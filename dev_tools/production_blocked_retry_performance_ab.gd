extends SceneTree

const COORDINATOR_SCENE := preload(
	"res://scene/game_modes/tower_defense/economy/production/production_coordinator.tscn"
)
const WAREHOUSE_SCENE := preload("res://scene/plant_defense/oak_warehouse.tscn")
const WOOD := preload("res://resources/config/materials/material_wood.tres")
const PLANK := preload("res://resources/config/materials/material_plank.tres")
const WATER_BOTTLE := preload(
	"res://resources/config/materials/material_water_bottle.tres"
)
const WATER_SOURCE := preload(
	"res://resources/config/production/water_source.tres"
)
const WATER_COLLECTOR_ITEM := preload(
	"res://resources/config/buildings/building_water_collector.tres"
)
const APPLE := preload(
	"res://resources/config/collectibles/collectible_apple.tres"
)

const WAREHOUSE_COUNT := 32
const BENCHMARK_ITERATIONS := 500

var failures: PackedStringArray = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var test_root := Node.new()
	test_root.name = "ProductionBlockedRetryPerformanceAB"
	root.add_child(test_root)
	var run_state := root.get_node("RunState") as RunStateStore
	run_state.begin_new_run(&"weishidaier", false)

	var coordinator := COORDINATOR_SCENE.instantiate() as ProductionCoordinator
	var station_config := PlantDefenseRegistry.get_config(&"wood_processing_station")
	var warehouse_config := PlantDefenseRegistry.get_config(&"oak_warehouse")
	var station := (
		station_config.plant_scene.instantiate() as ProductionBuilding
		if station_config != null
		else null
	)
	var second_station := (
		station_config.plant_scene.instantiate() as ProductionBuilding
		if station_config != null
		else null
	)
	test_root.add_child(coordinator)
	if station != null:
		test_root.add_child(station)
	if second_station != null:
		test_root.add_child(second_station)
	var warehouses: Array[OakWarehouse] = []
	for index in WAREHOUSE_COUNT:
		var warehouse := WAREHOUSE_SCENE.instantiate() as OakWarehouse
		warehouses.append(warehouse)
		test_root.add_child(warehouse)
	var construction_warehouse := WAREHOUSE_SCENE.instantiate() as OakWarehouse
	test_root.add_child(construction_warehouse)
	await process_frame
	coordinator.production_tick_timer.stop()

	_expect(
		station != null and second_station != null,
		"A/B夹具必须能实例化两座木头加工站。"
	)
	_expect(warehouse_config != null, "A/B夹具必须能加载橡木仓库配置。")
	if (
		station == null
		or second_station == null
		or station_config == null
		or warehouse_config == null
	):
		_finish(test_root)
		return
	station.setup(station_config, null, [Vector2i.ZERO])
	station.set_production_loop_enabled(true)
	coordinator.register_plant(station)
	second_station.setup(station_config, null, [Vector2i(0, 1)])
	second_station.set_production_loop_enabled(true)
	coordinator.register_plant(second_station)
	for index in warehouses.size():
		warehouses[index].setup(
			warehouse_config,
			null,
			[Vector2i(index + 1, 0)]
		)
		coordinator.register_plant(warehouses[index])

	var primary_warehouse := warehouses[0]
	_test_tick_retry_ab(coordinator, station, primary_warehouse)
	# The broad cohort exists only to amplify the retired snapshot path. Capacity
	# semantics below intentionally use one warehouse so "full" is unambiguous.
	for index in range(1, warehouses.size()):
		coordinator.unregister_plant(warehouses[index])
		warehouses[index].queue_free()
	_test_warehouse_capacity_wakeup(coordinator, station, primary_warehouse)
	_test_inventory_capacity_wakeup(
		coordinator,
		station,
		primary_warehouse,
		run_state
	)
	_test_same_frame_production_cascade(
		coordinator,
		station,
		second_station,
		primary_warehouse
	)
	_test_authority_resume_wakeup(coordinator, station, primary_warehouse)
	_test_warehouse_construction_wakeup(
		coordinator,
		station,
		primary_warehouse,
		construction_warehouse,
		warehouse_config
	)
	_finish(test_root)


