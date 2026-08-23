extends SceneTree

const FIXTURE_SCENE := preload(
	"res://dev_tools/fixtures/enemy_gameplay_gateway_test_runtime.tscn"
)
const COORDINATOR_SCENE := preload(
	"res://scene/multiplayer/projectile/mp_projectile_coordinator.tscn"
)
const ServiceScript := preload(
	"res://scene/combat/simulation/capoo_mage_fireball_simulation_service.gd"
)

const PROJECTILE_TYPE := &"capoo_mage_fireball"
const SPAWN_POSITION := Vector2(120.0, 80.0)
const DIRECTION := Vector2(0.6, 0.8)
const DAMAGE := 34
const SPEED := 155.0
const LIFETIME := 6.0
const HOST_TIME := 400.0
const COMPENSATION_AGE := 0.125
const TARGET_PEER_ID := 7
const TARGET_WORLD_NET_ID := 93


class TargetModeAdapter:
	extends MultiplayerModeAdapter

	var target_net_id := 0
	var target: Node2D = null

	func get_network_projectile_world_target(net_id: int) -> Node2D:
		return target if net_id == target_net_id else null


var failures: Array[String] = []
var broadcasts: Array[Array] = []


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
	var service: ServiceScript = (
		combat_services.get_capoo_mage_fireball_simulation_service()
		if combat_services != null
		else null
	)
	_expect(
		combat_services != null and service != null and service.is_bound(),
		"The Mage bridge smoke requires the authored typed simulation service."
	)
	if combat_services == null or service == null:
		runtime.queue_free()
		await process_frame
		_finish()
		return
	combat_services.set_physics_process(false)
	service.set_physics_process(false)

	var peer_target := Player.new()
	runtime.peer_players[TARGET_PEER_ID] = peer_target
	var world_target := Node2D.new()
	var target_adapter := TargetModeAdapter.new()
	target_adapter.target_net_id = TARGET_WORLD_NET_ID
	target_adapter.target = world_target
	target_adapter.bind_runtime(runtime)
	runtime.multiplayer_mode_adapter = target_adapter

	var player_coordinator := MpPlayerCoordinator.new()
	player_coordinator.bind_runtime(runtime)
	var host_net_manager := _make_net_manager(NetManagerStore.NetRole.HOST)
	var client_net_manager := _make_net_manager(NetManagerStore.NetRole.CLIENT)
	var host_coordinator := _make_coordinator(
		runtime,
		player_coordinator,
		host_net_manager,
		0.0
	)
	var client_coordinator := _make_coordinator(
		runtime,
		player_coordinator,
		client_net_manager,
		COMPENSATION_AGE
	)
	host_coordinator.rpc_broadcast_requested.connect(
		func(method_name: StringName, arguments: Array) -> void:
			if method_name == &"net_projectile_fired":
				broadcasts.append(arguments)
	)

	var source := _make_source(731)
	var data_handle := _spawn_data(service, source, peer_target)
	var projectile_id := host_coordinator.register_local_capoo_mage_fireball_data(
		service,
		data_handle,
		PROJECTILE_TYPE,
		0,
		SPAWN_POSITION,
		DIRECTION,
		DAMAGE,
		SPEED,
		LIFETIME,
		TARGET_PEER_ID,
		0,
		source
	)
	var host_record := host_coordinator.get_projectile_record(projectile_id)
	var frozen_source := service.get_damage_source_snapshot(data_handle)
	_expect(
		projectile_id > 0
		and service.get_projectile_id(data_handle) == projectile_id
		and service.get_slot_mode(data_handle) == ServiceScript.Mode.DATA
		and frozen_source != null
		and frozen_source.event_source_id == projectile_id
		and int(host_coordinator.get_state_metrics()[
			"known_capoo_mage_data"
		]) == 1
		and not host_coordinator.has_projectile(projectile_id),
		"Host registration must assign one hostile DATA identity without a Node backend."
	)
	_expect(
		not host_record.is_empty()
		and is_equal_approx(
			float(host_record["expires_at"]),
			HOST_TIME + LIFETIME
				+ MpProjectileCoordinator.PROJECTILE_RECORD_RETENTION_SECONDS
		),
		"The DATA record must retain the original lifetime-based expiry contract."
	)
	_expect(
		broadcasts.size() == 1
		and broadcasts[0].size() == 17
		and int(broadcasts[0][0]) == projectile_id
		and StringName(broadcasts[0][1]) == PROJECTILE_TYPE
		and broadcasts[0][3] == SPAWN_POSITION
		and (broadcasts[0][4] as Vector2).is_equal_approx(DIRECTION)
		and int(broadcasts[0][5]) == DAMAGE
		and is_equal_approx(float(broadcasts[0][6]), SPEED)
		and is_equal_approx(float(broadcasts[0][7]), LIFETIME)
		and not bool(broadcasts[0][8])
		and int(broadcasts[0][9]) == TARGET_PEER_ID
		and is_equal_approx(float(broadcasts[0][10]), HOST_TIME)
		and int(broadcasts[0][11]) == 0
		and int(broadcasts[0][12]) == frozen_source.source_faction_id
		and int(broadcasts[0][13]) == frozen_source.credit_peer_id
		and int(broadcasts[0][14]) == frozen_source.instigator_entity_id
		and int(broadcasts[0][15]) == projectile_id
		and StringName(broadcasts[0][16]) == frozen_source.source_type,
		"Mage DATA must append its frozen source to the current 17-field projectile RPC payload."
	)

	_apply_payload(client_coordinator, broadcasts[0])
	var replica_handle := _find_handle(
		service,
		projectile_id,
		ServiceScript.Mode.REPLICA
	)
	var expected_position := (
		SPAWN_POSITION + DIRECTION.normalized() * SPEED * COMPENSATION_AGE
	)
	_expect(
		replica_handle > ServiceScript.INVALID_HANDLE
		and client_coordinator.has_capoo_mage_replica(projectile_id)
		and service.get_position(replica_handle).is_equal_approx(expected_position)
		and is_equal_approx(
			service.get_remaining_lifetime(replica_handle),
			LIFETIME - COMPENSATION_AGE
		)
		and is_equal_approx(
			service.get_visual_age(replica_handle),
			COMPENSATION_AGE
		)
		and service.get_target_instance_id(replica_handle)
			== peer_target.get_instance_id()
		and _count_legacy_mage_nodes(runtime) == 0,
		"Client authority fire must resolve target_peer_id into one compensated REPLICA row and no legacy Node."
	)
	_apply_payload(client_coordinator, broadcasts[0])
	_expect(
		_find_handle(service, projectile_id, ServiceScript.Mode.REPLICA)
			== replica_handle
		and int(client_coordinator.get_state_metrics()[
			"known_capoo_mage_replicas"
		]) == 1,
		"A duplicate Mage projectile ID must not create another REPLICA row."
	)
	host_coordinator.notify_capoo_mage_fireball_data_finished(
		projectile_id,
		service,
		replica_handle
	)
	client_coordinator.notify_capoo_mage_fireball_data_finished(
		projectile_id,
		service,
		data_handle
	)
	_expect(
		host_coordinator.has_capoo_mage_data(projectile_id)
		and client_coordinator.has_capoo_mage_replica(projectile_id),
		"Finish must reject a mismatched service-handle ownership pair."
	)
	host_coordinator.notify_capoo_mage_fireball_data_finished(
		projectile_id,
		service,
		data_handle
	)
	client_coordinator.notify_capoo_mage_fireball_data_finished(
		projectile_id,
		service,
		replica_handle
	)
	_expect(
		not host_coordinator.has_capoo_mage_data(projectile_id)
		and not client_coordinator.has_capoo_mage_replica(projectile_id)
		and service.is_handle_live(data_handle)
		and service.is_handle_live(replica_handle),
		"Exact finish must erase only its typed map; the simulation still owns release."
	)
	service.release(data_handle)
	service.release(replica_handle)

	var peer_source := _make_source(732)
	var peer_data_handle := _spawn_data(service, peer_source, world_target)
	var peer_id := host_coordinator.register_local_capoo_mage_fireball_data(
		service,
		peer_data_handle,
		PROJECTILE_TYPE,
		9,
		SPAWN_POSITION,
		DIRECTION,
		DAMAGE,
		SPEED,
		LIFETIME,
		0,
		TARGET_WORLD_NET_ID,
		peer_source
	)
	_apply_payload(client_coordinator, broadcasts[1])
	var peer_replica_handle := _find_handle(
		service,
		peer_id,
		ServiceScript.Mode.REPLICA
	)
	_expect(
		int(broadcasts[1][9]) == 0
		and int(broadcasts[1][11]) == TARGET_WORLD_NET_ID
		and service.get_target_instance_id(peer_replica_handle)
			== world_target.get_instance_id(),
		"The existing world target ID field must resolve through the mode adapter."
	)
	host_coordinator.clear_peer(9)
	client_coordinator.clear_peer(9)
	_expect(
		not service.is_handle_live(peer_data_handle)
		and not service.is_handle_live(peer_replica_handle)
		and not host_coordinator.has_projectile_record(peer_id)
		and not client_coordinator.has_projectile_record(peer_id),
		"Peer clear must release Mage DATA/REPLICA handles, maps, and records."
	)

	var relation_service := runtime.get_combat_relation_service()
	const NON_DEFAULT_SOURCE_FACTION := 3
	_expect(
		relation_service.set_hostile(
			NON_DEFAULT_SOURCE_FACTION,
			CombatRelationService.HOSTILE_WAVE
		),
		"The Mage faction fixture must configure its non-default directed relation."
	)
	var converted_source := _make_source(735, NON_DEFAULT_SOURCE_FACTION)
	var converted_handle := _spawn_data(service, converted_source, null)
	var converted_id := host_coordinator.register_local_capoo_mage_fireball_data(
		service, converted_handle, PROJECTILE_TYPE, 0, SPAWN_POSITION,
		DIRECTION, DAMAGE, SPEED, LIFETIME, 0, 0, converted_source
	)
	converted_source.source_faction_id = CombatRelationService.HOSTILE_WAVE
	var converted_service_source := service.get_damage_source_snapshot(
		converted_handle
	)
	var converted_record_source := (
		host_coordinator.get_projectile_damage_source_snapshot(converted_id)
	)
	_expect(
		converted_id > 0
		and converted_service_source != null
		and converted_record_source != null
		and converted_service_source.source_faction_id
			== NON_DEFAULT_SOURCE_FACTION
		and converted_record_source.source_faction_id
			== NON_DEFAULT_SOURCE_FACTION
		and converted_service_source.event_source_id == converted_id
		and converted_record_source.event_source_id == converted_id,
		"Host Mage registration must preserve a valid non-default frozen faction in both backends."
	)
	_expect(
		relation_service.is_hostile(
			converted_service_source.source_faction_id,
			CombatRelationService.HOSTILE_WAVE
		)
		and not relation_service.is_hostile(
			converted_service_source.source_faction_id,
			CombatRelationService.PLAYER_ALLIED
		),
		"Mage target relations must still be resolved from the frozen launch faction."
	)
	host_coordinator.notify_capoo_mage_fireball_data_finished(
		converted_id,
		service,
		converted_handle
	)
	service.release(converted_handle)

	var prune_source := _make_source(733)
	var prune_handle := _spawn_data(service, prune_source, null)
	var prune_id := host_coordinator.register_local_capoo_mage_fireball_data(
		service, prune_handle, PROJECTILE_TYPE, 0, SPAWN_POSITION, DIRECTION,
		DAMAGE, SPEED, LIFETIME, 0, 0, prune_source
	)
	service.release(prune_handle)
	host_coordinator.prune_records(HOST_TIME)
	_expect(
		prune_id > 0
		and not host_coordinator.has_capoo_mage_data(prune_id)
		and int(host_coordinator.get_state_metrics()[
			"known_capoo_mage_data"
		]) == 0,
		"Pruning must remove a stale Mage typed handle map without disturbing its retained record."
	)

	var reset_source := _make_source(734)
	var reset_data_handle := _spawn_data(service, reset_source, null)
	var reset_id := host_coordinator.register_local_capoo_mage_fireball_data(
		service, reset_data_handle, PROJECTILE_TYPE, 0, SPAWN_POSITION,
		DIRECTION, DAMAGE, SPEED, LIFETIME, 0, 0, reset_source
	)
	_apply_payload(client_coordinator, broadcasts.back())
	var reset_replica_handle := _find_handle(
		service,
		reset_id,
		ServiceScript.Mode.REPLICA
	)
	host_coordinator.reset_session_state()
	client_coordinator.reset_session_state()
	_expect(
		reset_id > 0
		and not service.is_handle_live(reset_data_handle)
		and not service.is_handle_live(reset_replica_handle)
		and int(host_coordinator.get_state_metrics()[
			"known_capoo_mage_data"
		]) == 0
		and int(client_coordinator.get_state_metrics()[
			"known_capoo_mage_replicas"
		]) == 0
		and _count_legacy_mage_nodes(runtime) == 0,
		"Session reset must release every Mage typed backend and keep Node count at zero."
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
	net_manager: NetManagerStore,
	compensation_age: float
) -> MpProjectileCoordinator:
	var coordinator := COORDINATOR_SCENE.instantiate() as MpProjectileCoordinator
	coordinator.bind_runtime(runtime)
	coordinator.bind_network_facade_dependencies(
		net_manager,
		player_coordinator,
		func() -> float: return HOST_TIME,
		func(_host_timestamp: float) -> float: return compensation_age,
		func(_peer_id: int) -> bool: return false
	)
	return coordinator


