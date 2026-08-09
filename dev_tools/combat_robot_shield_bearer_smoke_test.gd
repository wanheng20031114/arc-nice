extends SceneTree

const SHIELD_BEARER_SCENE := preload(
	"res://scene/enemy/mechanical_life/combat_robot_shield_bearer.tscn"
)
const SHIELD_BEARER_CONFIG := preload(
	"res://resources/config/enemies/combat_robot_shield_bearer.tres"
)
const SHIELD_LAYER := 1 << 12
const STAGE_SHIFT := 5


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
	test_root.name = "CombatRobotShieldBearerSmokeTest"
	root.add_child(test_root)
	current_scene = test_root

	_test_resource_and_scene_contract()
	await _test_authoritative_durability_and_actions()
	await _test_facing_and_front_contact()
	await _test_proxy_collision_snapshot_and_action_contract()
	await _test_death_lifecycle()

	current_scene = null
	test_root.queue_free()
	await process_frame
	await physics_frame
	for _cleanup_frame in range(3):
		await process_frame

	if failures.is_empty():
		print("COMBAT_ROBOT_SHIELD_BEARER_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_resource_and_scene_contract() -> void:
	_expect(
		SHIELD_BEARER_CONFIG is CombatRobotShieldBearerConfig,
		"举盾机器人必须使用 CombatRobotShieldBearerConfig。"
	)
	_expect(
		SHIELD_BEARER_CONFIG.display_name == "举盾战斗机器人"
		and SHIELD_BEARER_CONFIG.enemy_scene == SHIELD_BEARER_SCENE,
		"举盾机器人显示名和场景绑定必须保持稳定。"
	)
	_expect(
		SHIELD_BEARER_CONFIG.max_health == 180
		and SHIELD_BEARER_CONFIG.attack_damage == 30
		and SHIELD_BEARER_CONFIG.physical_defense == 25
		and SHIELD_BEARER_CONFIG.magic_defense == 10
		and is_equal_approx(SHIELD_BEARER_CONFIG.move_speed, 30.0)
		and SHIELD_BEARER_CONFIG.home_damage == 2
		and SHIELD_BEARER_CONFIG.xirang_kill_reward == 10,
		"举盾机器人基础属性必须为180/30/25/10/30/2/10。"
	)
	_expect(
		SHIELD_BEARER_CONFIG.category_tags
		== PackedStringArray(["mechanical_life"]),
		"举盾机器人只能属于机械生命。"
	)
	_expect(
		SHIELD_BEARER_CONFIG.shield_max_blocks == 20
		and SHIELD_BEARER_CONFIG.shield_cracked_remaining == 13
		and SHIELD_BEARER_CONFIG.shield_critical_remaining == 6,
		"盾牌阶段必须精确使用20、13、6三个公开阈值。"
	)

	var robot := SHIELD_BEARER_SCENE.instantiate() as CombatRobotShieldBearer
	_expect(robot != null, "举盾机器人场景必须实例化强类型本体。")
	if robot == null:
		return
	var body_shape := robot.get_node_or_null("CollisionShape2D") as CollisionShape2D
	var touch_shape := robot.get_node_or_null(
		"TouchDamageArea/CollisionShape2D"
	) as CollisionShape2D
	var shield_root := robot.get_node_or_null("ShieldFacingRoot") as Node2D
	var shield_area := robot.get_node_or_null(
		"ShieldFacingRoot/ProjectileShieldArea"
	) as ProjectileShieldArea
	var shield_shape := robot.get_node_or_null(
		"ShieldFacingRoot/ProjectileShieldArea/CollisionShape2D"
	) as CollisionShape2D
	var shield_fx := robot.get_node_or_null(
		"ShieldFacingRoot/ShieldFxSprite"
	) as AnimatedSprite2D
	_expect(
		body_shape != null
		and body_shape.shape is RectangleShape2D
		and (body_shape.shape as RectangleShape2D).size == Vector2(8, 16),
		"本体世界碰撞必须保持8×16窄方盒。"
	)
	_expect(
		touch_shape != null
		and touch_shape.shape is RectangleShape2D
		and (touch_shape.shape as RectangleShape2D).size == Vector2(8, 16),
		"接触伤害区域必须保持8×16窄方盒且不包含盾牌。"
	)
	_expect(
		shield_root != null
		and shield_root.position == Vector2(11, 1)
		and shield_root.scale == Vector2.ONE,
		"右向盾牌根节点必须固定在(11,1)。"
	)
	_expect(
		shield_area != null
		and shield_shape != null
		and shield_shape.shape is ConvexPolygonShape2D,
		"盾牌必须是预置的强类型 Area2D 与凸多边形，不得动态创建。"
	)
	if shield_shape != null and shield_shape.shape is ConvexPolygonShape2D:
		_expect(
			(shield_shape.shape as ConvexPolygonShape2D).points
			== PackedVector2Array([
				Vector2(-1, -9),
				Vector2(1, -9),
				Vector2(2, -8),
				Vector2(2, 7),
				Vector2(1, 8),
				Vector2(-2, 8),
				Vector2(-3, 7),
				Vector2(-3, -7),
			]),
			"盾牌凸多边形必须以 ShieldFacingRoot 为局部中心贴合6×18轮廓。"
		)
	_expect(
		shield_fx != null
		and shield_fx.position == Vector2.ZERO
		and not shield_fx.visible
		and shield_fx.sprite_frames.has_animation(&"shield_block")
		and shield_fx.sprite_frames.has_animation(&"shield_break"),
		"盾牌反馈精灵必须预置在盾牌根节点原点并包含格挡/破盾动画。"
	)
	for frames in [
		robot.intact_sprite_frames,
		robot.cracked_sprite_frames,
		robot.critical_sprite_frames,
		robot.broken_sprite_frames,
	]:
		_expect(
			frames != null
			and frames.has_animation(&"move")
			and frames.has_animation(&"death"),
			"盾牌四个阶段都必须提供move/death动画。"
		)
	_expect(
		bool(robot.call("_uses_inherited_touch_damage"))
		and int(robot.call("_get_touch_damage_type"))
		== EnemyConfig.DamageType.PHYSICAL,
		"举盾机器人必须沿用30点物理接触伤害。"
	)
	robot.free()


func _test_authoritative_durability_and_actions() -> void:
	test_root.enemy_actions.clear()
	var robot := _spawn_robot(false)
	var shield_area := robot.projectile_shield_area
	_expect(
		shield_area.is_active()
		and shield_area.collision_layer == SHIELD_LAYER
		and robot.get_shield_remaining_durability() == 20
		and robot.get_shield_visual_stage()
		== CombatRobotShieldBearer.ShieldStage.INTACT,
		"权威本体出生时必须拥有20次完整盾牌和专用碰撞层。"
	)
	_expect(
		not shield_area.try_intercept(Vector2.RIGHT)
		and robot.get_shield_remaining_durability() == 20,
		"从背后沿正向飞行的弹体不得消耗右向盾牌。"
	)

	robot.animated_sprite.set_frame_and_progress(3, 0.4)
	for block_index in range(1, 21):
		_expect(
			shield_area.try_intercept(Vector2.LEFT),
			"第%d次正面命中必须被盾牌拦截。" % block_index
		)
		_expect(
			robot.get_shield_remaining_durability() == 20 - block_index,
			"每次正面拦截必须只消耗1次盾牌耐久。"
		)
		if block_index == 7:
			_expect(
				robot.get_shield_visual_stage()
				== CombatRobotShieldBearer.ShieldStage.CRACKED
				and robot.animated_sprite.sprite_frames
				== robot.cracked_sprite_frames
				and robot.animated_sprite.frame == 3,
				"剩余13次时必须进入开裂阶段且不跳腿部帧。"
			)
		if block_index == 14:
			_expect(
				robot.get_shield_visual_stage()
				== CombatRobotShieldBearer.ShieldStage.CRITICAL
				and robot.animated_sprite.sprite_frames
				== robot.critical_sprite_frames,
				"剩余6次时必须进入危急阶段。"
			)

	_expect(
		robot.get_shield_visual_stage()
		== CombatRobotShieldBearer.ShieldStage.BROKEN
		and robot.animated_sprite.sprite_frames == robot.broken_sprite_frames
		and not shield_area.is_active()
		and shield_area.collision_layer == 0,
		"第20次后盾牌必须永久破碎并立即退出查询层。"
	)
	_expect(
		test_root.enemy_actions.size() == 20,
		"20次格挡必须对应20个且仅20个有序敌人动作。"
	)
	if test_root.enemy_actions.size() == 20:
		for action_index in range(20):
			var action := test_root.enemy_actions[action_index]
			_expect(
				int(action["action_id"]) == action_index + 1,
				"格挡动作ID必须等于累计格挡数。"
			)
			_expect(
				StringName(action["action_name"])
				== (
					&"combat_robot_shield_break"
					if action_index == 19
					else &"combat_robot_shield_block"
				),
				"前19次只能广播block，第20次只能广播break。"
			)
	_expect(
		not shield_area.try_intercept(Vector2.LEFT),
		"破碎盾牌不得继续拦截或产生额外动作。"
	)
	robot.queue_free()
	await process_frame


func _test_facing_and_front_contact() -> void:
	var robot := _spawn_robot(false)
	robot.call("_update_facing", Vector2.LEFT)
	_expect(
		robot.facing_left
		and robot.shield_facing_root.position == Vector2(-11, 1)
		and robot.shield_facing_root.scale == Vector2(-1, 1)
		and robot.projectile_shield_area.get_facing_direction() == Vector2.LEFT,
		"左向时盾牌必须移到(-11,1)并以根节点镜像。"
	)
	_expect(
		robot.projectile_shield_area.try_intercept(Vector2.RIGHT)
		and not robot.projectile_shield_area.try_intercept(Vector2.LEFT),
		"左向盾牌只能拦截从左侧朝右飞入的弹体。"
	)
	robot.queue_free()
	await process_frame


func _test_proxy_collision_snapshot_and_action_contract() -> void:
	var proxy := _spawn_robot(true)
	var shield_area := proxy.projectile_shield_area
	_expect(
		proxy.is_multiplayer_proxy
		and shield_area.is_active()
		and shield_area.collision_layer == SHIELD_LAYER,
		"代理配置后必须同步恢复盾牌查询层，供客户端弹体表现命中。"
	)
	await process_frame
	await physics_frame
	_expect(
		shield_area.monitorable,
		"代理盾牌必须在安全物理边界恢复可查询状态。"
	)
	_expect(
		shield_area.try_intercept(Vector2.LEFT)
		and shield_area.get_remaining_durability() == 20
		and proxy.get_shield_remaining_durability() == 20,
		"代理盾牌只能消费本地弹体表现，不得自行扣除耐久。"
	)

	proxy.play_multiplayer_enemy_action_with_context(
		&"combat_robot_shield_block",
		Vector2.RIGHT,
		Vector2.ZERO,
		7,
		0.0
	)
	_expect(
		proxy.get_shield_remaining_durability() == 13
		and shield_area.get_remaining_durability() == 13
		and proxy.get_shield_visual_stage()
		== CombatRobotShieldBearer.ShieldStage.CRACKED
		and proxy.shield_fx_sprite.visible,
		"跳号到action_id=7必须直接补到剩余13次并播放格挡反馈。"
	)
	proxy.play_multiplayer_enemy_action_with_context(
		&"combat_robot_shield_block",
		Vector2.LEFT,
		Vector2.ZERO,
		6,
		0.0
	)
	_expect(
		proxy.get_shield_remaining_durability() == 13
		and not proxy.facing_left,
		"乱序格挡动作必须连朝向一起丢弃。"
	)

	proxy.apply_multiplayer_visual_status_mask(
		int(CombatRobotShieldBearer.ShieldStage.CRITICAL) << STAGE_SHIFT
	)
	_expect(
		proxy.get_shield_visual_stage()
		== CombatRobotShieldBearer.ShieldStage.CRITICAL
		and proxy.get_shield_remaining_durability() == 6
		and shield_area.is_active()
		and proxy.proxy_snapshot_min_action_id == 14
		and proxy.latest_proxy_action_id == 7,
		"快照高位必须单调推进盾牌阶段，未破盾时保留代理查询碰撞。"
	)
	proxy.apply_multiplayer_visual_status_mask(
		int(CombatRobotShieldBearer.ShieldStage.INTACT) << STAGE_SHIFT
	)
	_expect(
		proxy.get_shield_visual_stage()
		== CombatRobotShieldBearer.ShieldStage.CRITICAL,
		"旧快照不得把已恶化的盾牌重建为完整阶段。"
	)
	proxy.call("_stop_shield_fx")
	proxy.play_multiplayer_enemy_action_with_context(
		&"combat_robot_shield_block",
		Vector2.LEFT,
		Vector2.ZERO,
		8,
		0.0
	)
	_expect(
		proxy.get_shield_remaining_durability() == 6
		and proxy.get_shield_visual_stage()
		== CombatRobotShieldBearer.ShieldStage.CRITICAL
		and proxy.latest_proxy_action_id == 8
		and proxy.proxy_snapshot_min_action_id == 14
		and not proxy.facing_left
		and not proxy.shield_fx_sprite.visible,
		"跨频道晚到的旧block动作不得回退阶段、改朝向或重播陈旧FX。"
	)
	proxy.play_multiplayer_enemy_action_with_context(
		&"combat_robot_shield_block",
		Vector2.LEFT,
		Vector2.ZERO,
		14,
		0.0
	)
	_expect(
		proxy.latest_proxy_action_id == 14
		and proxy.get_shield_remaining_durability() == 6
		and proxy.facing_left
		and proxy.shield_fx_sprite.visible,
		"同阶段里程碑动作即使晚于快照到达，只要仍新鲜就必须补播FX。"
	)
	proxy.call("_stop_shield_fx")
	proxy.play_multiplayer_enemy_action_with_context(
		&"combat_robot_shield_block",
		Vector2.RIGHT,
		Vector2.ZERO,
		15,
		999.0
	)
	_expect(
		proxy.latest_proxy_action_id == 15
		and proxy.get_shield_remaining_durability() == 5
		and proxy.facing_left
		and not proxy.shield_fx_sprite.visible,
		"过期block动作只能单调修复耐久，不得改朝向或从头播放FX。"
	)
	proxy.set_multiplayer_proxy_visual_active(false)
	proxy.play_multiplayer_enemy_action_with_context(
		&"combat_robot_shield_block",
		Vector2.RIGHT,
		Vector2.ZERO,
		16,
		0.0
	)
	_expect(
		proxy.latest_proxy_action_id == 16
		and proxy.get_shield_remaining_durability() == 4
		and not proxy.facing_left
		and not proxy.shield_fx_sprite.visible,
		"离屏代理仍必须接收新鲜动作朝向以维持被动盾面，仅跳过FX播放。"
	)
	proxy.set_multiplayer_proxy_visual_active(true)

	proxy.play_multiplayer_enemy_action_with_context(
		&"combat_robot_shield_break",
		Vector2.RIGHT,
		Vector2.ZERO,
		20,
		999.0
	)
	_expect(
		proxy.get_shield_remaining_durability() == 0
		and shield_area.get_remaining_durability() == 0
		and not shield_area.is_active()
		and proxy.get_shield_visual_stage()
		== CombatRobotShieldBearer.ShieldStage.BROKEN
		and not proxy.shield_fx_sprite.visible,
		"过期break动作仍必须落地破盾状态，但跳过已过期的短暂特效。"
	)
	proxy.queue_free()
	await process_frame

	var snapshot_first_proxy := _spawn_robot(true)
	snapshot_first_proxy.apply_multiplayer_visual_status_mask(
		int(CombatRobotShieldBearer.ShieldStage.BROKEN) << STAGE_SHIFT
	)
	_expect(
		snapshot_first_proxy.get_shield_visual_stage()
		== CombatRobotShieldBearer.ShieldStage.BROKEN
		and snapshot_first_proxy.proxy_snapshot_min_action_id == 20
		and snapshot_first_proxy.latest_proxy_action_id == 0,
		"先到的破盾快照必须只推进状态下限，不得冒充已播放动作。"
	)
	snapshot_first_proxy.play_multiplayer_enemy_action_with_context(
		&"combat_robot_shield_break",
		Vector2.LEFT,
		Vector2.ZERO,
		20,
		0.0
	)
	_expect(
		snapshot_first_proxy.latest_proxy_action_id == 20
		and snapshot_first_proxy.facing_left
		and snapshot_first_proxy.shield_fx_sprite.visible
		and snapshot_first_proxy.shield_fx_sprite.animation == &"shield_break",
		"新鲜break动作晚于BROKEN快照到达时仍必须补播一次破盾反馈。"
	)
	snapshot_first_proxy.queue_free()
	await process_frame


func _test_death_lifecycle() -> void:
	var robot := _spawn_robot(false)
	robot.call("_die")
	_expect(
		robot.is_dead
		and not robot.projectile_shield_area.is_active()
		and robot.projectile_shield_area.collision_layer == 0
		and robot.animated_sprite.animation == &"death",
		"死亡必须先关闭盾牌查询与反馈，再播放当前阶段死亡动画。"
	)
	robot.queue_free()
	await process_frame

	var proxy := _spawn_robot(true)
	var death_stage_frames := proxy.animated_sprite.sprite_frames
	proxy.play_multiplayer_death_sequence()
	proxy.apply_multiplayer_visual_status_mask(
		int(CombatRobotShieldBearer.ShieldStage.BROKEN) << STAGE_SHIFT
	)
	_expect(
		proxy.is_dead
		and proxy.get_shield_visual_stage()
		== CombatRobotShieldBearer.ShieldStage.INTACT
		and proxy.animated_sprite.sprite_frames == death_stage_frames
		and proxy.animated_sprite.animation == &"death",
		"死亡后的迟到盾态快照不得中途替换已开始的死亡套图。"
	)
	proxy.queue_free()
	await process_frame


func _spawn_robot(as_proxy: bool) -> CombatRobotShieldBearer:
	var robot := SHIELD_BEARER_SCENE.instantiate() as CombatRobotShieldBearer
	test_root.add_child(robot)
	robot.setup(SHIELD_BEARER_CONFIG, null, null)
	robot.bind_gameplay_gateway(test_root)
	robot.set_meta(&"net_id", 7001)
	if as_proxy:
		robot.configure_multiplayer_proxy()
	return robot


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
