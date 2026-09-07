extends CanvasLayer
class_name VehicleCombatHUD

signal return_to_menu_requested
signal inventory_requested
signal start_requested
signal retry_requested

const ACCENT := Color(0.35, 0.87, 0.98)
const MUTED := Color(0.58, 0.69, 0.75)
const DANGER := Color(1.0, 0.38, 0.32)
const TELEMETRY_INTERVAL := 0.08

@onready var hud_root: Control = $Root
@onready var cockpit: Control = %Cockpit
@onready var wave_content: VBoxContainer = %WaveContent
@onready var wave_index: Label = %WaveIndex
@onready var wave_total: Label = %WaveTotal
@onready var wave_title: Label = %WaveTitle
@onready var phase_label: Label = %PhaseLabel
@onready var progress_label: Label = %ProgressLabel
@onready var wave_progress: ProgressBar = %WaveProgress
@onready var alive_label: Label = %AliveLabel
@onready var inventory_button: Button = %InventoryButton
@onready var vehicle_portrait: TextureRect = %VehiclePortrait
@onready var telemetry: PanelContainer = %Telemetry
@onready var speed_label: Label = %SpeedLabel
@onready var gear_label: Label = %GearLabel
@onready var speed_bar: ProgressBar = %SpeedBar
@onready var health_label: Label = %HealthLabel
@onready var health_bar: ProgressBar = %HealthBar
@onready var ammo_caption: Label = %AmmoCaption
@onready var ammo_label: Label = %AmmoLabel
@onready var ammo_bar: ProgressBar = %AmmoBar
@onready var skill_label: Label = %SkillLabel
@onready var skill_status: Label = %SkillStatus
@onready var skill_bar: ProgressBar = %SkillBar
@onready var driving_hint: Label = %DrivingHint
@onready var weapon_hint: Label = %WeaponHint
@onready var countdown: VBoxContainer = %Countdown
@onready var countdown_title: Label = %CountdownTitle
@onready var countdown_number: Label = %CountdownNumber
@onready var result_overlay: Control = %ResultOverlay
@onready var result_panel: PanelContainer = %ResultPanel
@onready var result_eyebrow: Label = %ResultEyebrow
@onready var result_title: Label = %ResultTitle
@onready var result_detail: Label = %ResultDetail
@onready var return_button: Button = %ReturnButton
@onready var action_button: Button = %ActionButton
@onready var result_stats: Label = %ResultStats
@onready var run_status: Label = %RunStatus

var _vehicle: PlayerVehicle
var _wave_number := 0
var _total_waves := 12
var _progress_target := -1.0
var _telemetry_elapsed := 0.0
var _skill_name := ""
var _wave_tween: Tween
var _progress_tween: Tween
var _countdown_tween: Tween
var _result_tween: Tween
var _run_progress: VehicleRunProgress
var _primary_action: StringName = &""
var _launch_ready := false
var _service_summary := ""


func _ready() -> void:
	set_process(false)
	UserSettings.action_bindings_changed.connect(_on_action_bindings_changed)
	_refresh_control_hints()
	var portrait_material := vehicle_portrait.material as ShaderMaterial
	portrait_material.set_shader_parameter(&"paint_color", RunState.get_vehicle_paint_color())


func bind_player(player: Player) -> void:
	if is_instance_valid(_vehicle):
		_vehicle.health_changed.disconnect(_on_health_changed)
	_vehicle = player as PlayerVehicle
	telemetry.visible = _vehicle != null
	set_process(_vehicle != null)
	if _vehicle == null:
		return
	_vehicle.health_changed.connect(_on_health_changed)
	_skill_name = _vehicle.get_skill1_display_name()
	_on_health_changed(_vehicle.current_health, _vehicle.max_health)
	_refresh_control_hints()
	_update_telemetry()


func set_wave(
	wave_number: int,
	total_waves: int,
	wave_name: String,
	total_enemies: int
) -> void:
	_show_cockpit()
	_service_summary = ""
	_wave_number = wave_number
	_total_waves = total_waves
	wave_index.text = "%02d" % wave_number
	wave_total.text = "/ %02d" % total_waves
	wave_title.text = wave_name
	phase_label.text = "清除本波敌人"
	countdown.hide()
	_progress_target = -1.0
	wave_progress.value = 0.0
	set_progress(0, total_enemies, 0)
	if _wave_tween != null:
		_wave_tween.kill()
	wave_content.modulate.a = 0.25
	_wave_tween = create_tween()
	_wave_tween.tween_property(wave_content, "modulate:a", 1.0, 0.32)


func set_progress(defeated: int, total: int, alive: int) -> void:
	var safe_total := maxi(total, 0)
	var safe_defeated := clampi(defeated, 0, safe_total)
	progress_label.text = "%d / %d 已击破" % [safe_defeated, safe_total]
	alive_label.text = "%02d" % maxi(alive, 0)
	var target := float(safe_defeated) / float(maxi(safe_total, 1))
	if is_equal_approx(target, _progress_target):
		return
	_progress_target = target
	if _progress_tween != null:
		_progress_tween.kill()
	_progress_tween = create_tween()
	_progress_tween.tween_property(wave_progress, "value", target, 0.18)


