extends SceneTree

const MAIN_MENU_SCENE := preload("res://scene/main_menu.tscn")
const GAME_TOWER_DEFENSE_SCENE := preload("res://scene/game_tower_defense.tscn")
const TEST_GRASS_ARENA_SCENE_PATH := "res://scene/test_arena/test_grass_arena.tscn"

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_tower_defense_scene_identity()
	await _test_main_menu_entry()

	if current_scene != null:
		current_scene.queue_free()
	await process_frame

	if failures.is_empty():
		print("GAME_TOWER_DEFENSE_SMOKE_TEST_OK")
		quit()
		return

	for failure in failures:
		push_error(failure)
	quit(1)


func _test_tower_defense_scene_identity() -> void:
	var game_tower_defense := GAME_TOWER_DEFENSE_SCENE.instantiate() as GameTowerDefense
	_expect(game_tower_defense != null, "Tower-defense scene must instantiate as GameTowerDefense.")
	if game_tower_defense == null:
		return
	_expect(game_tower_defense.name == &"GameTowerDefense", "Tower-defense root node name is incorrect.")
	_expect(
		game_tower_defense.get_script().resource_path == "res://scene/game_tower_defense.gd",
		"Tower-defense scene must use its independent controller script."
	)
	var warehouse_panels: Array[OakWarehousePanel] = []
	for candidate in game_tower_defense.find_children("*", "", true, false):
		if candidate is OakWarehousePanel:
			warehouse_panels.append(candidate as OakWarehousePanel)
	_expect(
		warehouse_panels.size() == 1
		and warehouse_panels[0] == game_tower_defense.get_node_or_null("OakWarehousePanel"),
		"Tower-defense scene must author exactly one game-level shared oak warehouse panel."
	)
	game_tower_defense.free()


