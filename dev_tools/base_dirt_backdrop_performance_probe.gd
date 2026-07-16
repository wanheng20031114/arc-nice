extends SceneTree

const TOWER_SCENE := preload("res://scene/game_tower_defense.tscn")
const SAMPLE_FRAMES := 180
const WARMUP_FRAMES := 45

var failures: Array[String] = []
var game: GameTowerDefense
var viewport_rid := RID()
var original_max_fps := 0


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	original_max_fps = Engine.max_fps
	Engine.max_fps = 0
	game = TOWER_SCENE.instantiate() as GameTowerDefense
	_expect(game != null, "Tower-defense scene must instantiate for the base-dirt render probe.")
	if game == null:
		await _finish()
		return
	game.auto_start_waves = false
	root.add_child(game)
	current_scene = game
	await process_frame
	await physics_frame

	var backdrop := game.dual_grid_terrain.base_dirt_backdrop
	_expect(backdrop != null, "Tower defense must expose one repeated base-dirt TextureRect.")
	_expect(
		game.dual_grid_terrain.base_dirt_map_layer == null,
		"The render probe must not find the legacy 49,152-cell base-dirt TileMapLayer."
	)
	if backdrop == null:
		await _finish()
		return
	_expect(backdrop.texture != null, "Repeated base dirt must have a texture.")
	_expect(
		backdrop.texture != null and backdrop.texture.get_size() == Vector2(16.0, 16.0),
		"Repeated base dirt must use the exact 16x16 authored full tile."
	)
	_expect(
		backdrop.stretch_mode == TextureRect.STRETCH_TILE,
		"Repeated base dirt must use native TextureRect tiling."
	)

	game.set_process(false)
	game.set_physics_process(false)
	viewport_rid = game.get_viewport().get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(viewport_rid, true)

	var visible_first := await _measure_phase(backdrop, true)
	var hidden := await _measure_phase(backdrop, false)
	var visible_second := await _measure_phase(backdrop, true)
	var visible_cpu_p95 := (
		float(visible_first["render_cpu_p95"])
		+ float(visible_second["render_cpu_p95"])
	) * 0.5
	var hidden_cpu_p95 := float(hidden["render_cpu_p95"])
	_expect(
		visible_cpu_p95 <= hidden_cpu_p95 + 0.5,
		"One repeated base-dirt CanvasItem must stay within a 0.5 ms render-CPU budget over hidden."
	)
	_expect(
		float(visible_first["canvas_objects_p50"])
		<= float(hidden["canvas_objects_p50"]) + 2.0,
		"The repeated base dirt must contribute at most one CanvasItem plus renderer bookkeeping."
	)
	print(
		(
			"BASE_DIRT_BACKDROP_RENDER_METRICS visible_cpu_p95=%.3f hidden_cpu_p95=%.3f "
			+ "visible_objects=%.0f hidden_objects=%.0f visible_draws=%.0f hidden_draws=%.0f"
		)
		% [
			visible_cpu_p95,
			hidden_cpu_p95,
			float(visible_first["canvas_objects_p50"]),
			float(hidden["canvas_objects_p50"]),
			float(visible_first["canvas_draws_p50"]),
			float(hidden["canvas_draws_p50"]),
		]
	)
	await _finish()


func _measure_phase(backdrop: TextureRect, visible: bool) -> Dictionary:
	backdrop.visible = visible
	for _warmup_frame in range(WARMUP_FRAMES):
		await process_frame
	var render_cpu_samples: Array[float] = []
	var canvas_object_samples: Array[float] = []
	var canvas_draw_samples: Array[float] = []
	for _sample_frame in range(SAMPLE_FRAMES):
		await process_frame
		render_cpu_samples.append(
			RenderingServer.viewport_get_measured_render_time_cpu(viewport_rid)
		)
		canvas_object_samples.append(
			RenderingServer.viewport_get_render_info(
				viewport_rid,
				RenderingServer.VIEWPORT_RENDER_INFO_TYPE_CANVAS,
				RenderingServer.VIEWPORT_RENDER_INFO_OBJECTS_IN_FRAME
			)
		)
		canvas_draw_samples.append(
			RenderingServer.viewport_get_render_info(
				viewport_rid,
				RenderingServer.VIEWPORT_RENDER_INFO_TYPE_CANVAS,
				RenderingServer.VIEWPORT_RENDER_INFO_DRAW_CALLS_IN_FRAME
			)
		)
	return {
		"render_cpu_p95": _percentile(render_cpu_samples, 0.95),
		"canvas_objects_p50": _percentile(canvas_object_samples, 0.50),
		"canvas_draws_p50": _percentile(canvas_draw_samples, 0.50),
	}


func _percentile(samples: Array[float], percentile: float) -> float:
	if samples.is_empty():
		return 0.0
	var sorted := samples.duplicate()
	sorted.sort()
	var rank := ceili(clampf(percentile, 0.0, 1.0) * sorted.size())
	return sorted[clampi(rank - 1, 0, sorted.size() - 1)]


func _finish() -> void:
	Engine.max_fps = original_max_fps
	if viewport_rid.is_valid():
		RenderingServer.viewport_set_measure_render_time(viewport_rid, false)
	current_scene = null
	if game != null:
		game.queue_free()
	for _cleanup_frame in range(8):
		await process_frame
		await physics_frame
	if failures.is_empty():
		print("BASE_DIRT_BACKDROP_PERFORMANCE_PROBE_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
