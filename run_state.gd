extends Node
class_name RunStateStore

signal inventory_changed
signal upgrade_changed
signal selected_character_changed(character_id: StringName)

const INVENTORY_CAPACITY := 20
const CRAFT_RESULT_SUCCESS := &"success"
const CRAFT_RESULT_INVALID_RECIPE := &"invalid_recipe"
const CRAFT_RESULT_MISSING_INPUT := &"missing_input"
const CRAFT_RESULT_INVENTORY_FULL := &"inventory_full"
const CRAFT_RESULT_STALE_REVISION := &"stale_revision"

enum StatType {
	ATTACK,
	HEALTH,
	ATTACK_SPEED,
	DODGE,
}

const MAX_UPGRADE_LEVELS := {
	StatType.ATTACK: 10,
	StatType.HEALTH: 10,
	StatType.ATTACK_SPEED: 10,
	StatType.DODGE: 10,
}

const UPGRADE_COSTS := {
	StatType.ATTACK: [100, 200, 400, 700, 1000, 1600, 2200, 3000, 3800, 4700],
	StatType.HEALTH: [40, 70, 90, 180, 450, 700, 1000, 1500, 2000, 2700],
	StatType.ATTACK_SPEED: [40, 70, 90, 180, 450, 700, 1000, 1500, 2000, 2700],
	StatType.DODGE: [40, 70, 90, 180, 450, 700, 1000, 1500, 2000, 2700],
}

var inventory: Array[PickupConfig] = []
var inventory_stack_counts: Array[int] = []
var inventory_revision: int = 0
var run_started := false
var upgrade_levels := {
	StatType.ATTACK: 0,
	StatType.HEALTH: 0,
	StatType.ATTACK_SPEED: 0,
	StatType.DODGE: 0,
}
var active_multiplayer_peer_id: int = 0
var multiplayer_inventories: Dictionary = {}
var multiplayer_inventory_stack_counts: Dictionary = {}
var multiplayer_inventory_revisions: Dictionary = {}
var multiplayer_upgrade_levels: Dictionary = {}
var selected_character_id: StringName = PlayerCharacterRegistry.DEFAULT_CHARACTER_ID


func set_selected_character(character_id: StringName) -> bool:
	if not PlayerCharacterRegistry.is_valid_character_id(character_id):
		return false
	if selected_character_id == character_id:
		return true
	selected_character_id = character_id
	selected_character_changed.emit(selected_character_id)
	return true


func get_selected_character_id() -> StringName:
	return selected_character_id


func get_selected_character_config() -> PlayerCharacterConfig:
	return PlayerCharacterRegistry.get_config(selected_character_id)


func begin_new_run(character_id: StringName = &"weishidaier") -> void:
	if not set_selected_character(character_id):
		push_error("RunState rejected invalid character id: %s" % character_id)
		return
	inventory.clear()
	inventory.resize(INVENTORY_CAPACITY)
	inventory_stack_counts.clear()
	inventory_stack_counts.resize(INVENTORY_CAPACITY)
	inventory_stack_counts.fill(0)
	inventory_revision = 0
	for stat_type: int in upgrade_levels:
		upgrade_levels[stat_type] = 0
	active_multiplayer_peer_id = 0
	multiplayer_inventories.clear()
	multiplayer_inventory_stack_counts.clear()
	multiplayer_inventory_revisions.clear()
	multiplayer_upgrade_levels.clear()
	run_started = true
	inventory_changed.emit()
	upgrade_changed.emit()


func ensure_run_started() -> void:
	if run_started:
		return
	begin_new_run(selected_character_id)


func try_add_item(item: PickupConfig) -> bool:
	return try_add_item_count(item, 1)


func can_add_item_count(item: PickupConfig, count: int = 1) -> bool:
	ensure_run_started()
	if active_multiplayer_peer_id > 0:
		return can_add_item_count_for_peer(active_multiplayer_peer_id, item, count)
	if item == null or not item.can_store_in_inventory or count <= 0:
		return false
	_ensure_local_inventory_shape()
	return _get_available_item_capacity(inventory, inventory_stack_counts, item) >= count


func try_add_item_count(item: PickupConfig, count: int = 1) -> bool:
	ensure_run_started()
	if active_multiplayer_peer_id > 0:
		return try_add_item_count_for_peer(active_multiplayer_peer_id, item, count)
	if not can_add_item_count(item, count):
		return false

	_add_item_count_to_arrays(inventory, inventory_stack_counts, item, count)
	_bump_local_inventory_revision()
	inventory_changed.emit()
	return true


func can_add_item_counts(
	items: Array[PickupConfig],
	counts: Array[int]
) -> bool:
	ensure_run_started()
	if active_multiplayer_peer_id > 0:
		return can_add_item_counts_for_peer(
			active_multiplayer_peer_id,
			items,
			counts
		)
	_ensure_local_inventory_shape()
	return not _simulate_add_item_counts(
		inventory,
		inventory_stack_counts,
		items,
		counts
	).is_empty()


func try_add_item_counts_if_revision(
	items: Array[PickupConfig],
	counts: Array[int],
	expected_revision: int,
	emit_change: bool = true
) -> bool:
	ensure_run_started()
	_ensure_local_inventory_shape()
	if expected_revision != inventory_revision:
		return false
	var simulated := _simulate_add_item_counts(
		inventory,
		inventory_stack_counts,
		items,
		counts
	)
	if simulated.is_empty():
		return false
	inventory.assign(simulated["items"] as Array)
	inventory_stack_counts.assign(simulated["counts"] as Array)
	_bump_local_inventory_revision()
	if emit_change:
		inventory_changed.emit()
	return true


