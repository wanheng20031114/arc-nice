extends PanelContainer
class_name PlayerCharacterCard

signal character_selected(character_id: StringName)
signal character_focused(character_id: StringName)

const HOVER_SCALE := Vector2(1.025, 1.025)
const HOVER_DURATION := 0.12

@onready var portrait: TextureRect = $Margin/Content/PortraitFrame/Portrait
@onready var portrait_placeholder: Label = $Margin/Content/PortraitFrame/PortraitPlaceholder
@onready var title_label: Label = $Margin/Content/Title
@onready var name_label: Label = $Margin/Content/Name
@onready var description_label: RichTextLabel = $Margin/Content/Description
@onready var stats_label: Label = $Margin/Content/Stats
@onready var playstyle_label: Label = $Margin/Content/Playstyle
@onready var select_button: Button = $Margin/Content/SelectButton

var character_config: PlayerCharacterConfig
var is_selected := false
var is_hovered := false
var hover_tween: Tween


func _ready() -> void:
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	mouse_entered.connect(_on_mouse_entered)
	mouse_exited.connect(_on_mouse_exited)
	gui_input.connect(_on_gui_input)
	select_button.pressed.connect(_emit_character_selected)
	resized.connect(_update_pivot)
	_update_pivot()


func setup(config: PlayerCharacterConfig, selected: bool = false) -> void:
	character_config = config
	if character_config == null:
		return

	title_label.text = character_config.title
	name_label.text = character_config.display_name
	description_label.text = character_config.description
	stats_label.text = "生命 %d  ·  攻击 %d  ·  攻速 %s" % [
		character_config.starting_max_health,
		character_config.starting_attack_damage,
		_format_attack_speed(character_config.starting_attack_speed),
	]
	playstyle_label.text = character_config.playstyle
	_apply_portrait()
	_apply_button_styles()
	set_selected(selected)


func set_selected(selected: bool) -> void:
	is_selected = selected
	select_button.text = "已选定" if is_selected else "选择角色"
	_refresh_card_style()


func play_confirmation() -> Tween:
	if hover_tween != null:
		hover_tween.kill()
		hover_tween = null
	var tween := create_tween()
	tween.tween_property(self, "scale", Vector2(1.055, 1.055), 0.09).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	tween.tween_property(self, "scale", Vector2.ONE, 0.12).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	return tween


func _apply_portrait() -> void:
	portrait.texture = null
	portrait_placeholder.visible = true
	portrait_placeholder.text = character_config.display_name.left(1)
	portrait_placeholder.modulate = character_config.card_accent_color
	if character_config.portrait_texture.is_empty():
		return
	if not ResourceLoader.exists(character_config.portrait_texture, "Texture2D"):
		return
	portrait.texture = load(character_config.portrait_texture) as Texture2D
	portrait_placeholder.visible = portrait.texture == null


func _apply_button_styles() -> void:
	var normal_style := _make_button_style(character_config.card_button_color)
	var hover_color := character_config.card_button_color.lightened(0.16)
	var hover_style := _make_button_style(hover_color)
	select_button.add_theme_stylebox_override(&"normal", normal_style)
	select_button.add_theme_stylebox_override(&"hover", hover_style)
	select_button.add_theme_stylebox_override(&"pressed", hover_style)
	select_button.add_theme_color_override(&"font_color", character_config.card_text_color)
	select_button.add_theme_color_override(&"font_hover_color", character_config.card_text_color)
	select_button.add_theme_color_override(&"font_pressed_color", character_config.card_text_color)


func _make_button_style(background_color: Color) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = background_color
	style.corner_radius_top_left = 5
	style.corner_radius_top_right = 5
	style.corner_radius_bottom_right = 5
	style.corner_radius_bottom_left = 5
	style.content_margin_top = 8.0
	style.content_margin_bottom = 8.0
	return style


func _refresh_card_style() -> void:
	if character_config == null:
		return
	var edge_color := (
		character_config.card_hover_edge_color
		if is_hovered or is_selected
		else character_config.card_edge_color
	)
	var style := StyleBoxFlat.new()
	style.bg_color = character_config.card_background_color
	style.border_width_left = 4 if is_selected else 2
	style.border_width_top = 4 if is_selected else 2
	style.border_width_right = 4 if is_selected else 2
	style.border_width_bottom = 4 if is_selected else 2
	style.border_color = edge_color
	style.corner_radius_top_left = 10
	style.corner_radius_top_right = 10
	style.corner_radius_bottom_right = 10
	style.corner_radius_bottom_left = 10
	style.shadow_color = Color(edge_color.r, edge_color.g, edge_color.b, 0.24 if is_hovered else 0.14)
	style.shadow_size = 13 if is_hovered else 8
	style.shadow_offset = Vector2(0.0, 3.0)
	add_theme_stylebox_override(&"panel", style)

	title_label.add_theme_color_override(&"font_color", character_config.card_accent_color)
	name_label.add_theme_color_override(&"font_color", character_config.card_text_color)
	description_label.add_theme_color_override(&"default_color", character_config.card_text_color.darkened(0.12))
	stats_label.add_theme_color_override(&"font_color", character_config.card_text_color)
	playstyle_label.add_theme_color_override(&"font_color", character_config.card_accent_color)


func _on_mouse_entered() -> void:
	if character_config == null:
		return
	is_hovered = true
	_refresh_card_style()
	character_focused.emit(character_config.character_id)
	_tween_scale(HOVER_SCALE)


func _on_mouse_exited() -> void:
	if character_config == null:
		return
	is_hovered = false
	_refresh_card_style()
	_tween_scale(Vector2.ONE)


func _on_gui_input(event: InputEvent) -> void:
	var mouse_event := event as InputEventMouseButton
	if mouse_event != null and mouse_event.button_index == MOUSE_BUTTON_LEFT and mouse_event.pressed:
		accept_event()
		_emit_character_selected()
		return
	if event.is_action_pressed(&"ui_accept"):
		accept_event()
		_emit_character_selected()


func _emit_character_selected() -> void:
	if character_config == null:
		return
	character_selected.emit(character_config.character_id)


func _tween_scale(target_scale: Vector2) -> void:
	if hover_tween != null:
		hover_tween.kill()
	hover_tween = create_tween()
	hover_tween.tween_property(self, "scale", target_scale, HOVER_DURATION).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	hover_tween.finished.connect(func() -> void:
		hover_tween = null
	)


func _update_pivot() -> void:
	pivot_offset = size * 0.5


func _format_attack_speed(value: float) -> String:
	if is_equal_approx(value, roundf(value)):
		return str(roundi(value))
	return "%.2f" % value
