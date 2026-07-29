extends PanelContainer
class_name EncyclopediaEntryCard

signal entry_pressed(entry: CodexEntryViewData)
signal entry_focused(entry: CodexEntryViewData)

const REVEALED_BACKGROUND := Color(0.075, 0.09, 0.095, 0.96)
const UNKNOWN_BACKGROUND := Color(0.065, 0.07, 0.075, 0.96)
const RESTING_EDGE_ALPHA := 0.34
const ACTIVE_EDGE_ALPHA := 0.92

@onready var artwork_frame: PanelContainer = $Margin/Content/ArtworkFrame
@onready var icon_rect: TextureRect = $Margin/Content/ArtworkFrame/Icon
@onready var unknown_glyph: Label = $Margin/Content/ArtworkFrame/UnknownGlyph
@onready var name_label: Label = $Margin/Content/Name
@onready var badge_label: Label = $Margin/Content/Badge
@onready var select_button: Button = $SelectButton

var entry_data: CodexEntryViewData
var _is_hovered := false
var _is_focused := false


func _ready() -> void:
	select_button.pressed.connect(_on_pressed)
	select_button.focus_entered.connect(_on_focus_entered)
	select_button.focus_exited.connect(_on_focus_exited)
	select_button.mouse_entered.connect(_on_mouse_entered)
	select_button.mouse_exited.connect(_on_mouse_exited)


func setup(entry: CodexEntryViewData) -> void:
	entry_data = entry
	var is_unknown := entry.visibility_state == CodexVisibilityState.UNKNOWN
	icon_rect.texture = null if is_unknown else entry.icon
	icon_rect.visible = not is_unknown and entry.icon != null
	unknown_glyph.visible = is_unknown
	name_label.text = "未发现" if is_unknown else entry.display_name
	badge_label.text = "未知档案" if is_unknown else entry.primary_badge
	select_button.tooltip_text = (
		"尚未发现" if is_unknown else "查看%s详情" % entry.display_name
	)
	_apply_palette()


func get_focus_control() -> Button:
	return select_button


func set_focus_neighbours(
	left: Control,
	right: Control,
	up: Control,
	down: Control
) -> void:
	select_button.focus_neighbor_left = _focus_path_to(left)
	select_button.focus_neighbor_right = _focus_path_to(right)
	select_button.focus_neighbor_top = _focus_path_to(up)
	select_button.focus_neighbor_bottom = _focus_path_to(down)


func _on_pressed() -> void:
	if (
		entry_data == null
		or entry_data.visibility_state != CodexVisibilityState.REVEALED
	):
		return
	entry_pressed.emit(entry_data)


func _on_focus_entered() -> void:
	_is_focused = true
	_apply_palette()
	if entry_data != null:
		entry_focused.emit(entry_data)


func _on_focus_exited() -> void:
	_is_focused = false
	_apply_palette()


func _on_mouse_entered() -> void:
	_is_hovered = true
	_apply_palette()
	if entry_data != null:
		entry_focused.emit(entry_data)


func _on_mouse_exited() -> void:
	_is_hovered = false
	_apply_palette()


func _apply_palette() -> void:
	if entry_data == null:
		return
	var is_unknown := entry_data.visibility_state == CodexVisibilityState.UNKNOWN
	var accent := Color(0.45, 0.48, 0.49) if is_unknown else entry_data.accent_color
	var is_active := _is_hovered or _is_focused
	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color = UNKNOWN_BACKGROUND if is_unknown else REVEALED_BACKGROUND
	panel_style.border_width_left = 1
	panel_style.border_width_top = 1
	panel_style.border_width_right = 1
	panel_style.border_width_bottom = 1
	panel_style.border_color = Color(
		accent.r,
		accent.g,
		accent.b,
		ACTIVE_EDGE_ALPHA if is_active else RESTING_EDGE_ALPHA
	)
	panel_style.corner_radius_top_left = 5
	panel_style.corner_radius_top_right = 5
	panel_style.corner_radius_bottom_right = 5
	panel_style.corner_radius_bottom_left = 5
	panel_style.content_margin_left = 0.0
	panel_style.content_margin_top = 0.0
	panel_style.content_margin_right = 0.0
	panel_style.content_margin_bottom = 0.0
	add_theme_stylebox_override(&"panel", panel_style)

	var artwork_style := StyleBoxFlat.new()
	artwork_style.bg_color = Color(0.025, 0.035, 0.038, 0.86)
	artwork_style.border_width_bottom = 1
	artwork_style.border_color = Color(accent.r, accent.g, accent.b, 0.2)
	artwork_style.corner_radius_top_left = 3
	artwork_style.corner_radius_top_right = 3
	artwork_frame.add_theme_stylebox_override(&"panel", artwork_style)

	var badge_style := StyleBoxFlat.new()
	badge_style.bg_color = Color(accent.r, accent.g, accent.b, 0.13)
	badge_style.corner_radius_top_left = 2
	badge_style.corner_radius_top_right = 2
	badge_style.corner_radius_bottom_left = 2
	badge_style.corner_radius_bottom_right = 2
	badge_label.add_theme_stylebox_override(&"normal", badge_style)
	badge_label.add_theme_color_override(
		&"font_color",
		accent.lightened(0.18) if not is_unknown else Color(0.58, 0.6, 0.61)
	)
	name_label.add_theme_color_override(
		&"font_color",
		Color(0.94, 0.92, 0.84) if not is_unknown else Color(0.5, 0.52, 0.53)
	)
	unknown_glyph.add_theme_color_override(&"font_color", accent)


func _focus_path_to(control: Control) -> NodePath:
	if control == null or not is_instance_valid(control):
		return NodePath("")
	return select_button.get_path_to(control)
