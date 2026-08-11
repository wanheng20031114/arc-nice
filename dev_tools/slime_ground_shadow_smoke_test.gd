extends SceneTree

const BASE_SLIME_SCENE := preload("res://scene/enemy/slime/slime_basic.tscn")
const SLIME_CONFIGS: Array[SlimeConfig] = [
	preload("res://resources/config/enemies/slime.tres"),
	preload("res://resources/config/enemies/slime_golden.tres"),
	preload("res://resources/config/enemies/slime_fire.tres"),
	preload("res://resources/config/enemies/slime_frost.tres"),
	preload("res://resources/config/enemies/slime_green.tres"),
	preload("res://resources/config/enemies/stone_eroded_slime.tres"),
	preload("res://resources/config/enemies/stone_eroded_slime_golden.tres"),
	preload("res://resources/config/enemies/stone_eroded_slime_fire.tres"),
	preload("res://resources/config/enemies/stone_eroded_slime_frost.tres"),
	preload("res://resources/config/enemies/stone_eroded_slime_green.tres"),
]

const EXPECTED_SHADOW_POSITION := Vector2(0.0, 5.5)
const EXPECTED_SHADOW_SIZE := Vector2i(26, 5)
const EXPECTED_GRADIENT_OFFSETS := [0.0, 0.5, 0.78, 1.0]
const EXPECTED_GRADIENT_ALPHAS := [0.66, 0.50, 0.20, 0.0]
const EXPECTED_GRADIENT_RGB := Vector3(0.02, 0.025, 0.035)
const STRESS_INSTANCE_COUNT := 1000

var failures: Array[String] = []
var fixture: Node2D


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	fixture = Node2D.new()
	fixture.name = "SlimeGroundShadowFixture"
	root.add_child(fixture)
	current_scene = fixture
	await process_frame

	var shared_texture := _test_base_authored_contract()
	_test_family_inheritance_and_resource_sharing(shared_texture)
	await _test_status_material_isolation()
	_test_animation_and_facing_stability()
	_test_thousand_instance_resource_sharing(shared_texture)

	fixture.queue_free()
	await process_frame
	_finish()


func _test_base_authored_contract() -> GradientTexture2D:
	var slime := BASE_SLIME_SCENE.instantiate() as Slime
	_expect(slime != null, "基础史莱姆场景必须仍可实例化为 Slime。")
	if slime == null:
		return null

	var shadows := _collect_named_nodes(slime, &"GroundShadow")
	_expect(shadows.size() == 1, "slime_basic 必须静态创作且仅创作一个 GroundShadow。")
	if shadows.size() != 1:
		slime.free()
		return null
	var shadow := shadows[0] as Sprite2D
	_expect(shadow != null, "GroundShadow 必须使用原生 Sprite2D。")
	if shadow == null:
		slime.free()
		return null

	_expect(shadow.owner == slime, "GroundShadow 必须直接保存在史莱姆 PackedScene 中。")
	_expect(
		shadow.position.is_equal_approx(EXPECTED_SHADOW_POSITION),
		"GroundShadow 横向中线必须锚定在普通移动帧最低像素中心 (0, 5.5)。"
	)
	_test_move_frame_baseline(slime, shadow)
	_expect(shadow.scale.is_equal_approx(Vector2.ONE), "GroundShadow 必须保持26×5原生尺寸。")
	_expect(shadow.z_index == 1, "GroundShadow 必须位于地板 z0 与敌人主体 z2 之间。")
	_expect(
		shadow.texture_filter == CanvasItem.TEXTURE_FILTER_LINEAR,
		"柔边接触阴影必须使用 linear 过滤。"
	)
	_expect(not shadow.use_parent_material, "GroundShadow 不得继承史莱姆主体状态材质。")
	_expect(shadow.material == null, "GroundShadow 不得绑定独立材质。")
	_expect(shadow.get_script() == null, "GroundShadow 必须由原生节点构成，不得绑定脚本。")
	_expect(
		not shadow.is_processing() and not shadow.is_physics_processing(),
		"GroundShadow 不得拥有独立逐帧或物理处理。"
	)
	_expect(
		shadow.get_child_count() == 0 and not shadow.is_class(&"CollisionObject2D"),
		"GroundShadow 必须是无碰撞、无辅助子节点的纯视觉节点。"
	)

	var texture := shadow.texture as GradientTexture2D
	_expect(texture != null, "GroundShadow 必须直接使用 GradientTexture2D。")
	if texture != null:
		_test_gradient_contract(texture)
	slime.free()
	return texture


