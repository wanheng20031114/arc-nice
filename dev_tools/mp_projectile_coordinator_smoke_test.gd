extends SceneTree

const PROJECTILE_COORDINATOR_SCENE := preload(
	"res://scene/multiplayer/projectile/mp_projectile_coordinator.tscn"
)
const MpProjectileCoordinatorScript := preload(
	"res://scene/multiplayer/projectile/mp_projectile_coordinator.gd"
)
const PROJECTILE_COORDINATOR_SCRIPT_PATH := (
	"res://scene/multiplayer/projectile/mp_projectile_coordinator.gd"
)
const RapidFireSimulationServiceScript := preload(
	"res://scene/combat/simulation/rapid_fire_simulation_service.gd"
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
		return get_network_enemy(net_id)

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
var broadcast_arguments: Array = []
var host_request_methods: Array[StringName] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var coordinator := (
		PROJECTILE_COORDINATOR_SCENE.instantiate() as MpProjectileCoordinatorScript
	)
	var runtime := ProbeRuntime.new()
	var runtime_gateway := MultiplayerGameplayGateway.new()
	runtime_gateway.name = &"MultiplayerGameplayGateway"
	runtime.add_child(runtime_gateway)
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
	var coordinator_source := FileAccess.get_file_as_string(
		PROJECTILE_COORDINATOR_SCRIPT_PATH
	)
	_expect(
		not coordinator_source.contains("DataProjectileBackend")
		and coordinator_source.contains(
			"_known_data_projectile_services: Dictionary"
		)
		and coordinator_source.contains(
			"_known_data_projectile_handles: Dictionary"
		),
		"Data backend 必须使用 id→service/id→handle 平行存储，不得逐发分配对象。"
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

	var data_service := RapidFireSimulationServiceScript.new()
	data_service.reserve_projectile_capacity(3)
	var data_handle := _register_data_projectile_handle(
		data_service,
		Vector2(12.0, 34.0)
	)
	var data_broadcast_count_before := broadcast_methods.size()
	var data_record_count_before := int(
		coordinator.get_state_metrics().get("projectile_records", -1)
	)
	var data_projectile_id := coordinator.register_local_data_projectile(
		data_service,
		data_handle,
		&"capoo_ak47_bullet",
		0,
		Vector2(12.0, 34.0),
		Vector2.RIGHT,
		23,
		160.0,
		1.25
	)
	var data_payload := broadcast_arguments.back() as Array
	_expect(
		data_projectile_id > 0
		and MpProjectileCoordinatorScript.is_projectile_id_valid_for_host_owner(
			data_projectile_id,
			MpProjectileCoordinatorScript.PROJECTILE_ID_FALLBACK_OWNER_PEER_ID
		)
		and data_service.get_projectile_id(data_handle) == data_projectile_id
		and coordinator.has_data_projectile(data_projectile_id)
		and not coordinator.has_projectile(data_projectile_id)
		and coordinator.has_projectile_record(data_projectile_id)
		and int(coordinator.get_state_metrics().get(
			"known_data_projectiles",
			-1
		)) == 1,
		"Host data handle 必须获得现有 projectile ID、record 与唯一 data backend。"
	)
	_expect(
		broadcast_methods.size() == data_broadcast_count_before + 1
		and broadcast_methods.back() == &"net_projectile_fired"
		and broadcast_argument_counts.back() == 12
		and data_payload.size() == 12
		and int(data_payload[0]) == data_projectile_id
		and String(data_payload[1]) == "capoo_ak47_bullet"
		and int(data_payload[2]) == 0
		and data_payload[3] == Vector2(12.0, 34.0)
		and data_payload[4] == Vector2.RIGHT
		and int(data_payload[5]) == 23
		and is_equal_approx(float(data_payload[6]), 160.0)
		and is_equal_approx(float(data_payload[7]), 1.25)
		and not bool(data_payload[8])
		and int(data_payload[9]) == 0
		and int(data_payload[11]) == 0,
		"Data handle 必须复用既有 net_projectile_fired 12 字段载荷。"
	)
	var client_visual_coordinator := (
		PROJECTILE_COORDINATOR_SCENE.instantiate() as MpProjectileCoordinatorScript
	)
	client_visual_coordinator.bind_runtime(runtime)
	client_visual_coordinator.bind_network_facade_dependencies(
		net_manager,
		player_coordinator,
		func() -> float: return 400.0,
		func(_host_timestamp: float) -> float: return 0.05,
		func(_peer_id: int) -> bool: return false
	)
	net_manager.net_role = NetManagerStore.NetRole.CLIENT
	client_visual_coordinator.receive_projectile_fired(
		data_projectile_id,
		&"capoo_ak47_bullet",
		0,
		Vector2(12.0, 34.0),
		Vector2.RIGHT,
		23,
		160.0,
		1.25,
		false,
		0,
		0,
		0.0,
		400.0
	)
	var client_visual_proxy := client_visual_coordinator.get_projectile(
		data_projectile_id
	)
	_expect(
		client_visual_proxy is CapooAK47Bullet
		and not client_visual_coordinator.has_data_projectile(data_projectile_id),
		"Client 收到既有广播后必须继续实例化旧 CapooAK47Bullet 视觉代理。"
	)
	client_visual_coordinator.notify_projectile_finished(
		data_projectile_id,
		client_visual_proxy
	)
	if client_visual_proxy != null and is_instance_valid(client_visual_proxy):
		client_visual_proxy.free()
	client_visual_coordinator.reset_session_state()
	client_visual_coordinator.unbind_runtime(runtime)
	client_visual_coordinator.free()
	net_manager.net_role = NetManagerStore.NetRole.HOST
	coordinator.receive_projectile_fired(
		data_projectile_id,
		&"capoo_ak47_bullet",
		0,
		Vector2(12.0, 34.0),
		Vector2.RIGHT,
		23,
		160.0,
		1.25,
		false,
		0,
		0,
		0.0,
		400.0
	)
	_expect(
		coordinator.has_data_projectile(data_projectile_id)
		and not coordinator.has_projectile(data_projectile_id),
		"同一 projectile ID 已有 data backend 时不得再生成 Node backend。"
	)

	var duplicate_metrics_before := coordinator.get_state_metrics()
	var duplicate_broadcast_count_before := broadcast_methods.size()
	_expect(
		coordinator.register_local_data_projectile(
			data_service,
			data_handle,
			&"capoo_ak47_bullet",
			0,
			Vector2(12.0, 34.0),
			Vector2.RIGHT,
			23,
			160.0,
			1.25
		) == 0
		and broadcast_methods.size() == duplicate_broadcast_count_before
		and int(coordinator.get_state_metrics().get(
			"known_data_projectiles",
			-1
		)) == int(duplicate_metrics_before.get("known_data_projectiles", -2))
		and int(coordinator.get_state_metrics().get(
			"projectile_records",
			-1
		)) == data_record_count_before + 1,
		"重复 handle 的 assign 失败必须原子保持 backend/record 且不广播。"
	)
	coordinator.notify_data_projectile_finished(
		data_projectile_id,
		data_service,
		data_handle + 1
	)
	_expect(
		coordinator.has_data_projectile(data_projectile_id),
		"错误 handle 的 finish 不得移除 live data backend。"
	)
	data_service.release_projectile(data_handle)
	coordinator.notify_data_projectile_finished(
		data_projectile_id,
		data_service,
		data_handle
	)
	_expect(
		not coordinator.has_data_projectile(data_projectile_id)
		and coordinator.has_projectile_record(data_projectile_id)
		and data_service.get_active_slot_count() == 0,
		"Data finish 只移除精确 live backend，并保留短期 record。"
	)

	var client_data_service := RapidFireSimulationServiceScript.new()
	var client_data_handle := _register_data_projectile_handle(
		client_data_service,
		Vector2.ZERO
	)
	net_manager.net_role = NetManagerStore.NetRole.CLIENT
	var client_broadcast_count_before := broadcast_methods.size()
	var client_request_count_before := host_request_methods.size()
	_expect(
		coordinator.register_local_data_projectile(
			client_data_service,
			client_data_handle,
			&"capoo_ak47_bullet",
			0,
			Vector2.ZERO,
			Vector2.RIGHT,
			9,
			120.0,
			1.0
		) == 0
		and client_data_service.get_projectile_id(client_data_handle) == 0
		and broadcast_methods.size() == client_broadcast_count_before
		and host_request_methods.size() == client_request_count_before,
		"Client 不得登记或上行权威 data projectile。"
	)
	net_manager.net_role = NetManagerStore.NetRole.HOST
	client_data_service.release_projectile(client_data_handle)

	var offline_gateway := MultiplayerGameplayGateway.new()
	var offline_data_service := RapidFireSimulationServiceScript.new()
	var offline_data_handle := _register_data_projectile_handle(
		offline_data_service,
		Vector2.ONE
	)
	_expect(
		offline_gateway.register_local_data_projectile(
			offline_data_service,
			offline_data_handle,
			&"capoo_ak47_bullet",
			0,
			Vector2.ONE,
			Vector2.RIGHT,
			7,
			100.0,
			1.0
		) == 0
		and offline_data_service.get_projectile_id(offline_data_handle) == 0,
		"单机 gateway 无 session 时必须返回 0 且不改变 data handle。"
	)
	offline_data_service.release_projectile(offline_data_handle)
	offline_gateway.free()

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
	var peer_data_service := RapidFireSimulationServiceScript.new()
	peer_data_service.reserve_projectile_capacity(2)
	var peer_two_data_handle := _register_data_projectile_handle(
		peer_data_service,
		Vector2(2.0, 0.0)
	)
	var peer_three_data_handle := _register_data_projectile_handle(
		peer_data_service,
		Vector2(3.0, 0.0)
	)
	var peer_two_data_id := coordinator.register_local_data_projectile(
		peer_data_service,
		peer_two_data_handle,
		&"capoo_ak47_bullet",
		2,
		Vector2(2.0, 0.0),
		Vector2.RIGHT,
		10,
		100.0,
		1.0
	)
	var peer_three_data_id := coordinator.register_local_data_projectile(
		peer_data_service,
		peer_three_data_handle,
		&"capoo_ak47_bullet",
		3,
		Vector2(3.0, 0.0),
		Vector2.RIGHT,
		10,
		100.0,
		1.0
	)
	_expect(
		peer_two_data_id > 0
		and peer_three_data_id > 0
		and peer_data_service.get_active_slot_count() == 2,
		"Peer clear/reset 前必须登记两个 live data handles。"
	)
	coordinator.clear_projectile_records_for_peer(2)
	coordinator.clear_peer(2)
	_expect(
		peer_two_projectile.retired
		and not coordinator.has_projectile(peer_two_id)
		and not coordinator.has_projectile_record(peer_two_id)
		and not peer_three_projectile.retired
		and coordinator.get_projectile(peer_three_id) == peer_three_projectile
		and not coordinator.has_data_projectile(peer_two_data_id)
		and not coordinator.has_projectile_record(peer_two_data_id)
		and coordinator.has_data_projectile(peer_three_data_id)
		and peer_data_service.get_active_slot_count() == 1,
		"peer 清理必须只回收该玩家的 Node/data 弹体、记录与限流状态。"
	)

	coordinator.reset_session_state()
	_expect(
		peer_three_projectile.retired
		and peer_data_service.get_active_slot_count() == 0
		and int(coordinator.get_state_metrics().get("next_sequence", -1)) == 1
		and int(coordinator.get_state_metrics().get("known_projectiles", -1)) == 0
		and int(coordinator.get_state_metrics().get(
			"known_data_projectiles",
			-1
		)) == 0
		and int(coordinator.get_state_metrics().get("projectile_records", -1)) == 0,
		"会话重置必须回收存活 Node/data 弹体并清空身份、记录和序号状态。"
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
	data_service.prepare_for_runtime_teardown()
	data_service.free()
	client_data_service.prepare_for_runtime_teardown()
	client_data_service.free()
	offline_data_service.prepare_for_runtime_teardown()
	offline_data_service.free()
	peer_data_service.prepare_for_runtime_teardown()
	peer_data_service.free()
	coordinator.free()
	runtime.free()
	if failures.is_empty():
		print("MP_PROJECTILE_COORDINATOR_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _register_data_projectile_handle(
	service: RapidFireSimulationServiceScript,
	position: Vector2
) -> int:
	return service.register_projectile(
		RapidFireSimulationServiceScript.Mode.DATA,
		RapidFireSimulationServiceScript.Profile.AK,
		position,
		Vector2.RIGHT,
		120.0,
		2.0,
		12,
		500,
		0,
		2,
		0
	)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _on_rpc_broadcast_requested(
	method_name: StringName,
	arguments: Array
) -> void:
	broadcast_methods.append(method_name)
	broadcast_argument_counts.append(arguments.size())
	broadcast_arguments.append(arguments.duplicate())


func _on_rpc_to_host_requested(
	method_name: StringName,
	_arguments: Array
) -> void:
	host_request_methods.append(method_name)
