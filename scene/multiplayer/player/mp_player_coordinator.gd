extends Node
class_name MpPlayerCoordinator

const _NetConstants := preload("res://scene/multiplayer/net_constants.gd")
const GAME_RUNTIME_CLIENT_VIEW := 2
const SHARED_SNAPSHOT_COHORT_ID := -1
const PLAYER_DELTA_KEYFRAME_INTERVAL_SECONDS := 0.5


class HostSnapshotBatch:
	extends RefCounted

	var peer_ids: Array[int] = []
	var host_timestamp := 0.0
	var data := PackedByteArray()
	var entity_count := 0

	func is_empty() -> bool:
		return peer_ids.is_empty() or data.is_empty() or entity_count <= 0


var _runtime: CombatRuntimeBase = null
var _snapshot_manager := SnapshotManager.new()
var _visual_interpolators: Dictionary[int, NetInterpolator] = {}
var _teleport_cutoff_sequences: Dictionary[int, int] = {}
var _pending_authoritative_teleports: Dictionary[int, Dictionary] = {}
var _character_mismatch_warnings: Dictionary[int, bool] = {}
var _latest_client_states: Dictionary[int, Dictionary] = {}
var _applied_health_revisions: Dictionary[int, int] = {}
var _last_keyframe_time_by_peer: Dictionary[int, float] = {}
var _snapshot_cohort_peers: Dictionary[int, bool] = {}
var _host_snapshot_sequence := 0
var _snapshot_encode_count := 0


func bind_runtime(runtime_instance: CombatRuntimeBase) -> void:
	assert(runtime_instance != null, "MpPlayerCoordinator 缺少战斗运行时。")
	if _runtime == runtime_instance:
		return
	if _runtime != null:
		reset_session_state()
	_runtime = runtime_instance


func unbind_runtime(runtime_instance: CombatRuntimeBase) -> void:
	if _runtime != runtime_instance:
		return
	_runtime = null
	reset_session_state()


func is_bound() -> bool:
	return _runtime != null and is_instance_valid(_runtime)


func sync_snapshot_cohort_readiness(ready_peer_ids: Array[int]) -> void:
	var ready_lookup: Dictionary[int, bool] = {}
	for peer_id in ready_peer_ids:
		if peer_id > 0:
			ready_lookup[peer_id] = true
	for peer_id_variant in _snapshot_cohort_peers.keys():
		var peer_id := int(peer_id_variant)
		if ready_lookup.has(peer_id):
			continue
		_snapshot_cohort_peers.erase(peer_id)
		_last_keyframe_time_by_peer.erase(peer_id)
	if _snapshot_cohort_peers.is_empty():
		_snapshot_manager.clear_player_send_baseline(SHARED_SNAPSHOT_COHORT_ID)


func build_host_snapshot_batch(
	states: Array[SnapshotManager.PlayerState],
	ready_peer_ids: Array[int],
	host_timestamp: float,
	health_revisions: Dictionary
) -> HostSnapshotBatch:
	if not is_bound() or ready_peer_ids.is_empty() or states.is_empty():
		return null
	_apply_latest_client_states(states)
	_host_snapshot_sequence += 1
	for state in states:
		if state == null:
			continue
		state.sequence = _host_snapshot_sequence
		state.health_revision = int(health_revisions.get(state.peer_id, 0))
	var force_keyframe := _snapshot_cohort_requires_keyframe(
		ready_peer_ids,
		host_timestamp
	)
	var data := _snapshot_manager.encode_player_snapshots_for_cohort(
		SHARED_SNAPSHOT_COHORT_ID,
		states,
		force_keyframe
	)
	if data.is_empty():
		return null
	_snapshot_encode_count += 1
	_commit_snapshot_cohort_send(
		ready_peer_ids,
		host_timestamp,
		force_keyframe
	)
	var batch := HostSnapshotBatch.new()
	batch.peer_ids.assign(ready_peer_ids)
	batch.host_timestamp = host_timestamp
	batch.data = data
	batch.entity_count = states.size()
	return batch


