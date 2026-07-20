extends Resource
class_name EnemyDropTable

const EnemyDropRuleResource := preload(
	"res://resources/config/enemies/enemy_drop_rule.gd"
)


@export var rules: Array[EnemyDropRuleResource] = []


func get_eligible_rules(tags: PackedStringArray) -> Array[EnemyDropRuleResource]:
	var eligible_rules: Array[EnemyDropRuleResource] = []
	for rule in rules:
		if rule != null and rule.matches_tags(tags):
			eligible_rules.append(rule)
	return eligible_rules


func resolve_drop_configs(
	tags: PackedStringArray,
	rng: RandomNumberGenerator
) -> Array[PickupConfig]:
	if rng == null:
		push_error("EnemyDropTable requires a random number generator.")
		return []
	var eligible_rules := get_eligible_rules(tags)
	var rolls: Array[float] = []
	for _rule in eligible_rules:
		rolls.append(rng.randf())
	return _resolve_eligible_rules_from_rolls(eligible_rules, rolls)


func resolve_drop_configs_from_rolls(
	tags: PackedStringArray,
	rolls: Array[float]
) -> Array[PickupConfig]:
	var eligible_rules := get_eligible_rules(tags)
	return _resolve_eligible_rules_from_rolls(eligible_rules, rolls)


func _resolve_eligible_rules_from_rolls(
	eligible_rules: Array[EnemyDropRuleResource],
	rolls: Array[float]
) -> Array[PickupConfig]:
	var resolved_configs: Array[PickupConfig] = []
	if rolls.size() != eligible_rules.size():
		push_error(
			"EnemyDropTable deterministic roll count mismatch: expected %d, got %d."
			% [eligible_rules.size(), rolls.size()]
		)
		return resolved_configs

	for index in range(eligible_rules.size()):
		var rule := eligible_rules[index]
		if (
			rule.pickup_config != null
			and _does_roll_succeed(rolls[index], rule.chance)
		):
			resolved_configs.append(rule.pickup_config)
	return resolved_configs


func _does_roll_succeed(roll: float, chance: float) -> bool:
	if chance <= 0.0:
		return false
	if chance >= 1.0:
		return true
	return roll < chance
