extends CanvasLayer
class_name RogueRouteMoveConfirmation

signal confirmed
signal canceled

const OPEN_DURATION_SECONDS := 0.16
const MAP_SHADE_COLOR := Color(0.018, 0.014, 0.011, 0.72)
const PANEL_OPEN_SCALE := Vector2(0.94, 0.94)

@onready var map_shade: ColorRect = %MapShade
@onready var panel_stage: Control = %PanelStage
@onready var destination_label: Label = %DestinationLabel
@onready var current_ap_label: Label = %CurrentAPLabel
@onready var remaining_ap_label: Label = %RemainingAPLabel
@onready var cost_label: Label = %CostLabel
@onready var confirm_button: Button = %ConfirmButton
@onready var cancel_button: Button = %CancelButton
@onready var close_button: Button = %CloseButton

var _open_tween: Tween


func _ready() -> void:
	map_shade.gui_input.connect(_on_map_shade_gui_input)
	close_button.pressed.connect(_cancel)
	cancel_button.pressed.connect(_cancel)
	confirm_button.pressed.connect(_confirm)
	dismiss()


func present(
	destination_name: String,
	current_action_points: int,
	move_cost: int
) -> void:
	destination_label.text = destination_name
	current_ap_label.text = str(current_action_points)
	remaining_ap_label.text = str(maxi(0, current_action_points - move_cost))
	cost_label.text = "消耗 %d 行动力" % move_cost
	visible = true
	set_process_input(true)
	_play_open_animation()
	confirm_button.grab_focus()


func dismiss() -> void:
	if _open_tween != null and _open_tween.is_valid():
		_open_tween.kill()
	_open_tween = null
	visible = false
	set_process_input(false)
	if get_viewport().gui_get_focus_owner() in [confirm_button, cancel_button, close_button]:
		get_viewport().gui_release_focus()


func _input(event: InputEvent) -> void:
	if not visible:
		return
	if event.is_action_pressed(&"ui_cancel"):
		get_viewport().set_input_as_handled()
		_cancel()


func _play_open_animation() -> void:
	if _open_tween != null and _open_tween.is_valid():
		_open_tween.kill()
	map_shade.color = Color(MAP_SHADE_COLOR, 0.0)
	panel_stage.scale = PANEL_OPEN_SCALE
	panel_stage.modulate = Color(1.0, 1.0, 1.0, 0.0)
	_open_tween = create_tween().set_parallel(true)
	_open_tween.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	_open_tween.tween_property(
		map_shade,
		^"color",
		MAP_SHADE_COLOR,
		OPEN_DURATION_SECONDS
	)
	_open_tween.tween_property(
		panel_stage,
		^"scale",
		Vector2.ONE,
		OPEN_DURATION_SECONDS
	)
	_open_tween.tween_property(
		panel_stage,
		^"modulate",
		Color.WHITE,
		OPEN_DURATION_SECONDS * 0.8
	)


func _on_map_shade_gui_input(event: InputEvent) -> void:
	var mouse_event := event as InputEventMouseButton
	if mouse_event == null:
		return
	if mouse_event.button_index == MOUSE_BUTTON_LEFT and mouse_event.pressed:
		map_shade.accept_event()
		_cancel()


func _confirm() -> void:
	if not visible:
		return
	dismiss()
	confirmed.emit()


func _cancel() -> void:
	if not visible:
		return
	dismiss()
	canceled.emit()
