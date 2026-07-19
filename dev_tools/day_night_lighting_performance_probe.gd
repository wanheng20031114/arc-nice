extends SceneTree

# This probe intentionally requires a real rendering driver. Do not run it with
# --headless: the render CPU/GPU monitors and Canvas draw-call counts would no
# longer describe PointLight2D cost.
const TOWER_SCENE := preload("res://scene/game_tower_defense.tscn")
const DAY_NIGHT_SCENE := preload(
	"res://scene/lighting/day_night_controller.tscn"
)
const NIGHT_LIGHT_SCENE := preload(
	"res://scene/lighting/night_point_light.tscn"
)
const VEGETATION_RING_TEXTURE := preload(
	"res://resources/lighting/vegetation_ring_point_light.tres"
)

const EXPECTED_AUTHORED_LIGHT_COUNT := 8
const DEFAULT_STRESS_LIGHT_COUNT := 100
const MICRO_BENCHMARK_LIGHT_COUNT := 300
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
var game: GameTowerDefense = null
var controller: DayNightController = null
var stress_root: Node2D = null
var stress_lights: Array[NightPointLight2D] = []
var viewport_rid := RID()

var warmup_frames := DEFAULT_WARMUP_FRAMES
var sample_frames := DEFAULT_SAMPLE_FRAMES
var micro_sample_count := DEFAULT_MICRO_SAMPLE_COUNT
var stress_light_count := DEFAULT_STRESS_LIGHT_COUNT
var save_screenshot := false


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

	game = TOWER_SCENE.instantiate() as GameTowerDefense
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

	_stop_background_gameplay()
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

	var authored_lights := _collect_night_lights(game)
	_expect(
		authored_lights.size() == EXPECTED_AUTHORED_LIGHT_COUNT,
		(
			"Tower-defense fixture must contain one player light and seven "
			+ "authored gate lights."
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
		"Night baseline must enable the player and seven fixed gate lights."
	)
	var fixed_summary: Dictionary = await _measure_phase(
		"night_fixed_gate_player",
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
		"night_fixed_gate_player",
		"day_zero_active",
		fixed_summary,
		day_zero_summary
	)
	_print_phase_delta(
		"night_%d_green_spread" % stress_light_count,
		"night_fixed_gate_player",
		spread_summary,
		fixed_summary
	)
	_print_phase_delta(
		"night_%d_green_dense" % stress_light_count,
		"night_fixed_gate_player",
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


func _position_stress_lights_spread() -> void:
	var light_radius := (
		64.0 * GREEN_RING_TEXTURE_SCALE * 0.5
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
		elapsed_ms >= 2800.0,
		"%s completed too quickly to represent the authored 3-second tween."
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
	var draw_calls := summary["draw_calls"] as Dictionary
	print(
		(
			"DAY_NIGHT_LIGHTING_TRANSITION phase=%s frames=%d "
			+ "elapsed_ms=%.3f wall_p95_ms=%.3f wall_max_ms=%.3f "
			+ "render_cpu_p95_ms=%.3f render_cpu_max_ms=%.3f "
			+ "render_gpu_p95_ms=%.3f render_gpu_max_ms=%.3f "
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
	var micro_viewport := SubViewport.new()
	micro_viewport.name = "LightingBroadcastMicroViewport"
	micro_viewport.disable_3d = true
	micro_viewport.size = Vector2i(64, 64)
	micro_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	root.add_child(micro_viewport)

	var micro_world := Node2D.new()
	micro_world.name = "LightingBroadcastMicroWorld"
	micro_viewport.add_child(micro_world)
	var micro_controller := (
		DAY_NIGHT_SCENE.instantiate() as DayNightController
	)
	micro_world.add_child(micro_controller)
	var micro_lights: Array[NightPointLight2D] = []
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
		micro_world.add_child(light)
		micro_lights.append(light)
	await process_frame
	await process_frame

	_expect(
		micro_controller != null
		and micro_lights.size() == MICRO_BENCHMARK_LIGHT_COUNT,
		"Broadcast microbenchmark must instantiate exactly three hundred lights."
	)
	if (
		micro_controller == null
		or micro_lights.size() != MICRO_BENCHMARK_LIGHT_COUNT
	):
		micro_viewport.queue_free()
		await process_frame
		return

	for warmup_index in range(24):
		micro_controller.call(
			"_apply_night_factor",
			0.35 if warmup_index % 2 == 0 else 0.85
		)
	_expect(
		_count_enabled_lights(micro_lights)
			== MICRO_BENCHMARK_LIGHT_COUNT,
		"All microbenchmark lights must receive the night-factor broadcast."
	)

	var broadcast_samples_usec: Array[float] = []
	var total_started_usec := Time.get_ticks_usec()
	for sample_index in range(micro_sample_count):
		var sample_started_usec := Time.get_ticks_usec()
		micro_controller.call(
			"_apply_night_factor",
			0.35 if sample_index % 2 == 0 else 0.85
		)
		broadcast_samples_usec.append(
			float(Time.get_ticks_usec() - sample_started_usec)
		)
	var total_usec := Time.get_ticks_usec() - total_started_usec
	var summary := _summarize(broadcast_samples_usec)
	_expect(
		float(summary["p95"]) <= 1000.0,
		"Three hundred light broadcasts exceeded the 1 ms CPU p95 budget."
	)
	_expect(
		float(summary["max"]) <= 2000.0,
		"Three hundred light broadcasts exceeded the 2 ms CPU maximum budget."
	)

	micro_controller.set_night_factor_immediate(0.0)
	_expect(
		_all_lights_disabled(micro_lights),
		"Microbenchmark teardown must return all three hundred lights to day."
	)
	print(
		(
			"DAY_NIGHT_LIGHTING_BROADCAST_CPU lights=%d samples=%d "
			+ "total_us=%d per_broadcast_p50_us=%.1f "
			+ "per_broadcast_p95_us=%.1f per_broadcast_max_us=%.1f "
			+ "p95_per_light_ns=%.1f"
		)
		% [
			MICRO_BENCHMARK_LIGHT_COUNT,
			micro_sample_count,
			total_usec,
			summary["p50"],
			summary["p95"],
			summary["max"],
			float(summary["p95"]) * 1000.0
				/ float(MICRO_BENCHMARK_LIGHT_COUNT),
		]
	)

	micro_viewport.queue_free()
	await process_frame
	await process_frame


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
		64.0 * GREEN_RING_TEXTURE_SCALE * 0.5
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
		if candidate is NightPointLight2D:
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
