extends SceneTree

const PROJECTILE_OUTPUT_PATH := "res://resources/texture/player/weishidaier/skill1_projectile.png"
const EXPLOSION_OUTPUT_PATH := "res://resources/texture/player/weishidaier/skill1_explosion.png"

const PROJECTILE_FRAME_SIZE := Vector2i(16, 12)
const PROJECTILE_FRAME_COUNT := 4
const EXPLOSION_FRAME_SIZE := Vector2i(96, 96)
const EXPLOSION_FRAME_COUNT := 8


func _init() -> void:
	var projectile_error := _build_projectile_sheet().save_png(PROJECTILE_OUTPUT_PATH)
	var explosion_error := _build_explosion_sheet().save_png(EXPLOSION_OUTPUT_PATH)
	if projectile_error != OK or explosion_error != OK:
		push_error(
			"Skill1 asset generation failed: projectile=%s explosion=%s"
			% [projectile_error, explosion_error]
		)
		quit(1)
		return

	print("Generated Weishidaier skill1 projectile and explosion assets.")
	quit()


func _build_projectile_sheet() -> Image:
	var sheet := Image.create(
		PROJECTILE_FRAME_SIZE.x * PROJECTILE_FRAME_COUNT,
		PROJECTILE_FRAME_SIZE.y,
		false,
		Image.FORMAT_RGBA8
	)
	sheet.fill(Color.TRANSPARENT)
	for frame_index in range(PROJECTILE_FRAME_COUNT):
		_draw_projectile_frame(sheet, frame_index)
	return sheet


func _draw_projectile_frame(sheet: Image, frame_index: int) -> void:
	var offset_x := frame_index * PROJECTILE_FRAME_SIZE.x
	var smoke_shift := frame_index % 2
	var outline := Color8(74, 48, 38, 255)
	var shell := Color8(232, 226, 211, 255)
	var shell_shadow := Color8(166, 136, 116, 255)
	var ember := Color8(239, 87, 32, 255)
	var hot := Color8(255, 193, 69, 255)
	var core := Color8(255, 245, 176, 255)
	var smoke := Color8(102, 98, 88, 150)
	var smoke_dark := Color8(67, 66, 62, 120)

	_plot(sheet, offset_x + 0, 5 + smoke_shift, smoke_dark)
	_plot(sheet, offset_x + 1, 4 + smoke_shift, smoke)
	_plot(sheet, offset_x + 1, 6 + smoke_shift, smoke)
	_plot(sheet, offset_x + 2, 5, smoke)
	_plot(sheet, offset_x + 3, 4, ember)
	_plot(sheet, offset_x + 3, 5, hot)
	_plot(sheet, offset_x + 3, 6, ember)
	_plot(sheet, offset_x + 4, 5, core)

	var body_pixels := {
		Vector2i(5, 4): outline,
		Vector2i(5, 5): shell_shadow,
		Vector2i(5, 6): outline,
		Vector2i(6, 3): outline,
		Vector2i(6, 4): shell,
		Vector2i(6, 5): shell,
		Vector2i(6, 6): shell_shadow,
		Vector2i(6, 7): outline,
		Vector2i(7, 3): outline,
		Vector2i(7, 4): shell,
		Vector2i(7, 5): shell,
		Vector2i(7, 6): shell_shadow,
		Vector2i(7, 7): outline,
		Vector2i(8, 3): outline,
		Vector2i(8, 4): shell,
		Vector2i(8, 5): core,
		Vector2i(8, 6): shell,
		Vector2i(8, 7): outline,
		Vector2i(9, 4): outline,
		Vector2i(9, 5): shell,
		Vector2i(9, 6): outline,
		Vector2i(10, 4): outline,
		Vector2i(10, 5): hot,
		Vector2i(10, 6): outline,
		Vector2i(11, 5): ember,
		Vector2i(12, 5): hot,
	}
	for local_position in body_pixels:
		_plot(sheet, offset_x + local_position.x, local_position.y, body_pixels[local_position])

	if frame_index == 1 or frame_index == 3:
		_plot(sheet, offset_x + 13, 5, ember)
	if frame_index == 2:
		_plot(sheet, offset_x + 2, 3, smoke_dark)
		_plot(sheet, offset_x + 13, 4, hot)
		_plot(sheet, offset_x + 13, 6, hot)


