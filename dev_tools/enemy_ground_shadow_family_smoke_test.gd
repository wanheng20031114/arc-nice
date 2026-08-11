extends SceneTree

const CONFIG_DIRECTORY := "res://resources/config/enemies"
const EXPECTED_CONFIG_COUNT := 63
const EXPECTED_STONE_ERODED_CONFIG_COUNT := 21
const EXPECTED_ELITE_CONFIG_COUNT := 11
const SHARED_SHADOW_TEXTURE := preload(
	"res://resources/texture/enemy/enemy_ground_shadow.tres"
)
const BASE_ENEMY_SCENE := preload("res://scene/enemy/enemy.tscn")
const LIGHTWEIGHT_ENEMY_SCENE := preload("res://scene/enemy/slime/slime_basic.tscn")
const SUICIDE_DRONE_SCENES: Array[PackedScene] = [
	preload(
		"res://scene/enemy/mechanical_life/combat_robot_suicide_drone.tscn"
	),
	preload(
		"res://scene/enemy/mechanical_life/combat_robot_suicide_drone_elite.tscn"
	),
]
const SUICIDE_DRONE_LABELS := ["普通自杀无人机", "精英自杀无人机"]
const NORMAL_ANIMATION_FALLBACKS: Array[StringName] = [
	&"move",
	&"walk",
	&"run",
	&"idle",
]
const ALPHA_THRESHOLD := 1.0 / 255.0
const BASELINE_TOLERANCE := 0.51
const MIN_EFFECTIVE_WIDTH := 8.0
const MAX_EFFECTIVE_WIDTH := 160.0
const MIN_EFFECTIVE_HEIGHT := 1.5
const MAX_EFFECTIVE_HEIGHT := 24.0
const MIN_FLAT_ASPECT_RATIO := 4.0
const STRESS_INSTANCE_COUNT := 1000

var failures: Array[String] = []


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	_test_shared_texture_shape()
	_test_base_scene_shadow_is_opt_in()
	var configs := _load_formal_enemy_configs()
	var audit := _audit_unique_enemy_scenes(configs)
	_test_variant_coverage(configs, audit)
	_test_suicide_drones_are_airborne_exceptions()
	_test_thousand_lightweight_instances()
	_finish(configs.size(), int(audit.get("scene_count", 0)))


func _test_shared_texture_shape() -> void:
	var texture := SHARED_SHADOW_TEXTURE as GradientTexture2D
	_expect(texture != null, "共享接地阴影必须继续使用原生 GradientTexture2D。")
	if texture == null:
		return
	_expect(
		texture.resource_path
		== "res://resources/texture/enemy/enemy_ground_shadow.tres",
		"全敌人阴影必须共享稳定的正式资源路径。"
	)
	_expect(
		not texture.resource_local_to_scene,
		"共享接地阴影纹理不得设为 resource_local_to_scene。"
	)
	_expect(
		texture.width > 0
		and texture.height > 0
		and float(texture.width) / float(texture.height) >= MIN_FLAT_ASPECT_RATIO,
		"共享接地阴影纹理必须是明显扁平的横向椭圆。"
	)
	_expect(
		texture.fill == GradientTexture2D.FILL_RADIAL,
		"共享接地阴影必须使用原生径向渐变。"
	)
	_expect(
		texture.fill_from.is_equal_approx(Vector2(0.5, 0.5))
		and texture.fill_to.is_equal_approx(Vector2(1.0, 0.5)),
		"共享接地阴影必须以纹理中心为椭圆中点并横向展开。"
	)
	var gradient := texture.gradient
	_expect(gradient != null, "共享接地阴影必须绑定 Gradient。")
	if gradient == null:
		return
	_expect(
		gradient.colors.size() >= 2
		and gradient.offsets.size() == gradient.colors.size(),
		"共享接地阴影必须提供完整渐变停点。"
	)
	if gradient.colors.size() < 2:
		return
	var previous_alpha := INF
	for color in gradient.colors:
		_expect(
			color.a <= previous_alpha + 0.0001,
			"接地阴影透明度必须从中心向边缘单调衰减。"
		)
		previous_alpha = color.a
	_expect(
		gradient.colors[0].a >= 0.5
		and is_zero_approx(gradient.colors[gradient.colors.size() - 1].a),
		"接地阴影必须保留清晰中心，并在椭圆边缘平滑归零。"
	)


