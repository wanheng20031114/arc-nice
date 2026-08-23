extends SceneTree

const ExplosionResolutionServiceScript := preload(
	"res://scene/combat/simulation/explosion_resolution_service.gd"
)
const SERVICE_SCENE := preload(
	"res://scene/combat/simulation/explosion_resolution_service.tscn"
)
const RUNTIME_SCENE := preload(
	"res://dev_tools/fixtures/enemy_gameplay_gateway_test_runtime.tscn"
)
const TEST_SESSION_SCRIPT := preload(
	"res://dev_tools/fixtures/enemy_gameplay_gateway_test_session.gd"
)
const PLAYER_SCENE := preload(
	"res://scene/player/weishidaier/player_weishidaier.tscn"
)
const SMG_SCENE := preload("res://scene/enemy/capoo/capoo_smg.tscn")
const SMG_CONFIG := preload("res://resources/config/enemies/capoo_smg.tres")

const DAMAGEABLE_MASK := 512
const PLAYER_MASK := 2

var failures: Array[String] = []
var runtime: EnemyGameplayGatewayTestRuntime = null
var service: ExplosionResolutionServiceScript = null
var damageable_index: EnemyDamageableSpatialIndex = null
var source_serial := 70000


class RejectOncePlant:
	extends PlantDefense

	var application_attempt_count := 0


	func apply_combat_damage(request: DamageRequest) -> DamageResult:
		application_attempt_count += 1
		if application_attempt_count == 1:
			return DamageResult.rejected(
				request,
				CombatTypes.DamageRejectionReason.TARGET_UNAVAILABLE,
				current_health
			)
		return super.apply_combat_damage(request)


class RecordingTypedSession:
	extends TEST_SESSION_SCRIPT

	var typed_request_count := 0
	var last_typed_snapshot: DamageSourceSnapshot = null


	func request_multiplayer_player_damage_with_source_snapshot(
		source_snapshot: DamageSourceSnapshot,
		target_peer_id: int,
		damage: int,
		damage_type: EnemyConfig.DamageType = EnemyConfig.DamageType.PHYSICAL,
		source_direction: Vector2 = Vector2.ZERO,
		is_ranged: bool = false,
		contact_preconsumed: bool = false
	) -> bool:
		typed_request_count += 1
		last_typed_snapshot = source_snapshot.duplicate_snapshot()
		return super.request_multiplayer_player_damage_with_source_snapshot(
			source_snapshot,
			target_peer_id,
			damage,
			damage_type,
			source_direction,
			is_ranged,
			contact_preconsumed
		)


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	_build_fixture()
	await process_frame
	await physics_frame
	if service != null and damageable_index != null:
		_test_authored_binding_and_direct_hit_first()
		await _test_player_collision_boundary_overlap()
		await _test_indexed_aabb_with_exact_circle_posterior()
		await _test_indexed_accepted_only_retry()
		await _test_geometry_cache_revalidates_lifecycle_and_identity()
		await _test_enemy_sink_and_faction_admission()
		await _test_host_player_uses_gateway()
		await _test_three_hundred_plants_avoid_native_query()
		_test_client_and_teardown_rejection()
	await _finish()


func _build_fixture() -> void:
	runtime = RUNTIME_SCENE.instantiate() as EnemyGameplayGatewayTestRuntime
	_expect(runtime != null, "Runtime fixture must instantiate.")
	if runtime == null:
		return
	runtime.name = "ExplosionResolutionServiceSmokeTest"
	root.add_child(runtime)
	current_scene = runtime
	var coordinator := runtime.get_enemy_simulation_coordinator()
	var combat_services := runtime.get_enemy_combat_services()
	_expect(coordinator != null, "Runtime must author the simulation coordinator.")
	_expect(combat_services != null, "Runtime must expose bound combat services.")
	if coordinator == null or combat_services == null:
		return
	coordinator.process_mode = Node.PROCESS_MODE_DISABLED
	damageable_index = combat_services.get_enemy_damageable_spatial_index()
	service = SERVICE_SCENE.instantiate() as ExplosionResolutionServiceScript
	_expect(service != null, "Explosion service scene must author its typed node.")
	if service == null:
		return
	combat_services.add_child(service)
	_expect(
		service.get_parent() == combat_services
		and service.bind_context(runtime, coordinator)
		and service.is_bound_to(runtime, coordinator),
		"Explosion service must bind to the authored runtime/coordinator/index context."
	)


