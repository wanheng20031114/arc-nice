extends CanvasLayer
class_name OakWarehousePanel

signal opened
signal closed

enum ItemSource {
	NONE,
	STORAGE,
	PLAYER,
}

const DESIGN_SIZE := Vector2(724.0, 543.0)
const CONTROLLER_HOLD_SECONDS := 0.32
const CONTROLLER_CURSOR_SPEED := 360.0
const CONTROLLER_STICK_DEADZONE := 0.22
const MAX_QUEUED_QUICK_MOVES := 12
const PANEL_MOUSE_PRESS_SEQUENCE_META := &"_oak_warehouse_mouse_press_sequence"

@onready var overlay: Control = $Overlay
@onready var panel_root: Control = $Overlay/PanelRoot
@onready var storage_grid: GridContainer = $Overlay/PanelRoot/StorageGrid
@onready var player_grid: GridContainer = $Overlay/PanelRoot/PlayerGrid
@onready var item_title: Label = $Overlay/PanelRoot/ItemDetail/ItemTitle
@onready var item_category: Label = $Overlay/PanelRoot/ItemDetail/ItemCategory
@onready var item_description: RichTextLabel = $Overlay/PanelRoot/ItemDetail/ItemDescription
@onready var status_label: Label = $Overlay/PanelRoot/StatusLabel
@onready var use_button: Button = $Overlay/PanelRoot/UseButton
@onready var move_button: Button = $Overlay/PanelRoot/MoveButton
@onready var discard_button: Button = $Overlay/PanelRoot/DiscardButton
@onready var close_button: Button = $Overlay/PanelRoot/CloseButton
@onready var virtual_cursor: Control = $Overlay/PanelRoot/VirtualCursor
@onready var controller_hold_timer: Timer = $ControllerHoldTimer
@onready var run_state: RunStateStore = get_node("/root/RunState") as RunStateStore

var warehouse: OakWarehouse = null
var tracked_player: Player = null
var storage_slots: Array[InventorySlot] = []
var player_slots: Array[InventorySlot] = []
var selected_source := ItemSource.NONE
var selected_slot_index := -1
var multiplayer_storage_enabled := false
var multiplayer_storage_snapshot_ready := true
var multiplayer_storage_request_pending := false
var controller_accept_held := false
var controller_drag_active := false
var controller_device := -1
var controller_drag_data: Dictionary = {}
var multiplayer_slot_drop_pending := false
var multiplayer_slot_drop_source := ItemSource.NONE
var multiplayer_slot_drop_source_index := -1
var multiplayer_slot_drop_target := ItemSource.NONE
var multiplayer_slot_drop_target_index := -1
var queued_quick_moves: Array[Dictionary] = []
var panel_mouse_press_sequence := 0
var panel_session_generation := 0


func _ready() -> void:
	overlay.hide()
	virtual_cursor.hide()
	set_process(false)
	set_process_input(false)
	set_process_unhandled_input(false)
	_collect_slots(storage_grid, storage_slots, ItemSource.STORAGE)
	_collect_slots(player_grid, player_slots, ItemSource.PLAYER)
	use_button.pressed.connect(_on_use_pressed)
	move_button.pressed.connect(_on_move_pressed)
	discard_button.pressed.connect(_on_discard_pressed)
	close_button.pressed.connect(close)
	overlay.gui_input.connect(_on_overlay_gui_input)
	controller_hold_timer.timeout.connect(_on_controller_hold_timeout)
	Input.joy_connection_changed.connect(_on_joy_connection_changed)
	get_viewport().size_changed.connect(_update_panel_transform)
	run_state.ensure_run_started()
	_update_panel_transform()
	_refresh_detail()


func bind_warehouse(new_warehouse: OakWarehouse, player: Player) -> void:
	if warehouse == new_warehouse and tracked_player == player:
		_refresh_all()
		return
	if is_open():
		close()
	else:
		_reset_transient_state()
		_unbind_warehouse()
	if new_warehouse != null:
		panel_session_generation += 1
	warehouse = new_warehouse
	tracked_player = player
	if tracked_player != null and not tracked_player.died.is_connected(_on_tracked_player_died):
		tracked_player.died.connect(_on_tracked_player_died)
	if warehouse != null and not warehouse.storage_changed.is_connected(_refresh_all):
		warehouse.storage_changed.connect(_refresh_all)
	if not run_state.inventory_changed.is_connected(_refresh_all):
		run_state.inventory_changed.connect(_refresh_all)
	if warehouse != null:
		set_multiplayer_storage_state(
			warehouse.multiplayer_storage_enabled,
			warehouse.multiplayer_storage_snapshot_ready,
			warehouse.multiplayer_storage_request_pending
		)
	_refresh_all()