func _test_tick_retry_ab(
	coordinator: ProductionCoordinator,
	station: ProductionBuilding,
	warehouse: OakWarehouse
) -> void:
	_expect(station.select_recipe(&"wood_to_plank"), "A/B测试必须能选择木材锯切。")
	station.advance_shared_production_tick(10.0)
	_expect(
		station.completion_wait_reason == ProductionCoordinator.RESULT_MISSING_INPUT
		and is_equal_approx(station.get_progress_ratio(), 1.0)
		and _count_valid_waiters(coordinator, &"_warehouse_waiting_buildings") == 1,
		"缺料周期必须只登记一次仓库状态唤醒。"
	)

	var optimized_started_usec := Time.get_ticks_usec()
	for _iteration in BENCHMARK_ITERATIONS:
		station.advance_shared_production_tick(1.0)
	var optimized_usec := maxi(
		Time.get_ticks_usec() - optimized_started_usec,
		1
	)

	# Calling the coordinator transaction reproduces the retired once-per-second
	# work without mutating the new wait table: every call exports all warehouse
	# snapshots and simulates the full recipe.
	var active_recipe := station.get_active_recipe()
	var legacy_started_usec := Time.get_ticks_usec()
	for _iteration in BENCHMARK_ITERATIONS:
		coordinator.try_commit_recipe(active_recipe)
	var legacy_usec := maxi(Time.get_ticks_usec() - legacy_started_usec, 1)
	var speedup := float(legacy_usec) / float(optimized_usec)
	print(
		"PRODUCTION_BLOCKED_RETRY_AB optimized=%dus legacy=%dus speedup=%.2fx"
		% [optimized_usec, legacy_usec, speedup]
	)
	_expect(
		legacy_usec >= optimized_usec * 5,
		(
			"事件等待路径至少应比完整事务空转快5倍，"
			+ "实测optimized=%dus legacy=%dus。" % [optimized_usec, legacy_usec]
		)
	)
	_expect(
		_count_valid_waiters(coordinator, &"_warehouse_waiting_buildings") == 1,
		"重复尝试不得扩张等待表或累积墓碑。"
	)

	_expect(warehouse.try_add_storage_item_count(WOOD, 1), "必须能补入唤醒原料。")
	_expect(
		coordinator.get_total_item_count(WOOD) == 0
		and coordinator.get_total_item_count(PLANK) == 2
		and is_zero_approx(station.progress_elapsed_seconds)
		and station.completion_wait_reason == &""
		and _count_valid_waiters(
			coordinator,
			&"_warehouse_waiting_buildings"
		) == 0,
		"仓库原料变化必须在同帧完成等待周期并撤销登记。"
	)


func _test_warehouse_capacity_wakeup(
	coordinator: ProductionCoordinator,
	station: ProductionBuilding,
	warehouse: OakWarehouse
) -> void:
	_clear_warehouse(warehouse)
	_expect(
		warehouse.try_add_storage_item_count(
			APPLE,
			OakWarehouse.STORAGE_CAPACITY
		),
		"仓库满容量夹具必须能放入20个不可堆叠苹果。"
	)
	var environment_recipe := ProductionRecipe.new()
	environment_recipe.recipe_id = &"blocked_retry_environment_output"
	environment_recipe.display_name = "阻塞唤醒夹具"
	environment_recipe.input_items = [WATER_SOURCE]
	environment_recipe.input_amounts = [0]
	environment_recipe.output_items = [WATER_BOTTLE]
	environment_recipe.output_amounts = [1]
	environment_recipe.duration_seconds = 1.0
	station.recipes.append(environment_recipe)
	_expect(
		station.select_recipe(environment_recipe.recipe_id),
		"必须能选择环境来源测试配方。"
	)
	station.advance_shared_production_tick(1.0)
	_expect(
		station.completion_wait_reason == ProductionCoordinator.RESULT_STORAGE_FULL
		and _count_valid_waiters(
			coordinator,
			&"_warehouse_waiting_buildings"
		) == 1
		and _count_valid_waiters(
			coordinator,
			&"_inventory_waiting_buildings"
		) == 0,
		"共享仓库满时只能登记仓库容量唤醒。"
	)
	_expect(warehouse.discard_storage_item(0), "必须能释放一个仓库槽位。")
	_expect(
		coordinator.get_total_item_count(WATER_BOTTLE) == 1
		and is_zero_approx(station.progress_elapsed_seconds)
		and station.completion_wait_reason == &""
		and _count_valid_waiters(
			coordinator,
			&"_warehouse_waiting_buildings"
		) == 0,
		"释放仓库容量必须同帧唤醒环境产出且不得等待下一个Tick。"
	)


