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
	var player := tower.get_node("HeartBobAnimationPlayer") as AnimationPlayer
	var health_bar := tower.get_node("HealthBar") as PlantHealthBar
	_assert(visual_root != null, "VisualRoot is missing.")
	_assert(lower_body != null, "LowerBody is missing.")
	_assert(heart_root != null, "HeartBobRoot is missing.")
	_assert(heart != null, "HeartForeground is missing.")
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
