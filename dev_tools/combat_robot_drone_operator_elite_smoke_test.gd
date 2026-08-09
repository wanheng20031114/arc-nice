extends SceneTree

const ELITE_CONFIG := preload(
	"res://resources/config/enemies/combat_robot_drone_operator_elite.tres"
)
const ORDINARY_CONFIG := preload(
	"res://resources/config/enemies/combat_robot_drone_operator.tres"
)
const ELITE_OPERATOR_SCENE := preload(
	"res://scene/enemy/mechanical_life/combat_robot_drone_operator_elite.tscn"
)
const ORDINARY_OPERATOR_SCENE := preload(
	"res://scene/enemy/mechanical_life/combat_robot_drone_operator.tscn"
)
const ELITE_DRONE_SCENE := preload(
	"res://scene/enemy/mechanical_life/combat_robot_suicide_drone_elite.tscn"
)
const ORDINARY_DRONE_SCENE := preload(
	"res://scene/enemy/mechanical_life/combat_robot_suicide_drone.tscn"
)
const DEFAULT_DROP_TABLE := preload(
	"res://resources/config/enemies/default_enemy_drop_table.tres"
)


class MotionSystemDouble:
	extends Node

	var registered: Array[Node] = []

	func register_drone(drone: Node) -> void:
		if not registered.has(drone):
			registered.append(drone)

	func unregister_drone(drone: Node) -> void:
		registered.erase(drone)


