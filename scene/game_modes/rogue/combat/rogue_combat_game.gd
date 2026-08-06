extends WaveCombatRuntimeBase
class_name RogueCombatGame

const TANGO_LASER_BULLET_POOL_SCENE := preload(
	"res://scene/player/tango/tango_laser_bullet.tscn"
)
const TANGO_MINIMUM_CHARGE_SECONDS := 0.2
const TANGO_MAXIMUM_CHARGE_SECONDS := 2.4
const TANGO_CHARGE_THRESHOLD_EPSILON := 0.0001

signal combat_outcome_started(victory: bool, failure_reason: String)

enum DeadlineStart {
	PREPARATION_START,
	WAVE_START,
}

const DEFAULT_EVENT_TITLE := "狭路相逢"
const DEFAULT_FAILURE_REASON := "队伍已全数阵亡"
const TIMEOUT_FAILURE_REASON := "作战时间已耗尽"
const UNDERGROUND_NIGHT_COLOR := DayNightController.REFERENCE_NIGHT_COLOR
const DEFAULT_MUSIC_VOLUME_DB := -6.0
const MUSIC_FADE_IN_SECONDS := 3.0
const MUSIC_FADE_IN_START_VOLUME_DB := -12.0
const INITIAL_PLAYER_XIRANG := 1000

@export_group("Rouge 作战")
@export var event_title := DEFAULT_EVENT_TITLE
@export_range(1.0, 3600.0, 1.0, "or_greater")
var combat_time_limit_seconds := 90.0
@export var deadline_start := DeadlineStart.WAVE_START
@export var enemy_pickup_drops_enabled := false

@onready var rogue_combat_hud: RogueCombatHUD = $RogueCombatHUD
@onready var player_life_status_hud: PlayerLifeStatusHUD = (
	$PlayerLifeStatusLayer/PlayerLifeStatusHUD
)
@onready var combat_deadline_timer: Timer = $CombatDeadlineTimer
@onready var music_player: AudioStreamPlayer = $MusicPlayer
@onready var countdown_audio: AudioStreamPlayer = $CountdownAudio
@onready var wave_start_audio: AudioStreamPlayer = $WaveStartAudio
@onready var currency_hud: CurrencyHUD = $CurrencyHUD
@onready var player_profile_panel: RoguePlayerProfilePanel = $PlayerProfilePanel
@onready var settings_panel: SettingsPanel = $SettingsLayer/SettingsPanel

var _singleplayer_tango_charge_started_at: float = -1.0
var combat_seconds_remaining := 0
var _combat_deadline_started := false
var _outcome_emitted := false
var _failure_reason := DEFAULT_FAILURE_REASON
var _spawn_point_rotation_index := 0
var music_fade_tween: Tween = null


func validate_encounter_scene_contract(
	expected_spawn_point_mask: int
) -> PackedStringArray:
	var errors := PackedStringArray()
	if world_lighting_policy != WorldLightingPolicy.FIXED_NIGHT:
		errors.append("地下 Rouge 作战场景必须使用常驻黑夜光照策略。")
	var lighting_controller := get_node_or_null(
		"DayNightController"
	) as DayNightController
	if lighting_controller == null:
		errors.append("地下 Rouge 作战场景缺少昼夜光照控制器。")
	elif lighting_controller.night_color != UNDERGROUND_NIGHT_COLOR:
		errors.append("地下 Rouge 作战场景必须使用塔防标准黑夜环境色。")
	if get_node_or_null("NightVfxFlashPool") as NightVfxFlashPool == null:
		errors.append("地下 Rouge 作战场景缺少塔防同款夜间闪光池。")
	if (
		expected_spawn_point_mask <= 0
		or expected_spawn_point_mask & ~WaveConfig.ALL_SPAWN_POINT_MASK
	):
		errors.append("Rouge 作战配置提供了无效的出生点掩码。")

	var spawn_root := get_node_or_null("EnemySpawnPoints") as Node2D
	if spawn_root == null:
		errors.append("Rouge 作战场景缺少 EnemySpawnPoints。")
	else:
		var authored_spawn_point_mask := 0
		for child in spawn_root.get_children():
			var marker := child as Marker2D
			if marker == null:
				errors.append(
					"EnemySpawnPoints 只能直接包含 Marker2D，发现：%s。"
					% child.name
				)
				continue
			var spawn_index := WaveConfig.SPAWN_POINT_NAMES.find(marker.name)
			if spawn_index < 0:
				errors.append("存在未注册的 Rouge 出生点：%s。" % marker.name)
				continue
			var spawn_bit := 1 << spawn_index
			if authored_spawn_point_mask & spawn_bit:
				errors.append("Rouge 出生点名称重复：%s。" % marker.name)
				continue
			authored_spawn_point_mask |= spawn_bit
			var night_light := marker.get_node_or_null(
				"NightLight"
			) as NightPointLight2D
			if night_light == null:
				errors.append("Rouge 出生点 %s 缺少夜间门灯。" % marker.name)
			elif not is_equal_approx(night_light.night_energy, 0.3):
				errors.append("Rouge 出生点 %s 的夜间门灯能量必须为0.3。" % marker.name)
		if authored_spawn_point_mask != expected_spawn_point_mask:
			errors.append(
				"Rouge 场景出生点掩码 %d 与遭遇配置 %d 不一致。"
				% [authored_spawn_point_mask, expected_spawn_point_mask]
			)

	if get_node_or_null("PlayerSpawn") as Marker2D == null:
		errors.append("Rouge 作战场景缺少队伍出生锚点 PlayerSpawn。")
	_append_forbidden_static_content_errors(self, errors)
	return errors


