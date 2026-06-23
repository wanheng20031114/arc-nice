extends Node2D
class_name Game

const ENEMY_SPAWN_EFFECT_SCENE := preload("res://scene/enemy/yuanshi_insect_spawn_effect.tscn")
const GUARDIAN_POINT_LIGHT_TEXTURE := preload("res://resources/texture/guardian_point_light.png")
const PLAYER_SCENE := preload("res://scene/player.tscn")
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
const SPAWN_AUDIO_MIN_INTERVAL_SECONDS := 0.08

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
signal multiplayer_defeat_started
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
]

@export_group("波次流程")
@export_range(0.0, 60.0, 1.0, "or_greater") var pre_wave_duration: float = 5.0
@export var auto_start_waves: bool = true
@export var runtime_mode: RuntimeMode = RuntimeMode.SINGLEPLAYER

@onready var player: Player = $Player
@onready var enemy_container: Node2D = $EnemyContainer
@onready var enemy_spawn_points_root: Node2D = $EnemySpawnPoints
@onready var enemy_spawn_timer: Timer = $EnemySpawnTimer
@onready var state_timer: Timer = $StateTimer
@onready var map_camera: Camera2D = $Camera2D
@onready var grid_pathfinder: Node = $GridPathfinder
@onready var music_player: AudioStreamPlayer = $MusicPlayer
@onready var enemy_spawn_audio: AudioStreamPlayer = $EnemySpawnAudio
@onready var countdown_audio: AudioStreamPlayer = $CountdownAudio
@onready var wave_start_audio: AudioStreamPlayer = $WaveStartAudio
@onready var currency_hud: CurrencyHUD = $CurrencyHUD
@onready var wave_hud: WaveHUD = $WaveHUD
@onready var player_profile_panel: PlayerProfilePanel = $PlayerProfilePanel
@onready var settings_panel: SettingsPanel = $SettingsLayer/SettingsPanel
@onready var merchant: ZhuangfangyiMerchant = $ZhuangfangyiMerchant
@onready var luoxi_merchant: LuoxiMerchant = $LuoxiMerchant
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
var multiplayer_local_peer_id: int = 0
var multiplayer_player_names: Dictionary = {}
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
var last_spawn_audio_msec: int = -100000
var luoxi_collectible_claimed_peers: Dictionary = {}


func _ready() -> void:
	random_generator.randomize()
	var user_settings := get_node_or_null("/root/UserSettings")
	if user_settings != null and user_settings.has_method("assign_audio_buses_to_tree"):
		user_settings.call("assign_audio_buses_to_tree")
	if runtime_mode == RuntimeMode.SINGLEPLAYER:
		run_state.ensure_run_started()
	_collect_enemy_spawn_points()
	_configure_timers()
	_prewarm_enemy_visual_resources()
	if runtime_mode != RuntimeMode.CLIENT_VIEW:
		_prewarm_enemy_navigation_grids()
	if runtime_mode != RuntimeMode.SINGLEPLAYER:
		run_state.ensure_run_started()
		run_state.set_active_multiplayer_peer(multiplayer_local_peer_id)
		_configure_multiplayer_players()
		_register_static_multiplayer_pickups()
	currency_hud.bind_player(player)
	player_profile_panel.bind_player(player)
	currency_hud.settings_requested.connect(_on_currency_hud_settings_requested)
	currency_hud.profile_requested.connect(player_profile_panel.open)
	settings_panel.closed.connect(_on_settings_panel_closed)
	wave_hud.set_return_button_text("返回菜单" if runtime_mode == RuntimeMode.SINGLEPLAYER else "返回大厅")
	if not wave_hud.return_to_lobby_requested.is_connected(_on_wave_hud_return_to_lobby_requested):
		wave_hud.return_to_lobby_requested.connect(_on_wave_hud_return_to_lobby_requested)
	if runtime_mode == RuntimeMode.SINGLEPLAYER:
		player.died.connect(_on_player_died)
	_set_merchant_active(false)

	if runtime_mode == RuntimeMode.CLIENT_VIEW:
		auto_start_waves = false
		_start_client_wave_countdown(WaveState.PRE_WAVE, 0, maxi(ceili(pre_wave_duration), 0))
	elif auto_start_waves and _is_wave_system_ready():
		_enter_pre_wave(0)
	else:
		wave_hud.hide_all()


