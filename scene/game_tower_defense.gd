extends Node2D
class_name GameTowerDefense

const ENEMY_SPAWN_EFFECT_SCENE := preload("res://scene/enemy/yuanshi_insect_spawn_effect.tscn")
const GUARDIAN_POINT_LIGHT_TEXTURE := preload("res://resources/texture/guardian_point_light.png")
const DEFAULT_PLAYER_CHARACTER_ID := &"weishidaier"
const LINGLAN_BOSS_INTRO_VFX_SCENE_PATH := "res://scene/boss/linglan/linglan_boss_intro_vfx.tscn"
const BOSS_HEALTH_HUD_SCENE_PATH := "res://scene/boss/linglan/boss_health_hud.tscn"
const COUNTDOWN_FINAL_SECONDS := 3
const MULTIPLAYER_DEFEAT_GRACE_SECONDS := 0.25
const PURCHASE_RESULT_SUCCESS := 0
const PURCHASE_RESULT_ALREADY_OWNED := 1
const PURCHASE_RESULT_INSUFFICIENT_XIRANG := 2
const PURCHASE_RESULT_INVALID_PLAYER := 3
const PURCHASE_RESULT_SKILL1_UPGRADE_SUCCESS := 4
const PURCHASE_RESULT_SKILL1_UPGRADE_MAXED := 5
const MIN_WAVE_SPAWN_INTERVAL_SECONDS := 0.1
const MAX_WAVE_SPAWN_COUNT_PER_TICK := 4
const SPAWN_EFFECTS_PER_SECOND_LIMIT := 24
const DEFAULT_MUSIC_VOLUME_DB := -6.0
const MUSIC_FADE_IN_SECONDS := 3.0
const MUSIC_FADE_IN_START_VOLUME_DB := -12.0
const INITIAL_PLAYER_XIRANG := 1000

signal multiplayer_enemy_spawned(net_id: int, enemy_config: EnemyConfig, spawn_position: Vector2)
signal multiplayer_enemy_defeated(net_id: int, defeat_position: Vector2)
signal multiplayer_enemy_removed(net_id: int)
signal multiplayer_pickup_spawned(net_id: int, pickup_config: PickupConfig, spawn_position: Vector2)
signal multiplayer_pickup_collected(
	net_id: int,
	collector_peer_id: int,
	pickup_config: PickupConfig,
	applied_immediately: bool
)
signal multiplayer_pickup_removed(net_id: int)
signal multiplayer_merchant_active_changed(active: bool)
signal multiplayer_wave_started(wave_index: int)
signal multiplayer_flow_state_changed(step_id: StringName, state: int, countdown_seconds: int)
signal multiplayer_boss_started(net_id: int, boss_config: BossConfig, spawn_position: Vector2)
signal multiplayer_defeat_started
signal multiplayer_victory_started
signal multiplayer_revive_all_requested
signal return_to_lobby_requested

enum RuntimeMode {
	SINGLEPLAYER,
	HOST_AUTHORITY,
	CLIENT_VIEW,
}

enum WaveState {
	PRE_WAVE,
	WAVE_ACTIVE,
	INTERMISSION,
	VICTORY,
	DEFEAT,
	BOSS_INTRO,
	BOSS_ACTIVE,
}

@export_group("波次资源")
@export var waves: Array[WaveConfig] = [
	preload("res://resources/config/waves/wave_01.tres"),
	preload("res://resources/config/waves/wave_02.tres"),
	preload("res://resources/config/waves/wave_03.tres"),
	preload("res://resources/config/waves/wave_04.tres"),
	preload("res://resources/config/waves/wave_05.tres"),
	preload("res://resources/config/waves/wave_06.tres"),
	preload("res://resources/config/waves/wave_07.tres"),
	preload("res://resources/config/waves/wave_08.tres"),
	preload("res://resources/config/waves/wave_09.tres"),
	preload("res://resources/config/waves/wave_10.tres"),
	preload("res://resources/config/waves/wave_11.tres"),
	preload("res://resources/config/waves/wave_12.tres"),
]

@export_group("Boss资源")
@export var bosses: Array[Resource] = [
	preload("res://resources/config/bosses/boss_01_linglan.tres"),
]

@export_group("战斗流程")
@export var flow_graph: FlowGraphConfig = preload("res://resources/config/flow/default_combat_flow.tres")
@export_range(0.0, 60.0, 1.0, "or_greater") var pre_wave_duration: float = 5.0
@export var auto_start_waves: bool = true
@export var runtime_mode: RuntimeMode = RuntimeMode.SINGLEPLAYER
@export var linglan_boss_enabled: bool = true

var player: Player = null
@onready var player_spawn: Marker2D = $PlayerSpawn
@onready var ground_tile_map_layer: TileMapLayer = $GroundTileMapLayer
@onready var overlay_tile_map_layer: TileMapLayer = $OverlayTileMapLayer
@onready var enemy_container: Node2D = $EnemyContainer
@onready var enemy_spawn_points_root: Node2D = $EnemySpawnPoints
@onready var enemy_spawn_timer: Timer = $EnemySpawnTimer
@onready var state_timer: Timer = $StateTimer
@onready var map_camera: Camera2D = $Camera2D
@onready var grid_pathfinder: Node = $GridPathfinder
@onready var music_player: AudioStreamPlayer = $MusicPlayer
@onready var countdown_audio: AudioStreamPlayer = $CountdownAudio
@onready var wave_start_audio: AudioStreamPlayer = $WaveStartAudio
@onready var currency_hud: CurrencyHUD = $CurrencyHUD
@onready var wave_hud: WaveHUD = $WaveHUD
@onready var player_profile_panel: PlayerProfilePanel = $PlayerProfilePanel
@onready var settings_panel: SettingsPanel = $SettingsLayer/SettingsPanel
@onready var debug_collectible_window: DebugCollectibleWindow = $SettingsLayer/DebugCollectibleWindow
@onready var merchant: ZhuangfangyiMerchant = $ZhuangfangyiMerchant
@onready var luoxi_merchant: LuoxiMerchant = $LuoxiMerchant
@onready var boss_container: Node2D = $BossContainer
@onready var plant_container: Node2D = $PlantContainer
@onready var plant_system: PlantSystem = $PlantSystem
@onready var plant_placement_controller: PlantPlacementController = $PlantPlacementController
@onready var damage_number_pool: DamageNumberPool = $DamageNumberPool
@onready var run_state: RunStateStore = get_node("/root/RunState") as RunStateStore

var random_generator := RandomNumberGenerator.new()
var enemy_spawn_points: Array[Marker2D] = []
var pending_enemy_configs: Array[EnemyConfig] = []
var pending_enemy_config_index: int = 0
var active_wave_enemy_ids: Dictionary = {}

