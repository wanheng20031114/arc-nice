extends Node
class_name MpMerchantTransactionsCoordinator

const CHEAT_XIRANG_AMOUNT := 1000
const LUOXI_TRANSACTION_RATE_PER_SECOND := 4.0
const LUOXI_TRANSACTION_RATE_BURST := 6.0

signal rpc_to_host_requested(method_name: StringName, args: Array)
signal rpc_to_peer_requested(
	peer_id: int,
	method_name: StringName,
	args: Array
)
signal rpc_broadcast_requested(method_name: StringName, args: Array)

var _runtime: CombatRuntimeBase = null
var _mode_adapter: MultiplayerModeAdapter = null
var _run_state: RunStateStore = null
var _net_manager: NetManagerStore = null
var _net_time_origin := 0.0

var _luoxi_transaction_rate_buckets: Dictionary = {}
var _luoxi_offer_states_by_peer: Dictionary = {}
var _luoxi_offer_revision_counters: Dictionary = {}
var _luoxi_offer_random_generator := RandomNumberGenerator.new()


func bind_runtime(
	runtime_instance: CombatRuntimeBase,
	mode_adapter_instance: MultiplayerModeAdapter,
	run_state_instance: RunStateStore,
	net_manager_instance: NetManagerStore,
	net_time_origin_seconds: float
) -> void:
	assert(runtime_instance != null, "MpMerchantTransactionsCoordinator 缺少战斗运行时。")
	assert(mode_adapter_instance != null, "MpMerchantTransactionsCoordinator 缺少模式适配器。")
	assert(run_state_instance != null, "MpMerchantTransactionsCoordinator 缺少 RunState。")
	assert(net_manager_instance != null, "MpMerchantTransactionsCoordinator 缺少 NetManager。")
	if (
		_runtime == runtime_instance
		and _mode_adapter == mode_adapter_instance
		and _run_state == run_state_instance
		and _net_manager == net_manager_instance
	):
		_net_time_origin = net_time_origin_seconds
		return
	reset_session_state()
	_runtime = runtime_instance
	_mode_adapter = mode_adapter_instance
	_run_state = run_state_instance
	_net_manager = net_manager_instance
	_net_time_origin = net_time_origin_seconds


func unbind_runtime(runtime_instance: CombatRuntimeBase) -> void:
	if _runtime != runtime_instance:
		return
	reset_session_state()
	_runtime = null
	_mode_adapter = null
	_run_state = null
	_net_manager = null


func is_bound() -> bool:
	return (
		_runtime != null
		and is_instance_valid(_runtime)
		and _mode_adapter != null
		and is_instance_valid(_mode_adapter)
		and _run_state != null
		and is_instance_valid(_run_state)
		and _net_manager != null
		and is_instance_valid(_net_manager)
	)


func randomize_offer_generator() -> void:
	_luoxi_offer_random_generator.randomize()


func uses_authoritative_luoxi_offers() -> bool:
	return true


func supports_luoxi_special_game() -> bool:
	return (
		is_bound()
		and _mode_adapter.runtime_supports_luoxi_special_game()
	)


func has_luoxi_collectible_claimed(peer_id: int) -> bool:
	return (
		is_bound()
		and peer_id > 0
		and _mode_adapter.runtime_has_luoxi_collectible_claimed(peer_id)
	)


func request_luoxi_collectible_offer() -> void:
	if not is_bound():
		return
	var peer_id := _net_manager.get_local_peer_id()
	if _net_manager.is_host():
		_send_or_create_luoxi_offer_for_peer(peer_id)
	elif _net_manager.is_client():
		rpc_to_host_requested.emit(&"net_luoxi_collectible_offer_requested", [])


func request_luoxi_collectible_choice(
	choice_index: int,
	offer_revision: int = 0
) -> void:
	if not is_bound():
		return
	if _net_manager.is_host():
		_apply_luoxi_collectible_choice_for_peer(
			_net_manager.get_local_peer_id(),
			choice_index,
			offer_revision,
			false
		)
	elif _net_manager.is_client():
		rpc_to_host_requested.emit(
			&"net_luoxi_collectible_choice_requested",
			[choice_index, offer_revision]
		)


