extends Node
class_name MpTransactionsCoordinator

const PeerReplayResultCacheScript := preload(
	"res://scene/multiplayer/peer_replay_result_cache.gd"
)

const SIMPLE_CRAFTING_RATE_PER_SECOND := 8.0
const SIMPLE_CRAFTING_RATE_BURST := 12.0
const SIMPLE_CRAFTING_RESULT_CACHE_SIZE := 32
const SIMPLE_CRAFTING_WIRE_ID_MAX_LENGTH := 128
const PLAYER_TRANSACTION_INGRESS_RATE_PER_SECOND := 32.0
const PLAYER_TRANSACTION_INGRESS_RATE_BURST := 48.0
const INVENTORY_COMMAND_RATE_PER_SECOND := 12.0
const INVENTORY_COMMAND_RATE_BURST := 20.0

signal upgrade_request_to_host(stat_type: int)
signal inventory_item_use_request_to_host(
	slot_index: int,
	expected_inventory_revision: int
)
signal inventory_item_discard_request_to_host(
	slot_index: int,
	expected_inventory_revision: int
)
signal simple_crafting_request_to_host(
	request_id: int,
	recipe_id: String,
	expected_inventory_revision: int
)
signal skill1_purchase_request_to_host

signal upgrade_confirmation_broadcast_requested(
	peer_id: int,
	stat_type: int,
	level: int,
	current_xirang: int,
	success: bool,
	free_upgrade: bool
)
signal inventory_item_used_broadcast_requested(
	peer_id: int,
	slot_index: int,
	config_path: String,
	success: bool,
	inventory_snapshot: Dictionary,
	force_inventory_repair: bool
)
signal inventory_item_discarded_broadcast_requested(
	peer_id: int,
	slot_index: int,
	success: bool,
	inventory_snapshot: Dictionary,
	force_inventory_repair: bool
)
signal simple_crafting_result_broadcast_requested(
	peer_id: int,
	request_id: int,
	recipe_id: String,
	result_code: String,
	inventory_snapshot: Dictionary,
	force_inventory_repair: bool
)
signal skill1_purchase_confirmation_broadcast_requested(
	peer_id: int,
	current_xirang: int,
	skill1_unlocked: bool,
	result_code: int,
	skill1_upgrade_level: int,
	skill1_charge_duration: float
)

var _session: MultiplayerGameplaySession = null
var _runtime: CombatRuntimeBase = null
var _mode_adapter: MultiplayerModeAdapter = null
var _net_manager: NetManagerStore = null
var _run_state: RunStateStore = null
var _suspended_peer_ids: Dictionary[int, bool] = {}

var _player_transaction_ingress_rate_buckets: Dictionary = {}
var _inventory_command_rate_buckets: Dictionary = {}
var _local_simple_crafting_request_id := 0
var _local_simple_crafting_ui_tokens_by_request_id: Dictionary = {}
var _local_simple_crafting_request_ids_by_ui_token: Dictionary = {}
var _last_simple_crafting_request_ids: Dictionary = {}
var _last_simple_crafting_result_ids: Dictionary = {}
var _simple_crafting_rate_buckets: Dictionary = {}
var _simple_crafting_result_cache := PeerReplayResultCacheScript.new(
	SIMPLE_CRAFTING_RESULT_CACHE_SIZE
)
# Kept as a stable diagnostic view over the bounded replay cache.
var _simple_crafting_results_by_peer: Dictionary = (
	_simple_crafting_result_cache.results_by_peer
)


func bind_session(
	session: MultiplayerGameplaySession,
	runtime: CombatRuntimeBase,
	mode_adapter: MultiplayerModeAdapter,
	net_manager: NetManagerStore,
	run_state: RunStateStore,
	suspended_peer_ids: Dictionary[int, bool]
) -> void:
	assert(session != null, "MpTransactionsCoordinator 缺少多人会话。")
	assert(runtime != null, "MpTransactionsCoordinator 缺少战斗运行时。")
	assert(mode_adapter != null, "MpTransactionsCoordinator 缺少模式适配器。")
	assert(net_manager != null, "MpTransactionsCoordinator 缺少网络管理器。")
	assert(run_state != null, "MpTransactionsCoordinator 缺少运行状态。")
	if _session != null and _session != session:
		reset_session_state()
	_session = session
	_runtime = runtime
	_mode_adapter = mode_adapter
	_net_manager = net_manager
	_run_state = run_state
	_suspended_peer_ids = suspended_peer_ids


