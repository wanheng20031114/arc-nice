extends CanvasLayer
class_name TowerDefenseWaveHUD

const EARLY_START_RETRY_SECONDS := 1.5
const CORE_HEALTH_COLOR := Color(0.42, 0.82, 1.0, 1.0)
const CORE_CRITICAL_COLOR := Color(1.0, 0.31, 0.28, 1.0)
const CORE_HIT_FLASH_COLOR := Color(1.28, 0.78, 0.72, 1.0)
const STAGE_FINAL_COLOR := Color(1.0, 0.76, 0.34, 1.0)

signal return_to_lobby_requested
signal start_wave_requested

@onready var top_bar: PanelContainer = $WaveInfoBar
@onready var top_bar_margin: MarginContainer = $WaveInfoBar/Margin
@onready var tower_defense_stats: HBoxContainer = (
	$WaveInfoBar/Margin/TowerDefenseStats
)
@onready var day_dial: TowerDefenseDayDial = (
	$WaveInfoBar/Margin/TowerDefenseStats/DayCycleStat/DayDial
)
@onready var day_label: Label = (
	$WaveInfoBar/Margin/TowerDefenseStats/DayCycleStat/DayText/DayLabel
)
@onready var phase_label: Label = (
	$WaveInfoBar/Margin/TowerDefenseStats/DayCycleStat/DayText/PhaseLabel
)
@onready var core_stat: VBoxContainer = (
	$WaveInfoBar/Margin/TowerDefenseStats/CoreStat
)
@onready var core_title_label: Label = (
	$WaveInfoBar/Margin/TowerDefenseStats/CoreStat/CoreRow/CoreTitle
)
@onready var core_value_label: Label = (
	$WaveInfoBar/Margin/TowerDefenseStats/CoreStat/CoreRow/CoreValue
)
@onready var core_progress_bar: ProgressBar = (
	$WaveInfoBar/Margin/TowerDefenseStats/CoreStat/CoreProgress
)
@onready var enemy_stat: VBoxContainer = (
	$WaveInfoBar/Margin/TowerDefenseStats/EnemyStat
)
@onready var enemy_title_label: Label = (
	$WaveInfoBar/Margin/TowerDefenseStats/EnemyStat/EnemyRow/EnemyTitle
)
@onready var enemy_value_label: Label = (
	$WaveInfoBar/Margin/TowerDefenseStats/EnemyStat/EnemyRow/EnemyValue
)
@onready var wave_stat: VBoxContainer = (
	$WaveInfoBar/Margin/TowerDefenseStats/WaveStat
)
@onready var wave_title_label: Label = (
	$WaveInfoBar/Margin/TowerDefenseStats/WaveStat/WaveRow/WaveTitle
)
@onready var wave_value_label: Label = (
	$WaveInfoBar/Margin/TowerDefenseStats/WaveStat/WaveRow/WaveValue
)
@onready var wave_progress_bar: ProgressBar = (
	$WaveInfoBar/Margin/TowerDefenseStats/WaveStat/WaveProgress
)
@onready var stage_banner: PanelContainer = $StageBanner
@onready var stage_label: Label = $StageBanner/Margin/StageLabel
@onready var start_wave_button: Button = $StartWaveButton
@onready var result_overlay: Control = $ResultOverlay
@onready var result_backdrop: TextureRect = $ResultOverlay/Backdrop
@onready var result_shade: ColorRect = $ResultOverlay/Shade
@onready var result_panel: PanelContainer = $ResultOverlay/Center/Panel
@onready var result_title: Label = (
	$ResultOverlay/Center/Panel/Margin/Content/ResultTitle
)
@onready var result_subtitle: Label = (
	$ResultOverlay/Center/Panel/Margin/Content/ResultSubtitle
)
@onready var return_button: Button = (
	$ResultOverlay/Center/Panel/Margin/Content/ReturnButton
)
@onready var global_wave_notice: PanelContainer = $GlobalWaveNotice
@onready var global_wave_label: Label = $GlobalWaveNotice/Margin/Label

var core_pulse_tween: Tween = null
var stage_pulse_tween: Tween = null
var result_tween: Tween = null
var global_wave_tween: Tween = null
var return_button_label := "返回大厅"
var early_start_pending := false
var early_start_request_generation := 0
var _cached_core_current := -1
var _cached_core_max := -1
var _cached_enemy_count := -1
var _cached_wave_number := -1
var _cached_wave_resolved := -1
var _cached_wave_total := -1
var _last_noticed_wave := -1
var day_cycle_config: DayCycleConfig = preload(
	"res://resources/config/day_cycle/tower_defense_day_cycle.tres"
)


func _ready() -> void:
	return_button.pressed.connect(return_to_lobby_requested.emit)
	start_wave_button.pressed.connect(_on_start_wave_button_pressed)


