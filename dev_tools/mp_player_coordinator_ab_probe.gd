extends SceneTree

const ROUND_COUNT := 3
const EVENT_COUNT := 384
const FIXED_SEED := 0x4D50504C
const SHARED_COHORT_ID := -1
const KEYFRAME_INTERVAL_SECONDS := 0.5


class ProbeRuntime:
	extends CombatRuntimeBase

	func configure_multiplayer(
		_mode: int,
		_local_peer_id: int,
		_player_names: Dictionary,
		_player_character_ids: Dictionary = {}
	) -> void:
		pass

	func get_player_for_peer(peer_id: int) -> Player:
		return peer_players.get(peer_id) as Player

	func get_enemy_for_net_id(_net_id: int) -> Enemy:
		return null

	func get_pickup_for_net_id(_net_id: int) -> Pickup:
		return null

	func remove_multiplayer_player(peer_id: int) -> void:
		peer_players.erase(peer_id)

	func collect_player_snapshot_states() -> Array[SnapshotManager.PlayerState]:
		return []

	func collect_enemy_snapshot_states() -> Array[SnapshotManager.EnemyState]:
		return []

	func play_remote_enemy_spawn_effect(_spawn_global_position: Vector2) -> void:
		pass


class LegacyPlayerSnapshotLogic:
	extends RefCounted

	var snapshot_manager := SnapshotManager.new()
	var latest_client_states: Dictionary[int, Dictionary] = {}
	var applied_health_revisions: Dictionary[int, int] = {}
	var last_keyframe_time_by_peer: Dictionary[int, float] = {}
	var cohort_peers: Dictionary[int, bool] = {}
	var host_sequence := 0
	var encode_count := 0

	func remember(
		peer_id: int,
		position: Vector2,
		velocity: Vector2,
		facing: int,
		anim_state: int
	) -> void:
		if peer_id <= 0:
			return
		latest_client_states[peer_id] = {
			"position": position,
			"velocity": velocity,
			"facing": facing,
			"anim_state": anim_state,
		}

	func sync(ready_peer_ids: Array[int]) -> void:
		var ready_lookup: Dictionary[int, bool] = {}
		for peer_id in ready_peer_ids:
			if peer_id > 0:
				ready_lookup[peer_id] = true
		for peer_id_variant in cohort_peers.keys():
			var peer_id := int(peer_id_variant)
			if ready_lookup.has(peer_id):
				continue
			cohort_peers.erase(peer_id)
			last_keyframe_time_by_peer.erase(peer_id)
		if cohort_peers.is_empty():
			snapshot_manager.clear_player_send_baseline(SHARED_COHORT_ID)

	func build(
		states: Array[SnapshotManager.PlayerState],
		ready_peer_ids: Array[int],
		snapshot_time: float,
		health_revisions: Dictionary
	) -> Dictionary:
		if ready_peer_ids.is_empty() or states.is_empty():
			return {}
		for state in states:
			if state == null or state.is_dead:
				continue
			var latest := latest_client_states.get(state.peer_id, {}) as Dictionary
			if latest.is_empty():
				continue
			state.position = latest["position"] as Vector2
			state.velocity = latest["velocity"] as Vector2
			state.facing = int(latest["facing"])
			state.anim_state = int(latest["anim_state"])
		host_sequence += 1
		for state in states:
			state.sequence = host_sequence
			state.health_revision = int(health_revisions.get(state.peer_id, 0))
		var force_keyframe := _requires_keyframe(ready_peer_ids, snapshot_time)
		var data := snapshot_manager.encode_player_snapshots_for_cohort(
			SHARED_COHORT_ID,
			states,
			force_keyframe
		)
		if data.is_empty():
			return {}
		encode_count += 1
		_commit(ready_peer_ids, snapshot_time, force_keyframe)
		return {
			"peer_ids": ready_peer_ids.duplicate(),
			"host_timestamp": snapshot_time,
			"data": data,
			"entity_count": states.size(),
		}

	func mark_health(peer_id: int, revision: int) -> void:
		if peer_id <= 0 or revision < 0:
			return
		applied_health_revisions[peer_id] = maxi(
			int(applied_health_revisions.get(peer_id, 0)),
			revision
		)

	func clear_peer(peer_id: int) -> void:
		snapshot_manager.clear_peer_delta_cache(peer_id)
		cohort_peers.erase(peer_id)
		last_keyframe_time_by_peer.erase(peer_id)
		if cohort_peers.is_empty():
			snapshot_manager.clear_player_send_baseline(SHARED_COHORT_ID)
		latest_client_states.erase(peer_id)
		applied_health_revisions.erase(peer_id)

	func _requires_keyframe(ready_peer_ids: Array[int], snapshot_time: float) -> bool:
		if ready_peer_ids.is_empty():
			return false
		if cohort_peers.size() != ready_peer_ids.size():
			return true
		for peer_id in ready_peer_ids:
			if not cohort_peers.has(peer_id) or not last_keyframe_time_by_peer.has(peer_id):
				return true
			if (
				snapshot_time
				- float(last_keyframe_time_by_peer.get(peer_id, -INF))
				>= KEYFRAME_INTERVAL_SECONDS
			):
				return true
		return false

	func _commit(
		ready_peer_ids: Array[int],
		snapshot_time: float,
		was_keyframe: bool
	) -> void:
		cohort_peers.clear()
		for peer_id in ready_peer_ids:
			if peer_id <= 0:
				continue
			cohort_peers[peer_id] = true
			if was_keyframe:
				last_keyframe_time_by_peer[peer_id] = snapshot_time


