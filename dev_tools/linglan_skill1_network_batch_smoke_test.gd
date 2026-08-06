extends SceneTree

const LINGLAN_SCENE := preload("res://scene/boss/linglan/linglan_boss.tscn")
const SAKURA_BULLET_SCENE := preload(
	"res://scene/boss/linglan/linglan_skill1_sakura_bullet.tscn"
)


class HostNetManagerStub:
	extends Node

	func is_multiplayer_active() -> bool:
		return true

	func is_host() -> bool:
		return true


class RecordingMpGame:
	extends "res://scene/multiplayer/mp_game.gd"

	var sent_methods: Array[StringName] = []
	var sent_arguments: Array[Array] = []

	func _rpc_to_connected_clients(method_name: StringName, args: Array = []) -> void:
		sent_methods.append(method_name)
		sent_arguments.append(args.duplicate())


class PoolRuntime:
	extends "res://dev_tools/fixtures/linglan_combat_test_runtime.gd"

	var pool: SessionObjectPool = null
	var ring_batch_call_count: int = 0
	var ring_projectiles: Array[Node] = []
	var ring_spawn_positions := PackedVector2Array()
	var ring_directions := PackedVector2Array()
	var ring_owner_peer_id: int = 0
	var ring_damage: int = 0
	var ring_speed: float = 0.0
	var ring_lifetime: float = 0.0

	func install_pool() -> void:
		pool = session_object_pool
		pool.register_scene(SAKURA_BULLET_SCENE, 20, 768)

	func has_session_object_pool_scene(scene: PackedScene) -> bool:
		return pool != null and pool.is_registered(scene)

	func acquire_session_object(scene: PackedScene, strict: bool = false) -> Node:
		if pool == null or not pool.is_registered(scene):
			return null
		return pool.try_acquire(scene) if strict else pool.acquire(scene)

	func register_local_linglan_skill1_ring(
		projectiles: Array[Node],
		spawn_positions: PackedVector2Array,
		directions: PackedVector2Array,
		owner_peer_id: int,
		damage: int,
		speed: float,
		lifetime: float
	) -> void:
		ring_batch_call_count += 1
		ring_projectiles.assign(projectiles)
		ring_spawn_positions = spawn_positions.duplicate()
		ring_directions = directions.duplicate()
		ring_owner_peer_id = owner_peer_id
		ring_damage = damage
		ring_speed = speed
		ring_lifetime = lifetime