func get_simple_crafting_result(recipe: ProductionRecipe) -> StringName:
	ensure_run_started()
	if active_multiplayer_peer_id > 0:
		return get_simple_crafting_result_for_peer(
			active_multiplayer_peer_id,
			recipe
		)
	_ensure_local_inventory_shape()
	return _get_crafting_simulation_result(
		_simulate_simple_crafting(inventory, inventory_stack_counts, recipe)
	)


func try_craft_inventory_recipe_if_revision(
	recipe: ProductionRecipe,
	expected_revision: int,
	emit_change: bool = true
) -> StringName:
	ensure_run_started()
	if active_multiplayer_peer_id > 0:
		return try_craft_inventory_recipe_for_peer_if_revision(
			active_multiplayer_peer_id,
			recipe,
			expected_revision,
			emit_change
		)
	_ensure_local_inventory_shape()
	if expected_revision != inventory_revision:
		return CRAFT_RESULT_STALE_REVISION
	var simulation := _simulate_simple_crafting(
		inventory,
		inventory_stack_counts,
		recipe
	)
	var result := _get_crafting_simulation_result(simulation)
	if result != CRAFT_RESULT_SUCCESS:
		return result
	inventory.assign(simulation["items"] as Array)
	inventory_stack_counts.assign(simulation["counts"] as Array)
	_bump_local_inventory_revision()
	if emit_change:
		inventory_changed.emit()
	return CRAFT_RESULT_SUCCESS


func get_inventory_item_total(item: PickupConfig) -> int:
	ensure_run_started()
	if active_multiplayer_peer_id > 0:
		return get_inventory_item_total_for_peer(
			active_multiplayer_peer_id,
			item
		)
	_ensure_local_inventory_shape()
	return _get_item_total_in_arrays(
		inventory,
		inventory_stack_counts,
		item
	)


func try_consume_item_at_slot_if_revision(
	slot_index: int,
	expected_item: PickupConfig,
	expected_revision: int,
	emit_change: bool = true
) -> bool:
	ensure_run_started()
	_ensure_local_inventory_shape()
	if expected_revision != inventory_revision:
		return false
	if not _can_consume_expected_item(inventory, slot_index, expected_item):
		return false
	_consume_one_item_from_arrays(
		inventory,
		inventory_stack_counts,
		slot_index
	)
	_bump_local_inventory_revision()
	if emit_change:
		inventory_changed.emit()
	return true


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

	if get_item_count(slot_index) > 1:
		inventory_stack_counts[slot_index] -= 1
	else:
		inventory[slot_index] = null
		inventory_stack_counts[slot_index] = 0
	_bump_local_inventory_revision()
	inventory_changed.emit()
	return true


func discard_item(slot_index: int) -> bool:
	if active_multiplayer_peer_id > 0:
		return discard_item_for_peer(active_multiplayer_peer_id, slot_index)
	if slot_index < 0 or slot_index >= inventory.size():
		return false
	if inventory[slot_index] == null:
		return false

	inventory[slot_index] = null
	inventory_stack_counts[slot_index] = 0
	_bump_local_inventory_revision()
	inventory_changed.emit()
	return true


func get_item(slot_index: int) -> PickupConfig:
	if active_multiplayer_peer_id > 0:
		return get_item_for_peer(active_multiplayer_peer_id, slot_index)
	if slot_index < 0 or slot_index >= inventory.size():
		return null
	return inventory[slot_index]


func get_item_count(slot_index: int) -> int:
	if active_multiplayer_peer_id > 0:
		return get_item_count_for_peer(active_multiplayer_peer_id, slot_index)
	_ensure_local_inventory_shape()
	if slot_index < 0 or slot_index >= inventory.size() or inventory[slot_index] == null:
		return 0
	return maxi(inventory_stack_counts[slot_index], 1)


func try_upgrade(stat_type: int, player: Player) -> bool:
	if active_multiplayer_peer_id > 0:
		return try_upgrade_for_peer(active_multiplayer_peer_id, stat_type, player)
	if player == null:
		return false
	player.consume_last_base_upgrade_free_flag()
	if not upgrade_levels.has(stat_type):
		return false

	var current_level: int = upgrade_levels[stat_type]
	var max_level: int = MAX_UPGRADE_LEVELS.get(stat_type, 0)
	if current_level >= max_level:
		return false
	var upgrade_cost := get_upgrade_cost(stat_type)
	if upgrade_cost < 0 or player.current_xirang < upgrade_cost:
		return false

	var free_upgrade := player.try_trigger_free_base_upgrade()
	if not free_upgrade:
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
	if not multiplayer_inventory_stack_counts.has(peer_id):
		var peer_counts: Array[int] = []
		peer_counts.resize(INVENTORY_CAPACITY)
		peer_counts.fill(0)
		multiplayer_inventory_stack_counts[peer_id] = peer_counts
	if not multiplayer_inventory_revisions.has(peer_id):
		multiplayer_inventory_revisions[peer_id] = 0
	if not multiplayer_upgrade_levels.has(peer_id):
		multiplayer_upgrade_levels[peer_id] = {
			StatType.ATTACK: 0,
			StatType.HEALTH: 0,
			StatType.ATTACK_SPEED: 0,
			StatType.DODGE: 0,
		}


func try_add_item_for_peer(peer_id: int, item: PickupConfig) -> bool:
	return try_add_item_count_for_peer(peer_id, item, 1)


func can_add_item_count_for_peer(peer_id: int, item: PickupConfig, count: int = 1) -> bool:
	ensure_run_started()
	ensure_multiplayer_peer_state(peer_id)
	if item == null or not item.can_store_in_inventory or count <= 0:
		return false

	var peer_inventory := multiplayer_inventories[peer_id] as Array
	var peer_counts := multiplayer_inventory_stack_counts[peer_id] as Array
	return _get_available_item_capacity(peer_inventory, peer_counts, item) >= count


