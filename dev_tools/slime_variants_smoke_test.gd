extends SceneTree

const BASE_CONFIG: SlimeConfig = preload("res://resources/config/enemies/slime.tres")
const GOLDEN_CONFIG: SlimeConfig = preload(
	"res://resources/config/enemies/slime_golden.tres"
)
const FIRE_CONFIG: SlimeConfig = preload(
	"res://resources/config/enemies/slime_fire.tres"
)
const FROST_CONFIG: SlimeConfig = preload(
	"res://resources/config/enemies/slime_frost.tres"
)
const GREEN_CONFIG: SlimeConfig = preload(
	"res://resources/config/enemies/slime_green.tres"
)
const BASE_FRAMES: SpriteFrames = preload("res://resources/animation/slime.tres")
const GOLDEN_FRAMES: SpriteFrames = preload(
	"res://resources/animation/slime_golden.tres"
)
const FIRE_FRAMES: SpriteFrames = preload(
	"res://resources/animation/slime_fire.tres"
)
const FROST_FRAMES: SpriteFrames = preload(
	"res://resources/animation/slime_frost.tres"
)
const GREEN_FRAMES: SpriteFrames = preload(
	"res://resources/animation/slime_green.tres"
)
const PLAYER_SCENE := preload("res://scene/player/hoe_cat/player_hoe_cat.tscn")
const MP_GAME_SCRIPT := preload("res://scene/multiplayer/mp_game.gd")

const FRAME_SIZE := 32
const SHEET_SIZE := Vector2i(96, 64)
const EYE_PIXELS := [
	Vector2i(14, 15),
	Vector2i(18, 15),
	Vector2i(14, 16),
	Vector2i(18, 16),
]
const MOVE_FACE_RECT := Rect2i(13, 14, 7, 3)
const EXPECTED_FRAME_BOUNDS := [
	Rect2i(7, 8, 18, 14),
	Rect2i(6, 9, 20, 13),
	Rect2i(7, 9, 18, 13),
	Rect2i(4, 11, 24, 11),
	Rect2i(1, 15, 29, 7),
	Rect2i(4, 18, 23, 4),
]
const EXPECTED_VISIBLE_PIXEL_COUNTS := [210, 208, 194, 160, 136, 64]
const EXPECTED_REGIONS := {
	&"move": [
		Rect2(0, 0, 32, 32),
		Rect2(32, 0, 32, 32),
		Rect2(64, 0, 32, 32),
	],
	&"death": [
		Rect2(0, 32, 32, 32),
		Rect2(32, 32, 32, 32),
		Rect2(64, 32, 32, 32),
	],
}

