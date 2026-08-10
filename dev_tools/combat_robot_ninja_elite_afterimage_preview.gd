extends Node

const SOURCE_PATH := "res://dev_assets/source_images/combat_robot_ninja_elite/combat_robot_ninja_elite_afterimage_review_source.png"
const STATUS_SHADER_PATH := "res://scene/combat/feedback/shaders/entity_motion_status.gdshader"
const ENEMY_SCENE_PATH := "res://scene/enemy/enemy.tscn"
const NINJA_SCENE_PATH := "res://scene/enemy/mechanical_life/combat_robot_ninja.tscn"
const NINJA_SCRIPT_PATH := "res://scene/enemy/mechanical_life/combat_robot_ninja.gd"
const RAW_OUTPUT_DIRECTORY := "res://dev_tools/output/combat_robot_ninja_elite_afterimage"

const EXPECTED_SOURCE_SHA := "6c0f50f2e02be51264ba92b269d26366653a0608cbed2b186e6c43c8ae2bd23b"
const EXPECTED_SOURCE_RGBA_SHA := "5fc943f0369c1e6a6f26f374c5c07542e2d92dd780e9a8ea7157220dca7001d3"
const EXPECTED_SHADER_SHA := "10454b4a7db41abf7ec5881a4f516f919868df1bbf1b395cc86346edc4de05f6"
const EXPECTED_ENEMY_SCENE_SHA := "48127a5e51bdcdce48c299a3185dd0b0bfcd684e4041850b3e419d9e306458ee"
const EXPECTED_NINJA_SCRIPT_SHA := "ded06d64d7e10ac74dd4015f1daccb968e0ab80aec230e7208dd455e0225db21"
const EXPECTED_NINJA_SCENE_SHA := "a040c7453b200355fe7f6ec61b5873c19367d63fbbbfacd25a4b4ed6c437201c"
const EXPECTED_ROW_RGBA_SHA := {
	"move": "cfb00c5e0c1e330d41a0bfcee6827576b52f39e8a7ca3c6875fb3511eed921ba",
	"boost": "e44ebfa9e6ba7f4cba50a38acf3f114ae87829f8fc1e047b6610243f2936cb37",
	"death": "616bff1518b607e5f58e60e1375eeb0fc339f41ec92e4280062d739757357ed0",
}
const APPROVED_ROW_PATHS := {
	"move": "res://dev_assets/source_images/combat_robot_ninja_elite/combat_robot_ninja_elite_move_m1_candidate_native.png",
	"boost": "res://dev_assets/source_images/combat_robot_ninja_elite/combat_robot_ninja_elite_boost_s2_candidate_native.png",
	"death": "res://dev_assets/source_images/combat_robot_ninja_elite/combat_robot_ninja_elite_death_d1_candidate_native.png",
}
const EXPECTED_ROW_FILE_SHA := {
	"move": "0d2abb9e49f38d1d9ff09a6e874485168e15798d78cd503a241fe601e1a5f3d9",
	"boost": "d227677c16a89685489649ddb56362c84356f81181792a920f1f0180638058b2",
	"death": "e886670c43fece56df7462ce8fb8b8bacae69bd8ab0d7ff82fc1c431e4aa7ffe",
}

const FRAME_SIZE := 40
const FRAME_COUNT := 8
const REVIEW_SCALE := 16
const REVIEW_SIZE := Vector2i(640, 640)
const REVIEW_BACKGROUND := Color8(13, 19, 31, 255)
const AFTERIMAGE_STRENGTH := 1.0
const AFTERIMAGE_PIXELS := 4.0
const SLOW_STRENGTH := 0.36
const BURN_STRENGTH := 0.26
const CHANGE_TOLERANCE := 1.0 / 255.0
const TRAIL_CHANGE_THRESHOLD := 0.02
const AFTERIMAGE_STRENGTH_PARAMETER := &"ninja_afterimage_strength"
const AFTERIMAGE_DIRECTION_PARAMETER := &"ninja_afterimage_direction"
const AFTERIMAGE_PIXELS_PARAMETER := &"ninja_afterimage_pixels"
const SLOW_PARAMETER := &"slow_overlay_strength"
const BURN_PARAMETER := &"burn_overlay_strength"

const DIRECTION_SPECS := [
	{"name": "right", "world": Vector2.RIGHT, "flip_h": false, "local": Vector2.RIGHT},
	{"name": "left", "world": Vector2.LEFT, "flip_h": true, "local": Vector2.RIGHT},
	{"name": "up", "world": Vector2.UP, "flip_h": false, "local": Vector2.UP},
	{"name": "down", "world": Vector2.DOWN, "flip_h": false, "local": Vector2.DOWN},
	{"name": "down_right", "world": Vector2(0.70710678, 0.70710678), "flip_h": false, "local": Vector2(0.70710678, 0.70710678)},
	{"name": "up_left", "world": Vector2(-0.70710678, -0.70710678), "flip_h": true, "local": Vector2(0.70710678, -0.70710678)},
]

const STATUS_SPECS := [
	{"name": "trail", "strength": 1.0, "slow": 0.0, "burn": 0.0},
	{"name": "slow_only", "strength": 0.0, "slow": 0.36, "burn": 0.0},
	{"name": "burn_only", "strength": 0.0, "slow": 0.0, "burn": 0.26},
	{"name": "slow_burn_only", "strength": 0.0, "slow": 0.36, "burn": 0.26},
	{"name": "trail_slow", "strength": 1.0, "slow": 0.36, "burn": 0.0},
	{"name": "trail_burn", "strength": 1.0, "slow": 0.0, "burn": 0.26},
	{"name": "trail_slow_burn", "strength": 1.0, "slow": 0.36, "burn": 0.26},
	{"name": "boost_end_slow_burn", "strength": 0.0, "slow": 0.36, "burn": 0.26},
]