func request_luoxi_collectible_refresh(offer_revision: int = 0) -> void:
	if not is_bound():
		return
	if _net_manager.is_host():
		_apply_luoxi_collectible_refresh_for_peer(
			_net_manager.get_local_peer_id(),
			offer_revision,
			false
		)
	elif _net_manager.is_client():
		rpc_to_host_requested.emit(
			&"net_luoxi_collectible_refresh_requested",
			[offer_revision]
		)


func request_luoxi_special_game_start() -> void:
	if not is_bound():
		return
	if _net_manager.is_host():
		_apply_luoxi_special_game_start_for_peer(
			_net_manager.get_local_peer_id()
		)
	elif _net_manager.is_client():
		rpc_to_host_requested.emit(&"net_luoxi_special_game_start_requested", [])


func request_luoxi_special_game_card_reveal(
	session_revision: int,
	card_index: int
) -> void:
	if not is_bound():
		return
	if _net_manager.is_host():
		_apply_luoxi_special_game_card_reveal_for_peer(
			_net_manager.get_local_peer_id(),
			session_revision,
			card_index
		)
	elif _net_manager.is_client():
		rpc_to_host_requested.emit(
			&"net_luoxi_special_game_card_reveal_requested",
			[session_revision, card_index]
		)


func request_luoxi_special_game_finish(session_revision: int) -> void:
	if not is_bound():
		return
	if _net_manager.is_host():
		_apply_luoxi_special_game_finish_for_peer(
			_net_manager.get_local_peer_id(),
			session_revision
		)
	elif _net_manager.is_client():
		rpc_to_host_requested.emit(
			&"net_luoxi_special_game_finish_requested",
			[session_revision]
		)


func request_cheat_xirang() -> void:
	if not is_bound() or not OS.is_debug_build():
		return
	if _net_manager.is_host():
		_apply_cheat_xirang_for_peer(_net_manager.get_local_peer_id())
	elif _net_manager.is_client():
		rpc_to_host_requested.emit(&"net_cheat_xirang_requested", [])


func request_debug_collectible(config_path: String) -> void:
	if not is_bound() or not _mode_adapter.allows_debug_collectible_grants():
		return
	if _net_manager.is_host():
		apply_debug_collectible_for_peer(
			_net_manager.get_local_peer_id(),
			config_path
		)
	elif _net_manager.is_client():
		rpc_to_host_requested.emit(
			&"net_debug_collectible_requested",
			[config_path]
		)


func handle_remote_luoxi_collectible_offer_requested(peer_id: int) -> void:
	if not _admit_remote_luoxi_request(peer_id):
		return
	_send_or_create_luoxi_offer_for_peer(peer_id)


func handle_remote_luoxi_collectible_choice_requested(
	peer_id: int,
	choice_index: int,
	offer_revision: int
) -> void:
	if not _admit_remote_luoxi_request(peer_id):
		return
	_apply_luoxi_collectible_choice_for_peer(
		peer_id,
		choice_index,
		offer_revision,
		true
	)


func handle_remote_luoxi_collectible_refresh_requested(
	peer_id: int,
	offer_revision: int
) -> void:
	if not _admit_remote_luoxi_request(peer_id):
		return
	_apply_luoxi_collectible_refresh_for_peer(
		peer_id,
		offer_revision,
		true
	)


func handle_remote_luoxi_special_game_start_requested(peer_id: int) -> void:
	if not _admit_remote_luoxi_request(peer_id):
		return
	_apply_luoxi_special_game_start_for_peer(peer_id)


func handle_remote_luoxi_special_game_card_reveal_requested(
	peer_id: int,
	session_revision: int,
	card_index: int
) -> void:
	if not _admit_remote_luoxi_request(peer_id):
		return
	_apply_luoxi_special_game_card_reveal_for_peer(
		peer_id,
		session_revision,
		card_index
	)


func handle_remote_luoxi_special_game_finish_requested(
	peer_id: int,
	session_revision: int
) -> void:
	if not _admit_remote_luoxi_request(peer_id):
		return
	_apply_luoxi_special_game_finish_for_peer(peer_id, session_revision)


func handle_remote_cheat_xirang_requested(peer_id: int) -> void:
	if not _is_host_bound() or peer_id <= 0 or not OS.is_debug_build():
		return
	_apply_cheat_xirang_for_peer(peer_id)


