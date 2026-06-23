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

var selected_index: int = 0
var choices: Array = []
var open_tween: Tween


func _ready() -> void:
	root_control.hide()
	for index in range(buttons.size()):
		buttons[index].pressed.connect(_on_select_pressed.bind(index))


func show_choices(new_choices: Array, initial_index: int = 0) -> void:
	choices = new_choices.duplicate()
	selected_index = clampi(initial_index, 0, maxi(choices.size() - 1, 0))
	_update_cards()
	root_control.show()
	call_deferred("_play_open_animation")


func hide_choices() -> void:
	if open_tween != null:
		open_tween.kill()
		open_tween = null
	root_control.hide()


func is_open() -> bool:
	return root_control.visible


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
	_update_selection()


func _update_selection() -> void:
	for index in range(cards.size()):
		cards[index].modulate = Color(1, 1, 1, 1) if index == selected_index else Color(0.72, 0.72, 0.72, 1)
	if selected_index >= 0 and selected_index < buttons.size() and not buttons[selected_index].disabled:
		buttons[selected_index].grab_focus()


func _play_open_animation() -> void:
	if open_tween != null:
		open_tween.kill()
	open_tween = create_tween()
	open_tween.set_parallel(true)
	for index in range(cards.size()):
		var card := cards[index]
		card.pivot_offset = card.size * 0.5
		card.scale = Vector2(0.05, 1.0)
		open_tween.tween_property(card, "scale:x", 1.0, 0.2).set_delay(float(index) * 0.07).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


func _on_select_pressed(choice_index: int) -> void:
	selected_index = choice_index
	_emit_current_choice()


func _emit_current_choice() -> void:
	if selected_index < 0 or selected_index >= choices.size():
		return
	choice_selected.emit(selected_index)
