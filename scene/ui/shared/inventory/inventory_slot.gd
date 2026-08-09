extends Button
class_name InventorySlot

const DRAG_PREVIEW_SCENE := preload("res://scene/ui/shared/inventory/inventory_drag_preview.tscn")
const DOUBLE_CLICK_FALLBACK_MSEC := 420
const DOUBLE_CLICK_MAX_DISTANCE_SQUARED := 144.0

static var fallback_mouse_press_sequence := 0

signal item_activated(slot_index: int)
signal slot_selected(slot_index: int)

@export var slot_index: int = -1

@onready var item_icon: Sprite2D = $Icon
@onready var stack_count_label: Label = $StackCount
@onready var quick_use_marker: TextureRect = (
	get_node_or_null(^"QuickUseMarker") as TextureRect
)

var item: PickupConfig = null
var stack_count: int = 0
var quick_use_marked := false
var drag_container := -1
var drag_coordinator: Node = null
var last_mouse_click_msec := 0
var last_mouse_click_position := Vector2.ZERO
var last_mouse_item_path := ""
var last_mouse_stack_count := 0
var last_mouse_context_revision := ""
var last_mouse_click_sequence := 0
var mouse_press_candidate := false
var mouse_press_position := Vector2.ZERO
var mouse_press_item_path := ""
var mouse_press_stack_count := 0
var mouse_press_context_revision := ""
var mouse_press_sequence := 0
var pending_mouse_activation := false
var suppress_mouse_release := false


func _ready() -> void:
	pressed.connect(_on_pressed)
	gui_input.connect(_on_gui_input)


func set_item(
	new_item: PickupConfig,
	new_stack_count: int = 1,
	icon_scale_multiplier: Vector2 = Vector2.ONE
) -> void:
	item = new_item
	stack_count = maxi(new_stack_count, 0) if item != null else 0
	item_icon.position = size * 0.5
	item_icon.texture = null
	item_icon.scale = Vector2.ONE
	if item != null:
		item_icon.texture = item.icon_texture
		item_icon.scale = (
			item.get_inventory_icon_scale() * icon_scale_multiplier
		)
	stack_count_label.visible = item != null and stack_count > 1
	stack_count_label.text = str(stack_count)
	_refresh_quick_use_marker()
	tooltip_text = _get_tooltip_text()


func set_selected(selected: bool) -> void:
	button_pressed = selected


func set_quick_use_marked(marked: bool) -> void:
	quick_use_marked = marked
	_refresh_quick_use_marker()
	tooltip_text = _get_tooltip_text()


func _refresh_quick_use_marker() -> void:
	if quick_use_marker == null:
		return
	quick_use_marker.visible = quick_use_marked and item != null


func configure_drag_context(container: int, coordinator: Node) -> void:
	drag_container = container
	drag_coordinator = coordinator


func _on_pressed() -> void:
	slot_selected.emit(slot_index)


func _on_gui_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_accept") and has_focus():
		if item != null:
			item_activated.emit(slot_index)
		accept_event()
		return

	var mouse_event := event as InputEventMouseButton
	if mouse_event == null:
		return
	if mouse_event.button_index != MOUSE_BUTTON_LEFT:
		return
	if not mouse_event.pressed:
		if not Rect2(Vector2.ZERO, size).has_point(mouse_event.position):
			suppress_mouse_release = false
			mouse_press_candidate = false
			pending_mouse_activation = false
			last_mouse_click_msec = 0
			last_mouse_click_sequence = 0
			return
		if suppress_mouse_release:
			suppress_mouse_release = false
			mouse_press_candidate = false
			pending_mouse_activation = false
			return
		if pending_mouse_activation:
			pending_mouse_activation = false
			if _current_item_matches_last_click():
				call_deferred(
					"_emit_item_activation_if_current",
					last_mouse_item_path,
					last_mouse_stack_count,
					last_mouse_context_revision
				)
			mouse_press_candidate = false
			return
		if mouse_press_candidate and _current_item_matches_press_candidate():
			last_mouse_click_msec = Time.get_ticks_msec()
			last_mouse_click_position = mouse_press_position
			last_mouse_item_path = mouse_press_item_path
			last_mouse_stack_count = mouse_press_stack_count
			last_mouse_context_revision = mouse_press_context_revision
			last_mouse_click_sequence = mouse_press_sequence
		mouse_press_candidate = false
		return

	suppress_mouse_release = false
	var now_msec := Time.get_ticks_msec()
	var current_mouse_press_sequence := _get_mouse_press_sequence(mouse_event)
	var is_matching_second_click := (
		last_mouse_click_msec > 0
		and current_mouse_press_sequence == last_mouse_click_sequence + 1
		and (
			mouse_event.double_click
			or (
				now_msec - last_mouse_click_msec <= DOUBLE_CLICK_FALLBACK_MSEC
				and mouse_event.position.distance_squared_to(last_mouse_click_position)
				<= DOUBLE_CLICK_MAX_DISTANCE_SQUARED
			)
		)
		and _current_item_matches_last_click()
	)
	if is_matching_second_click:
		last_mouse_click_msec = 0
		last_mouse_click_sequence = 0
		pending_mouse_activation = true
		mouse_press_candidate = false
		return
	pending_mouse_activation = false
	mouse_press_candidate = item != null
	mouse_press_position = mouse_event.position
	mouse_press_item_path = item.resource_path if item != null else ""
	mouse_press_stack_count = stack_count
	mouse_press_context_revision = _get_context_revision()
	mouse_press_sequence = current_mouse_press_sequence