func apply_authoritative_snapshot(
	snapshot_time: float,
	data: PackedByteArray,
	local_peer_id: int,
	local_tango_prediction_active: bool
) -> PackedInt32Array:
	var stale_peer_ids := PackedInt32Array()
	if not is_bound() or int(_runtime.runtime_mode) != GAME_RUNTIME_CLIENT_VIEW:
		return stale_peer_ids
	var states := _snapshot_manager.decode_player_snapshots_with_baseline(data)
	var snapshot_has_full_roster := _is_complete_snapshot_batch(data, states.size())
	var seen_player_ids: Dictionary[int, bool] = {}
	for state in states:
		var player_state := state as SnapshotManager.PlayerState
		if player_state == null or player_state.peer_id <= 0:
			continue
		seen_player_ids[player_state.peer_id] = true
		var player_node := _runtime.get_player_for_peer(player_state.peer_id)
		if player_node != null and is_instance_valid(player_node):
			try_apply_pending_authoritative_teleport(
				player_state.peer_id,
				local_peer_id,
				snapshot_time
			)
			player_node = _runtime.get_player_for_peer(player_state.peer_id)
		var accept_motion := accept_snapshot_motion_after_teleport(
			player_state.peer_id,
			player_state.sequence
		)
		if player_node != null and is_instance_valid(player_node):
			if player_node.get_character_id() != player_state.character_id:
				_warn_character_snapshot_mismatch(
					player_state.peer_id,
					player_node.get_character_id(),
					player_state.character_id
				)
				continue
			_apply_primary_cooldown_ratio(
				player_node,
				player_state.primary_cooldown_ratio,
				player_state.facing,
				player_state.peer_id == local_peer_id
				and local_tango_prediction_active
			)
		if player_state.peer_id == local_peer_id:
			_apply_realtime_snapshot(player_node, player_state)
			continue
		if not accept_motion:
			_apply_realtime_snapshot(player_node, player_state)
			continue
		var interpolator := _visual_interpolators.get(
			player_state.peer_id
		) as NetInterpolator
		if interpolator == null:
			interpolator = _create_interpolator()
			_visual_interpolators[player_state.peer_id] = interpolator
		interpolator.push_snapshot(
			snapshot_time,
			player_state.position,
			player_state.velocity,
			player_state.facing,
			player_state.anim_state,
			0,
			false
		)
		_apply_realtime_snapshot(player_node, player_state)
	if not snapshot_has_full_roster or seen_player_ids.is_empty():
		return stale_peer_ids
	var resolved_local_peer_id := local_peer_id
	if resolved_local_peer_id <= 0:
		resolved_local_peer_id = _runtime.multiplayer_local_peer_id
	for peer_id_variant in _runtime.peer_players.keys():
		var peer_id := int(peer_id_variant)
		if peer_id == resolved_local_peer_id or seen_player_ids.has(peer_id):
			continue
		stale_peer_ids.append(peer_id)
	return stale_peer_ids


func interpolate_remote_players(current_time: float, local_peer_id: int) -> void:
	if not is_bound() or int(_runtime.runtime_mode) != GAME_RUNTIME_CLIENT_VIEW:
		return
	for peer_id_variant in _visual_interpolators:
		var peer_id := int(peer_id_variant)
		if peer_id == local_peer_id:
			continue
		var interpolator := _visual_interpolators.get(peer_id) as NetInterpolator
		var player_node := _runtime.get_player_for_peer(peer_id)
		if interpolator == null or player_node == null or not is_instance_valid(player_node):
			continue
		var frame_state := interpolator.get_current_state(current_time)
		player_node.apply_multiplayer_snapshot_motion(
			interpolator.get_interpolated_position(current_time),
			interpolator.get_interpolated_velocity(current_time),
			frame_state.facing,
			frame_state.anim_state
		)


func remember_latest_client_state(
	is_host: bool,
	peer_id: int,
	player_position: Vector2,
	player_velocity: Vector2,
	facing_id: int,
	anim_state: int
) -> void:
	if not is_host or peer_id <= 0:
		return
	_latest_client_states[peer_id] = {
		"position": player_position,
		"velocity": player_velocity,
		"facing": facing_id,
		"anim_state": anim_state,
	}


func erase_latest_client_state(peer_id: int) -> void:
	_latest_client_states.erase(peer_id)


