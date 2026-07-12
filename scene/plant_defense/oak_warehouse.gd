extends PlantDefense
class_name OakWarehouse

signal storage_changed

const STORAGE_CAPACITY := RunStateStore.INVENTORY_CAPACITY

@onready var interaction_area: Area2D = $InteractionArea
@onready var interaction_prompt: Control = $InteractionPrompt
@onready var storage_panel: OakWarehousePanel = $OakWarehousePanel
@onready var health_bar: Control = $HealthBar

var storage_items: Array[PickupConfig] = []
var storage_stack_counts: Array[int] = []
var nearby_player: Player = null


func _ready() -> void:
	super._ready()
	storage_items.resize(STORAGE_CAPACITY)
	storage_stack_counts.resize(STORAGE_CAPACITY)
	storage_stack_counts.fill(0)
	interaction_prompt.hide()
	set_process_unhandled_input(false)
	interaction_area.body_entered.connect(_on_interaction_area_body_entered)
	interaction_area.body_exited.connect(_on_interaction_area_body_exited)
	storage_panel.opened.connect(_on_storage_panel_opened)
	storage_panel.closed.connect(_on_storage_panel_closed)


func _on_setup_completed() -> void:
	super._on_setup_completed()
	health_bar.call("setup", max_health, current_health)
	health_changed.connect(_on_health_changed)
	storage_panel.bind_warehouse(self, owner_player)
	if owner_player != null and not owner_player.died.is_connected(_on_owner_player_died):
		owner_player.died.connect(_on_owner_player_died)


func _unhandled_input(event: InputEvent) -> void:
	if nearby_player == null or storage_panel.is_open():
		return
	if not event.is_action_pressed(&"interact"):
		return
	if nearby_player.controls_locked or nearby_player.is_dead:
		return

	get_viewport().set_input_as_handled()
	storage_panel.bind_warehouse(self, nearby_player)
	storage_panel.open()


func is_modal_ui_open() -> bool:
	return storage_panel != null and storage_panel.is_open()


func get_storage_item(slot_index: int) -> PickupConfig:
	if slot_index < 0 or slot_index >= STORAGE_CAPACITY:
		return null
	return storage_items[slot_index]


func get_storage_item_count(slot_index: int) -> int:
	if slot_index < 0 or slot_index >= STORAGE_CAPACITY:
		return 0
	if storage_items[slot_index] == null:
		return 0
	return maxi(storage_stack_counts[slot_index], 1)


func can_add_storage_item_count(item: PickupConfig, count: int) -> bool:
	if item == null or not item.can_store_in_inventory or count <= 0:
		return false
	return _get_available_storage_capacity(item) >= count


func try_add_storage_item_count(item: PickupConfig, count: int) -> bool:
	if not can_add_storage_item_count(item, count):
		return false

	var remaining := count
	var stack_limit := _get_stack_limit(item)
	if item.stackable:
		for slot_index in range(STORAGE_CAPACITY):
			if not _items_share_stack(storage_items[slot_index], item):
				continue
			var room := maxi(stack_limit - storage_stack_counts[slot_index], 0)
			var added := mini(room, remaining)
			storage_stack_counts[slot_index] += added
			remaining -= added
			if remaining <= 0:
				storage_changed.emit()
				return true

	for slot_index in range(STORAGE_CAPACITY):
		if storage_items[slot_index] != null:
			continue
		var added := mini(stack_limit, remaining)
		storage_items[slot_index] = item
		storage_stack_counts[slot_index] = added
		remaining -= added
		if remaining <= 0:
			storage_changed.emit()
			return true
	return false


func discard_storage_item(slot_index: int) -> bool:
	if slot_index < 0 or slot_index >= STORAGE_CAPACITY:
		return false
	if storage_items[slot_index] == null:
		return false
	storage_items[slot_index] = null
	storage_stack_counts[slot_index] = 0
	storage_changed.emit()
	return true


func transfer_player_stack_to_storage(slot_index: int, run_state: RunStateStore) -> bool:
	if run_state == null:
		return false
	var item := run_state.get_item(slot_index)
	var count := run_state.get_item_count(slot_index)
	if not can_add_storage_item_count(item, count):
		return false
	if not run_state.discard_item(slot_index):
		return false
	return try_add_storage_item_count(item, count)


func transfer_storage_stack_to_player(slot_index: int, run_state: RunStateStore) -> bool:
	if run_state == null:
		return false
	var item := get_storage_item(slot_index)
	var count := get_storage_item_count(slot_index)
	if item == null or count <= 0:
		return false
	if not run_state.try_add_item_count(item, count):
		return false
	return discard_storage_item(slot_index)


func _get_available_storage_capacity(item: PickupConfig) -> int:
	var stack_limit := _get_stack_limit(item)
	var capacity := 0
	for slot_index in range(STORAGE_CAPACITY):
		var stored_item := storage_items[slot_index]
		if stored_item == null:
			capacity += stack_limit
		elif item.stackable and _items_share_stack(stored_item, item):
			capacity += maxi(stack_limit - storage_stack_counts[slot_index], 0)
	return capacity


func _items_share_stack(existing_item: PickupConfig, incoming_item: PickupConfig) -> bool:
	if existing_item == null or incoming_item == null or not incoming_item.stackable:
		return false
	if existing_item == incoming_item:
		return true
	return (
		not existing_item.resource_path.is_empty()
		and existing_item.resource_path == incoming_item.resource_path
	)


func _get_stack_limit(item: PickupConfig) -> int:
	if item == null or not item.stackable:
		return 1
	return clampi(item.inventory_stack_limit, 1, 999)


func _on_interaction_area_body_entered(body: Node2D) -> void:
	var player := body as Player
	if player == null or not player.uses_local_input or player.is_dead:
		return
	nearby_player = player
	interaction_prompt.visible = not storage_panel.is_open()
	set_process_unhandled_input(true)


func _on_interaction_area_body_exited(body: Node2D) -> void:
	if body != nearby_player:
		return
	nearby_player = null
	interaction_prompt.hide()
	set_process_unhandled_input(false)
	storage_panel.close()


func _on_storage_panel_opened() -> void:
	interaction_prompt.hide()
	set_process_unhandled_input(false)
	modal_ui_visibility_changed.emit(true)


func _on_storage_panel_closed() -> void:
	interaction_prompt.visible = nearby_player != null and not is_dead
	set_process_unhandled_input(nearby_player != null and not is_dead)
	modal_ui_visibility_changed.emit(false)


func _on_health_changed(new_health: int, new_max_health: int) -> void:
	health_bar.call("set_health", new_health, new_max_health)


func _on_owner_player_died() -> void:
	storage_panel.close()


func _on_death_started() -> void:
	interaction_area.set_deferred("monitoring", false)
	interaction_prompt.hide()
	storage_panel.close()
	super._on_death_started()
