extends Button
class_name InventorySlot

signal item_activated(slot_index: int)
signal slot_selected(slot_index: int)

@export var slot_index: int = -1

@onready var item_icon: TextureRect = $Icon

var item: PickupConfig = null


func _ready() -> void:
	pressed.connect(_on_pressed)
	gui_input.connect(_on_gui_input)


func set_item(new_item: PickupConfig) -> void:
	item = new_item
	item_icon.texture = null
	if item != null:
		item_icon.texture = item.icon_texture
	tooltip_text = _get_tooltip_text()


func set_selected(selected: bool) -> void:
	button_pressed = selected


func _on_pressed() -> void:
	slot_selected.emit(slot_index)


func _on_gui_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_accept") and has_focus():
		item_activated.emit(slot_index)
		accept_event()
		return

	var mouse_event := event as InputEventMouseButton
	if mouse_event == null:
		return
	if mouse_event.button_index != MOUSE_BUTTON_LEFT:
		return
	if not mouse_event.pressed or not mouse_event.double_click:
		return

	item_activated.emit(slot_index)
	accept_event()


func _get_tooltip_text() -> String:
	if item == null:
		return "空槽位"
	if item.description.is_empty():
		return item.display_name
	return "%s\n%s" % [item.display_name, item.description]
