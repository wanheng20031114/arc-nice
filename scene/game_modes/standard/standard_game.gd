extends WaveCombatRuntimeBase
class_name StandardGame

const TANGO_LASER_BULLET_POOL_SCENE := preload(
	"res://scene/player/tango/tango_laser_bullet.tscn"
)
const TANGO_MINIMUM_CHARGE_SECONDS := 0.2
const TANGO_MAXIMUM_CHARGE_SECONDS := 2.4
const TANGO_CHARGE_THRESHOLD_EPSILON := 0.0001

const LINGLAN_SKILL1_BULLET_POOL_SCENE := preload(
	"res://scene/boss/linglan/linglan_skill1_sakura_bullet.tscn"
)
const LINGLAN_SAKURA_HIT_EFFECT_POOL_SCENE := preload(
	"res://scene/boss/linglan/linglan_sakura_hit_effect.tscn"
)
const LINGLAN_BOSS_INTRO_VFX_SCENE_PATH := (
	"res://scene/boss/linglan/linglan_boss_intro_vfx.tscn"
)
const BOSS_HEALTH_HUD_SCENE_PATH := (
	"res://scene/boss/linglan/boss_health_hud.tscn"
)
const LINGLAN_ENRAGE_SNIPER_CONFIG_PATH := (
	"res://resources/config/enemies/capoo_sniper.tres"
)
const DEFAULT_MUSIC_VOLUME_DB := -6.0
const MUSIC_FADE_IN_SECONDS := 3.0
const MUSIC_FADE_IN_START_VOLUME_DB := -12.0
const INITIAL_PLAYER_XIRANG := 1000

@export_group("普通模式规则")
@export var linglan_boss_enabled: bool = true
@export var standard_merchants_enabled: bool = true

@onready var ground_tile_map_layer: TileMapLayer = $GroundTileMapLayer
@onready var overlay_tile_map_layer: TileMapLayer = $OverlayTileMapLayer
@onready var music_player: AudioStreamPlayer = $MusicPlayer
@onready var countdown_audio: AudioStreamPlayer = $CountdownAudio
@onready var wave_start_audio: AudioStreamPlayer = $WaveStartAudio
@onready var currency_hud: CurrencyHUD = $CurrencyHUD
@onready var wave_hud: StandardWaveHUD = $WaveHUD
@onready var player_profile_panel: StandardPlayerProfilePanel = $PlayerProfilePanel
@onready var settings_panel: SettingsPanel = $SettingsLayer/SettingsPanel
@onready var debug_collectible_window: DebugCollectibleWindow = (
	$SettingsLayer/DebugCollectibleWindow
)
@onready var merchant: ZhuangfangyiMerchant = _resolve_zhuangfangyi_merchant()
@onready var luoxi_merchant: LuoxiMerchant = _resolve_luoxi_merchant()
@onready var boss_container: Node2D = $BossContainer
@onready var linglan_boss_runtime_port: LinglanBossRuntimePort = (
	$LinglanBossRuntimePort
)
var campaign_wave_coordinator: StandardCampaignWaveCoordinator:
	get:
		return get_node("CampaignWaveCoordinator") as StandardCampaignWaveCoordinator

var _singleplayer_tango_charge_started_at: float = -1.0
var bosses: Array[Resource]:
	get:
		return (
			campaign_wave_coordinator.bosses
			if campaign_wave_coordinator != null
			else []
		)
	set(value):
		if campaign_wave_coordinator != null:
			campaign_wave_coordinator.replace_bosses(value)
var music_fade_tween: Tween = null
var luoxi_collectible_claim_counts: Dictionary = {}
var linglan_boss_started: bool = false
var active_boss_config: Resource
var linglan_boss: LinglanBoss = null
var linglan_boss_intro_vfx: LinglanBossIntroVFX = null
var boss_health_hud: BossHealthHUD = null
var boss_runtime_scene_loads_requested: bool = false
var linglan_enrage_sniper_config: EnemyConfig = null
var boss_runtime_resources_by_path: Dictionary[String, Resource] = {}


func _ready() -> void:
	super._ready()


func _get_default_mode_definition() -> GameModeDefinition:
	return GameModeCatalog.get_definition(GameModeCatalog.MODE_STANDARD)


