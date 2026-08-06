extends SceneTree

# This probe intentionally requires a real rendering driver. Do not run it with
# --headless: the render CPU/GPU monitors and Canvas draw-call counts would no
# longer describe PointLight2D cost.
const TOWER_SCENE := preload("res://scene/game_modes/tower_defense/tower_defense_game.tscn")
const DAY_NIGHT_SCENE := preload(
	"res://scene/lighting/day_night_controller.tscn"
)
const NIGHT_LIGHT_SCENE := preload(
	"res://scene/lighting/night_point_light.tscn"
)
const VEGETATION_RING_TEXTURE := preload(
	"res://resources/lighting/vegetation_ring_point_light.tres"
)

const EXPECTED_AUTHORED_LIGHT_COUNT := 10
const DEFAULT_STRESS_LIGHT_COUNT := 100
const MICRO_BENCHMARK_LIGHT_COUNT := 512
const MICRO_BROADCAST_P95_BUDGET_USEC := 1250.0
const MICRO_BROADCAST_MAX_BUDGET_USEC := 2000.0
const LIVE_GAMEPLAY_ENEMY_COUNT := 96
const LIFECYCLE_BENCHMARK_BATCH_SIZE := 128
const LIFECYCLE_BENCHMARK_ROUNDS := 24
const DEFAULT_WARMUP_FRAMES := 60
const DEFAULT_SAMPLE_FRAMES := 180
const DEFAULT_MICRO_SAMPLE_COUNT := 360
const CLEANUP_SETTLE_FRAMES := 8
const BENCHMARK_VIEWPORT_SIZE := Vector2i(1152, 648)
const TRANSITION_TIMEOUT_FRAMES := 480
const SPREAD_SCREENSHOT_PATH := (
	"user://day_night_lighting_probe.png"
)

# This is the completed-grass/home-gate area. Keeping the dense fixture over
# actual lit TileMap/Sprite canvas items avoids under-reporting lights placed
# above empty black world space.
const FIXTURE_CENTER := Vector2(112.0, 336.0)
const DENSE_SPACING := Vector2(12.0, 12.0)
const GREEN_RING_COLOR := Color(0.52, 1.0, 0.24, 1.0)
const GREEN_RING_TEXTURE_SCALE := 0.82
const GREEN_RING_NIGHT_ENERGY := 0.62

var failures: Array[String] = []
var game: TowerDefenseGame = null
var controller: DayNightController = null
var stress_root: Node2D = null
var stress_lights: Array[NightPointLight2D] = []
var viewport_rid := RID()

var warmup_frames := DEFAULT_WARMUP_FRAMES
var sample_frames := DEFAULT_SAMPLE_FRAMES
var micro_sample_count := DEFAULT_MICRO_SAMPLE_COUNT
var stress_light_count := DEFAULT_STRESS_LIGHT_COUNT
var save_screenshot := false
var cpu_only := false
var live_gameplay := false


class LegacyBroadcastLight:
	extends PointLight2D

	var benchmark_night_energy := 0.0
	var _benchmark_night_factor := 0.0
	var _benchmark_emission_allowed := true

	func set_benchmark_night_factor(value: float) -> void:
		_benchmark_night_factor = clampf(value, 0.0, 1.0)
		_refresh_benchmark_emission()

	func _refresh_benchmark_emission() -> void:
		var effective_factor := (
			_benchmark_night_factor
			if _benchmark_emission_allowed
			else 0.0
		)
		energy = benchmark_night_energy * effective_factor
		enabled = energy > NightPointLight2D.ENABLE_EPSILON


class LegacyBroadcastController:
	extends CanvasModulate

	signal benchmark_night_factor_changed(night_factor: float)

	var benchmark_day_color := Color.WHITE
	var benchmark_night_color := DayNightController.REFERENCE_NIGHT_COLOR
	var benchmark_night_factor := 0.0

	func set_benchmark_night_factor(value: float) -> void:
		benchmark_night_factor = clampf(value, 0.0, 1.0)
		color = benchmark_day_color.lerp(
			benchmark_night_color,
			benchmark_night_factor
		)
		benchmark_night_factor_changed.emit(benchmark_night_factor)


func _init() -> void:
	_parse_user_arguments()
	call_deferred("_run")


func _run() -> void:
	await _configure_benchmark_window()
	var run_state := root.get_node_or_null("RunState") as RunStateStore
	if run_state != null:
		run_state.set_selected_character(
			PlayerCharacterRegistry.WEISHIDAIER_ID
		)

	game = TOWER_SCENE.instantiate() as TowerDefenseGame
	_expect(game != null, "Lighting probe must instantiate tower defense.")
	if game == null:
		await _finish()
		return
	game.auto_start_waves = false
	game.linglan_boss_enabled = false
	root.add_child(game)
	current_scene = game
	await process_frame
	await physics_frame
	await process_frame

	controller = game.day_night_controller
	_expect(
		controller != null,
		"Tower-defense runtime must expose DayNightController."
	)
	if controller == null:
		await _finish()
		return

	_prepare_camera_fixture()
	viewport_rid = game.get_viewport().get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(viewport_rid, true)
	_print_benchmark_environment()
	_expect(
		Vector2i(game.get_viewport_rect().size)
			== BENCHMARK_VIEWPORT_SIZE,
		(
			"Lighting probe viewport must be fixed at %s, observed %s."
			% [
				str(BENCHMARK_VIEWPORT_SIZE),
				str(Vector2i(game.get_viewport_rect().size)),
			]
		)
	)
	if live_gameplay:
		await _run_live_gameplay_probe()
		await _finish()
		return

	_stop_background_gameplay()

	var authored_lights := _collect_night_lights(game)
	_expect(
		authored_lights.size() == EXPECTED_AUTHORED_LIGHT_COUNT,
		(
			"Tower-defense fixture must contain one player light, seven "
			+ "authored gate lights, and two merchant lights."
		)
	)
	_expect(
		_all_lights_disabled(authored_lights),
		"Day phase must begin with every authored light disabled at zero energy."
	)
	_expect(
		_all_lights_without_process(authored_lights),
		"Authored PointLight2D nodes must not register per-frame script processing."
	)
	_expect(
		_all_lights_without_shadows(authored_lights),
		"Authored night lights must keep 2D shadows disabled."
	)
	if cpu_only:
		await _run_broadcast_microbenchmark()
		await _run_lifecycle_microbenchmark()
		await _finish()
		return

	var day_zero_summary: Dictionary = await _measure_phase(
		"day_zero_active",
		0
	)
	if game.player != null:
		game.player.global_position = _camera_screen_center()
		game.player.reset_physics_interpolation()

	controller.set_night_factor_immediate(1.0)
	await process_frame
	_expect(
		_count_enabled_lights(authored_lights)
			== EXPECTED_AUTHORED_LIGHT_COUNT,
		(
			"Night baseline must enable the player, seven fixed gate lights, "
			+ "and two visible merchant lights."
		)
	)
	var fixed_summary: Dictionary = await _measure_phase(
		"night_fixed_gate_player_merchants",
		EXPECTED_AUTHORED_LIGHT_COUNT
	)

	await _create_stress_lights()
	_position_stress_lights_spread()
	await process_frame
	await process_frame
	_expect(
		stress_lights.size() == stress_light_count
		and _count_enabled_lights(stress_lights) == stress_light_count,
		"Spread phase must enable every configured green ring light."
	)
	var spread_summary: Dictionary = await _measure_phase(
		"night_%d_green_spread" % stress_light_count,
		EXPECTED_AUTHORED_LIGHT_COUNT + stress_light_count,
		stress_light_count
	)
	if save_screenshot:
		await _save_spread_screenshot()

	_position_stress_lights_dense()
	await process_frame
	await process_frame
	var dense_summary: Dictionary = await _measure_phase(
		"night_%d_green_dense" % stress_light_count,
		EXPECTED_AUTHORED_LIGHT_COUNT + stress_light_count,
		stress_light_count
	)

	var transition_to_day_summary := await _measure_transition(
		"transition_%d_green_night_to_day" % stress_light_count,
		false,
		0
	)
	var all_render_lights := _collect_night_lights(game)
	_expect(
		_all_lights_disabled(all_render_lights),
		"Returning to day must disable all fixed and stress lights at zero energy."
	)
	var return_day_summary: Dictionary = await _measure_phase(
		"day_return_zero_active",
		0
	)
	var transition_to_night_summary := await _measure_transition(
		"transition_%d_green_day_to_night" % stress_light_count,
		true,
		EXPECTED_AUTHORED_LIGHT_COUNT + stress_light_count
	)
	_expect(
		_count_visible_stress_lights() == stress_light_count,
		"Completed night transition must leave every stress light in view."
	)

	_print_phase_delta(
		"night_fixed_gate_player_merchants",
		"day_zero_active",
		fixed_summary,
		day_zero_summary
	)
	_print_phase_delta(
		"night_%d_green_spread" % stress_light_count,
		"night_fixed_gate_player_merchants",
		spread_summary,
		fixed_summary
	)
	_print_phase_delta(
		"night_%d_green_dense" % stress_light_count,
		"night_fixed_gate_player_merchants",
		dense_summary,
		fixed_summary
	)
	_print_phase_delta(
		"day_return_zero_active",
		"day_zero_active",
		return_day_summary,
		day_zero_summary
	)
	_assert_render_budgets(
		day_zero_summary,
		fixed_summary,
		spread_summary,
		dense_summary,
		return_day_summary,
		transition_to_day_summary,
		transition_to_night_summary
	)

	await _run_broadcast_microbenchmark()
	await _run_lifecycle_microbenchmark()
	controller.set_night_factor_immediate(0.0)
	await process_frame
	_expect(
		_all_lights_disabled(_collect_night_lights(game)),
		"Probe teardown must leave every persistent light disabled."
	)
	await _finish()


