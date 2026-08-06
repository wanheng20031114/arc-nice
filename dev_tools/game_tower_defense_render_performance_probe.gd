extends SceneTree

# Run this probe with a real display driver (not --headless) so Godot's render
# monitors include CanvasItem batching and draw calls. The window can be placed
# off-screen from the command line during automated profiling.
const TOWER_SCENE := preload("res://scene/game_modes/tower_defense/tower_defense_game.tscn")
const SAMPLE_FRAMES := 180
const EXPECTED_ENEMIES := 300

var failures: Array[String] = []
var game: TowerDefenseGame = null


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	game = TOWER_SCENE.instantiate() as TowerDefenseGame
	_expect(game != null, "Render probe must instantiate tower defense.")
	if game == null:
		await _finish()
		return
	game.auto_start_waves = false
	root.add_child(game)
	current_scene = game
	await process_frame
	await physics_frame
	game.call("_schedule_enemy_navigation_prewarm")
	var preparation_deadline := Time.get_ticks_msec() + 30000
	while (
		not game.is_runtime_preparation_complete()
		and Time.get_ticks_msec() < preparation_deadline
	):
		await process_frame
	_expect(
		game.is_runtime_preparation_complete(),
		"Render probe must finish staged preparation."
	)

	var first_wave := game.waves[0] if not game.waves.is_empty() else null
	_expect(first_wave != null, "Render probe requires the first tower-defense wave.")
	if first_wave == null:
		await _finish()
		return
	game.call("_begin_flow_step", first_wave)
	game.enemy_spawn_timer.stop()
	while game.current_wave_spawned < EXPECTED_ENEMIES:
		game.enemy_coordinator.spawn_wave_batch(
			TowerDefenseCampaignCoordinator.MAX_WAVE_SPAWN_COUNT_PER_TICK
		)
		await process_frame
	_expect(
		game.enemy_coordinator.active_wave_enemy_ids.size() == EXPECTED_ENEMIES,
		"Render probe must hold exactly 300 live enemies."
	)

	# Let texture uploads, shader pipelines and the initial direct-navigation
	# decisions settle before recording the sustained window.
	for _warmup_frame in range(60):
		await process_frame

	var far_summary := await _sample_monitor_window(SAMPLE_FRAMES)
	_print_monitor_summary("far_home", far_summary)
	_expect(
		float((far_summary["draw_calls"] as Dictionary)["p50"]) > 0.0,
		"Render probe must use a real rendering driver; do not run it headless."
	)

	game.set_physics_process(false)
	if game.player != null:
		game.player.global_position = Vector2(-5000.0, -5000.0)
	var positioned_near_home := _position_enemies_at_home_distance(280.0)
	_expect(
		positioned_near_home == EXPECTED_ENEMIES,
		"Render probe must position all enemies inside the full-flow navigation band."
	)
	for _near_warmup_frame in range(60):
		await process_frame
	var near_summary := await _sample_monitor_window(SAMPLE_FRAMES)
	_print_monitor_summary("near_home_flow", near_summary)

	var positioned_inside_direct_tier := _position_enemies_at_home_distance(
		72.0,
		true
	)
	_expect(
		positioned_inside_direct_tier == EXPECTED_ENEMIES,
		"Render probe must position all enemies inside the near direct-sweep tier."
	)
	for _direct_warmup_frame in range(60):
		await process_frame
	var direct_summary := await _sample_monitor_window(SAMPLE_FRAMES)
	_print_monitor_summary("near_home_direct_sweep", direct_summary)
	var direct_wall := direct_summary["wall_frame"] as Dictionary
	var direct_physics := direct_summary["physics"] as Dictionary
	_expect(
		float(direct_wall["p95"]) < 20.0,
		"Three hundred near-Home direct sweeps must keep wall-frame p95 below 20ms."
	)
	_expect(
		float(direct_physics["p95"]) < 25.0,
		"Three hundred near-Home direct sweeps must keep physics p95 below 25ms."
	)
	await _finish()


