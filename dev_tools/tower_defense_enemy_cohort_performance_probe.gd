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
const TOWER_SCENE := preload("res://scene/game_modes/tower_defense/tower_defense_game.tscn")
const TELEMETRY_SCRIPT := preload("res://scene/runtime_performance_telemetry.gd")
const ENEMY_ATTACK_AUDIO_LIMITER := preload(
	"res://scene/enemy_attack_audio_limiter.gd"
)
const CAPOO_MAGE_FIREBALL_SCRIPT := preload(
	"res://scene/enemy/capoo/capoo_mage_fireball.gd"
)
const STONE_GOLEM_SCRIPT := preload("res://scene/enemy/artificial_creation/stone_golem.gd")
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
const SIMPLE_FENCE_NET_ID_BASE := 50_000
const SIMPLE_FENCE_GRID_COLUMNS := 50
const SIMPLE_FENCE_FAR_CELL_ORIGIN := Vector2i(1000, 1000)
const LINGLAN_SKILL_RANDOM_SEED_OFFSET := 1_000_000
const LINGLAN_SKILL_RANDOM_SEED_STRIDE := 3
const LINGLAN_BOSS_CONFIG_PATH := (
	"res://resources/config/bosses/boss_01_linglan.tres"
)
const CAPOO_AK47_BULLET_POOL_PATH := "res://scene/enemy/capoo/capoo_ak47_bullet.tscn"
const COMBAT_ROBOT_GUNNER_BULLET_POOL_PATH := (
	"res://scene/enemy/mechanical_life/combat_robot_gunner_bullet.tscn"
)
const CAPOO_MAGE_FIREBALL_POOL_PATH := "res://scene/enemy/capoo/capoo_mage_fireball.tscn"
const BULLET_HIT_EFFECT_POOL_PATH := "res://scene/bullet_hit_effect.tscn"
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
var game: TowerDefenseGame = null
var pathfinder: GridPathfinder = null
var telemetry: RuntimePerformanceTelemetry = null
var enemy_config: EnemyConfig = null
var wave_config: WaveConfig = null
var active_boss_config: BossConfig = null
var cohort_configs: Array[EnemyConfig] = []
var enemies: Array[Enemy] = []
var corn_towers: Array[CornMachineGun] = []
var agave_towers: Array[AgaveCannon] = []
var simple_fences: Array[CardinalConnectedPlant] = []
var forbidden_enemy_cells: Dictionary[Vector2i, bool] = {}
var viewport_rid := RID()
var simple_fence_fixture_metrics := {}

