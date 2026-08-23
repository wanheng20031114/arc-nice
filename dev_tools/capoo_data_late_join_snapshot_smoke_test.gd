extends SceneTree

const FIXTURE_SCENE := preload(
	"res://dev_tools/fixtures/enemy_gameplay_gateway_test_runtime.tscn"
)
const COORDINATOR_SCENE := preload(
	"res://scene/multiplayer/projectile/mp_projectile_coordinator.tscn"
)
const RPGServiceScript := preload(
	"res://scene/combat/simulation/capoo_rpg_rocket_simulation_service.gd"
)
const MageServiceScript := preload(
	"res://scene/combat/simulation/capoo_mage_fireball_simulation_service.gd"
)

const MAGE_TYPE := &"capoo_mage_fireball"
const RPG_TYPE := &"capoo_rpg_rocket"
const SPAWN_POSITION := Vector2(120.0, 80.0)
const DIRECTION := Vector2(0.6, 0.8)
const DAMAGE := 34
const MAGE_SPEED := 155.0
const RPG_SPEED := 180.0
const LIFETIME := 6.0
const HOST_TIME := 400.0
const OWNER_PEER_ID := 9
const TARGET_PEER_ID := 7
const TARGET_WORLD_NET_ID := 93


class TargetModeAdapter:
	extends MultiplayerModeAdapter

	var target_net_id := 0
	var target: Node2D = null

	func get_network_projectile_world_target(net_id: int) -> Node2D:
		return target if net_id == target_net_id else null


