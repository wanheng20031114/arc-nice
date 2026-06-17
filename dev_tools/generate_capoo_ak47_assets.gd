@tool
extends SceneTree

const ENEMY_OUTPUT_PATH := "res://resources/texture/capoo_ak47.png"
const BULLET_OUTPUT_PATH := "res://resources/texture/capoo_ak47_bullet.png"
const FRAME_SIZE := Vector2i(32, 32)
const ENEMY_SHEET_SIZE := Vector2i(128, 128)
const BULLET_FRAME_SIZE := Vector2i(8, 8)
const BULLET_SHEET_SIZE := Vector2i(24, 8)

const TRANSPARENT := Color(0, 0, 0, 0)
const OUTLINE := Color8(24, 22, 24, 255)
const CAPOO_DARK := Color8(28, 132, 164, 255)
const CAPOO_BODY := Color8(51, 191, 224, 255)
const CAPOO_LIGHT := Color8(117, 228, 246, 255)
const CAPOO_SHADOW := Color8(32, 150, 186, 255)
const AK_METAL := Color8(78, 91, 98, 255)
const AK_LIGHT := Color8(150, 170, 176, 255)
const AK_WOOD := Color8(172, 104, 33, 255)
const AK_WOOD_LIGHT := Color8(219, 152, 50, 255)
const HEAT_ORANGE := Color8(255, 126, 30, 255)
const MUZZLE_YELLOW := Color8(255, 230, 79, 255)
const SMOKE := Color8(55, 57, 62, 185)
const BULLET_GOLD := Color8(255, 211, 56, 255)
const BULLET_ORANGE := Color8(255, 126, 25, 210)


func _init() -> void:
	var enemy_sheet := Image.create(ENEMY_SHEET_SIZE.x, ENEMY_SHEET_SIZE.y, false, Image.FORMAT_RGBA8)
	enemy_sheet.fill(TRANSPARENT)

	for frame_index in range(3):
		_draw_enemy_frame(enemy_sheet, Vector2i(frame_index * FRAME_SIZE.x, 0), &"move", frame_index)
	for frame_index in range(4):
		_draw_enemy_frame(enemy_sheet, Vector2i(frame_index * FRAME_SIZE.x, 32), &"windup", frame_index)
	for frame_index in range(4):
		_draw_enemy_frame(enemy_sheet, Vector2i(frame_index * FRAME_SIZE.x, 64), &"attack", frame_index)
	for frame_index in range(3):
		_draw_enemy_frame(enemy_sheet, Vector2i(frame_index * FRAME_SIZE.x, 96), &"death", frame_index)

	var enemy_error := enemy_sheet.save_png(ENEMY_OUTPUT_PATH)
	if enemy_error != OK:
		push_error("Failed to save Capoo AK47 sprite sheet: %s" % error_string(enemy_error))
		quit(1)
		return

	var bullet_sheet := Image.create(BULLET_SHEET_SIZE.x, BULLET_SHEET_SIZE.y, false, Image.FORMAT_RGBA8)
	bullet_sheet.fill(TRANSPARENT)
	for frame_index in range(3):
		_draw_bullet_frame(bullet_sheet, Vector2i(frame_index * BULLET_FRAME_SIZE.x, 0), frame_index)

	var bullet_error := bullet_sheet.save_png(BULLET_OUTPUT_PATH)
	if bullet_error != OK:
		push_error("Failed to save Capoo AK47 bullet sheet: %s" % error_string(bullet_error))
		quit(1)
		return

	print("CAPOO_AK47_ASSETS_GENERATED")
	quit()


func _draw_enemy_frame(image: Image, origin: Vector2i, animation_name: StringName, frame_index: int) -> void:
	var bob := 0
	var recoil := 0
	var heat := 0.0
	var dead := false

	match animation_name:
		&"move":
			bob = 1 if frame_index == 1 else 0
		&"windup":
			heat = float(frame_index + 1) / 4.0
		&"attack":
			recoil = 1 if frame_index % 2 == 1 else 0
			heat = 1.0
		&"death":
			dead = true

	if dead:
		_draw_death_frame(image, origin, frame_index)
		return

	_draw_shadow(image, origin + Vector2i(15, 28), 12, 2)
	_draw_body(image, origin, bob)
	_draw_face(image, origin, bob)
	_draw_ak(image, origin, bob, recoil, heat, animation_name == &"attack" and frame_index % 2 == 0)


