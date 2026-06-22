extends SceneTree

const MAIN_MENU_SCENE := preload("res://scene/main_menu.tscn")
const GAME_SCENE := preload("res://scene/game.tscn")
const SETTINGS_MANAGER_SCRIPT := preload("res://scene/settings/settings_manager.gd")

var failures: Array[String] = []
var _had_settings_config := false
var _settings_config_backup := ""


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	await process_frame
	_ensure_user_settings()
	await process_frame
	_backup_settings_config()
	_test_project_resolution_defaults()
	_test_user_settings_singleton()
	_test_config_file_reset()
	await _test_settings_panel_scene()
	await _test_audio_bus_assignment()
	_test_hotkey_defaults_and_event_helpers()
	_restore_settings_config()

	if failures.is_empty():
		print("SETTINGS_SMOKE_TEST_OK")
		quit(0)
	else:
		for failure in failures:
			push_error(failure)
		quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _ensure_user_settings() -> Node:
	var existing := root.get_node_or_null("UserSettings")
	if existing != null:
		return existing
	var manager := SETTINGS_MANAGER_SCRIPT.new()
	manager.name = "UserSettings"
	root.add_child(manager)
	return manager


func _settings() -> Node:
	return root.get_node("UserSettings")


func _backup_settings_config() -> void:
	var config_path := str(_settings().call("get_config_path"))
	_had_settings_config = FileAccess.file_exists(config_path)
	_settings_config_backup = FileAccess.get_file_as_string(config_path) if _had_settings_config else ""


func _restore_settings_config() -> void:
	var config_path := str(_settings().call("get_config_path"))
	if _had_settings_config:
		var file := FileAccess.open(config_path, FileAccess.WRITE)
		_expect(file != null, "Settings config backup must be restorable.")
		if file != null:
			file.store_string(_settings_config_backup)
			file.close()
		return
	if FileAccess.file_exists(config_path):
		var dir := DirAccess.open(config_path.get_base_dir())
		_expect(dir != null, "Settings config directory must be available for cleanup.")
		if dir != null:
			_expect(dir.remove(config_path.get_file()) == OK, "Temporary settings config must be removed.")


func _test_project_resolution_defaults() -> void:
	_expect(
		int(ProjectSettings.get_setting("display/window/size/viewport_width")) == 1152,
		"Project viewport width must keep the original 1152 design size."
	)
	_expect(
		int(ProjectSettings.get_setting("display/window/size/viewport_height")) == 648,
		"Project viewport height must keep the original 648 design size."
	)
	_expect(
		str(ProjectSettings.get_setting("display/window/stretch/mode")) == "canvas_items",
		"Project stretch mode must use canvas_items."
	)
	_expect(
		str(ProjectSettings.get_setting("display/window/stretch/aspect")) == "expand",
		"Project stretch aspect must use expand."
	)


func _test_user_settings_singleton() -> void:
	var settings := _settings()
	_expect(settings != null, "UserSettings singleton must be available.")
	_expect(AudioServer.get_bus_index("Music") >= 0, "Music audio bus must exist.")
	_expect(AudioServer.get_bus_index("SFX") >= 0, "SFX audio bus must exist.")
	var options: Array = settings.call("get_resolution_options")
	_expect(not options.is_empty(), "Resolution options must be available.")
	_expect(
		options.size() == SETTINGS_MANAGER_SCRIPT.RESOLUTION_OPTIONS.size(),
		"All configured resolution presets must be exposed."
	)
	_expect(str(options[0].get("id", "")) == "1280x720", "Default resolution option must be 1280x720.")
	var simulated_1080_options: Array = settings.call(
		"get_windowed_resolution_options_for_size",
		Vector2i(1920, 1080)
	)
	_expect(
		simulated_1080_options.size() == SETTINGS_MANAGER_SCRIPT.RESOLUTION_OPTIONS.size(),
		"Resolution presets must not be filtered by current screen size."
	)
	_expect(
		_resolution_options_contain(simulated_1080_options, "1366x768"),
		"1366x768 preset must be available."
	)
	_expect(
		_resolution_options_contain(simulated_1080_options, "3440x1440"),
		"UWQHD preset must be available."
	)
	_expect(
		_resolution_options_contain(simulated_1080_options, "3840x2160"),
		"4K preset must remain selectable."
	)
	_expect(settings.has_method("set_fullscreen_enabled"), "Fullscreen setting API must exist.")
	_expect(settings.has_method("get_current_screen_size"), "Fullscreen target screen-size API must exist.")
	_expect(settings.has_method("reset_all_settings"), "Full settings reset API must exist.")
	_expect(str(settings.call("get_config_path")) == "user://settings.cfg", "Settings config path must be stable.")
	_expect(settings.has_method("get_config_file_system_path"), "Settings file system path API must exist.")
	_expect(
		str(settings.call("get_config_file_system_path")).ends_with("settings.cfg"),
		"Settings file system path must point to settings.cfg."
	)
	_test_resolution_scaling_behavior()


