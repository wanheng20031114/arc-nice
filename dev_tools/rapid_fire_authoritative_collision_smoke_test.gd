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
const BASE_ENEMY_SCENE := preload("res://scene/enemy/enemy.tscn")
const RapidFireService := preload(
	"res://scene/combat/simulation/rapid_fire_simulation_service.gd"
)
const TEST_DELTA := 1.0 / 60.0
const TEST_SPEED := 600.0
const FAR_POSITION := Vector2(10000.0, 10000.0)
const PLANT_ID := 301
const PLAYER_ID := 7
const LOW_ENEMY_ID := 801
const HIGH_ENEMY_ID := 802

var failures: Array[String] = []
var fixture: EnemyGameplayGatewayTestRuntime = null
var service: RapidFireSimulationService = null
var damageable_index: EnemyDamageableSpatialIndex = null
var plant_system: PlantSystem = null
var plant: PlantDefense = null
var player: Player = null
var wall: StaticBody2D = null
var session: EnemyGameplayGatewayTestSession = null
var low_enemy: Enemy = null
var high_enemy: Enemy = null


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	await _mount_fixture()
	if service != null:
		_test_authored_contract()
		await _test_gunner_profiles_endpoint_world_and_source_types()
		await _test_next_frame_endpoint_delay_and_stable_damage()
		await _test_endpoint_only_and_initial_overlap()
		await _test_world_cadence_and_lifetime_ordering()
		await _test_world_target_precedence()
		await _test_moved_and_dead_plant_pending_contacts()
		await _test_enemy_contact_and_friendly_transparency()
		await _test_pending_enemy_faction_change_and_stable_order()
		await _test_player_authority_modes()
		await _test_host_plant_and_stable_spawn_order()
		await _test_enemy_defeat_source_snapshot_attribution()
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
	_mount_enemy_targets()
	_expect(
		service != null and service.is_bound(),
		"Rapid-fire service must bind through authored combat services."
	)
	_expect(
		damageable_index != null and damageable_index.contains_damageable(plant),
		"PlantSystem lifecycle must register the authored plant in the shared index."
	)
	await _reset_context()


func _mount_enemy_targets() -> void:
	var enemy_container := fixture.get_node_or_null("EnemyContainer") as Node2D
	_expect(enemy_container != null, "Rapid-fire fixture must author EnemyContainer.")
	if enemy_container == null:
		return
	high_enemy = BASE_ENEMY_SCENE.instantiate() as Enemy
	low_enemy = BASE_ENEMY_SCENE.instantiate() as Enemy
	var mounted_enemies: Array[Enemy] = [high_enemy, low_enemy]
	for enemy in mounted_enemies:
		if enemy == null:
			continue
		enemy.process_mode = Node.PROCESS_MODE_DISABLED
		enemy.visible = false
		enemy_container.add_child(enemy)
		enemy.bind_combat_runtime(fixture)
		enemy.current_health = 100
		enemy.global_position = FAR_POSITION
	var mounted := high_enemy != null and low_enemy != null
	_expect(mounted, "Rapid-fire fixture enemy targets must instantiate.")
	if not mounted:
		return
	high_enemy.set_meta(&"net_id", HIGH_ENEMY_ID)
	low_enemy.set_meta(&"net_id", LOW_ENEMY_ID)
	# Register in reverse stable-ID order so the projectile resolver must select
	# by stable identity rather than bucket insertion order.
	fixture.register_combat_target(HIGH_ENEMY_ID, high_enemy)
	fixture.register_combat_target(LOW_ENEMY_ID, low_enemy)


func _test_authored_contract() -> void:
	_expect(
		service.process_physics_priority == 4,
		"Rapid-fire service must run at priority 4: after actors and before priority-5 legacy batching."
	)
	_expect(
		service.get_ak_collision_size() == Vector2(5.0, 2.0)
		and is_equal_approx(
			service.get_ak_collision_center_forward_offset(), 0.5
		)
		and service.get_profile_collision_size(
			RapidFireService.Profile.GUNNER
		) == Vector2(9.0, 3.0)
		and service.get_profile_collision_size(
			RapidFireService.Profile.GUNNER_ELITE
		) == Vector2(9.0, 3.0)
		and is_zero_approx(service.get_profile_collision_center_forward_offset(
			RapidFireService.Profile.GUNNER
		))
		and is_zero_approx(service.get_profile_collision_center_forward_offset(
			RapidFireService.Profile.GUNNER_ELITE
		)),
		"AK and Gunner DATA profiles must preserve their exact authored rectangles and center offsets."
	)


