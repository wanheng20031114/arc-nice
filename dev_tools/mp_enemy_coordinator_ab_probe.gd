extends SceneTree

const ROUND_COUNT := 3
const EVENT_COUNT := 256
const FIXED_SEED := 0x4D50454E
const SHARED_COHORT_ID := -1
const KEYFRAME_INTERVAL_SECONDS := 0.5
const NET_CONSTANTS := preload("res://scene/multiplayer/net_constants.gd")


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

	func get_enemy_for_net_id(net_id: int) -> Enemy:
		return multiplayer_enemies_by_net_id.get(net_id) as Enemy

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


class LegacyEnemySnapshotLogic:
	extends RefCounted

	var snapshot_manager := SnapshotManager.new()
	var last_keyframe_time_by_peer: Dictionary[int, float] = {}
	var cohort_peers: Dictionary[int, bool] = {}
	var host_batch_sequence := 0
	var chunk_encode_count := 0

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
			snapshot_manager.clear_enemy_send_baseline(SHARED_COHORT_ID)

	func clear_peer(peer_id: int) -> void:
		snapshot_manager.clear_peer_delta_cache(peer_id)
		cohort_peers.erase(peer_id)
		last_keyframe_time_by_peer.erase(peer_id)
		if cohort_peers.is_empty():
			snapshot_manager.clear_enemy_send_baseline(SHARED_COHORT_ID)

	func build(
		states: Array[SnapshotManager.EnemyState],
		ready_peer_ids: Array[int],
		snapshot_time: float,
		enemy_count: int
	) -> Dictionary:
		if ready_peer_ids.is_empty():
			return {}
		var target_hz := (
			MpEnemyCoordinator.ENEMY_HIGH_PRESSURE_SNAPSHOT_HZ
			if enemy_count >= MpEnemyCoordinator.ENEMY_HIGH_PRESSURE_THRESHOLD
			else NET_CONSTANTS.ENEMY_SNAPSHOT_HZ
		)
		var interval_frames := maxi(
			roundi(float(NET_CONSTANTS.HOST_PHYSICS_HZ) / float(target_hz)),
			1
		)
		var snapshot_hz := maxi(
			roundi(float(NET_CONSTANTS.HOST_PHYSICS_HZ) / float(interval_frames)),
			1
		)
		host_batch_sequence += 1
		var chunk_count := maxi(
			ceili(
				float(states.size())
				/ float(MpEnemyCoordinator.ENEMY_SNAPSHOT_CHUNK_MAX_ENTITIES)
			),
			1
		)
		var live_ids: Dictionary[int, bool] = {}
		for state in states:
			if state != null and state.net_id > 0:
				live_ids[state.net_id] = true
		var force_keyframe := _requires_keyframe(ready_peer_ids, snapshot_time)
		var chunks: Array[Dictionary] = []
		for chunk_index in range(chunk_count):
			var chunk_start := (
				chunk_index
				* MpEnemyCoordinator.ENEMY_SNAPSHOT_CHUNK_MAX_ENTITIES
			)
			var chunk_end := mini(
				chunk_start + MpEnemyCoordinator.ENEMY_SNAPSHOT_CHUNK_MAX_ENTITIES,
				states.size()
			)
			var entity_count := chunk_end - chunk_start
			var data := snapshot_manager.encode_enemy_snapshot_range_for_cohort(
				SHARED_COHORT_ID,
				states,
				chunk_start,
				entity_count,
				force_keyframe
			)
			chunk_encode_count += 1
			chunks.append({
				"chunk_index": chunk_index,
				"data": data,
				"entity_count": entity_count,
			})
		snapshot_manager.prune_enemy_send_cohort_baseline_to_ids(
			SHARED_COHORT_ID,
			live_ids
		)
		_commit(ready_peer_ids, snapshot_time, force_keyframe)
		return {
			"peer_ids": ready_peer_ids.duplicate(),
			"host_timestamp": snapshot_time,
			"batch_id": host_batch_sequence,
			"chunk_count": chunk_count,
			"snapshot_hz": snapshot_hz,
			"chunks": chunks,
		}

	func _requires_keyframe(
		ready_peer_ids: Array[int],
		snapshot_time: float
	) -> bool:
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
			"第 %d 轮敌人快照轨迹不一致：legacy=%d extracted=%d。"
			% [round_index + 1, legacy_hash, extracted_hash]
		)
		combined_hash = _combine_hash(combined_hash, extracted_hash)
	if failures.is_empty():
		print(
			"MP_ENEMY_COORDINATOR_AB_PROBE_OK rounds=%d trajectory_hash=%d"
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
	var legacy := LegacyEnemySnapshotLogic.new()
	var extracted := MpEnemyCoordinator.new()
	extracted.bind_runtime(runtime)
	var trace_hash := 23
	var snapshot_time := 100.0
	for _event_index in range(EVENT_COUNT):
		var operation := random.randi_range(0, 3)
		match operation:
			0, 1:
				var enemy_count := random.randi_range(0, 260)
				runtime.multiplayer_enemies_by_net_id.clear()
				for net_id in range(1, enemy_count + 1):
					runtime.multiplayer_enemies_by_net_id[net_id] = null
				var ready_peers := _random_ready_peers(random)
				var states := _random_states(random)
				snapshot_time += random.randf_range(0.01, 0.32)
				var packet: Dictionary
				if use_legacy:
					packet = legacy.build(
						states,
						ready_peers,
						snapshot_time,
						enemy_count
					)
				else:
					packet = _coordinator_packet(
						extracted.build_host_snapshot_batch(
							states,
							ready_peers,
							snapshot_time
						)
					)
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
						int(extracted.get_snapshot_metrics().get(
							"enemy_snapshot_cohort_size",
							0
						))
					)
			_:
				var peer_id := random.randi_range(2, 5)
				if use_legacy:
					legacy.clear_peer(peer_id)
					trace_hash = _combine_hash(trace_hash, legacy.cohort_peers.size())
				else:
					extracted.clear_peer(peer_id)
					trace_hash = _combine_hash(
						trace_hash,
						int(extracted.get_snapshot_metrics().get(
							"enemy_snapshot_cohort_size",
							0
						))
					)
	if use_legacy:
		trace_hash = _combine_hash(trace_hash, legacy.chunk_encode_count)
	else:
		trace_hash = _combine_hash(
			trace_hash,
			int(extracted.get_snapshot_metrics().get(
				"enemy_snapshot_chunk_encode_count",
				0
			))
		)
	extracted.free()
	runtime.free()
	return trace_hash


