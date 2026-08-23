extends SceneTree

const CAPOO_SCENE := preload("res://scene/enemy/capoo/capoo_ak47.tscn")
const CAPOO_CONFIG := preload("res://resources/config/enemies/capoo_ak47.tres")
const BULLET_SCENE := preload(
	"res://scene/enemy/capoo/capoo_ak47_bullet.tscn"
)
const ENEMY_SIMULATION_COORDINATOR_SCENE := preload(
	"res://scene/combat/simulation/enemy_simulation_coordinator.tscn"
)


class CapturingGateway:
	extends MultiplayerGameplayGateway

	var next_projectile_id := 7001
	var data_payloads: Array[Array] = []
	var legacy_registration_count := 0
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
		_target_enemy_net_id: int = 0
	) -> void:
		legacy_registration_count += 1
		var bullet := projectile as CapooAK47Bullet
		if bullet != null:
			bullet.setup_multiplayer(
				next_projectile_id,
				owner_peer_id,
				projectile_type
			)
			next_projectile_id += 1


	func register_local_data_projectile(
		service: RapidFireSimulationService,
		handle: int,
		projectile_type: StringName,
		owner_peer_id: int,
		spawn_position: Vector2,
		direction: Vector2,
		damage: int,
		speed: float,
		lifetime: float
	) -> int:
		if reject_data_registration:
			return 0
		var projectile_id := next_projectile_id
		if not service.assign_projectile_identity(handle, projectile_id):
			return 0
		next_projectile_id += 1
		# Mirrors the established net_projectile_fired payload. The actual
		# coordinator contract is separately exercised by its integration smoke.
		data_payloads.append([
			projectile_id,
			String(projectile_type),
			owner_peer_id,
			spawn_position,
			direction,
			damage,
			speed,
			lifetime,
			false,
			0,
			12.5,
			0,
		])
		return projectile_id


	func notify_data_projectile_finished(
		_projectile_id: int,
		_service: RapidFireSimulationService,
		_handle: int
	) -> void:
		data_finish_count += 1


