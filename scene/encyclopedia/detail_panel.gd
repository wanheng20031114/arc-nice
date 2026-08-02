extends PanelContainer
class_name EncyclopediaDetailPanel

signal close_requested

const PREVIEW_MAGNIFICATION := 3.0
const PREVIEW_MAX_SIZE := Vector2(124.0, 124.0)
const SPECIAL_TEXT_COLOR := Color("e7efed")

@onready var detail_content: VBoxContainer = $Margin/Content
@onready var section_label: Label = $Margin/Content/Header/SectionLabel
@onready var close_button: Button = $Margin/Content/Header/CloseButton
@onready var preview_frame: PanelContainer = $Margin/Content/PreviewFrame
@onready var icon_rect: TextureRect = $Margin/Content/PreviewFrame/PreviewCanvas/Icon
@onready var enemy_preview: AnimatedSprite2D = $Margin/Content/PreviewFrame/PreviewCanvas/EnemyPreview
@onready var details_scroll: ScrollContainer = $Margin/Content/DetailsScroll
@onready var primary_badge: Label = $Margin/Content/DetailsScroll/Body/Details/Badges/PrimaryBadge
@onready var secondary_badge: Label = $Margin/Content/DetailsScroll/Body/Details/Badges/SecondaryBadge
@onready var name_label: Label = $Margin/Content/DetailsScroll/Body/Details/Name
@onready var description_label: RichTextLabel = $Margin/Content/DetailsScroll/Body/Details/Description
@onready var stats_heading: Label = $Margin/Content/DetailsScroll/Body/Details/StatsHeading
@onready var stats_rows: VBoxContainer = $Margin/Content/DetailsScroll/Body/Details/StatsRows
@onready var notes_heading: Label = $Margin/Content/DetailsScroll/Body/Details/NotesHeading
@onready var notes_rows: VBoxContainer = $Margin/Content/DetailsScroll/Body/Details/NotesRows

var current_entry: CodexEntryViewData
var _content_tween: Tween
var _preview_magnification := PREVIEW_MAGNIFICATION


func _ready() -> void:
	close_button.pressed.connect(func() -> void: close_requested.emit())
	preview_frame.resized.connect(_position_enemy_preview)


func show_entry(entry: CodexEntryViewData) -> void:
	if (
		entry == null
		or entry.visibility_state != CodexVisibilityState.REVEALED
	):
		return
	var is_refresh := current_entry != null
	current_entry = entry
	section_label.text = "%s档案" % CodexSection.get_label(entry.section)
	name_label.text = entry.display_name
	description_label.text = entry.description
	primary_badge.text = entry.primary_badge
	primary_badge.visible = not entry.primary_badge.is_empty()
	secondary_badge.text = entry.secondary_badge
	secondary_badge.visible = not entry.secondary_badge.is_empty()
	_apply_accent(entry.accent_color)
	_populate_stats(entry.stats)
	_populate_notes(entry.notes)
	_apply_preview(entry)
	details_scroll.scroll_vertical = 0
	if is_refresh:
		_play_content_refresh()


func clear_entry() -> void:
	current_entry = null
	enemy_preview.stop()
	enemy_preview.sprite_frames = null
	icon_rect.texture = null


func get_close_button() -> Button:
	return close_button


func get_scroll_control() -> ScrollContainer:
	return details_scroll


func _apply_preview(entry: CodexEntryViewData) -> void:
	enemy_preview.stop()
	enemy_preview.sprite_frames = null
	enemy_preview.visible = false
	icon_rect.texture = null
	icon_rect.visible = false
	if (
		entry.section == CodexSection.ENEMY
		and entry.preview_frames != null
		and entry.preview_animation != &""
		and entry.preview_frames.has_animation(entry.preview_animation)
	):
		enemy_preview.sprite_frames = entry.preview_frames
		enemy_preview.animation = entry.preview_animation
		_preview_magnification = _calculate_preview_magnification(entry)
		enemy_preview.scale = entry.preview_scale * _preview_magnification
		enemy_preview.visible = true
		_position_enemy_preview()
		enemy_preview.play()
		return
	icon_rect.texture = entry.icon
	icon_rect.visible = entry.icon != null


