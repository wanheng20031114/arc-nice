extends SceneTree

# This probe must run with a real rendering driver. It deliberately keeps the
# navigation performance probe separate: every phase below keeps the same 300
# frozen, on-screen enemies and changes only projectile/effect pressure.
const TOWER_SCENE := preload("res://scene/game_tower_defense.tscn")
const ENEMY_CONFIG := preload(
	"res://resources/config/enemies/yuanshi_insect_basic.tres"
)
const BULLET_SCENE := preload("res://scene/bullet.tscn")
const ENEMY_HIT_EFFECT_SCENE := preload("res://scene/enemy/enemy_hit_effect.tscn")

const ENEMY_COUNT := 300
const ENEMY_COLUMNS := 20
const ENEMY_SPACING := Vector2(14.0, 13.0)
const PROJECTILE_COLUMNS := 40
const PROJECTILE_SPACING := Vector2(3.0, 3.0)
const FIXTURE_CENTER := Vector2(512.0, 352.0)
const HIDDEN_PROJECTILE_ORIGIN := Vector2(-10000.0, -10000.0)
const LONG_PROJECTILE_LIFETIME := 3600.0

const DEFAULT_SAMPLE_FRAMES := 360
const DEFAULT_WARMUP_FRAMES := 120
const DEFAULT_PROJECTILE_COUNT := 600
const DEFAULT_HITS_PER_PHYSICS_FRAME := 10
const DEFAULT_SEED := 20260712

enum ProjectileMode {
	STATIC_VISIBLE,
	ACTIVE_HIDDEN,
	ACTIVE_VISIBLE,
}

var failures: Array[String] = []
var game: GameTowerDefense = null
var enemies: Array[Enemy] = []
var projectiles: Array[Bullet] = []
var viewport_rid := RID()

var sample_frames := DEFAULT_SAMPLE_FRAMES
var warmup_frames := DEFAULT_WARMUP_FRAMES
var projectile_count := DEFAULT_PROJECTILE_COUNT
var hits_per_physics_frame := DEFAULT_HITS_PER_PHYSICS_FRAME
var fixed_seed := DEFAULT_SEED
var hdr_2d_enabled := true
var glow_enabled := true
var hit_pressure_cursor := 0


func _init() -> void:
	_parse_user_arguments()
	call_deferred("_run")