var failures := PackedStringArray()
var saved_projectile_backend := CapooAK47.ProjectileBackend.SHADOW


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	saved_projectile_backend = CapooAK47.projectile_backend
	_expect(
		CapooAK47.projectile_backend
		== CapooAK47.ProjectileBackend.SHADOW,
		"AK migration must remain SHADOW by default."
	)
	await _test_singleplayer_data_burst()
	await _test_host_data_identity_and_payload()
	await _test_host_registration_failure_is_terminal()
	await _test_shadow_observation_and_release()
	await _test_legacy_and_client_boundaries()
	CapooAK47.projectile_backend = saved_projectile_backend
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
	CapooAK47.projectile_backend = CapooAK47.ProjectileBackend.DATA
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
		and gateway.legacy_registration_count == 0,
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
	CapooAK47.projectile_backend = CapooAK47.ProjectileBackend.DATA
	_fire_complete_burst(enemy)
	_expect(
		_count_live_bullet_nodes(fixture) == 0
		and service.get_active_slot_count() == CAPOO_CONFIG.burst_count,
		"Host DATA burst must use handles without authority projectile Nodes."
	)
	_expect(
		gateway.data_payloads.size() == CAPOO_CONFIG.burst_count,
		"Host DATA burst must register one existing-format broadcast per shot."
	)
	for stable_index in range(service.get_dense_record_count()):
		var handle := service.get_handle_at_stable_index(stable_index)
		var payload := gateway.data_payloads[stable_index]
		var projectile_id := int(payload[0])
		_expect(
			payload.size() == 12
			and String(payload[1]) == "capoo_ak47_bullet"
			and service.get_projectile_id(handle) == projectile_id
			and service.get_world_check_phase(handle) == projectile_id % 2
			and service.get_source_enemy_id(handle) == 91,
			"Host DATA must atomically bind its 12-field payload, handle identity, phase and source id."
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
	CapooAK47.projectile_backend = CapooAK47.ProjectileBackend.DATA
	var fired := bool(enemy.call(&"_fire_locked_bullet"))
	_expect(
		not fired
		and _count_live_bullet_nodes(fixture) == 0
		and gateway.legacy_registration_count == 0,
		"Rejected Host DATA registration must not fall back to the legacy Node backend."
	)
	await physics_frame
	_expect(
		service.get_active_slot_count() == 0,
		"Rejected Host DATA registration must release its inert handle."
	)
	await _destroy_fixture(fixture)


func _test_shadow_observation_and_release() -> void:
	var fixture := _create_fixture(
		CombatRuntimeBase.RuntimeMode.SINGLEPLAYER,
		"AKShadow"
	)
	var gateway := fixture.get_node(
		"MultiplayerGameplayGateway"
	) as CapturingGateway
	var enemy := _spawn_enemy(fixture, gateway)
	var service := _get_rapid_service(fixture)
	var motion := fixture.get_node(
		"CapooProjectileMotionSystem"
	) as CapooProjectileMotionSystem
	CapooAK47.projectile_backend = CapooAK47.ProjectileBackend.SHADOW
	_expect(
		bool(enemy.call(&"_fire_locked_bullet")),
		"SHADOW must keep the legacy authoritative projectile path."
	)
	var bullet := _find_live_bullet(fixture)
	_expect(
		bullet != null
		and service.get_active_slot_count() == 1
		and service.get_metrics().get("shadow_slots", 0) == 1
		and service.get_metrics().get("data_slots", 0) == 0,
		"SHADOW must pair one legacy Node with one non-authoritative handle."
	)
	await physics_frame
	await physics_frame
	_expect(
		service.get_difference_count() > 0
		and int(service.get_metrics().get("damage_applications", -1)) == 0,
		"SHADOW must record post-advance observations without applying data damage."
	)
	if bullet != null:
		bullet.retire(false)
	await physics_frame
	_expect(
		service.get_active_slot_count() == 0
		and motion.get_active_projectile_count() == 0,
		"SHADOW retirement must release both the handle and legacy motion slot."
	)
	await _destroy_fixture(fixture)


func _test_legacy_and_client_boundaries() -> void:
	var fixture := _create_fixture(
		CombatRuntimeBase.RuntimeMode.SINGLEPLAYER,
		"AKLegacy"
	)
	var gateway := fixture.get_node(
		"MultiplayerGameplayGateway"
	) as CapturingGateway
	var enemy := _spawn_enemy(fixture, gateway)
	var service := _get_rapid_service(fixture)
	CapooAK47.projectile_backend = CapooAK47.ProjectileBackend.LEGACY
	_expect(
		bool(enemy.call(&"_fire_locked_bullet"))
		and _count_live_bullet_nodes(fixture) == 1
		and service.get_active_slot_count() == 0,
		"LEGACY must remain an explicit Node-only rollback path."
	)
	var legacy_bullet := _find_live_bullet(fixture)
	if legacy_bullet != null:
		legacy_bullet.retire(false)
	await physics_frame
	fixture.runtime_mode = CombatRuntimeBase.RuntimeMode.CLIENT_VIEW
	CapooAK47.projectile_backend = CapooAK47.ProjectileBackend.DATA
	_expect(
		not bool(enemy.call(&"_fire_locked_bullet"))
		and service.get_active_slot_count() == 0,
		"CLIENT_VIEW must never fire an authoritative DATA projectile."
	)
	var client_proxy := BULLET_SCENE.instantiate() as CapooAK47Bullet
	fixture.add_child(client_proxy)
	client_proxy.setup_multiplayer(8801, 0, &"capoo_ak47_bullet")
	_expect(
		client_proxy.projectile_id == 8801
		and client_proxy.source_type == &"capoo_ak47_bullet",
		"The existing client legacy visual-proxy identity contract must remain available."
	)
	client_proxy.retire(false)
	await _destroy_fixture(fixture)


func _create_fixture(
	runtime_mode: CombatRuntimeBase.RuntimeMode,
	fixture_name: String
) -> PlayerTestCombatRuntime:
	var fixture := PlayerTestCombatRuntime.new()
	fixture.name = fixture_name
	fixture.runtime_mode = runtime_mode
	var motion_placeholder := fixture.get_node("CapooProjectileMotionSystem")
	fixture.remove_child(motion_placeholder)
	motion_placeholder.free()
	var motion_system := CapooProjectileMotionSystem.new()
	motion_system.name = "CapooProjectileMotionSystem"
	motion_system.process_physics_priority = 5
	fixture.add_child(motion_system)
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


func _find_live_bullet(fixture: Node) -> CapooAK47Bullet:
	for child in fixture.get_children():
		var bullet := child as CapooAK47Bullet
		if bullet != null and bullet.pool_active and not bullet.has_hit:
			return bullet
	return null


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