func _physics_process(delta: float) -> void:
	if runtime_mode == RuntimeMode.HOST_AUTHORITY:
		_update_multiplayer_remote_player_passive_state(delta)
		_update_multiplayer_enemy_targets(delta)
		_register_dynamic_multiplayer_pickups()


func configure_multiplayer(
	mode: int,
	local_peer_id: int,
	player_names: Dictionary
) -> void:
	runtime_mode = mode as RuntimeMode
	multiplayer_local_peer_id = local_peer_id
	multiplayer_player_names = player_names.duplicate()


func _on_currency_hud_settings_requested() -> void:
	if player_profile_panel.is_open():
		player_profile_panel.close()
	settings_panel.open()
	_lock_player_for_modal_ui()


func _on_settings_panel_closed() -> void:
	_refresh_player_modal_ui_lock()


func _lock_player_for_modal_ui() -> void:
	if player != null and not player.is_dead:
		player.set_controls_locked(true)


func _refresh_player_modal_ui_lock() -> void:
	if player == null or player.is_dead:
		return
	if settings_panel.is_open() or player_profile_panel.is_open():
		player.set_controls_locked(true)
	else:
		player.set_controls_locked(false)


func apply_remote_merchant_active(active: bool) -> void:
	_set_local_merchants_active(active)
	if runtime_mode != RuntimeMode.CLIENT_VIEW:
		return
	if active:
		var wave_config := _get_current_wave()
		var countdown := 0
		if wave_config != null:
			countdown = maxi(ceili(wave_config.rest_duration_after_wave), 0)
		_start_client_wave_countdown(WaveState.INTERMISSION, current_wave_index, countdown)
	elif wave_state == WaveState.PRE_WAVE or wave_state == WaveState.INTERMISSION:
		state_timer.stop()


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
	impact_direction: Vector2 = Vector2.ZERO
) -> bool:
	if damage_number_pool == null:
		return false
	return damage_number_pool.show_damage_number(amount, spawn_position, impact_direction)


func try_purchase_skill1_for_peer(peer_id: int) -> int:
	var player_instance := get_player_for_peer(peer_id)
	if player_instance == null or not is_instance_valid(player_instance):
		return PURCHASE_RESULT_INVALID_PLAYER
	if player_instance.has_skill1():
		if player_instance.is_skill1_upgrade_maxed():
			return PURCHASE_RESULT_SKILL1_UPGRADE_MAXED
		if not player_instance.try_upgrade_skill1():
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


func request_luoxi_collectible_choice(choice_index: int) -> void:
	if runtime_mode == RuntimeMode.CLIENT_VIEW:
		return
	var peer_id := multiplayer_local_peer_id if runtime_mode != RuntimeMode.SINGLEPLAYER else 0
	var result_code := try_claim_luoxi_collectible_for_peer(peer_id, choice_index)
	show_local_luoxi_collectible_result(result_code)


func try_claim_luoxi_collectible_for_peer(peer_id: int, choice_index: int) -> int:
	var player_instance := player if peer_id <= 0 else get_player_for_peer(peer_id)
	if player_instance == null or not is_instance_valid(player_instance):
		return LuoxiMerchant.COLLECTIBLE_RESULT_INVALID_PLAYER

	var claim_key := maxi(peer_id, 0)
	if luoxi_collectible_claimed_peers.has(claim_key):
		return LuoxiMerchant.COLLECTIBLE_RESULT_ALREADY_CLAIMED

	var item := LuoxiMerchant.get_collectible_for_choice(choice_index)
	if item == null:
		return LuoxiMerchant.COLLECTIBLE_RESULT_INVALID_PLAYER

	var stored := (
		run_state.try_add_item_for_peer(peer_id, item)
		if peer_id > 0
		else run_state.try_add_item(item)
	)
	if not stored:
		return LuoxiMerchant.COLLECTIBLE_RESULT_INVENTORY_FULL

	luoxi_collectible_claimed_peers[claim_key] = true
	return LuoxiMerchant.COLLECTIBLE_RESULT_SUCCESS