var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var combined_hash := 17
	for round_index in range(ROUND_COUNT):
		var legacy_hash := _run_trace(true, FIXED_SEED + round_index)
		var extracted_hash := _run_trace(false, FIXED_SEED + round_index)
		_expect(
			legacy_hash == extracted_hash,
			"第 %d 轮玩家快照轨迹不一致：legacy=%d extracted=%d。"
			% [round_index + 1, legacy_hash, extracted_hash]
		)
		combined_hash = _combine_hash(combined_hash, extracted_hash)
	if failures.is_empty():
		print(
			"MP_PLAYER_COORDINATOR_AB_PROBE_OK rounds=%d trajectory_hash=%d"
			% [ROUND_COUNT, combined_hash]
		)
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _run_trace(use_legacy: bool, seed: int) -> int:
	var random := RandomNumberGenerator.new()
	random.seed = seed
	var runtime := ProbeRuntime.new()
	runtime.runtime_mode = CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY
	var legacy := LegacyPlayerSnapshotLogic.new()
	var extracted := MpPlayerCoordinator.new()
	extracted.bind_runtime(runtime)
	var trace_hash := 23
	var snapshot_time := 100.0
	for _event_index in range(EVENT_COUNT):
		var operation := random.randi_range(0, 3)
		var peer_id := random.randi_range(1, 5)
		match operation:
			0:
				var position := Vector2(
					random.randf_range(-500.0, 500.0),
					random.randf_range(-500.0, 500.0)
				)
				var velocity := Vector2(
					random.randf_range(-80.0, 80.0),
					random.randf_range(-80.0, 80.0)
				)
				var facing := random.randi_range(0, 3)
				var anim_state := random.randi_range(0, 7)
				if use_legacy:
					legacy.remember(peer_id, position, velocity, facing, anim_state)
				else:
					extracted.remember_latest_client_state(
						true, peer_id, position, velocity, facing, anim_state
					)
				trace_hash = _combine_hash(trace_hash, peer_id + facing * 11 + anim_state * 31)
			1:
				var ready_peers := _random_ready_peers(random)
				snapshot_time += random.randf_range(0.01, 0.32)
				var health_revisions: Dictionary = {}
				var states := _random_states(random, health_revisions)
				var packet: Dictionary
				if use_legacy:
					legacy.sync(ready_peers)
					packet = legacy.build(
						states, ready_peers, snapshot_time, health_revisions
					)
				else:
					extracted.sync_snapshot_cohort_readiness(ready_peers)
					var batch := extracted.build_host_snapshot_batch(
						states, ready_peers, snapshot_time, health_revisions
					)
					if batch != null:
						packet = {
							"peer_ids": batch.peer_ids,
							"host_timestamp": batch.host_timestamp,
							"data": batch.data,
							"entity_count": batch.entity_count,
						}
				trace_hash = _combine_hash(trace_hash, _packet_hash(packet))
			2:
				var ready_peers := _random_ready_peers(random)
				if use_legacy:
					legacy.sync(ready_peers)
					trace_hash = _combine_hash(trace_hash, legacy.cohort_peers.size())
				else:
					extracted.sync_snapshot_cohort_readiness(ready_peers)
					trace_hash = _combine_hash(
						trace_hash,
						extracted.get_snapshot_cohort_size()
					)
			_:
				var revision := random.randi_range(0, 30)
				if use_legacy:
					legacy.mark_health(peer_id, revision)
					if random.randi_range(0, 4) == 0:
						legacy.clear_peer(peer_id)
					trace_hash = _combine_hash(
						trace_hash,
						int(legacy.applied_health_revisions.get(peer_id, 0))
					)
				else:
					extracted.mark_health_revision_applied(peer_id, revision)
					if random.randi_range(0, 4) == 0:
						extracted.clear_peer(peer_id)
					trace_hash = _combine_hash(
						trace_hash,
						extracted.get_applied_health_revision(peer_id)
					)
	if use_legacy:
		trace_hash = _combine_hash(trace_hash, legacy.encode_count)
		trace_hash = _combine_hash(trace_hash, legacy.host_sequence)
	else:
		trace_hash = _combine_hash(trace_hash, extracted.get_snapshot_encode_count())
		trace_hash = _combine_hash(trace_hash, extracted.get_host_snapshot_sequence())
	extracted.free()
	runtime.free()
	return trace_hash


