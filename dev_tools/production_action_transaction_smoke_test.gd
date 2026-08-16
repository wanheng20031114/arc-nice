extends SceneTree

const COORDINATOR_SCENE := preload(
	"res://scene/game_modes/tower_defense/economy/production/production_coordinator.tscn"
)
const WAREHOUSE_SCENE := preload("res://scene/plant_defense/oak_warehouse.tscn")
const BUILDING_ITEM: PickupConfig = preload(
	"res://resources/config/buildings/building_water_collector.tres"
)


class ActionProbe:
	extends RefCounted

	var call_count := 0
	var accepted := false

	func invoke() -> bool:
		call_count += 1
		return accepted


class SignalProbe:
	extends RefCounted

	var storage_count := 0
	var totals_count := 0

	func on_storage_changed() -> void:
		storage_count += 1

	func on_totals_changed() -> void:
		totals_count += 1


var failures: PackedStringArray = []


func _initialize() -> void:
	call_deferred(&"_run")


func _run() -> void:
	var test_root := Node.new()
	test_root.name = "ProductionActionTransactionSmokeTest"
	root.add_child(test_root)
	var coordinator := COORDINATOR_SCENE.instantiate() as ProductionCoordinator
	var warehouse := WAREHOUSE_SCENE.instantiate() as OakWarehouse
	test_root.add_child(coordinator)
	test_root.add_child(warehouse)
	await process_frame
	coordinator.production_tick_timer.stop()
	var warehouse_config := PlantDefenseRegistry.get_config(&"oak_warehouse")
	_expect(warehouse_config != null, "事务夹具必须能读取橡木仓库配置。")
	if warehouse_config == null:
		_finish(test_root)
		return
	warehouse.set_meta(&"net_id", 1)
	warehouse.setup(warehouse_config, null, [Vector2i.ZERO])
	coordinator.register_plant(warehouse)
	_expect(
		warehouse.try_add_storage_item_count(BUILDING_ITEM, 2),
		"事务夹具必须能在共享仓库放入两个建筑物品。"
	)

	var probe := SignalProbe.new()
	warehouse.storage_changed.connect(probe.on_storage_changed)
	coordinator.storage_totals_changed.connect(probe.on_totals_changed)
	var initial_revision := warehouse.get_storage_revision()
	var failed_action := ActionProbe.new()
	var result := coordinator.try_consume_item_requirements_with_action(
		[{"item": BUILDING_ITEM, "count": 1}],
		failed_action.invoke
	)
	_expect(
		result == ProductionCoordinator.RESULT_ACTION_FAILED
		and failed_action.call_count == 1
		and warehouse.get_storage_item_total(BUILDING_ITEM) == 2
		and warehouse.get_storage_revision() == initial_revision
		and probe.storage_count == 0
		and probe.totals_count == 0,
		"动作失败必须静默回滚建筑物品、revision 与全部仓库通知。"
	)

	var accepted_action := ActionProbe.new()
	accepted_action.accepted = true
	result = coordinator.try_consume_item_requirements_with_action(
		[{"item": BUILDING_ITEM, "count": 1}],
		accepted_action.invoke
	)
	_expect(
		result == ProductionCoordinator.RESULT_SUCCESS
		and accepted_action.call_count == 1
		and warehouse.get_storage_item_total(BUILDING_ITEM) == 1
		and warehouse.get_storage_revision() == initial_revision + 1
		and probe.storage_count == 1
		and probe.totals_count == 1,
		"动作成功必须只发布一次建筑扣料事务。"
	)
	_finish(test_root)


func _finish(test_root: Node) -> void:
	if test_root != null:
		test_root.queue_free()
		await process_frame
	if failures.is_empty():
		print("PRODUCTION_ACTION_TRANSACTION_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