func has_latest_client_state(peer_id: int) -> bool:
	return _latest_client_states.has(peer_id)


func get_latest_client_state(peer_id: int) -> Dictionary:
	return (_latest_client_states.get(peer_id, {}) as Dictionary).duplicate(true)


func queue_authoritative_teleport(
	peer_id: int,
	target_position: Vector2,
	snapshot_sequence_cutoff: int,
	local_peer_id: int,
	snapshot_time: float
) -> bool:
	if (
		peer_id <= 0
		or snapshot_sequence_cutoff < 0
		or not _is_finite_vector2(target_position)
	):
		return false
	_teleport_cutoff_sequences[peer_id] = maxi(
		snapshot_sequence_cutoff,
		int(_teleport_cutoff_sequences.get(peer_id, -1))
	)
	_pending_authoritative_teleports[peer_id] = {
		"position": target_position,
		"snapshot_sequence_cutoff": snapshot_sequence_cutoff,
	}
	try_apply_pending_authoritative_teleport(
		peer_id,
		local_peer_id,
		snapshot_time
	)
	return true


func try_apply_pending_authoritative_teleport(
	peer_id: int,
	local_peer_id: int,
	snapshot_time: float
) -> bool:
	if not is_bound() or peer_id <= 0:
		return false
	var pending := _pending_authoritative_teleports.get(peer_id, {}) as Dictionary
	if pending.is_empty():
		return false
	var player_node := _runtime.get_player_for_peer(peer_id)
	if player_node == null or not is_instance_valid(player_node):
		return false
	var target_position := pending.get("position", Vector2.ZERO) as Vector2
	apply_authoritative_teleport_to_player(player_node, target_position)
	if int(_runtime.runtime_mode) == GAME_RUNTIME_CLIENT_VIEW and peer_id != local_peer_id:
		reset_visual_interpolator_to_state(
			peer_id,
			target_position,
			Vector2.ZERO,
			player_node.get_multiplayer_facing_id(),
			player_node.get_multiplayer_anim_state(),
			snapshot_time
		)
	_pending_authoritative_teleports.erase(peer_id)
	return true


func accept_snapshot_motion_after_teleport(
	peer_id: int,
	snapshot_sequence: int
) -> bool:
	var cutoff := int(_teleport_cutoff_sequences.get(peer_id, -1))
	if cutoff < 0:
		return true
	if snapshot_sequence <= cutoff:
		return false
	_teleport_cutoff_sequences.erase(peer_id)
	return true


func reset_visual_interpolator_to_state(
	peer_id: int,
	player_position: Vector2,
	player_velocity: Vector2,
	facing_id: int,
	anim_state: int,
	snapshot_time: float
) -> void:
	if peer_id <= 0:
		return
	var interpolator := _visual_interpolators.get(peer_id) as NetInterpolator
	if interpolator == null:
		interpolator = _create_interpolator()
		_visual_interpolators[peer_id] = interpolator
	interpolator.clear()
	interpolator.push_snapshot(
		snapshot_time,
		player_position,
		player_velocity,
		facing_id,
		anim_state,
		0,
		false
	)


func apply_authoritative_teleport_to_player(
	player_node: Player,
	target_position: Vector2
) -> bool:
	if (
		player_node == null
		or not is_instance_valid(player_node)
		or not _is_finite_vector2(target_position)
	):
		return false
	var smoothing_was_enabled := player_node.is_multiplayer_visual_smoothing_enabled()
	if smoothing_was_enabled:
		player_node.set_multiplayer_visual_smoothing_enabled(false)
	player_node.global_position = target_position
	player_node.velocity = Vector2.ZERO
	player_node.reset_physics_interpolation()
	if smoothing_was_enabled:
		player_node.set_multiplayer_visual_smoothing_enabled(true)
	return true


func apply_local_state_correction(
	corrected_position: Vector2,
	corrected_velocity: Vector2
) -> void:
	if not is_bound() or _runtime.player == null:
		return
	_runtime.player.global_position = corrected_position
	_runtime.player.velocity = corrected_velocity