func _test_authored_binding_and_direct_hit_first() -> void:
	runtime.runtime_mode = CombatRuntimeBase.RuntimeMode.SINGLEPLAYER
	var player := PLAYER_SCENE.instantiate() as Player
	runtime.add_child(player)
	player.global_position = Vector2(400.0, 0.0)
	player.collision_layer = PLAYER_MASK
	player.peer_id = 7
	player.bind_combat_runtime(runtime)
	player.set_physics_process(false)
	var health_before := player.current_health
	var physics_frame_before := Engine.get_physics_frames()
	var accepted := service.resolve_hostile_explosion(
		Vector2.ZERO,
		1.0,
		17,
		player,
		_hostile_snapshot(&"direct_outside_radius"),
		51,
		source_serial,
		&"direct_outside_radius",
		EnemyConfig.DamageType.PHYSICAL
	)
	_expect(
		accepted == 1
		and player.current_health < health_before
		and Engine.get_physics_frames() == physics_frame_before,
		"Direct hit must resolve first and synchronously even outside the AoE circle."
	)
	var metrics := service.get_metrics()
	_expect(
		int(metrics["direct_attempt_count"]) == 1
		and int(metrics["direct_accept_count"]) == 1
		and int(metrics["active_resolution_count"]) == 0,
		"Direct-hit and synchronous-active metrics must be deterministic."
	)
	player.queue_free()


func _test_player_collision_boundary_overlap() -> void:
	var player := PLAYER_SCENE.instantiate() as Player
	runtime.add_child(player)
	player.collision_layer = PLAYER_MASK
	player.peer_id = 8
	player.bind_combat_runtime(runtime)
	player.set_physics_process(false)
	await process_frame
	var player_circle := player.collision_shape.shape as CircleShape2D
	var explosion_radius := 10.0
	player.global_position = Vector2(
		explosion_radius + player_circle.radius - 0.01,
		100.0 - player.collision_shape.position.y
	)
	runtime.player = player
	var health_before := player.current_health
	var metrics_before := service.get_metrics()
	var accepted := service.resolve_hostile_explosion(
		Vector2(0.0, 100.0),
		explosion_radius,
		13,
		null,
		_hostile_snapshot(&"player_boundary_overlap"),
		59,
		source_serial,
		&"player_boundary_overlap",
		EnemyConfig.DamageType.PHYSICAL
	)
	var metrics_after := service.get_metrics()
	_expect(
		accepted == 1 and player.current_health < health_before,
		"A player collision shape intersecting the explosion boundary must be hit even when its origin is outside."
	)
	_expect(
		int(metrics_after["player_broad_query_count"])
			== int(metrics_before["player_broad_query_count"]) + 1
		and int(metrics_after["player_candidate_count"])
			== int(metrics_before["player_candidate_count"]) + 1
		and int(metrics_after["player_exact_overlap_count"])
			== int(metrics_before["player_exact_overlap_count"]) + 1,
		"Player metrics must expose reusable traversal and exact collision-shape overlap."
	)
	runtime.player = null
	player.queue_free()
	await physics_frame


