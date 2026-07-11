extends SceneTree

const PLAYER_SCENE := preload("res://scene/player/weishidaier/player_weishidaier.tscn")
const HOE_CAT_SCENE := preload("res://scene/player/hoe_cat/player_hoe_cat.tscn")
const GAME_SCENE := preload("res://scene/game.tscn")
const LUOXI_SCENE := preload("res://scene/luoxi_merchant.tscn")
const BULLET_SCENE := preload("res://scene/bullet.tscn")
const INVENTORY_SLOT_SCENE := preload("res://scene/inventory_slot.tscn")
const BASIC_CONFIG := preload("res://resources/config/enemies/yuanshi_insect_basic.tres")
const APPLE_COLLECTIBLE := preload("res://resources/config/collectibles/collectible_apple.tres")
const RUBY_COLLECTIBLE := preload("res://resources/config/collectibles/collectible_ruby.tres")
const ARCHER_COLLECTIBLE := preload("res://resources/config/collectibles/collectible_archer.tres")
const ROLLER_SKATES_COLLECTIBLE := preload("res://resources/config/collectibles/collectible_roller_skates.tres")
const POWER_WHEEL_COLLECTIBLE := preload("res://resources/config/collectibles/collectible_power_wheel.tres")
const HEALTH_PICKUP := preload("res://resources/config/pickups/pickup_health.tres")

var failures: Array[String] = []
var test_root: Node2D


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	test_root = Node2D.new()
	test_root.name = "LuoxiCollectibleSmokeTest"
	root.add_child(test_root)
	current_scene = test_root

	await _test_luoxi_game_scene_placement()
	await _test_luoxi_dialogue_choice_and_inventory()
	await _test_luoxi_filters_owned_non_repeating_collectibles()
	await _test_hoe_cat_collectible_compatibility_filter()
	await _test_full_inventory_keeps_luoxi_choice_available()
	await _test_apple_piercing_bullet_effect()

	test_root.queue_free()
	for _cleanup_frame in range(8):
		await process_frame
		await physics_frame

	if failures.is_empty():
		print("LUOXI_COLLECTIBLE_SMOKE_TEST_OK")
		quit()
		return

	for failure in failures:
		push_error(failure)
	quit(1)


func _test_hoe_cat_collectible_compatibility_filter() -> void:
	var run_state := root.get_node("RunState") as RunStateStore
	run_state.begin_new_run(&"hoe_cat")
	var luoxi := LUOXI_SCENE.instantiate() as LuoxiMerchant
	var hoe_cat := HOE_CAT_SCENE.instantiate() as PlayerHoeCat
	test_root.add_child(luoxi)
	test_root.add_child(hoe_cat)
	await process_frame

	var filtered_pool := luoxi.call("_get_collectible_pool_for_player", hoe_cat) as Array
	_expect(filtered_pool.size() == 104, "Hoe Cat pool must exclude all eight ammo-character-only collectibles.")
	for item_variant in filtered_pool:
		var item := item_variant as PickupConfig
		_expect(
			item != null and not item.requires_projectile_primary_attack,
			"Hoe Cat pool must not contain projectile-only collectibles."
		)
	_expect(not hoe_cat.is_collectible_compatible(APPLE_COLLECTIBLE), "Apple must be incompatible with Hoe Cat.")
	_expect(
		int(luoxi.call("_claim_local_collectible", hoe_cat, APPLE_COLLECTIBLE.resource_path))
		== LuoxiMerchant.COLLECTIBLE_RESULT_INVALID_PLAYER,
		"Hoe Cat must not be able to claim a projectile-only collectible by path."
	)
	_expect(run_state.get_item(0) == null, "Rejected projectile-only collectible must not enter Hoe Cat inventory.")

	_stop_audio_players(hoe_cat)
	luoxi.queue_free()
	hoe_cat.queue_free()
	await process_frame


