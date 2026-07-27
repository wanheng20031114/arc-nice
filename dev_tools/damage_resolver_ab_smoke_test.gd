extends SceneTree

## Pure damage-domain regression test. The reference functions below intentionally
## duplicate the legacy Player / Enemy / Plant arithmetic instead of calling any
## DamageResolver helper, so this remains a genuine A/B comparison.

const RANDOM_MATRIX_SEED := 20260726
const RANDOM_CASES_PER_TARGET := 1000
const RANDOM_BATCH_CASES := 400
const MAX_REPORTED_FAILURES := 80

const TARGET_PLAYER := &"player"
const TARGET_ENEMY := &"enemy"
const TARGET_PLANT := &"plant"

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_table_driven_legacy_equivalence()
	_test_seeded_legacy_equivalence_matrix()
	_test_health_delta_and_overkill_contract()
	_test_batch_table_contract()
	_test_signed_int64_batch_contract()
	_test_seeded_batch_sequential_equivalence()

	if failures.is_empty():
		print(
			"DAMAGE_RESOLVER_AB_SMOKE_TEST_OK seed=%d scalar_cases=%d batch_cases=%d"
			% [
				RANDOM_MATRIX_SEED,
				RANDOM_CASES_PER_TARGET * 3,
				RANDOM_BATCH_CASES,
			]
		)
		quit(0)
		return

	print(
		"DAMAGE_RESOLVER_AB_SMOKE_TEST_FAILED seed=%d failures=%d"
		% [RANDOM_MATRIX_SEED, failures.size()]
	)
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_table_driven_legacy_equivalence() -> void:
	var cases: Array[Dictionary] = [
		{
			"label": "plant physical baseline",
			"target": TARGET_PLANT,
			"amount": 48,
			"health": 100,
			"physical_defense": 0,
			"magic_defense": 0,
			"damage_type": CombatTypes.DamageType.PHYSICAL,
			"pre": 1.0,
			"post": 1.0,
		},
		{
			"label": "plant physical flat defense",
			"target": TARGET_PLANT,
			"amount": 48,
			"health": 100,
			"physical_defense": 17,
			"magic_defense": 0,
			"damage_type": CombatTypes.DamageType.PHYSICAL,
			"pre": 1.0,
			"post": 1.0,
		},
		{
			"label": "plant physical defense floor",
			"target": TARGET_PLANT,
			"amount": 8,
			"health": 100,
			"physical_defense": 999,
			"magic_defense": 0,
			"damage_type": CombatTypes.DamageType.PHYSICAL,
			"pre": 1.0,
			"post": 1.0,
		},
		{
			"label": "plant magic floor before minimum",
			"target": TARGET_PLANT,
			"amount": 33,
			"health": 100,
			"physical_defense": 0,
			"magic_defense": 33,
			"damage_type": CombatTypes.DamageType.MAGIC,
			"pre": 1.0,
			"post": 1.0,
		},
		{
			"label": "plant magic defense 100 minimum one",
			"target": TARGET_PLANT,
			"amount": 999,
			"health": 100,
			"physical_defense": 0,
			"magic_defense": 100,
			"damage_type": CombatTypes.DamageType.MAGIC,
			"pre": 1.0,
			"post": 1.0,
		},
		{
			"label": "player ranged pre nearest",
			"target": TARGET_PLAYER,
			"amount": 13,
			"health": 100,
			"physical_defense": 2,
			"magic_defense": 0,
			"damage_type": CombatTypes.DamageType.PHYSICAL,
			"pre": 0.6,
			"post": 1.0,
		},
		{
			"label": "player strongest reduction post floor",
			"target": TARGET_PLAYER,
			"amount": 31,
			"health": 100,
			"physical_defense": 4,
			"magic_defense": 0,
			"damage_type": CombatTypes.DamageType.PHYSICAL,
			"pre": 1.0,
			"post": 0.75,
		},
		{
			"label": "player pre nearest magic then reduction floor",
			"target": TARGET_PLAYER,
			"amount": 37,
			"health": 100,
			"physical_defense": 0,
			"magic_defense": 27,
			"damage_type": CombatTypes.DamageType.MAGIC,
			"pre": 1.15,
			"post": 0.55,
		},
		{
			"label": "player zero post multiplier still minimum one",
			"target": TARGET_PLAYER,
			"amount": 400,
			"health": 100,
			"physical_defense": 0,
			"magic_defense": 0,
			"damage_type": CombatTypes.DamageType.PHYSICAL,
			"pre": 1.0,
			"post": 0.0,
		},
		{
			"label": "enemy incoming multiplier post nearest",
			"target": TARGET_ENEMY,
			"amount": 17,
			"health": 100,
			"physical_defense": 3,
			"magic_defense": 0,
			"damage_type": CombatTypes.DamageType.PHYSICAL,
			"pre": 1.0,
			"post": 1.4,
		},
		{
			"label": "enemy debuff post nearest and minimum one",
			"target": TARGET_ENEMY,
			"amount": 3,
			"health": 100,
			"physical_defense": 2,
			"magic_defense": 0,
			"damage_type": CombatTypes.DamageType.PHYSICAL,
			"pre": 1.0,
			"post": 0.25,
		},
		{
			"label": "enemy overkill reports resolved and capped applied",
			"target": TARGET_ENEMY,
			"amount": 250,
			"health": 19,
			"physical_defense": 0,
			"magic_defense": 0,
			"damage_type": CombatTypes.DamageType.PHYSICAL,
			"pre": 1.0,
			"post": 1.5,
		},
	]

	for case_data in cases:
		_compare_scalar_case(case_data, "table/%s" % case_data["label"])