func _test_base_scene_shadow_is_opt_in() -> void:
	var enemy := BASE_ENEMY_SCENE.instantiate()
	var shadows := _collect_named_nodes(enemy, &"GroundShadow")
	_expect(shadows.size() == 1, "Enemy 基类必须且只能提供一个共享 GroundShadow 槽位。")
	if shadows.size() == 1:
		var shadow := shadows[0] as Sprite2D
		_expect(shadow != null, "Enemy 基类 GroundShadow 必须是原生 Sprite2D。")
		if shadow != null:
			_expect(
				not shadow.visible,
				"Enemy 基类阴影必须默认隐藏，具体落地敌人场景再显式启用。"
			)
			_test_shadow_primitive_contract(shadow, "Enemy 基类")
	enemy.free()


func _load_formal_enemy_configs() -> Array[EnemyConfig]:
	var configs: Array[EnemyConfig] = []
	var file_names := DirAccess.get_files_at(CONFIG_DIRECTORY)
	file_names.sort()
	for file_name in file_names:
		if not file_name.ends_with(".tres"):
			continue
		var path := "%s/%s" % [CONFIG_DIRECTORY, file_name]
		var resource := load(path)
		if resource is EnemyConfig:
			configs.append(resource as EnemyConfig)
	_expect(
		configs.size() == EXPECTED_CONFIG_COUNT,
		"全敌人接地阴影审计必须动态覆盖全部%d个正式 EnemyConfig，实际为%d个。"
		% [EXPECTED_CONFIG_COUNT, configs.size()]
	)
	return configs


func _audit_unique_enemy_scenes(configs: Array[EnemyConfig]) -> Dictionary:
	var configs_by_scene: Dictionary = {}
	for config in configs:
		_expect(config.enemy_scene != null, "%s 必须配置 enemy_scene。" % config.resource_path)
		if config.enemy_scene == null:
			continue
		var scene_path := config.enemy_scene.resource_path
		_expect(
			not scene_path.is_empty(),
			"%s 的 enemy_scene 必须来自稳定资源路径。" % config.resource_path
		)
		if scene_path.is_empty():
			continue
		if not configs_by_scene.has(scene_path):
			configs_by_scene[scene_path] = []
		(configs_by_scene[scene_path] as Array).append(config)

	var scene_paths: Array = configs_by_scene.keys()
	scene_paths.sort()
	var passed_scene_paths: Dictionary = {}
	for scene_path_variant in scene_paths:
		var scene_path := String(scene_path_variant)
		var scene_configs := configs_by_scene[scene_path] as Array
		var representative := scene_configs[0] as EnemyConfig
		if _audit_enemy_scene(representative, scene_path):
			passed_scene_paths[scene_path] = true
	return {
		"scene_count": scene_paths.size(),
		"passed_scene_paths": passed_scene_paths,
		"configs_by_scene": configs_by_scene,
	}


