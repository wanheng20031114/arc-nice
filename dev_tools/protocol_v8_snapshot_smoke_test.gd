extends SceneTree

const NetConstants := preload("res://scene/multiplayer/net_constants.gd")
const SnapshotManager := preload("res://scene/multiplayer/snapshot_manager.gd")
const MpGameScript := preload("res://scene/multiplayer/mp_game.gd")
const BULLET_SCENE := preload("res://scene/bullet.tscn")
const TOWER_DEFENSE_RUNTIME_PATH := "res://scene/game_tower_defense.gd"
const PROJECTILE_SEQUENCE_MAX: int = 0xFFFFFFFF
const PROJECTILE_HOST_ORIGIN_BIT: int = 0x80000000
const PROJECTILE_SEQUENCE_COUNTER_MAX: int = 0x7FFFFFFF


class TerrainClientNetManagerStub:
	extends Node

	func is_host() -> bool:
		return false

	func is_client() -> bool:
		return true


class TerrainRuntimeStub:
	extends "res://scene/game_tower_defense.gd"

	var snapshot_revisions: Array[int] = []
	var delta_revisions: Array[int] = []
	var accept_snapshot := true
	var accept_delta := true

	func supports_multiplayer_terrain_state() -> bool:
		return true

	func apply_remote_terrain_snapshot(
		revision: int,
		_cell_xy: PackedInt32Array,
		_terrain_types: PackedInt32Array
	) -> bool:
		if not accept_snapshot:
			return false
		snapshot_revisions.append(revision)
		return true

	func apply_remote_terrain_delta(
		revision: int,
		_cell_xy: PackedInt32Array,
		_terrain_types: PackedInt32Array
	) -> bool:
		if not accept_delta:
			return false
		delta_revisions.append(revision)
		return true


class TerrainRepairMpGame:
	extends "res://scene/multiplayer/mp_game.gd"

	var repair_request_count := 0

	func _request_terrain_snapshot_repair() -> void:
		if bool(get("_client_waiting_for_terrain_snapshot")):
			return
		set("_client_waiting_for_terrain_snapshot", true)
		repair_request_count += 1


class TerrainWatchdogMpGame:
	extends "res://scene/multiplayer/mp_game.gd"

	var repair_request_count := 0

	func _transmit_terrain_snapshot_repair_request() -> void:
		repair_request_count += 1


class BambooBatchRecordingMpGame:
	extends "res://scene/multiplayer/mp_game.gd"

	var outbound_calls: Array[Dictionary] = []

	func _rpc_to_connected_clients(
		method_name: StringName,
		args: Array = []
	) -> void:
		outbound_calls.append({
			"method_name": method_name,
			"args": args.duplicate(true),
		})


