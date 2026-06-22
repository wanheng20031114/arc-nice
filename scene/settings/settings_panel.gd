extends Control
class_name SettingsPanel

const SETTINGS_MANAGER_SCRIPT := preload("res://scene/settings/settings_manager.gd")

signal opened
signal closed

const ACTION_ROW_NAMES := {
	"move_up": "MoveUpRow",
	"move_down": "MoveDownRow",
	"move_left": "MoveLeftRow",
	"move_right": "MoveRightRow",
	"shoot_up": "ShootUpRow",
	"shoot_down": "ShootDownRow",
	"shoot_left": "ShootLeftRow",
	"shoot_right": "ShootRightRow",
	"skill1": "Skill1Row",
}

const ACTION_DISPLAY_NAMES := {
	"move_up": "上移",
	"move_down": "下移",
	"move_left": "左移",
	"move_right": "右移",
	"shoot_up": "向上射击",
	"shoot_down": "向下射击",
	"shoot_left": "向左射击",
	"shoot_right": "向右射击",
	"skill1": "技能",
}

@onready var resolution_option: OptionButton = $Center/Panel/Margin/Layout/Scroll/Content/DisplaySection/ResolutionRow/ResolutionOption
@onready var fullscreen_check: CheckButton = $Center/Panel/Margin/Layout/Scroll/Content/DisplaySection/FullscreenRow/FullscreenCheck
@onready var config_path_label: Label = $Center/Panel/Margin/Layout/Scroll/Content/DisplaySection/ConfigPathLabel
@onready var master_slider: HSlider = $Center/Panel/Margin/Layout/Scroll/Content/AudioSection/MasterRow/MasterSlider
@onready var master_value: Label = $Center/Panel/Margin/Layout/Scroll/Content/AudioSection/MasterRow/MasterValue
@onready var music_slider: HSlider = $Center/Panel/Margin/Layout/Scroll/Content/AudioSection/MusicRow/MusicSlider
@onready var music_value: Label = $Center/Panel/Margin/Layout/Scroll/Content/AudioSection/MusicRow/MusicValue
@onready var sfx_slider: HSlider = $Center/Panel/Margin/Layout/Scroll/Content/AudioSection/SfxRow/SfxSlider
@onready var sfx_value: Label = $Center/Panel/Margin/Layout/Scroll/Content/AudioSection/SfxRow/SfxValue
@onready var key_rows: VBoxContainer = $Center/Panel/Margin/Layout/Scroll/Content/HotkeySection/Rows
@onready var hint_label: Label = $Center/Panel/Margin/Layout/Scroll/Content/HotkeySection/Hint
@onready var reset_settings_button: Button = $Center/Panel/Margin/Layout/Footer/ResetSettingsButton
@onready var reset_all_button: Button = $Center/Panel/Margin/Layout/Footer/ResetAllButton
@onready var close_button: Button = $Center/Panel/Margin/Layout/Footer/CloseButton

var _slot_buttons_by_action: Dictionary = {}
var _reset_buttons_by_action: Dictionary = {}
var _capture_action: String = ""
var _capture_slot: int = -1


func _settings() -> Node:
	return get_node("/root/UserSettings")


func _ready() -> void:
	hide()
	_populate_resolution_options()
	_collect_hotkey_rows()
	_connect_controls()
	_refresh_from_settings()


func open() -> void:
	if visible:
		return
	_settings().call("apply_all")
	_stop_capture()
	_refresh_from_settings()
	show()
	opened.emit()
	close_button.grab_focus()


func close() -> void:
	if not visible:
		return
	_stop_capture()
	hide()
	var viewport := get_viewport()
	if viewport != null:
		viewport.gui_release_focus()
	closed.emit()


func is_open() -> bool:
	return visible