func _audit_enemy_scene(config: EnemyConfig, scene_path: String) -> bool:
	var failure_count_before := failures.size()
	var enemy := config.enemy_scene.instantiate()
	_expect(enemy is Enemy, "%s 必须实例化为 Enemy。" % scene_path)
	if not enemy is Enemy:
		if enemy != null:
			enemy.free()
		return false

	var shadows := _collect_named_nodes(enemy, &"GroundShadow")
	_expect(
		shadows.size() == 1,
		"%s 必须且只能继承一个 GroundShadow，实际为%d个。"
		% [scene_path, shadows.size()]
	)
	if shadows.size() != 1:
		enemy.free()
		return false
	var shadow := shadows[0] as Sprite2D
	_expect(shadow != null, "%s 的 GroundShadow 必须是原生 Sprite2D。" % scene_path)
	if shadow == null:
		enemy.free()
		return false

	_expect(shadow.visible, "%s 必须显式启用 GroundShadow。" % scene_path)
	_expect(
		shadow.get_parent() == enemy,
		"%s 的 GroundShadow 必须直接跟随敌人根节点，不能跟随主体动画抖动。" % scene_path
	)
	_test_shadow_primitive_contract(shadow, scene_path)
	_test_effective_shadow_dimensions(shadow, scene_path)
	_test_normal_animation_baseline(enemy as Enemy, config, shadow, scene_path)
	enemy.free()
	return failures.size() == failure_count_before


func _test_shadow_primitive_contract(shadow: Sprite2D, label: String) -> void:
	_expect(
		shadow.texture == SHARED_SHADOW_TEXTURE,
		"%s 必须共享 enemy_ground_shadow.tres，禁止复制逐场景纹理。" % label
	)
	_expect(
		shadow.texture_filter == CanvasItem.TEXTURE_FILTER_LINEAR,
		"%s 的柔边 GroundShadow 必须使用 linear 过滤。" % label
	)
	_expect(
		is_zero_approx(shadow.rotation)
		and is_zero_approx(shadow.skew)
		and shadow.modulate.a > 0.0
		and shadow.self_modulate.a > 0.0,
		"%s 的 GroundShadow 必须保持水平且具备可见透明度。" % label
	)
	_expect(
		shadow.z_index == 1 and not shadow.z_as_relative,
		"%s 的 GroundShadow 必须使用绝对 z=1。" % label
	)
	_expect(
		not shadow.use_parent_material and shadow.material == null,
		"%s 的 GroundShadow 不得继承或持有敌人状态材质。" % label
	)
	_expect(
		shadow.get_script() == null,
		"%s 的 GroundShadow 必须保持无脚本原生节点。" % label
	)
	_expect(
		not shadow.is_processing()
		and not shadow.is_physics_processing()
		and not shadow.is_processing_internal()
		and not shadow.is_physics_processing_internal(),
		"%s 的 GroundShadow 不得引入任何逐帧处理。" % label
	)
	_expect(
		shadow.get_child_count() == 0,
		"%s 的 GroundShadow 必须是无子节点、无碰撞的纯视觉节点。" % label
	)


func _test_effective_shadow_dimensions(shadow: Sprite2D, label: String) -> void:
	var texture_size := shadow.texture.get_size() if shadow.texture != null else Vector2.ZERO
	_expect(
		is_finite(shadow.position.x)
		and is_finite(shadow.position.y)
		and is_finite(shadow.scale.x)
		and is_finite(shadow.scale.y)
		and not is_zero_approx(shadow.scale.x)
		and not is_zero_approx(shadow.scale.y),
		"%s 的 GroundShadow 必须使用有限且非零的 authored 变换。" % label
	)
	var effective_size := Vector2(
		texture_size.x * absf(shadow.scale.x),
		texture_size.y * absf(shadow.scale.y)
	)
	_expect(
		is_finite(effective_size.x)
		and effective_size.x >= MIN_EFFECTIVE_WIDTH
		and effective_size.x <= MAX_EFFECTIVE_WIDTH,
		"%s 的阴影有效宽度 %.2f 不在合理范围 %.1f–%.1f。"
		% [label, effective_size.x, MIN_EFFECTIVE_WIDTH, MAX_EFFECTIVE_WIDTH]
	)
	_expect(
		is_finite(effective_size.y)
		and effective_size.y >= MIN_EFFECTIVE_HEIGHT
		and effective_size.y <= MAX_EFFECTIVE_HEIGHT,
		"%s 的阴影有效高度 %.2f 不在合理范围 %.1f–%.1f。"
		% [label, effective_size.y, MIN_EFFECTIVE_HEIGHT, MAX_EFFECTIVE_HEIGHT]
	)
	_expect(
		effective_size.y > 0.0
		and effective_size.x / effective_size.y >= MIN_FLAT_ASPECT_RATIO,
		"%s 的 GroundShadow 必须保持扁椭圆，有效尺寸为 %.2f×%.2f。"
		% [label, effective_size.x, effective_size.y]
	)


