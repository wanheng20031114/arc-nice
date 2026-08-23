extends SceneTree

const ImmediateHitscanResolverScript := preload(
	"res://scene/combat/simulation/immediate_hitscan_resolver.gd"
)
const RESOLVER_SCENE := preload(
	"res://scene/combat/simulation/immediate_hitscan_resolver.tscn"
)
const RUNTIME_SCENE := preload(
	"res://dev_tools/fixtures/enemy_gameplay_gateway_test_runtime.tscn"
)
const PLAYER_SCENE := preload(
	"res://scene/player/weishidaier/player_weishidaier.tscn"
)
const SMG_SCENE := preload("res://scene/enemy/capoo/capoo_smg.tscn")
const SMG_CONFIG := preload("res://resources/config/enemies/capoo_smg.tres")

const DAMAGEABLE_MASK := 512
const PLAYER_MASK := 2
const ENEMY_MASK := 4
const WORLD_MASK := 1
const RAY_MASK := WORLD_MASK | DAMAGEABLE_MASK
const RAY_FROM := Vector2.ZERO
const RAY_TO := Vector2(160.0, 0.0)

var failures: Array[String] = []
var runtime: EnemyGameplayGatewayTestRuntime = null
var resolver: ImmediateHitscanResolverScript = null
var target: PlantDefense = null


class RecordingTypedSession:
	extends EnemyGameplayGatewayTestSession

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

	_test_singleplayer_same_tick_damage()
	await _test_world_blocking()
	_test_client_visual_only()
	_test_host_same_tick_damage()
	await _test_host_player_uses_typed_gateway()
	await _test_enemy_faction_transparency_and_snapshot()
	_test_query_object_reuse()
	_test_rng_isolation()
	_test_binding_and_teardown_lifecycle()

	await _finish()


func _build_fixture() -> void:
	runtime = RUNTIME_SCENE.instantiate() as EnemyGameplayGatewayTestRuntime
	runtime.name = "ImmediateHitscanResolverSmokeTest"
	root.add_child(runtime)
	current_scene = runtime
	var coordinator := runtime.get_node_or_null("EnemySimulationCoordinator")
	if coordinator != null:
		coordinator.process_mode = Node.PROCESS_MODE_DISABLED

	resolver = RESOLVER_SCENE.instantiate() as ImmediateHitscanResolverScript
	runtime.add_child(resolver)
	_expect(
		resolver.bind_combat_runtime(runtime),
		"The resolver must accept its first explicit runtime binding."
	)
	target = _create_plant_target(Vector2(100.0, 0.0))


func _test_singleplayer_same_tick_damage() -> void:
	runtime.runtime_mode = CombatRuntimeBase.RuntimeMode.SINGLEPLAYER
	var health_before := target.current_health
	var physics_tick_before := Engine.get_physics_frames()
	var result := resolver.resolve_immediate_hitscan(
		RAY_FROM,
		RAY_TO,
		RAY_MASK,
		25,
		41,
		9001,
		&"immediate_hitscan_smoke",
		EnemyConfig.DamageType.MAGIC
	)
	_expect(
		Engine.get_physics_frames() == physics_tick_before,
		"The native ray and damage decision must complete in the caller's physics tick."
	)
	_expect(
		result.hit
		and result.visual_hit
		and result.authoritative
		and result.damage_applied
		and result.hit_kind == ImmediateHitscanResolverScript.HitKind.PLANT
		and result.collider == target
		and result.damage == 25
		and result.source_enemy_id == 41
		and result.source_projectile_id == 9001
		and result.source_type == &"immediate_hitscan_smoke"
		and result.source_faction_id == CombatRelationService.HOSTILE_WAVE
		and result.query_count == 1
		and result.damage_type == EnemyConfig.DamageType.MAGIC,
		"Single-player resolution must return the immediately adjudicated plant hit."
	)
	_expect(
		target.current_health == health_before - 25,
		"Single-player health mutation must be observable before resolve returns."
	)
	var damage_result := target.last_damage_result
	var request := damage_result.request if damage_result != null else null
	_expect(
		request != null
		and request.source_enemy_id == 41
		and request.source_projectile_id == 9001
		and request.source_type == &"immediate_hitscan_smoke"
		and request.source_snapshot_is_explicit
		and request.get_or_create_source_snapshot().source_faction_id
			== CombatRelationService.HOSTILE_WAVE
		and request.damage_type == EnemyConfig.DamageType.MAGIC
		and request.has_flag(CombatTypes.DamageFlag.RANGED),
		"Authoritative damage must preserve every stable source and damage input."
	)


