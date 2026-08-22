extends Node
class_name MpTransactionsCoordinator

const PeerReplayResultCacheScript := preload(
	"res://scene/multiplayer/peer_replay_result_cache.gd"
)
const RuntimeContentCatalogScript := preload(
	"res://resources/config/runtime_content_catalog.gd"
)

const SIMPLE_CRAFTING_RATE_PER_SECOND := 8.0
const SIMPLE_CRAFTING_RATE_BURST := 12.0
const SIMPLE_CRAFTING_REPLAY_RATE_PER_SECOND := 4.0
const SIMPLE_CRAFTING_REPLAY_RATE_BURST := 8.0
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
var _simple_crafting_replay_rate_buckets: Dictionary = {}
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
	_simple_crafting_replay_rate_buckets.clear()
	_simple_crafting_result_cache.clear()


func clear_peer(peer_id: int) -> void:
	if peer_id <= 0:
		return
	_player_transaction_ingress_rate_buckets.erase(peer_id)
	_inventory_command_rate_buckets.erase(peer_id)
	_last_simple_crafting_request_ids.erase(peer_id)
	_last_simple_crafting_result_ids.erase(peer_id)
	_simple_crafting_rate_buckets.erase(peer_id)
	_simple_crafting_replay_rate_buckets.erase(peer_id)
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
	if (
		_suspended_peer_ids.has(peer_id)
		or not _net_manager.is_gameplay_ingress_admitted(peer_id)
	):
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
	var item_is_registered := (
		item == null
		or RuntimeContentCatalogScript.is_registered_pickup_config(item)
	)
	var success := (
		not revision_mismatch
		and item_is_registered
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
	if (
		request_id <= 0
		or expected_inventory_revision < 0
		or recipe_id.is_empty()
		or recipe_id.length() > SIMPLE_CRAFTING_WIRE_ID_MAX_LENGTH
	):
		return
	var cached_result := get_cached_simple_crafting_result(peer_id, request_id)
	if not cached_result.is_empty():
		# request_id 已经结算时只重放不可变结果，不再占用“新事务”预算；
		# 独立的低速预算仍限制恶意重复包造成的广播放大。
		if not _consume_peer_rate_token(
			_simple_crafting_replay_rate_buckets,
			peer_id,
			SIMPLE_CRAFTING_REPLAY_RATE_PER_SECOND,
			SIMPLE_CRAFTING_REPLAY_RATE_BURST
		):
			return
		cached_result["inventory_snapshot"] = (
			_run_state.export_inventory_snapshot_for_peer(peer_id)
		)
		cache_simple_crafting_result(peer_id, request_id, cached_result)
		_send_simple_crafting_result(cached_result)
		return
	if not consume_remote_transaction_admission(peer_id):
		return
	if not _consume_peer_rate_token(
		_simple_crafting_rate_buckets,
		peer_id,
		SIMPLE_CRAFTING_RATE_PER_SECOND,
		SIMPLE_CRAFTING_RATE_BURST
	):
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
			result = _mode_adapter.try_commit_simple_crafting_for_peer(
				_run_state,
				peer_id,
				recipe,
				expected_inventory_revision,
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
	var skill1_upgrade_level := (
		player_node.skill1_upgrade_level
		if result_code == MerchantPurchaseResult.SkillUpgrade.UPGRADE_SUCCESS
		else -1
	)
	var skill1_charge_duration := player_node.skill1_charge_duration
	skill1_purchase_confirmation_broadcast_requested.emit(
		peer_id,
		current_xirang,
		skill1_unlocked,
		result_code,
		skill1_upgrade_level,
		skill1_charge_duration
	)


func build_runtime_repair_inventory_rpc_arguments() -> Array[Array]:
	var payloads: Array[Array] = []
	if not is_bound():
		return payloads
	for peer_id_variant in _runtime.peer_players.keys():
		var peer_id := int(peer_id_variant)
		if peer_id <= 0 or not _run_state.has_multiplayer_peer_state(peer_id):
			continue
		payloads.append([
			peer_id,
			_run_state.export_inventory_snapshot_for_peer(peer_id),
			true,
		])
	return payloads


## CH6 冻结协议下的成长修复使用既有逐字段确认入口。每项等级本身就是
## 单调高水位，因此不比较各端本地 change counter；即使 Player 暂时缺席，
## 接收端也能先把四项基础等级与技能等级提交到稳定成员的 RunState。
func build_runtime_repair_progression_rpc_requests() -> Array[Dictionary]:
	var requests: Array[Dictionary] = []
	if not is_bound() or not _net_manager.is_host():
		return requests
	for peer_id in _run_state.get_registered_multiplayer_peer_ids():
		var player_node: Player = _runtime.get_player_for_peer(peer_id)
		var has_live_player := (
			player_node != null
			and is_instance_valid(player_node)
			and not player_node.is_queued_for_deletion()
		)
		var current_xirang := (
			player_node.current_xirang
			if has_live_player
			else _run_state.get_party_xirang_balance(peer_id)
		)
		var stat_types: Array = RunStateStore.MAX_UPGRADE_LEVELS.keys()
		stat_types.sort()
		for stat_type_variant in stat_types:
			var stat_type := int(stat_type_variant)
			requests.append({
				"method": &"net_upgrade_confirmed",
				"arguments": [
					peer_id,
					stat_type,
					_run_state.get_upgrade_level_for_peer(peer_id, stat_type),
					current_xirang,
					true,
					false,
				],
			})
		var skill_level := _run_state.get_skill1_upgrade_level_for_peer(peer_id)
		requests.append({
			"method": &"net_skill1_purchase_confirmed",
			"arguments": [
				peer_id,
				current_xirang,
				has_live_player and player_node.has_skill1(),
				# SUCCESS 不由真实购买产生，作为既有协议中的无 UI 状态修复码。
				MerchantPurchaseResult.SkillUpgrade.SUCCESS,
				skill_level,
				player_node.skill1_charge_duration if has_live_player else -1.0,
			],
		})
	return requests


func receive_inventory_snapshot(
	peer_id: int,
	snapshot: Dictionary,
	force_inventory_repair: bool = false
) -> bool:
	if _run_state == null or peer_id <= 0 or snapshot.is_empty():
		return false
	return _run_state.apply_inventory_snapshot_for_peer(
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
) -> bool:
	if (
		not is_bound()
		or peer_id <= 0
		or current_xirang < 0
		or not RunStateStore.MAX_UPGRADE_LEVELS.has(stat_type)
		or level < 0
		or level > int(RunStateStore.MAX_UPGRADE_LEVELS[stat_type])
	):
		return false
	if not success:
		return true
	# 升级等级属于 RunState 持久账本；Player 只负责当前场景中的属性表现。
	var previous_level := _run_state.get_upgrade_level_for_peer(peer_id, stat_type)
	# 低于本地高水位的迟到确认已经被更完整的状态覆盖；把它作为领域幂等
	# 接收，不能反复触发整局 repair，也不能用包内旧余额覆盖 Player。
	if level <= previous_level:
		return true
	if not _run_state.set_upgrade_level_for_peer(peer_id, stat_type, level):
		return false
	var player_node: Player = _runtime.get_player_for_peer(peer_id)
	if player_node == null or not is_instance_valid(player_node):
		return true
	# Player 永远消费账本的完整绝对投影。Host 的本机确认与可靠 RPC 重放都
	# 只是幂等收敛，不会再次累加基础值。
	if not player_node.apply_run_progression_snapshot(
		_run_state.export_player_run_progression(peer_id),
		true
	):
		return false
	if previous_level != level and stat_type == RunStateStore.StatType.HEALTH:
		player_node.restore_current_health_to_maximum()
	# RUN_PARTY 余额只消费带 revision 的权威账本；CH6 购买确认的裸余额
	# 仅在场景内账户上随真正前进的等级一次性投影。
	if not player_node.uses_run_party_xirang_ledger(peer_id):
		player_node.set_xirang_balance(current_xirang)
		if player_node.current_xirang != current_xirang:
			return false
	if free_upgrade and not (_net_manager.is_host() and peer_id == _get_local_peer_id()):
		player_node.play_lucky_upgrade_feedback()
	return true


func receive_inventory_item_used(
	peer_id: int,
	_slot_index: int,
	config_path: String,
	success: bool,
	inventory_snapshot: Dictionary,
	force_inventory_repair: bool = false
) -> bool:
	if not is_bound() or peer_id <= 0 or inventory_snapshot.is_empty():
		return false
	# 成功包的表现资源也是事务输入，必须先完成可信目录解析；否则背包
	# revision 不得先推进，再把未知路径悄悄降级成“无表现”。
	var replay_item: PickupConfig = null
	if success:
		replay_item = (
			RuntimeContentCatalogScript.load_pickup_config_from_path(config_path)
		)
		if replay_item == null:
			return false
	var revision_before := _commit_received_inventory_snapshot(
		peer_id,
		inventory_snapshot,
		force_inventory_repair
	)
	if revision_before < 0:
		return false
	if not success:
		return true
	# 消耗品表现依赖 Player 节点，但背包账本不依赖。断线/重连导致节点
	# 暂时缺席时只跳过表现；可靠事务快照已经在上方完成收敛。
	var player_node: Player = _runtime.get_player_for_peer(peer_id)
	if player_node == null or not is_instance_valid(player_node):
		return true
	if (
		int(inventory_snapshot.get("revision", -1)) > revision_before
		and replay_item != null
	):
		player_node.apply_inventory_item_use_replay(replay_item)
	return true


func receive_inventory_item_discarded(
	peer_id: int,
	_slot_index: int,
	_success: bool,
	inventory_snapshot: Dictionary,
	force_inventory_repair: bool = false
) -> bool:
	if not is_bound() or peer_id <= 0 or inventory_snapshot.is_empty():
		return false
	return _commit_received_inventory_snapshot(
		peer_id,
		inventory_snapshot,
		force_inventory_repair
	) >= 0


func receive_simple_crafting_result(
	peer_id: int,
	request_id: int,
	recipe_id: String,
	result: String,
	inventory_snapshot: Dictionary,
	force_inventory_repair: bool = false
) -> bool:
	if (
		not is_bound()
		or peer_id <= 0
		or request_id <= 0
		or inventory_snapshot.is_empty()
	):
		return false
	var last_result_id := int(_last_simple_crafting_result_ids.get(peer_id, 0))
	if request_id <= last_result_id:
		return true
	if _commit_received_inventory_snapshot(
		peer_id,
		inventory_snapshot,
		force_inventory_repair and peer_id == _get_local_peer_id()
	) < 0:
		return false
	_last_simple_crafting_result_ids[peer_id] = request_id
	if peer_id != _get_local_peer_id():
		return true
	var ui_request_token := take_local_simple_crafting_request_token(request_id)
	_mode_adapter.show_simple_crafting_result(
		StringName(recipe_id),
		_normalize_crafting_result_code(StringName(result)),
		ui_request_token
	)
	return true


## CH6 事务结果首先收敛持久背包账本；Player 只是可选的表现载体。
## 返回接收前 revision，供消耗品判断是否需要重放一次本地效果；-1 表示
## 快照无效。Host 本机已在权威执行阶段提交账本，因此这里只确认而不重写。
func _commit_received_inventory_snapshot(
	peer_id: int,
	inventory_snapshot: Dictionary,
	force_inventory_repair: bool
) -> int:
	var revision_before := _run_state.get_inventory_revision_for_peer(peer_id)
	if _net_manager.is_host():
		return revision_before if peer_id == _get_local_peer_id() else -1
	if not _run_state.apply_inventory_snapshot_for_peer(
		peer_id,
		inventory_snapshot,
		force_inventory_repair
	):
		return -1
	return revision_before


func receive_skill1_purchase_confirmation(
	peer_id: int,
	current_xirang: int,
	skill1_unlocked: bool,
	result_code: int,
	skill1_upgrade_level: int = -1,
	skill1_charge_duration: float = -1.0
) -> bool:
	if (
		not is_bound()
		or peer_id <= 0
		or current_xirang < 0
		or result_code < MerchantPurchaseResult.SkillUpgrade.SUCCESS
		or result_code > MerchantPurchaseResult.SkillUpgrade.UPGRADE_MAXED
		or skill1_upgrade_level < -1
		or skill1_upgrade_level > Player.SKILL1_MAX_UPGRADE_LEVEL
		or not is_finite(skill1_charge_duration)
		or (skill1_charge_duration != -1.0 and skill1_charge_duration <= 0.0)
	):
		return false
	var is_local_result := peer_id == _get_local_peer_id()
	var is_host_local_result := is_local_result and _net_manager.is_host()
	# 技能等级与基础升级相同，先收敛到稳定成员的 RunState 账本；当前场景
	# Player 可以尚未生成，迟加入/重连修复也不能因此丢弃持久确认。
	# 失败反馈不承载新等级，因而不得用其载荷内的无 revision 余额
	# 覆盖 Player。Host 本机反馈由权威发送点单独呈现，避免重放。
	if skill1_upgrade_level < 0:
		if (
			is_local_result
			and not is_host_local_result
			and result_code != MerchantPurchaseResult.SkillUpgrade.SUCCESS
		):
			_mode_adapter.show_local_skill1_purchase_result(result_code)
		return true
	var current_skill_level := (
		_run_state.get_skill1_upgrade_level_for_peer(peer_id)
	)
	if skill1_upgrade_level <= current_skill_level:
		return true
	if not _run_state.set_skill1_upgrade_level_for_peer(
		peer_id,
		skill1_upgrade_level
	):
		return false
	var player_node := _runtime.get_player_for_peer(peer_id)
	if player_node == null or not is_instance_valid(player_node):
		return true
	if not player_node.apply_run_progression_snapshot(
		_run_state.export_player_run_progression(peer_id),
		true
	):
		return false
	# RUN_PARTY 余额必须等带 revision 的 party/full snapshot；仅场景内账户
	# 允许在等级真正前进时消费这份购买确认余额。
	var applies_scene_local_balance := not player_node.uses_run_party_xirang_ledger(
		peer_id
	)
	if applies_scene_local_balance:
		player_node.set_xirang_balance(current_xirang)
	# SUCCESS 只承载 runtime repair；真实购买使用 UPGRADE_SUCCESS/失败码。
	# 修复包绝不能让商人面板显示一次伪购买结果。
	if (
		is_local_result
		and not is_host_local_result
		and result_code != MerchantPurchaseResult.SkillUpgrade.SUCCESS
	):
		_mode_adapter.show_local_skill1_purchase_result(result_code)
	if applies_scene_local_balance and player_node.current_xirang != current_xirang:
		return false
	if skill1_unlocked and not player_node.has_skill1():
		return false
	if (
		skill1_upgrade_level >= 0
		and player_node.skill1_upgrade_level != skill1_upgrade_level
	):
		return false
	return true


## Host 本机在权威购买阶段已先推进账本，因此接收者会把同级包
## 当作幂等重放。发送点仅对这一次真实结果补充 UI，runtime repair 不调用。
func show_authoritative_local_skill1_purchase_result(result_code: int) -> void:
	if (
		not is_bound()
		or not _net_manager.is_host()
		or result_code == MerchantPurchaseResult.SkillUpgrade.SUCCESS
	):
		return
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
