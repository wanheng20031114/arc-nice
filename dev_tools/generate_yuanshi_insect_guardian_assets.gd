@tool
extends SceneTree

const SOURCE_PATH := "res://resources/texture/enemy/yuanshi_insect/源石虫.png"
const OUTPUT_PATH := "res://resources/texture/enemy/yuanshi_insect/yuanshi_insect_guardian.png"
const FRAME_SIZE := Vector2i(32, 32)
const SHEET_SIZE := Vector2i(96, 64)

const TRANSPARENT := Color(0, 0, 0, 0)
const OUTLINE := Color8(17, 13, 17, 255)
const DEEP_BLUE_SHADOW := Color8(21, 31, 42, 255)
const BLUE_SHELL := Color8(38, 70, 89, 255)
const SKY := Color8(20, 197, 255, 255)
const SKY_LIGHT := Color8(113, 232, 255, 255)
const SKY_WHITE := Color8(220, 253, 255, 255)
const WARM_UNDERBODY := Color8(139, 78, 36, 255)
const DARK_UNDERBODY := Color8(69, 42, 30, 255)
const DEATH_SMOKE := Color8(39, 39, 43, 170)

const MOVE_SOURCE_Y := 96
const DEATH_SOURCE_Y := 160


func _init() -> void:
	var source_texture := load(SOURCE_PATH) as Texture2D
	if source_texture == null:
		push_error("Failed to load source Yuanshi insect texture.")
		quit(1)
		return
	var source := source_texture.get_image()

	var output := Image.create(SHEET_SIZE.x, SHEET_SIZE.y, false, Image.FORMAT_RGBA8)
	output.fill(TRANSPARENT)

	for frame_index in range(3):
		_draw_guardian_frame(source, output, frame_index, false)
	for frame_index in range(3):
		_draw_guardian_frame(source, output, frame_index, true)

	var save_error := output.save_png(OUTPUT_PATH)
	if save_error != OK:
		push_error("Failed to save guardian sprite sheet: %s" % error_string(save_error))
		quit(1)
		return

	print("YUANSHI_INSECT_GUARDIAN_ASSET_GENERATED")
	quit()


func _draw_guardian_frame(source: Image, output: Image, frame_index: int, death: bool) -> void:
	var source_origin := Vector2i(frame_index * FRAME_SIZE.x, DEATH_SOURCE_Y if death else MOVE_SOURCE_Y)
	var target_origin := Vector2i(frame_index * FRAME_SIZE.x, FRAME_SIZE.y if death else 0)

	for y in range(FRAME_SIZE.y):
		for x in range(FRAME_SIZE.x):
			var source_color := source.get_pixelv(source_origin + Vector2i(x, y))
			if source_color.a <= 0.0:
				continue
			var target_color := _guardian_color(source_color, death)
			output.set_pixelv(target_origin + Vector2i(x, y), target_color)

	if death:
		_draw_death_glow(output, target_origin, frame_index)
	else:
		_draw_shell_glow(output, target_origin, frame_index)
		_draw_guardian_shell_rim(output, target_origin, frame_index)


func _guardian_color(source_color: Color, death: bool) -> Color:
	var value := maxf(source_color.r, maxf(source_color.g, source_color.b))
	var chroma_warm := source_color.r - source_color.b

	if death:
		if value < 0.18:
			return Color(OUTLINE, source_color.a)
		if value > 0.58:
			return Color(SKY_LIGHT, source_color.a)
		if chroma_warm > 0.12:
			return Color(DEATH_SMOKE, source_color.a)
		return Color(BLUE_SHELL, source_color.a)

	if value < 0.16:
		return Color(OUTLINE, source_color.a)
	if value > 0.72:
		return Color(SKY_LIGHT, source_color.a)
	if chroma_warm > 0.18 and source_color.g > 0.18:
		return Color(WARM_UNDERBODY, source_color.a)
	if chroma_warm > 0.08:
		return Color(DARK_UNDERBODY, source_color.a)
	if source_color.b > source_color.r:
		return Color(BLUE_SHELL, source_color.a)
	return Color(DEEP_BLUE_SHADOW, source_color.a)


func _draw_shell_glow(image: Image, origin: Vector2i, frame_index: int) -> void:
	var y_offset := 1 if frame_index == 1 else 0
	var points: Array[Vector2i] = [
		Vector2i(10, 12 + y_offset),
		Vector2i(14, 10 + y_offset),
		Vector2i(18, 12 + y_offset),
		Vector2i(21, 15 + y_offset),
		Vector2i(12, 17 + y_offset),
	]
	for point_index in range(points.size()):
		var point: Vector2i = origin + points[point_index]
		_set_pixel(image, point, SKY if point_index % 2 == 0 else SKY_LIGHT)
		if point_index < 3:
			_set_pixel(image, point + Vector2i(1, 0), SKY_WHITE)

	_draw_line(image, origin + Vector2i(10, 14 + y_offset), origin + Vector2i(20, 14 + y_offset), SKY)
	_draw_line(image, origin + Vector2i(15, 10 + y_offset), origin + Vector2i(15, 18 + y_offset), SKY_LIGHT)


func _draw_guardian_shell_rim(image: Image, origin: Vector2i, frame_index: int) -> void:
	var y_offset := 1 if frame_index == 1 else 0
	_draw_line(image, origin + Vector2i(6, 17 + y_offset), origin + Vector2i(11, 21 + y_offset), BLUE_SHELL)
	_draw_line(image, origin + Vector2i(20, 10 + y_offset), origin + Vector2i(25, 13 + y_offset), BLUE_SHELL)
	_set_pixel(image, origin + Vector2i(24, 14 + y_offset), SKY_WHITE)


func _draw_death_glow(image: Image, origin: Vector2i, frame_index: int) -> void:
	match frame_index:
		0:
			_draw_line(image, origin + Vector2i(9, 13), origin + Vector2i(22, 19), SKY_WHITE)
			_draw_line(image, origin + Vector2i(16, 10), origin + Vector2i(13, 23), SKY)
		1:
			_set_pixel(image, origin + Vector2i(11, 18), SKY_LIGHT)
			_set_pixel(image, origin + Vector2i(19, 15), SKY)
			_set_pixel(image, origin + Vector2i(22, 21), SKY_WHITE)
		_:
			_set_pixel(image, origin + Vector2i(13, 23), SKY)
			_set_pixel(image, origin + Vector2i(20, 22), SKY_LIGHT)


func _draw_line(image: Image, from: Vector2i, to: Vector2i, color: Color) -> void:
	var delta := to - from
	var steps := maxi(absi(delta.x), absi(delta.y))
	if steps == 0:
		_set_pixel(image, from, color)
		return

	for step in range(steps + 1):
		var t := float(step) / float(steps)
		var position := Vector2i(roundi(lerpf(from.x, to.x, t)), roundi(lerpf(from.y, to.y, t)))
		_set_pixel(image, position, color)


func _set_pixel(image: Image, position: Vector2i, color: Color) -> void:
	if position.x < 0 or position.y < 0:
		return
	if position.x >= image.get_width() or position.y >= image.get_height():
		return
	var existing := image.get_pixelv(position)
	if existing.a <= 0.0:
		return
	image.set_pixelv(position, color)
