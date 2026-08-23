extends SceneTree

const FIXTURE_SCENE := preload(
	"res://dev_tools/fixtures/enemy_gameplay_gateway_test_runtime.tscn"
)
const COORDINATOR_SCENE := preload(
	"res://scene/multiplayer/projectile/mp_projectile_coordinator.tscn"
)
const CapooRPGRocketSimulationServiceScript := preload(
	"res://scene/combat/simulation/capoo_rpg_rocket_simulation_service.gd"
)
const CapooDataProjectileSnapshotCodecScript := preload(
	"res://scene/multiplayer/projectile/capoo_data_projectile_snapshot_codec.gd"
)

const PROJECTILE_TYPE := &"capoo_rpg_rocket"
const SPAWN_POSITION := Vector2(120.0, 80.0)
const DIRECTION := Vector2(0.6, 0.8)
const DAMAGE := 34
const SPEED := 180.0
const LIFETIME := 6.0
const EXPLOSION_RADIUS := 48.0
const HOST_TIME := 400.0
const COMPENSATION_AGE := 0.125

var failures: Array[String] = []
var broadcasts: Array[Array] = []
var peer_messages: Array[Dictionary] = []


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
	var simulation_coordinator := runtime.get_enemy_simulation_coordinator()
	var combat_services := runtime.get_enemy_combat_services()
	var service: CapooRPGRocketSimulationServiceScript = (
		combat_services.get_capoo_rpg_rocket_simulation_service()
		if combat_services != null
		else null
	)
	_expect(
		simulation_coordinator != null
		and combat_services != null
		and service != null,
		"The RPG bridge smoke must have an authored runtime and typed service."
	)
	if simulation_coordinator == null or combat_services == null or service == null:
		runtime.queue_free()
		await process_frame
		_finish()
		return
	_expect(
		service.is_bound() and service.get_reserved_capacity() >= 8,
		"The authored RPG simulation service must be bound and reserved."
	)

	var player_coordinator := MpPlayerCoordinator.new()
	player_coordinator.bind_runtime(runtime)
	var host_net_manager := NetManagerStore.new()
	host_net_manager.net_role = NetManagerStore.NetRole.HOST
	host_net_manager.connection_state = NetManagerStore.ConnectionState.IN_GAME
	var host_coordinator := COORDINATOR_SCENE.instantiate() as MpProjectileCoordinator
	host_coordinator.bind_runtime(runtime)
	host_coordinator.bind_network_facade_dependencies(
		host_net_manager,
		player_coordinator,
		func() -> float: return HOST_TIME,
		func(_host_timestamp: float) -> float: return 0.0,
		func(_peer_id: int) -> bool: return false
	)
	host_coordinator.rpc_broadcast_requested.connect(
		func(method_name: StringName, arguments: Array) -> void:
			if method_name == &"net_projectile_fired":
				broadcasts.append(arguments)
	)
	host_coordinator.rpc_to_peer_requested.connect(
		func(peer_id: int, method_name: StringName, arguments: Array) -> void:
			peer_messages.append({
				"peer_id": peer_id,
				"method_name": method_name,
				"arguments": arguments,
			})
	)

	var launch_source := DamageSourceSnapshot.create(
		CombatRelationService.HOSTILE_WAVE,
		0,
		731,
		0,
		PROJECTILE_TYPE
	)
	var host_handle := _spawn_pending(service, launch_source)
	var projectile_id := host_coordinator.register_local_capoo_rpg_data(
		service,
		host_handle,
		PROJECTILE_TYPE,
		0,
		SPAWN_POSITION,
		DIRECTION,
		DAMAGE,
		SPEED,
		LIFETIME,
		launch_source
	)
	var service_source := service.get_damage_source_snapshot(host_handle)
	var record_source := host_coordinator.get_projectile_damage_source_snapshot(
		projectile_id
	)
	var record := host_coordinator.get_projectile_record(projectile_id)
	var host_metrics := host_coordinator.get_state_metrics()
	_expect(
		projectile_id > 0
		and MpProjectileCoordinator.is_projectile_id_valid_for_host_owner(
			projectile_id,
			MpProjectileCoordinator.PROJECTILE_ID_FALLBACK_OWNER_PEER_ID
		)
		and service.get_projectile_id(host_handle) == projectile_id
		and service.get_slot_mode(host_handle)
			== CapooRPGRocketSimulationServiceScript.Mode.DATA
		and service.is_handle_live(host_handle),
		"Host registration must allocate the original Host-origin ID and assign it to the live DATA row."
	)
	_expect(
		service_source != null
		and record_source != null
		and service_source.source_faction_id
			== CombatRelationService.HOSTILE_WAVE
		and record_source.source_faction_id
			== CombatRelationService.HOSTILE_WAVE
		and service_source.instigator_entity_id == 731
		and record_source.instigator_entity_id == 731
		and service_source.event_source_id == projectile_id
		and record_source.event_source_id == projectile_id
		and record_source.source_type == PROJECTILE_TYPE,
		"Identity assignment and the projectile record must freeze the same hostile launch snapshot."
	)
	_expect(
		not record.is_empty()
		and int(record["damage"]) == DAMAGE
		and StringName(record["projectile_type"]) == PROJECTILE_TYPE
		and int(host_metrics["known_projectiles"]) == 0
		and int(host_metrics["known_data_projectiles"]) == 0
		and int(host_metrics["known_capoo_rpg_data"]) == 1
		and int(host_metrics["capoo_rpg_late_join_records"]) == 1
		and int(host_metrics["known_capoo_rpg_replicas"]) == 0
		and int(host_metrics["projectile_records"]) == 1,
		"RPG DATA registration must remember one record in its dedicated typed map without a legacy Node or generic backend."
	)
	_expect(
		broadcasts.size() == 1
		and broadcasts[0].size() == 17
		and int(broadcasts[0][0]) == projectile_id
		and StringName(broadcasts[0][1]) == PROJECTILE_TYPE
		and int(broadcasts[0][2]) == 0
		and broadcasts[0][3] == SPAWN_POSITION
		and broadcasts[0][4] == DIRECTION
		and int(broadcasts[0][5]) == DAMAGE
		and is_equal_approx(float(broadcasts[0][6]), SPEED)
		and is_equal_approx(float(broadcasts[0][7]), LIFETIME)
		and not bool(broadcasts[0][8])
		and int(broadcasts[0][9]) == 0
		and is_equal_approx(float(broadcasts[0][10]), HOST_TIME)
		and int(broadcasts[0][11]) == 0
		and int(broadcasts[0][12]) == CombatRelationService.HOSTILE_WAVE
		and int(broadcasts[0][13]) == 0
		and int(broadcasts[0][14]) == 731
		and int(broadcasts[0][15]) == projectile_id
		and StringName(broadcasts[0][16]) == PROJECTILE_TYPE,
		"Host registration must append the exact protocol-94 frozen damage source."
	)
	var sent_late_join_snapshot := (
		host_coordinator.send_active_data_visual_snapshot_to_peer(9)
	)
	var late_join_payload: Array = []
	for message in peer_messages:
		if (
			int(message["peer_id"]) == 9
			and StringName(message["method_name"])
				== &"net_capoo_data_projectile_snapshot_chunk"
		):
			late_join_payload = message["arguments"] as Array
			break
	var late_join_record: Dictionary = {}
	if late_join_payload.size() == 5:
		var decoded := CapooDataProjectileSnapshotCodecScript.decode_chunk(
			late_join_payload[4] as PackedByteArray
		)
		if bool(decoded.get("valid", false)):
			var decoded_records := decoded.get("records", []) as Array
			if decoded_records.size() == 1:
				late_join_record = decoded_records[0] as Dictionary
	_expect(
		sent_late_join_snapshot
		and late_join_payload.size() == 5
		and int(late_join_payload[1]) == 0
		and int(late_join_payload[2]) == 1
		and float(late_join_payload[3]) > float(broadcasts[0][10])
		and int(late_join_record.get("projectile_id", 0)) == projectile_id
		and int(late_join_record.get("family", 0))
			== CapooDataProjectileSnapshotCodecScript.FAMILY_CAPOO_RPG
		and int(late_join_record.get("source_faction_id", -1))
			== CombatRelationService.HOSTILE_WAVE
		and int(late_join_record.get("source_credit_peer_id", -1)) == 0
		and int(late_join_record.get("source_instigator_entity_id", -1)) == 731
		and int(late_join_record.get("source_event_id", 0)) == projectile_id
		and StringName(late_join_record.get("source_type", &""))
			== PROJECTILE_TYPE,
		"Late-join repair must include the live RPG DATA row and its frozen source in the reliable unified snapshot."
	)

	var wrong_type_handle := _spawn_pending(service, launch_source)
	var wrong_type_result := host_coordinator.register_local_capoo_rpg_data(
		service,
		wrong_type_handle,
		&"capoo_mage_fireball",
		0,
		SPAWN_POSITION,
		DIRECTION,
		DAMAGE,
		SPEED,
		LIFETIME,
		launch_source
	)
	_expect(
		wrong_type_result == 0
		and service.is_handle_live(wrong_type_handle)
		and service.get_projectile_id(wrong_type_handle) == 0
		and broadcasts.size() == 1,
		"Invalid type rejection must leave the caller-owned handle live and emit no protocol event."
	)

	var client_net_manager := NetManagerStore.new()
	client_net_manager.net_role = NetManagerStore.NetRole.CLIENT
	client_net_manager.connection_state = NetManagerStore.ConnectionState.IN_GAME
	var client_coordinator := COORDINATOR_SCENE.instantiate() as MpProjectileCoordinator
	client_coordinator.bind_runtime(runtime)
	client_coordinator.bind_network_facade_dependencies(
		client_net_manager,
		player_coordinator,
		func() -> float: return HOST_TIME,
		func(_host_timestamp: float) -> float: return COMPENSATION_AGE,
		func(_peer_id: int) -> bool: return false
	)
	var client_handle := _spawn_pending(service, launch_source)
	var client_result := client_coordinator.register_local_capoo_rpg_data(
		service,
		client_handle,
		PROJECTILE_TYPE,
		0,
		SPAWN_POSITION,
		DIRECTION,
		DAMAGE,
		SPEED,
		LIFETIME,
		launch_source
	)
	_expect(
		client_result == 0
		and service.is_handle_live(client_handle)
		and service.get_projectile_id(client_handle) == 0
		and int(client_coordinator.get_state_metrics()["projectile_records"]) == 0,
		"Client registration must reject without assigning identity or creating a record."
	)

	var payload := broadcasts[0]
	client_coordinator.apply_authority_projectile_fired(
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
	var replica_handle := _find_handle(
		service,
		projectile_id,
		CapooRPGRocketSimulationServiceScript.Mode.REPLICA
	)
	var expected_position := (
		SPAWN_POSITION + DIRECTION.normalized() * SPEED * COMPENSATION_AGE
	)
	_expect(
		replica_handle > CapooRPGRocketSimulationServiceScript.INVALID_HANDLE
		and client_coordinator.has_capoo_rpg_replica(projectile_id)
		and not client_coordinator.has_projectile(projectile_id)
		and service.get_slot_mode(replica_handle)
			== CapooRPGRocketSimulationServiceScript.Mode.REPLICA
		and service.get_position(replica_handle).is_equal_approx(expected_position)
		and is_equal_approx(
			service.get_remaining_lifetime(replica_handle),
			LIFETIME - COMPENSATION_AGE
		)
		and is_equal_approx(
			service.get_visual_age(replica_handle),
			COMPENSATION_AGE
		)
		and _count_legacy_rpg_nodes(runtime) == 0,
		"Client authority fire must create one compensated REPLICA row and no legacy RPG Node."
	)
	client_coordinator.apply_authority_projectile_fired(
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
	_expect(
		_find_handle(
			service,
			projectile_id,
			CapooRPGRocketSimulationServiceScript.Mode.REPLICA
		) == replica_handle
		and int(client_coordinator.get_state_metrics()[
			"known_capoo_rpg_replicas"
		]) == 1
		and _count_legacy_rpg_nodes(runtime) == 0,
		"A duplicate authority payload must not create a second RPG backend or Node."
	)

	host_coordinator.notify_capoo_rpg_data_finished(
		projectile_id,
		service,
		replica_handle
	)
	client_coordinator.notify_capoo_rpg_data_finished(
		projectile_id,
		service,
		host_handle
	)
	_expect(
		host_coordinator.has_capoo_rpg_data(projectile_id)
		and client_coordinator.has_capoo_rpg_replica(projectile_id),
		"Finish notification must ignore non-matching service/handle ownership."
	)
	host_coordinator.notify_capoo_rpg_data_finished(
		projectile_id,
		service,
		host_handle
	)
	client_coordinator.notify_capoo_rpg_data_finished(
		projectile_id,
		service,
		replica_handle
	)
	_expect(
		not host_coordinator.has_capoo_rpg_data(projectile_id)
		and not client_coordinator.has_capoo_rpg_replica(projectile_id)
		and service.is_handle_live(host_handle)
		and service.is_handle_live(replica_handle),
		"Matching finish must erase only its exact backend map without owning service release."
	)
	service.release(host_handle)
	service.release(replica_handle)
	service.release(wrong_type_handle)
	service.release(client_handle)
	service.clear_completion_records()
	combat_services.set_physics_process(false)
	var visual_only_id := MpProjectileCoordinator.encode_projectile_id(
		MpProjectileCoordinator.PROJECTILE_ID_FALLBACK_OWNER_PEER_ID,
		MpProjectileCoordinator.PROJECTILE_ID_HOST_ORIGIN_BIT | 9001
	)
	var visual_only_handle := service.spawn_replica(
		visual_only_id,
		Vector2(1000.0, 1000.0),
		Vector2.RIGHT,
		0.0,
		0.01,
		EXPLOSION_RADIUS,
		0.5
	)
	service.set_physics_process(false)
	await physics_frame
	service.advance(0.02)
	_expect(
		visual_only_handle
			> CapooRPGRocketSimulationServiceScript.INVALID_HANDLE
		and not service.is_handle_live(visual_only_handle)
		and service.get_completion_count() == 1
		and service.get_completion_mode(0)
			== CapooRPGRocketSimulationServiceScript.Mode.REPLICA
		and service.get_completion_damage(0) == 0,
		"REPLICA completion must retain visual mode while carrying zero authoritative damage."
	)
	service.clear_completion_records()

	var peer_source := DamageSourceSnapshot.create(
		CombatRelationService.HOSTILE_WAVE,
		0,
		732,
		0,
		PROJECTILE_TYPE
	)
	var peer_data_handle := _spawn_pending(service, peer_source)
	var peer_projectile_id := host_coordinator.register_local_capoo_rpg_data(
		service,
		peer_data_handle,
		PROJECTILE_TYPE,
		7,
		SPAWN_POSITION,
		DIRECTION,
		DAMAGE,
		SPEED,
		LIFETIME,
		peer_source
	)
	var peer_payload := broadcasts[1]
	client_coordinator.apply_authority_projectile_fired(
		1,
		int(peer_payload[0]),
		String(peer_payload[1]),
		int(peer_payload[2]),
		peer_payload[3] as Vector2,
		peer_payload[4] as Vector2,
		int(peer_payload[5]),
		float(peer_payload[6]),
		float(peer_payload[7]),
		bool(peer_payload[8]),
		int(peer_payload[9]),
		float(peer_payload[10]),
		int(peer_payload[11]),
		int(peer_payload[12]),
		int(peer_payload[13]),
		int(peer_payload[14]),
		int(peer_payload[15]),
		String(peer_payload[16])
	)
	var peer_replica_handle := _find_handle(
		service,
		peer_projectile_id,
		CapooRPGRocketSimulationServiceScript.Mode.REPLICA
	)
	host_coordinator.clear_peer(7)
	client_coordinator.clear_peer(7)
	_expect(
		peer_projectile_id > 0
		and not service.is_handle_live(peer_data_handle)
		and not service.is_handle_live(peer_replica_handle)
		and not host_coordinator.has_capoo_rpg_data(peer_projectile_id)
		and not client_coordinator.has_capoo_rpg_replica(peer_projectile_id)
		and not host_coordinator.has_projectile_record(peer_projectile_id)
		and not client_coordinator.has_projectile_record(peer_projectile_id),
		"Peer clear must release that peer's DATA/REPLICA handles, maps, and records."
	)

	var teardown_source := DamageSourceSnapshot.create(
		CombatRelationService.HOSTILE_WAVE,
		0,
		733,
		0,
		PROJECTILE_TYPE
	)
	var teardown_data_handle := _spawn_pending(service, teardown_source)
	var teardown_projectile_id := host_coordinator.register_local_capoo_rpg_data(
		service,
		teardown_data_handle,
		PROJECTILE_TYPE,
		0,
		SPAWN_POSITION,
		DIRECTION,
		DAMAGE,
		SPEED,
		LIFETIME,
		teardown_source
	)
	var teardown_payload := broadcasts[2]
	client_coordinator.apply_authority_projectile_fired(
		1,
		int(teardown_payload[0]),
		String(teardown_payload[1]),
		int(teardown_payload[2]),
		teardown_payload[3] as Vector2,
		teardown_payload[4] as Vector2,
		int(teardown_payload[5]),
		float(teardown_payload[6]),
		float(teardown_payload[7]),
		bool(teardown_payload[8]),
		int(teardown_payload[9]),
		float(teardown_payload[10]),
		int(teardown_payload[11]),
		int(teardown_payload[12]),
		int(teardown_payload[13]),
		int(teardown_payload[14]),
		int(teardown_payload[15]),
		String(teardown_payload[16])
	)
	var teardown_replica_handle := _find_handle(
		service,
		teardown_projectile_id,
		CapooRPGRocketSimulationServiceScript.Mode.REPLICA
	)
	_expect(
		teardown_projectile_id > 0
		and teardown_replica_handle
			> CapooRPGRocketSimulationServiceScript.INVALID_HANDLE,
		"Session teardown coverage must begin with live DATA and REPLICA maps."
	)
	host_coordinator.reset_session_state()
	client_coordinator.reset_session_state()
	_expect(
		not service.is_handle_live(teardown_data_handle)
		and not service.is_handle_live(teardown_replica_handle)
		and int(host_coordinator.get_state_metrics()["known_capoo_rpg_data"]) == 0
		and int(host_coordinator.get_state_metrics()[
			"capoo_rpg_late_join_records"
		]) == 0
		and int(client_coordinator.get_state_metrics()[
			"known_capoo_rpg_replicas"
		]) == 0
		and int(host_coordinator.get_state_metrics()["projectile_records"]) == 0,
		"Session teardown must release RPG DATA/REPLICA handles, maps, and records."
	)
	service.teardown()
	host_coordinator.unbind_runtime(runtime)
	client_coordinator.unbind_runtime(runtime)
	player_coordinator.unbind_runtime(runtime)
	host_coordinator.free()
	client_coordinator.free()
	player_coordinator.free()
	host_net_manager.free()
	client_net_manager.free()
	runtime.queue_free()
	for _cleanup_frame in range(4):
		await process_frame
		await physics_frame
	_finish()


func _spawn_pending(
	service: CapooRPGRocketSimulationServiceScript,
	source_snapshot: DamageSourceSnapshot
) -> int:
	return service.spawn_authoritative(
		0,
		SPAWN_POSITION,
		DIRECTION,
		DAMAGE,
		SPEED,
		LIFETIME,
		EXPLOSION_RADIUS,
		source_snapshot
	)


func _find_handle(
	service: CapooRPGRocketSimulationServiceScript,
	projectile_id: int,
	mode: CapooRPGRocketSimulationServiceScript.Mode
) -> int:
	for stable_index in range(service.get_dense_record_count()):
		var handle := service.get_handle_at_stable_index(stable_index)
		if (
			handle > CapooRPGRocketSimulationServiceScript.INVALID_HANDLE
			and service.get_projectile_id(handle) == projectile_id
			and service.get_slot_mode(handle) == mode
		):
			return handle
	return CapooRPGRocketSimulationServiceScript.INVALID_HANDLE


func _count_legacy_rpg_nodes(node: Node) -> int:
	var count := 1 if node is CapooRPGRocket else 0
	for child in node.get_children():
		count += _count_legacy_rpg_nodes(child)
	return count


func _finish() -> void:
	var result := {
		"status": "ok" if failures.is_empty() else "failed",
		"failures": failures.duplicate(),
	}
	print("CAPOO_RPG_DATA_MULTIPLAYER_BRIDGE_JSON %s" % JSON.stringify(result))
	if failures.is_empty():
		print("CAPOO_RPG_DATA_MULTIPLAYER_BRIDGE_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