func _test_indexed_aabb_with_exact_circle_posterior() -> void:
	var false_positive := _create_plant(
		"IndexedFalsePositive",
		Vector2(100.0, 205.5),
		4.0
	)
	var true_overlap := _create_plant(
		"IndexedTrueOverlap",
		Vector2(100.0, 200.0),
		4.0
	)
	_expect(
		damageable_index.register_damageable(false_positive)
		and damageable_index.register_damageable(true_overlap),
		"Indexed smoke plants must register complete root shapes."
	)
	await physics_frame
	var false_health := false_positive.current_health
	var true_health := true_overlap.current_health
	var metrics_before := service.get_metrics()
	var accepted := service.resolve_hostile_explosion(
		Vector2(0.0, 200.0),
		96.1,
		21,
		null,
		_hostile_snapshot(&"indexed_exact_circle"),
		52,
		source_serial,
		&"indexed_exact_circle",
		EnemyConfig.DamageType.MAGIC
	)
	var metrics_after := service.get_metrics()
	_expect(
		accepted == 1
		and false_positive.current_health == false_health
		and true_overlap.current_health < true_health,
		"AABB candidates must receive a CircleShape exact posterior before damage."
	)
	_expect(
		int(metrics_after["indexed_candidate_count"])
			>= int(metrics_before["indexed_candidate_count"]) + 2
		and int(metrics_after["indexed_exact_test_count"])
			>= int(metrics_before["indexed_exact_test_count"]) + 2
		and int(metrics_after["indexed_exact_overlap_count"])
			== int(metrics_before["indexed_exact_overlap_count"]) + 1,
		"Indexed metrics must distinguish broad candidates from exact overlaps."
	)
	var request := true_overlap.last_damage_result.request
	_expect(
		request != null
		and request.source == null
		and request.source_enemy_id == 52
		and request.source_projectile_id == source_serial
		and request.source_snapshot_is_explicit
		and request.damage_type == EnemyConfig.DamageType.MAGIC,
		"Accepted explosion requests must use stable value identity without a fake source Node."
	)
	damageable_index.unregister_damageable(false_positive)
	damageable_index.unregister_damageable(true_overlap)
	false_positive.queue_free()
	true_overlap.queue_free()
	await physics_frame


func _test_indexed_accepted_only_retry() -> void:
	var retry_plant := RejectOncePlant.new()
	_configure_plant(retry_plant, "AcceptedOnlyRetryPlant", Vector2(0.0, 400.0), 6.0)
	_expect(
		damageable_index.register_damageable(retry_plant),
		"Accepted-only retry plant must be indexed for radial discovery."
	)
	await physics_frame
	var retry_health := retry_plant.current_health
	var metrics_before := service.get_metrics()
	var accepted := service.resolve_hostile_explosion(
		Vector2(0.0, 400.0),
		24.0,
		23,
		retry_plant,
		_hostile_snapshot(&"accepted_only_retry"),
		54,
		source_serial,
		&"accepted_only_retry",
		EnemyConfig.DamageType.PHYSICAL
	)
	var metrics_after := service.get_metrics()
	_expect(
		accepted == 1
		and retry_plant.application_attempt_count == 2
		and retry_plant.current_health < retry_health,
		"A rejected direct attempt must stay outside the ledger so the indexed overlap can accept it."
	)
	_expect(
		int(metrics_after["sink_rejection_count"])
			== int(metrics_before["sink_rejection_count"]) + 1,
		"Accepted-only ledger behavior must expose the rejected first sink attempt."
	)
	damageable_index.unregister_damageable(retry_plant)
	retry_plant.queue_free()
	await physics_frame


