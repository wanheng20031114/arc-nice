extends RefCounted
class_name RogueUndergroundShopOfferGenerator

const OFFER_KIND_COLLECTIBLE := &"collectible"
const OFFER_KIND_CONSUMABLE := &"consumable"


static func generate_offers(
	config: RogueUndergroundShopConfig,
	node_content_seed: int,
	participant_stable_key: String,
	character_id: StringName
) -> Array[Dictionary]:
	return generate_offers_from_pool(
		config,
		node_content_seed,
		participant_stable_key,
		get_compatible_collectible_pool(character_id)
	)


static func generate_offers_from_pool(
	config: RogueUndergroundShopConfig,
	node_content_seed: int,
	participant_stable_key: String,
	compatible_collectibles: Array[PickupConfig]
) -> Array[Dictionary]:
	if (
		config == null
		or not config.validate_config().is_empty()
		or participant_stable_key.is_empty()
	):
		return []
	var pool := _normalize_collectible_pool(compatible_collectibles)
	var consumable_pool := _normalize_consumable_pool(config)
	var consumable_prices := generate_consumable_prices(
		config,
		node_content_seed,
		participant_stable_key
	)
	if consumable_prices.size() != consumable_pool.size():
		return []
	var consumable_price_by_path: Dictionary = {}
	for entry in consumable_prices:
		consumable_price_by_path[str(entry["config_path"])] = int(entry["price"])
	var rng := RandomNumberGenerator.new()
	rng.seed = _stable_seed(
		node_content_seed,
		participant_stable_key,
		config.compute_runtime_contract_hash()
	)
	var count_choices := config.collectible_count_choices.duplicate()
	count_choices.sort()
	var count_choice_index := rng.randi_range(
		0,
		count_choices.size() - 1
	)
	var collectible_count := int(count_choices[count_choice_index])
	if pool.size() < collectible_count:
		return []
	var consumable_count := config.offer_count - collectible_count
	if consumable_pool.size() < consumable_count:
		return []
	_shuffle_items(pool, rng)
	_shuffle_listings(consumable_pool, rng)

	var offers: Array[Dictionary] = []
	for pool_index in collectible_count:
		var item := pool[pool_index]
		offers.append({
			"offer_index": -1,
			"config_path": item.resource_path,
			"kind": String(OFFER_KIND_COLLECTIBLE),
			"rarity": int(item.collectible_rarity),
			"price": _roll_collectible_price(config, item, rng),
			"purchased": false,
		})
	for consumable_index in consumable_count:
		var listing := consumable_pool[consumable_index]
		var config_path := listing.get_config_path()
		offers.append({
			"offer_index": -1,
			"config_path": config_path,
			"kind": String(OFFER_KIND_CONSUMABLE),
			"rarity": -1,
			"price": int(consumable_price_by_path.get(config_path, 0)),
			"purchased": false,
		})
	_shuffle_offers(offers, rng)
	for offer_index in offers.size():
		offers[offer_index]["offer_index"] = offer_index
	return offers


static func generate_consumable_prices(
	config: RogueUndergroundShopConfig,
	node_content_seed: int,
	participant_stable_key: String
) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if (
		config == null
		or not config.validate_config().is_empty()
		or participant_stable_key.is_empty()
	):
		return result
	var config_hash := config.compute_runtime_contract_hash()
	for listing in _normalize_consumable_pool(config):
		var config_path := listing.get_config_path()
		var price_tier := int(listing.price_tier)
		var band := config.get_consumable_price_band(price_tier)
		if band.z <= 0 or band.y < band.x:
			return []
		var price_rng := RandomNumberGenerator.new()
		price_rng.seed = _stable_consumable_price_seed(
			node_content_seed,
			participant_stable_key,
			config_hash,
			config_path,
			price_tier
		)
		result.append({
			"config_path": config_path,
			"price_tier": price_tier,
			"price": _roll_price_band(band, price_rng),
		})
	return result


static func get_compatible_collectible_pool(
	character_id: StringName
) -> Array[PickupConfig]:
	var result: Array[PickupConfig] = []
	for item in CollectibleRegistry.get_standard_random_pool():
		if (
			item != null
			and item.can_store_in_inventory
			and _is_collectible_compatible_with_character(item, character_id)
		):
			result.append(item)
	return result


