extends SceneTree

# Reproducible Physics2D isolation benchmark for the 300-enemy tower-defense
# regression. Every phase reuses the same bodies, positions, target, pathfinder
# profile and player-motion trace. The symmetric phase order limits warm-up and
# thermal bias without mixing scene loading or navigation builds into samples.
const TOWER_SCENE := preload("res://scene/game_tower_defense.tscn")
const PROBE_ENEMY_SCENE := preload(
	"res://dev_tools/physics2d_isolation_probe_enemy.tscn"
)
const BASIC_ENEMY_CONFIG := preload(
	"res://resources/config/enemies/yuanshi_insect_basic.tres"
)

const ENEMY_COUNT := 300
const FIXED_SEED := 20260716
const FIXTURE_CENTER := Vector2(512.0, 352.0)
const MINIMUM_TARGET_DISTANCE := 200.0
const MAXIMUM_TARGET_DISTANCE := 300.0
const PLAYER_MOTION_AMPLITUDE := 64.0
const PLAYER_MOTION_PERIOD_FRAMES := 120.0
# TIME_PHYSICS_PROCESS is refreshed much more coarsely than a physics tick in
# headless runs. A >1 second warm-up prevents the previous phase's monitor value
# from bleeding into the next phase, and the 3 second window captures several
# independent refreshes while keeping the full probe practical.
const WARMUP_FRAMES := 90
const SAMPLE_FRAMES := 180
const RESET_SETTLE_FRAMES := 4

enum PhaseMode {
	FULL,
	SCRIPTS_OFF_BODY_AREA_ON,
	MOVEMENT_ON_TOUCH_AREA_OFF,
	AREA_ON_VERIFIED_DIRECT,
}

const PHASE_LABELS := {
	PhaseMode.FULL: "full",
	PhaseMode.SCRIPTS_OFF_BODY_AREA_ON: "scripts_off_body_area_on",
	PhaseMode.MOVEMENT_ON_TOUCH_AREA_OFF: "movement_on_touch_area_off",
	PhaseMode.AREA_ON_VERIFIED_DIRECT: "area_on_verified_direct",
}
const SYMMETRIC_PHASE_ORDER: Array[int] = [
	PhaseMode.FULL,
	PhaseMode.SCRIPTS_OFF_BODY_AREA_ON,
	PhaseMode.MOVEMENT_ON_TOUCH_AREA_OFF,
	PhaseMode.AREA_ON_VERIFIED_DIRECT,
	PhaseMode.AREA_ON_VERIFIED_DIRECT,
	PhaseMode.MOVEMENT_ON_TOUCH_AREA_OFF,
	PhaseMode.SCRIPTS_OFF_BODY_AREA_ON,
	PhaseMode.FULL,
]

var failures: Array[String] = []
var game: GameTowerDefense = null
var pathfinder: GridPathfinder = null
var static_target: Marker2D = null
var enemies: Array[Enemy] = []
var initial_enemy_positions := PackedVector2Array()
var samples_by_mode: Dictionary = {}
var validation_by_mode: Dictionary = {}
var original_max_fps := 0
var player_motion_frame := 0
var probe_half_extents := Vector2.ZERO


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	original_max_fps = Engine.max_fps
	Engine.max_fps = 60
	seed(FIXED_SEED)
	for mode in PHASE_LABELS:
		samples_by_mode[int(mode)] = []

	game = TOWER_SCENE.instantiate() as GameTowerDefense
	_expect(game != null, "Physics2D isolation probe must instantiate tower defense.")
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
	_expect(pathfinder != null and pathfinder.is_built, "GridPathfinder must be built.")
	if pathfinder == null or not pathfinder.is_built:
		await _finish()
		return

	_stop_background_gameplay()
	_prepare_player_and_target()
	_prepare_navigation_profile()
	_spawn_probe_enemies()
	_expect(enemies.size() == ENEMY_COUNT, "Probe must create exactly 300 enemies.")
	if enemies.size() != ENEMY_COUNT:
		await _finish()
		return

	print(
		"PHYSICS2D_ISOLATION_FIXTURE enemies=%d seed=%d warmup=%d samples_per_pass=%d passes=2 physics_hz=%d"
		% [
			ENEMY_COUNT,
			FIXED_SEED,
			WARMUP_FRAMES,
			SAMPLE_FRAMES,
			Engine.physics_ticks_per_second,
		]
	)
	for mode in SYMMETRIC_PHASE_ORDER:
		await _measure_phase(mode)

	_print_final_comparison()
	await _finish()

