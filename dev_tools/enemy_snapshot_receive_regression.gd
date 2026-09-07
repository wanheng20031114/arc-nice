extends SceneTree

var _failures: Array[String] = []
var _checks := 0


func _initialize() -> void:
	_run.call_deferred()


func _check(value: bool, message: String) -> void:
	_checks += 1
	if not value:
		_failures.append(message)


func _state(id: int, revision: int = 0) -> SnapshotManager.EnemyState:
	var result := SnapshotManager.EnemyState.new()
	result.net_id = id
	result.position = Vector2(id * 2, -id)
	result.health = 100 - revision
	result.health_revision = revision
	return result


func _fingerprint(codec: SnapshotManager) -> Array:
	var result: Array = []
	for id: int in codec.enemy_receive_baselines:
		var state: SnapshotManager.EnemyState = codec.enemy_receive_baselines[id]
		result.append([id, state.position, state.velocity, state.locomotion_state, state.health, state.health_revision, state.is_dead, state.visual_status_mask, state.faction_id, state.faction_revision])
	return result


func _old_receive(codec: SnapshotManager, packet: PackedByteArray, previous_ids: Dictionary) -> Array[SnapshotManager.EnemyState]:
	var ids: Array[int] = []
	if not codec.try_collect_decodable_enemy_snapshot_ids(packet, ids):
		return []
	for id in ids:
		if previous_ids.has(id): return []
	var states := codec.decode_enemy_snapshots_with_baseline(packet, false)
	# Preserve the old coordinator's final declared-count check in the reference.
	var stream := StreamPeerBuffer.new()
	stream.data_array = packet
	if states.size() != stream.get_u16(): return []
	return states


func _assert_atomic_rejection(packet: PackedByteArray, forbidden: Dictionary, message: String) -> void:
	var codec := SnapshotManager.new()
	var initial: Array[SnapshotManager.EnemyState] = [_state(1), _state(2)]
	codec.decode_enemy_snapshot_chunk(SnapshotManager.new().encode_all_enemy_snapshots(initial), {})
	var before := _fingerprint(codec)
	var old_output: SnapshotManager.EnemyState = codec.enemy_receive_output_states[1]
	_check(codec.decode_enemy_snapshot_chunk(packet, forbidden).is_empty(), message + " rejected")
	_check(_fingerprint(codec) == before and old_output.health_revision == 0, message + " kept baseline/output atomic")


func _run() -> void:
	var revised: Array[SnapshotManager.EnemyState] = [_state(1, 1), _state(2, 1)]
	var valid := SnapshotManager.new().encode_all_enemy_snapshots(revised)
	for size in valid.size():
		_assert_atomic_rejection(valid.slice(0, size), {}, "Truncation %d" % size)
	var trailing := valid.duplicate()
	trailing.append(0)
	_assert_atomic_rejection(trailing, {}, "Trailing data")
	for record in 2:
		var start := 2 + record * 29
		for reserved_bit in [4, 128]:
			var bad_mask := valid.duplicate()
			bad_mask[start + 4] |= reserved_bit
			_assert_atomic_rejection(bad_mask, {}, "Reserved mask")
		var bad_health := valid.duplicate()
		bad_health.encode_s32(start + 14, -1)
		_assert_atomic_rejection(bad_health, {}, "Negative health")
		var bad_revision := valid.duplicate()
		bad_revision.encode_u32(start + 18, 0xffffffff)
		_assert_atomic_rejection(bad_revision, {}, "Overflow health revision")
		var bad_faction := valid.duplicate()
		bad_faction[start + 24] = 255
		_assert_atomic_rejection(bad_faction, {}, "Unknown faction")
	var duplicate := valid.duplicate()
	duplicate.encode_s32(31, 1)
	_assert_atomic_rejection(duplicate, {}, "Same-chunk duplicate")
	_assert_atomic_rejection(valid, {1: true}, "Earlier chunk duplicate first")
	_assert_atomic_rejection(valid, {2: true}, "Earlier chunk duplicate last")
	var missing_previous := _state(99)
	var missing_current := _state(99, 1)
	var unknown_delta := PackedByteArray([2, 0])
	unknown_delta.append_array(SnapshotManager.encode_enemy_snapshot(revised[0], null))
	unknown_delta.append_array(SnapshotManager.encode_enemy_snapshot(missing_current, missing_previous))
	_assert_atomic_rejection(unknown_delta, {}, "Unknown delta baseline")
	var legacy := SnapshotManager.new()
	_check(legacy.decode_enemy_snapshots_with_baseline(unknown_delta, false).size() == 1, "Legacy direct decode still skips missing delta only")
	_check(SnapshotManager.new().decode_enemy_snapshot_chunk(PackedByteArray([0, 0]), {}).is_empty(), "Valid empty roster")
	_check(SnapshotManager.new().decode_enemy_snapshot_chunk(valid, {}).size() == 2, "Unknown nodes can receive independent full keyframes")
	_check_coordinator_ordering()
	var timings := _benchmark()
	print("ENEMY_SNAPSHOT_RECEIVE ", JSON.stringify({"checks": _checks, "timings": timings, "failures": _failures}))
	quit(0 if _failures.is_empty() else 1)


