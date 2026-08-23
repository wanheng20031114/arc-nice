extends SceneTree

const FIXTURE_SCENE := preload(
	"res://dev_tools/fixtures/rapid_fire_authoritative_collision_fixture.tscn"
)
const PLANT_CONFIG := preload(
	"res://resources/config/plant_defense/excavator.tres"
)
const TEST_SESSION_SCRIPT := preload(
	"res://dev_tools/fixtures/enemy_gameplay_gateway_test_session.gd"
)
const RapidFireService := preload(
	"res://scene/combat/simulation/rapid_fire_simulation_service.gd"
)
const TEST_DELTA := 1.0 / 60.0
const TEST_SPEED := 600.0
const FAR_POSITION := Vector2(10000.0, 10000.0)
const PLANT_ID := 301
const PLAYER_ID := 7

var failures: Array[String] = []
var fixture: EnemyGameplayGatewayTestRuntime = null
var service: RapidFireSimulationService = null
var damageable_index: EnemyDamageableSpatialIndex = null
var plant_system: PlantSystem = null
var plant: PlantDefense = null
var player: Player = null
var wall: StaticBody2D = null
var session: EnemyGameplayGatewayTestSession = null


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	await _mount_fixture()
	if service != null:
		_test_authored_contract()
		await _test_next_frame_endpoint_delay_and_stable_damage()
		await _test_endpoint_only_and_initial_overlap()
		await _test_world_cadence_and_lifetime_ordering()
		await _test_world_target_precedence()
		await _test_moved_and_dead_plant_pending_contacts()
		await _test_player_authority_modes()
		await _test_host_plant_and_stable_spawn_order()
	await _cleanup_fixture()
	_finish()


func _mount_fixture() -> void:
	fixture = FIXTURE_SCENE.instantiate() as EnemyGameplayGatewayTestRuntime
	_expect(fixture != null, "Rapid-fire semantic fixture must instantiate.")
	if fixture == null:
		return
	root.add_child(fixture)
	current_scene = fixture
	await process_frame
	plant_system = fixture.get_node_or_null("PlantSystem") as PlantSystem
	plant = fixture.get_node_or_null(
		"PlantContainer/TargetPlant"
	) as PlantDefense
	player = fixture.get_node_or_null("TargetPlayer") as Player
	wall = fixture.get_node_or_null("ThinWorldWall") as StaticBody2D
	var plant_container := fixture.get_node_or_null("PlantContainer") as Node2D
	_expect(
		plant_system != null and plant != null and player != null and wall != null,
		"Fixture must author PlantSystem, Plant, Player, and thin World wall."
	)
	if plant_system == null or plant == null or player == null or wall == null:
		return
	plant_system.setup(
		null,
		null,
		plant_container,
		PlantSystem.DEFAULT_PLACEMENT_AREA,
		null,
		fixture,
		null
	)
	var footprint := _make_footprint_cells()
	plant.setup(PLANT_CONFIG, null, footprint)
	plant.set_meta(&"net_id", PLANT_ID)
	plant_system.call(
		"_register_plant_footprint",
		plant,
		footprint,
		PLANT_CONFIG
	)
	fixture.player = player
	fixture.multiplayer_local_peer_id = PLAYER_ID
	fixture.peer_players = {PLAYER_ID: player}
	player.peer_id = PLAYER_ID
	session = TEST_SESSION_SCRIPT.new() as EnemyGameplayGatewayTestSession
	fixture.attach_gameplay_session(session)
	var services := fixture.get_enemy_combat_services()
	_expect(services != null, "Fixture must expose bound enemy combat services.")
	if services == null:
		return
	service = services.get_rapid_fire_simulation_service()
	damageable_index = services.get_enemy_damageable_spatial_index()
	_expect(
		service != null and service.is_bound(),
		"Rapid-fire service must bind through authored combat services."
	)
	_expect(
		damageable_index != null and damageable_index.contains_damageable(plant),
		"PlantSystem lifecycle must register the authored plant in the shared index."
	)
	await _reset_context()