func _stop_background_gameplay() -> void:
	game.set_process(false)
	game.set_physics_process(false)
	game.enemy_spawn_timer.stop()
	game.state_timer.stop()
	if game.plant_terrain_decay_timer != null:
		game.plant_terrain_decay_timer.stop()
	if game.player != null:
		game.player.set_process(false)
		game.player.set_physics_process(false)
	# The fixture owns the only physics callbacks that should scale with the
	# enemy count. Timers/minimap/ambient systems remain instantiated, but cannot
	# add periodic container scans to one phase and not another.
	_disable_background_processing_except_enemy_container(game)


func _disable_background_processing_except_enemy_container(node: Node) -> void:
	for child in node.get_children():
		if child == game.enemy_container:
			continue
		var timer := child as Timer
		if timer != null:
			timer.stop()
		child.set_process(false)
		child.set_physics_process(false)
		_disable_background_processing_except_enemy_container(child)


func _prepare_player_and_target() -> void:
	_expect(game.player != null, "Probe requires the authored player body.")
	if game.player == null:
		return
	game.player.global_position = FIXTURE_CENTER
	game.player.velocity = Vector2.ZERO
	game.player.max_health = 1_000_000
	game.player.current_health = 1_000_000
	game.player.is_dead = false
	game.player.reset_physics_interpolation()
	static_target = Marker2D.new()
	static_target.name = "Physics2DIsolationStaticFlowTarget"
	game.add_child(static_target)
	static_target.global_position = FIXTURE_CENTER


func _prepare_navigation_profile() -> void:
	var preview := PROBE_ENEMY_SCENE.instantiate() as Enemy
	_expect(preview != null, "Probe enemy scene must instantiate as Enemy.")
	if preview == null:
		return
	probe_half_extents = preview.get_configured_body_collision_half_extents()
	preview.free()
	_expect(probe_half_extents != Vector2.ZERO, "Probe body extents must be non-zero.")
	pathfinder.prewarm_agent_grid(
		probe_half_extents,
		DualGridTilemap.TraversalType.LAND
	)
	pathfinder.prewarm_flow_navigation_target(
		FIXTURE_CENTER,
		probe_half_extents,
		DualGridTilemap.TraversalType.LAND
	)
	pathfinder.set_process(false)


func _spawn_probe_enemies() -> void:
	var candidate_positions := _build_deterministic_connected_positions()
	_expect(
		candidate_positions.size() >= ENEMY_COUNT,
		"Map must provide 300 connected intermediate-distance probe cells; got %d."
		% candidate_positions.size()
	)
	if candidate_positions.size() < ENEMY_COUNT:
		return

	for enemy_index in range(ENEMY_COUNT):
		var enemy := PROBE_ENEMY_SCENE.instantiate() as Enemy
		_expect(enemy != null, "Every probe enemy must instantiate as Enemy.")
		if enemy == null:
			continue
		game.enemy_container.add_child(enemy)
		enemy.setup(BASIC_ENEMY_CONFIG, game.player, pathfinder)
		enemy.set_objective_target(static_target)
		enemy.global_position = candidate_positions[enemy_index]
		enemy.velocity = Vector2.ZERO
		enemy.set_physics_process(false)
		enemy.material_drop_random_generator.seed = FIXED_SEED + enemy_index * 2 + 1
		var insect := enemy as YuanshiInsect
		if insect != null:
			insect.random_generator.seed = FIXED_SEED + enemy_index * 2 + 2
		enemy.reset_physics_interpolation()
		enemies.append(enemy)
		initial_enemy_positions.append(enemy.global_position)


