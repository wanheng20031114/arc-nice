extends SceneTree

const ROUTE_SCENE := preload("res://scene/test_arena/test_rogue_route_p3.tscn")
const PREVIEW_PATH := "user://rogue_route_p3_preview.png"
const PREVIEW_SIZE := Vector2i(1280, 720)
const FIXED_SEED := 424242


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	DisplayServer.window_set_size(PREVIEW_SIZE)
	await process_frame
	var route := ROUTE_SCENE.instantiate() as TestRogueRouteP3
	if route == null:
		push_error("无法实例化 P3 路线视觉测试场景。")
		quit(1)
		return
	route.initial_generation_seed = FIXED_SEED
	root.add_child(route)
	current_scene = route
	for _frame in range(6):
		await process_frame
	if not route.is_route_ready():
		push_error("P3 路线视觉测试等待后仍未就绪。")
		quit(1)
		return
	var preview := root.get_texture().get_image()
	if preview == null or preview.is_empty():
		push_error("当前显示驱动无法读取 P3 路线视觉预览。")
		quit(1)
		return
	var absolute_path := ProjectSettings.globalize_path(PREVIEW_PATH)
	var save_error := preview.save_png(absolute_path)
	if save_error != OK:
		push_error("无法保存 P3 路线视觉预览：%s" % error_string(save_error))
		quit(1)
		return
	print("ROGUE_ROUTE_VISUAL_TEST_OK seed=%d path=%s" % [FIXED_SEED, absolute_path])
	current_scene = null
	route.queue_free()
	await process_frame
	quit(0)
