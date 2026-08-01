extends SceneTree

const GROUND_PATH := "res://resources/texture/rogue_route/world_ground_tile.png"
const LINK_PATH := "res://resources/texture/rogue_route/route_link_tile.png"
const FRAME_PATH := "res://resources/texture/rogue_route/hud_panel_frame.png"
const HUD_ICON_PATHS := [
	"res://resources/texture/rogue_route/hud_ap_icon.png",
	"res://resources/texture/rogue_route/hud_seed_icon.png",
	"res://resources/texture/rogue_route/hud_location_icon.png",
]
const SOURCE_IGNORE_PATH := (
	"res://dev_tools/generated_sources/rogue_route_p3_world/.gdignore"
)

var failures: Array[String] = []


func _init() -> void:
	var ground := _load_and_audit(GROUND_PATH, Vector2i(32, 32), 8, false)
	var link := _load_and_audit(LINK_PATH, Vector2i(16, 8), 8, true)
	var frame := _load_and_audit(FRAME_PATH, Vector2i(32, 32), 8, true)
	for icon_path in HUD_ICON_PATHS:
		_load_and_audit(str(icon_path), Vector2i(12, 12), 8, true)
	if ground != null:
		_expect(_opposite_edges_match(ground), "地面纹理必须逐像素无缝平铺。")
	if link != null:
		_expect(_horizontal_edges_match(link), "路线纹理左右端必须逐像素接续。")
	if frame != null:
		_expect(
			frame.get_pixel(16, 16).a <= 0.001,
			"NinePatch HUD 外框中心必须保持透明。"
		)
	_expect(FileAccess.file_exists(SOURCE_IGNORE_PATH), "imagegen 母素材目录必须由 .gdignore 隔离。")

	if failures.is_empty():
		print("ROGUE_ROUTE_WORLD_ASSET_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _load_and_audit(
	path: String,
	expected_size: Vector2i,
	max_colors: int,
	require_binary_alpha: bool
) -> Image:
	var image := Image.new()
	var error := image.load(ProjectSettings.globalize_path(path))
	if error != OK:
		failures.append("无法读取 P3 世界素材 %s：%s" % [path, error_string(error)])
		return null
	_expect(image.get_size() == expected_size, "%s 必须为 %s。" % [path, expected_size])
	var palette: Dictionary[int, bool] = {}
	var partial_alpha_count := 0
	for y in range(image.get_height()):
		for x in range(image.get_width()):
			var pixel := image.get_pixel(x, y)
			var alpha_byte := roundi(pixel.a * 255.0)
			if alpha_byte > 0 and alpha_byte < 255:
				partial_alpha_count += 1
			palette[pixel.to_rgba32()] = true
	_expect(palette.size() <= max_colors, "%s 色板不得超过 %d 色。" % [path, max_colors])
	if require_binary_alpha:
		_expect(partial_alpha_count == 0, "%s 不得包含半透明毛边。" % path)
	return image


func _opposite_edges_match(image: Image) -> bool:
	for y in range(image.get_height()):
		if image.get_pixel(0, y) != image.get_pixel(image.get_width() - 1, y):
			return false
	for x in range(image.get_width()):
		if image.get_pixel(x, 0) != image.get_pixel(x, image.get_height() - 1):
			return false
	return true


func _horizontal_edges_match(image: Image) -> bool:
	for y in range(image.get_height()):
		if image.get_pixel(0, y) != image.get_pixel(image.get_width() - 1, y):
			return false
	return true


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
