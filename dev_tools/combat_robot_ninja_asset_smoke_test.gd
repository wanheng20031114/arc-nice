extends SceneTree

const NINJA_FRAMES: SpriteFrames = preload(
	"res://resources/animation/combat_robot_ninja.tres"
)
const NINJA_TEXTURE: Texture2D = preload(
	"res://resources/texture/enemy/mechanical_life/combat_robot_ninja.png"
)
const MOTION_SHADER_PATH := "res://scene/entity_motion_status.gdshader"
const ANIMATION_CONTRACT := {
	&"move": {"row": 0, "speed": 20.0, "loop": true},
	&"boost": {"row": 1, "speed": 24.0, "loop": true},
	&"death": {"row": 2, "speed": 12.0, "loop": false},
}

var failures := PackedStringArray()


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_expect(
		NINJA_TEXTURE.get_size() == Vector2(320.0, 120.0),
		"Ninja runtime texture must import as 320x120."
	)
	var animation_names := NINJA_FRAMES.get_animation_names()
	_expect(
		animation_names.size() == ANIMATION_CONTRACT.size(),
		"Ninja SpriteFrames must expose exactly move, boost and death."
	)
	for animation_name: StringName in ANIMATION_CONTRACT:
		var contract: Dictionary = ANIMATION_CONTRACT[animation_name]
		_expect(
			NINJA_FRAMES.has_animation(animation_name),
			"Missing ninja animation: %s" % animation_name
		)
		_expect(
			NINJA_FRAMES.get_frame_count(animation_name) == 8,
			"%s must contain eight frames." % animation_name
		)
		_expect(
			is_equal_approx(
				NINJA_FRAMES.get_animation_speed(animation_name),
				float(contract["speed"])
			),
			"%s animation speed changed." % animation_name
		)
		_expect(
			NINJA_FRAMES.get_animation_loop(animation_name) == bool(contract["loop"]),
			"%s loop contract changed." % animation_name
		)
		for frame_index in range(8):
			var frame := (
				NINJA_FRAMES.get_frame_texture(animation_name, frame_index)
				as AtlasTexture
			)
			_expect(frame != null, "%s[%d] is not an AtlasTexture." % [animation_name, frame_index])
			if frame == null:
				continue
			_expect(frame.filter_clip, "%s[%d] must enable filter_clip." % [animation_name, frame_index])
			_expect(
				frame.region == Rect2(
					float(frame_index * 40),
					float(int(contract["row"]) * 40),
					40.0,
					40.0
				),
				"%s[%d] atlas region changed." % [animation_name, frame_index]
			)
			_expect(
				is_equal_approx(
					NINJA_FRAMES.get_frame_duration(animation_name, frame_index),
					1.0
				),
				"%s[%d] duration weight changed." % [animation_name, frame_index]
			)
	_expect(
		int(ProjectSettings.get_setting(
			"rendering/textures/canvas_textures/default_texture_filter",
			-1
		)) == 0,
		"Project canvas textures must remain nearest-neighbor."
	)
	var shader_source := FileAccess.get_file_as_string(MOTION_SHADER_PATH)
	_expect(
		shader_source.contains("instance uniform float ninja_afterimage_strength")
		and shader_source.contains("instance uniform vec2 ninja_afterimage_direction")
		and shader_source.contains("// Ninja afterimages preserve the source body"),
		"Production motion shader misses the ninja afterimage contract."
	)
	if failures.is_empty():
		print(
			"COMBAT_ROBOT_NINJA_ASSET_SMOKE_TEST_OK "
			+ "animations=3 frames=24 texture=320x120"
		)
		quit(0)
		return
	print("COMBAT_ROBOT_NINJA_ASSET_SMOKE_TEST_FAILED count=%d" % failures.size())
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if condition:
		return
	failures.append(message)
	push_error(message)
