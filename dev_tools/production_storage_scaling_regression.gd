extends SceneTree

var failures := 0
var coordinator: ProductionCoordinator
var stores: Array[OakWarehouse] = []
var water: PickupConfig
var output_path := "res://dev_tools/output/production_storage_scaling.json"


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--output="):
			output_path = arg.trim_prefix("--output=")
	_run.call_deferred()


func _run() -> void:
	coordinator = load("res://scene/game_modes/tower_defense/economy/production/production_coordinator.tscn").instantiate()
	root.add_child(coordinator)
	coordinator.production_tick_timer.stop()
	water = load("res://resources/config/materials/material_water_bottle.tres")
	var config: PlantDefenseConfig = load("res://resources/config/plant_defense/oak_warehouse.tres")
	for index in 128:
		var warehouse := config.plant_scene.instantiate() as OakWarehouse
		root.add_child(warehouse)
		warehouse.position = Vector2(index * 80, -200)
		warehouse.set_meta(&"net_id", index + 1)
		warehouse.configure_persistent_storage_identity(index + 1)
		warehouse.setup(config, null, [Vector2i(index, 0)])
		coordinator.register_plant(warehouse)
		stores.append(warehouse)
	var recipe := ProductionRecipe.new()
	recipe.recipe_id = &"cache_probe_source"
	recipe.input_items = [water]
	recipe.input_amounts = [0]
	recipe.output_items = [water]
	recipe.output_amounts = [1]
	_expect(recipe.is_valid(), "source recipe is valid")
	_expect(coordinator.get_total_item_count(water) == 0, "empty warehouse total")
	var scans_before := int(coordinator.get_storage_totals_metrics()["warehouse_scans"])
	var batches: Array[float] = []
	for batch in 6:
		var start := Time.get_ticks_usec()
		for operation in 100:
			_expect(coordinator.try_commit_recipe(recipe) == ProductionCoordinator.RESULT_SUCCESS, "source production commits")
			_expect(coordinator.get_total_item_count(water) == batch * 100 + operation + 1, "cache observes committed output")
		batches.append(float(Time.get_ticks_usec() - start) / 1000.0)
	var scans := int(coordinator.get_storage_totals_metrics()["warehouse_scans"]) - scans_before
	_expect(scans == 600, "600 single-store commits scan 600 stores, not all 128 warehouses")
	var result := {"warehouse_count": 128, "operations_per_batch": 100, "batches_ms": batches, "committed_store_scans": scans}
	print("PRODUCTION_SCALING ", JSON.stringify(result))
	var file := FileAccess.open(output_path, FileAccess.WRITE)
	file.store_string(JSON.stringify(result, "\t"))
	file.close()
	# Removing a store must remove its contribution and its capacity immediately.
	var removed_count := stores[0].get_storage_item_total(water)
	coordinator.unregister_plant(stores[0])
	_expect(coordinator.get_total_item_count(water) == 600 - removed_count, "unregister invalidates total")
	coordinator.register_plant(stores[0])
	_expect(coordinator.get_total_item_count(water) == 600, "reregister restores contribution")
	# Data commits without public notification still invalidate cached totals.
	var target := stores[-1]
	var item_array: Array[PickupConfig] = [water]
	var revision := target.storage_revision
	_expect(target.apply_production_storage_slot_changes(PackedInt32Array([0]), item_array, PackedInt32Array([7]), revision, false), "silent commit succeeds")
	_expect(coordinator.get_total_item_count(water) == 607, "silent commit is observable to next transaction")
	_expect(target.rollback_production_storage_slot_changes(PackedInt32Array([0]), [null], PackedInt32Array([0]), revision + 1, revision), "silent rollback succeeds")
	_expect(coordinator.get_total_item_count(water) == 600, "rollback restores aggregate")
	# All stores in a network batch commit before the first public notification.
	var snapshot_a := stores[-2].export_storage_snapshot()
	var snapshot_b := stores[-1].export_storage_snapshot()
	for snapshot in [snapshot_a, snapshot_b]:
		snapshot["revision"] += 1
		snapshot["slots"][0]["config_path"] = water.resource_path
		snapshot["slots"][0]["stack_count"] = 9
	var observations: Array[int] = []
	var observe := func() -> void: observations.append(coordinator.get_total_item_count(water))
	stores[-2].storage_changed.connect(observe)
	stores[-1].storage_changed.connect(observe)
	_expect(OakWarehouse.apply_storage_snapshot_batch([stores[-2], stores[-1]], [snapshot_a, snapshot_b]), "atomic two-store snapshot applies")
	_expect(observations == [618, 618], "each public notification observes both committed stores")
	stores[-2].storage_changed.disconnect(observe)
	stores[-1].storage_changed.disconnect(observe)
	# A building under construction has inventory, but no usable capacity yet.
	var unfinished := config.plant_scene.instantiate() as OakWarehouse
	root.add_child(unfinished)
	unfinished.setup(config, null, [Vector2i(130, 0)], false, -1, 0, -1, true)
	coordinator.register_plant(unfinished)
	unfinished.storage_items[0] = water
	unfinished.storage_stack_counts[0] = 4
	unfinished.storage_revision += 1
	_expect(coordinator.get_total_item_count(water) == 618, "unfinished warehouse stays outside totals")
	unfinished._finish_construction(false)
	_expect(coordinator.get_total_item_count(water) == 622, "construction completion admits stored items")
	coordinator.unregister_plant(unfinished)
	unfinished.queue_free()
	# Replica inventory is visible in the UI and excluded from authority capacity.
	var proxy := config.plant_scene.instantiate() as OakWarehouse
	root.add_child(proxy)
	proxy.setup(config, null, [Vector2i(131, 0)], true)
	proxy.storage_items[0] = water
	proxy.storage_stack_counts[0] = 5
	coordinator.register_plant(proxy)
	_expect(coordinator.get_total_item_count(water) == 623, "replica inventory contributes to visible totals")
	coordinator._ensure_storage_item_totals_cache()
	_expect(int(coordinator._operational_storage_item_totals[coordinator._get_storage_item_key(water)]) == 618, "replica inventory cannot fund authority recipes")
	coordinator.unregister_plant(proxy)
	proxy.queue_free()
	for warehouse in stores:
		coordinator.unregister_plant(warehouse)
		warehouse.queue_free()
	stores.clear()
	coordinator.queue_free()
	for frame in 3:
		await process_frame
	print("PRODUCTION_STORAGE_REGRESSION failures=", failures)
	quit(0 if failures == 0 else 1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures += 1
		push_error(message)