func _initialize_mode_runtime_before_validation() -> void:
	campaign_wave_coordinator.bind_presentation(
		wave_hud,
		countdown_audio,
		wave_start_audio
	)
	if not campaign_wave_coordinator.wave_music_requested.is_connected(
		_update_wave_music
	):
		campaign_wave_coordinator.wave_music_requested.connect(
			_update_wave_music
		)
	if not campaign_wave_coordinator.post_wave_music_requested.is_connected(
		_update_post_wave_music
	):
		campaign_wave_coordinator.post_wave_music_requested.connect(
			_update_post_wave_music
		)
	if not campaign_wave_coordinator.boss_step_requested.is_connected(
		_on_campaign_boss_step_requested
	):
		campaign_wave_coordinator.boss_step_requested.connect(
			_on_campaign_boss_step_requested
		)
	if not campaign_wave_coordinator.remote_boss_state_requested.is_connected(
		_on_campaign_remote_boss_state_requested
	):
		campaign_wave_coordinator.remote_boss_state_requested.connect(
			_on_campaign_remote_boss_state_requested
		)
	if merchant != null:
		merchant.bind_multiplayer_mode_adapter(multiplayer_mode_adapter)
	if luoxi_merchant != null:
		luoxi_merchant.bind_multiplayer_mode_adapter(multiplayer_mode_adapter)


func _validate_mode_scene_content() -> bool:
	if campaign_wave_coordinator == null:
		push_error("StandardGame: 缺少静态 CampaignWaveCoordinator 节点。")
		return false
	if linglan_boss_enabled and linglan_boss_runtime_port == null:
		push_error("StandardGame: 场景启用了铃兰 Boss，但缺少静态运行时端口。")
		return false
	if not standard_merchants_enabled:
		return true
	if merchant != null and luoxi_merchant != null:
		return true
	push_error("StandardGame: 场景启用了标准商人能力，但缺少对应静态节点。")
	return false


func _configure_active_campaign() -> bool:
	if not super._configure_active_campaign():
		return false
	return campaign_wave_coordinator.initialize_campaign(active_campaign)


func _register_mode_object_pools() -> void:
	session_object_pool.register_scene(TANGO_LASER_BULLET_POOL_SCENE, 64, 768)
	session_object_pool.register_scene(LINGLAN_SKILL1_BULLET_POOL_SCENE, 64, 768)
	session_object_pool.register_scene(LINGLAN_SAKURA_HIT_EFFECT_POOL_SCENE, 16, 96)


func _connect_mode_dynamic_pickup_containers() -> void:
	if not boss_container.child_entered_tree.is_connected(
		_on_dynamic_pickup_container_child_entered
	):
		boss_container.child_entered_tree.connect(
			_on_dynamic_pickup_container_child_entered
		)


func _register_additional_dynamic_multiplayer_pickups() -> void:
	for child in boss_container.get_children():
		_register_dynamic_multiplayer_pickup(child as Pickup)


func _initialize_mode_player_ui() -> void:
	currency_hud.bind_player(player)
	player_profile_panel.configure_multiplayer_requests(
		runtime_mode != RuntimeMode.SINGLEPLAYER
	)
	player_profile_panel.bind_player(player)
	currency_hud.settings_requested.connect(_on_currency_hud_settings_requested)
	currency_hud.profile_requested.connect(player_profile_panel.open)
	settings_panel.closed.connect(_on_settings_panel_closed)
	debug_collectible_window.collectible_requested.connect(
		_on_debug_collectible_requested
	)
	debug_collectible_window.closed.connect(_on_debug_collectible_window_closed)
	wave_hud.set_return_button_text(
		"返回菜单" if runtime_mode == RuntimeMode.SINGLEPLAYER else "返回大厅"
	)
	if not wave_hud.return_to_lobby_requested.is_connected(
		_on_wave_hud_return_to_lobby_requested
	):
		wave_hud.return_to_lobby_requested.connect(
			_on_wave_hud_return_to_lobby_requested
		)


func _initialize_mode_runtime_content() -> void:
	_set_merchant_active(false)
	_configure_linglan_boss()
	call_deferred("_deferred_request_boss_runtime_scene_loads")


func _apply_initial_player_resources() -> void:
	_apply_initial_player_xirang()


func _set_intermission_services_active(active: bool) -> void:
	_set_merchant_active(active)


func _present_flow_countdown(
	_state: CombatFlowState.State,
	seconds: int
) -> void:
	campaign_wave_coordinator.present_flow_countdown(seconds)