func _run() -> void:
	seed(fixed_seed)
	game = TOWER_SCENE.instantiate() as GameTowerDefense
	_expect(game != null, "Projectile render probe must instantiate tower defense.")
	if game == null:
		await _finish()
		return

	game.auto_start_waves = false
	game.random_generator.seed = fixed_seed
	root.add_child(game)
	current_scene = game
	await process_frame
	await physics_frame

	viewport_rid = game.get_viewport().get_viewport_rid()
	game.get_viewport().use_hdr_2d = hdr_2d_enabled
	var world_environment := game.get_node_or_null("WorldEnvironment") as WorldEnvironment
	_expect(
		world_environment != null and world_environment.environment != null,
		"Projectile render probe requires the tower-defense WorldEnvironment."
	)
	if world_environment != null and world_environment.environment != null:
		world_environment.environment.glow_enabled = glow_enabled
	RenderingServer.viewport_set_measure_render_time(viewport_rid, true)
	game.set_physics_process(false)
	_prepare_camera_fixture()
	var enemy_setup_started_usec := Time.get_ticks_usec()
	_spawn_frozen_visible_enemies()
	var enemy_setup_ms := (
		float(Time.get_ticks_usec() - enemy_setup_started_usec) / 1000.0
	)
	for _settle_frame in range(8):
		await process_frame
		await physics_frame

	_expect(enemies.size() == ENEMY_COUNT, "Probe must create exactly 300 enemies.")
	_expect(
		_count_enemies_inside_camera() == ENEMY_COUNT,
		"All 300 frozen enemies must remain inside the measured camera rectangle."
	)
	print(
		(
			"TOWER_DEFENSE_PROJECTILE_RENDER_FIXTURE enemies=%d "
			+ "enemy_setup_ms=%.3f projectiles=%d samples=%d warmup=%d "
			+ "hits_per_physics_frame=%d seed=%d hdr_2d=%s glow=%s "
			+ "window=%s viewport=%s renderer=%s driver=%s gpu=%s"
		)
		% [
			enemies.size(),
			enemy_setup_ms,
			projectile_count,
			sample_frames,
			warmup_frames,
			hits_per_physics_frame,
			fixed_seed,
			str(hdr_2d_enabled),
			str(glow_enabled),
			str(DisplayServer.window_get_size()),
			str(game.get_viewport().get_visible_rect().size),
			RenderingServer.get_current_rendering_method(),
			RenderingServer.get_current_rendering_driver_name(),
			RenderingServer.get_video_adapter_name(),
		]
	)

	await _measure_phase("baseline_300_enemies", 0.0, false)

	var setup_started_usec := Time.get_ticks_usec()
	_spawn_projectiles(ProjectileMode.STATIC_VISIBLE)
	var setup_ms := float(Time.get_ticks_usec() - setup_started_usec) / 1000.0
	await _measure_phase("static_visible_projectiles", setup_ms, false)
	await _clear_projectiles()

	setup_started_usec = Time.get_ticks_usec()
	_spawn_projectiles(ProjectileMode.ACTIVE_HIDDEN)
	setup_ms = float(Time.get_ticks_usec() - setup_started_usec) / 1000.0
	await _measure_phase("active_hidden_projectiles", setup_ms, false)
	await _clear_projectiles()

	setup_started_usec = Time.get_ticks_usec()
	_spawn_projectiles(ProjectileMode.ACTIVE_VISIBLE)
	setup_ms = float(Time.get_ticks_usec() - setup_started_usec) / 1000.0
	await _measure_phase("active_visible_projectiles", setup_ms, false)
	await _measure_phase("active_visible_plus_hit_particles", 0.0, true)
	await _clear_projectiles()

	await _finish()


func _parse_user_arguments() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--samples="):
			sample_frames = maxi(int(argument.get_slice("=", 1)), 10)
		elif argument.begins_with("--warmup="):
			warmup_frames = maxi(int(argument.get_slice("=", 1)), 2)
		elif argument.begins_with("--projectiles="):
			projectile_count = maxi(int(argument.get_slice("=", 1)), 1)
		elif argument.begins_with("--hits-per-physics-frame="):
			hits_per_physics_frame = maxi(int(argument.get_slice("=", 1)), 0)
		elif argument.begins_with("--seed="):
			fixed_seed = int(argument.get_slice("=", 1))
		elif argument.begins_with("--hdr2d="):
			hdr_2d_enabled = _parse_bool(argument.get_slice("=", 1), true)
		elif argument.begins_with("--glow="):
			glow_enabled = _parse_bool(argument.get_slice("=", 1), true)


func _parse_bool(value: String, default_value: bool) -> bool:
	match value.strip_edges().to_lower():
		"1", "true", "yes", "on":
			return true
		"0", "false", "no", "off":
			return false
		_:
			return default_value


func _prepare_camera_fixture() -> void:
	if game.player != null:
		game.player.global_position = FIXTURE_CENTER
		game.player.velocity = Vector2.ZERO
		game.player.set_physics_process(false)
		game.player.set_process(false)
	if game.map_camera != null:
		game.map_camera.position = Vector2.ZERO
		game.map_camera.position_smoothing_enabled = false
		game.map_camera.enabled = true