func handle_remote_debug_collectible_requested(
	peer_id: int,
	config_path: String
) -> void:
	if (
		not _is_host_bound()
		or peer_id <= 0
		or not _mode_adapter.allows_debug_collectible_grants()
	):
		return
	apply_debug_collectible_for_peer(peer_id, config_path)


func receive_luoxi_collectible_offer_state(
	peer_id: int,
	offer_revision: int,
	config_paths: PackedStringArray,
	refresh_count: int,
	current_xirang: int,
	refresh_result_code: int = -1
) -> void:
	if not is_bound() or peer_id != _net_manager.get_local_peer_id():
		return
	_luoxi_offer_states_by_peer[peer_id] = {
		"offer_revision": offer_revision,
		"config_paths": Array(config_paths),
		"refresh_count": refresh_count,
	}
	var merchant := _mode_adapter.get_luoxi_merchant()
	if merchant == null or not is_instance_valid(merchant):
		return
	merchant.apply_authoritative_offer_state(
		offer_revision,
		config_paths,
		refresh_count,
		current_xirang,
		refresh_result_code
	)


func receive_luoxi_collectible_confirmation(
	peer_id: int,
	choice_index: int,
	config_path: String,
	result_code: int,
	_offer_revision: int = 0,
	inventory_snapshot: Dictionary = {}
) -> void:
	if not is_bound():
		return
	if not inventory_snapshot.is_empty():
		_run_state.apply_inventory_snapshot_for_peer(peer_id, inventory_snapshot)
	if (
		result_code == MerchantPurchaseResult.CollectibleClaim.SUCCESS
		and not config_path.is_empty()
	):
		var already_applied_on_host := (
			_net_manager.is_host()
			and peer_id == _net_manager.get_local_peer_id()
		)
		if not already_applied_on_host:
			_mode_adapter.runtime_record_luoxi_collectible_claim(peer_id)
			if inventory_snapshot.is_empty():
				var item := load(config_path) as PickupConfig
				if item != null:
					_run_state.try_add_item_for_peer(peer_id, item)
	elif result_code == MerchantPurchaseResult.CollectibleClaim.ALREADY_CLAIMED:
		_mode_adapter.runtime_mark_luoxi_collectible_claimed(peer_id)
	if peer_id != _net_manager.get_local_peer_id():
		return
	if result_code == MerchantPurchaseResult.CollectibleClaim.STALE_OFFER:
		return
	_mode_adapter.show_local_luoxi_collectible_result(result_code)


func receive_luoxi_collectible_refresh_confirmation(
	peer_id: int,
	result_code: int,
	refresh_count: int,
	current_xirang: int
) -> void:
	if not is_bound():
		return
	var player_node := _runtime.get_player_for_peer(peer_id)
	if player_node != null and is_instance_valid(player_node):
		var already_applied_on_host := (
			_net_manager.is_host()
			and peer_id == _net_manager.get_local_peer_id()
		)
		if not already_applied_on_host:
			var xirang_delta := current_xirang - player_node.current_xirang
			player_node.current_xirang = maxi(current_xirang, 0)
			player_node.xirang_changed.emit(
				player_node.current_xirang,
				xirang_delta
			)
	if peer_id == _net_manager.get_local_peer_id():
		_mode_adapter.show_local_luoxi_refresh_result(
			result_code,
			refresh_count,
			current_xirang
		)


func receive_luoxi_special_game_started(
	peer_id: int,
	result: Dictionary,
	inventory_snapshot: Dictionary = {}
) -> void:
	if not is_bound() or peer_id <= 0:
		return
	if not inventory_snapshot.is_empty():
		_run_state.apply_inventory_snapshot_for_peer(peer_id, inventory_snapshot)
	if peer_id == _net_manager.get_local_peer_id():
		_mode_adapter.show_local_luoxi_special_game_started(result)


func receive_luoxi_special_game_card_revealed(
	peer_id: int,
	result: Dictionary
) -> void:
	if not is_bound() or peer_id <= 0:
		return
	if peer_id == _net_manager.get_local_peer_id():
		_mode_adapter.show_local_luoxi_special_game_card_revealed(result)


