extends SceneTree

const GAME_SCENE := preload("res://scene/game_tower_defense.tscn")

var failures: Array[String] = []
var test_root: Node2D


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	test_root = Node2D.new()
	test_root.name = "TowerDefenseCollectiblePlacementSmokeTest"
	root.add_child(test_root)
	current_scene = test_root

	var run_state := root.get_node("RunState") as RunStateStore
	for character_config in PlayerCharacterRegistry.get_all_configs():
		var character_id := character_config.character_id
		run_state.begin_new_run(character_id)
		var game := GAME_SCENE.instantiate() as GameTowerDefense
		game.auto_start_waves = false
		test_root.add_child(game)
		await process_frame
		await physics_frame

		var controller := game.plant_placement_controller
		var window := game.debug_collectible_window
		_expect(controller != null, "Tower-defense game must expose the placement controller.")
		_expect(window != null, "Tower-defense game must expose the debug collectible window.")
		if controller != null and window != null:
			var crowd_root := await _create_enemy_crowd_placement_fixture(game)
			await _test_f10_collectible_then_place(game, controller, window)
			if crowd_root != null and is_instance_valid(crowd_root):
				crowd_root.queue_free()
				await process_frame
				await physics_frame

		if controller != null:
			controller.cancel_placement()
		if window != null:
			window.close()
		game.plant_system.clear_all_plants()
		_clear_inventory(game.run_state)
		_stop_audio_players(game)
		game.queue_free()
		await process_frame
		await physics_frame
		await process_frame
	test_root.queue_free()
	await process_frame
	await physics_frame

	if failures.is_empty():
		print("TOWER_DEFENSE_COLLECTIBLE_PLACEMENT_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_f10_collectible_then_place(
	game: GameTowerDefense,
	controller: PlantPlacementController,
	window: DebugCollectibleWindow
) -> void:
	var collectible_pool := LuoxiMerchant.get_collectible_pool()
	_expect(not collectible_pool.is_empty(), "The collectible debug list must not be empty.")
	for item_variant in collectible_pool:
		var item := item_variant as PickupConfig
		if item == null:
			continue
		_clear_inventory(game.run_state)
		await _send_action(&"cheat_collectibles")
		_expect(window.is_open(), "F10 must open the collectible window through normal input dispatch.")
		_expect(
			not controller.is_processing_unhandled_input(),
			"An open collectible window must suspend placement input."
		)
		window.collectible_requested.emit(item.resource_path)
		await process_frame
		_expect(game.run_state.get_item(0) == item, "F10 must grant %s." % item.display_name)

		await _send_action(&"cheat_collectibles")
		_expect(not window.is_open(), "A second F10 press must close the collectible window.")
		_expect(
			not window.collectible_list.has_focus(),
			"Closing F10 after %s must release the debug ItemList focus." % item.display_name
		)
		_expect(
			controller.is_processing_unhandled_input(),
			"Closing F10 after %s must restore placement input." % item.display_name
		)
		_expect(not game.player.controls_locked, "Closing F10 after %s must release the player lock." % item.display_name)

		await _send_action(&"plant")
		_expect(controller.is_selecting(), "Plant input after %s must open selection." % item.display_name)
		if not controller.is_selecting():
			return
		var configs := game.plant_system.get_available_configs()
		_expect(not configs.is_empty(), "Plant registry must expose placeable configs.")
		if configs.is_empty():
			return
		controller.selection_hud.selection_confirmed.emit(configs[0])
		await process_frame
		await physics_frame
		_expect(controller.is_placing(), "Confirming after %s must enter world placement." % item.display_name)
		_expect(
			not controller.valid_anchors.is_empty(),
			"At least one plant anchor must remain after %s." % item.display_name
		)
		controller.cancel_placement()
		await process_frame

	# Mouse users close through this button instead of F10. Its own focus must
	# not survive as a hidden modal owner either.
	await _send_action(&"cheat_collectibles")
	window.close_button.grab_focus()
	window.close()
	await process_frame
	var focus_owner := root.gui_get_focus_owner()
	_expect(
		focus_owner == null or not window.is_ancestor_of(focus_owner),
		"The focused close-button route must release all debug modal focus."
	)
	_expect(
		controller.is_processing_unhandled_input(),
		"The focused close-button route must restore placement input."
	)

	# Exercise the complete click-to-placement path once after all collectible
	# inventory refresh variants have run.
	await _send_action(&"plant")
	var configs := game.plant_system.get_available_configs()
	controller.selection_hud.selection_confirmed.emit(configs[0])
	await process_frame
	await physics_frame
	if controller.valid_anchors.is_empty():
		_expect(false, "At least one final valid plant anchor must remain after F10.")
		return

	var anchor := controller.valid_anchors[0]
	controller.call("_set_hovered_anchor", anchor, true)
	var plant_count_before := game.plant_container.get_child_count()
	controller.call("_try_place_hovered")
	await process_frame
	_expect(
		game.plant_container.get_child_count() == plant_count_before + 1,
		"A valid world click after F10 must place the selected plant."
	)


