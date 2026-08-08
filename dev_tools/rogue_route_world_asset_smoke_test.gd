extends SceneTree

const BACKGROUND_PATH := (
	"res://resources/texture/rogue_route/underground_ruins_background.png"
)
const EMPTY_NODE_PATH := (
	"res://resources/texture/rogue_route/nodes/node_empty_ref_v4.png"
)
const HUD_ICON_PATHS := [
	"res://resources/texture/rogue_route/hud_ap_icon.png",
	"res://resources/texture/rogue_route/hud_location_icon.png",
]
const SOURCE_IGNORE_PATH := (
	"res://dev_tools/generated_sources/rogue_route_p3_v2/.gdignore"
)
const BACKGROUND_SIZE := Vector2i(2304, 1296)
const MAX_CENTER_MEAN_LUMINANCE := 0.11
const MAX_CENTER_LUMINANCE_RANGE := 0.20
const EMPTY_NODE_SIZE := Vector2i(128, 128)
const HUD_ICON_SIZE := Vector2i(48, 48)
const MAX_SIMPLE_ICON_RGB_COLORS := 6

var failures: Array[String] = []


func _init() -> void:
	var background := _load_image(BACKGROUND_PATH)
	if background != null:
		_audit_background(background)
	var empty_node := _load_image(EMPTY_NODE_PATH)
	if empty_node != null:
		_expect(
			empty_node.get_size() == EMPTY_NODE_SIZE,
			"%s 必须为 %s。" % [EMPTY_NODE_PATH, EMPTY_NODE_SIZE]
		)
		_expect(_corners_are_transparent(empty_node), "%s 四角必须透明。" % (
			EMPTY_NODE_PATH
		))
	for icon_path in HUD_ICON_PATHS:
		var path := str(icon_path)
		var image := _load_image(path)
		if image != null:
			_audit_simple_transparent_asset(
				image,
				path,
				HUD_ICON_SIZE,
				MAX_SIMPLE_ICON_RGB_COLORS
			)
	_expect(
		FileAccess.file_exists(SOURCE_IGNORE_PATH),
		"新版 imagegen 母素材目录必须由 .gdignore 隔离。"
	)

	if failures.is_empty():
		print("ROGUE_ROUTE_WORLD_ASSET_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _load_image(path: String) -> Image:
	var image := Image.new()
	var error := image.load(ProjectSettings.globalize_path(path))
	if error != OK:
		failures.append("无法读取 P3 世界素材 %s：%s" % [path, error_string(error)])
		return null
	return image


func _audit_background(image: Image) -> void:
	_expect(
		image.get_size() == BACKGROUND_SIZE,
		"%s 必须为 2304×1296。" % BACKGROUND_PATH
	)
	var all_samples_opaque := true
	for y in range(0, image.get_height(), 32):
		for x in range(0, image.get_width(), 32):
			if image.get_pixel(x, y).a < 0.999:
				all_samples_opaque = false
				break
		if not all_samples_opaque:
			break
	_expect(all_samples_opaque, "地下遗址背景必须保持不透明，避免露出清屏色。")

	var center_min_luminance := 1.0
	var center_max_luminance := 0.0
	var center_luminance_sum := 0.0
	var center_sample_count := 0
	for y in range(image.get_height() / 3, image.get_height() * 2 / 3, 16):
		for x in range(image.get_width() / 3, image.get_width() * 2 / 3, 16):
			var pixel := image.get_pixel(x, y)
			var luminance := (
				pixel.r * 0.2126 + pixel.g * 0.7152 + pixel.b * 0.0722
			)
			center_min_luminance = minf(center_min_luminance, luminance)
			center_max_luminance = maxf(center_max_luminance, luminance)
			center_luminance_sum += luminance
			center_sample_count += 1
	var center_mean_luminance := (
		center_luminance_sum / float(center_sample_count)
		if center_sample_count > 0
		else 1.0
	)
	_expect(
		center_max_luminance - center_min_luminance
		<= MAX_CENTER_LUMINANCE_RANGE
		and center_mean_luminance <= MAX_CENTER_MEAN_LUMINANCE,
		"地下遗址中央必须保持低亮度、低对比，为路线节点留出清晰阅读区。"
	)


func _audit_simple_transparent_asset(
	image: Image,
	path: String,
	expected_size: Vector2i,
	max_rgb_colors: int
) -> void:
	_expect(image.get_size() == expected_size, "%s 必须为 %s。" % [path, expected_size])
	_expect(_corners_are_transparent(image), "%s 四角必须透明。" % path)
	var rgb_palette: Dictionary[int, bool] = {}
	var visible_pixels := 0
	for y in range(image.get_height()):
		for x in range(image.get_width()):
			var pixel := image.get_pixel(x, y)
			if pixel.a <= 0.001:
				continue
			visible_pixels += 1
			rgb_palette[_rgb_key(pixel)] = true
	_expect(visible_pixels > 0, "%s 必须包含可见主体。" % path)
	_expect(
		rgb_palette.size() <= max_rgb_colors,
		"%s 的可见 RGB 色不得超过 %d 色。" % [path, max_rgb_colors]
	)


func _corners_are_transparent(image: Image) -> bool:
	var last_x := image.get_width() - 1
	var last_y := image.get_height() - 1
	return (
		image.get_pixel(0, 0).a <= 0.001
		and image.get_pixel(last_x, 0).a <= 0.001
		and image.get_pixel(0, last_y).a <= 0.001
		and image.get_pixel(last_x, last_y).a <= 0.001
	)


func _rgb_key(pixel: Color) -> int:
	return (
		(roundi(pixel.r * 255.0) << 16)
		| (roundi(pixel.g * 255.0) << 8)
		| roundi(pixel.b * 255.0)
	)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