var enemy_config_path := DEFAULT_ENEMY_CONFIG_PATH
var wave_config_path := ""
var phase := ProbePhase.APPROACH
var requested_enemy_count := DEFAULT_ENEMY_COUNT
var requested_simple_fence_count := 0
var requested_simple_fence_ab_metrics := false
var warmup_frames := DEFAULT_WARMUP_FRAMES
var sample_frames := DEFAULT_SAMPLE_FRAMES
var fixed_seed := DEFAULT_FIXED_SEED
var requested_corn_count := 0
var requested_agave_count := 0
var requested_max_fps := 60
var requested_navigation_interval := 0
var requested_navigation_render_dedupe := true
var requested_navigation_refresh_budget := true
var requested_navigation_refresh_cap := 0
var requested_combat_sense_throttling := true
var requested_enemy_hot_metrics := false
var requested_guardian_overlap_metrics := false
var requested_guardian_unchanged_diff_fast_path := true
var requested_guardian_refresh_interval := 0.0
var requested_runtime_count_scans := false
var requested_projectile_world_certificate := false
var effective_projectile_world_certificate := false
var requested_projectile_hot_metrics := false
var requested_batched_projectile_motion := true
var requested_ak_attack_phase_stagger := true
var requested_gunner_bullet_pool_prewarm := 0
var requested_gunner_bullet_pool_retained := 96
var requested_smg_short_range_targeting := true
var requested_smg_hitscan_attack := true
var requested_disable_smg_projectiles := false
var requested_expanded_projectile_prewarm := true
var requested_enemy_attack_audio_limiter := true
var requested_pooled_mage_impact_effect := true
var original_max_fps := 0
var original_navigation_render_dedupe := true
var original_navigation_refresh_budget := true
var original_combat_sense_throttling := true
var original_guardian_unchanged_diff_fast_path := true
var original_projectile_world_certificate := true
var original_batched_projectile_motion := true
var original_ak_attack_phase_stagger := true
var original_gunner_bullet_pool_prewarm := 0
var original_gunner_bullet_pool_retained := 96
var original_smg_short_range_targeting := true
var original_smg_hitscan_attack := true
var original_expanded_projectile_prewarm := true
var original_enemy_attack_audio_limiter := true
var original_pooled_mage_impact_effect := true
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
		elif argument.begins_with("--fences="):
			requested_simple_fence_count = maxi(
				int(argument.get_slice("=", 1)),
				0
			)
		elif argument.begins_with("--fence-ab-metrics="):
			requested_simple_fence_ab_metrics = (
				argument.get_slice("=", 1).to_lower() == "true"
			)
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
		elif argument.begins_with("--navigation-interval="):
			requested_navigation_interval = maxi(int(argument.get_slice("=", 1)), 0)
		elif argument.begins_with("--navigation-render-dedupe="):
			requested_navigation_render_dedupe = (
				argument.get_slice("=", 1).to_lower() == "true"
			)
		elif argument.begins_with("--navigation-refresh-budget="):
			requested_navigation_refresh_budget = (
				argument.get_slice("=", 1).to_lower() == "true"
			)
		elif argument.begins_with("--navigation-refresh-cap="):
			requested_navigation_refresh_cap = maxi(
				int(argument.get_slice("=", 1)),
				0
			)
		elif argument.begins_with("--combat-sense-throttling="):
			requested_combat_sense_throttling = (
				argument.get_slice("=", 1).to_lower() == "true"
			)
		elif argument.begins_with("--enemy-hot-metrics="):
			requested_enemy_hot_metrics = (
				argument.get_slice("=", 1).to_lower() == "true"
			)
		elif argument.begins_with("--guardian-overlap-metrics="):
			requested_guardian_overlap_metrics = (
				argument.get_slice("=", 1).to_lower() == "true"
			)
		elif argument.begins_with("--guardian-unchanged-diff-fast-path="):
			requested_guardian_unchanged_diff_fast_path = (
				argument.get_slice("=", 1).to_lower() == "true"
			)
		elif argument.begins_with("--guardian-refresh-interval="):
			requested_guardian_refresh_interval = maxf(
				float(argument.get_slice("=", 1)),
				0.0
			)
		elif argument.begins_with("--runtime-count-scans="):
			requested_runtime_count_scans = (
				argument.get_slice("=", 1).to_lower() == "true"
			)
		elif argument.begins_with("--projectile-world-certificate="):
			requested_projectile_world_certificate = (
				argument.get_slice("=", 1).to_lower() == "true"
			)
		elif argument.begins_with("--projectile-hot-metrics="):
			requested_projectile_hot_metrics = (
				argument.get_slice("=", 1).to_lower() == "true"
			)
		elif argument.begins_with("--batched-projectile-motion="):
			requested_batched_projectile_motion = (
				argument.get_slice("=", 1).to_lower() == "true"
			)
		elif argument.begins_with("--ak-attack-phase-stagger="):
			requested_ak_attack_phase_stagger = (
				argument.get_slice("=", 1).to_lower() == "true"
			)
		elif argument.begins_with("--gunner-bullet-pool-prewarm="):
			requested_gunner_bullet_pool_prewarm = maxi(
				int(argument.get_slice("=", 1)),
				0
			)
		elif argument.begins_with("--gunner-bullet-pool-retained="):
			requested_gunner_bullet_pool_retained = maxi(
				int(argument.get_slice("=", 1)),
				1
			)
		elif argument.begins_with("--smg-short-range-targeting="):
			requested_smg_short_range_targeting = (
				argument.get_slice("=", 1).to_lower() == "true"
			)
		elif argument.begins_with("--smg-hitscan-attack="):
			requested_smg_hitscan_attack = (
				argument.get_slice("=", 1).to_lower() == "true"
			)
		elif argument.begins_with("--disable-smg-projectiles="):
			requested_disable_smg_projectiles = (
				argument.get_slice("=", 1).to_lower() == "true"
			)
		elif argument.begins_with("--expanded-projectile-prewarm="):
			requested_expanded_projectile_prewarm = (
				argument.get_slice("=", 1).to_lower() == "true"
			)
		elif argument.begins_with("--enemy-attack-audio-limiter="):
			requested_enemy_attack_audio_limiter = (
				argument.get_slice("=", 1).to_lower() == "true"
			)
		elif argument.begins_with("--pooled-mage-impact-effect="):
			requested_pooled_mage_impact_effect = (
				argument.get_slice("=", 1).to_lower() == "true"
			)

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
	original_navigation_render_dedupe = Enemy.navigation_render_frame_dedupe_enabled
	original_navigation_refresh_budget = Enemy.navigation_process_frame_budget_enabled
	original_combat_sense_throttling = Enemy.combat_sense_throttling_enabled
	original_guardian_unchanged_diff_fast_path = (
		GuardianAuraSystem.unchanged_source_diff_fast_path_enabled
	)
	original_projectile_world_certificate = (
		CapooAK47Bullet.world_collision_certificate_enabled
	)
	original_batched_projectile_motion = CapooAK47Bullet.batched_motion_enabled
	original_ak_attack_phase_stagger = CapooAK47.attack_phase_stagger_enabled
	original_gunner_bullet_pool_prewarm = (
		CombatRuntimeBase.combat_robot_gunner_bullet_pool_prewarm_count
	)
	original_gunner_bullet_pool_retained = (
		CombatRuntimeBase.combat_robot_gunner_bullet_pool_retained_capacity
	)
	original_smg_short_range_targeting = CapooSMG.short_range_targeting_enabled
	original_smg_hitscan_attack = CapooSMG.hitscan_attack_enabled
	original_expanded_projectile_prewarm = (
		TowerDefenseGame.expanded_projectile_pool_prewarm_enabled
	)
	original_enemy_attack_audio_limiter = ENEMY_ATTACK_AUDIO_LIMITER.limiting_enabled
	original_pooled_mage_impact_effect = (
		CAPOO_MAGE_FIREBALL_SCRIPT.pooled_impact_effect_enabled
	)
	Enemy.navigation_render_frame_dedupe_enabled = requested_navigation_render_dedupe
	Enemy.navigation_process_frame_budget_enabled = requested_navigation_refresh_budget
	Enemy.combat_sense_throttling_enabled = requested_combat_sense_throttling
	GuardianAuraSystem.unchanged_source_diff_fast_path_enabled = (
		requested_guardian_unchanged_diff_fast_path
	)
	# The production scene contract is checked after GridPathfinder is ready.
	# Keep the static switch disabled until both halves of the certificate agree.
	CapooAK47Bullet.world_collision_certificate_enabled = false
	CapooAK47Bullet.batched_motion_enabled = requested_batched_projectile_motion
	CapooAK47.attack_phase_stagger_enabled = requested_ak_attack_phase_stagger
	CombatRuntimeBase.combat_robot_gunner_bullet_pool_prewarm_count = (
		requested_gunner_bullet_pool_prewarm
	)
	CombatRuntimeBase.combat_robot_gunner_bullet_pool_retained_capacity = (
		requested_gunner_bullet_pool_retained
	)
	CapooSMG.short_range_targeting_enabled = requested_smg_short_range_targeting
	CapooSMG.hitscan_attack_enabled = requested_smg_hitscan_attack
	TowerDefenseGame.expanded_projectile_pool_prewarm_enabled = (
		requested_expanded_projectile_prewarm
	)
	ENEMY_ATTACK_AUDIO_LIMITER.limiting_enabled = (
		requested_enemy_attack_audio_limiter
	)
	CAPOO_MAGE_FIREBALL_SCRIPT.pooled_impact_effect_enabled = (
		requested_pooled_mage_impact_effect
	)
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
	if requested_disable_smg_projectiles:
		_disable_smg_projectiles_in_cohort()

	var runtime_setup_started_usec := Time.get_ticks_usec()
	game = TOWER_SCENE.instantiate() as TowerDefenseGame
	_expect(game != null, "Enemy cohort probe must instantiate TowerDefenseGame.")
	if game == null:
		await _finish()
		return
	game.auto_start_waves = false
	game.random_generator.seed = fixed_seed
	root.add_child(game)
	current_scene = game
	await process_frame
	await physics_frame
	var runtime_setup_ms := float(
		Time.get_ticks_usec() - runtime_setup_started_usec
	) / 1000.0
	var guardian_aura_system := game.get_node_or_null(
		"GuardianAuraSystem"
	) as GuardianAuraSystem
	if (
		guardian_aura_system != null
		and requested_guardian_refresh_interval > 0.0
	):
		guardian_aura_system.refresh_interval_seconds = (
			requested_guardian_refresh_interval
		)

	pathfinder = game.grid_pathfinder as GridPathfinder
	_expect(pathfinder != null and pathfinder.is_built, "Production GridPathfinder must be built.")
	_expect(game.player != null, "Enemy cohort probe requires the real local player.")
	if pathfinder == null or not pathfinder.is_built or game.player == null:
		await _finish()
		return
	effective_projectile_world_certificate = (
		requested_projectile_world_certificate
		and pathfinder.world_collision_layer_exclusive_to_authored_tiles
	)
	CapooAK47Bullet.world_collision_certificate_enabled = (
		effective_projectile_world_certificate
	)
	_expect(
		not requested_projectile_world_certificate
		or effective_projectile_world_certificate,
		(
			"Projectile world certificate A/B requires a fixture whose world "
			+ "collision layer is exclusive to authored tiles; the production "
			+ "tower-defense scene contains additional StaticBody2D colliders."
		)
	)
	if requested_projectile_world_certificate and not effective_projectile_world_certificate:
		await _finish()
		return
	if requested_navigation_refresh_cap > 0:
		pathfinder.max_agent_navigation_refreshes_per_process_frame = (
			requested_navigation_refresh_cap
		)
	var projectile_pool_startup := _get_projectile_pool_metrics()
	_validate_projectile_pool_startup(projectile_pool_startup)

	telemetry = TELEMETRY_SCRIPT.new() as RuntimePerformanceTelemetry
	root.add_child(telemetry)
	viewport_rid = game.get_viewport().get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(viewport_rid, true)
	_prepare_runtime()
	await _spawn_simple_fence_fixture()
	if simple_fences.size() != requested_simple_fence_count:
		await _finish()
		return

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
			+ "phase=%s enemies=%d fences=%d corn=%d agave=%d warmup=%d samples=%d "
			+ "setup_ms=%.3f tower_setup_ms=%.3f runtime_setup_ms=%.3f "
			+ "projectile_pool_registration_ms=%.3f expanded_prewarm=%s "
			+ "gunner_pool=%d/%d "
			+ "seed=%d max_fps=%d physics_hz=%d renderer=%s driver=%s gpu=%s"
		)
		% [
			_get_cohort_source_path(),
			_get_cohort_display_name(),
			_phase_name(),
			enemies.size(),
			simple_fences.size(),
			corn_towers.size(),
			agave_towers.size(),
			warmup_frames,
			sample_frames,
			setup_ms,
			tower_setup_ms,
			runtime_setup_ms,
			game.projectile_pool_registration_ms,
			str(requested_expanded_projectile_prewarm),
			requested_gunner_bullet_pool_prewarm,
			requested_gunner_bullet_pool_retained,
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

	var result := await _measure_sample_window(
		setup_ms,
		tower_setup_ms,
		runtime_setup_ms,
		projectile_pool_startup
	)
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
		# Exercise the same far-right red-gate entry point as the formal tower-
		# defense campaign so Boss movement and skill anchors stay representative.
		active_boss_config = load(LINGLAN_BOSS_CONFIG_PATH) as BossConfig
		_expect(active_boss_config != null, "Linglan BossConfig must load.")
		if active_boss_config != null:
			game.linglan_boss_enabled = true
			game.boss_coordinator.active_boss_config = active_boss_config
			var boss_spawn_position := game.boss_coordinator.get_linglan_spawn_global_position(
				active_boss_config
			)
			game.player.global_position = boss_spawn_position + Vector2(120.0, 80.0)
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
		game.wave_state = CombatFlowState.State.BOSS_ACTIVE
	movement_start_physics_frame = Engine.get_physics_frames()
	movement_direction = 0
	if phase != ProbePhase.BURST:
		_set_movement_direction(1)


func _spawn_simple_fence_fixture() -> void:
	var plant_system := game.plant_system as PlantSystem
	_expect(
		plant_system != null,
		"The production fence cohort requires PlantSystem."
	)
	if plant_system == null:
		return
	if requested_simple_fence_ab_metrics:
		plant_system.set_plant_target_query_metrics_enabled(true)
		plant_system.set_enemy_target_query_metrics_enabled(true)

	# These cells remain thousands of authored tiles away from the player and
	# cohort. They therefore exercise real StaticBody2D registration and scene
	# ownership without creating a contact workload or changing an objective.
	plant_system.placement_area = Rect2i(-20_000, -20_000, 40_000, 40_000)
	await process_frame
	await physics_frame
	var node_count_before := Performance.get_monitor(Performance.OBJECT_NODE_COUNT)
	var static_memory_mib_before := (
		Performance.get_monitor(Performance.MEMORY_STATIC) / (1024.0 * 1024.0)
	)
	var all_index_before := plant_system.get_plant_target_spatial_index_metrics()
	var enemy_index_before := plant_system.get_enemy_target_spatial_index_metrics()
	var navigation_before := _capture_static_navigation_signature()
	var setup_started_usec := Time.get_ticks_usec()

	for fence_index in range(requested_simple_fence_count):
		var cell := SIMPLE_FENCE_FAR_CELL_ORIGIN + Vector2i(
			fence_index % SIMPLE_FENCE_GRID_COLUMNS,
			fence_index / SIMPLE_FENCE_GRID_COLUMNS
		)
		var fence := plant_system.spawn_multiplayer_replica(
			&"simple_fence",
			cell,
			null,
			SIMPLE_FENCE_NET_ID_BASE + fence_index,
			500,
			500,
			0,
			false
		) as CardinalConnectedPlant
		if fence != null:
			simple_fences.append(fence)
		var cardinal_metrics := (
			plant_system.get_last_cardinal_connection_refresh_metrics()
		)
		_expect(
			int(cardinal_metrics.get("cells_visited", -1)) <= 5,
			"A fence fixture mutation must visit no more than five cells."
		)

	await process_frame
	await physics_frame
	var fence_setup_ms := float(
		Time.get_ticks_usec() - setup_started_usec
	) / 1000.0
	var node_count_after := Performance.get_monitor(Performance.OBJECT_NODE_COUNT)
	var static_memory_mib_after := (
		Performance.get_monitor(Performance.MEMORY_STATIC) / (1024.0 * 1024.0)
	)
	var all_index_after := plant_system.get_plant_target_spatial_index_metrics()
	var enemy_index_after := plant_system.get_enemy_target_spatial_index_metrics()
	var navigation_after := _capture_static_navigation_signature()

	_expect(
		simple_fences.size() == requested_simple_fence_count,
		"The complete requested real simple-fence fixture must instantiate."
	)
	_expect(
		int(all_index_after.get("registered_count", -1))
		== int(all_index_before.get("registered_count", -1))
		+ requested_simple_fence_count,
		"Every real fence must enter the all-building target index exactly once."
	)
	_expect(
		int(enemy_index_after.get("registered_count", -1))
		== int(enemy_index_before.get("registered_count", -1)),
		"CONTACT_ONLY fences must never enter the proactive enemy target index."
	)
	_expect(
		bool(all_index_after.get("structure_counts_consistent", false))
		and bool(enemy_index_after.get("structure_counts_consistent", false)),
		"Fence fixture target-index membership counters must remain consistent."
	)
	_expect(
		navigation_after == navigation_before,
		"Real fence registration must not mutate the production navigation snapshot."
	)

	simple_fence_fixture_metrics = {
		"requested": requested_simple_fence_count,
		"spawned": simple_fences.size(),
		"real_static_body_count": simple_fences.size(),
		"real_collision_shape_count": _count_fence_collision_shapes(),
		"fence_subtree_node_count": _count_fence_subtree_nodes(),
		"setup_ms": fence_setup_ms,
		"node_count_before": node_count_before,
		"node_count_after": node_count_after,
		"node_count_delta": node_count_after - node_count_before,
		"static_memory_mib_before": static_memory_mib_before,
		"static_memory_mib_after": static_memory_mib_after,
		"static_memory_mib_delta": (
			static_memory_mib_after - static_memory_mib_before
		),
		"all_target_index_before": all_index_before,
		"all_target_index_after_spawn": all_index_after,
		"enemy_target_index_before": enemy_index_before,
		"enemy_target_index_after_spawn": enemy_index_after,
		"navigation_before": navigation_before,
		"navigation_after_spawn": navigation_after,
	}


func _capture_static_navigation_signature() -> Dictionary:
	return {
		"generation": pathfinder.navigation_generation,
		"raw_generation": pathfinder.raw_navigation_snapshot_generation,
		"raw_region": pathfinder.raw_navigation_snapshot_region,
		"raw_cell_count": pathfinder.raw_navigation_cell_snapshot.size(),
		"raw_cell_hash": hash(pathfinder.raw_navigation_cell_snapshot),
		"raw_obstacle_count": pathfinder.raw_obstacle_integral_snapshot.size(),
		"raw_obstacle_hash": hash(pathfinder.raw_obstacle_integral_snapshot),
		"raw_obstacle_stride": pathfinder.raw_obstacle_integral_stride,
	}


func _count_fence_subtree_nodes() -> int:
	var total := 0
	for fence in simple_fences:
		if fence != null and is_instance_valid(fence):
			total += _count_subtree_nodes(fence)
	return total


func _count_subtree_nodes(node: Node) -> int:
	var total := 1
	for child in node.get_children():
		total += _count_subtree_nodes(child)
	return total


func _count_fence_collision_shapes() -> int:
	var total := 0
	for fence in simple_fences:
		if (
			fence != null
			and is_instance_valid(fence)
			and fence.get_node_or_null("CollisionShape2D") is CollisionShape2D
		):
			total += 1
	return total


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


func _disable_smg_projectiles_in_cohort() -> void:
	var duplicates_by_config_id: Dictionary[int, CapooSMGConfig] = {}
	for config_index in range(cohort_configs.size()):
		var smg_config := cohort_configs[config_index] as CapooSMGConfig
		if smg_config == null:
			continue
		var config_id := smg_config.get_instance_id()
		var duplicate_config := duplicates_by_config_id.get(
			config_id
		) as CapooSMGConfig
		if duplicate_config == null:
			duplicate_config = smg_config.duplicate() as CapooSMGConfig
			if duplicate_config == null:
				continue
			duplicate_config.projectile_scene = null
			duplicates_by_config_id[config_id] = duplicate_config
		cohort_configs[config_index] = duplicate_config


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
	var minimum_unique_positions := requested_enemy_count
	if phase == ProbePhase.ENGAGEMENT:
		# The authored combat ring contains fewer than 300 distinct walkable cells.
		# Enemies do not collide with one another, so reusing at least 128 cells
		# with the small deterministic offsets below preserves a dense real-combat
		# fixture without weakening the requested 300-enemy workload.
		minimum_unique_positions = mini(requested_enemy_count, 128)
	elif phase == ProbePhase.BURST:
		minimum_unique_positions = 1
	_expect(
		positions.size() >= minimum_unique_positions,
		(
			"The production map must provide enough deterministic walkable "
			+ "cohort cells (required=%d actual=%d phase=%s)."
		)
		% [minimum_unique_positions, positions.size(), _phase_name()]
	)
	if positions.size() < minimum_unique_positions:
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
		# add_child() has completed _ready(), including every randomize() call.
		# Override all streams before setup/activate can consume them so A/B
		# pressure runs retain identical gameplay, drop and Boss-skill choices.
		_seed_enemy_random_streams(enemy, enemy_index)
		var position_index := enemy_index % positions.size()
		var stacked_row := int(enemy_index / positions.size())
		var stacked_offset := Vector2(
			float(stacked_row % 3) * 2.0,
			float(int(stacked_row / 3) % 3) * 2.0
		)
		enemy.global_position = positions[position_index] + stacked_offset
		enemy.setup(current_enemy_config, game.player, pathfinder, game)
		if requested_navigation_interval > 0:
			enemy.navigation_update_interval_frames = requested_navigation_interval
		enemy.current_health = ENEMY_PROBE_HEALTH if not is_boss else enemy.current_health
		enemy.set_near_moving_target_direct_distance(
			TowerDefenseEnemyCoordinator.PLAYER_OBJECTIVE_AGGRO_RADIUS_CELLS
			* TowerDefenseEnemyCoordinator.AUTHORED_LOGICAL_TILE_SIZE
		)
		if phase != ProbePhase.APPROACH:
			enemy.set_target_player(game.player)
			enemy.set_objective_target(game.player)
		else:
			game.enemy_coordinator.assign_enemy_targets(enemy, enemy.global_position)
		game.enemy_coordinator.configure_authoritative_enemy_physics_interpolation(enemy)
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


func _seed_enemy_random_streams(enemy: Enemy, enemy_index: int) -> void:
	var behavior_seed := fixed_seed + enemy_index * 2
	var material_drop_seed := behavior_seed + 1
	enemy.random_generator.seed = behavior_seed
	enemy.material_drop_random_generator.seed = material_drop_seed
	_assert_random_stream_matches_seed(
		enemy.random_generator,
		behavior_seed,
		"Enemy behavior RNG"
	)
	_assert_random_stream_matches_seed(
		enemy.material_drop_random_generator,
		material_drop_seed,
		"Enemy material-drop RNG"
	)

	var boss := enemy as LinglanBoss
	if boss == null:
		return
	var skill_seed_base := (
		fixed_seed
		+ LINGLAN_SKILL_RANDOM_SEED_OFFSET
		+ enemy_index * LINGLAN_SKILL_RANDOM_SEED_STRIDE
	)
	boss.skill3_random.seed = skill_seed_base
	boss.skill4_random.seed = skill_seed_base + 1
	boss.skill_order_random.seed = skill_seed_base + 2
	_assert_random_stream_matches_seed(
		boss.skill3_random,
		skill_seed_base,
		"Linglan skill-3 RNG"
	)
	_assert_random_stream_matches_seed(
		boss.skill4_random,
		skill_seed_base + 1,
		"Linglan skill-4 RNG"
	)
	_assert_random_stream_matches_seed(
		boss.skill_order_random,
		skill_seed_base + 2,
		"Linglan skill-order RNG"
	)


func _assert_random_stream_matches_seed(
	random_stream: RandomNumberGenerator,
	expected_seed: int,
	stream_name: String
) -> void:
	var original_state := random_stream.state
	var verifier := RandomNumberGenerator.new()
	verifier.seed = expected_seed
	var first_value_matches := random_stream.randi() == verifier.randi()
	var second_value_matches := random_stream.randi() == verifier.randi()
	random_stream.state = original_state
	_expect(
		random_stream.seed == expected_seed
		and random_stream.state == original_state
		and first_value_matches
		and second_value_matches,
		"%s must match its deterministic probe seed without advancing its state."
		% stream_name
	)


func _build_candidate_positions() -> PackedVector2Array:
	var candidates := PackedVector2Array()
	if phase == ProbePhase.BOSS and active_boss_config != null:
		candidates.append(
			game.boss_coordinator.get_linglan_spawn_global_position(
			active_boss_config
		))
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


func _measure_sample_window(
	setup_ms: float,
	tower_setup_ms: float,
	runtime_setup_ms: float,
	projectile_pool_startup: Dictionary
) -> Dictionary:
	Enemy.reset_performance_metrics()
	Enemy.performance_metrics_enabled = requested_enemy_hot_metrics
	STONE_GOLEM_SCRIPT.reset_slam_performance_metrics()
	STONE_GOLEM_SCRIPT.slam_performance_metrics_enabled = (
		requested_enemy_hot_metrics
	)
	CapooAK47Bullet.reset_performance_metrics()
	CapooAK47Bullet.performance_metrics_enabled = requested_projectile_hot_metrics
	ENEMY_ATTACK_AUDIO_LIMITER.reset_metrics()
	var guardian_aura_system := game.get_node_or_null(
		"GuardianAuraSystem"
	) as GuardianAuraSystem
	if guardian_aura_system != null:
		guardian_aura_system.collect_overlap_query_metrics = (
			requested_guardian_overlap_metrics
		)
		guardian_aura_system.reset_runtime_performance_metrics()
	telemetry.reset()
	var corn_locks_before := _get_corn_target_lock_count()
	var corn_rays_before := _get_corn_hitscan_ray_count()
	var pool_before := _aggregate_pool_metrics()
	var pool_buckets_before := _get_pool_bucket_metrics()
	var projectile_pool_before := _get_projectile_pool_metrics()
	var player_health_before := game.player.current_health
	var base_health_before := game.current_base_health
	var physics_frames_before := Engine.get_physics_frames()
	pathfinder.agent_navigation_refresh_max_wait_process_frames = 0
	var navigation_refresh_admitted_before := (
		pathfinder.agent_navigation_refreshes_admitted_total
	)
	var navigation_refresh_deferred_before := (
		pathfinder.agent_navigation_refreshes_deferred_total
	)
	var navigation_refresh_saturated_frames_before := (
		pathfinder.agent_navigation_refresh_budget_saturated_frames_total
	)
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
	var physics_steps_per_render_sample: Array[float] = []
	var frame_diagnostics: Array[Dictionary] = []
	var previous_corn_locks := _get_corn_target_lock_count()
	var previous_corn_rays := _get_corn_hitscan_ray_count()
	var previous_combat_index_size: int = (
		game.combat_target_index.enemies_by_net_id.size()
	)
	var previous_enemy_hit_effect_drops := _get_pool_dropped_count(
		ENEMY_HIT_EFFECT_POOL_PATH
	)
	var previous_navigation_refresh_deferrals := (
		pathfinder.agent_navigation_refreshes_deferred_total
	)
	var previous_sample_physics_frame := Engine.get_physics_frames()
	var previous_tick_usec := Time.get_ticks_usec()

	for sample_index in range(sample_frames):
		await process_frame
		_drive_player_movement()
		var now_usec := Time.get_ticks_usec()
		var wall_ms := float(now_usec - previous_tick_usec) / 1000.0
		wall_samples.append(wall_ms)
		previous_tick_usec = now_usec
		var current_sample_physics_frame := Engine.get_physics_frames()
		var physics_steps_this_sample := maxi(
			current_sample_physics_frame - previous_sample_physics_frame,
			0
		)
		physics_steps_per_render_sample.append(float(physics_steps_this_sample))
		previous_sample_physics_frame = current_sample_physics_frame
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
		var current_navigation_refresh_deferrals := (
			pathfinder.agent_navigation_refreshes_deferred_total
		)
		frame_diagnostics.append({
			"sample_index": sample_index,
			"wall_ms": wall_ms,
			"physics_steps": physics_steps_this_sample,
			"corn_locks": current_corn_locks - previous_corn_locks,
			"corn_rays": current_corn_rays - previous_corn_rays,
			"combat_index_size": current_combat_index_size,
			"combat_index_delta": (
				current_combat_index_size - previous_combat_index_size
			),
			"enemy_hit_effect_drops": (
				current_enemy_hit_effect_drops - previous_enemy_hit_effect_drops
			),
			"navigation_refresh_deferrals": (
				current_navigation_refresh_deferrals
				- previous_navigation_refresh_deferrals
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
		previous_navigation_refresh_deferrals = current_navigation_refresh_deferrals
		_sample_boss_runtime(boss_phase_observations, boss_peak_counters)

		if (
			requested_runtime_count_scans
			and sample_index % COUNT_SAMPLE_INTERVAL_FRAMES == 0
		):
			var counts := telemetry.sample_runtime_counts(game)
			peak_projectiles = maxi(peak_projectiles, int(counts["active_projectiles"]))
			minimum_alive = mini(minimum_alive, int(counts["active_enemies"]))

	Enemy.performance_metrics_enabled = false
	var enemy_metrics := Enemy.get_performance_metrics(true)
	STONE_GOLEM_SCRIPT.slam_performance_metrics_enabled = false
	var stone_golem_slam_metrics: Dictionary = (
		STONE_GOLEM_SCRIPT.get_slam_performance_metrics(true)
	)
	CapooAK47Bullet.performance_metrics_enabled = false
	var projectile_metrics := CapooAK47Bullet.get_performance_metrics(true)
	var guardian_aura_metrics := {}
	if guardian_aura_system != null:
		guardian_aura_system.collect_overlap_query_metrics = false
		guardian_aura_metrics = guardian_aura_system.get_runtime_performance_metrics()
	var final_counts := telemetry.sample_runtime_counts(game)
	peak_projectiles = maxi(peak_projectiles, telemetry.peak_active_projectiles)
	minimum_alive = mini(minimum_alive, int(final_counts["active_enemies"]))
	var pool_after := _aggregate_pool_metrics()
	var pool_buckets_after := _get_pool_bucket_metrics()
	var projectile_pool_after := _get_projectile_pool_metrics()
	var wall_summary := _summarize(wall_samples)
	var final_fence_metrics := simple_fence_fixture_metrics.duplicate(true)
	final_fence_metrics["all_target_index_final"] = (
		game.plant_system.get_plant_target_spatial_index_metrics()
	)
	final_fence_metrics["all_target_last_query"] = (
		game.plant_system.get_last_plant_target_query_metrics()
	)
	final_fence_metrics["enemy_target_index_final"] = (
		game.plant_system.get_enemy_target_spatial_index_metrics()
	)
	final_fence_metrics["enemy_target_last_query"] = (
		game.plant_system.get_last_enemy_target_query_metrics()
	)
	final_fence_metrics["navigation_final"] = (
		_capture_static_navigation_signature()
	)
	final_fence_metrics["terrain_support_final"] = (
		game.plant_system.get_unsupported_terrain_metrics()
	)

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
		"requested_simple_fences": requested_simple_fence_count,
		"simple_fences": simple_fences.size(),
		"simple_fence_ab_metrics": requested_simple_fence_ab_metrics,
		"simple_fence_fixture": final_fence_metrics,
		"corn_towers": corn_towers.size(),
		"agave_towers": agave_towers.size(),
		"alive_start": alive_start,
		"alive_min": minimum_alive,
		"alive_end": int(final_counts["active_enemies"]),
		"setup_ms": setup_ms,
		"tower_setup_ms": tower_setup_ms,
		"runtime_setup_ms": runtime_setup_ms,
		"projectile_pool_registration_ms": game.projectile_pool_registration_ms,
		"burst_trigger_ms": burst_trigger_ms,
		"warmup_frames": warmup_frames,
		"sample_frames": sample_frames,
		"navigation_interval": (
			requested_navigation_interval
			if requested_navigation_interval > 0
			else Enemy.DEFAULT_NAVIGATION_UPDATE_INTERVAL_FRAMES
		),
		"navigation_render_dedupe": requested_navigation_render_dedupe,
		"navigation_refresh_budget": requested_navigation_refresh_budget,
		"combat_sense_throttling": requested_combat_sense_throttling,
		"navigation_refresh_budget_runtime": {
			"cap_per_process_frame": (
				pathfinder.max_agent_navigation_refreshes_per_process_frame
			),
			"admitted": (
				pathfinder.agent_navigation_refreshes_admitted_total
				- navigation_refresh_admitted_before
			),
			"deferred": (
				pathfinder.agent_navigation_refreshes_deferred_total
				- navigation_refresh_deferred_before
			),
			"saturated_process_frames": (
				pathfinder.agent_navigation_refresh_budget_saturated_frames_total
				- navigation_refresh_saturated_frames_before
			),
			"max_wait_process_frames": (
				pathfinder.agent_navigation_refresh_max_wait_process_frames
			),
			"pending_agents": (
				pathfinder.agent_navigation_refresh_deferred_ids.size()
			),
		},
		"enemy_hot_metrics": requested_enemy_hot_metrics,
		"guardian_overlap_metrics": requested_guardian_overlap_metrics,
		"guardian_unchanged_diff_fast_path": (
			requested_guardian_unchanged_diff_fast_path
		),
		"guardian_refresh_interval": (
			requested_guardian_refresh_interval
			if requested_guardian_refresh_interval > 0.0
			else (
				guardian_aura_system.refresh_interval_seconds
				if guardian_aura_system != null
				else 0.0
			)
		),
		"runtime_count_scans": requested_runtime_count_scans,
		"projectile_world_certificate_requested": (
			requested_projectile_world_certificate
		),
		"projectile_world_certificate": effective_projectile_world_certificate,
		"projectile_hot_metrics": requested_projectile_hot_metrics,
		"batched_projectile_motion": requested_batched_projectile_motion,
		"ak_attack_phase_stagger": requested_ak_attack_phase_stagger,
		"gunner_bullet_pool_prewarm": requested_gunner_bullet_pool_prewarm,
		"gunner_bullet_pool_retained": requested_gunner_bullet_pool_retained,
		"smg_short_range_targeting": requested_smg_short_range_targeting,
		"smg_hitscan_attack": requested_smg_hitscan_attack,
		"disable_smg_projectiles": requested_disable_smg_projectiles,
		"expanded_projectile_prewarm": requested_expanded_projectile_prewarm,
		"enemy_attack_audio_limiter": requested_enemy_attack_audio_limiter,
		"enemy_attack_audio": ENEMY_ATTACK_AUDIO_LIMITER.get_metrics(),
		"pooled_mage_impact_effect": requested_pooled_mage_impact_effect,
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
		"physics_frames_elapsed": Engine.get_physics_frames() - physics_frames_before,
		"physics_catchup": {
			"max_steps_per_render_sample": int(
				_summarize(physics_steps_per_render_sample).get("max", 0.0)
			),
			"samples_with_multiple_steps": _count_over_budget(
				physics_steps_per_render_sample,
				1.0
			),
			"multiple_step_ratio": _ratio_over_budget(
				physics_steps_per_render_sample,
				1.0
			),
			"steps_per_render_sample": _summarize(
				physics_steps_per_render_sample
			),
			"configured_max_steps_per_frame": Engine.max_physics_steps_per_frame,
		},
		"simulation_seconds_elapsed": (
			float(Engine.get_physics_frames() - physics_frames_before)
			/ float(maxi(Engine.physics_ticks_per_second, 1))
		),
		"peak_projectiles": peak_projectiles,
		"corn_target_locks": _get_corn_target_lock_count() - corn_locks_before,
		"corn_hitscan_rays": _get_corn_hitscan_ray_count() - corn_rays_before,
		"boss_phase_observations": boss_phase_observations,
		"boss_peak_counters": boss_peak_counters,
		"boss_runtime_state": _get_boss_runtime_state(),
		"enemy_hot_segments": _format_enemy_hot_segments(enemy_metrics),
		"stone_golem_slam": stone_golem_slam_metrics,
		"projectile_hot_segments": projectile_metrics,
		"guardian_aura": guardian_aura_metrics,
		"pool_before": pool_before,
		"pool_after": pool_after,
		"pool_delta": _subtract_pool_metrics(pool_after, pool_before),
		"pool_bucket_changes": _diff_pool_bucket_metrics(
			pool_buckets_before,
			pool_buckets_after
		),
		"projectile_pool_startup": projectile_pool_startup,
		"projectile_pool_window": _build_pool_metric_window(
			projectile_pool_before,
			projectile_pool_after
		),
		"combat_index_size": game.combat_target_index.enemies_by_net_id.size(),
		"renderer": RenderingServer.get_current_rendering_method(),
		"render_driver": RenderingServer.get_current_rendering_driver_name(),
		"gpu": RenderingServer.get_video_adapter_name(),
	}

	_expect(wall_samples.size() == sample_frames, "Every requested frame sample must be recorded.")
	_expect(
		simple_fences.size() == requested_simple_fence_count,
		"Every requested real simple fence must survive the measured window."
	)
	var final_enemy_target_index := (
		final_fence_metrics["enemy_target_index_final"] as Dictionary
	)
	_expect(
		int(final_enemy_target_index.get("registered_count", -1))
		== int(
			(simple_fence_fixture_metrics["enemy_target_index_before"] as Dictionary).get(
				"registered_count",
				-1
			)
		),
		"CONTACT_ONLY fences must remain absent from the proactive index."
	)
	_expect(
		_capture_static_navigation_signature()
		== simple_fence_fixture_metrics["navigation_before"],
		"The measured real-fence cohort must retain the original navigation snapshot."
	)
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
		# The burst phase intentionally frees the entire cohort. Validate the
		# retained typed reference before casting it; casting a freed Object emits
		# one script error per sample even though the probe can otherwise finish.
		if not is_instance_valid(enemy):
			continue
		var boss := enemy as LinglanBoss
		if boss == null:
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
		if not is_instance_valid(enemy):
			continue
		var boss := enemy as LinglanBoss
		if boss == null:
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
	result["navigation_refresh_calls"] = int(
		metrics.get("navigation_refresh_calls", 0)
	)
	result["navigation_same_render_skips"] = int(
		metrics.get("navigation_same_render_skips", 0)
	)
	result["navigation_budget_deferrals"] = int(
		metrics.get("navigation_budget_deferrals", 0)
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


func _get_projectile_pool_metrics() -> Dictionary:
	var result := {}
	if game == null or game.session_object_pool == null:
		return result
	for scene_path in [
		CAPOO_AK47_BULLET_POOL_PATH,
		COMBAT_ROBOT_GUNNER_BULLET_POOL_PATH,
		CAPOO_MAGE_FIREBALL_POOL_PATH,
		BULLET_HIT_EFFECT_POOL_PATH,
	]:
		result[scene_path] = game.session_object_pool.get_metrics(scene_path)
	return result


func _validate_projectile_pool_startup(metrics_by_path: Dictionary) -> void:
	var expected_ak47_prewarm := (
		TowerDefensePrewarmerCoordinator.EXPANDED_CAPOO_AK47_BULLET_PREWARM_COUNT
		if requested_expanded_projectile_prewarm
		else TowerDefensePrewarmerCoordinator.LEGACY_CAPOO_AK47_BULLET_PREWARM_COUNT
	)
	var expected_mage_prewarm := (
		TowerDefensePrewarmerCoordinator.EXPANDED_CAPOO_MAGE_FIREBALL_PREWARM_COUNT
		if requested_expanded_projectile_prewarm
		else TowerDefensePrewarmerCoordinator.LEGACY_CAPOO_MAGE_FIREBALL_PREWARM_COUNT
	)
	var ak47_metrics := metrics_by_path.get(
		CAPOO_AK47_BULLET_POOL_PATH,
		{}
	) as Dictionary
	var mage_metrics := metrics_by_path.get(
		CAPOO_MAGE_FIREBALL_POOL_PATH,
		{}
	) as Dictionary
	var gunner_metrics := metrics_by_path.get(
		COMBAT_ROBOT_GUNNER_BULLET_POOL_PATH,
		{}
	) as Dictionary
	_expect(
		int(ak47_metrics.get("created", -1)) == expected_ak47_prewarm,
		"AK projectile pool startup count must match the selected A/B variant."
	)
	_expect(
		int(mage_metrics.get("created", -1)) == expected_mage_prewarm,
		"Mage projectile pool startup count must match the selected A/B variant."
	)
	_expect(
		int(gunner_metrics.get("created", -1))
		== requested_gunner_bullet_pool_prewarm
		and int(gunner_metrics.get("retained_capacity", -1))
		== maxi(
			requested_gunner_bullet_pool_prewarm,
			requested_gunner_bullet_pool_retained
		),
		"Gunner projectile pool startup metrics must match the isolated A/B values."
	)
	_expect(
		int(ak47_metrics.get("retained_capacity", -1)) == 384
		and int(mage_metrics.get("retained_capacity", -1)) == 192,
		"Expanded prewarming must not change projectile retained capacities."
	)


func _build_pool_metric_window(before: Dictionary, after: Dictionary) -> Dictionary:
	var result := {}
	for scene_path in [
		CAPOO_AK47_BULLET_POOL_PATH,
		COMBAT_ROBOT_GUNNER_BULLET_POOL_PATH,
		CAPOO_MAGE_FIREBALL_POOL_PATH,
		BULLET_HIT_EFFECT_POOL_PATH,
	]:
		var before_metrics := before.get(scene_path, {}) as Dictionary
		var after_metrics := after.get(scene_path, {}) as Dictionary
		result[scene_path] = {
			"before": before_metrics,
			"after": after_metrics,
			"delta": _subtract_pool_metrics(after_metrics, before_metrics),
		}
	return result


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
	STONE_GOLEM_SCRIPT.slam_performance_metrics_enabled = false
	CapooAK47Bullet.performance_metrics_enabled = false
	Enemy.navigation_render_frame_dedupe_enabled = original_navigation_render_dedupe
	Enemy.navigation_process_frame_budget_enabled = original_navigation_refresh_budget
	Enemy.combat_sense_throttling_enabled = original_combat_sense_throttling
	GuardianAuraSystem.unchanged_source_diff_fast_path_enabled = (
		original_guardian_unchanged_diff_fast_path
	)
	CapooAK47Bullet.world_collision_certificate_enabled = (
		original_projectile_world_certificate
	)
	CapooAK47Bullet.batched_motion_enabled = original_batched_projectile_motion
	CapooAK47.attack_phase_stagger_enabled = original_ak_attack_phase_stagger
	CombatRuntimeBase.combat_robot_gunner_bullet_pool_prewarm_count = (
		original_gunner_bullet_pool_prewarm
	)
	CombatRuntimeBase.combat_robot_gunner_bullet_pool_retained_capacity = (
		original_gunner_bullet_pool_retained
	)
	CapooSMG.short_range_targeting_enabled = original_smg_short_range_targeting
	CapooSMG.hitscan_attack_enabled = original_smg_hitscan_attack
	TowerDefenseGame.expanded_projectile_pool_prewarm_enabled = (
		original_expanded_projectile_prewarm
	)
	ENEMY_ATTACK_AUDIO_LIMITER.limiting_enabled = (
		original_enemy_attack_audio_limiter
	)
	CAPOO_MAGE_FIREBALL_SCRIPT.pooled_impact_effect_enabled = (
		original_pooled_mage_impact_effect
	)
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