func _test_luoxi_game_scene_placement() -> void:
	var game := GAME_SCENE.instantiate() as Game
	_expect(game != null, "Game scene must instantiate for Luoxi placement.")
	if game == null:
		return
	game.set("auto_start_waves", false)
	root.add_child(game)
	await process_frame
	await physics_frame

	var zhuangfangyi := game.get_node_or_null("ZhuangfangyiMerchant") as ZhuangfangyiMerchant
	var luoxi := game.get_node_or_null("LuoxiMerchant") as LuoxiMerchant
	_expect(zhuangfangyi != null, "Game must keep Zhuangfangyi merchant.")
	_expect(luoxi != null, "Game must instantiate Luoxi merchant.")
	if zhuangfangyi != null and luoxi != null:
		_expect(luoxi.position.x > zhuangfangyi.position.x, "Luoxi must be placed to the right of Zhuangfangyi.")
		var zhuang_shape := zhuangfangyi.get_node("InteractionArea/CollisionShape2D") as CollisionShape2D
		var luoxi_shape := luoxi.get_node("InteractionArea/CollisionShape2D") as CollisionShape2D
		var zhuang_circle := zhuang_shape.shape as CircleShape2D
		var luoxi_circle := luoxi_shape.shape as CircleShape2D
		_expect(
			zhuangfangyi.position.distance_to(luoxi.position) > zhuang_circle.radius + luoxi_circle.radius,
			"Luoxi and Zhuangfangyi interaction circles must not overlap."
		)

	_stop_audio_players(game)
	game.queue_free()
	await process_frame
	await physics_frame


