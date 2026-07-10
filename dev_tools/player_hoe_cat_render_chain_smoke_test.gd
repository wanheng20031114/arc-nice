extends SceneTree

const HOE_CAT_SCENE := preload("res://scene/player_hoe_cat.tscn")
const CARDINAL_DIRECTIONS := {
	&"down": Vector2.DOWN,
	&"up": Vector2.UP,
	&"right": Vector2.RIGHT,
	&"left": Vector2.LEFT,
}
const DIRECTION_ROWS := {
	&"down": 0,
	&"up": 1,
	&"right": 2,
	&"left": 3,
}
const PRIMARY_FRAME_DURATIONS := [0.8, 1.0, 0.6, 1.2, 1.4]
const PRIMARY_ANIMATION_DURATION := 0.3125
const PRIMARY_IMPACT_TIME := 0.1125
const WHIRLWIND_ANIMATION_DURATION := 0.5
const WHIRLWIND_IMPACT_TIME := 0.125

var failures: Array[String] = []
var test_root: Node2D
var player: PlayerHoeCat


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	test_root = Node2D.new()
	test_root.name = "PlayerHoeCatRenderChainSmokeRoot"
	root.add_child(test_root)
	current_scene = test_root
	player = HOE_CAT_SCENE.instantiate() as PlayerHoeCat
	_expect(player != null, "Hoe Cat scene must instantiate as PlayerHoeCat.")
	if player == null:
		_finish()
		return
	test_root.add_child(player)
	await process_frame

	_test_pixel_render_settings()
	_test_directional_body_atlases()
	_test_effect_atlases()
	_test_scene_action_node_contract()
	_test_action_visibility_contract()

	_finish()


func _test_pixel_render_settings() -> void:
	for node_path in [
		NodePath("BodySprite"),
		NodePath("BasicSlashEffect"),
		NodePath("WhirlwindRangeEffect"),
		NodePath("WhirlwindBodyEffect"),
	]:
		var sprite := player.get_node(node_path) as CanvasItem
		_expect(sprite != null, "%s must be a CanvasItem." % node_path)
		if sprite == null:
			continue
		_expect(
			sprite.texture_filter == CanvasItem.TEXTURE_FILTER_NEAREST,
			"%s must use nearest-neighbour filtering." % node_path
		)
		_expect(
			sprite.scale.is_equal_approx(Vector2.ONE),
			"%s must render at a stable 1x logical scale." % node_path
		)


func _test_directional_body_atlases() -> void:
	var body := player.get_node("BodySprite") as AnimatedSprite2D
	_expect(body != null and body.sprite_frames != null, "BodySprite must have SpriteFrames.")
	if body == null or body.sprite_frames == null:
		return
	var frames := body.sprite_frames
	_expect(body.animation == &"idle_right", "Hoe Cat must enter the scene in its right-facing idle animation.")
	for suffix: StringName in CARDINAL_DIRECTIONS:
		var row := int(DIRECTION_ROWS[suffix])
		_validate_atlas_animation(
			frames,
			StringName("idle_%s" % suffix),
			1,
			Vector2i(128, 128),
			Vector2i(32, 32),
			row,
			1.0,
			true
		)
		_validate_atlas_animation(
			frames,
			StringName("normal_%s" % suffix),
			4,
			Vector2i(128, 128),
			Vector2i(32, 32),
			row,
			8.0,
			true
		)
		_validate_atlas_animation(
			frames,
			StringName("attack_%s" % suffix),
			5,
			Vector2i(160, 128),
			Vector2i(32, 32),
			row,
			16.0,
			false
		)
		_validate_frame_durations(
			frames,
			StringName("attack_%s" % suffix),
			PRIMARY_FRAME_DURATIONS,
			PRIMARY_ANIMATION_DURATION
		)
		_expect(
			is_equal_approx(
				_animation_time_through_frame(frames, StringName("attack_%s" % suffix), 1),
				PRIMARY_IMPACT_TIME
			),
			"Attack direction %s must reach its impact frame at 0.1125 seconds." % suffix
		)

		player.set("facing_suffix", suffix)
		player.velocity = Vector2.ZERO
		player.call("_update_animation")
		_expect(
			body.animation == StringName("idle_%s" % suffix),
			"A stationary Hoe Cat must select idle_%s." % suffix
		)
		player.velocity = CARDINAL_DIRECTIONS[suffix]
		player.call("_update_animation")
		_expect(
			body.animation == StringName("normal_%s" % suffix),
			"A moving Hoe Cat must select normal_%s." % suffix
		)

		player.call("_play_primary_attack_visual", CARDINAL_DIRECTIONS[suffix])
		_expect(
			body.animation == StringName("attack_%s" % suffix),
			"Attack direction %s must select its matching animation row." % suffix
		)
		player.primary_impact_timer.stop()
		player.call("_update_character_combat_state", 1.0)
		player.velocity = Vector2.ZERO


