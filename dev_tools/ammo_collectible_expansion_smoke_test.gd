extends SceneTree

const WEISHIDAIER_SCENE := preload("res://scene/player/weishidaier/player_weishidaier.tscn")
const TIYI_SCENE := preload("res://scene/player/tiyi/player_tiyi.tscn")
const HOE_CAT_SCENE := preload("res://scene/player/hoe_cat/player_hoe_cat.tscn")
const ORANGE := preload("res://resources/config/collectibles/collectible_orange.tres")
const CAPACITY_ITEMS: Array[PickupConfig] = [
	preload("res://resources/config/collectibles/collectible_capacity_spring.tres"),
	preload("res://resources/config/collectibles/collectible_dual_row_feeder.tres"),
	preload("res://resources/config/collectibles/collectible_dual_ammo_chamber.tres"),
	preload("res://resources/config/collectibles/collectible_triple_ammo_chamber.tres"),
]
const RELOAD_ITEMS: Array[PickupConfig] = [
	preload("res://resources/config/collectibles/collectible_gun_oil.tres"),
	preload("res://resources/config/collectibles/collectible_quick_load_belt.tres"),
	preload("res://resources/config/collectibles/collectible_auto_loader.tres"),
	preload("res://resources/config/collectibles/collectible_high_speed_loader.tres"),
]
const ADDITIVE_ITEMS: Array[PickupConfig] = [
	preload("res://resources/config/collectibles/collectible_simple_magazine.tres"),
	preload("res://resources/config/collectibles/collectible_extended_magazine.tres"),
	preload("res://resources/config/collectibles/collectible_drum_magazine.tres"),
]

