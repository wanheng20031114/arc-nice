extends SceneTree

const COORDINATOR_SCENE := preload(
	"res://scene/plant_defense/production_coordinator.tscn"
)
const WAREHOUSE_SCENE := preload("res://scene/plant_defense/oak_warehouse.tscn")
const WOOD := preload("res://resources/config/materials/material_wood.tres")
const PLANK := preload("res://resources/config/materials/material_plank.tres")
const WATER_SOURCE := preload(
	"res://resources/config/production/water_source.tres"
)
const WATER_BOTTLE := preload(
	"res://resources/config/materials/material_water_bottle.tres"
)
const WATER_COLLECTOR_ITEM := preload(
	"res://resources/config/buildings/building_water_collector.tres"
)

const WAREHOUSE_COUNT := 32
const COHORT_SIZES := [1, 16, 64]
const WARMUP_ROUNDS := 2
const SAMPLE_ROUNDS := 9
const SCENARIO_MISSING := &"missing"
const SCENARIO_FULL := &"full"
const SCENARIO_SUCCESS := &"success"


class Fixture:
	extends RefCounted

	var coordinator: ProductionCoordinator
	var warehouses: Array[OakWarehouse] = []


class SignalProbe:
	extends RefCounted

	var storage_signal_count := 0
	var totals_signal_count := 0

	func on_storage_changed() -> void:
		storage_signal_count += 1

	func on_totals_changed() -> void:
		totals_signal_count += 1


var failures: PackedStringArray = []
var warehouse_config: PlantDefenseConfig = null
var shared_recipe: ProductionRecipe = null
var full_recipe: ProductionRecipe = null


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	warehouse_config = PlantDefenseRegistry.get_config(&"oak_warehouse")
	shared_recipe = _make_recipe(
		&"journal_wood_to_plank",
		[WOOD],
		[1],
		[PLANK],
		[2]
	)
	full_recipe = _make_recipe(
		&"journal_environment_output",
		[WATER_SOURCE],
		[0],
		[WATER_BOTTLE],
		[1]
	)
	_expect(warehouse_config != null, "A/B夹具必须加载橡木仓库配置。")
	_expect(shared_recipe.is_valid(), "木材事务配方必须有效。")
	_expect(full_recipe.is_valid(), "环境产出事务配方必须有效。")
	if not failures.is_empty():
		_finish(null)
		return

	var test_root := Node.new()
	test_root.name = "ProductionTransactionJournalAB"
	root.add_child(test_root)
	await _test_semantic_oracle(test_root)
	await _test_order_cache_lifecycle(test_root)
	await _run_transaction_ab(test_root)
	_finish(test_root)


