extends Node

const VIEW_SIZE := Vector2i(1344, 720)
const SOURCE_TEXTURE_PATH := (
	"res://resources/texture/enemy/mechanical_life/combat_robot_ninja.png"
)
const SOURCE_TEXTURE_SIZE := Vector2i(320, 120)
const SOURCE_ANIMATION_ROW := 1
const STATUS_SHADER_PATH := "res://scene/entity_motion_status.gdshader"
const RAW_OUTPUT_DIRECTORY := (
	"res://dev_tools/output/combat_robot_ninja_afterimage_shader"
)
const FRAME_COUNT := 8
const FRAME_INTERVAL_SECONDS := 1.0 / 24.0
const SPRITE_SCALE := 4.0
const AFTERIMAGE_PIXELS := 4.0
const AFTERIMAGE_STRENGTH_PARAMETER := &"ninja_afterimage_strength"
const AFTERIMAGE_DIRECTION_PARAMETER := &"ninja_afterimage_direction"
const AFTERIMAGE_PIXELS_PARAMETER := &"ninja_afterimage_pixels"

const DIRECTION_SPECS := [
	{"label": "RIGHT", "direction": Vector2.RIGHT, "flip_h": false},
	{"label": "LEFT", "direction": Vector2.LEFT, "flip_h": true},
	{"label": "UP", "direction": Vector2.UP, "flip_h": false},
	{"label": "DOWN", "direction": Vector2.DOWN, "flip_h": false},
	{
		"label": "DOWN-RIGHT",
		"direction": Vector2(0.70710678, 0.70710678),
		"flip_h": false,
	},
	{
		"label": "UP-LEFT",
		"direction": Vector2(-0.70710678, -0.70710678),
		"flip_h": true,
	},
]
const VARIANT_SPECS := [
	{
		"id": "v1",
		"label": "FINAL  100%",
		"strength": 1.0,
	},
	{
		"id": "v2",
		"label": "FINAL   70%",
		"strength": 0.7,
	},
	{
		"id": "v3",
		"label": "FINAL   40%",
		"strength": 0.4,
	},
]
const COLUMN_CENTERS := [250.0, 445.0, 640.0, 835.0, 1030.0, 1225.0]
const ROW_CENTERS := [210.0, 400.0, 590.0]
const ROW_RECTS := [
	Rect2i(0, 120, VIEW_SIZE.x, 180),
	Rect2i(0, 310, VIEW_SIZE.x, 180),
	Rect2i(0, 500, VIEW_SIZE.x, 180),
]

@onready var preview_viewport: SubViewport = $PreviewViewport
@onready var atlas_comparison_viewport: SubViewport = $AtlasComparisonViewport

var preview_sprites: Array[Sprite2D] = []
var variant_sprites: Array = []
var variant_materials: Array[ShaderMaterial] = []
var source_strip_image: Image = null
var source_atlas_texture: Texture2D = null
var source_atlas_frames: Array[AtlasTexture] = []
var source_standalone_frames: Array[ImageTexture] = []
var source_frame_images: Array[Image] = []
var comparison_atlas_sprite: Sprite2D = null
var comparison_standalone_sprite: Sprite2D = null
var failures := PackedStringArray()
var shader_source_sha256 := ""


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var raw_output_absolute := ProjectSettings.globalize_path(RAW_OUTPUT_DIRECTORY)
	var directory_error := DirAccess.make_dir_recursive_absolute(raw_output_absolute)
	_expect(directory_error == OK, "Unable to create the raw preview output directory.")
	preview_viewport.size = VIEW_SIZE
	preview_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	atlas_comparison_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_build_board()
	await get_tree().process_frame
	await RenderingServer.frame_post_draw

	var aggregate_audit := _empty_shader_audit()
	var atlas_standalone_changed_pixels_by_frame := {}
	for frame_index in range(FRAME_COUNT):
		_set_preview_frame(frame_index)
		_set_all_strengths(0.0)
		await _wait_for_render_frames(2)
		var baseline := preview_viewport.get_texture().get_image()
		_expect(
			baseline != null and not baseline.is_empty(),
			"The active display driver did not return an inactive frame image."
		)
		if baseline == null or baseline.is_empty():
			_finish()
			return

		_set_all_strengths(1.0)
		await get_tree().create_timer(FRAME_INTERVAL_SECONDS).timeout
		await RenderingServer.frame_post_draw
		var active := preview_viewport.get_texture().get_image()
		_expect(
			active != null and not active.is_empty(),
			"The active display driver returned an empty active frame image."
		)
		if active == null or active.is_empty():
			_finish()
			return
		_merge_shader_audit(
			aggregate_audit,
			_measure_shader_changes(baseline, active, frame_index)
		)
		atlas_standalone_changed_pixels_by_frame[str(frame_index)] = (
			_measure_atlas_standalone_difference(frame_index)
		)
		_save_frame(active, frame_index)

	_validate_shared_material_contract()
	_write_runtime_report(
		aggregate_audit,
		atlas_standalone_changed_pixels_by_frame
	)
	_finish()


