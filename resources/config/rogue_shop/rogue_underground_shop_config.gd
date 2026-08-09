@tool
extends Resource
class_name RogueUndergroundShopConfig

const RUNTIME_CONTRACT_SCHEMA := 3
const CONSUMABLE_SELECTION_RULE := "uniform_without_replacement"
const CONSUMABLE_PRICE_RULE := "stable_per_session_item"
const MINIMUM_CONSUMABLE_LISTING_COUNT := 4
const LOW_CONSUMABLE_PRICE_BAND := Vector3i(80, 130, 10)
const MEDIUM_CONSUMABLE_PRICE_BAND := Vector3i(160, 300, 10)
const HIGH_CONSUMABLE_PRICE_BAND := Vector3i(700, 1000, 10)

@export_range(1, 32, 1) var offer_count := 8
@export var collectible_count_choices := PackedInt32Array([4, 5, 6])
@export var consumable_listings: Array[RogueUndergroundShopListing] = []

@export_group("收藏品购买价格")
@export_range(0, 100000, 10) var common_price_minimum := 200
@export_range(0, 100000, 10) var common_price_maximum := 500
@export_range(1, 10000, 1) var common_price_step := 10
@export_range(0, 100000, 10) var rare_price_minimum := 500
@export_range(0, 100000, 10) var rare_price_maximum := 1000
@export_range(1, 10000, 1) var rare_price_step := 10
@export_range(0, 100000, 100) var epic_price_minimum := 1000
@export_range(0, 100000, 100) var epic_price_maximum := 2000
@export_range(1, 10000, 1) var epic_price_step := 100
@export_range(0, 100000, 100) var legendary_price_minimum := 5000
@export_range(0, 100000, 100) var legendary_price_maximum := 10000
@export_range(1, 10000, 1) var legendary_price_step := 100

@export_group("通用出售价格")
@export_range(0, 100000, 1) var material_sell_price := 10
@export_range(0, 100000, 1) var collectible_sell_price := 100


func validate_config() -> PackedStringArray:
	var errors := PackedStringArray()
	if offer_count != 8:
		errors.append("地下商店当前必须固定提供 8 个报价。")
	if collectible_count_choices.is_empty():
		errors.append("地下商店缺少收藏品数量候选。")
	else:
		var seen_counts: Dictionary = {}
		for collectible_count in collectible_count_choices:
			if collectible_count < 0 or collectible_count > offer_count:
				errors.append("地下商店收藏品数量超出报价容量。")
			elif seen_counts.has(collectible_count):
				errors.append("地下商店收藏品数量候选不可重复。")
			seen_counts[collectible_count] = true
		if seen_counts.keys().size() != 3 or not (
			seen_counts.has(4)
			and seen_counts.has(5)
			and seen_counts.has(6)
		):
			errors.append("地下商店收藏品数量候选必须恰好为 4、5、6。")
	_validate_consumable_listings(errors)
	_validate_price_band(
		errors,
		"普通",
		common_price_minimum,
		common_price_maximum,
		common_price_step
	)
	_validate_price_band(
		errors,
		"稀有",
		rare_price_minimum,
		rare_price_maximum,
		rare_price_step
	)
	_validate_price_band(
		errors,
		"史诗",
		epic_price_minimum,
		epic_price_maximum,
		epic_price_step
	)
	_validate_price_band(
		errors,
		"传说",
		legendary_price_minimum,
		legendary_price_maximum,
		legendary_price_step
	)
	if material_sell_price <= 0 or collectible_sell_price <= 0:
		errors.append("地下商店通用出售价格必须大于 0。")
	return errors


func get_collectible_price_band(rarity: int) -> Vector3i:
	match rarity:
		PickupConfig.CollectibleRarity.COMMON:
			return Vector3i(
				common_price_minimum,
				common_price_maximum,
				common_price_step
			)
		PickupConfig.CollectibleRarity.RARE:
			return Vector3i(
				rare_price_minimum,
				rare_price_maximum,
				rare_price_step
			)
		PickupConfig.CollectibleRarity.EPIC:
			return Vector3i(
				epic_price_minimum,
				epic_price_maximum,
				epic_price_step
			)
		PickupConfig.CollectibleRarity.LEGENDARY:
			return Vector3i(
				legendary_price_minimum,
				legendary_price_maximum,
				legendary_price_step
			)
		_:
			return Vector3i.ZERO