func unbind_session(session: MultiplayerGameplaySession) -> void:
	if _session != session:
		return
	reset_session_state()
	_session = null
	_runtime = null
	_mode_adapter = null
	_net_manager = null
	_run_state = null
	_suspended_peer_ids = {}


func is_bound() -> bool:
	return (
		_session != null
		and is_instance_valid(_session)
		and _runtime != null
		and is_instance_valid(_runtime)
		and _mode_adapter != null
		and is_instance_valid(_mode_adapter)
		and _net_manager != null
		and is_instance_valid(_net_manager)
		and _run_state != null
		and is_instance_valid(_run_state)
	)


func reset_session_state() -> void:
	_player_transaction_ingress_rate_buckets.clear()
	_inventory_command_rate_buckets.clear()
	_local_simple_crafting_request_id = 0
	clear_local_simple_crafting_request_tracking()
	_last_simple_crafting_request_ids.clear()
	_last_simple_crafting_result_ids.clear()
	_simple_crafting_rate_buckets.clear()
	_simple_crafting_result_cache.clear()


func clear_peer(peer_id: int) -> void:
	if peer_id <= 0:
		return
	_player_transaction_ingress_rate_buckets.erase(peer_id)
	_inventory_command_rate_buckets.erase(peer_id)
	_last_simple_crafting_request_ids.erase(peer_id)
	_last_simple_crafting_result_ids.erase(peer_id)
	_simple_crafting_rate_buckets.erase(peer_id)
	_simple_crafting_result_cache.clear_peer(peer_id)


func request_upgrade(stat_type: int) -> void:
	if not is_bound():
		return
	if _net_manager.is_host():
		apply_authoritative_upgrade(_get_local_peer_id(), stat_type)
	elif _net_manager.is_client():
		upgrade_request_to_host.emit(stat_type)


func request_inventory_item_use(slot_index: int) -> void:
	if not is_bound():
		return
	var peer_id := _get_local_peer_id()
	var expected_revision := _run_state.get_inventory_revision_for_peer(peer_id)
	if _net_manager.is_host():
		apply_authoritative_inventory_item_use(
			peer_id,
			slot_index,
			expected_revision
		)
	elif _net_manager.is_client():
		inventory_item_use_request_to_host.emit(slot_index, expected_revision)


func request_inventory_item_discard(slot_index: int) -> void:
	if not is_bound():
		return
	var peer_id := _get_local_peer_id()
	var expected_revision := _run_state.get_inventory_revision_for_peer(peer_id)
	if _net_manager.is_host():
		apply_authoritative_inventory_item_discard(
			peer_id,
			slot_index,
			expected_revision
		)
	elif _net_manager.is_client():
		inventory_item_discard_request_to_host.emit(slot_index, expected_revision)


func request_simple_crafting(
	recipe_id: StringName,
	ui_request_token: int
) -> void:
	var peer_id := _get_local_peer_id()
	if not is_bound() or peer_id <= 0 or ui_request_token <= 0:
		if _mode_adapter != null:
			_mode_adapter.show_simple_crafting_result(
				recipe_id,
				&"invalid_player",
				ui_request_token
			)
		return
	_local_simple_crafting_request_id += 1
	var request_id := _local_simple_crafting_request_id
	track_local_simple_crafting_request(request_id, ui_request_token)
	var expected_revision := _run_state.get_inventory_revision_for_peer(peer_id)
	if _net_manager.is_host():
		apply_authoritative_simple_crafting_request(
			peer_id,
			request_id,
			String(recipe_id),
			expected_revision
		)
	elif _net_manager.is_client():
		simple_crafting_request_to_host.emit(
			request_id,
			String(recipe_id),
			expected_revision
		)
	else:
		take_local_simple_crafting_request_token(request_id)
		_mode_adapter.show_simple_crafting_result(
			recipe_id,
			&"invalid_player",
			ui_request_token
		)


