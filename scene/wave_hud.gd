extends CanvasLayer
class_name WaveHUD

@onready var top_bar: PanelContainer = $TopCenter/TopBar
@onready var status_label: Label = $TopCenter/TopBar/Margin/Status
@onready var result_overlay: Control = $ResultOverlay
@onready var result_label: Label = $ResultOverlay/Result

var pulse_tween: Tween = null


func show_wave_progress(wave_number: int, defeated: int, total: int) -> void:
	top_bar.visible = true
	result_overlay.visible = false
	status_label.modulate = Color.WHITE
	status_label.text = "第 %d 波  已消灭 %d/%d" % [
		wave_number,
		defeated,
		total,
	]


func show_countdown(seconds: int) -> void:
	top_bar.visible = true
	result_overlay.visible = false
	status_label.text = "下一波将在 %d 秒后开始" % maxi(seconds, 0)
	status_label.modulate = (
		Color(1.0, 0.86, 0.42, 1.0)
		if seconds <= 5
		else Color.WHITE
	)
	if seconds <= 5:
		_pulse_top_bar()


func show_victory() -> void:
	top_bar.visible = false
	result_overlay.visible = true
	result_label.text = "通关"
	result_label.modulate = Color(1.0, 0.9, 0.42, 1.0)


func show_defeat() -> void:
	top_bar.visible = false
	result_overlay.visible = true
	result_label.text = "战败"
	result_label.modulate = Color(1.0, 0.38, 0.3, 1.0)


func hide_all() -> void:
	top_bar.visible = false
	result_overlay.visible = false


func _pulse_top_bar() -> void:
	if pulse_tween != null:
		pulse_tween.kill()
	top_bar.pivot_offset = top_bar.size * 0.5
	top_bar.scale = Vector2.ONE
	pulse_tween = create_tween()
	pulse_tween.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	pulse_tween.tween_property(top_bar, "scale", Vector2(1.06, 1.06), 0.08)
	pulse_tween.tween_property(top_bar, "scale", Vector2.ONE, 0.12)