func _test_luoxi_dialogue_choice_and_inventory() -> void:
	var run_state := root.get_node("RunState") as RunStateStore
	run_state.begin_new_run()

	var luoxi := LUOXI_SCENE.instantiate() as LuoxiMerchant
	var player := PLAYER_SCENE.instantiate() as Player
	test_root.add_child(luoxi)
	test_root.add_child(player)
	player.grant_cheat_xirang(1800)
	luoxi.set_active(true)
	await process_frame
	await physics_frame

	luoxi.call("_on_interaction_area_body_entered", player)
	var bubble := luoxi.get_node("MerchantDialogueBubble") as MerchantDialogueBubble
	_expect(bubble.visible, "Luoxi dialogue bubble must appear when the player enters range.")
	_expect(_dialogue_text(bubble) == "我是终末地的爪牙！", "Luoxi dialogue must start at the requested first line.")

	var bubble_panel := bubble.get_node("BubblePanel") as PanelContainer
	var bubble_style := bubble_panel.get_theme_stylebox("panel") as StyleBoxFlat
	_expect(bubble.text_label.custom_minimum_size.y >= 58.0, "Luoxi dialogue text area must leave vertical room for wrapped text.")
	_expect(
		bubble_style != null and is_equal_approx(bubble_style.bg_color.r, 0.98),
		"Luoxi dialogue bubble must keep the same warm background as Zhuangfangyi."
	)
	var name_plate := bubble.get_node("NamePlate") as PanelContainer
	var name_style := name_plate.get_theme_stylebox("panel") as StyleBoxFlat
	_expect(
		name_style != null and name_style.bg_color.r > 0.9 and name_style.bg_color.g < 0.25,
		"Luoxi dialogue name plate must keep the vivid red accent."
	)

	var interact := _make_action("interact")
	bubble.finish_line()
	luoxi._unhandled_input(interact)
	_expect(
		_dialogue_text(bubble) == "我能为你提供收藏品来强化自己。",
		"Luoxi dialogue must include the requested collectible intro line."
	)

	bubble.finish_line()
	luoxi._unhandled_input(interact)
	var choice_overlay := luoxi.get_node("LuoxiCollectibleChoiceOverlay") as LuoxiCollectibleChoiceOverlay
	_expect(choice_overlay != null and choice_overlay.is_open(), "Luoxi must open the collectible card chooser.")
	_expect(not bubble.visible, "Luoxi card chooser must not be embedded inside the dialogue bubble.")
	var first_title := choice_overlay.get_node("Root/Center/Content/CardRow/Card0/Margin/Content/Title") as Label
	var first_description := choice_overlay.get_node("Root/Center/Content/CardRow/Card0/Margin/Content/Description") as RichTextLabel
	var first_button := choice_overlay.get_node("Root/Center/Content/CardRow/Card0/Margin/Content/SelectButton") as Button
	var first_card := choice_overlay.get_node("Root/Center/Content/CardRow/Card0") as PanelContainer
	var first_front := choice_overlay.get_node("Root/Center/Content/CardRow/Card0/Margin") as Control
	var hint := choice_overlay.get_node("Root/Center/Content/Hint") as Label
	var card_row := choice_overlay.get_node("Root/Center/Content/CardRow") as HBoxContainer
	var refresh_button := choice_overlay.get_node("Root/Center/Content/RefreshPanel/Margin/Layout/RefreshButton") as Button
	var refresh_status := choice_overlay.get_node("Root/Center/Content/RefreshPanel/Margin/Layout/Info/RefreshStatus") as Label
	var refresh_progress := choice_overlay.get_node("Root/Center/Content/RefreshPanel/Margin/Layout/Info/RefreshProgress") as Label
	var first_choice := luoxi.call("_get_current_choice_item", 0) as PickupConfig
	var second_choice := luoxi.call("_get_current_choice_item", 1) as PickupConfig
	_expect(first_choice != null, "Luoxi must build a first collectible choice.")
	_expect(second_choice != null, "Luoxi must build a second collectible choice.")
	_expect(
		first_choice != null and LuoxiMerchant.is_collectible_pool_path(first_choice.resource_path),
		"Luoxi first choice must come from the collectible pool."
	)
	_expect(first_title.text == first_choice.display_name, "Luoxi card chooser must show the collectible name.")
	_expect(
		first_choice != null and first_description.text.contains(first_choice.description),
		"Luoxi card chooser must show the collectible description."
	)
	_expect(first_button.text == "选择", "Luoxi card chooser select button must not expose a visible waiting state.")
	_expect(refresh_button.text.contains("100") and refresh_button.text.contains("R") and refresh_button.text.contains("RB"), "Luoxi refresh button must show its first cost and keyboard/gamepad shortcuts.")
	_expect(not refresh_button.disabled, "Luoxi refresh button must start enabled.")
	_expect(refresh_progress.text.contains("0/4"), "Luoxi refresh progress must start at zero of four.")
	_expect(hint.label_settings.font_size >= 22, "Luoxi card chooser heading must be easier to read.")
	_expect(first_card.custom_minimum_size == Vector2(216, 310), "Luoxi card chooser cards must leave room for longer collectible text.")
	_expect(first_description.scroll_active, "Luoxi card chooser descriptions must scroll when text is too long.")
	_expect(first_description.custom_minimum_size.y >= 108.0, "Luoxi card chooser descriptions must have enough visible text area.")
	_expect(choice_overlay.is_confirmation_locked(), "Luoxi card chooser must lock confirmation immediately after opening.")
	_expect(not choice_overlay.has_node("Root/Center/Content/ConfirmationLockLabel"), "Luoxi card chooser must not show a visible accidental input protection countdown.")
	_expect(not first_button.disabled, "Luoxi card chooser select buttons must stay visually available during hidden accidental input protection.")
	luoxi._unhandled_input(interact)
	_expect(choice_overlay.is_open(), "Luoxi card chooser must ignore immediate interact confirmation after opening.")
	_expect(run_state.get_item(0) == null, "Luoxi card chooser must not add an item during accidental input protection.")
	luoxi._unhandled_input(_make_key(KEY_2))
	_expect(choice_overlay.is_open(), "Luoxi card chooser must ignore immediate number-key confirmation after opening.")
	_expect(run_state.get_item(0) == null, "Luoxi number-key shortcut must not add an item during accidental input protection.")
	var description_style := first_description.get_theme_stylebox("normal") as StyleBoxFlat
	_expect(
		description_style != null
		and description_style.get_content_margin(SIDE_LEFT) >= 5.0
		and description_style.get_content_margin(SIDE_RIGHT) >= 7.0,
		"Luoxi card chooser descriptions must leave horizontal glyph padding."
	)
	_expect(card_row.get_theme_constant("separation") == 24, "Luoxi card chooser spacing must scale with the larger cards.")
	for button_index in range(3):
		var button := choice_overlay.get_node("Root/Center/Content/CardRow/Card%d/Margin/Content/SelectButton" % button_index) as Button
		_expect(button.get_theme_stylebox("focus") is StyleBoxEmpty, "Luoxi card chooser select button %d must not show the default focus outline." % button_index)
	_expect(not first_front.visible, "Luoxi card chooser must start with the card front hidden for the flip animation.")
	await create_timer(0.18).timeout
	_expect(first_front.visible, "Luoxi card chooser must reveal the card front during the flip animation.")
	_expect(first_card.scale.x < 1.0, "Luoxi card chooser must still be visibly flipping after the front is revealed.")
	await create_timer(0.5).timeout
	for card_index in range(3):
		var card := choice_overlay.get_node("Root/Center/Content/CardRow/Card%d" % card_index) as PanelContainer
		var card_front := choice_overlay.get_node("Root/Center/Content/CardRow/Card%d/Margin" % card_index) as Control
		_expect(card_front.visible, "Luoxi card chooser card %d front must be visible after opening." % card_index)
		_expect(is_equal_approx(card.scale.x, 1.0), "Luoxi card chooser card %d must finish at full width." % card_index)
		_expect(_is_color_equal(card.modulate, Color.WHITE), "Luoxi card chooser card %d must not be dimmed after opening." % card_index)
		_expect(_is_color_equal(card.self_modulate, Color.WHITE), "Luoxi card chooser card %d face must be fully bright after opening." % card_index)

	var second_card := choice_overlay.get_node("Root/Center/Content/CardRow/Card1") as PanelContainer
	var second_base_style := second_card.get_theme_stylebox("panel") as StyleBoxFlat
	var second_base_position := second_card.position
	choice_overlay._on_card_mouse_entered(1)
	await create_timer(0.18).timeout
	var second_hover_style := second_card.get_theme_stylebox("panel") as StyleBoxFlat
	_expect(is_equal_approx(second_card.scale.x, 1.0) and is_equal_approx(second_card.scale.y, 1.0), "Luoxi card chooser hover must not scale card text.")
	_expect(second_card.position.y < second_base_position.y, "Luoxi card chooser hover must gently lift the hovered card.")
	_expect(second_hover_style.shadow_size > second_base_style.shadow_size, "Luoxi card chooser hover must add a visible glow.")
	_expect(second_hover_style.border_color.g > second_base_style.border_color.g, "Luoxi card chooser hover must brighten the red border.")
	choice_overlay._on_card_mouse_exited(1)
	await create_timer(0.18).timeout
	_expect(is_equal_approx(second_card.position.y, second_base_position.y), "Luoxi card chooser hover must restore the card position.")
	await create_timer(0.7).timeout
	_expect(not choice_overlay.is_confirmation_locked(), "Luoxi card chooser confirmation lock must expire after 1 second.")
	_expect(not first_button.disabled, "Luoxi card chooser select buttons must remain enabled after accidental input protection expires.")
	_expect(first_button.text == "选择", "Luoxi card chooser must expose a select button after accidental input protection expires.")

	var refresh_costs := [100, 200, 500, 1000]
	for refresh_index in range(refresh_costs.size()):
		var previous_paths: Array[String] = []
		for choice_variant in choice_overlay.choices:
			var previous_choice := choice_variant as PickupConfig
			previous_paths.append(previous_choice.resource_path)
		var xirang_before := player.current_xirang
		luoxi._unhandled_input(_make_action("luoxi_refresh"))
		_expect(player.current_xirang == xirang_before - refresh_costs[refresh_index], "Luoxi refresh %d must spend the configured cost." % refresh_index)
		_expect(luoxi.get_player_refresh_count(0) == refresh_index + 1, "Luoxi refresh count must advance after a successful refresh.")
		for choice_variant in choice_overlay.choices:
			var refreshed_choice := choice_variant as PickupConfig
			_expect(not previous_paths.has(refreshed_choice.resource_path), "A refresh must replace all three visible cards when the pool is large enough.")
		await create_timer(0.55).timeout
	_expect(refresh_button.disabled, "Luoxi refresh button must disable after four refreshes.")
	_expect(refresh_button.text.contains("无法刷新"), "Exhausted Luoxi refresh button must explain that refreshing is unavailable.")
	_expect(refresh_progress.text.contains("4/4"), "Luoxi refresh progress must show four of four after exhaustion.")
	_expect(refresh_status.text.contains("下次休整期重置"), "Luoxi exhausted state must explain when refreshes reset.")
	var xirang_after_four_refreshes := player.current_xirang
	luoxi._unhandled_input(_make_action("luoxi_refresh"))
	_expect(player.current_xirang == xirang_after_four_refreshes, "A fifth Luoxi refresh attempt must not spend xirang.")
	await create_timer(1.1).timeout
	second_choice = luoxi.call("_get_current_choice_item", 1) as PickupConfig

	var move_right := _make_action("move_right")
	bubble.finish_line()
	luoxi._unhandled_input(move_right)
	_expect(int(luoxi.get("selected_choice_index")) == 1, "Luoxi choice selection must move right.")
	for card_index in range(3):
		var card := choice_overlay.get_node("Root/Center/Content/CardRow/Card%d" % card_index) as PanelContainer
		_expect(_is_color_equal(card.modulate, Color.WHITE), "Luoxi choice selection must not dim card %d." % card_index)

	luoxi._unhandled_input(interact)
	_expect(not choice_overlay.is_open(), "Luoxi card chooser must close after a selection.")
	var item := run_state.get_item(0)
	_expect(item == second_choice, "Luoxi must add the selected collectible to the first inventory slot.")

	_expect(not run_state.try_use_item(0, player), "Apple collectible must not be consumable from inventory.")
	_expect(run_state.get_item(0) == second_choice, "Collectibles must remain in inventory after use attempt.")
	var slot := INVENTORY_SLOT_SCENE.instantiate() as InventorySlot
	test_root.add_child(slot)
	slot.set_item(second_choice)
	_expect(
		second_choice != null and slot.tooltip_text.contains(second_choice.description),
		"Collectible inventory tooltip must show its description."
	)
	slot.queue_free()

	bubble.finish_line()
	luoxi._unhandled_input(interact)
	luoxi._unhandled_input(interact)
	_expect(
		_dialogue_text(bubble) == "这段场间时间已经选择过一件收藏品。",
		"Luoxi must not offer another collectible after one choice in the same intermission."
	)
	_expect(
		bubble.text_label.text.contains(MerchantDialogueBubble.NO_BREAK_MARK + "。"),
		"Luoxi dialogue punctuation must stay attached to the preceding text when wrapped."
	)
	_expect(run_state.get_item(1) == null, "Luoxi must not add a second collectible in the same intermission.")

	luoxi.reset_intermission_state()
	bubble.finish_line()
	luoxi._unhandled_input(interact)
	_expect(choice_overlay.is_open(), "Luoxi must allow a new collectible choice after round reset.")
	_expect(luoxi.get_player_refresh_count(0) == 0, "Luoxi intermission reset must restore all four refreshes.")
	_expect(refresh_button.text.contains("100") and not refresh_button.disabled, "Luoxi reset must restore the first refresh cost and enabled state.")
	choice_overlay.hide_choices()

	luoxi.queue_free()
	player.queue_free()
	await process_frame
	await physics_frame