@onready var direction_viewport: SubViewport = $DirectionViewport
@onready var status_viewport: SubViewport = $StatusViewport
@onready var transition_viewport: SubViewport = $TransitionViewport
@onready var atlas_comparison_viewport: SubViewport = $AtlasComparisonViewport

var failures := PackedStringArray()
var source_image: Image = null
var source_texture: ImageTexture = null
var atlas_frames: Array = [[], [], []]
var standalone_frames: Array = [[], [], []]
var shared_material: ShaderMaterial = null
var production_shader: Shader = null
var direction_active_sprites: Array[Sprite2D] = []
var direction_baseline_sprites: Array[Sprite2D] = []
var status_sprites: Array[Sprite2D] = []
var transition_sprites: Array[Sprite2D] = []
var comparison_sprites: Array[Sprite2D] = []
var all_fixtures: Array[Sprite2D] = []
var material_uniforms_before := {}
var material_uniforms_after := {}
var production_material_instance_id := 0
var production_material_rid := 0
var production_shader_instance_id := 0
var production_shader_rid := 0
var direction_audit := {
	"body_changed_pixels": {},
	"trail_only_pixels": {},
	"trail_body_intersection_pixels": {},
	"trail_world_direction_dot": {},
	"original_rgb_oracle_max_channel_error": {},
}
var status_audit := {}
var phase_preservation := {}
var death_cleanup := {
	"boost_tail_pixels_before": 0,
	"first_death_frame_tail_pixels": -1,
	"strength_after": 0.0,
}
var atlas_differences := {}
var lifecycle_report := {}
var maximum_review_unique_rgb := 0
var captures := {}


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var output_absolute := ProjectSettings.globalize_path(RAW_OUTPUT_DIRECTORY)
	_expect(DirAccess.make_dir_recursive_absolute(output_absolute) == OK, "Could not create raw output directory.")
	_clear_stale_raw_outputs(output_absolute)
	_verify_locked_inputs()
	_load_source()
	_obtain_shared_production_material()
	_build_frame_textures()
	_build_fixtures()
	_validate_shared_material_and_instance_parameters()
	phase_preservation = _run_phase_preservation_proof()
	lifecycle_report = _run_material_lifecycle_proof()
	await _wait_for_render_frames(2)
	await _capture_animation_frames()
	await _capture_atlas_audit()
	material_uniforms_after = _snapshot_material_uniforms()
	_expect(material_uniforms_before == material_uniforms_after, "Shared material uniforms changed during capture.")
	_write_runtime_report()
	_finish()


func _clear_stale_raw_outputs(output_absolute: String) -> void:
	var directory := DirAccess.open(output_absolute)
	if directory == null:
		return
	for file_name in directory.get_files():
		if file_name.ends_with(".png") or file_name == "runtime_report.json":
			_expect(directory.remove(file_name) == OK, "Could not remove stale raw output: %s" % file_name)


func _verify_locked_inputs() -> void:
	var locks := {
		SOURCE_PATH: EXPECTED_SOURCE_SHA,
		STATUS_SHADER_PATH: EXPECTED_SHADER_SHA,
		ENEMY_SCENE_PATH: EXPECTED_ENEMY_SCENE_SHA,
		NINJA_SCRIPT_PATH: EXPECTED_NINJA_SCRIPT_SHA,
		NINJA_SCENE_PATH: EXPECTED_NINJA_SCENE_SHA,
	}
	for path in locks:
		_expect(FileAccess.file_exists(path), "Missing locked input: %s" % path)
		if FileAccess.file_exists(path):
			_expect(FileAccess.get_sha256(path) == locks[path], "Locked SHA drifted: %s" % path)
	for row_name in APPROVED_ROW_PATHS:
		var row_path: String = APPROVED_ROW_PATHS[row_name]
		_expect(FileAccess.file_exists(row_path), "Missing approved row: %s" % row_path)
		if FileAccess.file_exists(row_path):
			_expect(
				FileAccess.get_sha256(row_path) == EXPECTED_ROW_FILE_SHA[row_name],
				"Approved row SHA drifted: %s" % row_path
			)


func _load_source() -> void:
	source_image = Image.load_from_file(ProjectSettings.globalize_path(SOURCE_PATH))
	_expect(source_image != null and not source_image.is_empty(), "Review source could not be decoded.")
	if source_image == null or source_image.is_empty():
		return
	source_image.convert(Image.FORMAT_RGBA8)
	_expect(source_image.get_size() == Vector2i(320, 120), "Review source must remain 320x120.")
	_expect(_sha256_bytes(source_image.get_data()) == EXPECTED_SOURCE_RGBA_SHA, "Review source decoded RGBA SHA drifted.")
	for row_index in range(3):
		var row := source_image.get_region(Rect2i(0, row_index * FRAME_SIZE, 320, FRAME_SIZE))
		var row_name: String = ["move", "boost", "death"][row_index]
		_expect(_sha256_bytes(row.get_data()) == EXPECTED_ROW_RGBA_SHA[row_name], "%s row RGBA SHA drifted." % row_name)
	source_texture = ImageTexture.create_from_image(source_image)


