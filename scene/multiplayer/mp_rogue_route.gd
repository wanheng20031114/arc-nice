extends Node2D
class_name MpRogueRoute

const MULTIPLAYER_LOBBY_SCENE_PATH := (
	"res://scene/multiplayer/multiplayer_lobby.tscn"
)
const STATE_DISCONNECTED := NetManagerStore.ConnectionState.DISCONNECTED
const STATE_LOADING_GAME := NetManagerStore.ConnectionState.LOADING_GAME
const STATE_IN_GAME := NetManagerStore.ConnectionState.IN_GAME

var _route: Node = null
var _net_manager: Node = null
var _runtime_prepared := false
var _return_scheduled := false
var _snapshot_request_pending := false
var _latest_layout_snapshot: Dictionary = {}
var _latest_state_snapshot: Dictionary = {}


func _ready() -> void:
	_route = get_node_or_null("RogueRoute")
	_net_manager = get_node_or_null("/root/NetManager")
	if _net_manager == null or not _bind_route_contract():
		push_error("MpRogueRoute: P3 多人运行时契约不完整。")
		call_deferred("_return_to_lobby")
		return

	set_multiplayer_authority(_get_host_peer_id())
	_connect_net_manager_signals()
	if _is_host():
		_route.call("set_authority_enabled", true)
		var start_result: Variant = _route.call(
			"start_authoritative_session",
			_generate_session_seed(),
			false
		)
		if start_result is bool and not bool(start_result):
			push_error("MpRogueRoute: Host 无法生成 P3 路线。")
			call_deferred("_return_to_lobby")
			return
		_refresh_authoritative_snapshot_cache()
	elif _is_client():
		_route.call("set_authority_enabled", false)
		_route.call("start_client_waiting")
	else:
		push_warning("MpRogueRoute: 启动时没有有效多人连接，返回大厅。")
		call_deferred("_return_to_lobby")
		return

	_runtime_prepared = true
	call_deferred("_report_game_loaded")
	if _get_connection_state() == STATE_IN_GAME:
		call_deferred("_synchronize_after_barrier")


func _exit_tree() -> void:
	_disconnect_net_manager_signals()
	_disconnect_route_signals()


func is_runtime_preparation_complete() -> bool:
	return _runtime_prepared


func get_runtime_preparation_progress() -> Dictionary:
	return {
		"stage": (
			"路线框架已准备"
			if _runtime_prepared
			else "正在创建多人路线框架"
		),
		"completed": 1 if _runtime_prepared else 0,
		"total": 1,
	}


func _bind_route_contract() -> bool:
	if _route == null:
		return false
	for method_name in [
		&"start_authoritative_session",
		&"start_client_waiting",
		&"apply_full_snapshot",
		&"apply_move_delta",
		&"export_layout_snapshot",
		&"export_state_snapshot",
		&"is_route_ready",
		&"set_authority_enabled",
	]:
		if not _route.has_method(method_name):
			return false
	for signal_name in [
		&"host_layout_committed",
		&"host_move_committed",
		&"return_requested",
	]:
		if not _route.has_signal(signal_name):
			return false
	_route.connect(
		&"host_layout_committed",
		Callable(self, "_on_host_layout_committed")
	)
	_route.connect(
		&"host_move_committed",
		Callable(self, "_on_host_move_committed")
	)
	_route.connect(&"return_requested", Callable(self, "_on_return_requested"))
	return true


func _disconnect_route_signals() -> void:
	if _route == null or not is_instance_valid(_route):
		return
	for signal_contract in [
		[&"host_layout_committed", Callable(self, "_on_host_layout_committed")],
		[&"host_move_committed", Callable(self, "_on_host_move_committed")],
		[&"return_requested", Callable(self, "_on_return_requested")],
	]:
		var signal_name := signal_contract[0] as StringName
		var callback := signal_contract[1] as Callable
		if _route.is_connected(signal_name, callback):
			_route.disconnect(signal_name, callback)