func try_add_item_count_for_peer(peer_id: int, item: PickupConfig, count: int = 1) -> bool:
	ensure_run_started()
	ensure_multiplayer_peer_state(peer_id)
	if not can_add_item_count_for_peer(peer_id, item, count):
		return false

	var peer_inventory := multiplayer_inventories[peer_id] as Array
	var peer_counts := multiplayer_inventory_stack_counts[peer_id] as Array
	_add_item_count_to_arrays(peer_inventory, peer_counts, item, count)
	_bump_inventory_revision_for_peer(peer_id)
	inventory_changed.emit()
	return true


func can_add_item_counts_for_peer(
	peer_id: int,
	items: Array[PickupConfig],
	counts: Array[int]
) -> bool:
	ensure_run_started()
	ensure_multiplayer_peer_state(peer_id)
	return not _simulate_add_item_counts(
		multiplayer_inventories[peer_id] as Array,
		multiplayer_inventory_stack_counts[peer_id] as Array,
		items,
		counts
	).is_empty()


func try_add_item_counts_for_peer_if_revision(
	peer_id: int,
	items: Array[PickupConfig],
	counts: Array[int],
	expected_revision: int,
	emit_change: bool = true
) -> bool:
	ensure_run_started()
	ensure_multiplayer_peer_state(peer_id)
	if expected_revision != get_inventory_revision_for_peer(peer_id):
		return false
	var simulated := _simulate_add_item_counts(
		multiplayer_inventories[peer_id] as Array,
		multiplayer_inventory_stack_counts[peer_id] as Array,
		items,
		counts
	)
	if simulated.is_empty():
		return false
	var peer_inventory := multiplayer_inventories[peer_id] as Array
	var peer_counts := multiplayer_inventory_stack_counts[peer_id] as Array
	peer_inventory.assign(simulated["items"] as Array)
	peer_counts.assign(simulated["counts"] as Array)
	_bump_inventory_revision_for_peer(peer_id)
	if emit_change:
		inventory_changed.emit()
	return true


func get_simple_crafting_result_for_peer(
	peer_id: int,
	recipe: ProductionRecipe
) -> StringName:
	ensure_run_started()
	ensure_multiplayer_peer_state(peer_id)
	return _get_crafting_simulation_result(
		_simulate_simple_crafting(
			multiplayer_inventories[peer_id] as Array,
			multiplayer_inventory_stack_counts[peer_id] as Array,
			recipe
		)
	)


func try_craft_inventory_recipe_for_peer_if_revision(
	peer_id: int,
	recipe: ProductionRecipe,
	expected_revision: int,
	emit_change: bool = true
) -> StringName:
	ensure_run_started()
	ensure_multiplayer_peer_state(peer_id)
	if expected_revision != get_inventory_revision_for_peer(peer_id):
		return CRAFT_RESULT_STALE_REVISION
	var peer_inventory := multiplayer_inventories[peer_id] as Array
	var peer_counts := multiplayer_inventory_stack_counts[peer_id] as Array
	var simulation := _simulate_simple_crafting(
		peer_inventory,
		peer_counts,
		recipe
	)
	var result := _get_crafting_simulation_result(simulation)
	if result != CRAFT_RESULT_SUCCESS:
		return result
	peer_inventory.assign(simulation["items"] as Array)
	peer_counts.assign(simulation["counts"] as Array)
	_bump_inventory_revision_for_peer(peer_id)
	if emit_change:
		inventory_changed.emit()
	return CRAFT_RESULT_SUCCESS


func get_inventory_item_total_for_peer(
	peer_id: int,
	item: PickupConfig
) -> int:
	ensure_run_started()
	ensure_multiplayer_peer_state(peer_id)
	return _get_item_total_in_arrays(
		multiplayer_inventories[peer_id] as Array,
		multiplayer_inventory_stack_counts[peer_id] as Array,
		item
	)


func try_consume_item_at_slot_for_peer_if_revision(
	peer_id: int,
	slot_index: int,
	expected_item: PickupConfig,
	expected_revision: int,
	emit_change: bool = true
) -> bool:
	ensure_run_started()
	ensure_multiplayer_peer_state(peer_id)
	if expected_revision != get_inventory_revision_for_peer(peer_id):
		return false
	var peer_inventory := multiplayer_inventories[peer_id] as Array
	if not _can_consume_expected_item(
		peer_inventory,
		slot_index,
		expected_item
	):
		return false
	var peer_counts := multiplayer_inventory_stack_counts[peer_id] as Array
	_consume_one_item_from_arrays(peer_inventory, peer_counts, slot_index)
	_bump_inventory_revision_for_peer(peer_id)
	if emit_change:
		inventory_changed.emit()
	return true


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

	var peer_counts := multiplayer_inventory_stack_counts[peer_id] as Array
	if get_item_count_for_peer(peer_id, slot_index) > 1:
		peer_counts[slot_index] = int(peer_counts[slot_index]) - 1
	else:
		peer_inventory[slot_index] = null
		peer_counts[slot_index] = 0
	_bump_inventory_revision_for_peer(peer_id)
	inventory_changed.emit()
	return true


func discard_item_for_peer(peer_id: int, slot_index: int) -> bool:
	ensure_multiplayer_peer_state(peer_id)
	var peer_inventory := multiplayer_inventories[peer_id] as Array
	if slot_index < 0 or slot_index >= peer_inventory.size():
		return false
	if peer_inventory[slot_index] == null:
		return false

	peer_inventory[slot_index] = null
	var peer_counts := multiplayer_inventory_stack_counts[peer_id] as Array
	peer_counts[slot_index] = 0
	_bump_inventory_revision_for_peer(peer_id)
	inventory_changed.emit()
	return true