func _build_board() -> void:
	var background := ColorRect.new()
	background.position = Vector2.ZERO
	background.size = Vector2(VIEW_SIZE)
	background.color = Color("09111c")
	background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	preview_viewport.add_child(background)

	_add_label(
		"COMBAT ROBOT NINJA  /  PROJECT SHADER AFTERIMAGE REVIEW",
		Vector2(24.0, 12.0),
		Vector2(1296.0, 34.0),
		24,
		Color("e8eef6")
	)
	_add_label(
		"runtime 320x120 / S1 row  |  direct production shader  |  original-RGB 3-layer trail  |  filter_clip",
		Vector2(24.0, 48.0),
		Vector2(1296.0, 28.0),
		16,
		Color("8090a4")
	)

	for direction_index in range(DIRECTION_SPECS.size()):
		_add_centered_label(
			str(DIRECTION_SPECS[direction_index]["label"]),
			Vector2(COLUMN_CENTERS[direction_index] - 90.0, 82.0),
			Vector2(180.0, 30.0),
			16,
			Color("aebdcd")
		)

	var preview_shader := _build_preview_shader()
	_expect(preview_shader != null, "Failed to derive the review shader from the project shader.")
	if preview_shader == null:
		return
	_load_source_textures()
	if source_atlas_frames.size() != FRAME_COUNT:
		return
	_build_atlas_comparison_fixture(preview_shader)
	var shared_material := ShaderMaterial.new()
	shared_material.shader = preview_shader
	shared_material.set_shader_parameter(
		AFTERIMAGE_PIXELS_PARAMETER,
		AFTERIMAGE_PIXELS
	)
	for variant_index in range(VARIANT_SPECS.size()):
		var row_background := ColorRect.new()
		row_background.position = Vector2(12.0, float(ROW_RECTS[variant_index].position.y))
		row_background.size = Vector2(
			VIEW_SIZE.x - 24,
			ROW_RECTS[variant_index].size.y
		)
		row_background.color = (
			Color("101c2a") if variant_index % 2 == 0 else Color("0d1824")
		)
		row_background.mouse_filter = Control.MOUSE_FILTER_IGNORE
		preview_viewport.add_child(row_background)

		var variant_spec: Dictionary = VARIANT_SPECS[variant_index]
		_add_label(
			str(variant_spec["label"]),
			Vector2(28.0, ROW_CENTERS[variant_index] - 28.0),
			Vector2(170.0, 34.0),
			18,
			Color("dfe7ef")
		)
		_add_label(
			"original RGB",
			Vector2(28.0, ROW_CENTERS[variant_index] + 4.0),
			Vector2(170.0, 26.0),
			14,
			Color("68798c")
		)

		variant_materials.append(shared_material)
		var row_sprites: Array[Sprite2D] = []
		for direction_index in range(DIRECTION_SPECS.size()):
			var direction_spec: Dictionary = DIRECTION_SPECS[direction_index]
			var sprite := Sprite2D.new()
			sprite.name = "%s_%s" % [
				str(variant_spec["id"]),
				str(direction_spec["label"]).to_lower().replace("-", "_"),
			]
			sprite.texture = source_atlas_frames[0]
			sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
			sprite.position = Vector2(
				COLUMN_CENTERS[direction_index],
				ROW_CENTERS[variant_index]
			)
			sprite.scale = Vector2.ONE * SPRITE_SCALE
			sprite.flip_h = bool(direction_spec["flip_h"])
			sprite.material = shared_material
			preview_viewport.add_child(sprite)
			sprite.set_instance_shader_parameter(
				AFTERIMAGE_STRENGTH_PARAMETER,
				0.0
			)
			var local_shader_direction := _to_sprite_local_direction(
				direction_spec["direction"],
				sprite.flip_h
			)
			sprite.set_instance_shader_parameter(
				AFTERIMAGE_DIRECTION_PARAMETER,
				local_shader_direction
			)
			preview_sprites.append(sprite)
			row_sprites.append(sprite)
		variant_sprites.append(row_sprites)


