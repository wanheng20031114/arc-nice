extends Node
class_name RunStateStore

signal inventory_changed
signal upgrade_changed

const INVENTORY_CAPACITY := 20

enum StatType {
	ATTACK,
	HEALTH,
	ATTACK_SPEED,
	DODGE,
}

const MAX_UPGRADE_LEVELS := {
	StatType.ATTACK: 5,
	StatType.HEALTH: 5,
	StatType.ATTACK_SPEED: 5,
	StatType.DODGE: 5,
}

const UPGRADE_COSTS := {
	StatType.ATTACK: [100, 300, 500, 800, 1200],
	StatType.HEALTH: [50, 75, 100, 200, 500],
	StatType.ATTACK_SPEED: [50, 75, 100, 200, 500],
	StatType.DODGE: [50, 75, 100, 200, 500],
}

var inventory: Array[PickupConfig] = []
var run_started := false
var upgrade_levels := {
	StatType.ATTACK: 0,
	StatType.HEALTH: 0,
	StatType.ATTACK_SPEED: 0,
	StatType.DODGE: 0,
}
var active_multiplayer_peer_id: int = 0
var multiplayer_inventories: Dictionary = {}
var multiplayer_upgrade_levels: Dictionary = {}


func begin_new_run() -> void:
	inventory.clear()
	inventory.resize(INVENTORY_CAPACITY)
	for stat_type: int in upgrade_levels:
		upgrade_levels[stat_type] = 0
	active_multiplayer_peer_id = 0
	multiplayer_inventories.clear()
	multiplayer_upgrade_levels.clear()
	run_started = true
	inventory_changed.emit()
	upgrade_changed.emit()


func ensure_run_started() -> void:
	if run_started:
		return
	begin_new_run()


func try_add_item(item: PickupConfig) -> bool:
	ensure_run_started()
	if active_multiplayer_peer_id > 0:
		return try_add_item_for_peer(active_multiplayer_peer_id, item)
	if item == null or not item.can_store_in_inventory:
		return false

	for slot_index in range(inventory.size()):
		if inventory[slot_index] == null:
			inventory[slot_index] = item
			inventory_changed.emit()
			return true

	return false


func try_use_item(slot_index: int, player: Player) -> bool:
	if active_multiplayer_peer_id > 0:
		return try_use_item_for_peer(active_multiplayer_peer_id, slot_index, player)
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
	if active_multiplayer_peer_id > 0:
		return get_item_for_peer(active_multiplayer_peer_id, slot_index)
	if slot_index < 0 or slot_index >= inventory.size():
		return null
	return inventory[slot_index]


func try_upgrade(stat_type: int, player: Player) -> bool:
	if active_multiplayer_peer_id > 0:
		return try_upgrade_for_peer(active_multiplayer_peer_id, stat_type, player)
	if player == null:
		return false
	if not upgrade_levels.has(stat_type):
		return false

	var current_level: int = upgrade_levels[stat_type]
	var max_level: int = MAX_UPGRADE_LEVELS.get(stat_type, 0)
	if current_level >= max_level:
		return false
	var upgrade_cost := get_upgrade_cost(stat_type)
	if upgrade_cost < 0 or player.current_xirang < upgrade_cost:
		return false

	player.current_xirang -= upgrade_cost
	player.xirang_changed.emit(player.current_xirang, -upgrade_cost)
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
	if active_multiplayer_peer_id > 0:
		return get_upgrade_level_for_peer(active_multiplayer_peer_id, stat_type)
	return upgrade_levels.get(stat_type, 0)


func get_max_upgrade_level(stat_type: int) -> int:
	return MAX_UPGRADE_LEVELS.get(stat_type, 0)


func get_upgrade_cost(stat_type: int) -> int:
	var current_level := get_upgrade_level(stat_type)
	if current_level < 0:
		return -1

	var costs: Array = UPGRADE_COSTS.get(stat_type, [])
	if current_level < 0 or current_level >= costs.size():
		return -1
	return costs[current_level]


func set_active_multiplayer_peer(peer_id: int) -> void:
	active_multiplayer_peer_id = maxi(peer_id, 0)
	if active_multiplayer_peer_id > 0:
		ensure_multiplayer_peer_state(active_multiplayer_peer_id)
	inventory_changed.emit()
	upgrade_changed.emit()