func cancel_simple_crafting_request(ui_request_token: int) -> void:
	# The authoritative transaction may already be running. Releasing only the
	# local UI token lets a late result still repair the inventory snapshot.
	if ui_request_token <= 0:
		return
	var request_id := int(
		_local_simple_crafting_request_ids_by_ui_token.get(
			ui_request_token,
			0
		)
	)
	if request_id <= 0:
		return
	_local_simple_crafting_request_ids_by_ui_token.erase(ui_request_token)
	_local_simple_crafting_ui_tokens_by_request_id.erase(request_id)


func request_skill1_purchase() -> void:
	if not is_bound():
		return
	if _net_manager.is_host():
		apply_authoritative_skill1_purchase(_get_local_peer_id())
	elif _net_manager.is_client():
		skill1_purchase_request_to_host.emit()


func handle_remote_upgrade_selection(sender_id: int, stat_type: int) -> void:
	if not _is_authoritative_request_sender(sender_id):
		return
	if not consume_remote_transaction_admission(sender_id):
		return
	apply_authoritative_upgrade(sender_id, stat_type)


func handle_remote_inventory_item_use_request(
	sender_id: int,
	slot_index: int,
	expected_inventory_revision: int
) -> void:
	if not _admit_remote_inventory_command(sender_id):
		return
	if expected_inventory_revision < 0:
		# Missing optimistic-concurrency data becomes an impossible future revision.
		expected_inventory_revision = (
			_run_state.get_inventory_revision_for_peer(sender_id) + 1
		)
	apply_authoritative_inventory_item_use(
		sender_id,
		slot_index,
		expected_inventory_revision
	)


func handle_remote_inventory_item_discard_request(
	sender_id: int,
	slot_index: int,
	expected_inventory_revision: int
) -> void:
	if not _admit_remote_inventory_command(sender_id):
		return
	if expected_inventory_revision < 0:
		expected_inventory_revision = (
			_run_state.get_inventory_revision_for_peer(sender_id) + 1
		)
	apply_authoritative_inventory_item_discard(
		sender_id,
		slot_index,
		expected_inventory_revision
	)


func handle_remote_simple_crafting_request(
	sender_id: int,
	request_id: int,
	recipe_id: String,
	expected_inventory_revision: int
) -> void:
	if not _is_authoritative_request_sender(sender_id):
		return
	apply_authoritative_simple_crafting_request(
		sender_id,
		request_id,
		recipe_id,
		expected_inventory_revision
	)


func handle_remote_skill1_purchase_request(sender_id: int) -> void:
	if not _is_authoritative_request_sender(sender_id):
		return
	if not consume_remote_transaction_admission(sender_id):
		return
	apply_authoritative_skill1_purchase(sender_id)


func consume_remote_transaction_admission(
	peer_id: int,
	now_seconds: float = -1.0
) -> bool:
	if not is_bound() or peer_id <= 0:
		return false
	# Local Host UI calls are trusted. The shared remote budget prevents clients
	# from alternating transaction RPC types to multiply admitted work.
	if peer_id == _get_local_peer_id():
		return true
	if _suspended_peer_ids.has(peer_id):
		return false
	return _consume_peer_rate_token(
		_player_transaction_ingress_rate_buckets,
		peer_id,
		PLAYER_TRANSACTION_INGRESS_RATE_PER_SECOND,
		PLAYER_TRANSACTION_INGRESS_RATE_BURST,
		now_seconds
	)


