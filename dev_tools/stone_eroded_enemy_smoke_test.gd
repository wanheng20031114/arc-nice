extends SceneTree

const STONE_ERODED_NAME_PREFIX := "被石头侵蚀的"
const STONE_ERODED_TAG := "stone_eroded"
const REQUIRED_PHYSICAL_DEFENSE := 150
const MIN_VISIBLE_RGB_CHANGE_RATIO := 0.05
const MAX_VISIBLE_RGB_CHANGE_RATIO := 0.15
const LARGE_FRAME_MAX_VISIBLE_RGB_CHANGE_RATIO := 0.10
const SMALL_FRAME_VISIBLE_THRESHOLD := 512
const SMALL_FRAME_MIN_VISIBLE_RGB_CHANGE_RATIO := 0.075
const MAX_LOOPING_STONE_CENTER_DRIFT := 0.15
const MAX_NON_LOOPING_STONE_CENTER_DRIFT := 0.40
const MAX_SPIN_ATTACK_STONE_CENTER_DRIFT := 0.45
const MIN_STRONG_RGB_CHANGE_RATIO := 0.005
const MIN_STRONG_RGB_CHANNEL_DELTA := 24
const EXPECTED_TEXTURE_PAIR_COUNT := 18
const SHARED_NON_BODY_VFX_TEXTURE_BY_ENEMY := {
	"yuanshi_insect_bomber": "res://resources/texture/enemy/yuanshi_insect/爆炸特效.png",
	"yuanshi_insect_purple_bomber": (
		"res://resources/texture/enemy/yuanshi_insect/yuanshi_insect_purple_explosion.png"
	),
}

const ENEMY_IDS := [
	"capoo_ak47",
	"capoo_knight",
	"capoo_knight_elite",
	"capoo_mage",
	"capoo_rpg",
	"capoo_smg",
	"capoo_sniper",
	"capoo_swordsman",
	"yuanshi_insect_basic",
	"yuanshi_insect_bomber",
	"yuanshi_insect_fast",
	"yuanshi_insect_fire_ranged",
	"yuanshi_insect_green_shell",
	"yuanshi_insect_guardian",
	"yuanshi_insect_purple_bomber",
	"yuanshi_insect_shell",
	"slime",
	"slime_fire",
	"slime_frost",
	"slime_golden",
	"slime_green",
]