func _test_luoxi_filters_owned_non_repeating_collectibles() -> void:
	var run_state := root.get_node("RunState") as RunStateStore
	run_state.begin_new_run()
	_expect(run_state.try_add_item(APPLE_COLLECTIBLE), "Owned apple setup must fit in inventory.")
	_expect(run_state.try_add_item(RUBY_COLLECTIBLE), "Owned ruby setup must fit in inventory.")
	_expect(run_state.try_add_item(ARCHER_COLLECTIBLE), "Owned archer setup must fit in inventory.")
	_expect(run_state.try_add_item(ROLLER_SKATES_COLLECTIBLE), "Owned roller skates setup must fit in inventory.")
	_expect(run_state.try_add_item(POWER_WHEEL_COLLECTIBLE), "Owned power wheel setup must fit in inventory.")

	var luoxi := LUOXI_SCENE.instantiate() as LuoxiMerchant
	var player := PLAYER_SCENE.instantiate() as Player
	test_root.add_child(luoxi)
	test_root.add_child(player)
	luoxi.set_active(true)
	await process_frame
	await physics_frame

	var filtered_pool := luoxi.call("_get_collectible_pool_for_player", player) as Array
	_expect(
		_pool_contains_collectible(filtered_pool, APPLE_COLLECTIBLE),
		"Luoxi must continue offering apple until its five-copy cap is reached."
	)
	_expect(
		_pool_contains_collectible(filtered_pool, RUBY_COLLECTIBLE),
		"Luoxi must still offer an already-owned collectible whose copies stack."
	)
	_expect(
		not _pool_contains_collectible(filtered_pool, ARCHER_COLLECTIBLE),
		"Luoxi must not offer an already-owned non-repeating collectible."
	)
	_expect(
		not _pool_contains_collectible(filtered_pool, ROLLER_SKATES_COLLECTIBLE)
		and not _pool_contains_collectible(filtered_pool, POWER_WHEEL_COLLECTIBLE),
		"Luoxi must not offer either already-owned unique boot collectible."
	)
	for _copy_index in range(4):
		_expect(run_state.try_add_item(APPLE_COLLECTIBLE), "Apple copy-cap setup must fit in inventory.")
	filtered_pool = luoxi.call("_get_collectible_pool_for_player", player) as Array
	_expect(
		not _pool_contains_collectible(filtered_pool, APPLE_COLLECTIBLE),
		"Luoxi must stop offering apple after five copies reach 100% piercing."
	)

	luoxi.queue_free()
	player.queue_free()
	await process_frame
	await physics_frame


