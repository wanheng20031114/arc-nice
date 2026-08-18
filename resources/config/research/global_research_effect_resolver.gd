extends RefCounted
class_name GlobalResearchEffectResolver

## 科研效果的唯一解释与聚合入口。效果资源保持不可变；运行时只接收
## CompletedResearchEffects 中从完整已完成集合重新计算出的绝对值。

const BAMBOO_MORTAR_TOWER_ID: StringName = &"bamboo_mortar"
const GRAPE_ARC_TOWER_ID: StringName = &"grape_arc_tower"
const AGAVE_CANNON_TOWER_ID: StringName = &"agave_cannon"
const CORN_MACHINE_GUN_TOWER_ID: StringName = &"corn_machine_gun"


static func from_completed_ids(
	configs: Array[GlobalResearchConfig],
	completed_research_ids: Array[StringName]
) -> CompletedResearchEffects:
	return _build_projection(
		collect_from_completed_ids(configs, completed_research_ids)
	)


static func from_states(
	configs: Array[GlobalResearchConfig],
	global_states: Dictionary,
	completed_state_value: int
) -> CompletedResearchEffects:
	return _build_projection(
		collect_from_states(configs, global_states, completed_state_value)
	)


static func collect_from_completed_ids(
	configs: Array[GlobalResearchConfig],
	completed_research_ids: Array[StringName]
) -> Array[GlobalResearchEffect]:
	var effects: Array[GlobalResearchEffect] = []
	for config in configs:
		if config == null or config.research_id not in completed_research_ids:
			continue
		_append_valid_effects(effects, config.effects)
	return effects


static func collect_from_states(
	configs: Array[GlobalResearchConfig],
	global_states: Dictionary,
	completed_state_value: int
) -> Array[GlobalResearchEffect]:
	var effects: Array[GlobalResearchEffect] = []
	for config in configs:
		if (
			config == null
			or int(global_states.get(config.research_id, -1))
			!= completed_state_value
		):
			continue
		_append_valid_effects(effects, config.effects)
	return effects


static func get_additive_bonus(
	effects: Array[GlobalResearchEffect],
	attribute_id: StringName
) -> float:
	var total := 0.0
	for effect in effects:
		var additive := effect as GlobalResearchAdditiveModifierEffect
		if additive != null and additive.attribute_id == attribute_id:
			total += additive.bonus
	return total


static func get_additive_int_bonus(
	effects: Array[GlobalResearchEffect],
	attribute_id: StringName
) -> int:
	return roundi(get_additive_bonus(effects, attribute_id))


static func get_multiplier(
	effects: Array[GlobalResearchEffect],
	metric_id: StringName
) -> float:
	var result := 1.0
	for effect in effects:
		var multiplier_effect := (
			effect as GlobalResearchMultiplierModifierEffect
		)
		if multiplier_effect == null or multiplier_effect.metric_id != metric_id:
			continue
		match metric_id:
			GlobalResearchMultiplierModifierEffect.METRIC_WATER_COLLECTOR_CYCLE_DURATION:
				# 采水周期保留既有“只取最强缩短”的组合规则。
				result = minf(result, multiplier_effect.multiplier)
			GlobalResearchMultiplierModifierEffect.METRIC_VEGETATION_STAKE_SPREAD_SPEED:
				result *= multiplier_effect.multiplier
	return result


static func get_tower_on_hit_slow_effects(
	effects: Array[GlobalResearchEffect],
	source_tower_id: StringName
) -> Array[GlobalResearchTowerOnHitSlowEffect]:
	var result: Array[GlobalResearchTowerOnHitSlowEffect] = []
	for effect in effects:
		var slow := effect as GlobalResearchTowerOnHitSlowEffect
		if slow != null and slow.source_tower_id == source_tower_id:
			result.append(slow)
	return result


static func get_tower_on_hit_timed_status_effects(
	effects: Array[GlobalResearchEffect],
	source_tower_id: StringName,
	status_id: StringName = &""
) -> Array[GlobalResearchTowerOnHitTimedStatusEffect]:
	var result: Array[GlobalResearchTowerOnHitTimedStatusEffect] = []
	for effect in effects:
		var timed_status := effect as GlobalResearchTowerOnHitTimedStatusEffect
		if (
			timed_status != null
			and timed_status.source_tower_id == source_tower_id
			and (status_id == &"" or timed_status.status_id == status_id)
		):
			result.append(timed_status)
	return result


static func get_max_timed_status_duration(
	effects: Array[GlobalResearchEffect],
	source_tower_id: StringName,
	status_id: StringName
) -> float:
	var duration := 0.0
	for effect in get_tower_on_hit_timed_status_effects(
		effects,
		source_tower_id,
		status_id
	):
		duration = maxf(duration, effect.duration_seconds)
	return duration


static func get_conditional_damage_bonus_ratio(
	effects: Array[GlobalResearchEffect],
	source_tower_id: StringName,
	required_status_id: StringName
) -> float:
	var total := 0.0
	for effect in effects:
		var conditional := (
			effect as GlobalResearchTowerConditionalDamageBonusEffect
		)
		if (
			conditional != null
			and conditional.source_tower_id == source_tower_id
			and conditional.required_status_id == required_status_id
		):
			total += conditional.bonus_damage_ratio
	return total


static func get_recipe_unlock_effects(
	effects: Array[GlobalResearchEffect],
	catalog: StringName = &""
) -> Array[GlobalResearchRecipeUnlockEffect]:
	var result: Array[GlobalResearchRecipeUnlockEffect] = []
	for effect in effects:
		var unlock := effect as GlobalResearchRecipeUnlockEffect
		if unlock != null and (catalog == &"" or unlock.catalog == catalog):
			result.append(unlock)
	return result