func _present_wave_started(
	wave_config: WaveConfig,
	is_remote: bool
) -> void:
	campaign_wave_coordinator.present_wave_started(
		wave_config,
		is_remote,
		current_wave_index + 1,
		current_wave_defeated,
		current_wave_total
	)


func _present_wave_progress(defeated_count: int, total_count: int) -> void:
	campaign_wave_coordinator.present_wave_progress(
		current_wave_index + 1,
		defeated_count,
		total_count
	)


func _present_remote_enemy_count(alive_count: int) -> void:
	campaign_wave_coordinator.present_remote_enemy_count(
		current_wave_index + 1,
		alive_count
	)


func _present_terminal_state(victory: bool) -> void:
	if linglan_boss_intro_vfx != null:
		linglan_boss_intro_vfx.stop_intro()
	if boss_health_hud != null:
		boss_health_hud.hide_all()
	if victory:
		wave_hud.show_victory()
	else:
		wave_hud.show_defeat()


func _hide_mode_wave_presentation() -> void:
	campaign_wave_coordinator.hide_wave_presentation()


func _present_countdown_tick() -> void:
	campaign_wave_coordinator.present_countdown_tick()


func _present_intermission_started(cleared_step: FlowStepConfig) -> void:
	campaign_wave_coordinator.present_intermission_started(cleared_step)


func _begin_mode_flow_step(flow_step: FlowStepConfig) -> bool:
	return campaign_wave_coordinator.begin_mode_flow_step(flow_step)


func _apply_remote_mode_flow_state(
	state: CombatFlowState.State,
	flow_step: FlowStepConfig
) -> bool:
	return campaign_wave_coordinator.apply_remote_mode_flow_state(
		state,
		flow_step
	)


func _on_campaign_boss_step_requested(boss_config: BossConfig) -> void:
	_begin_linglan_boss_intro(boss_config)


func _on_campaign_remote_boss_state_requested(
	state: CombatFlowState.State,
	boss_config: BossConfig
) -> void:
	match state:
		CombatFlowState.State.BOSS_INTRO:
			state_timer.stop()
			wave_state = state
			_set_intermission_services_active(false)
			wave_hud.hide_all()
			active_boss_config = boss_config
			_update_boss_music(boss_config)
			_prepare_linglan_boss_arena(boss_config)
			_play_remote_boss_intro(boss_config)
		CombatFlowState.State.BOSS_ACTIVE:
			state_timer.stop()
			wave_state = state
			_set_intermission_services_active(false)
			wave_hud.hide_all()
			if linglan_boss_intro_vfx != null:
				linglan_boss_intro_vfx.stop_intro()
			active_boss_config = boss_config
			_update_boss_music(boss_config)


func _prewarm_mode_runtime_data() -> void:
	await _prewarm_boss_runtime_resources()


func _on_multiplayer_peer_restored(old_peer_id: int, new_peer_id: int) -> void:
	if not luoxi_collectible_claim_counts.has(old_peer_id):
		return
	luoxi_collectible_claim_counts[new_peer_id] = (
		luoxi_collectible_claim_counts[old_peer_id]
	)
	luoxi_collectible_claim_counts.erase(old_peer_id)


func allows_debug_collectible_grants() -> bool:
	return OS.is_debug_build()


func _resolve_zhuangfangyi_merchant() -> ZhuangfangyiMerchant:
	if not _uses_standard_merchants():
		return null
	return get_node("ZhuangfangyiMerchant") as ZhuangfangyiMerchant

func _resolve_luoxi_merchant() -> LuoxiMerchant:
	if not _uses_standard_merchants():
		return null
	return get_node("LuoxiMerchant") as LuoxiMerchant


func _uses_standard_merchants() -> bool:
	return standard_merchants_enabled

func _uses_linglan_boss_flow() -> bool:
	return linglan_boss_enabled

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("full_screen"):
		_toggle_full_screen()
		get_viewport().set_input_as_handled()
		return

	if event.is_action_pressed("cheat_collectibles"):
		_toggle_debug_collectible_window()
		get_viewport().set_input_as_handled()

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
	if player_profile_panel.is_open():
		player_profile_panel.close()
	settings_panel.open()
	_lock_player_for_modal_ui()

func _on_settings_panel_closed() -> void:
	_refresh_player_modal_ui_lock()

func _on_debug_collectible_window_closed() -> void:
	_refresh_player_modal_ui_lock()

func _lock_player_for_modal_ui() -> void:
	if player != null and not player.is_dead:
		player.set_controls_locked(true)

