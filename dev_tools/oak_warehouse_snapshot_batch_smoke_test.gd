extends SceneTree

const WAREHOUSE_SCENE := preload(
	"res://scene/plant_defense/oak_warehouse.tscn"
)
const WHITE_CRYSTAL := preload(
	"res://resources/config/materials/material_white_crystal.tres"
)
const WHITE_CRYSTAL_POWDER := preload(
	"res://resources/config/materials/material_white_crystal_powder.tres"
)

const FIRST_WAREHOUSE_NET_ID := 7101
const SECOND_WAREHOUSE_NET_ID := 7102
const CLIENT_PEER_ID := 2

var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var fixture := Node2D.new()
	fixture.name = "OakWarehouseSnapshotBatchSmokeTest"
	root.add_child(fixture)

	var first_warehouse := WAREHOUSE_SCENE.instantiate() as OakWarehouse
	var second_warehouse := WAREHOUSE_SCENE.instantiate() as OakWarehouse
	fixture.add_child(first_warehouse)
	fixture.add_child(second_warehouse)
	var config := PlantDefenseRegistry.get_config(&"oak_warehouse")
	first_warehouse.setup(
		config,
		null,
		[Vector2i.ZERO, Vector2i.RIGHT, Vector2i.DOWN, Vector2i.ONE],
		true
	)
	second_warehouse.setup(
		config,
		null,
		[
			Vector2i(3, 0),
			Vector2i(4, 0),
			Vector2i(3, 1),
			Vector2i(4, 1),
		],
		true
	)
	first_warehouse.configure_multiplayer_storage(
		FIRST_WAREHOUSE_NET_ID,
		CLIENT_PEER_ID,
		true
	)
	second_warehouse.configure_multiplayer_storage(
		SECOND_WAREHOUSE_NET_ID,
		CLIENT_PEER_ID,
		true
	)
	await process_frame

	_expect(config != null and config.is_valid(), "测试必须加载真实橡木仓库配置。")
	_expect(
		first_warehouse.try_add_storage_item_count(WHITE_CRYSTAL, 3),
		"测试前置必须能向第一座真实仓库写入3个白色水晶。"
	)
	_test_successful_batch_is_atomically_observable(
		first_warehouse,
		second_warehouse
	)
	_test_invalid_snapshot_aborts_whole_batch(
		first_warehouse,
		second_warehouse
	)
	_test_inventory_and_storage_notifications_are_atomic(
		first_warehouse,
		second_warehouse
	)

	fixture.queue_free()
	for _frame in range(3):
		await process_frame
	if failures.is_empty():
		print("OAK_WAREHOUSE_SNAPSHOT_BATCH_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_successful_batch_is_atomically_observable(
	first_warehouse: OakWarehouse,
	second_warehouse: OakWarehouse
) -> void:
	var first_snapshot := first_warehouse.export_storage_snapshot().duplicate(true)
	first_snapshot["revision"] = first_warehouse.get_storage_revision() + 1
	_set_snapshot_slot(first_snapshot, 0, WHITE_CRYSTAL, 2)
	var second_snapshot := second_warehouse.export_storage_snapshot().duplicate(true)
	second_snapshot["revision"] = second_warehouse.get_storage_revision() + 1
	_set_snapshot_slot(second_snapshot, 0, WHITE_CRYSTAL_POWDER, 1)

	var notifications := {"first": 0, "second": 0}
	var observed_global_totals: Array[Vector2i] = []
	var first_listener := func() -> void:
		notifications["first"] = int(notifications["first"]) + 1
		observed_global_totals.append(
			_get_global_totals(first_warehouse, second_warehouse)
		)
	var second_listener := func() -> void:
		notifications["second"] = int(notifications["second"]) + 1
		observed_global_totals.append(
			_get_global_totals(first_warehouse, second_warehouse)
		)
	first_warehouse.storage_changed.connect(first_listener)
	second_warehouse.storage_changed.connect(second_listener)

	var warehouses: Array[OakWarehouse] = [
		first_warehouse,
		second_warehouse,
	]
	var applied := OakWarehouse.apply_storage_snapshot_batch(
		warehouses,
		[first_snapshot, second_snapshot]
	)
	_expect(applied, "两个合法权威仓库快照必须作为一个批次应用成功。")
	_expect(
		first_warehouse.get_storage_item_total(WHITE_CRYSTAL) == 2
		and second_warehouse.get_storage_item_total(WHITE_CRYSTAL_POWDER) == 1,
		"成功批次必须在第一仓扣除1个白晶，并在第二仓写入1个白晶粉。"
	)
	_expect(
		int(notifications["first"]) == 1
		and int(notifications["second"]) == 1,
		"成功批次必须让每座发生提交的仓库恰好发出一次storage_changed。"
	)
	var all_observations_are_final := observed_global_totals.size() == 2
	for totals in observed_global_totals:
		all_observations_are_final = (
			all_observations_are_final and totals == Vector2i(2, 1)
		)
	_expect(
		all_observations_are_final,
		"任一仓库监听器读取全局两仓总量时都只能观察到批次最终状态。"
	)

	first_warehouse.storage_changed.disconnect(first_listener)
	second_warehouse.storage_changed.disconnect(second_listener)