func _coordinator_packet(batch: MpEnemyCoordinator.HostSnapshotBatch) -> Dictionary:
	if batch == null:
		return {}
	var chunks: Array[Dictionary] = []
	for chunk in batch.chunks:
		chunks.append({
			"chunk_index": chunk.chunk_index,
			"data": chunk.data,
			"entity_count": chunk.entity_count,
		})
	return {
		"peer_ids": batch.peer_ids,
		"host_timestamp": batch.host_timestamp,
		"batch_id": batch.batch_id,
		"chunk_count": batch.chunk_count,
		"snapshot_hz": batch.snapshot_hz,
		"chunks": chunks,
	}


func _random_ready_peers(random: RandomNumberGenerator) -> Array[int]:
	var result: Array[int] = []
	for peer_id in range(2, 6):
		if random.randi_range(0, 3) != 0:
			result.append(peer_id)
	return result


func _random_states(
	random: RandomNumberGenerator
) -> Array[SnapshotManager.EnemyState]:
	var states: Array[SnapshotManager.EnemyState] = []
	var state_count := random.randi_range(0, 96)
	for net_id in range(1, state_count + 1):
		var state := SnapshotManager.EnemyState.new()
		state.net_id = net_id
		state.position = Vector2(
			random.randf_range(-2000.0, 2000.0),
			random.randf_range(-2000.0, 2000.0)
		)
		state.velocity = Vector2(
			random.randf_range(-120.0, 120.0),
			random.randf_range(-120.0, 120.0)
		)
		state.locomotion_state = random.randi_range(0, 1)
		state.health = random.randi_range(0, 5000)
		state.health_revision = random.randi_range(0, 2000)
		state.is_dead = random.randi_range(0, 15) == 0
		state.visual_status_mask = random.randi_range(0, 127)
		states.append(state)
	return states


func _packet_hash(packet: Dictionary) -> int:
	if packet.is_empty():
		return 0
	var result := int(packet.get("batch_id", 0))
	result = _combine_hash(result, int(packet.get("chunk_count", 0)))
	result = _combine_hash(result, int(packet.get("snapshot_hz", 0)))
	result = _combine_hash(
		result,
		roundi(float(packet.get("host_timestamp", 0.0)) * 1000.0)
	)
	for peer_id_variant in packet.get("peer_ids", []):
		result = _combine_hash(result, int(peer_id_variant))
	for chunk_variant in packet.get("chunks", []):
		var chunk := chunk_variant as Dictionary
		result = _combine_hash(result, int(chunk.get("chunk_index", 0)))
		result = _combine_hash(result, int(chunk.get("entity_count", 0)))
		var data := chunk.get("data", PackedByteArray()) as PackedByteArray
		result = _combine_hash(result, data.size())
		for value in data:
			result = _combine_hash(result, int(value))
	return result


func _combine_hash(current: int, value: int) -> int:
	return int((current * 65599 + value) & 0x7fffffff)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
