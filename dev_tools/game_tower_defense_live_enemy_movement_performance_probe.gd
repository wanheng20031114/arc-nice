extends SceneTree

# Real-window diagnostic for the specific regression where camera/player motion
# becomes expensive only while live enemies exist. Every phase reuses the same
# 300 live first-wave enemies across three body profiles, deterministic
# walkable-cell placement and 60 Hz gameplay.
# The fixture changes one axis at a time: player motion, dynamic/static target,
# navigation, or physics interpolation scope.
const TOWER_SCENE := preload("res://scene/game_modes/tower_defense/tower_defense_game.tscn")
const BASIC_ENEMY_CONFIG := preload(
	"res://resources/config/enemies/yuanshi_insect_basic.tres"
)
const SHELL_ENEMY_CONFIG := preload(
	"res://resources/config/enemies/yuanshi_insect_shell.tres"
)
const AK_ENEMY_CONFIG := preload(
	"res://resources/config/enemies/capoo_ak47.tres"
)

const ENEMY_COUNT := 300
const BASIC_ENEMY_COUNT := 240
const SHELL_ENEMY_COUNT := 45
const AK_ENEMY_COUNT := 15
const FIXED_SEED := 20260713
const FIXTURE_CENTER := Vector2(512.0, 352.0)
const CANDIDATE_HALF_WIDTH_CELLS := 17
const CANDIDATE_HALF_HEIGHT_CELLS := 9
const MINIMUM_ENEMY_DISTANCE := 96.0
const WARMUP_FRAMES := 30
const SAMPLE_FRAMES := 180
const MOVEMENT_SWITCH_PHYSICS_FRAMES := 90
const CLEANUP_FRAMES := 8

enum TargetMode {
	DYNAMIC_PLAYER,
	STATIC_MARKER,
	NAVIGATION_DISABLED,
}

enum InterpolationScope {
	AUTHORED_ROOT_OFF,
	ENEMIES_ON,
	ROOT_ON,
}

var failures: Array[String] = []
var game: TowerDefenseGame = null
var pathfinder: GridPathfinder = null
var static_target: Marker2D = null
var enemies: Array[Enemy] = []
var initial_enemy_positions := PackedVector2Array()
var viewport_rid := RID()
var phase_results: Dictionary[String, Dictionary] = {}

var movement_enabled := false
var movement_start_physics_frame := 0
var movement_direction := 0
var original_max_fps := 0


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	original_max_fps = Engine.max_fps
	Engine.max_fps = 60
	seed(FIXED_SEED)

	game = TOWER_SCENE.instantiate() as TowerDefenseGame
	_expect(game != null, "Live-enemy movement probe must instantiate tower defense.")
	if game == null:
		await _finish()
		return
	game.auto_start_waves = false
	game.random_generator.seed = FIXED_SEED
	root.add_child(game)
	current_scene = game
	await process_frame
	await physics_frame

	pathfinder = game.grid_pathfinder as GridPathfinder
	_expect(pathfinder != null, "Live-enemy movement probe requires GridPathfinder.")
	_expect(pathfinder != null and pathfinder.is_built, "GridPathfinder must be built.")
	if pathfinder == null or not pathfinder.is_built:
		await _finish()
		return

	viewport_rid = game.get_viewport().get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(viewport_rid, true)
	_stop_background_gameplay()
	_prepare_player_and_camera()
	_create_static_target()
	_spawn_live_enemies()
	_prewarm_probe_agent_profiles()
	_expect(enemies.size() == ENEMY_COUNT, "Probe must create exactly 300 live enemies.")
	if enemies.size() != ENEMY_COUNT:
		await _finish()
		return

	print(
		(
			"LIVE_ENEMY_MOVEMENT_FIXTURE enemies=%d seed=%d samples=%d warmup=%d "
			+ "max_fps=%d physics_hz=%d window=%s viewport=%s renderer=%s gpu=%s"
		)
		% [
			ENEMY_COUNT,
			FIXED_SEED,
			SAMPLE_FRAMES,
			WARMUP_FRAMES,
			Engine.max_fps,
			Engine.physics_ticks_per_second,
			str(DisplayServer.window_get_size()),
			str(game.get_viewport().get_visible_rect().size),
			RenderingServer.get_current_rendering_method(),
			RenderingServer.get_video_adapter_name(),
		]
	)
	await _measure_phase(
		"stationary_dynamic_navigation_on",
		false,
		TargetMode.DYNAMIC_PLAYER,
		InterpolationScope.AUTHORED_ROOT_OFF
	)
	await _measure_phase(
		"moving_dynamic_navigation_on",
		true,
		TargetMode.DYNAMIC_PLAYER,
		InterpolationScope.AUTHORED_ROOT_OFF
	)
	await _measure_phase(
		"moving_dynamic_enemy_interpolation_on",
		true,
		TargetMode.DYNAMIC_PLAYER,
		InterpolationScope.ENEMIES_ON
	)
	await _measure_phase(
		"moving_dynamic_root_interpolation_on",
		true,
		TargetMode.DYNAMIC_PLAYER,
		InterpolationScope.ROOT_ON
	)
	await _measure_phase(
		"moving_static_target_navigation_on",
		true,
		TargetMode.STATIC_MARKER,
		InterpolationScope.AUTHORED_ROOT_OFF
	)
	await _measure_phase(
		"moving_dynamic_navigation_off",
		true,
		TargetMode.NAVIGATION_DISABLED,
		InterpolationScope.AUTHORED_ROOT_OFF
	)

	_print_comparison()
	await _finish()