func _obtain_shared_production_material() -> void:
	var enemy_scene := load(ENEMY_SCENE_PATH) as PackedScene
	_expect(enemy_scene != null, "Production enemy scene failed to load.")
	if enemy_scene == null:
		return
	var enemy_a := enemy_scene.instantiate()
	var enemy_b := enemy_scene.instantiate()
	var sprite_a := enemy_a.get_node("AnimatedSprite2D") as AnimatedSprite2D
	var sprite_b := enemy_b.get_node("AnimatedSprite2D") as AnimatedSprite2D
	var material_a := sprite_a.material as ShaderMaterial
	var material_b := sprite_b.material as ShaderMaterial
	_expect(material_a != null and material_a == material_b, "Two production enemy instances did not share ShaderMaterial_enemy.")
	shared_material = material_a
	production_shader = load(STATUS_SHADER_PATH) as Shader
	_expect(production_shader != null and shared_material.shader == production_shader, "Production material does not point at the direct production shader.")
	_expect(not shared_material.resource_local_to_scene, "Production material became local-to-scene.")
	production_material_instance_id = shared_material.get_instance_id()
	production_material_rid = shared_material.get_rid().get_id()
	production_shader_instance_id = production_shader.get_instance_id()
	production_shader_rid = production_shader.get_rid().get_id()
	var shader_source := FileAccess.get_file_as_string(STATUS_SHADER_PATH)
	_expect(
		shader_source.contains("instance uniform float ninja_afterimage_strength")
		and shader_source.contains("instance uniform vec2 ninja_afterimage_direction")
		and shader_source.contains("uniform float ninja_afterimage_pixels")
		and shader_source.contains("// Ninja afterimages preserve the source body"),
		"Production afterimage shader block drifted."
	)
	_expect(
		shader_source.find("if (ninja_afterimage_strength") < shader_source.find("if (slow_overlay_strength")
		and shader_source.find("if (slow_overlay_strength") < shader_source.find("if (burn_overlay_strength"),
		"Afterimage block no longer precedes slow/burn composition."
	)
	_expect(is_equal_approx(_resolved_afterimage_pixels(), AFTERIMAGE_PIXELS), "Shared ninja_afterimage_pixels is not 4.0.")
	material_uniforms_before = _snapshot_material_uniforms()
	enemy_a.free()
	enemy_b.free()


func _snapshot_material_uniforms() -> Dictionary:
	var snapshot := {}
	if production_shader == null or shared_material == null:
		return snapshot
	var uniforms: Variant = production_shader.call("get_shader_uniform_list")
	if uniforms is Array:
		for item in uniforms:
			if item is Dictionary and item.has("name"):
				var parameter_name := StringName(item["name"])
				snapshot[str(parameter_name)] = var_to_str(shared_material.get_shader_parameter(parameter_name))
	return snapshot


func _resolved_afterimage_pixels() -> float:
	var material_override: Variant = shared_material.get_shader_parameter(AFTERIMAGE_PIXELS_PARAMETER)
	if material_override != null:
		return float(material_override)
	var shader_source := FileAccess.get_file_as_string(STATUS_SHADER_PATH)
	_expect(
		shader_source.contains("uniform float ninja_afterimage_pixels : hint_range(1.0, 4.0) = 4.0;"),
		"Production shader default for ninja_afterimage_pixels is no longer 4.0."
	)
	return AFTERIMAGE_PIXELS


func _build_frame_textures() -> void:
	for row_index in range(3):
		for frame_index in range(FRAME_COUNT):
			var atlas := AtlasTexture.new()
			atlas.atlas = source_texture
			atlas.region = Rect2(frame_index * FRAME_SIZE, row_index * FRAME_SIZE, FRAME_SIZE, FRAME_SIZE)
			atlas.filter_clip = true
			atlas_frames[row_index].append(atlas)
			var frame_image := source_image.get_region(Rect2i(frame_index * FRAME_SIZE, row_index * FRAME_SIZE, FRAME_SIZE, FRAME_SIZE))
			standalone_frames[row_index].append(ImageTexture.create_from_image(frame_image))


func _build_fixtures() -> void:
	for viewport in [direction_viewport, status_viewport, transition_viewport, atlas_comparison_viewport]:
		viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	for index in range(DIRECTION_SPECS.size()):
		var spec: Dictionary = DIRECTION_SPECS[index]
		var active := _new_fixture(direction_viewport, Vector2(index * 40 + 20, 20), atlas_frames[1][0], bool(spec["flip_h"]))
		var baseline := _new_fixture(direction_viewport, Vector2(index * 40 + 20, 60), atlas_frames[1][0], bool(spec["flip_h"]))
		_apply_instance_parameters(active, 1.0, spec["local"], 0.0, 0.0)
		_apply_instance_parameters(baseline, 0.0, spec["local"], 0.0, 0.0)
		direction_active_sprites.append(active)
		direction_baseline_sprites.append(baseline)
	for index in range(STATUS_SPECS.size()):
		var spec: Dictionary = STATUS_SPECS[index]
		var sprite := _new_fixture(status_viewport, Vector2((index % 4) * 40 + 20, (index / 4) * 40 + 20), atlas_frames[1][0], false)
		_apply_instance_parameters(sprite, float(spec["strength"]), Vector2.RIGHT, float(spec["slow"]), float(spec["burn"]))
		status_sprites.append(sprite)
	for index in range(3):
		var sprite := _new_fixture(transition_viewport, Vector2(index * 40 + 20, 20), atlas_frames[0][0], false)
		_apply_instance_parameters(sprite, 0.0, Vector2.RIGHT, 0.0, 0.0)
		transition_sprites.append(sprite)
	var comparison_atlas := _new_fixture(atlas_comparison_viewport, Vector2(20, 20), atlas_frames[0][0], false)
	var comparison_standalone := _new_fixture(atlas_comparison_viewport, Vector2(70, 20), standalone_frames[0][0], false)
	_apply_instance_parameters(comparison_atlas, 1.0, Vector2.RIGHT, 0.0, 0.0)
	_apply_instance_parameters(comparison_standalone, 1.0, Vector2.RIGHT, 0.0, 0.0)
	comparison_sprites = [comparison_atlas, comparison_standalone]