var wave_state: WaveState = WaveState.PRE_WAVE
var current_wave_index: int = 0
var current_wave_total: int = 0
var current_wave_spawned: int = 0
var current_wave_defeated: int = 0
var countdown_seconds: int = 0
var current_flow_step: FlowStepConfig = null
var next_flow_step_after_rest: FlowStepConfig = null
var music_fade_tween: Tween = null
var multiplayer_local_peer_id: int = 0
var multiplayer_player_names: Dictionary = {}
var multiplayer_player_character_ids: Dictionary = {}
var peer_players: Dictionary = {}
var multiplayer_pickups: Dictionary = {}
var removed_multiplayer_pickup_ids: Dictionary = {}
var multiplayer_enemy_ids_by_instance: Dictionary = {}
var multiplayer_enemies_by_net_id: Dictionary = {}
var removed_multiplayer_enemy_ids: Dictionary = {}
var enemy_retarget_time_left: float = 0.0
var next_multiplayer_enemy_net_id: int = 1
var next_multiplayer_pickup_net_id: int = 1000
var multiplayer_defeat_check_pending: bool = false
var spawn_effect_budget_started_msec: int = 0
var spawn_effects_this_second: int = 0
var luoxi_collectible_claim_counts: Dictionary = {}
var linglan_boss_started: bool = false
var active_boss_config: Resource
var linglan_boss: LinglanBoss = null
var linglan_boss_intro_vfx: LinglanBossIntroVFX = null
var boss_health_hud: BossHealthHUD = null
var boss_runtime_scene_loads_requested: bool = false
var navigation_prewarm_requested: bool = false
var navigation_prewarmed: bool = false


func _ready() -> void:
	random_generator.randomize()
	var user_settings := get_node_or_null("/root/UserSettings")
	if user_settings != null and user_settings.has_method("assign_audio_buses_to_tree"):
		user_settings.call("assign_audio_buses_to_tree")
	if runtime_mode == RuntimeMode.SINGLEPLAYER:
		run_state.ensure_run_started()
		_configure_singleplayer_player()
	_collect_enemy_spawn_points()
	_configure_timers()
	_prewarm_enemy_visual_resources()
	if runtime_mode != RuntimeMode.SINGLEPLAYER:
		run_state.ensure_run_started()
		run_state.set_active_multiplayer_peer(multiplayer_local_peer_id)
		_configure_multiplayer_players()
		_register_static_multiplayer_pickups()
	if player == null:
		push_error("Game: 无法创建当前角色，停止初始化。")
		set_process(false)
		set_physics_process(false)
		return
	_configure_plant_defense_system()
	_apply_initial_player_xirang()
	currency_hud.bind_player(player)
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
	if runtime_mode == RuntimeMode.SINGLEPLAYER:
		player.died.connect(_on_player_died)
	_set_merchant_active(false)
	_configure_linglan_boss()
	call_deferred("_deferred_request_boss_runtime_scene_loads")

	if runtime_mode == RuntimeMode.CLIENT_VIEW:
		auto_start_waves = false
		_start_client_flow_countdown(
			WaveState.PRE_WAVE,
			_get_flow_step_id(_get_start_flow_step()),
			maxi(ceili(pre_wave_duration), 0)
		)
	elif auto_start_waves and _is_flow_system_ready():
		_enter_pre_flow_step(_get_start_flow_step())
	else:
		wave_hud.hide_all()


func _physics_process(delta: float) -> void:
	if runtime_mode == RuntimeMode.HOST_AUTHORITY:
		_update_multiplayer_remote_player_passive_state(delta)
		_update_multiplayer_enemy_targets(delta)
		_register_dynamic_multiplayer_pickups()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("full_screen"):
		_toggle_full_screen()
		get_viewport().set_input_as_handled()
		return

	if event.is_action_pressed("cheat_collectibles"):
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


func _configure_singleplayer_player() -> void:
	var character_id := _get_selected_singleplayer_character_id()
	var player_instance := _instantiate_player_character(character_id)
	if player_instance == null:
		return
	player_instance.name = "Player"
	player_instance.position = player_spawn.position
	add_child(player_instance)
	player = player_instance


func _configure_plant_defense_system() -> void:
	if plant_system == null or plant_placement_controller == null or plant_container == null:
		push_error("GameTowerDefense: 植物防御塔节点不完整，已禁用放置功能。")
		return
	if runtime_mode != RuntimeMode.SINGLEPLAYER:
		plant_placement_controller.set_process_unhandled_input(false)
		return

	var placement_rect := PlantSystem.DEFAULT_PLACEMENT_AREA
	if not bosses.is_empty():
		var first_boss_config := bosses[0]
		if first_boss_config != null:
			var configured_rect := _get_boss_arena_floor_rect(first_boss_config)
			if configured_rect.size.x > 0 and configured_rect.size.y > 0:
				placement_rect = configured_rect

	plant_system.setup(
		ground_tile_map_layer,
		player,
		plant_container,
		placement_rect
	)
	plant_system.clear_reserved_cells()
	plant_system.reserve_world_position(player_spawn.global_position)
	for spawn_point in enemy_spawn_points:
		plant_system.reserve_world_position(spawn_point.global_position, 1)
	if merchant != null:
		plant_system.reserve_world_position(merchant.global_position)
	if luoxi_merchant != null:
		plant_system.reserve_world_position(luoxi_merchant.global_position)

	plant_placement_controller.setup(plant_system, player)
	plant_placement_controller.player_lock_requested.connect(
		_on_plant_player_lock_requested
	)
	plant_placement_controller.placement_mode_changed.connect(
		_on_plant_placement_mode_changed
	)
	_update_plant_placement_input_state()


func _on_plant_player_lock_requested(_locked: bool) -> void:
	_refresh_player_modal_ui_lock()


func _on_plant_placement_mode_changed(active: bool) -> void:
	if active and _has_exclusive_modal_open():
		plant_placement_controller.cancel_placement()
		return
	_refresh_player_modal_ui_lock()


func _has_exclusive_modal_open() -> bool:
	return (
		settings_panel.is_open()
		or player_profile_panel.is_open()
		or debug_collectible_window.is_open()
	)


func _update_plant_placement_input_state() -> void:
	if plant_placement_controller == null:
		return
	var input_enabled := (
		runtime_mode == RuntimeMode.SINGLEPLAYER
		and player != null
		and not player.is_dead
		and not _has_exclusive_modal_open()
	)
	plant_placement_controller.set_process_unhandled_input(input_enabled)


