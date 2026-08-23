extends SceneTree

const WAREHOUSE_SCRIPT := preload(
	"res://scene/plant_defense/oak_warehouse.gd"
)
const BRIDGE := preload(
	"res://scene/game_modes/tower_defense/economy/warehouse/shared_warehouse_ledger_bridge.gd"
)
const PLANK := preload("res://resources/config/materials/material_plank.tres")
const BASKETBALL := preload(
	"res://resources/config/collectibles/collectible_basketball.tres"
)
const WAREHOUSE_NET_ID := 7301
const RUN_STATE_SOURCE_PATH := "res://run_state.gd"
const BRIDGE_SOURCE_PATH := (
	"res://scene/game_modes/tower_defense/economy/warehouse/"
	+ "shared_warehouse_ledger_bridge.gd"
)
const PERFORMANCE_ITERATIONS := 1000
const PERFORMANCE_BUDGET_MSEC := 250.0

var _failures: PackedStringArray = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var run_state := root.get_node("RunState") as RunStateStore
	run_state.begin_new_run(&"weishidaier", false)
	run_state.register_multiplayer_peer_state(1)
	var fixture := Node2D.new()
	fixture.name = "SharedWarehouseLedgerBridgeSmokeTest"
	root.add_child(fixture)

	var battle_warehouse := _make_warehouse()
	_expect(
		BRIDGE.bind_identity(
			battle_warehouse,
			WAREHOUSE_NET_ID
		),
		"真实仓库实体应能绑定跨场景稳定ID。"
	)
	_expect(
		battle_warehouse.try_add_storage_item_count(PLANK, 10),
		"战斗仓库应能存入10块木板。"
	)
	_expect(
		BRIDGE.persist_to_ledger(
			run_state,
			battle_warehouse,
			WAREHOUSE_NET_ID
		),
		"离开战斗前应能把真实仓库捕获到RunState账本。"
	)

	var economy := RogueEncounterEconomyCoordinator.new()
	economy.configure(run_state)
	var purchase := economy.resolve_chicken_bro(
		RogueEncounterEconomyCoordinator.OPTION_PURCHASE,
		730173,
		[1],
		"warehouse-roundtrip"
	)
	_expect(
		bool(purchase.get("reward_granted", false))
		and int(purchase.get("warehouse_paid", -1)) == 10
		and run_state.get_shared_warehouse_item_total(PLANK) == 0
		and run_state.get_party_item_total(BASKETBALL, PackedInt32Array([1])) == 1,
		"路线遭遇应从持久仓库扣除10块木板并只发一个篮球。"
	)

	var returned_warehouse := _make_warehouse()
	_expect(
		BRIDGE.restore_from_ledger(
			run_state,
			returned_warehouse,
			WAREHOUSE_NET_ID
		),
		"返回战斗时同ID真实仓库应恢复路线扣款后的快照。"
	)
	_expect(
		returned_warehouse.get_storage_item_total(PLANK) == 0
		and returned_warehouse.get_storage_revision() == 2,
		"返回战斗的仓库必须看到0块木板与扣款后的revision。"
	)
	_expect(
		returned_warehouse.try_add_storage_item_count(PLANK, 3)
		and BRIDGE.persist_to_ledger(
			run_state,
			returned_warehouse,
			WAREHOUSE_NET_ID
		),
		"返回战斗后的仓库变更应继续写回同一账本记录。"
	)
	var second_return := _make_warehouse()
	_expect(
		BRIDGE.restore_from_ledger(
			run_state,
			second_return,
			WAREHOUSE_NET_ID
		)
		and second_return.get_storage_item_total(PLANK) == 3,
		"重复跨场景往返不得丢失返回战斗后的仓库变更。"
	)
	_test_incremental_ledger_semantics()
	_test_single_warehouse_persist_scaling()
	_assert_incremental_source_contract()

	economy.free()
	battle_warehouse.free()
	returned_warehouse.free()
	second_return.free()
	fixture.queue_free()
	for _frame in 3:
		await process_frame
	run_state.begin_new_run(&"weishidaier", false)
	if _failures.is_empty():
		print("SHARED_WAREHOUSE_LEDGER_BRIDGE_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in _failures:
		push_error(failure)
	quit(1)


func _test_incremental_ledger_semantics() -> void:
	var store := RunStateStore.new()
	store.begin_new_run(&"weishidaier", false)
	var full_events: Array[Dictionary] = []
	var delta_events: Array[Dictionary] = []
	store.shared_warehouse_ledger_changed.connect(
		func(snapshot: Dictionary) -> void:
			full_events.append(snapshot.duplicate(true))
	)
	store.shared_warehouse_snapshot_changed.connect(
		func(
			warehouse_net_id: int,
			snapshot: Dictionary,
			removed: bool,
			ledger_revision: int
		) -> void:
			delta_events.append({
				"warehouse_net_id": warehouse_net_id,
				"snapshot": snapshot,
				"removed": removed,
				"ledger_revision": ledger_revision,
			})
	)
	var first := _make_empty_warehouse_snapshot(8101)
	var second := _make_empty_warehouse_snapshot(8102)
	_expect(
		store.replace_shared_warehouse_snapshots([first, second], 0),
		"批量初始化必须原子提交两个仓库。"
	)
	_expect(
		store.get_shared_warehouse_ledger_revision() == 1
		and full_events.size() == 1
		and delta_events.is_empty()
		and (full_events[0].get("warehouses", []) as Array).size() == 2,
		"显式批量 replace 必须只发布完整账本信号。"
	)

	var updated_first := first.duplicate(true)
	updated_first["revision"] = 1
	var updated_slots := updated_first["slots"] as Array
	updated_slots[0] = {
		"slot_index": 0,
		"config_path": PLANK.resource_path,
		"stack_count": 5,
	}
	_expect(
		store.upsert_shared_warehouse_snapshot(updated_first, 1),
		"单仓 upsert 必须接受当前账本 revision 的合法快照。"
	)
	var first_delta := delta_events[0] if not delta_events.is_empty() else {}
	_expect(
		store.get_shared_warehouse_ledger_revision() == 2
		and full_events.size() == 1
		and delta_events.size() == 1
		and int(first_delta.get("warehouse_net_id", 0)) == 8101
		and not bool(first_delta.get("removed", true))
		and int(first_delta.get("ledger_revision", 0)) == 2,
		"单仓 upsert 必须只发布一次携带提交后 revision 的 delta。"
	)
	var exposed_delta_snapshot := first_delta.get("snapshot", {}) as Dictionary
	var exposed_delta_slots := exposed_delta_snapshot.get("slots", []) as Array
	(exposed_delta_slots[0] as Dictionary)["stack_count"] = 999
	_expect(
		int(
			(
				(store.get_shared_warehouse_snapshot(8101)["slots"] as Array)[0]
				as Dictionary
			).get("stack_count", 0)
		) == 5,
		"delta 信号必须发布防御性副本，订阅者不得改写 RunState。"
	)

	var baseline_after_upsert := store.export_shared_warehouse_ledger()
	var stale_update := updated_first.duplicate(true)
	stale_update["revision"] = 2
	_expect(
		not store.upsert_shared_warehouse_snapshot(stale_update, 1)
		and store.export_shared_warehouse_ledger() == baseline_after_upsert
		and full_events.size() == 1
		and delta_events.size() == 1,
		"过期 CAS 的单仓 upsert 必须零写入、零 revision、零信号。"
	)
	var invalid_update := updated_first.duplicate(true)
	(invalid_update["slots"] as Array).pop_back()
	_expect(
		not store.upsert_shared_warehouse_snapshot(invalid_update, 2)
		and store.export_shared_warehouse_ledger() == baseline_after_upsert
		and delta_events.size() == 1,
		"非法单仓 payload 必须在提交前失败。"
	)

	_expect(
		store.remove_shared_warehouse_snapshot(8999, 2)
		and store.get_shared_warehouse_ledger_revision() == 2
		and delta_events.size() == 1,
		"删除缺失仓库必须是无 revision、无信号的幂等成功。"
	)
	_expect(
		store.remove_shared_warehouse_snapshot(8102, 2),
		"存在仓库必须能按当前 revision 增量删除。"
	)
	var remove_delta := delta_events[1] if delta_events.size() > 1 else {}
	_expect(
		store.get_shared_warehouse_ledger_revision() == 3
		and full_events.size() == 1
		and delta_events.size() == 2
		and int(remove_delta.get("warehouse_net_id", 0)) == 8102
		and bool(remove_delta.get("removed", false))
		and (remove_delta.get("snapshot", {}) as Dictionary).is_empty()
		and int(remove_delta.get("ledger_revision", 0)) == 3,
		"单仓 remove 必须只发布带删除 ID 的 bounded delta。"
	)

	var before_invalid_batch := store.export_shared_warehouse_ledger()
	var invalid_batch_snapshot := _make_empty_warehouse_snapshot(8201)
	(invalid_batch_snapshot["slots"] as Array).pop_back()
	_expect(
		not store.replace_shared_warehouse_snapshots(
			[updated_first, invalid_batch_snapshot], 3
		)
		and store.export_shared_warehouse_ledger() == before_invalid_batch
		and full_events.size() == 1
		and delta_events.size() == 2,
		"批量 replace 任一仓解码失败时不得出现半提交。"
	)

	var valid_apply := before_invalid_batch.duplicate(true)
	valid_apply["revision"] = 4
	_expect(
		store.apply_shared_warehouse_ledger_snapshot(valid_apply),
		"完整账本 apply 必须保留批量原子边界。"
	)
	_expect(
		store.get_shared_warehouse_ledger_revision() == 4
		and full_events.size() == 2
		and delta_events.size() == 2,
		"批量 apply 必须只发布完整账本信号，不伪装成单仓 delta。"
	)
	store.clear_shared_warehouse_ledger()
	_expect(
		store.get_shared_warehouse_ledger_revision() == 5
		and full_events.size() == 3
		and delta_events.size() == 2,
		"显式 clear 必须继续走完整账本信号边界。"
	)
	store.free()


func _test_single_warehouse_persist_scaling() -> void:
	var one_warehouse_msec := _measure_incremental_persist(1)
	var hundred_warehouses_msec := _measure_incremental_persist(100)
	print(
		"SHARED_WAREHOUSE_INCREMENTAL_BENCH iterations=%d one_ms=%.3f hundred_ms=%.3f"
		% [
			PERFORMANCE_ITERATIONS,
			one_warehouse_msec,
			hundred_warehouses_msec,
		]
	)
	_expect(
		hundred_warehouses_msec <= PERFORMANCE_BUDGET_MSEC,
		"100 仓账本下 %d 次单仓 persist 超过 %.1f ms 预算（实际 %.3f ms）。"
		% [
			PERFORMANCE_ITERATIONS,
			PERFORMANCE_BUDGET_MSEC,
			hundred_warehouses_msec,
		]
	)
	_expect(
		hundred_warehouses_msec <= one_warehouse_msec * 3.0 + 10.0,
		"单仓 persist 不应随账本从 1 仓扩到 100 仓而线性增长：1仓 %.3f ms，100仓 %.3f ms。"
		% [one_warehouse_msec, hundred_warehouses_msec]
	)


func _measure_incremental_persist(warehouse_count: int) -> float:
	var store := RunStateStore.new()
	store.begin_new_run(&"weishidaier", false)
	var target_id := 9001
	var target := _make_warehouse()
	BRIDGE.bind_identity(target, target_id)
	var snapshots: Array[Dictionary] = [target.export_storage_snapshot()]
	for warehouse_index in range(1, warehouse_count):
		snapshots.append(
			_make_empty_warehouse_snapshot(target_id + warehouse_index)
		)
	_expect(
		store.replace_shared_warehouse_snapshots(snapshots, 0, false),
		"%d 仓性能夹具必须完成批量初始化。" % warehouse_count
	)
	for _warmup in range(20):
		BRIDGE.persist_to_ledger(store, target, target_id)
	var all_persisted := true
	var started_usec := Time.get_ticks_usec()
	for _iteration in range(PERFORMANCE_ITERATIONS):
		all_persisted = (
			BRIDGE.persist_to_ledger(store, target, target_id)
			and all_persisted
		)
	var elapsed_msec := float(Time.get_ticks_usec() - started_usec) / 1000.0
	_expect(all_persisted, "%d 仓性能循环中的每次 upsert 都必须成功。" % warehouse_count)
	_expect(
		(store.export_shared_warehouse_ledger().get("warehouses", []) as Array).size()
		== warehouse_count,
		"单仓 upsert 不得覆盖或删除账本中的其他仓库。"
	)
	target.free()
	store.free()
	return elapsed_msec


func _assert_incremental_source_contract() -> void:
	var bridge_source := FileAccess.get_file_as_string(BRIDGE_SOURCE_PATH)
	var persist_source := _extract_function_source(
		bridge_source, "persist_to_ledger"
	)
	var remove_source := _extract_function_source(
		bridge_source, "remove_from_ledger"
	)
	for forbidden_text in [
		"export_shared_warehouse_ledger",
		"replace_shared_warehouse_snapshots",
		"sort",
		"\n\tfor ",
	]:
		_expect(
			not persist_source.contains(forbidden_text)
			and not remove_source.contains(forbidden_text),
			"Bridge 单仓 persist/remove 热路径不得包含 `%s`。" % forbidden_text
		)
	_expect(
		persist_source.contains("upsert_shared_warehouse_snapshot")
		and remove_source.contains("remove_shared_warehouse_snapshot"),
		"Bridge 热路径必须直接委托 RunState 单仓事务。"
	)

	var run_state_source := FileAccess.get_file_as_string(RUN_STATE_SOURCE_PATH)
	var upsert_source := _extract_function_source(
		run_state_source, "upsert_shared_warehouse_snapshot"
	)
	var run_state_remove_source := _extract_function_source(
		run_state_source, "remove_shared_warehouse_snapshot"
	)
	for forbidden_text in [
		"export_shared_warehouse_ledger",
		"replace_shared_warehouse_snapshots",
		"_decode_shared_warehouse_ledger",
		"shared_warehouse_ledger_changed",
		"sort",
		"\n\tfor ",
	]:
		_expect(
			not upsert_source.contains(forbidden_text)
			and not run_state_remove_source.contains(forbidden_text),
			"RunState 单仓事务不得包含 `%s`。" % forbidden_text
		)
	_expect(
		upsert_source.contains("_decode_shared_warehouse_snapshot")
		and upsert_source.contains("shared_warehouse_snapshot_changed")
		and run_state_remove_source.contains("shared_warehouse_snapshot_changed"),
		"RunState 单仓事务必须只解码一个仓并发布 bounded delta。"
	)


func _extract_function_source(source: String, function_name: String) -> String:
	var function_start := source.find("func %s(" % function_name)
	if function_start < 0:
		return ""
	var function_end := source.length()
	for next_marker in ["\nfunc ", "\nstatic func "]:
		var next_start := source.find(next_marker, function_start + 1)
		if next_start >= 0:
			function_end = mini(function_end, next_start)
	return source.substr(function_start, function_end - function_start)


func _make_empty_warehouse_snapshot(
	warehouse_net_id: int,
	warehouse_revision: int = 0
) -> Dictionary:
	var slots: Array[Dictionary] = []
	for slot_index in range(RunStateStore.INVENTORY_CAPACITY):
		slots.append({
			"slot_index": slot_index,
			"config_path": "",
			"stack_count": 0,
		})
	return {
		"warehouse_net_id": warehouse_net_id,
		"revision": warehouse_revision,
		"slots": slots,
	}


func _make_warehouse() -> OakWarehouse:
	var warehouse := WAREHOUSE_SCRIPT.new() as OakWarehouse
	warehouse.storage_items.resize(OakWarehouse.STORAGE_CAPACITY)
	warehouse.storage_stack_counts.resize(OakWarehouse.STORAGE_CAPACITY)
	warehouse.storage_stack_counts.fill(0)
	warehouse.multiplayer_storage_request_timer = Timer.new()
	warehouse.add_child(warehouse.multiplayer_storage_request_timer)
	return warehouse


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