func get_inventory_revision() -> int:
	return inventory_revision


func get_inventory_revision_for_peer(peer_id: int) -> int:
	if peer_id <= 0:
		return 0
	ensure_multiplayer_peer_state(peer_id)
	return int(multiplayer_inventory_revisions.get(peer_id, 0))


func has_multiplayer_peer_state(peer_id: int) -> bool:
	return (
		peer_id > 0
		and multiplayer_inventories.has(peer_id)
		and multiplayer_inventory_stack_counts.has(peer_id)
		and multiplayer_inventory_revisions.has(peer_id)
	)


func get_inventory_slot_state(slot_index: int) -> Dictionary:
	_ensure_local_inventory_shape()
	return _make_inventory_slot_state(
		slot_index,
		inventory,
		inventory_stack_counts,
		inventory_revision
	)


func get_inventory_slot_state_for_peer(peer_id: int, slot_index: int) -> Dictionary:
	ensure_multiplayer_peer_state(peer_id)
	return _make_inventory_slot_state(
		slot_index,
		multiplayer_inventories[peer_id] as Array,
		multiplayer_inventory_stack_counts[peer_id] as Array,
		get_inventory_revision_for_peer(peer_id)
	)


func export_inventory_snapshot() -> Dictionary:
	_ensure_local_inventory_shape()
	return _make_inventory_snapshot(
		0,
		inventory,
		inventory_stack_counts,
		inventory_revision
	)


func export_inventory_snapshot_for_peer(peer_id: int) -> Dictionary:
	ensure_multiplayer_peer_state(peer_id)
	return _make_inventory_snapshot(
		peer_id,
		multiplayer_inventories[peer_id] as Array,
		multiplayer_inventory_stack_counts[peer_id] as Array,
		get_inventory_revision_for_peer(peer_id)
	)


func apply_inventory_snapshot(snapshot: Dictionary) -> bool:
	var decoded := _decode_inventory_snapshot(snapshot, 0, inventory_revision)
	if decoded.is_empty():
		return false
	inventory.assign(decoded["items"] as Array)
	inventory_stack_counts.assign(decoded["counts"] as Array)
	inventory_revision = int(decoded["revision"])
	inventory_changed.emit()
	return true


func apply_inventory_snapshot_for_peer(
	peer_id: int,
	snapshot: Dictionary,
	allow_revision_rewind: bool = false
) -> bool:
	ensure_multiplayer_peer_state(peer_id)
	var decoded := _decode_inventory_snapshot(
		snapshot,
		peer_id,
		-1 if allow_revision_rewind else get_inventory_revision_for_peer(peer_id)
	)
	if decoded.is_empty():
		return false
	var peer_inventory := multiplayer_inventories[peer_id] as Array
	var peer_counts := multiplayer_inventory_stack_counts[peer_id] as Array
	peer_inventory.assign(decoded["items"] as Array)
	peer_counts.assign(decoded["counts"] as Array)
	multiplayer_inventory_revisions[peer_id] = int(decoded["revision"])
	inventory_changed.emit()
	return true


func apply_inventory_slot_state_for_peer(peer_id: int, slot_state: Dictionary) -> bool:
	ensure_multiplayer_peer_state(peer_id)
	var slot_index := int(slot_state.get("slot_index", -1))
	var new_revision := int(slot_state.get("revision", -1))
	var current_revision := get_inventory_revision_for_peer(peer_id)
	if slot_index < 0 or slot_index >= INVENTORY_CAPACITY:
		return false
	if new_revision == current_revision:
		return _inventory_slot_state_matches(
			slot_state,
			multiplayer_inventories[peer_id] as Array,
			multiplayer_inventory_stack_counts[peer_id] as Array
		)
	if new_revision != current_revision + 1:
		return false
	var decoded_item := _decode_inventory_item(
		str(slot_state.get("config_path", "")),
		int(slot_state.get("stack_count", 0))
	)
	if not bool(decoded_item.get("valid", false)):
		return false
	var peer_inventory := multiplayer_inventories[peer_id] as Array
	var peer_counts := multiplayer_inventory_stack_counts[peer_id] as Array
	peer_inventory[slot_index] = decoded_item["item"]
	peer_counts[slot_index] = int(decoded_item["count"])
	multiplayer_inventory_revisions[peer_id] = new_revision
	inventory_changed.emit()
	return true


func clear_item_slot_if_revision(slot_index: int, expected_revision: int) -> bool:
	if expected_revision != inventory_revision:
		return false
	return discard_item(slot_index)


func take_item_stack_if_revision(
	slot_index: int,
	expected_revision: int,
	emit_change: bool = true
) -> Dictionary:
	_ensure_local_inventory_shape()
	if expected_revision != inventory_revision:
		return {"success": false}
	if slot_index < 0 or slot_index >= inventory.size():
		return {"success": false}
	var item := inventory[slot_index]
	if item == null:
		return {"success": false}
	var count := maxi(inventory_stack_counts[slot_index], 1)
	inventory[slot_index] = null
	inventory_stack_counts[slot_index] = 0
	_bump_local_inventory_revision()
	if emit_change:
		inventory_changed.emit()
	return {
		"success": true,
		"item": item,
		"stack_count": count,
		"revision": inventory_revision,
	}


