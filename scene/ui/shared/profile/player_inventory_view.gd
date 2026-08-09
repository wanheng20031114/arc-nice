extends Control
class_name PlayerInventoryView

signal item_use_requested(slot_index: int)
signal item_discard_requested(slot_index: int)

const DESIGN_SIZE := Vector2(724.0, 543.0)
const ITEM_DETAIL_SIZE := Vector2(254.0, 166.0)
const ITEM_DETAIL_MARGIN := 14.0
const ITEM_CATEGORY_COLLECTIBLE_TEXTURE := preload(
	"res://resources/texture/item_category_badge_collectible.png"
)
const ITEM_CATEGORY_ITEM_TEXTURE := preload(
	"res://resources/texture/item_category_badge_item.png"
)

@onready var inventory_grid: Control = $InventoryGrid
@onready var item_detail_panel: PanelContainer = $ItemDetailPanel
@onready var item_detail_title: Label = (
	$ItemDetailPanel/Margin/Content/HeaderRow/ItemTitle
)
@onready var item_detail_category_backing: TextureRect = (
	$ItemDetailPanel/Margin/Content/HeaderRow/ItemCategory
)
@onready var item_detail_category_label: Label = (
	$ItemDetailPanel/Margin/Content/HeaderRow/ItemCategory/CategoryLabel
)
@onready var item_detail_description: RichTextLabel = (
	$ItemDetailPanel/Margin/Content/ItemDescription
)
@onready var item_detail_hint: Label = (
	$ItemDetailPanel/Margin/Content/ItemHint
)
@onready var item_detail_use_button: Button = (
	$ItemDetailPanel/Margin/Content/ButtonRow/UseButton
)
@onready var item_detail_discard_button: Button = (
	$ItemDetailPanel/Margin/Content/ButtonRow/DiscardButton
)

var run_state: RunStateStore = null
var slots: Array[InventorySlot] = []
var selected_slot_index := -1
var panel_active := true


func _ready() -> void:
	item_detail_use_button.pressed.connect(_on_detail_use_pressed)
	item_detail_discard_button.pressed.connect(_on_detail_discard_pressed)
	inventory_grid.gui_input.connect(_on_inventory_grid_gui_input)
	_collect_slots()
	_hide_item_detail()


func bind_run_state(new_run_state: RunStateStore) -> void:
	run_state = new_run_state
	refresh()


func set_panel_active(active: bool) -> void:
	panel_active = active
	visible = active
	inventory_grid.visible = active
	if not active:
		clear_selection()
	else:
		refresh()


func refresh() -> void:
	if run_state == null:
		return
	for slot_index in range(slots.size()):
		slots[slot_index].set_item(
			run_state.get_item(slot_index),
			run_state.get_item_count(slot_index)
		)
		slots[slot_index].set_selected(slot_index == selected_slot_index)
	_refresh_item_detail()


func select_slot(slot_index: int) -> void:
	_on_slot_selected(slot_index)


func clear_selection() -> void:
	selected_slot_index = -1
	for slot in slots:
		slot.set_selected(false)
	_hide_item_detail()
	get_viewport().gui_release_focus()


func get_item(slot_index: int) -> PickupConfig:
	if run_state == null or slot_index < 0 or slot_index >= slots.size():
		return null
	return run_state.get_item(slot_index)


func handle_accept() -> bool:
	if not panel_active or selected_slot_index < 0:
		return false
	_request_use(selected_slot_index)
	return true


func handle_blank_grid_input(event: InputEvent) -> void:
	_on_inventory_grid_gui_input(event)


func _collect_slots() -> void:
	slots.clear()
	for child in inventory_grid.get_children():
		var slot := child as InventorySlot
		if slot == null:
			continue
		slot.slot_selected.connect(_on_slot_selected)
		slot.item_activated.connect(_request_use)
		slots.append(slot)


func _on_slot_selected(slot_index: int) -> void:
	if (
		run_state == null
		or slot_index < 0
		or slot_index >= slots.size()
		or run_state.get_item(slot_index) == null
	):
		clear_selection()
		return
	selected_slot_index = slot_index
	for slot in slots:
		slot.set_selected(slot.slot_index == selected_slot_index)
	_refresh_item_detail()


func _request_use(slot_index: int) -> void:
	if (
		run_state == null
		or slot_index < 0
		or slot_index >= slots.size()
		or run_state.get_item(slot_index) == null
	):
		clear_selection()
		return
	selected_slot_index = slot_index
	var item := run_state.get_item(slot_index)
	if item.inventory_locked:
		_refresh_item_detail()
		return
	if (
		not item.is_consumable_item()
		and item.pickup_type != PickupConfig.PickupType.BUILDING
	):
		_refresh_item_detail()
		return
	item_use_requested.emit(slot_index)