func _spawn_frozen_visible_enemies() -> void:
	var row_count := ceili(float(ENEMY_COUNT) / float(ENEMY_COLUMNS))
	var grid_size := Vector2(
		float(ENEMY_COLUMNS - 1) * ENEMY_SPACING.x,
		float(row_count - 1) * ENEMY_SPACING.y
	)
	var grid_origin := FIXTURE_CENTER - grid_size * 0.5
	for enemy_index in range(ENEMY_COUNT):
		var enemy := ENEMY_CONFIG.enemy_scene.instantiate() as Enemy
		_expect(enemy != null, "Every render fixture enemy must instantiate.")
		if enemy == null:
			continue
		game.enemy_container.add_child(enemy)
		enemy.setup(ENEMY_CONFIG, game.player, null)
		enemy.configure_multiplayer_proxy()
		enemy.collision_layer = 0
		enemy.collision_mask = 0
		enemy.global_position = grid_origin + Vector2(
			float(enemy_index % ENEMY_COLUMNS) * ENEMY_SPACING.x,
			float(enemy_index / ENEMY_COLUMNS) * ENEMY_SPACING.y
		)
		enemies.append(enemy)


func _count_enemies_inside_camera() -> int:
	var viewport_size := Vector2(game.get_viewport().get_visible_rect().size)
	var zoom := Vector2.ONE
	if game.map_camera != null:
		zoom = game.map_camera.zoom.abs()
	zoom.x = maxf(zoom.x, 0.001)
	zoom.y = maxf(zoom.y, 0.001)
	var world_size := Vector2(viewport_size.x / zoom.x, viewport_size.y / zoom.y)
	var camera_rect := Rect2(FIXTURE_CENTER - world_size * 0.5, world_size)
	var visible_count := 0
	for enemy in enemies:
		if (
			enemy != null
			and is_instance_valid(enemy)
			and enemy.is_visible_in_tree()
			and camera_rect.has_point(enemy.global_position)
		):
			visible_count += 1
	return visible_count


func _spawn_projectiles(mode: ProjectileMode) -> void:
	projectiles.clear()
	var row_count := ceili(float(projectile_count) / float(PROJECTILE_COLUMNS))
	var visible_grid_size := Vector2(
		float(PROJECTILE_COLUMNS - 1) * PROJECTILE_SPACING.x,
		float(row_count - 1) * PROJECTILE_SPACING.y
	)
	var visible_grid_origin := FIXTURE_CENTER - visible_grid_size * 0.5
	for projectile_index in range(projectile_count):
		var bullet := game.acquire_session_object(BULLET_SCENE, false) as Bullet
		_expect(bullet != null, "Every projectile pressure fixture must acquire Bullet.")
		if bullet == null:
			continue
		var direction := Vector2.RIGHT.rotated(
			float(projectile_index % 32) / 32.0 * TAU
		)
		bullet.top_level = true
		bullet.max_lifetime = LONG_PROJECTILE_LIFETIME
		bullet.speed = 0.0 if mode != ProjectileMode.ACTIVE_HIDDEN else 320.0
		bullet.setup(direction, 1, false)
		if mode == ProjectileMode.STATIC_VISIBLE:
			bullet.set_physics_process(false)
			bullet.monitoring = false
			bullet.monitorable = false
			bullet.collision_layer = 0
			bullet.collision_mask = 0
		elif mode == ProjectileMode.ACTIVE_VISIBLE:
			# The Bullet still runs its real physics callback and world sweep. Area
			# contacts are disabled so this phase keeps a stable population and does
			# not accidentally include hit feedback.
			bullet.collision_layer = 0
			bullet.collision_mask = 0
		if bullet.get_parent() == null:
			game.add_child(bullet)
		if mode == ProjectileMode.ACTIVE_HIDDEN:
			bullet.visible = false
			bullet.global_position = HIDDEN_PROJECTILE_ORIGIN + Vector2(
				float(projectile_index % PROJECTILE_COLUMNS) * 2.0,
				float(projectile_index / PROJECTILE_COLUMNS) * 2.0
			)
		else:
			bullet.global_position = visible_grid_origin + Vector2(
				float(projectile_index % PROJECTILE_COLUMNS) * PROJECTILE_SPACING.x,
				float(projectile_index / PROJECTILE_COLUMNS) * PROJECTILE_SPACING.y
			)
		bullet.remaining_lifetime = LONG_PROJECTILE_LIFETIME
		bullet.reset_physics_interpolation()
		projectiles.append(bullet)