func _check_coordinator_ordering() -> void:
	var runtime := TowerDefenseGame.new()
	runtime.runtime_mode = CombatRuntimeBase.RuntimeMode.CLIENT_VIEW
	var coordinator := MpEnemyCoordinator.new()
	coordinator.bind_runtime(runtime)
	var states: Array[SnapshotManager.EnemyState] = []
	var live_enemies: Array[Enemy] = []
	var enemy_scene := load("res://scene/enemy/enemy.tscn") as PackedScene
	for index in 42:
		states.append(_state(index + 1))
		var enemy := enemy_scene.instantiate() as Enemy
		enemy.is_multiplayer_proxy = true
		root.add_child(enemy)
		enemy.set_process(false)
		enemy.set_physics_process(false)
		runtime.register_network_enemy(index + 1, enemy)
		live_enemies.append(enemy)
	var packets := SnapshotManager.new().encode_enemy_snapshot_chunks_for_cohort(-1, states, true)
	coordinator.apply_authoritative_snapshot(1.0, packets[0], 10, 0, 2, 20, 1.0)
	_check(coordinator.pending_enemy_snapshot_batches.has(10), "First chunk staged batch metadata")
	var before := _fingerprint(coordinator._snapshot_manager)
	var wrong_metadata := packets[1].duplicate()
	coordinator.apply_authoritative_snapshot(1.0, wrong_metadata, 10, 1, 3, 20, 1.0)
	_check(not coordinator.pending_enemy_snapshot_batches.has(10), "Conflicting metadata invalidates pending batch")
	_check(_fingerprint(coordinator._snapshot_manager) == before, "Metadata mismatch did not commit next chunk")
	coordinator.apply_authoritative_snapshot(2.0, packets[1], 20, 1, 2, 20, 2.0)
	coordinator.apply_authoritative_snapshot(2.0, packets[0], 20, 0, 2, 20, 2.0)
	_check(coordinator._last_completed_snapshot_batch_id == 20, "Reverse chunk order completed identical roster")
	before = _fingerprint(coordinator._snapshot_manager)
	var invalid_new_batch := packets[0].duplicate()
	invalid_new_batch[2 + 24] = 255
	coordinator.apply_authoritative_snapshot(3.0, invalid_new_batch, 1000, 0, 2, 20, 3.0)
	_check(coordinator._latest_snapshot_batch_seen == 20, "Invalid high batch cannot advance receive watermark")
	_check(_fingerprint(coordinator._snapshot_manager) == before, "Invalid high batch kept previous baselines")
	coordinator.apply_authoritative_snapshot(3.0, PackedByteArray([0, 0, 0]), 21, 0, 1, 20, 3.0)
	_check(coordinator._last_completed_snapshot_batch_id == 20, "Empty header with trailing byte rejected")
	coordinator.apply_authoritative_snapshot(3.0, PackedByteArray([0, 0]), 21, 0, 1, 20, 3.0)
	_check(coordinator._last_completed_snapshot_batch_id == 21 and coordinator._snapshot_manager.enemy_receive_baselines.is_empty(), "Valid empty batch clears old roster baseline")
	coordinator.unbind_runtime(runtime)
	coordinator.free()
	runtime.clear_network_enemy_registry()
	for enemy in live_enemies:
		if is_instance_valid(enemy): enemy.free()
	runtime.free()


func _benchmark() -> Dictionary:
	var sender := SnapshotManager.new()
	var states: Array[SnapshotManager.EnemyState] = []
	for index in 300: states.append(_state(index + 1))
	var samples: Array = []
	for sample in 120:
		for state in states:
			state.position.x += 0.75
			state.velocity = Vector2(15.0, 0)
			state.locomotion_state = 1
		samples.append(sender.encode_enemy_snapshot_chunks_for_cohort(-1, states, sample % 10 == 0))
	var old_ms: Array[float] = []
	var new_ms: Array[float] = []
	for repetition in 3:
		var old_codec := SnapshotManager.new()
		var new_codec := SnapshotManager.new()
		var old_usec := 0
		var new_usec := 0
		for sample in samples.size():
			var old_ids := {}
			var new_ids := {}
			for packet: PackedByteArray in samples[sample]:
				var old_states: Array[SnapshotManager.EnemyState]
				var new_states: Array[SnapshotManager.EnemyState]
				var before := Time.get_ticks_usec()
				if (sample + repetition) % 2 == 0:
					old_states = _old_receive(old_codec, packet, old_ids)
					old_usec += Time.get_ticks_usec() - before
					before = Time.get_ticks_usec()
					new_states = new_codec.decode_enemy_snapshot_chunk(packet, new_ids)
					new_usec += Time.get_ticks_usec() - before
				else:
					new_states = new_codec.decode_enemy_snapshot_chunk(packet, new_ids)
					new_usec += Time.get_ticks_usec() - before
					before = Time.get_ticks_usec()
					old_states = _old_receive(old_codec, packet, old_ids)
					old_usec += Time.get_ticks_usec() - before
				_check(old_states.size() == new_states.size(), "Decoded count parity")
				for state in old_states: old_ids[state.net_id] = true
				for state in new_states: new_ids[state.net_id] = true
			_check(_fingerprint(old_codec) == _fingerprint(new_codec), "300-enemy delta/full baseline parity")
		old_ms.append(old_usec / 1000.0)
		new_ms.append(new_usec / 1000.0)
	return {"entities": 300, "samples": 120, "old_prescan_ms": old_ms, "atomic_single_scan_ms": new_ms}