func apply_authoritative_upgrade(peer_id: int, stat_type: int) -> void:
	if not is_bound() or peer_id <= 0:
		return
	var player_node: Player = _runtime.get_player_for_peer(peer_id)
	if player_node == null or not is_instance_valid(player_node):
		return
	var success := _run_state.try_upgrade_for_peer(peer_id, stat_type, player_node)
	var free_upgrade := success and player_node.consume_last_base_upgrade_free_flag()
	var level := _run_state.get_upgrade_level_for_peer(peer_id, stat_type)
	var current_xirang := player_node.current_xirang
	upgrade_confirmation_broadcast_requested.emit(
		peer_id,
		stat_type,
		level,
		current_xirang,
		success,
		free_upgrade
	)


func apply_authoritative_inventory_item_use(
	peer_id: int,
	slot_index: int,
	expected_inventory_revision: int = -1
) -> void:
	if not is_bound() or peer_id <= 0:
		return
	var player_node: Player = _runtime.get_player_for_peer(peer_id)
	if player_node == null or not is_instance_valid(player_node):
		return
	var current_revision := _run_state.get_inventory_revision_for_peer(peer_id)
	var revision_mismatch := (
		expected_inventory_revision >= 0
		and expected_inventory_revision != current_revision
	)
	var item := _run_state.get_item_for_peer(peer_id, slot_index)
	var config_path := item.resource_path if item != null else ""
	var success := (
		not revision_mismatch
		and _run_state.try_use_item_for_peer(peer_id, slot_index, player_node)
	)
	if not success:
		config_path = ""
	var inventory_snapshot := _run_state.export_inventory_snapshot_for_peer(peer_id)
	inventory_item_used_broadcast_requested.emit(
		peer_id,
		slot_index,
		config_path,
		success,
		inventory_snapshot,
		revision_mismatch
	)


func apply_authoritative_inventory_item_discard(
	peer_id: int,
	slot_index: int,
	expected_inventory_revision: int = -1
) -> void:
	if not is_bound() or peer_id <= 0:
		return
	var player_node: Player = _runtime.get_player_for_peer(peer_id)
	if player_node == null or not is_instance_valid(player_node):
		return
	var current_revision := _run_state.get_inventory_revision_for_peer(peer_id)
	var revision_mismatch := (
		expected_inventory_revision >= 0
		and expected_inventory_revision != current_revision
	)
	var success := (
		not revision_mismatch
		and _run_state.discard_item_for_peer(peer_id, slot_index)
	)
	var inventory_snapshot := _run_state.export_inventory_snapshot_for_peer(peer_id)
	inventory_item_discarded_broadcast_requested.emit(
		peer_id,
		slot_index,
		success,
		inventory_snapshot,
		revision_mismatch
	)


func apply_authoritative_simple_crafting_request(
	peer_id: int,
	request_id: int,
	recipe_id: String,
	expected_inventory_revision: int
) -> void:
	if not is_bound() or not _net_manager.is_host() or peer_id <= 0:
		return
	if not consume_remote_transaction_admission(peer_id):
		return
	if (
		request_id <= 0
		or expected_inventory_revision < 0
		or recipe_id.is_empty()
		or recipe_id.length() > SIMPLE_CRAFTING_WIRE_ID_MAX_LENGTH
	):
		return
	if not _consume_peer_rate_token(
		_simple_crafting_rate_buckets,
		peer_id,
		SIMPLE_CRAFTING_RATE_PER_SECOND,
		SIMPLE_CRAFTING_RATE_BURST
	):
		return
	var cached_result := get_cached_simple_crafting_result(peer_id, request_id)
	if not cached_result.is_empty():
		cached_result["inventory_snapshot"] = (
			_run_state.export_inventory_snapshot_for_peer(peer_id)
		)
		cache_simple_crafting_result(peer_id, request_id, cached_result)
		_send_simple_crafting_result(cached_result)
		return
	var player_node := _runtime.get_player_for_peer(peer_id)
	var last_request_id := int(
		_last_simple_crafting_request_ids.get(peer_id, 0)
	)
	var recipe := SimpleCraftingRegistry.get_recipe_by_wire_id(recipe_id)
	var canonical_recipe_id := recipe.recipe_id if recipe != null else &""
	var result := RunStateStore.CRAFT_RESULT_INVALID_RECIPE
	var should_cache := false
	if request_id <= last_request_id:
		result = &"stale_request"
	else:
		_last_simple_crafting_request_ids[peer_id] = request_id
		should_cache = true
		if (
			player_node == null
			or not is_instance_valid(player_node)
			or player_node.is_dead
		):
			result = &"invalid_player"
		elif recipe != null:
			result = _run_state.try_craft_inventory_recipe_for_peer_if_revision(
				peer_id,
				recipe,
				expected_inventory_revision,
				true,
				_mode_adapter.get_completed_global_research_ids()
			)
	var transaction_result := {
		"peer_id": peer_id,
		"request_id": request_id,
		"recipe_id": String(canonical_recipe_id),
		"result": String(result),
		"inventory_snapshot": _run_state.export_inventory_snapshot_for_peer(
			peer_id
		),
		"force_inventory_repair": (
			result == RunStateStore.CRAFT_RESULT_STALE_REVISION
		),
	}
	if should_cache:
		cache_simple_crafting_result(peer_id, request_id, transaction_result)
	_send_simple_crafting_result(transaction_result)