func _connect_controls() -> void:
	fullscreen_check.toggled.connect(_on_fullscreen_toggled)
	resolution_option.item_selected.connect(_on_resolution_selected)
	master_slider.value_changed.connect(_on_volume_changed.bind(&"master"))
	music_slider.value_changed.connect(_on_volume_changed.bind(&"music"))
	sfx_slider.value_changed.connect(_on_volume_changed.bind(&"sfx"))
	reset_settings_button.pressed.connect(_on_reset_settings_pressed)
	reset_all_button.pressed.connect(_on_reset_all_pressed)
	close_button.pressed.connect(_on_close_pressed)


func _populate_resolution_options() -> void:
	resolution_option.clear()
	for option in _settings().call("get_resolution_options"):
		resolution_option.add_item(str(option.get("label", "")))


func _collect_hotkey_rows() -> void:
	for action in SETTINGS_MANAGER_SCRIPT.BINDABLE_ACTIONS:
		var row_name := str(ACTION_ROW_NAMES.get(action, ""))
		var row := key_rows.get_node_or_null(row_name) as HBoxContainer
		if row == null:
			continue
		var action_label := row.get_node_or_null("ActionLabel") as Label
		if action_label != null:
			action_label.text = str(ACTION_DISPLAY_NAMES.get(action, action))
		var slot_buttons: Array[Button] = []
		for slot_idx in range(SETTINGS_MANAGER_SCRIPT.MAX_BINDINGS_PER_ACTION):
			var button := row.get_node_or_null("Slot%d" % (slot_idx + 1)) as Button
			if button == null:
				continue
			button.pressed.connect(_on_bind_slot_pressed.bind(action, slot_idx))
			slot_buttons.append(button)
		_slot_buttons_by_action[action] = slot_buttons
		var reset_button := row.get_node_or_null("Reset") as Button
		if reset_button != null:
			reset_button.pressed.connect(_on_reset_action_pressed.bind(action))
			_reset_buttons_by_action[action] = reset_button


func _refresh_from_settings() -> void:
	var settings := _settings()
	_populate_resolution_options()
	fullscreen_check.set_pressed_no_signal(bool(settings.call("is_fullscreen_enabled")))
	resolution_option.disabled = fullscreen_check.button_pressed
	resolution_option.select(int(settings.call("get_selected_resolution_index")))
	config_path_label.text = "配置文件：%s。删除该文件会恢复默认设置。" % str(settings.call("get_config_file_system_path"))
	_set_slider_value(master_slider, float(settings.call("get_volume_percent", &"master")))
	_set_slider_value(music_slider, float(settings.call("get_volume_percent", &"music")))
	_set_slider_value(sfx_slider, float(settings.call("get_volume_percent", &"sfx")))
	_update_volume_labels()
	_refresh_hotkey_rows()
	if not _is_capture_active():
		hint_label.text = "点击一个槽位后按下键盘按键、手柄按钮或摇杆方向。Esc 取消，Backspace/Delete 清空。"


func _set_slider_value(slider: HSlider, value: float) -> void:
	slider.set_value_no_signal(clampf(value, 0.0, 100.0))


func _update_volume_labels() -> void:
	master_value.text = "%d%%" % int(round(master_slider.value))
	music_value.text = "%d%%" % int(round(music_slider.value))
	sfx_value.text = "%d%%" % int(round(sfx_slider.value))


func _refresh_hotkey_rows() -> void:
	var settings := _settings()
	for action in SETTINGS_MANAGER_SCRIPT.BINDABLE_ACTIONS:
		var buttons: Array = _slot_buttons_by_action.get(action, [])
		var events: Array = settings.call("get_supported_events", action)
		for slot_idx in range(buttons.size()):
			var button := buttons[slot_idx] as Button
			if button == null:
				continue
			if _capture_action == action and _capture_slot == slot_idx:
				button.text = "等待输入..."
			elif slot_idx < events.size():
				button.text = str(settings.call("event_to_display_text", events[slot_idx]))
			else:
				button.text = "未绑定"
		var reset_button := _reset_buttons_by_action.get(action) as Button
		if reset_button != null:
			reset_button.text = "重置"