func _test_full_inventory_keeps_luoxi_choice_available() -> void:
	var run_state := root.get_node("RunState") as RunStateStore
	run_state.begin_new_run()
	for _slot_index in range(RunStateStore.INVENTORY_CAPACITY):
		_expect(run_state.try_add_item(HEALTH_PICKUP), "Inventory setup must fill every slot before testing Luoxi's full bag result.")

	var luoxi := LUOXI_SCENE.instantiate() as LuoxiMerchant
	var player := PLAYER_SCENE.instantiate() as Player
	test_root.add_child(luoxi)
	test_root.add_child(player)
	luoxi.set_active(true)
	await process_frame
	await physics_frame

	luoxi.call("_on_interaction_area_body_entered", player)
	var bubble := luoxi.get_node("MerchantDialogueBubble") as MerchantDialogueBubble
	var choice_overlay := luoxi.get_node("LuoxiCollectibleChoiceOverlay") as LuoxiCollectibleChoiceOverlay
	var interact := _make_action("interact")
	_open_luoxi_choice(luoxi, bubble, interact)
	_expect(choice_overlay.is_open(), "Luoxi must still offer a collectible choice before the full inventory result.")
	var first_choice := luoxi.call("_get_current_choice_item", 0) as PickupConfig

	luoxi._unhandled_input(interact)
	_expect(choice_overlay.is_open(), "Luoxi full-inventory choice must also ignore immediate interact confirmation after opening.")
	await create_timer(1.1).timeout
	luoxi._unhandled_input(interact)
	_expect(
		_dialogue_text(bubble) == "背包已经满了，无法再继续获得收藏品。",
		"Luoxi must clearly explain that a full inventory blocks collectible pickup."
	)
	_expect(not bool(luoxi.call("_is_player_claimed", player)), "A full inventory must not spend Luoxi's collectible choices.")
	_expect(run_state.get_item(0) == HEALTH_PICKUP, "A failed Luoxi claim must not replace existing inventory items.")

	_expect(run_state.discard_item(0), "Discarding one item must free a slot for the original Luoxi choice.")
	bubble.finish_line()
	luoxi._unhandled_input(interact)
	_open_luoxi_choice(luoxi, bubble, interact)
	await create_timer(1.1).timeout
	luoxi._unhandled_input(interact)
	_expect(_dialogue_text(bubble) == "拿好收藏品，可别小看它。", "Luoxi must allow the original choice after the player frees a slot.")
	_expect(bool(luoxi.call("_is_player_claimed", player)), "The first successful retry must spend the only Luoxi choice.")
	_expect(run_state.get_item(0) == first_choice, "The retried Luoxi choice must fill the freed inventory slot.")

	luoxi.queue_free()
	player.queue_free()
	await process_frame
	await physics_frame


