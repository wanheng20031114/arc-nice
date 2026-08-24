extends EnemySimulationCoordinator
class_name EnemySimulationAtomicRollbackCoordinator

## Deterministic failure-injection seam for the contact-admission transaction.
## Production code has no test flag: this subclass fails exactly the requested
## virtual admission call while every other call uses the real contact service.

var fail_contact_admission_call := 0
var contact_admission_call_count := 0
var manual_dispatch_only := false


func _claim_existing_supported_enemies_after_boundary(
	expected_mode: int
) -> void:
	super._claim_existing_supported_enemies_after_boundary(expected_mode)
	# The production handoff deliberately re-enables automatic coordinator ticks.
	# This failure-injection fixture drives exact tick boundaries manually, so keep
	# the callback disabled after that deferred handoff to avoid a render/physics
	# cadence race in the regression itself.
	if manual_dispatch_only:
		set_physics_process(false)


func _register_contact_proxy(
	registration: EnemySimulationCoordinator.Registration
) -> bool:
	contact_admission_call_count += 1
	if (
		fail_contact_admission_call > 0
		and contact_admission_call_count == fail_contact_admission_call
	):
		_metric_contact_registration_rejection_count += 1
		return false
	return super._register_contact_proxy(registration)


func is_contact_proxy_state_fully_released(enemy: Enemy) -> bool:
	if enemy == null or not is_instance_valid(enemy):
		return false
	var registration := _registration_by_instance_id.get(
		enemy.get_instance_id()
	) as EnemySimulationCoordinator.Registration
	return (
		registration != null
		and not registration.tombstone
		and not registration.contact_proxy_registered
		and not registration.indexed_touch_authority_capable
		and not registration.indexed_touch_dirty
		and registration.indexed_touch_dirty_reasons == 0
		and not registration.contact_geometry_dirty
		and registration.contact_shape_revision == -1
		and registration.contact_attacker_proxy == null
		and registration.contact_body_proxy == null
		and registration.contact_attacker_shape == null
		and registration.contact_attacker_shape_resource_ids.is_empty()
		and registration.contact_body_shape_resource_ids.is_empty()
		and registration.contact_attacker_shape_local_transforms.is_empty()
		and registration.contact_body_shape_local_transforms.is_empty()
	)


func contact_transaction_queues_are_empty() -> bool:
	return (
		_pending_contact_admissions.is_empty()
		and _dirty_contact_geometries.is_empty()
		and _dirty_indexed_touch_registrations.is_empty()
		and _dirty_indexed_touch_work_registrations.is_empty()
		and _indexed_touch_moved_registrations.is_empty()
		and _indexed_touch_moved_work_registrations.is_empty()
	)
