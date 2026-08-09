@tool
extends Resource
class_name RogueUndergroundShopListing

enum PriceTier {
	LOW,
	MEDIUM,
	HIGH,
}

@export var item: PickupConfig
@export var price_tier: PriceTier = PriceTier.LOW


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
	if price_tier < PriceTier.LOW or price_tier > PriceTier.HIGH:
		errors.append("地下商店消耗品条目的价格档位无效。")
	return errors


func get_config_path() -> String:
	return item.resource_path if item != null else ""