func restore_reconnected_player_snapshot(
	player_node: Player,
	player_state: SnapshotManager.PlayerState,
	snapshot_time: float,
	is_host: bool,
	local_peer_id: int,
	local_tango_prediction_active: bool
) -> void:
	if player_node == null or player_state == null or not is_instance_valid(player_node):
		return
	player_node.apply_multiplayer_snapshot_motion(
		player_state.position,
		player_state.velocity,
		player_state.facing,
		player_state.anim_state
	)
	_apply_primary_cooldown_ratio(
		player_node,
		player_state.primary_cooldown_ratio,
		player_state.facing,
		player_state.peer_id == local_peer_id and local_tango_prediction_active
	)
	_apply_realtime_snapshot(player_node, player_state)
	if is_host:
		remember_latest_client_state(
			true,
			player_state.peer_id,
			player_state.position,
			player_state.velocity,
			player_state.facing,
			player_state.anim_state
		)
	else:
		reset_visual_interpolator_to_state(
			player_state.peer_id,
			player_state.position,
			player_state.velocity,
			player_state.facing,
			player_state.anim_state,
			snapshot_time
		)


func get_host_snapshot_sequence() -> int:
	return _host_snapshot_sequence


func get_snapshot_encode_count() -> int:
	return _snapshot_encode_count


func get_snapshot_cohort_size() -> int:
	return _snapshot_cohort_peers.size()


func get_applied_health_revision(peer_id: int) -> int:
	return int(_applied_health_revisions.get(peer_id, 0))


func set_applied_health_revision(peer_id: int, health_revision: int) -> void:
	if peer_id <= 0 or health_revision < 0:
		return
	_applied_health_revisions[peer_id] = health_revision


func mark_health_revision_applied(peer_id: int, health_revision: int) -> void:
	if peer_id <= 0 or health_revision < 0:
		return
	_applied_health_revisions[peer_id] = maxi(
		get_applied_health_revision(peer_id),
		health_revision
	)


func get_visual_interpolator(peer_id: int) -> NetInterpolator:
	return _visual_interpolators.get(peer_id) as NetInterpolator


func has_visual_interpolator(peer_id: int) -> bool:
	return _visual_interpolators.has(peer_id)


func get_visual_interpolator_count() -> int:
	return _visual_interpolators.size()


func has_pending_authoritative_teleport(peer_id: int) -> bool:
	return _pending_authoritative_teleports.has(peer_id)


func clear_peer(peer_id: int) -> void:
	if peer_id <= 0:
		return
	_snapshot_manager.clear_peer_delta_cache(peer_id)
	_snapshot_cohort_peers.erase(peer_id)
	_last_keyframe_time_by_peer.erase(peer_id)
	if _snapshot_cohort_peers.is_empty():
		_snapshot_manager.clear_player_send_baseline(SHARED_SNAPSHOT_COHORT_ID)
	_visual_interpolators.erase(peer_id)
	_teleport_cutoff_sequences.erase(peer_id)
	_pending_authoritative_teleports.erase(peer_id)
	_character_mismatch_warnings.erase(peer_id)
	_latest_client_states.erase(peer_id)
	_applied_health_revisions.erase(peer_id)


func reset_session_state() -> void:
	_snapshot_manager.reset_delta_cache()
	_visual_interpolators.clear()
	_teleport_cutoff_sequences.clear()
	_pending_authoritative_teleports.clear()
	_character_mismatch_warnings.clear()
	_latest_client_states.clear()
	_applied_health_revisions.clear()
	_last_keyframe_time_by_peer.clear()
	_snapshot_cohort_peers.clear()
	_host_snapshot_sequence = 0
	_snapshot_encode_count = 0


func _apply_latest_client_states(states: Array[SnapshotManager.PlayerState]) -> void:
	if _latest_client_states.is_empty():
		return
	for state in states:
		if state == null or state.is_dead:
			continue
		var latest := _latest_client_states.get(state.peer_id, {}) as Dictionary
		if latest.is_empty():
			continue
		state.position = latest.get("position", state.position) as Vector2
		state.velocity = latest.get("velocity", state.velocity) as Vector2
		state.facing = int(latest.get("facing", state.facing))
		state.anim_state = int(latest.get("anim_state", state.anim_state))


