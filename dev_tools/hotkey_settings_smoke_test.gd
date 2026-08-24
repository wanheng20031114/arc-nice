extends SceneTree

const SETTINGS_MANAGER_SCRIPT := preload("res://scene/settings/settings_manager.gd")
const SETTINGS_PANEL_SCRIPT := preload("res://scene/settings/settings_panel.gd")
const SETTINGS_PANEL_SCENE := preload("res://scene/settings/settings_panel.tscn")

const EXPECTED_BINDABLE_ACTIONS: Array[String] = [
	"move_up",
	"move_down",
	"move_left",
	"move_right",
	"shoot_up",
	"shoot_down",
	"shoot_left",
	"shoot_right",
	"skill1",
	"dash",
	"interact",
	"bag",
	"use_item",
	"continuous_place",
	"plant",
	"show_detail",
	"delete",
	"reload",
	"luoxi_refresh",
	"select_option_1",
	"select_option_2",
	"select_option_3",
	"select_option_4",
	"recenter_camera",
	"full_screen",
	"quit",
	"pause",
]
const DEBUG_ACTIONS: Array[String] = ["cheat_collectibles", "cheat_xirang"]

var failures: Array[String] = []


func _initialize() -> void:
	call_deferred(&"_run")


func _run() -> void:
	await process_frame
	var settings := root.get_node_or_null("UserSettings")
	_expect(settings != null, "UserSettings autoload must exist.")
	if settings == null:
		_finish()
		return

	_expect(
		SETTINGS_MANAGER_SCRIPT.BINDABLE_ACTIONS == EXPECTED_BINDABLE_ACTIONS,
		"Bindable action list must contain every production hotkey in stable order."
	)
	for action in EXPECTED_BINDABLE_ACTIONS:
		_expect(InputMap.has_action(action), "InputMap action is missing: %s" % action)
		_expect(
			not InputMap.action_get_events(action).is_empty(),
			"Production hotkey must have at least one default binding: %s" % action
		)
		_expect(
			SETTINGS_PANEL_SCRIPT.ACTION_ROW_NAMES.has(action),
			"Settings row mapping is missing: %s" % action
		)
		_expect(
			SETTINGS_PANEL_SCRIPT.ACTION_DISPLAY_NAMES.has(action),
			"Settings display name is missing: %s" % action
		)
	for action in DEBUG_ACTIONS:
		_expect(
			not SETTINGS_MANAGER_SCRIPT.BINDABLE_ACTIONS.has(action),
			"Debug action must stay out of user hotkeys: %s" % action
		)
	var expected_custom_actions := EXPECTED_BINDABLE_ACTIONS.duplicate()
	expected_custom_actions.append_array(DEBUG_ACTIONS)
	expected_custom_actions.sort()
	var actual_custom_actions: Array[String] = []
	for action_name in InputMap.get_actions():
		var action := str(action_name)
		if not action.begins_with("ui_"):
			actual_custom_actions.append(action)
	actual_custom_actions.sort()
	_expect(
		actual_custom_actions == expected_custom_actions,
		"Every non-UI project action must be classified as bindable or debug-only."
	)

	var panel := SETTINGS_PANEL_SCENE.instantiate()
	root.add_child(panel)
	await process_frame
	var rows := panel.get_node_or_null(
		"Center/Panel/Margin/Layout/Scroll/Content/HotkeySection/Rows"
	)
	_expect(rows != null, "Settings hotkey row container must exist.")
	if rows != null:
		for action in EXPECTED_BINDABLE_ACTIONS:
			var row_name := str(SETTINGS_PANEL_SCRIPT.ACTION_ROW_NAMES[action])
			var row := rows.get_node_or_null(row_name)
			_expect(row != null, "Authored hotkey row is missing: %s" % row_name)
			if row == null:
				continue
			_expect(row.get_node_or_null("ActionLabel") is Label, "%s ActionLabel missing." % row_name)
			for slot_index in range(SETTINGS_MANAGER_SCRIPT.MAX_BINDINGS_PER_ACTION):
				_expect(
					row.get_node_or_null("Slot%d" % (slot_index + 1)) is Button,
					"%s slot %d missing." % [row_name, slot_index + 1]
				)
			_expect(row.get_node_or_null("Reset") is Button, "%s Reset missing." % row_name)
	_expect(
		panel.get_node_or_null(
			"Center/Panel/Margin/Layout/Scroll/Content/HotkeySection/CaptureActions/ClearBindingButton"
		) is Button,
		"Capture UI must expose an explicit clear button."
	)
	_expect(
		panel.get_node_or_null(
			"Center/Panel/Margin/Layout/Scroll/Content/HotkeySection/CaptureActions/CancelCaptureButton"
		) is Button,
		"Capture UI must expose an explicit cancel button."
	)

	for keycode in [KEY_ESCAPE, KEY_BACKSPACE, KEY_DELETE]:
		var key_event := InputEventKey.new()
		key_event.pressed = true
		key_event.physical_keycode = keycode
		var normalized: InputEvent = settings.call("normalize_captured_event", key_event)
		_expect(
			normalized is InputEventKey
				and (normalized as InputEventKey).physical_keycode == keycode,
			"Reserved editor key must remain bindable: %s" % OS.get_keycode_string(keycode)
		)

	var physical_key := InputEventKey.new()
	physical_key.physical_keycode = KEY_K
	var logical_key := InputEventKey.new()
	logical_key.keycode = KEY_K
	_expect(
		bool(settings.call("events_equal", physical_key, logical_key)),
		"Physical and logical forms of the same key must conflict."
	)
	var modified_key := InputEventKey.new()
	modified_key.physical_keycode = KEY_K
	modified_key.ctrl_pressed = true
	_expect(
		not bool(settings.call("events_equal", physical_key, modified_key)),
		"Exact binding comparison must preserve modifiers."
	)
	_expect(
		bool(settings.call("events_overlap", physical_key, modified_key)),
		"Plain and modified forms of a key must be treated as runtime conflicts."
	)
	var standalone_ctrl := InputEventKey.new()
	standalone_ctrl.physical_keycode = KEY_CTRL
	_expect(
		bool(settings.call("events_overlap", standalone_ctrl, modified_key)),
		"A standalone modifier must conflict with chords that use it."
	)
	var captured_combo := InputEventKey.new()
	captured_combo.pressed = true
	captured_combo.physical_keycode = KEY_K
	captured_combo.ctrl_pressed = true
	var normalized_combo: InputEvent = settings.call("normalize_captured_event", captured_combo)
	_expect(
		normalized_combo is InputEventKey
			and (normalized_combo as InputEventKey).ctrl_pressed,
		"Captured keyboard chords must preserve their modifier."
	)
	_expect(
		bool(settings.call("_actions_may_share_binding", "reload", "luoxi_refresh")),
		"Reload and Luoxi refresh must be allowed to share their contextual default."
	)
	_expect(
		bool(settings.call("_actions_may_share_binding", "use_item", "continuous_place")),
		"Quick use and continuous placement must be allowed to share Shift by default."
	)
	_expect(
		not bool(settings.call("_actions_may_share_binding", "move_up", "shoot_up")),
		"Parallel gameplay actions must retain conflict protection."
	)

	var route_source := FileAccess.get_file_as_string(
		"res://scene/game_modes/rogue/route/rogue_route_game.gd"
	)
	var luoxi_source := FileAccess.get_file_as_string(
		"res://scene/merchants/luoxi/luoxi_merchant.gd"
	)
	var placement_source := FileAccess.get_file_as_string(
		"res://scene/game_modes/tower_defense/plant/placement/plant_placement_controller.gd"
	)
	_expect(route_source.contains("is_action_pressed(&\"recenter_camera\")"), "Route recenter must use InputMap.")
	_expect(not route_source.contains("KEY_HOME"), "Route recenter must not hardcode Home.")
	for option_key in ["KEY_1", "KEY_2", "KEY_3", "KEY_4"]:
		_expect(
			not luoxi_source.contains(option_key),
			"Luoxi option shortcuts must not hardcode %s." % option_key
		)
	_expect(
		placement_source.contains("Input.is_action_pressed(&\"continuous_place\")"),
		"Continuous placement must use its editable action."
	)
	_expect(not placement_source.contains("shift_pressed"), "Continuous placement must not hardcode Shift.")

	panel.queue_free()
	await process_frame
	_finish()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("HOTKEY_SETTINGS_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)