func _test_config_file_reset() -> void:
	var settings := _settings()
	var config_path := str(settings.call("get_config_path"))
	settings.call("set_volume_percent", &"master", 37.0)
	settings.call("set_volume_percent", &"music", 38.0)
	settings.call("set_volume_percent", &"sfx", 39.0)
	_expect(FileAccess.file_exists(config_path), "Changing settings must create settings config file.")
	settings.call("reset_all_settings")
	_expect(not FileAccess.file_exists(config_path), "Reset all settings must remove settings config file.")
	_expect(_float_close(float(settings.call("get_volume_percent", &"master")), 100.0), "Master volume must reset to default.")
	_expect(_float_close(float(settings.call("get_volume_percent", &"music")), 70.0), "Music volume must reset to default.")
	_expect(_float_close(float(settings.call("get_volume_percent", &"sfx")), 100.0), "SFX volume must reset to default.")
	_expect(not bool(settings.call("is_fullscreen_enabled")), "Fullscreen must reset to default.")


func _test_resolution_scaling_behavior() -> void:
	var settings := _settings()
	settings.call("set_fullscreen_enabled", false)
	var target_index := _resolution_option_index("1920x1080")
	_expect(target_index >= 0, "1920x1080 preset must exist for scaling test.")
	if target_index < 0:
		return
	settings.call("set_resolution_index", target_index)
	var window := root
	_expect(window.size == Vector2i(1920, 1080), "Applying 1920x1080 must resize the window.")
	_expect(
		window.content_scale_mode == Window.CONTENT_SCALE_MODE_CANVAS_ITEMS,
		"Window content scale mode must use canvas_items."
	)
	_expect(
		window.content_scale_aspect == Window.CONTENT_SCALE_ASPECT_EXPAND,
		"Window content scale aspect must use expand."
	)
	_expect(
		window.content_scale_size == SETTINGS_MANAGER_SCRIPT.BASE_CONTENT_SCALE_SIZE,
		"Changing resolution must keep the base canvas size so content scales with the window."
	)
	settings.call("set_resolution_index", 0)


