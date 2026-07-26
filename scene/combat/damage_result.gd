extends RefCounted
class_name DamageResult

## Complete, side-effect-free answer from DamageResolver. `resolved_damage` is
## the post-defense value of the hit; `applied_damage` is the actual health
## delta and is therefore capped at the target's remaining health.
var request: DamageRequest = null
var accepted: bool = false
var rejection_reason: int = CombatTypes.DamageRejectionReason.NONE
var requested_amount: int = 0
var adjusted_amount: int = 0
var mitigated_damage: int = 0
var resolved_damage: int = 0
var applied_damage: int = 0
var health_before: int = 0
var health_after: int = 0
var lethal: bool = false
var requested_hit_count: int = 0
var accepted_hit_count: int = 0


static func rejected(
	damage_request: DamageRequest,
	reason: int,
	current_health: int = 0
) -> DamageResult:
	var result := DamageResult.new()
	result.request = damage_request
	result.rejection_reason = reason
	if damage_request is DamageBatchRequest:
		var batch_request := damage_request as DamageBatchRequest
		result.requested_amount = batch_request.get_requested_amount()
		result.requested_hit_count = batch_request.get_requested_hit_count()
	elif damage_request != null:
		result.requested_amount = damage_request.amount
		result.requested_hit_count = 1 if damage_request.amount > 0 else 0
	result.health_before = maxi(current_health, 0)
	result.health_after = result.health_before
	return result


func is_rejected_for(reason: int) -> bool:
	return not accepted and rejection_reason == reason
