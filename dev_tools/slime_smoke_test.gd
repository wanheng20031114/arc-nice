extends SceneTree

const SLIME_CONFIG: EnemyConfig = preload(
	"res://resources/config/enemies/slime.tres"
)
const BASIC_YUANSHI_CONFIG: EnemyConfig = preload(
	"res://resources/config/enemies/yuanshi_insect_basic.tres"
)
const SLIME_FRAMES: SpriteFrames = preload(
	"res://resources/animation/slime.tres"
)

const FRAME_SIZE := Vector2(32.0, 32.0)
const SHEET_SIZE := Vector2i(96, 64)
const EXPECTED_MOVE_REGIONS := [
	Rect2(0, 0, 32, 32),
	Rect2(32, 0, 32, 32),
	Rect2(64, 0, 32, 32),
]
const EXPECTED_DEATH_REGIONS := [
	Rect2(0, 32, 32, 32),
	Rect2(32, 32, 32, 32),
	Rect2(64, 32, 32, 32),
]
const EXPECTED_MOVE_ALPHA_BOUNDS := [
	Rect2i(7, 8, 18, 14),
	Rect2i(6, 9, 20, 13),
	Rect2i(7, 9, 18, 13),
]
const EXPECTED_MOVE_ALPHA_PIXEL_COUNTS := [210, 208, 194]
const EXPECTED_DEATH_ALPHA_BOUNDS := [
	Rect2i(4, 11, 24, 11),
	Rect2i(1, 15, 29, 7),
	Rect2i(4, 18, 23, 4),
]
const EXPECTED_DEATH_ALPHA_PIXEL_COUNTS := [160, 136, 64]
const EXPECTED_DEATH_COMPONENT_COUNTS := [2, 3, 3]
const EXPECTED_EYE_CORE_PIXELS := [
	[
		Vector2i(14, 15),
		Vector2i(14, 16),
		Vector2i(18, 15),
		Vector2i(18, 16),
	],
	[
		Vector2i(14, 15),
		Vector2i(14, 16),
		Vector2i(18, 15),
		Vector2i(18, 16),
	],
	[
		Vector2i(14, 15),
		Vector2i(14, 16),
		Vector2i(18, 15),
		Vector2i(18, 16),
	],
]
const EXPECTED_COLLAPSE_EYE_CORE_PIXELS := [
	Vector2i(14, 19),
	Vector2i(18, 19),
]
const CARDINAL_NEIGHBORS: Array[Vector2i] = [
	Vector2i.LEFT,
	Vector2i.RIGHT,
	Vector2i.UP,
	Vector2i.DOWN,
]

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_config_contract()
	_test_animation_contract()
	_test_sprite_sheet_contract()
	_test_scene_contract()

	if failures.is_empty():
		print("SLIME_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_config_contract() -> void:
	_expect(SLIME_CONFIG.display_name == "史莱姆", "基础史莱姆必须使用独立显示名称。")
	_expect(SLIME_CONFIG.max_health == 40, "基础史莱姆生命值必须为 40。")
	_expect(SLIME_CONFIG.attack_damage == 10, "基础史莱姆攻击力必须为 10。")
	_expect(SLIME_CONFIG.physical_defense == 0, "基础史莱姆物理防御必须为 0。")
	_expect(SLIME_CONFIG.magic_defense == 0, "基础史莱姆法术防御必须为 0。")
	_expect(
		is_equal_approx(SLIME_CONFIG.move_speed, BASIC_YUANSHI_CONFIG.move_speed)
		and is_equal_approx(SLIME_CONFIG.move_speed, 20.0),
		"基础史莱姆必须和基础原石虫同为 20 像素/秒。"
	)
	_expect(
		SLIME_CONFIG.category_tags == PackedStringArray([EnemyConfig.CATEGORY_SLIME]),
		"基础史莱姆必须只携带 slime 类别标签。"
	)
	_expect(
		SLIME_CONFIG.has_category_tag(EnemyConfig.CATEGORY_SLIME),
		"通用类别查询必须能识别史莱姆。"
	)


func _test_animation_contract() -> void:
	_expect(SLIME_FRAMES.has_animation(&"move"), "史莱姆必须提供 move 动画。")
	_expect(SLIME_FRAMES.has_animation(&"death"), "史莱姆必须提供 death 动画。")
	_expect(SLIME_FRAMES.get_frame_count(&"move") == 3, "move 必须严格包含 3 帧。")
	_expect(SLIME_FRAMES.get_frame_count(&"death") == 3, "death 必须严格包含 3 帧。")
	_expect(
		is_equal_approx(SLIME_FRAMES.get_animation_speed(&"move"), 5.0),
		"move 必须复用基础原石虫的 5 FPS 节奏。"
	)
	_expect(SLIME_FRAMES.get_animation_loop(&"move"), "move 必须循环播放。")
	_expect(
		SLIME_FRAMES.get_animation_speed(&"death") > 0.0,
		"death 必须使用正向播放速度。"
	)
	_expect(not SLIME_FRAMES.get_animation_loop(&"death"), "death 不得循环播放。")
	_test_animation_regions(&"move", EXPECTED_MOVE_REGIONS)
	_test_animation_regions(&"death", EXPECTED_DEATH_REGIONS)


func _test_animation_regions(
	animation_name: StringName,
	expected_regions: Array
) -> void:
	for frame_index in range(expected_regions.size()):
		var frame_texture := SLIME_FRAMES.get_frame_texture(
			animation_name,
			frame_index
		) as AtlasTexture
		_expect(
			frame_texture != null,
			"%s 第 %d 帧必须使用 AtlasTexture。" % [animation_name, frame_index]
		)
		if frame_texture == null:
			continue
		_expect(
			frame_texture.region == expected_regions[frame_index],
			"%s 第 %d 帧必须对应正确的 32x32 图集区域。"
			% [animation_name, frame_index]
		)
		_expect(
			frame_texture.get_size() == FRAME_SIZE,
			"%s 第 %d 帧逻辑尺寸必须为 32x32。" % [animation_name, frame_index]
		)


func _test_sprite_sheet_contract() -> void:
	var first_frame := SLIME_FRAMES.get_frame_texture(&"move", 0) as AtlasTexture
	_expect(first_frame != null and first_frame.atlas != null, "史莱姆移动帧必须引用有效图集。")
	if first_frame == null or first_frame.atlas == null:
		return
	var image := first_frame.atlas.get_image()
	_expect(image != null, "史莱姆图集必须可以读取像素。")
	if image == null:
		return
	_expect(image.get_size() == SHEET_SIZE, "史莱姆图集必须严格为 96x64。")
	if image.get_size() != SHEET_SIZE:
		return

	for y in range(SHEET_SIZE.y):
		for x in range(SHEET_SIZE.x):
			var color := image.get_pixel(x, y)
			_expect(
				is_zero_approx(color.a) or is_equal_approx(color.a, 1.0),
				"史莱姆图集必须保持二值 alpha，禁止半透明破边。"
			)
			if color.a > 0.5:
				_expect(
					not _is_magenta_key_color(color),
					"史莱姆图集的非透明区域不得残留洋红抠图底色。"
				)

	_test_move_frame_contract(image)
	_test_death_frame_contract(image)


func _test_move_frame_contract(image: Image) -> void:
	var minimum_top := int(FRAME_SIZE.y)
	var maximum_top := 0
	for frame_index in range(3):
		var opaque_pixels := _get_local_opaque_pixels(image, frame_index, 0)
		var bounds := _get_local_alpha_bounds(image, frame_index, 0)
		_expect(
			bounds == EXPECTED_MOVE_ALPHA_BOUNDS[frame_index]
			and opaque_pixels.size() == EXPECTED_MOVE_ALPHA_PIXEL_COUNTS[frame_index],
			"move 第 %d 帧必须保留指定原图压回视觉网格后的轮廓。" % frame_index
		)
		_expect(
			_count_opaque_components(opaque_pixels) == 1,
			"move 第 %d 帧主体必须保持连续，不能出现透明破洞或碎边。" % frame_index
		)
		_expect(
			not _has_transparent_hole(opaque_pixels),
			"move 第 %d 帧轮廓内部不得出现透明破洞。" % frame_index
		)
		var center_x := (
			float(bounds.position.x * 2 + bounds.size.x - 1) * 0.5
		)
		_expect(
			is_equal_approx(center_x, 15.5)
			and bounds.position.y + bounds.size.y == 22,
			"move 第 %d 帧必须共用水平中心与落地点，避免动画剧烈偏移。" % frame_index
		)
		minimum_top = mini(minimum_top, bounds.position.y)
		maximum_top = maxi(maximum_top, bounds.position.y)
		_test_eye_core_contract(image, frame_index)
	_expect(
		maximum_top - minimum_top <= 1,
		"move 动画只允许一像素的自然弹跳，不得产生明显上下抖动。"
	)


func _test_eye_core_contract(image: Image, frame_index: int) -> void:
	var actual_eye_pixels := {}
	for local_y in range(13, 18):
		for local_x in range(12, 20):
			var color := image.get_pixel(frame_index * 32 + local_x, local_y)
			if _is_eye_core_color(color):
				actual_eye_pixels[Vector2i(local_x, local_y)] = true
	var expected_eye_pixels: Array = EXPECTED_EYE_CORE_PIXELS[frame_index]
	_expect(
		actual_eye_pixels.size() == expected_eye_pixels.size(),
		"move 第 %d 帧必须保留原图眼部核心像素数量。" % frame_index
	)
	for eye_pixel in expected_eye_pixels:
		_expect(
			actual_eye_pixels.has(eye_pixel),
			"move 第 %d 帧的两枚竖点眼睛必须保持原图位置与分离状态。" % frame_index
		)


func _test_death_frame_contract(image: Image) -> void:
	for frame_index in range(3):
		var opaque_pixels := _get_local_opaque_pixels(image, frame_index, 1)
		var bounds := _get_local_alpha_bounds(image, frame_index, 1)
		_expect(
			bounds == EXPECTED_DEATH_ALPHA_BOUNDS[frame_index]
			and opaque_pixels.size() == EXPECTED_DEATH_ALPHA_PIXEL_COUNTS[frame_index],
			"death 第 %d 帧必须保留指定原图的塌缩与飞溅姿态。" % frame_index
		)
		_expect(
			bounds.position.y + bounds.size.y == 22,
			"death 第 %d 帧必须与移动动画共用落地点。" % frame_index
		)
		_expect(
			_count_opaque_components(opaque_pixels)
			== EXPECTED_DEATH_COMPONENT_COUNTS[frame_index],
			"death 第 %d 帧必须保留原图中的独立飞溅液滴。" % frame_index
		)
	for eye_pixel in EXPECTED_COLLAPSE_EYE_CORE_PIXELS:
		_expect(
			_is_eye_core_color(image.get_pixel(eye_pixel.x, 32 + eye_pixel.y)),
			"第一帧塌缩姿势必须保留原图中的两枚眼睛。"
		)


func _is_magenta_key_color(color: Color) -> bool:
	return minf(color.r, color.b) - color.g >= 96.0 / 255.0


func _is_eye_core_color(color: Color) -> bool:
	return (
		color.a > 0.9
		and color.r < 20.0 / 255.0
		and color.g < 100.0 / 255.0
		and color.b < 180.0 / 255.0
	)


func _get_local_opaque_pixels(
	image: Image,
	frame_index: int,
	frame_row: int
) -> Dictionary:
	var opaque_pixels := {}
	for local_y in range(32):
		for local_x in range(32):
			if image.get_pixel(
				frame_index * 32 + local_x,
				frame_row * 32 + local_y
			).a > 0.5:
				opaque_pixels[Vector2i(local_x, local_y)] = true
	return opaque_pixels


func _get_local_alpha_bounds(
	image: Image,
	frame_index: int,
	frame_row: int
) -> Rect2i:
	var minimum := Vector2i(32, 32)
	var maximum := Vector2i(-1, -1)
	for pixel_position in _get_local_opaque_pixels(
		image,
		frame_index,
		frame_row
	).keys():
		minimum.x = mini(minimum.x, pixel_position.x)
		minimum.y = mini(minimum.y, pixel_position.y)
		maximum.x = maxi(maximum.x, pixel_position.x)
		maximum.y = maxi(maximum.y, pixel_position.y)
	if maximum.x < 0:
		return Rect2i()
	return Rect2i(minimum, maximum - minimum + Vector2i.ONE)


func _count_opaque_components(opaque_pixels: Dictionary) -> int:
	var remaining := opaque_pixels.duplicate()
	var component_count := 0
	while not remaining.is_empty():
		component_count += 1
		var pending: Array[Vector2i] = [remaining.keys()[0] as Vector2i]
		while not pending.is_empty():
			var current: Vector2i = pending.pop_back()
			if not remaining.has(current):
				continue
			remaining.erase(current)
			for offset in CARDINAL_NEIGHBORS:
				var neighbor: Vector2i = current + offset
				if remaining.has(neighbor):
					pending.append(neighbor)
	return component_count


func _has_transparent_hole(opaque_pixels: Dictionary) -> bool:
	var reachable_transparent := {}
	var pending: Array[Vector2i] = []
	for coordinate in range(32):
		for border_position in [
			Vector2i(coordinate, 0),
			Vector2i(coordinate, 31),
			Vector2i(0, coordinate),
			Vector2i(31, coordinate),
		]:
			if (
				not opaque_pixels.has(border_position)
				and not reachable_transparent.has(border_position)
			):
				reachable_transparent[border_position] = true
				pending.append(border_position)
	while not pending.is_empty():
		var current: Vector2i = pending.pop_back()
		for offset in CARDINAL_NEIGHBORS:
			var neighbor: Vector2i = current + offset
			if (
				neighbor.x < 0
				or neighbor.x >= 32
				or neighbor.y < 0
				or neighbor.y >= 32
				or opaque_pixels.has(neighbor)
				or reachable_transparent.has(neighbor)
			):
				continue
			reachable_transparent[neighbor] = true
			pending.append(neighbor)
	return reachable_transparent.size() != 32 * 32 - opaque_pixels.size()


func _test_scene_contract() -> void:
	_expect(SLIME_CONFIG.enemy_scene != null, "史莱姆配置必须绑定敌人场景。")
	if SLIME_CONFIG.enemy_scene == null:
		return
	var slime := SLIME_CONFIG.enemy_scene.instantiate()
	_expect(slime is Slime, "史莱姆场景必须实例化独立 Slime 类型。")
	_expect(slime is YuanshiInsect, "Slime 必须复用原石虫的移动实现。")
	if not slime is Enemy:
		if slime != null:
			slime.free()
		return
	var enemy := slime as Enemy
	var sprite := enemy.get_node_or_null("AnimatedSprite2D") as AnimatedSprite2D
	var body_shape := enemy.get_node_or_null("CollisionShape2D") as CollisionShape2D
	var touch_shape := enemy.get_node_or_null(
		"TouchDamageArea/CollisionShape2D"
	) as CollisionShape2D
	_expect(sprite != null, "史莱姆场景必须包含 AnimatedSprite2D。")
	_expect(body_shape != null, "史莱姆场景必须包含本体碰撞。")
	_expect(touch_shape != null, "史莱姆场景必须包含独立接触伤害碰撞。")
	if sprite != null:
		_expect(sprite.position == Vector2(0, -2), "史莱姆精灵必须与原石虫同样上移 2 像素。")
		_expect(sprite.scale == Vector2.ONE, "32x32 原生视觉图集不得再进行二次缩放。")
		_expect(sprite.sprite_frames == SLIME_FRAMES, "史莱姆精灵必须绑定专用 SpriteFrames。")
	if body_shape != null and touch_shape != null:
		var body_capsule := body_shape.shape as CapsuleShape2D
		var touch_capsule := touch_shape.shape as CapsuleShape2D
		_expect(body_capsule != null, "史莱姆本体必须使用横向胶囊碰撞。")
		_expect(touch_capsule != null, "史莱姆接触伤害必须使用横向胶囊碰撞。")
		_expect(body_shape.shape != touch_shape.shape, "本体与接触伤害不得共享 Shape2D 资源。")
		if body_capsule != null:
			_expect(
				is_equal_approx(body_capsule.radius, 4.0)
				and is_equal_approx(body_capsule.height, 16.0),
				"史莱姆本体胶囊必须使用 radius=4、height=16。"
			)
		if touch_capsule != null:
			_expect(
				is_equal_approx(touch_capsule.radius, 4.0)
				and is_equal_approx(touch_capsule.height, 16.0),
				"史莱姆接触胶囊必须使用 radius=4、height=16。"
			)
		_expect(
			is_equal_approx(body_shape.rotation, PI / 2.0)
			and is_equal_approx(touch_shape.rotation, PI / 2.0),
			"史莱姆两枚胶囊碰撞必须水平旋转 90 度。"
		)
	enemy.free()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
