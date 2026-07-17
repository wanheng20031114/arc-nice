extends SceneTree

# Parameterized production-scene benchmark for one enemy type or one authored
# WaveConfig mixture at a time.
#
# Examples:
#   Godot_console.exe --path . --script res://dev_tools/tower_defense_enemy_cohort_performance_probe.gd -- \
#       --enemy=res://resources/config/enemies/capoo_ak47.tres --phase=approach --enemies=300
#   Godot_console.exe --path . --script res://dev_tools/tower_defense_enemy_cohort_performance_probe.gd -- \
#       --enemy=res://resources/config/enemies/yuanshi_insect_bomber.tres --phase=burst --enemies=300
#   Godot_console.exe --path . --script res://dev_tools/tower_defense_enemy_cohort_performance_probe.gd -- \
#       --wave=res://resources/config/waves/wave_12.tres --phase=approach --enemies=300
#
# Run without --headless when render/GPU numbers matter. The probe uses the real
# tower-defense scene, authored enemy scenes, shared GridPathfinder, production
# retargeting, projectile/effect pools, camera, player collision and audio/VFX
# budgets. Timings are diagnostic; semantic/lifecycle invariants are the gates.
const TOWER_SCENE := preload("res://scene/game_tower_defense.tscn")
const TELEMETRY_SCRIPT := preload("res://scene/runtime_performance_telemetry.gd")
const CORN_CONFIG := preload(
	"res://resources/config/plant_defense/corn_machine_gun.tres"
)
const AGAVE_CONFIG := preload(
	"res://resources/config/plant_defense/agave_cannon.tres"
)

const DEFAULT_ENEMY_CONFIG_PATH := (
	"res://resources/config/enemies/yuanshi_insect_basic.tres"
)
const DEFAULT_ENEMY_COUNT := 300
const DEFAULT_WARMUP_FRAMES := 60
const DEFAULT_SAMPLE_FRAMES := 240
const DEFAULT_FIXED_SEED := 20260717
const LINGLAN_BOSS_CONFIG_PATH := (
	"res://resources/config/bosses/boss_01_linglan.tres"
)
const ENEMY_HIT_EFFECT_POOL_PATH := "res://scene/enemy/enemy_hit_effect.tscn"
const FIXTURE_CENTER := Vector2(512.0, 352.0)
const PLAYER_PROBE_HEALTH := 1_000_000_000
const ENEMY_PROBE_HEALTH := 1_000_000_000
const BASE_PROBE_HEALTH := 1_000_000_000
const PLANT_PROBE_HEALTH := 1_000_000_000
const MOVEMENT_SWITCH_PHYSICS_FRAMES := 75
const COUNT_SAMPLE_INTERVAL_FRAMES := 15
const CLEANUP_FRAMES := 10
const FRAME_BUDGET_60_FPS_MS := 1000.0 / 60.0
const FRAME_BUDGET_30_FPS_MS := 1000.0 / 30.0

enum ProbePhase {
	APPROACH,
	ENGAGEMENT,
	BURST,
	BOSS,
}

var failures: Array[String] = []
var game: GameTowerDefense = null
var pathfinder: GridPathfinder = null
var telemetry: RuntimePerformanceTelemetry = null
var enemy_config: EnemyConfig = null
var wave_config: WaveConfig = null
var active_boss_config: BossConfig = null
var cohort_configs: Array[EnemyConfig] = []
var enemies: Array[Enemy] = []
var corn_towers: Array[CornMachineGun] = []
var agave_towers: Array[AgaveCannon] = []
var forbidden_enemy_cells: Dictionary[Vector2i, bool] = {}
var viewport_rid := RID()

var enemy_config_path := DEFAULT_ENEMY_CONFIG_PATH
var wave_config_path := ""
var phase := ProbePhase.APPROACH
var requested_enemy_count := DEFAULT_ENEMY_COUNT
var warmup_frames := DEFAULT_WARMUP_FRAMES
var sample_frames := DEFAULT_SAMPLE_FRAMES
var fixed_seed := DEFAULT_FIXED_SEED
var requested_corn_count := 0
var requested_agave_count := 0
var requested_max_fps := 60
var original_max_fps := 0
var original_vsync_mode := DisplayServer.VSYNC_ENABLED
var vsync_overridden := false
var movement_start_physics_frame := 0
var movement_direction := 0


func _init() -> void:
	_parse_user_arguments()
	call_deferred("_run")


func _parse_user_arguments() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--enemy="):
			enemy_config_path = argument.get_slice("=", 1)
		elif argument.begins_with("--wave="):
			wave_config_path = argument.get_slice("=", 1)
		elif argument.begins_with("--phase="):
			phase = _parse_phase(argument.get_slice("=", 1))
		elif argument.begins_with("--enemies="):
			requested_enemy_count = maxi(int(argument.get_slice("=", 1)), 1)
		elif argument.begins_with("--warmup="):
			warmup_frames = maxi(int(argument.get_slice("=", 1)), 0)
		elif argument.begins_with("--samples="):
			sample_frames = maxi(int(argument.get_slice("=", 1)), 30)
		elif argument.begins_with("--seed="):
			fixed_seed = int(argument.get_slice("=", 1))
		elif argument.begins_with("--corn="):
			requested_corn_count = maxi(int(argument.get_slice("=", 1)), 0)
		elif argument.begins_with("--agave="):
			requested_agave_count = maxi(int(argument.get_slice("=", 1)), 0)
		elif argument.begins_with("--max-fps="):
			requested_max_fps = maxi(int(argument.get_slice("=", 1)), 0)

	if phase == ProbePhase.BURST:
		# The first frames are the workload for self-destruct enemies. Warming
		# them first would leave an empty cohort and produce a false cheap result.
		warmup_frames = 0


