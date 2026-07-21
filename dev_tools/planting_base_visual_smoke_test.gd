extends SceneTree

const PLANTING_BASE_SCENE := preload(
	"res://scene/plant_defense/planting_base.tscn"
)
const DAY_NIGHT_CONTROLLER_SCENE := preload(
	"res://scene/lighting/day_night_controller.tscn"
)
const VIEWPORT_SIZE := Vector2i(256, 256)
const BASE_POSITION := Vector2(128.0, 128.0)
const BASE_SCALE := Vector2(2.0, 2.0)
const HOTSPOT_LOCAL_POSITIONS := [
	Vector2(-0.25, -8.75),
	Vector2(-0.25, -2.25),
	Vector2(-0.25, 4.75),
]

var failures: PackedStringArray = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	root.size = VIEWPORT_SIZE
	root.content_scale_size = VIEWPORT_SIZE

	var world := Node2D.new()
	world.name = "PlantingBaseVisualSmokeWorld"
	root.add_child(world)

	var ground := Polygon2D.new()
	ground.z_index = -100
	ground.color = Color(0.08, 0.28, 0.08, 1.0)
	ground.polygon = PackedVector2Array(
		[
			Vector2.ZERO,
			Vector2(VIEWPORT_SIZE.x, 0.0),
			Vector2(VIEWPORT_SIZE),
			Vector2(0.0, VIEWPORT_SIZE.y),
		]
	)
	world.add_child(ground)

	var controller := (
		DAY_NIGHT_CONTROLLER_SCENE.instantiate() as DayNightController
	)
	world.add_child(controller)

	var planting_base := PLANTING_BASE_SCENE.instantiate() as PlantingBase
	planting_base.position = BASE_POSITION
	planting_base.scale = BASE_SCALE
	world.add_child(planting_base)
	await process_frame

	var config := PlantDefenseRegistry.get_config(&"planting_base")
	_expect(config != null, "视觉测试必须能读取种植基地配置。")
	if config == null:
		await _finish(world)
		return
	planting_base.setup(
		config,
		null,
		[
			Vector2i.ZERO,
			Vector2i.RIGHT,
			Vector2i.DOWN,
			Vector2i.ONE,
		]
	)
	(planting_base.get_node("ProductionBorder") as CanvasItem).hide()

	var blocker := Polygon2D.new()
	blocker.position = BASE_POSITION
	blocker.z_index = 3
	blocker.color = Color(0.95, 0.08, 0.85, 1.0)
	blocker.polygon = PackedVector2Array(
		[
			Vector2(-8.0, -20.0),
			Vector2(8.0, -20.0),
			Vector2(8.0, 8.0),
			Vector2(-8.0, 8.0),
		]
	)
	blocker.hide()
	world.add_child(blocker)

	controller.set_night_factor_immediate(1.0)
	var hotspot_glow := planting_base.get_node(
		"HotspotGlow"
	) as NightPointLight2D
	hotspot_glow.set_emission_allowed(false)
	var off_before := await _capture_stable_frame()
	hotspot_glow.set_emission_allowed(true)
	var glow_on := await _capture_stable_frame()
	hotspot_glow.set_emission_allowed(false)
	var off_after := await _capture_stable_frame()
	_verify_glow(planting_base, glow_on, off_before, off_after)

	controller.set_night_factor_immediate(0.0)
	blocker.show()
	var layered_frame := await _capture_stable_frame()
	_verify_foreground_layer(planting_base, layered_frame)

	await _finish(world)


func _capture_stable_frame() -> Image:
	await process_frame
	await process_frame
	await RenderingServer.frame_post_draw
	return root.get_texture().get_image()


