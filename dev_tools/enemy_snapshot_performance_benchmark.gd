extends SceneTree

const ENTITY_COUNT := 300
## Full enemy keyframes are 29 bytes after faction repair data is appended.
## 41 records plus the u16 count use 1191 bytes and stay below the 1200-byte budget.
const CHUNK_SIZE := 41
# 300 entities use MpGame's high-pressure cadence. Keep the benchmark aligned
# with production so its bytes/s result measures the actual acceptance path.
const SNAPSHOT_HZ := 20
const KEYFRAME_INTERVAL_TICKS := 10
const WARMUP_TICKS := 30
const MEASURE_TICKS := 240
const FANOUT_WARMUP_TICKS := 10
const FANOUT_MEASURE_TICKS := 60
const LARGE_FANOUT_ENTITY_COUNT := 1000
const LARGE_FANOUT_WARMUP_TICKS := 5
const LARGE_FANOUT_MEASURE_TICKS := 30
const FANOUT_CLIENT_COUNTS := [1, 4, 7]
const PAYLOAD_BUDGET_BYTES := 1200
## The 0.5-second keyframe cadence adds 300 * 5 * 2 = 3000 bytes/s for
## faction identity repair. Keep the measured application budget explicit.
const PAYLOAD_BUDGET_BYTES_PER_SECOND := 68_000.0
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
		state.locomotion_state = SnapshotManager.ENEMY_LOCOMOTION_MOVING
		state.health = 100
		state.faction_id = enemy_index % 32
		state.faction_revision = enemy_index
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
				state.health_revision += 1

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
	var fanout_metrics := _measure_shared_cohort_fanout(
		states,
		FANOUT_WARMUP_TICKS,
		FANOUT_MEASURE_TICKS
	)
	var large_fanout_states := _make_enemy_states(LARGE_FANOUT_ENTITY_COUNT)
	fanout_metrics.append_array(_measure_shared_cohort_fanout(
		large_fanout_states,
		LARGE_FANOUT_WARMUP_TICKS,
		LARGE_FANOUT_MEASURE_TICKS
	))
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
	for fanout_metric_variant in fanout_metrics:
		var fanout_metric := fanout_metric_variant as Dictionary
		print(
			(
				"ENEMY_SNAPSHOT_COHORT_AB entities=%d clients=%d "
				+ "legacy_encode_usec_per_tick=%.1f shared_encode_usec_per_tick=%.1f "
				+ "speedup=%.2f legacy_baseline_states=%d shared_baseline_states=%d"
			)
			% [
				int(fanout_metric.get("entities", 0)),
				int(fanout_metric.get("clients", 0)),
				float(fanout_metric.get("legacy_usec_per_tick", 0.0)),
				float(fanout_metric.get("shared_usec_per_tick", 0.0)),
				float(fanout_metric.get("speedup", 0.0)),
				int(fanout_metric.get("legacy_baseline_states", 0)),
				int(fanout_metric.get("shared_baseline_states", 0)),
			]
		)
	_expect(max_payload_bytes <= PAYLOAD_BUDGET_BYTES, "Snapshot payload must stay within budget.")
	_expect(
		payload_bytes_per_second <= PAYLOAD_BUDGET_BYTES_PER_SECOND,
		"The 300-enemy 20 Hz faction-aware payload must stay below about 68 KB/s."
	)
	for fanout_metric_variant in fanout_metrics:
		var fanout_metric := fanout_metric_variant as Dictionary
		var client_count := int(fanout_metric.get("clients", 0))
		var speedup := float(fanout_metric.get("speedup", 0.0))
		if client_count == 4:
			_expect(speedup >= 2.0, "Four-client cohort encoding must beat repeated encoding by at least 2x.")
		elif client_count == 7:
			_expect(speedup >= 3.5, "Seven-client cohort encoding must beat repeated encoding by at least 3.5x.")
	if failures.is_empty():
		print("ENEMY_SNAPSHOT_PERFORMANCE_BENCHMARK_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _verify_interpolator_semantics() -> void:
	var interpolator := NetInterpolator.new(0.1, 1.0, 0.2)
	interpolator.push_snapshot(
		0.0,
		Vector2.ZERO,
		Vector2(10.0, 0.0),
		0,
		SnapshotManager.ENEMY_LOCOMOTION_IDLE
	)
	interpolator.push_snapshot(
		0.1,
		Vector2(1.0, 0.0),
		Vector2(20.0, 0.0),
		0,
		SnapshotManager.ENEMY_LOCOMOTION_MOVING
	)
	interpolator.push_snapshot(
		0.2,
		Vector2(3.0, 0.0),
		Vector2(30.0, 0.0),
		0,
		SnapshotManager.ENEMY_LOCOMOTION_IDLE
	)
	var interpolated_velocity := interpolator.get_interpolated_velocity(0.25)
	var interpolated_position := interpolator.get_interpolated_position(0.25)
	_expect(
		interpolated_position.distance_to(Vector2(2.0, 0.0)) < 0.001
		and interpolated_velocity.distance_to(Vector2(25.0, 0.0)) < 0.001,
		"Cached interpolation must preserve position and velocity lerp semantics."
	)
	_expect(
		interpolator.get_current_state(0.25).anim_state
			== SnapshotManager.ENEMY_LOCOMOTION_MOVING
		and interpolator.get_latest_state().anim_state
			== SnapshotManager.ENEMY_LOCOMOTION_IDLE,
		"Discrete locomotion must use the delayed timeline while latest-state access remains explicit."
	)
	interpolator.set_snapshot_interval(0.2)
	_expect(
		interpolator.get_current_state(0.25).anim_state
			== SnapshotManager.ENEMY_LOCOMOTION_IDLE,
		"Changing snapshot cadence must invalidate the shared motion/state cache immediately."
	)
	interpolator.set_snapshot_interval(0.1)

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
			state.locomotion_state = source.locomotion_state
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
				source.locomotion_state,
				source.health,
				source.is_dead
			)
		var elapsed_usec := Time.get_ticks_usec() - started_usec
		if tick >= WARMUP_TICKS:
			push_usec += elapsed_usec

	var sample_usec := 0
	var sample_checksum := Vector2.ZERO
	var sample_locomotion_checksum := 0
	var latest_timestamp := float(total_ticks - 1) / float(SNAPSHOT_HZ)
	for frame_index in range(MEASURE_TICKS):
		var render_time := latest_timestamp + float(frame_index % 2) / 60.0
		var started_usec := Time.get_ticks_usec()
		for interpolator in interpolators:
			sample_checksum += interpolator.get_interpolated_position(render_time)
			sample_checksum += interpolator.get_interpolated_velocity(render_time)
			sample_locomotion_checksum += interpolator.get_current_state(render_time).anim_state
		sample_usec += Time.get_ticks_usec() - started_usec
	_expect(
		sample_checksum != Vector2.ZERO and sample_locomotion_checksum > 0,
		"Interpolator benchmark must consume continuous motion and discrete locomotion."
	)
	return {
		"push_usec_per_tick": float(push_usec) / float(MEASURE_TICKS),
		"sample_usec_per_frame": float(sample_usec) / float(MEASURE_TICKS),
	}


