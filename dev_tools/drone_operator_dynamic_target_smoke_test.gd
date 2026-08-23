extends SceneTree

const RUNTIME_SCENE := preload(
	"res://dev_tools/fixtures/enemy_gameplay_gateway_test_runtime.tscn"
)
const OPERATOR_SCENE := preload(
	"res://scene/enemy/mechanical_life/combat_robot_drone_operator.tscn"
)
const OPERATOR_CONFIG := preload(
	"res://resources/config/enemies/combat_robot_drone_operator.tres"
)
const TARGET_CONFIG := preload(
	"res://resources/config/enemies/yuanshi_insect_fast.tres"
)
const DESCRIPTOR := preload(
	"res://scene/combat/targeting/combat_target_descriptor.gd"
)

var failures: Array[String] = []


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	var runtime := RUNTIME_SCENE.instantiate() as EnemyGameplayGatewayTestRuntime
	root.add_child(runtime)
	await process_frame
	var coordinator := runtime.get_enemy_simulation_coordinator()
	coordinator.set_mode(EnemySimulationPolicy.Mode.LEGACY)

	_test_authored_enemy_layer()
	_test_enemy_sensor_and_faction_filter(runtime)
	_test_designated_target_absolute_priority(runtime)
	_test_proactive_target_recovers_missed_area_event(runtime)

	runtime.queue_free()
	await process_frame
	await physics_frame
	if failures.is_empty():
		print("DRONE_OPERATOR_DYNAMIC_TARGET_SMOKE_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_authored_enemy_layer() -> void:
	var operator := OPERATOR_SCENE.instantiate() as CombatRobotDroneOperator
	var sense_area := operator.get_node("AttackSenseArea") as Area2D
	_expect(
		sense_area != null
		and sense_area.collision_layer == 0
		and sense_area.collision_mask == 518
		and bool(sense_area.collision_mask & (1 << 2)),
		"无人机操作员的 authored 感知区必须包含敌人 layer 4。"
	)
	operator.free()


func _test_enemy_sensor_and_faction_filter(
	runtime: EnemyGameplayGatewayTestRuntime
) -> void:
	var source := _spawn_operator(runtime, 1101, Vector2.ZERO)
	var hostile_target := _spawn_target(runtime, 1102, Vector2(24.0, 0.0))
	var allied_target := _spawn_target(runtime, 1103, Vector2(60.0, 0.0))
	allied_target.set_combat_faction_id(
		CombatRelationService.PLAYER_ALLIED,
		-1,
		true
	)
	source.call("_on_attack_sense_area_body_entered", hostile_target)
	_expect(
		not source.sensed_targets.has(hostile_target.get_instance_id())
		and source.combat_state
			== CombatRobotDroneOperator.CombatState.TRACKING_READY,
		"同阵营 Enemy 即使进入感知区也不能成为攻击候选。"
	)
	source.call("_on_attack_sense_area_body_entered", allied_target)
	_expect(
		source.supports_dynamic_enemy_targeting()
		and source.sensed_targets.has(allied_target.get_instance_id())
		and source.combat_state == CombatRobotDroneOperator.CombatState.DEPLOY
		and source.last_attack_target == allied_target,
		"敌对 Enemy 进入感知区后必须像玩家/植物一样触发无人机部署。"
	)


func _test_designated_target_absolute_priority(
	runtime: EnemyGameplayGatewayTestRuntime
) -> void:
	var source := _spawn_operator(runtime, 1201, Vector2(0.0, 160.0))
	var nearer_target := _spawn_target(runtime, 1202, Vector2(16.0, 160.0))
	var designated_target := _spawn_target(
		runtime,
		1203,
		Vector2(64.0, 160.0)
	)
	nearer_target.set_combat_faction_id(
		CombatRelationService.PLAYER_ALLIED,
		-1,
		true
	)
	designated_target.set_combat_faction_id(
		CombatRelationService.PLAYER_ALLIED,
		-1,
		true
	)
	source.sensed_targets[nearer_target.get_instance_id()] = nearer_target
	var assignment := DESCRIPTOR.create_enemy(
		1203,
		1,
		designated_target.global_position
	)
	_expect(
		source.apply_designated_combat_target(assignment)
		and source.combat_state == CombatRobotDroneOperator.CombatState.DEPLOY
		and source.last_attack_target == designated_target,
		"宿主指定 Enemy 必须压过更近的普通感知候选。"
	)


func _test_proactive_target_recovers_missed_area_event(
	runtime: EnemyGameplayGatewayTestRuntime
) -> void:
	var source := _spawn_operator(runtime, 1301, Vector2(0.0, 320.0))
	var target := _spawn_target(runtime, 1302, Vector2(48.0, 320.0))
	# 目标以友军身份进入范围时不会进入 sensed_targets；随后转为敌对，
	# 统一查询门面可直接提交自动目标，无需等待 Area2D 再次 enter。
	source.call("_on_attack_sense_area_body_entered", target)
	_expect(
		not source.sensed_targets.has(target.get_instance_id()),
		"友军目标不得预先污染无人机感知集合。"
	)
	target.set_combat_faction_id(
		CombatRelationService.PLAYER_ALLIED,
		-1,
		true
	)
	_expect(
		source.consider_automatic_combat_target(target, 1)
		and source.combat_state == CombatRobotDroneOperator.CombatState.DEPLOY
		and source.last_attack_target == target,
		"范围内目标转为敌对后，主动目标更新必须弥补缺失的 Area enter 事件。"
	)


func _spawn_operator(
	runtime: EnemyGameplayGatewayTestRuntime,
	net_id: int,
	position: Vector2
) -> CombatRobotDroneOperator:
	var operator := OPERATOR_SCENE.instantiate() as CombatRobotDroneOperator
	runtime.enemy_container.add_child(operator)
	operator.global_position = position
	operator.setup(OPERATOR_CONFIG, null, runtime.get_node("GridPathfinder"), runtime)
	operator.set_physics_process(false)
	if not runtime.register_network_enemy(net_id, operator):
		failures.append("无人机操作员 %d 注册失败。" % net_id)
	return operator


func _spawn_target(
	runtime: EnemyGameplayGatewayTestRuntime,
	net_id: int,
	position: Vector2
) -> Enemy:
	var target := TARGET_CONFIG.enemy_scene.instantiate() as Enemy
	runtime.enemy_container.add_child(target)
	target.global_position = position
	target.setup(TARGET_CONFIG, null, runtime.get_node("GridPathfinder"), runtime)
	target.set_physics_process(false)
	if not runtime.register_network_enemy(net_id, target):
		failures.append("动态目标 %d 注册失败。" % net_id)
	return target


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
