extends Node
class_name ProductionCoordinator

signal storage_totals_changed
signal personal_inventory_output_committed(peer_id: int)

const TICK_INTERVAL_SECONDS := 1.0
const RESULT_SUCCESS := &"success"
const RESULT_MISSING_INPUT := &"missing_input"
const RESULT_STORAGE_FULL := &"storage_full"
const RESULT_UNAVAILABLE := &"unavailable"
const RESULT_OUTPUT_PEER_UNAVAILABLE := &"output_peer_unavailable"
const RESULT_OUTPUT_SLOT_OCCUPIED := &"output_slot_occupied"


## Sparse overlay for one warehouse. The first write to a slot captures both
## its original value (for rollback) and its final simulated value. Subsequent
## recipe inputs/outputs update the same entry in O(1).
class WarehouseSlotJournal:
	extends RefCounted

	var warehouse: OakWarehouse
	var expected_revision := 0
	var change_index_by_slot := PackedInt32Array()
	var slot_indices := PackedInt32Array()
	var original_items: Array[PickupConfig] = []
	var original_counts := PackedInt32Array()
	var final_items: Array[PickupConfig] = []
	var final_counts := PackedInt32Array()

	func _init(target: OakWarehouse) -> void:
		warehouse = target
		expected_revision = target.get_storage_revision()
		change_index_by_slot.resize(OakWarehouse.STORAGE_CAPACITY)
		change_index_by_slot.fill(-1)

	func write_slot(
		slot_index: int,
		item: PickupConfig,
		count: int
	) -> void:
		var change_index := int(change_index_by_slot[slot_index])
		if change_index < 0:
			change_index = slot_indices.size()
			change_index_by_slot[slot_index] = change_index
			slot_indices.append(slot_index)
			original_items.append(warehouse.get_storage_item(slot_index))
			original_counts.append(warehouse.get_storage_item_count(slot_index))
			final_items.append(item)
			final_counts.append(count)
			return
		final_items[change_index] = item
		final_counts[change_index] = count


## One transaction owns only a warehouse-sized reference table. Per-slot arrays
## are allocated lazily for stores the recipe actually touches; failed preflight
## against empty or full storage therefore creates no per-warehouse snapshots.
class StorageTransactionJournal:
	extends RefCounted

	var ordered_warehouses: Array[OakWarehouse]
	var warehouse_journals: Array[WarehouseSlotJournal] = []

	func _init(warehouses: Array[OakWarehouse]) -> void:
		ordered_warehouses = warehouses
		warehouse_journals.resize(warehouses.size())

	func write_slot(
		warehouse_index: int,
		slot_index: int,
		item: PickupConfig,
		count: int
	) -> void:
		var journal := warehouse_journals[warehouse_index]
		if journal == null:
			journal = WarehouseSlotJournal.new(ordered_warehouses[warehouse_index])
			warehouse_journals[warehouse_index] = journal
		journal.write_slot(slot_index, item, count)


@onready var production_tick_timer: Timer = $ProductionTickTimer
@onready var run_state: RunStateStore = get_node_or_null(
	"/root/RunState"
) as RunStateStore

var authoritative_processing_enabled := true
var production_buildings: Array[ProductionBuilding] = []
var warehouses: Array[OakWarehouse] = []
var _storage_transaction_in_progress := false
var _warehouse_state_changed_during_transaction := false
var _inventory_state_changed_during_transaction := false
var _multiplayer_output_validation_enabled := false
var _active_personal_output_peers: Dictionary[int, bool] = {}
var _warehouse_waiting_buildings: Array[ProductionBuilding] = []
var _warehouse_waiting_indices: Dictionary[int, int] = {}
var _inventory_waiting_buildings: Array[ProductionBuilding] = []
var _inventory_waiting_indices: Dictionary[int, int] = {}
var _inventory_waiting_revisions: Dictionary[int, int] = {}
var _ordered_operational_warehouses: Array[OakWarehouse] = []
var _ordered_visible_warehouses: Array[OakWarehouse] = []
var _ordered_warehouse_cache_dirty := true
var _operational_storage_item_totals: Dictionary = {}
var _visible_storage_item_totals: Dictionary = {}
var _operational_storage_stack_capacity: Dictionary = {}
var _operational_empty_storage_slot_count := 0
var _storage_item_totals_cache_dirty := true


func _ready() -> void:
	production_tick_timer.timeout.connect(_on_production_tick)
	if (
		run_state != null
		and not run_state.inventory_changed.is_connected(_on_inventory_changed)
	):
		run_state.inventory_changed.connect(_on_inventory_changed)
	_refresh_timer_state()


