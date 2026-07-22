extends SceneTree

const PLAYER_SCENE := preload("res://scene/player/weishidaier/player_weishidaier.tscn")
const PROFILE_PANEL_SCENE := preload("res://scene/player/ui/player_profile_panel.tscn")
const APPLE_COLLECTIBLE := preload("res://resources/config/collectibles/collectible_apple.tres")
const HEALTH_PICKUP := preload("res://resources/config/pickups/pickup_health.tres")
const ITEM_DETAIL_PANEL_BG := preload("res://resources/texture/item_detail_panel_bg.png")
const ITEM_CATEGORY_BADGE_COLLECTIBLE := preload("res://resources/texture/item_category_badge_collectible.png")
const ITEM_CATEGORY_BADGE_ITEM := preload("res://resources/texture/item_category_badge_item.png")

var failures: Array[String] = []
var test_root: Node2D


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	test_root = Node2D.new()
	test_root.name = "PlayerProfileInventoryDetailSmokeTest"
	root.add_child(test_root)
	current_scene = test_root

	await _test_inventory_detail_panel_and_item_actions()

	test_root.queue_free()
	for _cleanup_frame in range(8):
		await process_frame
		await physics_frame

	if failures.is_empty():
		print("PLAYER_PROFILE_INVENTORY_DETAIL_SMOKE_TEST_OK")
		quit()
		return

	for failure in failures:
		push_error(failure)
	quit(1)