func _test_semantic_oracle(test_root: Node) -> void:
	var optimized := _create_fixture_nodes(test_root, "SemanticOptimized", 2)
	var legacy := _create_fixture_nodes(test_root, "SemanticLegacy", 2)
	await process_frame
	_setup_fixture(optimized)
	_setup_fixture(legacy)

	# Two inputs in one warehouse plus output back into the first consumed slot.
	var multi_input_recipe := _make_recipe(
		&"journal_multi_input_same_slot",
		[WOOD, PLANK],
		[5, 1],
		[WOOD],
		[1]
	)
	_set_exact_slots(optimized.warehouses[0], [WOOD, PLANK], [5, 3])
	_set_exact_slots(legacy.warehouses[0], [WOOD, PLANK], [5, 3])
	var optimized_probe := _attach_probe(optimized)
	var legacy_probe := _attach_probe(legacy)
	var optimized_revision := optimized.warehouses[0].get_storage_revision()
	var legacy_revision := legacy.warehouses[0].get_storage_revision()
	var optimized_result := optimized.coordinator.try_commit_recipe(multi_input_recipe)
	var legacy_result := _legacy_try_commit_recipe(legacy.coordinator, multi_input_recipe)
	_expect(
		optimized_result == ProductionCoordinator.RESULT_SUCCESS
		and legacy_result == optimized_result,
		"同仓多输入事务必须与旧实现同样成功。"
	)
	_expect(
		_fixture_storage_matches(optimized, legacy)
		and optimized.warehouses[0].get_storage_item(0) == WOOD
		and optimized.warehouses[0].get_storage_item_count(0) == 1
		and optimized.warehouses[0].get_storage_item(1) == PLANK
		and optimized.warehouses[0].get_storage_item_count(1) == 2,
		"同仓多输入与先清空后写回同槽必须保留旧槽序语义。"
	)
	_expect(
		optimized.warehouses[0].get_storage_revision() == optimized_revision + 1
		and legacy.warehouses[0].get_storage_revision() == legacy_revision + 1
		and optimized_probe.storage_signal_count == 1
		and optimized_probe.totals_signal_count == 1
		and legacy_probe.storage_signal_count == 1
		and legacy_probe.totals_signal_count == 1,
		"一次成功事务对每个变更仓库只能增加一次revision并发布一次信号。"
	)

	# Missing input after a partial simulated consume must leave every slot intact.
	_disconnect_probe(optimized, optimized_probe)
	_disconnect_probe(legacy, legacy_probe)
	_set_exact_slots(optimized.warehouses[0], [WOOD], [2])
	_set_exact_slots(legacy.warehouses[0], [WOOD], [2])
	optimized_probe = _attach_probe(optimized)
	legacy_probe = _attach_probe(legacy)
	optimized_revision = optimized.warehouses[0].get_storage_revision()
	legacy_revision = legacy.warehouses[0].get_storage_revision()
	var missing_recipe := _make_recipe(
		&"journal_partial_missing",
		[WOOD],
		[3],
		[PLANK],
		[1]
	)
	optimized_result = optimized.coordinator.try_commit_recipe(missing_recipe)
	legacy_result = _legacy_try_commit_recipe(legacy.coordinator, missing_recipe)
	_expect(
		optimized_result == ProductionCoordinator.RESULT_MISSING_INPUT
		and legacy_result == optimized_result
		and _fixture_storage_matches(optimized, legacy)
		and optimized.warehouses[0].get_storage_item_count(0) == 2
		and optimized.warehouses[0].get_storage_revision() == optimized_revision
		and legacy.warehouses[0].get_storage_revision() == legacy_revision
		and optimized_probe.storage_signal_count == 0
		and optimized_probe.totals_signal_count == 0,
		"缺料前已模拟的局部扣除必须整体丢弃且不发布信号。"
	)

	# A full result after filling one simulated free slot must also roll back.
	_disconnect_probe(optimized, optimized_probe)
	_disconnect_probe(legacy, legacy_probe)
	_set_one_empty_slot_layout(optimized.warehouses[0])
	_set_one_empty_slot_layout(legacy.warehouses[0])
	_fill_other_warehouses(optimized, WATER_COLLECTOR_ITEM)
	_fill_other_warehouses(legacy, WATER_COLLECTOR_ITEM)
	optimized_probe = _attach_probe(optimized)
	legacy_probe = _attach_probe(legacy)
	optimized_revision = optimized.warehouses[0].get_storage_revision()
	legacy_revision = legacy.warehouses[0].get_storage_revision()
	var partial_full_recipe := _make_recipe(
		&"journal_partial_full",
		[WATER_SOURCE],
		[0],
		[WATER_COLLECTOR_ITEM],
		[2]
	)
	optimized_result = optimized.coordinator.try_commit_recipe(partial_full_recipe)
	legacy_result = _legacy_try_commit_recipe(legacy.coordinator, partial_full_recipe)
	_expect(
		optimized_result == ProductionCoordinator.RESULT_STORAGE_FULL
		and legacy_result == optimized_result
		and _fixture_storage_matches(optimized, legacy)
		and optimized.warehouses[0].get_storage_item(0) == null
		and optimized.warehouses[0].get_storage_revision() == optimized_revision
		and legacy.warehouses[0].get_storage_revision() == legacy_revision
		and optimized_probe.storage_signal_count == 0
		and optimized_probe.totals_signal_count == 0,
		"满仓前已模拟的局部写入必须整体丢弃且不发布信号。"
	)

	_disconnect_probe(optimized, optimized_probe)
	_disconnect_probe(legacy, legacy_probe)
	_free_fixture(optimized)
	_free_fixture(legacy)
	await process_frame