var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_channel_contract()
	_test_v25_high_value_player_snapshot_contract()
	_test_terrain_payload_contract()
	_test_terrain_delta_revision_repair_contract()
	_test_terrain_snapshot_repair_watchdog_contract()
	_test_bamboo_mortar_payload_contract()
	_test_corn_burst_payload_contract()
	_test_projectile_id_codec_contract()
	_test_projectile_origin_lane_runtime_contract()
	_test_linglan_skill1_ring_payload_contract()
	_test_runtime_state_send_order()
	_test_plant_removal_restore_order()
	_test_player_codec_and_reuse()
	_test_shared_snapshot_cohort_lifecycle()
	_test_enemy_codec_reuse_and_packet_budget()
	if failures.is_empty():
		print("PROTOCOL_V26_SNAPSHOT_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_channel_contract() -> void:
	_expect(NetConstants.PROTOCOL_VERSION == 26, "Protocol must be v26.")
	_expect(
		NetConstants.NETWORK_COMBAT_VALUE_MIN == 0
		and NetConstants.NETWORK_COMBAT_VALUE_MAX == 0x7FFFFFFF,
		"Fixed-width network combat values must use the signed-int32 nonnegative range."
	)
	_expect(NetConstants.CHANNEL_COUNT == 8, "ENet must provision eight channels.")
	_expect(NetConstants.MAX_PLAYERS == 8, "Protocol capacity must accept an eight-player roster.")
	_expect(
		NetConstants.CH_AUTH == 0
		and NetConstants.CH_INPUT == 1
		and NetConstants.CH_PLAYER_STATE == 2
		and NetConstants.CH_ENEMY_STATE == 3
		and NetConstants.CH_PROJECTILE == 4
		and NetConstants.CH_WORLD_EVENT == 5
		and NetConstants.CH_TRANSACTION == 6
		and NetConstants.CH_FEEDBACK == 7,
		"Protocol v26 channel assignments must remain stable."
	)


func _test_v25_high_value_player_snapshot_contract() -> void:
	var health_boundaries: Array[int] = [
		32767,
		32768,
		65535,
		100000,
		NetConstants.NETWORK_COMBAT_VALUE_MAX,
	]
	for health_value in health_boundaries:
		var state := SnapshotManager.PlayerState.new()
		state.peer_id = 2
		state.sequence = health_boundaries.find(health_value) + 1
		state.position = Vector2(8192.0, 8192.0)
		state.current_health = health_value
		state.max_health = health_value
		var packet := SnapshotManager.new().encode_all_player_snapshots([state])
		var decoded := SnapshotManager.decode_all_player_snapshots(packet)
		_expect(
			decoded.size() == 1
			and decoded[0].current_health == health_value
			and decoded[0].max_health == health_value,
			"Player health %d must round-trip as signed int32." % health_value
		)
		_expect(
			decoded.size() == 1
			and decoded[0].position == Vector2(8192.0, 8192.0),
			"Xiaocong-room player positions must round-trip without int16 saturation."
		)

	var full_roster: Array[SnapshotManager.PlayerState] = []
	for peer_id in range(1, NetConstants.MAX_PLAYERS + 1):
		var roster_state := SnapshotManager.PlayerState.new()
		roster_state.peer_id = peer_id
		roster_state.sequence = 1
		roster_state.position = Vector2(8192.0 + peer_id, 8192.0 - peer_id)
		roster_state.current_health = 100000
		roster_state.max_health = 100000
		full_roster.append(roster_state)
	var full_packet := SnapshotManager.new().encode_all_player_snapshots(full_roster)
	_expect(
		full_packet.size() == 553,
		"Eight full v25 player snapshots must use exactly 553 bytes. actual=%d"
		% full_packet.size()
	)

	var invalid_negative := SnapshotManager.PlayerState.new()
	invalid_negative.current_health = -1
	invalid_negative.max_health = 100
	var invalid_overflow := SnapshotManager.PlayerState.new()
	invalid_overflow.current_health = 100
	invalid_overflow.max_health = NetConstants.NETWORK_COMBAT_VALUE_MAX + 1
	_expect(
		not SnapshotManager.is_player_snapshot_state_serializable(invalid_negative)
		and not SnapshotManager.is_player_snapshot_state_serializable(invalid_overflow),
		"Player snapshot serialization must reject negative and signed-int32-overflow health."
	)
	var invalid_enemy := SnapshotManager.EnemyState.new()
	invalid_enemy.health = NetConstants.NETWORK_COMBAT_VALUE_MAX + 1
	_expect(
		not SnapshotManager.is_enemy_snapshot_state_serializable(invalid_enemy),
		"Enemy snapshot serialization must reject signed-int32-overflow health."
	)


func _test_terrain_delta_revision_repair_contract() -> void:
	var mp_game := TerrainRepairMpGame.new()
	var runtime := TerrainRuntimeStub.new()
	var net_stub := TerrainClientNetManagerStub.new()
	mp_game.set("game", runtime)
	mp_game.set("net_manager", net_stub)
	var cell_xy := PackedInt32Array([4, 7])
	var grass := PackedInt32Array([2])
	var dirt := PackedInt32Array([1])

	mp_game.call("net_terrain_delta", 1, cell_xy, grass)
	_expect(
		mp_game.repair_request_count == 1
		and runtime.delta_revisions.is_empty()
		and int(mp_game.get("_client_terrain_revision")) == -1,
		"A delta before the first snapshot must request repair without mutating terrain."
	)

	mp_game.call("net_terrain_snapshot_chunk", 1, 5, 0, 1, cell_xy, grass)
	_expect(
		runtime.snapshot_revisions == [5]
		and bool(mp_game.get("_client_has_terrain_snapshot"))
		and not bool(mp_game.get("_client_waiting_for_terrain_snapshot"))
		and int(mp_game.get("_client_terrain_revision")) == 5,
		"A complete snapshot must apply atomically and establish the client revision."
	)

	mp_game.call("net_terrain_delta", 5, cell_xy, dirt)
	_expect(
		runtime.delta_revisions.is_empty()
		and mp_game.repair_request_count == 1,
		"A stale or duplicate terrain delta must be ignored without requesting repair."
	)
	mp_game.call("net_terrain_delta", 7, cell_xy, dirt)
	mp_game.call("net_terrain_delta", 6, cell_xy, dirt)
	_expect(
		runtime.delta_revisions.is_empty()
		and mp_game.repair_request_count == 2
		and bool(mp_game.get("_client_waiting_for_terrain_snapshot"))
		and int(mp_game.get("_client_terrain_revision")) == 5,
		"A revision gap must request one repair and reject later deltas while waiting."
	)

	mp_game.call("net_terrain_snapshot_chunk", 2, 7, 0, 1, cell_xy, dirt)
	mp_game.call("net_terrain_delta", 8, cell_xy, grass)
	_expect(
		runtime.snapshot_revisions == [5, 7]
		and runtime.delta_revisions == [8]
		and int(mp_game.get("_client_terrain_revision")) == 8,
		"After repair, exactly the next revision must apply once and advance the client."
	)

	runtime.accept_delta = false
	mp_game.call("net_terrain_delta", 9, cell_xy, dirt)
	_expect(
		runtime.delta_revisions == [8]
		and mp_game.repair_request_count == 3
		and int(mp_game.get("_client_terrain_revision")) == 8,
		"A runtime-rejected delta must preserve the prior revision and request repair."
	)
	mp_game.free()
	runtime.free()
	net_stub.free()


func _test_terrain_snapshot_repair_watchdog_contract() -> void:
	var mp_game := TerrainWatchdogMpGame.new()
	var runtime := TerrainRuntimeStub.new()
	var net_stub := TerrainClientNetManagerStub.new()
	mp_game.set("game", runtime)
	mp_game.set("net_manager", net_stub)

	mp_game.call("_request_terrain_snapshot_repair")
	mp_game.call("_request_terrain_snapshot_repair")
	_expect(
		mp_game.repair_request_count == 1
		and bool(mp_game.get("_client_waiting_for_terrain_snapshot")),
		"Terrain repair must send one request while a snapshot is already pending."
	)
	mp_game.call("_update_terrain_snapshot_repair_watchdog", 1.99)
	_expect(
		mp_game.repair_request_count == 1,
		"Terrain repair watchdog must not retry before its conservative timeout."
	)
	mp_game.call("_update_terrain_snapshot_repair_watchdog", 0.02)
	_expect(
		mp_game.repair_request_count == 2,
		"Terrain repair watchdog must retry a silent or Host-rate-limited request."
	)
	for _frame_index in range(60):
		mp_game.call("_update_terrain_snapshot_repair_watchdog", 1.0 / 60.0)
	_expect(
		mp_game.repair_request_count == 2,
		"Terrain repair watchdog must not create a per-frame request storm."
	)

	var first_chunk_xy := PackedInt32Array()
	var first_chunk_types := PackedInt32Array()
	for cell_x in range(96):
		first_chunk_xy.append(cell_x)
		first_chunk_xy.append(0)
		first_chunk_types.append(1)
	mp_game.call(
		"net_terrain_snapshot_chunk",
		41,
		0,
		0,
		2,
		first_chunk_xy,
		first_chunk_types
	)
	mp_game.call("_update_terrain_snapshot_repair_watchdog", 1.99)
	_expect(
		mp_game.repair_request_count == 2,
		"Every valid terrain chunk must rearm the watchdog while assembly progresses."
	)
	mp_game.call("_update_terrain_snapshot_repair_watchdog", 0.02)
	_expect(
		mp_game.repair_request_count == 3
		and (mp_game.get("_pending_terrain_snapshot_batches") as Dictionary).is_empty(),
		"A stalled partial terrain snapshot must be discarded before retrying."
	)

	mp_game.call(
		"net_terrain_snapshot_chunk",
		42,
		0,
		0,
		2,
		first_chunk_xy,
		first_chunk_types
	)
	mp_game.call("_update_terrain_snapshot_repair_watchdog", 1.5)
	var last_chunk_xy := PackedInt32Array([96, 0])
	var last_chunk_types := PackedInt32Array([1])
	mp_game.call(
		"net_terrain_snapshot_chunk",
		42,
		0,
		1,
		2,
		last_chunk_xy,
		last_chunk_types
	)
	_expect(
		runtime.snapshot_revisions == [0]
		and not bool(mp_game.get("_client_waiting_for_terrain_snapshot"))
		and is_zero_approx(float(mp_game.get(
			"_terrain_snapshot_repair_watchdog_time_left"
		))),
		"A complete terrain snapshot must cancel the repair watchdog."
	)
	mp_game.call("_update_terrain_snapshot_repair_watchdog", 10.0)
	_expect(
		mp_game.repair_request_count == 3,
		"A completed terrain snapshot must not trigger a later watchdog retry."
	)
	mp_game.free()
	runtime.free()
	net_stub.free()


func _test_player_codec_and_reuse() -> void:
	var sender := SnapshotManager.new()
	var receiver := SnapshotManager.new()
	var state := SnapshotManager.PlayerState.new()
	state.peer_id = 2
	state.sequence = 1
	state.character_id = &"tiyi"
	state.position = Vector2(12.3, -45.6)
	state.velocity = Vector2(2.0, -3.0)
	state.current_health = 48
	state.max_health = 50
	state.ammo_capacity = 7
	state.current_ammo = 4
	state.effective_move_speed_multiplier = 1.375
	var keyframe := sender.encode_player_snapshots_for_peer(8, [state], true)
	var decoded_keyframe := receiver.decode_player_snapshots_with_baseline(keyframe)
	_expect(decoded_keyframe.size() == 1, "Player keyframe must decode.")
	if decoded_keyframe.is_empty():
		return
	_expect(
		absf(decoded_keyframe[0].effective_move_speed_multiplier - 1.375) <= 0.001,
		"Authoritative movement multiplier must round-trip at 0.001 precision."
	)
	state.sequence = 2
	state.position.x += 1.0
	var delta := sender.encode_player_snapshots_for_peer(8, [state], false)
	var decoded_delta := receiver.decode_player_snapshots_with_baseline(delta)
	_expect(
		decoded_delta.size() == 1
		and is_same(decoded_keyframe[0], decoded_delta[0])
		and decoded_delta[0].position.distance_to(state.position) <= 0.11,
		"Player delta output must reuse the per-peer object and preserve its baseline."
	)
	receiver.reset_delta_cache()
	_expect(
		receiver.player_receive_baselines.is_empty()
		and receiver.player_receive_output_states.is_empty(),
		"Player reset must release baseline and output-object caches."
	)


func _test_shared_snapshot_cohort_lifecycle() -> void:
	const cohort_id := -1
	var sender := SnapshotManager.new()
	var player_state := SnapshotManager.PlayerState.new()
	player_state.peer_id = 2
	player_state.sequence = 1
	player_state.position = Vector2(8.0, 12.0)
	player_state.velocity = Vector2.RIGHT * 4.0
	player_state.current_health = 90
	player_state.max_health = 100
	var keyframe := sender.encode_player_snapshots_for_cohort(
		cohort_id,
		[player_state],
		true
	)
	var receivers: Array[SnapshotManager] = []
	for _peer_index in range(3):
		var receiver := SnapshotManager.new()
		receivers.append(receiver)
		var decoded := receiver.decode_player_snapshots_with_baseline(keyframe)
		_expect(
			decoded.size() == 1
			and decoded[0].peer_id == player_state.peer_id
			and decoded[0].position.distance_to(player_state.position) <= 0.11,
			"Every member must decode the same shared player keyframe."
		)
	player_state.sequence = 2
	player_state.position += Vector2(3.0, -2.0)
	var delta := sender.encode_player_snapshots_for_cohort(
		cohort_id,
		[player_state],
		false
	)
	for receiver in receivers:
		var decoded := receiver.decode_player_snapshots_with_baseline(delta)
		_expect(
			decoded.size() == 1
			and decoded[0].position.distance_to(player_state.position) <= 0.11,
			"Every member must restore an identical delta from the shared baseline."
		)
	_expect(
		sender.player_send_baselines_by_peer.size() == 1
		and sender.player_send_baselines_by_peer.has(cohort_id),
		"One shared cohort must retain one player baseline instead of one per member."
	)

	var mp_game := MpGameScript.new()
	var cohort_peers := mp_game.get("_player_snapshot_cohort_peers") as Dictionary
	var keyframe_times := mp_game.get("_last_player_keyframe_time_by_peer") as Dictionary
	var ready_peers: Array[int] = [2, 3, 4]
	mp_game.call(
		"_commit_snapshot_cohort_send",
		cohort_peers,
		keyframe_times,
		ready_peers,
		0.0,
		true
	)
	var mp_snapshot_mgr := mp_game.get("snapshot_mgr") as SnapshotManager
	mp_snapshot_mgr.encode_player_snapshots_for_cohort(
		cohort_id,
		[player_state],
		true
	)
	var enemy_state := SnapshotManager.EnemyState.new()
	enemy_state.net_id = 11
	enemy_state.position = Vector2(20.0, 30.0)
	mp_snapshot_mgr.encode_enemy_snapshot_range_for_cohort(
		cohort_id,
		[enemy_state],
		0,
		1,
		true
	)
	var enemy_cohort_peers := mp_game.get("_enemy_snapshot_cohort_peers") as Dictionary
	var enemy_keyframe_times := mp_game.get("_last_enemy_keyframe_time_by_peer") as Dictionary
	mp_game.call(
		"_commit_snapshot_cohort_send",
		enemy_cohort_peers,
		enemy_keyframe_times,
		ready_peers,
		0.0,
		true
	)

	var temporarily_ready: Array[int] = [2, 4]
	mp_game.call("_sync_snapshot_cohort_readiness", temporarily_ready)
	_expect(
		cohort_peers.size() == 2
		and cohort_peers.has(2)
		and cohort_peers.has(4)
		and not cohort_peers.has(3)
		and not keyframe_times.has(3),
		"A send-unready peer must detach immediately without disturbing ready members."
	)
	_expect(
		not bool(mp_game.call(
			"_snapshot_cohort_requires_keyframe",
			cohort_peers,
			keyframe_times,
			temporarily_ready,
			0.25,
			0.5
		)),
		"The remaining continuously-ready members must keep using their shared delta."
	)
	var same_size_replacement: Array[int] = [2, 5]
	_expect(
		bool(mp_game.call(
			"_snapshot_cohort_requires_keyframe",
			cohort_peers,
			keyframe_times,
			same_size_replacement,
			0.25,
			0.5
		)),
		"Replacing one member must force a keyframe even when cohort size is unchanged."
	)
	_expect(
		bool(mp_game.call(
			"_snapshot_cohort_requires_keyframe",
			cohort_peers,
			keyframe_times,
			ready_peers,
			0.25,
			0.5
		)),
		"A recovered peer must force a full frame before rejoining the cohort."
	)
	mp_game.call(
		"_commit_snapshot_cohort_send",
		cohort_peers,
		keyframe_times,
		ready_peers,
		0.25,
		true
	)
	_expect(
		cohort_peers.size() == 3
		and is_equal_approx(float(keyframe_times.get(3, -1.0)), 0.25),
		"A shared recovery keyframe must atomically readmit every ready member."
	)
	_expect(
		bool(mp_game.call(
			"_snapshot_cohort_requires_keyframe",
			cohort_peers,
			keyframe_times,
			ready_peers,
			0.75,
			0.5
		)),
		"A stable cohort must still emit its periodic 0.5-second keyframe."
	)

	mp_game.call("_clear_peer_network_state", 3)
	_expect(
		not cohort_peers.has(3)
		and not enemy_cohort_peers.has(3)
		and not keyframe_times.has(3)
		and not enemy_keyframe_times.has(3)
		and mp_snapshot_mgr.player_send_baselines_by_peer.has(cohort_id)
		and mp_snapshot_mgr.enemy_send_baselines_by_peer.has(cohort_id),
		"Disconnect cleanup must detach one member while preserving a live shared baseline."
	)
	var no_ready_peers: Array[int] = []
	mp_game.call("_sync_snapshot_cohort_readiness", no_ready_peers)
	_expect(
		cohort_peers.is_empty()
		and enemy_cohort_peers.is_empty()
		and not mp_snapshot_mgr.player_send_baselines_by_peer.has(cohort_id)
		and not mp_snapshot_mgr.enemy_send_baselines_by_peer.has(cohort_id),
		"An empty cohort must release both shared send baselines."
	)
	var empty_enemy_packet := mp_snapshot_mgr.encode_enemy_snapshot_range_for_cohort(
		cohort_id,
		[],
		0,
		0,
		true
	)
	_expect(
		empty_enemy_packet.size() == 2
		and SnapshotManager.decode_all_enemy_snapshots(empty_enemy_packet).is_empty(),
		"An empty enemy cohort frame must remain a valid zero-roster packet."
	)
	mp_game.free()


func _test_terrain_payload_contract() -> void:
	var mp_game := MpGameScript.new()
	var cell_xy := PackedInt32Array([0, 0, 1, -2, 5, 7])
	var terrain_types := PackedInt32Array([-1, 1, 2])
	_expect(
		bool(mp_game.call("_is_valid_terrain_payload", cell_xy, terrain_types, 96)),
		"Terrain payloads must preserve EMPTY=-1 alongside grass and dirt."
	)
	_expect(
		not bool(mp_game.call(
			"_is_valid_terrain_payload",
			PackedInt32Array([0, 0, 0, 0]),
			PackedInt32Array([1, 2]),
			96
		)),
		"Terrain payloads must reject duplicate coordinates."
	)
	var maximum_cell_xy := PackedInt32Array()
	var maximum_types := PackedInt32Array()
	for cell_index in range(97):
		maximum_cell_xy.append(cell_index)
		maximum_cell_xy.append(0)
		maximum_types.append(1)
	_expect(
		not bool(mp_game.call(
			"_is_valid_terrain_payload",
			maximum_cell_xy,
			maximum_types,
			96
		)),
		"Terrain chunks must reject a 97th cell."
	)
	mp_game.free()


func _test_bamboo_mortar_payload_contract() -> void:
	var mp_game := MpGameScript.new()
	_expect(
		int(mp_game.call(
			"_get_rpc_traffic_channel",
			&"net_bamboo_mortar_visual_batch"
		)) == NetConstants.CH_WORLD_EVENT,
		"Bamboo mortar visual traffic must share ordered CH_WORLD_EVENT with plant lifecycle."
	)
	var mp_game_source := FileAccess.get_file_as_string(
		"res://scene/multiplayer/mp_game.gd"
	)
	_expect(
		mp_game_source.contains(
			"const BAMBOO_MORTAR_VISUAL_FLUSH_INTERVAL_SECONDS := 0.05"
		)
		and mp_game_source.contains(
			"const BAMBOO_MORTAR_VISUAL_MAX_RECORDS_PER_PACKET := 24"
		)
		and mp_game_source.contains(
			'@rpc("authority", "call_remote", "reliable", 5)\nfunc net_bamboo_mortar_visual_batch'
		),
		"Bamboo mortar visuals must flush every 0.05 seconds in reliable CH_WORLD_EVENT packets of at most 24."
	)
	var removal_function_index := mp_game_source.find(
		"func _on_host_plant_removed"
	)
	var removal_flush_index := mp_game_source.find(
		"_flush_bamboo_mortar_visuals()",
		removal_function_index
	)
	var removal_rpc_index := mp_game_source.find(
		'_rpc_to_connected_clients(&"net_plant_removed"',
		removal_function_index
	)
	_expect(
		removal_function_index >= 0
		and removal_flush_index > removal_function_index
		and removal_rpc_index > removal_flush_index,
		"Host must flush Bamboo visual records before sending plant removal on the same ordered channel."
	)
	_expect(
		bool(mp_game.call(
			"_is_valid_bamboo_mortar_visual_payload",
			PackedInt32Array([11, 12]),
			PackedInt32Array([21, 22]),
			PackedByteArray([0, 1]),
			PackedVector2Array([
				Vector2(1.0, 2.0),
				Vector2(3.0, 4.0),
			]),
			PackedVector2Array([
				Vector2(80.0, 0.0),
				Vector2(96.0, 8.0),
			]),
			PackedFloat32Array([4.0, 3.2]),
			PackedFloat64Array([0.0, 1.25])
		)),
		"Bamboo mortar payloads must accept equal-length finite windup/fire records."
	)
	_expect(
		not bool(mp_game.call(
			"_is_valid_bamboo_mortar_visual_payload",
			PackedInt32Array([11, 12]),
			PackedInt32Array([21]),
			PackedByteArray([0, 1]),
			PackedVector2Array([Vector2.ZERO, Vector2.ZERO]),
			PackedVector2Array([Vector2.ZERO, Vector2.ZERO]),
			PackedFloat32Array([4.0, 4.0]),
			PackedFloat64Array([0.0, 1.25])
		))
		and not bool(mp_game.call(
			"_is_valid_bamboo_mortar_visual_payload",
			PackedInt32Array([11]),
			PackedInt32Array([21]),
			PackedByteArray([2]),
			PackedVector2Array([Vector2.ZERO]),
			PackedVector2Array([Vector2.ZERO]),
			PackedFloat32Array([4.0]),
			PackedFloat64Array([0.0])
		))
		and not bool(mp_game.call(
			"_is_valid_bamboo_mortar_visual_payload",
			PackedInt32Array([11]),
			PackedInt32Array([21]),
			PackedByteArray([1]),
			PackedVector2Array([Vector2(NAN, 0.0)]),
			PackedVector2Array([Vector2.ZERO]),
			PackedFloat32Array([4.0]),
			PackedFloat64Array([0.0])
		))
		and not bool(mp_game.call(
			"_is_valid_bamboo_mortar_visual_payload",
			PackedInt32Array([11]),
			PackedInt32Array([21]),
			PackedByteArray([0]),
			PackedVector2Array([Vector2.ZERO]),
			PackedVector2Array([Vector2.ZERO]),
			PackedFloat32Array([0.0]),
			PackedFloat64Array([0.0])
		)),
		"Bamboo mortar payloads must reject mismatched, unknown, non-finite, or invalid-duration records."
	)
	var oversized_ids := PackedInt32Array()
	var oversized_actions := PackedInt32Array()
	var oversized_stages := PackedByteArray()
	var oversized_spawns := PackedVector2Array()
	var oversized_landings := PackedVector2Array()
	var oversized_windup_durations := PackedFloat32Array()
	var oversized_times := PackedFloat64Array()
	for record_index in range(25):
		oversized_ids.append(record_index + 1)
		oversized_actions.append(record_index + 1)
		oversized_stages.append(record_index % 2)
		oversized_spawns.append(Vector2.ZERO)
		oversized_landings.append(Vector2(96.0, 0.0))
		oversized_windup_durations.append(4.0)
		oversized_times.append(float(record_index))
	_expect(
		not bool(mp_game.call(
			"_is_valid_bamboo_mortar_visual_payload",
			oversized_ids,
			oversized_actions,
			oversized_stages,
			oversized_spawns,
			oversized_landings,
			oversized_windup_durations,
			oversized_times
		)),
		"Bamboo mortar visual packets must reject a 25th record."
	)
	_expect(
		mp_game_source.contains('"windup_elapsed_seconds"')
		and mp_game_source.contains('"projectile_elapsed_seconds"')
		and mp_game_source.contains("+ sample_age"),
		"Plant runtime repair must add network sample age to bamboo windup and projectile visual progress."
	)
	var recorder := BambooBatchRecordingMpGame.new()
	var record_count := 300
	var plant_ids := PackedInt32Array()
	var action_ids := PackedInt32Array()
	var stages := PackedByteArray()
	var spawn_positions := PackedVector2Array()
	var landing_positions := PackedVector2Array()
	var windup_durations := PackedFloat32Array()
	var host_times := PackedFloat64Array()
	for record_index in range(record_count):
		plant_ids.append(record_index + 1)
		action_ids.append(record_index + 101)
		stages.append(record_index % 2)
		spawn_positions.append(Vector2(record_index, 0.0))
		landing_positions.append(Vector2(96.0, record_index))
		windup_durations.append(3.2 if record_index % 2 == 0 else 4.0)
		host_times.append(float(record_index))
	recorder.set("_pending_bamboo_mortar_visuals", plant_ids)
	recorder.set("_pending_bamboo_mortar_action_ids", action_ids)
	recorder.set("_pending_bamboo_mortar_stages", stages)
	recorder.set("_pending_bamboo_mortar_spawn_positions", spawn_positions)
	recorder.set("_pending_bamboo_mortar_landing_positions", landing_positions)
	recorder.set("_pending_bamboo_mortar_windup_durations", windup_durations)
	recorder.set("_pending_bamboo_mortar_host_times", host_times)
	recorder.call("_flush_bamboo_mortar_visuals")
	var first_args := (
		recorder.outbound_calls[0].get("args", []) as Array
		if recorder.outbound_calls.size() >= 1
		else []
	)
	var last_args := (
		recorder.outbound_calls.back().get("args", []) as Array
		if not recorder.outbound_calls.is_empty()
		else []
	)
	_expect(
		recorder.outbound_calls.size() == 13
		and recorder.outbound_calls[0].get("method_name")
		== &"net_bamboo_mortar_visual_batch"
		and recorder.outbound_calls.back().get("method_name")
		== &"net_bamboo_mortar_visual_batch"
		and first_args.size() == 7
		and last_args.size() == 7
		and (first_args[0] as PackedInt32Array).size() == 24
		and (last_args[0] as PackedInt32Array).size() == 12
		and (
			recorder.get("_pending_bamboo_mortar_visuals")
			as PackedInt32Array
		).is_empty(),
		"Bamboo visual flush must split 300 records into thirteen ordered packets and clear the queue."
	)
	recorder.free()
	mp_game.free()


func _test_corn_burst_payload_contract() -> void:
	var mp_game := MpGameScript.new()
	_expect(
		int(mp_game.call(
			"_get_rpc_traffic_channel",
			&"net_corn_machine_gun_burst_batch"
		)) == NetConstants.CH_PROJECTILE,
		"Corn burst traffic metrics must be attributed to CH_PROJECTILE."
	)
	var mp_game_source := FileAccess.get_file_as_string("res://scene/multiplayer/mp_game.gd")
	_expect(
		mp_game_source.contains(
			"const CORN_MACHINE_GUN_BURST_FLUSH_INTERVAL_SECONDS := 0.05"
		)
		and mp_game_source.contains(
			"const CORN_MACHINE_GUN_BURST_MAX_RECORDS_PER_PACKET := 32"
		),
		"Corn burst visuals must flush every 0.05 seconds in packets of at most 32."
	)
	var exit_start := mp_game_source.find("func _exit_tree()")
	var exit_end := mp_game_source.find("\n\nfunc ", exit_start + 1)
	var exit_body := (
		mp_game_source.substr(exit_start, exit_end - exit_start)
		if exit_start >= 0 and exit_end > exit_start
		else ""
	)
	_expect(
		exit_body.contains("_pending_corn_machine_gun_burst_visuals.clear()")
		and exit_body.contains(
			"_pending_corn_machine_gun_burst_action_ids.clear()"
		)
		and exit_body.contains(
			"_pending_corn_machine_gun_burst_directions.clear()"
		)
		and exit_body.contains(
			"_pending_corn_machine_gun_burst_host_times.clear()"
		),
		"MpGame exit must discard every packed column of queued corn burst visuals."
	)
	_expect(
		mp_game_source.contains(
			"_pending_corn_machine_gun_burst_host_times.append(host_action_time)"
		)
		and mp_game_source.contains("_map_host_timestamp_to_client_time("),
		"Corn burst records must carry Host time and map it before client playback."
	)
	_expect(
		bool(mp_game.call(
			"_is_valid_corn_machine_gun_burst_payload",
			PackedInt32Array([11, 12]),
			PackedInt32Array([21, 22]),
			PackedVector2Array([Vector2.RIGHT, Vector2.UP]),
			PackedFloat64Array([0.0, 1.25])
		)),
		"Corn burst payloads must accept equal-length finite records."
	)
	_expect(
		not bool(mp_game.call(
			"_is_valid_corn_machine_gun_burst_payload",
			PackedInt32Array([11, 12]),
			PackedInt32Array([21]),
			PackedVector2Array([Vector2.RIGHT, Vector2.UP]),
			PackedFloat64Array([0.0, 1.25])
		)),
		"Corn burst payloads must reject mismatched packed-array lengths."
	)
	_expect(
		not bool(mp_game.call(
			"_is_valid_corn_machine_gun_burst_payload",
			PackedInt32Array([11]),
			PackedInt32Array([21]),
			PackedVector2Array([Vector2(NAN, 0.0)]),
			PackedFloat64Array([0.0])
		))
		and not bool(mp_game.call(
			"_is_valid_corn_machine_gun_burst_payload",
			PackedInt32Array([11]),
			PackedInt32Array([21]),
			PackedVector2Array([Vector2.RIGHT]),
			PackedFloat64Array([NAN])
		)),
		"Corn burst payloads must reject non-finite directions and Host times."
	)
	var oversized_ids := PackedInt32Array()
	var oversized_actions := PackedInt32Array()
	var oversized_directions := PackedVector2Array()
	var oversized_times := PackedFloat64Array()
	for record_index in range(33):
		oversized_ids.append(record_index + 1)
		oversized_actions.append(record_index + 1)
		oversized_directions.append(Vector2.RIGHT)
		oversized_times.append(float(record_index))
	_expect(
		not bool(mp_game.call(
			"_is_valid_corn_machine_gun_burst_payload",
			oversized_ids,
			oversized_actions,
			oversized_directions,
			oversized_times
		)),
		"Corn burst packets must reject a 33rd record."
	)
	mp_game.free()


func _test_linglan_skill1_ring_payload_contract() -> void:
	var mp_game := MpGameScript.new()
	var first_projectile_id := int(mp_game.call(
		"_encode_projectile_id",
		1,
		PROJECTILE_HOST_ORIGIN_BIT | 1000000
	))
	var second_projectile_id := int(mp_game.call(
		"_encode_projectile_id",
		1,
		PROJECTILE_HOST_ORIGIN_BIT | 1000001
	))
	var projectile_ids := PackedInt64Array([first_projectile_id, second_projectile_id])
	var spawn_positions := PackedVector2Array([Vector2(10.0, 20.0), Vector2(30.0, 40.0)])
	var directions := PackedVector2Array([Vector2.RIGHT, Vector2.UP])
	_expect(
		int(mp_game.call(
			"_get_rpc_traffic_channel",
			&"net_linglan_skill1_ring_batch"
		)) == NetConstants.CH_PROJECTILE,
		"Linglan ring batches must be attributed to CH_PROJECTILE."
	)
	_expect(
		bool(mp_game.call(
			"_is_valid_linglan_skill1_ring_payload",
			projectile_ids,
			spawn_positions,
			directions,
			1,
			50,
			300.0,
			2.0,
			1.25
		)),
		"Linglan ring batches must accept aligned, finite packed columns."
	)
	_expect(
		not bool(mp_game.call(
			"_is_valid_linglan_skill1_ring_payload",
			PackedInt64Array([first_projectile_id, first_projectile_id]),
			spawn_positions,
			directions,
			1,
			50,
			300.0,
			2.0,
			1.25
		)),
		"Linglan ring batches must reject duplicate projectile IDs."
	)
	_expect(
		not bool(mp_game.call(
			"_is_valid_linglan_skill1_ring_payload",
			PackedInt64Array([
				first_projectile_id,
				int(mp_game.call(
					"_encode_projectile_id",
					2,
					PROJECTILE_HOST_ORIGIN_BIT | 1000001
				)),
			]),
			spawn_positions,
			directions,
			1,
			50,
			300.0,
			2.0,
			1.25
		)),
		"Linglan ring batches must reject an ID encoded for another owner."
	)
	_expect(
		not bool(mp_game.call(
			"_is_valid_linglan_skill1_ring_payload",
			PackedInt64Array([
				int(mp_game.call("_encode_projectile_id", 1, 1000000)),
				int(mp_game.call("_encode_projectile_id", 1, 1000001)),
			]),
			spawn_positions,
			directions,
			1,
			50,
			300.0,
			2.0,
			1.25
		)),
		"Host-authored Linglan batches must reject client-origin projectile IDs."
	)
	var wrapped_host_ids := PackedInt64Array([
		int(mp_game.call(
			"_encode_projectile_id",
			1,
			PROJECTILE_HOST_ORIGIN_BIT | PROJECTILE_SEQUENCE_COUNTER_MAX
		)),
		int(mp_game.call(
			"_encode_projectile_id",
			1,
			PROJECTILE_HOST_ORIGIN_BIT | 1
		)),
	])
	_expect(
		wrapped_host_ids[1] < wrapped_host_ids[0]
		and bool(mp_game.call(
			"_is_valid_linglan_skill1_ring_payload",
			wrapped_host_ids,
			spawn_positions,
			directions,
			1,
			50,
			300.0,
			2.0,
			1.25
		)),
		"A valid Host ring must survive the 31-bit counter wrap without relying on monotonic IDs."
	)
	mp_game.free()


func _test_projectile_id_codec_contract() -> void:
	var mp_game := MpGameScript.new()
	var below_legacy_boundary := int(
		mp_game.call("_encode_projectile_id", 2, 999999)
	)
	var at_legacy_boundary := int(
		mp_game.call("_encode_projectile_id", 2, 1000000)
	)
	var above_legacy_boundary := int(
		mp_game.call("_encode_projectile_id", 2, 1000001)
	)
	var other_owner_same_sequence := int(
		mp_game.call("_encode_projectile_id", 3, 1000000)
	)
	var host_same_owner_and_counter := int(mp_game.call(
		"_encode_projectile_id",
		2,
		PROJECTILE_HOST_ORIGIN_BIT | 1000000
	))
	_expect(
		below_legacy_boundary > 0
		and at_legacy_boundary > below_legacy_boundary
		and above_legacy_boundary > at_legacy_boundary
		and other_owner_same_sequence != at_legacy_boundary
		and host_same_owner_and_counter != at_legacy_boundary,
		"Projectile IDs must stay unique across the old one-million boundary, owners, and origin lanes."
	)
	for projectile_id in [
		below_legacy_boundary,
		at_legacy_boundary,
		above_legacy_boundary,
	]:
		_expect(
			int(mp_game.call("_decode_projectile_owner_peer_id", projectile_id)) == 2
			and bool(mp_game.call(
				"_is_projectile_id_valid_for_owner",
				projectile_id,
				2
			)),
			"Cross-boundary projectile IDs must retain owner 2 exactly."
		)
	_expect(
		int(mp_game.call("_decode_projectile_sequence", at_legacy_boundary)) == 1000000
		and int(mp_game.call(
			"_decode_projectile_owner_peer_id",
			other_owner_same_sequence
		)) == 3
		and not bool(mp_game.call(
			"_is_projectile_id_valid_for_owner",
			other_owner_same_sequence,
			2
		)),
		"Projectile ID decoding must keep owner and sequence in disjoint bit fields."
	)
	_expect(
		bool(mp_game.call(
			"_is_projectile_id_valid_for_client_owner",
			at_legacy_boundary,
			2
		))
		and not bool(mp_game.call(
			"_is_projectile_id_valid_for_client_owner",
			host_same_owner_and_counter,
			2
		))
		and bool(mp_game.call(
			"_is_projectile_id_valid_for_host_owner",
			host_same_owner_and_counter,
			2
		))
		and not bool(mp_game.call(
			"_is_projectile_id_valid_for_host_owner",
			at_legacy_boundary,
			2
		))
		and int(mp_game.call(
			"_decode_projectile_sequence_counter",
			host_same_owner_and_counter
		)) == 1000000,
		"Host and client origin lanes must be disjoint while retaining the same 31-bit counter."
	)
	var signed_int64_max := int(mp_game.call(
		"_encode_projectile_id",
		0x7FFFFFFF,
		PROJECTILE_SEQUENCE_MAX
	))
	_expect(
		signed_int64_max == 0x7FFFFFFFFFFFFFFF
		and int(mp_game.call(
			"_decode_projectile_owner_peer_id",
			signed_int64_max
		)) == 0x7FFFFFFF
		and int(mp_game.call(
			"_decode_projectile_sequence",
			signed_int64_max
		)) == PROJECTILE_SEQUENCE_MAX,
		"The largest supported owner/sequence pair must remain a positive signed int64."
	)
	_expect(
		int(mp_game.call("_encode_projectile_id", 0, 1)) == 0
		and int(mp_game.call("_encode_projectile_id", 0x80000000, 1)) == 0
		and int(mp_game.call("_encode_projectile_id", 2, 0)) == 0
		and int(mp_game.call(
			"_encode_projectile_id",
			2,
			PROJECTILE_SEQUENCE_MAX + 1
		)) == 0,
		"Projectile ID encoding must reject zero and signed-overflow fields."
	)
	_expect(
		not bool(mp_game.call("_is_projectile_id_valid_for_owner", 1, 0))
		and not bool(mp_game.call(
			"_is_projectile_id_valid_for_owner",
			0x7FFFFFFF,
			0
		)),
		"Owner zero must never become valid through a hand-crafted low sequence ID."
	)

	var occupied_wrapped_id := int(mp_game.call("_encode_projectile_id", 2, 1))
	var records := mp_game.get("_projectile_records") as Dictionary
	records[occupied_wrapped_id] = {"expires_at": INF}
	mp_game.set("_next_projectile_sequence", PROJECTILE_SEQUENCE_COUNTER_MAX)
	var final_sequence_id := int(mp_game.call("_allocate_projectile_id", 2, false))
	var wrapped_sequence_id := int(mp_game.call("_allocate_projectile_id", 2, false))
	_expect(
		int(mp_game.call(
			"_decode_projectile_sequence_counter",
			final_sequence_id
		)) == PROJECTILE_SEQUENCE_COUNTER_MAX
		and int(mp_game.call(
			"_decode_projectile_sequence_counter",
			wrapped_sequence_id
		)) == 2,
		"Sequence wrap must skip zero and any still-live/recent wrapped identity."
	)
	mp_game.set("_next_projectile_sequence", 42)
	var client_lane_id := int(mp_game.call("_allocate_projectile_id", 2, false))
	mp_game.set("_next_projectile_sequence", 42)
	var host_lane_id := int(mp_game.call("_allocate_projectile_id", 2, true))
	_expect(
		client_lane_id != host_lane_id
		and int(mp_game.call(
			"_decode_projectile_sequence_counter",
			client_lane_id
		)) == 42
		and int(mp_game.call(
			"_decode_projectile_sequence_counter",
			host_lane_id
		)) == 42
		and bool(mp_game.call("_is_host_origin_projectile_id", host_lane_id))
		and not bool(mp_game.call("_is_host_origin_projectile_id", client_lane_id)),
		"Concurrent Host/client allocation for one owner must use collision-free origin lanes."
	)
	_expect(
		bool(mp_game.call(
			"_is_projectile_id_valid_for_client_owner",
			client_lane_id,
			2
		))
		and not bool(mp_game.call(
			"_is_projectile_id_valid_for_client_owner",
			host_lane_id,
			2
		))
		and bool(mp_game.call(
			"_is_projectile_id_valid_for_host_owner",
			host_lane_id,
			2
		)),
		"Origin lanes must remain structurally distinct even though neither lane authorizes a remote enemy-hit claim."
	)
	mp_game.free()


func _test_projectile_origin_lane_runtime_contract() -> void:
	var mp_game := MpGameScript.new()
	var client_lane_id := int(mp_game.call("_encode_projectile_id", 2, 57))
	var host_lane_id := int(mp_game.call(
		"_encode_projectile_id",
		2,
		PROJECTILE_HOST_ORIGIN_BIT | 57
	))
	var predicted_bullet := BULLET_SCENE.instantiate() as Bullet
	mp_game.add_child(predicted_bullet)
	mp_game.call(
		"_setup_projectile_network_identity",
		predicted_bullet,
		client_lane_id,
		2,
		&"player_bullet"
	)
	var known_projectiles := mp_game.get("_known_projectiles") as Dictionary
	known_projectiles[client_lane_id] = predicted_bullet
	mp_game.call(
		"_remember_projectile_record",
		client_lane_id,
		2,
		&"player_bullet",
		3,
		2.0,
		false
	)

	# The Host echo for a predicted client-lane shot must update the same node
	# instead of creating a duplicate proxy.
	mp_game.call(
		"net_projectile_fired",
		client_lane_id,
		"player_bullet",
		2,
		Vector2(10.0, 20.0),
		Vector2.UP,
		11,
		222.0,
		1.5,
		false,
		0,
		-1.0,
		0
	)
	var reconciled_record := (
		mp_game.get("_projectile_records") as Dictionary
	).get(client_lane_id, {}) as Dictionary
	_expect(
		known_projectiles.size() == 1
		and known_projectiles.get(client_lane_id) == predicted_bullet
		and predicted_bullet.direction.is_equal_approx(Vector2.UP)
		and predicted_bullet.damage == 11
		and is_equal_approx(predicted_bullet.speed, 222.0)
		and int(reconciled_record.get("damage", -1)) == 11,
		"A Host echo must reconcile the existing client prediction in place."
	)

	# A distinct Host-authoritative projectile for the same remote owner and
	# counter must coexist under the Host lane without replacing that prediction.
	mp_game.call(
		"net_projectile_fired",
		host_lane_id,
		"player_bullet",
		2,
		Vector2(30.0, 40.0),
		Vector2.LEFT,
		13,
		180.0,
		1.25,
		false,
		0,
		-1.0,
		0
	)
	var host_bullet := known_projectiles.get(host_lane_id) as Bullet
	_expect(
		known_projectiles.size() == 2
		and known_projectiles.get(client_lane_id) == predicted_bullet
		and host_bullet != null
		and host_bullet != predicted_bullet
		and host_bullet.projectile_id == host_lane_id
		and host_bullet.owner_peer_id == 2
		and host_bullet.damage == 13,
		"A Host-lane projectile must coexist with the same owner's client prediction "
		+ "without an ID collision or replacement."
	)
	mp_game.free()


func _test_enemy_codec_reuse_and_packet_budget() -> void:
	var sender := SnapshotManager.new()
	var receiver := SnapshotManager.new()
	var states: Array[SnapshotManager.EnemyState] = []
	for enemy_index in range(46):
		var state := SnapshotManager.EnemyState.new()
		state.net_id = enemy_index + 1
		state.position = Vector2(enemy_index * 2.0, enemy_index * -1.5)
		state.velocity = Vector2(1.0, -1.0)
		state.locomotion_state = SnapshotManager.ENEMY_LOCOMOTION_MOVING
		state.health = 100 + enemy_index
		state.health_revision = enemy_index + 3
		state.visual_status_mask = 0b1101 if enemy_index == 0 else 0
		states.append(state)
	var keyframe := sender.encode_enemy_snapshots_for_peer(8, states, true)
	_expect(
		keyframe.size() == 1106,
		"A v25 46-enemy keyframe must use 1106 bytes and stay within the 1200-byte budget."
	)
	var decoded_keyframe := receiver.decode_enemy_snapshots_with_baseline(keyframe)
	_expect(decoded_keyframe.size() == 46, "The complete 46-enemy keyframe must decode.")
	if decoded_keyframe.is_empty():
		return
	_expect(
		decoded_keyframe[0].visual_status_mask == 0b1101
		and decoded_keyframe[0].locomotion_state
			== SnapshotManager.ENEMY_LOCOMOTION_MOVING
		and decoded_keyframe[0].health_revision == 3,
		"Enemy visual status, locomotion and health revision must round-trip in a keyframe."
	)
	states[0].position.x += 2.0
	states[0].visual_status_mask = 0b0100
	states[0].locomotion_state = SnapshotManager.ENEMY_LOCOMOTION_IDLE
	var delta := sender.encode_enemy_snapshots_for_peer(8, states, false)
	var decoded_delta := receiver.decode_enemy_snapshots_with_baseline(delta)
	_expect(
		decoded_delta.size() == 46
		and is_same(decoded_keyframe[0], decoded_delta[0])
		and decoded_delta[0].visual_status_mask == 0b0100
		and decoded_delta[0].locomotion_state
			== SnapshotManager.ENEMY_LOCOMOTION_IDLE,
		"Enemy delta output must reuse objects and update visual and locomotion bits."
	)
	receiver.prune_enemy_receive_baseline_to_ids({1: true})
	_expect(
		receiver.enemy_receive_baselines.size() == 1
		and receiver.enemy_receive_output_states.size() == 1,
		"Enemy pruning must release stale baseline and output-object entries together."
	)

	var locomotion_sender := SnapshotManager.new()
	var locomotion_receiver := SnapshotManager.new()
	var locomotion_state := SnapshotManager.EnemyState.new()
	locomotion_state.net_id = 99
	locomotion_state.locomotion_state = SnapshotManager.ENEMY_LOCOMOTION_MOVING
	var locomotion_keyframe := locomotion_sender.encode_enemy_snapshots_for_peer(
		9,
		[locomotion_state],
		true
	)
	locomotion_receiver.decode_enemy_snapshots_with_baseline(locomotion_keyframe)
	locomotion_state.locomotion_state = SnapshotManager.ENEMY_LOCOMOTION_IDLE
	var locomotion_delta := locomotion_sender.encode_enemy_snapshots_for_peer(
		9,
		[locomotion_state],
		false
	)
	var decoded_locomotion_delta := (
		locomotion_receiver.decode_enemy_snapshots_with_baseline(locomotion_delta)
	)
	_expect(
		locomotion_delta.size() == 8
		and decoded_locomotion_delta.size() == 1
		and decoded_locomotion_delta[0].locomotion_state
			== SnapshotManager.ENEMY_LOCOMOTION_IDLE,
		"A locomotion-only enemy delta must use exactly one payload byte and round-trip."
	)


func _test_runtime_state_send_order() -> void:
	var source := FileAccess.get_file_as_string("res://scene/multiplayer/mp_game.gd")
	var request_start := source.find("func net_runtime_state_requested(")
	var request_end := source.find("\n\nfunc ", request_start + 1)
	var request_body := (
		source.substr(request_start, request_end - request_start)
		if request_start >= 0 and request_end > request_start
		else ""
	)
	var handler_start := source.find(
		"func _handle_authoritative_runtime_state_request("
	)
	var handler_end := source.find("\n\nfunc ", handler_start + 1)
	var handler_body := (
		source.substr(handler_start, handler_end - handler_start)
		if handler_start >= 0 and handler_end > handler_start
		else ""
	)
	_expect(
		request_body.contains("multiplayer.get_remote_sender_id()")
		and request_body.contains(
			"_handle_authoritative_runtime_state_request(sender_id"
		)
		and handler_body.contains("sender_id <= 0")
		and handler_body.contains("_consume_peer_rate_token(")
		and handler_body.contains("game.get_player_for_peer(sender_id) == null")
		and handler_body.contains("_send_runtime_state_to_peer(sender_id"),
		"Complete-state repair requests must come from a registered in-game peer."
	)
	var function_start := source.find("func _send_runtime_state_to_peer(")
	var function_end := source.find("\n\nfunc ", function_start + 1)
	var function_body := (
		source.substr(function_start, function_end - function_start)
		if function_start >= 0 and function_end > function_start
		else ""
	)
	var terrain_position := function_body.find("_send_terrain_snapshot_to_peer")
	var plant_position := function_body.find("_send_live_plant_roster_to_peer")
	var other_position := function_body.find("_send_live_enemy_roster_to_peer")
	var manifest_position := function_body.find("_send_runtime_world_manifest_to_peer")
	_expect(
		terrain_position >= 0
		and plant_position > terrain_position
		and other_position > plant_position
		and manifest_position > other_position,
		"Complete-state repair must send terrain, plants, other state, then the world manifest."
	)


func _test_plant_removal_restore_order() -> void:
	var source := FileAccess.get_file_as_string(TOWER_DEFENSE_RUNTIME_PATH)
	var function_start := source.find("func _on_plant_removed(")
	var function_end := source.find("\n\nfunc ", function_start + 1)
	var function_body := (
		source.substr(function_start, function_end - function_start)
		if function_start >= 0 and function_end > function_start
		else ""
	)
	var removal_signal_position := function_body.find("multiplayer_plant_removed.emit")
	var cancel_position := function_body.find("vegetation_spread_system.cancel_source")
	_expect(
		removal_signal_position >= 0
		and cancel_position > removal_signal_position,
		"Plant removal must reach reliable CH5 before its terrain-restore delta so clients clear the growth overlay first."
	)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