static func _normalize_collectible_pool(
	items: Array[PickupConfig]
) -> Array[PickupConfig]:
	var by_path: Dictionary = {}
	for item in items:
		if (
			item == null
			or item.pickup_type != PickupConfig.PickupType.COLLECTIBLE
			or not item.can_store_in_inventory
			or not CollectibleRegistry.is_standard_random_collectible(item)
			or item.resource_path.is_empty()
		):
			continue
		by_path[item.resource_path] = item
	var paths := PackedStringArray(by_path.keys())
	paths.sort()
	var result: Array[PickupConfig] = []
	for path in paths:
		result.append(by_path[path] as PickupConfig)
	return result


static func _normalize_consumable_pool(
	config: RogueUndergroundShopConfig
) -> Array[RogueUndergroundShopListing]:
	var by_path: Dictionary = {}
	for listing in config.consumable_listings:
		if listing == null or listing.get_config_path().is_empty():
			continue
		by_path[listing.get_config_path()] = listing
	var paths := PackedStringArray(by_path.keys())
	paths.sort()
	var result: Array[RogueUndergroundShopListing] = []
	for path in paths:
		result.append(by_path[path] as RogueUndergroundShopListing)
	return result


static func _roll_collectible_price(
	config: RogueUndergroundShopConfig,
	item: PickupConfig,
	rng: RandomNumberGenerator
) -> int:
	var band := config.get_collectible_price_band(item.collectible_rarity)
	return _roll_price_band(band, rng)


static func _roll_price_band(
	band: Vector3i,
	rng: RandomNumberGenerator
) -> int:
	if band.z <= 0 or band.y < band.x:
		return 0
	var step_count := (band.y - band.x) / band.z
	return band.x + rng.randi_range(0, step_count) * band.z


static func _stable_seed(
	node_content_seed: int,
	participant_stable_key: String,
	config_hash: String
) -> int:
	var digest := (
		"underground-shop|%d|%s|%s"
		% [node_content_seed, participant_stable_key, config_hash]
	).sha256_text()
	# Keep the parsed value within signed 64-bit range on every platform.
	return digest.substr(0, 15).hex_to_int()


static func _stable_consumable_price_seed(
	node_content_seed: int,
	participant_stable_key: String,
	config_hash: String,
	config_path: String,
	price_tier: int
) -> int:
	var digest := (
		"underground-shop-consumable-price|%d|%s|%s|%s|%d"
		% [
			node_content_seed,
			participant_stable_key,
			config_hash,
			config_path,
			price_tier,
		]
	).sha256_text()
	return digest.substr(0, 15).hex_to_int()


static func _shuffle_items(
	items: Array[PickupConfig],
	rng: RandomNumberGenerator
) -> void:
	for index in range(items.size() - 1, 0, -1):
		var swap_index := rng.randi_range(0, index)
		var temporary := items[index]
		items[index] = items[swap_index]
		items[swap_index] = temporary


static func _shuffle_listings(
	listings: Array[RogueUndergroundShopListing],
	rng: RandomNumberGenerator
) -> void:
	for index in range(listings.size() - 1, 0, -1):
		var swap_index := rng.randi_range(0, index)
		var temporary := listings[index]
		listings[index] = listings[swap_index]
		listings[swap_index] = temporary


static func _shuffle_offers(
	offers: Array[Dictionary],
	rng: RandomNumberGenerator
) -> void:
	for index in range(offers.size() - 1, 0, -1):
		var swap_index := rng.randi_range(0, index)
		var temporary := offers[index]
		offers[index] = offers[swap_index]
		offers[swap_index] = temporary


static func _is_collectible_compatible_with_character(
	item: PickupConfig,
	character_id: StringName
) -> bool:
	if item == null:
		return false
	# This mirrors Player.is_collectible_compatible without instantiating a
	# gameplay character in the host's route-only scene.
	var supports_ammunition := (
		PlayerCharacterRegistry.supports_ammunition_reward(character_id)
	)
	var supports_projectile_patterns := supports_ammunition
	if item.requires_projectile_primary_attack and not supports_projectile_patterns:
		return false
	if item.requires_ammunition and not supports_ammunition:
		return false
	return true
