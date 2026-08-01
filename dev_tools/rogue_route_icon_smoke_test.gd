extends SceneTree

## 锁定 P3 路线图标的低像素预算，避免后续误换回高分辨率或半透明素材。

const ICON_PATHS := [
	"res://resources/texture/rogue_route/magical_encounter.png",
	"res://resources/texture/rogue_route/emergency_combat.png",
	"res://resources/texture/rogue_route/normal_combat.png",
	"res://resources/texture/rogue_route/wilderness_resource.png",
	"res://resources/texture/rogue_route/mystery_black_market.png",
	"res://resources/texture/rogue_route/prepare_ahead.png",
	"res://resources/texture/rogue_route/party_marker.png",
]
const REQUIRED_SIZE := Vector2i(16, 16)
const MAX_VISIBLE_PIXELS := 192
const MAX_PALETTE_COLORS := 8


func _init() -> void:
	var failures := PackedStringArray()
	for icon_path in ICON_PATHS:
		_audit_icon(str(icon_path), failures)
	if not failures.is_empty():
		for failure in failures:
			push_error(failure)
		quit(1)
		return
	print("ROGUE_ROUTE_ICON_SMOKE_TEST_OK icons=%d size=16x16 max_colors=%d" % [
		ICON_PATHS.size(),
		MAX_PALETTE_COLORS,
	])
	quit(0)


func _audit_icon(icon_path: String, failures: PackedStringArray) -> void:
	var image := Image.new()
	var absolute_path := ProjectSettings.globalize_path(icon_path)
	var load_error := image.load(absolute_path)
	if load_error != OK:
		failures.append("无法读取路线图标 %s：%s" % [icon_path, error_string(load_error)])
		return
	if image.get_size() != REQUIRED_SIZE:
		failures.append("路线图标必须为 16×16：%s 当前为 %s" % [icon_path, image.get_size()])
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
	if visible_pixels <= 0 or visible_pixels > MAX_VISIBLE_PIXELS:
		failures.append("路线图标可见像素超出预算：%s 为 %d" % [icon_path, visible_pixels])
	if partial_alpha_pixels != 0:
		failures.append("路线图标不得包含半透明毛边：%s 有 %d 像素" % [icon_path, partial_alpha_pixels])
	if palette.size() > MAX_PALETTE_COLORS:
		failures.append("路线图标色板超出预算：%s 为 %d 色" % [icon_path, palette.size()])