func _measure_shared_cohort_fanout(
	states: Array[SnapshotManager.EnemyState],
	warmup_ticks: int,
	measure_ticks: int
) -> Array[Dictionary]:
	var summaries: Array[Dictionary] = []
	var live_ids: Dictionary = {}
	for state in states:
		live_ids[state.net_id] = true
	for client_count_variant in FANOUT_CLIENT_COUNTS:
		var client_count := int(client_count_variant)
		var legacy_sender := SnapshotManager.new()
		var shared_sender := SnapshotManager.new()
		var legacy_receivers: Array[SnapshotManager] = []
		var shared_receivers: Array[SnapshotManager] = []
		for _client_index in range(client_count):
			legacy_receivers.append(SnapshotManager.new())
			shared_receivers.append(SnapshotManager.new())
		var legacy_usec := 0
		var shared_usec := 0
		var total_ticks := warmup_ticks + measure_ticks
		for tick in range(total_ticks):
			for state in states:
				state.position += state.velocity / float(SNAPSHOT_HZ)
			var force_keyframe := tick % KEYFRAME_INTERVAL_TICKS == 0
			var legacy_packets_by_client: Array = []
			var legacy_started_usec := Time.get_ticks_usec()
			for client_index in range(client_count):
				legacy_packets_by_client.append(_encode_enemy_packets(
					legacy_sender,
					100 + client_index,
					states,
					live_ids,
					force_keyframe,
					false
				))
			var legacy_elapsed_usec := Time.get_ticks_usec() - legacy_started_usec

			var shared_started_usec := Time.get_ticks_usec()
			var shared_packets := _encode_enemy_packets(
				shared_sender,
				-1,
				states,
				live_ids,
				force_keyframe,
				true
			)
			var shared_elapsed_usec := Time.get_ticks_usec() - shared_started_usec
			if tick >= warmup_ticks:
				legacy_usec += legacy_elapsed_usec
				shared_usec += shared_elapsed_usec

			for client_index in range(client_count):
				var legacy_packets := legacy_packets_by_client[client_index] as Array[PackedByteArray]
				_expect(
					legacy_packets == shared_packets,
					"A cohort packet must be byte-identical to every equal-history peer packet."
				)
				var legacy_decoded := _decode_enemy_packets(
					legacy_receivers[client_index],
					legacy_packets,
					live_ids
				)
				var shared_decoded := _decode_enemy_packets(
					shared_receivers[client_index],
					shared_packets,
					live_ids
				)
				_expect(
					_enemy_decoded_states_equal(legacy_decoded, shared_decoded, states),
					"Every client must decode shared cohort packets exactly like its legacy stream."
				)
		var legacy_baseline_states := 0
		for baseline_variant in legacy_sender.enemy_send_baselines_by_peer.values():
			var baseline := baseline_variant as Dictionary
			legacy_baseline_states += baseline.size()
			_expect(
				baseline.size() == states.size(),
				"Every legacy receiver baseline must retain one state per live enemy."
			)
		var shared_baseline := shared_sender.enemy_send_baselines_by_peer.get(-1, {}) as Dictionary
		_expect(
			legacy_sender.enemy_send_baselines_by_peer.size() == client_count
			and shared_sender.enemy_send_baselines_by_peer.size() == 1
			and shared_baseline.size() == states.size(),
			"Cohort encoding must collapse C x N send baselines to exactly one N-state baseline."
		)
		var legacy_per_tick := float(legacy_usec) / float(measure_ticks)
		var shared_per_tick := float(shared_usec) / float(measure_ticks)
		summaries.append({
			"entities": states.size(),
			"clients": client_count,
			"legacy_usec_per_tick": legacy_per_tick,
			"shared_usec_per_tick": shared_per_tick,
			"speedup": legacy_per_tick / maxf(shared_per_tick, 0.001),
			"legacy_baseline_states": legacy_baseline_states,
			"shared_baseline_states": shared_baseline.size(),
		})
	return summaries