var failures: Array[String] = []
var late_join_payloads: Array[Array] = []


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	var runtime := FIXTURE_SCENE.instantiate() as EnemyGameplayGatewayTestRuntime
	_expect(runtime != null, "The authored combat runtime fixture must instantiate.")
	if runtime == null:
		_finish()
		return
	root.add_child(runtime)
	await process_frame
	var combat_services := runtime.get_enemy_combat_services()
	var mage_service: MageServiceScript = (
		combat_services.get_capoo_mage_fireball_simulation_service()
		if combat_services != null
		else null
	)
	var rpg_service: RPGServiceScript = (
		combat_services.get_capoo_rpg_rocket_simulation_service()
		if combat_services != null
		else null
	)
	_expect(
		combat_services != null
		and mage_service != null
		and rpg_service != null,
		"Late-join coverage requires both authored Capoo simulation services."
	)
	if combat_services == null or mage_service == null or rpg_service == null:
		runtime.queue_free()
		await process_frame
		_finish()
		return
	combat_services.set_physics_process(false)
	mage_service.set_physics_process(false)
	rpg_service.set_physics_process(false)

	var peer_target := Player.new()
	peer_target.global_position = Vector2(-180.0, -120.0)
	var world_target := PlantDefense.new()
	world_target.global_position = Vector2(360.0, 40.0)
	var target_adapter := TargetModeAdapter.new()
	target_adapter.target_net_id = TARGET_WORLD_NET_ID
	target_adapter.bind_runtime(runtime)
	runtime.multiplayer_mode_adapter = target_adapter

	var player_coordinator := MpPlayerCoordinator.new()
	player_coordinator.bind_runtime(runtime)
	var host_net_manager := _make_net_manager(NetManagerStore.NetRole.HOST)
	var client_net_manager := _make_net_manager(NetManagerStore.NetRole.CLIENT)
	var host_coordinator := _make_coordinator(
		runtime,
		player_coordinator,
		host_net_manager
	)
	var client_coordinator := _make_coordinator(
		runtime,
		player_coordinator,
		client_net_manager
	)
	host_coordinator.rpc_to_peer_requested.connect(
		func(peer_id: int, method_name: StringName, arguments: Array) -> void:
			if peer_id == 77 and method_name == &"net_projectile_fired":
				late_join_payloads.append(arguments)
	)

	var peer_source := _make_source(MAGE_TYPE, 731)
	var peer_mage_handle := _spawn_mage(
		mage_service,
		peer_source,
		peer_target
	)
	var peer_mage_id := _register_mage(
		host_coordinator,
		mage_service,
		peer_mage_handle,
		peer_source,
		TARGET_PEER_ID,
		0
	)
	var rpg_source := _make_source(RPG_TYPE, 732)
	var rpg_handle := _spawn_rpg(rpg_service, rpg_source)
	var rpg_id := host_coordinator.register_local_capoo_rpg_data(
		rpg_service,
		rpg_handle,
		RPG_TYPE,
		OWNER_PEER_ID,
		SPAWN_POSITION,
		DIRECTION,
		DAMAGE,
		RPG_SPEED,
		LIFETIME,
		rpg_source
	)
	var world_source := _make_source(MAGE_TYPE, 733)
	var world_mage_handle := _spawn_mage(
		mage_service,
		world_source,
		world_target
	)
	var world_mage_id := _register_mage(
		host_coordinator,
		mage_service,
		world_mage_handle,
		world_source,
		0,
		TARGET_WORLD_NET_ID
	)
	_expect(
		peer_mage_id > 0
		and rpg_id > peer_mage_id
		and world_mage_id > rpg_id,
		"The fixture must interleave Mage/RPG/Mage IDs before sorting."
	)

	await physics_frame
	mage_service.advance(0.2)
	rpg_service.advance(0.2)
	_expect(
		host_coordinator.send_active_data_visual_snapshot_to_peer(77),
		"Host late-join snapshot dispatch must succeed."
	)
	_expect(
		late_join_payloads.size() == 3
		and int(late_join_payloads[0][0]) == peer_mage_id
		and int(late_join_payloads[1][0]) == rpg_id
		and int(late_join_payloads[2][0]) == world_mage_id,
		"RPG and Mage DATA snapshots must share one projectile-ID stable order."
	)
	_expect(
		_is_current_mage_payload(
			late_join_payloads[0],
			mage_service,
			peer_mage_handle,
			TARGET_PEER_ID,
			0
		)
		and _is_current_rpg_payload(
			late_join_payloads[1],
			rpg_service,
			rpg_handle
		)
		and _is_current_mage_payload(
			late_join_payloads[2],
			mage_service,
			world_mage_handle,
			0,
			TARGET_WORLD_NET_ID
		),
		"Each 17-field late-join payload must use live motion, remaining lifetime, target IDs, current snapshot time, and frozen source."
	)

	var original_late_join_payloads := late_join_payloads.duplicate(true)
	for payload in late_join_payloads:
		_apply_payload(client_coordinator, payload)
	var peer_mage_replica := _find_mage_handle(
		mage_service,
		peer_mage_id,
		MageServiceScript.Mode.REPLICA
	)
	var rpg_replica := _find_rpg_handle(
		rpg_service,
		rpg_id,
		RPGServiceScript.Mode.REPLICA
	)
	var world_mage_replica := _find_mage_handle(
		mage_service,
		world_mage_id,
		MageServiceScript.Mode.REPLICA
	)
	_expect(
		peer_mage_replica > MageServiceScript.INVALID_HANDLE
		and rpg_replica > RPGServiceScript.INVALID_HANDLE
		and world_mage_replica > MageServiceScript.INVALID_HANDLE
		and mage_service.get_position(peer_mage_replica).is_equal_approx(
			mage_service.get_position(peer_mage_handle)
		)
		and rpg_service.get_position(rpg_replica).is_equal_approx(
			rpg_service.get_position(rpg_handle)
		)
		and mage_service.get_target_instance_id(peer_mage_replica) == 0
		and mage_service.get_target_instance_id(world_mage_replica) == 0
		and _count_legacy_nodes(runtime) == 0,
		"Projectile-first delivery must create pure REPLICA rows at the current state without inventing unavailable targets or applying a second historical compensation."
	)
	_expect(
		not mage_service.rebind_replica_target(
			peer_mage_handle,
			peer_target
		)
		and not mage_service.rebind_replica_target(
			MageServiceScript.INVALID_HANDLE,
			peer_target
		),
		"The target-rebind interface must reject authoritative and invalid handles."
	)
	var peer_direction_before_rebind := mage_service.get_direction(
		peer_mage_replica
	)
	var world_direction_before_rebind := mage_service.get_direction(
		world_mage_replica
	)
	runtime.peer_players[TARGET_PEER_ID] = peer_target
	target_adapter.target = world_target
	client_coordinator.prune_records(HOST_TIME)
	_expect(
		mage_service.get_target_instance_id(peer_mage_replica)
			== peer_target.get_instance_id()
		and mage_service.get_target(peer_mage_replica) == peer_target
		and mage_service.get_target_instance_id(world_mage_replica)
			== world_target.get_instance_id()
		and mage_service.get_target(world_mage_replica) == world_target
		and int(client_coordinator.get_state_metrics()[
			"capoo_mage_replica_target_records"
		]) == 2,
		"Regular coordinator maintenance must idempotently bind player and world targets that arrive after their Mage projectiles."
	)
	await physics_frame
	mage_service.advance(0.1)
	_expect(
		not mage_service.get_direction(peer_mage_replica).is_equal_approx(
			peer_direction_before_rebind
		)
		and not mage_service.get_direction(world_mage_replica).is_equal_approx(
			world_direction_before_rebind
		),
		"Late-bound Mage replicas must resume homing on the next simulation step."
	)
	var mage_dense_count := mage_service.get_dense_record_count()
	var rpg_dense_count := rpg_service.get_dense_record_count()
	for payload in original_late_join_payloads:
		_apply_payload(client_coordinator, payload)
	_expect(
		mage_service.get_dense_record_count() == mage_dense_count
		and rpg_service.get_dense_record_count() == rpg_dense_count
		and int(client_coordinator.get_state_metrics()[
			"known_capoo_mage_replicas"
		]) == 2
		and int(client_coordinator.get_state_metrics()[
			"known_capoo_rpg_replicas"
		]) == 1
		and int(client_coordinator.get_state_metrics()[
			"capoo_mage_replica_target_records"
		]) == 2,
		"Repeated late-join payloads must be rejected by the existing ID maps/records."
	)

	await physics_frame
	mage_service.advance(LIFETIME)
	rpg_service.advance(LIFETIME)
	late_join_payloads.clear()
	_expect(
		host_coordinator.send_active_data_visual_snapshot_to_peer(77),
		"An expired late-join snapshot pass must still complete."
	)
	client_coordinator.prune_records(HOST_TIME)
	_expect(
		late_join_payloads.is_empty()
		and int(host_coordinator.get_state_metrics()[
			"known_capoo_mage_data"
		]) == 0
		and int(host_coordinator.get_state_metrics()[
			"known_capoo_rpg_data"
		]) == 0
		and int(host_coordinator.get_state_metrics()[
			"capoo_mage_late_join_records"
		]) == 0
		and int(client_coordinator.get_state_metrics()[
			"known_capoo_mage_replicas"
		]) == 0
		and int(client_coordinator.get_state_metrics()[
			"known_capoo_rpg_replicas"
		]) == 0
		and int(client_coordinator.get_state_metrics()[
			"capoo_mage_replica_target_records"
		]) == 0,
		"Expired DATA/REPLICA handles must be pruned and omitted from later snapshots."
	)
	for payload in original_late_join_payloads:
		_apply_payload(client_coordinator, payload)
	_expect(
		mage_service.get_live_count() == 0
		and rpg_service.get_live_count() == 0,
		"Expired records must not be resurrected by duplicate snapshot delivery."
	)
	mage_service.clear_completion_records()
	rpg_service.clear_completion_records()

	var clear_mage_source := _make_source(MAGE_TYPE, 734)
	var clear_mage_handle := _spawn_mage(
		mage_service,
		clear_mage_source,
		peer_target
	)
	var clear_mage_id := _register_mage(
		host_coordinator,
		mage_service,
		clear_mage_handle,
		clear_mage_source,
		TARGET_PEER_ID,
		0
	)
	var clear_rpg_source := _make_source(RPG_TYPE, 735)
	var clear_rpg_handle := _spawn_rpg(rpg_service, clear_rpg_source)
	var clear_rpg_id := host_coordinator.register_local_capoo_rpg_data(
		rpg_service, clear_rpg_handle, RPG_TYPE, OWNER_PEER_ID,
		SPAWN_POSITION, DIRECTION, DAMAGE, RPG_SPEED, LIFETIME,
		clear_rpg_source
	)
	late_join_payloads.clear()
	host_coordinator.send_active_data_visual_snapshot_to_peer(77)
	for payload in late_join_payloads:
		_apply_payload(client_coordinator, payload)
	var clear_mage_replica := _find_mage_handle(
		mage_service,
		clear_mage_id,
		MageServiceScript.Mode.REPLICA
	)
	var clear_rpg_replica := _find_rpg_handle(
		rpg_service,
		clear_rpg_id,
		RPGServiceScript.Mode.REPLICA
	)
	host_coordinator.clear_peer(OWNER_PEER_ID)
	client_coordinator.clear_peer(OWNER_PEER_ID)
	_expect(
		not mage_service.is_handle_live(clear_mage_handle)
		and not mage_service.is_handle_live(clear_mage_replica)
		and not rpg_service.is_handle_live(clear_rpg_handle)
		and not rpg_service.is_handle_live(clear_rpg_replica)
		and int(host_coordinator.get_state_metrics()[
			"known_capoo_mage_data"
		]) == 0
		and int(host_coordinator.get_state_metrics()[
			"known_capoo_rpg_data"
		]) == 0
		and int(host_coordinator.get_state_metrics()[
			"capoo_mage_late_join_records"
		]) == 0
		and int(client_coordinator.get_state_metrics()[
			"capoo_mage_replica_target_records"
		]) == 0
		and not host_coordinator.has_projectile_record(clear_mage_id)
		and not host_coordinator.has_projectile_record(clear_rpg_id),
		"Peer clear must release both snapshot families and erase Mage target metadata."
	)

	var reset_source := _make_source(MAGE_TYPE, 736)
	var reset_data_handle := _spawn_mage(
		mage_service,
		reset_source,
		peer_target
	)
	var reset_projectile_id := _register_mage(
		host_coordinator,
		mage_service,
		reset_data_handle,
		reset_source,
		TARGET_PEER_ID,
		0
	)
	late_join_payloads.clear()
	host_coordinator.send_active_data_visual_snapshot_to_peer(77)
	for payload in late_join_payloads:
		_apply_payload(client_coordinator, payload)
	var reset_replica_handle := _find_mage_handle(
		mage_service,
		reset_projectile_id,
		MageServiceScript.Mode.REPLICA
	)
	_expect(
		reset_data_handle > MageServiceScript.INVALID_HANDLE
		and reset_replica_handle > MageServiceScript.INVALID_HANDLE
		and int(host_coordinator.get_state_metrics()[
			"capoo_mage_late_join_records"
		]) == 1
		and int(client_coordinator.get_state_metrics()[
			"capoo_mage_replica_target_records"
		]) == 1,
		"The reset fixture must own one live DATA/REPLICA pair and both target ledgers."
	)
	host_coordinator.reset_session_state()
	client_coordinator.reset_session_state()
	_expect(
		not mage_service.is_handle_live(reset_data_handle)
		and not mage_service.is_handle_live(reset_replica_handle)
		and int(host_coordinator.get_state_metrics()[
			"known_capoo_mage_data"
		]) == 0
		and int(host_coordinator.get_state_metrics()[
			"capoo_mage_late_join_records"
		]) == 0
		and int(client_coordinator.get_state_metrics()[
			"known_capoo_mage_replicas"
		]) == 0
		and int(client_coordinator.get_state_metrics()[
			"capoo_mage_replica_target_records"
		]) == 0,
		"Session reset must release live Mage backends and erase both target ledgers."
	)
	host_coordinator.unbind_runtime(runtime)
	client_coordinator.unbind_runtime(runtime)
	player_coordinator.unbind_runtime(runtime)
	host_coordinator.free()
	client_coordinator.free()
	player_coordinator.free()
	host_net_manager.free()
	client_net_manager.free()
	runtime.peer_players.erase(TARGET_PEER_ID)
	peer_target.free()
	world_target.free()
	target_adapter.free()
	runtime.queue_free()
	for _cleanup_frame in range(4):
		await process_frame
		await physics_frame
	_finish()