func receive_luoxi_special_game_finished(
	peer_id: int,
	result: Dictionary,
	inventory_snapshot: Dictionary = {}
) -> void:
	if not is_bound() or peer_id <= 0:
		return
	if not inventory_snapshot.is_empty():
		_run_state.apply_inventory_snapshot_for_peer(peer_id, inventory_snapshot)
	var player_node := _runtime.get_player_for_peer(peer_id)
	if player_node != null and is_instance_valid(player_node):
		var confirmed_xirang := int(
			result.get("current_xirang", player_node.current_xirang)
		)
		var already_applied_on_host := (
			_net_manager.is_host()
			and peer_id == _net_manager.get_local_peer_id()
		)
		if not already_applied_on_host and confirmed_xirang != player_node.current_xirang:
			var xirang_delta := confirmed_xirang - player_node.current_xirang
			player_node.current_xirang = maxi(confirmed_xirang, 0)
			player_node.xirang_changed.emit(
				player_node.current_xirang,
				xirang_delta
			)
	if peer_id == _net_manager.get_local_peer_id():
		_mode_adapter.show_local_luoxi_special_game_finished(result)


func receive_cheat_xirang_confirmation(
	peer_id: int,
	current_xirang: int,
	added_amount: int
) -> void:
	if not is_bound():
		return
	var player_node := _runtime.get_player_for_peer(peer_id)
	if player_node == null or not is_instance_valid(player_node):
		return
	player_node.current_xirang = maxi(current_xirang, 0)
	player_node.xirang_changed.emit(
		player_node.current_xirang,
		maxi(added_amount, 0)
	)


func receive_debug_collectible_granted(
	peer_id: int,
	config_path: String,
	success: bool,
	inventory_snapshot: Dictionary = {}
) -> void:
	if not is_bound() or peer_id <= 0:
		return
	var player_node := _runtime.get_player_for_peer(peer_id)
	if player_node == null or not is_instance_valid(player_node):
		return
	if not inventory_snapshot.is_empty():
		_run_state.apply_inventory_snapshot_for_peer(peer_id, inventory_snapshot)
	elif success and not config_path.is_empty():
		var already_applied_on_host := (
			_net_manager.is_host()
			and peer_id == _net_manager.get_local_peer_id()
		)
		if not already_applied_on_host:
			var item := LuoxiMerchant.get_collectible_for_path(config_path)
			if item != null:
				_run_state.try_add_item_for_peer(peer_id, item)
	if peer_id == _net_manager.get_local_peer_id():
		_mode_adapter.show_debug_collectible_grant_result(config_path, success)


func send_offer_state_if_present(peer_id: int) -> void:
	var state := _luoxi_offer_states_by_peer.get(peer_id, {}) as Dictionary
	if not state.is_empty():
		_send_luoxi_offer_state_to_peer(peer_id, state)


func clear_offer_states() -> void:
	_luoxi_offer_states_by_peer.clear()


func capture_reconnect_state(peer_id: int) -> Dictionary:
	return {
		"luoxi_offer_state": (
			(_luoxi_offer_states_by_peer.get(peer_id, {}) as Dictionary).duplicate(true)
		),
		"luoxi_offer_revision": int(
			_luoxi_offer_revision_counters.get(peer_id, -1)
		),
	}


func restore_reconnect_state(peer_id: int, reconnect_state: Dictionary) -> void:
	if peer_id <= 0:
		return
	var offer_state := reconnect_state.get("luoxi_offer_state", {}) as Dictionary
	if not offer_state.is_empty():
		_luoxi_offer_states_by_peer[peer_id] = offer_state.duplicate(true)
	var offer_revision := int(reconnect_state.get("luoxi_offer_revision", -1))
	if offer_revision >= 0:
		_luoxi_offer_revision_counters[peer_id] = offer_revision


func clear_peer(peer_id: int) -> void:
	_luoxi_offer_states_by_peer.erase(peer_id)
	_luoxi_offer_revision_counters.erase(peer_id)
	_luoxi_transaction_rate_buckets.erase(peer_id)


func reset_session_state() -> void:
	_luoxi_offer_states_by_peer.clear()
	_luoxi_offer_revision_counters.clear()
	_luoxi_transaction_rate_buckets.clear()


