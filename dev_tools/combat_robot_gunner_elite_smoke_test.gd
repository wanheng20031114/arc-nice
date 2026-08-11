extends SceneTree

const ELITE_SCENE := preload(
	"res://scene/enemy/mechanical_life/combat_robot_gunner_elite.tscn"
)
const ELITE_BULLET_SCENE := preload(
	"res://scene/enemy/mechanical_life/combat_robot_gunner_elite_bullet.tscn"
)
const ELITE_CONFIG := preload(
	"res://resources/config/enemies/combat_robot_gunner_elite.tres"
)
const ORDINARY_SCENE := preload(
	"res://scene/enemy/mechanical_life/combat_robot_gunner.tscn"
)
const ORDINARY_BULLET_SCENE := preload(
	"res://scene/enemy/mechanical_life/combat_robot_gunner_bullet.tscn"
)
const PLAYER_SCENE := preload(
	"res://scene/player/weishidaier/player_weishidaier.tscn"
)
const DEFAULT_DROP_TABLE := preload(
	"res://resources/config/enemies/default_enemy_drop_table.tres"
)
const TEST_DOUBLE_SCRIPT := preload(
	"res://dev_tools/fixtures/combat_robot_gunner_elite_test_double.gd"
)
const MP_PROJECTILE_COORDINATOR_SCRIPT := preload(
	"res://scene/multiplayer/projectile/mp_projectile_coordinator.gd"
)
const FATE_COORDINATOR_SCRIPT := preload(
	"res://scene/game_modes/tower_defense/fate/fate_coordinator.gd"
)
const NET_CONSTANTS := preload("res://scene/multiplayer/net_constants.gd")
const ELITE_CONFIG_REFERENCE := (
	"res://resources/config/enemies/combat_robot_gunner_elite.tres"
)
const SUITCASE_BATTLE_GUNNER_ENTRY := (
	"res://resources/config/campaigns/rogue_combat/suitcase_battle/entries/gunner_elite.tres"
)
const ZERO_DIRECT_REFERENCE_ROOTS := {
	"正式标准单人波次": "res://resources/config/campaigns/standard/singleplayer",
	"正式标准多人波次": "res://resources/config/campaigns/standard/multiplayer",
	"正式塔防波次": "res://resources/config/campaigns/tower_defense/formal",
	"旧正式波次": "res://resources/config/waves",
	"肉鸽战斗波次": "res://resources/config/campaigns/rogue_combat",
	"肉鸽遭遇配置": "res://resources/config/rogue_combat",
	"P1B单人": "res://resources/config/campaigns/test_arena/p1b/singleplayer",
	"P1B多人": "res://resources/config/campaigns/test_arena/p1b/multiplayer",
}


class DirectPathfinder:
	extends Node

	var is_built := true

	func try_get_safe_navigation_step(
		_from_position: Vector2,
		target_position: Vector2,
		_half_extents: Vector2 = Vector2.ZERO,
		_terrain_types: int = DualGridTilemap.TraversalType.LAND
	) -> Dictionary:
		return {
			"status": GridPathfinder.NavigationStepStatus.READY,
			"is_complete_route": true,
			"waypoint": target_position,
		}


