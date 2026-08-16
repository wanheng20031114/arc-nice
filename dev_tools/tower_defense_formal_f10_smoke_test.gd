extends SceneTree

const GAME_SCENE := preload(
	"res://scene/game_modes/tower_defense/tower_defense_game.tscn"
)

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var run_state := root.get_node("RunState") as RunStateStore
	run_state.begin_new_run(&"weishidaier")
	var game := GAME_SCENE.instantiate() as TowerDefenseGame
	game.auto_start_waves = false
	root.add_child(game)
	current_scene = game
	await _wait_frames(3)

	var controller := game.plant_placement_controller
	var window := game.debug_collectible_window
	_expect(
		not game.sandbox_free_building_enabled
		and not controller.free_placement_enabled
		and game.tower_multiplayer_mode_adapter.allows_debug_collectible_grants(),
		(
			"Formal tower defense must keep sandbox placement disabled while "
			+ "debug collectible grants remain available."
		)
	)
	await _test_physical_f10_flow(game, run_state, controller, window)

	if window != null:
		window.close()
	controller.cancel_placement()
	_stop_audio_players(game)
	current_scene = null
	game.queue_free()
	await _wait_until_freed(game)
	if failures.is_empty():
		print("TOWER_DEFENSE_FORMAL_F10_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_physical_f10_flow(
	game: TowerDefenseGame,
	run_state: RunStateStore,
	controller: PlantPlacementController,
	window: DebugCollectibleWindow
) -> void:
	_expect(window != null, "Formal tower defense must expose the debug window.")
	if window == null:
		return

	await _send_key(KEY_F10)
	_expect(
		window.is_open()
		and not controller.is_processing_unhandled_input()
		and game.player.controls_locked,
		"Physical F10 must open the collectible modal and lock gameplay input."
	)
	_expect(
		window.collectible_list.get_item_count() > 0,
		"The F10 collectible modal must expose at least one selectable item."
	)
	if not window.is_open() or window.collectible_list.get_item_count() <= 0:
		window.close()
		return

	var item_index := 0
	var config_path := str(window.collectible_list.get_item_metadata(item_index))
	var item := LuoxiMerchant.get_collectible_for_path(config_path)
	_expect(
		item != null,
		"F10 catalog metadata must resolve to a trusted collectible."
	)
	if item == null:
		window.close()
		return
	var total_before := run_state.get_inventory_item_total(item)
	window.collectible_list.item_activated.emit(item_index)
	await process_frame
	_expect(
		run_state.get_inventory_item_total(item) == total_before + 1,
		"Activating an F10 catalog item must grant exactly one copy."
	)

	await _send_key(KEY_F10)
	_expect(
		not window.is_open()
		and controller.is_processing_unhandled_input()
		and not game.player.controls_locked
		and not controller.free_placement_enabled,
		(
			"Physical F10 must close the modal, restore gameplay input, and "
			+ "leave sandbox placement disabled."
		)
	)


func _send_key(physical_keycode: Key) -> void:
	var press := InputEventKey.new()
	press.physical_keycode = physical_keycode
	press.pressed = true
	Input.parse_input_event(press)
	await process_frame
	var release := InputEventKey.new()
	release.physical_keycode = physical_keycode
	release.pressed = false
	Input.parse_input_event(release)
	await process_frame


func _wait_frames(frame_count: int) -> void:
	for _frame in frame_count:
		await process_frame
		await physics_frame


func _wait_until_freed(node: Node) -> void:
	for _frame in 10:
		if not is_instance_valid(node):
			return
		await process_frame
		await physics_frame


func _stop_audio_players(node: Node) -> void:
	if node is AudioStreamPlayer or node is AudioStreamPlayer2D:
		node.stop()
	for child in node.get_children():
		_stop_audio_players(child)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
