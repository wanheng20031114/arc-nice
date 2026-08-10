@tool
extends Resource
class_name RogueCombatRewardItemEntry

@export var item: PickupConfig
@export_range(1, 999, 1, "or_greater") var count: int = 1


func validate_entry() -> PackedStringArray:
	var errors := PackedStringArray()
	if item == null:
		errors.append("作战固定物品奖励缺少 PickupConfig。")
	elif not item.can_store_in_inventory:
		errors.append("作战固定物品奖励必须允许写入背包：%s。" % item.resource_path)
	if count <= 0:
		errors.append("作战固定物品奖励数量必须大于0。")
	return errors


func compute_contract_fragment() -> String:
	if item == null:
		return ""
	return "%s:%d" % [item.resource_path, count]