func take_item_count_at_slot_if_revision(
	slot_index: int,
	count: int,
	expected_revision: int,
	emit_change: bool = true
) -> Dictionary:
	_ensure_local_inventory_shape()
	if expected_revision != inventory_revision:
		return {"success": false}
	if slot_index < 0 or slot_index >= inventory.size() or count <= 0:
		return {"success": false}
	var item := inventory[slot_index]
	if item == null:
		return {"success": false}
	var stored_count := maxi(inventory_stack_counts[slot_index], 1)
	if count > stored_count:
		return {"success": false}
	_take_item_count_from_slot_unchecked(
		inventory,
		inventory_stack_counts,
		slot_index,
		count
	)
	_bump_local_inventory_revision()
	if emit_change:
		inventory_changed.emit()
	return {
		"success": true,
		"item": item,
		"stack_count": count,
		"revision": inventory_revision,
	}


func try_add_item_count_if_revision(
	item: PickupConfig,
	count: int,
	expected_revision: int,
	emit_change: bool = true
) -> bool:
	ensure_run_started()
	_ensure_local_inventory_shape()
	if (
		expected_revision != inventory_revision
		or item == null
		or not item.can_store_in_inventory
		or count <= 0
		or _get_available_item_capacity(inventory, inventory_stack_counts, item) < count
	):
		return false
	_add_item_count_to_arrays(inventory, inventory_stack_counts, item, count)
	_bump_local_inventory_revision()
	if emit_change:
		inventory_changed.emit()
	return true


func can_add_item_count_to_slot(
	item: PickupConfig,
	count: int,
	target_slot_index: int,
	expected_revision: int = -1
) -> bool:
	ensure_run_started()
	_ensure_local_inventory_shape()
	if expected_revision >= 0 and expected_revision != inventory_revision:
		return false
	return _can_add_item_count_to_slot_in_arrays(
		inventory,
		inventory_stack_counts,
		item,
		count,
		target_slot_index
	)


func try_add_item_count_to_slot_if_revision(
	item: PickupConfig,
	count: int,
	target_slot_index: int,
	expected_revision: int,
	emit_change: bool = true
) -> bool:
	if not can_add_item_count_to_slot(item, count, target_slot_index, expected_revision):
		return false
	_add_item_count_to_slot_unchecked(
		inventory,
		inventory_stack_counts,
		item,
		count,
		target_slot_index
	)
	_bump_local_inventory_revision()
	if emit_change:
		inventory_changed.emit()
	return true


func move_item_stack_to_slot(
	source_slot_index: int,
	target_slot_index: int,
	expected_revision: int = -1,
	emit_change: bool = true
) -> bool:
	ensure_run_started()
	if active_multiplayer_peer_id > 0:
		return move_item_stack_to_slot_for_peer_if_revision(
			active_multiplayer_peer_id,
			source_slot_index,
			target_slot_index,
			get_inventory_revision_for_peer(active_multiplayer_peer_id)
				if expected_revision < 0
				else expected_revision,
			emit_change
		)
	_ensure_local_inventory_shape()
	if expected_revision >= 0 and expected_revision != inventory_revision:
		return false
	if not _can_move_item_stack_between_slots(
		inventory,
		inventory_stack_counts,
		source_slot_index,
		target_slot_index
	):
		return false
	_move_item_stack_between_slots_unchecked(
		inventory,
		inventory_stack_counts,
		source_slot_index,
		target_slot_index
	)
	_bump_local_inventory_revision()
	if emit_change:
		inventory_changed.emit()
	return true


func clear_item_slot_for_peer_if_revision(
	peer_id: int,
	slot_index: int,
	expected_revision: int
) -> bool:
	ensure_multiplayer_peer_state(peer_id)
	if expected_revision != get_inventory_revision_for_peer(peer_id):
		return false
	return discard_item_for_peer(peer_id, slot_index)


func take_item_stack_for_peer_if_revision(
	peer_id: int,
	slot_index: int,
	expected_revision: int,
	emit_change: bool = true
) -> Dictionary:
	ensure_multiplayer_peer_state(peer_id)
	if expected_revision != get_inventory_revision_for_peer(peer_id):
		return {"success": false}
	var peer_inventory := multiplayer_inventories[peer_id] as Array
	var peer_counts := multiplayer_inventory_stack_counts[peer_id] as Array
	if slot_index < 0 or slot_index >= peer_inventory.size():
		return {"success": false}
	var item := peer_inventory[slot_index] as PickupConfig
	if item == null:
		return {"success": false}
	var count := maxi(int(peer_counts[slot_index]), 1)
	peer_inventory[slot_index] = null
	peer_counts[slot_index] = 0
	_bump_inventory_revision_for_peer(peer_id)
	if emit_change:
		inventory_changed.emit()
	return {
		"success": true,
		"item": item,
		"stack_count": count,
		"revision": get_inventory_revision_for_peer(peer_id),
	}


func take_item_count_at_slot_for_peer_if_revision(
	peer_id: int,
	slot_index: int,
	count: int,
	expected_revision: int,
	emit_change: bool = true
) -> Dictionary:
	ensure_multiplayer_peer_state(peer_id)
	if expected_revision != get_inventory_revision_for_peer(peer_id):
		return {"success": false}
	var peer_inventory := multiplayer_inventories[peer_id] as Array
	var peer_counts := multiplayer_inventory_stack_counts[peer_id] as Array
	if slot_index < 0 or slot_index >= peer_inventory.size() or count <= 0:
		return {"success": false}
	var item := peer_inventory[slot_index] as PickupConfig
	if item == null:
		return {"success": false}
	var stored_count := maxi(int(peer_counts[slot_index]), 1)
	if count > stored_count:
		return {"success": false}
	_take_item_count_from_slot_unchecked(
		peer_inventory,
		peer_counts,
		slot_index,
		count
	)
	_bump_inventory_revision_for_peer(peer_id)
	if emit_change:
		inventory_changed.emit()
	return {
		"success": true,
		"item": item,
		"stack_count": count,
		"revision": get_inventory_revision_for_peer(peer_id),
	}


