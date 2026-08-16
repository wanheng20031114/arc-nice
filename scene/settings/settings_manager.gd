extends Node

# 设置文件只属于当前用户，不依赖编辑器/导出包所在目录是否可写。
const CONFIG_PATH := "user://settings.cfg"
const SAVE_DEBOUNCE_SECONDS := 0.25
const SECTION_DISPLAY := "display"
const SECTION_AUDIO := "audio"
const SECTION_BINDINGS := "input_bindings"

const MASTER_BUS := &"Master"
const MUSIC_BUS := &"Music"
const SFX_BUS := &"SFX"

const DEFAULT_RESOLUTION_ID := "1280x720"
const BASE_CONTENT_SCALE_SIZE := Vector2i(1152, 648)
const DEFAULT_MASTER_VOLUME := 100.0
const DEFAULT_MUSIC_VOLUME := 70.0
const DEFAULT_SFX_VOLUME := 100.0
const DEFAULT_FULLSCREEN := false
const MAX_BINDINGS_PER_ACTION := 3
const JOYPAD_MOTION_THRESHOLD := 0.55
const PLANT_ACTION := "plant"
const PLANT_DEFAULT_PHYSICAL_KEYCODE := KEY_T

# 所有持久化尝试都从同一信号对外反馈；error_code 为 OK 时表示已落盘/删除。
signal persistence_finished(operation: StringName, config_path: String, error_code: int)

const BINDABLE_ACTIONS: Array[String] = [
	"move_up",
	"move_down",
	"move_left",
	"move_right",
	"shoot_up",
	"shoot_down",
	"shoot_left",
	"shoot_right",
	"skill1",
	"plant",
	"reload",
]

const RESOLUTION_OPTIONS: Array[Dictionary] = [
	{"id": "1280x720", "label": "1280 x 720 (720p)", "width": 1280, "height": 720},
	{"id": "1366x768", "label": "1366 x 768", "width": 1366, "height": 768},
	{"id": "1600x900", "label": "1600 x 900", "width": 1600, "height": 900},
	{"id": "1920x1080", "label": "1920 x 1080 (1080p)", "width": 1920, "height": 1080},
	{"id": "1920x1200", "label": "1920 x 1200", "width": 1920, "height": 1200},
	{"id": "2560x1080", "label": "2560 x 1080 (UW-FHD)", "width": 2560, "height": 1080},
	{"id": "2560x1440", "label": "2560 x 1440 (2K)", "width": 2560, "height": 1440},
	{"id": "3440x1440", "label": "3440 x 1440 (UWQHD)", "width": 3440, "height": 1440},
	{"id": "3840x2160", "label": "3840 x 2160 (4K)", "width": 3840, "height": 2160},
]

var _defaults_captured: bool = false
var _default_events_by_action: Dictionary = {}
var _config := ConfigFile.new()
var _config_loaded: bool = false
var _config_dirty: bool = false
var _save_time_left: float = 0.0
var _last_persistence_error: Error = OK


func _ready() -> void:
	set_process(false)
	_ensure_config_loaded()
	_ensure_audio_buses()
	_ensure_builtin_action_defaults()
	_capture_default_bindings()
	apply_all()


func _process(delta: float) -> void:
	if not _config_dirty:
		set_process(false)
		return
	_save_time_left = maxf(_save_time_left - maxf(delta, 0.0), 0.0)
	if _save_time_left <= 0.0:
		flush_pending_save()


func _exit_tree() -> void:
	# 面板没来得及关闭或程序直接退出时，仍要兑现最后一次音量修改。
	flush_pending_save()


func apply_all() -> void:
	_apply_saved_resolution()
	_apply_saved_audio()
	_apply_saved_bindings()


func get_config_path() -> String:
	return CONFIG_PATH


func get_config_file_system_path() -> String:
	return ProjectSettings.globalize_path(CONFIG_PATH)


func get_last_persistence_error() -> Error:
	return _last_persistence_error


func is_save_pending() -> bool:
	return _config_dirty


