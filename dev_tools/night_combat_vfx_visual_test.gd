extends Node2D

const OUTPUT_DIRECTORY := "res://dev_tools/output/night_combat_vfx"

@onready var day_night_controller: DayNightController = $DayNightController
@onready var flash_pool: NightVfxFlashPool = $NightVfxFlashPool
@onready var rpg_explosion: Node2D = $Explosions/RpgExplosion
@onready var skill_explosion: Node2D = $Explosions/SkillExplosion
@onready var mortar_explosion: BambooMortarShell = $Explosions/MortarExplosion
@onready var sakura_explosion: Node2D = $Explosions/SakuraExplosion
@onready var ak_projectile_sprite: AnimatedSprite2D = (
	$Projectiles/AkBullet/AnimatedSprite2D
)
@onready var frost_projectile_sprite: AnimatedSprite2D = (
	$SecondaryProjectiles/FrostIceSpike/AnimatedSprite2D
)

var failures: PackedStringArray = []


func _ready() -> void:
	_mute_audio()
	DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path(OUTPUT_DIRECTORY)
	)
	await get_tree().process_frame
	_prepare_static_fixtures()
	await get_tree().create_timer(0.45).timeout

	day_night_controller.set_night_factor_immediate(0.0)
	_set_explosion_frames(2, 2, 2, 2)
	_set_emission_overlays_visible(self, false)
	await _capture("day_base.png")
	_set_emission_overlays_visible(self, true)
	await _capture("day.png")

	day_night_controller.set_night_factor_immediate(1.0)
	_set_explosion_frames(2, 2, 2, 2)
	var single_pass_material := ak_projectile_sprite.material
	var frost_single_pass_material := frost_projectile_sprite.material
	ak_projectile_sprite.material = null
	frost_projectile_sprite.material = null
	var ak_body_only := await _capture("night_ak_body_only.png")
	ak_projectile_sprite.material = single_pass_material
	frost_projectile_sprite.material = frost_single_pass_material
	var ak_single_pass := await _capture("night_ak_single_pass.png")
	_verify_single_pass_projectile(
		ak_projectile_sprite,
		&"AK",
		ak_body_only,
		ak_single_pass,
		12.0,
		42.0
	)
	_verify_single_pass_projectile(
		frost_projectile_sprite,
		&"FROST",
		ak_body_only,
		ak_single_pass,
		40.0,
		70.0
	)
	_set_projectile_halos_visible(self, false)
	var night_without_halos := await _capture("night_projectiles_no_halo.png")
	_set_projectile_halos_visible(self, true)
	var night_unlit := await _capture("night_unlit.png")
	_verify_projectile_halo_diff(night_without_halos, night_unlit)
	_set_flash_decay_exponent(2.2)
	_request_showcase_flashes(0.5)
	_freeze_active_flashes()
	var old_decay := await _capture("night_old_decay.png")
	_stop_showcase_flashes()

	_set_flash_decay_exponent(1.8)
	_request_showcase_flashes(0.0)
	_freeze_active_flashes()
	_print_light_state("peak")
	var night_peak := await _capture("night_peak.png")
	_verify_flash_illumination(night_unlit, night_peak)
	_stop_showcase_flashes()

	_request_showcase_flashes(0.5)
	_freeze_active_flashes()
	_print_light_state("decay")
	var night_decay := await _capture("night_decay.png")
	_verify_slower_mid_decay(night_unlit, old_decay, night_decay)
	_stop_showcase_flashes()

	_request_showcase_flashes(0.75)
	_freeze_active_flashes()
	_print_light_state("tail")
	var night_tail := await _capture("night_tail.png")
	_verify_tail_illumination(night_unlit, night_tail)
	_stop_showcase_flashes()

	if failures.is_empty():
		print(
			"NIGHT_COMBAT_VFX_VISUAL_TEST_OK capacity=%d active_tail=%d" % [
				flash_pool.get_capacity(),
				flash_pool.get_active_flash_count(),
			]
		)
		get_tree().quit(0)
		return
	print("NIGHT_COMBAT_VFX_VISUAL_TEST_FAILED count=%d" % failures.size())
	get_tree().quit(1)


func _prepare_static_fixtures() -> void:
	ak_projectile_sprite.pause()
	ak_projectile_sprite.set_frame_and_progress(1, 0.35)
	frost_projectile_sprite.pause()
	frost_projectile_sprite.set_frame_and_progress(0, 0.35)
	_stop_animated_pair(rpg_explosion.get_node("AnimatedSprite2D"))
	_stop_animated_pair(skill_explosion.get_node("AnimatedSprite2D"))
	_stop_animated_pair(sakura_explosion.get_node("AnimatedSprite2D"))
	mortar_explosion.setup(
		Vector2(545, 255),
		Vector2(545, 255),
		100,
		50,
		false,
		0,
		0.34
	)
	_stop_animated_pair(mortar_explosion.visual)