func _stop_background_gameplay() -> void:
	game.set_process(false)
	game.set_physics_process(false)
	game.enemy_spawn_timer.stop()
	game.state_timer.stop()


func _prepare_player_and_camera() -> void:
	_expect(game.player != null, "Probe requires the local player.")
	if game.player == null:
		return
	game.player.global_position = FIXTURE_CENTER
	game.player.velocity = Vector2.ZERO
	game.player.controls_locked = false
	game.player.uses_local_input = true
	# The diagnostic is about movement/navigation cost, not combat resolution.
	game.player.max_health = 1_000_000
	game.player.current_health = 1_000_000
	game.player.is_dead = false
	game.player.reset_physics_interpolation()
	if game.map_camera != null:
		game.map_camera.position = Vector2.ZERO
		game.map_camera.position_smoothing_enabled = false
		game.map_camera.enabled = true
		game.map_camera.reset_physics_interpolation()


func _create_static_target() -> void:
	static_target = Marker2D.new()
	static_target.name = "MovementProbeStaticTarget"
	game.add_child(static_target)
	static_target.global_position = FIXTURE_CENTER


func _spawn_live_enemies() -> void:
	var candidate_positions := _build_deterministic_walkable_positions()
	_expect(
		candidate_positions.size() >= ENEMY_COUNT,
		"Walkable camera fixture must provide at least 300 enemy positions."
	)
	if candidate_positions.size() < ENEMY_COUNT:
		return

	for enemy_index in range(ENEMY_COUNT):
		var enemy_config: EnemyConfig = BASIC_ENEMY_CONFIG
		if enemy_index >= BASIC_ENEMY_COUNT + SHELL_ENEMY_COUNT:
			enemy_config = AK_ENEMY_CONFIG
		elif enemy_index >= BASIC_ENEMY_COUNT:
			enemy_config = SHELL_ENEMY_CONFIG
		var enemy := enemy_config.enemy_scene.instantiate() as Enemy
		_expect(enemy != null, "Every first-wave enemy must instantiate as Enemy.")
		if enemy == null:
			continue
		game.enemy_container.add_child(enemy)
		enemy.setup(enemy_config, game.player, pathfinder)
		enemy.set_near_moving_target_direct_distance(
			TowerDefenseEnemyCoordinator.PLAYER_NEAR_MOVING_DIRECT_DISTANCE
		)
		enemy.global_position = candidate_positions[enemy_index]
		enemy.velocity = Vector2.ZERO
		enemy.set_physics_process(false)
		enemy.material_drop_random_generator.seed = FIXED_SEED + enemy_index * 2 + 1
		var insect := enemy as YuanshiInsect
		if insect != null:
			insect.random_generator.seed = FIXED_SEED + enemy_index * 2 + 2
		var ak_enemy := enemy as CapooAK47
		if ak_enemy != null:
			ak_enemy.random_generator.seed = FIXED_SEED + enemy_index * 2 + 2
			# Keep the probe about movement/navigation. Projectile pressure has its
			# own render/pool probe and would make phase resets non-equivalent.
			ak_enemy.attack_cooldown_left = 1_000_000.0
		enemy.reset_physics_interpolation()
		enemies.append(enemy)
		initial_enemy_positions.append(enemy.global_position)


