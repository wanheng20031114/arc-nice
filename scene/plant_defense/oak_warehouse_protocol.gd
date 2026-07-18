extends RefCounted
class_name OakWarehouseProtocol

enum TransferDirection {
	PLAYER_TO_STORAGE,
	STORAGE_TO_PLAYER,
}

enum ItemContainer {
	PLAYER,
	STORAGE,
}

const OPERATION_TRANSFER := &"transfer"
const OPERATION_SLOT_MOVE := &"slot_move"
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
		"operation": OPERATION_TRANSFER,
		"request_id": request_id,
		"warehouse_net_id": warehouse_net_id,
		"peer_id": peer_id,
		"direction": int(direction),
		"slot_index": slot_index,
		"expected_inventory_revision": expected_inventory_revision,
		"expected_storage_revision": expected_storage_revision,
	}


static func make_slot_move_command(
	request_id: int,
	warehouse_net_id: int,
	peer_id: int,
	source_container: int,
	source_slot_index: int,
	target_container: int,
	target_slot_index: int,
	expected_inventory_revision: int,
	expected_storage_revision: int
) -> Dictionary:
	return {
		"operation": OPERATION_SLOT_MOVE,
		"request_id": request_id,
		"warehouse_net_id": warehouse_net_id,
		"peer_id": peer_id,
		"source_container": int(source_container),
		"source_slot_index": source_slot_index,
		"target_container": int(target_container),
		"target_slot_index": target_slot_index,
		"expected_inventory_revision": expected_inventory_revision,
		"expected_storage_revision": expected_storage_revision,
	}


static func is_valid_command(command: Dictionary) -> bool:
	var operation := _get_command_operation(command, OPERATION_TRANSFER)
	if operation == OPERATION_SLOT_MOVE:
		return is_valid_slot_move_command(command)
	if operation == OPERATION_TRANSFER:
		return is_valid_transfer_command(command)
	return false


static func is_valid_transfer_command(command: Dictionary) -> bool:
	var request_id := get_int_field(command, "request_id", 0)
	var warehouse_net_id := get_int_field(command, "warehouse_net_id", 0)
	var peer_id := get_int_field(command, "peer_id", 0)
	var direction := get_int_field(command, "direction", -1)
	var slot_index := get_int_field(command, "slot_index", -1)
	var inventory_revision := get_int_field(command, "expected_inventory_revision", -1)
	var storage_revision := get_int_field(command, "expected_storage_revision", -1)
	return (
		_get_command_operation(command, OPERATION_TRANSFER) == OPERATION_TRANSFER
		and request_id > 0
		and warehouse_net_id > 0
		and peer_id > 0
		and direction >= TransferDirection.PLAYER_TO_STORAGE
		and direction <= TransferDirection.STORAGE_TO_PLAYER
		and slot_index >= 0
		and slot_index < RunStateStore.INVENTORY_CAPACITY
		and inventory_revision >= 0
		and storage_revision >= 0
	)


static func is_valid_slot_move_command(command: Dictionary) -> bool:
	var request_id := get_int_field(command, "request_id", 0)
	var warehouse_net_id := get_int_field(command, "warehouse_net_id", 0)
	var peer_id := get_int_field(command, "peer_id", 0)
	var source_container := get_int_field(command, "source_container", -1)
	var target_container := get_int_field(command, "target_container", -1)
	var source_slot_index := get_int_field(command, "source_slot_index", -1)
	var target_slot_index := get_int_field(command, "target_slot_index", -1)
	var inventory_revision := get_int_field(command, "expected_inventory_revision", -1)
	var storage_revision := get_int_field(command, "expected_storage_revision", -1)
	return (
		_get_command_operation(command) == OPERATION_SLOT_MOVE
		and request_id > 0
		and warehouse_net_id > 0
		and peer_id > 0
		and source_container >= ItemContainer.PLAYER
		and source_container <= ItemContainer.STORAGE
		and target_container >= ItemContainer.PLAYER
		and target_container <= ItemContainer.STORAGE
		and source_slot_index >= 0
		and source_slot_index < RunStateStore.INVENTORY_CAPACITY
		and target_slot_index >= 0
		and target_slot_index < RunStateStore.INVENTORY_CAPACITY
		and (
			source_container != target_container
			or source_slot_index != target_slot_index
		)
		and inventory_revision >= 0
		and storage_revision >= 0
	)


static func make_result(
	command: Dictionary,
	success: bool,
	reason: StringName,
	inventory_revision: int,
	storage_revision: int
) -> Dictionary:
	return {
		"request_id": get_int_field(command, "request_id", 0),
		"warehouse_net_id": get_int_field(command, "warehouse_net_id", 0),
		"peer_id": get_int_field(command, "peer_id", 0),
		"success": success,
		"reason": reason,
		"inventory_revision": inventory_revision,
		"storage_revision": storage_revision,
	}


static func get_int_field(command: Dictionary, key: String, default_value: int) -> int:
	var value: Variant = command.get(key, default_value)
	if typeof(value) != TYPE_INT:
		return default_value
	return int(value)


static func command_peer_matches(command: Dictionary, expected_peer_id: int) -> bool:
	return (
		expected_peer_id > 0
		and typeof(command.get("peer_id")) == TYPE_INT
		and int(command["peer_id"]) == expected_peer_id
	)


static func _get_command_operation(
	command: Dictionary,
	default_operation: StringName = &""
) -> StringName:
	var operation: Variant = command.get("operation", default_operation)
	if typeof(operation) not in [TYPE_STRING, TYPE_STRING_NAME]:
		return &""
	return StringName(operation)