func _parse_phase(value: String) -> ProbePhase:
	match value.to_lower():
		"approach":
			return ProbePhase.APPROACH
		"engagement":
			return ProbePhase.ENGAGEMENT
		"burst":
			return ProbePhase.BURST
		"boss":
			return ProbePhase.BOSS
		_:
			failures.append("Unknown cohort phase: %s" % value)
			return ProbePhase.APPROACH


func _run() -> void:
	original_max_fps = Engine.max_fps
	Engine.max_fps = requested_max_fps
	if requested_max_fps == 0:
		original_vsync_mode = DisplayServer.window_get_vsync_mode()
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		vsync_overridden = true
	seed(fixed_seed)

	if wave_config_path.is_empty():
		enemy_config = load(enemy_config_path) as EnemyConfig
		_expect(enemy_config != null, "Enemy cohort config must load as EnemyConfig.")
		_expect(
			enemy_config != null and enemy_config.enemy_scene != null,
			"Enemy cohort config must provide an enemy_scene."
		)
		if enemy_config != null:
			for _enemy_index in range(requested_enemy_count):
				cohort_configs.append(enemy_config)
	else:
		wave_config = load(wave_config_path) as WaveConfig
		_expect(wave_config != null, "Mixed cohort wave must load as WaveConfig.")
		if wave_config != null:
			cohort_configs = _build_scaled_wave_configs(wave_config)
	_expect(
		cohort_configs.size() == requested_enemy_count,
		"Cohort source must resolve exactly the requested enemy count."
	)
	if cohort_configs.size() != requested_enemy_count:
		await _finish()
		return

	game = TOWER_SCENE.instantiate() as GameTowerDefense
	_expect(game != null, "Enemy cohort probe must instantiate GameTowerDefense.")
	if game == null:
		await _finish()
		return
	game.auto_start_waves = false
	game.random_generator.seed = fixed_seed
	root.add_child(game)
	current_scene = game
	await process_frame
	await physics_frame

	pathfinder = game.grid_pathfinder as GridPathfinder
	_expect(pathfinder != null and pathfinder.is_built, "Production GridPathfinder must be built.")
	_expect(game.player != null, "Enemy cohort probe requires the real local player.")
	if pathfinder == null or not pathfinder.is_built or game.player == null:
		await _finish()
		return

	telemetry = TELEMETRY_SCRIPT.new() as RuntimePerformanceTelemetry
	root.add_child(telemetry)
	viewport_rid = game.get_viewport().get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(viewport_rid, true)
	_prepare_runtime()

	var tower_setup_started_usec := Time.get_ticks_usec()
	_spawn_tower_fixture()
	var tower_setup_ms := float(
		Time.get_ticks_usec() - tower_setup_started_usec
	) / 1000.0
	_expect(
		corn_towers.size() == requested_corn_count
		and agave_towers.size() == requested_agave_count,
		"The complete requested production tower fixture must instantiate."
	)
	if (
		corn_towers.size() != requested_corn_count
		or agave_towers.size() != requested_agave_count
	):
		await _finish()
		return

	var setup_started_usec := Time.get_ticks_usec()
	await _spawn_cohort()
	var setup_ms := float(Time.get_ticks_usec() - setup_started_usec) / 1000.0
	_expect(
		enemies.size() == requested_enemy_count,
		"The complete requested enemy cohort must instantiate."
	)
	if enemies.size() != requested_enemy_count:
		await _finish()
		return
	_stagger_tower_attack_timers()

	print(
		(
			"TOWER_DEFENSE_ENEMY_COHORT_FIXTURE source=%s display_name=%s "
			+ "phase=%s enemies=%d corn=%d agave=%d warmup=%d samples=%d "
			+ "setup_ms=%.3f tower_setup_ms=%.3f "
			+ "seed=%d max_fps=%d physics_hz=%d renderer=%s driver=%s gpu=%s"
		)
		% [
			_get_cohort_source_path(),
			_get_cohort_display_name(),
			_phase_name(),
			enemies.size(),
			corn_towers.size(),
			agave_towers.size(),
			warmup_frames,
			sample_frames,
			setup_ms,
			tower_setup_ms,
			fixed_seed,
			Engine.max_fps,
			Engine.physics_ticks_per_second,
			RenderingServer.get_current_rendering_method(),
			RenderingServer.get_current_rendering_driver_name(),
			RenderingServer.get_video_adapter_name(),
		]
	)

	for _warmup_index in range(warmup_frames):
		await process_frame
		_drive_player_movement()

	var result := await _measure_sample_window(setup_ms, tower_setup_ms)
	print("TOWER_DEFENSE_ENEMY_COHORT_RESULT %s" % JSON.stringify(result))
	await _finish()