func _cancel_plant_placement() -> void:
	if plant_placement_controller != null and plant_placement_controller.is_active():
		plant_placement_controller.cancel_placement()


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
		settings_panel.is_open()
		or player_profile_panel.is_open()
		or debug_collectible_window.is_open()
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
	if debug_collectible_window == null:
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
	if config_path.is_empty():
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


func apply_remote_merchant_active(active: bool) -> void:
	_set_local_merchants_active(active)
	if runtime_mode != RuntimeMode.CLIENT_VIEW:
		return
	if not active and (wave_state == WaveState.PRE_WAVE or wave_state == WaveState.INTERMISSION):
		state_timer.stop()


func apply_remote_flow_state(step_id: StringName, state: int, seconds: int) -> void:
	if runtime_mode != RuntimeMode.CLIENT_VIEW:
		return
	var flow_step := _get_flow_step_by_id(step_id)
	if flow_step != null:
		current_flow_step = flow_step
		if flow_step is WaveConfig:
			current_wave_index = _get_wave_number_for_step(flow_step as WaveConfig) - 1
	var typed_state := state as WaveState
	match typed_state:
		WaveState.PRE_WAVE, WaveState.INTERMISSION:
			_start_client_flow_countdown(typed_state, step_id, seconds)
		WaveState.WAVE_ACTIVE:
			state_timer.stop()
			wave_state = WaveState.WAVE_ACTIVE
			_set_local_merchants_active(false)
			var wave_config := flow_step as WaveConfig
			if wave_config != null:
				_update_wave_music(wave_config)
			wave_hud.show_enemy_count(maxi(current_wave_index + 1, 1), 0)
			wave_start_audio.play()
		WaveState.BOSS_INTRO:
			state_timer.stop()
			wave_state = WaveState.BOSS_INTRO
			_set_local_merchants_active(false)
			wave_hud.hide_all()
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
			wave_hud.hide_all()
			if linglan_boss_intro_vfx != null:
				linglan_boss_intro_vfx.stop_intro()
			var active_config := flow_step as BossConfig
			if active_config != null:
				active_boss_config = active_config
				_update_boss_music(active_config)
		WaveState.VICTORY:
			apply_remote_victory()
		WaveState.DEFEAT:
			apply_remote_defeat()


func apply_remote_wave_started(wave_index: int) -> void:
	if wave_index < 0 or wave_index >= waves.size():
		return
	var wave_config := waves[wave_index]
	if wave_config == null:
		return
	state_timer.stop()
	wave_state = WaveState.WAVE_ACTIVE
	current_wave_index = wave_index
	_update_wave_music(wave_config)
	wave_hud.show_enemy_count(current_wave_index + 1, 0)
	wave_start_audio.play()


func apply_remote_boss_started(net_id: int, boss_config: BossConfig, spawn_position: Vector2) -> void:
	if runtime_mode != RuntimeMode.CLIENT_VIEW or boss_config == null:
		return
	if linglan_boss_intro_vfx != null:
		linglan_boss_intro_vfx.stop_intro()
	active_boss_config = boss_config
	current_flow_step = boss_config
	wave_state = WaveState.BOSS_ACTIVE
	state_timer.stop()
	wave_hud.hide_all()
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
	if net_id <= 0 or boss_config == null:
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
	boss_enemy.configure_multiplayer_proxy()
	boss_enemy.set_meta("net_id", net_id)
	multiplayer_enemies_by_net_id[net_id] = boss_enemy
	multiplayer_enemy_ids_by_instance[boss_enemy.get_instance_id()] = net_id
	return boss_enemy


func apply_remote_victory() -> void:
	if runtime_mode != RuntimeMode.CLIENT_VIEW:
		return
	_enter_victory(false)


func apply_remote_enemy_count(alive_count: int) -> void:
	if runtime_mode != RuntimeMode.CLIENT_VIEW:
		return
	if wave_state != WaveState.WAVE_ACTIVE:
		return
	wave_hud.show_enemy_count(current_wave_index + 1, alive_count)



func apply_remote_defeat() -> void:
	if runtime_mode != RuntimeMode.CLIENT_VIEW:
		return
	if wave_state == WaveState.DEFEAT:
		return
	wave_state = WaveState.DEFEAT
	enemy_spawn_timer.stop()
	state_timer.stop()
	_set_merchant_active(false)
	wave_hud.show_defeat()


func show_damage_number(
	amount: int,
	spawn_position: Vector2,
	impact_direction: Vector2 = Vector2.ZERO,
	damage_type: EnemyConfig.DamageType = EnemyConfig.DamageType.PHYSICAL
) -> bool:
	if damage_number_pool == null:
		return false
	return damage_number_pool.show_damage_number(amount, spawn_position, impact_direction, damage_type)


func try_purchase_skill1_for_peer(peer_id: int) -> int:
	var player_instance := get_player_for_peer(peer_id)
	if player_instance == null or not is_instance_valid(player_instance):
		return PURCHASE_RESULT_INVALID_PLAYER
	if player_instance.has_skill1():
		if player_instance.is_skill1_upgrade_maxed():
			return PURCHASE_RESULT_SKILL1_UPGRADE_MAXED
		var free_upgrade := player_instance.has_collectible_effect(
			PickupConfig.COLLECTIBLE_EFFECT_ADMIN_DOLL
		)
		if not player_instance.try_upgrade_skill1(free_upgrade):
			return PURCHASE_RESULT_INSUFFICIENT_XIRANG
		return PURCHASE_RESULT_SKILL1_UPGRADE_SUCCESS
	if not player_instance.try_purchase_skill1(ZhuangfangyiMerchant.PURCHASE_COST):
		return PURCHASE_RESULT_INSUFFICIENT_XIRANG
	return PURCHASE_RESULT_SUCCESS


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


func request_luoxi_collectible_choice(choice_index: int, config_path: String = "") -> void:
	if runtime_mode == RuntimeMode.CLIENT_VIEW:
		return
	var peer_id := multiplayer_local_peer_id if runtime_mode != RuntimeMode.SINGLEPLAYER else 0
	var resolved_config_path := _resolve_luoxi_collectible_path(choice_index, config_path)
	var result_code := try_claim_luoxi_collectible_for_peer(peer_id, resolved_config_path)
	show_local_luoxi_collectible_result(result_code)


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


func _on_wave_hud_return_to_lobby_requested() -> void:
	if runtime_mode == RuntimeMode.SINGLEPLAYER:
		_cancel_plant_placement()
		get_tree().change_scene_to_file("res://scene/main_menu.tscn")
		return
	return_to_lobby_requested.emit()