func _refresh_player_modal_ui_lock() -> void:
	if player == null or player.is_dead:
		return
	if settings_panel.is_open() or player_profile_panel.is_open() or debug_collectible_window.is_open():
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
	if debug_collectible_window == null or not allows_debug_collectible_grants():
		return
	debug_collectible_window.toggle()
	if debug_collectible_window.is_open():
		_lock_player_for_modal_ui()
	else:
		_refresh_player_modal_ui_lock()

func _on_debug_collectible_requested(config_path: String) -> void:
	if config_path.is_empty():
		return
	if (
		runtime_mode != RuntimeMode.SINGLEPLAYER
		and multiplayer_mode_adapter.request_debug_collectible(config_path)
	):
		return
	debug_collectible_window.show_grant_result(config_path, grant_debug_collectible(config_path))

func grant_debug_collectible(config_path: String) -> bool:
	if not allows_debug_collectible_grants():
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

func _on_profile_multiplayer_upgrade_requested(stat_type: int) -> void:
	multiplayer_mode_adapter.profile_upgrade_requested.emit(stat_type)

func _on_profile_multiplayer_inventory_item_use_requested(
	slot_index: int
) -> void:
	multiplayer_mode_adapter.profile_inventory_item_use_requested.emit(slot_index)

func _on_profile_multiplayer_inventory_item_discard_requested(
	slot_index: int
) -> void:
	multiplayer_mode_adapter.profile_inventory_item_discard_requested.emit(slot_index)

func _on_profile_multiplayer_simple_crafting_requested(
	recipe_id: StringName,
	request_token: int
) -> void:
	multiplayer_mode_adapter.profile_simple_crafting_requested.emit(
		recipe_id,
		request_token
	)

func _on_profile_multiplayer_simple_crafting_cancel_requested(
	request_token: int
) -> void:
	multiplayer_mode_adapter.profile_simple_crafting_cancel_requested.emit(request_token)

func apply_remote_merchant_active(active: bool) -> void:
	_set_local_merchants_active(active)
	if runtime_mode != RuntimeMode.CLIENT_VIEW:
		return
	if not active and (wave_state == CombatFlowState.State.PRE_WAVE or wave_state == CombatFlowState.State.INTERMISSION):
		state_timer.stop()

func apply_remote_boss_started(net_id: int, boss_config: BossConfig, spawn_position: Vector2) -> void:
	if runtime_mode != RuntimeMode.CLIENT_VIEW or boss_config == null:
		return
	if linglan_boss_intro_vfx != null:
		linglan_boss_intro_vfx.stop_intro()
	active_boss_config = boss_config
	current_flow_step = boss_config
	wave_state = CombatFlowState.State.BOSS_ACTIVE
	state_timer.stop()
	if wave_hud != null:
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
	boss_enemy.setup(
		enemy_config,
		player,
		grid_pathfinder,
		self,
		linglan_boss_runtime_port
	)
	boss_enemy.configure_multiplayer_proxy()
	boss_enemy.set_meta("net_id", net_id)
	multiplayer_enemies_by_net_id[net_id] = boss_enemy
	register_combat_target(net_id, boss_enemy)
	multiplayer_enemy_ids_by_instance[boss_enemy.get_instance_id()] = net_id
	return boss_enemy

func try_purchase_skill1_for_peer(peer_id: int) -> int:
	var player_instance := get_player_for_peer(peer_id)
	if player_instance == null or not is_instance_valid(player_instance):
		return MerchantPurchaseResult.SkillUpgrade.INVALID_PLAYER
	if not player_instance.has_skill1():
		return MerchantPurchaseResult.SkillUpgrade.INVALID_PLAYER
	if player_instance.is_skill1_upgrade_maxed():
		return MerchantPurchaseResult.SkillUpgrade.UPGRADE_MAXED
	var free_upgrade := player_instance.has_collectible_effect(
		PickupConfig.COLLECTIBLE_EFFECT_ADMIN_DOLL
	)
	if not player_instance.try_upgrade_skill1(free_upgrade):
		return MerchantPurchaseResult.SkillUpgrade.INSUFFICIENT_XIRANG
	return MerchantPurchaseResult.SkillUpgrade.UPGRADE_SUCCESS

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
		return MerchantPurchaseResult.OfferRefresh.INVALID_PLAYER
	if has_luoxi_collectible_claimed(peer_id):
		return MerchantPurchaseResult.OfferRefresh.INVALID_PLAYER
	return luoxi_merchant.try_purchase_refresh_for_player(player_instance)

