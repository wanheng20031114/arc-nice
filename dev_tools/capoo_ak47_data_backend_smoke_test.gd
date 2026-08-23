extends SceneTree

const CAPOO_SCENE := preload("res://scene/enemy/capoo/capoo_ak47.tscn")
const CAPOO_CONFIG := preload("res://resources/config/enemies/capoo_ak47.tres")
const ENEMY_SIMULATION_COORDINATOR_SCENE := preload(
	"res://scene/combat/simulation/enemy_simulation_coordinator.tscn"
)
const RAPID_FIRE_CODEC := preload(
	"res://scene/multiplayer/projectile/enemy_rapid_fire_network_codec.gd"
)


class CapturingGateway:
	extends MultiplayerGameplayGateway

	var next_projectile_id := 7001
	var data_payloads: Array[Dictionary] = []
	var burst_descriptors: Array[PackedByteArray] = []
	var released_reservations := PackedInt64Array()
	var node_registration_count := 0
	var data_finish_count := 0
	var reject_data_registration := false


	func register_local_projectile(
		projectile: Node,
		projectile_type: StringName,
		owner_peer_id: int,
		_spawn_position: Vector2,
		_direction: Vector2,
		_damage: int,
		_speed: float,
		_lifetime: float,
		_pierces_enemies: bool = false,
		_target_peer_id: int = 0,
		_target_enemy_net_id: int = 0,
		_damage_source_snapshot: DamageSourceSnapshot = null
	) -> void:
		node_registration_count += 1
		var bullet := projectile as CapooAK47Bullet
		if bullet != null:
			bullet.setup_multiplayer(
				next_projectile_id,
				owner_peer_id,
				projectile_type
			)
			next_projectile_id += 1


	func reserve_enemy_rapid_fire_projectile_ids(
		count: int
	) -> PackedInt64Array:
		var ids := PackedInt64Array()
		for _shot_index in range(count):
			ids.append(next_projectile_id)
			next_projectile_id += 1
		return ids


	func release_enemy_rapid_fire_projectile_ids(
		projectile_ids: PackedInt64Array
	) -> bool:
		released_reservations.append_array(projectile_ids)
		return true


	func attach_reserved_enemy_rapid_fire_projectile(
		service: RapidFireSimulationService,
		handle: int,
		projectile_id: int,
		projectile_type: StringName,
		owner_peer_id: int,
		damage: int,
		lifetime: float,
		damage_source_snapshot: DamageSourceSnapshot = null
	) -> bool:
		if reject_data_registration:
			return false
		if not service.assign_projectile_identity(handle, projectile_id):
			return false
		data_payloads.append({
			"projectile_id": projectile_id,
			"projectile_type": projectile_type,
			"owner_peer_id": owner_peer_id,
			"damage": damage,
			"lifetime": lifetime,
			"damage_source_snapshot": damage_source_snapshot,
			"per_shot_registration": false,
		})
		return true


	func broadcast_enemy_rapid_fire_burst(
		descriptor: PackedByteArray
	) -> bool:
		burst_descriptors.append(descriptor)
		return true


	func notify_data_projectile_finished(
		_projectile_id: int,
		_service: RapidFireSimulationService,
		_handle: int,
		_completion_reason: int = RapidFireSimulationService.CompletionReason.NONE,
		_completion_position: Vector2 = Vector2.ZERO,
		_completion_direction: Vector2 = Vector2.RIGHT
	) -> void:
		data_finish_count += 1


var failures := PackedStringArray()


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	await _test_singleplayer_data_burst()
	await _test_host_data_identity_and_payload()
	await _test_host_registration_failure_is_terminal()
	await _test_client_boundary()
	_finish()


