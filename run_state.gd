extends Node
class_name RunStateStore

signal inventory_changed
signal quick_use_binding_changed(
	owner_peer_id: int,
	config_path: String,
	preferred_slot_index: int
)
signal upgrade_changed
signal selected_character_changed(character_id: StringName)
signal shared_warehouse_ledger_changed(snapshot: Dictionary)
signal party_xirang_ledger_changed(snapshot: Dictionary)
signal party_light_stone_ledger_changed(snapshot: Dictionary)
signal party_status_ledger_changed(snapshot: Dictionary)
signal rogue_encounter_history_changed(snapshot: Dictionary)

const INVENTORY_CAPACITY := 20
const PARTY_ECONOMY_SCHEMA_VERSION := 7
const SHARED_WAREHOUSE_LEDGER_SCHEMA_VERSION := 1
const PARTY_XIRANG_LEDGER_SCHEMA_VERSION := 1
const PARTY_LIGHT_STONE_LEDGER_SCHEMA_VERSION := 1
const PARTY_STATUS_LEDGER_SCHEMA_VERSION := 3
const ROGUE_ENCOUNTER_HISTORY_LEDGER_SCHEMA_VERSION := 1
const DEFAULT_PARTY_CORE_HEALTH := 100
const PLAYER_STAT_BONUS_KEYS: Array[StringName] = [
	&"max_health",
	&"physical_defense",
	&"magic_defense",
	&"move_speed",
	&"ammo_capacity",
	&"attack_damage",
	&"dodge_percent_points",
	&"dash_cooldown_reduction",
]
const PLAYER_STAT_BONUS_HARD_CAPS := {
	&"max_health": 2147483647,
	&"physical_defense": 2147483647,
	&"magic_defense": 100,
	&"move_speed": 2147483647,
	&"ammo_capacity": 65535,
	&"attack_damage": 2147483647,
	&"dodge_percent_points": 100,
	&"dash_cooldown_reduction": 2147483647,
}
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
## Per-run, presentation-facing shortcut preferences. These are deliberately
## separate from authoritative inventory snapshots and revisions: clients resolve
## their own binding to a concrete slot, then reuse the normal reliable use
## transaction. A missing stack leaves the binding dormant until the item returns.
var _quick_use_bindings_by_owner: Dictionary[int, Dictionary] = {}
## OakWarehouse 的跨场景 wire 快照。路线场景没有仓库节点，因此只保留
## 可验证的 config_path/count 数据，不持有已卸载场景中的 Node 引用。
var shared_warehouse_snapshots: Dictionary = {}
var shared_warehouse_ledger_revision: int = 0
## 路线、遭遇与重连共享的息壤绝对余额。键为 peer_id；单人使用 0。
## 余额与背包、仓库一同进入 party economy 快照，避免重复快照重复加钱。
var party_xirang_balances: Dictionary = {}
var party_xirang_ledger_revision: int = 0
## Rogue 路线共用的共享光石。该资源属于全队而非某个 peer，并以独立
## revision 参与 party economy CAS，确保扣除光石与发放奖励可以原子提交。
var party_light_stone_amount: int = 0
var party_light_stone_ledger_revision: int = 0
## Rouge 路线、遭遇、战斗与塔防共享的本局队伍状态。最大生命惩罚按
## peer 累计；单人使用 peer=0。运行时内部使用 int 键，wire 快照使用字符串键。
var party_core_current: int = DEFAULT_PARTY_CORE_HEALTH
var party_core_maximum: int = DEFAULT_PARTY_CORE_HEALTH
var max_health_penalties: Dictionary = {}
## 稀有宝箱等本局永久来源提供的玩家属性绝对总值。内部与 wire 均使用
## 固定八字段字典，避免重连、重复快照或换场时再次按 delta 叠加。
var player_stat_bonuses: Dictionary = {}
var party_status_ledger_revision: int = 0
## 本局已经启动过的神奇遭遇稳定 ID。该历史属于整局共享状态，不按玩家
## 拆分；房主只在成功启动节点时追加，客户端只能通过权威快照恢复。
var rogue_encounter_history_revision: int = 0
var rogue_encounter_ids: Dictionary = {}
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
	_clear_all_quick_use_bindings()
	shared_warehouse_snapshots.clear()
	shared_warehouse_ledger_revision = 0
	party_xirang_balances = {0: 0}
	party_xirang_ledger_revision = 0
	party_light_stone_amount = 0
	party_light_stone_ledger_revision = 0
	party_core_current = DEFAULT_PARTY_CORE_HEALTH
	party_core_maximum = DEFAULT_PARTY_CORE_HEALTH
	max_health_penalties = {0: 0}
	player_stat_bonuses = {0: _make_empty_player_stat_bonuses()}
	party_status_ledger_revision = 0
	rogue_encounter_history_revision = 0
	rogue_encounter_ids.clear()
	run_started = true
	inventory_changed.emit()
	upgrade_changed.emit()


func ensure_run_started() -> void:
	if run_started:
		return
	begin_new_run(selected_character_id)


func record_rogue_encounter(encounter_id: StringName) -> bool:
	ensure_run_started()
	if (
		encounter_id.is_empty()
		or not RogueEncounterRegistry.has_encounter(encounter_id)
		or not RogueEncounterRegistry.get_pool_entries(
			RogueEncounterRegistry.MAGICAL_ENCOUNTER_POOL
		).has(encounter_id)
	):
		return false
	if rogue_encounter_ids.has(encounter_id):
		return true
	rogue_encounter_ids[encounter_id] = true
	rogue_encounter_history_revision += 1
	rogue_encounter_history_changed.emit(export_rogue_encounter_history_ledger())
	return true


func has_rogue_encountered(encounter_id: StringName) -> bool:
	ensure_run_started()
	return rogue_encounter_ids.has(encounter_id)


func get_rogue_encountered_ids() -> Array[StringName]:
	ensure_run_started()
	var result: Array[StringName] = []
	for encounter_id in RogueEncounterRegistry.get_pool_entries(
		RogueEncounterRegistry.MAGICAL_ENCOUNTER_POOL
	):
		if rogue_encounter_ids.has(encounter_id):
			result.append(encounter_id)
	return result


func export_rogue_encounter_history_ledger() -> Dictionary:
	ensure_run_started()
	var encounter_ids: Array[String] = []
	for encounter_id in get_rogue_encountered_ids():
		encounter_ids.append(String(encounter_id))
	return {
		"schema_version": ROGUE_ENCOUNTER_HISTORY_LEDGER_SCHEMA_VERSION,
		"revision": rogue_encounter_history_revision,
		"encounter_ids": encounter_ids,
	}


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
	if item.inventory_locked or not item.is_consumable_item():
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


