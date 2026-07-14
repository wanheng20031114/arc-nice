extends CanvasLayer
class_name WaveHUD

const EARLY_START_RETRY_SECONDS := 1.5
const CORE_HEALTH_COLOR := Color(0.42, 0.82, 1.0, 1.0)
const CORE_CRITICAL_COLOR := Color(1.0, 0.31, 0.28, 1.0)
const CORE_HIT_FLASH_COLOR := Color(1.28, 0.78, 0.72, 1.0)
const STAGE_FINAL_COLOR := Color(1.0, 0.76, 0.34, 1.0)

signal return_to_lobby_requested
signal start_wave_requested

@onready var top_bar: PanelContainer = $WaveInfoBar
@onready var top_bar_margin: MarginContainer = $WaveInfoBar/Margin
@onready var status_label: Label = $WaveInfoBar/Margin/Status
@onready var tower_defense_stats: HBoxContainer = $WaveInfoBar/Margin/TowerDefenseStats
@onready var core_stat: VBoxContainer = $WaveInfoBar/Margin/TowerDefenseStats/CoreStat
@onready var core_title_label: Label = $WaveInfoBar/Margin/TowerDefenseStats/CoreStat/CoreRow/CoreTitle
@onready var core_value_label: Label = $WaveInfoBar/Margin/TowerDefenseStats/CoreStat/CoreRow/CoreValue
@onready var core_progress_bar: ProgressBar = $WaveInfoBar/Margin/TowerDefenseStats/CoreStat/CoreProgress
@onready var enemy_stat: VBoxContainer = $WaveInfoBar/Margin/TowerDefenseStats/EnemyStat
@onready var enemy_title_label: Label = $WaveInfoBar/Margin/TowerDefenseStats/EnemyStat/EnemyRow/EnemyTitle
@onready var enemy_value_label: Label = $WaveInfoBar/Margin/TowerDefenseStats/EnemyStat/EnemyRow/EnemyValue
@onready var wave_stat: VBoxContainer = $WaveInfoBar/Margin/TowerDefenseStats/WaveStat
@onready var wave_title_label: Label = $WaveInfoBar/Margin/TowerDefenseStats/WaveStat/WaveRow/WaveTitle
@onready var wave_value_label: Label = $WaveInfoBar/Margin/TowerDefenseStats/WaveStat/WaveRow/WaveValue
@onready var wave_progress_bar: ProgressBar = $WaveInfoBar/Margin/TowerDefenseStats/WaveStat/WaveProgress
@onready var stage_banner: PanelContainer = $StageBanner
@onready var stage_label: Label = $StageBanner/Margin/StageLabel
@onready var start_wave_button: Button = $StartWaveButton
@onready var result_overlay: Control = $ResultOverlay
@onready var result_backdrop: TextureRect = $ResultOverlay/Backdrop
@onready var result_shade: ColorRect = $ResultOverlay/Shade
@onready var result_panel: PanelContainer = $ResultOverlay/Center/Panel
@onready var result_title: Label = $ResultOverlay/Center/Panel/Margin/Content/ResultTitle
@onready var result_subtitle: Label = $ResultOverlay/Center/Panel/Margin/Content/ResultSubtitle
@onready var return_button: Button = $ResultOverlay/Center/Panel/Margin/Content/ReturnButton

var pulse_tween: Tween = null
var core_pulse_tween: Tween = null
var stage_pulse_tween: Tween = null
var result_tween: Tween = null
var return_button_label: String = "返回大厅"
var early_start_pending := false
var early_start_request_generation := 0
var tower_defense_mode := false
var _cached_core_current := -1
var _cached_core_max := -1
var _cached_enemy_count := -1
var _cached_wave_number := -1
var _cached_wave_resolved := -1
var _cached_wave_total := -1


func _ready() -> void:
	return_button.pressed.connect(return_to_lobby_requested.emit)
	start_wave_button.pressed.connect(_on_start_wave_button_pressed)


func set_return_button_text(button_text: String) -> void:
	return_button_label = button_text
	if return_button != null:
		return_button.text = return_button_label


func configure_tower_defense(current_core_health: int, max_core_health: int) -> void:
	tower_defense_mode = true
	_apply_tower_defense_layout()
	status_label.visible = false
	tower_defense_stats.visible = true
	stage_banner.visible = false
	set_tower_defense_core_health(current_core_health, max_core_health)
	set_tower_defense_enemy_count(0)
	set_tower_defense_wave_progress(1, 0, 0)


