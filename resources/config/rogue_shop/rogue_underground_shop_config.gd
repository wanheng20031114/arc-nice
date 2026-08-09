@tool
extends Resource
class_name RogueUndergroundShopConfig

const RUNTIME_CONTRACT_SCHEMA := 1

@export_range(1, 32, 1) var offer_count := 8
@export var collectible_count_choices := PackedInt32Array([4, 5, 6])
@export_file("*.tres") var health_potion_path := (
	"res://resources/config/pickups/pickup_health.tres"
)

@export_group("购买价格")
@export_range(0, 100000, 10) var health_potion_purchase_price := 50
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

@export_group("出售价格")
@export_range(0, 100000, 1) var material_sell_price := 10
@export_range(0, 100000, 1) var collectible_sell_price := 100
@export_range(0, 100000, 1) var health_potion_sell_price := 50


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
	if health_potion_path.is_empty():
		errors.append("地下商店缺少生命药瓶资源路径。")
	else:
		var potion := load(health_potion_path) as PickupConfig
		if (
			potion == null
			or potion.pickup_type != PickupConfig.PickupType.HEALTH
			or not potion.can_store_in_inventory
		):
			errors.append("地下商店生命药瓶资源无效。")
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
	if (
		health_potion_purchase_price <= 0
		or material_sell_price <= 0
		or collectible_sell_price <= 0
		or health_potion_sell_price <= 0
	):
		errors.append("地下商店买卖价格必须大于 0。")
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


func compute_runtime_contract_hash() -> String:
	if not validate_config().is_empty():
		return ""
	var choices := collectible_count_choices.duplicate()
	choices.sort()
	var choice_parts := PackedStringArray()
	for choice in choices:
		choice_parts.append(str(choice))
	return "\n".join(PackedStringArray([
		"schema=%d" % RUNTIME_CONTRACT_SCHEMA,
		"offers=%d" % offer_count,
		"collectible_counts=%s" % ",".join(choice_parts),
		"health_path=%s" % health_potion_path,
		"purchase=%d;%d,%d,%d;%d,%d,%d;%d,%d,%d;%d,%d,%d" % [
			health_potion_purchase_price,
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
		"sell=%d,%d,%d" % [
			material_sell_price,
			collectible_sell_price,
			health_potion_sell_price,
		],
	])).sha256_text()


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