func _test_seeded_legacy_equivalence_matrix() -> void:
	var target_kinds: Array[StringName] = [
		TARGET_PLAYER,
		TARGET_ENEMY,
		TARGET_PLANT,
	]
	for target_index in target_kinds.size():
		var target_kind := target_kinds[target_index]
		for sample_index in range(RANDOM_CASES_PER_TARGET):
			if failures.size() >= MAX_REPORTED_FAILURES:
				return
			var replay_seed := (
				RANDOM_MATRIX_SEED
				+ target_index * 1_000_003
				+ sample_index * 7_919
			)
			var rng := RandomNumberGenerator.new()
			rng.seed = replay_seed
			var case_data := _make_random_scalar_case(rng, target_kind)
			var context := (
				"random_scalar target=%s sample=%d replay_seed=%d input=%s"
				% [target_kind, sample_index, replay_seed, _format_scalar_case(case_data)]
			)
			_compare_scalar_case(case_data, context)


func _test_health_delta_and_overkill_contract() -> void:
	var request := DamageRequest.new(999, CombatTypes.DamageType.MAGIC)
	var profile := DamageTargetProfile.new(7, 200, 100)
	profile.pre_mitigation_multiplier = 3.0
	profile.post_mitigation_multiplier = 4.0
	var result := DamageResolver.resolve(request, profile)
	_expect(
		result.accepted,
		"invariant/defense_minimum: a positive hit against a living target must be accepted"
	)
	_expect(
		result.applied_damage == result.health_before - result.health_after,
		"invariant/defense_minimum: applied_damage must equal health delta"
	)
	_expect(
		result.applied_damage <= result.health_before,
		"invariant/defense_minimum: applied damage must be capped by health_before"
	)

	request = DamageRequest.new(99, CombatTypes.DamageType.PHYSICAL)
	profile = DamageTargetProfile.new(5, 0, 0)
	result = DamageResolver.resolve(request, profile)
	_expect(
		result.resolved_damage == 99
		and result.applied_damage == 5
		and result.health_after == 0
		and result.lethal,
		"invariant/overkill: resolved damage stays 99 while applied damage caps to 5"
	)
	_expect(
		result.applied_damage == result.health_before - result.health_after,
		"invariant/overkill: applied_damage must exactly equal health delta"
	)

	var invalid_result := DamageResolver.resolve(
		DamageRequest.new(0, CombatTypes.DamageType.PHYSICAL),
		DamageTargetProfile.new(25, 0, 0)
	)
	_expect(
		not invalid_result.accepted
		and invalid_result.rejection_reason
		== CombatTypes.DamageRejectionReason.INVALID_AMOUNT
		and invalid_result.applied_damage == 0
		and invalid_result.health_before == invalid_result.health_after,
		"invariant/invalid_amount: invalid hit must preserve health and explain rejection"
	)

	var dead_result := DamageResolver.resolve(
		DamageRequest.new(1, CombatTypes.DamageType.PHYSICAL),
		DamageTargetProfile.new(0, 0, 0)
	)
	_expect(
		not dead_result.accepted
		and dead_result.rejection_reason
		== CombatTypes.DamageRejectionReason.TARGET_DEAD
		and dead_result.applied_damage == 0,
		"invariant/dead_target: dead target must reject without an applied delta"
	)