func _draw_body(image: Image, origin: Vector2i, bob: int) -> void:
	_draw_filled_ellipse(image, origin + Vector2i(14, 18 + bob), 13, 11, OUTLINE)
	_draw_filled_ellipse(image, origin + Vector2i(14, 18 + bob), 11, 9, CAPOO_BODY)
	_draw_filled_ellipse(image, origin + Vector2i(11, 14 + bob), 6, 4, CAPOO_LIGHT)
	_draw_line(image, origin + Vector2i(4, 18 + bob), origin + Vector2i(2, 20 + bob), CAPOO_SHADOW)
	_draw_line(image, origin + Vector2i(4, 22 + bob), origin + Vector2i(2, 24 + bob), CAPOO_SHADOW)
	_draw_line(image, origin + Vector2i(5, 25 + bob), origin + Vector2i(3, 27 + bob), CAPOO_SHADOW)

	_draw_left_ear(image, origin + Vector2i(5, 6 + bob))
	_draw_right_ear(image, origin + Vector2i(16, 6 + bob))
	_draw_rect(image, origin + Vector2i(8, 28 + bob), Vector2i(4, 2), OUTLINE)
	_draw_rect(image, origin + Vector2i(18, 28 + bob), Vector2i(4, 2), OUTLINE)


func _draw_left_ear(image: Image, base: Vector2i) -> void:
	_draw_line(image, base + Vector2i(0, 6), base + Vector2i(5, 0), OUTLINE)
	_draw_line(image, base + Vector2i(5, 0), base + Vector2i(10, 7), OUTLINE)
	_draw_line(image, base + Vector2i(1, 6), base + Vector2i(9, 7), OUTLINE)
	_draw_line(image, base + Vector2i(3, 5), base + Vector2i(5, 2), CAPOO_LIGHT)
	_draw_line(image, base + Vector2i(5, 2), base + Vector2i(8, 6), CAPOO_BODY)
	_set_pixel(image, base + Vector2i(4, 4), CAPOO_LIGHT)


func _draw_right_ear(image: Image, base: Vector2i) -> void:
	_draw_line(image, base + Vector2i(0, 7), base + Vector2i(6, 0), OUTLINE)
	_draw_line(image, base + Vector2i(6, 0), base + Vector2i(11, 6), OUTLINE)
	_draw_line(image, base + Vector2i(1, 7), base + Vector2i(10, 6), OUTLINE)
	_draw_line(image, base + Vector2i(3, 6), base + Vector2i(6, 2), CAPOO_LIGHT)
	_draw_line(image, base + Vector2i(6, 2), base + Vector2i(9, 5), CAPOO_BODY)
	_set_pixel(image, base + Vector2i(6, 4), CAPOO_LIGHT)


func _draw_face(image: Image, origin: Vector2i, bob: int) -> void:
	_draw_rect(image, origin + Vector2i(8, 16 + bob), Vector2i(2, 4), OUTLINE)
	_draw_rect(image, origin + Vector2i(19, 16 + bob), Vector2i(2, 4), OUTLINE)
	_set_pixel(image, origin + Vector2i(13, 19 + bob), OUTLINE)
	_set_pixel(image, origin + Vector2i(12, 20 + bob), OUTLINE)
	_set_pixel(image, origin + Vector2i(14, 20 + bob), OUTLINE)
	_set_pixel(image, origin + Vector2i(15, 20 + bob), OUTLINE)
	_set_pixel(image, origin + Vector2i(17, 20 + bob), OUTLINE)
	_set_pixel(image, origin + Vector2i(16, 19 + bob), OUTLINE)