func _build_explosion_sheet() -> Image:
	var sheet := Image.create(
		EXPLOSION_FRAME_SIZE.x * EXPLOSION_FRAME_COUNT,
		EXPLOSION_FRAME_SIZE.y,
		false,
		Image.FORMAT_RGBA8
	)
	sheet.fill(Color.TRANSPARENT)

	var radii := [12, 22, 34, 43, 44, 37, 26, 14]
	for frame_index in range(EXPLOSION_FRAME_COUNT):
		_draw_explosion_frame(sheet, frame_index, radii[frame_index])
	return sheet


func _draw_explosion_frame(sheet: Image, frame_index: int, radius: int) -> void:
	var offset_x := frame_index * EXPLOSION_FRAME_SIZE.x
	var center := Vector2i(
		offset_x + EXPLOSION_FRAME_SIZE.x / 2,
		EXPLOSION_FRAME_SIZE.y / 2
	)
	var outline := Color8(84, 35, 24, 255)
	var flame := Color8(216, 63, 25, 255)
	var orange := Color8(249, 122, 36, 255)
	var hot := Color8(255, 198, 61, 255)
	var core := Color8(255, 244, 174, 255)
	var smoke := Color8(111, 102, 87, 155)
	var smoke_dark := Color8(69, 65, 61, 130)

	if frame_index >= 5:
		_draw_pixel_disc(sheet, center, radius, smoke_dark, 0.9)
		_draw_pixel_disc(sheet, center, maxi(radius - 5, 1), smoke, 0.74)
		_draw_pixel_disc(sheet, center, maxi(radius - 11, 1), orange, 0.62)
	else:
		_draw_pixel_disc(sheet, center, radius, outline, 1.0)
		_draw_pixel_disc(sheet, center, maxi(radius - 4, 1), flame, 0.94)
		_draw_pixel_disc(sheet, center, maxi(radius - 9, 1), orange, 0.9)
		_draw_pixel_disc(sheet, center, maxi(radius - 15, 1), hot, 0.86)
		_draw_pixel_disc(sheet, center, maxi(radius - 22, 1), core, 0.78)

	var rays := [
		Vector2.RIGHT,
		Vector2.LEFT,
		Vector2.UP,
		Vector2.DOWN,
		Vector2(0.72, 0.72).normalized(),
		Vector2(-0.72, 0.72).normalized(),
		Vector2(0.72, -0.72).normalized(),
		Vector2(-0.72, -0.72).normalized(),
	]
	for ray_index in range(rays.size()):
		var ray_length := radius + ((frame_index + ray_index) % 2)
		var ray_position := center + Vector2i((rays[ray_index] * ray_length).round())
		_draw_pixel_block(sheet, ray_position, 2, orange if frame_index < 5 else smoke)
		if frame_index < 4:
			_draw_pixel_block(sheet, center + Vector2i((rays[ray_index] * (ray_length - 4)).round()), 1, hot)


func _draw_pixel_disc(image: Image, center: Vector2i, radius: int, color: Color, density: float) -> void:
	var radius_squared := radius * radius
	var random := RandomNumberGenerator.new()
	random.seed = 0x51EED + radius * 37 + int(color.r8) * 11
	for y in range(center.y - radius, center.y + radius + 1, 2):
		for x in range(center.x - radius, center.x + radius + 1, 2):
			var delta := Vector2i(x, y) - center
			if delta.length_squared() > radius_squared:
				continue
			if random.randf() > density:
				continue
			_draw_pixel_block(image, Vector2i(x, y), 1, color)


func _draw_pixel_block(image: Image, position: Vector2i, half_size: int, color: Color) -> void:
	for y in range(position.y - half_size, position.y + half_size + 1):
		for x in range(position.x - half_size, position.x + half_size + 1):
			_plot(image, x, y, color)


func _plot(image: Image, x: int, y: int, color: Color) -> void:
	if x < 0 or y < 0 or x >= image.get_width() or y >= image.get_height():
		return
	image.set_pixel(x, y, color)