func _position_enemies_at_home_distance(
	target_distance: float,
	freeze_movement: bool = false
) -> int:
	var home_targets := game.get_home_objective_targets()
	if home_targets.is_empty():
		return 0
	var home_target := home_targets[0]
	var positioned := 0
	for child in game.enemy_container.get_children():
		var enemy := child as Enemy
		if enemy == null or enemy.is_dead or enemy.config == null:
			continue
		var path: PackedVector2Array = game.grid_pathfinder.get_complete_global_path(
			enemy.global_position,
			home_target.global_position,
			enemy.get_configured_body_collision_half_extents(),
			enemy.config.terrain_traversal_types
		)
		if path.is_empty():
			continue
		var chosen_position: Vector2 = path[0]
		var best_distance_error := INF
		for waypoint_variant in path:
			var waypoint := waypoint_variant as Vector2
			var home_distance: float = waypoint.distance_to(home_target.global_position)
			var distance_error := absf(home_distance - target_distance)
			if home_distance < Enemy.FAR_STATIC_OBJECTIVE_DISTANCE and distance_error < best_distance_error:
				chosen_position = waypoint
				best_distance_error = distance_error
		if best_distance_error == INF:
			continue
		if (
			target_distance <= Enemy.NEAR_STATIC_DIRECT_OBJECTIVE_DISTANCE
			and chosen_position.distance_to(home_target.global_position)
				> Enemy.NEAR_STATIC_DIRECT_OBJECTIVE_DISTANCE
		):
			continue
		enemy.set_physics_process(false)
		enemy.global_position = chosen_position
		enemy.set_target_player(game.player)
		enemy.set_objective_target(home_target)
		enemy.call("_clear_navigation_path")
		if freeze_movement:
			enemy.cached_effective_move_speed = 0.0
			enemy.velocity = Vector2.ZERO
		enemy.set_physics_process(true)
		positioned += 1
	return positioned


func _sample_monitor_window(frame_count: int) -> Dictionary:
	var wall_frame_samples_ms: Array[float] = []
	var engine_frame_samples_ms: Array[float] = []
	var physics_samples_ms: Array[float] = []
	var draw_call_samples: Array[float] = []
	var render_object_samples: Array[float] = []
	var collision_pair_samples: Array[float] = []
	var previous_frame_tick_usec := Time.get_ticks_usec()
	for _sample_frame in range(frame_count):
		await process_frame
		var current_frame_tick_usec := Time.get_ticks_usec()
		wall_frame_samples_ms.append(
			float(current_frame_tick_usec - previous_frame_tick_usec) / 1000.0
		)
		previous_frame_tick_usec = current_frame_tick_usec
		engine_frame_samples_ms.append(
			Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
		)
		physics_samples_ms.append(
			Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
		)
		draw_call_samples.append(
			Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
		)
		render_object_samples.append(
			Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)
		)
		collision_pair_samples.append(
			Performance.get_monitor(Performance.PHYSICS_2D_COLLISION_PAIRS)
		)
	return {
		"wall_frame": _summarize(wall_frame_samples_ms),
		"engine_frame": _summarize(engine_frame_samples_ms),
		"physics": _summarize(physics_samples_ms),
		"draw_calls": _summarize(draw_call_samples),
		"render_objects": _summarize(render_object_samples),
		"collision_pairs": _summarize(collision_pair_samples),
	}


func _print_monitor_summary(label: String, summary: Dictionary) -> void:
	var wall_frame := summary["wall_frame"] as Dictionary
	var engine_frame := summary["engine_frame"] as Dictionary
	var physics := summary["physics"] as Dictionary
	var draw_calls := summary["draw_calls"] as Dictionary
	var render_objects := summary["render_objects"] as Dictionary
	var collision_pairs := summary["collision_pairs"] as Dictionary
	print(
		(
			"TOWER_DEFENSE_RENDER_PROBE phase=%s enemies=%d "
			+ "wall_p50_ms=%.3f wall_p95_ms=%.3f wall_p99_ms=%.3f "
			+ "engine_frame_ms=%.3f "
			+ "physics_p50_ms=%.3f physics_p95_ms=%.3f physics_p99_ms=%.3f "
			+ "draw_p50=%.0f draw_p95=%.0f objects_p50=%.0f objects_p95=%.0f "
			+ "collision_pairs_p50=%.0f collision_pairs_p95=%.0f nodes=%.0f"
		) % [
			label,
			game.enemy_coordinator.active_wave_enemy_ids.size(),
			wall_frame["p50"],
			wall_frame["p95"],
			wall_frame["p99"],
			engine_frame["p50"],
			physics["p50"],
			physics["p95"],
			physics["p99"],
			draw_calls["p50"],
			draw_calls["p95"],
			render_objects["p50"],
			render_objects["p95"],
			collision_pairs["p50"],
			collision_pairs["p95"],
			Performance.get_monitor(Performance.OBJECT_NODE_COUNT),
		]
	)


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


func _finish() -> void:
	current_scene = null
	if game != null:
		game.queue_free()
	for _cleanup_frame in range(8):
		await process_frame
		await physics_frame
	if failures.is_empty():
		print("GAME_TOWER_DEFENSE_RENDER_PERFORMANCE_PROBE_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