func _prewarm_probe_agent_profiles() -> void:
	# Production loading prewarms every campaign body profile. Keep the measured
	# phases focused on dynamic target fields while the dedicated staged-grid
	# smoke test covers cold profile joins and terrain rebuilds.
	for enemy in enemies:
		if enemy.config == null:
			continue
		pathfinder.prewarm_agent_grid(
			enemy.get_configured_body_collision_half_extents(),
			enemy.config.terrain_traversal_types
		)


func _build_deterministic_walkable_positions() -> PackedVector2Array:
	var candidates := PackedVector2Array()
	var center_cell := pathfinder.call("_global_to_map", FIXTURE_CENTER) as Vector2i
	for y_offset in range(-CANDIDATE_HALF_HEIGHT_CELLS, CANDIDATE_HALF_HEIGHT_CELLS + 1):
		for x_offset in range(-CANDIDATE_HALF_WIDTH_CELLS, CANDIDATE_HALF_WIDTH_CELLS + 1):
			var cell := center_cell + Vector2i(x_offset, y_offset)
			if not pathfinder.astar_grid.is_in_boundsv(cell):
				continue
			if pathfinder.astar_grid.is_point_solid(cell):
				continue
			var world_position := pathfinder.call("_map_to_global", cell) as Vector2
			if world_position.distance_to(FIXTURE_CENTER) < MINIMUM_ENEMY_DISTANCE:
				continue
			candidates.append(world_position)

	var shuffle_rng := RandomNumberGenerator.new()
	shuffle_rng.seed = FIXED_SEED
	for source_index in range(candidates.size() - 1, 0, -1):
		var target_index := shuffle_rng.randi_range(0, source_index)
		var temporary := candidates[source_index]
		candidates[source_index] = candidates[target_index]
		candidates[target_index] = temporary
	return candidates


