extends CombatRuntimeBase
class_name TowerDefenseGame

const PLAYER_BULLET_POOL_SCENE := preload("res://scene/bullet.tscn")
const TANGO_LASER_BULLET_POOL_SCENE := preload(
	"res://scene/player/tango/tango_laser_bullet.tscn"
)
const CAPOO_AK47_BULLET_POOL_SCENE := preload("res://scene/enemy/capoo/capoo_ak47_bullet.tscn")
const COMBAT_ROBOT_SUICIDE_DRONE_POOL_SCENE := preload(
	"res://scene/enemy/mechanical_life/combat_robot_suicide_drone.tscn"
)
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
const LINGLAN_SLIME_CONFIG_PATHS := TowerDefenseBossCoordinator.LINGLAN_SLIME_CONFIG_PATHS
const GUARDIAN_POINT_LIGHT_TEXTURE := preload("res://resources/texture/enemy/yuanshi_insect/guardian_point_light.png")
const DEFAULT_PLAYER_CHARACTER_ID := &"weishidaier"
const TANGO_MINIMUM_CHARGE_SECONDS := 0.2
const TANGO_MAXIMUM_CHARGE_SECONDS := 2.4
const TANGO_CHARGE_THRESHOLD_EPSILON := 0.0001
const LINGLAN_BOSS_INTRO_VFX_SCENE_PATH := TowerDefenseBossCoordinator.LINGLAN_BOSS_INTRO_VFX_SCENE_PATH
const BOSS_HEALTH_HUD_SCENE_PATH := TowerDefenseBossCoordinator.BOSS_HEALTH_HUD_SCENE_PATH
const LINGLAN_ENRAGE_SNIPER_CONFIG_PATH := TowerDefenseBossCoordinator.LINGLAN_ENRAGE_SNIPER_CONFIG_PATH
const COUNTDOWN_FINAL_SECONDS := TowerDefensePresentationCoordinator.COUNTDOWN_FINAL_SECONDS
const PLAYER_RESPAWN_DELAYS: Array[int] = [5, 10, 15, 20]
const PLAYER_RESPAWN_INVINCIBILITY_SECONDS := 3.0
const SPECTATOR_CAMERA_SPEED := TowerDefensePresentationCoordinator.SPECTATOR_CAMERA_SPEED
const MIN_WAVE_SPAWN_INTERVAL_SECONDS := 0.025
const DEFAULT_MUSIC_VOLUME_DB := TowerDefensePresentationCoordinator.DEFAULT_MUSIC_VOLUME_DB
const MUSIC_FADE_IN_SECONDS := TowerDefensePresentationCoordinator.MUSIC_FADE_IN_SECONDS
const MUSIC_FADE_IN_START_VOLUME_DB := TowerDefensePresentationCoordinator.MUSIC_FADE_IN_START_VOLUME_DB
const LINGLAN_SPAWN_LEFT_OFFSET := TowerDefenseBossCoordinator.LINGLAN_SPAWN_LEFT_OFFSET
const LINGLAN_SKILL4_AUTHORED_TARGET_CENTER := TowerDefenseBossCoordinator.LINGLAN_SKILL4_AUTHORED_TARGET_CENTER
const BOSS_INTRO_CAMERA_FOCUS_SECONDS := TowerDefensePresentationCoordinator.BOSS_INTRO_CAMERA_FOCUS_SECONDS
const LINGLAN_AIRDROP_NEARBY_RADIUS := TowerDefenseBossCoordinator.LINGLAN_AIRDROP_NEARBY_RADIUS
const DEFEAT_CAMERA_TRAVEL_SECONDS := TowerDefensePresentationCoordinator.DEFEAT_CAMERA_TRAVEL_SECONDS
const INITIAL_PLAYER_XIRANG := TowerDefensePlayerRosterCoordinator.INITIAL_PLAYER_XIRANG
const DEFAULT_BASE_HEALTH := 100
const XIAOCONG_INTERACTION_DISTANCE := (
	TowerDefenseFateFlowCoordinator.XIAOCONG_INTERACTION_DISTANCE
)
const FORMAL_PROGRESSION_CONFIG_PATH := (
	"res://resources/config/campaigns/tower_defense/formal_progression.tres"
)
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
const LINGLAN_SKILL_REFERENCE_ARENA_POSITION := TowerDefenseBossCoordinator.LINGLAN_SKILL_REFERENCE_ARENA_POSITION
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
const PLANT_PLACEMENT_REJECT_INVALID_REQUEST := TowerDefensePlantRuntimeCoordinator.PLACEMENT_REJECT_INVALID_REQUEST
const PLANT_PLACEMENT_REJECT_INVALID_PLAYER := TowerDefensePlantRuntimeCoordinator.PLACEMENT_REJECT_INVALID_PLAYER
const PLANT_PLACEMENT_REJECT_INVALID_CONFIG := TowerDefensePlantRuntimeCoordinator.PLACEMENT_REJECT_INVALID_CONFIG
const PLANT_PLACEMENT_REJECT_INVALID_POSITION := TowerDefensePlantRuntimeCoordinator.PLACEMENT_REJECT_INVALID_POSITION
const PLANT_PLACEMENT_REJECT_INVALID_INVENTORY_ITEM := TowerDefensePlantRuntimeCoordinator.PLACEMENT_REJECT_INVALID_INVENTORY_ITEM
const PLANT_PLACEMENT_REJECT_STALE_INVENTORY := TowerDefensePlantRuntimeCoordinator.PLACEMENT_REJECT_STALE_INVENTORY
const PLANT_PLACEMENT_REJECT_FREE_DISABLED := TowerDefensePlantRuntimeCoordinator.PLACEMENT_REJECT_FREE_DISABLED
const PLANT_PLACEMENT_REJECT_FLOW_LOCKED := TowerDefensePlantRuntimeCoordinator.PLACEMENT_REJECT_FLOW_LOCKED

signal base_health_changed(current_health: int, maximum_health: int, revision: int)

# Production defaults to loading-time prewarming. The cohort performance probe
# can disable it before scene instantiation for a strict old/new A/B.
static var expanded_projectile_pool_prewarm_enabled := true

@export_group("战役资源")
@export var mode_definition: GameModeDefinition = null
@export var singleplayer_campaign: WaveCampaignConfig = null
@export var multiplayer_campaign: WaveCampaignConfig = null

@export_group("战斗流程")
@export var progression_config: TowerDefenseProgressionConfig = null
@export var day_cycle_config: DayCycleConfig = preload(
	"res://resources/config/day_cycle/tower_defense_day_cycle.tres"
)
@export var auto_start_waves: bool = true
@export var linglan_boss_enabled: bool = false
@export var day_phase_announcements_enabled: bool = true

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
@onready var wave_hud: TowerDefenseWaveHUD = $WaveHUD
@onready var day_phase_announcement: DayPhaseAnnouncement = $DayPhaseAnnouncement
@onready var tower_defense_status_hud: TowerDefenseStatusHUD = $TowerDefenseStatusHUD
@onready var tower_defense_minimap: TowerDefenseMinimap = $TowerDefenseMinimap
@onready var oak_warehouse_panel: OakWarehousePanel = $OakWarehousePanel
@onready var production_building_panel: ProductionBuildingPanel = $ProductionBuildingPanel
@onready var research_center_panel: ResearchCenterPanel = $ResearchCenterPanel
@onready var player_profile_panel: TowerDefensePlayerProfilePanel = $PlayerProfilePanel
@onready var settings_panel: SettingsPanel = $SettingsLayer/SettingsPanel
@onready var debug_collectible_window: DebugCollectibleWindow = $SettingsLayer/DebugCollectibleWindow
@onready var merchant: ZhuangfangyiMerchant = $ZhuangfangyiMerchant
@onready var luoxi_merchant: TowerDefenseLuoxiMerchant = $LuoxiMerchant
@onready var campaign_coordinator: TowerDefenseCampaignCoordinator = (
	$CampaignCoordinator
)
@onready var campaign_runtime_port: TowerDefenseCampaignRuntimePort = (
	$CampaignRuntimePort
)
@onready var enemy_coordinator: TowerDefenseEnemyCoordinator = $EnemyCoordinator
@onready var home_defense_coordinator: TowerDefenseHomeDefenseCoordinator = (
	$HomeDefenseCoordinator
)
@onready var plant_runtime_coordinator := get_node_or_null(
	"PlantRuntimeCoordinator"
) as TowerDefensePlantRuntimeCoordinator
@onready var plant_placement_coordinator := get_node_or_null(
	"PlantPlacementCoordinator"
) as TowerDefensePlantPlacementCoordinator
@onready var player_roster_coordinator := get_node_or_null(
	"PlayerRosterCoordinator"
) as TowerDefensePlayerRosterCoordinator
@onready var boss_coordinator := get_node_or_null(
	"BossCoordinator"
) as TowerDefenseBossCoordinator
@onready var presentation_coordinator := get_node_or_null(
	"PresentationCoordinator"
) as TowerDefensePresentationCoordinator
@onready var prewarmer_coordinator := get_node_or_null(
	"PrewarmerCoordinator"
) as TowerDefensePrewarmerCoordinator
@onready var tower_grid_pathfinder: GridPathfinder = grid_pathfinder as GridPathfinder
@onready var tower_multiplayer_mode_adapter: TowerDefenseMultiplayerModeAdapter = (
	multiplayer_mode_adapter as TowerDefenseMultiplayerModeAdapter
)
@onready var tower_plant_gameplay_port: TowerPlantGameplayPort = (
	$TowerPlantGameplayPort as TowerPlantGameplayPort
)
@onready var luoxi_special_game_coordinator: LuoxiSpecialGameCoordinator = (
	$LuoxiSpecialGameCoordinator
)
@onready var fate_coordinator: FateCoordinator = $FateCoordinator
@onready var fate_manager: TowerDefenseFateManager = (
	$FateCoordinator/TowerDefenseFateManager
)
@onready var xiaocong_fate_interlude: XiaocongFateInterlude = $XiaocongFateInterlude
@onready var fate_flow_coordinator: TowerDefenseFateFlowCoordinator = (
	$FateFlowCoordinator
)
@onready var boss_container: Node2D = $BossContainer
@onready var linglan_boss_runtime_port: TowerDefenseLinglanBossRuntimePort = (
	$LinglanBossRuntimePort as TowerDefenseLinglanBossRuntimePort
)
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
@onready var damage_number_pool: DamageNumberPool = $DamageNumberPool
@onready var session_object_pool: SessionObjectPool = $SessionObjectPool
@onready var bamboo_mortar_combat_system: BambooMortarCombatSystem = (
	$BambooMortarCombatSystem
)
@onready var run_state: RunStateStore = get_node("/root/RunState") as RunStateStore