func _test_settings_panel_scene() -> void:
	var menu := MAIN_MENU_SCENE.instantiate()
	_expect(menu != null, "Main menu scene must instantiate.")
	if menu == null:
		return
	root.add_child(menu)
	await process_frame

	var panel := menu.get_node_or_null("SettingsPanel") as Control
	_expect(panel != null, "Main menu must contain SettingsPanel.")
	if panel != null:
		panel.call("open")
		await process_frame
		_expect(panel.visible, "Settings panel must become visible after open().")
		var resolution_option := panel.get_node_or_null(
			"Center/Panel/Margin/Layout/Scroll/Content/DisplaySection/ResolutionRow/ResolutionOption"
		) as OptionButton
		var fullscreen_check := panel.get_node_or_null(
			"Center/Panel/Margin/Layout/Scroll/Content/DisplaySection/FullscreenRow/FullscreenCheck"
		) as CheckButton
		var config_path_label := panel.get_node_or_null(
			"Center/Panel/Margin/Layout/Scroll/Content/DisplaySection/ConfigPathLabel"
		) as Label
		var music_slider := panel.get_node_or_null(
			"Center/Panel/Margin/Layout/Scroll/Content/AudioSection/MusicRow/MusicSlider"
		) as HSlider
		var music_value := panel.get_node_or_null(
			"Center/Panel/Margin/Layout/Scroll/Content/AudioSection/MusicRow/MusicValue"
		) as Label
		var hotkey_hint := panel.get_node_or_null(
			"Center/Panel/Margin/Layout/Scroll/Content/HotkeySection/Hint"
		) as Label
		var settings_panel := panel.get_node_or_null("Center/Panel") as PanelContainer
		var settings_scroll := panel.get_node_or_null("Center/Panel/Margin/Layout/Scroll") as ScrollContainer
		var reset_settings_button := panel.get_node_or_null(
			"Center/Panel/Margin/Layout/Footer/ResetSettingsButton"
		) as Button
		_expect(settings_panel != null, "Settings panel outer container must exist.")
		_expect(settings_scroll != null, "Settings panel scroll container must exist.")
		_expect(fullscreen_check != null, "Fullscreen CheckButton must exist.")
		_expect(resolution_option != null, "Resolution OptionButton must exist.")
		_expect(config_path_label != null, "Settings panel must show config path label.")
		_expect(music_slider != null, "Settings panel must expose MusicSlider.")
		_expect(music_value != null, "Settings panel must expose MusicValue.")
		_expect(hotkey_hint != null, "Settings panel must contain the hotkey hint label for transient capture messages.")
		_expect(reset_settings_button != null, "Settings panel must expose full reset button.")
		if settings_panel != null:
			var panel_rect := settings_panel.get_global_rect()
			var viewport_size := Vector2(
				float(ProjectSettings.get_setting("display/window/size/viewport_width")),
				float(ProjectSettings.get_setting("display/window/size/viewport_height"))
			)
			_expect(
				panel_rect.position.x >= 0.0
					and panel_rect.position.y >= 0.0
					and panel_rect.end.x <= viewport_size.x + 0.5
					and panel_rect.end.y <= viewport_size.y + 0.5,
				"Settings panel outer border must fit inside the design viewport."
			)
		if settings_scroll != null:
			_expect(
				settings_scroll.custom_minimum_size.y <= 454.0,
				"Settings scroll area must leave room for the outer bottom border and footer."
			)
		if fullscreen_check != null:
			var checked_icon := fullscreen_check.get_theme_icon(&"checked")
			var unchecked_icon := fullscreen_check.get_theme_icon(&"unchecked")
			_expect(
				checked_icon != null and checked_icon.resource_path.ends_with("settings_switch_checked.png"),
				"Fullscreen CheckButton must use the high-contrast checked switch icon."
			)
			_expect(
				unchecked_icon != null and unchecked_icon.resource_path.ends_with("settings_switch_unchecked.png"),
				"Fullscreen CheckButton must use the high-contrast unchecked switch icon."
			)
		if resolution_option != null:
			_expect(
				resolution_option.item_count == SETTINGS_MANAGER_SCRIPT.RESOLUTION_OPTIONS.size(),
				"Resolution OptionButton must list every preset."
			)
			_expect(resolution_option.get_item_text(0).contains("1280 x 720"), "First resolution item must be 720p.")
			_expect(
				resolution_option.get_item_text(resolution_option.item_count - 1).contains("3840 x 2160"),
				"Last resolution item must be 4K."
			)
		if config_path_label != null:
			_expect(
				config_path_label.text.contains("settings.cfg"),
				"Config path label must mention settings.cfg."
			)
		if music_slider != null:
			_expect(_float_close(float(music_slider.value), 70.0), "Music slider must default to 70%.")
		if music_value != null:
			_expect(music_value.text == "70%", "Music value label must default to 70%.")
		if hotkey_hint != null:
			_expect(not hotkey_hint.visible, "Hotkey hint must not occupy the settings panel by default.")
			_expect(hotkey_hint.text.is_empty(), "Hotkey hint must start empty by default.")
		panel.call("close")
		_expect(not panel.visible, "Settings panel must hide after close().")

	menu.queue_free()
	await process_frame