func _make_net_manager(role: NetManagerStore.NetRole) -> NetManagerStore:
	var net_manager := NetManagerStore.new()
	net_manager.net_role = role
	net_manager.connection_state = NetManagerStore.ConnectionState.IN_GAME
	return net_manager


func _make_coordinator(
	runtime: EnemyGameplayGatewayTestRuntime,
	player_coordinator: MpPlayerCoordinator,
	net_manager: NetManagerStore
) -> MpProjectileCoordinator:
	var coordinator := COORDINATOR_SCENE.instantiate() as MpProjectileCoordinator
	coordinator.bind_runtime(runtime)
	coordinator.bind_network_facade_dependencies(
		net_manager,
		player_coordinator,
		func() -> float: return HOST_TIME,
		func(_host_timestamp: float) -> float: return 0.0,
		func(_peer_id: int) -> bool: return false
	)
	return coordinator


func _spawn_mage(
	service: MageServiceScript,
	source: DamageSourceSnapshot,
	target: Node2D
) -> int:
	return service.spawn_authoritative(
		SPAWN_POSITION,
		DIRECTION,
		DAMAGE,
		MAGE_SPEED,
		LIFETIME,
		MageServiceScript.DEFAULT_RADIUS,
		target,
		MageServiceScript.DEFAULT_HOMING_TURN_RATE,
		source,
		MageServiceScript.Profile.NORMAL
	)


