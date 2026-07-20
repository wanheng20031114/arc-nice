extends SceneTree

const HEALTH_BAR_SCENE := preload(
	"res://scene/plant_defense/ui/plant_health_bar.tscn"
)
const VIEWPORT_SIZE := Vector2i(192, 96)
const BAR_POSITION := Vector2(32.0, 36.0)
const BAR_SCALE := Vector2(4.0, 4.0)
const DAY_GRASS_COLOR := Color(0.16, 0.46, 0.15, 1.0)
const NIGHT_COLOR := DayNightController.REFERENCE_NIGHT_COLOR
const PREVIEW_PATH := "user://plant_health_bar_readability_preview.png"

var failures: Array[String] = []
var save_preview := false


func _initialize() -> void:
	save_preview = OS.get_cmdline_user_args().has("--screenshot")
	call_deferred("_run")


func _run() -> void:
	root.size = VIEWPORT_SIZE
	root.content_scale_size = VIEWPORT_SIZE

	var world := Node2D.new()
	world.name = "PlantHealthBarReadabilityRenderWorld"
	root.add_child(world)

	var grass := Polygon2D.new()
	grass.z_index = -10
	grass.color = DAY_GRASS_COLOR
	grass.polygon = PackedVector2Array(
		[
			Vector2.ZERO,
			Vector2(VIEWPORT_SIZE.x, 0.0),
			Vector2(VIEWPORT_SIZE),
			Vector2(0.0, VIEWPORT_SIZE.y),
		]
	)
	world.add_child(grass)

	var environment := CanvasModulate.new()
	environment.color = Color.WHITE
	world.add_child(environment)

	var health_bar := HEALTH_BAR_SCENE.instantiate() as PlantHealthBar
	health_bar.position = BAR_POSITION
	health_bar.scale = BAR_SCALE
	world.add_child(health_bar)

	var compact_bar := HEALTH_BAR_SCENE.instantiate() as PlantHealthBar
	compact_bar.custom_minimum_size = Vector2(12.0, 3.0)
	compact_bar.size = Vector2(12.0, 3.0)
	compact_bar.position = Vector2(32.0, 68.0)
	compact_bar.scale = BAR_SCALE
	world.add_child(compact_bar)
	await process_frame
	compact_bar.size = Vector2(12.0, 3.0)

	for bar in [health_bar, compact_bar]:
		bar.fade_duration = 0.0
		bar.fill_duration = 0.0
		bar.damage_trail_delay = 0.0
		bar.damage_trail_duration = 0.0
		bar.setup(100, 72)
		bar.call("_set_idle_style_amount", 0.0)
	var active_day := await _capture_stable_frame()

	for bar in [health_bar, compact_bar]:
		bar.call("_set_idle_style_amount", 1.0)
	var idle_day := await _capture_stable_frame()

	environment.color = NIGHT_COLOR
	var idle_night := await _capture_stable_frame()
	if save_preview and not idle_night.is_empty():
		var preview_path := ProjectSettings.globalize_path(PREVIEW_PATH)
		var save_error := idle_night.save_png(preview_path)
		_expect(save_error == OK, "闲置血条预览图必须能成功写入user目录。")
		if save_error == OK:
			print(
				"PLANT_HEALTH_BAR_READABILITY_PREVIEW path=%s"
				% preview_path
			)

	_expect(
		not active_day.is_empty()
		and not idle_day.is_empty()
		and not idle_night.is_empty(),
		"血条可读性测试必须能读回活跃、白昼闲置和黑夜闲置画面。"
	)
	if (
		not active_day.is_empty()
		and not idle_day.is_empty()
		and not idle_night.is_empty()
	):
		_verify_rendered_colors(
			health_bar,
			compact_bar,
			active_day,
			idle_day,
			idle_night
		)

	world.queue_free()
	await process_frame
	if failures.is_empty():
		print("PLANT_HEALTH_BAR_READABILITY_RENDER_TEST_PASSED")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _capture_stable_frame() -> Image:
	await process_frame
	await process_frame
	await RenderingServer.frame_post_draw
	return root.get_texture().get_image()


