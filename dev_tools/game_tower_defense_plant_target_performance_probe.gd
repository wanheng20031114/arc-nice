extends SceneTree

# Headless CPU A/B for the single-player plant-target query. It compares the
# former full EnemyContainer scan with the production CombatTargetIndex while
# keeping enemy instances, positions, query centers and deterministic ordering
# identical. Timings are diagnostic; semantic parity is the regression gate.
const TOWER_SCENE := preload("res://scene/game_tower_defense.tscn")
const BASIC_CONFIG := preload("res://resources/config/enemies/yuanshi_insect_basic.tres")

const ENEMY_COUNT := 300
const ENEMY_COLUMNS := 30
const ENEMY_SPACING := Vector2(64.0, 64.0)
const QUERY_COLUMNS := 8
const QUERY_COUNT := 32
const QUERY_SPACING := Vector2(128.0, 128.0)
const QUERY_RADIUS := 176.0
const WARMUP_SWEEPS := 8
const SAMPLE_SWEEPS := 60
const FIXTURE_ORIGIN := Vector2(3000.0, 3000.0)

var failures: Array[String] = []
var game: GameTowerDefense = null
var enemies: Array[Enemy] = []
var query_centers := PackedVector2Array()
var reusable_indexed_targets: Array[Enemy] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	game = TOWER_SCENE.instantiate() as GameTowerDefense
	_expect(game != null, "Plant-target performance probe must instantiate tower defense.")
	if game == null:
		await _finish()
		return
	game.auto_start_waves = false
	root.add_child(game)
	current_scene = game
	await process_frame
	await physics_frame
	game.set_process(false)
	game.set_physics_process(false)
	game.enemy_spawn_timer.stop()
	game.state_timer.stop()

	_spawn_frozen_enemies()
	_build_query_centers()
	await process_frame
	await physics_frame
	_expect(enemies.size() == ENEMY_COUNT, "Probe must create exactly 300 enemies.")
	_expect(
		game.combat_target_index.enemies_by_net_id.size() == ENEMY_COUNT,
		"Every manually added single-player enemy must be present in CombatTargetIndex."
	)
	_verify_query_parity()

	for _warmup_index in range(WARMUP_SWEEPS):
		await physics_frame
		_run_indexed_sweep()
		_run_reused_indexed_sweep()
		_run_legacy_sweep()

	var indexed_samples: Array[float] = []
	var legacy_samples: Array[float] = []
	for sample_index in range(SAMPLE_SWEEPS):
		await physics_frame
		if sample_index % 2 == 0:
			indexed_samples.append(_measure_indexed_sweep())
			legacy_samples.append(_measure_legacy_sweep())
		else:
			legacy_samples.append(_measure_legacy_sweep())
			indexed_samples.append(_measure_indexed_sweep())
	# Keep the original indexed-vs-legacy loop unchanged so its old/new numbers
	# remain comparable. Measure the reusable API in separate physics frames so it
	# also pays the once-per-frame index refresh instead of inheriting a warm index.
	var reused_indexed_samples: Array[float] = []
	for sample_index in range(SAMPLE_SWEEPS):
		await physics_frame
		if sample_index % 2 == 0:
			reused_indexed_samples.append(_measure_reused_indexed_sweep())
			_run_legacy_sweep()
		else:
			_run_legacy_sweep()
			reused_indexed_samples.append(_measure_reused_indexed_sweep())

	var indexed_summary := _summarize(indexed_samples)
	var reused_indexed_summary := _summarize(reused_indexed_samples)
	var legacy_summary := _summarize(legacy_samples)
	var crowded_migration_ms := await _measure_crowded_bucket_migration()
	print(
		(
			"PLANT_TARGET_QUERY_PROBE enemies=%d queries_per_sweep=%d samples=%d "
			+ "indexed_ms=%s indexed_reuse_ms=%s legacy_ms=%s "
			+ "speedup_p50=%.2f reuse_speedup_p50=%.2f crowded_migration_ms=%.3f"
		)
		% [
			ENEMY_COUNT,
			QUERY_COUNT,
			SAMPLE_SWEEPS,
			_format_summary(indexed_summary),
			_format_summary(reused_indexed_summary),
			_format_summary(legacy_summary),
			float(legacy_summary["p50"]) / maxf(float(indexed_summary["p50"]), 0.001),
			float(legacy_summary["p50"])
			/ maxf(float(reused_indexed_summary["p50"]), 0.001),
			crowded_migration_ms,
		]
	)
	await _finish()


func _spawn_frozen_enemies() -> void:
	for enemy_index in range(ENEMY_COUNT):
		var enemy := BASIC_CONFIG.enemy_scene.instantiate() as Enemy
		if enemy == null:
			continue
		game.enemy_container.add_child(enemy)
		enemy.global_position = FIXTURE_ORIGIN + Vector2(
			float(enemy_index % ENEMY_COLUMNS) * ENEMY_SPACING.x,
			float(enemy_index / ENEMY_COLUMNS) * ENEMY_SPACING.y
		)
		enemy.setup(BASIC_CONFIG, game.player, null)
		enemy.velocity = Vector2.ZERO
		enemy.set_process(false)
		enemy.set_physics_process(false)
		enemy.collision_layer = 0
		enemy.collision_mask = 0
		enemies.append(enemy)


