extends StandardGame
class_name RogueCombatGame

signal combat_outcome_started(victory: bool, failure_reason: String)

enum DeadlineStart {
	PREPARATION_START,
	WAVE_START,
}

const DEFAULT_EVENT_TITLE := "狭路相逢"
const DEFAULT_FAILURE_REASON := "队伍已全数阵亡"
const TIMEOUT_FAILURE_REASON := "作战时间已耗尽"
const UNDERGROUND_NIGHT_COLOR := DayNightController.REFERENCE_NIGHT_COLOR

@export_group("Rouge 作战")
@export var event_title := DEFAULT_EVENT_TITLE
@export_range(1.0, 3600.0, 1.0, "or_greater")
var combat_time_limit_seconds := 90.0
@export var deadline_start := DeadlineStart.WAVE_START
@export var enemy_pickup_drops_enabled := false

@onready var rogue_combat_hud: RogueCombatHUD = $RogueCombatHUD
@onready var tower_defense_status_hud: TowerDefenseStatusHUD = (
	$TowerDefenseStatusHUD
)
@onready var combat_deadline_timer: Timer = $CombatDeadlineTimer

var combat_seconds_remaining := 0
var _combat_deadline_started := false
var _outcome_emitted := false
var _failure_reason := DEFAULT_FAILURE_REASON
var _spawn_point_rotation_index := 0


func validate_encounter_scene_contract(
	expected_spawn_point_mask: int
) -> PackedStringArray:
	var errors := PackedStringArray()
	if standard_merchants_enabled:
		errors.append("Rouge 专用作战场景必须关闭标准商人能力。")
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
	tower_defense_status_hud.set_dead_player_list_enabled(false)


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
	if wave_state != WaveState.PRE_WAVE:
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
	if wave_state != WaveState.WAVE_ACTIVE:
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
	if wave_state == WaveState.PRE_WAVE:
		rogue_combat_hud.set_preparation_time(float(countdown_seconds))


func _on_combat_deadline_timer_timeout() -> void:
	if not _combat_deadline_started:
		combat_deadline_timer.stop()
		return
	if wave_state not in [WaveState.PRE_WAVE, WaveState.WAVE_ACTIVE]:
		_stop_combat_deadline()
		return
	combat_seconds_remaining = maxi(combat_seconds_remaining - 1, 0)
	if wave_state == WaveState.WAVE_ACTIVE:
		rogue_combat_hud.set_combat_remaining_time(
			float(combat_seconds_remaining)
		)
		_emit_multiplayer_flow_state(WaveState.WAVE_ACTIVE)
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
	if runtime_mode != RuntimeMode.CLIENT_VIEW or wave_state != WaveState.WAVE_ACTIVE:
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
	var typed_state := state as WaveState
	var was_wave_active := wave_state == WaveState.WAVE_ACTIVE
	if typed_state == WaveState.WAVE_ACTIVE and was_wave_active:
		combat_seconds_remaining = maxi(seconds, 0)
		rogue_combat_hud.set_combat_remaining_time(
			float(combat_seconds_remaining)
		)
		return
	super.apply_remote_flow_state(step_id, state, seconds)
	match typed_state:
		WaveState.PRE_WAVE:
			rogue_combat_hud.show_preparation(
				event_title,
				float(seconds),
				_get_expected_enemy_count(current_flow_step)
			)
		WaveState.WAVE_ACTIVE:
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
		WaveState.VICTORY, WaveState.DEFEAT:
			rogue_combat_hud.hide_hud()


func get_flow_state_snapshot() -> Dictionary:
	var snapshot := super.get_flow_state_snapshot()
	if wave_state == WaveState.WAVE_ACTIVE:
		snapshot["countdown_seconds"] = combat_seconds_remaining
	return snapshot


func _emit_multiplayer_flow_state(state: WaveState) -> void:
	if runtime_mode != RuntimeMode.HOST_AUTHORITY:
		return
	var seconds := (
		combat_seconds_remaining
		if state == WaveState.WAVE_ACTIVE
		else countdown_seconds
	)
	multiplayer_flow_state_changed.emit(
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
		dead_player.apply_tower_defense_death_presentation()
	var is_local_death := (
		(runtime_mode == RuntimeMode.SINGLEPLAYER and peer_id == 0)
		or peer_id == multiplayer_local_peer_id
	)
	if is_local_death:
		tower_defense_status_hud.show_local_permanent_death(peer_id)


func _enter_victory(emit_multiplayer: bool = true) -> void:
	if wave_state == WaveState.VICTORY:
		return
	_stop_combat_deadline()
	super._enter_victory(emit_multiplayer)
	rogue_combat_hud.hide_hud()
	_emit_combat_outcome_once(true, "")


func _enter_defeat() -> void:
	if wave_state == WaveState.DEFEAT:
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
	if runtime_mode != RuntimeMode.CLIENT_VIEW or wave_state == WaveState.DEFEAT:
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
