extends SceneTree

const EnemyDropRuleScript := preload(
	"res://resources/config/enemies/enemy_drop_rule.gd"
)
const DEFAULT_ENEMY_DROP_TABLE: EnemyDropTable = preload(
	"res://resources/config/enemies/default_enemy_drop_table.tres"
)
const STONE_GOLEM_DROP_TABLE: EnemyDropTable = preload(
	"res://resources/config/enemies/stone_golem_drop_table.tres"
)
const STONE_GOLEM_CONFIG: EnemyConfig = preload(
	"res://resources/config/enemies/stone_golem.tres"
)
const STONE_GOLEM_ELITE_CONFIG: EnemyConfig = preload(
	"res://resources/config/enemies/stone_golem_elite.tres"
)
const WOOD: PickupConfig = preload(
	"res://resources/config/materials/material_wood.tres"
)
const WHITE_CRYSTAL: PickupConfig = preload(
	"res://resources/config/materials/material_white_crystal.tres"
)
const SAPLING: PickupConfig = preload(
	"res://resources/config/materials/material_sapling.tres"
)
const SMALL_STONE: PickupConfig = preload(
	"res://resources/config/materials/material_small_stone.tres"
)

var failures: Array[String] = []


class FixedDamageProxyEnemy:
	extends Enemy

	func _create_damage_target_profile() -> DamageTargetProfile:
		var profile := super()
		profile.fixed_damage_per_accepted_hit = 1.0
		return profile


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_fixed_damage_scalar_contract()
	_test_fixed_damage_batch_contract()
	_test_fixed_damage_authority_contract()
	_test_drop_table_inheritance_contract()

	if failures.is_empty():
		print("FIXED_DAMAGE_DROP_INHERITANCE_SMOKE_TEST_OK")
		quit(0)
		return

	print(
		"FIXED_DAMAGE_DROP_INHERITANCE_SMOKE_TEST_FAILED failures=%d"
		% failures.size()
	)
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_fixed_damage_scalar_contract() -> void:
	var default_result := DamageResolver.resolve(
		DamageRequest.new(20, CombatTypes.DamageType.PHYSICAL),
		DamageTargetProfile.new(100, 3, 0)
	)
	_expect(
		default_result.accepted
		and default_result.resolved_damage == 17
		and default_result.applied_damage == 17,
		"The default zero fixed-damage value must preserve ordinary resolution."
	)

	var physical_profile := _fixed_profile(10, 5, 0)
	_assert_fixed_scalar(
		"physical",
		DamageRequest.new(12, CombatTypes.DamageType.PHYSICAL),
		physical_profile,
		12,
		7
	)
	var magic_profile := _fixed_profile(10, 0, 90)
	_assert_fixed_scalar(
		"magic",
		DamageRequest.new(50, CombatTypes.DamageType.MAGIC),
		magic_profile,
		50,
		5
	)

	var dot_request := DamageRequest.new(
		3,
		CombatTypes.DamageType.PHYSICAL
	)
	dot_request.source_type = &"burn_dot"
	dot_request.with_flag(CombatTypes.DamageFlag.PERIODIC)
	_assert_fixed_scalar(
		"periodic damage",
		dot_request,
		_fixed_profile(10, 0, 0),
		3,
		3
	)

	var explosion_request := DamageRequest.new(
		40,
		CombatTypes.DamageType.PHYSICAL
	)
	explosion_request.source_type = &"mortar_explosion"
	explosion_request.with_flag(CombatTypes.DamageFlag.RANGED)
	_assert_fixed_scalar(
		"explosion",
		explosion_request,
		_fixed_profile(10, 4, 0),
		40,
		36
	)

	var bypass_request := DamageRequest.new(
		40,
		CombatTypes.DamageType.PHYSICAL
	)
	bypass_request.with_flag(CombatTypes.DamageFlag.BYPASS_MITIGATION)
	_assert_fixed_scalar(
		"bypass mitigation",
		bypass_request,
		_fixed_profile(10, 999, 0),
		40,
		40
	)

	var multiplied_profile := _fixed_profile(10, 5, 0)
	multiplied_profile.pre_mitigation_multiplier = 0.5
	multiplied_profile.post_mitigation_multiplier = 0.25
	_assert_fixed_scalar(
		"pre/post multipliers",
		DamageRequest.new(50, CombatTypes.DamageType.PHYSICAL),
		multiplied_profile,
		25,
		20
	)

	var execute_result := DamageResolver.resolve(
		DamageRequest.new(999_999, CombatTypes.DamageType.PHYSICAL),
		_fixed_profile(10, 0, 0)
	)
	_expect(
		execute_result.accepted
		and execute_result.resolved_damage == 1
		and execute_result.applied_damage == 1
		and execute_result.health_after == 9
		and not execute_result.lethal,
		"An execute-sized accepted hit must still resolve to exactly one damage."
	)

	var sequential_profile := _fixed_profile(10, 0, 0)
	for hit_index in range(10):
		var hit_result := DamageResolver.resolve(
			DamageRequest.new(999, CombatTypes.DamageType.PHYSICAL),
			sequential_profile
		)
		_expect(
			hit_result.accepted
			and hit_result.applied_damage == 1
			and hit_result.lethal == (hit_index == 9),
			"Fixed sequential hit %d must deal one and only hit 10 may be lethal."
			% (hit_index + 1)
		)
		sequential_profile.current_health = hit_result.health_after
	_expect(
		sequential_profile.current_health == 0,
		"Ten accepted fixed hits must reduce ten health to zero exactly."
	)

	var zero_result := DamageResolver.resolve(
		DamageRequest.new(0, CombatTypes.DamageType.PHYSICAL),
		_fixed_profile(10, 0, 0)
	)
	_expect(
		zero_result.is_rejected_for(
			CombatTypes.DamageRejectionReason.INVALID_AMOUNT
		)
		and zero_result.applied_damage == 0,
		"Fixed damage must not resurrect a zero or invalid request."
	)
	var dead_result := DamageResolver.resolve(
		DamageRequest.new(20, CombatTypes.DamageType.PHYSICAL),
		_fixed_profile(0, 0, 0)
	)
	_expect(
		dead_result.is_rejected_for(
			CombatTypes.DamageRejectionReason.TARGET_DEAD
		)
		and dead_result.applied_damage == 0,
		"Fixed damage must not affect an already-dead target."
	)
	var null_result := DamageResolver.resolve(
		null,
		_fixed_profile(10, 0, 0)
	)
	_expect(
		null_result.is_rejected_for(
			CombatTypes.DamageRejectionReason.INVALID_REQUEST
		)
		and null_result.applied_damage == 0,
		"Fixed damage must preserve invalid-request rejection."
	)

	var zero_pipeline_profile := _fixed_profile(10, 0, 0)
	zero_pipeline_profile.minimum_damage = 0
	zero_pipeline_profile.post_mitigation_multiplier = 0.0
	var zero_pipeline_result := DamageResolver.resolve(
		DamageRequest.new(20, CombatTypes.DamageType.PHYSICAL),
		zero_pipeline_profile
	)
	_expect(
		zero_pipeline_result.is_rejected_for(
			CombatTypes.DamageRejectionReason.INVALID_AMOUNT
		)
		and zero_pipeline_result.resolved_damage == 0
		and zero_pipeline_result.applied_damage == 0,
		"Fixed damage may replace only a positive result from the normal pipeline."
	)


