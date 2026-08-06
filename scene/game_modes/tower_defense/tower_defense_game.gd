extends CombatRuntimeBase
class_name TowerDefenseGame

const PLANT_PLACEMENT_PARTICLES_SCENE := preload(
	"res://scene/plant_defense/effects/plant_placement_particles.tscn"
)
const PLANT_REMOVAL_SMOKE_SCENE := preload(
	"res://scene/plant_defense/effects/plant_removal_smoke.tscn"
)
const GUARDIAN_POINT_LIGHT_TEXTURE := preload("res://resources/texture/enemy/yuanshi_insect/guardian_point_light.png")
const TANGO_MINIMUM_CHARGE_SECONDS := 0.2
const TANGO_MAXIMUM_CHARGE_SECONDS := 2.4
const TANGO_CHARGE_THRESHOLD_EPSILON := 0.0001
const PLAYER_RESPAWN_DELAYS: Array[int] = [5, 10, 15, 20]
const PLAYER_RESPAWN_INVINCIBILITY_SECONDS := 3.0
const DEFAULT_BASE_HEALTH := 100
const FORMAL_PROGRESSION_CONFIG_PATH := (
	"res://resources/config/campaigns/tower_defense/formal_progression.tres"
)
const TERRAIN_NETWORK_BATCH_MAX_CELLS := 96
const UNSUPPORTED_PLANT_DAMAGE_INTERVAL_SECONDS := 1.0
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
var multiplayer_player_names: Dictionary = {}
var multiplayer_player_character_ids: Dictionary = {}
var multiplayer_spawn_slot_indices: Dictionary[int, int] = {}
var _pending_multiplayer_pickup_exit_ids: Dictionary = {}
var pending_multiplayer_pickup_exit_ids: Dictionary:
	get:
		return (
			pickup_registry.pending_multiplayer_pickup_exit_ids
			if pickup_registry != null and pickup_registry.is_bound()
			else _pending_multiplayer_pickup_exit_ids
		)
	set(value):
		_pending_multiplayer_pickup_exit_ids = value
		if pickup_registry != null and pickup_registry.is_bound():
			pickup_registry.pending_multiplayer_pickup_exit_ids = value
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
var _next_multiplayer_pickup_net_id := PickupRegistryBase.FIRST_DYNAMIC_PICKUP_NET_ID
var next_multiplayer_pickup_net_id: int:
	get:
		return (
			pickup_registry.next_multiplayer_pickup_net_id
			if pickup_registry != null and pickup_registry.is_bound()
			else _next_multiplayer_pickup_net_id
		)
	set(value):
		_next_multiplayer_pickup_net_id = value
		if pickup_registry != null and pickup_registry.is_bound():
			pickup_registry.next_multiplayer_pickup_net_id = value
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
var projectile_pool_registration_ms := 0.0
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
	if not _configure_pickup_registry():
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
	research_coordinator.setup(
		production_coordinator,
		plant_system,
		player_roster_coordinator
	)
	research_coordinator.set_authoritative_processing_enabled(
		runtime_mode != RuntimeMode.CLIENT_VIEW
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
	prewarmer_coordinator.schedule_boss_runtime_scene_loads()

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
		campaign_coordinator.enter_pre_flow_step(
			campaign_coordinator.get_start_flow_step()
		)


func _physics_process(delta: float) -> void:
	presentation_coordinator.update_local_spectator_camera(delta)
	player_roster_coordinator.local_player = player
	player_roster_coordinator.update_singleplayer_respawn(delta)
	if runtime_mode != RuntimeMode.CLIENT_VIEW:
		enemy_coordinator.update_targets(delta)
	if runtime_mode == RuntimeMode.HOST_AUTHORITY:
		player_roster_coordinator.update_remote_passive_state(delta)


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
		TowerDefensePlayerRosterCoordinator.DEFAULT_PLAYER_CHARACTER_ID,
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
	return true


func _configure_pickup_registry() -> bool:
	if pickup_registry == null:
		push_error("TowerDefenseGame: 缺少静态 PickupRegistry 节点。")
		return false
	pickup_registry.bind_tower_dependencies(
		runtime_mode,
		multiplayer_pickups,
		get_multiplayer_gameplay_gateway(),
		enemy_container,
		boss_container,
		_pending_multiplayer_pickup_exit_ids,
		_next_multiplayer_pickup_net_id
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


func _apply_initial_player_xirang() -> void:
	player_roster_coordinator.local_player = player
	player_roster_coordinator.apply_initial_player_xirang()


func _grant_tower_defense_starting_package() -> bool:
	return player_roster_coordinator.grant_starting_package(progression_config)


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
	if (
		debug_collectible_window == null
		or not sandbox_free_building_enabled
		or not tower_multiplayer_mode_adapter.allows_debug_collectible_grants()
	):
		return
	debug_collectible_window.toggle()


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
	plant_terrain_decay_timer.one_shot = false
	plant_terrain_decay_timer.wait_time = UNSUPPORTED_PLANT_DAMAGE_INTERVAL_SECONDS
	plant_terrain_decay_timer.process_callback = Timer.TIMER_PROCESS_PHYSICS
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
		campaign_coordinator,
		fate_coordinator,
		fate_manager,
		player_roster_coordinator,
		plant_placement_coordinator,
		presentation_coordinator,
		tower_multiplayer_mode_adapter,
		multiplayer_gateway,
		xiaocong_fate_interlude,
		enemy_spawn_timer,
		state_timer,
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
	if pickup_registry != null and pickup_registry.is_bound():
		return pickup_registry.get_pickup_for_net_id(net_id)
	return PickupRegistryBase.get_pickup_from_index(multiplayer_pickups, net_id)


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
