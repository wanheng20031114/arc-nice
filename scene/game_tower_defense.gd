extends GameRuntimeBase
class_name GameTowerDefense

const PLAYER_BULLET_POOL_SCENE := preload("res://scene/bullet.tscn")
const TANGO_LASER_BULLET_POOL_SCENE := preload(
	"res://scene/player/tango/tango_laser_bullet.tscn"
)
const CAPOO_AK47_BULLET_POOL_SCENE := preload("res://scene/enemy/capoo/capoo_ak47_bullet.tscn")
const CAPOO_SMG_BULLET_POOL_SCENE := preload("res://scene/enemy/capoo/capoo_smg_bullet.tscn")
const CAPOO_RPG_ROCKET_POOL_SCENE := preload("res://scene/enemy/capoo/capoo_rpg_rocket.tscn")
const CAPOO_MAGE_FIREBALL_POOL_SCENE := preload("res://scene/enemy/capoo/capoo_mage_fireball.tscn")
const FIRE_SORCERER_FIREBALL_VOLLEY_POOL_SCENE := preload(
	"res://scene/enemy/sorcerer/fire_sorcerer_fireball_volley.tscn"
)
const FIRE_SORCERER_ELITE_FIREBALL_VOLLEY_POOL_SCENE := preload(
	"res://scene/enemy/sorcerer/fire_sorcerer_elite_fireball_volley.tscn"
)
const FROST_SORCERER_ICE_SPIKE_POOL_SCENE := preload(
	"res://scene/enemy/sorcerer/frost_sorcerer_ice_spike.tscn"
)
const YUANSHI_FIRE_PROJECTILE_POOL_SCENE := preload("res://scene/enemy/yuanshi_insect/yuanshi_insect_fire_projectile.tscn")
const AGAVE_CANNONBALL_POOL_SCENE := preload("res://scene/plant_defense/agave_cannonball.tscn")
const BAMBOO_MORTAR_SHELL_POOL_SCENE := preload(
	"res://scene/plant_defense/bamboo_mortar_shell.tscn"
)
const PLANT_PLACEMENT_PARTICLES_SCENE := preload(
	"res://scene/plant_defense/effects/plant_placement_particles.tscn"
)
const PLANT_REMOVAL_SMOKE_SCENE := preload(
	"res://scene/plant_defense/effects/plant_removal_smoke.tscn"
)
const COLLECTIBLE_ARROW_POOL_SCENE := preload("res://scene/collectible_arrow_projectile.tscn")
const COLLECTIBLE_SAKURA_ROCKET_POOL_SCENE := preload(
	"res://scene/collectible_sakura_rocket.tscn"
)
const LINGLAN_SKILL1_BULLET_POOL_SCENE := preload(
	"res://scene/boss/linglan/linglan_skill1_sakura_bullet.tscn"
)
const LINGLAN_SAKURA_HIT_EFFECT_POOL_SCENE := preload(
	"res://scene/boss/linglan/linglan_sakura_hit_effect.tscn"
)
const LINGLAN_SLIME_CONFIG_PATHS: Array[String] = [
	"res://resources/config/enemies/slime.tres",
	"res://resources/config/enemies/slime_green.tres",
	"res://resources/config/enemies/slime_golden.tres",
	"res://resources/config/enemies/slime_frost.tres",
	"res://resources/config/enemies/slime_fire.tres",
]
const WORLD_EFFECT_VISIBILITY := preload("res://scene/world_effect_visibility.gd")
const GUARDIAN_POINT_LIGHT_TEXTURE := preload("res://resources/texture/guardian_point_light.png")
const DEFAULT_PLAYER_CHARACTER_ID := &"weishidaier"
const TANGO_MINIMUM_CHARGE_SECONDS := 0.2
const TANGO_MAXIMUM_CHARGE_SECONDS := 2.4
const TANGO_CHARGE_THRESHOLD_EPSILON := 0.0001
const LINGLAN_BOSS_INTRO_VFX_SCENE_PATH := "res://scene/boss/linglan/linglan_boss_intro_vfx.tscn"
const BOSS_HEALTH_HUD_SCENE_PATH := "res://scene/boss/linglan/boss_health_hud.tscn"
const LINGLAN_ENRAGE_SNIPER_CONFIG_PATH := "res://resources/config/enemies/capoo_sniper.tres"
const COUNTDOWN_FINAL_SECONDS := 3
const PLAYER_RESPAWN_DELAYS: Array[int] = [5, 10, 15, 20]
const PLAYER_RESPAWN_INVINCIBILITY_SECONDS := 3.0
const SPECTATOR_CAMERA_SPEED := 180.0
const PURCHASE_RESULT_SUCCESS := 0
const PURCHASE_RESULT_ALREADY_OWNED := 1
const PURCHASE_RESULT_INSUFFICIENT_XIRANG := 2
const PURCHASE_RESULT_INVALID_PLAYER := 3
const PURCHASE_RESULT_SKILL1_UPGRADE_SUCCESS := 4
const PURCHASE_RESULT_SKILL1_UPGRADE_MAXED := 5
const MIN_WAVE_SPAWN_INTERVAL_SECONDS := 0.025
const MAX_WAVE_SPAWN_COUNT_PER_TICK := 4
const DEFAULT_MUSIC_VOLUME_DB := -6.0
const MUSIC_FADE_IN_SECONDS := 3.0
const MUSIC_FADE_IN_START_VOLUME_DB := -12.0
const LINGLAN_SPAWN_LEFT_OFFSET := 96.0
const LINGLAN_SKILL4_AUTHORED_TARGET_CENTER := Vector2(6.5, 2.0)
const BOSS_INTRO_CAMERA_FOCUS_SECONDS := 0.9
const LINGLAN_AIRDROP_NEARBY_RADIUS := Vector2(96.0, 80.0)
const DEFEAT_CAMERA_TRAVEL_SECONDS := 0.55
const INITIAL_PLAYER_XIRANG := 1000
const DEFAULT_BASE_HEALTH := 100
const XIAOCONG_INTERACTION_DISTANCE := 220.0
# A full background sweep only needs to keep long-lived objectives reasonably
# fresh. Topology changes and player availability changes request an immediate
# budgeted pass below, so the idle cadence can stay deliberately conservative.
const ENEMY_RETARGET_INTERVAL_SECONDS := 0.60
const SINGLEPLAYER_CAMPAIGN_PATH := (
	"res://resources/config/campaigns/tower_defense/singleplayer/campaign.tres"
)
const MULTIPLAYER_CAMPAIGN_PATH := (
	"res://resources/config/campaigns/tower_defense/multiplayer/campaign.tres"
)
const FORMAL_PROGRESSION_CONFIG_PATH := (
	"res://resources/config/campaigns/tower_defense/formal_progression.tres"
)
const ENEMY_RETARGET_MAX_PER_PHYSICS_FRAME := 16
# Target priority is evaluated in logical tile units so it remains stable if a
# TileMap transform changes. These world-space constants document the current
# authored 16 px grid and remain useful to UI/tests.
const AUTHORED_LOGICAL_TILE_SIZE := 16.0
const PLANT_OBJECTIVE_AGGRO_RADIUS_CELLS := 8.0
const PLAYER_OBJECTIVE_AGGRO_RADIUS_CELLS := 10.0
const PLAYER_OBJECTIVE_AGGRO_RADIUS := (
	PLAYER_OBJECTIVE_AGGRO_RADIUS_CELLS * AUTHORED_LOGICAL_TILE_SIZE
)
# Keep navigation's nearby-moving-target tier independent from the gameplay
# aggro radius. This lets target acquisition shrink without silently changing
# how an already-selected moving objective is navigated.
const PLAYER_NEAR_MOVING_DIRECT_DISTANCE_CELLS := 16.0
const PLAYER_NEAR_MOVING_DIRECT_DISTANCE := (
	PLAYER_NEAR_MOVING_DIRECT_DISTANCE_CELLS * AUTHORED_LOGICAL_TILE_SIZE
)
const PLANT_PLACEMENT_REJECT_INVALID_REQUEST := &"invalid_request"
const PLANT_PLACEMENT_REJECT_INVALID_PLAYER := &"invalid_player"
const PLANT_PLACEMENT_REJECT_INVALID_CONFIG := &"invalid_config"
const PLANT_PLACEMENT_REJECT_INVALID_POSITION := &"invalid_position"
const PLANT_PLACEMENT_REJECT_INVALID_INVENTORY_ITEM := &"invalid_inventory_item"
const PLANT_PLACEMENT_REJECT_STALE_INVENTORY := &"stale_inventory"
const PLANT_PLACEMENT_REJECT_FREE_DISABLED := &"free_placement_disabled"
const PLANT_PLACEMENT_REJECT_FLOW_LOCKED := &"flow_locked"
const TERRAIN_NETWORK_BATCH_MAX_CELLS := 96
const UNSUPPORTED_PLANT_DAMAGE_INTERVAL_SECONDS := 1.0
const PLANT_LIFECYCLE_VFX_PREWARM_COUNT := 8
const PLANT_LIFECYCLE_VFX_RETAINED_CAPACITY := 32
# Wave 9 can have roughly 120 AK rounds and more than 30 mage fireballs alive
# concurrently. Instantiate that steady-state set while the loading mask is
# active instead of growing the elastic gameplay pools on synchronized attacks.
# The retained capacities are deliberately unchanged.
const LEGACY_CAPOO_AK47_BULLET_PREWARM_COUNT := 32
const EXPANDED_CAPOO_AK47_BULLET_PREWARM_COUNT := 128
const LEGACY_CAPOO_MAGE_FIREBALL_PREWARM_COUNT := 24
const EXPANDED_CAPOO_MAGE_FIREBALL_PREWARM_COUNT := 64
const LINGLAN_SKILL_REFERENCE_ARENA_POSITION := Vector2i(-3, -1)
const MULTIPLAYER_SPAWN_OFFSETS: Array[Vector2] = [
	Vector2.ZERO,
	Vector2(18.0, 0.0),
	Vector2(0.0, 18.0),
	Vector2(18.0, 18.0),
	Vector2(-18.0, 0.0),
	Vector2(0.0, -18.0),
	Vector2(-18.0, -18.0),
	Vector2(18.0, -18.0),
]

signal base_health_changed(current_health: int, maximum_health: int, revision: int)

# Production defaults to loading-time prewarming. The cohort performance probe
# can disable it before scene instantiation for a strict old/new A/B.
static var expanded_projectile_pool_prewarm_enabled := true
var _singleplayer_tango_charge_started_at: float = -1.0

@export_group("战役资源")
@export var singleplayer_campaign: WaveCampaignConfig = null
@export var multiplayer_campaign: WaveCampaignConfig = null

@export_group("战斗流程")
@export var progression_config: TowerDefenseProgressionConfig = null
@export var day_cycle_config: DayCycleConfig = preload(
	"res://resources/config/day_cycle/tower_defense_day_cycle.tres"
)
@export var auto_start_waves: bool = true
@export var linglan_boss_enabled: bool = false

@export_group("沙盒调试")
@export var sandbox_free_building_enabled := false

@onready var player_spawn: Marker2D = $PlayerSpawn
@onready var ground_tile_map_layer: TileMapLayer = $GroundTileMapLayer
@onready var overlay_tile_map_layer: TileMapLayer = $OverlayTileMapLayer
@onready var home_gate_controller: HomeGateController = $HomeGateController
@onready var dual_grid_terrain: DualGridTilemap = $DualGridTerrain
@onready var enemy_spawn_points_root: Node2D = $EnemySpawnPoints
@onready var enemy_spawn_timer: Timer = $EnemySpawnTimer
@onready var state_timer: Timer = $StateTimer
@onready var plant_terrain_decay_timer: Timer = $PlantTerrainDecayTimer
@onready var map_camera: Camera2D = $Camera2D
@onready var music_player: AudioStreamPlayer = $MusicPlayer
@onready var countdown_audio: AudioStreamPlayer = $CountdownAudio
@onready var wave_start_audio: AudioStreamPlayer = $WaveStartAudio
@onready var defeat_audio: AudioStreamPlayer = $DefeatAudio
@onready var currency_hud: CurrencyHUD = $CurrencyHUD
@onready var wave_hud: WaveHUD = $WaveHUD
@onready var tower_defense_status_hud: TowerDefenseStatusHUD = $TowerDefenseStatusHUD
@onready var tower_defense_minimap: TowerDefenseMinimap = $TowerDefenseMinimap
@onready var oak_warehouse_panel: OakWarehousePanel = $OakWarehousePanel
@onready var production_building_panel: ProductionBuildingPanel = $ProductionBuildingPanel
@onready var research_center_panel: ResearchCenterPanel = $ResearchCenterPanel
@onready var player_profile_panel: PlayerProfilePanel = $PlayerProfilePanel
@onready var settings_panel: SettingsPanel = $SettingsLayer/SettingsPanel
@onready var debug_collectible_window: DebugCollectibleWindow = $SettingsLayer/DebugCollectibleWindow
@onready var merchant: ZhuangfangyiMerchant = $ZhuangfangyiMerchant
@onready var luoxi_merchant: LuoxiMerchant = $LuoxiMerchant
@onready var luoxi_special_game_coordinator: LuoxiSpecialGameCoordinator = (
	$LuoxiSpecialGameCoordinator
)
@onready var fate_coordinator: FateCoordinator = $FateCoordinator
@onready var fate_manager: TowerDefenseFateManager = (
	$FateCoordinator/TowerDefenseFateManager
)
@onready var xiaocong_fate_interlude: XiaocongFateInterlude = $XiaocongFateInterlude
@onready var boss_container: Node2D = $BossContainer
@onready var guardian_aura_system: GuardianAuraSystem = $GuardianAuraSystem
@onready var plant_container: Node2D = $PlantContainer
@onready var plant_system: PlantSystem = $PlantSystem
@onready var vegetation_spread_system: VegetationSpreadSystem = $VegetationSpreadSystem
@onready var production_coordinator: ProductionCoordinator = $ProductionCoordinator
@onready var orange_charging_aura_coordinator: OrangeChargingAuraCoordinator = (
	$OrangeChargingAuraCoordinator
)
@onready var research_coordinator: ResearchCoordinator = $ResearchCoordinator
@onready var plant_placement_controller: PlantPlacementController = $PlantPlacementController
@onready var plant_lifecycle_shader_prewarm: Sprite2D = $PlantLifecycleShaderPrewarm
@onready var bamboo_mortar_lifecycle_shader_prewarm: Sprite2D = (
	$BambooMortarLifecycleShaderPrewarm
)
@onready var bamboo_mortar_glow_shader_prewarm: Polygon2D = (
	$BambooMortarGlowShaderPrewarm
)
@onready var damage_number_pool: DamageNumberPool = $DamageNumberPool
@onready var session_object_pool: SessionObjectPool = $SessionObjectPool
@onready var bamboo_mortar_combat_system: BambooMortarCombatSystem = (
	$BambooMortarCombatSystem
)
@onready var run_state: RunStateStore = get_node("/root/RunState") as RunStateStore

var random_generator := RandomNumberGenerator.new()
var multiplayer_terrain_revision: int = 0
var authored_terrain_baseline: Dictionary = {}
var multiplayer_terrain_overrides: Dictionary = {}
var active_campaign: WaveCampaignConfig = null
var flow_graph: FlowGraphConfig = null
var waves: Array[WaveConfig] = []
var bosses: Array[Resource] = []
var enemy_spawn_points: Array[Marker2D] = []
var enemy_spawn_points_by_name: Dictionary[StringName, Marker2D] = {}
var active_wave_spawn_points: Array[Marker2D] = []
var spawn_point_configuration_valid := true
var pending_enemy_configs: Array[EnemyConfig] = []
var pending_enemy_xirang_kill_rewards: Array[int] = []
var pending_enemy_config_index: int = 0
var active_wave_enemy_ids: Dictionary = {}
var hud_alive_enemy_ids: Dictionary = {}

var current_wave_index: int = 0
var current_wave_total: int = 0
var current_wave_spawned: int = 0
var current_wave_defeated: int = 0
var current_wave_escaped: int = 0
var current_wave_resolved: int = 0
var countdown_seconds: int = 0
var current_flow_step: FlowStepConfig = null
var next_flow_step_after_rest: FlowStepConfig = null
var music_fade_tween: Tween = null
var boss_intro_camera_tween: Tween = null
var defeat_camera_tween: Tween = null
var defeat_presentation_completed := false
var multiplayer_player_names: Dictionary = {}
var multiplayer_player_character_ids: Dictionary = {}
var multiplayer_spawn_slot_indices: Dictionary[int, int] = {}
var pending_multiplayer_pickup_exit_ids: Dictionary = {}
var pending_multiplayer_enemy_escape_ids: Dictionary = {}
var enemy_retarget_time_left: float = 0.0
var enemy_retarget_sweep_remaining: int = 0
var enemy_retarget_cursor: int = 0
var home_objective_targets: Array[Node2D] = []
var maximum_base_health: int = DEFAULT_BASE_HEALTH
var current_base_health: int = DEFAULT_BASE_HEALTH
var base_health_revision: int = 0
var has_received_remote_base_health_snapshot := false
var resolved_home_enemy_ids: Dictionary = {}
var next_multiplayer_enemy_net_id: int = 1
var next_multiplayer_pickup_net_id: int = 1000
var next_multiplayer_plant_net_id: int = 1
var luoxi_collectible_claim_counts: Dictionary = {}
var linglan_boss_started: bool = false
var active_boss_config: Resource
var linglan_boss: LinglanBoss = null
var linglan_boss_intro_vfx: LinglanBossIntroVFX = null
var boss_health_hud: BossHealthHUD = null
var linglan_skill4_orb_anchor_global_position := Vector2.ZERO
var linglan_skill4_orb_authored_center := LINGLAN_SKILL4_AUTHORED_TARGET_CENTER
var linglan_skill4_orb_anchor_valid := false
var linglan_slime_configs: Array[EnemyConfig] = []
var linglan_enrage_sniper_config: EnemyConfig = null
var boss_runtime_scene_loads_requested: bool = false
var boss_runtime_resources_by_path: Dictionary[String, Resource] = {}
var navigation_prewarm_requested: bool = false
var navigation_prewarmed: bool = false
var plant_lifecycle_shader_prewarmed: bool = false
var _previous_physics_interpolation_enabled := false
var _owns_physics_interpolation_override := false
var merchant_intermission_active := false
var player_wave_death_counts: Dictionary = {}
var singleplayer_respawn_time_left := -1.0
var singleplayer_respawn_last_seconds := -1
var spectator_camera_active := false
var projectile_pool_registration_ms := 0.0
var fate_frozen_terrain_decay_time_left := 0.0
var remote_fate_entry_in_progress := false
var remote_fate_departure_in_progress := false
var remote_fate_departure_covered := false
var pending_remote_fate_flow_state: Dictionary = {}
var starting_package_granted := false
var progression_started_msec := 0
var first_defense_tower_seconds := -1.0
var water_chain_online_seconds := -1.0
var daily_xirang_rewards: Dictionary[int, int] = {}
var progression_day_records: Array[Dictionary] = []
var runtime_prewarm_tearing_down := false


func _enter_tree() -> void:
	runtime_prewarm_tearing_down = false
	_previous_physics_interpolation_enabled = get_tree().physics_interpolation
	get_tree().physics_interpolation = true
	_owns_physics_interpolation_override = true


func _exit_tree() -> void:
	runtime_prewarm_tearing_down = true
	LuoxiMerchant.reset_runtime_choice_count()
	if _owns_physics_interpolation_override:
		get_tree().physics_interpolation = _previous_physics_interpolation_enabled
		_owns_physics_interpolation_override = false


func _ready() -> void:
	random_generator.randomize()
	LuoxiMerchant.reset_runtime_choice_count()
	if day_cycle_config == null or not day_cycle_config.is_valid():
		push_error("GameTowerDefense: DayCycleConfig 无效，停止初始化。")
		set_process(false)
		set_physics_process(false)
		return
	bamboo_mortar_combat_system.setup(self)
	bamboo_mortar_combat_system.set_authoritative_processing_enabled(
		runtime_mode != RuntimeMode.CLIENT_VIEW
	)
	if runtime_mode == RuntimeMode.SINGLEPLAYER:
		var load_coordinator := get_node_or_null("/root/GameLoadCoordinator")
		if load_coordinator != null and bool(load_coordinator.call("is_loading")):
			defer_runtime_activation()
	if not _configure_active_campaign():
		set_process(false)
		set_physics_process(false)
		return
	if runtime_mode == RuntimeMode.SINGLEPLAYER:
		run_state.ensure_run_started()
		_configure_singleplayer_player()
	_collect_enemy_spawn_points()
	_configure_timers()
	_prewarm_enemy_visual_resources()
	GameRuntimeBase.register_common_visual_effect_pools(session_object_pool)
	session_object_pool.register_scene(
		PLANT_PLACEMENT_PARTICLES_SCENE,
		PLANT_LIFECYCLE_VFX_PREWARM_COUNT,
		PLANT_LIFECYCLE_VFX_RETAINED_CAPACITY
	)
	session_object_pool.register_scene(
		PLANT_REMOVAL_SMOKE_SCENE,
		PLANT_LIFECYCLE_VFX_PREWARM_COUNT,
		PLANT_LIFECYCLE_VFX_RETAINED_CAPACITY
	)
	var projectile_pool_registration_started_usec := Time.get_ticks_usec()
	session_object_pool.register_scene(PLAYER_BULLET_POOL_SCENE, 64, 768)
	session_object_pool.register_scene(TANGO_LASER_BULLET_POOL_SCENE, 64, 768)
	session_object_pool.register_scene(
		CAPOO_AK47_BULLET_POOL_SCENE,
		(
			EXPANDED_CAPOO_AK47_BULLET_PREWARM_COUNT
			if expanded_projectile_pool_prewarm_enabled
			else LEGACY_CAPOO_AK47_BULLET_PREWARM_COUNT
		),
		384
	)
	session_object_pool.register_scene(CAPOO_SMG_BULLET_POOL_SCENE, 48, 512)
	session_object_pool.register_scene(CAPOO_RPG_ROCKET_POOL_SCENE, 24, 192)
	session_object_pool.register_scene(
		CAPOO_MAGE_FIREBALL_POOL_SCENE,
		(
			EXPANDED_CAPOO_MAGE_FIREBALL_PREWARM_COUNT
			if expanded_projectile_pool_prewarm_enabled
			else LEGACY_CAPOO_MAGE_FIREBALL_PREWARM_COUNT
		),
		192
	)
	# A 7 s flight plus expiry visuals slightly overlaps a third 3.6 s attack
	# cycle. Capacity includes those visual-only leases and release quarantine.
	session_object_pool.register_scene(
		FIRE_SORCERER_FIREBALL_VOLLEY_POOL_SCENE,
		48,
		704
	)
	session_object_pool.register_scene(
		FIRE_SORCERER_ELITE_FIREBALL_VOLLEY_POOL_SCENE,
		48,
		704
	)
	# One 7 s ice spike spans two 3.6 s cast cycles.  Capacity intentionally
	# covers the 300-enemy gameplay probe while prewarm stays loading-friendly.
	session_object_pool.register_scene(FROST_SORCERER_ICE_SPIKE_POOL_SCENE, 48, 704)
	GameRuntimeBase.register_capoo_mage_fireball_impact_pool(
		session_object_pool,
		48,
		64
	)
	projectile_pool_registration_ms = float(
		Time.get_ticks_usec() - projectile_pool_registration_started_usec
	) / 1000.0
	session_object_pool.register_scene(YUANSHI_FIRE_PROJECTILE_POOL_SCENE, 48, 384)
	session_object_pool.register_scene(AGAVE_CANNONBALL_POOL_SCENE, 48, 384)
	# The formal synchronized ceiling is 100 mortars. Prewarm the complete
	# first volley during loading so gameplay never pays a 64 -> 100 expansion.
	session_object_pool.register_scene(BAMBOO_MORTAR_SHELL_POOL_SCENE, 100, 384)
	session_object_pool.register_scene(COLLECTIBLE_ARROW_POOL_SCENE, 48, 384)
	session_object_pool.register_scene(COLLECTIBLE_SAKURA_ROCKET_POOL_SCENE, 16, 128)
	# 18 rings/s * 20 directions * 2 s lifetime = 720 live bullets. The extra
	# retained headroom covers the pool's one-physics-frame release quarantine;
	# elastic acquisition still preserves every shot after an unusually long frame.
	session_object_pool.register_scene(LINGLAN_SKILL1_BULLET_POOL_SCENE, 64, 768)
	# A 0.16 s effect at the same peak fire rate needs about 58 concurrent leases.
	session_object_pool.register_scene(LINGLAN_SAKURA_HIT_EFFECT_POOL_SCENE, 16, 96)
	# Tower-defense batteries issue independently staggered target queries. Keep
	# its already-validated policy of forcing every bounded query through buckets.
	enable_singleplayer_combat_target_index(true)
	guardian_aura_system.set_authoritative_processing_enabled(
		runtime_mode != RuntimeMode.CLIENT_VIEW
	)
	if not enemy_container.child_entered_tree.is_connected(
		_on_dynamic_pickup_container_child_entered
	):
		enemy_container.child_entered_tree.connect(
			_on_dynamic_pickup_container_child_entered
		)
	if not boss_container.child_entered_tree.is_connected(
		_on_dynamic_pickup_container_child_entered
	):
		boss_container.child_entered_tree.connect(
			_on_dynamic_pickup_container_child_entered
		)
	if runtime_mode != RuntimeMode.SINGLEPLAYER:
		run_state.ensure_run_started()
		run_state.set_active_multiplayer_peer(multiplayer_local_peer_id)
		_configure_multiplayer_players()
		production_coordinator.configure_multiplayer_output_peers(peer_players.keys())
		_register_static_multiplayer_pickups()
	if player == null:
		push_error("Game: 无法创建当前角色，停止初始化。")
		set_process(false)
		set_physics_process(false)
		return
	tower_defense_status_hud.set_dead_player_list_enabled(
		runtime_mode != RuntimeMode.SINGLEPLAYER
	)
	tower_defense_status_hud.show()
	_attach_camera_to_local_player()
	wave_hud.configure_tower_defense(
		current_base_health,
		maximum_base_health,
		day_cycle_config
	)
	_configure_home_defense()
	_configure_plant_defense_system()
	production_coordinator.set_authoritative_processing_enabled(
		runtime_mode != RuntimeMode.CLIENT_VIEW
	)
	if not production_coordinator.personal_inventory_output_committed.is_connected(
		_on_personal_inventory_output_committed
	):
		production_coordinator.personal_inventory_output_committed.connect(
			_on_personal_inventory_output_committed
		)
	research_coordinator.setup(production_coordinator, plant_system, self)
	research_coordinator.set_authoritative_processing_enabled(
		runtime_mode != RuntimeMode.CLIENT_VIEW
	)
	if not research_coordinator.research_state_changed.is_connected(
		_on_research_recipe_unlocks_changed
	):
		research_coordinator.research_state_changed.connect(
			_on_research_recipe_unlocks_changed
		)
	_register_research_players()
	_configure_minimap()
	_apply_initial_player_xirang()
	_start_progression_metrics()
	if (
		runtime_mode != RuntimeMode.CLIENT_VIEW
		and not _grant_tower_defense_starting_package()
	):
		push_error("GameTowerDefense: 无法原子发放正式塔防起步包，停止初始化。")
		set_process(false)
		set_physics_process(false)
		return
	currency_hud.bind_player(player)
	player_profile_panel.set_research_coordinator(research_coordinator)
	player_profile_panel.bind_player(player)
	currency_hud.settings_requested.connect(_on_currency_hud_settings_requested)
	currency_hud.profile_requested.connect(_on_currency_hud_profile_requested)
	settings_panel.opened.connect(_on_exclusive_modal_opened)
	settings_panel.closed.connect(_on_settings_panel_closed)
	player_profile_panel.opened.connect(_on_exclusive_modal_opened)
	player_profile_panel.closed.connect(_on_player_profile_panel_closed)
	debug_collectible_window.collectible_requested.connect(_on_debug_collectible_requested)
	debug_collectible_window.closed.connect(_on_debug_collectible_window_closed)
	wave_hud.set_return_button_text("返回菜单" if runtime_mode == RuntimeMode.SINGLEPLAYER else "返回大厅")
	if not wave_hud.return_to_lobby_requested.is_connected(_on_wave_hud_return_to_lobby_requested):
		wave_hud.return_to_lobby_requested.connect(_on_wave_hud_return_to_lobby_requested)
	if not wave_hud.start_wave_requested.is_connected(_on_wave_hud_start_wave_requested):
		wave_hud.start_wave_requested.connect(_on_wave_hud_start_wave_requested)
	if runtime_mode == RuntimeMode.SINGLEPLAYER:
		player.died.connect(_on_player_died)
		player.revived.connect(_on_player_revived.bind(0))
	luoxi_special_game_coordinator.setup(
		self,
		run_state,
		luoxi_merchant,
		random_generator,
		runtime_mode != RuntimeMode.CLIENT_VIEW
	)
	_set_merchant_active(false)
	fate_coordinator.setup(self, day_cycle_config)
	_configure_xiaocong_fate_flow()
	_configure_linglan_boss()
	call_deferred("_deferred_request_boss_runtime_scene_loads")

	if runtime_mode == RuntimeMode.CLIENT_VIEW:
		auto_start_waves = false
		_start_client_flow_countdown(
			WaveState.PRE_WAVE,
			_get_flow_step_id(_get_start_flow_step()),
			_get_initial_preparation_seconds()
		)
	elif auto_start_waves and not runtime_activation_deferred and _is_flow_system_ready():
		_enter_pre_flow_step(_get_start_flow_step())
	else:
		_show_tower_defense_wave_progress()
	if runtime_mode == RuntimeMode.CLIENT_VIEW:
		if runtime_activation_deferred:
			call_deferred("prepare_shared_runtime_data_and_complete")
		else:
			mark_runtime_preparation_complete()
	elif auto_start_waves or runtime_activation_deferred:
		_schedule_enemy_navigation_prewarm()


func _on_runtime_activated() -> void:
	if runtime_mode == RuntimeMode.CLIENT_VIEW:
		return
	if current_flow_step == null and auto_start_waves and _is_flow_system_ready():
		_enter_pre_flow_step(_get_start_flow_step())