func _build_preview_shader() -> Shader:
	var source := FileAccess.get_file_as_string(STATUS_SHADER_PATH)
	_expect(not source.is_empty(), "The project motion-status shader source is empty.")
	if source.is_empty():
		return null
	shader_source_sha256 = source.sha256_text()
	_expect(
		source.contains("instance uniform float ninja_afterimage_strength")
		and source.contains("instance uniform vec2 ninja_afterimage_direction")
		and source.contains("// Ninja afterimages preserve the source body"),
		"The production shader no longer exposes the reviewed ninja contract."
	)
	return load(STATUS_SHADER_PATH) as Shader


func _load_source_textures() -> void:
	var source_absolute := ProjectSettings.globalize_path(SOURCE_TEXTURE_PATH)
	source_strip_image = Image.load_from_file(source_absolute)
	_expect(
		source_strip_image != null and not source_strip_image.is_empty(),
		"The final ninja runtime texture could not be loaded."
	)
	if source_strip_image == null or source_strip_image.is_empty():
		return
	_expect(
		source_strip_image.get_size() == SOURCE_TEXTURE_SIZE,
		"The final ninja runtime texture must remain 320x120."
	)
	if source_strip_image.get_size() != SOURCE_TEXTURE_SIZE:
		return
	source_atlas_texture = load(SOURCE_TEXTURE_PATH) as Texture2D
	_expect(
		source_atlas_texture != null
		and source_atlas_texture.get_size() == Vector2(SOURCE_TEXTURE_SIZE),
		"The imported runtime texture is unavailable or has the wrong size."
	)
	if source_atlas_texture == null:
		return
	source_atlas_frames.clear()
	source_standalone_frames.clear()
	source_frame_images.clear()
	for frame_index in range(FRAME_COUNT):
		var atlas_frame := AtlasTexture.new()
		atlas_frame.atlas = source_atlas_texture
		atlas_frame.region = Rect2(
			float(frame_index * 40),
			float(SOURCE_ANIMATION_ROW * 40),
			40.0,
			40.0
		)
		atlas_frame.filter_clip = true
		source_atlas_frames.append(atlas_frame)
		var standalone_image := source_strip_image.get_region(
			Rect2i(frame_index * 40, SOURCE_ANIMATION_ROW * 40, 40, 40)
		)
		source_frame_images.append(standalone_image)
		source_standalone_frames.append(
			ImageTexture.create_from_image(standalone_image)
		)