func _test_singleplayer_data_burst() -> void:
	var fixture := _create_fixture(
		CombatRuntimeBase.RuntimeMode.SINGLEPLAYER,
		"AKDataSingleplayer"
	)
	var gateway := fixture.get_node(
		"MultiplayerGameplayGateway"
	) as CapturingGateway
	var enemy := _spawn_enemy(fixture, gateway)
	var service := _get_rapid_service(fixture)
	_fire_complete_burst(enemy)
	_expect(
		service != null and service.get_active_slot_count() == CAPOO_CONFIG.burst_count,
		"Singleplayer DATA burst must register every authored shot."
	)
	_expect(
		_count_live_bullet_nodes(fixture) == 0,
		"Singleplayer DATA burst must own no CapooAK47Bullet Node."
	)
	_expect(
		gateway.data_payloads.is_empty()
		and gateway.node_registration_count == 0,
		"Singleplayer DATA must keep projectile id zero and emit no network registration."
	)
	var phase_zero_count := 0
	var phase_one_count := 0
	for stable_index in range(service.get_dense_record_count()):
		var handle := service.get_handle_at_stable_index(stable_index)
		_expect(
			service.get_projectile_id(handle) == 0
			and service.get_source_enemy_id(handle)
				== int(enemy.get_instance_id()),
			"Singleplayer DATA identity must use id=0 and a stable source enemy id."
		)
		if service.get_world_check_phase(handle) == 0:
			phase_zero_count += 1
		elif service.get_world_check_phase(handle) == 1:
			phase_one_count += 1
	_expect(
		phase_zero_count == phase_one_count,
		"Node-free singleplayer phases must preserve the legacy alternating distribution."
	)
	_release_all_handles(service)
	await physics_frame
	_expect(
		service.get_active_slot_count() == 0,
		"Singleplayer DATA handles must compact to zero without projectile Nodes."
	)
	await _destroy_fixture(fixture)


func _test_host_data_identity_and_payload() -> void:
	var fixture := _create_fixture(
		CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY,
		"AKDataHost"
	)
	var gateway := fixture.get_node(
		"MultiplayerGameplayGateway"
	) as CapturingGateway
	var enemy := _spawn_enemy(fixture, gateway)
	enemy.set_meta(&"net_id", 91)
	var service := _get_rapid_service(fixture)
	_fire_complete_burst(enemy)
	_expect(
		_count_live_bullet_nodes(fixture) == 0
		and service.get_active_slot_count() == CAPOO_CONFIG.burst_count,
		"Host DATA burst must use handles without authority projectile Nodes."
	)
	_expect(
		gateway.data_payloads.size() == CAPOO_CONFIG.burst_count
		and gateway.burst_descriptors.size() == 1,
		"Host DATA burst must attach every shot and emit one batch descriptor."
	)
	var descriptor := (
		RAPID_FIRE_CODEC.decode_burst(gateway.burst_descriptors[0])
		if gateway.burst_descriptors.size() == 1
		else {}
	)
	_expect(
		bool(descriptor.get("valid", false))
		and int(descriptor.get("count", 0)) == CAPOO_CONFIG.burst_count
		and int(descriptor.get("source_enemy_id", 0)) == 91,
		"Host DATA descriptor must preserve count and source identity."
	)
	for stable_index in range(service.get_dense_record_count()):
		var handle := service.get_handle_at_stable_index(stable_index)
		var payload := gateway.data_payloads[stable_index]
		var projectile_id := int(payload["projectile_id"])
		var source_snapshot := payload.get(
			"damage_source_snapshot"
		) as DamageSourceSnapshot
		_expect(
			not bool(payload["per_shot_registration"])
			and String(payload["projectile_type"]) == "capoo_ak47_bullet"
			and source_snapshot != null
			and source_snapshot.source_faction_id
			== CombatRelationService.HOSTILE_WAVE
			and source_snapshot.instigator_entity_id == 91
			and service.get_projectile_id(handle) == projectile_id
			and service.get_world_check_phase(handle) == projectile_id % 2
			and service.get_source_enemy_id(handle) == 91,
			"Host DATA must atomically bind batch identity, phase and source id."
		)
	_release_all_handles(service)
	await physics_frame
	_expect(
		service.get_active_slot_count() == 0,
		"Host DATA handles must have a zero-live terminal state."
	)
	await _destroy_fixture(fixture)