var failures: Array[String] = []
var fixture: Node2D


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	fixture = Node2D.new()
	fixture.name = "SlimeVariantsFixture"
	root.add_child(fixture)
	current_scene = fixture
	await process_frame

	_test_config_contracts()
	_test_sprite_and_scene_contracts()
	_test_multiplayer_status_mapping()
	await _test_elemental_touch_contracts()
	await _test_green_regeneration_contract()

	fixture.queue_free()
	await process_frame
	if failures.is_empty():
		print("SLIME_VARIANTS_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_config_contracts() -> void:
	var contracts := [
		{
			"config": BASE_CONFIG,
			"name": "史莱姆",
			"variant": SlimeConfig.Variant.BASIC,
			"health": 100,
			"damage": 10,
			"physical_defense": 0,
			"magic_defense": 0,
		},
		{
			"config": GOLDEN_CONFIG,
			"name": "黄金史莱姆",
			"variant": SlimeConfig.Variant.GOLDEN,
			"health": 1000,
			"damage": 50,
			"physical_defense": 0,
			"magic_defense": 0,
		},
		{
			"config": FIRE_CONFIG,
			"name": "火焰史莱姆",
			"variant": SlimeConfig.Variant.FIRE,
			"health": 200,
			"damage": 10,
			"physical_defense": 0,
			"magic_defense": 0,
		},
		{
			"config": FROST_CONFIG,
			"name": "寒冰史莱姆",
			"variant": SlimeConfig.Variant.FROST,
			"health": 200,
			"damage": 10,
			"physical_defense": 0,
			"magic_defense": 0,
		},
		{
			"config": GREEN_CONFIG,
			"name": "绿色史莱姆",
			"variant": SlimeConfig.Variant.GREEN,
			"health": 300,
			"damage": 10,
			"physical_defense": 50,
			"magic_defense": 50,
		},
	]
	for contract in contracts:
		var config := contract["config"] as SlimeConfig
		_expect(config.display_name == contract["name"], "史莱姆显示名称必须匹配变体。")
		_expect(config.variant == contract["variant"], "%s 变体枚举错误。" % config.display_name)
		_expect(config.max_health == contract["health"], "%s 生命值错误。" % config.display_name)
		_expect(config.attack_damage == contract["damage"], "%s 攻击力错误。" % config.display_name)
		_expect(
			config.physical_defense == contract["physical_defense"]
			and config.magic_defense == contract["magic_defense"],
			"%s 双防错误。" % config.display_name
		)
		_expect(is_equal_approx(config.move_speed, 20.0), "%s 必须沿用基础史莱姆移速。" % config.display_name)
		_expect(
			config.category_tags == PackedStringArray([EnemyConfig.CATEGORY_SLIME]),
			"%s 必须保留统一 slime 类别标签。" % config.display_name
		)


func _test_sprite_and_scene_contracts() -> void:
	var variants := [
		{"config": GOLDEN_CONFIG, "frames": GOLDEN_FRAMES},
		{"config": FIRE_CONFIG, "frames": FIRE_FRAMES},
		{"config": FROST_CONFIG, "frames": FROST_FRAMES},
		{"config": GREEN_CONFIG, "frames": GREEN_FRAMES},
	]
	var base_image := _get_sheet_image(BASE_FRAMES)
	_expect(base_image != null and base_image.get_size() == SHEET_SIZE, "基础史莱姆图集必须有效。")
	if base_image == null or base_image.get_size() != SHEET_SIZE:
		return
	for variant in variants:
		var config := variant["config"] as SlimeConfig
		var frames := variant["frames"] as SpriteFrames
		_test_animation_contract(frames, config.display_name)
		var image := _get_sheet_image(frames)
		_expect(image != null and image.get_size() == SHEET_SIZE, "%s 图集必须为96×64。" % config.display_name)
		if image != null and image.get_size() == SHEET_SIZE:
			_test_locked_geometry(base_image, image, config.display_name)
			if config == GREEN_CONFIG:
				_test_green_palette(image)
		_test_scene_contract(config, frames)


func _test_animation_contract(frames: SpriteFrames, label: String) -> void:
	for animation_name in [&"move", &"death"]:
		_expect(frames.has_animation(animation_name), "%s 缺少%s动画。" % [label, animation_name])
		_expect(frames.get_frame_count(animation_name) == 3, "%s 的%s必须为3帧。" % [label, animation_name])
		for frame_index in range(3):
			var texture := frames.get_frame_texture(animation_name, frame_index) as AtlasTexture
			_expect(
				texture != null
				and texture.region == EXPECTED_REGIONS[animation_name][frame_index],
				"%s 的%s第%d帧区域错误。" % [label, animation_name, frame_index]
			)
	_expect(
		is_equal_approx(frames.get_animation_speed(&"move"), 5.0)
		and frames.get_animation_loop(&"move"),
		"%s 移动动画必须沿用5 FPS循环。" % label
	)
	_expect(
		is_equal_approx(frames.get_animation_speed(&"death"), 6.0)
		and not frames.get_animation_loop(&"death"),
		"%s 死亡动画必须沿用6 FPS非循环。" % label
	)


func _test_locked_geometry(base: Image, variant: Image, label: String) -> void:
	var changed_color_count := 0
	for y in range(SHEET_SIZE.y):
		for x in range(SHEET_SIZE.x):
			var base_color := base.get_pixel(x, y)
			var variant_color := variant.get_pixel(x, y)
			_expect(
				is_equal_approx(base_color.a, variant_color.a),
				"%s 生图原稿必须保持基础史莱姆的视觉像素轮廓。" % label
			)
			_expect(
				is_zero_approx(variant_color.a) or is_equal_approx(variant_color.a, 1.0),
				"%s 禁止半透明破边。" % label
			)
			if variant_color.a > 0.5 and variant_color != base_color:
				changed_color_count += 1
	_expect(changed_color_count > 900, "%s 必须完整使用独立元素色带。" % label)
	for frame_index in range(6):
		var frame_geometry := _measure_frame_geometry(variant, frame_index)
		_expect(
			frame_geometry["bounds"] == EXPECTED_FRAME_BOUNDS[frame_index],
			"%s 第%d帧不能通过缩放改变主体尺寸或基线。" % [label, frame_index]
		)
		_expect(
			frame_geometry["visible_count"]
			== EXPECTED_VISIBLE_PIXEL_COUNTS[frame_index],
			"%s 第%d帧必须保持正确的视觉像素数量。" % [label, frame_index]
		)
	var shared_eye_color := variant.get_pixel(EYE_PIXELS[0].x, EYE_PIXELS[0].y)
	for frame_index in range(3):
		var dark_face_pixels: Array[Vector2i] = []
		for y in range(MOVE_FACE_RECT.position.y, MOVE_FACE_RECT.end.y):
			for x in range(MOVE_FACE_RECT.position.x, MOVE_FACE_RECT.end.x):
				var face_color := variant.get_pixel(
					frame_index * FRAME_SIZE + x,
					y
				)
				if face_color.a > 0.99 and face_color.get_luminance() < 0.32:
					dark_face_pixels.append(Vector2i(x, y))
		_expect(
			dark_face_pixels == EYE_PIXELS,
			"%s 移动第%d帧眼区必须恰好只有两枚1×2竖点眼，不能加粗或漂移。"
			% [label, frame_index]
		)
		for eye_pixel in EYE_PIXELS:
			var color := variant.get_pixel(frame_index * FRAME_SIZE + eye_pixel.x, eye_pixel.y)
			_expect(
				color == shared_eye_color,
				"%s 三个移动帧的眼睛颜色和粗细必须完全一致。" % label
			)


func _measure_frame_geometry(image: Image, frame_index: int) -> Dictionary:
	var frame_offset := Vector2i(
		frame_index % 3 * FRAME_SIZE,
		frame_index / 3 * FRAME_SIZE
	)
	var minimum := Vector2i(FRAME_SIZE, FRAME_SIZE)
	var maximum := Vector2i(-1, -1)
	var visible_count := 0
	for y in range(FRAME_SIZE):
		for x in range(FRAME_SIZE):
			if image.get_pixel(frame_offset.x + x, frame_offset.y + y).a <= 0.5:
				continue
			visible_count += 1
			minimum.x = mini(minimum.x, x)
			minimum.y = mini(minimum.y, y)
			maximum.x = maxi(maximum.x, x)
			maximum.y = maxi(maximum.y, y)
	var bounds := Rect2i()
	if visible_count > 0:
		bounds = Rect2i(minimum, maximum - minimum + Vector2i.ONE)
	return {"bounds": bounds, "visible_count": visible_count}


func _test_green_palette(image: Image) -> void:
	var opaque_colors := {}
	for y in range(SHEET_SIZE.y):
		for x in range(SHEET_SIZE.x):
			var color := image.get_pixel(x, y)
			if color.a < 0.99:
				continue
			opaque_colors[color.to_rgba32()] = true
			_expect(
				color.g > color.r + 8.0 / 255.0
				and color.g > color.b + 8.0 / 255.0,
				"绿色史莱姆所有可见像素必须保持草绿色主导。"
			)
	_expect(
		opaque_colors.size() == 8,
		"绿色史莱姆运行时图集必须严格使用8色有限色板，禁止生成噪点和脏渐变。"
	)


func _test_scene_contract(config: SlimeConfig, frames: SpriteFrames) -> void:
	var slime := config.enemy_scene.instantiate() as Slime
	_expect(slime != null, "%s 场景必须实例化 Slime。" % config.display_name)
	if slime == null:
		return
	slime.config = config
	var sprite := slime.get_node("AnimatedSprite2D") as AnimatedSprite2D
	_expect(sprite.sprite_frames == frames, "%s 场景必须绑定专用动画。" % config.display_name)
	var expected_damage_type := (
		EnemyConfig.DamageType.MAGIC
		if config.variant in [SlimeConfig.Variant.FIRE, SlimeConfig.Variant.FROST]
		else EnemyConfig.DamageType.PHYSICAL
	)
	_expect(
		slime.call("_get_touch_damage_type") == expected_damage_type,
		"%s 接触伤害类型错误。" % config.display_name
	)
	var expected_source_type := &"enemy_touch"
	if config.variant == SlimeConfig.Variant.FIRE:
		expected_source_type = Slime.FIRE_TOUCH_SOURCE_FAMILY
	elif config.variant == SlimeConfig.Variant.FROST:
		expected_source_type = Slime.FROST_TOUCH_SOURCE_TYPE
	_expect(
		slime.call("_get_multiplayer_touch_source_type") == expected_source_type,
		"%s 多人接触来源类型错误。" % config.display_name
	)
	slime.free()


func _test_multiplayer_status_mapping() -> void:
	var mp_game := MP_GAME_SCRIPT.new()
	_expect(
		mp_game.call(
			"_get_enemy_burn_family",
			Slime.FIRE_TOUCH_SOURCE_FAMILY
		) == Slime.FIRE_TOUCH_SOURCE_FAMILY,
		"多人权威层必须识别火焰史莱姆燃烧来源。"
	)
	_expect(
		int(mp_game.call(
			"_get_enemy_burn_level",
			Slime.FIRE_TOUCH_SOURCE_FAMILY
		)) == 10
		and is_equal_approx(float(mp_game.call(
			"_get_enemy_burn_duration",
			Slime.FIRE_TOUCH_SOURCE_FAMILY
		)), 3.0),
		"多人权威层必须信任火焰史莱姆的3秒10级燃烧参数。"
	)
	mp_game.free()


func _test_elemental_touch_contracts() -> void:
	var burn_scheduler := root.get_node_or_null("BurnStatusScheduler")
	var cold_scheduler := root.get_node_or_null("ColdStatusScheduler")
	_expect(burn_scheduler != null, "燃烧状态调度器必须存在。")
	_expect(cold_scheduler != null, "冰霜状态调度器必须存在。")
	if burn_scheduler == null or cold_scheduler == null:
		return
	burn_scheduler.call("clear_all")
	cold_scheduler.call("clear_all")

	var player := PLAYER_SCENE.instantiate() as Player
	fixture.add_child(player)
	player.set_controls_locked(true)
	player.set_physics_process(false)
	player.current_health = player.max_health
	player.invincibility_time_left = 0.0

	var fire_slime := FIRE_CONFIG.enemy_scene.instantiate() as Slime
	fixture.add_child(fire_slime)
	fire_slime.setup(FIRE_CONFIG, player, null)
	fire_slime.set_physics_process(false)
	fire_slime.touched_player = player
	var health_before_fire := player.current_health
	fire_slime.call("_try_deal_touch_damage")
	var player_burn := burn_scheduler.call(
		"get_source_snapshot",
		player,
		Slime.FIRE_TOUCH_SOURCE_FAMILY
	) as Dictionary
	_expect(
		player.current_health == health_before_fire - 10,
		"火焰史莱姆接触必须造成10点法术伤害。"
	)
	_expect(
		is_equal_approx(float(player_burn.get("time_left", 0.0)), 3.0)
		and int(player_burn.get("tick_damage", 0)) == 10,
		"火焰史莱姆成功命中后必须施加3秒10级燃烧。"
	)

	var plant := PlantDefense.new()
	plant.max_health = 100
	plant.current_health = 100
	fixture.add_child(plant)
	fire_slime.call("_on_touch_damage_applied", plant)
	var plant_burn := burn_scheduler.call(
		"get_source_snapshot",
		plant,
		Slime.FIRE_TOUCH_SOURCE_FAMILY
	) as Dictionary
	_expect(
		is_equal_approx(float(plant_burn.get("time_left", 0.0)), 3.0)
		and int(plant_burn.get("tick_damage", 0)) == 10,
		"火焰史莱姆必须同样能点燃建筑。"
	)

	player.clear_burn_status()
	player.clear_cold_status()
	player.invincibility_time_left = 0.0
	var frost_slime := FROST_CONFIG.enemy_scene.instantiate() as Slime
	fixture.add_child(frost_slime)
	frost_slime.setup(FROST_CONFIG, player, null)
	frost_slime.set_physics_process(false)
	frost_slime.touched_player = player
	var health_before_frost := player.current_health
	frost_slime.call("_try_deal_touch_damage")
	var cold_snapshot := cold_scheduler.call("get_state_snapshot", player) as Dictionary
	_expect(
		player.current_health == health_before_frost - 10,
		"寒冰史莱姆接触必须造成10点法术伤害。"
	)
	_expect(
		int(cold_snapshot.get("stack_count", 0)) == 1
		and is_equal_approx(float(cold_snapshot.get("time_left", 0.0)), 3.0)
		and is_equal_approx(float(cold_snapshot.get("multiplier", 0.0)), 0.75),
		"寒冰史莱姆成功命中后必须施加3秒1级冰霜。"
	)

	burn_scheduler.call("clear_all")
	cold_scheduler.call("clear_all")
	plant.queue_free()
	fire_slime.queue_free()
	frost_slime.queue_free()
	player.queue_free()
	await process_frame


func _test_green_regeneration_contract() -> void:
	var green_slime := GREEN_CONFIG.enemy_scene.instantiate() as GreenSlime
	_expect(green_slime != null, "绿色史莱姆场景必须实例化 GreenSlime。")
	if green_slime == null:
		return
	fixture.add_child(green_slime)
	green_slime.setup(GREEN_CONFIG, null, null)
	green_slime.set_process(false)
	green_slime.set_physics_process(false)
	await process_frame

	var regeneration_timer := green_slime.get_node_or_null(
		"RegenerationTimer"
	) as Timer
	_expect(regeneration_timer != null, "绿色史莱姆必须使用场景内原生 Timer 回血。")
	if regeneration_timer == null:
		green_slime.queue_free()
		await process_frame
		return
	_expect(
		is_equal_approx(
			regeneration_timer.wait_time,
			GreenSlime.REGENERATION_INTERVAL_SECONDS
		)
		and regeneration_timer.process_callback == Timer.TIMER_PROCESS_PHYSICS
		and not regeneration_timer.one_shot
		and not regeneration_timer.is_stopped(),
		"绿色史莱姆回血 Timer 必须每0.5秒按物理帧循环并自动启动。"
	)
	_expect(
		regeneration_timer.timeout.is_connected(
			green_slime._on_regeneration_timer_timeout
		),
		"绿色史莱姆回血 Timer 必须连接到专用超时处理。"
	)
	regeneration_timer.stop()

	green_slime.current_health = 200
	var revision_before_heal := green_slime.health_revision
	green_slime._on_regeneration_timer_timeout()
	_expect(
		green_slime.current_health == 215
		and green_slime.health_revision == revision_before_heal + 1,
		"绿色史莱姆每次必须恢复15生命并推进生命修订号。"
	)
	green_slime.current_health = 295
	green_slime._on_regeneration_timer_timeout()
	var capped_revision := green_slime.health_revision
	green_slime._on_regeneration_timer_timeout()
	_expect(
		green_slime.current_health == GREEN_CONFIG.max_health
		and green_slime.health_revision == capped_revision,
		"绿色史莱姆回血不得超过300，满血空转不得推进修订号。"
	)

	green_slime.current_health = 200
	green_slime.is_multiplayer_proxy = true
	green_slime._on_regeneration_timer_timeout()
	_expect(
		green_slime.current_health == 200,
		"多人代理不得在客户端自行回血。"
	)
	green_slime.is_multiplayer_proxy = false
	green_slime.is_dead = true
	green_slime._on_regeneration_timer_timeout()
	_expect(green_slime.current_health == 200, "死亡绿色史莱姆不得回血。")

	green_slime.queue_free()
	await process_frame


func _get_sheet_image(frames: SpriteFrames) -> Image:
	var texture := frames.get_frame_texture(&"move", 0) as AtlasTexture
	if texture == null or texture.atlas == null:
		return null
	return texture.atlas.get_image()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