func open_for(new_warehouse: OakWarehouse, player: Player) -> void:
	bind_warehouse(new_warehouse, player)
	open()


func set_multiplayer_storage_state(
	enabled: bool,
	snapshot_ready: bool,
	request_pending: bool
) -> void:
	multiplayer_storage_enabled = enabled
	multiplayer_storage_snapshot_ready = snapshot_ready or not enabled
	multiplayer_storage_request_pending = request_pending and enabled
	if _is_network_locked() and controller_accept_held:
		_cancel_controller_drag()
	if not _is_network_locked() and not queued_quick_moves.is_empty():
		call_deferred("_process_next_queued_quick_move")
	if _is_waiting_for_multiplayer_storage_configuration():
		status_label.text = "正在同步共享仓库…"
	elif multiplayer_storage_enabled and not multiplayer_storage_snapshot_ready:
		status_label.text = "正在同步共享仓库…"
	elif multiplayer_storage_request_pending:
		status_label.text = "正在等待主机确认…"
	elif status_label.text in ["正在同步共享仓库…", "正在等待主机确认…"]:
		status_label.text = ""
	_refresh_detail()


func show_multiplayer_command_result(success: bool, reason: StringName) -> void:
	var was_slot_drop := multiplayer_slot_drop_pending
	var focus_source: int = (
		multiplayer_slot_drop_target if success else multiplayer_slot_drop_source
	)
	var focus_slot_index: int = (
		multiplayer_slot_drop_target_index if success else multiplayer_slot_drop_source_index
	)
	var suppress_failure_text := was_slot_drop and not success
	clear_multiplayer_slot_drop_pending()
	if success:
		status_label.text = "物品已移动"
	elif not suppress_failure_text:
		status_label.text = _get_multiplayer_failure_text(reason)
	_clear_selection(not was_slot_drop)
	_refresh_all()
	if was_slot_drop:
		call_deferred("_focus_slot", focus_source, focus_slot_index)
	else:
		call_deferred("_focus_first_item_slot")


func clear_multiplayer_slot_drop_pending() -> void:
	multiplayer_slot_drop_pending = false
	multiplayer_slot_drop_source = ItemSource.NONE
	multiplayer_slot_drop_source_index = -1
	multiplayer_slot_drop_target = ItemSource.NONE
	multiplayer_slot_drop_target_index = -1


func open() -> void:
	if warehouse == null or tracked_player == null or tracked_player.is_dead:
		_reset_transient_state()
		_unbind_warehouse()
		return
	if overlay.visible:
		return
	show()
	overlay.show()
	set_process_input(true)
	set_process_unhandled_input(true)
	tracked_player.set_controls_locked(true)
	_clear_selection()
	_refresh_all()
	_focus_first_item_slot()
	warehouse.on_shared_storage_panel_opened(self)
	opened.emit()


func close() -> void:
	if not overlay.visible and warehouse == null:
		return
	var closing_warehouse := warehouse
	var closing_player := tracked_player
	var was_open := overlay.visible
	overlay.hide()
	hide()
	set_process_input(false)
	set_process_unhandled_input(false)
	_reset_transient_state()
	if (
		was_open
		and closing_player != null
		and is_instance_valid(closing_player)
		and not closing_player.is_dead
	):
		closing_player.set_controls_locked(false)
	_unbind_warehouse()
	_clear_slot_contents()
	if not was_open:
		return
	if closing_warehouse != null and is_instance_valid(closing_warehouse):
		closing_warehouse.on_shared_storage_panel_closed(self)
	closed.emit()


func is_open() -> bool:
	return overlay.visible


func is_bound_to_warehouse(candidate: OakWarehouse) -> bool:
	return warehouse == candidate and candidate != null