func _test_host_registration_failure_is_terminal() -> void:
	var fixture := _create_fixture(
		CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY,
		"AKDataRejectedHost"
	)
	var gateway := fixture.get_node(
		"MultiplayerGameplayGateway"
	) as CapturingGateway
	gateway.reject_data_registration = true
	var enemy := _spawn_enemy(fixture, gateway)
	var service := _get_rapid_service(fixture)
	enemy.call(&"_prepare_network_burst", CAPOO_CONFIG)
	var fired := bool(enemy.call(&"_fire_locked_bullet"))
	_expect(
		not fired
		and _count_live_bullet_nodes(fixture) == 0
		and gateway.node_registration_count == 0,
		"Rejected Host DATA registration must not fall back to the legacy Node backend."
	)
	await physics_frame
	_expect(
		service.get_active_slot_count() == 0,
		"Rejected Host DATA registration must release its inert handle."
	)
	await _destroy_fixture(fixture)


func _test_client_boundary() -> void:
	var fixture := _create_fixture(
		CombatRuntimeBase.RuntimeMode.CLIENT_VIEW,
		"AKClientBoundary"
	)
	var gateway := fixture.get_node(
		"MultiplayerGameplayGateway"
	) as CapturingGateway
	var enemy := _spawn_enemy(fixture, gateway)
	var service := _get_rapid_service(fixture)
	_expect(
		not bool(enemy.call(&"_fire_locked_bullet"))
		and service.get_active_slot_count() == 0,
		"CLIENT_VIEW must never fire an authoritative DATA projectile."
	)
	await _destroy_fixture(fixture)


func _create_fixture(
	runtime_mode: CombatRuntimeBase.RuntimeMode,
	fixture_name: String
) -> PlayerTestCombatRuntime:
	var fixture := PlayerTestCombatRuntime.new()
	fixture.name = fixture_name
	fixture.runtime_mode = runtime_mode
	var gateway_placeholder := fixture.get_node("MultiplayerGameplayGateway")
	fixture.remove_child(gateway_placeholder)
	gateway_placeholder.free()
	var gateway := CapturingGateway.new()
	gateway.name = "MultiplayerGameplayGateway"
	fixture.add_child(gateway)
	fixture.add_child(ENEMY_SIMULATION_COORDINATOR_SCENE.instantiate())
	root.add_child(fixture)
	current_scene = fixture
	return fixture


func _spawn_enemy(
	fixture: PlayerTestCombatRuntime,
	gateway: CapturingGateway
) -> CapooAK47:
	var enemy := CAPOO_SCENE.instantiate() as CapooAK47
	fixture.enemy_container.add_child(enemy)
	enemy.global_position = Vector2(160.0, 160.0)
	enemy.setup(
		CAPOO_CONFIG,
		null,
		fixture.get_node("GridPathfinder"),
		fixture
	)
	enemy.bind_gameplay_gateway(gateway)
	enemy.set_process(false)
	enemy.set_physics_process(false)
	enemy.burst_shot_direction = Vector2.RIGHT
	return enemy


func _fire_complete_burst(enemy: CapooAK47) -> void:
	enemy.combat_state = CapooAK47.CombatState.BURST
	enemy.burst_shots_fired = 0
	enemy.burst_fire_time_left = 0.0
	enemy.call(&"_prepare_network_burst", CAPOO_CONFIG)
	for shot_index in range(CAPOO_CONFIG.burst_count):
		enemy.call(
			&"_update_burst",
			0.0 if shot_index == 0 else CAPOO_CONFIG.burst_fire_interval
		)


func _get_rapid_service(
	fixture: PlayerTestCombatRuntime
) -> RapidFireSimulationService:
	var services := fixture.get_enemy_combat_services()
	return services.get_rapid_fire_simulation_service()


func _release_all_handles(service: RapidFireSimulationService) -> void:
	for stable_index in range(service.get_dense_record_count()):
		var handle := service.get_handle_at_stable_index(stable_index)
		if handle > RapidFireSimulationService.INVALID_HANDLE:
			service.release_projectile(handle)


func _count_live_bullet_nodes(fixture: Node) -> int:
	var count := 0
	for child in fixture.get_children():
		var bullet := child as CapooAK47Bullet
		if bullet != null and bullet.pool_active and not bullet.has_hit:
			count += 1
	return count


func _destroy_fixture(fixture: PlayerTestCombatRuntime) -> void:
	current_scene = null
	fixture.queue_free()
	await process_frame
	await physics_frame


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("CAPOO_AK47_DATA_BACKEND_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)