func _spawn_rpg(
	service: RPGServiceScript,
	source: DamageSourceSnapshot
) -> int:
	return service.spawn_authoritative(
		0,
		SPAWN_POSITION,
		DIRECTION,
		DAMAGE,
		RPG_SPEED,
		LIFETIME,
		RPGServiceScript.DEFAULT_EXPLOSION_RADIUS,
		source
	)


func _register_mage(
	coordinator: MpProjectileCoordinator,
	service: MageServiceScript,
	handle: int,
	source: DamageSourceSnapshot,
	target_peer_id: int,
	target_world_net_id: int
) -> int:
	return coordinator.register_local_capoo_mage_fireball_data(
		service,
		handle,
		MAGE_TYPE,
		OWNER_PEER_ID,
		SPAWN_POSITION,
		DIRECTION,
		DAMAGE,
		MAGE_SPEED,
		LIFETIME,
		target_peer_id,
		target_world_net_id,
		source
	)


func _make_source(
	projectile_type: StringName,
	instigator_id: int
) -> DamageSourceSnapshot:
	return DamageSourceSnapshot.create(
		CombatRelationService.HOSTILE_WAVE,
		0,
		instigator_id,
		0,
		projectile_type
	)


func _is_current_mage_payload(
	payload: Array,
	service: MageServiceScript,
	handle: int,
	target_peer_id: int,
	target_world_net_id: int
) -> bool:
	var source := service.get_damage_source_snapshot(handle)
	return (
		payload.size() == 17
		and source != null
		and StringName(payload[1]) == MAGE_TYPE
		and int(payload[2]) == OWNER_PEER_ID
		and (payload[3] as Vector2).is_equal_approx(service.get_position(handle))
		and (payload[4] as Vector2).is_equal_approx(service.get_direction(handle))
		and int(payload[5]) == service.get_damage(handle)
		and is_equal_approx(float(payload[6]), service.get_speed(handle))
		and is_equal_approx(
			float(payload[7]),
			service.get_remaining_lifetime(handle)
		)
		and not bool(payload[8])
		and int(payload[9]) == target_peer_id
		and is_equal_approx(float(payload[10]), HOST_TIME)
		and int(payload[11]) == target_world_net_id
		and int(payload[12]) == source.source_faction_id
		and int(payload[13]) == source.credit_peer_id
		and int(payload[14]) == source.instigator_entity_id
		and int(payload[15]) == int(payload[0])
		and StringName(payload[16]) == source.source_type
	)


