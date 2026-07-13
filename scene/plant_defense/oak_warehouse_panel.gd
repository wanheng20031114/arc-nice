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


func _ready() -> void:
	overlay.hide()
	set_process_input(false)
	set_process_unhandled_input(false)
	_collect_slots(storage_grid, storage_slots, ItemSource.STORAGE)
	_collect_slots(player_grid, player_slots, ItemSource.PLAYER)
	use_button.pressed.connect(_on_use_pressed)
	move_button.pressed.connect(_on_move_pressed)
	discard_button.pressed.connect(_on_discard_pressed)
	close_button.pressed.connect(close)
	overlay.gui_input.connect(_on_overlay_gui_input)
	get_viewport().size_changed.connect(_update_panel_transform)
	run_state.ensure_run_started()
	run_state.inventory_changed.connect(_refresh_all)
	_update_panel_transform()
	_refresh_detail()


func bind_warehouse(new_warehouse: OakWarehouse, player: Player) -> void:
	if warehouse != null and warehouse.storage_changed.is_connected(_refresh_all):
		warehouse.storage_changed.disconnect(_refresh_all)
	if tracked_player != null and tracked_player.died.is_connected(_on_tracked_player_died):
		tracked_player.died.disconnect(_on_tracked_player_died)
	warehouse = new_warehouse
	tracked_player = player
	if tracked_player != null and not tracked_player.died.is_connected(_on_tracked_player_died):
		tracked_player.died.connect(_on_tracked_player_died)
	if warehouse != null and not warehouse.storage_changed.is_connected(_refresh_all):
		warehouse.storage_changed.connect(_refresh_all)
	_refresh_all()


func set_multiplayer_storage_state(
	enabled: bool,
	snapshot_ready: bool,
	request_pending: bool
) -> void:
	multiplayer_storage_enabled = enabled
	multiplayer_storage_snapshot_ready = snapshot_ready or not enabled
	multiplayer_storage_request_pending = request_pending and enabled
	if multiplayer_storage_enabled and not multiplayer_storage_snapshot_ready:
		status_label.text = "正在同步共享仓库…"
	elif multiplayer_storage_request_pending:
		status_label.text = "正在等待主机确认…"
	elif status_label.text in ["正在同步共享仓库…", "正在等待主机确认…"]:
		status_label.text = ""
	_refresh_detail()


func show_multiplayer_command_result(success: bool, reason: StringName) -> void:
	if success:
		status_label.text = "物品已移动"
	else:
		status_label.text = _get_multiplayer_failure_text(reason)
	_clear_selection()
	_refresh_all()


func open() -> void:
	if warehouse == null or tracked_player == null or tracked_player.is_dead:
		return
	if overlay.visible:
		return
	overlay.show()
	set_process_input(true)
	set_process_unhandled_input(true)
	tracked_player.set_controls_locked(true)
	_clear_selection()
	_refresh_all()
	opened.emit()


func close() -> void:
	if not overlay.visible:
		return
	overlay.hide()
	set_process_input(false)
	set_process_unhandled_input(false)
	_clear_selection()
	if tracked_player != null and not tracked_player.is_dead:
		tracked_player.set_controls_locked(false)
	closed.emit()


func is_open() -> bool:
	return overlay.visible


func _input(event: InputEvent) -> void:
	if not overlay.visible:
		return
	if (
		event.is_action_pressed(&"quit")
		or event.is_action_pressed(&"ui_cancel")
		or event.is_action_pressed(&"bag")
		or event.is_action_pressed(&"interact")
	):
		close()
		get_viewport().set_input_as_handled()


func _unhandled_input(event: InputEvent) -> void:
	if not overlay.visible or selected_source == ItemSource.NONE:
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
		target.append(slot)


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
		_clear_selection()
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
	if multiplayer_storage_enabled:
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
	if multiplayer_storage_enabled:
		if not multiplayer_storage_snapshot_ready:
			status_label.text = "正在同步共享仓库…"
			return
		if multiplayer_storage_request_pending:
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


func _on_discard_pressed() -> void:
	if selected_slot_index < 0:
		return
	if multiplayer_storage_enabled:
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


func _clear_selection() -> void:
	selected_source = ItemSource.NONE
	selected_slot_index = -1
	for slot in storage_slots:
		slot.set_selected(false)
	for slot in player_slots:
		slot.set_selected(false)
	_refresh_detail()
	get_viewport().gui_release_focus()


func _refresh_detail() -> void:
	var item := _get_selected_item()
	if item == null:
		item_title.text = "选择一个物品查看详情"
		item_category.text = ""
		item_description.text = "双击物品，可在仓库与背包间快速移动。"
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
	var network_locked := (
		multiplayer_storage_enabled
		and (
			not multiplayer_storage_snapshot_ready
			or multiplayer_storage_request_pending
		)
	)
	use_button.disabled = (
		multiplayer_storage_enabled
		or selected_source != ItemSource.PLAYER
		or not _is_consumable_item(item)
	)
	move_button.disabled = network_locked
	discard_button.disabled = multiplayer_storage_enabled or network_locked
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


func _get_item(source: int, slot_index: int) -> PickupConfig:
	if slot_index < 0:
		return null
	if source == ItemSource.STORAGE and warehouse != null:
		return warehouse.get_storage_item(slot_index)
	if source == ItemSource.PLAYER:
		return run_state.get_item(slot_index)
	return null


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