func flush_pending_save() -> Error:
	if not _config_dirty:
		return OK
	return _save_config()


func reset_all_settings() -> Error:
	var delete_error := _delete_config_file()
	if delete_error != OK:
		return delete_error
	_cancel_pending_save()
	# 删除成功后同时替换内存副本，避免磁盘与运行时出现两个真相源。
	_config = ConfigFile.new()
	_config_loaded = true
	_capture_default_bindings()
	for action in BINDABLE_ACTIONS:
		_restore_action_default(action)
	_apply_default_resolution()
	_apply_default_audio()
	return OK


func get_resolution_options() -> Array[Dictionary]:
	var options: Array[Dictionary] = []
	for option in RESOLUTION_OPTIONS:
		options.append(option.duplicate(true))
	return options


func get_windowed_resolution_options_for_size(_screen_size: Vector2i) -> Array[Dictionary]:
	return get_resolution_options()


func get_selected_resolution_index() -> int:
	_ensure_config_loaded()
	var resolution_id := str(_config.get_value(SECTION_DISPLAY, "resolution", DEFAULT_RESOLUTION_ID))
	for idx in range(RESOLUTION_OPTIONS.size()):
		if str(RESOLUTION_OPTIONS[idx].get("id", "")) == resolution_id:
			return idx
	return _get_default_resolution_index()


func set_resolution_index(index: int) -> Error:
	var safe_index := clampi(index, 0, RESOLUTION_OPTIONS.size() - 1)
	var option := RESOLUTION_OPTIONS[safe_index]
	var save_error := _set_config_value_immediately(
		SECTION_DISPLAY,
		"resolution",
		str(option.get("id", DEFAULT_RESOLUTION_ID))
	)
	if not is_fullscreen_enabled():
		_apply_windowed_resolution_option(option)
	return save_error


func is_fullscreen_enabled() -> bool:
	_ensure_config_loaded()
	return bool(_config.get_value(SECTION_DISPLAY, "fullscreen", DEFAULT_FULLSCREEN))


func set_fullscreen_enabled(enabled: bool) -> Error:
	var save_error := _set_config_value_immediately(SECTION_DISPLAY, "fullscreen", enabled)
	if enabled:
		_apply_fullscreen_resolution()
	else:
		_apply_saved_windowed_resolution()
	return save_error


func get_current_screen_size() -> Vector2i:
	return _get_current_screen_size()


func get_volume_percent(channel: StringName) -> float:
	_ensure_config_loaded()
	var key := _volume_key(channel)
	var default_value := _volume_default(channel)
	return clampf(float(_config.get_value(SECTION_AUDIO, key, default_value)), 0.0, 100.0)


func set_volume_percent(channel: StringName, percent: float) -> Error:
	if not _is_volume_channel(channel):
		return ERR_INVALID_PARAMETER
	var clamped := clampf(percent, 0.0, 100.0)
	_ensure_config_loaded()
	var changed := _set_config_value(SECTION_AUDIO, _volume_key(channel), clamped)
	if changed or _config_dirty:
		_queue_config_save()
	_apply_volume(channel, clamped)
	# 音量在内存与音频总线上已经生效；落盘结果由 flush API/信号反馈。
	return OK


func get_supported_events(action: String) -> Array:
	var result: Array = []
	if not InputMap.has_action(action):
		return result
	for event in InputMap.action_get_events(action):
		if _is_supported_binding_event(event):
			result.append(event)
		if result.size() >= MAX_BINDINGS_PER_ACTION:
			break
	return result


func set_action_event(action: String, slot_index: int, event: InputEvent) -> Error:
	if not _is_bindable_action(action):
		return ERR_INVALID_PARAMETER
	if slot_index < 0 or slot_index >= MAX_BINDINGS_PER_ACTION:
		return ERR_INVALID_PARAMETER
	if not _is_supported_binding_event(event):
		return ERR_INVALID_PARAMETER
	var events := get_supported_events(action)
	while events.size() < MAX_BINDINGS_PER_ACTION:
		events.append(null)
	events[slot_index] = _clone_binding_event(event)
	_apply_action_events(action, _compact_supported_events(events))
	return _save_bindings()