func _build_atlas_comparison_fixture(preview_shader: Shader) -> void:
	var comparison_material := ShaderMaterial.new()
	comparison_material.shader = preview_shader
	comparison_material.set_shader_parameter(
		AFTERIMAGE_PIXELS_PARAMETER,
		AFTERIMAGE_PIXELS
	)
	comparison_atlas_sprite = Sprite2D.new()
	comparison_atlas_sprite.name = "AtlasFrame"
	comparison_atlas_sprite.texture = source_atlas_frames[0]
	comparison_atlas_sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	comparison_atlas_sprite.position = Vector2(90.0, 90.0)
	comparison_atlas_sprite.scale = Vector2.ONE * SPRITE_SCALE
	comparison_atlas_sprite.material = comparison_material
	atlas_comparison_viewport.add_child(comparison_atlas_sprite)
	comparison_standalone_sprite = Sprite2D.new()
	comparison_standalone_sprite.name = "StandaloneFrame"
	comparison_standalone_sprite.texture = source_standalone_frames[0]
	comparison_standalone_sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	comparison_standalone_sprite.position = Vector2(270.0, 90.0)
	comparison_standalone_sprite.scale = Vector2.ONE * SPRITE_SCALE
	comparison_standalone_sprite.material = comparison_material
	atlas_comparison_viewport.add_child(comparison_standalone_sprite)
	for sprite in [comparison_atlas_sprite, comparison_standalone_sprite]:
		sprite.set_instance_shader_parameter(AFTERIMAGE_STRENGTH_PARAMETER, 1.0)
		sprite.set_instance_shader_parameter(
			AFTERIMAGE_DIRECTION_PARAMETER,
			Vector2.RIGHT
		)


func _set_preview_frame(frame_index: int) -> void:
	var safe_frame := clampi(frame_index, 0, FRAME_COUNT - 1)
	for sprite in preview_sprites:
		sprite.texture = source_atlas_frames[safe_frame]
	comparison_atlas_sprite.texture = source_atlas_frames[safe_frame]
	comparison_standalone_sprite.texture = source_standalone_frames[safe_frame]


func _set_all_strengths(strength_scale: float) -> void:
	for variant_index in range(variant_sprites.size()):
		var authored_strength := float(VARIANT_SPECS[variant_index]["strength"])
		for sprite: Sprite2D in variant_sprites[variant_index]:
			sprite.set_instance_shader_parameter(
				AFTERIMAGE_STRENGTH_PARAMETER,
				clampf(authored_strength * strength_scale, 0.0, 1.0)
			)


func _wait_for_render_frames(count: int) -> void:
	for _frame_index in range(count):
		await get_tree().process_frame
		await RenderingServer.frame_post_draw


func _empty_shader_audit() -> Dictionary:
	return {
		"changed_pixels_by_sprite": {},
		"body_changed_pixels_by_sprite": {},
		"trail_only_changed_pixels_by_sprite": {},
		"trail_body_intersection_pixels_by_sprite": {},
		"trail_centroid_offset_by_sprite": {},
		"trail_world_direction_dot_by_sprite": {},
		"opposite_direction_projection_by_sprite": {},
		"body_rgba_tolerance": 1.0 / 255.0,
	}


func _merge_shader_audit(target: Dictionary, frame_audit: Dictionary) -> void:
	for dictionary_key in [
		"changed_pixels_by_sprite",
		"body_changed_pixels_by_sprite",
		"trail_only_changed_pixels_by_sprite",
		"trail_body_intersection_pixels_by_sprite",
		"trail_centroid_offset_by_sprite",
		"trail_world_direction_dot_by_sprite",
		"opposite_direction_projection_by_sprite",
	]:
		(target[dictionary_key] as Dictionary).merge(
			frame_audit[dictionary_key],
			true
		)