var failures: Array[String] = []
var test_root: Node2D


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	test_root = Node2D.new()
	test_root.name = "CombatRobotGunnerEliteSmokeTest"
	root.add_child(test_root)
	current_scene = test_root

	_test_config_scene_and_geometry_contract()
	await _test_bullet_source_contract()
	await _test_burst_scheduler_and_half_speed()
	await _test_network_pool_and_fate_contract()
	_test_zero_direct_wave_references()

	current_scene = null
	test_root.queue_free()
	await process_frame
	await physics_frame
	for _cleanup_frame in range(3):
		await process_frame

	if failures.is_empty():
		print("COMBAT_ROBOT_GUNNER_ELITE_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_config_scene_and_geometry_contract() -> void:
	_expect(
		ELITE_CONFIG is CombatRobotGunnerEliteConfig,
		"精英枪手必须使用 CombatRobotGunnerEliteConfig。"
	)
	_expect(
		ELITE_CONFIG is CombatRobotGunnerConfig,
		"精英枪手必须继续复用普通枪手配置合同。"
	)
	_expect(ELITE_CONFIG.display_name == "精英持枪战斗机器人", "显示名不正确。")
	_expect(ELITE_CONFIG.enemy_scene == ELITE_SCENE, "精英枪手场景绑定不正确。")
	_expect(ELITE_CONFIG.max_health == 360, "生命值必须为360。")
	_expect(ELITE_CONFIG.attack_damage == 50, "攻击力必须为50。")
	_expect(ELITE_CONFIG.physical_defense == 20, "物理防御必须为20。")
	_expect(ELITE_CONFIG.magic_defense == 15, "法术防御必须为15。")
	_expect(is_equal_approx(ELITE_CONFIG.move_speed, 50.0), "移动速度必须为50。")
	_expect(ELITE_CONFIG.home_damage == 2, "基地伤害必须保持2。")
	_expect(ELITE_CONFIG.xirang_kill_reward == 10, "击杀息壤必须保持10。")
	_expect(ELITE_CONFIG.drop_table == DEFAULT_DROP_TABLE, "精英枪手必须使用通用掉落表。")
	_expect(
		ELITE_CONFIG.category_tags == PackedStringArray(["mechanical_life"]),
		"精英枪手必须仅属于机械生命。"
	)
	_expect(is_equal_approx(ELITE_CONFIG.attack_range, 84.0), "射程必须保持84。")
	_expect(is_equal_approx(ELITE_CONFIG.stop_distance, 24.0), "停步距离必须保持24。")
	_expect(ELITE_CONFIG.burst_count == 12, "每轮必须成功射出12发。")
	_expect(is_equal_approx(ELITE_CONFIG.burst_fire_interval, 0.08), "连射间隔必须保持0.08秒。")
	_expect(is_equal_approx(ELITE_CONFIG.spread_angle_degrees, 5.0), "散布必须保持±5度。")
	_expect(is_equal_approx(ELITE_CONFIG.burst_move_speed_multiplier, 0.5), "连射移速倍率必须保持0.5。")
	_expect(is_equal_approx(ELITE_CONFIG.move_speed * ELITE_CONFIG.burst_move_speed_multiplier, 25.0), "精英连射基础有效移速必须为25。")
	_expect(is_equal_approx(ELITE_CONFIG.attack_cooldown, 2.0), "精英连射冷却必须为2秒。")
	_expect(ELITE_CONFIG.projectile_type == &"combat_robot_gunner_elite_bullet", "精英投射物类型不正确。")
	_expect(ELITE_CONFIG.projectile_scene == ELITE_BULLET_SCENE, "精英投射物场景绑定不正确。")
	_expect(is_equal_approx(ELITE_CONFIG.projectile_speed, 80.0), "弹速必须保持80。")
	_expect(is_equal_approx(ELITE_CONFIG.projectile_lifetime, 1.5), "弹体寿命必须保持1.5秒。")

	var elite := ELITE_SCENE.instantiate() as CombatRobotGunner
	var ordinary := ORDINARY_SCENE.instantiate() as CombatRobotGunner
	_expect(elite != null and ordinary != null, "普通与精英枪手场景都必须能实例化。")
	if elite == null or ordinary == null:
		if elite != null:
			elite.free()
		if ordinary != null:
			ordinary.free()
		return
	_expect(_same_body_geometry(elite, ordinary), "精英与普通枪手的身体和接触几何必须完全相同。")
	var elite_muzzle := elite.get_node_or_null("Muzzle") as Marker2D
	var ordinary_muzzle := ordinary.get_node_or_null("Muzzle") as Marker2D
	_expect(
		elite_muzzle != null
		and ordinary_muzzle != null
		and elite_muzzle.position == ordinary_muzzle.position
		and elite_muzzle.position == Vector2(11, 2),
		"精英枪口锚点必须继承普通枪手的(11,2)。"
	)
	var sprite := elite.get_node_or_null("AnimatedSprite2D") as AnimatedSprite2D
	_expect(sprite != null and sprite.sprite_frames != null, "精英枪手必须绑定独立SpriteFrames。")
	if sprite != null and sprite.sprite_frames != null:
		var expected := {
			&"move": [8, 14.0, true],
			&"fire": [4, 25.0, true],
			&"fire_walk": [32, 25.0, true],
			&"death": [8, 12.0, false],
		}
		for animation_name: StringName in expected:
			var contract: Array = expected[animation_name]
			_expect(sprite.sprite_frames.has_animation(animation_name), "缺少%s动画。" % animation_name)
			_expect(sprite.sprite_frames.get_frame_count(animation_name) == contract[0], "%s帧数不正确。" % animation_name)
			_expect(is_equal_approx(sprite.sprite_frames.get_animation_speed(animation_name), contract[1]), "%s帧率不正确。" % animation_name)
			_expect(sprite.sprite_frames.get_animation_loop(animation_name) == contract[2], "%s循环合同不正确。" % animation_name)
	elite.free()
	ordinary.free()


func _test_bullet_source_contract() -> void:
	var elite_bullet := ELITE_BULLET_SCENE.instantiate() as CombatRobotGunnerBullet
	var ordinary_bullet := ORDINARY_BULLET_SCENE.instantiate() as CombatRobotGunnerBullet
	_expect(elite_bullet != null and ordinary_bullet != null, "普通与精英弹丸场景都必须能实例化。")
	if elite_bullet == null or ordinary_bullet == null:
		if elite_bullet != null:
			elite_bullet.free()
		if ordinary_bullet != null:
			ordinary_bullet.free()
		return
	_expect(elite_bullet.authored_source_type == &"combat_robot_gunner_elite_bullet", "精英弹丸必须拥有独立伤害来源。")
	_expect(ordinary_bullet.authored_source_type == &"combat_robot_gunner_bullet", "普通弹丸来源不得被精英资源污染。")
	test_root.add_child(elite_bullet)
	test_root.add_child(ordinary_bullet)
	await process_frame
	_expect(elite_bullet.source_type == &"combat_robot_gunner_elite_bullet", "精英弹丸_ready后必须应用独立来源。")
	_expect(ordinary_bullet.source_type == &"combat_robot_gunner_bullet", "普通弹丸_ready后必须保持原来源。")
	elite_bullet.source_type = &"corrupted_test_source"
	elite_bullet.on_pool_released(1)
	_expect(
		elite_bullet.source_type == &"combat_robot_gunner_elite_bullet",
		"精英弹丸回池时必须恢复其独立伤害来源。"
	)
	elite_bullet.on_pool_acquired(2)
	_expect(
		elite_bullet.source_type == &"combat_robot_gunner_elite_bullet",
		"精英弹丸再次租用时必须保持其独立伤害来源。"
	)
	var telemetry := RuntimePerformanceTelemetry.new()
	_expect(
		telemetry._is_active_projectile(elite_bullet),
		"精英弹丸继承普通弹丸脚本后仍必须进入投射物遥测分类。"
	)
	telemetry.free()
	_expect(
		elite_bullet.z_index == ordinary_bullet.z_index
		and elite_bullet.collision_layer == ordinary_bullet.collision_layer
		and elite_bullet.collision_mask == ordinary_bullet.collision_mask,
		"紫弹必须继承普通弹丸的层级和碰撞合同。"
	)
	var elite_shape := elite_bullet.get_node_or_null("CollisionShape2D") as CollisionShape2D
	var ordinary_shape := ordinary_bullet.get_node_or_null("CollisionShape2D") as CollisionShape2D
	_expect(
		elite_shape != null
		and ordinary_shape != null
		and elite_shape.shape is RectangleShape2D
		and ordinary_shape.shape is RectangleShape2D
		and (elite_shape.shape as RectangleShape2D).size == Vector2(9, 3)
		and (elite_shape.shape as RectangleShape2D).size
		== (ordinary_shape.shape as RectangleShape2D).size,
		"紫弹必须保持9x3碰撞几何。"
	)
	var bullet_sprite := elite_bullet.get_node_or_null("AnimatedSprite2D") as AnimatedSprite2D
	_expect(
		bullet_sprite != null
		and bullet_sprite.sprite_frames.get_frame_count(&"fly") == 3
		and is_equal_approx(bullet_sprite.sprite_frames.get_animation_speed(&"fly"), 25.0),
		"紫弹必须使用3帧25FPS飞行动画。"
	)
	elite_bullet.queue_free()
	ordinary_bullet.queue_free()
	await process_frame


func _test_burst_scheduler_and_half_speed() -> void:
	var player := PLAYER_SCENE.instantiate() as Player
	player.global_position = Vector2(60, 0)
	test_root.add_child(player)
	var pathfinder := DirectPathfinder.new()
	test_root.add_child(pathfinder)

	var elite := ELITE_SCENE.instantiate() as CombatRobotGunner
	elite.set_script(TEST_DOUBLE_SCRIPT)
	var test_double := elite as CombatRobotGunner
	_expect(
		test_double != null and test_double.get_script() == TEST_DOUBLE_SCRIPT,
		"调度测试替身必须保留CombatRobotGunner继承。"
	)
	if test_double == null:
		elite.free()
		player.queue_free()
		pathfinder.queue_free()
		await process_frame
		return
	test_root.add_child(test_double)
	test_double.global_position = Vector2.ZERO
	test_double.setup(ELITE_CONFIG, player, pathfinder)
	test_double.set_physics_process(false)
	_expect(bool(test_double.call("_try_start_burst", player)), "84像素内玩家必须立即锁定。")
	test_double.call("_update_burst", 0.0)
	var accepted_shots := test_double.get("accepted_shots") as Array
	_expect(accepted_shots.size() == 1, "锁定同帧必须成功产生首发。")
	_expect(
		absf(test_double.velocity.length() - 25.0) <= 0.05,
		"连射追击必须以50×0.5=25的速度移动。"
	)
	test_double.call("_update_burst", 0.88)
	_expect(
		accepted_shots.size() == 12
		and test_double.burst_shots_fired == 12,
		"0.88秒时必须完成且仅完成12发连射。"
	)
	_expect(
		test_double.combat_state == CombatRobotGunner.CombatState.TRACKING_COOLDOWN
		and is_equal_approx(test_double.attack_cooldown_left, 2.0),
		"第12发成功后必须开始2秒冷却。"
	)
	for shot in accepted_shots:
		_expect(
			shot.projectile_type == &"combat_robot_gunner_elite_bullet"
			and shot.projectile_scene == ELITE_BULLET_SCENE
			and shot.damage == 50
			and is_equal_approx(shot.speed, 80.0)
			and is_equal_approx(shot.lifetime, 1.5),
			"每发必须使用精英紫弹、50点伤害、80速度与1.5秒寿命。"
		)
	test_double.queue_free()
	player.queue_free()
	pathfinder.queue_free()
	await process_frame


func _test_network_pool_and_fate_contract() -> void:
	_expect(
		NET_CONSTANTS.PROTOCOL_VERSION == 60
		and NET_CONSTANTS.CHANNEL_COUNT == 8,
		"协议v60必须保留精英紫弹的v49资源合同、v50消耗品合同且不增加ENet频道。"
	)
	_expect(
		CombatAttackRegistry.encode_player_hit_source(
			&"combat_robot_gunner_elite_bullet"
		) == 18
		and CombatAttackRegistry.decode_player_hit_source(18)
			== &"combat_robot_gunner_elite_bullet"
		and CombatAttackRegistry.get_certificate_projectile_type(18)
			== &"combat_robot_gunner_elite_bullet"
		and CombatAttackRegistry.get_damage_type(18)
			== CombatTypes.DamageType.PHYSICAL,
		"精英紫弹必须占用稳定物理攻击ID18并可双向编码。"
	)

	var pool := SessionObjectPool.new()
	test_root.add_child(pool)
	CombatRuntimeBase.register_combat_robot_gunner_elite_bullet_pool(pool)
	var metrics := pool.get_metrics(ELITE_BULLET_SCENE.resource_path)
	_expect(
		int(metrics.get("created", -1)) == 0
		and int(metrics.get("inactive", -1)) == 0
		and int(metrics.get("retained_capacity", -1)) == 96,
		"精英紫弹对象池必须保持预热0、保留96。"
	)
	pool.queue_free()
	await process_frame

	var fate_coordinator := FATE_COORDINATOR_SCRIPT.new()
	_expect(
		str(fate_coordinator.ELITE_ENEMY_CONFIG_PATH_BY_BASE_PATH.get(
			"res://resources/config/enemies/combat_robot_gunner.tres",
			""
		)) == "res://resources/config/enemies/combat_robot_gunner_elite.tres"
		and fate_coordinator.ELITE_ENEMY_CONFIG_PATH_BY_BASE_PATH.size() == 10,
		"命运系统必须把普通枪手映射到精英枪手，并保持十组精英替换。"
	)
	fate_coordinator.free()

	var runtime := StandardGame.new()
	var gateway := MultiplayerGameplayGateway.new()
	gateway.name = "MultiplayerGameplayGateway"
	runtime.add_child(gateway)
	gateway.bind_runtime(runtime)
	var coordinator := MP_PROJECTILE_COORDINATOR_SCRIPT.new()
	coordinator.bind_runtime(runtime)
	var host_direction := Vector2(0.6, 0.8)
	var projectile := coordinator.instantiate_projectile(
		&"combat_robot_gunner_elite_bullet",
		1,
		host_direction,
		50,
		80.0,
		1.5,
		false,
		0,
		0
	) as CombatRobotGunnerBullet
	_expect(
		projectile != null
		and projectile.authored_source_type
			== &"combat_robot_gunner_elite_bullet"
		and projectile.direction.is_equal_approx(host_direction)
		and projectile.damage == 50
		and is_equal_approx(projectile.speed, 80.0)
		and is_equal_approx(projectile.remaining_lifetime, 1.5),
		"客户端必须按Host方向实例化独立紫弹表现，且保留50点快照。"
	)
	coordinator.unbind_runtime(runtime)
	coordinator.free()
	runtime.free()


func _test_zero_direct_wave_references() -> void:
	for label: String in ZERO_DIRECT_REFERENCE_ROOTS:
		var directory_path: String = ZERO_DIRECT_REFERENCE_ROOTS[label]
		var references := _find_text_references(directory_path, ELITE_CONFIG_REFERENCE)
		references.sort()
		var expected: Array[String] = []
		if label == "肉鸽战斗波次":
			expected.append(SUITCASE_BATTLE_GUNNER_ENTRY)
		_expect(
			references == expected,
			(
				"%s只允许皮箱之战的唯一精英枪手条目；expected=%s actual=%s"
				% [label, expected, references]
			)
		)


func _find_text_references(directory_path: String, needle: String) -> Array[String]:
	var matches: Array[String] = []
	var directory := DirAccess.open(directory_path)
	if directory == null:
		failures.append("无法打开集成审计目录：%s" % directory_path)
		return matches
	directory.list_dir_begin()
	var entry_name := directory.get_next()
	while not entry_name.is_empty():
		if entry_name != "." and entry_name != "..":
			var child_path := directory_path.path_join(entry_name)
			if directory.current_is_dir():
				matches.append_array(_find_text_references(child_path, needle))
			elif entry_name.get_extension() in ["tres", "tscn", "gd"]:
				var file := FileAccess.open(child_path, FileAccess.READ)
				if file != null and needle in file.get_as_text():
					matches.append(child_path)
		entry_name = directory.get_next()
	directory.list_dir_end()
	return matches


func _same_body_geometry(elite: Node, ordinary: Node) -> bool:
	for parent_path in [NodePath("."), NodePath("TouchDamageArea")]:
		var elite_shapes := _direct_shapes(elite.get_node(parent_path))
		var ordinary_shapes := _direct_shapes(ordinary.get_node(parent_path))
		if elite_shapes.size() != ordinary_shapes.size():
			return false
		for index in range(elite_shapes.size()):
			var elite_shape := elite_shapes[index]
			var ordinary_shape := ordinary_shapes[index]
			if (
				elite_shape.name != ordinary_shape.name
				or elite_shape.position != ordinary_shape.position
				or not (elite_shape.shape is RectangleShape2D)
				or not (ordinary_shape.shape is RectangleShape2D)
				or (elite_shape.shape as RectangleShape2D).size
				!= (ordinary_shape.shape as RectangleShape2D).size
			):
				return false
	return true


func _direct_shapes(parent_node: Node) -> Array[CollisionShape2D]:
	var shapes: Array[CollisionShape2D] = []
	for child in parent_node.get_children():
		var shape := child as CollisionShape2D
		if shape != null:
			shapes.append(shape)
	return shapes


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