func _test_batch_table_contract() -> void:
	var cases: Array[Dictionary] = [
		{
			"label": "invalid groups are skipped without reordering valid hits",
			"amounts": PackedInt64Array([-4, 10, 0, 8]),
			"counts": PackedInt32Array([3, 2, 5, 0]),
			"health": 100,
			"physical_defense": 2,
			"magic_defense": 0,
			"damage_type": CombatTypes.DamageType.PHYSICAL,
			"pre": 1.0,
			"post": 1.0,
			"rounding": CombatTypes.RoundingMode.NEAREST,
		},
		{
			"label": "lethal hit stops later groups",
			"amounts": PackedInt64Array([8, 50]),
			"counts": PackedInt32Array([10, 2]),
			"health": 20,
			"physical_defense": 0,
			"magic_defense": 0,
			"damage_type": CombatTypes.DamageType.PHYSICAL,
			"pre": 1.0,
			"post": 1.0,
			"rounding": CombatTypes.RoundingMode.NEAREST,
		},
		{
			"label": "array length mismatch uses paired prefix",
			"amounts": PackedInt64Array([5, 7, 100]),
			"counts": PackedInt32Array([2, 1]),
			"health": 100,
			"physical_defense": 1,
			"magic_defense": 0,
			"damage_type": CombatTypes.DamageType.PHYSICAL,
			"pre": 1.0,
			"post": 1.0,
			"rounding": CombatTypes.RoundingMode.NEAREST,
		},
		{
			"label": "all invalid groups reject",
			"amounts": PackedInt64Array([0, -5, 12]),
			"counts": PackedInt32Array([3, 1, 0]),
			"health": 100,
			"physical_defense": 0,
			"magic_defense": 0,
			"damage_type": CombatTypes.DamageType.PHYSICAL,
			"pre": 1.0,
			"post": 1.0,
			"rounding": CombatTypes.RoundingMode.NEAREST,
		},
		{
			"label": "dead target rejects before reading groups",
			"amounts": PackedInt64Array([10]),
			"counts": PackedInt32Array([1]),
			"health": 0,
			"physical_defense": 0,
			"magic_defense": 0,
			"damage_type": CombatTypes.DamageType.PHYSICAL,
			"pre": 1.0,
			"post": 1.0,
			"rounding": CombatTypes.RoundingMode.NEAREST,
		},
	]

	for case_data in cases:
		_compare_batch_case(case_data, "table_batch/%s" % case_data["label"])
	var lethal_intent_result := _resolve_batch_case(cases[1])
	_expect(
		lethal_intent_result.requested_amount == 180
		and lethal_intent_result.requested_hit_count == 12
		and lethal_intent_result.accepted_hit_count == 3
		and lethal_intent_result.request is DamageBatchRequest,
		(
			"table_batch/lethal_intent: requested totals must describe all valid "
			+ "input while accepted hits stop at the lethal ordered prefix, and the "
			+ "result must retain the replayable batch request"
		)
	)
	var zero_minimum_request := DamageBatchRequest.new(
		PackedInt64Array([5]),
		PackedInt32Array([2]),
		CombatTypes.DamageType.PHYSICAL
	)
	var zero_minimum_profile := DamageTargetProfile.new(100, 0, 0)
	zero_minimum_profile.minimum_damage = 0
	zero_minimum_profile.post_mitigation_multiplier = 0.0
	var zero_minimum_result := DamageResolver.resolve(
		zero_minimum_request,
		zero_minimum_profile
	)
	_expect(
		not zero_minimum_result.accepted
		and zero_minimum_result.rejection_reason
			== CombatTypes.DamageRejectionReason.INVALID_AMOUNT
		and zero_minimum_result.requested_amount == 10
		and zero_minimum_result.requested_hit_count == 2,
		"table_batch/zero_minimum: zero resolved damage must reject without division by zero while retaining intent"
	)

	var early_heavy := {
		"amounts": PackedInt64Array([20, 3]),
		"counts": PackedInt32Array([1, 10]),
		"health": 25,
		"physical_defense": 0,
		"magic_defense": 0,
		"damage_type": CombatTypes.DamageType.PHYSICAL,
		"pre": 1.0,
		"post": 1.0,
		"rounding": CombatTypes.RoundingMode.NEAREST,
	}
	var early_light := early_heavy.duplicate(true)
	early_light["amounts"] = PackedInt64Array([3, 20])
	early_light["counts"] = PackedInt32Array([10, 1])
	var heavy_result := _resolve_batch_case(early_heavy)
	var light_result := _resolve_batch_case(early_light)
	_expect(
		heavy_result.accepted_hit_count == 3
		and light_result.accepted_hit_count == 9,
		"table_batch/order: batch traversal must preserve group order; expected accepted hits 3 vs 9"
	)
	_compare_batch_case(early_heavy, "table_batch/order_heavy_first")
	_compare_batch_case(early_light, "table_batch/order_light_first")


