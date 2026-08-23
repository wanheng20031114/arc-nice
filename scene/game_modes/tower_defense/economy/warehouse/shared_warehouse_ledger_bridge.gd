extends RefCounted
class_name SharedWarehouseLedgerBridge

## OakWarehouse 实体与 RunState 跨场景账本之间的唯一桥接层。
## 单人战斗和联机房主都复用同一单仓增量事务；离场捕获仍通过批量替换
## 一次原子提交，避免两套持久化逻辑在 revision 或槽位格式变化后漂移。


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
	return run_state.upsert_shared_warehouse_snapshot(
		warehouse.export_storage_snapshot(),
		run_state.get_shared_warehouse_ledger_revision()
	)


static func remove_from_ledger(
	run_state: RunStateStore,
	warehouse_net_id: int
) -> bool:
	if run_state == null or warehouse_net_id <= 0:
		return false
	return run_state.remove_shared_warehouse_snapshot(
		warehouse_net_id,
		run_state.get_shared_warehouse_ledger_revision()
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