var random_generator := RandomNumberGenerator.new()
var multiplayer_terrain_revision: int:
	get:
		return plant_runtime_coordinator.multiplayer_terrain_revision
	set(value):
		plant_runtime_coordinator.multiplayer_terrain_revision = value
var authored_terrain_baseline: Dictionary:
	get:
		return plant_runtime_coordinator.authored_terrain_baseline
var multiplayer_terrain_overrides: Dictionary:
	get:
		return plant_runtime_coordinator.multiplayer_terrain_overrides
	set(value):
		plant_runtime_coordinator.multiplayer_terrain_overrides = value
var _pending_music_fade_tween: Tween = null
var music_fade_tween: Tween:
	get:
		return (
			presentation_coordinator.music_fade_tween
			if presentation_coordinator != null and presentation_coordinator.is_bound()
			else _pending_music_fade_tween
		)
	set(value):
		_pending_music_fade_tween = value
		if presentation_coordinator != null and presentation_coordinator.is_bound():
			presentation_coordinator.replace_music_fade_tween(value)
var _pending_boss_intro_camera_tween: Tween = null
var boss_intro_camera_tween: Tween:
	get:
		return (
			presentation_coordinator.boss_intro_camera_tween
			if presentation_coordinator != null and presentation_coordinator.is_bound()
			else _pending_boss_intro_camera_tween
		)
	set(value):
		_pending_boss_intro_camera_tween = value
		if presentation_coordinator != null and presentation_coordinator.is_bound():
			presentation_coordinator.replace_boss_intro_camera_tween(value)
var _pending_defeat_camera_tween: Tween = null
var defeat_camera_tween: Tween:
	get:
		return (
			presentation_coordinator.defeat_camera_tween
			if presentation_coordinator != null and presentation_coordinator.is_bound()
			else _pending_defeat_camera_tween
		)
	set(value):
		_pending_defeat_camera_tween = value
		if presentation_coordinator != null and presentation_coordinator.is_bound():
			presentation_coordinator.replace_defeat_camera_tween(value)
var multiplayer_player_names: Dictionary = {}
var multiplayer_player_character_ids: Dictionary = {}
var multiplayer_spawn_slot_indices: Dictionary[int, int] = {}
var pending_multiplayer_pickup_exit_ids: Dictionary = {}
var maximum_base_health: int:
	get:
		return home_defense_coordinator.maximum_base_health
	set(value):
		home_defense_coordinator.maximum_base_health = value
var current_base_health: int:
	get:
		return home_defense_coordinator.current_base_health
	set(value):
		home_defense_coordinator.current_base_health = value
var base_health_revision: int:
	get:
		return home_defense_coordinator.base_health_revision
	set(value):
		home_defense_coordinator.base_health_revision = value
var has_received_remote_base_health_snapshot: bool:
	get:
		return home_defense_coordinator.has_received_remote_base_health_snapshot
	set(value):
		home_defense_coordinator.has_received_remote_base_health_snapshot = value
var next_multiplayer_pickup_net_id: int = 1000
var _next_multiplayer_plant_net_id := 1
var next_multiplayer_plant_net_id: int:
	get:
		return plant_runtime_coordinator.next_multiplayer_plant_net_id if plant_runtime_coordinator != null else _next_multiplayer_plant_net_id
	set(value):
		_next_multiplayer_plant_net_id = value
		if plant_runtime_coordinator != null:
			plant_runtime_coordinator.next_multiplayer_plant_net_id = value
var _linglan_boss_started := false
var linglan_boss_started: bool:
	get:
		return (
			boss_coordinator.linglan_boss_started
			if boss_coordinator != null
			else _linglan_boss_started
		)
	set(value):
		_linglan_boss_started = value
		if boss_coordinator != null:
			boss_coordinator.linglan_boss_started = value
var _active_boss_config: BossConfig
var active_boss_config: Resource:
	get:
		return (
			boss_coordinator.active_boss_config
			if boss_coordinator != null
			else _active_boss_config
		)
	set(value):
		_active_boss_config = value as BossConfig
		if boss_coordinator != null:
			boss_coordinator.active_boss_config = value as BossConfig
var _linglan_boss: LinglanBoss
var linglan_boss: LinglanBoss:
	get:
		return (
			boss_coordinator.linglan_boss
			if boss_coordinator != null
			else _linglan_boss
		)
	set(value):
		_linglan_boss = value
		if boss_coordinator != null:
			boss_coordinator.linglan_boss = value
var _linglan_boss_intro_vfx: LinglanBossIntroVFX
var linglan_boss_intro_vfx: LinglanBossIntroVFX:
	get:
		return (
			boss_coordinator.linglan_boss_intro_vfx
			if boss_coordinator != null
			else _linglan_boss_intro_vfx
		)
	set(value):
		_linglan_boss_intro_vfx = value
		if boss_coordinator != null:
			boss_coordinator.linglan_boss_intro_vfx = value
var _boss_health_hud: BossHealthHUD
var boss_health_hud: BossHealthHUD:
	get:
		return (
			boss_coordinator.boss_health_hud
			if boss_coordinator != null
			else _boss_health_hud
		)
	set(value):
		_boss_health_hud = value
		if boss_coordinator != null:
			boss_coordinator.boss_health_hud = value
var _linglan_skill4_orb_anchor_global_position := Vector2.ZERO
var linglan_skill4_orb_anchor_global_position: Vector2:
	get:
		return (
			boss_coordinator.linglan_skill4_orb_anchor_global_position
			if boss_coordinator != null
			else _linglan_skill4_orb_anchor_global_position
		)
	set(value):
		_linglan_skill4_orb_anchor_global_position = value
		if boss_coordinator != null:
			boss_coordinator.linglan_skill4_orb_anchor_global_position = value
var _linglan_skill4_orb_authored_center := LINGLAN_SKILL4_AUTHORED_TARGET_CENTER
var linglan_skill4_orb_authored_center: Vector2:
	get:
		return (
			boss_coordinator.linglan_skill4_orb_authored_center
			if boss_coordinator != null
			else _linglan_skill4_orb_authored_center
		)
	set(value):
		_linglan_skill4_orb_authored_center = value
		if boss_coordinator != null:
			boss_coordinator.linglan_skill4_orb_authored_center = value
var _linglan_skill4_orb_anchor_valid := false
var linglan_skill4_orb_anchor_valid: bool:
	get:
		return (
			boss_coordinator.linglan_skill4_orb_anchor_valid
			if boss_coordinator != null
			else _linglan_skill4_orb_anchor_valid
		)
	set(value):
		_linglan_skill4_orb_anchor_valid = value
		if boss_coordinator != null:
			boss_coordinator.linglan_skill4_orb_anchor_valid = value
var _linglan_slime_configs: Array[EnemyConfig] = []
var linglan_slime_configs: Array[EnemyConfig]:
	get:
		return (
			boss_coordinator.linglan_slime_configs
			if boss_coordinator != null
			else _linglan_slime_configs
		)
	set(value):
		_linglan_slime_configs = value
		if boss_coordinator != null:
			boss_coordinator.linglan_slime_configs = value
var _linglan_enrage_sniper_config: EnemyConfig
var linglan_enrage_sniper_config: EnemyConfig:
	get:
		return (
			boss_coordinator.linglan_enrage_sniper_config
			if boss_coordinator != null
			else _linglan_enrage_sniper_config
		)
	set(value):
		_linglan_enrage_sniper_config = value
		if boss_coordinator != null:
			boss_coordinator.linglan_enrage_sniper_config = value
var _boss_runtime_scene_loads_requested := false
var boss_runtime_scene_loads_requested: bool:
	get:
		return (
			boss_coordinator.runtime_scene_loads_requested
			if boss_coordinator != null
			else _boss_runtime_scene_loads_requested
		)
	set(value):
		_boss_runtime_scene_loads_requested = value
		if boss_coordinator != null:
			boss_coordinator.runtime_scene_loads_requested = value
var _boss_runtime_resources_by_path: Dictionary[String, Resource] = {}
var boss_runtime_resources_by_path: Dictionary[String, Resource]:
	get:
		return (
			boss_coordinator.runtime_resources_by_path
			if boss_coordinator != null
			else _boss_runtime_resources_by_path
		)
	set(value):
		_boss_runtime_resources_by_path = value
		if boss_coordinator != null:
			boss_coordinator.runtime_resources_by_path = value
var navigation_prewarm_requested: bool:
	get:
		return prewarmer_coordinator != null and prewarmer_coordinator.navigation_prewarm_requested
var navigation_prewarmed: bool:
	get:
		return prewarmer_coordinator != null and prewarmer_coordinator.navigation_prewarmed
var plant_lifecycle_shader_prewarmed: bool:
	get:
		return prewarmer_coordinator != null and prewarmer_coordinator.plant_lifecycle_shader_prewarmed
var _previous_physics_interpolation_enabled := false
var _owns_physics_interpolation_override := false
var player_wave_death_counts: Dictionary = {}
var _singleplayer_respawn_time_left := -1.0
var singleplayer_respawn_time_left: float:
	get:
		if player_roster_coordinator != null:
			return player_roster_coordinator.singleplayer_respawn_time_left
		return _singleplayer_respawn_time_left
	set(value):
		_singleplayer_respawn_time_left = value
		if player_roster_coordinator != null:
			player_roster_coordinator.singleplayer_respawn_time_left = value
