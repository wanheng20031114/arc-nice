extends Node2D
class_name MpRogueRoute

const _NetConstants := preload("res://scene/multiplayer/net_constants.gd")
const MULTIPLAYER_LOBBY_SCENE_PATH := (
	"res://scene/multiplayer/multiplayer_lobby.tscn"
)
const STATE_DISCONNECTED := NetManagerStore.ConnectionState.DISCONNECTED
const STATE_LOADING_GAME := NetManagerStore.ConnectionState.LOADING_GAME
const STATE_IN_GAME := NetManagerStore.ConnectionState.IN_GAME
const AVATAR_POSE_FIELD_COUNT := 6
const AVATAR_SNAPSHOT_FIELD_COUNT := 7
const AVATAR_QUANTIZATION_SCALE := 10.0
const AVATAR_MAX_SEQUENCE := 0x7FFFFFFF
const AVATAR_FACING_MIN := 0
const AVATAR_FACING_MAX := 3
const AVATAR_ANIM_STATE_MAX := 15
const AVATAR_INITIAL_POSITION_TOLERANCE := 48.0
const AVATAR_POSITION_TOLERANCE := 8.0
const AVATAR_SPEED_TOLERANCE_MULTIPLIER := 1.75
const AVATAR_VELOCITY_TOLERANCE_MULTIPLIER := 2.5
const AVATAR_MAX_VALIDATION_SECONDS := 0.5
const AVATAR_CORRECTION_INTERVAL_MSEC := 84
const AVATAR_RECONNECT_POSE_RETENTION_MSEC := 90_000

var _route: Node = null
var _net_manager: Node = null
var _runtime_prepared := false
var _return_scheduled := false
var _snapshot_request_pending := false
var _latest_layout_snapshot: Dictionary = {}
var _latest_state_snapshot: Dictionary = {}
var _avatar_sync_time_left := 0.0
var _client_avatar_sequence := 0
var _host_avatar_snapshot_sequence := 0
var _last_host_avatar_snapshot_sequence := 0
var _last_client_avatar_sequences: Dictionary = {}
var _accepted_avatar_positions: Dictionary = {}
var _accepted_avatar_times_msec: Dictionary = {}
var _disconnected_avatar_poses: Dictionary = {}
var _last_avatar_correction_times_msec: Dictionary = {}
var _last_avatar_correction_sequences: Dictionary = {}


func _ready() -> void:
	_route = get_node_or_null("RogueRoute")
	_net_manager = get_node_or_null("/root/NetManager")
	if _net_manager == null or not _bind_route_contract():
		push_error("MpRogueRoute: P3 多人运行时契约不完整。")
		call_deferred("_return_to_lobby")
		return

	set_multiplayer_authority(_get_host_peer_id())
	_connect_net_manager_signals()
	if not _configure_route_players():
		push_error("MpRogueRoute: 无法按房间角色表创建 P3 玩家。")
		call_deferred("_return_to_lobby")
		return
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


func _physics_process(delta: float) -> void:
	if (
		not _runtime_prepared
		or _get_connection_state() != STATE_IN_GAME
		or _route == null
		or not bool(_route.call("is_route_ready"))
	):
		return
	_avatar_sync_time_left -= maxf(delta, 0.0)
	if _avatar_sync_time_left > 0.0:
		return
	_avatar_sync_time_left = _NetConstants.ROGUE_ROUTE_AVATAR_SYNC_INTERVAL_SECONDS
	if _is_host():
		_broadcast_avatar_snapshot()
	elif _is_client():
		_send_local_avatar_pose()


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
		&"configure_multiplayer_players",
		&"add_multiplayer_player",
		&"migrate_multiplayer_player",
		&"get_local_avatar_snapshot",
		&"apply_avatar_snapshot",
		&"clamp_avatar_position",
		&"is_avatar_position_in_world",
		&"get_player_for_peer",
		&"remove_multiplayer_player",
		&"get_route_revision",
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
	if not _net_manager.player_left.is_connected(_on_player_left):
		_net_manager.player_left.connect(_on_player_left)


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
	if _net_manager.player_left.is_connected(_on_player_left):
		_net_manager.player_left.disconnect(_on_player_left)


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
	old_peer_id: int,
	new_peer_id: int,
	player_name: String,
	character_id: StringName
) -> void:
	call_deferred(
		"_finish_player_reconnect",
		old_peer_id,
		new_peer_id,
		player_name,
		character_id
	)