func _set_merchant_active(active: bool) -> void:
	var changed := _set_local_merchants_active(active)
	if not changed:
		return
	if runtime_mode == RuntimeMode.HOST_AUTHORITY:
		multiplayer_merchant_active_changed.emit(active)


func _set_local_merchants_active(active: bool) -> bool:
	var changed := false
	if merchant != null and merchant.is_active != active:
		merchant.set_active(active)
		changed = true
	if luoxi_merchant != null and luoxi_merchant.is_active != active:
		if active:
			luoxi_collectible_claim_counts.clear()
			luoxi_merchant.reset_round_collectible_claims()
		luoxi_merchant.set_active(active)
		changed = true
	return changed


func _configure_linglan_boss() -> void:
	if linglan_boss == null:
		return
	var boss_config := active_boss_config if active_boss_config != null else _get_first_boss_config()
	if boss_config != null:
		linglan_boss.config = _get_boss_enemy_config(boss_config)
		linglan_boss.global_position = _get_boss_arena_center(boss_config)
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
	for boss_config in _get_configured_bosses():
		if not _boss_config_has_required_data(boss_config):
			continue
		var enemy_config_path := _get_boss_enemy_config_path(boss_config)
		if not enemy_config_path.is_empty():
			ResourceLoader.load_threaded_request(enemy_config_path)
		var intro_path := _get_boss_intro_vfx_scene_path(boss_config)
		if not intro_path.is_empty():
			ResourceLoader.load_threaded_request(intro_path)
		var hud_path := _get_boss_hud_scene_path(boss_config)
		if not hud_path.is_empty():
			ResourceLoader.load_threaded_request(hud_path)


func _deferred_request_boss_runtime_scene_loads() -> void:
	if DisplayServer.get_name() == "headless":
		return
	await get_tree().process_frame
	await get_tree().process_frame
	if not is_inside_tree():
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
	if boss_container == null:
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
	var status := ResourceLoader.load_threaded_get_status(path)
	if status == ResourceLoader.THREAD_LOAD_LOADED:
		return ResourceLoader.load_threaded_get(path)
	if status == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
		return ResourceLoader.load_threaded_get(path)
	return load(path)


func _collect_enemy_spawn_points() -> void:
	enemy_spawn_points.clear()
	for child in enemy_spawn_points_root.get_children():
		var spawn_point := child as Marker2D
		if spawn_point != null:
			enemy_spawn_points.append(spawn_point)

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
			var extent_key := "%d:%d" % [ceili(body_half_extents.x), ceili(body_half_extents.y)]
			if seen_extent_keys.has(extent_key):
				continue
			seen_extent_keys[extent_key] = true
			grid_pathfinder.call("prewarm_agent_grid", body_half_extents)
			if grid_pathfinder.has_method("prewarm_flow_navigation_target") and player != null:
				grid_pathfinder.call(
					"prewarm_flow_navigation_target",
					player.global_position,
					body_half_extents
				)


func _schedule_enemy_navigation_prewarm() -> void:
	if runtime_mode == RuntimeMode.CLIENT_VIEW:
		return
	if navigation_prewarmed or navigation_prewarm_requested:
		return
	navigation_prewarm_requested = true
	call_deferred("_run_scheduled_enemy_navigation_prewarm")


func _run_scheduled_enemy_navigation_prewarm() -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	if not is_inside_tree():
		return
	navigation_prewarm_requested = false
	if navigation_prewarmed:
		return
	_prewarm_enemy_navigation_grids()
	navigation_prewarmed = true


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


func _enter_pre_wave(wave_index: int) -> void:
	if wave_index < 0 or wave_index >= waves.size():
		_enter_victory()
		return
	_enter_pre_flow_step(waves[wave_index])


func _enter_pre_flow_step(flow_step: FlowStepConfig) -> void:
	if flow_step == null:
		_enter_victory()
		return
	wave_state = WaveState.PRE_WAVE
	current_flow_step = flow_step
	next_flow_step_after_rest = flow_step
	if flow_step is WaveConfig:
		current_wave_index = _get_wave_number_for_step(flow_step as WaveConfig) - 1
	enemy_spawn_timer.stop()
	_set_merchant_active(false)
	countdown_seconds = maxi(ceili(pre_wave_duration), 0)
	wave_hud.show_countdown(countdown_seconds)
	_schedule_enemy_navigation_prewarm()
	_emit_multiplayer_flow_state(WaveState.PRE_WAVE)

	if countdown_seconds <= 0:
		_begin_flow_step(current_flow_step)
		return

	if countdown_seconds <= COUNTDOWN_FINAL_SECONDS:
		_play_countdown_tick()
	state_timer.start(1.0)


func _enter_intermission(next_step: FlowStepConfig = null) -> void:
	if runtime_mode == RuntimeMode.HOST_AUTHORITY:
		multiplayer_revive_all_requested.emit()
	wave_state = WaveState.INTERMISSION
	enemy_spawn_timer.stop()
	_set_merchant_active(true)
	next_flow_step_after_rest = next_step
	countdown_seconds = (
		maxi(ceili(current_flow_step.post_clear_rest_duration), 0)
		if current_flow_step != null
		else 0
	)
	_update_post_wave_music(current_flow_step)
	wave_hud.show_countdown(countdown_seconds)
	_emit_multiplayer_flow_state(WaveState.INTERMISSION)

	if countdown_seconds <= 0:
		_begin_flow_step(next_flow_step_after_rest)
		return

	if countdown_seconds <= COUNTDOWN_FINAL_SECONDS:
		_play_countdown_tick()
	state_timer.start(1.0)


func _begin_wave(wave_index: int) -> void:
	if wave_index < 0 or wave_index >= waves.size():
		_enter_victory()
		return

	var wave_config := waves[wave_index]
	current_flow_step = wave_config
	next_flow_step_after_rest = null
	_begin_wave_config(wave_config)


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
	if runtime_mode != RuntimeMode.CLIENT_VIEW and not navigation_prewarmed:
		_prewarm_enemy_navigation_grids()
		navigation_prewarmed = true

	wave_state = WaveState.WAVE_ACTIVE
	current_wave_index = _get_wave_number_for_step(wave_config) - 1
	state_timer.stop()
	_set_merchant_active(false)
	current_wave_spawned = 0
	current_wave_defeated = 0
	active_wave_enemy_ids.clear()
	_build_wave_spawn_queue(wave_config)
	current_wave_total = pending_enemy_configs.size()
	_update_wave_music(wave_config)
	wave_hud.show_wave_progress(
		current_wave_index + 1,
		current_wave_defeated,
		current_wave_total
	)
	wave_start_audio.play()
	if runtime_mode == RuntimeMode.HOST_AUTHORITY:
		multiplayer_wave_started.emit(current_wave_index)
	_emit_multiplayer_flow_state(WaveState.WAVE_ACTIVE)

	if current_wave_total <= 0:
		_check_wave_completion()
		return

	_spawn_wave_batch()
	if _has_pending_enemy_configs():
		enemy_spawn_timer.start(maxf(wave_config.spawn_interval, MIN_WAVE_SPAWN_INTERVAL_SECONDS))


