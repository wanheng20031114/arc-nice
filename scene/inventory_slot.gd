extends Button
class_name InventorySlot

signal item_activated(slot_index: int)
signal slot_selected(slot_index: int)

@export var slot_index: int = -1

@onready var item_icon: TextureRect = $Icon
@onready var stack_count_label: Label = $StackCount

var item: PickupConfig = null
var stack_count: int = 0


func _ready() -> void:
	pressed.connect(_on_pressed)
	gui_input.connect(_on_gui_input)


func set_item(new_item: PickupConfig, new_stack_count: int = 1) -> void:
	item = new_item
	stack_count = maxi(new_stack_count, 0) if item != null else 0
	item_icon.texture = null
	if item != null:
		item_icon.texture = item.icon_texture
	stack_count_label.visible = item != null and stack_count > 1
	stack_count_label.text = str(stack_count)
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
		return "%s ×%d" % [item.display_name, stack_count] if stack_count > 1 else item.display_name
	var name_text := "%s ×%d" % [item.display_name, stack_count] if stack_count > 1 else item.display_name
	return "%s\n%s" % [name_text, item.description]