func get_luoxi_collectible_refresh_count(peer_id: int) -> int:
	if luoxi_merchant == null:
		return 0
	return luoxi_merchant.get_player_refresh_count(maxi(peer_id, 0))

func try_claim_luoxi_collectible_for_peer(peer_id: int, config_path_or_choice: Variant) -> int:
	var player_instance := player if peer_id <= 0 else get_player_for_peer(peer_id)
	if player_instance == null or not is_instance_valid(player_instance):
		return MerchantPurchaseResult.CollectibleClaim.INVALID_PLAYER

	var claim_key := maxi(peer_id, 0)
	if get_luoxi_collectible_claim_count(claim_key) >= LuoxiMerchant.COLLECTIBLE_CLAIMS_PER_ROUND:
		return MerchantPurchaseResult.CollectibleClaim.ALREADY_CLAIMED

	var config_path := ""
	if typeof(config_path_or_choice) == TYPE_INT:
		config_path = _resolve_luoxi_collectible_path(int(config_path_or_choice), "")
	else:
		config_path = String(config_path_or_choice)
	var item := LuoxiMerchant.get_collectible_for_path(config_path)
	if item == null:
		return MerchantPurchaseResult.CollectibleClaim.INVALID_PLAYER
	if not player_instance.is_collectible_compatible(item):
		return MerchantPurchaseResult.CollectibleClaim.INVALID_PLAYER
	if not LuoxiMerchant.is_collectible_available_for_inventory(item, run_state, peer_id):
		return MerchantPurchaseResult.CollectibleClaim.INVALID_PLAYER

	var stored := (
		run_state.try_add_item_for_peer(peer_id, item)
		if peer_id > 0
		else run_state.try_add_item(item)
	)
	if not stored:
		return MerchantPurchaseResult.CollectibleClaim.INVENTORY_FULL

	record_luoxi_collectible_claim(claim_key)
	return MerchantPurchaseResult.CollectibleClaim.SUCCESS

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
		get_tree().change_scene_to_file("res://scene/main_menu.tscn")
		return
	multiplayer_mode_adapter.return_to_lobby_requested.emit()

func _set_merchant_active(active: bool) -> void:
	var changed := _set_local_merchants_active(active)
	if not changed:
		return
	if runtime_mode == RuntimeMode.HOST_AUTHORITY:
		multiplayer_mode_adapter.merchant_active_changed.emit(active)

func _set_local_merchants_active(active: bool) -> bool:
	var changed := false
	if merchant != null and merchant.is_active != active:
		merchant.set_active(active)
		changed = true
	if luoxi_merchant != null and luoxi_merchant.is_active != active:
		if active:
			luoxi_collectible_claim_counts.clear()
			luoxi_merchant.reset_intermission_state()
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
	if not _uses_linglan_boss_flow():
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
	paths.append(LINGLAN_ENRAGE_SNIPER_CONFIG_PATH)
	return paths

func _prewarm_boss_runtime_resources() -> void:
	if not _uses_linglan_boss_flow():
		return
	_request_boss_runtime_scene_loads()
	for resource_path in _get_boss_runtime_resource_paths():
		if boss_runtime_resources_by_path.has(resource_path):
			continue
		var status := ResourceLoader.load_threaded_get_status(resource_path)
		while status == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
			await get_tree().process_frame
			if not is_inside_tree():
				return
			status = ResourceLoader.load_threaded_get_status(resource_path)
		var runtime_resource := (
			ResourceLoader.load_threaded_get(resource_path)
			if status == ResourceLoader.THREAD_LOAD_LOADED
			else load(resource_path)
		)
		if runtime_resource != null:
			boss_runtime_resources_by_path[resource_path] = runtime_resource

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
	await get_tree().process_frame
	if not is_inside_tree():
		return
	_request_boss_runtime_scene_loads()

func _get_first_boss_config() -> Resource:
	for boss_config in campaign_wave_coordinator.get_configured_bosses():
		if _boss_config_has_required_data(boss_config):
			return boss_config
	return null

