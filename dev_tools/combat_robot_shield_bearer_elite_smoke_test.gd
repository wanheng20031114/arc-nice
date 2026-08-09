extends SceneTree

const ELITE_SCENE := preload(
	"res://scene/enemy/mechanical_life/combat_robot_shield_bearer_elite.tscn"
)
const ELITE_CONFIG := preload(
	"res://resources/config/enemies/combat_robot_shield_bearer_elite.tres"
)
const ORDINARY_SCENE := preload(
	"res://scene/enemy/mechanical_life/combat_robot_shield_bearer.tscn"
)
const DEFAULT_DROP_TABLE := preload(
	"res://resources/config/enemies/default_enemy_drop_table.tres"
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
	test_root.name = "CombatRobotShieldBearerEliteSmokeTest"
	root.add_child(test_root)
	current_scene = test_root

	_test_config_scene_and_geometry()
	await _test_authoritative_49_50_51_boundary()
	await _test_proxy_stage_action_contract()
	await _test_death_cleanup()

	current_scene = null
	test_root.queue_free()
	await process_frame
	await physics_frame
	for _cleanup_frame in range(3):
		await process_frame

	if failures.is_empty():
		print("COMBAT_ROBOT_SHIELD_BEARER_ELITE_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_config_scene_and_geometry() -> void:
	_expect(
		ELITE_CONFIG is CombatRobotShieldBearerEliteConfig
		and ELITE_CONFIG is CombatRobotShieldBearerConfig,
		"精英盾兵配置必须强类型继承普通盾兵配置。"
	)
	_expect(
		ELITE_CONFIG.display_name == "精英举盾战斗机器人"
		and ELITE_CONFIG.enemy_scene == ELITE_SCENE,
		"精英盾兵显示名和场景绑定不正确。"
	)
	_expect(
		ELITE_CONFIG.max_health == 400
		and ELITE_CONFIG.attack_damage == 60
		and ELITE_CONFIG.physical_defense == 35
		and ELITE_CONFIG.magic_defense == 20
		and is_equal_approx(ELITE_CONFIG.move_speed, 40.0)
		and ELITE_CONFIG.home_damage == 2
		and ELITE_CONFIG.xirang_kill_reward == 10,
		"精英盾兵属性必须为400/60/35/20/40/2/10。"
	)
	_expect(
		ELITE_CONFIG.shield_max_blocks == 50
		and ELITE_CONFIG.shield_cracked_remaining == 33
		and ELITE_CONFIG.shield_critical_remaining == 16,
		"精英盾牌必须使用50/33/16耐久合同。"
	)
	_expect(
		ELITE_CONFIG.category_tags == PackedStringArray(["mechanical_life"])
		and ELITE_CONFIG.drop_table == DEFAULT_DROP_TABLE,
		"精英盾兵只能属于机械生命并沿用通用掉落。"
	)

	var elite := ELITE_SCENE.instantiate() as CombatRobotShieldBearer
	var ordinary := ORDINARY_SCENE.instantiate() as CombatRobotShieldBearer
	_expect(elite != null and ordinary != null, "普通/精英盾兵场景必须可强类型实例化。")
	if elite == null or ordinary == null:
		if elite != null:
			elite.free()
		if ordinary != null:
			ordinary.free()
		return

	_compare_geometry(elite, ordinary)
	_expect(
		bool(elite.call("_uses_inherited_touch_damage"))
		and int(elite.call("_get_touch_damage_type"))
		== EnemyConfig.DamageType.PHYSICAL,
		"精英盾兵必须沿用每0.5秒一次的60点物理接触伤害入口。"
	)
	for frames in [
		elite.intact_sprite_frames,
		elite.cracked_sprite_frames,
		elite.critical_sprite_frames,
		elite.broken_sprite_frames,
	]:
		_expect(
			frames != null
			and frames.get_frame_count(&"move") == 8
			and frames.get_animation_speed(&"move") == 14.0
			and frames.get_animation_loop(&"move")
			and frames.get_frame_count(&"death") == 8
			and frames.get_animation_speed(&"death") == 12.0
			and not frames.get_animation_loop(&"death"),
			"精英盾兵四个阶段都必须提供8帧move/death动画合同。"
		)
	var elite_fx := elite.get_node_or_null("ShieldFacingRoot/ShieldFxSprite") as AnimatedSprite2D
	_expect(
		elite_fx != null
		and elite_fx.sprite_frames.get_frame_count(&"shield_block") == 3
		and elite_fx.sprite_frames.get_animation_speed(&"shield_block") == 24.0
		and elite_fx.sprite_frames.get_frame_count(&"shield_break") == 5
		and elite_fx.sprite_frames.get_animation_speed(&"shield_break") == 18.0,
		"精英盾击B1和破盾X1必须保持3@24与5@18合同。"
	)
	elite.free()
	ordinary.free()


func _compare_geometry(
	elite: CombatRobotShieldBearer,
	ordinary: CombatRobotShieldBearer
) -> void:
	var elite_body := elite.get_node("CollisionShape2D") as CollisionShape2D
	var ordinary_body := ordinary.get_node("CollisionShape2D") as CollisionShape2D
	var elite_touch := elite.get_node(
		"TouchDamageArea/CollisionShape2D"
	) as CollisionShape2D
	var ordinary_touch := ordinary.get_node(
		"TouchDamageArea/CollisionShape2D"
	) as CollisionShape2D
	var elite_root := elite.get_node("ShieldFacingRoot") as Node2D
	var ordinary_root := ordinary.get_node("ShieldFacingRoot") as Node2D
	var elite_area := elite.get_node(
		"ShieldFacingRoot/ProjectileShieldArea"
	) as ProjectileShieldArea
	var ordinary_area := ordinary.get_node(
		"ShieldFacingRoot/ProjectileShieldArea"
	) as ProjectileShieldArea
	var elite_shape := elite.get_node(
		"ShieldFacingRoot/ProjectileShieldArea/CollisionShape2D"
	) as CollisionShape2D
	var ordinary_shape := ordinary.get_node(
		"ShieldFacingRoot/ProjectileShieldArea/CollisionShape2D"
	) as CollisionShape2D
	_expect(
		elite_body.position == ordinary_body.position
		and elite_body.shape is RectangleShape2D
		and ordinary_body.shape is RectangleShape2D
		and (elite_body.shape as RectangleShape2D).size
		== (ordinary_body.shape as RectangleShape2D).size
		and (elite_body.shape as RectangleShape2D).size == Vector2(8, 16),
		"精英本体世界碰撞必须与普通盾兵逐项一致。"
	)
	_expect(
		elite_touch.position == ordinary_touch.position
		and elite_touch.shape is RectangleShape2D
		and ordinary_touch.shape is RectangleShape2D
		and (elite_touch.shape as RectangleShape2D).size
		== (ordinary_touch.shape as RectangleShape2D).size
		and (elite_touch.shape as RectangleShape2D).size == Vector2(8, 16),
		"精英接触区不得因盾牌扩大。"
	)
	_expect(
		elite_root.position == ordinary_root.position
		and elite_root.position == Vector2(11, 1)
		and elite_root.scale == ordinary_root.scale
		and elite_area.collision_layer == ordinary_area.collision_layer
		and elite_area.collision_mask == ordinary_area.collision_mask
		and elite_area.monitoring == ordinary_area.monitoring
		and elite_area.monitorable == ordinary_area.monitorable,
		"精英盾根和被动物理层必须与普通盾兵相同。"
	)
	_expect(
		elite_shape.position == ordinary_shape.position
		and elite_shape.shape is ConvexPolygonShape2D
		and ordinary_shape.shape is ConvexPolygonShape2D
		and (elite_shape.shape as ConvexPolygonShape2D).points
		== (ordinary_shape.shape as ConvexPolygonShape2D).points
		and (elite_shape.shape as ConvexPolygonShape2D).points.size() == 8,
		"精英盾牌必须逐点复用普通8顶点凸多边形。"
	)


func _test_authoritative_49_50_51_boundary() -> void:
	test_root.enemy_actions.clear()
	var robot := _spawn_robot(false)
	var shield := robot.projectile_shield_area
	_expect(
		shield.is_active()
		and shield.collision_layer == SHIELD_LAYER
		and robot.get_shield_remaining_durability() == 50
		and robot.get_shield_visual_stage()
		== CombatRobotShieldBearer.ShieldStage.INTACT,
		"权威精英盾兵出生时必须拥有50次完整盾牌。"
	)
	_expect(
		not shield.try_intercept(Vector2.RIGHT)
		and robot.get_shield_remaining_durability() == 50,
		"背后命中不得消耗精英盾牌。"
	)

	robot.animated_sprite.set_frame_and_progress(5, 0.35)
	for block_index in range(1, 51):
		_expect(
			shield.try_intercept(Vector2.LEFT),
			"第%d发正面弹体必须完整格挡。" % block_index
		)
		_expect(
			robot.get_shield_remaining_durability() == 50 - block_index,
			"第%d发必须且只能扣除1次盾牌耐久。" % block_index
		)
		if block_index == 17:
			_expect(
				robot.get_shield_visual_stage()
				== CombatRobotShieldBearer.ShieldStage.CRACKED
				and robot.get_shield_remaining_durability() == 33
				and robot.animated_sprite.sprite_frames == robot.cracked_sprite_frames
				and robot.animated_sprite.frame == 5,
				"剩余33次必须进入裂损R1且保留腿相。"
			)
		if block_index == 34:
			_expect(
				robot.get_shield_visual_stage()
				== CombatRobotShieldBearer.ShieldStage.CRITICAL
				and robot.get_shield_remaining_durability() == 16
				and robot.animated_sprite.sprite_frames == robot.critical_sprite_frames,
				"剩余16次必须进入危急R1。"
			)
		if block_index == 49:
			_expect(
				robot.get_shield_remaining_durability() == 1
				and shield.is_active(),
				"第49发后盾牌必须仍可拦截第50发。"
			)

	_expect(
		robot.get_shield_visual_stage()
		== CombatRobotShieldBearer.ShieldStage.BROKEN
		and robot.animated_sprite.sprite_frames == robot.broken_sprite_frames
		and robot.get_shield_remaining_durability() == 0
		and not shield.is_active()
		and shield.collision_layer == 0,
		"第50发必须被完整抵消后立即破盾并退出物理层。"
	)
	_expect(
		not shield.try_intercept(Vector2.LEFT)
		and robot.get_shield_remaining_durability() == 0,
		"第51发必须穿过已破碎盾牌。"
	)
	_expect(test_root.enemy_actions.size() == 50, "50次格挡必须广播50个有序动作。")
	if test_root.enemy_actions.size() == 50:
		for index in range(50):
			var action := test_root.enemy_actions[index]
			_expect(
				int(action["action_id"]) == index + 1
				and StringName(action["action_name"])
				== (
					&"combat_robot_shield_break"
					if index == 49
					else &"combat_robot_shield_block"
				),
				"精英盾兵action_id 1-50及block/break边界必须稳定。"
			)
	robot.queue_free()
	await process_frame


func _test_proxy_stage_action_contract() -> void:
	var proxy := _spawn_robot(true)
	var shield := proxy.projectile_shield_area
	await process_frame
	await physics_frame
	_expect(
		proxy.is_multiplayer_proxy
		and shield.monitorable
		and shield.collision_layer == SHIELD_LAYER
		and shield.try_intercept(Vector2.LEFT)
		and proxy.get_shield_remaining_durability() == 50,
		"代理盾牌只吞本地表现弹体，不得自行扣耐久。"
	)

	proxy.play_multiplayer_enemy_action_with_context(
		&"combat_robot_shield_block", Vector2.RIGHT, Vector2.ZERO, 17, 0.0
	)
	_expect(
		proxy.get_shield_remaining_durability() == 33
		and proxy.get_shield_visual_stage()
		== CombatRobotShieldBearer.ShieldStage.CRACKED
		and proxy.latest_proxy_action_id == 17,
		"代理action_id=17必须推进到裂损阶段并播放反馈。"
	)
	proxy.apply_multiplayer_visual_status_mask(
		int(CombatRobotShieldBearer.ShieldStage.CRITICAL) << STAGE_SHIFT
	)
	_expect(
		proxy.get_shield_remaining_durability() == 16
		and proxy.get_shield_visual_stage()
		== CombatRobotShieldBearer.ShieldStage.CRITICAL
		and proxy.proxy_snapshot_min_action_id == 34
		and shield.is_active(),
		"bit5-6危急快照必须单调修复到16次并保留被动盾面。"
	)
	proxy.apply_multiplayer_visual_status_mask(
		int(CombatRobotShieldBearer.ShieldStage.INTACT) << STAGE_SHIFT
	)
	_expect(
		proxy.get_shield_visual_stage()
		== CombatRobotShieldBearer.ShieldStage.CRITICAL,
		"旧快照不得恢复已恶化的精英盾牌。"
	)
	proxy.call("_stop_shield_fx")
	proxy.play_multiplayer_enemy_action_with_context(
		&"combat_robot_shield_block", Vector2.LEFT, Vector2.ZERO, 18, 0.0
	)
	_expect(
		proxy.get_shield_remaining_durability() == 16
		and proxy.latest_proxy_action_id == 18
		and not proxy.facing_left
		and not proxy.shield_fx_sprite.visible,
		"跨频道晚到旧动作不得回退阶段、改朝向或重播FX。"
	)
	proxy.play_multiplayer_enemy_action_with_context(
		&"combat_robot_shield_block", Vector2.LEFT, Vector2.ZERO, 34, 0.0
	)
	_expect(
		proxy.latest_proxy_action_id == 34
		and proxy.facing_left
		and proxy.shield_fx_sprite.visible,
		"action_id=34里程碑在快照后到达仍应补播一次新鲜反馈。"
	)
	proxy.call("_stop_shield_fx")
	proxy.play_multiplayer_enemy_action_with_context(
		&"combat_robot_shield_block", Vector2.RIGHT, Vector2.ZERO, 49, 999.0
	)
	_expect(
		proxy.get_shield_remaining_durability() == 1
		and shield.is_active()
		and not proxy.shield_fx_sprite.visible,
		"过期第49发只应修复到剩余1次，不重播FX。"
	)
	proxy.play_multiplayer_enemy_action_with_context(
		&"combat_robot_shield_break", Vector2.RIGHT, Vector2.ZERO, 50, 999.0
	)
	_expect(
		proxy.get_shield_remaining_durability() == 0
		and proxy.get_shield_visual_stage()
		== CombatRobotShieldBearer.ShieldStage.BROKEN
		and not shield.is_active()
		and not proxy.shield_fx_sprite.visible,
		"过期第50发仍须可靠落地破盾状态，但不得从头播放FX。"
	)
	proxy.queue_free()
	await process_frame


func _test_death_cleanup() -> void:
	var host := _spawn_robot(false)
	for _index in range(17):
		host.projectile_shield_area.try_intercept(Vector2.LEFT)
	var death_frames := host.cracked_sprite_frames
	host.call("_die")
	_expect(
		host.is_dead
		and not host.projectile_shield_area.is_active()
		and host.projectile_shield_area.collision_layer == 0
		and host.animated_sprite.sprite_frames == death_frames
		and host.animated_sprite.animation == &"death",
		"权威死亡必须立即禁用盾面并锁定当前裂损死亡套图。"
	)
	host.queue_free()
	await process_frame

	var proxy := _spawn_robot(true)
	var proxy_death_frames := proxy.intact_sprite_frames
	proxy.play_multiplayer_death_sequence()
	proxy.apply_multiplayer_visual_status_mask(
		int(CombatRobotShieldBearer.ShieldStage.BROKEN) << STAGE_SHIFT
	)
	_expect(
		proxy.is_dead
		and not proxy.projectile_shield_area.is_active()
		and proxy.animated_sprite.sprite_frames == proxy_death_frames
		and proxy.animated_sprite.animation == &"death"
		and proxy.get_shield_visual_stage()
		== CombatRobotShieldBearer.ShieldStage.INTACT,
		"代理死亡必须禁用盾面，迟到快照不得替换已开始的死亡套图。"
	)
	proxy.queue_free()
	await process_frame


func _spawn_robot(as_proxy: bool) -> CombatRobotShieldBearer:
	var robot := ELITE_SCENE.instantiate() as CombatRobotShieldBearer
	test_root.add_child(robot)
	robot.setup(ELITE_CONFIG, null, null)
	robot.set_meta(&"net_id", 7550)
	robot.bind_gameplay_gateway(test_root)
	if as_proxy:
		robot.configure_multiplayer_proxy()
	return robot


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