func _new_fixture(viewport: SubViewport, position: Vector2, texture: Texture2D, flip_h: bool) -> Sprite2D:
	var sprite := Sprite2D.new()
	sprite.texture = texture
	sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	sprite.position = position
	sprite.flip_h = flip_h
	sprite.material = shared_material
	viewport.add_child(sprite)
	all_fixtures.append(sprite)
	return sprite


func _apply_instance_parameters(sprite: Sprite2D, strength: float, direction: Vector2, slow: float, burn: float) -> void:
	sprite.set_instance_shader_parameter(AFTERIMAGE_STRENGTH_PARAMETER, strength)
	sprite.set_instance_shader_parameter(AFTERIMAGE_DIRECTION_PARAMETER, direction.normalized())
	sprite.set_instance_shader_parameter(SLOW_PARAMETER, slow)
	sprite.set_instance_shader_parameter(BURN_PARAMETER, burn)


func _validate_shared_material_and_instance_parameters() -> void:
	var material_ids := {}
	var shader_ids := {}
	for sprite in all_fixtures:
		_expect(sprite.material == shared_material, "A fixture did not use the shared production material.")
		material_ids[str(sprite.material.get_instance_id())] = true
		var fixture_material := sprite.material as ShaderMaterial
		shader_ids[str(fixture_material.shader.get_instance_id())] = true
	_expect(material_ids.size() == 1 and shader_ids.size() == 1, "Fixture material/shader identities are not singular.")
	for index in range(DIRECTION_SPECS.size()):
		var spec: Dictionary = DIRECTION_SPECS[index]
		var active := direction_active_sprites[index]
		var baseline := direction_baseline_sprites[index]
		_expect(is_equal_approx(float(active.get_instance_shader_parameter(AFTERIMAGE_STRENGTH_PARAMETER)), 1.0), "Active direction strength did not round-trip.")
		_expect(is_zero_approx(float(baseline.get_instance_shader_parameter(AFTERIMAGE_STRENGTH_PARAMETER))), "Baseline direction strength did not round-trip.")
		_expect((active.get_instance_shader_parameter(AFTERIMAGE_DIRECTION_PARAMETER) as Vector2).is_equal_approx(spec["local"]), "Per-instance direction did not round-trip.")


func _build_review_sprite_frames() -> SpriteFrames:
	var frames := SpriteFrames.new()
	frames.remove_animation(&"default")
	for row_index in range(3):
		var animation_name: StringName = [&"move", &"boost", &"death"][row_index]
		frames.add_animation(animation_name)
		frames.set_animation_loop(animation_name, row_index != 2)
		frames.set_animation_speed(animation_name, [20.0, 24.0, 12.0][row_index])
		for frame in atlas_frames[row_index]:
			frames.add_frame(animation_name, frame)
	return frames


func _run_phase_preservation_proof() -> Dictionary:
	var ninja_scene := load(NINJA_SCENE_PATH) as PackedScene
	var ninja = ninja_scene.instantiate()
	var sprite := ninja.get_node("AnimatedSprite2D") as AnimatedSprite2D
	ninja.animated_sprite = sprite
	sprite.sprite_frames = _build_review_sprite_frames()
	sprite.play(&"move")
	sprite.set_frame_and_progress(3, 0.25)
	var move_playing_before := sprite.is_playing()
	ninja.call("_switch_locomotion_animation_preserving_phase", &"boost", false)
	var move_to_boost := {
		"preserved": sprite.frame == 3 and is_equal_approx(sprite.frame_progress, 0.25) and sprite.is_playing() == move_playing_before,
		"input_frame": 3, "input_progress": 0.25,
		"output_frame": sprite.frame, "output_progress": sprite.frame_progress,
		"playing_before": move_playing_before, "playing_after": sprite.is_playing(),
	}
	sprite.play(&"boost")
	sprite.set_frame_and_progress(7, 0.75)
	var boost_playing_before := sprite.is_playing()
	ninja.call("_switch_locomotion_animation_preserving_phase", &"move", false)
	var boost_to_move := {
		"preserved": sprite.frame == 7 and is_equal_approx(sprite.frame_progress, 0.75) and sprite.is_playing() == boost_playing_before,
		"input_frame": 7, "input_progress": 0.75,
		"output_frame": sprite.frame, "output_progress": sprite.frame_progress,
		"playing_before": boost_playing_before, "playing_after": sprite.is_playing(),
	}
	_expect(move_to_boost["preserved"] and boost_to_move["preserved"], "Production phase-preservation method failed.")
	ninja.free()
	return {"production_method": "_switch_locomotion_animation_preserving_phase", "method_called": true, "move_to_boost": move_to_boost, "boost_to_move": boost_to_move}