func _build_deterministic_connected_positions() -> PackedVector2Array:
	var path_grid := pathfinder.call(
		"_get_or_create_agent_grid",
		probe_half_extents,
		DualGridTilemap.TraversalType.LAND
	) as AStarGrid2D
	var target_cell := pathfinder.call("_global_to_map", FIXTURE_CENTER) as Vector2i
	var resolved_target_cell := pathfinder.call(
		"_get_closest_walkable_cell",
		target_cell,
		path_grid
	) as Vector2i
	# Build the one reference field directly for the fixture. This keeps candidate
	# connectivity independent of cache-key implementation details while all
	# measured phases still consume the production prewarmed cache.
	var field := pathfinder.call(
		"_build_flow_field",
		resolved_target_cell,
		path_grid
	) as Dictionary
	var next_cells := field.get("next_cells", {}) as Dictionary
	var candidates := PackedVector2Array()
	for y in range(path_grid.region.position.y, path_grid.region.end.y):
		for x in range(path_grid.region.position.x, path_grid.region.end.x):
			var cell := Vector2i(x, y)
			if path_grid.is_point_solid(cell) or not next_cells.has(cell):
				continue
			var world_position := pathfinder.call("_map_to_global", cell) as Vector2
			var target_distance := world_position.distance_to(FIXTURE_CENTER)
			if (
				target_distance < MINIMUM_TARGET_DISTANCE
				or target_distance > MAXIMUM_TARGET_DISTANCE
			):
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


func _measure_phase(mode: int) -> void:
	await _configure_phase(mode)
	await _advance_distinct_physics_frames(WARMUP_FRAMES)

	var physics_samples: Array[float] = []
	var process_samples: Array[float] = []
	var collision_pair_samples: Array[float] = []
	var active_object_samples: Array[float] = []
	var last_sampled_physics_frame := Engine.get_physics_frames()
	while physics_samples.size() < SAMPLE_FRAMES:
		await process_frame
		var current_physics_frame := Engine.get_physics_frames()
		if current_physics_frame <= last_sampled_physics_frame:
			continue
		last_sampled_physics_frame = current_physics_frame
		_drive_player_motion()
		physics_samples.append(
			Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
		)
		process_samples.append(
			Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
		)
		collision_pair_samples.append(
			Performance.get_monitor(Performance.PHYSICS_2D_COLLISION_PAIRS)
		)
		active_object_samples.append(
			Performance.get_monitor(Performance.PHYSICS_2D_ACTIVE_OBJECTS)
		)

	var stored_samples := samples_by_mode[mode] as Array
	stored_samples.append_array(physics_samples)
	var summary := _summarize(physics_samples)
	print(
		"PHYSICS2D_ISOLATION_PASS mode=%s physics_ms=%s process_ms=%s pairs=%s active=%s"
		% [
			PHASE_LABELS[mode],
			_format_summary(summary),
			_format_summary(_summarize(process_samples)),
			_format_summary(_summarize(collision_pair_samples)),
			_format_summary(_summarize(active_object_samples)),
		]
	)


func _advance_distinct_physics_frames(frame_count: int) -> void:
	var observed_frame := Engine.get_physics_frames()
	var advanced_frames := 0
	while advanced_frames < frame_count:
		await process_frame
		var current_frame := Engine.get_physics_frames()
		if current_frame <= observed_frame:
			continue
		advanced_frames += current_frame - observed_frame
		observed_frame = current_frame
		_drive_player_motion()


func _configure_phase(mode: int) -> void:
	for enemy in enemies:
		enemy.set_physics_process(false)
	player_motion_frame = 0
	game.player.global_position = FIXTURE_CENTER
	game.player.velocity = Vector2.ZERO
	game.player.reset_physics_interpolation()

	var touch_area_enabled := mode != PhaseMode.MOVEMENT_ON_TOUCH_AREA_OFF
	var scripts_enabled := mode != PhaseMode.SCRIPTS_OFF_BODY_AREA_ON
	var force_direct := mode == PhaseMode.AREA_ON_VERIFIED_DIRECT
	for enemy_index in range(enemies.size()):
		var enemy := enemies[enemy_index]
		enemy.global_position = initial_enemy_positions[enemy_index]
		enemy.velocity = Vector2.ZERO
		enemy.set_pathfinder(pathfinder)
		enemy.set_target_player(game.player)
		enemy.set_objective_target(static_target)
		enemy.call("_clear_navigation_path")
		enemy.call("_clear_touching_players")
		enemy.touch_damage_cooldown_left = 0.0
		enemy.set("probe_force_verified_direct", force_direct)
		_set_touch_area_enabled(enemy, touch_area_enabled)
		for body_shape in enemy.body_collision_shapes:
			body_shape.set_deferred("disabled", false)
		enemy.reset_physics_interpolation()

	await process_frame
	await physics_frame
	for enemy in enemies:
		enemy.set_physics_process(scripts_enabled)
	for _settle_index in range(RESET_SETTLE_FRAMES):
		await physics_frame
		_drive_player_motion()
		await process_frame
	_verify_phase_contract(mode)
	await _capture_validation_metrics(mode)


