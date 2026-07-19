extends Resource
class_name ProductionRecipe

const MAX_INPUT_ITEMS := 3
const MAX_OUTPUT_ITEMS := 3

enum InputSource {
	SHARED_STORAGE,
	PLAYER_INVENTORY,
}

enum OutputDestination {
	SHARED_STORAGE,
	PLAYER_INVENTORY,
}

@export_group("基础信息")
@export var recipe_id: StringName = &""
@export var display_name: String = "生产配方"

@export_group("投入")
@export var input_items: Array[PickupConfig] = []
# 单一投入且数量为 0 表示环境来源：只展示，不从仓库消耗。
@export var input_amounts: Array[int] = []
@export var input_source: InputSource = InputSource.SHARED_STORAGE

@export_group("产出")
@export var output_items: Array[PickupConfig] = []
@export var output_amounts: Array[int] = []
@export var output_destination: OutputDestination = OutputDestination.SHARED_STORAGE

@export_group("生产")
@export_range(0.1, 3600.0, 0.1, "or_greater") var duration_seconds: float = 10.0


func is_valid() -> bool:
	if (
		recipe_id == &""
		or display_name.is_empty()
		or input_items.is_empty()
		or input_items.size() != input_amounts.size()
		or input_items.size() > MAX_INPUT_ITEMS
		or input_source < InputSource.SHARED_STORAGE
		or input_source > InputSource.PLAYER_INVENTORY
		or output_items.is_empty()
		or output_items.size() != output_amounts.size()
		or output_items.size() > MAX_OUTPUT_ITEMS
		or output_destination < OutputDestination.SHARED_STORAGE
		or output_destination > OutputDestination.PLAYER_INVENTORY
		or not is_finite(duration_seconds)
		or duration_seconds <= 0.0
	):
		return false
	var environment_source_count := 0
	for input_index in input_items.size():
		if input_items[input_index] == null or input_amounts[input_index] < 0:
			return false
		if input_amounts[input_index] == 0:
			environment_source_count += 1
	if environment_source_count > 0 and (
		environment_source_count != 1
		or input_items.size() != 1
		or input_source != InputSource.SHARED_STORAGE
	):
		return false
	for output_index in output_items.size():
		if output_items[output_index] == null or output_amounts[output_index] <= 0:
			return false
	return true


func uses_environment_source() -> bool:
	return (
		input_items.size() == 1
		and input_amounts.size() == 1
		and input_amounts[0] == 0
	)


func outputs_to_player_inventory() -> bool:
	return output_destination == OutputDestination.PLAYER_INVENTORY


func inputs_from_player_inventory() -> bool:
	return input_source == InputSource.PLAYER_INVENTORY


func get_input_summary() -> String:
	var parts: PackedStringArray = []
	for input_index in input_items.size():
		var amount := input_amounts[input_index]
		parts.append(
			input_items[input_index].display_name
			if amount == 0
			else "%s ×%d" % [input_items[input_index].display_name, amount]
		)
	return "、".join(parts)


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
