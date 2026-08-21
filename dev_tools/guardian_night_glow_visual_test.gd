extends Node2D

const OUTPUT_DIRECTORY := "res://dev_tools/output/guardian_night_glow"
const LEGACY_HALO_MODULATE := Color(0.2, 0.78, 1.0, 0.78)
const FIXTURE_LOCAL_RADIUS := 36.0
const BODY_LOCAL_RADIUS := 13.0
const MAX_BRIGHTNESS_RATIO_ERROR := 0.08
const MAX_COVERAGE_RATIO_ERROR := 0.1
const MAX_CHANNEL_SHARE_ERROR := 0.055
const MAX_REGION_RGB_MAE := 0.025
const MAX_RECEIVER_BRIGHTNESS_RATIO_ERROR := 0.18
const MAX_RECEIVER_RGB_MAE := 0.035
const MAX_DENSE_BRIGHTNESS_RATIO_ERROR := 0.12
const MAX_DENSE_RGB_MAE := 0.065
const MAX_DENSE_CHANNEL_SHARE_ERROR := 0.055
const MIN_DENSE_LUMINANCE_SSIM := 0.94
const MAX_DENSE_SATURATED_PIXEL_RATIO_ERROR := 0.18
const VISIBLE_LUMINANCE_STEP := 1.0 / 255.0

@onready var day_night_controller: DayNightController = $DayNightController
@onready var legacy_fixtures: Node2D = $LegacyFixtures
@onready var foreground_receivers: Node2D = $LegacyFixtures/ForegroundReceivers
@onready var guardians: Node2D = $Guardians
@onready var dense_legacy_lights: Node2D = $DenseLegacyLights

var failures: PackedStringArray = []
var fixture_guardians: Array[YuanshiInsectAura] = []
var dense_guardians: Array[YuanshiInsectAura] = []
var fixture_receivers: Array[Enemy] = []


func _ready() -> void:
	_mute_audio()
	DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path(OUTPUT_DIRECTORY)
	)
	fixture_guardians = _collect_guardians(legacy_fixtures)
	dense_guardians = _collect_guardians(guardians)
	fixture_receivers = _collect_receivers()
	_prepare_guardians(fixture_guardians)
	_prepare_guardians(dense_guardians)
	_prepare_receivers()
	_verify_production_self_emission_contract()

	guardians.hide()
	legacy_fixtures.show()
	# Visibility-based slot handoff is deferred so every hidden candidate can
	# release before visible candidates reclaim. Let production ownership settle
	# before the A/B fixture temporarily overrides individual emission visibility.
	await get_tree().process_frame
	await get_tree().process_frame
	await _verify_legacy_visual_parity("night", 1.0)
	await _verify_legacy_visual_parity("day", 0.0)
	await _verify_status_visual_parity()
	await _verify_dense_budget_parity("night_dense", 1.0)
	await _verify_dense_budget_parity("day_dense", 0.0)

	if failures.is_empty():
		print(
			"GUARDIAN_NIGHT_GLOW_VISUAL_TEST_OK fixtures=%d guardians=%d" % [
				fixture_guardians.size(),
				dense_guardians.size(),
			]
		)
		get_tree().quit(0)
		return
	print("GUARDIAN_NIGHT_GLOW_VISUAL_TEST_FAILED count=%d" % failures.size())
	get_tree().quit(1)


func _collect_guardians(container: Node) -> Array[YuanshiInsectAura]:
	var result: Array[YuanshiInsectAura] = []
	for child in container.get_children():
		var guardian := child as YuanshiInsectAura
		if guardian != null:
			result.append(guardian)
	return result


func _collect_receivers() -> Array[Enemy]:
	var result: Array[Enemy] = []
	for child in foreground_receivers.get_children():
		var receiver := child as Enemy
		if receiver != null:
			result.append(receiver)
	return result


func _prepare_guardians(collection: Array[YuanshiInsectAura]) -> void:
	for guardian in collection:
		guardian.set_process(false)
		guardian.set_physics_process(false)
		guardian.animated_sprite.pause()


