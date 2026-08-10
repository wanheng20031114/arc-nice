extends SceneTree

const PREVIEW_SCENE := preload(
	"res://dev_tools/visual_prototypes/underground_shop/underground_shop_preview.tscn"
)
const VIEWPORT_SIZE := Vector2i(1152, 648)
const OUTPUT_DIRECTORY := "res://dev_tools/output/underground_shop"


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	root.content_scale_size = VIEWPORT_SIZE
	root.size = VIEWPORT_SIZE
	if DisplayServer.get_name() != "headless":
		DisplayServer.window_set_size(VIEWPORT_SIZE)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT_DIRECTORY))

	var preview := PREVIEW_SCENE.instantiate() as Control
	if preview == null:
		push_error("无法实例化地下商店拼装预览。")
		quit(1)
		return
	root.add_child(preview)
	current_scene = preview
	for _frame in range(6):
		await process_frame
	var shop_view := preview.get_node("ShopView") as RogueUndergroundShopView
	shop_view.xiaocong_dialogue_bubble.finish_line()
	await process_frame
	if not await _capture("underground_shop_assembly.png"):
		_finish(preview, 1)
		return
	preview.call("open_offer", 0)
	for _frame in range(3):
		await process_frame
	if not await _capture("underground_shop_detail.png"):
		_finish(preview, 1)
		return
	_finish(preview, 0)


func _capture(file_name: String) -> bool:
	await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	if image == null or image.is_empty():
		push_error("当前显示驱动无法读取地下商店预览帧。")
		return false
	if bool(ProjectSettings.get_setting("rendering/viewport/hdr_2d", false)):
		if image.get_format() not in [Image.FORMAT_RGB8, Image.FORMAT_RGBA8]:
			image.convert(Image.FORMAT_RGBA8)
		image.linear_to_srgb()
	var output_path := "%s/%s" % [OUTPUT_DIRECTORY, file_name]
	var error := image.save_png(ProjectSettings.globalize_path(output_path))
	if error != OK:
		push_error("无法保存地下商店视觉预览：%s" % error_string(error))
		return false
	print("ROGUE_UNDERGROUND_SHOP_CAPTURE path=%s" % ProjectSettings.globalize_path(output_path))
	return true


func _finish(preview: Control, exit_code: int) -> void:
	current_scene = null
	root.remove_child(preview)
	preview.free()
	quit(exit_code)
