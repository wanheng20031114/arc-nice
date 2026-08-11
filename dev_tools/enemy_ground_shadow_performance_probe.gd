extends SceneTree

# This probe deliberately needs a real rendering driver. It keeps one fixed
# cohort alive and alternates only GroundShadow visibility, so gameplay,
# physics, animation and allocation noise are identical on both A/B arms.
const LIGHTWEIGHT_ENEMY_SCENE := preload(
	"res://scene/enemy/slime/slime_basic.tscn"
)
const SHARED_SHADOW_TEXTURE := preload(
	"res://resources/texture/enemy/enemy_ground_shadow.tres"
)

const DEFAULT_ENEMY_COUNT := 1000
const DEFAULT_WARMUP_FRAMES := 30
const DEFAULT_SAMPLE_FRAMES := 90
const DEFAULT_SAMPLE_PAIRS := 3
const GRID_COLUMNS := 40
const GRID_ORIGIN := Vector2(40.0, 54.0)
const GRID_SPACING := Vector2(27.0, 20.0)
const MOTION_OFFSET := 0.5
const SETTLE_FRAMES := 8

# The threshold is intentionally much wider than the expected desktop result.
# It guards against an architectural regression (per-shadow material/draw or
# process callback), not tiny differences between graphics drivers.
const MAX_BATCH_DRAW_CALL_DELTA := 2.0
const MAX_STATIC_RENDER_CPU_P50_DELTA_MS := 1.5
const MAX_MOVING_RENDER_CPU_P50_DELTA_MS := 2.0
const MAX_RENDER_GPU_P50_DELTA_MS := 1.0

var failures: Array[String] = []
var fixture: Node2D = null
var enemies: Array[Enemy] = []
var shadows: Array[Sprite2D] = []
var authored_positions: Array[Vector2] = []
var viewport_rid := RID()

var enemy_count := DEFAULT_ENEMY_COUNT
var warmup_frames := DEFAULT_WARMUP_FRAMES
var sample_frames := DEFAULT_SAMPLE_FRAMES
var sample_pairs := DEFAULT_SAMPLE_PAIRS


func _init() -> void:
	_parse_user_arguments()
	call_deferred(&"_run")


func _run() -> void:
	Engine.max_fps = 0
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	fixture = Node2D.new()
	fixture.name = "EnemyGroundShadowPerformanceProbe"
	root.add_child(fixture)
	current_scene = fixture

	await _spawn_frozen_cohort()
	viewport_rid = root.get_viewport().get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(viewport_rid, true)
	_print_fixture_header()

	# Compile/upload the one shared gradient before either measured arm. This
	# keeps the test about steady-state shadows rather than first-use pipelines.
	_set_shadows_visible(true)
	await _wait_frames(warmup_frames, false)
	_set_shadows_visible(false)
	await _wait_frames(SETTLE_FRAMES, false)

	var static_hidden: Array[Dictionary] = []
	var static_visible: Array[Dictionary] = []
	var moving_hidden: Array[Dictionary] = []
	var moving_visible: Array[Dictionary] = []
	for pair_index in range(sample_pairs):
		if pair_index % 2 == 0:
			static_hidden.append(await _measure_phase(false, false, pair_index))
			static_visible.append(await _measure_phase(true, false, pair_index))
			moving_visible.append(await _measure_phase(true, true, pair_index))
			moving_hidden.append(await _measure_phase(false, true, pair_index))
		else:
			static_visible.append(await _measure_phase(true, false, pair_index))
			static_hidden.append(await _measure_phase(false, false, pair_index))
			moving_hidden.append(await _measure_phase(false, true, pair_index))
			moving_visible.append(await _measure_phase(true, true, pair_index))

	_assert_ab_contract("static", static_hidden, static_visible)
	_assert_ab_contract("moving", moving_hidden, moving_visible)
	_print_ab_summary("static", static_hidden, static_visible)
	_print_ab_summary("moving", moving_hidden, moving_visible)
	await _finish()


func _parse_user_arguments() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--enemies="):
			enemy_count = maxi(int(argument.get_slice("=", 1)), 1)
		elif argument.begins_with("--warmup="):
			warmup_frames = maxi(int(argument.get_slice("=", 1)), 4)
		elif argument.begins_with("--samples="):
			sample_frames = maxi(int(argument.get_slice("=", 1)), 20)
		elif argument.begins_with("--pairs="):
			sample_pairs = maxi(int(argument.get_slice("=", 1)), 1)