func clear_action_event(action: String, slot_index: int) -> Error:
	if not _is_bindable_action(action):
		return ERR_INVALID_PARAMETER
	if slot_index < 0 or slot_index >= MAX_BINDINGS_PER_ACTION:
		return ERR_INVALID_PARAMETER
	var events := get_supported_events(action)
	while events.size() < MAX_BINDINGS_PER_ACTION:
		events.append(null)
	events[slot_index] = null
	_apply_action_events(action, _compact_supported_events(events))
	return _save_bindings()


func reset_action(action: String) -> Error:
	if not _is_bindable_action(action):
		return ERR_INVALID_PARAMETER
	_restore_action_default(action)
	return _save_bindings()


func reset_all_bindings() -> Error:
	for action in BINDABLE_ACTIONS:
		_restore_action_default(action)
	return _save_bindings()


func find_event_owner(event: InputEvent, excluded_action: String = "", excluded_slot: int = -1) -> String:
	if not _is_supported_binding_event(event):
		return ""
	for action in BINDABLE_ACTIONS:
		var events := get_supported_events(action)
		for idx in range(events.size()):
			if action == excluded_action and idx == excluded_slot:
				continue
			if events_equal(events[idx], event):
				return action
	return ""


func events_equal(a: InputEvent, b: InputEvent) -> bool:
	if a == null or b == null:
		return false
	if a is InputEventKey and b is InputEventKey:
		var ka := a as InputEventKey
		var kb := b as InputEventKey
		return (
			ka.physical_keycode == kb.physical_keycode
			and ka.keycode == kb.keycode
			and ka.shift_pressed == kb.shift_pressed
			and ka.ctrl_pressed == kb.ctrl_pressed
			and ka.alt_pressed == kb.alt_pressed
			and ka.meta_pressed == kb.meta_pressed
		)
	if a is InputEventJoypadButton and b is InputEventJoypadButton:
		var ba := a as InputEventJoypadButton
		var bb := b as InputEventJoypadButton
		return ba.button_index == bb.button_index
	if a is InputEventJoypadMotion and b is InputEventJoypadMotion:
		var ma := a as InputEventJoypadMotion
		var mb := b as InputEventJoypadMotion
		return ma.axis == mb.axis and _motion_direction(ma.axis_value) == _motion_direction(mb.axis_value)
	return false


func event_to_display_text(event: InputEvent) -> String:
	if event is InputEventKey:
		var key_event := event as InputEventKey
		var parts: Array[String] = []
		if key_event.ctrl_pressed:
			parts.append("Ctrl")
		if key_event.alt_pressed:
			parts.append("Alt")
		if key_event.shift_pressed:
			parts.append("Shift")
		if key_event.meta_pressed:
			parts.append("Meta")
		var code := key_event.physical_keycode if key_event.physical_keycode != 0 else key_event.keycode
		parts.append(OS.get_keycode_string(code))
		return "+".join(parts)
	if event is InputEventJoypadButton:
		var button_event := event as InputEventJoypadButton
		return "手柄按钮 %d" % button_event.button_index
	if event is InputEventJoypadMotion:
		var motion_event := event as InputEventJoypadMotion
		return _joy_motion_display_name(motion_event.axis, motion_event.axis_value)
	return "未知"