func _make_enemy_states(entity_count: int) -> Array[SnapshotManager.EnemyState]:
	var states: Array[SnapshotManager.EnemyState] = []
	for enemy_index in range(entity_count):
		var state := SnapshotManager.EnemyState.new()
		state.net_id = enemy_index + 1
		state.position = Vector2(enemy_index * 0.5, enemy_index * 0.25)
		state.velocity = Vector2(8.0 + float(enemy_index % 5), 0.0)
		state.locomotion_state = SnapshotManager.ENEMY_LOCOMOTION_MOVING
		state.health = 100 + enemy_index % 100
		state.visual_status_mask = enemy_index % 16
		state.faction_id = enemy_index % 32
		state.faction_revision = enemy_index
		states.append(state)
	return states


func _encode_enemy_packets(
	sender: SnapshotManager,
	baseline_id: int,
	states: Array[SnapshotManager.EnemyState],
	live_ids: Dictionary,
	force_keyframe: bool,
	shared_cohort: bool
) -> Array[PackedByteArray]:
	var packets: Array[PackedByteArray] = []
	for chunk_start in range(0, states.size(), CHUNK_SIZE):
		var chunk_count := mini(CHUNK_SIZE, states.size() - chunk_start)
		if shared_cohort:
			packets.append(sender.encode_enemy_snapshot_range_for_cohort(
				baseline_id,
				states,
				chunk_start,
				chunk_count,
				force_keyframe
			))
		else:
			packets.append(sender.encode_enemy_snapshot_range_for_peer(
				baseline_id,
				states,
				chunk_start,
				chunk_count,
				force_keyframe
			))
	if shared_cohort:
		sender.prune_enemy_send_cohort_baseline_to_ids(baseline_id, live_ids)
	else:
		sender.prune_enemy_send_baseline_to_ids(baseline_id, live_ids)
	return packets


func _decode_enemy_packets(
	receiver: SnapshotManager,
	packets: Array[PackedByteArray],
	live_ids: Dictionary
) -> Array[SnapshotManager.EnemyState]:
	var decoded: Array[SnapshotManager.EnemyState] = []
	for packet in packets:
		decoded.append_array(receiver.decode_enemy_snapshots_with_baseline(packet, false))
	receiver.prune_enemy_receive_baseline_to_ids(live_ids)
	return decoded


func _enemy_decoded_states_equal(
	legacy_states: Array[SnapshotManager.EnemyState],
	shared_states: Array[SnapshotManager.EnemyState],
	source_states: Array[SnapshotManager.EnemyState]
) -> bool:
	if legacy_states.size() != source_states.size() or shared_states.size() != source_states.size():
		return false
	for state_index in range(source_states.size()):
		var source := source_states[state_index]
		var legacy := legacy_states[state_index]
		var shared := shared_states[state_index]
		if (
			legacy.net_id != source.net_id
			or shared.net_id != source.net_id
			or legacy.position.distance_to(source.position) > 0.11
			or shared.position.distance_to(source.position) > 0.11
			or legacy.velocity.distance_to(source.velocity) > 0.11
			or shared.velocity.distance_to(source.velocity) > 0.11
			or legacy.locomotion_state != source.locomotion_state
			or shared.locomotion_state != source.locomotion_state
			or legacy.health != source.health
			or shared.health != source.health
			or legacy.is_dead != source.is_dead
			or shared.is_dead != source.is_dead
			or legacy.visual_status_mask != source.visual_status_mask
			or shared.visual_status_mask != source.visual_status_mask
			or legacy.faction_id != source.faction_id
			or shared.faction_id != source.faction_id
			or legacy.faction_revision != source.faction_revision
			or shared.faction_revision != source.faction_revision
		):
			return false
	return true


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