func _snapshot_cohort_requires_keyframe(
	ready_peer_ids: Array[int],
	snapshot_time: float
) -> bool:
	if ready_peer_ids.is_empty():
		return false
	if _snapshot_cohort_peers.size() != ready_peer_ids.size():
		return true
	for peer_id in ready_peer_ids:
		if (
			not _snapshot_cohort_peers.has(peer_id)
			or not _last_keyframe_time_by_peer.has(peer_id)
		):
			return true
		var last_keyframe_time := float(
			_last_keyframe_time_by_peer.get(peer_id, -INF)
		)
		if snapshot_time - last_keyframe_time >= PLAYER_DELTA_KEYFRAME_INTERVAL_SECONDS:
			return true
	return false


func _commit_snapshot_cohort_send(
	ready_peer_ids: Array[int],
	snapshot_time: float,
	was_keyframe: bool
) -> void:
	_snapshot_cohort_peers.clear()
	for peer_id in ready_peer_ids:
		if peer_id <= 0:
			continue
		_snapshot_cohort_peers[peer_id] = true
		if was_keyframe:
			_last_keyframe_time_by_peer[peer_id] = snapshot_time


func _apply_primary_cooldown_ratio(
	player_node: Player,
	ratio: float,
	facing_id: int,
	suppress_local_tango_snapshot: bool
) -> void:
	if player_node == null or not is_instance_valid(player_node):
		return
	var tango_player := player_node as PlayerTango
	if tango_player != null:
		if suppress_local_tango_snapshot:
			return
		tango_player.apply_multiplayer_tango_charge_snapshot(
			clampf(ratio, 0.0, 1.0),
			facing_id
		)
		return
	player_node.apply_multiplayer_primary_cooldown_ratio(clampf(ratio, 0.0, 1.0))


func _apply_realtime_snapshot(
	player_node: Player,
	player_state: SnapshotManager.PlayerState
) -> void:
	if player_node == null or player_state == null or not is_instance_valid(player_node):
		return
	var apply_snapshot_health := (
		player_state.health_revision
		>= get_applied_health_revision(player_state.peer_id)
	)
	player_node.apply_multiplayer_realtime_state(
		player_state.current_health if apply_snapshot_health else player_node.current_health,
		player_state.max_health if apply_snapshot_health else player_node.max_health,
		player_state.current_xirang,
		player_state.is_dead if apply_snapshot_health else player_node.is_dead,
		(
			player_state.invincibility_time_left
			if apply_snapshot_health
			else player_node.invincibility_time_left
		),
		player_state.skill1_unlocked,
		player_state.skill1_charge,
		player_state.skill1_charge_duration,
		player_state.form_mode,
		player_state.shot_pattern,
		player_state.skill1_upgrade_level,
		player_state.ammo_capacity,
		player_state.current_ammo,
		player_state.is_reloading,
		player_state.reload_progress
	)
	player_node.apply_multiplayer_effective_move_speed_multiplier(
		player_state.effective_move_speed_multiplier
	)
	if apply_snapshot_health:
		mark_health_revision_applied(
			player_state.peer_id,
			player_state.health_revision
		)


func _warn_character_snapshot_mismatch(
	peer_id: int,
	local_character_id: StringName,
	host_character_id: StringName
) -> void:
	if _character_mismatch_warnings.has(peer_id):
		return
	_character_mismatch_warnings[peer_id] = true
	push_warning(
		"MpPlayerCoordinator: peer %d 角色不一致 local=%s host=%s，忽略该角色快照。"
		% [peer_id, local_character_id, host_character_id]
	)


func _is_complete_snapshot_batch(data: PackedByteArray, decoded_count: int) -> bool:
	if data.is_empty():
		return false
	var expected_count := int(data[0])
	return expected_count > 0 and decoded_count == expected_count


func _create_interpolator() -> NetInterpolator:
	return NetInterpolator.new(
		1.0 / float(_NetConstants.PLAYER_SNAPSHOT_HZ),
		_NetConstants.PLAYER_INTERPOLATION_DELAY_FACTOR,
		_NetConstants.PLAYER_MAX_EXTRAPOLATION_SECONDS
	)


func _is_finite_vector2(value: Vector2) -> bool:
	return is_finite(value.x) and is_finite(value.y)