func _parse_user_arguments() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--warmup="):
			warmup_frames = maxi(
				int(argument.get_slice("=", 1)),
				2
			)
		elif argument.begins_with("--samples="):
			sample_frames = maxi(
				int(argument.get_slice("=", 1)),
				10
			)
		elif argument.begins_with("--micro-samples="):
			micro_sample_count = maxi(
				int(argument.get_slice("=", 1)),
				20
			)
		elif argument.begins_with("--lights="):
			stress_light_count = maxi(
				int(argument.get_slice("=", 1)),
				1
			)
		elif argument == "--screenshot":
			save_screenshot = true
		elif argument == "--cpu-only":
			cpu_only = true
		elif argument == "--live-gameplay":
			live_gameplay = true


func _configure_benchmark_window() -> void:
	Engine.max_fps = 60
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED)
	DisplayServer.window_set_size(BENCHMARK_VIEWPORT_SIZE)
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
	root.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_EXPAND
	root.content_scale_size = BENCHMARK_VIEWPORT_SIZE
	root.size = BENCHMARK_VIEWPORT_SIZE
	await process_frame
	await process_frame


func _print_benchmark_environment() -> void:
	print(
		(
			"DAY_NIGHT_LIGHTING_ENV viewport=%s window=%s "
			+ "content_scale=%s vsync_mode=%d max_fps=%d "
			+ "rendering_driver=%s"
		)
		% [
			str(Vector2i(game.get_viewport_rect().size)),
			str(DisplayServer.window_get_size()),
			str(root.content_scale_size),
			DisplayServer.window_get_vsync_mode(),
			Engine.max_fps,
			RenderingServer.get_current_rendering_driver_name(),
		]
	)


func _stop_background_gameplay() -> void:
	game.set_process(false)
	game.set_physics_process(false)
	game.enemy_spawn_timer.stop()
	game.state_timer.stop()
	if game.player != null:
		game.player.velocity = Vector2.ZERO
		game.player.set_process(false)
		game.player.set_physics_process(false)
	for candidate in game.find_children("*", "", true, false):
		if candidate is Timer:
			(candidate as Timer).stop()
		elif candidate is GPUParticles2D:
			var particles := candidate as GPUParticles2D
			particles.emitting = false
			particles.hide()
		elif candidate is AudioStreamPlayer:
			(candidate as AudioStreamPlayer).stop()
		elif candidate is AudioStreamPlayer2D:
			(candidate as AudioStreamPlayer2D).stop()


func _prepare_camera_fixture() -> void:
	if game.player != null:
		game.player.global_position = FIXTURE_CENTER
		game.player.velocity = Vector2.ZERO
		game.player.reset_physics_interpolation()
	if game.map_camera != null:
		if game.map_camera.get_parent() == game.player:
			game.map_camera.position = Vector2.ZERO
		else:
			game.map_camera.global_position = FIXTURE_CENTER
		game.map_camera.position_smoothing_enabled = false
		game.map_camera.enabled = true
		game.map_camera.reset_physics_interpolation()
		game.map_camera.force_update_scroll()


func _run_live_gameplay_probe() -> void:
	_expect(
		not game.waves.is_empty(),
		"Live lighting probe requires at least one authored combat wave."
	)
	if game.waves.is_empty():
		return
	if game.player != null:
		game.player.max_health = 1_000_000_000
		game.player.current_health = 1_000_000_000
		game.player.is_dead = false
		game.player.controls_locked = true
		game.player.uses_local_input = false

	var enemy_count_before := game.enemy_container.get_child_count()
	game.enemy_spawn_timer.stop()
	game.state_timer.stop()
	game.wave_state = CombatFlowState.State.WAVE_ACTIVE
	var spawned_enemy_count := _spawn_live_gameplay_enemies()
	_expect(
		spawned_enemy_count == LIVE_GAMEPLAY_ENEMY_COUNT,
		"Live lighting probe must instantiate its full real-enemy cohort."
	)
	for _warmup_index in range(60):
		await physics_frame
		await process_frame
	var transition_to_night_summary := await _measure_transition(
		"live_combat_day_to_night",
		true,
		EXPECTED_AUTHORED_LIGHT_COUNT
	)
	var stable_night_summary := await _measure_phase(
		"live_combat_stable_night",
		EXPECTED_AUTHORED_LIGHT_COUNT
	)
	var transition_to_day_summary := await _measure_transition(
		"live_combat_night_to_day",
		false,
		0
	)
	var stable_day_summary := await _measure_phase(
		"live_combat_stable_day",
		0
	)
	_print_live_gameplay_cpu_comparison(
		stable_night_summary,
		stable_day_summary,
		transition_to_night_summary,
		transition_to_day_summary
	)
	print(
		(
			"DAY_NIGHT_LIGHTING_LIVE_COMBAT_STATE "
			+ "wave_state=%d enemies_before=%d enemies_after=%d "
			+ "live_spawned=%d"
		)
		% [
			game.wave_state,
			enemy_count_before,
			game.enemy_container.get_child_count(),
			spawned_enemy_count,
		]
	)
	_expect(
		game.enemy_container.get_child_count()
			>= enemy_count_before + LIVE_GAMEPLAY_ENEMY_COUNT,
		"Live lighting sample must keep real enemies active during measurement."
	)