func set_countdown(
	wave_number: int,
	total_waves: int,
	seconds: int,
	is_intermission: bool
) -> void:
	_show_cockpit()
	_total_waves = total_waves
	wave_index.text = "%02d" % wave_number
	wave_total.text = "/ %02d" % total_waves
	wave_title.text = "准备下一波" if is_intermission else "引擎就绪"
	phase_label.text = _service_summary if is_intermission else "保持移动，清除所有敌人"
	progress_label.text = "每波结束 · 收藏品 3 选 1"
	alive_label.text = "00"
	countdown_title.text = "第 %02d 波即将开始" % wave_number
	countdown_number.text = "%02d" % maxi(seconds, 0)
	countdown.show()
	if _countdown_tween != null:
		_countdown_tween.kill()
	countdown_number.pivot_offset = countdown_number.size * 0.5
	countdown_number.scale = Vector2.ONE * 0.9
	countdown_number.modulate.a = 0.55
	_countdown_tween = create_tween().set_parallel(true)
	_countdown_tween.tween_property(countdown_number, "scale", Vector2.ONE, 0.24).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_countdown_tween.tween_property(countdown_number, "modulate:a", 1.0, 0.18)


func show_reward(cleared_wave: int) -> void:
	_show_cockpit()
	countdown.hide()
	phase_label.text = "第 %02d 波已清空" % cleared_wave
	progress_label.text = "选择一件收藏品"
	alive_label.text = "00"
	if _progress_tween != null:
		_progress_tween.kill()
	wave_progress.value = 1.0
	_progress_target = 1.0
	inventory_button.disabled = true
	cockpit.hide()


func show_victory() -> void:
	_primary_action = &"retry"
	action_button.text = "再来一局"
	_show_result(
		"%02d / %02d 波次完成" % [_total_waves, _total_waves],
		"突围成功",
		"最后一波敌人已清空。\n这辆小车，撑到了最后。",
		ACCENT
	)


func show_defeat() -> void:
	_primary_action = &"retry"
	action_button.text = "重新出发"
	_show_result(
		"抵达第 %02d / %02d 波" % [_wave_number, _total_waves],
		"战车失去动力",
		"本次突围结束。\n重新整备，再次出发。",
		DANGER
	)


func show_briefing(best_score: int, ready_to_launch: bool) -> void:
	_primary_action = &"start"
	_launch_ready = ready_to_launch
	action_button.text = "启动引擎" if ready_to_launch else "正在准备战场…"
	set_result_stats("%s\n%s\n%s · 向车头方向发射榴弹\n个人最佳得分 %d" % [
		driving_hint.text, weapon_hint.text, skill_label.text, best_score,
	])
	_show_result(
		"12 道关卡 · 战车突围",
		"一辆小车，冲出包围",
		"清空每波敌人，选择一件免费收藏品。\n波间自动：攻击 +4、耐久上限 +10、维修 25%、弹药补满。\n背包 / 改装中可用息壤强化火力与耐久。\n车头决定射向，松键滑行，反向键先刹车再倒车。\n无伤清场和快速通关可获得额外积分。",
		ACCENT
	)


func set_launch_ready(ready_to_launch: bool) -> void:
	_launch_ready = ready_to_launch
	if _primary_action == &"start":
		action_button.text = "启动引擎" if ready_to_launch else "正在准备战场…"
		action_button.disabled = not ready_to_launch


func set_run_status(progress: VehicleRunProgress) -> void:
	_run_progress = progress
	_update_run_status()


func set_service_status(wave_number: int, attack: int) -> void:
	_service_summary = "火控 Lv.%d · 攻击 %d · 已维修并补满弹药" % [wave_number, attack]


func set_result_stats(text: String) -> void:
	result_stats.text = text


func _update_run_status() -> void:
	if _run_progress == null or not is_instance_valid(_vehicle):
		return
	run_status.text = "得分 %05d  ·  战斗 %s  ·  息壤 %d  ·  攻击 %d" % [
		_run_progress.score, VehicleRunProgress.format_time(_run_progress.combat_seconds),
		_vehicle.get_xirang(), _vehicle.attack_damage,
	]


func hide_all() -> void:
	hud_root.hide()
	_stop_result_tween()
	result_overlay.hide()
	countdown.hide()


func _process(delta: float) -> void:
	if not is_instance_valid(_vehicle):
		set_process(false)
		return
	_telemetry_elapsed += delta
	if _telemetry_elapsed < TELEMETRY_INTERVAL:
		return
	_telemetry_elapsed = 0.0
	_update_telemetry()
	_update_run_status()