func _build_wave_spawn_queue(wave_config: WaveConfig) -> void:
	pending_enemy_configs.clear()
	pending_enemy_config_index = 0
	for entry in wave_config.enemy_entries:
		if entry == null or entry.enemy_config == null:
			continue
		for _enemy_index in range(maxi(entry.count, 0)):
			pending_enemy_configs.append(entry.enemy_config)

	for source_index in range(pending_enemy_configs.size() - 1, 0, -1):
		var target_index := random_generator.randi_range(0, source_index)
		var temporary := pending_enemy_configs[source_index]
		pending_enemy_configs[source_index] = pending_enemy_configs[target_index]
		pending_enemy_configs[target_index] = temporary


func _on_state_timer_timeout() -> void:
	if runtime_mode == RuntimeMode.CLIENT_VIEW:
		_update_client_flow_countdown()
		return
	if wave_state != WaveState.PRE_WAVE and wave_state != WaveState.INTERMISSION:
		state_timer.stop()
		return

	countdown_seconds = maxi(countdown_seconds - 1, 0)
	if countdown_seconds > 0:
		wave_hud.show_countdown(countdown_seconds)
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


func _start_client_wave_countdown(state: WaveState, wave_index: int, seconds: int) -> void:
	wave_state = state
	current_wave_index = clampi(wave_index, 0, maxi(waves.size() - 1, 0))
	if state == WaveState.INTERMISSION and current_wave_index >= 0 and current_wave_index < waves.size():
		_update_post_wave_music(waves[current_wave_index])
	countdown_seconds = maxi(seconds, 0)
	wave_hud.show_countdown(countdown_seconds)
	if countdown_seconds <= 0:
		state_timer.stop()
		return
	state_timer.start(1.0)


func _start_client_flow_countdown(state: WaveState, step_id: StringName, seconds: int) -> void:
	wave_state = state
	var flow_step := _get_flow_step_by_id(step_id)
	if flow_step != null:
		current_flow_step = flow_step
		if flow_step is WaveConfig:
			current_wave_index = _get_wave_number_for_step(flow_step as WaveConfig) - 1
	if state == WaveState.INTERMISSION:
		_update_post_wave_music(flow_step)
	countdown_seconds = maxi(seconds, 0)
	wave_hud.show_countdown(countdown_seconds)
	if countdown_seconds <= 0:
		state_timer.stop()
		return
	state_timer.start(1.0)


func _update_client_flow_countdown() -> void:
	if wave_state != WaveState.PRE_WAVE and wave_state != WaveState.INTERMISSION:
		state_timer.stop()
		return
	countdown_seconds = maxi(countdown_seconds - 1, 0)
	wave_hud.show_countdown(countdown_seconds)
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
		if not _try_spawn_enemy(enemy_config):
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
	pending_enemy_config_index = 0


func _try_spawn_enemy(enemy_config: EnemyConfig) -> bool:
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
	var enemy_id := enemy_instance.get_instance_id()
	active_wave_enemy_ids[enemy_id] = true
	enemy_instance.defeated.connect(_on_wave_enemy_defeated)
	enemy_instance.tree_exited.connect(_on_wave_enemy_tree_exited.bind(enemy_id))
	_register_multiplayer_enemy_instance(enemy_instance, enemy_config, enemy_instance.global_position)
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
	if not enemy_instance.defeated.is_connected(_on_boss_add_defeated):
		enemy_instance.defeated.connect(_on_boss_add_defeated)
	if not enemy_instance.tree_exited.is_connected(_on_boss_enemy_tree_exited.bind(enemy_id)):
		enemy_instance.tree_exited.connect(_on_boss_enemy_tree_exited.bind(enemy_id))
	_register_multiplayer_enemy_instance(enemy_instance, enemy_config, landing_position)
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
	if active_boss_config == null or ground_tile_map_layer == null:
		return linglan_boss.global_position if linglan_boss != null else Vector2.ZERO
	var arena_rect := _get_boss_arena_floor_rect(active_boss_config)
	if arena_rect.size.x <= 0 or arena_rect.size.y <= 0:
		return _get_boss_arena_center(active_boss_config)
	var min_cell_x := arena_rect.position.x
	var max_cell_x := arena_rect.position.x + arena_rect.size.x - 1
	var min_cell_y := arena_rect.position.y
	var max_cell_y := arena_rect.position.y + arena_rect.size.y - 1
	if arena_rect.size.x > 2:
		min_cell_x += 1
		max_cell_x -= 1
	if arena_rect.size.y > 2:
		min_cell_y += 1
		max_cell_y -= 1
	var target_cell := Vector2i(
		random_generator.randi_range(min_cell_x, max_cell_x),
		random_generator.randi_range(min_cell_y, max_cell_y)
	)
	return _get_tile_cell_global_position(target_cell)


func _try_spawn_boss_add_at_marker(enemy_config: EnemyConfig, marker_name: StringName) -> bool:
	if enemy_config == null:
		return false
	if enemy_container == null or player == null:
		return false
	var spawn_marker := _get_enemy_spawn_marker(marker_name)
	if spawn_marker == null:
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
	enemy_instance.global_position = spawn_marker.global_position
	enemy_instance.setup(enemy_config, _pick_enemy_target(spawn_marker.global_position), grid_pathfinder)
	var enemy_id := enemy_instance.get_instance_id()
	if not enemy_instance.defeated.is_connected(_on_boss_add_defeated):
		enemy_instance.defeated.connect(_on_boss_add_defeated)
	if not enemy_instance.tree_exited.is_connected(_on_boss_enemy_tree_exited.bind(enemy_id)):
		enemy_instance.tree_exited.connect(_on_boss_enemy_tree_exited.bind(enemy_id))
	_register_multiplayer_enemy_instance(enemy_instance, enemy_config, enemy_instance.global_position)
	_spawn_enemy_spawn_effect(spawn_marker.global_position)
	return true


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
	if broadcast_spawn:
		multiplayer_enemy_spawned.emit(enemy_net_id, enemy_config, spawn_position)
	return enemy_net_id