func _finish_player_reconnect(
	old_peer_id: int,
	new_peer_id: int,
	player_name: String,
	character_id: StringName
) -> bool:
	if not is_inside_tree():
		return false
	if not _migrate_reconnected_player(
		old_peer_id,
		new_peer_id,
		player_name,
		character_id
	):
		return false
	if _is_host():
		_send_full_snapshot_to_peer(new_peer_id)
	return true


func _migrate_reconnected_player(
	old_peer_id: int,
	new_peer_id: int,
	player_name: String,
	character_id: StringName
) -> bool:
	if (
		old_peer_id <= 0
		or new_peer_id <= 0
		or old_peer_id == new_peer_id
		or _route == null
	):
		return false
	var preserved_pose := _get_avatar_pose_for_peer(old_peer_id)
	var old_player: Node = _route.call("get_player_for_peer", old_peer_id) as Node
	var migrated := false
	if old_player != null:
		migrated = bool(_route.call(
			"migrate_multiplayer_player",
			old_peer_id,
			new_peer_id,
			player_name,
			character_id
		))
	else:
		_prune_disconnected_avatar_poses()
		preserved_pose = _disconnected_avatar_poses.get(old_peer_id, {}) as Dictionary
		if preserved_pose.is_empty():
			push_warning(
				"MpRogueRoute: 重连 peer %d 缺少可迁移角色姿态。"
				% old_peer_id
			)
			return false
		migrated = bool(_route.call(
			"add_multiplayer_player",
			new_peer_id,
			player_name,
			character_id,
			preserved_pose.get("position", Vector2.ZERO) as Vector2
		))
	if not migrated:
		return false
	if not preserved_pose.is_empty():
		_route.call(
			"apply_avatar_snapshot",
			new_peer_id,
			preserved_pose.get("position", Vector2.ZERO) as Vector2,
			preserved_pose.get("velocity", Vector2.ZERO) as Vector2,
			int(preserved_pose.get("facing", 0)),
			int(preserved_pose.get("anim_state", 0)),
			true
		)
	_disconnected_avatar_poses.erase(old_peer_id)
	_clear_avatar_peer_sync_state(old_peer_id)
	_clear_avatar_peer_sync_state(new_peer_id)
	return true


func _on_player_left(peer_id: int) -> void:
	if _route != null:
		_prune_disconnected_avatar_poses()
		var preserved_pose := _get_avatar_pose_for_peer(peer_id)
		if not preserved_pose.is_empty():
			preserved_pose["stored_at_msec"] = Time.get_ticks_msec()
			_disconnected_avatar_poses[peer_id] = preserved_pose.duplicate(true)
		_route.call("remove_multiplayer_player", peer_id)
	_clear_avatar_peer_sync_state(peer_id)


func _on_host_layout_committed(layout: Dictionary, state: Dictionary) -> void:
	if not _is_host() or layout.is_empty() or state.is_empty():
		return
	_reset_avatar_validation_positions()
	_latest_layout_snapshot = layout.duplicate(true)
	_latest_state_snapshot = state.duplicate(true)
	if _get_connection_state() == STATE_IN_GAME:
		_broadcast_full_snapshot()


func _on_host_move_committed(delta: Dictionary) -> void:
	if not _is_host() or delta.is_empty():
		return
	_refresh_authoritative_state_cache()
	_reset_avatar_validation_positions()
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


func _configure_route_players() -> bool:
	if _route == null or _net_manager == null:
		return false
	var player_names := _net_manager.get("connected_players") as Dictionary
	var character_ids: Dictionary = {}
	if _net_manager.has_method("get_player_character_map"):
		character_ids = _net_manager.call("get_player_character_map") as Dictionary
	var local_peer_id := _get_local_peer_id()
	if local_peer_id <= 0 or not player_names.has(local_peer_id):
		return false
	var configured: Variant = _route.call(
		"configure_multiplayer_players",
		local_peer_id,
		player_names.duplicate(),
		character_ids.duplicate()
	)
	return configured is bool and bool(configured)


func _send_local_avatar_pose() -> void:
	if not _is_client() or not _has_network_peer():
		return
	var host_peer_id := _get_host_peer_id()
	if host_peer_id <= 0 or not _is_peer_send_ready(host_peer_id):
		return
	var snapshot := _route.call("get_local_avatar_snapshot") as Dictionary
	var packed_pose := _encode_avatar_pose(snapshot)
	if packed_pose.size() != AVATAR_POSE_FIELD_COUNT:
		return
	_client_avatar_sequence = _next_avatar_sequence(_client_avatar_sequence)
	net_route_avatar_input.rpc_id(
		host_peer_id,
		_client_avatar_sequence,
		int(_route.call("get_route_revision")),
		packed_pose
	)