func _test_authored_contract() -> void:
	_expect(
		service.process_physics_priority == 4,
		"Rapid-fire service must run at priority 4: after actors and before priority-5 legacy batching."
	)
	_expect(
		service.get_ak_collision_size() == Vector2(5.0, 2.0)
		and is_equal_approx(
			service.get_ak_collision_center_forward_offset(), 0.5
		),
		"AK DATA collision must exactly preserve the effective 5x2 shape and 0.5 forward center."
	)


func _test_next_frame_endpoint_delay_and_stable_damage() -> void:
	await _reset_context(Vector2(12.0, 0.0))
	var health_before := plant.current_health
	var handle := _register_projectile(
		RapidFireService.Mode.DATA,
		101,
		1.0,
		1
	)
	_manual_step()
	_expect(
		service.get_position(handle).is_equal_approx(Vector2.ZERO)
		and service.get_slot_state(handle)
		== RapidFireService.SlotState.PENDING_ACTIVATION,
		"A newly registered DATA projectile must remain inert in its spawn physics frame."
	)
	await _next_manual_step()
	_expect(
		service.get_completion_count() == 0
		and service.get_position(handle).is_equal_approx(Vector2(10.0, 0.0))
		and plant.current_health == health_before,
		"The first active tick must move a full delta and cache endpoint contact without early damage."
	)
	await _next_manual_step()
	_expect_completion(
		RapidFireService.CompletionReason.TARGET,
		RapidFireService.TargetKind.PLANT,
		PLANT_ID,
		Vector2(10.0, 0.0),
		"A cached Plant endpoint contact must complete exactly one physics tick later."
	)
	_expect(
		plant.current_health < health_before
		and service.get_completion_damage_applied(0)
		and plant.last_damage_result != null
		and plant.last_damage_result.request.source_enemy_id == 700
		and plant.last_damage_result.request.source_projectile_id == 101
		and plant.last_damage_result.request.source_type
		== RapidFireService.AK_SOURCE_TYPE,
		"Authoritative Plant damage must retain stable enemy/projectile/type identity."
	)


func _test_endpoint_only_and_initial_overlap() -> void:
	await _reset_context(Vector2(5.5, 0.0))
	var handle := _register_projectile(
		RapidFireService.Mode.DATA,
		102,
		1.0,
		0
	)
	await _next_manual_step()
	await _next_manual_step()
	_expect(
		service.get_completion_count() == 0
		and service.is_handle_live(handle)
		and service.get_position(handle).is_equal_approx(Vector2(20.0, 0.0)),
		"A Plant crossed between endpoints must not be hit by a sweep or nearest-TOI query."
	)

	await _reset_context(Vector2.ZERO)
	var initial_health := plant.current_health
	var overlap_handle := _register_projectile(
		RapidFireService.Mode.DATA,
		103,
		1.0,
		1
	)
	await _next_manual_step()
	_expect(
		not service.is_handle_live(overlap_handle)
		and service.get_completion_count() == 1
		and service.get_completion_position(0).is_equal_approx(Vector2.ZERO)
		and plant.current_health < initial_health,
		"Spawn overlap must resolve on the first active tick before any movement."
	)