func _physics_process(delta: float) -> void:
	_update_local_spectator_camera(delta)
	_update_singleplayer_respawn(delta)
	if runtime_mode != RuntimeMode.CLIENT_VIEW:
		_update_tower_defense_enemy_targets(delta)
	if runtime_mode == RuntimeMode.HOST_AUTHORITY:
		_update_multiplayer_remote_player_passive_state(delta)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("full_screen"):
		_toggle_full_screen()
		get_viewport().set_input_as_handled()
		return

	if event.is_action_pressed("cheat_collectibles"):
		if sandbox_free_building_enabled:
			_toggle_debug_collectible_window()
		get_viewport().set_input_as_handled()


func configure_multiplayer(
	mode: int,
	local_peer_id: int,
	player_names: Dictionary,
	player_character_ids: Dictionary = {}
) -> void:
	runtime_mode = mode as RuntimeMode
	multiplayer_local_peer_id = local_peer_id
	multiplayer_player_names = player_names.duplicate()
	multiplayer_player_character_ids = player_character_ids.duplicate()


func request_tango_charge_started(direction: Vector2) -> bool:
	if runtime_mode != RuntimeMode.SINGLEPLAYER:
		return false
	if not _is_valid_singleplayer_tango_player(player):
		return false
	var safe_direction := _sanitize_tango_charge_direction(player, direction)
	if not bool(player.call("try_authoritative_tango_charge_started", safe_direction)):
		return false
	_singleplayer_tango_charge_started_at = Time.get_ticks_usec() / 1000000.0
	return true


func request_tango_charge_released(direction: Vector2) -> bool:
	if runtime_mode != RuntimeMode.SINGLEPLAYER or _singleplayer_tango_charge_started_at < 0.0:
		return false
	var started_at := _singleplayer_tango_charge_started_at
	_singleplayer_tango_charge_started_at = -1.0
	if not _is_valid_singleplayer_tango_player(player):
		return false
	var elapsed := maxf(Time.get_ticks_usec() / 1000000.0 - started_at, 0.0)
	if elapsed + TANGO_CHARGE_THRESHOLD_EPSILON < TANGO_MINIMUM_CHARGE_SECONDS:
		player.call("cancel_authoritative_tango_charge")
		return true
	var charge_ratio := clampf(
		(elapsed - TANGO_MINIMUM_CHARGE_SECONDS)
		/ (TANGO_MAXIMUM_CHARGE_SECONDS - TANGO_MINIMUM_CHARGE_SECONDS),
		0.0,
		1.0
	)
	var safe_direction := _sanitize_tango_charge_direction(player, direction)
	var result_variant: Variant = player.call(
		"try_authoritative_tango_charge_released",
		safe_direction,
		charge_ratio
	)
	if not (result_variant is Dictionary):
		player.call("cancel_authoritative_tango_charge")
		return false
	var result := result_variant as Dictionary
	var succeeded := bool(result.get("accepted", false)) and bool(result.get("fired", false))
	if not succeeded:
		player.call("cancel_authoritative_tango_charge")
	return succeeded


func request_tango_charge_cancelled() -> bool:
	if runtime_mode != RuntimeMode.SINGLEPLAYER:
		return false
	var had_active_charge := _singleplayer_tango_charge_started_at >= 0.0
	_singleplayer_tango_charge_started_at = -1.0
	if not _is_valid_singleplayer_tango_player(player):
		return false
	player.call("cancel_authoritative_tango_charge")
	return had_active_charge


func _is_valid_singleplayer_tango_player(player_node: Player) -> bool:
	return (
		player_node != null
		and is_instance_valid(player_node)
		and player_node.has_method("is_tango")
		and bool(player_node.call("is_tango"))
		and player_node.has_method("try_authoritative_tango_charge_started")
		and player_node.has_method("try_authoritative_tango_charge_released")
		and player_node.has_method("cancel_authoritative_tango_charge")
	)


func _sanitize_tango_charge_direction(player_node: Player, direction: Vector2) -> Vector2:
	if is_finite(direction.x) and is_finite(direction.y) and direction.length_squared() > 0.0001:
		return direction.normalized()
	match player_node.get_multiplayer_facing_id():
		1:
			return Vector2.LEFT
		2:
			return Vector2.UP
		3:
			return Vector2.DOWN
		_:
			return Vector2.RIGHT


func supports_tower_defense() -> bool:
	return true


func _apply_wave_start_lighting(wave_number: int) -> void:
	if _is_night_wave(wave_number):
		transition_world_to_night()
	else:
		transition_world_to_day()


func _apply_intermission_lighting(completed_wave_number: int) -> void:
	if day_cycle_config.is_night_intermission_after_wave(completed_wave_number):
		transition_world_to_night()
	else:
		transition_world_to_day()


func _is_night_wave(wave_number: int) -> bool:
	return day_cycle_config.is_night_wave(wave_number)


func _get_day_number_for_wave(wave_number: int) -> int:
	return day_cycle_config.get_day_number(wave_number)


func supports_multiplayer_terrain_state() -> bool:
	return true


func request_bamboo_mortar_target(
	owner: Node2D,
	minimum_range: float,
	maximum_range: float,
	callback: Callable
) -> bool:
	if (
		runtime_mode == RuntimeMode.CLIENT_VIEW
		or bamboo_mortar_combat_system == null
	):
		return false
	return bamboo_mortar_combat_system.request_target(
		owner,
		minimum_range,
		maximum_range,
		callback
	)


func cancel_bamboo_mortar_target_request(owner: Node) -> void:
	if bamboo_mortar_combat_system == null:
		return
	bamboo_mortar_combat_system.cancel_target_request(owner)


func select_bamboo_mortar_target_sync_for_fixture(
	center: Vector2,
	minimum_range: float,
	maximum_range: float
) -> Enemy:
	if bamboo_mortar_combat_system == null:
		return null
	return bamboo_mortar_combat_system.select_target_sync_for_fixture(
		center,
		minimum_range,
		maximum_range
	)


func queue_bamboo_mortar_explosion(
	landing_position: Vector2,
	inner_radius: float,
	outer_radius: float,
	inner_damage: int,
	outer_damage: int,
	damage_source_id: int
) -> bool:
	if (
		runtime_mode == RuntimeMode.CLIENT_VIEW
		or bamboo_mortar_combat_system == null
	):
		return false
	return bamboo_mortar_combat_system.queue_explosion(
		landing_position,
		inner_radius,
		outer_radius,
		inner_damage,
		outer_damage,
		damage_source_id
	)


func apply_authoritative_plant_enemy_damage_batch(
	damage_source_id: int,
	enemy: Enemy,
	damage_amounts: PackedInt64Array,
	hit_counts: PackedInt32Array,
	impact_direction: Vector2,
	damage_type: EnemyConfig.DamageType
) -> bool:
	if (
		runtime_mode == RuntimeMode.CLIENT_VIEW
		or enemy == null
		or not is_instance_valid(enemy)
		or enemy.is_dead
		or damage_amounts.is_empty()
	):
		return false
	var safe_direction := (
		impact_direction
		if impact_direction.is_finite()
		else Vector2.ZERO
	)
	var request := DamageBatchRequest.new(
		damage_amounts,
		hit_counts,
		int(damage_type)
	)
	request.with_source(null, damage_source_id, &"plant_damage_batch")
	request.with_directions(safe_direction)
	return enemy.apply_combat_damage(request).accepted


func query_living_plants_in_radius_into(
	center: Vector2,
	radius: float,
	result: Array[PlantDefense]
) -> void:
	result.clear()
	if plant_system == null:
		return
	plant_system.query_living_plants_in_world_radius_into(
		center,
		radius,
		result
	)


func get_bamboo_mortar_combat_metrics() -> Dictionary:
	if bamboo_mortar_combat_system == null:
		return {}
	return bamboo_mortar_combat_system.get_metrics_snapshot()


func get_fixed_multiplayer_respawn_position(peer_id: int) -> Variant:
	if player_spawn == null or not multiplayer_spawn_slot_indices.has(peer_id):
		return null
	var slot_index := int(multiplayer_spawn_slot_indices[peer_id])
	return player_spawn.global_position + _get_multiplayer_spawn_offset(slot_index)


func _configure_active_campaign() -> bool:
	if progression_config == null:
		progression_config = load(
			FORMAL_PROGRESSION_CONFIG_PATH
		) as TowerDefenseProgressionConfig
	if progression_config == null or not progression_config.is_valid():
		push_error("GameTowerDefense: 正式成长配置缺失或无效。")
		return false
	active_campaign = (
		singleplayer_campaign
		if runtime_mode == RuntimeMode.SINGLEPLAYER
		else multiplayer_campaign
	)
	if active_campaign == null:
		var campaign_path := (
			SINGLEPLAYER_CAMPAIGN_PATH
			if runtime_mode == RuntimeMode.SINGLEPLAYER
			else MULTIPLAYER_CAMPAIGN_PATH
		)
		active_campaign = load(campaign_path) as WaveCampaignConfig
	flow_graph = null
	waves.clear()
	bosses.clear()
	if active_campaign == null:
		push_error("GameTowerDefense: 当前运行模式没有配置 WaveCampaignConfig。")
		return false
	var campaign_errors := active_campaign.validate_campaign()
	if not campaign_errors.is_empty():
		for error in campaign_errors:
			push_error(error)
		return false
	flow_graph = active_campaign.flow_graph
	waves.assign(active_campaign.get_waves())
	for boss_config in active_campaign.get_bosses():
		bosses.append(boss_config)
	return true


func _configure_singleplayer_player() -> void:
	var character_id := _get_selected_singleplayer_character_id()
	var player_instance := _instantiate_player_character(character_id)
	if player_instance == null:
		return
	player_instance.name = "Player"
	player_instance.position = player_spawn.position
	add_child(player_instance)
	player = player_instance


func _attach_camera_to_local_player() -> void:
	if map_camera == null or player == null:
		return
	# The local player moves on the 60 Hz physics clock while the renderer can
	# run much faster. Interpolate this one branch so the following camera does
	# not turn each physics step into a whole-screen judder. The scene root is
	# explicitly opted out, keeping UI, tweens and network-smoothed proxies on
	# their existing timing paths.
	map_camera.process_callback = Camera2D.CAMERA2D_PROCESS_PHYSICS
	player.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_ON
	if map_camera.get_parent() != player:
		map_camera.reparent(player)
	map_camera.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_INHERIT
	map_camera.position = Vector2.ZERO
	map_camera.zoom = Vector2(2.0, 2.0)
	map_camera.position_smoothing_enabled = false
	map_camera.enabled = true
	player.reset_physics_interpolation()
	map_camera.reset_physics_interpolation()


func _configure_home_defense() -> void:
	maximum_base_health = DEFAULT_BASE_HEALTH
	current_base_health = maximum_base_health
	base_health_revision = 0
	resolved_home_enemy_ids.clear()
	home_objective_targets.clear()
	if home_gate_controller == null:
		push_error("GameTowerDefense: HomeGateController 缺失。")
	else:
		home_gate_controller.setup(overlay_tile_map_layer)
		home_objective_targets = home_gate_controller.get_objective_targets()
		if not home_gate_controller.enemy_reached_home.is_connected(_on_enemy_reached_home):
			home_gate_controller.enemy_reached_home.connect(_on_enemy_reached_home)
	_update_base_health_display()


func get_home_objective_targets() -> Array[Node2D]:
	return home_objective_targets.duplicate()


func get_linglan_home_objective_target(from_position: Vector2) -> Node2D:
	var nearest_target: Node2D = null
	var nearest_distance_squared := INF
	for target in home_objective_targets:
		if target == null or not is_instance_valid(target):
			continue
		var distance_squared := from_position.distance_squared_to(target.global_position)
		if distance_squared < nearest_distance_squared:
			nearest_distance_squared = distance_squared
			nearest_target = target
	return nearest_target


func _configure_minimap() -> void:
	tower_defense_minimap.setup(
		player,
		map_camera,
		ground_tile_map_layer,
		dual_grid_terrain,
		overlay_tile_map_layer,
		self,
		enemy_container,
		boss_container,
		plant_system
	)


func get_base_health_snapshot() -> Dictionary:
	return {
		"current_health": current_base_health,
		"maximum_health": maximum_base_health,
		"revision": base_health_revision,
	}


func apply_remote_base_health(
	new_current_health: int,
	new_maximum_health: int,
	new_revision: int
) -> void:
	if runtime_mode != RuntimeMode.CLIENT_VIEW:
		return
	if (
		has_received_remote_base_health_snapshot
		and new_revision <= base_health_revision
	):
		return
	if not has_received_remote_base_health_snapshot and new_revision < base_health_revision:
		return
	var previous_health := current_base_health
	var safe_maximum := maxi(new_maximum_health, 1)
	var safe_current := clampi(new_current_health, 0, safe_maximum)
	maximum_base_health = safe_maximum
	current_base_health = safe_current
	base_health_revision = new_revision
	_update_base_health_display(has_received_remote_base_health_snapshot)
	base_health_changed.emit(current_base_health, maximum_base_health, base_health_revision)
	if (
		has_received_remote_base_health_snapshot
		and current_base_health < previous_health
		and tower_defense_status_hud != null
	):
		tower_defense_status_hud.play_gate_damage_warning()
	has_received_remote_base_health_snapshot = true


func apply_remote_enemy_escape(net_id: int) -> void:
	if runtime_mode != RuntimeMode.CLIENT_VIEW or net_id <= 0:
		return
	var enemy := get_enemy_for_net_id(net_id)
	if enemy == null or not is_instance_valid(enemy):
		return
	multiplayer_enemies_by_net_id.erase(net_id)
	multiplayer_enemy_ids_by_instance.erase(enemy.get_instance_id())
	unregister_combat_target(net_id)
	enemy.remove_for_home_escape()


func _on_enemy_reached_home(enemy: Enemy, _gate_cell: Vector2i) -> void:
	if runtime_mode == RuntimeMode.CLIENT_VIEW:
		return
	if wave_state == WaveState.VICTORY or wave_state == WaveState.DEFEAT:
		return
	if enemy == null or not is_instance_valid(enemy) or enemy.is_dead:
		return
	var enemy_id := enemy.get_instance_id()
	if resolved_home_enemy_ids.has(enemy_id):
		return
	resolved_home_enemy_ids[enemy_id] = true

	var resolves_active_wave := (
		wave_state == WaveState.WAVE_ACTIVE
		and active_wave_enemy_ids.has(enemy_id)
	)
	var resolves_boss_step := (
		wave_state == WaveState.BOSS_ACTIVE
		and enemy == linglan_boss
		and active_wave_enemy_ids.has(enemy_id)
	)
	if resolves_active_wave or resolves_boss_step:
		current_wave_escaped = mini(current_wave_escaped + 1, current_wave_total)
		current_wave_resolved = mini(current_wave_resolved + 1, current_wave_total)
		active_wave_enemy_ids.erase(enemy_id)

	var home_damage := (
		current_base_health
		if resolves_boss_step
		else enemy.config.home_damage if enemy.config != null else 1
	)
	_remove_hud_alive_enemy(enemy_id)
	_emit_multiplayer_enemy_escaped(enemy)
	enemy.remove_for_home_escape()
	_apply_base_damage(maxi(home_damage, 1))

	if resolves_active_wave:
		_show_tower_defense_wave_progress()
		_check_wave_completion()
	elif resolves_boss_step and wave_state != WaveState.DEFEAT:
		call_deferred("_complete_escaped_boss_step")


func _emit_multiplayer_enemy_escaped(enemy: Enemy) -> void:
	if runtime_mode != RuntimeMode.HOST_AUTHORITY or enemy == null:
		return
	var enemy_net_id := int(multiplayer_enemy_ids_by_instance.get(enemy.get_instance_id(), 0))
	if enemy_net_id > 0:
		# Escape is the terminal replication event. Suppress the later generic
		# tree-exit removal so clients never replay a death-style removal path.
		pending_multiplayer_enemy_escape_ids[enemy_net_id] = true
		multiplayer_enemy_escaped.emit(enemy_net_id)


func _apply_base_damage(amount: int) -> void:
	if amount <= 0 or current_base_health <= 0:
		return
	var request := DamageRequest.new(amount, CombatTypes.DamageType.PHYSICAL)
	request.with_flag(CombatTypes.DamageFlag.BYPASS_MITIGATION)
	var result := DamageResolver.resolve(
		request,
		DamageTargetProfile.new(current_base_health)
	)
	if not result.accepted:
		return
	current_base_health = result.health_after
	base_health_revision += 1
	_update_base_health_display()
	if tower_defense_status_hud != null:
		tower_defense_status_hud.play_gate_damage_warning()
	base_health_changed.emit(current_base_health, maximum_base_health, base_health_revision)
	if runtime_mode == RuntimeMode.HOST_AUTHORITY:
		multiplayer_base_health_changed.emit(
			current_base_health,
			maximum_base_health,
			base_health_revision
		)
	if current_base_health <= 0:
		_enter_defeat()


func _update_base_health_display(play_damage_pulse: bool = true) -> void:
	if wave_hud != null:
		wave_hud.set_tower_defense_core_health(
			current_base_health,
			maximum_base_health,
			play_damage_pulse
		)


func _register_hud_alive_enemy(enemy: Enemy) -> void:
	if runtime_mode == RuntimeMode.CLIENT_VIEW:
		return
	if enemy == null or not is_instance_valid(enemy):
		return
	var enemy_id := enemy.get_instance_id()
	if hud_alive_enemy_ids.has(enemy_id):
		return
	hud_alive_enemy_ids[enemy_id] = true
	_update_hud_alive_enemy_count()


func _remove_hud_alive_enemy(enemy_id: int) -> void:
	if runtime_mode == RuntimeMode.CLIENT_VIEW or not hud_alive_enemy_ids.has(enemy_id):
		return
	hud_alive_enemy_ids.erase(enemy_id)
	_update_hud_alive_enemy_count()


func _clear_hud_alive_enemies() -> void:
	if runtime_mode == RuntimeMode.CLIENT_VIEW:
		return
	hud_alive_enemy_ids.clear()
	_update_hud_alive_enemy_count()


func _update_hud_alive_enemy_count() -> void:
	if wave_hud != null:
		wave_hud.set_tower_defense_enemy_count(hud_alive_enemy_ids.size())


func _complete_escaped_boss_step() -> void:
	if wave_state != WaveState.BOSS_ACTIVE:
		return
	if current_wave_resolved < current_wave_total:
		return
	if boss_health_hud != null:
		boss_health_hud.hide_all()
	_complete_current_step()


func _configure_plant_defense_system() -> void:
	if plant_system == null or plant_placement_controller == null or plant_container == null:
		push_error("GameTowerDefense: 植物防御塔节点不完整，已禁用放置功能。")
		return

	var placement_rect := PlantSystem.DEFAULT_PLACEMENT_AREA
	if dual_grid_terrain != null and dual_grid_terrain.world_map_layer != null:
		var authored_terrain_rect := dual_grid_terrain.world_map_layer.get_used_rect()
		if authored_terrain_rect.size.x > 0 and authored_terrain_rect.size.y > 0:
			placement_rect = authored_terrain_rect

	plant_system.setup(
		ground_tile_map_layer,
		player,
		plant_container,
		placement_rect,
		dual_grid_terrain
	)
	orange_charging_aura_coordinator.setup(plant_system)
	_configure_vegetation_spread_system(placement_rect)
	plant_system.clear_reserved_cells()
	for spawn_offset in MULTIPLAYER_SPAWN_OFFSETS:
		plant_system.reserve_world_position(player_spawn.global_position + spawn_offset)
	if home_gate_controller != null:
		for home_cell in home_gate_controller.get_home_gate_cells():
			plant_system.reserve_cell(home_cell)
	for spawn_point in enemy_spawn_points:
		plant_system.reserve_world_position(spawn_point.global_position, 1)
	if merchant != null:
		plant_system.reserve_world_position(merchant.global_position)
	if luoxi_merchant != null:
		plant_system.reserve_world_position(luoxi_merchant.global_position)
	if not plant_system.plant_removed.is_connected(_on_plant_removed):
		plant_system.plant_removed.connect(_on_plant_removed)

	plant_placement_controller.setup(plant_system, player)
	plant_placement_controller.set_multiplayer_request_mode(
		runtime_mode != RuntimeMode.SINGLEPLAYER
	)
	plant_placement_controller.configure_inventory_catalog(
		run_state,
		multiplayer_local_peer_id if runtime_mode != RuntimeMode.SINGLEPLAYER else 0,
		sandbox_free_building_enabled
	)
	if not plant_placement_controller.player_lock_requested.is_connected(
		_on_plant_player_lock_requested
	):
		plant_placement_controller.player_lock_requested.connect(
			_on_plant_player_lock_requested
		)
	if not plant_placement_controller.placement_mode_changed.is_connected(
		_on_plant_placement_mode_changed
	):
		plant_placement_controller.placement_mode_changed.connect(
			_on_plant_placement_mode_changed
		)
	if not plant_placement_controller.multiplayer_placement_requested.is_connected(
		_on_multiplayer_plant_placement_requested
	):
		plant_placement_controller.multiplayer_placement_requested.connect(
			_on_multiplayer_plant_placement_requested
		)
	if not plant_placement_controller.inventory_placement_requested.is_connected(
		_on_inventory_plant_placement_requested
	):
		plant_placement_controller.inventory_placement_requested.connect(
			_on_inventory_plant_placement_requested
		)
	if not plant_system.plant_placed.is_connected(_on_runtime_plant_placed):
		plant_system.plant_placed.connect(_on_runtime_plant_placed)
	_update_plant_placement_input_state()


func _on_plant_player_lock_requested(_locked: bool) -> void:
	_refresh_player_modal_ui_lock()


func _on_plant_placement_mode_changed(active: bool) -> void:
	if active and _has_exclusive_modal_open():
		plant_placement_controller.cancel_placement()
		return
	_refresh_player_modal_ui_lock()


func _on_runtime_plant_placed(plant: PlantDefense) -> void:
	if plant == null:
		return
	_track_progression_plant_placement(plant)
	var hydrangea := plant as HydrangeaRainTower
	if hydrangea != null:
		hydrangea.set_plant_system(plant_system)
	var orange_charging_tower := plant as OrangeChargingTower
	if orange_charging_tower != null:
		orange_charging_tower.set_plant_system(plant_system)
	if plant.config.is_proactive_enemy_target():
		_request_enemy_retarget_after_objective_change()
	if runtime_mode == RuntimeMode.HOST_AUTHORITY:
		var damage_callback := _on_authoritative_plant_damage_applied.bind(plant)
		if not plant.damage_applied.is_connected(damage_callback):
			plant.damage_applied.connect(damage_callback)
		var healing_callback := _on_authoritative_plant_healing_applied.bind(plant)
		if not plant.healing_applied.is_connected(healing_callback):
			plant.healing_applied.connect(healing_callback)
	if plant.is_construction_visual_active():
		_spawn_plant_placement_particles(plant)
	var oak_warehouse := plant as OakWarehouse
	if oak_warehouse != null:
		oak_warehouse.set_shared_storage_panel(oak_warehouse_panel)
	production_coordinator.register_plant(plant)
	var production_building := plant as ProductionBuilding
	if production_building != null:
		production_building.set_recipe_unlock_checker(
			Callable(research_coordinator, "is_global_research_completed")
		)
		production_building.set_shared_production_panel(production_building_panel)
	var research_center := plant as ResearchCenter
	if research_center != null:
		research_center.set_research_services(
			research_coordinator,
			research_center_panel
		)
	if not plant.modal_ui_visibility_changed.is_connected(_on_plant_modal_ui_visibility_changed):
		plant.modal_ui_visibility_changed.connect(_on_plant_modal_ui_visibility_changed)
	var vegetation_stake := plant as VegetationStake
	if vegetation_stake == null or vegetation_spread_system == null:
		return
	if vegetation_stake.is_operational:
		_activate_vegetation_stake_source(vegetation_stake)
		return
	var construction_callback := _on_vegetation_stake_construction_finished.bind(
		vegetation_stake
	)
	if not vegetation_stake.construction_finished.is_connected(construction_callback):
		vegetation_stake.construction_finished.connect(
			construction_callback,
			CONNECT_ONE_SHOT
		)


func _track_progression_plant_placement(plant: PlantDefense) -> void:
	if (
		runtime_mode == RuntimeMode.CLIENT_VIEW
		or plant == null
		or plant.config == null
	):
		return
	var elapsed_seconds := _get_progression_elapsed_seconds()
	if (
		first_defense_tower_seconds < 0.0
		and plant.config.building_category
		== PlantDefenseConfig.BuildingCategory.DEFENSE_TOWER
	):
		first_defense_tower_seconds = elapsed_seconds
	if (
		water_chain_online_seconds < 0.0
		and plant.config.plant_id == PlantDefenseRegistry.WATER_COLLECTOR_ID
	):
		water_chain_online_seconds = elapsed_seconds


func _on_vegetation_stake_construction_finished(vegetation_stake: VegetationStake) -> void:
	if (
		vegetation_stake == null
		or not is_instance_valid(vegetation_stake)
		or not vegetation_stake.is_operational
		or vegetation_stake.is_removing
	):
		return
	_activate_vegetation_stake_source(vegetation_stake)


func _activate_vegetation_stake_source(vegetation_stake: VegetationStake) -> void:
	if (
		vegetation_spread_system == null
		or vegetation_stake == null
		or vegetation_stake.footprint_cells.is_empty()
	):
		return
	var source_id := _get_vegetation_source_id(vegetation_stake)
	var origin_cell := vegetation_stake.footprint_cells[0]
	vegetation_spread_system.register_source(
		source_id,
		origin_cell,
		vegetation_stake.get_spread_elapsed_seconds()
	)
	if not vegetation_stake.spread_runtime_state_changed.is_connected(
		_on_vegetation_runtime_state_changed.bind(source_id, origin_cell)
	):
		vegetation_stake.spread_runtime_state_changed.connect(
			_on_vegetation_runtime_state_changed.bind(source_id, origin_cell)
		)


func _spawn_plant_placement_particles(plant: PlantDefense) -> void:
	if not WORLD_EFFECT_VISIBILITY.is_position_near_viewport(
		self,
		plant.get_lifecycle_vfx_global_position()
	):
		return
	var effect := session_object_pool.try_acquire(
		PLANT_PLACEMENT_PARTICLES_SCENE
	) as PlantPlacementParticles
	if effect == null:
		return
	effect.global_position = plant.get_lifecycle_vfx_global_position()
	effect.reset_physics_interpolation()
	effect.restart_effect(plant, plant.get_lifecycle_particle_scale())


func _spawn_plant_removal_smoke(plant: PlantDefense) -> void:
	if not WORLD_EFFECT_VISIBILITY.is_position_near_viewport(
		self,
		plant.get_lifecycle_vfx_global_position()
	):
		return
	var effect := session_object_pool.try_acquire(
		PLANT_REMOVAL_SMOKE_SCENE
	) as PlantRemovalSmoke
	if effect == null:
		return
	effect.global_position = plant.get_lifecycle_vfx_global_position()
	effect.reset_physics_interpolation()
	effect.restart_effect(plant.get_lifecycle_particle_scale(), plant.is_dead)


func _on_plant_terrain_decay_timer_timeout() -> void:
	if runtime_mode == RuntimeMode.CLIENT_VIEW:
		return
	plant_system.apply_unsupported_terrain_damage_tick()


func _configure_vegetation_spread_system(placement_rect: Rect2i) -> void:
	authored_terrain_baseline.clear()
	multiplayer_terrain_overrides.clear()
	multiplayer_terrain_revision = 0
	if dual_grid_terrain == null or vegetation_spread_system == null:
		push_error("GameTowerDefense: 植被传播节点或地形节点缺失。")
		return
	for y in range(placement_rect.position.y, placement_rect.end.y):
		for x in range(placement_rect.position.x, placement_rect.end.x):
			var cell := Vector2i(x, y)
			authored_terrain_baseline[cell] = dual_grid_terrain.get_terrain_type(cell)
	vegetation_spread_system.setup(
		dual_grid_terrain,
		placement_rect,
		runtime_mode != RuntimeMode.CLIENT_VIEW
	)
	if not vegetation_spread_system.authoritative_terrain_changed.is_connected(
		_on_authoritative_vegetation_terrain_changed
	):
		vegetation_spread_system.authoritative_terrain_changed.connect(
			_on_authoritative_vegetation_terrain_changed
		)


func _on_vegetation_runtime_state_changed(
	elapsed_seconds: float,
	source_id: int,
	origin_cell: Vector2i
) -> void:
	if vegetation_spread_system == null:
		return
	vegetation_spread_system.apply_source_runtime_state(
		source_id,
		origin_cell,
		{
			"schema": VegetationSpreadSystem.RUNTIME_STATE_SCHEMA,
			"spread_elapsed_seconds": elapsed_seconds,
		}
	)


func _get_vegetation_source_id(plant: PlantDefense) -> int:
	var net_id := int(plant.get_meta(&"net_id", 0))
	return net_id if net_id > 0 else int(plant.get_instance_id())


func _on_plant_modal_ui_visibility_changed(is_open: bool) -> void:
	if is_open:
		_cancel_plant_placement()
	_refresh_player_modal_ui_lock()
	_update_plant_placement_input_state()


func _has_exclusive_modal_open() -> bool:
	return (
		settings_panel.is_open()
		or player_profile_panel.is_open()
		or debug_collectible_window.is_open()
		or _has_open_plant_modal_ui()
	)


func _has_open_plant_modal_ui() -> bool:
	for node in get_tree().get_nodes_in_group(&"plant_defense"):
		var plant := node as PlantDefense
		if plant != null and plant.is_modal_ui_open():
			return true
	return false


func _update_plant_placement_input_state() -> void:
	if plant_placement_controller == null:
		return
	var input_enabled := (
		player != null
		and not player.is_dead
		and wave_state not in [
			WaveState.VICTORY,
			WaveState.DEFEAT,
			WaveState.FATE_INTERLUDE,
		]
		and not _has_exclusive_modal_open()
	)
	plant_placement_controller.set_placement_input_enabled(input_enabled)
	plant_placement_controller.set_process_unhandled_input(input_enabled)