func _on_wave_enemy_defeated(enemy: Enemy) -> void:
	if wave_state != WaveState.WAVE_ACTIVE:
		return
	if enemy == null or not active_wave_enemy_ids.has(enemy.get_instance_id()):
		return

	current_wave_defeated = mini(current_wave_defeated + 1, current_wave_total)
	_emit_multiplayer_enemy_defeated(enemy)
	wave_hud.show_wave_progress(
		current_wave_index + 1,
		current_wave_defeated,
		current_wave_total
	)
	_check_wave_completion()


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
	_mark_multiplayer_enemy_removed(enemy_id)
	_check_wave_completion()


func _mark_multiplayer_enemy_removed(enemy_id: int) -> void:
	if runtime_mode != RuntimeMode.HOST_AUTHORITY:
		return
	var enemy_net_id := int(multiplayer_enemy_ids_by_instance.get(enemy_id, 0))
	multiplayer_enemy_ids_by_instance.erase(enemy_id)
	if enemy_net_id > 0:
		multiplayer_enemies_by_net_id.erase(enemy_net_id)
	if enemy_net_id <= 0 or removed_multiplayer_enemy_ids.has(enemy_net_id):
		return
	removed_multiplayer_enemy_ids[enemy_net_id] = true
	multiplayer_enemy_removed.emit(enemy_net_id)


func _check_wave_completion() -> void:
	if wave_state != WaveState.WAVE_ACTIVE:
		return
	if _has_pending_enemy_configs():
		return
	if current_wave_spawned < current_wave_total:
		return
	if current_wave_defeated < current_wave_total:
		return
	if not active_wave_enemy_ids.is_empty():
		return

	enemy_spawn_timer.stop()
	_complete_current_step()


func _complete_current_step() -> void:
	var next_step := _get_default_next_flow_step(current_flow_step)
	if next_step == null:
		_enter_victory()
		return
	if current_flow_step != null and current_flow_step.post_clear_rest_duration > 0.0:
		_enter_intermission(next_step)
		return
	_begin_flow_step(next_step)


func _enter_victory(emit_multiplayer: bool = true) -> void:
	_cancel_plant_placement()
	if emit_multiplayer and runtime_mode == RuntimeMode.HOST_AUTHORITY:
		multiplayer_revive_all_requested.emit()
	wave_state = WaveState.VICTORY
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


func _enter_defeat() -> void:
	if wave_state == WaveState.DEFEAT:
		return
	_cancel_plant_placement()
	wave_state = WaveState.DEFEAT
	enemy_spawn_timer.stop()
	state_timer.stop()
	_set_merchant_active(false)
	if linglan_boss_intro_vfx != null:
		linglan_boss_intro_vfx.stop_intro()
	if boss_health_hud != null:
		boss_health_hud.hide_all()
	wave_hud.show_defeat()
	if runtime_mode == RuntimeMode.HOST_AUTHORITY:
		multiplayer_defeat_started.emit()


func _begin_linglan_boss_intro(boss_config: BossConfig = null) -> void:
	if boss_config == null:
		boss_config = current_flow_step as BossConfig
	if boss_config == null:
		_enter_victory()
		return
	if not _ensure_linglan_boss_runtime_nodes(boss_config):
		_enter_victory()
		return
	active_boss_config = boss_config
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
	_set_merchant_active(false)
	wave_hud.hide_all()
	_update_boss_music(boss_config)
	_prepare_linglan_boss_arena(boss_config)
	linglan_boss.config = _get_boss_enemy_config(boss_config)
	linglan_boss.global_position = _get_boss_arena_center(boss_config)
	linglan_boss.set_active(false)
	if boss_health_hud != null:
		boss_health_hud.hide_all()
	_emit_multiplayer_flow_state(WaveState.BOSS_INTRO)
	if linglan_boss_intro_vfx != null:
		linglan_boss_intro_vfx.play_intro(_get_boss_arena_center(boss_config))
	else:
		_on_linglan_boss_intro_finished()


func _on_linglan_boss_intro_finished() -> void:
	if wave_state != WaveState.BOSS_INTRO:
		return
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
	linglan_boss.global_position = _get_boss_arena_center(boss_config)
	linglan_boss.activate_boss(player, grid_pathfinder)
	var boss_instance_id := linglan_boss.get_instance_id()
	active_wave_enemy_ids[boss_instance_id] = true
	if not linglan_boss.tree_exited.is_connected(_on_boss_enemy_tree_exited.bind(boss_instance_id)):
		linglan_boss.tree_exited.connect(_on_boss_enemy_tree_exited.bind(boss_instance_id))
	var boss_net_id := _register_multiplayer_enemy_instance(
		linglan_boss,
		_get_boss_enemy_config(boss_config),
		linglan_boss.global_position,
		false
	)
	if boss_health_hud != null:
		boss_health_hud.show_for_boss(linglan_boss, _get_boss_display_name(boss_config))
	_emit_multiplayer_flow_state(WaveState.BOSS_ACTIVE)
	if runtime_mode == RuntimeMode.HOST_AUTHORITY:
		multiplayer_boss_started.emit(boss_net_id, boss_config, linglan_boss.global_position)
		_rebroadcast_linglan_boss_started_after_sync_window(boss_net_id, boss_config)


func _on_boss_enemy_tree_exited(enemy_id: int) -> void:
	active_wave_enemy_ids.erase(enemy_id)
	_mark_multiplayer_enemy_removed(enemy_id)


func _on_boss_add_defeated(enemy: Enemy) -> void:
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
	current_wave_defeated = 1
	_emit_multiplayer_enemy_defeated(enemy)
	var victory_timer := get_tree().create_timer(1.3)
	victory_timer.timeout.connect(_complete_linglan_boss_after_delay)


func _complete_linglan_boss_after_delay() -> void:
	if wave_state != WaveState.BOSS_ACTIVE:
		return
	_complete_current_step()


func _prepare_linglan_boss_arena(boss_config: Resource) -> void:
	if boss_config == null:
		return
	if ground_tile_map_layer == null:
		return
	var arena_rect := _get_boss_arena_floor_rect(boss_config)
	if arena_rect.size.x <= 0 or arena_rect.size.y <= 0:
		return
	for cell_x in range(arena_rect.position.x, arena_rect.position.x + arena_rect.size.x):
		for cell_y in range(arena_rect.position.y, arena_rect.position.y + arena_rect.size.y):
			ground_tile_map_layer.set_cell(
				Vector2i(cell_x, cell_y),
				_get_boss_floor_source_id(boss_config),
				_get_boss_floor_atlas_coords(boss_config),
				0
			)
	if _should_clear_boss_inner_overlay_cells(boss_config) and overlay_tile_map_layer != null:
		for cell in overlay_tile_map_layer.get_used_cells():
			if arena_rect.has_point(cell):
				overlay_tile_map_layer.erase_cell(cell)
	if grid_pathfinder != null and grid_pathfinder.has_method("rebuild"):
		grid_pathfinder.call("rebuild")


