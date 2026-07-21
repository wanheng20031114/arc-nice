extends SceneTree

const LUOXI_SCENE := preload("res://scene/luoxi_merchant.tscn")
const PLAYER_SCENE := preload("res://scene/player/weishidaier/player_weishidaier.tscn")
const HOE_CAT_PLAYER_SCENE := preload("res://scene/player/hoe_cat/player_hoe_cat.tscn")
const TIYI_PLAYER_SCENE := preload("res://scene/player/tiyi/player_tiyi.tscn")

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var run_state := root.get_node("RunState") as RunStateStore
	run_state.begin_new_run()
	run_state.ensure_multiplayer_peer_state(2)
	run_state.ensure_multiplayer_peer_state(3)
	run_state.ensure_multiplayer_peer_state(4)

	var test_root := Node2D.new()
	test_root.name = "LuoxiAuthoritativeOfferSmokeTest"
	root.add_child(test_root)
	var merchant := LUOXI_SCENE.instantiate() as LuoxiMerchant
	var player := PLAYER_SCENE.instantiate() as Player
	var hoe_cat_player := HOE_CAT_PLAYER_SCENE.instantiate() as Player
	var tiyi_player := TIYI_PLAYER_SCENE.instantiate() as Player
	player.peer_id = 2
	hoe_cat_player.peer_id = 3
	tiyi_player.peer_id = 4
	test_root.add_child(merchant)
	test_root.add_child(player)
	test_root.add_child(hoe_cat_player)
	test_root.add_child(tiyi_player)
	merchant.set_active(true)
	await process_frame
	await physics_frame
	merchant.active_player = player
	_test_offer_rarity_roll_contract()
	_test_compatible_pool_rarity_capacity(merchant, player, "维斯戴尔")
	_test_compatible_pool_rarity_capacity(merchant, hoe_cat_player, "锄头猫")
	_test_compatible_pool_rarity_capacity(merchant, tiyi_player, "缇伊")

	var rng := RandomNumberGenerator.new()
	rng.seed = 0x4C554F5849
	var first_paths := merchant.build_authoritative_offer_paths(player, [], rng)
	_expect(first_paths.size() == 3, "Authoritative Luoxi offer must contain exactly three cards.")
	_expect(_has_unique_paths(first_paths), "Authoritative Luoxi offer paths must be unique.")
	for config_path in first_paths:
		var item := LuoxiMerchant.get_collectible_for_path(config_path)
		_expect(item != null, "Every authoritative offer path must resolve to a collectible.")
		_expect(
			item != null and player.is_collectible_compatible(item),
			"Every authoritative offer must be compatible with its target player."
		)
	_expect(
		_is_supported_offer_rarity_pattern(_get_path_rarity_pattern(first_paths)),
		"Every authoritative offer must use one of the six batch rarity patterns."
	)

	var replacement_paths := merchant.build_authoritative_offer_paths(player, first_paths, rng)
	_expect(replacement_paths.size() == 3, "Authoritative refresh must also produce three cards.")
	for config_path in replacement_paths:
		_expect(
			not first_paths.has(config_path),
			"Authoritative refresh should replace all previous cards when the pool is large enough."
		)
	_expect(
		_is_supported_offer_rarity_pattern(_get_path_rarity_pattern(replacement_paths)),
		"Authoritative refresh must preserve the batch rarity contract."
	)

	var sampled_patterns := {}
	for _sample_index in range(600):
		var sampled_paths := merchant.build_authoritative_offer_paths(player, [], rng)
		_expect(sampled_paths.size() == 3, "Every sampled Host offer must contain three cards.")
		_expect(_has_unique_paths(sampled_paths), "Every sampled Host offer must be unique.")
		var sampled_rarities := _get_path_rarity_pattern(sampled_paths)
		_expect(
			_is_supported_offer_rarity_pattern(sampled_rarities),
			"A sampled Host offer used a forbidden mixed-rarity pattern."
		)
		sampled_patterns[_get_rarity_pattern_key(sampled_rarities)] = true
	_expect(
		sampled_patterns.size() == 6,
		"The deterministic Host sample must exercise all six rarity patterns."
	)

	for _local_sample_index in range(24):
		var local_choices := merchant.call("_build_random_collectible_choices") as Array
		_expect(local_choices.size() == 3, "Every local Luoxi offer must contain three cards.")
		_expect(
			_is_supported_offer_rarity_pattern(_get_choice_rarity_pattern(local_choices)),
			"Local Luoxi offers must use the same batch rarity contract as Host offers."
		)

	merchant.begin_authoritative_offer_request()
	_expect(merchant.authoritative_offer_pending, "Opening an authoritative offer must enter a pending state.")
	_expect(
		merchant.apply_authoritative_offer_state(
			7,
			PackedStringArray(first_paths),
			2,
			900
		),
		"A valid Host offer state must be accepted."
	)
	_expect(merchant.get_authoritative_offer_revision() == 7, "Merchant must retain Host offer revision.")
	_expect(not merchant.authoritative_offer_pending, "Host offer state must clear pending state.")
	_expect(merchant.get_player_refresh_count(2) == 2, "Host refresh count must replace local state.")
	_expect(player.current_xirang == 900, "Host xirang must replace local state.")
	for choice_index in range(3):
		var item := merchant.call("_get_current_choice_item", choice_index) as PickupConfig
		_expect(
			item != null and item.resource_path == first_paths[choice_index],
			"Visible card order must exactly match the Host offer."
		)

	_expect(
		not merchant.apply_authoritative_offer_state(
			6,
			PackedStringArray(replacement_paths),
			3,
			800
		),
		"An older offer revision must not replace the current cards."
	)
	_expect(
		not merchant.apply_authoritative_offer_state(
			7,
			PackedStringArray(replacement_paths),
			3,
			800
		),
		"The same revision must not be reused for different card paths."
	)

	merchant.set_active(false)
	test_root.queue_free()
	for _cleanup_frame in range(4):
		await process_frame
		await physics_frame
	call_deferred("_finish")


