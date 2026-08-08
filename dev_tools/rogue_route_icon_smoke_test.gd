extends SceneTree

## 内容节点采用最终选定的 128×128 完整节点图；锁定透明边缘和像素预算。

const CONTENT_ICON_PATHS := [
	"res://resources/texture/rogue_route/nodes/node_magical_encounter_b_ref_v3.png",
	"res://resources/texture/rogue_route/nodes/node_emergency_combat_a_ref_v3.png",
	"res://resources/texture/rogue_route/nodes/node_normal_combat_b_ref_v3.png",
	"res://resources/texture/rogue_route/nodes/node_wilderness_resource_ref_v3.png",
	"res://resources/texture/rogue_route/nodes/node_black_market_b_ref_v3.png",
	"res://resources/texture/rogue_route/nodes/node_gift_b_ref_v3.png",
]
const PARTY_MARKER_PATH := "res://resources/texture/rogue_route/party_marker.png"
const CONTENT_ICON_SIZE := Vector2i(128, 128)
const PARTY_MARKER_SIZE := Vector2i(16, 16)
const MAX_PARTY_MARKER_COLORS := 8
const MAX_PARTY_MARKER_VISIBLE_PIXELS := 192
const MIN_CONTENT_BOUNDS := Vector2i(112, 112)
const MAX_CONTENT_BOUNDS := Vector2i(124, 124)
const MIN_CONTENT_MARGIN := 2


func _init() -> void:
	var failures := PackedStringArray()
	for icon_path in CONTENT_ICON_PATHS:
		_audit_content_icon(str(icon_path), failures)
	_audit_party_marker(failures)
	if not failures.is_empty():
		for failure in failures:
			push_error(failure)
		quit(1)
		return
	print("ROGUE_ROUTE_ICON_SMOKE_TEST_OK content=%d size=128x128" % (
		CONTENT_ICON_PATHS.size()
	))
	quit(0)


func _audit_content_icon(
	icon_path: String,
	failures: PackedStringArray
) -> void:
	var image := _load_icon(icon_path, failures)
	if image == null:
		return
	if image.get_size() != CONTENT_ICON_SIZE:
		failures.append(
			"内容节点图标必须为 128×128：%s 当前为 %s"
			% [icon_path, image.get_size()]
		)
		return
	if not _corners_are_transparent(image):
		failures.append("内容节点图标四角必须透明：%s" % icon_path)

	var visible_bounds := Rect2i()
	var has_visible_pixel := false
	for y in range(image.get_height()):
		for x in range(image.get_width()):
			var pixel := image.get_pixel(x, y)
			if pixel.a <= 0.001:
				continue
			var point_rect := Rect2i(x, y, 1, 1)
			visible_bounds = (
				visible_bounds.merge(point_rect)
				if has_visible_pixel
				else point_rect
			)
			has_visible_pixel = true
	if not has_visible_pixel:
		failures.append("内容节点图标必须包含可见主体：%s" % icon_path)
		return
	var right_margin := image.get_width() - visible_bounds.end.x
	var bottom_margin := image.get_height() - visible_bounds.end.y
	if (
		visible_bounds.size.x < MIN_CONTENT_BOUNDS.x
		or visible_bounds.size.y < MIN_CONTENT_BOUNDS.y
		or visible_bounds.size.x > MAX_CONTENT_BOUNDS.x
		or visible_bounds.size.y > MAX_CONTENT_BOUNDS.y
	):
		failures.append(
			"内容节点图标主体大小不合理：%s 可见包围盒为 %s"
			% [icon_path, visible_bounds]
		)
	if (
		visible_bounds.position.x < MIN_CONTENT_MARGIN
		or visible_bounds.position.y < MIN_CONTENT_MARGIN
		or right_margin < MIN_CONTENT_MARGIN
		or bottom_margin < MIN_CONTENT_MARGIN
	):
		failures.append(
			"内容节点图标必须在透明画布内留白：%s 包围盒为 %s"
			% [icon_path, visible_bounds]
		)


func _audit_party_marker(failures: PackedStringArray) -> void:
	var image := _load_icon(PARTY_MARKER_PATH, failures)
	if image == null:
		return
	if image.get_size() != PARTY_MARKER_SIZE:
		failures.append(
			"队伍标记必须继续保持 16×16：当前为 %s" % image.get_size()
		)
		return
	var visible_pixels := 0
	var partial_alpha_pixels := 0
	var palette: Dictionary[int, bool] = {}
	for y in range(image.get_height()):
		for x in range(image.get_width()):
			var pixel := image.get_pixel(x, y)
			var alpha_byte := roundi(pixel.a * 255.0)
			if alpha_byte == 0:
				continue
			visible_pixels += 1
			if alpha_byte != 255:
				partial_alpha_pixels += 1
			palette[pixel.to_rgba32()] = true
	if visible_pixels <= 0 or visible_pixels > MAX_PARTY_MARKER_VISIBLE_PIXELS:
		failures.append("队伍标记可见像素超出预算：%d" % visible_pixels)
	if partial_alpha_pixels != 0:
		failures.append("队伍标记仍应使用硬边像素 alpha。")
	if palette.size() > MAX_PARTY_MARKER_COLORS:
		failures.append("队伍标记色板超出预算：%d 色" % palette.size())


func _load_icon(
	icon_path: String,
	failures: PackedStringArray
) -> Image:
	var image := Image.new()
	var load_error := image.load(ProjectSettings.globalize_path(icon_path))
	if load_error != OK:
		failures.append(
			"无法读取路线图标 %s：%s" % [icon_path, error_string(load_error)]
		)
		return null
	return image


func _corners_are_transparent(image: Image) -> bool:
	var last_x := image.get_width() - 1
	var last_y := image.get_height() - 1
	return (
		image.get_pixel(0, 0).a <= 0.001
		and image.get_pixel(last_x, 0).a <= 0.001
		and image.get_pixel(0, last_y).a <= 0.001
		and image.get_pixel(last_x, last_y).a <= 0.001
	)
