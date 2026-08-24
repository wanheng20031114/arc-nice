@abstract
extends "res://scene/enemy/capoo_ranged_enemy.gd"
class_name LayeredRangedEnemy

## Opt-in template for ranged enemies whose authored state machine has been
## separated into event, decision and motion responsibilities. Merely inheriting
## this script grants no layered, shared-contact or indexed-touch authority;
## every concrete family must explicitly pass each independent gate.


func supports_layered_area_authoritative_simulation() -> bool:
	return (
		supports_centralized_authoritative_simulation()
		and _supports_layered_ranged_authoritative_simulation()
	)


func supports_layered_contact_authoritative_simulation() -> bool:
	return (
		supports_layered_area_authoritative_simulation()
		and _supports_layered_ranged_contact_authority()
	)


func supports_indexed_touch_authority() -> bool:
	return (
		supports_layered_area_authoritative_simulation()
		and _supports_layered_ranged_indexed_touch_authority()
	)


## Concrete migrations override this only after their complete ranged state
## machine has an event/decision/motion split with semantic regression coverage.
func _supports_layered_ranged_authoritative_simulation() -> bool:
	return false


## Shared Enemy/Enemy contact admission is independent from Player/Plant Area
## indexing. A ranged family opts in only after directed-contact parity passes.
func _supports_layered_ranged_contact_authority() -> bool:
	return false


## Indexed contact is a separate admission gate. A family may migrate to
## LAYERED_AREA while its authored Area2D contact remains authoritative.
func _supports_layered_ranged_indexed_touch_authority() -> bool:
	return false


func prepare_layered_area_authoritative_simulation() -> void:
	super.prepare_layered_area_authoritative_simulation()
	_prepare_layered_ranged_authoritative_simulation()


## Admission and rollback both enter this boundary. Concrete families reset
## only their layered projections here; authored LEGACY/COMPAT state remains the
## source of truth and must not be reconstructed by the template.
func _prepare_layered_ranged_authoritative_simulation() -> void:
	pass


func _advance_layered_area_family_event_phase(delta: float) -> void:
	super._advance_layered_area_family_event_phase(delta)
	_advance_layered_ranged_event_phase(delta)


## Advance deterministic ranged timers and validate already committed attack
## state. Spawning projectiles or committing a new attack belongs in decision.
func _advance_layered_ranged_event_phase(_delta: float) -> void:
	pass


func _can_sleep_layered_area_family_event_phase() -> bool:
	return (
		super._can_sleep_layered_area_family_event_phase()
		and _can_sleep_layered_ranged_event_phase()
	)


## Return false while a ranged event still needs per-tick polling.
func _can_sleep_layered_ranged_event_phase() -> bool:
	return true


func _get_layered_area_event_sleep_until_physics_frame(
	physics_delta: float
) -> int:
	var inherited_deadline := (
		super._get_layered_area_event_sleep_until_physics_frame(physics_delta)
	)
	var ranged_deadline := (
		_get_layered_ranged_event_sleep_until_physics_frame(physics_delta)
	)
	if inherited_deadline < 0:
		return ranged_deadline
	if ranged_deadline < 0:
		return inherited_deadline
	return mini(inherited_deadline, ranged_deadline)


## Absolute physics frame for the next observable ranged event, or -1 when the
## family has no pending deadline. The template always keeps the earliest of
## this deadline and the inherited touch-cooldown deadline.
func _get_layered_ranged_event_sleep_until_physics_frame(
	_physics_delta: float
) -> int:
	return -1


func _try_consume_layered_area_family_decision_phase(delta: float) -> bool:
	if super._try_consume_layered_area_family_decision_phase(delta):
		return true
	return _try_consume_layered_ranged_decision_phase(delta)


## Commit ranged state transitions and attacks here. Return true when the
## decision consumes this tick's movement.
func _try_consume_layered_ranged_decision_phase(_delta: float) -> bool:
	return false


func _can_run_layered_area_motion() -> bool:
	return (
		super._can_run_layered_area_motion()
		and _layered_ranged_attack_state_allows_motion()
	)


## Pure attack-state motion gate. Concrete families map their authored
## wind-up/recovery/lock states here without duplicating chase/contact rules.
func _layered_ranged_attack_state_allows_motion() -> bool:
	return true
