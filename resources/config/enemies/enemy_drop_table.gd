extends Resource
class_name EnemyDropTable

const EnemyDropRuleResource := preload(
	"res://resources/config/enemies/enemy_drop_rule.gd"
)
const ContentValidationContextResource := preload(
	"res://resources/config/content_validation_context.gd"
)


@export var base_table: EnemyDropTable
@export var rules: Array[EnemyDropRuleResource] = []


func get_eligible_rules(tags: PackedStringArray) -> Array[EnemyDropRuleResource]:
	var eligible_rules: Array[EnemyDropRuleResource] = []
	if not _append_eligible_rules(tags, {}, PackedStringArray(), eligible_rules):
		eligible_rules.clear()
	return eligible_rules


func _append_eligible_rules(
	tags: PackedStringArray,
	visited_tables: Dictionary,
	table_chain: PackedStringArray,
	eligible_rules: Array[EnemyDropRuleResource]
) -> bool:
	var table_id := get_instance_id()
	if visited_tables.has(table_id):
		var cycle_chain := table_chain.duplicate()
		cycle_chain.append(String(visited_tables[table_id]))
		push_error(
			"EnemyDropTable base_table cycle detected: %s."
			% " -> ".join(cycle_chain)
		)
		return false
	var table_label := (
		resource_path
		if not resource_path.is_empty()
		else "EnemyDropTable[%d]" % table_chain.size()
	)
	visited_tables[table_id] = table_label
	table_chain.append(table_label)
	if base_table != null:
		var base_is_valid := base_table._append_eligible_rules(
			tags,
			visited_tables,
			table_chain,
			eligible_rules
		)
		if not base_is_valid:
			table_chain.remove_at(table_chain.size() - 1)
			return false
	for rule in rules:
		if rule != null and rule.matches_tags(tags):
			eligible_rules.append(rule)
	table_chain.remove_at(table_chain.size() - 1)
	return true


func validate_config() -> PackedStringArray:
	var context := ContentValidationContextResource.new()
	append_validation_errors(
		context,
		ContentValidationContextResource.describe_resource(self, "EnemyDropTable")
	)
	return context.errors


## base_table 先于本表规则校验，与真实掉落解析顺序一致。
func append_validation_errors(
	context: ContentValidationContextResource,
	path: String
) -> void:
	var visit_state := context.begin_resource(self, path)
	if visit_state == ContentValidationContextResource.VisitState.ACTIVE:
		context.add_error(
			path,
			"base_table 形成循环，指回 %s。" % context.get_active_path(self)
		)
		return
	if visit_state == ContentValidationContextResource.VisitState.COMPLETED:
		return

	if base_table != null:
		base_table.append_validation_errors(
			context,
			ContentValidationContextResource.child_path(path, "base_table")
		)
	for rule_index in range(rules.size()):
		var rule := rules[rule_index]
		var rule_path := ContentValidationContextResource.child_path(
			path,
			"rules[%d]" % rule_index
		)
		if rule == null:
			context.add_error(rule_path, "不能为空。")
			continue
		rule.append_validation_errors(context, rule_path)
	context.complete_resource(self)


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
