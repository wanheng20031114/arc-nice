extends SceneTree

const MAIN_MENU_SCENE := preload("res://scene/main_menu.tscn")

var _errors: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var initial_menu := await _create_menu()
	_expect(
		root.gui_get_focus_owner() == null,
		"首次进入主菜单时不应隐式聚焦第一项。",
	)
	initial_menu.free()
	await process_frame

	MainMenu.request_focus_after_return(MainMenu.FOCUS_ENCYCLOPEDIA)
	var returned_menu := await _create_menu()
	_expect(
		root.gui_get_focus_owner() == returned_menu.encyclopedia_button,
		"从图鉴返回时应恢复图鉴按钮焦点。",
	)
	returned_menu.free()
	await process_frame

	var keyboard_menu := await _create_menu()
	var navigation_event := InputEventAction.new()
	navigation_event.action = &"ui_down"
	navigation_event.pressed = true
	keyboard_menu._unhandled_input(navigation_event)
	await process_frame
	_expect(
		root.gui_get_focus_owner() == keyboard_menu.singleplayer_button,
		"无焦点时首次键盘导航应显式聚焦第一项。",
	)
	keyboard_menu.free()

	if _errors.is_empty():
		print("MAIN_MENU_FOCUS_REGRESSION_OK")
		quit(0)
		return
	for error in _errors:
		push_error(error)
	quit(1)


func _create_menu() -> MainMenu:
	var menu := MAIN_MENU_SCENE.instantiate() as MainMenu
	root.add_child(menu)
	# 本测试仅覆盖菜单焦点，不启动与结论无关的图鉴资源预热。
	menu._is_exiting_tree = true
	await process_frame
	await process_frame
	return menu


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_errors.append(message)