func _test_signed_int64_batch_contract() -> void:
	var runtime_request := DamageBatchRequest.new(
		PackedInt64Array([3_000_000_000]),
		PackedInt32Array([2]),
		CombatTypes.DamageType.PHYSICAL
	)
	_expect(
		runtime_request.damage_amounts is PackedInt64Array
		and runtime_request.damage_amounts[0] == 3_000_000_000
		and runtime_request.get_requested_amount() == 6_000_000_000,
		"Runtime damage batches must retain signed-int64 amounts without PackedInt32 wrapping."
	)
	var runtime_result := DamageResolver.resolve(
		runtime_request,
		DamageTargetProfile.new(6_000_000_000, 0, 0)
	)
	_expect(
		runtime_result.accepted
		and runtime_result.requested_amount == 6_000_000_000
		and runtime_result.resolved_damage == 6_000_000_000
		and runtime_result.applied_damage == 6_000_000_000
		and runtime_result.health_after == 0,
		"Damage settlement intermediates and runtime health must remain signed int64."
	)

	var int32_boundary_request := DamageBatchRequest.new(
		PackedInt64Array([0x7FFFFFFF]),
		PackedInt32Array([0x7FFFFFFF]),
		CombatTypes.DamageType.PHYSICAL
	)
	_expect(
		int32_boundary_request.get_requested_amount() == 4_611_686_014_132_420_609,
		"The maximum fixed-width damage and hit-count product must remain positive int64."
	)