func _measure_phase(
	label: String,
	should_move: bool,
	target_mode: TargetMode,
	interpolation_scope: InterpolationScope
) -> void:
	await _reset_phase(should_move, target_mode, interpolation_scope)
	for _warmup_index in range(WARMUP_FRAMES):
		await process_frame
		_drive_movement_input()
	var segment_queries_start := pathfinder.segment_queries_total
	var segment_integral_hits_start := pathfinder.segment_integral_hits_total
	var segment_exact_fallbacks_start := pathfinder.segment_exact_fallbacks_total
	var segment_budget_deferrals_start := pathfinder.segment_budget_deferrals_total

	var wall_samples: Array[float] = []
	var process_samples: Array[float] = []
	var physics_samples: Array[float] = []
	var frame_setup_samples: Array[float] = []
	var render_cpu_samples: Array[float] = []
	var render_gpu_samples: Array[float] = []
	var collision_pair_samples: Array[float] = []
	var physics_active_samples: Array[float] = []
	var flow_cache_samples: Array[float] = []
	var build_frame_wall_samples: Array[float] = []
	var no_build_frame_wall_samples: Array[float] = []
	var previous_tick_usec := Time.get_ticks_usec()
	var last_sampled_physics_frame := -1
	var previous_target_cell := _get_player_target_cell()
	var target_cell_transitions := 0
	var flow_builds_total := 0
	var path_queries_total := 0
	var maximum_player_displacement := 0.0

	for _sample_index in range(SAMPLE_FRAMES):
		await process_frame
		_drive_movement_input()
		var now_usec := Time.get_ticks_usec()
		var wall_ms := float(now_usec - previous_tick_usec) / 1000.0
		previous_tick_usec = now_usec
		wall_samples.append(wall_ms)
		process_samples.append(Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0)
		frame_setup_samples.append(RenderingServer.get_frame_setup_time_cpu())
		render_cpu_samples.append(
			RenderingServer.viewport_get_measured_render_time_cpu(viewport_rid)
		)
		render_gpu_samples.append(
			RenderingServer.viewport_get_measured_render_time_gpu(viewport_rid)
		)
		collision_pair_samples.append(
			Performance.get_monitor(Performance.PHYSICS_2D_COLLISION_PAIRS)
		)
		physics_active_samples.append(
			Performance.get_monitor(Performance.PHYSICS_2D_ACTIVE_OBJECTS)
		)
		flow_cache_samples.append(float(pathfinder.flow_field_cache.size()))

		var target_cell := _get_player_target_cell()
		if target_cell != previous_target_cell:
			target_cell_transitions += 1
			previous_target_cell = target_cell
		if game.player != null:
			maximum_player_displacement = maxf(
				maximum_player_displacement,
				game.player.global_position.distance_to(FIXTURE_CENTER)
			)

		var current_physics_frame := Engine.get_physics_frames()
		if current_physics_frame == last_sampled_physics_frame:
			continue
		last_sampled_physics_frame = current_physics_frame
		physics_samples.append(
			Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
		)
		var current_process_frame := Engine.get_process_frames()
		var builds_this_frame := 0
		if pathfinder.flow_field_budget_frame == current_process_frame:
			builds_this_frame = pathfinder.flow_field_builds_used_this_frame
		var queries_this_frame := 0
		if pathfinder.path_query_budget_frame == current_process_frame:
			queries_this_frame = pathfinder.path_queries_used_this_frame
		flow_builds_total += builds_this_frame
		path_queries_total += queries_this_frame
		if builds_this_frame > 0:
			build_frame_wall_samples.append(wall_ms)
		else:
			no_build_frame_wall_samples.append(wall_ms)

	_release_movement_input()
	var navigation_counts := _get_enemy_navigation_counts()
	var dynamic_flow_diagnostics := _get_dynamic_flow_diagnostics()
	var segment_queries := pathfinder.segment_queries_total - segment_queries_start
	var segment_integral_hits := (
		pathfinder.segment_integral_hits_total - segment_integral_hits_start
	)
	var summary := {
		"wall": _summarize(wall_samples),
		"process": _summarize(process_samples),
		"physics": _summarize(physics_samples),
		"frame_setup": _summarize(frame_setup_samples),
		"render_cpu": _summarize(render_cpu_samples),
		"render_gpu": _summarize(render_gpu_samples),
		"collision_pairs": _summarize(collision_pair_samples),
		"physics_active": _summarize(physics_active_samples),
		"flow_cache": _summarize(flow_cache_samples),
		"build_frame_wall": _summarize(build_frame_wall_samples),
		"no_build_frame_wall": _summarize(no_build_frame_wall_samples),
		"flow_builds": flow_builds_total,
		"runtime_flow_builds": pathfinder.runtime_flow_builds_completed,
		"runtime_flow_builds_cancelled": pathfinder.runtime_flow_builds_cancelled,
		"runtime_build_usec_peak": pathfinder.runtime_navigation_build_usec_peak,
		"runtime_build_usec_last": pathfinder.runtime_navigation_build_usec_last_frame,
		"dynamic_slots": pathfinder.dynamic_flow_target_slots.size(),
		"dynamic_published_slots": int(dynamic_flow_diagnostics["published_slots"]),
		"dynamic_min_revision": int(dynamic_flow_diagnostics["min_revision"]),
		"dynamic_end_max_anchor_lag_cells": int(dynamic_flow_diagnostics["max_anchor_lag_cells"]),
		"dynamic_end_max_retargets_since_publish": int(
			dynamic_flow_diagnostics["max_retargets_since_publish"]
		),
		"pending_flow_jobs": pathfinder.runtime_flow_build_jobs.size(),
		"path_queries": path_queries_total,
		"segment_queries": segment_queries,
		"segment_integral_hits": segment_integral_hits,
		"segment_integral_hit_rate": (
			float(segment_integral_hits) / float(segment_queries)
			if segment_queries > 0
			else 0.0
		),
		"segment_exact_fallbacks": (
			pathfinder.segment_exact_fallbacks_total
			- segment_exact_fallbacks_start
		),
		"segment_budget_deferrals": (
			pathfinder.segment_budget_deferrals_total
			- segment_budget_deferrals_start
		),
		"target_cell_transitions": target_cell_transitions,
		"maximum_player_displacement": maximum_player_displacement,
		"navigation_counts": navigation_counts,
	}
	phase_results[label] = summary
	_print_phase_summary(
		label,
		should_move,
		target_mode,
		interpolation_scope,
		summary
	)

	var render_cpu := summary["render_cpu"] as Dictionary
	var render_gpu := summary["render_gpu"] as Dictionary
	_expect(float(render_cpu["p50"]) > 0.0, "%s requires a real render loop." % label)
	_expect(float(render_gpu["p50"]) > 0.0, "%s requires non-zero GPU timing." % label)
	if should_move:
		_expect(
			target_cell_transitions >= 4 and maximum_player_displacement >= 48.0,
			"%s must move the real player across multiple navigation cells." % label
		)
	else:
		_expect(target_cell_transitions == 0, "%s player must remain stationary." % label)
	if target_mode == TargetMode.DYNAMIC_PLAYER:
		_expect(_count_dynamic_player_targets() == ENEMY_COUNT, "%s must force every objective to the player." % label)
		_expect(_count_enemies_with_pathfinder() == ENEMY_COUNT, "%s must keep navigation enabled." % label)
	elif target_mode == TargetMode.STATIC_MARKER:
		_expect(_count_static_targets() == ENEMY_COUNT, "%s must force the static marker objective." % label)
	else:
		_expect(_count_enemies_with_pathfinder() == 0, "%s must disable navigation only." % label)