func set_authoritative_processing_enabled(enabled: bool) -> void:
	var was_enabled := authoritative_processing_enabled
	authoritative_processing_enabled = enabled
	_refresh_timer_state()
	if enabled and not was_enabled and is_node_ready():
		_retry_waiting_buildings(true, true, true)


func configure_multiplayer_output_peers(peer_ids: Array) -> void:
	_multiplayer_output_validation_enabled = true
	_active_personal_output_peers.clear()
	for peer_id_variant in peer_ids:
		var peer_id := int(peer_id_variant)
		if peer_id > 0:
			_active_personal_output_peers[peer_id] = true


func configure_local_output_peer() -> void:
	_multiplayer_output_validation_enabled = false
	_active_personal_output_peers.clear()


func is_personal_output_peer_available(peer_id: int) -> bool:
	if not _multiplayer_output_validation_enabled:
		return peer_id == 0
	return peer_id > 0 and _active_personal_output_peers.has(peer_id)


func activate_personal_output_peer(peer_id: int) -> bool:
	if not _multiplayer_output_validation_enabled or peer_id <= 0:
		return false
	_active_personal_output_peers[peer_id] = true
	return true


func deactivate_personal_output_peer(peer_id: int) -> void:
	if peer_id <= 0 or not _active_personal_output_peers.has(peer_id):
		return
	_active_personal_output_peers.erase(peer_id)
	# Every endpoint receives the existing player_left lifecycle event and applies
	# this deterministic state transition locally. No production RPC is needed.
	for index in range(production_buildings.size() - 1, -1, -1):
		var building := production_buildings[index]
		if building == null or not is_instance_valid(building):
			production_buildings.remove_at(index)
			continue
		building.release_personal_output_peer(peer_id)


func get_seconds_until_next_tick() -> float:
	if (
		not is_node_ready()
		or production_tick_timer == null
		or production_tick_timer.is_stopped()
		or production_tick_timer.time_left <= 0.001
	):
		return TICK_INTERVAL_SECONDS
	return clampf(
		production_tick_timer.time_left,
		0.001,
		TICK_INTERVAL_SECONDS
	)


func register_plant(plant: PlantDefense) -> void:
	var production_building := plant as ProductionBuilding
	if production_building != null:
		if not production_buildings.has(production_building):
			production_buildings.append(production_building)
		production_building.set_production_coordinator(self)

	var warehouse := plant as OakWarehouse
	if warehouse == null or warehouses.has(warehouse):
		return
	warehouses.append(warehouse)
	_invalidate_ordered_warehouse_cache()
	if not warehouse.storage_changed.is_connected(_on_warehouse_storage_changed):
		warehouse.storage_changed.connect(_on_warehouse_storage_changed)
	var removal_callback := _on_warehouse_removal_started.bind(warehouse)
	if not warehouse.removal_started.is_connected(removal_callback):
		warehouse.removal_started.connect(removal_callback, CONNECT_ONE_SHOT)
	var tree_exiting_callback := _on_warehouse_tree_exiting.bind(warehouse)
	if not warehouse.tree_exiting.is_connected(tree_exiting_callback):
		warehouse.tree_exiting.connect(tree_exiting_callback, CONNECT_ONE_SHOT)
	if not warehouse.is_operational:
		var construction_callback := _on_warehouse_construction_finished.bind(
			warehouse
		)
		if not warehouse.construction_finished.is_connected(construction_callback):
			warehouse.construction_finished.connect(
				construction_callback,
				CONNECT_ONE_SHOT
			)
	_on_warehouse_storage_changed()


func unregister_plant(plant: PlantDefense) -> void:
	var production_building := plant as ProductionBuilding
	if production_building != null:
		production_buildings.erase(production_building)
		production_building.set_production_coordinator(null)

	var warehouse := plant as OakWarehouse
	if warehouse == null:
		return
	warehouses.erase(warehouse)
	_invalidate_ordered_warehouse_cache()
	if warehouse.storage_changed.is_connected(_on_warehouse_storage_changed):
		warehouse.storage_changed.disconnect(_on_warehouse_storage_changed)
	var construction_callback := _on_warehouse_construction_finished.bind(warehouse)
	if warehouse.construction_finished.is_connected(construction_callback):
		warehouse.construction_finished.disconnect(construction_callback)
	var removal_callback := _on_warehouse_removal_started.bind(warehouse)
	if warehouse.removal_started.is_connected(removal_callback):
		warehouse.removal_started.disconnect(removal_callback)
	var tree_exiting_callback := _on_warehouse_tree_exiting.bind(warehouse)
	if warehouse.tree_exiting.is_connected(tree_exiting_callback):
		warehouse.tree_exiting.disconnect(tree_exiting_callback)
	_on_warehouse_storage_changed()