func _reset_transient_state() -> void:
	_cancel_controller_drag()
	queued_quick_moves.clear()
	clear_multiplayer_slot_drop_pending()
	if get_viewport().gui_is_dragging():
		get_viewport().gui_cancel_drag()
	_clear_selection()
	multiplayer_storage_enabled = false
	multiplayer_storage_snapshot_ready = true
	multiplayer_storage_request_pending = false
	status_label.text = ""


func _unbind_warehouse() -> void:
	if warehouse != null and warehouse.storage_changed.is_connected(_refresh_all):
		warehouse.storage_changed.disconnect(_refresh_all)
	if tracked_player != null and tracked_player.died.is_connected(_on_tracked_player_died):
		tracked_player.died.disconnect(_on_tracked_player_died)
	if run_state.inventory_changed.is_connected(_refresh_all):
		run_state.inventory_changed.disconnect(_refresh_all)
	warehouse = null
	tracked_player = null


func _clear_slot_contents() -> void:
	for slot in storage_slots:
		slot.set_item(null, 0)
		slot.set_selected(false)
	for slot in player_slots:
		slot.set_item(null, 0)
		slot.set_selected(false)


func _input(event: InputEvent) -> void:
	if not overlay.visible:
		return
	var mouse_button := event as InputEventMouseButton
	if (
		mouse_button != null
		and mouse_button.button_index == MOUSE_BUTTON_LEFT
		and mouse_button.pressed
	):
		register_panel_mouse_press(mouse_button)
	var joy_button := event as InputEventJoypadButton
	var joy_motion := event as InputEventJoypadMotion
	if (joy_button != null or joy_motion != null) and get_viewport().gui_get_focus_owner() == null:
		_focus_first_item_slot()
	if joy_button != null and joy_button.is_action(&"ui_accept"):
		if joy_button.pressed:
			if _begin_controller_accept_hold(joy_button.device):
				get_viewport().set_input_as_handled()
				return
		elif controller_accept_held and joy_button.device == controller_device:
			_finish_controller_accept_hold()
			get_viewport().set_input_as_handled()
			return
	if (
		controller_accept_held
		and joy_motion != null
		and joy_motion.device == controller_device
		and joy_motion.axis in [JOY_AXIS_LEFT_X, JOY_AXIS_LEFT_Y]
	):
		get_viewport().set_input_as_handled()
		return
	if (
		event.is_action_pressed(&"quit")
		or event.is_action_pressed(&"ui_cancel")
		or event.is_action_pressed(&"bag")
		or event.is_action_pressed(&"interact")
	):
		close()
		get_viewport().set_input_as_handled()


func _process(delta: float) -> void:
	if not controller_drag_active or not overlay.visible:
		return
	var stick := Vector2(
		Input.get_joy_axis(controller_device, JOY_AXIS_LEFT_X),
		Input.get_joy_axis(controller_device, JOY_AXIS_LEFT_Y)
	)
	var strength := stick.length()
	if strength <= CONTROLLER_STICK_DEADZONE:
		return
	var normalized_strength := clampf(
		(strength - CONTROLLER_STICK_DEADZONE) / (1.0 - CONTROLLER_STICK_DEADZONE),
		0.0,
		1.0
	)
	var cursor_center := virtual_cursor.position + virtual_cursor.size * 0.5
	cursor_center += stick.normalized() * normalized_strength * CONTROLLER_CURSOR_SPEED * delta
	var cursor_radius := virtual_cursor.size * 0.5
	cursor_center.x = clampf(cursor_center.x, cursor_radius.x, DESIGN_SIZE.x - cursor_radius.x)
	cursor_center.y = clampf(cursor_center.y, cursor_radius.y, DESIGN_SIZE.y - cursor_radius.y)
	virtual_cursor.position = cursor_center - cursor_radius


func _begin_controller_accept_hold(device: int) -> bool:
	if controller_accept_held:
		return true
	var focus_owner := get_viewport().gui_get_focus_owner()
	var focused_slot := focus_owner as InventorySlot
	var source := ItemSource.NONE
	var slot_index := -1
	if focused_slot != null:
		slot_index = storage_slots.find(focused_slot)
		if slot_index >= 0:
			source = ItemSource.STORAGE
		else:
			slot_index = player_slots.find(focused_slot)
			if slot_index >= 0:
				source = ItemSource.PLAYER
	elif focus_owner == null:
		source = selected_source
		slot_index = selected_slot_index
	if source == ItemSource.NONE or slot_index < 0:
		return false
	var drag_data := make_slot_drag_data(source, slot_index)
	if drag_data.is_empty():
		return false
	controller_accept_held = true
	controller_device = device
	controller_drag_data = drag_data
	controller_hold_timer.start(CONTROLLER_HOLD_SECONDS)
	return true


