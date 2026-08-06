extends PanelContainer
class_name PlantSelectionCard

signal plant_selected(config: PlantDefenseConfig)
signal plant_confirmed(config: PlantDefenseConfig)

const SELECTION_FEEDBACK_SECONDS := 0.12

@onready var icon_rect: TextureRect = $Margin/Content/Top/IconFrame/Icon
@onready var name_label: Label = $Margin/Content/Top/Summary/Name
@onready var owned_label: Label = $Margin/Content/Top/Summary/Owned
@onready var surface_label: Label = $Margin/Content/Top/Summary/Surface
@onready var stats_label: Label = $Margin/Content/Stats
@onready var select_button: Button = $Margin/Content/SelectButton

var plant_config: PlantDefenseConfig = null
var owned_count := 0
var free_placement_mode := false
var selected := false
var hovered := false
var _selection_tween: Tween = null


func _ready() -> void:
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	mouse_entered.connect(_on_mouse_entered)
	mouse_exited.connect(_on_mouse_exited)
	focus_entered.connect(_emit_selected)
	gui_input.connect(_on_gui_input)
	select_button.gui_input.connect(_on_gui_input)
	_refresh_style()


func setup(
	config: PlantDefenseConfig,
	new_owned_count: int = 0,
	allow_free_placement: bool = false,
	is_selected: bool = false
) -> void:
	plant_config = config
	if plant_config == null:
		return
	icon_rect.texture = plant_config.icon
	name_label.text = plant_config.display_name
	tooltip_text = plant_config.description
	stats_label.text = _build_stats_text()
	surface_label.text = PlantDefenseConfig.get_placement_surface_label(
		plant_config.placement_surface
	)
	update_availability(new_owned_count, allow_free_placement)
	set_selected(is_selected)


func update_availability(
	new_owned_count: int,
	allow_free_placement: bool
) -> void:
	owned_count = maxi(new_owned_count, 0)
	free_placement_mode = allow_free_placement
	owned_label.text = (
		"沙盒免费"
		if free_placement_mode
		else "持有 ×%d" % owned_count
	)
	select_button.disabled = not can_confirm()
	select_button.text = (
		"选择（免费）"
		if free_placement_mode
		else "选择（%d）" % owned_count
	)
	_refresh_style()


func can_confirm() -> bool:
	return plant_config != null and (free_placement_mode or owned_count > 0)


func set_selected(value: bool) -> void:
	var changed := selected != value
	selected = value
	_refresh_style()
	if changed and selected and is_inside_tree():
		_play_selection_feedback()


func _build_stats_text() -> String:
	var parts: PackedStringArray = ["生命 %d" % plant_config.max_health]
	if plant_config.attack_damage > 0:
		if plant_config.attack_burst_count > 1:
			parts.append(
				"伤害 %s×%d"
				% [
					_format_number(plant_config.attack_damage),
					plant_config.attack_burst_count,
				]
			)
		else:
			parts.append("伤害 %s" % _format_number(plant_config.attack_damage))
		var attack_interval := plant_config.get_attack_interval()
		if attack_interval > 0.0:
			parts.append(
				"%s %s 秒"
				% [
					"轮间隔" if plant_config.attack_burst_count > 1 else "间隔",
					_format_number(attack_interval),
				]
			)
	if plant_config.attack_range > 0.0:
		parts.append("半径 %s" % _format_number(plant_config.attack_range))
	return "  ·  ".join(parts)


func _format_number(value: float) -> String:
	if is_equal_approx(value, roundf(value)):
		return str(roundi(value))
	return ("%.2f" % value).trim_suffix("0")


func _refresh_style() -> void:
	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color = (
		Color(0.035, 0.07, 0.052, 0.98)
		if can_confirm()
		else Color(0.025, 0.036, 0.03, 0.96)
	)
	panel_style.border_color = (
		Color(0.68, 1.0, 0.58, 1.0)
		if selected
		else Color(0.42, 0.72, 0.42, 0.95)
		if hovered
		else Color(0.22, 0.4, 0.26, 0.82)
	)
	var border_width := 3 if selected else 2
	panel_style.border_width_left = border_width
	panel_style.border_width_top = border_width
	panel_style.border_width_right = border_width
	panel_style.border_width_bottom = border_width
	panel_style.corner_radius_top_left = 8
	panel_style.corner_radius_top_right = 8
	panel_style.corner_radius_bottom_right = 8
	panel_style.corner_radius_bottom_left = 8
	panel_style.shadow_color = Color(0.16, 0.62, 0.25, 0.22 if hovered else 0.1)
	panel_style.shadow_size = 7 if hovered else 4
	panel_style.shadow_offset = Vector2(0.0, 2.0)
	add_theme_stylebox_override(&"panel", panel_style)
	modulate = Color.WHITE if can_confirm() or selected else Color(0.68, 0.72, 0.68, 1.0)


func _play_selection_feedback() -> void:
	if _selection_tween != null and _selection_tween.is_valid():
		_selection_tween.kill()
	modulate = Color(0.78, 1.0, 0.76, 1.0)
	_selection_tween = create_tween()
	_selection_tween.tween_property(
		self,
		"modulate",
		Color.WHITE if can_confirm() else Color(0.78, 0.84, 0.78, 1.0),
		SELECTION_FEEDBACK_SECONDS
	)


func _on_mouse_entered() -> void:
	hovered = true
	_refresh_style()


func _on_mouse_exited() -> void:
	hovered = false
	_refresh_style()


func _on_gui_input(event: InputEvent) -> void:
	var mouse_event := event as InputEventMouseButton
	if (
		mouse_event == null
		or mouse_event.button_index != MOUSE_BUTTON_LEFT
		or not mouse_event.pressed
	):
		return
	accept_event()
	_emit_selected()
	if mouse_event.double_click and can_confirm():
		plant_confirmed.emit(plant_config)


func _emit_selected() -> void:
	if plant_config != null:
		plant_selected.emit(plant_config)


func _exit_tree() -> void:
	if _selection_tween != null and _selection_tween.is_valid():
		_selection_tween.kill()