func _spawn_frozen_cohort() -> void:
	var setup_started_usec := Time.get_ticks_usec()
	var shared_texture_instance_id := SHARED_SHADOW_TEXTURE.get_instance_id()
	for enemy_index in range(enemy_count):
		var enemy := LIGHTWEIGHT_ENEMY_SCENE.instantiate() as Enemy
		_expect(enemy != null, "Every fixture entry must instantiate as Enemy.")
		if enemy == null:
			continue
		_freeze_enemy(enemy)
		enemy.position = GRID_ORIGIN + Vector2(
			float(enemy_index % GRID_COLUMNS) * GRID_SPACING.x,
			float(enemy_index / GRID_COLUMNS) * GRID_SPACING.y
		)
		fixture.add_child(enemy)
		var shadow := enemy.get_node_or_null("GroundShadow") as Sprite2D
		_expect(shadow != null, "Every fixture enemy must inherit GroundShadow.")
		if shadow == null:
			enemy.queue_free()
			continue
		_expect(
			shadow.texture == SHARED_SHADOW_TEXTURE
			and shadow.texture.get_instance_id() == shared_texture_instance_id,
			"Every fixture shadow must retain one shared GradientTexture2D."
		)
		_expect(
			shadow.material == null and not shadow.use_parent_material,
			"GroundShadow must not create or inherit a per-instance material."
		)
		_expect(
			shadow.get_script() == null
			and not shadow.is_processing()
			and not shadow.is_physics_processing(),
			"GroundShadow must add no script or independent process callback."
		)
		enemies.append(enemy)
		shadows.append(shadow)
		authored_positions.append(enemy.position)

	await _wait_frames(SETTLE_FRAMES, false)
	_expect(enemies.size() == enemy_count, "The complete stress cohort must spawn.")
	_expect(shadows.size() == enemy_count, "The complete shadow cohort must spawn.")
	print(
		"ENEMY_GROUND_SHADOW_SETUP enemies=%d setup_ms=%.3f nodes=%d"
		% [
			enemies.size(),
			float(Time.get_ticks_usec() - setup_started_usec) / 1000.0,
			int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
		]
	)


func _freeze_enemy(enemy: Enemy) -> void:
	enemy.process_mode = Node.PROCESS_MODE_DISABLED
	enemy.collision_layer = 0
	enemy.collision_mask = 0
	var body_shape := enemy.get_node_or_null("CollisionShape2D") as CollisionShape2D
	if body_shape != null:
		body_shape.disabled = true
	var touch_area := enemy.get_node_or_null("TouchDamageArea") as Area2D
	if touch_area != null:
		touch_area.collision_layer = 0
		touch_area.collision_mask = 0
		touch_area.monitoring = false
		touch_area.monitorable = false
		var touch_shape := (
			touch_area.get_node_or_null("CollisionShape2D") as CollisionShape2D
		)
		if touch_shape != null:
			touch_shape.disabled = true


func _print_fixture_header() -> void:
	print(
		(
			"ENEMY_GROUND_SHADOW_FIXTURE enemies=%d pairs=%d samples=%d "
			+ "warmup=%d window=%s viewport=%s renderer=%s driver=%s gpu=%s"
		)
		% [
			enemies.size(),
			sample_pairs,
			sample_frames,
			warmup_frames,
			str(DisplayServer.window_get_size()),
			str(root.get_viewport().get_visible_rect().size),
			RenderingServer.get_current_rendering_method(),
			RenderingServer.get_current_rendering_driver_name(),
			RenderingServer.get_video_adapter_name(),
		]
	)


func _measure_phase(
	visible: bool,
	moving: bool,
	pair_index: int
) -> Dictionary:
	_set_shadows_visible(visible)
	_reset_enemy_positions()
	await _wait_frames(warmup_frames, moving)
	var summary := await _sample_monitor_window(moving)
	var label := "%s_%s_pair%d" % [
		"moving" if moving else "static",
		"visible" if visible else "hidden",
		pair_index,
	]
	_print_phase_summary(label, summary)
	return summary