func _finish_controller_accept_hold() -> void:
	if not controller_accept_held:
		return
	var drag_data := controller_drag_data.duplicate(true)
	var was_dragging := controller_drag_active
	var target := {
		"source": ItemSource.NONE,
		"slot_index": -1,
	}
	if was_dragging:
		target = _get_slot_at_panel_position(
			virtual_cursor.position + virtual_cursor.size * 0.5
		)
	_cancel_controller_drag()
	if was_dragging:
		var target_source := int(target["source"])
		var target_slot_index := int(target["slot_index"])
		if target_source != ItemSource.NONE:
			drop_slot_data(drag_data, target_source, target_slot_index)
		return
	if _drag_source_is_current(drag_data):
		_on_slot_activated(
			int(drag_data["source_slot_index"]),
			int(drag_data["source"])
		)
		call_deferred("_focus_first_item_slot")


func _on_controller_hold_timeout() -> void:
	if not controller_accept_held or not _drag_source_is_current(controller_drag_data):
		_cancel_controller_drag()
		return
	controller_drag_active = true
	var source := int(controller_drag_data["source"])
	var source_slot_index := int(controller_drag_data["source_slot_index"])
	var cursor_center := _get_slot_center_in_panel(source, source_slot_index)
	virtual_cursor.position = cursor_center - virtual_cursor.size * 0.5
	virtual_cursor.show()
	set_process(true)


func _cancel_controller_drag() -> void:
	controller_hold_timer.stop()
	controller_accept_held = false
	controller_drag_active = false
	controller_device = -1
	controller_drag_data.clear()
	virtual_cursor.hide()
	set_process(false)


func _on_joy_connection_changed(device: int, connected: bool) -> void:
	if not connected and controller_accept_held and controller_device == device:
		_cancel_controller_drag()


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT and controller_accept_held:
		_cancel_controller_drag()


func _focus_first_item_slot() -> void:
	if not overlay.visible:
		return
	for slot in storage_slots:
		if slot.item != null:
			slot.grab_focus()
			return
	for slot in player_slots:
		if slot.item != null:
			slot.grab_focus()
			return
	if not storage_slots.is_empty():
		storage_slots[0].grab_focus()


func _focus_slot(source: int, slot_index: int) -> void:
	if not overlay.visible:
		return
	var slot := _get_slot(source, slot_index)
	if slot != null:
		slot.grab_focus()
	else:
		_focus_first_item_slot()


func _get_slot_center_in_panel(source: int, slot_index: int) -> Vector2:
	var slot := _get_slot(source, slot_index)
	var grid := storage_grid if source == ItemSource.STORAGE else player_grid
	return grid.position + slot.position + slot.size * 0.5


func _get_slot_at_panel_position(panel_position: Vector2) -> Dictionary:
	for slot_index in range(storage_slots.size()):
		var slot := storage_slots[slot_index]
		if Rect2(storage_grid.position + slot.position, slot.size).has_point(panel_position):
			return {"source": ItemSource.STORAGE, "slot_index": slot_index}
	for slot_index in range(player_slots.size()):
		var slot := player_slots[slot_index]
		if Rect2(player_grid.position + slot.position, slot.size).has_point(panel_position):
			return {"source": ItemSource.PLAYER, "slot_index": slot_index}
	return {"source": ItemSource.NONE, "slot_index": -1}


func _unhandled_input(event: InputEvent) -> void:
	if not overlay.visible or selected_source == ItemSource.NONE:
		return
	if event is InputEventJoypadButton and event.is_action(&"ui_accept"):
		return
	if not event.is_action_pressed(&"ui_accept"):
		return
	if selected_source == ItemSource.PLAYER and _is_consumable_item(_get_selected_item()):
		_on_use_pressed()
	else:
		_on_move_pressed()
	get_viewport().set_input_as_handled()


