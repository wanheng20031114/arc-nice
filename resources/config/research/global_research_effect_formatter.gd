extends RefCounted
class_name GlobalResearchEffectFormatter

## 科研面板徽章与百科详情使用不同密度，二者都从同一份 typed effect 生成。


static func format_badge(effects: Array[GlobalResearchEffect]) -> String:
	var unlock_effects := GlobalResearchEffectResolver.get_recipe_unlock_effects(
		effects
	)
	if unlock_effects.size() >= 2:
		return "解锁简易制作\n与建筑生产"
	if _has_additive(
		effects,
		GlobalResearchAdditiveModifierEffect.ATTRIBUTE_FENCE_MAX_HEALTH
	) and _has_additive(
		effects,
		GlobalResearchAdditiveModifierEffect.ATTRIBUTE_FENCE_PHYSICAL_DEFENSE
	):
		return "生命 +%s\n物防 +%s" % [
			_format_number(_get_additive_value(
				effects,
				GlobalResearchAdditiveModifierEffect.ATTRIBUTE_FENCE_MAX_HEALTH
			)),
			_format_number(_get_additive_value(
				effects,
				GlobalResearchAdditiveModifierEffect.ATTRIBUTE_FENCE_PHYSICAL_DEFENSE
			)),
		]
	if _has_timed_electromagnetic(effects) and _has_electromagnetic_bonus(effects):
		return "电磁附着\n%s秒 / +%s%%" % [
			_format_number(_get_electromagnetic_duration(effects)),
			_format_percent(_get_electromagnetic_bonus(effects)),
		]

	var lines := PackedStringArray()
	for effect in effects:
		for line in _format_badge_effect(effect):
			if lines.size() >= 2:
				break
			lines.append(line)
		if lines.size() >= 2:
			break
	return "\n".join(lines)


static func format_compact(effects: Array[GlobalResearchEffect]) -> String:
	return format_badge(effects)


static func format_detail_lines(
	effects: Array[GlobalResearchEffect]
) -> PackedStringArray:
	var lines := PackedStringArray()
	for effect in effects:
		var line := _format_detail_effect(effect)
		if not line.is_empty():
			lines.append(line)
	return lines


static func format_detail(effects: Array[GlobalResearchEffect]) -> String:
	return "\n".join(format_detail_lines(effects))