func _run_material_lifecycle_proof() -> Dictionary:
	var ninja_scene := load(NINJA_SCENE_PATH) as PackedScene
	var ninja = ninja_scene.instantiate()
	var sprite := ninja.get_node("AnimatedSprite2D") as AnimatedSprite2D
	_expect(sprite.material == shared_material, "Production ninja did not inherit shared material.")
	ninja.animated_sprite = sprite
	ninja.status_visual_material = shared_material
	sprite.material = null
	var initial_null := sprite.material == null
	ninja.boost_active = true
	ninja.call("_set_afterimage_strength", 1.0)
	var boost_attached := sprite.material == shared_material
	var boost_rid := (sprite.material as ShaderMaterial).get_rid().get_id() if sprite.material != null else 0
	ninja.call("_set_visual_shader_parameter", SLOW_PARAMETER, SLOW_STRENGTH)
	ninja.call("_set_visual_shader_parameter", BURN_PARAMETER, BURN_STRENGTH)
	var statuses_same_rid := sprite.material == shared_material and (sprite.material as ShaderMaterial).get_rid().get_id() == boost_rid
	var slow_retained := sprite.material == shared_material
	var burn_retained := sprite.material == shared_material
	ninja.boost_active = false
	ninja.call("_set_afterimage_strength", 0.0)
	var boost_end_kept_for_status := sprite.material == shared_material
	ninja.call("_set_visual_shader_parameter", SLOW_PARAMETER, 0.0)
	var one_status_kept := sprite.material == shared_material
	ninja.call("_set_visual_shader_parameter", BURN_PARAMETER, 0.0)
	var final_null := sprite.material == null
	var result := {
		"initial_material_null": initial_null,
		"boost_attached_cached_shared_material": boost_attached,
		"slow_burn_did_not_change_rid": statuses_same_rid,
		"boost_end_kept_material_for_status": boost_end_kept_for_status,
		"one_remaining_status_kept_material": one_status_kept,
		"last_status_clear_detached_material": final_null,
		"slow_retained_after_boost": slow_retained and boost_end_kept_for_status,
		"burn_retained_after_boost": burn_retained and boost_end_kept_for_status,
		"slow_burn_retained_after_boost": statuses_same_rid and boost_end_kept_for_status,
		"verified": initial_null and boost_attached and statuses_same_rid and boost_end_kept_for_status and one_status_kept and final_null,
	}
	_expect(result["verified"], "Production material lifecycle binding proof failed.")
	ninja.free()
	return result


func _capture_animation_frames() -> void:
	_initialize_status_audit_maps()
	for frame_index in range(FRAME_COUNT):
		for sprite in direction_active_sprites:
			sprite.texture = atlas_frames[1][frame_index]
		for sprite in direction_baseline_sprites:
			sprite.texture = atlas_frames[1][frame_index]
		for sprite in status_sprites:
			sprite.texture = atlas_frames[1][frame_index]
		_set_transition_frame(frame_index)
		await _wait_for_render_frames(2)
		var direction_image := direction_viewport.get_texture().get_image()
		var status_image := status_viewport.get_texture().get_image()
		var transition_image := transition_viewport.get_texture().get_image()
		_expect(not direction_image.is_empty() and not status_image.is_empty() and not transition_image.is_empty(), "A capture viewport returned an empty image.")
		var source_boost := source_image.get_region(Rect2i(frame_index * 40, 40, 40, 40))
		var direction_crops := []
		var baseline_crops := []
		for direction_index in range(DIRECTION_SPECS.size()):
			var active := direction_image.get_region(Rect2i(direction_index * 40, 0, 40, 40))
			var baseline := direction_image.get_region(Rect2i(direction_index * 40, 40, 40, 40))
			direction_crops.append(active)
			baseline_crops.append(baseline)
			var spec: Dictionary = DIRECTION_SPECS[direction_index]
			var key := "%s/frame_%d" % [spec["name"], frame_index]
			var metrics := _audit_direction_frame(baseline, active, source_boost, spec)
			for metric_name in direction_audit:
				direction_audit[metric_name][key] = metrics[metric_name]
			_save_review_frame(active, "direction_%s_frame_%d.png" % [spec["name"], frame_index])
		var state_crops := []
		for state_index in range(STATUS_SPECS.size()):
			state_crops.append(status_image.get_region(Rect2i((state_index % 4) * 40, (state_index / 4) * 40, 40, 40)))
		_audit_and_save_status_frame(frame_index, source_boost, baseline_crops[0], state_crops)
		var transition_crops := [
			transition_image.get_region(Rect2i(0, 0, 40, 40)),
			transition_image.get_region(Rect2i(40, 0, 40, 40)),
			transition_image.get_region(Rect2i(80, 0, 40, 40)),
		]
		_save_review_frame(transition_crops[0], "move_to_boost_frame_%d.png" % frame_index)
		_save_review_frame(transition_crops[1], "boost_to_move_frame_%d.png" % frame_index)
		_save_review_frame(transition_crops[2], "boost_to_death_cleanup_frame_%d.png" % frame_index)
		if frame_index == 3:
			death_cleanup["boost_tail_pixels_before"] = _count_transparent_trail(transition_crops[2], source_image.get_region(Rect2i(7 * 40, 40, 40, 40)))
		if frame_index == 4:
			death_cleanup["first_death_frame_tail_pixels"] = _count_transparent_trail(transition_crops[2], source_image.get_region(Rect2i(0, 80, 40, 40)))
	_expect(int(death_cleanup["boost_tail_pixels_before"]) > 0 and int(death_cleanup["first_death_frame_tail_pixels"]) == 0, "Boost-to-death cleanup retained a ghost or lacked the preceding trail.")
	lifecycle_report["death_tail_zero"] = int(death_cleanup["first_death_frame_tail_pixels"]) == 0
	lifecycle_report["boost_end_tail_zero"] = _all_status_boost_end_tails_zero()


