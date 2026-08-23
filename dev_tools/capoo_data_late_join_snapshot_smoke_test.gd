extends SceneTree

const FIXTURE_SCENE := preload(
	"res://dev_tools/fixtures/enemy_gameplay_gateway_test_runtime.tscn"
)
const COORDINATOR_SCENE := preload(
	"res://scene/multiplayer/projectile/mp_projectile_coordinator.tscn"
)
const Codec := preload(
	"res://scene/multiplayer/projectile/capoo_data_projectile_snapshot_codec.gd"
)
const RPGServiceScript := preload(
	"res://scene/combat/simulation/capoo_rpg_rocket_simulation_service.gd"
)
const MageServiceScript := preload(
	"res://scene/combat/simulation/capoo_mage_fireball_simulation_service.gd"
)

const MAGE_TYPE := &"capoo_mage_fireball"
const RPG_TYPE := &"capoo_rpg_rocket"
const SPAWN_POSITION := Vector2(120.0, 80.0)
const DIRECTION := Vector2(0.6, 0.8)
const DAMAGE := 34
const MAGE_SPEED := 155.0
const RPG_SPEED := 180.0
const LIFETIME := 6.0
const HOST_TIME := 400.0
const OWNER_PEER_ID := 9
const TARGET_PEER_ID := 7
const TARGET_WORLD_NET_ID := 93
const LARGE_RECORD_COUNT := 300
const SIMULATED_SNAPSHOT_TRANSIT_AGE := 0.125
const COMPLETION_BACKLOG_LIFETIME := 0.001


class TargetModeAdapter:
	extends MultiplayerModeAdapter

	var target_net_id := 0
	var target: Node2D = null

	func get_network_projectile_world_target(net_id: int) -> Node2D:
		return target if net_id == target_net_id else null