## Binds one consumable stack for the current run without mutating inventory
## contents or its optimistic-concurrency revision. owner_peer_id=-1 means the
## currently active local inventory; 0 is single-player and positive ids are
## multiplayer inventory owners.
func set_quick_use_binding(
	slot_index: int,
	owner_peer_id: int = -1
) -> bool:
	ensure_run_started()
	var resolved_owner := _resolve_quick_use_owner_peer_id(owner_peer_id)
	var item := _get_quick_use_item_at_slot(resolved_owner, slot_index)
	if (
		item == null
		or item.inventory_locked
		or not item.is_consumable_item()
		or item.resource_path.is_empty()
	):
		return false
	var config_path := item.resource_path
	var current := _quick_use_bindings_by_owner.get(resolved_owner, {}) as Dictionary
	if (
		str(current.get("config_path", "")) == config_path
		and int(current.get("preferred_slot_index", -1)) == slot_index
	):
		return true
	_quick_use_bindings_by_owner[resolved_owner] = {
		"config_path": config_path,
		"preferred_slot_index": slot_index,
	}
	quick_use_binding_changed.emit(resolved_owner, config_path, slot_index)
	return true


func toggle_quick_use_binding(
	slot_index: int,
	owner_peer_id: int = -1
) -> bool:
	var resolved_owner := _resolve_quick_use_owner_peer_id(owner_peer_id)
	if is_quick_use_slot(slot_index, resolved_owner):
		return clear_quick_use_binding(resolved_owner)
	return set_quick_use_binding(slot_index, resolved_owner)


func clear_quick_use_binding(owner_peer_id: int = -1) -> bool:
	var resolved_owner := _resolve_quick_use_owner_peer_id(owner_peer_id)
	if not _quick_use_bindings_by_owner.has(resolved_owner):
		return false
	_quick_use_bindings_by_owner.erase(resolved_owner)
	quick_use_binding_changed.emit(resolved_owner, "", -1)
	return true


func get_quick_use_bound_config_path(owner_peer_id: int = -1) -> String:
	var resolved_owner := _resolve_quick_use_owner_peer_id(owner_peer_id)
	var binding := _quick_use_bindings_by_owner.get(resolved_owner, {}) as Dictionary
	return str(binding.get("config_path", ""))


## Resolves a binding against the latest inventory shape. The preferred slot is
## retained while it still contains that item; otherwise the lowest matching
## slot becomes preferred. No match keeps the item path dormant and returns -1.
func get_quick_use_slot_index(owner_peer_id: int = -1) -> int:
	var resolved_owner := _resolve_quick_use_owner_peer_id(owner_peer_id)
	if not _quick_use_bindings_by_owner.has(resolved_owner):
		return -1
	var binding := _quick_use_bindings_by_owner[resolved_owner] as Dictionary
	var config_path := str(binding.get("config_path", ""))
	if config_path.is_empty():
		return -1
	var preferred_slot_index := int(binding.get("preferred_slot_index", -1))
	if _quick_use_slot_matches_path(
		resolved_owner,
		preferred_slot_index,
		config_path
	):
		return preferred_slot_index
	for slot_index in INVENTORY_CAPACITY:
		if not _quick_use_slot_matches_path(resolved_owner, slot_index, config_path):
			continue
		binding["preferred_slot_index"] = slot_index
		_quick_use_bindings_by_owner[resolved_owner] = binding
		return slot_index
	binding["preferred_slot_index"] = -1
	_quick_use_bindings_by_owner[resolved_owner] = binding
	return -1


func is_quick_use_slot(
	slot_index: int,
	owner_peer_id: int = -1
) -> bool:
	return slot_index >= 0 and slot_index == get_quick_use_slot_index(owner_peer_id)


func is_quick_use_item(
	item: PickupConfig,
	owner_peer_id: int = -1
) -> bool:
	return (
		item != null
		and item.is_consumable_item()
		and not item.resource_path.is_empty()
		and item.resource_path == get_quick_use_bound_config_path(owner_peer_id)
	)


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
		player.set_xirang_balance(player.current_xirang - upgrade_cost)
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


## 当前本地界面所映射的多人背包 owner。0 表示使用单人背包。
## 外部系统只能通过此只读接口观察映射，避免依赖 RunState 的存储字段。
func get_active_multiplayer_peer_id() -> int:
	return active_multiplayer_peer_id


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
	if not party_xirang_balances.has(peer_id):
		party_xirang_balances[peer_id] = 0
		party_xirang_ledger_revision += 1
		party_xirang_ledger_changed.emit(export_party_xirang_ledger())
	var status_ledger_changed := false
	if not max_health_penalties.has(peer_id):
		max_health_penalties[peer_id] = 0
		status_ledger_changed = true
	if not player_stat_bonuses.has(peer_id):
		player_stat_bonuses[peer_id] = _make_empty_player_stat_bonuses()
		status_ledger_changed = true
	if status_ledger_changed:
		party_status_ledger_revision += 1
		party_status_ledger_changed.emit(export_party_status_ledger())


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
	if item.inventory_locked or not item.is_consumable_item():
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