func _test_seeded_batch_sequential_equivalence() -> void:
	for sample_index in range(RANDOM_BATCH_CASES):
		if failures.size() >= MAX_REPORTED_FAILURES:
			return
		var replay_seed := RANDOM_MATRIX_SEED + 9_000_001 + sample_index * 104_729
		var rng := RandomNumberGenerator.new()
		rng.seed = replay_seed
		var group_count := rng.randi_range(0, 8)
		var amounts := PackedInt64Array()
		var counts := PackedInt32Array()
		for _group_index in range(group_count):
			amounts.append(rng.randi_range(-4, 160))
			counts.append(rng.randi_range(-2, 12))
		if rng.randi_range(0, 3) == 0 and not counts.is_empty():
			counts.resize(counts.size() - 1)
		var rounding := (
			CombatTypes.RoundingMode.FLOOR
			if rng.randi_range(0, 1) == 0
			else CombatTypes.RoundingMode.NEAREST
		)
		var case_data := {
			"amounts": amounts,
			"counts": counts,
			"health": rng.randi_range(0, 600),
			"physical_defense": rng.randi_range(-20, 180),
			"magic_defense": rng.randi_range(-20, 120),
			"damage_type": rng.randi_range(-1, 2),
			"pre": _pick_multiplier(rng, true),
			"post": _pick_multiplier(rng, false),
			"rounding": rounding,
		}
		var context := (
			"random_batch sample=%d replay_seed=%d input=%s"
			% [sample_index, replay_seed, _format_batch_case(case_data)]
		)
		_compare_batch_case(case_data, context)


func _make_random_scalar_case(
	rng: RandomNumberGenerator,
	target_kind: StringName
) -> Dictionary:
	var pre_multiplier := 1.0
	var post_multiplier := 1.0
	if target_kind == TARGET_PLAYER:
		pre_multiplier = _pick_multiplier(rng, true)
		post_multiplier = _pick_player_reduction_multiplier(rng)
	elif target_kind == TARGET_ENEMY:
		post_multiplier = _pick_multiplier(rng, false)
	return {
		"target": target_kind,
		"amount": rng.randi_range(1, 700),
		"health": rng.randi_range(1, 600),
		"physical_defense": rng.randi_range(-20, 720),
		"magic_defense": rng.randi_range(-20, 120),
		"damage_type": rng.randi_range(-1, 2),
		"pre": pre_multiplier,
		"post": post_multiplier,
	}


func _compare_scalar_case(case_data: Dictionary, context: String) -> void:
	var request := DamageRequest.new(
		int(case_data["amount"]),
		int(case_data["damage_type"])
	)
	var profile := _make_profile(case_data)
	var result := DamageResolver.resolve(request, profile)
	var expected := _legacy_scalar(case_data)

	_compare_result_field(result.accepted, expected["accepted"], "accepted", context)
	_compare_result_field(
		result.rejection_reason,
		expected["rejection_reason"],
		"rejection_reason",
		context
	)
	_compare_result_field(result.requested_amount, expected["requested_amount"], "requested_amount", context)
	_compare_result_field(result.adjusted_amount, expected["adjusted_amount"], "adjusted_amount", context)
	_compare_result_field(result.mitigated_damage, expected["mitigated_damage"], "mitigated_damage", context)
	_compare_result_field(result.resolved_damage, expected["resolved_damage"], "resolved_damage", context)
	_compare_result_field(result.applied_damage, expected["applied_damage"], "applied_damage", context)
	_compare_result_field(result.health_before, expected["health_before"], "health_before", context)
	_compare_result_field(result.health_after, expected["health_after"], "health_after", context)
	_compare_result_field(result.lethal, expected["lethal"], "lethal", context)
	_compare_result_field(result.requested_hit_count, expected["requested_hit_count"], "requested_hit_count", context)
	_compare_result_field(result.accepted_hit_count, expected["accepted_hit_count"], "accepted_hit_count", context)
	_expect(
		result.applied_damage == result.health_before - result.health_after,
		"%s field=health_delta expected=%d actual=%d"
		% [context, result.applied_damage, result.health_before - result.health_after]
	)
	_expect(
		result.applied_damage <= result.health_before,
		"%s field=overkill_cap health_before=%d applied=%d"
		% [context, result.health_before, result.applied_damage]
	)