func _cancel_plant_placement() -> void:
	if plant_placement_controller != null and plant_placement_controller.is_active():
		plant_placement_controller.cancel_placement()


func begin_inventory_building_placement(
	slot_index: int,
	expected_inventory_revision: int = -1
) -> bool:
	if (
		plant_placement_controller == null
		or plant_system == null
		or player == null
		or player.is_dead
		or wave_state == WaveState.FATE_INTERLUDE
		or _has_exclusive_modal_open()
	):
		return false
	var inventory_peer_id := (
		multiplayer_local_peer_id
		if runtime_mode != RuntimeMode.SINGLEPLAYER
		else 0
	)
	var item := (
		run_state.get_item_for_peer(inventory_peer_id, slot_index)
		if inventory_peer_id > 0
		else run_state.get_item(slot_index)
	)
	var current_revision := (
		run_state.get_inventory_revision_for_peer(inventory_peer_id)
		if inventory_peer_id > 0
		else run_state.get_inventory_revision()
	)
	if (
		item == null
		or item.pickup_type != PickupConfig.PickupType.BUILDING
		or item.placeable_plant_id == &""
		or item.resource_path.is_empty()
		or (
			expected_inventory_revision >= 0
			and expected_inventory_revision != current_revision
		)
	):
		return false
	var config := plant_system.get_config(item.placeable_plant_id)
	if (
		config == null
		or not config.is_valid()
		or (
			runtime_mode != RuntimeMode.SINGLEPLAYER
			and not config.supports_multiplayer
		)
	):
		return false
	var started := plant_placement_controller.begin_inventory_placement(
		config,
		slot_index,
		current_revision,
		item.resource_path
	)
	if started:
		_refresh_player_modal_ui_lock()
		_update_plant_placement_input_state()
	return started


func _on_inventory_plant_placement_requested(
	request_id: int,
	plant_id: StringName,
	anchor: Vector2i,
	slot_index: int,
	expected_inventory_revision: int,
	item_config_path: String
) -> void:
	if runtime_mode == RuntimeMode.SINGLEPLAYER:
		_request_singleplayer_inventory_plant_placement(
			request_id,
			plant_id,
			anchor,
			slot_index,
			expected_inventory_revision,
			item_config_path
		)
		return
	multiplayer_inventory_plant_placement_requested.emit(
		request_id,
		plant_id,
		anchor,
		slot_index,
		expected_inventory_revision,
		item_config_path
	)


func _request_singleplayer_inventory_plant_placement(
	request_id: int,
	plant_id: StringName,
	anchor: Vector2i,
	slot_index: int,
	expected_inventory_revision: int,
	item_config_path: String
) -> void:
	if wave_state == WaveState.FATE_INTERLUDE:
		plant_placement_controller.notify_multiplayer_placement_rejected(
			request_id
		)
		return
	var stored_item := run_state.get_item(slot_index)
	var config := plant_system.get_config(plant_id) if plant_system != null else null
	if (
		request_id <= 0
		or stored_item == null
		or stored_item.resource_path != item_config_path
		or stored_item.pickup_type != PickupConfig.PickupType.BUILDING
		or stored_item.placeable_plant_id != plant_id
		or config == null
		or not config.is_valid()
		or not plant_system.is_placement_valid_for_player(
			anchor,
			config,
			player
		)
	):
		plant_placement_controller.notify_multiplayer_placement_rejected(
			request_id
		)
		return
	if not run_state.try_consume_item_at_slot_if_revision(
		slot_index,
		stored_item,
		expected_inventory_revision,
		false
	):
		plant_placement_controller.notify_multiplayer_placement_rejected(
			request_id
		)
		return
	var placed_plant := plant_system.try_place_for_player(
		config,
		anchor,
		player
	)
	if placed_plant == null:
		var restored := run_state.try_add_item_count_to_slot_if_revision(
			stored_item,
			1,
			slot_index,
			run_state.get_inventory_revision(),
			false
		)
		if not restored:
			push_error("Failed to restore a consumed building item after placement.")
		run_state.notify_inventory_transaction_completed()
		plant_placement_controller.notify_multiplayer_placement_rejected(
			request_id
		)
		return
	run_state.notify_inventory_transaction_completed()


func _on_personal_inventory_output_committed(peer_id: int) -> void:
	if runtime_mode == RuntimeMode.HOST_AUTHORITY and peer_id > 0:
		multiplayer_inventory_changed.emit(peer_id)


func _on_multiplayer_plant_placement_requested(
	request_id: int,
	plant_id: StringName,
	anchor: Vector2i
) -> void:
	if runtime_mode == RuntimeMode.SINGLEPLAYER:
		return
	multiplayer_plant_placement_requested.emit(request_id, plant_id, anchor)


func request_multiplayer_plant_placement(
	requester_peer_id: int,
	request_id: int,
	plant_id: StringName,
	anchor: Vector2i
) -> void:
	if runtime_mode != RuntimeMode.HOST_AUTHORITY:
		return
	if wave_state == WaveState.FATE_INTERLUDE:
		_reject_multiplayer_plant_placement(
			request_id,
			requester_peer_id,
			PLANT_PLACEMENT_REJECT_FLOW_LOCKED
		)
		return
	if not sandbox_free_building_enabled:
		_reject_multiplayer_plant_placement(
			request_id,
			requester_peer_id,
			PLANT_PLACEMENT_REJECT_FREE_DISABLED
		)
		return
	if request_id <= 0 or requester_peer_id <= 0:
		_reject_multiplayer_plant_placement(
			request_id,
			requester_peer_id,
			PLANT_PLACEMENT_REJECT_INVALID_REQUEST
		)
		return
	var placement_player := get_player_for_peer(requester_peer_id)
	if placement_player == null or not is_instance_valid(placement_player) or placement_player.is_dead:
		_reject_multiplayer_plant_placement(
			request_id,
			requester_peer_id,
			PLANT_PLACEMENT_REJECT_INVALID_PLAYER
		)
		return
	var plant_config := plant_system.get_config(plant_id) if plant_system != null else null
	if (
		plant_config == null
		or not plant_config.is_valid()
		or not plant_config.supports_multiplayer
	):
		_reject_multiplayer_plant_placement(
			request_id,
			requester_peer_id,
			PLANT_PLACEMENT_REJECT_INVALID_CONFIG
		)
		return
	_spawn_authoritative_multiplayer_plant(
		requester_peer_id,
		request_id,
		plant_config,
		anchor,
		placement_player
	)


func request_multiplayer_inventory_plant_placement(
	requester_peer_id: int,
	request_id: int,
	plant_id: StringName,
	anchor: Vector2i,
	slot_index: int,
	expected_inventory_revision: int,
	item_config_path: String
) -> void:
	if runtime_mode != RuntimeMode.HOST_AUTHORITY:
		return
	if wave_state == WaveState.FATE_INTERLUDE:
		_reject_multiplayer_plant_placement(
			request_id,
			requester_peer_id,
			PLANT_PLACEMENT_REJECT_FLOW_LOCKED
		)
		return
	if (
		request_id <= 0
		or requester_peer_id <= 0
		or slot_index < 0
		or expected_inventory_revision < 0
		or item_config_path.is_empty()
	):
		_reject_multiplayer_plant_placement(
			request_id,
			requester_peer_id,
			PLANT_PLACEMENT_REJECT_INVALID_REQUEST
		)
		return
	var placement_player := get_player_for_peer(requester_peer_id)
	if (
		placement_player == null
		or not is_instance_valid(placement_player)
		or placement_player.is_dead
	):
		_reject_multiplayer_plant_placement(
			request_id,
			requester_peer_id,
			PLANT_PLACEMENT_REJECT_INVALID_PLAYER
		)
		return
	if (
		run_state.get_inventory_revision_for_peer(requester_peer_id)
		!= expected_inventory_revision
	):
		_reject_multiplayer_plant_placement(
			request_id,
			requester_peer_id,
			PLANT_PLACEMENT_REJECT_STALE_INVENTORY
		)
		return
	var stored_item := run_state.get_item_for_peer(
		requester_peer_id,
		slot_index
	)
	if (
		stored_item == null
		or stored_item.resource_path != item_config_path
		or stored_item.pickup_type != PickupConfig.PickupType.BUILDING
		or stored_item.placeable_plant_id != plant_id
	):
		_reject_multiplayer_plant_placement(
			request_id,
			requester_peer_id,
			PLANT_PLACEMENT_REJECT_INVALID_INVENTORY_ITEM
		)
		return
	var plant_config := plant_system.get_config(plant_id) if plant_system != null else null
	if (
		plant_config == null
		or not plant_config.is_valid()
		or not plant_config.supports_multiplayer
	):
		_reject_multiplayer_plant_placement(
			request_id,
			requester_peer_id,
			PLANT_PLACEMENT_REJECT_INVALID_CONFIG
		)
		return
	if not plant_system.is_placement_valid_for_player(
		anchor,
		plant_config,
		placement_player
	):
		_reject_multiplayer_plant_placement(
			request_id,
			requester_peer_id,
			PLANT_PLACEMENT_REJECT_INVALID_POSITION
		)
		return
	if not run_state.try_consume_item_at_slot_for_peer_if_revision(
		requester_peer_id,
		slot_index,
		stored_item,
		expected_inventory_revision,
		false
	):
		_reject_multiplayer_plant_placement(
			request_id,
			requester_peer_id,
			PLANT_PLACEMENT_REJECT_STALE_INVENTORY
		)
		return
	var placed_plant := _spawn_authoritative_multiplayer_plant(
		requester_peer_id,
		request_id,
		plant_config,
		anchor,
		placement_player
	)
	if placed_plant == null:
		var restored := run_state.try_add_item_count_to_slot_for_peer_if_revision(
			requester_peer_id,
			stored_item,
			1,
			slot_index,
			run_state.get_inventory_revision_for_peer(requester_peer_id),
			false
		)
		if not restored:
			push_error(
				"Failed to restore a peer building item after placement."
			)
		run_state.notify_inventory_transaction_completed()
		multiplayer_inventory_changed.emit(requester_peer_id)
		return
	run_state.notify_inventory_transaction_completed()
	multiplayer_inventory_changed.emit(requester_peer_id)


func _spawn_authoritative_multiplayer_plant(
	requester_peer_id: int,
	request_id: int,
	plant_config: PlantDefenseConfig,
	anchor: Vector2i,
	placement_player: Player
) -> PlantDefense:
	var plant_net_id := next_multiplayer_plant_net_id
	var plant := plant_system.try_place_for_player(
		plant_config,
		anchor,
		placement_player,
		plant_net_id
	)
	if plant == null:
		_reject_multiplayer_plant_placement(
			request_id,
			requester_peer_id,
			PLANT_PLACEMENT_REJECT_INVALID_POSITION
		)
		return null
	next_multiplayer_plant_net_id += 1
	if not plant.authoritative_health_changed.is_connected(
		_on_authoritative_plant_health_changed.bind(plant_net_id)
	):
		plant.authoritative_health_changed.connect(
			_on_authoritative_plant_health_changed.bind(plant_net_id)
		)
	if not plant.authoritative_damage_status_changed.is_connected(
		_on_authoritative_plant_damage_status_changed.bind(plant_net_id)
	):
		plant.authoritative_damage_status_changed.connect(
			_on_authoritative_plant_damage_status_changed.bind(plant_net_id)
		)
	multiplayer_plant_spawned.emit(
		request_id,
		requester_peer_id,
		plant_net_id,
		plant_config.plant_id,
		anchor,
		plant.current_health,
		plant.max_health,
		plant.health_revision
	)
	return plant


func _reject_multiplayer_plant_placement(
	request_id: int,
	requester_peer_id: int,
	reason: StringName
) -> void:
	multiplayer_plant_placement_rejected.emit(request_id, requester_peer_id, reason)


func _on_authoritative_plant_health_changed(
	current_health: int,
	maximum_health: int,
	health_revision: int,
	net_id: int
) -> void:
	if runtime_mode != RuntimeMode.HOST_AUTHORITY or net_id <= 0:
		return
	if plant_system == null or plant_system.get_plant_by_net_id(net_id) == null:
		return
	multiplayer_plant_health_changed.emit(
		net_id,
		current_health,
		maximum_health,
		health_revision
	)


func _on_authoritative_plant_damage_status_changed(
	status_mask: int,
	status_revision: int,
	net_id: int
) -> void:
	if runtime_mode != RuntimeMode.HOST_AUTHORITY or net_id <= 0:
		return
	if plant_system == null or plant_system.get_plant_by_net_id(net_id) == null:
		return
	multiplayer_plant_damage_status_changed.emit(
		net_id,
		status_mask,
		status_revision
	)


func _on_authoritative_plant_damage_applied(
	applied_damage: int,
	impact_direction: Vector2,
	damage_type: EnemyConfig.DamageType,
	plant: PlantDefense
) -> void:
	if (
		runtime_mode != RuntimeMode.HOST_AUTHORITY
		or applied_damage <= 0
		or plant == null
		or not is_instance_valid(plant)
	):
		return
	var net_id := int(plant.get_meta(&"net_id", 0))
	if net_id <= 0:
		return
	multiplayer_plant_damage_applied.emit(
		net_id,
		applied_damage,
		impact_direction,
		damage_type,
		plant.get_lifecycle_vfx_global_position()
	)


func _on_authoritative_plant_healing_applied(
	applied_healing: int,
	plant: PlantDefense
) -> void:
	if (
		runtime_mode != RuntimeMode.HOST_AUTHORITY
		or applied_healing <= 0
		or plant == null
		or not is_instance_valid(plant)
	):
		return
	var net_id := int(plant.get_meta(&"net_id", 0))
	if net_id <= 0:
		return
	multiplayer_plant_healing_applied.emit(
		net_id,
		applied_healing,
		plant.get_lifecycle_vfx_global_position()
	)


func _on_plant_removed(plant: PlantDefense) -> void:
	if plant == null:
		return
	production_coordinator.unregister_plant(plant)
	if plant.config.is_proactive_enemy_target():
		_clear_enemy_references_to_removed_plant(plant)
		_request_enemy_retarget_after_objective_change()
	if plant.removal_mode == PlantDefense.RemovalMode.ANIMATED:
		_spawn_plant_removal_smoke(plant)
	var oak_warehouse := plant as OakWarehouse
	if oak_warehouse != null:
		oak_warehouse.close_storage_panel()
	var production_building := plant as ProductionBuilding
	if production_building != null:
		production_building.close_production_panel()
	var net_id := int(plant.get_meta(&"net_id", 0))
	if runtime_mode == RuntimeMode.HOST_AUTHORITY and net_id > 0:
		multiplayer_plant_removed.emit(net_id, plant.is_dead)
	if plant is VegetationStake and vegetation_spread_system != null:
		vegetation_spread_system.cancel_source(_get_vegetation_source_id(plant))


func _clear_enemy_references_to_removed_plant(plant: PlantDefense) -> void:
	# Removal is rare, so one bounded pass is preferable to letting enemies keep
	# a direct reference to the visual-only dissolve remnant until a budgeted
	# retarget sweep reaches them.
	var objective_containers: Array[Node] = [enemy_container, boss_container]
	for container in objective_containers:
		if container == null:
			continue
		for child in container.get_children():
			var enemy := child as Enemy
			if enemy != null and enemy.objective_target == plant:
				enemy.set_objective_target(null)


func apply_remote_plant_spawn(
	request_id: int,
	owner_peer_id: int,
	net_id: int,
	plant_id: StringName,
	anchor: Vector2i,
	current_health: int,
	maximum_health: int,
	health_revision: int
) -> void:
	if runtime_mode != RuntimeMode.CLIENT_VIEW or plant_system == null:
		return
	var owner := get_player_for_peer(owner_peer_id)
	var replica := plant_system.spawn_multiplayer_replica(
		plant_id,
		anchor,
		owner,
		net_id,
		current_health,
		maximum_health,
		health_revision,
		request_id > 0
	)
	if replica != null:
		replica.apply_remote_health(current_health, maximum_health, health_revision)


func apply_remote_plant_health(
	net_id: int,
	current_health: int,
	maximum_health: int,
	health_revision: int
) -> void:
	if runtime_mode != RuntimeMode.CLIENT_VIEW or plant_system == null:
		return
	var plant := plant_system.get_plant_by_net_id(net_id)
	if plant != null and is_instance_valid(plant):
		plant.apply_remote_health(current_health, maximum_health, health_revision)


func apply_remote_plant_removed(net_id: int) -> void:
	apply_remote_plant_removed_with_reason(net_id, false)


func apply_remote_plant_removed_with_reason(
	net_id: int,
	was_destroyed: bool
) -> void:
	if runtime_mode != RuntimeMode.CLIENT_VIEW or plant_system == null:
		return
	var plant := plant_system.get_plant_by_net_id(net_id)
	if plant != null and is_instance_valid(plant) and was_destroyed:
		plant.current_health = 0
		plant.is_dead = true
	plant_system.remove_plant_by_net_id(net_id, PlantDefense.RemovalMode.ANIMATED)


func apply_remote_plant_removed_silently(net_id: int) -> void:
	if runtime_mode != RuntimeMode.CLIENT_VIEW or plant_system == null:
		return
	plant_system.remove_plant_by_net_id(net_id, PlantDefense.RemovalMode.SILENT)


func apply_remote_plant_placement_rejected(request_id: int, _reason: StringName) -> void:
	if runtime_mode == RuntimeMode.SINGLEPLAYER or plant_placement_controller == null:
		return
	plant_placement_controller.notify_multiplayer_placement_rejected(request_id)


func has_multiplayer_plant(net_id: int) -> bool:
	if plant_system == null or net_id <= 0:
		return false
	var plant := plant_system.get_plant_by_net_id(net_id)
	return (
		plant != null
		and is_instance_valid(plant)
		and not plant.is_dead
		and not plant.is_removing
	)


func get_multiplayer_plant_node(net_id: int) -> PlantDefense:
	if plant_system == null or net_id <= 0:
		return null
	return plant_system.get_plant_by_net_id(net_id)


func get_multiplayer_plant_snapshots() -> Array[Dictionary]:
	var snapshots: Array[Dictionary] = []
	if plant_system == null:
		return snapshots
	var net_ids: Array[int] = []
	for net_id_variant in plant_system.plants_by_net_id:
		net_ids.append(int(net_id_variant))
	net_ids.sort()
	for net_id in net_ids:
		var plant := plant_system.get_plant_by_net_id(net_id)
		if (
			plant == null
			or not is_instance_valid(plant)
			or plant.is_dead
			or plant.is_removing
			or plant.config == null
			or plant.footprint_cells.is_empty()
		):
			continue
		var owner_peer_id := (
			plant.owner_player.peer_id
			if plant.owner_player != null and is_instance_valid(plant.owner_player)
			else 0
		)
		snapshots.append({
			"owner_peer_id": owner_peer_id,
			"net_id": net_id,
			"plant_id": plant.config.plant_id,
			"anchor": plant.footprint_cells[0],
			"current_health": plant.current_health,
			"maximum_health": plant.max_health,
			"health_revision": plant.health_revision,
		})
	return snapshots


func get_multiplayer_terrain_snapshot() -> Dictionary:
	var cells: Array[Vector2i] = []
	for cell_variant in multiplayer_terrain_overrides:
		cells.append(cell_variant as Vector2i)
	cells.sort_custom(_sort_terrain_cells)
	var cell_xy := PackedInt32Array()
	var terrain_types := PackedInt32Array()
	for cell in cells:
		cell_xy.append(cell.x)
		cell_xy.append(cell.y)
		terrain_types.append(int(multiplayer_terrain_overrides[cell]))
	return {
		"revision": multiplayer_terrain_revision,
		"cell_xy": cell_xy,
		"terrain_types": terrain_types,
	}


func apply_remote_terrain_snapshot(
	revision: int,
	cell_xy: PackedInt32Array,
	terrain_types: PackedInt32Array
) -> bool:
	if runtime_mode != RuntimeMode.CLIENT_VIEW or revision < 0:
		return false
	if terrain_types.is_empty():
		if not cell_xy.is_empty() or dual_grid_terrain == null:
			return false
	else:
		if not _is_valid_terrain_payload(cell_xy, terrain_types):
			return false
	var next_overrides: Dictionary = {}
	for index in range(terrain_types.size()):
		var cell := Vector2i(cell_xy[index * 2], cell_xy[index * 2 + 1])
		var terrain_type := terrain_types[index]
		if terrain_type == int(authored_terrain_baseline[cell]):
			return false
		next_overrides[cell] = terrain_type
	for cell_variant in multiplayer_terrain_overrides:
		var previous_cell := cell_variant as Vector2i
		if not next_overrides.has(previous_cell):
			dual_grid_terrain.set_tile(
				previous_cell,
				int(authored_terrain_baseline[previous_cell])
			)
	for cell_variant in next_overrides:
		var cell := cell_variant as Vector2i
		dual_grid_terrain.set_tile(cell, int(next_overrides[cell]))
	multiplayer_terrain_overrides = next_overrides
	multiplayer_terrain_revision = revision
	_refresh_remote_vegetation_overlay()
	return true


func apply_remote_terrain_delta(
	revision: int,
	cell_xy: PackedInt32Array,
	terrain_types: PackedInt32Array
) -> bool:
	if (
		runtime_mode != RuntimeMode.CLIENT_VIEW
		or revision != multiplayer_terrain_revision + 1
		or not _is_valid_terrain_payload(cell_xy, terrain_types)
	):
		return false
	for index in range(terrain_types.size()):
		var cell := Vector2i(cell_xy[index * 2], cell_xy[index * 2 + 1])
		var terrain_type := terrain_types[index]
		dual_grid_terrain.set_tile(cell, terrain_type)
		if terrain_type == int(authored_terrain_baseline[cell]):
			multiplayer_terrain_overrides.erase(cell)
		else:
			multiplayer_terrain_overrides[cell] = terrain_type
	multiplayer_terrain_revision = revision
	_refresh_remote_vegetation_overlay()
	return true


func _on_authoritative_vegetation_terrain_changed(
	cell_xy: PackedInt32Array,
	terrain_types: PackedInt32Array
) -> void:
	if not _is_valid_terrain_payload(cell_xy, terrain_types):
		push_error("GameTowerDefense: 植被传播提交了非法地形批次。")
		return
	for index in range(terrain_types.size()):
		var cell := Vector2i(cell_xy[index * 2], cell_xy[index * 2 + 1])
		var terrain_type := terrain_types[index]
		if terrain_type == int(authored_terrain_baseline[cell]):
			multiplayer_terrain_overrides.erase(cell)
		else:
			multiplayer_terrain_overrides[cell] = terrain_type
	if runtime_mode != RuntimeMode.HOST_AUTHORITY:
		return
	var cell_count := terrain_types.size()
	for start_index in range(0, cell_count, TERRAIN_NETWORK_BATCH_MAX_CELLS):
		var end_index := mini(start_index + TERRAIN_NETWORK_BATCH_MAX_CELLS, cell_count)
		var chunk_cell_xy := PackedInt32Array()
		var chunk_terrain_types := PackedInt32Array()
		for index in range(start_index, end_index):
			chunk_cell_xy.append(cell_xy[index * 2])
			chunk_cell_xy.append(cell_xy[index * 2 + 1])
			chunk_terrain_types.append(terrain_types[index])
		multiplayer_terrain_revision += 1
		multiplayer_terrain_delta.emit(
			multiplayer_terrain_revision,
			chunk_cell_xy,
			chunk_terrain_types
		)


func _is_valid_terrain_payload(
	cell_xy: PackedInt32Array,
	terrain_types: PackedInt32Array
) -> bool:
	if (
		terrain_types.is_empty()
		or cell_xy.size() != terrain_types.size() * 2
		or dual_grid_terrain == null
	):
		return false
	var previous_cell := Vector2i.ZERO
	var has_previous := false
	for index in range(terrain_types.size()):
		var cell := Vector2i(cell_xy[index * 2], cell_xy[index * 2 + 1])
		var terrain_type := terrain_types[index]
		if not authored_terrain_baseline.has(cell):
			return false
		if terrain_type not in [
			DualGridTilemap.TerrainType.EMPTY,
			DualGridTilemap.TerrainType.GRASS,
			DualGridTilemap.TerrainType.DIRT,
			DualGridTilemap.TerrainType.WATER,
			DualGridTilemap.TerrainType.METAL,
		]:
			return false
		if has_previous and not _sort_terrain_cells(previous_cell, cell):
			return false
		previous_cell = cell
		has_previous = true
	return true


func _refresh_remote_vegetation_overlay() -> void:
	if vegetation_spread_system != null:
		vegetation_spread_system.advance_time(0.0)


static func _sort_terrain_cells(a: Vector2i, b: Vector2i) -> bool:
	if a.y == b.y:
		return a.x < b.x
	return a.y < b.y


func _get_selected_singleplayer_character_id() -> StringName:
	var character_id := DEFAULT_PLAYER_CHARACTER_ID
	if run_state != null:
		if run_state.has_method("get_selected_character_id"):
			character_id = StringName(run_state.call("get_selected_character_id"))
		else:
			character_id = StringName(run_state.get("selected_character_id"))
	if not PlayerCharacterRegistry.is_valid_character_id(character_id):
		return DEFAULT_PLAYER_CHARACTER_ID
	return character_id


func _instantiate_player_character(character_id: StringName) -> Player:
	var resolved_id := character_id
	if not PlayerCharacterRegistry.is_valid_character_id(resolved_id):
		resolved_id = DEFAULT_PLAYER_CHARACTER_ID
	var instance := PlayerCharacterRegistry.instantiate_character(resolved_id) as Player
	if instance == null:
		push_error("Game: 无法实例化角色 %s" % resolved_id)
	return instance


func _apply_initial_player_xirang() -> void:
	var players: Array[Player] = []
	if runtime_mode == RuntimeMode.SINGLEPLAYER:
		if player != null:
			players.append(player)
	else:
		for peer_id_variant in peer_players:
			var player_instance := peer_players[peer_id_variant] as Player
			if player_instance != null and is_instance_valid(player_instance):
				players.append(player_instance)
	for player_instance in players:
		if player_instance.current_xirang == INITIAL_PLAYER_XIRANG:
			continue
		player_instance.current_xirang = INITIAL_PLAYER_XIRANG
		player_instance.xirang_changed.emit(player_instance.current_xirang, 0)


func _grant_tower_defense_starting_package() -> bool:
	if starting_package_granted:
		return true
	if run_state == null or progression_config == null:
		return false
	if runtime_mode == RuntimeMode.CLIENT_VIEW:
		return false
	if runtime_mode == RuntimeMode.SINGLEPLAYER:
		var items := progression_config.get_starting_items(true)
		var amounts := progression_config.get_starting_amounts(true)
		if not run_state.can_add_item_counts(items, amounts):
			return false
		if not run_state.try_add_item_counts_if_revision(
			items,
			amounts,
			run_state.get_inventory_revision()
		):
			return false
		starting_package_granted = true
		return true

	var peer_ids: Array[int] = []
	for peer_id_variant in peer_players:
		peer_ids.append(int(peer_id_variant))
	peer_ids.sort()
	if (
		peer_ids.is_empty()
		or multiplayer_local_peer_id <= 0
		or not peer_players.has(multiplayer_local_peer_id)
	):
		return false
	for peer_id in peer_ids:
		run_state.ensure_multiplayer_peer_state(peer_id)
		var include_team_items := peer_id == multiplayer_local_peer_id
		if not run_state.can_add_item_counts_for_peer(
			peer_id,
			progression_config.get_starting_items(include_team_items),
			progression_config.get_starting_amounts(include_team_items)
		):
			return false
	for peer_id in peer_ids:
		var include_team_items := peer_id == multiplayer_local_peer_id
		if not run_state.try_add_item_counts_for_peer_if_revision(
			peer_id,
			progression_config.get_starting_items(include_team_items),
			progression_config.get_starting_amounts(include_team_items),
			run_state.get_inventory_revision_for_peer(peer_id),
			false
		):
			return false
	starting_package_granted = true
	run_state.notify_inventory_snapshot_committed()
	return true


func _start_progression_metrics() -> void:
	if progression_started_msec <= 0:
		progression_started_msec = Time.get_ticks_msec()


func _get_progression_elapsed_seconds() -> float:
	if progression_started_msec <= 0:
		return 0.0
	return maxf(
		float(Time.get_ticks_msec() - progression_started_msec) / 1000.0,
		0.0
	)


func _register_research_players() -> void:
	if research_coordinator == null:
		return
	if runtime_mode == RuntimeMode.SINGLEPLAYER:
		research_coordinator.register_player(player)
		return
	for player_variant in peer_players.values():
		var player_instance := player_variant as Player
		if player_instance != null:
			research_coordinator.register_player(player_instance)


func _on_research_recipe_unlocks_changed() -> void:
	for plant_variant in get_tree().get_nodes_in_group(&"plant_defense"):
		var production_building := plant_variant as ProductionBuilding
		if production_building != null:
			production_building.notify_recipe_unlocks_changed()


func _on_currency_hud_settings_requested() -> void:
	_cancel_plant_placement()
	if player_profile_panel.is_open():
		player_profile_panel.close()
	settings_panel.open()
	_lock_player_for_modal_ui()
	_update_plant_placement_input_state()


func _on_currency_hud_profile_requested() -> void:
	_cancel_plant_placement()
	if settings_panel.is_open():
		settings_panel.close()
	player_profile_panel.open()
	_update_plant_placement_input_state()


func _on_exclusive_modal_opened() -> void:
	_cancel_plant_placement()
	_update_plant_placement_input_state()


func _on_settings_panel_closed() -> void:
	_refresh_player_modal_ui_lock()
	_update_plant_placement_input_state()


func _on_player_profile_panel_closed() -> void:
	_refresh_player_modal_ui_lock()
	_update_plant_placement_input_state()


func _on_debug_collectible_window_closed() -> void:
	_refresh_player_modal_ui_lock()
	_update_plant_placement_input_state()


func _lock_player_for_modal_ui() -> void:
	if player != null and not player.is_dead:
		player.set_controls_locked(true)


