extends SceneTree

const SOURCE_TEXTURE_PATH := "res://resources/texture/yuanshi_insect_green_shell.png"
const YUANSHI_INSECT_OUTPUT_PATH := "res://resources/texture/yuanshi_insect_fire_ranged.png"
const PROJECTILE_OUTPUT_PATH := "res://resources/texture/yuanshi_insect_fire_projectile.png"
const AUDIO_OUTPUT_PATH := "res://resources/audio/yuanshi_insect_fire_attack.wav"

const FRAME_SIZE := Vector2i(32, 32)
const PROJECTILE_FRAME_SIZE := Vector2i(8, 8)
const SAMPLE_RATE := 22050
const AUDIO_DURATION := 0.25


func _init() -> void:
	var source := Image.load_from_file(SOURCE_TEXTURE_PATH)
	if source == null or source.is_empty():
		push_error("Unable to load source Yuanshi insect texture: %s" % SOURCE_TEXTURE_PATH)
		quit(1)
		return

	var yuanshi_insect_sheet := _build_yuanshi_insect_sheet(source)
	var projectile_sheet := _build_projectile_sheet()

	var yuanshi_insect_error := yuanshi_insect_sheet.save_png(YUANSHI_INSECT_OUTPUT_PATH)
	var projectile_error := projectile_sheet.save_png(PROJECTILE_OUTPUT_PATH)
	var audio_error := _write_attack_audio(AUDIO_OUTPUT_PATH)

	if yuanshi_insect_error != OK or projectile_error != OK or audio_error != OK:
		push_error(
			"Asset generation failed: yuanshi_insect=%s projectile=%s audio=%s"
			% [yuanshi_insect_error, projectile_error, audio_error]
		)
		quit(1)
		return

	print("Generated fire Yuanshi insect assets.")
	quit()


func _build_yuanshi_insect_sheet(source: Image) -> Image:
	var sheet := Image.create(320, 32, false, Image.FORMAT_RGBA8)
	sheet.fill(Color.TRANSPARENT)

	for frame_index in range(3):
		var move_frame := source.get_region(
			Rect2i(frame_index * FRAME_SIZE.x, 0, FRAME_SIZE.x, FRAME_SIZE.y)
		)
		_recolor_fire_yuanshi_insect(move_frame)
		_add_flame_crown(move_frame, frame_index, false)
		sheet.blit_rect(move_frame, Rect2i(Vector2i.ZERO, FRAME_SIZE), Vector2i(frame_index * 32, 0))

	var attack_source := source.get_region(Rect2i(32, 0, 32, 32))
	_recolor_fire_yuanshi_insect(attack_source)
	for attack_frame_index in range(4):
		var attack_frame := attack_source.duplicate()
		_add_flame_crown(attack_frame, attack_frame_index, true)
		_add_attack_pose(attack_frame, attack_frame_index)
		sheet.blit_rect(
			attack_frame,
			Rect2i(Vector2i.ZERO, FRAME_SIZE),
			Vector2i((attack_frame_index + 3) * 32, 0)
		)

	for death_frame_index in range(3):
		var death_frame := source.get_region(
			Rect2i(death_frame_index * FRAME_SIZE.x, 32, FRAME_SIZE.x, FRAME_SIZE.y)
		)
		_recolor_fire_yuanshi_insect(death_frame)
		_dim_death_frame(death_frame, death_frame_index)
		sheet.blit_rect(
			death_frame,
			Rect2i(Vector2i.ZERO, FRAME_SIZE),
			Vector2i((death_frame_index + 7) * 32, 0)
		)

	return sheet


func _recolor_fire_yuanshi_insect(image: Image) -> void:
	for y in range(image.get_height()):
		for x in range(image.get_width()):
			var source_color := image.get_pixel(x, y)
			if source_color.a <= 0.0:
				continue

			var lightness := (
				source_color.r * 0.299
				+ source_color.g * 0.587
				+ source_color.b * 0.114
			)
			var target_color: Color
			if lightness < 0.18:
				target_color = Color8(20, 13, 17, 255)
			elif lightness < 0.36:
				target_color = Color8(48, 23, 18, 255)
			elif lightness < 0.54:
				target_color = Color8(116, 42, 10, 255)
			elif lightness < 0.72:
				target_color = Color8(230, 82, 8, 255)
			elif lightness < 0.88:
				target_color = Color8(255, 174, 18, 255)
			else:
				target_color = Color8(255, 235, 92, 255)
			image.set_pixel(x, y, target_color)


func _add_flame_crown(image: Image, frame_index: int, is_attacking: bool) -> void:
	var outline := Color8(71, 24, 10, 255)
	var flame := Color8(244, 70, 6, 255)
	var hot := Color8(255, 173, 18, 255)
	var core := Color8(255, 238, 100, 255)
	var rise := 1 if is_attacking and frame_index >= 1 else 0

	var crown_pixels := {
		Vector2i(11, 9 - rise): outline,
		Vector2i(12, 8 - rise): flame,
		Vector2i(13, 7 - rise): hot,
		Vector2i(14, 5 - rise): outline,
		Vector2i(14, 6 - rise): flame,
		Vector2i(15, 7 - rise): core,
		Vector2i(16, 4 - rise): outline,
		Vector2i(16, 5 - rise): flame,
		Vector2i(16, 6 - rise): hot,
		Vector2i(17, 7 - rise): core,
		Vector2i(18, 6 - rise): flame,
		Vector2i(19, 7 - rise): hot,
		Vector2i(20, 8 - rise): flame,
		Vector2i(21, 9 - rise): outline,
		Vector2i(22, 11): hot,
		Vector2i(23, 10): flame,
	}
	for pixel in crown_pixels:
		image.set_pixelv(pixel, crown_pixels[pixel])

	var crack_shift := frame_index % 2
	for pixel in [
		Vector2i(13 + crack_shift, 12),
		Vector2i(16, 11 + crack_shift),
		Vector2i(19 - crack_shift, 13),
	]:
		_set_pixel_if_opaque(image, pixel, core)


