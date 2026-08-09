extends Control

signal preview_purchase_requested(offer_index: int)
signal exit_requested

const SAMPLE_ITEMS: Array[PickupConfig] = [
	preload("res://resources/config/pickups/pickup_health.tres"),
	preload("res://resources/config/collectibles/collectible_iron_dagger.tres"),
	preload("res://resources/config/collectibles/collectible_oil_lamp.tres"),
	preload("res://resources/config/collectibles/collectible_apprentice_scroll.tres"),
	preload("res://resources/config/collectibles/collectible_obsidian_key.tres"),
	preload("res://resources/config/collectibles/collectible_frost_crystal.tres"),
	preload("res://resources/config/collectibles/collectible_royal_goblet.tres"),
	preload("res://resources/config/pickups/pickup_health.tres"),
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
	for index in range(SAMPLE_ITEMS.size()):
		var item := SAMPLE_ITEMS[index]
		offers.append({
			"offer_index": index,
			"config_path": item.resource_path,
			"item": item,
			"price": 50 if item.pickup_type == PickupConfig.PickupType.HEALTH else 200 + index * 70,
			"purchased": false,
		})
	return offers


func _build_sample_sell_slots() -> Array[Dictionary]:
	var slots: Array[Dictionary] = []
	for index in range(SAMPLE_ITEMS.size()):
		var item := SAMPLE_ITEMS[index]
		slots.append({
			"slot_index": index,
			"config_path": item.resource_path,
			"item": item,
			"stack_count": 3 if index == 0 else 1,
			"sell_price": 50 if item.pickup_type == PickupConfig.PickupType.HEALTH else 100,
			"can_sell": true,
		})
	return slots


func _on_purchase_requested(offer_index: int) -> void:
	preview_purchase_requested.emit(offer_index)


func _on_exit_requested() -> void:
	exit_requested.emit()
