extends RefCounted
class_name ProductionRecipeRegistry

## 正式配方的显式信任根。配方 ID 与资源路径均为作者数据；运行时与百科
## 不遍历目录，以免把临时资源或未接入玩法的资源误当成可用配方。
const REGISTERED_RECIPE_COUNT := 32
const INVALID_CATEGORY := -1

enum Category {
	SIMPLE_CRAFTING,
	SHARED_PRODUCTION,
}

const SIMPLE_CRAFTING_PRODUCER_ID: StringName = &"simple_crafting"
const WOOD_PROCESSING_STATION_PRODUCER_ID: StringName = (
	&"wood_processing_station"
)
const PLANTING_BASE_PRODUCER_ID: StringName = &"planting_base"
const WATER_COLLECTOR_PRODUCER_ID: StringName = &"water_collector"
const STONE_MILL_PRODUCER_ID: StringName = &"stone_mill"
const PLANT_CULTIVATION_CENTER_PRODUCER_ID: StringName = (
	&"plant_cultivation_center"
)
const EXCAVATOR_PRODUCER_ID: StringName = &"excavator"

const RECIPE_ORDER: Array[StringName] = [
	&"herbal_health_potion",
	&"wood_processing_station",
	&"oak_warehouse",
	&"vegetation_stake",
	&"stone_mill",
	&"simple_fence",
	&"gel_to_water_bottle",
	&"bamboo_mortar",
	&"hydrangea_rain_tower",
	&"wood_to_plank",
	&"wooden_core_assembly",
	&"gambler_ticket_assembly",
	&"water_collector_assembly",
	&"planting_base_assembly",
	&"plant_cultivation_center_assembly",
	&"research_center_assembly",
	&"excavator_assembly",
	&"life_tower_assembly",
	&"speed_tower_assembly",
	&"attack_speed_tower_assembly",
	&"sapling_propagation",
	&"sapling_to_wood",
	&"water_to_bottle",
	&"white_crystal_to_powder",
	&"capoo_blue_crystal_to_powder",
	&"wooden_core_to_agave_cannon",
	&"wooden_core_to_corn_machine_gun",
	&"wooden_core_to_bamboo_mortar",
	&"wooden_core_to_hydrangea_rain_tower",
	&"wooden_core_to_grape_arc_tower",
	&"wooden_core_to_orange_charging_tower",
	&"excavator_cycle",
]

const RECIPE_ID_TO_PATH := {
	&"herbal_health_potion": (
		"res://resources/config/production/simple_herbal_health_potion.tres"
	),
	&"wood_processing_station": (
		"res://resources/config/production/simple_wood_processing_station.tres"
	),
	&"oak_warehouse": (
		"res://resources/config/production/simple_oak_warehouse.tres"
	),
	&"vegetation_stake": (
		"res://resources/config/production/simple_vegetation_stake.tres"
	),
	&"stone_mill": (
		"res://resources/config/production/simple_stone_mill.tres"
	),
	&"simple_fence": (
		"res://resources/config/production/simple_simple_fence.tres"
	),
	&"gel_to_water_bottle": (
		"res://resources/config/production/simple_gel_to_water_bottle.tres"
	),
	&"bamboo_mortar": (
		"res://resources/config/production/simple_bamboo_mortar.tres"
	),
	&"hydrangea_rain_tower": (
		"res://resources/config/production/simple_hydrangea_rain_tower.tres"
	),
	&"wood_to_plank": "res://resources/config/production/wood_to_plank.tres",
	&"wooden_core_assembly": (
		"res://resources/config/production/wooden_core_assembly.tres"
	),
	&"gambler_ticket_assembly": (
		"res://resources/config/production/gambler_ticket_assembly.tres"
	),
	&"water_collector_assembly": (
		"res://resources/config/production/water_collector_assembly.tres"
	),
	&"planting_base_assembly": (
		"res://resources/config/production/planting_base_assembly.tres"
	),
	&"plant_cultivation_center_assembly": (
		"res://resources/config/production/plant_cultivation_center_assembly.tres"
	),
	&"research_center_assembly": (
		"res://resources/config/production/research_center_assembly.tres"
	),
	&"excavator_assembly": (
		"res://resources/config/production/excavator_assembly.tres"
	),
	&"life_tower_assembly": (
		"res://resources/config/production/life_tower_assembly.tres"
	),
	&"speed_tower_assembly": (
		"res://resources/config/production/speed_tower_assembly.tres"
	),
	&"attack_speed_tower_assembly": (
		"res://resources/config/production/attack_speed_tower_assembly.tres"
	),
	&"sapling_propagation": (
		"res://resources/config/production/sapling_propagation.tres"
	),
	&"sapling_to_wood": (
		"res://resources/config/production/sapling_to_wood.tres"
	),
	&"water_to_bottle": (
		"res://resources/config/production/water_to_bottle.tres"
	),
	&"white_crystal_to_powder": (
		"res://resources/config/production/white_crystal_to_powder.tres"
	),
	&"capoo_blue_crystal_to_powder": (
		"res://resources/config/production/capoo_blue_crystal_to_powder.tres"
	),
	&"wooden_core_to_agave_cannon": (
		"res://resources/config/production/wooden_core_to_agave_cannon.tres"
	),
	&"wooden_core_to_corn_machine_gun": (
		"res://resources/config/production/wooden_core_to_corn_machine_gun.tres"
	),
	&"wooden_core_to_bamboo_mortar": (
		"res://resources/config/production/wooden_core_to_bamboo_mortar.tres"
	),
	&"wooden_core_to_hydrangea_rain_tower": (
		"res://resources/config/production/wooden_core_to_hydrangea_rain_tower.tres"
	),
	&"wooden_core_to_grape_arc_tower": (
		"res://resources/config/production/wooden_core_to_grape_arc_tower.tres"
	),
	&"wooden_core_to_orange_charging_tower": (
		"res://resources/config/production/wooden_core_to_orange_charging_tower.tres"
	),
	&"excavator_cycle": (
		"res://resources/config/production/excavator_cycle.tres"
	),
}