func _on_player_died() -> void:
	_cancel_plant_placement()
	_update_plant_placement_input_state()
	if wave_state == WaveState.VICTORY:
		return
	_enter_defeat()


func _on_multiplayer_player_died(_peer_id: int) -> void:
	if runtime_mode != RuntimeMode.HOST_AUTHORITY:
		return
	if wave_state == WaveState.VICTORY or wave_state == WaveState.DEFEAT:
		return
	if multiplayer_defeat_check_pending:
		return
	multiplayer_defeat_check_pending = true
	var defeat_timer := get_tree().create_timer(MULTIPLAYER_DEFEAT_GRACE_SECONDS)
	defeat_timer.timeout.connect(_check_multiplayer_defeat_after_grace)


func _check_multiplayer_defeat_after_grace() -> void:
	multiplayer_defeat_check_pending = false
	if runtime_mode != RuntimeMode.HOST_AUTHORITY:
		return
	if wave_state == WaveState.VICTORY or wave_state == WaveState.DEFEAT:
		return
	for peer_id_variant in peer_players:
		var candidate := peer_players[peer_id_variant] as Player
		if candidate != null and is_instance_valid(candidate) and not candidate.is_dead:
			return
	_enter_defeat()


func _configure_multiplayer_players() -> void:
	player = null
	peer_players.clear()
	if multiplayer_player_names.is_empty():
		multiplayer_player_names[multiplayer_local_peer_id if multiplayer_local_peer_id > 0 else 1] = "Player"

	var peer_ids: Array[int] = []
	for peer_id_variant in multiplayer_player_names:
		peer_ids.append(int(peer_id_variant))
	peer_ids.sort()

	var base_position := player_spawn.position
	for index in range(peer_ids.size()):
		var peer_id := peer_ids[index]
		var character_id := _get_multiplayer_character_id(peer_id)
		var player_instance := _instantiate_player_character(character_id)
		if player_instance == null:
			continue
		player_instance.name = "Player_%d" % peer_id
		player_instance.position = base_position + _get_multiplayer_spawn_offset(index)
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
		if (
			(runtime_mode == RuntimeMode.CLIENT_VIEW and not predicts_local_movement)
			or (runtime_mode == RuntimeMode.HOST_AUTHORITY and peer_id != multiplayer_local_peer_id)
		):
			player_instance.set_physics_process(false)
		if not player_instance.died.is_connected(_on_multiplayer_player_died.bind(peer_id)):
			player_instance.died.connect(_on_multiplayer_player_died.bind(peer_id))
		peer_players[peer_id] = player_instance
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
	const OFFSETS := [
		Vector2.ZERO,
		Vector2(18.0, 0.0),
		Vector2(0.0, 18.0),
		Vector2(18.0, 18.0),
		Vector2(-18.0, 0.0),
		Vector2(0.0, -18.0),
		Vector2(-18.0, -18.0),
		Vector2(18.0, -18.0),
	]
	return OFFSETS[index % OFFSETS.size()]


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
	var player_instance := peer_players.get(peer_id) as Player
	peer_players.erase(peer_id)
	multiplayer_player_names.erase(peer_id)
	multiplayer_player_character_ids.erase(peer_id)
	if player_instance != null and is_instance_valid(player_instance):
		player_instance.queue_free()
	if runtime_mode == RuntimeMode.HOST_AUTHORITY:
		_check_multiplayer_defeat_after_grace()


func get_player_for_peer(peer_id: int) -> Player:
	return peer_players.get(peer_id) as Player


func get_enemy_for_net_id(net_id: int) -> Enemy:
	if not multiplayer_enemies_by_net_id.has(net_id):
		return null
	var enemy_variant: Variant = multiplayer_enemies_by_net_id.get(net_id)
	if enemy_variant == null:
		multiplayer_enemies_by_net_id.erase(net_id)
		return null
	if not is_instance_valid(enemy_variant):
		multiplayer_enemies_by_net_id.erase(net_id)
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
	removed_multiplayer_pickup_ids.clear()
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
	var pickups: Array[Pickup] = []
	_collect_pickups_recursive(self, pickups)
	for pickup in pickups:
		if pickup == null or not is_instance_valid(pickup):
			continue
		if int(pickup.get_meta("net_id", 0)) > 0:
			continue
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
	_mark_multiplayer_pickup_removed(net_id)
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


func _mark_multiplayer_pickup_removed(net_id: int) -> void:
	if removed_multiplayer_pickup_ids.has(net_id):
		return
	removed_multiplayer_pickup_ids[net_id] = true
	multiplayer_pickups.erase(net_id)
	multiplayer_pickup_removed.emit(net_id)


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
	var states: Array[SnapshotManager.EnemyState] = []
	_collect_enemy_snapshot_states_from_container(enemy_container, states)
	_collect_enemy_snapshot_states_from_container(boss_container, states)
	return states


func _collect_enemy_snapshot_states_from_container(
	container: Node,
	states: Array[SnapshotManager.EnemyState]
) -> void:
	if container == null:
		return
	for child in container.get_children():
		var enemy := child as Enemy
		if enemy == null or not is_instance_valid(enemy):
			continue
		var state := SnapshotManager.EnemyState.new()
		state.net_id = int(enemy.get_meta("net_id", enemy.get_instance_id()))
		state.position = enemy.global_position
		state.velocity = enemy.velocity
		state.health = enemy.current_health
		state.is_dead = enemy.is_dead
		states.append(state)


func _update_multiplayer_enemy_targets(delta: float) -> void:
	enemy_retarget_time_left = maxf(enemy_retarget_time_left - delta, 0.0)
	if enemy_retarget_time_left > 0.0:
		return
	enemy_retarget_time_left = 0.35
	for child in enemy_container.get_children():
		var enemy := child as Enemy
		if enemy == null or enemy.is_dead:
			continue
		enemy.set_target_player(_pick_enemy_target(enemy.global_position))


func _pick_enemy_target(from_position: Vector2) -> Player:
	if runtime_mode != RuntimeMode.HOST_AUTHORITY:
		return player
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
	return best_player if best_player != null else player


func get_linglan_skill2_target_global_position(target_cell: Vector2i) -> Vector2:
	if ground_tile_map_layer != null:
		return ground_tile_map_layer.to_global(ground_tile_map_layer.map_to_local(target_cell))
	if active_boss_config != null:
		return _get_boss_arena_center(active_boss_config)
	return Vector2.ZERO


