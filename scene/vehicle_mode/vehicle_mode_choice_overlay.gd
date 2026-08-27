extends CanvasLayer
class_name VehicleModeChoiceOverlay

signal vehicle_confirmed(paint_color: Color)
signal selection_closed

const PRESET_COLORS: Array[Color] = [
	Color("16afe8"),
	Color("ec584d"),
	Color("f0c843"),
	Color("58bd70"),
	Color("a36be2"),
	Color("e8eef2"),
]
const PAINT_COLOR_SHADER_PARAMETER := &"paint_color"

@onready var root_control: Control = $Root
@onready var preview: TextureRect = $Root/Center/Panel/Margin/Content/PreviewFrame/PreviewCenter/Preview
@onready var color_picker_button: ColorPickerButton = $Root/Center/Panel/Margin/Content/CustomColor/ColorPickerButton
@onready var start_button: Button = $Root/Center/Panel/Margin/Content/Footer/StartButton
@onready var back_button: Button = $Root/Center/Panel/Margin/Content/Footer/BackButton

var selected_color := RunStateStore.DEFAULT_VEHICLE_PAINT_COLOR


func _ready() -> void:
	visible = false
	root_control.hide()
	set_process_unhandled_input(false)


func open(initial_color: Color) -> void:
	if is_open():
		return
	_set_selected_color(initial_color)
	visible = true
	root_control.show()
	set_process_unhandled_input(true)
	start_button.call_deferred("grab_focus")


func close() -> void:
	if not is_open():
		return
	_hide_overlay()
	selection_closed.emit()


func is_open() -> bool:
	return visible and root_control.visible


func _unhandled_input(event: InputEvent) -> void:
	if not is_open():
		return
	if event.is_action_pressed(&"quit"):
		close()
		get_viewport().set_input_as_handled()


func _on_color_changed(color: Color) -> void:
	_set_selected_color(color)


func _on_preset_pressed(index: int) -> void:
	if index < 0 or index >= PRESET_COLORS.size():
		return
	_set_selected_color(PRESET_COLORS[index])


func _on_start_pressed() -> void:
	if not is_open():
		return
	_hide_overlay()
	vehicle_confirmed.emit(selected_color)


func _hide_overlay() -> void:
	root_control.hide()
	visible = false
	set_process_unhandled_input(false)


func _set_selected_color(color: Color) -> void:
	selected_color = Color(
		clampf(color.r, 0.0, 1.0),
		clampf(color.g, 0.0, 1.0),
		clampf(color.b, 0.0, 1.0),
		1.0
	)
	if not color_picker_button.color.is_equal_approx(selected_color):
		color_picker_button.color = selected_color
	var preview_material := preview.material as ShaderMaterial
	if preview_material != null:
		preview_material.set_shader_parameter(
			PAINT_COLOR_SHADER_PARAMETER,
			selected_color
		)