func _append_forbidden_static_content_errors(
	parent: Node,
	errors: PackedStringArray
) -> void:
	for child in parent.get_children():
		if child is ZhuangfangyiMerchant:
			errors.append("Rouge 专用作战场景不得包含庄方宜商人节点。")
		elif child is LuoxiMerchant:
			errors.append("Rouge 专用作战场景不得包含洛茜商人节点。")
		elif child is Pickup:
			errors.append(
				"Rouge 专用作战场景不得预置静态拾取物：%s。" % child.name
			)
		_append_forbidden_static_content_errors(child, errors)


func _ready() -> void:
	super._ready()
	player_life_status_hud.set_dead_player_list_enabled(false)


func _register_mode_object_pools() -> void:
	session_object_pool.register_scene(TANGO_LASER_BULLET_POOL_SCENE, 64, 768)


func _initialize_mode_player_ui() -> void:
	currency_hud.bind_player(player)
	player_profile_panel.configure_multiplayer_requests(false)
	player_profile_panel.configure_local_upgrade_authority(
		runtime_mode != RuntimeMode.CLIENT_VIEW
	)
	player_profile_panel.bind_player(player)
	currency_hud.settings_requested.connect(_on_currency_hud_settings_requested)
	currency_hud.profile_requested.connect(player_profile_panel.open)
	settings_panel.closed.connect(_on_settings_panel_closed)


func _apply_initial_player_resources() -> void:
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


func _present_wave_started(wave_config: WaveConfig, _is_remote: bool) -> void:
	_update_wave_music(wave_config)
	wave_start_audio.play()


func _present_terminal_state(_victory: bool) -> void:
	rogue_combat_hud.hide_hud()


func _hide_mode_wave_presentation() -> void:
	rogue_combat_hud.hide_hud()


func _present_countdown_tick() -> void:
	countdown_audio.pitch_scale = 1.0
	countdown_audio.play()


func _present_intermission_started(cleared_step: FlowStepConfig) -> void:
	_update_post_wave_music(cleared_step)


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
	player.set_controls_locked(
		settings_panel.is_open() or player_profile_panel.is_open()
	)


func _unhandled_input(event: InputEvent) -> void:
	if not event.is_action_pressed("full_screen"):
		return
	var user_settings := get_node_or_null("/root/UserSettings")
	if user_settings != null:
		var next_fullscreen := not bool(
			user_settings.call("is_fullscreen_enabled")
		)
		user_settings.call("set_fullscreen_enabled", next_fullscreen)
		settings_panel.refresh_from_settings()
	get_viewport().set_input_as_handled()


func allows_player_respawn(_peer_id: int) -> bool:
	return false


func allows_enemy_pickup_drops() -> bool:
	return enemy_pickup_drops_enabled


func _resolve_wave_spawn_points(wave_config: WaveConfig) -> bool:
	var resolved := super._resolve_wave_spawn_points(wave_config)
	if not resolved:
		_spawn_point_rotation_index = 0
		return false
	_spawn_point_rotation_index = random_generator.randi_range(
		0,
		active_wave_spawn_points.size() - 1
	)
	return true


func _pick_spawn_point() -> Marker2D:
	if active_wave_spawn_points.is_empty():
		return null
	var marker := active_wave_spawn_points[
		_spawn_point_rotation_index % active_wave_spawn_points.size()
	]
	_spawn_point_rotation_index += 1
	return marker


func _enter_pre_flow_step(flow_step: FlowStepConfig) -> void:
	_reset_combat_outcome()
	_reset_combat_deadline()
	super._enter_pre_flow_step(flow_step)
	if wave_state != CombatFlowState.State.PRE_WAVE:
		return
	rogue_combat_hud.show_preparation(
		event_title,
		float(countdown_seconds),
		_get_expected_enemy_count(flow_step)
	)
	if deadline_start == DeadlineStart.PREPARATION_START:
		_start_combat_deadline()