func _measure_phase(label: String, setup_ms: float, drive_hit_particles: bool) -> void:
	var pipeline_canvas_before := _get_pipeline_compilation_count(
		RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_CANVAS
	)
	var pipeline_draw_before := _get_pipeline_compilation_count(
		RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_DRAW
	)
	var transition_max_ms := await _warmup_phase(drive_hit_particles)
	var summary := await _sample_monitor_window(drive_hit_particles)
	var pipeline_canvas_delta := maxi(
		_get_pipeline_compilation_count(
			RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_CANVAS
		) - pipeline_canvas_before,
		0
	)
	var pipeline_draw_delta := maxi(
		_get_pipeline_compilation_count(
			RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_DRAW
		) - pipeline_draw_before,
		0
	)
	_print_phase_summary(
		label,
		summary,
		setup_ms,
		transition_max_ms,
		pipeline_canvas_delta,
		pipeline_draw_delta
	)
	var live_projectiles := _count_live_projectiles()
	if label != "baseline_300_enemies":
		_expect(
			live_projectiles == projectile_count,
			"%s must retain exactly %d projectiles, found %d."
			% [label, projectile_count, live_projectiles]
		)
	var draw_summary := summary["draw_calls"] as Dictionary
	var render_cpu_summary := summary["render_cpu"] as Dictionary
	var render_gpu_summary := summary["render_gpu"] as Dictionary
	_expect(float(draw_summary["p50"]) > 0.0, "%s requires a real render loop." % label)
	_expect(
		float(render_cpu_summary["p50"]) > 0.0,
		"%s must expose non-zero viewport render CPU time." % label
	)
	_expect(
		float(render_gpu_summary["p50"]) > 0.0,
		"%s must expose non-zero viewport GPU time; do not run headless." % label
	)


func _warmup_phase(drive_hit_particles: bool) -> float:
	var previous_tick_usec := Time.get_ticks_usec()
	var maximum_ms := 0.0
	var last_physics_frame := -1
	for _frame_index in range(warmup_frames):
		await process_frame
		var now_usec := Time.get_ticks_usec()
		maximum_ms = maxf(
			maximum_ms,
			float(now_usec - previous_tick_usec) / 1000.0
		)
		previous_tick_usec = now_usec
		if drive_hit_particles:
			last_physics_frame = _drive_hits_on_new_physics_frame(last_physics_frame)
	return maximum_ms