func _test_world_cadence_and_lifetime_ordering() -> void:
	await _reset_context(FAR_POSITION, FAR_POSITION, Vector2(5.0, 0.0))
	var phase_one := _register_projectile(
		RapidFireService.Mode.DATA,
		201,
		1.0,
		1
	)
	await _next_manual_step()
	_expect(
		service.get_completion_count() == 0
		and service.get_position(phase_one).is_equal_approx(Vector2(10.0, 0.0)),
		"Phase 1 must skip its first World query while retaining the complete delta."
	)
	await _next_manual_step()
	_expect_world_completion(
		"Phase 1 must ray the accumulated two-tick segment and catch a thin wall."
	)

	await _reset_context(FAR_POSITION, FAR_POSITION, Vector2(5.0, 0.0))
	_register_projectile(RapidFireService.Mode.DATA, 202, 1.0, 0)
	await _next_manual_step()
	_expect_world_completion(
		"Phase 0 must query on the first active movement tick."
	)
	_expect(
		int(service.get_metrics()["world_queries"]) == 1,
		"An unknown/non-certifying pathfinder must retain the native World ray."
	)

	await _reset_context(FAR_POSITION, FAR_POSITION, Vector2(5.0, 0.0))
	_register_projectile(
		RapidFireService.Mode.DATA,
		203,
		TEST_DELTA * 0.5,
		1
	)
	await _next_manual_step()
	_expect_world_completion(
		"Lifetime expiry must force the final unchecked World suffix even on the skipped phase."
	)

	await _reset_context(Vector2(12.0, 0.0))
	var final_health := plant.current_health
	_register_projectile(
		RapidFireService.Mode.DATA,
		204,
		TEST_DELTA * 0.5,
		1
	)
	await _next_manual_step()
	_expect(
		service.get_completion_count() == 1
		and service.get_completion_reason(0)
		== RapidFireService.CompletionReason.LIFETIME
		and service.get_completion_target_kind(0)
		== RapidFireService.TargetKind.NONE
		and plant.current_health == final_health,
		"The final tick must complete after its World check without creating endpoint target damage."
	)


func _test_world_target_precedence() -> void:
	await _reset_context(
		Vector2(12.0, 0.0),
		FAR_POSITION,
		Vector2(30.0, 0.0)
	)
	var clear_health := plant.current_health
	_register_projectile(RapidFireService.Mode.DATA, 301, 1.0, 1)
	await _next_manual_step()
	await _next_manual_step()
	_expect(
		service.get_completion_reason(0)
		== RapidFireService.CompletionReason.TARGET
		and plant.current_health < clear_health,
		"A wall behind the cached endpoint target must not replace the target contact."
	)

	await _reset_context(
		Vector2(12.0, 0.0),
		FAR_POSITION,
		Vector2(5.0, 0.0)
	)
	var blocked_health := plant.current_health
	_register_projectile(RapidFireService.Mode.DATA, 302, 1.0, 1)
	await _next_manual_step()
	_expect(
		service.get_completion_count() == 0,
		"A skipped-phase endpoint target must remain pending until the next physics tick."
	)
	await _next_manual_step()
	_expect(
		service.get_completion_reason(0)
		== RapidFireService.CompletionReason.WORLD
		and service.get_completion_target_kind(0)
		== RapidFireService.TargetKind.WORLD
		and plant.current_health == blocked_health,
		"World must win when it shares the unchecked segment with a pending target."
	)


func _test_moved_and_dead_plant_pending_contacts() -> void:
	await _reset_context(Vector2(12.0, 0.0))
	var moved_health := plant.current_health
	_register_projectile(RapidFireService.Mode.DATA, 401, 1.0, 1)
	await _next_manual_step()
	plant.global_position = Vector2(42.0, 0.0)
	_expect(
		plant_system.refresh_enemy_damageable_spatial_entry(plant),
		"A moved Plant must refresh the shared broad/exact cache explicitly."
	)
	await _next_manual_step()
	_expect(
		service.get_completion_reason(0)
		== RapidFireService.CompletionReason.TARGET
		and service.get_completion_position(0).is_equal_approx(Vector2(10.0, 0.0))
		and plant.current_health < moved_health,
		"A previously emitted endpoint contact must resolve next tick even after its live Plant moved."
	)

	await _reset_context(Vector2(12.0, 0.0))
	var dead_handle := _register_projectile(
		RapidFireService.Mode.DATA,
		402,
		1.0,
		1
	)
	await _next_manual_step()
	plant.is_dead = true
	await _next_manual_step()
	_expect(
		service.get_completion_count() == 0
		and service.is_handle_live(dead_handle)
		and service.get_position(dead_handle).is_equal_approx(Vector2(20.0, 0.0)),
		"A Plant that dies while contact is pending must be skipped and motion must continue this tick."
	)


