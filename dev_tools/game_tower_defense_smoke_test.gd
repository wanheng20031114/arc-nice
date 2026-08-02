extends SceneTree

const MAIN_MENU_SCENE := preload("res://scene/main_menu.tscn")
const GAME_TOWER_DEFENSE_SCENE := preload("res://scene/game_tower_defense.tscn")
const TEST_GRASS_ARENA_SCENE_PATH := "res://scene/test_arena/test_grass_arena.tscn"
const TEST_GRASS_ARENA_P1B_SCENE_PATH := (
	"res://scene/test_arena/test_grass_arena_p1b.tscn"
)
const TEST_GRASS_ARENA_P2_SCENE_PATH := (
	"res://scene/test_arena/test_grass_arena_p2.tscn"
)

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
	var encyclopedia_button := main_menu.get_node_or_null(
		"MenuCenter/MenuPanel/MarginContainer/MenuStack/Encyclopedia"
	) as Button
	var settings_button := main_menu.get_node(
		"MenuCenter/MenuPanel/MarginContainer/MenuStack/Settings"
	) as Button
	_expect(encyclopedia_button != null, "Main menu must include the Encyclopedia button.")
	if encyclopedia_button == null:
		return
	_expect(encyclopedia_button.text == "图鉴", "Encyclopedia button text is incorrect.")
	_expect(
		encyclopedia_button.pressed.is_connected(
			Callable(main_menu, "_on_encyclopedia_pressed")
		),
		"Encyclopedia button must be connected to its menu handler."
	)
	_expect(
		multiplayer_button.get_index() < encyclopedia_button.get_index()
		and encyclopedia_button.get_index() < settings_button.get_index(),
		"Encyclopedia must sit between Multiplayer and Settings."
	)
	MainMenu.request_focus_after_return(MainMenu.FOCUS_ENCYCLOPEDIA)
	main_menu.call("_apply_requested_focus")
	_expect(
		encyclopedia_button.has_focus(),
		"Returning from the encyclopedia must restore focus to its menu button."
	)

	var run_state := root.get_node("RunState") as RunStateStore
	run_state.run_started = false
	run_state.set_selected_character(PlayerCharacterRegistry.WEISHIDAIER_ID)
	var character_overlay := main_menu.get_node_or_null(
		"PlayerCharacterChoiceOverlay"
	) as PlayerCharacterChoiceOverlay
	var test_choice_overlay := main_menu.get_node_or_null(
		"TestArenaChoiceOverlay"
	) as TestArenaChoiceOverlay
	_expect(
		test_choice_overlay != null
		and test_choice_overlay.arena_selected.is_connected(
			Callable(main_menu, "_on_test_arena_selected")
		),
		"Main menu must own and connect the P1A/P1B/P2/P3 test-arena selector."
	)
	if test_choice_overlay == null or character_overlay == null:
		return
	test_arena_button.pressed.emit()
	await process_frame
	_expect(
		test_choice_overlay.is_open() and not character_overlay.is_open(),
		"Test-arena entry must open scene selection before character selection."
	)
	var p1a_button := test_choice_overlay.get_node(
		"Root/Center/Panel/PanelMargin/Layout/Tabs/P1A/PageMargin/Content/EnterButton"
	) as Button
	var p1b_button := test_choice_overlay.get_node(
		"Root/Center/Panel/PanelMargin/Layout/Tabs/P1B/PageMargin/Content/EnterButton"
	) as Button
	var p2_button := test_choice_overlay.get_node(
		"Root/Center/Panel/PanelMargin/Layout/Tabs/P2/PageMargin/Content/EnterButton"
	) as Button
	_expect(
		p1a_button.text == "进入 P1A 史莱姆测试"
		and p1b_button.text == "进入 P1B 机器人测试"
		and p2_button.text == "进入 P2 单日流程",
		"Test selector must expose authored P1A, P1B and P2 actions."
	)
	p1a_button.pressed.emit()
	await process_frame
	_expect(
		not test_choice_overlay.is_open()
		and character_overlay.is_open()
		and str(main_menu.call("_get_pending_singleplayer_scene_path"))
		== TEST_GRASS_ARENA_SCENE_PATH,
		"Selecting P1A must continue to character selection and preserve the original arena."
	)
	_expect(not run_state.run_started, "Selecting P1A must not start the run before confirmation.")
	character_overlay.close()
	await process_frame
	_expect(
		test_choice_overlay.is_open(),
		"Backing out of test-arena character selection must return to the scene selector."
	)
	test_choice_overlay.close()
	await process_frame
	_expect(
		test_arena_button.has_focus(),
		"Closing the scene selector must restore focus to the test-arena entry."
	)

	test_arena_button.pressed.emit()
	await process_frame
	var tabs := test_choice_overlay.tabs
	tabs.current_tab = TestArenaChoiceOverlay.P1B_TAB_INDEX
	await process_frame
	p1b_button.pressed.emit()
	await process_frame
	_expect(
		character_overlay.is_open()
		and str(main_menu.call("_get_pending_singleplayer_scene_path"))
		== TEST_GRASS_ARENA_P1B_SCENE_PATH,
		"Selecting P1B must route character confirmation to its independent arena."
	)
	_expect(not run_state.run_started, "Selecting P1B must not start the run before confirmation.")
	character_overlay.close()
	await process_frame
	_expect(
		test_choice_overlay.is_open()
		and test_choice_overlay.tabs.current_tab == TestArenaChoiceOverlay.P1B_TAB_INDEX,
		"Backing out of P1B character selection must restore the P1B tab."
	)
	test_choice_overlay.close()
	await process_frame

	test_arena_button.pressed.emit()
	await process_frame
	tabs.current_tab = TestArenaChoiceOverlay.P2_TAB_INDEX
	await process_frame
	p2_button.pressed.emit()
	await process_frame
	_expect(
		character_overlay.is_open()
		and str(main_menu.call("_get_pending_singleplayer_scene_path"))
		== TEST_GRASS_ARENA_P2_SCENE_PATH,
		"Selecting P2 must route character confirmation to test_grass_arena_p2.tscn."
	)
	_expect(not run_state.run_started, "Selecting P2 must not start the run before character confirmation.")
	character_overlay.close()
	await process_frame
	_expect(
		test_choice_overlay.is_open()
		and test_choice_overlay.tabs.current_tab == TestArenaChoiceOverlay.P2_TAB_INDEX,
		"Backing out of P2 character selection must restore the P2 tab."
	)
	test_choice_overlay.close()
	await process_frame
	_expect(
		str(main_menu.call("_get_pending_singleplayer_scene_path"))
		== TEST_GRASS_ARENA_P2_SCENE_PATH,
		"The selected P2 destination must remain stable after returning to the menu."
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