func apply_debug_collectible_for_peer(
	peer_id: int,
	config_path: String
) -> void:
	if (
		not _is_host_bound()
		or peer_id <= 0
		or not _mode_adapter.allows_debug_collectible_grants()
	):
		return
	var item := LuoxiMerchant.get_collectible_for_path(config_path)
	var success := item != null and _run_state.try_add_item_for_peer(peer_id, item)
	var inventory_snapshot := _run_state.export_inventory_snapshot_for_peer(peer_id)
	rpc_broadcast_requested.emit(
		&"net_debug_collectible_granted",
		[peer_id, config_path, success, inventory_snapshot]
	)
	if peer_id == _net_manager.get_local_peer_id():
		receive_debug_collectible_granted(
			peer_id,
			config_path,
			success,
			inventory_snapshot
		)


func _admit_remote_luoxi_request(peer_id: int) -> bool:
	return (
		_is_host_bound()
		and peer_id > 0
		and _consume_peer_rate_token(
			_luoxi_transaction_rate_buckets,
			peer_id,
			LUOXI_TRANSACTION_RATE_PER_SECOND,
			LUOXI_TRANSACTION_RATE_BURST
		)
	)


func _send_or_create_luoxi_offer_for_peer(peer_id: int) -> void:
	if not _is_host_bound() or peer_id <= 0:
		return
	var state := _ensure_luoxi_offer_for_peer(peer_id)
	if not state.is_empty():
		_send_luoxi_offer_state_to_peer(peer_id, state)


func _ensure_luoxi_offer_for_peer(peer_id: int) -> Dictionary:
	var existing := _luoxi_offer_states_by_peer.get(peer_id, {}) as Dictionary
	if not existing.is_empty():
		return existing
	return _create_luoxi_offer_for_peer(peer_id, [])


func _create_luoxi_offer_for_peer(
	peer_id: int,
	excluded_paths: Array[String]
) -> Dictionary:
	if (
		not is_bound()
		or peer_id <= 0
		or _mode_adapter.runtime_has_luoxi_collectible_claimed(peer_id)
	):
		return {}
	var player_node := _runtime.get_player_for_peer(peer_id)
	var merchant := _mode_adapter.get_luoxi_merchant()
	if (
		player_node == null
		or not is_instance_valid(player_node)
		or merchant == null
		or not is_instance_valid(merchant)
	):
		return {}
	var config_paths := merchant.build_authoritative_offer_paths(
		player_node,
		excluded_paths,
		_luoxi_offer_random_generator
	)
	if config_paths.size() != LuoxiMerchant.get_choice_count():
		return {}
	return _commit_luoxi_offer_state(peer_id, config_paths)


func _commit_luoxi_offer_state(
	peer_id: int,
	config_paths: Array[String]
) -> Dictionary:
	var next_revision := int(_luoxi_offer_revision_counters.get(peer_id, 0)) + 1
	_luoxi_offer_revision_counters[peer_id] = next_revision
	var state := {
		"offer_revision": next_revision,
		"config_paths": config_paths.duplicate(),
		"refresh_count": (
			_mode_adapter.runtime_get_luoxi_collectible_refresh_count(peer_id)
		),
	}
	_luoxi_offer_states_by_peer[peer_id] = state
	return state


func _send_luoxi_offer_state_to_peer(
	peer_id: int,
	state: Dictionary,
	refresh_result_code: int = -1
) -> void:
	if not is_bound() or peer_id <= 0 or state.is_empty():
		return
	var player_node := _runtime.get_player_for_peer(peer_id)
	if player_node == null or not is_instance_valid(player_node):
		return
	var packed_paths := PackedStringArray(state.get("config_paths", []) as Array)
	var offer_revision := int(state.get("offer_revision", 0))
	var refresh_count := int(
		state.get(
			"refresh_count",
			_mode_adapter.runtime_get_luoxi_collectible_refresh_count(peer_id)
		)
	)
	var args := [
		peer_id,
		offer_revision,
		packed_paths,
		refresh_count,
		player_node.current_xirang,
		refresh_result_code,
	]
	if peer_id == _net_manager.get_local_peer_id():
		receive_luoxi_collectible_offer_state(
			peer_id,
			offer_revision,
			packed_paths,
			refresh_count,
			player_node.current_xirang,
			refresh_result_code
		)
		return
	if not _net_manager.is_peer_send_ready(peer_id):
		return
	rpc_to_peer_requested.emit(
		peer_id,
		&"net_luoxi_collectible_offer_state",
		args
	)