func _refresh_player_modal_ui_lock() -> void:
	if player == null or player.is_dead:
		return
	if (
		_has_exclusive_modal_open()
		or (
			plant_placement_controller != null
			and plant_placement_controller.is_active()
		)
	):
		player.set_controls_locked(true)
	else:
		player.set_controls_locked(false)


func _toggle_full_screen() -> void:
	var user_settings := get_node_or_null("/root/UserSettings")
	if user_settings != null and user_settings.has_method("set_fullscreen_enabled"):
		var next_fullscreen := not bool(user_settings.call("is_fullscreen_enabled"))
		user_settings.call("set_fullscreen_enabled", next_fullscreen)
		if settings_panel != null and settings_panel.has_method("refresh_from_settings"):
			settings_panel.call("refresh_from_settings")
		return

	var current_mode := DisplayServer.window_get_mode()
	var is_fullscreen := (
		current_mode == DisplayServer.WINDOW_MODE_FULLSCREEN
		or current_mode == DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN
	)
	DisplayServer.window_set_mode(
		DisplayServer.WINDOW_MODE_WINDOWED if is_fullscreen else DisplayServer.WINDOW_MODE_FULLSCREEN
	)


func _toggle_debug_collectible_window() -> void:
	if debug_collectible_window == null or not sandbox_free_building_enabled:
		return
	if not debug_collectible_window.is_open():
		_cancel_plant_placement()
	debug_collectible_window.toggle()
	if debug_collectible_window.is_open():
		_lock_player_for_modal_ui()
	else:
		_refresh_player_modal_ui_lock()
	_update_plant_placement_input_state()


func _on_debug_collectible_requested(config_path: String) -> void:
	if config_path.is_empty() or not sandbox_free_building_enabled:
		return
	var current_scene := get_tree().current_scene
	if (
		runtime_mode != RuntimeMode.SINGLEPLAYER
		and current_scene != null
		and current_scene.has_method("request_debug_collectible")
	):
		current_scene.call("request_debug_collectible", config_path)
		return
	debug_collectible_window.show_grant_result(config_path, grant_debug_collectible(config_path))


func grant_debug_collectible(config_path: String) -> bool:
	if not sandbox_free_building_enabled:
		return false
	var item := LuoxiMerchant.get_collectible_for_path(config_path)
	if item == null:
		return false
	if runtime_mode != RuntimeMode.SINGLEPLAYER and multiplayer_local_peer_id > 0:
		return run_state.try_add_item_for_peer(multiplayer_local_peer_id, item)
	return run_state.try_add_item(item)


func show_debug_collectible_grant_result(config_path: String, success: bool) -> void:
	if debug_collectible_window == null:
		return
	debug_collectible_window.show_grant_result(config_path, success)


func allows_debug_collectible_grants() -> bool:
	return sandbox_free_building_enabled


func show_simple_crafting_result(
	recipe_id: StringName,
	result: StringName,
	request_token: int
) -> void:
	if player_profile_panel == null:
		return
	player_profile_panel.show_simple_crafting_result(
		recipe_id,
		result,
		request_token
	)


func apply_remote_merchant_active(active: bool) -> void:
	_set_local_merchants_active(active)


func apply_remote_flow_state(step_id: StringName, state: int, seconds: int) -> void:
	if runtime_mode != RuntimeMode.CLIENT_VIEW:
		return
	var typed_state := state as WaveState
	var flow_step := _get_flow_step_by_id(step_id)
	if flow_step == null and typed_state not in [WaveState.VICTORY, WaveState.DEFEAT]:
		push_error(
			"GameTowerDefense: 收到当前 Campaign 不存在的流程 step_id：%s"
			% String(step_id)
		)
		return
	if (
		wave_state == WaveState.FATE_INTERLUDE
		and typed_state != WaveState.FATE_INTERLUDE
		and xiaocong_fate_interlude.is_active
		and not remote_fate_departure_covered
	):
		pending_remote_fate_flow_state = {
			"step_id": step_id,
			"state": state,
			"seconds": seconds,
		}
		_begin_remote_fate_departure()
		return
	var leaving_fate_interlude := (
		wave_state == WaveState.FATE_INTERLUDE
		and typed_state != WaveState.FATE_INTERLUDE
		and xiaocong_fate_interlude.is_active
	)
	if flow_step != null:
		current_flow_step = flow_step
		if flow_step is WaveConfig:
			current_wave_index = _get_wave_number_for_step(flow_step as WaveConfig) - 1
	_set_fate_interlude_systems_frozen(typed_state == WaveState.FATE_INTERLUDE)
	match typed_state:
		WaveState.PRE_WAVE:
			transition_world_to_day()
			_start_client_flow_countdown(typed_state, step_id, seconds)
		WaveState.INTERMISSION:
			_apply_intermission_lighting(maxi(current_wave_index + 1, 1))
			_start_client_flow_countdown(typed_state, step_id, seconds)
		WaveState.WAVE_ACTIVE:
			state_timer.stop()
			wave_state = WaveState.WAVE_ACTIVE
			_apply_wave_start_lighting(maxi(current_wave_index + 1, 1))
			_set_local_merchants_active(false)
			var wave_config := flow_step as WaveConfig
			if wave_config != null:
				_update_wave_music(wave_config)
			_show_tower_defense_wave_progress()
			wave_start_audio.play()
		WaveState.BOSS_INTRO:
			state_timer.stop()
			wave_state = WaveState.BOSS_INTRO
			_set_local_merchants_active(false)
			wave_hud.show_tower_defense_boss_progress(0, 1)
			var boss_config := flow_step as BossConfig
			if boss_config != null:
				active_boss_config = boss_config
				_update_boss_music(boss_config)
				_prepare_linglan_boss_arena(boss_config)
				_play_remote_boss_intro(boss_config)
		WaveState.BOSS_ACTIVE:
			state_timer.stop()
			wave_state = WaveState.BOSS_ACTIVE
			_set_local_merchants_active(false)
			wave_hud.show_tower_defense_boss_progress(0, 1)
			_restore_remote_camera_if_boss_intro_complete()
			var active_config := flow_step as BossConfig
			if active_config != null:
				active_boss_config = active_config
				_update_boss_music(active_config)
		WaveState.FATE_INTERLUDE:
			state_timer.stop()
			enemy_spawn_timer.stop()
			wave_state = WaveState.FATE_INTERLUDE
			_set_fate_player_combat_locked(true)
			if not remote_fate_entry_in_progress:
				if xiaocong_fate_interlude.is_active:
					_present_fate_interlude_locally(
						_get_day_number_for_wave(maxi(current_wave_index + 1, 1))
					)
				else:
					_begin_remote_fate_entry(
						_get_day_number_for_wave(maxi(current_wave_index + 1, 1))
					)
		WaveState.VICTORY:
			apply_remote_victory()
		WaveState.DEFEAT:
			apply_remote_defeat()
	if leaving_fate_interlude:
		_leave_fate_interlude_presentation()
		_finish_remote_fate_return()
	_update_plant_placement_input_state()

func get_flow_state_snapshot() -> Dictionary:
	return {
		"step_id": _get_flow_step_id(current_flow_step),
		"state": int(wave_state),
		"countdown_seconds": countdown_seconds,
	}


func apply_remote_boss_started(net_id: int, boss_config: BossConfig, spawn_position: Vector2) -> void:
	if (
		not linglan_boss_enabled
		or runtime_mode != RuntimeMode.CLIENT_VIEW
		or boss_config == null
	):
		return
	_restore_remote_camera_if_boss_intro_complete()
	active_boss_config = boss_config
	current_flow_step = boss_config
	wave_state = WaveState.BOSS_ACTIVE
	state_timer.stop()
	wave_hud.show_tower_defense_boss_progress(0, 1)
	_set_local_merchants_active(false)
	_update_boss_music(boss_config)

	var boss_enemy := get_enemy_for_net_id(net_id) as LinglanBoss
	if boss_enemy == null or not is_instance_valid(boss_enemy):
		boss_enemy = _instantiate_remote_linglan_boss_proxy(net_id, boss_config, spawn_position)
	if boss_enemy != null and is_instance_valid(boss_enemy):
		linglan_boss = boss_enemy
		if boss_container != null and linglan_boss.get_parent() != boss_container:
			linglan_boss.reparent(boss_container, true)
		linglan_boss.global_position = spawn_position
		linglan_boss.visible = true
		if linglan_boss.animated_sprite != null and not linglan_boss.is_dead:
			linglan_boss.animated_sprite.play(&"idle")
		_ensure_boss_health_hud_runtime_node(boss_config)
		if boss_health_hud != null:
			boss_health_hud.show_for_boss(linglan_boss, _get_boss_display_name(boss_config))


func _instantiate_remote_linglan_boss_proxy(
	net_id: int,
	boss_config: BossConfig,
	spawn_position: Vector2
) -> LinglanBoss:
	if not linglan_boss_enabled or net_id <= 0 or boss_config == null:
		return null
	var enemy_config := _get_boss_enemy_config(boss_config)
	if enemy_config == null or enemy_config.enemy_scene == null:
		return null
	var boss_enemy := enemy_config.enemy_scene.instantiate() as LinglanBoss
	if boss_enemy == null:
		return null
	boss_container.add_child(boss_enemy)
	boss_enemy.global_position = spawn_position
	boss_enemy.setup(enemy_config, player, grid_pathfinder)
	configure_runtime_enemy_modifiers(boss_enemy)
	boss_enemy.configure_multiplayer_proxy()
	boss_enemy.set_meta("net_id", net_id)
	multiplayer_enemies_by_net_id[net_id] = boss_enemy
	register_combat_target(net_id, boss_enemy)
	multiplayer_enemy_ids_by_instance[boss_enemy.get_instance_id()] = net_id
	return boss_enemy


func apply_remote_victory() -> void:
	if runtime_mode != RuntimeMode.CLIENT_VIEW:
		return
	_enter_victory(false)


func apply_remote_enemy_count(alive_count: int) -> void:
	if runtime_mode != RuntimeMode.CLIENT_VIEW:
		return
	# Enemy snapshots already carry the local proxy count. The dedicated HUD
	# field can consume it without overwriting the independently replicated wave
	# progress, so no additional multiplayer message is needed.
	wave_hud.set_tower_defense_enemy_count(maxi(alive_count, 0))



func apply_remote_defeat() -> void:
	if runtime_mode != RuntimeMode.CLIENT_VIEW:
		return
	_enter_defeat(false)


func show_damage_number(
	amount: int,
	spawn_position: Vector2,
	impact_direction: Vector2 = Vector2.ZERO,
	damage_type: EnemyConfig.DamageType = EnemyConfig.DamageType.PHYSICAL,
	display_priority: DamageNumberPool.DisplayPriority = DamageNumberPool.DisplayPriority.NORMAL
) -> bool:
	return show_combat_number(
		amount,
		spawn_position,
		DamageNumberPool.CombatNumberKind.DAMAGE,
		impact_direction,
		damage_type,
		display_priority
	)


func show_combat_number(
	amount: int,
	spawn_position: Vector2,
	number_kind: DamageNumberPool.CombatNumberKind,
	motion_direction: Vector2 = Vector2.ZERO,
	damage_type: EnemyConfig.DamageType = EnemyConfig.DamageType.PHYSICAL,
	display_priority: DamageNumberPool.DisplayPriority = DamageNumberPool.DisplayPriority.NORMAL
) -> bool:
	if damage_number_pool == null:
		return false
	return damage_number_pool.show_combat_number(
		amount,
		spawn_position,
		number_kind,
		motion_direction,
		damage_type,
		display_priority
	)


func try_purchase_skill1_for_peer(peer_id: int) -> int:
	var player_instance := get_player_for_peer(peer_id)
	if player_instance == null or not is_instance_valid(player_instance):
		return PURCHASE_RESULT_INVALID_PLAYER
	if not player_instance.has_skill1():
		return PURCHASE_RESULT_INVALID_PLAYER
	if player_instance.is_skill1_upgrade_maxed():
		return PURCHASE_RESULT_SKILL1_UPGRADE_MAXED
	var free_upgrade := player_instance.has_collectible_effect(
		PickupConfig.COLLECTIBLE_EFFECT_ADMIN_DOLL
	)
	if not player_instance.try_upgrade_skill1(free_upgrade):
		return PURCHASE_RESULT_INSUFFICIENT_XIRANG
	return PURCHASE_RESULT_SKILL1_UPGRADE_SUCCESS


func apply_skill1_purchase_state(
	peer_id: int,
	current_xirang: int,
	skill1_unlocked: bool,
	skill1_upgrade_level: int = -1,
	skill1_charge_duration: float = -1.0
) -> void:
	var player_instance := get_player_for_peer(peer_id)
	if player_instance == null or not is_instance_valid(player_instance):
		return
	if player_instance.current_xirang != current_xirang:
		player_instance.current_xirang = current_xirang
		player_instance.xirang_changed.emit(current_xirang, 0)
	if skill1_unlocked and not player_instance.has_skill1():
		player_instance.unlock_skill1()
	if skill1_upgrade_level >= 0:
		player_instance.apply_skill1_upgrade_state(
			skill1_upgrade_level,
			skill1_charge_duration
		)


func show_local_skill1_purchase_result(result_code: int) -> void:
	if merchant == null:
		return
	merchant.show_purchase_result(result_code)


func player_has_luoxi_special_ticket(player_instance: Player) -> bool:
	if player_instance == null or luoxi_special_game_coordinator == null:
		return false
	return luoxi_special_game_coordinator.player_has_ticket(
		player_instance.peer_id if player_instance.peer_id > 0 else 0
	)


func supports_luoxi_special_game() -> bool:
	return wave_state not in [WaveState.VICTORY, WaveState.DEFEAT]


func request_luoxi_special_game_start() -> void:
	if runtime_mode == RuntimeMode.CLIENT_VIEW:
		return
	var peer_id := (
		multiplayer_local_peer_id
		if runtime_mode != RuntimeMode.SINGLEPLAYER
		else 0
	)
	show_local_luoxi_special_game_started(
		try_start_luoxi_special_game_for_peer(peer_id)
	)


func request_luoxi_special_game_card_reveal(
	session_revision: int,
	card_index: int
) -> void:
	if runtime_mode == RuntimeMode.CLIENT_VIEW:
		return
	var peer_id := (
		multiplayer_local_peer_id
		if runtime_mode != RuntimeMode.SINGLEPLAYER
		else 0
	)
	show_local_luoxi_special_game_card_revealed(
		try_reveal_luoxi_special_game_card_for_peer(
			peer_id,
			session_revision,
			card_index
		)
	)


func request_luoxi_special_game_finish(session_revision: int) -> void:
	if runtime_mode == RuntimeMode.CLIENT_VIEW:
		return
	var peer_id := (
		multiplayer_local_peer_id
		if runtime_mode != RuntimeMode.SINGLEPLAYER
		else 0
	)
	show_local_luoxi_special_game_finished(
		try_finish_luoxi_special_game_for_peer(peer_id, session_revision)
	)


func try_start_luoxi_special_game_for_peer(peer_id: int) -> Dictionary:
	if luoxi_special_game_coordinator == null:
		return {
			"result_code": LuoxiSpecialGameCoordinator.ResultCode.INVALID_PLAYER,
		}
	return luoxi_special_game_coordinator.start_for_peer(peer_id)


func try_reveal_luoxi_special_game_card_for_peer(
	peer_id: int,
	session_revision: int,
	card_index: int
) -> Dictionary:
	if luoxi_special_game_coordinator == null:
		return {
			"result_code": LuoxiSpecialGameCoordinator.ResultCode.INVALID_PLAYER,
		}
	return luoxi_special_game_coordinator.reveal_for_peer(
		peer_id,
		session_revision,
		card_index
	)


func try_finish_luoxi_special_game_for_peer(
	peer_id: int,
	session_revision: int
) -> Dictionary:
	if luoxi_special_game_coordinator == null:
		return {
			"result_code": LuoxiSpecialGameCoordinator.ResultCode.INVALID_PLAYER,
		}
	return luoxi_special_game_coordinator.finish_for_peer(
		peer_id,
		session_revision
	)


func cancel_luoxi_special_game_for_peer(peer_id: int) -> void:
	if luoxi_special_game_coordinator != null:
		luoxi_special_game_coordinator.cancel_for_peer(peer_id)


func show_local_luoxi_special_game_started(result: Dictionary) -> void:
	if luoxi_merchant != null:
		luoxi_merchant.apply_special_game_started(result)


func show_local_luoxi_special_game_card_revealed(result: Dictionary) -> void:
	if luoxi_merchant != null:
		luoxi_merchant.apply_special_game_card_revealed(result)


func show_local_luoxi_special_game_finished(result: Dictionary) -> void:
	if luoxi_merchant != null:
		luoxi_merchant.apply_special_game_finished(result)


func get_luoxi_damageable_players() -> Array[Player]:
	var result: Array[Player] = []
	if runtime_mode == RuntimeMode.SINGLEPLAYER:
		if player != null and is_instance_valid(player):
			result.append(player)
		return result
	for player_variant in peer_players.values():
		var player_instance := player_variant as Player
		if player_instance != null and is_instance_valid(player_instance):
			result.append(player_instance)
	return result


func apply_luoxi_player_health_loss(
	target_player: Player,
	amount: int,
	minimum_health: int = 0
) -> int:
	if (
		target_player == null
		or not is_instance_valid(target_player)
		or target_player.is_dead
		or amount <= 0
		or runtime_mode == RuntimeMode.CLIENT_VIEW
	):
		return 0
	if runtime_mode == RuntimeMode.SINGLEPLAYER:
		return target_player.apply_direct_health_loss(amount, minimum_health)
	var current_scene := get_tree().current_scene
	if (
		current_scene == null
		or not current_scene.has_method("apply_luoxi_direct_health_loss")
	):
		push_error("GameTowerDefense: 多人洛茜直接扣血缺少主机复制入口。")
		return 0
	return int(current_scene.call(
		"apply_luoxi_direct_health_loss",
		target_player,
		amount,
		minimum_health
	))


func apply_luoxi_core_health_loss(amount: int) -> int:
	if runtime_mode == RuntimeMode.CLIENT_VIEW or amount <= 0:
		return 0
	var previous_health := current_base_health
	_apply_base_damage(amount)
	return previous_health - current_base_health


func request_luoxi_collectible_choice(choice_index: int, config_path: String = "") -> void:
	if runtime_mode == RuntimeMode.CLIENT_VIEW:
		return
	var peer_id := multiplayer_local_peer_id if runtime_mode != RuntimeMode.SINGLEPLAYER else 0
	var resolved_config_path := _resolve_luoxi_collectible_path(choice_index, config_path)
	var result_code := try_claim_luoxi_collectible_for_peer(peer_id, resolved_config_path)
	show_local_luoxi_collectible_result(result_code)


func request_luoxi_collectible_refresh() -> void:
	if runtime_mode == RuntimeMode.CLIENT_VIEW:
		return
	var peer_id := multiplayer_local_peer_id if runtime_mode != RuntimeMode.SINGLEPLAYER else 0
	var player_instance := player if peer_id <= 0 else get_player_for_peer(peer_id)
	var result_code := try_refresh_luoxi_collectibles_for_peer(peer_id)
	show_local_luoxi_refresh_result(
		result_code,
		get_luoxi_collectible_refresh_count(peer_id),
		player_instance.current_xirang if player_instance != null else 0
	)


func try_refresh_luoxi_collectibles_for_peer(peer_id: int) -> int:
	var player_instance := player if peer_id <= 0 else get_player_for_peer(peer_id)
	if player_instance == null or not is_instance_valid(player_instance) or luoxi_merchant == null:
		return LuoxiMerchant.REFRESH_RESULT_INVALID_PLAYER
	if has_luoxi_collectible_claimed(peer_id):
		return LuoxiMerchant.REFRESH_RESULT_INVALID_PLAYER
	return luoxi_merchant.try_purchase_refresh_for_player(player_instance)


func get_luoxi_collectible_refresh_count(peer_id: int) -> int:
	if luoxi_merchant == null:
		return 0
	return luoxi_merchant.get_player_refresh_count(maxi(peer_id, 0))


func try_claim_luoxi_collectible_for_peer(peer_id: int, config_path_or_choice: Variant) -> int:
	var player_instance := player if peer_id <= 0 else get_player_for_peer(peer_id)
	if player_instance == null or not is_instance_valid(player_instance):
		return LuoxiMerchant.COLLECTIBLE_RESULT_INVALID_PLAYER

	var claim_key := maxi(peer_id, 0)
	if get_luoxi_collectible_claim_count(claim_key) >= LuoxiMerchant.COLLECTIBLE_CLAIMS_PER_ROUND:
		return LuoxiMerchant.COLLECTIBLE_RESULT_ALREADY_CLAIMED

	var config_path := ""
	if typeof(config_path_or_choice) == TYPE_INT:
		config_path = _resolve_luoxi_collectible_path(int(config_path_or_choice), "")
	else:
		config_path = String(config_path_or_choice)
	var item := LuoxiMerchant.get_collectible_for_path(config_path)
	if item == null:
		return LuoxiMerchant.COLLECTIBLE_RESULT_INVALID_PLAYER
	if not player_instance.is_collectible_compatible(item):
		return LuoxiMerchant.COLLECTIBLE_RESULT_INVALID_PLAYER
	if not LuoxiMerchant.is_collectible_available_for_inventory(item, run_state, peer_id):
		return LuoxiMerchant.COLLECTIBLE_RESULT_INVALID_PLAYER

	var stored := (
		run_state.try_add_item_for_peer(peer_id, item)
		if peer_id > 0
		else run_state.try_add_item(item)
	)
	if not stored:
		return LuoxiMerchant.COLLECTIBLE_RESULT_INVENTORY_FULL

	record_luoxi_collectible_claim(claim_key)
	return LuoxiMerchant.COLLECTIBLE_RESULT_SUCCESS


func _resolve_luoxi_collectible_path(choice_index: int, config_path: String) -> String:
	if not config_path.is_empty():
		return config_path
	var item := LuoxiMerchant.get_collectible_for_choice(choice_index)
	return item.resource_path if item != null else ""


func has_luoxi_collectible_claimed(peer_id: int) -> bool:
	return get_luoxi_collectible_claim_count(peer_id) >= LuoxiMerchant.COLLECTIBLE_CLAIMS_PER_ROUND


func get_luoxi_collectible_claim_count(peer_id: int) -> int:
	return int(luoxi_collectible_claim_counts.get(maxi(peer_id, 0), 0))


func record_luoxi_collectible_claim(peer_id: int) -> void:
	var claim_key := maxi(peer_id, 0)
	luoxi_collectible_claim_counts[claim_key] = mini(
		get_luoxi_collectible_claim_count(claim_key) + 1,
		LuoxiMerchant.COLLECTIBLE_CLAIMS_PER_ROUND
	)


func mark_luoxi_collectible_claimed(peer_id: int) -> void:
	luoxi_collectible_claim_counts[maxi(peer_id, 0)] = LuoxiMerchant.COLLECTIBLE_CLAIMS_PER_ROUND


func show_local_luoxi_collectible_result(result_code: int) -> void:
	if luoxi_merchant == null:
		return
	luoxi_merchant.show_collectible_result(result_code)


func show_local_luoxi_refresh_result(
	result_code: int,
	refresh_count: int,
	current_xirang: int
) -> void:
	if luoxi_merchant == null:
		return
	luoxi_merchant.show_refresh_result(result_code, refresh_count, current_xirang)


func _on_wave_hud_return_to_lobby_requested() -> void:
	if runtime_mode == RuntimeMode.SINGLEPLAYER:
		_cancel_plant_placement()
		get_tree().change_scene_to_file("res://scene/main_menu.tscn")
		return
	return_to_lobby_requested.emit()


func _on_wave_hud_start_wave_requested() -> void:
	if runtime_mode == RuntimeMode.CLIENT_VIEW:
		var current_scene := get_tree().current_scene
		if current_scene != null and current_scene.has_method("request_multiplayer_start_wave"):
			current_scene.call("request_multiplayer_start_wave")
		return
	request_tower_defense_wave_start(multiplayer_local_peer_id)


func request_tower_defense_wave_start(requester_peer_id: int = 0) -> bool:
	if runtime_mode == RuntimeMode.CLIENT_VIEW:
		return false
	if (
		runtime_mode == RuntimeMode.HOST_AUTHORITY
		and (
			requester_peer_id != multiplayer_local_peer_id
			or not peer_players.has(requester_peer_id)
		)
	):
		return false
	if wave_state != WaveState.PRE_WAVE and wave_state != WaveState.INTERMISSION:
		return false
	var flow_step := (
		current_flow_step
		if wave_state == WaveState.PRE_WAVE
		else next_flow_step_after_rest
	)
	if flow_step == null:
		return false
	state_timer.stop()
	countdown_seconds = 0
	_begin_flow_step(flow_step)
	return true


func _set_merchant_active(active: bool) -> void:
	var changed := _set_local_merchants_active(active)
	if not changed:
		return
	if runtime_mode == RuntimeMode.HOST_AUTHORITY:
		multiplayer_merchant_active_changed.emit(active)


func _set_local_merchants_active(active: bool) -> bool:
	var changed := merchant_intermission_active != active
	var entering_new_intermission := active and not merchant_intermission_active
	merchant_intermission_active = active
	if merchant != null and not merchant.is_active:
		merchant.set_active(true)
		changed = true
	if luoxi_merchant != null:
		if not luoxi_merchant.is_active:
			luoxi_merchant.set_active(true)
			changed = true
		if entering_new_intermission:
			luoxi_collectible_claim_counts.clear()
			if luoxi_special_game_coordinator != null:
				luoxi_special_game_coordinator.cancel_all()
			luoxi_merchant.reset_intermission_state()
	return changed


func _configure_linglan_boss() -> void:
	if linglan_boss == null:
		return
	var boss_config := active_boss_config if active_boss_config != null else _get_first_boss_config()
	if boss_config != null:
		linglan_boss.config = _get_boss_enemy_config(boss_config)
		linglan_boss.global_position = _get_linglan_spawn_global_position(boss_config)
	linglan_boss.set_active(false)
	if not linglan_boss.defeated.is_connected(_on_linglan_boss_defeated):
		linglan_boss.defeated.connect(_on_linglan_boss_defeated)
	if linglan_boss_intro_vfx != null:
		linglan_boss_intro_vfx.stop_intro()
		if not linglan_boss_intro_vfx.intro_finished.is_connected(_on_linglan_boss_intro_finished):
			linglan_boss_intro_vfx.intro_finished.connect(_on_linglan_boss_intro_finished)
	if boss_health_hud != null:
		boss_health_hud.hide_all()


func _request_boss_runtime_scene_loads() -> void:
	if boss_runtime_scene_loads_requested:
		return
	if not linglan_boss_enabled:
		return
	boss_runtime_scene_loads_requested = true
	for resource_path in _get_boss_runtime_resource_paths():
		ResourceLoader.load_threaded_request(resource_path)


func _get_boss_runtime_resource_paths() -> Array[String]:
	var paths: Array[String] = []
	for boss_config in _get_configured_bosses():
		if not _boss_config_has_required_data(boss_config):
			continue
		var enemy_config_path := _get_boss_enemy_config_path(boss_config)
		if not enemy_config_path.is_empty() and not paths.has(enemy_config_path):
			paths.append(enemy_config_path)
		var intro_path := _get_boss_intro_vfx_scene_path(boss_config)
		if not intro_path.is_empty() and not paths.has(intro_path):
			paths.append(intro_path)
		var hud_path := _get_boss_hud_scene_path(boss_config)
		if not hud_path.is_empty() and not paths.has(hud_path):
			paths.append(hud_path)
	for slime_config_path in LINGLAN_SLIME_CONFIG_PATHS:
		if not paths.has(slime_config_path):
			paths.append(slime_config_path)
	paths.append(LINGLAN_ENRAGE_SNIPER_CONFIG_PATH)
	return paths


func _prewarm_boss_runtime_resources() -> void:
	if not linglan_boss_enabled or not _can_continue_runtime_prewarm():
		return
	_request_boss_runtime_scene_loads()
	for resource_path in _get_boss_runtime_resource_paths():
		if boss_runtime_resources_by_path.has(resource_path):
			continue
		var status := ResourceLoader.load_threaded_get_status(resource_path)
		while status == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
			await get_tree().process_frame
			if not _can_continue_runtime_prewarm():
				return
			status = ResourceLoader.load_threaded_get_status(resource_path)
		var runtime_resource := (
			ResourceLoader.load_threaded_get(resource_path)
			if status == ResourceLoader.THREAD_LOAD_LOADED
			else load(resource_path)
		)
		if runtime_resource != null:
			boss_runtime_resources_by_path[resource_path] = runtime_resource


func _cache_linglan_slime_configs() -> void:
	if linglan_slime_configs.size() == LINGLAN_SLIME_CONFIG_PATHS.size():
		return
	linglan_slime_configs.clear()
	for config_path in LINGLAN_SLIME_CONFIG_PATHS:
		var slime_config := _load_threaded_or_direct(config_path) as EnemyConfig
		if slime_config != null:
			linglan_slime_configs.append(slime_config)


func get_linglan_enrage_sniper_config() -> EnemyConfig:
	if linglan_enrage_sniper_config == null:
		linglan_enrage_sniper_config = (
			_load_threaded_or_direct(LINGLAN_ENRAGE_SNIPER_CONFIG_PATH) as EnemyConfig
		)
	return linglan_enrage_sniper_config


func _deferred_request_boss_runtime_scene_loads() -> void:
	if DisplayServer.get_name() == "headless":
		return
	await get_tree().process_frame
	if not _can_continue_runtime_prewarm():
		return
	await get_tree().process_frame
	if not _can_continue_runtime_prewarm():
		return
	_request_boss_runtime_scene_loads()


func _get_first_boss_config() -> Resource:
	for boss_config in _get_configured_bosses():
		if _boss_config_has_required_data(boss_config):
			return boss_config
	return null


func _get_configured_bosses() -> Array[BossConfig]:
	var result: Array[BossConfig] = []
	if flow_graph != null:
		for step in flow_graph.steps:
			var boss_step := step as BossConfig
			if boss_step != null:
				result.append(boss_step)
	if result.is_empty():
		for boss_resource in bosses:
			var boss_config := boss_resource as BossConfig
			if boss_config != null:
				result.append(boss_config)
	return result


