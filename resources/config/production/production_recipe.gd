extends Resource
class_name ProductionRecipe

@export_group("基础信息")
@export var recipe_id: StringName = &""
@export var display_name: String = "生产配方"

@export_group("投入")
@export var input_item: PickupConfig = null
@export_range(1, 999, 1, "or_greater") var input_amount: int = 1

@export_group("产出")
@export var output_items: Array[PickupConfig] = []
@export var output_amounts: Array[int] = []

@export_group("生产")
@export_range(0.1, 3600.0, 0.1, "or_greater") var duration_seconds: float = 10.0


func is_valid() -> bool:
	if (
		recipe_id == &""
		or display_name.is_empty()
		or input_item == null
		or input_amount <= 0
		or output_items.is_empty()
		or output_items.size() != output_amounts.size()
		or not is_finite(duration_seconds)
		or duration_seconds <= 0.0
	):
		return false
	for output_index in output_items.size():
		if output_items[output_index] == null or output_amounts[output_index] <= 0:
			return false
	return true


func get_output_summary() -> String:
	var parts: PackedStringArray = []
	for output_index in output_items.size():
		parts.append(
			"%s ×%d" % [
				output_items[output_index].display_name,
				output_amounts[output_index],
			]
		)
	return "、".join(parts)