func _test_fixed_damage_batch_contract() -> void:
	var lethal_batch := DamageBatchRequest.new(
		PackedInt64Array([100, 4]),
		PackedInt32Array([7, 8]),
		CombatTypes.DamageType.PHYSICAL
	)
	var lethal_result := DamageResolver.resolve(
		lethal_batch,
		_fixed_profile(10, 0, 0)
	)
	_expect(
		lethal_result.accepted
		and lethal_result.requested_hit_count == 15
		and lethal_result.accepted_hit_count == 10
		and lethal_result.requested_amount == 732
		and lethal_result.adjusted_amount == 712
		and lethal_result.mitigated_damage == 712
		and lethal_result.resolved_damage == 10
		and lethal_result.applied_damage == 10
		and lethal_result.health_after == 0
		and lethal_result.lethal,
		"Batch settlement must apply fixed damage per ordered hit and stop on hit 10."
	)

	var nonlethal_result := DamageResolver.resolve(
		lethal_batch,
		_fixed_profile(100, 0, 0)
	)
	_expect(
		nonlethal_result.accepted_hit_count == 15
		and nonlethal_result.resolved_damage == 15
		and nonlethal_result.applied_damage == 15
		and nonlethal_result.health_after == 85
		and not nonlethal_result.lethal,
		"A nonlethal batch must consume every valid hit at one damage each."
	)

	var invalid_groups_result := DamageResolver.resolve(
		DamageBatchRequest.new(
			PackedInt64Array([0, -5, 7]),
			PackedInt32Array([3, 2, 4]),
			CombatTypes.DamageType.PHYSICAL
		),
		_fixed_profile(10, 0, 0)
	)
	_expect(
		invalid_groups_result.accepted
		and invalid_groups_result.requested_hit_count == 4
		and invalid_groups_result.accepted_hit_count == 4
		and invalid_groups_result.resolved_damage == 4
		and invalid_groups_result.applied_damage == 4,
		"Invalid batch groups must stay skipped while every valid hit is fixed independently."
	)

	var zero_batch_profile := _fixed_profile(10, 0, 0)
	zero_batch_profile.minimum_damage = 0
	zero_batch_profile.post_mitigation_multiplier = 0.0
	var zero_batch_result := DamageResolver.resolve(
		DamageBatchRequest.new(
			PackedInt64Array([20]),
			PackedInt32Array([5]),
			CombatTypes.DamageType.PHYSICAL
		),
		zero_batch_profile
	)
	_expect(
		zero_batch_result.is_rejected_for(
			CombatTypes.DamageRejectionReason.INVALID_AMOUNT
		)
		and zero_batch_result.accepted_hit_count == 0
		and zero_batch_result.applied_damage == 0,
		"A batch whose ordinary pipeline resolves to zero must remain rejected."
	)