func _broadcast_avatar_snapshot() -> void:
	if not _is_host() or not _has_network_peer():
		return
	var route_revision := int(_route.call("get_route_revision"))
	if route_revision < 0:
		return
	var host_peer_id := _get_host_peer_id()
	_enforce_host_avatar_bounds(host_peer_id)
	var player_names := _net_manager.get("connected_players") as Dictionary
	var peer_ids: Array[int] = []
	for peer_id_variant in player_names:
		var peer_id := int(peer_id_variant)
		if peer_id > 0 and _route.call("get_player_for_peer", peer_id) != null:
			peer_ids.append(peer_id)
	peer_ids.sort()
	var packed_states := PackedInt32Array()
	for peer_id in peer_ids:
		var pose := _get_avatar_pose_for_peer(peer_id)
		var packed_pose := _encode_avatar_pose(pose)
		if packed_pose.size() != AVATAR_POSE_FIELD_COUNT:
			continue
		packed_states.append(peer_id)
		packed_states.append_array(packed_pose)
	if packed_states.is_empty():
		return
	_host_avatar_snapshot_sequence = _next_avatar_sequence(
		_host_avatar_snapshot_sequence
	)
	for peer_id in _get_remote_player_peer_ids():
		if _is_peer_send_ready(peer_id):
			net_route_avatar_snapshot.rpc_id(
				peer_id,
				_host_avatar_snapshot_sequence,
				route_revision,
				packed_states
			)


func _get_avatar_pose_for_peer(peer_id: int) -> Dictionary:
	var player_node: Node = _route.call("get_player_for_peer", peer_id) as Node
	if player_node == null or not is_instance_valid(player_node):
		return {}
	return {
		"position": player_node.get("global_position") as Vector2,
		"velocity": player_node.get("velocity") as Vector2,
		"facing": int(player_node.call("get_multiplayer_facing_id")),
		"anim_state": int(player_node.call("get_multiplayer_anim_state")),
	}


func _enforce_host_avatar_bounds(host_peer_id: int) -> void:
	var pose := _get_avatar_pose_for_peer(host_peer_id)
	if pose.is_empty():
		return
	var position := pose.get("position", Vector2.ZERO) as Vector2
	if bool(_route.call("is_avatar_position_in_world", position)):
		return
	var safe_position := _route.call("clamp_avatar_position", position) as Vector2
	_route.call(
		"apply_avatar_snapshot",
		host_peer_id,
		safe_position,
		Vector2.ZERO,
		int(pose.get("facing", 0)),
		int(pose.get("anim_state", 0)),
		true
	)


func _encode_avatar_pose(snapshot: Dictionary) -> PackedInt32Array:
	if snapshot.is_empty():
		return PackedInt32Array()
	var position := snapshot.get("position", Vector2.INF) as Vector2
	var velocity := snapshot.get("velocity", Vector2.INF) as Vector2
	var facing := int(snapshot.get("facing", -1))
	var anim_state := int(snapshot.get("anim_state", -1))
	if (
		not position.is_finite()
		or not velocity.is_finite()
		or facing < AVATAR_FACING_MIN
		or facing > AVATAR_FACING_MAX
		or anim_state < 0
		or anim_state > AVATAR_ANIM_STATE_MAX
	):
		return PackedInt32Array()
	return PackedInt32Array([
		roundi(position.x * AVATAR_QUANTIZATION_SCALE),
		roundi(position.y * AVATAR_QUANTIZATION_SCALE),
		roundi(velocity.x * AVATAR_QUANTIZATION_SCALE),
		roundi(velocity.y * AVATAR_QUANTIZATION_SCALE),
		facing,
		anim_state,
	])


func _decode_avatar_pose(
	packed_pose: PackedInt32Array,
	start_offset: int = 0
) -> Dictionary:
	if start_offset < 0 or packed_pose.size() - start_offset < AVATAR_POSE_FIELD_COUNT:
		return {}
	var facing := int(packed_pose[start_offset + 4])
	var anim_state := int(packed_pose[start_offset + 5])
	if (
		facing < AVATAR_FACING_MIN
		or facing > AVATAR_FACING_MAX
		or anim_state < 0
		or anim_state > AVATAR_ANIM_STATE_MAX
	):
		return {}
	var inverse_scale := 1.0 / AVATAR_QUANTIZATION_SCALE
	var position := Vector2(
		float(packed_pose[start_offset]) * inverse_scale,
		float(packed_pose[start_offset + 1]) * inverse_scale
	)
	var velocity := Vector2(
		float(packed_pose[start_offset + 2]) * inverse_scale,
		float(packed_pose[start_offset + 3]) * inverse_scale
	)
	if not position.is_finite() or not velocity.is_finite():
		return {}
	return {
		"position": position,
		"velocity": velocity,
		"facing": facing,
		"anim_state": anim_state,
	}


