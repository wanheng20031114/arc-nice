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
const GAMEPLAY_GATEWAY_SCRIPT_PATH := (
	"res://scene/multiplayer/gameplay/multiplayer_gameplay_gateway.gd"
)
const GAMEPLAY_SESSION_SCRIPT_PATH := (
	"res://scene/multiplayer/gameplay/multiplayer_gameplay_session.gd"
)
const MP_GAME_SCRIPT_PATH := "res://scene/multiplayer/mp_game.gd"
const RapidFireSimulationServiceScript := preload(
	"res://scene/combat/simulation/rapid_fire_simulation_service.gd"
)
const EnemyRapidFireNetworkCodecScript := preload(
	"res://scene/multiplayer/projectile/enemy_rapid_fire_network_codec.gd"
)


class ProbeRuntime:
	extends CombatRuntimeBase

	var combat_services: EnemyCombatServices = null

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

	func get_enemy_combat_services() -> EnemyCombatServices:
		return combat_services


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


class RejectingReplicaService:
	extends RapidFireSimulationService

	var registration_calls := 0
	var reject_on_registration_call := -1

	func register_replica_projectile(
		profile: Profile,
		position: Vector2,
		direction: Vector2,
		speed: float,
		lifetime: float,
		source_enemy_id: int,
		projectile_id: int,
		activation_delay_seconds: float
	) -> int:
		registration_calls += 1
		if registration_calls == reject_on_registration_call:
			return INVALID_HANDLE
		return super.register_replica_projectile(
			profile,
			position,
			direction,
			speed,
			lifetime,
			source_enemy_id,
			projectile_id,
			activation_delay_seconds
		)


