extends SceneTree

const MpProjectileCoordinatorScript := preload(
	"res://scene/multiplayer/projectile/mp_projectile_coordinator.gd"
)
const NetConstants := preload("res://scene/multiplayer/net_constants.gd")
const ELITE_DRONE_SCENE_PATH := (
	"res://scene/enemy/mechanical_life/combat_robot_suicide_drone_elite.tscn"
)
const ORDINARY_DRONE_SCENE_PATH := (
	"res://scene/enemy/mechanical_life/combat_robot_suicide_drone.tscn"
)
const ELITE_DRONE_TYPE: StringName = &"combat_robot_suicide_drone_elite"
const ORDINARY_DRONE_TYPE: StringName = &"combat_robot_suicide_drone"
const EXPECTED_FLIGHT_DURATION := 80.0 / 90.0

var failures: Array[String] = []
var fixture: Node = null


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	fixture = Node.new()
	fixture.name = "EliteDroneOperatorNetworkFixture"
	root.add_child(fixture)
	_test_protocol_and_compensation_contract()
	_test_multiplayer_instantiation_branch()
	await _test_independent_pool_and_shared_motion_contract()
	_test_registration_fate_and_loading_contract()
	await _finish()


func _test_protocol_and_compensation_contract() -> void:
	_expect(
		NetConstants.PROTOCOL_VERSION == 79
		and NetConstants.CHANNEL_COUNT == 8,
		"协议v79必须保留内容摘要、同局成员身份和精英无人机语义，且不能增加 ENet 信道。"
	)
	_expect(
		MpProjectileCoordinatorScript._is_combat_robot_suicide_drone_type(
			ORDINARY_DRONE_TYPE
		)
		and MpProjectileCoordinatorScript._is_combat_robot_suicide_drone_type(
			ELITE_DRONE_TYPE
		),
		"普通与精英无人机必须共用同一个三阶段类型判定。"
	)
	var coordinator := MpProjectileCoordinatorScript.new()
	var expected_total := (
		CombatRobotSuicideDrone.DEPLOY_DELAY
		+ EXPECTED_FLIGHT_DURATION
		+ CombatRobotSuicideDrone.EXPLOSION_DURATION
	)
	for projectile_type in [ORDINARY_DRONE_TYPE, ELITE_DRONE_TYPE]:
		_expect(
			is_equal_approx(
				coordinator.get_projectile_time_compensation_age(
					99.0,
					EXPECTED_FLIGHT_DURATION,
					projectile_type
				),
				expected_total
			),
			"%s 必须允许elapsed覆盖完整部署、飞行与爆炸阶段。" % projectile_type
		)
	coordinator.free()
	_expect(
		CombatAttackRegistry.encode_player_hit_source(ELITE_DRONE_TYPE) == 0,
		"精英无人机爆炸是Host-only范围伤害，不能占用新的攻击wire ID。"
	)


func _test_multiplayer_instantiation_branch() -> void:
	# Keep the runtime off-tree: the focused branch only needs the typed gateway
	# and shared motion system, not a full authored wave scene.
	var runtime := StandardGame.new()
	runtime.runtime_mode = CombatRuntimeBase.RuntimeMode.CLIENT_VIEW
	var gateway := MultiplayerGameplayGateway.new()
	gateway.name = "MultiplayerGameplayGateway"
	runtime.add_child(gateway)
	gateway.bind_runtime(runtime)
	var motion_system := CombatRobotDroneMotionSystem.new()
	motion_system.name = "CombatRobotDroneMotionSystem"
	runtime.add_child(motion_system)
	runtime.combat_robot_drone_motion_system = motion_system
	var coordinator := MpProjectileCoordinatorScript.new()
	coordinator.bind_runtime(runtime)
	var drone := coordinator.instantiate_projectile(
		ELITE_DRONE_TYPE,
		1,
		Vector2.RIGHT,
		100,
		90.0,
		EXPECTED_FLIGHT_DURATION,
		false,
		0,
		0
	) as CombatRobotSuicideDrone
	_expect(
		drone != null
		and drone.authored_source_type == ELITE_DRONE_TYPE
		and drone.damage == 100
		and is_equal_approx(drone.speed, 90.0)
		and is_equal_approx(drone.max_lifetime, EXPECTED_FLIGHT_DURATION)
		and drone.batched_motion_system == motion_system,
		"多人实例化必须按精英类型选择独立场景，并保留Host方向、伤害、速度与动态航时。"
	)
	coordinator.unbind_runtime(runtime)
	coordinator.free()
	runtime.free()