func _next_avatar_sequence(current_sequence: int) -> int:
	return mini(current_sequence + 1, AVATAR_MAX_SEQUENCE)


@rpc("any_peer", "call_remote", "unreliable_ordered", 1)
func net_route_avatar_input(
	sequence: int,
	route_revision: int,
	packed_pose: PackedInt32Array
) -> void:
	if not _is_host():
		return
	var sender_id := multiplayer.get_remote_sender_id()
	if (
		sender_id <= 0
		or sender_id == _get_host_peer_id()
		or sequence <= int(_last_client_avatar_sequences.get(sender_id, 0))
		or sequence > AVATAR_MAX_SEQUENCE
	):
		return
	if not _accept_client_avatar_pose(
		sender_id,
		sequence,
		route_revision,
		packed_pose
	):
		_try_send_avatar_correction(sender_id, sequence)


func _accept_client_avatar_pose(
	peer_id: int,
	sequence: int,
	route_revision: int,
	packed_pose: PackedInt32Array
) -> bool:
	if (
		peer_id <= 0
		or peer_id == _get_host_peer_id()
		or sequence <= int(_last_client_avatar_sequences.get(peer_id, 0))
		or sequence > AVATAR_MAX_SEQUENCE
		or packed_pose.size() != AVATAR_POSE_FIELD_COUNT
		or _route.call("get_player_for_peer", peer_id) == null
	):
		return false
	if route_revision != int(_route.call("get_route_revision")):
		return false
	var pose := _decode_avatar_pose(packed_pose)
	if pose.is_empty():
		return false
	var position := pose.get("position", Vector2.ZERO) as Vector2
	var velocity := pose.get("velocity", Vector2.ZERO) as Vector2
	if not bool(_route.call("is_avatar_position_in_world", position)):
		return false
	var player_node: Node = _route.call("get_player_for_peer", peer_id) as Node
	var move_speed := maxf(float(player_node.get("move_speed")), 1.0)
	if velocity.length() > (
		move_speed * AVATAR_VELOCITY_TOLERANCE_MULTIPLIER
		+ AVATAR_POSITION_TOLERANCE
	):
		return false
	var now_msec := Time.get_ticks_msec()
	if not _accepted_avatar_positions.has(peer_id):
		var authoritative_position := player_node.get("global_position") as Vector2
		if authoritative_position.distance_to(position) > AVATAR_INITIAL_POSITION_TOLERANCE:
			return false
	else:
		var previous_position := _accepted_avatar_positions[peer_id] as Vector2
		var previous_time_msec := int(
			_accepted_avatar_times_msec.get(peer_id, now_msec)
		)
		var elapsed := clampf(
			float(now_msec - previous_time_msec) / 1000.0,
			1.0 / 120.0,
			AVATAR_MAX_VALIDATION_SECONDS
		)
		var allowed_distance := (
			move_speed * elapsed * AVATAR_SPEED_TOLERANCE_MULTIPLIER
			+ AVATAR_POSITION_TOLERANCE
		)
		if position.distance_to(previous_position) > allowed_distance:
			return false
	var applied := bool(_route.call(
		"apply_avatar_snapshot",
		peer_id,
		position,
		velocity,
		int(pose.get("facing", 0)),
		int(pose.get("anim_state", 0))
	))
	if applied:
		_accepted_avatar_positions[peer_id] = position
		_accepted_avatar_times_msec[peer_id] = now_msec
		_last_client_avatar_sequences[peer_id] = sequence
	return applied


func _try_send_avatar_correction(
	peer_id: int,
	input_sequence: int,
	now_msec: int = -1
) -> bool:
	if (
		not _is_host()
		or peer_id <= 0
		or not _has_network_peer()
		or not _is_peer_send_ready(peer_id)
	):
		return false
	var packed_pose := _encode_avatar_pose(_get_avatar_pose_for_peer(peer_id))
	if packed_pose.size() != AVATAR_POSE_FIELD_COUNT:
		return false
	if not _reserve_avatar_correction(peer_id, input_sequence, now_msec):
		return false
	net_route_avatar_corrected.rpc_id(
		peer_id,
		int(_route.call("get_route_revision")),
		packed_pose
	)
	return true