func set_return_button_text(button_text: String) -> void:
	return_button_label = button_text
	if return_button != null:
		return_button.text = return_button_label


func configure_tower_defense(
	current_core_health: int,
	max_core_health: int,
	new_day_cycle_config: DayCycleConfig = null
) -> void:
	if new_day_cycle_config != null and new_day_cycle_config.is_valid():
		day_cycle_config = new_day_cycle_config
	top_bar.visible = true
	tower_defense_stats.visible = true
	stage_banner.visible = false
	set_tower_defense_core_health(current_core_health, max_core_health)
	set_tower_defense_enemy_count(0)
	set_tower_defense_wave_progress(1, 0, 0)


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


func set_tower_defense_wave_progress(
	wave_number: int,
	resolved: int,
	total: int
) -> void:
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
	var wave_in_day := day_cycle_config.get_wave_in_day(safe_wave)
	var phase_index := wave_in_day - 1
	var day_number := day_cycle_config.get_day_number(safe_wave)
	var is_night := day_cycle_config.is_night_wave(safe_wave)
	var phase_start := day_cycle_config.night_start_wave_in_day if is_night else 1
	var phase_end := (
		day_cycle_config.waves_per_day
		if is_night
		else day_cycle_config.night_start_wave_in_day - 1
	)
	day_label.text = "第 %d 日" % day_number
	phase_label.text = "%s %d/%d" % [
		"黑夜" if is_night else "白昼",
		wave_in_day - phase_start + 1,
		maxi(phase_end - phase_start + 1, 1),
	]
	phase_label.self_modulate = (
		Color(1.0, 0.88, 0.54, 1.0)
		if not is_night
		else Color(0.62, 0.78, 1.0, 1.0)
	)
	day_dial.set_day_progress(
		phase_index,
		day_cycle_config.waves_per_day,
		day_cycle_config.night_start_wave_in_day - 1,
		safe_resolved,
		safe_total
	)
	var progress_percent := (
		roundi(float(safe_resolved) / float(safe_total) * 100.0)
		if safe_total > 0
		else 0
	)
	wave_title_label.text = "第 %d 波" % safe_wave
	wave_value_label.text = "%d%%" % progress_percent
	wave_progress_bar.value = float(progress_percent)
	_show_global_wave_notice(safe_wave)


func show_tower_defense_wave_progress(
	wave_number: int,
	_defeated: int,
	_escaped: int,
	resolved: int,
	total: int
) -> void:
	_stop_result_tween()
	top_bar.visible = true
	result_overlay.visible = false
	tower_defense_stats.visible = true
	_hide_stage_banner()
	set_tower_defense_wave_progress(wave_number, resolved, total)
	_hide_start_wave_button()


func show_tower_defense_boss_progress(resolved: int = 0, total: int = 1) -> void:
	_stop_result_tween()
	top_bar.visible = true
	result_overlay.visible = false
	tower_defense_stats.visible = true
	_hide_stage_banner()
	set_tower_defense_wave_progress(maxi(_cached_wave_number, 1), resolved, total)
	wave_title_label.text = "首领战"
	_hide_start_wave_button()


func show_tower_defense_boss_day_preparation(
	day_number: int,
	seconds: int,
	allow_early_start: bool = false
) -> void:
	show_countdown(seconds, allow_early_start)
	_set_boss_day_context(day_number, 0, 1, true)


func show_tower_defense_boss_day_progress(
	day_number: int,
	resolved: int = 0,
	total: int = 1
) -> void:
	_stop_result_tween()
	top_bar.visible = true
	result_overlay.visible = false
	tower_defense_stats.visible = true
	_hide_stage_banner()
	_set_boss_day_context(day_number, resolved, total, false)
	_hide_start_wave_button()


func _set_boss_day_context(
	day_number: int,
	resolved: int,
	total: int,
	preparing: bool
) -> void:
	var safe_resolved := maxi(resolved, 0)
	var safe_total := maxi(total, 1)
	var progress_percent := clampi(
		roundi(float(safe_resolved) / float(safe_total) * 100.0),
		0,
		100
	)
	day_label.text = "第 %d 日" % maxi(day_number, 1)
	phase_label.text = "白昼"
	phase_label.self_modulate = Color(1.0, 0.88, 0.54, 1.0)
	day_dial.set_day_progress(0, 1, 1, safe_resolved, safe_total)
	wave_title_label.text = "首领战准备" if preparing else "首领战"
	wave_value_label.text = "--" if preparing else "%d%%" % progress_percent
	wave_progress_bar.value = 0.0 if preparing else float(progress_percent)
	_hide_global_wave_notice()