func _spawn_live_gameplay_enemies() -> int:
	var pathfinder := game.grid_pathfinder as GridPathfinder
	_expect(
		pathfinder != null and pathfinder.is_built,
		"Live lighting probe requires the production pathfinder."
	)
	if pathfinder == null or not pathfinder.is_built:
		return 0
	var enemy_config: EnemyConfig = null
	for entry in game.waves[0].enemy_entries:
		if entry != null and entry.enemy_config != null:
			enemy_config = entry.enemy_config
			break
	_expect(
		enemy_config != null and enemy_config.enemy_scene != null,
		"Live lighting probe requires an authored enemy scene."
	)
	if enemy_config == null or enemy_config.enemy_scene == null:
		return 0

	var positions := PackedVector2Array()
	var center_cell := pathfinder.call(
		"_global_to_map",
		FIXTURE_CENTER
	) as Vector2i
	for y_offset in range(-10, 11):
		for x_offset in range(-18, 19):
			var cell := center_cell + Vector2i(x_offset, y_offset)
			if not pathfinder.astar_grid.is_in_boundsv(cell):
				continue
			if pathfinder.astar_grid.is_point_solid(cell):
				continue
			var world_position := pathfinder.call(
				"_map_to_global",
				cell
			) as Vector2
			if world_position.distance_to(FIXTURE_CENTER) < 96.0:
				continue
			positions.append(world_position)
	_expect(
		positions.size() >= LIVE_GAMEPLAY_ENEMY_COUNT,
		"Live lighting fixture lacks enough walkable enemy positions."
	)
	if positions.size() < LIVE_GAMEPLAY_ENEMY_COUNT:
		return 0

	var spawned_count := 0
	for enemy_index in range(LIVE_GAMEPLAY_ENEMY_COUNT):
		var enemy := enemy_config.enemy_scene.instantiate() as Enemy
		if enemy == null:
			continue
		game.enemy_container.add_child(enemy)
		enemy.global_position = positions[enemy_index]
		enemy.setup(enemy_config, game.player, pathfinder)
		enemy.current_health = 1_000_000_000
		enemy.set_near_moving_target_direct_distance(
			TowerDefenseGame.PLAYER_OBJECTIVE_AGGRO_RADIUS
		)
		enemy.material_drop_random_generator.seed = 20260720 + enemy_index * 2
		var insect := enemy as YuanshiInsect
		if insect != null:
			insect.random_generator.seed = 20260721 + enemy_index * 2
		enemy.reset_physics_interpolation()
		spawned_count += 1
	return spawned_count


func _print_live_gameplay_cpu_comparison(
	stable_night: Dictionary,
	stable_day: Dictionary,
	transition_to_night: Dictionary,
	transition_to_day: Dictionary
) -> void:
	var stable_night_process := stable_night["process_ms"] as Dictionary
	var stable_night_physics := stable_night["physics_ms"] as Dictionary
	var stable_day_process := stable_day["process_ms"] as Dictionary
	var stable_day_physics := stable_day["physics_ms"] as Dictionary
	var to_night_process := transition_to_night["process_ms"] as Dictionary
	var to_night_physics := transition_to_night["physics_ms"] as Dictionary
	var to_day_process := transition_to_day["process_ms"] as Dictionary
	var to_day_physics := transition_to_day["physics_ms"] as Dictionary
	print(
		(
			"DAY_NIGHT_LIGHTING_LIVE_COMBAT_CPU "
			+ "stable_night_process_p95_ms=%.3f "
			+ "stable_night_physics_p95_ms=%.3f "
			+ "stable_day_process_p95_ms=%.3f "
			+ "stable_day_physics_p95_ms=%.3f "
			+ "to_night_process_p95_ms=%.3f "
			+ "to_night_physics_p95_ms=%.3f "
			+ "to_day_process_p95_ms=%.3f "
			+ "to_day_physics_p95_ms=%.3f"
		)
		% [
			stable_night_process["p95"],
			stable_night_physics["p95"],
			stable_day_process["p95"],
			stable_day_physics["p95"],
			to_night_process["p95"],
			to_night_physics["p95"],
			to_day_process["p95"],
			to_day_physics["p95"],
		]
	)


func _create_stress_lights() -> void:
	stress_root = Node2D.new()
	stress_root.name = "LightingPerformanceStressLights"
	game.add_child(stress_root)
	stress_lights.clear()
	for light_index in range(stress_light_count):
		var light := (
			NIGHT_LIGHT_SCENE.instantiate() as NightPointLight2D
		)
		_expect(
			light != null,
			"Failed to instantiate stress light %d." % light_index
		)
		if light == null:
			continue
		light.name = "GreenRing%03d" % light_index
		light.texture = VEGETATION_RING_TEXTURE
		light.color = GREEN_RING_COLOR
		light.texture_scale = GREEN_RING_TEXTURE_SCALE
		light.night_energy = GREEN_RING_NIGHT_ENERGY
		light.starts_emitting = true
		stress_root.add_child(light)
		stress_lights.append(light)
	await process_frame
	await process_frame
	_expect(
		_all_lights_without_process(stress_lights),
		"Stress PointLight2D nodes must remain free of per-frame script callbacks."
	)
	_expect(
		_all_lights_without_shadows(stress_lights),
		"Stress PointLight2D nodes must keep 2D shadows disabled."
	)


func _position_stress_lights_spread() -> void:
	var light_radius := (
		float(VEGETATION_RING_TEXTURE.get_width())
		* GREEN_RING_TEXTURE_SCALE
		* 0.5
	)
	var spread_rect := _fixture_visible_rect().grow(-light_radius)
	if spread_rect.size.x <= 0.0 or spread_rect.size.y <= 0.0:
		spread_rect = Rect2(
			_camera_screen_center() - Vector2(288.0, 144.0),
			Vector2(576.0, 288.0)
		)
	var column_count := ceili(sqrt(float(stress_lights.size())))
	var row_count := ceili(
		float(stress_lights.size()) / float(column_count)
	)
	for light_index in range(stress_lights.size()):
		var column := light_index % column_count
		var row := light_index / column_count
		var x_ratio := (
			float(column) / float(maxi(column_count - 1, 1))
		)
		var y_ratio := (
			float(row) / float(maxi(row_count - 1, 1))
		)
		stress_lights[light_index].position = Vector2(
			lerpf(
				stress_root.to_local(spread_rect.position).x,
				stress_root.to_local(spread_rect.end).x,
				x_ratio
			),
			lerpf(
				stress_root.to_local(spread_rect.position).y,
				stress_root.to_local(spread_rect.end).y,
				y_ratio
			)
		)
		stress_lights[light_index].reset_physics_interpolation()


func _position_stress_lights_dense() -> void:
	var column_count := ceili(sqrt(float(stress_lights.size())))
	var row_count := ceili(
		float(stress_lights.size()) / float(column_count)
	)
	var screen_center := _camera_screen_center()
	var center_offset := Vector2(
		float(column_count - 1) * DENSE_SPACING.x,
		float(row_count - 1) * DENSE_SPACING.y
	) * 0.5
	for light_index in range(stress_lights.size()):
		var column := light_index % column_count
		var row := light_index / column_count
		stress_lights[light_index].position = (
			stress_root.to_local(screen_center)
			+ Vector2(
				float(column) * DENSE_SPACING.x,
				float(row) * DENSE_SPACING.y
			)
			- center_offset
		)
		stress_lights[light_index].reset_physics_interpolation()


func _measure_phase(
	label: String,
	expected_active_lights: int,
	expected_visible_stress_lights: int = -1
) -> Dictionary:
	var transition_max_ms := await _warmup_phase()
	var summary := await _sample_monitor_window()
	var all_lights := _collect_night_lights(game)
	var active_lights := _count_enabled_lights(all_lights)
	var visible_stress_lights := _count_visible_stress_lights()
	_expect(
		active_lights == expected_active_lights,
		(
			"%s expected %d active lights but observed %d."
			% [label, expected_active_lights, active_lights]
		)
	)
	if expected_visible_stress_lights >= 0:
		_expect(
			visible_stress_lights == expected_visible_stress_lights,
			(
				"%s expected %d visible stress lights but observed %d."
				% [
					label,
					expected_visible_stress_lights,
					visible_stress_lights,
				]
			)
		)
	var render_cpu := summary["render_cpu_ms"] as Dictionary
	var render_gpu := summary["render_gpu_ms"] as Dictionary
	var draw_calls := summary["draw_calls"] as Dictionary
	_expect(
		float(render_cpu["p50"]) > 0.0
		and float(render_gpu["p50"]) > 0.0
		and float(draw_calls["p50"]) > 0.0,
		(
			"%s requires a real rendering driver; do not use --headless."
			% label
		)
	)
	_print_phase_summary(
		label,
		summary,
		all_lights.size(),
		active_lights,
		visible_stress_lights,
		transition_max_ms
	)
	return summary


