extends PanelContainer
class_name PlantSelectionCard

signal plant_selected(config: PlantDefenseConfig)

@onready var icon_rect: TextureRect = $Margin/Content/IconFrame/Icon
@onready var name_label: Label = $Margin/Content/Name
@onready var description_label: RichTextLabel = $Margin/Content/Description
@onready var stats_label: Label = $Margin/Content/Stats
@onready var select_button: Button = $Margin/Content/SelectButton

var plant_config: PlantDefenseConfig
var selected := false
var hovered := false


func _ready() -> void:
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	mouse_entered.connect(_on_mouse_entered)
	mouse_exited.connect(_on_mouse_exited)
	gui_input.connect(_on_gui_input)
	select_button.pressed.connect(_emit_selected)
	_refresh_style()


func setup(config: PlantDefenseConfig, is_selected: bool = false) -> void:
	plant_config = config
	if plant_config == null:
		return
	icon_rect.texture = plant_config.icon
	name_label.text = plant_config.display_name
	description_label.text = plant_config.description
	stats_label.text = _build_stats_text()
	set_selected(is_selected)


func set_selected(value: bool) -> void:
	selected = value
	select_button.text = "已选定" if selected else "选择植物"
	_refresh_style()


func _build_stats_text() -> String:
	var parts: PackedStringArray = ["生命 %d" % plant_config.max_health]
	if plant_config.attack_damage > 0.0:
		parts.append("伤害 %s" % _format_number(plant_config.attack_damage))
		parts.append("间隔 %s 秒" % _format_number(plant_config.get_attack_interval()))
	if plant_config.attack_range > 0.0:
		parts.append("半径 %s" % _format_number(plant_config.attack_range))
	return "  ·  ".join(parts)


func _format_number(value: float) -> String:
	if is_equal_approx(value, roundf(value)):
		return str(roundi(value))
	return "%.2f" % value


func _refresh_style() -> void:
	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color = Color(0.035, 0.07, 0.052, 0.98)
	panel_style.border_color = (
		Color(0.68, 1.0, 0.58, 1.0)
		if selected or hovered
		else Color(0.28, 0.52, 0.32, 0.9)
	)
	var border_width := 3 if selected else 2
	panel_style.border_width_left = border_width
	panel_style.border_width_top = border_width
	panel_style.border_width_right = border_width
	panel_style.border_width_bottom = border_width
	panel_style.content_margin_left = 0.0
	panel_style.content_margin_top = 0.0
	panel_style.content_margin_right = 0.0
	panel_style.content_margin_bottom = 0.0
	panel_style.corner_radius_top_left = 9
	panel_style.corner_radius_top_right = 9
	panel_style.corner_radius_bottom_right = 9
	panel_style.corner_radius_bottom_left = 9
	panel_style.shadow_color = Color(0.16, 0.62, 0.25, 0.28 if hovered else 0.14)
	panel_style.shadow_size = 10 if hovered else 6
	panel_style.shadow_offset = Vector2(0.0, 3.0)
	add_theme_stylebox_override(&"panel", panel_style)


func _on_mouse_entered() -> void:
	hovered = true
	_refresh_style()


func _on_mouse_exited() -> void:
	hovered = false
	_refresh_style()


func _on_gui_input(event: InputEvent) -> void:
	var mouse_event := event as InputEventMouseButton
	if mouse_event != null and mouse_event.button_index == MOUSE_BUTTON_LEFT and mouse_event.pressed:
		accept_event()
		_emit_selected()


func _emit_selected() -> void:
	if plant_config != null:
		plant_selected.emit(plant_config)
