extends SceneTree

const ENTITY_COUNT := 300
const CHUNK_SIZE := 56
const SNAPSHOT_HZ := 30
const KEYFRAME_INTERVAL_TICKS := 15
const WARMUP_TICKS := 30
const MEASURE_TICKS := 240
const PAYLOAD_BUDGET_BYTES := 1200
const RECEIVER_PEER_ID := 77

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_verify_interpolator_semantics()
	var states: Array[SnapshotManager.EnemyState] = []
	for enemy_index in range(ENTITY_COUNT):
		var state := SnapshotManager.EnemyState.new()
		state.net_id = enemy_index + 1
		state.position = Vector2(enemy_index * 0.5, enemy_index * 0.25)
		state.velocity = Vector2(8.0 + float(enemy_index % 5), 0.0)
		state.health = 100
		states.append(state)

	var sender := SnapshotManager.new()
	var receiver := SnapshotManager.new()
	var encode_usec := 0
	var decode_usec := 0
	var measured_payload_bytes := 0
	var measured_packet_count := 0
	var max_payload_bytes := 0
	var total_ticks := WARMUP_TICKS + MEASURE_TICKS
	for tick in range(total_ticks):
		for enemy_index in range(states.size()):
			var state := states[enemy_index]
			state.position += state.velocity / float(SNAPSHOT_HZ)
			if enemy_index == tick % ENTITY_COUNT:
				state.health = maxi(state.health - 1, 0)

		var force_keyframe := tick % KEYFRAME_INTERVAL_TICKS == 0
		var live_ids: Dictionary = {}
		for state in states:
			live_ids[state.net_id] = true
		var packets: Array[PackedByteArray] = []
		var encode_started_usec := Time.get_ticks_usec()
		for chunk_start in range(0, states.size(), CHUNK_SIZE):
			var chunk_count := mini(CHUNK_SIZE, states.size() - chunk_start)
			packets.append(
				sender.encode_enemy_snapshot_range_for_peer(
					RECEIVER_PEER_ID,
					states,
					chunk_start,
					chunk_count,
					force_keyframe
				)
			)
		sender.prune_enemy_send_baseline_to_ids(RECEIVER_PEER_ID, live_ids)
		var encoded_usec := Time.get_ticks_usec() - encode_started_usec

		var decoded_count := 0
		var decode_started_usec := Time.get_ticks_usec()
		for packet in packets:
			decoded_count += receiver.decode_enemy_snapshots_with_baseline(packet, false).size()
		receiver.prune_enemy_receive_baseline_to_ids(live_ids)
		var decoded_usec := Time.get_ticks_usec() - decode_started_usec
		_expect(decoded_count == ENTITY_COUNT, "Every benchmark tick must decode all 300 enemies.")

		if tick < WARMUP_TICKS:
			continue
		encode_usec += encoded_usec
		decode_usec += decoded_usec
		for packet in packets:
			measured_payload_bytes += packet.size()
			measured_packet_count += 1
			max_payload_bytes = maxi(max_payload_bytes, packet.size())

	var seconds := float(MEASURE_TICKS) / float(SNAPSHOT_HZ)
	var average_payload_per_tick := float(measured_payload_bytes) / float(MEASURE_TICKS)
	var payload_bytes_per_second := float(measured_payload_bytes) / seconds
	var state_collection_alloc_usec_per_tick := _measure_state_collection_allocations(states)
	var interpolation_metrics := _measure_interpolator_costs(states)
	print(
		(
			"ENEMY_SNAPSHOT_PERFORMANCE_BENCHMARK "
		+ "entities=%d chunks_per_tick=%d max_payload=%d "
		+ "avg_payload_per_tick=%.1f payload_per_second=%.1f "
		+ "encode_usec_per_tick=%.1f decode_usec_per_tick=%.1f "
		+ "state_collection_alloc_usec_per_tick=%.1f "
		+ "interpolator_push_usec_per_tick=%.1f "
		+ "interpolator_sample_usec_per_frame=%.1f packets_per_second=%.1f"
		)
		% [
			ENTITY_COUNT,
			ceili(float(ENTITY_COUNT) / float(CHUNK_SIZE)),
			max_payload_bytes,
			average_payload_per_tick,
			payload_bytes_per_second,
			float(encode_usec) / float(MEASURE_TICKS),
			float(decode_usec) / float(MEASURE_TICKS),
			state_collection_alloc_usec_per_tick,
			float(interpolation_metrics.get("push_usec_per_tick", 0.0)),
			float(interpolation_metrics.get("sample_usec_per_frame", 0.0)),
			float(measured_packet_count) / seconds,
		]
	)
	_expect(max_payload_bytes <= PAYLOAD_BUDGET_BYTES, "Snapshot payload must stay within budget.")
	if failures.is_empty():
		print("ENEMY_SNAPSHOT_PERFORMANCE_BENCHMARK_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _verify_interpolator_semantics() -> void:
	var interpolator := NetInterpolator.new(0.1, 1.0, 0.2)
	interpolator.push_snapshot(0.0, Vector2.ZERO, Vector2(10.0, 0.0))
	interpolator.push_snapshot(0.1, Vector2(1.0, 0.0), Vector2(20.0, 0.0))
	interpolator.push_snapshot(0.2, Vector2(3.0, 0.0), Vector2(30.0, 0.0))
	var interpolated_velocity := interpolator.get_interpolated_velocity(0.25)
	var interpolated_position := interpolator.get_interpolated_position(0.25)
	_expect(
		interpolated_position.distance_to(Vector2(2.0, 0.0)) < 0.001
		and interpolated_velocity.distance_to(Vector2(25.0, 0.0)) < 0.001,
		"Cached interpolation must preserve position and velocity lerp semantics."
	)

	interpolator.push_snapshot(0.15, Vector2(1.5, 0.0), Vector2(15.0, 0.0))
	_expect(
		interpolator.get_interpolated_position(0.25).distance_to(Vector2(1.5, 0.0)) < 0.001
		and interpolator.get_interpolated_velocity(0.25).distance_to(Vector2(15.0, 0.0)) < 0.001,
		"Out-of-order insertion must invalidate and rebuild cached interpolation."
	)
	interpolator.push_snapshot(0.15, Vector2(1.75, 0.0), Vector2(17.5, 0.0))
	_expect(
		interpolator.get_interpolated_position(0.25).distance_to(Vector2(1.75, 0.0)) < 0.001,
		"Replacing an equal-timestamp sample must invalidate cached interpolation."
	)
	_expect(
		interpolator.get_interpolated_position(0.5).distance_to(Vector2(9.0, 0.0)) < 0.001
		and interpolator.get_interpolated_velocity(0.5).distance_to(Vector2(30.0, 0.0)) < 0.001,
		"Cached interpolation must preserve bounded extrapolation."
	)
	interpolator.clear()
	_expect(
		interpolator.get_interpolated_position(0.5) == Vector2.ZERO
		and interpolator.get_interpolated_velocity(0.5) == Vector2.ZERO,
		"Clearing interpolation must invalidate cached motion."
	)

	var rolling_interpolator := NetInterpolator.new(0.1, 1.0, 0.2)
	for sample_index in range(30):
		rolling_interpolator.push_snapshot(
			float(sample_index) * 0.1,
			Vector2(float(sample_index), 0.0),
			Vector2(10.0, 0.0)
		)
	_expect(
		rolling_interpolator.get_buffer_size() == 18
		and is_equal_approx(rolling_interpolator.get_latest_timestamp(), 2.9)
		and rolling_interpolator.get_interpolated_position(3.0).distance_to(
			Vector2(29.0, 0.0)
		) < 0.001,
		"Recycled interpolation frames must preserve buffer bounds and newest motion."
	)


func _measure_state_collection_allocations(
	source_states: Array[SnapshotManager.EnemyState]
) -> float:
	var measured_usec := 0
	var total_ticks := WARMUP_TICKS + MEASURE_TICKS
	for tick in range(total_ticks):
		var started_usec := Time.get_ticks_usec()
		var collected: Array[SnapshotManager.EnemyState] = []
		for source in source_states:
			var state := SnapshotManager.EnemyState.new()
			state.net_id = source.net_id
			state.position = source.position
			state.velocity = source.velocity
			state.health = source.health
			state.is_dead = source.is_dead
			collected.append(state)
		var elapsed_usec := Time.get_ticks_usec() - started_usec
		_expect(collected.size() == ENTITY_COUNT, "Collection allocation fixture must build 300 states.")
		if tick >= WARMUP_TICKS:
			measured_usec += elapsed_usec
	return float(measured_usec) / float(MEASURE_TICKS)


func _measure_interpolator_costs(
	source_states: Array[SnapshotManager.EnemyState]
) -> Dictionary:
	var interpolators: Array[NetInterpolator] = []
	for _enemy_index in range(ENTITY_COUNT):
		interpolators.append(NetInterpolator.new(1.0 / float(SNAPSHOT_HZ), 2.5, 0.12))

	var push_usec := 0
	var total_ticks := WARMUP_TICKS + MEASURE_TICKS
	for tick in range(total_ticks):
		var timestamp := float(tick) / float(SNAPSHOT_HZ)
		var started_usec := Time.get_ticks_usec()
		for enemy_index in range(ENTITY_COUNT):
			var source := source_states[enemy_index]
			interpolators[enemy_index].push_snapshot(
				timestamp,
				source.position + source.velocity * timestamp,
				source.velocity,
				0,
				0,
				source.health,
				source.is_dead
			)
		var elapsed_usec := Time.get_ticks_usec() - started_usec
		if tick >= WARMUP_TICKS:
			push_usec += elapsed_usec

	var sample_usec := 0
	var sample_checksum := Vector2.ZERO
	var latest_timestamp := float(total_ticks - 1) / float(SNAPSHOT_HZ)
	for frame_index in range(MEASURE_TICKS):
		var render_time := latest_timestamp + float(frame_index % 2) / 60.0
		var started_usec := Time.get_ticks_usec()
		for interpolator in interpolators:
			sample_checksum += interpolator.get_interpolated_position(render_time)
			sample_checksum += interpolator.get_interpolated_velocity(render_time)
		sample_usec += Time.get_ticks_usec() - started_usec
	_expect(sample_checksum != Vector2.ZERO, "Interpolator benchmark must consume sampled motion.")
	return {
		"push_usec_per_tick": float(push_usec) / float(MEASURE_TICKS),
		"sample_usec_per_frame": float(sample_usec) / float(MEASURE_TICKS),
	}


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
