extends WaveCombatRuntimeBase
class_name StandardGame

const MODAL_CONTROL_LOCK_OWNER := &"standard_modal_ui"

const TANGO_LASER_BULLET_POOL_SCENE := (
	StandardPrewarmerCoordinator.TANGO_LASER_BULLET_POOL_SCENE
)
const INITIAL_PLAYER_XIRANG := StandardPlayerRosterCoordinator.INITIAL_PLAYER_XIRANG

const LINGLAN_SKILL1_BULLET_POOL_SCENE := (
	StandardPrewarmerCoordinator.LINGLAN_SKILL1_BULLET_POOL_SCENE
)
const LINGLAN_SAKURA_HIT_EFFECT_POOL_SCENE := (
	StandardPrewarmerCoordinator.LINGLAN_SAKURA_HIT_EFFECT_POOL_SCENE
)
const LINGLAN_ENRAGE_SNIPER_CONFIG_PATH := (
	StandardPrewarmerCoordinator.LINGLAN_ENRAGE_SNIPER_CONFIG_PATH
)
const DEFAULT_MUSIC_VOLUME_DB := StandardMusicCoordinator.DEFAULT_MUSIC_VOLUME_DB
const MUSIC_FADE_IN_SECONDS := StandardMusicCoordinator.MUSIC_FADE_IN_SECONDS
const MUSIC_FADE_IN_START_VOLUME_DB := (
	StandardMusicCoordinator.MUSIC_FADE_IN_START_VOLUME_DB
)

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
@onready var boss_container: Node2D = $BossContainer
@onready var linglan_boss_runtime_port: LinglanBossRuntimePort = (
	$LinglanBossRuntimePort
)
var campaign_wave_coordinator: StandardCampaignWaveCoordinator:
	get:
		return get_node("CampaignWaveCoordinator") as StandardCampaignWaveCoordinator
var boss_coordinator: StandardBossCoordinator:
	get:
		return get_node("BossCoordinator") as StandardBossCoordinator
var player_roster_coordinator: StandardPlayerRosterCoordinator:
	get:
		return get_node("PlayerRosterCoordinator") as StandardPlayerRosterCoordinator
var merchant_coordinator: StandardMerchantCoordinator:
	get:
		return get_node_or_null("MerchantCoordinator") as StandardMerchantCoordinator
var music_coordinator: StandardMusicCoordinator:
	get:
		return get_node_or_null("MusicCoordinator") as StandardMusicCoordinator
var prewarmer_coordinator: StandardPrewarmerCoordinator:
	get:
		return get_node_or_null("PrewarmerCoordinator") as StandardPrewarmerCoordinator
var standard_multiplayer_mode_adapter: StandardMultiplayerModeAdapter:
	get:
		return get_multiplayer_mode_adapter() as StandardMultiplayerModeAdapter
var merchant: ZhuangfangyiMerchant:
	get:
		var coordinator := merchant_coordinator
		return coordinator.get_merchant() if coordinator != null else null
var luoxi_merchant: LuoxiMerchant:
	get:
		var coordinator := merchant_coordinator
		return coordinator.get_luoxi_merchant() if coordinator != null else null
var pickup_registry: StandardPickupRegistry:
	get:
		return get_node_or_null("PickupRegistry") as StandardPickupRegistry
var multiplayer_player_names: Dictionary:
	get:
		return player_roster_coordinator.player_names
	set(value):
		player_roster_coordinator.player_names = value
var multiplayer_player_character_ids: Dictionary:
	get:
		return player_roster_coordinator.player_character_ids
	set(value):
		player_roster_coordinator.player_character_ids = value
var multiplayer_defeat_check_pending: bool:
	get:
		return player_roster_coordinator.defeat_check_pending
	set(value):
		player_roster_coordinator.defeat_check_pending = value

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
var _pending_music_fade_tween: Tween = null
var music_fade_tween: Tween:
	get:
		var coordinator := music_coordinator
		return (
			coordinator.music_fade_tween
			if coordinator != null and coordinator.is_bound()
			else _pending_music_fade_tween
		)
	set(value):
		_pending_music_fade_tween = value
		var coordinator := music_coordinator
		if coordinator != null and coordinator.is_bound():
			coordinator.replace_music_fade_tween(value)
