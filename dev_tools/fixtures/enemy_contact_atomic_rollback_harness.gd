extends Enemy
class_name EnemyContactAtomicRollbackHarness

const RNG_SEED := 0x51A7C0DE

var event_count := 0
var decision_count := 0
var motion_count := 0
var compat_count := 0
var victim_health := 1000
var projectile_spawn_count := 0
var gameplay_value := 17
var compat_ticks: Array[int] = []
var gameplay_rng := RandomNumberGenerator.new()


func _init() -> void:
	gameplay_rng.seed = RNG_SEED


func supports_centralized_authoritative_simulation() -> bool:
	return true


func supports_layered_area_authoritative_simulation() -> bool:
	return true


func supports_layered_contact_authoritative_simulation() -> bool:
	return true


func supports_indexed_touch_authority() -> bool:
	return true


func prepare_layered_area_authoritative_simulation() -> void:
	super.prepare_layered_area_authoritative_simulation()
	layered_area_motion_phase_due = true


func simulate_layered_area_event_phase(
	_delta: float,
	simulation_tick: int,
	token: int
) -> bool:
	if not _accept_layered_area_event_phase(token, simulation_tick):
		return false
	event_count += 1
	_apply_gameplay_side_effect(101)
	return true


func simulate_layered_area_decision_phase(
	_delta: float,
	simulation_tick: int,
	token: int
) -> bool:
	if not _accept_layered_area_followup_phase(token, simulation_tick):
		return false
	decision_count += 1
	layered_area_decision_urgent = false
	_apply_gameplay_side_effect(211)
	return true


func simulate_layered_area_motion_phase(
	_delta: float,
	simulation_tick: int,
	token: int
) -> bool:
	if not _accept_layered_area_followup_phase(token, simulation_tick):
		return false
	motion_count += 1
	global_position += Vector2(3.0, -2.0)
	_apply_gameplay_side_effect(307)
	return true


func _run_authoritative_physics_step(_delta: float) -> void:
	compat_count += 1
	compat_ticks.append(scheduled_authoritative_admission_tick)
	global_position += Vector2(1.0, 0.0)
	_apply_gameplay_side_effect(401)


func capture_gameplay_state() -> Dictionary:
	return {
		"event_count": event_count,
		"decision_count": decision_count,
		"motion_count": motion_count,
		"compat_count": compat_count,
		"victim_health": victim_health,
		"projectile_spawn_count": projectile_spawn_count,
		"gameplay_value": gameplay_value,
		"rng_state": gameplay_rng.state,
		"position": global_position,
		"velocity": velocity,
		"compat_ticks": compat_ticks.duplicate(),
	}


func _apply_gameplay_side_effect(signature: int) -> void:
	victim_health -= 7
	projectile_spawn_count += 1
	var mixed_value := int(
		gameplay_value * 1103515245 + signature + gameplay_rng.randi()
	)
	gameplay_value = mixed_value & 0x7fffffff
