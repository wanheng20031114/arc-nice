extends SceneTree

const MAIN_MENU_SCENE := preload("res://scene/main_menu.tscn")
const GAME_TOWER_DEFENSE_SCENE := preload("res://scene/game_tower_defense.tscn")

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
	tower_defense_button.pressed.emit()
	for _frame in range(3):
		await process_frame

	_expect(run_state.run_started, "Tower-defense entry must begin a new single-player run.")
	_expect(current_scene is GameTowerDefense, "Tower-defense entry must load game_tower_defense.tscn.")
	if current_scene != null:
		_expect(
			current_scene.scene_file_path == "res://scene/game_tower_defense.tscn",
			"Current scene path must be game_tower_defense.tscn."
		)
	var tower_game := current_scene as GameTowerDefense
	if tower_game != null:
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