func _collect_slots(
	grid: GridContainer,
	target: Array[InventorySlot],
	source: int
) -> void:
	target.clear()
	for child in grid.get_children():
		var slot := child as InventorySlot
		if slot == null:
			continue
		slot.slot_selected.connect(_on_slot_selected.bind(source))
		slot.item_activated.connect(_on_slot_activated.bind(source))
		slot.configure_drag_context(source, self)
		target.append(slot)


func register_panel_mouse_press(event: InputEventMouseButton) -> int:
	var stamped_sequences: Dictionary = event.get_meta(
		PANEL_MOUSE_PRESS_SEQUENCE_META,
		{}
	)
	var panel_id := get_instance_id()
	if stamped_sequences.has(panel_id):
		return int(stamped_sequences[panel_id])
	panel_mouse_press_sequence += 1
	stamped_sequences[panel_id] = panel_mouse_press_sequence
	event.set_meta(PANEL_MOUSE_PRESS_SEQUENCE_META, stamped_sequences)
	return panel_mouse_press_sequence


func make_slot_drag_data(source: int, slot_index: int) -> Dictionary:
	if (
		not overlay.visible
		or warehouse == null
		or source == ItemSource.NONE
		or _is_network_locked()
	):
		return {}
	var item := _get_item(source, slot_index)
	var count := _get_item_count(source, slot_index)
	if item == null or count <= 0:
		return {}
	_on_slot_selected(slot_index, source)
	return {
		"panel_instance_id": get_instance_id(),
		"panel_session_generation": panel_session_generation,
		"warehouse_instance_id": warehouse.get_instance_id(),
		"warehouse_net_id": warehouse.warehouse_net_id,
		"source": source,
		"source_slot_index": slot_index,
		"item_path": item.resource_path,
		"stack_count": count,
		"inventory_revision": _get_panel_inventory_revision(),
		"storage_revision": warehouse.get_storage_revision(),
	}


func get_slot_gesture_revision(_source: int) -> String:
	if warehouse == null:
		return ""
	return "%d:%d:%d:%d:%d:%d" % [
		panel_session_generation,
		warehouse.get_instance_id(),
		warehouse.warehouse_net_id,
		_get_panel_inventory_revision(),
		warehouse.get_storage_revision(),
		1 if _is_network_locked() else 0,
	]


func can_drop_slot_data(
	data: Variant,
	target_source: int,
	target_slot_index: int
) -> bool:
	if (
		typeof(data) != TYPE_DICTIONARY
		or warehouse == null
		or _is_network_locked()
		or target_source == ItemSource.NONE
	):
		return false
	var drag_data: Dictionary = data
	if not _drag_source_is_current(drag_data):
		return false
	var source := int(drag_data.get("source", ItemSource.NONE))
	var source_slot_index := int(drag_data.get("source_slot_index", -1))
	var peer_id := _get_storage_peer_id()
	return warehouse.can_move_stack_to_slot(
		_to_protocol_container(source),
		source_slot_index,
		_to_protocol_container(target_source),
		target_slot_index,
		run_state,
		int(drag_data.get("inventory_revision", -1)),
		int(drag_data.get("storage_revision", -1)),
		peer_id
	)


func drop_slot_data(
	data: Variant,
	target_source: int,
	target_slot_index: int
) -> void:
	if not can_drop_slot_data(data, target_source, target_slot_index):
		return
	var drag_data: Dictionary = data
	var moved := false
	if multiplayer_storage_enabled:
		multiplayer_slot_drop_pending = true
		multiplayer_slot_drop_source = int(drag_data["source"])
		multiplayer_slot_drop_source_index = int(drag_data["source_slot_index"])
		multiplayer_slot_drop_target = target_source
		multiplayer_slot_drop_target_index = target_slot_index
		moved = warehouse.request_multiplayer_slot_move(
			_to_protocol_container(int(drag_data["source"])),
			int(drag_data["source_slot_index"]),
			_to_protocol_container(target_source),
			target_slot_index,
			int(drag_data["inventory_revision"]),
			int(drag_data["storage_revision"])
		)
		if not moved:
			clear_multiplayer_slot_drop_pending()
	else:
		moved = warehouse.move_stack_to_slot(
			_to_protocol_container(int(drag_data["source"])),
			int(drag_data["source_slot_index"]),
			_to_protocol_container(target_source),
			target_slot_index,
			run_state,
			int(drag_data["inventory_revision"]),
			int(drag_data["storage_revision"])
		)
	if not moved:
		return
	if not multiplayer_storage_enabled:
		status_label.text = "物品已移动"
		_clear_selection()
	_get_slot(target_source, target_slot_index).grab_focus()