var _pending_luoxi_collectible_claim_counts: Dictionary = {}
var luoxi_collectible_claim_counts: Dictionary:
	get:
		var coordinator := merchant_coordinator
		return (
			coordinator.luoxi_collectible_claim_counts
			if coordinator != null and coordinator.is_bound()
			else _pending_luoxi_collectible_claim_counts
		)
	set(value):
		_pending_luoxi_collectible_claim_counts = value
		var coordinator := merchant_coordinator
		if coordinator != null and coordinator.is_bound():
			coordinator.replace_luoxi_collectible_claim_counts(value)
var linglan_boss_started: bool:
	get:
		return boss_coordinator.linglan_boss_started
	set(value):
		boss_coordinator.linglan_boss_started = value
var active_boss_config: Resource:
	get:
		return boss_coordinator.active_boss_config
	set(value):
		boss_coordinator.active_boss_config = value as BossConfig
var linglan_boss: LinglanBoss:
	get:
		return boss_coordinator.linglan_boss
	set(value):
		boss_coordinator.linglan_boss = value
var linglan_boss_intro_vfx: LinglanBossIntroVFX:
	get:
		return boss_coordinator.linglan_boss_intro_vfx
	set(value):
		boss_coordinator.linglan_boss_intro_vfx = value
var boss_health_hud: BossHealthHUD:
	get:
		return boss_coordinator.boss_health_hud
	set(value):
		boss_coordinator.boss_health_hud = value


func _ready() -> void:
	super._ready()


func configure_multiplayer(
	mode: int,
	local_peer_id: int,
	player_names: Dictionary,
	player_character_ids: Dictionary = {}
) -> void:
	var adapter := standard_multiplayer_mode_adapter
	if adapter == null:
		push_error("StandardGame: 缺少静态 MultiplayerModeAdapter 节点。")
		return
	adapter.configure_standard_multiplayer(
		self,
		merchant_coordinator,
		player_roster_coordinator,
		mode,
		local_peer_id,
		player_names,
		player_character_ids
	)


func _configure_singleplayer_player() -> void:
	player_roster_coordinator.configure_singleplayer_player()


func _configure_multiplayer_players() -> void:
	player_roster_coordinator.configure_multiplayer_players()


func _connect_mode_singleplayer_player_death_signal() -> void:
	player_roster_coordinator.connect_singleplayer_death_signal()


func apply_network_input_for_peer(
	peer_id: int,
	move_input: Vector2,
	shoot_input: Vector2,
	use_skill1: bool,
	use_reload: bool = false
) -> void:
	player_roster_coordinator.apply_network_input_for_peer(
		peer_id,
		move_input,
		shoot_input,
		use_skill1,
		use_reload
	)


func _update_multiplayer_remote_player_passive_state(delta: float) -> void:
	player_roster_coordinator.update_remote_player_passive_state(delta)


func remove_multiplayer_player(peer_id: int) -> void:
	player_roster_coordinator.remove_multiplayer_player(peer_id)


func ensure_reconnected_multiplayer_player(
	old_peer_id: int,
	new_peer_id: int,
	player_name: String,
	character_id: StringName,
	state: SnapshotManager.PlayerState,
	spawn_slot_index: int,
	_reconnect_state: Dictionary = {}
) -> CombatRuntimeBase.ReconnectedPlayerProjection:
	return player_roster_coordinator.ensure_reconnected_multiplayer_player(
		old_peer_id,
		new_peer_id,
		player_name,
		character_id,
		state,
		spawn_slot_index
	)


func get_player_for_peer(peer_id: int) -> Player:
	return player_roster_coordinator.get_player_for_peer(peer_id)


func get_pickup_for_net_id(net_id: int) -> Pickup:
	return get_network_pickup(net_id)


func collect_player_snapshot_states() -> Array[SnapshotManager.PlayerState]:
	return player_roster_coordinator.collect_player_snapshot_states()


func _get_multiplayer_character_id(peer_id: int) -> StringName:
	return player_roster_coordinator.get_multiplayer_character_id(peer_id)


func _get_multiplayer_spawn_offset(index: int) -> Vector2:
	return player_roster_coordinator.get_spawn_offset(index)


func _on_player_died() -> void:
	if wave_state in [
		CombatFlowState.State.VICTORY,
		CombatFlowState.State.DEFEAT,
	]:
		return
	_enter_defeat()


func _get_default_mode_definition() -> GameModeDefinition:
	return GameModeCatalog.get_definition(GameModeCatalog.MODE_STANDARD)


