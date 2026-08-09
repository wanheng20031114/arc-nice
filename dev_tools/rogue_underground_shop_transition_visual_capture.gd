extends SceneTree

const PREVIEW_SCENE := preload(
	"res://dev_tools/visual_prototypes/underground_shop/underground_shop_transition_preview.tscn"
)
const VIEWPORT_SIZE := Vector2i(1280, 720)
const FOUR_THREE_SIZE := Vector2i(960, 720)
const OUTPUT_DIRECTORY := "res://dev_tools/output/underground_shop"


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	root.content_scale_size = VIEWPORT_SIZE
	root.size = VIEWPORT_SIZE
	DisplayServer.window_set_size(VIEWPORT_SIZE)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT_DIRECTORY))
	var preview := PREVIEW_SCENE.instantiate() as Control
	if preview == null:
		push_error("无法实例化地下商店菱形转场预览。")
		quit(1)
		return
	root.add_child(preview)
	current_scene = preview
	var transition := preview.get_node("Transition") as RogueUndergroundShopTransition
	for _frame in range(6):
		await process_frame
	transition.visible = true
	transition.call("_set_reveal_phase", false)
	transition.call("_set_progress", 0.5)
	for _frame in range(2):
		await process_frame
	if not await _capture("diamond_cover_mid"):
		_finish(preview, 1)
		return
	transition.call("_set_progress", 1.0)
	for _frame in range(2):
		await process_frame
	if not await _capture("diamond_cover_full"):
		_finish(preview, 1)
		return
	transition.call("_set_reveal_phase", true)
	transition.call("_set_progress", 0.5)
	for _frame in range(2):
		await process_frame
	if not await _capture("diamond_reveal_mid"):
		_finish(preview, 1)
		return
	transition.call("_set_progress", 0.0)
	for _frame in range(2):
		await process_frame
	if not await _capture("diamond_reveal_full"):
		_finish(preview, 1)
		return
	root.content_scale_size = FOUR_THREE_SIZE
	root.size = FOUR_THREE_SIZE
	DisplayServer.window_set_size(FOUR_THREE_SIZE)
	transition.visible = true
	transition.call("_set_reveal_phase", false)
	transition.call("_set_progress", 0.5)
	for _frame in range(3):
		await process_frame
	if not await _capture("diamond_cover_mid_960x720"):
		_finish(preview, 1)
		return
	_finish(preview, 0)


func _capture(stem: String) -> bool:
	await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	if image == null or image.is_empty():
		push_error("当前显示驱动无法读取地下商店转场帧。")
		return false
	if image.get_format() not in [Image.FORMAT_RGB8, Image.FORMAT_RGBA8]:
		image.convert(Image.FORMAT_RGBA8)
		image.linear_to_srgb()
	var renderer := RenderingServer.get_current_rendering_method()
	var output_path := "%s/%s_%s.png" % [OUTPUT_DIRECTORY, stem, renderer]
	var error := image.save_png(ProjectSettings.globalize_path(output_path))
	if error != OK:
		push_error("无法保存地下商店转场预览：%s" % error_string(error))
		return false
	print("ROGUE_UNDERGROUND_SHOP_TRANSITION_CAPTURE path=%s" % ProjectSettings.globalize_path(output_path))
	return true


func _finish(preview: Control, exit_code: int) -> void:
	current_scene = null
	root.remove_child(preview)
	preview.free()
	quit(exit_code)