func get_consumable_listing_by_path(
	config_path: String
) -> RogueUndergroundShopListing:
	if config_path.is_empty():
		return null
	for listing in consumable_listings:
		if listing != null and listing.get_config_path() == config_path:
			return listing
	return null


func get_consumable_price_band(price_tier: int) -> Vector3i:
	match price_tier:
		RogueUndergroundShopListing.PriceTier.LOW:
			return LOW_CONSUMABLE_PRICE_BAND
		RogueUndergroundShopListing.PriceTier.MEDIUM:
			return MEDIUM_CONSUMABLE_PRICE_BAND
		RogueUndergroundShopListing.PriceTier.HIGH:
			return HIGH_CONSUMABLE_PRICE_BAND
		_:
			return Vector3i.ZERO


func compute_runtime_contract_hash() -> String:
	if not validate_config().is_empty():
		return ""
	var choices := collectible_count_choices.duplicate()
	choices.sort()
	var choice_parts := PackedStringArray()
	for choice in choices:
		choice_parts.append(str(choice))
	var listing_parts := PackedStringArray()
	for listing in consumable_listings:
		listing_parts.append("%s,%d" % [
			listing.get_config_path(),
			int(listing.price_tier),
		])
	listing_parts.sort()
	return "\n".join(PackedStringArray([
		"schema=%d" % RUNTIME_CONTRACT_SCHEMA,
		"offers=%d" % offer_count,
		"collectible_counts=%s" % ",".join(choice_parts),
		"consumable_selection=%s" % CONSUMABLE_SELECTION_RULE,
		"consumable_pricing=%s" % CONSUMABLE_PRICE_RULE,
		"consumable_price_bands=%d,%d,%d;%d,%d,%d;%d,%d,%d" % [
			LOW_CONSUMABLE_PRICE_BAND.x,
			LOW_CONSUMABLE_PRICE_BAND.y,
			LOW_CONSUMABLE_PRICE_BAND.z,
			MEDIUM_CONSUMABLE_PRICE_BAND.x,
			MEDIUM_CONSUMABLE_PRICE_BAND.y,
			MEDIUM_CONSUMABLE_PRICE_BAND.z,
			HIGH_CONSUMABLE_PRICE_BAND.x,
			HIGH_CONSUMABLE_PRICE_BAND.y,
			HIGH_CONSUMABLE_PRICE_BAND.z,
		],
		"consumables=%s" % ";".join(listing_parts),
		"collectible_purchase=%d,%d,%d;%d,%d,%d;%d,%d,%d;%d,%d,%d" % [
			common_price_minimum,
			common_price_maximum,
			common_price_step,
			rare_price_minimum,
			rare_price_maximum,
			rare_price_step,
			epic_price_minimum,
			epic_price_maximum,
			epic_price_step,
			legendary_price_minimum,
			legendary_price_maximum,
			legendary_price_step,
		],
		"generic_sell=%d,%d" % [
			material_sell_price,
			collectible_sell_price,
		],
	])).sha256_text()


func _validate_consumable_listings(errors: PackedStringArray) -> void:
	if consumable_listings.size() < MINIMUM_CONSUMABLE_LISTING_COUNT:
		errors.append("地下商店消耗品池必须至少配置 4 个条目。")
	var seen_paths: Dictionary = {}
	for listing_index in consumable_listings.size():
		var listing := consumable_listings[listing_index]
		if listing == null:
			errors.append("地下商店消耗品条目 %d 为空。" % listing_index)
			continue
		for listing_error in listing.validate_listing():
			errors.append("消耗品条目 %d：%s" % [listing_index, listing_error])
		var config_path := listing.get_config_path()
		if config_path.is_empty():
			continue
		if seen_paths.has(config_path):
			errors.append("地下商店消耗品路径不可重复：%s" % config_path)
		seen_paths[config_path] = true


func _validate_price_band(
	errors: PackedStringArray,
	label: String,
	minimum: int,
	maximum: int,
	step: int
) -> void:
	if minimum <= 0 or maximum < minimum or step <= 0:
		errors.append("地下商店%s收藏品价格区间无效。" % label)
	elif minimum % step != 0 or maximum % step != 0:
		errors.append("地下商店%s收藏品价格必须按步长量化。" % label)