func _finish() -> void:
	if failures.is_empty():
		print("LUOXI_AUTHORITATIVE_OFFER_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _has_unique_paths(paths: Array[String]) -> bool:
	var seen := {}
	for config_path in paths:
		if seen.has(config_path):
			return false
		seen[config_path] = true
	return true


func _test_offer_rarity_roll_contract() -> void:
	_expect(
		LuoxiMerchant.COLLECTIBLE_OFFER_ROLL_TOTAL == 100,
		"Luoxi batch rarity weights must total exactly 100%."
	)
	var pattern_counts := {}
	for roll in range(LuoxiMerchant.COLLECTIBLE_OFFER_ROLL_TOTAL):
		var pattern := LuoxiMerchant.get_collectible_offer_rarity_pattern_for_roll(
			roll,
			roll % LuoxiMerchant.get_choice_count()
		)
		_expect(pattern.size() == 3, "Every rarity roll must resolve to three card rarities.")
		var key := _get_rarity_pattern_key(pattern)
		pattern_counts[key] = int(pattern_counts.get(key, 0)) + 1

	var expected_counts := {
		"3/0/0/0": 50,
		"0/3/0/0": 30,
		"0/0/3/0": 12,
		"0/0/2/1": 3,
		"0/0/1/2": 3,
		"0/0/0/3": 2,
	}
	_expect(
		pattern_counts == expected_counts,
		"Luoxi batch rarity cases must be 50/30/12/3/3/2 across the 100-point roll."
	)

	var common := PickupConfig.CollectibleRarity.COMMON
	var rare := PickupConfig.CollectibleRarity.RARE
	var epic := PickupConfig.CollectibleRarity.EPIC
	var legendary := PickupConfig.CollectibleRarity.LEGENDARY
	_expect(
		LuoxiMerchant.get_collectible_offer_rarity_pattern_for_roll(0) == [common, common, common]
		and LuoxiMerchant.get_collectible_offer_rarity_pattern_for_roll(49) == [common, common, common],
		"Rolls 0-49 must produce three common cards."
	)
	_expect(
		LuoxiMerchant.get_collectible_offer_rarity_pattern_for_roll(50) == [rare, rare, rare]
		and LuoxiMerchant.get_collectible_offer_rarity_pattern_for_roll(79) == [rare, rare, rare],
		"Rolls 50-79 must produce three rare cards."
	)
	_expect(
		LuoxiMerchant.get_collectible_offer_rarity_pattern_for_roll(80) == [epic, epic, epic]
		and LuoxiMerchant.get_collectible_offer_rarity_pattern_for_roll(91) == [epic, epic, epic],
		"Rolls 80-91 must produce three epic cards."
	)
	_expect(
		LuoxiMerchant.get_collectible_offer_rarity_pattern_for_roll(92, 1) == [epic, legendary, epic]
		and LuoxiMerchant.get_collectible_offer_rarity_pattern_for_roll(94, 1) == [epic, legendary, epic],
		"Rolls 92-94 must produce exactly one legendary among two epic cards."
	)
	_expect(
		LuoxiMerchant.get_collectible_offer_rarity_pattern_for_roll(95, 1) == [legendary, epic, legendary]
		and LuoxiMerchant.get_collectible_offer_rarity_pattern_for_roll(97, 1) == [legendary, epic, legendary],
		"Rolls 95-97 must produce exactly two legendary cards and one epic card."
	)
	_expect(
		LuoxiMerchant.get_collectible_offer_rarity_pattern_for_roll(98) == [legendary, legendary, legendary]
		and LuoxiMerchant.get_collectible_offer_rarity_pattern_for_roll(99) == [legendary, legendary, legendary],
		"Rolls 98-99 must produce three legendary cards."
	)
	for position in range(3):
		_expect(
			LuoxiMerchant.get_collectible_offer_rarity_pattern_for_roll(92, position)[position]
			== legendary,
			"The single legendary card must support every card position."
		)
		_expect(
			LuoxiMerchant.get_collectible_offer_rarity_pattern_for_roll(95, position)[position]
			== epic,
			"The lone epic card in a two-legendary offer must support every card position."
		)

	var position_rng := RandomNumberGenerator.new()
	position_rng.seed = 0x504F534954494F4E
	var sampled_single_legendary_positions := {}
	var sampled_single_epic_positions := {}
	for _sample_index in range(1200):
		var sampled_pattern := LuoxiMerchant.roll_collectible_offer_rarity_pattern(
			position_rng
		)
		var sampled_key := _get_rarity_pattern_key(sampled_pattern)
		if sampled_key == "0/0/2/1":
			sampled_single_legendary_positions[sampled_pattern.find(legendary)] = true
		elif sampled_key == "0/0/1/2":
			sampled_single_epic_positions[sampled_pattern.find(epic)] = true
	_expect(
		sampled_single_legendary_positions.size() == 3,
		"The actual rarity roller must randomize the single legendary across all slots."
	)
	_expect(
		sampled_single_epic_positions.size() == 3,
		"The actual rarity roller must randomize the lone epic across all slots."
	)


func _test_compatible_pool_rarity_capacity(
	merchant: LuoxiMerchant,
	player: Player,
	player_name: String
) -> void:
	var counts := [0, 0, 0, 0]
	var pool := merchant.call("_get_collectible_pool_for_player", player) as Array
	for item_variant in pool:
		var item := item_variant as PickupConfig
		if item != null:
			counts[int(item.collectible_rarity)] += 1
	for rarity in range(counts.size()):
		_expect(
			counts[rarity] >= 6,
			"%s rarity %d pool must survive a three-card refresh exclusion."
			% [player_name, rarity]
		)


func _get_path_rarity_pattern(paths: Array[String]) -> Array[int]:
	var result: Array[int] = []
	for config_path in paths:
		var item := LuoxiMerchant.get_collectible_for_path(config_path)
		if item != null:
			result.append(int(item.collectible_rarity))
	return result


func _get_choice_rarity_pattern(offer_choices: Array) -> Array[int]:
	var result: Array[int] = []
	for item_variant in offer_choices:
		var item := item_variant as PickupConfig
		if item != null:
			result.append(int(item.collectible_rarity))
	return result


func _is_supported_offer_rarity_pattern(pattern: Array[int]) -> bool:
	return _get_rarity_pattern_key(pattern) in [
		"3/0/0/0",
		"0/3/0/0",
		"0/0/3/0",
		"0/0/2/1",
		"0/0/1/2",
		"0/0/0/3",
	]


func _get_rarity_pattern_key(pattern: Array[int]) -> String:
	var counts := [0, 0, 0, 0]
	for rarity in pattern:
		if rarity >= 0 and rarity < counts.size():
			counts[rarity] += 1
	return "%d/%d/%d/%d" % counts


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
