extends CanvasLayer
class_name PlantSelectionHUD

signal selection_confirmed(config: PlantDefenseConfig)
signal cancel_requested

const PLANT_CARD_SCENE := preload("res://scene/plant_defense/plant_selection_card.tscn")

@onready var root_control: Control = $Root
@onready var dim: ColorRect = $Root/Dim
@onready var card_row: HBoxContainer = $Root/Center/Content/Margin/Layout/CardScroll/CardCenter/CardRow
@onready var confirm_button: Button = $Root/Center/Content/Margin/Layout/Footer/ConfirmButton
@onready var cancel_button: Button = $Root/Center/Content/Margin/Layout/Footer/CancelButton

var cards: Array[PlantSelectionCard] = []
var available_configs: Array[PlantDefenseConfig] = []
var selected_config: PlantDefenseConfig


func _ready() -> void:
	hide()
	root_control.hide()
	confirm_button.pressed.connect(_confirm_selection)
	cancel_button.pressed.connect(_request_cancel)
	dim.gui_input.connect(_on_dim_gui_input)
	set_process_unhandled_input(false)


func open(configs: Array[PlantDefenseConfig]) -> bool:
	if configs.is_empty():
		return false
	available_configs.clear()
	available_configs.append_array(configs)
	_build_cards()
	selected_config = available_configs[0]
	_refresh_selection()
	show()
	root_control.show()
	set_process_unhandled_input(true)
	call_deferred("_focus_selected_card")
	return true


func close() -> void:
	root_control.hide()
	hide()
	set_process_unhandled_input(false)


func is_open() -> bool:
	return root_control.visible


func _unhandled_input(event: InputEvent) -> void:
	if not root_control.visible:
		return
	if event.is_action_pressed(&"ui_left") or event.is_action_pressed(&"move_left"):
		_select_relative(-1)
		get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed(&"ui_right") or event.is_action_pressed(&"move_right"):
		_select_relative(1)
		get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed(&"ui_accept") or event.is_action_pressed(&"interact"):
		_confirm_selection()
		get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed(&"ui_cancel"):
		_request_cancel()
		get_viewport().set_input_as_handled()


func _build_cards() -> void:
	for child in card_row.get_children():
		child.free()
	cards.clear()
	for config in available_configs:
		var card := PLANT_CARD_SCENE.instantiate() as PlantSelectionCard
		card_row.add_child(card)
		card.setup(config, false)
		card.plant_selected.connect(_select_config)
		cards.append(card)


func _select_config(config: PlantDefenseConfig) -> void:
	if config == null or not available_configs.has(config):
		return
	selected_config = config
	_refresh_selection()


func _select_relative(offset: int) -> void:
	if cards.is_empty():
		return
	var selected_index := _get_selected_index()
	selected_index = wrapi(selected_index + offset, 0, cards.size())
	_select_config(cards[selected_index].plant_config)
	cards[selected_index].grab_focus()


func _refresh_selection() -> void:
	for card in cards:
		card.set_selected(card.plant_config == selected_config)
	confirm_button.disabled = selected_config == null
	confirm_button.text = (
		"选择 %s" % selected_config.display_name
		if selected_config != null
		else "选择植物"
	)


func _get_selected_index() -> int:
	for index in range(cards.size()):
		if cards[index].plant_config == selected_config:
			return index
	return 0


func _focus_selected_card() -> void:
	if root_control.visible and not cards.is_empty():
		cards[_get_selected_index()].grab_focus()


func _confirm_selection() -> void:
	if selected_config != null:
		selection_confirmed.emit(selected_config)


func _request_cancel() -> void:
	if root_control.visible:
		cancel_requested.emit()


func _on_dim_gui_input(event: InputEvent) -> void:
	var mouse_event := event as InputEventMouseButton
	if mouse_event != null and mouse_event.button_index == MOUSE_BUTTON_RIGHT and mouse_event.pressed:
		dim.accept_event()
		_request_cancel()
