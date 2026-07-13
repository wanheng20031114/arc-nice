extends RefCounted
class_name OakWarehouseProtocol

enum TransferDirection {
	PLAYER_TO_STORAGE,
	STORAGE_TO_PLAYER,
}

const RESULT_SUCCESS := &"success"
const RESULT_INVALID_COMMAND := &"invalid_command"
const RESULT_STALE_INVENTORY := &"stale_inventory"
const RESULT_STALE_STORAGE := &"stale_storage"
const RESULT_SOURCE_EMPTY := &"source_empty"
const RESULT_TARGET_FULL := &"target_full"


static func make_transfer_command(
	request_id: int,
	warehouse_net_id: int,
	peer_id: int,
	direction: int,
	slot_index: int,
	expected_inventory_revision: int,
	expected_storage_revision: int
) -> Dictionary:
	return {
		"request_id": request_id,
		"warehouse_net_id": warehouse_net_id,
		"peer_id": peer_id,
		"direction": int(direction),
		"slot_index": slot_index,
		"expected_inventory_revision": expected_inventory_revision,
		"expected_storage_revision": expected_storage_revision,
	}


static func is_valid_transfer_command(command: Dictionary) -> bool:
	var direction := int(command.get("direction", -1))
	return (
		int(command.get("request_id", 0)) > 0
		and int(command.get("warehouse_net_id", 0)) > 0
		and int(command.get("peer_id", 0)) > 0
		and direction >= TransferDirection.PLAYER_TO_STORAGE
		and direction <= TransferDirection.STORAGE_TO_PLAYER
		and int(command.get("slot_index", -1)) >= 0
		and int(command.get("slot_index", -1)) < RunStateStore.INVENTORY_CAPACITY
		and int(command.get("expected_inventory_revision", -1)) >= 0
		and int(command.get("expected_storage_revision", -1)) >= 0
	)


static func make_result(
	command: Dictionary,
	success: bool,
	reason: StringName,
	inventory_revision: int,
	storage_revision: int
) -> Dictionary:
	return {
		"request_id": int(command.get("request_id", 0)),
		"warehouse_net_id": int(command.get("warehouse_net_id", 0)),
		"peer_id": int(command.get("peer_id", 0)),
		"success": success,
		"reason": reason,
		"inventory_revision": inventory_revision,
		"storage_revision": storage_revision,
	}