func _test_apple_piercing_bullet_effect() -> void:
	var player := PLAYER_SCENE.instantiate() as Player
	var enemy_a := BASIC_CONFIG.enemy_scene.instantiate() as Enemy
	var enemy_b := BASIC_CONFIG.enemy_scene.instantiate() as Enemy
	var bullet := BULLET_SCENE.instantiate() as Bullet
	test_root.add_child(player)
	test_root.add_child(enemy_a)
	test_root.add_child(enemy_b)
	enemy_a.setup(BASIC_CONFIG, player, null)
	enemy_b.setup(BASIC_CONFIG, player, null)
	await process_frame
	await physics_frame

	enemy_a.current_health = 10
	enemy_b.current_health = 10
	bullet.setup(Vector2.RIGHT, 3, true)
	test_root.add_child(bullet)
	bullet.global_position = Vector2(-1000.0, -1000.0)

	_expect(bullet.try_hit_enemy(enemy_a), "Piercing bullet must hit the first enemy.")
	_expect(enemy_a.current_health == 7, "Piercing bullet must damage the first enemy.")
	_expect(not bullet.is_queued_for_deletion(), "Piercing bullet must not be removed after the first enemy.")
	_expect(not bullet.try_hit_enemy(enemy_a), "Piercing bullet must not damage the same enemy twice.")
	_expect(enemy_a.current_health == 7, "Repeated piercing hit on the same enemy must not deal damage.")
	_expect(bullet.try_hit_enemy(enemy_b), "Piercing bullet must hit a second enemy.")
	_expect(enemy_b.current_health == 7, "Piercing bullet must damage the second enemy.")

	bullet.queue_free()
	enemy_a.queue_free()
	enemy_b.queue_free()
	player.queue_free()
	await process_frame
	await physics_frame