func has_luoxi_collectible_claimed(peer_id: int) -> bool:
	return luoxi_collectible_claimed_peers.has(maxi(peer_id, 0))


func mark_luoxi_collectible_claimed(peer_id: int) -> void:
	luoxi_collectible_claimed_peers[maxi(peer_id, 0)] = true


func show_local_luoxi_collectible_result(result_code: int) -> void:
	if luoxi_merchant == null:
		return
	luoxi_merchant.show_collectible_result(result_code)


func _on_wave_hud_return_to_lobby_requested() -> void:
	if runtime_mode == RuntimeMode.SINGLEPLAYER:
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
			luoxi_collectible_claimed_peers.clear()
			luoxi_merchant.reset_round_collectible_claims()
		luoxi_merchant.set_active(active)
		changed = true
	return changed


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

	wave_state = WaveState.PRE_WAVE
	current_wave_index = wave_index
	enemy_spawn_timer.stop()
	if runtime_mode != RuntimeMode.CLIENT_VIEW:
		_prewarm_enemy_navigation_grids()
	_set_merchant_active(false)
	countdown_seconds = maxi(ceili(pre_wave_duration), 0)
	wave_hud.show_countdown(countdown_seconds)

	if countdown_seconds <= 0:
		_begin_wave(current_wave_index)
		return

	if countdown_seconds <= COUNTDOWN_FINAL_SECONDS:
		_play_countdown_tick()
	state_timer.start(1.0)


func _enter_intermission() -> void:
	if runtime_mode == RuntimeMode.HOST_AUTHORITY:
		multiplayer_revive_all_requested.emit()
	wave_state = WaveState.INTERMISSION
	enemy_spawn_timer.stop()
	_set_merchant_active(true)

	var wave_config := _get_current_wave()
	countdown_seconds = (
		maxi(ceili(wave_config.rest_duration_after_wave), 0)
		if wave_config != null
		else 0
	)
	wave_hud.show_countdown(countdown_seconds)

	if countdown_seconds <= 0:
		_begin_wave(current_wave_index + 1)
		return

	if countdown_seconds <= COUNTDOWN_FINAL_SECONDS:
		_play_countdown_tick()
	state_timer.start(1.0)


func _begin_wave(wave_index: int) -> void:
	if wave_index < 0 or wave_index >= waves.size():
		_enter_victory()
		return

	var wave_config := waves[wave_index]
	if wave_config == null:
		push_error("波次 %d 缺少 WaveConfig。" % (wave_index + 1))
		_enter_defeat()
		return

	wave_state = WaveState.WAVE_ACTIVE
	current_wave_index = wave_index
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
		_update_client_wave_countdown()
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
		_begin_wave(current_wave_index)
	else:
		_begin_wave(current_wave_index + 1)


func _on_enemy_spawn_timer_timeout() -> void:
	_spawn_wave_batch()


func _start_client_wave_countdown(state: int, wave_index: int, seconds: int) -> void:
	wave_state = state
	current_wave_index = clampi(wave_index, 0, maxi(waves.size() - 1, 0))
	countdown_seconds = maxi(seconds, 0)
	wave_hud.show_countdown(countdown_seconds)
	if countdown_seconds <= 0:
		state_timer.stop()
		return
	state_timer.start(1.0)