func _measure_shader_changes(
	baseline: Image,
	active: Image,
	frame_index: int
) -> Dictionary:
	var changed_by_sprite := {}
	var body_changed_by_sprite := {}
	var trail_only_changed_by_sprite := {}
	var trail_body_intersection_by_sprite := {}
	var trail_centroid_offset_by_sprite := {}
	var trail_world_direction_dot_by_sprite := {}
	var opposite_projection_by_sprite := {}
	var body_rgba_tolerance := 1.0 / 255.0
	for variant_index in range(VARIANT_SPECS.size()):
		for direction_index in range(DIRECTION_SPECS.size()):
			var center := Vector2i(
				roundi(COLUMN_CENTERS[direction_index]),
				roundi(ROW_CENTERS[variant_index])
			)
			var sample_rect := Rect2i(center - Vector2i(92, 92), Vector2i(184, 184))
			var changed_pixels := 0
			var body_changed_pixels := 0
			var trail_only_changed_pixels := 0
			var trail_body_intersection_pixels := 0
			var trail_position_sum := Vector2.ZERO
			var body_position_sum := Vector2.ZERO
			var body_pixel_count := 0
			var direction_spec: Dictionary = DIRECTION_SPECS[direction_index]
			var flip_h := bool(direction_spec["flip_h"])
			for y in range(sample_rect.position.y, sample_rect.end.y):
				for x in range(sample_rect.position.x, sample_rect.end.x):
					var before := baseline.get_pixel(x, y)
					var after := active.get_pixel(x, y)
					var max_channel_delta := maxf(
						maxf(absf(after.r - before.r), absf(after.g - before.g)),
						maxf(absf(after.b - before.b), absf(after.a - before.a))
					)
					var is_body_pixel := _is_body_screen_pixel(
						Vector2i(x, y),
						center,
						flip_h,
						frame_index
					)
					if is_body_pixel:
						body_pixel_count += 1
						body_position_sum += Vector2(x, y)
					if is_body_pixel and max_channel_delta > body_rgba_tolerance:
						body_changed_pixels += 1
					if max_channel_delta >= 0.02:
						changed_pixels += 1
						if is_body_pixel:
							trail_body_intersection_pixels += 1
						else:
							trail_only_changed_pixels += 1
							trail_position_sum += Vector2(x, y)
			var key := "%s/%s/frame_%d" % [
				str(VARIANT_SPECS[variant_index]["id"]),
				str(direction_spec["label"]),
				frame_index,
			]
			changed_by_sprite[key] = changed_pixels
			body_changed_by_sprite[key] = body_changed_pixels
			trail_only_changed_by_sprite[key] = trail_only_changed_pixels
			trail_body_intersection_by_sprite[key] = trail_body_intersection_pixels
			_expect(
				body_changed_pixels == 0,
				"Active afterimages changed original body RGBA for %s." % key
			)
			_expect(
				trail_body_intersection_pixels == 0,
				"Trail fragments intersected original body pixels for %s." % key
			)
			_expect(
				trail_only_changed_pixels >= 48,
				"Project shader produced too little visible afterimage change for %s."
				% key
			)
			if trail_only_changed_pixels > 0 and body_pixel_count > 0:
				var centroid := trail_position_sum / float(trail_only_changed_pixels)
				var body_centroid := body_position_sum / float(body_pixel_count)
				var centroid_offset := centroid - body_centroid
				var world_direction: Vector2 = direction_spec["direction"]
				var world_direction_dot := centroid_offset.dot(world_direction.normalized())
				var opposite_projection := -world_direction_dot
				trail_centroid_offset_by_sprite[key] = [
					centroid_offset.x,
					centroid_offset.y,
				]
				trail_world_direction_dot_by_sprite[key] = world_direction_dot
				opposite_projection_by_sprite[key] = opposite_projection
				_expect(
					world_direction_dot < -0.5,
					"Afterimage centroid is not behind world motion for %s." % key
				)
	return {
		"changed_pixels_by_sprite": changed_by_sprite,
		"body_changed_pixels_by_sprite": body_changed_by_sprite,
		"trail_only_changed_pixels_by_sprite": trail_only_changed_by_sprite,
		"trail_body_intersection_pixels_by_sprite": trail_body_intersection_by_sprite,
		"trail_centroid_offset_by_sprite": trail_centroid_offset_by_sprite,
		"trail_world_direction_dot_by_sprite": trail_world_direction_dot_by_sprite,
		"opposite_direction_projection_by_sprite": opposite_projection_by_sprite,
		"body_rgba_tolerance": body_rgba_tolerance,
	}