func _sample_monitor_window(drive_hit_particles: bool) -> Dictionary:
	var wall_samples: Array[float] = []
	var process_samples: Array[float] = []
	var physics_samples: Array[float] = []
	var frame_setup_samples: Array[float] = []
	var render_cpu_samples: Array[float] = []
	var render_gpu_samples: Array[float] = []
	var render_total_cpu_samples: Array[float] = []
	var draw_call_samples: Array[float] = []
	var render_object_samples: Array[float] = []
	var primitive_samples: Array[float] = []
	var canvas_draw_call_samples: Array[float] = []
	var canvas_object_samples: Array[float] = []
	var canvas_primitive_samples: Array[float] = []
	var collision_pair_samples: Array[float] = []
	var vram_samples_mib: Array[float] = []
	var node_count_samples: Array[float] = []
	var previous_tick_usec := Time.get_ticks_usec()
	var last_sampled_physics_frame := -1
	var last_driven_physics_frame := -1
	for _frame_index in range(sample_frames):
		await process_frame
		var now_usec := Time.get_ticks_usec()
		wall_samples.append(float(now_usec - previous_tick_usec) / 1000.0)
		previous_tick_usec = now_usec
		if drive_hit_particles:
			last_driven_physics_frame = _drive_hits_on_new_physics_frame(
				last_driven_physics_frame
			)

		process_samples.append(
			Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
		)
		var current_physics_frame := Engine.get_physics_frames()
		if current_physics_frame != last_sampled_physics_frame:
			last_sampled_physics_frame = current_physics_frame
			physics_samples.append(
				Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
			)

		var frame_setup_ms := RenderingServer.get_frame_setup_time_cpu()
		var viewport_render_cpu_ms := (
			RenderingServer.viewport_get_measured_render_time_cpu(viewport_rid)
		)
		frame_setup_samples.append(frame_setup_ms)
		render_cpu_samples.append(viewport_render_cpu_ms)
		render_gpu_samples.append(
			RenderingServer.viewport_get_measured_render_time_gpu(viewport_rid)
		)
		render_total_cpu_samples.append(frame_setup_ms + viewport_render_cpu_ms)
		draw_call_samples.append(
			Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
		)
		render_object_samples.append(
			Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)
		)
		primitive_samples.append(
			Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)
		)
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
		collision_pair_samples.append(
			Performance.get_monitor(Performance.PHYSICS_2D_COLLISION_PAIRS)
		)
		vram_samples_mib.append(
			Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED)
			/ (1024.0 * 1024.0)
		)
		node_count_samples.append(
			Performance.get_monitor(Performance.OBJECT_NODE_COUNT)
		)

	return {
		"wall": _summarize(wall_samples),
		"process": _summarize(process_samples),
		"physics": _summarize(physics_samples),
		"frame_setup": _summarize(frame_setup_samples),
		"render_cpu": _summarize(render_cpu_samples),
		"render_gpu": _summarize(render_gpu_samples),
		"render_total_cpu": _summarize(render_total_cpu_samples),
		"draw_calls": _summarize(draw_call_samples),
		"render_objects": _summarize(render_object_samples),
		"primitives": _summarize(primitive_samples),
		"canvas_draw_calls": _summarize(canvas_draw_call_samples),
		"canvas_objects": _summarize(canvas_object_samples),
		"canvas_primitives": _summarize(canvas_primitive_samples),
		"collision_pairs": _summarize(collision_pair_samples),
		"vram_mib": _summarize(vram_samples_mib),
		"nodes": _summarize(node_count_samples),
	}


func _drive_hits_on_new_physics_frame(previous_physics_frame: int) -> int:
	var current_physics_frame := Engine.get_physics_frames()
	if current_physics_frame == previous_physics_frame:
		return previous_physics_frame
	if enemies.is_empty() or hits_per_physics_frame <= 0:
		return current_physics_frame
	for _hit_index in range(hits_per_physics_frame):
		var enemy := enemies[hit_pressure_cursor % enemies.size()]
		hit_pressure_cursor = (hit_pressure_cursor + 1) % enemies.size()
		if enemy != null and is_instance_valid(enemy):
			enemy.play_multiplayer_damage_feedback(Vector2.RIGHT, true)
	return current_physics_frame


func _get_pipeline_compilation_count(info: RenderingServer.RenderingInfo) -> int:
	return RenderingServer.get_rendering_info(info)


