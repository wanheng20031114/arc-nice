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
const PRIMARY_BODY_FRAME_DURATIONS := [0.8, 1.0, 0.6, 1.2, 1.4]
const PRIMARY_VFX_FRAME_DURATIONS := [0.6, 0.7, 0.8, 0.6, 0.7, 1.3, 2.0, 0.8]
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
	_test_free_aim_visual_rotation()
	_test_effect_atlases()
	_test_scene_action_node_contract()
	_test_visual_offset_and_bar_contract()
	_test_action_visibility_contract()
	await _test_death_animation_contract()

	_finish()


func _test_pixel_render_settings() -> void:
	for node_path in [
		NodePath("BodySprite"),
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
	var slash := player.get_node("BasicSlashEffect") as AnimatedSprite2D
	_expect(slash != null, "BasicSlashEffect must be an AnimatedSprite2D.")
	if slash != null:
		_expect(
			slash.texture_filter == CanvasItem.TEXTURE_FILTER_NEAREST,
			"BasicSlashEffect must use nearest-neighbour filtering for crisp pixel art."
		)
		_expect(
			slash.scale.is_equal_approx(Vector2.ONE),
			"BasicSlashEffect must render at a stable 1x logical scale."
		)
		var slash_material := slash.material as ShaderMaterial
		_expect(
			slash_material != null and slash_material.shader != null,
			"BasicSlashEffect must use its dedicated HDR glow shader."
		)
		if slash_material != null:
			_expect(
				float(slash_material.get_shader_parameter(&"hdr_energy")) > 1.0,
				"BasicSlashEffect glow must output overbright HDR colour."
			)
	_expect(
		bool(ProjectSettings.get_setting("rendering/viewport/hdr_2d", false)),
		"The project must keep HDR 2D enabled for the slash glow."
	)
	_expect(
		int(ProjectSettings.get_setting(
			"rendering/textures/canvas_textures/default_texture_filter",
			-1
		)) == 0,
		"In-game CanvasItem textures must inherit nearest-neighbour filtering."
	)


func _test_directional_body_atlases() -> void:
	var body := player.get_node("BodySprite") as AnimatedSprite2D
	_expect(body != null and body.sprite_frames != null, "BodySprite must have SpriteFrames.")
	if body == null or body.sprite_frames == null:
		return
	var frames := body.sprite_frames
	_expect(body.animation == &"idle_right", "Hoe Cat must enter the scene in its right-facing idle animation.")
	_validate_atlas_animation(
		frames,
		&"death",
		5,
		Vector2i(160, 32),
		Vector2i(32, 32),
		0,
		10.0,
		false
	)
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
			PRIMARY_BODY_FRAME_DURATIONS,
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


func _test_free_aim_visual_rotation() -> void:
	var body := player.get_node("BodySprite") as AnimatedSprite2D
	var slash := player.get_node("BasicSlashEffect") as AnimatedSprite2D
	var direction_cases := [
		{
			"angle": 20.0,
			"animation": &"attack_right",
		},
		{
			"angle": 50.0,
			"animation": &"attack_down",
		},
	]
	for direction_case in direction_cases:
		var angle_degrees := float(direction_case["angle"])
		var direction := Vector2.RIGHT.rotated(deg_to_rad(angle_degrees))
		player.call("_play_primary_attack_visual", direction)
		_expect(
			body.animation == direction_case["animation"],
			"Free aim at %.1f degrees must use nearest body row %s."
			% [angle_degrees, direction_case["animation"]]
		)
		_expect(
			is_equal_approx(slash.rotation, deg_to_rad(angle_degrees)),
			"Slash VFX must preserve the exact %.1f-degree attack direction."
			% angle_degrees
		)
		player.primary_impact_timer.stop()
		player.call("_update_character_combat_state", 1.0)
	var remote_direction := Vector2.RIGHT.rotated(deg_to_rad(135.0))
	player.play_remote_hoe_action(&"primary", remote_direction, 1)
	_expect(
		body.animation == &"attack_left",
		"Remote free aim must keep the nearest four-direction body animation."
	)
	_expect(
		is_equal_approx(slash.rotation, remote_direction.angle()),
		"Remote action confirmation must preserve its exact non-cardinal rotation."
	)
	player.primary_impact_timer.stop()
	player.call("_update_character_combat_state", 1.0)


func _test_effect_atlases() -> void:
	var slash := player.get_node("BasicSlashEffect") as AnimatedSprite2D
	var whirlwind_range := player.get_node("WhirlwindRangeEffect") as AnimatedSprite2D
	var whirlwind_body := player.get_node("WhirlwindBodyEffect") as AnimatedSprite2D
	_validate_atlas_animation(
		slash.sprite_frames, &"slash", 8, Vector2i(896, 112), Vector2i(112, 112), 0, 24.0, false
	)
	_validate_frame_durations(
		slash.sprite_frames,
		&"slash",
		PRIMARY_VFX_FRAME_DURATIONS,
		PRIMARY_ANIMATION_DURATION
	)
	_expect(
		is_equal_approx(
			_animation_time_through_frame(slash.sprite_frames, &"slash", 3),
			PRIMARY_IMPACT_TIME
		),
		"Primary slash must reach its impact frame at 0.1125 seconds."
	)
	_validate_atlas_animation(
		whirlwind_range.sprite_frames,
		&"whirlwind",
		8,
		Vector2i(1280, 160),
		Vector2i(160, 160),
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
	var whirlwind_material := whirlwind_range.material as ShaderMaterial
	_expect(
		whirlwind_material != null and whirlwind_material.shader != null,
		"Whirlwind range must use the shared pale-yellow HDR slash shader."
	)
	if whirlwind_material != null:
		_expect(
			float(whirlwind_material.get_shader_parameter(&"hdr_energy")) > 2.15,
			"Whirlwind HDR energy must read stronger than the basic slash."
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


func _test_visual_offset_and_bar_contract() -> void:
	var tracked_paths: Array[NodePath] = [
		NodePath("BodySprite"),
		NodePath("AttackIntervalBar"),
		NodePath("BasicSlashEffect"),
		NodePath("WhirlwindRangeEffect"),
		NodePath("WhirlwindBodyEffect"),
	]
	var base_positions: Dictionary = {}
	player.call("_cache_multiplayer_visual_base_positions")
	for node_path in tracked_paths:
		var visual_node := player.get_node(node_path)
		base_positions[node_path] = visual_node.get("position")
	var offset := Vector2(7.0, -3.0)
	player.call("_set_multiplayer_visual_offset", offset)
	for node_path in tracked_paths:
		var visual_node := player.get_node(node_path)
		var actual_position: Vector2 = visual_node.get("position")
		var expected_position: Vector2 = base_positions[node_path] + offset
		_expect(
			actual_position.is_equal_approx(expected_position),
			"%s must follow the same multiplayer visual smoothing offset." % node_path
		)
	player.call("_set_multiplayer_visual_offset", Vector2.ZERO)

	var attack_bar := player.get_node("AttackIntervalBar") as Control
	var skill_bar := player.get_node("Skill1ChargeBar") as Control
	var slash := player.get_node("BasicSlashEffect") as CanvasItem
	_expect(
		is_equal_approx(attack_bar.offset_top, 13.0)
		and is_equal_approx(attack_bar.offset_bottom, 15.0),
		"Attack recovery bar must stay below the raised Hoe Cat body."
	)
	_expect(
		attack_bar.offset_bottom <= skill_bar.offset_top,
		"Attack recovery and skill charge bars must not overlap."
	)
	_expect(
		attack_bar.z_index > slash.z_index and skill_bar.z_index > slash.z_index,
		"Hoe Cat bars must remain readable above the enlarged attack VFX."
	)


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


func _test_death_animation_contract() -> void:
	var body := player.get_node("BodySprite") as AnimatedSprite2D
	var slash := player.get_node("BasicSlashEffect") as AnimatedSprite2D
	var whirlwind_range := player.get_node("WhirlwindRangeEffect") as AnimatedSprite2D
	var whirlwind_body := player.get_node("WhirlwindBodyEffect") as AnimatedSprite2D

	player.call("_play_whirlwind_visual")
	player.primary_impact_timer.start(1.0)
	_expect(not body.visible, "Whirlwind setup must hide the base body before the death transition test.")
	# The audio path is covered elsewhere; omit it here so the headless process
	# can exit immediately without retaining a transient playback resource.
	player.death_audio.stream = null
	player.apply_multiplayer_death_state()
	_expect(player.is_dead and player.controls_locked, "Multiplayer death must enter the locked dead state.")
	_expect(body.visible, "Death must keep the body visible instead of freezing or disappearing.")
	_expect(body.animation == &"death" and body.is_playing(), "Death must start the authored non-looping animation.")
	_expect(not slash.visible and not whirlwind_range.visible and not whirlwind_body.visible, "Death must clear every attack VFX layer.")
	_expect(player.primary_impact_timer.is_stopped(), "Death must cancel a pending primary impact.")
	_expect(player.whirlwind_impact_timer.is_stopped(), "Death must cancel a pending whirlwind impact.")
	await create_timer(0.65).timeout
	_expect(body.visible, "The settled death pose must remain visible.")
	_expect(
		body.animation == &"death" and body.frame == 4,
		"Death must retain its final authored frame (got frame %d, playing=%s)." % [body.frame, body.is_playing()]
	)
	player.play_remote_hoe_action(&"whirlwind", Vector2.RIGHT, 2)
	_expect(
		body.visible and body.animation == &"death" and body.frame == 4,
		"An in-flight remote action confirmation must not overwrite death."
	)
	_expect(
		not whirlwind_range.visible and not whirlwind_body.visible,
		"An in-flight remote action confirmation must not restore attack VFX after death."
	)
	body.hide()
	body.play(&"attack_right")
	player.apply_multiplayer_death_state()
	_expect(
		body.visible and body.animation == &"death" and body.is_playing(),
		"A repeated authoritative death state must repair an overwritten death visual."
	)


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
	if is_instance_valid(player) and player.death_audio != null:
		player.death_audio.stop()
		player.death_audio.stream = null
	if is_instance_valid(test_root):
		test_root.free()
	player = null
	test_root = null
	if failures.is_empty():
		print("PLAYER_HOE_CAT_RENDER_CHAIN_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)