func _test_audio_bus_assignment() -> void:
	var game := GAME_SCENE.instantiate()
	_expect(game != null, "Game scene must instantiate for audio bus test.")
	if game == null:
		return
	game.set("auto_start_waves", false)
	root.add_child(game)
	await process_frame
	_settings().call("assign_audio_buses_to_tree")
	await process_frame

	var music_player := game.get_node_or_null("MusicPlayer") as AudioStreamPlayer
	_expect(music_player != null, "Game MusicPlayer must exist.")
	if music_player != null:
		_expect(music_player.bus == "Music", "MusicPlayer must route to Music bus.")
	var player := game.get_node_or_null("Player")
	var gunshot: AudioStreamPlayer2D = null
	if player != null:
		gunshot = player.get_node_or_null("GunshotAudio") as AudioStreamPlayer2D
	_expect(gunshot != null, "Player GunshotAudio must exist.")
	if gunshot != null:
		_expect(gunshot.bus == "SFX", "Effect audio must route to SFX bus.")
	var camera := game.get_node_or_null("Camera2D") as Camera2D
	_expect(camera != null, "Game Camera2D must exist.")
	if camera != null:
		var visible_world_size := Vector2(root.content_scale_size) / camera.zoom
		_expect(
			visible_world_size.is_equal_approx(Vector2(576, 324)),
			"Camera visible world size must stay aligned with the original project viewport."
		)

	game.queue_free()
	await process_frame


func _resolution_options_contain(options: Array, resolution_id: String) -> bool:
	for option in options:
		if str(option.get("id", "")) == resolution_id:
			return true
	return false


func _resolution_option_index(resolution_id: String) -> int:
	for idx in range(SETTINGS_MANAGER_SCRIPT.RESOLUTION_OPTIONS.size()):
		var option := SETTINGS_MANAGER_SCRIPT.RESOLUTION_OPTIONS[idx]
		if str(option.get("id", "")) == resolution_id:
			return idx
	return -1


func _float_close(a: float, b: float) -> bool:
	return absf(a - b) <= 0.001


func _test_hotkey_defaults_and_event_helpers() -> void:
	var settings := _settings()
	for action in SETTINGS_MANAGER_SCRIPT.BINDABLE_ACTIONS:
		_expect(InputMap.has_action(action), "InputMap must contain action %s." % action)
		var events: Array = settings.call("get_supported_events", action)
		_expect(
			events.size() <= SETTINGS_MANAGER_SCRIPT.MAX_BINDINGS_PER_ACTION,
			"%s must expose at most 3 bindings." % action
		)

	var move_up_events: Array = settings.call("get_supported_events", "move_up")
	var has_keyboard_w := false
	var has_joy_motion := false
	for event in move_up_events:
		if event is InputEventKey:
			has_keyboard_w = has_keyboard_w or (event as InputEventKey).physical_keycode == KEY_W
		if event is InputEventJoypadMotion:
			var motion := event as InputEventJoypadMotion
			has_joy_motion = has_joy_motion or (motion.axis == 1 and motion.axis_value < 0.0)
	_expect(has_keyboard_w, "move_up default binding must include W.")
	_expect(has_joy_motion, "move_up default binding must include gamepad up motion.")

	var captured_key := InputEventKey.new()
	captured_key.pressed = true
	captured_key.physical_keycode = KEY_Z
	var normalized_key: InputEvent = settings.call("normalize_captured_event", captured_key)
	_expect(normalized_key is InputEventKey, "Keyboard capture must normalize pressed key events.")

	var captured_motion := InputEventJoypadMotion.new()
	captured_motion.axis = 2
	captured_motion.axis_value = -0.8
	var normalized_motion: InputEvent = settings.call("normalize_captured_event", captured_motion)
	_expect(normalized_motion is InputEventJoypadMotion, "Joypad motion capture must be supported.")
	if normalized_motion is InputEventJoypadMotion:
		_expect(
			(normalized_motion as InputEventJoypadMotion).axis_value == -1.0,
			"Joypad motion capture must normalize axis direction."
		)
