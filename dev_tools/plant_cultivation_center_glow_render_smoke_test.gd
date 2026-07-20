extends SceneTree

const CENTER_SCENE := preload(
	"res://scene/plant_defense/plant_cultivation_center.tscn"
)
const DAY_NIGHT_CONTROLLER_SCENE := preload(
	"res://scene/lighting/day_night_controller.tscn"
)
const VIEWPORT_SIZE := Vector2i(256, 256)
const CENTER_POSITION := Vector2(128.0, 128.0)
const CENTER_SCALE := Vector2(2.0, 2.0)
const HOTSPOT_LOCAL_POSITIONS := [
	Vector2(0.0, -10.0),
	Vector2(-11.0, 0.0),
	Vector2(11.0, 0.0),
	Vector2(-5.0, 4.0),
	Vector2(0.25, 10.25),
]

var failures: PackedStringArray = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	root.size = VIEWPORT_SIZE
	root.content_scale_size = VIEWPORT_SIZE

	var world := Node2D.new()
	world.name = "PlantCultivationCenterGlowRenderWorld"
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

	var day_night_controller := (
		DAY_NIGHT_CONTROLLER_SCENE.instantiate() as DayNightController
	)
	world.add_child(day_night_controller)

	var center := CENTER_SCENE.instantiate() as PlantCultivationCenter
	center.position = CENTER_POSITION
	center.scale = CENTER_SCALE
	world.add_child(center)
	await process_frame

	var config := PlantDefenseRegistry.get_config(&"plant_cultivation_center")
	_expect(config != null, "渲染测试必须能读取植物培育中心配置。")
	if config == null:
		await _finish(world)
		return

	center.setup(
		config,
		null,
		[
			Vector2i.ZERO,
			Vector2i.RIGHT,
			Vector2i.DOWN,
			Vector2i.ONE,
		]
	)
	day_night_controller.set_night_factor_immediate(1.0)

	var border := center.get_node("ProductionBorder") as CanvasItem
	border.visible = false
	var main_sprite := center.get_node(
		"VisualRoot/MainSprite"
	) as Sprite2D
	var stable_material := main_sprite.material.duplicate() as ShaderMaterial
	stable_material.resource_local_to_scene = true
	stable_material.set_shader_parameter(&"glow_pulse_amount", 0.0)
	main_sprite.material = stable_material

	var hotspot_glow := center.get_node(
		"HotspotGlow"
	) as NightPointLight2D
	_expect(
		hotspot_glow.visible
		and hotspot_glow.is_visible_in_tree()
		and hotspot_glow.enabled
		and is_equal_approx(hotspot_glow.energy, 0.84),
		"真实渲染前，五热点灯必须处于可见且满强度的夜间状态。"
	)

	hotspot_glow.set_emission_allowed(false)
	var off_before := await _capture_stable_frame()
	hotspot_glow.set_emission_allowed(true)
	var glow_on := await _capture_stable_frame()
	hotspot_glow.set_emission_allowed(false)
	var off_after := await _capture_stable_frame()

	_expect(
		not off_before.is_empty()
		and not glow_on.is_empty()
		and not off_after.is_empty(),
		"渲染测试必须能读回夜间灯开关前后的画面。"
	)
	if (
		not off_before.is_empty()
		and not glow_on.is_empty()
		and not off_after.is_empty()
	):
		_verify_hotspot_deltas(
			center,
			glow_on,
			off_before,
			off_after
		)

	await _finish(world)


func _capture_stable_frame() -> Image:
	await process_frame
	await process_frame
	await RenderingServer.frame_post_draw
	return root.get_texture().get_image()


func _verify_hotspot_deltas(
	center: PlantCultivationCenter,
	glow_on: Image,
	off_before: Image,
	off_after: Image
) -> void:
	var transform := center.get_global_transform_with_canvas()
	var visibly_changed_pixels := 0
	for y in range(glow_on.get_height()):
		for x in range(glow_on.get_width()):
			var on_color := glow_on.get_pixel(x, y)
			var baseline := _average_color(
				off_before.get_pixel(x, y),
				off_after.get_pixel(x, y)
			)
			if (
				on_color.get_luminance()
				- baseline.get_luminance()
				>= 0.02
			):
				visibly_changed_pixels += 1

	_expect(
		visibly_changed_pixels >= 180,
		(
			"五热点灯必须让足够多的像素产生肉眼可辨变化，当前仅%d像素。"
			% visibly_changed_pixels
		)
	)
	print(
		"CULTIVATION_GLOW visibly_changed_pixels=%d"
		% visibly_changed_pixels
	)

	for hotspot_index in range(HOTSPOT_LOCAL_POSITIONS.size()):
		var screen_position: Vector2 = (
			transform * HOTSPOT_LOCAL_POSITIONS[hotspot_index]
		)
		var metrics := _measure_region(
			glow_on,
			off_before,
			off_after,
			Vector2i(roundi(screen_position.x), roundi(screen_position.y)),
			8
		)
		print(
			(
				"CULTIVATION_GLOW hotspot=%d max_luminance=%.4f "
				+ "max_green=%.4f avg_positive_green=%.4f"
			)
			% [
				hotspot_index,
				float(metrics["max_luminance"]),
				float(metrics["max_green"]),
				float(metrics["avg_positive_green"]),
			]
		)
		_expect(
			float(metrics["max_luminance"]) >= 0.25
			and float(metrics["max_green"]) >= 0.30,
			"第%d处嫩绿色热点在真实夜间画面中必须清晰可辨。" % (
				hotspot_index + 1
			)
		)

	var negative_control := _measure_region(
		glow_on,
		off_before,
		off_after,
		Vector2i(28, 28),
		6
	)
	_expect(
		float(negative_control["max_luminance"]) <= 0.005
		and float(negative_control["max_green"]) <= 0.005,
		"热点灯不得把整个画面抬亮；远离建筑的负对照区域必须保持不变。"
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
	var positive_green_total := 0.0
	var sample_count := 0
	for y in range(center.y - half_extent, center.y + half_extent + 1):
		if y < 0 or y >= glow_on.get_height():
			continue
		for x in range(
			center.x - half_extent,
			center.x + half_extent + 1
		):
			if x < 0 or x >= glow_on.get_width():
				continue
			var on_color := glow_on.get_pixel(x, y)
			var baseline := _average_color(
				off_before.get_pixel(x, y),
				off_after.get_pixel(x, y)
			)
			max_luminance = maxf(
				max_luminance,
				on_color.get_luminance() - baseline.get_luminance()
			)
			var green_delta := on_color.g - baseline.g
			max_green = maxf(max_green, green_delta)
			positive_green_total += maxf(green_delta, 0.0)
			sample_count += 1
	return {
		"max_luminance": max_luminance,
		"max_green": max_green,
		"avg_positive_green": (
			positive_green_total / float(maxi(sample_count, 1))
		),
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
		print("PLANT_CULTIVATION_CENTER_GLOW_RENDER_SMOKE_TEST_PASSED")
		quit()
		return
	print(
		"PLANT_CULTIVATION_CENTER_GLOW_RENDER_SMOKE_TEST_FAILED count=%d"
		% failures.size()
	)
	quit(1)
