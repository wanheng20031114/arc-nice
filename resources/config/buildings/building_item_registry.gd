extends RefCounted
class_name BuildingItemRegistry

const AGAVE_CANNON_ITEM: PickupConfig = preload(
	"res://resources/config/buildings/building_agave_cannon.tres"
)
const BAMBOO_MORTAR_ITEM: PickupConfig = preload(
	"res://resources/config/buildings/building_bamboo_mortar.tres"
)
const CORN_MACHINE_GUN_ITEM: PickupConfig = preload(
	"res://resources/config/buildings/building_corn_machine_gun.tres"
)
const GRAPE_ARC_TOWER_ITEM: PickupConfig = preload(
	"res://resources/config/buildings/building_grape_arc_tower.tres"
)
const HYDRANGEA_RAIN_TOWER_ITEM: PickupConfig = preload(
	"res://resources/config/buildings/building_hydrangea_rain_tower.tres"
)
const ORANGE_CHARGING_TOWER_ITEM: PickupConfig = preload(
	"res://resources/config/buildings/building_orange_charging_tower.tres"
)
const LIFE_TOWER_ITEM: PickupConfig = preload(
	"res://resources/config/buildings/building_life_tower.tres"
)
const SPEED_TOWER_ITEM: PickupConfig = preload(
	"res://resources/config/buildings/building_speed_tower.tres"
)
const ATTACK_SPEED_TOWER_ITEM: PickupConfig = preload(
	"res://resources/config/buildings/building_attack_speed_tower.tres"
)
const WOOD_PROCESSING_STATION_ITEM: PickupConfig = preload(
	"res://resources/config/buildings/building_wood_processing_station.tres"
)
const WATER_COLLECTOR_ITEM: PickupConfig = preload(
	"res://resources/config/buildings/building_water_collector.tres"
)
const PLANTING_BASE_ITEM: PickupConfig = preload(
	"res://resources/config/buildings/building_planting_base.tres"
)
const PLANT_CULTIVATION_CENTER_ITEM: PickupConfig = preload(
	"res://resources/config/buildings/building_plant_cultivation_center.tres"
)
const EXCAVATOR_ITEM: PickupConfig = preload(
	"res://resources/config/buildings/building_excavator.tres"
)
const STONE_MILL_ITEM: PickupConfig = preload(
	"res://resources/config/buildings/building_stone_mill.tres"
)
const RESEARCH_CENTER_ITEM: PickupConfig = preload(
	"res://resources/config/buildings/building_research_center.tres"
)
const SIMPLE_FENCE_ITEM: PickupConfig = preload(
	"res://resources/config/buildings/building_simple_fence.tres"
)
const VEGETATION_STAKE_ITEM: PickupConfig = preload(
	"res://resources/config/buildings/building_vegetation_stake.tres"
)
const OAK_WAREHOUSE_ITEM: PickupConfig = preload(
	"res://resources/config/buildings/building_oak_warehouse.tres"
)

const AGAVE_CANNON_RECIPE: ProductionRecipe = preload(
	"res://resources/config/production/wooden_core_to_agave_cannon.tres"
)
const BAMBOO_MORTAR_RECIPE: ProductionRecipe = preload(
	"res://resources/config/production/wooden_core_to_bamboo_mortar.tres"
)
const CORN_MACHINE_GUN_RECIPE: ProductionRecipe = preload(
	"res://resources/config/production/wooden_core_to_corn_machine_gun.tres"
)
const GRAPE_ARC_TOWER_RECIPE: ProductionRecipe = preload(
	"res://resources/config/production/wooden_core_to_grape_arc_tower.tres"
)
const HYDRANGEA_RAIN_TOWER_RECIPE: ProductionRecipe = preload(
	"res://resources/config/production/wooden_core_to_hydrangea_rain_tower.tres"
)
const ORANGE_CHARGING_TOWER_RECIPE: ProductionRecipe = preload(
	"res://resources/config/production/wooden_core_to_orange_charging_tower.tres"
)
const LIFE_TOWER_RECIPE: ProductionRecipe = preload(
	"res://resources/config/production/wooden_core_to_life_tower.tres"
)
const SPEED_TOWER_RECIPE: ProductionRecipe = preload(
	"res://resources/config/production/wooden_core_to_speed_tower.tres"
)
const ATTACK_SPEED_TOWER_RECIPE: ProductionRecipe = preload(
	"res://resources/config/production/wooden_core_to_attack_speed_tower.tres"
)
const WOOD_PROCESSING_STATION_RECIPE: ProductionRecipe = preload(
	"res://resources/config/production/simple_wood_processing_station.tres"
)
const WATER_COLLECTOR_RECIPE: ProductionRecipe = preload(
	"res://resources/config/production/water_collector_assembly.tres"
)
const PLANTING_BASE_RECIPE: ProductionRecipe = preload(
	"res://resources/config/production/planting_base_assembly.tres"
)
const PLANT_CULTIVATION_CENTER_RECIPE: ProductionRecipe = preload(
	"res://resources/config/production/plant_cultivation_center_assembly.tres"
)
const EXCAVATOR_RECIPE: ProductionRecipe = preload(
	"res://resources/config/production/excavator_assembly.tres"
)
const STONE_MILL_RECIPE: ProductionRecipe = preload(
	"res://resources/config/production/simple_stone_mill.tres"
)
const RESEARCH_CENTER_RECIPE: ProductionRecipe = preload(
	"res://resources/config/production/research_center_assembly.tres"
)
const SIMPLE_FENCE_RECIPE: ProductionRecipe = preload(
	"res://resources/config/production/simple_simple_fence.tres"
)
const VEGETATION_STAKE_RECIPE: ProductionRecipe = preload(
	"res://resources/config/production/simple_vegetation_stake.tres"
)
const OAK_WAREHOUSE_RECIPE: ProductionRecipe = preload(
	"res://resources/config/production/simple_oak_warehouse.tres"
)

