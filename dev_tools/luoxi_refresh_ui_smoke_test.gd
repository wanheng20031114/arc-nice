extends SceneTree

const OVERLAY_SCENE := preload("res://scene/luoxi_collectible_choice_overlay.tscn")

var failures: Array[String] = []
var refresh_signal_count := 0


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var overlay := OVERLAY_SCENE.instantiate() as LuoxiCollectibleChoiceOverlay
	root.add_child(overlay)
	await process_frame

	var refresh_button := overlay.get_node("Root/Center/Content/RefreshPanel/Margin/Layout/RefreshButton") as Button
	var refresh_status := overlay.get_node("Root/Center/Content/RefreshPanel/Margin/Layout/Info/RefreshStatus") as Label
	var refresh_progress := overlay.get_node("Root/Center/Content/RefreshPanel/Margin/Layout/Info/RefreshProgress") as Label
	var sub_hint := overlay.get_node("Root/Center/Content/SubHint") as Label
	_expect(InputMap.has_action("luoxi_refresh"), "The project must expose a dedicated Luoxi refresh input action.")
	var has_r_key := false
	var has_rb_button := false
	for input_event in InputMap.action_get_events("luoxi_refresh"):
		if input_event is InputEventKey and (input_event as InputEventKey).physical_keycode == KEY_R:
			has_r_key = true
		if input_event is InputEventJoypadButton and (input_event as InputEventJoypadButton).button_index == JOY_BUTTON_RIGHT_SHOULDER:
			has_rb_button = true
	_expect(has_r_key, "The Luoxi refresh action must bind keyboard R.")
	_expect(has_rb_button, "The Luoxi refresh action must bind gamepad RB.")

	overlay.set_refresh_state(0, 4, 100, 1800)
	_expect(not refresh_button.disabled, "The first Luoxi refresh must be enabled.")
	_expect(refresh_button.text.contains("100"), "The first Luoxi refresh must cost 100 xirang.")
	_expect(refresh_button.text.contains("R") and refresh_button.text.contains("RB"), "The refresh button must show R and RB shortcuts.")
	_expect(refresh_progress.text.contains("0/4"), "Refresh progress must start at 0/4.")
	_expect(refresh_status.text.contains("剩余 4 次"), "Refresh status must show four remaining refreshes.")
	_expect(sub_hint.text.contains("仅可带走一件"), "The chooser must explain the one-collectible intermission limit.")

	overlay.refresh_requested.connect(func() -> void: refresh_signal_count += 1)
	refresh_button.pressed.emit()
	_expect(refresh_signal_count == 1, "An enabled refresh button must emit one request.")
	overlay.set_refresh_pending(true)
	_expect(refresh_button.disabled and refresh_button.text.contains("正在刷新"), "A pending refresh must lock the button until authority responds.")
	refresh_button.pressed.emit()
	_expect(refresh_signal_count == 1, "A pending refresh must suppress duplicate requests.")

	overlay.set_refresh_state(4, 4, 0, 0)
	_expect(refresh_button.disabled, "The refresh button must disable after four refreshes.")
	_expect(refresh_button.text.contains("无法刷新"), "The exhausted button must explain its disabled state.")
	_expect(refresh_progress.text.contains("4/4"), "Refresh progress must show 4/4 after exhaustion.")
	_expect(refresh_status.text.contains("下次休整期重置"), "The exhausted state must explain the intermission reset.")
	var disabled_style := refresh_button.get_theme_stylebox("disabled") as StyleBoxFlat
	_expect(
		disabled_style != null
		and absf(disabled_style.bg_color.r - disabled_style.bg_color.g) < 0.03
		and absf(disabled_style.bg_color.g - disabled_style.bg_color.b) < 0.03,
		"The exhausted refresh button must use a gray-white disabled style."
	)
	refresh_button.pressed.emit()
	_expect(refresh_signal_count == 1, "An exhausted refresh button must not emit another request.")

	overlay.free()
	await process_frame
	if failures.is_empty():
		print("LUOXI_REFRESH_UI_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
