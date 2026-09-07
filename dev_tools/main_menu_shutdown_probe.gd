extends SceneTree

var _route := "button"
var _phase := "scene"
var _deadline_msec := 0

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--route="):
			_route = arg.trim_prefix("--route=")
		elif arg.begins_with("--phase="):
			_phase = arg.trim_prefix("--phase=")
	_deadline_msec = Time.get_ticks_msec() + 30000
	_run.call_deferred()

func _process(_delta: float) -> bool:
	if Time.get_ticks_msec() > _deadline_msec:
		push_error("Menu shutdown probe exceeded 30 seconds")
		quit(2)
	return false

func _run() -> void:
	var menu: Node = load("res://scene/main_menu.tscn").instantiate()
	root.add_child(menu)
	current_scene = menu
	while int(menu.get("_encyclopedia_load_state")) == 0:
		await process_frame
	if _phase == "collectibles":
		while (menu.get("_collectible_loading_paths") as Dictionary).is_empty():
			await process_frame
	if _route in ["loading-window", "prewarm-window"]:
		var loader := root.get_node("GameLoadCoordinator")
		root.get_node("RunState").call("begin_new_run", &"weishidaier", false)
		loader.call("begin_singleplayer", "res://scene/game_modes/tower_defense/tower_defense_game.tscn")
		while (loader.get("_active_attempt").get("started_paths") as Dictionary).is_empty():
			await process_frame
		if _route == "prewarm-window":
			while current_scene == null or current_scene.scene_file_path != "res://scene/game_modes/tower_defense/tower_defense_game.tscn":
				await process_frame
			print("MENU_SHUTDOWN runtime_preparation_state=", current_scene.call("get_runtime_preparation_state"))
	print("MENU_SHUTDOWN route=", _route, " phase=", _phase, " scene_thread_status=",
		ResourceLoader.load_threaded_get_status("res://scene/encyclopedia/encyclopedia_screen.tscn"))
	if _route in ["window", "loading-window", "prewarm-window"]:
		root.propagate_notification(Node.NOTIFICATION_WM_CLOSE_REQUEST)
	else:
		menu.call("_on_quit_pressed")
