extends CanvasLayer
class_name LuoxiCollectibleChoiceOverlay

signal choice_selected(choice_index: int)
signal choice_closed

@onready var root_control: Control = $Root
@onready var cards: Array[PanelContainer] = [
	$Root/Center/Content/CardRow/Card0,
	$Root/Center/Content/CardRow/Card1,
	$Root/Center/Content/CardRow/Card2,
]
@onready var card_fronts: Array[Control] = [
	$Root/Center/Content/CardRow/Card0/Margin,
	$Root/Center/Content/CardRow/Card1/Margin,
	$Root/Center/Content/CardRow/Card2/Margin,
]
@onready var icons: Array[TextureRect] = [
	$Root/Center/Content/CardRow/Card0/Margin/Content/Icon,
	$Root/Center/Content/CardRow/Card1/Margin/Content/Icon,
	$Root/Center/Content/CardRow/Card2/Margin/Content/Icon,
]
@onready var titles: Array[Label] = [
	$Root/Center/Content/CardRow/Card0/Margin/Content/Title,
	$Root/Center/Content/CardRow/Card1/Margin/Content/Title,
	$Root/Center/Content/CardRow/Card2/Margin/Content/Title,
]
@onready var descriptions: Array[RichTextLabel] = [
	$Root/Center/Content/CardRow/Card0/Margin/Content/Description,
	$Root/Center/Content/CardRow/Card1/Margin/Content/Description,
	$Root/Center/Content/CardRow/Card2/Margin/Content/Description,
]
@onready var buttons: Array[Button] = [
	$Root/Center/Content/CardRow/Card0/Margin/Content/SelectButton,
	$Root/Center/Content/CardRow/Card1/Margin/Content/SelectButton,
	$Root/Center/Content/CardRow/Card2/Margin/Content/SelectButton,
]

const CARD_BACK_TINT := Color(0.52, 0.47, 0.39, 1.0)
const CARD_EDGE_SCALE_X := 0.04
const CARD_FLIP_IN_DURATION := 0.14
const CARD_FLIP_OUT_DURATION := 0.24
const CARD_OPEN_STAGGER := 0.08
const CARD_HOVER_LIFT := 4.0
const CARD_HOVER_DURATION := 0.12
const DESCRIPTION_SCROLL_SPEED := 10.0
const DESCRIPTION_SCROLL_TOP_PAUSE := 0.8
const DESCRIPTION_SCROLL_BOTTOM_PAUSE := 1.5

var selected_index: int = 0
var choices: Array = []
var open_tween: Tween
var hover_tweens: Array[Tween] = []
var card_base_styles: Array[StyleBoxFlat] = []
var card_hover_styles: Array[StyleBoxFlat] = []
var card_base_positions: Array[Vector2] = []
var card_base_positions_captured := false
var description_scroll_offsets: Array[float] = []
var description_scroll_pauses: Array[float] = []
var description_scroll_at_bottom: Array[bool] = []


func _ready() -> void:
	root_control.hide()
	_build_card_hover_styles()
	hover_tweens.resize(cards.size())
	card_base_positions.resize(cards.size())
	description_scroll_offsets.resize(descriptions.size())
	description_scroll_pauses.resize(descriptions.size())
	description_scroll_at_bottom.resize(descriptions.size())
	for description in descriptions:
		description.scroll_active = true
		description.scroll_following = false
	for index in range(buttons.size()):
		buttons[index].pressed.connect(_on_select_pressed.bind(index))
	for index in range(cards.size()):
		cards[index].mouse_entered.connect(_on_card_mouse_entered.bind(index))
		cards[index].mouse_exited.connect(_on_card_mouse_exited.bind(index))
	set_process(false)


func show_choices(new_choices: Array, initial_index: int = 0) -> void:
	choices = new_choices.duplicate()
	selected_index = clampi(initial_index, 0, maxi(choices.size() - 1, 0))
	card_base_positions_captured = false
	_update_cards()
	_prepare_open_animation()
	_reset_description_scrolls()
	root_control.show()
	set_process(true)
	call_deferred("_reset_description_scrolls")
	call_deferred("_play_open_animation")


func hide_choices() -> void:
	if open_tween != null:
		open_tween.kill()
		open_tween = null
	for index in range(cards.size()):
		_reset_card_hover(index)
		card_fronts[index].show()
		cards[index].scale = Vector2.ONE
		cards[index].self_modulate = Color.WHITE
		cards[index].modulate = Color.WHITE
	root_control.hide()
	set_process(false)


