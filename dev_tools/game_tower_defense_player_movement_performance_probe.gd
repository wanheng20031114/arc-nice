extends SceneTree

# Real-window regression probe for the tower-defense follow camera. It keeps
# the same 300 frozen enemies on screen and changes only player/camera motion
# or one visual layer at a time.
const TOWER_SCENE := preload("res://scene/game_tower_defense.tscn")
const BASIC_ENEMY_CONFIG := preload(
	"res://resources/config/enemies/yuanshi_insect_basic.tres"
)
const ENEMY_COUNT := 300
const ENEMY_COLUMNS := 20
const ENEMY_SPACING := Vector2(14.0, 13.0)
const FIXTURE_CENTER := Vector2(512.0, 352.0)
const SAMPLE_FRAMES := 300
const WARMUP_FRAMES := 90
const DIRECTION_SWITCH_PHYSICS_FRAMES := 30

var failures: Array[String] = []
var game: GameTowerDefense = null
var enemies: Array[Enemy] = []
var viewport_rid := RID()
var movement_enabled := false
var movement_direction := 1
var last_movement_physics_frame := -1
var phase_results: Dictionary[String, Dictionary] = {}
var original_max_fps := 0


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	# Exercise the high-refresh mismatch that originally exposed the regression,
	# even though normal gameplay is intentionally capped at 60 FPS.
	original_max_fps = Engine.max_fps
	Engine.max_fps = 0
	game = TOWER_SCENE.instantiate() as GameTowerDefense
	_expect(game != null, "Movement probe must instantiate tower defense.")
	if game == null:
		await _finish()
		return
	game.auto_start_waves = false
	root.add_child(game)
	current_scene = game
	await process_frame
	await physics_frame

	viewport_rid = game.get_viewport().get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(viewport_rid, true)
	game.set_physics_process(false)
	_prepare_player()
	_spawn_frozen_enemies()
	for _settle_frame in range(12):
		await process_frame
		await physics_frame
	_expect(enemies.size() == ENEMY_COUNT, "Movement probe must create 300 enemies.")
	_expect(
		_count_visible_enemies() == ENEMY_COUNT,
		"All movement-probe enemies must begin inside the follow camera."
	)

	physics_interpolation = false
	await _measure_phase("stationary_interpolation_off", false)
	await _measure_phase("moving_interpolation_off", true)

	physics_interpolation = true
	game.player.reset_physics_interpolation()
	game.map_camera.reset_physics_interpolation()
	await _measure_phase("moving_interpolation_on", true)
	var off_result: Dictionary = phase_results.get("moving_interpolation_off", {})
	var on_result: Dictionary = phase_results.get("moving_interpolation_on", {})
	_expect(
		float(on_result.get("world_repeat_ratio", 1.0))
		< float(off_result.get("world_repeat_ratio", 0.0)) * 0.35,
		"Native interpolation must remove repeated whole-world render positions."
	)

	var base_dirt := game.get_node_or_null("DualGridTerrain/BaseDirtLayer") as TileMapLayer
	_expect(base_dirt != null, "Movement probe requires BaseDirtLayer.")
	if base_dirt != null:
		base_dirt.hide()
	await _measure_phase("moving_without_base_dirt", true)
	if base_dirt != null:
		base_dirt.show()

	game.enemy_container.hide()
	await _measure_phase("moving_without_enemy_visuals", true)
	game.enemy_container.show()

	_set_enemy_particle_fast_path(false)
	await _measure_phase("moving_with_legacy_idle_particle_processing", true)
	_set_enemy_particle_fast_path(true)

	await _finish()


func _prepare_player() -> void:
	_expect(game.player != null, "Movement probe requires a local player.")
	if game.player == null:
		return
	game.player.global_position = FIXTURE_CENTER
	game.player.velocity = Vector2.ZERO
	game.player.controls_locked = false
	game.player.uses_local_input = true
	if game.map_camera != null:
		game.map_camera.position = Vector2.ZERO
		game.map_camera.position_smoothing_enabled = false
		game.map_camera.enabled = true


func _spawn_frozen_enemies() -> void:
	var rows := ceili(float(ENEMY_COUNT) / float(ENEMY_COLUMNS))
	var grid_size := Vector2(
		float(ENEMY_COLUMNS - 1) * ENEMY_SPACING.x,
		float(rows - 1) * ENEMY_SPACING.y
	)
	var origin := FIXTURE_CENTER - grid_size * 0.5
	for enemy_index in range(ENEMY_COUNT):
		var enemy := BASIC_ENEMY_CONFIG.enemy_scene.instantiate() as Enemy
		if enemy == null:
			continue
		game.enemy_container.add_child(enemy)
		enemy.setup(BASIC_ENEMY_CONFIG, game.player, null)
		enemy.configure_multiplayer_proxy()
		enemy.collision_layer = 0
		enemy.collision_mask = 0
		enemy.global_position = origin + Vector2(
			float(enemy_index % ENEMY_COLUMNS) * ENEMY_SPACING.x,
			float(enemy_index / ENEMY_COLUMNS) * ENEMY_SPACING.y
		)
		enemies.append(enemy)


