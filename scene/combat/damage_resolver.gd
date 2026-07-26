extends RefCounted
class_name DamageResolver

## Pure numeric damage resolution. This class deliberately owns no Nodes,
## signals, random rolls, visuals, death lifecycle or networking.


static func resolve(
	request: DamageRequest,
	target: DamageTargetProfile
) -> DamageResult:
	if request is DamageBatchRequest:
		return _resolve_batch(request as DamageBatchRequest, target)
	if request == null or target == null:
		return DamageResult.rejected(
			request,
			CombatTypes.DamageRejectionReason.INVALID_REQUEST,
			target.current_health if target != null else 0
		)
	if request.amount <= 0:
		return DamageResult.rejected(
			request,
			CombatTypes.DamageRejectionReason.INVALID_AMOUNT,
			target.current_health
		)
	if target.current_health <= 0:
		return DamageResult.rejected(
			request,
			CombatTypes.DamageRejectionReason.TARGET_DEAD,
			target.current_health
		)

	var result := _new_accepted_result(request, target.current_health)
	result.requested_amount = request.amount
	result.requested_hit_count = 1
	result.accepted_hit_count = 1
	result.adjusted_amount = _apply_multiplier(
		request.amount,
		target.pre_mitigation_multiplier,
		target.pre_multiplier_rounding,
		target.minimum_damage
	)
	result.mitigated_damage = _mitigate_base_damage(
		result.adjusted_amount,
		request.damage_type,
		target.physical_defense,
		target.magic_defense,
		target.minimum_damage,
		request.has_flag(CombatTypes.DamageFlag.BYPASS_MITIGATION)
	)
	result.resolved_damage = _apply_multiplier(
		result.mitigated_damage,
		target.post_mitigation_multiplier,
		target.post_multiplier_rounding,
		target.minimum_damage
	)
	_finalize_health_delta(result)
	return result


static func _resolve_batch(
	request: DamageBatchRequest,
	target: DamageTargetProfile
) -> DamageResult:
	if request == null or target == null:
		return DamageResult.rejected(
			request,
			CombatTypes.DamageRejectionReason.INVALID_REQUEST,
			target.current_health if target != null else 0
		)
	if target.current_health <= 0:
		return DamageResult.rejected(
			request,
			CombatTypes.DamageRejectionReason.TARGET_DEAD,
			target.current_health
		)
	var group_count := request.get_group_count()
	if group_count <= 0:
		return DamageResult.rejected(
			request,
			CombatTypes.DamageRejectionReason.INVALID_AMOUNT,
			target.current_health
		)

	var result := _new_accepted_result(request, target.current_health)
	# "Requested" describes the complete valid input intent, independent of the
	# point at which ordered execution becomes lethal. "Accepted" remains the
	# actually consumed prefix and therefore may be smaller.
	for group_index in range(group_count):
		var raw_damage := request.damage_amounts[group_index]
		var requested_count := request.hit_counts[group_index]
		if raw_damage <= 0 or requested_count <= 0:
			continue
		result.requested_amount += raw_damage * requested_count
		result.requested_hit_count += requested_count

	var remaining_health := target.current_health
	for group_index in range(group_count):
		var raw_damage := request.damage_amounts[group_index]
		var requested_count := request.hit_counts[group_index]
		if raw_damage <= 0 or requested_count <= 0:
			continue
		var adjusted_per_hit := _apply_multiplier(
			raw_damage,
			target.pre_mitigation_multiplier,
			target.pre_multiplier_rounding,
			target.minimum_damage
		)
		var mitigated_per_hit := _mitigate_base_damage(
			adjusted_per_hit,
			request.damage_type,
			target.physical_defense,
			target.magic_defense,
			target.minimum_damage,
			request.has_flag(CombatTypes.DamageFlag.BYPASS_MITIGATION)
		)
		var resolved_per_hit := _apply_multiplier(
			mitigated_per_hit,
			target.post_mitigation_multiplier,
			target.post_multiplier_rounding,
			target.minimum_damage
		)
		if resolved_per_hit <= 0:
			continue
		var hits_until_lethal := ceili(
			float(remaining_health) / float(resolved_per_hit)
		)
		var accepted_count := mini(requested_count, hits_until_lethal)
		result.accepted_hit_count += accepted_count
		result.adjusted_amount += adjusted_per_hit * accepted_count
		result.mitigated_damage += mitigated_per_hit * accepted_count
		result.resolved_damage += resolved_per_hit * accepted_count
		remaining_health = maxi(
			remaining_health - resolved_per_hit * accepted_count,
			0
		)
		if remaining_health <= 0:
			break

	if result.accepted_hit_count <= 0:
		return DamageResult.rejected(
			request,
			CombatTypes.DamageRejectionReason.INVALID_AMOUNT,
			target.current_health
		)
	_finalize_health_delta(result)
	return result


static func _new_accepted_result(
	request: DamageRequest,
	health_before: int
) -> DamageResult:
	var result := DamageResult.new()
	result.request = request
	result.accepted = true
	result.health_before = maxi(health_before, 0)
	result.health_after = result.health_before
	return result


static func _finalize_health_delta(result: DamageResult) -> void:
	result.applied_damage = mini(result.resolved_damage, result.health_before)
	result.health_after = maxi(result.health_before - result.applied_damage, 0)
	result.lethal = result.applied_damage > 0 and result.health_after <= 0
	if result.applied_damage <= 0:
		result.accepted = false
		result.rejection_reason = CombatTypes.DamageRejectionReason.INVALID_AMOUNT


static func _mitigate_base_damage(
	amount: int,
	damage_type: int,
	physical_defense: int,
	magic_defense: int,
	minimum_damage: int,
	bypass_mitigation: bool
) -> int:
	var safe_minimum := maxi(minimum_damage, 0)
	if bypass_mitigation:
		return maxi(amount, safe_minimum)
	if CombatTypes.normalize_damage_type(damage_type) == CombatTypes.DamageType.MAGIC:
		var defense_ratio := float(100 - clampi(magic_defense, 0, 100)) / 100.0
		return maxi(floori(float(amount) * defense_ratio), safe_minimum)
	return maxi(amount - maxi(physical_defense, 0), safe_minimum)


static func _apply_multiplier(
	amount: int,
	multiplier: float,
	rounding_mode: int,
	minimum_damage: int
) -> int:
	if is_equal_approx(multiplier, 1.0):
		return maxi(amount, minimum_damage)
	var scaled := float(amount) * maxf(multiplier, 0.0)
	var rounded := 0
	match rounding_mode:
		CombatTypes.RoundingMode.FLOOR:
			rounded = floori(scaled)
		CombatTypes.RoundingMode.CEIL:
			rounded = ceili(scaled)
		_:
			rounded = roundi(scaled)
	return maxi(rounded, minimum_damage)