func apply_authoritative_skill1_purchase(peer_id: int) -> void:
	if not is_bound() or peer_id <= 0:
		return
	var player_node := _runtime.get_player_for_peer(peer_id)
	if player_node == null or not is_instance_valid(player_node):
		return
	var result_code := _mode_adapter.try_purchase_skill1_for_peer(peer_id)
	var current_xirang := player_node.current_xirang
	var skill1_unlocked := player_node.has_skill1()
	var skill1_upgrade_level := player_node.skill1_upgrade_level
	var skill1_charge_duration := player_node.skill1_charge_duration
	skill1_purchase_confirmation_broadcast_requested.emit(
		peer_id,
		current_xirang,
		skill1_unlocked,
		result_code,
		skill1_upgrade_level,
		skill1_charge_duration
	)


func receive_inventory_snapshot(
	peer_id: int,
	snapshot: Dictionary,
	force_inventory_repair: bool = false
) -> void:
	if _run_state == null or peer_id <= 0 or snapshot.is_empty():
		return
	_run_state.apply_inventory_snapshot_for_peer(
		peer_id,
		snapshot,
		force_inventory_repair
	)


func receive_upgrade_confirmation(
	peer_id: int,
	stat_type: int,
	level: int,
	current_xirang: int,
	success: bool,
	free_upgrade: bool = false
) -> void:
	if not success or not is_bound() or peer_id <= 0:
		return
	var player_node: Player = _runtime.get_player_for_peer(peer_id)
	if player_node == null or not is_instance_valid(player_node):
		return
	_run_state.ensure_multiplayer_peer_state(peer_id)
	_run_state.set_upgrade_level_for_peer(peer_id, stat_type, level)
	var already_applied_on_host := (
		_net_manager.is_host() and peer_id == _get_local_peer_id()
	)
	if not already_applied_on_host:
		_apply_confirmed_upgrade_to_player(player_node, stat_type)
	player_node.current_xirang = current_xirang
	player_node.xirang_changed.emit(current_xirang, 0)
	if free_upgrade and not already_applied_on_host:
		player_node.play_lucky_upgrade_feedback()


func receive_inventory_item_used(
	peer_id: int,
	_slot_index: int,
	config_path: String,
	success: bool,
	inventory_snapshot: Dictionary,
	force_inventory_repair: bool = false
) -> void:
	if not is_bound() or peer_id <= 0 or inventory_snapshot.is_empty():
		return
	var player_node: Player = _runtime.get_player_for_peer(peer_id)
	if player_node == null or not is_instance_valid(player_node):
		return
	if _net_manager.is_host() and peer_id == _get_local_peer_id():
		return
	var revision_before := _run_state.get_inventory_revision_for_peer(peer_id)
	var snapshot_applied := _run_state.apply_inventory_snapshot_for_peer(
		peer_id,
		inventory_snapshot,
		force_inventory_repair
	)
	if not snapshot_applied or not success:
		return
	if (
		int(inventory_snapshot.get("revision", -1)) > revision_before
		and not config_path.is_empty()
	):
		var item := load(config_path) as PickupConfig
		if item != null:
			player_node.apply_pickup(item, false)