func _verify_glow(
	planting_base: PlantingBase,
	glow_on: Image,
	off_before: Image,
	off_after: Image
) -> void:
	_expect(
		not glow_on.is_empty()
		and not off_before.is_empty()
		and not off_after.is_empty(),
		"夜灯渲染测试必须能读回开关前后的画面。"
	)
	if glow_on.is_empty() or off_before.is_empty() or off_after.is_empty():
		return
	var changed_pixels := 0
	for y in glow_on.get_height():
		for x in glow_on.get_width():
			var baseline := _average_color(
				off_before.get_pixel(x, y),
				off_after.get_pixel(x, y)
			)
			if (
				glow_on.get_pixel(x, y).get_luminance()
				- baseline.get_luminance()
				>= 0.02
			):
				changed_pixels += 1
	_expect(
		changed_pixels >= 120,
		"三热点夜灯必须产生足够可见的照明变化，当前仅%d像素。" % changed_pixels
	)
	var transform := planting_base.get_global_transform_with_canvas()
	for hotspot_index in HOTSPOT_LOCAL_POSITIONS.size():
		var screen_position: Vector2 = (
			transform * HOTSPOT_LOCAL_POSITIONS[hotspot_index]
		)
		var metrics := _measure_region(
			glow_on,
			off_before,
			off_after,
			Vector2i(roundi(screen_position.x), roundi(screen_position.y)),
			12
		)
		_expect(
			float(metrics["max_luminance"]) >= 0.20
			and float(metrics["max_green"]) >= 0.25,
			"第%d处红圈热点在真实夜景中必须清晰发光。" % (hotspot_index + 1)
		)
	print("PLANTING_BASE_GLOW changed_pixels=%d" % changed_pixels)


func _verify_foreground_layer(
	planting_base: PlantingBase,
	frame: Image
) -> void:
	var transform := planting_base.get_global_transform_with_canvas()
	var upper_position: Vector2 = transform * HOTSPOT_LOCAL_POSITIONS[0]
	var lower_position: Vector2 = transform * HOTSPOT_LOCAL_POSITIONS[1]
	var upper_color := frame.get_pixel(
		roundi(upper_position.x),
		roundi(upper_position.y)
	)
	var lower_color := frame.get_pixel(
		roundi(lower_position.x),
		roundi(lower_position.y)
	)
	_expect(
		upper_color.g > upper_color.r * 1.2
		and upper_color.g > upper_color.b * 1.2,
		"z=4蓝圈上层必须覆盖模拟的z=3 Boss遮挡层。"
	)
	_expect(
		lower_color.r > 0.75
		and lower_color.b > 0.65
		and lower_color.g < 0.30,
		"蓝圈外下层必须被模拟的z=3 Boss遮挡层正常覆盖。"
	)


func _measure_region(
	glow_on: Image,
	off_before: Image,
	off_after: Image,
	center: Vector2i,
	half_extent: int
) -> Dictionary:
	var max_luminance := 0.0
	var max_green := 0.0
	for y in range(center.y - half_extent, center.y + half_extent + 1):
		if y < 0 or y >= glow_on.get_height():
			continue
		for x in range(center.x - half_extent, center.x + half_extent + 1):
			if x < 0 or x >= glow_on.get_width():
				continue
			var baseline := _average_color(
				off_before.get_pixel(x, y),
				off_after.get_pixel(x, y)
			)
			var on_color := glow_on.get_pixel(x, y)
			max_luminance = maxf(
				max_luminance,
				on_color.get_luminance() - baseline.get_luminance()
			)
			max_green = maxf(max_green, on_color.g - baseline.g)
	return {
		"max_luminance": max_luminance,
		"max_green": max_green,
	}


func _average_color(first: Color, second: Color) -> Color:
	return Color(
		(first.r + second.r) * 0.5,
		(first.g + second.g) * 0.5,
		(first.b + second.b) * 0.5,
		(first.a + second.a) * 0.5
	)


func _expect(condition: bool, message: String) -> void:
	if condition:
		return
	failures.append(message)
	push_error(message)


func _finish(world: Node) -> void:
	world.queue_free()
	await process_frame
	if failures.is_empty():
		print("PLANTING_BASE_VISUAL_SMOKE_TEST_OK")
		quit(0)
		return
	print("PLANTING_BASE_VISUAL_SMOKE_TEST_FAILED: %d" % failures.size())
	quit(1)