func _test_move_frame_baseline(slime: Slime, shadow: Sprite2D) -> void:
	var body := slime.get_node_or_null("AnimatedSprite2D") as AnimatedSprite2D
	_expect(body != null, "普通行动基线检查必须取得史莱姆主体。")
	if body == null:
		return
	_expect(
		body.centered
		and body.position.is_zero_approx()
		and body.offset.is_zero_approx()
		and body.scale.is_equal_approx(Vector2.ONE),
		"普通行动基线换算要求主体保持居中、零偏移与原生缩放。"
	)
	var frames := body.sprite_frames
	_expect(
		frames != null
		and frames.has_animation(&"move")
		and frames.get_frame_count(&"move") > 0,
		"史莱姆必须保留可分析的普通 move 动画。"
	)
	if frames == null or not frames.has_animation(&"move"):
		return
	for frame_index in range(frames.get_frame_count(&"move")):
		var texture := frames.get_frame_texture(&"move", frame_index)
		var image := texture.get_image() if texture != null else null
		_expect(
			image != null and not image.is_empty(),
			"move 第%d帧必须可读取像素。" % frame_index
		)
		if image == null or image.is_empty():
			continue
		var lowest_alpha_row := -1
		for y in range(image.get_height()):
			for x in range(image.get_width()):
				if image.get_pixel(x, y).a > 0.0:
					lowest_alpha_row = maxi(lowest_alpha_row, y)
		var lowest_pixel_center_y := (
			float(lowest_alpha_row) + 0.5 - float(image.get_height()) * 0.5
		)
		_expect(
			lowest_alpha_row >= 0
			and is_equal_approx(shadow.position.y, lowest_pixel_center_y),
			"GroundShadow 中线必须穿过 move 第%d帧最低Alpha像素中心 y=%.1f。"
			% [frame_index, lowest_pixel_center_y]
		)


func _test_gradient_contract(texture: GradientTexture2D) -> void:
	_expect(
		texture.width == EXPECTED_SHADOW_SIZE.x
		and texture.height == EXPECTED_SHADOW_SIZE.y,
		"GroundShadow 渐变纹理必须精确为26×5。"
	)
	_expect(
		texture.fill == GradientTexture2D.FILL_RADIAL,
		"GroundShadow 必须使用径向渐变。"
	)
	_expect(
		texture.fill_from.is_equal_approx(Vector2(0.5, 0.5))
		and texture.fill_to.is_equal_approx(Vector2(1.0, 0.5)),
		"GroundShadow 径向渐变必须从中心水平展开。"
	)
	var gradient := texture.gradient
	_expect(gradient != null, "GroundShadow GradientTexture2D 必须绑定 Gradient。")
	if gradient == null:
		return
	_expect(
		gradient.offsets.size() == EXPECTED_GRADIENT_OFFSETS.size()
		and gradient.colors.size() == EXPECTED_GRADIENT_ALPHAS.size(),
		"GroundShadow 必须保留四级柔边颜色停点。"
	)
	var stop_count := mini(
		gradient.offsets.size(),
		mini(EXPECTED_GRADIENT_OFFSETS.size(), gradient.colors.size())
	)
	for stop_index in range(stop_count):
		var color := gradient.colors[stop_index]
		_expect(
			is_equal_approx(gradient.offsets[stop_index], EXPECTED_GRADIENT_OFFSETS[stop_index]),
			"GroundShadow 第%d个渐变停点位置错误。" % stop_index
		)
		_expect(
			is_equal_approx(color.r, EXPECTED_GRADIENT_RGB.x)
			and is_equal_approx(color.g, EXPECTED_GRADIENT_RGB.y)
			and is_equal_approx(color.b, EXPECTED_GRADIENT_RGB.z)
			and is_equal_approx(color.a, EXPECTED_GRADIENT_ALPHAS[stop_index]),
			"GroundShadow 第%d个渐变停点颜色或透明度错误。" % stop_index
		)