func _compare_batch_case(case_data: Dictionary, context: String) -> void:
	var result := _resolve_batch_case(case_data)
	var expected := _legacy_batch(case_data)
	_compare_result_field(result.accepted, expected["accepted"], "accepted", context)
	_compare_result_field(
		result.rejection_reason,
		expected["rejection_reason"],
		"rejection_reason",
		context
	)
	_compare_result_field(result.requested_amount, expected["requested_amount"], "requested_amount", context)
	_compare_result_field(result.adjusted_amount, expected["adjusted_amount"], "adjusted_amount", context)
	_compare_result_field(result.mitigated_damage, expected["mitigated_damage"], "mitigated_damage", context)
	_compare_result_field(result.resolved_damage, expected["resolved_damage"], "resolved_damage", context)
	_compare_result_field(result.applied_damage, expected["applied_damage"], "applied_damage", context)
	_compare_result_field(result.health_before, expected["health_before"], "health_before", context)
	_compare_result_field(result.health_after, expected["health_after"], "health_after", context)
	_compare_result_field(result.lethal, expected["lethal"], "lethal", context)
	_compare_result_field(result.requested_hit_count, expected["requested_hit_count"], "requested_hit_count", context)
	_compare_result_field(result.accepted_hit_count, expected["accepted_hit_count"], "accepted_hit_count", context)
	_expect(
		result.applied_damage == result.health_before - result.health_after,
		"%s field=health_delta expected=%d actual=%d"
		% [context, result.applied_damage, result.health_before - result.health_after]
	)
	_expect(
		result.applied_damage <= result.health_before,
		"%s field=overkill_cap health_before=%d applied=%d"
		% [context, result.health_before, result.applied_damage]
	)


func _resolve_batch_case(case_data: Dictionary) -> DamageResult:
	var request := DamageBatchRequest.new(
		case_data["amounts"] as PackedInt64Array,
		case_data["counts"] as PackedInt32Array,
		int(case_data["damage_type"])
	)
	var profile := _make_profile(case_data)
	profile.post_multiplier_rounding = int(case_data["rounding"])
	return DamageResolver.resolve(request, profile)


func _make_profile(case_data: Dictionary) -> DamageTargetProfile:
	var profile := DamageTargetProfile.new(
		int(case_data["health"]),
		int(case_data["physical_defense"]),
		int(case_data["magic_defense"])
	)
	# Assign the raw values after construction as a boundary test: the resolver,
	# not callers, owns normalization of defense values.
	profile.physical_defense = int(case_data["physical_defense"])
	profile.magic_defense = int(case_data["magic_defense"])
	profile.pre_mitigation_multiplier = float(case_data["pre"])
	profile.pre_multiplier_rounding = CombatTypes.RoundingMode.NEAREST
	profile.post_mitigation_multiplier = float(case_data["post"])
	profile.post_multiplier_rounding = (
		CombatTypes.RoundingMode.FLOOR
		if case_data.get("target", TARGET_ENEMY) == TARGET_PLAYER
		else CombatTypes.RoundingMode.NEAREST
	)
	return profile