var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var runtime := PoolRuntime.new()
	runtime.name = "LinglanSkill1NetworkBatchRuntime"
	runtime.install_pool()
	root.add_child(runtime)

	var boss := LINGLAN_SCENE.instantiate() as LinglanBoss
	runtime.add_child(boss)
	runtime.bind_linglan_node(boss)
	await process_frame
	boss.global_position = Vector2(96.0, 64.0)
	boss.call("_fire_skill1_ring", 0.0)

	var direction_count := boss.skill1_config.ring_direction_count
	var fire_interval := boss.skill1_config.get_fire_interval()
	var ring_rate := 1.0 / fire_interval
	var total_ring_count := ceili(
		boss.skill1_config.get_total_duration() / fire_interval
	)
	var total_projectile_count := total_ring_count * direction_count
	_expect(
		direction_count == 20
		and total_ring_count == 306
		and total_projectile_count == 6120,
		"Authored Skill1 must remain 306 rings × 20 projectiles = 6120 projectiles."
	)
	_expect(
		is_equal_approx(ring_rate, 18.0)
		and is_equal_approx(ring_rate * float(direction_count), 360.0),
		"Authored emission must remain 18 rings/s and 360 projectiles/s."
	)
	_expect(
		runtime.ring_batch_call_count == 1
		and runtime.ring_projectiles.size() == direction_count
		and runtime.ring_spawn_positions.size() == direction_count
		and runtime.ring_directions.size() == direction_count,
		"One authored 20-projectile ring must enter multiplayer registration exactly once."
	)
	_verify_ring_geometry(runtime, boss.global_position, boss.skill1_config.projectile_spawn_distance)

	var host_mp := RecordingMpGame.new()
	var host_net := HostNetManagerStub.new()
	host_mp.add_child(host_net)
	host_mp.set("net_manager", host_net)
	# Cross the old decimal namespace boundary inside the real PackedInt64 ring
	# path. IDs must remain owned by the same peer on both sides of 1,000,000.
	host_mp.set("_next_projectile_sequence", 999999)
	host_mp.call(
		"register_local_linglan_skill1_ring",
		runtime.ring_projectiles,
		runtime.ring_spawn_positions,
		runtime.ring_directions,
		runtime.ring_owner_peer_id,
		runtime.ring_damage,
		runtime.ring_speed,
		runtime.ring_lifetime
	)
	_expect(
		host_mp.sent_methods == [&"net_linglan_skill1_ring_batch"]
		and host_mp.sent_arguments.size() == 1,
		"Host must emit one CH4 batch call for a complete 20-projectile ring."
	)
	if host_mp.sent_arguments.is_empty():
		await _cleanup(runtime, boss, host_mp, null)
		_finish(ring_rate)
		return

	var payload := host_mp.sent_arguments[0]
	var projectile_ids := payload[0] as PackedInt64Array
	var spawn_positions := payload[1] as PackedVector2Array
	var directions := payload[2] as PackedVector2Array
	var owner_peer_id := int(payload[3])
	var damage := int(payload[4])
	var speed := float(payload[5])
	var lifetime := float(payload[6])
	var host_fire_timestamp := float(payload[7])
	_expect(
		projectile_ids.size() == direction_count
		and spawn_positions == runtime.ring_spawn_positions
		and directions == runtime.ring_directions
		and owner_peer_id == runtime.ring_owner_peer_id
		and damage == runtime.ring_damage
		and is_equal_approx(speed, runtime.ring_speed)
		and is_equal_approx(lifetime, runtime.ring_lifetime)
		and host_fire_timestamp >= 0.0,
		"Packed Host payload must preserve every projectile's position, direction, and shared start time."
	)
	_verify_strictly_increasing_ids(projectile_ids)
	_expect(
		int(host_mp.call(
			"_decode_projectile_sequence_counter",
			int(projectile_ids[0])
		)) == 999999
		and int(host_mp.call(
			"_decode_projectile_sequence_counter",
			int(projectile_ids[projectile_ids.size() - 1])
		)) == 1000018,
		"The real ring batch must cross the legacy one-million sequence boundary without changing owner."
	)
	for projectile_id in projectile_ids:
		_expect(
			bool(host_mp.call(
				"_is_projectile_id_valid_for_host_owner",
				int(projectile_id),
				owner_peer_id
			)),
			"Every PackedInt64 ring ID must decode to the authoritative owner."
		)
	_expect(
		(host_mp.get("_known_projectiles") as Dictionary).size() == direction_count
		and (host_mp.get("_projectile_records") as Dictionary).size() == direction_count,
		"Host batch registration must retain one identity and damage record per real projectile."
	)

	var client_mp := RecordingMpGame.new()
	client_mp.set("game", runtime)
	client_mp.set("_has_host_time_offset", true)
	client_mp.set("_host_to_client_time_offset", 0.0)
	client_mp.call(
		"net_linglan_skill1_ring_batch",
		projectile_ids,
		spawn_positions,
		directions,
		owner_peer_id,
		damage,
		speed,
		lifetime,
		host_fire_timestamp
	)
	var client_known := client_mp.get("_known_projectiles") as Dictionary
	var client_records := client_mp.get("_projectile_records") as Dictionary
	_expect(
		client_known.size() == direction_count and client_records.size() == direction_count,
		"Client batch playback must create and track all 20 proxy projectiles."
	)
	_verify_client_proxy_payload(
		client_known,
		projectile_ids,
		spawn_positions,
		directions,
		owner_peer_id,
		damage,
		speed,
		lifetime
	)
	var created_before_duplicate := int(
		runtime.pool.get_metrics(SAKURA_BULLET_SCENE.resource_path).get("created", 0)
	)
	client_mp.call(
		"net_linglan_skill1_ring_batch",
		projectile_ids,
		spawn_positions,
		directions,
		owner_peer_id,
		damage,
		speed,
		lifetime,
		host_fire_timestamp
	)
	_expect(
		client_known.size() == direction_count
		and int(runtime.pool.get_metrics(
			SAKURA_BULLET_SCENE.resource_path
		).get("created", 0)) == created_before_duplicate,
		"A duplicated ring packet must not lease or register any second proxy projectile."
	)

	_retire_projectiles(client_known)
	_retire_projectiles(host_mp.get("_known_projectiles") as Dictionary)
	_expect(
		client_known.is_empty()
		and (host_mp.get("_known_projectiles") as Dictionary).is_empty(),
		"Pooled projectile_finished signals must synchronously clear both network registries."
	)
	client_mp.call("_prune_projectile_records", INF)
	host_mp.call("_prune_projectile_records", INF)
	_expect(
		client_records.is_empty()
		and (host_mp.get("_projectile_records") as Dictionary).is_empty(),
		"Expired batch records must be removed by the reusable stale-ID prune buffer."
	)

	await _cleanup(runtime, boss, host_mp, client_mp)
	_finish(ring_rate)


