extends SceneTree

const PLAYER_SCENE := preload("res://scene/player/weishidaier/player_weishidaier.tscn")
const PROFILE_PANEL_SCENE := preload(
	"res://scene/game_modes/standard/ui/standard_player_profile_panel.tscn"
)
const APPLE_COLLECTIBLE := preload("res://resources/config/collectibles/collectible_apple.tres")
const HEALTH_PICKUP := preload("res://resources/config/consumables/healing_potion.tres")
const XIAOCONG_FATE_STONE := preload(
	"res://resources/config/fate/xiaocong_fate_stone.tres"
)
const ITEM_DETAIL_PANEL_BG := preload("res://resources/texture/item_detail_panel_bg.png")
const ITEM_CATEGORY_BADGE_COLLECTIBLE := preload("res://resources/texture/item_category_badge_collectible.png")
const ITEM_CATEGORY_BADGE_ITEM := preload("res://resources/texture/item_category_badge_item.png")
const QUICK_USE_BADGE := preload(
	"res://resources/texture/ui/inventory/quick_use_badge.png"
)

var failures: Array[String] = []
var test_root: Node2D


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	test_root = Node2D.new()
	test_root.name = "PlayerProfileInventoryDetailSmokeTest"
	root.add_child(test_root)
	current_scene = test_root

	_test_quick_use_badge_asset_contract()
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


func _test_quick_use_badge_asset_contract() -> void:
	var source_bytes := FileAccess.get_file_as_bytes(
		"res://resources/texture/ui/inventory/quick_use_badge.png"
	)
	var source_image := Image.new()
	_expect(
		source_image.load_png_from_buffer(source_bytes) == OK,
		"Quick-use badge source PNG must decode successfully."
	)
	if source_image.is_empty():
		return
	_expect(
		source_image.get_size() == Vector2i(10, 10)
		and source_image.get_used_rect() == Rect2i(2, 1, 6, 8),
		"Quick-use badge must remain a 10x10 canvas with its reviewed inset silhouette."
	)
	var visible_colors := {}
	var alpha_values := {}
	var transparent_rgb_is_zero := true
	for y in source_image.get_height():
		for x in source_image.get_width():
			var pixel := source_image.get_pixel(x, y)
			alpha_values[pixel.a8] = true
			if pixel.a8 == 0:
				transparent_rgb_is_zero = (
					transparent_rgb_is_zero
					and pixel.r8 == 0
					and pixel.g8 == 0
					and pixel.b8 == 0
				)
			else:
				visible_colors[pixel] = true
	_expect(
		alpha_values.keys() == [0, 255]
		and transparent_rgb_is_zero,
		"Quick-use badge must use binary alpha and zero RGB in transparent pixels."
	)
	_expect(
		visible_colors.size() == 2
		and visible_colors.has(Color8(169, 232, 255, 255))
		and visible_colors.has(Color8(22, 143, 209, 255)),
		"Quick-use badge must retain the approved pale/saturated sky-blue palette."
	)
	var import_source := FileAccess.get_file_as_string(
		"res://resources/texture/ui/inventory/quick_use_badge.png.import"
	)
	_expect(
		import_source.contains("compress/mode=0")
		and import_source.contains("mipmaps/generate=false")
		and import_source.contains("process/premult_alpha=false")
		and import_source.contains("process/size_limit=0"),
		"Quick-use badge import must stay lossless, unmipped, and native-sized."
	)


