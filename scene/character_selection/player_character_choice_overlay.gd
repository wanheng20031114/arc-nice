extends CanvasLayer
class_name PlayerCharacterChoiceOverlay

signal character_confirmed(character_id: StringName)
signal selection_closed

const CHARACTER_CARD_SCENE := preload(
	"res://scene/character_selection/player_character_card.tscn"
)
const CONFIRMATION_LOCK_DURATION := 0.3
const CARD_OPEN_STAGGER := 0.09

@onready var root_control: Control = $Root
@onready var dim: ColorRect = $Root/Dim
@onready var heading: VBoxContainer = $Root/Center/Content/Heading
@onready var card_row: HBoxContainer = $Root/Center/Content/CardRow
@onready var confirm_button: Button = $Root/Center/Content/Footer/ConfirmButton
@onready var back_button: Button = $Root/Center/Content/Footer/BackButton

var cards: Array[PlayerCharacterCard] = []
var selected_character_id: StringName = PlayerCharacterRegistry.DEFAULT_CHARACTER_ID
var confirmation_lock_time_left := 0.0
var confirmation_in_progress := false
var open_tween: Tween


func _ready() -> void:
	visible = false
	root_control.hide()
	confirm_button.pressed.connect(_confirm_selection)
	back_button.pressed.connect(close)
	set_process(false)
	set_process_unhandled_input(false)


func open(initial_character_id: StringName = PlayerCharacterRegistry.DEFAULT_CHARACTER_ID) -> void:
	if is_open():
		return
	selected_character_id = (
		initial_character_id
		if PlayerCharacterRegistry.is_valid_character_id(initial_character_id)
		else PlayerCharacterRegistry.DEFAULT_CHARACTER_ID
	)
	confirmation_lock_time_left = CONFIRMATION_LOCK_DURATION
	confirmation_in_progress = false
	confirm_button.disabled = false
	back_button.disabled = false
	_build_character_cards()
	visible = true
	root_control.show()
	set_process(true)
	set_process_unhandled_input(true)
	_prepare_open_animation()
	call_deferred("_play_open_animation")


func close() -> void:
	if not root_control.visible or confirmation_in_progress:
		return
	if open_tween != null:
		open_tween.kill()
		open_tween = null
	root_control.hide()
	visible = false
	set_process(false)
	set_process_unhandled_input(false)
	selection_closed.emit()


func is_open() -> bool:
	return visible and root_control.visible


func _process(delta: float) -> void:
	confirmation_lock_time_left = maxf(confirmation_lock_time_left - delta, 0.0)


func _unhandled_input(event: InputEvent) -> void:
	if not root_control.visible or confirmation_in_progress:
		return
	if event.is_action_pressed(&"move_left") or event.is_action_pressed(&"shoot_left") or event.is_action_pressed(&"ui_left"):
		_select_relative(-1)
		get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed(&"move_right") or event.is_action_pressed(&"shoot_right") or event.is_action_pressed(&"ui_right"):
		_select_relative(1)
		get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed(&"interact") or event.is_action_pressed(&"ui_accept"):
		_confirm_selection()
		get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed(&"ui_cancel"):
		close()
		get_viewport().set_input_as_handled()


func _build_character_cards() -> void:
	for child in card_row.get_children():
		child.free()
	cards.clear()

	for config in PlayerCharacterRegistry.get_all_configs():
		var card := CHARACTER_CARD_SCENE.instantiate() as PlayerCharacterCard
		card_row.add_child(card)
		card.setup(config, config.character_id == selected_character_id)
		card.character_selected.connect(_select_character)
		cards.append(card)
	_refresh_selection()


func _select_character(character_id: StringName) -> void:
	if not PlayerCharacterRegistry.is_valid_character_id(character_id):
		return
	selected_character_id = character_id
	_refresh_selection()