func _test_geometry_cache_revalidates_lifecycle_and_identity() -> void:
	var plant := _create_plant(
		"CachedGeometryLifecyclePlant",
		Vector2(0.0, 460.0),
		5.0
	)
	_expect(
		damageable_index.register_damageable(plant),
		"Geometry cache plant must register in the authoritative index."
	)
	await physics_frame
	plant.is_removing = true
	var metrics_before := service.get_metrics()
	var rejected := service.resolve_hostile_explosion(
		Vector2(0.0, 460.0), 20.0, 7, null,
		_hostile_snapshot(&"cached_removing_rejection"),
		64, source_serial, &"cached_removing_rejection",
		EnemyConfig.DamageType.PHYSICAL
	)
	plant.is_removing = false
	var first_accepted := service.resolve_hostile_explosion(
		Vector2(0.0, 460.0), 20.0, 7, null,
		_hostile_snapshot(&"cached_restored_accept"),
		64, source_serial, &"cached_restored_accept",
		EnemyConfig.DamageType.PHYSICAL
	)
	var retained_result := plant.last_damage_result
	var retained_projectile_id := retained_result.request.source_projectile_id
	var second_accepted := service.resolve_hostile_explosion(
		Vector2(0.0, 460.0), 20.0, 7, null,
		_hostile_snapshot(&"cached_second_accept"),
		64, source_serial, &"cached_second_accept",
		EnemyConfig.DamageType.PHYSICAL
	)
	var metrics_cached := service.get_metrics()
	_expect(
		rejected == 0
		and first_accepted == 1
		and second_accepted == 1
		and int(metrics_cached["plant_query_cache_hits"])
			>= int(metrics_before["plant_query_cache_hits"]) + 2,
		"Cached geometry must revalidate removing/alive state for every explosion."
	)
	_expect(
		retained_result.request.source_projectile_id == retained_projectile_id
		and retained_result.request.source_type == &"cached_restored_accept",
		"Later cached explosions must not mutate a retained DamageResult request."
	)
	plant.global_position = Vector2(100.0, 460.0)
	_expect(
		damageable_index.update_damageable(plant),
		"Moving cached geometry must advance the index revision."
	)
	var accepted_after_move := service.resolve_hostile_explosion(
		Vector2(0.0, 460.0), 20.0, 7, null,
		_hostile_snapshot(&"cache_revision_invalidation"),
		64, source_serial, &"cache_revision_invalidation",
		EnemyConfig.DamageType.PHYSICAL
	)
	var metrics_after_move := service.get_metrics()
	_expect(
		accepted_after_move == 0
		and int(metrics_after_move["plant_query_cache_misses"])
			== int(metrics_cached["plant_query_cache_misses"]) + 1,
		"Index geometry revision must invalidate cached broad/exact overlap results."
	)
	damageable_index.unregister_damageable(plant)
	plant.queue_free()
	await physics_frame


func _test_enemy_sink_and_faction_admission() -> void:
	var enemy := SMG_SCENE.instantiate() as CapooSMG
	runtime.get_node("EnemyContainer").add_child(enemy)
	enemy.global_position = Vector2(0.0, 500.0)
	enemy.setup(SMG_CONFIG, null, null, runtime)
	enemy.set_physics_process(false)
	await physics_frame
	var hostile_health := enemy.current_health
	var rejected := service.resolve_hostile_explosion(
		enemy.global_position,
		20.0,
		25,
		enemy,
		_hostile_snapshot(&"friendly_faction_rejection"),
		55,
		source_serial,
		&"friendly_faction_rejection",
		EnemyConfig.DamageType.PHYSICAL
	)
	_expect(
		rejected == 0 and enemy.current_health == hostile_health,
		"Faction admission must reject a hostile-wave source hitting a hostile-wave Enemy."
	)
	var previous_net_id := enemy.combat_target_index_net_id
	if previous_net_id > 0:
		runtime.unregister_combat_target(previous_net_id)
	enemy.set_combat_faction_id(CombatRelationService.PLAYER_ALLIED, -1, true)
	var indexed_net_id := 9055
	runtime.register_combat_target(indexed_net_id, enemy)
	var metrics_before := service.get_metrics()
	var accepted := service.resolve_hostile_explosion(
		enemy.global_position,
		20.0,
		25,
		null,
		_hostile_snapshot(&"enemy_sink"),
		55,
		source_serial,
		&"enemy_sink",
		EnemyConfig.DamageType.PHYSICAL
	)
	_expect(
		accepted == 1 and enemy.current_health < hostile_health,
		"An admitted indexed Enemy sink must receive one exact-shape explosion hit."
	)
	var metrics_after := service.get_metrics()
	_expect(
		int(metrics_after["enemy_broad_query_count"])
			== int(metrics_before["enemy_broad_query_count"]) + 1
		and int(metrics_after["enemy_exact_test_count"])
			== int(metrics_before["enemy_exact_test_count"]) + 1
		and int(metrics_after["enemy_exact_overlap_count"])
			== int(metrics_before["enemy_exact_overlap_count"]) + 1,
		"Enemy radial damage must use CombatTargetIndex broad phase plus exact body geometry."
	)
	runtime.unregister_combat_target(indexed_net_id)
	enemy.queue_free()
	await physics_frame