var _singleplayer_respawn_last_seconds := -1
var singleplayer_respawn_last_seconds: int:
	get:
		if player_roster_coordinator != null:
			return player_roster_coordinator.singleplayer_respawn_last_seconds
		return _singleplayer_respawn_last_seconds
	set(value):
		_singleplayer_respawn_last_seconds = value
		if player_roster_coordinator != null:
			player_roster_coordinator.singleplayer_respawn_last_seconds = value
var _pending_spectator_camera_active := false
var spectator_camera_active: bool:
	get:
		return (
			presentation_coordinator.spectator_camera_active
			if presentation_coordinator != null and presentation_coordinator.is_bound()
			else _pending_spectator_camera_active
		)
	set(value):
		_pending_spectator_camera_active = value
		if presentation_coordinator != null and presentation_coordinator.is_bound():
			presentation_coordinator.spectator_camera_active = value
var projectile_pool_registration_ms := 0.0
var starting_package_granted := false
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
	initialize_world_lighting()
	if not _configure_player_roster_coordinator():
		set_process(false)
		set_physics_process(false)
		return
	if merchant != null:
		merchant.bind_multiplayer_mode_adapter(multiplayer_mode_adapter)
	if luoxi_merchant != null:
		luoxi_merchant.bind_multiplayer_mode_adapter(multiplayer_mode_adapter)
	oak_warehouse_panel.bind_tower_plant_gameplay_port(
		tower_plant_gameplay_port
	)
	LuoxiMerchant.reset_runtime_choice_count()
	if day_cycle_config == null or not day_cycle_config.is_valid():
		push_error("TowerDefenseGame: DayCycleConfig 无效，停止初始化。")
		set_process(false)
		set_physics_process(false)
		return
	if not _configure_presentation_coordinator():
		set_process(false)
		set_physics_process(false)
		return
	bamboo_mortar_combat_system.setup(
		self,
		tower_plant_gameplay_port
	)
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
	if not _configure_prewarmer_coordinator():
		set_process(false)
		set_physics_process(false)
		return
	if runtime_mode == RuntimeMode.SINGLEPLAYER:
		run_state.ensure_run_started()
		_configure_singleplayer_player()
	_configure_enemy_coordinator()
	_configure_timers()
	prewarmer_coordinator.prewarm_enemy_visual_resources()
	CombatRuntimeBase.register_common_visual_effect_pools(session_object_pool)
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
	CombatRuntimeBase.register_combat_robot_gunner_bullet_pool(session_object_pool)
	session_object_pool.register_scene(COMBAT_ROBOT_SUICIDE_DRONE_POOL_SCENE, 0, 384)
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
	CombatRuntimeBase.register_capoo_mage_fireball_impact_pool(
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
		player_roster_coordinator.configure_production_output_peers()
		_register_static_multiplayer_pickups()
	if player == null:
		push_error("TowerDefenseGame: 无法创建当前角色，停止初始化。")
		set_process(false)
		set_physics_process(false)
		return
	presentation_coordinator.configure_status_hud(int(runtime_mode))
	_attach_camera_to_local_player()
	presentation_coordinator.configure_wave_hud(
		int(runtime_mode),
		home_defense_coordinator.current_base_health,
		home_defense_coordinator.maximum_base_health
	)
	_configure_home_defense()
	_configure_plant_defense_system()
	if not _configure_plant_placement_coordinator():
		set_process(false)
		set_physics_process(false)
		return
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
		plant_runtime_coordinator.notify_recipe_unlocks_changed
	):
		research_coordinator.research_state_changed.connect(
			plant_runtime_coordinator.notify_recipe_unlocks_changed
		)
	_register_research_players()
	_configure_minimap()
	_apply_initial_player_xirang()
	campaign_coordinator.start_progression_metrics()
	if (
		runtime_mode != RuntimeMode.CLIENT_VIEW
		and not _grant_tower_defense_starting_package()
	):
		push_error("TowerDefenseGame: 无法原子发放正式塔防起步包，停止初始化。")
		set_process(false)
		set_physics_process(false)
		return
	currency_hud.bind_player(player)
	player_profile_panel.configure_multiplayer_requests(
		runtime_mode != RuntimeMode.SINGLEPLAYER
	)
	player_profile_panel.set_research_coordinator(research_coordinator)
	player_profile_panel.bind_player(player)
	currency_hud.settings_requested.connect(_on_currency_hud_settings_requested)
	currency_hud.profile_requested.connect(_on_currency_hud_profile_requested)
	presentation_coordinator.connect_wave_hud_requests()
	luoxi_special_game_coordinator.setup(
		self,
		run_state,
		luoxi_merchant,
		random_generator,
		runtime_mode != RuntimeMode.CLIENT_VIEW
	)
	_set_merchant_active(false)
	fate_coordinator.setup(self, campaign_coordinator, day_cycle_config)
	if not _configure_xiaocong_fate_flow():
		set_process(false)
		set_physics_process(false)
		return
	if not _configure_boss_coordinator():
		set_process(false)
		set_physics_process(false)
		return
	if not _bind_tower_multiplayer_adapter_dependencies():
		set_process(false)
		set_physics_process(false)
		return
	if not _configure_campaign_runtime_coordinator():
		set_process(false)
		set_physics_process(false)
		return
	call_deferred("_deferred_request_boss_runtime_scene_loads")

	if runtime_mode == RuntimeMode.CLIENT_VIEW:
		auto_start_waves = false
		campaign_coordinator.start_client_flow_countdown(
			CombatFlowState.State.PRE_WAVE,
			_get_flow_step_id(_get_start_flow_step()),
			campaign_coordinator.get_initial_preparation_seconds()
		)
	elif auto_start_waves and not runtime_activation_deferred and _is_flow_system_ready():
		campaign_coordinator.enter_pre_flow_step(_get_start_flow_step())
	else:
		enemy_coordinator.show_wave_progress()
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
	if (
		campaign_coordinator.current_flow_step == null
		and auto_start_waves
		and _is_flow_system_ready()
	):
		campaign_coordinator.enter_pre_flow_step(_get_start_flow_step())


func _physics_process(delta: float) -> void:
	_update_local_spectator_camera(delta)
	_update_singleplayer_respawn(delta)
	if runtime_mode != RuntimeMode.CLIENT_VIEW:
		enemy_coordinator.update_targets(delta)
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
	var adapter := get_multiplayer_mode_adapter() as TowerDefenseMultiplayerModeAdapter
	if adapter == null:
		push_error("TowerDefenseGame: 缺少静态 MultiplayerModeAdapter 节点。")
		return
	adapter.configure_tower_multiplayer(
		self,
		mode,
		local_peer_id,
		player_names,
		player_character_ids
	)


func _configure_player_roster_coordinator() -> bool:
	if player_roster_coordinator == null:
		push_error("TowerDefenseGame: 缺少静态 PlayerRosterCoordinator 节点。")
		return false
	player_roster_coordinator.setup(
		runtime_mode,
		multiplayer_local_peer_id,
		self,
		player_spawn,
		run_state,
		research_coordinator,
		production_coordinator,
		peer_players,
		multiplayer_player_names,
		multiplayer_player_character_ids,
		multiplayer_spawn_slot_indices,
		player_wave_death_counts,
		DEFAULT_PLAYER_CHARACTER_ID,
		MULTIPLAYER_SPAWN_OFFSETS,
		PLAYER_RESPAWN_DELAYS,
		PLAYER_RESPAWN_INVINCIBILITY_SECONDS,
		TANGO_MINIMUM_CHARGE_SECONDS,
		TANGO_MAXIMUM_CHARGE_SECONDS,
		TANGO_CHARGE_THRESHOLD_EPSILON
	)
	player_roster_coordinator.singleplayer_respawn_time_left = (
		_singleplayer_respawn_time_left
	)
	player_roster_coordinator.singleplayer_respawn_last_seconds = (
		_singleplayer_respawn_last_seconds
	)
	if not player_roster_coordinator.is_bound():
		push_error("TowerDefenseGame: PlayerRosterCoordinator 依赖绑定不完整。")
		return false
	player_roster_coordinator.player_runtime_binding_requested.connect(
		bind_player_runtime_context
	)
	player_roster_coordinator.enemy_retarget_requested.connect(
		enemy_coordinator.request_retarget
	)
	return true


func _configure_presentation_coordinator() -> bool:
	if presentation_coordinator == null:
		push_error("TowerDefenseGame: 缺少静态 PresentationCoordinator 节点。")
		return false
	presentation_coordinator.setup(
		self,
		campaign_coordinator,
		day_cycle_config,
		map_camera,
		music_player,
		countdown_audio,
		wave_start_audio,
		defeat_audio,
		wave_hud,
		day_phase_announcement,
		tower_defense_status_hud
	)
	presentation_coordinator.replace_music_fade_tween(
		_pending_music_fade_tween
	)
	presentation_coordinator.replace_boss_intro_camera_tween(
		_pending_boss_intro_camera_tween
	)
	presentation_coordinator.replace_defeat_camera_tween(
		_pending_defeat_camera_tween
	)
	presentation_coordinator.spectator_camera_active = (
		_pending_spectator_camera_active
	)
	if not presentation_coordinator.is_bound():
		push_error("TowerDefenseGame: PresentationCoordinator 依赖绑定不完整。")
		return false
	return true


func request_tango_charge_started(direction: Vector2) -> bool:
	player_roster_coordinator.local_player = player
	player_roster_coordinator.set_runtime_identity(runtime_mode, multiplayer_local_peer_id)
	return player_roster_coordinator.request_tango_charge_started(direction)


func request_tango_charge_released(direction: Vector2) -> bool:
	player_roster_coordinator.local_player = player
	player_roster_coordinator.set_runtime_identity(runtime_mode, multiplayer_local_peer_id)
	return player_roster_coordinator.request_tango_charge_released(direction)