func _get_configured_bosses() -> Array[BossConfig]:
	return campaign_wave_coordinator.get_configured_bosses()

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
	linglan_boss.bind_combat_runtime(self)
	linglan_boss.bind_linglan_runtime_port(linglan_boss_runtime_port)

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
	if wave_state != CombatFlowState.State.BOSS_ACTIVE:
		return
	if enemy_config == null or enemy_config.enemy_scene == null:
		return
	var landing_position := _get_random_linglan_boss_arena_position()
	if runtime_mode == RuntimeMode.HOST_AUTHORITY:
		linglan_boss_runtime_port.airdrop_started.emit(
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
	if wave_state != CombatFlowState.State.BOSS_ACTIVE:
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
	enemy_instance.setup(
		enemy_config,
		_pick_enemy_target(landing_position),
		grid_pathfinder,
		self
	)
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
	if wave_state != CombatFlowState.State.BOSS_ACTIVE:
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
	enemy_instance.setup(
		enemy_config,
		_pick_enemy_target(spawn_marker.global_position),
		grid_pathfinder,
		self
	)
	var enemy_id := enemy_instance.get_instance_id()
	if not enemy_instance.defeated.is_connected(_on_boss_add_defeated):
		enemy_instance.defeated.connect(_on_boss_add_defeated)
	if not enemy_instance.tree_exited.is_connected(_on_boss_enemy_tree_exited.bind(enemy_id)):
		enemy_instance.tree_exited.connect(_on_boss_enemy_tree_exited.bind(enemy_id))
	_register_multiplayer_enemy_instance(enemy_instance, enemy_config, enemy_instance.global_position)
	_spawn_enemy_spawn_effect(spawn_marker.global_position)
	return true

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
	wave_state = CombatFlowState.State.BOSS_INTRO
	enemy_spawn_timer.stop()
	state_timer.stop()
	_clear_pending_enemy_spawn_queue()
	active_wave_enemy_ids.clear()
	current_wave_total = 1
	current_wave_spawned = 1
	current_wave_defeated = 0
	_set_merchant_active(false)
	if wave_hud != null:
		wave_hud.hide_all()
	_update_boss_music(boss_config)
	_prepare_linglan_boss_arena(boss_config)
	linglan_boss.config = _get_boss_enemy_config(boss_config)
	linglan_boss.global_position = _get_boss_arena_center(boss_config)
	linglan_boss.set_active(false)
	if boss_health_hud != null:
		boss_health_hud.hide_all()
	_emit_multiplayer_flow_state(CombatFlowState.State.BOSS_INTRO)
	if linglan_boss_intro_vfx != null:
		linglan_boss_intro_vfx.play_intro(_get_boss_arena_center(boss_config))
	else:
		_on_linglan_boss_intro_finished()

func _on_linglan_boss_intro_finished() -> void:
	if wave_state != CombatFlowState.State.BOSS_INTRO:
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
	wave_state = CombatFlowState.State.BOSS_ACTIVE
	linglan_boss.config = _get_boss_enemy_config(boss_config)
	linglan_boss.global_position = _get_boss_arena_center(boss_config)
	linglan_boss.activate_boss(
		player,
		grid_pathfinder,
		self,
		linglan_boss_runtime_port
	)
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
	_emit_multiplayer_flow_state(CombatFlowState.State.BOSS_ACTIVE)
	if runtime_mode == RuntimeMode.HOST_AUTHORITY:
		multiplayer_mode_adapter.boss_started.emit(boss_net_id, boss_config, linglan_boss.global_position)
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
	if wave_state != CombatFlowState.State.BOSS_ACTIVE:
		return
	if linglan_boss == null or not is_instance_valid(linglan_boss):
		return
	multiplayer_mode_adapter.boss_started.emit(boss_net_id, boss_config, linglan_boss.global_position)

func _on_linglan_boss_defeated(enemy: Enemy) -> void:
	if wave_state != CombatFlowState.State.BOSS_ACTIVE:
		return
	if enemy != linglan_boss:
		return
	active_wave_enemy_ids.erase(enemy.get_instance_id())
	current_wave_defeated = 1
	_emit_multiplayer_enemy_defeated(enemy)
	var victory_timer := get_tree().create_timer(1.3)
	victory_timer.timeout.connect(_complete_linglan_boss_after_delay)

func _complete_linglan_boss_after_delay() -> void:
	if wave_state != CombatFlowState.State.BOSS_ACTIVE:
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

func collect_enemy_snapshot_states() -> Array[SnapshotManager.EnemyState]:
	return collect_reused_enemy_snapshot_states(enemy_container, boss_container)

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