var failures: Array[String] = []
var test_root: Node2D
var run_state: RunStateStore


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	test_root = Node2D.new()
	test_root.name = "AmmoCollectibleExpansionSmokeTest"
	root.add_child(test_root)
	current_scene = test_root
	run_state = root.get_node("RunState") as RunStateStore

	await _test_capacity_tiers_and_highest_only()
	await _test_additive_before_multiplier_and_effect_caps()
	await _test_reload_tiers_and_highest_only()
	await _test_ammo_state_transitions()
	await _test_character_compatibility_and_orange_marker()
	await _test_multiplayer_capacity_does_not_replace_base()

	test_root.queue_free()
	for _cleanup_frame in range(6):
		await process_frame
		await physics_frame

	if failures.is_empty():
		print("AMMO_COLLECTIBLE_EXPANSION_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_capacity_tiers_and_highest_only() -> void:
	var weish := await _spawn_ammo_player(WEISHIDAIER_SCENE)
	var tiyi := await _spawn_ammo_player(TIYI_SCENE)
	var weish_expected := [36, 45, 60, 90]
	var tiyi_expected := [6, 7, 10, 15]
	for index in CAPACITY_ITEMS.size():
		_set_inventory([CAPACITY_ITEMS[index]], weish)
		_expect(weish.get_ammo_capacity() == weish_expected[index], "Weishidaier capacity tier %d must equal %d." % [index, weish_expected[index]])
		_set_inventory([CAPACITY_ITEMS[index]], tiyi)
		_expect(tiyi.get_ammo_capacity() == tiyi_expected[index], "Tiyi capacity tier %d must floor to %d." % [index, tiyi_expected[index]])
	_set_inventory(CAPACITY_ITEMS, weish)
	_expect(weish.get_ammo_capacity() == 90, "Capacity ratios must use only the highest held tier for Weishidaier.")
	_set_inventory(CAPACITY_ITEMS, tiyi)
	_expect(tiyi.get_ammo_capacity() == 15, "Capacity ratios must use only the highest held tier for Tiyi.")
	await _free_player(weish)
	await _free_player(tiyi)


func _test_additive_before_multiplier_and_effect_caps() -> void:
	var tiyi := await _spawn_ammo_player(TIYI_SCENE)
	_set_inventory([ADDITIVE_ITEMS[0], ADDITIVE_ITEMS[1], ADDITIVE_ITEMS[2], CAPACITY_ITEMS[1]], tiyi)
	_expect(tiyi.get_ammo_capacity() == 21, "Tiyi must calculate floor((5 + 1 + 3 + 5) * 1.5) = 21.")

	for additive_item in ADDITIVE_ITEMS:
		run_state.begin_new_run(&"tiyi", false)
		for _copy_index in range(5):
			_expect(run_state.try_add_item(additive_item), "%s copy setup must fit." % additive_item.display_name)
		tiyi.call("_refresh_collectible_stats", false)
		var capped_capacity := tiyi.get_ammo_capacity()
		_expect(
			capped_capacity == (
				tiyi.ammo_capacity
				+ additive_item.collectible_ammo_capacity_additive_bonus
				* additive_item.collectible_max_copies
			),
			"%s must apply exactly its first five carried copies to magazine capacity."
			% additive_item.display_name
		)
		_expect(
			LuoxiMerchant.is_collectible_available_for_inventory(additive_item, run_state),
			"%s must remain obtainable after five copies cap its active effect."
			% additive_item.display_name
		)
		_expect(
			run_state.try_add_item(additive_item),
			"A sixth %s must remain carryable." % additive_item.display_name
		)
		_expect(
			run_state.get_item(5) == additive_item,
			"A sixth %s must be stored in a real inventory slot." % additive_item.display_name
		)
		tiyi.call("_refresh_collectible_stats", false)
		_expect(
			tiyi.get_ammo_capacity() == capped_capacity,
			"A sixth carried %s must not increase magazine capacity beyond its five-copy effect cap."
			% additive_item.display_name
		)
	await _free_player(tiyi)


func _test_reload_tiers_and_highest_only() -> void:
	var player := await _spawn_ammo_player(WEISHIDAIER_SCENE)
	var expected_durations := [1.35, 1.2, 1.05, 0.75]
	for index in RELOAD_ITEMS.size():
		_set_inventory([RELOAD_ITEMS[index]], player)
		_expect(
			is_equal_approx(player.get_effective_reload_duration(), expected_durations[index]),
			"Reload tier %d must equal %.2f seconds." % [index, expected_durations[index]]
		)
	_set_inventory(RELOAD_ITEMS, player)
	_expect(is_equal_approx(player.get_effective_reload_duration(), 0.75), "Reload reductions must use only the highest held tier.")
	await _free_player(player)


func _test_ammo_state_transitions() -> void:
	var player := await _spawn_ammo_player(WEISHIDAIER_SCENE)
	player.current_ammo = player.get_ammo_capacity()
	_set_inventory([CAPACITY_ITEMS[0]], player)
	_expect(player.current_ammo == 36, "A full magazine must refill to the expanded capacity.")

	_set_inventory([], player)
	player.current_ammo = 12
	_set_inventory([CAPACITY_ITEMS[1]], player)
	_expect(player.current_ammo == 12, "A partially filled magazine must not gain free ammo when capacity increases.")
	player.current_ammo = 40
	_set_inventory([], player)
	_expect(player.current_ammo == 30, "Removing capacity must clamp current ammo to the new limit.")

	player.current_ammo = 10
	_expect(player.call("_try_start_reload"), "Reload transition setup must start reloading.")
	player.call("_update_reload", 0.75)
	_expect(is_equal_approx(player.reload_progress, 0.5), "Reload setup must reach half progress.")
	_set_inventory([RELOAD_ITEMS[3]], player)
	_expect(is_equal_approx(player.reload_progress, 0.5), "Obtaining a reload collectible mid-reload must preserve progress.")
	player.call("_update_reload", 0.375)
	_expect(not player.is_reloading and player.current_ammo == player.get_ammo_capacity(), "The shortened remaining reload must complete at the new effective duration.")

	_set_inventory([CAPACITY_ITEMS[3]], player)
	player.current_ammo = 4
	player.current_health = player.max_health
	player.invincibility_time_left = 0.0
	player.call("_set_hurt_blink_enabled", false)
	player.apply_damage(player.max_health)
	_expect(player.is_dead, "Revive setup must kill the ammo player.")
	player.revive_multiplayer(Vector2.ZERO, player.max_health, 0.0)
	_expect(player.current_ammo == 90, "Reviving must restore the effective expanded magazine to full.")
	await _free_player(player)


func _test_character_compatibility_and_orange_marker() -> void:
	var weish := await _spawn_player(WEISHIDAIER_SCENE)
	var tiyi := await _spawn_player(TIYI_SCENE)
	var hoe_cat := await _spawn_player(HOE_CAT_SCENE)
	var ammo_items: Array[PickupConfig] = []
	ammo_items.append_array(CAPACITY_ITEMS)
	ammo_items.append_array(RELOAD_ITEMS)
	ammo_items.append_array(ADDITIVE_ITEMS)
	for item in ammo_items:
		_expect(item.requires_ammunition, "%s must declare ammunition compatibility." % item.display_name)
		_expect(weish.is_collectible_compatible(item), "Weishidaier must accept %s." % item.display_name)
		_expect(tiyi.is_collectible_compatible(item), "Tiyi must accept %s." % item.display_name)
		_expect(not hoe_cat.is_collectible_compatible(item), "Hoe Cat must reject %s." % item.display_name)
	_expect(ORANGE.requires_ammunition, "Orange must declare ammunition compatibility.")
	_expect(not hoe_cat.is_collectible_compatible(ORANGE), "Hoe Cat must reject Orange after its ammunition marker is added.")
	await _free_player(weish)
	await _free_player(tiyi)
	await _free_player(hoe_cat)


func _test_multiplayer_capacity_does_not_replace_base() -> void:
	var player := await _spawn_ammo_player(WEISHIDAIER_SCENE)
	_set_inventory([CAPACITY_ITEMS[3]], player)
	_expect(player.get_multiplayer_ammo_capacity() == 90, "The authoritative state must expose effective capacity.")
	var base_capacity := player.ammo_capacity
	player.uses_local_input = false
	player.apply_multiplayer_ammo_state(90, 44, true, 0.4)
	_expect(player.ammo_capacity == base_capacity, "Applying multiplayer ammo state must not overwrite the base ammo_capacity.")
	_expect(player.get_ammo_capacity() == 90, "Remote effective capacity must not be multiplied a second time.")
	_expect(player.current_ammo == 44 and is_equal_approx(player.reload_progress, 0.4), "Remote ammo count and reload progress must stay synchronized.")
	await _free_player(player)


func _set_inventory(items: Array, player: Player) -> void:
	run_state.begin_new_run(&"weishidaier", false)
	for item_variant in items:
		var item := item_variant as PickupConfig
		_expect(run_state.try_add_item(item), "%s must fit in the test inventory." % item.display_name)
	player.call("_refresh_collectible_stats", false)


func _spawn_ammo_player(scene: PackedScene) -> AmmoRangedPlayer:
	return await _spawn_player(scene) as AmmoRangedPlayer


func _spawn_player(scene: PackedScene) -> Player:
	var player := scene.instantiate() as Player
	test_root.add_child(player)
	await process_frame
	await physics_frame
	return player


func _free_player(player: Player) -> void:
	player.queue_free()
	await process_frame
	await physics_frame


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