## Parks a completed cycle behind the exact external state that can unblock it.
## Registration and cancellation are O(1); retries only traverse the relevant
## parked cohort when that state actually changes.
func update_ready_production_wait(
	building: ProductionBuilding,
	wait_reason: StringName
) -> void:
	if building == null or not is_instance_valid(building):
		return
	var instance_id := building.get_instance_id()
	if wait_reason == RESULT_MISSING_INPUT:
		_remove_waiting_building(
			instance_id,
			_inventory_waiting_buildings,
			_inventory_waiting_indices
		)
		_inventory_waiting_revisions.erase(instance_id)
		_add_waiting_building(
			building,
			_warehouse_waiting_buildings,
			_warehouse_waiting_indices
		)
		return
	if wait_reason != RESULT_STORAGE_FULL:
		clear_ready_production_wait(building)
		return
	var recipe := building.get_active_recipe()
	if recipe != null and recipe.outputs_to_player_inventory():
		_remove_waiting_building(
			instance_id,
			_warehouse_waiting_buildings,
			_warehouse_waiting_indices
		)
		_add_waiting_building(
			building,
			_inventory_waiting_buildings,
			_inventory_waiting_indices
		)
		_inventory_waiting_revisions[instance_id] = (
			_get_output_inventory_revision(building)
		)
		return
	_remove_waiting_building(
		instance_id,
		_inventory_waiting_buildings,
		_inventory_waiting_indices
	)
	_inventory_waiting_revisions.erase(instance_id)
	_add_waiting_building(
		building,
		_warehouse_waiting_buildings,
		_warehouse_waiting_indices
	)


func clear_ready_production_wait(building: ProductionBuilding) -> void:
	if building == null or not is_instance_valid(building):
		return
	var instance_id := building.get_instance_id()
	_remove_waiting_building(
		instance_id,
		_warehouse_waiting_buildings,
		_warehouse_waiting_indices
	)
	_remove_waiting_building(
		instance_id,
		_inventory_waiting_buildings,
		_inventory_waiting_indices
	)
	_inventory_waiting_revisions.erase(instance_id)


func get_total_item_count(item: PickupConfig) -> int:
	if item == null:
		return 0
	_ensure_storage_item_totals_cache()
	return int(_visible_storage_item_totals.get(_get_storage_item_key(item), 0))


func try_consume_item_requirements(requirements: Array[Dictionary]) -> StringName:
	if not authoritative_processing_enabled or requirements.is_empty():
		return RESULT_UNAVAILABLE
	var ordered_warehouses := _get_ordered_operational_warehouses()
	if ordered_warehouses.is_empty():
		return RESULT_MISSING_INPUT
	for requirement in requirements:
		var item := requirement.get("item") as PickupConfig
		var count := int(requirement.get("count", 0))
		if item == null or count <= 0:
			return RESULT_UNAVAILABLE
	if not _has_operational_requirement_counts(requirements):
		return RESULT_MISSING_INPUT
	var journal := StorageTransactionJournal.new(ordered_warehouses)
	for requirement in requirements:
		var item := requirement.get("item") as PickupConfig
		var count := int(requirement.get("count", 0))
		if not _simulate_journal_consume_item_count(journal, item, count):
			return RESULT_MISSING_INPUT
	if not _validate_storage_journal(journal):
		return RESULT_UNAVAILABLE
	var previous_transaction_state := _storage_transaction_in_progress
	_storage_transaction_in_progress = true
	if not _apply_storage_journal(journal):
		_storage_transaction_in_progress = previous_transaction_state
		return RESULT_UNAVAILABLE
	_publish_storage_journal_changes(journal)
	_finish_storage_transaction(previous_transaction_state)
	return RESULT_SUCCESS