func _set_transition_frame(output_index: int) -> void:
	# move->boost: M1[0,1,2,3], S2[3,4,5,6]
	if output_index < 4:
		transition_sprites[0].texture = atlas_frames[0][output_index]
		transition_sprites[0].set_instance_shader_parameter(AFTERIMAGE_STRENGTH_PARAMETER, 0.0)
	else:
		transition_sprites[0].texture = atlas_frames[1][output_index - 1]
		transition_sprites[0].set_instance_shader_parameter(AFTERIMAGE_STRENGTH_PARAMETER, 1.0)
	# boost->move: S2[4,5,6,7], M1[7,0,1,2]
	if output_index < 4:
		transition_sprites[1].texture = atlas_frames[1][output_index + 4]
		transition_sprites[1].set_instance_shader_parameter(AFTERIMAGE_STRENGTH_PARAMETER, 1.0)
	else:
		transition_sprites[1].texture = atlas_frames[0][(output_index + 3) % 8]
		transition_sprites[1].set_instance_shader_parameter(AFTERIMAGE_STRENGTH_PARAMETER, 0.0)
	# boost->death: S2[4,5,6,7], D1[0,1,2,3], death starts at frame zero.
	if output_index < 4:
		transition_sprites[2].texture = atlas_frames[1][output_index + 4]
		transition_sprites[2].set_instance_shader_parameter(AFTERIMAGE_STRENGTH_PARAMETER, 1.0)
	else:
		transition_sprites[2].texture = atlas_frames[2][output_index - 4]
		transition_sprites[2].set_instance_shader_parameter(AFTERIMAGE_STRENGTH_PARAMETER, 0.0)


func _audit_direction_frame(baseline: Image, active: Image, source: Image, spec: Dictionary) -> Dictionary:
	var body_changed := 0
	var trail_only := 0
	var trail_intersection := 0
	var trail_sum := Vector2.ZERO
	var body_sum := Vector2.ZERO
	var body_count := 0
	var oracle_error := 0.0
	var oracle_samples := 0
	for y in range(40):
		for x in range(40):
			var source_x := 39 - x if bool(spec["flip_h"]) else x
			var source_color := source.get_pixel(source_x, y)
			var before := baseline.get_pixel(x, y)
			var after := active.get_pixel(x, y)
			var delta := _max_color_delta(before, after)
			var is_body := source_color.a > 0.0
			if is_body:
				body_count += 1
				body_sum += Vector2(x, y)
				if delta > CHANGE_TOLERANCE:
					body_changed += 1
				if delta >= TRAIL_CHANGE_THRESHOLD:
					trail_intersection += 1
			elif delta >= TRAIL_CHANGE_THRESHOLD:
				trail_only += 1
				trail_sum += Vector2(x, y)
				var oracle := _single_source_rgb_oracle(source, Vector2i(source_x, y), spec["local"])
				if oracle["valid"]:
					oracle_samples += 1
					# Transparent SubViewport readback is premultiplied.  Compare against
					# the production source RGB premultiplied by the captured alpha rather
					# than mistaking the blend representation for a shader tint.
					var source_rgb: Color = oracle["color"]
					var expected_premultiplied := Color(
						source_rgb.r * after.a,
						source_rgb.g * after.a,
						source_rgb.b * after.a,
						after.a
					)
					oracle_error = maxf(oracle_error, _max_rgb_delta(after, expected_premultiplied))
	var centroid_dot := 0.0
	if trail_only > 0 and body_count > 0:
		centroid_dot = ((trail_sum / float(trail_only)) - (body_sum / float(body_count))).dot((spec["world"] as Vector2).normalized())
	_expect(body_changed == 0 and trail_intersection == 0, "Afterimage changed body pixels for %s." % spec["name"])
	_expect(trail_only > 0 and centroid_dot < -0.5, "Afterimage direction failed for %s." % spec["name"])
	_expect(oracle_samples > 0 and oracle_error <= CHANGE_TOLERANCE, "Original-RGB oracle failed for %s: samples=%d error=%f" % [spec["name"], oracle_samples, oracle_error])
	return {
		"body_changed_pixels": body_changed,
		"trail_only_pixels": trail_only,
		"trail_body_intersection_pixels": trail_intersection,
		"trail_world_direction_dot": centroid_dot,
		"original_rgb_oracle_max_channel_error": oracle_error,
	}


func _single_source_rgb_oracle(source: Image, point: Vector2i, local_direction: Vector2) -> Dictionary:
	var sampled := []
	for offset in [1.8, 3.6, 5.4]:
		var x := clampi(floori(float(point.x) + 0.5 + local_direction.x * offset), 0, 39)
		var y := clampi(floori(float(point.y) + 0.5 + local_direction.y * offset), 0, 39)
		var color := source.get_pixel(x, y)
		if color.a > 0.0:
			sampled.append(color)
	if sampled.size() == 1:
		return {"valid": true, "color": sampled[0]}
	return {"valid": false, "color": Color.TRANSPARENT}


func _initialize_status_audit_maps() -> void:
	status_audit = {
		"slow": _empty_status_record({"slow": 0.36, "burn": 0.0}),
		"burn": _empty_status_record({"slow": 0.0, "burn": 0.26}),
		"slow_burn": _empty_status_record({"slow": 0.36, "burn": 0.26}),
	}


func _empty_status_record(strengths: Dictionary) -> Dictionary:
	return {
		"strengths": strengths,
		"status_body_changed_vs_no_status": {},
		"tail_changed_vs_no_status": {},
		"afterimage_body_changed_active_vs_baseline": {},
		"baseline_tail_pixels": {},
		"boost_end_tail_pixels": {},
	}