func _is_current_rpg_payload(
	payload: Array,
	service: RPGServiceScript,
	handle: int
) -> bool:
	var source := service.get_damage_source_snapshot(handle)
	return (
		payload.size() == 17
		and source != null
		and StringName(payload[1]) == RPG_TYPE
		and int(payload[2]) == OWNER_PEER_ID
		and (payload[3] as Vector2).is_equal_approx(service.get_position(handle))
		and (payload[4] as Vector2).is_equal_approx(service.get_direction(handle))
		and int(payload[5]) == service.get_damage(handle)
		and is_equal_approx(float(payload[6]), service.get_speed(handle))
		and is_equal_approx(
			float(payload[7]),
			service.get_remaining_lifetime(handle)
		)
		and not bool(payload[8])
		and int(payload[9]) == 0
		and is_equal_approx(float(payload[10]), HOST_TIME)
		and int(payload[11]) == 0
		and int(payload[12]) == source.source_faction_id
		and int(payload[13]) == source.credit_peer_id
		and int(payload[14]) == source.instigator_entity_id
		and int(payload[15]) == int(payload[0])
		and StringName(payload[16]) == source.source_type
	)


func _apply_payload(
	coordinator: MpProjectileCoordinator,
	payload: Array
) -> void:
	coordinator.apply_authority_projectile_fired(
		1,
		int(payload[0]),
		String(payload[1]),
		int(payload[2]),
		payload[3] as Vector2,
		payload[4] as Vector2,
		int(payload[5]),
		float(payload[6]),
		float(payload[7]),
		bool(payload[8]),
		int(payload[9]),
		float(payload[10]),
		int(payload[11]),
		int(payload[12]),
		int(payload[13]),
		int(payload[14]),
		int(payload[15]),
		String(payload[16])
	)