func _add_attack_pose(image: Image, frame_index: int) -> void:
	var heat_color := Color8(255, 112, 16, 255)
	var hot_color := Color8(255, 222, 72, 255)
	var core_color := Color8(255, 250, 205, 255)

	var shell_pixels: Array[Vector2i] = [
		Vector2i(13, 9),
		Vector2i(16, 8),
		Vector2i(19, 10),
	]
	for pixel in shell_pixels:
		_set_pixel_if_opaque(image, pixel, heat_color if frame_index == 0 else hot_color)

	if frame_index >= 1:
		for pixel in [Vector2i(23, 16), Vector2i(24, 16), Vector2i(24, 17)]:
			image.set_pixelv(pixel, hot_color)
	if frame_index >= 2:
		for pixel in [Vector2i(25, 15), Vector2i(25, 16), Vector2i(26, 16), Vector2i(25, 17)]:
			image.set_pixelv(pixel, core_color)
		image.set_pixel(27, 16, hot_color)
	if frame_index == 3:
		image.set_pixel(27, 16, Color.TRANSPARENT)
		image.set_pixel(25, 15, heat_color)
		image.set_pixel(25, 16, hot_color)
		image.set_pixel(25, 17, heat_color)


func _dim_death_frame(image: Image, frame_index: int) -> void:
	var brightness := [0.82, 0.55, 0.30][frame_index] as float
	for y in range(image.get_height()):
		for x in range(image.get_width()):
			var color := image.get_pixel(x, y)
			if color.a <= 0.0:
				continue
			image.set_pixel(x, y, Color(color.r * brightness, color.g * brightness, color.b * brightness, 1.0))


func _set_pixel_if_opaque(image: Image, position: Vector2i, color: Color) -> void:
	if image.get_pixelv(position).a > 0.0:
		image.set_pixelv(position, color)


func _build_projectile_sheet() -> Image:
	var sheet := Image.create(24, 8, false, Image.FORMAT_RGBA8)
	sheet.fill(Color.TRANSPARENT)
	for frame_index in range(3):
		_draw_projectile_frame(sheet, frame_index)
	return sheet


func _draw_projectile_frame(sheet: Image, frame_index: int) -> void:
	var offset_x := frame_index * PROJECTILE_FRAME_SIZE.x
	var outline := Color8(90, 20, 12, 255)
	var flame := Color8(242, 68, 12, 255)
	var hot := Color8(255, 153, 20, 255)
	var core := Color8(255, 241, 144, 255)

	var pixels := {
		Vector2i(1, 3): flame,
		Vector2i(2, 2): outline,
		Vector2i(2, 3): hot,
		Vector2i(2, 4): outline,
		Vector2i(3, 1): outline,
		Vector2i(3, 2): hot,
		Vector2i(3, 3): core,
		Vector2i(3, 4): hot,
		Vector2i(3, 5): outline,
		Vector2i(4, 1): outline,
		Vector2i(4, 2): hot,
		Vector2i(4, 3): core,
		Vector2i(4, 4): hot,
		Vector2i(4, 5): outline,
		Vector2i(5, 2): outline,
		Vector2i(5, 3): hot,
		Vector2i(5, 4): outline,
		Vector2i(6, 3): flame,
	}

	for local_position in pixels:
		var animated_position: Vector2i = local_position
		if frame_index == 1 and local_position.x <= 2:
			animated_position.y += 1
		elif frame_index == 2 and local_position.x <= 2:
			animated_position.y -= 1
		sheet.set_pixel(offset_x + animated_position.x, animated_position.y, pixels[local_position])


func _write_attack_audio(path: String) -> Error:
	var sample_count := int(SAMPLE_RATE * AUDIO_DURATION)
	var pcm := PackedByteArray()
	pcm.resize(sample_count * 2)
	var random := RandomNumberGenerator.new()
	random.seed = 0xF1A4E

	for sample_index in range(sample_count):
		var time := float(sample_index) / SAMPLE_RATE
		var progress := time / AUDIO_DURATION
		var envelope := sin(PI * clampf(progress, 0.0, 1.0)) * exp(-2.8 * progress)
		var frequency := lerpf(230.0, 92.0, progress)
		var tone := sin(TAU * frequency * time + 10.0 * progress * progress)
		var crackle := random.randf_range(-1.0, 1.0)
		var low_noise := sin(TAU * 46.0 * time) * random.randf_range(-0.35, 0.35)
		var sample := clampf((tone * 0.38 + crackle * 0.52 + low_noise * 0.10) * envelope, -1.0, 1.0)
		var sample_value := int(sample * 32767.0)
		if sample_value < 0:
			sample_value += 65536
		pcm[sample_index * 2] = sample_value & 0xFF
		pcm[sample_index * 2 + 1] = (sample_value >> 8) & 0xFF

	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()

	file.store_buffer("RIFF".to_ascii_buffer())
	file.store_32(36 + pcm.size())
	file.store_buffer("WAVE".to_ascii_buffer())
	file.store_buffer("fmt ".to_ascii_buffer())
	file.store_32(16)
	file.store_16(1)
	file.store_16(1)
	file.store_32(SAMPLE_RATE)
	file.store_32(SAMPLE_RATE * 2)
	file.store_16(2)
	file.store_16(16)
	file.store_buffer("data".to_ascii_buffer())
	file.store_32(pcm.size())
	file.store_buffer(pcm)
	return OK
