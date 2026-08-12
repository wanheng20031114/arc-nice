extends SceneTree


const SCENE_PATH := "res://scene/plant_defense/life_tower.tscn"
const CONFIG := preload(
	"res://resources/config/plant_defense/life_tower.tres"
)
const EXPECTED_PERIOD_SECONDS := 2.0
const EXPECTED_AMPLITUDE_SOURCE_PIXELS := 2.0


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	var packed_scene := load(SCENE_PATH) as PackedScene
	_assert(packed_scene != null, "Life Tower scene failed to load.")
	var tower := packed_scene.instantiate() as LifeTower
	_assert(tower != null, "Life Tower scene failed to instantiate.")
	root.add_child(tower)
	await process_frame
	tower.setup(
		CONFIG,
		null,
		[Vector2i.ZERO, Vector2i.RIGHT, Vector2i.DOWN, Vector2i.ONE]
	)
	_assert(CONFIG is LifeTowerConfig, "Life Tower must use LifeTowerConfig.")
	_assert(CONFIG.is_valid(), "Life Tower config must be valid.")
	_assert(CONFIG.plant_id == &"life_tower", "Life Tower plant_id is invalid.")
	_assert(CONFIG.display_name == "生命强化塔", "Life Tower display name is invalid.")
	_assert(CONFIG.footprint_size == Vector2i(2, 2), "Life Tower must occupy 2x2 cells.")
	_assert(CONFIG.max_health == 2400, "Life Tower max health must be 2400.")
	_assert(CONFIG.physical_defense == 5, "Life Tower physical defense must be 5.")
	_assert(CONFIG.magic_defense == 0, "Life Tower magic defense must be 0.")
	_assert(CONFIG.supports_multiplayer, "Life Tower must support multiplayer.")
	_assert(
		CONFIG.building_category
		== PlantDefenseConfig.BuildingCategory.SUPPORT_TOWER,
		"Life Tower must be registered as a support tower."
	)
	_assert(
		is_equal_approx(CONFIG.max_health_bonus_ratio, 0.10),
		"Life Tower player max-health bonus must be 10%."
	)
	_assert(tower.max_health == 2400, "Scene setup must apply config max health.")
	_assert(tower.current_health == 2400, "Life Tower must start at full health.")
	_assert(tower.physical_defense == 5, "Scene setup must apply physical defense.")
	_assert(tower.magic_defense == 0, "Scene setup must apply magic defense.")
	_assert(tower.is_operational, "A non-animated setup must finish construction.")

	var visual_root := tower.get_node("VisualRoot") as Node2D
	var lower_body := tower.get_node("VisualRoot/LowerBody") as Sprite2D
	var heart_root := tower.get_node("VisualRoot/HeartBobRoot") as Node2D
	var heart := tower.get_node(
		"VisualRoot/HeartBobRoot/HeartForeground"
	) as Sprite2D
	var heart_motes := tower.get_node(
		"VisualRoot/HeartBobRoot/HeartMotes"
	) as GPUParticles2D
	var player := tower.get_node("HeartBobAnimationPlayer") as AnimationPlayer
	var health_bar := tower.get_node("HealthBar") as PlantHealthBar
	_assert(visual_root != null, "VisualRoot is missing.")
	_assert(lower_body != null, "LowerBody is missing.")
	_assert(heart_root != null, "HeartBobRoot is missing.")
	_assert(heart != null, "HeartForeground is missing.")
	_assert(heart_motes != null, "HeartMotes is missing.")
	_assert(player != null, "HeartBobAnimationPlayer is missing.")
	_assert(health_bar != null, "HealthBar is missing.")
	_assert(visual_root.scale == Vector2(0.5, 0.5), "VisualRoot scale must be 0.5.")
	_assert(lower_body.texture != null, "LowerBody texture is not imported.")
	_assert(heart.texture != null, "Heart texture is not imported.")
	_assert(lower_body.texture.get_size() == Vector2(64, 64), "LowerBody must be 64x64.")
	_assert(heart.texture.get_size() == Vector2(64, 64), "Heart must be 64x64.")
	_assert(lower_body.z_index == 0, "LowerBody z_index must be 0.")
	_assert(heart.z_index == 4, "Heart z_index must be 4.")
	_assert(
		tower.find_children("*", "GPUParticles2D", true, false).size() == 1
		and tower.find_children("*", "CPUParticles2D", true, false).is_empty(),
		"Life Tower must use exactly one GPU emitter and no CPU emitters."
	)
	_assert(
		tower.find_children(
			"*", "VisibleOnScreenNotifier2D", true, false
		).is_empty(),
		"Heart motes must rely on their native visibility_rect without a duplicate notifier."
	)
	var mote_material := heart_motes.process_material as ParticleProcessMaterial
	var mote_alpha_texture := mote_material.color_ramp as GradientTexture1D
	var mote_alpha_gradient := mote_alpha_texture.gradient
	_assert(
		heart_motes.get_parent() == heart_root
		and heart_motes.z_index == 3
		and not heart_motes.local_coords
		and heart_motes.texture_filter == CanvasItem.TEXTURE_FILTER_NEAREST,
		"Heart motes must follow the heart emitter, render behind it, and keep nearest sampling."
	)
	_assert(
		heart_motes.texture != null
		and heart_motes.texture.get_size() == Vector2.ONE
		and heart_motes.texture.get_size() * visual_root.scale == Vector2(0.5, 0.5),
		"Heart motes must match exactly one native pixel in the 64x64 heart artwork."
	)
	_assert(
		heart_motes.amount == 8
		and is_equal_approx(heart_motes.lifetime, 0.8)
		and heart_motes.preprocess == 0.0
		and heart_motes.fixed_fps == 30
		and heart_motes.process_mode == Node.PROCESS_MODE_INHERIT
		and heart_motes.visibility_rect.size == Vector2(36, 30),
		"Heart mote emitter must stay within the authored particle budget."
	)
	var second_tower := packed_scene.instantiate() as LifeTower
	_assert(second_tower != null, "Second Life Tower particle fixture failed to instantiate.")
	var second_heart_motes := second_tower.get_node(
		"VisualRoot/HeartBobRoot/HeartMotes"
	) as GPUParticles2D
	_assert(
		second_heart_motes != null
		and second_heart_motes.emitting
		and second_heart_motes.visible
		and second_heart_motes.process_mode == Node.PROCESS_MODE_INHERIT
		and second_heart_motes.process_material == heart_motes.process_material
		and second_heart_motes.texture == heart_motes.texture,
		"The authored scene must preview shared heart mote resources in the editor."
	)
	second_tower.free()
	_assert(
		mote_material != null
		and mote_material.emission_shape
		== ParticleProcessMaterial.EMISSION_SHAPE_BOX
		and mote_material.emission_shape_offset == Vector3(0, -4, 0)
		and mote_material.emission_box_extents == Vector3(7, 3, 0)
		and is_equal_approx(mote_material.spread, 65.0)
		and is_equal_approx(mote_material.initial_velocity_min, 4.0)
		and is_equal_approx(mote_material.initial_velocity_max, 7.0)
		and mote_material.gravity == Vector3(0, -0.5, 0)
		and is_equal_approx(mote_material.radial_velocity_min, 2.0)
		and is_equal_approx(mote_material.radial_velocity_max, 4.0)
		and mote_material.direction.y < 0.0,
		"Heart motes must emerge from behind the upper heart edge in an outward fan."
	)
	_assert(
		mote_material.color.is_equal_approx(Color(0.956863, 0.184314, 0.058824, 1))
		and mote_alpha_gradient != null
		and mote_alpha_gradient.offsets == PackedFloat32Array([0, 0.78, 0.9, 1])
		and is_equal_approx(mote_alpha_gradient.colors[0].a, 0.94)
		and is_equal_approx(mote_alpha_gradient.colors[1].a, 0.94)
		and is_equal_approx(mote_alpha_gradient.colors[2].a, 0.35)
		and is_zero_approx(mote_alpha_gradient.colors[3].a),
		"Heart motes must match the heart red and use a short final fade."
	)
	_assert(
		is_equal_approx(
			heart_motes.lifetime * (1.0 - mote_alpha_gradient.offsets[1]),
			0.176,
		),
		"Heart mote fade must finish within the final 0.176 seconds."
	)
	_assert(
		health_bar.custom_minimum_size == Vector2(24, 4)
		and health_bar.size == Vector2(24, 4),
		"Life Tower health bar must render on a 24x4 integer pixel grid."
	)
	_assert(
		health_bar.offset_left == -12.0
		and health_bar.offset_top == -10.0
		and health_bar.offset_right == 12.0
		and health_bar.offset_bottom == -6.0
		and health_bar.scale == Vector2.ONE,
		"Life Tower health bar must keep its authored top edge and integer layout."
	)
	_assert(
		lower_body.texture_filter == CanvasItem.TEXTURE_FILTER_NEAREST,
		"LowerBody must use nearest filtering."
	)
	_assert(
		heart.texture_filter == CanvasItem.TEXTURE_FILTER_NEAREST,
		"Heart must use nearest filtering."
	)
	_assert(
		heart_motes.emitting and heart_motes.visible,
		"A completed Life Tower must emit and rely on native visibility_rect off screen."
	)
	tower.call("_on_construction_started")
	_assert(
		not heart_motes.emitting
		and not heart_motes.visible,
		"Life Tower construction must suspend heart motes."
	)
	tower.call("_on_construction_finished", false)
	_assert(
		heart_motes.emitting
		and heart_motes.visible,
		"Heart motes must resume after construction and use visibility_rect for off-screen culling."
	)

	var animation := player.get_animation(&"heart_bob")
	_assert(animation != null, "heart_bob animation is missing.")
	_assert(
		is_equal_approx(animation.length, EXPECTED_PERIOD_SECONDS),
		"heart_bob period must be 2 seconds."
	)
	_assert(
		animation.loop_mode == Animation.LOOP_LINEAR,
		"heart_bob must loop linearly."
	)
	_assert(animation.get_track_count() == 1, "heart_bob must have one track.")
	_assert(
		animation.track_get_path(0) == NodePath("VisualRoot/HeartBobRoot:position"),
		"heart_bob must animate only HeartBobRoot.position."
	)
	_assert(
		animation.track_get_interpolation_type(0) == Animation.INTERPOLATION_CUBIC,
		"heart_bob must use cubic interpolation."
	)
	_assert(
		animation.track_get_key_count(0) == 5,
		"heart_bob must contain five cycle keys."
	)
	var expected_values := [
		Vector2(0, 0),
		Vector2(0, -EXPECTED_AMPLITUDE_SOURCE_PIXELS),
		Vector2(0, 0),
		Vector2(0, EXPECTED_AMPLITUDE_SOURCE_PIXELS),
		Vector2(0, 0),
	]
	for key_index in expected_values.size():
		_assert(
			animation.track_get_key_value(0, key_index) == expected_values[key_index],
			"heart_bob key %d has an unexpected value." % key_index
		)

	tower.receive_unmitigated_damage(100)
	await process_frame
	_assert(tower.current_health == 2300, "Life Tower damage handling is invalid.")
	_assert(health_bar.max_health_value == 2400, "Health bar maximum is invalid.")
	_assert(health_bar.visible, "Health bar must appear after the tower takes damage.")
	tower.begin_removal(PlantDefense.RemovalMode.SILENT)
	_assert(
		not heart_motes.emitting
		and not heart_motes.visible,
		"Life Tower removal must stop particle simulation immediately."
	)

	print("LIFE_TOWER_SCENE_SMOKE_OK")
	print("period_seconds=2.0")
	print("source_amplitude_pixels=2.0")
	print("world_amplitude_pixels=1.0")
	print("heart_z_index=4")
	print("max_health_bonus_per_tower=0.10")
	tower.queue_free()
	quit(0)


func _assert(condition: bool, message: String) -> void:
	if condition:
		return
	push_error(message)
	quit(1)
