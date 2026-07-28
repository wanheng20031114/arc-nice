extends RefCounted
class_name LuoxiSpecialGameRules

const CARD_COUNT := 4
const ROLL_TOTAL := 100
const INVALID_CLASSIFICATION := -1

const DIRT_BLOCK_PATH := "res://resources/config/materials/material_dirt_block.tres"
const WOOD_PATH := "res://resources/config/materials/material_wood.tres"
const SAPLING_PATH := "res://resources/config/materials/material_sapling.tres"
const WOODEN_CORE_PATH := "res://resources/config/materials/material_wooden_core.tres"
const WHITE_CRYSTAL_PATH := "res://resources/config/materials/material_white_crystal.tres"
const CAPOO_BLUE_CRYSTAL_PATH := (
	"res://resources/config/materials/material_capoo_blue_crystal.tres"
)

enum OutcomeKind {
	COLLECTIBLE = 0,
	HEALTH_DAMAGE = 1,
	MATERIAL = 2,
	CORE_DAMAGE = 3,
	XIRANG = 4,
}

enum HealthEffect {
	SELF_FIXED = 0,
	SELF_LEAVE_ONE = 1,
	OTHERS_CURRENT_PERCENT = 2,
	ALL_FIXED = 3,
}


static func classify_kind(roll: int) -> int:
	if not _is_valid_roll(roll):
		return INVALID_CLASSIFICATION
	if roll < 25:
		return OutcomeKind.COLLECTIBLE
	if roll < 45:
		return OutcomeKind.HEALTH_DAMAGE
	if roll < 70:
		return OutcomeKind.MATERIAL
	if roll < 80:
		return OutcomeKind.CORE_DAMAGE
	return OutcomeKind.XIRANG


static func classify_collectible_rarity(roll: int) -> int:
	if not _is_valid_roll(roll):
		return INVALID_CLASSIFICATION
	if roll < 70:
		return PickupConfig.CollectibleRarity.COMMON
	if roll < 90:
		return PickupConfig.CollectibleRarity.RARE
	if roll < 98:
		return PickupConfig.CollectibleRarity.EPIC
	return PickupConfig.CollectibleRarity.LEGENDARY


static func classify_health_damage(roll: int) -> Dictionary:
	if not _is_valid_roll(roll):
		return {}
	if roll < 30:
		return _make_outcome(
			OutcomeKind.HEALTH_DAMAGE,
			HealthEffect.SELF_FIXED,
			40
		)
	if roll < 60:
		return _make_outcome(
			OutcomeKind.HEALTH_DAMAGE,
			HealthEffect.SELF_FIXED,
			20
		)
	if roll < 70:
		return _make_outcome(
			OutcomeKind.HEALTH_DAMAGE,
			HealthEffect.SELF_FIXED,
			10
		)
	if roll < 80:
		return _make_outcome(
			OutcomeKind.HEALTH_DAMAGE,
			HealthEffect.SELF_LEAVE_ONE,
			1
		)
	if roll < 85:
		return _make_outcome(
			OutcomeKind.HEALTH_DAMAGE,
			HealthEffect.OTHERS_CURRENT_PERCENT,
			90
		)
	if roll < 90:
		return _make_outcome(
			OutcomeKind.HEALTH_DAMAGE,
			HealthEffect.ALL_FIXED,
			1000
		)
	return _make_outcome(
		OutcomeKind.HEALTH_DAMAGE,
		HealthEffect.SELF_FIXED,
		3250
	)


static func classify_material(roll: int, crystal_roll: int) -> Dictionary:
	if not _is_valid_roll(roll) or not _is_valid_roll(crystal_roll):
		return {}
	if roll < 80:
		return _make_outcome(OutcomeKind.MATERIAL, 0, 1, DIRT_BLOCK_PATH)
	if roll < 85:
		return _make_outcome(OutcomeKind.MATERIAL, 0, 1, WOOD_PATH)
	if roll < 90:
		return _make_outcome(OutcomeKind.MATERIAL, 0, 1, SAPLING_PATH)
	if roll < 92:
		return _make_outcome(OutcomeKind.MATERIAL, 0, 1, WOODEN_CORE_PATH)
	var crystal_path := (
		WHITE_CRYSTAL_PATH
		if crystal_roll < 50
		else CAPOO_BLUE_CRYSTAL_PATH
	)
	return _make_outcome(OutcomeKind.MATERIAL, 0, 1, crystal_path)


static func classify_core_damage(roll: int) -> Dictionary:
	if not _is_valid_roll(roll):
		return {}
	return _make_outcome(
		OutcomeKind.CORE_DAMAGE,
		0,
		1 if roll < 90 else 5
	)


static func classify_xirang(roll: int) -> Dictionary:
	if not _is_valid_roll(roll):
		return {}
	var amount := 100
	if roll < 70:
		amount = 100
	elif roll < 90:
		amount = 325
	elif roll < 93:
		amount = 1
	elif roll < 96:
		amount = 799
	elif roll < 99:
		amount = 2000
	else:
		amount = 9999
	return _make_outcome(OutcomeKind.XIRANG, 0, amount)