func _prepare_receivers() -> void:
	for receiver in fixture_receivers:
		receiver.set_process(false)
		receiver.set_physics_process(false)
		receiver.animated_sprite.pause()


func _verify_production_self_emission_contract() -> void:
	_expect(
		fixture_guardians.size() == 3
		and fixture_receivers.size() == 3
		and dense_guardians.size() == 16,
		"Visual fixture must contain three A/B pairs and sixteen dense guardians."
	)
	var runtime_boost_count := 0
	for guardian in fixture_guardians + dense_guardians:
		var halo := guardian.get_node_or_null("GuardianLightHalo") as Sprite2D
		var light_emission := guardian.get_node_or_null(
			"GuardianLightEmission"
		) as Sprite2D
		var material := (
			halo.material as CanvasItemMaterial
			if halo != null
			else null
		)
		var boosted := light_emission != null and light_emission.visible
		if boosted:
			runtime_boost_count += 1
		_expect(
			guardian.find_children("*", "Light2D", true, false).is_empty()
			and guardian.get_node_or_null("GuardianLight") == null,
			"Production guardian instances must contain no decorative Light2D nodes."
		)
		_expect(
			halo != null
			and halo.texture != null
			and halo.texture.resource_path.ends_with("guardian_point_light.png")
			and halo.texture_filter == CanvasItem.TEXTURE_FILTER_LINEAR
			and halo.scale.is_equal_approx(Vector2(0.95, 0.95))
			and halo.visible
			and halo.modulate.is_equal_approx(LEGACY_HALO_MODULATE)
			and material != null
			and material.blend_mode == CanvasItemMaterial.BLEND_MODE_ADD
			and material.light_mode == CanvasItemMaterial.LIGHT_MODE_UNSHADED
			and halo.z_index < guardian.animated_sprite.z_index,
			"Production guardian glow must be the calibrated additive self-emission layer."
		)
		var emission_material := (
			light_emission.material as ShaderMaterial
			if light_emission != null
			else null
		)
		_expect(
			light_emission != null
			and halo != null
			and light_emission.texture == halo.texture
			and light_emission.texture_filter == CanvasItem.TEXTURE_FILTER_LINEAR
			and light_emission.scale.is_equal_approx(Vector2(0.95, 0.95))
			and emission_material != null
			and emission_material.shader != null
			and emission_material.shader.resource_path.ends_with(
				"guardian_light_emission.gdshader"
			)
			and light_emission.z_index > guardian.animated_sprite.z_index,
			"Guardian boost must use the shared receiver-aware self-emission layer."
		)
	_expect(
		runtime_boost_count
		== YuanshiInsectAura.MAX_ACTIVE_GUARDIAN_EMISSION_BOOSTS,
		"Production runtime must preserve exactly twelve self-emission boost slots."
	)


