extends "res://scene/enemy/layered_ranged_enemy.gd"

## Test-only ranged family. Capability flags are authored per fixture instance so
## one scene proves fail-closed inheritance and independent capability gates.

@export var centralized_contract_opt_in := false
@export var layered_contract_opt_in := false
@export var contact_contract_opt_in := false
@export var indexed_contract_opt_in := false

var contract_event_deadline_physics_frame := -1
var contract_event_sleep_allowed := true
var contract_decision_consumed := false
var contract_motion_allowed := true
var contract_prepare_count := 0
var contract_hook_order: Array[StringName] = []


func supports_centralized_authoritative_simulation() -> bool:
	return centralized_contract_opt_in


func _supports_layered_ranged_authoritative_simulation() -> bool:
	return layered_contract_opt_in


func _supports_layered_ranged_contact_authority() -> bool:
	return contact_contract_opt_in


func _supports_layered_ranged_indexed_touch_authority() -> bool:
	return indexed_contract_opt_in


func run_contract_hook_order_probe(probe_target: Node2D) -> Dictionary:
	objective_target = probe_target
	contract_hook_order.clear()
	_advance_layered_area_family_event_phase(1.0 / 60.0)
	var decision_consumed := (
		_try_consume_layered_area_family_decision_phase(1.0 / 60.0)
	)
	var motion_allowed := _can_run_layered_area_motion()
	return {
		"decision_consumed": decision_consumed,
		"motion_allowed": motion_allowed,
		"order": contract_hook_order.duplicate(),
	}


func get_contract_merged_event_deadline(physics_delta: float) -> int:
	return _get_layered_area_event_sleep_until_physics_frame(physics_delta)


func get_contract_family_event_sleep_allowed() -> bool:
	return _can_sleep_layered_area_family_event_phase()


func _prepare_layered_ranged_authoritative_simulation() -> void:
	contract_prepare_count += 1
	contract_event_deadline_physics_frame = -1
	contract_event_sleep_allowed = true
	contract_decision_consumed = false
	contract_motion_allowed = true
	contract_hook_order.clear()
	contract_hook_order.append(&"prepare")


func _advance_layered_ranged_event_phase(_delta: float) -> void:
	contract_hook_order.append(&"event")


func _can_sleep_layered_ranged_event_phase() -> bool:
	return contract_event_sleep_allowed


func _get_layered_ranged_event_sleep_until_physics_frame(
	_physics_delta: float
) -> int:
	return contract_event_deadline_physics_frame


func _try_consume_layered_ranged_decision_phase(_delta: float) -> bool:
	contract_hook_order.append(&"decision")
	return contract_decision_consumed


func _layered_ranged_attack_state_allows_motion() -> bool:
	contract_hook_order.append(&"motion")
	return contract_motion_allowed
