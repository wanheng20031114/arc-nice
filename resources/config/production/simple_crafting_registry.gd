extends RefCounted
class_name SimpleCraftingRegistry

const HERBAL_HEALTH_POTION_ID: StringName = &"herbal_health_potion"
const HERBAL_HEALTH_POTION_RECIPE: ProductionRecipe = preload(
	"res://resources/config/production/simple_herbal_health_potion.tres"
)

const RECIPES := {
	HERBAL_HEALTH_POTION_ID: HERBAL_HEALTH_POTION_RECIPE,
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
	for recipe in RECIPES.values():
		var crafting_recipe := recipe as ProductionRecipe
		if _has_simple_crafting_contract(crafting_recipe):
			recipes.append(crafting_recipe)
	return recipes


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