func _measure_transition(
	label: String,
	to_night: bool,
	expected_final_active_lights: int
) -> Dictionary:
	var wall_samples: Array[float] = []
	var render_cpu_samples: Array[float] = []
	var render_gpu_samples: Array[float] = []
	var process_samples: Array[float] = []
	var physics_samples: Array[float] = []
	var draw_call_samples: Array[float] = []
	var canvas_draw_call_samples: Array[float] = []
	var started_usec := Time.get_ticks_usec()
	var previous_tick_usec := started_usec
	if to_night:
		controller.transition_to_night()
	else:
		controller.transition_to_day()

	while (
		controller.is_transitioning()
		and wall_samples.size() < TRANSITION_TIMEOUT_FRAMES
	):
		await process_frame
		var current_tick_usec := Time.get_ticks_usec()
		wall_samples.append(
			float(current_tick_usec - previous_tick_usec) / 1000.0
		)
		previous_tick_usec = current_tick_usec
		render_cpu_samples.append(
			RenderingServer.viewport_get_measured_render_time_cpu(
				viewport_rid
			)
		)
		render_gpu_samples.append(
			RenderingServer.viewport_get_measured_render_time_gpu(
				viewport_rid
			)
		)
		process_samples.append(
			Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
		)
		physics_samples.append(
			Performance.get_monitor(
				Performance.TIME_PHYSICS_PROCESS
			) * 1000.0
		)
		draw_call_samples.append(
			Performance.get_monitor(
				Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME
			)
		)
		canvas_draw_call_samples.append(
			RenderingServer.viewport_get_render_info(
				viewport_rid,
				RenderingServer.VIEWPORT_RENDER_INFO_TYPE_CANVAS,
				RenderingServer.VIEWPORT_RENDER_INFO_DRAW_CALLS_IN_FRAME
			)
		)

	var elapsed_ms := (
		float(Time.get_ticks_usec() - started_usec) / 1000.0
	)
	var summary := {
		"wall_ms": _summarize(wall_samples),
		"render_cpu_ms": _summarize(render_cpu_samples),
		"render_gpu_ms": _summarize(render_gpu_samples),
		"process_ms": _summarize(process_samples),
		"physics_ms": _summarize(physics_samples),
		"draw_calls": _summarize(draw_call_samples),
		"canvas_draw_calls": _summarize(canvas_draw_call_samples),
		"elapsed_ms": elapsed_ms,
		"sample_frames": wall_samples.size(),
	}
	_expect(
		not controller.is_transitioning(),
		"%s exceeded the %d-frame transition timeout."
		% [label, TRANSITION_TIMEOUT_FRAMES]
	)
	_expect(
		elapsed_ms >= 4800.0,
		"%s completed too quickly to represent the authored 5-second tween."
		% label
	)
	_expect(
		absf(controller.night_factor - (1.0 if to_night else 0.0))
			<= 0.001,
		"%s did not reach its exact target factor." % label
	)
	var all_lights := _collect_night_lights(game)
	_expect(
		_count_enabled_lights(all_lights)
			== expected_final_active_lights,
		(
			"%s expected %d final active lights but observed %d."
			% [
				label,
				expected_final_active_lights,
				_count_enabled_lights(all_lights),
			]
		)
	)
	_print_transition_summary(label, summary)
	return summary


func _print_transition_summary(
	label: String,
	summary: Dictionary
) -> void:
	var wall := summary["wall_ms"] as Dictionary
	var render_cpu := summary["render_cpu_ms"] as Dictionary
	var render_gpu := summary["render_gpu_ms"] as Dictionary
	var process_cpu := summary["process_ms"] as Dictionary
	var physics_cpu := summary["physics_ms"] as Dictionary
	var draw_calls := summary["draw_calls"] as Dictionary
	print(
		(
			"DAY_NIGHT_LIGHTING_TRANSITION phase=%s frames=%d "
			+ "elapsed_ms=%.3f wall_p95_ms=%.3f wall_max_ms=%.3f "
			+ "render_cpu_p95_ms=%.3f render_cpu_max_ms=%.3f "
			+ "render_gpu_p95_ms=%.3f render_gpu_max_ms=%.3f "
			+ "process_p95_ms=%.3f physics_p95_ms=%.3f "
			+ "draw_p50=%.0f draw_p95=%.0f"
		)
		% [
			label,
			summary["sample_frames"],
			summary["elapsed_ms"],
			wall["p95"],
			wall["max"],
			render_cpu["p95"],
			render_cpu["max"],
			render_gpu["p95"],
			render_gpu["max"],
			process_cpu["p95"],
			physics_cpu["p95"],
			draw_calls["p50"],
			draw_calls["p95"],
		]
	)


func _warmup_phase() -> float:
	var previous_tick_usec := Time.get_ticks_usec()
	var maximum_ms := 0.0
	for _frame_index in range(warmup_frames):
		await process_frame
		var current_tick_usec := Time.get_ticks_usec()
		maximum_ms = maxf(
			maximum_ms,
			float(current_tick_usec - previous_tick_usec) / 1000.0
		)
		previous_tick_usec = current_tick_usec
	return maximum_ms


func _sample_monitor_window() -> Dictionary:
	var wall_samples: Array[float] = []
	var render_cpu_samples: Array[float] = []
	var render_gpu_samples: Array[float] = []
	var process_samples: Array[float] = []
	var physics_samples: Array[float] = []
	var draw_call_samples: Array[float] = []
	var canvas_draw_call_samples: Array[float] = []
	var previous_tick_usec := Time.get_ticks_usec()
	for _sample_index in range(sample_frames):
		await process_frame
		var current_tick_usec := Time.get_ticks_usec()
		wall_samples.append(
			float(current_tick_usec - previous_tick_usec) / 1000.0
		)
		previous_tick_usec = current_tick_usec
		render_cpu_samples.append(
			RenderingServer.viewport_get_measured_render_time_cpu(
				viewport_rid
			)
		)
		render_gpu_samples.append(
			RenderingServer.viewport_get_measured_render_time_gpu(
				viewport_rid
			)
		)
		process_samples.append(
			Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
		)
		physics_samples.append(
			Performance.get_monitor(
				Performance.TIME_PHYSICS_PROCESS
			) * 1000.0
		)
		draw_call_samples.append(
			Performance.get_monitor(
				Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME
			)
		)
		canvas_draw_call_samples.append(
			RenderingServer.viewport_get_render_info(
				viewport_rid,
				RenderingServer.VIEWPORT_RENDER_INFO_TYPE_CANVAS,
				RenderingServer.VIEWPORT_RENDER_INFO_DRAW_CALLS_IN_FRAME
			)
		)
	return {
		"wall_ms": _summarize(wall_samples),
		"render_cpu_ms": _summarize(render_cpu_samples),
		"render_gpu_ms": _summarize(render_gpu_samples),
		"process_ms": _summarize(process_samples),
		"physics_ms": _summarize(physics_samples),
		"draw_calls": _summarize(draw_call_samples),
		"canvas_draw_calls": _summarize(canvas_draw_call_samples),
	}


