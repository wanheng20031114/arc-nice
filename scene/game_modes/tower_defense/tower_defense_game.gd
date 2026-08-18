extends CombatRuntimeBase
class_name TowerDefenseGame

const PLANT_PLACEMENT_PARTICLES_SCENE := preload(
	"res://scene/game_modes/tower_defense/plant/presentation/plant_placement_particles.tscn"
)
const PLANT_REMOVAL_SMOKE_SCENE := preload(
	"res://scene/game_modes/tower_defense/plant/presentation/plant_removal_smoke.tscn"
)
const GUARDIAN_POINT_LIGHT_TEXTURE := preload("res://resources/texture/enemy/yuanshi_insect/guardian_point_light.png")
const PLAYER_RESPAWN_DELAYS: Array[int] = [5, 10, 15, 20]
const PLAYER_RESPAWN_INVINCIBILITY_SECONDS := 3.0
const DEFAULT_BASE_HEALTH := 100
const FORMAL_PROGRESSION_CONFIG_PATH := (
	"res://resources/config/campaigns/tower_defense/formal_progression.tres"
)
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
@onready var plant_runtime_coordinator: TowerDefensePlantRuntimeCoordinator = (
	$PlantRuntimeCoordinator
)
@onready var plant_placement_coordinator: TowerDefensePlantPlacementCoordinator = (
	$PlantPlacementCoordinator
)
@onready var player_roster_coordinator: TowerDefensePlayerRosterCoordinator = (
	$PlayerRosterCoordinator
)
@onready var boss_coordinator: TowerDefenseBossCoordinator = $BossCoordinator
@onready var presentation_coordinator: TowerDefensePresentationCoordinator = (
	$PresentationCoordinator
)
@onready var prewarmer_coordinator: TowerDefensePrewarmerCoordinator = (
	$PrewarmerCoordinator
)
@onready var tower_grid_pathfinder: GridPathfinder = grid_pathfinder as GridPathfinder
@onready var tower_multiplayer_mode_adapter: TowerDefenseMultiplayerModeAdapter = (
	multiplayer_mode_adapter as TowerDefenseMultiplayerModeAdapter
)
@onready var tower_plant_gameplay_port: TowerPlantGameplayPort = (
	$TowerPlantGameplayPort as TowerPlantGameplayPort
)
@onready var pickup_registry: TowerDefensePickupRegistry = (
	$PickupRegistry as TowerDefensePickupRegistry
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
@onready var rogue_exploration_coordinator: TowerDefenseRogueExplorationCoordinator = (
	$RogueExplorationCoordinator
)
@onready var boss_container: Node2D = $BossContainer
@onready var linglan_boss_runtime_port: TowerDefenseLinglanBossRuntimePort = (
	$LinglanBossRuntimePort as TowerDefenseLinglanBossRuntimePort
)
@onready var guardian_aura_system: GuardianAuraSystem = $GuardianAuraSystem
@onready var plant_system: PlantSystem = $PlantSystem
@onready var production_coordinator: ProductionCoordinator = $ProductionCoordinator
@onready var research_coordinator: ResearchCoordinator = $ResearchCoordinator
@onready var plant_placement_controller: PlantPlacementController = $PlantPlacementController
@onready var damage_number_pool: DamageNumberPool = $DamageNumberPool
@onready var session_object_pool: SessionObjectPool = $SessionObjectPool
@onready var bamboo_mortar_combat_system: BambooMortarCombatSystem = (
	$BambooMortarCombatSystem
)
@onready var run_state: RunStateStore = get_node("/root/RunState") as RunStateStore

var random_generator := RandomNumberGenerator.new()
var multiplayer_player_names: Dictionary = {}
var multiplayer_player_character_ids: Dictionary = {}
var multiplayer_spawn_slot_indices: Dictionary[int, int] = {}
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
var navigation_prewarm_requested: bool:
	get:
		return prewarmer_coordinator != null and prewarmer_coordinator.navigation_prewarm_requested
var navigation_prewarmed: bool:
	get:
		return prewarmer_coordinator != null and prewarmer_coordinator.navigation_prewarmed
var plant_lifecycle_shader_prewarmed: bool:
	get:
		return prewarmer_coordinator != null and prewarmer_coordinator.plant_lifecycle_shader_prewarmed
var _physics_interpolation_lease_token := (
	GlobalRuntimePolicyLeaseStore.INVALID_LEASE_TOKEN
)
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
var projectile_pool_registration_ms := 0.0
var runtime_prewarm_tearing_down := false


func _enter_tree() -> void:
	runtime_prewarm_tearing_down = false
	# 全局物理插值由项目级租约统一拥有，塔防退出顺序不会再覆盖 Rogue 的需求。
	var runtime_policy_lease := (
		GlobalRuntimePolicyLeaseStore.get_autoload_instance()
	)
	if runtime_policy_lease == null:
		push_error("TowerDefenseGame: 缺少全局运行策略租约协调器。")
		return
	_physics_interpolation_lease_token = (
		runtime_policy_lease.acquire_physics_interpolation(self, true)
	)
	if (
		_physics_interpolation_lease_token
		== GlobalRuntimePolicyLeaseStore.INVALID_LEASE_TOKEN
	):
		push_error("TowerDefenseGame: 无法获取物理插值租约。")


func _exit_tree() -> void:
	runtime_prewarm_tearing_down = true
	LuoxiMerchant.reset_runtime_choice_count()
	var runtime_policy_lease := (
		GlobalRuntimePolicyLeaseStore.get_autoload_instance()
	)
	if (
		runtime_policy_lease != null
		and _physics_interpolation_lease_token
		!= GlobalRuntimePolicyLeaseStore.INVALID_LEASE_TOKEN
	):
		runtime_policy_lease.release_physics_interpolation(
			_physics_interpolation_lease_token
		)
	_physics_interpolation_lease_token = (
		GlobalRuntimePolicyLeaseStore.INVALID_LEASE_TOKEN
	)


func _ready() -> void:
	var preparation_generation := begin_runtime_preparation(
		"正在初始化塔防运行时…",
		1
	)
	random_generator.randomize()
	initialize_world_lighting()
	if not _configure_player_roster_coordinator():
		_fail_tower_runtime_preparation(preparation_generation, "塔防玩家名册协调器配置失败。")
		return
	if not _configure_pickup_registry():
		_fail_tower_runtime_preparation(preparation_generation, "塔防拾取物注册表配置失败。")
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
		_fail_tower_runtime_preparation(preparation_generation, "塔防昼夜周期配置无效。")
		return
	if not _configure_presentation_coordinator():
		_fail_tower_runtime_preparation(preparation_generation, "塔防表现协调器配置失败。")
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
		_fail_tower_runtime_preparation(preparation_generation, "塔防战役配置无效。")
		return
	if not _configure_prewarmer_coordinator():
		_fail_tower_runtime_preparation(preparation_generation, "塔防预热协调器配置失败。")
		return
	if runtime_mode == RuntimeMode.SINGLEPLAYER:
		run_state.ensure_run_started()
		_configure_singleplayer_player()
	_configure_enemy_coordinator()
	_configure_timers()
	prewarmer_coordinator.register_runtime_object_pools(
		expanded_projectile_pool_prewarm_enabled
	)
	projectile_pool_registration_ms = (
		prewarmer_coordinator.projectile_pool_registration_ms
	)
	# Tower-defense batteries issue independently staggered target queries. Keep
	# its already-validated policy of forcing every bounded query through buckets.
	enable_singleplayer_combat_target_index(true)
	guardian_aura_system.set_authoritative_processing_enabled(
		runtime_mode != RuntimeMode.CLIENT_VIEW
	)
	if runtime_mode != RuntimeMode.SINGLEPLAYER:
		run_state.ensure_run_started()
		run_state.set_active_multiplayer_peer(multiplayer_local_peer_id)
		_configure_multiplayer_players()
		player_roster_coordinator.configure_production_output_peers()
		_register_static_multiplayer_pickups()
	if player == null:
		push_error("TowerDefenseGame: 无法创建当前角色，停止初始化。")
		_fail_tower_runtime_preparation(preparation_generation, "塔防无法创建当前角色。")
		return
	presentation_coordinator.configure_status_hud(int(runtime_mode))
	_attach_camera_to_local_player()
	presentation_coordinator.configure_wave_hud(
		int(runtime_mode),
		home_defense_coordinator.current_base_health,
		home_defense_coordinator.maximum_base_health
	)
	_configure_home_defense()
	if not plant_runtime_coordinator.initialize_authored_runtime(
		runtime_mode,
		self,
		player,
		run_state,
		MULTIPLAYER_SPAWN_OFFSETS
	):
		_fail_tower_runtime_preparation(preparation_generation, "塔防植物运行时配置失败。")
		return
	if not _configure_plant_placement_coordinator():
		_fail_tower_runtime_preparation(preparation_generation, "塔防植物放置协调器配置失败。")
		return
	production_coordinator.set_authoritative_processing_enabled(
		runtime_mode != RuntimeMode.CLIENT_VIEW
	)
	research_coordinator.setup(
		production_coordinator,
		plant_system,
		player_roster_coordinator,
		bamboo_mortar_combat_system
	)
	research_coordinator.set_authoritative_processing_enabled(
		runtime_mode != RuntimeMode.CLIENT_VIEW
	)
	_register_research_players()
	presentation_coordinator.configure_minimap(
		tower_defense_minimap,
		player,
		ground_tile_map_layer,
		dual_grid_terrain,
		overlay_tile_map_layer,
		enemy_container,
		boss_container,
		plant_system
	)
	_apply_initial_player_xirang()
	campaign_coordinator.start_progression_metrics()
	if (
		runtime_mode != RuntimeMode.CLIENT_VIEW
		and not _grant_tower_defense_starting_package()
	):
		push_error("TowerDefenseGame: 无法原子发放正式塔防起步包，停止初始化。")
		_fail_tower_runtime_preparation(preparation_generation, "塔防起步包原子发放失败。")
		return
	presentation_coordinator.configure_player_ui(
		int(runtime_mode),
		player,
		research_coordinator,
		currency_hud,
		player_profile_panel,
		settings_panel,
		debug_collectible_window,
		tower_multiplayer_mode_adapter
	)
	luoxi_special_game_coordinator.setup(
		campaign_coordinator,
		home_defense_coordinator,
		player_roster_coordinator,
		tower_multiplayer_mode_adapter,
		run_state,
		luoxi_merchant,
		random_generator,
		runtime_mode != RuntimeMode.CLIENT_VIEW
	)
	tower_multiplayer_mode_adapter.set_merchant_active(false)
	fate_coordinator.setup(
		campaign_coordinator,
		home_defense_coordinator,
		player_roster_coordinator,
		tower_multiplayer_mode_adapter,
		run_state,
		luoxi_merchant,
		enemy_container,
		boss_container,
		day_cycle_config
	)
	if not _configure_xiaocong_fate_flow():
		_fail_tower_runtime_preparation(preparation_generation, "塔防小葱命运流程配置失败。")
		return
	if not _configure_boss_coordinator():
		_fail_tower_runtime_preparation(preparation_generation, "塔防 Boss 协调器配置失败。")
		return
	if not _configure_rogue_exploration():
		_fail_tower_runtime_preparation(preparation_generation, "塔防地下探索运行时配置失败。")
		return
	if not _bind_tower_multiplayer_adapter_dependencies():
		_fail_tower_runtime_preparation(preparation_generation, "塔防多人适配器依赖绑定失败。")
		return
	if not _configure_campaign_runtime_coordinator():
		_fail_tower_runtime_preparation(preparation_generation, "塔防战役运行时协调器配置失败。")
		return
	prewarmer_coordinator.schedule_boss_runtime_scene_loads(preparation_generation)

	if runtime_mode == RuntimeMode.CLIENT_VIEW:
		auto_start_waves = false
		campaign_coordinator.start_client_flow_countdown(
			CombatFlowState.State.PRE_WAVE,
			campaign_coordinator.get_flow_step_id(
				campaign_coordinator.get_start_flow_step()
			),
			campaign_coordinator.get_initial_preparation_seconds()
		)
	elif auto_start_waves and not runtime_activation_deferred and _is_flow_system_ready():
		campaign_coordinator.enter_pre_flow_step(
			campaign_coordinator.get_start_flow_step()
		)
	else:
		enemy_coordinator.show_wave_progress()
	if runtime_mode == RuntimeMode.CLIENT_VIEW:
		if runtime_activation_deferred:
			call_deferred(
				"prepare_shared_runtime_data_and_complete",
				preparation_generation
			)
		else:
			mark_runtime_preparation_complete(preparation_generation)
	elif auto_start_waves or runtime_activation_deferred:
		_schedule_enemy_navigation_prewarm(preparation_generation)


func _fail_tower_runtime_preparation(
	preparation_generation: int,
	reason: String
) -> void:
	# 静态场景契约失败与线程预热失败共享同一加载终态，不再静默等待超时。
	mark_runtime_preparation_failed(preparation_generation, reason)
	set_process(false)
	set_physics_process(false)


func _on_runtime_activated() -> void:
	if runtime_mode == RuntimeMode.CLIENT_VIEW:
		return
	if (
		campaign_coordinator.current_flow_step == null
		and auto_start_waves
		and _is_flow_system_ready()
	):
		campaign_coordinator.enter_pre_flow_step(
			campaign_coordinator.get_start_flow_step()
		)


func _physics_process(delta: float) -> void:
	if _is_tower_runtime_suspended_for_rogue():
		return
	presentation_coordinator.update_local_spectator_camera(delta)
	player_roster_coordinator.local_player = player
	player_roster_coordinator.update_singleplayer_respawn(delta)
	if runtime_mode != RuntimeMode.CLIENT_VIEW:
		enemy_coordinator.update_targets(delta)
	if runtime_mode == RuntimeMode.HOST_AUTHORITY:
		player_roster_coordinator.update_remote_passive_state(delta)


func _unhandled_input(event: InputEvent) -> void:
	if _is_tower_runtime_suspended_for_rogue():
		return
	presentation_coordinator.handle_unhandled_input(event)


func _is_tower_runtime_suspended_for_rogue() -> bool:
	return (
		rogue_exploration_coordinator != null
		and rogue_exploration_coordinator.is_tower_runtime_suspended()
	)


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
		TowerDefensePlayerRosterCoordinator.DEFAULT_PLAYER_CHARACTER_ID,
		MULTIPLAYER_SPAWN_OFFSETS,
		PLAYER_RESPAWN_DELAYS,
		PLAYER_RESPAWN_INVINCIBILITY_SECONDS
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
	return true


func _configure_pickup_registry() -> bool:
	if pickup_registry == null:
		push_error("TowerDefenseGame: 缺少静态 PickupRegistry 节点。")
		return false
	pickup_registry.bind_tower_dependencies(
		runtime_mode,
		self,
		get_multiplayer_gameplay_gateway(),
		enemy_container,
		boss_container
	)
	if not pickup_registry.is_bound():
		push_error("TowerDefenseGame: PickupRegistry 依赖绑定不完整。")
		return false
	pickup_registry.connect_dynamic_containers()
	return true


func _configure_presentation_coordinator() -> bool:
	if presentation_coordinator == null:
		push_error("TowerDefenseGame: 缺少静态 PresentationCoordinator 节点。")
		return false
	presentation_coordinator.setup(
		self,
		campaign_coordinator,
		plant_placement_coordinator,
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
	if not presentation_coordinator.is_bound():
		push_error("TowerDefenseGame: PresentationCoordinator 依赖绑定不完整。")
		return false
	return true


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
		rogue_exploration_coordinator,
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


func _configure_rogue_exploration() -> bool:
	if rogue_exploration_coordinator == null:
		push_error("TowerDefenseGame: 缺少静态 RogueExplorationCoordinator 节点。")
		return false
	if not rogue_exploration_coordinator.setup(
		self,
		campaign_coordinator,
		progression_config,
		player_roster_coordinator,
		home_defense_coordinator,
		plant_placement_coordinator,
		plant_placement_controller,
		tower_multiplayer_mode_adapter,
		plant_terrain_decay_timer,
		production_coordinator,
		research_coordinator,
		fate_coordinator,
		run_state
	):
		push_error("TowerDefenseGame: RogueExplorationCoordinator 依赖绑定失败。")
		return false
	return true


func get_rogue_exploration_coordinator() -> TowerDefenseRogueExplorationCoordinator:
	return rogue_exploration_coordinator


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
	tower_multiplayer_mode_adapter.bind_rogue_exploration_coordinator(
		rogue_exploration_coordinator
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
	var character_id := (
		player_roster_coordinator.get_selected_singleplayer_character_id()
	)
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


func _apply_base_damage(amount: int) -> void:
	home_defense_coordinator.apply_base_damage(amount)


func _update_base_health_display(play_damage_pulse: bool = true) -> void:
	presentation_coordinator.show_base_health(
		home_defense_coordinator.current_base_health,
		home_defense_coordinator.maximum_base_health,
		play_damage_pulse
	)


func _configure_plant_placement_coordinator() -> bool:
	if plant_placement_coordinator == null:
		push_error("TowerDefenseGame: 缺少静态 PlantPlacementCoordinator 节点。")
		return false
	if not plant_placement_coordinator.setup(
		plant_placement_controller,
		plant_system,
		plant_runtime_coordinator,
		run_state,
		production_coordinator,
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


func _apply_initial_player_xirang() -> void:
	player_roster_coordinator.local_player = player
	player_roster_coordinator.apply_initial_player_xirang()


func _grant_tower_defense_starting_package() -> bool:
	return player_roster_coordinator.grant_starting_package(progression_config)


func _register_research_players() -> void:
	player_roster_coordinator.local_player = player
	player_roster_coordinator.register_research_players()


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
		presentation_coordinator,
		tower_multiplayer_mode_adapter,
		prewarmer_coordinator,
		grid_pathfinder,
		random_generator
	)
	if not boss_coordinator.is_bound():
		push_error("TowerDefenseGame: BossCoordinator 依赖绑定不完整。")
		return false
	boss_coordinator.configure_existing_runtime_nodes()
	return true


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


func prepare_shared_runtime_data_and_complete(preparation_generation: int) -> void:
	if prewarmer_coordinator != null:
		await prewarmer_coordinator.prepare_shared_runtime_data_and_complete(
			preparation_generation
		)


func _can_continue_runtime_prewarm(preparation_generation: int) -> bool:
	return (
		not runtime_prewarm_tearing_down
		and is_inside_tree()
		and is_runtime_preparation_generation_preparing(preparation_generation)
	)


func _schedule_enemy_navigation_prewarm(preparation_generation: int) -> void:
	if prewarmer_coordinator != null:
		prewarmer_coordinator.schedule_enemy_navigation_prewarm(
			preparation_generation
		)


func _configure_xiaocong_fate_flow() -> bool:
	if fate_flow_coordinator == null:
		push_error("TowerDefenseGame: 缺少静态 FateFlowCoordinator 节点。")
		return false
	fate_flow_coordinator.setup(
		campaign_coordinator,
		rogue_exploration_coordinator,
		fate_coordinator,
		fate_manager,
		player_roster_coordinator,
		plant_placement_coordinator,
		presentation_coordinator,
		tower_multiplayer_mode_adapter,
		multiplayer_gateway,
		xiaocong_fate_interlude,
		plant_terrain_decay_timer,
		production_coordinator,
		research_coordinator,
		plant_placement_controller,
		wave_hud,
		tower_defense_status_hud,
		tower_defense_minimap
	)
	if not fate_flow_coordinator.is_bound():
		push_error("TowerDefenseGame: FateFlowCoordinator 依赖绑定失败。")
		return false
	return true




func grant_xirang_kill_reward(amount: int) -> bool:
	var rewarded_amount := amount
	if (
		fate_coordinator != null
		and fate_coordinator.is_double_xirang_reward_active()
	):
		rewarded_amount *= 2
	var accepted := super.grant_xirang_kill_reward(rewarded_amount)
	if accepted:
		campaign_coordinator.record_xirang_reward(rewarded_amount)
	return accepted


func get_progression_metrics_snapshot() -> Dictionary:
	return campaign_coordinator.get_progression_metrics_snapshot()


func _configure_multiplayer_players() -> void:
	player_roster_coordinator.set_runtime_identity(
		runtime_mode, multiplayer_local_peer_id
	)
	player = player_roster_coordinator.configure_multiplayer_players()


func remove_multiplayer_player(peer_id: int) -> void:
	tower_multiplayer_mode_adapter.remove_multiplayer_player(peer_id)


func ensure_reconnected_multiplayer_player(
	old_peer_id: int,
	new_peer_id: int,
	player_name: String,
	character_id: StringName,
	state: SnapshotManager.PlayerState,
	spawn_slot_index: int,
	reconnect_state: Dictionary = {}
) -> CombatRuntimeBase.ReconnectedPlayerProjection:
	var projection := (
		tower_multiplayer_mode_adapter.ensure_reconnected_multiplayer_player(
			old_peer_id,
			new_peer_id,
			player_name,
			character_id,
			state,
			spawn_slot_index,
			reconnect_state
		)
	)
	if new_peer_id == multiplayer_local_peer_id and projection.is_success():
		player = projection.player
	return projection


func get_player_for_peer(peer_id: int) -> Player:
	if player_roster_coordinator != null and player_roster_coordinator.is_bound():
		return player_roster_coordinator.get_player(peer_id)
	# Narrow pre-tree/fixture façade: `TowerDefenseGame.new()` has not yet
	# resolved its statically authored coordinator child.
	return peer_players.get(peer_id) as Player


func get_enemy_for_net_id(net_id: int) -> Enemy:
	return get_network_enemy(net_id)


func get_pickup_for_net_id(net_id: int) -> Pickup:
	return get_network_pickup(net_id)


func _register_static_multiplayer_pickups() -> void:
	pickup_registry.set_runtime_mode(runtime_mode)
	pickup_registry.register_static_pickups(self)


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


func _is_flow_system_ready() -> bool:
	if campaign_coordinator.flow_graph == null:
		push_error("TowerDefenseGame 当前 Campaign 没有配置 FlowGraphConfig。")
		return false
	if not enemy_coordinator.is_spawn_system_ready():
		return false
	var errors := campaign_coordinator.validate_flow_graph()
	for error in errors:
		push_warning(error)
	if not errors.is_empty():
		return false
	return campaign_coordinator.get_start_flow_step() != null


func play_remote_enemy_spawn_effect(spawn_global_position: Vector2) -> void:
	enemy_coordinator.spawn_enemy_spawn_effect(spawn_global_position)