func _initialize_mode_runtime_before_validation() -> void:
	var standard_adapter := standard_multiplayer_mode_adapter
	var standard_music := music_coordinator
	if standard_music != null:
		standard_music.bind_dependencies(music_player, self)
		standard_music.replace_music_fade_tween(
			_pending_music_fade_tween
		)
	var standard_prewarmer := prewarmer_coordinator
	if standard_prewarmer != null:
		standard_prewarmer.bind_dependencies(
			session_object_pool,
			boss_coordinator,
			linglan_boss_enabled
		)
	pickup_registry.bind_standard_dependencies(
		runtime_mode,
		self,
		get_multiplayer_gameplay_gateway(),
		enemy_container,
		boss_container
	)
	player_roster_coordinator.bind_dependencies(
		self,
		$PlayerSpawn as Marker2D,
		run_state
	)
	var resolved_merchant: ZhuangfangyiMerchant = null
	var resolved_luoxi_merchant: LuoxiMerchant = null
	if standard_merchants_enabled:
		resolved_merchant = get_node_or_null(
			"ZhuangfangyiMerchant"
		) as ZhuangfangyiMerchant
		resolved_luoxi_merchant = get_node_or_null(
			"LuoxiMerchant"
		) as LuoxiMerchant
	merchant_coordinator.bind_dependencies(
		resolved_merchant,
		resolved_luoxi_merchant,
		player_roster_coordinator,
		standard_adapter,
		run_state,
		runtime_mode,
		multiplayer_local_peer_id,
		standard_merchants_enabled,
		_pending_luoxi_collectible_claim_counts
	)
	_connect_singleplayer_death_signal()
	if standard_prewarmer != null:
		boss_coordinator.bind_dependencies(
			self,
			boss_container,
			linglan_boss_runtime_port,
			ground_tile_map_layer,
			overlay_tile_map_layer,
			campaign_wave_coordinator,
			standard_prewarmer.load_threaded_or_direct,
			standard_prewarmer.get_linglan_enrage_sniper_config
		)
	(linglan_boss_runtime_port as StandardLinglanBossRuntimePort).bind_standard_dependencies(
		boss_coordinator,
		pause_all_background_music
	)
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
		boss_coordinator.start_step
	):
		campaign_wave_coordinator.boss_step_requested.connect(
			boss_coordinator.start_step
		)
	if not campaign_wave_coordinator.remote_boss_state_requested.is_connected(
		boss_coordinator.apply_remote_state
	):
		campaign_wave_coordinator.remote_boss_state_requested.connect(
			boss_coordinator.apply_remote_state
		)
	if standard_adapter != null:
		standard_adapter.bind_standard_dependencies(
			self,
			player_roster_coordinator,
			boss_coordinator,
			merchant_coordinator,
			player_profile_panel,
			debug_collectible_window,
			wave_hud
		)
	_connect_boss_coordinator_signals()


func _connect_singleplayer_death_signal() -> void:
	if not player_roster_coordinator.singleplayer_died.is_connected(
		_on_player_died
	):
		player_roster_coordinator.singleplayer_died.connect(_on_player_died)


func _connect_boss_coordinator_signals() -> void:
	if not boss_coordinator.music_requested.is_connected(_update_boss_music):
		boss_coordinator.music_requested.connect(_update_boss_music)
	if not boss_coordinator.boss_proxy_created.is_connected(
		_on_boss_proxy_created
	):
		boss_coordinator.boss_proxy_created.connect(_on_boss_proxy_created)
	if not boss_coordinator.boss_enemy_removed.is_connected(
		_on_boss_enemy_removed
	):
		boss_coordinator.boss_enemy_removed.connect(_on_boss_enemy_removed)
	if not boss_coordinator.boss_defeated.is_connected(_on_boss_defeated):
		boss_coordinator.boss_defeated.connect(_on_boss_defeated)
	if not boss_coordinator.step_completed.is_connected(_on_boss_step_completed):
		boss_coordinator.step_completed.connect(_on_boss_step_completed)
	if not boss_coordinator.victory_requested.is_connected(_enter_victory):
		boss_coordinator.victory_requested.connect(_enter_victory)