func _reset_phase(
	should_move: bool,
	target_mode: TargetMode,
	interpolation_scope: InterpolationScope
) -> void:
	_release_movement_input()
	for enemy in enemies:
		enemy.set_physics_process(false)
	_clear_pathfinder_diagnostics_and_flow_cache()
	_apply_interpolation_scope(interpolation_scope)

	game.player.global_position = FIXTURE_CENTER
	game.player.velocity = Vector2.ZERO
	# A real-window benchmark can otherwise absorb unrelated keyboard input while
	# its stationary control phase is running in the background.
	game.player.controls_locked = not should_move
	game.player.uses_local_input = should_move
	game.player.is_dead = false
	game.player.current_health = game.player.max_health
	game.player.reset_physics_interpolation()
	static_target.global_position = FIXTURE_CENTER
	static_target.reset_physics_interpolation()
	if game.map_camera != null:
		game.map_camera.position = Vector2.ZERO
		game.map_camera.reset_physics_interpolation()

	for enemy_index in range(enemies.size()):
		var enemy := enemies[enemy_index]
		enemy.global_position = initial_enemy_positions[enemy_index]
		enemy.velocity = Vector2.ZERO
		enemy.set_target_player(game.player)
		match target_mode:
			TargetMode.DYNAMIC_PLAYER:
				enemy.set_pathfinder(pathfinder)
				enemy.set_objective_target(game.player)
			TargetMode.STATIC_MARKER:
				enemy.set_pathfinder(pathfinder)
				enemy.set_objective_target(static_target)
			TargetMode.NAVIGATION_DISABLED:
				enemy.set_pathfinder(null)
				enemy.set_objective_target(game.player)
		enemy.call("_clear_navigation_path")
		enemy.call("_clear_touching_players")
		var ak_enemy := enemy as CapooAK47
		if ak_enemy != null:
			ak_enemy.attack_cooldown_left = 1_000_000.0
		enemy.reset_physics_interpolation()
		enemy.set_physics_process(true)

	movement_enabled = should_move
	movement_start_physics_frame = Engine.get_physics_frames()
	movement_direction = 0
	if should_move:
		_set_movement_direction(1)
	for _settle_index in range(3):
		await process_frame
		await physics_frame