func _print_phase_summary(
	label: String,
	summary: Dictionary,
	total_lights: int,
	active_lights: int,
	visible_stress_lights: int,
	transition_max_ms: float
) -> void:
	var wall := summary["wall_ms"] as Dictionary
	var render_cpu := summary["render_cpu_ms"] as Dictionary
	var render_gpu := summary["render_gpu_ms"] as Dictionary
	var process_cpu := summary["process_ms"] as Dictionary
	var physics_cpu := summary["physics_ms"] as Dictionary
	var draw_calls := summary["draw_calls"] as Dictionary
	var canvas_draw_calls := summary["canvas_draw_calls"] as Dictionary
	print(
		(
			"DAY_NIGHT_LIGHTING_RENDER_PROBE phase=%s total_lights=%d "
			+ "active_lights=%d visible_stress_lights=%d "
			+ "camera_center=%s "
			+ "warmup_max_ms=%.3f "
			+ "wall_p50_ms=%.3f wall_p95_ms=%.3f wall_max_ms=%.3f "
			+ "render_cpu_p50_ms=%.3f render_cpu_p95_ms=%.3f "
			+ "render_cpu_max_ms=%.3f "
			+ "render_gpu_p50_ms=%.3f render_gpu_p95_ms=%.3f "
			+ "render_gpu_max_ms=%.3f "
			+ "process_p50_ms=%.3f process_p95_ms=%.3f "
			+ "physics_p50_ms=%.3f physics_p95_ms=%.3f "
			+ "draw_p50=%.0f draw_p95=%.0f draw_max=%.0f "
			+ "canvas_draw_p50=%.0f canvas_draw_p95=%.0f "
			+ "canvas_draw_max=%.0f"
		)
		% [
			label,
			total_lights,
			active_lights,
			visible_stress_lights,
			str(_camera_screen_center()),
			transition_max_ms,
			wall["p50"],
			wall["p95"],
			wall["max"],
			render_cpu["p50"],
			render_cpu["p95"],
			render_cpu["max"],
			render_gpu["p50"],
			render_gpu["p95"],
			render_gpu["max"],
			process_cpu["p50"],
			process_cpu["p95"],
			physics_cpu["p50"],
			physics_cpu["p95"],
			draw_calls["p50"],
			draw_calls["p95"],
			draw_calls["max"],
			canvas_draw_calls["p50"],
			canvas_draw_calls["p95"],
			canvas_draw_calls["max"],
		]
	)


func _print_phase_delta(
	label: String,
	baseline_label: String,
	summary: Dictionary,
	baseline: Dictionary
) -> void:
	var wall := summary["wall_ms"] as Dictionary
	var baseline_wall := baseline["wall_ms"] as Dictionary
	var render_cpu := summary["render_cpu_ms"] as Dictionary
	var baseline_render_cpu := baseline["render_cpu_ms"] as Dictionary
	var render_gpu := summary["render_gpu_ms"] as Dictionary
	var baseline_render_gpu := baseline["render_gpu_ms"] as Dictionary
	var draw_calls := summary["draw_calls"] as Dictionary
	var baseline_draw_calls := baseline["draw_calls"] as Dictionary
	print(
		(
			"DAY_NIGHT_LIGHTING_RENDER_DELTA phase=%s baseline=%s "
			+ "wall_p95_delta_ms=%.3f render_cpu_p95_delta_ms=%.3f "
			+ "render_gpu_p95_delta_ms=%.3f draw_p50_delta=%.0f"
		)
		% [
			label,
			baseline_label,
			float(wall["p95"]) - float(baseline_wall["p95"]),
			float(render_cpu["p95"])
				- float(baseline_render_cpu["p95"]),
			float(render_gpu["p95"])
				- float(baseline_render_gpu["p95"]),
			float(draw_calls["p50"])
				- float(baseline_draw_calls["p50"]),
		]
	)


func _assert_render_budgets(
	day_zero: Dictionary,
	fixed: Dictionary,
	spread: Dictionary,
	dense: Dictionary,
	return_day: Dictionary,
	transition_to_day: Dictionary,
	transition_to_night: Dictionary
) -> void:
	var day_cpu := day_zero["render_cpu_ms"] as Dictionary
	var day_gpu := day_zero["render_gpu_ms"] as Dictionary
	var day_draw := day_zero["draw_calls"] as Dictionary
	var fixed_cpu := fixed["render_cpu_ms"] as Dictionary
	var fixed_gpu := fixed["render_gpu_ms"] as Dictionary
	var stress_summaries: Array[Dictionary] = [spread, dense]
	var stress_cpu_budget_ms := (
		0.5 if stress_light_count <= 100 else 2.0
	)
	var stress_gpu_budget_ms := (
		1.0 if stress_light_count <= 100 else 4.0
	)
	var transition_cpu_budget_ms := (
		1.0 if stress_light_count <= 100 else 2.0
	)
	var transition_gpu_budget_ms := (
		1.5 if stress_light_count <= 100 else 4.0
	)
	_expect(
		float(fixed_cpu["p95"]) - float(day_cpu["p95"]) <= 0.5,
		"Eight fixed night lights exceeded the 0.5 ms render-CPU p95 budget."
	)
	_expect(
		float(fixed_gpu["p95"]) - float(day_gpu["p95"]) <= 0.5,
		"Eight fixed night lights exceeded the 0.5 ms GPU p95 budget."
	)
	for stress_summary in stress_summaries:
		var stress_wall := stress_summary["wall_ms"] as Dictionary
		var stress_cpu := (
			stress_summary["render_cpu_ms"] as Dictionary
		)
		var stress_gpu := (
			stress_summary["render_gpu_ms"] as Dictionary
		)
		_expect(
			float(stress_wall["p95"]) <= 20.0,
			"%d vegetation lights exceeded the 20 ms wall p95 budget."
			% stress_light_count
		)
		_expect(
			(
				float(stress_cpu["p95"])
				- float(fixed_cpu["p95"])
			) <= stress_cpu_budget_ms,
			(
				"%d vegetation lights exceeded the %.1f ms "
				+ "render-CPU p95 delta budget."
			) % [stress_light_count, stress_cpu_budget_ms]
		)
		_expect(
			(
				float(stress_gpu["p95"])
				- float(fixed_gpu["p95"])
			) <= stress_gpu_budget_ms,
			(
				"%d vegetation lights exceeded the %.1f ms "
				+ "GPU p95 delta budget."
			) % [stress_light_count, stress_gpu_budget_ms]
		)
	var return_draw := return_day["draw_calls"] as Dictionary
	_expect(
		absf(
			float(return_draw["p50"])
			- float(day_draw["p50"])
		) <= 1.0,
		"Returning to day must restore draw calls to the initial day baseline."
	)
	for transition_summary in [transition_to_day, transition_to_night]:
		var transition_wall := (
			transition_summary["wall_ms"] as Dictionary
		)
		var transition_cpu := (
			transition_summary["render_cpu_ms"] as Dictionary
		)
		var transition_gpu := (
			transition_summary["render_gpu_ms"] as Dictionary
		)
		_expect(
			float(transition_wall["p95"]) <= 20.0,
			"%d-light transition exceeded the 20 ms wall p95 budget."
			% stress_light_count
		)
		_expect(
			float(transition_cpu["p95"])
				- float(fixed_cpu["p95"])
				<= transition_cpu_budget_ms,
			(
				"%d-light transition exceeded the %.1f ms "
				+ "render-CPU p95 delta budget."
			) % [stress_light_count, transition_cpu_budget_ms]
		)
		_expect(
			float(transition_gpu["p95"])
				- float(fixed_gpu["p95"])
				<= transition_gpu_budget_ms,
			(
				"%d-light transition exceeded the %.1f ms "
				+ "GPU p95 delta budget."
			) % [stress_light_count, transition_gpu_budget_ms]
		)


func _save_spread_screenshot() -> void:
	# Readback happens after the spread sampling window so it cannot contaminate
	# the render timings above. user:// keeps this optional diagnostic artifact
	# outside the repository and therefore cannot dirty the worktree.
	await process_frame
	var screenshot := game.get_viewport().get_texture().get_image()
	_expect(
		screenshot != null and not screenshot.is_empty(),
		"Lighting probe could not read back the spread-light viewport."
	)
	if screenshot == null or screenshot.is_empty():
		return
	var save_error := screenshot.save_png(
		ProjectSettings.globalize_path(SPREAD_SCREENSHOT_PATH)
	)
	_expect(
		save_error == OK,
		"Lighting probe could not save its spread-light screenshot."
	)
	if save_error == OK:
		print(
			"DAY_NIGHT_LIGHTING_SCREENSHOT path=%s"
			% ProjectSettings.globalize_path(SPREAD_SCREENSHOT_PATH)
		)