func _test_family_inheritance_and_resource_sharing(
	shared_texture: GradientTexture2D
) -> void:
	_expect(SLIME_CONFIGS.size() == 10, "阴影继承矩阵必须覆盖五种普通与五种石蚀史莱姆。")
	for slime_config in SLIME_CONFIGS:
		var slime := slime_config.enemy_scene.instantiate() as Slime
		_expect(slime != null, "%s 场景必须仍可实例化为 Slime。" % slime_config.display_name)
		if slime == null:
			continue
		var shadows := _collect_named_nodes(slime, &"GroundShadow")
		_expect(
			shadows.size() == 1,
			"%s 必须从共享基础场景继承且仅继承一个 GroundShadow。" % slime_config.display_name
		)
		if shadows.size() == 1:
			var shadow := shadows[0] as Sprite2D
			_expect(shadow != null, "%s 的 GroundShadow 必须保持 Sprite2D。" % slime_config.display_name)
			if shadow != null:
				_expect(
					shared_texture != null and shadow.texture == shared_texture,
					"%s 必须共享同一阴影纹理资源，禁止逐实例复制。" % slime_config.display_name
				)
				_test_move_frame_baseline(slime, shadow)
		slime.free()


func _test_status_material_isolation() -> void:
	var slime := BASE_SLIME_SCENE.instantiate() as Slime
	fixture.add_child(slime)
	await process_frame
	slime.setup(SLIME_CONFIGS[0], null, null)
	slime.add_move_speed_modifier(1, 0.5)
	var shadow := slime.get_node_or_null("GroundShadow") as Sprite2D
	var body := slime.get_node_or_null("AnimatedSprite2D") as AnimatedSprite2D
	_expect(
		shadow != null
		and body != null
		and slime.status_visual_material != null
		and body.material == slime.status_visual_material
		and shadow.material == null
		and not shadow.use_parent_material,
		"激活减速状态后 ShaderMaterial 必须只作用于主体，不得传播到 GroundShadow。"
	)
	slime.remove_move_speed_modifier(1)
	slime.queue_free()
	await process_frame


func _test_animation_and_facing_stability() -> void:
	var slime := BASE_SLIME_SCENE.instantiate() as Slime
	var shadow := slime.get_node_or_null("GroundShadow") as Sprite2D
	var body := slime.get_node_or_null("AnimatedSprite2D") as AnimatedSprite2D
	_expect(shadow != null and body != null, "动画稳定性检查必须取得主体与 GroundShadow。")
	if shadow == null or body == null:
		slime.free()
		return
	var expected_transform := shadow.transform
	var expected_rect := shadow.get_rect()
	for frame_index in range(3):
		body.frame = frame_index
		for flipped in [false, true]:
			body.flip_h = flipped
			_expect(
				shadow.transform.is_equal_approx(expected_transform)
				and shadow.get_rect().is_equal_approx(expected_rect),
				"移动第%d帧 flip_h=%s 时阴影位置、缩放和尺寸不得变化。"
				% [frame_index, str(flipped)]
			)
	slime.free()


func _test_thousand_instance_resource_sharing(
	shared_texture: GradientTexture2D
) -> void:
	var shared_count := 0
	var process_free_count := 0
	for _instance_index in range(STRESS_INSTANCE_COUNT):
		var slime := BASE_SLIME_SCENE.instantiate() as Slime
		var shadow := slime.get_node_or_null("GroundShadow") as Sprite2D
		if shared_texture != null and shadow != null and shadow.texture == shared_texture:
			shared_count += 1
		if (
			shadow != null
			and shadow.get_script() == null
			and not shadow.is_processing()
			and not shadow.is_physics_processing()
		):
			process_free_count += 1
		slime.free()
	_expect(
		shared_count == STRESS_INSTANCE_COUNT,
		"1000个史莱姆实例必须共享同一 GradientTexture2D。"
	)
	_expect(
		process_free_count == STRESS_INSTANCE_COUNT,
		"1000个史莱姆阴影都不得产生独立逐帧处理。"
	)


func _collect_named_nodes(search_root: Node, node_name: StringName) -> Array[Node]:
	var matches: Array[Node] = []
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


func _finish() -> void:
	if failures.is_empty():
		print("SLIME_GROUND_SHADOW_SMOKE_TEST_OK")
		quit(0)
		return
	print("SLIME_GROUND_SHADOW_SMOKE_TEST_FAILED count=%d" % failures.size())
	for failure in failures:
		print(" - %s" % failure)
	quit(1)
