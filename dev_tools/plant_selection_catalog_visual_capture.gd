extends SceneTree

const HUD_SCENE := preload(
	"res://scene/game_modes/tower_defense/ui/plant_selection/plant_selection_hud.tscn"
)
const CONTENT_SIZE := Vector2i(1152, 648)
const OUTPUT_SIZE := Vector2i(1920, 1080)
const OUTPUT_DIRECTORY := "res://dev_tools/output/plant_selection_catalog"
const OUTPUT_FILE := "catalog_compact_1920x1080.png"


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("建筑部署目录视觉捕获必须使用图形显示驱动运行。")
		quit(2)
		return
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
	root.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_EXPAND
	root.content_scale_size = CONTENT_SIZE
	root.size = OUTPUT_SIZE
	DisplayServer.window_set_size(OUTPUT_SIZE)
	DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path(OUTPUT_DIRECTORY)
	)

	var hud := HUD_SCENE.instantiate() as PlantSelectionHUD
	if hud == null:
		push_error("无法实例化建筑部署目录。")
		quit(1)
		return
	root.add_child(hud)
	var item_counts := {
		PlantDefenseRegistry.AGAVE_CANNON_ID: 3,
		PlantDefenseRegistry.LIFE_TOWER_ID: 2,
		PlantDefenseRegistry.PLANTING_BASE_ID: 2,
		PlantDefenseRegistry.SIMPLE_FENCE_ID: 4,
		PlantDefenseRegistry.OAK_WAREHOUSE_ID: 1,
	}
	if not hud.open(PlantDefenseRegistry.get_all_configs(), item_counts, false):
		push_error("无法打开建筑部署目录。")
		_finish(hud, 1)
		return
	for _frame in range(20):
		await process_frame
	await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	if image == null or image.is_empty():
		push_error("当前显示驱动无法读取建筑部署目录预览帧。")
		_finish(hud, 1)
		return
	if bool(ProjectSettings.get_setting("rendering/viewport/hdr_2d", false)):
		if image.get_format() not in [Image.FORMAT_RGB8, Image.FORMAT_RGBA8]:
			image.convert(Image.FORMAT_RGBA8)
		image.linear_to_srgb()
	var output_path := "%s/%s" % [OUTPUT_DIRECTORY, OUTPUT_FILE]
	var save_error := image.save_png(ProjectSettings.globalize_path(output_path))
	if save_error != OK:
		push_error("无法保存建筑部署目录预览：%s" % error_string(save_error))
		_finish(hud, 1)
		return
	print("PLANT_SELECTION_CATALOG_CAPTURE path=%s" % ProjectSettings.globalize_path(output_path))
	_finish(hud, 0)


func _finish(hud: PlantSelectionHUD, exit_code: int) -> void:
	if is_instance_valid(hud):
		root.remove_child(hud)
		hud.free()
	quit(exit_code)