func _test_inventory_detail_panel_and_item_actions() -> void:
	var run_state := root.get_node("RunState") as RunStateStore
	run_state.begin_new_run()

	var player := PLAYER_SCENE.instantiate() as Player
	var profile_panel := PROFILE_PANEL_SCENE.instantiate() as PlayerProfilePanel
	test_root.add_child(player)
	test_root.add_child(profile_panel)
	await process_frame
	await physics_frame
	var panel_root := profile_panel.get_node("Overlay/PanelRoot") as Control
	var viewport_size := Vector2(root.get_visible_rect().size)
	var expected_scale := 1.0
	if viewport_size.x < 724.0 or viewport_size.y < 543.0:
		expected_scale = minf(viewport_size.x / 724.0, viewport_size.y / 543.0) * 0.94
		expected_scale = minf(expected_scale, 1.0)
	_expect(
		panel_root.scale.is_equal_approx(Vector2.ONE * expected_scale),
		"Profile panel must remain native-sized when it fits and scale uniformly only on smaller viewports."
	)
	_expect(
		panel_root.position.is_equal_approx(panel_root.position.round()),
		"Profile PanelRoot must stay on integer canvas coordinates."
	)
	_expect(
		panel_root.position.x >= 0.0 and panel_root.position.y >= 0.0
		and panel_root.position.x + 724.0 * expected_scale <= viewport_size.x + 1.0
		and panel_root.position.y + 543.0 * expected_scale <= viewport_size.y + 1.0,
		"Profile panel must stay fully inside the viewport after its responsive transform."
	)

	profile_panel.bind_player(player)
	_expect(run_state.try_add_item(APPLE_COLLECTIBLE), "The first apple collectible must fit in inventory.")
	_expect(run_state.try_add_item(APPLE_COLLECTIBLE), "The second apple collectible must fit in inventory.")
	_expect(run_state.try_add_item(HEALTH_PICKUP), "The health pickup must fit in inventory.")
	_expect(
		is_equal_approx(player.call("_get_inventory_bullet_pierce_chance"), 0.4),
		"Two apples must stack to a 40% piercing chance."
	)

	profile_panel.open()
	await process_frame
	_expect(
		not profile_panel.is_processing(),
		"An open profile panel must remain event-driven instead of polling stats every frame."
	)
	_expect(profile_panel.selected_slot_index == -1, "Opening the inventory must not auto-select the first slot.")
	_expect(not profile_panel.item_detail_panel.visible, "Opening the inventory must not show an item detail panel by default.")
	_expect(not profile_panel.slots[0].button_pressed, "Opening the inventory must leave the first slot unselected.")
	var raw_attack_speed := player.get_attack_speed()
	var rounded_attack_speed := roundf(raw_attack_speed)
	var expected_attack_speed_text := (
		str(roundi(rounded_attack_speed))
		if is_equal_approx(raw_attack_speed, rounded_attack_speed)
		else "%.2f" % raw_attack_speed
	)
	_expect(
		profile_panel.attack_speed_value.text == expected_attack_speed_text,
		"Profile panel must show only raw attack speed without attacks-per-second text."
	)
	_expect(profile_panel.move_speed_value.text == str(roundi(player.move_speed)), "Profile panel must show current movement speed.")
	_expect(profile_panel.physical_defense_value.text == str(player.physical_defense), "Profile panel must show current physical defense.")
	_expect(profile_panel.magic_defense_value.text == str(player.magic_defense), "Profile panel must show current magic defense.")

	player.upgrade_attack()
	_expect(
		profile_panel.attack_value.text == str(player.attack_damage),
		"Profile panel attack text must update from the player state-change signal."
	)
	player.set_research_global_move_speed_bonus(7.0)
	_expect(
		profile_panel.move_speed_value.text == str(roundi(player.move_speed)),
		"Profile panel movement text must update from the player state-change signal."
	)
	player.set_research_temporary_physical_defense_bonus(9)
	_expect(
		profile_panel.physical_defense_value.text == str(player.physical_defense),
		"Profile panel defense text must update from the player state-change signal."
	)
	_expect(player.unlock_skill1(), "The profile event test must unlock skill 1 once.")
	_expect(
		profile_panel.skill_info.visible,
		"Profile panel skill presentation must update when the skill is unlocked."
	)
	var previous_skill_cost_text := profile_panel.skill_cost_label.text
	_expect(player.try_upgrade_skill1_free(), "The profile event test must upgrade skill 1 once.")
	_expect(
		profile_panel.skill_cost_label.text != previous_skill_cost_text,
		"Profile panel skill cost must update when the skill level changes."
	)

	profile_panel.slots[1].emit_signal("pressed")
	await process_frame
	_expect(profile_panel.item_detail_panel.visible, "Selecting an occupied inventory slot must show the item detail panel.")
	var detail_style := profile_panel.item_detail_panel.get_theme_stylebox("panel") as StyleBoxTexture
	_expect(detail_style != null and detail_style.texture == ITEM_DETAIL_PANEL_BG, "The item detail panel must use the generated background texture.")
	_expect(profile_panel.item_detail_title.text == "苹果", "The item detail panel title must show only the item name.")
	_expect(not profile_panel.item_detail_title.text.contains("收藏品"), "The item detail panel title must not append the item category.")
	_expect(profile_panel.item_detail_category_label.text == "收藏品", "The item detail panel must show the collectible category in its own label.")
	_expect(profile_panel.item_detail_category_backing.texture == ITEM_CATEGORY_BADGE_COLLECTIBLE, "Collectibles must use the generated collectible badge texture.")
	_expect(
		profile_panel.item_detail_description.text.contains(APPLE_COLLECTIBLE.description),
		"The item detail panel must show the collectible description."
	)
	_expect(profile_panel.item_detail_description.scroll_active, "The item detail panel description must scroll instead of clipping long text.")
	var description_style := profile_panel.item_detail_description.get_theme_stylebox("normal") as StyleBoxFlat
	_expect(
		description_style != null
		and description_style.get_content_margin(SIDE_LEFT) >= 5.0
		and description_style.get_content_margin(SIDE_RIGHT) >= 7.0,
		"The item detail panel description must leave horizontal glyph padding."
	)
	_expect(not profile_panel.item_detail_use_button.visible, "Collectibles must not show a use button.")
	_expect(profile_panel.item_detail_discard_button.visible, "Collectibles must show a discard button.")

	var blank_click := InputEventMouseButton.new()
	blank_click.button_index = MOUSE_BUTTON_LEFT
	blank_click.pressed = true
	blank_click.position = Vector2(72.0, 86.0)
	profile_panel.call("_on_inventory_grid_gui_input", blank_click)
	await process_frame
	_expect(profile_panel.selected_slot_index == -1, "Clicking blank inventory space must clear the selected slot.")
	_expect(not profile_panel.item_detail_panel.visible, "Clicking blank inventory space must hide the item detail panel.")
	_expect(not profile_panel.slots[1].button_pressed, "Clicking blank inventory space must remove the selected slot highlight.")

	profile_panel.slots[1].emit_signal("pressed")
	await process_frame
	profile_panel.item_detail_discard_button.emit_signal("pressed")
	await process_frame
	_expect(run_state.get_item(1) == null, "Discarding a collectible from the detail panel must destroy it.")
	_expect(run_state.get_item(2) == APPLE_COLLECTIBLE, "Discarding one apple must not remove another apple.")
	_expect(
		is_equal_approx(player.call("_get_inventory_bullet_pierce_chance"), 0.2),
		"One remaining apple must keep the piercing chance at 20%."
	)
	_expect(not profile_panel.item_detail_panel.visible, "The item detail panel must hide when the selected slot becomes empty.")
	_expect(profile_panel.selected_slot_index == -1, "Discarding the selected item must clear the selected slot.")

	profile_panel.slots[3].emit_signal("pressed")
	await process_frame
	_expect(profile_panel.item_detail_panel.visible, "Selecting a stored consumable must show the item detail panel.")
	_expect(profile_panel.item_detail_title.text == "生命药瓶", "The item detail panel title must show only the consumable name.")
	_expect(profile_panel.item_detail_category_label.text == "道具", "The item detail panel must show the consumable category in its own label.")
	_expect(profile_panel.item_detail_category_backing.texture == ITEM_CATEGORY_BADGE_ITEM, "Consumables must use the generated item badge texture.")
	_expect(profile_panel.item_detail_use_button.visible, "Consumable items must show a green use button.")
	_expect(profile_panel.item_detail_discard_button.visible, "Consumable items must show a red discard button.")
	_expect(profile_panel.item_detail_hint.visible, "Consumable items must show the double-click use hint.")
	_expect(profile_panel.item_detail_hint.text.contains("双击"), "The consumable hint must mention double-click use.")

	player.current_health = maxi(player.max_health - HEALTH_PICKUP.heal_amount, 1)
	profile_panel.item_detail_use_button.emit_signal("pressed")
	await process_frame
	_expect(run_state.get_item(3) == null, "Using a consumable from the detail panel must remove it from inventory.")
	_expect(player.current_health == player.max_health, "Using a health bottle from the detail panel must heal the player.")

	_expect(run_state.try_add_item(HEALTH_PICKUP), "A replacement health pickup must fit for discard testing.")
	profile_panel.slots[1].emit_signal("pressed")
	await process_frame
	profile_panel.item_detail_discard_button.emit_signal("pressed")
	await process_frame
	_expect(run_state.get_item(1) == null, "Discarding a consumable from the detail panel must destroy it.")

	_expect(run_state.try_add_item(HEALTH_PICKUP), "A replacement health pickup must fit for double-click testing.")
	profile_panel.slots[1].emit_signal("pressed")
	await process_frame
	player.current_health = maxi(player.max_health - HEALTH_PICKUP.heal_amount, 1)
	_simulate_double_click(profile_panel.slots[1])
	await process_frame
	_expect(run_state.get_item(1) == null, "Double-clicking a consumable slot must still use and remove the item.")
	_expect(player.current_health == player.max_health, "Double-clicking a health bottle must still heal the player.")

	_stop_audio_players(test_root)
	profile_panel.close()
	profile_panel.queue_free()
	player.queue_free()
	await process_frame
	await physics_frame


func _simulate_double_click(slot: InventorySlot) -> void:
	for _click_index in 2:
		var press := InputEventMouseButton.new()
		press.button_index = MOUSE_BUTTON_LEFT
		press.pressed = true
		press.position = Vector2(24.0, 24.0)
		slot._on_gui_input(press)
		var release := InputEventMouseButton.new()
		release.button_index = MOUSE_BUTTON_LEFT
		release.pressed = false
		release.position = press.position
		slot._on_gui_input(release)


func _stop_audio_players(node: Node) -> void:
	if node is AudioStreamPlayer:
		(node as AudioStreamPlayer).stop()
	elif node is AudioStreamPlayer2D:
		(node as AudioStreamPlayer2D).stop()
	for child in node.get_children():
		_stop_audio_players(child)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