func normalize_captured_event(event: InputEvent) -> InputEvent:
	if event is InputEventKey:
		var key_event := event as InputEventKey
		if not key_event.pressed or key_event.echo:
			return null
		var output_key := InputEventKey.new()
		output_key.physical_keycode = key_event.physical_keycode
		output_key.keycode = key_event.keycode
		output_key.shift_pressed = key_event.shift_pressed
		output_key.ctrl_pressed = key_event.ctrl_pressed
		output_key.alt_pressed = key_event.alt_pressed
		output_key.meta_pressed = key_event.meta_pressed
		return output_key
	if event is InputEventJoypadButton:
		var joy_button := event as InputEventJoypadButton
		if not joy_button.pressed:
			return null
		var output_button := InputEventJoypadButton.new()
		output_button.device = -1
		output_button.button_index = joy_button.button_index
		return output_button
	if event is InputEventJoypadMotion:
		var joy_motion := event as InputEventJoypadMotion
		if absf(joy_motion.axis_value) < JOYPAD_MOTION_THRESHOLD:
			return null
		var output_motion := InputEventJoypadMotion.new()
		output_motion.device = -1
		output_motion.axis = joy_motion.axis
		output_motion.axis_value = float(_motion_direction(joy_motion.axis_value))
		return output_motion
	return null


func _ensure_config_loaded() -> void:
	if _config_loaded:
		return
	_config_loaded = true
	var load_error := _config.load(CONFIG_PATH)
	if load_error == OK or load_error == ERR_FILE_NOT_FOUND:
		return
	# 损坏文件可能只解析出一半字段；失败时整份回到默认，禁止使用半成品状态。
	_config = ConfigFile.new()
	_report_persistence_result(&"load", load_error)


func _set_config_value(section: String, key: String, value: Variant) -> bool:
	_ensure_config_loaded()
	if _config.has_section_key(section, key) and _config.get_value(section, key) == value:
		return false
	_config.set_value(section, key, value)
	_config_dirty = true
	return true


func _set_config_value_immediately(section: String, key: String, value: Variant) -> Error:
	_set_config_value(section, key, value)
	if not _config_dirty:
		return OK
	return flush_pending_save()


func _queue_config_save() -> void:
	_save_time_left = SAVE_DEBOUNCE_SECONDS
	if is_inside_tree():
		set_process(true)


func _cancel_pending_save() -> void:
	_config_dirty = false
	_save_time_left = 0.0
	set_process(false)


func _save_config() -> Error:
	_ensure_config_loaded()
	var save_error := _config.save(CONFIG_PATH)
	if save_error == OK:
		_config_dirty = false
		_save_time_left = 0.0
	# 失败后保留 dirty，供显式 flush 或下一次修改重试，但停止逐帧刷错误日志。
	set_process(false)
	_report_persistence_result(&"save", save_error)
	return save_error


func _delete_config_file() -> Error:
	if not FileAccess.file_exists(CONFIG_PATH):
		_report_persistence_result(&"delete", OK)
		return OK
	var dir := DirAccess.open(CONFIG_PATH.get_base_dir())
	if dir == null:
		var open_error := DirAccess.get_open_error()
		_report_persistence_result(&"delete", open_error)
		return open_error
	var delete_error := dir.remove(CONFIG_PATH.get_file())
	_report_persistence_result(&"delete", delete_error)
	return delete_error


func _report_persistence_result(operation: StringName, error_code: Error) -> void:
	_last_persistence_error = error_code
	persistence_finished.emit(operation, CONFIG_PATH, int(error_code))
	if error_code != OK:
		push_error(
			"设置持久化失败：操作=%s，路径=%s，错误码=%d"
			% [operation, CONFIG_PATH, int(error_code)]
		)


func _apply_saved_resolution() -> void:
	if is_fullscreen_enabled():
		_apply_fullscreen_resolution()
	else:
		_apply_saved_windowed_resolution()


func _apply_default_resolution() -> void:
	var option := RESOLUTION_OPTIONS[_get_default_resolution_index()].duplicate(true)
	_apply_windowed_resolution_option(option)


func _apply_saved_windowed_resolution() -> void:
	var index := get_selected_resolution_index()
	var option := RESOLUTION_OPTIONS[index]
	_apply_windowed_resolution_option(option)


func _apply_windowed_resolution_option(option: Dictionary) -> void:
	var width := int(option.get("width", 1280))
	var height := int(option.get("height", 720))
	var window := get_window()
	if window == null:
		return
	window.mode = Window.MODE_WINDOWED
	window.size = Vector2i(width, height)
	_apply_canvas_stretch()
	_center_window(window)