func _test_inventory_capacity_wakeup(
	coordinator: ProductionCoordinator,
	station: ProductionBuilding,
	warehouse: OakWarehouse,
	run_state: RunStateStore
) -> void:
	_clear_warehouse(warehouse)
	_expect(
		run_state.register_multiplayer_peer_state(2),
		"个人背包唤醒夹具必须先注册无关Peer。"
	)
	_expect(
		warehouse.try_add_storage_item_count(PLANK, 10),
		"个人背包阻塞夹具必须能准备10份木板。"
	)
	var inventory_filled := true
	for _slot_index in RunStateStore.INVENTORY_CAPACITY:
		inventory_filled = (
			run_state.try_add_item(APPLE)
			and inventory_filled
		)
	_expect(inventory_filled, "个人背包夹具必须能用苹果填满20个不可堆叠槽位。")
	var inventory_output_recipe := ProductionRecipe.new()
	inventory_output_recipe.recipe_id = &"blocked_retry_inventory_output"
	inventory_output_recipe.display_name = "个人背包产物阻塞夹具"
	inventory_output_recipe.input_items = [PLANK]
	inventory_output_recipe.input_amounts = [10]
	inventory_output_recipe.output_items = [WATER_COLLECTOR_ITEM]
	inventory_output_recipe.output_amounts = [1]
	inventory_output_recipe.output_destination = (
		ProductionRecipe.OutputDestination.PLAYER_INVENTORY
	)
	inventory_output_recipe.duration_seconds = 30.0
	station.recipes.append(inventory_output_recipe)
	_expect(
		station.select_recipe(inventory_output_recipe.recipe_id),
		"必须能选择进入个人背包的阻塞唤醒夹具配方。"
	)
	station.advance_shared_production_tick(30.0)
	_expect(
		station.completion_wait_reason == ProductionCoordinator.RESULT_STORAGE_FULL
		and coordinator.get_total_item_count(PLANK) == 10
		and _count_valid_waiters(
			coordinator,
			&"_inventory_waiting_buildings"
		) == 1
		and _count_valid_waiters(
			coordinator,
			&"_warehouse_waiting_buildings"
		) == 0,
		"个人背包满时只能登记背包revision唤醒，且不得提前扣料。"
	)

	var local_revision_before_peer_change := run_state.get_inventory_revision()
	_expect(
		run_state.try_add_item_for_peer(2, WOOD),
		"必须能制造无关Peer背包变更。"
	)
	_expect(
		run_state.get_inventory_revision() == local_revision_before_peer_change
		and coordinator.get_total_item_count(PLANK) == 10
		and station.completion_wait_reason
		== ProductionCoordinator.RESULT_STORAGE_FULL
		and _count_valid_waiters(
			coordinator,
			&"_inventory_waiting_buildings"
		) == 1,
		"全局背包信号中无关Peer的revision不得触发完整生产事务。"
	)

	var revision_before_discard := run_state.get_inventory_revision()
	_expect(run_state.discard_item(0), "必须能释放本地个人背包槽位。")
	_expect(
		coordinator.get_total_item_count(PLANK) == 0
		and run_state.get_inventory_revision() == revision_before_discard + 2
		and run_state.get_inventory_item_total(WATER_COLLECTOR_ITEM) == 1
		and is_zero_approx(station.progress_elapsed_seconds)
		and station.completion_wait_reason == &""
		and _count_valid_waiters(
			coordinator,
			&"_inventory_waiting_buildings"
		) == 0,
		"对应背包revision变化必须同帧原子扣料、补回产物并撤销等待。"
	)


func _test_same_frame_production_cascade(
	coordinator: ProductionCoordinator,
	consumer: ProductionBuilding,
	producer: ProductionBuilding,
	warehouse: OakWarehouse
) -> void:
	_clear_warehouse(warehouse)
	var consume_plank_recipe := ProductionRecipe.new()
	consume_plank_recipe.recipe_id = &"blocked_retry_cascade_consumer"
	consume_plank_recipe.display_name = "同帧级联夹具"
	consume_plank_recipe.input_items = [PLANK]
	consume_plank_recipe.input_amounts = [1]
	consume_plank_recipe.output_items = [WATER_BOTTLE]
	consume_plank_recipe.output_amounts = [1]
	consume_plank_recipe.duration_seconds = 1.0
	consumer.recipes.append(consume_plank_recipe)
	_expect(
		consumer.select_recipe(consume_plank_recipe.recipe_id)
		and producer.select_recipe(&"wood_to_plank"),
		"级联夹具必须能选择消费者与生产者配方。"
	)
	# Register the consumer first. On the external wood event it fails before
	# the later producer creates plank, forcing the coordinator to drain a
	# second state-change pass rather than relying on a future one-second tick.
	consumer.advance_shared_production_tick(1.0)
	producer.advance_shared_production_tick(10.0)
	_expect(
		_count_valid_waiters(
			coordinator,
			&"_warehouse_waiting_buildings"
		) == 2,
		"级联前两座建筑都必须停在缺料等待表。"
	)
	_expect(warehouse.try_add_storage_item_count(WOOD, 1), "必须能触发级联木材事件。")
	_expect(
		coordinator.get_total_item_count(WOOD) == 0
		and coordinator.get_total_item_count(PLANK) == 1
		and coordinator.get_total_item_count(WATER_BOTTLE) == 1
		and is_zero_approx(consumer.progress_elapsed_seconds)
		and is_zero_approx(producer.progress_elapsed_seconds)
		and _count_valid_waiters(
			coordinator,
			&"_warehouse_waiting_buildings"
		) == 0,
		"后序建筑产出的原料必须在同一事件中再次唤醒前序消费者。"
	)


