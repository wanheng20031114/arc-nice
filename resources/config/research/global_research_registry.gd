extends RefCounted
class_name GlobalResearchRegistry

const BUILDING_DEFENSE_ID: StringName = &"building_defense"
const PLAYER_MOVE_SPEED_ID: StringName = &"player_move_speed"
const BAMBOO_MORTAR_CRAFTING_ID: StringName = &"bamboo_mortar_crafting"
const HYDRANGEA_RAIN_TOWER_CRAFTING_ID: StringName = (
	&"hydrangea_rain_tower_crafting"
)
const ORANGE_CHARGING_TOWER_CRAFTING_ID: StringName = (
	&"orange_charging_tower_crafting"
)
const VEGETATION_STAKE_SPREAD_ENHANCEMENT_ID: StringName = (
	&"vegetation_stake_spread_enhancement"
)
const VEGETATION_ENHANCEMENT_ID: StringName = &"vegetation_enhancement"
const WATER_COLLECTION_RATE_ENHANCEMENT_ID: StringName = (
	&"water_collection_rate_enhancement"
)
const FENCE_REINFORCEMENT_ID: StringName = &"fence_reinforcement"
const RESEARCH_ORDER: Array[StringName] = [
	BUILDING_DEFENSE_ID,
	PLAYER_MOVE_SPEED_ID,
	BAMBOO_MORTAR_CRAFTING_ID,
	HYDRANGEA_RAIN_TOWER_CRAFTING_ID,
	ORANGE_CHARGING_TOWER_CRAFTING_ID,
	VEGETATION_STAKE_SPREAD_ENHANCEMENT_ID,
	VEGETATION_ENHANCEMENT_ID,
	WATER_COLLECTION_RATE_ENHANCEMENT_ID,
	FENCE_REINFORCEMENT_ID,
]
const MAX_WIRE_RESEARCH_ID_LENGTH := 64

const BUILDING_DEFENSE: GlobalResearchConfig = preload(
	"res://resources/config/research/building_defense.tres"
)
const PLAYER_MOVE_SPEED: GlobalResearchConfig = preload(
	"res://resources/config/research/player_move_speed.tres"
)
const BAMBOO_MORTAR_CRAFTING: GlobalResearchConfig = preload(
	"res://resources/config/research/bamboo_mortar_crafting.tres"
)
const HYDRANGEA_RAIN_TOWER_CRAFTING: GlobalResearchConfig = preload(
	"res://resources/config/research/hydrangea_rain_tower_crafting.tres"
)
const ORANGE_CHARGING_TOWER_CRAFTING: GlobalResearchConfig = preload(
	"res://resources/config/research/orange_charging_tower_crafting.tres"
)
const VEGETATION_STAKE_SPREAD_ENHANCEMENT: GlobalResearchConfig = preload(
	"res://resources/config/research/vegetation_stake_spread_enhancement.tres"
)
const VEGETATION_ENHANCEMENT: GlobalResearchConfig = preload(
	"res://resources/config/research/vegetation_enhancement.tres"
)
const WATER_COLLECTION_RATE_ENHANCEMENT: GlobalResearchConfig = preload(
	"res://resources/config/research/water_collection_rate_enhancement.tres"
)
const FENCE_REINFORCEMENT: GlobalResearchConfig = preload(
	"res://resources/config/research/fence_reinforcement.tres"
)

const RESEARCH_PROJECTS := {
	BUILDING_DEFENSE_ID: BUILDING_DEFENSE,
	PLAYER_MOVE_SPEED_ID: PLAYER_MOVE_SPEED,
	BAMBOO_MORTAR_CRAFTING_ID: BAMBOO_MORTAR_CRAFTING,
	HYDRANGEA_RAIN_TOWER_CRAFTING_ID: HYDRANGEA_RAIN_TOWER_CRAFTING,
	ORANGE_CHARGING_TOWER_CRAFTING_ID: ORANGE_CHARGING_TOWER_CRAFTING,
	VEGETATION_STAKE_SPREAD_ENHANCEMENT_ID: (
		VEGETATION_STAKE_SPREAD_ENHANCEMENT
	),
	VEGETATION_ENHANCEMENT_ID: VEGETATION_ENHANCEMENT,
	WATER_COLLECTION_RATE_ENHANCEMENT_ID: WATER_COLLECTION_RATE_ENHANCEMENT,
	FENCE_REINFORCEMENT_ID: FENCE_REINFORCEMENT,
}


static func get_config(research_id: StringName) -> GlobalResearchConfig:
	var config := RESEARCH_PROJECTS.get(research_id) as GlobalResearchConfig
	return (
		config
		if (
			config != null
			and config.research_id == research_id
			and config.is_valid()
		)
		else null
	)


static func get_config_by_wire_id(research_id: String) -> GlobalResearchConfig:
	if research_id.is_empty() or research_id.length() > MAX_WIRE_RESEARCH_ID_LENGTH:
		return null
	for registered_id_variant in RESEARCH_PROJECTS:
		var registered_id := registered_id_variant as StringName
		if String(registered_id) == research_id:
			return get_config(registered_id)
	return null


static func get_all_configs() -> Array[GlobalResearchConfig]:
	var configs: Array[GlobalResearchConfig] = []
	for research_id in RESEARCH_ORDER:
		var config := get_config(research_id)
		if config != null:
			configs.append(config)
	return configs


static func get_unlock_research_id_for_simple_crafting_recipe(
	recipe_id: StringName
) -> StringName:
	if recipe_id == &"":
		return &""
	# 使用原始注册项目建立门槛。即使某份科研资源因配置错误而失效，
	# 对应配方也应保持锁定，而不能因为 get_all_configs() 过滤后意外放行。
	# 一个科研可同时声明简易制作与建筑生产路线，因此反查只匹配对应字段。
	for research_id in RESEARCH_ORDER:
		var config := RESEARCH_PROJECTS.get(research_id) as GlobalResearchConfig
		if (
			config != null
			and config.unlocked_simple_crafting_recipe_id == recipe_id
		):
			return research_id
	return &""


static func get_unlock_research_id_for_production_recipe(
	recipe_id: StringName
) -> StringName:
	if recipe_id == &"":
		return &""
	# 不按 effect_type 排斥复合解锁；生产路线以该字段为唯一反向索引。
	for research_id in RESEARCH_ORDER:
		var config := RESEARCH_PROJECTS.get(research_id) as GlobalResearchConfig
		if (
			config != null
			and config.unlocked_production_recipe_id == recipe_id
		):
			return research_id
	return &""