func _position_enemy_preview() -> void:
	if current_entry == null:
		return
	enemy_preview.position = (
		preview_frame.size * 0.5
		+ current_entry.preview_offset * _preview_magnification
	)


func _calculate_preview_magnification(entry: CodexEntryViewData) -> float:
	var frame_texture := entry.preview_frames.get_frame_texture(
		entry.preview_animation,
		0
	)
	if frame_texture == null:
		return PREVIEW_MAGNIFICATION
	var displayed_size := Vector2(
		frame_texture.get_width() * absf(entry.preview_scale.x),
		frame_texture.get_height() * absf(entry.preview_scale.y)
	) * PREVIEW_MAGNIFICATION
	if displayed_size.x <= 0.0 or displayed_size.y <= 0.0:
		return PREVIEW_MAGNIFICATION
	var fit_factor := minf(
		1.0,
		minf(
			PREVIEW_MAX_SIZE.x / displayed_size.x,
			PREVIEW_MAX_SIZE.y / displayed_size.y
		)
	)
	return PREVIEW_MAGNIFICATION * fit_factor


func _populate_stats(rows: Array[CodexStatRow]) -> void:
	_clear_container(stats_rows)
	stats_heading.visible = not rows.is_empty()
	stats_rows.visible = not rows.is_empty()
	for stat in rows:
		var row := HBoxContainer.new()
		row.custom_minimum_size = Vector2(0.0, 27.0)
		row.add_theme_constant_override(&"separation", 12)
		var label := Label.new()
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		label.add_theme_color_override(&"font_color", Color(0.59, 0.64, 0.63))
		label.add_theme_font_size_override(&"font_size", 13)
		label.text = stat.label
		var value := Label.new()
		value.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		value.add_theme_color_override(&"font_color", Color(0.91, 0.9, 0.82))
		value.add_theme_font_size_override(&"font_size", 14)
		value.text = stat.value
		value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		row.add_child(label)
		row.add_child(value)
		stats_rows.add_child(row)


func _populate_notes(notes: PackedStringArray) -> void:
	_clear_container(notes_rows)
	notes_heading.visible = not notes.is_empty()
	notes_rows.visible = not notes.is_empty()
	for note in notes:
		var label := Label.new()
		label.add_theme_color_override(&"font_color", Color(0.75, 0.77, 0.72))
		label.add_theme_font_size_override(&"font_size", 13)
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		label.text = "·  %s" % note
		notes_rows.add_child(label)


func _clear_container(container: Container) -> void:
	for child in container.get_children():
		container.remove_child(child)
		child.queue_free()


func _apply_accent(accent: Color) -> void:
	var is_special := (
		current_entry != null and current_entry.primary_badge == "特殊"
	)
	section_label.add_theme_color_override(&"font_color", accent)
	name_label.add_theme_color_override(
		&"font_color",
		SPECIAL_TEXT_COLOR if is_special else accent.lightened(0.18)
	)
	stats_heading.add_theme_color_override(&"font_color", accent)
	notes_heading.add_theme_color_override(&"font_color", accent)
	_apply_badge_style(primary_badge, accent, 0.16)
	_apply_badge_style(secondary_badge, accent, 0.08)
	if is_special:
		primary_badge.add_theme_color_override(&"font_color", SPECIAL_TEXT_COLOR)


func _apply_badge_style(label: Label, accent: Color, alpha: float) -> void:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(accent.r, accent.g, accent.b, alpha)
	style.border_width_left = 1
	style.border_width_top = 1
	style.border_width_right = 1
	style.border_width_bottom = 1
	style.border_color = Color(accent.r, accent.g, accent.b, 0.3)
	style.corner_radius_top_left = 3
	style.corner_radius_top_right = 3
	style.corner_radius_bottom_left = 3
	style.corner_radius_bottom_right = 3
	label.add_theme_stylebox_override(&"normal", style)
	label.add_theme_color_override(&"font_color", accent.lightened(0.18))


func _play_content_refresh() -> void:
	if _content_tween != null:
		_content_tween.kill()
	detail_content.modulate = Color(1.0, 1.0, 1.0, 0.58)
	_content_tween = create_tween()
	_content_tween.tween_property(
		detail_content,
		"modulate",
		Color.WHITE,
		0.12
	).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	_content_tween.finished.connect(func() -> void: _content_tween = null)