static func roll_cards(
	rng: RandomNumberGenerator,
	collectible_pool: Array
) -> Array[Dictionary]:
	var outcomes: Array[Dictionary] = []
	if rng == null:
		return outcomes
	for _card_index in range(CARD_COUNT):
		var outcome := _roll_outcome(rng, collectible_pool)
		if outcome.is_empty():
			outcomes.clear()
			return outcomes
		outcomes.append(outcome)
	return outcomes


static func is_valid_outcome(outcome: Dictionary) -> bool:
	if outcome.size() != 5:
		return false
	for required_key in ["kind", "effect", "amount", "item_path", "rarity"]:
		if not outcome.has(required_key):
			return false
	if (
		typeof(outcome["kind"]) != TYPE_INT
		or typeof(outcome["effect"]) != TYPE_INT
		or typeof(outcome["amount"]) != TYPE_INT
		or typeof(outcome["item_path"]) != TYPE_STRING
		or typeof(outcome["rarity"]) != TYPE_INT
	):
		return false

	var kind := int(outcome["kind"])
	var effect := int(outcome["effect"])
	var amount := int(outcome["amount"])
	var item_path := String(outcome["item_path"])
	var rarity := int(outcome["rarity"])
	match kind:
		OutcomeKind.COLLECTIBLE:
			return (
				effect == 0
				and amount == 1
				and not item_path.is_empty()
				and rarity >= PickupConfig.CollectibleRarity.COMMON
				and rarity <= PickupConfig.CollectibleRarity.LEGENDARY
			)
		OutcomeKind.HEALTH_DAMAGE:
			if not item_path.is_empty() or rarity != -1:
				return false
			match effect:
				HealthEffect.SELF_FIXED:
					return amount in [10, 20, 40, 3250]
				HealthEffect.SELF_LEAVE_ONE:
					return amount == 1
				HealthEffect.OTHERS_CURRENT_PERCENT:
					return amount == 90
				HealthEffect.ALL_FIXED:
					return amount == 1000
		OutcomeKind.MATERIAL:
			return (
				effect == 0
				and amount == 1
				and rarity == -1
				and item_path in _get_material_paths()
			)
		OutcomeKind.CORE_DAMAGE:
			return (
				effect == 0
				and amount in [1, 5]
				and item_path.is_empty()
				and rarity == -1
			)
		OutcomeKind.XIRANG:
			return (
				effect == 0
				and amount in [1, 100, 325, 799, 2000, 9999]
				and item_path.is_empty()
				and rarity == -1
			)
	return false


static func _roll_outcome(
	rng: RandomNumberGenerator,
	collectible_pool: Array
) -> Dictionary:
	var kind := classify_kind(rng.randi_range(0, ROLL_TOTAL - 1))
	match kind:
		OutcomeKind.COLLECTIBLE:
			return _roll_collectible(rng, collectible_pool)
		OutcomeKind.HEALTH_DAMAGE:
			return classify_health_damage(rng.randi_range(0, ROLL_TOTAL - 1))
		OutcomeKind.MATERIAL:
			return classify_material(
				rng.randi_range(0, ROLL_TOTAL - 1),
				rng.randi_range(0, ROLL_TOTAL - 1)
			)
		OutcomeKind.CORE_DAMAGE:
			return classify_core_damage(rng.randi_range(0, ROLL_TOTAL - 1))
		OutcomeKind.XIRANG:
			return classify_xirang(rng.randi_range(0, ROLL_TOTAL - 1))
	return {}


static func _roll_collectible(
	rng: RandomNumberGenerator,
	collectible_pool: Array
) -> Dictionary:
	var rarity := classify_collectible_rarity(
		rng.randi_range(0, ROLL_TOTAL - 1)
	)
	return roll_collectible_for_rarity(rng, collectible_pool, rarity)


static func roll_collectible_for_rarity(
	rng: RandomNumberGenerator,
	collectible_pool: Array,
	rarity: int
) -> Dictionary:
	if (
		rng == null
		or rarity < PickupConfig.CollectibleRarity.COMMON
		or rarity > PickupConfig.CollectibleRarity.LEGENDARY
	):
		return {}
	var compatible_items: Array[PickupConfig] = []
	for candidate_variant: Variant in collectible_pool:
		var candidate := candidate_variant as PickupConfig
		if candidate == null or int(candidate.collectible_rarity) != rarity:
			continue
		if candidate.resource_path.is_empty():
			continue
		compatible_items.append(candidate)
	if compatible_items.is_empty():
		return {}
	var selected := compatible_items[rng.randi_range(0, compatible_items.size() - 1)]
	return _make_outcome(
		OutcomeKind.COLLECTIBLE,
		0,
		1,
		selected.resource_path,
		rarity
	)


static func _make_outcome(
	kind: int,
	effect: int,
	amount: int,
	item_path: String = "",
	rarity: int = -1
) -> Dictionary:
	return {
		"kind": kind,
		"effect": effect,
		"amount": amount,
		"item_path": item_path,
		"rarity": rarity,
	}


static func _get_material_paths() -> Array[String]:
	return [
		DIRT_BLOCK_PATH,
		WOOD_PATH,
		SAPLING_PATH,
		WOODEN_CORE_PATH,
		WHITE_CRYSTAL_PATH,
		CAPOO_BLUE_CRYSTAL_PATH,
	]


static func _is_valid_roll(roll: int) -> bool:
	return roll >= 0 and roll < ROLL_TOTAL
