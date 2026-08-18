extends Resource
class_name GlobalResearchConfig

const MAX_INPUT_ITEMS := 4
const CATEGORY_ATTRIBUTE: StringName = &"attribute"
const CATEGORY_RECIPE_UNLOCK: StringName = &"recipe_unlock"
const CATEGORY_BUILDING_ENHANCEMENT: StringName = &"building_enhancement"
const SUPPORTED_CATEGORY_IDS: Array[StringName] = [
	CATEGORY_ATTRIBUTE,
	CATEGORY_RECIPE_UNLOCK,
	CATEGORY_BUILDING_ENHANCEMENT,
]

@export_group("基础信息")
@export var research_id: StringName = &""
@export var display_name: String = "全局研究"
@export_multiline var description: String = ""
@export var category_id: StringName = CATEGORY_ATTRIBUTE
@export var prerequisite_research_id: StringName = &""

@export_group("投入")
@export var input_items: Array[PickupConfig] = []
@export var input_amounts: Array[int] = []

@export_group("研究")
@export_range(0.1, 3600.0, 0.1, "or_greater") var duration_seconds: float = 60.0
@export var effects: Array[GlobalResearchEffect] = []


func is_valid() -> bool:
	if (
		research_id == &""
		or display_name.is_empty()
		or description.is_empty()
		or category_id not in SUPPORTED_CATEGORY_IDS
		or input_items.is_empty()
		or input_items.size() != input_amounts.size()
		or input_items.size() > MAX_INPUT_ITEMS
		or not is_finite(duration_seconds)
		or duration_seconds <= 0.0
		or effects.is_empty()
	):
		return false
	var semantic_keys := {}
	for effect in effects:
		if effect == null or not effect.is_valid():
			return false
		var semantic_key := effect.get_semantic_key()
		if semantic_key == &"" or semantic_keys.has(semantic_key):
			return false
		semantic_keys[semantic_key] = true
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
