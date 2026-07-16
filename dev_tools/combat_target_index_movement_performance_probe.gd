extends SceneTree

# End-to-end A/B for moving CombatTargetIndex members. The event-driven side
# uses the production transform-notification binding. The audit side detaches
# that binding and reconstructs the retired once-per-simulated-frame O(N)
# reconciliation. Timed regions include position assignment, index maintenance
# and every query; fixture resets and equivalence checks stay outside timing.

const ENEMY_COUNTS := [300, 1000]
const QUERIES_PER_FRAME := [0, 1, 3, 8]
const SAMPLE_PAIRS := 9
const WARMUP_PAIRS := 2
const SIMULATED_FRAMES := 24
const BUCKET_SIZE := 96.0
const QUERY_RADIUS := 112.0

const MODE_EVENT := 0
const MODE_FULL_AUDIT := 1
const MODE_UNBOUND_MOVE_ONLY := 2

const MOVEMENT_REALISTIC := 0
const MOVEMENT_WORST_CASE := 1


class TestEnemy:
	extends Enemy

	func _ready() -> void:
		pass

	func _physics_process(_delta: float) -> void:
		pass


var failures: Array[String] = []
var fixture_root: Node2D


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	fixture_root = Node2D.new()
	fixture_root.name = "CombatTargetIndexMovementPerformanceProbe"
	root.add_child(fixture_root)
	current_scene = fixture_root

	for enemy_count in ENEMY_COUNTS:
		await _run_enemy_count(int(enemy_count))

	current_scene = null
	fixture_root.queue_free()
	for _cleanup_frame in range(3):
		await process_frame
		await physics_frame
	if failures.is_empty():
		print("COMBAT_TARGET_INDEX_MOVEMENT_PERFORMANCE_PROBE_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _run_enemy_count(enemy_count: int) -> void:
	var cohort_root := Node2D.new()
	cohort_root.name = "Enemies%d" % enemy_count
	fixture_root.add_child(cohort_root)
	var index := CombatTargetIndex.new()
	index.bucket_size = BUCKET_SIZE
	var enemies: Array[Enemy] = []
	for enemy_index in range(enemy_count):
		var enemy := _new_tree_safe_test_enemy()
		enemy.name = "TestEnemy%d" % enemy_index
		cohort_root.add_child(enemy)
		enemies.append(enemy)
		index.register_enemy(enemy_index + 1, enemy)

	_expect(
		index.enemies_by_net_id.size() == enemy_count,
		"Fixture must register all %d enemies." % enemy_count
	)
	for movement_mode in [MOVEMENT_REALISTIC, MOVEMENT_WORST_CASE]:
		for query_count in QUERIES_PER_FRAME:
			var safe_query_count := int(query_count)
			_validate_equivalence(
				index,
				enemies,
				enemy_count,
				int(movement_mode),
				safe_query_count
			)
			_run_case_ab(
				index,
				enemies,
				enemy_count,
				int(movement_mode),
				safe_query_count
			)

	index.clear()
	cohort_root.queue_free()
	await process_frame


func _new_tree_safe_test_enemy() -> TestEnemy:
	# Enemy's typed @onready references are resolved before this fixture's no-op
	# _ready override, so retain the production node contract without running any
	# animation, audio, collision or gameplay processing in the benchmark.
	var enemy := TestEnemy.new()
	var animated_sprite := AnimatedSprite2D.new()
	animated_sprite.name = "AnimatedSprite2D"
	enemy.add_child(animated_sprite)
	var touch_damage_area := Area2D.new()
	touch_damage_area.name = "TouchDamageArea"
	enemy.add_child(touch_damage_area)
	var hit_audio := AudioStreamPlayer2D.new()
	hit_audio.name = "HitAudio"
	enemy.add_child(hit_audio)
	var death_audio := AudioStreamPlayer2D.new()
	death_audio.name = "DeathAudio"
	enemy.add_child(death_audio)
	return enemy


func _validate_equivalence(
	index: CombatTargetIndex,
	enemies: Array[Enemy],
	enemy_count: int,
	movement_mode: int,
	query_count: int
) -> void:
	_prepare_run(index, enemies, movement_mode, MODE_EVENT)
	var event_signature := _execute_sequence(
		index,
		enemies,
		movement_mode,
		query_count,
		MODE_EVENT,
		true
	)["signature"] as Array
	_expect(
		_assert_index_matches_positions(index, enemies),
		"Event index buckets diverged after %s movement with %d enemies."
		% [_movement_label(movement_mode), enemy_count]
	)

	_prepare_run(index, enemies, movement_mode, MODE_FULL_AUDIT)
	var audit_signature := _execute_sequence(
		index,
		enemies,
		movement_mode,
		query_count,
		MODE_FULL_AUDIT,
		true
	)["signature"] as Array
	_expect(
		_assert_index_matches_positions(index, enemies),
		"Full-audit index buckets diverged after %s movement with %d enemies."
		% [_movement_label(movement_mode), enemy_count]
	)
	_expect(
		event_signature == audit_signature,
		(
			"Event/full-audit query semantics differ: enemies=%d movement=%s "
			+ "queries_per_frame=%d event_entries=%d audit_entries=%d."
		)
		% [
			enemy_count,
			_movement_label(movement_mode),
			query_count,
			event_signature.size(),
			audit_signature.size(),
		]
	)
	if query_count > 0:
		_expect(
			event_signature.size() == SIMULATED_FRAMES * query_count * 2,
			"Every validation query must contribute a result count and nearest id."
		)


func _run_case_ab(
	index: CombatTargetIndex,
	enemies: Array[Enemy],
	enemy_count: int,
	movement_mode: int,
	query_count: int
) -> void:
	for warmup_index in range(WARMUP_PAIRS):
		if warmup_index % 2 == 0:
			_measure_mode(index, enemies, movement_mode, query_count, MODE_EVENT)
			_measure_mode(index, enemies, movement_mode, query_count, MODE_FULL_AUDIT)
		else:
			_measure_mode(index, enemies, movement_mode, query_count, MODE_FULL_AUDIT)
			_measure_mode(index, enemies, movement_mode, query_count, MODE_EVENT)

	var event_samples: Array[int] = []
	var audit_samples: Array[int] = []
	var bare_move_samples: Array[int] = []
	for sample_index in range(SAMPLE_PAIRS):
		if sample_index % 2 == 0:
			event_samples.append(
				_measure_mode(index, enemies, movement_mode, query_count, MODE_EVENT)
			)
			audit_samples.append(
				_measure_mode(index, enemies, movement_mode, query_count, MODE_FULL_AUDIT)
			)
		else:
			audit_samples.append(
				_measure_mode(index, enemies, movement_mode, query_count, MODE_FULL_AUDIT)
			)
			event_samples.append(
				_measure_mode(index, enemies, movement_mode, query_count, MODE_EVENT)
			)
		if query_count == 0:
			bare_move_samples.append(
				_measure_mode(
					index,
					enemies,
					movement_mode,
					0,
					MODE_UNBOUND_MOVE_ONLY
				)
			)

	event_samples.sort()
	audit_samples.sort()
	var event_median := event_samples[event_samples.size() / 2]
	var audit_median := audit_samples[audit_samples.size() / 2]
	var speedup := float(audit_median) / float(maxi(event_median, 1))
	var event_per_frame := float(event_median) / float(SIMULATED_FRAMES)
	var audit_per_frame := float(audit_median) / float(SIMULATED_FRAMES)

	if query_count == 0:
		bare_move_samples.sort()
		var bare_move_median := bare_move_samples[bare_move_samples.size() / 2]
		var event_overhead := maxi(event_median - bare_move_median, 0)
		var assignments := enemy_count * SIMULATED_FRAMES
		print(
			(
				"COMBAT_TARGET_INDEX_MOVEMENT_EVENT_OVERHEAD enemies=%d "
				+ "movement=%s frames=%d assignments=%d bare_move_median_usec=%d "
				+ "event_median_usec=%d event_overhead_usec=%d "
				+ "event_overhead_per_assignment_usec=%.4f "
				+ "old_full_audit_median_usec=%d old_over_event=%.2fx"
			)
			% [
				enemy_count,
				_movement_label(movement_mode),
				SIMULATED_FRAMES,
				assignments,
				bare_move_median,
				event_median,
				event_overhead,
				float(event_overhead) / float(maxi(assignments, 1)),
				audit_median,
				speedup,
			]
		)
		return

	print(
		(
			"COMBAT_TARGET_INDEX_MOVEMENT_AB enemies=%d movement=%s frames=%d "
			+ "queries_per_frame=%d total_queries=%d event_median_usec=%d "
			+ "old_full_audit_median_usec=%d event_usec_per_frame=%.1f "
			+ "old_usec_per_frame=%.1f old_over_event=%.2fx"
		)
		% [
			enemy_count,
			_movement_label(movement_mode),
			SIMULATED_FRAMES,
			query_count,
			SIMULATED_FRAMES * query_count,
			event_median,
			audit_median,
			event_per_frame,
			audit_per_frame,
			speedup,
		]
	)

	# Total-work thresholds deliberately include absolute per-frame slack so tiny
	# timer noise cannot fail the probe. Realistic movement should not regress the
	# former O(N) audit; in the artificial all-enemies-cross-every-frame case, the
	# event path may be modestly slower but must stay far from catastrophic.
	if movement_mode == MOVEMENT_REALISTIC:
		_expect(
			event_per_frame <= audit_per_frame * 1.15 + 100.0,
			(
				"Realistic event maintenance regressed total query workload: "
				+ "enemies=%d qpf=%d event=%.1fus/frame audit=%.1fus/frame."
			)
			% [enemy_count, query_count, event_per_frame, audit_per_frame]
		)
	else:
		_expect(
			event_per_frame <= audit_per_frame * 1.50 + 150.0,
			(
				"Worst-case event maintenance regressed catastrophically: "
				+ "enemies=%d qpf=%d event=%.1fus/frame audit=%.1fus/frame."
			)
			% [enemy_count, query_count, event_per_frame, audit_per_frame]
		)


func _measure_mode(
	index: CombatTargetIndex,
	enemies: Array[Enemy],
	movement_mode: int,
	query_count: int,
	mode: int
) -> int:
	_prepare_run(index, enemies, movement_mode, mode)
	return int(_execute_sequence(
		index,
		enemies,
		movement_mode,
		query_count,
		mode,
		false
	)["elapsed_usec"])


func _prepare_run(
	index: CombatTargetIndex,
	enemies: Array[Enemy],
	movement_mode: int,
	mode: int
) -> void:
	# Detach before resetting so neither side gets charged for fixture setup.
	for enemy_index in range(enemies.size()):
		var enemy := enemies[enemy_index]
		if enemy.combat_target_index_binding != null:
			enemy.unbind_combat_target_index(index, enemy_index + 1)
		enemy.position = _position_for(enemy_index, 0, movement_mode)

	# Reconcile the reset once outside timing. The old side stays detached; the
	# event side binds only after storage and positions already agree.
	_legacy_full_audit(index)
	if mode == MODE_EVENT:
		for enemy_index in range(enemies.size()):
			enemies[enemy_index].bind_combat_target_index(index, enemy_index + 1)
	index._last_refresh_physics_frame = Engine.get_physics_frames()


func _execute_sequence(
	index: CombatTargetIndex,
	enemies: Array[Enemy],
	movement_mode: int,
	query_count: int,
	mode: int,
	collect_signature: bool
) -> Dictionary:
	var signature: Array[int] = []
	var result: Array[Enemy] = []
	var checksum := 0
	var started_usec := Time.get_ticks_usec()
	for simulated_frame in range(1, SIMULATED_FRAMES + 1):
		for enemy_index in range(enemies.size()):
			enemies[enemy_index].position = _position_for(
				enemy_index,
				simulated_frame,
				movement_mode
			)
		if mode == MODE_FULL_AUDIT:
			_legacy_full_audit(index)
		elif mode == MODE_EVENT and query_count > 0:
			# Model a new physics frame so the first production query also pays its
			# current bounded safety-repair slice. With zero queries no such work is
			# scheduled in game, leaving that row as pure notification overhead.
			index._last_refresh_physics_frame = -1
		for query_index in range(query_count):
			var target_index := (
				simulated_frame * 97 + query_index * 193
			) % enemies.size()
			var center := enemies[target_index].position + Vector2(7.0, -5.0)
			index.query_radius_into(center, QUERY_RADIUS, result, 1)
			checksum += result.size()
			if collect_signature:
				signature.append(result.size())
				signature.append(
					0 if result.is_empty() else int(result[0].get_instance_id())
				)
	var elapsed_usec := Time.get_ticks_usec() - started_usec
	if query_count > 0 and checksum != SIMULATED_FRAMES * query_count:
		failures.append(
			"Timed sequence lost a nearby target: mode=%d movement=%s qpf=%d."
			% [mode, _movement_label(movement_mode), query_count]
		)
	return {
		"elapsed_usec": elapsed_usec,
		"signature": signature,
	}


func _legacy_full_audit(index: CombatTargetIndex) -> void:
	# Reconstruct the retired query-frame audit locally instead of routing through
	# the production safety repair, which is intentionally bounded and therefore
	# no longer represents the A side. All fixture entries are live, so the old
	# stale-entry collection branch would be dead work in both implementations.
	var safe_bucket_size := maxf(index.bucket_size, 1.0)
	for net_id_variant in index.enemies_by_net_id:
		var net_id := int(net_id_variant)
		var enemy := index.enemies_by_net_id.get(net_id) as Enemy
		if enemy == null or not is_instance_valid(enemy) or enemy.is_dead:
			continue
		var next_cell := Vector2i(
			floori(enemy.global_position.x / safe_bucket_size),
			floori(enemy.global_position.y / safe_bucket_size)
		)
		if not index.bucket_by_net_id.has(net_id):
			index._add_net_id_to_bucket(net_id, next_cell)
			continue
		var previous_cell: Vector2i = index.bucket_by_net_id[net_id]
		if previous_cell == next_cell:
			continue
		index._remove_net_id_from_bucket(net_id)
		index._add_net_id_to_bucket(net_id, next_cell)


func _position_for(enemy_index: int, simulated_frame: int, movement_mode: int) -> Vector2:
	var local_x := float((enemy_index * 37) % int(BUCKET_SIZE)) + 0.25
	var local_y := float((enemy_index * 53) % int(BUCKET_SIZE)) + 0.25
	var base_bucket_x := enemy_index % 32
	var base_bucket_y := (enemy_index / 32) % 32
	if movement_mode == MOVEMENT_REALISTIC:
		# 3.25 px/frame with uniformly distributed starting offsets: only about
		# 3.4% of enemies cross an X bucket boundary in an ordinary frame.
		return Vector2(
			float(base_bucket_x) * BUCKET_SIZE
				+ local_x
				+ float(simulated_frame) * 3.25,
			float(base_bucket_y) * BUCKET_SIZE
				+ local_y
				+ float((simulated_frame + enemy_index) % 5) * 0.2
		)
	# Deliberate stress bound: every assignment teleports every enemy by three
	# complete buckets, forcing the event and audit paths to migrate every entry.
	return Vector2(
		float(base_bucket_x + simulated_frame * 3) * BUCKET_SIZE + local_x,
		float(base_bucket_y) * BUCKET_SIZE + local_y
	)


func _assert_index_matches_positions(
	index: CombatTargetIndex,
	enemies: Array[Enemy]
) -> bool:
	for enemy_index in range(enemies.size()):
		var expected_bucket := Vector2i(
			floori(enemies[enemy_index].position.x / BUCKET_SIZE),
			floori(enemies[enemy_index].position.y / BUCKET_SIZE)
		)
		if index.bucket_by_net_id.get(enemy_index + 1, Vector2i.MAX) != expected_bucket:
			return false
	return true


func _movement_label(movement_mode: int) -> String:
	return "realistic_small_step" if movement_mode == MOVEMENT_REALISTIC else "worst_every_move_crosses_bucket"


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
