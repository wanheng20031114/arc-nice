extends SceneTree

const PLAYER_SCENE := preload("res://scene/player/tiyi/player_tiyi.tscn")
const CHARACTER_CARD_SCENE := preload("res://scene/character_selection/player_character_card.tscn")
const PROFILE_PANEL_SCENE := preload("res://scene/player/ui/player_profile_panel.tscn")
const CANONICAL_PATH := "res://dev_assets/source_images/player_tiyi/movement_scale1_20px_candidate.png"
const RUNTIME_PATH := "res://resources/texture/player/tiyi/movement.png"
const PORTRAIT_PATH := "res://resources/texture/player/tiyi/portrait.png"
const DEATH_PATH := "res://resources/texture/player/tiyi/body.png"
const HIGH_NOON_CAST_PATH := "res://resources/texture/player/tiyi/high_noon_cast.png"

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var canonical_bytes := FileAccess.get_file_as_bytes(CANONICAL_PATH)
	var runtime_bytes := FileAccess.get_file_as_bytes(RUNTIME_PATH)
	_expect(not canonical_bytes.is_empty(), "The approved Tiyi movement source must exist.")
	_expect(
		canonical_bytes == runtime_bytes,
		"The runtime movement texture must be byte-identical to the approved source."
	)
	var canonical_image := Image.load_from_file(CANONICAL_PATH)
	var imported_texture := load(RUNTIME_PATH) as Texture2D
	var imported_image := imported_texture.get_image() if imported_texture != null else null
	_expect(
		canonical_image != null
		and imported_image != null
		and _images_match_authored_pixels(canonical_image, imported_image),
		"Godot's imported Tiyi movement texture must preserve Alpha and visible RGBA pixels."
	)
	var expected_portrait := canonical_image.get_region(Rect2i(0, 0, 32, 32))
	expected_portrait.resize(128, 128, Image.INTERPOLATE_NEAREST)
	var portrait_image := Image.load_from_file(ProjectSettings.globalize_path(PORTRAIT_PATH))
	_expect(
		portrait_image != null and expected_portrait.get_data() == portrait_image.get_data(),
		"Tiyi's UI portrait must be normal_down frame 0 enlarged exactly 4x."
	)
	var imported_portrait_texture := load(PORTRAIT_PATH) as Texture2D
	var imported_portrait_image := (
		imported_portrait_texture.get_image() if imported_portrait_texture != null else null
	)
	_expect(
		portrait_image != null
		and imported_portrait_image != null
		and _images_match_authored_pixels(portrait_image, imported_portrait_image),
		"Godot's imported Tiyi UI portrait must preserve the authored frame-0 pixels."
	)
	var high_noon_cast_image := Image.load_from_file(
		ProjectSettings.globalize_path(HIGH_NOON_CAST_PATH)
	)
	var imported_high_noon_cast_texture := load(HIGH_NOON_CAST_PATH) as Texture2D
	var imported_high_noon_cast_image := (
		imported_high_noon_cast_texture.get_image()
		if imported_high_noon_cast_texture != null
		else null
	)
	_expect(
		high_noon_cast_image != null
		and high_noon_cast_image.get_size() == Vector2i(448, 48)
		and imported_high_noon_cast_image != null
		and _images_match_authored_pixels(
			high_noon_cast_image,
			imported_high_noon_cast_image
		),
		"Tiyi's imported seven-frame High Noon cast sheet must preserve its authored pixels."
	)

	var player := PLAYER_SCENE.instantiate() as PlayerTiyi
	_expect(player != null, "Tiyi must instantiate for movement asset validation.")
	if player != null:
		root.add_child(player)
		var body_sprite := player.get_node("BodySprite") as AnimatedSprite2D
		_expect(body_sprite != null, "Tiyi must keep its BodySprite contract.")
		if body_sprite != null:
			_expect(
				body_sprite.scale == Vector2.ONE,
				"Tiyi must render native logical pixels at integer scale 1."
			)
			for animation_name in [
				&"normal_down",
				&"normal_up",
				&"normal_right",
				&"normal_left",
				&"armed_down",
				&"armed_up",
				&"armed_right",
				&"armed_left"
			]:
				_assert_animation_uses_texture(body_sprite.sprite_frames, animation_name, RUNTIME_PATH)
			for idle_animation in [&"idle_down", &"idle_up", &"idle_right", &"idle_left"]:
				_expect(
					not body_sprite.sprite_frames.has_animation(idle_animation),
					"Tiyi must not retain a static %s animation." % idle_animation
				)
			_assert_animation_uses_texture(body_sprite.sprite_frames, &"death", DEATH_PATH)
			player.velocity = Vector2.ZERO
			player.call("_update_animation")
			_expect(
				body_sprite.animation == &"normal_right" and body_sprite.is_playing(),
				"Tiyi must keep the normal directional loop playing while standing still."
			)
		var armed_effect := player.get_node("ArmedEffectSprite") as AnimatedSprite2D
		_expect(
			armed_effect != null and armed_effect.scale == Vector2.ONE,
			"Tiyi's armed effect must use the same integer scale as the body."
		)
		var high_noon_cast_effect := player.get_node(
			"HighNoonCastEffectSprite"
		) as AnimatedSprite2D
		_expect(
			high_noon_cast_effect != null
			and high_noon_cast_effect.scale == Vector2.ONE
			and high_noon_cast_effect.sprite_frames.get_frame_count(&"default") == 7
			and is_equal_approx(
				high_noon_cast_effect.sprite_frames.get_animation_speed(&"default"),
				14.0
			),
			"Tiyi's High Noon cast effect must keep seven native frames at 14 FPS."
		)
		if high_noon_cast_effect != null:
			_assert_animation_uses_texture(
				high_noon_cast_effect.sprite_frames,
				&"default",
				HIGH_NOON_CAST_PATH
			)
		var character_config := player.get_character_config()
		_expect(
			character_config != null and character_config.portrait_texture == PORTRAIT_PATH,
			"Tiyi's shared card/profile portrait config must use the frame-0 portrait."
		)
		var character_card := CHARACTER_CARD_SCENE.instantiate() as PlayerCharacterCard
		root.add_child(character_card)
		character_card.setup(character_config)
		var card_portrait := character_card.get_node(
			"Margin/Content/PortraitFrame/PortraitLayer/Portrait"
		) as TextureRect
		_expect(
			card_portrait != null
			and card_portrait.texture != null
			and card_portrait.texture.resource_path == PORTRAIT_PATH,
			"Tiyi's character-selection card must display normal_down frame 0."
		)
		var profile_panel := PROFILE_PANEL_SCENE.instantiate() as PlayerProfilePanel
		root.add_child(profile_panel)
		profile_panel.bind_player(player)
		_expect(
			profile_panel.portrait.texture != null
			and profile_panel.portrait.texture.resource_path == PORTRAIT_PATH,
			"Tiyi's profile inventory panel must display normal_down frame 0."
		)
		character_card.queue_free()
		profile_panel.queue_free()
		player.queue_free()
		await process_frame

	if failures.is_empty():
		print("PLAYER_TIYI_MOVEMENT_ASSET_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _assert_animation_uses_texture(
	sprite_frames: SpriteFrames,
	animation_name: StringName,
	expected_path: String
) -> void:
	_expect(
		sprite_frames != null and sprite_frames.has_animation(animation_name),
		"Missing Tiyi animation %s." % animation_name
	)
	if sprite_frames == null or not sprite_frames.has_animation(animation_name):
		return
	for frame_index in range(sprite_frames.get_frame_count(animation_name)):
		var atlas_texture := sprite_frames.get_frame_texture(
			animation_name,
			frame_index
		) as AtlasTexture
		_expect(
			atlas_texture != null
			and atlas_texture.atlas != null
			and atlas_texture.atlas.resource_path == expected_path,
			"Animation %s frame %d must use %s."
			% [animation_name, frame_index, expected_path]
		)


func _images_match_authored_pixels(expected: Image, actual: Image) -> bool:
	if expected == null or actual == null or expected.get_size() != actual.get_size():
		return false
	expected.convert(Image.FORMAT_RGBA8)
	actual.convert(Image.FORMAT_RGBA8)
	for y in range(expected.get_height()):
		for x in range(expected.get_width()):
			var expected_color := expected.get_pixel(x, y)
			var actual_color := actual.get_pixel(x, y)
			if expected_color.a != actual_color.a:
				push_error(
					"Imported Tiyi Alpha mismatch at (%d, %d): %s != %s"
					% [x, y, expected_color.to_html(true), actual_color.to_html(true)]
				)
				return false
			if expected_color.a > 0.0 and expected_color.to_rgba32() != actual_color.to_rgba32():
				push_error(
					"Imported Tiyi visible RGBA mismatch at (%d, %d): %s != %s"
					% [x, y, expected_color.to_html(true), actual_color.to_html(true)]
				)
				return false
	return true


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