func _make_action(action_name: StringName) -> InputEventAction:
	var event := InputEventAction.new()
	event.action = action_name
	event.pressed = true
	return event


func _make_key(physical_keycode: Key) -> InputEventKey:
	var event := InputEventKey.new()
	event.physical_keycode = physical_keycode
	event.pressed = true
	return event


func _open_luoxi_choice(luoxi: LuoxiMerchant, bubble: MerchantDialogueBubble, interact: InputEventAction) -> void:
	if not bubble.visible:
		luoxi._unhandled_input(interact)
	for _line_index in range(2):
		bubble.finish_line()
		luoxi._unhandled_input(interact)


func _stop_audio_players(node: Node) -> void:
	if node is AudioStreamPlayer:
		(node as AudioStreamPlayer).stop()
	elif node is AudioStreamPlayer2D:
		(node as AudioStreamPlayer2D).stop()
	for child in node.get_children():
		_stop_audio_players(child)


func _is_color_equal(color_a: Color, color_b: Color) -> bool:
	return (
		is_equal_approx(color_a.r, color_b.r)
		and is_equal_approx(color_a.g, color_b.g)
		and is_equal_approx(color_a.b, color_b.b)
		and is_equal_approx(color_a.a, color_b.a)
	)


func _dialogue_text(bubble: MerchantDialogueBubble) -> String:
	return bubble.text_label.text.replace(MerchantDialogueBubble.NO_BREAK_MARK, "")


func _pool_contains_collectible(pool: Array, target_item: PickupConfig) -> bool:
	for item_variant in pool:
		var item := item_variant as PickupConfig
		if item != null and item.resource_path == target_item.resource_path:
			return true
	return false


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