func _stop_animated_pair(sprite: AnimatedSprite2D) -> void:
	sprite.pause()
	var overlay := sprite.get_node_or_null("EmissionOverlay") as AnimatedSprite2D
	if overlay != null:
		overlay.pause()


func _set_explosion_frames(
	rpg_frame: int,
	skill_frame: int,
	mortar_frame: int,
	sakura_frame: int
) -> void:
	_set_animated_pair_frame(
		rpg_explosion.get_node("AnimatedSprite2D") as AnimatedSprite2D,
		rpg_frame
	)
	_set_animated_pair_frame(
		skill_explosion.get_node("AnimatedSprite2D") as AnimatedSprite2D,
		skill_frame
	)
	_set_animated_pair_frame(mortar_explosion.visual, mortar_frame)
	_set_animated_pair_frame(
		sakura_explosion.get_node("AnimatedSprite2D") as AnimatedSprite2D,
		sakura_frame
	)


func _set_animated_pair_frame(sprite: AnimatedSprite2D, frame_index: int) -> void:
	var safe_frame := clampi(
		frame_index,
		0,
		sprite.sprite_frames.get_frame_count(sprite.animation) - 1
	)
	sprite.set_frame_and_progress(safe_frame, 0.35)
	var overlay := sprite.get_node_or_null("EmissionOverlay") as AnimatedSprite2D
	if overlay != null:
		overlay.animation = sprite.animation
		overlay.set_frame_and_progress(safe_frame, 0.35)


func _set_emission_overlays_visible(branch: Node, visible: bool) -> void:
	for child in branch.get_children():
		if child.name == &"EmissionOverlay":
			(child as CanvasItem).visible = visible
		_set_emission_overlays_visible(child, visible)


func _set_projectile_halos_visible(branch: Node, visible: bool) -> void:
	for child in branch.get_children():
		if child.name == &"ProjectileHalo":
			(child as CanvasItem).visible = visible
		_set_projectile_halos_visible(child, visible)


func _request_showcase_flashes(decay_progress: float) -> void:
	var safe_progress := clampf(decay_progress, 0.0, 1.0)
	flash_pool.request_flash(
		rpg_explosion.global_position,
		Color(1.0, 0.56, 0.22, 1.0),
		1.08,
		0.82,
		0.04,
		0.06,
		0.30,
		2,
		0.04 + 0.06 + 0.30 * safe_progress
	)
	flash_pool.request_flash(
		skill_explosion.global_position,
		Color(1.0, 0.6, 0.25, 1.0),
		1.12,
		0.80,
		0.04,
		0.06,
		0.30,
		2,
		0.04 + 0.06 + 0.30 * safe_progress
	)
	flash_pool.request_flash(
		mortar_explosion.global_position,
		Color(1.0, 0.58, 0.24, 1.0),
		1.05,
		0.78,
		0.035,
		0.055,
		0.28,
		2,
		0.035 + 0.055 + 0.28 * safe_progress
	)
	flash_pool.request_flash(
		sakura_explosion.global_position,
		Color(1.0, 0.5, 0.86, 1.0),
		1.18,
		1.05,
		0.045,
		0.065,
		0.32,
		3,
		0.045 + 0.065 + 0.32 * safe_progress
	)


func _set_flash_decay_exponent(value: float) -> void:
	for child in flash_pool.get_children():
		(child as NightVfxFlash2D).decay_exponent = value


func _freeze_active_flashes() -> void:
	for child in flash_pool.get_children():
		var flash := child as NightVfxFlash2D
		if flash.is_flash_active():
			flash.set_process(false)


func _stop_showcase_flashes() -> void:
	for child in flash_pool.get_children():
		(child as NightVfxFlash2D).stop_flash()


func _print_light_state(label: String) -> void:
	var first_flash := flash_pool.get_child(0) as NightVfxFlash2D
	print(
		(
			"NIGHT_COMBAT_VFX_LIGHT label=%s factor=%.3f active=%d "
			+ "flash_enabled=%s flash_energy=%.4f flash_strength=%.4f "
			+ "flash_scale=%.4f"
		)
		% [
			label,
			day_night_controller.night_factor,
			flash_pool.get_active_flash_count(),
			str(first_flash.enabled),
			first_flash.energy,
			first_flash.get_emission_strength(),
			first_flash.texture_scale,
		]
	)


