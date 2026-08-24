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
const TOWER_SCENE_PATH := "res://scene/game_modes/tower_defense/tower_defense_game.tscn"
const TELEMETRY_SCRIPT := preload("res://scene/combat/diagnostics/runtime_performance_telemetry.gd")
const ENEMY_ATTACK_AUDIO_LIMITER := preload(
	"res://scene/combat/audio/enemy_attack_audio_limiter.gd"
)
const STONE_GOLEM_SCRIPT := preload("res://scene/enemy/artificial_creation/stone_golem.gd")
const CORN_CONFIG := preload(
	"res://resources/config/plant_defense/corn_machine_gun.tres"
)
const AGAVE_CONFIG := preload(
	"res://resources/config/plant_defense/agave_cannon.tres"
)
const FORMAL_WAVE_01_PATH := (
	"res://resources/config/campaigns/tower_defense/formal/wave_01.tres"
)
const FORMAL_WAVE_12_PATH := (
	"res://resources/config/campaigns/tower_defense/formal/wave_12.tres"
)
const CLIENT_RUNTIME_SCENE := preload(
	"res://dev_tools/fixtures/enemy_gameplay_gateway_test_runtime.tscn"
)
const MP_ENEMY_COORDINATOR_SCENE := preload(
	"res://scene/multiplayer/enemy/mp_enemy_coordinator.tscn"
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
const CAPOO_MAGE_FIREBALL_SCRIPT_PATH := "res://scene/enemy/capoo/capoo_mage_fireball.gd"
const BULLET_HIT_EFFECT_POOL_PATH := "res://scene/combat/projectiles/bullet_hit_effect.tscn"
const ENEMY_HIT_EFFECT_POOL_PATH := "res://scene/enemy/enemy_hit_effect.tscn"
const AGAVE_CANNONBALL_POOL_PATH := "res://scene/plant_defense/agave_cannonball.tscn"
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
const PROBE_RESULT_SCHEMA_VERSION := 1
const FORMAL_GATE_MINIMUM_WARMUP_FRAMES := 120
const FORMAL_GATE_MINIMUM_SAMPLE_FRAMES := 1200
const QUICK_GATE_MINIMUM_WARMUP_FRAMES := 60
const QUICK_GATE_MINIMUM_SAMPLE_FRAMES := 240
const CPU60_DEFAULT_OVER_33_RATIO_BUDGET := 0.005
const WINDOW60_DEFAULT_WALL_P95_BUDGET_MS := 18.0
const WINDOW60_DEFAULT_OVER_18_RATIO_BUDGET := 0.05
const FORMAL_WINDOW_SIZE := Vector2i(1280, 720)
const AB_WARMUP_PHYSICS_TICKS := 300
const AB_SAMPLE_PHYSICS_TICKS := 1800
const FORMAL_SCENARIO_IDS := [
	"first_night_main",
	"critical_300",
	"basic_pursuit_300",
	"tower_projectile_96",
	"faction_battle_150v150",
	"obstacle_water_unreachable",
	"host_client_proxy_1000",
]
const FACTION_BATTLE_SIZE := 150
const CLIENT_PROXY_COUNT := 1_000
const CLIENT_PROXY_NET_ID_BASE := 30_001
const CLIENT_PROXY_POSITION_COLUMNS := 40
const CLIENT_PROXY_POSITION_SPACING := 64.0
const CLIENT_PROXY_SNAPSHOT_HZ := 20
const CLIENT_PROXY_SNAPSHOT_BATCH_ID_BASE := 90_000
const CLIENT_PROXY_SNAPSHOT_HEALTH := 1_000_000
const UNREACHABLE_TARGET_SLOW_SOURCE_ID := 91_001
const RUNTIME_FATE_RANDOM_SEED_OFFSET := 2_000_000
const RUNTIME_FATE_MANAGER_RANDOM_SEED_OFFSET := 2_000_001
const TOWER_PROJECTILE_MINIMUM_TOTAL_SHOTS := 96
const TOWER_PROJECTILE_MINIMUM_AGAVE_SHOTS := 32
const TOWER_PROJECTILE_MINIMUM_CONCURRENT_PROJECTILES := 8

enum ProbePhase {
	APPROACH,
	ENGAGEMENT,
	BURST,
	BOSS,
}

enum GateProfile {
	DIAGNOSTIC,
	CPU60,
	WINDOW60,
	WAVE60,
}

var failures: Array[String] = []
var tower_scene: PackedScene = null
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
var building_fixture_positions := PackedVector2Array()
var formal_registration_fingerprint_before_measurement := {}
var formal_flow_config: WaveConfig = null
var scenario_contract := {}
var client_proxy_runtime: EnemyGameplayGatewayTestRuntime = null
var client_proxy_coordinator: MpEnemyCoordinator = null
var client_proxy_snapshot_sender: SnapshotManager = null
var client_proxy_snapshot_states: Array[SnapshotManager.EnemyState] = []
var client_proxy_snapshot_sequence := 0
var client_proxy_fixture_tick := 0
var client_proxy_target_assignment_events := 0
var client_proxy_damage_broadcast_events := 0
var client_proxy_defeat_events := 0
var host_runtime_configured_before_tree := false
var runtime_random_streams_determinized_after_ready := false

var enemy_config_path := DEFAULT_ENEMY_CONFIG_PATH
var wave_config_path := ""
var phase := ProbePhase.APPROACH
var requested_enemy_count := DEFAULT_ENEMY_COUNT
var requested_scenario_id := "custom"
var requested_simulation_mode := EnemySimulationPolicy.Mode.LEGACY
var requested_simulation_mode_explicit := false
var requested_authoritative_tick_sampling := false
var requested_detailed_semantic_evidence := false
var requested_simple_fence_count := 0
var requested_simple_fence_ab_metrics := false
var warmup_frames := DEFAULT_WARMUP_FRAMES
var sample_frames := DEFAULT_SAMPLE_FRAMES
var fixed_seed := DEFAULT_FIXED_SEED
var requested_corn_count := 0
var requested_agave_count := 0
var requested_max_fps := 60
var requested_window_size := Vector2i.ZERO
var requested_gate_profile := GateProfile.DIAGNOSTIC
var requested_quick_validation := false
var requested_wall_p95_budget_ms := FRAME_BUDGET_60_FPS_MS
var requested_wall_p99_budget_ms := FRAME_BUDGET_30_FPS_MS
var requested_over_18_ratio_budget := WINDOW60_DEFAULT_OVER_18_RATIO_BUDGET
var requested_over_33_ratio_budget := CPU60_DEFAULT_OVER_33_RATIO_BUDGET
var requested_vsync_mode := "project"
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
var requested_enemy_attack_audio_limiter := true
var original_max_fps := 0
var original_navigation_render_dedupe := true
var original_navigation_refresh_budget := true
var original_combat_sense_throttling := true
var original_guardian_unchanged_diff_fast_path := true
var original_enemy_attack_audio_limiter := true
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
			requested_enemy_count = maxi(int(argument.get_slice("=", 1)), 0)
		elif argument.begins_with("--scenario-id="):
			requested_scenario_id = argument.get_slice("=", 1).strip_edges().to_lower()
		elif argument.begins_with("--enemy-simulation-mode="):
			requested_simulation_mode_explicit = true
			requested_simulation_mode = EnemySimulationPolicy.parse_mode_name(
				argument.get_slice("=", 1),
				EnemySimulationPolicy.Mode.LEGACY
			)
		elif argument.begins_with("--authoritative-tick-sampling="):
			requested_authoritative_tick_sampling = (
				argument.get_slice("=", 1).to_lower() == "true"
			)
		elif argument.begins_with("--detailed-semantic-evidence="):
			requested_detailed_semantic_evidence = (
				argument.get_slice("=", 1).to_lower() == "true"
			)
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
		elif argument.begins_with("--gate-profile="):
			requested_gate_profile = _parse_gate_profile(argument.get_slice("=", 1))
			if requested_gate_profile in [GateProfile.WINDOW60, GateProfile.WAVE60]:
				requested_wall_p95_budget_ms = WINDOW60_DEFAULT_WALL_P95_BUDGET_MS
		elif argument.begins_with("--quick-validation="):
			requested_quick_validation = (
				argument.get_slice("=", 1).to_lower() == "true"
			)
		elif argument.begins_with("--wall-p95-budget-ms="):
			requested_wall_p95_budget_ms = maxf(
				float(argument.get_slice("=", 1)),
				0.0
			)
		elif argument.begins_with("--wall-p99-budget-ms="):
			requested_wall_p99_budget_ms = maxf(
				float(argument.get_slice("=", 1)),
				0.0
			)
		elif argument.begins_with("--over-18-ratio-budget="):
			requested_over_18_ratio_budget = clampf(
				float(argument.get_slice("=", 1)),
				0.0,
				1.0
			)
		elif argument.begins_with("--over-33-ratio-budget="):
			requested_over_33_ratio_budget = clampf(
				float(argument.get_slice("=", 1)),
				0.0,
				1.0
			)
		elif argument.begins_with("--vsync-mode="):
			requested_vsync_mode = argument.get_slice("=", 1).to_lower()
			if requested_vsync_mode not in ["project", "disabled", "enabled"]:
				failures.append(
					"Unknown cohort VSync mode: %s" % requested_vsync_mode
				)
		elif argument.begins_with("--window-size="):
			var components := argument.get_slice("=", 1).to_lower().split("x", false)
			if components.size() == 2:
				requested_window_size = Vector2i(
					maxi(int(components[0]), 1),
					maxi(int(components[1]), 1)
				)
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
		elif argument.begins_with("--enemy-attack-audio-limiter="):
			requested_enemy_attack_audio_limiter = (
				argument.get_slice("=", 1).to_lower() == "true"
			)

	if phase == ProbePhase.BURST:
		# The first frames are the workload for self-destruct enemies. Warming
		# them first would leave an empty cohort and produce a false cheap result.
		warmup_frames = 0
	_validate_scenario_contract()


func _validate_scenario_contract() -> void:
	if requested_scenario_id.is_empty():
		failures.append("Scenario ID must not be empty.")
		requested_scenario_id = "custom"
	if requested_scenario_id != "custom" and requested_scenario_id not in FORMAL_SCENARIO_IDS:
		failures.append("Unknown cohort scenario ID: %s" % requested_scenario_id)
		return
	if requested_scenario_id == "custom":
		return
	var expected_enemy_count := 200 if requested_scenario_id == "first_night_main" else 300
	var expected_wave_path := ""
	var expected_enemy_path := ""
	var expected_phase := ProbePhase.APPROACH
	var expected_fences := 0
	var expected_corn := 0
	var expected_agave := 0
	match requested_scenario_id:
		"first_night_main", "critical_300":
			expected_wave_path = FORMAL_WAVE_01_PATH
			expected_fences = 40
			expected_corn = 40
			expected_agave = 20
		"tower_projectile_96":
			expected_wave_path = FORMAL_WAVE_12_PATH
			expected_phase = ProbePhase.ENGAGEMENT
			expected_corn = 64
			expected_agave = 32
		"host_client_proxy_1000":
			expected_wave_path = FORMAL_WAVE_01_PATH
		_:
			expected_enemy_path = DEFAULT_ENEMY_CONFIG_PATH
			if requested_scenario_id == "faction_battle_150v150":
				expected_phase = ProbePhase.ENGAGEMENT
	_expect(
		wave_config_path == expected_wave_path
		and (expected_enemy_path.is_empty() or enemy_config_path == expected_enemy_path),
		"%s must use its declared authored cohort source."
		% requested_scenario_id
	)
	_expect(
		requested_enemy_count == expected_enemy_count,
		"%s must contain exactly %d host-authoritative enemies."
		% [requested_scenario_id, expected_enemy_count]
	)
	_expect(
		requested_simple_fence_count == expected_fences
		and requested_corn_count == expected_corn
		and requested_agave_count == expected_agave,
		"%s building composition must match its formal fixture."
		% requested_scenario_id
	)
	_expect(
		phase == expected_phase,
		"%s must retain its declared production phase."
		% requested_scenario_id
	)
	_expect(
		requested_authoritative_tick_sampling,
		"%s requires authoritative physics-tick sampling."
		% requested_scenario_id
	)
	_expect(
		warmup_frames == AB_WARMUP_PHYSICS_TICKS
		and sample_frames == AB_SAMPLE_PHYSICS_TICKS,
		"%s requires exactly %d warmup and %d sample physics ticks."
		% [
			requested_scenario_id,
			AB_WARMUP_PHYSICS_TICKS,
			AB_SAMPLE_PHYSICS_TICKS,
		]
	)
	_expect(
		not requested_detailed_semantic_evidence,
		"Performance A/B scenarios must disable detailed semantic evidence."
	)


func _uses_formal_runtime_fixture() -> bool:
	return requested_scenario_id in FORMAL_SCENARIO_IDS


func _get_scenario_fixture_kind() -> String:
	match requested_scenario_id:
		"first_night_main", "critical_300":
			return "host_wave"
		"basic_pursuit_300":
			return "basic_pursuit"
		"tower_projectile_96":
			return "tower_projectile"
		"faction_battle_150v150":
			return "faction_battle"
		"obstacle_water_unreachable":
			return "water_unreachable"
		"host_client_proxy_1000":
			return "host_client_proxy"
	return "custom"


func _get_formal_flow_step_path() -> String:
	return (
		FORMAL_WAVE_12_PATH
		if requested_scenario_id == "tower_projectile_96"
		else FORMAL_WAVE_01_PATH
	)


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


func _parse_gate_profile(value: String) -> GateProfile:
	match value.to_lower():
		"diagnostic":
			return GateProfile.DIAGNOSTIC
		"cpu60":
			return GateProfile.CPU60
		"window60":
			return GateProfile.WINDOW60
		"wave60":
			return GateProfile.WAVE60
		_:
			failures.append("Unknown cohort gate profile: %s" % value)
			return GateProfile.DIAGNOSTIC


func _run() -> void:
	original_max_fps = Engine.max_fps
	original_navigation_render_dedupe = Enemy.navigation_render_frame_dedupe_enabled
	original_navigation_refresh_budget = Enemy.navigation_process_frame_budget_enabled
	original_combat_sense_throttling = Enemy.combat_sense_throttling_enabled
	original_guardian_unchanged_diff_fast_path = (
		GuardianAuraSystem.unchanged_source_diff_fast_path_enabled
	)
	original_enemy_attack_audio_limiter = ENEMY_ATTACK_AUDIO_LIMITER.limiting_enabled
	Enemy.navigation_render_frame_dedupe_enabled = requested_navigation_render_dedupe
	Enemy.navigation_process_frame_budget_enabled = requested_navigation_refresh_budget
	Enemy.combat_sense_throttling_enabled = requested_combat_sense_throttling
	GuardianAuraSystem.unchanged_source_diff_fast_path_enabled = (
		requested_guardian_unchanged_diff_fast_path
	)
	ENEMY_ATTACK_AUDIO_LIMITER.limiting_enabled = (
		requested_enemy_attack_audio_limiter
	)
	Engine.max_fps = requested_max_fps
	if requested_max_fps == 0 or requested_vsync_mode != "project":
		original_vsync_mode = DisplayServer.window_get_vsync_mode()
		var effective_vsync_mode := (
			DisplayServer.VSYNC_ENABLED
			if requested_vsync_mode == "enabled" and requested_max_fps != 0
			else DisplayServer.VSYNC_DISABLED
		)
		DisplayServer.window_set_vsync_mode(effective_vsync_mode)
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
	var runtime_setup_started_usec := Time.get_ticks_usec()
	tower_scene = load(TOWER_SCENE_PATH) as PackedScene
	_expect(tower_scene != null, "Enemy cohort probe must load TowerDefenseGame scene.")
	if tower_scene == null:
		await _finish()
		return
	game = tower_scene.instantiate() as TowerDefenseGame
	_expect(game != null, "Enemy cohort probe must instantiate TowerDefenseGame.")
	if game == null:
		await _finish()
		return
	game.auto_start_waves = false
	if _uses_formal_runtime_fixture():
		# Match MpGame's production construction order: multiplayer identity and
		# authority are configured while the runtime is still outside SceneTree, so
		# every _ready() branch observes Host authority from its first instruction.
		game.defer_runtime_activation()
		game.configure_multiplayer(
			CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY,
			1,
			{1: "A/B Probe Host"}
		)
		host_runtime_configured_before_tree = (
			not game.is_inside_tree()
			and game.runtime_mode == CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY
		)
	root.add_child(game)
	current_scene = game
	# TowerDefenseGame and its Fate children randomize in _ready(). Reapply every
	# runtime-owned stream only after those calls, before activation or fixture
	# setup can consume gameplay randomness.
	_determinize_runtime_random_streams_after_ready()
	if _uses_formal_runtime_fixture():
		game.activate_runtime()
	if requested_window_size != Vector2i.ZERO and DisplayServer.get_name() != "headless":
		DisplayServer.window_set_size(requested_window_size)
		root.size = requested_window_size
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
	if _uses_in_field_building_fixture():
		building_fixture_positions = _build_tower_positions(
			requested_simple_fence_count
			+ requested_corn_count
			+ requested_agave_count
		)
		_expect(
			building_fixture_positions.size()
			== requested_simple_fence_count
			+ requested_corn_count
			+ requested_agave_count,
			"The scenario must reserve every in-field building position."
		)
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
	if requested_scenario_id == "host_client_proxy_1000":
		await _spawn_client_proxy_fixture()
		if client_proxy_runtime == null or client_proxy_coordinator == null:
			await _finish()
			return
	_stagger_tower_attack_timers()

	print(
		(
			"TOWER_DEFENSE_ENEMY_COHORT_FIXTURE source=%s display_name=%s "
			+ "phase=%s enemies=%d fences=%d corn=%d agave=%d warmup=%d samples=%d "
			+ "setup_ms=%.3f tower_setup_ms=%.3f runtime_setup_ms=%.3f "
			+ "projectile_pool_registration_ms=%.3f "
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
			fixed_seed,
			Engine.max_fps,
			Engine.physics_ticks_per_second,
			RenderingServer.get_current_rendering_method(),
			RenderingServer.get_current_rendering_driver_name(),
			RenderingServer.get_video_adapter_name(),
		]
	)

	await _run_warmup_window()
	print("TOWER_DEFENSE_ENEMY_COHORT_MEASURE_BEGIN")

	var result := await _measure_sample_window(
		setup_ms,
		tower_setup_ms,
		runtime_setup_ms,
		projectile_pool_startup
	)
	print("TOWER_DEFENSE_ENEMY_COHORT_MEASURE_END")
	print("TOWER_DEFENSE_ENEMY_COHORT_RESULT %s" % JSON.stringify(result))
	await _finish()


func _uses_in_field_building_fixture() -> bool:
	return (
		_uses_formal_runtime_fixture()
		and requested_simple_fence_count
		+ requested_corn_count
		+ requested_agave_count > 0
	)


func _run_warmup_window() -> void:
	var previous_physics_frame := Engine.get_physics_frames()
	for _warmup_index in range(warmup_frames):
		_step_client_proxy_fixture()
		if requested_authoritative_tick_sampling:
			await physics_frame
			var current_physics_frame := Engine.get_physics_frames()
			_expect(
				current_physics_frame - previous_physics_frame == 1,
				"Authoritative warmup must advance exactly one physics tick per sample."
			)
			previous_physics_frame = current_physics_frame
		else:
			await process_frame
		_drive_player_movement()


func _prepare_runtime() -> void:
	game.enemy_spawn_timer.stop()
	game.state_timer.stop()
	if _uses_formal_runtime_fixture():
		# The formal A/B fixture represents the first night itself, not the quiet
		# PRE_WAVE daylight that happens to precede it in the production scene. It
		# also exercises the Host-authoritative identity path configured before the
		# scene entered SceneTree; every fixture enemy then enters through
		# register_external_enemy/finalize_authoritative_enemy_spawn below.
		formal_flow_config = load(_get_formal_flow_step_path()) as WaveConfig
		_expect(formal_flow_config != null, "Formal flow-step resource must load.")
		game.campaign_coordinator.current_flow_step = formal_flow_config
		game.campaign_coordinator.wave_state = CombatFlowState.State.WAVE_ACTIVE
		game.campaign_coordinator.current_wave_index = 0
		game.enemy_coordinator.clear_queue()
		game.enemy_coordinator.clear_active_enemies()
		game.enemy_coordinator.clear_hud_alive_enemies()
		game.clear_network_enemy_registry()
		game.enemy_coordinator.next_multiplayer_enemy_net_id = 1
		game.campaign_coordinator.reset_wave_progress(requested_enemy_count)
		# Timers remain stopped so the fixed cohort is the only spawn workload.
		game.day_night_controller.set_night_factor_immediate(1.0)
	game.maximum_base_health = BASE_PROBE_HEALTH
	game.current_base_health = BASE_PROBE_HEALTH
	game.player.global_position = FIXTURE_CENTER
	game.player.velocity = Vector2.ZERO
	game.player.set_controls_locked(false)
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
			game.player.set_controls_locked(true)
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
	if (
		_uses_in_field_building_fixture()
		and building_fixture_positions.size() < requested_simple_fence_count
	):
		_expect(false, "The in-field fence fixture has insufficient reserved positions.")
		return
	if requested_simple_fence_ab_metrics:
		plant_system.set_plant_target_query_metrics_enabled(true)
		plant_system.set_enemy_target_query_metrics_enabled(true)

	# Custom diagnostics keep fences far from combat. Formal first-night A/B uses
	# reserved production-map cells so all 100 buildings contribute their real
	# scene, collision and target-index cost inside the active field.
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
		if _uses_in_field_building_fixture():
			cell = pathfinder.call(
				"_global_to_map",
				building_fixture_positions[fence_index]
			) as Vector2i
			for y_offset in range(-1, 2):
				for x_offset in range(-1, 2):
					forbidden_enemy_cells[cell + Vector2i(x_offset, y_offset)] = true
		var fence := plant_system.spawn_multiplayer_replica(
			&"simple_fence",
			cell,
			null,
			SIMPLE_FENCE_NET_ID_BASE + fence_index,
			PLANT_PROBE_HEALTH,
			PLANT_PROBE_HEALTH,
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
		"placement_scope": (
			"in_field" if _uses_in_field_building_fixture() else "far_non_contact"
		),
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


func _count_nodes_with_script_path(node: Node, script_path: String) -> int:
	var total := 0
	var node_script := node.get_script() as Script
	if node_script != null and node_script.resource_path == script_path:
		total += 1
	for child in node.get_children():
		total += _count_nodes_with_script_path(child, script_path)
	return total


func _cohort_contains_mage_config() -> bool:
	for config in cohort_configs:
		if config is CapooMageConfig:
			return true
	return false


func _build_mage_activity_window(before: Dictionary, after: Dictionary) -> Dictionary:
	var before_simulation := before.get(
		"capoo_mage_fireball_simulation",
		{}
	) as Dictionary
	var after_simulation := after.get(
		"capoo_mage_fireball_simulation",
		{}
	) as Dictionary
	var before_completions := (
		int(before_simulation.get("world_completions", 0))
		+ int(before_simulation.get("direct_completions", 0))
		+ int(before_simulation.get("lifetime_completions", 0))
	)
	var after_completions := (
		int(after_simulation.get("world_completions", 0))
		+ int(after_simulation.get("direct_completions", 0))
		+ int(after_simulation.get("lifetime_completions", 0))
	)
	return {
		"spawns": (
			int(after_simulation.get("spawns", 0))
			- int(before_simulation.get("spawns", 0))
		),
		"advances": (
			int(after_simulation.get("advances", 0))
			- int(before_simulation.get("advances", 0))
		),
		"direct_queries": (
			int(after_simulation.get("direct_queries", 0))
			- int(before_simulation.get("direct_queries", 0))
		),
		"completions": after_completions - before_completions,
		"damage_accepts": (
			int(after.get("mage_damage_accepts", 0))
			- int(before.get("mage_damage_accepts", 0))
		),
		"presentation_requests": (
			int(after.get("mage_presentation_requests", 0))
			- int(before.get("mage_presentation_requests", 0))
		),
	}


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
	var plant_system := game.plant_system as PlantSystem
	_expect(
		plant_system != null,
		"The production tower cohort requires PlantSystem."
	)
	if plant_system == null:
		return
	var positions := PackedVector2Array()
	if _uses_in_field_building_fixture():
		for position_index in range(total_tower_count):
			var source_index := requested_simple_fence_count + position_index
			if source_index >= building_fixture_positions.size():
				break
			positions.append(building_fixture_positions[source_index])
	else:
		positions = _build_tower_positions(total_tower_count)
	_expect(
		positions.size() >= total_tower_count,
		"The production map must provide every requested tower cell."
	)
	if positions.size() < total_tower_count:
		return

	for tower_index in range(total_tower_count):
		var tower_position := positions[tower_index]
		var tower_cell := pathfinder.call("_global_to_map", tower_position) as Vector2i
		for y_offset in range(-1, 2):
			for x_offset in range(-1, 2):
				forbidden_enemy_cells[tower_cell + Vector2i(x_offset, y_offset)] = true

		if tower_index < requested_corn_count:
			var corn := plant_system._instantiate_registered_plant(
				CORN_CONFIG,
				tower_cell,
				game.player,
				tower_index + 1,
				false,
				PLANT_PROBE_HEALTH,
				0,
				PLANT_PROBE_HEALTH,
				false
			) as CornMachineGun
			if corn == null:
				continue
			corn.set_idle_aim_random_seed(fixed_seed + tower_index)
			corn_towers.append(corn)
			continue

		var agave := plant_system._instantiate_registered_plant(
			AGAVE_CONFIG,
			tower_cell,
			game.player,
			tower_index + 1,
			false,
			PLANT_PROBE_HEALTH,
			0,
			PLANT_PROBE_HEALTH,
			false
		) as AgaveCannon
		if agave == null:
			continue
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
		if _uses_formal_runtime_fixture():
			var enemy_id := enemy.get_instance_id()
			var registered_in_wave := game.enemy_coordinator.register_external_enemy(
				enemy,
				WaveEnemyTerminalLedger.EnemyRole.OBJECTIVE
			)
			_expect(
				registered_in_wave,
				"Every formal cohort enemy must register in the production wave ledger."
			)
			if not registered_in_wave:
				enemy.queue_free()
				continue
			enemy.defeated.connect(Callable(
				game.enemy_coordinator,
				&"_on_wave_enemy_defeated"
			))
			enemy.tree_exited.connect(
				game.enemy_coordinator.handle_wave_enemy_tree_exited.bind(enemy_id)
			)
			var enemy_net_id := (
				game.enemy_coordinator.finalize_authoritative_enemy_spawn(
					enemy,
					current_enemy_config,
					enemy.global_position,
					true
				)
			)
			_expect(
				enemy_net_id > 0,
				"Every formal cohort enemy must receive a production network identity."
			)
		else:
			game.enemy_coordinator.configure_authoritative_enemy_physics_interpolation(
				enemy
			)
		if is_boss:
			(enemy as LinglanBoss).activate_boss(game.player, pathfinder)
		enemy.velocity = Vector2.ZERO
		# Pause through the simulation ownership boundary. Directly toggling the
		# Node callback would accidentally re-enable an empty per-enemy callback in
		# centralized modes and contaminate the A/B result.
		enemy.set_authoritative_simulation_enabled(false)
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
	_configure_formal_scenario_adapter()
	for enemy in enemies:
		enemy.set_authoritative_simulation_enabled(true)
		enemy.reset_physics_interpolation()

	for _settle_index in range(3):
		await process_frame
		await physics_frame
	if _uses_formal_runtime_fixture():
		formal_registration_fingerprint_before_measurement = (
			_capture_formal_registration_fingerprint()
		)
		_validate_formal_registration_fingerprint(
			formal_registration_fingerprint_before_measurement,
			"before_measurement"
		)


func _configure_formal_scenario_adapter() -> void:
	if not _uses_formal_runtime_fixture():
		return
	scenario_contract = {
		"fixture_kind": _get_scenario_fixture_kind(),
		"flow_step_path": _get_formal_flow_step_path(),
		"host_configured_before_tree": host_runtime_configured_before_tree,
		"host_authority_verified": (
			game.runtime_mode == CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY
		),
		"host_enemy_count": enemies.size(),
		"allied_enemy_count": 0,
		"hostile_enemy_count": enemies.size(),
		"unreachable_assignment_count": 0,
		"client_proxy_count": 0,
		"client_index_count": 0,
		"client_authoritative_registered_count": 0,
		"client_proxy_start": {},
		"client_proxy_end": {},
		"client_authoritative_attack_delta": 0,
		"client_authoritative_damage_delta": 0,
		"client_authoritative_kill_delta": 0,
		"client_authoritative_reward_delta": 0,
		"basic_pursuit_count": 0,
		"tower_count": corn_towers.size() + agave_towers.size(),
		"projectile_pressure_verified": false,
		"tower_total_shots": 0,
		"tower_agave_projectile_shots": 0,
		"tower_peak_concurrent_projectiles": 0,
		"paired_dynamic_target_count": 0,
		"faction_valid_dynamic_targets_start": {},
		"faction_valid_dynamic_targets_end": {},
		"faction_damage_taken": {},
		"water_target_verified": false,
		"disconnected_connectivity_verified": false,
	}
	_expect(
		host_runtime_configured_before_tree,
		"Formal A/B runtime must configure Host authority before entering SceneTree."
	)
	match requested_scenario_id:
		"basic_pursuit_300":
			scenario_contract["basic_pursuit_count"] = _count_basic_pursuit_enemies()
		"faction_battle_150v150":
			_configure_faction_battle_adapter()
		"obstacle_water_unreachable":
			_configure_water_unreachable_adapter()


func _count_basic_pursuit_enemies() -> int:
	var count := 0
	for enemy in enemies:
		if enemy != null and enemy.config != null and enemy.config.resource_path == DEFAULT_ENEMY_CONFIG_PATH:
			count += 1
	return count


func _configure_faction_battle_adapter() -> void:
	_expect(enemies.size() == FACTION_BATTLE_SIZE * 2, "Faction adapter requires 150v150 enemies.")
	if enemies.size() != FACTION_BATTLE_SIZE * 2:
		return
	var paired_target_count := 0
	for pair_index in range(FACTION_BATTLE_SIZE):
		var allied := enemies[pair_index]
		var hostile := enemies[FACTION_BATTLE_SIZE + pair_index]
		allied.set_combat_faction_id(CombatRelationService.PLAYER_ALLIED)
		if allied.consider_automatic_combat_target(hostile, 1):
			paired_target_count += 1
		if hostile.consider_automatic_combat_target(allied, 1):
			paired_target_count += 1
	scenario_contract["allied_enemy_count"] = _count_enemies_in_faction(
		CombatRelationService.PLAYER_ALLIED
	)
	scenario_contract["hostile_enemy_count"] = _count_enemies_in_faction(
		CombatRelationService.HOSTILE_WAVE
	)
	scenario_contract["paired_dynamic_target_count"] = paired_target_count
	_expect(
		paired_target_count == FACTION_BATTLE_SIZE * 2,
		"Faction adapter must assign all 300 paired dynamic targets."
	)


func _configure_water_unreachable_adapter() -> void:
	_expect(enemies.size() == 300, "Water-unreachable adapter requires 300 enemies.")
	if enemies.size() != 300:
		return
	var target := enemies[0]
	var source := enemies[1]
	target.set_combat_faction_id(CombatRelationService.PLAYER_ALLIED)
	target.add_move_speed_modifier(UNREACHABLE_TARGET_SLOW_SOURCE_ID, 0.0)
	var profile := source.call("_get_navigation_agent_profile") as GridPathfinder.AgentNavigationProfile
	_expect(profile != null, "Water-unreachable adapter requires a published navigation profile.")
	if profile == null:
		return
	var water_target_position := _find_disconnected_water_target_position(
		source,
		target,
		profile
	)
	_expect(
		water_target_position.is_finite() and water_target_position != Vector2.INF,
		"Production navigation must provide a disconnected water target cell."
	)
	if not water_target_position.is_finite() or water_target_position == Vector2.INF:
		return
	target.global_position = water_target_position
	target.reset_physics_interpolation()
	var descriptor := CombatTargetDescriptor.create_enemy(
		target.combat_target_index_net_id,
		target.get_faction_revision(),
		water_target_position
	)
	var assignment_count := 0
	for enemy_index in range(1, enemies.size()):
		if enemies[enemy_index].apply_designated_combat_target(descriptor, 1):
			assignment_count += 1
	var connectivity := pathfinder.classify_dynamic_target_connectivity_with_profile(
		source.global_position,
		water_target_position,
		source.get_dynamic_target_contact_goal_radius(target),
		profile
	)
	scenario_contract["allied_enemy_count"] = 1
	scenario_contract["hostile_enemy_count"] = 299
	scenario_contract["unreachable_assignment_count"] = assignment_count
	scenario_contract["water_target_verified"] = true
	scenario_contract["disconnected_connectivity_verified"] = (
		connectivity == GridPathfinder.NavigationConnectivityStatus.DISCONNECTED
	)
	_expect(assignment_count == 299, "All hostile enemies must receive the unreachable target.")
	_expect(
		connectivity == GridPathfinder.NavigationConnectivityStatus.DISCONNECTED,
		"The authored water target must be navigation-disconnected."
	)


func _find_disconnected_water_target_position(
	source: Enemy,
	target: Enemy,
	profile: GridPathfinder.AgentNavigationProfile
) -> Vector2:
	var region := profile.solid_integral_snapshot.region
	for cell_y in range(region.position.y, region.end.y):
		for cell_x in range(region.position.x, region.end.x):
			var cell := Vector2i(cell_x, cell_y)
			if not profile.path_grid.is_point_solid(cell):
				continue
			var traversal_flags := int(pathfinder.call(
				"_get_live_terrain_traversal_flags",
				cell
			))
			if (
				traversal_flags & DualGridTilemap.TraversalType.WATER
			) == 0:
				continue
			var candidate := pathfinder.call("_map_to_global", cell) as Vector2
			var connectivity := pathfinder.classify_dynamic_target_connectivity_with_profile(
				source.global_position,
				candidate,
				source.get_dynamic_target_contact_goal_radius(target),
				profile
			)
			if connectivity == GridPathfinder.NavigationConnectivityStatus.DISCONNECTED:
				return candidate
	return Vector2.INF


func _count_enemies_in_faction(faction_id: int) -> int:
	var count := 0
	for enemy in enemies:
		if enemy != null and enemy.get_combat_faction_id() == faction_id:
			count += 1
	return count


func _capture_faction_battle_state() -> Dictionary:
	var result := {
		"allied_count": 0,
		"hostile_count": 0,
		"allied_valid_dynamic_targets": 0,
		"hostile_valid_dynamic_targets": 0,
		"allied_total_health": 0,
		"hostile_total_health": 0,
		"health_by_index": {},
	}
	var relation_service := game.get_combat_relation_service()
	for enemy_index in range(enemies.size()):
		var enemy := enemies[enemy_index]
		if enemy == null or not is_instance_valid(enemy) or enemy.is_dead:
			continue
		var faction_id := enemy.get_combat_faction_id()
		if faction_id == CombatRelationService.PLAYER_ALLIED:
			result["allied_count"] = int(result["allied_count"]) + 1
			result["allied_total_health"] = (
				int(result["allied_total_health"]) + enemy.current_health
			)
		elif faction_id == CombatRelationService.HOSTILE_WAVE:
			result["hostile_count"] = int(result["hostile_count"]) + 1
			result["hostile_total_health"] = (
				int(result["hostile_total_health"]) + enemy.current_health
			)
		else:
			continue
		var health_by_index := result["health_by_index"] as Dictionary
		health_by_index[enemy_index] = enemy.current_health
		var dynamic_target := enemy.objective_target as Enemy
		if (
			dynamic_target == null
			or not is_instance_valid(dynamic_target)
			or dynamic_target.is_dead
			or relation_service == null
			or not relation_service.is_hostile(
				faction_id,
				dynamic_target.get_combat_faction_id()
			)
			or not enemy.can_attack_combat_target(dynamic_target)
		):
			continue
		if faction_id == CombatRelationService.PLAYER_ALLIED:
			result["allied_valid_dynamic_targets"] = (
				int(result["allied_valid_dynamic_targets"]) + 1
			)
		else:
			result["hostile_valid_dynamic_targets"] = (
				int(result["hostile_valid_dynamic_targets"]) + 1
			)
	return result


func _build_faction_damage_evidence(
	before: Dictionary,
	after: Dictionary
) -> Dictionary:
	var before_health := before.get("health_by_index", {}) as Dictionary
	var after_health := after.get("health_by_index", {}) as Dictionary
	var allied_damaged_count := 0
	var hostile_damaged_count := 0
	for enemy_index_variant in before_health:
		var enemy_index := int(enemy_index_variant)
		var damage_taken := maxi(
			int(before_health.get(enemy_index, 0))
			- int(after_health.get(enemy_index, 0)),
			0
		)
		if damage_taken <= 0 or enemy_index < 0 or enemy_index >= enemies.size():
			continue
		var enemy := enemies[enemy_index]
		if enemy == null or not is_instance_valid(enemy):
			continue
		if enemy.get_combat_faction_id() == CombatRelationService.PLAYER_ALLIED:
			allied_damaged_count += 1
		elif enemy.get_combat_faction_id() == CombatRelationService.HOSTILE_WAVE:
			hostile_damaged_count += 1
	return {
		"allied_damage_taken": maxi(
			int(before.get("allied_total_health", 0))
			- int(after.get("allied_total_health", 0)),
			0
		),
		"hostile_damage_taken": maxi(
			int(before.get("hostile_total_health", 0))
			- int(after.get("hostile_total_health", 0)),
			0
		),
		"allied_damaged_enemy_count": allied_damaged_count,
		"hostile_damaged_enemy_count": hostile_damaged_count,
	}


func _get_agave_projectile_generation_total() -> int:
	if game == null or game.session_object_pool == null:
		return 0
	var total := 0
	for child in game.session_object_pool.get_children():
		if (
			str(child.get_meta(SessionObjectPool.POOL_KEY_META, ""))
			== AGAVE_CANNONBALL_POOL_PATH
		):
			total += int(child.get_meta(SessionObjectPool.POOL_GENERATION_META, 0))
	return total


func _get_agave_projectile_in_use_count() -> int:
	if game == null or game.session_object_pool == null:
		return 0
	return int(
		game.session_object_pool.get_metrics(
			AGAVE_CANNONBALL_POOL_PATH
		).get("in_use", 0)
	)


func _spawn_client_proxy_fixture() -> void:
	client_proxy_target_assignment_events = 0
	client_proxy_damage_broadcast_events = 0
	client_proxy_defeat_events = 0
	client_proxy_runtime = CLIENT_RUNTIME_SCENE.instantiate() as EnemyGameplayGatewayTestRuntime
	client_proxy_coordinator = (
		MP_ENEMY_COORDINATOR_SCENE.instantiate() as MpEnemyCoordinator
	)
	_expect(
		client_proxy_runtime != null and client_proxy_coordinator != null,
		"Host/client adapter must instantiate the authored client runtime and coordinator."
	)
	if client_proxy_runtime == null or client_proxy_coordinator == null:
		return
	client_proxy_runtime.runtime_mode = CombatRuntimeBase.RuntimeMode.CLIENT_VIEW
	root.add_child(client_proxy_runtime)
	root.add_child(client_proxy_coordinator)
	client_proxy_coordinator.bind_runtime(client_proxy_runtime)
	await process_frame
	client_proxy_snapshot_sender = SnapshotManager.new()
	client_proxy_snapshot_states.resize(CLIENT_PROXY_COUNT)
	for proxy_index in range(CLIENT_PROXY_COUNT):
		var column := proxy_index % CLIENT_PROXY_POSITION_COLUMNS
		var row := floori(float(proxy_index) / float(CLIENT_PROXY_POSITION_COLUMNS))
		var initial_position := Vector2(
			float(column - 20) * CLIENT_PROXY_POSITION_SPACING,
			float(row - 12) * CLIENT_PROXY_POSITION_SPACING
		)
		var state := SnapshotManager.EnemyState.new()
		state.net_id = CLIENT_PROXY_NET_ID_BASE + proxy_index
		state.position = initial_position
		state.velocity = Vector2(12.0, 0.0)
		state.locomotion_state = Enemy.LocomotionState.MOVING
		state.health = CLIENT_PROXY_SNAPSHOT_HEALTH
		state.health_revision = 1
		state.is_dead = false
		state.visual_status_mask = 0
		state.faction_id = CombatRelationService.HOSTILE_WAVE
		state.faction_revision = 0
		client_proxy_snapshot_states[proxy_index] = state
	_spawn_client_proxy_batches()
	for net_id in client_proxy_coordinator.get_remote_enemy_ids():
		var proxy := client_proxy_coordinator.get_valid_client_enemy(net_id)
		if proxy == null:
			continue
		if not proxy.objective_target_changed.is_connected(
			_on_client_proxy_objective_target_changed
		):
			proxy.objective_target_changed.connect(
				_on_client_proxy_objective_target_changed
			)
		if not proxy.defeated.is_connected(_on_client_proxy_defeated):
			proxy.defeated.connect(_on_client_proxy_defeated)
	if not client_proxy_coordinator.damage_rpc_broadcast_requested.is_connected(
		_on_client_proxy_damage_rpc_broadcast_requested
	):
		client_proxy_coordinator.damage_rpc_broadcast_requested.connect(
			_on_client_proxy_damage_rpc_broadcast_requested
		)
	var client_simulation := client_proxy_runtime.get_enemy_simulation_coordinator()
	var client_registered := (
		int(client_simulation.get_metrics().get("registered_count", -1))
		if client_simulation != null
		else -1
	)
	var proxy_count := client_proxy_coordinator.get_remote_enemy_count()
	var client_index_count: int = int(
		client_proxy_runtime.combat_target_index.enemies_by_net_id.size()
	)
	_expect(
		proxy_count == CLIENT_PROXY_COUNT
		and client_proxy_runtime.get_network_enemy_count() == CLIENT_PROXY_COUNT
		and client_index_count == CLIENT_PROXY_COUNT,
		"Host/client adapter must register exactly 1,000 real client proxies."
	)
	_expect(
		client_registered == 0,
		"CLIENT_VIEW must keep the authored AI coordinator at zero registrations."
	)
	scenario_contract["client_proxy_count"] = proxy_count
	scenario_contract["client_index_count"] = client_index_count
	scenario_contract["client_authoritative_registered_count"] = client_registered


func _on_client_proxy_objective_target_changed(
	_enemy: Enemy,
	current_target: Node2D
) -> void:
	if current_target != null:
		client_proxy_target_assignment_events += 1


func _on_client_proxy_damage_rpc_broadcast_requested(
	_method_name: StringName,
	_arguments: Array
) -> void:
	client_proxy_damage_broadcast_events += 1


func _on_client_proxy_defeated(_enemy: Enemy) -> void:
	client_proxy_defeat_events += 1


func _capture_client_proxy_authority_state() -> Dictionary:
	var result := {
		"proxy_count": -1,
		"network_count": -1,
		"index_count": -1,
		"proxy_true_count": 0,
		"process_disabled_count": 0,
		"physics_process_disabled_count": 0,
		"area_count": 0,
		"monitoring_area_count": 0,
		"simulation_registered_count": -1,
		"contact_registered_count": -1,
		"authoritative_attack_state_count": 0,
		"authoritative_damage_state_count": 0,
		"dead_count": 0,
		"total_health": 0,
		"target_assignment_events": client_proxy_target_assignment_events,
		"damage_broadcast_events": client_proxy_damage_broadcast_events,
		"defeat_events": client_proxy_defeat_events,
		"pending_reward": 0,
		"reward_flush_queued": false,
	}
	if client_proxy_runtime == null or client_proxy_coordinator == null:
		return result
	result["proxy_count"] = client_proxy_coordinator.get_remote_enemy_count()
	result["network_count"] = client_proxy_runtime.get_network_enemy_count()
	result["index_count"] = (
		client_proxy_runtime.combat_target_index.enemies_by_net_id.size()
	)
	var simulation := client_proxy_runtime.get_enemy_simulation_coordinator()
	if simulation != null:
		result["simulation_registered_count"] = int(
			simulation.get_metrics().get("registered_count", -1)
		)
	var contact_service := client_proxy_runtime.get_enemy_contact_service()
	if contact_service != null:
		result["contact_registered_count"] = int(
			contact_service.get_metrics().get("registered_count", -1)
		)
	result["pending_reward"] = client_proxy_runtime._pending_xirang_kill_reward
	result["reward_flush_queued"] = client_proxy_runtime._xirang_kill_reward_flush_queued
	for net_id in client_proxy_coordinator.get_remote_enemy_ids():
		var proxy := client_proxy_coordinator.get_valid_client_enemy(net_id)
		if proxy == null or not is_instance_valid(proxy):
			continue
		if proxy.is_multiplayer_proxy:
			result["proxy_true_count"] = int(result["proxy_true_count"]) + 1
		if not proxy.is_processing():
			result["process_disabled_count"] = (
				int(result["process_disabled_count"]) + 1
			)
		if not proxy.is_physics_processing():
			result["physics_process_disabled_count"] = (
				int(result["physics_process_disabled_count"]) + 1
			)
		if (
			proxy.objective_target != null
			or proxy.target_player != null
			or proxy.dynamic_targeting_state_active
			or proxy.touch_damage_cooldown_left > 0.0
		):
			result["authoritative_attack_state_count"] = (
				int(result["authoritative_attack_state_count"]) + 1
			)
		if proxy.last_damage_taken != 0 or proxy.last_damage_result != null:
			result["authoritative_damage_state_count"] = (
				int(result["authoritative_damage_state_count"]) + 1
			)
		if proxy.is_dead:
			result["dead_count"] = int(result["dead_count"]) + 1
		result["total_health"] = int(result["total_health"]) + proxy.current_health
		var area_nodes := proxy.find_children("*", "Area2D", true, false)
		result["area_count"] = int(result["area_count"]) + area_nodes.size()
		for area_node in area_nodes:
			var area := area_node as Area2D
			if area != null and area.monitoring:
				result["monitoring_area_count"] = (
					int(result["monitoring_area_count"]) + 1
				)
	return result


func _spawn_client_proxy_batches() -> void:
	var batch_size := MpEnemyCoordinator.ENEMY_SPAWN_BATCH_MAX_RECORDS
	for batch_start in range(0, CLIENT_PROXY_COUNT, batch_size):
		var batch_end := mini(batch_start + batch_size, CLIENT_PROXY_COUNT)
		var net_ids := PackedInt32Array()
		var config_paths := PackedStringArray()
		var positions := PackedVector2Array()
		var spawn_times := PackedFloat64Array()
		var faction_ids := PackedByteArray()
		var faction_revisions := PackedInt32Array()
		for proxy_index in range(batch_start, batch_end):
			var state := client_proxy_snapshot_states[proxy_index]
			net_ids.append(state.net_id)
			config_paths.append(DEFAULT_ENEMY_CONFIG_PATH)
			positions.append(state.position)
			spawn_times.append(1.0)
			faction_ids.append(CombatRelationService.HOSTILE_WAVE)
			faction_revisions.append(0)
		client_proxy_coordinator.receive_enemy_spawn_batch(
			net_ids,
			config_paths,
			positions,
			spawn_times,
			1.0,
			false,
			0.0,
			faction_ids,
			faction_revisions,
			true
		)


func _step_client_proxy_fixture() -> void:
	if client_proxy_runtime == null or client_proxy_coordinator == null:
		return
	client_proxy_fixture_tick += 1
	var sample_tick := client_proxy_fixture_tick
	if sample_tick % 3 != 0:
		client_proxy_coordinator.interpolate_remote_enemies(
			2.0 + float(sample_tick) / 60.0
		)
		return
	client_proxy_snapshot_sequence += 1
	var offset_sign := 1.0 if client_proxy_snapshot_sequence % 2 == 0 else -1.0
	for proxy_index in range(CLIENT_PROXY_COUNT):
		var state := client_proxy_snapshot_states[proxy_index]
		state.position.x += 40.0 * offset_sign
		state.position.y += 24.0 * offset_sign
		state.health_revision = client_proxy_snapshot_sequence
	var records_per_chunk := MpEnemyCoordinator.ENEMY_SNAPSHOT_CHUNK_MAX_ENTITIES
	var chunk_count := ceili(
		float(CLIENT_PROXY_COUNT) / float(records_per_chunk)
	)
	var snapshot_timestamp := 2.0 + float(sample_tick) / 60.0
	for chunk_index in range(chunk_count):
		var chunk_start := chunk_index * records_per_chunk
		var chunk_size := mini(
			records_per_chunk,
			CLIENT_PROXY_COUNT - chunk_start
		)
		var data := client_proxy_snapshot_sender.encode_enemy_snapshot_range_for_cohort(
			-77,
			client_proxy_snapshot_states,
			chunk_start,
			chunk_size,
			true
		)
		client_proxy_coordinator.apply_authoritative_snapshot(
			snapshot_timestamp,
			data,
			CLIENT_PROXY_SNAPSHOT_BATCH_ID_BASE + client_proxy_snapshot_sequence,
			chunk_index,
			chunk_count,
			CLIENT_PROXY_SNAPSHOT_HZ,
			snapshot_timestamp
		)
	client_proxy_coordinator.interpolate_remote_enemies(snapshot_timestamp + 0.05)
	client_proxy_coordinator.update_proxy_visual_budget(1.0 / 60.0)


func _dispose_client_proxy_fixture() -> void:
	if client_proxy_coordinator != null and is_instance_valid(client_proxy_coordinator):
		client_proxy_coordinator.reset_session_state()
		client_proxy_coordinator.unbind_runtime(client_proxy_runtime)
		client_proxy_coordinator.queue_free()
	if client_proxy_runtime != null and is_instance_valid(client_proxy_runtime):
		client_proxy_runtime.queue_free()
	client_proxy_snapshot_states.clear()
	client_proxy_snapshot_sender = null
	client_proxy_coordinator = null
	client_proxy_runtime = null
	client_proxy_fixture_tick = 0
	client_proxy_target_assignment_events = 0
	client_proxy_damage_broadcast_events = 0
	client_proxy_defeat_events = 0
	await process_frame


func _capture_formal_registration_fingerprint() -> Dictionary:
	var ledger := game.campaign_coordinator.wave_enemy_terminal_ledger
	var ledger_snapshot := ledger.get_snapshot()
	var plant_index := game.enemy_coordinator.get_plant_objective_index_metrics()
	var network_ids := game.get_network_enemy_ids()
	network_ids.sort()
	var combat_ids: Array[int] = []
	for net_id_variant in game.combat_target_index.enemies_by_net_id:
		combat_ids.append(int(net_id_variant))
	combat_ids.sort()
	var cross_store_mapping_count := 0
	var ledger_mapping_count := 0
	var reverse_mapping_count := 0
	for net_id in network_ids:
		var network_enemy := game.get_network_enemy(net_id)
		if network_enemy == null or not is_instance_valid(network_enemy):
			continue
		if game.combat_target_index.enemies_by_net_id.get(net_id) == network_enemy:
			cross_store_mapping_count += 1
		if ledger.has_enemy(network_enemy.get_instance_id()):
			ledger_mapping_count += 1
		if (
			game.get_network_enemy_net_id_by_instance_id(
				network_enemy.get_instance_id()
			)
			== net_id
		):
			reverse_mapping_count += 1
	var expected_network_ids: Array[int] = []
	for expected_net_id in range(1, requested_enemy_count + 1):
		expected_network_ids.append(expected_net_id)
	var combat_registered_count: int = (
		game.combat_target_index.enemies_by_net_id.size()
	)
	var network_registered_count: int = network_ids.size()
	var ledger_attached_count: int = ledger.get_attached_enemy_count()
	return {
		"runtime_mode": int(game.runtime_mode),
		"current_flow_step_path": (
			game.campaign_coordinator.current_flow_step.resource_path
			if game.campaign_coordinator.current_flow_step != null
			else ""
		),
		"ledger": {
			"snapshot": ledger_snapshot,
			"active_count": ledger.get_active_enemy_count(),
			"attached_count": ledger_attached_count,
		},
		"plant_objective_index": plant_index,
		"network_registry": {
			"registered_count": network_registered_count,
			"net_ids_hash": hash(network_ids),
			"continuous_initial_ids": network_ids == expected_network_ids,
			"reverse_mapping_count": reverse_mapping_count,
		},
		"combat_target_index": {
			"registered_count": combat_registered_count,
			"net_ids_hash": hash(combat_ids),
			"bucket_mapping_count": game.combat_target_index.bucket_by_net_id.size(),
			"bucket_slot_count": game.combat_target_index.bucket_slot_by_net_id.size(),
			"faction_mapping_count": game.combat_target_index.faction_by_net_id.size(),
			"faction_slot_count": (
				game.combat_target_index.faction_bucket_slot_by_net_id.size()
			),
			"safety_audit_count": game.combat_target_index.safety_audit_net_ids.size(),
		},
		"cross_store": {
			"combat_mapping_count": cross_store_mapping_count,
			"ledger_mapping_count": ledger_mapping_count,
			"network_and_combat_ids_match": network_ids == combat_ids,
			"attached_and_network_counts_match": (
				ledger_attached_count == network_registered_count
			),
		},
	}


func _validate_formal_registration_fingerprint(
	fingerprint: Dictionary,
	stage: String
) -> void:
	var ledger := fingerprint.get("ledger", {}) as Dictionary
	var ledger_snapshot := ledger.get("snapshot", {}) as Dictionary
	var plant_index := fingerprint.get("plant_objective_index", {}) as Dictionary
	var network_registry := fingerprint.get("network_registry", {}) as Dictionary
	var combat_index := fingerprint.get("combat_target_index", {}) as Dictionary
	var cross_store := fingerprint.get("cross_store", {}) as Dictionary
	var network_count := int(network_registry.get("registered_count", -1))
	var combat_count := int(combat_index.get("registered_count", -1))
	var attached_count := int(ledger.get("attached_count", -1))
	var tracked_count := int(plant_index.get("tracked_enemies", -1))
	_expect(
		int(fingerprint.get("runtime_mode", -1))
		== CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY,
		"Formal registration fingerprint %s must use Host authority." % stage
	)
	_expect(
		str(fingerprint.get("current_flow_step_path", ""))
		== _get_formal_flow_step_path(),
		"Formal registration fingerprint %s must retain its declared current_flow_step."
		% stage
	)
	_expect(
		int(ledger_snapshot.get("total", -1)) == requested_enemy_count
		and int(ledger_snapshot.get("spawned", -1)) == requested_enemy_count,
		"Formal registration fingerprint %s must retain the complete wave ledger."
		% stage
	)
	_expect(
		network_count == combat_count
		and attached_count == network_count
		and tracked_count == attached_count,
		(
			"Formal registration fingerprint %s must keep ledger, plant, network "
			+ "and combat-index membership aligned."
		)
		% stage
	)
	_expect(
		int(network_registry.get("reverse_mapping_count", -1)) == network_count
		and int(cross_store.get("combat_mapping_count", -1)) == network_count
		and int(cross_store.get("ledger_mapping_count", -1)) == network_count
		and bool(cross_store.get("network_and_combat_ids_match", false))
		and bool(cross_store.get("attached_and_network_counts_match", false)),
		"Formal registration fingerprint %s must preserve every cross-store identity."
		% stage
	)
	_expect(
		int(combat_index.get("bucket_mapping_count", -1)) == combat_count
		and int(combat_index.get("bucket_slot_count", -1)) == combat_count
		and int(combat_index.get("faction_mapping_count", -1)) == combat_count
		and int(combat_index.get("faction_slot_count", -1)) == combat_count
		and int(combat_index.get("safety_audit_count", -1)) == combat_count,
		"Formal registration fingerprint %s must preserve CombatTargetIndex structure."
		% stage
	)
	if stage == "before_measurement":
		_expect(
			network_count == requested_enemy_count
			and int(ledger.get("active_count", -1)) == requested_enemy_count
			and bool(network_registry.get("continuous_initial_ids", false)),
			"Formal registration fingerprint must start with the fixed complete cohort."
		)


func _determinize_runtime_random_streams_after_ready() -> void:
	_expect(
		game != null and game.is_node_ready(),
		"Runtime RNG determinization must happen after TowerDefenseGame._ready()."
	)
	if game == null or not game.is_node_ready():
		return
	# Global helpers are used by a few legacy presentation paths; reseed them too,
	# but the auditable gameplay contract below is composed only of explicit RNG
	# objects whose exact state can be captured without consuming a value.
	seed(fixed_seed)
	game.random_generator.seed = fixed_seed
	_expect(
		game.fate_coordinator != null and game.fate_manager != null,
		"Formal runtime must expose both Fate RNG owners."
	)
	if game.fate_coordinator != null:
		game.fate_coordinator.random_generator.seed = (
			fixed_seed + RUNTIME_FATE_RANDOM_SEED_OFFSET
		)
	if game.fate_manager != null:
		game.fate_manager.random_generator.seed = (
			fixed_seed + RUNTIME_FATE_MANAGER_RANDOM_SEED_OFFSET
		)
	_assert_random_stream_matches_seed(
		game.random_generator,
		fixed_seed,
		"TowerDefenseGame runtime RNG"
	)
	if game.fate_coordinator != null:
		_assert_random_stream_matches_seed(
			game.fate_coordinator.random_generator,
			fixed_seed + RUNTIME_FATE_RANDOM_SEED_OFFSET,
			"FateCoordinator RNG"
		)
	if game.fate_manager != null:
		_assert_random_stream_matches_seed(
			game.fate_manager.random_generator,
			fixed_seed + RUNTIME_FATE_MANAGER_RANDOM_SEED_OFFSET,
			"TowerDefenseFateManager RNG"
		)
	runtime_random_streams_determinized_after_ready = true


func _capture_random_stream_state(random_stream: RandomNumberGenerator) -> Dictionary:
	if random_stream == null:
		return {"seed": null, "state": null}
	return {
		"seed": random_stream.seed,
		"state": random_stream.state,
	}


func _capture_runtime_random_state_evidence() -> Dictionary:
	var enemy_behavior_states: Array[Dictionary] = []
	var enemy_drop_states: Array[Dictionary] = []
	var boss_skill_states: Array[Dictionary] = []
	for enemy_index in range(enemies.size()):
		var enemy := enemies[enemy_index]
		if enemy == null or not is_instance_valid(enemy):
			continue
		enemy_behavior_states.append({
			"index": enemy_index,
			"seed": enemy.random_generator.seed,
			"state": enemy.random_generator.state,
		})
		enemy_drop_states.append({
			"index": enemy_index,
			"seed": enemy.material_drop_random_generator.seed,
			"state": enemy.material_drop_random_generator.state,
		})
		var boss := enemy as LinglanBoss
		if boss != null:
			boss_skill_states.append({
				"index": enemy_index,
				"skill3": _capture_random_stream_state(boss.skill3_random),
				"skill4": _capture_random_stream_state(boss.skill4_random),
				"skill_order": _capture_random_stream_state(boss.skill_order_random),
			})
	var corn_idle_states: Array[Dictionary] = []
	for tower_index in range(corn_towers.size()):
		var corn := corn_towers[tower_index]
		if corn != null and is_instance_valid(corn):
			corn_idle_states.append({
				"index": tower_index,
				"seed": corn.idle_aim_random.seed,
				"state": corn.idle_aim_random.state,
			})
	var agave_idle_states: Array[Dictionary] = []
	for tower_index in range(agave_towers.size()):
		var agave := agave_towers[tower_index]
		if agave != null and is_instance_valid(agave):
			agave_idle_states.append({
				"index": tower_index,
				"seed": agave.idle_aim_random.seed,
				"state": agave.idle_aim_random.state,
			})
	return {
		"requested_seed": fixed_seed,
		"determinized_after_ready": runtime_random_streams_determinized_after_ready,
		"runtime": _capture_random_stream_state(game.random_generator),
		"fate_coordinator": _capture_random_stream_state(
			game.fate_coordinator.random_generator
			if game.fate_coordinator != null
			else null
		),
		"fate_manager": _capture_random_stream_state(
			game.fate_manager.random_generator
			if game.fate_manager != null
			else null
		),
		"enemy_behavior_states": enemy_behavior_states,
		"enemy_drop_states": enemy_drop_states,
		"boss_skill_states": boss_skill_states,
		"corn_idle_states": corn_idle_states,
		"agave_idle_states": agave_idle_states,
	}


func _validate_runtime_random_state_evidence(
	evidence: Dictionary,
	stage: String
) -> void:
	var runtime_state := evidence.get("runtime", {}) as Dictionary
	var fate_state := evidence.get("fate_coordinator", {}) as Dictionary
	var fate_manager_state := evidence.get("fate_manager", {}) as Dictionary
	var behavior_states := evidence.get("enemy_behavior_states", []) as Array
	var drop_states := evidence.get("enemy_drop_states", []) as Array
	var corn_states := evidence.get("corn_idle_states", []) as Array
	var agave_states := evidence.get("agave_idle_states", []) as Array
	_expect(
		bool(evidence.get("determinized_after_ready", false))
		and int(evidence.get("requested_seed", -1)) == fixed_seed
		and int(runtime_state.get("seed", -1)) == fixed_seed
		and int(fate_state.get("seed", -1))
		== fixed_seed + RUNTIME_FATE_RANDOM_SEED_OFFSET
		and int(fate_manager_state.get("seed", -1))
		== fixed_seed + RUNTIME_FATE_MANAGER_RANDOM_SEED_OFFSET,
		"Runtime RNG evidence %s must retain the post-ready deterministic seeds."
		% stage
	)
	_expect(
		behavior_states.size() == enemies.size()
		and drop_states.size() == enemies.size()
		and corn_states.size() == corn_towers.size()
		and agave_states.size() == agave_towers.size(),
		"Runtime RNG evidence %s must cover every authored random stream." % stage
	)


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
	var agave_projectile_generations_before := _get_agave_projectile_generation_total()
	var tower_peak_concurrent_projectiles := _get_agave_projectile_in_use_count()
	var pool_before := _aggregate_pool_metrics()
	var pool_buckets_before := _get_pool_bucket_metrics()
	var projectile_pool_before := _get_projectile_pool_metrics()
	var initial_enemy_combat_services := game.get_enemy_combat_services()
	_expect(
		initial_enemy_combat_services != null,
		"EnemyCombatServices must be mounted before the cohort sample begins."
	)
	var initial_shared_combat_metrics := (
		initial_enemy_combat_services.get_metrics()
		if initial_enemy_combat_services != null
		else {}
	)
	var player_health_before := game.player.current_health
	var base_health_before := game.current_base_health
	var physics_frames_before := Engine.get_physics_frames()
	var random_state_evidence_start := _capture_runtime_random_state_evidence()
	_validate_runtime_random_state_evidence(random_state_evidence_start, "measurement_start")
	var client_proxy_authority_start := {}
	if requested_scenario_id == "host_client_proxy_1000":
		client_proxy_authority_start = _capture_client_proxy_authority_state()
	var faction_battle_state_start := {}
	if requested_scenario_id == "faction_battle_150v150":
		faction_battle_state_start = _capture_faction_battle_state()
	var simulation_coordinator := game.get_enemy_simulation_coordinator()
	_expect(
		simulation_coordinator != null,
		"The production fixture must expose EnemySimulationCoordinator metrics."
	)
	var simulation_metrics_before := (
		simulation_coordinator.get_metrics()
		if simulation_coordinator != null
		else {}
	)
	var enemy_contact_service := game.get_enemy_contact_service()
	_expect(
		enemy_contact_service != null,
		"The production fixture must expose EnemyContactService metrics."
	)
	var contact_service_metrics_before := (
		enemy_contact_service.get_metrics()
		if enemy_contact_service != null
		else {}
	)
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
	var individual_physics_processing_start := 0
	var touch_damage_area_monitoring_start := 0
	for enemy in enemies:
		if (
			enemy != null
			and is_instance_valid(enemy)
			and not enemy.is_dead
			and enemy.is_physics_processing()
		):
			individual_physics_processing_start += 1
		if (
			enemy != null
			and is_instance_valid(enemy)
			and not enemy.is_dead
			and enemy.touch_damage_area != null
			and is_instance_valid(enemy.touch_damage_area)
			and enemy.touch_damage_area.monitoring
		):
			touch_damage_area_monitoring_start += 1
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
	var render_total_cpu_samples: Array[float] = []
	var draw_call_samples: Array[float] = []
	var render_object_samples: Array[float] = []
	var canvas_draw_call_samples: Array[float] = []
	var canvas_object_samples: Array[float] = []
	var canvas_primitive_samples: Array[float] = []
	var collision_pair_samples: Array[float] = []
	var physics_active_samples: Array[float] = []
	var node_count_samples: Array[float] = []
	var static_memory_mib_samples: Array[float] = []
	var video_memory_mib_samples: Array[float] = []
	var texture_memory_mib_samples: Array[float] = []
	var buffer_memory_mib_samples: Array[float] = []
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
		_step_client_proxy_fixture()
		if requested_authoritative_tick_sampling:
			await physics_frame
		else:
			await process_frame
		_drive_player_movement()
		var now_usec := Time.get_ticks_usec()
		var wall_ms := float(now_usec - previous_tick_usec) / 1000.0
		wall_samples.append(wall_ms)
		previous_tick_usec = now_usec
		var current_sample_physics_frame := Engine.get_physics_frames()
		if requested_scenario_id == "tower_projectile_96":
			tower_peak_concurrent_projectiles = maxi(
				tower_peak_concurrent_projectiles,
				_get_agave_projectile_in_use_count()
			)
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
		if requested_authoritative_tick_sampling:
			# Formal A/B records only the tick wall/engine physics timings needed
			# for the gate. Render, memory, query and semantic diagnostics would
			# allocate or call into servers once per sample and contaminate p95.
			continue
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
		physics_active_samples.append(
			Performance.get_monitor(Performance.PHYSICS_2D_ACTIVE_OBJECTS)
		)
		node_count_samples.append(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
		static_memory_mib_samples.append(
			Performance.get_monitor(Performance.MEMORY_STATIC) / (1024.0 * 1024.0)
		)
		video_memory_mib_samples.append(
			Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED)
			/ (1024.0 * 1024.0)
		)
		texture_memory_mib_samples.append(
			Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED)
			/ (1024.0 * 1024.0)
		)
		buffer_memory_mib_samples.append(
			Performance.get_monitor(Performance.RENDER_BUFFER_MEM_USED)
			/ (1024.0 * 1024.0)
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
	var guardian_aura_metrics := {}
	if guardian_aura_system != null:
		guardian_aura_system.collect_overlap_query_metrics = false
		guardian_aura_metrics = guardian_aura_system.get_runtime_performance_metrics()
	var final_counts := telemetry.sample_runtime_counts(game)
	if requested_runtime_count_scans:
		peak_projectiles = maxi(peak_projectiles, telemetry.peak_active_projectiles)
	minimum_alive = mini(minimum_alive, int(final_counts["active_enemies"]))
	var pool_after := _aggregate_pool_metrics()
	var pool_buckets_after := _get_pool_bucket_metrics()
	var projectile_pool_after := _get_projectile_pool_metrics()
	var shared_combat_metrics := (
		initial_enemy_combat_services.get_metrics()
		if initial_enemy_combat_services != null
		else {}
	)
	var mage_activity_window := _build_mage_activity_window(
		initial_shared_combat_metrics,
		shared_combat_metrics
	)
	var legacy_mage_projectile_nodes := _count_nodes_with_script_path(
		game,
		CAPOO_MAGE_FIREBALL_SCRIPT_PATH
	)
	var random_state_evidence_end := _capture_runtime_random_state_evidence()
	_validate_runtime_random_state_evidence(random_state_evidence_end, "measurement_end")
	var client_proxy_authority_end := {}
	if requested_scenario_id == "host_client_proxy_1000":
		client_proxy_authority_end = _capture_client_proxy_authority_state()
	var faction_battle_state_end := {}
	if requested_scenario_id == "faction_battle_150v150":
		faction_battle_state_end = _capture_faction_battle_state()
	var simulation_metrics_after := (
		simulation_coordinator.get_metrics()
		if simulation_coordinator != null
		else {}
	)
	var simulation_metric_delta := _subtract_coordinator_metrics(
		simulation_metrics_after,
		simulation_metrics_before
	)
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
	var formal_registration_fingerprint_after_measurement := {}
	if _uses_formal_runtime_fixture():
		formal_registration_fingerprint_after_measurement = (
			_capture_formal_registration_fingerprint()
		)
		_validate_formal_registration_fingerprint(
			formal_registration_fingerprint_after_measurement,
			"after_measurement"
		)
	if _uses_formal_runtime_fixture():
		scenario_contract["host_enemy_count"] = alive_start
		scenario_contract["allied_enemy_count"] = _count_enemies_in_faction(
			CombatRelationService.PLAYER_ALLIED
		)
		scenario_contract["hostile_enemy_count"] = _count_enemies_in_faction(
			CombatRelationService.HOSTILE_WAVE
		)
	if requested_scenario_id == "tower_projectile_96":
		var tower_corn_shots := _get_corn_hitscan_ray_count() - corn_rays_before
		var tower_agave_shots := (
			_get_agave_projectile_generation_total()
			- agave_projectile_generations_before
		)
		var tower_total_shots := tower_corn_shots + tower_agave_shots
		scenario_contract["tower_total_shots"] = tower_total_shots
		scenario_contract["tower_agave_projectile_shots"] = tower_agave_shots
		scenario_contract["tower_peak_concurrent_projectiles"] = (
			tower_peak_concurrent_projectiles
		)
		scenario_contract["projectile_pressure_verified"] = (
			tower_total_shots >= TOWER_PROJECTILE_MINIMUM_TOTAL_SHOTS
			and tower_agave_shots >= TOWER_PROJECTILE_MINIMUM_AGAVE_SHOTS
			and tower_peak_concurrent_projectiles
			>= TOWER_PROJECTILE_MINIMUM_CONCURRENT_PROJECTILES
		)
		_expect(
			bool(scenario_contract["projectile_pressure_verified"]),
			(
				"Tower scenario must emit at least %d total shots, %d Agave "
				+ "projectiles and sustain a concurrent projectile peak of %d."
			)
			% [
				TOWER_PROJECTILE_MINIMUM_TOTAL_SHOTS,
				TOWER_PROJECTILE_MINIMUM_AGAVE_SHOTS,
				TOWER_PROJECTILE_MINIMUM_CONCURRENT_PROJECTILES,
			]
		)
	if requested_scenario_id == "faction_battle_150v150":
		scenario_contract["faction_valid_dynamic_targets_start"] = {
			"allied": int(faction_battle_state_start.get(
				"allied_valid_dynamic_targets",
				0
			)),
			"hostile": int(faction_battle_state_start.get(
				"hostile_valid_dynamic_targets",
				0
			)),
		}
		scenario_contract["faction_valid_dynamic_targets_end"] = {
			"allied": int(faction_battle_state_end.get(
				"allied_valid_dynamic_targets",
				0
			)),
			"hostile": int(faction_battle_state_end.get(
				"hostile_valid_dynamic_targets",
				0
			)),
		}
		scenario_contract["faction_damage_taken"] = (
			_build_faction_damage_evidence(
				faction_battle_state_start,
				faction_battle_state_end
			)
		)
		var faction_damage := scenario_contract["faction_damage_taken"] as Dictionary
		_expect(
			int(faction_battle_state_start.get("allied_valid_dynamic_targets", 0))
			== FACTION_BATTLE_SIZE
			and int(faction_battle_state_start.get("hostile_valid_dynamic_targets", 0))
			== FACTION_BATTLE_SIZE
			and int(faction_battle_state_end.get("allied_valid_dynamic_targets", 0))
			== FACTION_BATTLE_SIZE
			and int(faction_battle_state_end.get("hostile_valid_dynamic_targets", 0))
			== FACTION_BATTLE_SIZE
			and int(faction_damage.get("allied_damage_taken", 0)) > 0
			and int(faction_damage.get("hostile_damage_taken", 0)) > 0
			and int(faction_damage.get("allied_damaged_enemy_count", 0)) > 0
			and int(faction_damage.get("hostile_damaged_enemy_count", 0)) > 0,
			"Faction scenario must retain 150v150 valid targets and real bidirectional damage."
		)
	if requested_scenario_id == "host_client_proxy_1000":
		var client_simulation := (
			client_proxy_runtime.get_enemy_simulation_coordinator()
			if client_proxy_runtime != null
			else null
		)
		scenario_contract["client_proxy_count"] = (
			client_proxy_coordinator.get_remote_enemy_count()
			if client_proxy_coordinator != null
			else -1
		)
		scenario_contract["client_index_count"] = (
			client_proxy_runtime.combat_target_index.enemies_by_net_id.size()
			if client_proxy_runtime != null
			else -1
		)
		scenario_contract["client_authoritative_registered_count"] = (
			int(client_simulation.get_metrics().get("registered_count", -1))
			if client_simulation != null
			else -1
		)
		scenario_contract["client_proxy_start"] = client_proxy_authority_start
		scenario_contract["client_proxy_end"] = client_proxy_authority_end
		scenario_contract["client_authoritative_attack_delta"] = maxi(
			int(client_proxy_authority_end.get("target_assignment_events", 0))
			- int(client_proxy_authority_start.get("target_assignment_events", 0)),
			0
		)
		scenario_contract["client_authoritative_damage_delta"] = (
			maxi(
				int(client_proxy_authority_end.get("damage_broadcast_events", 0))
				- int(client_proxy_authority_start.get("damage_broadcast_events", 0)),
				0
			)
			+ maxi(
				int(client_proxy_authority_start.get("total_health", 0))
				- int(client_proxy_authority_end.get("total_health", 0)),
				0
			)
		)
		scenario_contract["client_authoritative_kill_delta"] = (
			maxi(
				int(client_proxy_authority_end.get("defeat_events", 0))
				- int(client_proxy_authority_start.get("defeat_events", 0)),
				0
			)
			+ maxi(
				int(client_proxy_authority_end.get("dead_count", 0))
				- int(client_proxy_authority_start.get("dead_count", 0)),
				0
			)
		)
		scenario_contract["client_authoritative_reward_delta"] = maxi(
			int(client_proxy_authority_end.get("pending_reward", 0))
			- int(client_proxy_authority_start.get("pending_reward", 0)),
			0
		)
		for state_variant in [client_proxy_authority_start, client_proxy_authority_end]:
			var state := state_variant as Dictionary
			_expect(
				int(state.get("proxy_count", -1)) == CLIENT_PROXY_COUNT
				and int(state.get("network_count", -1)) == CLIENT_PROXY_COUNT
				and int(state.get("index_count", -1)) == CLIENT_PROXY_COUNT
				and int(state.get("proxy_true_count", -1)) == CLIENT_PROXY_COUNT
				and int(state.get("process_disabled_count", -1)) == CLIENT_PROXY_COUNT
				and int(state.get("physics_process_disabled_count", -1))
				== CLIENT_PROXY_COUNT
				and int(state.get("area_count", -1)) > 0
				and int(state.get("monitoring_area_count", -1)) == 0
				and int(state.get("simulation_registered_count", -1)) == 0
				and int(state.get("contact_registered_count", -1)) == 0
				and int(state.get("authoritative_attack_state_count", -1)) == 0
				and int(state.get("authoritative_damage_state_count", -1)) == 0
				and int(state.get("dead_count", -1)) == 0
				and int(state.get("pending_reward", -1)) == 0
				and not bool(state.get("reward_flush_queued", true)),
				"Every client proxy must remain presentation-only at both measurement boundaries."
			)
		_expect(
			int(scenario_contract["client_authoritative_attack_delta"]) == 0
			and int(scenario_contract["client_authoritative_damage_delta"]) == 0
			and int(scenario_contract["client_authoritative_kill_delta"]) == 0
			and int(scenario_contract["client_authoritative_reward_delta"]) == 0,
			"CLIENT_VIEW must produce zero attack, damage, kill and reward authority deltas."
		)

	var result := {
		"schema_version": PROBE_RESULT_SCHEMA_VERSION,
		"scenario_id": requested_scenario_id,
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
		"scenario_contract": scenario_contract.duplicate(true),
		"building_composition": {
			"simple_fence": _count_alive_fences(),
			"corn": corn_towers.size(),
			"agave": agave_towers.size(),
			"total": (
				_count_alive_fences() + corn_towers.size() + agave_towers.size()
			),
			"placement_scope": (
				"in_field"
				if _uses_in_field_building_fixture()
				else (
					"none"
					if _uses_formal_runtime_fixture()
					else "mixed_or_external"
				)
			),
		},
		"phase": _phase_name(),
		"flow_state": int(game.campaign_coordinator.wave_state),
		"night_factor": game.day_night_controller.night_factor,
		"is_night": game.day_night_controller.is_night(),
		"gate_profile": _gate_profile_name(),
		"quick_validation": requested_quick_validation,
		"seed": fixed_seed,
		"rng_state_evidence": {
			"start": random_state_evidence_start,
			"end": random_state_evidence_end,
		},
		"requested_enemies": requested_enemy_count,
		"requested_simple_fences": requested_simple_fence_count,
		"simple_fences": simple_fences.size(),
		"simple_fence_ab_metrics": requested_simple_fence_ab_metrics,
		"simple_fence_fixture": final_fence_metrics,
		"production_registration_fingerprint": {
			"required": _uses_formal_runtime_fixture(),
			"before_measurement": (
				formal_registration_fingerprint_before_measurement
			),
			"after_measurement": (
				formal_registration_fingerprint_after_measurement
			),
		},
		"corn_towers": corn_towers.size(),
		"agave_towers": agave_towers.size(),
		"alive_start": alive_start,
		"alive_min": minimum_alive,
		"alive_end": int(final_counts["active_enemies"]),
		"individual_physics_processing_start": (
			individual_physics_processing_start
		),
		"touch_damage_area_monitoring_start": (
			touch_damage_area_monitoring_start
		),
		"setup_ms": setup_ms,
		"tower_setup_ms": tower_setup_ms,
		"runtime_setup_ms": runtime_setup_ms,
		"projectile_pool_registration_ms": game.projectile_pool_registration_ms,
		"burst_trigger_ms": burst_trigger_ms,
		"warmup_frames": warmup_frames,
		"sample_frames": sample_frames,
		"sampling_contract": {
			"sample_unit": (
				"authoritative_physics_tick"
				if requested_authoritative_tick_sampling
				else "render_process_frame"
			),
			"authoritative_tick_sampling": requested_authoritative_tick_sampling,
			"detailed_semantic_evidence": requested_detailed_semantic_evidence,
			"per_tick_diagnostics": (
				"minimal" if requested_authoritative_tick_sampling else "detailed"
			),
			"requested_warmup_physics_ticks": warmup_frames,
			"requested_sample_physics_ticks": sample_frames,
		},
		"enemy_simulation": {
			"requested_mode": (
				EnemySimulationPolicy.mode_to_name(
					requested_simulation_mode
				).to_lower()
				if requested_simulation_mode_explicit
				else "project_default"
			),
			"requested_mode_explicit": requested_simulation_mode_explicit,
			"actual_mode": EnemySimulationPolicy.mode_to_name(
				int(simulation_metrics_after.get("mode", -1))
			).to_lower(),
			"actual_mode_value": int(simulation_metrics_after.get("mode", -1)),
			"registered_start": int(
				simulation_metrics_before.get("registered_count", 0)
			),
			"active_start": int(simulation_metrics_before.get("active_count", 0)),
			"registered": int(simulation_metrics_after.get("registered_count", 0)),
			"active": int(simulation_metrics_after.get("active_count", 0)),
			"contact_registration_count": int(
				contact_service_metrics_before.get("registered_count", 0)
			),
			"registration_rejections": int(
				simulation_metrics_after.get("registration_rejections", 0)
			),
			"contact_registration_rejections": int(
				simulation_metrics_after.get(
					"contact_registration_rejections",
					0
				)
			),
			"physics_ticks": int(simulation_metric_delta.get("physics_ticks", 0)),
			"authoritative_steps": int(
				simulation_metric_delta.get("authoritative_steps", 0)
			),
			"metrics_before": simulation_metrics_before,
			"metrics_after": simulation_metrics_after,
			"measured_metric_delta": simulation_metric_delta,
		},
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
		"enemy_attack_audio_limiter": requested_enemy_attack_audio_limiter,
		"enemy_attack_audio": ENEMY_ATTACK_AUDIO_LIMITER.get_metrics(),
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
		"render_total_cpu_ms": _summarize(render_total_cpu_samples),
		"draw_calls": _summarize(draw_call_samples),
		"render_objects": _summarize(render_object_samples),
		"canvas_draw_calls": _summarize(canvas_draw_call_samples),
		"canvas_objects": _summarize(canvas_object_samples),
		"canvas_primitives": _summarize(canvas_primitive_samples),
		"collision_pairs": _summarize(collision_pair_samples),
		"physics_active_objects": _summarize(physics_active_samples),
		"node_count": _summarize(node_count_samples),
		"static_memory_mib": _summarize(static_memory_mib_samples),
		"video_memory_mib": _summarize(video_memory_mib_samples),
		"texture_memory_mib": _summarize(texture_memory_mib_samples),
		"buffer_memory_mib": _summarize(buffer_memory_mib_samples),
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
		"peak_projectiles": (
			peak_projectiles if requested_runtime_count_scans else null
		),
		"peak_projectiles_supported": requested_runtime_count_scans,
		"corn_target_locks": _get_corn_target_lock_count() - corn_locks_before,
		"corn_hitscan_rays": _get_corn_hitscan_ray_count() - corn_rays_before,
		"boss_phase_observations": boss_phase_observations,
		"boss_peak_counters": boss_peak_counters,
		"boss_runtime_state": _get_boss_runtime_state(),
		"enemy_hot_segments": _format_enemy_hot_segments(enemy_metrics),
		"stone_golem_slam": stone_golem_slam_metrics,
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
		"enemy_combat_services": shared_combat_metrics,
		"mage_activity_window": mage_activity_window,
		"legacy_mage_projectile_nodes": legacy_mage_projectile_nodes,
		"combat_index_size": game.combat_target_index.enemies_by_net_id.size(),
		"renderer": RenderingServer.get_current_rendering_method(),
		"render_driver": RenderingServer.get_current_rendering_driver_name(),
		"gpu": RenderingServer.get_video_adapter_name(),
		"runtime_environment": {
			"godot": Engine.get_version_info(),
			"os": {
				"name": OS.get_name(),
				"version": OS.get_version(),
			},
			"cpu": {
				"name": OS.get_processor_name(),
				"logical_processor_count": OS.get_processor_count(),
			},
		},
		"requested_vsync_mode": requested_vsync_mode,
		"vsync_mode": int(DisplayServer.window_get_vsync_mode()),
		"requested_window_size": [requested_window_size.x, requested_window_size.y],
		"window_size": [DisplayServer.window_get_size().x, DisplayServer.window_get_size().y],
		"viewport_size": [
			game.get_viewport().get_visible_rect().size.x,
			game.get_viewport().get_visible_rect().size.y,
		],
	}

	_expect(wall_samples.size() == sample_frames, "Every requested frame sample must be recorded.")
	if requested_authoritative_tick_sampling:
		_expect(
			_count_samples_not_equal_to(physics_steps_per_render_sample, 1.0) == 0,
			"Every authoritative sample must contain exactly one physics tick."
		)
	_expect(
		_count_alive_fences() == requested_simple_fence_count,
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
		)
		+ corn_towers.size()
		+ agave_towers.size(),
		(
			"CONTACT_ONLY fences must remain absent while every combat tower stays "
			+ "registered in the proactive index."
		)
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
	var mage_simulation_metrics := shared_combat_metrics.get(
		"capoo_mage_fireball_simulation",
		{}
	) as Dictionary
	var mage_presenter_metrics := shared_combat_metrics.get(
		"capoo_mage_fireball_presenter",
		{}
	) as Dictionary
	var impact_presentation_metrics := shared_combat_metrics.get(
		"explosion_presentation",
		{}
	) as Dictionary
	_expect(
		not mage_simulation_metrics.is_empty()
		and bool(mage_simulation_metrics.get("bound", false))
		and int(mage_simulation_metrics.get("reserved_capacity", 0))
			>= 2048
		and not bool(mage_simulation_metrics.get("teardown_prepared", true))
		and int(mage_simulation_metrics.get("teardowns", -1)) == 0,
		"Mage shared simulation metrics must remain live and preallocated during the cohort window."
	)
	_expect(
		not mage_presenter_metrics.is_empty()
		and bool(mage_presenter_metrics.get("bound", false))
		and int(mage_presenter_metrics.get("draw_family_count", 0)) == 3
		and not bool(mage_presenter_metrics.get("teardown_prepared", true))
		and int(mage_presenter_metrics.get("teardown_count", -1)) == 0,
		"Mage shared projectile presenter metrics must remain visible without early teardown."
	)
	_expect(
		not impact_presentation_metrics.is_empty()
		and int(impact_presentation_metrics.get("draw_family_count", 0)) == 4
		and int(impact_presentation_metrics.get("teardown_count", -1)) == 0,
		"Shared impact metrics must expose the authored RPG and Mage draw families."
	)
	_expect(
		legacy_mage_projectile_nodes == 0,
		"Production cohorts must not instantiate legacy CapooMage fireball nodes."
	)
	if phase == ProbePhase.ENGAGEMENT and _cohort_contains_mage_config():
		_expect(
			int(mage_activity_window["spawns"]) > 0,
			"Mage engagement must spawn production DATA fireballs during the sample window."
		)
		_expect(
			int(mage_activity_window["advances"]) > 0,
			"Mage engagement must advance production DATA fireballs during the sample window."
		)
		_expect(
			int(mage_activity_window["direct_queries"]) > 0,
			"Mage engagement must execute direct-hit queries during the sample window."
		)
		_expect(
			int(mage_activity_window["completions"]) > 0,
			"Mage engagement must complete production DATA fireballs during the sample window."
		)
		_expect(
			int(mage_activity_window["damage_accepts"]) > 0,
			"Mage engagement must resolve accepted authoritative damage during the sample window."
		)
		_expect(
			int(mage_activity_window["presentation_requests"]) > 0,
			"Mage engagement must request shared impact presentation during the sample window."
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
	var gate_result := _evaluate_gate(result)
	result["gate"] = gate_result
	result["valid"] = bool(gate_result.get("valid", false))
	result["verdict"] = str(gate_result.get("status", "invalid"))
	result["violations"] = gate_result.get("violations", [])
	return result


func _evaluate_gate(result: Dictionary) -> Dictionary:
	var semantic_failures := failures.duplicate()
	var invalid_reasons: Array[String] = []
	var budget_violations: Array[Dictionary] = []
	var violations: Array[Dictionary] = []
	var budgets := {
		"wall_p95_ms": requested_wall_p95_budget_ms,
		"wall_p99_ms": requested_wall_p99_budget_ms,
		"over_18_ratio": requested_over_18_ratio_budget,
		"over_33_333_ratio": requested_over_33_ratio_budget,
	}
	for semantic_failure in semantic_failures:
		violations.append({
			"code": "semantic_failure",
			"message": semantic_failure,
		})
	if requested_gate_profile == GateProfile.DIAGNOSTIC:
		return {
			"profile": _gate_profile_name(),
			"measurement_scope": "diagnostic",
			"status": "diagnostic",
			"valid": semantic_failures.is_empty(),
			"passed": false,
			"quick_validation": false,
			"budgets": budgets,
			"invalid_reasons": invalid_reasons,
			"budget_violations": budget_violations,
			"semantic_failures": semantic_failures,
			"violations": violations,
		}

	var profile_name := _gate_profile_name()
	var window_profile := requested_gate_profile in [
		GateProfile.WINDOW60,
		GateProfile.WAVE60,
	]
	if requested_gate_profile == GateProfile.CPU60:
		if DisplayServer.get_name().to_lower() != "headless":
			invalid_reasons.append("cpu60 requires the headless display driver")
		if requested_max_fps != 0:
			invalid_reasons.append("cpu60 requires max_fps=0")
	elif window_profile:
		if DisplayServer.get_name().to_lower() == "headless":
			invalid_reasons.append("%s requires a real window" % profile_name)
		if requested_max_fps != 60:
			invalid_reasons.append("%s requires max_fps=60" % profile_name)
		if requested_window_size != FORMAL_WINDOW_SIZE:
			invalid_reasons.append(
				"%s requires a requested 1280x720 window" % profile_name
			)
		if requested_vsync_mode != "disabled":
			invalid_reasons.append("%s requires vsync-mode=disabled" % profile_name)
		if DisplayServer.window_get_vsync_mode() != DisplayServer.VSYNC_DISABLED:
			invalid_reasons.append("%s did not apply disabled VSync" % profile_name)
		if requested_gate_profile == GateProfile.WINDOW60 and not wave_config_path.is_empty():
			invalid_reasons.append("window60 requires a single EnemyConfig source")
		if requested_gate_profile == GateProfile.WAVE60 and wave_config_path.is_empty():
			invalid_reasons.append("wave60 requires a WaveConfig source")
	if (
		phase != ProbePhase.ENGAGEMENT
		and not _uses_formal_runtime_fixture()
	):
		invalid_reasons.append("%s requires phase=engagement" % profile_name)
	if requested_enemy_count not in [200, DEFAULT_ENEMY_COUNT]:
		invalid_reasons.append(
			"%s requires exactly 200 or 300 requested enemies" % profile_name
		)
	var minimum_warmup_frames := (
		QUICK_GATE_MINIMUM_WARMUP_FRAMES
		if requested_quick_validation
		else FORMAL_GATE_MINIMUM_WARMUP_FRAMES
	)
	var minimum_sample_frames := (
		QUICK_GATE_MINIMUM_SAMPLE_FRAMES
		if requested_quick_validation
		else FORMAL_GATE_MINIMUM_SAMPLE_FRAMES
	)
	if warmup_frames < minimum_warmup_frames:
		invalid_reasons.append(
			"%s requires at least %d warmup frames"
			% [profile_name, minimum_warmup_frames]
		)
	if sample_frames < minimum_sample_frames:
		invalid_reasons.append(
			"%s requires at least %d sample frames"
			% [profile_name, minimum_sample_frames]
		)
	if (
		requested_enemy_hot_metrics
		or requested_guardian_overlap_metrics
		or requested_runtime_count_scans
		or requested_simple_fence_ab_metrics
		or requested_detailed_semantic_evidence
	):
		invalid_reasons.append(
			"%s forbids intrusive hot-path/count instrumentation" % profile_name
		)
	if requested_authoritative_tick_sampling:
		if warmup_frames != AB_WARMUP_PHYSICS_TICKS:
			invalid_reasons.append(
				"authoritative A/B requires exactly %d warmup physics ticks"
				% AB_WARMUP_PHYSICS_TICKS
			)
		if sample_frames != AB_SAMPLE_PHYSICS_TICKS:
			invalid_reasons.append(
				"authoritative A/B requires exactly %d sample physics ticks"
				% AB_SAMPLE_PHYSICS_TICKS
			)
		if requested_detailed_semantic_evidence:
			invalid_reasons.append(
				"authoritative performance A/B forbids detailed semantic evidence"
			)

	var alive_start := int(result.get("alive_start", -1))
	var alive_min := int(result.get("alive_min", -1))
	var alive_end := int(result.get("alive_end", -1))
	if _uses_formal_runtime_fixture():
		if alive_start != requested_enemy_count or alive_end <= 0:
			invalid_reasons.append(
				"%s requires a complete starting cohort and a non-empty measured workload"
				% profile_name
			)
	elif (
		alive_start != requested_enemy_count
		or alive_min != requested_enemy_count
		or alive_end != requested_enemy_count
	):
		invalid_reasons.append(
			"%s requires a stable %d-enemy cohort, observed %d/%d/%d"
			% [profile_name, requested_enemy_count, alive_start, alive_min, alive_end]
		)

	var minimum_physics_frames := floori(float(sample_frames) * 0.95)
	var physics_frames_elapsed := int(result.get("physics_frames_elapsed", 0))
	if physics_frames_elapsed < minimum_physics_frames:
		invalid_reasons.append(
			"%s sampled only %d physics frames; requires at least %d"
			% [profile_name, physics_frames_elapsed, minimum_physics_frames]
		)
	if requested_authoritative_tick_sampling and physics_frames_elapsed != sample_frames:
		invalid_reasons.append(
			"authoritative A/B observed %d physics ticks; requires exactly %d"
			% [physics_frames_elapsed, sample_frames]
		)
	var catchup := result.get("physics_catchup", {}) as Dictionary
	if (
		requested_authoritative_tick_sampling
		and (
			int(catchup.get("max_steps_per_render_sample", 0)) != 1
			or int(catchup.get("samples_with_multiple_steps", 0)) != 0
		)
	):
		invalid_reasons.append(
			"authoritative A/B requires exactly one physics step in every sample"
		)
	var simulation := result.get("enemy_simulation", {}) as Dictionary
	if _uses_formal_runtime_fixture():
		if (
			int(result.get("flow_state", -1))
			!= CombatFlowState.State.WAVE_ACTIVE
		):
			invalid_reasons.append(
				"formal first-night A/B must remain in WAVE_ACTIVE"
			)
		if (
			not bool(result.get("is_night", false))
			or not is_equal_approx(float(result.get("night_factor", -1.0)), 1.0)
		):
			invalid_reasons.append(
				"formal first-night A/B must remain at full night factor"
			)
	var requested_mode_name := EnemySimulationPolicy.mode_to_name(
		requested_simulation_mode
	).to_lower()
	if (
		requested_simulation_mode_explicit
		and str(simulation.get("actual_mode", "")) != requested_mode_name
	):
		invalid_reasons.append(
			"coordinator mode did not match requested %s" % requested_mode_name
		)
	if (
		requested_simulation_mode_explicit
		and requested_simulation_mode == EnemySimulationPolicy.Mode.LEGACY
	):
		if (
			int(simulation.get("registered_start", -1)) != 0
			or int(simulation.get("active_start", -1)) != 0
			or int(simulation.get("registered", -1)) != 0
			or int(simulation.get("active", -1)) != 0
			or int(simulation.get("physics_ticks", -1)) != 0
			or int(simulation.get("authoritative_steps", -1)) != 0
		):
			invalid_reasons.append(
				"LEGACY must retain per-enemy callbacks without coordinator work"
			)
		if (
			int(result.get("individual_physics_processing_start", -1))
			!= alive_start
			or int(simulation.get("contact_registration_count", -1)) != 0
			or int(result.get("touch_damage_area_monitoring_start", -1))
			!= alive_start
		):
			invalid_reasons.append(
				"LEGACY must retain every per-enemy callback and authored TouchDamageArea monitor"
			)
	elif (
		requested_simulation_mode_explicit
		and requested_simulation_mode
		== EnemySimulationPolicy.Mode.LAYERED_CONTACT
	):
		if (
			int(simulation.get("registered_start", -1)) != alive_start
			or int(simulation.get("active_start", -1)) != alive_start
			or int(result.get("individual_physics_processing_start", -1)) != 0
			or int(simulation.get("contact_registration_count", -1)) < 0
			or int(simulation.get("contact_registration_count", -1))
			+ int(result.get("touch_damage_area_monitoring_start", -1))
			!= alive_start
		):
			invalid_reasons.append(
				"LAYERED_CONTACT must exclusively own simulation and partition shared/authored contact for every live enemy"
			)
		if (
			int(simulation.get("registration_rejections", -1)) != 0
			or int(simulation.get("contact_registration_rejections", -1)) != 0
		):
			invalid_reasons.append(
				"LAYERED_CONTACT must not reject or fall back any formal enemy registration"
			)
		var maximum_monitored_touch_areas := floori(
			float(alive_start) * 0.05
		)
		if (
			int(result.get("touch_damage_area_monitoring_start", -1)) < 0
			or int(result.get("touch_damage_area_monitoring_start", -1))
			> maximum_monitored_touch_areas
		):
			invalid_reasons.append(
				"LAYERED_CONTACT must reduce TouchDamageArea monitoring by at least 95%"
			)
		var layered_alive_end_for_steps := int(result.get("alive_end", -1))
		var layered_authoritative_steps := int(
			simulation.get("authoritative_steps", -1)
		)
		if (
			int(simulation.get("physics_ticks", -1)) != sample_frames
			or layered_authoritative_steps
			< layered_alive_end_for_steps * sample_frames
			or layered_authoritative_steps > alive_start * sample_frames
			or int(simulation.get("registered", -1))
			!= layered_alive_end_for_steps
			or int(simulation.get("active", -1)) != layered_alive_end_for_steps
		):
			invalid_reasons.append(
				"LAYERED_CONTACT ticks, bounded steps, and final ownership must cover the authoritative window"
			)
	elif (
		requested_simulation_mode_explicit
		and requested_simulation_mode == EnemySimulationPolicy.Mode.COMPAT_60
	):
		if (
			int(simulation.get("registered_start", -1)) != alive_start
			or int(simulation.get("active_start", -1)) != alive_start
			or int(result.get("individual_physics_processing_start", -1)) != 0
		):
			invalid_reasons.append(
				"COMPAT_60 must exclusively own every live enemy at measurement start"
			)
		var alive_end_for_steps := int(result.get("alive_end", -1))
		var authoritative_steps := int(
			simulation.get("authoritative_steps", -1)
		)
		if (
			int(simulation.get("physics_ticks", -1)) != sample_frames
			or authoritative_steps < alive_end_for_steps * sample_frames
			or authoritative_steps > alive_start * sample_frames
			or int(simulation.get("registered", -1)) != alive_end_for_steps
			or int(simulation.get("active", -1)) != alive_end_for_steps
		):
			invalid_reasons.append(
				"COMPAT_60 ticks, bounded steps, and final ownership must cover the authoritative window"
			)
	var minimum_simulation_seconds := (
		float(sample_frames)
		/ float(maxi(Engine.physics_ticks_per_second, 1))
		* 0.95
	)
	var simulation_seconds := float(result.get("simulation_seconds_elapsed", 0.0))
	if simulation_seconds < minimum_simulation_seconds:
		invalid_reasons.append(
			"%s covered only %.3f simulation seconds; requires at least %.3f"
			% [profile_name, simulation_seconds, minimum_simulation_seconds]
		)

	var wall_summary := result.get("wall_ms", {}) as Dictionary
	var frame_budget := result.get("frame_budget", {}) as Dictionary
	var wall_p95 := float(wall_summary.get("p95", 0.0))
	var wall_p99 := float(wall_summary.get("p99", 0.0))
	var over_18_ratio := float(frame_budget.get("over_18_ratio", 0.0))
	var over_33_ratio := float(frame_budget.get("over_33_333_ratio", 0.0))
	if (
		is_nan(wall_p95)
		or is_inf(wall_p95)
		or is_nan(wall_p99)
		or is_inf(wall_p99)
		or wall_p95 <= 0.0
		or wall_p99 <= 0.0
	):
		invalid_reasons.append(
			"%s requires finite positive wall p95/p99 samples" % profile_name
		)
	else:
		if wall_p95 > requested_wall_p95_budget_ms:
			budget_violations.append({
				"code": "wall_p95_budget",
				"actual": wall_p95,
				"limit": requested_wall_p95_budget_ms,
			})
		if wall_p99 > requested_wall_p99_budget_ms:
			budget_violations.append({
				"code": "wall_p99_budget",
				"actual": wall_p99,
				"limit": requested_wall_p99_budget_ms,
			})
	if window_profile and over_18_ratio > requested_over_18_ratio_budget:
		budget_violations.append({
			"code": "over_18_ratio_budget",
			"actual": over_18_ratio,
			"limit": requested_over_18_ratio_budget,
		})
	if over_33_ratio > requested_over_33_ratio_budget:
		budget_violations.append({
			"code": "over_33_333_ratio_budget",
			"actual": over_33_ratio,
			"limit": requested_over_33_ratio_budget,
		})

	for reason in invalid_reasons:
		violations.append({
			"code": "invalid_configuration_or_workload",
			"message": reason,
		})
	for budget_violation in budget_violations:
		violations.append(budget_violation)

	var valid := semantic_failures.is_empty() and invalid_reasons.is_empty()
	var successful := valid and budget_violations.is_empty()
	var passed := successful and not requested_quick_validation
	var status := (
		("smoke_passed" if requested_quick_validation else "passed")
		if successful
		else ("failed" if valid else "invalid")
	)
	for reason in invalid_reasons:
		failures.append("%s gate invalid: %s" % [profile_name, reason])
	for violation in budget_violations:
		failures.append(
			"%s gate failed: %s actual=%s limit=%s"
			% [
				profile_name,
				str(violation.get("code", "unknown")),
				str(violation.get("actual", 0.0)),
				str(violation.get("limit", 0.0)),
			]
		)
	return {
		"profile": _gate_profile_name(),
		"measurement_scope": (
			"headless_unpaced_cpu"
			if requested_gate_profile == GateProfile.CPU60
			else "paced_window_60hz"
		),
		"status": status,
		"valid": valid,
		"passed": passed,
		"quick_validation": requested_quick_validation,
		"budgets": budgets,
		"invalid_reasons": invalid_reasons,
		"budget_violations": budget_violations,
		"semantic_failures": semantic_failures,
		"violations": violations,
	}


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


func _subtract_coordinator_metrics(after: Dictionary, before: Dictionary) -> Dictionary:
	var result := {}
	for key in [
		"simulation_tick",
		"physics_ticks",
		"authoritative_steps",
		"event_phases",
		"event_sleep_acks",
		"decision_phases",
		"urgent_decisions",
		"motion_phases",
		"contact_phases",
		"indexed_touch_syncs",
		"indexed_touch_authority_enables",
		"indexed_touch_plant_broadphases",
		"indexed_touch_plant_exact_candidates",
		"indexed_touch_plant_candidate_checks",
		"indexed_touch_plant_sleep_skips",
		"indexed_touch_plant_exact_cache_hits",
		"indexed_touch_empty_snapshot_skips",
		"indexed_touch_unchanged_snapshot_skips",
		"indexed_touch_complete_snapshot_skips",
		"indexed_touch_empty_corridor_skips",
		"indexed_touch_nonempty_plant_certificate_builds",
		"indexed_touch_nonempty_plant_certificate_reuses",
		"indexed_touch_nonempty_plant_certificate_rejects",
		"indexed_touch_dirty_enqueues",
		"indexed_touch_dirty_drains",
		"indexed_touch_dirty_ordered_drains",
		"indexed_touch_dirty_sorts",
		"indexed_touch_moved_ordered_drains",
		"indexed_touch_moved_sorts",
		"indexed_touch_player_invalidations",
		"indexed_touch_global_invalidations",
		"activation_skips",
		"suspended_skips",
		"profile_contact_setup_usec",
		"profile_contact_admission_usec",
		"profile_contact_geometry_usec",
		"profile_contact_service_usec",
		"profile_indexed_player_refresh_usec",
		"profile_indexed_dirty_drain_usec",
		"profile_event_phase_usec",
		"profile_decision_phase_usec",
		"profile_planned_contact_usec",
		"profile_motion_phase_usec",
	]:
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
		BULLET_HIT_EFFECT_POOL_PATH,
	]:
		result[scene_path] = game.session_object_pool.get_metrics(scene_path)
	return result


func _validate_projectile_pool_startup(metrics_by_path: Dictionary) -> void:
	var ak47_metrics := metrics_by_path.get(
		CAPOO_AK47_BULLET_POOL_PATH,
		{}
	) as Dictionary
	var gunner_metrics := metrics_by_path.get(
		COMBAT_ROBOT_GUNNER_BULLET_POOL_PATH,
		{}
	) as Dictionary
	_expect(
		ak47_metrics.is_empty(),
		"Production must not register the retired AK projectile pool."
	)
	_expect(
		gunner_metrics.is_empty(),
		"Production must not register the retired gunner projectile pool."
	)


func _build_pool_metric_window(before: Dictionary, after: Dictionary) -> Dictionary:
	var result := {}
	for scene_path in [
		CAPOO_AK47_BULLET_POOL_PATH,
		COMBAT_ROBOT_GUNNER_BULLET_POOL_PATH,
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


func _count_alive_fences() -> int:
	var count := 0
	for fence in simple_fences:
		if (
			fence != null
			and is_instance_valid(fence)
			and not fence.is_dead
			and not fence.is_queued_for_deletion()
		):
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


func _count_samples_not_equal_to(samples: Array[float], expected: float) -> int:
	var count := 0
	for sample in samples:
		if not is_equal_approx(sample, expected):
			count += 1
	return count


func _ratio_over_budget(samples: Array[float], budget_ms: float) -> float:
	if samples.is_empty():
		return 0.0
	return float(_count_over_budget(samples, budget_ms)) / float(samples.size())


func _phase_name() -> String:
	return ProbePhase.keys()[int(phase)].to_lower()


func _gate_profile_name() -> String:
	return GateProfile.keys()[int(requested_gate_profile)].to_lower()


func _finish() -> void:
	_release_movement_input()
	await _dispose_client_proxy_fixture()
	Enemy.performance_metrics_enabled = false
	STONE_GOLEM_SCRIPT.slam_performance_metrics_enabled = false
	Enemy.navigation_render_frame_dedupe_enabled = original_navigation_render_dedupe
	Enemy.navigation_process_frame_budget_enabled = original_navigation_refresh_budget
	Enemy.combat_sense_throttling_enabled = original_combat_sense_throttling
	GuardianAuraSystem.unchanged_source_diff_fast_path_enabled = (
		original_guardian_unchanged_diff_fast_path
	)
	ENEMY_ATTACK_AUDIO_LIMITER.limiting_enabled = (
		original_enemy_attack_audio_limiter
	)
	Engine.max_fps = original_max_fps
	if vsync_overridden:
		DisplayServer.window_set_vsync_mode(original_vsync_mode)
	# Match the real return-to-lobby teardown transaction before SceneTree starts
	# recursively deleting enemies. This lets the simulation coordinator release
	# registrations while the enemy nodes and runtime ledgers are still valid.
	if game != null and is_instance_valid(game):
		game.prepare_for_scene_teardown()
	current_scene = null
	if game != null:
		game.queue_free()
	if telemetry != null:
		telemetry.queue_free()
	for _cleanup_index in range(CLEANUP_FRAMES):
		await process_frame
		await physics_frame
	# A PackedScene preloaded by a SceneTree main script remains rooted until the
	# engine destroys that main script, which is later than ResourceCache cleanup
	# on affected Windows Godot builds. Drop the runtime reference before quit.
	tower_scene = null
	if failures.is_empty():
		if requested_gate_profile == GateProfile.DIAGNOSTIC:
			print("TOWER_DEFENSE_ENEMY_COHORT_DIAGNOSTIC_COMPLETE")
		elif requested_quick_validation:
			print(
				"TOWER_DEFENSE_ENEMY_COHORT_%s_GATE_SMOKE_OK"
				% _gate_profile_name().to_upper()
			)
		else:
			print(
				"TOWER_DEFENSE_ENEMY_COHORT_%s_GATE_OK"
				% _gate_profile_name().to_upper()
			)
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
