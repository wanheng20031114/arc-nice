extends CanvasLayer
class_name PlayerProfilePanel

const DESIGN_SIZE := Vector2(724.0, 543.0)

@onready var overlay: Control = $Overlay
@onready var panel_root: Control = $Overlay/PanelRoot
@onready var close_button: Button = $Overlay/PanelRoot/CloseButton
@onready var portrait: AnimatedSprite2D = $Overlay/PanelRoot/Portrait
@onready var attack_value: Label = $Overlay/PanelRoot/AttackValue
@onready var health_value: Label = $Overlay/PanelRoot/HealthValue
@onready var method_value: Label = $Overlay/PanelRoot/MethodValue
@onready var inventory_grid: GridContainer = $Overlay/PanelRoot/InventoryGrid
@onready var run_state: Node = get_node("/root/RunState")

var tracked_player: Player = null
var slots: Array[InventorySlot] = []
var selected_slot_index := -1


func _ready() -> void:
	overlay.visible = false
	close_button.pressed.connect(close)
	get_viewport().size_changed.connect(_update_panel_transform)
	_collect_slots()
	_update_panel_transform()
	run_state.ensure_run_started()
	run_state.inventory_changed.connect(_refresh_inventory)


func bind_player(player: Player) -> void:
	if tracked_player != null:
		if overlay.visible:
			close()
		if tracked_player.health_changed.is_connected(_on_health_changed):
			tracked_player.health_changed.disconnect(_on_health_changed)
		if tracked_player.died.is_connected(_on_player_died):
			tracked_player.died.disconnect(_on_player_died)

	tracked_player = player
	if tracked_player == null:
		close()
		return

	tracked_player.health_changed.connect(_on_health_changed)
	tracked_player.died.connect(_on_player_died)
	portrait.sprite_frames = tracked_player.body_sprite.sprite_frames
	portrait.play(&"normal_down")
	attack_value.text = str(tracked_player.attack_damage)
	method_value.text = tracked_player.attack_method_name
	_on_health_changed(tracked_player.current_health, tracked_player.max_health)
	_refresh_inventory()


func open() -> void:
	if tracked_player == null or tracked_player.is_dead:
		return
	if overlay.visible:
		return

	overlay.visible = true
	tracked_player.set_controls_locked(true)
	_refresh_inventory()
	_focus_first_available_slot()


func close() -> void:
	if not overlay.visible:
		return

	overlay.visible = false
	selected_slot_index = -1
	get_viewport().gui_release_focus()
	if tracked_player != null and not tracked_player.is_dead:
		tracked_player.set_controls_locked(false)


func toggle() -> void:
	if overlay.visible:
		close()
	else:
		open()


func is_open() -> bool:
	return overlay.visible


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("bag"):
		toggle()
		get_viewport().set_input_as_handled()
		return

	if not overlay.visible:
		return

	if event.is_action_pressed("quit") or event.is_action_pressed("ui_cancel"):
		close()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("ui_accept") and selected_slot_index >= 0:
		_try_use_slot(selected_slot_index)
		get_viewport().set_input_as_handled()


func _collect_slots() -> void:
	slots.clear()
	for child in inventory_grid.get_children():
		var slot := child as InventorySlot
		if slot == null:
			continue
		slot.slot_selected.connect(_on_slot_selected)
		slot.item_activated.connect(_try_use_slot)
		slots.append(slot)


func _refresh_inventory() -> void:
	for slot_index in range(slots.size()):
		slots[slot_index].set_item(run_state.get_item(slot_index))
		slots[slot_index].set_selected(slot_index == selected_slot_index)


func _on_slot_selected(slot_index: int) -> void:
	selected_slot_index = slot_index
	for slot in slots:
		slot.set_selected(slot.slot_index == selected_slot_index)


func _try_use_slot(slot_index: int) -> void:
	selected_slot_index = slot_index
	if run_state.try_use_item(slot_index, tracked_player):
		_refresh_inventory()


func _focus_first_available_slot() -> void:
	for slot in slots:
		if slot.item != null:
			selected_slot_index = slot.slot_index
			slot.grab_focus()
			_refresh_inventory()
			return

	selected_slot_index = 0
	if not slots.is_empty():
		slots[0].grab_focus()
		_refresh_inventory()


func _on_health_changed(current: int, maximum: int) -> void:
	health_value.text = "%d / %d" % [current, maximum]


func _on_player_died() -> void:
	close()


func _update_panel_transform() -> void:
	var viewport_size := Vector2(get_viewport().get_visible_rect().size)
	var scale_factor := minf(
		viewport_size.x / DESIGN_SIZE.x,
		viewport_size.y / DESIGN_SIZE.y
	) * 0.94
	scale_factor = minf(scale_factor, 1.0)
	panel_root.scale = Vector2.ONE * scale_factor
	panel_root.position = (viewport_size - DESIGN_SIZE * scale_factor) * 0.5