func _apply_tower_defense_layout() -> void:
	top_bar.custom_minimum_size = Vector2(390.0, 44.0)
	top_bar.offset_left = -195.0
	top_bar.offset_top = 6.0
	top_bar.offset_right = 195.0
	top_bar.offset_bottom = 50.0
	top_bar_margin.add_theme_constant_override("margin_left", 10)
	top_bar_margin.add_theme_constant_override("margin_top", 3)
	top_bar_margin.add_theme_constant_override("margin_right", 10)
	top_bar_margin.add_theme_constant_override("margin_bottom", 3)
	stage_banner.custom_minimum_size = Vector2(190.0, 26.0)
	stage_banner.offset_left = -195.0
	stage_banner.offset_top = 54.0
	stage_banner.offset_right = -5.0
	stage_banner.offset_bottom = 80.0
	start_wave_button.custom_minimum_size = Vector2(190.0, 26.0)
	start_wave_button.offset_left = 5.0
	start_wave_button.offset_top = 54.0
	start_wave_button.offset_right = 195.0
	start_wave_button.offset_bottom = 80.0
	start_wave_button.add_theme_font_size_override("font_size", 11)


func set_tower_defense_core_health(
	current_health: int,
	max_health: int,
	play_damage_pulse: bool = true
) -> void:
	var safe_max := maxi(max_health, 0)
	var safe_current := clampi(current_health, 0, safe_max) if safe_max > 0 else 0
	if safe_current == _cached_core_current and safe_max == _cached_core_max:
		return

	var took_damage := (
		play_damage_pulse
		and _cached_core_current >= 0
		and safe_current < _cached_core_current
	)
	_cached_core_current = safe_current
	_cached_core_max = safe_max
	core_value_label.text = "%d/%d" % [safe_current, safe_max]
	core_progress_bar.max_value = float(maxi(safe_max, 1))
	core_progress_bar.value = float(safe_current)
	var is_critical := safe_max > 0 and safe_current * 4 <= safe_max
	var value_color := CORE_CRITICAL_COLOR if is_critical else CORE_HEALTH_COLOR
	core_value_label.self_modulate = value_color
	core_progress_bar.self_modulate = (
		Color(2.0, 0.42, 0.34, 1.0) if is_critical else Color.WHITE
	)
	if took_damage:
		_pulse_core_stat()


func set_tower_defense_enemy_count(alive_count: int) -> void:
	var safe_count := maxi(alive_count, 0)
	if safe_count == _cached_enemy_count:
		return
	_cached_enemy_count = safe_count
	enemy_value_label.text = str(safe_count)


func set_tower_defense_wave_progress(wave_number: int, resolved: int, total: int) -> void:
	var safe_wave := maxi(wave_number, 1)
	var safe_total := maxi(total, 0)
	var safe_resolved := clampi(resolved, 0, safe_total) if safe_total > 0 else 0
	if (
		safe_wave == _cached_wave_number
		and safe_resolved == _cached_wave_resolved
		and safe_total == _cached_wave_total
	):
		return
	_cached_wave_number = safe_wave
	_cached_wave_resolved = safe_resolved
	_cached_wave_total = safe_total
	var progress_percent := (
		roundi(float(safe_resolved) / float(safe_total) * 100.0)
		if safe_total > 0
		else 0
	)
	wave_title_label.text = "第 %d 波" % safe_wave
	wave_value_label.text = "%d%%" % progress_percent
	wave_progress_bar.value = float(progress_percent)

func show_wave_progress(wave_number: int, defeated: int, total: int) -> void:
	_stop_result_tween()
	top_bar.visible = true
	result_overlay.visible = false
	status_label.modulate = Color.WHITE
	status_label.text = "第 %d 波  已消灭 %d/%d" % [
		wave_number,
		defeated,
		total,
	]
	_hide_start_wave_button()