func _test_world_blocking() -> void:
	var wall := _create_world_blocker(Vector2(50.0, 0.0))
	await physics_frame
	var health_before := target.current_health
	var result := resolver.resolve_immediate_hitscan(
		RAY_FROM,
		RAY_TO,
		RAY_MASK,
		30,
		42,
		0,
		&"blocked_hitscan",
		EnemyConfig.DamageType.PHYSICAL
	)
	_expect(
		result.hit
		and result.collider == wall
		and result.hit_kind == ImmediateHitscanResolverScript.HitKind.WORLD
		and not result.damage_applied,
		"The native ray must report the first World-layer blocker."
	)
	_expect(
		target.current_health == health_before,
		"A target behind World collision must not receive hitscan damage."
	)
	wall.queue_free()
	await process_frame
	await physics_frame


func _test_client_visual_only() -> void:
	runtime.runtime_mode = CombatRuntimeBase.RuntimeMode.CLIENT_VIEW
	var health_before := target.current_health
	var revision_before := target.health_revision
	var result := resolver.resolve_immediate_hitscan(
		RAY_FROM,
		RAY_TO,
		RAY_MASK,
		40,
		43,
		9002,
		&"client_visual_hitscan",
		EnemyConfig.DamageType.PHYSICAL
	)
	_expect(
		result.hit
		and result.visual_hit
		and not result.authoritative
		and not result.damage_applied
		and result.collider == target,
		"Client view must retain the visual ray hit without adjudicating damage."
	)
	_expect(
		target.current_health == health_before
		and target.health_revision == revision_before,
		"Client view must never mutate target health or its authoritative revision."
	)


func _test_host_same_tick_damage() -> void:
	runtime.runtime_mode = CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY
	var health_before := target.current_health
	var physics_tick_before := Engine.get_physics_frames()
	var result := resolver.resolve_immediate_hitscan(
		RAY_FROM,
		RAY_TO,
		RAY_MASK,
		35,
		44,
		9003,
		&"host_hitscan",
		EnemyConfig.DamageType.PHYSICAL
	)
	_expect(
		Engine.get_physics_frames() == physics_tick_before
		and result.authoritative
		and result.damage_applied
		and target.current_health == health_before - 35,
		"Host authority must apply plant damage before the resolver returns."
	)


func _test_host_player_uses_typed_gateway() -> void:
	var session := RecordingTypedSession.new()
	runtime.attach_gameplay_session(session)
	var player := PLAYER_SCENE.instantiate() as Player
	runtime.add_child(player)
	player.global_position = Vector2(100.0, 80.0)
	player.collision_layer = PLAYER_MASK
	player.peer_id = 77
	player.bind_combat_runtime(runtime)
	player.set_physics_process(false)
	await physics_frame
	var health_before := player.current_health
	var source_snapshot := DamageSourceSnapshot.create(
		CombatRelationService.HOSTILE_WAVE,
		0,
		50,
		9010,
		&"typed_host_hitscan"
	)
	var result := resolver.resolve_immediate_hitscan(
		Vector2(0.0, 80.0),
		Vector2(160.0, 80.0),
		PLAYER_MASK,
		20,
		50,
		9010,
		&"typed_host_hitscan",
		EnemyConfig.DamageType.PHYSICAL,
		source_snapshot
	)
	_expect(
		result.hit
		and result.hit_kind == ImmediateHitscanResolverScript.HitKind.PLAYER
		and result.damage_applied
		and result.query_count == 1
		and session.typed_request_count == 1
		and session.last_typed_snapshot != null
		and session.last_typed_snapshot.source_faction_id
			== CombatRelationService.HOSTILE_WAVE
		and session.last_typed_snapshot.event_source_id == 9010
		and player.current_health == health_before,
		"HOST player hits must use the typed frozen-snapshot gateway without mutating the local proxy directly."
	)
	runtime.detach_gameplay_session(session)
	player.queue_free()
	session.free()
	await process_frame
	await physics_frame