static func _format_badge_effect(effect: GlobalResearchEffect) -> PackedStringArray:
	var additive := effect as GlobalResearchAdditiveModifierEffect
	if additive != null:
		match additive.attribute_id:
			GlobalResearchAdditiveModifierEffect.ATTRIBUTE_BUILDING_PHYSICAL_DEFENSE:
				return PackedStringArray([
					"全建筑物防",
					"+%s" % _format_number(additive.bonus),
				])
			GlobalResearchAdditiveModifierEffect.ATTRIBUTE_PLAYER_MOVE_SPEED:
				return PackedStringArray([
					"全体移速",
					"+%s" % _format_number(additive.bonus),
				])
			GlobalResearchAdditiveModifierEffect.ATTRIBUTE_GRASS_HEAL_MAX_HEALTH_RATIO:
				return PackedStringArray([
					"草地回血",
					"+%s%%生命/秒" % _format_percent(additive.bonus),
				])
			GlobalResearchAdditiveModifierEffect.ATTRIBUTE_FENCE_MAX_HEALTH:
				return PackedStringArray([
					"围栏生命 +%s" % _format_number(additive.bonus)
				])
			GlobalResearchAdditiveModifierEffect.ATTRIBUTE_FENCE_PHYSICAL_DEFENSE:
				return PackedStringArray([
					"围栏物防 +%s" % _format_number(additive.bonus)
				])
			GlobalResearchAdditiveModifierEffect.ATTRIBUTE_AGAVE_CANNON_ATTACK_DAMAGE:
				return PackedStringArray([
					"单次伤害",
					"+%s" % _format_number(additive.bonus),
				])
			GlobalResearchAdditiveModifierEffect.ATTRIBUTE_CORN_MACHINE_GUN_BURST_COUNT:
				return PackedStringArray([
					"每轮射击",
					"+%s次" % _format_number(additive.bonus),
				])

	var multiplier := effect as GlobalResearchMultiplierModifierEffect
	if multiplier != null:
		match multiplier.metric_id:
			GlobalResearchMultiplierModifierEffect.METRIC_VEGETATION_STAKE_SPREAD_SPEED:
				return PackedStringArray([
					"蔓延速率",
					"×%s" % _format_number(multiplier.multiplier),
				])
			GlobalResearchMultiplierModifierEffect.METRIC_WATER_COLLECTOR_CYCLE_DURATION:
				return PackedStringArray([
					"采水耗时",
					"×%s" % _format_number(multiplier.multiplier),
				])

	var unlock := effect as GlobalResearchRecipeUnlockEffect
	if unlock != null:
		return PackedStringArray([
			"解锁简易制作"
			if unlock.catalog == GlobalResearchRecipeUnlockEffect.CATALOG_SIMPLE_CRAFTING
			else "解锁建筑生产"
		])

	var slow := effect as GlobalResearchTowerOnHitSlowEffect
	if slow != null:
		return PackedStringArray([
			"减速 %s%%" % _format_percent(slow.slow_ratio),
			"持续 %s秒" % _format_number(slow.duration_seconds),
		])

	var timed_status := effect as GlobalResearchTowerOnHitTimedStatusEffect
	if timed_status != null:
		return PackedStringArray([
			"电磁附着",
			"持续 %s秒" % _format_number(timed_status.duration_seconds),
		])

	var conditional := effect as GlobalResearchTowerConditionalDamageBonusEffect
	if conditional != null:
		return PackedStringArray([
			"对附着目标 +%s%%" % _format_percent(conditional.bonus_damage_ratio)
		])
	return PackedStringArray()


static func _format_detail_effect(effect: GlobalResearchEffect) -> String:
	var additive := effect as GlobalResearchAdditiveModifierEffect
	if additive != null:
		var value := _format_number(additive.bonus)
		match additive.attribute_id:
			GlobalResearchAdditiveModifierEffect.ATTRIBUTE_BUILDING_PHYSICAL_DEFENSE:
				return "本局所有建筑物理防御 +%s" % value
			GlobalResearchAdditiveModifierEffect.ATTRIBUTE_PLAYER_MOVE_SPEED:
				return "本局所有玩家移动速度 +%s" % value
			GlobalResearchAdditiveModifierEffect.ATTRIBUTE_GRASS_HEAL_MAX_HEALTH_RATIO:
				return "玩家在草块上每秒额外回复 %s%% 最大生命值" % _format_percent(additive.bonus)
			GlobalResearchAdditiveModifierEffect.ATTRIBUTE_FENCE_MAX_HEALTH:
				return "本局所有围栏最大生命值 +%s" % value
			GlobalResearchAdditiveModifierEffect.ATTRIBUTE_FENCE_PHYSICAL_DEFENSE:
				return "本局所有围栏物理防御 +%s" % value
			GlobalResearchAdditiveModifierEffect.ATTRIBUTE_AGAVE_CANNON_ATTACK_DAMAGE:
				return "本局所有龙舌兰加农炮单次攻击伤害 +%s" % value
			GlobalResearchAdditiveModifierEffect.ATTRIBUTE_CORN_MACHINE_GUN_BURST_COUNT:
				return "本局所有玉米机枪塔每轮射击次数 +%s" % value

	var multiplier := effect as GlobalResearchMultiplierModifierEffect
	if multiplier != null:
		match multiplier.metric_id:
			GlobalResearchMultiplierModifierEffect.METRIC_VEGETATION_STAKE_SPREAD_SPEED:
				return "本局所有植被桩剩余蔓延进度速率 ×%s" % _format_number(multiplier.multiplier)
			GlobalResearchMultiplierModifierEffect.METRIC_WATER_COLLECTOR_CYCLE_DURATION:
				return "本局所有水收集器单轮耗时 ×%s" % _format_number(multiplier.multiplier)

	var unlock := effect as GlobalResearchRecipeUnlockEffect
	if unlock != null:
		var recipe_name := _get_recipe_display_name(unlock)
		return "%s：%s" % [
			"解锁简易制作"
			if unlock.catalog == GlobalResearchRecipeUnlockEffect.CATALOG_SIMPLE_CRAFTING
			else "解锁建筑生产",
			recipe_name,
		]

	var slow := effect as GlobalResearchTowerOnHitSlowEffect
	if slow != null:
		return "%s造成伤害后施加 %s%% 减速，持续 %s 秒" % [
			_get_tower_display_name(slow.source_tower_id),
			_format_percent(slow.slow_ratio),
			_format_number(slow.duration_seconds),
		]

	var timed_status := effect as GlobalResearchTowerOnHitTimedStatusEffect
	if timed_status != null:
		return "%s造成伤害后附加电磁附着，持续 %s 秒" % [
			_get_tower_display_name(timed_status.source_tower_id),
			_format_number(timed_status.duration_seconds),
		]

	var conditional := effect as GlobalResearchTowerConditionalDamageBonusEffect
	if conditional != null:
		return "%s对电磁附着影响下的单位额外造成 %s%% 伤害" % [
			_get_tower_display_name(conditional.source_tower_id),
			_format_percent(conditional.bonus_damage_ratio),
		]
	return ""