func _begin_wave_config(wave_config: WaveConfig) -> void:
	if deadline_start == DeadlineStart.WAVE_START:
		_reset_combat_deadline()
	super._begin_wave_config(wave_config)
	if wave_state != CombatFlowState.State.WAVE_ACTIVE:
		return
	var total_enemies := maxi(current_wave_total, 0)
	rogue_combat_hud.show_combat(
		event_title,
		float(combat_seconds_remaining),
		current_wave_defeated,
		total_enemies
	)
	if deadline_start == DeadlineStart.WAVE_START:
		_start_combat_deadline()


func _on_state_timer_timeout() -> void:
	super._on_state_timer_timeout()
	if wave_state == CombatFlowState.State.PRE_WAVE:
		rogue_combat_hud.set_preparation_time(float(countdown_seconds))


func _on_combat_deadline_timer_timeout() -> void:
	if not _combat_deadline_started:
		combat_deadline_timer.stop()
		return
	if wave_state not in [CombatFlowState.State.PRE_WAVE, CombatFlowState.State.WAVE_ACTIVE]:
		_stop_combat_deadline()
		return
	combat_seconds_remaining = maxi(combat_seconds_remaining - 1, 0)
	if wave_state == CombatFlowState.State.WAVE_ACTIVE:
		rogue_combat_hud.set_combat_remaining_time(
			float(combat_seconds_remaining)
		)
		_emit_multiplayer_flow_state(CombatFlowState.State.WAVE_ACTIVE)
	if combat_seconds_remaining > 0:
		return
	_failure_reason = TIMEOUT_FAILURE_REASON
	_enter_defeat()


func _on_wave_enemy_defeated(enemy: Enemy) -> void:
	super._on_wave_enemy_defeated(enemy)
	rogue_combat_hud.set_defeated_enemy_count(
		maxi(current_wave_defeated, 0),
		maxi(current_wave_total, 0)
	)


func apply_remote_enemy_count(alive_count: int) -> void:
	super.apply_remote_enemy_count(alive_count)
	if runtime_mode != RuntimeMode.CLIENT_VIEW or wave_state != CombatFlowState.State.WAVE_ACTIVE:
		return
	var total_enemies := maxi(current_wave_total, maxi(alive_count, 0))
	var safe_alive_count := clampi(alive_count, 0, total_enemies)
	current_wave_defeated = total_enemies - safe_alive_count
	rogue_combat_hud.set_defeated_enemy_count(
		current_wave_defeated,
		total_enemies
	)


func apply_remote_flow_state(
	step_id: StringName,
	state: int,
	seconds: int
) -> void:
	if runtime_mode != RuntimeMode.CLIENT_VIEW:
		return
	var typed_state := state as CombatFlowState.State
	var was_wave_active := wave_state == CombatFlowState.State.WAVE_ACTIVE
	if typed_state == CombatFlowState.State.WAVE_ACTIVE and was_wave_active:
		combat_seconds_remaining = maxi(seconds, 0)
		rogue_combat_hud.set_combat_remaining_time(
			float(combat_seconds_remaining)
		)
		return
	super.apply_remote_flow_state(step_id, state, seconds)
	match typed_state:
		CombatFlowState.State.PRE_WAVE:
			rogue_combat_hud.show_preparation(
				event_title,
				float(seconds),
				_get_expected_enemy_count(current_flow_step)
			)
		CombatFlowState.State.WAVE_ACTIVE:
			combat_seconds_remaining = maxi(seconds, 0)
			var total_enemies := _get_expected_enemy_count(current_flow_step)
			current_wave_total = total_enemies
			current_wave_defeated = 0
			rogue_combat_hud.show_combat(
				event_title,
				float(combat_seconds_remaining),
				0,
				total_enemies
			)
		CombatFlowState.State.VICTORY, CombatFlowState.State.DEFEAT:
			rogue_combat_hud.hide_hud()


func get_flow_state_snapshot() -> Dictionary:
	var snapshot := super.get_flow_state_snapshot()
	if wave_state == CombatFlowState.State.WAVE_ACTIVE:
		snapshot["countdown_seconds"] = combat_seconds_remaining
	return snapshot


func _emit_multiplayer_flow_state(state: CombatFlowState.State) -> void:
	if runtime_mode != RuntimeMode.HOST_AUTHORITY:
		return
	var seconds := (
		combat_seconds_remaining
		if state == CombatFlowState.State.WAVE_ACTIVE
		else countdown_seconds
	)
	multiplayer_mode_adapter.flow_state_changed.emit(
		_get_flow_step_id(current_flow_step),
		int(state),
		seconds
	)


func _on_player_died() -> void:
	_present_permanent_death(0)
	super._on_player_died()