func show_countdown(seconds: int, allow_early_start: bool = false) -> void:
	_stop_result_tween()
	top_bar.visible = true
	result_overlay.visible = false
	var safe_seconds := maxi(seconds, 0)
	var countdown_text := _format_countdown(safe_seconds)
	start_wave_button.visible = allow_early_start
	start_wave_button.disabled = not allow_early_start or early_start_pending
	start_wave_button.text = (
		"等待开始……" if early_start_pending else "立即开始下一波"
	)
	tower_defense_stats.visible = true
	stage_banner.visible = true
	stage_label.text = "休整  ·  %s" % countdown_text
	stage_label.self_modulate = (
		STAGE_FINAL_COLOR
		if safe_seconds <= 3
		else Color(0.84, 0.91, 0.82, 1.0)
	)
	if safe_seconds <= 3:
		_pulse_stage_banner()
	else:
		_reset_stage_banner_pulse()


func show_victory() -> void:
	_hide_start_wave_button()
	_play_result_sequence(
		"通关",
		"源石虫的浪潮暂时退去了",
		Color(1.0, 0.9, 0.42, 1.0)
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
	_hide_global_wave_notice()
	result_overlay.visible = false
	_hide_start_wave_button()


func _show_global_wave_notice(wave_number: int) -> void:
	var safe_wave := maxi(wave_number, 1)
	global_wave_label.text = "全局第 %d 波" % safe_wave
	global_wave_notice.visible = true
	if safe_wave == _last_noticed_wave:
		return
	_last_noticed_wave = safe_wave
	if global_wave_tween != null:
		global_wave_tween.kill()
	global_wave_notice.modulate = Color(1.0, 1.0, 1.0, 0.0)
	global_wave_tween = create_tween()
	global_wave_tween.tween_property(
		global_wave_notice,
		"modulate",
		Color(1.0, 1.0, 1.0, 0.92),
		0.22
	).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)


func _on_start_wave_button_pressed() -> void:
	if start_wave_button.disabled or not start_wave_button.visible:
		return
	start_wave_button.disabled = true
	start_wave_button.text = "等待开始……"
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
	start_wave_button.text = "立即开始下一波"


func _format_countdown(seconds: int) -> String:
	var safe_seconds := maxi(seconds, 0)
	return "%02d:%02d" % [floori(float(safe_seconds) / 60.0), safe_seconds % 60]


func _play_result_sequence(
	title: String,
	subtitle: String,
	title_color: Color
) -> void:
	_stop_result_tween()
	top_bar.visible = false
	_hide_stage_banner()
	_hide_global_wave_notice()
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
	result_tween.tween_property(
		result_shade,
		"color",
		Color(0.0, 0.0, 0.0, 0.18),
		0.85
	).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	result_tween.tween_property(
		result_backdrop,
		"modulate",
		Color(1.0, 1.0, 1.0, 0.48),
		1.0
	).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	result_tween.tween_property(
		result_title,
		"modulate",
		title_color,
		0.34
	).set_delay(0.62).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	result_tween.tween_property(
		result_panel,
		"modulate",
		Color.WHITE,
		0.36
	).set_delay(1.02).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	result_tween.tween_property(
		result_subtitle,
		"modulate",
		Color(0.88, 0.95, 0.86, 0.94),
		0.26
	).set_delay(1.1).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	result_tween.tween_callback(_show_result_button).set_delay(1.45)


func _show_result_button() -> void:
	return_button.visible = true
	return_button.disabled = false
	return_button.modulate = Color(1.0, 1.0, 1.0, 0.0)
	var button_tween := create_tween()
	button_tween.tween_property(
		return_button,
		"modulate",
		Color.WHITE,
		0.26
	).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	return_button.grab_focus()


func _stop_result_tween() -> void:
	if result_tween != null:
		result_tween.kill()
		result_tween = null


func _pulse_core_stat() -> void:
	if core_pulse_tween != null:
		core_pulse_tween.kill()
	core_stat.self_modulate = CORE_HIT_FLASH_COLOR
	core_pulse_tween = create_tween()
	core_pulse_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	core_pulse_tween.tween_property(
		core_stat,
		"self_modulate",
		Color.WHITE,
		0.28
	)


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
	stage_pulse_tween.tween_property(
		stage_banner,
		"self_modulate",
		Color.WHITE,
		0.16
	)


func _reset_stage_banner_pulse() -> void:
	if stage_pulse_tween != null:
		stage_pulse_tween.kill()
		stage_pulse_tween = null
	stage_banner.self_modulate = Color.WHITE


func _hide_stage_banner() -> void:
	_reset_stage_banner_pulse()
	stage_banner.visible = false


func _hide_global_wave_notice() -> void:
	if global_wave_tween != null:
		global_wave_tween.kill()
		global_wave_tween = null
	global_wave_notice.visible = false
	global_wave_notice.modulate = Color(1.0, 1.0, 1.0, 0.92)
	_last_noticed_wave = -1
