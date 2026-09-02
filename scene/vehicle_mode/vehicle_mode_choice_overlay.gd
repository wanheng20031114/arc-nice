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
@onready var preset_buttons: Array[Button] = [
	$Root/Center/Panel/Margin/Content/Presets/Ocean,
	$Root/Center/Panel/Margin/Content/Presets/Flame,
	$Root/Center/Panel/Margin/Content/Presets/Sun,
	$Root/Center/Panel/Margin/Content/Presets/Leaf,
	$Root/Center/Panel/Margin/Content/Presets/Amethyst,
	$Root/Center/Panel/Margin/Content/Presets/Snow,
]
@onready var start_button: Button = $Root/Center/Panel/Margin/Content/Footer/StartButton
@onready var back_button: Button = $Root/Center/Panel/Margin/Content/Footer/BackButton

var selected_color := RunStateStore.DEFAULT_VEHICLE_PAINT_COLOR
var _syncing_color_picker := false


func _ready() -> void:
	_configure_color_picker()
	visible = false
	root_control.hide()
	set_process_unhandled_input(false)


func open(initial_color: Color) -> void:
	if is_open():
		return
	_set_selected_color(initial_color, _find_matching_preset(initial_color))
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
	if _syncing_color_picker:
		return
	_set_selected_color(color)


func _on_preset_pressed(index: int) -> void:
	if index < 0 or index >= PRESET_COLORS.size():
		return
	_set_selected_color(PRESET_COLORS[index], index)


func _on_start_pressed() -> void:
	if not is_open():
		return
	_hide_overlay()
	vehicle_confirmed.emit(selected_color)


func _hide_overlay() -> void:
	var picker_popup := color_picker_button.get_popup()
	if picker_popup.visible:
		picker_popup.hide()
	root_control.hide()
	visible = false
	set_process_unhandled_input(false)


func _configure_color_picker() -> void:
	color_picker_button.edit_alpha = false
	var picker := color_picker_button.get_picker()
	picker.picker_shape = ColorPicker.SHAPE_HSV_RECTANGLE
	picker.color_modes_visible = false
	picker.sliders_visible = false
	picker.sampler_visible = false
	picker.presets_visible = false
	picker.can_add_swatches = false
	picker.hex_visible = true
	picker.deferred_mode = false
	picker.edit_alpha = false
	picker.edit_intensity = false
	picker.add_theme_constant_override(&"sv_width", 210)
	picker.add_theme_constant_override(&"sv_height", 160)
	picker.add_theme_constant_override(&"h_width", 24)
	picker.add_theme_constant_override(&"margin", 6)

	var popup_style := StyleBoxFlat.new()
	popup_style.bg_color = Color(0.025, 0.055, 0.068, 1.0)
	popup_style.border_color = Color(0.12, 0.7, 0.88, 1.0)
	popup_style.set_border_width_all(2)
	popup_style.set_corner_radius_all(8)
	popup_style.content_margin_left = 12.0
	popup_style.content_margin_top = 12.0
	popup_style.content_margin_right = 12.0
	popup_style.content_margin_bottom = 12.0
	color_picker_button.get_popup().add_theme_stylebox_override(
		&"panel",
		popup_style
	)


func _set_selected_color(color: Color, preset_index: int = -1) -> void:
	selected_color = Color(
		clampf(color.r, 0.0, 1.0),
		clampf(color.g, 0.0, 1.0),
		clampf(color.b, 0.0, 1.0),
		1.0
	)
	if not color_picker_button.color.is_equal_approx(selected_color):
		_syncing_color_picker = true
		color_picker_button.color = selected_color
		_syncing_color_picker = false
	_set_active_preset(preset_index)
	var preview_material := preview.material as ShaderMaterial
	if preview_material != null:
		preview_material.set_shader_parameter(
			PAINT_COLOR_SHADER_PARAMETER,
			selected_color
		)


func _set_active_preset(preset_index: int) -> void:
	for button_index in preset_buttons.size():
		preset_buttons[button_index].set_pressed_no_signal(
			button_index == preset_index
		)


func _find_matching_preset(color: Color) -> int:
	var resolved_color := Color(
		clampf(color.r, 0.0, 1.0),
		clampf(color.g, 0.0, 1.0),
		clampf(color.b, 0.0, 1.0),
		1.0
	)
	for preset_index in PRESET_COLORS.size():
		if PRESET_COLORS[preset_index].is_equal_approx(resolved_color):
			return preset_index
	return -1
