extends Node2D

const OUTPUT_DIRECTORY := "res://dev_tools/output/guardian_night_glow"

@onready var day_night_controller: DayNightController = $DayNightController
@onready var guardians: Node2D = $Guardians

var failures: PackedStringArray = []


func _ready() -> void:
	_mute_audio()
	DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path(OUTPUT_DIRECTORY)
	)
	day_night_controller.set_night_factor_immediate(1.0)
	await get_tree().process_frame
	await get_tree().process_frame
	_prepare_guardians()

	var active_lights := _count_active_guardian_lights()
	_expect(
		active_lights == YuanshiInsectAura.MAX_ACTIVE_GUARDIAN_LIGHTS,
		"Guardian visual fixture must preserve the 12-light production budget."
	)
	_set_guardian_halos_visible(false)
	var without_halos := await _capture("night_without_halos.png")
	_set_guardian_halos_visible(true)
	var with_halos := await _capture("night_all_guardians_glowing.png")
	_verify_unbudgeted_guardians_glow(without_halos, with_halos)

	if failures.is_empty():
		print(
			"GUARDIAN_NIGHT_GLOW_VISUAL_TEST_OK guardians=%d lights=%d" % [
				guardians.get_child_count(),
				active_lights,
			]
		)
		get_tree().quit(0)
		return
	print("GUARDIAN_NIGHT_GLOW_VISUAL_TEST_FAILED count=%d" % failures.size())
	get_tree().quit(1)


func _prepare_guardians() -> void:
	for guardian_node in guardians.get_children():
		var guardian := guardian_node as YuanshiInsectAura
		if guardian == null:
			continue
		guardian.set_process(false)
		guardian.set_physics_process(false)
		guardian.animated_sprite.pause()


func _count_active_guardian_lights() -> int:
	var active_count := 0
	for guardian in guardians.get_children():
		var light := guardian.get_node_or_null("GuardianLight") as PointLight2D
		if light != null and light.enabled:
			active_count += 1
	return active_count


func _set_guardian_halos_visible(visible: bool) -> void:
	for guardian in guardians.get_children():
		var halo := guardian.get_node_or_null("GuardianLightHalo") as Sprite2D
		if halo != null:
			halo.visible = visible


func _verify_unbudgeted_guardians_glow(
	without_halos: Image,
	with_halos: Image
) -> void:
	var checked_count := 0
	for guardian_node in guardians.get_children():
		var guardian := guardian_node as Node2D
		if guardian == null:
			continue
		var light := guardian.get_node_or_null("GuardianLight") as PointLight2D
		if light != null and light.enabled:
			continue
		var center := guardian.get_global_transform_with_canvas().origin
		var metrics := _measure_region_delta(
			without_halos,
			with_halos,
			center,
			42.0
		)
		checked_count += 1
		_expect(
			float(metrics["positive_delta"]) >= 1.0
			and int(metrics["changed_pixels"]) >= 80
			and float(metrics["max_delta"]) >= 0.01,
			"A guardian without a PointLight budget slot lost its visible halo."
		)
	print("GUARDIAN_NIGHT_GLOW_UNBUDGETED checked=%d" % checked_count)
	_expect(
		checked_count == guardians.get_child_count() - YuanshiInsectAura.MAX_ACTIVE_GUARDIAN_LIGHTS,
		"Visual fixture must exercise guardians beyond the real-light budget."
	)


func _measure_region_delta(
	without_halos: Image,
	with_halos: Image,
	center: Vector2,
	radius: float
) -> Dictionary:
	var positive_delta := 0.0
	var changed_pixels := 0
	var max_delta := 0.0
	var radius_squared := radius * radius
	for y in range(
		maxi(floori(center.y - radius), 0),
		mini(ceili(center.y + radius) + 1, with_halos.get_height())
	):
		for x in range(
			maxi(floori(center.x - radius), 0),
			mini(ceili(center.x + radius) + 1, with_halos.get_width())
		):
			if center.distance_squared_to(Vector2(x, y)) > radius_squared:
				continue
			var delta := (
				with_halos.get_pixel(x, y).get_luminance()
				- without_halos.get_pixel(x, y).get_luminance()
			)
			positive_delta += maxf(delta, 0.0)
			max_delta = maxf(max_delta, delta)
			if delta >= 0.002:
				changed_pixels += 1
	return {
		"positive_delta": positive_delta,
		"changed_pixels": changed_pixels,
		"max_delta": max_delta,
	}


func _capture(file_name: String) -> Image:
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	var save_path := "%s/%s" % [OUTPUT_DIRECTORY, file_name]
	var error := image.save_png(ProjectSettings.globalize_path(save_path))
	_expect(error == OK, "Failed to save guardian visual capture: %s" % file_name)
	return image


func _expect(condition: bool, message: String) -> void:
	if condition:
		return
	failures.append(message)
	push_error(message)


func _mute_audio() -> void:
	for bus_index in range(AudioServer.bus_count):
		AudioServer.set_bus_mute(bus_index, true)