func _test_authority_resume_wakeup(
	coordinator: ProductionCoordinator,
	station: ProductionBuilding,
	warehouse: OakWarehouse
) -> void:
	_clear_warehouse(warehouse)
	_expect(
		station.select_recipe(&"wood_to_plank"),
		"权威恢复夹具必须能选择木材锯切。"
	)
	station.advance_shared_production_tick(10.0)
	coordinator.set_authoritative_processing_enabled(false)
	_expect(
		warehouse.try_add_storage_item_count(WOOD, 1),
		"非权威阶段必须仍能准备恢复用原料。"
	)
	_expect(
		coordinator.get_total_item_count(WOOD) == 1
		and station.completion_wait_reason
		== ProductionCoordinator.RESULT_MISSING_INPUT
		and _count_valid_waiters(
			coordinator,
			&"_warehouse_waiting_buildings"
		) == 1,
		"非权威阶段不得执行生产，但必须保留等待登记。"
	)
	coordinator.set_authoritative_processing_enabled(true)
	coordinator.production_tick_timer.stop()
	_expect(
		coordinator.get_total_item_count(WOOD) == 0
		and coordinator.get_total_item_count(PLANK) == 2
		and is_zero_approx(station.progress_elapsed_seconds)
		and station.completion_wait_reason == &""
		and _count_valid_waiters(
			coordinator,
			&"_warehouse_waiting_buildings"
		) == 0,
		"恢复权威处理必须立即重放等待状态，不能依赖下一次外部变更。"
	)


func _test_warehouse_construction_wakeup(
	coordinator: ProductionCoordinator,
	station: ProductionBuilding,
	full_warehouse: OakWarehouse,
	construction_warehouse: OakWarehouse,
	warehouse_config: PlantDefenseConfig
) -> void:
	_clear_warehouse(full_warehouse)
	_expect(
		full_warehouse.try_add_storage_item_count(
			APPLE,
			OakWarehouse.STORAGE_CAPACITY
		),
		"施工唤醒夹具必须先填满既有仓库。"
	)
	construction_warehouse.setup(
		warehouse_config,
		null,
		[Vector2i(64, 0)],
		false,
		-1,
		0,
		-1,
		true
	)
	_expect(
		not construction_warehouse.is_operational,
		"带放置效果的新仓库在施工完成前不得提供容量。"
	)
	_expect(
		station.select_recipe(&"blocked_retry_environment_output"),
		"施工唤醒夹具必须能复用环境产出配方。"
	)
	station.advance_shared_production_tick(1.0)
	coordinator.register_plant(construction_warehouse)
	_expect(
		station.completion_wait_reason == ProductionCoordinator.RESULT_STORAGE_FULL
		and _count_valid_waiters(
			coordinator,
			&"_warehouse_waiting_buildings"
		) == 1,
		"未完工仓库注册后不得提前解除共享容量阻塞。"
	)
	construction_warehouse.call("_stop_construction_tween")
	construction_warehouse.call("_finish_construction", true)
	_expect(
		construction_warehouse.is_operational
		and construction_warehouse.get_storage_item_total(WATER_BOTTLE) == 1
		and is_zero_approx(station.progress_elapsed_seconds)
		and station.completion_wait_reason == &""
		and _count_valid_waiters(
			coordinator,
			&"_warehouse_waiting_buildings"
		) == 0,
		"空仓完工虽无storage_changed，也必须立即提供容量并唤醒生产。"
	)
	coordinator.unregister_plant(construction_warehouse)


func _clear_warehouse(warehouse: OakWarehouse) -> void:
	for slot_index in OakWarehouse.STORAGE_CAPACITY:
		if warehouse.get_storage_item(slot_index) != null:
			warehouse.discard_storage_item(slot_index)


func _count_valid_waiters(
	coordinator: ProductionCoordinator,
	property_name: StringName
) -> int:
	var waiting_buildings := coordinator.get(property_name) as Array
	var count := 0
	for building in waiting_buildings:
		if building != null and is_instance_valid(building):
			count += 1
	return count


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish(test_root: Node) -> void:
	if failures.is_empty():
		print("PRODUCTION_BLOCKED_RETRY_PERFORMANCE_AB_OK")
		test_root.queue_free()
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	test_root.queue_free()
	quit(1)