func _update_client_wave_countdown() -> void:
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
	var enemy_net_id := 0
	if runtime_mode == RuntimeMode.HOST_AUTHORITY:
		enemy_net_id = next_multiplayer_enemy_net_id
		next_multiplayer_enemy_net_id += 1
		enemy_instance.set_meta("net_id", enemy_net_id)
		multiplayer_enemy_ids_by_instance[enemy_id] = enemy_net_id
		multiplayer_enemies_by_net_id[enemy_net_id] = enemy_instance
	active_wave_enemy_ids[enemy_id] = true
	enemy_instance.defeated.connect(_on_wave_enemy_defeated)
	enemy_instance.tree_exited.connect(_on_wave_enemy_tree_exited.bind(enemy_id))
	if runtime_mode == RuntimeMode.HOST_AUTHORITY:
		multiplayer_enemy_spawned.emit(enemy_net_id, enemy_config, enemy_instance.global_position)
	_spawn_enemy_spawn_effect(spawn_point.global_position)
	_try_play_enemy_spawn_audio()
	return true


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
	if current_wave_index >= waves.size() - 1:
		_enter_victory()
	else:
		_enter_intermission()


func _enter_victory() -> void:
	if runtime_mode == RuntimeMode.HOST_AUTHORITY:
		multiplayer_revive_all_requested.emit()
	wave_state = WaveState.VICTORY
	enemy_spawn_timer.stop()
	state_timer.stop()
	_set_merchant_active(false)
	wave_hud.show_victory()


func _enter_defeat() -> void:
	if wave_state == WaveState.DEFEAT:
		return
	wave_state = WaveState.DEFEAT
	enemy_spawn_timer.stop()
	state_timer.stop()
	_set_merchant_active(false)
	wave_hud.show_defeat()
	if runtime_mode == RuntimeMode.HOST_AUTHORITY:
		multiplayer_defeat_started.emit()


func _on_player_died() -> void:
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
	peer_players.clear()
	if multiplayer_player_names.is_empty():
		multiplayer_player_names[multiplayer_local_peer_id if multiplayer_local_peer_id > 0 else 1] = "Player"

	var peer_ids: Array[int] = []
	for peer_id_variant in multiplayer_player_names:
		peer_ids.append(int(peer_id_variant))
	peer_ids.sort()

	var base_position := player.global_position
	for index in range(peer_ids.size()):
		var peer_id := peer_ids[index]
		var player_instance: Player = player
		if index > 0:
			player_instance = PLAYER_SCENE.instantiate() as Player
		if player_instance == null:
			continue
		if index > 0:
			add_child(player_instance)
		player_instance.name = "Player_%d" % peer_id
		player_instance.global_position = base_position + _get_multiplayer_spawn_offset(index)
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
			predicts_local_movement
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
	use_skill1: bool
) -> void:
	var player_instance: Player = peer_players.get(peer_id) as Player
	if player_instance == null or not is_instance_valid(player_instance):
		return
	player_instance.apply_network_input(move_input, shoot_input, use_skill1)


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


func get_multiplayer_revive_position() -> Vector2:
	return map_camera.global_position


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
		state.form_mode = player_instance.current_form_mode
		state.shot_pattern = player_instance.current_shot_pattern
		states.append(state)
	return states


func collect_enemy_snapshot_states() -> Array[SnapshotManager.EnemyState]:
	var states: Array[SnapshotManager.EnemyState] = []
	for child in enemy_container.get_children():
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
	return states


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


func _is_spawn_system_ready() -> bool:
	return (
		player != null
		and grid_pathfinder != null
		and grid_pathfinder.get("is_built")
		and not enemy_spawn_points.is_empty()
	)


func _get_current_wave() -> WaveConfig:
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


func _try_play_enemy_spawn_audio() -> void:
	if enemy_spawn_audio == null:
		return
	var now := Time.get_ticks_msec()
	if float(now - last_spawn_audio_msec) * 0.001 < SPAWN_AUDIO_MIN_INTERVAL_SECONDS:
		return
	last_spawn_audio_msec = now
	enemy_spawn_audio.play()


func _play_countdown_tick() -> void:
	countdown_audio.pitch_scale = 1.0
	countdown_audio.play()


func _update_wave_music(wave_config: WaveConfig) -> void:
	if wave_config.music == null:
		return
	if music_player.stream == wave_config.music and music_player.playing:
		return
	music_player.stream = wave_config.music
	music_player.play()
