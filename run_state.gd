extends Node

signal inventory_changed

const INVENTORY_CAPACITY := 20

var inventory: Array[PickupConfig] = []
var run_started := false


func begin_new_run() -> void:
	inventory.clear()
	inventory.resize(INVENTORY_CAPACITY)
	run_started = true
	inventory_changed.emit()


func ensure_run_started() -> void:
	if run_started:
		return
	begin_new_run()


func try_add_item(item: PickupConfig) -> bool:
	ensure_run_started()
	if item == null or not item.can_store_in_inventory:
		return false

	for slot_index in range(inventory.size()):
		if inventory[slot_index] == null:
			inventory[slot_index] = item
			inventory_changed.emit()
			return true

	return false


func try_use_item(slot_index: int, player: Player) -> bool:
	if player == null:
		return false
	if slot_index < 0 or slot_index >= inventory.size():
		return false

	var item := inventory[slot_index]
	if item == null:
		return false
	if not player.apply_pickup(item):
		return false

	inventory[slot_index] = null
	inventory_changed.emit()
	return true


func get_item(slot_index: int) -> PickupConfig:
	if slot_index < 0 or slot_index >= inventory.size():
		return null
	return inventory[slot_index]