func _test_order_cache_lifecycle(test_root: Node) -> void:
	var fixture := _create_fixture_nodes(test_root, "OrderCache", 0)
	var first := _create_warehouse_node(test_root, "OrderFirst")
	var second := _create_warehouse_node(test_root, "OrderSecond")
	var networked := _create_warehouse_node(test_root, "OrderNetworked")
	await process_frame
	_setup_warehouse(first, Vector2(0.0, 20.0), 0)
	_setup_warehouse(second, Vector2(0.0, 0.0), 0)
	_setup_warehouse(networked, Vector2(0.0, -20.0), 8)
	# Deliberately register in the opposite of stable order.
	fixture.coordinator.register_plant(networked)
	fixture.coordinator.register_plant(first)
	fixture.coordinator.register_plant(second)
	fixture.warehouses.assign([first, second, networked])
	var ordered := fixture.coordinator.call(
		"_get_ordered_operational_warehouses"
	) as Array
	_expect(
		ordered == [second, first, networked],
		"首次缓存必须按net_id、Y、X、instance_id稳定排序。"
	)

	var added := _create_warehouse_node(test_root, "OrderAdded")
	await process_frame
	_setup_warehouse(added, Vector2(0.0, -30.0), 0)
	fixture.coordinator.register_plant(added)
	ordered = fixture.coordinator.call("_get_ordered_operational_warehouses") as Array
	_expect(
		ordered == [added, second, first, networked],
		"注册新仓库必须使稳定顺序缓存立即失效。"
	)

	fixture.coordinator.unregister_plant(second)
	ordered = fixture.coordinator.call("_get_ordered_operational_warehouses") as Array
	_expect(
		not ordered.has(second) and ordered == [added, first, networked],
		"注销仓库必须从缓存中移除旧引用。"
	)

	var constructing := _create_warehouse_node(test_root, "OrderConstructing")
	await process_frame
	constructing.global_position = Vector2(0.0, -40.0)
	constructing.setup(
		warehouse_config,
		null,
		[Vector2i(64, 0)],
		false,
		-1,
		0,
		-1,
		true
	)
	fixture.coordinator.register_plant(constructing)
	ordered = fixture.coordinator.call("_get_ordered_operational_warehouses") as Array
	_expect(not ordered.has(constructing), "施工仓库不得进入可用缓存。")
	constructing.call("_stop_construction_tween")
	constructing.call("_finish_construction", true)
	ordered = fixture.coordinator.call("_get_ordered_operational_warehouses") as Array
	_expect(
		ordered.has(constructing) and ordered[0] == constructing,
		"完工信号必须失效缓存并按稳定键插入新仓库。"
	)

	first.begin_removal(PlantDefense.RemovalMode.SILENT)
	ordered = fixture.coordinator.call("_get_ordered_operational_warehouses") as Array
	_expect(not ordered.has(first), "移除开始后缓存不得继续返回失效仓库。")

	fixture.coordinator.unregister_plant(added)
	fixture.coordinator.unregister_plant(networked)
	fixture.coordinator.unregister_plant(constructing)
	for warehouse in [second, added, networked, constructing]:
		if is_instance_valid(warehouse):
			warehouse.queue_free()
	fixture.coordinator.queue_free()
	await process_frame


