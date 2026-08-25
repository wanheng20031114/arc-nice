extends SceneTree

const MAIN_MENU_SCENE := preload("res://scene/main_menu.tscn")
const ENCYCLOPEDIA_SCENE_PATH := (
	"res://scene/encyclopedia/encyclopedia_screen.tscn"
)
const LOAD_TIMEOUT_MSEC := 30000

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	await _test_exit_during_pending_request()
	await _test_preload_feedback_and_transition()
	await _cleanup_current_scene()

	if failures.is_empty():
		print("MAIN_MENU_ENCYCLOPEDIA_PRELOAD_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_exit_during_pending_request() -> void:
	var main_menu := MAIN_MENU_SCENE.instantiate() as MainMenu
	root.add_child(main_menu)
	current_scene = main_menu
	_expect(
		int(main_menu.get("_encyclopedia_load_state"))
		== MainMenu.EncyclopediaLoadState.IDLE,
		"Encyclopedia preload must not start synchronously inside MainMenu._ready()."
	)

	var cold_click_started_usec := Time.get_ticks_usec()
	main_menu.call("_on_encyclopedia_pressed")
	var cold_click_handler_msec := (
		float(Time.get_ticks_usec() - cold_click_started_usec) / 1000.0
	)
	var feedback := main_menu.get_node_or_null(
		"EncyclopediaLoadingFeedback"
	) as PanelContainer
	var status_label := main_menu.get_node_or_null(
		"EncyclopediaLoadingFeedback/Status"
	) as Label
	var encyclopedia_button := main_menu.get_node_or_null(
		"MenuCenter/MenuPanel/MarginContainer/MenuStack/Encyclopedia"
	) as Button
	_expect(feedback != null and feedback.visible, "Cold entry must show loading feedback immediately.")
	_expect(
		status_label != null and status_label.text == "正在整理图鉴…",
		"Cold entry loading feedback text is incorrect."
	)
	_expect(
		encyclopedia_button != null and not encyclopedia_button.disabled,
		"Encyclopedia loading must preserve keyboard and gamepad focusability."
	)
	_expect(
		int(main_menu.get("_encyclopedia_load_state"))
		== MainMenu.EncyclopediaLoadState.LOADING,
		"Cold entry must begin a threaded preload request without a synchronous scene change."
	)
	_expect(
		cold_click_handler_msec < 50.0,
		"Cold encyclopedia click must return within 50 ms; got %.3f ms."
		% cold_click_handler_msec
	)

	current_scene = null
	main_menu.queue_free()
	for _frame in range(3):
		await process_frame
	_expect(
		not is_instance_valid(main_menu),
		"Leaving the main menu while its preload is pending must release the menu safely."
	)


func _test_preload_feedback_and_transition() -> void:
	var scene_deadline := Time.get_ticks_msec() + LOAD_TIMEOUT_MSEC
	while (
		ResourceLoader.load_threaded_get_status(ENCYCLOPEDIA_SCENE_PATH)
		== ResourceLoader.THREAD_LOAD_IN_PROGRESS
		and Time.get_ticks_msec() < scene_deadline
	):
		await process_frame
	_expect(
		ResourceLoader.load_threaded_get_status(ENCYCLOPEDIA_SCENE_PATH)
		== ResourceLoader.THREAD_LOAD_LOADED,
		"The first menu's background PackedScene request did not finish in time."
	)
	_expect(
		not CollectibleRegistry.is_cache_ready(),
		"Exiting before scene retrieval must leave the collectible cache cold."
	)

	var main_menu := MAIN_MENU_SCENE.instantiate() as MainMenu
	root.add_child(main_menu)
	current_scene = main_menu
	var encyclopedia_button := main_menu.get_node(
		"MenuCenter/MenuPanel/MarginContainer/MenuStack/Encyclopedia"
	) as Button
	var feedback := main_menu.get_node(
		"EncyclopediaLoadingFeedback"
	) as PanelContainer
	main_menu.call("_ensure_encyclopedia_preload_started")
	_expect(
		int(main_menu.get("_encyclopedia_load_state"))
		== MainMenu.EncyclopediaLoadState.LOADING
		and main_menu.get("_encyclopedia_scene") is PackedScene
		and not CollectibleRegistry.is_cache_ready(),
		"A cached PackedScene with a cold collectible registry must continue warming in LOADING."
	)
	_expect(
		int(main_menu.get("_collectible_next_request_index")) > 0
		and main_menu.is_processing(),
		"Cached-scene entry must start collectible requests and keep polling enabled."
	)

	# Exercise feedback, duplicate activation and controller cancel deterministically
	# while the real background request is allowed to continue globally.
	main_menu.set_process(false)
	encyclopedia_button.grab_focus()
	main_menu.call("_on_encyclopedia_pressed")
	var first_feedback_tween: Tween = main_menu.get("_encyclopedia_feedback_tween") as Tween
	main_menu.call("_on_encyclopedia_pressed")
	_expect(
		main_menu.get("_encyclopedia_feedback_tween") == first_feedback_tween,
		"Repeated activation while loading must not restart feedback or queue another entry."
	)
	_expect(
		bool(main_menu.get("_encyclopedia_open_requested")),
		"Loading activation must retain a single pending entry intent."
	)

	var cancel_event := InputEventAction.new()
	cancel_event.action = &"quit"
	cancel_event.pressed = true
	main_menu.call("_unhandled_input", cancel_event)
	_expect(
		not bool(main_menu.get("_encyclopedia_open_requested")) and not feedback.visible,
		"The quit action must dismiss a pending encyclopedia entry without cancelling preloading."
	)
	_expect(
		encyclopedia_button.has_focus(),
		"The quit action must return focus to the Encyclopedia button."
	)

	main_menu.set_process(true)
	var deadline := Time.get_ticks_msec() + LOAD_TIMEOUT_MSEC
	while (
		int(main_menu.get("_encyclopedia_load_state"))
		in [
			MainMenu.EncyclopediaLoadState.IDLE,
			MainMenu.EncyclopediaLoadState.LOADING,
		]
		and Time.get_ticks_msec() < deadline
	):
		await process_frame
	_expect(
		int(main_menu.get("_encyclopedia_load_state"))
		== MainMenu.EncyclopediaLoadState.LOADED,
		"Background preload did not finish within the smoke-test timeout."
	)
	_expect(
		main_menu.get("_encyclopedia_scene") is PackedScene,
		"A completed preload must retain the loaded PackedScene for non-blocking entry."
	)
	_expect(
		CollectibleRegistry.is_cache_ready(),
		"The overall LOADED state must wait until every collectible config is cached."
	)
	var collectible_paths := CollectibleRegistry.get_config_paths()
	_expect(
		collectible_paths.size() == 125
		and CollectibleRegistry.get_all().size() == collectible_paths.size(),
		"The completed warmup must cache all 125 registered collectible configs."
	)
	if (
		int(main_menu.get("_encyclopedia_load_state"))
		!= MainMenu.EncyclopediaLoadState.LOADED
	):
		return

	# A loaded click still enters through a deferred call. Controller cancel in
	# that same frame must revoke the intent before the scene can change.
	encyclopedia_button.pressed.emit()
	_expect(
		bool(main_menu.get("_encyclopedia_open_requested")),
		"A loaded activation must retain its intent until the deferred scene change."
	)
	main_menu.call("_unhandled_input", cancel_event)
	await process_frame
	_expect(
		current_scene == main_menu
		and int(main_menu.get("_encyclopedia_load_state"))
		== MainMenu.EncyclopediaLoadState.LOADED,
		"A same-frame quit action must revoke a deferred loaded-state entry."
	)
	_expect(
		not bool(main_menu.get("_encyclopedia_open_requested"))
		and encyclopedia_button.has_focus(),
		"Cancelling a loaded-state entry must clear its intent and preserve focus."
	)

	encyclopedia_button.pressed.emit()
	for _frame in range(3):
		await process_frame
	_expect(
		current_scene != null
		and current_scene != main_menu
		and current_scene.scene_file_path == ENCYCLOPEDIA_SCENE_PATH,
		"A loaded encyclopedia must enter through change_scene_to_packed()."
	)
	var screen := current_scene as EncyclopediaScreen
	if screen != null:
		var collectible_switch_started_usec := Time.get_ticks_usec()
		screen.call("_apply_section", CodexSection.COLLECTIBLE)
		var collectible_switch_msec := (
			float(Time.get_ticks_usec() - collectible_switch_started_usec) / 1000.0
		)
		_expect(
			collectible_switch_msec < 50.0,
			"A warmed collectible section switch must return within 50 ms; got %.3f ms."
			% collectible_switch_msec
		)
		await _test_encyclopedia_escape_return(screen)


func _test_encyclopedia_escape_return(screen: EncyclopediaScreen) -> void:
	var escape_event := InputEventKey.new()
	escape_event.keycode = KEY_ESCAPE
	escape_event.physical_keycode = KEY_ESCAPE
	escape_event.pressed = true
	Input.parse_input_event(escape_event)
	for _frame in range(3):
		await process_frame
	escape_event.pressed = false
	Input.parse_input_event(escape_event)
	var returned_menu := current_scene as MainMenu
	_expect(
		returned_menu != null,
		"Physical Escape from the encyclopedia must return to the main menu."
	)
	if returned_menu == null:
		return
	var encyclopedia_button := returned_menu.get_node_or_null(
		"MenuCenter/MenuPanel/MarginContainer/MenuStack/Encyclopedia"
	) as Button
	_expect(
		encyclopedia_button != null and encyclopedia_button.has_focus(),
		"Returning from the encyclopedia must restore focus to its main-menu button."
	)


func _cleanup_current_scene() -> void:
	var active_scene := current_scene
	current_scene = null
	if active_scene != null and is_instance_valid(active_scene):
		active_scene.queue_free()
	for _frame in range(4):
		await process_frame


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