func _validate_mode_scene_content() -> bool:
	if prewarmer_coordinator == null:
		push_error("StandardGame: 缺少静态 PrewarmerCoordinator 节点。")
		return false
	if not prewarmer_coordinator.is_bound():
		push_error("StandardGame: PrewarmerCoordinator 依赖未完整绑定。")
		return false
	if music_coordinator == null:
		push_error("StandardGame: 缺少静态 MusicCoordinator 节点。")
		return false
	if not music_coordinator.is_bound():
		push_error("StandardGame: MusicCoordinator 依赖未完整绑定。")
		return false
	if pickup_registry == null:
		push_error("StandardGame: 缺少静态 PickupRegistry 节点。")
		return false
	if not pickup_registry.is_bound():
		push_error("StandardGame: PickupRegistry 依赖未完整绑定。")
		return false
	if player_roster_coordinator == null:
		push_error("StandardGame: 缺少静态 PlayerRosterCoordinator 节点。")
		return false
	if not player_roster_coordinator.is_bound():
		push_error("StandardGame: PlayerRosterCoordinator 依赖未完整绑定。")
		return false
	if standard_multiplayer_mode_adapter == null:
		push_error("StandardGame: 缺少静态 MultiplayerModeAdapter 节点。")
		return false
	if not standard_multiplayer_mode_adapter.is_standard_bound():
		push_error("StandardGame: MultiplayerModeAdapter 依赖未完整绑定。")
		return false
	if merchant_coordinator == null:
		push_error("StandardGame: 缺少静态 MerchantCoordinator 节点。")
		return false
	if not merchant_coordinator.is_bound():
		push_error("StandardGame: MerchantCoordinator 依赖未完整绑定。")
		return false
	if campaign_wave_coordinator == null:
		push_error("StandardGame: 缺少静态 CampaignWaveCoordinator 节点。")
		return false
	if boss_coordinator == null:
		push_error("StandardGame: 缺少静态 BossCoordinator 节点。")
		return false
	if not boss_coordinator.is_bound():
		push_error("StandardGame: BossCoordinator 依赖未完整绑定。")
		return false
	if linglan_boss_enabled and linglan_boss_runtime_port == null:
		push_error("StandardGame: 场景启用了铃兰 Boss，但缺少静态运行时端口。")
		return false
	return true


func _configure_active_campaign() -> bool:
	if not super._configure_active_campaign():
		return false
	if not campaign_wave_coordinator.initialize_campaign(active_campaign):
		return false
	boss_coordinator.configure(
		linglan_boss_enabled,
		campaign_wave_coordinator
	)
	return true


func _register_mode_object_pools() -> void:
	prewarmer_coordinator.register_mode_object_pools()


func _connect_mode_dynamic_pickup_containers() -> void:
	pickup_registry.set_runtime_mode(runtime_mode)
	pickup_registry.connect_dynamic_containers()


func _register_static_multiplayer_pickups() -> void:
	pickup_registry.set_runtime_mode(runtime_mode)
	pickup_registry.register_static_pickups(self)


func _on_multiplayer_pickup_consumed(
	pickup: Pickup,
	collector_peer_id: int,
	applied_immediately: bool
) -> void:
	pickup_registry.handle_multiplayer_pickup_consumed(
		pickup,
		collector_peer_id,
		applied_immediately
	)


func _on_multiplayer_pickup_tree_exited(net_id: int) -> void:
	pickup_registry.set_runtime_mode(runtime_mode)
	pickup_registry.handle_multiplayer_pickup_tree_exited(net_id)


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
		standard_multiplayer_mode_adapter.handle_debug_collectible_requested
	)
	debug_collectible_window.closed.connect(_on_debug_collectible_window_closed)
	wave_hud.set_return_button_text(
		"返回菜单" if runtime_mode == RuntimeMode.SINGLEPLAYER else "返回大厅"
	)
	if not wave_hud.return_to_lobby_requested.is_connected(
		standard_multiplayer_mode_adapter.handle_return_to_lobby_requested
	):
		wave_hud.return_to_lobby_requested.connect(
			standard_multiplayer_mode_adapter.handle_return_to_lobby_requested
		)


func _initialize_mode_runtime_content() -> void:
	_set_merchant_active(false)
	boss_coordinator.configure_existing_runtime_nodes()
	prewarmer_coordinator.configure_boss_flow_enabled(_uses_linglan_boss_flow())
	prewarmer_coordinator.schedule_boss_runtime_scene_loads()


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
		current_wave_resolved,
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
	boss_coordinator.end_encounter()
	boss_coordinator.stop_presentation()
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


func _on_boss_proxy_created(boss: LinglanBoss, net_id: int) -> void:
	if boss == null or net_id <= 0:
		return
	register_network_enemy(net_id, boss)