func _on_inventory_grid_gui_input(event: InputEvent) -> void:
	if not panel_active:
		return
	var mouse_event := event as InputEventMouseButton
	if mouse_event == null:
		return
	if mouse_event.button_index != MOUSE_BUTTON_LEFT or not mouse_event.pressed:
		return
	clear_selection()
	inventory_grid.accept_event()


func _refresh_item_detail() -> void:
	if (
		not panel_active
		or run_state == null
		or selected_slot_index < 0
		or selected_slot_index >= slots.size()
	):
		_hide_item_detail()
		return
	var item := run_state.get_item(selected_slot_index)
	if item == null:
		clear_selection()
		return
	var is_consumable := item.is_consumable_item()
	var is_material := item.pickup_type == PickupConfig.PickupType.MATERIAL
	var is_building := item.pickup_type == PickupConfig.PickupType.BUILDING
	var is_inventory_locked := item.inventory_locked
	var stack_count := run_state.get_item_count(selected_slot_index)
	item_detail_title.text = (
		"%s ×%d" % [item.display_name, stack_count]
		if stack_count > 1
		else item.display_name
	)
	item_detail_category_label.text = _get_item_type_label(item)
	item_detail_category_backing.texture = (
		ITEM_CATEGORY_ITEM_TEXTURE
		if is_consumable or is_material or is_building
		else ITEM_CATEGORY_COLLECTIBLE_TEXTURE
	)
	item_detail_description.text = (
		item.description if not item.description.is_empty() else "暂无描述"
	)
	item_detail_hint.visible = is_inventory_locked or is_consumable or is_building
	if is_inventory_locked:
		item_detail_hint.text = "命运物品 · 无法使用、移动或删除"
	else:
		item_detail_hint.text = (
			"也可以双击槽位进入建造模式"
			if is_building
			else "也可以双击槽位使用"
		)
	item_detail_use_button.visible = (
		(is_consumable or is_building) and not is_inventory_locked
	)
	item_detail_use_button.text = "建造" if is_building else "使用"
	item_detail_discard_button.visible = not is_inventory_locked
	item_detail_discard_button.text = (
		"销毁" if is_building else ("删除" if is_material else "丢弃")
	)
	item_detail_panel.visible = true
	item_detail_panel.move_to_front()
	_update_item_detail_position(slots[selected_slot_index])


func _hide_item_detail() -> void:
	item_detail_panel.visible = false


func _update_item_detail_position(slot: InventorySlot) -> void:
	if slot == null:
		return
	var slot_size := slot.size
	if slot_size.x <= 0.0 or slot_size.y <= 0.0:
		slot_size = slot.custom_minimum_size
	var slot_position := inventory_grid.position + slot.position
	var target_x := slot_position.x + slot_size.x + ITEM_DETAIL_MARGIN
	if target_x + ITEM_DETAIL_SIZE.x > DESIGN_SIZE.x - ITEM_DETAIL_MARGIN:
		target_x = slot_position.x - ITEM_DETAIL_MARGIN - ITEM_DETAIL_SIZE.x
	target_x = clampf(
		target_x,
		ITEM_DETAIL_MARGIN,
		DESIGN_SIZE.x - ITEM_DETAIL_SIZE.x - ITEM_DETAIL_MARGIN
	)
	var target_y := clampf(
		slot_position.y,
		ITEM_DETAIL_MARGIN,
		DESIGN_SIZE.y - ITEM_DETAIL_SIZE.y - ITEM_DETAIL_MARGIN
	)
	item_detail_panel.position = Vector2(roundf(target_x), roundf(target_y))
	item_detail_panel.size = ITEM_DETAIL_SIZE


func _on_detail_use_pressed() -> void:
	if selected_slot_index >= 0:
		_request_use(selected_slot_index)


func _on_detail_discard_pressed() -> void:
	if selected_slot_index < 0 or run_state == null:
		return
	var item := run_state.get_item(selected_slot_index)
	if item == null or item.inventory_locked:
		_refresh_item_detail()
		return
	item_discard_requested.emit(selected_slot_index)


func _get_item_type_label(item: PickupConfig) -> String:
	if item != null and item.is_consumable_item():
		return "消耗品"
	if item != null and item.pickup_type == PickupConfig.PickupType.COLLECTIBLE:
		return "收藏品"
	if item != null and item.pickup_type == PickupConfig.PickupType.MATERIAL:
		return "物资"
	if item != null and item.pickup_type == PickupConfig.PickupType.BUILDING:
		return "建筑"
	return "道具"