func try_add_item_count_for_peer_if_revision(
	peer_id: int,
	item: PickupConfig,
	count: int,
	expected_revision: int,
	emit_change: bool = true
) -> bool:
	ensure_multiplayer_peer_state(peer_id)
	if expected_revision != get_inventory_revision_for_peer(peer_id):
		return false
	if not can_add_item_count_for_peer(peer_id, item, count):
		return false
	var peer_inventory := multiplayer_inventories[peer_id] as Array
	var peer_counts := multiplayer_inventory_stack_counts[peer_id] as Array
	_add_item_count_to_arrays(peer_inventory, peer_counts, item, count)
	_bump_inventory_revision_for_peer(peer_id)
	if emit_change:
		inventory_changed.emit()
	return true


func can_add_item_count_to_slot_for_peer(
	peer_id: int,
	item: PickupConfig,
	count: int,
	target_slot_index: int,
	expected_revision: int = -1
) -> bool:
	ensure_multiplayer_peer_state(peer_id)
	if expected_revision >= 0 and expected_revision != get_inventory_revision_for_peer(peer_id):
		return false
	return _can_add_item_count_to_slot_in_arrays(
		multiplayer_inventories[peer_id] as Array,
		multiplayer_inventory_stack_counts[peer_id] as Array,
		item,
		count,
		target_slot_index
	)


func try_add_item_count_to_slot_for_peer_if_revision(
	peer_id: int,
	item: PickupConfig,
	count: int,
	target_slot_index: int,
	expected_revision: int,
	emit_change: bool = true
) -> bool:
	if not can_add_item_count_to_slot_for_peer(
		peer_id,
		item,
		count,
		target_slot_index,
		expected_revision
	):
		return false
	_add_item_count_to_slot_unchecked(
		multiplayer_inventories[peer_id] as Array,
		multiplayer_inventory_stack_counts[peer_id] as Array,
		item,
		count,
		target_slot_index
	)
	_bump_inventory_revision_for_peer(peer_id)
	if emit_change:
		inventory_changed.emit()
	return true


func move_item_stack_to_slot_for_peer_if_revision(
	peer_id: int,
	source_slot_index: int,
	target_slot_index: int,
	expected_revision: int,
	emit_change: bool = true
) -> bool:
	ensure_multiplayer_peer_state(peer_id)
	if expected_revision != get_inventory_revision_for_peer(peer_id):
		return false
	var peer_inventory := multiplayer_inventories[peer_id] as Array
	var peer_counts := multiplayer_inventory_stack_counts[peer_id] as Array
	if not _can_move_item_stack_between_slots(
		peer_inventory,
		peer_counts,
		source_slot_index,
		target_slot_index
	):
		return false
	_move_item_stack_between_slots_unchecked(
		peer_inventory,
		peer_counts,
		source_slot_index,
		target_slot_index
	)
	_bump_inventory_revision_for_peer(peer_id)
	if emit_change:
		inventory_changed.emit()
	return true


func notify_inventory_transaction_completed() -> void:
	inventory_changed.emit()


func get_item_for_peer(peer_id: int, slot_index: int) -> PickupConfig:
	ensure_multiplayer_peer_state(peer_id)
	var peer_inventory := multiplayer_inventories[peer_id] as Array
	if slot_index < 0 or slot_index >= peer_inventory.size():
		return null
	return peer_inventory[slot_index] as PickupConfig


func get_item_count_for_peer(peer_id: int, slot_index: int) -> int:
	ensure_multiplayer_peer_state(peer_id)
	var peer_inventory := multiplayer_inventories[peer_id] as Array
	var peer_counts := multiplayer_inventory_stack_counts[peer_id] as Array
	if slot_index < 0 or slot_index >= peer_inventory.size() or peer_inventory[slot_index] == null:
		return 0
	return maxi(int(peer_counts[slot_index]), 1)


func _bump_local_inventory_revision() -> void:
	inventory_revision += 1


func _bump_inventory_revision_for_peer(peer_id: int) -> void:
	multiplayer_inventory_revisions[peer_id] = get_inventory_revision_for_peer(peer_id) + 1


func _make_inventory_slot_state(
	slot_index: int,
	items: Array,
	counts: Array,
	revision: int
) -> Dictionary:
	if slot_index < 0 or slot_index >= INVENTORY_CAPACITY:
		return {}
	var item := items[slot_index] as PickupConfig
	return {
		"slot_index": slot_index,
		"config_path": item.resource_path if item != null else "",
		"stack_count": maxi(int(counts[slot_index]), 1) if item != null else 0,
		"revision": revision,
	}


func _make_inventory_snapshot(
	peer_id: int,
	items: Array,
	counts: Array,
	revision: int
) -> Dictionary:
	var slots: Array[Dictionary] = []
	slots.resize(INVENTORY_CAPACITY)
	for slot_index in range(INVENTORY_CAPACITY):
		slots[slot_index] = _make_inventory_slot_state(
			slot_index,
			items,
			counts,
			revision
		)
	return {
		"peer_id": peer_id,
		"revision": revision,
		"slots": slots,
	}