func _boss_config_has_required_data(boss_config: Resource) -> bool:
	if boss_config == null:
		return false
	if boss_config.has_method("has_required_data"):
		return bool(boss_config.call("has_required_data"))
	return (
		(_get_boss_enemy_config(boss_config) != null or not _get_boss_enemy_config_path(boss_config).is_empty())
	)


func _get_boss_enemy_config(boss_config: Resource) -> EnemyConfig:
	if boss_config == null:
		return null
	if boss_config.has_method("get_enemy_config"):
		return boss_config.call("get_enemy_config") as EnemyConfig
	var enemy_config := boss_config.get("enemy_config") as EnemyConfig
	if enemy_config != null:
		return enemy_config
	var enemy_config_path := _get_boss_enemy_config_path(boss_config)
	if enemy_config_path.is_empty():
		return null
	return _load_threaded_or_direct(enemy_config_path) as EnemyConfig


func _get_boss_enemy_config_path(boss_config: Resource) -> String:
	if boss_config == null:
		return ""
	var path_value: Variant = boss_config.get("enemy_config_path")
	if typeof(path_value) == TYPE_STRING and not String(path_value).is_empty():
		return String(path_value)
	var enemy_config := boss_config.get("enemy_config") as EnemyConfig
	if enemy_config != null:
		return enemy_config.resource_path
	return ""


func _get_boss_arena_center(boss_config: Resource) -> Vector2:
	return boss_config.get("arena_center")


func _get_linglan_spawn_global_position(boss_config: Resource) -> Vector2:
	var upper_gate_spawn := _get_enemy_spawn_marker(&"Spawn5")
	var lower_gate_spawn := _get_enemy_spawn_marker(&"Spawn6")
	if upper_gate_spawn != null and lower_gate_spawn != null:
		return (
			(upper_gate_spawn.global_position + lower_gate_spawn.global_position) * 0.5
			+ Vector2.LEFT * LINGLAN_SPAWN_LEFT_OFFSET
		).round()
	return _get_boss_arena_center(boss_config) if boss_config != null else Vector2.ZERO


func _get_boss_arena_floor_rect(boss_config: Resource) -> Rect2i:
	return boss_config.get("arena_floor_rect")


func _get_boss_floor_source_id(boss_config: Resource) -> int:
	return int(boss_config.get("floor_source_id"))


func _get_boss_floor_atlas_coords(boss_config: Resource) -> Vector2i:
	return boss_config.get("floor_atlas_coords")


func _should_clear_boss_inner_overlay_cells(boss_config: Resource) -> bool:
	return bool(boss_config.get("clear_inner_overlay_cells"))


func _get_boss_display_name(boss_config: Resource) -> String:
	var boss_name_value: Variant = boss_config.get("boss_name")
	if typeof(boss_name_value) == TYPE_STRING and not String(boss_name_value).is_empty():
		return String(boss_name_value)
	var enemy_config := _get_boss_enemy_config(boss_config)
	if enemy_config != null and not enemy_config.display_name.is_empty():
		return enemy_config.display_name
	return "Boss"


func _get_boss_intro_vfx_scene_path(boss_config: Resource) -> String:
	if boss_config == null:
		return LINGLAN_BOSS_INTRO_VFX_SCENE_PATH
	var path_value: Variant = boss_config.get("intro_vfx_scene_path")
	if typeof(path_value) == TYPE_STRING and not String(path_value).is_empty():
		return String(path_value)
	return LINGLAN_BOSS_INTRO_VFX_SCENE_PATH


func _get_boss_hud_scene_path(boss_config: Resource) -> String:
	if boss_config == null:
		return BOSS_HEALTH_HUD_SCENE_PATH
	var path_value: Variant = boss_config.get("boss_hud_scene_path")
	if typeof(path_value) == TYPE_STRING and not String(path_value).is_empty():
		return String(path_value)
	return BOSS_HEALTH_HUD_SCENE_PATH


func _ensure_linglan_boss_runtime_nodes(boss_config: Resource) -> bool:
	if not linglan_boss_enabled or boss_container == null:
		return false
	var enemy_config := _get_boss_enemy_config(boss_config)
	if enemy_config == null or enemy_config.enemy_scene == null:
		push_error("Boss 配置缺少可实例化的 EnemyConfig 或 enemy_scene。")
		return false

	if linglan_boss == null or not is_instance_valid(linglan_boss):
		var boss_instance := enemy_config.enemy_scene.instantiate()
		linglan_boss = boss_instance as LinglanBoss
		if linglan_boss == null:
			if boss_instance != null:
				boss_instance.free()
			push_error("Boss enemy_scene 必须实例化为 LinglanBoss。")
			return false
		linglan_boss.config = enemy_config
		linglan_boss.name = "LinglanBoss"
		boss_container.add_child(linglan_boss)

	if linglan_boss_intro_vfx == null or not is_instance_valid(linglan_boss_intro_vfx):
		var intro_scene := _load_threaded_or_direct(_get_boss_intro_vfx_scene_path(boss_config)) as PackedScene
		if intro_scene == null:
			push_error("无法加载铃兰 Boss 入场 VFX 场景。")
			return false
		var intro_instance := intro_scene.instantiate()
		linglan_boss_intro_vfx = intro_instance as LinglanBossIntroVFX
		if linglan_boss_intro_vfx == null:
			if intro_instance != null:
				intro_instance.free()
			push_error("铃兰 Boss 入场 VFX 场景类型不正确。")
			return false
		linglan_boss_intro_vfx.name = "LinglanBossIntroVFX"
		add_child(linglan_boss_intro_vfx)

	if not _ensure_boss_health_hud_runtime_node(boss_config):
		return false

	_cache_linglan_slime_configs()
	if get_linglan_enrage_sniper_config() == null:
		push_error("无法加载铃兰半血空降狙击手配置。")
		return false
	_configure_linglan_boss()
	return true


func _ensure_boss_health_hud_runtime_node(boss_config: Resource) -> bool:
	if boss_health_hud != null and is_instance_valid(boss_health_hud):
		return true
	var hud_scene := _load_threaded_or_direct(_get_boss_hud_scene_path(boss_config)) as PackedScene
	if hud_scene == null:
		push_error("无法加载 Boss 大 HUD 场景。")
		return false
	var hud_instance := hud_scene.instantiate()
	boss_health_hud = hud_instance as BossHealthHUD
	if boss_health_hud == null:
		if hud_instance != null:
			hud_instance.free()
		push_error("Boss 大 HUD 场景类型不正确。")
		return false
	boss_health_hud.name = "BossHealthHUD"
	add_child(boss_health_hud)
	return true


func _load_threaded_or_direct(path: String) -> Resource:
	if path.is_empty():
		return null
	var retained_resource := boss_runtime_resources_by_path.get(path) as Resource
	if retained_resource != null:
		return retained_resource
	var status := ResourceLoader.load_threaded_get_status(path)
	if status == ResourceLoader.THREAD_LOAD_LOADED:
		return ResourceLoader.load_threaded_get(path)
	if status == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
		return ResourceLoader.load_threaded_get(path)
	return load(path)


func _collect_enemy_spawn_points() -> void:
	enemy_spawn_points.clear()
	enemy_spawn_points_by_name.clear()
	active_wave_spawn_points.clear()
	spawn_point_configuration_valid = true
	for child in enemy_spawn_points_root.get_children():
		var spawn_point := child as Marker2D
		if spawn_point != null:
			var spawn_name := StringName(spawn_point.name)
			if enemy_spawn_points_by_name.has(spawn_name):
				push_error("EnemySpawnPoints 包含重复名称：%s" % String(spawn_name))
				spawn_point_configuration_valid = false
				continue
			enemy_spawn_points.append(spawn_point)
			enemy_spawn_points_by_name[spawn_name] = spawn_point

	if enemy_spawn_points.is_empty():
		push_warning("EnemySpawnPoints 下没有可用的 Marker2D 刷新点。")


func _configure_timers() -> void:
	enemy_spawn_timer.one_shot = false
	if not enemy_spawn_timer.timeout.is_connected(_on_enemy_spawn_timer_timeout):
		enemy_spawn_timer.timeout.connect(_on_enemy_spawn_timer_timeout)

	state_timer.one_shot = false
	state_timer.wait_time = 1.0
	if not state_timer.timeout.is_connected(_on_state_timer_timeout):
		state_timer.timeout.connect(_on_state_timer_timeout)

	plant_terrain_decay_timer.one_shot = false
	plant_terrain_decay_timer.wait_time = UNSUPPORTED_PLANT_DAMAGE_INTERVAL_SECONDS
	plant_terrain_decay_timer.process_callback = Timer.TIMER_PROCESS_PHYSICS
	if not plant_terrain_decay_timer.timeout.is_connected(
		_on_plant_terrain_decay_timer_timeout
	):
		plant_terrain_decay_timer.timeout.connect(
			_on_plant_terrain_decay_timer_timeout
		)
	if runtime_mode == RuntimeMode.CLIENT_VIEW:
		plant_terrain_decay_timer.stop()
	else:
		plant_terrain_decay_timer.start()


func _get_initial_preparation_seconds() -> int:
	return maxi(ceili(progression_config.initial_preparation_seconds), 0)


func _get_wave_intermission_seconds() -> int:
	return maxi(ceili(progression_config.wave_intermission_seconds), 0)


func _get_new_day_preparation_seconds() -> int:
	return maxi(ceili(progression_config.new_day_preparation_seconds), 0)


func _get_current_intermission_seconds() -> int:
	var completed_wave_number := maxi(current_wave_index + 1, 1)
	return (
		_get_new_day_preparation_seconds()
		if day_cycle_config.is_day_end_wave(completed_wave_number)
		else _get_wave_intermission_seconds()
	)


func _can_local_player_start_wave_early() -> bool:
	return runtime_mode != RuntimeMode.CLIENT_VIEW


func _prewarm_enemy_navigation_grids() -> void:
	if grid_pathfinder == null:
		return
	if not grid_pathfinder.has_method("prewarm_agent_grid"):
		return
	if not bool(grid_pathfinder.get("is_built")):
		return

	var seen_scene_keys: Dictionary = {}
	var seen_extent_keys: Dictionary = {}
	for wave_config in waves:
		if wave_config == null:
			continue
		for entry in wave_config.enemy_entries:
			if entry == null or entry.enemy_config == null:
				continue
			var enemy_config := entry.enemy_config
			if enemy_config.enemy_scene == null:
				continue
			var scene_key := enemy_config.enemy_scene.resource_path
			if scene_key.is_empty():
				scene_key = enemy_config.resource_path
			if seen_scene_keys.has(scene_key):
				continue
			seen_scene_keys[scene_key] = true

			var body_half_extents := _get_enemy_scene_body_half_extents(enemy_config)
			if body_half_extents == Vector2.ZERO:
				continue
			var traversal_types := enemy_config.terrain_traversal_types
			var extent_key := "%d:%d:%d" % [
				ceili(body_half_extents.x),
				ceili(body_half_extents.y),
				traversal_types,
			]
			if seen_extent_keys.has(extent_key):
				continue
			seen_extent_keys[extent_key] = true
			grid_pathfinder.call(
				"prewarm_agent_grid",
				body_half_extents,
				traversal_types
			)
			if grid_pathfinder.has_method("prewarm_flow_navigation_target"):
				var navigation_targets: Array[Node2D] = []
				if player != null:
					navigation_targets.append(player)
				navigation_targets.append_array(get_home_objective_targets())
				for navigation_target in navigation_targets:
					if navigation_target == null or not is_instance_valid(navigation_target):
						continue
					grid_pathfinder.call(
						"prewarm_flow_navigation_target",
						navigation_target.global_position,
						body_half_extents,
						traversal_types
					)


func prepare_shared_runtime_data_and_complete() -> void:
	await _prewarm_tower_shared_runtime_data()
	if not _can_continue_runtime_prewarm():
		return
	await _prewarm_plant_lifecycle_shader()
	if _can_continue_runtime_prewarm():
		mark_runtime_preparation_complete()


func _prewarm_tower_shared_runtime_data() -> void:
	await prewarm_shared_runtime_data()
	if not _can_continue_runtime_prewarm():
		return
	await _prewarm_boss_runtime_resources()
	if not _can_continue_runtime_prewarm():
		return
	if fate_coordinator != null:
		await fate_coordinator.prewarm_elite_enemy_configs()


func _can_continue_runtime_prewarm() -> bool:
	return not runtime_prewarm_tearing_down and is_inside_tree()


func _prewarm_plant_lifecycle_shader() -> void:
	if (
		not _can_continue_runtime_prewarm()
		or plant_lifecycle_shader_prewarmed
		or not runtime_activation_deferred
		or plant_lifecycle_shader_prewarm == null
		or bamboo_mortar_lifecycle_shader_prewarm == null
		or bamboo_mortar_glow_shader_prewarm == null
	):
		return
	update_runtime_preparation_progress("预热植物生命周期特效…", 0, 1)
	var prewarm_position := map_camera.get_screen_center_position()
	plant_lifecycle_shader_prewarm.global_position = prewarm_position
	bamboo_mortar_lifecycle_shader_prewarm.global_position = (
		prewarm_position
	)
	bamboo_mortar_glow_shader_prewarm.global_position = prewarm_position
	plant_lifecycle_shader_prewarm.set_instance_shader_parameter(
		&"construction_progress",
		0.5
	)
	plant_lifecycle_shader_prewarm.set_instance_shader_parameter(
		&"construction_front_strength",
		1.0
	)
	plant_lifecycle_shader_prewarm.set_instance_shader_parameter(&"removal_enabled", true)
	plant_lifecycle_shader_prewarm.set_instance_shader_parameter(&"removal_progress", 0.5)
	plant_lifecycle_shader_prewarm.show()
	bamboo_mortar_lifecycle_shader_prewarm.show()
	bamboo_mortar_glow_shader_prewarm.show()

	# The pre-authored Sprite2D compiles the lifecycle shader. Briefly drawing
	# one pooled instance of each particle effect in the same masked frame also
	# compiles their particle and canvas pipelines without adding runtime nodes.
	var placement_particles := session_object_pool.try_acquire(
		PLANT_PLACEMENT_PARTICLES_SCENE
	) as GPUParticles2D
	if placement_particles != null:
		placement_particles.global_position = prewarm_position
		placement_particles.reset_physics_interpolation()
		placement_particles.amount_ratio = 1.0
		placement_particles.restart()
		placement_particles.emitting = true
	var removal_smoke := session_object_pool.try_acquire(
		PLANT_REMOVAL_SMOKE_SCENE
	) as GPUParticles2D
	if removal_smoke != null:
		removal_smoke.global_position = prewarm_position
		removal_smoke.reset_physics_interpolation()
		removal_smoke.restart()
		removal_smoke.emitting = true
	if DisplayServer.get_name() == "headless":
		# A headless DisplayServer has no Canvas frame to compile or signal. Still
		# advance once so the pooled leases exercise the same acquire/release path.
		await get_tree().process_frame
	else:
		await RenderingServer.frame_post_draw
	if not _can_continue_runtime_prewarm():
		return
	plant_lifecycle_shader_prewarm.hide()
	bamboo_mortar_lifecycle_shader_prewarm.hide()
	bamboo_mortar_glow_shader_prewarm.hide()
	if placement_particles != null:
		placement_particles.emitting = false
		placement_particles.amount_ratio = 0.0
		SessionObjectPool.release_to_owner(placement_particles)
	if removal_smoke != null:
		removal_smoke.emitting = false
		SessionObjectPool.release_to_owner(removal_smoke)
	if not is_inside_tree():
		return
	plant_lifecycle_shader_prewarmed = true
	update_runtime_preparation_progress("预热植物生命周期特效…", 1, 1)


func _schedule_enemy_navigation_prewarm() -> void:
	if runtime_mode == RuntimeMode.CLIENT_VIEW:
		return
	if navigation_prewarmed or navigation_prewarm_requested:
		return
	navigation_prewarm_requested = true
	call_deferred("_run_scheduled_enemy_navigation_prewarm")


func _run_scheduled_enemy_navigation_prewarm() -> void:
	await get_tree().process_frame
	if not _can_continue_runtime_prewarm():
		return
	await get_tree().process_frame
	if not _can_continue_runtime_prewarm():
		return
	navigation_prewarm_requested = false
	if navigation_prewarmed:
		await _prewarm_tower_shared_runtime_data()
		if not _can_continue_runtime_prewarm():
			return
		await _prewarm_plant_lifecycle_shader()
		if not _can_continue_runtime_prewarm():
			return
		mark_runtime_preparation_complete()
		return
	await _prewarm_enemy_navigation_grids_staged()
	if not _can_continue_runtime_prewarm():
		return
	navigation_prewarmed = true
	await _prewarm_tower_shared_runtime_data()
	if not _can_continue_runtime_prewarm():
		return
	await _prewarm_plant_lifecycle_shader()
	if not _can_continue_runtime_prewarm():
		return
	mark_runtime_preparation_complete()


func _prewarm_enemy_navigation_grids_staged() -> void:
	update_runtime_preparation_progress("分析塔防敌人体型…", 0, 1)
	await get_tree().process_frame
	if (
		not _can_continue_runtime_prewarm()
		or grid_pathfinder == null
		or not grid_pathfinder.has_method("prewarm_agent_grid")
		or not bool(grid_pathfinder.get("is_built"))
	):
		return

	var profiles: Array[Dictionary] = []
	var seen_scene_keys: Dictionary = {}
	var seen_extent_keys: Dictionary = {}
	for wave_config in waves:
		if wave_config == null:
			continue
		for entry in wave_config.enemy_entries:
			if entry == null or entry.enemy_config == null:
				continue
			var enemy_config := entry.enemy_config
			if enemy_config.enemy_scene == null:
				continue
			var scene_key := enemy_config.enemy_scene.resource_path
			if scene_key.is_empty():
				scene_key = enemy_config.resource_path
			if seen_scene_keys.has(scene_key):
				continue
			seen_scene_keys[scene_key] = true
			var body_half_extents := _get_enemy_scene_body_half_extents(enemy_config)
			await get_tree().process_frame
			if not _can_continue_runtime_prewarm():
				return
			if body_half_extents == Vector2.ZERO:
				continue
			var traversal_types := enemy_config.terrain_traversal_types
			var extent_key := "%d:%d:%d" % [
				ceili(body_half_extents.x),
				ceili(body_half_extents.y),
				traversal_types,
			]
			if seen_extent_keys.has(extent_key):
				continue
			seen_extent_keys[extent_key] = true
			profiles.append({
				"half_extents": body_half_extents,
				"traversal_types": traversal_types,
			})

	var navigation_targets: Array[Node2D] = []
	if player != null:
		navigation_targets.append(player)
	navigation_targets.append_array(get_home_objective_targets())
	var total_steps := maxi(profiles.size() * (1 + navigation_targets.size()), 1)
	var completed_steps := 0
	update_runtime_preparation_progress("预热塔防寻路网格…", completed_steps, total_steps)
	for profile in profiles:
		var half_extents: Vector2 = profile["half_extents"]
		var traversal_types: int = int(profile["traversal_types"])
		if grid_pathfinder.has_method("prewarm_agent_grid_staged"):
			await grid_pathfinder.call(
				"prewarm_agent_grid_staged",
				half_extents,
				traversal_types
			)
			if not _can_continue_runtime_prewarm():
				return
		else:
			grid_pathfinder.call("prewarm_agent_grid", half_extents, traversal_types)
		completed_steps += 1
		update_runtime_preparation_progress("预热塔防寻路网格…", completed_steps, total_steps)
		await get_tree().process_frame
		if not _can_continue_runtime_prewarm():
			return
		if not grid_pathfinder.has_method("prewarm_flow_navigation_target"):
			continue
		for navigation_target in navigation_targets:
			if navigation_target == null or not is_instance_valid(navigation_target):
				completed_steps += 1
				continue
			if grid_pathfinder.has_method("prewarm_flow_navigation_target_staged"):
				await grid_pathfinder.call(
					"prewarm_flow_navigation_target_staged",
					navigation_target.global_position,
					half_extents,
					traversal_types
				)
				if not _can_continue_runtime_prewarm():
					return
			else:
				grid_pathfinder.call(
					"prewarm_flow_navigation_target",
					navigation_target.global_position,
					half_extents,
					traversal_types
				)
			completed_steps += 1
			update_runtime_preparation_progress("预热 Home 防线…", completed_steps, total_steps)
			await get_tree().process_frame
			if not _can_continue_runtime_prewarm():
				return


func _prewarm_enemy_visual_resources() -> void:
	GUARDIAN_POINT_LIGHT_TEXTURE.get_size()


func _get_enemy_scene_body_half_extents(enemy_config: EnemyConfig) -> Vector2:
	if enemy_config == null or enemy_config.enemy_scene == null:
		return Vector2.ZERO
	var instance := enemy_config.enemy_scene.instantiate()
	var enemy_instance := instance as Enemy
	if enemy_instance == null:
		if instance != null:
			instance.free()
		return Vector2.ZERO
	var body_half_extents := enemy_instance.get_configured_body_collision_half_extents()
	enemy_instance.free()
	return body_half_extents


func _configure_xiaocong_fate_flow() -> void:
	if not fate_manager.state_changed.is_connected(_on_xiaocong_fate_state_changed):
		fate_manager.state_changed.connect(_on_xiaocong_fate_state_changed)
	if not fate_manager.interlude_completed.is_connected(
		_on_xiaocong_fate_interlude_completed
	):
		fate_manager.interlude_completed.connect(
			_on_xiaocong_fate_interlude_completed
		)
	if not xiaocong_fate_interlude.interaction_requested.is_connected(
		_on_local_xiaocong_interaction_requested
	):
		xiaocong_fate_interlude.interaction_requested.connect(
			_on_local_xiaocong_interaction_requested
		)
	if not xiaocong_fate_interlude.fate_choice_submitted.is_connected(
		_on_local_xiaocong_fate_choice_submitted
	):
		xiaocong_fate_interlude.fate_choice_submitted.connect(
			_on_local_xiaocong_fate_choice_submitted
		)
	if not xiaocong_fate_interlude.collectible_choice_submitted.is_connected(
		_on_local_xiaocong_collectible_choice_submitted
	):
		xiaocong_fate_interlude.collectible_choice_submitted.connect(
			_on_local_xiaocong_collectible_choice_submitted
		)
	_configure_xiaocong_local_context()


func _configure_xiaocong_local_context() -> void:
	var character_ids := multiplayer_player_character_ids.duplicate()
	if runtime_mode == RuntimeMode.SINGLEPLAYER and player != null:
		character_ids[0] = player.character_id
	xiaocong_fate_interlude.configure_local_player(
		player,
		_get_local_fate_peer_id(),
		character_ids
	)


func _get_local_fate_peer_id() -> int:
	return 0 if runtime_mode == RuntimeMode.SINGLEPLAYER else multiplayer_local_peer_id


func _get_fate_peer_ids() -> Array[int]:
	if runtime_mode == RuntimeMode.SINGLEPLAYER:
		return [0]
	var peer_ids: Array[int] = []
	for peer_variant in peer_players:
		var peer_id := int(peer_variant)
		if peer_id > 0:
			peer_ids.append(peer_id)
	peer_ids.sort()
	return peer_ids


func _get_fate_player(peer_id: int) -> Player:
	if runtime_mode == RuntimeMode.SINGLEPLAYER and peer_id == 0:
		return player
	return get_player_for_peer(peer_id)


func _on_local_xiaocong_interaction_requested() -> void:
	if runtime_mode == RuntimeMode.SINGLEPLAYER:
		request_xiaocong_interaction(0)
	else:
		multiplayer_xiaocong_interaction_requested.emit()


func _on_local_xiaocong_fate_choice_submitted(
	option_id: StringName,
	permanent_buff_id: StringName
) -> void:
	if runtime_mode == RuntimeMode.SINGLEPLAYER:
		request_xiaocong_fate_vote(0, option_id, permanent_buff_id)
	else:
		multiplayer_xiaocong_vote_requested.emit(option_id, permanent_buff_id)


func _on_local_xiaocong_collectible_choice_submitted(choice_index: int) -> void:
	if runtime_mode == RuntimeMode.SINGLEPLAYER:
		request_xiaocong_collectible_choice(0, choice_index)
	else:
		multiplayer_xiaocong_collectible_requested.emit(choice_index)


func request_xiaocong_interaction(peer_id: int) -> void:
	if runtime_mode == RuntimeMode.CLIENT_VIEW or wave_state != WaveState.FATE_INTERLUDE:
		return
	var player_instance := _get_fate_player(peer_id)
	if player_instance == null or not is_instance_valid(player_instance):
		return
	if (
		player_instance.global_position.distance_to(
			xiaocong_fate_interlude.global_position
		) > XIAOCONG_INTERACTION_DISTANCE
	):
		return
	if not fate_manager.record_interaction(peer_id):
		fate_manager.request_timeout_recovery(peer_id)


func request_xiaocong_fate_vote(
	peer_id: int,
	option_id: StringName,
	permanent_buff_id: StringName
) -> void:
	if runtime_mode == RuntimeMode.CLIENT_VIEW or wave_state != WaveState.FATE_INTERLUDE:
		return
	fate_manager.submit_vote(peer_id, option_id, permanent_buff_id)


func request_xiaocong_collectible_choice(peer_id: int, choice_index: int) -> void:
	if runtime_mode == RuntimeMode.CLIENT_VIEW or wave_state != WaveState.FATE_INTERLUDE:
		return
	fate_coordinator.request_collectible_choice(peer_id, choice_index)


func _is_fate_collectible_choice_pending_for_peer(peer_id: int) -> bool:
	return fate_coordinator.is_collectible_choice_pending_for_peer(peer_id)


func get_xiaocong_fate_state_snapshot() -> Dictionary:
	return _build_xiaocong_fate_state_snapshot()


func apply_remote_xiaocong_fate_state(state: Dictionary) -> void:
	if runtime_mode != RuntimeMode.CLIENT_VIEW:
		return
	if int(state.get("revision", 0)) < fate_manager.state_revision:
		return
	fate_coordinator.apply_remote_runtime_state(state)
	fate_manager.apply_remote_state(state)


func _build_xiaocong_fate_state_snapshot() -> Dictionary:
	var state := fate_manager.export_state()
	state.merge(fate_coordinator.export_runtime_state(), true)
	return state


func _on_xiaocong_fate_state_changed(_state: Dictionary) -> void:
	var snapshot := _build_xiaocong_fate_state_snapshot()
	_configure_xiaocong_local_context()
	xiaocong_fate_interlude.apply_fate_state(snapshot)
	if fate_manager.active:
		if not (
			runtime_mode == RuntimeMode.CLIENT_VIEW
			and remote_fate_entry_in_progress
		):
			_present_fate_interlude_locally(fate_manager.completed_day)
	elif (
		wave_state == WaveState.FATE_INTERLUDE
		and runtime_mode == RuntimeMode.CLIENT_VIEW
	):
		_begin_remote_fate_departure()
	if runtime_mode == RuntimeMode.HOST_AUTHORITY:
		multiplayer_xiaocong_fate_state_changed.emit(snapshot)

func _enter_xiaocong_fate_interlude(next_step: FlowStepConfig) -> void:
	_set_fate_interlude_systems_frozen(true)
	wave_state = WaveState.FATE_INTERLUDE
	_set_fate_player_combat_locked(true)
	next_flow_step_after_rest = next_step
	countdown_seconds = 0
	enemy_spawn_timer.stop()
	state_timer.stop()
	var completed_day := _get_day_number_for_wave(current_wave_index + 1)
	_emit_multiplayer_flow_state(WaveState.FATE_INTERLUDE)
	await xiaocong_fate_interlude.cover_scene_for_transfer()
	if wave_state != WaveState.FATE_INTERLUDE:
		return
	_set_merchant_active(false)
	transition_world_to_day()
	_force_revive_dead_players()
	_present_fate_interlude_locally(completed_day)
	_teleport_authoritative_players_to_fate_room()
	await xiaocong_fate_interlude.play_room_reveal()
	if wave_state != WaveState.FATE_INTERLUDE:
		return
	fate_coordinator.begin_interlude(
		completed_day,
		_get_flow_step_id(next_step),
		_get_fate_peer_ids(),
		_get_local_fate_peer_id()
	)


func _present_fate_interlude_locally(day_number: int) -> void:
	transition_world_to_day()
	if not xiaocong_fate_interlude.is_active:
		xiaocong_fate_interlude.set_active(true, day_number)
	wave_hud.hide_all()
	if tower_defense_status_hud != null:
		tower_defense_status_hud.hide()
	if tower_defense_minimap != null:
		tower_defense_minimap.hide()
	_set_fate_player_combat_locked(true)


func _begin_remote_fate_entry(day_number: int) -> void:
	if remote_fate_entry_in_progress:
		return
	remote_fate_entry_in_progress = true
	remote_fate_departure_in_progress = false
	remote_fate_departure_covered = false
	pending_remote_fate_flow_state.clear()
	await xiaocong_fate_interlude.cover_scene_for_transfer()
	if runtime_mode != RuntimeMode.CLIENT_VIEW or wave_state != WaveState.FATE_INTERLUDE:
		remote_fate_entry_in_progress = false
		return
	transition_world_to_day()
	_set_local_merchants_active(false)
	_present_fate_interlude_locally(day_number)
	await xiaocong_fate_interlude.play_room_reveal()
	remote_fate_entry_in_progress = false


func _begin_remote_fate_departure() -> void:
	if remote_fate_departure_in_progress:
		return
	remote_fate_departure_in_progress = true
	await xiaocong_fate_interlude.play_outcome_message(
		fate_manager.winning_option_id
	)
	await xiaocong_fate_interlude.cover_scene_for_transfer()
	remote_fate_departure_covered = true
	if pending_remote_fate_flow_state.is_empty():
		return
	var deferred_flow_state := pending_remote_fate_flow_state.duplicate()
	pending_remote_fate_flow_state.clear()
	apply_remote_flow_state(
		StringName(deferred_flow_state.get("step_id", "")),
		int(deferred_flow_state.get("state", int(WaveState.INTERMISSION))),
		int(deferred_flow_state.get("seconds", 0))
	)


