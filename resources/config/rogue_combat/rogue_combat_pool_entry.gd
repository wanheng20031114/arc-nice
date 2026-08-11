@tool
extends Resource
class_name RogueCombatPoolEntry

@export var combat_config: RogueCombatEncounterConfig
@export_range(1, 1000000, 1, "or_greater") var selection_weight := 1


func validate_entry() -> PackedStringArray:
	var errors := PackedStringArray()
	if combat_config == null:
		errors.append("普通作战池条目缺少 combat_config。")
	else:
		errors.append_array(combat_config.validate_config())
	if selection_weight <= 0:
		errors.append("普通作战池条目的 selection_weight 必须大于0。")
	return errors