func _test_fixed_damage_authority_contract() -> void:
	var proxy := FixedDamageProxyEnemy.new()
	proxy.current_health = 10
	proxy.is_multiplayer_proxy = true
	var proxy_result := proxy.apply_combat_damage(
		DamageRequest.new(100, CombatTypes.DamageType.PHYSICAL)
	)
	_expect(
		proxy_result.is_rejected_for(
			CombatTypes.DamageRejectionReason.NOT_AUTHORITY
		)
		and proxy_result.applied_damage == 0
		and proxy.current_health == 10,
		"A multiplayer proxy must reject before its fixed-damage profile is resolved."
	)
	proxy.free()


func _test_drop_table_inheritance_contract() -> void:
	var base_table := EnemyDropTable.new()
	var middle_table := EnemyDropTable.new()
	var leaf_table := EnemyDropTable.new()
	var base_rule := _new_drop_rule(WOOD, 1.0)
	var middle_rule := _new_drop_rule(WHITE_CRYSTAL, 1.0)
	var leaf_rule := _new_drop_rule(SAPLING, 1.0)
	base_table.rules.append(base_rule)
	middle_table.rules.append(middle_rule)
	leaf_table.rules.append(leaf_rule)
	middle_table.base_table = base_table
	leaf_table.base_table = middle_table

	var inherited_rules := leaf_table.get_eligible_rules(PackedStringArray())
	_expect(
		inherited_rules.size() == 3
		and inherited_rules[0] == base_rule
		and inherited_rules[1] == middle_rule
		and inherited_rules[2] == leaf_rule,
		"Drop inheritance must expand the deepest base first and local rules last."
	)
	_expect(
		leaf_table.resolve_drop_configs_from_rolls(
			PackedStringArray(),
			[0.0, 0.0, 0.0]
		) == [WOOD, WHITE_CRYSTAL, SAPLING],
		"Deterministic roll order must match base-first flattening."
	)

	base_table.base_table = leaf_table
	var cycle_errors := leaf_table.validate_config()
	_expect(
		cycle_errors.size() == 1
		and cycle_errors[0].contains("base_table 形成循环")
		and cycle_errors[0].contains(".base_table.base_table.base_table"),
		"Cycles must be rejected with one stable structural path before runtime."
	)
	# RefCounted 夹具在后续正常掉落断言前拆掉循环。
	base_table.base_table = null

	var artificial_tags := PackedStringArray(["artificial_creation"])
	var default_rules := DEFAULT_ENEMY_DROP_TABLE.get_eligible_rules(
		artificial_tags
	)
	_expect(
		default_rules.size() == 7
		and not _rules_contain_pickup(default_rules, SMALL_STONE),
		"The shared artificial-creation path must no longer contain small stone."
	)
	var stone_rules := STONE_GOLEM_DROP_TABLE.get_eligible_rules(
		artificial_tags
	)
	var base_prefix_matches := stone_rules.size() == default_rules.size() + 1
	if base_prefix_matches:
		for rule_index in range(default_rules.size()):
			base_prefix_matches = (
				base_prefix_matches
				and stone_rules[rule_index] == default_rules[rule_index]
			)
	_expect(
		STONE_GOLEM_DROP_TABLE.base_table == DEFAULT_ENEMY_DROP_TABLE
		and STONE_GOLEM_DROP_TABLE.rules.size() == 1
		and base_prefix_matches
		and stone_rules[-1].pickup_config == SMALL_STONE
		and is_equal_approx(stone_rules[-1].chance, 0.5),
		"The stone-golem table must append one 50% small-stone rule after the shared base."
	)
	_expect(
		STONE_GOLEM_CONFIG.drop_table == STONE_GOLEM_DROP_TABLE
		and STONE_GOLEM_ELITE_CONFIG.drop_table == STONE_GOLEM_DROP_TABLE,
		"Normal and elite stone golems must explicitly use the inherited table."
	)

	var local_only_rolls: Array[float] = []
	var local_boundary_rolls: Array[float] = []
	for rule in stone_rules:
		var is_small_stone := rule.pickup_config == SMALL_STONE
		local_only_rolls.append(0.0 if is_small_stone else 1.0)
		local_boundary_rolls.append(
			rule.chance if is_small_stone else 1.0
		)
	_expect(
		STONE_GOLEM_DROP_TABLE.resolve_drop_configs_from_rolls(
			artificial_tags,
			local_only_rolls
		) == [SMALL_STONE],
		"Only the stone-specific local rule may produce small stone."
	)
	_expect(
		STONE_GOLEM_DROP_TABLE.resolve_drop_configs_from_rolls(
			artificial_tags,
			local_boundary_rolls
		).is_empty(),
		"The stone-specific 50% rule must retain the strict roll < chance boundary."
	)