func _set_shadows_visible(is_visible: bool) -> void:
	for shadow in shadows:
		shadow.visible = is_visible


func _reset_enemy_positions() -> void:
	for enemy_index in range(enemies.size()):
		enemies[enemy_index].position = authored_positions[enemy_index]


func _wait_frames(frame_count: int, moving: bool) -> void:
	for frame_index in range(frame_count):
		if moving:
			_apply_motion(frame_index)
		await process_frame


func _apply_motion(frame_index: int) -> void:
	var offset := MOTION_OFFSET if frame_index % 2 == 0 else -MOTION_OFFSET
	for enemy_index in range(enemies.size()):
		enemies[enemy_index].position = (
			authored_positions[enemy_index] + Vector2(offset, 0.0)
		)


func _sample_monitor_window(moving: bool) -> Dictionary:
	var process_samples: Array[float] = []
	var frame_setup_samples: Array[float] = []
	var render_cpu_samples: Array[float] = []
	var render_gpu_samples: Array[float] = []
	var render_total_cpu_samples: Array[float] = []
	var canvas_draw_call_samples: Array[float] = []
	var canvas_object_samples: Array[float] = []
	var canvas_primitive_samples: Array[float] = []
	var vram_samples_mib: Array[float] = []
	var node_count_samples: Array[float] = []
	for frame_index in range(sample_frames):
		if moving:
			_apply_motion(frame_index)
		await process_frame
		process_samples.append(
			Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
		)
		var frame_setup_ms := RenderingServer.get_frame_setup_time_cpu()
		var render_cpu_ms := (
			RenderingServer.viewport_get_measured_render_time_cpu(viewport_rid)
		)
		frame_setup_samples.append(frame_setup_ms)
		render_cpu_samples.append(render_cpu_ms)
		render_gpu_samples.append(
			RenderingServer.viewport_get_measured_render_time_gpu(viewport_rid)
		)
		render_total_cpu_samples.append(frame_setup_ms + render_cpu_ms)
		canvas_draw_call_samples.append(
			RenderingServer.viewport_get_render_info(
				viewport_rid,
				RenderingServer.VIEWPORT_RENDER_INFO_TYPE_CANVAS,
				RenderingServer.VIEWPORT_RENDER_INFO_DRAW_CALLS_IN_FRAME
			)
		)
		canvas_object_samples.append(
			RenderingServer.viewport_get_render_info(
				viewport_rid,
				RenderingServer.VIEWPORT_RENDER_INFO_TYPE_CANVAS,
				RenderingServer.VIEWPORT_RENDER_INFO_OBJECTS_IN_FRAME
			)
		)
		canvas_primitive_samples.append(
			RenderingServer.viewport_get_render_info(
				viewport_rid,
				RenderingServer.VIEWPORT_RENDER_INFO_TYPE_CANVAS,
				RenderingServer.VIEWPORT_RENDER_INFO_PRIMITIVES_IN_FRAME
			)
		)
		vram_samples_mib.append(
			Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED)
			/ (1024.0 * 1024.0)
		)
		node_count_samples.append(
			Performance.get_monitor(Performance.OBJECT_NODE_COUNT)
		)
	return {
		"process": _summarize(process_samples),
		"frame_setup": _summarize(frame_setup_samples),
		"render_cpu": _summarize(render_cpu_samples),
		"render_gpu": _summarize(render_gpu_samples),
		"render_total_cpu": _summarize(render_total_cpu_samples),
		"canvas_draw_calls": _summarize(canvas_draw_call_samples),
		"canvas_objects": _summarize(canvas_object_samples),
		"canvas_primitives": _summarize(canvas_primitive_samples),
		"vram_mib": _summarize(vram_samples_mib),
		"nodes": _summarize(node_count_samples),
	}