func _capture(file_name: String) -> Image:
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	var save_path := "%s/%s" % [OUTPUT_DIRECTORY, file_name]
	var error := image.save_png(ProjectSettings.globalize_path(save_path))
	if error != OK:
		push_error("Failed to save visual capture %s: %s" % [save_path, error])
		failures.append("无法保存视觉截图：%s" % file_name)
	return image


func _verify_flash_illumination(unlit: Image, peak: Image) -> void:
	var samples := [
		[rpg_explosion, 42.0, 105.0, "RPG"],
		[skill_explosion, 38.0, 100.0, "维什爆炸"],
		[mortar_explosion, 30.0, 100.0, "竹迫击炮"],
		[sakura_explosion, 72.0, 135.0, "樱花爆炸"],
	]
	for sample in samples:
		var effect := sample[0] as Node2D
		var metrics := _measure_light_annulus(
			unlit,
			peak,
			effect.get_global_transform_with_canvas().origin,
			float(sample[1]),
			float(sample[2])
		)
		print(
			(
				"NIGHT_COMBAT_VFX_RENDER effect=%s avg_delta=%.4f "
				+ "changed_pixels=%d max_delta=%.4f"
			)
			% [
				String(sample[3]),
				float(metrics["average_positive_delta"]),
				int(metrics["changed_pixels"]),
				float(metrics["max_delta"]),
			]
		)
		_expect(
			float(metrics["average_positive_delta"]) >= 0.008
			and int(metrics["changed_pixels"]) >= 1000
			and float(metrics["max_delta"]) >= 0.06,
			"%s的峰值灯光没有在爆炸本体之外产生足够的夜间环境反光。" % sample[3]
		)


func _verify_projectile_halo_diff(without_halos: Image, with_halos: Image) -> void:
	var positive_delta_total := 0.0
	var changed_pixels := 0
	var max_delta := 0.0
	for y in range(with_halos.get_height()):
		for x in range(with_halos.get_width()):
			var delta := (
				with_halos.get_pixel(x, y).get_luminance()
				- without_halos.get_pixel(x, y).get_luminance()
			)
			positive_delta_total += maxf(delta, 0.0)
			max_delta = maxf(max_delta, delta)
			if delta >= 0.002:
				changed_pixels += 1
	print(
		(
			"NIGHT_COMBAT_PROJECTILE_HALO total_delta=%.4f "
			+ "changed_pixels=%d max_delta=%.4f"
		)
		% [positive_delta_total, changed_pixels, max_delta]
	)
	_expect(
		positive_delta_total >= 3.0
		and changed_pixels >= 150
		and max_delta >= 0.01,
		"弹体外侧没有形成可测量但克制的柔和空间扩散。"
	)


func _verify_single_pass_projectile(
	projectile_sprite: AnimatedSprite2D,
	label: StringName,
	body_only: Image,
	single_pass: Image,
	core_radius: float,
	bloom_outer_radius: float
) -> void:
	var center := (
		get_viewport().get_screen_transform()
		* projectile_sprite.get_global_transform_with_canvas()
	).origin
	var core_metrics := _measure_light_annulus(
		body_only,
		single_pass,
		center,
		0.0,
		core_radius
	)
	var bloom_metrics := _measure_light_annulus(
		body_only,
		single_pass,
		center,
		core_radius,
		bloom_outer_radius
	)
	var body_only_contrast := _measure_local_luminance_contrast(
		body_only,
		center,
		ceili(core_radius)
	)
	var single_pass_contrast := _measure_local_luminance_contrast(
		single_pass,
		center,
		ceili(core_radius)
	)
	print(
		(
			"PROJECTILE_SINGLE_PASS label=%s core_avg=%.5f "
			+ "core_changed=%d core_max=%.5f bloom_avg=%.5f "
			+ "bloom_changed=%d bloom_max=%.5f body_contrast=%.5f "
			+ "single_pass_contrast=%.5f"
		)
		% [
			label,
			float(core_metrics["average_positive_delta"]),
			int(core_metrics["changed_pixels"]),
			float(core_metrics["max_delta"]),
			float(bloom_metrics["average_positive_delta"]),
			int(bloom_metrics["changed_pixels"]),
			float(bloom_metrics["max_delta"]),
			body_only_contrast,
			single_pass_contrast,
		]
	)
	_expect(
		float(core_metrics["average_positive_delta"]) >= 0.01
		and float(core_metrics["max_delta"]) >= 0.05,
		"弹体单通道材质没有生成可测量的HDR自发光核心：%s" % label
	)
	_expect(
		float(bloom_metrics["average_positive_delta"]) >= 0.00005
		and int(bloom_metrics["changed_pixels"]) >= 12,
		"弹体单通道HDR核心没有形成轻微柔光扩散：%s" % label
	)
	_expect(
		single_pass_contrast >= 0.65 * body_only_contrast,
		"弹体单通道自发光把像素本体洗白，主体清晰度不足：%s" % label
	)


