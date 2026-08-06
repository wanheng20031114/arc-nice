extends SceneTree

const ROUTE_SCENE := preload("res://scene/game_modes/rogue/route/rogue_route_game.tscn")
const PREVIEW_PATH := "user://rogue_route_p3_preview.png"
const PREVIEW_SIZE := Vector2i(1280, 720)
const FIXED_SEED := 424242


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	DisplayServer.window_set_size(PREVIEW_SIZE)
	await process_frame
	var route := ROUTE_SCENE.instantiate() as RogueRouteGame
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
	# 项目启用了 HDR 2D；视口读回值处于线性空间，PNG 预览需要转回
	# sRGB 才能与玩家实际看到的亮度一致。
	if bool(ProjectSettings.get_setting("rendering/viewport/hdr_2d", false)):
		if preview.get_format() not in [Image.FORMAT_RGB8, Image.FORMAT_RGBA8]:
			preview.convert(Image.FORMAT_RGBA8)
		preview.linear_to_srgb()
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