func _assert_ab_contract(
	label: String,
	hidden_results: Array[Dictionary],
	visible_results: Array[Dictionary]
) -> void:
	var draw_delta := _median_phase_p50(
		visible_results,
		"canvas_draw_calls"
	) - _median_phase_p50(hidden_results, "canvas_draw_calls")
	var object_delta := _median_phase_p50(
		visible_results,
		"canvas_objects"
	) - _median_phase_p50(hidden_results, "canvas_objects")
	var node_delta := _median_phase_p50(
		visible_results,
		"nodes"
	) - _median_phase_p50(hidden_results, "nodes")
	var render_cpu_delta := _median_phase_p50(
		visible_results,
		"render_total_cpu"
	) - _median_phase_p50(hidden_results, "render_total_cpu")
	var render_gpu_delta := _median_phase_p50(
		visible_results,
		"render_gpu"
	) - _median_phase_p50(hidden_results, "render_gpu")
	_expect(
		draw_delta >= 0.0 and draw_delta <= MAX_BATCH_DRAW_CALL_DELTA,
		"%s 1000 shared shadows must batch into at most %.0f extra draw calls; delta=%.1f."
		% [label, MAX_BATCH_DRAW_CALL_DELTA, draw_delta]
	)
	_expect(
		absf(object_delta - float(enemy_count)) <= 1.0,
		"%s visible arm must expose one canvas object per shadow; delta=%.1f."
		% [label, object_delta]
	)
	_expect(
		absf(node_delta) <= 1.0,
		"%s visibility changes must not create/free nodes; delta=%.1f."
		% [label, node_delta]
	)
	var cpu_limit := (
		MAX_MOVING_RENDER_CPU_P50_DELTA_MS
		if label == "moving"
		else MAX_STATIC_RENDER_CPU_P50_DELTA_MS
	)
	_expect(
		render_cpu_delta <= cpu_limit,
		"%s 1000-shadow render CPU p50 delta %.3f ms exceeds %.3f ms."
		% [label, render_cpu_delta, cpu_limit]
	)
	_expect(
		render_gpu_delta <= MAX_RENDER_GPU_P50_DELTA_MS,
		"%s 1000-shadow GPU p50 delta %.3f ms exceeds %.3f ms."
		% [label, render_gpu_delta, MAX_RENDER_GPU_P50_DELTA_MS]
	)


func _print_phase_summary(label: String, summary: Dictionary) -> void:
	var parts := PackedStringArray(["phase=%s" % label])
	for metric in [
		"process",
		"frame_setup",
		"render_cpu",
		"render_gpu",
		"render_total_cpu",
		"canvas_draw_calls",
		"canvas_objects",
		"canvas_primitives",
		"vram_mib",
		"nodes",
	]:
		var values := summary[metric] as Dictionary
		parts.append("%s_p50=%.3f" % [metric, float(values["p50"])])
		parts.append("%s_p95=%.3f" % [metric, float(values["p95"])])
	print("ENEMY_GROUND_SHADOW_PHASE %s" % " ".join(parts))


func _print_ab_summary(
	label: String,
	hidden_results: Array[Dictionary],
	visible_results: Array[Dictionary]
) -> void:
	var parts := PackedStringArray([
		"mode=%s" % label,
		"enemies=%d" % enemy_count,
		"pairs=%d" % sample_pairs,
	])
	for metric in [
		"process",
		"frame_setup",
		"render_cpu",
		"render_gpu",
		"render_total_cpu",
		"canvas_draw_calls",
		"canvas_objects",
		"canvas_primitives",
		"vram_mib",
		"nodes",
	]:
		var hidden_value := _median_phase_p50(hidden_results, metric)
		var visible_value := _median_phase_p50(visible_results, metric)
		parts.append("%s_hidden=%.3f" % [metric, hidden_value])
		parts.append("%s_visible=%.3f" % [metric, visible_value])
		parts.append("%s_delta=%.3f" % [metric, visible_value - hidden_value])
	print("ENEMY_GROUND_SHADOW_AB %s" % " ".join(parts))


func _median_phase_p50(results: Array[Dictionary], metric: String) -> float:
	var values: Array[float] = []
	for result in results:
		values.append(float((result[metric] as Dictionary)["p50"]))
	values.sort()
	return values[values.size() / 2] if not values.is_empty() else 0.0


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
	if viewport_rid.is_valid():
		RenderingServer.viewport_set_measure_render_time(viewport_rid, false)
	current_scene = null
	if fixture != null and is_instance_valid(fixture):
		fixture.queue_free()
	for _cleanup_index in range(10):
		await process_frame
		await physics_frame
	if failures.is_empty():
		print("ENEMY_GROUND_SHADOW_PERFORMANCE_PROBE_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