func _clear_pathfinder_diagnostics_and_flow_cache() -> void:
	pathfinder.call("_cancel_all_runtime_navigation_jobs")
	pathfinder.dynamic_flow_target_slots.clear()
	pathfinder.flow_field_cache.clear()
	pathfinder.flow_field_cache_order.clear()
	pathfinder.flow_recovery_route_cache.clear()
	pathfinder.flow_recovery_cache_order.clear()
	pathfinder.flow_field_builds_used_this_frame = 0
	pathfinder.flow_field_budget_frame = -1
	pathfinder.path_queries_used_this_frame = 0
	pathfinder.path_query_budget_frame = -1
	pathfinder.runtime_navigation_expansions_last_frame = 0
	pathfinder.runtime_navigation_build_usec_last_frame = 0
	pathfinder.runtime_navigation_build_usec_peak = 0
	pathfinder.runtime_flow_builds_completed = 0
	pathfinder.runtime_flow_builds_cancelled = 0


func _apply_interpolation_scope(scope: InterpolationScope) -> void:
	game.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	for enemy in enemies:
		enemy.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_INHERIT
	match scope:
		InterpolationScope.ENEMIES_ON:
			for enemy in enemies:
				enemy.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_ON
		InterpolationScope.ROOT_ON:
			game.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_ON
		_:
			pass
	game.reset_physics_interpolation()


func _drive_movement_input() -> void:
	if not movement_enabled:
		return
	var elapsed_physics_frames := maxi(
		Engine.get_physics_frames() - movement_start_physics_frame,
		0
	)
	var segment := floori(
		float(elapsed_physics_frames) / float(MOVEMENT_SWITCH_PHYSICS_FRAMES)
	)
	var next_direction := 1 if segment % 2 == 0 else -1
	if next_direction != movement_direction:
		_set_movement_direction(next_direction)


func _set_movement_direction(direction: int) -> void:
	movement_direction = signi(direction)
	Input.action_release(&"move_left")
	Input.action_release(&"move_right")
	if movement_direction > 0:
		Input.action_press(&"move_right")
	elif movement_direction < 0:
		Input.action_press(&"move_left")


func _release_movement_input() -> void:
	Input.action_release(&"move_left")
	Input.action_release(&"move_right")
	movement_enabled = false
	movement_direction = 0


func _get_player_target_cell() -> Vector2i:
	if game == null or game.player == null or pathfinder == null:
		return Vector2i.MAX
	return pathfinder.call("_global_to_map", game.player.global_position) as Vector2i


func _get_enemy_navigation_counts() -> Dictionary:
	var ready := 0
	var arrived := 0
	var deferred := 0
	var unreachable := 0
	var uninitialized := 0
	var zero_direction := 0
	var direct_objective := 0
	for enemy in enemies:
		if enemy.cached_navigation_move_direction == Vector2.ZERO:
			zero_direction += 1
		if enemy.cached_navigation_uses_direct_objective_approach:
			direct_objective += 1
		if enemy.navigation_step_result == null:
			uninitialized += 1
			continue
		match enemy.navigation_step_result.status:
			GridPathfinder.NavigationStepStatus.READY:
				ready += 1
			GridPathfinder.NavigationStepStatus.ARRIVED:
				arrived += 1
			GridPathfinder.NavigationStepStatus.DEFERRED:
				deferred += 1
			_:
				unreachable += 1
	return {
		"ready": ready,
		"arrived": arrived,
		"deferred": deferred,
		"unreachable": unreachable,
		"uninitialized": uninitialized,
		"zero_direction": zero_direction,
		"direct_objective": direct_objective,
	}


func _count_dynamic_player_targets() -> int:
	var count := 0
	for enemy in enemies:
		if enemy.objective_target == game.player:
			count += 1
	return count


func _count_static_targets() -> int:
	var count := 0
	for enemy in enemies:
		if enemy.objective_target == static_target:
			count += 1
	return count


func _count_enemies_with_pathfinder() -> int:
	var count := 0
	for enemy in enemies:
		if enemy.pathfinder == pathfinder:
			count += 1
	return count