func request_tango_charge_cancelled() -> bool:
	player_roster_coordinator.local_player = player
	player_roster_coordinator.set_runtime_identity(runtime_mode, multiplayer_local_peer_id)
	return player_roster_coordinator.request_tango_charge_cancelled()


func supports_tower_defense() -> bool:
	return true


## Only authored tower-defense test arenas opt into this diagnostic contract.
## Keeping it on the tower runtime avoids leaking test-arena behavior into the
## neutral combat base while preserving the existing subclasses' overrides.
func supports_test_arena_manual_night_sync() -> bool:
	return false


func get_test_arena_manual_night_enabled() -> bool:
	return false


func apply_remote_test_arena_manual_night(_enabled: bool) -> void:
	pass


func _apply_wave_start_lighting(wave_number: int) -> void:
	presentation_coordinator.apply_wave_start_lighting(wave_number)


func _apply_intermission_lighting(completed_wave_number: int) -> void:
	presentation_coordinator.apply_intermission_lighting(completed_wave_number)


func _is_night_wave(wave_number: int) -> bool:
	return (
		campaign_coordinator.is_night_wave(wave_number)
		if campaign_coordinator != null
		else day_cycle_config.is_night_wave(wave_number)
	)


func _get_day_number_for_wave(wave_number: int) -> int:
	return (
		campaign_coordinator.get_day_number_for_wave(wave_number)
		if campaign_coordinator != null
		else day_cycle_config.get_day_number(wave_number)
	)


func _announce_wave_phase_start(wave_number: int) -> bool:
	return presentation_coordinator.announce_wave_phase_start(
		wave_number,
		day_phase_announcements_enabled
	)


func supports_multiplayer_terrain_state() -> bool:
	return true


func request_bamboo_mortar_target(
	owner: Node2D,
	minimum_range: float,
	maximum_range: float,
	callback: Callable
) -> bool:
	if runtime_mode == RuntimeMode.CLIENT_VIEW:
		return false
	return plant_runtime_coordinator.request_bamboo_mortar_target(
		owner,
		minimum_range,
		maximum_range,
		callback
	)


func cancel_bamboo_mortar_target_request(owner: Node) -> void:
	plant_runtime_coordinator.cancel_bamboo_mortar_target_request(owner)