func _verify_ring_geometry(runtime: PoolRuntime, center: Vector2, spawn_distance: float) -> void:
	for projectile_index in range(runtime.ring_projectiles.size()):
		var projectile := runtime.ring_projectiles[projectile_index] as LinglanSakuraBullet
		var direction := runtime.ring_directions[projectile_index]
		var expected_position := center + direction * spawn_distance
		_expect(
			projectile != null
			and projectile.global_position.is_equal_approx(expected_position)
			and projectile.direction.is_equal_approx(direction.normalized()),
			"Ring projectile %d must preserve its authored radial spawn and trajectory."
			% projectile_index
		)


func _verify_strictly_increasing_ids(projectile_ids: PackedInt64Array) -> void:
	var previous_id: int = 0
	for projectile_id in projectile_ids:
		_expect(
			projectile_id > previous_id,
			"Every packed ring projectile must have a unique, monotonic network ID."
		)
		previous_id = projectile_id


func _verify_client_proxy_payload(
	known_projectiles: Dictionary,
	projectile_ids: PackedInt64Array,
	spawn_positions: PackedVector2Array,
	directions: PackedVector2Array,
	owner_peer_id: int,
	damage: int,
	speed: float,
	lifetime: float
) -> void:
	for projectile_index in range(projectile_ids.size()):
		var projectile_id := int(projectile_ids[projectile_index])
		var projectile := known_projectiles.get(projectile_id) as LinglanSakuraBullet
		_expect(projectile != null, "Client proxy %d must exist." % projectile_id)
		if projectile == null:
			continue
		var direction := directions[projectile_index].normalized()
		var compensated_offset := projectile.global_position - spawn_positions[projectile_index]
		_expect(
			projectile.projectile_id == projectile_id
			and projectile.owner_peer_id == owner_peer_id
			and projectile.source_type == &"linglan_skill1"
			and projectile.direction.is_equal_approx(direction)
			and projectile.damage == damage
			and is_equal_approx(projectile.speed, speed)
			and projectile.remaining_lifetime <= lifetime
			and compensated_offset.dot(direction) >= -0.01
			and absf(compensated_offset.cross(direction)) <= 0.01,
			"Client proxy %d must preserve identity, payload, and forward-only late compensation."
			% projectile_id
		)


func _retire_projectiles(projectiles: Dictionary) -> void:
	var active_projectiles: Array[Node] = []
	for projectile_variant in projectiles.values():
		var projectile := projectile_variant as Node
		if projectile != null and is_instance_valid(projectile):
			active_projectiles.append(projectile)
	for projectile in active_projectiles:
		projectile.call("retire")


func _cleanup(
	runtime: PoolRuntime,
	boss: LinglanBoss,
	host_mp: RecordingMpGame,
	client_mp: RecordingMpGame
) -> void:
	if client_mp != null:
		client_mp.free()
	if host_mp != null:
		host_mp.free()
	if boss != null and is_instance_valid(boss):
		boss.queue_free()
	if runtime != null and is_instance_valid(runtime):
		runtime.queue_free()
	for _frame in range(3):
		await process_frame
		await physics_frame


func _finish(ring_rate: float) -> void:
	if failures.is_empty():
		print(
			"LINGLAN_SKILL1_NETWORK_BATCH_SMOKE_TEST_OK ",
			"before_rpc_per_second=", snappedf(ring_rate * 20.0, 0.001),
			" after_rpc_per_second=", snappedf(ring_rate, 0.001),
			" reduction=20x total_projectiles=6120 total_batches=306"
		)
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