func show_tower_defense_wave_progress(
	wave_number: int,
	defeated: int,
	escaped: int,
	resolved: int,
	total: int
) -> void:
	_stop_result_tween()
	if not tower_defense_mode:
		configure_tower_defense(0, 0)
	top_bar.visible = true
	result_overlay.visible = false
	status_label.visible = false
	tower_defense_stats.visible = true
	_hide_stage_banner()
	status_label.text = "第 %d 波  击败 %d  ·  漏过 %d  ·  已结算 %d/%d" % [
		wave_number,
		defeated,
		escaped,
		resolved,
		total,
	]
	set_tower_defense_wave_progress(wave_number, resolved, total)
	_hide_start_wave_button()


func show_tower_defense_boss_progress(resolved: int = 0, total: int = 1) -> void:
	_stop_result_tween()
	if not tower_defense_mode:
		configure_tower_defense(0, 0)
	top_bar.visible = true
	result_overlay.visible = false
	status_label.visible = false
	tower_defense_stats.visible = true
	_hide_stage_banner()
	set_tower_defense_wave_progress(maxi(_cached_wave_number, 1), resolved, total)
	wave_title_label.text = "首领战"
	_hide_start_wave_button()


func show_enemy_count(wave_number: int, alive_count: int) -> void:
	_stop_result_tween()
	top_bar.visible = true
	result_overlay.visible = false
	status_label.modulate = Color.WHITE
	status_label.text = "第 %d 波  场上敌人 %d" % [wave_number, maxi(alive_count, 0)]
	_hide_start_wave_button()


func show_countdown(seconds: int, allow_early_start: bool = false) -> void:
	_stop_result_tween()
	top_bar.visible = true
	result_overlay.visible = false
	var safe_seconds := maxi(seconds, 0)
	var countdown_text := (
		_format_countdown(safe_seconds)
		if allow_early_start
		else "%d 秒" % safe_seconds
	)
	var countdown_status := "下一波将在 %s 后开始" % countdown_text
	status_label.text = countdown_status
	start_wave_button.visible = allow_early_start
	start_wave_button.disabled = not allow_early_start or early_start_pending
	if tower_defense_mode:
		start_wave_button.text = "等待开始……" if early_start_pending else "立即开始下一波"
		status_label.visible = false
		tower_defense_stats.visible = true
		stage_banner.visible = true
		stage_label.text = "休整  ·  %s" % countdown_text
		stage_label.self_modulate = (
			STAGE_FINAL_COLOR if safe_seconds <= 3 else Color(0.84, 0.91, 0.82, 1.0)
		)
		if safe_seconds <= 3:
			_pulse_stage_banner()
		else:
			_reset_stage_banner_pulse()
	else:
		start_wave_button.text = (
			"等待战斗开始……"
			if early_start_pending
			else "提前结束休整并开始战斗"
		)
		status_label.modulate = (
			Color(1.0, 0.86, 0.42, 1.0)
			if seconds <= 3
			else Color.WHITE
		)
		if seconds <= 3:
			_pulse_top_bar()


func show_victory() -> void:
	_hide_start_wave_button()
	_play_result_sequence(
		"通关",
		"源石虫的浪潮暂时退去了",
		Color(1.0, 0.9, 0.42, 1.0)
	)


func show_defeat() -> void:
	_hide_start_wave_button()
	_play_result_sequence(
		"战败",
		"全员已经倒下，回到大厅重新整备。",
		Color(1.0, 0.38, 0.3, 1.0)
	)


func show_tower_defense_defeat() -> void:
	_hide_start_wave_button()
	_play_result_sequence(
		"战败",
		"核心生命值归0，游戏结束",
		Color(1.0, 0.38, 0.3, 1.0)
	)


func hide_all() -> void:
	_stop_result_tween()
	top_bar.visible = false
	_hide_stage_banner()
	result_overlay.visible = false
	_hide_start_wave_button()


func _on_start_wave_button_pressed() -> void:
	if start_wave_button.disabled or not start_wave_button.visible:
		return
	start_wave_button.disabled = true
	start_wave_button.text = "等待开始……" if tower_defense_mode else "等待战斗开始……"
	early_start_pending = true
	early_start_request_generation += 1
	var request_generation := early_start_request_generation
	start_wave_requested.emit()
	get_tree().create_timer(EARLY_START_RETRY_SECONDS).timeout.connect(
		_on_early_start_retry_timeout.bind(request_generation)
	)


func _hide_start_wave_button() -> void:
	early_start_request_generation += 1
	early_start_pending = false
	start_wave_button.visible = false
	start_wave_button.disabled = true