func _test_gunner_profiles_endpoint_world_and_source_types() -> void:
	await _reset_context(Vector2(16.0, 0.0))
	var normal_health := plant.current_health
	var normal_handle := _register_projectile(
		RapidFireService.Mode.DATA,
		801,
		1.0,
		1,
		RapidFireService.Profile.GUNNER
	)
	await _next_manual_step()
	_expect(
		service.get_completion_count() == 0
		and service.get_position(normal_handle).is_equal_approx(Vector2(10.0, 0.0))
		and plant.current_health == normal_health,
		"GUNNER 9x3 endpoint contact must retain the Area-style one-physics-tick delay."
	)
	await _next_manual_step()
	_expect(
		service.get_completion_count() == 1
		and service.get_completion_reason(0)
		== RapidFireService.CompletionReason.TARGET
		and service.get_completion_profile(0)
		== RapidFireService.Profile.GUNNER
		and service.get_completion_position(0).is_equal_approx(Vector2(10.0, 0.0))
		and plant.current_health < normal_health
		and plant.last_damage_result != null
		and plant.last_damage_result.request.source_type
		== RapidFireService.GUNNER_SOURCE_TYPE
		and plant.last_damage_result.request.source_enemy_id == 700
		and plant.last_damage_result.request.source_projectile_id == 801,
		"GUNNER must use endpoint exact contact and its stable normal source type."
	)

	await _reset_context(Vector2.ZERO)
	var elite_health := plant.current_health
	_register_projectile(
		RapidFireService.Mode.DATA,
		802,
		1.0,
		0,
		RapidFireService.Profile.GUNNER_ELITE
	)
	await _next_manual_step()
	_expect(
		service.get_completion_count() == 1
		and service.get_completion_profile(0)
		== RapidFireService.Profile.GUNNER_ELITE
		and service.get_completion_position(0).is_equal_approx(Vector2.ZERO)
		and plant.current_health < elite_health
		and plant.last_damage_result.request.source_type
		== RapidFireService.GUNNER_ELITE_SOURCE_TYPE,
		"GUNNER_ELITE spawn overlap must preserve zero movement and its elite source type."
	)

	await _reset_context(FAR_POSITION, FAR_POSITION, Vector2(5.0, 0.0))
	var phase_one := _register_projectile(
		RapidFireService.Mode.DATA,
		803,
		1.0,
		1,
		RapidFireService.Profile.GUNNER_ELITE
	)
	await _next_manual_step()
	_expect(
		service.get_completion_count() == 0
		and service.get_position(phase_one).is_equal_approx(Vector2(10.0, 0.0)),
		"GUNNER_ELITE phase 1 must skip its first World ray and keep full movement."
	)
	await _next_manual_step()
	_expect_world_completion(
		"GUNNER_ELITE must catch a thin wall with the accumulated two-tick World segment."
	)
	_expect(
		service.get_completion_profile(0)
		== RapidFireService.Profile.GUNNER_ELITE,
		"World completion must retain the originating elite Profile."
	)

	await _reset_context(Vector2(16.0, 0.0))
	var final_health := plant.current_health
	_register_projectile(
		RapidFireService.Mode.DATA,
		804,
		TEST_DELTA * 0.5,
		1,
		RapidFireService.Profile.GUNNER
	)
	await _next_manual_step()
	_expect(
		service.get_completion_count() == 1
		and service.get_completion_reason(0)
		== RapidFireService.CompletionReason.LIFETIME
		and service.get_completion_target_kind(0)
		== RapidFireService.TargetKind.NONE
		and plant.current_health == final_health,
		"GUNNER final lifetime must validate World then finish without endpoint target damage."
	)

	await _reset_context(Vector2(10.0, 0.0), Vector2(10.0, 0.0))
	low_enemy.global_position = Vector2(22.0, 0.0)
	var allied_gunner_source := DamageSourceSnapshot.create(
		CombatRelationService.PLAYER_ALLIED,
		29,
		700,
		805,
		RapidFireService.GUNNER_SOURCE_TYPE
	)
	var allied_plant_health := plant.current_health
	var allied_player_health := player.current_health
	var hostile_enemy_health := low_enemy.current_health
	_register_projectile(
		RapidFireService.Mode.DATA,
		805,
		1.0,
		1,
		RapidFireService.Profile.GUNNER,
		allied_gunner_source
	)
	await _next_manual_step()
	await _next_manual_step()
	_expect(
		service.get_completion_count() == 1
		and service.get_completion_target_kind(0)
		== RapidFireService.TargetKind.ENEMY
		and service.get_completion_target_id(0) == LOW_ENEMY_ID
		and plant.current_health == allied_plant_health
		and player.current_health == allied_player_health
		and low_enemy.current_health < hostile_enemy_health
		and low_enemy.last_damage_result.request.source_type
		== RapidFireService.GUNNER_SOURCE_TYPE
		and low_enemy.last_damage_result.request.source_snapshot.credit_peer_id == 29
		and low_enemy.last_damage_result.request.source_snapshot.event_source_id == 805,
		"A player-allied Gunner 9x3 boundary contact must pass through allied Player/Plant bodies, hit the hostile Enemy, and preserve launch attribution."
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
		== RapidFireService.AK_SOURCE_TYPE
		and plant.last_damage_result.request.source_snapshot_is_explicit
		and plant.last_damage_result.request.source_snapshot.source_faction_id
		== CombatRelationService.HOSTILE_WAVE
		and plant.last_damage_result.request.source_snapshot.instigator_entity_id
		== 700
		and plant.last_damage_result.request.source_snapshot.event_source_id
		== 101,
		"Authoritative Plant damage must rebuild the frozen hostile source while retaining stable enemy/projectile/type identity."
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


func _test_enemy_contact_and_friendly_transparency() -> void:
	await _reset_context(Vector2(12.0, 0.0), Vector2(12.0, 0.0))
	low_enemy.global_position = Vector2(20.0, 0.0)
	var plant_health := plant.current_health
	var player_health := player.current_health
	var enemy_health := low_enemy.current_health
	var allied_source := DamageSourceSnapshot.create(
		CombatRelationService.PLAYER_ALLIED,
		17,
		700,
		901,
		RapidFireService.AK_SOURCE_TYPE
	)
	_register_projectile(
		RapidFireService.Mode.DATA,
		901,
		1.0,
		1,
		RapidFireService.Profile.AK,
		allied_source
	)
	await _next_manual_step()
	await _next_manual_step()
	_expect_completion(
		RapidFireService.CompletionReason.TARGET,
		RapidFireService.TargetKind.ENEMY,
		LOW_ENEMY_ID,
		Vector2(10.0, 0.0),
		"A DATA AK round must pass through allied Player/Plant bodies and hit the hostile indexed Enemy whose root lies outside the raw projectile AABB."
	)
	_expect(
		plant.current_health == plant_health
		and player.current_health == player_health
		and low_enemy.current_health < enemy_health
		and service.get_completion_damage_applied(0),
		"Friendly Player/Plant candidates must be transparent while hostile Enemy damage remains authoritative."
	)

	await _reset_context(Vector2(12.0, 0.0))
	low_enemy.global_position = Vector2(20.0, 0.0)
	var hostile_plant_health := plant.current_health
	var friendly_enemy_health := low_enemy.current_health
	_register_projectile(RapidFireService.Mode.DATA, 902, 1.0, 1)
	await _next_manual_step()
	await _next_manual_step()
	_expect(
		service.get_completion_target_kind(0)
		== RapidFireService.TargetKind.PLANT
		and plant.current_health < hostile_plant_health
		and low_enemy.current_health == friendly_enemy_health,
		"A wave-hostile DATA round must ignore its same-faction Enemy body and retain the legacy hostile Plant contact."
	)


func _test_pending_enemy_faction_change_and_stable_order() -> void:
	await _reset_context()
	low_enemy.global_position = Vector2(20.0, 0.0)
	var allied_source := DamageSourceSnapshot.create(
		CombatRelationService.PLAYER_ALLIED,
		19,
		700,
		903,
		RapidFireService.AK_SOURCE_TYPE
	)
	var pending_handle := _register_projectile(
		RapidFireService.Mode.DATA,
		903,
		1.0,
		1,
		RapidFireService.Profile.AK,
		allied_source
	)
	await _next_manual_step()
	_expect(
		service.get_completion_count() == 0,
		"A hostile Enemy endpoint must retain the existing one-tick contact delivery delay."
	)
	low_enemy.set_combat_faction_id(
		CombatRelationService.PLAYER_ALLIED,
		-1,
		true
	)
	var health_before_resolution := low_enemy.current_health
	await _next_manual_step()
	_expect(
		service.get_completion_count() == 0
		and service.is_handle_live(pending_handle)
		and service.get_position(pending_handle).is_equal_approx(
			Vector2(20.0, 0.0)
		)
		and low_enemy.current_health == health_before_resolution,
		"An Enemy that becomes friendly while contact is pending must become transparent without consuming the projectile."
	)

	await _reset_context()
	low_enemy.global_position = Vector2(20.0, 0.0)
	high_enemy.global_position = Vector2(20.0, 0.0)
	var low_health := low_enemy.current_health
	var high_health := high_enemy.current_health
	var stable_source := DamageSourceSnapshot.create(
		CombatRelationService.PLAYER_ALLIED,
		21,
		700,
		904,
		RapidFireService.AK_SOURCE_TYPE
	)
	_register_projectile(
		RapidFireService.Mode.DATA,
		904,
		1.0,
		1,
		RapidFireService.Profile.AK,
		stable_source
	)
	await _next_manual_step()
	await _next_manual_step()
	_expect(
		service.get_completion_target_kind(0)
		== RapidFireService.TargetKind.ENEMY
		and service.get_completion_target_id(0) == LOW_ENEMY_ID
		and low_enemy.current_health < low_health
		and high_enemy.current_health == high_health,
		"Overlapping hostile Enemy candidates must resolve by stable net ID rather than reverse registration order."
	)


func _test_enemy_defeat_source_snapshot_attribution() -> void:
	await _reset_context()
	low_enemy.global_position = Vector2(20.0, 0.0)
	low_enemy.current_health = 10
	var allied_source := DamageSourceSnapshot.create(
		CombatRelationService.PLAYER_ALLIED,
		23,
		700,
		905,
		RapidFireService.AK_SOURCE_TYPE
	)
	_register_projectile(
		RapidFireService.Mode.DATA,
		905,
		1.0,
		1,
		RapidFireService.Profile.AK,
		allied_source
	)
	await _next_manual_step()
	await _next_manual_step()
	_expect(
		low_enemy.is_dead
		and low_enemy.defeat_context != null
		and low_enemy.defeat_context.is_player_reward_eligible()
		and low_enemy.defeat_context.source_snapshot.source_faction_id
		== CombatRelationService.PLAYER_ALLIED
		and low_enemy.defeat_context.source_snapshot.credit_peer_id == 23
		and low_enemy.defeat_context.source_snapshot.instigator_entity_id == 700
		and low_enemy.defeat_context.source_snapshot.event_source_id == 905,
		"A player-allied DATA Enemy kill must retain launch faction, credit, instigator, and projectile event identity for reward settlement."
	)

	service.clear()
	service.reserve_projectile_capacity(8)
	service.set_physics_process(false)
	high_enemy.set_combat_faction_id(
		CombatRelationService.PLAYER_ALLIED,
		-1,
		true
	)
	high_enemy.current_health = 10
	high_enemy.global_position = Vector2(20.0, 0.0)
	_register_projectile(RapidFireService.Mode.DATA, 906, 1.0, 1)
	await _next_manual_step()
	await _next_manual_step()
	_expect(
		high_enemy.is_dead
		and high_enemy.defeat_context != null
		and not high_enemy.defeat_context.is_player_reward_eligible()
		and high_enemy.defeat_context.source_snapshot.source_faction_id
		== CombatRelationService.HOSTILE_WAVE,
		"A wave-hostile Enemy kill must not be reinterpreted as player-owned reward credit."
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
	var target_enemies: Array[Enemy] = [low_enemy, high_enemy]
	for enemy in target_enemies:
		if enemy == null or not is_instance_valid(enemy) or enemy.is_dead:
			continue
		enemy.set_combat_faction_id(
			CombatRelationService.HOSTILE_WAVE,
			-1,
			true
		)
		enemy.current_health = 100
		enemy.last_damage_result = null
		enemy.defeat_context = null
		enemy.global_position = FAR_POSITION
	wall.global_position = wall_position
	await physics_frame


func _register_projectile(
	mode: int,
	projectile_id: int,
	lifetime: float,
	phase: int,
	profile: int = RapidFireService.Profile.AK,
	damage_source_snapshot: DamageSourceSnapshot = null
) -> int:
	var handle := service.register_projectile(
		mode as RapidFireService.Mode,
		profile as RapidFireService.Profile,
		Vector2.ZERO,
		Vector2.RIGHT,
		TEST_SPEED,
		lifetime,
		25,
		700,
		projectile_id,
		service.get_profile_world_check_interval(
			profile as RapidFireService.Profile
		),
		phase,
		damage_source_snapshot
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
