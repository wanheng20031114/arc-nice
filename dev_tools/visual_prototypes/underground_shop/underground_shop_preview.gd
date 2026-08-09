extends Control

signal preview_purchase_requested(offer_index: int)
signal exit_requested

const SHOP_CONFIG: RogueUndergroundShopConfig = preload(
	"res://resources/config/rogue_shop/shallow_mine_underground_shop.tres"
)
const PREVIEW_NODE_SEED := 71031
const PREVIEW_STABLE_KEY := "underground-shop-preview"
const SAMPLE_ITEMS: Array[PickupConfig] = [
	preload("res://resources/config/consumables/healing_potion.tres"),
	preload("res://resources/config/consumables/large_healing_potion.tres"),
	preload("res://resources/config/consumables/rock_potion.tres"),
	preload("res://resources/config/consumables/large_rock_potion.tres"),
	preload("res://resources/config/collectibles/collectible_iron_dagger.tres"),
	preload("res://resources/config/collectibles/collectible_oil_lamp.tres"),
	preload("res://resources/config/collectibles/collectible_apprentice_scroll.tres"),
	preload("res://resources/config/collectibles/collectible_obsidian_key.tres"),
]

@onready var shop_view: RogueUndergroundShopView = %ShopView


func _ready() -> void:
	shop_view.present_buy_offers(_build_sample_offers())
	shop_view.present_sell_inventory(_build_sample_sell_slots())
	shop_view.open_session()


func open_offer(index: int) -> void:
	if index < 0 or index >= shop_view.get_item_cards().size():
		return
	shop_view.show_buy_tab()
	shop_view.get_item_cards()[index].pressed.emit()


func close_detail() -> void:
	shop_view.close_detail()


func get_product_cards() -> Array[RogueUndergroundShopItemCard]:
	return shop_view.get_item_cards()


func _build_sample_offers() -> Array[Dictionary]:
	var offers: Array[Dictionary] = []
	var consumable_prices := _build_consumable_price_lookup()
	for index in range(SAMPLE_ITEMS.size()):
		var item := SAMPLE_ITEMS[index]
		offers.append({
			"offer_index": index,
			"config_path": item.resource_path,
			"item": item,
			"kind": "consumable" if item.is_consumable_item() else "collectible",
			"price": (
				int(consumable_prices.get(item.resource_path, 0))
				if item.is_consumable_item()
				else 200 + index * 70
			),
			"purchased": false,
		})
	return offers


func _build_sample_sell_slots() -> Array[Dictionary]:
	var slots: Array[Dictionary] = []
	var consumable_prices := _build_consumable_price_lookup()
	for index in range(SAMPLE_ITEMS.size()):
		var item := SAMPLE_ITEMS[index]
		slots.append({
			"slot_index": index,
			"config_path": item.resource_path,
			"item": item,
			"stack_count": 3 if item.is_consumable_item() else 1,
			"sell_price": (
				int(consumable_prices.get(item.resource_path, 0))
				if item.is_consumable_item()
				else SHOP_CONFIG.collectible_sell_price
			),
			"can_sell": true,
		})
	return slots


func _build_consumable_price_lookup() -> Dictionary:
	var result: Dictionary = {}
	for entry in RogueUndergroundShopOfferGenerator.generate_consumable_prices(
		SHOP_CONFIG,
		PREVIEW_NODE_SEED,
		PREVIEW_STABLE_KEY
	):
		result[str(entry["config_path"])] = int(entry["price"])
	return result


func _on_purchase_requested(offer_index: int) -> void:
	preview_purchase_requested.emit(offer_index)


func _on_exit_requested() -> void:
	exit_requested.emit()