func _on_resolution_selected(index: int) -> void:
	_settings().call("set_resolution_index", index)
	hint_label.text = "分辨率已应用。"


func _on_fullscreen_toggled(enabled: bool) -> void:
	_settings().call("set_fullscreen_enabled", enabled)
	resolution_option.disabled = enabled
	if enabled:
		var screen_size: Vector2i = _settings().call("get_current_screen_size")
		hint_label.text = "已进入全屏：%d x %d。" % [screen_size.x, screen_size.y]
	else:
		_populate_resolution_options()
		resolution_option.select(int(_settings().call("get_selected_resolution_index")))
		hint_label.text = "已退出全屏，恢复窗口分辨率。"


func _on_volume_changed(value: float, channel: StringName) -> void:
	_settings().call("set_volume_percent", channel, value)
	_update_volume_labels()


func _on_bind_slot_pressed(action: String, slot_idx: int) -> void:
	_capture_action = action
	_capture_slot = slot_idx
	hint_label.text = "正在设置“%s”，请按下新的按键或手柄输入。" % str(ACTION_DISPLAY_NAMES.get(action, action))
	_refresh_hotkey_rows()


func _on_reset_action_pressed(action: String) -> void:
	_settings().call("reset_action", action)
	_stop_capture()
	_refresh_hotkey_rows()
	hint_label.text = "“%s”已恢复默认。" % str(ACTION_DISPLAY_NAMES.get(action, action))


func _on_reset_all_pressed() -> void:
	_settings().call("reset_all_bindings")
	_stop_capture()
	_refresh_hotkey_rows()
	hint_label.text = "所有热键已恢复默认。"


func _on_reset_settings_pressed() -> void:
	_settings().call("reset_all_settings")
	_stop_capture()
	_refresh_from_settings()
	hint_label.text = "配置文件已删除，所有设置已恢复默认。"


func _on_close_pressed() -> void:
	close()


func _input(event: InputEvent) -> void:
	if not visible:
		return
	if _is_capture_active():
		_handle_capture_input(event)
		return
	if event.is_action_pressed("ui_cancel"):
		close()
		_mark_input_handled()
		return
	if event.is_action_pressed("bag"):
		_mark_input_handled()


func _handle_capture_input(event: InputEvent) -> void:
	if event is InputEventKey:
		var key_event := event as InputEventKey
		if key_event.pressed and not key_event.echo:
			if key_event.physical_keycode == KEY_ESCAPE:
				_stop_capture()
				_refresh_hotkey_rows()
				hint_label.text = "已取消按键设置。"
				_mark_input_handled()
				return
			if key_event.physical_keycode == KEY_BACKSPACE or key_event.physical_keycode == KEY_DELETE:
				_settings().call("clear_action_event", _capture_action, _capture_slot)
				_stop_capture()
				_refresh_hotkey_rows()
				hint_label.text = "该槽位已清空。"
				_mark_input_handled()
				return
	var settings := _settings()
	var captured: InputEvent = settings.call("normalize_captured_event", event)
	if captured == null:
		return
	var owner_action := str(settings.call("find_event_owner", captured, _capture_action, _capture_slot))
	if not owner_action.is_empty():
		hint_label.text = "该输入已用于“%s”，请换一个。" % str(ACTION_DISPLAY_NAMES.get(owner_action, owner_action))
		_mark_input_handled()
		return
	settings.call("set_action_event", _capture_action, _capture_slot, captured)
	_stop_capture()
	_refresh_hotkey_rows()
	hint_label.text = "热键已保存。"
	_mark_input_handled()


func _is_capture_active() -> bool:
	return not _capture_action.is_empty() and _capture_slot >= 0


func _stop_capture() -> void:
	_capture_action = ""
	_capture_slot = -1


func _mark_input_handled() -> void:
	var viewport := get_viewport()
	if viewport != null:
		viewport.set_input_as_handled()