func _run_transaction_ab(test_root: Node) -> void:
	var optimized := _create_fixture_nodes(test_root, "ABOptimized", WAREHOUSE_COUNT)
	var legacy := _create_fixture_nodes(test_root, "ABLegacy", WAREHOUSE_COUNT)
	await process_frame
	_setup_fixture(optimized)
	_setup_fixture(legacy)
	for scenario in [SCENARIO_MISSING, SCENARIO_FULL, SCENARIO_SUCCESS]:
		var recipe := full_recipe if scenario == SCENARIO_FULL else shared_recipe
		var expected_result := _expected_result_for_scenario(scenario)
		for cohort_size in COHORT_SIZES:
			for _warmup in WARMUP_ROUNDS:
				_prepare_scenario(optimized, scenario, cohort_size)
				_prepare_scenario(legacy, scenario, cohort_size)
				_run_optimized_cohort(optimized, recipe, expected_result, cohort_size)
				_run_legacy_cohort(legacy, recipe, expected_result, cohort_size)
			var optimized_samples: Array[int] = []
			var legacy_samples: Array[int] = []
			for sample_index in SAMPLE_ROUNDS:
				_prepare_scenario(optimized, scenario, cohort_size)
				_prepare_scenario(legacy, scenario, cohort_size)
				if sample_index % 2 == 0:
					optimized_samples.append(
						_measure_optimized_cohort(
							optimized,
							recipe,
							expected_result,
							cohort_size
						)
					)
					legacy_samples.append(
						_measure_legacy_cohort(
							legacy,
							recipe,
							expected_result,
							cohort_size
						)
					)
				else:
					legacy_samples.append(
						_measure_legacy_cohort(
							legacy,
							recipe,
							expected_result,
							cohort_size
						)
					)
					optimized_samples.append(
						_measure_optimized_cohort(
							optimized,
							recipe,
							expected_result,
							cohort_size
						)
					)
				_expect(
					_fixture_storage_matches(optimized, legacy),
					"%s/%d 同帧事务结果必须与旧实现逐槽一致。"
					% [scenario, cohort_size]
				)
			optimized_samples.sort()
			legacy_samples.sort()
			var optimized_p50 := _nearest_rank(optimized_samples, 0.50)
			var optimized_p95 := _nearest_rank(optimized_samples, 0.95)
			var legacy_p50 := _nearest_rank(legacy_samples, 0.50)
			var legacy_p95 := _nearest_rank(legacy_samples, 0.95)
			print(
				(
					"PRODUCTION_TRANSACTION_JOURNAL_AB scenario=%s cohort=%d "
					+ "optimized_p50=%dus optimized_p95=%dus legacy_p50=%dus "
					+ "legacy_p95=%dus speedup_p50=%.2fx speedup_p95=%.2fx"
				)
				% [
					scenario,
					cohort_size,
					optimized_p50,
					optimized_p95,
					legacy_p50,
					legacy_p95,
					float(legacy_p50) / float(maxi(optimized_p50, 1)),
					float(legacy_p95) / float(maxi(optimized_p95, 1)),
				]
			)
			if scenario == SCENARIO_MISSING and cohort_size == 64:
				_expect(
					legacy_p95 >= optimized_p95 * 5,
					"64座首次缺料事务的p95必须至少比完整快照路径快5倍。"
				)
	_free_fixture(optimized)
	_free_fixture(legacy)
	await process_frame


func _create_fixture_nodes(parent: Node, prefix: String, count: int) -> Fixture:
	var fixture := Fixture.new()
	fixture.coordinator = COORDINATOR_SCENE.instantiate() as ProductionCoordinator
	fixture.coordinator.name = prefix + "Coordinator"
	parent.add_child(fixture.coordinator)
	for warehouse_index in count:
		var warehouse := _create_warehouse_node(
			parent,
			prefix + "Warehouse%d" % warehouse_index
		)
		fixture.warehouses.append(warehouse)
	return fixture


func _create_warehouse_node(parent: Node, node_name: String) -> OakWarehouse:
	var warehouse := WAREHOUSE_SCENE.instantiate() as OakWarehouse
	warehouse.name = node_name
	parent.add_child(warehouse)
	return warehouse