func try_commit_recipe(
	recipe: ProductionRecipe,
	output_peer_id: int = 0
) -> StringName:
	if (
		not authoritative_processing_enabled
		or recipe == null
		or not recipe.is_valid()
		or recipe.inputs_from_player_inventory()
	):
		return RESULT_UNAVAILABLE
	var outputs_to_inventory := recipe.outputs_to_player_inventory()
	if outputs_to_inventory and not is_personal_output_peer_available(output_peer_id):
		return RESULT_OUTPUT_PEER_UNAVAILABLE
	var ordered_warehouses := _get_ordered_operational_warehouses()
	if ordered_warehouses.is_empty():
		return RESULT_MISSING_INPUT
	if not _has_operational_recipe_inputs(recipe):
		return RESULT_MISSING_INPUT
	if (
		not outputs_to_inventory
		and recipe.uses_environment_source()
		and not _has_cached_output_capacity_without_consumption(recipe)
	):
		return RESULT_STORAGE_FULL

	var journal := StorageTransactionJournal.new(ordered_warehouses)

	for input_index in recipe.input_items.size():
		var input_amount := recipe.input_amounts[input_index]
		if input_amount == 0:
			continue
		if not _simulate_journal_consume_item_count(
			journal,
			recipe.input_items[input_index],
			input_amount
		):
			return RESULT_MISSING_INPUT

	var inventory_revision := -1
	if outputs_to_inventory:
		if run_state == null or output_peer_id < 0:
			return RESULT_UNAVAILABLE
		inventory_revision = (
			run_state.get_inventory_revision_for_peer(output_peer_id)
			if output_peer_id > 0
			else run_state.get_inventory_revision()
		)
		var inventory_has_capacity := (
			run_state.can_add_item_counts_for_peer(
				output_peer_id,
				recipe.output_items,
				recipe.output_amounts
			)
			if output_peer_id > 0
			else run_state.can_add_item_counts(
				recipe.output_items,
				recipe.output_amounts
			)
		)
		if not inventory_has_capacity:
			return RESULT_STORAGE_FULL
	else:
		for output_index in recipe.output_items.size():
			if not _simulate_journal_add_item_count(
				journal,
				recipe.output_items[output_index],
				recipe.output_amounts[output_index]
			):
				return RESULT_STORAGE_FULL

	# No method above yields control. Validate every sparse warehouse payload and
	# revision before the first write, producing one atomic game-frame transaction.
	if not _validate_storage_journal(journal):
		return RESULT_UNAVAILABLE
	if outputs_to_inventory:
		var current_inventory_revision := (
			run_state.get_inventory_revision_for_peer(output_peer_id)
			if output_peer_id > 0
			else run_state.get_inventory_revision()
		)
		if current_inventory_revision != inventory_revision:
			return RESULT_UNAVAILABLE
	var transaction_was_already_in_progress := _storage_transaction_in_progress
	_storage_transaction_in_progress = true
	if not _apply_storage_journal(journal):
		_storage_transaction_in_progress = transaction_was_already_in_progress
		push_error("Production storage transaction changed after revision validation.")
		return RESULT_UNAVAILABLE
	if outputs_to_inventory:
		var inventory_committed := (
			run_state.try_add_item_counts_for_peer_if_revision(
				output_peer_id,
				recipe.output_items,
				recipe.output_amounts,
				inventory_revision,
				false
			)
			if output_peer_id > 0
			else run_state.try_add_item_counts_if_revision(
				recipe.output_items,
				recipe.output_amounts,
				inventory_revision,
				false
			)
		)
		if not inventory_committed:
			_rollback_storage_journal(journal, journal.warehouse_journals.size() - 1)
			_storage_transaction_in_progress = transaction_was_already_in_progress
			push_error(
				"Production inventory transaction changed after revision validation."
			)
			return RESULT_UNAVAILABLE
	# Publish only after every warehouse array and revision has committed. Signal
	# listeners can therefore never observe a half-applied cross-store cycle.
	_publish_storage_journal_changes(journal)
	if outputs_to_inventory:
		run_state.notify_inventory_transaction_completed()
		personal_inventory_output_committed.emit(output_peer_id)
	_finish_storage_transaction(transaction_was_already_in_progress)
	return RESULT_SUCCESS


## Commits one building-local output into a player's inventory without emitting
## inventory signals. The building clears its output slot and advances its own
## revision before calling publish_personal_output_commit(), so signal listeners
## can never observe the item in both places at once.
func try_commit_personal_output_without_notification(
	item: PickupConfig,
	count: int,
	output_peer_id: int
) -> StringName:
	if (
		not authoritative_processing_enabled
		or run_state == null
		or item == null
		or not item.can_store_in_inventory
		or count <= 0
		or not is_personal_output_peer_available(output_peer_id)
	):
		return (
			RESULT_OUTPUT_PEER_UNAVAILABLE
			if not is_personal_output_peer_available(output_peer_id)
			else RESULT_UNAVAILABLE
		)
	var inventory_revision := (
		run_state.get_inventory_revision_for_peer(output_peer_id)
		if output_peer_id > 0
		else run_state.get_inventory_revision()
	)
	var committed := (
		run_state.try_add_item_count_for_peer_if_revision(
			output_peer_id,
			item,
			count,
			inventory_revision,
			false
		)
		if output_peer_id > 0
		else run_state.try_add_item_count_if_revision(
			item,
			count,
			inventory_revision,
			false
		)
	)
	return RESULT_SUCCESS if committed else RESULT_STORAGE_FULL


func publish_personal_output_commit(output_peer_id: int) -> void:
	if run_state == null:
		return
	run_state.notify_inventory_transaction_completed()
	personal_inventory_output_committed.emit(output_peer_id)