func _test_main_menu_entry() -> void:
	var main_menu := MAIN_MENU_SCENE.instantiate() as Control
	root.add_child(main_menu)
	current_scene = main_menu
	await process_frame

	var tower_defense_button := main_menu.get_node_or_null(
		"MenuCenter/MenuPanel/MarginContainer/MenuStack/TowerDefense"
	) as Button
	_expect(tower_defense_button != null, "Main menu must include the TowerDefense button.")
	if tower_defense_button == null:
		return
	_expect(tower_defense_button.text == "塔防模式", "Tower-defense button text is incorrect.")
	_expect(
		tower_defense_button.pressed.is_connected(
			Callable(main_menu, "_on_tower_defense_pressed")
		),
		"Tower-defense button must be connected to its menu handler."
	)
	var test_arena_button := main_menu.get_node_or_null(
		"MenuCenter/MenuPanel/MarginContainer/MenuStack/TestArena"
	) as Button
	_expect(test_arena_button != null, "Main menu must include the TestArena button.")
	if test_arena_button == null:
		return
	_expect(test_arena_button.text == "测试场景", "Test-arena button text is incorrect.")
	_expect(
		test_arena_button.pressed.is_connected(
			Callable(main_menu, "_on_test_arena_pressed")
		),
		"Test-arena button must be connected to its menu handler."
	)
	var singleplayer_button := main_menu.get_node(
		"MenuCenter/MenuPanel/MarginContainer/MenuStack/SinglePlayer"
	) as Button
	var multiplayer_button := main_menu.get_node(
		"MenuCenter/MenuPanel/MarginContainer/MenuStack/Multiplayer"
	) as Button
	_expect(
		singleplayer_button.pressed.is_connected(Callable(main_menu, "_on_singleplayer_pressed")),
		"Existing single-player menu connection must remain intact."
	)
	_expect(
		multiplayer_button.pressed.is_connected(Callable(main_menu, "_on_multiplayer_pressed")),
		"Existing multiplayer menu connection must remain intact."
	)

	var run_state := root.get_node("RunState") as RunStateStore
	run_state.run_started = false
	run_state.set_selected_character(PlayerCharacterRegistry.WEISHIDAIER_ID)
	var character_overlay := main_menu.get_node_or_null(
		"PlayerCharacterChoiceOverlay"
	) as PlayerCharacterChoiceOverlay
	test_arena_button.pressed.emit()
	await process_frame
	_expect(
		character_overlay != null and character_overlay.is_open(),
		"Test-arena entry must open character selection before starting the run."
	)
	_expect(
		str(main_menu.call("_get_pending_singleplayer_scene_path"))
		== TEST_GRASS_ARENA_SCENE_PATH,
		"Test-arena entry must resolve to test_grass_arena.tscn."
	)
	_expect(not run_state.run_started, "Opening test-arena selection must not start the run yet.")
	if character_overlay == null:
		return
	character_overlay.close()
	await process_frame
	_expect(
		test_arena_button.has_focus(),
		"Closing test-arena character selection must restore focus to its entry button."
	)

	tower_defense_button.pressed.emit()
	await process_frame
	_expect(
		character_overlay != null and character_overlay.is_open(),
		"Tower-defense entry must open character selection before starting the run."
	)
	_expect(
		character_overlay != null
		and character_overlay.selected_character_id == PlayerCharacterRegistry.WEISHIDAIER_ID,
		"Tower-defense selection must open on the character currently stored in RunState."
	)
	_expect(not run_state.run_started, "Opening tower-defense selection must not start the run yet.")
	_expect(current_scene == main_menu, "Tower-defense selection must remain on the main menu.")
	character_overlay.close()
	await process_frame
	_expect(
		tower_defense_button.has_focus(),
		"Closing tower-defense character selection must restore focus to its entry button."
	)
	_expect(not run_state.run_started, "Cancelling tower-defense selection must not start a run.")

	tower_defense_button.pressed.emit()
	await process_frame
	_expect(character_overlay.is_open(), "Tower-defense character selection must reopen after cancellation.")
	character_overlay.call("_select_character", PlayerCharacterRegistry.TIYI_ID)
	_expect(
		run_state.get_selected_character_id() == PlayerCharacterRegistry.WEISHIDAIER_ID
		and not run_state.run_started,
		"Browsing tower-defense characters must not mutate RunState before confirmation."
	)
	character_overlay.confirmation_lock_time_left = 0.0
	character_overlay.call("_confirm_selection")
	var scene_change_deadline := Time.get_ticks_msec() + 30000
	while (
		not (current_scene is GameTowerDefense)
		and Time.get_ticks_msec() < scene_change_deadline
	):
		await process_frame

	_expect(run_state.run_started, "Tower-defense entry must begin a new single-player run.")
	_expect(
		run_state.get_selected_character_id() == PlayerCharacterRegistry.TIYI_ID,
		"Tower-defense entry must persist the character confirmed in the shared selection flow."
	)
	_expect(current_scene is GameTowerDefense, "Tower-defense entry must load game_tower_defense.tscn.")
	if current_scene != null:
		_expect(
			current_scene.scene_file_path == "res://scene/game_tower_defense.tscn",
			"Current scene path must be game_tower_defense.tscn."
		)
	var tower_game := current_scene as GameTowerDefense
	if tower_game != null:
		var preparation_deadline := Time.get_ticks_msec() + 30000
		while (
			not tower_game.is_runtime_preparation_complete()
			and Time.get_ticks_msec() < preparation_deadline
		):
			await process_frame
		_expect(
			tower_game.is_runtime_preparation_complete(),
			"Tower-defense entry must finish staged runtime preparation."
		)
		_expect(
			tower_game.player != null
			and tower_game.player.get_character_id() == PlayerCharacterRegistry.TIYI_ID,
			"Tower-defense game must instantiate Tiyi through the shared single-player character flow."
		)
		_expect(
			tower_game.player is PlayerTiyi
			and (tower_game.player as PlayerTiyi).get_ammo_capacity() == 5,
			"Tower-defense Tiyi must keep the authored five-round sniper magazine."
		)
		var placement_controller := tower_game.get_node_or_null(
			"PlantPlacementController"
		) as PlantPlacementController
		_expect(placement_controller != null, "Tower-defense game must expose PlantPlacementController.")
		if placement_controller != null:
			_expect(
				placement_controller.is_processing_unhandled_input(),
				"PlantPlacementController must receive unhandled input in single-player tower defense."
			)
			var plant_press := InputEventAction.new()
			plant_press.action = &"plant"
			plant_press.pressed = true
			Input.parse_input_event(plant_press)
			for _input_frame in range(2):
				await process_frame
			_expect(placement_controller.is_selecting(), "plant action must enter SELECTING state.")
			_expect(
				placement_controller.selection_hud.is_open(),
				"plant action must visibly open the plant selection HUD."
			)
			var plant_release := InputEventAction.new()
			plant_release.action = &"plant"
			plant_release.pressed = false
			Input.parse_input_event(plant_release)
			Input.flush_buffered_events()
			placement_controller.cancel_placement()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
