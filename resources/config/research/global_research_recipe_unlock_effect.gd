extends GlobalResearchEffect
class_name GlobalResearchRecipeUnlockEffect

const CATALOG_SIMPLE_CRAFTING: StringName = &"simple_crafting"
const CATALOG_PRODUCTION: StringName = &"production"
const SUPPORTED_CATALOGS: Array[StringName] = [
	CATALOG_SIMPLE_CRAFTING,
	CATALOG_PRODUCTION,
]

@export var catalog: StringName = &""
@export var recipe_id: StringName = &""


func is_valid() -> bool:
	return catalog in SUPPORTED_CATALOGS and recipe_id != &""


func get_semantic_key() -> StringName:
	return StringName(
		"recipe_unlock:%s:%s" % [String(catalog), String(recipe_id)]
	)