func _apply_fullscreen_resolution() -> void:
	var window := get_window()
	if window == null:
		return
	var screen_size := _get_current_screen_size()
	window.mode = Window.MODE_EXCLUSIVE_FULLSCREEN
	window.size = screen_size
	_apply_canvas_stretch()


func _apply_canvas_stretch() -> void:
	var root_window := get_tree().root
	if root_window == null:
		return
	root_window.content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
	root_window.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_EXPAND
	root_window.content_scale_size = BASE_CONTENT_SCALE_SIZE


func _center_window(window: Window) -> void:
	if window == null:
		return
	var screen := DisplayServer.window_get_current_screen()
	var usable_rect := DisplayServer.screen_get_usable_rect(screen)
	var centered := usable_rect.position + Vector2i(
		maxi(floori(float(usable_rect.size.x - window.size.x) / 2.0), 0),
		maxi(floori(float(usable_rect.size.y - window.size.y) / 2.0), 0)
	)
	window.position = centered


func _get_current_screen_size() -> Vector2i:
	var screen := DisplayServer.window_get_current_screen()
	var screen_size := DisplayServer.screen_get_size(screen)
	if screen_size.x > 0 and screen_size.y > 0:
		return screen_size
	var window := get_window()
	if window != null and window.size.x > 0 and window.size.y > 0:
		return window.size
	return Vector2i(1280, 720)


func _apply_saved_audio() -> void:
	_apply_volume(&"master", get_volume_percent(&"master"))
	_apply_volume(&"music", get_volume_percent(&"music"))
	_apply_volume(&"sfx", get_volume_percent(&"sfx"))


func _apply_default_audio() -> void:
	_apply_volume(&"master", DEFAULT_MASTER_VOLUME)
	_apply_volume(&"music", DEFAULT_MUSIC_VOLUME)
	_apply_volume(&"sfx", DEFAULT_SFX_VOLUME)


func _apply_volume(channel: StringName, percent: float) -> void:
	var bus_name := _bus_for_channel(channel)
	var bus_index := AudioServer.get_bus_index(bus_name)
	if bus_index < 0:
		return
	var clamped := clampf(percent, 0.0, 100.0)
	AudioServer.set_bus_mute(bus_index, clamped <= 0.0)
	AudioServer.set_bus_volume_db(bus_index, -80.0 if clamped <= 0.0 else linear_to_db(clamped / 100.0))


func _is_volume_channel(channel: StringName) -> bool:
	return channel == &"master" or channel == &"music" or channel == &"sfx"


func _volume_key(channel: StringName) -> String:
	match channel:
		&"music":
			return "music_volume"
		&"sfx":
			return "sfx_volume"
		_:
			return "master_volume"


func _volume_default(channel: StringName) -> float:
	match channel:
		&"music":
			return DEFAULT_MUSIC_VOLUME
		&"sfx":
			return DEFAULT_SFX_VOLUME
		_:
			return DEFAULT_MASTER_VOLUME


func _bus_for_channel(channel: StringName) -> StringName:
	match channel:
		&"music":
			return MUSIC_BUS
		&"sfx":
			return SFX_BUS
		_:
			return MASTER_BUS


func _ensure_audio_buses() -> void:
	_ensure_bus(MUSIC_BUS)
	_ensure_bus(SFX_BUS)


func _ensure_bus(bus_name: StringName) -> void:
	if AudioServer.get_bus_index(bus_name) >= 0:
		return
	AudioServer.add_bus(AudioServer.get_bus_count())
	var index := AudioServer.get_bus_count() - 1
	AudioServer.set_bus_name(index, bus_name)
	AudioServer.set_bus_send(index, MASTER_BUS)


func _capture_default_bindings() -> void:
	if _defaults_captured:
		return
	for action in BINDABLE_ACTIONS:
		_default_events_by_action[action] = _clone_events(get_supported_events(action))
	_defaults_captured = true