var failures: Array[String] = []
var snapshot_chunks: Array[Array] = []
var launch_broadcasts: Array[Array] = []
var simulated_client_event_age := 0.0


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
	var mage_service: MageServiceScript = (
		combat_services.get_capoo_mage_fireball_simulation_service()
		if combat_services != null
		else null
	)
	var rpg_service: RPGServiceScript = (
		combat_services.get_capoo_rpg_rocket_simulation_service()
		if combat_services != null
		else null
	)
	_expect(
		combat_services != null and mage_service != null and rpg_service != null,
		"Late-join coverage requires both authored Capoo simulation services."
	)
	if combat_services == null or mage_service == null or rpg_service == null:
		runtime.queue_free()
		await process_frame
		_finish()
		return
	combat_services.set_physics_process(false)
	mage_service.set_physics_process(false)
	rpg_service.set_physics_process(false)

	var peer_target := Player.new()
	peer_target.global_position = Vector2(-180.0, -120.0)
	var world_target := PlantDefense.new()
	world_target.global_position = Vector2(360.0, 40.0)
	var target_adapter := TargetModeAdapter.new()
	target_adapter.target_net_id = TARGET_WORLD_NET_ID
	target_adapter.bind_runtime(runtime)
	runtime.multiplayer_mode_adapter = target_adapter

	var player_coordinator := MpPlayerCoordinator.new()
	player_coordinator.bind_runtime(runtime)
	var host_net_manager := _make_net_manager(NetManagerStore.NetRole.HOST)
	var client_net_manager := _make_net_manager(NetManagerStore.NetRole.CLIENT)
	var host_coordinator := _make_coordinator(
		runtime,
		player_coordinator,
		host_net_manager
	)
	var client_coordinator := _make_coordinator(
		runtime,
		player_coordinator,
		client_net_manager
	)
	host_coordinator.rpc_to_peer_requested.connect(
		func(peer_id: int, method_name: StringName, arguments: Array) -> void:
			if (
				peer_id == 77
				and method_name == &"net_capoo_data_projectile_snapshot_chunk"
			):
				snapshot_chunks.append(arguments.duplicate(true))
	)
	host_coordinator.rpc_broadcast_requested.connect(
		func(method_name: StringName, arguments: Array) -> void:
			if method_name == &"net_projectile_fired":
				launch_broadcasts.append(arguments.duplicate(true))
	)

	var peer_source := _make_source(MAGE_TYPE, 731)
	var peer_mage_handle := _spawn_mage(mage_service, peer_source, peer_target)
	var peer_mage_id := _register_mage(
		host_coordinator,
		mage_service,
		peer_mage_handle,
		peer_source,
		TARGET_PEER_ID,
		0
	)
	var rpg_source := _make_source(RPG_TYPE, 732)
	var rpg_handle := _spawn_rpg(rpg_service, rpg_source)
	var rpg_id := _register_rpg(
		host_coordinator,
		rpg_service,
		rpg_handle,
		rpg_source
	)
	var world_source := _make_source(MAGE_TYPE, 733)
	var world_mage_handle := _spawn_mage(mage_service, world_source, world_target)
	var world_mage_id := _register_mage(
		host_coordinator,
		mage_service,
		world_mage_handle,
		world_source,
		0,
		TARGET_WORLD_NET_ID
	)
	_expect(
		peer_mage_id > 0 and rpg_id > peer_mage_id and world_mage_id > rpg_id,
		"The fixture must interleave Mage/RPG/Mage IDs before sorting."
	)

	await physics_frame
	mage_service.advance(0.2)
	rpg_service.advance(0.2)
	_snapshot(host_coordinator)
	var initial_snapshot_timestamp := float(snapshot_chunks[0][3])
	var post_snapshot_source := _make_source(RPG_TYPE, 734)
	var post_snapshot_data_handle := _spawn_rpg(
		rpg_service,
		post_snapshot_source
	)
	var post_snapshot_id := _register_rpg(
		host_coordinator,
		rpg_service,
		post_snapshot_data_handle,
		post_snapshot_source
	)
	var post_snapshot_launch: Array = launch_broadcasts.back()
	_apply_launch_payload(client_coordinator, post_snapshot_launch)
	var post_snapshot_replica := _find_rpg_handle(
		rpg_service,
		post_snapshot_id,
		RPGServiceScript.Mode.REPLICA
	)
	_expect(
		post_snapshot_id > world_mage_id
		and float(post_snapshot_launch[10]) > initial_snapshot_timestamp
		and post_snapshot_replica > RPGServiceScript.INVALID_HANDLE,
		"A launch after snapshot capture must receive a timestamp strictly above the snapshot waterline even within the same millisecond."
	)
	var initial_records := _decode_complete_snapshot(snapshot_chunks)
	_expect(
		initial_records.size() == 3
		and int(initial_records[0]["projectile_id"]) == peer_mage_id
		and int(initial_records[1]["projectile_id"]) == rpg_id
		and int(initial_records[2]["projectile_id"]) == world_mage_id,
		"RPG and Mage rows must share one projectile-ID stable snapshot order."
	)
	_expect(
		_is_current_record(
			initial_records[0], mage_service, peer_mage_handle,
			Codec.FAMILY_CAPOO_MAGE, TARGET_PEER_ID, 0
		)
		and _is_current_record(
			initial_records[1], rpg_service, rpg_handle,
			Codec.FAMILY_CAPOO_RPG, 0, 0
		)
		and _is_current_record(
			initial_records[2], mage_service, world_mage_handle,
			Codec.FAMILY_CAPOO_MAGE, 0, TARGET_WORLD_NET_ID
		),
		"The snapshot must carry current motion, remaining lifetime, targets, and frozen source."
	)
	var initial_chunks := snapshot_chunks.duplicate(true)
	simulated_client_event_age = SIMULATED_SNAPSHOT_TRANSIT_AGE
	_expect(
		_apply_chunks(client_coordinator, initial_chunks),
		"A complete reliable snapshot must apply."
	)
	var peer_mage_replica := _find_mage_handle(
		mage_service, peer_mage_id, MageServiceScript.Mode.REPLICA
	)
	var rpg_replica := _find_rpg_handle(
		rpg_service, rpg_id, RPGServiceScript.Mode.REPLICA
	)
	var world_mage_replica := _find_mage_handle(
		mage_service, world_mage_id, MageServiceScript.Mode.REPLICA
	)
	var expected_peer_mage_position := (
		(initial_records[0]["position"] as Vector2)
		+ (initial_records[0]["direction"] as Vector2).normalized()
			* float(initial_records[0]["speed"])
			* SIMULATED_SNAPSHOT_TRANSIT_AGE
	)
	var expected_rpg_position := (
		(initial_records[1]["position"] as Vector2)
		+ (initial_records[1]["direction"] as Vector2).normalized()
			* float(initial_records[1]["speed"])
			* SIMULATED_SNAPSHOT_TRANSIT_AGE
	)
	_expect(
		peer_mage_replica > MageServiceScript.INVALID_HANDLE
		and rpg_replica > RPGServiceScript.INVALID_HANDLE
		and world_mage_replica > MageServiceScript.INVALID_HANDLE
		and mage_service.get_position(peer_mage_replica).distance_to(
			expected_peer_mage_position
		) < 0.05
		and rpg_service.get_position(rpg_replica).distance_to(
			expected_rpg_position
		) < 0.05
		and is_equal_approx(
			mage_service.get_remaining_lifetime(peer_mage_replica),
			float(initial_records[0]["remaining_lifetime"])
				- SIMULATED_SNAPSHOT_TRANSIT_AGE
		)
		and is_equal_approx(
			rpg_service.get_remaining_lifetime(rpg_replica),
			float(initial_records[1]["remaining_lifetime"])
				- SIMULATED_SNAPSHOT_TRANSIT_AGE
		)
		and is_equal_approx(
			mage_service.get_visual_age(peer_mage_replica),
			float(initial_records[0]["visual_age"])
				+ SIMULATED_SNAPSHOT_TRANSIT_AGE
		)
		and is_equal_approx(
			rpg_service.get_visual_age(rpg_replica),
			float(initial_records[1]["visual_age"])
				+ SIMULATED_SNAPSHOT_TRANSIT_AGE
		)
		and mage_service.get_damage(peer_mage_replica) == 0
		and rpg_service.get_damage(rpg_replica) == 0
		and rpg_service.is_handle_live(post_snapshot_replica)
		and client_coordinator.has_capoo_rpg_replica(post_snapshot_id)
		and int(client_coordinator.get_state_metrics()[
			"pending_capoo_mage_replica_targets"
		]) == 2
		and mage_service.get_target_instance_id(peer_mage_replica) == 0
		and mage_service.get_target_instance_id(world_mage_replica) == 0
		and _count_legacy_nodes(runtime) == 0,
		"Complete application must independently preserve current visual age and apply network transit compensation to position/lifetime while keeping zero-damage REPLICA rows."
	)
	simulated_client_event_age = 0.0
	_expect(
		not mage_service.rebind_replica_target(peer_mage_handle, peer_target)
		and not mage_service.rebind_replica_target(
			MageServiceScript.INVALID_HANDLE, peer_target
		),
		"Target rebinding must reject authoritative and invalid handles."
	)
	var peer_direction_before_rebind := mage_service.get_direction(peer_mage_replica)
	var world_direction_before_rebind := mage_service.get_direction(world_mage_replica)
	runtime.peer_players[TARGET_PEER_ID] = peer_target
	target_adapter.target = world_target
	client_coordinator.refresh_pending_capoo_mage_replica_targets()
	_expect(
		mage_service.get_target(peer_mage_replica) == peer_target
		and mage_service.get_target(world_mage_replica) == world_target
		and int(client_coordinator.get_state_metrics()[
			"capoo_mage_replica_target_records"
		]) == 2
		and int(client_coordinator.get_state_metrics()[
			"pending_capoo_mage_replica_targets"
		]) == 0,
		"Physics-rate maintenance must rebind player and world targets that arrive after the snapshot, then stop retrying them."
	)
	var mp_game_source := FileAccess.get_file_as_string(
		"res://scene/multiplayer/mp_game.gd"
	)
	_expect(
		mp_game_source.contains(
			"projectile_coordinator.refresh_pending_capoo_mage_replica_targets()"
		),
		"The live client physics tick must drive pending Mage target rebinding faster than the five-second record prune."
	)
	await physics_frame
	mage_service.advance(0.1)
	_expect(
		not mage_service.get_direction(peer_mage_replica).is_equal_approx(
			peer_direction_before_rebind
		)
		and not mage_service.get_direction(world_mage_replica).is_equal_approx(
			world_direction_before_rebind
		),
		"Late-bound Mage replicas must resume homing on the next simulation step."
	)
	var mage_dense_count := mage_service.get_dense_record_count()
	var rpg_dense_count := rpg_service.get_dense_record_count()
	_expect(
		_apply_chunks(client_coordinator, initial_chunks)
		and mage_service.get_dense_record_count() == mage_dense_count
		and rpg_service.get_dense_record_count() == rpg_dense_count,
		"Repeated chunks from an applied snapshot must be idempotent."
	)

	await physics_frame
	mage_service.advance(LIFETIME)
	rpg_service.advance(LIFETIME)
	_snapshot(host_coordinator)
	_expect(
		snapshot_chunks.size() == 1
		and int(snapshot_chunks[0][2]) == 0
		and (snapshot_chunks[0][4] as PackedByteArray).is_empty()
		and _apply_chunks(client_coordinator, snapshot_chunks),
		"An empty reliable manifest must retire the older complete active set."
	)
	client_coordinator.prune_records(HOST_TIME)
	_expect(
		int(host_coordinator.get_state_metrics()["known_capoo_mage_data"]) == 0
		and int(host_coordinator.get_state_metrics()["known_capoo_rpg_data"]) == 0
		and int(client_coordinator.get_state_metrics()[
			"known_capoo_mage_replicas"
		]) == 0
		and int(client_coordinator.get_state_metrics()[
			"known_capoo_rpg_replicas"
		]) == 0
		and not _apply_chunks(client_coordinator, initial_chunks),
		"Expired rows must be pruned and an older snapshot must not resurrect them."
	)
	mage_service.clear_completion_records()
	rpg_service.clear_completion_records()

	var large_ids: Array[int] = []
	for record_index in range(LARGE_RECORD_COUNT):
		if record_index % 2 == 0:
			var source := _make_source(RPG_TYPE, 1000 + record_index)
			var handle := _spawn_rpg(rpg_service, source)
			large_ids.append(_register_rpg(
				host_coordinator, rpg_service, handle, source
			))
		else:
			var source := _make_source(MAGE_TYPE, 1000 + record_index)
			var handle := _spawn_mage(mage_service, source, null)
			large_ids.append(_register_mage(
				host_coordinator, mage_service, handle, source, 0, 0
			))
	_expect(
		large_ids.size() == LARGE_RECORD_COUNT and large_ids.min() > 0,
		"The 300-row fixture must register every authoritative DATA projectile."
	)
	_snapshot(host_coordinator)
	var missing_chunk_snapshot := snapshot_chunks.duplicate(true)
	var large_records := _decode_complete_snapshot(missing_chunk_snapshot)
	_expect(
		large_records.size() == LARGE_RECORD_COUNT
		and missing_chunk_snapshot.size() == ceili(
			float(LARGE_RECORD_COUNT) / float(Codec.MAX_RECORDS_PER_CHUNK)
		)
		and _records_match_ids(large_records, large_ids)
		and _chunks_within_budget(missing_chunk_snapshot),
		"The 300-row snapshot must be globally sorted, complete, and remain under the 1200-byte packet budget."
	)
	var missing_chunk_index := missing_chunk_snapshot.size() / 2
	for chunk in missing_chunk_snapshot:
		if int(chunk[1]) != missing_chunk_index:
			_expect(
				_apply_chunk(client_coordinator, chunk),
				"Every valid partial chunk must be accepted."
			)
	_expect(
		int(client_coordinator.get_state_metrics()[
			"pending_capoo_data_snapshots"
		]) == 1
		and int(client_coordinator.get_state_metrics()[
			"known_capoo_mage_replicas"
		]) == 0
		and int(client_coordinator.get_state_metrics()[
			"known_capoo_rpg_replicas"
		]) == 0,
		"A missing chunk must leave the previous visual set untouched and apply no partial rows."
	)
	client_coordinator.prune_records(
		HOST_TIME + MpProjectileCoordinator.CAPOO_DATA_PENDING_SNAPSHOT_RETENTION_SECONDS + 1.0
	)
	_expect(
		int(client_coordinator.get_state_metrics()[
			"pending_capoo_data_snapshots"
		]) == 0
		and not _apply_chunk(
			client_coordinator, missing_chunk_snapshot[missing_chunk_index]
		),
		"Timed-out incomplete snapshots must be pruned and cannot be resumed by a late missing chunk."
	)

	_snapshot(host_coordinator)
	var replacement_chunks := snapshot_chunks.duplicate(true)
	var rpg_backlog_count := (
		rpg_service.get_reserved_capacity()
		- rpg_service.get_live_count()
		- LARGE_RECORD_COUNT / 2
		+ 1
	)
	var mage_backlog_count := (
		mage_service.get_reserved_capacity()
		- mage_service.get_live_count()
		- LARGE_RECORD_COUNT / 2
		+ 1
	)
	_expect(
		rpg_backlog_count > 0
		and mage_backlog_count > 0
		and _spawn_rpg_replica_backlog(rpg_service, rpg_backlog_count)
		and _spawn_mage_replica_backlog(mage_service, mage_backlog_count),
		"The capacity regression fixture must fill each completion transfer buffer to one row beyond the old snapshot reservation formula."
	)
	await physics_frame
	rpg_service.advance(0.01)
	mage_service.advance(0.01)
	_expect(
		rpg_service.get_completion_count() == rpg_backlog_count
		and mage_service.get_completion_count() == mage_backlog_count,
		"Completed transient replicas must remain queued while the reliable snapshot is applied."
	)
	var final_chunk: Array = replacement_chunks[0]
	for reverse_index in range(replacement_chunks.size() - 1, 0, -1):
		_expect(
			_apply_chunk(client_coordinator, replacement_chunks[reverse_index]),
			"Out-of-order chunks from the newer snapshot must be buffered."
		)
	if replacement_chunks.size() > 2:
		_expect(
			_apply_chunk(client_coordinator, replacement_chunks[2]),
			"An identical duplicate buffered chunk must be idempotent."
		)
	_expect(
		int(client_coordinator.get_state_metrics()[
			"known_capoo_mage_replicas"
		]) == 0
		and int(client_coordinator.get_state_metrics()[
			"known_capoo_rpg_replicas"
		]) == 0
		and _apply_chunk(client_coordinator, final_chunk),
		"The newer snapshot must not publish until its final missing chunk arrives."
	)
	_expect(
		int(client_coordinator.get_state_metrics()[
			"known_capoo_mage_replicas"
		]) == LARGE_RECORD_COUNT / 2
		and int(client_coordinator.get_state_metrics()[
			"known_capoo_rpg_replicas"
		]) == LARGE_RECORD_COUNT / 2
		and _all_replica_damage_is_zero(mage_service, rpg_service)
		and rpg_service.get_completion_count() == rpg_backlog_count
		and mage_service.get_completion_count() == mage_backlog_count,
		"A complete 300-row replacement must reserve around queued completions, publish exactly once, and leave every client row zero-damage."
	)
	rpg_service.clear_completion_records()
	mage_service.clear_completion_records()
	var live_count_after_replacement := (
		mage_service.get_live_count() + rpg_service.get_live_count()
	)
	_expect(
		_apply_chunks(client_coordinator, replacement_chunks)
		and mage_service.get_live_count() + rpg_service.get_live_count()
			== live_count_after_replacement,
		"Repeating the complete 300-row snapshot must not leak handles."
	)

	client_coordinator.reset_session_state()
	_expect(
		mage_service.get_live_count() + rpg_service.get_live_count()
			== LARGE_RECORD_COUNT,
		"Client reconnect reset must release every visual replica while preserving Host DATA."
	)
	_snapshot(host_coordinator)
	var reconnect_chunks := snapshot_chunks.duplicate(true)
	for parity in [1, 0]:
		for chunk in reconnect_chunks:
			if int(chunk[1]) % 2 == parity:
				_expect(
					_apply_chunk(client_coordinator, chunk),
					"Reconnect chunks must tolerate deterministic shuffled delivery."
				)
	_expect(
		int(client_coordinator.get_state_metrics()[
			"known_capoo_mage_replicas"
		]) + int(client_coordinator.get_state_metrics()[
			"known_capoo_rpg_replicas"
		]) == LARGE_RECORD_COUNT,
		"Reconnect must rebuild the complete 300-row visual set."
	)

	var unrelated_source := _make_source(RPG_TYPE, 1999)
	var unrelated_data_handle := _spawn_rpg(rpg_service, unrelated_source)
	var unrelated_projectile_id := _register_rpg(
		host_coordinator,
		rpg_service,
		unrelated_data_handle,
		unrelated_source,
		0
	)
	_snapshot(host_coordinator)
	var peer_clear_older_chunks := snapshot_chunks.duplicate(true)
	_snapshot(host_coordinator)
	var peer_clear_chunks := snapshot_chunks.duplicate(true)
	client_coordinator.clear_peer(OWNER_PEER_ID)
	host_coordinator.clear_peer(OWNER_PEER_ID)
	var delayed_owner_launch: Array = []
	for launch_index in range(launch_broadcasts.size() - 1, -1, -1):
		var candidate: Array = launch_broadcasts[launch_index]
		if int(candidate[2]) == OWNER_PEER_ID:
			delayed_owner_launch = candidate.duplicate(true)
			break
	if not delayed_owner_launch.is_empty():
		delayed_owner_launch[10] = float(peer_clear_chunks[0][3]) + 1.0
		_apply_launch_payload(client_coordinator, delayed_owner_launch)
	var older_first_chunk_accepted := _apply_chunk(
		client_coordinator,
		peer_clear_older_chunks[0]
	)
	var newer_peer_clear_snapshot_accepted := true
	for chunk_index in range(peer_clear_chunks.size()):
		newer_peer_clear_snapshot_accepted = (
			_apply_chunk(client_coordinator, peer_clear_chunks[chunk_index])
			and newer_peer_clear_snapshot_accepted
		)
	var replaced_older_chunks_rejected := true
	for chunk_index in range(1, peer_clear_older_chunks.size()):
		replaced_older_chunks_rejected = (
			not _apply_chunk(
				client_coordinator,
				peer_clear_older_chunks[chunk_index]
			)
			and replaced_older_chunks_rejected
		)
	_expect(
		int(client_coordinator.get_state_metrics()[
			"pending_capoo_data_snapshots"
		]) == 0
		and older_first_chunk_accepted
		and newer_peer_clear_snapshot_accepted
		and replaced_older_chunks_rejected
		and not delayed_owner_launch.is_empty()
		and not client_coordinator.has_capoo_rpg_replica(
			int(delayed_owner_launch[0])
		)
		and int(host_coordinator.get_state_metrics()["known_capoo_mage_data"]) == 0
		and int(host_coordinator.get_state_metrics()["known_capoo_rpg_data"]) == 1
		and int(client_coordinator.get_state_metrics()[
			"known_capoo_mage_replicas"
		]) == 0
		and int(client_coordinator.get_state_metrics()[
			"known_capoo_rpg_replicas"
		]) == 1
		and host_coordinator.has_capoo_rpg_data(unrelated_projectile_id)
		and client_coordinator.has_capoo_rpg_replica(unrelated_projectile_id)
		and int(client_coordinator.get_state_metrics()[
			"cleared_capoo_data_owner_peers"
		]) == 1,
		"A clear before the first chunk must reject later owner launches; a newer snapshot must inherit the owner tombstone, replace the partial batch, and preserve unrelated enemy-owned DATA."
	)
	host_coordinator.mark_capoo_data_owner_active(OWNER_PEER_ID)
	client_coordinator.mark_capoo_data_owner_active(OWNER_PEER_ID)
	_expect(
		int(host_coordinator.get_state_metrics()[
			"cleared_capoo_data_owner_peers"
		]) == 0
		and int(client_coordinator.get_state_metrics()[
			"cleared_capoo_data_owner_peers"
		]) == 0,
		"An explicit rejoin must clear only the new active owner's lifecycle tombstone."
	)

	var reset_source := _make_source(MAGE_TYPE, 2000)
	var reset_data_handle := _spawn_mage(mage_service, reset_source, peer_target)
	var reset_projectile_id := _register_mage(
		host_coordinator, mage_service, reset_data_handle, reset_source,
		TARGET_PEER_ID, 0
	)
	_snapshot(host_coordinator)
	_expect(
		_apply_chunks(client_coordinator, snapshot_chunks),
		"The final reset fixture snapshot must apply."
	)
	var reset_replica_handle := _find_mage_handle(
		mage_service, reset_projectile_id, MageServiceScript.Mode.REPLICA
	)
	host_coordinator.reset_session_state()
	client_coordinator.reset_session_state()
	_expect(
		not mage_service.is_handle_live(reset_data_handle)
		and not mage_service.is_handle_live(reset_replica_handle)
		and mage_service.get_live_count() == 0
		and rpg_service.get_live_count() == 0
		and int(client_coordinator.get_state_metrics()[
			"pending_capoo_data_snapshots"
		]) == 0
		and int(client_coordinator.get_state_metrics()[
			"capoo_mage_replica_target_records"
		]) == 0
		and int(client_coordinator.get_state_metrics()[
			"pending_capoo_mage_replica_targets"
		]) == 0,
		"Session reset must release every handle and clear snapshot/target metadata."
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
	_finish()


func _snapshot(coordinator: MpProjectileCoordinator) -> void:
	snapshot_chunks.clear()
	_expect(
		coordinator.send_active_data_visual_snapshot_to_peer(77),
		"Host late-join snapshot dispatch must succeed."
	)


func _make_net_manager(role: NetManagerStore.NetRole) -> NetManagerStore:
	var net_manager := NetManagerStore.new()
	net_manager.net_role = role
	net_manager.connection_state = NetManagerStore.ConnectionState.IN_GAME
	return net_manager


func _make_coordinator(
	runtime: EnemyGameplayGatewayTestRuntime,
	player_coordinator: MpPlayerCoordinator,
	net_manager: NetManagerStore
) -> MpProjectileCoordinator:
	var coordinator := COORDINATOR_SCENE.instantiate() as MpProjectileCoordinator
	var event_age_provider := (
		Callable(self, &"_get_simulated_client_event_age")
		if net_manager.net_role == NetManagerStore.NetRole.CLIENT
		else Callable(self, &"_get_zero_event_age")
	)
	coordinator.bind_runtime(runtime)
	coordinator.bind_network_facade_dependencies(
		net_manager,
		player_coordinator,
		func() -> float: return HOST_TIME,
		event_age_provider,
		func(_peer_id: int) -> bool: return false
	)
	return coordinator


func _get_simulated_client_event_age(_host_timestamp: float) -> float:
	return simulated_client_event_age


func _get_zero_event_age(_host_timestamp: float) -> float:
	return 0.0


func _spawn_mage(
	service: MageServiceScript,
	source: DamageSourceSnapshot,
	target: Node2D
) -> int:
	return service.spawn_authoritative(
		SPAWN_POSITION,
		DIRECTION,
		DAMAGE,
		MAGE_SPEED,
		LIFETIME,
		MageServiceScript.DEFAULT_RADIUS,
		target,
		MageServiceScript.DEFAULT_HOMING_TURN_RATE,
		source,
		MageServiceScript.Profile.NORMAL
	)


func _spawn_rpg(
	service: RPGServiceScript,
	source: DamageSourceSnapshot
) -> int:
	return service.spawn_authoritative(
		0,
		SPAWN_POSITION,
		DIRECTION,
		DAMAGE,
		RPG_SPEED,
		LIFETIME,
		RPGServiceScript.DEFAULT_EXPLOSION_RADIUS,
		source
	)


func _spawn_rpg_replica_backlog(
	service: RPGServiceScript,
	count: int
) -> bool:
	var source := _make_source(RPG_TYPE, 8101)
	for index in range(count):
		var handle := service.spawn_replica(
			50_000_000 + index,
			SPAWN_POSITION,
			DIRECTION,
			RPG_SPEED,
			COMPLETION_BACKLOG_LIFETIME,
			RPGServiceScript.DEFAULT_EXPLOSION_RADIUS,
			0.0,
			source
		)
		if handle <= RPGServiceScript.INVALID_HANDLE:
			return false
	return true


func _spawn_mage_replica_backlog(
	service: MageServiceScript,
	count: int
) -> bool:
	var source := _make_source(MAGE_TYPE, 8102)
	for index in range(count):
		var handle := service.spawn_replica(
			60_000_000 + index,
			SPAWN_POSITION,
			DIRECTION,
			MAGE_SPEED,
			COMPLETION_BACKLOG_LIFETIME,
			MageServiceScript.DEFAULT_RADIUS,
			null,
			MageServiceScript.DEFAULT_HOMING_TURN_RATE,
			0.0,
			MageServiceScript.Profile.NORMAL,
			source
		)
		if handle <= MageServiceScript.INVALID_HANDLE:
			return false
	return true


func _register_mage(
	coordinator: MpProjectileCoordinator,
	service: MageServiceScript,
	handle: int,
	source: DamageSourceSnapshot,
	target_peer_id: int,
	target_world_net_id: int
) -> int:
	return coordinator.register_local_capoo_mage_fireball_data(
		service,
		handle,
		MAGE_TYPE,
		OWNER_PEER_ID,
		SPAWN_POSITION,
		DIRECTION,
		DAMAGE,
		MAGE_SPEED,
		LIFETIME,
		target_peer_id,
		target_world_net_id,
		source
	)


func _register_rpg(
	coordinator: MpProjectileCoordinator,
	service: RPGServiceScript,
	handle: int,
	source: DamageSourceSnapshot,
	owner_peer_id: int = OWNER_PEER_ID
) -> int:
	return coordinator.register_local_capoo_rpg_data(
		service,
		handle,
		RPG_TYPE,
		owner_peer_id,
		SPAWN_POSITION,
		DIRECTION,
		DAMAGE,
		RPG_SPEED,
		LIFETIME,
		source
	)


func _make_source(
	projectile_type: StringName,
	instigator_id: int
) -> DamageSourceSnapshot:
	return DamageSourceSnapshot.create(
		CombatRelationService.HOSTILE_WAVE,
		0,
		instigator_id,
		0,
		projectile_type
	)


func _decode_complete_snapshot(chunks: Array[Array]) -> Array[Dictionary]:
	var records: Array[Dictionary] = []
	if chunks.is_empty():
		return records
	var ordered := chunks.duplicate(true)
	ordered.sort_custom(
		func(a: Array, b: Array) -> bool: return int(a[1]) < int(b[1])
	)
	var expected_snapshot_id := int(ordered[0][0])
	var expected_chunk_count := int(ordered[0][2])
	var expected_snapshot_timestamp := float(ordered[0][3])
	for chunk in ordered:
		if (
			chunk.size() != 5
			or int(chunk[0]) != expected_snapshot_id
			or int(chunk[2]) != expected_chunk_count
			or not is_finite(expected_snapshot_timestamp)
			or expected_snapshot_timestamp < HOST_TIME
			or float(chunk[3]) != expected_snapshot_timestamp
		):
			return []
		if expected_chunk_count == 0:
			continue
		var decoded := Codec.decode_chunk(chunk[4] as PackedByteArray)
		if not bool(decoded.get("valid", false)):
			return []
		for record_variant in decoded.get("records", []) as Array:
			records.append(record_variant as Dictionary)
	return records


func _apply_chunks(
	coordinator: MpProjectileCoordinator,
	chunks: Array[Array]
) -> bool:
	var accepted := true
	for chunk in chunks:
		accepted = _apply_chunk(coordinator, chunk) and accepted
	return accepted


func _apply_chunk(
	coordinator: MpProjectileCoordinator,
	chunk: Array
) -> bool:
	return (
		chunk.size() == 5
		and coordinator.apply_authority_capoo_data_projectile_snapshot_chunk(
			1,
			int(chunk[0]),
			int(chunk[1]),
			int(chunk[2]),
			float(chunk[3]),
			chunk[4] as PackedByteArray
		)
	)


func _apply_launch_payload(
	coordinator: MpProjectileCoordinator,
	payload: Array
) -> void:
	if payload.size() != 17:
		return
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


func _is_current_record(
	record: Dictionary,
	service: Node,
	handle: int,
	family: int,
	target_peer_id: int,
	target_world_net_id: int
) -> bool:
	var source: DamageSourceSnapshot = service.call("get_damage_source_snapshot", handle)
	var record_direction := record.get("direction", Vector2.ZERO) as Vector2
	var service_direction: Vector2 = service.call("get_direction", handle)
	return (
		source != null
		and int(record.get("family", 0)) == family
		and int(record.get("owner_peer_id", 0)) == OWNER_PEER_ID
		and (record.get("position", Vector2.ZERO) as Vector2).distance_to(
			service.call("get_position", handle) as Vector2
		) < 0.05
		and record_direction.normalized().dot(service_direction.normalized()) > 0.999
		and int(record.get("damage", -1)) == int(service.call("get_damage", handle))
		and is_equal_approx(
			float(record.get("speed", 0.0)),
			float(service.call("get_speed", handle))
		)
		and is_equal_approx(
			float(record.get("remaining_lifetime", 0.0)),
			float(service.call("get_remaining_lifetime", handle))
		)
		and is_equal_approx(
			float(record.get("visual_age", -1.0)),
			float(service.call("get_visual_age", handle))
		)
		and int(record.get("target_peer_id", -1)) == target_peer_id
		and int(record.get("target_enemy_net_id", -1)) == target_world_net_id
		and int(record.get("source_faction_id", -1)) == source.source_faction_id
		and int(record.get("source_credit_peer_id", -1)) == source.credit_peer_id
		and int(record.get("source_instigator_entity_id", -1))
			== source.instigator_entity_id
		and int(record.get("source_event_id", -1))
			== int(record.get("projectile_id", 0))
		and StringName(record.get("source_type", &"")) == source.source_type
	)


func _records_match_ids(records: Array[Dictionary], expected_ids: Array[int]) -> bool:
	if records.size() != expected_ids.size():
		return false
	var sorted_ids := expected_ids.duplicate()
	sorted_ids.sort()
	for record_index in range(records.size()):
		if int(records[record_index].get("projectile_id", 0)) != sorted_ids[record_index]:
			return false
	return true


func _chunks_within_budget(chunks: Array[Array]) -> bool:
	for chunk in chunks:
		var descriptor := chunk[4] as PackedByteArray
		var estimated_rpc_packet_bytes := var_to_bytes(chunk).size() + 16
		if (
			descriptor.size() > Codec.MAX_PAYLOAD_BYTES
			or estimated_rpc_packet_bytes > 1200
		):
			return false
	return true


func _all_replica_damage_is_zero(
	mage_service: MageServiceScript,
	rpg_service: RPGServiceScript
) -> bool:
	for stable_index in range(mage_service.get_dense_record_count()):
		var handle := mage_service.get_handle_at_stable_index(stable_index)
		if (
			handle > MageServiceScript.INVALID_HANDLE
			and mage_service.get_slot_mode(handle) == MageServiceScript.Mode.REPLICA
			and mage_service.get_damage(handle) != 0
		):
			return false
	for stable_index in range(rpg_service.get_dense_record_count()):
		var handle := rpg_service.get_handle_at_stable_index(stable_index)
		if (
			handle > RPGServiceScript.INVALID_HANDLE
			and rpg_service.get_slot_mode(handle) == RPGServiceScript.Mode.REPLICA
			and rpg_service.get_damage(handle) != 0
		):
			return false
	return true


func _find_mage_handle(
	service: MageServiceScript,
	projectile_id: int,
	mode: MageServiceScript.Mode
) -> int:
	for stable_index in range(service.get_dense_record_count()):
		var handle := service.get_handle_at_stable_index(stable_index)
		if (
			handle > MageServiceScript.INVALID_HANDLE
			and service.get_projectile_id(handle) == projectile_id
			and service.get_slot_mode(handle) == mode
		):
			return handle
	return MageServiceScript.INVALID_HANDLE


func _find_rpg_handle(
	service: RPGServiceScript,
	projectile_id: int,
	mode: RPGServiceScript.Mode
) -> int:
	for stable_index in range(service.get_dense_record_count()):
		var handle := service.get_handle_at_stable_index(stable_index)
		if (
			handle > RPGServiceScript.INVALID_HANDLE
			and service.get_projectile_id(handle) == projectile_id
			and service.get_slot_mode(handle) == mode
		):
			return handle
	return RPGServiceScript.INVALID_HANDLE


func _count_legacy_nodes(node: Node) -> int:
	var count := 1 if node is CapooMageFireball or node is CapooRPGRocket else 0
	for child in node.get_children():
		count += _count_legacy_nodes(child)
	return count


func _finish() -> void:
	var result := {
		"status": "ok" if failures.is_empty() else "failed",
		"failures": failures.duplicate(),
	}
	print("CAPOO_DATA_LATE_JOIN_SNAPSHOT_JSON %s" % JSON.stringify(result))
	if failures.is_empty():
		print("CAPOO_DATA_LATE_JOIN_SNAPSHOT_SMOKE_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