var failures: Array[String] = []
var test_root: Node2D


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	test_root = Node2D.new()
	test_root.name = "CombatRobotDroneOperatorEliteSmokeTest"
	root.add_child(test_root)
	current_scene = test_root

	_test_config_contract()
	_test_operator_scene_contract()
	await _test_drone_runtime_contract()
	_test_config_driven_projectile_type()

	current_scene = null
	test_root.queue_free()
	await process_frame
	await physics_frame
	for _cleanup_frame in range(3):
		await process_frame

	if failures.is_empty():
		print("COMBAT_ROBOT_DRONE_OPERATOR_ELITE_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_config_contract() -> void:
	_expect(
		ELITE_CONFIG is CombatRobotDroneOperatorEliteConfig,
		"精英操作员必须使用独立的精英配置类。"
	)
	_expect(
		ELITE_CONFIG is CombatRobotDroneOperatorConfig,
		"精英操作员必须复用普通操作员配置合同。"
	)
	_expect(ELITE_CONFIG.display_name == "精英爆炸无人机操作员", "精英显示名不正确。")
	_expect(ELITE_CONFIG.enemy_scene == ELITE_OPERATOR_SCENE, "精英本体场景绑定错误。")
	_expect(ELITE_CONFIG.drone_scene == ELITE_DRONE_SCENE, "精英无人机场景绑定错误。")
	_expect(ELITE_CONFIG.max_health == 360, "精英生命值必须为360。")
	_expect(ELITE_CONFIG.attack_damage == 100, "接触与无人机攻击快照必须为100。")
	_expect(ELITE_CONFIG.physical_defense == 20, "精英物理防御必须为20。")
	_expect(ELITE_CONFIG.magic_defense == 15, "精英法术防御必须为15。")
	_expect(is_equal_approx(ELITE_CONFIG.move_speed, 40.0), "精英移动速度必须为40。")
	_expect(ELITE_CONFIG.home_damage == 2, "基地伤害必须保持2。")
	_expect(ELITE_CONFIG.xirang_kill_reward == 10, "击杀息壤必须保持10。")
	_expect(ELITE_CONFIG.drop_table == DEFAULT_DROP_TABLE, "必须沿用通用掉落。")
	_expect(
		ELITE_CONFIG.category_tags == PackedStringArray(["mechanical_life"]),
		"精英操作员必须仅属于机械生命。"
	)
	_expect(is_equal_approx(ELITE_CONFIG.attack_range, 80.0), "搜索范围必须保持80。")
	_expect(is_equal_approx(ELITE_CONFIG.stop_distance, 40.0), "停步距离必须保持40。")
	_expect(is_equal_approx(ELITE_CONFIG.deploy_delay, 0.10), "部署延迟必须保持0.10秒。")
	_expect(is_equal_approx(ELITE_CONFIG.attack_cooldown, 2.5), "精英冷却必须为2.5秒。")
	_expect(ELITE_CONFIG.visible_target_check_limit == 4, "可见候选上限必须保持4。")
	_expect(is_equal_approx(ELITE_CONFIG.blocked_retry_interval, 0.35), "遮挡重试必须保持0.35秒。")
	_expect(is_equal_approx(ELITE_CONFIG.drone_speed, 90.0), "精英无人机速度必须为90。")
	_expect(is_equal_approx(ELITE_CONFIG.explosion_radius, 28.0), "爆炸半径必须保持28。")
	_expect(
		ELITE_CONFIG.projectile_type == &"combat_robot_suicide_drone_elite",
		"精英投射物类型必须独立。"
	)
	_expect(
		ORDINARY_CONFIG.projectile_type == &"combat_robot_suicide_drone",
		"普通操作员投射物类型不得被精英配置污染。"
	)


func _test_operator_scene_contract() -> void:
	var elite := ELITE_OPERATOR_SCENE.instantiate() as CombatRobotDroneOperator
	var ordinary := ORDINARY_OPERATOR_SCENE.instantiate() as CombatRobotDroneOperator
	_expect(elite != null and ordinary != null, "普通与精英操作员场景必须能实例化。")
	if elite == null or ordinary == null:
		if elite != null:
			elite.free()
		if ordinary != null:
			ordinary.free()
		return
	_expect(_same_collision_geometry(elite, ordinary), "精英本体必须完全继承普通碰撞几何。")
	var elite_sense := elite.get_node_or_null("AttackSenseArea/CollisionShape2D") as CollisionShape2D
	var ordinary_sense := ordinary.get_node_or_null("AttackSenseArea/CollisionShape2D") as CollisionShape2D
	_expect(
		elite_sense != null
		and ordinary_sense != null
		and elite_sense.shape is CircleShape2D
		and ordinary_sense.shape is CircleShape2D
		and is_equal_approx((elite_sense.shape as CircleShape2D).radius, 80.0)
		and (elite_sense.shape as CircleShape2D).radius
			== (ordinary_sense.shape as CircleShape2D).radius,
		"精英感知圆必须继承普通80像素几何。"
	)
	var sprite := elite.get_node_or_null("AnimatedSprite2D") as AnimatedSprite2D
	_expect(sprite != null and sprite.sprite_frames != null, "精英本体必须绑定独立动画资源。")
	if sprite != null and sprite.sprite_frames != null:
		var contracts := {
			&"move": [8, 14.0, true],
			&"deploy": [3, 30.0, false],
			&"death": [8, 12.0, false],
		}
		for animation_name: StringName in contracts:
			var contract: Array = contracts[animation_name]
			_expect(sprite.sprite_frames.has_animation(animation_name), "缺少%s动画。" % animation_name)
			_expect(sprite.sprite_frames.get_frame_count(animation_name) == contract[0], "%s帧数错误。" % animation_name)
			_expect(is_equal_approx(sprite.sprite_frames.get_animation_speed(animation_name), contract[1]), "%s帧率错误。" % animation_name)
			_expect(sprite.sprite_frames.get_animation_loop(animation_name) == contract[2], "%s循环合同错误。" % animation_name)
	elite.free()
	ordinary.free()


func _test_drone_runtime_contract() -> void:
	var elite := ELITE_DRONE_SCENE.instantiate() as CombatRobotSuicideDrone
	var ordinary := ORDINARY_DRONE_SCENE.instantiate() as CombatRobotSuicideDrone
	_expect(elite != null and ordinary != null, "普通与精英无人机场景必须能实例化。")
	if elite == null or ordinary == null:
		if elite != null:
			elite.free()
		if ordinary != null:
			ordinary.free()
		return
	_expect(
		elite.authored_source_type == &"combat_robot_suicide_drone_elite"
		and ordinary.authored_source_type == &"combat_robot_suicide_drone",
		"普通与精英无人机必须拥有稳定且互不污染的来源类型。"
	)
	var elite_shape := elite.explosion_shape as CircleShape2D
	var ordinary_shape := ordinary.explosion_shape as CircleShape2D
	_expect(
		elite_shape != null
		and ordinary_shape != null
		and is_equal_approx(elite_shape.radius, 28.0)
		and is_equal_approx(ordinary_shape.radius, 28.0),
		"精英无人机必须继承28像素爆炸圆。"
	)
	var elite_frames := (elite.get_node("DroneSprite") as AnimatedSprite2D).sprite_frames
	_expect(
		elite_frames.get_frame_count(&"fly") == 4
		and is_equal_approx(elite_frames.get_animation_speed(&"fly"), 12.0)
		and elite_frames.get_frame_count(&"target") == 4
		and is_equal_approx(elite_frames.get_animation_speed(&"target"), 12.0)
		and elite_frames.get_frame_count(&"explode") == 8
		and is_equal_approx(elite_frames.get_animation_speed(&"explode"), 14.0),
		"精英无人机必须保持4/4/8帧和12/12/14FPS合同。"
	)
	test_root.add_child(elite)
	test_root.add_child(ordinary)
	await process_frame
	_expect(
		elite.source_type == &"combat_robot_suicide_drone_elite"
		and ordinary.source_type == &"combat_robot_suicide_drone",
		"场景_ready必须恢复各自创作来源。"
	)
	_expect(
		not elite.is_processing() and not elite.is_physics_processing(),
		"精英无人机不得新增独立process或physics_process。"
	)
	elite.source_type = &"corrupted_test_source"
	elite.on_pool_released(1)
	_expect(
		elite.source_type == &"combat_robot_suicide_drone_elite",
		"回池时必须恢复精英来源字段。"
	)
	elite.on_pool_acquired(2)
	_expect(
		elite.source_type == &"combat_robot_suicide_drone_elite",
		"再次租用时必须恢复精英来源字段。"
	)

	var motion_system := MotionSystemDouble.new()
	test_root.add_child(motion_system)
	var initial_direction := Vector2(3, 4).normalized()
	var duration := 80.0 / 90.0
	elite.global_position = Vector2(12, -7)
	elite.setup(initial_direction, 100, 90.0, duration, 28.0, motion_system)
	elite.authoritative_damage = false
	_expect(elite.begin_deployment(), "精英无人机必须能注册到共享批量运动系统。")
	var committed_target := Vector2(12, -7) + initial_direction * 80.0
	_expect(
		motion_system.registered == [elite]
		and elite.target_position.is_equal_approx(committed_target)
		and elite.damage == 100
		and is_equal_approx(elite.speed, 90.0)
		and is_equal_approx(elite.max_lifetime, duration),
		"部署时必须一次性锁定80像素落点、100伤害、90速度和固定航时。"
	)
	elite.simulate_compensated_motion(0.10 + duration * 0.5)
	_expect(
		elite.target_position.is_equal_approx(committed_target)
		and elite.target_marker.position.is_equal_approx(initial_direction * 80.0)
		and elite.drone_sprite.position.is_equal_approx(initial_direction * 40.0),
		"elapsed补偿只能沿已提交航线插值，不得重新追踪目标。"
	)
	# The drone is a sibling runtime projectile, not operator-owned state.  Its
	# committed lease therefore survives the operator's death/removal path.
	var operator_source := FileAccess.get_file_as_string(
		"res://scene/enemy/mechanical_life/combat_robot_drone_operator.gd"
	)
	var cancel_start := operator_source.find("func _cancel_operator_state(")
	var cancel_end := operator_source.find(
		"\nfunc play_multiplayer_enemy_action(",
		cancel_start
	)
	var cancel_source := operator_source.substr(
		cancel_start,
		cancel_end - cancel_start
	)
	_expect(
		"active_drone" not in operator_source
		and cancel_start >= 0
		and cancel_end > cancel_start
		and "retire" not in cancel_source
		and "queue_free" not in cancel_source,
		"操作员生命周期不得持有或销毁已经提交的无人机。"
	)
	elite.retire()
	ordinary.queue_free()
	motion_system.queue_free()
	await process_frame


func _test_config_driven_projectile_type() -> void:
	var source := FileAccess.get_file_as_string(
		"res://scene/enemy/mechanical_life/combat_robot_drone_operator.gd"
	)
	_expect(
		"operator_config_cache.projectile_type" in source
		and "const PROJECTILE_TYPE" not in source,
		"普通与精英发包必须只读取配置中的稳定projectile_type。"
	)


func _same_collision_geometry(elite: Node, ordinary: Node) -> bool:
	for path in [NodePath("CollisionShape2D"), NodePath("TouchDamageArea/CollisionShape2D")]:
		var elite_shape := elite.get_node_or_null(path) as CollisionShape2D
		var ordinary_shape := ordinary.get_node_or_null(path) as CollisionShape2D
		if (
			elite_shape == null
			or ordinary_shape == null
			or elite_shape.position != ordinary_shape.position
			or not (elite_shape.shape is RectangleShape2D)
			or not (ordinary_shape.shape is RectangleShape2D)
			or (elite_shape.shape as RectangleShape2D).size
				!= (ordinary_shape.shape as RectangleShape2D).size
		):
			return false
	return true


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