func _audit_and_save_status_frame(frame_index: int, source: Image, neutral: Image, crops: Array) -> void:
	var trail: Image = crops[0]
	var status_indices := {"slow": [1, 4], "burn": [2, 5], "slow_burn": [3, 6]}
	var frame_key := "frame_%d" % frame_index
	for status_name in status_indices:
		var indices: Array = status_indices[status_name]
		var status_only: Image = crops[indices[0]]
		var active: Image = crops[indices[1]]
		var body_changed_vs_neutral := 0
		var tail_changed_vs_trail := 0
		var active_body_changed_vs_status := 0
		var baseline_tail_pixels := 0
		for y in range(40):
			for x in range(40):
				var is_body := source.get_pixel(x, y).a > 0.0
				if is_body:
					if _max_color_delta(status_only.get_pixel(x, y), neutral.get_pixel(x, y)) > CHANGE_TOLERANCE:
						body_changed_vs_neutral += 1
					if _max_color_delta(active.get_pixel(x, y), status_only.get_pixel(x, y)) > CHANGE_TOLERANCE:
						active_body_changed_vs_status += 1
				else:
					if _max_color_delta(active.get_pixel(x, y), trail.get_pixel(x, y)) > CHANGE_TOLERANCE:
						tail_changed_vs_trail += 1
					if status_only.get_pixel(x, y).a > CHANGE_TOLERANCE:
						baseline_tail_pixels += 1
		var record: Dictionary = status_audit[status_name]
		record["status_body_changed_vs_no_status"][frame_key] = body_changed_vs_neutral
		record["tail_changed_vs_no_status"][frame_key] = tail_changed_vs_trail
		record["afterimage_body_changed_active_vs_baseline"][frame_key] = active_body_changed_vs_status
		record["baseline_tail_pixels"][frame_key] = baseline_tail_pixels
		_expect(body_changed_vs_neutral > 0, "%s status was not visible on the body." % status_name)
		_expect(tail_changed_vs_trail == 0 and active_body_changed_vs_status == 0 and baseline_tail_pixels == 0, "%s status tinted the trail or afterimage changed the body." % status_name)
		_save_review_frame(active, "status_%s_active_frame_%d.png" % [status_name, frame_index])
		_save_review_frame(status_only, "status_%s_baseline_frame_%d.png" % [status_name, frame_index])
	var boost_end_tail := _count_transparent_trail(crops[7], source)
	for status_name in status_audit:
		status_audit[status_name]["boost_end_tail_pixels"][frame_key] = boost_end_tail
	_expect(boost_end_tail == 0, "Boost end retained tail pixels while slow/burn remained active.")


func _all_status_boost_end_tails_zero() -> bool:
	for status_name in status_audit:
		for value in status_audit[status_name]["boost_end_tail_pixels"].values():
			if int(value) != 0:
				return false
	return true


func _count_transparent_trail(rendered: Image, source: Image) -> int:
	var count := 0
	for y in range(40):
		for x in range(40):
			if source.get_pixel(x, y).a <= 0.0 and rendered.get_pixel(x, y).a > CHANGE_TOLERANCE:
				count += 1
	return count


func _capture_atlas_audit() -> void:
	for row_index in range(3):
		for frame_index in range(8):
			comparison_sprites[0].texture = atlas_frames[row_index][frame_index]
			comparison_sprites[1].texture = standalone_frames[row_index][frame_index]
			await _wait_for_render_frames(1)
			var image := atlas_comparison_viewport.get_texture().get_image()
			var atlas_crop := image.get_region(Rect2i(0, 0, 40, 40))
			var standalone_crop := image.get_region(Rect2i(50, 0, 40, 40))
			var changed := 0
			for y in range(40):
				for x in range(40):
					if _max_color_delta(atlas_crop.get_pixel(x, y), standalone_crop.get_pixel(x, y)) > CHANGE_TOLERANCE:
						changed += 1
			var key := "%s/frame_%d" % [["move", "boost", "death"][row_index], frame_index]
			atlas_differences[key] = changed
			_expect(changed == 0, "AtlasTexture and standalone rendering diverged: %s" % key)


func _save_review_frame(rendered: Image, file_name: String) -> void:
	var composed := Image.create(40, 40, false, Image.FORMAT_RGBA8)
	composed.fill(REVIEW_BACKGROUND)
	composed.blend_rect(rendered, Rect2i(0, 0, 40, 40), Vector2i.ZERO)
	var unique_rgb := {}
	for y in range(composed.get_height()):
		for x in range(composed.get_width()):
			var color := composed.get_pixel(x, y)
			_expect(color.a >= 1.0 - CHANGE_TOLERANCE, "Review PNG Alpha is not fully opaque.")
			unique_rgb[color.to_html(false)] = true
	maximum_review_unique_rgb = maxi(maximum_review_unique_rgb, unique_rgb.size())
	_expect(unique_rgb.size() <= 256, "Review frame exceeds the exact GIF palette budget: %s colors=%d" % [file_name, unique_rgb.size()])
	var scaled := composed.duplicate() as Image
	scaled.resize(REVIEW_SIZE.x, REVIEW_SIZE.y, Image.INTERPOLATE_NEAREST)
	var output_path := "%s/%s" % [RAW_OUTPUT_DIRECTORY, file_name]
	var output_absolute := ProjectSettings.globalize_path(output_path)
	_expect(scaled.save_png(output_absolute) == OK, "Could not save %s" % file_name)
	if FileAccess.file_exists(output_path):
		captures[file_name] = {"sha256": FileAccess.get_sha256(output_path), "size": [640, 640], "mode": "RGBA", "unique_rgb": unique_rgb.size()}


func _max_color_delta(a: Color, b: Color) -> float:
	return maxf(maxf(absf(a.r - b.r), absf(a.g - b.g)), maxf(absf(a.b - b.b), absf(a.a - b.a)))


