extends SceneTree

const ELITE_SCENE := preload(
	"res://scene/enemy/mechanical_life/combat_robot_ninja_elite.tscn"
)
const ELITE_CONFIG := preload(
	"res://resources/config/enemies/combat_robot_ninja_elite.tres"
)
const ORDINARY_SCENE := preload(
	"res://scene/enemy/mechanical_life/combat_robot_ninja.tscn"
)
const DEFAULT_DROP_TABLE := preload(
	"res://resources/config/enemies/default_enemy_drop_table.tres"
)
const BOOST_STATUS_MASK := 1 << 5


class EnemyActionRecorder:
	extends MultiplayerGameplayGateway

	var enemy_actions: Array[Dictionary] = []


	func broadcast_enemy_action(
		net_id: int,
		action_name: StringName,
		direction: Vector2,
		action_position: Vector2,
		action_id: int
	) -> void:
		enemy_actions.append({
			"net_id": net_id,
			"action_name": action_name,
			"direction": direction,
			"action_position": action_position,
			"action_id": action_id,
		})


var failures: Array[String] = []
var test_root: EnemyActionRecorder


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	test_root = EnemyActionRecorder.new()
	test_root.name = "CombatRobotNinjaEliteCoreSmokeTest"
	root.add_child(test_root)
	current_scene = test_root

	_test_config_scene_animation_and_geometry()
	await _test_authoritative_boost_and_modifiers()
	await _test_batch_and_dot_trigger_contract()
	await _test_invalid_lethal_and_proxy_rejection()
	await _test_proxy_snapshot_action_and_cleanup()
	await _test_shared_afterimage_material_contract()

	var scheduler := root.get_node_or_null("EnemyCollectibleStatusScheduler")
	if scheduler != null:
		scheduler.call("clear_all")
	current_scene = null
	test_root.queue_free()
	await process_frame
	await physics_frame
	for _cleanup_frame in range(3):
		await process_frame

	if failures.is_empty():
		print("COMBAT_ROBOT_NINJA_ELITE_CORE_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_config_scene_animation_and_geometry() -> void:
	_expect(
		ELITE_CONFIG is CombatRobotNinjaEliteConfig
		and ELITE_CONFIG is CombatRobotNinjaConfig,
		"精英忍者配置必须继承 CombatRobotNinjaConfig。"
	)
	_expect(
		ELITE_CONFIG.display_name == "精英忍者战斗机器人"
		and ELITE_CONFIG.enemy_scene == ELITE_SCENE
		and ELITE_CONFIG.max_health == 360
		and ELITE_CONFIG.attack_damage == 70
		and ELITE_CONFIG.physical_defense == 20
		and ELITE_CONFIG.magic_defense == 20
		and is_equal_approx(ELITE_CONFIG.move_speed, 80.0)
		and ELITE_CONFIG.home_damage == 2
		and ELITE_CONFIG.xirang_kill_reward == 10,
		"精英忍者属性必须为360/70/20/20/80/2/10。"
	)
	_expect(
		ELITE_CONFIG.boost_animation_name == &"boost"
		and is_equal_approx(ELITE_CONFIG.boost_speed_multiplier, 2.0)
		and is_equal_approx(ELITE_CONFIG.boost_duration, 0.5)
		and is_equal_approx(ELITE_CONFIG.boost_cooldown, 2.0),
		"精英受击加速必须为2倍、0.5秒持续、2秒冷却，峰值160。"
	)
	_expect(
		ELITE_CONFIG.category_tags == PackedStringArray(["mechanical_life"])
		and ELITE_CONFIG.drop_table == DEFAULT_DROP_TABLE,
		"精英忍者只能属于机械生命并沿用通用掉落。"
	)

	var elite := _spawn_ninja(false)
	var ordinary := ORDINARY_SCENE.instantiate() as CombatRobotNinja
	test_root.add_child(ordinary)
	ordinary.setup(
		load("res://resources/config/enemies/combat_robot_ninja.tres"),
		null,
		null
	)
	elite.set_physics_process(false)
	ordinary.set_physics_process(false)
	_expect(
		elite.animated_sprite.sprite_frames.get_frame_count(&"move") == 8
		and elite.animated_sprite.sprite_frames.get_animation_speed(&"move") == 20.0
		and elite.animated_sprite.sprite_frames.get_animation_loop(&"move")
		and elite.animated_sprite.sprite_frames.get_frame_count(&"boost") == 8
		and elite.animated_sprite.sprite_frames.get_animation_speed(&"boost") == 24.0
		and elite.animated_sprite.sprite_frames.get_animation_loop(&"boost")
		and elite.animated_sprite.sprite_frames.get_frame_count(&"death") == 8
		and elite.animated_sprite.sprite_frames.get_animation_speed(&"death") == 12.0
		and not elite.animated_sprite.sprite_frames.get_animation_loop(&"death"),
		"精英图集必须暴露move/boost/death各8帧，FPS为20/24/12。"
	)
	_compare_collision_geometry(elite, ordinary)
	_expect(
		bool(elite.call("_uses_inherited_touch_damage"))
		and int(elite.call("_get_touch_damage_type"))
		== EnemyConfig.DamageType.PHYSICAL,
		"精英忍者必须沿用70点物理接触伤害入口。"
	)
	elite.queue_free()
	ordinary.queue_free()


func _compare_collision_geometry(
	elite: CombatRobotNinja,
	ordinary: CombatRobotNinja
) -> void:
	var paths := [
		"CollisionShape2D",
		"TouchDamageArea/CollisionShape2D",
		"TouchDamageArea/MoveRearBladeCollisionShape2D",
		"TouchDamageArea/MoveFrontBladeCollisionShape2D",
		"TouchDamageArea/BoostUpperBladeCollisionShape2D",
		"TouchDamageArea/BoostLowerBladeCollisionShape2D",
	]
	for path in paths:
		var elite_shape := elite.get_node(path) as CollisionShape2D
		var ordinary_shape := ordinary.get_node(path) as CollisionShape2D
		var same_shape := (
			elite_shape.position == ordinary_shape.position
			and is_equal_approx(elite_shape.rotation, ordinary_shape.rotation)
			and elite_shape.disabled == ordinary_shape.disabled
			and elite_shape.shape.get_class() == ordinary_shape.shape.get_class()
		)
		if elite_shape.shape is RectangleShape2D:
			same_shape = same_shape and (
				(elite_shape.shape as RectangleShape2D).size
				== (ordinary_shape.shape as RectangleShape2D).size
			)
		elif elite_shape.shape is ConvexPolygonShape2D:
			same_shape = same_shape and (
				(elite_shape.shape as ConvexPolygonShape2D).points
				== (ordinary_shape.shape as ConvexPolygonShape2D).points
			)
		_expect(same_shape, "精英忍者碰撞几何必须逐项继承普通版：%s。" % path)
	_expect(
		(elite.get_node("CollisionShape2D") as CollisionShape2D).shape
		is RectangleShape2D
		and (
			(elite.get_node("CollisionShape2D") as CollisionShape2D).shape
			as RectangleShape2D
		).size == Vector2(8, 17),
		"世界碰撞必须继续只有8×17身体，双刃不得撞墙。"
	)


func _test_authoritative_boost_and_modifiers() -> void:
	test_root.enemy_actions.clear()
	var ninja := _spawn_ninja(false)
	ninja.set_meta(&"net_id", 7601)
	ninja.set_physics_process(false)
	ninja.animated_sprite.set_frame_and_progress(3, 0.25)
	# 7602模拟寒冷，7603模拟独立全局倍率；加速必须动态乘在乘积之后。
	ninja.add_move_speed_modifier(7602, 0.5)
	ninja.add_move_speed_modifier(7603, 1.25)
	_expect(is_equal_approx(ninja.get_effective_move_speed(), 50.0), "寒冷与全局倍率必须相乘。")
	var accepted := ninja.apply_damage(
		30,
		Vector2.LEFT,
		EnemyConfig.DamageType.PHYSICAL,
		false
	)
	_expect(
		accepted
		and ninja.current_health == 350
		and ninja.is_damage_boost_active()
		and ninja.is_damage_boost_on_cooldown()
		and is_equal_approx(ninja.get_effective_move_speed(), 100.0),
		"非致死实际扣血必须同帧触发当前有效速度×2。"
	)
	_expect(
		ninja.animated_sprite.animation == &"boost"
		and ninja.animated_sprite.frame == 3
		and is_equal_approx(ninja.animated_sprite.frame_progress, 0.25)
		and ninja.boost_timer.time_left > 0.45
		and ninja.cooldown_timer.time_left > 1.9,
		"加速必须保留腿相并启动0.5/2秒物理Timer。"
	)
	_expect(
		(ninja.get_collectible_visual_status_mask() & BOOST_STATUS_MASK) != 0
		and test_root.enemy_actions.size() == 1
		and test_root.enemy_actions[0]["action_name"] == &"combat_robot_ninja_boost"
		and test_root.enemy_actions[0]["action_id"] == 1,
		"Host必须唯一写bit5并广播有序boost动作。"
	)
	var boost_left := ninja.boost_timer.time_left
	var cooldown_left := ninja.cooldown_timer.time_left
	ninja.apply_damage(30, Vector2.RIGHT, EnemyConfig.DamageType.PHYSICAL, false)
	_expect(
		test_root.enemy_actions.size() == 1
		and is_equal_approx(ninja.boost_timer.time_left, boost_left)
		and is_equal_approx(ninja.cooldown_timer.time_left, cooldown_left),
		"持续/冷却期间受击不得刷新、排队或重复广播。"
	)
	ninja.remove_move_speed_modifier(7602)
	ninja.remove_move_speed_modifier(7603)
	_expect(is_equal_approx(ninja.get_effective_move_speed(), 160.0), "无修正加速峰值必须为160。")
	ninja.call("_on_boost_timer_timeout")
	_expect(
		not ninja.is_damage_boost_active()
		and ninja.is_damage_boost_on_cooldown()
		and is_equal_approx(ninja.get_effective_move_speed(), 80.0)
		and (ninja.get_collectible_visual_status_mask() & BOOST_STATUS_MASK) == 0,
		"0.5秒结束必须只结束加速并保持2秒冷却。"
	)
	ninja.apply_damage(30, Vector2.ZERO, EnemyConfig.DamageType.PHYSICAL, false)
	_expect(not ninja.is_damage_boost_active(), "冷却期扣血不得排队下一次加速。")
	ninja.call("_on_cooldown_timer_timeout")
	ninja.apply_damage(30, Vector2.ZERO, EnemyConfig.DamageType.PHYSICAL, false)
	_expect(
		ninja.is_damage_boost_active()
		and test_root.enemy_actions.size() == 2
		and test_root.enemy_actions[-1]["action_id"] == 2,
		"2秒冷却结束后的下一次扣血必须触发新动作。"
	)
	ninja.queue_free()
	await process_frame


func _test_batch_and_dot_trigger_contract() -> void:
	test_root.enemy_actions.clear()
	var batched := _spawn_ninja(false)
	batched.set_physics_process(false)
	var accepted := batched.apply_damage_batch(
		PackedInt64Array([30, 25]),
		PackedInt32Array([2, 1]),
		Vector2.RIGHT,
		EnemyConfig.DamageType.PHYSICAL,
		false
	)
	_expect(
		accepted
		and batched.current_health == 335
		and batched.last_damage_result.accepted_hit_count == 3
		and batched.is_damage_boost_active()
		and test_root.enemy_actions.size() == 1,
		"一次三击批量结算必须扣25点且只触发一次boost。"
	)
	batched.queue_free()
	await process_frame

	var scheduler := root.get_node_or_null("EnemyCollectibleStatusScheduler")
	_expect(scheduler != null, "DoT专项验收需要全局状态调度器。")
	if scheduler == null:
		return
	scheduler.call("clear_all")
	test_root.enemy_actions.clear()
	var dot_ninja := _spawn_ninja(false)
	dot_ninja.set_physics_process(false)
	dot_ninja.apply_collectible_status(
		&"bleed",
		7604,
		1.1,
		30,
		0.5,
		EnemyConfig.DamageType.PHYSICAL
	)
	_expect(not dot_ninja.is_damage_boost_active(), "仅施加DoT不得提前触发。")
	scheduler.call("advance_for_test", 0.5)
	_expect(
		dot_ninja.current_health == 350
		and dot_ninja.is_damage_boost_active()
		and test_root.enemy_actions.size() == 1,
		"真实DoT扣血必须触发一次boost。"
	)
	var time_left := dot_ninja.boost_timer.time_left
	scheduler.call("advance_for_test", 0.5)
	_expect(
		dot_ninja.current_health == 340
		and test_root.enemy_actions.size() == 1
		and is_equal_approx(dot_ninja.boost_timer.time_left, time_left),
		"持续期间后续DoT应扣血但不得刷新或排队。"
	)
	dot_ninja.queue_free()
	await process_frame
	scheduler.call("clear_all")


func _test_invalid_lethal_and_proxy_rejection() -> void:
	test_root.enemy_actions.clear()
	var invalid := _spawn_ninja(false)
	var invalid_result := invalid.apply_combat_damage(null)
	_expect(
		not invalid_result.accepted
		and not invalid.is_damage_boost_active()
		and test_root.enemy_actions.is_empty(),
		"无效伤害不得触发。"
	)
	invalid.queue_free()
	await process_frame

	var lethal := _spawn_ninja(false)
	lethal.apply_damage(9999, Vector2.LEFT, EnemyConfig.DamageType.PHYSICAL, false)
	_expect(
		lethal.is_dead
		and not lethal.is_damage_boost_active()
		and lethal.boost_timer.is_stopped()
		and lethal.cooldown_timer.is_stopped(),
		"致死伤害不得启动boost，死亡必须清理Timer。"
	)
	lethal.queue_free()
	await process_frame

	var proxy := _spawn_ninja(true)
	var proxy_result := proxy.apply_combat_damage(
		DamageRequest.new(999, EnemyConfig.DamageType.PHYSICAL)
	)
	_expect(
		not proxy_result.accepted
		and not proxy.is_damage_boost_active()
		and test_root.enemy_actions.is_empty(),
		"代理端必须零伤害、零触发、零广播。"
	)
	proxy.queue_free()
	await process_frame


func _test_proxy_snapshot_action_and_cleanup() -> void:
	var proxy := _spawn_ninja(true)
	proxy.velocity = Vector2(60, 80)
	proxy.apply_multiplayer_visual_status_mask(BOOST_STATUS_MASK)
	var direction: Vector2 = proxy.animated_sprite.get_instance_shader_parameter(
		&"ninja_afterimage_direction"
	)
	_expect(
		proxy.is_damage_boost_active()
		and proxy.animated_sprite.animation == &"boost"
		and direction.is_equal_approx(Vector2(0.6, 0.8)),
		"bit5快照必须按真实斜向速度修复尾影。"
	)
	var snapshot_left := proxy.boost_timer.time_left
	proxy.apply_multiplayer_visual_status_mask(BOOST_STATUS_MASK)
	_expect(
		is_equal_approx(proxy.boost_timer.time_left, snapshot_left),
		"重复bit5快照不得延长效果。"
	)
	proxy.call("_on_boost_timer_timeout")
	proxy.apply_multiplayer_visual_status_mask(BOOST_STATUS_MASK)
	_expect(not proxy.is_damage_boost_active(), "未观察到bit5下降前旧快照不得重启。")
	proxy.apply_multiplayer_visual_status_mask(0)
	proxy.play_multiplayer_enemy_action_with_context(
		&"combat_robot_ninja_boost",
		Vector2.RIGHT,
		Vector2.ZERO,
		7,
		0.2
	)
	_expect(
		proxy.is_damage_boost_active()
		and proxy.latest_proxy_action_id == 7
		and proxy.animated_sprite.frame == 4
		and is_equal_approx(proxy.animated_sprite.frame_progress, 0.8)
		and proxy.boost_timer.time_left > 0.29
		and proxy.boost_timer.time_left <= 0.3,
		"代理动作必须按elapsed补到24FPS的4.8帧并保留0.3秒。"
	)
	var action_left := proxy.boost_timer.time_left
	proxy.play_multiplayer_enemy_action_with_context(
		&"combat_robot_ninja_boost", Vector2.LEFT, Vector2.ZERO, 7, 0.0
	)
	proxy.play_multiplayer_enemy_action_with_context(
		&"combat_robot_ninja_boost", Vector2.LEFT, Vector2.ZERO, 6, 0.0
	)
	_expect(
		is_equal_approx(proxy.boost_timer.time_left, action_left)
		and proxy.latest_proxy_action_id == 7,
		"重复与乱序动作不得刷新或回退。"
	)
	proxy.play_multiplayer_death_sequence()
	_expect(
		proxy.is_dead
		and not proxy.is_damage_boost_active()
		and proxy.boost_timer.is_stopped()
		and proxy.cooldown_timer.is_stopped()
		and proxy.animated_sprite.material == null,
		"代理死亡必须立即清理bit5、Timer与尾影。"
	)
	await physics_frame
	_expect(
		_all_blades_disabled(proxy),
		"代理死亡必须在物理安全延迟点禁用全部刀刃接触。"
	)
	proxy.queue_free()
	await process_frame


func _test_shared_afterimage_material_contract() -> void:
	var first := _spawn_ninja(false)
	var second := _spawn_ninja(false)
	first.set_physics_process(false)
	second.set_physics_process(false)
	_expect(
		first.status_visual_material != null
		and first.status_visual_material == second.status_visual_material
		and first.status_visual_material.shader == second.status_visual_material.shader
		and not first.status_visual_material.resource_local_to_scene
		and first.animated_sprite.material == null
		and second.animated_sprite.material == null,
		"所有精英忍者必须缓存同一共享原色状态材质，闲置时不挂载。"
	)
	first.apply_damage(30, Vector2.RIGHT, EnemyConfig.DamageType.PHYSICAL, false)
	_expect(
		first.animated_sprite.material == first.status_visual_material
		and second.animated_sprite.material == null
		and first.status_visual_material == second.status_visual_material
		and is_equal_approx(float(first.animated_sprite.get_instance_shader_parameter(
			&"ninja_afterimage_strength"
		)), 1.0),
		"尾影必须仅用per-instance参数，不复制或污染另一个实例的材质。"
	)
	first.call("_on_boost_timer_timeout")
	_expect(first.animated_sprite.material == null, "无其他状态时boost结束必须卸载共享材质。")
	first.queue_free()
	second.queue_free()
	await process_frame


func _spawn_ninja(proxy: bool) -> CombatRobotNinja:
	var ninja := ELITE_SCENE.instantiate() as CombatRobotNinja
	test_root.add_child(ninja)
	ninja.setup(ELITE_CONFIG, null, null)
	ninja.bind_gameplay_gateway(test_root)
	if proxy:
		ninja.configure_multiplayer_proxy()
	return ninja


func _all_blades_disabled(ninja: CombatRobotNinja) -> bool:
	return (
		ninja.move_rear_blade_shape.disabled
		and ninja.move_front_blade_shape.disabled
		and ninja.boost_upper_blade_shape.disabled
		and ninja.boost_lower_blade_shape.disabled
	)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