func _refresh_all() -> void:
	for slot_index in range(storage_slots.size()):
		var item: PickupConfig = null
		var count := 0
		if warehouse != null:
			item = warehouse.get_storage_item(slot_index)
			count = warehouse.get_storage_item_count(slot_index)
		storage_slots[slot_index].set_item(item, count)
		storage_slots[slot_index].set_selected(
			selected_source == ItemSource.STORAGE and selected_slot_index == slot_index
		)

	for slot_index in range(player_slots.size()):
		player_slots[slot_index].set_item(
			run_state.get_item(slot_index),
			run_state.get_item_count(slot_index)
		)
		player_slots[slot_index].set_selected(
			selected_source == ItemSource.PLAYER and selected_slot_index == slot_index
		)

	if selected_source != ItemSource.NONE and _get_selected_item() == null:
		_clear_selection()
	else:
		_refresh_detail()


func _on_slot_selected(slot_index: int, source: int) -> void:
	var item := _get_item(source, slot_index)
	if item == null:
		_clear_selection(false)
		return
	selected_source = source
	selected_slot_index = slot_index
	status_label.text = ""
	_refresh_all()


func _on_slot_activated(slot_index: int, source: int) -> void:
	_on_slot_selected(slot_index, source)
	if selected_source == source and selected_slot_index == slot_index:
		_on_move_pressed()


func _on_use_pressed() -> void:
	if _is_multiplayer_inventory_context():
		status_label.text = "请在背包界面使用该物品"
		return
	if selected_source != ItemSource.PLAYER or selected_slot_index < 0:
		return
	var item := _get_selected_item()
	if not _is_consumable_item(item) or tracked_player == null:
		return
	if run_state.try_use_item(selected_slot_index, tracked_player):
		status_label.text = "已使用 %s" % item.display_name
	else:
		status_label.text = "当前无法使用该物品"
	_refresh_all()


func _on_move_pressed() -> void:
	if warehouse == null or selected_slot_index < 0:
		return
	if _is_waiting_for_multiplayer_storage_configuration():
		status_label.text = "正在同步共享仓库…"
		_refresh_detail()
		return
	if multiplayer_storage_enabled:
		if not multiplayer_storage_snapshot_ready:
			status_label.text = "正在同步共享仓库…"
			return
		if multiplayer_storage_request_pending:
			_queue_selected_quick_move()
			status_label.text = "正在等待主机确认…"
			return
		var direction := (
			OakWarehouseProtocol.TransferDirection.STORAGE_TO_PLAYER
			if selected_source == ItemSource.STORAGE
			else OakWarehouseProtocol.TransferDirection.PLAYER_TO_STORAGE
		)
		if warehouse.request_multiplayer_stack_transfer(direction, selected_slot_index):
			status_label.text = "正在等待主机确认…"
		else:
			status_label.text = "共享仓库当前不可操作"
		_refresh_detail()
		return
	var moved := false
	if selected_source == ItemSource.STORAGE:
		moved = warehouse.transfer_storage_stack_to_player(selected_slot_index, run_state)
	elif selected_source == ItemSource.PLAYER:
		moved = warehouse.transfer_player_stack_to_storage(selected_slot_index, run_state)
	status_label.text = "物品已移动" if moved else "目标容器空间不足"
	if moved:
		_clear_selection()
	_refresh_all()


func _queue_selected_quick_move() -> void:
	if (
		selected_source == ItemSource.NONE
		or selected_slot_index < 0
		or queued_quick_moves.size() >= MAX_QUEUED_QUICK_MOVES
	):
		return
	var item := _get_selected_item()
	var count := _get_selected_count()
	if item == null or count <= 0:
		return
	var intent := {
		"source": selected_source,
		"slot_index": selected_slot_index,
		"item_path": item.resource_path,
		"stack_count": count,
	}
	if not queued_quick_moves.is_empty() and queued_quick_moves.back() == intent:
		return
	queued_quick_moves.append(intent)


