extends SceneTree

const PROJECTILE_COORDINATOR_SCENE := preload(
	"res://scene/multiplayer/projectile/mp_projectile_coordinator.tscn"
)
const MpProjectileCoordinatorScript := preload(
	"res://scene/multiplayer/projectile/mp_projectile_coordinator.gd"
)


class ProbeRuntime:
	extends CombatRuntimeBase

	func configure_multiplayer(
		_mode: int,
		_local_peer_id: int,
		_player_names: Dictionary,
		_player_character_ids: Dictionary = {}
	) -> void:
		pass

	func get_player_for_peer(peer_id: int) -> Player:
		return peer_players.get(peer_id) as Player

	func get_enemy_for_net_id(net_id: int) -> Enemy:
		return multiplayer_enemies_by_net_id.get(net_id) as Enemy

	func get_pickup_for_net_id(_net_id: int) -> Pickup:
		return null

	func remove_multiplayer_player(peer_id: int) -> void:
		peer_players.erase(peer_id)

	func collect_player_snapshot_states() -> Array[SnapshotManager.PlayerState]:
		return []

	func collect_enemy_snapshot_states() -> Array[SnapshotManager.EnemyState]:
		return []

	func play_remote_enemy_spawn_effect(
		_spawn_global_position: Vector2
	) -> void:
		pass


class ProbeProjectile:
	extends Node2D

	signal projectile_finished(projectile_id: int, projectile: Node)

	var projectile_id := 0
	var owner_peer_id := 0
	var projectile_type: StringName = &""
	var retired := false

	func setup_multiplayer(
		new_projectile_id: int,
		new_owner_peer_id: int,
		new_projectile_type: StringName
	) -> void:
		projectile_id = new_projectile_id
		owner_peer_id = new_owner_peer_id
		projectile_type = new_projectile_type

	func retire() -> void:
		retired = true