func _setup_fixture(fixture: Fixture) -> void:
	fixture.coordinator.production_tick_timer.stop()
	for warehouse_index in fixture.warehouses.size():
		var warehouse := fixture.warehouses[warehouse_index]
		_setup_warehouse(
			warehouse,
			Vector2(float(warehouse_index * 16), 0.0),
			warehouse_index + 1
		)
		fixture.coordinator.register_plant(warehouse)


func _setup_warehouse(
	warehouse: OakWarehouse,
	world_position: Vector2,
	net_id: int
) -> void:
	warehouse.global_position = world_position
	if net_id > 0:
		warehouse.set_meta(&"net_id", net_id)
	warehouse.setup(
		warehouse_config,
		null,
		[Vector2i(roundi(world_position.x / 16.0), roundi(world_position.y / 16.0))]
	)


func _prepare_scenario(fixture: Fixture, scenario: StringName, cohort_size: int) -> void:
	for warehouse_index in fixture.warehouses.size():
		var items: Array[PickupConfig] = []
		var counts: Array[int] = []
		items.resize(OakWarehouse.STORAGE_CAPACITY)
		counts.resize(OakWarehouse.STORAGE_CAPACITY)
		counts.fill(0)
		if scenario == SCENARIO_FULL:
			items.fill(WATER_COLLECTOR_ITEM)
			counts.fill(1)
		elif scenario == SCENARIO_SUCCESS and warehouse_index == 0:
			items[0] = WOOD
			counts[0] = cohort_size
		_expect(
			fixture.warehouses[warehouse_index].apply_production_storage_snapshot(
				items,
				counts,
				fixture.warehouses[warehouse_index].get_storage_revision()
			),
			"A/B场景必须能重置仓库槽位。"
		)


func _run_optimized_cohort(
	fixture: Fixture,
	recipe: ProductionRecipe,
	expected_result: StringName,
	cohort_size: int
) -> void:
	for _building_index in cohort_size:
		_expect(
			fixture.coordinator.try_commit_recipe(recipe) == expected_result,
			"优化事务必须返回预期结果%s。" % expected_result
		)


func _run_legacy_cohort(
	fixture: Fixture,
	recipe: ProductionRecipe,
	expected_result: StringName,
	cohort_size: int
) -> void:
	for _building_index in cohort_size:
		_expect(
			_legacy_try_commit_recipe(fixture.coordinator, recipe) == expected_result,
			"旧快照事务必须返回预期结果%s。" % expected_result
		)


func _measure_optimized_cohort(
	fixture: Fixture,
	recipe: ProductionRecipe,
	expected_result: StringName,
	cohort_size: int
) -> int:
	var started_usec := Time.get_ticks_usec()
	_run_optimized_cohort(fixture, recipe, expected_result, cohort_size)
	return maxi(Time.get_ticks_usec() - started_usec, 1)


func _measure_legacy_cohort(
	fixture: Fixture,
	recipe: ProductionRecipe,
	expected_result: StringName,
	cohort_size: int
) -> int:
	var started_usec := Time.get_ticks_usec()
	_run_legacy_cohort(fixture, recipe, expected_result, cohort_size)
	return maxi(Time.get_ticks_usec() - started_usec, 1)


func _legacy_try_commit_recipe(
	coordinator: ProductionCoordinator,
	recipe: ProductionRecipe
) -> StringName:
	var ordered := _legacy_ordered_warehouses(coordinator.warehouses)
	if ordered.is_empty():
		return ProductionCoordinator.RESULT_MISSING_INPUT
	var states: Array[Dictionary] = []
	for warehouse in ordered:
		states.append(warehouse.export_production_storage_snapshot())
	for input_index in recipe.input_items.size():
		var amount := recipe.input_amounts[input_index]
		if amount > 0 and not _legacy_consume(
			states,
			recipe.input_items[input_index],
			amount
		):
			return ProductionCoordinator.RESULT_MISSING_INPUT
	for output_index in recipe.output_items.size():
		if not _legacy_add(
			states,
			recipe.output_items[output_index],
			recipe.output_amounts[output_index]
		):
			return ProductionCoordinator.RESULT_STORAGE_FULL
	for state in states:
		var warehouse := state["warehouse"] as OakWarehouse
		if warehouse.get_storage_revision() != int(state["revision"]):
			return ProductionCoordinator.RESULT_UNAVAILABLE
	var changed: Array[OakWarehouse] = []
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
			return ProductionCoordinator.RESULT_UNAVAILABLE
		changed.append(warehouse)
	for warehouse in changed:
		warehouse.notify_production_storage_changed()
	return ProductionCoordinator.RESULT_SUCCESS


