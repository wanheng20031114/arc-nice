extends SceneTree

const RESEARCH_COORDINATOR_SCENE := preload(
	"res://scene/plant_defense/research_coordinator.tscn"
)
const CENTER_SCENE := preload(
	"res://scene/plant_defense/research_center.tscn"
)
const DAY_NIGHT_CONTROLLER_SCENE := preload(
	"res://scene/lighting/day_night_controller.tscn"
)
const VIEWPORT_SIZE := Vector2i(256, 256)
const CENTER_POSITION := Vector2(128.0, 128.0)
const CENTER_SCALE := Vector2(2.0, 2.0)
const BORDER_TEST_PROGRESS := 0.3
const HOTSPOT_LOCAL_POSITIONS := [
	Vector2(9.25, -3.15),
	Vector2(-9.38, 9.55),
	Vector2(9.5, 9.35),
]

var failures: PackedStringArray = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	root.size = VIEWPORT_SIZE
	root.content_scale_size = VIEWPORT_SIZE

	var world := Node2D.new()
	world.name = "ResearchCenterVisualRenderWorld"
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

	var center := CENTER_SCENE.instantiate() as ResearchCenter
	center.position = CENTER_POSITION
	center.scale = CENTER_SCALE
	world.add_child(center)
	await process_frame

	var config := PlantDefenseRegistry.get_config(&"research_center")
	_expect(config != null, "渲染测试必须能读取科研中心配置。")
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

	var main_sprite := center.get_node(
		"VisualRoot/MainSprite"
	) as Sprite2D
	var research_border := center.get_node(
		"ResearchBorder"
	) as MeshInstance2D
	var main_material := main_sprite.material as ShaderMaterial
	var border_material := research_border.material as ShaderMaterial
	_expect(
		main_material != null and border_material != null,
		"科研中心主体与外边框必须使用可复制的ShaderMaterial。"
	)
	if main_material == null or border_material == null:
		await _finish(world)
		return

	var stable_main_material := main_material.duplicate() as ShaderMaterial
	stable_main_material.resource_local_to_scene = true
	stable_main_material.set_shader_parameter(&"glow_pulse_speed", 0.0)
	main_sprite.material = stable_main_material

	var stable_border_material := border_material.duplicate() as ShaderMaterial
	stable_border_material.resource_local_to_scene = true
	stable_border_material.set_shader_parameter(&"data_noise_speed", 0.0)
	research_border.material = stable_border_material

	var hotspot_glow := center.get_node(
		"HotspotGlow"
	) as NightPointLight2D
	_expect(
		hotspot_glow.visible
		and hotspot_glow.is_visible_in_tree()
		and hotspot_glow.enabled
		and is_equal_approx(hotspot_glow.energy, 0.45),
		"真实渲染前，科研中心三热点灯必须处于可见且满强度的夜间状态。"
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
		"渲染测试必须能读回科研中心夜间灯开关前后的画面。"
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

	await _verify_border_progress_step(research_border)
	await _finish(world)


func _capture_stable_frame() -> Image:
	await process_frame
	await process_frame
	await RenderingServer.frame_post_draw
	return root.get_texture().get_image()


func _verify_hotspot_deltas(
	center: ResearchCenter,
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
			var luminance_delta := (
				on_color.get_luminance() - baseline.get_luminance()
			)
			var blue_delta := on_color.b - baseline.b
			if luminance_delta >= 0.01 and blue_delta >= 0.02:
				visibly_changed_pixels += 1

	_expect(
		visibly_changed_pixels >= 50,
		(
			"科研中心三热点灯必须让足够多的像素产生淡蓝色变化，当前仅%d像素。"
			% visibly_changed_pixels
		)
	)
	print(
		"RESEARCH_CENTER_GLOW visibly_changed_pixels=%d"
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
				"RESEARCH_CENTER_GLOW hotspot=%d max_luminance=%.4f "
				+ "max_blue=%.4f max_blue_advantage=%.4f "
				+ "avg_positive_blue=%.4f"
			)
			% [
				hotspot_index,
				float(metrics["max_luminance"]),
				float(metrics["max_blue"]),
				float(metrics["max_blue_advantage"]),
				float(metrics["avg_positive_blue"]),
			]
		)
		_expect(
			float(metrics["max_luminance"]) >= 0.10
			and float(metrics["max_blue"]) >= 0.20
			and float(metrics["max_blue_advantage"]) >= 0.19,
			"第%d处科研中心淡蓝色热点在真实夜间画面中必须可辨。" % (
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
		and float(negative_control["max_blue"]) <= 0.005,
		"科研中心热点灯不得抬亮整个画面；远处负对照区域必须保持不变。"
	)


func _verify_border_progress_step(
	research_border: MeshInstance2D
) -> void:
	research_border.set_instance_shader_parameter(
		&"working_active",
		true
	)
	research_border.set_instance_shader_parameter(
		&"progress_value",
		0.0
	)
	var baseline := await _capture_stable_frame()

	research_border.set_instance_shader_parameter(
		&"progress_value",
		BORDER_TEST_PROGRESS
	)
	var progressed := await _capture_stable_frame()

	var applied_progress := float(
		research_border.get_instance_shader_parameter(&"progress_value")
	)
	var border_delta_metrics := _measure_border_progress_delta(
		baseline,
		progressed
	)
	var brightened_border_pixels := int(
		border_delta_metrics["brightened_pixels"]
	)
	print(
		(
			"RESEARCH_CENTER_BORDER_STEP driver=%s "
			+ "progress=%.3f "
			+ "brightened_pixels=%d changed_pixels=%d "
			+ "max_green_delta=%.4f max_luminance_delta=%.4f"
		)
		% [
			RenderingServer.get_current_rendering_driver_name(),
			applied_progress,
			brightened_border_pixels,
			int(border_delta_metrics["changed_pixels"]),
			float(border_delta_metrics["max_green_delta"]),
			float(border_delta_metrics["max_luminance_delta"]),
		]
	)
	_expect(
		is_equal_approx(applied_progress, BORDER_TEST_PROGRESS)
		and brightened_border_pixels >= 24,
		(
			"科研外框收到权威进度事件后必须在真实渲染中增加已完成边框像素；"
			+ "当前新增%d像素。"
		) % brightened_border_pixels
	)


func _measure_border_progress_delta(
	baseline: Image,
	projected: Image
) -> Dictionary:
	if baseline.is_empty() or projected.is_empty():
		return {
			"brightened_pixels": 0,
			"changed_pixels": 0,
			"max_green_delta": 0.0,
			"max_luminance_delta": 0.0,
		}
	var half_extent := 34
	var minimum := Vector2i(
		roundi(CENTER_POSITION.x) - half_extent,
		roundi(CENTER_POSITION.y) - half_extent
	)
	var maximum := Vector2i(
		roundi(CENTER_POSITION.x) + half_extent,
		roundi(CENTER_POSITION.y) + half_extent
	)
	var brightened_pixels := 0
	var changed_pixels := 0
	var max_green_delta := 0.0
	var max_luminance_delta := 0.0
	for y in range(minimum.y, maximum.y + 1):
		for x in range(minimum.x, maximum.x + 1):
			var before := baseline.get_pixel(x, y)
			var after := projected.get_pixel(x, y)
			var green_delta := after.g - before.g
			var luminance_delta := (
				after.get_luminance() - before.get_luminance()
			)
			max_green_delta = maxf(max_green_delta, green_delta)
			max_luminance_delta = maxf(
				max_luminance_delta,
				luminance_delta
			)
			if (
				absf(after.r - before.r) >= 0.002
				or absf(green_delta) >= 0.002
				or absf(after.b - before.b) >= 0.002
			):
				changed_pixels += 1
			if green_delta >= 0.05 and luminance_delta >= 0.025:
				brightened_pixels += 1
	return {
		"brightened_pixels": brightened_pixels,
		"changed_pixels": changed_pixels,
		"max_green_delta": max_green_delta,
		"max_luminance_delta": max_luminance_delta,
	}


func _measure_region(
	glow_on: Image,
	off_before: Image,
	off_after: Image,
	center: Vector2i,
	half_extent: int
) -> Dictionary:
	var max_luminance := 0.0
	var max_blue := 0.0
	var max_blue_advantage := 0.0
	var positive_blue_total := 0.0
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
			var luminance_delta := (
				on_color.get_luminance() - baseline.get_luminance()
			)
			var red_delta := on_color.r - baseline.r
			var blue_delta := on_color.b - baseline.b
			max_luminance = maxf(max_luminance, luminance_delta)
			max_blue = maxf(max_blue, blue_delta)
			max_blue_advantage = maxf(
				max_blue_advantage,
				blue_delta - red_delta
			)
			positive_blue_total += maxf(blue_delta, 0.0)
			sample_count += 1
	return {
		"max_luminance": max_luminance,
		"max_blue": max_blue,
		"max_blue_advantage": max_blue_advantage,
		"avg_positive_blue": (
			positive_blue_total / float(maxi(sample_count, 1))
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
		print("RESEARCH_CENTER_VISUAL_RENDER_SMOKE_TEST_PASSED")
		quit()
		return
	print(
		"RESEARCH_CENTER_VISUAL_RENDER_SMOKE_TEST_FAILED count=%d"
		% failures.size()
	)
	quit(1)
