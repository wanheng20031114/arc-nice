extends SceneTree

const SERVICE_SCENE := preload(
	"res://scene/combat/simulation/capoo_mage_fireball_simulation_service.tscn"
)
const ServiceScript := preload(
	"res://scene/combat/simulation/capoo_mage_fireball_simulation_service.gd"
)
const COORDINATOR_SCENE := preload(
	"res://scene/combat/simulation/enemy_simulation_coordinator.tscn"
)
const PLAYER_SCENE := preload(
	"res://scene/player/weishidaier/player_weishidaier.tscn"
)

var failures: Array[String] = []
var fixture: Node2D = null
var runtime: PlayerTestCombatRuntime = null
var coordinator: EnemySimulationCoordinator = null
var service: ServiceScript = null


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	fixture = Node2D.new()
	fixture.name = "CapooMageFireballSimulationServiceSmokeTest"
	root.add_child(fixture)
	current_scene = fixture
	runtime = PlayerTestCombatRuntime.new()
	runtime.name = "Runtime"
	runtime.add_child(COORDINATOR_SCENE.instantiate())
	fixture.add_child(runtime)
	coordinator = runtime.get_enemy_simulation_coordinator()
	service = SERVICE_SCENE.instantiate() as ServiceScript
	runtime.add_child(service)
	service.process_mode = Node.PROCESS_MODE_DISABLED

	_expect(service.bind_context(runtime, coordinator), "Service must bind typed runtime context.")
	_test_reserve_handle_identity_and_replica_compensation()
	await _test_activation_world_direct_lifetime_and_stable_completion()
	await _test_homing_target_pause_resume_without_retarget()
	_test_teardown_and_metrics()

	coordinator.prepare_combat_services_for_runtime_teardown()
	current_scene = null
	fixture.queue_free()
	for _cleanup_frame in range(4):
		await process_frame
		await physics_frame
	if failures.is_empty():
		print("CAPOO_MAGE_FIREBALL_SIMULATION_SERVICE_SMOKE_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_reserve_handle_identity_and_replica_compensation() -> void:
	_expect(service.reserve(12), "Fixed record reserve must succeed.")
	var target := _spawn_plant_body(Vector2(0.0, 100.0))
	var original_snapshot := _make_snapshot(0, &"capoo_mage_fireball")
	var handle := service.spawn_authoritative(
		Vector2.ZERO,
		Vector2.RIGHT,
		31,
		10.0,
		4.0,
		ServiceScript.DEFAULT_RADIUS,
		target,
		ServiceScript.DEFAULT_HOMING_TURN_RATE,
		original_snapshot
	)
	_expect(
		handle != ServiceScript.INVALID_HANDLE
		and service.get_slot_mode(handle) == ServiceScript.Mode.DATA
		and service.get_slot_profile(handle) == ServiceScript.Profile.NORMAL
		and service.get_direction(handle) == Vector2.RIGHT
		and service.get_target(handle) == target
		and service.get_target_instance_id(handle) == target.get_instance_id()
		and service.assign_projectile_identity(handle, 101)
		and not service.assign_projectile_identity(handle, 102)
		and service.get_projectile_id(handle) == 101
		and service.get_damage_source_snapshot(handle).event_source_id == 101,
		"DATA handle getters and one-time identity binding must retain typed values."
	)
	var stale_handle := handle
	_expect(service.release(handle), "A live handle must release once.")
	var replica_handle := service.spawn_replica(
		201,
		Vector2(5.0, 200.0),
		Vector2.RIGHT,
		10.0,
		4.0,
		ServiceScript.DEFAULT_RADIUS,
		target,
		ServiceScript.DEFAULT_HOMING_TURN_RATE,
		1.25
	)
	_expect(
		replica_handle != ServiceScript.INVALID_HANDLE
		and replica_handle != stale_handle
		and not service.is_handle_live(stale_handle)
		and service.get_slot_mode(replica_handle) == ServiceScript.Mode.REPLICA
		and service.get_position(replica_handle).is_equal_approx(Vector2(17.5, 200.0))
		and is_equal_approx(service.get_remaining_lifetime(replica_handle), 2.75)
		and is_equal_approx(service.get_visual_age(replica_handle), 1.25)
		and service.get_direction(replica_handle) == Vector2.RIGHT,
		"REPLICA spawn must perform one linear late compensation without homing replay."
	)
	service.clear()
	target.queue_free()


func _test_activation_world_direct_lifetime_and_stable_completion() -> void:
	var wall := _spawn_world_body(Vector2(5.0, 0.0), 1.0)
	var world_path_plant := _spawn_plant_body(Vector2(10.0, 0.0))
	var direct_plant := _spawn_plant_body(Vector2(10.0, 40.0))
	var unknown_damageable_body := _spawn_unknown_damageable_body(
		Vector2(10.0, 160.0)
	)
	var dead_plant := _spawn_plant_body(Vector2(10.0, 200.0))
	dead_plant.is_dead = true
	var dead_player := _spawn_player_body(Vector2(10.0, 240.0))
	dead_player.is_dead = true
	await physics_frame

	var activation_handle := service.spawn_authoritative(
		Vector2(0.0, -60.0), Vector2.RIGHT, 1, 10.0, 4.0,
		ServiceScript.DEFAULT_RADIUS, null, 0.0, _make_snapshot(301)
	)
	service.advance(0.1)
	_expect(
		service.get_position(activation_handle).is_equal_approx(Vector2(0.0, -60.0)),
		"A fireball must remain pending in its registration physics frame."
	)
	await physics_frame
	service.advance(0.1)
	_expect(
		service.get_position(activation_handle).is_equal_approx(Vector2(1.0, -60.0)),
		"A fireball must activate on the next physics frame."
	)
	service.clear()

	var retained_snapshot := _make_snapshot(0, &"capoo_mage_fireball")
	var world_handle := service.spawn_authoritative(
		Vector2.ZERO, Vector2.RIGHT, 41, 10.0, 3.0,
		ServiceScript.DEFAULT_RADIUS, null, 0.0, retained_snapshot
	)
	_expect(service.assign_projectile_identity(world_handle, 401), "DATA identity must bind before activation.")
	var direct_handle := service.spawn_authoritative(
		Vector2(0.0, 40.0), Vector2.RIGHT, 42, 10.0, 3.0,
		ServiceScript.DEFAULT_RADIUS, null, 0.0, _make_snapshot(402)
	)
	service.assign_projectile_identity(direct_handle, 402)
	var lifetime_handle := service.spawn_authoritative(
		Vector2(0.0, 80.0), Vector2.RIGHT, 43, 10.0, 0.25,
		ServiceScript.DEFAULT_RADIUS, null, 0.0, _make_snapshot(403)
	)
	service.assign_projectile_identity(lifetime_handle, 403)
	var replica_target := _spawn_plant_body(Vector2(10.0, 120.0))
	var replica_handle := service.spawn_replica(
		404, Vector2(0.0, 120.0), Vector2.RIGHT, 10.0, 3.0,
		ServiceScript.DEFAULT_RADIUS, null, 0.0, 0.0
	)
	var unknown_body_handle := service.spawn_authoritative(
		Vector2(0.0, 160.0), Vector2.RIGHT, 44, 10.0, 3.0,
		ServiceScript.DEFAULT_RADIUS, null, 0.0, _make_snapshot(405)
	)
	service.assign_projectile_identity(unknown_body_handle, 405)
	var dead_plant_handle := service.spawn_authoritative(
		Vector2(0.0, 200.0), Vector2.RIGHT, 45, 10.0, 3.0,
		ServiceScript.DEFAULT_RADIUS, null, 0.0, _make_snapshot(406)
	)
	service.assign_projectile_identity(dead_plant_handle, 406)
	var dead_player_replica_handle := service.spawn_replica(
		407, Vector2(0.0, 240.0), Vector2.RIGHT, 10.0, 3.0,
		ServiceScript.DEFAULT_RADIUS, null, 0.0, 0.0
	)
	retained_snapshot.source_type = &"mutated_after_spawn"
	await physics_frame
	service.advance(1.0)

	_expect(
		service.get_completion_count() == 7
		and service.get_completion_reason(0) == ServiceScript.CompletionReason.WORLD
		and service.get_completion_reason(1) == ServiceScript.CompletionReason.DIRECT_HIT
		and service.get_completion_reason(2) == ServiceScript.CompletionReason.LIFETIME
		and service.get_completion_reason(3) == ServiceScript.CompletionReason.DIRECT_HIT
		and service.get_completion_reason(4) == ServiceScript.CompletionReason.DIRECT_HIT
		and service.get_completion_reason(5) == ServiceScript.CompletionReason.DIRECT_HIT
		and service.get_completion_reason(6) == ServiceScript.CompletionReason.DIRECT_HIT,
		"World, direct, lifetime, replica, unknown-body, and corpse contacts must preserve stable record order."
	)
	var source := service.get_completion_damage_source_snapshot(0)
	_expect(
		service.get_completion_handle(0) == world_handle
		and service.get_completion_projectile_id(0) == 401
		and service.get_completion_direction(0) == Vector2.RIGHT
		and service.get_completion_direct_hit(0) == null
		and service.get_completion_damage(0) == 41
		and service.get_completion_profile(0) == ServiceScript.Profile.NORMAL
		and source != null
		and source.source_type == &"capoo_mage_fireball"
		and source.event_source_id == 401,
		"World priority must retain the copied DATA snapshot and scalar payload."
	)
	_expect(
		service.get_completion_direct_hit(1) == direct_plant
		and service.get_completion_damage(1) == 42
		and service.get_completion_position(2).is_equal_approx(Vector2(10.0, 80.0))
		and service.get_completion_mode(3) == ServiceScript.Mode.REPLICA
		and service.get_completion_direct_hit(3) == replica_target
		and service.get_completion_damage(3) == 0
		and service.get_completion_direct_hit(4) == unknown_damageable_body
		and service.get_completion_damage(4) == 44
		and service.get_completion_direct_hit(5) == dead_plant
		and service.get_completion_damage(5) == 45
		and service.get_completion_mode(6) == ServiceScript.Mode.REPLICA
		and service.get_completion_direct_hit(6) == dead_player
		and service.get_completion_damage(6) == 0,
		"Endpoint contact must preserve legacy-compatible unknown and corpse detonation while REPLICA remains damage-free."
	)
	_expect(
		not service.is_handle_live(world_handle)
		and not service.is_handle_live(direct_handle)
		and not service.is_handle_live(lifetime_handle)
		and not service.is_handle_live(replica_handle)
		and not service.is_handle_live(unknown_body_handle)
		and not service.is_handle_live(dead_plant_handle)
		and not service.is_handle_live(dead_player_replica_handle)
		and service.get_dense_record_count() == 0,
		"Frame-end compaction must retire every completed handle."
	)
	var drained: Array[Dictionary] = []
	_expect(
		service.drain_completions(drained) == 7
		and drained.size() == 7
		and int(drained[3]["damage"]) == 0,
		"Completion drain must expose the stable terminal payload without replica damage."
	)
	var friendly_handle := service.spawn_authoritative(
		Vector2(0.0, 40.0),
		Vector2.RIGHT,
		45,
		10.0,
		3.0,
		ServiceScript.DEFAULT_RADIUS,
		null,
		0.0,
		DamageSourceSnapshot.create(
			CombatRelationService.PLAYER_ALLIED,
			0,
			77,
			406,
			&"capoo_mage_fireball"
		)
	)
	await physics_frame
	service.advance(1.0)
	_expect(
		service.is_handle_live(friendly_handle)
		and service.get_completion_count() == 0
		and service.get_position(friendly_handle).is_equal_approx(
			Vector2(10.0, 40.0)
		),
		"A same-faction typed body must not detonate an authoritative fireball."
	)
	service.release(friendly_handle)
	wall.queue_free()
	world_path_plant.queue_free()
	direct_plant.queue_free()
	replica_target.queue_free()
	unknown_damageable_body.queue_free()
	dead_plant.queue_free()
	dead_player.queue_free()
	service.clear()
	await physics_frame


func _test_homing_target_pause_resume_without_retarget() -> void:
	var target := _spawn_plant_body(Vector2(0.0, 260.0))
	await physics_frame
	var handle := service.spawn_authoritative(
		Vector2(0.0, 200.0), Vector2.RIGHT, 1, 1.0, 5.0,
		ServiceScript.DEFAULT_RADIUS, target, 0.5, _make_snapshot(501)
	)
	service.assign_projectile_identity(handle, 501)
	await physics_frame
	service.advance(0.5)
	var homed_direction := service.get_direction(handle)
	_expect(
		homed_direction.y > 0.0
		and is_equal_approx(homed_direction.angle(), 0.25)
		and service.get_target(handle) == target,
		"Live targets must rotate direction by at most turn_rate times delta."
	)
	target.is_dead = true
	service.advance(0.5)
	_expect(
		service.get_target(handle) == null
		and service.get_target_instance_id(handle) == target.get_instance_id()
		and service.get_direction(handle).is_equal_approx(homed_direction),
		"A dead target must pause homing and continue straight without retargeting."
	)
	target.is_dead = false
	service.advance(0.5)
	_expect(
		service.get_target(handle) == target
		and not service.get_direction(handle).is_equal_approx(homed_direction),
		"A revived original target must resume the legacy homing relationship."
	)
	service.release(handle)
	target.queue_free()
	service.clear()
	await physics_frame


func _test_teardown_and_metrics() -> void:
	var metrics := service.get_metrics()
	_expect(
		int(metrics["spawns"]) >= 8
		and int(metrics["activation_skips"]) >= 1
		and int(metrics["world_completions"]) == 1
		and int(metrics["direct_completions"]) == 5
		and int(metrics["lifetime_completions"]) == 1
		and int(metrics["homing_updates"]) >= 1
		and int(metrics["homing_targets_lost"]) >= 1,
		"Metrics must expose activation, contact, lifetime, and homing work."
	)
	service.teardown()
	_expect(
		not service.is_bound()
		and bool(service.get_metrics()["teardown_prepared"])
		and not service.reserve(13)
		and service.spawn_authoritative(
			Vector2.ZERO, Vector2.RIGHT, 1, 1.0, 1.0,
			ServiceScript.DEFAULT_RADIUS, null, 0.0, _make_snapshot(601)
		) == ServiceScript.INVALID_HANDLE,
		"Teardown must clear retained objects and permanently reject new records."
	)
	service.teardown()


func _spawn_world_body(position: Vector2, radius: float) -> StaticBody2D:
	var body := StaticBody2D.new()
	body.position = position
	body.collision_layer = 1
	body.collision_mask = 0
	var shape_node := CollisionShape2D.new()
	var shape := CircleShape2D.new()
	shape.radius = radius
	shape_node.shape = shape
	body.add_child(shape_node)
	runtime.add_child(body)
	return body


func _spawn_plant_body(position: Vector2) -> PlantDefense:
	var plant := PlantDefense.new()
	plant.position = position
	plant.collision_layer = 4
	plant.collision_mask = 0
	plant.max_health = 1_000_000
	plant.current_health = 1_000_000
	var shape_node := CollisionShape2D.new()
	var shape := CircleShape2D.new()
	shape.radius = 1.5
	shape_node.shape = shape
	plant.add_child(shape_node)
	runtime.add_child(plant)
	return plant


func _spawn_unknown_damageable_body(position: Vector2) -> StaticBody2D:
	var body := StaticBody2D.new()
	body.position = position
	body.collision_layer = 2
	body.collision_mask = 0
	var shape_node := CollisionShape2D.new()
	var shape := CircleShape2D.new()
	shape.radius = 1.5
	shape_node.shape = shape
	body.add_child(shape_node)
	runtime.add_child(body)
	return body


func _spawn_player_body(position: Vector2) -> Player:
	var player := PLAYER_SCENE.instantiate() as Player
	player.position = position
	player.collision_layer = 2
	player.collision_mask = 0
	runtime.add_child(player)
	runtime.bind_player_runtime_context(player)
	player.set_process(false)
	player.set_physics_process(false)
	return player


func _make_snapshot(
	event_id: int,
	source_type: StringName = &"capoo_mage_fireball"
) -> DamageSourceSnapshot:
	return DamageSourceSnapshot.create(
		CombatRelationService.HOSTILE_WAVE,
		0,
		77,
		event_id,
		source_type
	)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