func _test_player_authority_modes() -> void:
	await _reset_context(FAR_POSITION, Vector2(12.0, 0.0))
	var single_health := player.current_health
	_register_projectile(RapidFireService.Mode.DATA, 501, 1.0, 1)
	await _next_manual_step()
	await _next_manual_step()
	_expect(
		service.get_completion_target_kind(0)
		== RapidFireService.TargetKind.PLAYER
		and service.get_completion_target_id(0) == PLAYER_ID
		and service.get_completion_damage_applied(0)
		and player.current_health < single_health
		and player.last_damage_result.request.source_enemy_id == 700
		and player.last_damage_result.request.source_projectile_id == 501,
		"Singleplayer Player contact must use direct stable DamageRequest damage."
	)

	await _reset_context(
		FAR_POSITION,
		Vector2(12.0, 0.0),
		FAR_POSITION,
		CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY
	)
	var host_health := player.current_health
	_register_projectile(RapidFireService.Mode.DATA, 502, 1.0, 1)
	await _next_manual_step()
	await _next_manual_step()
	_expect(
		service.get_completion_damage_applied(0)
		and player.current_health == host_health
		and session.player_damage_requests.size() == 1
		and int(session.player_damage_requests[0]["source_id"]) == 502
		and int(session.player_damage_requests[0]["target_peer_id"]) == PLAYER_ID
		and bool(session.player_damage_requests[0]["is_ranged"]),
		"HOST Player contact must route through the gameplay gateway with projectile identity."
	)

	await _reset_context(
		FAR_POSITION,
		Vector2(12.0, 0.0),
		FAR_POSITION,
		CombatRuntimeBase.RuntimeMode.CLIENT_VIEW
	)
	var client_health := player.current_health
	_register_projectile(RapidFireService.Mode.DATA, 503, 1.0, 1)
	await _next_manual_step()
	await _next_manual_step()
	_expect(
		service.get_completion_count() == 1
		and not service.get_completion_damage_applied(0)
		and player.current_health == client_health
		and session.player_damage_requests.is_empty(),
		"CLIENT_VIEW DATA contact must consume locally without damage or network output."
	)

	await _reset_context(
		FAR_POSITION,
		Vector2(12.0, 0.0),
		FAR_POSITION,
		CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY
	)
	var shadow_health := player.current_health
	_register_projectile(RapidFireService.Mode.SHADOW, 504, 1.0, 1)
	await _next_manual_step()
	await _next_manual_step()
	_expect(
		service.get_completion_count() == 1
		and not service.get_completion_damage_applied(0)
		and player.current_health == shadow_health
		and session.player_damage_requests.is_empty(),
		"SHADOW contact must never damage, send a packet, or require an effect path."
	)


func _test_host_plant_and_stable_spawn_order() -> void:
	await _reset_context(
		Vector2.ZERO,
		FAR_POSITION,
		FAR_POSITION,
		CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY
	)
	var host_plant_health := plant.current_health
	_register_projectile(RapidFireService.Mode.DATA, 601, 1.0, 0)
	await _next_manual_step()
	_expect(
		plant.current_health < host_plant_health
		and service.get_completion_damage_applied(0)
		and session.player_damage_requests.is_empty(),
		"HOST Plant damage must remain a direct stable DamageRequest, not a Player packet."
	)

	await _reset_context(Vector2(12.0, 0.0))
	_register_projectile(RapidFireService.Mode.SHADOW, 701, 1.0, 1)
	_register_projectile(RapidFireService.Mode.SHADOW, 702, 1.0, 1)
	await _next_manual_step()
	await _next_manual_step()
	_expect(
		service.get_completion_count() == 2
		and service.get_completion_projectile_id(0) == 701
		and service.get_completion_projectile_id(1) == 702
		and service.get_completion_spawn_sequence(0)
		< service.get_completion_spawn_sequence(1),
		"Same-frame pending contacts must complete in stable spawn order."
	)