func _test_effect_atlases() -> void:
	var slash := player.get_node("BasicSlashEffect") as AnimatedSprite2D
	var whirlwind_range := player.get_node("WhirlwindRangeEffect") as AnimatedSprite2D
	var whirlwind_body := player.get_node("WhirlwindBodyEffect") as AnimatedSprite2D
	_validate_atlas_animation(
		slash.sprite_frames, &"slash", 5, Vector2i(160, 32), Vector2i(32, 32), 0, 16.0, false
	)
	_validate_frame_durations(
		slash.sprite_frames,
		&"slash",
		PRIMARY_FRAME_DURATIONS,
		PRIMARY_ANIMATION_DURATION
	)
	_expect(
		is_equal_approx(
			_animation_time_through_frame(slash.sprite_frames, &"slash", 1),
			PRIMARY_IMPACT_TIME
		),
		"Primary slash must reach its impact frame at 0.1125 seconds."
	)
	_validate_atlas_animation(
		whirlwind_range.sprite_frames,
		&"whirlwind",
		8,
		Vector2i(384, 48),
		Vector2i(48, 48),
		0,
		16.0,
		false
	)
	_expect(
		is_equal_approx(
			_animation_duration_seconds(whirlwind_range.sprite_frames, &"whirlwind"),
			WHIRLWIND_ANIMATION_DURATION
		),
		"Whirlwind range animation must last exactly 0.5 seconds."
	)
	_expect(
		is_equal_approx(
			_animation_time_through_frame(whirlwind_range.sprite_frames, &"whirlwind", 1),
			WHIRLWIND_IMPACT_TIME
		),
		"Whirlwind range must reach its impact frame at 0.125 seconds."
	)
	_validate_atlas_animation(
		whirlwind_body.sprite_frames,
		&"whirlwind",
		8,
		Vector2i(256, 32),
		Vector2i(32, 32),
		0,
		16.0,
		false
	)
	_expect(
		is_equal_approx(
			_animation_duration_seconds(whirlwind_body.sprite_frames, &"whirlwind"),
			WHIRLWIND_ANIMATION_DURATION
		),
		"Whirlwind body animation must last exactly 0.5 seconds."
	)
	_expect(
		is_equal_approx(
			_animation_time_through_frame(whirlwind_body.sprite_frames, &"whirlwind", 1),
			WHIRLWIND_IMPACT_TIME
		),
		"Whirlwind body must reach its impact frame at 0.125 seconds."
	)


func _test_scene_action_node_contract() -> void:
	_expect(
		player.get_node_or_null("BodySprite/HoeSprite") == null,
		"The hoe must be authored into body frames instead of a runtime-rotated HoeSprite."
	)
	_expect(
		player.get_node_or_null("ActionAnimationPlayer") == null,
		"The obsolete scale-only ActionAnimationPlayer must stay removed."
	)
	var primary_timer := player.get_node_or_null("PrimaryImpactTimer") as Timer
	var whirlwind_timer := player.get_node_or_null("WhirlwindImpactTimer") as Timer
	_expect(primary_timer != null, "PrimaryImpactTimer must be prebuilt in the Hoe Cat scene.")
	_expect(whirlwind_timer != null, "WhirlwindImpactTimer must be prebuilt in the Hoe Cat scene.")
	if primary_timer != null:
		_expect(primary_timer.one_shot, "PrimaryImpactTimer must be one-shot.")
		_expect(primary_timer.is_stopped(), "PrimaryImpactTimer must start inactive.")
	if whirlwind_timer != null:
		_expect(whirlwind_timer.one_shot, "WhirlwindImpactTimer must be one-shot.")
		_expect(whirlwind_timer.is_stopped(), "WhirlwindImpactTimer must start inactive.")