func _verify_legacy_visual_parity(label: String, night_factor: float) -> void:
	day_night_controller.set_night_factor_immediate(night_factor)
	_set_legacy_lights_enabled(false)
	_set_halo_state(fixture_guardians, false, false)
	var no_glow := await _capture("%s_no_glow.png" % label)

	_set_halo_state(fixture_guardians, true, false)
	_set_legacy_lights_enabled(true)
	var legacy := await _capture("%s_legacy_light.png" % label)

	_set_legacy_lights_enabled(false)
	_set_halo_state(fixture_guardians, true, true)
	_verify_emission_environment_binding(fixture_guardians, night_factor)
	var self_emission := await _capture("%s_self_emission.png" % label)

	for guardian_index in range(fixture_guardians.size()):
		var guardian := fixture_guardians[guardian_index]
		var transform := (
			get_viewport().get_screen_transform()
			* guardian.get_global_transform_with_canvas()
		)
		var center := transform.origin
		var radius := FIXTURE_LOCAL_RADIUS * transform.x.length()
		var body_radius := BODY_LOCAL_RADIUS * transform.x.length()
		var legacy_metrics := _measure_glow_delta(
			no_glow,
			legacy,
			center,
			radius,
			body_radius
		)
		var emission_metrics := _measure_glow_delta(
			no_glow,
			self_emission,
			center,
			radius,
			body_radius
		)
		var brightness_ratio := _safe_ratio(
			float(emission_metrics["positive_luminance"]),
			float(legacy_metrics["positive_luminance"])
		)
		var coverage_ratio := _safe_ratio(
			float(emission_metrics["changed_pixels"]),
			float(legacy_metrics["changed_pixels"])
		)
		var body_ratio := _safe_ratio(
			float(emission_metrics["body_positive_luminance"]),
			float(legacy_metrics["body_positive_luminance"])
		)
		var channel_share_error := _channel_share_error(
			legacy_metrics,
			emission_metrics
		)
		var region_mae := _measure_region_rgb_mae(
			legacy,
			self_emission,
			center,
			radius
		)
		print(
			(
				"GUARDIAN_SELF_EMISSION_AB phase=%s ground=%s "
				+ "brightness_ratio=%.4f coverage_ratio=%.4f "
				+ "body_ratio=%.4f channel_share_error=%.4f mae=%.4f"
			)
			% [
				label,
				guardian.name,
				brightness_ratio,
				coverage_ratio,
				body_ratio,
				channel_share_error,
				region_mae,
			]
		)
		_expect(
			absf(brightness_ratio - 1.0) <= MAX_BRIGHTNESS_RATIO_ERROR,
			"%s %s self-emission changed total glow brightness too much."
			% [label, guardian.name]
		)
		_expect(
			absf(coverage_ratio - 1.0) <= MAX_COVERAGE_RATIO_ERROR,
			"%s %s self-emission changed the visible glow radius too much."
			% [label, guardian.name]
		)
		_expect(
			body_ratio >= 0.88 and body_ratio <= 1.12,
			"%s %s self-emission no longer preserves body-center readability."
			% [label, guardian.name]
		)
		_expect(
			channel_share_error <= MAX_CHANNEL_SHARE_ERROR,
			"%s %s self-emission changed the cyan color balance too much."
			% [label, guardian.name]
		)
		_expect(
			region_mae <= MAX_REGION_RGB_MAE,
			"%s %s self-emission differs visibly from the legacy light fixture."
			% [label, guardian.name]
		)
		if guardian_index < fixture_receivers.size():
			_verify_receiver_visual_parity(
				label,
				fixture_receivers[guardian_index],
				no_glow,
				legacy,
				self_emission
			)


func _verify_status_visual_parity() -> void:
	for guardian in fixture_guardians:
		guardian.call("_set_direct_hit_flash_strength", 0.9)
		_expect(
			guardian.animated_sprite.material is ShaderMaterial
			and is_equal_approx(
				float(
					guardian.animated_sprite.get_instance_shader_parameter(
						&"direct_hit_flash_strength"
					)
				),
				0.9
			),
			"Hit-flash A/B must exercise the production status material."
		)
	await _verify_legacy_visual_parity("night_hit_flash", 1.0)
	for guardian in fixture_guardians:
		guardian.call("_set_direct_hit_flash_strength", 0.0)


func _verify_receiver_visual_parity(
	label: String,
	receiver: Enemy,
	no_glow: Image,
	legacy: Image,
	self_emission: Image
) -> void:
	var transform := (
		get_viewport().get_screen_transform()
		* receiver.get_global_transform_with_canvas()
	)
	var center := transform.origin
	var radius := 11.0 * transform.x.length()
	var legacy_metrics := _measure_glow_delta(
		no_glow,
		legacy,
		center,
		radius,
		radius
	)
	var emission_metrics := _measure_glow_delta(
		no_glow,
		self_emission,
		center,
		radius,
		radius
	)
	var brightness_ratio := _safe_ratio(
		float(emission_metrics["positive_luminance"]),
		float(legacy_metrics["positive_luminance"])
	)
	var region_mae := _measure_region_rgb_mae(
		legacy,
		self_emission,
		center,
		radius
	)
	print(
		"GUARDIAN_RECEIVER_AB phase=%s receiver=%s brightness_ratio=%.4f mae=%.4f"
		% [label, receiver.name, brightness_ratio, region_mae]
	)
	_expect(
		absf(brightness_ratio - 1.0)
		<= MAX_RECEIVER_BRIGHTNESS_RATIO_ERROR,
		"%s %s nearby foreground receiver lost legacy lighting."
		% [label, receiver.name]
	)
	_expect(
		region_mae <= MAX_RECEIVER_RGB_MAE,
		"%s %s nearby foreground receiver changed color too much."
		% [label, receiver.name]
	)