func _max_rgb_delta(a: Color, b: Color) -> float:
	return maxf(maxf(absf(a.r - b.r), absf(a.g - b.g)), absf(a.b - b.b))


func _sha256_bytes(data: PackedByteArray) -> String:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(data)
	return context.finish().hex_encode()


func _wait_for_render_frames(count: int) -> void:
	for _index in range(count):
		await get_tree().process_frame
		await RenderingServer.frame_post_draw


func _directions_for_report() -> Array:
	var result := []
	for spec in DIRECTION_SPECS:
		var world: Vector2 = spec["world"]
		var local: Vector2 = spec["local"]
		result.append({"name": spec["name"], "world": [world.x, world.y], "flip_h": spec["flip_h"], "shader_local": [local.x, local.y]})
	return result


func _write_runtime_report() -> void:
	var source_rows := {"move": "m1", "boost": "s2", "death": "d1"}
	var report := {
		"schema_version": 1,
		"asset": "combat_robot_ninja_elite_afterimage",
		"stage": "godot_capture_complete",
		"failures": Array(failures),
		"review_algorithm": "production_original_rgb_three_offset_afterimage",
		"source": {
			"path": SOURCE_PATH,
			"sha256": FileAccess.get_sha256(SOURCE_PATH),
			"rgba_sha256": _sha256_bytes(source_image.get_data()),
			"size": [source_image.get_width(), source_image.get_height()],
			"rows": source_rows,
			"approved_row_paths": APPROVED_ROW_PATHS,
			"approved_row_file_sha256": EXPECTED_ROW_FILE_SHA,
		},
		"shader": {
			"path": STATUS_SHADER_PATH,
			"sha256": FileAccess.get_sha256(STATUS_SHADER_PATH),
			"used_directly": true,
			"in_memory_modified": false,
			"sample_rgb": "original texture RGB",
			"block_before_slow_burn": true,
			"instance_id": production_shader_instance_id,
			"rid": production_shader_rid,
		},
		"material": {
			"source_scene": ENEMY_SCENE_PATH,
			"resource_local_to_scene": shared_material.resource_local_to_scene,
			"shared_identity": true,
			"shared_material_count": 1,
			"shared_shader_count": 1,
			"created_material_count": 0,
			"duplicated_material_count": 0,
			"set_shader_parameter_call_count": 0,
			"material_uniforms_unchanged": material_uniforms_before == material_uniforms_after,
			"material_override_before": shared_material.get_shader_parameter(AFTERIMAGE_PIXELS_PARAMETER),
			"material_override_after": shared_material.get_shader_parameter(AFTERIMAGE_PIXELS_PARAMETER),
			"shader_declared_default": AFTERIMAGE_PIXELS,
			"effective_pixels": _resolved_afterimage_pixels(),
			"ninja_afterimage_pixels_before": _resolved_afterimage_pixels(),
			"ninja_afterimage_pixels_after": _resolved_afterimage_pixels(),
			"instance_parameter_isolation": true,
			"instance_id": production_material_instance_id,
			"rid": production_material_rid,
			"material_rids": [production_material_rid],
			"shader_rids": [production_shader_rid],
			"uniforms_before": material_uniforms_before,
			"uniforms_after": material_uniforms_after,
		},
		"sampling": {
			"strength": 1.0,
			"pixels": 4.0,
			"coefficients": [0.45, 0.9, 1.35],
			"offsets": [1.8, 3.6, 5.4],
			"alphas": [0.48, 0.34, 0.22],
			"maximum_overlap_alpha": 0.732304,
		},
		"directions": _directions_for_report(),
		"direction_audit": direction_audit,
		"status_audit": status_audit,
		"phase_preservation": phase_preservation,
		"death_cleanup": death_cleanup,
		"lifecycle": lifecycle_report,
		"atlas_audit": {
			"filter_clip": true,
			"frame_count": 24,
			"atlas_standalone_changed_pixels": atlas_differences,
		},
		"godot_real_render": true,
		"raw_frame_size": [640, 640],
		"raw_frame_background_rgb": [13, 19, 31],
		"raw_frame_alpha_fully_opaque": true,
		"maximum_raw_unique_rgb": maximum_review_unique_rgb,
		"captures": captures,
		"capture_builder": {
			"path": "res://dev_tools/combat_robot_ninja_elite_afterimage_preview.gd",
			"sha256": FileAccess.get_sha256("res://dev_tools/combat_robot_ninja_elite_afterimage_preview.gd"),
		},
		"runtime_paths_written": [],
		"production_shader_written": false,
		"production_material_written": false,
		"rendering_method": RenderingServer.get_current_rendering_method(),
		"rendering_driver": RenderingServer.get_current_rendering_driver_name(),
	}
	var report_file := FileAccess.open(ProjectSettings.globalize_path("%s/runtime_report.json" % RAW_OUTPUT_DIRECTORY), FileAccess.WRITE)
	_expect(report_file != null, "Could not open runtime report.")
	if report_file != null:
		report_file.store_string(JSON.stringify(report, "\t"))


func _expect(condition: bool, message: String) -> void:
	if condition:
		return
	failures.append(message)
	push_error(message)


func _finish() -> void:
	for viewport in [direction_viewport, status_viewport, transition_viewport, atlas_comparison_viewport]:
		viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	if failures.is_empty():
		print("COMBAT_ROBOT_NINJA_ELITE_AFTERIMAGE_PREVIEW_OK directions=6 frames=8 material=%d" % production_material_instance_id)
		get_tree().quit(0)
		return
	print("COMBAT_ROBOT_NINJA_ELITE_AFTERIMAGE_PREVIEW_FAILED count=%d" % failures.size())
	get_tree().quit(1)