func _legacy_scalar(case_data: Dictionary) -> Dictionary:
	var health_before := maxi(int(case_data["health"]), 0)
	var amount := int(case_data["amount"])
	if amount <= 0:
		return _legacy_rejected(
			CombatTypes.DamageRejectionReason.INVALID_AMOUNT,
			health_before,
			amount
		)
	if health_before <= 0:
		return _legacy_rejected(
			CombatTypes.DamageRejectionReason.TARGET_DEAD,
			health_before,
			amount
		)

	var rounding := (
		CombatTypes.RoundingMode.FLOOR
		if case_data["target"] == TARGET_PLAYER
		else CombatTypes.RoundingMode.NEAREST
	)
	var stages := _legacy_stages(
		amount,
		int(case_data["damage_type"]),
		int(case_data["physical_defense"]),
		int(case_data["magic_defense"]),
		float(case_data["pre"]),
		float(case_data["post"]),
		rounding
	)
	var applied := mini(int(stages["resolved"]), health_before)
	var health_after := maxi(health_before - applied, 0)
	return {
		"accepted": true,
		"rejection_reason": CombatTypes.DamageRejectionReason.NONE,
		"requested_amount": amount,
		"adjusted_amount": stages["adjusted"],
		"mitigated_damage": stages["mitigated"],
		"resolved_damage": stages["resolved"],
		"applied_damage": applied,
		"health_before": health_before,
		"health_after": health_after,
		"lethal": applied > 0 and health_after <= 0,
		"requested_hit_count": 1,
		"accepted_hit_count": 1,
	}


func _legacy_batch(case_data: Dictionary) -> Dictionary:
	var health_before := maxi(int(case_data["health"]), 0)
	var amounts := case_data["amounts"] as PackedInt64Array
	var counts := case_data["counts"] as PackedInt32Array
	var group_count := mini(amounts.size(), counts.size())
	var requested_amount := 0
	var requested_hit_count := 0
	for group_index in range(group_count):
		var raw_amount := amounts[group_index]
		var requested_count := counts[group_index]
		if raw_amount <= 0 or requested_count <= 0:
			continue
		requested_amount += raw_amount * requested_count
		requested_hit_count += requested_count
	if health_before <= 0:
		return _legacy_rejected(
			CombatTypes.DamageRejectionReason.TARGET_DEAD,
			health_before,
			requested_amount,
			requested_hit_count
		)
	if group_count <= 0:
		return _legacy_rejected(
			CombatTypes.DamageRejectionReason.INVALID_AMOUNT,
			health_before,
			requested_amount,
			requested_hit_count
		)

	var expected := {
		"accepted": true,
		"rejection_reason": CombatTypes.DamageRejectionReason.NONE,
		"requested_amount": requested_amount,
		"adjusted_amount": 0,
		"mitigated_damage": 0,
		"resolved_damage": 0,
		"applied_damage": 0,
		"health_before": health_before,
		"health_after": health_before,
		"lethal": false,
		"requested_hit_count": requested_hit_count,
		"accepted_hit_count": 0,
	}
	var remaining_health := health_before
	for group_index in range(group_count):
		var raw_amount := amounts[group_index]
		var requested_count := counts[group_index]
		if raw_amount <= 0 or requested_count <= 0:
			continue
		var stages := _legacy_stages(
			raw_amount,
			int(case_data["damage_type"]),
			int(case_data["physical_defense"]),
			int(case_data["magic_defense"]),
			float(case_data["pre"]),
			float(case_data["post"]),
			int(case_data["rounding"])
		)
		for _hit_index in range(requested_count):
			if remaining_health <= 0:
				break
			expected["accepted_hit_count"] += 1
			expected["adjusted_amount"] += int(stages["adjusted"])
			expected["mitigated_damage"] += int(stages["mitigated"])
			expected["resolved_damage"] += int(stages["resolved"])
			remaining_health = maxi(
				remaining_health - int(stages["resolved"]),
				0
			)
		if remaining_health <= 0:
			break

	if int(expected["accepted_hit_count"]) <= 0:
		return _legacy_rejected(
			CombatTypes.DamageRejectionReason.INVALID_AMOUNT,
			health_before,
			requested_amount,
			requested_hit_count
		)
	expected["applied_damage"] = mini(
		int(expected["resolved_damage"]),
		health_before
	)
	expected["health_after"] = maxi(
		health_before - int(expected["applied_damage"]),
		0
	)
	expected["lethal"] = (
		int(expected["applied_damage"]) > 0
		and int(expected["health_after"]) <= 0
	)
	return expected