func _test_host_player_uses_gateway() -> void:
	runtime.runtime_mode = CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY
	var session := RecordingTypedSession.new()
	runtime.attach_gameplay_session(session)
	var player := PLAYER_SCENE.instantiate() as Player
	runtime.add_child(player)
	player.global_position = Vector2(0.0, 600.0)
	player.collision_layer = PLAYER_MASK
	player.peer_id = 77
	player.bind_combat_runtime(runtime)
	player.set_physics_process(false)
	runtime.player = player
	await physics_frame
	var health_before := player.current_health
	var projectile_id := source_serial
	var accepted := service.resolve_hostile_explosion(
		player.global_position,
		20.0,
		27,
		player,
		_hostile_snapshot(&"host_gateway_explosion"),
		56,
		projectile_id,
		&"host_gateway_explosion",
		EnemyConfig.DamageType.MAGIC
	)
	_expect(
		accepted == 1
		and player.current_health == health_before
		and session.typed_request_count == 1
		and session.player_damage_requests.size() == 1
		and session.last_typed_snapshot != null
		and session.last_typed_snapshot.event_source_id == projectile_id
		and session.last_typed_snapshot.source_faction_id
			== CombatRelationService.HOSTILE_WAVE,
		"HOST player damage must use the typed frozen-snapshot gateway without mutating the local proxy."
	)
	session.accept_player_damage_requests = false
	var rejected := service.resolve_hostile_explosion(
		player.global_position,
		20.0,
		27,
		player,
		_hostile_snapshot(&"host_gateway_rejection"),
		56,
		source_serial,
		&"host_gateway_rejection",
		EnemyConfig.DamageType.PHYSICAL
	)
	_expect(
		rejected == 0 and session.typed_request_count == 3,
		"A rejected direct gateway request must remain retryable by the player-shape overlap and report no accepted hit."
	)
	runtime.detach_gameplay_session(session)
	runtime.player = null
	player.queue_free()
	session.free()
	await physics_frame


func _test_three_hundred_plants_avoid_native_query() -> void:
	runtime.runtime_mode = CombatRuntimeBase.RuntimeMode.SINGLEPLAYER
	var plants: Array[PlantDefense] = []
	for index in range(300):
		var plant := _create_plant(
			"IndexedPlant%03d" % index,
			Vector2(
				1000.0 + float(index % 20) * 24.0,
				1000.0 + float(index / 20) * 24.0
			),
			4.0
		)
		plants.append(plant)
		_expect(
			damageable_index.register_damageable(plant),
			"Every load fixture plant must register in the damageable spatial index."
		)
	await physics_frame
	var metrics_before := service.get_metrics()
	var accepted := service.resolve_hostile_explosion(
		Vector2(1000.0, 1000.0),
		8.0,
		11,
		null,
		_hostile_snapshot(&"indexed_300_plant_query"),
		60,
		source_serial,
		&"indexed_300_plant_query",
		EnemyConfig.DamageType.PHYSICAL
	)
	var metrics_after := service.get_metrics()
	_expect(
		accepted == 1
		and int(metrics_after["native_shape_query_count"])
			== int(metrics_before["native_shape_query_count"])
		and int(metrics_after["native_candidate_count"])
			== int(metrics_before["native_candidate_count"])
		and int(metrics_after["indexed_aabb_query_count"])
			== int(metrics_before["indexed_aabb_query_count"]) + 1
		and int(metrics_after["indexed_candidate_count"])
			< int(metrics_before["indexed_candidate_count"]) + 300,
		"A 300-plant explosion must stay on indexed broad phase and execute zero full native shape queries."
	)
	for plant in plants:
		damageable_index.unregister_damageable(plant)
		plant.queue_free()
	await physics_frame