func _on_multiplayer_player_died(peer_id: int) -> void:
	_present_permanent_death(peer_id)
	super._on_multiplayer_player_died(peer_id)


func _present_permanent_death(peer_id: int) -> void:
	var dead_player := (
		player
		if runtime_mode == RuntimeMode.SINGLEPLAYER
		else get_player_for_peer(peer_id)
	)
	if dead_player != null and is_instance_valid(dead_player):
		dead_player.apply_permanent_death_presentation()
	var is_local_death := (
		(runtime_mode == RuntimeMode.SINGLEPLAYER and peer_id == 0)
		or peer_id == multiplayer_local_peer_id
	)
	if is_local_death:
		player_life_status_hud.show_local_permanent_death(peer_id)


func _enter_victory(emit_multiplayer: bool = true) -> void:
	if wave_state == CombatFlowState.State.VICTORY:
		return
	_stop_combat_deadline()
	super._enter_victory(emit_multiplayer)
	rogue_combat_hud.hide_hud()
	_emit_combat_outcome_once(true, "")


func _enter_defeat() -> void:
	if wave_state == CombatFlowState.State.DEFEAT:
		return
	_stop_combat_deadline()
	super._enter_defeat()
	rogue_combat_hud.hide_hud()
	_emit_combat_outcome_once(false, _failure_reason)


func get_multiplayer_defeat_reason() -> String:
	return _failure_reason


func apply_remote_defeat_with_reason(failure_reason: String) -> void:
	_failure_reason = (
		failure_reason
		if not failure_reason.strip_edges().is_empty()
		else DEFAULT_FAILURE_REASON
	)
	apply_remote_defeat()


func apply_remote_defeat() -> void:
	if runtime_mode != RuntimeMode.CLIENT_VIEW or wave_state == CombatFlowState.State.DEFEAT:
		return
	_stop_combat_deadline()
	super.apply_remote_defeat()
	rogue_combat_hud.hide_hud()
	_emit_combat_outcome_once(false, _failure_reason)


func _reset_combat_outcome() -> void:
	_outcome_emitted = false
	_failure_reason = DEFAULT_FAILURE_REASON


func _emit_combat_outcome_once(victory: bool, failure_reason: String) -> void:
	if _outcome_emitted:
		return
	_outcome_emitted = true
	combat_outcome_started.emit(victory, failure_reason)


func _reset_combat_deadline() -> void:
	combat_deadline_timer.stop()
	_combat_deadline_started = false
	combat_seconds_remaining = maxi(ceili(combat_time_limit_seconds), 1)


func _start_combat_deadline() -> void:
	if _combat_deadline_started:
		return
	_combat_deadline_started = true
	combat_deadline_timer.start()


func _stop_combat_deadline() -> void:
	_combat_deadline_started = false
	combat_deadline_timer.stop()


func _get_expected_enemy_count(flow_step: FlowStepConfig) -> int:
	var wave_config := flow_step as WaveConfig
	return wave_config.get_total_enemy_count() if wave_config != null else 0


func allows_debug_collectible_grants() -> bool:
	return OS.is_debug_build()


func apply_remote_boss_started(
	_net_id: int,
	_boss_config: BossConfig,
	_spawn_position: Vector2
) -> void:
	# Rouge 普通作战不定义 Boss 流程；保留稳定多人 façade 并明确拒绝。
	pass


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


func show_local_skill1_purchase_result(_result_code: int) -> void:
	# Rouge 作战没有商人购买结果面板。
	pass


func show_debug_collectible_grant_result(
	_config_path: String,
	_success: bool
) -> void:
	# Rouge 作战没有普通模式调试收藏品窗口入口。
	pass


func show_simple_crafting_result(
	recipe_id: StringName,
	result: StringName,
	request_token: int
) -> void:
	player_profile_panel.show_simple_crafting_result(
		recipe_id,
		result,
		request_token
	)


func _update_wave_music(wave_config: WaveConfig) -> void:
	if wave_config == null or wave_config.music == null:
		return
	_play_music_stream(wave_config.music, DEFAULT_MUSIC_VOLUME_DB, 0.0, true)


func _update_post_wave_music(flow_step: FlowStepConfig) -> void:
	var wave_config := flow_step as WaveConfig
	if wave_config == null or wave_config.post_wave_music == null:
		return
	_play_music_stream(
		wave_config.post_wave_music,
		DEFAULT_MUSIC_VOLUME_DB,
		0.0,
		true
	)


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
	music_player.volume_db = (
		MUSIC_FADE_IN_START_VOLUME_DB if fade_in else volume_db
	)
	music_player.play()
	if not fade_in:
		return
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


func _audio_stream_has_property(
	stream: AudioStream,
	property_name: StringName
) -> bool:
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