func _verify_dense_budget_parity(label: String, night_factor: float) -> void:
	day_night_controller.set_night_factor_immediate(night_factor)
	_set_legacy_lights_enabled(false)
	legacy_fixtures.hide()
	guardians.show()
	await get_tree().process_frame
	await get_tree().process_frame
	_set_dense_legacy_lights_enabled(false)
	_set_budgeted_emission_state(dense_guardians, 0, false)
	var no_glow := await _capture("%s_no_glow.png" % label)

	_set_budgeted_emission_state(dense_guardians, 0, true)
	_set_dense_legacy_lights_enabled(true)
	var legacy := await _capture("%s_legacy_budget.png" % label)

	_set_dense_legacy_lights_enabled(false)
	_set_budgeted_emission_state(
		dense_guardians,
		YuanshiInsectAura.MAX_ACTIVE_GUARDIAN_EMISSION_BOOSTS,
		true
	)
	var self_emission := await _capture("%s_self_emission_budget.png" % label)

	var cluster_center := Vector2.ZERO
	for guardian in dense_guardians:
		cluster_center += (
			get_viewport().get_screen_transform()
			* guardian.get_global_transform_with_canvas()
		).origin
	cluster_center /= float(maxi(dense_guardians.size(), 1))
	var cluster_radius := 88.0
	var legacy_metrics := _measure_glow_delta(
		no_glow,
		legacy,
		cluster_center,
		cluster_radius,
		cluster_radius
	)
	var emission_metrics := _measure_glow_delta(
		no_glow,
		self_emission,
		cluster_center,
		cluster_radius,
		cluster_radius
	)
	var brightness_ratio := _safe_ratio(
		float(emission_metrics["positive_luminance"]),
		float(legacy_metrics["positive_luminance"])
	)
	var region_mae := _measure_region_rgb_mae(
		legacy,
		self_emission,
		cluster_center,
		cluster_radius
	)
	var channel_share_error := _channel_share_error(
		legacy_metrics,
		emission_metrics
	)
	var luminance_ssim := _measure_region_luminance_ssim(
		legacy,
		self_emission,
		cluster_center,
		cluster_radius
	)
	var legacy_saturated := _count_saturated_pixels(
		legacy,
		cluster_center,
		cluster_radius
	)
	var emission_saturated := _count_saturated_pixels(
		self_emission,
		cluster_center,
		cluster_radius
	)
	var saturated_ratio := (
		1.0
		if legacy_saturated == 0 and emission_saturated == 0
		else _safe_ratio(
			float(emission_saturated),
			float(maxi(legacy_saturated, 1))
		)
	)
	print(
		(
			"GUARDIAN_DENSE_BUDGET_AB phase=%s brightness_ratio=%.4f "
			+ "mae=%.4f channel_share_error=%.4f ssim=%.4f "
			+ "saturated_ratio=%.4f legacy_saturated=%d "
			+ "emission_saturated=%d"
		)
		% [
			label,
			brightness_ratio,
			region_mae,
			channel_share_error,
			luminance_ssim,
			saturated_ratio,
			legacy_saturated,
			emission_saturated,
		]
	)
	_expect(
		absf(brightness_ratio - 1.0) <= MAX_DENSE_BRIGHTNESS_RATIO_ERROR,
		"%s dense self-emission changed the legacy 12-slot total brightness."
		% label
	)
	_expect(
		region_mae <= MAX_DENSE_RGB_MAE,
		"%s dense self-emission differs visibly from the legacy 12-slot fixture."
		% label
	)
	_expect(
		channel_share_error <= MAX_DENSE_CHANNEL_SHARE_ERROR,
		"%s dense self-emission changed the legacy cyan color balance."
		% label
	)
	_expect(
		luminance_ssim >= MIN_DENSE_LUMINANCE_SSIM,
		"%s dense self-emission changed the legacy glow structure."
		% label
	)
	_expect(
		absf(saturated_ratio - 1.0)
		<= MAX_DENSE_SATURATED_PIXEL_RATIO_ERROR,
		"%s dense self-emission changed the legacy saturation footprint."
		% label
	)
	_verify_dense_budget_states()
	print(
		"GUARDIAN_SELF_EMISSION_DENSE checked=%d boosted=12 real_lights=0"
		% dense_guardians.size()
	)