func _create_enemy_crowd_placement_fixture(game: GameTowerDefense) -> Node2D:
	var configs := game.plant_system.get_available_configs()
	_expect(not configs.is_empty(), "Enemy-crowd placement regression requires a plant config.")
	if configs.is_empty():
		return null
	var config := configs[0]
	var baseline_anchors := game.plant_system.get_valid_anchors_for_player(config, game.player)
	_expect(
		not baseline_anchors.is_empty(),
		"Enemy-crowd placement regression requires at least one baseline anchor."
	)
	if baseline_anchors.is_empty():
		return null

	_expect(
		(PlantSystem.ENTITY_BLOCKING_MASK & 4) == 0
		and (PlantSystem.ENTITY_BLOCKING_MASK & 256) == 0,
		"Normal enemy and boss combat layers must not participate in placement blocking."
	)
	_expect(
		(PlantSystem.ENTITY_BLOCKING_MASK & 1) != 0
		and (PlantSystem.ENTITY_BLOCKING_MASK & 2) != 0,
		"Static world and player bodies must remain placement blockers."
	)

	var crowd_root := Node2D.new()
	crowd_root.name = "TransientCombatPlacementCrowd"
	game.add_child(crowd_root)
	var blocker_shape := RectangleShape2D.new()
	blocker_shape.size = Vector2(12.0, 12.0)
	for anchor in baseline_anchors:
		_create_combat_blocker(
			crowd_root,
			blocker_shape,
			4,
			game.plant_system.get_anchor_world_position(anchor, config)
		)
		_create_combat_blocker(
			crowd_root,
			blocker_shape,
			256,
			game.plant_system.get_anchor_world_position(anchor, config)
		)
	await physics_frame

	var crowded_anchors := game.plant_system.get_valid_anchors_for_player(config, game.player)
	_expect(
		crowded_anchors == baseline_anchors,
		(
			"Enemy/Boss bodies covering every baseline anchor must not erase placement "
			+ "options. baseline=%d crowded=%d"
		) % [baseline_anchors.size(), crowded_anchors.size()]
	)
	# Keep the complete crowd alive throughout the following F10/collectible and
	# plant-input loop. This reproduces the reported combination instead of only
	# comparing placement anchors before opening the debug modal.
	return crowd_root


func _create_combat_blocker(
	parent: Node2D,
	shape: Shape2D,
	layer: int,
	world_position: Vector2
) -> void:
	var body := CharacterBody2D.new()
	body.collision_layer = layer
	body.collision_mask = 0
	var collision_shape := CollisionShape2D.new()
	collision_shape.shape = shape
	body.add_child(collision_shape)
	parent.add_child(body)
	body.global_position = world_position


func _clear_inventory(run_state: RunStateStore) -> void:
	for slot_index in range(RunStateStore.INVENTORY_CAPACITY):
		if run_state.get_item(slot_index) != null:
			run_state.discard_item(slot_index)


func _send_action(action: StringName) -> void:
	var press := InputEventAction.new()
	press.action = action
	press.pressed = true
	Input.parse_input_event(press)
	await process_frame
	var release := InputEventAction.new()
	release.action = action
	release.pressed = false
	Input.parse_input_event(release)
	await process_frame


func _stop_audio_players(node: Node) -> void:
	if node is AudioStreamPlayer or node is AudioStreamPlayer2D:
		node.stop()
	for child in node.get_children():
		_stop_audio_players(child)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