func receive_inventory_item_discarded(
	peer_id: int,
	_slot_index: int,
	_success: bool,
	inventory_snapshot: Dictionary,
	force_inventory_repair: bool = false
) -> void:
	if not is_bound() or peer_id <= 0 or inventory_snapshot.is_empty():
		return
	var player_node: Player = _runtime.get_player_for_peer(peer_id)
	if player_node == null or not is_instance_valid(player_node):
		return
	if _net_manager.is_host() and peer_id == _get_local_peer_id():
		return
	_run_state.apply_inventory_snapshot_for_peer(
		peer_id,
		inventory_snapshot,
		force_inventory_repair
	)


func receive_simple_crafting_result(
	peer_id: int,
	request_id: int,
	recipe_id: String,
	result: String,
	inventory_snapshot: Dictionary,
	force_inventory_repair: bool = false
) -> void:
	if (
		not is_bound()
		or peer_id <= 0
		or request_id <= 0
		or inventory_snapshot.is_empty()
	):
		return
	var player_node := _runtime.get_player_for_peer(peer_id)
	if player_node == null or not is_instance_valid(player_node):
		return
	var last_result_id := int(_last_simple_crafting_result_ids.get(peer_id, 0))
	if request_id <= last_result_id:
		return
	if not _net_manager.is_host():
		var snapshot_applied := _run_state.apply_inventory_snapshot_for_peer(
			peer_id,
			inventory_snapshot,
			force_inventory_repair and peer_id == _get_local_peer_id()
		)
		if not snapshot_applied:
			return
	_last_simple_crafting_result_ids[peer_id] = request_id
	if peer_id != _get_local_peer_id():
		return
	var ui_request_token := take_local_simple_crafting_request_token(request_id)
	_mode_adapter.show_simple_crafting_result(
		StringName(recipe_id),
		_normalize_crafting_result_code(StringName(result)),
		ui_request_token
	)


func receive_skill1_purchase_confirmation(
	peer_id: int,
	current_xirang: int,
	skill1_unlocked: bool,
	result_code: int,
	skill1_upgrade_level: int = -1,
	skill1_charge_duration: float = -1.0
) -> void:
	if not is_bound():
		return
	_mode_adapter.apply_skill1_purchase_state(
		peer_id,
		current_xirang,
		skill1_unlocked,
		skill1_upgrade_level,
		skill1_charge_duration
	)
	if peer_id == _get_local_peer_id():
		_mode_adapter.show_local_skill1_purchase_result(result_code)


func track_local_simple_crafting_request(
	request_id: int,
	ui_request_token: int
) -> void:
	if request_id <= 0 or ui_request_token <= 0:
		return
	var previous_request_id := int(
		_local_simple_crafting_request_ids_by_ui_token.get(ui_request_token, 0)
	)
	if previous_request_id > 0:
		_local_simple_crafting_ui_tokens_by_request_id.erase(previous_request_id)
	_local_simple_crafting_ui_tokens_by_request_id[request_id] = ui_request_token
	_local_simple_crafting_request_ids_by_ui_token[ui_request_token] = request_id


func take_local_simple_crafting_request_token(request_id: int) -> int:
	if request_id <= 0:
		return 0
	var ui_request_token := int(
		_local_simple_crafting_ui_tokens_by_request_id.get(request_id, 0)
	)
	_local_simple_crafting_ui_tokens_by_request_id.erase(request_id)
	if (
		ui_request_token > 0
		and int(
			_local_simple_crafting_request_ids_by_ui_token.get(
				ui_request_token,
				0
			)
		) == request_id
	):
		_local_simple_crafting_request_ids_by_ui_token.erase(ui_request_token)
	return ui_request_token


func clear_local_simple_crafting_request_tracking() -> void:
	_local_simple_crafting_ui_tokens_by_request_id.clear()
	_local_simple_crafting_request_ids_by_ui_token.clear()