func _set_legacy_lights_enabled(enabled: bool) -> void:
	for child in legacy_fixtures.get_children():
		var light := child as PointLight2D
		if light != null:
			light.enabled = enabled


func _set_dense_legacy_lights_enabled(enabled: bool) -> void:
	for child in dense_legacy_lights.get_children():
		var light := child as PointLight2D
		if light != null:
			light.enabled = enabled


func _set_budgeted_emission_state(
	collection: Array[YuanshiInsectAura],
	boosted_count: int,
	halos_visible: bool
) -> void:
	for guardian_index in range(collection.size()):
		var guardian := collection[guardian_index]
		guardian.call(
			"_set_guardian_emission_boost_enabled",
			guardian_index < boosted_count
		)
		var halo := guardian.get_node_or_null("GuardianLightHalo") as Sprite2D
		var light_emission := guardian.get_node_or_null(
			"GuardianLightEmission"
		) as Sprite2D
		if halo != null:
			halo.visible = halos_visible
		if light_emission != null and not halos_visible:
			light_emission.visible = false


func _verify_dense_budget_states() -> void:
	var boosted_count := 0
	for guardian_index in range(dense_guardians.size()):
		var guardian := dense_guardians[guardian_index]
		var halo := guardian.get_node_or_null("GuardianLightHalo") as Sprite2D
		var light_emission := guardian.get_node_or_null(
			"GuardianLightEmission"
		) as Sprite2D
		var should_be_boosted := (
			guardian_index
			< YuanshiInsectAura.MAX_ACTIVE_GUARDIAN_EMISSION_BOOSTS
		)
		var boosted := light_emission != null and light_emission.visible
		var bound_controller: Variant = (
			light_emission.get("_controller")
			if light_emission != null
			else null
		)
		if boosted:
			boosted_count += 1
		_expect(
			halo != null
			and halo.visible
			and halo.modulate.is_equal_approx(LEGACY_HALO_MODULATE)
			and boosted == should_be_boosted,
			"Dense guardian %d no longer preserves its legacy visual budget tier."
			% guardian_index
		)
		_expect(
			(bound_controller == day_night_controller) == should_be_boosted,
			"Only the twelve visible emission boosts may bind the day/night controller."
		)
	_expect(
		boosted_count
		== YuanshiInsectAura.MAX_ACTIVE_GUARDIAN_EMISSION_BOOSTS,
		"Dense self-emission fixture must keep exactly twelve boosted guardians."
	)
	_verify_emission_environment_binding(
		dense_guardians,
		day_night_controller.night_factor
	)


func _verify_emission_environment_binding(
	collection: Array[YuanshiInsectAura],
	expected_night_factor: float
) -> void:
	for guardian in collection:
		var emission := guardian.get_node_or_null(
			"GuardianLightEmission"
		) as Sprite2D
		if emission == null or not emission.is_visible_in_tree():
			continue
		var runtime_material := emission.material as ShaderMaterial
		_expect(
			emission.get("_controller") == day_night_controller
			and runtime_material != null
			and is_equal_approx(
				float(
					runtime_material.get_shader_parameter(
						&"night_factor"
					)
				),
				expected_night_factor
			)
			and (
				runtime_material.get_shader_parameter(
					&"canvas_modulate_color"
				) as Color
			).is_equal_approx(day_night_controller.color),
			"Visible emission boosts must use their branch-owned day/night state."
		)


