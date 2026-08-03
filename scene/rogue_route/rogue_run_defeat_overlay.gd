extends CanvasLayer
class_name RogueRunDefeatOverlay

signal confirmed

const TITLE_TEXT := "战败"
const REASON_TEXT := "核心生命值归0，游戏结束"

@onready var root: Control = %Root
@onready var panel: PanelContainer = %Panel
@onready var title_label: Label = %Title
@onready var reason_label: Label = %Reason
@onready var confirm_button: Button = %ConfirmButton

var _open_tween: Tween = null


func _ready() -> void:
	confirm_button.pressed.connect(_on_confirm_button_pressed)
	set_process_unhandled_input(false)


func show_defeat(multiplayer_mode: bool) -> void:
	title_label.text = TITLE_TEXT
	reason_label.text = REASON_TEXT
	confirm_button.text = "返回多人大厅" if multiplayer_mode else "返回主菜单"
	show()
	set_process_unhandled_input(true)
	_play_open_animation()
	call_deferred(&"_focus_confirm_button")


func hide_immediately() -> void:
	_stop_open_tween()
	set_process_unhandled_input(false)
	root.modulate = Color.WHITE
	panel.scale = Vector2.ONE
	confirm_button.release_focus()
	hide()


func _play_open_animation() -> void:
	_stop_open_tween()
	panel.pivot_offset = panel.size * 0.5
	root.modulate = Color(1.0, 1.0, 1.0, 0.0)
	panel.scale = Vector2(0.94, 0.94)
	_open_tween = create_tween()
	_open_tween.set_parallel(true)
	_open_tween.tween_property(root, "modulate:a", 1.0, 0.24).set_trans(
		Tween.TRANS_QUAD
	).set_ease(Tween.EASE_OUT)
	_open_tween.tween_property(panel, "scale", Vector2.ONE, 0.24).set_trans(
		Tween.TRANS_BACK
	).set_ease(Tween.EASE_OUT)
	_open_tween.finished.connect(_on_open_tween_finished)


func _stop_open_tween() -> void:
	if _open_tween == null:
		return
	_open_tween.kill()
	_open_tween = null


func _on_open_tween_finished() -> void:
	_open_tween = null
	root.modulate = Color.WHITE
	panel.scale = Vector2.ONE


func _focus_confirm_button() -> void:
	if not visible:
		return
	panel.pivot_offset = panel.size * 0.5
	confirm_button.grab_focus()


func _on_confirm_button_pressed() -> void:
	if not visible:
		return
	hide_immediately()
	confirmed.emit()


func _unhandled_input(event: InputEvent) -> void:
	if not visible or not event.is_action_pressed(&"ui_accept"):
		return
	get_viewport().set_input_as_handled()
	_on_confirm_button_pressed()