func _measure_atlas_standalone_difference(frame_index: int) -> int:
	var comparison_image := atlas_comparison_viewport.get_texture().get_image()
	_expect(
		comparison_image != null and not comparison_image.is_empty(),
		"Atlas/standalone comparison viewport returned no image."
	)
	if comparison_image == null or comparison_image.is_empty():
		return -1
	var atlas_region := comparison_image.get_region(Rect2i(10, 10, 160, 160))
	var standalone_region := comparison_image.get_region(Rect2i(190, 10, 160, 160))
	var changed_pixels := 0
	var tolerance := 1.0 / 255.0
	for y in range(160):
		for x in range(160):
			var atlas_color := atlas_region.get_pixel(x, y)
			var standalone_color := standalone_region.get_pixel(x, y)
			var max_channel_delta := maxf(
				maxf(
					absf(atlas_color.r - standalone_color.r),
					absf(atlas_color.g - standalone_color.g)
				),
				maxf(
					absf(atlas_color.b - standalone_color.b),
					absf(atlas_color.a - standalone_color.a)
				)
			)
			if max_channel_delta > tolerance:
				changed_pixels += 1
	_expect(
		changed_pixels == 0,
		"AtlasTexture and standalone 40x40 rendering diverged on frame %d."
		% frame_index
	)
	return changed_pixels


func _validate_shared_material_contract() -> void:
	_expect(
		variant_materials.size() == VARIANT_SPECS.size()
		and variant_materials[0] == variant_materials[1]
		and variant_materials[1] == variant_materials[2],
		"All production-strength rows must share one ShaderMaterial."
	)
	for variant_index in range(variant_sprites.size()):
		var expected_material: ShaderMaterial = variant_materials[variant_index]
		var row_sprites: Array = variant_sprites[variant_index]
		for direction_index in range(row_sprites.size()):
			var sprite: Sprite2D = row_sprites[direction_index]
			_expect(
				sprite.material == expected_material,
				"All direction fixtures in one color candidate must share one material."
			)
			var actual_direction: Vector2 = sprite.get_instance_shader_parameter(
				AFTERIMAGE_DIRECTION_PARAMETER
			)
			var direction_spec: Dictionary = DIRECTION_SPECS[direction_index]
			var expected_direction := _to_sprite_local_direction(
				direction_spec["direction"],
				sprite.flip_h
			)
			_expect(
				actual_direction.is_equal_approx(expected_direction.normalized()),
				"Per-instance afterimage direction did not round-trip independently."
			)
			var actual_strength := float(
				sprite.get_instance_shader_parameter(AFTERIMAGE_STRENGTH_PARAMETER)
			)
			var expected_strength := float(VARIANT_SPECS[variant_index]["strength"])
			_expect(
				is_equal_approx(actual_strength, expected_strength),
				"Per-instance afterimage strength did not remain active."
			)
	_expect(
		variant_materials[0].shader == variant_materials[1].shader
		and variant_materials[1].shader == variant_materials[2].shader,
		"All color candidates must execute the same derived project shader."
	)
	for sprite in preview_sprites:
		_expect(
			sprite.texture == source_atlas_frames[FRAME_COUNT - 1],
			"All review fixtures must share the same current AtlasTexture frame."
		)
	for atlas_frame in source_atlas_frames:
		_expect(
			atlas_frame.atlas == source_atlas_texture and atlas_frame.filter_clip,
			"Every 40x40 S1 AtlasTexture must share the strip and enable filter_clip."
		)


func _save_frame(image: Image, frame_index: int) -> void:
	_expect(image != null and not image.is_empty(), "Captured an empty preview frame.")
	if image == null or image.is_empty():
		return
	var board_path := "%s/board_%02d.png" % [RAW_OUTPUT_DIRECTORY, frame_index]
	_expect(
		image.save_png(ProjectSettings.globalize_path(board_path)) == OK,
		"Could not save raw board frame %d." % frame_index
	)
	for variant_index in range(VARIANT_SPECS.size()):
		var row_image := image.get_region(ROW_RECTS[variant_index])
		var row_path := "%s/%s_%02d.png" % [
			RAW_OUTPUT_DIRECTORY,
			str(VARIANT_SPECS[variant_index]["id"]),
			frame_index,
		]
		_expect(
			row_image.save_png(ProjectSettings.globalize_path(row_path)) == OK,
			"Could not save raw row frame %s/%d."
			% [VARIANT_SPECS[variant_index]["id"], frame_index]
		)