func _run_broadcast_microbenchmark() -> void:
	var optimized_viewport := SubViewport.new()
	optimized_viewport.name = "OptimizedLightingBroadcastViewport"
	optimized_viewport.disable_3d = true
	optimized_viewport.size = Vector2i(64, 64)
	optimized_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	root.add_child(optimized_viewport)
	var optimized_world := Node2D.new()
	optimized_world.name = "OptimizedLightingBroadcastWorld"
	optimized_viewport.add_child(optimized_world)
	var optimized_controller := (
		DAY_NIGHT_SCENE.instantiate() as DayNightController
	)
	optimized_world.add_child(optimized_controller)
	var optimized_lights: Array[NightPointLight2D] = []
	for light_index in range(MICRO_BENCHMARK_LIGHT_COUNT):
		var light := (
			NIGHT_LIGHT_SCENE.instantiate() as NightPointLight2D
		)
		if light == null:
			continue
		light.name = "MicroLight%03d" % light_index
		light.texture = VEGETATION_RING_TEXTURE
		light.color = GREEN_RING_COLOR
		light.texture_scale = GREEN_RING_TEXTURE_SCALE
		light.night_energy = GREEN_RING_NIGHT_ENERGY
		optimized_world.add_child(light)
		optimized_lights.append(light)

	var legacy_viewport := SubViewport.new()
	legacy_viewport.name = "LegacyLightingBroadcastViewport"
	legacy_viewport.disable_3d = true
	legacy_viewport.size = Vector2i(64, 64)
	legacy_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	root.add_child(legacy_viewport)
	var legacy_world := Node2D.new()
	legacy_world.name = "LegacyLightingBroadcastWorld"
	legacy_viewport.add_child(legacy_world)
	var legacy_controller := LegacyBroadcastController.new()
	legacy_world.add_child(legacy_controller)
	var legacy_lights: Array[LegacyBroadcastLight] = []
	for light_index in range(MICRO_BENCHMARK_LIGHT_COUNT):
		var light := LegacyBroadcastLight.new()
		light.name = "LegacyMicroLight%03d" % light_index
		light.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
		light.enabled = false
		light.energy = 0.0
		light.texture = VEGETATION_RING_TEXTURE
		light.color = GREEN_RING_COLOR
		light.texture_scale = GREEN_RING_TEXTURE_SCALE
		light.shadow_enabled = false
		light.benchmark_night_energy = GREEN_RING_NIGHT_ENERGY
		legacy_world.add_child(light)
		legacy_controller.benchmark_night_factor_changed.connect(
			light.set_benchmark_night_factor
		)
		legacy_lights.append(light)
	await process_frame
	await process_frame

	_expect(
		optimized_controller != null
		and legacy_controller != null
		and optimized_lights.size()
		== MICRO_BENCHMARK_LIGHT_COUNT
		and legacy_lights.size() == MICRO_BENCHMARK_LIGHT_COUNT,
		"Broadcast A/B microbenchmark must instantiate two sets of %d lights."
		% MICRO_BENCHMARK_LIGHT_COUNT
	)
	if (
		optimized_controller == null
		or legacy_controller == null
		or optimized_lights.size()
		!= MICRO_BENCHMARK_LIGHT_COUNT
		or legacy_lights.size() != MICRO_BENCHMARK_LIGHT_COUNT
	):
		optimized_viewport.queue_free()
		legacy_viewport.queue_free()
		await process_frame
		return

	for warmup_index in range(24):
		var warmup_factor := (
			0.35 if warmup_index % 2 == 0 else 0.85
		)
		optimized_controller.call(
			"_apply_night_factor",
			warmup_factor
		)
		legacy_controller.set_benchmark_night_factor(warmup_factor)
	_expect(
		_count_enabled_lights(optimized_lights)
			== MICRO_BENCHMARK_LIGHT_COUNT,
		"All optimized microbenchmark lights must receive the broadcast."
	)

	var optimized_apply := Callable(
		optimized_controller,
		"_apply_night_factor"
	)
	var legacy_apply := Callable(
		legacy_controller,
		"set_benchmark_night_factor"
	)
	var changing_result := _measure_interleaved_broadcast_pair(
		optimized_apply,
		legacy_apply,
		true
	)
	var changing_optimized_summary: Dictionary = (
		changing_result["optimized_summary"]
	)
	var changing_legacy_total_usec: int = (
		changing_result["legacy_total_usec"]
	)
	var changing_optimized_total_usec: int = (
		changing_result["optimized_total_usec"]
	)
	_expect(
		float(changing_optimized_summary["p95"])
		<= MICRO_BROADCAST_P95_BUDGET_USEC,
		(
			"%d-light broadcasts exceeded the %.2f ms CPU p95 "
			+ "diagnostic budget."
		)
		% [
			MICRO_BENCHMARK_LIGHT_COUNT,
			MICRO_BROADCAST_P95_BUDGET_USEC / 1000.0,
		]
	)
	_expect(
		float(changing_optimized_summary["max"])
		<= MICRO_BROADCAST_MAX_BUDGET_USEC,
		"%d-light broadcasts exceeded the %.2f ms CPU maximum budget."
		% [
			MICRO_BENCHMARK_LIGHT_COUNT,
			MICRO_BROADCAST_MAX_BUDGET_USEC / 1000.0,
		]
	)
	_expect(
		changing_optimized_total_usec
		<= int(round(float(changing_legacy_total_usec) * 1.05)),
		"Optimized broadcasts regressed more than 5% against the in-process legacy path."
	)
	_expect(
		_broadcast_light_states_match(
			optimized_lights,
			legacy_lights
		),
		"Changing-factor A/B paths must produce identical light states."
	)
	_print_broadcast_pair("changing_factor", changing_result)

	optimized_apply.call(0.65)
	legacy_apply.call(0.65)
	var repeated_result := _measure_interleaved_broadcast_pair(
		optimized_apply,
		legacy_apply,
		false
	)
	var repeated_legacy_total_usec: int = (
		repeated_result["legacy_total_usec"]
	)
	var repeated_optimized_total_usec: int = (
		repeated_result["optimized_total_usec"]
	)
	_expect(
		repeated_optimized_total_usec
		<= int(round(float(repeated_legacy_total_usec) * 1.05)),
		"Repeated-factor optimization regressed against the legacy full broadcast."
	)
	_expect(
		_broadcast_light_states_match(
			optimized_lights,
			legacy_lights
		),
		"Repeated-factor A/B paths must preserve identical light states."
	)
	_print_broadcast_pair("repeated_factor", repeated_result)

	for light in optimized_lights:
		light.set_emission_allowed(false)
	for light in legacy_lights:
		light._benchmark_emission_allowed = false
	optimized_apply.call(0.65)
	legacy_apply.call(0.65)
	var blocked_result := _measure_interleaved_broadcast_pair(
		optimized_apply,
		legacy_apply,
		true
	)
	var blocked_legacy_total_usec: int = (
		blocked_result["legacy_total_usec"]
	)
	var blocked_optimized_total_usec: int = (
		blocked_result["optimized_total_usec"]
	)
	_expect(
		blocked_optimized_total_usec
		<= int(round(float(blocked_legacy_total_usec) * 1.05)),
		(
			"Emission-blocked broadcasts regressed more than 5% "
			+ "against the legacy path."
		)
	)
	_expect(
		blocked_optimized_total_usec
		<= int(round(float(changing_optimized_total_usec) * 0.95)),
		(
			"Emission-blocked broadcasts must skip unchanged energy writes "
			+ "and remain at least 5% cheaper than active changing lights."
		)
	)
	_expect(
		_broadcast_light_states_match(
			optimized_lights,
			legacy_lights
		),
		"Emission-blocked A/B paths must preserve identical disabled states."
	)
	_print_broadcast_pair("changing_factor_emission_blocked", blocked_result)

	optimized_controller.set_night_factor_immediate(0.0)
	legacy_controller.set_benchmark_night_factor(0.0)
	var legacy_lights_disabled := true
	for light in legacy_lights:
		if light.enabled or not is_zero_approx(light.energy):
			legacy_lights_disabled = false
			break
	_expect(
		_all_lights_disabled(optimized_lights)
		and legacy_lights_disabled,
		"Microbenchmark teardown must return all %d lights to day."
		% MICRO_BENCHMARK_LIGHT_COUNT
	)

	optimized_viewport.queue_free()
	legacy_viewport.queue_free()
	await process_frame
	await process_frame