func _connect_net_manager_signals() -> void:
	if not _net_manager.connection_state_changed.is_connected(
		_on_connection_state_changed
	):
		_net_manager.connection_state_changed.connect(_on_connection_state_changed)
	if not _net_manager.player_reconnected.is_connected(_on_player_reconnected):
		_net_manager.player_reconnected.connect(_on_player_reconnected)


func _disconnect_net_manager_signals() -> void:
	if _net_manager == null or not is_instance_valid(_net_manager):
		return
	if _net_manager.connection_state_changed.is_connected(
		_on_connection_state_changed
	):
		_net_manager.connection_state_changed.disconnect(
			_on_connection_state_changed
		)
	if _net_manager.player_reconnected.is_connected(_on_player_reconnected):
		_net_manager.player_reconnected.disconnect(_on_player_reconnected)


func _report_game_loaded() -> void:
	if (
		_runtime_prepared
		and is_inside_tree()
		and _get_connection_state() == STATE_LOADING_GAME
		and _net_manager.has_method("report_game_loaded")
	):
		_net_manager.call("report_game_loaded")


func _synchronize_after_barrier() -> void:
	if _is_host():
		_broadcast_full_snapshot()
	elif _is_client():
		_request_full_snapshot()


func _on_connection_state_changed(new_state: int) -> void:
	if new_state == STATE_DISCONNECTED:
		_return_to_lobby()
	elif new_state == STATE_IN_GAME:
		_synchronize_after_barrier()


func _on_player_reconnected(
	_old_peer_id: int,
	new_peer_id: int,
	_player_name: String,
	_character_id: StringName
) -> void:
	if _is_host():
		_send_full_snapshot_to_peer(new_peer_id)


func _on_host_layout_committed(layout: Dictionary, state: Dictionary) -> void:
	if not _is_host() or layout.is_empty() or state.is_empty():
		return
	_latest_layout_snapshot = layout.duplicate(true)
	_latest_state_snapshot = state.duplicate(true)
	if _get_connection_state() == STATE_IN_GAME:
		_broadcast_full_snapshot()


func _on_host_move_committed(delta: Dictionary) -> void:
	if not _is_host() or delta.is_empty():
		return
	_refresh_authoritative_state_cache()
	if _get_connection_state() != STATE_IN_GAME or not _has_network_peer():
		return
	for peer_id in _get_remote_player_peer_ids():
		if _is_peer_send_ready(peer_id):
			net_route_move_delta.rpc_id(peer_id, delta.duplicate(true))


func _refresh_authoritative_snapshot_cache() -> bool:
	if (
		_route == null
		or not bool(_route.call("is_route_ready"))
	):
		return false
	var layout := _route.call("export_layout_snapshot") as Dictionary
	var state := _route.call("export_state_snapshot") as Dictionary
	if layout.is_empty() or state.is_empty():
		return false
	_latest_layout_snapshot = layout.duplicate(true)
	_latest_state_snapshot = state.duplicate(true)
	return true


func _refresh_authoritative_state_cache() -> bool:
	if _route == null or not bool(_route.call("is_route_ready")):
		return false
	var state := _route.call("export_state_snapshot") as Dictionary
	if state.is_empty():
		return false
	_latest_state_snapshot = state.duplicate(true)
	return true


func _broadcast_full_snapshot() -> void:
	if not _is_host() or not _has_network_peer():
		return
	if not _refresh_authoritative_snapshot_cache():
		return
	for peer_id in _get_remote_player_peer_ids():
		_send_full_snapshot_to_peer(peer_id)


func _send_full_snapshot_to_peer(peer_id: int) -> void:
	if (
		not _is_host()
		or peer_id <= 0
		or peer_id == _get_host_peer_id()
		or not _has_network_peer()
		or not _is_peer_send_ready(peer_id)
		or not _refresh_authoritative_snapshot_cache()
	):
		return
	net_route_full_snapshot.rpc_id(
		peer_id,
		_latest_layout_snapshot.duplicate(true),
		_latest_state_snapshot.duplicate(true)
	)


func _request_full_snapshot() -> void:
	if (
		not _is_client()
		or _snapshot_request_pending
		or not _has_network_peer()
	):
		return
	var host_peer_id := _get_host_peer_id()
	if host_peer_id <= 0:
		return
	_snapshot_request_pending = true
	net_request_route_full_snapshot.rpc_id(host_peer_id)