func _build_query_centers() -> void:
	query_centers.clear()
	for query_index in range(QUERY_COUNT):
		query_centers.append(
			FIXTURE_ORIGIN
			+ Vector2(
				float(query_index % QUERY_COLUMNS) * QUERY_SPACING.x,
				float(query_index / QUERY_COLUMNS) * QUERY_SPACING.y
			)
		)


func _verify_query_parity() -> void:
	for center in query_centers:
		var indexed := game.query_combat_targets(center, QUERY_RADIUS, 0)
		var legacy := _legacy_query(center, QUERY_RADIUS)
		_expect(
			indexed.size() == legacy.size(),
			"Indexed and legacy queries must return the same target count at %s." % center
		)
		if indexed.size() != legacy.size():
			continue
		for target_index in range(indexed.size()):
			_expect(
				indexed[target_index] == legacy[target_index],
				"Indexed queries must preserve deterministic distance/id ordering."
			)


func _measure_indexed_sweep() -> float:
	var started_usec := Time.get_ticks_usec()
	_run_indexed_sweep()
	return float(Time.get_ticks_usec() - started_usec) / 1000.0


func _measure_legacy_sweep() -> float:
	var started_usec := Time.get_ticks_usec()
	_run_legacy_sweep()
	return float(Time.get_ticks_usec() - started_usec) / 1000.0


func _measure_reused_indexed_sweep() -> float:
	var started_usec := Time.get_ticks_usec()
	_run_reused_indexed_sweep()
	return float(Time.get_ticks_usec() - started_usec) / 1000.0


func _run_indexed_sweep() -> void:
	for center in query_centers:
		game.query_combat_targets(center, QUERY_RADIUS, 0)


func _run_reused_indexed_sweep() -> void:
	for center in query_centers:
		game.query_combat_targets_into(
			center,
			QUERY_RADIUS,
			reusable_indexed_targets,
			0
		)


func _measure_crowded_bucket_migration() -> float:
	var clustered_origin := FIXTURE_ORIGIN + Vector2(4096.0, 0.0)
	for enemy in enemies:
		enemy.global_position = clustered_origin
	await physics_frame
	_expect(
		game.query_combat_targets(clustered_origin, 2.0, 0).size() == ENEMY_COUNT,
		"Crowded migration warmup must place all targets in one bucket."
	)
	var migrated_origin := clustered_origin + Vector2(game.combat_target_index.bucket_size * 2.0, 0.0)
	for enemy in enemies:
		enemy.global_position = migrated_origin
	await physics_frame
	var started_usec := Time.get_ticks_usec()
	game.query_combat_targets_into(
		migrated_origin,
		2.0,
		reusable_indexed_targets,
		0
	)
	var elapsed_ms := float(Time.get_ticks_usec() - started_usec) / 1000.0
	_expect(
		reusable_indexed_targets.size() == ENEMY_COUNT,
		"Crowded whole-bucket migration must retain all targets."
	)
	return elapsed_ms


func _run_legacy_sweep() -> void:
	for center in query_centers:
		_legacy_query(center, QUERY_RADIUS)


func _legacy_query(center: Vector2, radius: float) -> Array[Enemy]:
	var result: Array[Enemy] = []
	var radius_squared := maxf(radius, 0.0) * maxf(radius, 0.0)
	for child in game.enemy_container.get_children():
		var enemy := child as Enemy
		if (
			enemy == null
			or enemy.is_dead
			or center.distance_squared_to(enemy.global_position) > radius_squared
		):
			continue
		result.append(enemy)
	result.sort_custom(
		func(a: Enemy, b: Enemy) -> bool:
			var a_distance := center.distance_squared_to(a.global_position)
			var b_distance := center.distance_squared_to(b.global_position)
			if not is_equal_approx(a_distance, b_distance):
				return a_distance < b_distance
			return a.get_instance_id() < b.get_instance_id()
	)
	return result


func _summarize(samples: Array[float]) -> Dictionary:
	if samples.is_empty():
		return {"p50": 0.0, "p95": 0.0, "p99": 0.0, "max": 0.0}
	var sorted := samples.duplicate()
	sorted.sort()
	return {
		"p50": _nearest_rank(sorted, 0.50),
		"p95": _nearest_rank(sorted, 0.95),
		"p99": _nearest_rank(sorted, 0.99),
		"max": sorted.back(),
	}


func _nearest_rank(sorted: Array[float], percentile: float) -> float:
	var rank := ceili(clampf(percentile, 0.0, 1.0) * sorted.size())
	return sorted[clampi(rank - 1, 0, sorted.size() - 1)]


func _format_summary(summary: Dictionary) -> String:
	return "%.3f/%.3f/%.3f/%.3f" % [
		summary["p50"],
		summary["p95"],
		summary["p99"],
		summary["max"],
	]


func _finish() -> void:
	for enemy in enemies:
		if enemy != null and is_instance_valid(enemy):
			enemy.queue_free()
	enemies.clear()
	current_scene = null
	if game != null and is_instance_valid(game):
		game.queue_free()
	for _cleanup_index in range(8):
		await process_frame
		await physics_frame
	if failures.is_empty():
		print("GAME_TOWER_DEFENSE_PLANT_TARGET_PERFORMANCE_PROBE_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
