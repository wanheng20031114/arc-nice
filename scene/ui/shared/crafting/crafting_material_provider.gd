extends Node
class_name CraftingMaterialProvider

signal material_state_changed


## Returns only the mode-owned shared contribution. The panel adds the active
## player's inventory count so output ownership remains explicit.
func get_shared_material_item_total(_item: PickupConfig) -> int:
	return 0


func get_simple_crafting_result(
	_recipe: ProductionRecipe,
	_completed_global_research_ids: Array[StringName] = []
) -> StringName:
	return RunStateStore.CRAFT_RESULT_INVALID_RECIPE


func try_commit_simple_crafting_recipe(
	_recipe: ProductionRecipe,
	_expected_inventory_revision: int,
	_completed_global_research_ids: Array[StringName] = []
) -> StringName:
	return RunStateStore.CRAFT_RESULT_INVALID_RECIPE


func try_commit_simple_crafting_recipe_for_peer(
	_peer_id: int,
	_recipe: ProductionRecipe,
	_expected_inventory_revision: int,
	_completed_global_research_ids: Array[StringName] = []
) -> StringName:
	return RunStateStore.CRAFT_RESULT_INVALID_RECIPE
