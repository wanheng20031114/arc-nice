extends SceneTree

const GAME_SCENE_PATH := "res://scene/game.tscn"


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var start_msec := Time.get_ticks_msec()
	var packed := load(GAME_SCENE_PATH) as PackedScene
	var loaded_msec := Time.get_ticks_msec()
	if packed == null:
		push_error("Failed to load %s" % GAME_SCENE_PATH)
		quit(1)
		return

	var game := packed.instantiate() as Game
	var instantiated_msec := Time.get_ticks_msec()
	if game == null:
		push_error("Failed to instantiate Game.")
		quit(1)
		return

	game.auto_start_waves = false
	root.add_child(game)
	current_scene = game
	await process_frame
	await physics_frame
	var ready_msec := Time.get_ticks_msec()

	print("SINGLEPLAYER_STARTUP_PROFILE")
	print("load_game_scene_ms=%d" % (loaded_msec - start_msec))
	print("instantiate_game_ms=%d" % (instantiated_msec - loaded_msec))
	print("ready_first_frame_ms=%d" % (ready_msec - instantiated_msec))
	print("total_ms=%d" % (ready_msec - start_msec))

	game.queue_free()
	for _frame_index in range(3):
		await process_frame
		await physics_frame
	quit()