func _process_next_queued_quick_move() -> void:
	if (
		not overlay.visible
		or not multiplayer_storage_enabled
		or _is_network_locked()
	):
		return
	while not queued_quick_moves.is_empty():
		var intent: Dictionary = queued_quick_moves.pop_front()
		var source := int(intent.get("source", ItemSource.NONE))
		var slot_index := int(intent.get("slot_index", -1))
		var item := _get_item(source, slot_index)
		if (
			item == null
			or item.resource_path != str(intent.get("item_path", ""))
			or _get_item_count(source, slot_index) != int(intent.get("stack_count", 0))
		):
			continue
		_on_slot_selected(slot_index, source)
		_on_move_pressed()
		return


func _on_discard_pressed() -> void:
	if selected_slot_index < 0:
		return
	if _is_multiplayer_inventory_context():
		status_label.text = (
			"共享仓库物品不能直接删除，请先取回背包"
			if selected_source == ItemSource.STORAGE
			else "多人模式请在背包界面管理物品"
		)
		return
	var item := _get_selected_item()
	var discarded := false
	if selected_source == ItemSource.STORAGE and warehouse != null:
		discarded = warehouse.discard_storage_item(selected_slot_index)
	elif selected_source == ItemSource.PLAYER:
		discarded = run_state.discard_item(selected_slot_index)
	if discarded:
		status_label.text = "已删除 %s" % item.display_name
		_clear_selection()
	_refresh_all()


func _on_overlay_gui_input(event: InputEvent) -> void:
	var mouse_event := event as InputEventMouseButton
	if mouse_event == null:
		return
	if mouse_event.button_index != MOUSE_BUTTON_LEFT or not mouse_event.pressed:
		return
	_clear_selection()
	overlay.accept_event()


func _clear_selection(release_focus: bool = true) -> void:
	if controller_accept_held:
		_cancel_controller_drag()
	selected_source = ItemSource.NONE
	selected_slot_index = -1
	for slot in storage_slots:
		slot.set_selected(false)
	for slot in player_slots:
		slot.set_selected(false)
	_refresh_detail()
	if release_focus:
		get_viewport().gui_release_focus()


func _refresh_detail() -> void:
	var item := _get_selected_item()
	if item == null:
		item_title.text = "选择一个物品查看详情"
		item_category.text = ""
		item_description.text = "双击可快速移动；也可拖拽到目标格。手柄长按 A 后用左摇杆移动。"
		item_description.tooltip_text = item_description.text
		use_button.disabled = true
		move_button.disabled = true
		discard_button.disabled = true
		move_button.text = "移动"
		return

	var count := _get_selected_count()
	item_title.text = (
		"%s ×%d" % [item.display_name, count]
		if count > 1
		else item.display_name
	)
	item_category.text = "%s · %s" % [
		_get_item_type_label(item),
		"仓库" if selected_source == ItemSource.STORAGE else "背包",
	]
	item_description.text = item.description if not item.description.is_empty() else "暂无描述"
	item_description.tooltip_text = item_description.text
	var network_locked := _is_network_locked()
	use_button.disabled = (
		_is_multiplayer_inventory_context()
		or selected_source != ItemSource.PLAYER
		or not _is_consumable_item(item)
	)
	move_button.disabled = network_locked
	discard_button.disabled = _is_multiplayer_inventory_context() or network_locked
	move_button.text = "移入背包" if selected_source == ItemSource.STORAGE else "移入仓库"
	discard_button.text = "删除" if item.pickup_type == PickupConfig.PickupType.MATERIAL else "丢弃"


func _on_tracked_player_died() -> void:
	close()


func _get_multiplayer_failure_text(reason: StringName) -> String:
	match reason:
		OakWarehouseProtocol.RESULT_STALE_INVENTORY, OakWarehouseProtocol.RESULT_STALE_STORAGE:
			return "内容已变化，已刷新最新状态"
		OakWarehouseProtocol.RESULT_SOURCE_EMPTY:
			return "来源物品已不存在"
		OakWarehouseProtocol.RESULT_TARGET_FULL:
			return "目标容器空间不足"
		_:
			return "共享仓库操作失败"


func _get_selected_item() -> PickupConfig:
	return _get_item(selected_source, selected_slot_index)


func _get_selected_count() -> int:
	if selected_source == ItemSource.STORAGE and warehouse != null:
		return warehouse.get_storage_item_count(selected_slot_index)
	if selected_source == ItemSource.PLAYER:
		return run_state.get_item_count(selected_slot_index)
	return 0