func _apply_luoxi_collectible_choice_for_peer(
	peer_id: int,
	choice_index: int,
	offer_revision: int = 0,
	require_offer_revision: bool = false
) -> void:
	if not _is_host_bound() or peer_id <= 0:
		return
	var state := _ensure_luoxi_offer_for_peer(peer_id)
	if state.is_empty():
		_send_luoxi_collectible_confirmation(
			peer_id,
			choice_index,
			"",
			MerchantPurchaseResult.CollectibleClaim.INVALID_PLAYER,
			0
		)
		return
	var authoritative_revision := int(state.get("offer_revision", 0))
	if (
		(require_offer_revision and offer_revision <= 0)
		or (offer_revision > 0 and offer_revision != authoritative_revision)
	):
		_send_luoxi_offer_state_to_peer(peer_id, state)
		_send_luoxi_collectible_confirmation(
			peer_id,
			choice_index,
			"",
			MerchantPurchaseResult.CollectibleClaim.STALE_OFFER,
			authoritative_revision
		)
		return
	var config_paths := state.get("config_paths", []) as Array
	if choice_index < 0 or choice_index >= config_paths.size():
		_send_luoxi_collectible_confirmation(
			peer_id,
			choice_index,
			"",
			MerchantPurchaseResult.CollectibleClaim.INVALID_PLAYER,
			authoritative_revision
		)
		return
	var resolved_config_path := str(config_paths[choice_index])
	var result_code := _mode_adapter.runtime_try_claim_luoxi_collectible_for_peer(
		peer_id,
		resolved_config_path
	)
	if result_code != MerchantPurchaseResult.CollectibleClaim.SUCCESS:
		resolved_config_path = ""
	_send_luoxi_collectible_confirmation(
		peer_id,
		choice_index,
		resolved_config_path,
		result_code,
		authoritative_revision
	)


func _send_luoxi_collectible_confirmation(
	peer_id: int,
	choice_index: int,
	config_path: String,
	result_code: int,
	offer_revision: int
) -> void:
	var inventory_snapshot := _run_state.export_inventory_snapshot_for_peer(peer_id)
	var args := [
		peer_id,
		choice_index,
		config_path,
		result_code,
		offer_revision,
		inventory_snapshot,
	]
	rpc_broadcast_requested.emit(&"net_luoxi_collectible_confirmed", args)
	if peer_id == _net_manager.get_local_peer_id():
		receive_luoxi_collectible_confirmation(
			peer_id,
			choice_index,
			config_path,
			result_code,
			offer_revision,
			inventory_snapshot
		)


func _apply_luoxi_collectible_refresh_for_peer(
	peer_id: int,
	offer_revision: int = 0,
	require_offer_revision: bool = false
) -> void:
	if not _is_host_bound() or peer_id <= 0:
		return
	var player_node := _runtime.get_player_for_peer(peer_id)
	if player_node == null or not is_instance_valid(player_node):
		return
	var state := _ensure_luoxi_offer_for_peer(peer_id)
	if state.is_empty():
		return
	var authoritative_revision := int(state.get("offer_revision", 0))
	if (
		(require_offer_revision and offer_revision <= 0)
		or (offer_revision > 0 and offer_revision != authoritative_revision)
	):
		_send_luoxi_offer_state_to_peer(
			peer_id,
			state,
			MerchantPurchaseResult.OfferRefresh.STALE_OFFER
		)
		return
	var previous_paths: Array[String] = []
	for config_path_variant in state.get("config_paths", []) as Array:
		previous_paths.append(str(config_path_variant))
	var merchant := _mode_adapter.get_luoxi_merchant()
	if merchant == null or not is_instance_valid(merchant):
		return
	# Keep the legacy order: roll replacement cards before charging the refresh.
	var replacement_paths := merchant.build_authoritative_offer_paths(
		player_node,
		previous_paths,
		_luoxi_offer_random_generator
	)
	if replacement_paths.size() != LuoxiMerchant.get_choice_count():
		_send_luoxi_offer_state_to_peer(
			peer_id,
			state,
			MerchantPurchaseResult.OfferRefresh.INVALID_PLAYER
		)
		return
	var result_code := (
		_mode_adapter.runtime_try_refresh_luoxi_collectibles_for_peer(peer_id)
	)
	if result_code == MerchantPurchaseResult.OfferRefresh.SUCCESS:
		state = _commit_luoxi_offer_state(peer_id, replacement_paths)
	else:
		state["refresh_count"] = (
			_mode_adapter.runtime_get_luoxi_collectible_refresh_count(peer_id)
		)
		_luoxi_offer_states_by_peer[peer_id] = state
	_send_luoxi_offer_state_to_peer(peer_id, state, result_code)