func _test_enemy_faction_transparency_and_snapshot() -> void:
	runtime.runtime_mode = CombatRuntimeBase.RuntimeMode.SINGLEPLAYER
	var friendly_enemy := _create_enemy_target(
		Vector2(50.0, 120.0),
		CombatRelationService.PLAYER_ALLIED
	)
	var hostile_enemy := _create_enemy_target(
		Vector2(100.0, 120.0),
		CombatRelationService.HOSTILE_WAVE
	)
	await physics_frame
	await physics_frame
	var friendly_health := friendly_enemy.current_health
	var hostile_health := hostile_enemy.current_health
	var source_snapshot := DamageSourceSnapshot.create(
		CombatRelationService.PLAYER_ALLIED,
		88,
		51,
		9011,
		&"frozen_enemy_hitscan"
	)
	var result := resolver.resolve_immediate_hitscan(
		Vector2(0.0, 120.0),
		Vector2(160.0, 120.0),
		ENEMY_MASK,
		20,
		51,
		9011,
		&"frozen_enemy_hitscan",
		EnemyConfig.DamageType.PHYSICAL,
		source_snapshot
	)
	source_snapshot.source_faction_id = CombatRelationService.HOSTILE_WAVE
	var request := (
		hostile_enemy.last_damage_result.request
		if hostile_enemy.last_damage_result != null
		else null
	)
	_expect(
		result.hit
		and result.hit_kind == ImmediateHitscanResolverScript.HitKind.ENEMY
		and result.collider == hostile_enemy
		and result.damage_applied
		and result.query_count == 2
		and result.transparent_hit_count == 1
		and friendly_enemy.current_health == friendly_health
		and hostile_enemy.current_health < hostile_health
		and request != null
		and request.source_enemy_id == 51
		and request.source_projectile_id == 9011
		and request.get_or_create_source_snapshot().source_faction_id
			== CombatRelationService.PLAYER_ALLIED
		and request.get_or_create_source_snapshot().credit_peer_id == 88,
		"The shared resolver must skip a friendly Enemy, damage the hostile Enemy behind it, and retain a frozen source snapshot."
	)
	friendly_enemy.queue_free()
	hostile_enemy.queue_free()
	await process_frame
	await physics_frame


func _test_query_object_reuse() -> void:
	var query_instance_id := resolver.get_query_instance_id()
	var result_instance_id := resolver.get_result_instance_id()
	var count_before := resolver.get_resolution_count()
	var first_result := resolver.resolve_immediate_hitscan(
		Vector2(0.0, 40.0),
		Vector2(160.0, 40.0),
		RAY_MASK,
		10,
		45,
		0,
		&"miss_hitscan",
		EnemyConfig.DamageType.PHYSICAL
	)
	_expect(
		not first_result.hit
		and first_result.resolution_id == count_before + 1,
		"The reusable result must expose the current call immediately."
	)
	var second_result := resolver.resolve_immediate_hitscan(
		Vector2(0.0, 48.0),
		Vector2(160.0, 48.0),
		RAY_MASK,
		10,
		46,
		0,
		&"second_miss_hitscan",
		EnemyConfig.DamageType.PHYSICAL
	)
	_expect(
		first_result == second_result
		and query_instance_id == resolver.get_query_instance_id()
		and result_instance_id == resolver.get_result_instance_id()
		and resolver.get_resolution_count() == count_before + 2,
		"Every call must reuse one native query and one strong Resolution object."
	)


func _test_rng_isolation() -> void:
	const FIXED_SEED := 0x5A17C0DE
	var caller_rng := RandomNumberGenerator.new()
	var caller_reference := RandomNumberGenerator.new()
	caller_rng.seed = FIXED_SEED
	caller_reference.seed = FIXED_SEED
	_expect(
		caller_rng.randi() == caller_reference.randi(),
		"The fixed caller RNG baseline must be deterministic."
	)
	resolver.resolve_immediate_hitscan(
		Vector2(0.0, 56.0),
		Vector2(160.0, 56.0),
		RAY_MASK,
		0,
		47,
		0,
		&"rng_isolation_hitscan",
		EnemyConfig.DamageType.PHYSICAL
	)
	_expect(
		caller_rng.randi() == caller_reference.randi(),
		"Resolving a final ray must not consume the caller-owned RNG sequence."
	)

	seed(FIXED_SEED)
	var expected_before := randi()
	var expected_after := randi()
	seed(FIXED_SEED)
	var actual_before := randi()
	resolver.resolve_immediate_hitscan(
		Vector2(0.0, 64.0),
		Vector2(160.0, 64.0),
		RAY_MASK,
		0,
		48,
		0,
		&"global_rng_isolation_hitscan",
		EnemyConfig.DamageType.PHYSICAL
	)
	var actual_after := randi()
	_expect(
		actual_before == expected_before and actual_after == expected_after,
		"ImmediateHitscanResolver must not read or advance the global RNG."
	)