func _spawn_data(
	service: ServiceScript,
	source: DamageSourceSnapshot,
	target: Node2D
) -> int:
	return service.spawn_authoritative(
		SPAWN_POSITION,
		DIRECTION,
		DAMAGE,
		SPEED,
		LIFETIME,
		ServiceScript.DEFAULT_RADIUS,
		target,
		ServiceScript.DEFAULT_HOMING_TURN_RATE,
		source,
		ServiceScript.Profile.NORMAL
	)


func _make_source(
	instigator_id: int,
	source_faction_id: int = CombatRelationService.HOSTILE_WAVE
) -> DamageSourceSnapshot:
	return DamageSourceSnapshot.create(
		source_faction_id,
		0,
		instigator_id,
		0,
		PROJECTILE_TYPE
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


func _find_handle(
	service: ServiceScript,
	projectile_id: int,
	mode: ServiceScript.Mode
) -> int:
	for stable_index in range(service.get_dense_record_count()):
		var handle := service.get_handle_at_stable_index(stable_index)
		if (
			handle > ServiceScript.INVALID_HANDLE
			and service.get_projectile_id(handle) == projectile_id
			and service.get_slot_mode(handle) == mode
		):
			return handle
	return ServiceScript.INVALID_HANDLE


func _count_legacy_mage_nodes(node: Node) -> int:
	var count := 1 if node is CapooMageFireball else 0
	for child in node.get_children():
		count += _count_legacy_mage_nodes(child)
	return count


func _finish() -> void:
	var result := {
		"status": "ok" if failures.is_empty() else "failed",
		"failures": failures.duplicate(),
	}
	print("CAPOO_MAGE_FIREBALL_DATA_MULTIPLAYER_BRIDGE_JSON %s" % JSON.stringify(result))
	if failures.is_empty():
		print("CAPOO_MAGE_FIREBALL_DATA_MULTIPLAYER_BRIDGE_SMOKE_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