func _measure_phase(label: String, should_move: bool) -> void:
	await _reset_player_motion(should_move)
	for _warmup_index in range(WARMUP_FRAMES):
		await process_frame
		_drive_movement_input()

	var wall_samples: Array[float] = []
	var render_cpu_samples: Array[float] = []
	var render_gpu_samples: Array[float] = []
	var frame_setup_samples: Array[float] = []
	var canvas_draw_samples: Array[float] = []
	var canvas_object_samples: Array[float] = []
	var screen_fraction_samples: Array[float] = []
	var world_anchor_delta_samples: Array[float] = []
	var repeated_world_anchor_frames := 0
	var previous_world_anchor := _get_world_anchor_screen_position()
	var previous_tick := Time.get_ticks_usec()
	for _sample_index in range(SAMPLE_FRAMES):
		await process_frame
		_drive_movement_input()
		var now := Time.get_ticks_usec()
		wall_samples.append(float(now - previous_tick) / 1000.0)
		previous_tick = now
		render_cpu_samples.append(
			RenderingServer.viewport_get_measured_render_time_cpu(viewport_rid)
		)
		render_gpu_samples.append(
			RenderingServer.viewport_get_measured_render_time_gpu(viewport_rid)
		)
		frame_setup_samples.append(RenderingServer.get_frame_setup_time_cpu())
		canvas_draw_samples.append(
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
		if game.player != null:
			var screen_position := game.player.get_global_transform_with_canvas().origin
			screen_fraction_samples.append(
				maxf(
					absf(screen_position.x - roundf(screen_position.x)),
					absf(screen_position.y - roundf(screen_position.y))
				)
			)
		var world_anchor := _get_world_anchor_screen_position()
		var world_anchor_delta := world_anchor.distance_to(previous_world_anchor)
		world_anchor_delta_samples.append(world_anchor_delta)
		if should_move and world_anchor_delta <= 0.001:
			repeated_world_anchor_frames += 1
		previous_world_anchor = world_anchor

	_release_movement_input()
	var world_repeat_ratio := (
		float(repeated_world_anchor_frames) / float(maxi(world_anchor_delta_samples.size(), 1))
	)
	phase_results[label] = {
		"world_repeat_ratio": world_repeat_ratio,
		"world_anchor_delta": _summarize(world_anchor_delta_samples),
	}
	print(
		(
			"TOWER_DEFENSE_MOVEMENT_PROBE phase=%s moved=%s distance=%.1f "
			+ "wall=%s render_cpu=%s render_gpu=%s frame_setup=%s "
			+ "canvas_draws=%s canvas_objects=%s screen_fraction=%s "
			+ "world_delta=%s world_repeat=%.3f"
		)
		% [
			label,
			str(should_move),
			game.player.global_position.distance_to(FIXTURE_CENTER) if game.player != null else 0.0,
			_format_summary(_summarize(wall_samples)),
			_format_summary(_summarize(render_cpu_samples)),
			_format_summary(_summarize(render_gpu_samples)),
			_format_summary(_summarize(frame_setup_samples)),
			_format_summary(_summarize(canvas_draw_samples)),
			_format_summary(_summarize(canvas_object_samples)),
			_format_summary(_summarize(screen_fraction_samples)),
			_format_summary(_summarize(world_anchor_delta_samples)),
			world_repeat_ratio,
		]
	)


func _reset_player_motion(should_move: bool) -> void:
	_release_movement_input()
	movement_enabled = should_move
	movement_direction = 1
	last_movement_physics_frame = -1
	if game.player != null:
		game.player.global_position = FIXTURE_CENTER
		game.player.velocity = Vector2.ZERO
		game.player.reset_physics_interpolation()
	if game.map_camera != null:
		game.map_camera.reset_physics_interpolation()
	if should_move:
		Input.action_press(&"move_right")
	for _settle_index in range(8):
		await process_frame
		await physics_frame


func _drive_movement_input() -> void:
	if not movement_enabled:
		return
	var current_physics_frame := Engine.get_physics_frames()
	if current_physics_frame == last_movement_physics_frame:
		return
	last_movement_physics_frame = current_physics_frame
	var next_direction := (
		1
		if (current_physics_frame / DIRECTION_SWITCH_PHYSICS_FRAMES) % 2 == 0
		else -1
	)
	if next_direction == movement_direction:
		return
	movement_direction = next_direction
	Input.action_release(&"move_left")
	Input.action_release(&"move_right")
	var action := &"move_right" if movement_direction > 0 else &"move_left"
	Input.action_press(action)


func _release_movement_input() -> void:
	Input.action_release(&"move_left")
	Input.action_release(&"move_right")
	movement_enabled = false


func _set_enemy_particle_fast_path(enabled: bool) -> void:
	for enemy in enemies:
		if enemy == null or not is_instance_valid(enemy):
			continue
		var trail := enemy.get_node_or_null("MoveSpeedTrailEffect") as Node2D
		if trail != null:
			trail.process_mode = (
				Node.PROCESS_MODE_DISABLED if enabled else Node.PROCESS_MODE_INHERIT
			)


func _count_visible_enemies() -> int:
	var count := 0
	for enemy in enemies:
		if enemy != null and is_instance_valid(enemy) and enemy.is_visible_in_tree():
			count += 1
	return count


func _get_world_anchor_screen_position() -> Vector2:
	if game == null or game.dual_grid_terrain == null:
		return Vector2.ZERO
	return game.dual_grid_terrain.get_global_transform_with_canvas().origin


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
	_release_movement_input()
	Engine.max_fps = original_max_fps
	if viewport_rid.is_valid():
		RenderingServer.viewport_set_measure_render_time(viewport_rid, false)
	current_scene = null
	if game != null:
		game.queue_free()
	for _cleanup_index in range(10):
		await process_frame
		await physics_frame
	if failures.is_empty():
		print("GAME_TOWER_DEFENSE_PLAYER_MOVEMENT_PERFORMANCE_PROBE_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