func _write_runtime_report(
	shader_audit: Dictionary,
	atlas_standalone_changed_pixels_by_frame: Dictionary
) -> void:
	var atlas_filter_clip := true
	var atlas_regions := []
	for frame in source_atlas_frames:
		atlas_filter_clip = atlas_filter_clip and frame.filter_clip
		atlas_regions.append([
			frame.region.position.x,
			frame.region.position.y,
			frame.region.size.x,
			frame.region.size.y,
		])
	var direction_contract := {}
	for variant_index in range(variant_sprites.size()):
		var row_sprites: Array = variant_sprites[variant_index]
		for direction_index in range(row_sprites.size()):
			var sprite: Sprite2D = row_sprites[direction_index]
			var direction_spec: Dictionary = DIRECTION_SPECS[direction_index]
			var world_direction: Vector2 = direction_spec["direction"]
			var local_direction := _to_sprite_local_direction(
				world_direction,
				sprite.flip_h
			)
			var key := "%s/%s" % [
				str(VARIANT_SPECS[variant_index]["id"]),
				str(direction_spec["label"]),
			]
			direction_contract[key] = {
				"flip_h": sprite.flip_h,
				"world": [world_direction.x, world_direction.y],
				"shader_local": [local_direction.x, local_direction.y],
			}
	var report := {
		"status_shader_path": STATUS_SHADER_PATH,
		"status_shader_sha256": shader_source_sha256,
		"production_shader_used_directly": true,
		"runtime_shader_in_memory_modified": false,
		"review_algorithm": "production_original_rgb_three_offset_afterimage",
		"body_source_over_foreground": true,
		"trail_requires_source_transparency": true,
		"sample_rgb": "original texture RGB",
		"ninja_block_excludes": ["scan", "leading_edge", "body_tint"],
		"production_instance_uniforms": [
			str(AFTERIMAGE_STRENGTH_PARAMETER),
			str(AFTERIMAGE_DIRECTION_PARAMETER),
		],
		"variant_strengths": VARIANT_SPECS.map(
			func(spec: Dictionary): return spec["strength"]
		),
		"source_texture": SOURCE_TEXTURE_PATH,
		"source_texture_class": source_atlas_texture.get_class(),
		"source_texture_loaded_via_resource_loader": true,
		"source_size": [SOURCE_TEXTURE_SIZE.x, SOURCE_TEXTURE_SIZE.y],
		"source_animation": "boost_s1",
		"source_animation_row": SOURCE_ANIMATION_ROW,
		"atlas_frame_count": source_atlas_frames.size(),
		"atlas_frame_size": [40, 40],
		"atlas_filter_clip": atlas_filter_clip,
		"atlas_regions": atlas_regions,
		"atlas_standalone_rgba_tolerance": 1.0 / 255.0,
		"atlas_standalone_changed_pixels_by_frame": (
			atlas_standalone_changed_pixels_by_frame
		),
		"sprite_scale": SPRITE_SCALE,
		"afterimage_pixels": AFTERIMAGE_PIXELS,
		"afterimage_sample_offsets": [0.45, 0.9, 1.35],
		"afterimage_sample_alpha_near_middle_far": [0.48, 0.34, 0.22],
		"max_source_pixel_offset": AFTERIMAGE_PIXELS * 1.35,
		"transparent_margin_contract": 6,
		"shared_shader_count": 1,
		"shared_material_count": 1,
		"instances_per_shared_material": (
			DIRECTION_SPECS.size() * VARIANT_SPECS.size()
		),
		"directions": DIRECTION_SPECS.map(func(spec: Dictionary): return spec["label"]),
		"world_to_shader_local_direction": direction_contract,
		"body_rgba_tolerance": shader_audit["body_rgba_tolerance"],
		"changed_pixels_by_sprite": shader_audit["changed_pixels_by_sprite"],
		"body_changed_pixels_by_sprite": shader_audit["body_changed_pixels_by_sprite"],
		"trail_only_changed_pixels_by_sprite": shader_audit["trail_only_changed_pixels_by_sprite"],
		"trail_body_intersection_pixels_by_sprite": shader_audit["trail_body_intersection_pixels_by_sprite"],
		"trail_centroid_offset_by_sprite": shader_audit["trail_centroid_offset_by_sprite"],
		"trail_world_direction_dot_by_sprite": shader_audit["trail_world_direction_dot_by_sprite"],
		"opposite_direction_projection_by_sprite": shader_audit["opposite_direction_projection_by_sprite"],
		"rendering_method": RenderingServer.get_current_rendering_method(),
		"rendering_driver": RenderingServer.get_current_rendering_driver_name(),
		"failures": Array(failures),
	}
	var report_path := "%s/runtime_report.json" % RAW_OUTPUT_DIRECTORY
	var report_file := FileAccess.open(
		ProjectSettings.globalize_path(report_path),
		FileAccess.WRITE
	)
	_expect(report_file != null, "Could not open the raw runtime report for writing.")
	if report_file != null:
		report_file.store_string(JSON.stringify(report, "\t"))