func _ensure_builtin_action_defaults() -> void:
	if not InputMap.has_action(PLANT_ACTION):
		InputMap.add_action(PLANT_ACTION)
	var has_default_plant_key := false
	for event in InputMap.action_get_events(PLANT_ACTION):
		if event is InputEventKey:
			has_default_plant_key = (
				has_default_plant_key
				or (event as InputEventKey).physical_keycode == PLANT_DEFAULT_PHYSICAL_KEYCODE
			)
	if has_default_plant_key:
		return
	var default_event := InputEventKey.new()
	default_event.physical_keycode = PLANT_DEFAULT_PHYSICAL_KEYCODE
	_apply_action_events(PLANT_ACTION, [default_event])


func _apply_saved_bindings() -> void:
	_ensure_config_loaded()
	for action in BINDABLE_ACTIONS:
		if not _config.has_section_key(SECTION_BINDINGS, action):
			continue
		var encoded_events: Variant = _config.get_value(SECTION_BINDINGS, action, [])
		if not (encoded_events is Array):
			continue
		var restored_events: Array = []
		for encoded in encoded_events:
			if not (encoded is String):
				continue
			var parsed: Variant = str_to_var(str(encoded))
			if _is_supported_binding_event(parsed):
				restored_events.append(parsed)
		_apply_action_events(action, restored_events)


func _save_bindings() -> Error:
	var changed := false
	for action in BINDABLE_ACTIONS:
		var serialized_events: Array[String] = []
		for event in get_supported_events(action):
			serialized_events.append(var_to_str(event))
		changed = _set_config_value(SECTION_BINDINGS, action, serialized_events) or changed
	if not changed and not _config_dirty:
		return OK
	return flush_pending_save()


func _restore_action_default(action: String) -> void:
	var defaults: Array = _default_events_by_action.get(action, [])
	_apply_action_events(action, _clone_events(defaults))


func _apply_action_events(action: String, events: Array) -> void:
	if not InputMap.has_action(action):
		InputMap.add_action(action)
	for old_event in InputMap.action_get_events(action):
		InputMap.action_erase_event(action, old_event)
	var added := 0
	for event in events:
		if not _is_supported_binding_event(event):
			continue
		InputMap.action_add_event(action, event)
		added += 1
		if added >= MAX_BINDINGS_PER_ACTION:
			break


func _compact_supported_events(events: Array) -> Array:
	var result: Array = []
	for event in events:
		if _is_supported_binding_event(event):
			result.append(event)
		if result.size() >= MAX_BINDINGS_PER_ACTION:
			break
	return result


func _is_supported_binding_event(event: Variant) -> bool:
	return event is InputEventKey or event is InputEventJoypadButton or event is InputEventJoypadMotion


func _is_bindable_action(action: String) -> bool:
	return BINDABLE_ACTIONS.has(action)


func _clone_events(events: Array) -> Array:
	var result: Array = []
	for event in events:
		if _is_supported_binding_event(event):
			result.append(_clone_binding_event(event))
	return result


func _clone_binding_event(event: InputEvent) -> InputEvent:
	return event.duplicate() as InputEvent


func _get_default_resolution_index() -> int:
	for idx in range(RESOLUTION_OPTIONS.size()):
		if str(RESOLUTION_OPTIONS[idx].get("id", "")) == DEFAULT_RESOLUTION_ID:
			return idx
	return 0


func _motion_direction(axis_value: float) -> int:
	return -1 if axis_value < 0.0 else 1


func _joy_motion_display_name(axis: int, axis_value: float) -> String:
	var direction := _motion_direction(axis_value)
	match axis:
		0:
			return "左摇杆 左" if direction < 0 else "左摇杆 右"
		1:
			return "左摇杆 上" if direction < 0 else "左摇杆 下"
		2:
			return "右摇杆 左" if direction < 0 else "右摇杆 右"
		3:
			return "右摇杆 上" if direction < 0 else "右摇杆 下"
		_:
			return "摇杆 %d %s" % [axis, "-" if direction < 0 else "+"]