func _prepare_runtime() -> void:
	game.enemy_spawn_timer.stop()
	game.state_timer.stop()
	game.maximum_base_health = BASE_PROBE_HEALTH
	game.current_base_health = BASE_PROBE_HEALTH
	game.player.global_position = FIXTURE_CENTER
	game.player.velocity = Vector2.ZERO
	game.player.controls_locked = false
	game.player.uses_local_input = true
	# Player.apply_damage() refreshes collectible-derived stats after a hit. Keep
	# the underlying probe health in sync so a long boss cycle cannot silently
	# switch the fixture back to the authored low health and enter respawn flow.
	game.player.set("_base_max_health", PLAYER_PROBE_HEALTH)
	game.player.max_health = PLAYER_PROBE_HEALTH
	game.player.current_health = PLAYER_PROBE_HEALTH
	game.player.is_dead = false
	game.player.reset_physics_interpolation()
	if phase == ProbePhase.BOSS:
		# Tower-defense currently ships with Linglan disabled, but its campaign
		# resource and production arena hooks remain present. Enable those exact
		# hooks for the explicit per-enemy probe; otherwise target cells are
		# interpreted against the full map and the synthetic boss can appear to
		# stall while moving to a non-arena coordinate.
		active_boss_config = load(LINGLAN_BOSS_CONFIG_PATH) as BossConfig
		_expect(active_boss_config != null, "Linglan BossConfig must load.")
		if active_boss_config != null:
			game.linglan_boss_enabled = true
			game.active_boss_config = active_boss_config
			game.call("_prepare_linglan_boss_arena", active_boss_config)
			var arena_center := game.call(
				"_get_boss_arena_center",
				active_boss_config
			) as Vector2
			game.player.global_position = arena_center + Vector2(120.0, 80.0)
			game.player.reset_physics_interpolation()
	if game.map_camera != null:
		game.map_camera.position = Vector2.ZERO
		game.map_camera.position_smoothing_enabled = false
		game.map_camera.enabled = true
		game.map_camera.reset_physics_interpolation()
	if phase == ProbePhase.ENGAGEMENT or phase == ProbePhase.BURST:
		# These phases isolate authored attack/projectile behavior. Production
		# retargeting is covered by APPROACH; leaving it on here would replace the
		# forced nearby player objective with a distant gate for part of the cohort.
		game.set_physics_process(false)
		if phase == ProbePhase.BURST:
			game.player.controls_locked = true
			game.player.uses_local_input = false
			_release_movement_input()
	elif phase == ProbePhase.BOSS:
		game.wave_state = GameTowerDefense.WaveState.BOSS_ACTIVE
	movement_start_physics_frame = Engine.get_physics_frames()
	movement_direction = 0
	if phase != ProbePhase.BURST:
		_set_movement_direction(1)


func _build_scaled_wave_configs(source_wave: WaveConfig) -> Array[EnemyConfig]:
	var configs: Array[EnemyConfig] = []
	if source_wave == null:
		return configs

	var total_weight := 0
	var first_valid_config: EnemyConfig = null
	for entry in source_wave.enemy_entries:
		if entry == null or entry.enemy_config == null or entry.count <= 0:
			continue
		if first_valid_config == null:
			first_valid_config = entry.enemy_config
		total_weight += entry.count
	if total_weight <= 0 or first_valid_config == null:
		_expect(false, "Mixed cohort wave must contain at least one enemy entry.")
		return configs

	# Cumulative rounding keeps the authored proportions while guaranteeing the
	# requested active count, including waves whose authored total is 1200.
	var cumulative_exact := 0.0
	var assigned_count := 0
	for entry in source_wave.enemy_entries:
		if entry == null or entry.enemy_config == null or entry.count <= 0:
			continue
		cumulative_exact += (
			float(entry.count) * float(requested_enemy_count) / float(total_weight)
		)
		var cumulative_target := mini(
			roundi(cumulative_exact),
			requested_enemy_count
		)
		var scaled_count := maxi(cumulative_target - assigned_count, 0)
		for _scaled_index in range(scaled_count):
			configs.append(entry.enemy_config)
		assigned_count += scaled_count

	while configs.size() < requested_enemy_count:
		configs.append(first_valid_config)
	if configs.size() > requested_enemy_count:
		configs.resize(requested_enemy_count)

	var shuffle_rng := RandomNumberGenerator.new()
	shuffle_rng.seed = fixed_seed + source_wave.resource_path.hash()
	for source_index in range(configs.size() - 1, 0, -1):
		var target_index := shuffle_rng.randi_range(0, source_index)
		var temporary := configs[source_index]
		configs[source_index] = configs[target_index]
		configs[target_index] = temporary
	return configs


func _get_cohort_source_path() -> String:
	return wave_config_path if wave_config != null else enemy_config_path


func _get_cohort_display_name() -> String:
	if wave_config != null:
		return wave_config.get_flow_display_name()
	return enemy_config.display_name if enemy_config != null else ""


func _get_cohort_composition() -> Dictionary:
	var composition := {}
	for config in cohort_configs:
		if config == null:
			continue
		var path := config.resource_path
		if path.is_empty():
			path = config.display_name
		if not composition.has(path):
			composition[path] = {
				"display_name": config.display_name,
				"count": 0,
			}
		var entry := composition[path] as Dictionary
		entry["count"] = int(entry["count"]) + 1
	return composition


func _spawn_tower_fixture() -> void:
	var total_tower_count := requested_corn_count + requested_agave_count
	if total_tower_count <= 0:
		return
	var positions := _build_tower_positions(total_tower_count)
	_expect(
		positions.size() >= total_tower_count,
		"The production map must provide every requested tower cell."
	)
	if positions.size() < total_tower_count:
		return

	var empty_footprint: Array[Vector2i] = []
	for tower_index in range(total_tower_count):
		var tower_position := positions[tower_index]
		var tower_cell := pathfinder.call("_global_to_map", tower_position) as Vector2i
		for y_offset in range(-1, 2):
			for x_offset in range(-1, 2):
				forbidden_enemy_cells[tower_cell + Vector2i(x_offset, y_offset)] = true

		if tower_index < requested_corn_count:
			var corn := CORN_CONFIG.plant_scene.instantiate() as CornMachineGun
			if corn == null:
				continue
			game.plant_container.add_child(corn)
			corn.global_position = tower_position
			corn.set_meta(&"net_id", tower_index + 1)
			corn.setup(
				CORN_CONFIG,
				game.player,
				empty_footprint,
				false,
				PLANT_PROBE_HEALTH,
				0,
				PLANT_PROBE_HEALTH,
				false
			)
			corn.set_idle_aim_random_seed(fixed_seed + tower_index)
			corn_towers.append(corn)
			continue

		var agave := AGAVE_CONFIG.plant_scene.instantiate() as AgaveCannon
		if agave == null:
			continue
		game.plant_container.add_child(agave)
		agave.global_position = tower_position
		agave.set_meta(&"net_id", tower_index + 1)
		agave.setup(
			AGAVE_CONFIG,
			game.player,
			empty_footprint,
			false,
			PLANT_PROBE_HEALTH,
			0,
			PLANT_PROBE_HEALTH,
			false
		)
		agave.set_idle_aim_random_seed(fixed_seed + tower_index)
		agave_towers.append(agave)


