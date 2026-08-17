extends Resource
class_name GlobalResearchConfig

const MAX_INPUT_ITEMS := 3

enum EffectType {
	BUILDING_PHYSICAL_DEFENSE,
	PLAYER_MOVE_SPEED,
	SIMPLE_CRAFTING_RECIPE_UNLOCK,
	PRODUCTION_RECIPE_UNLOCK,
	VEGETATION_SPREAD_SPEED_MULTIPLIER,
	GRASS_HEAL_RATIO_BONUS,
	WATER_COLLECTOR_DURATION_MULTIPLIER,
	FENCE_REINFORCEMENT,
}

@export_group("基础信息")
@export var research_id: StringName = &""
@export var display_name: String = "全局研究"
@export_multiline var description: String = ""
@export var result_summary: String = ""

@export_group("投入")
@export var input_items: Array[PickupConfig] = []
@export var input_amounts: Array[int] = []

@export_group("研究")
@export_range(0.1, 3600.0, 0.1, "or_greater") var duration_seconds: float = 60.0
@export var effect_type: EffectType = EffectType.BUILDING_PHYSICAL_DEFENSE
@export var effect_amount: float = 0.0
# 围栏强化使用主效果表示生命值加成，次效果表示物理防御加成。
@export var secondary_effect_amount: float = 0.0
# 同一项配方解锁科研可以同时开放一条简易制作路线与一条建筑生产路线。
@export var unlocked_simple_crafting_recipe_id: StringName = &""
@export var unlocked_production_recipe_id: StringName = &""


func is_valid() -> bool:
	if (
		research_id == &""
		or display_name.is_empty()
		or description.is_empty()
		or result_summary.is_empty()
		or input_items.is_empty()
		or input_items.size() != input_amounts.size()
		or input_items.size() > MAX_INPUT_ITEMS
		or not is_finite(duration_seconds)
		or duration_seconds <= 0.0
		or not is_finite(effect_amount)
		or not is_finite(secondary_effect_amount)
		or effect_type < EffectType.BUILDING_PHYSICAL_DEFENSE
		or effect_type > EffectType.FENCE_REINFORCEMENT
	):
		return false
	match effect_type:
		EffectType.SIMPLE_CRAFTING_RECIPE_UNLOCK:
			if (
				unlocked_simple_crafting_recipe_id == &""
				or effect_amount != 0.0
				or secondary_effect_amount != 0.0
			):
				return false
		EffectType.PRODUCTION_RECIPE_UNLOCK:
			if (
				unlocked_production_recipe_id == &""
				or effect_amount != 0.0
				or secondary_effect_amount != 0.0
			):
				return false
		EffectType.WATER_COLLECTOR_DURATION_MULTIPLIER:
			if (
				effect_amount <= 0.0
				or effect_amount > 1.0
				or secondary_effect_amount != 0.0
				or unlocked_simple_crafting_recipe_id != &""
				or unlocked_production_recipe_id != &""
			):
				return false
		EffectType.FENCE_REINFORCEMENT:
			if (
				effect_amount <= 0.0
				or secondary_effect_amount <= 0.0
				or not is_equal_approx(
					effect_amount,
					float(roundi(effect_amount))
				)
				or not is_equal_approx(
					secondary_effect_amount,
					float(roundi(secondary_effect_amount))
				)
				or unlocked_simple_crafting_recipe_id != &""
				or unlocked_production_recipe_id != &""
			):
				return false
		_:
			if (
				effect_amount <= 0.0
				or secondary_effect_amount != 0.0
				or unlocked_simple_crafting_recipe_id != &""
				or unlocked_production_recipe_id != &""
			):
				return false
	for input_index in input_items.size():
		if input_items[input_index] == null or input_amounts[input_index] <= 0:
			return false
	return true


func get_requirements() -> Array[Dictionary]:
	var requirements: Array[Dictionary] = []
	for input_index in input_items.size():
		requirements.append({
			"item": input_items[input_index],
			"count": input_amounts[input_index],
		})
	return requirements
