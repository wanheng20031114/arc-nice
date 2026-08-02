extends RefCounted
class_name SharedWarehouseLedgerBridge

## OakWarehouse 实体与 RunState 跨场景账本之间的唯一桥接层。
## 单人战斗和联机房主都必须复用这里的解码、替换与排序规则，避免两套
## 持久化逻辑在仓库 revision 或槽位 wire 格式变化后发生漂移。


static func bind_identity(warehouse: Node, warehouse_net_id: int) -> bool:
	if not _has_warehouse_interface(warehouse) or warehouse_net_id <= 0:
		return false
	return bool(warehouse.call(
		"configure_persistent_storage_identity",
		warehouse_net_id
	))


static func restore_from_ledger(
	run_state: RunStateStore,
	warehouse: Node,
	warehouse_net_id: int
) -> bool:
	if run_state == null or not bind_identity(warehouse, warehouse_net_id):
		return false
	var snapshot := run_state.get_shared_warehouse_snapshot(warehouse_net_id)
	if snapshot.is_empty():
		return false
	return bool(warehouse.call("apply_storage_snapshot", snapshot))


static func persist_to_ledger(
	run_state: RunStateStore,
	warehouse: Node,
	warehouse_net_id: int
) -> bool:
	if run_state == null or not bind_identity(warehouse, warehouse_net_id):
		return false
	var ledger := run_state.export_shared_warehouse_ledger()
	var snapshots := (ledger.get("warehouses", []) as Array).duplicate(true)
	var replacement := warehouse.call("export_storage_snapshot") as Dictionary
	var replaced := false
	for index in snapshots.size():
		var current := snapshots[index] as Dictionary
		if int(current.get("warehouse_net_id", 0)) == warehouse_net_id:
			snapshots[index] = replacement
			replaced = true
			break
	if not replaced:
		snapshots.append(replacement)
	snapshots.sort_custom(_sort_snapshots_by_warehouse_id)
	return run_state.replace_shared_warehouse_snapshots(
		snapshots,
		int(ledger.get("revision", -1))
	)


static func remove_from_ledger(
	run_state: RunStateStore,
	warehouse_net_id: int
) -> bool:
	if run_state == null or warehouse_net_id <= 0:
		return false
	var ledger := run_state.export_shared_warehouse_ledger()
	var snapshots: Array = []
	var found := false
	for raw_snapshot in ledger.get("warehouses", []) as Array:
		var snapshot := raw_snapshot as Dictionary
		if int(snapshot.get("warehouse_net_id", 0)) == warehouse_net_id:
			found = true
			continue
		snapshots.append(snapshot.duplicate(true))
	if not found:
		return true
	return run_state.replace_shared_warehouse_snapshots(
		snapshots,
		int(ledger.get("revision", -1))
	)


static func capture_runtime_warehouses(
	run_state: RunStateStore,
	runtime: Node
) -> bool:
	if (
		run_state == null
		or runtime == null
		or not is_instance_valid(runtime)
		or not runtime.has_method("get_multiplayer_plant_snapshots")
		or not runtime.has_method("get_multiplayer_plant_node")
	):
		return false
	var warehouse_ids: Array[int] = []
	for plant_snapshot in runtime.call("get_multiplayer_plant_snapshots") as Array:
		var net_id := int(plant_snapshot.get("net_id", 0))
		var warehouse := runtime.call(
			"get_multiplayer_plant_node",
			net_id
		) as Node
		if (
			net_id <= 0
			or not _has_warehouse_interface(warehouse)
			or bool(warehouse.get("is_dead"))
			or bool(warehouse.get("is_removing"))
			or warehouse.is_queued_for_deletion()
		):
			continue
		warehouse_ids.append(net_id)
	warehouse_ids.sort()

	var snapshots: Array[Dictionary] = []
	for warehouse_net_id in warehouse_ids:
		var warehouse := runtime.call(
			"get_multiplayer_plant_node",
			warehouse_net_id
		) as Node
		if not bind_identity(warehouse, warehouse_net_id):
			return false
		snapshots.append(
			warehouse.call("export_storage_snapshot") as Dictionary
		)
	return run_state.replace_shared_warehouse_snapshots(
		snapshots,
		run_state.get_shared_warehouse_ledger_revision()
	)


static func _sort_snapshots_by_warehouse_id(left: Variant, right: Variant) -> bool:
	return int((left as Dictionary).get("warehouse_net_id", 0)) < int(
		(right as Dictionary).get("warehouse_net_id", 0)
	)


static func _has_warehouse_interface(warehouse: Node) -> bool:
	return (
		warehouse != null
		and is_instance_valid(warehouse)
		and warehouse.has_method("configure_persistent_storage_identity")
		and warehouse.has_method("apply_storage_snapshot")
		and warehouse.has_method("export_storage_snapshot")
	)
