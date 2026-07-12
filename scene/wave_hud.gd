extends CanvasLayer
class_name WaveHUD

signal return_to_lobby_requested

@onready var top_bar: PanelContainer = $WaveInfoBar
@onready var status_label: Label = $WaveInfoBar/Margin/Status
@onready var result_overlay: Control = $ResultOverlay
@onready var result_backdrop: TextureRect = $ResultOverlay/Backdrop
@onready var result_shade: ColorRect = $ResultOverlay/Shade
@onready var result_panel: PanelContainer = $ResultOverlay/Center/Panel
@onready var result_title: Label = $ResultOverlay/Center/Panel/Margin/Content/ResultTitle
@onready var result_subtitle: Label = $ResultOverlay/Center/Panel/Margin/Content/ResultSubtitle
@onready var return_button: Button = $ResultOverlay/Center/Panel/Margin/Content/ReturnButton

var pulse_tween: Tween = null
var result_tween: Tween = null
var return_button_label: String = "返回大厅"


func _ready() -> void:
	return_button.pressed.connect(return_to_lobby_requested.emit)


func set_return_button_text(button_text: String) -> void:
	return_button_label = button_text
	if return_button != null:
		return_button.text = return_button_label

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


func show_enemy_count(wave_number: int, alive_count: int) -> void:
	_stop_result_tween()
	top_bar.visible = true
	result_overlay.visible = false
	status_label.modulate = Color.WHITE
	status_label.text = "第 %d 波  场上敌人 %d" % [wave_number, maxi(alive_count, 0)]


func show_countdown(seconds: int) -> void:
	_stop_result_tween()
	top_bar.visible = true
	result_overlay.visible = false
	status_label.text = "下一波将在 %d 秒后开始" % maxi(seconds, 0)
	status_label.modulate = (
		Color(1.0, 0.86, 0.42, 1.0)
		if seconds <= 3
		else Color.WHITE
	)
	if seconds <= 3:
		_pulse_top_bar()


func show_victory() -> void:
	_play_result_sequence(
		"通关",
		"源石虫的浪潮暂时退去了",
		Color(1.0, 0.9, 0.42, 1.0)
	)


func show_defeat() -> void:
	_play_result_sequence(
		"战败",
		"全员已经倒下，回到大厅重新整备。",
		Color(1.0, 0.38, 0.3, 1.0)
	)


func hide_all() -> void:
	_stop_result_tween()
	top_bar.visible = false
	result_overlay.visible = false


func _play_result_sequence(title: String, subtitle: String, title_color: Color) -> void:
	_stop_result_tween()
	top_bar.visible = false
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
