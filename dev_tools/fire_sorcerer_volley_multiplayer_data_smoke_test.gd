extends SceneTree

const FIXTURE_SCENE := preload(
	"res://dev_tools/fixtures/enemy_gameplay_gateway_test_runtime.tscn"
)
const COORDINATOR_SCENE := preload(
	"res://scene/multiplayer/projectile/mp_projectile_coordinator.tscn"
)
const PROJECTILE_TYPE := &"fire_sorcerer_fireball_volley"
const ELITE_PROJECTILE_TYPE := &"fire_sorcerer_elite_fireball_volley"
const SOURCE_TYPES: Array[StringName] = [
	&"fire_sorcerer_fireball_a",
	&"fire_sorcerer_fireball_b",
	&"fire_sorcerer_fireball_c",
]
const LOCAL_OFFSETS: Array[Vector2] = [
	Vector2(24.0, 1.0),
	Vector2(15.0, -5.0),
	Vector2(23.0, 13.0),
]
const SPAWN_POSITION := Vector2(120.0, 80.0)
const DIRECTION := Vector2(0.6, 0.8)
const SPEED := 140.0
const LIFETIME := 7.0
const COMPENSATION_AGE := 0.125

var failures: Array[String] = []
var host_broadcasts: Array[Array] = []
var late_join_peer_ids: Array[int] = []
var late_join_methods: Array[StringName] = []
var late_join_arguments: Array[Array] = []


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	var runtime := FIXTURE_SCENE.instantiate() as EnemyGameplayGatewayTestRuntime
	_expect(runtime != null, "The authored combat fixture must instantiate.")
	if runtime == null:
		_finish()
		return
	root.add_child(runtime)
	await process_frame
	var services := runtime.get_enemy_combat_services()
	var service: FireSorcererVolleySimulationService = (
		services.get_fire_sorcerer_volley_simulation_service()
		if services != null
		else null
	)
	_expect(
		service != null and service.is_bound(),
		"The fixture must expose the bound authored fire-volley service."
	)
	if service == null:
		runtime.queue_free()
		await process_frame
		_finish()
		return

	var host_net_manager := NetManagerStore.new()
	host_net_manager.net_role = NetManagerStore.NetRole.HOST
	host_net_manager.connection_state = NetManagerStore.ConnectionState.IN_GAME
	var player_coordinator := MpPlayerCoordinator.new()
	player_coordinator.bind_runtime(runtime)
	var host_coordinator := COORDINATOR_SCENE.instantiate() as MpProjectileCoordinator
	host_coordinator.bind_runtime(runtime)
	host_coordinator.bind_network_facade_dependencies(
		host_net_manager,
		player_coordinator,
		func() -> float: return 400.0,
		func(_host_timestamp: float) -> float: return 0.0,
		func(_peer_id: int) -> bool: return false
	)
	host_coordinator.rpc_broadcast_requested.connect(
		func(method_name: StringName, arguments: Array) -> void:
			if method_name == &"net_projectile_fired":
				host_broadcasts.append(arguments)
	)
	host_coordinator.rpc_to_peer_requested.connect(
		func(peer_id: int, method_name: StringName, arguments: Array) -> void:
			late_join_peer_ids.append(peer_id)
			late_join_methods.append(method_name)
			late_join_arguments.append(arguments)
	)

	var positions := _make_ball_positions(SPAWN_POSITION, DIRECTION)
	var directions := PackedVector2Array([DIRECTION, DIRECTION, DIRECTION])
	var launch_source := DamageSourceSnapshot.create(
		CombatRelationService.HOSTILE_WAVE,
		0,
		731,
		0,
		PROJECTILE_TYPE
	)
	var data_handle := service.register_volley(
		FireSorcererVolleySimulationService.Mode.DATA,
		FireSorcererVolleySimulationService.Profile.NORMAL,
		positions,
		directions,
		SPEED,
		LIFETIME,
		6.0,
		18,
		731,
		0,
		null,
		5.0,
		5,
		launch_source
	)
	var projectile_id := host_coordinator.register_local_fire_sorcerer_volley_data(
		service,
		data_handle,
		PROJECTILE_TYPE,
		0,
		SPAWN_POSITION,
		DIRECTION,
		18,
		SPEED,
		LIFETIME,
		0,
		0,
		launch_source
	)
	var host_metrics := host_coordinator.get_state_metrics()
	var frozen_source := host_coordinator.get_projectile_damage_source_snapshot(
		projectile_id
	)
	_expect(
		projectile_id > 0
		and service.get_projectile_id(data_handle) == projectile_id
		and service.get_slot_mode(data_handle)
			== FireSorcererVolleySimulationService.Mode.DATA
		and host_coordinator.has_fire_sorcerer_volley_data(projectile_id)
		and not host_coordinator.has_projectile(projectile_id)
		and int(host_metrics["known_fire_sorcerer_volley_data"]) == 1
		and int(host_metrics["fire_sorcerer_volley_late_join_records"]) == 1,
		"Host DATA registration must assign the original projectile identity without creating a Node."
	)
	_expect(
		frozen_source != null
		and frozen_source.source_faction_id == CombatRelationService.HOSTILE_WAVE
		and frozen_source.instigator_entity_id == 731
		and frozen_source.event_source_id == projectile_id
		and frozen_source.source_type == PROJECTILE_TYPE,
		"Host DATA registration must freeze hostile launch attribution onto the projectile ID."
	)
	_expect(
		host_broadcasts.size() == 1
		and host_broadcasts[0].size() == 17
		and int(host_broadcasts[0][0]) == projectile_id
		and StringName(host_broadcasts[0][1]) == PROJECTILE_TYPE
		and host_broadcasts[0][3] == SPAWN_POSITION
		and host_broadcasts[0][4] == DIRECTION
		and not bool(host_broadcasts[0][8])
		and int(host_broadcasts[0][12]) == CombatRelationService.HOSTILE_WAVE
		and int(host_broadcasts[0][14]) == 731
		and int(host_broadcasts[0][15]) == projectile_id
		and StringName(host_broadcasts[0][16]) == PROJECTILE_TYPE,
		"Host DATA registration must publish the protocol-94 projectile payload with frozen attribution."
	)
	_expect(
		host_coordinator.try_consume_fire_sorcerer_fireball_contact(
			projectile_id,
			SOURCE_TYPES[0]
		)
		and not host_coordinator.try_consume_fire_sorcerer_fireball_contact(
			projectile_id,
			SOURCE_TYPES[0]
		)
		and host_coordinator.try_consume_fire_sorcerer_fireball_contact(
			projectile_id,
			SOURCE_TYPES[1]
		),
		"The existing per-ball fire contact mask must remain independent and one-shot."
	)

	_expect(
		host_coordinator.send_active_data_visual_snapshot_to_peer(9)
		and late_join_methods.has(&"net_projectile_fired"),
		"A live DATA volley must retain one late-join replay record on the existing RPC."
	)
	var late_join_fire_index := late_join_methods.find(&"net_projectile_fired")
	_expect(
		late_join_fire_index >= 0
		and late_join_peer_ids[late_join_fire_index] == 9
		and late_join_arguments[late_join_fire_index].size() == 17
		and int(late_join_arguments[late_join_fire_index][0]) == projectile_id,
		"Late-join replay must preserve the protocol-94 projectile identity and attribution."
	)

	var client_net_manager := NetManagerStore.new()
	client_net_manager.net_role = NetManagerStore.NetRole.CLIENT
	client_net_manager.connection_state = NetManagerStore.ConnectionState.IN_GAME
	var client_coordinator := COORDINATOR_SCENE.instantiate() as MpProjectileCoordinator
	client_coordinator.bind_runtime(runtime)
	client_coordinator.bind_network_facade_dependencies(
		client_net_manager,
		player_coordinator,
		func() -> float: return 400.125,
		func(_host_timestamp: float) -> float: return COMPENSATION_AGE,
		func(_peer_id: int) -> bool: return false
	)
	var payload := host_broadcasts[0]
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
		FireSorcererVolleySimulationService.Mode.REPLICA
	)
	var client_metrics := client_coordinator.get_state_metrics()
	_expect(
		replica_handle > FireSorcererVolleySimulationService.INVALID_HANDLE
		and client_coordinator.has_fire_sorcerer_volley_replica(projectile_id)
		and not client_coordinator.has_projectile(projectile_id)
		and int(client_metrics["known_fire_sorcerer_volley_replicas"]) == 1
		and _count_legacy_volley_nodes(runtime) == 0,
		"Client fire payloads must register one REPLICA row and instantiate no legacy volley Node."
	)
	_expect(
		is_equal_approx(
			service.get_remaining_lifetime(replica_handle),
			LIFETIME - COMPENSATION_AGE
		),
		"Replica Host-time compensation must leave exactly lifetime minus event age."
	)
	for ball_index in range(FireSorcererVolleySimulationService.BALL_COUNT):
		var expected_position := positions[ball_index] + (
			DIRECTION * SPEED * COMPENSATION_AGE
		)
		_expect(
			service.get_ball_position(replica_handle, ball_index).is_equal_approx(
				expected_position
			),
			"Replica ball %d must preserve its rotated authored offset and Host-time compensation."
			% ball_index
		)
	var elite_projectile_id := MpProjectileCoordinator.encode_projectile_id(
		MpProjectileCoordinator.PROJECTILE_ID_FALLBACK_OWNER_PEER_ID,
		MpProjectileCoordinator.PROJECTILE_ID_HOST_ORIGIN_BIT | 9001
	)
	client_coordinator.apply_authority_projectile_fired(
		1,
		elite_projectile_id,
		String(ELITE_PROJECTILE_TYPE),
		0,
		Vector2(240.0, 160.0),
		Vector2.UP,
		25,
		155.0,
		LIFETIME,
		false,
		0,
		400.0,
		0,
		CombatRelationService.HOSTILE_WAVE,
		0,
		732,
		elite_projectile_id,
		String(ELITE_PROJECTILE_TYPE)
	)
	var elite_replica_handle := _find_handle(
		service,
		elite_projectile_id,
		FireSorcererVolleySimulationService.Mode.REPLICA
	)
	_expect(
		elite_replica_handle > FireSorcererVolleySimulationService.INVALID_HANDLE
		and service.get_slot_profile(elite_replica_handle)
			== FireSorcererVolleySimulationService.Profile.ELITE
		and client_coordinator.has_fire_sorcerer_volley_replica(
			elite_projectile_id
		)
		and int(client_coordinator.get_state_metrics()[
			"known_fire_sorcerer_volley_replicas"
		]) == 2
		and _count_legacy_volley_nodes(runtime) == 0,
		"Elite fire payloads must use the ELITE REPLICA profile without a legacy Node."
	)

	service.release_volley(data_handle)
	service.release_volley(replica_handle)
	service.release_volley(elite_replica_handle)
	service.advance_authoritative(0.0)
	host_coordinator.notify_fire_sorcerer_volley_finished(
		projectile_id,
		service,
		data_handle
	)
	client_coordinator.notify_fire_sorcerer_volley_finished(
		projectile_id,
		service,
		replica_handle
	)
	client_coordinator.notify_fire_sorcerer_volley_finished(
		elite_projectile_id,
		service,
		elite_replica_handle
	)
	host_metrics = host_coordinator.get_state_metrics()
	client_metrics = client_coordinator.get_state_metrics()
	_expect(
		int(host_metrics["known_fire_sorcerer_volley_data"]) == 0
		and int(host_metrics["fire_sorcerer_volley_late_join_records"]) == 0
		and int(client_metrics["known_fire_sorcerer_volley_replicas"]) == 0
		and service.get_active_slot_count() == 0
		and host_coordinator.has_projectile_record(projectile_id)
		and client_coordinator.has_projectile_record(projectile_id),
		"Whole-volley finish must clear typed/live state while retaining the bounded contact ledger."
	)
	host_coordinator.prune_records(999.0)
	client_coordinator.prune_records(999.0)
	_expect(
		not host_coordinator.has_projectile_record(projectile_id)
		and not client_coordinator.has_projectile_record(projectile_id)
		and not client_coordinator.has_projectile_record(elite_projectile_id),
		"Expired fire contact and late-join records must not leak."
	)

	host_coordinator.reset_session_state()
	client_coordinator.reset_session_state()
	var reset_host_metrics := host_coordinator.get_state_metrics()
	var reset_client_metrics := client_coordinator.get_state_metrics()
	_expect(
		int(reset_host_metrics["known_fire_sorcerer_volley_data"]) == 0
		and int(reset_host_metrics["fire_sorcerer_volley_late_join_records"]) == 0
		and int(reset_client_metrics["known_fire_sorcerer_volley_replicas"]) == 0,
		"Session teardown must leave every fire-volley backend ledger empty."
	)
	host_coordinator.unbind_runtime(runtime)
	client_coordinator.unbind_runtime(runtime)
	host_coordinator.free()
	client_coordinator.free()
	player_coordinator.unbind_runtime(runtime)
	player_coordinator.free()
	host_net_manager.free()
	client_net_manager.free()
	runtime.prepare_for_scene_teardown()
	runtime.queue_free()
	await process_frame
	await physics_frame
	_finish()


