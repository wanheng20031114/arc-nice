extends SceneTree

const SERVICE_SCENE := preload(
	"res://scene/combat/simulation/capoo_rpg_rocket_simulation_service.tscn"
)
const ServiceScript := preload(
	"res://scene/combat/simulation/capoo_rpg_rocket_simulation_service.gd"
)
const COORDINATOR_SCENE := preload(
	"res://scene/combat/simulation/enemy_simulation_coordinator.tscn"
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
	fixture.name = "CapooRPGRocketSimulationServiceSmokeTest"
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
	_test_fixed_reserve_and_handle_generations()
	await _test_activation_collision_order_and_compaction()
	await _test_client_view_has_no_damage_side_effect()
	_test_clear_teardown_and_metrics()

	coordinator.prepare_combat_services_for_runtime_teardown()
	current_scene = null
	fixture.queue_free()
	for _cleanup_frame in range(4):
		await process_frame
		await physics_frame

	if failures.is_empty():
		print("CAPOO_RPG_ROCKET_SIMULATION_SERVICE_SMOKE_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_fixed_reserve_and_handle_generations() -> void:
	_expect(service.reserve(6), "Explicit six-record reserve must succeed.")
	var snapshot := _make_snapshot(100)
	var handles := PackedInt64Array()
	for projectile_index in range(6):
		handles.append(service.spawn_authoritative(
			100 + projectile_index,
			Vector2(0.0, 200.0 + projectile_index * 12.0),
			Vector2.RIGHT,
			20,
			0.0,
			3.0,
			44.0,
			snapshot
		))
	_expect(
		handles.size() == 6
		and handles[0] != ServiceScript.INVALID_HANDLE
		and service.get_live_count() == 6
		and service.get_reserved_capacity() == 6,
		"Reserved storage must admit exactly six live scalar records."
	)
	_expect(
		service.spawn_authoritative(
			999,
			Vector2.ZERO,
			Vector2.RIGHT,
			20,
			1.0,
			1.0,
			44.0,
			snapshot
		) == ServiceScript.INVALID_HANDLE,
		"A seventh rocket must be rejected without implicit storage growth."
	)
	var stale_handle := int(handles[0])
	service.clear()
	var replacement_handle := service.spawn_authoritative(
		0,
		Vector2(0.0, 180.0),
		Vector2.RIGHT,
		20,
		0.0,
		3.0,
		44.0,
		_make_snapshot(200)
	)
	_expect(
		not service.is_handle_live(stale_handle)
		and service.is_handle_live(replacement_handle)
		and replacement_handle != stale_handle
		and service.assign_projectile_identity(replacement_handle, 200)
		and not service.assign_projectile_identity(replacement_handle, 201)
		and service.get_projectile_id(replacement_handle) == 200
		and service.get_damage_source_snapshot(replacement_handle).event_source_id == 200,
		"Slot reuse must invalidate stale generations and permit one identity bind."
	)
	_expect(
		service.release(replacement_handle)
		and not service.release(replacement_handle)
		and service.get_completion_count() == 0
		and service.get_dense_record_count() == 0,
		"Release must compact immediately without producing a completion."
	)
	service.clear()


func _test_activation_collision_order_and_compaction() -> void:
	var wall := _spawn_world_body(Vector2(8.0, 0.0), 1, 1.0)
	var world_path_plant := _spawn_plant_body(Vector2(2.0, 0.0))
	var direct_plant := _spawn_plant_body(Vector2(5.0, 20.0))
	var initial_side_plant := _spawn_plant_body(Vector2(0.0, 103.0))
	await physics_frame

	var activation_snapshot := _make_snapshot(300)
	var activation_handle := service.spawn_authoritative(
		300,
		Vector2(0.0, 60.0),
		Vector2.RIGHT,
		20,
		10.0,
		5.0,
		44.0,
		activation_snapshot
	)
	service.advance(0.1)
	_expect(
		service.get_position(activation_handle).is_equal_approx(Vector2(0.0, 60.0)),
		"A newly spawned rocket must not move in its registration physics frame."
	)
	await physics_frame
	service.advance(0.1)
	_expect(
		service.get_position(activation_handle).is_equal_approx(Vector2(1.0, 60.0)),
		"The rocket must activate and move on the following physics frame."
	)
	service.clear()

	var original_snapshot := _make_snapshot(401)
	var world_handle := service.spawn_authoritative(
		0, Vector2.ZERO, Vector2.RIGHT, 21, 10.0, 2.0, 45.0, original_snapshot
	)
	_expect(
		service.assign_projectile_identity(world_handle, 401),
		"Pending data rockets must accept their authoritative projectile identity."
	)
	var direct_handle := service.spawn_authoritative(
		402, Vector2(0.0, 20.0), Vector2.RIGHT, 22, 10.0, 2.0, 46.0,
		_make_snapshot(402)
	)
	service.spawn_authoritative(
		403, Vector2(0.0, 40.0), Vector2.RIGHT, 23, 10.0, 0.25, 47.0,
		_make_snapshot(403)
	)
	var survivor_handle := service.spawn_authoritative(
		404, Vector2(0.0, 60.0), Vector2.RIGHT, 24, 1.0, 5.0, 48.0,
		_make_snapshot(404)
	)
	service.spawn_authoritative(
		405, Vector2(0.0, 100.0), Vector2.RIGHT, 25, 0.0, 2.0, 49.0,
		_make_snapshot(405)
	)
	original_snapshot.source_type = &"mutated_after_spawn"
	await physics_frame
	service.advance(1.0)

	_expect(
		service.get_completion_count() == 4
		and service.get_completion_reason(0) == ServiceScript.CompletionReason.WORLD
		and service.get_completion_reason(1) == ServiceScript.CompletionReason.DIRECT_HIT
		and service.get_completion_reason(2) == ServiceScript.CompletionReason.LIFETIME
		and service.get_completion_reason(3) == ServiceScript.CompletionReason.DIRECT_HIT,
		"Production completion getters must preserve stable terminal order."
	)
	var getter_snapshot := service.get_completion_damage_source_snapshot(0)
	_expect(
		service.get_completion_handle(0) == world_handle
		and service.get_completion_projectile_id(0) == 401
		and service.get_completion_direction(0) == Vector2.RIGHT
		and service.get_completion_direct_hit(0) == null
		and service.get_completion_damage(0) == 21
		and is_equal_approx(service.get_completion_radius(0), 45.0)
		and getter_snapshot != null
		and getter_snapshot.event_source_id == 401,
		"Scalar completion getters must expose the full terminal payload."
	)
	_expect(
		not service.is_handle_live(world_handle)
		and not service.is_handle_live(direct_handle)
		and service.is_handle_live(survivor_handle)
		and service.get_dense_record_count() == 1
		and service.get_handle_at_stable_index(0) == survivor_handle
		and service.get_position_at_stable_index(0).is_equal_approx(Vector2(1.0, 60.0))
		and service.get_direction_at_stable_index(0) == Vector2.RIGHT
		and is_equal_approx(service.get_visual_age_at_stable_index(0), 1.0),
		"Frame-end stable compaction must preserve the surviving handle and row."
	)
	var capacity_guard_handle := service.spawn_authoritative(
		406, Vector2(0.0, 140.0), Vector2.RIGHT, 1, 0.0, 2.0, 1.0,
		_make_snapshot(406)
	)
	_expect(
		capacity_guard_handle != ServiceScript.INVALID_HANDLE
		and service.spawn_authoritative(
			407, Vector2(0.0, 160.0), Vector2.RIGHT, 1, 0.0, 2.0, 1.0,
			_make_snapshot(407)
		) == ServiceScript.INVALID_HANDLE,
		"Live records plus undrained completions must never exceed completion reserve."
	)
	var completions: Array[Dictionary] = []
	_expect(
		service.drain_completions(completions) == 4
		and completions.size() == 4,
		"The test-only drain adapter must consume all scalar completion records."
	)
	if completions.size() == 4:
		var world_record := completions[0]
		var direct_record := completions[1]
		var lifetime_record := completions[2]
		var completion_snapshot := (
			world_record["damage_source_snapshot"] as DamageSourceSnapshot
		)
		_expect(
			int(world_record["projectile_id"]) == 401
			and int(world_record["reason"])
				== ServiceScript.CompletionReason.WORLD
			and world_record["direct_hit"] == null
			and int(world_record["damage"]) == 21
			and is_equal_approx(float(world_record["radius"]), 45.0)
			and completion_snapshot != null
			and completion_snapshot.source_type == &"capoo_rpg_rocket"
			and completion_snapshot.event_source_id == 401,
			"World must win before a nearer damageable and retain copied payload values."
		)
		_expect(
			int(direct_record["projectile_id"]) == 402
			and int(direct_record["reason"])
				== ServiceScript.CompletionReason.DIRECT_HIT
			and direct_record["direct_hit"] == direct_plant,
			"Direct damageable contact must terminate after the world sweep misses."
		)
		_expect(
			int(lifetime_record["projectile_id"]) == 403
			and int(lifetime_record["reason"])
				== ServiceScript.CompletionReason.LIFETIME
			and (lifetime_record["position"] as Vector2).is_equal_approx(
				Vector2(10.0, 40.0)
			),
			"Lifetime must lose to contacts, then complete at the moved endpoint."
		)
		_expect(
			int(completions[3]["projectile_id"]) == 405
			and completions[3]["direct_hit"] == initial_side_plant,
			"Endpoint capsule overlap must include initial and lateral contacts."
		)
	wall.queue_free()
	world_path_plant.queue_free()
	direct_plant.queue_free()
	initial_side_plant.queue_free()
	service.clear()
	await physics_frame


func _test_client_view_has_no_damage_side_effect() -> void:
	runtime.runtime_mode = CombatRuntimeBase.RuntimeMode.CLIENT_VIEW
	var plant := _spawn_plant_body(Vector2(5.0, 80.0))
	plant.max_health = 100
	plant.current_health = 100
	await physics_frame
	service.spawn_authoritative(
		501,
		Vector2(0.0, 80.0),
		Vector2.RIGHT,
		99,
		10.0,
		2.0,
		44.0,
		_make_snapshot(501)
	)
	await physics_frame
	service.advance(1.0)
	var completions: Array[Dictionary] = []
	service.drain_completions(completions)
	_expect(
		completions.size() == 1
		and int(completions[0]["reason"])
			== ServiceScript.CompletionReason.DIRECT_HIT
		and plant.current_health == 100,
		"CLIENT_VIEW may simulate contact but must never apply authoritative damage."
	)
	plant.queue_free()
	service.clear()
	runtime.runtime_mode = CombatRuntimeBase.RuntimeMode.SINGLEPLAYER
	await physics_frame


func _test_clear_teardown_and_metrics() -> void:
	var metrics := service.get_metrics()
	_expect(
		int(metrics["spawns"]) >= 12
		and int(metrics["spawn_rejections"]) >= 1
		and int(metrics["releases"]) == 1
		and int(metrics["activation_skips"]) >= 1
		and int(metrics["world_completions"]) == 1
		and int(metrics["direct_completions"]) == 3
		and int(metrics["lifetime_completions"]) == 1
		and int(metrics["compacted_tombstones"]) == 6
		and int(metrics["drained_completions"]) == 5,
		"Metrics must expose capacity, activation, terminal and compaction work."
	)
	service.teardown()
	_expect(
		not service.is_bound()
		and bool(service.get_metrics()["teardown_prepared"])
		and not service.reserve(7)
		and service.spawn_authoritative(
			600, Vector2.ZERO, Vector2.RIGHT, 1, 1.0, 1.0, 1.0,
			_make_snapshot(600)
		) == ServiceScript.INVALID_HANDLE,
		"Teardown must be idempotent and permanently reject new storage or records."
	)
	service.teardown()


func _spawn_world_body(position: Vector2, layer: int, radius: float) -> StaticBody2D:
	var body := StaticBody2D.new()
	body.position = position
	body.collision_layer = layer
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


func _make_snapshot(event_id: int) -> DamageSourceSnapshot:
	return DamageSourceSnapshot.create(
		CombatRelationService.HOSTILE_WAVE,
		0,
		77,
		event_id,
		&"capoo_rpg_rocket"
	)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
