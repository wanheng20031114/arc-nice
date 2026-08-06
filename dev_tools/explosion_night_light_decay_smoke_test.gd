extends SceneTree

const DAY_NIGHT_CONTROLLER_SCENE := preload(
	"res://scene/lighting/day_night_controller.tscn"
)
const FLASH_POOL_SCENE := preload(
	"res://scene/lighting/night_vfx_flash_pool.tscn"
)
const EXPLOSION_SCENES := [
	"res://scene/enemy/capoo/capoo_rpg_explosion.tscn",
	"res://scene/enemy/capoo/capoo_mage_fireball_impact.tscn",
	"res://scene/player/weishidaier/weishidaier_skill1_explosion.tscn",
	"res://scene/combat/collectibles/collectible_sakura_explosion.tscn",
	"res://scene/boss/linglan/linglan_skill2_sakura_explosion.tscn",
	"res://scene/player/tiyi/tiyi_sniper_hit_effect.tscn",
	"res://scene/plant_defense/bamboo_mortar_shell.tscn",
	"res://scene/enemy/yuanshi_insect/yuanshi_insect_bomber.tscn",
	"res://scene/enemy/yuanshi_insect/yuanshi_insect_purple_bomber.tscn",
]
const WORLD_SCENES := [
	"res://scene/game_modes/standard/standard_game.tscn",
	"res://scene/game_modes/tower_defense/tower_defense_game.tscn",
]
const EXPECTED_DECAY_EXPONENT := 1.8
const ATTACK_SECONDS := 0.04
const HOLD_SECONDS := 0.06
const DECAY_SECONDS := 0.30
const HOLD_END_STRENGTH := 0.78

var failures: PackedStringArray = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	root.size = Vector2i(320, 240)
	root.content_scale_size = Vector2i(320, 240)

	var world := Node2D.new()
	world.name = "ExplosionNightLightDecaySmokeWorld"
	root.add_child(world)

	var controller := (
		DAY_NIGHT_CONTROLLER_SCENE.instantiate() as DayNightController
	)
	world.add_child(controller)
	var pool := FLASH_POOL_SCENE.instantiate() as NightVfxFlashPool
	world.add_child(pool)
	var source := Node2D.new()
	source.name = "ExplosionSource"
	world.add_child(source)
	var camera := Camera2D.new()
	camera.position = Vector2(160.0, 120.0)
	camera.enabled = true
	world.add_child(camera)
	await process_frame
	await process_frame

	_verify_pool_structure(pool)
	_verify_decay_curve(pool)
	_verify_day_night_behavior(controller, pool)
	_verify_pool_budget(pool, source)
	_verify_scene_structure()
	_verify_emission_shader()

	world.queue_free()
	await process_frame
	if failures.is_empty():
		print("EXPLOSION_NIGHT_LIGHT_DECAY_SMOKE_TEST_OK")
		quit(0)
		return
	print(
		"EXPLOSION_NIGHT_LIGHT_DECAY_SMOKE_TEST_FAILED count=%d"
		% failures.size()
	)
	quit(1)


func _verify_pool_structure(pool: NightVfxFlashPool) -> void:
	_expect(pool.get_capacity() == 8, "爆炸闪光池必须固定为8盏真实灯。")
	_expect(pool.get_child_count() == 8, "闪光池场景必须只预置8个槽位。")
	for child in pool.get_children():
		var flash := child as NightVfxFlash2D
		_expect(flash != null, "闪光池槽位必须是NightVfxFlash2D。")
		if flash == null:
			continue
		_expect(not flash.shadow_enabled, "爆炸闪光不得启用昂贵的2D阴影。")
		_expect(not flash.auto_play, "池化闪光不得在待机时自动播放。")
		_expect(not flash.is_processing(), "待机闪光不得占用逐帧处理。")


func _verify_decay_curve(pool: NightVfxFlashPool) -> void:
	var flash := pool.get_child(0) as NightVfxFlash2D
	flash.configure_flash(
		Color.WHITE,
		1.0,
		0.8,
		ATTACK_SECONDS,
		HOLD_SECONDS,
		DECAY_SECONDS
	)
	_expect(
		is_equal_approx(flash.decay_exponent, EXPECTED_DECAY_EXPONENT),
		"爆炸尾光衰减指数必须为1.8。"
	)
	_expect(
		is_equal_approx(flash.get_flash_duration(), 0.40),
		"放缓衰减不得延长闪光总生命周期。"
	)

	var decay_start_time := ATTACK_SECONDS + HOLD_SECONDS
	flash.play_flash(decay_start_time)
	var decay_start_strength := flash.get_emission_strength()
	flash.play_flash(decay_start_time + DECAY_SECONDS * 0.5)
	var midpoint_strength := flash.get_emission_strength()
	flash.play_flash(decay_start_time + DECAY_SECONDS * 0.75)
	var tail_strength := flash.get_emission_strength()

	var expected_midpoint := (
		HOLD_END_STRENGTH * pow(0.5, EXPECTED_DECAY_EXPONENT)
	)
	var expected_tail := (
		HOLD_END_STRENGTH * pow(0.25, EXPECTED_DECAY_EXPONENT)
	)
	var old_midpoint := HOLD_END_STRENGTH * pow(0.5, 2.2)
	var old_tail := HOLD_END_STRENGTH * pow(0.25, 2.2)
	_expect(
		absf(decay_start_strength - HOLD_END_STRENGTH) <= 0.001
		and absf(midpoint_strength - expected_midpoint) <= 0.001
		and absf(tail_strength - expected_tail) <= 0.001,
		"爆炸尾光必须严格遵循1.8指数的平滑衰减曲线。"
	)
	_expect(
		decay_start_strength > midpoint_strength
		and midpoint_strength > tail_strength
		and tail_strength > 0.05,
		"爆炸尾光必须连续减弱，同时在75%衰减点仍可辨识。"
	)
	_expect(
		midpoint_strength >= old_midpoint * 1.30
		and tail_strength >= old_tail * 1.70,
		"新的中后段尾光必须明显慢于旧2.2指数，但不能增加持续时间。"
	)
	flash.stop_flash()


