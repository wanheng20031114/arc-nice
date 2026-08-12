extends SceneTree


const SCENE_PATH := "res://scene/plant_defense/speed_tower.tscn"
const CONFIG_PATH := "res://resources/config/plant_defense/speed_tower.tres"
const LIFE_TOWER_LOWER_BODY_PATH := (
	"res://resources/texture/plant_defense/life_tower/layers/lower_body.png"
)
const EXPECTED_PERIOD_SECONDS := 2.0
const EXPECTED_AMPLITUDE_SOURCE_PIXELS := 2.0
const EXPECTED_MOTE_COLOR := Color(0.992157, 0.85098, 0.007843, 1)


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	var packed_scene := load(SCENE_PATH) as PackedScene
	var config := load(CONFIG_PATH) as SpeedTowerConfig
	_assert(packed_scene != null, "Speed Tower scene failed to load.")
	_assert(config != null, "Speed Tower config failed to load.")
	var tower := packed_scene.instantiate() as SpeedTower
	_assert(tower != null, "Speed Tower scene must instantiate SpeedTower.")
	root.add_child(tower)
	await process_frame
	tower.setup(
		config,
		null,
		[Vector2i.ZERO, Vector2i.RIGHT, Vector2i.DOWN, Vector2i.ONE]
	)
	_assert(config is SpeedTowerConfig, "Speed Tower must use SpeedTowerConfig.")
	_assert(config.is_valid(), "Speed Tower config must be valid.")
	_assert(config.plant_id == &"speed_tower", "Speed Tower plant_id is invalid.")
	_assert(config.display_name == "移速强化塔", "Speed Tower display name is invalid.")
	_assert(config.footprint_size == Vector2i(2, 2), "Speed Tower must occupy 2x2 cells.")
	_assert(config.max_health == 2400, "Speed Tower max health must be 2400.")
	_assert(config.physical_defense == 5, "Speed Tower physical defense must be 5.")
	_assert(config.magic_defense == 0, "Speed Tower magic defense must be 0.")
	_assert(config.supports_multiplayer, "Speed Tower must support multiplayer.")
	_assert(
		config.building_category
		== PlantDefenseConfig.BuildingCategory.SUPPORT_TOWER,
		"Speed Tower must be registered as a support tower."
	)
	_assert(
		is_equal_approx(config.move_speed_bonus, 10.0),
		"Speed Tower player move-speed bonus must be 10."
	)
	_assert(
		is_equal_approx(tower.get_player_move_speed_bonus(), 10.0),
		"Speed Tower must expose its configured additive move-speed bonus."
	)
	_assert(tower.max_health == 2400, "Scene setup must apply config max health.")
	_assert(tower.current_health == 2400, "Speed Tower must start at full health.")
	_assert(tower.physical_defense == 5, "Scene setup must apply physical defense.")
	_assert(tower.magic_defense == 0, "Scene setup must apply magic defense.")
	_assert(tower.is_operational, "A non-animated setup must finish construction.")

	var visual_root := tower.get_node("VisualRoot") as Node2D
	var lower_body := tower.get_node("VisualRoot/LowerBody") as Sprite2D
	var boot_root := tower.get_node("VisualRoot/BootBobRoot") as Node2D
	var boot := tower.get_node(
		"VisualRoot/BootBobRoot/BootForeground"
	) as Sprite2D
	var boot_motes := tower.get_node(
		"VisualRoot/BootBobRoot/BootMotes"
	) as GPUParticles2D
	var animation_player := tower.get_node(
		"BootBobAnimationPlayer"
	) as AnimationPlayer
	var health_bar := tower.get_node("HealthBar") as PlantHealthBar
	var body_collision := tower.get_node("CollisionShape2D") as CollisionShape2D
	var player_core := tower.get_node("PlayerCoreBody") as StaticBody2D
	var player_core_collision := tower.get_node(
		"PlayerCoreBody/CollisionShape2D"
	) as CollisionShape2D
	_assert(visual_root != null, "VisualRoot is missing.")
	_assert(lower_body != null, "LowerBody is missing.")
	_assert(boot_root != null, "BootBobRoot is missing.")
	_assert(boot != null, "BootForeground is missing.")
	_assert(boot_motes != null, "BootMotes is missing.")
	_assert(animation_player != null, "BootBobAnimationPlayer is missing.")
	_assert(health_bar != null, "HealthBar is missing.")
	_assert(body_collision != null, "Speed Tower body collision is missing.")
	_assert(player_core != null, "Speed Tower player core is missing.")
	_assert(player_core_collision != null, "Speed Tower player core collision is missing.")

	var body_shape := body_collision.shape as RectangleShape2D
	var player_core_shape := player_core_collision.shape as CapsuleShape2D
	_assert(
		body_collision.position == Vector2(0, 5.5)
		and body_shape != null
		and body_shape.size == Vector2(24, 17),
		"Speed Tower body collision must preserve the authored 24x17 footprint."
	)
	_assert(
		player_core.position == Vector2(0, 1)
		and player_core.collision_layer == 1024
		and player_core.collision_mask == 2
		and player_core_collision.position == Vector2(0, 7)
		and is_equal_approx(player_core_collision.rotation, PI / 2.0)
		and player_core_shape != null
		and is_equal_approx(player_core_shape.radius, 4.0)
		and is_equal_approx(player_core_shape.height, 16.0),
		"Speed Tower player core collision must preserve the authored 16x8 capsule."
	)
	_assert(visual_root.scale == Vector2(0.5, 0.5), "VisualRoot scale must be 0.5.")
	_assert(lower_body.texture != null, "LowerBody texture is not imported.")
	_assert(boot.texture != null, "Boot texture is not imported.")
	_assert(lower_body.texture.get_size() == Vector2(64, 64), "LowerBody must be 64x64.")
	_assert(boot.texture.get_size() == Vector2(64, 64), "Boot must be 64x64.")
	_assert(
		lower_body.texture.resource_path == LIFE_TOWER_LOWER_BODY_PATH,
		"Speed Tower must reuse the exact Life Tower lower-body texture."
	)
	_assert(lower_body.z_index == 0, "LowerBody z_index must be 0.")
	_assert(boot.z_index == 4, "Boot z_index must be 4.")
	_assert(
		tower.lifecycle_visual_paths
		== [
			NodePath("VisualRoot/LowerBody"),
			NodePath("VisualRoot/BootBobRoot/BootForeground"),
		],
		"Lifecycle visuals must cover the shared base and floating boot."
	)
	_assert(
		tower.find_children("*", "GPUParticles2D", true, false).size() == 1
		and tower.find_children("*", "CPUParticles2D", true, false).is_empty(),
		"Speed Tower must use exactly one GPU emitter and no CPU emitters."
	)
	_assert(
		tower.find_children(
			"*", "VisibleOnScreenNotifier2D", true, false
		).is_empty(),
		"Boot motes must rely on their native visibility_rect without a duplicate notifier."
	)

	var mote_material := boot_motes.process_material as ParticleProcessMaterial
	var mote_alpha_texture := mote_material.color_ramp as GradientTexture1D
	var mote_alpha_gradient := mote_alpha_texture.gradient
	_assert(
		boot_motes.get_parent() == boot_root
		and boot_motes.z_index == 3
		and not boot_motes.local_coords
		and boot_motes.texture_filter == CanvasItem.TEXTURE_FILTER_NEAREST,
		"Boot motes must follow the boot emitter, render behind it, and keep nearest sampling."
	)
	_assert(
		boot_motes.texture != null
		and boot_motes.texture.get_size() == Vector2.ONE
		and boot_motes.texture.get_size() * visual_root.scale == Vector2(0.5, 0.5),
		"Boot motes must match exactly one native pixel in the 64x64 boot artwork."
	)
	_assert(
		boot_motes.amount == 8
		and is_equal_approx(boot_motes.lifetime, 0.8)
		and boot_motes.preprocess == 0.0
		and boot_motes.fixed_fps == 30
		and boot_motes.process_mode == Node.PROCESS_MODE_INHERIT
		and boot_motes.visibility_rect == Rect2(-18, -18, 36, 30),
		"Boot mote emitter must stay within the Life Tower particle budget."
	)
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
		"Boot motes must preserve the Life Tower outward fan and moderate speed."
	)
	_assert(
		mote_material.color.is_equal_approx(EXPECTED_MOTE_COLOR)
		and mote_alpha_gradient != null
		and mote_alpha_gradient.offsets == PackedFloat32Array([0, 0.78, 0.9, 1])
		and is_equal_approx(mote_alpha_gradient.colors[0].a, 0.94)
		and is_equal_approx(mote_alpha_gradient.colors[1].a, 0.94)
		and is_equal_approx(mote_alpha_gradient.colors[2].a, 0.35)
		and is_zero_approx(mote_alpha_gradient.colors[3].a),
		"Boot motes must be yellow and preserve the short final fade."
	)
	_assert(
		is_equal_approx(
			boot_motes.lifetime * (1.0 - mote_alpha_gradient.offsets[1]),
			0.176
		),
		"Boot mote fade must finish within the final 0.176 seconds."
	)

	_assert(
		health_bar.custom_minimum_size == Vector2(24, 4)
		and health_bar.size == Vector2(24, 4)
		and health_bar.offset_left == -12.0
		and health_bar.offset_top == -11.0
		and health_bar.offset_right == 12.0
		and health_bar.offset_bottom == -7.0
		and health_bar.scale == Vector2.ONE,
		"Speed Tower health bar must preserve the Life Tower integer-pixel layout."
	)
	_assert(
		lower_body.texture_filter == CanvasItem.TEXTURE_FILTER_NEAREST
		and boot.texture_filter == CanvasItem.TEXTURE_FILTER_NEAREST,
		"Speed Tower artwork must use nearest filtering."
	)
	_assert(
		boot_motes.emitting and boot_motes.visible,
		"A completed Speed Tower must emit and rely on native off-screen culling."
	)
	tower.call("_on_construction_started")
	_assert(
		not boot_motes.emitting and not boot_motes.visible,
		"Speed Tower construction must suspend boot motes."
	)
	tower.call("_on_construction_finished", false)
	_assert(
		boot_motes.emitting and boot_motes.visible,
		"Boot motes must resume after construction."
	)

	var animation := animation_player.get_animation(&"boot_bob")
	_assert(animation != null, "boot_bob animation is missing.")
	_assert(
		is_equal_approx(animation.length, EXPECTED_PERIOD_SECONDS)
		and animation.loop_mode == Animation.LOOP_LINEAR
		and animation.get_track_count() == 1
		and animation.track_get_path(0)
		== NodePath("VisualRoot/BootBobRoot:position")
		and animation.track_get_interpolation_type(0)
		== Animation.INTERPOLATION_CUBIC
		and animation.track_get_key_count(0) == 5,
		"boot_bob must preserve the Life Tower's smooth two-second cycle."
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
			"boot_bob key %d has an unexpected value." % key_index
		)

	tower.receive_unmitigated_damage(100)
	await process_frame
	_assert(tower.current_health == 2300, "Speed Tower damage handling is invalid.")
	_assert(health_bar.max_health_value == 2400, "Health bar maximum is invalid.")
	_assert(health_bar.visible, "Health bar must appear after the tower takes damage.")
	tower.begin_removal(PlantDefense.RemovalMode.SILENT)
	_assert(
		not boot_motes.emitting and not boot_motes.visible,
		"Speed Tower removal must stop particle simulation immediately."
	)

	print("SPEED_TOWER_SCENE_SMOKE_OK")
	print("period_seconds=2.0")
	print("source_amplitude_pixels=2.0")
	print("world_amplitude_pixels=1.0")
	print("boot_z_index=4")
	print("move_speed_bonus_per_tower=10")
	tower.queue_free()
	quit(0)


func _assert(condition: bool, message: String) -> void:
	if condition:
		return
	push_error(message)
	quit(1)