const BUILDING_ITEMS := {
	&"agave_cannon": AGAVE_CANNON_ITEM,
	&"bamboo_mortar": BAMBOO_MORTAR_ITEM,
	&"corn_machine_gun": CORN_MACHINE_GUN_ITEM,
	&"grape_arc_tower": GRAPE_ARC_TOWER_ITEM,
	&"hydrangea_rain_tower": HYDRANGEA_RAIN_TOWER_ITEM,
	&"orange_charging_tower": ORANGE_CHARGING_TOWER_ITEM,
	&"life_tower": LIFE_TOWER_ITEM,
	&"speed_tower": SPEED_TOWER_ITEM,
	&"attack_speed_tower": ATTACK_SPEED_TOWER_ITEM,
	&"wood_processing_station": WOOD_PROCESSING_STATION_ITEM,
	&"water_collector": WATER_COLLECTOR_ITEM,
	&"planting_base": PLANTING_BASE_ITEM,
	&"plant_cultivation_center": PLANT_CULTIVATION_CENTER_ITEM,
	&"excavator": EXCAVATOR_ITEM,
	&"stone_mill": STONE_MILL_ITEM,
	&"research_center": RESEARCH_CENTER_ITEM,
	&"simple_fence": SIMPLE_FENCE_ITEM,
	&"vegetation_stake": VEGETATION_STAKE_ITEM,
	&"oak_warehouse": OAK_WAREHOUSE_ITEM,
}

# Each formal building names one known-good route. A building may have additional
# recipes, but this map makes the minimum content-closure contract explicit.
const PRIMARY_ACQUISITION_RECIPES := {
	&"agave_cannon": AGAVE_CANNON_RECIPE,
	&"bamboo_mortar": BAMBOO_MORTAR_RECIPE,
	&"corn_machine_gun": CORN_MACHINE_GUN_RECIPE,
	&"grape_arc_tower": GRAPE_ARC_TOWER_RECIPE,
	&"hydrangea_rain_tower": HYDRANGEA_RAIN_TOWER_RECIPE,
	&"orange_charging_tower": ORANGE_CHARGING_TOWER_RECIPE,
	&"life_tower": LIFE_TOWER_RECIPE,
	&"speed_tower": SPEED_TOWER_RECIPE,
	&"attack_speed_tower": ATTACK_SPEED_TOWER_RECIPE,
	&"wood_processing_station": WOOD_PROCESSING_STATION_RECIPE,
	&"water_collector": WATER_COLLECTOR_RECIPE,
	&"planting_base": PLANTING_BASE_RECIPE,
	&"plant_cultivation_center": PLANT_CULTIVATION_CENTER_RECIPE,
	&"excavator": EXCAVATOR_RECIPE,
	&"stone_mill": STONE_MILL_RECIPE,
	&"research_center": RESEARCH_CENTER_RECIPE,
	&"simple_fence": SIMPLE_FENCE_RECIPE,
	&"vegetation_stake": VEGETATION_STAKE_RECIPE,
	&"oak_warehouse": OAK_WAREHOUSE_RECIPE,
}


static func get_item(plant_id: StringName) -> PickupConfig:
	var item := BUILDING_ITEMS.get(plant_id) as PickupConfig
	return item if _has_item_contract(item, plant_id) else null


static func get_plant_id(item: PickupConfig) -> StringName:
	if item == null or item.pickup_type != PickupConfig.PickupType.BUILDING:
		return &""
	var plant_id := item.placeable_plant_id
	var registered_item := BUILDING_ITEMS.get(plant_id) as PickupConfig
	return (
		plant_id
		if PickupConfig.inventory_identity_matches(registered_item, item)
		else &""
	)


static func get_all_items() -> Array[PickupConfig]:
	var items: Array[PickupConfig] = []
	for config in PlantDefenseRegistry.get_all_configs():
		var item := get_item(config.plant_id)
		if item != null:
			items.append(item)
	return items


static func get_primary_acquisition_recipe(
	plant_id: StringName
) -> ProductionRecipe:
	var recipe := PRIMARY_ACQUISITION_RECIPES.get(plant_id) as ProductionRecipe
	var item := get_item(plant_id)
	return recipe if _recipe_outputs_item(recipe, item) else null


static func has_acquisition_route(plant_id: StringName) -> bool:
	return get_primary_acquisition_recipe(plant_id) != null


static func validate_contract() -> bool:
	var configs := PlantDefenseRegistry.get_all_configs()
	if (
		configs.size() != BUILDING_ITEMS.size()
		or configs.size() != PRIMARY_ACQUISITION_RECIPES.size()
	):
		return false
	var seen_item_paths := {}
	for config in configs:
		var item := get_item(config.plant_id)
		if item == null or item.resource_path.is_empty():
			return false
		if seen_item_paths.has(item.resource_path):
			return false
		seen_item_paths[item.resource_path] = true
		if get_plant_id(item) != config.plant_id:
			return false
		if not has_acquisition_route(config.plant_id):
			return false
	return true


static func _has_item_contract(
	item: PickupConfig,
	plant_id: StringName
) -> bool:
	return (
		item != null
		and item.pickup_type == PickupConfig.PickupType.BUILDING
		and item.can_store_in_inventory
		and item.placeable_plant_id == plant_id
	)


static func _recipe_outputs_item(
	recipe: ProductionRecipe,
	item: PickupConfig
) -> bool:
	if recipe == null or item == null or not recipe.is_valid():
		return false
	for output_item in recipe.output_items:
		if PickupConfig.inventory_identity_matches(output_item, item):
			return true
	return false