static func _has_additive(
	effects: Array[GlobalResearchEffect],
	attribute_id: StringName
) -> bool:
	for effect in effects:
		var additive := effect as GlobalResearchAdditiveModifierEffect
		if additive != null and additive.attribute_id == attribute_id:
			return true
	return false


static func _get_additive_value(
	effects: Array[GlobalResearchEffect],
	attribute_id: StringName
) -> float:
	return GlobalResearchEffectResolver.get_additive_bonus(effects, attribute_id)


static func _has_timed_electromagnetic(
	effects: Array[GlobalResearchEffect]
) -> bool:
	return _get_electromagnetic_duration(effects) > 0.0


static func _get_electromagnetic_duration(
	effects: Array[GlobalResearchEffect]
) -> float:
	var duration := 0.0
	for effect in effects:
		var timed_status := effect as GlobalResearchTowerOnHitTimedStatusEffect
		if (
			timed_status != null
			and timed_status.status_id
			== GlobalResearchTowerOnHitTimedStatusEffect.STATUS_ELECTROMAGNETIC
		):
			duration = maxf(duration, timed_status.duration_seconds)
	return duration


static func _has_electromagnetic_bonus(
	effects: Array[GlobalResearchEffect]
) -> bool:
	return _get_electromagnetic_bonus(effects) > 0.0


static func _get_electromagnetic_bonus(
	effects: Array[GlobalResearchEffect]
) -> float:
	var bonus := 0.0
	for effect in effects:
		var conditional := effect as GlobalResearchTowerConditionalDamageBonusEffect
		if (
			conditional != null
			and conditional.required_status_id
			== GlobalResearchTowerConditionalDamageBonusEffect.STATUS_ELECTROMAGNETIC
		):
			bonus += conditional.bonus_damage_ratio
	return bonus


static func _get_tower_display_name(tower_id: StringName) -> String:
	var config := PlantDefenseRegistry.get_config(tower_id)
	return config.display_name if config != null else String(tower_id)


static func _get_recipe_display_name(
	effect: GlobalResearchRecipeUnlockEffect
) -> String:
	var recipe := ProductionRecipeRegistry.get_recipe(effect.recipe_id)
	return recipe.display_name if recipe != null else String(effect.recipe_id)


static func _format_percent(ratio: float) -> String:
	return _format_number(ratio * 100.0)


static func _format_number(value: float) -> String:
	if is_equal_approx(value, float(roundi(value))):
		return str(roundi(value))
	var result := "%.2f" % value
	while result.ends_with("0"):
		result = result.trim_suffix("0")
	return result.trim_suffix(".")
