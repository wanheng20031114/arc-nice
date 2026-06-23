extends SceneTree

const PLAYER_SCENE := preload("res://scene/player.tscn")
const PROFILE_PANEL_SCENE := preload("res://scene/player_profile_panel.tscn")
const APPLE_COLLECTIBLE := preload("res://resources/config/pickups/collectible_apple.tres")
const HEALTH_PICKUP := preload("res://resources/config/pickups/pickup_health.tres")

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

	profile_panel.bind_player(player)
	_expect(run_state.try_add_item(APPLE_COLLECTIBLE), "The first apple collectible must fit in inventory.")
	_expect(run_state.try_add_item(APPLE_COLLECTIBLE), "The second apple collectible must fit in inventory.")
	_expect(run_state.try_add_item(HEALTH_PICKUP), "The health pickup must fit in inventory.")
	_expect(
		is_equal_approx(player.call("_get_inventory_bullet_pierce_chance"), 0.5),
		"Owning multiple apples must still grant only the single 50% piercing chance."
	)

	profile_panel.open()
	await process_frame
	_expect(profile_panel.selected_slot_index == -1, "Opening the inventory must not auto-select the first slot.")
	_expect(not profile_panel.item_detail_panel.visible, "Opening the inventory must not show an item detail panel by default.")
	_expect(not profile_panel.slots[0].button_pressed, "Opening the inventory must leave the first slot unselected.")

	profile_panel.slots[0].emit_signal("pressed")
	await process_frame
	_expect(profile_panel.item_detail_panel.visible, "Selecting an occupied inventory slot must show the item detail panel.")
	_expect(profile_panel.item_detail_title.text.contains("苹果"), "The item detail panel must show the collectible name.")
	_expect(profile_panel.item_detail_title.text.contains("收藏品"), "The item detail panel must label apples as collectibles.")
	_expect(
		profile_panel.item_detail_description.text.contains(APPLE_COLLECTIBLE.description),
		"The item detail panel must show the collectible description."
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
	_expect(not profile_panel.slots[0].button_pressed, "Clicking blank inventory space must remove the selected slot highlight.")

	profile_panel.slots[0].emit_signal("pressed")
	await process_frame
	profile_panel.item_detail_discard_button.emit_signal("pressed")
	await process_frame
	_expect(run_state.get_item(0) == null, "Discarding a collectible from the detail panel must destroy it.")
	_expect(run_state.get_item(1) == APPLE_COLLECTIBLE, "Discarding one apple must not remove another apple.")
	_expect(
		is_equal_approx(player.call("_get_inventory_bullet_pierce_chance"), 0.5),
		"One remaining apple must keep the piercing chance at 50%."
	)
	_expect(not profile_panel.item_detail_panel.visible, "The item detail panel must hide when the selected slot becomes empty.")
	_expect(profile_panel.selected_slot_index == -1, "Discarding the selected item must clear the selected slot.")

	profile_panel.slots[2].emit_signal("pressed")
	await process_frame
	_expect(profile_panel.item_detail_panel.visible, "Selecting a stored consumable must show the item detail panel.")
	_expect(profile_panel.item_detail_title.text.contains("生命药瓶"), "The item detail panel must show the consumable name.")
	_expect(profile_panel.item_detail_title.text.contains("道具"), "The item detail panel must label health bottles as items.")
	_expect(profile_panel.item_detail_use_button.visible, "Consumable items must show a green use button.")
	_expect(profile_panel.item_detail_discard_button.visible, "Consumable items must show a red discard button.")
	_expect(profile_panel.item_detail_hint.visible, "Consumable items must show the double-click use hint.")
	_expect(profile_panel.item_detail_hint.text.contains("双击"), "The consumable hint must mention double-click use.")

	player.current_health = maxi(player.max_health - HEALTH_PICKUP.heal_amount, 1)
	profile_panel.item_detail_use_button.emit_signal("pressed")
	await process_frame
	_expect(run_state.get_item(2) == null, "Using a consumable from the detail panel must remove it from inventory.")
	_expect(player.current_health == player.max_health, "Using a health bottle from the detail panel must heal the player.")

	_expect(run_state.try_add_item(HEALTH_PICKUP), "A replacement health pickup must fit for discard testing.")
	profile_panel.slots[0].emit_signal("pressed")
	await process_frame
	profile_panel.item_detail_discard_button.emit_signal("pressed")
	await process_frame
	_expect(run_state.get_item(0) == null, "Discarding a consumable from the detail panel must destroy it.")

	_expect(run_state.try_add_item(HEALTH_PICKUP), "A replacement health pickup must fit for double-click testing.")
	profile_panel.slots[0].emit_signal("pressed")
	await process_frame
	player.current_health = maxi(player.max_health - HEALTH_PICKUP.heal_amount, 1)
	var double_click := InputEventMouseButton.new()
	double_click.button_index = MOUSE_BUTTON_LEFT
	double_click.pressed = true
	double_click.double_click = true
	profile_panel.slots[0]._on_gui_input(double_click)
	await process_frame
	_expect(run_state.get_item(0) == null, "Double-clicking a consumable slot must still use and remove the item.")
	_expect(player.current_health == player.max_health, "Double-clicking a health bottle must still heal the player.")

	_stop_audio_players(test_root)
	profile_panel.close()
	profile_panel.queue_free()
	player.queue_free()
	await process_frame
	await physics_frame


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