func _reserve_avatar_correction(
	peer_id: int,
	input_sequence: int,
	now_msec: int = -1
) -> bool:
	if (
		peer_id <= 0
		or input_sequence <= int(_last_client_avatar_sequences.get(peer_id, 0))
		or input_sequence > AVATAR_MAX_SEQUENCE
		or input_sequence == int(
			_last_avatar_correction_sequences.get(peer_id, -1)
		)
	):
		return false
	var resolved_now_msec := Time.get_ticks_msec() if now_msec < 0 else now_msec
	var previous_correction_msec := int(
		_last_avatar_correction_times_msec.get(
			peer_id,
			resolved_now_msec - AVATAR_CORRECTION_INTERVAL_MSEC
		)
	)
	if resolved_now_msec - previous_correction_msec < AVATAR_CORRECTION_INTERVAL_MSEC:
		return false
	_last_avatar_correction_times_msec[peer_id] = resolved_now_msec
	_last_avatar_correction_sequences[peer_id] = input_sequence
	return true


@rpc("authority", "call_remote", "unreliable_ordered", 2)
func net_route_avatar_snapshot(
	snapshot_sequence: int,
	route_revision: int,
	packed_states: PackedInt32Array
) -> void:
	if (
		not _is_client()
		or multiplayer.get_remote_sender_id() != _get_host_peer_id()
		or snapshot_sequence <= _last_host_avatar_snapshot_sequence
		or snapshot_sequence > AVATAR_MAX_SEQUENCE
		or route_revision != int(_route.call("get_route_revision"))
		or packed_states.is_empty()
		or packed_states.size() % AVATAR_SNAPSHOT_FIELD_COUNT != 0
	):
		return
	_last_host_avatar_snapshot_sequence = snapshot_sequence
	for state_offset in range(0, packed_states.size(), AVATAR_SNAPSHOT_FIELD_COUNT):
		var peer_id := int(packed_states[state_offset])
		if peer_id <= 0:
			continue
		var pose := _decode_avatar_pose(packed_states, state_offset + 1)
		if pose.is_empty():
			continue
		var position := pose.get("position", Vector2.ZERO) as Vector2
		if not bool(_route.call("is_avatar_position_in_world", position)):
			continue
		_route.call(
			"apply_avatar_snapshot",
			peer_id,
			position,
			pose.get("velocity", Vector2.ZERO) as Vector2,
			int(pose.get("facing", 0)),
			int(pose.get("anim_state", 0))
		)


@rpc("authority", "call_remote", "reliable", 0)
func net_route_avatar_corrected(
	route_revision: int,
	packed_pose: PackedInt32Array
) -> void:
	if (
		not _is_client()
		or multiplayer.get_remote_sender_id() != _get_host_peer_id()
		or route_revision != int(_route.call("get_route_revision"))
		or packed_pose.size() != AVATAR_POSE_FIELD_COUNT
	):
		return
	var pose := _decode_avatar_pose(packed_pose)
	if pose.is_empty():
		return
	_route.call(
		"apply_avatar_snapshot",
		_get_local_peer_id(),
		pose.get("position", Vector2.ZERO) as Vector2,
		pose.get("velocity", Vector2.ZERO) as Vector2,
		int(pose.get("facing", 0)),
		int(pose.get("anim_state", 0)),
		true
	)


func _reset_avatar_validation_positions() -> void:
	_accepted_avatar_positions.clear()
	_accepted_avatar_times_msec.clear()


func _reset_avatar_sync_state() -> void:
	_client_avatar_sequence = 0
	_last_host_avatar_snapshot_sequence = 0
	_last_client_avatar_sequences.clear()
	_last_avatar_correction_times_msec.clear()
	_last_avatar_correction_sequences.clear()
	_disconnected_avatar_poses.clear()
	_reset_avatar_validation_positions()


func _clear_avatar_peer_sync_state(peer_id: int) -> void:
	_last_client_avatar_sequences.erase(peer_id)
	_accepted_avatar_positions.erase(peer_id)
	_accepted_avatar_times_msec.erase(peer_id)
	_last_avatar_correction_times_msec.erase(peer_id)
	_last_avatar_correction_sequences.erase(peer_id)


func _prune_disconnected_avatar_poses() -> void:
	var now_msec := Time.get_ticks_msec()
	for peer_id_variant in _disconnected_avatar_poses.keys():
		var pose := _disconnected_avatar_poses.get(peer_id_variant, {}) as Dictionary
		if (
			pose.is_empty()
			or now_msec - int(pose.get("stored_at_msec", 0))
			> AVATAR_RECONNECT_POSE_RETENTION_MSEC
		):
			_disconnected_avatar_poses.erase(peer_id_variant)


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
	_reset_avatar_validation_positions()
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


func _get_local_peer_id() -> int:
	if multiplayer != null and multiplayer.has_multiplayer_peer():
		return multiplayer.get_unique_id()
	if _is_host():
		return _get_host_peer_id()
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