func _test_independent_pool_and_shared_motion_contract() -> void:
	var ordinary_scene := load(ORDINARY_DRONE_SCENE_PATH) as PackedScene
	var elite_scene := load(ELITE_DRONE_SCENE_PATH) as PackedScene
	_expect(
		ordinary_scene != null and elite_scene != null and ordinary_scene != elite_scene,
		"普通与精英无人机必须提供两个独立PackedScene池键。"
	)
	if ordinary_scene == null or elite_scene == null:
		return
	var pool := SessionObjectPool.new()
	pool.name = "SessionObjectPool"
	fixture.add_child(pool)
	pool.register_scene(ordinary_scene, 0, 384)
	pool.register_scene(elite_scene, 0, 384)
	for scene_path in [ORDINARY_DRONE_SCENE_PATH, ELITE_DRONE_SCENE_PATH]:
		var metrics := pool.get_metrics(scene_path)
		_expect(
			int(metrics.get("created", -1)) == 0
			and int(metrics.get("in_use", -1)) == 0
			and int(metrics.get("retained_capacity", -1)) == 384,
			"%s 必须以预热0、保留384独立注册。" % scene_path
		)

	var motion_system := CombatRobotDroneMotionSystem.new()
	motion_system.name = "CombatRobotDroneMotionSystem"
	fixture.add_child(motion_system)
	var elite_drone := pool.acquire(elite_scene) as CombatRobotSuicideDrone
	_expect(elite_drone != null, "精英无人机池必须能取得租约。")
	if elite_drone == null:
		return
	var elite_instance_id := elite_drone.get_instance_id()
	var telemetry := RuntimePerformanceTelemetry.new()
	_expect(
		elite_drone.authored_source_type == ELITE_DRONE_TYPE
		and elite_drone.source_type == ELITE_DRONE_TYPE
		and elite_drone.is_in_group(&"runtime_projectiles")
		and telemetry._is_active_projectile(elite_drone),
		"精英租约必须恢复独立来源，并继续进入既有投射物遥测。"
	)
	elite_drone.setup(
		Vector2.RIGHT,
		100,
		90.0,
		EXPECTED_FLIGHT_DURATION,
		28.0,
		motion_system
	)
	_expect(elite_drone.begin_deployment(), "精英无人机必须注册到共享批量运动系统。")
	elite_drone.simulate_compensated_motion(0.35)
	_expect(
		motion_system.get_active_drone_count() == 1
		and elite_drone.flight_started
		and not elite_drone.explosion_started
		and is_equal_approx(elite_drone.speed, 90.0)
		and is_equal_approx(elite_drone.max_lifetime, EXPECTED_FLIGHT_DURATION),
		"精英类型必须在唯一运动系统中按Host给出的90速度与动态航时补播。"
	)
	elite_drone.retire()
	for _frame in range(4):
		await physics_frame
		await process_frame
	_expect(
		motion_system.get_active_drone_count() == 0,
		"回池必须从共享运动系统移除精英租约。"
	)
	var reused_elite := pool.acquire(elite_scene) as CombatRobotSuicideDrone
	_expect(
		reused_elite != null
		and reused_elite.get_instance_id() == elite_instance_id
		and reused_elite.authored_source_type == ELITE_DRONE_TYPE
		and reused_elite.source_type == ELITE_DRONE_TYPE
		and not reused_elite.deployment_started
		and reused_elite.projectile_id == 0,
		"精英池复用时必须完整恢复来源、阶段和网络字段。"
	)
	if reused_elite != null:
		reused_elite.retire()
	var ordinary_drone := pool.acquire(ordinary_scene) as CombatRobotSuicideDrone
	_expect(
		ordinary_drone != null
		and ordinary_drone.authored_source_type == ORDINARY_DRONE_TYPE
		and ordinary_drone.source_type == ORDINARY_DRONE_TYPE
		and ordinary_drone.get_instance_id() != elite_instance_id,
		"普通池不得被精英租约的来源或实例桶污染。"
	)
	if ordinary_drone != null:
		ordinary_drone.retire()
	telemetry.free()


func _test_registration_fate_and_loading_contract() -> void:
	var coordinator_source := FileAccess.get_file_as_string(
		"res://scene/multiplayer/projectile/mp_projectile_coordinator.gd"
	)
	_expect(
		coordinator_source.contains("COMBAT_ROBOT_SUICIDE_DRONE_ELITE_SCENE")
		and coordinator_source.contains("COMBAT_ROBOT_SUICIDE_DRONE_ELITE_TYPE")
		and coordinator_source.contains(
			"COMBAT_ROBOT_SUICIDE_DRONE_TYPE, COMBAT_ROBOT_SUICIDE_DRONE_ELITE_TYPE"
		),
		"多人实例化分支必须按普通/精英类型选择独立场景。"
	)
	for source_path in [
		"res://scene/combat/runtime/wave_combat_runtime_base.gd",
		"res://scene/game_modes/tower_defense/prewarm/tower_defense_prewarmer_coordinator.gd",
	]:
		var source := FileAccess.get_file_as_string(source_path)
		var compact := source.replace(" ", "").replace("\t", "").replace("\r", "").replace("\n", "")
		_expect(
			compact.contains(
				"register_scene(COMBAT_ROBOT_SUICIDE_DRONE_ELITE_POOL_SCENE,0,384)"
			),
			"%s 必须注册精英无人机0/384池。" % source_path
		)
	var catalog_source := FileAccess.get_file_as_string(
		"res://scene/game_modes/game_mode_catalog.gd"
	)
	_expect(
		catalog_source.contains(ELITE_DRONE_SCENE_PATH),
		"加载目录必须包含精英无人机场景。"
	)
	_expect(
		FateCoordinator.ELITE_ENEMY_CONFIG_PATH_BY_BASE_PATH.size() == 10
		and str(FateCoordinator.ELITE_ENEMY_CONFIG_PATH_BY_BASE_PATH.get(
			"res://resources/config/enemies/combat_robot_drone_operator.tres",
			""
		)) == "res://resources/config/enemies/combat_robot_drone_operator_elite.tres",
		"命运替换必须将普通操作员稳定映射到精英操作员，且映射总数为10。"
	)


func _finish() -> void:
	if fixture != null and is_instance_valid(fixture):
		fixture.queue_free()
	await process_frame
	if failures.is_empty():
		print("COMBAT_ROBOT_DRONE_OPERATOR_ELITE_NETWORK_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
