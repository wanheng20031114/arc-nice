extends Node
class_name RunStateStore

signal inventory_changed
signal upgrade_changed
signal selected_character_changed(character_id: StringName)
signal shared_warehouse_ledger_changed(snapshot: Dictionary)

const INVENTORY_CAPACITY := 20
const PARTY_ECONOMY_SCHEMA_VERSION := 1
const SHARED_WAREHOUSE_LEDGER_SCHEMA_VERSION := 1
const STARTING_WOOD_COUNT := 5
const STARTING_WOOD: PickupConfig = preload(
	"res://resources/config/materials/material_wood.tres"
)
const CRAFT_RESULT_SUCCESS := &"success"
const CRAFT_RESULT_INVALID_RECIPE := &"invalid_recipe"
const CRAFT_RESULT_MISSING_INPUT := &"missing_input"
const CRAFT_RESULT_INVENTORY_FULL := &"inventory_full"
const CRAFT_RESULT_STALE_REVISION := &"stale_revision"
const CRAFT_RESULT_RESEARCH_LOCKED := &"research_locked"

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
## OakWarehouse 的跨场景 wire 快照。路线场景没有仓库节点，因此只保留
## 可验证的 config_path/count 数据，不持有已卸载场景中的 Node 引用。
var shared_warehouse_snapshots: Dictionary = {}
var shared_warehouse_ledger_revision: int = 0
var selected_character_id: StringName = PlayerCharacterRegistry.DEFAULT_CHARACTER_ID
var _include_starting_inventory_for_new_peers := true


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


func begin_new_run(
	character_id: StringName = &"weishidaier",
	include_starting_inventory: bool = true
) -> void:
	if not set_selected_character(character_id):
		push_error("RunState rejected invalid character id: %s" % character_id)
		return
	_include_starting_inventory_for_new_peers = include_starting_inventory
	inventory.clear()
	inventory.resize(INVENTORY_CAPACITY)
	inventory_stack_counts.clear()
	inventory_stack_counts.resize(INVENTORY_CAPACITY)
	inventory_stack_counts.fill(0)
	if include_starting_inventory:
		_seed_starting_inventory(inventory, inventory_stack_counts)
	inventory_revision = 0
	for stat_type: int in upgrade_levels:
		upgrade_levels[stat_type] = 0
	active_multiplayer_peer_id = 0
	multiplayer_inventories.clear()
	multiplayer_inventory_stack_counts.clear()
	multiplayer_inventory_revisions.clear()
	multiplayer_upgrade_levels.clear()
	shared_warehouse_snapshots.clear()
	shared_warehouse_ledger_revision = 0
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


func get_simple_crafting_result(
	recipe: ProductionRecipe,
	completed_global_research_ids: Array[StringName] = []
) -> StringName:
	ensure_run_started()
	if active_multiplayer_peer_id > 0:
		return get_simple_crafting_result_for_peer(
			active_multiplayer_peer_id,
			recipe,
			completed_global_research_ids
		)
	_ensure_local_inventory_shape()
	return _get_crafting_simulation_result(
		_simulate_simple_crafting(
			inventory,
			inventory_stack_counts,
			recipe,
			completed_global_research_ids
		)
	)