func _finish_remote_fate_return() -> void:
	await xiaocong_fate_interlude.reveal_world_after_transfer()
	remote_fate_entry_in_progress = false
	remote_fate_departure_in_progress = false
	remote_fate_departure_covered = false
	pending_remote_fate_flow_state.clear()


func _leave_fate_interlude_presentation() -> void:
	xiaocong_fate_interlude.set_active(false)
	_set_fate_interlude_systems_frozen(false)
	if tower_defense_status_hud != null:
		tower_defense_status_hud.show()
	if tower_defense_minimap != null:
		tower_defense_minimap.show()
	_set_fate_player_combat_locked(false)
	_refresh_player_modal_ui_lock()
	_update_plant_placement_input_state()


func _set_fate_interlude_systems_frozen(frozen: bool) -> void:
	if plant_placement_controller != null:
		plant_placement_controller.set_placement_input_enabled(not frozen)
		plant_placement_controller.set_process_unhandled_input(not frozen)
	if frozen:
		_cancel_plant_placement()
	if runtime_mode == RuntimeMode.CLIENT_VIEW:
		return
	if production_coordinator != null:
		production_coordinator.set_authoritative_processing_enabled(not frozen)
	if research_coordinator != null:
		research_coordinator.set_authoritative_processing_enabled(not frozen)
	if plant_terrain_decay_timer == null:
		return
	if frozen:
		if not plant_terrain_decay_timer.is_stopped():
			fate_frozen_terrain_decay_time_left = plant_terrain_decay_timer.time_left
			plant_terrain_decay_timer.stop()
		return
	if plant_terrain_decay_timer.is_stopped():
		plant_terrain_decay_timer.start(
			fate_frozen_terrain_decay_time_left
			if fate_frozen_terrain_decay_time_left > 0.0
			else plant_terrain_decay_timer.wait_time
		)
	fate_frozen_terrain_decay_time_left = 0.0


func _set_fate_player_combat_locked(locked: bool) -> void:
	if runtime_mode == RuntimeMode.SINGLEPLAYER:
		if player != null and is_instance_valid(player) and not player.is_dead:
			player.set_combat_actions_locked(locked)
			player.set_controls_locked(false)
		return
	for player_variant in peer_players.values():
		var player_instance := player_variant as Player
		if (
			player_instance != null
			and is_instance_valid(player_instance)
			and not player_instance.is_dead
		):
			player_instance.set_combat_actions_locked(locked)
			player_instance.set_controls_locked(false)


func _teleport_authoritative_players_to_fate_room() -> void:
	if runtime_mode == RuntimeMode.CLIENT_VIEW:
		return
	var peer_ids := _get_fate_peer_ids()
	for slot_index in range(peer_ids.size()):
		var peer_id := peer_ids[slot_index]
		var player_instance := _get_fate_player(peer_id)
		if player_instance == null or not is_instance_valid(player_instance):
			continue
		_teleport_fate_player_authoritatively(
			peer_id,
			player_instance,
			xiaocong_fate_interlude.get_player_spawn_position(slot_index)
		)


func _restore_authoritative_players_from_fate_room() -> void:
	if runtime_mode == RuntimeMode.CLIENT_VIEW:
		return
	var peer_ids := _get_fate_peer_ids()
	for slot_index in range(peer_ids.size()):
		var peer_id := peer_ids[slot_index]
		var player_instance := _get_fate_player(peer_id)
		if player_instance == null or not is_instance_valid(player_instance):
			continue
		var spawn_offset := (
			Vector2.ZERO
			if runtime_mode == RuntimeMode.SINGLEPLAYER
			else _get_multiplayer_spawn_offset(
				int(multiplayer_spawn_slot_indices.get(peer_id, slot_index))
			)
		)
		_teleport_fate_player_authoritatively(
			peer_id,
			player_instance,
			player_spawn.global_position + spawn_offset
		)


func _teleport_fate_player_authoritatively(
	peer_id: int,
	player_instance: Player,
	target_position: Vector2
) -> void:
	if runtime_mode == RuntimeMode.HOST_AUTHORITY:
		if not multiplayer_player_teleport_requested.has_connections():
			push_error("GameTowerDefense: 多人权威传送缺少 MPGame 处理器。")
			return
		multiplayer_player_teleport_requested.emit(peer_id, target_position)
		return
	player_instance.global_position = target_position
	player_instance.velocity = Vector2.ZERO
	player_instance.reset_physics_interpolation()


func _on_xiaocong_fate_interlude_completed(next_step_id: StringName) -> void:
	if runtime_mode == RuntimeMode.CLIENT_VIEW:
		return
	var winning_option_id := fate_manager.winning_option_id
	await xiaocong_fate_interlude.play_outcome_message(winning_option_id)
	await xiaocong_fate_interlude.cover_scene_for_transfer()
	fate_coordinator.clear_pending_rewards()
	_leave_fate_interlude_presentation()
	_restore_authoritative_players_from_fate_room()
	var next_step := _get_flow_step_by_id(next_step_id)
	if next_step == null:
		_enter_victory()
		await xiaocong_fate_interlude.reveal_world_after_transfer()
		return
	_enter_intermission(next_step)
	await xiaocong_fate_interlude.reveal_world_after_transfer()


func _begin_fate_collectible_reward() -> void:
	if fate_coordinator != null:
		fate_coordinator._begin_collectible_reward()


func _remove_fate_eligible_peer(peer_id: int) -> void:
	if fate_coordinator != null:
		fate_coordinator.remove_eligible_peer(peer_id)


func _prune_missing_fate_players() -> void:
	if fate_coordinator != null:
		fate_coordinator._prune_missing_players()


func _resolve_fate_enemy_config(enemy_config: EnemyConfig) -> EnemyConfig:
	return (
		fate_coordinator.resolve_enemy_config(enemy_config)
		if fate_coordinator != null
		else enemy_config
	)


func grant_xirang_kill_reward(amount: int) -> bool:
	var rewarded_amount := amount
	if _is_fate_double_xirang_reward_active():
		rewarded_amount *= 2
	var accepted := super.grant_xirang_kill_reward(rewarded_amount)
	if accepted:
		var day_number := _get_day_number_for_wave(current_wave_index + 1)
		daily_xirang_rewards[day_number] = (
			int(daily_xirang_rewards.get(day_number, 0)) + rewarded_amount
		)
	return accepted


func _is_fate_double_xirang_reward_active() -> bool:
	return fate_coordinator != null and fate_coordinator.is_double_xirang_reward_active()


func _enter_pre_flow_step(flow_step: FlowStepConfig) -> void:
	if flow_step == null:
		_enter_victory()
		return
	wave_state = WaveState.PRE_WAVE
	transition_world_to_day()
	current_flow_step = flow_step
	next_flow_step_after_rest = flow_step
	if flow_step is WaveConfig:
		current_wave_index = _get_wave_number_for_step(flow_step as WaveConfig) - 1
	enemy_spawn_timer.stop()
	_set_merchant_active(true)
	countdown_seconds = _get_initial_preparation_seconds()
	_update_post_wave_music(flow_step)
	wave_hud.show_countdown(countdown_seconds, _can_local_player_start_wave_early())
	_schedule_enemy_navigation_prewarm()
	_emit_multiplayer_flow_state(WaveState.PRE_WAVE)

	if countdown_seconds <= 0:
		_begin_flow_step(current_flow_step)
		return

	if countdown_seconds <= COUNTDOWN_FINAL_SECONDS:
		_play_countdown_tick()
	state_timer.start(1.0)


func _enter_intermission(next_step: FlowStepConfig = null) -> void:
	wave_state = WaveState.INTERMISSION
	_apply_intermission_lighting(maxi(current_wave_index + 1, 1))
	enemy_spawn_timer.stop()
	_set_merchant_active(true)
	next_flow_step_after_rest = next_step
	countdown_seconds = _get_current_intermission_seconds()
	_update_post_wave_music(current_flow_step)
	wave_hud.show_countdown(countdown_seconds, _can_local_player_start_wave_early())
	_emit_multiplayer_flow_state(WaveState.INTERMISSION)
	_force_revive_dead_players()

	if countdown_seconds <= 0:
		_begin_flow_step(next_flow_step_after_rest)
		return

	if countdown_seconds <= COUNTDOWN_FINAL_SECONDS:
		_play_countdown_tick()
	state_timer.start(1.0)


func _begin_flow_step(flow_step: FlowStepConfig) -> void:
	if flow_step == null:
		_enter_victory()
		return
	current_flow_step = flow_step
	next_flow_step_after_rest = null
	if flow_step is WaveConfig:
		_begin_wave_config(flow_step as WaveConfig)
	elif flow_step is BossConfig:
		_begin_linglan_boss_intro(flow_step as BossConfig)
	else:
		push_error("流程节点 %s 类型不支持。" % flow_step.get_flow_display_name())
		_enter_defeat()


func _begin_wave_config(wave_config: WaveConfig) -> void:
	if wave_config == null:
		push_error("流程节点缺少 WaveConfig。")
		_enter_defeat()
		return
	if not _resolve_wave_spawn_points(wave_config):
		_enter_defeat()
		return
	if runtime_mode != RuntimeMode.CLIENT_VIEW and not navigation_prewarmed:
		_prewarm_enemy_navigation_grids()
		navigation_prewarmed = true

	wave_state = WaveState.WAVE_ACTIVE
	_reset_player_wave_death_counts()
	current_wave_index = _get_wave_number_for_step(wave_config) - 1
	_apply_wave_start_lighting(current_wave_index + 1)
	state_timer.stop()
	_set_merchant_active(false)
	current_wave_spawned = 0
	current_wave_defeated = 0
	current_wave_escaped = 0
	current_wave_resolved = 0
	resolved_home_enemy_ids.clear()
	active_wave_enemy_ids.clear()
	_clear_hud_alive_enemies()
	_build_wave_spawn_queue(wave_config)
	current_wave_total = pending_enemy_configs.size()
	_update_wave_music(wave_config)
	_show_tower_defense_wave_progress()
	wave_start_audio.play()
	_emit_multiplayer_flow_state(WaveState.WAVE_ACTIVE)

	if current_wave_total <= 0:
		_check_wave_completion()
		return

	_spawn_wave_batch()
	if _has_pending_enemy_configs():
		enemy_spawn_timer.start(maxf(wave_config.spawn_interval, MIN_WAVE_SPAWN_INTERVAL_SECONDS))


func _build_wave_spawn_queue(wave_config: WaveConfig) -> void:
	pending_enemy_configs.clear()
	pending_enemy_xirang_kill_rewards.clear()
	pending_enemy_config_index = 0
	for entry in wave_config.enemy_entries:
		if entry == null or entry.enemy_config == null:
			continue
		var scaled_count := progression_config.get_scaled_enemy_count(
			maxi(entry.count, 0),
			_get_progression_player_count()
		)
		for _enemy_index in range(scaled_count):
			var resolved_enemy_config := _resolve_fate_enemy_config(
				entry.enemy_config
			)
			pending_enemy_configs.append(resolved_enemy_config)
			pending_enemy_xirang_kill_rewards.append(
				entry.resolve_xirang_kill_reward(resolved_enemy_config)
			)

	for source_index in range(pending_enemy_configs.size() - 1, 0, -1):
		var target_index := random_generator.randi_range(0, source_index)
		var temporary_config := pending_enemy_configs[source_index]
		pending_enemy_configs[source_index] = pending_enemy_configs[target_index]
		pending_enemy_configs[target_index] = temporary_config
		var temporary_reward := pending_enemy_xirang_kill_rewards[source_index]
		pending_enemy_xirang_kill_rewards[source_index] = (
			pending_enemy_xirang_kill_rewards[target_index]
		)
		pending_enemy_xirang_kill_rewards[target_index] = temporary_reward


func _get_progression_player_count() -> int:
	if runtime_mode == RuntimeMode.SINGLEPLAYER:
		return 1
	return maxi(peer_players.size(), 1)


func _resolve_wave_spawn_points(wave_config: WaveConfig) -> bool:
	active_wave_spawn_points.clear()
	var resolution := _inspect_wave_spawn_points(wave_config)
	if not bool(resolution.get("valid", false)):
		var error_message := str(resolution.get("error", ""))
		if not error_message.is_empty():
			push_error(error_message)
		return false
	active_wave_spawn_points.assign(resolution.get("points", []))
	return not active_wave_spawn_points.is_empty()


func _inspect_wave_spawn_points(wave_config: WaveConfig) -> Dictionary:
	var points: Array[Marker2D] = []
	if wave_config == null or not spawn_point_configuration_valid:
		return {"valid": false, "points": points, "error": ""}
	var enabled_names := wave_config.get_enabled_spawn_point_names()
	if enabled_names.is_empty():
		return {
			"valid": false,
			"points": points,
			"error": "波次 %s 没有启用任何出生点。" % wave_config.get_flow_display_name(),
		}
	for spawn_name in enabled_names:
		var marker := enemy_spawn_points_by_name.get(spawn_name) as Marker2D
		if marker == null:
			return {
				"valid": false,
				"points": points,
				"error": (
					"波次 %s 引用了场景中不存在的出生点 %s。"
					% [wave_config.get_flow_display_name(), String(spawn_name)]
				),
			}
		points.append(marker)
	return {"valid": true, "points": points, "error": ""}


func _on_state_timer_timeout() -> void:
	if runtime_mode == RuntimeMode.CLIENT_VIEW:
		_update_client_flow_countdown()
		return
	if wave_state != WaveState.PRE_WAVE and wave_state != WaveState.INTERMISSION:
		state_timer.stop()
		return

	countdown_seconds = maxi(countdown_seconds - 1, 0)
	if countdown_seconds > 0:
		wave_hud.show_countdown(
			countdown_seconds,
			_can_local_player_start_wave_early()
		)
		if countdown_seconds <= COUNTDOWN_FINAL_SECONDS:
			_play_countdown_tick()
		return

	state_timer.stop()
	if wave_state == WaveState.PRE_WAVE:
		_begin_flow_step(current_flow_step)
	else:
		_begin_flow_step(next_flow_step_after_rest)


func _on_enemy_spawn_timer_timeout() -> void:
	_spawn_wave_batch()


func _start_client_flow_countdown(state: WaveState, step_id: StringName, seconds: int) -> void:
	wave_state = state
	var flow_step := _get_flow_step_by_id(step_id)
	if flow_step != null:
		current_flow_step = flow_step
		if flow_step is WaveConfig:
			current_wave_index = _get_wave_number_for_step(flow_step as WaveConfig) - 1
	if state == WaveState.PRE_WAVE or state == WaveState.INTERMISSION:
		_set_local_merchants_active(true)
		_update_post_wave_music(flow_step)
	countdown_seconds = maxi(seconds, 0)
	wave_hud.show_countdown(
		countdown_seconds,
		_can_local_player_start_wave_early()
	)
	if countdown_seconds <= 0:
		state_timer.stop()
		return
	state_timer.start(1.0)


func _update_client_flow_countdown() -> void:
	if wave_state != WaveState.PRE_WAVE and wave_state != WaveState.INTERMISSION:
		state_timer.stop()
		return
	countdown_seconds = maxi(countdown_seconds - 1, 0)
	wave_hud.show_countdown(
		countdown_seconds,
		_can_local_player_start_wave_early()
	)
	if countdown_seconds <= 0:
		state_timer.stop()
		return
	if countdown_seconds <= COUNTDOWN_FINAL_SECONDS:
		_play_countdown_tick()


func _spawn_wave_batch() -> void:
	if wave_state != WaveState.WAVE_ACTIVE:
		enemy_spawn_timer.stop()
		return

	var wave_config := _get_current_wave()
	if wave_config == null:
		enemy_spawn_timer.stop()
		return

	var spawn_count_this_tick := mini(
		maxi(wave_config.spawn_count_per_tick, 1),
		MAX_WAVE_SPAWN_COUNT_PER_TICK
	)
	for _spawn_index in range(spawn_count_this_tick):
		if not _has_pending_enemy_configs():
			break
		if active_wave_enemy_ids.size() >= maxi(wave_config.max_alive_enemies, 1):
			break

		var enemy_config := pending_enemy_configs[pending_enemy_config_index]
		var xirang_kill_reward := pending_enemy_xirang_kill_rewards[
			pending_enemy_config_index
		]
		if not _try_spawn_enemy(enemy_config, xirang_kill_reward):
			break

		pending_enemy_config_index += 1
		current_wave_spawned += 1

	if not _has_pending_enemy_configs():
		enemy_spawn_timer.stop()
		_clear_pending_enemy_spawn_queue()

	_check_wave_completion()


func _has_pending_enemy_configs() -> bool:
	return pending_enemy_config_index < pending_enemy_configs.size()


func _clear_pending_enemy_spawn_queue() -> void:
	pending_enemy_configs.clear()
	pending_enemy_xirang_kill_rewards.clear()
	pending_enemy_config_index = 0


func _try_spawn_enemy(
	enemy_config: EnemyConfig,
	xirang_kill_reward_override: int = -1
) -> bool:
	if not _is_spawn_system_ready() or enemy_config == null:
		return false

	var spawn_point := _pick_spawn_point()
	if spawn_point == null:
		return false

	var spawn_scene := enemy_config.enemy_scene
	if spawn_scene == null:
		push_warning("敌人配置 %s 缺少 enemy_scene。" % enemy_config.resource_path)
		return false
	var enemy_instance := spawn_scene.instantiate() as Enemy
	if enemy_instance == null:
		push_warning("敌人场景实例化失败，请检查波次中的敌人配置。")
		return false

	enemy_container.add_child(enemy_instance)
	enemy_instance.global_position = spawn_point.global_position
	enemy_instance.setup(enemy_config, _pick_enemy_target(spawn_point.global_position), grid_pathfinder)
	enemy_instance.set_xirang_kill_reward_override(xirang_kill_reward_override)
	_assign_enemy_targets(enemy_instance, spawn_point.global_position)
	var enemy_id := enemy_instance.get_instance_id()
	active_wave_enemy_ids[enemy_id] = true
	enemy_instance.defeated.connect(_on_wave_enemy_defeated)
	enemy_instance.tree_exited.connect(_on_wave_enemy_tree_exited.bind(enemy_id))
	_finalize_authoritative_enemy_spawn(enemy_instance, enemy_config, enemy_instance.global_position)
	_spawn_enemy_spawn_effect(spawn_point.global_position)
	return true


func spawn_linglan_skill2_enemies(
	enemy_config: EnemyConfig,
	marker_names: Array[StringName]
) -> void:
	if runtime_mode == RuntimeMode.CLIENT_VIEW:
		return
	if enemy_config == null:
		return
	for marker_name in marker_names:
		_try_spawn_boss_add_at_marker(enemy_config, marker_name)


func spawn_linglan_random_slime(spawn_position: Vector2) -> void:
	if runtime_mode == RuntimeMode.CLIENT_VIEW or wave_state != WaveState.BOSS_ACTIVE:
		return
	if not spawn_position.is_finite():
		return
	_cache_linglan_slime_configs()
	if linglan_slime_configs.is_empty():
		return
	var slime_config := linglan_slime_configs[
		random_generator.randi_range(0, linglan_slime_configs.size() - 1)
	]
	_try_spawn_boss_add_at_position(slime_config, spawn_position)


func spawn_linglan_airdrop_sniper(
	enemy_config: EnemyConfig,
	warning_scene: PackedScene,
	warning_duration: float,
	drop_height: float,
	drop_duration: float
) -> void:
	if runtime_mode == RuntimeMode.CLIENT_VIEW:
		return
	if wave_state != WaveState.BOSS_ACTIVE:
		return
	if enemy_config == null or enemy_config.enemy_scene == null:
		return
	var landing_position := _get_random_linglan_boss_arena_position()
	if runtime_mode == RuntimeMode.HOST_AUTHORITY:
		multiplayer_linglan_airdrop_started.emit(
			enemy_config,
			landing_position,
			warning_duration,
			drop_height,
			drop_duration
		)
	_spawn_linglan_airdrop_warning(warning_scene, landing_position, warning_duration)
	_finish_linglan_airdrop_sniper_spawn(
		enemy_config,
		landing_position,
		maxf(warning_duration, 0.0),
		maxf(drop_height, 0.0),
		maxf(drop_duration, 0.01)
	)


func _spawn_linglan_airdrop_warning(
	warning_scene: PackedScene,
	landing_position: Vector2,
	warning_duration: float
) -> void:
	if warning_scene == null:
		return
	var warning := warning_scene.instantiate() as Node2D
	if warning == null:
		return
	add_child(warning)
	warning.top_level = true
	warning.global_position = landing_position
	if warning.has_method("start"):
		warning.call("start", warning_duration)


func _finish_linglan_airdrop_sniper_spawn(
	enemy_config: EnemyConfig,
	landing_position: Vector2,
	warning_duration: float,
	drop_height: float,
	drop_duration: float
) -> void:
	if warning_duration > 0.0:
		await get_tree().create_timer(warning_duration).timeout
	if wave_state != WaveState.BOSS_ACTIVE:
		return
	if enemy_container == null or player == null:
		return

	var spawn_scene := enemy_config.enemy_scene
	var enemy_instance := spawn_scene.instantiate() as Enemy
	if enemy_instance == null:
		push_warning("Linglan 空降狙击手场景实例化失败。")
		return

	enemy_container.add_child(enemy_instance)
	enemy_instance.global_position = landing_position + Vector2(0.0, -drop_height)
	enemy_instance.setup(enemy_config, _pick_enemy_target(landing_position), grid_pathfinder)
	_assign_enemy_targets(enemy_instance, landing_position)
	enemy_instance.velocity = Vector2.ZERO
	enemy_instance.set_process(false)
	enemy_instance.set_physics_process(false)
	_set_enemy_collision_shapes_disabled_recursive(enemy_instance, true)

	var tween := enemy_instance.create_tween()
	tween.set_trans(Tween.TRANS_CUBIC)
	tween.set_ease(Tween.EASE_IN)
	tween.tween_property(enemy_instance, "global_position", landing_position, drop_duration)
	await tween.finished

	if not is_instance_valid(enemy_instance):
		return
	if wave_state != WaveState.BOSS_ACTIVE:
		enemy_instance.queue_free()
		return

	enemy_instance.global_position = landing_position
	enemy_instance.set_process(true)
	enemy_instance.set_physics_process(true)
	_set_enemy_collision_shapes_disabled_recursive(enemy_instance, false)
	var enemy_id := enemy_instance.get_instance_id()
	active_wave_enemy_ids[enemy_id] = true
	if not enemy_instance.defeated.is_connected(_on_boss_add_defeated):
		enemy_instance.defeated.connect(_on_boss_add_defeated)
	if not enemy_instance.tree_exited.is_connected(_on_boss_enemy_tree_exited.bind(enemy_id)):
		enemy_instance.tree_exited.connect(_on_boss_enemy_tree_exited.bind(enemy_id))
	_finalize_authoritative_enemy_spawn(enemy_instance, enemy_config, landing_position)
	_spawn_enemy_spawn_effect(landing_position)


func _set_enemy_collision_shapes_disabled_recursive(root: Node, disabled: bool) -> void:
	if root == null:
		return
	for child in root.get_children():
		var shape := child as CollisionShape2D
		if shape != null:
			shape.set_deferred("disabled", disabled)
		_set_enemy_collision_shapes_disabled_recursive(child, disabled)


func _get_random_linglan_boss_arena_position() -> Vector2:
	var front_center := (
		linglan_boss.global_position
		if linglan_boss != null and is_instance_valid(linglan_boss)
		else _get_linglan_spawn_global_position(active_boss_config)
	)
	var tower_pathfinder := grid_pathfinder as GridPathfinder
	for _attempt in range(8):
		var candidate := front_center + Vector2(
			random_generator.randf_range(
				-LINGLAN_AIRDROP_NEARBY_RADIUS.x,
				LINGLAN_AIRDROP_NEARBY_RADIUS.x
			),
			random_generator.randf_range(
				-LINGLAN_AIRDROP_NEARBY_RADIUS.y,
				LINGLAN_AIRDROP_NEARBY_RADIUS.y
			)
		)
		candidate = _clamp_spectator_camera_position(candidate).round()
		if (
			tower_pathfinder == null
			or not tower_pathfinder.is_built
			or tower_pathfinder.is_navigation_segment_walkable(front_center, candidate)
		):
			return candidate
	return front_center.round()


func _try_spawn_boss_add_at_marker(enemy_config: EnemyConfig, marker_name: StringName) -> bool:
	if enemy_config == null:
		return false
	if enemy_container == null or player == null:
		return false
	var spawn_marker := _get_enemy_spawn_marker(marker_name)
	if spawn_marker == null:
		return false
	return _try_spawn_boss_add_at_position(enemy_config, spawn_marker.global_position)


func _try_spawn_boss_add_at_position(
	enemy_config: EnemyConfig,
	spawn_position: Vector2
) -> bool:
	if enemy_config == null:
		return false
	if enemy_container == null or player == null:
		return false

	var spawn_scene := enemy_config.enemy_scene
	if spawn_scene == null:
		push_warning("Boss 召唤敌人配置 %s 缺少 enemy_scene。" % enemy_config.resource_path)
		return false
	var enemy_instance := spawn_scene.instantiate() as Enemy
	if enemy_instance == null:
		push_warning("Boss 召唤敌人场景实例化失败。")
		return false

	enemy_container.add_child(enemy_instance)
	enemy_instance.global_position = spawn_position
	enemy_instance.setup(enemy_config, _pick_enemy_target(spawn_position), grid_pathfinder)
	_assign_enemy_targets(enemy_instance, spawn_position)
	var enemy_id := enemy_instance.get_instance_id()
	active_wave_enemy_ids[enemy_id] = true
	if not enemy_instance.defeated.is_connected(_on_boss_add_defeated):
		enemy_instance.defeated.connect(_on_boss_add_defeated)
	if not enemy_instance.tree_exited.is_connected(_on_boss_enemy_tree_exited.bind(enemy_id)):
		enemy_instance.tree_exited.connect(_on_boss_enemy_tree_exited.bind(enemy_id))
	_finalize_authoritative_enemy_spawn(enemy_instance, enemy_config, enemy_instance.global_position)
	_spawn_enemy_spawn_effect(spawn_position)
	return true


func _finalize_authoritative_enemy_spawn(
	enemy_instance: Enemy,
	enemy_config: EnemyConfig,
	spawn_position: Vector2,
	broadcast_spawn: bool = true
) -> int:
	configure_runtime_enemy_modifiers(enemy_instance)
	_configure_authoritative_enemy_physics_interpolation(enemy_instance)
	var enemy_net_id := _register_multiplayer_enemy_instance(
		enemy_instance,
		enemy_config,
		spawn_position,
		broadcast_spawn
	)
	_register_hud_alive_enemy(enemy_instance)
	return enemy_net_id


func configure_runtime_enemy_modifiers(enemy_instance: Enemy) -> void:
	if fate_coordinator != null:
		fate_coordinator.configure_enemy_modifiers(enemy_instance)


func _register_multiplayer_enemy_instance(
	enemy_instance: Enemy,
	enemy_config: EnemyConfig,
	spawn_position: Vector2,
	broadcast_spawn: bool = true
) -> int:
	if runtime_mode != RuntimeMode.HOST_AUTHORITY:
		return 0
	if enemy_instance == null or enemy_config == null:
		return 0
	var enemy_id := enemy_instance.get_instance_id()
	var existing_net_id := int(multiplayer_enemy_ids_by_instance.get(enemy_id, 0))
	if existing_net_id > 0:
		return existing_net_id
	var enemy_net_id := next_multiplayer_enemy_net_id
	next_multiplayer_enemy_net_id += 1
	enemy_instance.set_meta("net_id", enemy_net_id)
	multiplayer_enemy_ids_by_instance[enemy_id] = enemy_net_id
	multiplayer_enemies_by_net_id[enemy_net_id] = enemy_instance
	register_combat_target(enemy_net_id, enemy_instance)
	if broadcast_spawn:
		multiplayer_enemy_spawned.emit(enemy_net_id, enemy_config, spawn_position)
	return enemy_net_id


func _configure_authoritative_enemy_physics_interpolation(enemy_instance: Enemy) -> void:
	if (
		runtime_mode == RuntimeMode.CLIENT_VIEW
		or enemy_instance == null
		or not is_instance_valid(enemy_instance)
	):
		return
	# The local player and its following camera render on Godot's interpolated
	# physics timeline. Authoritative enemies also move in _physics_process(), so
	# they must use the same timeline or they visibly step against the camera.
	# Client proxies stay out of this path because NetInterpolator already places
	# them on the render clock.
	enemy_instance.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_ON
	enemy_instance.reset_physics_interpolation()


func _on_wave_enemy_defeated(enemy: Enemy) -> void:
	if wave_state != WaveState.WAVE_ACTIVE:
		return
	if enemy == null or not active_wave_enemy_ids.has(enemy.get_instance_id()):
		return

	current_wave_defeated = mini(current_wave_defeated + 1, current_wave_total)
	current_wave_resolved = mini(current_wave_resolved + 1, current_wave_total)
	_remove_hud_alive_enemy(enemy.get_instance_id())
	_emit_multiplayer_enemy_defeated(enemy)
	_show_tower_defense_wave_progress()
	_check_wave_completion()


func _show_tower_defense_wave_progress() -> void:
	wave_hud.show_tower_defense_wave_progress(
		current_wave_index + 1,
		current_wave_defeated,
		current_wave_escaped,
		current_wave_resolved,
		current_wave_total
	)
	if runtime_mode == RuntimeMode.HOST_AUTHORITY:
		multiplayer_tower_defense_wave_progress_changed.emit(
			current_wave_index + 1,
			current_wave_defeated,
			current_wave_escaped,
			current_wave_resolved,
			current_wave_total
		)


func get_tower_defense_wave_progress_snapshot() -> Dictionary:
	return {
		"wave_number": current_wave_index + 1,
		"defeated": current_wave_defeated,
		"escaped": current_wave_escaped,
		"resolved": current_wave_resolved,
		"total": current_wave_total,
	}