var failures: Array[String] = []
var checked_texture_pairs: Dictionary = {}
var texture_pair_pixels: Dictionary = {}


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_expect(ENEMY_IDS.size() == 21, "石蚀敌人契约必须恰好覆盖21种敌人。")
	for enemy_id in ENEMY_IDS:
		_test_enemy_contract(String(enemy_id))
	_expect(
		checked_texture_pairs.size() == EXPECTED_TEXTURE_PAIR_COUNT,
		"石蚀敌人动画必须恰好覆盖18对独立原版/石蚀版纹理（实际%d对）。"
		% checked_texture_pairs.size()
	)

	if failures.is_empty():
		print("STONE_ERODED_ENEMY_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_enemy_contract(enemy_id: String) -> void:
	var base_config_path := "res://resources/config/enemies/%s.tres" % enemy_id
	var eroded_config_path := (
		"res://resources/config/enemies/stone_eroded_%s.tres" % enemy_id
	)
	var base_frames_path := "res://resources/animation/%s.tres" % enemy_id
	var eroded_frames_path := (
		"res://resources/animation/stone_eroded_%s.tres" % enemy_id
	)

	var base_config := _load_enemy_config(base_config_path, enemy_id, "原版")
	var eroded_config := _load_enemy_config(eroded_config_path, enemy_id, "石蚀版")
	var base_frames := _load_sprite_frames(base_frames_path, enemy_id, "原版")
	var eroded_frames := _load_sprite_frames(eroded_frames_path, enemy_id, "石蚀版")
	if base_config == null or eroded_config == null:
		return

	_expect(
		eroded_config.display_name.begins_with(STONE_ERODED_NAME_PREFIX),
		"%s 显示名称必须精确以“%s”开头。"
		% [enemy_id, STONE_ERODED_NAME_PREFIX]
	)
	_expect(
		eroded_config.max_health == base_config.max_health * 2,
		"%s 石蚀版生命值必须为原版的2倍（期望%d，实际%d）。"
		% [enemy_id, base_config.max_health * 2, eroded_config.max_health]
	)
	_expect(
		eroded_config.physical_defense == REQUIRED_PHYSICAL_DEFENSE,
		"%s 石蚀版物理防御必须为%d（实际%d）。"
		% [enemy_id, REQUIRED_PHYSICAL_DEFENSE, eroded_config.physical_defense]
	)
	_expect(
		_has_preserved_categories(base_config.category_tags, eroded_config.category_tags),
		"%s 必须完整保留原类别标签，并且只额外增加一次%s标签。"
		% [enemy_id, STONE_ERODED_TAG]
	)

	_test_scene_contract(eroded_config, eroded_frames, eroded_frames_path, enemy_id)
	if base_frames != null and eroded_frames != null:
		_test_animation_contract(base_frames, eroded_frames, enemy_id)


func _load_enemy_config(path: String, enemy_id: String, edition: String) -> EnemyConfig:
	if not ResourceLoader.exists(path):
		_failures_append_once("%s %s敌人配置缺失：%s" % [enemy_id, edition, path])
		return null
	var config := load(path) as EnemyConfig
	_expect(config != null, "%s %s敌人配置无法加载：%s" % [enemy_id, edition, path])
	return config


func _load_sprite_frames(path: String, enemy_id: String, edition: String) -> SpriteFrames:
	if not ResourceLoader.exists(path):
		_failures_append_once("%s %s动画资源缺失：%s" % [enemy_id, edition, path])
		return null
	var frames := load(path) as SpriteFrames
	_expect(frames != null, "%s %s动画资源无法加载：%s" % [enemy_id, edition, path])
	return frames


func _has_preserved_categories(
	base_tags: PackedStringArray,
	eroded_tags: PackedStringArray
) -> bool:
	if eroded_tags.size() != base_tags.size() + 1:
		return false
	var stone_eroded_tag_count := 0
	for tag in eroded_tags:
		if tag == STONE_ERODED_TAG:
			stone_eroded_tag_count += 1
		elif not base_tags.has(tag):
			return false
	for tag in base_tags:
		if not eroded_tags.has(tag):
			return false
	return stone_eroded_tag_count == 1


func _test_scene_contract(
	config: EnemyConfig,
	expected_frames: SpriteFrames,
	expected_frames_path: String,
	enemy_id: String
) -> void:
	var enemy_scene := config.enemy_scene
	_expect(enemy_scene != null, "%s 石蚀版必须配置可用的enemy_scene。" % enemy_id)
	if enemy_scene == null:
		return
	var instance := enemy_scene.instantiate()
	_expect(instance != null, "%s 石蚀版enemy_scene必须能够实例化。" % enemy_id)
	if instance == null:
		return
	var sprite := instance.get_node_or_null("AnimatedSprite2D") as AnimatedSprite2D
	_expect(sprite != null, "%s 石蚀版场景必须包含AnimatedSprite2D。" % enemy_id)
	if sprite != null:
		var actual_frames_path := (
			sprite.sprite_frames.resource_path
			if sprite.sprite_frames != null
			else ""
		)
		_expect(
			sprite.sprite_frames != null
				and sprite.sprite_frames == expected_frames
				and actual_frames_path == expected_frames_path,
			"%s 场景AnimatedSprite2D必须使用%s。"
			% [enemy_id, expected_frames_path]
		)
	instance.free()


func _test_animation_contract(
	base_frames: SpriteFrames,
	eroded_frames: SpriteFrames,
	enemy_id: String
) -> void:
	var base_animation_names := _get_sorted_animation_names(base_frames)
	var eroded_animation_names := _get_sorted_animation_names(eroded_frames)
	_expect(
		eroded_animation_names == base_animation_names,
		"%s 石蚀版动画名称集合必须与原版完全一致。" % enemy_id
	)
	for animation_text in base_animation_names:
		var animation_name := StringName(animation_text)
		if not eroded_frames.has_animation(animation_name):
			continue
		var base_frame_count := base_frames.get_frame_count(animation_name)
		var eroded_frame_count := eroded_frames.get_frame_count(animation_name)
		_expect(
			eroded_frame_count == base_frame_count,
			"%s 的%s动画帧数必须与原版一致（期望%d，实际%d）。"
			% [enemy_id, animation_name, base_frame_count, eroded_frame_count]
		)
		_expect(
			is_equal_approx(
				eroded_frames.get_animation_speed(animation_name),
				base_frames.get_animation_speed(animation_name)
			),
			"%s 的%s动画FPS必须与原版一致。" % [enemy_id, animation_name]
		)
		_expect(
			eroded_frames.get_animation_loop(animation_name)
				== base_frames.get_animation_loop(animation_name),
			"%s 的%s动画循环属性必须与原版一致。" % [enemy_id, animation_name]
		)
		for frame_index in range(mini(base_frame_count, eroded_frame_count)):
			_test_frame_contract(
				base_frames.get_frame_texture(animation_name, frame_index),
				eroded_frames.get_frame_texture(animation_name, frame_index),
				enemy_id,
				animation_name,
				frame_index
			)
		_test_animation_temporal_contract(
			base_frames,
			eroded_frames,
			enemy_id,
			animation_name
		)


func _get_sorted_animation_names(frames: SpriteFrames) -> PackedStringArray:
	var names := PackedStringArray()
	for animation_name in frames.get_animation_names():
		names.append(String(animation_name))
	names.sort()
	return names


func _test_animation_temporal_contract(
	base_frames: SpriteFrames,
	eroded_frames: SpriteFrames,
	enemy_id: String,
	animation_name: StringName
) -> void:
	var frame_count := mini(
		base_frames.get_frame_count(animation_name),
		eroded_frames.get_frame_count(animation_name)
	)
	if frame_count < 2:
		return
	var samples: Array[Dictionary] = []
	for frame_index in range(frame_count):
		samples.append(
			_get_frame_stone_center(
				base_frames.get_frame_texture(animation_name, frame_index),
				eroded_frames.get_frame_texture(animation_name, frame_index)
			)
		)
	var is_looping := base_frames.get_animation_loop(animation_name)
	var comparison_count := frame_count if is_looping else frame_count - 1
	var maximum_drift := (
		MAX_LOOPING_STONE_CENTER_DRIFT
		if is_looping
		else (
			MAX_SPIN_ATTACK_STONE_CENTER_DRIFT
			if enemy_id == "capoo_swordsman" and animation_name == &"attack"
			else MAX_NON_LOOPING_STONE_CENTER_DRIFT
		)
	)
	for frame_index in range(comparison_count):
		var next_frame_index := (frame_index + 1) % frame_count
		var current_sample := samples[frame_index]
		var next_sample := samples[next_frame_index]
		# Shared explosion VFX and explicitly unchanged terminal frames have no
		# stone pixels, so they intentionally do not form a temporal pair.
		if not current_sample.get("valid", false) or not next_sample.get("valid", false):
			continue
		var current_center: Vector2 = current_sample["center"]
		var next_center: Vector2 = next_sample["center"]
		var drift := current_center.distance_to(next_center)
		_expect(
			drift <= maximum_drift,
			"%s/%s[%d→%d] 石蚀区域中心漂移必须不超过%.3f（实际%.3f）。"
			% [
				enemy_id,
				animation_name,
				frame_index,
				next_frame_index,
				maximum_drift,
				drift,
			]
		)


func _get_frame_stone_center(
	base_texture: Texture2D,
	eroded_texture: Texture2D
) -> Dictionary:
	var base_atlas_texture := base_texture as AtlasTexture
	var eroded_atlas_texture := eroded_texture as AtlasTexture
	if base_atlas_texture == null or eroded_atlas_texture == null:
		return {"valid": false}
	var pair_key := _get_texture_pair_key(
		base_atlas_texture.atlas,
		eroded_atlas_texture.atlas
	)
	if not texture_pair_pixels.has(pair_key):
		return {"valid": false}
	var pixel_data := texture_pair_pixels[pair_key] as Dictionary
	var image_size := pixel_data["size"] as Vector2i
	var base_bytes := pixel_data["base_bytes"] as PackedByteArray
	var eroded_bytes := pixel_data["eroded_bytes"] as PackedByteArray
	var atlas_region := base_atlas_texture.region
	var region_position := Vector2i(
		roundi(atlas_region.position.x),
		roundi(atlas_region.position.y)
	)
	var region_size := Vector2i(
		roundi(atlas_region.size.x),
		roundi(atlas_region.size.y)
	)
	var changed_count := 0
	var coordinate_sum := Vector2.ZERO
	var visible_min := Vector2i(region_size.x, region_size.y)
	var visible_max := Vector2i(-1, -1)
	for y in range(region_position.y, region_position.y + region_size.y):
		for x in range(region_position.x, region_position.x + region_size.x):
			if x < 0 or y < 0 or x >= image_size.x or y >= image_size.y:
				continue
			var byte_offset := (y * image_size.x + x) * 4
			if base_bytes[byte_offset + 3] == 0:
				continue
			var local_coordinate := Vector2i(x, y) - region_position
			visible_min.x = mini(visible_min.x, local_coordinate.x)
			visible_min.y = mini(visible_min.y, local_coordinate.y)
			visible_max.x = maxi(visible_max.x, local_coordinate.x)
			visible_max.y = maxi(visible_max.y, local_coordinate.y)
			var rgb_changed := (
				base_bytes[byte_offset] != eroded_bytes[byte_offset]
				or base_bytes[byte_offset + 1] != eroded_bytes[byte_offset + 1]
				or base_bytes[byte_offset + 2] != eroded_bytes[byte_offset + 2]
			)
			if not rgb_changed:
				continue
			changed_count += 1
			coordinate_sum += Vector2(
				float(local_coordinate.x) + 0.5,
				float(local_coordinate.y) + 0.5
			)
	if changed_count == 0 or visible_max.x < visible_min.x or visible_max.y < visible_min.y:
		return {"valid": false}
	var visible_size := Vector2(visible_max - visible_min + Vector2i.ONE)
	var center := coordinate_sum / float(changed_count) - Vector2(visible_min)
	return {
		"valid": true,
		"center": Vector2(center.x / visible_size.x, center.y / visible_size.y),
	}


func _test_frame_contract(
	base_texture: Texture2D,
	eroded_texture: Texture2D,
	enemy_id: String,
	animation_name: StringName,
	frame_index: int
) -> void:
	var label := "%s/%s[%d]" % [enemy_id, animation_name, frame_index]
	var base_atlas_texture := base_texture as AtlasTexture
	var eroded_atlas_texture := eroded_texture as AtlasTexture
	_expect(base_atlas_texture != null, "%s 原版帧必须使用AtlasTexture。" % label)
	_expect(eroded_atlas_texture != null, "%s 石蚀版帧必须使用AtlasTexture。" % label)
	if base_atlas_texture == null or eroded_atlas_texture == null:
		return
	_expect(
		eroded_atlas_texture.get_size() == base_atlas_texture.get_size(),
		"%s AtlasTexture逻辑尺寸必须与原版一致。" % label
	)
	_expect(
		eroded_atlas_texture.region == base_atlas_texture.region,
		"%s AtlasTexture区域必须与原版一致。" % label
	)
	_expect(
		eroded_atlas_texture.margin == base_atlas_texture.margin,
		"%s AtlasTexture边距必须与原版一致。" % label
	)
	var base_atlas := base_atlas_texture.atlas
	var eroded_atlas := eroded_atlas_texture.atlas
	_expect(base_atlas != null, "%s 原版图集纹理缺失。" % label)
	_expect(eroded_atlas != null, "%s 石蚀版图集纹理缺失。" % label)
	if base_atlas == null or eroded_atlas == null:
		return
	if base_atlas.resource_path == eroded_atlas.resource_path:
		_expect(
			_is_allowed_shared_non_body_vfx(
				enemy_id,
				animation_name,
				base_atlas.resource_path
			),
			"%s 只有明确登记的explode非主体VFX可以复用原版图集。" % label
		)
		_test_shared_vfx_bytes(base_atlas, eroded_atlas, label)
		return
	_expect(
		eroded_atlas.resource_path.begins_with(
			"res://resources/texture/enemy/stone_eroded/"
		),
		"%s 石蚀版帧必须引用stone_eroded运行时纹理。" % label
	)
	_test_texture_bytes_once(base_atlas, eroded_atlas, enemy_id)
	_test_frame_visual_contract(
		base_atlas_texture,
		eroded_atlas_texture,
		enemy_id,
		animation_name,
		frame_index,
		label
	)


func _is_allowed_shared_non_body_vfx(
	enemy_id: String,
	animation_name: StringName,
	texture_path: String
) -> bool:
	return (
		animation_name == &"explode"
		and SHARED_NON_BODY_VFX_TEXTURE_BY_ENEMY.get(enemy_id, "") == texture_path
	)


func _test_shared_vfx_bytes(
	base_texture: Texture2D,
	eroded_texture: Texture2D,
	label: String
) -> void:
	var base_image := base_texture.get_image()
	var eroded_image := eroded_texture.get_image()
	_expect(
		base_image != null and not base_image.is_empty(),
		"%s 原版共享VFX图像不可读。" % label
	)
	_expect(
		eroded_image != null and not eroded_image.is_empty(),
		"%s 石蚀版共享VFX图像不可读。" % label
	)
	if (
		base_image == null
		or eroded_image == null
		or base_image.is_empty()
		or eroded_image.is_empty()
	):
		return
	base_image.convert(Image.FORMAT_RGBA8)
	eroded_image.convert(Image.FORMAT_RGBA8)
	_expect(
		eroded_image.get_size() == base_image.get_size()
			and eroded_image.get_data() == base_image.get_data(),
		"%s 共享非主体VFX必须与原版保持完整RGBA字节一致。" % label
	)


func _test_frame_visual_contract(
	base_atlas_texture: AtlasTexture,
	eroded_atlas_texture: AtlasTexture,
	enemy_id: String,
	animation_name: StringName,
	frame_index: int,
	label: String
) -> void:
	var pair_key := _get_texture_pair_key(
		base_atlas_texture.atlas,
		eroded_atlas_texture.atlas
	)
	if not texture_pair_pixels.has(pair_key):
		return
	var pixel_data := texture_pair_pixels[pair_key] as Dictionary
	var image_size := pixel_data["size"] as Vector2i
	var base_bytes := pixel_data["base_bytes"] as PackedByteArray
	var eroded_bytes := pixel_data["eroded_bytes"] as PackedByteArray
	var atlas_region := base_atlas_texture.region
	var region_position := Vector2i(
		roundi(atlas_region.position.x),
		roundi(atlas_region.position.y)
	)
	var region_size := Vector2i(
		roundi(atlas_region.size.x),
		roundi(atlas_region.size.y)
	)
	_expect(
		Vector2(region_position) == atlas_region.position
			and Vector2(region_size) == atlas_region.size,
		"%s AtlasTexture region必须对齐整数像素。" % label
	)
	var region_is_valid := (
		region_position.x >= 0
		and region_position.y >= 0
		and region_size.x > 0
		and region_size.y > 0
		and region_position.x + region_size.x <= image_size.x
		and region_position.y + region_size.y <= image_size.y
	)
	_expect(region_is_valid, "%s AtlasTexture region必须完整位于图集内。" % label)
	if not region_is_valid:
		return

	var visible_pixel_count := 0
	var changed_visible_rgb_count := 0
	var strong_changed_visible_rgb_count := 0
	for y in range(region_position.y, region_position.y + region_size.y):
		for x in range(region_position.x, region_position.x + region_size.x):
			var byte_offset := (y * image_size.x + x) * 4
			if base_bytes[byte_offset + 3] == 0:
				continue
			visible_pixel_count += 1
			var red_delta := absi(
				int(base_bytes[byte_offset]) - int(eroded_bytes[byte_offset])
			)
			var green_delta := absi(
				int(base_bytes[byte_offset + 1])
				- int(eroded_bytes[byte_offset + 1])
			)
			var blue_delta := absi(
				int(base_bytes[byte_offset + 2])
				- int(eroded_bytes[byte_offset + 2])
			)
			if red_delta > 0 or green_delta > 0 or blue_delta > 0:
				changed_visible_rgb_count += 1
			if (
				red_delta >= MIN_STRONG_RGB_CHANNEL_DELTA
				or green_delta >= MIN_STRONG_RGB_CHANNEL_DELTA
				or blue_delta >= MIN_STRONG_RGB_CHANNEL_DELTA
			):
				strong_changed_visible_rgb_count += 1

	if _is_explicitly_unchanged_stone_frame(enemy_id, animation_name, frame_index):
		_expect(
			changed_visible_rgb_count == 0,
			"%s 显式终末帧RGB必须与原版完全一致（实际改动%d像素）。"
			% [label, changed_visible_rgb_count]
		)
		return

	_expect(visible_pixel_count > 0, "%s 主体帧必须包含可见像素。" % label)
	if visible_pixel_count == 0:
		return
	var minimum_changed_ratio := (
		SMALL_FRAME_MIN_VISIBLE_RGB_CHANGE_RATIO
		if visible_pixel_count < SMALL_FRAME_VISIBLE_THRESHOLD
		else MIN_VISIBLE_RGB_CHANGE_RATIO
	)
	var maximum_changed_ratio := (
		MAX_VISIBLE_RGB_CHANGE_RATIO
		if visible_pixel_count < SMALL_FRAME_VISIBLE_THRESHOLD
		else LARGE_FRAME_MAX_VISIBLE_RGB_CHANGE_RATIO
	)
	var minimum_changed_count := mini(
		floori(float(visible_pixel_count) * maximum_changed_ratio),
		maxi(1, ceili(float(visible_pixel_count) * minimum_changed_ratio))
	)
	var maximum_changed_count := maxi(
		minimum_changed_count,
		floori(float(visible_pixel_count) * maximum_changed_ratio)
	)
	var changed_ratio := float(changed_visible_rgb_count) / float(visible_pixel_count)
	_expect(
		changed_visible_rgb_count >= minimum_changed_count
			and changed_visible_rgb_count <= maximum_changed_count,
		"%s region内可见RGB差异必须在%d至%d像素之间（实际%.3f%%，%d/%d）。"
		% [
			label,
			minimum_changed_count,
			maximum_changed_count,
			changed_ratio * 100.0,
			changed_visible_rgb_count,
			visible_pixel_count,
		]
	)
	var minimum_strong_change_count := 1 if visible_pixel_count < 64 else 2
	var required_strong_change_count := maxi(
		minimum_strong_change_count,
		ceili(float(visible_pixel_count) * MIN_STRONG_RGB_CHANGE_RATIO)
	)
	_expect(
		strong_changed_visible_rgb_count >= required_strong_change_count,
		"%s region内至少需要%d个像素存在任一RGB通道差值不小于%d（实际%d）。"
		% [
			label,
			required_strong_change_count,
			MIN_STRONG_RGB_CHANNEL_DELTA,
			strong_changed_visible_rgb_count,
		]
	)


func _is_explicitly_unchanged_stone_frame(
	enemy_id: String,
	animation_name: StringName,
	frame_index: int
) -> bool:
	if animation_name != &"death":
		return false
	if enemy_id == "yuanshi_insect_fire_ranged":
		return frame_index in [1, 2]
	if enemy_id == "yuanshi_insect_guardian":
		return frame_index == 2
	if enemy_id in ["capoo_smg", "capoo_sniper"]:
		return frame_index == 3
	return false


func _get_texture_pair_key(
	base_texture: Texture2D,
	eroded_texture: Texture2D
) -> String:
	var pair_key := "%s|%s" % [base_texture.resource_path, eroded_texture.resource_path]
	if pair_key == "|":
		pair_key = "%d|%d" % [
			base_texture.get_instance_id(),
			eroded_texture.get_instance_id(),
		]
	return pair_key


func _test_texture_bytes_once(
	base_texture: Texture2D,
	eroded_texture: Texture2D,
	enemy_id: String
) -> void:
	var pair_key := _get_texture_pair_key(base_texture, eroded_texture)
	if checked_texture_pairs.has(pair_key):
		return
	checked_texture_pairs[pair_key] = true

	var base_image := base_texture.get_image()
	var eroded_image := eroded_texture.get_image()
	_expect(base_image != null and not base_image.is_empty(), "%s 原版图集图像不可读。" % enemy_id)
	_expect(eroded_image != null and not eroded_image.is_empty(), "%s 石蚀版图集图像不可读。" % enemy_id)
	if (
		base_image == null
		or eroded_image == null
		or base_image.is_empty()
		or eroded_image.is_empty()
	):
		return
	_expect(
		eroded_image.get_size() == base_image.get_size(),
		"%s 石蚀版与原版纹理尺寸必须完全一致。" % enemy_id
	)
	if eroded_image.get_size() != base_image.get_size():
		return

	base_image.convert(Image.FORMAT_RGBA8)
	eroded_image.convert(Image.FORMAT_RGBA8)
	var base_bytes := base_image.get_data()
	var eroded_bytes := eroded_image.get_data()
	_expect(
		eroded_bytes.size() == base_bytes.size(),
		"%s 石蚀版与原版RGBA字节长度必须一致。" % enemy_id
	)
	if eroded_bytes.size() != base_bytes.size():
		return
	texture_pair_pixels[pair_key] = {
		"size": base_image.get_size(),
		"base_bytes": base_bytes,
		"eroded_bytes": eroded_bytes,
	}

	var alpha_bytes_identical := true
	var visible_pixel_count := 0
	var changed_visible_rgb_count := 0
	var protected_emissive_pixel_count := 0
	var changed_protected_emissive_pixel_count := 0
	for byte_offset in range(0, base_bytes.size(), 4):
		var base_alpha: int = base_bytes[byte_offset + 3]
		if base_alpha != eroded_bytes[byte_offset + 3]:
			alpha_bytes_identical = false
		if base_alpha == 0:
			continue
		visible_pixel_count += 1
		var base_red: int = base_bytes[byte_offset]
		var base_green: int = base_bytes[byte_offset + 1]
		var base_blue: int = base_bytes[byte_offset + 2]
		var rgb_changed := (
			base_red != eroded_bytes[byte_offset]
			or base_green != eroded_bytes[byte_offset + 1]
			or base_blue != eroded_bytes[byte_offset + 2]
		)
		if rgb_changed:
			changed_visible_rgb_count += 1
		if _is_protected_emissive_pixel(enemy_id, base_red, base_green, base_blue):
			protected_emissive_pixel_count += 1
			if rgb_changed:
				changed_protected_emissive_pixel_count += 1
	_expect(
		alpha_bytes_identical,
		"%s 石蚀版必须逐字节保留原版Alpha通道。" % enemy_id
	)
	if _requires_emissive_identity_contract(enemy_id):
		_expect(
			protected_emissive_pixel_count > 0,
			"%s 原版图集必须包含受保护的发光身份像素。" % enemy_id
		)
		_expect(
			changed_protected_emissive_pixel_count == 0,
			"%s 的受保护发光像素必须保持RGB完全不变（实际改动%d/%d）。"
			% [
				enemy_id,
				changed_protected_emissive_pixel_count,
				protected_emissive_pixel_count,
			]
		)
	_expect(visible_pixel_count > 0, "%s 原版纹理必须包含可见像素。" % enemy_id)
	if visible_pixel_count == 0:
		return
	var changed_ratio := float(changed_visible_rgb_count) / float(visible_pixel_count)
	_expect(
		changed_ratio >= MIN_VISIBLE_RGB_CHANGE_RATIO
			and changed_ratio <= MAX_VISIBLE_RGB_CHANGE_RATIO,
		"%s 石蚀版可见RGB差异率必须在5%%至15%%之间（实际%.3f%%，%d/%d）。"
		% [
			enemy_id,
			changed_ratio * 100.0,
			changed_visible_rgb_count,
			visible_pixel_count,
		]
	)


func _requires_emissive_identity_contract(enemy_id: String) -> bool:
	return enemy_id in [
		"yuanshi_insect_fire_ranged",
		"yuanshi_insect_guardian",
	]


func _is_protected_emissive_pixel(
	enemy_id: String,
	base_red: int,
	base_green: int,
	base_blue: int
) -> bool:
	if enemy_id == "yuanshi_insect_fire_ranged":
		return base_red >= 188
	if enemy_id == "yuanshi_insect_guardian":
		return (
			base_blue >= 178
			and base_green >= 140
			and base_blue - base_red >= 25
		)
	return false


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures_append_once(message)


func _failures_append_once(message: String) -> void:
	if not failures.has(message):
		failures.append(message)