func is_open() -> bool:
	return root_control.visible


func _process(delta: float) -> void:
	if root_control.visible:
		_process_description_scrolls(delta)


func handle_input(event: InputEvent) -> bool:
	if not root_control.visible:
		return false
	if event.is_action_pressed("move_left") or event.is_action_pressed("shoot_left"):
		select_choice(selected_index - 1)
		return true
	if event.is_action_pressed("move_right") or event.is_action_pressed("shoot_right"):
		select_choice(selected_index + 1)
		return true
	if event.is_action_pressed("interact"):
		_emit_current_choice()
		return true
	if event.is_action_pressed("ui_cancel"):
		hide_choices()
		choice_closed.emit()
		return true
	return false


func select_choice(choice_index: int) -> void:
	if choices.is_empty():
		selected_index = 0
	else:
		selected_index = wrapi(choice_index, 0, choices.size())
	_update_selection()


func _update_cards() -> void:
	for index in range(cards.size()):
		var item: PickupConfig = null
		if index < choices.size():
			item = choices[index] as PickupConfig
		var has_item := item != null
		icons[index].texture = item.icon_texture if has_item else null
		titles[index].text = item.display_name if has_item else ""
		descriptions[index].text = item.description if has_item else ""
		buttons[index].disabled = not has_item
		_reset_description_scroll(index)
	_update_selection()


func _reset_description_scrolls() -> void:
	for index in range(descriptions.size()):
		_reset_description_scroll(index)


func _reset_description_scroll(index: int) -> void:
	if index < 0 or index >= descriptions.size():
		return
	description_scroll_offsets[index] = 0.0
	description_scroll_pauses[index] = DESCRIPTION_SCROLL_TOP_PAUSE
	description_scroll_at_bottom[index] = false
	var scroll_bar := descriptions[index].get_v_scroll_bar()
	if scroll_bar != null:
		scroll_bar.value = 0.0


func _process_description_scrolls(delta: float) -> void:
	for index in range(descriptions.size()):
		var scroll_bar := descriptions[index].get_v_scroll_bar()
		if scroll_bar == null:
			continue
		var max_scroll := floorf(maxf(scroll_bar.max_value - scroll_bar.page, 0.0))
		if max_scroll <= 0.5:
			description_scroll_offsets[index] = 0.0
			description_scroll_at_bottom[index] = false
			scroll_bar.value = 0.0
			continue
		if description_scroll_pauses[index] > 0.0:
			description_scroll_pauses[index] = maxf(description_scroll_pauses[index] - delta, 0.0)
			continue
		if description_scroll_at_bottom[index]:
			description_scroll_offsets[index] = 0.0
			description_scroll_at_bottom[index] = false
			description_scroll_pauses[index] = DESCRIPTION_SCROLL_TOP_PAUSE
			scroll_bar.value = 0.0
			continue
		description_scroll_offsets[index] += DESCRIPTION_SCROLL_SPEED * delta
		if description_scroll_offsets[index] >= max_scroll:
			description_scroll_offsets[index] = max_scroll
			description_scroll_at_bottom[index] = true
			description_scroll_pauses[index] = DESCRIPTION_SCROLL_BOTTOM_PAUSE
		# Fractional scroll offsets soften dynamic font rendering while the text moves.
		scroll_bar.value = minf(roundf(description_scroll_offsets[index]), max_scroll)


func _update_selection() -> void:
	for index in range(cards.size()):
		cards[index].modulate = Color.WHITE
	if selected_index >= 0 and selected_index < buttons.size() and not buttons[selected_index].disabled:
		buttons[selected_index].grab_focus()


func _prepare_open_animation() -> void:
	if open_tween != null:
		open_tween.kill()
		open_tween = null
	for index in range(cards.size()):
		var card := cards[index]
		_reset_card_hover(index)
		card.scale = Vector2.ONE
		card.modulate = Color.WHITE
		card.self_modulate = CARD_BACK_TINT
		card_fronts[index].hide()