func _test_normal_animation_baseline(
	enemy: Enemy,
	config: EnemyConfig,
	shadow: Sprite2D,
	label: String
) -> void:
	var body := enemy.get_node_or_null("AnimatedSprite2D") as AnimatedSprite2D
	_expect(body != null, "%s 必须保留 AnimatedSprite2D 主体。" % label)
	if body == null:
		return
	var frames := body.sprite_frames
	_expect(frames != null, "%s 主体必须绑定 SpriteFrames。" % label)
	if frames == null:
		return
	var animation := _choose_normal_animation(frames, config.move_animation_name)
	_expect(
		not animation.is_empty(),
		"%s 必须能从 move/walk/run/idle 中选择正常行动动画。" % label
	)
	if animation.is_empty():
		return
	var frame_count := frames.get_frame_count(animation)
	_expect(frame_count > 0, "%s 的 %s 动画必须包含帧。" % [label, animation])
	for frame_index in range(frame_count):
		var lowest_y := _get_lowest_alpha_pixel_center_y(
			body,
			frames.get_frame_texture(animation, frame_index)
		)
		_expect(
			is_finite(lowest_y),
			"%s 的 %s 第%d帧必须包含可分析的非透明像素。"
			% [label, animation, frame_index]
		)
		if not is_finite(lowest_y):
			continue
		var baseline_error := absf(shadow.position.y - lowest_y)
		_expect(
			baseline_error <= BASELINE_TOLERANCE,
			"%s 的阴影横向中线 y=%.2f 未对齐 %s 第%d帧最低 Alpha 像素中心 y=%.2f（误差 %.2f）。"
			% [
				label,
				shadow.position.y,
				animation,
				frame_index,
				lowest_y,
				baseline_error,
			]
		)


func _choose_normal_animation(
	frames: SpriteFrames,
	configured_animation: StringName
) -> StringName:
	var candidates: Array[StringName] = []
	if configured_animation in NORMAL_ANIMATION_FALLBACKS:
		candidates.append(configured_animation)
	for fallback in NORMAL_ANIMATION_FALLBACKS:
		if fallback not in candidates:
			candidates.append(fallback)
	for candidate in candidates:
		if frames.has_animation(candidate) and frames.get_frame_count(candidate) > 0:
			return candidate
	return &""


func _get_lowest_alpha_pixel_center_y(
	sprite: AnimatedSprite2D,
	texture: Texture2D
) -> float:
	if texture == null:
		return NAN
	var image := texture.get_image()
	if image == null or image.is_empty():
		return NAN
	var texture_size := texture.get_size()
	if texture_size.x <= 0.0 or texture_size.y <= 0.0:
		return NAN
	var pixel_scale := Vector2(
		texture_size.x / float(image.get_width()),
		texture_size.y / float(image.get_height())
	)
	var lowest_y := -INF
	for image_y in range(image.get_height()):
		for image_x in range(image.get_width()):
			if image.get_pixel(image_x, image_y).a < ALPHA_THRESHOLD:
				continue
			var texture_point := Vector2(
				(float(image_x) + 0.5) * pixel_scale.x,
				(float(image_y) + 0.5) * pixel_scale.y
			)
			if sprite.flip_h:
				texture_point.x = texture_size.x - texture_point.x
			if sprite.flip_v:
				texture_point.y = texture_size.y - texture_point.y
			if sprite.centered:
				texture_point -= texture_size * 0.5
			texture_point += sprite.offset
			lowest_y = maxf(lowest_y, (sprite.transform * texture_point).y)
	return lowest_y