func select_bamboo_mortar_target_sync_for_fixture(
	center: Vector2,
	minimum_range: float,
	maximum_range: float
) -> Enemy:
	return plant_runtime_coordinator.select_bamboo_mortar_target_sync_for_fixture(
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
	if runtime_mode == RuntimeMode.CLIENT_VIEW:
		return false
	return plant_runtime_coordinator.queue_bamboo_mortar_explosion(
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
	plant_runtime_coordinator.set_runtime_mode(runtime_mode)
	return plant_runtime_coordinator.apply_authoritative_enemy_damage_batch(
		damage_source_id,
		enemy,
		damage_amounts,
		hit_counts,
		impact_direction,
		damage_type
	)


func query_living_plants_in_radius_into(
	center: Vector2,
	radius: float,
	result: Array[PlantDefense]
) -> void:
	result.clear()
	plant_runtime_coordinator.query_living_plants_in_radius_into(center, radius, result)


func get_bamboo_mortar_combat_metrics() -> Dictionary:
	return plant_runtime_coordinator.get_bamboo_mortar_combat_metrics()


func get_fixed_multiplayer_respawn_position(peer_id: int) -> Variant:
	return tower_multiplayer_mode_adapter.get_fixed_multiplayer_respawn_position(
		peer_id
	)


func _configure_active_campaign() -> bool:
	if progression_config == null:
		progression_config = load(
			FORMAL_PROGRESSION_CONFIG_PATH
		) as TowerDefenseProgressionConfig
	if progression_config == null or not progression_config.is_valid():
		push_error("TowerDefenseGame: 正式成长配置缺失或无效。")
		return false
	var definition := mode_definition
	if definition == null:
		definition = GameModeCatalog.get_definition(
			GameModeCatalog.MODE_TOWER_DEFENSE
		)
	var configured := campaign_coordinator.configure(
		int(runtime_mode),
		definition,
		singleplayer_campaign,
		multiplayer_campaign,
		day_cycle_config
	)
	singleplayer_campaign = campaign_coordinator.singleplayer_campaign
	multiplayer_campaign = campaign_coordinator.multiplayer_campaign
	if campaign_coordinator.active_campaign == null:
		push_error("TowerDefenseGame: 模式定义无法解析当前运行模式的 Campaign。")
		push_error("TowerDefenseGame: 当前运行模式没有配置 WaveCampaignConfig。")
		return false
	for error in campaign_coordinator.configuration_errors:
		push_error(error)
	if not configured:
		return false
	return true


func _configure_prewarmer_coordinator() -> bool:
	if prewarmer_coordinator == null:
		push_error("TowerDefenseGame: 缺少静态 PrewarmerCoordinator 节点。")
		return false
	if tower_grid_pathfinder == null:
		push_error("TowerDefenseGame: GridPathfinder 必须为强类型 GridPathfinder。")
		return false
	return prewarmer_coordinator.setup(
		self,
		tower_grid_pathfinder,
		map_camera,
		session_object_pool,
		boss_coordinator,
		fate_coordinator,
		campaign_coordinator.waves,
		PLANT_PLACEMENT_PARTICLES_SCENE,
		PLANT_REMOVAL_SMOKE_SCENE,
		GUARDIAN_POINT_LIGHT_TEXTURE
	)


func _configure_campaign_runtime_coordinator() -> bool:
	if campaign_runtime_port == null:
		push_error("TowerDefenseGame: 缺少静态 CampaignRuntimePort 节点。")
		return false
	campaign_runtime_port.bind_runtime(self)
	var configured := campaign_coordinator.setup_runtime(
		campaign_runtime_port,
		enemy_coordinator,
		presentation_coordinator,
		boss_coordinator,
		player_roster_coordinator,
		prewarmer_coordinator,
		fate_flow_coordinator,
		tower_multiplayer_mode_adapter,
		plant_placement_coordinator,
		home_defense_coordinator,
		state_timer,
		enemy_spawn_timer,
		progression_config,
		run_state,
		production_coordinator,
		luoxi_special_game_coordinator,
		luoxi_merchant,
		day_phase_announcements_enabled
	)
	if not configured:
		push_error("TowerDefenseGame: CampaignCoordinator 运行时依赖绑定不完整。")
		return false
	return true


func _bind_tower_multiplayer_adapter_dependencies() -> bool:
	if tower_multiplayer_mode_adapter == null:
		push_error("TowerDefenseGame: 缺少静态 TowerDefenseMultiplayerModeAdapter。")
		return false
	tower_multiplayer_mode_adapter.bind_tower_dependencies(
		self,
		campaign_coordinator,
		enemy_coordinator,
		home_defense_coordinator,
		plant_runtime_coordinator,
		player_roster_coordinator,
		boss_coordinator,
		fate_coordinator,
		fate_flow_coordinator,
		fate_manager,
		presentation_coordinator,
		player_profile_panel,
		debug_collectible_window,
		merchant,
		luoxi_merchant,
		luoxi_special_game_coordinator,
		run_state,
		research_coordinator,
		plant_placement_coordinator,
		state_timer
	)
	if not tower_multiplayer_mode_adapter.is_tower_bound():
		push_error("TowerDefenseGame: MultiplayerAdapter 依赖绑定不完整。")
		return false
	return true


func replace_campaign_runtime_state_for_fixture(
	fixture_flow_graph: FlowGraphConfig,
	fixture_waves: Array[WaveConfig],
	fixture_bosses: Array[Resource]
) -> void:
	campaign_coordinator.replace_runtime_state_for_fixture(
		fixture_flow_graph,
		fixture_waves,
		fixture_bosses
	)


func _configure_singleplayer_player() -> void:
	var character_id := _get_selected_singleplayer_character_id()
	player = player_roster_coordinator.configure_singleplayer(character_id)


func _attach_camera_to_local_player() -> void:
	presentation_coordinator.attach_camera_to_local_player(player)


func _configure_home_defense() -> void:
	home_defense_coordinator.setup(
		self,
		run_state,
		home_gate_controller,
		overlay_tile_map_layer,
		DEFAULT_BASE_HEALTH,
		campaign_coordinator,
		enemy_coordinator,
		boss_container,
		presentation_coordinator,
		tower_multiplayer_mode_adapter
	)


func get_home_objective_targets() -> Array[Node2D]:
	return home_defense_coordinator.get_home_targets()


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


func _apply_base_damage(amount: int) -> void:
	home_defense_coordinator.apply_base_damage(amount)


func _update_base_health_display(play_damage_pulse: bool = true) -> void:
	presentation_coordinator.show_base_health(
		home_defense_coordinator.current_base_health,
		home_defense_coordinator.maximum_base_health,
		play_damage_pulse
	)


func _configure_plant_defense_system() -> void:
	if plant_system == null or plant_placement_controller == null or plant_container == null:
		push_error("TowerDefenseGame: 植物防御塔节点不完整，已禁用放置功能。")
		return
	plant_runtime_coordinator.setup(
		runtime_mode,
		dual_grid_terrain,
		vegetation_spread_system,
		plant_system,
		plant_placement_controller
	)
	plant_runtime_coordinator.configure_mode_services(
		run_state,
		production_coordinator,
		research_coordinator,
		oak_warehouse_panel,
		production_building_panel,
		research_center_panel,
		bamboo_mortar_combat_system,
		TERRAIN_NETWORK_BATCH_MAX_CELLS
	)
	plant_runtime_coordinator.next_multiplayer_plant_net_id = _next_multiplayer_plant_net_id
	_prepare_plant_runtime_signal_bindings()
	if not plant_runtime_coordinator.plant_removed_for_target_cleanup.is_connected(
		enemy_coordinator.clear_removed_plant_objective
	):
		plant_runtime_coordinator.plant_removed_for_target_cleanup.connect(
			enemy_coordinator.clear_removed_plant_objective
		)

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
		dual_grid_terrain,
		self,
		tower_plant_gameplay_port
	)
	orange_charging_aura_coordinator.setup(plant_system)
	if not plant_runtime_coordinator.configure_vegetation(placement_rect):
		push_error("TowerDefenseGame: 植被传播节点或地形节点缺失。")
	plant_system.clear_reserved_cells()
	for spawn_offset in MULTIPLAYER_SPAWN_OFFSETS:
		plant_system.reserve_world_position(player_spawn.global_position + spawn_offset)
	if home_gate_controller != null:
		for home_cell in home_gate_controller.get_home_gate_cells():
			plant_system.reserve_cell(home_cell)
	for spawn_point in enemy_coordinator.enemy_spawn_points:
		plant_system.reserve_world_position(spawn_point.global_position, 1)
	if merchant != null:
		plant_system.reserve_world_position(merchant.global_position)
	if luoxi_merchant != null:
		plant_system.reserve_world_position(luoxi_merchant.global_position)
	if not plant_system.plant_removed.is_connected(_on_plant_removed):
		plant_system.plant_removed.connect(_on_plant_removed)

	if not plant_system.plant_placed.is_connected(_on_runtime_plant_placed):
		plant_system.plant_placed.connect(_on_runtime_plant_placed)


func _configure_plant_placement_coordinator() -> bool:
	if plant_placement_coordinator == null:
		push_error("TowerDefenseGame: 缺少静态 PlantPlacementCoordinator 节点。")
		return false
	if not plant_placement_coordinator.setup(
		plant_placement_controller,
		plant_system,
		plant_runtime_coordinator,
		run_state,
		player,
		session_object_pool,
		settings_panel,
		player_profile_panel,
		debug_collectible_window,
		PLANT_PLACEMENT_PARTICLES_SCENE,
		PLANT_REMOVAL_SMOKE_SCENE,
		int(runtime_mode),
		multiplayer_local_peer_id,
		sandbox_free_building_enabled,
		campaign_coordinator.wave_state
	):
		return false
	return plant_placement_coordinator.is_bound()


func _prepare_plant_runtime_signal_bindings() -> void:
	if not plant_runtime_coordinator.enemy_retarget_requested.is_connected(
		enemy_coordinator.request_retarget
	):
		plant_runtime_coordinator.enemy_retarget_requested.connect(
			enemy_coordinator.request_retarget
		)
	if not plant_runtime_coordinator.progression_plant_placed.is_connected(
		campaign_coordinator.track_progression_plant_placement
	):
		plant_runtime_coordinator.progression_plant_placed.connect(
			campaign_coordinator.track_progression_plant_placement
		)
func _on_runtime_plant_placed(plant: PlantDefense) -> void:
	plant_runtime_coordinator.set_runtime_mode(runtime_mode)
	plant_runtime_coordinator.handle_plant_placed(plant)


func _on_plant_terrain_decay_timer_timeout() -> void:
	plant_runtime_coordinator.set_runtime_mode(runtime_mode)
	plant_runtime_coordinator.apply_unsupported_terrain_damage_tick()


func _update_plant_placement_input_state() -> void:
	if plant_placement_coordinator != null:
		plant_placement_coordinator.set_flow_state(
			campaign_coordinator.wave_state
		)


func _refresh_player_modal_ui_lock() -> void:
	if plant_placement_coordinator != null:
		plant_placement_coordinator.refresh_interaction_state()


func _has_exclusive_modal_open() -> bool:
	return (
		plant_placement_coordinator != null
		and plant_placement_coordinator.has_exclusive_modal_open()
	)


func _cancel_plant_placement() -> void:
	if plant_placement_coordinator != null:
		plant_placement_coordinator.cancel_placement()


func begin_inventory_building_placement(
	slot_index: int,
	expected_inventory_revision: int = -1
) -> bool:
	return (
		plant_placement_coordinator != null
		and plant_placement_coordinator.begin_inventory_building_placement(
			slot_index,
			expected_inventory_revision
		)
	)


func _on_personal_inventory_output_committed(peer_id: int) -> void:
	tower_multiplayer_mode_adapter.publish_inventory_changed(peer_id)


func request_multiplayer_plant_placement(
	requester_peer_id: int,
	request_id: int,
	plant_id: StringName,
	anchor: Vector2i
) -> void:
	var placement_player := get_player_for_peer(requester_peer_id)
	_prepare_plant_runtime_signal_bindings()
	plant_runtime_coordinator.set_runtime_mode(runtime_mode)
	plant_runtime_coordinator.request_multiplayer_free_placement(
		requester_peer_id,
		request_id,
		plant_id,
		anchor,
		placement_player,
		campaign_coordinator.wave_state == CombatFlowState.State.FATE_INTERLUDE,
		sandbox_free_building_enabled
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
	var placement_player := get_player_for_peer(requester_peer_id)
	_prepare_plant_runtime_signal_bindings()
	plant_runtime_coordinator.set_runtime_mode(runtime_mode)
	plant_runtime_coordinator.request_multiplayer_inventory_placement(
		requester_peer_id,
		request_id,
		plant_id,
		anchor,
		slot_index,
		expected_inventory_revision,
		item_config_path,
		run_state,
		placement_player,
		campaign_coordinator.wave_state == CombatFlowState.State.FATE_INTERLUDE
	)


func _on_plant_removed(plant: PlantDefense) -> void:
	plant_runtime_coordinator.set_runtime_mode(runtime_mode)
	plant_runtime_coordinator.handle_plant_removed(plant)


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
	var owner := get_player_for_peer(owner_peer_id)
	plant_runtime_coordinator.set_runtime_mode(runtime_mode)
	plant_runtime_coordinator.apply_remote_plant_spawn(
		request_id,
		owner,
		net_id,
		plant_id,
		anchor,
		current_health,
		maximum_health,
		health_revision
	)


func apply_remote_plant_health(
	net_id: int,
	current_health: int,
	maximum_health: int,
	health_revision: int
) -> void:
	plant_runtime_coordinator.set_runtime_mode(runtime_mode)
	plant_runtime_coordinator.apply_remote_plant_health(
		net_id, current_health, maximum_health, health_revision
	)


func apply_remote_plant_removed(net_id: int) -> void:
	apply_remote_plant_removed_with_reason(net_id, false)


func apply_remote_plant_removed_with_reason(
	net_id: int,
	was_destroyed: bool
) -> void:
	plant_runtime_coordinator.set_runtime_mode(runtime_mode)
	plant_runtime_coordinator.apply_remote_plant_removed(net_id, was_destroyed, false)


func apply_remote_plant_removed_silently(net_id: int) -> void:
	plant_runtime_coordinator.set_runtime_mode(runtime_mode)
	plant_runtime_coordinator.apply_remote_plant_removed(net_id, false, true)


func apply_remote_plant_placement_rejected(request_id: int, _reason: StringName) -> void:
	plant_runtime_coordinator.set_runtime_mode(runtime_mode)
	plant_runtime_coordinator.apply_remote_placement_rejected(request_id)


func has_multiplayer_plant(net_id: int) -> bool:
	return plant_runtime_coordinator.has_multiplayer_plant(net_id)


func get_multiplayer_plant_node(net_id: int) -> PlantDefense:
	return plant_runtime_coordinator.get_multiplayer_plant(net_id)


func get_multiplayer_plant_snapshots() -> Array[Dictionary]:
	return plant_runtime_coordinator.get_multiplayer_plant_snapshots()


func get_multiplayer_terrain_snapshot() -> Dictionary:
	return plant_runtime_coordinator.get_terrain_snapshot()


func apply_remote_terrain_snapshot(
	revision: int,
	cell_xy: PackedInt32Array,
	terrain_types: PackedInt32Array
) -> bool:
	plant_runtime_coordinator.set_runtime_mode(runtime_mode)
	return plant_runtime_coordinator.apply_remote_terrain_snapshot(
		revision, cell_xy, terrain_types
	)


func apply_remote_terrain_delta(
	revision: int,
	cell_xy: PackedInt32Array,
	terrain_types: PackedInt32Array
) -> bool:
	plant_runtime_coordinator.set_runtime_mode(runtime_mode)
	return plant_runtime_coordinator.apply_remote_terrain_delta(
		revision, cell_xy, terrain_types
	)


func _on_authoritative_vegetation_terrain_changed(
	cell_xy: PackedInt32Array,
	terrain_types: PackedInt32Array
) -> void:
	plant_runtime_coordinator.set_runtime_mode(runtime_mode)
	plant_runtime_coordinator.apply_authoritative_terrain_changes(
		cell_xy, terrain_types, TERRAIN_NETWORK_BATCH_MAX_CELLS
	)


func _is_valid_terrain_payload(
	cell_xy: PackedInt32Array,
	terrain_types: PackedInt32Array
) -> bool:
	return plant_runtime_coordinator.is_valid_terrain_payload(cell_xy, terrain_types)


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


func _apply_initial_player_xirang() -> void:
	player_roster_coordinator.local_player = player
	player_roster_coordinator.apply_initial_player_xirang()


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


func _register_research_players() -> void:
	player_roster_coordinator.local_player = player
	player_roster_coordinator.register_research_players()


func _on_currency_hud_settings_requested() -> void:
	if player_profile_panel.is_open():
		player_profile_panel.close()
	settings_panel.open()


func _on_currency_hud_profile_requested() -> void:
	if settings_panel.is_open():
		settings_panel.close()
	player_profile_panel.open()


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
	debug_collectible_window.toggle()


func grant_debug_collectible(config_path: String) -> bool:
	return tower_multiplayer_mode_adapter.grant_debug_collectible(config_path)


func show_debug_collectible_grant_result(config_path: String, success: bool) -> void:
	tower_multiplayer_mode_adapter.show_debug_collectible_grant_result(
		config_path, success
	)


func allows_debug_collectible_grants() -> bool:
	return tower_multiplayer_mode_adapter.allows_debug_collectible_grants()


func show_simple_crafting_result(
	recipe_id: StringName,
	result: StringName,
	request_token: int
) -> void:
	tower_multiplayer_mode_adapter.show_simple_crafting_result(
		recipe_id, result, request_token
	)


func apply_remote_merchant_active(active: bool) -> void:
	tower_multiplayer_mode_adapter.apply_remote_merchant_active(active)


func apply_remote_flow_state(step_id: StringName, state: int, seconds: int) -> void:
	tower_multiplayer_mode_adapter.apply_remote_flow_state(step_id, state, seconds)


func _on_remote_flow_state_applied(
	_step_id: StringName,
	_state: CombatFlowState.State,
	_seconds: int
) -> void:
	pass

func get_flow_state_snapshot() -> Dictionary:
	return tower_multiplayer_mode_adapter.get_flow_state_snapshot()


func apply_remote_boss_started(net_id: int, boss_config: BossConfig, spawn_position: Vector2) -> void:
	tower_multiplayer_mode_adapter.apply_remote_boss_started(
		net_id, boss_config, spawn_position
	)


func _instantiate_remote_linglan_boss_proxy(
	net_id: int,
	boss_config: BossConfig,
	spawn_position: Vector2
) -> LinglanBoss:
	return boss_coordinator.instantiate_remote_proxy(
		net_id, boss_config, spawn_position
	)


func apply_remote_victory() -> void:
	tower_multiplayer_mode_adapter.apply_remote_victory()


func apply_remote_enemy_count(alive_count: int) -> void:
	tower_multiplayer_mode_adapter.apply_remote_enemy_count(alive_count)



func apply_remote_defeat() -> void:
	tower_multiplayer_mode_adapter.apply_remote_defeat()


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
	return tower_multiplayer_mode_adapter.try_purchase_skill1_for_peer(peer_id)


func apply_skill1_purchase_state(
	peer_id: int,
	current_xirang: int,
	skill1_unlocked: bool,
	skill1_upgrade_level: int = -1,
	skill1_charge_duration: float = -1.0
) -> void:
	tower_multiplayer_mode_adapter.apply_skill1_purchase_state(
		peer_id,
		current_xirang,
		skill1_unlocked,
		skill1_upgrade_level,
		skill1_charge_duration
	)


func show_local_skill1_purchase_result(result_code: int) -> void:
	tower_multiplayer_mode_adapter.show_local_skill1_purchase_result(result_code)


func player_has_luoxi_special_ticket(player_instance: Player) -> bool:
	if player_instance == null or luoxi_special_game_coordinator == null:
		return false
	return luoxi_special_game_coordinator.player_has_ticket(
		player_instance.peer_id if player_instance.peer_id > 0 else 0
	)


func supports_luoxi_special_game() -> bool:
	return tower_multiplayer_mode_adapter.runtime_supports_luoxi_special_game()


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
	return tower_multiplayer_mode_adapter.runtime_try_start_luoxi_special_game_for_peer(
		peer_id
	)


func try_reveal_luoxi_special_game_card_for_peer(
	peer_id: int,
	session_revision: int,
	card_index: int
) -> Dictionary:
	return tower_multiplayer_mode_adapter.runtime_try_reveal_luoxi_special_game_card_for_peer(
		peer_id,
		session_revision,
		card_index
	)


func try_finish_luoxi_special_game_for_peer(
	peer_id: int,
	session_revision: int
) -> Dictionary:
	return tower_multiplayer_mode_adapter.runtime_try_finish_luoxi_special_game_for_peer(
		peer_id,
		session_revision
	)


func cancel_luoxi_special_game_for_peer(peer_id: int) -> void:
	tower_multiplayer_mode_adapter.cancel_luoxi_special_game_for_peer(peer_id)


func show_local_luoxi_special_game_started(result: Dictionary) -> void:
	tower_multiplayer_mode_adapter.show_local_luoxi_special_game_started(result)


func show_local_luoxi_special_game_card_revealed(result: Dictionary) -> void:
	tower_multiplayer_mode_adapter.show_local_luoxi_special_game_card_revealed(
		result
	)


func show_local_luoxi_special_game_finished(result: Dictionary) -> void:
	tower_multiplayer_mode_adapter.show_local_luoxi_special_game_finished(result)


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
	var tower_adapter := (
		multiplayer_mode_adapter as TowerDefenseMultiplayerModeAdapter
	)
	if tower_adapter == null:
		push_error("TowerDefenseGame: 多人洛茜直接扣血缺少主机复制入口。")
		return 0
	return tower_adapter.apply_luoxi_player_health_loss(
		target_player,
		amount,
		minimum_health
	)


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
	return tower_multiplayer_mode_adapter.runtime_try_refresh_luoxi_collectibles_for_peer(
		peer_id
	)


func get_luoxi_collectible_refresh_count(peer_id: int) -> int:
	return tower_multiplayer_mode_adapter.runtime_get_luoxi_collectible_refresh_count(
		peer_id
	)


func try_claim_luoxi_collectible_for_peer(peer_id: int, config_path_or_choice: Variant) -> int:
	return tower_multiplayer_mode_adapter.runtime_try_claim_luoxi_collectible_for_peer(
		peer_id,
		config_path_or_choice
	)


func _resolve_luoxi_collectible_path(choice_index: int, config_path: String) -> String:
	if not config_path.is_empty():
		return config_path
	var item := LuoxiMerchant.get_collectible_for_choice(choice_index)
	return item.resource_path if item != null else ""


func has_luoxi_collectible_claimed(peer_id: int) -> bool:
	return tower_multiplayer_mode_adapter.runtime_has_luoxi_collectible_claimed(peer_id)


func get_luoxi_collectible_claim_count(peer_id: int) -> int:
	return tower_multiplayer_mode_adapter.runtime_get_luoxi_collectible_claim_count(
		peer_id
	)


func record_luoxi_collectible_claim(peer_id: int) -> void:
	tower_multiplayer_mode_adapter.runtime_record_luoxi_collectible_claim(peer_id)


func mark_luoxi_collectible_claimed(peer_id: int) -> void:
	tower_multiplayer_mode_adapter.runtime_mark_luoxi_collectible_claimed(peer_id)


func show_local_luoxi_collectible_result(result_code: int) -> void:
	tower_multiplayer_mode_adapter.show_local_luoxi_collectible_result(result_code)


func show_local_luoxi_refresh_result(
	result_code: int,
	refresh_count: int,
	current_xirang: int
) -> void:
	tower_multiplayer_mode_adapter.show_local_luoxi_refresh_result(
		result_code,
		refresh_count,
		current_xirang
	)


func request_tower_defense_wave_start(requester_peer_id: int = 0) -> bool:
	return campaign_coordinator.request_wave_start(requester_peer_id)


func _set_merchant_active(active: bool) -> void:
	tower_multiplayer_mode_adapter.set_merchant_active(active)


func _set_local_merchants_active(active: bool) -> bool:
	return tower_multiplayer_mode_adapter.set_local_merchants_active(active)


func _configure_boss_coordinator() -> bool:
	if boss_coordinator == null:
		push_error("TowerDefenseGame: 缺少静态 BossCoordinator 节点。")
		return false
	boss_coordinator.setup(
		self,
		linglan_boss_enabled,
		boss_container,
		enemy_container,
		linglan_boss_runtime_port,
		ground_tile_map_layer,
		campaign_coordinator,
		enemy_coordinator,
		home_defense_coordinator,
		player_roster_coordinator,
		grid_pathfinder,
		random_generator
	)
	boss_coordinator.linglan_boss_started = _linglan_boss_started
	boss_coordinator.active_boss_config = _active_boss_config
	boss_coordinator.linglan_boss = _linglan_boss
	boss_coordinator.linglan_boss_intro_vfx = _linglan_boss_intro_vfx
	boss_coordinator.boss_health_hud = _boss_health_hud
	boss_coordinator.linglan_skill4_orb_anchor_global_position = (
		_linglan_skill4_orb_anchor_global_position
	)
	boss_coordinator.linglan_skill4_orb_authored_center = (
		_linglan_skill4_orb_authored_center
	)
	boss_coordinator.linglan_skill4_orb_anchor_valid = _linglan_skill4_orb_anchor_valid
	boss_coordinator.linglan_slime_configs = _linglan_slime_configs
	boss_coordinator.linglan_enrage_sniper_config = _linglan_enrage_sniper_config
	boss_coordinator.runtime_scene_loads_requested = _boss_runtime_scene_loads_requested
	boss_coordinator.runtime_resources_by_path = _boss_runtime_resources_by_path
	if not boss_coordinator.is_bound():
		push_error("TowerDefenseGame: BossCoordinator 依赖绑定不完整。")
		return false
	boss_coordinator.configure_existing_runtime_nodes()
	return true


func _configure_linglan_boss() -> void:
	if boss_coordinator != null and boss_coordinator.is_bound():
		boss_coordinator.configure_existing_runtime_nodes()


func _cache_linglan_slime_configs() -> void:
	boss_coordinator.cache_slime_configs()


func get_linglan_enrage_sniper_config() -> EnemyConfig:
	return boss_coordinator.get_enrage_sniper_config()


func _deferred_request_boss_runtime_scene_loads() -> void:
	if prewarmer_coordinator != null:
		await prewarmer_coordinator.schedule_boss_runtime_scene_loads()


func _get_first_boss_config() -> Resource:
	return boss_coordinator.get_first_boss_config()


func _get_configured_bosses() -> Array[BossConfig]:
	return boss_coordinator.get_configured_bosses()


func _boss_config_has_required_data(boss_config: Resource) -> bool:
	return boss_coordinator.boss_config_has_required_data(boss_config as BossConfig)


func _get_boss_enemy_config(boss_config: Resource) -> EnemyConfig:
	return boss_coordinator.get_boss_enemy_config(boss_config as BossConfig)


func _get_boss_enemy_config_path(boss_config: Resource) -> String:
	return boss_coordinator.get_boss_enemy_config_path(boss_config as BossConfig)


func _get_boss_arena_center(boss_config: Resource) -> Vector2:
	return boss_coordinator.get_boss_arena_center(boss_config as BossConfig)


func _get_linglan_spawn_global_position(boss_config: Resource) -> Vector2:
	return boss_coordinator.get_linglan_spawn_global_position(boss_config as BossConfig)


func _get_boss_arena_floor_rect(boss_config: Resource) -> Rect2i:
	return boss_coordinator.get_boss_arena_floor_rect(boss_config as BossConfig)


func _get_boss_floor_source_id(boss_config: Resource) -> int:
	return boss_coordinator.get_boss_floor_source_id(boss_config as BossConfig)


func _get_boss_floor_atlas_coords(boss_config: Resource) -> Vector2i:
	return boss_coordinator.get_boss_floor_atlas_coords(boss_config as BossConfig)


func _should_clear_boss_inner_overlay_cells(boss_config: Resource) -> bool:
	return boss_coordinator.should_clear_boss_inner_overlay_cells(boss_config as BossConfig)


func _get_boss_display_name(boss_config: Resource) -> String:
	return boss_coordinator.get_boss_display_name(boss_config as BossConfig)


func _get_boss_intro_vfx_scene_path(boss_config: Resource) -> String:
	return boss_coordinator.get_boss_intro_vfx_scene_path(boss_config as BossConfig)


func _get_boss_hud_scene_path(boss_config: Resource) -> String:
	return boss_coordinator.get_boss_hud_scene_path(boss_config as BossConfig)


func _ensure_linglan_boss_runtime_nodes(boss_config: Resource) -> bool:
	return boss_coordinator.ensure_runtime_nodes(boss_config as BossConfig)


func _ensure_boss_health_hud_runtime_node(boss_config: Resource) -> bool:
	return boss_coordinator.ensure_health_hud(boss_config as BossConfig)


func _configure_enemy_coordinator() -> void:
	enemy_coordinator.setup(
		self,
		campaign_coordinator,
		player_roster_coordinator,
		plant_runtime_coordinator,
		random_generator,
		enemy_container,
		boss_container,
		enemy_spawn_points_root,
		ground_tile_map_layer,
		tower_grid_pathfinder,
		enemy_spawn_timer,
		multiplayer_gateway,
		fate_coordinator,
		presentation_coordinator,
		session_object_pool,
		ENEMY_SPAWN_EFFECT_SCENE
	)


func _configure_timers() -> void:
	enemy_spawn_timer.one_shot = false
	state_timer.one_shot = false
	state_timer.wait_time = 1.0
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


func prepare_shared_runtime_data_and_complete() -> void:
	if prewarmer_coordinator != null:
		await prewarmer_coordinator.prepare_shared_runtime_data_and_complete()


func _can_continue_runtime_prewarm() -> bool:
	return not runtime_prewarm_tearing_down and is_inside_tree()


func _schedule_enemy_navigation_prewarm() -> void:
	if prewarmer_coordinator != null:
		prewarmer_coordinator.schedule_enemy_navigation_prewarm()


func _configure_xiaocong_fate_flow() -> bool:
	if fate_flow_coordinator == null:
		push_error("TowerDefenseGame: 缺少静态 FateFlowCoordinator 节点。")
		return false
	fate_flow_coordinator.setup(
		self,
		campaign_coordinator,
		fate_coordinator,
		fate_manager,
		xiaocong_fate_interlude,
		enemy_spawn_timer,
		state_timer,
		plant_terrain_decay_timer,
		production_coordinator,
		research_coordinator,
		plant_placement_controller,
		wave_hud,
		tower_defense_status_hud,
		tower_defense_minimap,
		player_spawn
	)
	if not fate_flow_coordinator.is_bound():
		push_error("TowerDefenseGame: FateFlowCoordinator 依赖绑定失败。")
		return false
	return true


func _resume_flow_after_fate_interlude(next_step_id: StringName) -> void:
	campaign_coordinator.resume_flow_after_fate_interlude(next_step_id)


func request_xiaocong_interaction(peer_id: int) -> void:
	tower_multiplayer_mode_adapter.request_xiaocong_interaction(peer_id)


func request_xiaocong_fate_vote(
	peer_id: int,
	option_id: StringName,
	permanent_buff_id: StringName
) -> void:
	tower_multiplayer_mode_adapter.request_xiaocong_fate_vote(
		peer_id,
		option_id,
		permanent_buff_id
	)


func request_xiaocong_collectible_choice(peer_id: int, choice_index: int) -> void:
	tower_multiplayer_mode_adapter.request_xiaocong_collectible_choice(
		peer_id,
		choice_index
	)


func _is_fate_collectible_choice_pending_for_peer(peer_id: int) -> bool:
	return (
		fate_flow_coordinator != null
		and fate_flow_coordinator.is_collectible_choice_pending_for_peer(peer_id)
	)


func get_xiaocong_fate_state_snapshot() -> Dictionary:
	return tower_multiplayer_mode_adapter.get_xiaocong_fate_state_snapshot()


func apply_remote_xiaocong_fate_state(state: Dictionary) -> void:
	tower_multiplayer_mode_adapter.apply_remote_xiaocong_fate_state(state)

func _enter_xiaocong_fate_interlude(next_step: FlowStepConfig) -> void:
	if fate_flow_coordinator != null:
		fate_flow_coordinator.enter_interlude(next_step)


func _set_fate_interlude_systems_frozen(frozen: bool) -> void:
	if fate_flow_coordinator != null:
		fate_flow_coordinator.set_interlude_systems_frozen(frozen)


func _set_fate_player_combat_locked(locked: bool) -> void:
	if fate_flow_coordinator != null:
		fate_flow_coordinator.set_player_combat_locked(locked)


func _teleport_fate_player_authoritatively(
	peer_id: int,
	player_instance: Player,
	target_position: Vector2
) -> void:
	if runtime_mode == RuntimeMode.HOST_AUTHORITY:
		if not multiplayer_gateway.player_teleport_requested.has_connections():
			push_error("TowerDefenseGame: 多人权威传送缺少 MPGame 处理器。")
			return
		multiplayer_gateway.player_teleport_requested.emit(peer_id, target_position)
		return
	player_instance.global_position = target_position
	player_instance.velocity = Vector2.ZERO
	player_instance.reset_physics_interpolation()


func _on_xiaocong_fate_interlude_completed(next_step_id: StringName) -> void:
	if fate_flow_coordinator != null:
		fate_flow_coordinator._on_interlude_completed(next_step_id)


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
		campaign_coordinator.record_xirang_reward(rewarded_amount)
	return accepted


func _is_fate_double_xirang_reward_active() -> bool:
	return fate_coordinator != null and fate_coordinator.is_double_xirang_reward_active()


func spawn_linglan_skill2_enemies(
	enemy_config: EnemyConfig,
	marker_names: Array[StringName]
) -> void:
	boss_coordinator.spawn_skill2_enemies(enemy_config, marker_names)


func spawn_linglan_random_slime(spawn_position: Vector2) -> void:
	boss_coordinator.spawn_random_slime(spawn_position)


func spawn_linglan_airdrop_sniper(
	enemy_config: EnemyConfig,
	warning_scene: PackedScene,
	warning_duration: float,
	drop_height: float,
	drop_duration: float
) -> void:
	boss_coordinator.spawn_airdrop_sniper(
		enemy_config,
		warning_scene,
		warning_duration,
		drop_height,
		drop_duration
	)


func _show_tower_defense_boss_progress(defeated: int, total: int) -> void:
	presentation_coordinator.show_boss_progress(defeated, total)


func get_progression_metrics_snapshot() -> Dictionary:
	return campaign_coordinator.get_progression_metrics_snapshot()


func _complete_defeat_presentation() -> void:
	campaign_coordinator.complete_defeat_presentation()


func _begin_linglan_boss_intro(boss_config: BossConfig = null) -> void:
	boss_coordinator.begin_intro(boss_config)


func _on_linglan_boss_intro_finished() -> void:
	boss_coordinator.finish_intro()


func _activate_linglan_boss() -> void:
	boss_coordinator.activate_boss()


func _rebroadcast_linglan_boss_started_after_sync_window(
	boss_net_id: int,
	boss_config: BossConfig
) -> void:
	if boss_net_id <= 0 or boss_config == null:
		return
	await get_tree().create_timer(0.75).timeout
	if runtime_mode != RuntimeMode.HOST_AUTHORITY:
		return
	if campaign_coordinator.wave_state != CombatFlowState.State.BOSS_ACTIVE:
		return
	if linglan_boss == null or not is_instance_valid(linglan_boss):
		return
	multiplayer_mode_adapter.boss_started.emit(boss_net_id, boss_config, linglan_boss.global_position)


func _emit_tower_boss_started_authoritatively(
	boss_net_id: int,
	boss_config: BossConfig,
	spawn_position: Vector2
) -> void:
	if runtime_mode != RuntimeMode.HOST_AUTHORITY:
		return
	multiplayer_mode_adapter.boss_started.emit(
		boss_net_id, boss_config, spawn_position
	)
	_rebroadcast_linglan_boss_started_after_sync_window(boss_net_id, boss_config)


func _on_linglan_boss_defeated(enemy: Enemy) -> void:
	boss_coordinator.handle_boss_defeated(enemy)


func _complete_linglan_boss_after_delay() -> void:
	boss_coordinator.complete_boss_after_delay()


func _remove_remaining_boss_adds() -> void:
	boss_coordinator.remove_remaining_adds()


func _prepare_linglan_boss_arena(boss_config: Resource) -> void:
	boss_coordinator.prepare_arena(boss_config as BossConfig)


func consume_next_player_respawn_delay(peer_id: int) -> float:
	return tower_multiplayer_mode_adapter.consume_next_player_respawn_delay(peer_id)


func update_player_respawn_countdown(peer_id: int, seconds_left: int) -> void:
	tower_multiplayer_mode_adapter.update_player_respawn_countdown(
		peer_id,
		seconds_left
	)


func clear_player_respawn_countdown(peer_id: int) -> void:
	tower_multiplayer_mode_adapter.clear_player_respawn_countdown(peer_id)


func _reset_player_wave_death_counts() -> void:
	player_roster_coordinator.reset_wave_death_counts()


func _force_revive_dead_players(emit_multiplayer: bool = true) -> void:
	player_roster_coordinator.local_player = player
	player_roster_coordinator.set_runtime_identity(runtime_mode, multiplayer_local_peer_id)
	player_roster_coordinator.force_revive_dead_players(emit_multiplayer)


func _update_singleplayer_respawn(delta: float) -> void:
	player_roster_coordinator.local_player = player
	player_roster_coordinator.update_singleplayer_respawn(delta)


func _begin_local_spectator_camera() -> void:
	presentation_coordinator.begin_local_spectator_camera(player)


func _end_local_spectator_camera() -> void:
	presentation_coordinator.end_local_spectator_camera(player)


func _update_local_spectator_camera(delta: float) -> void:
	presentation_coordinator.update_local_spectator_camera(delta)


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
	player_roster_coordinator.set_runtime_identity(
		runtime_mode, multiplayer_local_peer_id
	)
	player = player_roster_coordinator.configure_multiplayer_players()


func _get_multiplayer_spawn_offset(index: int) -> Vector2:
	return MULTIPLAYER_SPAWN_OFFSETS[index % MULTIPLAYER_SPAWN_OFFSETS.size()]


func apply_network_input_for_peer(
	peer_id: int,
	move_input: Vector2,
	shoot_input: Vector2,
	use_skill1: bool,
	use_reload: bool = false
) -> void:
	player_roster_coordinator.apply_network_input_for_peer(
		peer_id, move_input, shoot_input, use_skill1, use_reload
	)


func _update_multiplayer_remote_player_passive_state(delta: float) -> void:
	player_roster_coordinator.update_remote_passive_state(delta)


func remove_multiplayer_player(peer_id: int) -> void:
	tower_multiplayer_mode_adapter.remove_multiplayer_player(peer_id)


func restore_multiplayer_player(
	old_peer_id: int,
	new_peer_id: int,
	player_name: String,
	character_id: StringName,
	state: SnapshotManager.PlayerState,
	spawn_slot_index: int,
	reconnect_state: Dictionary = {}
) -> Player:
	return tower_multiplayer_mode_adapter.restore_multiplayer_player(
		old_peer_id,
		new_peer_id,
		player_name,
		character_id,
		state,
		spawn_slot_index,
		reconnect_state
	)


func get_player_for_peer(peer_id: int) -> Player:
	if player_roster_coordinator != null and player_roster_coordinator.is_bound():
		return player_roster_coordinator.get_player(peer_id)
	# Narrow pre-tree/fixture façade: `TowerDefenseGame.new()` has not yet
	# resolved its statically authored coordinator child.
	return peer_players.get(peer_id) as Player


func get_enemy_for_net_id(net_id: int) -> Enemy:
	var enemy := enemy_coordinator.get_enemy(net_id)
	if enemy == null:
		unregister_combat_target(net_id)
	return enemy


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
		multiplayer_gateway.pickup_spawned.emit(net_id, pickup.config, pickup.global_position)


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
	multiplayer_gateway.pickup_collected.emit(
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
	multiplayer_gateway.pickup_removed.emit(net_id)
	return true


func collect_player_snapshot_states() -> Array[SnapshotManager.PlayerState]:
	if player_roster_coordinator != null and player_roster_coordinator.is_bound():
		return player_roster_coordinator.collect_snapshot_states()
	# Explicit tree-less fixture path: retain the same stateless serializer
	# without dynamically constructing an orchestration node.
	return TowerDefensePlayerRosterCoordinator.collect_snapshot_states_from(
		peer_players
	)


func collect_enemy_snapshot_states() -> Array[SnapshotManager.EnemyState]:
	return enemy_coordinator.collect_snapshot_states()


func find_nearest_enemy_attack_target_world(
	from_position: Vector2,
	max_distance: float,
	excluded_instance_ids: Dictionary = {}
) -> Node2D:
	var neutral_target := super.find_nearest_enemy_attack_target_world(
		from_position,
		max_distance,
		excluded_instance_ids
	)
	return plant_runtime_coordinator.find_nearest_enemy_attack_target_world(
		from_position,
		max_distance,
		excluded_instance_ids,
		neutral_target
	)


func get_linglan_skill2_target_global_position(target_cell: Vector2i) -> Vector2:
	return boss_coordinator.get_skill_target_global_position(target_cell)


func get_linglan_skill3_target_global_position(target_cell: Vector2i) -> Vector2:
	return boss_coordinator.get_skill_target_global_position(target_cell)


func get_linglan_skill4_target_global_position(
	target_cell_a: Vector2i,
	target_cell_b: Vector2i
) -> Vector2:
	return boss_coordinator.get_skill4_target_global_position(
		target_cell_a, target_cell_b
	)


func get_linglan_skill4_laser_bounds(
	left_cell_x: int,
	right_cell_x: int,
	top_cell_y: int,
	bottom_cell_y: int,
	inward_cell_distance: int
) -> Dictionary:
	return boss_coordinator.get_skill4_laser_bounds(
		left_cell_x,
		right_cell_x,
		top_cell_y,
		bottom_cell_y,
		inward_cell_distance
	)


func get_linglan_skill4_orb_spawn_global_position(x_cell: int, y_cell: int) -> Vector2:
	return boss_coordinator.get_skill4_orb_spawn_global_position(x_cell, y_cell)


func get_linglan_skill2_target_player(from_position: Vector2) -> Player:
	return boss_coordinator.get_skill2_target_player(from_position)


func _is_flow_system_ready() -> bool:
	if campaign_coordinator.flow_graph == null:
		push_error("TowerDefenseGame 当前 Campaign 没有配置 FlowGraphConfig。")
		return false
	if not _is_spawn_system_ready():
		return false
	var errors := campaign_coordinator.validate_flow_graph()
	for error in errors:
		push_warning(error)
	if not errors.is_empty():
		return false
	return _get_start_flow_step() != null


func _get_start_flow_step() -> FlowStepConfig:
	return campaign_coordinator.get_start_flow_step()


func _get_flow_step_by_id(step_id: StringName) -> FlowStepConfig:
	return campaign_coordinator.get_flow_step_by_id(step_id)


func _get_flow_step_id(flow_step: FlowStepConfig) -> StringName:
	return campaign_coordinator.get_flow_step_id(flow_step)


func _get_default_next_flow_step(flow_step: FlowStepConfig) -> FlowStepConfig:
	return campaign_coordinator.get_default_next_flow_step(flow_step)


func _get_wave_number_for_step(wave_config: WaveConfig) -> int:
	return campaign_coordinator.get_wave_number_for_step(
		wave_config,
		campaign_coordinator.current_wave_index
	)


func _emit_multiplayer_flow_state(state: CombatFlowState.State) -> void:
	tower_multiplayer_mode_adapter.publish_flow_state(state)


func _play_remote_boss_intro(boss_config: BossConfig) -> void:
	boss_coordinator.play_remote_intro(boss_config)


func _on_remote_linglan_boss_intro_finished() -> void:
	boss_coordinator.finish_intro()


func _restore_remote_camera_if_boss_intro_complete() -> void:
	boss_coordinator.restore_remote_camera_if_intro_complete()


func _focus_camera_on_boss_intro(boss_position: Vector2) -> void:
	presentation_coordinator.focus_camera_on_boss_intro(boss_position)


func _restore_camera_after_boss_intro() -> void:
	presentation_coordinator.restore_camera_after_boss_intro(player)


func _is_spawn_system_ready() -> bool:
	return enemy_coordinator.is_spawn_system_ready()


func play_remote_enemy_spawn_effect(spawn_global_position: Vector2) -> void:
	enemy_coordinator.spawn_enemy_spawn_effect(spawn_global_position)


func _play_countdown_tick() -> void:
	presentation_coordinator.play_countdown_tick()


func _play_client_countdown_tick_if_new(
	state: CombatFlowState.State,
	step_id: StringName,
	seconds: int
) -> void:
	presentation_coordinator.play_client_countdown_tick_if_new(
		state,
		step_id,
		seconds
	)


func _update_wave_music(wave_config: WaveConfig) -> void:
	presentation_coordinator.update_wave_music(wave_config)


func _update_post_wave_music(flow_step: FlowStepConfig) -> void:
	presentation_coordinator.update_post_wave_music(flow_step)


func _update_boss_music(boss_config: BossConfig) -> void:
	presentation_coordinator.update_boss_music(boss_config)


func pause_all_background_music() -> void:
	presentation_coordinator.pause_all_background_music()


func _stop_background_music_for_defeat() -> void:
	presentation_coordinator.stop_background_music_for_defeat()


func _play_music_stream(
	stream: AudioStream,
	volume_db: float,
	loop_offset: float = 0.0,
	fade_in: bool = false
) -> void:
	presentation_coordinator.play_music_stream(
		stream,
		volume_db,
		loop_offset,
		fade_in
	)


func _stop_music_fade_tween() -> void:
	presentation_coordinator.stop_music_fade_tween()


func _configure_music_loop(stream: AudioStream, loop_offset: float) -> void:
	presentation_coordinator.configure_music_loop(stream, loop_offset)


func _audio_stream_has_property(stream: AudioStream, property_name: StringName) -> bool:
	return presentation_coordinator.audio_stream_has_property(
		stream,
		property_name
	)


func _pause_background_music_players(root_node: Node) -> void:
	presentation_coordinator.pause_background_music_players(root_node)


func _is_background_music_player(node: Node) -> bool:
	return presentation_coordinator.is_background_music_player(node)
