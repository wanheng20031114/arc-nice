extends RefCounted
class_name SimpleCraftingRegistry

const HERBAL_HEALTH_POTION_ID: StringName = &"herbal_health_potion"
const HERBAL_HEALTH_POTION_RECIPE: ProductionRecipe = preload(
	"res://resources/config/production/simple_herbal_health_potion.tres"
)
const WOOD_PROCESSING_STATION_ID: StringName = &"wood_processing_station"
const WOOD_PROCESSING_STATION_RECIPE: ProductionRecipe = preload(
	"res://resources/config/production/simple_wood_processing_station.tres"
)
const OAK_WAREHOUSE_ID: StringName = &"oak_warehouse"
const OAK_WAREHOUSE_RECIPE: ProductionRecipe = preload(
	"res://resources/config/production/simple_oak_warehouse.tres"
)
const VEGETATION_STAKE_ID: StringName = &"vegetation_stake"
const VEGETATION_STAKE_RECIPE: ProductionRecipe = preload(
	"res://resources/config/production/simple_vegetation_stake.tres"
)
const STONE_MILL_ID: StringName = &"stone_mill"
const STONE_MILL_RECIPE: ProductionRecipe = preload(
	"res://resources/config/production/simple_stone_mill.tres"
)
const SIMPLE_FENCE_ID: StringName = &"simple_fence"
const SIMPLE_FENCE_RECIPE: ProductionRecipe = preload(
	"res://resources/config/production/simple_simple_fence.tres"
)
const BAMBOO_MORTAR_ID: StringName = &"bamboo_mortar"
const BAMBOO_MORTAR_RECIPE: ProductionRecipe = preload(
	"res://resources/config/production/simple_bamboo_mortar.tres"
)
const HYDRANGEA_RAIN_TOWER_ID: StringName = &"hydrangea_rain_tower"
const HYDRANGEA_RAIN_TOWER_RECIPE: ProductionRecipe = preload(
	"res://resources/config/production/simple_hydrangea_rain_tower.tres"
)

const RECIPES := {
	HERBAL_HEALTH_POTION_ID: HERBAL_HEALTH_POTION_RECIPE,
	WOOD_PROCESSING_STATION_ID: WOOD_PROCESSING_STATION_RECIPE,
	OAK_WAREHOUSE_ID: OAK_WAREHOUSE_RECIPE,
	VEGETATION_STAKE_ID: VEGETATION_STAKE_RECIPE,
	STONE_MILL_ID: STONE_MILL_RECIPE,
	SIMPLE_FENCE_ID: SIMPLE_FENCE_RECIPE,
	BAMBOO_MORTAR_ID: BAMBOO_MORTAR_RECIPE,
	HYDRANGEA_RAIN_TOWER_ID: HYDRANGEA_RAIN_TOWER_RECIPE,
}
const MAX_WIRE_RECIPE_ID_LENGTH := 64


static func get_recipe(recipe_id: StringName) -> ProductionRecipe:
	var recipe := RECIPES.get(recipe_id) as ProductionRecipe
	return recipe if _has_simple_crafting_contract(recipe) else null


static func get_recipe_by_wire_id(recipe_id: String) -> ProductionRecipe:
	if recipe_id.is_empty() or recipe_id.length() > MAX_WIRE_RECIPE_ID_LENGTH:
		return null
	for registered_id_variant in RECIPES:
		var registered_id := registered_id_variant as StringName
		if String(registered_id) == recipe_id:
			return get_recipe(registered_id)
	return null


static func get_all_recipes() -> Array[ProductionRecipe]:
	var recipes: Array[ProductionRecipe] = []
	for recipe_id in [
		HERBAL_HEALTH_POTION_ID,
		WOOD_PROCESSING_STATION_ID,
		OAK_WAREHOUSE_ID,
		VEGETATION_STAKE_ID,
		STONE_MILL_ID,
		SIMPLE_FENCE_ID,
		BAMBOO_MORTAR_ID,
		HYDRANGEA_RAIN_TOWER_ID,
	]:
		var crafting_recipe := get_recipe(recipe_id)
		if _has_simple_crafting_contract(crafting_recipe):
			recipes.append(crafting_recipe)
	return recipes


static func get_available_recipes(
	completed_global_research_ids: Array[StringName] = []
) -> Array[ProductionRecipe]:
	var recipes: Array[ProductionRecipe] = []
	for recipe in get_all_recipes():
		if is_recipe_unlocked(recipe, completed_global_research_ids):
			recipes.append(recipe)
	return recipes


static func is_recipe_unlocked(
	recipe: ProductionRecipe,
	completed_global_research_ids: Array[StringName] = []
) -> bool:
	if not is_simple_crafting_recipe(recipe):
		return false
	if not recipe.requires_global_research():
		return true
	return recipe.required_global_research_id in completed_global_research_ids


static func is_simple_crafting_recipe(recipe: ProductionRecipe) -> bool:
	if not _has_simple_crafting_contract(recipe):
		return false
	return RECIPES.get(recipe.recipe_id) == recipe


static func _has_simple_crafting_contract(recipe: ProductionRecipe) -> bool:
	return (
		recipe != null
		and recipe.is_valid()
		and recipe.inputs_from_player_inventory()
		and recipe.outputs_to_player_inventory()
		and not recipe.uses_environment_source()
	)