func _simulate_journal_consume_item_count(
	journal: StorageTransactionJournal,
	item: PickupConfig,
	count: int
) -> bool:
	if item == null or count <= 0:
		return false
	var remaining := count
	for warehouse_index in journal.ordered_warehouses.size():
		var warehouse := journal.ordered_warehouses[warehouse_index]
		var live_items := warehouse.storage_items
		var live_counts := warehouse.storage_stack_counts
		var warehouse_journal := journal.warehouse_journals[warehouse_index]
		for slot_index in OakWarehouse.STORAGE_CAPACITY:
			if remaining <= 0:
				return true
			var change_index := (
				int(warehouse_journal.change_index_by_slot[slot_index])
				if warehouse_journal != null
				else -1
			)
			var stored_item := (
				warehouse_journal.final_items[change_index]
				if change_index >= 0
				else live_items[slot_index]
			) as PickupConfig
			if not PickupConfig.inventory_identity_matches(stored_item, item):
				continue
			var current_count := (
				int(warehouse_journal.final_counts[change_index])
				if change_index >= 0
				else int(live_counts[slot_index])
			)
			var taken := mini(current_count, remaining)
			var next_count := current_count - taken
			remaining -= taken
			if next_count <= 0:
				journal.write_slot(warehouse_index, slot_index, null, 0)
			else:
				journal.write_slot(
					warehouse_index,
					slot_index,
					stored_item,
					next_count
				)
			if warehouse_journal == null:
				warehouse_journal = journal.warehouse_journals[warehouse_index]
	return remaining <= 0


func _simulate_journal_add_item_count(
	journal: StorageTransactionJournal,
	item: PickupConfig,
	count: int
) -> bool:
	if item == null or count <= 0:
		return false
	var remaining := count
	var stack_limit := PickupConfig.get_inventory_stack_limit(item)
	for warehouse_index in journal.ordered_warehouses.size():
		var warehouse := journal.ordered_warehouses[warehouse_index]
		var live_items := warehouse.storage_items
		var live_counts := warehouse.storage_stack_counts
		var warehouse_journal := journal.warehouse_journals[warehouse_index]
		for slot_index in OakWarehouse.STORAGE_CAPACITY:
			if remaining <= 0:
				return true
			var change_index := (
				int(warehouse_journal.change_index_by_slot[slot_index])
				if warehouse_journal != null
				else -1
			)
			var existing := (
				warehouse_journal.final_items[change_index]
				if change_index >= 0
				else live_items[slot_index]
			) as PickupConfig
			if not PickupConfig.inventory_items_can_stack(existing, item):
				continue
			var current_count := (
				int(warehouse_journal.final_counts[change_index])
				if change_index >= 0
				else int(live_counts[slot_index])
			)
			var available := stack_limit - current_count
			if available <= 0:
				continue
			var added := mini(available, remaining)
			journal.write_slot(
				warehouse_index,
				slot_index,
				existing,
				current_count + added
			)
			remaining -= added
			if warehouse_journal == null:
				warehouse_journal = journal.warehouse_journals[warehouse_index]
	for warehouse_index in journal.ordered_warehouses.size():
		var warehouse := journal.ordered_warehouses[warehouse_index]
		var live_items := warehouse.storage_items
		var warehouse_journal := journal.warehouse_journals[warehouse_index]
		for slot_index in OakWarehouse.STORAGE_CAPACITY:
			if remaining <= 0:
				return true
			var change_index := (
				int(warehouse_journal.change_index_by_slot[slot_index])
				if warehouse_journal != null
				else -1
			)
			var existing := (
				warehouse_journal.final_items[change_index]
				if change_index >= 0
				else live_items[slot_index]
			) as PickupConfig
			if existing != null:
				continue
			var added := mini(stack_limit, remaining)
			journal.write_slot(
				warehouse_index,
				slot_index,
				item,
				added
			)
			remaining -= added
			if warehouse_journal == null:
				warehouse_journal = journal.warehouse_journals[warehouse_index]
	return remaining <= 0


func _validate_storage_journal(journal: StorageTransactionJournal) -> bool:
	for warehouse_index in journal.warehouse_journals.size():
		var warehouse_journal := journal.warehouse_journals[warehouse_index]
		if warehouse_journal == null:
			continue
		var warehouse := warehouse_journal.warehouse
		if (
			warehouse == null
			or not is_instance_valid(warehouse)
			or warehouse != journal.ordered_warehouses[warehouse_index]
			or not warehouse.validate_production_storage_slot_changes(
				warehouse_journal.slot_indices,
				warehouse_journal.final_items,
				warehouse_journal.final_counts,
				warehouse_journal.expected_revision
			)
		):
			return false
	return true


