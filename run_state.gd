extends Node

signal inventory_changed
signal upgrade_changed

const INVENTORY_CAPACITY := 20
const UPGRADE_COST := 100

enum StatType {
	ATTACK,
	HEALTH,
	ATTACK_SPEED,
	DODGE,
}

const MAX_UPGRADE_LEVELS := {
	StatType.ATTACK: 2,
	StatType.HEALTH: 5,
	StatType.ATTACK_SPEED: 5,
	StatType.DODGE: 5,
}

var inventory: Array[PickupConfig] = []
var run_started := false
var upgrade_levels := {
	StatType.ATTACK: 0,
	StatType.HEALTH: 0,
	StatType.ATTACK_SPEED: 0,
	StatType.DODGE: 0,
}


func begin_new_run() -> void:
	inventory.clear()
	inventory.resize(INVENTORY_CAPACITY)
	for stat_type: int in upgrade_levels:
		upgrade_levels[stat_type] = 0
	run_started = true
	inventory_changed.emit()
	upgrade_changed.emit()


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


func try_upgrade(stat_type: int, player: Player) -> bool:
	if player == null:
		return false
	if not upgrade_levels.has(stat_type):
		return false

	var current_level: int = upgrade_levels[stat_type]
	var max_level: int = MAX_UPGRADE_LEVELS.get(stat_type, 0)
	if current_level >= max_level:
		return false
	if player.current_xirang < UPGRADE_COST:
		return false

	player.current_xirang -= UPGRADE_COST
	player.xirang_changed.emit(player.current_xirang, -UPGRADE_COST)
	upgrade_levels[stat_type] = current_level + 1

	match stat_type:
		StatType.ATTACK:
			player.upgrade_attack()
		StatType.HEALTH:
			player.upgrade_max_health()
		StatType.ATTACK_SPEED:
			player.upgrade_attack_speed()
		StatType.DODGE:
			player.upgrade_dodge()

	upgrade_changed.emit()
	return true


func get_upgrade_level(stat_type: int) -> int:
	return upgrade_levels.get(stat_type, 0)


func get_max_upgrade_level(stat_type: int) -> int:
	return MAX_UPGRADE_LEVELS.get(stat_type, 0)