const RECIPE_ID_TO_PRODUCER_ID := {
	&"herbal_health_potion": SIMPLE_CRAFTING_PRODUCER_ID,
	&"wood_processing_station": SIMPLE_CRAFTING_PRODUCER_ID,
	&"oak_warehouse": SIMPLE_CRAFTING_PRODUCER_ID,
	&"vegetation_stake": SIMPLE_CRAFTING_PRODUCER_ID,
	&"stone_mill": SIMPLE_CRAFTING_PRODUCER_ID,
	&"simple_fence": SIMPLE_CRAFTING_PRODUCER_ID,
	&"gel_to_water_bottle": SIMPLE_CRAFTING_PRODUCER_ID,
	&"bamboo_mortar": SIMPLE_CRAFTING_PRODUCER_ID,
	&"hydrangea_rain_tower": SIMPLE_CRAFTING_PRODUCER_ID,
	&"wood_to_plank": WOOD_PROCESSING_STATION_PRODUCER_ID,
	&"wooden_core_assembly": WOOD_PROCESSING_STATION_PRODUCER_ID,
	&"gambler_ticket_assembly": WOOD_PROCESSING_STATION_PRODUCER_ID,
	&"water_collector_assembly": WOOD_PROCESSING_STATION_PRODUCER_ID,
	&"planting_base_assembly": WOOD_PROCESSING_STATION_PRODUCER_ID,
	&"plant_cultivation_center_assembly": WOOD_PROCESSING_STATION_PRODUCER_ID,
	&"research_center_assembly": WOOD_PROCESSING_STATION_PRODUCER_ID,
	&"excavator_assembly": WOOD_PROCESSING_STATION_PRODUCER_ID,
	&"life_tower_assembly": WOOD_PROCESSING_STATION_PRODUCER_ID,
	&"speed_tower_assembly": WOOD_PROCESSING_STATION_PRODUCER_ID,
	&"attack_speed_tower_assembly": WOOD_PROCESSING_STATION_PRODUCER_ID,
	&"sapling_propagation": PLANTING_BASE_PRODUCER_ID,
	&"sapling_to_wood": PLANTING_BASE_PRODUCER_ID,
	&"water_to_bottle": WATER_COLLECTOR_PRODUCER_ID,
	&"white_crystal_to_powder": STONE_MILL_PRODUCER_ID,
	&"capoo_blue_crystal_to_powder": STONE_MILL_PRODUCER_ID,
	&"wooden_core_to_agave_cannon": PLANT_CULTIVATION_CENTER_PRODUCER_ID,
	&"wooden_core_to_corn_machine_gun": PLANT_CULTIVATION_CENTER_PRODUCER_ID,
	&"wooden_core_to_bamboo_mortar": PLANT_CULTIVATION_CENTER_PRODUCER_ID,
	&"wooden_core_to_hydrangea_rain_tower": (
		PLANT_CULTIVATION_CENTER_PRODUCER_ID
	),
	&"wooden_core_to_grape_arc_tower": PLANT_CULTIVATION_CENTER_PRODUCER_ID,
	&"wooden_core_to_orange_charging_tower": (
		PLANT_CULTIVATION_CENTER_PRODUCER_ID
	),
	&"excavator_cycle": EXCAVATOR_PRODUCER_ID,
}