func _run_lifecycle_microbenchmark() -> void:
	var lifecycle_viewport := SubViewport.new()
	lifecycle_viewport.name = "LightingLifecycleBenchmarkViewport"
	lifecycle_viewport.disable_3d = true
	lifecycle_viewport.size = Vector2i(64, 64)
	lifecycle_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	root.add_child(lifecycle_viewport)
	var lifecycle_world := Node2D.new()
	lifecycle_world.name = "LightingLifecycleBenchmarkWorld"
	lifecycle_viewport.add_child(lifecycle_world)
	var lifecycle_controller := (
		DAY_NIGHT_SCENE.instantiate() as DayNightController
	)
	lifecycle_world.add_child(lifecycle_controller)
	await process_frame
	lifecycle_controller.set_night_factor_immediate(1.0)

	var resident_lights: Array[NightPointLight2D] = []
	for light_index in range(LIFECYCLE_BENCHMARK_BATCH_SIZE):
		var light := (
			NIGHT_LIGHT_SCENE.instantiate() as NightPointLight2D
		)
		if light == null:
			continue
		light.name = "ResidentToggleLight%03d" % light_index
		light.texture = VEGETATION_RING_TEXTURE
		light.color = GREEN_RING_COLOR
		light.texture_scale = GREEN_RING_TEXTURE_SCALE
		light.night_energy = GREEN_RING_NIGHT_ENERGY
		lifecycle_world.add_child(light)
		light.call("_bind_to_owner_controller")
		resident_lights.append(light)
	_expect(
		resident_lights.size() == LIFECYCLE_BENCHMARK_BATCH_SIZE
		and _count_enabled_lights(resident_lights)
		== LIFECYCLE_BENCHMARK_BATCH_SIZE,
		"Resident-toggle benchmark must start with a full active light batch."
	)

	var setup_samples_usec: Array[float] = []
	var bind_samples_usec: Array[float] = []
	var teardown_samples_usec: Array[float] = []
	var resident_toggle_samples_usec: Array[float] = []
	for _round_index in range(LIFECYCLE_BENCHMARK_ROUNDS):
		var toggle_started_usec := Time.get_ticks_usec()
		for light in resident_lights:
			light.set_emission_allowed(false)
		for light in resident_lights:
			light.set_emission_allowed(true)
		resident_toggle_samples_usec.append(
			float(Time.get_ticks_usec() - toggle_started_usec)
		)
		_expect(
			_count_enabled_lights(resident_lights)
			== LIFECYCLE_BENCHMARK_BATCH_SIZE,
			"Resident toggles must restore every light to its night state."
		)

		var round_lights: Array[NightPointLight2D] = []
		var setup_started_usec := Time.get_ticks_usec()
		for light_index in range(LIFECYCLE_BENCHMARK_BATCH_SIZE):
			var light := (
				NIGHT_LIGHT_SCENE.instantiate() as NightPointLight2D
			)
			if light == null:
				continue
			light.name = "LifecycleLight%03d" % light_index
			light.texture = VEGETATION_RING_TEXTURE
			light.color = GREEN_RING_COLOR
			light.texture_scale = GREEN_RING_TEXTURE_SCALE
			light.night_energy = GREEN_RING_NIGHT_ENERGY
			lifecycle_world.add_child(light)
			round_lights.append(light)
		setup_samples_usec.append(
			float(Time.get_ticks_usec() - setup_started_usec)
		)

		var bind_started_usec := Time.get_ticks_usec()
		for light in round_lights:
			light.call("_bind_to_owner_controller")
		bind_samples_usec.append(
			float(Time.get_ticks_usec() - bind_started_usec)
		)
		_expect(
			round_lights.size() == LIFECYCLE_BENCHMARK_BATCH_SIZE,
			"Lifecycle benchmark must instantiate its complete light batch."
		)
		_expect(
			_all_lights_without_process(round_lights),
			"Lifecycle benchmark lights must not register frame callbacks."
		)
		_expect(
			_all_lights_without_shadows(round_lights),
			"Lifecycle benchmark lights must keep 2D shadows disabled."
		)
		for light in round_lights:
			_expect(
				light.get("_controller") == lifecycle_controller,
				"Lifecycle benchmark light failed to bind its local controller."
			)

		var teardown_started_usec := Time.get_ticks_usec()
		for light in round_lights:
			light.free()
		teardown_samples_usec.append(
			float(Time.get_ticks_usec() - teardown_started_usec)
		)
		_expect(
			lifecycle_world.get_child_count()
			== 1 + LIFECYCLE_BENCHMARK_BATCH_SIZE,
			"Lifecycle teardown leaked a light node."
		)
		_expect(
			lifecycle_controller.get_signal_connection_list(
				&"night_factor_changed"
			).size() == LIFECYCLE_BENCHMARK_BATCH_SIZE,
			"Lifecycle teardown leaked a night-factor signal connection."
		)

	var setup_summary := _summarize(setup_samples_usec)
	var bind_summary := _summarize(bind_samples_usec)
	var teardown_summary := _summarize(teardown_samples_usec)
	var resident_toggle_summary := _summarize(
		resident_toggle_samples_usec
	)
	_print_lifecycle_summary(
		"resident_disable_enable",
		resident_toggle_summary
	)
	_print_lifecycle_summary("instantiate_add", setup_summary)
	_print_lifecycle_summary("ancestor_bind_connect", bind_summary)
	_print_lifecycle_summary("disconnect_free", teardown_summary)
	_expect(
		float(resident_toggle_summary["p95"])
		< (
			float(setup_summary["p95"])
			+ float(bind_summary["p95"])
			+ float(teardown_summary["p95"])
		),
		"Resident disable/enable must remain cheaper than light node churn."
	)

	for light in resident_lights:
		light.free()
	_expect(
		lifecycle_controller.get_signal_connection_list(
			&"night_factor_changed"
		).is_empty(),
		"Resident-toggle teardown leaked a night-factor signal connection."
	)
	lifecycle_viewport.queue_free()
	await process_frame
	await process_frame


func _print_lifecycle_summary(
	phase: String,
	summary: Dictionary
) -> void:
	print(
		(
			"DAY_NIGHT_LIGHTING_LIFECYCLE_CPU phase=%s "
			+ "batch=%d rounds=%d batch_p50_us=%.1f "
			+ "batch_p95_us=%.1f batch_max_us=%.1f "
			+ "p95_per_light_us=%.3f"
		)
		% [
			phase,
			LIFECYCLE_BENCHMARK_BATCH_SIZE,
			LIFECYCLE_BENCHMARK_ROUNDS,
			summary["p50"],
			summary["p95"],
			summary["max"],
			float(summary["p95"])
				/ float(LIFECYCLE_BENCHMARK_BATCH_SIZE),
		]
	)


