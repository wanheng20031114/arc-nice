extends SceneTree

## 回归“多人对局 Camera2D 残留 Canvas 变换，返回大厅后只显示左上区域”。

const LOBBY_SCENE := preload("res://scene/multiplayer/multiplayer_lobby.tscn")
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
		await _audit_game_to_lobby_transition(resolution)

	await _release_current_scene()
	(root.get_node("NetManager") as NetManagerStore).disconnect_from_game()
	_restore_window_state()
	_finish()


func _audit_game_to_lobby_transition(resolution: Vector2i) -> void:
	await _release_current_scene()
	root.size = resolution
	await process_frame
	await process_frame

	# 塔防多人场景的相机使用 zoom=2，且位置令 Canvas 原点接近左上角；
	# 这正是故障截图中大厅整体放大两倍的状态。
	var gameplay_fixture := Node2D.new()
	gameplay_fixture.name = "MultiplayerGameplayCameraFixture"
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
	_expect(
		not outgoing_canvas.is_equal_approx(Transform2D.IDENTITY),
		"%s 的多人对局夹具必须先提交非单位 Canvas 变换。" % resolution
	)
	# 模拟游戏场景退出清理完成时留在共享 Viewport 上的最后一帧相机状态。
	gameplay_fixture.remove_child(camera)
	camera.free()
	await process_frame
	root.canvas_transform = outgoing_canvas

	var change_error := change_scene_to_packed(LOBBY_SCENE)
	_expect(change_error == OK, "%s 必须能从多人对局切回大厅。" % resolution)
	if change_error != OK:
		return
	await scene_changed
	await process_frame
	await process_frame

	var lobby := current_scene as Control
	_expect(lobby != null, "%s 返回后当前场景必须是 MultiplayerLobby。" % resolution)
	if lobby == null:
		return
	_expect(
		root.canvas_transform.is_equal_approx(Transform2D.IDENTITY),
		"%s 返回多人大厅时必须清除游戏 Camera2D 的 Canvas 变换。" % resolution
	)
	var username_panel := lobby.get_node_or_null(
		"LobbyCenter/UsernamePanel"
	) as Control
	_expect(username_panel != null, "%s 多人大厅用户名面板必须存在。" % resolution)
	if username_panel == null:
		return
	var panel_screen_transform := username_panel.get_screen_transform()
	var panel_top_left := panel_screen_transform * Vector2.ZERO
	var panel_bottom_right := panel_screen_transform * username_panel.size
	var visible_canvas_size := root.get_visible_rect().size
	_expect(
		panel_top_left.x >= -0.5
		and panel_top_left.y >= -0.5
		and panel_bottom_right.x <= visible_canvas_size.x + 0.5
		and panel_bottom_right.y <= visible_canvas_size.y + 0.5,
		"%s 返回后的大厅面板必须完整落在 %s 可见画布内，实际为 %s 到 %s。"
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
		print("MULTIPLAYER_LOBBY_RETURN_CANVAS_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)
