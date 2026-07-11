extends SceneTree

const GAME_SCENE := preload("res://scene/game.tscn")
const PLAYER_SCENE := preload("res://scene/player/weishidaier/player_weishidaier.tscn")
const APPLE_COLLECTIBLE := preload("res://resources/config/collectibles/collectible_apple.tres")

var failures: Array[String] = []
var test_root: Node2D


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	test_root = Node2D.new()
	test_root.name = "DebugShortcutsSmokeTest"
	root.add_child(test_root)
	current_scene = test_root

	_test_input_map()
	await _test_cheat_xirang_action()
	await _test_debug_collectible_window()

	test_root.queue_free()
	await process_frame
	await physics_frame
	for _cleanup_frame in range(4):
		await process_frame
		await physics_frame

	if failures.is_empty():
		print("DEBUG_SHORTCUTS_SMOKE_TEST_OK")
		quit()
		return

	for failure in failures:
		push_error(failure)
	quit(1)


func _test_input_map() -> void:
	_expect(InputMap.has_action("cheat_xirang"), "Input map must include cheat_xirang.")
	_expect(InputMap.has_action("cheat_collectibles"), "Input map must include cheat_collectibles.")
	_expect(InputMap.has_action("full_screen"), "Input map must include full_screen.")


func _test_cheat_xirang_action() -> void:
	var player := PLAYER_SCENE.instantiate() as Player
	test_root.add_child(player)
	await process_frame
	await physics_frame

	var event := _make_action("cheat_xirang")
	player._unhandled_input(event)
	_expect(player.current_xirang == 1000, "cheat_xirang must grant 1000 xirang.")

	player.queue_free()
	await process_frame
	await physics_frame


func _test_debug_collectible_window() -> void:
	var run_state := root.get_node("RunState") as RunStateStore
	run_state.begin_new_run()

	var game := GAME_SCENE.instantiate() as Game
	game.set("auto_start_waves", false)
	test_root.add_child(game)
	await process_frame
	await physics_frame
	_expect(game.player.current_xirang == Game.INITIAL_PLAYER_XIRANG, "Game player must start with initial xirang.")

	var window := game.get_node_or_null("SettingsLayer/DebugCollectibleWindow") as DebugCollectibleWindow
	_expect(window != null, "Game must include DebugCollectibleWindow under SettingsLayer.")
	if window == null:
		game.queue_free()
		return

	game._unhandled_input(_make_action("cheat_collectibles"))
	_expect(window.is_open(), "cheat_collectibles must open the debug collectible window.")
	_expect(game.player.controls_locked, "Opening the debug collectible window must lock player controls.")
	_expect(window.collectible_list.get_item_count() == LuoxiMerchant.get_collectible_pool().size(), "Debug window must list every collectible.")

	window.collectible_requested.emit(APPLE_COLLECTIBLE.resource_path)
	await process_frame
	_expect(run_state.get_item(0) == APPLE_COLLECTIBLE, "Debug collectible request must add the selected collectible to inventory.")
	_expect(not game.has_luoxi_collectible_claimed(0), "Debug collectible grant must not spend Luoxi's round claim.")

	window.close()
	await process_frame
	_expect(not game.player.controls_locked, "Closing the debug collectible window must unlock player controls when no other modal is open.")

	_stop_audio_players(game)
	game.queue_free()
	await process_frame
	await physics_frame


func _make_action(action_name: String) -> InputEventAction:
	var event := InputEventAction.new()
	event.action = action_name
	event.pressed = true
	return event


func _stop_audio_players(root_node: Node) -> void:
	for child in root_node.get_children():
		if child is AudioStreamPlayer or child is AudioStreamPlayer2D:
			child.stop()
		_stop_audio_players(child)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
