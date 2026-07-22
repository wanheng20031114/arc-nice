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
	if not warehouse.storage_changed.is_connected(_on_warehouse_storage_changed):
		warehouse.storage_changed.connect(_on_warehouse_storage_changed)
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
	if warehouse.storage_changed.is_connected(_on_warehouse_storage_changed):
		warehouse.storage_changed.disconnect(_on_warehouse_storage_changed)
	var construction_callback := _on_warehouse_construction_finished.bind(warehouse)
	if warehouse.construction_finished.is_connected(construction_callback):
		warehouse.construction_finished.disconnect(construction_callback)
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
	var total := 0
	for warehouse in _get_ordered_visible_warehouses():
		total += warehouse.get_storage_item_total(item)
	return total


func try_consume_item_requirements(requirements: Array[Dictionary]) -> StringName:
	if not authoritative_processing_enabled or requirements.is_empty():
		return RESULT_UNAVAILABLE
	var ordered_warehouses := _get_ordered_operational_warehouses()
	if ordered_warehouses.is_empty():
		return RESULT_MISSING_INPUT
	var states: Array[Dictionary] = []
	for warehouse in ordered_warehouses:
		states.append(warehouse.export_production_storage_snapshot())
	for requirement in requirements:
		var item := requirement.get("item") as PickupConfig
		var count := int(requirement.get("count", 0))
		if item == null or count <= 0:
			return RESULT_UNAVAILABLE
		if not _simulate_consume_item_count(states, item, count):
			return RESULT_MISSING_INPUT
	for state in states:
		var warehouse := state["warehouse"] as OakWarehouse
		if (
			warehouse == null
			or not is_instance_valid(warehouse)
			or warehouse.get_storage_revision() != int(state["revision"])
		):
			return RESULT_UNAVAILABLE
	var previous_transaction_state := _storage_transaction_in_progress
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
			_storage_transaction_in_progress = previous_transaction_state
			return RESULT_UNAVAILABLE
		changed_warehouses.append(warehouse)
	for warehouse in changed_warehouses:
		warehouse.notify_production_storage_changed()
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

	var states: Array[Dictionary] = []
	for warehouse in ordered_warehouses:
		states.append(warehouse.export_production_storage_snapshot())

	for input_index in recipe.input_items.size():
		var input_amount := recipe.input_amounts[input_index]
		if input_amount == 0:
			continue
		if not _simulate_consume_item_count(
			states,
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
			_storage_transaction_in_progress = transaction_was_already_in_progress
			push_error(
				"Production inventory transaction changed after revision validation."
			)
			return RESULT_UNAVAILABLE
	# Publish only after every warehouse array and revision has committed. Signal
	# listeners can therefore never observe a half-applied cross-store cycle.
	for warehouse in changed_warehouses:
		warehouse.notify_production_storage_changed()
	if outputs_to_inventory:
		run_state.notify_inventory_transaction_completed()
		personal_inventory_output_committed.emit(output_peer_id)
	_finish_storage_transaction(transaction_was_already_in_progress)
	return RESULT_SUCCESS


func _simulate_consume_item_count(
	states: Array[Dictionary],
	item: PickupConfig,
	count: int
) -> bool:
	if item == null or count <= 0:
		return false
	var remaining := count
	for state in states:
		var items: Array = state["items"]
		var counts: Array = state["counts"]
		for slot_index in items.size():
			if remaining <= 0:
				return true
			var stored_item := items[slot_index] as PickupConfig
			if not PickupConfig.inventory_identity_matches(stored_item, item):
				continue
			var taken := mini(int(counts[slot_index]), remaining)
			var next_count := int(counts[slot_index]) - taken
			remaining -= taken
			if next_count <= 0:
				items[slot_index] = null
				counts[slot_index] = 0
			else:
				counts[slot_index] = next_count
			state["changed"] = true
	return remaining <= 0


func _simulate_add_item_count(
	states: Array[Dictionary],
	item: PickupConfig,
	count: int
) -> bool:
	if item == null or count <= 0:
		return false
	var remaining := count
	var stack_limit := PickupConfig.get_inventory_stack_limit(item)
	for state in states:
		var items: Array = state["items"]
		var counts: Array = state["counts"]
		for slot_index in items.size():
			if remaining <= 0:
				return true
			var existing := items[slot_index] as PickupConfig
			if not PickupConfig.inventory_items_can_stack(existing, item):
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


func _get_ordered_visible_warehouses() -> Array[OakWarehouse]:
	var result: Array[OakWarehouse] = []
	for warehouse in warehouses:
		if (
			warehouse == null
			or not is_instance_valid(warehouse)
			or warehouse.is_queued_for_deletion()
			or warehouse.is_dead
			or warehouse.is_removing
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
	# Operational capacity is part of the shared storage state even when the new
	# warehouse starts empty and therefore emits no storage_changed signal.
	_on_warehouse_storage_changed()


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
