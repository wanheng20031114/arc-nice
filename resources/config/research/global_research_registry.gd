extends RefCounted
class_name GlobalResearchRegistry

const BUILDING_DEFENSE_ID: StringName = &"building_defense"
const BUILDING_DEFENSE_II_ID: StringName = &"building_defense_ii"
const BUILDING_DEFENSE_III_ID: StringName = &"building_defense_iii"
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
const AGAVE_CANNON_MUZZLE_IMPROVEMENT_ID: StringName = (
	&"agave_cannon_muzzle_improvement"
)
const CORN_MACHINE_GUN_COOLING_SYSTEM_IMPROVEMENT_ID: StringName = (
	&"corn_machine_gun_cooling_system_improvement"
)
const BAMBOO_MORTAR_CONCUSSIVE_MODIFICATION_ID: StringName = (
	&"bamboo_mortar_concussive_modification"
)
const GRAPE_ARC_TOWER_SURGE_MODIFICATION_ID: StringName = (
	&"grape_arc_tower_surge_modification"
)
const RESEARCH_ORDER: Array[StringName] = [
	BUILDING_DEFENSE_ID,
	BUILDING_DEFENSE_II_ID,
	BUILDING_DEFENSE_III_ID,
	PLAYER_MOVE_SPEED_ID,
	BAMBOO_MORTAR_CRAFTING_ID,
	HYDRANGEA_RAIN_TOWER_CRAFTING_ID,
	ORANGE_CHARGING_TOWER_CRAFTING_ID,
	VEGETATION_STAKE_SPREAD_ENHANCEMENT_ID,
	VEGETATION_ENHANCEMENT_ID,
	WATER_COLLECTION_RATE_ENHANCEMENT_ID,
	FENCE_REINFORCEMENT_ID,
	AGAVE_CANNON_MUZZLE_IMPROVEMENT_ID,
	CORN_MACHINE_GUN_COOLING_SYSTEM_IMPROVEMENT_ID,
	BAMBOO_MORTAR_CONCUSSIVE_MODIFICATION_ID,
	GRAPE_ARC_TOWER_SURGE_MODIFICATION_ID,
]
const MAX_WIRE_RESEARCH_ID_LENGTH := 64
const PRODUCTION_RECIPE_REGISTRY_SCRIPT_PATH := (
	"res://resources/config/production/production_recipe_registry.gd"
)
const PLANT_DEFENSE_REGISTRY_SCRIPT_PATH := (
	"res://resources/config/plant_defense/plant_defense_registry.gd"
)
const SIMPLE_CRAFTING_PRODUCER_ID: StringName = &"simple_crafting"
const DEFENSE_TOWER_BUILDING_CATEGORY := 1