func _print_phase_summary(
	label: String,
	should_move: bool,
	target_mode: TargetMode,
	interpolation_scope: InterpolationScope,
	summary: Dictionary
) -> void:
	var navigation_counts := summary["navigation_counts"] as Dictionary
	var parts := PackedStringArray([
		"phase=%s" % label,
		"moving=%s" % str(should_move),
		"target_mode=%s" % TargetMode.keys()[target_mode],
		"interpolation=%s" % InterpolationScope.keys()[interpolation_scope],
		"enemies=%d" % enemies.size(),
		"player_max_displacement=%.2f" % float(summary["maximum_player_displacement"]),
		"target_cell_transitions=%d" % int(summary["target_cell_transitions"]),
		"flow_builds=%d" % int(summary["flow_builds"]),
		"runtime_flow_builds=%d" % int(summary["runtime_flow_builds"]),
		"runtime_cancelled=%d" % int(summary["runtime_flow_builds_cancelled"]),
		"runtime_peak_usec=%d" % int(summary["runtime_build_usec_peak"]),
		"dynamic_slots=%d" % int(summary["dynamic_slots"]),
		"dynamic_published=%d" % int(summary["dynamic_published_slots"]),
		"dynamic_min_revision=%d" % int(summary["dynamic_min_revision"]),
		"dynamic_end_max_lag_cells=%d" % int(summary["dynamic_end_max_anchor_lag_cells"]),
		"dynamic_end_max_retargets=%d" % int(summary["dynamic_end_max_retargets_since_publish"]),
		"pending_flow_jobs=%d" % int(summary["pending_flow_jobs"]),
		"path_queries=%d" % int(summary["path_queries"]),
		"segment_queries=%d" % int(summary["segment_queries"]),
		"segment_integral_hits=%d" % int(summary["segment_integral_hits"]),
		"segment_integral_hit_rate=%.3f" % float(summary["segment_integral_hit_rate"]),
		"segment_exact_fallbacks=%d" % int(summary["segment_exact_fallbacks"]),
		"segment_budget_deferrals=%d" % int(summary["segment_budget_deferrals"]),
		"flow_cache_final=%d" % pathfinder.flow_field_cache.size(),
		"agent_grid_cache=%d" % pathfinder.agent_grid_cache.size(),
		"nav_ready=%d" % int(navigation_counts["ready"]),
		"nav_deferred=%d" % int(navigation_counts["deferred"]),
		"nav_unreachable=%d" % int(navigation_counts["unreachable"]),
		"nav_uninitialized=%d" % int(navigation_counts["uninitialized"]),
		"nav_zero=%d" % int(navigation_counts["zero_direction"]),
		"nav_direct=%d" % int(navigation_counts["direct_objective"]),
	])
	_append_summary(parts, "wall_ms", summary["wall"] as Dictionary)
	_append_summary(parts, "process_ms", summary["process"] as Dictionary)
	_append_summary(parts, "physics_ms", summary["physics"] as Dictionary)
	_append_summary(parts, "frame_setup_ms", summary["frame_setup"] as Dictionary)
	_append_summary(parts, "render_cpu_ms", summary["render_cpu"] as Dictionary)
	_append_summary(parts, "render_gpu_ms", summary["render_gpu"] as Dictionary)
	_append_summary(parts, "collision_pairs", summary["collision_pairs"] as Dictionary)
	_append_summary(parts, "physics_active", summary["physics_active"] as Dictionary)
	_append_summary(parts, "flow_cache", summary["flow_cache"] as Dictionary)
	_append_summary(parts, "build_frame_wall_ms", summary["build_frame_wall"] as Dictionary)
	_append_summary(parts, "no_build_frame_wall_ms", summary["no_build_frame_wall"] as Dictionary)
	print("LIVE_ENEMY_MOVEMENT_PROBE %s" % " ".join(parts))


func _get_dynamic_flow_diagnostics() -> Dictionary:
	var published_slots := 0
	var minimum_revision := 2147483647
	var maximum_anchor_lag := 0
	var maximum_retargets := 0
	for slot_variant in pathfinder.dynamic_flow_target_slots.values():
		var slot: Variant = slot_variant
		if slot == null:
			continue
		maximum_retargets = maxi(
			maximum_retargets,
			int(slot.get("pending_retargets_since_publish"))
		)
		var published_field := slot.get("published_field") as Dictionary
		if published_field.is_empty():
			continue
		published_slots += 1
		minimum_revision = mini(
			minimum_revision,
			int(slot.get("published_revision"))
		)
		var published_anchor := slot.get("published_anchor_cell") as Vector2i
		# published_anchor_cell is the immutable player/target cell captured by the
		# field, while desired_resolved_cell is one seed in the surrounding contact
		# envelope. Comparing those two reports the intentional contact radius as
		# target lag. Measure like-for-like original target cells instead.
		var desired_anchor := slot.get("desired_original_cell") as Vector2i
		var anchor_delta := (published_anchor - desired_anchor).abs()
		maximum_anchor_lag = maxi(
			maximum_anchor_lag,
			maxi(anchor_delta.x, anchor_delta.y)
		)
	return {
		"published_slots": published_slots,
		"min_revision": minimum_revision if published_slots > 0 else 0,
		"max_anchor_lag_cells": maximum_anchor_lag,
		"max_retargets_since_publish": maximum_retargets,
	}