func get_cached_simple_crafting_result(peer_id: int, request_id: int) -> Dictionary:
	if peer_id <= 0 or request_id <= 0:
		return {}
	return _simple_crafting_result_cache.get_result(peer_id, request_id)


func cache_simple_crafting_result(
	peer_id: int,
	request_id: int,
	result: Dictionary
) -> void:
	if peer_id <= 0 or request_id <= 0 or result.is_empty():
		return
	_simple_crafting_result_cache.store_result(peer_id, request_id, result)


func _send_simple_crafting_result(result: Dictionary) -> void:
	simple_crafting_result_broadcast_requested.emit(
		int(result.get("peer_id", 0)),
		int(result.get("request_id", 0)),
		str(result.get("recipe_id", "")),
		str(result.get("result", RunStateStore.CRAFT_RESULT_INVALID_RECIPE)),
		result.get("inventory_snapshot", {}) as Dictionary,
		bool(result.get("force_inventory_repair", false))
	)


func _admit_remote_inventory_command(sender_id: int) -> bool:
	return (
		_is_authoritative_request_sender(sender_id)
		and consume_remote_transaction_admission(sender_id)
		and _consume_peer_rate_token(
			_inventory_command_rate_buckets,
			sender_id,
			INVENTORY_COMMAND_RATE_PER_SECOND,
			INVENTORY_COMMAND_RATE_BURST
		)
	)


func _is_authoritative_request_sender(sender_id: int) -> bool:
	return (
		is_bound()
		and _net_manager.is_host()
		and sender_id > 0
	)


func _consume_peer_rate_token(
	buckets: Dictionary,
	peer_id: int,
	rate_per_second: float,
	burst: float,
	now_seconds: float = -1.0
) -> bool:
	if peer_id <= 0 or rate_per_second <= 0.0 or burst <= 0.0:
		return false
	var now := Time.get_ticks_msec() / 1000.0 if now_seconds < 0.0 else now_seconds
	var bucket: Dictionary
	if buckets.has(peer_id):
		bucket = buckets[peer_id] as Dictionary
	else:
		bucket = {"tokens": burst, "last_time": now}
		buckets[peer_id] = bucket
	var tokens := float(bucket.get("tokens", burst))
	var last_time := float(bucket.get("last_time", now))
	tokens = minf(burst, tokens + maxf(now - last_time, 0.0) * rate_per_second)
	var accepted := tokens >= 1.0
	if accepted:
		tokens -= 1.0
	bucket["tokens"] = tokens
	bucket["last_time"] = now
	return accepted


func _get_local_peer_id() -> int:
	if _net_manager == null:
		return 0
	return _net_manager.get_local_peer_id()


func _apply_confirmed_upgrade_to_player(
	player_node: Player,
	stat_type: int
) -> void:
	match stat_type:
		RunStateStore.StatType.ATTACK:
			player_node.upgrade_attack()
		RunStateStore.StatType.HEALTH:
			player_node.upgrade_max_health()
		RunStateStore.StatType.ATTACK_SPEED:
			player_node.upgrade_attack_speed()
		RunStateStore.StatType.DODGE:
			player_node.upgrade_dodge()


func _normalize_crafting_result_code(result_code: StringName) -> StringName:
	match result_code:
		RunStateStore.CRAFT_RESULT_SUCCESS:
			return result_code
		RunStateStore.CRAFT_RESULT_INVALID_RECIPE:
			return result_code
		RunStateStore.CRAFT_RESULT_MISSING_INPUT:
			return result_code
		RunStateStore.CRAFT_RESULT_INVENTORY_FULL:
			return result_code
		RunStateStore.CRAFT_RESULT_STALE_REVISION:
			return result_code
		RunStateStore.CRAFT_RESULT_RESEARCH_LOCKED:
			return result_code
		&"rate_limited":
			return result_code
		&"invalid_player":
			return result_code
		&"stale_request":
			return result_code
	return RunStateStore.CRAFT_RESULT_INVALID_RECIPE