func _build_tower_positions(total_tower_count: int) -> PackedVector2Array:
	var result := PackedVector2Array()
	var used_cells: Dictionary[Vector2i, bool] = {}
	var center_cell := pathfinder.call("_global_to_map", FIXTURE_CENTER) as Vector2i
	for y_offset in [-8, -6, -4, 4, 6, 8]:
		for x_offset in range(-15, 16, 2):
			_append_tower_cell(
				center_cell + Vector2i(x_offset, y_offset),
				used_cells,
				result
			)
			if result.size() >= total_tower_count:
				return result

	for y_offset in range(-10, 11):
		if absi(y_offset) < 3:
			continue
		for x_offset in range(-18, 19):
			_append_tower_cell(
				center_cell + Vector2i(x_offset, y_offset),
				used_cells,
				result
			)
			if result.size() >= total_tower_count:
				return result
	return result


func _append_tower_cell(
	cell: Vector2i,
	used_cells: Dictionary[Vector2i, bool],
	result: PackedVector2Array
) -> void:
	if used_cells.has(cell):
		return
	if not pathfinder.astar_grid.is_in_boundsv(cell):
		return
	if pathfinder.astar_grid.is_point_solid(cell):
		return
	used_cells[cell] = true
	result.append(pathfinder.call("_map_to_global", cell) as Vector2)


func _stagger_tower_attack_timers() -> void:
	# A player constructs towers over many different frames. Instantiating the
	# fixture in one loop would make every Timer expire together and turn the
	# normal-play phase into the separately measured synchronization worst case.
	for tower_index in range(corn_towers.size()):
		var tower := corn_towers[tower_index]
		var authored_interval := CORN_CONFIG.get_attack_interval()
		var initial_delay := 0.05 + fposmod(
			float(tower_index) * 0.61803398875 * authored_interval,
			maxf(authored_interval - 0.05, 0.05)
		)
		tower.attack_timer.start(initial_delay)
		tower.attack_timer.wait_time = authored_interval
	for tower_index in range(agave_towers.size()):
		var tower := agave_towers[tower_index]
		var authored_interval := AGAVE_CONFIG.get_attack_interval()
		var initial_delay := 0.08 + fposmod(
			float(tower_index) * 0.61803398875 * authored_interval,
			maxf(authored_interval - 0.08, 0.08)
		)
		tower.attack_timer.start(initial_delay)
		tower.attack_timer.wait_time = authored_interval


func _spawn_cohort() -> void:
	var positions := _build_candidate_positions()
	_expect(
		positions.size() >= requested_enemy_count
		or (phase == ProbePhase.BURST and not positions.is_empty()),
		"The production map must provide enough deterministic walkable cohort cells."
	)
	if (
		positions.is_empty()
		or (positions.size() < requested_enemy_count and phase != ProbePhase.BURST)
	):
		return

	for enemy_index in range(requested_enemy_count):
		var current_enemy_config := cohort_configs[enemy_index]
		if current_enemy_config == null or current_enemy_config.enemy_scene == null:
			_expect(false, "Every cohort entry must provide an enemy scene.")
			continue
		var enemy := current_enemy_config.enemy_scene.instantiate() as Enemy
		if enemy == null:
			continue
		var is_boss := enemy is LinglanBoss
		var container: Node = game.boss_container if is_boss else game.enemy_container
		container.add_child(enemy)
		var position_index := enemy_index % positions.size()
		var stacked_row := int(enemy_index / positions.size())
		var stacked_offset := Vector2(
			float(stacked_row % 3) * 2.0,
			float(int(stacked_row / 3) % 3) * 2.0
		)
		enemy.global_position = positions[position_index] + stacked_offset
		enemy.setup(current_enemy_config, game.player, pathfinder)
		enemy.current_health = ENEMY_PROBE_HEALTH if not is_boss else enemy.current_health
		enemy.set_near_moving_target_direct_distance(
			GameTowerDefense.PLAYER_OBJECTIVE_AGGRO_RADIUS
		)
		if phase != ProbePhase.APPROACH:
			enemy.set_target_player(game.player)
			enemy.set_objective_target(game.player)
		else:
			game.call("_assign_enemy_targets", enemy, enemy.global_position)
		game.call("_configure_authoritative_enemy_physics_interpolation", enemy)
		enemy.material_drop_random_generator.seed = fixed_seed + enemy_index * 2 + 1
		if is_boss:
			(enemy as LinglanBoss).activate_boss(game.player, pathfinder)
		enemy.velocity = Vector2.ZERO
		enemy.set_physics_process(false)
		enemy.reset_physics_interpolation()
		enemies.append(enemy)

	var prewarmed_profiles: Dictionary[String, bool] = {}
	for enemy in enemies:
		if enemy == null or enemy.config == null:
			continue
		var half_extents := enemy.get_configured_body_collision_half_extents()
		var traversal_types := enemy.config.terrain_traversal_types
		var profile_key := "%s|%s" % [half_extents, traversal_types]
		if prewarmed_profiles.has(profile_key):
			continue
		prewarmed_profiles[profile_key] = true
		pathfinder.prewarm_agent_grid(half_extents, traversal_types)
	for enemy in enemies:
		enemy.set_physics_process(true)
		enemy.reset_physics_interpolation()

	for _settle_index in range(3):
		await process_frame
		await physics_frame