func apply_remote_tower_defense_wave_progress(
	wave_number: int,
	defeated: int,
	escaped: int,
	resolved: int,
	total: int
) -> void:
	if runtime_mode != RuntimeMode.CLIENT_VIEW:
		return
	current_wave_index = maxi(wave_number - 1, 0)
	current_wave_total = maxi(total, 0)
	current_wave_defeated = clampi(defeated, 0, current_wave_total)
	current_wave_escaped = clampi(escaped, 0, current_wave_total)
	current_wave_resolved = clampi(resolved, 0, current_wave_total)
	_show_tower_defense_wave_progress()


func _emit_multiplayer_enemy_defeated(enemy: Enemy) -> void:
	if runtime_mode != RuntimeMode.HOST_AUTHORITY:
		return
	if enemy == null:
		return
	var enemy_net_id := int(multiplayer_enemy_ids_by_instance.get(enemy.get_instance_id(), 0))
	if enemy_net_id <= 0:
		return
	multiplayer_enemy_defeated.emit(enemy_net_id, enemy.global_position)


func _on_wave_enemy_tree_exited(enemy_id: int) -> void:
	active_wave_enemy_ids.erase(enemy_id)
	_remove_hud_alive_enemy(enemy_id)
	_mark_multiplayer_enemy_removed(enemy_id)
	_check_wave_completion()


func _mark_multiplayer_enemy_removed(enemy_id: int) -> void:
	if runtime_mode != RuntimeMode.HOST_AUTHORITY:
		return
	var enemy_net_id := int(multiplayer_enemy_ids_by_instance.get(enemy_id, 0))
	multiplayer_enemy_ids_by_instance.erase(enemy_id)
	if enemy_net_id > 0:
		multiplayer_enemies_by_net_id.erase(enemy_net_id)
		unregister_combat_target(enemy_net_id)
	if enemy_net_id <= 0:
		return
	# Escape owns the terminal event and leaves exactly one short-lived marker for
	# the ensuing tree exit. Consume it here; normal exits never become history.
	if pending_multiplayer_enemy_escape_ids.erase(enemy_net_id):
		return
	multiplayer_enemy_removed.emit(enemy_net_id)


func _check_wave_completion() -> void:
	if wave_state != WaveState.WAVE_ACTIVE:
		return
	if _has_pending_enemy_configs():
		return
	if current_wave_spawned < current_wave_total:
		return
	if current_wave_resolved < current_wave_total:
		return
	if not active_wave_enemy_ids.is_empty():
		return

	enemy_spawn_timer.stop()
	_complete_current_step()


func _complete_current_step() -> void:
	var next_step := _get_default_next_flow_step(current_flow_step)
	var completed_wave := current_flow_step as WaveConfig
	var completed_wave_number := (
		_get_wave_number_for_step(completed_wave)
		if completed_wave != null
		else 0
	)
	var completed_day := (
		completed_wave != null
		and day_cycle_config.is_day_end_wave(completed_wave_number)
	)
	if completed_day:
		_record_progression_day(_get_day_number_for_wave(completed_wave_number))
	if next_step == null:
		_enter_victory()
		return
	if completed_day:
		_enter_xiaocong_fate_interlude(next_step)
		return
	_enter_intermission(next_step)


func _record_progression_day(day_number: int) -> void:
	if runtime_mode == RuntimeMode.CLIENT_VIEW or day_number <= 0:
		return
	for record in progression_day_records:
		if int(record.get("day", 0)) == day_number:
			return
	var inventory_materials := _get_tracked_inventory_material_totals()
	var shared_materials := _get_tracked_shared_material_totals()
	var combined_materials := inventory_materials.duplicate()
	for config_path_variant in shared_materials:
		var config_path := String(config_path_variant)
		combined_materials[config_path] = (
			int(combined_materials.get(config_path, 0))
			+ int(shared_materials[config_path_variant])
		)
	progression_day_records.append({
		"day": day_number,
		"elapsed_seconds": _get_progression_elapsed_seconds(),
		"building_count": _get_active_progression_building_count(),
		"daily_xirang": int(daily_xirang_rewards.get(day_number, 0)),
		"inventory_materials": inventory_materials,
		"shared_storage_materials": shared_materials,
		"combined_materials": combined_materials,
	})


func _get_active_progression_building_count() -> int:
	var building_count := 0
	for plant_variant in get_tree().get_nodes_in_group(&"plant_defense"):
		var plant := plant_variant as PlantDefense
		if (
			plant != null
			and is_instance_valid(plant)
			and not plant.is_dead
			and not plant.is_removing
		):
			building_count += 1
	return building_count


func _get_tracked_inventory_material_totals() -> Dictionary:
	var totals := {}
	if progression_config == null or run_state == null:
		return totals
	for item in progression_config.tracked_materials:
		var total := 0
		if runtime_mode == RuntimeMode.SINGLEPLAYER:
			total = run_state.get_inventory_item_total(item)
		else:
			for peer_id_variant in peer_players:
				total += run_state.get_inventory_item_total_for_peer(
					int(peer_id_variant),
					item
				)
		totals[item.resource_path] = total
	return totals


func _get_tracked_shared_material_totals() -> Dictionary:
	var totals := {}
	if progression_config == null or production_coordinator == null:
		return totals
	for item in progression_config.tracked_materials:
		totals[item.resource_path] = production_coordinator.get_total_item_count(item)
	return totals


func get_progression_metrics_snapshot() -> Dictionary:
	var first_day_building_count := -1
	for record in progression_day_records:
		if int(record.get("day", 0)) == 1:
			first_day_building_count = int(record.get("building_count", -1))
			break
	return {
		"first_defense_tower_seconds": first_defense_tower_seconds,
		"water_chain_online_seconds": water_chain_online_seconds,
		"first_day_building_count": first_day_building_count,
		"daily_xirang_rewards": daily_xirang_rewards.duplicate(true),
		"day_records": progression_day_records.duplicate(true),
	}


func _enter_victory(emit_multiplayer: bool = true) -> void:
	if luoxi_special_game_coordinator != null:
		luoxi_special_game_coordinator.cancel_all()
	if luoxi_merchant != null:
		luoxi_merchant.abort_special_game()
	_cancel_plant_placement()
	if defeat_camera_tween != null:
		defeat_camera_tween.kill()
		defeat_camera_tween = null
	_restore_camera_after_boss_intro()
	wave_state = WaveState.VICTORY
	transition_world_to_day()
	_force_revive_dead_players(emit_multiplayer)
	_clear_respawn_runtime_for_result()
	if tower_defense_status_hud != null:
		tower_defense_status_hud.stop_gate_damage_warning()
	enemy_spawn_timer.stop()
	state_timer.stop()
	_set_merchant_active(false)
	if linglan_boss_intro_vfx != null:
		linglan_boss_intro_vfx.stop_intro()
	if boss_health_hud != null:
		boss_health_hud.hide_all()
	wave_hud.show_victory()
	if emit_multiplayer and runtime_mode == RuntimeMode.HOST_AUTHORITY:
		multiplayer_victory_started.emit()
		_emit_multiplayer_flow_state(WaveState.VICTORY)


func _enter_defeat(emit_multiplayer: bool = true) -> void:
	if wave_state == WaveState.DEFEAT:
		return
	if luoxi_special_game_coordinator != null:
		luoxi_special_game_coordinator.cancel_all()
	if luoxi_merchant != null:
		luoxi_merchant.abort_special_game()
	_cancel_plant_placement()
	wave_state = WaveState.DEFEAT
	transition_world_to_day()
	defeat_presentation_completed = false
	_clear_respawn_runtime_for_result()
	enemy_spawn_timer.stop()
	state_timer.stop()
	_set_merchant_active(false)
	_stop_background_music_for_defeat()
	if linglan_boss_intro_vfx != null:
		linglan_boss_intro_vfx.stop_intro()
	if boss_health_hud != null:
		boss_health_hud.hide_all()
	wave_hud.hide_all()
	if emit_multiplayer and runtime_mode == RuntimeMode.HOST_AUTHORITY:
		multiplayer_defeat_started.emit()
	_begin_defeat_camera_sequence()


func _begin_defeat_camera_sequence() -> void:
	if boss_intro_camera_tween != null:
		boss_intro_camera_tween.kill()
		boss_intro_camera_tween = null
	if defeat_camera_tween != null:
		defeat_camera_tween.kill()
		defeat_camera_tween = null
	if map_camera == null or home_objective_targets.is_empty():
		_complete_defeat_presentation()
		return

	# Keep the player's current zoom while detaching the camera from either a
	# living player or spectator mode. The unique blue-gate objective is the
	# authoritative destination on every peer.
	spectator_camera_active = false
	if map_camera.get_parent() != self:
		map_camera.reparent(self, true)
	map_camera.process_callback = Camera2D.CAMERA2D_PROCESS_IDLE
	map_camera.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	map_camera.reset_physics_interpolation()
	var gate_center := home_objective_targets[0].global_position.round()
	if map_camera.global_position.is_equal_approx(gate_center) or not is_inside_tree():
		map_camera.global_position = gate_center
		_complete_defeat_presentation()
		return

	defeat_camera_tween = create_tween()
	defeat_camera_tween.set_trans(Tween.TRANS_SINE)
	defeat_camera_tween.set_ease(Tween.EASE_IN_OUT)
	defeat_camera_tween.tween_method(
		_set_map_camera_rounded_global_position,
		map_camera.global_position,
		gate_center,
		DEFEAT_CAMERA_TRAVEL_SECONDS
	)
	defeat_camera_tween.tween_callback(_complete_defeat_presentation)


func _set_map_camera_rounded_global_position(camera_position: Vector2) -> void:
	if map_camera != null:
		map_camera.global_position = camera_position.round()


func _complete_defeat_presentation() -> void:
	defeat_camera_tween = null
	if wave_state != WaveState.DEFEAT or defeat_presentation_completed:
		return
	defeat_presentation_completed = true
	wave_hud.show_tower_defense_defeat()
	defeat_audio.play()


func _clear_respawn_runtime_for_result() -> void:
	singleplayer_respawn_time_left = -1.0
	singleplayer_respawn_last_seconds = -1
	spectator_camera_active = false
	if tower_defense_status_hud != null:
		tower_defense_status_hud.clear_all_respawns()


func _begin_linglan_boss_intro(boss_config: BossConfig = null) -> void:
	if not linglan_boss_enabled:
		_enter_victory()
		return
	if boss_config == null:
		boss_config = current_flow_step as BossConfig
	if boss_config == null:
		_enter_victory()
		return
	if not _ensure_linglan_boss_runtime_nodes(boss_config):
		_enter_victory()
		return
	active_boss_config = boss_config
	_reset_player_wave_death_counts()
	linglan_boss_started = true
	current_flow_step = boss_config
	wave_state = WaveState.BOSS_INTRO
	enemy_spawn_timer.stop()
	state_timer.stop()
	_clear_pending_enemy_spawn_queue()
	active_wave_enemy_ids.clear()
	current_wave_total = 1
	current_wave_spawned = 1
	current_wave_defeated = 0
	current_wave_escaped = 0
	current_wave_resolved = 0
	resolved_home_enemy_ids.clear()
	_clear_hud_alive_enemies()
	_set_merchant_active(false)
	wave_hud.show_tower_defense_boss_progress(0, 1)
	_update_boss_music(boss_config)
	_prepare_linglan_boss_arena(boss_config)
	var boss_spawn_position := _get_linglan_spawn_global_position(boss_config)
	linglan_skill4_orb_anchor_valid = false
	linglan_boss.config = _get_boss_enemy_config(boss_config)
	linglan_boss.global_position = boss_spawn_position
	linglan_boss.set_active(false)
	_focus_camera_on_boss_intro(boss_spawn_position)
	if boss_health_hud != null:
		boss_health_hud.hide_all()
	_emit_multiplayer_flow_state(WaveState.BOSS_INTRO)
	if linglan_boss_intro_vfx != null:
		linglan_boss_intro_vfx.play_intro(boss_spawn_position)
	else:
		_on_linglan_boss_intro_finished()


func _on_linglan_boss_intro_finished() -> void:
	if wave_state != WaveState.BOSS_INTRO:
		return
	_restore_camera_after_boss_intro()
	_activate_linglan_boss()


func _activate_linglan_boss() -> void:
	if linglan_boss == null or not is_instance_valid(linglan_boss):
		if not _ensure_linglan_boss_runtime_nodes(active_boss_config):
			_enter_victory()
			return
	var boss_config := active_boss_config
	if not _boss_config_has_required_data(boss_config):
		_enter_victory()
		return
	wave_state = WaveState.BOSS_ACTIVE
	linglan_boss.config = _get_boss_enemy_config(boss_config)
	linglan_boss.global_position = _get_linglan_spawn_global_position(boss_config)
	linglan_boss.activate_boss(player, grid_pathfinder)
	if not linglan_boss.is_advancing_to_home():
		_assign_enemy_targets(linglan_boss, linglan_boss.global_position)
	var boss_instance_id := linglan_boss.get_instance_id()
	active_wave_enemy_ids[boss_instance_id] = true
	if not linglan_boss.tree_exited.is_connected(_on_boss_enemy_tree_exited.bind(boss_instance_id)):
		linglan_boss.tree_exited.connect(_on_boss_enemy_tree_exited.bind(boss_instance_id))
	var boss_net_id := _finalize_authoritative_enemy_spawn(
		linglan_boss,
		_get_boss_enemy_config(boss_config),
		linglan_boss.global_position,
		false
	)
	wave_hud.show_tower_defense_boss_progress(0, 1)
	if boss_health_hud != null:
		boss_health_hud.show_for_boss(linglan_boss, _get_boss_display_name(boss_config))
	_emit_multiplayer_flow_state(WaveState.BOSS_ACTIVE)
	if runtime_mode == RuntimeMode.HOST_AUTHORITY:
		multiplayer_boss_started.emit(boss_net_id, boss_config, linglan_boss.global_position)
		_rebroadcast_linglan_boss_started_after_sync_window(boss_net_id, boss_config)


func _on_boss_enemy_tree_exited(enemy_id: int) -> void:
	active_wave_enemy_ids.erase(enemy_id)
	_remove_hud_alive_enemy(enemy_id)
	_mark_multiplayer_enemy_removed(enemy_id)


func _on_boss_add_defeated(enemy: Enemy) -> void:
	if enemy != null:
		_remove_hud_alive_enemy(enemy.get_instance_id())
	_emit_multiplayer_enemy_defeated(enemy)


func _rebroadcast_linglan_boss_started_after_sync_window(
	boss_net_id: int,
	boss_config: BossConfig
) -> void:
	if boss_net_id <= 0 or boss_config == null:
		return
	await get_tree().create_timer(0.75).timeout
	if runtime_mode != RuntimeMode.HOST_AUTHORITY:
		return
	if wave_state != WaveState.BOSS_ACTIVE:
		return
	if linglan_boss == null or not is_instance_valid(linglan_boss):
		return
	multiplayer_boss_started.emit(boss_net_id, boss_config, linglan_boss.global_position)


func _on_linglan_boss_defeated(enemy: Enemy) -> void:
	if wave_state != WaveState.BOSS_ACTIVE:
		return
	if enemy != linglan_boss:
		return
	active_wave_enemy_ids.erase(enemy.get_instance_id())
	_remove_hud_alive_enemy(enemy.get_instance_id())
	current_wave_defeated = 1
	current_wave_resolved = 1
	wave_hud.show_tower_defense_boss_progress(1, 1)
	_emit_multiplayer_enemy_defeated(enemy)
	_remove_remaining_boss_adds()
	var victory_timer := get_tree().create_timer(1.3)
	victory_timer.timeout.connect(_complete_linglan_boss_after_delay)


func _complete_linglan_boss_after_delay() -> void:
	if wave_state != WaveState.BOSS_ACTIVE:
		return
	_remove_remaining_boss_adds()
	_complete_current_step()


func _remove_remaining_boss_adds() -> void:
	if enemy_container == null:
		active_wave_enemy_ids.clear()
		_clear_hud_alive_enemies()
		return
	for child in enemy_container.get_children():
		var enemy := child as Enemy
		if enemy == null or not is_instance_valid(enemy):
			continue
		if active_wave_enemy_ids.has(enemy.get_instance_id()):
			enemy.queue_free()
	active_wave_enemy_ids.clear()
	_clear_hud_alive_enemies()


func _prepare_linglan_boss_arena(_boss_config: Resource) -> void:
	# Tower defense keeps its authored terrain, gates and player-built front line.
	# The shared Linglan BossConfig still describes the compact standard arena;
	# applying it here would overwrite the tower-defense map's upper-left corner.
	return


func _on_player_died() -> void:
	cancel_luoxi_special_game_for_peer(0)
	_request_enemy_retarget_after_objective_change()
	_cancel_plant_placement()
	_update_plant_placement_input_state()
	player.apply_tower_defense_death_presentation()
	if wave_state == WaveState.VICTORY or wave_state == WaveState.DEFEAT:
		return
	_begin_local_spectator_camera()
	var respawn_delay := consume_next_player_respawn_delay(0)
	singleplayer_respawn_time_left = respawn_delay
	singleplayer_respawn_last_seconds = ceili(respawn_delay)
	update_player_respawn_countdown(0, singleplayer_respawn_last_seconds)


func _on_multiplayer_player_died(peer_id: int) -> void:
	cancel_luoxi_special_game_for_peer(peer_id)
	_request_enemy_retarget_after_objective_change()
	var dead_player := get_player_for_peer(peer_id)
	if dead_player != null and is_instance_valid(dead_player):
		dead_player.apply_tower_defense_death_presentation()
	if wave_state == WaveState.VICTORY or wave_state == WaveState.DEFEAT:
		return
	if peer_id == multiplayer_local_peer_id:
		_begin_local_spectator_camera()


func _on_player_revived(peer_id: int) -> void:
	_request_enemy_retarget_after_objective_change()
	clear_player_respawn_countdown(peer_id)
	if (
		(runtime_mode == RuntimeMode.SINGLEPLAYER and peer_id == 0)
		or peer_id == multiplayer_local_peer_id
	):
		_end_local_spectator_camera()
	_update_plant_placement_input_state()


func consume_next_player_respawn_delay(peer_id: int) -> float:
	var death_count := int(player_wave_death_counts.get(peer_id, 0))
	var delay_index := mini(death_count, PLAYER_RESPAWN_DELAYS.size() - 1)
	player_wave_death_counts[peer_id] = death_count + 1
	return float(PLAYER_RESPAWN_DELAYS[delay_index])


func update_player_respawn_countdown(peer_id: int, seconds_left: int) -> void:
	if tower_defense_status_hud == null:
		return
	var is_local := (
		(runtime_mode == RuntimeMode.SINGLEPLAYER and peer_id == 0)
		or peer_id == multiplayer_local_peer_id
	)
	var display_name := "玩家"
	if runtime_mode != RuntimeMode.SINGLEPLAYER:
		display_name = str(multiplayer_player_names.get(peer_id, "玩家 %d" % peer_id))
	tower_defense_status_hud.set_player_respawn(
		peer_id,
		display_name,
		seconds_left,
		is_local
	)


func clear_player_respawn_countdown(peer_id: int) -> void:
	if tower_defense_status_hud != null:
		tower_defense_status_hud.clear_player_respawn(peer_id)


func _reset_player_wave_death_counts() -> void:
	player_wave_death_counts.clear()


func _force_revive_dead_players(emit_multiplayer: bool = true) -> void:
	match runtime_mode:
		RuntimeMode.SINGLEPLAYER:
			singleplayer_respawn_time_left = -1.0
			singleplayer_respawn_last_seconds = -1
			clear_player_respawn_countdown(0)
			if player == null or not is_instance_valid(player) or not player.is_dead:
				return
			player.revive_multiplayer(
				player_spawn.global_position,
				player.max_health,
				PLAYER_RESPAWN_INVINCIBILITY_SECONDS
			)
		RuntimeMode.HOST_AUTHORITY:
			if not emit_multiplayer:
				return
			for player_variant in peer_players.values():
				var player_instance := player_variant as Player
				if (
					player_instance != null
					and is_instance_valid(player_instance)
					and player_instance.is_dead
				):
					multiplayer_revive_all_requested.emit()
					return
		RuntimeMode.CLIENT_VIEW:
			return


func _update_singleplayer_respawn(delta: float) -> void:
	if runtime_mode != RuntimeMode.SINGLEPLAYER or singleplayer_respawn_time_left < 0.0:
		return
	if player == null or not player.is_dead:
		singleplayer_respawn_time_left = -1.0
		singleplayer_respawn_last_seconds = -1
		return
	singleplayer_respawn_time_left = maxf(singleplayer_respawn_time_left - delta, 0.0)
	var seconds_left := ceili(singleplayer_respawn_time_left)
	if seconds_left != singleplayer_respawn_last_seconds:
		singleplayer_respawn_last_seconds = seconds_left
		update_player_respawn_countdown(0, seconds_left)
	if singleplayer_respawn_time_left > 0.0:
		return
	singleplayer_respawn_time_left = -1.0
	singleplayer_respawn_last_seconds = -1
	player.revive_multiplayer(
		player_spawn.global_position,
		player.max_health,
		PLAYER_RESPAWN_INVINCIBILITY_SECONDS
	)


func _begin_local_spectator_camera() -> void:
	if spectator_camera_active or map_camera == null or player == null:
		return
	if map_camera.get_parent() != self:
		map_camera.reparent(self, true)
	map_camera.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	map_camera.reset_physics_interpolation()
	spectator_camera_active = true


func _end_local_spectator_camera() -> void:
	if not spectator_camera_active:
		return
	spectator_camera_active = false
	_attach_camera_to_local_player()


func _update_local_spectator_camera(delta: float) -> void:
	if not spectator_camera_active or map_camera == null:
		return
	if _has_exclusive_modal_open():
		return
	var move_input := Input.get_vector(
		&"move_left",
		&"move_right",
		&"move_up",
		&"move_down"
	)
	if move_input == Vector2.ZERO:
		return
	map_camera.global_position += move_input * SPECTATOR_CAMERA_SPEED * delta
	map_camera.global_position = _clamp_spectator_camera_position(map_camera.global_position)


func _clamp_spectator_camera_position(camera_position: Vector2) -> Vector2:
	if ground_tile_map_layer == null or ground_tile_map_layer.tile_set == null:
		return camera_position
	var used_rect := ground_tile_map_layer.get_used_rect()
	if used_rect.size.x <= 0 or used_rect.size.y <= 0:
		return camera_position
	var top_left := ground_tile_map_layer.to_global(
		ground_tile_map_layer.map_to_local(used_rect.position)
	)
	var bottom_right_cell := used_rect.end - Vector2i.ONE
	var bottom_right := ground_tile_map_layer.to_global(
		ground_tile_map_layer.map_to_local(bottom_right_cell)
	)
	return Vector2(
		clampf(camera_position.x, minf(top_left.x, bottom_right.x), maxf(top_left.x, bottom_right.x)),
		clampf(camera_position.y, minf(top_left.y, bottom_right.y), maxf(top_left.y, bottom_right.y))
	)


func _configure_multiplayer_players() -> void:
	player = null
	peer_players.clear()
	multiplayer_spawn_slot_indices.clear()
	if multiplayer_player_names.is_empty():
		multiplayer_player_names[multiplayer_local_peer_id if multiplayer_local_peer_id > 0 else 1] = "Player"

	var peer_ids: Array[int] = []
	for peer_id_variant in multiplayer_player_names:
		peer_ids.append(int(peer_id_variant))
	peer_ids.sort()

	for index in range(peer_ids.size()):
		var peer_id := peer_ids[index]
		multiplayer_spawn_slot_indices[peer_id] = index
		var character_id := _get_multiplayer_character_id(peer_id)
		var player_instance := _instantiate_player_character(character_id)
		if player_instance == null:
			continue
		player_instance.name = "Player_%d" % peer_id
		player_instance.position = player_spawn.position + _get_multiplayer_spawn_offset(index)
		add_child(player_instance)
		var accepts_local_input := (
			peer_id == multiplayer_local_peer_id
			and (
				runtime_mode == RuntimeMode.HOST_AUTHORITY
				or runtime_mode == RuntimeMode.CLIENT_VIEW
			)
		)
		var predicts_local_movement := (
			runtime_mode == RuntimeMode.CLIENT_VIEW
			and peer_id == multiplayer_local_peer_id
		)
		var display_name: String = str(multiplayer_player_names.get(peer_id, "Player %d" % peer_id))
		player_instance.configure_multiplayer_control(
			peer_id,
			accepts_local_input,
			display_name,
			predicts_local_movement,
			peer_id == multiplayer_local_peer_id
		)
		player_instance.set_multiplayer_visual_smoothing_enabled(
			runtime_mode == RuntimeMode.HOST_AUTHORITY
			and peer_id != multiplayer_local_peer_id
		)
		player_instance.physics_interpolation_mode = (
			Node.PHYSICS_INTERPOLATION_MODE_ON
			if accepts_local_input or predicts_local_movement
			else Node.PHYSICS_INTERPOLATION_MODE_OFF
		)
		player_instance.reset_physics_interpolation()
		if (
			(runtime_mode == RuntimeMode.CLIENT_VIEW and not predicts_local_movement)
			or (runtime_mode == RuntimeMode.HOST_AUTHORITY and peer_id != multiplayer_local_peer_id)
		):
			player_instance.set_physics_process(false)
		if not player_instance.died.is_connected(_on_multiplayer_player_died.bind(peer_id)):
			player_instance.died.connect(_on_multiplayer_player_died.bind(peer_id))
		if not player_instance.revived.is_connected(_on_player_revived.bind(peer_id)):
			player_instance.revived.connect(_on_player_revived.bind(peer_id))
		peer_players[peer_id] = player_instance
		if research_coordinator != null:
			research_coordinator.register_player(player_instance)
		if peer_id == multiplayer_local_peer_id:
			player = player_instance
	if player == null and not peer_ids.is_empty():
		player = peer_players.get(peer_ids[0]) as Player


func _get_multiplayer_character_id(peer_id: int) -> StringName:
	var character_id := StringName(
		multiplayer_player_character_ids.get(peer_id, DEFAULT_PLAYER_CHARACTER_ID)
	)
	if not PlayerCharacterRegistry.is_valid_character_id(character_id):
		return DEFAULT_PLAYER_CHARACTER_ID
	return character_id


func _get_multiplayer_spawn_offset(index: int) -> Vector2:
	return MULTIPLAYER_SPAWN_OFFSETS[index % MULTIPLAYER_SPAWN_OFFSETS.size()]


func apply_network_input_for_peer(
	peer_id: int,
	move_input: Vector2,
	shoot_input: Vector2,
	use_skill1: bool,
	use_reload: bool = false
) -> void:
	var player_instance: Player = peer_players.get(peer_id) as Player
	if player_instance == null or not is_instance_valid(player_instance):
		return
	player_instance.apply_network_input(move_input, shoot_input, use_skill1, use_reload)


func _update_multiplayer_remote_player_passive_state(delta: float) -> void:
	for peer_id_variant in peer_players:
		var peer_id := int(peer_id_variant)
		if peer_id == multiplayer_local_peer_id:
			continue
		var player_instance := peer_players[peer_id] as Player
		if player_instance == null or not is_instance_valid(player_instance):
			continue
		player_instance.update_multiplayer_authority_passive_state(delta)


func remove_multiplayer_player(peer_id: int) -> void:
	if peer_id <= 0 or peer_id == multiplayer_local_peer_id:
		return
	cancel_luoxi_special_game_for_peer(peer_id)
	production_coordinator.deactivate_personal_output_peer(peer_id)
	var player_instance := peer_players.get(peer_id) as Player
	peer_players.erase(peer_id)
	_request_enemy_retarget_after_objective_change()
	multiplayer_spawn_slot_indices.erase(peer_id)
	multiplayer_player_names.erase(peer_id)
	multiplayer_player_character_ids.erase(peer_id)
	clear_player_respawn_countdown(peer_id)
	player_wave_death_counts.erase(peer_id)
	if player_instance != null and is_instance_valid(player_instance):
		player_instance.queue_free()
	_remove_fate_eligible_peer(peer_id)


func restore_multiplayer_player(
	old_peer_id: int,
	new_peer_id: int,
	player_name: String,
	character_id: StringName,
	state: SnapshotManager.PlayerState,
	spawn_slot_index: int,
	reconnect_state: Dictionary = {}
) -> Player:
	if (
		new_peer_id <= 0
		or peer_players.has(new_peer_id)
		or not PlayerCharacterRegistry.is_valid_character_id(character_id)
	):
		return null
	multiplayer_player_names.erase(old_peer_id)
	multiplayer_player_character_ids.erase(old_peer_id)
	multiplayer_spawn_slot_indices.erase(old_peer_id)
	multiplayer_player_names[new_peer_id] = player_name
	multiplayer_player_character_ids[new_peer_id] = character_id
	multiplayer_spawn_slot_indices[new_peer_id] = maxi(spawn_slot_index, 0)
	if luoxi_collectible_claim_counts.has(old_peer_id):
		luoxi_collectible_claim_counts[new_peer_id] = (
			luoxi_collectible_claim_counts[old_peer_id]
		)
		luoxi_collectible_claim_counts.erase(old_peer_id)
	var wave_death_count := int(reconnect_state.get("wave_death_count", 0))
	if wave_death_count > 0:
		player_wave_death_counts[new_peer_id] = wave_death_count
	var player_instance := _instantiate_player_character(character_id)
	if player_instance == null:
		return null
	player_instance.name = "Player_%d" % new_peer_id
	player_instance.position = (
		state.position
		if state != null
		else player_spawn.position + _get_multiplayer_spawn_offset(spawn_slot_index)
	)
	add_child(player_instance)
	var accepts_local_input := new_peer_id == multiplayer_local_peer_id
	var predicts_local_movement := (
		runtime_mode == RuntimeMode.CLIENT_VIEW
		and new_peer_id == multiplayer_local_peer_id
	)
	player_instance.configure_multiplayer_control(
		new_peer_id,
		accepts_local_input,
		player_name,
		predicts_local_movement,
		new_peer_id == multiplayer_local_peer_id
	)
	player_instance.set_multiplayer_visual_smoothing_enabled(
		runtime_mode == RuntimeMode.HOST_AUTHORITY
		and new_peer_id != multiplayer_local_peer_id
	)
	player_instance.physics_interpolation_mode = (
		Node.PHYSICS_INTERPOLATION_MODE_ON
		if accepts_local_input or predicts_local_movement
		else Node.PHYSICS_INTERPOLATION_MODE_OFF
	)
	player_instance.reset_physics_interpolation()
	if (
		(runtime_mode == RuntimeMode.CLIENT_VIEW and not predicts_local_movement)
		or (runtime_mode == RuntimeMode.HOST_AUTHORITY and new_peer_id != multiplayer_local_peer_id)
	):
		player_instance.set_physics_process(false)
	if not player_instance.died.is_connected(
		_on_multiplayer_player_died.bind(new_peer_id)
	):
		player_instance.died.connect(_on_multiplayer_player_died.bind(new_peer_id))
	if not player_instance.revived.is_connected(_on_player_revived.bind(new_peer_id)):
		player_instance.revived.connect(_on_player_revived.bind(new_peer_id))
	peer_players[new_peer_id] = player_instance
	if research_coordinator != null:
		if research_coordinator.player_technology_levels.has(old_peer_id):
			if not research_coordinator.remap_player_peer_state(
				old_peer_id,
				new_peer_id
			):
				push_error(
					"GameTowerDefense: 无法迁移重连玩家 %d -> %d 的个人科研状态。"
					% [old_peer_id, new_peer_id]
				)
		research_coordinator.register_player(player_instance)
	if production_coordinator != null:
		production_coordinator.activate_personal_output_peer(new_peer_id)
	if fate_coordinator != null:
		fate_coordinator.apply_player_modifiers_to_all()
	_request_enemy_retarget_after_objective_change()
	return player_instance