func _decode_inventory_snapshot(
	snapshot: Dictionary,
	expected_peer_id: int,
	current_revision: int
) -> Dictionary:
	if int(snapshot.get("peer_id", expected_peer_id)) != expected_peer_id:
		return {}
	var new_revision := int(snapshot.get("revision", -1))
	if new_revision < 0 or new_revision < current_revision:
		return {}
	var raw_slots := snapshot.get("slots", []) as Array
	if raw_slots.size() != INVENTORY_CAPACITY:
		return {}
	var decoded_items: Array[PickupConfig] = []
	var decoded_counts: Array[int] = []
	decoded_items.resize(INVENTORY_CAPACITY)
	decoded_counts.resize(INVENTORY_CAPACITY)
	var seen_slots := {}
	for raw_slot_value in raw_slots:
		var raw_slot := raw_slot_value as Dictionary
		var slot_index := int(raw_slot.get("slot_index", -1))
		if (
			slot_index < 0
			or slot_index >= INVENTORY_CAPACITY
			or seen_slots.has(slot_index)
		):
			return {}
		seen_slots[slot_index] = true
		var decoded_item := _decode_inventory_item(
			str(raw_slot.get("config_path", "")),
			int(raw_slot.get("stack_count", 0))
		)
		if not bool(decoded_item.get("valid", false)):
			return {}
		decoded_items[slot_index] = decoded_item["item"]
		decoded_counts[slot_index] = int(decoded_item["count"])
	return {
		"items": decoded_items,
		"counts": decoded_counts,
		"revision": new_revision,
	}


func _decode_inventory_item(config_path: String, stack_count: int) -> Dictionary:
	if config_path.is_empty():
		return {
			"valid": stack_count == 0,
			"item": null,
			"count": 0,
		}
	if stack_count <= 0:
		return {"valid": false}
	var item := load(config_path) as PickupConfig
	if (
		item == null
		or not item.can_store_in_inventory
		or stack_count > _get_item_stack_limit(item)
	):
		return {"valid": false}
	return {
		"valid": true,
		"item": item,
		"count": stack_count,
	}


func _inventory_slot_state_matches(
	slot_state: Dictionary,
	items: Array,
	counts: Array
) -> bool:
	var slot_index := int(slot_state.get("slot_index", -1))
	if slot_index < 0 or slot_index >= INVENTORY_CAPACITY:
		return false
	var current_item := items[slot_index] as PickupConfig
	var current_path := current_item.resource_path if current_item != null else ""
	var current_count := maxi(int(counts[slot_index]), 1) if current_item != null else 0
	return (
		current_path == str(slot_state.get("config_path", ""))
		and current_count == int(slot_state.get("stack_count", 0))
	)


func _ensure_local_inventory_shape() -> void:
	if inventory.size() != INVENTORY_CAPACITY:
		inventory.resize(INVENTORY_CAPACITY)
	if inventory_stack_counts.size() != INVENTORY_CAPACITY:
		inventory_stack_counts.resize(INVENTORY_CAPACITY)
	for slot_index in range(INVENTORY_CAPACITY):
		if inventory[slot_index] == null:
			inventory_stack_counts[slot_index] = 0
		elif inventory_stack_counts[slot_index] <= 0:
			inventory_stack_counts[slot_index] = 1


func _items_share_stack(existing_item: PickupConfig, incoming_item: PickupConfig) -> bool:
	if existing_item == null or incoming_item == null or not incoming_item.stackable:
		return false
	if existing_item == incoming_item:
		return true
	return (
		not existing_item.resource_path.is_empty()
		and existing_item.resource_path == incoming_item.resource_path
	)


func _items_match_identity(
	existing_item: PickupConfig,
	expected_item: PickupConfig
) -> bool:
	if existing_item == null or expected_item == null:
		return false
	if existing_item == expected_item:
		return true
	return (
		not existing_item.resource_path.is_empty()
		and existing_item.resource_path == expected_item.resource_path
	)


func _can_consume_expected_item(
	items: Array,
	slot_index: int,
	expected_item: PickupConfig
) -> bool:
	return (
		slot_index >= 0
		and slot_index < items.size()
		and _items_match_identity(
			items[slot_index] as PickupConfig,
			expected_item
		)
	)


func _consume_one_item_from_arrays(
	items: Array,
	counts: Array,
	slot_index: int
) -> void:
	var current_count := maxi(int(counts[slot_index]), 1)
	if current_count > 1:
		counts[slot_index] = current_count - 1
		return
	items[slot_index] = null
	counts[slot_index] = 0


func _take_item_count_from_slot_unchecked(
	items: Array,
	counts: Array,
	slot_index: int,
	count: int
) -> void:
	var remaining_count := maxi(int(counts[slot_index]), 1) - count
	if remaining_count > 0:
		counts[slot_index] = remaining_count
		return
	items[slot_index] = null
	counts[slot_index] = 0


func _get_item_stack_limit(item: PickupConfig) -> int:
	if item == null or not item.stackable:
		return 1
	return clampi(item.inventory_stack_limit, 1, 999)


func _get_available_item_capacity(
	items: Array,
	counts: Array,
	item: PickupConfig
) -> int:
	if item == null:
		return 0

	var stack_limit := _get_item_stack_limit(item)
	var capacity := 0
	for slot_index in range(items.size()):
		var stored_item := items[slot_index] as PickupConfig
		if stored_item == null:
			capacity += stack_limit
		elif item.stackable and _items_share_stack(stored_item, item):
			capacity += maxi(stack_limit - int(counts[slot_index]), 0)
	return capacity


func _can_add_item_count_to_slot_in_arrays(
	items: Array,
	counts: Array,
	item: PickupConfig,
	count: int,
	target_slot_index: int
) -> bool:
	if (
		item == null
		or not item.can_store_in_inventory
		or count <= 0
		or target_slot_index < 0
		or target_slot_index >= items.size()
	):
		return false
	var target_item := items[target_slot_index] as PickupConfig
	if target_item == null:
		return count <= _get_item_stack_limit(item)
	if not _items_share_stack(target_item, item):
		return false
	return int(counts[target_slot_index]) + count <= _get_item_stack_limit(item)