func _select_relative(offset: int) -> void:
	if cards.is_empty():
		return
	var selected_index := _get_selected_card_index()
	selected_index = wrapi(selected_index + offset, 0, cards.size())
	_select_character(cards[selected_index].character_config.character_id)
	cards[selected_index].grab_focus()


func _refresh_selection() -> void:
	var selected_config := PlayerCharacterRegistry.get_config(selected_character_id)
	for card in cards:
		card.set_selected(card.character_config.character_id == selected_character_id)
	confirm_button.disabled = selected_config == null
	confirm_button.text = (
		"以 %s 出战" % selected_config.display_name
		if selected_config != null
		else "选择角色"
	)
	if selected_config != null:
		_apply_confirm_button_palette(selected_config)


func _confirm_selection() -> void:
	if confirmation_in_progress or confirmation_lock_time_left > 0.0:
		return
	if not PlayerCharacterRegistry.is_valid_character_id(selected_character_id):
		return
	var selected_index := _get_selected_card_index()
	if selected_index < 0:
		return

	confirmation_in_progress = true
	confirm_button.disabled = true
	back_button.disabled = true
	var confirmation_tween := cards[selected_index].play_confirmation()
	confirmation_tween.finished.connect(func() -> void:
		confirmation_in_progress = false
		back_button.disabled = false
		_refresh_selection()
		character_confirmed.emit(selected_character_id)
	)


func _get_selected_card_index() -> int:
	for index in range(cards.size()):
		if cards[index].character_config.character_id == selected_character_id:
			return index
	return 0 if not cards.is_empty() else -1


func _prepare_open_animation() -> void:
	if open_tween != null:
		open_tween.kill()
		open_tween = null
	dim.modulate = Color(1.0, 1.0, 1.0, 0.0)
	heading.modulate = Color(1.0, 1.0, 1.0, 0.0)
	heading.scale = Vector2.ONE
	for card in cards:
		card.scale = Vector2.ONE
		card.modulate = Color(1.0, 1.0, 1.0, 0.0)


func _play_open_animation() -> void:
	if not root_control.visible:
		return
	open_tween = create_tween()
	open_tween.set_parallel(true)
	open_tween.tween_property(dim, "modulate", Color.WHITE, 0.18).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	open_tween.tween_property(heading, "modulate", Color.WHITE, 0.2).set_delay(0.04)
	for index in range(cards.size()):
		var delay := 0.08 + float(index) * CARD_OPEN_STAGGER
		open_tween.tween_property(cards[index], "modulate", Color.WHITE, 0.12).set_delay(delay)
	open_tween.finished.connect(func() -> void:
		open_tween = null
		var selected_index := _get_selected_card_index()
		if selected_index >= 0:
			cards[selected_index].grab_focus()
	)


func _apply_confirm_button_palette(config: PlayerCharacterConfig) -> void:
	var normal_style := _make_footer_button_style(config.card_button_color, config.card_edge_color)
	var hover_style := _make_footer_button_style(
		config.card_button_color.lightened(0.16),
		config.card_hover_edge_color
	)
	confirm_button.add_theme_stylebox_override(&"normal", normal_style)
	confirm_button.add_theme_stylebox_override(&"hover", hover_style)
	confirm_button.add_theme_stylebox_override(&"pressed", hover_style)
	confirm_button.add_theme_color_override(&"font_color", config.card_text_color)
	confirm_button.add_theme_color_override(&"font_hover_color", config.card_text_color)
	confirm_button.add_theme_color_override(&"font_pressed_color", config.card_text_color)


func _make_footer_button_style(background: Color, edge: Color) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = background
	style.border_width_left = 1
	style.border_width_top = 1
	style.border_width_right = 1
	style.border_width_bottom = 1
	style.border_color = edge
	style.corner_radius_top_left = 5
	style.corner_radius_top_right = 5
	style.corner_radius_bottom_right = 5
	style.corner_radius_bottom_left = 5
	return style
