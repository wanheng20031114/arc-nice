extends PanelContainer
class_name RogueSupplyCollectibleChoicePanel

signal choice_selected(offer_index: int)
signal inventory_requested()

@onready var status_label: Label = $Margin/Rows/Status
@onready var cards: Array[RogueSupplyCollectibleCard] = [
	$Margin/Rows/Cards/Choice0,
	$Margin/Rows/Cards/Choice1,
	$Margin/Rows/Cards/Choice2,
]
@onready var inventory_button: Button = $Margin/Rows/InventoryButton

var interaction_enabled := false


func _ready() -> void:
	for card in cards:
		card.selected.connect(_on_card_selected)
	inventory_button.pressed.connect(_on_inventory_button_pressed)
	hide_panel()


func show_choices(
	offer_paths: Array,
	status_text: String,
	enabled: bool,
	show_inventory_button: bool,
	inventory_enabled: bool
) -> void:
	visible = true
	interaction_enabled = enabled
	status_label.text = status_text
	for offer_index in range(cards.size()):
		var card := cards[offer_index]
		card.visible = offer_index < offer_paths.size()
		if not card.visible:
			continue
		card.configure(
			offer_index,
			str(offer_paths[offer_index]),
			enabled
		)
		card.set_interaction_enabled(enabled)
	inventory_button.visible = show_inventory_button
	inventory_button.disabled = not inventory_enabled
	if enabled:
		focus_first_available()


func set_pending(pending: bool, status_text: String = "") -> void:
	interaction_enabled = not pending
	if not status_text.is_empty():
		status_label.text = status_text
	for card in cards:
		card.set_interaction_enabled(not pending)
	if inventory_button.visible:
		inventory_button.disabled = pending


func hide_panel() -> void:
	visible = false
	interaction_enabled = false
	inventory_button.visible = false
	inventory_button.disabled = true
	for card in cards:
		card.set_interaction_enabled(false)


func focus_first_available() -> void:
	for card in cards:
		if card.visible and not card.button.disabled:
			card.button.grab_focus()
			return
	if inventory_button.visible and not inventory_button.disabled:
		inventory_button.grab_focus()


func _on_card_selected(offer_index: int) -> void:
	if interaction_enabled:
		choice_selected.emit(offer_index)


func _on_inventory_button_pressed() -> void:
	if inventory_button.visible and not inventory_button.disabled:
		inventory_requested.emit()