func _test_client_and_teardown_rejection() -> void:
	runtime.runtime_mode = CombatRuntimeBase.RuntimeMode.CLIENT_VIEW
	var metrics_before := service.get_metrics()
	_expect(
		service.resolve_hostile_explosion(
			Vector2.ZERO,
			16.0,
			10,
			null,
			_hostile_snapshot(&"client_rejection"),
			57,
			source_serial,
			&"client_rejection",
			EnemyConfig.DamageType.PHYSICAL
		) == 0,
		"CLIENT_VIEW must reject authoritative explosion resolution."
	)
	var shape_id := int(metrics_before["circle_shape_instance_id"])
	service.prepare_for_runtime_teardown()
	service.prepare_for_runtime_teardown()
	var metrics := service.get_metrics()
	_expect(
		not service.is_bound()
		and bool(metrics["teardown_prepared"])
		and int(metrics["teardown_count"]) == 1
		and int(metrics["active_resolution_count"]) == 0
		and int(metrics["accepted_ledger_size"]) == 0
		and int(metrics["indexed_candidate_buffer_size"]) == 0
		and int(metrics["cached_indexed_candidate_count"]) == 0
		and int(metrics["cached_overlapping_plant_count"]) == 0
		and int(metrics["player_candidate_buffer_size"]) == 0
		and int(metrics["enemy_candidate_buffer_size"]) == 0
		and int(metrics["native_shape_query_count"]) == 0
		and int(metrics["circle_shape_instance_id"]) == shape_id,
		"Teardown must be idempotent, release live work, and keep stable metric identities."
	)
	_expect(
		service.resolve_hostile_explosion(
			Vector2.ZERO,
			16.0,
			10,
			null,
			null,
			58,
			source_serial,
			&"post_teardown",
			EnemyConfig.DamageType.PHYSICAL
		) == 0,
		"A torn-down service must reject all later work."
	)


func _create_plant(
	plant_name: String,
	position: Vector2,
	radius: float
) -> PlantDefense:
	var plant := PlantDefense.new()
	_configure_plant(plant, plant_name, position, radius)
	return plant


func _configure_plant(
	plant: PlantDefense,
	plant_name: String,
	position: Vector2,
	radius: float
) -> void:
	plant.name = plant_name
	plant.collision_layer = DAMAGEABLE_MASK
	plant.collision_mask = 0
	plant.max_health = 1000
	plant.current_health = 1000
	plant.physical_defense = 0
	plant.magic_defense = 0
	plant.bind_gameplay_context(runtime, null)
	var collision_shape := CollisionShape2D.new()
	var circle := CircleShape2D.new()
	circle.radius = radius
	collision_shape.shape = circle
	plant.add_child(collision_shape)
	runtime.add_child(plant)
	plant.global_position = position


func _hostile_snapshot(source_type: StringName) -> DamageSourceSnapshot:
	source_serial += 1
	return DamageSourceSnapshot.create(
		CombatRelationService.HOSTILE_WAVE,
		0,
		50,
		source_serial,
		source_type
	)


func _finish() -> void:
	current_scene = null
	if runtime != null and is_instance_valid(runtime):
		runtime.queue_free()
	for _cleanup_frame in range(5):
		await process_frame
		await physics_frame
	var result := {
		"status": "ok" if failures.is_empty() else "failed",
		"failures": failures.duplicate(),
	}
	print("EXPLOSION_RESOLUTION_SERVICE_JSON %s" % JSON.stringify(result))
	if failures.is_empty():
		print("EXPLOSION_RESOLUTION_SERVICE_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