func _apply_luoxi_special_game_start_for_peer(peer_id: int) -> void:
	if not _is_host_bound() or peer_id <= 0:
		return
	var result := (
		_mode_adapter.runtime_try_start_luoxi_special_game_for_peer(peer_id)
	)
	var inventory_snapshot := _run_state.export_inventory_snapshot_for_peer(peer_id)
	var args := [peer_id, result, inventory_snapshot]
	rpc_broadcast_requested.emit(&"net_luoxi_special_game_started", args)
	if peer_id == _net_manager.get_local_peer_id():
		receive_luoxi_special_game_started(peer_id, result, inventory_snapshot)


func _apply_luoxi_special_game_card_reveal_for_peer(
	peer_id: int,
	session_revision: int,
	card_index: int
) -> void:
	if not _is_host_bound() or peer_id <= 0:
		return
	var result := _mode_adapter.runtime_try_reveal_luoxi_special_game_card_for_peer(
		peer_id,
		session_revision,
		card_index
	)
	var args := [peer_id, result]
	rpc_broadcast_requested.emit(&"net_luoxi_special_game_card_revealed", args)
	if peer_id == _net_manager.get_local_peer_id():
		receive_luoxi_special_game_card_revealed(peer_id, result)


func _apply_luoxi_special_game_finish_for_peer(
	peer_id: int,
	session_revision: int
) -> void:
	if not _is_host_bound() or peer_id <= 0:
		return
	var result := _mode_adapter.runtime_try_finish_luoxi_special_game_for_peer(
		peer_id,
		session_revision
	)
	var inventory_snapshot := _run_state.export_inventory_snapshot_for_peer(peer_id)
	var args := [peer_id, result, inventory_snapshot]
	rpc_broadcast_requested.emit(&"net_luoxi_special_game_finished", args)
	if peer_id == _net_manager.get_local_peer_id():
		receive_luoxi_special_game_finished(peer_id, result, inventory_snapshot)


func _apply_cheat_xirang_for_peer(peer_id: int) -> void:
	if not _is_host_bound() or peer_id <= 0 or not OS.is_debug_build():
		return
	var player_node := _runtime.get_player_for_peer(peer_id)
	if player_node == null or not is_instance_valid(player_node):
		return
	if not player_node.grant_cheat_xirang(CHEAT_XIRANG_AMOUNT):
		return
	rpc_broadcast_requested.emit(
		&"net_cheat_xirang_confirmed",
		[peer_id, player_node.current_xirang, CHEAT_XIRANG_AMOUNT]
	)


func _consume_peer_rate_token(
	buckets: Dictionary,
	peer_id: int,
	rate_per_second: float,
	burst: float
) -> bool:
	if peer_id <= 0 or rate_per_second <= 0.0 or burst <= 0.0:
		return false
	var now := _get_net_time()
	var bucket := buckets.get(peer_id, {}) as Dictionary
	if bucket.is_empty():
		bucket = {"tokens": burst, "last_time": now}
		buckets[peer_id] = bucket
	var tokens := minf(
		burst,
		float(bucket.get("tokens", burst))
		+ maxf(now - float(bucket.get("last_time", now)), 0.0) * rate_per_second
	)
	var accepted := tokens >= 1.0
	if accepted:
		tokens -= 1.0
	bucket["tokens"] = tokens
	bucket["last_time"] = now
	return accepted


func _is_host_bound() -> bool:
	return is_bound() and _net_manager.is_host()


func _get_net_time() -> float:
	return Time.get_ticks_msec() / 1000.0 - _net_time_origin
