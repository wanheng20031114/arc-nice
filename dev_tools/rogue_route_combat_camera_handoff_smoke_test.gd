extends SceneTree

const ROUTE_SCENE := preload(
	"res://scene/game_modes/rogue/route/rogue_route_game.tscn"
)

var failures: PackedStringArray = []


func _initialize() -> void:
	call_deferred(&"_run")


func _run() -> void:
	var route := ROUTE_SCENE.instantiate() as RogueRouteGame
	route.auto_initialize = false
	route.manage_return_locally = true
	root.add_child(route)
	await process_frame
	await physics_frame

	var route_camera := route.map_camera
	var viewport := route.get_viewport()
	route.set_route_presentation_enabled(true)
	await process_frame
	_expect(
		route.player != null
		and route_camera.get_parent() == route.player
		and viewport.get_camera_2d() == route_camera,
		"夹具必须先建立路线玩家跟随相机。"
	)

	# 多人终局安全屏障会让隐藏的战斗 runtime 暂时留树；隐藏 Node2D
	# 不会自动停用 Camera2D，正是实机截图中视角锁在 (128, 128) 的路径。
	route.set_route_presentation_enabled(false)
	var combat_runtime := Node2D.new()
	combat_runtime.name = "RetainedCombatRuntime"
	var combat_camera := Camera2D.new()
	combat_camera.name = "Camera2D"
	combat_camera.position = Vector2(128.0, 128.0)
	combat_camera.zoom = Vector2(2.0, 2.0)
	combat_runtime.add_child(combat_camera)
	route.add_child(combat_runtime)
	combat_camera.make_current()
	combat_camera.force_update_scroll()
	await process_frame
	_expect(
		viewport.get_camera_2d() == combat_camera,
		"进入作战后战斗相机必须取得同一 Viewport。"
	)

	combat_runtime.hide()
	route.set_route_presentation_enabled(true)
	await physics_frame
	await process_frame
	_expect_route_camera_and_canvas(route, "隐藏战场尚未释放时")

	# 覆盖 presentation 已是 true 的重复恢复：旧实现会在这里提前 return，
	# 让仍启用的战斗相机继续控制路线。
	combat_camera.make_current()
	combat_camera.force_update_scroll()
	route.set_route_presentation_enabled(true)
	await physics_frame
	await process_frame
	_expect_route_camera_and_canvas(route, "重复返回通知到达时")

	# 单人战斗会先移除 runtime 再揭示路线；同一 API 也必须稳定恢复。
	route.set_route_presentation_enabled(false)
	combat_runtime.show()
	combat_camera.make_current()
	combat_camera.force_update_scroll()
	route.remove_child(combat_runtime)
	combat_runtime.free()
	route.set_route_presentation_enabled(true)
	await physics_frame
	await process_frame
	_expect_route_camera_and_canvas(route, "战场已释放时")

	route.queue_free()
	await process_frame
	await process_frame
	if failures.is_empty():
		print("ROGUE_ROUTE_COMBAT_CAMERA_HANDOFF_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect_route_camera_and_canvas(
	route: RogueRouteGame,
	context: String
) -> void:
	var camera := route.map_camera
	var viewport := route.get_viewport()
	var viewport_center := route.get_viewport_rect().size * 0.5
	var canvas_world_center := (
		viewport.get_canvas_transform().affine_inverse() * viewport_center
	)
	var camera_center := camera.get_screen_center_position()
	_expect(
		camera.enabled
		and camera.get_parent() == route.player
		and viewport.get_camera_2d() == camera
		and canvas_world_center.distance_to(camera_center) <= 0.51
		and not canvas_world_center.is_equal_approx(Vector2(128.0, 128.0)),
		(
			"%s必须让路线相机成为 current，并立即清除战斗相机 (128,128) 的 Canvas 变换。"
			% context
		)
	)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