func _test_variant_coverage(configs: Array[EnemyConfig], audit: Dictionary) -> void:
	var passed_scene_paths := audit.get("passed_scene_paths", {}) as Dictionary
	var stone_eroded_count := 0
	var elite_count := 0
	for config in configs:
		var file_name := config.resource_path.get_file().get_basename()
		var is_stone_eroded := file_name.begins_with("stone_eroded_")
		var is_elite := file_name.ends_with("_elite")
		if is_stone_eroded:
			stone_eroded_count += 1
		if is_elite:
			elite_count += 1
		if is_stone_eroded or is_elite:
			_expect(
				config.enemy_scene != null
				and passed_scene_paths.has(config.enemy_scene.resource_path),
				"%s 必须通过继承链获得同一份合格 GroundShadow。" % config.resource_path
			)
	_expect(
		stone_eroded_count == EXPECTED_STONE_ERODED_CONFIG_COUNT,
		"石蚀继承审计必须覆盖%d个配置，实际为%d个。"
		% [EXPECTED_STONE_ERODED_CONFIG_COUNT, stone_eroded_count]
	)
	_expect(
		elite_count == EXPECTED_ELITE_CONFIG_COUNT,
		"精英继承审计必须覆盖%d个配置，实际为%d个。"
		% [EXPECTED_ELITE_CONFIG_COUNT, elite_count]
	)


func _test_suicide_drones_are_airborne_exceptions() -> void:
	for index in range(SUICIDE_DRONE_SCENES.size()):
		var drone := SUICIDE_DRONE_SCENES[index].instantiate()
		var shadows := _collect_named_nodes(drone, &"GroundShadow")
		_expect(
			shadows.is_empty(),
			"%s是脱离地面的飞行投射物，必须明确保持无 GroundShadow。"
			% SUICIDE_DRONE_LABELS[index]
		)
		drone.free()


func _test_thousand_lightweight_instances() -> void:
	var shared_texture_count := 0
	var process_free_count := 0
	for _instance_index in range(STRESS_INSTANCE_COUNT):
		var enemy := LIGHTWEIGHT_ENEMY_SCENE.instantiate()
		var shadows := _collect_named_nodes(enemy, &"GroundShadow")
		if shadows.size() == 1:
			var shadow := shadows[0] as Sprite2D
			if shadow != null and shadow.texture == SHARED_SHADOW_TEXTURE:
				shared_texture_count += 1
			if (
				shadow != null
				and shadow.get_script() == null
				and shadow.material == null
				and not shadow.is_processing()
				and not shadow.is_physics_processing()
			):
				process_free_count += 1
		enemy.free()
	_expect(
		shared_texture_count == STRESS_INSTANCE_COUNT,
		"1000个轻量敌人实例必须全部复用同一阴影纹理资源。"
	)
	_expect(
		process_free_count == STRESS_INSTANCE_COUNT,
		"1000个轻量敌人阴影必须全部保持零脚本、零材质、零独立处理。"
	)


func _collect_named_nodes(search_root: Node, node_name: StringName) -> Array[Node]:
	var matches: Array[Node] = []
	if search_root == null:
		return matches
	for child in search_root.get_children():
		if child.name == node_name:
			matches.append(child)
		matches.append_array(_collect_named_nodes(child, node_name))
	return matches


func _expect(condition: bool, message: String) -> void:
	if condition:
		return
	failures.append(message)
	push_error(message)


func _finish(config_count: int, scene_count: int) -> void:
	if failures.is_empty():
		print(
			"ENEMY_GROUND_SHADOW_FAMILY_SMOKE_TEST_OK configs=%d unique_scenes=%d stress=%d"
			% [config_count, scene_count, STRESS_INSTANCE_COUNT]
		)
		quit(0)
		return
	print(
		"ENEMY_GROUND_SHADOW_FAMILY_SMOKE_TEST_FAILED count=%d configs=%d unique_scenes=%d"
		% [failures.size(), config_count, scene_count]
	)
	for failure in failures:
		print(" - %s" % failure)
	quit(1)