func _get_item_count(source: int, slot_index: int) -> int:
	if source == ItemSource.STORAGE and warehouse != null:
		return warehouse.get_storage_item_count(slot_index)
	if source == ItemSource.PLAYER:
		return run_state.get_item_count(slot_index)
	return 0


func _get_item(source: int, slot_index: int) -> PickupConfig:
	if slot_index < 0:
		return null
	if source == ItemSource.STORAGE and warehouse != null:
		return warehouse.get_storage_item(slot_index)
	if source == ItemSource.PLAYER:
		return run_state.get_item(slot_index)
	return null


func _get_slot(source: int, slot_index: int) -> InventorySlot:
	if source == ItemSource.STORAGE and slot_index >= 0 and slot_index < storage_slots.size():
		return storage_slots[slot_index]
	if source == ItemSource.PLAYER and slot_index >= 0 and slot_index < player_slots.size():
		return player_slots[slot_index]
	return null


func _drag_source_is_current(data: Dictionary) -> bool:
	if (
		data.is_empty()
		or warehouse == null
		or int(data.get("panel_instance_id", 0)) != get_instance_id()
		or int(data.get("panel_session_generation", -1)) != panel_session_generation
		or int(data.get("warehouse_instance_id", 0)) != warehouse.get_instance_id()
		or int(data.get("warehouse_net_id", -1)) != warehouse.warehouse_net_id
		or int(data.get("inventory_revision", -1)) != _get_panel_inventory_revision()
		or int(data.get("storage_revision", -1)) != warehouse.get_storage_revision()
	):
		return false
	var source := int(data.get("source", ItemSource.NONE))
	var source_slot_index := int(data.get("source_slot_index", -1))
	var item := _get_item(source, source_slot_index)
	return (
		item != null
		and item.resource_path == str(data.get("item_path", ""))
		and _get_item_count(source, source_slot_index) == int(data.get("stack_count", 0))
	)


func _is_network_locked() -> bool:
	if _is_waiting_for_multiplayer_storage_configuration():
		return true
	return (
		multiplayer_storage_enabled
		and (
			not multiplayer_storage_snapshot_ready
			or multiplayer_storage_request_pending
		)
	)


func _is_multiplayer_inventory_context() -> bool:
	return multiplayer_storage_enabled or run_state.active_multiplayer_peer_id > 0


func _is_waiting_for_multiplayer_storage_configuration() -> bool:
	return run_state.active_multiplayer_peer_id > 0 and not multiplayer_storage_enabled


func _get_storage_peer_id() -> int:
	if multiplayer_storage_enabled and warehouse != null:
		return warehouse.multiplayer_storage_peer_id
	return 0


func _get_panel_inventory_revision() -> int:
	var peer_id := _get_storage_peer_id()
	if peer_id > 0:
		return run_state.get_inventory_revision_for_peer(peer_id)
	return run_state.get_inventory_revision()


func _to_protocol_container(source: int) -> int:
	if source == ItemSource.STORAGE:
		return OakWarehouseProtocol.ItemContainer.STORAGE
	if source == ItemSource.PLAYER:
		return OakWarehouseProtocol.ItemContainer.PLAYER
	return -1


func _is_consumable_item(item: PickupConfig) -> bool:
	return (
		item != null
		and item.pickup_type != PickupConfig.PickupType.COLLECTIBLE
		and item.pickup_type != PickupConfig.PickupType.MATERIAL
	)


func _get_item_type_label(item: PickupConfig) -> String:
	if item.pickup_type == PickupConfig.PickupType.COLLECTIBLE:
		return "收藏品"
	if item.pickup_type == PickupConfig.PickupType.MATERIAL:
		return "物资"
	return "道具"


func _update_panel_transform() -> void:
	var viewport_size := Vector2(get_viewport().get_visible_rect().size)
	var scale_factor := minf(
		viewport_size.x / DESIGN_SIZE.x,
		viewport_size.y / DESIGN_SIZE.y
	) * 0.94
	scale_factor = minf(scale_factor, 1.0)
	panel_root.scale = Vector2.ONE * scale_factor
	panel_root.position = (viewport_size - DESIGN_SIZE * scale_factor) * 0.5