func _find_mage_handle(
	service: MageServiceScript,
	projectile_id: int,
	mode: MageServiceScript.Mode
) -> int:
	for stable_index in range(service.get_dense_record_count()):
		var handle := service.get_handle_at_stable_index(stable_index)
		if (
			handle > MageServiceScript.INVALID_HANDLE
			and service.get_projectile_id(handle) == projectile_id
			and service.get_slot_mode(handle) == mode
		):
			return handle
	return MageServiceScript.INVALID_HANDLE


func _find_rpg_handle(
	service: RPGServiceScript,
	projectile_id: int,
	mode: RPGServiceScript.Mode
) -> int:
	for stable_index in range(service.get_dense_record_count()):
		var handle := service.get_handle_at_stable_index(stable_index)
		if (
			handle > RPGServiceScript.INVALID_HANDLE
			and service.get_projectile_id(handle) == projectile_id
			and service.get_slot_mode(handle) == mode
		):
			return handle
	return RPGServiceScript.INVALID_HANDLE


func _count_legacy_nodes(node: Node) -> int:
	var count := 1 if node is CapooMageFireball or node is CapooRPGRocket else 0
	for child in node.get_children():
		count += _count_legacy_nodes(child)
	return count


func _finish() -> void:
	var result := {
		"status": "ok" if failures.is_empty() else "failed",
		"failures": failures.duplicate(),
	}
	print("CAPOO_DATA_LATE_JOIN_SNAPSHOT_JSON %s" % JSON.stringify(result))
	if failures.is_empty():
		print("CAPOO_DATA_LATE_JOIN_SNAPSHOT_SMOKE_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