func _legacy_ordered_warehouses(
	warehouses: Array[OakWarehouse]
) -> Array[OakWarehouse]:
	var ordered: Array[OakWarehouse] = []
	for warehouse in warehouses:
		if (
			warehouse != null
			and is_instance_valid(warehouse)
			and not warehouse.is_queued_for_deletion()
			and not warehouse.is_dead
			and not warehouse.is_removing
			and not warehouse.is_multiplayer_proxy
			and warehouse.is_operational
		):
			ordered.append(warehouse)
	ordered.sort_custom(_warehouse_precedes)
	return ordered


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


func _legacy_consume(states: Array[Dictionary], item: PickupConfig, count: int) -> bool:
	var remaining := count
	for state in states:
		var items := state["items"] as Array
		var counts := state["counts"] as Array
		for slot_index in items.size():
			if remaining <= 0:
				return true
			if not PickupConfig.inventory_identity_matches(items[slot_index], item):
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


func _legacy_add(states: Array[Dictionary], item: PickupConfig, count: int) -> bool:
	var remaining := count
	var stack_limit := PickupConfig.get_inventory_stack_limit(item)
	for state in states:
		var items := state["items"] as Array
		var counts := state["counts"] as Array
		for slot_index in items.size():
			if remaining <= 0:
				return true
			if not PickupConfig.inventory_items_can_stack(items[slot_index], item):
				continue
			var available := stack_limit - int(counts[slot_index])
			if available <= 0:
				continue
			var added := mini(available, remaining)
			counts[slot_index] = int(counts[slot_index]) + added
			remaining -= added
			state["changed"] = true
	for state in states:
		var items := state["items"] as Array
		var counts := state["counts"] as Array
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


func _set_exact_slots(
	warehouse: OakWarehouse,
	items_to_set: Array[PickupConfig],
	counts_to_set: Array[int]
) -> void:
	var items: Array[PickupConfig] = []
	var counts: Array[int] = []
	items.resize(OakWarehouse.STORAGE_CAPACITY)
	counts.resize(OakWarehouse.STORAGE_CAPACITY)
	counts.fill(0)
	for index in items_to_set.size():
		items[index] = items_to_set[index]
		counts[index] = counts_to_set[index]
	_expect(
		warehouse.apply_production_storage_snapshot(
			items,
			counts,
			warehouse.get_storage_revision()
		),
		"语义夹具必须能写入精确槽布局。"
	)


func _set_one_empty_slot_layout(warehouse: OakWarehouse) -> void:
	var items: Array[PickupConfig] = []
	var counts: Array[int] = []
	items.resize(OakWarehouse.STORAGE_CAPACITY)
	counts.resize(OakWarehouse.STORAGE_CAPACITY)
	items.fill(WATER_COLLECTOR_ITEM)
	counts.fill(1)
	items[0] = null
	counts[0] = 0
	_expect(
		warehouse.apply_production_storage_snapshot(
			items,
			counts,
			warehouse.get_storage_revision()
		),
		"满仓回滚夹具必须保留一个空槽。"
	)