func _random_ready_peers(random: RandomNumberGenerator) -> Array[int]:
	var result: Array[int] = []
	for peer_id in range(2, 6):
		if random.randi_range(0, 3) != 0:
			result.append(peer_id)
	return result


func _random_states(
	random: RandomNumberGenerator,
	health_revisions: Dictionary
) -> Array[SnapshotManager.PlayerState]:
	var states: Array[SnapshotManager.PlayerState] = []
	for peer_id in range(1, random.randi_range(2, 5) + 1):
		var state := SnapshotManager.PlayerState.new()
		state.peer_id = peer_id
		state.character_id = &"weishidaier"
		state.position = Vector2(
			random.randf_range(-300.0, 300.0),
			random.randf_range(-300.0, 300.0)
		)
		state.velocity = Vector2(
			random.randf_range(-60.0, 60.0),
			random.randf_range(-60.0, 60.0)
		)
		state.current_health = random.randi_range(1, 100)
		state.max_health = 100
		state.is_dead = random.randi_range(0, 7) == 0
		state.facing = random.randi_range(0, 3)
		state.anim_state = random.randi_range(0, 7)
		health_revisions[peer_id] = random.randi_range(0, 40)
		states.append(state)
	return states


func _packet_hash(packet: Dictionary) -> int:
	if packet.is_empty():
		return 0
	var result := int(packet.get("entity_count", 0))
	result = _combine_hash(
		result,
		roundi(float(packet.get("host_timestamp", 0.0)) * 1000.0)
	)
	for peer_id_variant in packet.get("peer_ids", []):
		result = _combine_hash(result, int(peer_id_variant))
	var data := packet.get("data", PackedByteArray()) as PackedByteArray
	result = _combine_hash(result, data.size())
	for value in data:
		result = _combine_hash(result, int(value))
	return result


func _combine_hash(current: int, value: int) -> int:
	return int((current * 65599 + value) & 0x7fffffff)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