func _update_telemetry() -> void:
	var speed := absf(_vehicle.longitudinal_speed)
	speed_label.text = "%03d" % roundi(speed)
	gear_label.text = "倒车" if _vehicle.longitudinal_speed < -0.5 else ("前进" if speed > 0.5 else "驻车")
	speed_bar.value = speed / PlayerVehicle.MAX_VEHICLE_SPEED
	var capacity := _vehicle.get_multiplayer_ammo_capacity()
	var ammunition := _vehicle.get_multiplayer_current_ammo()
	if _vehicle.get_multiplayer_is_reloading():
		ammo_caption.text = "装填中"
		ammo_bar.value = _vehicle.get_multiplayer_reload_progress()
		ammo_label.text = "%d%%" % roundi(ammo_bar.value * 100.0)
	else:
		ammo_caption.text = "弹药"
		ammo_label.text = "%02d / %02d" % [ammunition, capacity]
		ammo_bar.value = float(ammunition) / float(maxi(capacity, 1))
	var skill_ready := (
		_vehicle.skill1_unlocked
		and not _vehicle.is_dead
		and (_vehicle.has_void_battery_charge() or _vehicle.skill1_charge >= _vehicle.skill1_charge_duration)
	)
	skill_bar.value = 1.0 if skill_ready else _vehicle.skill1_charge / maxf(_vehicle.skill1_charge_duration, 0.01)
	if not _vehicle.skill1_unlocked:
		skill_status.text = "未解锁"
	elif _vehicle.is_dead:
		skill_status.text = "离线"
	elif skill_ready:
		skill_status.text = "已就绪"
	else:
		skill_status.text = "充能 %d%%" % roundi(skill_bar.value * 100.0)
	skill_status.add_theme_color_override("font_color", ACCENT if skill_ready else MUTED)


func _on_health_changed(current: int, maximum: int) -> void:
	health_label.text = "%d / %d" % [current, maximum]
	health_bar.value = float(current) / float(maxi(maximum, 1))
	health_bar.modulate = DANGER if health_bar.value <= 0.25 else ACCENT
	health_label.modulate = DANGER if health_bar.value <= 0.25 else Color.WHITE


func _on_action_bindings_changed(_action: StringName) -> void:
	_refresh_control_hints()


func _refresh_control_hints() -> void:
	driving_hint.text = "%s / %s 前进·倒车    %s / %s 转向" % [
		UserSettings.get_primary_keyboard_binding_text("move_up", "—", true),
		UserSettings.get_primary_keyboard_binding_text("move_down", "—", true),
		UserSettings.get_primary_keyboard_binding_text("move_left", "—", true),
		UserSettings.get_primary_keyboard_binding_text("move_right", "—", true),
	]
	weapon_hint.text = "鼠标左键 开火    %s 装填    %s 暂停" % [
		UserSettings.get_primary_keyboard_binding_text("reload", "—", true),
		UserSettings.get_primary_keyboard_binding_text("pause", "—", true),
	]
	skill_label.text = "%s  %s" % [
		UserSettings.get_primary_keyboard_binding_text("skill1", "—", true),
		_skill_name if not _skill_name.is_empty() else "战车技能",
	]


func _show_cockpit() -> void:
	_stop_result_tween()
	hud_root.show()
	cockpit.show()
	result_overlay.hide()
	inventory_button.disabled = false


func _show_result(eyebrow: String, title: String, detail: String, accent: Color) -> void:
	_stop_result_tween()
	hud_root.show()
	cockpit.hide()
	result_overlay.show()
	result_eyebrow.text = eyebrow
	result_title.text = title
	result_title.add_theme_color_override("font_color", accent)
	result_detail.text = detail
	result_overlay.modulate.a = 0.0
	result_panel.pivot_offset = result_panel.size * 0.5
	result_panel.scale = Vector2.ONE * 0.96
	return_button.disabled = true
	action_button.disabled = true
	_result_tween = create_tween().set_parallel(true)
	_result_tween.tween_property(result_overlay, "modulate:a", 1.0, 0.3)
	_result_tween.tween_property(result_panel, "scale", Vector2.ONE, 0.4).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_result_tween.chain().tween_callback(_enable_return_button)


func _enable_return_button() -> void:
	return_button.disabled = false
	action_button.disabled = _primary_action == &"start" and not _launch_ready
	if not action_button.disabled:
		action_button.grab_focus()


func _stop_result_tween() -> void:
	if _result_tween != null:
		_result_tween.kill()
		_result_tween = null


func _on_inventory_pressed() -> void:
	inventory_requested.emit()


func _on_return_pressed() -> void:
	return_button.disabled = true
	return_to_menu_requested.emit()


func _on_action_pressed() -> void:
	action_button.disabled = true
	if _primary_action == &"start":
		start_requested.emit()
	elif _primary_action == &"retry":
		retry_requested.emit()