func _set_touch_area_enabled(enemy: Enemy, enabled: bool) -> void:
	if enemy.touch_damage_area != null:
		enemy.touch_damage_area.set_deferred("monitoring", enabled)
		enemy.touch_damage_area.set_deferred("monitorable", enabled)
	for touch_shape in enemy.touch_damage_shapes:
		touch_shape.set_deferred("disabled", not enabled)


func _verify_phase_contract(mode: int) -> void:
	var expected_scripts := mode != PhaseMode.SCRIPTS_OFF_BODY_AREA_ON
	var expected_area := mode != PhaseMode.MOVEMENT_ON_TOUCH_AREA_OFF
	var expected_direct := mode == PhaseMode.AREA_ON_VERIFIED_DIRECT
	var moving_enemies := 0
	for enemy in enemies:
		_expect(
			enemy.is_physics_processing() == expected_scripts,
			"%s script-processing contract failed." % PHASE_LABELS[mode]
		)
		for body_shape in enemy.body_collision_shapes:
			_expect(not body_shape.disabled, "%s must retain CharacterBody shapes." % PHASE_LABELS[mode])
		if enemy.touch_damage_area != null:
			_expect(
				enemy.touch_damage_area.monitoring == expected_area
				and enemy.touch_damage_area.monitorable == expected_area,
				"%s TouchDamageArea state mismatch." % PHASE_LABELS[mode]
			)
		for touch_shape in enemy.touch_damage_shapes:
			_expect(
				touch_shape.disabled != expected_area,
				"%s TouchDamageArea shape state mismatch." % PHASE_LABELS[mode]
			)
		_expect(
			bool(enemy.get("probe_force_verified_direct")) == expected_direct,
			"%s direct-certificate switch mismatch." % PHASE_LABELS[mode]
		)
		if enemy.velocity != Vector2.ZERO:
			moving_enemies += 1
	if expected_scripts:
		_expect(
			moving_enemies >= ENEMY_COUNT * 9 / 10,
			"%s must keep at least 90%% of enemies moving; got %d."
			% [PHASE_LABELS[mode], moving_enemies]
		)


func _capture_validation_metrics(mode: int) -> void:
	Enemy.set_performance_metrics_enabled(true)
	Enemy.reset_performance_metrics()
	var starting_physics_frame := Engine.get_physics_frames()
	while Engine.get_physics_frames() <= starting_physics_frame:
		await process_frame
	_drive_player_motion()
	var metrics := Enemy.get_performance_metrics()
	Enemy.set_performance_metrics_enabled(false)
	validation_by_mode[mode] = metrics
	var scripts_enabled := mode != PhaseMode.SCRIPTS_OFF_BODY_AREA_ON
	if not scripts_enabled:
		_expect(
			int(metrics.get("navigation_calls", -1)) == 0
			and int(metrics.get("move_and_slide_calls", -1)) == 0
			and int(metrics.get("verified_direct_move_calls", -1)) == 0,
			"Stopped scripts must produce no Enemy movement metrics: %s." % [metrics]
		)
	elif mode == PhaseMode.AREA_ON_VERIFIED_DIRECT:
		var total_move_submissions := (
			int(metrics.get("verified_direct_move_calls", 0))
			+ int(metrics.get("move_and_slide_calls", 0))
		)
		_expect(
			total_move_submissions > 0
			and int(metrics.get("verified_direct_move_calls", 0)) * 100
				>= total_move_submissions * 95
			and int(metrics.get("move_and_slide_calls", 0)) * 100
				<= total_move_submissions * 5,
			(
				"Certified-direct phase must submit at least 95%% of movement directly "
				+ "and at most 5%% through move_and_slide(): %s."
			) % [metrics]
		)
	else:
		var normal_move_submissions := (
			int(metrics.get("verified_direct_move_calls", 0))
			+ int(metrics.get("move_and_slide_calls", 0))
		)
		_expect(
			normal_move_submissions >= ENEMY_COUNT * 9 / 10
			and int(metrics.get("move_and_slide_calls", 0)) > 0,
			(
				"Normal production movement must submit almost every enemy while retaining "
				+ "a collision fallback for uncertified corridors: %s."
			) % [metrics]
		)
	print("PHYSICS2D_ISOLATION_VALIDATION mode=%s metrics=%s" % [PHASE_LABELS[mode], metrics])


