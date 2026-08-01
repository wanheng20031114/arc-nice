extends Control
class_name RogueRouteCell

signal node_pressed(node_id: int)

const INVALID_NODE_ID := -1

@onready var current_halo: Panel = $CurrentHalo
@onready var selected_halo: Panel = $SelectedHalo
@onready var node_button: Button = $NodeButton
@onready var icon_rect: TextureRect = $NodeButton/Icon
@onready var empty_glyph: Label = $NodeButton/EmptyGlyph
@onready var visited_mark: Panel = $VisitedMark
@onready var name_label: Label = $NameLabel

var node_id: int = INVALID_NODE_ID
var display_name := ""
var is_empty := false
var _icon: Texture2D

var _authority_enabled := true
var _click_enabled := true
var _is_near := false
var _is_hovered := false
var _is_focused := false
var _is_selected := false
var _is_current := false
var _is_visited := false


func _ready() -> void:
	_apply_content()
	_update_interaction_state()
	_update_visual_state()


func setup(
	initial_node_id: int,
	node_display_name: String,
	icon: Texture2D,
	node_is_empty: bool
) -> void:
	node_id = initial_node_id
	display_name = node_display_name
	is_empty = node_is_empty
	_icon = icon
	if not is_node_ready():
		return
	_apply_content()
	_update_visual_state()


func set_authority_enabled(enabled: bool) -> void:
	if _authority_enabled == enabled:
		return
	_authority_enabled = enabled
	if is_node_ready():
		_update_interaction_state()


func set_click_enabled(enabled: bool) -> void:
	if _click_enabled == enabled:
		return
	_click_enabled = enabled
	if is_node_ready():
		_update_interaction_state()


func set_near(enabled: bool) -> void:
	if _is_near == enabled:
		return
	_is_near = enabled
	if is_node_ready():
		_update_name_visibility()


func set_selected(enabled: bool) -> void:
	if _is_selected == enabled:
		return
	_is_selected = enabled
	if is_node_ready():
		_update_visual_state()


func set_current(enabled: bool) -> void:
	if _is_current == enabled:
		return
	_is_current = enabled
	if is_node_ready():
		_update_visual_state()


func set_visited(enabled: bool) -> void:
	if _is_visited == enabled:
		return
	_is_visited = enabled
	if is_node_ready():
		_update_visual_state()


func is_interaction_enabled() -> bool:
	return _authority_enabled and _click_enabled


func get_focus_control() -> Button:
	return node_button


func get_connection_anchor() -> Vector2:
	if not is_node_ready():
		return Vector2(32.0, 28.0)
	return node_button.position + node_button.size * 0.5


func _on_node_button_pressed() -> void:
	if node_id == INVALID_NODE_ID or not is_interaction_enabled():
		return
	node_pressed.emit(node_id)


func _on_node_button_mouse_entered() -> void:
	_is_hovered = true
	_update_visual_state()


func _on_node_button_mouse_exited() -> void:
	_is_hovered = false
	_update_visual_state()


func _on_node_button_focus_entered() -> void:
	_is_focused = true
	_update_visual_state()


func _on_node_button_focus_exited() -> void:
	_is_focused = false
	_update_visual_state()


func _update_interaction_state() -> void:
	var enabled := is_interaction_enabled()
	node_button.disabled = not enabled
	node_button.focus_mode = Control.FOCUS_ALL if enabled else Control.FOCUS_NONE
	node_button.mouse_default_cursor_shape = (
		Control.CURSOR_POINTING_HAND if enabled else Control.CURSOR_ARROW
	)
	_update_visual_state()


func _apply_content() -> void:
	name_label.text = display_name
	icon_rect.texture = _icon
	node_button.tooltip_text = display_name


func _update_visual_state() -> void:
	current_halo.visible = _is_current
	selected_halo.visible = _is_selected
	visited_mark.visible = _is_visited and not _is_current

	var content_modulate := Color.WHITE
	if not is_interaction_enabled():
		content_modulate = Color(0.64, 0.68, 0.7, 0.88)
	elif _is_visited and not _is_current:
		content_modulate = Color(0.76, 0.84, 0.82, 0.92)
	if _is_hovered or _is_focused or _is_selected or _is_current:
		content_modulate = content_modulate.lightened(0.12)
	icon_rect.modulate = content_modulate
	empty_glyph.modulate = content_modulate

	icon_rect.visible = not is_empty and icon_rect.texture != null
	empty_glyph.visible = is_empty or icon_rect.texture == null
	if _is_selected:
		name_label.add_theme_color_override(&"font_color", Color("ffe28a"))
	elif _is_current:
		name_label.add_theme_color_override(&"font_color", Color("8df2ff"))
	elif _is_visited:
		name_label.add_theme_color_override(&"font_color", Color("b7d4cc"))
	else:
		name_label.add_theme_color_override(&"font_color", Color("edf4f2"))
	_update_name_visibility()


func _update_name_visibility() -> void:
	name_label.visible = (
		not display_name.is_empty()
		and (
			_is_near
			or _is_hovered
			or _is_focused
			or _is_selected
			or _is_current
		)
	)