@rpc("any_peer", "call_remote", "reliable", 0)
func net_request_route_full_snapshot() -> void:
	if not _is_host():
		return
	var sender_id := multiplayer.get_remote_sender_id()
	if sender_id <= 0 or sender_id == _get_host_peer_id():
		return
	_send_full_snapshot_to_peer(sender_id)


@rpc("authority", "call_remote", "reliable", 0)
func net_route_full_snapshot(layout: Dictionary, state: Dictionary) -> void:
	_apply_full_snapshot_from_peer(
		multiplayer.get_remote_sender_id(),
		layout,
		state
	)


func _apply_full_snapshot_from_peer(
	sender_id: int,
	layout: Dictionary,
	state: Dictionary
) -> bool:
	if (
		not _is_client()
		or sender_id != _get_host_peer_id()
		or layout.is_empty()
		or state.is_empty()
		or _route == null
	):
		return false
	var apply_result: Variant = _route.call(
		"apply_full_snapshot",
		layout.duplicate(true),
		state.duplicate(true)
	)
	if apply_result is bool and not bool(apply_result):
		return false
	if not bool(_route.call("is_route_ready")):
		return false
	_snapshot_request_pending = false
	return true


@rpc("authority", "call_remote", "reliable", 0)
func net_route_move_delta(delta: Dictionary) -> void:
	_apply_move_delta_from_peer(multiplayer.get_remote_sender_id(), delta)


func _apply_move_delta_from_peer(sender_id: int, delta: Dictionary) -> bool:
	if (
		not _is_client()
		or sender_id != _get_host_peer_id()
		or delta.is_empty()
		or _route == null
	):
		return false
	var apply_result: Variant = _route.call(
		"apply_move_delta",
		delta.duplicate(true)
	)
	if apply_result is bool and bool(apply_result):
		return true
	if apply_result == null and bool(_route.call("is_route_ready")):
		return true
	_request_full_snapshot()
	return false


func _on_return_requested() -> void:
	if _net_manager != null and _net_manager.has_method("disconnect_from_game"):
		_net_manager.call("disconnect_from_game")
	_return_to_lobby()


func _return_to_lobby() -> void:
	if _return_scheduled:
		return
	_return_scheduled = true
	call_deferred("_change_to_lobby")


func _change_to_lobby() -> void:
	var tree := get_tree()
	if tree != null:
		tree.change_scene_to_file(MULTIPLAYER_LOBBY_SCENE_PATH)


func _generate_session_seed() -> int:
	return int(Time.get_unix_time_from_system() * 1_000_000.0) ^ Time.get_ticks_usec()


func _get_connection_state() -> int:
	if _net_manager == null:
		return STATE_DISCONNECTED
	return int(_net_manager.get("connection_state"))


func _get_host_peer_id() -> int:
	if _net_manager != null and _net_manager.has_method("get_host_peer_id"):
		return int(_net_manager.call("get_host_peer_id"))
	return 0


func _is_host() -> bool:
	return (
		_net_manager != null
		and _net_manager.has_method("is_host")
		and bool(_net_manager.call("is_host"))
	)


func _is_client() -> bool:
	return (
		_net_manager != null
		and _net_manager.has_method("is_client")
		and bool(_net_manager.call("is_client"))
	)


func _is_peer_send_ready(peer_id: int) -> bool:
	return (
		_net_manager != null
		and _net_manager.has_method("is_peer_send_ready")
		and bool(_net_manager.call("is_peer_send_ready", peer_id))
	)


func _get_remote_player_peer_ids() -> Array[int]:
	var result: Array[int] = []
	if _net_manager == null:
		return result
	var connected_players := _net_manager.get("connected_players") as Dictionary
	var host_peer_id := _get_host_peer_id()
	for peer_id_variant in connected_players:
		var peer_id := int(peer_id_variant)
		if peer_id > 0 and peer_id != host_peer_id:
			result.append(peer_id)
	result.sort()
	return result


func _has_network_peer() -> bool:
	return multiplayer != null and multiplayer.has_multiplayer_peer()