func _measure_interleaved_broadcast_pair(
	optimized_apply: Callable,
	legacy_apply: Callable,
	use_changing_factor: bool
) -> Dictionary:
	var optimized_samples_usec: Array[float] = []
	var legacy_samples_usec: Array[float] = []
	var optimized_total_usec := 0
	var legacy_total_usec := 0
	for sample_index in range(micro_sample_count):
		var sample_factor := 0.65
		if use_changing_factor:
			sample_factor = (
				0.35 if sample_index % 2 == 0 else 0.85
			)
		if sample_index % 2 == 0:
			var optimized_started_usec := Time.get_ticks_usec()
			optimized_apply.call(sample_factor)
			var optimized_elapsed_usec := (
				Time.get_ticks_usec() - optimized_started_usec
			)
			optimized_total_usec += optimized_elapsed_usec
			optimized_samples_usec.append(
				float(optimized_elapsed_usec)
			)
			var legacy_started_usec := Time.get_ticks_usec()
			legacy_apply.call(sample_factor)
			var legacy_elapsed_usec := (
				Time.get_ticks_usec() - legacy_started_usec
			)
			legacy_total_usec += legacy_elapsed_usec
			legacy_samples_usec.append(float(legacy_elapsed_usec))
		else:
			var legacy_started_usec := Time.get_ticks_usec()
			legacy_apply.call(sample_factor)
			var legacy_elapsed_usec := (
				Time.get_ticks_usec() - legacy_started_usec
			)
			legacy_total_usec += legacy_elapsed_usec
			legacy_samples_usec.append(float(legacy_elapsed_usec))
			var optimized_started_usec := Time.get_ticks_usec()
			optimized_apply.call(sample_factor)
			var optimized_elapsed_usec := (
				Time.get_ticks_usec() - optimized_started_usec
			)
			optimized_total_usec += optimized_elapsed_usec
			optimized_samples_usec.append(
				float(optimized_elapsed_usec)
			)
	return {
		"optimized_total_usec": optimized_total_usec,
		"legacy_total_usec": legacy_total_usec,
		"optimized_summary": _summarize(optimized_samples_usec),
		"legacy_summary": _summarize(legacy_samples_usec),
	}


func _broadcast_light_states_match(
	optimized_lights: Array[NightPointLight2D],
	legacy_lights: Array[LegacyBroadcastLight]
) -> bool:
	if optimized_lights.size() != legacy_lights.size():
		return false
	for light_index in range(optimized_lights.size()):
		var optimized_light := optimized_lights[light_index]
		var legacy_light := legacy_lights[light_index]
		if (
			optimized_light.enabled != legacy_light.enabled
			or not is_equal_approx(
				optimized_light.energy,
				legacy_light.energy
			)
		):
			return false
	return true


func _print_broadcast_pair(
	phase: String,
	result: Dictionary
) -> void:
	var optimized_total_usec: int = result["optimized_total_usec"]
	var legacy_total_usec: int = result["legacy_total_usec"]
	var optimized_summary: Dictionary = result["optimized_summary"]
	var legacy_summary: Dictionary = result["legacy_summary"]
	print(
		(
			"DAY_NIGHT_LIGHTING_BROADCAST_CPU phase=%s "
			+ "variant=optimized lights=%d samples=%d "
			+ "total_us=%d per_broadcast_p50_us=%.1f "
			+ "per_broadcast_p95_us=%.1f per_broadcast_max_us=%.1f "
			+ "p95_per_light_ns=%.1f"
		)
		% [
			phase,
			MICRO_BENCHMARK_LIGHT_COUNT,
			micro_sample_count,
			optimized_total_usec,
			optimized_summary["p50"],
			optimized_summary["p95"],
			optimized_summary["max"],
			float(optimized_summary["p95"]) * 1000.0
				/ float(MICRO_BENCHMARK_LIGHT_COUNT),
		]
	)
	print(
		(
			"DAY_NIGHT_LIGHTING_BROADCAST_CPU phase=%s "
			+ "variant=legacy lights=%d samples=%d "
			+ "total_us=%d per_broadcast_p50_us=%.1f "
			+ "per_broadcast_p95_us=%.1f per_broadcast_max_us=%.1f "
			+ "p95_per_light_ns=%.1f"
		)
		% [
			phase,
			MICRO_BENCHMARK_LIGHT_COUNT,
			micro_sample_count,
			legacy_total_usec,
			legacy_summary["p50"],
			legacy_summary["p95"],
			legacy_summary["max"],
			float(legacy_summary["p95"]) * 1000.0
				/ float(MICRO_BENCHMARK_LIGHT_COUNT),
		]
	)
	print(
		(
			"DAY_NIGHT_LIGHTING_BROADCAST_AB phase=%s "
			+ "optimized_total_us=%d legacy_total_us=%d "
			+ "total_reduction_percent=%.2f"
		)
		% [
			phase,
			optimized_total_usec,
			legacy_total_usec,
			(
				float(legacy_total_usec - optimized_total_usec)
				* 100.0
				/ maxf(float(legacy_total_usec), 1.0)
			),
		]
	)


func _fixture_visible_rect() -> Rect2:
	if game == null or game.map_camera == null:
		return Rect2()
	var viewport_size := game.get_viewport_rect().size
	var camera_zoom := Vector2(
		maxf(absf(game.map_camera.zoom.x), 0.001),
		maxf(absf(game.map_camera.zoom.y), 0.001)
	)
	var visible_world_size := Vector2(
		viewport_size.x / camera_zoom.x,
		viewport_size.y / camera_zoom.y
	)
	return Rect2(
		_camera_screen_center() - visible_world_size * 0.5,
		visible_world_size
	)


func _camera_screen_center() -> Vector2:
	if game == null or game.map_camera == null:
		return Vector2.ZERO
	return game.map_camera.get_screen_center_position()


func _count_visible_stress_lights() -> int:
	var visible_rect := _fixture_visible_rect().grow(
		float(VEGETATION_RING_TEXTURE.get_width())
		* GREEN_RING_TEXTURE_SCALE
		* 0.5
	)
	var count := 0
	for light in stress_lights:
		if (
			light != null
			and is_instance_valid(light)
			and light.enabled
			and visible_rect.has_point(light.global_position)
		):
			count += 1
	return count


func _collect_night_lights(search_root: Node) -> Array[NightPointLight2D]:
	var result: Array[NightPointLight2D] = []
	if search_root == null:
		return result
	for candidate in search_root.find_children("*", "", true, false):
		if (
			candidate is NightPointLight2D
			and not candidate is NightVfxFlash2D
		):
			result.append(candidate as NightPointLight2D)
	return result


func _count_enabled_lights(lights: Array[NightPointLight2D]) -> int:
	var count := 0
	for light in lights:
		if (
			light != null
			and is_instance_valid(light)
			and light.enabled
			and light.energy > 0.0
		):
			count += 1
	return count


func _all_lights_disabled(lights: Array[NightPointLight2D]) -> bool:
	for light in lights:
		if (
			light != null
			and is_instance_valid(light)
			and (light.enabled or not is_zero_approx(light.energy))
		):
			return false
	return true


func _all_lights_without_process(
	lights: Array[NightPointLight2D]
) -> bool:
	for light in lights:
		if (
			light != null
			and is_instance_valid(light)
			and (
				light.is_processing()
				or light.is_physics_processing()
			)
		):
			return false
	return true


func _all_lights_without_shadows(
	lights: Array[NightPointLight2D]
) -> bool:
	for light in lights:
		if (
			light != null
			and is_instance_valid(light)
			and light.shadow_enabled
		):
			return false
	return true


func _summarize(samples: Array[float]) -> Dictionary:
	if samples.is_empty():
		return {"p50": 0.0, "p95": 0.0, "max": 0.0}
	var sorted := samples.duplicate()
	sorted.sort()
	return {
		"p50": _nearest_rank(sorted, 0.50),
		"p95": _nearest_rank(sorted, 0.95),
		"max": sorted.back(),
	}


func _nearest_rank(sorted: Array[float], percentile: float) -> float:
	var rank := ceili(
		clampf(percentile, 0.0, 1.0) * sorted.size()
	)
	return sorted[clampi(rank - 1, 0, sorted.size() - 1)]


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if viewport_rid.is_valid():
		RenderingServer.viewport_set_measure_render_time(
			viewport_rid,
			false
		)
	current_scene = null
	if game != null and is_instance_valid(game):
		game.queue_free()
	for _cleanup_frame in range(CLEANUP_SETTLE_FRAMES):
		await process_frame
		await physics_frame
	if failures.is_empty():
		print("DAY_NIGHT_LIGHTING_PERFORMANCE_PROBE_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)