func _apply_storage_journal(journal: StorageTransactionJournal) -> bool:
	for warehouse_index in journal.warehouse_journals.size():
		var warehouse_journal := journal.warehouse_journals[warehouse_index]
		if warehouse_journal == null:
			continue
		if warehouse_journal.warehouse.apply_production_storage_slot_changes(
			warehouse_journal.slot_indices,
			warehouse_journal.final_items,
			warehouse_journal.final_counts,
			warehouse_journal.expected_revision,
			false
		):
			continue
		if not _rollback_storage_journal(journal, warehouse_index - 1):
			push_error("Production storage journal rollback failed after a rejected write.")
		return false
	return true


func _rollback_storage_journal(
	journal: StorageTransactionJournal,
	last_applied_warehouse_index: int
) -> bool:
	var rollback_succeeded := true
	var bounded_last_index := mini(
		last_applied_warehouse_index,
		journal.warehouse_journals.size() - 1
	)
	for warehouse_index in range(bounded_last_index, -1, -1):
		var warehouse_journal := journal.warehouse_journals[warehouse_index]
		if warehouse_journal == null:
			continue
		if not warehouse_journal.warehouse.rollback_production_storage_slot_changes(
			warehouse_journal.slot_indices,
			warehouse_journal.original_items,
			warehouse_journal.original_counts,
			warehouse_journal.expected_revision + 1,
			warehouse_journal.expected_revision
		):
			rollback_succeeded = false
	return rollback_succeeded


func _publish_storage_journal_changes(journal: StorageTransactionJournal) -> void:
	for warehouse_journal in journal.warehouse_journals:
		if warehouse_journal != null:
			warehouse_journal.warehouse.notify_production_storage_changed()


func _get_ordered_operational_warehouses() -> Array[OakWarehouse]:
	_ensure_ordered_warehouse_cache()
	return _ordered_operational_warehouses


func _get_ordered_visible_warehouses() -> Array[OakWarehouse]:
	_ensure_ordered_warehouse_cache()
	return _ordered_visible_warehouses


func _has_operational_recipe_inputs(recipe: ProductionRecipe) -> bool:
	_ensure_storage_item_totals_cache()
	for input_index in recipe.input_items.size():
		var required_count := recipe.input_amounts[input_index]
		if required_count <= 0:
			continue
		var item := recipe.input_items[input_index]
		for previous_index in input_index:
			if PickupConfig.inventory_identity_matches(
				recipe.input_items[previous_index],
				item
			):
				required_count += maxi(recipe.input_amounts[previous_index], 0)
		if int(
			_operational_storage_item_totals.get(
				_get_storage_item_key(item),
				0
			)
		) < required_count:
			return false
	return true


func _has_operational_requirement_counts(
	requirements: Array[Dictionary]
) -> bool:
	_ensure_storage_item_totals_cache()
	for requirement_index in requirements.size():
		var requirement := requirements[requirement_index]
		var item := requirement.get("item") as PickupConfig
		var required_count := int(requirement.get("count", 0))
		for previous_index in requirement_index:
			var previous := requirements[previous_index]
			if PickupConfig.inventory_identity_matches(
				previous.get("item") as PickupConfig,
				item
			):
				required_count += maxi(int(previous.get("count", 0)), 0)
		if int(
			_operational_storage_item_totals.get(
				_get_storage_item_key(item),
				0
			)
		) < required_count:
			return false
	return true


func _has_cached_output_capacity_without_consumption(
	recipe: ProductionRecipe
) -> bool:
	_ensure_storage_item_totals_cache()
	var required_output_counts: Dictionary = {}
	var output_items_by_key: Dictionary = {}
	for output_index in recipe.output_items.size():
		var item := recipe.output_items[output_index]
		var item_key: Variant = _get_storage_item_key(item)
		required_output_counts[item_key] = (
			int(required_output_counts.get(item_key, 0))
			+ recipe.output_amounts[output_index]
		)
		output_items_by_key[item_key] = item

	var required_empty_slots := 0
	for item_key in required_output_counts:
		var remaining := maxi(
			int(required_output_counts[item_key])
			- int(_operational_storage_stack_capacity.get(item_key, 0)),
			0
		)
		if remaining == 0:
			continue
		var item := output_items_by_key[item_key] as PickupConfig
		var stack_limit := PickupConfig.get_inventory_stack_limit(item)
		required_empty_slots += ceili(float(remaining) / float(stack_limit))
		if required_empty_slots > _operational_empty_storage_slot_count:
			return false
	return true