func _build_candidate_positions() -> PackedVector2Array:
	var candidates := PackedVector2Array()
	if phase == ProbePhase.BOSS and active_boss_config != null:
		candidates.append(game.call(
			"_get_boss_arena_center",
			active_boss_config
		) as Vector2)
		return candidates
	var center_cell := pathfinder.call("_global_to_map", FIXTURE_CENTER) as Vector2i
	var minimum_distance := 24.0
	var maximum_distance := 176.0
	var half_width := 20
	var half_height := 14
	if phase == ProbePhase.APPROACH:
		minimum_distance = 128.0
		maximum_distance = 420.0
		half_width = 26
		half_height = 18
	elif phase == ProbePhase.BURST:
		# Intentionally dense: converging enemies do not collide with one
		# another in the authored layer setup, so many can die inside the same
		# explosion radius during real play. Reusing this small cell set exposes
		# the complete-shape-query and death-presentation worst case.
		minimum_distance = 0.0
		maximum_distance = 32.0
		half_width = 3
		half_height = 3
	elif phase == ProbePhase.BOSS:
		minimum_distance = 96.0
		maximum_distance = 320.0
		half_width = 20
		half_height = 14

	for y_offset in range(-half_height, half_height + 1):
		for x_offset in range(-half_width, half_width + 1):
			var cell := center_cell + Vector2i(x_offset, y_offset)
			if forbidden_enemy_cells.has(cell):
				continue
			if not pathfinder.astar_grid.is_in_boundsv(cell):
				continue
			if pathfinder.astar_grid.is_point_solid(cell):
				continue
			var world_position := pathfinder.call("_map_to_global", cell) as Vector2
			var distance := world_position.distance_to(FIXTURE_CENTER)
			if distance < minimum_distance or distance > maximum_distance:
				continue
			candidates.append(world_position)

	var shuffle_rng := RandomNumberGenerator.new()
	shuffle_rng.seed = fixed_seed + int(phase) * 1009
	for source_index in range(candidates.size() - 1, 0, -1):
		var target_index := shuffle_rng.randi_range(0, source_index)
		var temporary := candidates[source_index]
		candidates[source_index] = candidates[target_index]
		candidates[target_index] = temporary
	return candidates