var failures: Array[String] = []
var broadcast_methods: Array[StringName] = []
var broadcast_argument_counts: Array[int] = []
var host_request_methods: Array[StringName] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var coordinator := (
		PROJECTILE_COORDINATOR_SCENE.instantiate() as MpProjectileCoordinatorScript
	)
	var runtime := ProbeRuntime.new()
	_expect(coordinator != null, "ProjectileCoordinator 场景必须可实例化。")
	if coordinator == null:
		quit(1)
		return
	coordinator.bind_runtime(runtime)
	_expect(coordinator.is_bound(), "弹体协调器必须强类型绑定战斗运行时。")
	var net_manager := NetManagerStore.new()
	net_manager.net_role = NetManagerStore.NetRole.HOST
	net_manager.connection_state = NetManagerStore.ConnectionState.IN_GAME
	var player_coordinator := MpPlayerCoordinator.new()
	player_coordinator.bind_runtime(runtime)
	coordinator.bind_network_facade_dependencies(
		net_manager,
		player_coordinator,
		func() -> float: return 400.0,
		func(_host_timestamp: float) -> float: return 0.05,
		func(_peer_id: int) -> bool: return false
	)
	coordinator.rpc_broadcast_requested.connect(_on_rpc_broadcast_requested)
	coordinator.rpc_to_host_requested.connect(_on_rpc_to_host_requested)
	_expect(
		coordinator.has_network_facade_dependencies(),
		"弹体网络门面必须显式注入 NetManager、玩家协调器与时钟入口。"
	)

	var host_projectile := ProbeProjectile.new()
	coordinator.submit_local_projectile(
		host_projectile,
		&"probe",
		2,
		Vector2(10.0, 20.0),
		Vector2.RIGHT,
		11,
		120.0,
		1.0
	)
	_expect(
		broadcast_methods == [&"net_projectile_fired"]
		and broadcast_argument_counts == [12],
		"Host 本地弹体必须由协调器登记，并请求根节点广播既有 12 字段载荷。"
	)

	player_coordinator.observe_tango_charge_sequence(2, 1)
	var tango_projectiles: Array[Node] = [
		ProbeProjectile.new(),
		ProbeProjectile.new(),
		ProbeProjectile.new(),
	]
	coordinator.submit_local_tango_laser_volley(
		tango_projectiles,
		PackedVector2Array([Vector2.ZERO, Vector2.UP, Vector2.DOWN]),
		Vector2.RIGHT,
		2,
		13,
		200.0,
		1.5,
		1.0,
		0.5
	)
	_expect(
		broadcast_methods.size() == 2
		and broadcast_methods[1] == &"net_tango_laser_volley"
		and broadcast_argument_counts[1] == 11,
		"探戈三连发必须由协调器登记并请求根节点广播既有载荷。"
	)

	var linglan_projectiles: Array[Node] = []
	var linglan_positions := PackedVector2Array()
	var linglan_directions := PackedVector2Array()
	for projectile_index in range(33):
		linglan_projectiles.append(ProbeProjectile.new())
		linglan_positions.append(Vector2(projectile_index, 0.0))
		linglan_directions.append(Vector2.RIGHT)
	coordinator.submit_local_linglan_skill1_ring(
		linglan_projectiles,
		linglan_positions,
		linglan_directions,
		9,
		17,
		180.0,
		2.0
	)
	_expect(
		broadcast_methods.size() == 4
		and broadcast_methods[2] == &"net_linglan_skill1_ring_batch"
		and broadcast_methods[3] == &"net_linglan_skill1_ring_batch"
		and broadcast_argument_counts[2] == 8
		and broadcast_argument_counts[3] == 8,
		"灵兰弹环超过单包上限时必须由协调器按既有 32 颗边界分批。"
	)

	net_manager.net_role = NetManagerStore.NetRole.CLIENT
	var client_projectile := ProbeProjectile.new()
	coordinator.submit_local_projectile(
		client_projectile,
		&"probe",
		77,
		Vector2.ZERO,
		Vector2.RIGHT,
		19,
		100.0,
		1.0
	)
	_expect(
		host_request_methods == [&"_rpc_projectile_fired_from_client"],
		"Client 本地预测弹体必须由协调器请求根节点发往 Host。"
	)
	net_manager.net_role = NetManagerStore.NetRole.HOST

	var encoded_host_id := MpProjectileCoordinatorScript.encode_projectile_id(
		7,
		MpProjectileCoordinatorScript.PROJECTILE_ID_HOST_ORIGIN_BIT | 19
	)
	_expect(
		MpProjectileCoordinatorScript.decode_projectile_owner_peer_id(encoded_host_id) == 7
		and MpProjectileCoordinatorScript.decode_projectile_sequence_counter(
			encoded_host_id
		) == 19
		and MpProjectileCoordinatorScript.is_projectile_id_valid_for_host_owner(
			encoded_host_id,
			7
		),
		"弹体 ID 必须稳定编码 owner、序号与 Host 来源位。"
	)

	var finished_projectile := ProbeProjectile.new()
	var finished_id := coordinator.register_local_projectile(
		finished_projectile,
		&"player_bullet",
		2,
		37,
		1.5,
		false,
		true,
		100.0
	)
	_expect(
		finished_id > 0
		and coordinator.get_projectile(finished_id) == finished_projectile
		and coordinator.has_projectile_record(finished_id),
		"本地弹体必须同时登记实例与权威命中记录。"
	)
	var admission := coordinator.prepare_enemy_hit(
		finished_id,
		2,
		41,
		999,
		100.1
	)
	_expect(
		admission != null
		and admission.authoritative_damage == 37
		and admission.consumes_first_confirmed_hit,
		"非穿透玩家弹体必须使用权威伤害且只准入首次命中。"
	)
	if admission != null:
		coordinator.commit_enemy_hit(
			finished_id,
			41,
			admission.consumes_first_confirmed_hit,
			100.1
		)
	_expect(
		coordinator.prepare_enemy_hit(
			finished_id,
			2,
			41,
			37,
			100.2
		) == null,
		"重复或已消费的敌人命中不得再次准入。"
	)
	coordinator.notify_projectile_finished(finished_id, finished_projectile)
	_expect(
		not coordinator.has_projectile(finished_id)
		and coordinator.has_projectile_record(finished_id),
		"弹体结束后应移除实例，但保留短期命中去重记录。"
	)

	var accepted_count := 0
	for sequence in range(1, 66):
		var client_id := MpProjectileCoordinatorScript.encode_projectile_id(4, sequence)
		if coordinator.accept_client_projectile_request_identity(
			4,
			client_id,
			4,
			false,
			200.0
		):
			accepted_count += 1
	_expect(
		accepted_count == 64,
		"同一时刻客户端弹体请求必须严格受 64 次 burst 限制。"
	)
	_expect(
		coordinator.accept_client_projectile_request_identity(
			4,
			MpProjectileCoordinatorScript.encode_projectile_id(4, 66),
			4,
			false,
			200.01
		),
		"令牌桶经过时间推进后必须按既有速率恢复准入。"
	)

	var expiring_id := MpProjectileCoordinatorScript.encode_projectile_id(5, 99)
	coordinator.remember_projectile_record(
		expiring_id,
		5,
		&"player_bullet",
		12,
		1.0,
		false,
		10.0
	)
	coordinator.prune_records(15.999)
	_expect(
		coordinator.has_projectile_record(expiring_id),
		"弹体记录不得在 lifetime 加保留窗之前被清理。"
	)
	coordinator.prune_records(16.0)
	_expect(
		not coordinator.has_projectile_record(expiring_id),
		"弹体记录必须在保留窗边界按原语义清理。"
	)

	var peer_two_projectile := ProbeProjectile.new()
	var peer_three_projectile := ProbeProjectile.new()
	var peer_two_id := coordinator.register_local_projectile(
		peer_two_projectile,
		&"probe",
		2,
		10,
		1.0,
		false,
		true,
		300.0
	)
	var peer_three_id := coordinator.register_local_projectile(
		peer_three_projectile,
		&"probe",
		3,
		10,
		1.0,
		false,
		true,
		300.0
	)
	coordinator.clear_peer(2)
	_expect(
		peer_two_projectile.retired
		and not coordinator.has_projectile(peer_two_id)
		and not coordinator.has_projectile_record(peer_two_id)
		and not peer_three_projectile.retired
		and coordinator.get_projectile(peer_three_id) == peer_three_projectile,
		"peer 清理必须只回收该玩家的弹体、记录与限流状态。"
	)

	coordinator.reset_session_state()
	_expect(
		peer_three_projectile.retired
		and int(coordinator.get_state_metrics().get("next_sequence", -1)) == 1
		and int(coordinator.get_state_metrics().get("known_projectiles", -1)) == 0
		and int(coordinator.get_state_metrics().get("projectile_records", -1)) == 0,
		"会话重置必须回收存活弹体并清空身份、记录和序号状态。"
	)
	coordinator.unbind_runtime(runtime)
	_expect(not coordinator.is_bound(), "解绑后不得保留旧战斗运行时。")
	_expect(
		not coordinator.has_network_facade_dependencies(),
		"解绑运行时后必须释放网络门面依赖。"
	)

	player_coordinator.unbind_runtime(runtime)
	player_coordinator.free()
	net_manager.free()
	host_projectile.free()
	client_projectile.free()
	for tango_projectile in tango_projectiles:
		tango_projectile.free()
	for linglan_projectile in linglan_projectiles:
		linglan_projectile.free()
	finished_projectile.free()
	peer_two_projectile.free()
	peer_three_projectile.free()
	coordinator.free()
	runtime.free()
	if failures.is_empty():
		print("MP_PROJECTILE_COORDINATOR_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _on_rpc_broadcast_requested(
	method_name: StringName,
	arguments: Array
) -> void:
	broadcast_methods.append(method_name)
	broadcast_argument_counts.append(arguments.size())


func _on_rpc_to_host_requested(
	method_name: StringName,
	_arguments: Array
) -> void:
	host_request_methods.append(method_name)