func try_craft_inventory_recipe_if_revision(
	recipe: ProductionRecipe,
	expected_revision: int,
	emit_change: bool = true,
	completed_global_research_ids: Array[StringName] = []
) -> StringName:
	ensure_run_started()
	if active_multiplayer_peer_id > 0:
		return try_craft_inventory_recipe_for_peer_if_revision(
			active_multiplayer_peer_id,
			recipe,
			expected_revision,
			emit_change,
			completed_global_research_ids
		)
	_ensure_local_inventory_shape()
	if expected_revision != inventory_revision:
		return CRAFT_RESULT_STALE_REVISION
	var simulation := _simulate_simple_crafting(
		inventory,
		inventory_stack_counts,
		recipe,
		completed_global_research_ids
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


## 原子地按物品身份消耗一批库存。调用方用 revision 把“检查拥有数量”与
## “实际扣除”绑定到同一份库存快照，适用于需要在服务端确认后才消费的事务。
func try_consume_item_count_if_revision(
	item: PickupConfig,
	count: int,
	expected_revision: int,
	emit_change: bool = true
) -> bool:
	ensure_run_started()
	if active_multiplayer_peer_id > 0:
		return try_consume_item_count_for_peer_if_revision(
			active_multiplayer_peer_id,
			item,
			count,
			expected_revision,
			emit_change
		)
	_ensure_local_inventory_shape()
	if (
		expected_revision != inventory_revision
		or item == null
		or count <= 0
		or _get_item_total_in_arrays(
			inventory,
			inventory_stack_counts,
			item
		) < count
	):
		return false
	if not _consume_item_count_from_arrays(
		inventory,
		inventory_stack_counts,
		item,
		count
	):
		return false
	_bump_local_inventory_revision()
	if emit_change:
		inventory_changed.emit()
	return true


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
	if item.inventory_locked:
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
	var item := inventory[slot_index] as PickupConfig
	if item == null or item.inventory_locked:
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
	var created_inventory := false
	if not multiplayer_inventories.has(peer_id):
		var peer_inventory: Array[PickupConfig] = []
		peer_inventory.resize(INVENTORY_CAPACITY)
		multiplayer_inventories[peer_id] = peer_inventory
		created_inventory = true
	if not multiplayer_inventory_stack_counts.has(peer_id):
		var peer_counts: Array[int] = []
		peer_counts.resize(INVENTORY_CAPACITY)
		peer_counts.fill(0)
		multiplayer_inventory_stack_counts[peer_id] = peer_counts
	if created_inventory and _include_starting_inventory_for_new_peers:
		_seed_starting_inventory(
			multiplayer_inventories[peer_id] as Array,
			multiplayer_inventory_stack_counts[peer_id] as Array
		)
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
	recipe: ProductionRecipe,
	completed_global_research_ids: Array[StringName] = []
) -> StringName:
	ensure_run_started()
	ensure_multiplayer_peer_state(peer_id)
	return _get_crafting_simulation_result(
		_simulate_simple_crafting(
			multiplayer_inventories[peer_id] as Array,
			multiplayer_inventory_stack_counts[peer_id] as Array,
			recipe,
			completed_global_research_ids
		)
	)


