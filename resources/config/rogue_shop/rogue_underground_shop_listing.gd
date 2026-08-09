@tool
extends Resource
class_name RogueUndergroundShopListing

@export var item: PickupConfig
@export_range(1, 100000, 1) var purchase_price := 1
@export_range(1, 100000, 1) var sell_price := 1


func validate_listing() -> PackedStringArray:
	var errors := PackedStringArray()
	if item == null:
		errors.append("地下商店消耗品条目缺少物品资源。")
		return errors
	if item.resource_path.is_empty():
		errors.append("地下商店消耗品条目必须引用已保存的物品资源。")
	if not item.is_consumable_item() or not item.can_store_in_inventory:
		errors.append("地下商店消耗品条目引用了非背包消耗品。")
	if not item.stackable or PickupConfig.get_inventory_stack_limit(item) != 999:
		errors.append("地下商店消耗品必须可堆叠，且单槽上限为 999。")
	if purchase_price <= 0 or sell_price <= 0:
		errors.append("地下商店消耗品条目的买卖价格必须大于 0。")
	if purchase_price != sell_price:
		errors.append("地下商店消耗品条目当前必须保持买卖同价。")
	return errors


func get_config_path() -> String:
	return item.resource_path if item != null else ""