func _legacy_stages(
	amount: int,
	damage_type: int,
	physical_defense: int,
	magic_defense: int,
	pre_multiplier: float,
	post_multiplier: float,
	post_rounding: int
) -> Dictionary:
	# Player directional ranged modifiers used roundi before defense.
	var adjusted := maxi(roundi(float(amount) * maxf(pre_multiplier, 0.0)), 1)
	var mitigated := 0
	if damage_type == CombatTypes.DamageType.MAGIC:
		# Player, Enemy and Plant all floor percentage magic mitigation.
		var defense_ratio := float(100 - clampi(magic_defense, 0, 100)) / 100.0
		mitigated = maxi(floori(float(adjusted) * defense_ratio), 1)
	else:
		# Player, Enemy and Plant all subtract physical defense as a flat value.
		mitigated = maxi(adjusted - maxi(physical_defense, 0), 1)
	var scaled_post := float(mitigated) * maxf(post_multiplier, 0.0)
	var resolved := (
		floori(scaled_post)
		if post_rounding == CombatTypes.RoundingMode.FLOOR
		else roundi(scaled_post)
	)
	return {
		"adjusted": adjusted,
		"mitigated": mitigated,
		"resolved": maxi(resolved, 1),
	}


func _legacy_rejected(
	reason: int,
	health: int,
	requested_amount: int,
	requested_hit_count: int = -1
) -> Dictionary:
	var resolved_requested_hit_count := requested_hit_count
	if resolved_requested_hit_count < 0:
		resolved_requested_hit_count = 1 if requested_amount > 0 else 0
	return {
		"accepted": false,
		"rejection_reason": reason,
		"requested_amount": requested_amount,
		"adjusted_amount": 0,
		"mitigated_damage": 0,
		"resolved_damage": 0,
		"applied_damage": 0,
		"health_before": health,
		"health_after": health,
		"lethal": false,
		"requested_hit_count": resolved_requested_hit_count,
		"accepted_hit_count": 0,
	}


func _pick_multiplier(rng: RandomNumberGenerator, include_directional: bool) -> float:
	var choices: Array[float] = [0.0, 0.05, 0.25, 0.55, 0.75, 1.0, 1.15, 1.4, 1.5, 2.0]
	if include_directional:
		choices.append_array([0.6, 0.85, 1.25])
	return choices[rng.randi_range(0, choices.size() - 1)]


func _pick_player_reduction_multiplier(rng: RandomNumberGenerator) -> float:
	var choices: Array[float] = [0.0, 0.05, 0.25, 0.5, 0.75, 0.9, 0.95, 1.0]
	return choices[rng.randi_range(0, choices.size() - 1)]


func _compare_result_field(actual: Variant, expected: Variant, field: String, context: String) -> void:
	_expect(
		actual == expected,
		"%s field=%s expected=%s actual=%s" % [context, field, str(expected), str(actual)]
	)


func _format_scalar_case(case_data: Dictionary) -> String:
	return (
		"{amount=%d health=%d pdef=%d mdef=%d type=%d pre=%.3f post=%.3f}"
		% [
			case_data["amount"],
			case_data["health"],
			case_data["physical_defense"],
			case_data["magic_defense"],
			case_data["damage_type"],
			case_data["pre"],
			case_data["post"],
		]
	)


func _format_batch_case(case_data: Dictionary) -> String:
	return (
		"{amounts=%s counts=%s health=%d pdef=%d mdef=%d type=%d pre=%.3f post=%.3f rounding=%d}"
		% [
			str(case_data["amounts"]),
			str(case_data["counts"]),
			case_data["health"],
			case_data["physical_defense"],
			case_data["magic_defense"],
			case_data["damage_type"],
			case_data["pre"],
			case_data["post"],
			case_data["rounding"],
		]
	)


func _expect(condition: bool, message: String) -> void:
	if condition or failures.size() >= MAX_REPORTED_FAILURES:
		return
	failures.append(message)