func ensure_multiplayer_peer_state(peer_id: int) -> void:
	if peer_id <= 0:
		return
	if not multiplayer_inventories.has(peer_id):
		var peer_inventory: Array[PickupConfig] = []
		peer_inventory.resize(INVENTORY_CAPACITY)
		multiplayer_inventories[peer_id] = peer_inventory
	if not multiplayer_upgrade_levels.has(peer_id):
		multiplayer_upgrade_levels[peer_id] = {
			StatType.ATTACK: 0,
			StatType.HEALTH: 0,
			StatType.ATTACK_SPEED: 0,
			StatType.DODGE: 0,
		}


func try_add_item_for_peer(peer_id: int, item: PickupConfig) -> bool:
	ensure_run_started()
	ensure_multiplayer_peer_state(peer_id)
	if item == null or not item.can_store_in_inventory:
		return false

	var peer_inventory := multiplayer_inventories[peer_id] as Array
	for slot_index in range(peer_inventory.size()):
		if peer_inventory[slot_index] == null:
			peer_inventory[slot_index] = item
			if peer_id == active_multiplayer_peer_id:
				inventory_changed.emit()
			return true

	return false


func try_use_item_for_peer(peer_id: int, slot_index: int, player: Player) -> bool:
	ensure_multiplayer_peer_state(peer_id)
	if player == null:
		return false
	var peer_inventory := multiplayer_inventories[peer_id] as Array
	if slot_index < 0 or slot_index >= peer_inventory.size():
		return false

	var item := peer_inventory[slot_index] as PickupConfig
	if item == null:
		return false
	if not player.apply_pickup(item):
		return false

	peer_inventory[slot_index] = null
	if peer_id == active_multiplayer_peer_id:
		inventory_changed.emit()
	return true


func get_item_for_peer(peer_id: int, slot_index: int) -> PickupConfig:
	ensure_multiplayer_peer_state(peer_id)
	var peer_inventory := multiplayer_inventories[peer_id] as Array
	if slot_index < 0 or slot_index >= peer_inventory.size():
		return null
	return peer_inventory[slot_index] as PickupConfig


func try_upgrade_for_peer(peer_id: int, stat_type: int, player: Player) -> bool:
	ensure_multiplayer_peer_state(peer_id)
	if player == null:
		return false

	var peer_levels := multiplayer_upgrade_levels[peer_id] as Dictionary
	if not peer_levels.has(stat_type):
		return false

	var current_level: int = peer_levels[stat_type]
	var max_level: int = MAX_UPGRADE_LEVELS.get(stat_type, 0)
	if current_level >= max_level:
		return false
	var upgrade_cost := get_upgrade_cost_for_peer(peer_id, stat_type)
	if upgrade_cost < 0 or player.current_xirang < upgrade_cost:
		return false

	player.current_xirang -= upgrade_cost
	player.xirang_changed.emit(player.current_xirang, -upgrade_cost)
	peer_levels[stat_type] = current_level + 1

	match stat_type:
		StatType.ATTACK:
			player.upgrade_attack()
		StatType.HEALTH:
			player.upgrade_max_health()
		StatType.ATTACK_SPEED:
			player.upgrade_attack_speed()
		StatType.DODGE:
			player.upgrade_dodge()

	if peer_id == active_multiplayer_peer_id:
		upgrade_changed.emit()
	return true


func get_upgrade_level_for_peer(peer_id: int, stat_type: int) -> int:
	ensure_multiplayer_peer_state(peer_id)
	var peer_levels := multiplayer_upgrade_levels[peer_id] as Dictionary
	return peer_levels.get(stat_type, 0)


func get_upgrade_cost_for_peer(peer_id: int, stat_type: int) -> int:
	ensure_multiplayer_peer_state(peer_id)
	if not MAX_UPGRADE_LEVELS.has(stat_type):
		return -1
	var current_level: int = get_upgrade_level_for_peer(peer_id, stat_type)
	var costs: Array = UPGRADE_COSTS.get(stat_type, [])
	if current_level < 0 or current_level >= costs.size():
		return -1
	return costs[current_level]


func set_upgrade_level_for_peer(peer_id: int, stat_type: int, level: int) -> void:
	ensure_multiplayer_peer_state(peer_id)
	var peer_levels := multiplayer_upgrade_levels[peer_id] as Dictionary
	if not peer_levels.has(stat_type):
		return
	peer_levels[stat_type] = clampi(level, 0, MAX_UPGRADE_LEVELS.get(stat_type, 0))
	if peer_id == active_multiplayer_peer_id:
		upgrade_changed.emit()
