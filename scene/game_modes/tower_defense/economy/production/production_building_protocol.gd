extends RefCounted
class_name ProductionBuildingProtocol

const OPERATION_SELECT_RECIPE := &"select_recipe"
const OPERATION_SET_ENABLED := &"set_enabled"
const OPERATION_COLLECT_OUTPUT := &"collect_output"

const RESULT_SUCCESS := &"success"
const RESULT_INVALID_COMMAND := &"invalid_command"
const RESULT_STALE_STATE := &"stale_state"
const RESULT_INVALID_RECIPE := &"invalid_recipe"
const RESULT_RESEARCH_LOCKED := &"research_locked"
const RESULT_BUILDING_MISSING := &"building_missing"
const RESULT_INVALID_PLAYER := &"invalid_player"
const RESULT_OUT_OF_RANGE := &"out_of_range"
const RESULT_RATE_LIMITED := &"rate_limited"
const RESULT_UNAVAILABLE := &"unavailable"
const RESULT_OUTPUT_EMPTY := &"output_empty"
const RESULT_INVENTORY_FULL := &"inventory_full"
const MAX_RECIPE_ID_WIRE_LENGTH := 128


static func make_select_recipe_command(
	request_id: int,
	building_net_id: int,
	peer_id: int,
	expected_production_revision: int,
	recipe_id: StringName
) -> Dictionary:
	return {
		"operation": OPERATION_SELECT_RECIPE,
		"request_id": request_id,
		"building_net_id": building_net_id,
		"peer_id": peer_id,
		"expected_production_revision": expected_production_revision,
		"recipe_id": String(recipe_id),
	}


static func make_set_enabled_command(
	request_id: int,
	building_net_id: int,
	peer_id: int,
	expected_production_revision: int,
	enabled: bool
) -> Dictionary:
	return {
		"operation": OPERATION_SET_ENABLED,
		"request_id": request_id,
		"building_net_id": building_net_id,
		"peer_id": peer_id,
		"expected_production_revision": expected_production_revision,
		"enabled": enabled,
	}


static func make_collect_output_command(
	request_id: int,
	building_net_id: int,
	peer_id: int,
	expected_production_revision: int
) -> Dictionary:
	return {
		"operation": OPERATION_COLLECT_OUTPUT,
		"request_id": request_id,
		"building_net_id": building_net_id,
		"peer_id": peer_id,
		"expected_production_revision": expected_production_revision,
	}


static func is_valid_command(command: Dictionary) -> bool:
	if not _has_strict_positive_int(command, "request_id"):
		return false
	if not _has_strict_positive_int(command, "building_net_id"):
		return false
	if not _has_strict_positive_int(command, "peer_id"):
		return false
	if not _has_strict_non_negative_int(command, "expected_production_revision"):
		return false
	var operation := get_operation(command)
	match operation:
		OPERATION_SELECT_RECIPE:
			var recipe_value: Variant = command.get("recipe_id")
			return (
				typeof(recipe_value) in [TYPE_STRING, TYPE_STRING_NAME]
				and not String(recipe_value).is_empty()
			)
		OPERATION_SET_ENABLED:
			return typeof(command.get("enabled")) == TYPE_BOOL
		OPERATION_COLLECT_OUTPUT:
			return true
		_:
			return false


## Copies only the fixed protocol fields from an untrusted RPC Dictionary.
## Unknown/nested fields are deliberately ignored so the gameplay handler does
## not deep-copy extension payloads after Godot has deserialized the RPC.
static func canonicalize_command(
	raw_command: Dictionary,
	expected_peer_id: int
) -> Dictionary:
	if not command_peer_matches(raw_command, expected_peer_id):
		return {}
	if (
		not _has_strict_positive_int(raw_command, "request_id")
		or not _has_strict_positive_int(raw_command, "building_net_id")
		or not _has_strict_non_negative_int(
			raw_command,
			"expected_production_revision"
		)
	):
		return {}
	var operation_value: Variant = raw_command.get("operation")
	if typeof(operation_value) not in [TYPE_STRING, TYPE_STRING_NAME]:
		return {}
	var operation_wire := String(operation_value)
	var command := {
		"request_id": int(raw_command["request_id"]),
		"building_net_id": int(raw_command["building_net_id"]),
		"peer_id": expected_peer_id,
		"expected_production_revision": int(
			raw_command["expected_production_revision"]
		),
	}
	if operation_wire == String(OPERATION_SELECT_RECIPE):
		var recipe_value: Variant = raw_command.get("recipe_id")
		if typeof(recipe_value) not in [TYPE_STRING, TYPE_STRING_NAME]:
			return {}
		var recipe_wire := String(recipe_value)
		if (
			recipe_wire.is_empty()
			or recipe_wire.length() > MAX_RECIPE_ID_WIRE_LENGTH
		):
			return {}
		command["operation"] = OPERATION_SELECT_RECIPE
		command["recipe_id"] = recipe_wire
	elif operation_wire == String(OPERATION_SET_ENABLED):
		if typeof(raw_command.get("enabled")) != TYPE_BOOL:
			return {}
		command["operation"] = OPERATION_SET_ENABLED
		command["enabled"] = bool(raw_command["enabled"])
	elif operation_wire == String(OPERATION_COLLECT_OUTPUT):
		command["operation"] = OPERATION_COLLECT_OUTPUT
	else:
		return {}
	return command if is_valid_command(command) else {}


static func make_result(
	command: Dictionary,
	success: bool,
	reason: StringName,
	production_revision: int,
	state: Dictionary,
	host_sample_time: float
) -> Dictionary:
	return {
		"request_id": get_int_field(command, "request_id", 0),
		"building_net_id": get_int_field(command, "building_net_id", 0),
		"peer_id": get_int_field(command, "peer_id", 0),
		"success": success,
		"reason": reason,
		"production_revision": production_revision,
		"state": state.duplicate(true),
		"host_sample_time": host_sample_time,
	}


static func get_operation(command: Dictionary) -> StringName:
	var value: Variant = command.get("operation", &"")
	if typeof(value) not in [TYPE_STRING, TYPE_STRING_NAME]:
		return &""
	return StringName(value)


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


static func _has_strict_positive_int(command: Dictionary, key: String) -> bool:
	return typeof(command.get(key)) == TYPE_INT and int(command[key]) > 0


static func _has_strict_non_negative_int(command: Dictionary, key: String) -> bool:
	return typeof(command.get(key)) == TYPE_INT and int(command[key]) >= 0