func _verify_rendered_colors(
	health_bar: PlantHealthBar,
	compact_bar: PlantHealthBar,
	active_day: Image,
	idle_day: Image,
	idle_night: Image
) -> void:
	var transform := health_bar.get_global_transform_with_canvas()
	var fill_pixel := _screen_pixel(transform * Vector2(8.0, 2.5))
	var slot_pixel := _screen_pixel(transform * Vector2(29.0, 2.5))
	var frame_pixel := _screen_pixel(transform * Vector2(0.25, 2.5))

	var active_fill := active_day.get_pixelv(fill_pixel)
	var idle_day_fill := idle_day.get_pixelv(fill_pixel)
	var idle_night_fill := idle_night.get_pixelv(fill_pixel)
	var idle_day_slot := idle_day.get_pixelv(slot_pixel)
	var idle_night_slot := idle_night.get_pixelv(slot_pixel)
	var idle_day_frame := idle_day.get_pixelv(frame_pixel)
	var idle_night_frame := idle_night.get_pixelv(frame_pixel)
	var idle_day_ground := idle_day.get_pixel(10, 10)
	var idle_night_ground := idle_night.get_pixel(10, 10)
	var resolved_slot: Color = health_bar.call(
		"_resolve_idle_color",
		health_bar.slot_color,
		health_bar.idle_color_brightness,
		health_bar.idle_slot_alpha,
		1.0
	)

	var active_luminance := _relative_luminance(active_fill)
	var idle_luminance := _relative_luminance(idle_day_fill)
	var fill_brightness_ratio := (
		idle_luminance / maxf(active_luminance, 0.0001)
	)
	print(
		(
			"PLANT_HEALTH_BAR_READABILITY_COLORS active_fill=%s "
			+ "idle_day_fill=%s idle_night_fill=%s "
			+ "idle_day_slot=%s idle_night_slot=%s "
			+ "idle_day_ground=%s idle_night_ground=%s "
			+ "resolved_slot=%s"
		)
		% [
			str(active_fill),
			str(idle_day_fill),
			str(idle_night_fill),
			str(idle_day_slot),
			str(idle_night_slot),
			str(idle_day_ground),
			str(idle_night_ground),
			str(resolved_slot),
		]
	)
	_expect(
		_max_rgb_delta(idle_day_ground, idle_night_ground) >= 0.02,
		"可读性测试的草地背景必须确实受到昼夜环境调制。"
	)
	_expect(
		_max_rgb_delta(idle_day_slot, idle_night_slot) >= 0.01,
		"闲置空槽必须真正透出昼夜世界背景，而不是压在整块不透明底色上。"
	)
	_expect(
		fill_brightness_ratio >= 0.66
		and fill_brightness_ratio <= 0.90,
		(
			"闲置血量填充应只降低显著度而不能糊掉；当前相对亮度为%.3f。"
			% fill_brightness_ratio
		)
	)
	_expect(
		idle_day_fill.g > idle_day_fill.r * 1.45
		and idle_day_fill.g > idle_day_fill.b * 1.45,
		"闲置血量填充必须保持清晰可辨的绿色，而不是与背景混成灰绿。"
	)
	_expect(
		_max_rgb_delta(idle_day_fill, idle_night_fill) <= 0.012
		and _max_rgb_delta(idle_day_frame, idle_night_frame) <= 0.012,
		"关键填充与一像素边框必须通过unshaded材质避免被昼夜调制二次压暗。"
	)

	var day_contrast := _contrast_ratio(idle_day_fill, idle_day_slot)
	var night_contrast := _contrast_ratio(
		idle_night_fill,
		idle_night_slot
	)
	print(
		(
			"PLANT_HEALTH_BAR_READABILITY brightness_ratio=%.3f "
			+ "day_fill_slot_contrast=%.3f "
			+ "night_fill_slot_contrast=%.3f"
		)
		% [
			fill_brightness_ratio,
			day_contrast,
			night_contrast,
		]
	)
	_expect(
		day_contrast >= 3.0 and night_contrast >= 3.0,
		(
			"闲置填充与空槽在昼夜背景下都必须保持至少3:1对比度；"
			+ "当前白昼%.3f、黑夜%.3f。"
		)
		% [day_contrast, night_contrast]
	)

	_verify_compact_bar(
		compact_bar,
		idle_day,
		idle_night
	)


func _verify_compact_bar(
	compact_bar: PlantHealthBar,
	idle_day: Image,
	idle_night: Image
) -> void:
	var transform := compact_bar.get_global_transform_with_canvas()
	var fill_pixel := _screen_pixel(transform * Vector2(3.0, 1.5))
	var slot_pixel := _screen_pixel(transform * Vector2(10.5, 1.5))
	var frame_pixel := _screen_pixel(transform * Vector2(0.25, 1.5))
	var day_fill := idle_day.get_pixelv(fill_pixel)
	var night_fill := idle_night.get_pixelv(fill_pixel)
	var day_slot := idle_day.get_pixelv(slot_pixel)
	var night_slot := idle_night.get_pixelv(slot_pixel)
	var day_frame := idle_day.get_pixelv(frame_pixel)
	var night_frame := idle_night.get_pixelv(frame_pixel)
	var day_contrast := _contrast_ratio(day_fill, day_slot)
	var night_contrast := _contrast_ratio(night_fill, night_slot)
	print(
		(
			"PLANT_HEALTH_BAR_COMPACT_READABILITY size=%s "
			+ "day_fill_slot_contrast=%.3f "
			+ "night_fill_slot_contrast=%.3f"
		)
		% [str(compact_bar.size), day_contrast, night_contrast]
	)
	_expect(
		_max_rgb_delta(day_fill, night_fill) <= 0.012
		and _max_rgb_delta(day_frame, night_frame) <= 0.012,
		"12×3紧凑血条的填充与边框也必须保持昼夜一致且像素清晰。"
	)
	_expect(
		_max_rgb_delta(day_slot, night_slot) >= 0.01,
		"12×3紧凑血条的一像素空槽必须真正透出世界背景。"
	)
	_expect(
		day_contrast >= 3.0 and night_contrast >= 3.0,
		(
			"12×3紧凑血条在昼夜都必须保持填充/空槽至少3:1对比；"
			+ "当前白昼%.3f、黑夜%.3f。"
		)
		% [day_contrast, night_contrast]
	)


func _screen_pixel(position: Vector2) -> Vector2i:
	return Vector2i(roundi(position.x), roundi(position.y))


func _max_rgb_delta(first: Color, second: Color) -> float:
	return maxf(
		absf(first.r - second.r),
		maxf(
			absf(first.g - second.g),
			absf(first.b - second.b)
		)
	)


func _contrast_ratio(first: Color, second: Color) -> float:
	var brighter := maxf(
		_relative_luminance(first),
		_relative_luminance(second)
	)
	var darker := minf(
		_relative_luminance(first),
		_relative_luminance(second)
	)
	return (brighter + 0.05) / (darker + 0.05)


func _relative_luminance(color: Color) -> float:
	# Godot's linear framebuffer readback has already converted sRGB channels,
	# so applying the WCAG transfer curve a second time would understate contrast.
	return (
		0.2126 * color.r
		+ 0.7152 * color.g
		+ 0.0722 * color.b
	)


func _expect(condition: bool, message: String) -> void:
	if condition:
		return
	failures.append(message)