func _get_drag_data(_at_position: Vector2) -> Variant:
	if (
		item == null
		or drag_coordinator == null
		or not is_instance_valid(drag_coordinator)
		or not drag_coordinator.has_method("make_slot_drag_data")
	):
		return null
	var data := drag_coordinator.call(
		"make_slot_drag_data",
		drag_container,
		slot_index
	) as Dictionary
	if data.is_empty():
		return null
	last_mouse_click_msec = 0
	last_mouse_click_sequence = 0
	pending_mouse_activation = false
	mouse_press_candidate = false
	suppress_mouse_release = true
	var preview := DRAG_PREVIEW_SCENE.instantiate() as Control
	preview.call("configure", item, stack_count)
	set_drag_preview(preview)
	return data


func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
	return (
		drag_coordinator != null
		and is_instance_valid(drag_coordinator)
		and drag_coordinator.has_method("can_drop_slot_data")
		and bool(
			drag_coordinator.call(
				"can_drop_slot_data",
				data,
				drag_container,
				slot_index
			)
		)
	)


func _drop_data(_at_position: Vector2, data: Variant) -> void:
	if (
		drag_coordinator == null
		or not is_instance_valid(drag_coordinator)
		or not drag_coordinator.has_method("drop_slot_data")
	):
		return
	drag_coordinator.call(
		"drop_slot_data",
		data,
		drag_container,
		slot_index
	)


func _current_item_matches_last_click() -> bool:
	return (
		item != null
		and item.resource_path == last_mouse_item_path
		and stack_count == last_mouse_stack_count
		and _get_context_revision() == last_mouse_context_revision
	)


func _current_item_matches_press_candidate() -> bool:
	return (
		item != null
		and item.resource_path == mouse_press_item_path
		and stack_count == mouse_press_stack_count
		and _get_context_revision() == mouse_press_context_revision
	)


func _emit_item_activation_if_current(
	expected_item_path: String,
	expected_stack_count: int,
	expected_context_revision: String
) -> void:
	if (
		item != null
		and item.resource_path == expected_item_path
		and stack_count == expected_stack_count
		and _get_context_revision() == expected_context_revision
	):
		item_activated.emit(slot_index)


func _get_context_revision() -> String:
	if (
		drag_coordinator != null
		and is_instance_valid(drag_coordinator)
		and drag_coordinator.has_method("get_slot_gesture_revision")
	):
		return str(drag_coordinator.call("get_slot_gesture_revision", drag_container))
	return ""


func _get_mouse_press_sequence(mouse_event: InputEventMouseButton) -> int:
	if (
		drag_coordinator != null
		and is_instance_valid(drag_coordinator)
		and drag_coordinator.has_method("register_panel_mouse_press")
	):
		return int(drag_coordinator.call("register_panel_mouse_press", mouse_event))
	fallback_mouse_press_sequence += 1
	return fallback_mouse_press_sequence


func _get_tooltip_text() -> String:
	if item == null:
		return "空槽位"
	var quick_use_text := "\n已设置快捷使用" if quick_use_marked else ""
	if item.description.is_empty():
		var title_text := (
			"%s ×%d" % [item.display_name, stack_count]
			if stack_count > 1
			else item.display_name
		)
		return "%s%s" % [title_text, quick_use_text]
	var name_text := "%s ×%d" % [item.display_name, stack_count] if stack_count > 1 else item.display_name
	return "%s\n%s%s" % [name_text, item.description, quick_use_text]