func _test_action_visibility_contract() -> void:
	var body := player.get_node("BodySprite") as AnimatedSprite2D
	var slash := player.get_node("BasicSlashEffect") as AnimatedSprite2D
	var whirlwind_range := player.get_node("WhirlwindRangeEffect") as AnimatedSprite2D
	var whirlwind_body := player.get_node("WhirlwindBodyEffect") as AnimatedSprite2D

	player.call("_play_primary_attack_visual", Vector2.RIGHT)
	_expect(body.visible, "Primary attack must keep exactly one body animation visible.")
	_expect(slash.visible, "Primary slash effect must be visible during the primary animation.")
	_expect(not whirlwind_range.visible and not whirlwind_body.visible, "Whirlwind layers must not overlap a primary attack.")
	_expect(not player.primary_impact_timer.is_stopped(), "Primary visual playback must arm PrimaryImpactTimer.")

	player.call("_play_whirlwind_visual")
	_expect(not body.visible, "Base body must hide while whirlwind body frames are visible.")
	_expect(not slash.visible, "Primary slash must stop before whirlwind layers appear.")
	_expect(whirlwind_range.visible and whirlwind_body.visible, "Both intended whirlwind layers must play together.")
	_expect(not player.whirlwind_impact_timer.is_stopped(), "Whirlwind playback must arm WhirlwindImpactTimer.")

	player.call("_finish_whirlwind_visual")
	_expect(body.visible, "Base body must return after whirlwind playback.")
	_expect(not whirlwind_range.visible and not whirlwind_body.visible, "Whirlwind layers must hide after playback.")
	player.primary_impact_timer.stop()
	player.whirlwind_impact_timer.stop()
	player.call("_update_character_combat_state", 1.0)


func _validate_atlas_animation(
	frames: SpriteFrames,
	animation_name: StringName,
	expected_frame_count: int,
	expected_sheet_size: Vector2i,
	cell_size: Vector2i,
	row: int,
	expected_speed: float,
	expected_loop: bool
) -> void:
	_expect(frames != null and frames.has_animation(animation_name), "%s must exist." % animation_name)
	if frames == null or not frames.has_animation(animation_name):
		return
	_expect(frames.get_frame_count(animation_name) == expected_frame_count, "%s frame count mismatch." % animation_name)
	_expect(is_equal_approx(frames.get_animation_speed(animation_name), expected_speed), "%s speed mismatch." % animation_name)
	_expect(frames.get_animation_loop(animation_name) == expected_loop, "%s loop flag mismatch." % animation_name)
	for frame_index in range(expected_frame_count):
		var texture := frames.get_frame_texture(animation_name, frame_index) as AtlasTexture
		_expect(texture != null, "%s frame %d must use AtlasTexture." % [animation_name, frame_index])
		if texture == null:
			continue
		_expect(Vector2i(texture.atlas.get_size()) == expected_sheet_size, "%s sheet size mismatch." % animation_name)
		_expect(
			texture.region == Rect2(frame_index * cell_size.x, row * cell_size.y, cell_size.x, cell_size.y),
			"%s frame %d atlas region mismatch." % [animation_name, frame_index]
		)


func _validate_frame_durations(
	frames: SpriteFrames,
	animation_name: StringName,
	expected_durations: Array,
	expected_total_seconds: float
) -> void:
	if frames == null or not frames.has_animation(animation_name):
		return
	_expect(
		frames.get_frame_count(animation_name) == expected_durations.size(),
		"%s duration contract frame count mismatch." % animation_name
	)
	for frame_index in range(mini(frames.get_frame_count(animation_name), expected_durations.size())):
		_expect(
			is_equal_approx(
				frames.get_frame_duration(animation_name, frame_index),
				float(expected_durations[frame_index])
			),
			"%s frame %d duration weight mismatch." % [animation_name, frame_index]
		)
	_expect(
		is_equal_approx(
			_animation_duration_seconds(frames, animation_name),
			expected_total_seconds
		),
		"%s weighted duration mismatch." % animation_name
	)


func _animation_duration_seconds(frames: SpriteFrames, animation_name: StringName) -> float:
	return _animation_time_through_frame(
		frames,
		animation_name,
		frames.get_frame_count(animation_name) - 1
	)


func _animation_time_through_frame(
	frames: SpriteFrames,
	animation_name: StringName,
	last_frame_index: int
) -> float:
	if frames == null or not frames.has_animation(animation_name):
		return 0.0
	var animation_speed := frames.get_animation_speed(animation_name)
	if animation_speed <= 0.0:
		return 0.0
	var duration_weight := 0.0
	for frame_index in range(mini(last_frame_index + 1, frames.get_frame_count(animation_name))):
		duration_weight += frames.get_frame_duration(animation_name, frame_index)
	return duration_weight / animation_speed


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if is_instance_valid(test_root):
		test_root.queue_free()
	if failures.is_empty():
		print("PLAYER_HOE_CAT_RENDER_CHAIN_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)