func _reset_context(
	plant_position: Vector2 = FAR_POSITION,
	player_position: Vector2 = FAR_POSITION,
	wall_position: Vector2 = FAR_POSITION,
	runtime_mode: int = CombatRuntimeBase.RuntimeMode.SINGLEPLAYER
) -> void:
	service.clear()
	service.reserve_projectile_capacity(8)
	service.set_physics_process(false)
	fixture.runtime_mode = runtime_mode as CombatRuntimeBase.RuntimeMode
	session.player_damage_requests.clear()
	plant.is_dead = false
	plant.is_removing = false
	plant.current_health = maxi(plant.max_health, 100)
	plant.last_damage_result = null
	plant.global_position = plant_position
	plant_system.refresh_enemy_damageable_spatial_entry(plant)
	player.is_dead = false
	player.current_health = maxi(player.max_health, 100)
	player.invincibility_time_left = 0.0
	player.last_damage_result = null
	player.global_position = player_position
	wall.global_position = wall_position
	await physics_frame


func _register_projectile(
	mode: int,
	projectile_id: int,
	lifetime: float,
	phase: int
) -> int:
	var handle := service.register_projectile(
		mode as RapidFireService.Mode,
		RapidFireService.Profile.AK,
		Vector2.ZERO,
		Vector2.RIGHT,
		TEST_SPEED,
		lifetime,
		25,
		700,
		projectile_id,
		RapidFireService.AK_WORLD_CHECK_INTERVAL,
		phase
	)
	service.set_physics_process(false)
	_expect(handle > 0, "Semantic projectile registration must succeed.")
	return handle


func _manual_step(delta: float = TEST_DELTA) -> void:
	service._physics_process(delta)
	service.set_physics_process(false)


func _next_manual_step(delta: float = TEST_DELTA) -> void:
	await physics_frame
	_manual_step(delta)


func _expect_completion(
	reason: int,
	target_kind: int,
	target_id: int,
	position: Vector2,
	message: String
) -> void:
	_expect(
		service.get_completion_count() == 1
		and service.get_completion_reason(0) == reason
		and service.get_completion_target_kind(0) == target_kind
		and service.get_completion_target_id(0) == target_id
		and service.get_completion_position(0).is_equal_approx(position),
		message
	)


func _expect_world_completion(message: String) -> void:
	_expect(
		service.get_completion_count() == 1
		and service.get_completion_reason(0)
		== RapidFireService.CompletionReason.WORLD
		and service.get_completion_target_kind(0)
		== RapidFireService.TargetKind.WORLD
		and service.get_completion_position(0).x > 4.0
		and service.get_completion_position(0).x < 6.0,
		message
	)


func _make_footprint_cells() -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	for y in range(PLANT_CONFIG.footprint_size.y):
		for x in range(PLANT_CONFIG.footprint_size.x):
			result.append(Vector2i(x, y))
	return result


func _cleanup_fixture() -> void:
	if service != null and is_instance_valid(service):
		service.set_physics_process(false)
	if fixture != null and is_instance_valid(fixture):
		if session != null:
			fixture.detach_gameplay_session(session)
		fixture.prepare_for_scene_teardown()
		fixture.queue_free()
	if session != null and is_instance_valid(session):
		session.free()
	current_scene = null
	for _cleanup_frame in range(4):
		await process_frame
	await physics_frame


func _finish() -> void:
	var result := {
		"status": "ok" if failures.is_empty() else "failed",
		"failures": failures.duplicate(),
	}
	print("RAPID_FIRE_AUTHORITATIVE_COLLISION_JSON %s" % JSON.stringify(result))
	if failures.is_empty():
		print("RAPID_FIRE_AUTHORITATIVE_COLLISION_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