func _test_invalid_snapshot_aborts_whole_batch(
	first_warehouse: OakWarehouse,
	second_warehouse: OakWarehouse
) -> void:
	var first_before := first_warehouse.export_storage_snapshot().duplicate(true)
	var second_before := second_warehouse.export_storage_snapshot().duplicate(true)
	var valid_first_snapshot := first_before.duplicate(true)
	valid_first_snapshot["revision"] = first_warehouse.get_storage_revision() + 1
	_set_snapshot_slot(valid_first_snapshot, 0, WHITE_CRYSTAL, 1)
	var invalid_second_snapshot := second_before.duplicate(true)
	invalid_second_snapshot["revision"] = (
		second_warehouse.get_storage_revision() + 1
	)
	var invalid_slots := invalid_second_snapshot["slots"] as Array
	invalid_slots.pop_back()

	var notifications := {"first": 0, "second": 0}
	var observed_global_totals: Array[Vector2i] = []
	var first_listener := func() -> void:
		notifications["first"] = int(notifications["first"]) + 1
		observed_global_totals.append(
			_get_global_totals(first_warehouse, second_warehouse)
		)
	var second_listener := func() -> void:
		notifications["second"] = int(notifications["second"]) + 1
		observed_global_totals.append(
			_get_global_totals(first_warehouse, second_warehouse)
		)
	first_warehouse.storage_changed.connect(first_listener)
	second_warehouse.storage_changed.connect(second_listener)

	var warehouses: Array[OakWarehouse] = [
		first_warehouse,
		second_warehouse,
	]
	var applied := OakWarehouse.apply_storage_snapshot_batch(
		warehouses,
		[valid_first_snapshot, invalid_second_snapshot]
	)
	_expect(not applied, "批次内任一仓库快照非法时必须拒绝整个批次。")
	_expect(
		first_warehouse.export_storage_snapshot() == first_before
		and second_warehouse.export_storage_snapshot() == second_before,
		"后置仓库快照非法时，前置合法快照也不得产生任何写入或revision变化。"
	)
	_expect(
		int(notifications["first"]) == 0
		and int(notifications["second"]) == 0
		and observed_global_totals.is_empty(),
		"失败批次必须零通知，任何storage_changed监听器都不得被触发。"
	)

	first_warehouse.storage_changed.disconnect(first_listener)
	second_warehouse.storage_changed.disconnect(second_listener)


func _test_inventory_and_storage_notifications_are_atomic(
	first_warehouse: OakWarehouse,
	second_warehouse: OakWarehouse
) -> void:
	var run_state := RunStateStore.new()
	run_state.begin_new_run(&"weishidaier", false)
	run_state.ensure_multiplayer_peer_state(CLIENT_PEER_ID)
	_expect(
		run_state.try_add_item_for_peer(CLIENT_PEER_ID, WHITE_CRYSTAL),
		"背包—仓库原子通知夹具必须准备1个Peer白色水晶。"
	)
	var inventory_snapshot := (
		run_state.export_inventory_snapshot_for_peer(CLIENT_PEER_ID)
	).duplicate(true)
	inventory_snapshot["revision"] = int(inventory_snapshot["revision"]) + 1
	for raw_slot_value in inventory_snapshot.get("slots", []) as Array:
		var raw_slot := raw_slot_value as Dictionary
		if str(raw_slot.get("config_path", "")) != WHITE_CRYSTAL.resource_path:
			continue
		raw_slot["config_path"] = ""
		raw_slot["stack_count"] = 0
		break
	var storage_snapshot := first_warehouse.export_storage_snapshot().duplicate(true)
	storage_snapshot["revision"] = int(storage_snapshot["revision"]) + 1
	for raw_slot_value in storage_snapshot.get("slots", []) as Array:
		var raw_slot := raw_slot_value as Dictionary
		if str(raw_slot.get("config_path", "")) != WHITE_CRYSTAL.resource_path:
			continue
		raw_slot["stack_count"] = int(raw_slot["stack_count"]) + 1
		break
	var prepared_inventory := run_state.prepare_inventory_snapshot_for_peer(
		CLIENT_PEER_ID,
		inventory_snapshot
	)
	var prepared_storage := first_warehouse.prepare_storage_snapshot(
		storage_snapshot
	)
	var observations: Array[Vector2i] = []
	var record_combined_state := func() -> void:
		observations.append(Vector2i(
			run_state.get_inventory_item_total_for_peer(
				CLIENT_PEER_ID,
				WHITE_CRYSTAL
			),
			first_warehouse.get_storage_item_total(WHITE_CRYSTAL)
			+ second_warehouse.get_storage_item_total(WHITE_CRYSTAL)
		))
	run_state.inventory_changed.connect(record_combined_state)
	first_warehouse.storage_changed.connect(record_combined_state)
	var storage_committed := first_warehouse.commit_prepared_storage_snapshot(
		prepared_storage,
		false
	)
	var inventory_committed := run_state.commit_prepared_inventory_snapshot_for_peer(
		prepared_inventory,
		false
	)
	if storage_committed and inventory_committed:
		run_state.notify_inventory_snapshot_committed()
		first_warehouse.notify_storage_snapshot_committed()
	_expect(
		storage_committed
		and inventory_committed
		and observations == [Vector2i(0, 3), Vector2i(0, 3)],
		"背包与仓库必须先静默完成双方提交，再让任一监听器观察最终组合。"
	)
	run_state.free()


func _set_snapshot_slot(
	snapshot: Dictionary,
	slot_index: int,
	item: PickupConfig,
	stack_count: int
) -> void:
	var slots := snapshot["slots"] as Array
	slots[slot_index] = {
		"slot_index": slot_index,
		"config_path": item.resource_path,
		"stack_count": stack_count,
	}


func _get_global_totals(
	first_warehouse: OakWarehouse,
	second_warehouse: OakWarehouse
) -> Vector2i:
	return Vector2i(
		first_warehouse.get_storage_item_total(WHITE_CRYSTAL)
		+ second_warehouse.get_storage_item_total(WHITE_CRYSTAL),
		first_warehouse.get_storage_item_total(WHITE_CRYSTAL_POWDER)
		+ second_warehouse.get_storage_item_total(WHITE_CRYSTAL_POWDER)
	)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