func _on_early_start_retry_timeout(request_generation: int) -> void:
	if request_generation != early_start_request_generation:
		return
	if not early_start_pending or not start_wave_button.visible:
		return
	early_start_pending = false
	start_wave_button.disabled = false
	start_wave_button.text = (
		"立即开始下一波"
		if tower_defense_mode
		else "提前结束休整并开始战斗"
	)


func _format_countdown(seconds: int) -> String:
	var safe_seconds := maxi(seconds, 0)
	return "%02d:%02d" % [floori(float(safe_seconds) / 60.0), safe_seconds % 60]


func _play_result_sequence(title: String, subtitle: String, title_color: Color) -> void:
	_stop_result_tween()
	top_bar.visible = false
	_hide_stage_banner()
	result_overlay.visible = true
	result_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	result_title.text = title
	result_title.modulate = Color(title_color.r, title_color.g, title_color.b, 0.0)
	result_subtitle.text = subtitle
	result_subtitle.modulate = Color(0.88, 0.95, 0.86, 0.0)
	return_button.text = return_button_label
	return_button.visible = false
	return_button.disabled = true
	return_button.modulate = Color(1.0, 1.0, 1.0, 0.0)
	result_backdrop.modulate = Color(1.0, 1.0, 1.0, 0.0)
	result_shade.color = Color(0.0, 0.0, 0.0, 0.0)
	result_panel.modulate = Color(1.0, 1.0, 1.0, 0.0)
	result_panel.scale = Vector2.ONE

	result_tween = create_tween()
	result_tween.set_parallel(true)
	result_tween.tween_property(result_shade, "color", Color(0.0, 0.0, 0.0, 0.18), 0.85).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	result_tween.tween_property(result_backdrop, "modulate", Color(1.0, 1.0, 1.0, 0.48), 1.0).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	result_tween.tween_property(result_title, "modulate", title_color, 0.34).set_delay(0.62).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	result_tween.tween_property(result_panel, "modulate", Color.WHITE, 0.36).set_delay(1.02).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	result_tween.tween_property(result_subtitle, "modulate", Color(0.88, 0.95, 0.86, 0.94), 0.26).set_delay(1.1).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	result_tween.tween_callback(_show_result_button).set_delay(1.45)


func _show_result_button() -> void:
	return_button.visible = true
	return_button.disabled = false
	return_button.modulate = Color(1.0, 1.0, 1.0, 0.0)
	var button_tween := create_tween()
	button_tween.tween_property(return_button, "modulate", Color.WHITE, 0.26).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	return_button.grab_focus()


func _stop_result_tween() -> void:
	if result_tween != null:
		result_tween.kill()
		result_tween = null


func _pulse_top_bar() -> void:
	if pulse_tween != null:
		pulse_tween.kill()
	top_bar.scale = Vector2.ONE
	top_bar.self_modulate = Color.WHITE
	pulse_tween = create_tween()
	pulse_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	pulse_tween.tween_property(top_bar, "self_modulate", Color(1.2, 1.1, 0.78, 1.0), 0.08)
	pulse_tween.tween_property(top_bar, "self_modulate", Color.WHITE, 0.12)


func _pulse_core_stat() -> void:
	if core_pulse_tween != null:
		core_pulse_tween.kill()
	core_stat.self_modulate = CORE_HIT_FLASH_COLOR
	core_pulse_tween = create_tween()
	core_pulse_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	core_pulse_tween.tween_property(core_stat, "self_modulate", Color.WHITE, 0.28)


func _pulse_stage_banner() -> void:
	if stage_pulse_tween != null:
		stage_pulse_tween.kill()
	stage_banner.self_modulate = Color.WHITE
	stage_pulse_tween = create_tween()
	stage_pulse_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	stage_pulse_tween.tween_property(
		stage_banner,
		"self_modulate",
		Color(1.22, 1.08, 0.64, 1.0),
		0.09
	)
	stage_pulse_tween.tween_property(stage_banner, "self_modulate", Color.WHITE, 0.16)


func _reset_stage_banner_pulse() -> void:
	if stage_pulse_tween != null:
		stage_pulse_tween.kill()
		stage_pulse_tween = null
	stage_banner.self_modulate = Color.WHITE


func _hide_stage_banner() -> void:
	_reset_stage_banner_pulse()
	stage_banner.visible = false