func _fill_other_warehouses(fixture: Fixture, item: PickupConfig) -> void:
	for warehouse_index in range(1, fixture.warehouses.size()):
		var items: Array[PickupConfig] = []
		var counts: Array[int] = []
		items.resize(OakWarehouse.STORAGE_CAPACITY)
		counts.resize(OakWarehouse.STORAGE_CAPACITY)
		items.fill(item)
		counts.fill(1)
		fixture.warehouses[warehouse_index].apply_production_storage_snapshot(
			items,
			counts,
			fixture.warehouses[warehouse_index].get_storage_revision()
		)


func _attach_probe(fixture: Fixture) -> SignalProbe:
	var probe := SignalProbe.new()
	for warehouse in fixture.warehouses:
		warehouse.storage_changed.connect(probe.on_storage_changed)
	fixture.coordinator.storage_totals_changed.connect(probe.on_totals_changed)
	return probe


func _disconnect_probe(fixture: Fixture, probe: SignalProbe) -> void:
	for warehouse in fixture.warehouses:
		if warehouse.storage_changed.is_connected(probe.on_storage_changed):
			warehouse.storage_changed.disconnect(probe.on_storage_changed)
	if fixture.coordinator.storage_totals_changed.is_connected(probe.on_totals_changed):
		fixture.coordinator.storage_totals_changed.disconnect(probe.on_totals_changed)


func _fixture_storage_matches(left: Fixture, right: Fixture) -> bool:
	if left.warehouses.size() != right.warehouses.size():
		return false
	for warehouse_index in left.warehouses.size():
		var left_warehouse := left.warehouses[warehouse_index]
		var right_warehouse := right.warehouses[warehouse_index]
		if left_warehouse.get_storage_revision() != right_warehouse.get_storage_revision():
			return false
		for slot_index in OakWarehouse.STORAGE_CAPACITY:
			if not PickupConfig.inventory_identity_matches(
				left_warehouse.get_storage_item(slot_index),
				right_warehouse.get_storage_item(slot_index)
			):
				if (
					left_warehouse.get_storage_item(slot_index) != null
					or right_warehouse.get_storage_item(slot_index) != null
				):
					return false
			if (
				left_warehouse.get_storage_item_count(slot_index)
				!= right_warehouse.get_storage_item_count(slot_index)
			):
				return false
	return true


func _make_recipe(
	recipe_id: StringName,
	inputs: Array[PickupConfig],
	input_counts: Array[int],
	outputs: Array[PickupConfig],
	output_counts: Array[int]
) -> ProductionRecipe:
	var recipe := ProductionRecipe.new()
	recipe.recipe_id = recipe_id
	recipe.display_name = String(recipe_id)
	recipe.input_items = inputs
	recipe.input_amounts = input_counts
	recipe.output_items = outputs
	recipe.output_amounts = output_counts
	recipe.duration_seconds = 1.0
	return recipe


func _expected_result_for_scenario(scenario: StringName) -> StringName:
	match scenario:
		SCENARIO_MISSING:
			return ProductionCoordinator.RESULT_MISSING_INPUT
		SCENARIO_FULL:
			return ProductionCoordinator.RESULT_STORAGE_FULL
		_:
			return ProductionCoordinator.RESULT_SUCCESS


func _nearest_rank(sorted_samples: Array[int], percentile: float) -> int:
	var rank := ceili(clampf(percentile, 0.0, 1.0) * sorted_samples.size())
	return sorted_samples[clampi(rank - 1, 0, sorted_samples.size() - 1)]


func _free_fixture(fixture: Fixture) -> void:
	if fixture == null:
		return
	for warehouse in fixture.warehouses:
		if warehouse != null and is_instance_valid(warehouse):
			fixture.coordinator.unregister_plant(warehouse)
			warehouse.queue_free()
	if fixture.coordinator != null and is_instance_valid(fixture.coordinator):
		fixture.coordinator.queue_free()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish(test_root: Node) -> void:
	if test_root != null and is_instance_valid(test_root):
		test_root.queue_free()
	if failures.is_empty():
		print("PRODUCTION_TRANSACTION_JOURNAL_AB_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)