func _draw_ak(image: Image, origin: Vector2i, bob: int, recoil: int, heat: float, muzzle_flash: bool) -> void:
	var y := 23 + bob + recoil
	_draw_rect(image, origin + Vector2i(9, y), Vector2i(12, 3), OUTLINE)
	_draw_rect(image, origin + Vector2i(10, y), Vector2i(10, 2), AK_METAL)
	_draw_rect(image, origin + Vector2i(20, y - 1), Vector2i(8, 2), OUTLINE)
	_draw_rect(image, origin + Vector2i(21, y - 1), Vector2i(6, 1), AK_LIGHT)
	_draw_rect(image, origin + Vector2i(4, y + 1), Vector2i(6, 4), OUTLINE)
	_draw_rect(image, origin + Vector2i(5, y + 1), Vector2i(5, 3), AK_WOOD)
	_set_pixel(image, origin + Vector2i(8, y + 1), AK_WOOD_LIGHT)
	_draw_rect(image, origin + Vector2i(17, y + 3), Vector2i(3, 5), OUTLINE)
	_draw_rect(image, origin + Vector2i(18, y + 3), Vector2i(2, 4), AK_METAL)
	_draw_line(image, origin + Vector2i(27, y), origin + Vector2i(31, y), AK_METAL)

	if heat > 0.0:
		var heat_color := Color(1.0, lerpf(0.34, 0.92, heat), 0.08, lerpf(0.45, 1.0, heat))
		_set_pixel(image, origin + Vector2i(29, y), heat_color)
		_set_pixel(image, origin + Vector2i(30, y), heat_color)
	if muzzle_flash:
		_draw_line(image, origin + Vector2i(29, y), origin + Vector2i(31, y - 1), MUZZLE_YELLOW)
		_set_pixel(image, origin + Vector2i(31, y), HEAT_ORANGE)


func _draw_death_frame(image: Image, origin: Vector2i, frame_index: int) -> void:
	match frame_index:
		0:
			_draw_body(image, origin, 2)
			_draw_face(image, origin, 2)
			_draw_ak(image, origin, 2, 1, 0.2, false)
		1:
			_draw_shadow(image, origin + Vector2i(15, 28), 10, 2)
			_draw_filled_ellipse(image, origin + Vector2i(14, 24), 10, 5, OUTLINE)
			_draw_filled_ellipse(image, origin + Vector2i(14, 24), 8, 3, CAPOO_DARK)
			_draw_rect(image, origin + Vector2i(18, 22), Vector2i(9, 2), AK_METAL)
			_draw_rect(image, origin + Vector2i(7, 19), Vector2i(2, 2), SMOKE)
			_draw_rect(image, origin + Vector2i(23, 17), Vector2i(2, 2), SMOKE)
		_:
			_draw_shadow(image, origin + Vector2i(15, 29), 8, 1)
			_draw_rect(image, origin + Vector2i(7, 25), Vector2i(13, 2), CAPOO_DARK)
			_draw_rect(image, origin + Vector2i(20, 23), Vector2i(7, 2), AK_METAL)
			_set_pixel(image, origin + Vector2i(13, 22), SMOKE)
			_set_pixel(image, origin + Vector2i(18, 20), SMOKE)


func _draw_bullet_frame(image: Image, origin: Vector2i, frame_index: int) -> void:
	var tail_alpha := 0.45 + float(frame_index) * 0.12
	_set_pixel(image, origin + Vector2i(0, 4), Color(BULLET_ORANGE, tail_alpha))
	_set_pixel(image, origin + Vector2i(1, 4), BULLET_ORANGE)
	_draw_rect(image, origin + Vector2i(2, 3), Vector2i(4, 2), BULLET_GOLD)
	_set_pixel(image, origin + Vector2i(6, 3), MUZZLE_YELLOW)
	_set_pixel(image, origin + Vector2i(6, 4), BULLET_GOLD)


func _draw_shadow(image: Image, center: Vector2i, radius_x: int, radius_y: int) -> void:
	_draw_filled_ellipse(image, center, radius_x, radius_y, Color8(0, 0, 0, 60))


func _draw_rect(image: Image, position: Vector2i, size: Vector2i, color: Color) -> void:
	for y in range(position.y, position.y + size.y):
		for x in range(position.x, position.x + size.x):
			_set_pixel(image, Vector2i(x, y), color)


func _draw_filled_ellipse(image: Image, center: Vector2i, radius_x: int, radius_y: int, color: Color) -> void:
	for y in range(center.y - radius_y, center.y + radius_y + 1):
		for x in range(center.x - radius_x, center.x + radius_x + 1):
			var normalized_x := float(x - center.x) / float(radius_x)
			var normalized_y := float(y - center.y) / float(radius_y)
			if normalized_x * normalized_x + normalized_y * normalized_y <= 1.0:
				_set_pixel(image, Vector2i(x, y), color)


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
	image.set_pixelv(position, color)