func _to_sprite_local_direction(world_direction: Vector2, flip_h: bool) -> Vector2:
	var local_direction := world_direction.normalized()
	if flip_h:
		local_direction.x *= -1.0
	return local_direction


func _is_body_screen_pixel(
	screen_pixel: Vector2i,
	sprite_center: Vector2i,
	flip_h: bool,
	frame_index: int
) -> bool:
	var scaled_size := Vector2i(40, 40) * int(SPRITE_SCALE)
	var sprite_top_left := sprite_center - scaled_size / 2
	var local_screen := screen_pixel - sprite_top_left
	if (
		local_screen.x < 0
		or local_screen.y < 0
		or local_screen.x >= scaled_size.x
		or local_screen.y >= scaled_size.y
	):
		return false
	var source_x := floori(float(local_screen.x) / SPRITE_SCALE)
	var source_y := floori(float(local_screen.y) / SPRITE_SCALE)
	if flip_h:
		source_x = 39 - source_x
	var safe_frame := clampi(frame_index, 0, source_frame_images.size() - 1)
	var source_image := source_frame_images[safe_frame]
	return source_image.get_pixel(source_x, source_y).a > 0.0


func _add_label(
	text: String,
	position: Vector2,
	size: Vector2,
	font_size: int,
	color: Color
) -> void:
	var label := Label.new()
	label.text = text
	label.position = position
	label.size = size
	label.add_theme_font_size_override(&"font_size", font_size)
	label.add_theme_color_override(&"font_color", color)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	preview_viewport.add_child(label)


func _add_centered_label(
	text: String,
	position: Vector2,
	size: Vector2,
	font_size: int,
	color: Color
) -> void:
	var label := Label.new()
	label.text = text
	label.position = position
	label.size = size
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override(&"font_size", font_size)
	label.add_theme_color_override(&"font_color", color)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	preview_viewport.add_child(label)


func _expect(condition: bool, message: String) -> void:
	if condition:
		return
	failures.append(message)
	push_error(message)


func _finish() -> void:
	preview_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	if failures.is_empty():
		print(
			"COMBAT_ROBOT_NINJA_AFTERIMAGE_SHADER_PREVIEW_OK "
			+ "frames=%d sprites=%d shader=%s" % [
				FRAME_COUNT,
				preview_sprites.size(),
				shader_source_sha256,
			]
		)
		get_tree().quit(0)
		return
	print(
		"COMBAT_ROBOT_NINJA_AFTERIMAGE_SHADER_PREVIEW_FAILED count=%d"
		% failures.size()
	)
	get_tree().quit(1)