static func find_recipe_unlock_owner(
	configs: Array[GlobalResearchConfig],
	catalog: StringName,
	recipe_id: StringName
) -> StringName:
	if catalog == &"" or recipe_id == &"":
		return &""
	for config in configs:
		if config == null:
			continue
		for unlock in get_recipe_unlock_effects(config.effects, catalog):
			if unlock.recipe_id == recipe_id:
				return config.research_id
	return &""


static func get_referenced_tower_ids(
	effects: Array[GlobalResearchEffect]
) -> Array[StringName]:
	var tower_ids := {}
	for effect in effects:
		var additive := effect as GlobalResearchAdditiveModifierEffect
		if additive != null:
			match additive.attribute_id:
				GlobalResearchAdditiveModifierEffect.ATTRIBUTE_AGAVE_CANNON_ATTACK_DAMAGE:
					tower_ids[AGAVE_CANNON_TOWER_ID] = true
				GlobalResearchAdditiveModifierEffect.ATTRIBUTE_CORN_MACHINE_GUN_BURST_COUNT:
					tower_ids[CORN_MACHINE_GUN_TOWER_ID] = true
			continue
		var slow := effect as GlobalResearchTowerOnHitSlowEffect
		if slow != null:
			tower_ids[slow.source_tower_id] = true
			continue
		var timed_status := effect as GlobalResearchTowerOnHitTimedStatusEffect
		if timed_status != null:
			tower_ids[timed_status.source_tower_id] = true
			continue
		var conditional := effect as GlobalResearchTowerConditionalDamageBonusEffect
		if conditional != null:
			tower_ids[conditional.source_tower_id] = true
	return _sorted_string_name_keys(tower_ids)


static func _build_projection(
	effects: Array[GlobalResearchEffect]
) -> CompletedResearchEffects:
	var simple_recipe_ids := _get_recipe_ids(
		effects,
		GlobalResearchRecipeUnlockEffect.CATALOG_SIMPLE_CRAFTING
	)
	var production_recipe_ids := _get_recipe_ids(
		effects,
		GlobalResearchRecipeUnlockEffect.CATALOG_PRODUCTION
	)
	var bamboo_slow_ratio := 0.0
	var bamboo_slow_duration := 0.0
	for slow in get_tower_on_hit_slow_effects(effects, BAMBOO_MORTAR_TOWER_ID):
		bamboo_slow_ratio = maxf(bamboo_slow_ratio, slow.slow_ratio)
		bamboo_slow_duration = maxf(bamboo_slow_duration, slow.duration_seconds)
	var electromagnetic_status := (
		GlobalResearchTowerOnHitTimedStatusEffect.STATUS_ELECTROMAGNETIC
	)
	return CompletedResearchEffects.new(
		get_additive_int_bonus(
			effects,
			GlobalResearchAdditiveModifierEffect.ATTRIBUTE_BUILDING_PHYSICAL_DEFENSE
		),
		get_additive_bonus(
			effects,
			GlobalResearchAdditiveModifierEffect.ATTRIBUTE_PLAYER_MOVE_SPEED
		),
		get_additive_bonus(
			effects,
			GlobalResearchAdditiveModifierEffect.ATTRIBUTE_GRASS_HEAL_MAX_HEALTH_RATIO
		),
		get_additive_int_bonus(
			effects,
			GlobalResearchAdditiveModifierEffect.ATTRIBUTE_FENCE_MAX_HEALTH
		),
		get_additive_int_bonus(
			effects,
			GlobalResearchAdditiveModifierEffect.ATTRIBUTE_FENCE_PHYSICAL_DEFENSE
		),
		get_additive_int_bonus(
			effects,
			GlobalResearchAdditiveModifierEffect.ATTRIBUTE_AGAVE_CANNON_ATTACK_DAMAGE
		),
		get_additive_int_bonus(
			effects,
			GlobalResearchAdditiveModifierEffect.ATTRIBUTE_CORN_MACHINE_GUN_BURST_COUNT
		),
		get_multiplier(
			effects,
			GlobalResearchMultiplierModifierEffect.METRIC_VEGETATION_STAKE_SPREAD_SPEED
		),
		get_multiplier(
			effects,
			GlobalResearchMultiplierModifierEffect.METRIC_WATER_COLLECTOR_CYCLE_DURATION
		),
		bamboo_slow_ratio,
		bamboo_slow_duration,
		get_max_timed_status_duration(
			effects,
			GRAPE_ARC_TOWER_ID,
			electromagnetic_status
		),
		get_conditional_damage_bonus_ratio(
			effects,
			GRAPE_ARC_TOWER_ID,
			electromagnetic_status
		),
		simple_recipe_ids,
		production_recipe_ids
	)


static func _append_valid_effects(
	target: Array[GlobalResearchEffect],
	source: Array[GlobalResearchEffect]
) -> void:
	for effect in source:
		if effect != null and effect.is_valid():
			target.append(effect)


static func _get_recipe_ids(
	effects: Array[GlobalResearchEffect],
	catalog: StringName
) -> Array[StringName]:
	var ids := {}
	for unlock in get_recipe_unlock_effects(effects, catalog):
		ids[unlock.recipe_id] = true
	return _sorted_string_name_keys(ids)


static func _sorted_string_name_keys(values: Dictionary) -> Array[StringName]:
	var strings := PackedStringArray()
	for key_variant in values:
		strings.append(String(key_variant as StringName))
	strings.sort()
	var result: Array[StringName] = []
	for value in strings:
		result.append(StringName(value))
	return result