## Atomically migrates a reconnect identity. When independent reliable channels
## deliver the Host's new-id inventory before the old->new identity RPC, clients
## may preserve that equal-or-newer inventory while still migrating the old
## peer's upgrades and party ledgers. Only one final signal set is published.
func remap_multiplayer_peer_state(
	old_peer_id: int,
	new_peer_id: int,
	replace_existing_target: bool = false,
	preserve_newer_target_inventory: bool = false
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
	var keep_target_inventory := (
		preserve_newer_target_inventory
		and has_multiplayer_peer_state(new_peer_id)
		and get_inventory_revision_for_peer(new_peer_id)
		>= get_inventory_revision_for_peer(old_peer_id)
	)
	var remapped_inventory: Array = (
		multiplayer_inventories[new_peer_id] as Array
		if keep_target_inventory
		else multiplayer_inventories[old_peer_id] as Array
	)
	var remapped_counts: Array = (
		multiplayer_inventory_stack_counts[new_peer_id] as Array
		if keep_target_inventory
		else multiplayer_inventory_stack_counts[old_peer_id] as Array
	)
	var remapped_revision: int = int(
		multiplayer_inventory_revisions[new_peer_id]
		if keep_target_inventory
		else multiplayer_inventory_revisions[old_peer_id]
	)
	multiplayer_inventories[new_peer_id] = remapped_inventory
	multiplayer_inventory_stack_counts[new_peer_id] = remapped_counts
	multiplayer_inventory_revisions[new_peer_id] = remapped_revision
	_remap_quick_use_binding(old_peer_id, new_peer_id, keep_target_inventory)
	if multiplayer_upgrade_levels.has(old_peer_id):
		multiplayer_upgrade_levels[new_peer_id] = multiplayer_upgrade_levels[old_peer_id]
	if party_xirang_balances.has(old_peer_id):
		party_xirang_balances[new_peer_id] = int(party_xirang_balances[old_peer_id])
		party_xirang_balances.erase(old_peer_id)
		party_xirang_ledger_revision += 1
	var status_ledger_remapped := false
	if max_health_penalties.has(old_peer_id):
		max_health_penalties[new_peer_id] = int(max_health_penalties[old_peer_id])
		max_health_penalties.erase(old_peer_id)
		status_ledger_remapped = true
	if player_stat_bonuses.has(old_peer_id):
		player_stat_bonuses[new_peer_id] = (
			player_stat_bonuses[old_peer_id] as Dictionary
		).duplicate(true)
		player_stat_bonuses.erase(old_peer_id)
		status_ledger_remapped = true
	if status_ledger_remapped:
		party_status_ledger_revision += 1
	multiplayer_inventories.erase(old_peer_id)
	multiplayer_inventory_stack_counts.erase(old_peer_id)
	multiplayer_inventory_revisions.erase(old_peer_id)
	multiplayer_upgrade_levels.erase(old_peer_id)
	if active_multiplayer_peer_id == old_peer_id:
		active_multiplayer_peer_id = new_peer_id
	inventory_changed.emit()
	upgrade_changed.emit()
	party_xirang_ledger_changed.emit(export_party_xirang_ledger())
	party_status_ledger_changed.emit(export_party_status_ledger())
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
		clear_quick_use_binding(peer_id)
		multiplayer_inventories.erase(peer_id)
		multiplayer_inventory_stack_counts.erase(peer_id)
		multiplayer_inventory_revisions.erase(peer_id)
		multiplayer_upgrade_levels.erase(peer_id)
		party_xirang_balances.erase(peer_id)
		max_health_penalties.erase(peer_id)
		player_stat_bonuses.erase(peer_id)
		if active_multiplayer_peer_id == peer_id:
			active_multiplayer_peer_id = 0
	inventory_changed.emit()
	upgrade_changed.emit()
	party_xirang_ledger_revision += 1
	party_xirang_ledger_changed.emit(export_party_xirang_ledger())
	party_status_ledger_revision += 1
	party_status_ledger_changed.emit(export_party_status_ledger())
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
	# Inventory revisions are a monotonic cross-channel fence. A CH0 combat
	# settlement can legitimately overtake an older CH6 repair response; allowing
	# that response to rewind the revision would also discard settlement loot.
	# Keep the compatibility flag for callers that request an authoritative repair,
	# but never let it authorize an older wire revision over newer local state.
	var snapshot_revision := int(snapshot.get("revision", -1))
	if snapshot_revision < current_revision:
		return {}
	var decoded := _decode_inventory_snapshot(
		snapshot,
		peer_id,
		current_revision
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


func get_party_xirang_ledger_revision() -> int:
	return party_xirang_ledger_revision


func get_party_xirang_balance(peer_id: int) -> int:
	ensure_run_started()
	if peer_id < 0:
		return 0
	if peer_id > 0:
		ensure_multiplayer_peer_state(peer_id)
	elif not party_xirang_balances.has(0):
		party_xirang_balances[0] = 0
	return maxi(int(party_xirang_balances.get(peer_id, 0)), 0)


func set_party_xirang_balance(
	peer_id: int,
	amount: int,
	emit_change_signal: bool = true
) -> bool:
	ensure_run_started()
	if peer_id < 0 or amount < 0:
		return false
	if peer_id > 0:
		ensure_multiplayer_peer_state(peer_id)
	var clamped_amount := maxi(amount, 0)
	if int(party_xirang_balances.get(peer_id, 0)) == clamped_amount:
		return true
	party_xirang_balances[peer_id] = clamped_amount
	party_xirang_ledger_revision += 1
	if emit_change_signal:
		party_xirang_ledger_changed.emit(export_party_xirang_ledger())
	return true


## Applies one authoritative combat settlement as a single ledger revision and
## signal, so route listeners can never observe a half-updated multiplayer map.
func set_party_xirang_balances(
	balances: Dictionary,
	emit_change_signal: bool = true
) -> bool:
	ensure_run_started()
	if balances.is_empty():
		return false
	var normalized: Dictionary[int, int] = {}
	for peer_id_variant in balances.keys():
		if typeof(peer_id_variant) != TYPE_INT:
			return false
		var peer_id := int(peer_id_variant)
		if (
			peer_id < 0
			or normalized.has(peer_id)
			or typeof(balances[peer_id_variant]) != TYPE_INT
			or int(balances[peer_id_variant]) < 0
			or (peer_id > 0 and not has_multiplayer_peer_state(peer_id))
		):
			return false
		normalized[peer_id] = int(balances[peer_id_variant])
	var changed := false
	for peer_id in normalized:
		var amount: int = normalized[peer_id]
		if int(party_xirang_balances.get(peer_id, 0)) == amount:
			continue
		party_xirang_balances[peer_id] = amount
		changed = true
	if not changed:
		return true
	party_xirang_ledger_revision += 1
	if emit_change_signal:
		party_xirang_ledger_changed.emit(export_party_xirang_ledger())
	return true


func export_party_xirang_ledger() -> Dictionary:
	ensure_run_started()
	var values: Dictionary = {}
	var peer_ids: Array[int] = []
	for raw_peer_id in party_xirang_balances.keys():
		var peer_id := int(raw_peer_id)
		if peer_id >= 0 and not peer_ids.has(peer_id):
			peer_ids.append(peer_id)
	peer_ids.sort()
	for peer_id in peer_ids:
		values[str(peer_id)] = maxi(
			int(party_xirang_balances.get(peer_id, 0)),
			0
		)
	return {
		"schema_version": PARTY_XIRANG_LEDGER_SCHEMA_VERSION,
		"revision": party_xirang_ledger_revision,
		"values": values,
	}


func get_party_light_stone_ledger_revision() -> int:
	ensure_run_started()
	return party_light_stone_ledger_revision


func get_party_light_stone_amount() -> int:
	ensure_run_started()
	return party_light_stone_amount


func set_party_light_stone_amount(
	amount: int,
	emit_change_signal: bool = true
) -> bool:
	ensure_run_started()
	if amount < 0:
		return false
	if party_light_stone_amount == amount:
		return true
	party_light_stone_amount = amount
	party_light_stone_ledger_revision += 1
	if emit_change_signal:
		party_light_stone_ledger_changed.emit(export_party_light_stone_ledger())
	return true


## 对共享光石账本执行一次 revision-fenced 权威变更。负数代表扣除；余额
## 不足或 revision 已陈旧时整笔拒绝，且不会产生 signal 或 revision 空洞。
func try_change_party_light_stone_amount(
	delta: int,
	expected_revision: int = -1,
	emit_change_signal: bool = true
) -> bool:
	ensure_run_started()
	if (
		expected_revision >= 0
		and expected_revision != party_light_stone_ledger_revision
	):
		return false
	if delta == 0:
		return true
	var next_amount := party_light_stone_amount + delta
	if next_amount < 0:
		return false
	party_light_stone_amount = next_amount
	party_light_stone_ledger_revision += 1
	if emit_change_signal:
		party_light_stone_ledger_changed.emit(export_party_light_stone_ledger())
	return true


func export_party_light_stone_ledger() -> Dictionary:
	ensure_run_started()
	return {
		"schema_version": PARTY_LIGHT_STONE_LEDGER_SCHEMA_VERSION,
		"revision": party_light_stone_ledger_revision,
		"amount": party_light_stone_amount,
	}


func apply_party_light_stone_ledger(
	snapshot: Dictionary,
	allow_revision_rewind: bool = false,
	emit_change_signal: bool = true
) -> bool:
	ensure_run_started()
	var decoded := _decode_party_light_stone_ledger(
		snapshot,
		-1 if allow_revision_rewind else party_light_stone_ledger_revision
	)
	if decoded.is_empty():
		return false
	var incoming_revision := int(decoded["revision"])
	var incoming_amount := int(decoded["amount"])
	if (
		not allow_revision_rewind
		and incoming_revision == party_light_stone_ledger_revision
		and incoming_amount != party_light_stone_amount
	):
		return false
	var changed := (
		incoming_revision != party_light_stone_ledger_revision
		or incoming_amount != party_light_stone_amount
	)
	party_light_stone_amount = incoming_amount
	party_light_stone_ledger_revision = incoming_revision
	if changed and emit_change_signal:
		party_light_stone_ledger_changed.emit(export_party_light_stone_ledger())
	return true


func get_party_status_ledger_revision() -> int:
	ensure_run_started()
	return party_status_ledger_revision


func get_party_core_health() -> int:
	ensure_run_started()
	return party_core_current


func get_party_core_maximum_health() -> int:
	ensure_run_started()
	return party_core_maximum


func set_party_core_health(
	current_health: int,
	maximum_health: int = -1,
	emit_change_signal: bool = true
) -> bool:
	ensure_run_started()
	if current_health < 0 or maximum_health < -1 or maximum_health == 0:
		return false
	var resolved_maximum := (
		party_core_maximum
		if maximum_health < 0
		else maximum_health
	)
	resolved_maximum = maxi(resolved_maximum, 1)
	var resolved_current := clampi(current_health, 0, resolved_maximum)
	if (
		party_core_current == resolved_current
		and party_core_maximum == resolved_maximum
	):
		return true
	party_core_current = resolved_current
	party_core_maximum = resolved_maximum
	party_status_ledger_revision += 1
	if emit_change_signal:
		party_status_ledger_changed.emit(export_party_status_ledger())
	return true


func apply_party_core_health_loss(
	amount: int,
	emit_change_signal: bool = true
) -> int:
	ensure_run_started()
	if amount <= 0 or party_core_current <= 0:
		return 0
	var previous_health := party_core_current
	party_core_current = maxi(party_core_current - amount, 0)
	party_status_ledger_revision += 1
	if emit_change_signal:
		party_status_ledger_changed.emit(export_party_status_ledger())
	return previous_health - party_core_current


func get_max_health_penalty_for_peer(peer_id: int) -> int:
	ensure_run_started()
	if peer_id < 0:
		return 0
	if peer_id > 0:
		ensure_multiplayer_peer_state(peer_id)
	elif not max_health_penalties.has(0):
		max_health_penalties[0] = 0
	return maxi(int(max_health_penalties.get(peer_id, 0)), 0)


func set_max_health_penalty_for_peer(
	peer_id: int,
	amount: int,
	emit_change_signal: bool = true
) -> bool:
	ensure_run_started()
	if peer_id < 0 or amount < 0:
		return false
	if peer_id > 0:
		ensure_multiplayer_peer_state(peer_id)
	if int(max_health_penalties.get(peer_id, 0)) == amount:
		return true
	max_health_penalties[peer_id] = amount
	party_status_ledger_revision += 1
	if emit_change_signal:
		party_status_ledger_changed.emit(export_party_status_ledger())
	return true


func add_max_health_penalty_for_peer(
	peer_id: int,
	amount: int,
	emit_change_signal: bool = true
) -> int:
	if peer_id < 0 or amount < 0:
		return 0
	var previous_amount := get_max_health_penalty_for_peer(peer_id)
	if amount == 0:
		return previous_amount
	if not set_max_health_penalty_for_peer(
		peer_id,
		previous_amount + amount,
		emit_change_signal
	):
		return previous_amount
	return previous_amount + amount


func get_player_stat_bonuses(peer_id: int) -> Dictionary:
	ensure_run_started()
	if peer_id < 0:
		return _make_empty_player_stat_bonuses()
	if peer_id > 0 and not has_multiplayer_peer_state(peer_id):
		return _make_empty_player_stat_bonuses()
	if not player_stat_bonuses.has(peer_id):
		player_stat_bonuses[peer_id] = _make_empty_player_stat_bonuses()
	return _normalize_player_stat_bonuses(
		player_stat_bonuses[peer_id] as Dictionary
	)


func get_player_stat_bonus_value(peer_id: int, stat_id: StringName) -> int:
	if not PLAYER_STAT_BONUS_HARD_CAPS.has(stat_id):
		return 0
	return int(get_player_stat_bonuses(peer_id).get(str(stat_id), 0))


func get_player_stat_bonus_hard_cap(stat_id: StringName) -> int:
	return int(PLAYER_STAT_BONUS_HARD_CAPS.get(stat_id, -1))


## Builds a complete schema-valid party-status snapshot for the existing CAS.
## The caller must still pass the current status revision to
## apply_authoritative_party_transaction; this helper never mutates state.
func build_party_status_ledger_with_player_stat_bonus(
	peer_id: int,
	stat_id: StringName,
	delta: int
) -> Dictionary:
	ensure_run_started()
	if (
		peer_id < 0
		or delta <= 0
		or not PLAYER_STAT_BONUS_HARD_CAPS.has(stat_id)
		or (peer_id > 0 and not has_multiplayer_peer_state(peer_id))
	):
		return {}
	var current_bonuses := get_player_stat_bonuses(peer_id)
	var stat_key := str(stat_id)
	var previous_value := int(current_bonuses.get(stat_key, 0))
	var hard_cap := get_player_stat_bonus_hard_cap(stat_id)
	if hard_cap < 0 or previous_value > hard_cap - delta:
		return {}
	var next_snapshot := export_party_status_ledger()
	next_snapshot["revision"] = party_status_ledger_revision + 1
	var exported_bonuses := (
		next_snapshot["player_stat_bonuses"] as Dictionary
	)
	var peer_key := str(peer_id)
	var next_bonuses := (
		exported_bonuses.get(peer_key, _make_empty_player_stat_bonuses())
		as Dictionary
	).duplicate(true)
	next_bonuses[stat_key] = previous_value + delta
	exported_bonuses[peer_key] = next_bonuses
	return next_snapshot


func export_party_status_ledger() -> Dictionary:
	ensure_run_started()
	var exported_penalties: Dictionary = {}
	var exported_bonuses: Dictionary = {}
	var peer_ids: Array[int] = []
	for raw_peer_id in max_health_penalties.keys():
		var peer_id := int(raw_peer_id)
		if peer_id >= 0 and not peer_ids.has(peer_id):
			peer_ids.append(peer_id)
	for raw_peer_id in player_stat_bonuses.keys():
		var peer_id := int(raw_peer_id)
		if peer_id >= 0 and not peer_ids.has(peer_id):
			peer_ids.append(peer_id)
	if not peer_ids.has(0):
		peer_ids.append(0)
	peer_ids.sort()
	for peer_id in peer_ids:
		exported_penalties[str(peer_id)] = maxi(
			int(max_health_penalties.get(peer_id, 0)),
			0
		)
		exported_bonuses[str(peer_id)] = get_player_stat_bonuses(peer_id)
	return {
		"schema_version": PARTY_STATUS_LEDGER_SCHEMA_VERSION,
		"revision": party_status_ledger_revision,
		"core_current": party_core_current,
		"core_maximum": party_core_maximum,
		"max_health_penalties": exported_penalties,
		"player_stat_bonuses": exported_bonuses,
	}


func apply_party_status_ledger(
	snapshot: Dictionary,
	allow_revision_rewind: bool = false,
	emit_change_signal: bool = true
) -> bool:
	ensure_run_started()
	var decoded := _decode_party_status_ledger(
		snapshot,
		-1 if allow_revision_rewind else party_status_ledger_revision
	)
	if decoded.is_empty():
		return false
	var incoming_revision := int(decoded["revision"])
	var incoming_penalties := decoded["max_health_penalties"] as Dictionary
	var incoming_bonuses := decoded["player_stat_bonuses"] as Dictionary
	if (
		not allow_revision_rewind
		and incoming_revision == party_status_ledger_revision
		and (
			int(decoded["core_current"]) != party_core_current
			or int(decoded["core_maximum"]) != party_core_maximum
			or incoming_penalties != max_health_penalties
			or incoming_bonuses != player_stat_bonuses
		)
	):
		return false
	var changed := (
		incoming_revision != party_status_ledger_revision
		or int(decoded["core_current"]) != party_core_current
		or int(decoded["core_maximum"]) != party_core_maximum
		or incoming_penalties != max_health_penalties
		or incoming_bonuses != player_stat_bonuses
	)
	party_core_current = int(decoded["core_current"])
	party_core_maximum = int(decoded["core_maximum"])
	max_health_penalties = incoming_penalties.duplicate(true)
	player_stat_bonuses = incoming_bonuses.duplicate(true)
	party_status_ledger_revision = incoming_revision
	if changed and emit_change_signal:
		party_status_ledger_changed.emit(export_party_status_ledger())
	return true


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
		"xirang_ledger": export_party_xirang_ledger(),
		"light_stone_ledger": export_party_light_stone_ledger(),
		"party_status_ledger": export_party_status_ledger(),
		"rogue_encounter_history_ledger": (
			export_rogue_encounter_history_ledger()
		),
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
		{},
		-1,
		-1,
		-1
	)
	return _commit_prepared_party_economy_snapshot(prepared)


## 只读校验一份完整经济快照。复用正式应用路径的全部字段解码与
## 当前 revision 基线，但不进入 commit，也不会创建 Run、改写账本或发信号。
func validate_party_economy_snapshot(
	snapshot: Dictionary,
	allow_revision_rewind: bool = false
) -> bool:
	if not run_started:
		return false
	return not _prepare_party_economy_snapshot(
		snapshot,
		allow_revision_rewind,
		false,
		-1,
		{},
		-1,
		-1,
		-1
	).is_empty()


## 遭遇等房主事务使用的单步 CAS。next snapshot 中每个发生变化的 store
## 必须只前进一个 revision；全部基准 revision 在首个写入前统一复核。
func apply_authoritative_party_transaction(
	next_snapshot: Dictionary,
	expected_warehouse_ledger_revision: int,
	expected_inventory_revisions: Dictionary,
	expected_xirang_ledger_revision: int = -1,
	next_xirang_ledger: Dictionary = {},
	expected_status_ledger_revision: int = -1,
	next_status_ledger: Dictionary = {},
	expected_light_stone_ledger_revision: int = -1,
	next_light_stone_ledger: Dictionary = {}
) -> bool:
	var resolved_snapshot := next_snapshot
	if (
		not next_xirang_ledger.is_empty()
		or not next_status_ledger.is_empty()
		or not next_light_stone_ledger.is_empty()
	):
		resolved_snapshot = next_snapshot.duplicate(true)
	if not next_xirang_ledger.is_empty():
		resolved_snapshot["xirang_ledger"] = next_xirang_ledger.duplicate(true)
	if not next_status_ledger.is_empty():
		resolved_snapshot["party_status_ledger"] = next_status_ledger.duplicate(true)
	if not next_light_stone_ledger.is_empty():
		resolved_snapshot["light_stone_ledger"] = (
			next_light_stone_ledger.duplicate(true)
		)
	var prepared := _prepare_party_economy_snapshot(
		resolved_snapshot,
		false,
		true,
		expected_warehouse_ledger_revision,
		expected_inventory_revisions,
		expected_xirang_ledger_revision,
		expected_status_ledger_revision,
		expected_light_stone_ledger_revision
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


func _decode_party_xirang_ledger(
	snapshot: Dictionary,
	minimum_revision: int
) -> Dictionary:
	if (
		typeof(snapshot.get("schema_version")) != TYPE_INT
		or int(snapshot["schema_version"])
		!= PARTY_XIRANG_LEDGER_SCHEMA_VERSION
		or typeof(snapshot.get("revision")) != TYPE_INT
		or typeof(snapshot.get("values")) != TYPE_DICTIONARY
	):
		return {}
	var incoming_revision := int(snapshot["revision"])
	if incoming_revision < 0 or incoming_revision < minimum_revision:
		return {}
	var decoded_values: Dictionary = {}
	for raw_peer_id in (snapshot["values"] as Dictionary).keys():
		if (
			typeof(raw_peer_id) != TYPE_INT
			and (
				typeof(raw_peer_id) != TYPE_STRING
				or not str(raw_peer_id).is_valid_int()
			)
		):
			return {}
		var peer_id := int(raw_peer_id)
		var amount_value: Variant = (snapshot["values"] as Dictionary)[raw_peer_id]
		if (
			peer_id < 0
			or decoded_values.has(peer_id)
			or typeof(amount_value) != TYPE_INT
			or int(amount_value) < 0
		):
			return {}
		decoded_values[peer_id] = int(amount_value)
	return {
		"revision": incoming_revision,
		"values": decoded_values,
	}


func _decode_party_light_stone_ledger(
	snapshot: Dictionary,
	minimum_revision: int
) -> Dictionary:
	if (
		typeof(snapshot.get("schema_version")) != TYPE_INT
		or int(snapshot["schema_version"])
		!= PARTY_LIGHT_STONE_LEDGER_SCHEMA_VERSION
		or typeof(snapshot.get("revision")) != TYPE_INT
		or typeof(snapshot.get("amount")) != TYPE_INT
	):
		return {}
	var incoming_revision := int(snapshot["revision"])
	var incoming_amount := int(snapshot["amount"])
	if (
		incoming_revision < 0
		or incoming_revision < minimum_revision
		or incoming_amount < 0
	):
		return {}
	return {
		"revision": incoming_revision,
		"amount": incoming_amount,
	}


func _decode_party_status_ledger(
	snapshot: Dictionary,
	minimum_revision: int
) -> Dictionary:
	if (
		typeof(snapshot.get("schema_version")) != TYPE_INT
		or int(snapshot["schema_version"])
		!= PARTY_STATUS_LEDGER_SCHEMA_VERSION
		or typeof(snapshot.get("revision")) != TYPE_INT
		or typeof(snapshot.get("core_current")) != TYPE_INT
		or typeof(snapshot.get("core_maximum")) != TYPE_INT
		or typeof(snapshot.get("max_health_penalties")) != TYPE_DICTIONARY
		or typeof(snapshot.get("player_stat_bonuses")) != TYPE_DICTIONARY
	):
		return {}
	var incoming_revision := int(snapshot["revision"])
	var core_current := int(snapshot["core_current"])
	var core_maximum := int(snapshot["core_maximum"])
	if (
		incoming_revision < 0
		or incoming_revision < minimum_revision
		or core_maximum <= 0
		or core_current < 0
		or core_current > core_maximum
	):
		return {}
	var decoded_penalties: Dictionary = {}
	for raw_peer_id in (snapshot["max_health_penalties"] as Dictionary).keys():
		if (
			typeof(raw_peer_id) != TYPE_INT
			and (
				typeof(raw_peer_id) != TYPE_STRING
				or not str(raw_peer_id).is_valid_int()
			)
		):
			return {}
		var peer_id := int(raw_peer_id)
		var penalty_value: Variant = (
			snapshot["max_health_penalties"] as Dictionary
		)[raw_peer_id]
		if (
			peer_id < 0
			or decoded_penalties.has(peer_id)
			or typeof(penalty_value) != TYPE_INT
			or int(penalty_value) < 0
		):
			return {}
		decoded_penalties[peer_id] = int(penalty_value)
	if not decoded_penalties.has(0):
		decoded_penalties[0] = 0
	var decoded_bonuses: Dictionary = {}
	for raw_peer_id in (snapshot["player_stat_bonuses"] as Dictionary).keys():
		if (
			typeof(raw_peer_id) != TYPE_INT
			and (
				typeof(raw_peer_id) != TYPE_STRING
				or not str(raw_peer_id).is_valid_int()
			)
		):
			return {}
		var peer_id := int(raw_peer_id)
		var raw_bonuses: Variant = (
			snapshot["player_stat_bonuses"] as Dictionary
		)[raw_peer_id]
		if (
			peer_id < 0
			or decoded_bonuses.has(peer_id)
			or typeof(raw_bonuses) != TYPE_DICTIONARY
		):
			return {}
		var decoded_entry := _decode_player_stat_bonuses(
			raw_bonuses as Dictionary
		)
		if decoded_entry.is_empty():
			return {}
		decoded_bonuses[peer_id] = decoded_entry
	if not decoded_bonuses.has(0):
		return {}
	if decoded_bonuses.keys().size() != decoded_penalties.keys().size():
		return {}
	for raw_peer_id in decoded_penalties.keys():
		if not decoded_bonuses.has(int(raw_peer_id)):
			return {}
	return {
		"revision": incoming_revision,
		"core_current": core_current,
		"core_maximum": core_maximum,
		"max_health_penalties": decoded_penalties,
		"player_stat_bonuses": decoded_bonuses,
	}


func _make_empty_player_stat_bonuses() -> Dictionary:
	var result: Dictionary = {}
	for stat_id in PLAYER_STAT_BONUS_KEYS:
		result[str(stat_id)] = 0
	return result


func _normalize_player_stat_bonuses(source: Dictionary) -> Dictionary:
	var result := _make_empty_player_stat_bonuses()
	for stat_id in PLAYER_STAT_BONUS_KEYS:
		var stat_key := str(stat_id)
		result[stat_key] = clampi(
			int(source.get(stat_key, source.get(stat_id, 0))),
			0,
			get_player_stat_bonus_hard_cap(stat_id)
		)
	return result


func _decode_player_stat_bonuses(source: Dictionary) -> Dictionary:
	if source.size() != PLAYER_STAT_BONUS_KEYS.size():
		return {}
	var decoded: Dictionary = {}
	for stat_id in PLAYER_STAT_BONUS_KEYS:
		var stat_key := str(stat_id)
		if not source.has(stat_key):
			return {}
		var raw_value: Variant = source[stat_key]
		if typeof(raw_value) != TYPE_INT:
			return {}
		var value := int(raw_value)
		if value < 0 or value > get_player_stat_bonus_hard_cap(stat_id):
			return {}
		decoded[stat_key] = value
	return decoded


func _decode_rogue_encounter_history_ledger(
	ledger: Dictionary,
	minimum_revision: int
) -> Dictionary:
	if (
		typeof(ledger.get("schema_version")) != TYPE_INT
		or int(ledger["schema_version"])
		!= ROGUE_ENCOUNTER_HISTORY_LEDGER_SCHEMA_VERSION
		or typeof(ledger.get("revision")) != TYPE_INT
		or int(ledger["revision"]) < maxi(minimum_revision, 0)
		or typeof(ledger.get("encounter_ids")) != TYPE_ARRAY
	):
		return {}
	var decoded_ids: Dictionary = {}
	var magical_pool := RogueEncounterRegistry.get_pool_entries(
		RogueEncounterRegistry.MAGICAL_ENCOUNTER_POOL
	)
	for raw_id in ledger["encounter_ids"]:
		if typeof(raw_id) != TYPE_STRING:
			return {}
		var encounter_id := StringName(raw_id)
		if (
			encounter_id.is_empty()
			or decoded_ids.has(encounter_id)
			or not RogueEncounterRegistry.has_encounter(encounter_id)
			or not magical_pool.has(encounter_id)
		):
			return {}
		decoded_ids[encounter_id] = true
	var canonical_ids: Array[String] = []
	for encounter_id in magical_pool:
		if decoded_ids.has(encounter_id):
			canonical_ids.append(String(encounter_id))
	var raw_ids: Array = Array(ledger["encounter_ids"])
	if (
		canonical_ids != raw_ids
		or int(ledger["revision"]) != decoded_ids.size()
	):
		return {}
	return {
		"revision": int(ledger["revision"]),
		"encounter_ids": decoded_ids,
	}


func _prepare_party_economy_snapshot(
	snapshot: Dictionary,
	allow_revision_rewind: bool,
	require_single_revision_step: bool,
	expected_warehouse_revision: int,
	expected_inventory_revisions: Dictionary,
	expected_xirang_revision: int,
	expected_status_revision: int,
	expected_light_stone_revision: int
) -> Dictionary:
	ensure_run_started()
	if (
		typeof(snapshot.get("schema_version")) != TYPE_INT
		or int(snapshot["schema_version"]) != PARTY_ECONOMY_SCHEMA_VERSION
		or typeof(snapshot.get("warehouse_ledger")) != TYPE_DICTIONARY
		or typeof(snapshot.get("inventories")) != TYPE_ARRAY
		or typeof(snapshot.get("xirang_ledger")) != TYPE_DICTIONARY
		or typeof(snapshot.get("light_stone_ledger")) != TYPE_DICTIONARY
		or typeof(snapshot.get("party_status_ledger")) != TYPE_DICTIONARY
		or typeof(snapshot.get("rogue_encounter_history_ledger"))
		!= TYPE_DICTIONARY
	):
		return {}
	if (
		require_single_revision_step
		and expected_warehouse_revision != shared_warehouse_ledger_revision
	):
		return {}
	if (
		require_single_revision_step
		and expected_xirang_revision >= 0
		and expected_xirang_revision != party_xirang_ledger_revision
	):
		return {}
	if (
		require_single_revision_step
		and expected_status_revision >= 0
		and expected_status_revision != party_status_ledger_revision
	):
		return {}
	if (
		require_single_revision_step
		and expected_light_stone_revision >= 0
		and expected_light_stone_revision != party_light_stone_ledger_revision
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
	var decoded_xirang_ledger := _decode_party_xirang_ledger(
		snapshot["xirang_ledger"] as Dictionary,
		-1 if allow_revision_rewind else party_xirang_ledger_revision
	)
	if decoded_xirang_ledger.is_empty():
		return {}
	var incoming_xirang_revision := int(decoded_xirang_ledger["revision"])
	if (
		require_single_revision_step
		and incoming_xirang_revision != party_xirang_ledger_revision
		and incoming_xirang_revision != party_xirang_ledger_revision + 1
	):
		return {}
	if (
		not allow_revision_rewind
		and incoming_xirang_revision == party_xirang_ledger_revision
		and decoded_xirang_ledger["values"] != party_xirang_balances
	):
		return {}
	var decoded_light_stone_ledger := _decode_party_light_stone_ledger(
		snapshot["light_stone_ledger"] as Dictionary,
		-1 if allow_revision_rewind else party_light_stone_ledger_revision
	)
	if decoded_light_stone_ledger.is_empty():
		return {}
	var incoming_light_stone_revision := int(
		decoded_light_stone_ledger["revision"]
	)
	if (
		require_single_revision_step
		and incoming_light_stone_revision != party_light_stone_ledger_revision
		and incoming_light_stone_revision != party_light_stone_ledger_revision + 1
	):
		return {}
	if (
		not allow_revision_rewind
		and incoming_light_stone_revision == party_light_stone_ledger_revision
		and int(decoded_light_stone_ledger["amount"])
		!= party_light_stone_amount
	):
		return {}
	var decoded_status_ledger := _decode_party_status_ledger(
		snapshot["party_status_ledger"] as Dictionary,
		-1 if allow_revision_rewind else party_status_ledger_revision
	)
	if decoded_status_ledger.is_empty():
		return {}
	var incoming_status_revision := int(decoded_status_ledger["revision"])
	if (
		require_single_revision_step
		and incoming_status_revision != party_status_ledger_revision
		and incoming_status_revision != party_status_ledger_revision + 1
	):
		return {}
	var decoded_encounter_history := _decode_rogue_encounter_history_ledger(
		snapshot["rogue_encounter_history_ledger"] as Dictionary,
		-1 if allow_revision_rewind else rogue_encounter_history_revision
	)
	if decoded_encounter_history.is_empty():
		return {}
	var incoming_encounter_history_revision := int(
		decoded_encounter_history["revision"]
	)
	if (
		require_single_revision_step
		and incoming_encounter_history_revision
		!= rogue_encounter_history_revision
	):
		return {}
	if (
		not allow_revision_rewind
		and incoming_encounter_history_revision
		== rogue_encounter_history_revision
		and decoded_encounter_history["encounter_ids"]
		!= rogue_encounter_ids
	):
		return {}
	if (
		not allow_revision_rewind
		and incoming_status_revision == party_status_ledger_revision
		and (
			int(decoded_status_ledger["core_current"]) != party_core_current
			or int(decoded_status_ledger["core_maximum"]) != party_core_maximum
			or decoded_status_ledger["max_health_penalties"]
			!= max_health_penalties
			or decoded_status_ledger["player_stat_bonuses"]
			!= player_stat_bonuses
		)
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
		if not (
			decoded_status_ledger["max_health_penalties"] as Dictionary
		).has(peer_id):
			return {}
		if not (
			decoded_status_ledger["player_stat_bonuses"] as Dictionary
		).has(peer_id):
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
		"expected_xirang_revision": party_xirang_ledger_revision,
		"expected_status_revision": party_status_ledger_revision,
		"expected_light_stone_revision": party_light_stone_ledger_revision,
		"expected_encounter_history_revision": (
			rogue_encounter_history_revision
		),
		"warehouse_ledger": decoded_ledger,
		"xirang_ledger": decoded_xirang_ledger,
		"light_stone_ledger": decoded_light_stone_ledger,
		"party_status_ledger": decoded_status_ledger,
		"rogue_encounter_history_ledger": decoded_encounter_history,
		"inventories": prepared_inventories,
	}


func _commit_prepared_party_economy_snapshot(prepared: Dictionary) -> bool:
	if (
		prepared.is_empty()
		or int(prepared.get("expected_warehouse_revision", -1))
		!= shared_warehouse_ledger_revision
		or int(prepared.get("expected_xirang_revision", -1))
		!= party_xirang_ledger_revision
		or int(prepared.get("expected_status_revision", -1))
		!= party_status_ledger_revision
		or int(prepared.get("expected_light_stone_revision", -1))
		!= party_light_stone_ledger_revision
		or int(prepared.get("expected_encounter_history_revision", -1))
		!= rogue_encounter_history_revision
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
	var prepared_xirang_ledger := prepared["xirang_ledger"] as Dictionary
	var xirang_changed: bool = (
		int(prepared_xirang_ledger["revision"]) != party_xirang_ledger_revision
		or prepared_xirang_ledger["values"] != party_xirang_balances
	)
	party_xirang_balances = (
		prepared_xirang_ledger["values"] as Dictionary
	).duplicate(true)
	party_xirang_ledger_revision = int(prepared_xirang_ledger["revision"])
	var prepared_light_stone_ledger := (
		prepared["light_stone_ledger"] as Dictionary
	)
	var light_stone_changed: bool = (
		int(prepared_light_stone_ledger["revision"])
		!= party_light_stone_ledger_revision
		or int(prepared_light_stone_ledger["amount"])
		!= party_light_stone_amount
	)
	party_light_stone_amount = int(prepared_light_stone_ledger["amount"])
	party_light_stone_ledger_revision = int(
		prepared_light_stone_ledger["revision"]
	)
	var prepared_status_ledger := prepared["party_status_ledger"] as Dictionary
	var status_changed: bool = (
		int(prepared_status_ledger["revision"]) != party_status_ledger_revision
		or int(prepared_status_ledger["core_current"]) != party_core_current
		or int(prepared_status_ledger["core_maximum"]) != party_core_maximum
		or prepared_status_ledger["max_health_penalties"]
		!= max_health_penalties
		or prepared_status_ledger["player_stat_bonuses"]
		!= player_stat_bonuses
	)
	party_core_current = int(prepared_status_ledger["core_current"])
	party_core_maximum = int(prepared_status_ledger["core_maximum"])
	max_health_penalties = (
		prepared_status_ledger["max_health_penalties"] as Dictionary
	).duplicate(true)
	player_stat_bonuses = (
		prepared_status_ledger["player_stat_bonuses"] as Dictionary
	).duplicate(true)
	party_status_ledger_revision = int(prepared_status_ledger["revision"])
	var prepared_encounter_history := (
		prepared["rogue_encounter_history_ledger"] as Dictionary
	)
	var encounter_history_changed: bool = (
		int(prepared_encounter_history["revision"])
		!= rogue_encounter_history_revision
		or prepared_encounter_history["encounter_ids"]
		!= rogue_encounter_ids
	)
	rogue_encounter_ids = (
		prepared_encounter_history["encounter_ids"] as Dictionary
	).duplicate(true)
	rogue_encounter_history_revision = int(
		prepared_encounter_history["revision"]
	)

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
	if xirang_changed:
		party_xirang_ledger_changed.emit(export_party_xirang_ledger())
	if light_stone_changed:
		party_light_stone_ledger_changed.emit(export_party_light_stone_ledger())
	if status_changed:
		party_status_ledger_changed.emit(export_party_status_ledger())
	if encounter_history_changed:
		rogue_encounter_history_changed.emit(
			export_rogue_encounter_history_ledger()
		)
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


func _resolve_quick_use_owner_peer_id(owner_peer_id: int) -> int:
	return active_multiplayer_peer_id if owner_peer_id < 0 else maxi(owner_peer_id, 0)


func _get_quick_use_item_at_slot(
	owner_peer_id: int,
	slot_index: int
) -> PickupConfig:
	if slot_index < 0 or slot_index >= INVENTORY_CAPACITY:
		return null
	if owner_peer_id == 0:
		_ensure_local_inventory_shape()
		return inventory[slot_index] as PickupConfig
	if not has_multiplayer_peer_state(owner_peer_id):
		return null
	var peer_inventory := multiplayer_inventories[owner_peer_id] as Array
	return peer_inventory[slot_index] as PickupConfig


func _quick_use_slot_matches_path(
	owner_peer_id: int,
	slot_index: int,
	config_path: String
) -> bool:
	var item := _get_quick_use_item_at_slot(owner_peer_id, slot_index)
	return (
		item != null
		and not item.inventory_locked
		and item.is_consumable_item()
		and item.resource_path == config_path
	)


func _clear_all_quick_use_bindings() -> void:
	if _quick_use_bindings_by_owner.is_empty():
		return
	var owner_peer_ids := _quick_use_bindings_by_owner.keys()
	_quick_use_bindings_by_owner.clear()
	for owner_peer_id_variant in owner_peer_ids:
		quick_use_binding_changed.emit(int(owner_peer_id_variant), "", -1)


func _remap_quick_use_binding(
	old_peer_id: int,
	new_peer_id: int,
	keep_target_inventory: bool
) -> void:
	var old_binding_exists := _quick_use_bindings_by_owner.has(old_peer_id)
	var target_binding_exists := _quick_use_bindings_by_owner.has(new_peer_id)
	if not old_binding_exists and not target_binding_exists:
		return
	if keep_target_inventory:
		# The target's newer authoritative inventory snapshot does not carry this
		# client-local preference. Preserve an already-remapped target binding, or
		# migrate the old peer's binding when the target has none.
		if old_binding_exists and not target_binding_exists:
			_quick_use_bindings_by_owner[new_peer_id] = (
				_quick_use_bindings_by_owner[old_peer_id] as Dictionary
			).duplicate(true)
	else:
		if old_binding_exists:
			_quick_use_bindings_by_owner[new_peer_id] = (
				_quick_use_bindings_by_owner[old_peer_id] as Dictionary
			).duplicate(true)
		else:
			_quick_use_bindings_by_owner.erase(new_peer_id)
	_quick_use_bindings_by_owner.erase(old_peer_id)
	if old_binding_exists:
		quick_use_binding_changed.emit(old_peer_id, "", -1)
	if old_binding_exists or target_binding_exists:
		quick_use_binding_changed.emit(
			new_peer_id,
			get_quick_use_bound_config_path(new_peer_id),
			get_quick_use_slot_index(new_peer_id)
		)


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
		player.set_xirang_balance(player.current_xirang - upgrade_cost)
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
