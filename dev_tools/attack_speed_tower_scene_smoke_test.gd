extends SceneTree


const SCENE_PATH := "res://scene/plant_defense/attack_speed_tower.tscn"
const CONFIG := preload(
	"res://resources/config/plant_defense/attack_speed_tower.tres"
)
const LIFE_TOWER_BASE_PATH := (
	"res://resources/texture/plant_defense/life_tower/layers/lower_body.png"
)
const EXPECTED_PERIOD_SECONDS := 2.0
const EXPECTED_AMPLITUDE_SOURCE_PIXELS := 2.0
const FORCED_FAILURE_ARGUMENT := "--force-smoke-failure"

var _failures: PackedStringArray = []


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	var packed_scene := load(SCENE_PATH) as PackedScene
	_assert(packed_scene != null, "Attack Speed Tower scene failed to load.")
	if packed_scene == null:
		_finish()
		return
	var tower := packed_scene.instantiate() as AttackSpeedTower
	_assert(tower != null, "Attack Speed Tower scene failed to instantiate.")
	if tower == null:
		_finish()
		return
	root.add_child(tower)
	await process_frame
	tower.setup(
		CONFIG,
		null,
		[Vector2i.ZERO, Vector2i.RIGHT, Vector2i.DOWN, Vector2i.ONE]
	)

	_assert(CONFIG is AttackSpeedTowerConfig, "Tower must use AttackSpeedTowerConfig.")
	_assert(CONFIG.is_valid(), "Attack Speed Tower config must be valid.")
	_assert(CONFIG.plant_id == &"attack_speed_tower", "Tower plant_id is invalid.")
	_assert(CONFIG.display_name == "攻速强化塔", "Tower display name is invalid.")
	_assert(CONFIG.footprint_size == Vector2i(2, 2), "Tower must occupy 2x2 cells.")
	_assert(CONFIG.max_health == 2400, "Tower max health must match Life Tower.")
	_assert(CONFIG.physical_defense == 5, "Physical defense must match Life Tower.")
	_assert(CONFIG.magic_defense == 0, "Magic defense must match Life Tower.")
	_assert(CONFIG.supports_multiplayer, "Tower must support multiplayer.")
	_assert(
		CONFIG.building_category
		== PlantDefenseConfig.BuildingCategory.SUPPORT_TOWER,
		"Attack Speed Tower must be a support tower."
	)
	_assert(
		is_equal_approx(CONFIG.attack_speed_bonus_ratio, 0.03),
		"Attack Speed Tower bonus must be 3%."
	)
	_assert(tower.max_health == 2400, "Scene setup must apply config max health.")
	_assert(tower.current_health == 2400, "Tower must start at full health.")
	_assert(tower.physical_defense == 5, "Scene setup must apply physical defense.")
	_assert(tower.magic_defense == 0, "Scene setup must apply magic defense.")
	_assert(tower.is_operational, "A non-animated setup must finish construction.")

	var visual_root := tower.get_node("VisualRoot") as Node2D
	var lower_body := tower.get_node("VisualRoot/LowerBody") as Sprite2D
	var speed_root := tower.get_node("VisualRoot/SpeedBobRoot") as Node2D
	var speed_foreground := tower.get_node(
		"VisualRoot/SpeedBobRoot/SpeedForeground"
	) as Sprite2D
	var speed_motes := tower.get_node(
		"VisualRoot/SpeedBobRoot/SpeedMotes"
	) as GPUParticles2D
	var animation_player := tower.get_node(
		"SpeedBobAnimationPlayer"
	) as AnimationPlayer
	var health_bar := tower.get_node("HealthBar") as PlantHealthBar
	var body_collision := tower.get_node("CollisionShape2D") as CollisionShape2D
	var player_core := tower.get_node("PlayerCoreBody") as StaticBody2D
	var core_collision := tower.get_node(
		"PlayerCoreBody/CollisionShape2D"
	) as CollisionShape2D
	_assert(visual_root != null, "VisualRoot is missing.")
	_assert(lower_body != null, "LowerBody is missing.")
	_assert(speed_root != null, "SpeedBobRoot is missing.")
	_assert(speed_foreground != null, "SpeedForeground is missing.")
	_assert(speed_motes != null, "SpeedMotes is missing.")
	_assert(animation_player != null, "SpeedBobAnimationPlayer is missing.")
	_assert(health_bar != null, "HealthBar is missing.")
	_assert(body_collision != null, "Body collision is missing.")
	_assert(player_core != null and core_collision != null, "Player core is missing.")
	if not _failures.is_empty():
		_finish(tower)
		return

	var body_shape := body_collision.shape as RectangleShape2D
	var core_shape := core_collision.shape as CapsuleShape2D
	_assert(
		body_collision.position == Vector2(0, 5.5)
		and body_shape != null
		and body_shape.size == Vector2(24, 17),
		"Body collision must match Life Tower's authored 24x17 footprint."
	)
	_assert(
		player_core.position == Vector2(0, 1)
		and player_core.collision_layer == 1024
		and player_core.collision_mask == 2
		and core_collision.position == Vector2(0, 7)
		and is_equal_approx(core_collision.rotation, PI / 2.0)
		and core_shape != null
		and is_equal_approx(core_shape.radius, 4.0)
		and is_equal_approx(core_shape.height, 16.0),
		"Player core collision must exactly match Life Tower."
	)
	_assert(visual_root.scale == Vector2(0.5, 0.5), "Visual scale must be 0.5.")
	_assert(lower_body.texture != null, "Shared lower-body texture is not imported.")
	_assert(speed_foreground.texture != null, "Speed foreground is not imported.")
	_assert(
		lower_body.texture.resource_path == LIFE_TOWER_BASE_PATH,
		"Attack Speed Tower must directly reuse Life Tower's lower body."
	)
	_assert(lower_body.texture.get_size() == Vector2(64, 64), "Base must be 64x64.")
	_assert(
		speed_foreground.texture.get_size() == Vector2(64, 64),
		"Speed foreground must be 64x64."
	)
	_assert(
		lower_body.texture_filter == CanvasItem.TEXTURE_FILTER_NEAREST
		and speed_foreground.texture_filter == CanvasItem.TEXTURE_FILTER_NEAREST,
		"Both authored pixel layers must use nearest filtering."
	)
	_assert(lower_body.z_index == 0, "LowerBody z_index must be 0.")
	_assert(speed_foreground.z_index == 4, "SpeedForeground z_index must be 4.")
	_assert(
		tower.find_children("*", "GPUParticles2D", true, false).size() == 1
		and tower.find_children("*", "CPUParticles2D", true, false).is_empty(),
		"Tower must use exactly one GPU emitter and no CPU emitters."
	)
	_assert(
		tower.find_children(
			"*", "VisibleOnScreenNotifier2D", true, false
		).is_empty(),
		"Speed motes must rely on native visibility_rect culling."
	)
	var mote_material := speed_motes.process_material as ParticleProcessMaterial
	_assert(mote_material != null, "Speed mote process material is missing.")
	if mote_material == null:
		_finish(tower)
		return
	var alpha_texture := mote_material.color_ramp as GradientTexture1D
	_assert(alpha_texture != null, "Speed mote color ramp texture is missing.")
	if alpha_texture == null:
		_finish(tower)
		return
	var alpha_gradient := alpha_texture.gradient
	_assert(
		speed_motes.get_parent() == speed_root
		and speed_motes.z_index == 3
		and not speed_motes.local_coords
		and speed_motes.texture_filter == CanvasItem.TEXTURE_FILTER_NEAREST,
		"Speed motes must mirror Life Tower's authored renderer settings."
	)
	_assert(
		speed_motes.texture != null
		and speed_motes.texture.get_size() == Vector2.ONE
		and speed_motes.amount == 8
		and is_equal_approx(speed_motes.lifetime, 0.8)
		and speed_motes.fixed_fps == 30
		and speed_motes.visibility_rect.size == Vector2(36, 30),
		"Speed mote particle budget must match Life Tower."
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
		and is_equal_approx(mote_material.radial_velocity_max, 4.0),
		"Speed mote motion must match Life Tower."
	)
	_assert(
		mote_material.color.b > mote_material.color.r
		and mote_material.color.b > mote_material.color.g
		and alpha_gradient != null
		and alpha_gradient.offsets == PackedFloat32Array([0, 0.78, 0.9, 1]),
		"Speed motes must be blue while preserving Life Tower's fade."
	)
	_assert(
		health_bar.custom_minimum_size == Vector2(24, 4)
		and health_bar.size == Vector2(24, 4)
		and health_bar.offset_left == -12.0
		and health_bar.offset_top == -11.0
		and health_bar.offset_right == 12.0
		and health_bar.offset_bottom == -7.0,
		"Health bar must exactly match Life Tower."
	)

	var animation := animation_player.get_animation(&"speed_bob")
	_assert(animation != null, "speed_bob animation is missing.")
	if animation == null:
		_finish(tower)
		return
	_assert(
		is_equal_approx(animation.length, EXPECTED_PERIOD_SECONDS)
		and animation.loop_mode == Animation.LOOP_LINEAR
		and animation.get_track_count() == 1
		and animation.track_get_path(0)
		== NodePath("VisualRoot/SpeedBobRoot:position")
		and animation.track_get_interpolation_type(0)
		== Animation.INTERPOLATION_CUBIC,
		"Speed symbol bob must mirror Life Tower's 2-second animation."
	)
	var expected_values := [
		Vector2(0, 0),
		Vector2(0, -EXPECTED_AMPLITUDE_SOURCE_PIXELS),
		Vector2(0, 0),
		Vector2(0, EXPECTED_AMPLITUDE_SOURCE_PIXELS),
		Vector2(0, 0),
	]
	_assert(
		animation.track_get_key_count(0) == expected_values.size(),
		"speed_bob must contain five cycle keys."
	)
	if animation.track_get_key_count(0) == expected_values.size():
		for key_index in expected_values.size():
			_assert(
				animation.track_get_key_value(0, key_index) == expected_values[key_index],
				"speed_bob key %d is invalid." % key_index
			)

	_assert(speed_motes.emitting and speed_motes.visible, "Completed tower must emit.")
	tower.call("_on_construction_started")
	_assert(
		not speed_motes.emitting and not speed_motes.visible,
		"Construction must suspend speed motes."
	)
	tower.call("_on_construction_finished", false)
	_assert(speed_motes.emitting and speed_motes.visible, "Motes must resume.")
	tower.receive_unmitigated_damage(100)
	await process_frame
	_assert(tower.current_health == 2300, "Tower damage handling is invalid.")
	_assert(health_bar.max_health_value == 2400, "Health bar maximum is invalid.")
	tower.begin_removal(PlantDefense.RemovalMode.SILENT)
	_assert(
		not speed_motes.emitting and not speed_motes.visible,
		"Removal must stop speed motes immediately."
	)

	if OS.get_cmdline_user_args().has(FORCED_FAILURE_ARGUMENT):
		_assert(false, "Intentional failure used to verify the smoke-test harness.")
	_finish(tower)


func _assert(condition: bool, message: String) -> void:
	if condition:
		return
	_failures.append(message)


func _finish(tower: Node = null) -> void:
	if tower != null:
		tower.queue_free()
	var exit_code := 0
	if not _failures.is_empty():
		for message in _failures:
			push_error(message)
		print("ATTACK_SPEED_TOWER_SCENE_SMOKE_FAILED")
		exit_code = 1
	else:
		print("ATTACK_SPEED_TOWER_SCENE_SMOKE_OK")
		print("base_reused=true")
		print("particle_color=blue")
		print("attack_speed_bonus_per_tower=0.03")
	quit(exit_code)