func get_player_for_peer(peer_id: int) -> Player:
	return peer_players.get(peer_id) as Player


func get_enemy_for_net_id(net_id: int) -> Enemy:
	if not multiplayer_enemies_by_net_id.has(net_id):
		return null
	var enemy_variant: Variant = multiplayer_enemies_by_net_id.get(net_id)
	if enemy_variant == null:
		multiplayer_enemies_by_net_id.erase(net_id)
		unregister_combat_target(net_id)
		return null
	if not is_instance_valid(enemy_variant):
		multiplayer_enemies_by_net_id.erase(net_id)
		unregister_combat_target(net_id)
		return null
	return enemy_variant as Enemy


func get_pickup_for_net_id(net_id: int) -> Pickup:
	if not multiplayer_pickups.has(net_id):
		return null
	var pickup_variant: Variant = multiplayer_pickups.get(net_id)
	if pickup_variant == null:
		multiplayer_pickups.erase(net_id)
		return null
	if not is_instance_valid(pickup_variant):
		multiplayer_pickups.erase(net_id)
		return null
	return pickup_variant as Pickup


func _register_static_multiplayer_pickups() -> void:
	multiplayer_pickups.clear()
	pending_multiplayer_pickup_exit_ids.clear()
	next_multiplayer_pickup_net_id = 1000
	var pickups: Array[Pickup] = []
	_collect_pickups_recursive(self, pickups)
	pickups.sort_custom(_sort_pickups_by_path)

	var next_pickup_id := 1
	for pickup in pickups:
		if pickup == null or not is_instance_valid(pickup):
			continue
		_register_multiplayer_pickup(pickup, next_pickup_id, false)
		next_pickup_id += 1


func _register_dynamic_multiplayer_pickups() -> void:
	for child in enemy_container.get_children():
		_register_dynamic_multiplayer_pickup(child as Pickup)
	for child in boss_container.get_children():
		_register_dynamic_multiplayer_pickup(child as Pickup)


func _on_dynamic_pickup_container_child_entered(child: Node) -> void:
	if runtime_mode != RuntimeMode.HOST_AUTHORITY:
		return
	var pickup := child as Pickup
	if pickup == null:
		return
	# Drop scripts assign global_position immediately after add_child(). Defer one
	# turn so the spawn RPC observes that final position rather than the container
	# origin, while still avoiding a full-tree scan on every physics frame.
	call_deferred("_register_dynamic_multiplayer_pickup_from_ref", weakref(pickup))


func _register_dynamic_multiplayer_pickup_from_ref(pickup_ref: WeakRef) -> void:
	if pickup_ref == null:
		return
	var pickup := pickup_ref.get_ref() as Pickup
	_register_dynamic_multiplayer_pickup(pickup)


func _register_dynamic_multiplayer_pickup(pickup: Pickup) -> void:
	if runtime_mode != RuntimeMode.HOST_AUTHORITY:
		return
	if pickup == null or not is_instance_valid(pickup) or pickup.is_queued_for_deletion():
		return
	if int(pickup.get_meta("net_id", 0)) > 0:
		return
	var net_id := next_multiplayer_pickup_net_id
	next_multiplayer_pickup_net_id += 1
	_register_multiplayer_pickup(pickup, net_id, true)


func _collect_pickups_recursive(node: Node, pickups: Array[Pickup]) -> void:
	for child in node.get_children():
		var pickup := child as Pickup
		if pickup != null:
			pickups.append(pickup)
		_collect_pickups_recursive(child, pickups)


func _sort_pickups_by_path(a: Pickup, b: Pickup) -> bool:
	return str(a.get_path()) < str(b.get_path())


func _register_multiplayer_pickup(pickup: Pickup, net_id: int, broadcast_spawn: bool) -> void:
	pickup.set_meta("net_id", net_id)
	multiplayer_pickups[net_id] = pickup
	if runtime_mode != RuntimeMode.HOST_AUTHORITY:
		return
	if not pickup.consumed.is_connected(_on_multiplayer_pickup_consumed):
		pickup.consumed.connect(_on_multiplayer_pickup_consumed)
	if not pickup.tree_exited.is_connected(_on_multiplayer_pickup_tree_exited.bind(net_id)):
		pickup.tree_exited.connect(_on_multiplayer_pickup_tree_exited.bind(net_id))
	if broadcast_spawn:
		multiplayer_pickup_spawned.emit(net_id, pickup.config, pickup.global_position)


func _on_multiplayer_pickup_consumed(
	pickup: Pickup,
	collector_peer_id: int,
	applied_immediately: bool
) -> void:
	var net_id := int(pickup.get_meta("net_id", 0))
	if net_id <= 0:
		return
	if not _mark_multiplayer_pickup_removed(net_id, true):
		return
	multiplayer_pickup_collected.emit(
		net_id,
		collector_peer_id,
		pickup.config,
		applied_immediately
	)


func _on_multiplayer_pickup_tree_exited(net_id: int) -> void:
	if runtime_mode != RuntimeMode.HOST_AUTHORITY:
		return
	_mark_multiplayer_pickup_removed(net_id)


func _mark_multiplayer_pickup_removed(
	net_id: int,
	suppress_next_tree_exit: bool = false
) -> bool:
	if net_id <= 0:
		return false
	if suppress_next_tree_exit:
		if pending_multiplayer_pickup_exit_ids.has(net_id):
			return false
		pending_multiplayer_pickup_exit_ids[net_id] = true
	elif pending_multiplayer_pickup_exit_ids.erase(net_id):
		return false
	multiplayer_pickups.erase(net_id)
	multiplayer_pickup_removed.emit(net_id)
	return true


func collect_player_snapshot_states() -> Array[SnapshotManager.PlayerState]:
	var states: Array[SnapshotManager.PlayerState] = []
	for peer_id_variant in peer_players:
		var peer_id := int(peer_id_variant)
		var player_instance := peer_players[peer_id] as Player
		if player_instance == null or not is_instance_valid(player_instance):
			continue
		var state := SnapshotManager.PlayerState.new()
		state.peer_id = peer_id
		state.character_id = player_instance.get_character_id()
		state.position = player_instance.global_position
		state.velocity = player_instance.velocity
		state.facing = player_instance.get_multiplayer_facing_id()
		state.anim_state = player_instance.get_multiplayer_anim_state()
		state.current_health = player_instance.current_health
		state.max_health = player_instance.max_health
		state.current_xirang = player_instance.current_xirang
		state.is_dead = player_instance.is_dead
		state.invincibility_time_left = player_instance.invincibility_time_left
		state.skill1_unlocked = player_instance.skill1_unlocked
		state.skill1_charge = player_instance.skill1_charge
		state.skill1_charge_duration = player_instance.skill1_charge_duration
		state.skill1_upgrade_level = player_instance.skill1_upgrade_level
		state.form_mode = player_instance.get_multiplayer_form_mode()
		state.shot_pattern = player_instance.get_multiplayer_shot_pattern()
		state.ammo_capacity = player_instance.get_multiplayer_ammo_capacity()
		state.current_ammo = player_instance.get_multiplayer_current_ammo()
		state.is_reloading = player_instance.get_multiplayer_is_reloading()
		state.reload_progress = player_instance.get_multiplayer_reload_progress()
		state.primary_cooldown_ratio = _get_player_primary_cooldown_ratio(player_instance)
		state.effective_move_speed_multiplier = (
			player_instance.get_authoritative_move_speed_multiplier()
		)
		states.append(state)
	return states


func _get_player_primary_cooldown_ratio(player_instance: Player) -> float:
	if player_instance == null:
		return 0.0
	if player_instance.has_method("get_primary_cooldown_ratio"):
		return clampf(float(player_instance.call("get_primary_cooldown_ratio")), 0.0, 1.0)
	if player_instance.has_method("get_primary_attack_cooldown_ratio"):
		return clampf(float(player_instance.call("get_primary_attack_cooldown_ratio")), 0.0, 1.0)
	return 0.0


func collect_enemy_snapshot_states() -> Array[SnapshotManager.EnemyState]:
	return collect_reused_enemy_snapshot_states(enemy_container, boss_container)


func _update_tower_defense_enemy_targets(delta: float) -> void:
	enemy_retarget_time_left = maxf(enemy_retarget_time_left - delta, 0.0)
	if enemy_retarget_time_left <= 0.0 and enemy_retarget_sweep_remaining <= 0:
		enemy_retarget_time_left = ENEMY_RETARGET_INTERVAL_SECONDS
		enemy_retarget_sweep_remaining = enemy_container.get_child_count()
		if (
			linglan_boss != null
			and is_instance_valid(linglan_boss)
			and not linglan_boss.is_dead
			and not linglan_boss.is_advancing_to_home()
		):
			_assign_enemy_targets(linglan_boss, linglan_boss.global_position)

	_process_enemy_retarget_budget()


func _process_enemy_retarget_budget() -> void:
	var processed_count := 0
	while (
		enemy_retarget_sweep_remaining > 0
		and processed_count < ENEMY_RETARGET_MAX_PER_PHYSICS_FRAME
	):
		var enemy_count := enemy_container.get_child_count()
		if enemy_count <= 0:
			enemy_retarget_sweep_remaining = 0
			enemy_retarget_cursor = 0
			return
		if enemy_retarget_cursor >= enemy_count:
			enemy_retarget_cursor = 0

		var enemy := enemy_container.get_child(enemy_retarget_cursor) as Enemy
		enemy_retarget_cursor = (enemy_retarget_cursor + 1) % enemy_count
		enemy_retarget_sweep_remaining -= 1
		processed_count += 1
		if enemy == null or enemy.is_dead:
			continue
		_assign_enemy_targets(enemy, enemy.global_position)


func _assign_enemy_targets(enemy: Enemy, from_position: Vector2) -> void:
	if enemy == null or enemy.is_dead:
		return
	enemy.set_near_moving_target_direct_distance(PLAYER_NEAR_MOVING_DIRECT_DISTANCE)
	var combat_player := _pick_enemy_target(from_position)
	# Resolve the capability once in this budgeted 0.60-second retarget pass.
	# PlantSystem then reuses its existing influence candidates and only adds one
	# enum comparison per candidate; movement ticks perform no type probing.
	var objective := _pick_enemy_objective(
		from_position,
		combat_player,
		enemy.can_target_water_plant_objectives()
	)
	enemy.set_target_player(combat_player)
	enemy.set_objective_target(objective)


func _pick_enemy_target(from_position: Vector2) -> Player:
	if runtime_mode != RuntimeMode.HOST_AUTHORITY:
		return player if player != null and not player.is_dead else null
	var best_player: Player = null
	var best_distance := INF
	for peer_id_variant in peer_players:
		var candidate := peer_players[peer_id_variant] as Player
		if candidate == null or not is_instance_valid(candidate) or candidate.is_dead:
			continue
		var distance := from_position.distance_squared_to(candidate.global_position)
		if distance < best_distance:
			best_distance = distance
			best_player = candidate
	return best_player


func find_nearest_enemy_attack_target_world(
	from_position: Vector2,
	max_distance: float,
	excluded_instance_ids: Dictionary = {}
) -> Node2D:
	var nearest_target := super.find_nearest_enemy_attack_target_world(
		from_position,
		max_distance,
		excluded_instance_ids
	)
	if (
		plant_system == null
		or max_distance < 0.0
		or not is_finite(max_distance)
	):
		return nearest_target
	var nearest_plant := plant_system.find_nearest_enemy_attack_target_world(
		from_position,
		max_distance,
		excluded_instance_ids
	)
	if nearest_plant == null:
		return nearest_target
	# PlantSystem already uses an allocation-free exact world-space pass here.
	# Keep this defensive comparison beside the player/plant merge so the public
	# runtime API retains one pixel-radius contract.
	var plant_distance_squared := from_position.distance_squared_to(
		nearest_plant.global_position
	)
	if plant_distance_squared > max_distance * max_distance:
		return nearest_target
	if nearest_target == null:
		return nearest_plant
	var target_distance_squared := from_position.distance_squared_to(
		nearest_target.global_position
	)
	if plant_distance_squared < target_distance_squared:
		return nearest_plant
	if (
		plant_distance_squared == target_distance_squared
		and nearest_plant.get_instance_id()
			< nearest_target.get_instance_id()
	):
		return nearest_plant
	return nearest_target


func _pick_enemy_objective(
	from_position: Vector2,
	combat_player: Player,
	include_water_plants: bool = false
) -> Node2D:
	if plant_system != null:
		var nearest_plant := plant_system.find_nearest_enemy_objective(
			from_position,
			PLANT_OBJECTIVE_AGGRO_RADIUS_CELLS,
			include_water_plants
		)
		if nearest_plant != null:
			return nearest_plant
	if (
		combat_player != null
		and is_instance_valid(combat_player)
		and not combat_player.is_dead
		and _get_logical_tile_distance_squared(
			from_position,
			combat_player.global_position
		) <= PLAYER_OBJECTIVE_AGGRO_RADIUS_CELLS * PLAYER_OBJECTIVE_AGGRO_RADIUS_CELLS
	):
		return combat_player

	var best_gate: Node2D = null
	var best_gate_distance := INF
	for gate_target in home_objective_targets:
		if gate_target == null or not is_instance_valid(gate_target):
			continue
		var gate_distance := from_position.distance_squared_to(gate_target.global_position)
		if gate_distance < best_gate_distance:
			best_gate_distance = gate_distance
			best_gate = gate_target
	return best_gate


func _get_logical_tile_distance_squared(
	from_global_position: Vector2,
	to_global_position: Vector2
) -> float:
	if ground_tile_map_layer == null or ground_tile_map_layer.tile_set == null:
		return (
			from_global_position.distance_squared_to(to_global_position)
			/ (AUTHORED_LOGICAL_TILE_SIZE * AUTHORED_LOGICAL_TILE_SIZE)
		)
	var tile_size := Vector2(ground_tile_map_layer.tile_set.tile_size).abs()
	if tile_size.x <= 0.0 or tile_size.y <= 0.0:
		return INF
	var from_local := ground_tile_map_layer.to_local(from_global_position)
	var to_local := ground_tile_map_layer.to_local(to_global_position)
	var offset_in_cells := Vector2(
		(to_local.x - from_local.x) / tile_size.x,
		(to_local.y - from_local.y) / tile_size.y
	)
	return offset_in_cells.length_squared()


func _request_enemy_retarget_after_objective_change() -> void:
	# Do not restart an in-progress budgeted sweep. Setting the timer to zero
	# guarantees one fresh pass immediately after it finishes, while preserving
	# the per-physics-frame cap for 300+ active enemies.
	enemy_retarget_time_left = 0.0


func get_linglan_skill2_target_global_position(_target_cell: Vector2i) -> Vector2:
	return (
		linglan_boss.global_position
		if linglan_boss != null and is_instance_valid(linglan_boss)
		else _get_linglan_spawn_global_position(active_boss_config)
	)


func get_linglan_skill3_target_global_position(_target_cell: Vector2i) -> Vector2:
	return (
		linglan_boss.global_position
		if linglan_boss != null and is_instance_valid(linglan_boss)
		else _get_linglan_spawn_global_position(active_boss_config)
	)


func get_linglan_skill4_target_global_position(
	target_cell_a: Vector2i,
	target_cell_b: Vector2i
) -> Vector2:
	linglan_skill4_orb_anchor_global_position = (
		linglan_boss.global_position
		if linglan_boss != null and is_instance_valid(linglan_boss)
		else _get_linglan_spawn_global_position(active_boss_config)
	)
	linglan_skill4_orb_authored_center = (
		Vector2(target_cell_a) + Vector2(target_cell_b)
	) * 0.5
	linglan_skill4_orb_anchor_valid = true
	return linglan_skill4_orb_anchor_global_position


func get_linglan_skill4_laser_bounds(
	left_cell_x: int,
	right_cell_x: int,
	top_cell_y: int,
	bottom_cell_y: int,
	inward_cell_distance: int
) -> Dictionary:
	if ground_tile_map_layer == null:
		var fallback_center := _get_boss_arena_center(active_boss_config) if active_boss_config != null else Vector2.ZERO
		return {
			"start_min": fallback_center,
			"start_max": fallback_center,
			"final_min": fallback_center,
			"final_max": fallback_center,
		}
	var start_a := _get_tile_cell_global_position(_map_linglan_skill_cell_to_active_arena(
		Vector2i(left_cell_x, top_cell_y)
	))
	var start_b := _get_tile_cell_global_position(_map_linglan_skill_cell_to_active_arena(
		Vector2i(right_cell_x, bottom_cell_y)
	))
	var final_a := _get_tile_cell_global_position(_map_linglan_skill_cell_to_active_arena(Vector2i(
		left_cell_x + inward_cell_distance,
		top_cell_y + inward_cell_distance
	)))
	var final_b := _get_tile_cell_global_position(_map_linglan_skill_cell_to_active_arena(Vector2i(
		right_cell_x - inward_cell_distance,
		bottom_cell_y - inward_cell_distance
	)))
	return {
		"start_min": Vector2(minf(start_a.x, start_b.x), minf(start_a.y, start_b.y)),
		"start_max": Vector2(maxf(start_a.x, start_b.x), maxf(start_a.y, start_b.y)),
		"final_min": Vector2(minf(final_a.x, final_b.x), minf(final_a.y, final_b.y)),
		"final_max": Vector2(maxf(final_a.x, final_b.x), maxf(final_a.y, final_b.y)),
	}


func get_linglan_skill4_orb_spawn_global_position(x_cell: int, y_cell: int) -> Vector2:
	var anchor_position := linglan_skill4_orb_anchor_global_position
	if not linglan_skill4_orb_anchor_valid:
		anchor_position = (
			linglan_boss.global_position
			if linglan_boss != null and is_instance_valid(linglan_boss)
			else _get_linglan_spawn_global_position(active_boss_config)
		)
	var authored_offset := Vector2(x_cell, y_cell) - linglan_skill4_orb_authored_center
	return anchor_position + _get_tile_cell_global_offset(authored_offset)


func _get_tile_cell_global_position(cell: Vector2i) -> Vector2:
	return ground_tile_map_layer.to_global(ground_tile_map_layer.map_to_local(cell))


func _get_tile_cell_global_offset(cell_offset: Vector2) -> Vector2:
	if ground_tile_map_layer == null:
		return cell_offset * AUTHORED_LOGICAL_TILE_SIZE
	var origin := _get_tile_cell_global_position(Vector2i.ZERO)
	var right_step := _get_tile_cell_global_position(Vector2i.RIGHT) - origin
	var down_step := _get_tile_cell_global_position(Vector2i.DOWN) - origin
	return right_step * cell_offset.x + down_step * cell_offset.y


func _map_linglan_skill_cell_to_active_arena(authored_cell: Vector2i) -> Vector2i:
	if active_boss_config == null:
		return authored_cell
	var arena_rect := _get_boss_arena_floor_rect(active_boss_config)
	if arena_rect.size.x <= 0 or arena_rect.size.y <= 0:
		return authored_cell
	return (
		arena_rect.position
		+ (authored_cell - LINGLAN_SKILL_REFERENCE_ARENA_POSITION)
	)


func get_linglan_skill2_target_player(from_position: Vector2) -> Player:
	return _pick_enemy_target(from_position)


func _get_enemy_spawn_marker(marker_name: StringName) -> Marker2D:
	if marker_name == &"":
		return null
	for marker in enemy_spawn_points:
		if marker != null and marker.name == String(marker_name):
			return marker
	if enemy_spawn_points_root == null:
		return null
	var node := enemy_spawn_points_root.get_node_or_null(NodePath(String(marker_name)))
	return node as Marker2D


func _is_flow_system_ready() -> bool:
	if flow_graph == null:
		push_error("GameTowerDefense 当前 Campaign 没有配置 FlowGraphConfig。")
		return false
	if not _is_spawn_system_ready():
		return false
	var errors := flow_graph.validate_graph()
	for error in errors:
		push_warning(error)
	if not errors.is_empty():
		return false
	return _get_start_flow_step() != null


func _get_start_flow_step() -> FlowStepConfig:
	return flow_graph.start_step if flow_graph != null else null


func _get_flow_step_by_id(step_id: StringName) -> FlowStepConfig:
	if step_id == &"":
		return null
	return flow_graph.get_step_by_id(step_id) if flow_graph != null else null


func _get_flow_step_id(flow_step: FlowStepConfig) -> StringName:
	return flow_step.step_id if flow_step != null else &""


func _get_default_next_flow_step(flow_step: FlowStepConfig) -> FlowStepConfig:
	if flow_step == null:
		return null
	if flow_graph == null or flow_graph.get_step_index(flow_step) < 0:
		return null
	return flow_graph.get_default_next_step(flow_step)


func _get_wave_number_for_step(wave_config: WaveConfig) -> int:
	if wave_config == null:
		return current_wave_index + 1
	var wave_index := waves.find(wave_config)
	if wave_index >= 0:
		return wave_index + 1
	if flow_graph != null:
		var wave_number := 0
		for step in flow_graph.steps:
			if step is WaveConfig:
				wave_number += 1
			if step == wave_config:
				return maxi(wave_number, 1)
	return current_wave_index + 1


func _emit_multiplayer_flow_state(state: WaveState) -> void:
	if runtime_mode != RuntimeMode.HOST_AUTHORITY:
		return
	multiplayer_flow_state_changed.emit(
		_get_flow_step_id(current_flow_step),
		int(state),
		countdown_seconds
	)


func _play_remote_boss_intro(boss_config: BossConfig) -> void:
	var boss_spawn_position := _get_linglan_spawn_global_position(boss_config)
	_focus_camera_on_boss_intro(boss_spawn_position)
	var intro_scene := _load_threaded_or_direct(_get_boss_intro_vfx_scene_path(boss_config)) as PackedScene
	if intro_scene == null:
		return
	if linglan_boss_intro_vfx == null or not is_instance_valid(linglan_boss_intro_vfx):
		linglan_boss_intro_vfx = intro_scene.instantiate() as LinglanBossIntroVFX
		if linglan_boss_intro_vfx == null:
			return
		linglan_boss_intro_vfx.name = "LinglanBossIntroVFX"
		add_child(linglan_boss_intro_vfx)
	if not linglan_boss_intro_vfx.intro_finished.is_connected(
		_on_remote_linglan_boss_intro_finished
	):
		linglan_boss_intro_vfx.intro_finished.connect(
			_on_remote_linglan_boss_intro_finished
		)
	linglan_boss_intro_vfx.play_intro(boss_spawn_position)


func _on_remote_linglan_boss_intro_finished() -> void:
	if runtime_mode != RuntimeMode.CLIENT_VIEW:
		return
	if linglan_boss_intro_vfx != null:
		linglan_boss_intro_vfx.stop_intro()
	_restore_camera_after_boss_intro()


func _restore_remote_camera_if_boss_intro_complete() -> void:
	if (
		linglan_boss_intro_vfx != null
		and linglan_boss_intro_vfx.intro_tween != null
	):
		return
	if linglan_boss_intro_vfx != null:
		linglan_boss_intro_vfx.stop_intro()
	_restore_camera_after_boss_intro()


func _focus_camera_on_boss_intro(boss_position: Vector2) -> void:
	if boss_intro_camera_tween != null:
		boss_intro_camera_tween.kill()
		boss_intro_camera_tween = null
	if map_camera == null:
		return
	spectator_camera_active = false
	if map_camera.get_parent() != self:
		map_camera.reparent(self, true)
	map_camera.process_callback = Camera2D.CAMERA2D_PROCESS_IDLE
	map_camera.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	map_camera.reset_physics_interpolation()
	var rounded_target := boss_position.round()
	if map_camera.global_position.is_equal_approx(rounded_target) or not is_inside_tree():
		map_camera.global_position = rounded_target
		return
	boss_intro_camera_tween = create_tween()
	boss_intro_camera_tween.set_trans(Tween.TRANS_SINE)
	boss_intro_camera_tween.set_ease(Tween.EASE_IN_OUT)
	boss_intro_camera_tween.tween_method(
		_set_map_camera_rounded_global_position,
		map_camera.global_position,
		rounded_target,
		BOSS_INTRO_CAMERA_FOCUS_SECONDS
	)


func _restore_camera_after_boss_intro() -> void:
	if boss_intro_camera_tween != null:
		boss_intro_camera_tween.kill()
		boss_intro_camera_tween = null
	if map_camera == null or player == null:
		return
	spectator_camera_active = false
	_attach_camera_to_local_player()


func _is_spawn_system_ready() -> bool:
	return (
		player != null
		and grid_pathfinder != null
		and grid_pathfinder.get("is_built")
		and not enemy_spawn_points.is_empty()
	)


func _get_current_wave() -> WaveConfig:
	return current_flow_step as WaveConfig


func _pick_spawn_point() -> Marker2D:
	if active_wave_spawn_points.is_empty():
		return null
	return active_wave_spawn_points[
		random_generator.randi_range(0, active_wave_spawn_points.size() - 1)
	]


func _spawn_enemy_spawn_effect(spawn_global_position: Vector2) -> void:
	if not try_reserve_enemy_spawn_effect(spawn_global_position):
		return
	var effect := session_object_pool.acquire(ENEMY_SPAWN_EFFECT_SCENE) as Node2D
	if effect == null:
		return
	effect.global_position = spawn_global_position
	if effect.has_method("restart_effect"):
		effect.call("restart_effect")


func play_remote_enemy_spawn_effect(spawn_global_position: Vector2) -> void:
	_spawn_enemy_spawn_effect(spawn_global_position)


func _play_countdown_tick() -> void:
	countdown_audio.pitch_scale = 1.0
	countdown_audio.play()


func _update_wave_music(wave_config: WaveConfig) -> void:
	if wave_config.music == null:
		return
	_play_music_stream(wave_config.music, DEFAULT_MUSIC_VOLUME_DB, 0.0, true)


func _update_post_wave_music(flow_step: FlowStepConfig) -> void:
	var wave_config := flow_step as WaveConfig
	if wave_config == null or wave_config.post_wave_music == null:
		return
	_play_music_stream(wave_config.post_wave_music, DEFAULT_MUSIC_VOLUME_DB, 0.0, true)


func _update_boss_music(boss_config: BossConfig) -> void:
	if boss_config == null or boss_config.music == null:
		return
	_play_music_stream(boss_config.music, boss_config.music_volume_db, boss_config.music_loop_offset, false)


func pause_all_background_music() -> void:
	_stop_music_fade_tween()
	_pause_background_music_players(self)


func _stop_background_music_for_defeat() -> void:
	_stop_music_fade_tween()
	music_player.stream_paused = false
	music_player.stop()


func _play_music_stream(
	stream: AudioStream,
	volume_db: float,
	loop_offset: float = 0.0,
	fade_in: bool = false
) -> void:
	if stream == null:
		return
	_configure_music_loop(stream, loop_offset)
	music_player.stream_paused = false
	if music_player.stream == stream and music_player.playing:
		return
	_stop_music_fade_tween()
	music_player.stream = stream
	music_player.volume_db = MUSIC_FADE_IN_START_VOLUME_DB if fade_in else volume_db
	music_player.play()
	if fade_in:
		var fade_tween := create_tween()
		music_fade_tween = fade_tween
		fade_tween.tween_property(
			music_player,
			"volume_db",
			volume_db,
			MUSIC_FADE_IN_SECONDS
		)
		fade_tween.finished.connect(
			func() -> void:
				if music_fade_tween == fade_tween:
					music_fade_tween = null
		)


func _stop_music_fade_tween() -> void:
	if music_fade_tween == null:
		return
	music_fade_tween.kill()
	music_fade_tween = null


func _configure_music_loop(stream: AudioStream, loop_offset: float) -> void:
	if stream == null:
		return
	if _audio_stream_has_property(stream, &"loop"):
		stream.set(&"loop", true)
	if _audio_stream_has_property(stream, &"loop_offset"):
		stream.set(&"loop_offset", maxf(loop_offset, 0.0))


func _audio_stream_has_property(stream: AudioStream, property_name: StringName) -> bool:
	for property in stream.get_property_list():
		if property.get("name") == property_name:
			return true
	return false


func _pause_background_music_players(root_node: Node) -> void:
	if root_node == null:
		return
	if _is_background_music_player(root_node):
		root_node.set(&"stream_paused", true)
	for child in root_node.get_children():
		_pause_background_music_players(child)


func _is_background_music_player(node: Node) -> bool:
	if not (
		node is AudioStreamPlayer
		or node is AudioStreamPlayer2D
		or node is AudioStreamPlayer3D
	):
		return false
	if not bool(node.get(&"playing")):
		return false
	var bus_name := String(node.get(&"bus")).to_lower()
	var node_name := String(node.name).to_lower()
	return bus_name == "music" or node_name.contains("music") or node_name.contains("bgm")
