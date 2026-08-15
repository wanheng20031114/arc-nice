extends WaveCombatRuntimeBase
class_name RogueCombatGame

const MODAL_CONTROL_LOCK_OWNER := &"rogue_combat_modal_ui"

const TANGO_LASER_BULLET_POOL_SCENE := preload(
	"res://scene/player/tango/tango_laser_bullet.tscn"
)
const INITIAL_PLAYER_XIRANG := RoguePlayerRosterCoordinator.INITIAL_PLAYER_XIRANG

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
@onready var presentation_camera: Camera2D = $Camera2D
@onready var music_player: AudioStreamPlayer = $MusicPlayer
@onready var countdown_audio: AudioStreamPlayer = $CountdownAudio
@onready var wave_start_audio: AudioStreamPlayer = $WaveStartAudio
@onready var currency_hud: CurrencyHUD = $CurrencyHUD
@onready var player_profile_panel: RoguePlayerProfilePanel = $PlayerProfilePanel
@onready var settings_panel: SettingsPanel = $SettingsLayer/SettingsPanel

var player_roster_coordinator: RoguePlayerRosterCoordinator:
	get:
		return get_node("PlayerRosterCoordinator") as RoguePlayerRosterCoordinator
var pickup_registry: RoguePickupRegistry:
	get:
		return get_node_or_null("PickupRegistry") as RoguePickupRegistry
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
var combat_seconds_remaining := 0
var _combat_deadline_started := false
var _outcome_emitted := false
var _failure_reason := DEFAULT_FAILURE_REASON
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

	var obstacle_layer := get_node_or_null(
		"GroundTileMapLayer"
	) as TileMapLayer
	if obstacle_layer == null:
		errors.append("Rouge 作战场景缺少 GroundTileMapLayer。")
	elif (
		obstacle_layer.tile_set == null
		or not obstacle_layer.get_used_rect().has_area()
	):
		errors.append("Rouge 作战场景的 GroundTileMapLayer 缺少有效导航格。")
	var pathfinder := get_node_or_null("GridPathfinder") as GridPathfinder
	if pathfinder == null:
		errors.append("Rouge 作战场景缺少 GridPathfinder。")
	elif pathfinder.obstacle_tile_layer_path.is_empty():
		errors.append("Rouge 作战场景的 GridPathfinder 未绑定障碍层。")
	elif (
		pathfinder.get_node_or_null(pathfinder.obstacle_tile_layer_path)
		as TileMapLayer
	) != obstacle_layer:
		errors.append("Rouge 作战场景的 GridPathfinder 未绑定 GroundTileMapLayer。")
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


func configure_multiplayer(
	mode: int,
	local_peer_id: int,
	player_names: Dictionary,
	player_character_ids: Dictionary = {}
) -> void:
	runtime_mode = mode as RuntimeMode
	multiplayer_local_peer_id = local_peer_id
	player_roster_coordinator.configure_peer_metadata(
		player_names,
		player_character_ids
	)


func _initialize_mode_runtime_before_validation() -> void:
	pickup_registry.bind_rogue_dependencies(
		runtime_mode,
		self,
		get_multiplayer_gameplay_gateway(),
		enemy_container
	)
	player_roster_coordinator.bind_dependencies(
		self,
		$PlayerSpawn as Marker2D,
		run_state
	)
	if not player_roster_coordinator.singleplayer_died.is_connected(
		_on_player_died
	):
		player_roster_coordinator.singleplayer_died.connect(_on_player_died)
	if not player_roster_coordinator.multiplayer_player_died.is_connected(
		_on_multiplayer_player_died
	):
		player_roster_coordinator.multiplayer_player_died.connect(
			_on_multiplayer_player_died
		)
	if not player_roster_coordinator.all_players_dead.is_connected(
		_on_all_multiplayer_players_dead
	):
		player_roster_coordinator.all_players_dead.connect(
			_on_all_multiplayer_players_dead
		)
func _validate_mode_scene_content() -> bool:
	if pickup_registry == null:
		push_error("RogueCombatGame: 缺少静态 PickupRegistry 节点。")
		return false
	if not pickup_registry.is_bound():
		push_error("RogueCombatGame: PickupRegistry 依赖未完整绑定。")
		return false
	if player_roster_coordinator == null:
		push_error("RogueCombatGame: 缺少静态 PlayerRosterCoordinator 节点。")
		return false
	if not player_roster_coordinator.is_bound():
		push_error("RogueCombatGame: PlayerRosterCoordinator 依赖未完整绑定。")
		return false
	return true


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


func restore_multiplayer_player(
	old_peer_id: int,
	new_peer_id: int,
	player_name: String,
	character_id: StringName,
	state: SnapshotManager.PlayerState,
	spawn_slot_index: int,
	_reconnect_state: Dictionary = {}
) -> Player:
	return player_roster_coordinator.restore_multiplayer_player(
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


func _register_mode_object_pools() -> void:
	session_object_pool.register_scene(TANGO_LASER_BULLET_POOL_SCENE, 64, 768)


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
	player_profile_panel.configure_local_upgrade_authority(
		runtime_mode != RuntimeMode.CLIENT_VIEW
	)
	player_profile_panel.bind_player(player)
	currency_hud.settings_requested.connect(_on_currency_hud_settings_requested)
	currency_hud.profile_requested.connect(player_profile_panel.open)
	settings_panel.closed.connect(_on_settings_panel_closed)


func _apply_initial_player_resources() -> void:
	player_roster_coordinator.apply_initial_xirang()


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
	if player != null and is_instance_valid(player):
		player.set_control_lock(MODAL_CONTROL_LOCK_OWNER, true)


func _refresh_player_modal_ui_lock() -> void:
	if player == null or not is_instance_valid(player):
		return
	player.set_control_lock(
		MODAL_CONTROL_LOCK_OWNER,
		settings_panel.is_open()
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
	if not apply_wave_progress_snapshot(
		total_enemies,
		total_enemies,
		total_enemies - safe_alive_count
	):
		return
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
			reset_wave_progress(total_enemies, total_enemies)
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
	if wave_state in [
		CombatFlowState.State.VICTORY,
		CombatFlowState.State.DEFEAT,
	]:
		return
	_enter_defeat()


func _on_multiplayer_player_died(peer_id: int) -> void:
	_present_permanent_death(peer_id)
	if (
		runtime_mode != RuntimeMode.HOST_AUTHORITY
		or wave_state in [
			CombatFlowState.State.VICTORY,
			CombatFlowState.State.DEFEAT,
		]
	):
		return
	player_roster_coordinator.schedule_multiplayer_defeat_check()


func _on_all_multiplayer_players_dead() -> void:
	if (
		runtime_mode != RuntimeMode.HOST_AUTHORITY
		or wave_state in [
			CombatFlowState.State.VICTORY,
			CombatFlowState.State.DEFEAT,
		]
	):
		return
	_enter_defeat()


func _check_multiplayer_defeat_after_grace() -> void:
	player_roster_coordinator.run_multiplayer_defeat_check_after_grace()


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
	player_instance.set_xirang_balance(current_xirang)
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
	return player_roster_coordinator.request_tango_charge_started(direction)

func request_tango_charge_released(direction: Vector2) -> bool:
	return player_roster_coordinator.request_tango_charge_released(direction)

func request_tango_charge_cancelled() -> bool:
	return player_roster_coordinator.request_tango_charge_cancelled()