func _print_phase_summary(
	label: String,
	summary: Dictionary,
	setup_ms: float,
	transition_max_ms: float,
	pipeline_canvas_delta: int,
	pipeline_draw_delta: int
) -> void:
	var parts := PackedStringArray([
		"phase=%s" % label,
		"enemies=%d" % enemies.size(),
		"projectiles=%d" % _count_live_projectiles(),
		"setup_ms=%.3f" % setup_ms,
		"transition_max_ms=%.3f" % transition_max_ms,
		"pipeline_canvas_delta=%d" % pipeline_canvas_delta,
		"pipeline_draw_delta=%d" % pipeline_draw_delta,
	])
	_append_summary_parts(parts, "wall_ms", summary["wall"] as Dictionary)
	_append_summary_parts(parts, "process_ms", summary["process"] as Dictionary)
	_append_summary_parts(parts, "physics_ms", summary["physics"] as Dictionary)
	_append_summary_parts(parts, "frame_setup_ms", summary["frame_setup"] as Dictionary)
	_append_summary_parts(parts, "render_cpu_ms", summary["render_cpu"] as Dictionary)
	_append_summary_parts(parts, "render_gpu_ms", summary["render_gpu"] as Dictionary)
	_append_summary_parts(
		parts,
		"render_total_cpu_ms",
		summary["render_total_cpu"] as Dictionary
	)
	_append_summary_parts(parts, "draw_calls", summary["draw_calls"] as Dictionary)
	_append_summary_parts(parts, "render_objects", summary["render_objects"] as Dictionary)
	_append_summary_parts(parts, "primitives", summary["primitives"] as Dictionary)
	_append_summary_parts(
		parts,
		"canvas_draw_calls",
		summary["canvas_draw_calls"] as Dictionary
	)
	_append_summary_parts(parts, "canvas_objects", summary["canvas_objects"] as Dictionary)
	_append_summary_parts(
		parts,
		"canvas_primitives",
		summary["canvas_primitives"] as Dictionary
	)
	_append_summary_parts(
		parts,
		"collision_pairs",
		summary["collision_pairs"] as Dictionary
	)
	_append_summary_parts(parts, "vram_mib", summary["vram_mib"] as Dictionary)
	_append_summary_parts(parts, "nodes", summary["nodes"] as Dictionary)
	var pool_metrics := game.session_object_pool.get_metrics(BULLET_SCENE.resource_path)
	parts.append("pool_created=%d" % int(pool_metrics.get("created", 0)))
	parts.append("pool_in_use=%d" % int(pool_metrics.get("in_use", 0)))
	parts.append("pool_overflow=%d" % int(pool_metrics.get("overflow", 0)))
	var hit_pool_metrics := game.session_object_pool.get_metrics(
		ENEMY_HIT_EFFECT_SCENE.resource_path
	)
	parts.append("hit_pool_in_use=%d" % int(hit_pool_metrics.get("in_use", 0)))
	parts.append("hit_pool_dropped=%d" % int(hit_pool_metrics.get("dropped", 0)))
	print("TOWER_DEFENSE_PROJECTILE_RENDER_PROBE %s" % " ".join(parts))


func _append_summary_parts(
	parts: PackedStringArray,
	label: String,
	summary: Dictionary
) -> void:
	parts.append("%s_p50=%.3f" % [label, float(summary["p50"])])
	parts.append("%s_p95=%.3f" % [label, float(summary["p95"])])
	parts.append("%s_p99=%.3f" % [label, float(summary["p99"])])
	parts.append("%s_max=%.3f" % [label, float(summary["max"])])


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


func _count_live_projectiles() -> int:
	var live_count := 0
	for bullet in projectiles:
		if (
			bullet != null
			and is_instance_valid(bullet)
			and bullet.pool_active
		):
			live_count += 1
	return live_count


func _clear_projectiles() -> void:
	for bullet in projectiles:
		if bullet != null and is_instance_valid(bullet) and bullet.pool_active:
			bullet.retire()
	projectiles.clear()
	for _cleanup_frame in range(6):
		await process_frame
		await physics_frame


func _finish() -> void:
	if viewport_rid.is_valid():
		RenderingServer.viewport_set_measure_render_time(viewport_rid, false)
	current_scene = null
	if game != null:
		game.queue_free()
	for _cleanup_frame in range(10):
		await process_frame
		await physics_frame
	if failures.is_empty():
		print("GAME_TOWER_DEFENSE_PROJECTILE_RENDER_PERFORMANCE_PROBE_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