func _on_boss_enemy_removed(enemy_id: int) -> void:
	var result := wave_enemy_terminal_ledger.detach_enemy(enemy_id)
	if not result.accepted:
		if not result.known:
			push_error(
				"StandardGame: 未登记 Boss 实体 %d 退出，执行隔离的网络清理。"
				% enemy_id
			)
			_cleanup_untracked_multiplayer_enemy_exit(enemy_id)
		return
	if (
		result.terminal_created
		and result.role == WaveEnemyTerminalLedger.EnemyRole.OBJECTIVE
	):
		push_error(
			"StandardGame: Boss 遭遇实体 %d 未经终结便退出，按 REMOVED 结算。"
			% enemy_id
		)
	_mark_multiplayer_enemy_detached(enemy_id, result)


func _on_boss_defeated(enemy: Enemy) -> void:
	if (
		enemy == null
		or not try_resolve_active_wave_enemy_defeat(enemy.get_instance_id())
	):
		return
	_emit_multiplayer_enemy_defeated(enemy)


func _on_boss_step_completed() -> void:
	if wave_state == CombatFlowState.State.BOSS_ACTIVE:
		_complete_current_step()


func _prewarm_mode_runtime_data() -> void:
	prewarmer_coordinator.configure_boss_flow_enabled(_uses_linglan_boss_flow())
	await prewarmer_coordinator.prewarm_boss_runtime_resources()


func _on_multiplayer_peer_restored(old_peer_id: int, new_peer_id: int) -> void:
	merchant_coordinator.restore_peer_state(old_peer_id, new_peer_id)


func allows_debug_collectible_grants() -> bool:
	return merchant_coordinator.allows_debug_collectible_grants()

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
	player_roster_coordinator.apply_initial_xirang()

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
	if player != null and is_instance_valid(player):
		player.set_control_lock(MODAL_CONTROL_LOCK_OWNER, true)

func _refresh_player_modal_ui_lock() -> void:
	if player == null or not is_instance_valid(player):
		return
	player.set_control_lock(
		MODAL_CONTROL_LOCK_OWNER,
		settings_panel.is_open()
		or debug_collectible_window.is_open()
	)

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

func grant_debug_collectible(config_path: String) -> bool:
	return merchant_coordinator.grant_debug_collectible(config_path)

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

func try_purchase_skill1_for_peer(peer_id: int) -> int:
	return merchant_coordinator.try_purchase_skill1_for_peer(peer_id)

func apply_skill1_purchase_state(
	peer_id: int,
	current_xirang: int,
	skill1_unlocked: bool,
	skill1_upgrade_level: int = -1,
	skill1_charge_duration: float = -1.0
) -> void:
	merchant_coordinator.apply_skill1_purchase_state(
		peer_id,
		current_xirang,
		skill1_unlocked,
		skill1_upgrade_level,
		skill1_charge_duration
	)

func show_local_skill1_purchase_result(result_code: int) -> void:
	merchant_coordinator.show_local_skill1_purchase_result(result_code)

func request_luoxi_collectible_choice(choice_index: int, config_path: String = "") -> void:
	merchant_coordinator.request_luoxi_collectible_choice(
		choice_index,
		config_path
	)

func request_luoxi_collectible_refresh() -> void:
	merchant_coordinator.request_luoxi_collectible_refresh()

func try_refresh_luoxi_collectibles_for_peer(peer_id: int) -> int:
	return merchant_coordinator.try_refresh_luoxi_collectibles_for_peer(peer_id)

func get_luoxi_collectible_refresh_count(peer_id: int) -> int:
	return merchant_coordinator.get_luoxi_collectible_refresh_count(peer_id)

func try_claim_luoxi_collectible_for_peer(peer_id: int, config_path_or_choice: Variant) -> int:
	return merchant_coordinator.try_claim_luoxi_collectible_for_peer(
		peer_id,
		config_path_or_choice
	)

func has_luoxi_collectible_claimed(peer_id: int) -> bool:
	return merchant_coordinator.has_luoxi_collectible_claimed(peer_id)

func get_luoxi_collectible_claim_count(peer_id: int) -> int:
	return merchant_coordinator.get_luoxi_collectible_claim_count(peer_id)

func record_luoxi_collectible_claim(peer_id: int) -> void:
	merchant_coordinator.record_luoxi_collectible_claim(peer_id)

func mark_luoxi_collectible_claimed(peer_id: int) -> void:
	merchant_coordinator.mark_luoxi_collectible_claimed(peer_id)