func _set_halo_state(
	collection: Array[YuanshiInsectAura],
	halo_visible: bool,
	emission_visible: bool
) -> void:
	for guardian in collection:
		var halo := guardian.get_node_or_null("GuardianLightHalo") as Sprite2D
		var light_emission := guardian.get_node_or_null(
			"GuardianLightEmission"
		) as Sprite2D
		if halo == null:
			continue
		halo.modulate = LEGACY_HALO_MODULATE
		halo.visible = halo_visible
		if light_emission != null:
			light_emission.visible = emission_visible


func _count_saturated_pixels(
	image: Image,
	center: Vector2,
	radius: float
) -> int:
	var saturated_count := 0
	var radius_squared := radius * radius
	for y in range(
		maxi(floori(center.y - radius), 0),
		mini(ceili(center.y + radius) + 1, image.get_height())
	):
		for x in range(
			maxi(floori(center.x - radius), 0),
			mini(ceili(center.x + radius) + 1, image.get_width())
		):
			if center.distance_squared_to(Vector2(x, y)) > radius_squared:
				continue
			var color := image.get_pixel(x, y)
			if maxf(color.r, maxf(color.g, color.b)) >= 0.99:
				saturated_count += 1
	return saturated_count


func _measure_glow_delta(
	baseline: Image,
	illuminated: Image,
	center: Vector2,
	radius: float,
	body_radius: float
) -> Dictionary:
	var positive_luminance := 0.0
	var body_positive_luminance := 0.0
	var positive_red := 0.0
	var positive_green := 0.0
	var positive_blue := 0.0
	var changed_pixels := 0
	var max_luminance := 0.0
	var radius_squared := radius * radius
	var body_radius_squared := body_radius * body_radius
	for y in range(
		maxi(floori(center.y - radius), 0),
		mini(ceili(center.y + radius) + 1, illuminated.get_height())
	):
		for x in range(
			maxi(floori(center.x - radius), 0),
			mini(ceili(center.x + radius) + 1, illuminated.get_width())
		):
			var offset := Vector2(x, y) - center
			if offset.length_squared() > radius_squared:
				continue
			var before := baseline.get_pixel(x, y)
			var after := illuminated.get_pixel(x, y)
			var luminance_delta := (
				after.get_luminance() - before.get_luminance()
			)
			var positive_delta := maxf(luminance_delta, 0.0)
			positive_luminance += positive_delta
			positive_red += maxf(after.r - before.r, 0.0)
			positive_green += maxf(after.g - before.g, 0.0)
			positive_blue += maxf(after.b - before.b, 0.0)
			max_luminance = maxf(max_luminance, luminance_delta)
			if luminance_delta >= VISIBLE_LUMINANCE_STEP:
				changed_pixels += 1
			if offset.length_squared() <= body_radius_squared:
				body_positive_luminance += positive_delta
	return {
		"positive_luminance": positive_luminance,
		"body_positive_luminance": body_positive_luminance,
		"positive_red": positive_red,
		"positive_green": positive_green,
		"positive_blue": positive_blue,
		"changed_pixels": changed_pixels,
		"max_luminance": max_luminance,
	}


func _channel_share_error(legacy: Dictionary, emission: Dictionary) -> float:
	var legacy_total := (
		float(legacy["positive_red"])
		+ float(legacy["positive_green"])
		+ float(legacy["positive_blue"])
	)
	var emission_total := (
		float(emission["positive_red"])
		+ float(emission["positive_green"])
		+ float(emission["positive_blue"])
	)
	if legacy_total <= 0.0001 or emission_total <= 0.0001:
		return INF
	return maxf(
		absf(
			float(legacy["positive_red"]) / legacy_total
			- float(emission["positive_red"]) / emission_total
		),
		maxf(
			absf(
				float(legacy["positive_green"]) / legacy_total
				- float(emission["positive_green"]) / emission_total
			),
			absf(
				float(legacy["positive_blue"]) / legacy_total
				- float(emission["positive_blue"]) / emission_total
			)
		)
	)