func _test_inventory_detail_panel_and_item_actions() -> void:
	var run_state := root.get_node("RunState") as RunStateStore
	run_state.begin_new_run()

	var player := PLAYER_SCENE.instantiate() as Player
	var profile_panel := (
		PROFILE_PANEL_SCENE.instantiate() as StandardPlayerProfilePanel
	)
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
	_expect(player.has_skill1(), "The profile event test player must start with skill 1.")
	_expect(
		profile_panel.skill_info.visible,
		"Profile panel must present the player's starting skill."
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
	var quick_use_button := (
		profile_panel.inventory_view.item_detail_quick_use_button
	)
	_expect(
		not quick_use_button.visible,
		"Collectibles must not show a quick-use binding button."
	)
	_expect(
		not profile_panel.slots[1].quick_use_marker.visible,
		"Collectible slots must not show the quick-use marker."
	)
	var base_detail_height := profile_panel.item_detail_panel.size.y

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
	_expect(profile_panel.item_detail_title.text == "治疗血瓶", "The item detail panel title must show only the consumable name.")
	_expect(profile_panel.item_detail_category_label.text == "消耗品", "The item detail panel must show the consumable category in its own label.")
	_expect(profile_panel.item_detail_category_backing.texture == ITEM_CATEGORY_BADGE_ITEM, "Consumables must use the generated item badge texture.")
	_expect(profile_panel.item_detail_use_button.visible, "Consumable items must show a green use button.")
	_expect(profile_panel.item_detail_discard_button.visible, "Consumable items must show a red discard button.")
	_expect(profile_panel.item_detail_hint.visible, "Consumable items must show the double-click use hint.")
	_expect(profile_panel.item_detail_hint.text.contains("双击"), "The consumable hint must mention double-click use.")
	_expect(
		quick_use_button.visible
		and quick_use_button.text == "设置快捷使用"
		and quick_use_button.size.x >= 230.0,
		"Consumables must expose the full-width quick-use binding action."
	)
	_expect(
		profile_panel.item_detail_panel.size.y > base_detail_height + 30.0,
		"Showing the quick-use action must expand the item detail panel vertically."
	)
	_expect(
		profile_panel.item_detail_panel.position.y >= 14.0
		and (
			profile_panel.item_detail_panel.position.y
			+ profile_panel.item_detail_panel.size.y
			<= 543.0 - 14.0
		),
		"The expanded consumable detail panel must remain inside the authored design area."
	)
	_expect(
		profile_panel.slots[3].quick_use_marker.texture == QUICK_USE_BADGE
		and profile_panel.slots[3].quick_use_marker.size == Vector2(10.0, 10.0)
		and (
			profile_panel.slots[3].quick_use_marker.position
			+ profile_panel.slots[3].quick_use_marker.size
		).is_equal_approx(profile_panel.slots[3].size - Vector2(2.0, 2.0)),
		"The inventory slot must own the authored 10x10 quick-use badge overlay."
	)
	quick_use_button.emit_signal("pressed")
	await process_frame
	_expect(
		run_state.is_quick_use_slot(3)
		and profile_panel.slots[3].quick_use_marker.visible,
		"Setting quick use must mark the selected consumable slot."
	)
	_expect(
		quick_use_button.text == "取消快捷使用"
		and profile_panel.slots[3].tooltip_text.contains("已设置快捷使用"),
		"A bound slot must expose both toggle text and an accessible tooltip status."
	)
	quick_use_button.emit_signal("pressed")
	await process_frame
	_expect(
		run_state.get_quick_use_bound_config_path().is_empty()
		and not profile_panel.slots[3].quick_use_marker.visible
		and quick_use_button.text == "设置快捷使用",
		"Pressing the bound action again must cancel quick use and clear its marker."
	)
	quick_use_button.emit_signal("pressed")
	await process_frame

	player.current_health = maxi(player.max_health - HEALTH_PICKUP.heal_amount, 1)
	profile_panel.item_detail_use_button.emit_signal("pressed")
	await process_frame
	_expect(run_state.get_item(3) == null, "Using a consumable from the detail panel must remove it from inventory.")
	_expect(player.current_health == player.max_health, "Using a health bottle from the detail panel must heal the player.")
	_expect(
		run_state.get_quick_use_bound_config_path() == HEALTH_PICKUP.resource_path
		and not profile_panel.slots[3].quick_use_marker.visible,
		"Consuming the last bound item must hide its marker while keeping the item-type binding dormant."
	)

	_expect(run_state.try_add_item(HEALTH_PICKUP), "A replacement health pickup must fit for discard testing.")
	_expect(run_state.try_add_item(HEALTH_PICKUP), "A second replacement health pickup must join the discard-test stack.")
	profile_panel.slots[1].emit_signal("pressed")
	await process_frame
	_expect(
		profile_panel.slots[1].quick_use_marker.visible
		and profile_panel.slots[1].stack_count_label.visible
		and quick_use_button.text == "取消快捷使用"
		and not profile_panel.slots[1].quick_use_marker.get_rect().intersects(
			profile_panel.slots[1].stack_count_label.get_rect()
		),
		"Reacquiring the bound item must restore its bottom-right marker without overlapping the top-right stack count."
	)
	profile_panel.item_detail_discard_button.emit_signal("pressed")
	await process_frame
	_expect(run_state.get_item(1) == null, "Discarding a consumable from the detail panel must destroy it.")
	_expect(
		run_state.get_quick_use_bound_config_path() == HEALTH_PICKUP.resource_path
		and not profile_panel.slots[1].quick_use_marker.visible,
		"Discarding the bound stack must leave its item-type binding dormant and hide the marker."
	)

	_expect(run_state.try_add_item(HEALTH_PICKUP), "A replacement health pickup must fit for double-click testing.")
	profile_panel.slots[1].emit_signal("pressed")
	await process_frame
	player.current_health = maxi(player.max_health - HEALTH_PICKUP.heal_amount, 1)
	_simulate_double_click(profile_panel.slots[1])
	await process_frame
	_expect(run_state.get_item(1) == null, "Double-clicking a consumable slot must still use and remove the item.")
	_expect(player.current_health == player.max_health, "Double-clicking a health bottle must still heal the player.")

	_expect(
		run_state.try_add_item(XIAOCONG_FATE_STONE),
		"The Xiaocong fate stone must fit in an available backpack slot."
	)
	var stone_slot_index := -1
	for slot_index in range(profile_panel.slots.size()):
		if run_state.get_item(slot_index) == XIAOCONG_FATE_STONE:
			stone_slot_index = slot_index
			break
	_expect(stone_slot_index >= 0, "The fate stone must remain visible in the backpack.")
	if stone_slot_index >= 0:
		profile_panel.slots[stone_slot_index].emit_signal("pressed")
		await process_frame
		_expect(
			profile_panel.item_detail_hint.visible
			and "无法使用、移动或删除" in profile_panel.item_detail_hint.text,
			"A locked fate item must explain all of its backpack restrictions."
		)
		_expect(
			not profile_panel.item_detail_use_button.visible
			and not profile_panel.item_detail_discard_button.visible,
			"A locked fate item must not expose use or discard actions."
		)
		_simulate_double_click(profile_panel.slots[stone_slot_index])
		await process_frame
		_expect(
			run_state.get_item(stone_slot_index) == XIAOCONG_FATE_STONE
			and not run_state.discard_item(stone_slot_index),
			"Double-click and direct discard attempts must not remove the fate stone."
		)

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