func _drive_player_motion() -> void:
	player_motion_frame += 1
	var phase := TAU * float(player_motion_frame) / PLAYER_MOTION_PERIOD_FRAMES
	game.player.global_position = (
		FIXTURE_CENTER + Vector2(sin(phase) * PLAYER_MOTION_AMPLITUDE, 0.0)
	)


func _print_final_comparison() -> void:
	var summaries: Dictionary = {}
	for mode in PHASE_LABELS:
		var summary := _summarize(samples_by_mode[int(mode)] as Array)
		summaries[int(mode)] = summary
		print(
			"PHYSICS2D_ISOLATION_RESULT mode=%s physics_ms=%s"
			% [PHASE_LABELS[mode], _format_summary(summary)]
		)
	var full := summaries[PhaseMode.FULL] as Dictionary
	var scripts_off := summaries[PhaseMode.SCRIPTS_OFF_BODY_AREA_ON] as Dictionary
	var touch_off := summaries[PhaseMode.MOVEMENT_ON_TOUCH_AREA_OFF] as Dictionary
	var direct := summaries[PhaseMode.AREA_ON_VERIFIED_DIRECT] as Dictionary
	var full_p50 := float(full["p50"])
	var direct_p50 := float(direct["p50"])
	var direct_saving := full_p50 - direct_p50
	var direct_ratio := direct_p50 / maxf(full_p50, 0.0001)
	var extend_flow_certificate := direct_saving >= 0.5 and direct_ratio <= 0.9
	print(
		(
			"PHYSICS2D_ISOLATION_COMPARISON full_minus_scripts_off_p50_ms=%.3f "
			+ "full_minus_touch_off_p50_ms=%.3f full_minus_direct_p50_ms=%.3f "
			+ "direct_over_full_ratio=%.3f extend_flow_direction_certificate=%s"
		)
		% [
			full_p50 - float(scripts_off["p50"]),
			full_p50 - float(touch_off["p50"]),
			direct_saving,
			direct_ratio,
			str(extend_flow_certificate),
		]
	)
	_expect(
		float(full["p50"]) > 0.0
		and float(scripts_off["p50"]) > 0.0
		and float(touch_off["p50"]) > 0.0
		and float(direct["p50"]) > 0.0,
		"Every phase must collect non-zero Physics2D timing."
	)


func _summarize(values: Array) -> Dictionary:
	if values.is_empty():
		return {"mean": 0.0, "p50": 0.0, "p95": 0.0, "p99": 0.0, "max": 0.0}
	var sorted := values.duplicate()
	sorted.sort()
	var total := 0.0
	for value in sorted:
		total += float(value)
	return {
		"mean": total / float(sorted.size()),
		"p50": _nearest_rank(sorted, 0.50),
		"p95": _nearest_rank(sorted, 0.95),
		"p99": _nearest_rank(sorted, 0.99),
		"max": float(sorted.back()),
	}


func _nearest_rank(sorted: Array, percentile: float) -> float:
	var index := clampi(ceili(float(sorted.size()) * percentile) - 1, 0, sorted.size() - 1)
	return float(sorted[index])


func _format_summary(summary: Dictionary) -> String:
	return "mean=%.3f,p50=%.3f,p95=%.3f,p99=%.3f,max=%.3f" % [
		float(summary["mean"]),
		float(summary["p50"]),
		float(summary["p95"]),
		float(summary["p99"]),
		float(summary["max"]),
	]


func _finish() -> void:
	Enemy.set_performance_metrics_enabled(false)
	Engine.max_fps = original_max_fps
	for enemy in enemies:
		if enemy != null and is_instance_valid(enemy):
			enemy.set_physics_process(false)
	if game != null and is_instance_valid(game):
		game.queue_free()
	for _cleanup_index in range(4):
		await process_frame
	if failures.is_empty():
		print("PHYSICS2D_ISOLATION_AB_PROBE_OK")
		quit(0)
	else:
		for failure in failures:
			push_error(failure)
		quit(1)


func _expect(condition: bool, message: String) -> void:
	if condition:
		return
	if not failures.has(message):
		failures.append(message)