func _ensure_storage_item_totals_cache() -> void:
	_ensure_ordered_warehouse_cache()
	if not _storage_item_totals_cache_dirty:
		return
	var operational_totals: Dictionary = {}
	var visible_totals: Dictionary = {}
	var operational_stack_capacity: Dictionary = {}
	var operational_empty_slot_count := 0
	for warehouse in _ordered_visible_warehouses:
		var include_in_operational := not warehouse.is_multiplayer_proxy
		for slot_index in OakWarehouse.STORAGE_CAPACITY:
			var item: PickupConfig = warehouse.storage_items[slot_index]
			if item == null:
				if include_in_operational:
					operational_empty_slot_count += 1
				continue
			var item_key: Variant = _get_storage_item_key(item)
			var count := maxi(warehouse.storage_stack_counts[slot_index], 1)
			visible_totals[item_key] = int(visible_totals.get(item_key, 0)) + count
			if include_in_operational:
				operational_totals[item_key] = (
					int(operational_totals.get(item_key, 0)) + count
				)
				var stack_capacity := maxi(
					PickupConfig.get_inventory_stack_limit(item) - count,
					0
				)
				if stack_capacity > 0:
					operational_stack_capacity[item_key] = (
						int(operational_stack_capacity.get(item_key, 0))
						+ stack_capacity
					)
	_operational_storage_item_totals = operational_totals
	_visible_storage_item_totals = visible_totals
	_operational_storage_stack_capacity = operational_stack_capacity
	_operational_empty_storage_slot_count = operational_empty_slot_count
	_storage_item_totals_cache_dirty = false


func _get_storage_item_key(item: PickupConfig) -> Variant:
	if not item.resource_path.is_empty():
		return StringName(item.resource_path)
	return item.get_instance_id()


func _ensure_ordered_warehouse_cache() -> void:
	if not _ordered_warehouse_cache_dirty:
		return
	var operational: Array[OakWarehouse] = []
	var visible: Array[OakWarehouse] = []
	for warehouse in warehouses:
		if not _is_visible_warehouse(warehouse):
			continue
		visible.append(warehouse)
		if not warehouse.is_multiplayer_proxy:
			operational.append(warehouse)
	operational.sort_custom(_warehouse_precedes)
	visible.sort_custom(_warehouse_precedes)
	# Replace the cache arrays instead of clearing them. A signal listener may
	# invalidate and rebuild during publication while the active journal still
	# holds the previous, immutable ordering.
	_ordered_operational_warehouses = operational
	_ordered_visible_warehouses = visible
	_ordered_warehouse_cache_dirty = false


func _is_visible_warehouse(warehouse: OakWarehouse) -> bool:
	return (
		warehouse != null
		and is_instance_valid(warehouse)
		and not warehouse.is_queued_for_deletion()
		and not warehouse.is_dead
		and not warehouse.is_removing
		and warehouse.is_operational
	)


func _invalidate_ordered_warehouse_cache() -> void:
	_ordered_warehouse_cache_dirty = true
	_storage_item_totals_cache_dirty = true


func _warehouse_precedes(left: OakWarehouse, right: OakWarehouse) -> bool:
	var left_net_id := int(left.get_meta(&"net_id", 0))
	var right_net_id := int(right.get_meta(&"net_id", 0))
	if left_net_id > 0 or right_net_id > 0:
		if left_net_id != right_net_id:
			return left_net_id < right_net_id
	if not is_equal_approx(left.global_position.y, right.global_position.y):
		return left.global_position.y < right.global_position.y
	if not is_equal_approx(left.global_position.x, right.global_position.x):
		return left.global_position.x < right.global_position.x
	return left.get_instance_id() < right.get_instance_id()


func _on_production_tick() -> void:
	if not authoritative_processing_enabled:
		return
	var active_buildings := production_buildings.duplicate()
	for building in active_buildings:
		if building == null or not is_instance_valid(building):
			production_buildings.erase(building)
			continue
		building.advance_shared_production_tick(TICK_INTERVAL_SECONDS)


func _on_warehouse_storage_changed() -> void:
	_storage_item_totals_cache_dirty = true
	storage_totals_changed.emit()
	if _storage_transaction_in_progress:
		_warehouse_state_changed_during_transaction = true
		return
	_retry_waiting_buildings(true, false)


func _on_warehouse_construction_finished(warehouse: OakWarehouse) -> void:
	if (
		warehouse == null
		or not is_instance_valid(warehouse)
		or not warehouses.has(warehouse)
	):
		return
	_invalidate_ordered_warehouse_cache()
	# Operational capacity is part of the shared storage state even when the new
	# warehouse starts empty and therefore emits no storage_changed signal.
	_on_warehouse_storage_changed()


func _on_warehouse_removal_started(
	_mode: int,
	warehouse: OakWarehouse
) -> void:
	if warehouse != null and warehouses.has(warehouse):
		_invalidate_ordered_warehouse_cache()