func show_local_luoxi_collectible_result(result_code: int) -> void:
	merchant_coordinator.show_local_luoxi_collectible_result(result_code)

func show_local_luoxi_refresh_result(
	result_code: int,
	refresh_count: int,
	current_xirang: int
) -> void:
	merchant_coordinator.show_local_luoxi_refresh_result(
		result_code,
		refresh_count,
		current_xirang
	)

func _set_merchant_active(active: bool) -> void:
	merchant_coordinator.set_active(active)

func _set_local_merchants_active(active: bool) -> bool:
	return merchant_coordinator.set_local_merchants_active(active)

func spawn_linglan_skill2_enemies(
	enemy_config: EnemyConfig,
	marker_names: Array[StringName]
) -> void:
	boss_coordinator.spawn_skill2_enemies(enemy_config, marker_names)

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

func _begin_linglan_boss_intro(boss_config: BossConfig = null) -> void:
	if boss_config == null:
		boss_config = current_flow_step as BossConfig
	if not boss_coordinator.start_step(boss_config):
		_enter_victory()

func _on_linglan_boss_intro_finished() -> void:
	boss_coordinator.finish_intro()

func _activate_linglan_boss() -> void:
	boss_coordinator.activate_boss()

func _on_boss_enemy_tree_exited(enemy_id: int) -> void:
	_on_boss_enemy_removed(enemy_id)

func _prepare_linglan_boss_arena(boss_config: Resource) -> void:
	boss_coordinator.prepare_arena(boss_config as BossConfig)

func collect_enemy_snapshot_states() -> Array[SnapshotManager.EnemyState]:
	return collect_reused_enemy_snapshot_states(enemy_container, boss_container)

func get_linglan_skill2_target_global_position(target_cell: Vector2i) -> Vector2:
	return boss_coordinator.get_skill_target_global_position(target_cell)

func get_linglan_skill3_target_global_position(target_cell: Vector2i) -> Vector2:
	return boss_coordinator.get_skill_target_global_position(target_cell)

func get_linglan_skill4_target_global_position(
	target_cell_a: Vector2i,
	target_cell_b: Vector2i
) -> Vector2:
	return boss_coordinator.get_skill4_target_global_position(
		target_cell_a,
		target_cell_b
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

func _get_tile_cell_global_position(cell: Vector2i) -> Vector2:
	return ground_tile_map_layer.to_global(ground_tile_map_layer.map_to_local(cell))

func get_linglan_skill2_target_player(from_position: Vector2) -> Player:
	return boss_coordinator.get_skill2_target_player(from_position)

func _play_remote_boss_intro(boss_config: BossConfig) -> void:
	boss_coordinator.play_remote_intro(boss_config)

func _update_wave_music(wave_config: WaveConfig) -> void:
	music_coordinator.update_wave_music(wave_config)

func _update_post_wave_music(flow_step: FlowStepConfig) -> void:
	music_coordinator.update_post_wave_music(flow_step)

func _update_boss_music(boss_config: BossConfig) -> void:
	music_coordinator.update_boss_music(boss_config)

func pause_all_background_music() -> void:
	music_coordinator.pause_all_background_music()

func _play_music_stream(
	stream: AudioStream,
	volume_db: float,
	loop_offset: float = 0.0,
	fade_in: bool = false
) -> void:
	music_coordinator.play_music_stream(
		stream,
		volume_db,
		loop_offset,
		fade_in
	)

func _stop_music_fade_tween() -> void:
	music_coordinator.stop_music_fade_tween()

func _configure_music_loop(stream: AudioStream, loop_offset: float) -> void:
	music_coordinator.configure_music_loop(stream, loop_offset)

func _audio_stream_has_property(stream: AudioStream, property_name: StringName) -> bool:
	return music_coordinator.audio_stream_has_property(stream, property_name)

func _pause_background_music_players(root_node: Node) -> void:
	music_coordinator.pause_background_music_players(root_node)

func _is_background_music_player(node: Node) -> bool:
	return music_coordinator.is_background_music_player(node)

func request_tango_charge_started(direction: Vector2) -> bool:
	return player_roster_coordinator.request_tango_charge_started(direction)

func request_tango_charge_released(direction: Vector2) -> bool:
	return player_roster_coordinator.request_tango_charge_released(direction)

func request_tango_charge_cancelled() -> bool:
	return player_roster_coordinator.request_tango_charge_cancelled()