func get_linglan_skill3_target_global_position(target_cell: Vector2i) -> Vector2:
	if ground_tile_map_layer != null:
		return ground_tile_map_layer.to_global(ground_tile_map_layer.map_to_local(target_cell))
	if active_boss_config != null:
		return _get_boss_arena_center(active_boss_config)
	return Vector2.ZERO


func get_linglan_skill4_target_global_position(
	target_cell_a: Vector2i,
	target_cell_b: Vector2i
) -> Vector2:
	if ground_tile_map_layer != null:
		return (
			_get_tile_cell_global_position(target_cell_a)
			+ _get_tile_cell_global_position(target_cell_b)
		) * 0.5
	if active_boss_config != null:
		return _get_boss_arena_center(active_boss_config)
	return Vector2.ZERO


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
	var start_a := _get_tile_cell_global_position(Vector2i(left_cell_x, top_cell_y))
	var start_b := _get_tile_cell_global_position(Vector2i(right_cell_x, bottom_cell_y))
	var final_a := _get_tile_cell_global_position(Vector2i(
		left_cell_x + inward_cell_distance,
		top_cell_y + inward_cell_distance
	))
	var final_b := _get_tile_cell_global_position(Vector2i(
		right_cell_x - inward_cell_distance,
		bottom_cell_y - inward_cell_distance
	))
	return {
		"start_min": Vector2(minf(start_a.x, start_b.x), minf(start_a.y, start_b.y)),
		"start_max": Vector2(maxf(start_a.x, start_b.x), maxf(start_a.y, start_b.y)),
		"final_min": Vector2(minf(final_a.x, final_b.x), minf(final_a.y, final_b.y)),
		"final_max": Vector2(maxf(final_a.x, final_b.x), maxf(final_a.y, final_b.y)),
	}


func get_linglan_skill4_orb_spawn_global_position(x_cell: int, y_cell: int) -> Vector2:
	if ground_tile_map_layer != null:
		return _get_tile_cell_global_position(Vector2i(x_cell, y_cell))
	if active_boss_config != null:
		return _get_boss_arena_center(active_boss_config)
	return Vector2.ZERO


func _get_tile_cell_global_position(cell: Vector2i) -> Vector2:
	return ground_tile_map_layer.to_global(ground_tile_map_layer.map_to_local(cell))


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


func _is_wave_system_ready() -> bool:
	if not _is_spawn_system_ready():
		return false
	if waves.is_empty():
		push_warning("Game 场景没有配置任何波次资源。")
		return false
	for wave_config in waves:
		if wave_config == null:
			push_warning("Game 场景的波次数组包含空资源。")
			return false
	return true


func _is_flow_system_ready() -> bool:
	if flow_graph == null:
		push_warning("Game 场景没有配置 FlowGraphConfig。")
		return _is_wave_system_ready()
	if not _is_spawn_system_ready():
		return false
	var errors := flow_graph.validate_graph()
	for error in errors:
		push_warning(error)
	if not errors.is_empty():
		return false
	return _get_start_flow_step() != null


func _get_start_flow_step() -> FlowStepConfig:
	if flow_graph != null and flow_graph.start_step != null:
		return flow_graph.start_step
	if not waves.is_empty():
		return waves[0]
	return null


func _get_flow_step_by_id(step_id: StringName) -> FlowStepConfig:
	if step_id == &"":
		return null
	if flow_graph != null:
		var flow_step := flow_graph.get_step_by_id(step_id)
		if flow_step != null:
			return flow_step
	for wave_config in waves:
		if wave_config != null and wave_config.step_id == step_id:
			return wave_config
	for boss_resource in bosses:
		var boss_config := boss_resource as BossConfig
		if boss_config != null and boss_config.step_id == step_id:
			return boss_config
	return null


func _get_flow_step_id(flow_step: FlowStepConfig) -> StringName:
	return flow_step.step_id if flow_step != null else &""


func _get_default_next_flow_step(flow_step: FlowStepConfig) -> FlowStepConfig:
	if flow_step == null:
		return null
	if flow_graph != null and flow_graph.get_step_index(flow_step) >= 0:
		return flow_graph.get_default_next_step(flow_step)
	var default_exit := flow_step.get_default_exit()
	if default_exit == null:
		return null
	if default_exit.target_step != null:
		return default_exit.target_step
	return _get_flow_step_by_id(default_exit.target_step_id)


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
	var intro_scene := _load_threaded_or_direct(_get_boss_intro_vfx_scene_path(boss_config)) as PackedScene
	if intro_scene == null:
		return
	if linglan_boss_intro_vfx == null or not is_instance_valid(linglan_boss_intro_vfx):
		linglan_boss_intro_vfx = intro_scene.instantiate() as LinglanBossIntroVFX
		if linglan_boss_intro_vfx == null:
			return
		linglan_boss_intro_vfx.name = "LinglanBossIntroVFX"
		add_child(linglan_boss_intro_vfx)
	linglan_boss_intro_vfx.play_intro(_get_boss_arena_center(boss_config))


func _is_spawn_system_ready() -> bool:
	return (
		player != null
		and grid_pathfinder != null
		and grid_pathfinder.get("is_built")
		and not enemy_spawn_points.is_empty()
	)


func _get_current_wave() -> WaveConfig:
	var flow_wave := current_flow_step as WaveConfig
	if flow_wave != null:
		return flow_wave
	if current_wave_index < 0 or current_wave_index >= waves.size():
		return null
	return waves[current_wave_index]


func _pick_spawn_point() -> Marker2D:
	if enemy_spawn_points.is_empty():
		return null
	return enemy_spawn_points[
		random_generator.randi_range(0, enemy_spawn_points.size() - 1)
	]


func _spawn_enemy_spawn_effect(spawn_global_position: Vector2) -> void:
	if not _consume_spawn_effect_budget():
		return
	var effect := ENEMY_SPAWN_EFFECT_SCENE.instantiate() as Node2D
	if effect == null:
		return
	add_child(effect)
	effect.global_position = spawn_global_position


func play_remote_enemy_spawn_effect(spawn_global_position: Vector2) -> void:
	_spawn_enemy_spawn_effect(spawn_global_position)


func _consume_spawn_effect_budget() -> bool:
	var now := Time.get_ticks_msec()
	if now - spawn_effect_budget_started_msec >= 1000:
		spawn_effect_budget_started_msec = now
		spawn_effects_this_second = 0
	if spawn_effects_this_second >= SPAWN_EFFECTS_PER_SECOND_LIMIT:
		return false
	spawn_effects_this_second += 1
	return true


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