func _on_warehouse_tree_exiting(warehouse: OakWarehouse) -> void:
	if warehouse == null:
		return
	warehouses.erase(warehouse)
	_invalidate_ordered_warehouse_cache()


func _on_inventory_changed() -> void:
	if _storage_transaction_in_progress:
		_inventory_state_changed_during_transaction = true
		return
	_retry_waiting_buildings(false, true)


func _retry_waiting_buildings(
	retry_warehouse_waits: bool,
	retry_inventory_waits: bool,
	force_inventory_retry: bool = false
) -> void:
	if not authoritative_processing_enabled or _storage_transaction_in_progress:
		return
	var retry_warehouse_next := (
		retry_warehouse_waits
		or _warehouse_state_changed_during_transaction
	)
	var retry_inventory_next := (
		retry_inventory_waits
		or _inventory_state_changed_during_transaction
	)
	var force_inventory_retry_next := force_inventory_retry
	_warehouse_state_changed_during_transaction = false
	_inventory_state_changed_during_transaction = false
	if not retry_warehouse_next and not retry_inventory_next:
		return
	_storage_transaction_in_progress = true
	while retry_warehouse_next or retry_inventory_next:
		if retry_warehouse_next:
			_retry_warehouse_waiting_buildings()
		if retry_inventory_next:
			_retry_inventory_waiting_buildings(force_inventory_retry_next)
		retry_warehouse_next = _warehouse_state_changed_during_transaction
		retry_inventory_next = _inventory_state_changed_during_transaction
		force_inventory_retry_next = false
		_warehouse_state_changed_during_transaction = false
		_inventory_state_changed_during_transaction = false
	_storage_transaction_in_progress = false


func _finish_storage_transaction(previous_transaction_state: bool) -> void:
	_storage_transaction_in_progress = previous_transaction_state
	if not previous_transaction_state:
		# A completed building can produce the exact input of an earlier parked
		# building. Drain those synchronous state changes before returning so an
		# event-driven waiter never depends on a future one-second fallback tick.
		_retry_waiting_buildings(false, false)


func _retry_warehouse_waiting_buildings() -> void:
	# Swap out the cohort before invoking buildings. A failed attempt registers
	# into the fresh arrays and cannot be visited twice by the same event.
	var waiting_buildings := _warehouse_waiting_buildings
	_warehouse_waiting_buildings = []
	_warehouse_waiting_indices = {}
	for building in waiting_buildings:
		if building == null or not is_instance_valid(building):
			continue
		building.try_complete_ready_production()


func _retry_inventory_waiting_buildings(force_retry: bool) -> void:
	var waiting_buildings := _inventory_waiting_buildings
	var waiting_revisions := _inventory_waiting_revisions
	_inventory_waiting_buildings = []
	_inventory_waiting_indices = {}
	_inventory_waiting_revisions = {}
	for building in waiting_buildings:
		if building == null or not is_instance_valid(building):
			continue
		var instance_id := building.get_instance_id()
		if (
			not force_retry
			and _get_output_inventory_revision(building)
			== int(waiting_revisions.get(instance_id, -1))
		):
			update_ready_production_wait(building, RESULT_STORAGE_FULL)
			continue
		building.try_complete_ready_production()


func _get_output_inventory_revision(building: ProductionBuilding) -> int:
	if run_state == null or building == null or not is_instance_valid(building):
		return -1
	if building.personal_output_peer_id > 0:
		return run_state.get_inventory_revision_for_peer(
			building.personal_output_peer_id
		)
	return run_state.get_inventory_revision()


func _add_waiting_building(
	building: ProductionBuilding,
	waiting_buildings: Array[ProductionBuilding],
	waiting_indices: Dictionary[int, int]
) -> void:
	var instance_id := building.get_instance_id()
	if waiting_indices.has(instance_id):
		return
	waiting_indices[instance_id] = waiting_buildings.size()
	waiting_buildings.append(building)


func _remove_waiting_building(
	instance_id: int,
	waiting_buildings: Array[ProductionBuilding],
	waiting_indices: Dictionary[int, int]
) -> void:
	var index := int(waiting_indices.get(instance_id, -1))
	if index < 0:
		return
	waiting_indices.erase(instance_id)
	if index < waiting_buildings.size():
		# Preserve registration order for deterministic competition over newly
		# available inputs; the next state event compacts this one tombstone.
		waiting_buildings[index] = null


func _refresh_timer_state() -> void:
	if not is_node_ready():
		return
	if authoritative_processing_enabled:
		if production_tick_timer.is_stopped():
			production_tick_timer.start()
	else:
		production_tick_timer.stop()