func _measure_region_rgb_mae(
	first: Image,
	second: Image,
	center: Vector2,
	radius: float
) -> float:
	var total_error := 0.0
	var sample_count := 0
	var radius_squared := radius * radius
	for y in range(
		maxi(floori(center.y - radius), 0),
		mini(ceili(center.y + radius) + 1, first.get_height())
	):
		for x in range(
			maxi(floori(center.x - radius), 0),
			mini(ceili(center.x + radius) + 1, first.get_width())
		):
			if center.distance_squared_to(Vector2(x, y)) > radius_squared:
				continue
			var first_color := first.get_pixel(x, y)
			var second_color := second.get_pixel(x, y)
			total_error += (
				absf(first_color.r - second_color.r)
				+ absf(first_color.g - second_color.g)
				+ absf(first_color.b - second_color.b)
			) / 3.0
			sample_count += 1
	return total_error / float(maxi(sample_count, 1))


func _measure_region_luminance_ssim(
	first: Image,
	second: Image,
	center: Vector2,
	radius: float
) -> float:
	var first_sum := 0.0
	var second_sum := 0.0
	var first_squared_sum := 0.0
	var second_squared_sum := 0.0
	var cross_sum := 0.0
	var sample_count := 0
	var radius_squared := radius * radius
	for y in range(
		maxi(floori(center.y - radius), 0),
		mini(ceili(center.y + radius) + 1, first.get_height())
	):
		for x in range(
			maxi(floori(center.x - radius), 0),
			mini(ceili(center.x + radius) + 1, first.get_width())
		):
			if center.distance_squared_to(Vector2(x, y)) > radius_squared:
				continue
			var first_luminance := first.get_pixel(x, y).get_luminance()
			var second_luminance := second.get_pixel(x, y).get_luminance()
			first_sum += first_luminance
			second_sum += second_luminance
			first_squared_sum += first_luminance * first_luminance
			second_squared_sum += second_luminance * second_luminance
			cross_sum += first_luminance * second_luminance
			sample_count += 1
	if sample_count == 0:
		return 0.0
	var divisor := float(sample_count)
	var first_mean := first_sum / divisor
	var second_mean := second_sum / divisor
	var first_variance := maxf(
		first_squared_sum / divisor - first_mean * first_mean,
		0.0
	)
	var second_variance := maxf(
		second_squared_sum / divisor - second_mean * second_mean,
		0.0
	)
	var covariance := cross_sum / divisor - first_mean * second_mean
	const LUMINANCE_STABILITY := 0.01 * 0.01
	const CONTRAST_STABILITY := 0.03 * 0.03
	return (
		(2.0 * first_mean * second_mean + LUMINANCE_STABILITY)
		* (2.0 * covariance + CONTRAST_STABILITY)
		/ (
			(first_mean * first_mean + second_mean * second_mean + LUMINANCE_STABILITY)
			* (first_variance + second_variance + CONTRAST_STABILITY)
		)
	)


func _safe_ratio(value: float, baseline: float) -> float:
	if baseline <= 0.0001:
		return INF
	return value / baseline


func _capture(file_name: String) -> Image:
	await get_tree().process_frame
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	var source_is_linear_hdr := (
		bool(ProjectSettings.get_setting("rendering/viewport/hdr_2d", false))
		and image.get_format() not in [Image.FORMAT_RGB8, Image.FORMAT_RGBA8]
	)
	if source_is_linear_hdr:
		image.convert(Image.FORMAT_RGBA8)
		image.linear_to_srgb()
	image.convert(Image.FORMAT_RGB8)
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
