extends SceneTree

const LUOXI_SCENE := preload("res://scene/luoxi_merchant.tscn")
const PLAYER_SCENE := preload("res://scene/player/weishidaier/player_weishidaier.tscn")

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var run_state := root.get_node("RunState") as RunStateStore
	run_state.begin_new_run()
	run_state.ensure_multiplayer_peer_state(2)

	var test_root := Node2D.new()
	test_root.name = "LuoxiAuthoritativeOfferSmokeTest"
	root.add_child(test_root)
	var merchant := LUOXI_SCENE.instantiate() as LuoxiMerchant
	var player := PLAYER_SCENE.instantiate() as Player
	player.peer_id = 2
	test_root.add_child(merchant)
	test_root.add_child(player)
	merchant.set_active(true)
	await process_frame
	await physics_frame
	merchant.active_player = player

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

	var replacement_paths := merchant.build_authoritative_offer_paths(player, first_paths, rng)
	_expect(replacement_paths.size() == 3, "Authoritative refresh must also produce three cards.")
	for config_path in replacement_paths:
		_expect(
			not first_paths.has(config_path),
			"Authoritative refresh should replace all previous cards when the pool is large enough."
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


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
