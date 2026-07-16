extends Node
class_name ProductionCoordinator

signal storage_totals_changed

const TICK_INTERVAL_SECONDS := 1.0
const RESULT_SUCCESS := &"success"
const RESULT_MISSING_INPUT := &"missing_input"
const RESULT_STORAGE_FULL := &"storage_full"
const RESULT_UNAVAILABLE := &"unavailable"

@onready var production_tick_timer: Timer = $ProductionTickTimer

var authoritative_processing_enabled := true
var production_buildings: Array[ProductionBuilding] = []
var warehouses: Array[OakWarehouse] = []
var _storage_transaction_in_progress := false


func _ready() -> void:
	production_tick_timer.timeout.connect(_on_production_tick)
	_refresh_timer_state()


func set_authoritative_processing_enabled(enabled: bool) -> void:
	authoritative_processing_enabled = enabled
	_refresh_timer_state()


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
	if not warehouse.storage_changed.is_connected(_on_warehouse_storage_changed):
		warehouse.storage_changed.connect(_on_warehouse_storage_changed)
	storage_totals_changed.emit()


func unregister_plant(plant: PlantDefense) -> void:
	var production_building := plant as ProductionBuilding
	if production_building != null:
		production_buildings.erase(production_building)
		production_building.set_production_coordinator(null)

	var warehouse := plant as OakWarehouse
	if warehouse == null:
		return
	warehouses.erase(warehouse)
	if warehouse.storage_changed.is_connected(_on_warehouse_storage_changed):
		warehouse.storage_changed.disconnect(_on_warehouse_storage_changed)
	storage_totals_changed.emit()


func get_total_item_count(item: PickupConfig) -> int:
	if item == null:
		return 0
	var total := 0
	for warehouse in _get_ordered_operational_warehouses():
		total += warehouse.get_storage_item_total(item)
	return total


func try_commit_recipe(recipe: ProductionRecipe) -> StringName:
	if not authoritative_processing_enabled or recipe == null or not recipe.is_valid():
		return RESULT_UNAVAILABLE
	var ordered_warehouses := _get_ordered_operational_warehouses()
	if ordered_warehouses.is_empty():
		return RESULT_MISSING_INPUT

	var states: Array[Dictionary] = []
	for warehouse in ordered_warehouses:
		states.append(warehouse.export_production_storage_snapshot())

	var input_remaining := recipe.input_amount
	for state in states:
		var items: Array = state["items"]
		var counts: Array = state["counts"]
		for slot_index in items.size():
			if input_remaining <= 0:
				break
			var slot_item := items[slot_index] as PickupConfig
			if not _items_share_stack(slot_item, recipe.input_item):
				continue
			var taken := mini(int(counts[slot_index]), input_remaining)
			var next_count := int(counts[slot_index]) - taken
			input_remaining -= taken
			if next_count <= 0:
				items[slot_index] = null
				counts[slot_index] = 0
			else:
				counts[slot_index] = next_count
			state["changed"] = true
	if input_remaining > 0:
		return RESULT_MISSING_INPUT

	for output_index in recipe.output_items.size():
		if not _simulate_add_item_count(
			states,
			recipe.output_items[output_index],
			recipe.output_amounts[output_index]
		):
			return RESULT_STORAGE_FULL

	# No method above yields control. Revisions can therefore be checked for all
	# warehouses before any write, producing one atomic game-frame transaction.
	for state in states:
		var warehouse := state["warehouse"] as OakWarehouse
		if (
			warehouse == null
			or not is_instance_valid(warehouse)
			or warehouse.get_storage_revision() != int(state["revision"])
		):
			return RESULT_UNAVAILABLE
	var transaction_was_already_in_progress := _storage_transaction_in_progress
	_storage_transaction_in_progress = true
	var changed_warehouses: Array[OakWarehouse] = []
	for state in states:
		if not bool(state["changed"]):
			continue
		var warehouse := state["warehouse"] as OakWarehouse
		if not warehouse.apply_production_storage_snapshot(
			state["items"],
			state["counts"],
			int(state["revision"]),
			false
		):
			_storage_transaction_in_progress = transaction_was_already_in_progress
			push_error("Production storage transaction changed after revision validation.")
			return RESULT_UNAVAILABLE
		changed_warehouses.append(warehouse)
	# Publish only after every warehouse array and revision has committed. Signal
	# listeners can therefore never observe a half-applied cross-warehouse cycle.
	for warehouse in changed_warehouses:
		warehouse.notify_production_storage_changed()
	_storage_transaction_in_progress = transaction_was_already_in_progress
	return RESULT_SUCCESS


func _simulate_add_item_count(
	states: Array[Dictionary],
	item: PickupConfig,
	count: int
) -> bool:
	if item == null or count <= 0:
		return false
	var remaining := count
	var stack_limit := clampi(item.inventory_stack_limit, 1, 999) if item.stackable else 1
	for state in states:
		var items: Array = state["items"]
		var counts: Array = state["counts"]
		for slot_index in items.size():
			if remaining <= 0:
				return true
			var existing := items[slot_index] as PickupConfig
			if not _items_share_stack(existing, item):
				continue
			var available := stack_limit - int(counts[slot_index])
			if available <= 0:
				continue
			var added := mini(available, remaining)
			counts[slot_index] = int(counts[slot_index]) + added
			remaining -= added
			state["changed"] = true
	for state in states:
		var items: Array = state["items"]
		var counts: Array = state["counts"]
		for slot_index in items.size():
			if remaining <= 0:
				return true
			if items[slot_index] != null:
				continue
			var added := mini(stack_limit, remaining)
			items[slot_index] = item
			counts[slot_index] = added
			remaining -= added
			state["changed"] = true
	return remaining <= 0


func _get_ordered_operational_warehouses() -> Array[OakWarehouse]:
	var result: Array[OakWarehouse] = []
	for warehouse in warehouses:
		if (
			warehouse == null
			or not is_instance_valid(warehouse)
			or warehouse.is_queued_for_deletion()
			or warehouse.is_dead
			or warehouse.is_removing
			or warehouse.is_multiplayer_proxy
			or not warehouse.is_operational
		):
			continue
		result.append(warehouse)
	result.sort_custom(_warehouse_precedes)
	return result


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


func _items_share_stack(existing_item: PickupConfig, incoming_item: PickupConfig) -> bool:
	if existing_item == null or incoming_item == null or not incoming_item.stackable:
		return false
	if existing_item == incoming_item:
		return true
	return (
		not existing_item.resource_path.is_empty()
		and existing_item.resource_path == incoming_item.resource_path
	)


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
	storage_totals_changed.emit()
	if not authoritative_processing_enabled or _storage_transaction_in_progress:
		return
	# A building parked at zero remaining time completes in this same storage
	# change frame as soon as its raw material becomes available.
	_storage_transaction_in_progress = true
	for building in production_buildings.duplicate():
		if building != null and is_instance_valid(building):
			building.try_complete_ready_production()
	_storage_transaction_in_progress = false


func _refresh_timer_state() -> void:
	if not is_node_ready():
		return
	if authoritative_processing_enabled:
		if production_tick_timer.is_stopped():
			production_tick_timer.start()
	else:
		production_tick_timer.stop()
