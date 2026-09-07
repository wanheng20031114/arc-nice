extends SceneTree

const ENTITY_COUNT := 300
const SAMPLE_COUNT := 240
var _failures: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _check(value: bool, message: String) -> void:
	if not value:
		_failures.append(message)
		printerr("FAIL: ", message)


func _run() -> void:
	var sender := SnapshotManager.new()
	var reference_baseline: Dictionary[int, SnapshotManager.EnemyState] = {}
	var states: Array[SnapshotManager.EnemyState] = []
	for index in ENTITY_COUNT:
		var state := SnapshotManager.EnemyState.new()
		state.net_id = index + 1
		states.append(state)
	var checked_bytes := 0
	for sample in SAMPLE_COUNT:
		_mutate(states, sample)
		var keyframe := sample % 10 == 0
		var expected := _reference_chunks(states, reference_baseline, keyframe)
		var actual := sender.encode_enemy_snapshot_chunks_for_cohort(-1, states, keyframe)
		_check(actual == expected, "Wire differs from reference at sample %d" % sample)
		for packet in actual:
			_check(packet.size() <= 1191, "Packet exceeds 41-entity MTU bound")
			checked_bytes += packet.size()
			if keyframe:
				_check(not SnapshotManager.decode_all_enemy_snapshots(packet).is_empty(), "Keyframe must decode independently")
	# A late invalid record must leave the entire cohort's previously sent
	# baseline untouched, including all seven earlier, otherwise valid chunks.
	_mutate(states, SAMPLE_COUNT)
	states[ENTITY_COUNT - 1].position = Vector2(INF, 0)
	Engine.print_error_messages = false
	var rejected := sender.encode_enemy_snapshot_chunks_for_cohort(-1, states)
	Engine.print_error_messages = true
	_check(rejected.is_empty(), "Nonfinite last chunk was not rejected atomically")
	_mutate(states, SAMPLE_COUNT + 1)
	_check(
		sender.encode_enemy_snapshot_chunks_for_cohort(-1, states)
		== _reference_chunks(states, reference_baseline, false),
		"Rejected batch advanced an earlier chunk's baseline"
	)
	# New incarnation on an existing net ID must become independently decodable
	# immediately, without waiting for the periodic full cohort keyframe.
	sender.erase_enemy_send_baseline(states[0].net_id)
	reference_baseline.erase(states[0].net_id)
	_check(
		sender.encode_enemy_snapshot_chunks_for_cohort(-1, states)
		== _reference_chunks(states, reference_baseline, false),
		"Same-ID incarnation retained its former delta baseline"
	)
	var trimmed: Array[SnapshotManager.EnemyState] = [states[0]]
	sender.prune_enemy_send_cohort_baseline_to_ids(-1, {states[0].net_id: true})
	_check(sender.enemy_send_baselines_by_peer[-1].size() == 1, "Roster pruning retained stale send entries")
	sender.clear_enemy_send_baseline(-1)
	_check(
		sender.encode_enemy_snapshot_chunks_for_cohort(-1, trimmed)[0]
		== SnapshotManager.new().encode_all_enemy_snapshots(trimmed),
		"Rejoining cohort did not receive a full independent baseline"
	)
	sender.reset_delta_cache()
	_check(sender.enemy_send_baselines_by_peer.is_empty(), "Session reset retained send state")
	var times := _benchmark(states)
	print("ENEMY_SNAPSHOT_SCALING ", JSON.stringify({
		"samples": SAMPLE_COUNT, "entities": ENTITY_COUNT, "wire_bytes_compared": checked_bytes,
		"timings": times, "failures": _failures,
	}))
	quit(0 if _failures.is_empty() else 1)


func _mutate(states: Array[SnapshotManager.EnemyState], sample: int) -> void:
	for index in states.size():
		var state := states[index]
		# Exercise saturation, both signs, sub-quantization movement, stop/start,
		# damage/healing revisions, every mask and faction keyframe trailers.
		state.position = Vector2((index - 150) * 40.0 + sample * 0.013, sample * 0.17 - index)
		state.velocity = Vector2(0 if sample % 3 == 0 else index * 0.007, (sample % 11 - 5) * 0.19)
		state.locomotion_state = sample % 3
		state.health = 10000000 + sample % 4 - index
		state.health_revision = sample
		state.is_dead = sample % 7 == 0
		state.visual_status_mask = (sample + index) % 128
		state.faction_id = 1 if sample % 2 == 0 else 2
		state.faction_revision = sample


func _reference_chunks(
	states: Array[SnapshotManager.EnemyState],
	baseline: Dictionary[int, SnapshotManager.EnemyState],
	keyframe: bool
) -> Array[PackedByteArray]:
	var packets: Array[PackedByteArray] = []
	if not SnapshotManager.are_enemy_snapshot_states_serializable(states):
		return packets
	var count := maxi(ceili(states.size() / 41.0), 1)
	for chunk_index in count:
		var start := chunk_index * 41
		var end := mini(start + 41, states.size())
		# Match the pre-optimization coordinator plus range codec: whole-batch
		# validation followed by a second validation of each range.
		for index in range(start, end):
			if not SnapshotManager.is_enemy_snapshot_state_serializable(states[index]):
				return []
		var stream := StreamPeerBuffer.new()
		stream.put_u16(end - start)
		for index in range(start, end):
			var state := states[index]
			var previous: SnapshotManager.EnemyState = null if keyframe else baseline.get(state.net_id)
			SnapshotManager._write_enemy_snapshot(stream, state, previous)
			var stored: SnapshotManager.EnemyState = baseline.get(state.net_id)
			if stored == null:
				stored = SnapshotManager.EnemyState.new()
				baseline[state.net_id] = stored
			SnapshotManager._copy_enemy_state_into(state, stored)
		packets.append(stream.data_array)
	return packets


func _benchmark(states: Array[SnapshotManager.EnemyState]) -> Dictionary:
	var old_samples: Array[float] = []
	var new_samples: Array[float] = []
	for repeat_index in 5:
		var reference: Dictionary[int, SnapshotManager.EnemyState] = {}
		var sender := SnapshotManager.new()
		var old_total := 0
		var new_total := 0
		for sample in SAMPLE_COUNT:
			_mutate(states, sample)
			var keyframe := sample % 10 == 0
			# Alternating order limits warm-cache/thermal bias without concurrent
			# processes or using the Godot function profiler to measure throughput.
			if (sample + repeat_index) % 2 == 0:
				var before := Time.get_ticks_usec()
				_reference_chunks(states, reference, keyframe)
				old_total += Time.get_ticks_usec() - before
				before = Time.get_ticks_usec()
				sender.encode_enemy_snapshot_chunks_for_cohort(-1, states, keyframe)
				new_total += Time.get_ticks_usec() - before
			else:
				var before := Time.get_ticks_usec()
				sender.encode_enemy_snapshot_chunks_for_cohort(-1, states, keyframe)
				new_total += Time.get_ticks_usec() - before
				before = Time.get_ticks_usec()
				_reference_chunks(states, reference, keyframe)
				old_total += Time.get_ticks_usec() - before
		old_samples.append(old_total / 1000.0)
		new_samples.append(new_total / 1000.0)
	return {"reference_ms": old_samples, "quantized_baseline_ms": new_samples}