func _play_open_animation() -> void:
	if open_tween != null:
		open_tween.kill()
	open_tween = create_tween()
	open_tween.set_parallel(true)
	for index in range(cards.size()):
		var card := cards[index]
		var visible_size := card.size
		if visible_size.x <= 0.0 or visible_size.y <= 0.0:
			visible_size = card.custom_minimum_size
		card.pivot_offset = visible_size * 0.5
		var delay := float(index) * CARD_OPEN_STAGGER
		open_tween.tween_property(card, "scale:x", CARD_EDGE_SCALE_X, CARD_FLIP_IN_DURATION).set_delay(delay).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
		open_tween.tween_callback(_reveal_card_front.bind(index)).set_delay(delay + CARD_FLIP_IN_DURATION)
		open_tween.tween_property(card, "scale:x", 1.0, CARD_FLIP_OUT_DURATION).set_delay(delay + CARD_FLIP_IN_DURATION).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	open_tween.finished.connect(func() -> void:
		open_tween = null
		_capture_card_base_positions()
		_refresh_card_hover_from_mouse()
	)


func _reveal_card_front(index: int) -> void:
	if index < 0 or index >= cards.size():
		return
	card_fronts[index].show()
	cards[index].self_modulate = Color.WHITE
	cards[index].modulate = Color.WHITE


func _build_card_hover_styles() -> void:
	card_base_styles.clear()
	card_hover_styles.clear()
	for card in cards:
		var base_style := (card.get_theme_stylebox("panel") as StyleBoxFlat).duplicate() as StyleBoxFlat
		var hover_style := base_style.duplicate() as StyleBoxFlat
		hover_style.bg_color = Color(1.0, 0.975, 0.93, 1.0)
		hover_style.border_color = Color(1.0, 0.25, 0.3, 1.0)
		hover_style.shadow_color = Color(1.0, 0.15, 0.18, 0.3)
		hover_style.shadow_size = 14
		hover_style.shadow_offset = Vector2(0, 2)
		card.add_theme_stylebox_override("panel", base_style)
		card_base_styles.append(base_style)
		card_hover_styles.append(hover_style)


func _refresh_card_hover_from_mouse() -> void:
	for index in range(cards.size()):
		_set_card_hovered(index, _is_mouse_over_card(index))


func _on_card_mouse_entered(index: int) -> void:
	_set_card_hovered(index, true)


func _on_card_mouse_exited(index: int) -> void:
	if _is_mouse_over_card(index):
		return
	_set_card_hovered(index, false)


func _set_card_hovered(index: int, hovered: bool) -> void:
	if index < 0 or index >= cards.size():
		return
	if open_tween != null:
		return
	var card := cards[index]
	var base_position := _get_card_base_position(index)
	var target_position := base_position + Vector2(0.0, -CARD_HOVER_LIFT if hovered else 0.0)
	if hover_tweens[index] != null:
		hover_tweens[index].kill()
	card.pivot_offset = _get_card_visible_size(card) * 0.5
	card.add_theme_stylebox_override("panel", card_hover_styles[index] if hovered else card_base_styles[index])
	hover_tweens[index] = create_tween()
	hover_tweens[index].tween_property(card, "position", target_position, CARD_HOVER_DURATION).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	hover_tweens[index].finished.connect(func() -> void:
		hover_tweens[index] = null
	)


func _reset_card_hover(index: int) -> void:
	if hover_tweens[index] != null:
		hover_tweens[index].kill()
		hover_tweens[index] = null
	cards[index].scale = Vector2.ONE
	cards[index].position = _get_card_base_position(index)
	cards[index].add_theme_stylebox_override("panel", card_base_styles[index])


func _is_mouse_over_card(index: int) -> bool:
	return cards[index].get_global_rect().has_point(cards[index].get_global_mouse_position())


func _get_card_visible_size(card: Control) -> Vector2:
	if card.size.x > 0.0 and card.size.y > 0.0:
		return card.size
	return card.custom_minimum_size


func _capture_card_base_positions() -> void:
	for index in range(cards.size()):
		card_base_positions[index] = cards[index].position.round()
		cards[index].position = card_base_positions[index]
	card_base_positions_captured = true


func _get_card_base_position(index: int) -> Vector2:
	if card_base_positions_captured and index >= 0 and index < card_base_positions.size():
		return card_base_positions[index]
	return cards[index].position.round()


func _on_select_pressed(choice_index: int) -> void:
	selected_index = choice_index
	_emit_current_choice()


func _emit_current_choice() -> void:
	if selected_index < 0 or selected_index >= choices.size():
		return
	choice_selected.emit(selected_index)
