extends RefCounted
class_name SharedWarehouseLedgerBridge

## OakWarehouse 实体与 RunState 跨场景账本之间的唯一桥接层。
## 单人战斗和联机房主都必须复用这里的解码、替换与排序规则，避免两套
## 持久化逻辑在仓库 revision 或槽位 wire 格式变化后发生漂移。


static func bind_identity(
	warehouse: OakWarehouse,
	warehouse_net_id: int
) -> bool:
	if warehouse == null or not is_instance_valid(warehouse) or warehouse_net_id <= 0:
		return false
	return warehouse.configure_persistent_storage_identity(warehouse_net_id)


static func restore_from_ledger(
	run_state: RunStateStore,
	warehouse: OakWarehouse,
	warehouse_net_id: int
) -> bool:
	if run_state == null or not bind_identity(warehouse, warehouse_net_id):
		return false
	var snapshot := run_state.get_shared_warehouse_snapshot(warehouse_net_id)
	if snapshot.is_empty():
		return false
	return warehouse.apply_storage_snapshot(snapshot)


static func persist_to_ledger(
	run_state: RunStateStore,
	warehouse: OakWarehouse,
	warehouse_net_id: int
) -> bool:
	if run_state == null or not bind_identity(warehouse, warehouse_net_id):
		return false
	var ledger := run_state.export_shared_warehouse_ledger()
	var snapshots := (ledger.get("warehouses", []) as Array).duplicate(true)
	var replacement := warehouse.export_storage_snapshot()
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


static func capture_warehouses(
	run_state: RunStateStore,
	warehouses: Array[OakWarehouse]
) -> bool:
	if run_state == null:
		return false
	var warehouses_by_id: Dictionary[int, OakWarehouse] = {}
	for warehouse in warehouses:
		var net_id := (
			int(warehouse.get_meta(&"net_id", warehouse.warehouse_net_id))
			if warehouse != null and is_instance_valid(warehouse)
			else 0
		)
		if (
			net_id <= 0
			or warehouse.is_dead
			or warehouse.is_removing
			or warehouse.is_queued_for_deletion()
		):
			continue
		warehouses_by_id[net_id] = warehouse
	var warehouse_ids: Array[int] = warehouses_by_id.keys()
	warehouse_ids.sort()

	var snapshots: Array[Dictionary] = []
	for warehouse_net_id in warehouse_ids:
		var warehouse := warehouses_by_id[warehouse_net_id]
		if not bind_identity(warehouse, warehouse_net_id):
			return false
		snapshots.append(warehouse.export_storage_snapshot())
	return run_state.replace_shared_warehouse_snapshots(
		snapshots,
		run_state.get_shared_warehouse_ledger_revision()
	)


static func _sort_snapshots_by_warehouse_id(left: Variant, right: Variant) -> bool:
	return int((left as Dictionary).get("warehouse_net_id", 0)) < int(
		(right as Dictionary).get("warehouse_net_id", 0)
	)