var failures: Array[String] = []
var broadcast_methods: Array[StringName] = []
var broadcast_argument_counts: Array[int] = []
var broadcast_arguments: Array = []
var host_request_methods: Array[StringName] = []
var peer_rpc_peer_ids: Array[int] = []
var peer_rpc_methods: Array[StringName] = []
var peer_rpc_arguments: Array[Array] = []
var rapid_fire_action_records: Array[Dictionary] = []


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
	var combat_services := EnemyCombatServices.new()
	var replica_service := RapidFireSimulationServiceScript.new()
	replica_service.name = &"RapidFireSimulationService"
	combat_services.add_child(replica_service)
	runtime.combat_services = combat_services
	runtime.add_child(combat_services)
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
	coordinator.rpc_to_peer_requested.connect(_on_rpc_to_peer_requested)
	_expect(
		coordinator.has_network_facade_dependencies(),
		"弹体网络门面必须显式注入 NetManager、玩家协调器与时钟入口。"
	)
	_test_atomic_snapshot_commit(net_manager, player_coordinator)
	var range_coordinator := (
		PROJECTILE_COORDINATOR_SCENE.instantiate() as MpProjectileCoordinatorScript
	)
	range_coordinator.bind_runtime(runtime)
	range_coordinator.bind_network_facade_dependencies(
		net_manager,
		player_coordinator,
		func() -> float: return 400.0,
		func(_host_timestamp: float) -> float: return 0.05,
		func(_peer_id: int) -> bool: return false
	)
	var range_ids := range_coordinator.reserve_host_projectile_id_range(
		MpProjectileCoordinatorScript.PROJECTILE_ID_FALLBACK_OWNER_PEER_ID,
		3
	)
	_expect(
		range_ids.size() == 3
		and range_ids[1] == range_ids[0] + 1
		and range_ids[2] == range_ids[1] + 1
		and range_coordinator.release_reserved_host_projectile_ids(range_ids),
		"Host range reservation 必须一次分配连续身份并支持原子释放。"
	)
	var conflict_first_counter := int(
		range_coordinator.get_state_metrics().get("next_sequence", 0)
	)
	var conflict_id := MpProjectileCoordinatorScript.encode_projectile_id(
		MpProjectileCoordinatorScript.PROJECTILE_ID_FALLBACK_OWNER_PEER_ID,
		MpProjectileCoordinatorScript.PROJECTILE_ID_HOST_ORIGIN_BIT
			| (conflict_first_counter + 1)
	)
	range_coordinator.remember_projectile_record(
		conflict_id,
		MpProjectileCoordinatorScript.PROJECTILE_ID_FALLBACK_OWNER_PEER_ID,
		&"range_conflict",
		1,
		1.0,
		false,
		400.0
	)
	var conflict_rejection := range_coordinator.reserve_host_projectile_id_range(
		MpProjectileCoordinatorScript.PROJECTILE_ID_FALLBACK_OWNER_PEER_ID,
		3
	)
	_expect(
		conflict_rejection.is_empty()
		and int(range_coordinator.get_state_metrics().get("next_sequence", 0))
			== conflict_first_counter
		and int(range_coordinator.get_state_metrics().get(
			"reserved_host_projectile_ids",
			-1
		)) == 0,
		"Range 中任一身份冲突时必须整段拒绝且序号游标保持不变。"
	)
	range_coordinator.set(
		"_next_projectile_sequence",
		MpProjectileCoordinatorScript.PROJECTILE_ID_SEQUENCE_COUNTER_MASK
	)
	var tail_rejection := range_coordinator.reserve_host_projectile_id_range(
		MpProjectileCoordinatorScript.PROJECTILE_ID_FALLBACK_OWNER_PEER_ID,
		2
	)
	_expect(
		tail_rejection.is_empty()
		and int(range_coordinator.get_state_metrics().get("next_sequence", 0))
			== MpProjectileCoordinatorScript.PROJECTILE_ID_SEQUENCE_COUNTER_MASK,
		"Range 跨越 Host 序号尾部时必须整段拒绝且不得提前回绕。"
	)
	range_coordinator.reset_session_state()
	range_coordinator.unbind_runtime(runtime)
	range_coordinator.free()
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
	var gateway_data_registration_source := _get_data_registration_source(
		GAMEPLAY_GATEWAY_SCRIPT_PATH
	)
	var session_data_registration_source := _get_data_registration_source(
		GAMEPLAY_SESSION_SCRIPT_PATH
	)
	var mp_game_data_registration_source := _get_data_registration_source(
		MP_GAME_SCRIPT_PATH
	)
	var coordinator_data_registration_source := _get_data_registration_source(
		PROJECTILE_COORDINATOR_SCRIPT_PATH
	)
	_expect(
		gateway_data_registration_source.count("damage_source_snapshot") == 2
		and session_data_registration_source.count(
			"damage_source_snapshot"
		) == 1
		and mp_game_data_registration_source.count(
			"damage_source_snapshot"
		) == 2
		and coordinator_data_registration_source.contains(
			"damage_source_snapshot: DamageSourceSnapshot = null"
		),
		"Data projectile 的可选来源快照必须贯穿 gateway、session、MpGame 与 coordinator。"
	)

	var host_projectile := ProbeProjectile.new()
	host_projectile.set_meta(
		&"damage_source_snapshot",
		DamageSourceSnapshot.create(3, 7, 99, 0, &"probe_source")
	)
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
	var frozen_source := coordinator.get_projectile_damage_source_snapshot(
		host_projectile.projectile_id
	)
	_expect(
		frozen_source != null
		and frozen_source.source_faction_id == 3
		and frozen_source.credit_peer_id == 7
		and frozen_source.instigator_entity_id == 99
		and frozen_source.event_source_id == host_projectile.projectile_id
		and frozen_source.source_type == &"probe_source",
		"Host 弹体记录必须冻结注册时来源，并以分配后的 projectile_id 补齐事件ID。"
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
	var data_damage_source_snapshot := DamageSourceSnapshot.create(
		CombatRelationService.HOSTILE_WAVE,
		37,
		4201,
		99,
		&"capoo_ak47_data"
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
		1.25,
		data_damage_source_snapshot
	)
	var data_payload := broadcast_arguments.back() as Array
	var data_frozen_source := (
		coordinator.get_projectile_damage_source_snapshot(data_projectile_id)
	)
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
		data_frozen_source != null
		and data_frozen_source.source_faction_id
		== CombatRelationService.HOSTILE_WAVE
		and data_frozen_source.credit_peer_id == 37
		and data_frozen_source.instigator_entity_id == 4201
		and data_frozen_source.event_source_id == data_projectile_id
		and data_frozen_source.source_type == &"capoo_ak47_data",
		"Host data projectile record 必须冻结敌军阵营与 credit，并把事件ID绑定到分配后的 projectile ID。"
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
	client_visual_coordinator.enemy_rapid_fire_action_requested.connect(
		_on_enemy_rapid_fire_action_requested
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

	# Production AK/Gunner routing reserves one contiguous range, attaches Host
	# DATA rows at the authored cadence, and emits exactly one compact burst.
	const RAPID_BURST_COUNT := 32
	var batch_service := RapidFireSimulationServiceScript.new()
	batch_service.reserve_projectile_capacity(RAPID_BURST_COUNT)
	net_manager.net_role = NetManagerStore.NetRole.HOST
	var batch_ids := coordinator.reserve_host_projectile_id_range(
		MpProjectileCoordinatorScript.PROJECTILE_ID_FALLBACK_OWNER_PEER_ID,
		RAPID_BURST_COUNT
	)
	var batch_handles: Array[int] = []
	var batch_directions := PackedVector2Array()
	for shot_index in range(RAPID_BURST_COUNT):
		var direction := Vector2.RIGHT.rotated(
			deg_to_rad(float(shot_index - 16) * 0.2)
		).normalized()
		batch_directions.append(direction)
		batch_handles.append(batch_service.register_projectile(
			RapidFireSimulationServiceScript.Mode.DATA,
			RapidFireSimulationServiceScript.Profile.AK,
			Vector2(50.0, 60.0),
			direction,
			120.0,
			2.0,
			12,
			500,
			0,
			2,
			shot_index % 2
		))
	_expect(
		batch_ids.size() == RAPID_BURST_COUNT
		and batch_handles.size() == RAPID_BURST_COUNT
		and batch_handles[0] > 0
		and coordinator.attach_reserved_local_data_projectile(
			batch_service,
			batch_handles[0],
			batch_ids[0],
			&"capoo_ak47_bullet",
			0,
			12,
			2.0,
			DamageSourceSnapshot.create(
				CombatRelationService.HOSTILE_WAVE,
				57,
				500,
				0,
				&"capoo_ak47_bullet"
			)
		),
		"Rapid burst 首发必须消费连续区间的第一个 Host DATA 身份。"
	)
	var explicit_batch_source := (
		coordinator.get_projectile_damage_source_snapshot(batch_ids[0])
	)
	_expect(
		explicit_batch_source != null
		and explicit_batch_source.source_faction_id
		== CombatRelationService.HOSTILE_WAVE
		and explicit_batch_source.credit_peer_id == 57
		and explicit_batch_source.instigator_entity_id == 500
		and explicit_batch_source.event_source_id == batch_ids[0]
		and explicit_batch_source.source_type == &"capoo_ak47_bullet",
		"Reserved DATA attach 必须冻结敌军来源，并把事件ID重绑到预留 projectile ID。"
	)
	var burst_descriptor := EnemyRapidFireNetworkCodecScript.encode_burst(
		RapidFireSimulationServiceScript.Profile.AK,
		batch_ids[0],
		batch_ids[0],
		500,
		Vector2(42.0, 60.0),
		Vector2(50.0, 60.0),
		Vector2.RIGHT,
		0.08,
		120.0,
		2.0,
		batch_directions
	)
	var rapid_broadcast_count_before := broadcast_methods.size()
	_expect(
		coordinator.broadcast_enemy_rapid_fire_burst(400.0, burst_descriptor)
		and broadcast_methods.size() == rapid_broadcast_count_before + 1
		and broadcast_methods.back() == &"net_enemy_rapid_fire_burst"
		and broadcast_argument_counts.back() == 2
		and burst_descriptor.size() < 1200,
		"首发 attach 后必须立即发送一次小于 1200B 的 burst 描述。"
	)
	peer_rpc_peer_ids.clear()
	peer_rpc_methods.clear()
	peer_rpc_arguments.clear()
	_expect(
		coordinator.send_active_data_visual_snapshot_to_peer(77)
		and peer_rpc_methods == [
			&"net_enemy_rapid_fire_repair_burst",
			&"net_enemy_rapid_fire_snapshot_chunk",
		],
		"进行中 burst 的 repair 必须先可靠补描述，再发送已 attach 前缀快照。"
	)
	peer_rpc_peer_ids.clear()
	peer_rpc_methods.clear()
	peer_rpc_arguments.clear()
	var attached_tail_count := 0
	for shot_index in range(1, RAPID_BURST_COUNT):
		if coordinator.attach_reserved_local_data_projectile(
			batch_service,
			batch_handles[shot_index],
			batch_ids[shot_index],
			&"capoo_ak47_bullet",
			0,
			12,
			2.0
		):
			attached_tail_count += 1
	_expect(
		attached_tail_count == RAPID_BURST_COUNT - 1
		and broadcast_methods.size() == rapid_broadcast_count_before + 1
		and int(coordinator.get_state_metrics().get(
			"reserved_host_projectile_ids",
			-1
		)) == 0,
		"后续逐发 attach 不得新增网络事件，整段 reservation 必须恰好耗尽。"
	)
	var fallback_batch_source := (
		coordinator.get_projectile_damage_source_snapshot(batch_ids[1])
	)
	_expect(
		fallback_batch_source != null
		and fallback_batch_source.source_faction_id
		== CombatRelationService.HOSTILE_WAVE
		and fallback_batch_source.credit_peer_id == 0
		and fallback_batch_source.instigator_entity_id == 500
		and fallback_batch_source.event_source_id == batch_ids[1],
		"Reserved DATA attach 未显式传快照时必须复用 service 的敌军发射快照。"
	)

	# Client receives visual-only rows. Late/duplicate descriptors cannot create
	# a second backend, and an enemy terminal cancels scheduled future rows.
	net_manager.net_role = NetManagerStore.NetRole.CLIENT
	_expect(
		client_visual_coordinator.apply_authority_enemy_rapid_fire_burst(
			1,
			400.0,
			burst_descriptor
		)
		and int(client_visual_coordinator.get_state_metrics().get(
			"known_replica_projectiles",
			-1
		)) == RAPID_BURST_COUNT
		and replica_service.get_active_slot_count() == RAPID_BURST_COUNT
		and int(replica_service.get_metrics().get("world_queries", -1)) == 0
		and int(replica_service.get_metrics().get("damage_applications", -1)) == 0,
		"Client burst 必须只创建无碰撞、无伤害的 REPLICA rows。"
	)
	_expect(
		rapid_fire_action_records.size() == 1
		and int(rapid_fire_action_records[0].get("source_enemy_id", 0)) == 500
		and int(rapid_fire_action_records[0].get("action_id", 0))
			== int(batch_ids[0])
		and rapid_fire_action_records[0].get("source_position")
			== Vector2(42.0, 60.0),
		"首个 burst 必须把动作 ID 与来源位置一并交给客户端表现。"
	)
	_expect(
		client_visual_coordinator.apply_authority_enemy_rapid_fire_burst(
			1,
			400.0,
			burst_descriptor
		)
		and int(client_visual_coordinator.get_state_metrics().get(
			"known_replica_projectiles",
			-1
		)) == RAPID_BURST_COUNT,
		"重复 burst 描述必须按 projectile ID 幂等去重。"
	)
	_expect(
		rapid_fire_action_records.size() == 1,
		"重复 burst 不得重放一次性敌人动作。"
	)
	var prune_passes_before_packet_storm := int(
		client_visual_coordinator.get_state_metrics().get(
			"replica_prune_passes",
			-1
		)
	)
	for _packet_index in range(300):
		client_visual_coordinator.apply_authority_enemy_rapid_fire_burst(
			1,
			400.0,
			burst_descriptor
		)
	_expect(
		int(client_visual_coordinator.get_state_metrics().get(
			"replica_prune_passes",
			-2
		)) == prune_passes_before_packet_storm,
		"300 个同帧 burst 包不得触发任何 replica/去重表全量清理。"
	)
	_expect(
		client_visual_coordinator.release_replica_projectiles_for_source(500)
		== RAPID_BURST_COUNT - 1
		and int(client_visual_coordinator.get_state_metrics().get(
			"known_replica_projectiles",
			-1
		)) == 1
		and client_visual_coordinator.apply_authority_enemy_rapid_fire_burst(
			1,
			400.0,
			burst_descriptor
		)
		and int(client_visual_coordinator.get_state_metrics().get(
			"known_replica_projectiles",
			-1
		)) == 1,
		"敌人终端必须保留已开火视觉、取消未来尾弹并拒绝迟到 burst。"
	)
	var first_finish_descriptor := EnemyRapidFireNetworkCodecScript.encode_finish_batch([
		{
			"projectile_id": int(batch_ids[0]),
			"reason": RapidFireSimulationServiceScript.CompletionReason.WORLD,
			"position": Vector2(54.0, 60.0),
			"direction": Vector2.RIGHT,
		},
	])
	_expect(
		client_visual_coordinator.apply_authority_enemy_rapid_fire_finished_batch(
			1,
			400.2,
			first_finish_descriptor
		)
		and int(client_visual_coordinator.get_state_metrics().get(
			"known_replica_projectiles",
			-1
		)) == 0,
		"Host finish 必须回收已开火视觉，且终端保留弹不再穿墙至寿命结束。"
	)
	client_visual_coordinator.reset_session_state()
	rapid_fire_action_records.clear()
	_expect(
		client_visual_coordinator.release_replica_projectiles_for_source(
			500,
			400.2
		) == 0
		and client_visual_coordinator.apply_authority_enemy_rapid_fire_burst(
			1,
			400.0,
			burst_descriptor
		)
		and int(client_visual_coordinator.get_state_metrics().get(
			"known_replica_projectiles",
			-1
		)) == 3
		and rapid_fire_action_records.size() == 1,
		"CH5 终止先到时必须按 Host 时间恢复终止前3发，并拒绝终止后尾弹。"
	)

	# The 32-row batch plus the earlier live DATA row split into two reliable
	# repair chunks. Applying them in reverse order must remain atomic.
	# in reverse order must be atomic and duplicate-safe.
	client_visual_coordinator.reset_session_state()
	peer_rpc_peer_ids.clear()
	peer_rpc_methods.clear()
	peer_rpc_arguments.clear()
	net_manager.net_role = NetManagerStore.NetRole.HOST
	_expect(
		coordinator.send_active_data_visual_snapshot_to_peer(77)
		and peer_rpc_methods.size() == 2
		and peer_rpc_methods[0]
		== &"net_enemy_rapid_fire_snapshot_chunk"
		and peer_rpc_methods[1]
		== &"net_enemy_rapid_fire_snapshot_chunk",
		"全部 33 个活跃 DATA rows 必须分成两个 peer-specific 视觉快照块。"
	)
	net_manager.net_role = NetManagerStore.NetRole.CLIENT
	if peer_rpc_arguments.size() == 2:
		var tail_chunk := peer_rpc_arguments[1]
		var head_chunk := peer_rpc_arguments[0]
		_expect(
			client_visual_coordinator.apply_authority_enemy_rapid_fire_snapshot_chunk(
				1,
				int(tail_chunk[0]),
				int(tail_chunk[1]),
				int(tail_chunk[2]),
				float(tail_chunk[3]),
				tail_chunk[4] as PackedByteArray
			)
			and int(client_visual_coordinator.get_state_metrics().get(
				"known_replica_projectiles",
				-1
			)) == 0,
			"乱序尾块到达时不得暴露半套快照。"
		)
		_expect(
			client_visual_coordinator.apply_authority_enemy_rapid_fire_snapshot_chunk(
				1,
				int(head_chunk[0]),
				int(head_chunk[1]),
				int(head_chunk[2]),
				float(head_chunk[3]),
				head_chunk[4] as PackedByteArray
			)
			and int(client_visual_coordinator.get_state_metrics().get(
				"known_replica_projectiles",
				-1
			)) == RAPID_BURST_COUNT + 1,
			"全部乱序块收齐后必须原子恢复每个视觉 row。"
		)
		_expect(
			client_visual_coordinator.apply_authority_enemy_rapid_fire_snapshot_chunk(
				1,
				int(head_chunk[0]),
				int(head_chunk[1]),
				int(head_chunk[2]),
				float(head_chunk[3]),
				head_chunk[4] as PackedByteArray
			),
			"已提交快照块的重放必须幂等接受。"
		)
		_expect(
			client_visual_coordinator.apply_authority_enemy_rapid_fire_snapshot_chunk(
				1,
				int(head_chunk[0]) + 1,
				0,
				0,
				401.0,
				PackedByteArray()
			)
			and int(client_visual_coordinator.get_state_metrics().get(
				"known_replica_projectiles",
				-1
			)) == 0,
			"空 repair 快照必须可靠清空上一套视觉 rows。"
		)
	client_visual_coordinator.reset_session_state()
	client_visual_coordinator.unbind_runtime(runtime)
	client_visual_coordinator.free()
	net_manager.net_role = NetManagerStore.NetRole.HOST

	# An interrupted live burst must reliably cancel every reserved future shot.
	# REPLICA rows never collide locally, so losing this terminal description
	# would otherwise create projectiles the Host never fired.
	const CANCELLED_BURST_COUNT := 4
	var cancellation_service := RapidFireSimulationServiceScript.new()
	var cancellation_ids := coordinator.reserve_host_projectile_id_range(
		MpProjectileCoordinatorScript.PROJECTILE_ID_FALLBACK_OWNER_PEER_ID,
		CANCELLED_BURST_COUNT
	)
	var cancellation_directions := PackedVector2Array([
		Vector2.RIGHT,
		Vector2.RIGHT.rotated(0.01),
		Vector2.RIGHT.rotated(0.02),
		Vector2.RIGHT.rotated(0.03),
	])
	var cancellation_handle := cancellation_service.register_projectile(
		RapidFireSimulationServiceScript.Mode.DATA,
		RapidFireSimulationServiceScript.Profile.AK,
		Vector2(70.0, 80.0),
		cancellation_directions[0],
		120.0,
		2.0,
		12,
		501,
		0,
		2,
		0
	)
	var cancellation_descriptor := EnemyRapidFireNetworkCodecScript.encode_burst(
		RapidFireSimulationServiceScript.Profile.AK,
		int(cancellation_ids[0]),
		int(cancellation_ids[0]),
		501,
		Vector2(62.0, 80.0),
		Vector2(70.0, 80.0),
		Vector2.RIGHT,
		0.08,
		120.0,
		2.0,
		cancellation_directions
	)
	var cancellation_broadcast_start := broadcast_methods.size()
	var cancellation_tail := cancellation_ids.slice(1)
	_expect(
		cancellation_ids.size() == CANCELLED_BURST_COUNT
		and cancellation_handle > 0
		and coordinator.attach_reserved_local_data_projectile(
			cancellation_service,
			cancellation_handle,
			int(cancellation_ids[0]),
			&"capoo_ak47_bullet",
			0,
			12,
			2.0
		)
		and coordinator.broadcast_enemy_rapid_fire_burst(
			400.0,
			cancellation_descriptor
		)
		and coordinator.release_reserved_host_projectile_ids(cancellation_tail)
		and coordinator.flush_enemy_rapid_fire_finish_batch(),
		"Host 中断 live burst 必须取消未开火尾段并立即形成终止批次。"
	)
	var cancellation_records: Array = []
	if broadcast_arguments.size() >= cancellation_broadcast_start + 2:
		var cancellation_payload := broadcast_arguments[
			cancellation_broadcast_start + 1
		] as Array
		if cancellation_payload.size() == 2:
			var decoded_cancellations := (
				EnemyRapidFireNetworkCodecScript.decode_finish_batch(
					cancellation_payload[1] as PackedByteArray
				)
			)
			if bool(decoded_cancellations.get("valid", false)):
				cancellation_records = decoded_cancellations.get("records", []) as Array
	var cancellation_ids_match := cancellation_records.size() == 3
	for record_index in range(cancellation_records.size()):
		var cancellation_record := cancellation_records[record_index] as Dictionary
		cancellation_ids_match = (
			cancellation_ids_match
			and int(cancellation_record.get("projectile_id", 0))
				== int(cancellation_ids[record_index + 1])
			and int(cancellation_record.get("reason", 0)) == 4
		)
	_expect(
		broadcast_methods.size() == cancellation_broadcast_start + 2
		and broadcast_methods[cancellation_broadcast_start]
			== &"net_enemy_rapid_fire_burst"
		and broadcast_methods[cancellation_broadcast_start + 1]
			== &"net_enemy_rapid_fire_finished_batch"
		and cancellation_ids_match,
		"取消批次必须按 projectile ID 顺序可靠描述全部未开火尾弹。"
	)
	cancellation_service.release_projectile(cancellation_handle)
	coordinator.notify_data_projectile_finished(
		int(cancellation_ids[0]),
		cancellation_service,
		cancellation_handle
	)
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
		)) == int(duplicate_metrics_before.get("projectile_records", -2)),
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
	var finish_broadcast_start := broadcast_methods.size()
	coordinator.notify_data_projectile_finished(
		data_projectile_id,
		data_service,
		data_handle,
		RapidFireSimulationServiceScript.CompletionReason.WORLD,
		Vector2(18.0, 34.0),
		Vector2.RIGHT
	)
	_expect(
		not coordinator.has_data_projectile(data_projectile_id)
		and coordinator.has_projectile_record(data_projectile_id)
		and data_service.get_active_slot_count() == 0
		and coordinator.flush_enemy_rapid_fire_finish_batch()
		and broadcast_methods.size() == finish_broadcast_start + 1
		and broadcast_methods.back() == &"net_enemy_rapid_fire_finished_batch",
		"Data finish 必须移除精确 backend、保留 record 并合批广播权威终点。"
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
	batch_service.prepare_for_runtime_teardown()
	batch_service.free()
	cancellation_service.prepare_for_runtime_teardown()
	cancellation_service.free()
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


func _get_data_registration_source(script_path: String) -> String:
	var source := FileAccess.get_file_as_string(script_path)
	var function_start := source.find("func register_local_data_projectile(")
	if function_start < 0:
		return ""
	var function_end := source.find("\nfunc ", function_start + 1)
	var next_abstract := source.find("\n@abstract", function_start + 1)
	if function_end < 0:
		function_end = source.length()
	if next_abstract >= 0:
		function_end = mini(function_end, next_abstract)
	return source.substr(function_start, function_end - function_start)


func _test_atomic_snapshot_commit(
	net_manager: NetManagerStore,
	player_coordinator: MpPlayerCoordinator
) -> void:
	var atomic_runtime := ProbeRuntime.new()
	var atomic_services := EnemyCombatServices.new()
	var rejecting_service := RejectingReplicaService.new()
	rejecting_service.name = &"RapidFireSimulationService"
	atomic_services.add_child(rejecting_service)
	atomic_runtime.combat_services = atomic_services
	atomic_runtime.add_child(atomic_services)
	var atomic_coordinator := (
		PROJECTILE_COORDINATOR_SCENE.instantiate() as MpProjectileCoordinatorScript
	)
	atomic_coordinator.bind_runtime(atomic_runtime)
	atomic_coordinator.bind_network_facade_dependencies(
		net_manager,
		player_coordinator,
		func() -> float: return 400.0,
		func(_host_timestamp: float) -> float: return 0.05,
		func(_peer_id: int) -> bool: return false
	)
	net_manager.net_role = NetManagerStore.NetRole.CLIENT
	var projectile_ids := PackedInt64Array()
	for sequence_offset in range(3):
		projectile_ids.append(MpProjectileCoordinatorScript.encode_projectile_id(
			MpProjectileCoordinatorScript.PROJECTILE_ID_FALLBACK_OWNER_PEER_ID,
			MpProjectileCoordinatorScript.PROJECTILE_ID_HOST_ORIGIN_BIT
				| (1001 + sequence_offset)
		))
	var initial_records: Array[Dictionary] = [{
		"projectile_id": int(projectile_ids[0]),
		"profile": RapidFireSimulationServiceScript.Profile.AK,
		"source_enemy_id": 601,
		"position": Vector2(1.0, 2.0),
		"direction": Vector2.RIGHT,
		"speed": 100.0,
		"remaining_lifetime": 1.0,
	}]
	var initial_descriptor := (
		EnemyRapidFireNetworkCodecScript.encode_snapshot_chunk(initial_records)
	)
	_expect(
		atomic_coordinator.apply_authority_enemy_rapid_fire_snapshot_chunk(
			1,
			1,
			0,
			1,
			400.0,
			initial_descriptor
		)
		and int(atomic_coordinator.get_state_metrics().get(
			"known_replica_projectiles",
			-1
		)) == 1,
		"事务快照负控必须先建立一套可观察的旧 replica。"
	)
	var replacement_records: Array[Dictionary] = []
	for record_index in range(2):
		replacement_records.append({
			"projectile_id": int(projectile_ids[record_index + 1]),
			"profile": RapidFireSimulationServiceScript.Profile.AK,
			"source_enemy_id": 602,
			"position": Vector2(10.0 + record_index, 20.0),
			"direction": Vector2.RIGHT,
			"speed": 100.0,
			"remaining_lifetime": 1.0,
		})
	var replacement_descriptor := (
		EnemyRapidFireNetworkCodecScript.encode_snapshot_chunk(replacement_records)
	)
	rejecting_service.reject_on_registration_call = (
		rejecting_service.registration_calls + 2
	)
	_expect(
		not atomic_coordinator.apply_authority_enemy_rapid_fire_snapshot_chunk(
			1,
			2,
			0,
			1,
			401.0,
			replacement_descriptor
		)
		and int(atomic_coordinator.get_state_metrics().get(
			"known_replica_projectiles",
			-1
		)) == 1
		and int(atomic_coordinator.get_state_metrics().get(
			"latest_rapid_fire_snapshot_id",
			-1
		)) == 1
		and rejecting_service.get_active_slot_count() == 1,
		"第 N 条注册失败时必须保留完整旧快照且不得推进水位线。"
	)
	rejecting_service.reject_on_registration_call = -1
	_expect(
		atomic_coordinator.apply_authority_enemy_rapid_fire_snapshot_chunk(
			1,
			2,
			0,
			1,
			401.0,
			replacement_descriptor
		)
		and int(atomic_coordinator.get_state_metrics().get(
			"known_replica_projectiles",
			-1
		)) == 2
		and int(atomic_coordinator.get_state_metrics().get(
			"latest_rapid_fire_snapshot_id",
			-1
		)) == 2
		and rejecting_service.get_active_slot_count() == 2,
		"同一事务快照重试成功后才可一次替换旧 replica 并推进水位线。"
	)
	atomic_coordinator.reset_session_state()
	atomic_coordinator.unbind_runtime(atomic_runtime)
	atomic_coordinator.free()
	rejecting_service.prepare_for_runtime_teardown()
	atomic_runtime.free()
	net_manager.net_role = NetManagerStore.NetRole.HOST


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


func _on_rpc_to_peer_requested(
	peer_id: int,
	method_name: StringName,
	arguments: Array
) -> void:
	peer_rpc_peer_ids.append(peer_id)
	peer_rpc_methods.append(method_name)
	peer_rpc_arguments.append(arguments.duplicate(true))


func _on_enemy_rapid_fire_action_requested(
	source_enemy_id: int,
	profile: int,
	direction: Vector2,
	source_position: Vector2,
	action_id: int,
	host_action_timestamp: float,
	action_elapsed: float
) -> void:
	rapid_fire_action_records.append({
		"source_enemy_id": source_enemy_id,
		"profile": profile,
		"direction": direction,
		"source_position": source_position,
		"action_id": action_id,
		"host_action_timestamp": host_action_timestamp,
		"action_elapsed": action_elapsed,
	})