func _make_ball_positions(
	spawn_position: Vector2,
	direction: Vector2
) -> PackedVector2Array:
	var positions := PackedVector2Array()
	for local_offset in LOCAL_OFFSETS:
		positions.append(
			spawn_position + local_offset.rotated(direction.angle())
		)
	return positions


func _find_handle(
	service: FireSorcererVolleySimulationService,
	projectile_id: int,
	mode: FireSorcererVolleySimulationService.Mode
) -> int:
	for stable_index in range(service.get_dense_record_count()):
		var handle := service.get_handle_at_stable_index(stable_index)
		if (
			handle > FireSorcererVolleySimulationService.INVALID_HANDLE
			and service.get_projectile_id(handle) == projectile_id
			and service.get_slot_mode(handle) == mode
		):
			return handle
	return FireSorcererVolleySimulationService.INVALID_HANDLE


func _count_legacy_volley_nodes(runtime: Node) -> int:
	return runtime.find_children(
		"*",
		"FireSorcererFireballVolley",
		true,
		false
	).size()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	var result := {
		"status": "ok" if failures.is_empty() else "failed",
		"failures": failures.duplicate(),
	}
	print("FIRE_SORCERER_VOLLEY_MULTIPLAYER_DATA_JSON %s" % JSON.stringify(result))
	if failures.is_empty():
		print("FIRE_SORCERER_VOLLEY_MULTIPLAYER_DATA_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)
