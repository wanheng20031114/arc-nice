extends Node

## Instrument authored panels without replacing their widgets or refresh logic.
class CountedProductionPanel extends ProductionBuildingPanel:
	var refresh_count := 0
	func _refresh_all(replicate: bool = false) -> void:
		refresh_count += 1
		super._refresh_all(replicate)

class CountedWarehousePanel extends OakWarehousePanel:
	var refresh_count := 0
	func _refresh_all() -> void:
		refresh_count += 1
		super._refresh_all()

var result: Dictionary = {}
var failures: Array[String] = []

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	var coordinator := load("res://scene/game_modes/tower_defense/economy/production/production_coordinator.tscn").instantiate() as ProductionCoordinator
	add_child(coordinator)
	coordinator.production_tick_timer.stop()
	var wood_config := load("res://resources/config/plant_defense/wood_processing_station.tres") as PlantDefenseConfig
	var wood := wood_config.plant_scene.instantiate() as ProductionBuilding
	add_child(wood)
	wood.setup(wood_config, null, [Vector2i.ZERO])
	coordinator.register_plant(wood)
	var storage_config := load("res://resources/config/plant_defense/oak_warehouse.tres") as PlantDefenseConfig
	var warehouse := storage_config.plant_scene.instantiate() as OakWarehouse
	add_child(warehouse)
	warehouse.setup(storage_config, null, [Vector2i.ONE])
	coordinator.register_plant(warehouse)
	var water := load("res://resources/config/materials/material_water_bottle.tres") as PickupConfig
	var production_panel = load("res://scene/game_modes/tower_defense/economy/production/production_building_panel.tscn").instantiate()
	production_panel.set_script(CountedProductionPanel)
	add_child(production_panel)
	production_panel.bind_building(wood, null)
	# This fixture exercises model signals; player control locking has its own UI flow.
	production_panel.overlay.show()
	var warehouse_panel = load("res://scene/game_modes/tower_defense/economy/warehouse/oak_warehouse_panel.tscn").instantiate()
	warehouse_panel.set_script(CountedWarehousePanel)
	add_child(warehouse_panel)
	warehouse_panel.bind_warehouse(warehouse, null)
	warehouse_panel.overlay.show()
	await get_tree().process_frame
	var production_before: int = production_panel.refresh_count
	var warehouse_before: int = warehouse_panel.refresh_count
	var start := Time.get_ticks_usec()
	for update in 100:
		warehouse.storage_items[0] = water
		warehouse.storage_stack_counts[0] = update + 1
		warehouse.storage_revision += 1
		warehouse.storage_changed.emit()
		wood.production_enabled = update % 2 == 0
		wood.production_state_changed.emit(false)
	_check(production_panel.refresh_count == production_before, "Production refresh waits for the final same-frame state")
	_check(warehouse_panel.refresh_count == warehouse_before, "Warehouse refresh waits for the final same-frame state")
	await get_tree().process_frame
	var coalesced_usec := Time.get_ticks_usec() - start
	_check(production_panel.refresh_count == production_before + 1, "100 production and storage notifications redraw once")
	_check(warehouse_panel.refresh_count == warehouse_before + 1, "100 warehouse notifications redraw once")
	_check(warehouse_panel.storage_slots[0].stack_count == 100, "Warehouse paints the final count, not an intermediate value")
	_check(production_panel.toggle_button.text == "▶", "Production paints the final stopped state")
	start = Time.get_ticks_usec()
	for update in 100:
		production_panel._refresh_all()
		warehouse_panel._refresh_all()
	var immediate_usec := Time.get_ticks_usec() - start
	wood.production_state_changed.emit(false)
	warehouse.storage_changed.emit()
	production_panel.close()
	warehouse_panel.close()
	production_before = production_panel.refresh_count
	warehouse_before = warehouse_panel.refresh_count
	await get_tree().process_frame
	_check(production_panel.refresh_count == production_before and warehouse_panel.refresh_count == warehouse_before, "Closing cancels pending visual work")
	_check(not wood.production_state_changed.is_connected(production_panel._request_state_refresh), "Production close unbinds model signal")
	_check(not warehouse.storage_changed.is_connected(warehouse_panel._request_state_refresh), "Warehouse close unbinds model signal")
	# Reopening on the same models must show edits that happened while closed.
	warehouse.storage_stack_counts[0] = 123
	warehouse.storage_revision += 1
	warehouse.storage_changed.emit()
	warehouse_panel.bind_warehouse(warehouse, null)
	_check(warehouse_panel.storage_slots[0].stack_count == 123, "Rebinding refreshes edits made while closed")
	warehouse_panel.close()
	var inventory := load("res://scene/ui/shared/profile/player_inventory_view.tscn").instantiate() as PlayerInventoryView
	add_child(inventory)
	var state := get_node("/root/RunState") as RunStateStore
	state.ensure_run_started()
	inventory.bind_run_state(state)
	var initial_count := inventory.slots[0].stack_count
	inventory.hide()
	state.inventory[0] = water
	state.inventory_stack_counts[0] = initial_count + 17
	state.inventory_revision += 1
	state.inventory_changed.emit()
	inventory.refresh()
	_check(inventory.slots[0].stack_count == initial_count, "Hidden inventory does not rebuild slots")
	_check(inventory.get_item(0) == water, "Hidden inventory model access remains current")
	inventory.set_panel_active(true)
	_check(inventory.slots[0].stack_count == initial_count + 17, "Activating inventory paints all intervening edits")
	print("ECONOMY_UI_REFRESH_REGRESSION ", JSON.stringify({"failures": failures, "notifications": 100, "refreshes_per_panel": 1, "coalesced_including_frame_usec": coalesced_usec, "immediate_100_refresh_pairs_usec": immediate_usec}))
	result["exit_code"] = 0 if failures.is_empty() else 1
	queue_free()

func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
		push_error(message)