func try_craft_inventory_recipe_for_peer_if_revision(
	peer_id: int,
	recipe: ProductionRecipe,
	expected_revision: int,
	emit_change: bool = true,
	completed_global_research_ids: Array[StringName] = []
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
		recipe,
		completed_global_research_ids
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


func try_consume_item_count_for_peer_if_revision(
	peer_id: int,
	item: PickupConfig,
	count: int,
	expected_revision: int,
	emit_change: bool = true
) -> bool:
	ensure_run_started()
	ensure_multiplayer_peer_state(peer_id)
	if (
		expected_revision != get_inventory_revision_for_peer(peer_id)
		or item == null
		or count <= 0
	):
		return false
	var peer_inventory := multiplayer_inventories[peer_id] as Array
	var peer_counts := multiplayer_inventory_stack_counts[peer_id] as Array
	if _get_item_total_in_arrays(peer_inventory, peer_counts, item) < count:
		return false
	if not _consume_item_count_from_arrays(
		peer_inventory,
		peer_counts,
		item,
		count
	):
		return false
	_bump_inventory_revision_for_peer(peer_id)
	if emit_change:
		inventory_changed.emit()
	return true


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
	if item.inventory_locked:
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
	var item := peer_inventory[slot_index] as PickupConfig
	if item == null or item.inventory_locked:
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


func remap_multiplayer_peer_state(
	old_peer_id: int,
	new_peer_id: int,
	replace_existing_target: bool = false
) -> bool:
	if (
		old_peer_id <= 0
		or new_peer_id <= 0
		or old_peer_id == new_peer_id
		or not has_multiplayer_peer_state(old_peer_id)
		or (
			has_multiplayer_peer_state(new_peer_id)
			and not replace_existing_target
		)
	):
		return false
	multiplayer_inventories[new_peer_id] = multiplayer_inventories[old_peer_id]
	multiplayer_inventory_stack_counts[new_peer_id] = (
		multiplayer_inventory_stack_counts[old_peer_id]
	)
	multiplayer_inventory_revisions[new_peer_id] = (
		multiplayer_inventory_revisions[old_peer_id]
	)
	if multiplayer_upgrade_levels.has(old_peer_id):
		multiplayer_upgrade_levels[new_peer_id] = multiplayer_upgrade_levels[old_peer_id]
	multiplayer_inventories.erase(old_peer_id)
	multiplayer_inventory_stack_counts.erase(old_peer_id)
	multiplayer_inventory_revisions.erase(old_peer_id)
	multiplayer_upgrade_levels.erase(old_peer_id)
	if active_multiplayer_peer_id == old_peer_id:
		active_multiplayer_peer_id = new_peer_id
	inventory_changed.emit()
	upgrade_changed.emit()
	return true


## 客户端收到房主全量身份表后清理本局已不再存在的 peer，避免重连前后的
## old/new 背包同时参与默认全队统计。仅处理多人键，不影响单人 peer=0。
func prune_multiplayer_peer_states(
	allowed_peer_ids: PackedInt32Array
) -> int:
	var allowed: Dictionary = {}
	for peer_id in allowed_peer_ids:
		if peer_id > 0:
			allowed[peer_id] = true
	var stale_peer_ids: Array[int] = []
	for raw_peer_id in multiplayer_inventories.keys():
		var peer_id := int(raw_peer_id)
		if peer_id > 0 and not allowed.has(peer_id):
			stale_peer_ids.append(peer_id)
	if stale_peer_ids.is_empty():
		return 0
	for peer_id in stale_peer_ids:
		multiplayer_inventories.erase(peer_id)
		multiplayer_inventory_stack_counts.erase(peer_id)
		multiplayer_inventory_revisions.erase(peer_id)
		multiplayer_upgrade_levels.erase(peer_id)
		if active_multiplayer_peer_id == peer_id:
			active_multiplayer_peer_id = 0
	inventory_changed.emit()
	upgrade_changed.emit()
	return stale_peer_ids.size()


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
	var prepared := prepare_inventory_snapshot_for_peer(
		peer_id,
		snapshot,
		allow_revision_rewind
	)
	return commit_prepared_inventory_snapshot_for_peer(prepared)


## Decodes an authoritative peer inventory snapshot without publishing or
## mutating its arrays. Network transactions can preflight inventory and
## warehouse payloads together before either side becomes observable.
func prepare_inventory_snapshot_for_peer(
	peer_id: int,
	snapshot: Dictionary,
	allow_revision_rewind: bool = false
) -> Dictionary:
	if peer_id <= 0:
		return {}
	ensure_multiplayer_peer_state(peer_id)
	var current_revision := get_inventory_revision_for_peer(peer_id)
	var decoded := _decode_inventory_snapshot(
		snapshot,
		peer_id,
		-1 if allow_revision_rewind else current_revision
	)
	if decoded.is_empty():
		return {}
	decoded["peer_id"] = peer_id
	decoded["expected_current_revision"] = current_revision
	decoded["allow_revision_rewind"] = allow_revision_rewind
	return decoded


func commit_prepared_inventory_snapshot_for_peer(
	prepared: Dictionary,
	emit_change_signal: bool = true
) -> bool:
	var peer_id := int(prepared.get("peer_id", 0))
	if (
		peer_id <= 0
		or not has_multiplayer_peer_state(peer_id)
		or int(prepared.get("expected_current_revision", -1))
		!= get_inventory_revision_for_peer(peer_id)
		or (prepared.get("items", []) as Array).size() != INVENTORY_CAPACITY
		or (prepared.get("counts", []) as Array).size() != INVENTORY_CAPACITY
		or int(prepared.get("revision", -1)) < 0
		or (
			not bool(prepared.get("allow_revision_rewind", false))
			and int(prepared.get("revision", -1))
			< int(prepared.get("expected_current_revision", -1))
		)
	):
		return false
	var prepared_items := prepared["items"] as Array
	var prepared_counts := prepared["counts"] as Array
	for slot_index in INVENTORY_CAPACITY:
		var item := prepared_items[slot_index] as PickupConfig
		var count := int(prepared_counts[slot_index])
		if item == null:
			if count != 0:
				return false
			continue
		if (
			not item.can_store_in_inventory
			or count <= 0
			or count > PickupConfig.get_inventory_stack_limit(item)
		):
			return false
	var peer_inventory := multiplayer_inventories[peer_id] as Array
	var peer_counts := multiplayer_inventory_stack_counts[peer_id] as Array
	peer_inventory.assign(prepared_items)
	peer_counts.assign(prepared_counts)
	multiplayer_inventory_revisions[peer_id] = int(prepared["revision"])
	if emit_change_signal:
		notify_inventory_snapshot_committed()
	return true


func notify_inventory_snapshot_committed() -> void:
	inventory_changed.emit()


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
	if item == null or item.inventory_locked:
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
	if item == null or item.inventory_locked:
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
	if item == null or item.inventory_locked:
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
	if item == null or item.inventory_locked:
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


func get_shared_warehouse_ledger_revision() -> int:
	return shared_warehouse_ledger_revision


## 用场景中 OakWarehouse.export_storage_snapshot() 的结果刷新持久账本。
## 整批快照先完成解码，再一次发布，避免跨仓库的半提交状态。
func replace_shared_warehouse_snapshots(
	snapshots: Array,
	expected_ledger_revision: int = -1,
	emit_change_signal: bool = true
) -> bool:
	ensure_run_started()
	if (
		expected_ledger_revision >= 0
		and expected_ledger_revision != shared_warehouse_ledger_revision
	):
		return false
	var candidate := {
		"schema_version": SHARED_WAREHOUSE_LEDGER_SCHEMA_VERSION,
		"revision": shared_warehouse_ledger_revision + 1,
		"warehouses": snapshots,
	}
	var decoded := _decode_shared_warehouse_ledger(candidate, -1)
	if decoded.is_empty():
		return false
	shared_warehouse_snapshots = decoded["warehouses"] as Dictionary
	shared_warehouse_ledger_revision = int(decoded["revision"])
	if emit_change_signal:
		shared_warehouse_ledger_changed.emit(export_shared_warehouse_ledger())
	return true


func clear_shared_warehouse_ledger(emit_change_signal: bool = true) -> void:
	shared_warehouse_snapshots.clear()
	shared_warehouse_ledger_revision += 1
	if emit_change_signal:
		shared_warehouse_ledger_changed.emit(export_shared_warehouse_ledger())


func export_shared_warehouse_ledger() -> Dictionary:
	var ordered_ids: Array[int] = []
	for raw_warehouse_id in shared_warehouse_snapshots.keys():
		ordered_ids.append(int(raw_warehouse_id))
	ordered_ids.sort()
	var warehouses: Array[Dictionary] = []
	for warehouse_id in ordered_ids:
		warehouses.append(
			(shared_warehouse_snapshots[warehouse_id] as Dictionary).duplicate(true)
		)
	return {
		"schema_version": SHARED_WAREHOUSE_LEDGER_SCHEMA_VERSION,
		"revision": shared_warehouse_ledger_revision,
		"warehouses": warehouses,
	}


func apply_shared_warehouse_ledger_snapshot(
	snapshot: Dictionary,
	allow_revision_rewind: bool = false,
	emit_change_signal: bool = true
) -> bool:
	var minimum_revision := -1 if allow_revision_rewind else shared_warehouse_ledger_revision
	var decoded := _decode_shared_warehouse_ledger(snapshot, minimum_revision)
	if decoded.is_empty():
		return false
	var changed: bool = (
		int(decoded["revision"]) != shared_warehouse_ledger_revision
		or decoded["warehouses"] != shared_warehouse_snapshots
	)
	shared_warehouse_snapshots = decoded["warehouses"] as Dictionary
	shared_warehouse_ledger_revision = int(decoded["revision"])
	if changed and emit_change_signal:
		shared_warehouse_ledger_changed.emit(export_shared_warehouse_ledger())
	return true


func get_shared_warehouse_snapshot(warehouse_net_id: int) -> Dictionary:
	if not shared_warehouse_snapshots.has(warehouse_net_id):
		return {}
	return (
		(shared_warehouse_snapshots[warehouse_net_id] as Dictionary).duplicate(true)
	)


func get_shared_warehouse_item_total(item: PickupConfig) -> int:
	if item == null or item.resource_path.is_empty():
		return 0
	var total := 0
	for warehouse_snapshot_value in shared_warehouse_snapshots.values():
		var warehouse_snapshot := warehouse_snapshot_value as Dictionary
		for raw_slot_value in warehouse_snapshot.get("slots", []) as Array:
			var slot := raw_slot_value as Dictionary
			if str(slot.get("config_path", "")) == item.resource_path:
				total += int(slot.get("stack_count", 0))
	return total


func get_registered_inventory_peer_ids() -> PackedInt32Array:
	var peer_ids := PackedInt32Array()
	if multiplayer_inventories.is_empty():
		peer_ids.append(0)
		return peer_ids
	var ordered_peer_ids: Array[int] = []
	for raw_peer_id in multiplayer_inventories.keys():
		var peer_id := int(raw_peer_id)
		if peer_id > 0:
			ordered_peer_ids.append(peer_id)
	ordered_peer_ids.sort()
	for peer_id in ordered_peer_ids:
		peer_ids.append(peer_id)
	return peer_ids


func get_party_item_total(
	item: PickupConfig,
	peer_ids: PackedInt32Array = PackedInt32Array()
) -> int:
	ensure_run_started()
	if item == null:
		return 0
	var resolved_peer_ids := (
		peer_ids.duplicate()
		if not peer_ids.is_empty()
		else get_registered_inventory_peer_ids()
	)
	var seen_peer_ids: Dictionary = {}
	var total := get_shared_warehouse_item_total(item)
	for peer_id in resolved_peer_ids:
		if seen_peer_ids.has(peer_id):
			continue
		seen_peer_ids[peer_id] = true
		if peer_id == 0:
			total += get_inventory_item_total(item)
		elif peer_id > 0:
			total += get_inventory_item_total_for_peer(peer_id, item)
	return total


func has_party_item(
	item: PickupConfig,
	peer_ids: PackedInt32Array = PackedInt32Array()
) -> bool:
	return get_party_item_total(item, peer_ids) > 0


func export_party_economy_snapshot(
	peer_ids: PackedInt32Array = PackedInt32Array()
) -> Dictionary:
	ensure_run_started()
	var resolved_peer_ids := (
		peer_ids.duplicate()
		if not peer_ids.is_empty()
		else get_registered_inventory_peer_ids()
	)
	resolved_peer_ids.sort()
	var inventories: Array[Dictionary] = []
	var seen_peer_ids: Dictionary = {}
	for peer_id in resolved_peer_ids:
		if seen_peer_ids.has(peer_id) or peer_id < 0:
			continue
		seen_peer_ids[peer_id] = true
		inventories.append(
			export_inventory_snapshot()
			if peer_id == 0
			else export_inventory_snapshot_for_peer(peer_id)
		)
	return {
		"schema_version": PARTY_ECONOMY_SCHEMA_VERSION,
		"warehouse_ledger": export_shared_warehouse_ledger(),
		"inventories": inventories,
	}


## 应用来自房主的全量经济快照。所有仓库和玩家背包先解码、再一起提交。
func apply_party_economy_snapshot(
	snapshot: Dictionary,
	allow_revision_rewind: bool = false
) -> bool:
	var prepared := _prepare_party_economy_snapshot(
		snapshot,
		allow_revision_rewind,
		false,
		-1,
		{}
	)
	return _commit_prepared_party_economy_snapshot(prepared)


## 遭遇等房主事务使用的单步 CAS。next snapshot 中每个发生变化的 store
## 必须只前进一个 revision；全部基准 revision 在首个写入前统一复核。
func apply_authoritative_party_transaction(
	next_snapshot: Dictionary,
	expected_warehouse_ledger_revision: int,
	expected_inventory_revisions: Dictionary
) -> bool:
	var prepared := _prepare_party_economy_snapshot(
		next_snapshot,
		false,
		true,
		expected_warehouse_ledger_revision,
		expected_inventory_revisions
	)
	return _commit_prepared_party_economy_snapshot(prepared)


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
		or stack_count > PickupConfig.get_inventory_stack_limit(item)
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


func _decode_shared_warehouse_ledger(
	snapshot: Dictionary,
	minimum_revision: int
) -> Dictionary:
	if (
		typeof(snapshot.get("schema_version")) != TYPE_INT
		or int(snapshot["schema_version"])
		!= SHARED_WAREHOUSE_LEDGER_SCHEMA_VERSION
		or typeof(snapshot.get("revision")) != TYPE_INT
	):
		return {}
	var incoming_revision := int(snapshot["revision"])
	if incoming_revision < 0 or incoming_revision < minimum_revision:
		return {}
	var raw_warehouses_value: Variant = snapshot.get("warehouses")
	if typeof(raw_warehouses_value) != TYPE_ARRAY:
		return {}
	var decoded_warehouses: Dictionary = {}
	for raw_warehouse_value in raw_warehouses_value as Array:
		if typeof(raw_warehouse_value) != TYPE_DICTIONARY:
			return {}
		var decoded_warehouse := _decode_shared_warehouse_snapshot(
			raw_warehouse_value as Dictionary
		)
		if decoded_warehouse.is_empty():
			return {}
		var warehouse_net_id := int(decoded_warehouse["warehouse_net_id"])
		if decoded_warehouses.has(warehouse_net_id):
			return {}
		decoded_warehouses[warehouse_net_id] = decoded_warehouse
	return {
		"revision": incoming_revision,
		"warehouses": decoded_warehouses,
	}


func _decode_shared_warehouse_snapshot(snapshot: Dictionary) -> Dictionary:
	if (
		typeof(snapshot.get("warehouse_net_id")) != TYPE_INT
		or int(snapshot["warehouse_net_id"]) <= 0
		or typeof(snapshot.get("revision")) != TYPE_INT
		or int(snapshot["revision"]) < 0
	):
		return {}
	var raw_slots_value: Variant = snapshot.get("slots")
	if typeof(raw_slots_value) != TYPE_ARRAY:
		return {}
	var raw_slots := raw_slots_value as Array
	if raw_slots.size() != INVENTORY_CAPACITY:
		return {}
	var normalized_slots: Array[Dictionary] = []
	normalized_slots.resize(INVENTORY_CAPACITY)
	var seen_slots: Dictionary = {}
	for raw_slot_value in raw_slots:
		if typeof(raw_slot_value) != TYPE_DICTIONARY:
			return {}
		var raw_slot := raw_slot_value as Dictionary
		var slot_index := int(raw_slot.get("slot_index", -1))
		if (
			slot_index < 0
			or slot_index >= INVENTORY_CAPACITY
			or seen_slots.has(slot_index)
		):
			return {}
		seen_slots[slot_index] = true
		var config_path := str(raw_slot.get("config_path", ""))
		var stack_count := int(raw_slot.get("stack_count", 0))
		var decoded_item := _decode_inventory_item(config_path, stack_count)
		if not bool(decoded_item.get("valid", false)):
			return {}
		normalized_slots[slot_index] = {
			"slot_index": slot_index,
			"config_path": config_path,
			"stack_count": stack_count,
		}
	return {
		"warehouse_net_id": int(snapshot["warehouse_net_id"]),
		"revision": int(snapshot["revision"]),
		"slots": normalized_slots,
	}


func _prepare_party_economy_snapshot(
	snapshot: Dictionary,
	allow_revision_rewind: bool,
	require_single_revision_step: bool,
	expected_warehouse_revision: int,
	expected_inventory_revisions: Dictionary
) -> Dictionary:
	ensure_run_started()
	if (
		typeof(snapshot.get("schema_version")) != TYPE_INT
		or int(snapshot["schema_version"]) != PARTY_ECONOMY_SCHEMA_VERSION
		or typeof(snapshot.get("warehouse_ledger")) != TYPE_DICTIONARY
		or typeof(snapshot.get("inventories")) != TYPE_ARRAY
	):
		return {}
	if (
		require_single_revision_step
		and expected_warehouse_revision != shared_warehouse_ledger_revision
	):
		return {}
	var decoded_ledger := _decode_shared_warehouse_ledger(
		snapshot["warehouse_ledger"] as Dictionary,
		-1 if allow_revision_rewind else shared_warehouse_ledger_revision
	)
	if decoded_ledger.is_empty():
		return {}
	var incoming_ledger_revision := int(decoded_ledger["revision"])
	if (
		require_single_revision_step
		and incoming_ledger_revision != shared_warehouse_ledger_revision
		and incoming_ledger_revision != shared_warehouse_ledger_revision + 1
	):
		return {}

	var prepared_inventories: Dictionary = {}
	for raw_inventory_value in snapshot["inventories"] as Array:
		if typeof(raw_inventory_value) != TYPE_DICTIONARY:
			return {}
		var raw_inventory := raw_inventory_value as Dictionary
		if typeof(raw_inventory.get("peer_id")) != TYPE_INT:
			return {}
		var peer_id := int(raw_inventory["peer_id"])
		if peer_id < 0 or prepared_inventories.has(peer_id):
			return {}
		var current_revision := _get_inventory_revision_without_creating(peer_id)
		if require_single_revision_step:
			if (
				not expected_inventory_revisions.has(peer_id)
				or int(expected_inventory_revisions[peer_id]) != current_revision
			):
				return {}
		var decoded_inventory := _decode_inventory_snapshot(
			raw_inventory,
			peer_id,
			-1 if allow_revision_rewind else current_revision
		)
		if decoded_inventory.is_empty():
			return {}
		var incoming_revision := int(decoded_inventory["revision"])
		if (
			require_single_revision_step
			and incoming_revision != current_revision
			and incoming_revision != current_revision + 1
		):
			return {}
		decoded_inventory["expected_current_revision"] = current_revision
		prepared_inventories[peer_id] = decoded_inventory
	return {
		"expected_warehouse_revision": shared_warehouse_ledger_revision,
		"warehouse_ledger": decoded_ledger,
		"inventories": prepared_inventories,
	}


func _commit_prepared_party_economy_snapshot(prepared: Dictionary) -> bool:
	if (
		prepared.is_empty()
		or int(prepared.get("expected_warehouse_revision", -1))
		!= shared_warehouse_ledger_revision
	):
		return false
	var prepared_inventories := prepared.get("inventories", {}) as Dictionary
	for raw_peer_id in prepared_inventories.keys():
		var peer_id := int(raw_peer_id)
		var prepared_inventory := prepared_inventories[raw_peer_id] as Dictionary
		if (
			int(prepared_inventory.get("expected_current_revision", -1))
			!= _get_inventory_revision_without_creating(peer_id)
		):
			return false

	var prepared_ledger := prepared["warehouse_ledger"] as Dictionary
	var ledger_changed: bool = (
		int(prepared_ledger["revision"]) != shared_warehouse_ledger_revision
		or prepared_ledger["warehouses"] != shared_warehouse_snapshots
	)
	shared_warehouse_snapshots = prepared_ledger["warehouses"] as Dictionary
	shared_warehouse_ledger_revision = int(prepared_ledger["revision"])

	var any_inventory_changed := false
	for raw_peer_id in prepared_inventories.keys():
		var peer_id := int(raw_peer_id)
		var prepared_inventory := prepared_inventories[raw_peer_id] as Dictionary
		var next_items := prepared_inventory["items"] as Array
		var next_counts := prepared_inventory["counts"] as Array
		var next_revision := int(prepared_inventory["revision"])
		if peer_id == 0:
			_ensure_local_inventory_shape()
			any_inventory_changed = any_inventory_changed or (
				next_revision != inventory_revision
				or next_items != inventory
				or next_counts != inventory_stack_counts
			)
			inventory.assign(next_items)
			inventory_stack_counts.assign(next_counts)
			inventory_revision = next_revision
			continue
		ensure_multiplayer_peer_state(peer_id)
		var peer_items := multiplayer_inventories[peer_id] as Array
		var peer_counts := multiplayer_inventory_stack_counts[peer_id] as Array
		any_inventory_changed = any_inventory_changed or (
			next_revision != get_inventory_revision_for_peer(peer_id)
			or next_items != peer_items
			or next_counts != peer_counts
		)
		peer_items.assign(next_items)
		peer_counts.assign(next_counts)
		multiplayer_inventory_revisions[peer_id] = next_revision

	# 对外只在整个批次均已写入后各发布一次信号。
	if any_inventory_changed:
		inventory_changed.emit()
	if ledger_changed:
		shared_warehouse_ledger_changed.emit(export_shared_warehouse_ledger())
	return true


func _get_inventory_revision_without_creating(peer_id: int) -> int:
	if peer_id == 0:
		return inventory_revision
	if peer_id < 0:
		return -1
	return int(multiplayer_inventory_revisions.get(peer_id, 0))


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


func _seed_starting_inventory(items: Array, counts: Array) -> void:
	_add_item_count_to_arrays(items, counts, STARTING_WOOD, STARTING_WOOD_COUNT)


func _can_consume_expected_item(
	items: Array,
	slot_index: int,
	expected_item: PickupConfig
) -> bool:
	var stored_item := (
		items[slot_index] as PickupConfig
		if slot_index >= 0 and slot_index < items.size()
		else null
	)
	return (
		stored_item != null
		and not stored_item.inventory_locked
		and PickupConfig.inventory_identity_matches(
			stored_item,
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


func _get_available_item_capacity(
	items: Array,
	counts: Array,
	item: PickupConfig
) -> int:
	if item == null:
		return 0

	var stack_limit := PickupConfig.get_inventory_stack_limit(item)
	var capacity := 0
	for slot_index in range(items.size()):
		var stored_item := items[slot_index] as PickupConfig
		if stored_item == null:
			capacity += stack_limit
		elif PickupConfig.inventory_items_can_stack(stored_item, item):
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
		return count <= PickupConfig.get_inventory_stack_limit(item)
	if not PickupConfig.inventory_items_can_stack(target_item, item):
		return false
	return (
		int(counts[target_slot_index]) + count
		<= PickupConfig.get_inventory_stack_limit(item)
	)


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
	if source_item == null or source_item.inventory_locked:
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
	var stack_limit := PickupConfig.get_inventory_stack_limit(item)
	if item.stackable:
		for slot_index in range(items.size()):
			if not PickupConfig.inventory_items_can_stack(
				items[slot_index] as PickupConfig,
				item
			):
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
	recipe: ProductionRecipe,
	completed_global_research_ids: Array[StringName] = []
) -> Dictionary:
	if not SimpleCraftingRegistry.is_simple_crafting_recipe(recipe):
		return {"result": CRAFT_RESULT_INVALID_RECIPE}
	if not SimpleCraftingRegistry.is_recipe_unlocked(
		recipe,
		completed_global_research_ids
	):
		return {"result": CRAFT_RESULT_RESEARCH_LOCKED}
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
		var stored_item := items[slot_index] as PickupConfig
		if stored_item == null or stored_item.inventory_locked:
			continue
		if not PickupConfig.inventory_identity_matches(
			stored_item,
			item
		):
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
		if PickupConfig.inventory_identity_matches(
			items[slot_index] as PickupConfig,
			item
		):
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