func _test_binding_and_teardown_lifecycle() -> void:
	_expect(
		resolver.bind_combat_runtime(runtime)
		and resolver.is_bound_to(runtime),
		"Rebinding the same runtime must be idempotent."
	)
	var other_runtime := (
		RUNTIME_SCENE.instantiate() as EnemyGameplayGatewayTestRuntime
	)
	_expect(
		not resolver.bind_combat_runtime(other_runtime)
		and resolver.is_bound_to(runtime),
		"A live resolver must reject binding to a different runtime."
	)
	other_runtime.free()

	var query_count_before := resolver.get_query_count()
	resolver.prepare_for_runtime_teardown()
	resolver.prepare_for_runtime_teardown()
	var metrics := resolver.get_metrics()
	_expect(
		not resolver.is_bound()
		and bool(metrics["teardown_prepared"])
		and int(metrics["teardown_count"]) == 1
		and int(metrics["bind_rejection_count"]) == 1,
		"Teardown must be idempotent, clear the runtime, and publish lifecycle metrics."
	)
	_expect(
		not resolver.bind_combat_runtime(runtime),
		"A torn-down resolver must reject every later bind attempt."
	)
	var post_teardown_result := resolver.resolve_immediate_hitscan(
		RAY_FROM,
		RAY_TO,
		RAY_MASK,
		100,
		49,
		0,
		&"post_teardown_hitscan",
		EnemyConfig.DamageType.PHYSICAL
	)
	metrics = resolver.get_metrics()
	_expect(
		not post_teardown_result.hit
		and not post_teardown_result.authoritative
		and resolver.get_query_count() == query_count_before
		and int(metrics["bind_rejection_count"]) == 2
		and int(metrics["rejected_resolution_count"]) > 0,
		"After teardown the service must reject work without issuing another ray."
	)


func _create_plant_target(position: Vector2) -> PlantDefense:
	var plant := PlantDefense.new()
	plant.name = "HitscanPlantTarget"
	plant.collision_layer = DAMAGEABLE_MASK
	plant.collision_mask = 0
	plant.max_health = 1000
	plant.current_health = 1000
	plant.physical_defense = 0
	plant.magic_defense = 0
	var collision_shape := CollisionShape2D.new()
	var circle := CircleShape2D.new()
	circle.radius = 8.0
	collision_shape.shape = circle
	plant.add_child(collision_shape)
	runtime.add_child(plant)
	plant.global_position = position
	return plant


func _create_world_blocker(position: Vector2) -> StaticBody2D:
	var wall := StaticBody2D.new()
	wall.name = "HitscanWorldBlocker"
	wall.collision_layer = WORLD_MASK
	wall.collision_mask = 0
	var collision_shape := CollisionShape2D.new()
	var rectangle := RectangleShape2D.new()
	rectangle.size = Vector2(12.0, 48.0)
	collision_shape.shape = rectangle
	wall.add_child(collision_shape)
	runtime.add_child(wall)
	wall.global_position = position
	return wall


func _create_enemy_target(position: Vector2, faction_id: int) -> CapooSMG:
	var enemy := SMG_SCENE.instantiate() as CapooSMG
	runtime.get_node("EnemyContainer").add_child(enemy)
	enemy.global_position = position
	enemy.setup(SMG_CONFIG, null, null, runtime)
	enemy.set_physics_process(false)
	enemy.set_combat_faction_id(faction_id, -1, true)
	return enemy


func _finish() -> void:
	current_scene = null
	if runtime != null and is_instance_valid(runtime):
		runtime.queue_free()
	for _cleanup_frame in range(5):
		await process_frame
		await physics_frame
	if failures.is_empty():
		print("IMMEDIATE_HITSCAN_RESOLVER_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