func _measure_sample_window(setup_ms: float, tower_setup_ms: float) -> Dictionary:
	Enemy.reset_performance_metrics()
	Enemy.performance_metrics_enabled = true
	telemetry.reset()
	var corn_locks_before := _get_corn_target_lock_count()
	var corn_rays_before := _get_corn_hitscan_ray_count()
	var pool_before := _aggregate_pool_metrics()
	var pool_buckets_before := _get_pool_bucket_metrics()
	var player_health_before := game.player.current_health
	var base_health_before := game.current_base_health
	var alive_start := _count_alive_enemies()
	var minimum_alive := alive_start
	var peak_projectiles := 0
	var boss_phase_observations := {}
	var boss_peak_counters := {}
	var burst_trigger_ms := 0.0
	if phase == ProbePhase.BURST:
		game.player.invincibility_time_left = 0.0
		var burst_started_usec := Time.get_ticks_usec()
		for enemy in enemies:
			if enemy != null and is_instance_valid(enemy) and not enemy.is_dead:
				enemy.call("_die")
		burst_trigger_ms = float(Time.get_ticks_usec() - burst_started_usec) / 1000.0

	var wall_samples: Array[float] = []
	var process_samples: Array[float] = []
	var physics_samples: Array[float] = []
	var frame_setup_samples: Array[float] = []
	var render_cpu_samples: Array[float] = []
	var render_gpu_samples: Array[float] = []
	var draw_call_samples: Array[float] = []
	var render_object_samples: Array[float] = []
	var collision_pair_samples: Array[float] = []
	var physics_active_samples: Array[float] = []
	var node_count_samples: Array[float] = []
	var static_memory_mib_samples: Array[float] = []
	var frame_diagnostics: Array[Dictionary] = []
	var previous_corn_locks := _get_corn_target_lock_count()
	var previous_corn_rays := _get_corn_hitscan_ray_count()
	var previous_combat_index_size: int = (
		game.combat_target_index.enemies_by_net_id.size()
	)
	var previous_enemy_hit_effect_drops := _get_pool_dropped_count(
		ENEMY_HIT_EFFECT_POOL_PATH
	)
	var previous_tick_usec := Time.get_ticks_usec()

	for sample_index in range(sample_frames):
		await process_frame
		_drive_player_movement()
		var now_usec := Time.get_ticks_usec()
		var wall_ms := float(now_usec - previous_tick_usec) / 1000.0
		wall_samples.append(wall_ms)
		previous_tick_usec = now_usec
		process_samples.append(Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0)
		physics_samples.append(
			Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
		)
		frame_setup_samples.append(RenderingServer.get_frame_setup_time_cpu())
		render_cpu_samples.append(
			RenderingServer.viewport_get_measured_render_time_cpu(viewport_rid)
		)
		render_gpu_samples.append(
			RenderingServer.viewport_get_measured_render_time_gpu(viewport_rid)
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
		physics_active_samples.append(
			Performance.get_monitor(Performance.PHYSICS_2D_ACTIVE_OBJECTS)
		)
		node_count_samples.append(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
		static_memory_mib_samples.append(
			Performance.get_monitor(Performance.MEMORY_STATIC) / (1024.0 * 1024.0)
		)
		var current_corn_locks := _get_corn_target_lock_count()
		var current_corn_rays := _get_corn_hitscan_ray_count()
		var current_combat_index_size: int = (
			game.combat_target_index.enemies_by_net_id.size()
		)
		var current_enemy_hit_effect_drops := _get_pool_dropped_count(
			ENEMY_HIT_EFFECT_POOL_PATH
		)
		frame_diagnostics.append({
			"sample_index": sample_index,
			"wall_ms": wall_ms,
			"corn_locks": current_corn_locks - previous_corn_locks,
			"corn_rays": current_corn_rays - previous_corn_rays,
			"combat_index_size": current_combat_index_size,
			"combat_index_delta": (
				current_combat_index_size - previous_combat_index_size
			),
			"enemy_hit_effect_drops": (
				current_enemy_hit_effect_drops - previous_enemy_hit_effect_drops
			),
			"process_ms": process_samples.back(),
			"physics_ms": physics_samples.back(),
			"render_cpu_ms": render_cpu_samples.back(),
			"render_gpu_ms": render_gpu_samples.back(),
			"draw_calls": draw_call_samples.back(),
			"collision_pairs": collision_pair_samples.back(),
			"physics_active_objects": physics_active_samples.back(),
			"node_count": node_count_samples.back(),
		})
		previous_corn_locks = current_corn_locks
		previous_corn_rays = current_corn_rays
		previous_combat_index_size = current_combat_index_size
		previous_enemy_hit_effect_drops = current_enemy_hit_effect_drops
		_sample_boss_runtime(boss_phase_observations, boss_peak_counters)

		if sample_index % COUNT_SAMPLE_INTERVAL_FRAMES == 0:
			var counts := telemetry.sample_runtime_counts(game)
			peak_projectiles = maxi(peak_projectiles, int(counts["active_projectiles"]))
			minimum_alive = mini(minimum_alive, int(counts["active_enemies"]))

	Enemy.performance_metrics_enabled = false
	var enemy_metrics := Enemy.get_performance_metrics(true)
	var final_counts := telemetry.sample_runtime_counts(game)
	peak_projectiles = maxi(peak_projectiles, telemetry.peak_active_projectiles)
	minimum_alive = mini(minimum_alive, int(final_counts["active_enemies"]))
	var pool_after := _aggregate_pool_metrics()
	var pool_buckets_after := _get_pool_bucket_metrics()
	var wall_summary := _summarize(wall_samples)

	var result := {
		"scope": (
			"out_of_campaign_boss_diagnostic"
			if phase == ProbePhase.BOSS
			else "tower_defense_runtime"
		),
		"source_path": _get_cohort_source_path(),
		"enemy_path": enemy_config_path if wave_config == null else "",
		"wave_path": wave_config_path,
		"display_name": _get_cohort_display_name(),
		"composition": _get_cohort_composition(),
		"phase": _phase_name(),
		"requested_enemies": requested_enemy_count,
		"corn_towers": corn_towers.size(),
		"agave_towers": agave_towers.size(),
		"alive_start": alive_start,
		"alive_min": minimum_alive,
		"alive_end": int(final_counts["active_enemies"]),
		"setup_ms": setup_ms,
		"tower_setup_ms": tower_setup_ms,
		"burst_trigger_ms": burst_trigger_ms,
		"warmup_frames": warmup_frames,
		"sample_frames": sample_frames,
		"frame_budget": {
			"over_16_667_count": _count_over_budget(wall_samples, FRAME_BUDGET_60_FPS_MS),
			"over_16_667_ratio": _ratio_over_budget(wall_samples, FRAME_BUDGET_60_FPS_MS),
			# Exact 16.667 ms is intentionally retained, but a paced 60 Hz
			# Windows run naturally jitters around it. The 18 ms ratio is the
			# practical missed-refresh indicator; p95/p99 remain the main signal.
			"over_18_count": _count_over_budget(wall_samples, 18.0),
			"over_18_ratio": _ratio_over_budget(wall_samples, 18.0),
			"over_33_333_count": _count_over_budget(wall_samples, FRAME_BUDGET_30_FPS_MS),
			"over_33_333_ratio": _ratio_over_budget(wall_samples, FRAME_BUDGET_30_FPS_MS),
		},
		"slowest_frames": _get_slowest_frame_diagnostics(frame_diagnostics, 8),
		"wall_ms": wall_summary,
		"process_ms": _summarize(process_samples),
		"physics_ms": _summarize(physics_samples),
		"frame_setup_ms": _summarize(frame_setup_samples),
		"render_cpu_ms": _summarize(render_cpu_samples),
		"render_gpu_ms": _summarize(render_gpu_samples),
		"draw_calls": _summarize(draw_call_samples),
		"render_objects": _summarize(render_object_samples),
		"collision_pairs": _summarize(collision_pair_samples),
		"physics_active_objects": _summarize(physics_active_samples),
		"node_count": _summarize(node_count_samples),
		"static_memory_mib": _summarize(static_memory_mib_samples),
		"player_damage": maxi(player_health_before - game.player.current_health, 0),
		"base_damage": maxi(base_health_before - game.current_base_health, 0),
		"peak_projectiles": peak_projectiles,
		"corn_target_locks": _get_corn_target_lock_count() - corn_locks_before,
		"corn_hitscan_rays": _get_corn_hitscan_ray_count() - corn_rays_before,
		"boss_phase_observations": boss_phase_observations,
		"boss_peak_counters": boss_peak_counters,
		"boss_runtime_state": _get_boss_runtime_state(),
		"enemy_hot_segments": _format_enemy_hot_segments(enemy_metrics),
		"pool_before": pool_before,
		"pool_after": pool_after,
		"pool_delta": _subtract_pool_metrics(pool_after, pool_before),
		"pool_bucket_changes": _diff_pool_bucket_metrics(
			pool_buckets_before,
			pool_buckets_after
		),
		"combat_index_size": game.combat_target_index.enemies_by_net_id.size(),
		"renderer": RenderingServer.get_current_rendering_method(),
		"render_driver": RenderingServer.get_current_rendering_driver_name(),
		"gpu": RenderingServer.get_video_adapter_name(),
	}

	_expect(wall_samples.size() == sample_frames, "Every requested frame sample must be recorded.")
	_expect(
		_count_alive_towers() == corn_towers.size() + agave_towers.size(),
		"Every requested production tower must survive the measured window."
	)
	_expect(
		int(result["combat_index_size"]) >= int(final_counts["active_enemies"]),
		"CombatTargetIndex must retain every live cohort enemy."
	)
	if DisplayServer.get_name() != "headless":
		_expect(
			float((result["render_cpu_ms"] as Dictionary)["p50"]) > 0.0,
			"A real-window cohort run must expose render CPU timing."
		)
		_expect(
			float((result["render_gpu_ms"] as Dictionary)["p50"]) > 0.0,
			"A real-window cohort run must expose GPU timing."
		)
	return result


func _sample_boss_runtime(
	phase_observations: Dictionary,
	peak_counters: Dictionary
) -> void:
	var current_counter_totals := {
		"opening_skill_order_index": 0,
		"skill2_shots_fired": 0,
		"skill3_shots_fired": 0,
		"skill4_orb_spawn_ticks_completed": 0,
	}
	for enemy in enemies:
		var boss := enemy as LinglanBoss
		if boss == null or not is_instance_valid(boss):
			continue
		var phase_name := str(
			LinglanBoss.BossSkillPhase.keys()[int(boss.boss_skill_phase)]
		)
		phase_observations[phase_name] = int(phase_observations.get(phase_name, 0)) + 1
		current_counter_totals["opening_skill_order_index"] = (
			int(current_counter_totals["opening_skill_order_index"])
			+ boss.opening_skill_order_index
		)
		current_counter_totals["skill2_shots_fired"] = (
			int(current_counter_totals["skill2_shots_fired"])
			+ boss.skill2_shots_fired
		)
		current_counter_totals["skill3_shots_fired"] = (
			int(current_counter_totals["skill3_shots_fired"])
			+ boss.skill3_shots_fired
		)
		current_counter_totals["skill4_orb_spawn_ticks_completed"] = (
			int(current_counter_totals["skill4_orb_spawn_ticks_completed"])
			+ boss.skill4_orb_spawn_ticks_completed
		)
	for counter_name in current_counter_totals:
		peak_counters[counter_name] = maxi(
			int(peak_counters.get(counter_name, 0)),
			int(current_counter_totals[counter_name])
		)


func _get_boss_runtime_state() -> Array[Dictionary]:
	var states: Array[Dictionary] = []
	for enemy in enemies:
		var boss := enemy as LinglanBoss
		if boss == null or not is_instance_valid(boss):
			continue
		var slide_colliders: Array[String] = []
		for collision_index in range(boss.get_slide_collision_count()):
			var collision := boss.get_slide_collision(collision_index)
			var collider := collision.get_collider() as Node
			if collider == null:
				slide_colliders.append("<non-node>")
			else:
				slide_colliders.append("%s:%s" % [collider.name, collider.get_class()])
		states.append({
			"position": boss.global_position,
			"velocity": boss.velocity,
			"phase": str(
				LinglanBoss.BossSkillPhase.keys()[int(boss.boss_skill_phase)]
			),
			"skill2_target": boss.skill2_target_global_position,
			"skill2_distance": boss.global_position.distance_to(
				boss.skill2_target_global_position
			),
			"skill3_target": boss.skill3_target_global_position,
			"skill3_distance": boss.global_position.distance_to(
				boss.skill3_target_global_position
			),
			"skill4_target": boss.skill4_target_global_position,
			"skill4_distance": boss.global_position.distance_to(
				boss.skill4_target_global_position
			),
			"player_position": game.player.global_position,
			"has_player_contact": bool(boss.call("_has_player_contact")),
			"slide_collision_count": boss.get_slide_collision_count(),
			"slide_colliders": slide_colliders,
		})
	return states


func _format_enemy_hot_segments(metrics: Dictionary) -> Dictionary:
	var result := {}
	for prefix in [
		"touch_damage",
		"navigation",
		"navigation_lookahead",
		"test_move",
		"move_and_slide",
		"status_process",
	]:
		var calls := int(metrics.get(prefix + "_calls", 0))
		var usec := int(metrics.get(prefix + "_usec", 0))
		result[prefix] = {
			"calls": calls,
			"total_ms": float(usec) / 1000.0,
			"per_sample_frame_ms": float(usec) / 1000.0 / float(maxi(sample_frames, 1)),
			"per_call_usec": float(usec) / float(maxi(calls, 1)),
		}
	result["verified_direct_move_calls"] = int(
		metrics.get("verified_direct_move_calls", 0)
	)
	result["navigation_flow_prefetches"] = int(
		metrics.get("navigation_flow_prefetches", 0)
	)
	result["navigation_flow_prefetch_deduplicated"] = int(
		metrics.get("navigation_flow_prefetch_deduplicated", 0)
	)
	return result


func _aggregate_pool_metrics() -> Dictionary:
	var aggregate := {
		"created": 0,
		"in_use": 0,
		"peak_in_use": 0,
		"overflow": 0,
		"dropped": 0,
		"pending_release": 0,
	}
	if game == null or game.session_object_pool == null:
		return aggregate
	var all_metrics := game.session_object_pool.get_all_metrics()
	for metrics_variant in all_metrics.values():
		var metrics := metrics_variant as Dictionary
		for key in aggregate:
			aggregate[key] = int(aggregate[key]) + int(metrics.get(key, 0))
	return aggregate


func _subtract_pool_metrics(after: Dictionary, before: Dictionary) -> Dictionary:
	var result := {}
	for key in after:
		result[key] = int(after.get(key, 0)) - int(before.get(key, 0))
	return result


func _get_pool_bucket_metrics() -> Dictionary:
	if game == null or game.session_object_pool == null:
		return {}
	return game.session_object_pool.get_all_metrics()


func _get_pool_dropped_count(scene_path: String) -> int:
	if game == null or game.session_object_pool == null:
		return 0
	return int(game.session_object_pool.get_metrics(scene_path).get("dropped", 0))


func _diff_pool_bucket_metrics(before: Dictionary, after: Dictionary) -> Dictionary:
	var result := {}
	var paths: Dictionary[String, bool] = {}
	for path_variant in before:
		paths[str(path_variant)] = true
	for path_variant in after:
		paths[str(path_variant)] = true
	for path in paths:
		var before_metrics := before.get(path, {}) as Dictionary
		var after_metrics := after.get(path, {}) as Dictionary
		var delta := {}
		var changed := false
		for key in [
			"created",
			"in_use",
			"peak_in_use",
			"overflow",
			"dropped",
			"pending_release",
		]:
			var difference := int(after_metrics.get(key, 0)) - int(
				before_metrics.get(key, 0)
			)
			delta[key] = difference
			if difference != 0:
				changed = true
		if not changed:
			continue
		result[path] = {
			"before": before_metrics,
			"after": after_metrics,
			"delta": delta,
		}
	return result


func _count_alive_enemies() -> int:
	var count := 0
	for enemy in enemies:
		if enemy != null and is_instance_valid(enemy) and not enemy.is_dead:
			count += 1
	return count


func _count_alive_towers() -> int:
	var count := 0
	for tower in corn_towers:
		if tower != null and is_instance_valid(tower) and not tower.is_dead:
			count += 1
	for tower in agave_towers:
		if tower != null and is_instance_valid(tower) and not tower.is_dead:
			count += 1
	return count


func _get_corn_target_lock_count() -> int:
	var count := 0
	for tower in corn_towers:
		if tower != null and is_instance_valid(tower):
			count += tower.next_authoritative_action_id
	return count


func _get_corn_hitscan_ray_count() -> int:
	var count := 0
	for tower in corn_towers:
		if tower != null and is_instance_valid(tower):
			count += tower.get_hitscan_query_count()
	return count


func _drive_player_movement() -> void:
	if game == null or game.player == null:
		return
	if phase == ProbePhase.BURST:
		return
	var elapsed_frames := Engine.get_physics_frames() - movement_start_physics_frame
	var next_direction := int(elapsed_frames / MOVEMENT_SWITCH_PHYSICS_FRAMES) % 4
	if next_direction != movement_direction:
		movement_direction = next_direction
		_set_movement_direction(movement_direction)


func _set_movement_direction(direction: int) -> void:
	_release_movement_input()
	match direction:
		0:
			Input.action_press("move_right")
		1:
			Input.action_press("move_down")
		2:
			Input.action_press("move_left")
		_:
			Input.action_press("move_up")


func _release_movement_input() -> void:
	for action in [&"move_left", &"move_right", &"move_up", &"move_down"]:
		Input.action_release(action)


func _get_slowest_frame_diagnostics(
	frames: Array[Dictionary],
	maximum_count: int
) -> Array[Dictionary]:
	var sorted := frames.duplicate()
	sorted.sort_custom(_frame_diagnostic_is_slower)
	if sorted.size() > maxi(maximum_count, 0):
		sorted.resize(maxi(maximum_count, 0))
	return sorted


func _frame_diagnostic_is_slower(left: Dictionary, right: Dictionary) -> bool:
	return float(left.get("wall_ms", 0.0)) > float(right.get("wall_ms", 0.0))


func _summarize(samples: Array[float]) -> Dictionary:
	var result := {
		"sample_count": samples.size(),
		"avg": 0.0,
		"p50": 0.0,
		"p95": 0.0,
		"p99": 0.0,
		"max": 0.0,
	}
	if samples.is_empty():
		return result
	var sorted := samples.duplicate()
	sorted.sort()
	var total := 0.0
	for sample in sorted:
		total += sample
	result["avg"] = total / float(sorted.size())
	result["p50"] = _nearest_rank(sorted, 0.50)
	result["p95"] = _nearest_rank(sorted, 0.95)
	result["p99"] = _nearest_rank(sorted, 0.99)
	result["max"] = sorted.back()
	return result


func _nearest_rank(sorted: Array[float], percentile: float) -> float:
	if sorted.is_empty():
		return 0.0
	var rank := ceili(clampf(percentile, 0.0, 1.0) * sorted.size())
	return sorted[clampi(rank - 1, 0, sorted.size() - 1)]


func _count_over_budget(samples: Array[float], budget_ms: float) -> int:
	var count := 0
	for sample in samples:
		if sample > budget_ms:
			count += 1
	return count


func _ratio_over_budget(samples: Array[float], budget_ms: float) -> float:
	if samples.is_empty():
		return 0.0
	return float(_count_over_budget(samples, budget_ms)) / float(samples.size())


func _phase_name() -> String:
	return ProbePhase.keys()[int(phase)].to_lower()


func _finish() -> void:
	_release_movement_input()
	Enemy.performance_metrics_enabled = false
	Engine.max_fps = original_max_fps
	if vsync_overridden:
		DisplayServer.window_set_vsync_mode(original_vsync_mode)
	current_scene = null
	if game != null:
		game.queue_free()
	if telemetry != null:
		telemetry.queue_free()
	for _cleanup_index in range(CLEANUP_FRAMES):
		await process_frame
		await physics_frame
	if failures.is_empty():
		print("TOWER_DEFENSE_ENEMY_COHORT_PERFORMANCE_PROBE_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