func _print_comparison() -> void:
	var stationary := phase_results.get("stationary_dynamic_navigation_on", {}) as Dictionary
	var moving := phase_results.get("moving_dynamic_navigation_on", {}) as Dictionary
	var static_moving := phase_results.get("moving_static_target_navigation_on", {}) as Dictionary
	var navigation_off := phase_results.get("moving_dynamic_navigation_off", {}) as Dictionary
	if stationary.is_empty() or moving.is_empty() or static_moving.is_empty() or navigation_off.is_empty():
		return
	print(
		(
			"LIVE_ENEMY_MOVEMENT_COMPARISON moving_minus_stationary_physics_p95_ms=%.3f "
			+ "moving_minus_static_physics_p95_ms=%.3f "
			+ "moving_minus_navigation_off_physics_p95_ms=%.3f "
			+ "moving_flow_builds=%d moving_runtime_builds=%d "
			+ "static_flow_builds=%d navigation_off_flow_builds=%d"
		)
		% [
			_get_p95(moving, "physics") - _get_p95(stationary, "physics"),
			_get_p95(moving, "physics") - _get_p95(static_moving, "physics"),
			_get_p95(moving, "physics") - _get_p95(navigation_off, "physics"),
			int(moving["flow_builds"]),
			int(moving["runtime_flow_builds"]),
			int(static_moving["flow_builds"]),
			int(navigation_off["flow_builds"]),
		]
	)
	var moving_wall := moving["wall"] as Dictionary
	_expect(
		float(moving_wall["p99"]) < 30.0 and float(moving_wall["max"]) < 35.0,
		"Three hundred live enemies must not restore the moving-target frame spikes."
	)
	_expect(
		int(moving["runtime_build_usec_peak"]) <= 3000,
		"Runtime navigation slices must remain tightly bounded on the main thread."
	)
	_expect(
		int(moving["runtime_flow_builds"]) > 0
		and int(moving["runtime_flow_builds"])
			< int(moving["target_cell_transitions"])
				* maxi(int(moving["dynamic_slots"]), 1)
		and int(moving["pending_flow_jobs"])
			<= int(moving["dynamic_slots"]),
		"Moving target cells must coalesce into one bounded pipeline per body profile."
	)


func _get_p95(summary: Dictionary, metric: String) -> float:
	var metric_summary := summary.get(metric, {}) as Dictionary
	return float(metric_summary.get("p95", 0.0))


func _append_summary(parts: PackedStringArray, prefix: String, summary: Dictionary) -> void:
	parts.append("%s_p50=%.3f" % [prefix, float(summary["p50"])])
	parts.append("%s_p95=%.3f" % [prefix, float(summary["p95"])])
	parts.append("%s_p99=%.3f" % [prefix, float(summary["p99"])])
	parts.append("%s_max=%.3f" % [prefix, float(summary["max"])])


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
	_release_movement_input()
	Engine.max_fps = original_max_fps
	if viewport_rid.is_valid():
		RenderingServer.viewport_set_measure_render_time(viewport_rid, false)
	for enemy in enemies:
		if enemy != null and is_instance_valid(enemy):
			enemy.set_physics_process(false)
	current_scene = null
	if game != null:
		game.queue_free()
	for _cleanup_index in range(CLEANUP_FRAMES):
		await process_frame
		await physics_frame
	if failures.is_empty():
		print("GAME_TOWER_DEFENSE_LIVE_ENEMY_MOVEMENT_PERFORMANCE_PROBE_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
