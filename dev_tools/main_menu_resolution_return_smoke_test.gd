extends SceneTree

## 回归“游戏 Camera2D 残留 Canvas 变换导致主菜单在改分辨率后被裁切”。

const MAIN_MENU_SCENE := preload("res://scene/main_menu.tscn")
const BASE_CONTENT_SIZE := Vector2i(1152, 648)
const RESOLUTION_CASES := [
	Vector2i(1280, 720),
	Vector2i(1920, 1080),
	Vector2i(2560, 1080),
]

var failures: PackedStringArray = []
var _original_window_size := Vector2i.ZERO
var _original_content_scale_size := Vector2i.ZERO
var _original_content_scale_mode := Window.CONTENT_SCALE_MODE_DISABLED
var _original_content_scale_aspect := Window.CONTENT_SCALE_ASPECT_IGNORE


func _initialize() -> void:
	call_deferred(&"_run")


func _run() -> void:
	_capture_window_state()
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
	root.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_EXPAND
	root.content_scale_size = BASE_CONTENT_SIZE

	for resolution in RESOLUTION_CASES:
		await _audit_game_to_menu_transition(resolution)

	await _release_current_scene()
	_restore_window_state()
	_finish()


func _audit_game_to_menu_transition(resolution: Vector2i) -> void:
	await _release_current_scene()
	root.size = resolution
	await process_frame
	await process_frame

	# 复刻塔防场景的主相机参数。它提交的 basis=2 Canvas 正是旧主菜单
	# 被放大并向右裁切的来源。
	var gameplay_fixture := Node2D.new()
	gameplay_fixture.name = "GameplayCameraFixture"
	var camera := Camera2D.new()
	camera.position = Vector2(286.0, 160.0)
	camera.zoom = Vector2(2.0, 2.0)
	gameplay_fixture.add_child(camera)
	root.add_child(gameplay_fixture)
	current_scene = gameplay_fixture
	camera.make_current()
	camera.force_update_scroll()
	await process_frame

	var outgoing_canvas := root.canvas_transform
	# Camera2D 自身释放时会清理 Viewport；正式塔防内嵌的 RogueRouteWorld
	# 随后却会把入树时捕获的游戏 Canvas 写回。这里复刻该最终残留状态，
	# 聚焦验证主菜单入口必须自行建立 UI Canvas 不变量。
	gameplay_fixture.remove_child(camera)
	camera.free()
	await process_frame
	root.canvas_transform = outgoing_canvas
	_expect(
		not root.canvas_transform.is_equal_approx(Transform2D.IDENTITY),
		"%s 的游戏夹具必须先提交非单位 Canvas 变换。" % resolution
	)
	var change_error := change_scene_to_packed(MAIN_MENU_SCENE)
	_expect(change_error == OK, "%s 必须能切回主菜单。" % resolution)
	if change_error != OK:
		return
	await scene_changed

	var menu := current_scene as MainMenu
	_expect(menu != null, "%s 返回后当前场景必须是 MainMenu。" % resolution)
	if menu == null:
		return
	# 本用例只验收 Canvas/布局，不启动与其无关的图鉴全量后台预加载。
	menu.set("_is_exiting_tree", true)
	await process_frame
	await process_frame
	_expect(
		root.canvas_transform.is_equal_approx(Transform2D.IDENTITY),
		"%s 返回主菜单时必须清除游戏 Camera2D 的 Canvas 变换。" % resolution
	)
	var menu_panel := menu.get_node_or_null("MenuCenter/MenuPanel") as Control
	_expect(menu_panel != null, "%s 主菜单面板必须存在。" % resolution)
	if menu_panel == null:
		return
	var panel_screen_transform := menu_panel.get_screen_transform()
	var panel_top_left := panel_screen_transform * Vector2.ZERO
	var panel_bottom_right := panel_screen_transform * menu_panel.size
	var visible_canvas_size := root.get_visible_rect().size
	_expect(
		panel_top_left.x >= -0.5
		and panel_top_left.y >= -0.5
		and panel_bottom_right.x <= visible_canvas_size.x + 0.5
		and panel_bottom_right.y <= visible_canvas_size.y + 0.5,
		"%s 返回后的主菜单面板必须完整落在 %s 可见画布内，实际为 %s 到 %s。"
		% [resolution, visible_canvas_size, panel_top_left, panel_bottom_right]
	)


func _release_current_scene() -> void:
	var scene := current_scene
	if scene == null:
		return
	current_scene = null
	root.remove_child(scene)
	scene.free()
	await process_frame


func _capture_window_state() -> void:
	_original_window_size = root.size
	_original_content_scale_size = root.content_scale_size
	_original_content_scale_mode = root.content_scale_mode
	_original_content_scale_aspect = root.content_scale_aspect


func _restore_window_state() -> void:
	root.canvas_transform = Transform2D.IDENTITY
	root.content_scale_mode = _original_content_scale_mode
	root.content_scale_aspect = _original_content_scale_aspect
	root.content_scale_size = _original_content_scale_size
	root.size = _original_window_size


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("MAIN_MENU_RESOLUTION_RETURN_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)