func _add_item_count_to_slot_unchecked(
	items: Array,
	counts: Array,
	item: PickupConfig,
	count: int,
	target_slot_index: int
) -> void:
	if items[target_slot_index] == null:
		items[target_slot_index] = item
		counts[target_slot_index] = count
	else:
		counts[target_slot_index] = int(counts[target_slot_index]) + count


func _can_move_item_stack_between_slots(
	items: Array,
	counts: Array,
	source_slot_index: int,
	target_slot_index: int
) -> bool:
	if (
		source_slot_index < 0
		or source_slot_index >= items.size()
		or target_slot_index < 0
		or target_slot_index >= items.size()
		or source_slot_index == target_slot_index
	):
		return false
	var source_item := items[source_slot_index] as PickupConfig
	if source_item == null:
		return false
	return _can_add_item_count_to_slot_in_arrays(
		items,
		counts,
		source_item,
		maxi(int(counts[source_slot_index]), 1),
		target_slot_index
	)


func _move_item_stack_between_slots_unchecked(
	items: Array,
	counts: Array,
	source_slot_index: int,
	target_slot_index: int
) -> void:
	var source_item := items[source_slot_index] as PickupConfig
	var source_count := maxi(int(counts[source_slot_index]), 1)
	_add_item_count_to_slot_unchecked(
		items,
		counts,
		source_item,
		source_count,
		target_slot_index
	)
	items[source_slot_index] = null
	counts[source_slot_index] = 0


func _add_item_count_to_arrays(
	items: Array,
	counts: Array,
	item: PickupConfig,
	count: int
) -> void:
	var remaining := count
	var stack_limit := _get_item_stack_limit(item)
	if item.stackable:
		for slot_index in range(items.size()):
			if not _items_share_stack(items[slot_index] as PickupConfig, item):
				continue
			var room := maxi(stack_limit - int(counts[slot_index]), 0)
			var added := mini(room, remaining)
			counts[slot_index] = int(counts[slot_index]) + added
			remaining -= added
			if remaining <= 0:
				return

	for slot_index in range(items.size()):
		if items[slot_index] != null:
			continue
		var added := mini(stack_limit, remaining)
		items[slot_index] = item
		counts[slot_index] = added
		remaining -= added
		if remaining <= 0:
			return


func _simulate_add_item_counts(
	current_items: Array,
	current_counts: Array,
	items: Array[PickupConfig],
	counts: Array[int]
) -> Dictionary:
	if items.is_empty() or items.size() != counts.size():
		return {}
	var simulated_items := current_items.duplicate()
	var simulated_counts := current_counts.duplicate()
	for item_index in items.size():
		var item := items[item_index]
		var count := counts[item_index]
		if (
			item == null
			or not item.can_store_in_inventory
			or count <= 0
			or _get_available_item_capacity(
				simulated_items,
				simulated_counts,
				item
			) < count
		):
			return {}
		_add_item_count_to_arrays(
			simulated_items,
			simulated_counts,
			item,
			count
		)
	return {
		"items": simulated_items,
		"counts": simulated_counts,
	}


func _simulate_simple_crafting(
	current_items: Array,
	current_counts: Array,
	recipe: ProductionRecipe
) -> Dictionary:
	if not SimpleCraftingRegistry.is_simple_crafting_recipe(recipe):
		return {"result": CRAFT_RESULT_INVALID_RECIPE}
	var simulated_items := current_items.duplicate()
	var simulated_counts := current_counts.duplicate()
	for input_index in recipe.input_items.size():
		if not _consume_item_count_from_arrays(
			simulated_items,
			simulated_counts,
			recipe.input_items[input_index],
			recipe.input_amounts[input_index]
		):
			return {"result": CRAFT_RESULT_MISSING_INPUT}
	var output_simulation := _simulate_add_item_counts(
		simulated_items,
		simulated_counts,
		recipe.output_items,
		recipe.output_amounts
	)
	if output_simulation.is_empty():
		return {"result": CRAFT_RESULT_INVENTORY_FULL}
	return {
		"result": CRAFT_RESULT_SUCCESS,
		"items": output_simulation["items"],
		"counts": output_simulation["counts"],
	}


func _consume_item_count_from_arrays(
	items: Array,
	counts: Array,
	item: PickupConfig,
	count: int
) -> bool:
	if item == null or count <= 0:
		return false
	var remaining := count
	for slot_index in items.size():
		if not _items_match_identity(items[slot_index] as PickupConfig, item):
			continue
		var stored_count := maxi(int(counts[slot_index]), 1)
		var consumed := mini(stored_count, remaining)
		var next_count := stored_count - consumed
		if next_count > 0:
			counts[slot_index] = next_count
		else:
			items[slot_index] = null
			counts[slot_index] = 0
		remaining -= consumed
		if remaining <= 0:
			return true
	return false


func _get_item_total_in_arrays(
	items: Array,
	counts: Array,
	item: PickupConfig
) -> int:
	if item == null:
		return 0
	var total := 0
	for slot_index in items.size():
		if _items_match_identity(items[slot_index] as PickupConfig, item):
			total += maxi(int(counts[slot_index]), 1)
	return total


func _get_crafting_simulation_result(simulation: Dictionary) -> StringName:
	var result: Variant = simulation.get(
		"result",
		CRAFT_RESULT_INVALID_RECIPE
	)
	if typeof(result) not in [TYPE_STRING, TYPE_STRING_NAME]:
		return CRAFT_RESULT_INVALID_RECIPE
	return StringName(result)


func try_upgrade_for_peer(peer_id: int, stat_type: int, player: Player) -> bool:
	ensure_multiplayer_peer_state(peer_id)
	if player == null:
		return false
	player.consume_last_base_upgrade_free_flag()

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

	var free_upgrade := player.try_trigger_free_base_upgrade()
	if not free_upgrade:
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