func _measure_local_luminance_contrast(
	image: Image,
	center: Vector2,
	radius: int
) -> float:
	var minimum := 1.0
	var maximum := 0.0
	for y in range(
		maxi(floori(center.y) - radius, 0),
		mini(ceili(center.y) + radius + 1, image.get_height())
	):
		for x in range(
			maxi(floori(center.x) - radius, 0),
			mini(ceili(center.x) + radius + 1, image.get_width())
		):
			var luminance := image.get_pixel(x, y).get_luminance()
			minimum = minf(minimum, luminance)
			maximum = maxf(maximum, luminance)
	return maximum - minimum


func _verify_slower_mid_decay(
	unlit: Image,
	old_decay: Image,
	new_decay: Image
) -> void:
	var old_metrics := _measure_light_annulus(
		unlit,
		old_decay,
		rpg_explosion.get_global_transform_with_canvas().origin,
		42.0,
		105.0
	)
	var new_metrics := _measure_light_annulus(
		unlit,
		new_decay,
		rpg_explosion.get_global_transform_with_canvas().origin,
		42.0,
		105.0
	)
	var old_average := float(old_metrics["average_positive_delta"])
	var new_average := float(new_metrics["average_positive_delta"])
	print(
		"NIGHT_COMBAT_VFX_DECAY old_mid=%.5f new_mid=%.5f ratio=%.3f"
		% [old_average, new_average, new_average / maxf(old_average, 0.00001)]
	)
	_expect(
		new_average >= old_average * 1.15,
		"1.8指数必须让爆炸中段环境反光比旧2.2指数更平缓。"
	)


func _verify_tail_illumination(unlit: Image, tail: Image) -> void:
	var metrics := _measure_light_annulus(
		unlit,
		tail,
		rpg_explosion.get_global_transform_with_canvas().origin,
		42.0,
		105.0
	)
	print(
		(
			"NIGHT_COMBAT_VFX_TAIL avg_delta=%.5f "
			+ "changed_pixels=%d max_delta=%.5f"
		)
		% [
			float(metrics["average_positive_delta"]),
			int(metrics["changed_pixels"]),
			float(metrics["max_delta"]),
		]
	)
	_expect(
		float(metrics["average_positive_delta"]) >= 0.0004
		and float(metrics["max_delta"]) >= 0.004,
		"75%衰减点仍应保留克制、可测量的环境尾光。"
	)
func _measure_light_annulus(
	unlit: Image,
	peak: Image,
	center: Vector2,
	inner_radius: float,
	outer_radius: float
) -> Dictionary:
	var positive_delta_total := 0.0
	var changed_pixels := 0
	var max_delta := 0.0
	var sample_count := 0
	var outer_radius_squared := outer_radius * outer_radius
	var inner_radius_squared := inner_radius * inner_radius
	for y in range(
		maxi(floori(center.y - outer_radius), 0),
		mini(ceili(center.y + outer_radius) + 1, peak.get_height())
	):
		for x in range(
			maxi(floori(center.x - outer_radius), 0),
			mini(ceili(center.x + outer_radius) + 1, peak.get_width())
		):
			var distance_squared := center.distance_squared_to(Vector2(x, y))
			if (
				distance_squared < inner_radius_squared
				or distance_squared > outer_radius_squared
			):
				continue
			var delta := (
				peak.get_pixel(x, y).get_luminance()
				- unlit.get_pixel(x, y).get_luminance()
			)
			positive_delta_total += maxf(delta, 0.0)
			max_delta = maxf(max_delta, delta)
			if delta >= 0.015:
				changed_pixels += 1
			sample_count += 1
	return {
		"average_positive_delta": (
			positive_delta_total / float(maxi(sample_count, 1))
		),
		"changed_pixels": changed_pixels,
		"max_delta": max_delta,
	}


func _expect(condition: bool, message: String) -> void:
	if condition:
		return
	failures.append(message)
	push_error(message)


func _mute_audio() -> void:
	for bus_index in range(AudioServer.bus_count):
		AudioServer.set_bus_mute(bus_index, true)