const PRODUCER_LABELS := {
	SIMPLE_CRAFTING_PRODUCER_ID: "简易制作",
	WOOD_PROCESSING_STATION_PRODUCER_ID: "木头加工站",
	PLANTING_BASE_PRODUCER_ID: "种植基地",
	WATER_COLLECTOR_PRODUCER_ID: "水源采集器",
	STONE_MILL_PRODUCER_ID: "石磨台",
	PLANT_CULTIVATION_CENTER_PRODUCER_ID: "植物培育中心",
	EXCAVATOR_PRODUCER_ID: "挖土装置",
}

const EXPECTED_CATEGORY_COUNTS := {
	Category.SIMPLE_CRAFTING: 9,
	Category.SHARED_PRODUCTION: 23,
}


static func get_recipe(recipe_id: StringName) -> ProductionRecipe:
	var path := str(RECIPE_ID_TO_PATH.get(recipe_id, ""))
	if path.is_empty():
		return null
	# Validate the exported binary resource after loading; custom script-class loader
	# hints are only reliable for the source .tres representation.
	var recipe := ResourceLoader.load(path) as ProductionRecipe
	return (
		recipe
		if (
			recipe != null
			and recipe.resource_path == path
			and recipe.recipe_id == recipe_id
			and recipe.is_valid()
		)
		else null
	)


static func get_all_recipes() -> Array[ProductionRecipe]:
	var recipes: Array[ProductionRecipe] = []
	for recipe_id in RECIPE_ORDER:
		var recipe := get_recipe(recipe_id)
		if recipe != null:
			recipes.append(recipe)
	return recipes


static func get_registered_count() -> int:
	return RECIPE_ORDER.size()


static func get_producer_id(recipe_id: StringName) -> StringName:
	return RECIPE_ID_TO_PRODUCER_ID.get(recipe_id, &"") as StringName


static func get_producer_label(recipe_id: StringName) -> String:
	return str(PRODUCER_LABELS.get(get_producer_id(recipe_id), "未知生产端"))


static func get_category_for_recipe(recipe: ProductionRecipe) -> int:
	if recipe == null:
		return INVALID_CATEGORY
	var expected_path := str(RECIPE_ID_TO_PATH.get(recipe.recipe_id, ""))
	if expected_path.is_empty() or recipe.resource_path != expected_path:
		return INVALID_CATEGORY
	if get_producer_id(recipe.recipe_id) == SIMPLE_CRAFTING_PRODUCER_ID:
		return (
			Category.SIMPLE_CRAFTING
			if (
				recipe.inputs_from_player_inventory()
				and recipe.outputs_to_player_inventory()
			)
			else INVALID_CATEGORY
		)
	if (
		recipe.inputs_from_player_inventory()
		or recipe.output_destination
		!= ProductionRecipe.OutputDestination.SHARED_STORAGE
	):
		# 正式建筑生产统一结算到共享仓库；本地产物格仍是底层通用能力，
		# 但本地产物格或个人背包事务不得悄然重新进入正式生产目录。
		return INVALID_CATEGORY
	return Category.SHARED_PRODUCTION


static func get_category_key(category: int) -> StringName:
	match category:
		Category.SIMPLE_CRAFTING:
			return &"simple_crafting"
		Category.SHARED_PRODUCTION:
			return &"shared_production"
		_:
			return &""


static func get_category_label(category: int) -> String:
	match category:
		Category.SIMPLE_CRAFTING:
			return "简易制作"
		Category.SHARED_PRODUCTION:
			return "共享仓库生产"
		_:
			return "未知配方"


static func validate_contract() -> bool:
	if (
		RECIPE_ORDER.size() != REGISTERED_RECIPE_COUNT
		or RECIPE_ID_TO_PATH.size() != REGISTERED_RECIPE_COUNT
		or RECIPE_ID_TO_PRODUCER_ID.size() != REGISTERED_RECIPE_COUNT
	):
		return false
	var seen_ids := {}
	var seen_paths := {}
	var category_counts := {}
	for recipe_id in RECIPE_ORDER:
		if seen_ids.has(recipe_id):
			return false
		seen_ids[recipe_id] = true
		var path := str(RECIPE_ID_TO_PATH.get(recipe_id, ""))
		if path.is_empty() or seen_paths.has(path):
			return false
		seen_paths[path] = true
		var producer_id := get_producer_id(recipe_id)
		if producer_id == &"" or not PRODUCER_LABELS.has(producer_id):
			return false
		var recipe := get_recipe(recipe_id)
		if recipe == null:
			return false
		var category := get_category_for_recipe(recipe)
		if category == INVALID_CATEGORY:
			return false
		category_counts[category] = int(category_counts.get(category, 0)) + 1
	return category_counts == EXPECTED_CATEGORY_COUNTS
