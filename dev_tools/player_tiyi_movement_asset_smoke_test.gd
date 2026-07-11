extends SceneTree

const PLAYER_SCENE := preload("res://scene/player/tiyi/player_tiyi.tscn")
const CANONICAL_PATH := "res://dev_assets/source_images/player_tiyi/movement_logical_lossless.png"
const RUNTIME_PATH := "res://resources/texture/player/tiyi/movement.png"
const DEATH_PATH := "res://resources/texture/player/tiyi/body.png"

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

	var player := PLAYER_SCENE.instantiate() as PlayerTiyi
	_expect(player != null, "Tiyi must instantiate for movement asset validation.")
	if player != null:
		root.add_child(player)
		var body_sprite := player.get_node("BodySprite") as AnimatedSprite2D
		_expect(body_sprite != null, "Tiyi must keep its BodySprite contract.")
		if body_sprite != null:
			for animation_name in [
				&"idle_down",
				&"idle_up",
				&"idle_right",
				&"idle_left",
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
			_assert_animation_uses_texture(body_sprite.sprite_frames, &"death", DEATH_PATH)
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


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
