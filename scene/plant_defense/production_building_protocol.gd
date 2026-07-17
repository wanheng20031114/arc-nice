extends RefCounted
class_name ProductionBuildingProtocol

const OPERATION_SELECT_RECIPE := &"select_recipe"
const OPERATION_SET_ENABLED := &"set_enabled"

const RESULT_SUCCESS := &"success"
const RESULT_INVALID_COMMAND := &"invalid_command"
const RESULT_STALE_STATE := &"stale_state"
const RESULT_INVALID_RECIPE := &"invalid_recipe"
const RESULT_BUILDING_MISSING := &"building_missing"
const RESULT_INVALID_PLAYER := &"invalid_player"
const RESULT_OUT_OF_RANGE := &"out_of_range"
const RESULT_RATE_LIMITED := &"rate_limited"
const RESULT_UNAVAILABLE := &"unavailable"


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
		_:
			return false


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