func _verify_day_night_behavior(
	controller: DayNightController,
	pool: NightVfxFlashPool
) -> void:
	_stop_all_flashes(pool)
	controller.set_night_factor_immediate(0.0)
	var accepted := pool.request_flash(
		Vector2(160.0, 120.0),
		Color(1.0, 0.55, 0.22, 1.0),
		1.0,
		0.8,
		ATTACK_SECONDS,
		HOLD_SECONDS,
		DECAY_SECONDS,
		2
	)
	var flash := pool.get_child(0) as NightVfxFlash2D
	_expect(accepted and flash.is_flash_active(), "白天请求仍须推进短暂包络。")
	_expect(
		not flash.enabled and is_zero_approx(flash.energy),
		"白天爆炸真实灯必须完全关闭。"
	)
	controller.set_night_factor_immediate(1.0)
	_expect(
		flash.enabled and flash.energy > 0.0,
		"同一爆炸闪光在夜晚必须照亮周围空间。"
	)
	_stop_all_flashes(pool)


func _verify_pool_budget(pool: NightVfxFlashPool, source: Node) -> void:
	_stop_all_flashes(pool)
	for request_index in range(8):
		_expect(
			pool.request_flash(
				Vector2(120.0 + request_index * 4.0, 120.0),
				Color.WHITE,
				0.8,
				0.35,
				0.01,
				0.02,
				DECAY_SECONDS,
				2
			),
			"可见范围内前8个爆炸都必须获得槽位。"
		)
	_expect(pool.get_active_flash_count() == 8, "活跃真实灯不得超过8盏。")
	_expect(
		not pool.request_flash(
			Vector2(160.0, 120.0),
			Color.WHITE,
			0.8,
			0.35,
			0.01,
			0.02,
			DECAY_SECONDS,
			1
		),
		"低优先级闪光不得抢占满池。"
	)
	_expect(
		pool.request_flash(
			Vector2(160.0, 120.0),
			Color.WHITE,
			1.0,
			0.6,
			0.01,
			0.02,
			DECAY_SECONDS,
			3
		),
		"高优先级爆炸必须能抢占低优先级槽位。"
	)
	_expect(pool.get_active_flash_count() == 8, "抢占后仍只能有8盏真实灯。")
	_expect(
		NightVfxFlashPool.find_for(source) == pool,
		"爆炸必须能在同一世界分支找到共享闪光池。"
	)
	_stop_all_flashes(pool)


func _verify_scene_structure() -> void:
	for scene_path in EXPLOSION_SCENES:
		var instance := _instantiate_scene(scene_path)
		if instance == null:
			continue
		_expect(
			_count_named_emission_overlays(instance) > 0,
			"爆炸/冲击特效缺少不受夜色压暗的发光核心：%s" % scene_path
		)
		_expect(
			_count_point_lights(instance) == 0,
			"爆炸场景必须复用共享池，不能内置常驻灯：%s" % scene_path
		)
		instance.free()

	for scene_path in WORLD_SCENES:
		_expect(
			_packed_scene_has_node(scene_path, &"NightVfxFlashPool"),
			"主世界必须原生预置共享夜间闪光池：%s" % scene_path
		)


func _verify_emission_shader() -> void:
	var shader := load(
		"res://resources/shader/night_vfx_emission_mask.gdshader"
	) as Shader
	_expect(shader != null, "爆炸亮区遮罩shader必须可以加载。")
	if shader == null:
		return
	_expect(
		shader.code.contains("render_mode blend_add, unshaded"),
		"爆炸亮核必须加色且不受CanvasModulate二次压暗。"
	)


func _stop_all_flashes(pool: NightVfxFlashPool) -> void:
	for child in pool.get_children():
		(child as NightVfxFlash2D).stop_flash()


func _instantiate_scene(scene_path: String) -> Node:
	var packed_scene := load(scene_path) as PackedScene
	_expect(packed_scene != null, "无法加载场景：%s" % scene_path)
	if packed_scene == null:
		return null
	return packed_scene.instantiate()


func _packed_scene_has_node(scene_path: String, node_name: StringName) -> bool:
	var packed_scene := load(scene_path) as PackedScene
	if packed_scene == null:
		return false
	var state := packed_scene.get_state()
	for node_index in range(state.get_node_count()):
		if state.get_node_name(node_index) == node_name:
			return true
	return false


func _count_named_emission_overlays(node: Node) -> int:
	var count := 1 if String(node.name).contains("EmissionOverlay") else 0
	for child in node.get_children():
		count += _count_named_emission_overlays(child)
	return count


func _count_point_lights(node: Node) -> int:
	var count := 1 if node is PointLight2D else 0
	for child in node.get_children():
		count += _count_point_lights(child)
	return count


func _expect(condition: bool, message: String) -> void:
	if condition:
		return
	failures.append(message)
	push_error(message)