func _fixed_profile(
	health: int,
	physical_defense: int,
	magic_defense: int
) -> DamageTargetProfile:
	var profile := DamageTargetProfile.new(
		health,
		physical_defense,
		magic_defense
	)
	profile.fixed_damage_per_accepted_hit = 1.0
	return profile


func _assert_fixed_scalar(
	label: String,
	request: DamageRequest,
	profile: DamageTargetProfile,
	expected_adjusted: int,
	expected_mitigated: int
) -> void:
	var result := DamageResolver.resolve(request, profile)
	_expect(
		result.accepted
		and result.adjusted_amount == expected_adjusted
		and result.mitigated_damage == expected_mitigated
		and result.resolved_damage == 1
		and result.applied_damage == 1
		and result.health_after == profile.current_health - 1
		and not result.lethal,
		"%s must run the normal pipeline, then replace its positive result with one."
		% label
	)


func _new_drop_rule(
	pickup_config: PickupConfig,
	chance: float
) -> EnemyDropRule:
	var rule := EnemyDropRuleScript.new()
	rule.pickup_config = pickup_config
	rule.chance = chance
	return rule


func _rules_contain_pickup(rules: Array, pickup_config: PickupConfig) -> bool:
	for rule in rules:
		if rule != null and rule.pickup_config == pickup_config:
			return true
	return false


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