const BUILDING_DEFENSE: GlobalResearchConfig = preload(
	"res://resources/config/research/building_defense.tres"
)
const BUILDING_DEFENSE_II: GlobalResearchConfig = preload(
	"res://resources/config/research/building_defense_ii.tres"
)
const BUILDING_DEFENSE_III: GlobalResearchConfig = preload(
	"res://resources/config/research/building_defense_iii.tres"
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
const AGAVE_CANNON_MUZZLE_IMPROVEMENT: GlobalResearchConfig = preload(
	"res://resources/config/research/agave_cannon_muzzle_improvement.tres"
)
const CORN_MACHINE_GUN_COOLING_SYSTEM_IMPROVEMENT: GlobalResearchConfig = preload(
	"res://resources/config/research/corn_machine_gun_cooling_system_improvement.tres"
)
const BAMBOO_MORTAR_CONCUSSIVE_MODIFICATION: GlobalResearchConfig = preload(
	"res://resources/config/research/bamboo_mortar_concussive_modification.tres"
)
const GRAPE_ARC_TOWER_SURGE_MODIFICATION: GlobalResearchConfig = preload(
	"res://resources/config/research/grape_arc_tower_surge_modification.tres"
)

const RESEARCH_PROJECTS := {
	BUILDING_DEFENSE_ID: BUILDING_DEFENSE,
	BUILDING_DEFENSE_II_ID: BUILDING_DEFENSE_II,
	BUILDING_DEFENSE_III_ID: BUILDING_DEFENSE_III,
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
	AGAVE_CANNON_MUZZLE_IMPROVEMENT_ID: AGAVE_CANNON_MUZZLE_IMPROVEMENT,
	CORN_MACHINE_GUN_COOLING_SYSTEM_IMPROVEMENT_ID: (
		CORN_MACHINE_GUN_COOLING_SYSTEM_IMPROVEMENT
	),
	BAMBOO_MORTAR_CONCUSSIVE_MODIFICATION_ID: (
		BAMBOO_MORTAR_CONCUSSIVE_MODIFICATION
	),
	GRAPE_ARC_TOWER_SURGE_MODIFICATION_ID: (
		GRAPE_ARC_TOWER_SURGE_MODIFICATION
	),
}


static func get_config(research_id: StringName) -> GlobalResearchConfig:
	var config := RESEARCH_PROJECTS.get(research_id) as GlobalResearchConfig
	return (
		config
		if (
			config != null
			and config.research_id == research_id
			and config.is_valid()
			and _has_valid_prerequisite_chain(research_id)
		)
		else null
	)


static func is_registry_valid() -> bool:
	if RESEARCH_ORDER.size() != RESEARCH_PROJECTS.size():
		return false
	var registered_ids := {}
	for research_id in RESEARCH_ORDER:
		if registered_ids.has(research_id):
			return false
		registered_ids[research_id] = true
		var config := RESEARCH_PROJECTS.get(research_id) as GlobalResearchConfig
		if (
			config == null
			or config.research_id != research_id
			or not config.is_valid()
			or not _has_valid_effect_references(config)
			or not _has_valid_prerequisite_chain(research_id)
		):
			return false
	return _has_unique_recipe_unlock_owners()


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
	# 使用原始注册项目建立门槛。即使某份科研资源因配置错误而失效，
	# 对应配方也应保持锁定，而不能因为 get_all_configs() 过滤后意外放行。
	return GlobalResearchEffectResolver.find_recipe_unlock_owner(
		_get_registered_configs_in_order(),
		GlobalResearchRecipeUnlockEffect.CATALOG_SIMPLE_CRAFTING,
		recipe_id
	)


static func get_unlock_research_id_for_production_recipe(
	recipe_id: StringName
) -> StringName:
	return GlobalResearchEffectResolver.find_recipe_unlock_owner(
		_get_registered_configs_in_order(),
		GlobalResearchRecipeUnlockEffect.CATALOG_PRODUCTION,
		recipe_id
	)


static func _has_valid_prerequisite_chain(research_id: StringName) -> bool:
	var visited_ids := {}
	var current_id := research_id
	while current_id != &"":
		if visited_ids.has(current_id):
			return false
		visited_ids[current_id] = true
		var config := RESEARCH_PROJECTS.get(current_id) as GlobalResearchConfig
		if (
			config == null
			or config.research_id != current_id
			or not config.is_valid()
		):
			return false
		current_id = config.prerequisite_research_id
	return true


static func _has_valid_effect_references(config: GlobalResearchConfig) -> bool:
	# 这里按明确路径延迟取得两个玩法注册表，避免配方/植物注册表在编译自身
	# 时与科研注册表形成 preload 环。校验仍调用正式注册表，不复制其目录。
	var recipe_registry := load(PRODUCTION_RECIPE_REGISTRY_SCRIPT_PATH) as Script
	var plant_registry := load(PLANT_DEFENSE_REGISTRY_SCRIPT_PATH) as Script
	if recipe_registry == null or plant_registry == null:
		return false
	for unlock in GlobalResearchEffectResolver.get_recipe_unlock_effects(
		config.effects
	):
		var recipe := recipe_registry.call("get_recipe", unlock.recipe_id) as Resource
		var producer_id := StringName(
			recipe_registry.call("get_producer_id", unlock.recipe_id)
		)
		if (
			recipe == null
			or StringName(recipe.get("recipe_id")) != unlock.recipe_id
			or StringName(recipe.get("required_global_research_id"))
			!= config.research_id
			or (
				unlock.catalog
				== GlobalResearchRecipeUnlockEffect.CATALOG_SIMPLE_CRAFTING
			) != (
				producer_id == SIMPLE_CRAFTING_PRODUCER_ID
			)
		):
			return false
	for tower_id in GlobalResearchEffectResolver.get_referenced_tower_ids(
		config.effects
	):
		var tower_config := plant_registry.call("get_config", tower_id) as Resource
		if (
			tower_config == null
			or not bool(tower_config.call("is_valid"))
			or int(tower_config.get("building_category"))
			!= DEFENSE_TOWER_BUILDING_CATEGORY
		):
			return false
	return true


static func _has_unique_recipe_unlock_owners() -> bool:
	var owners := {}
	for research_id in RESEARCH_ORDER:
		var config := RESEARCH_PROJECTS.get(research_id) as GlobalResearchConfig
		if config == null:
			return false
		for unlock in GlobalResearchEffectResolver.get_recipe_unlock_effects(
			config.effects
		):
			var key := "%s:%s" % [
				String(unlock.catalog),
				String(unlock.recipe_id),
			]
			if owners.has(key) and owners[key] != research_id:
				return false
			owners[key] = research_id
	return true


static func _get_registered_configs_in_order() -> Array[GlobalResearchConfig]:
	var configs: Array[GlobalResearchConfig] = []
	for research_id in RESEARCH_ORDER:
		var config := RESEARCH_PROJECTS.get(research_id) as GlobalResearchConfig
		if config != null:
			configs.append(config)
	return configs
