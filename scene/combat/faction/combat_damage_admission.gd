extends RefCounted
class_name CombatDamageAdmission

## Shared faction gate used immediately before every authoritative resolver.
## Presentation-only health snapshots never enter this API.


static func get_rejection_reason(
	request: DamageRequest,
	target_faction_id: int,
	relation_service: CombatRelationService = null
) -> CombatTypes.DamageRejectionReason:
	if request == null or not CombatRelationService.is_valid_faction_id(
		target_faction_id
	):
		return CombatTypes.DamageRejectionReason.INVALID_REQUEST
	var source_snapshot := request.get_or_create_source_snapshot()
	if source_snapshot == null or not source_snapshot.is_valid():
		return CombatTypes.DamageRejectionReason.INVALID_REQUEST
	if request.has_flag(CombatTypes.DamageFlag.BYPASS_FACTION_FILTER):
		return CombatTypes.DamageRejectionReason.NONE
	var is_hostile := (
		relation_service.is_hostile(
			source_snapshot.source_faction_id,
			target_faction_id
		)
		if relation_service != null
		else CombatRelationService.is_default_hostile(
			source_snapshot.source_faction_id,
			target_faction_id
		)
	)
	return (
		CombatTypes.DamageRejectionReason.NONE
		if is_hostile
		else CombatTypes.DamageRejectionReason.NON_HOSTILE
	)


static func is_admitted(
	request: DamageRequest,
	target_faction_id: int,
	relation_service: CombatRelationService = null
) -> bool:
	return get_rejection_reason(
		request,
		target_faction_id,
		relation_service
	) == CombatTypes.DamageRejectionReason.NONE
