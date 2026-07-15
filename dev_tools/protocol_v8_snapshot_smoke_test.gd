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


var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_channel_contract()
	_test_terrain_payload_contract()
	_test_terrain_delta_revision_repair_contract()
	_test_terrain_snapshot_repair_watchdog_contract()
	_test_corn_burst_payload_contract()
	_test_projectile_id_codec_contract()
	_test_projectile_origin_lane_runtime_contract()
	_test_linglan_skill1_ring_payload_contract()
	_test_runtime_state_send_order()
	_test_plant_removal_restore_order()
	_test_player_codec_and_reuse()
	_test_enemy_codec_reuse_and_packet_budget()
	if failures.is_empty():
		print("PROTOCOL_V8_SNAPSHOT_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_channel_contract() -> void:
	_expect(NetConstants.PROTOCOL_VERSION == 8, "Protocol must be v8.")
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
		"Protocol v8 channel assignments must remain stable."
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
	records[client_lane_id] = {
		"owner_peer_id": 2,
		"projectile_type": &"player_bullet",
	}
	records[host_lane_id] = {
		"owner_peer_id": 2,
		"projectile_type": &"player_bullet",
	}
	_expect(
		bool(mp_game.call(
			"_is_client_enemy_hit_report_allowed",
			client_lane_id,
			2,
			2
		))
		and not bool(mp_game.call(
			"_is_client_enemy_hit_report_allowed",
			host_lane_id,
			2,
			2
		))
		and bool(mp_game.call(
			"_is_client_enemy_hit_report_allowed",
			host_lane_id,
			2,
			0
		)),
		"Remote hit RPCs must accept the owner's client lane, reject its Host lane, "
		+ "and leave Host-local authoritative settlement valid."
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
	for enemy_index in range(56):
		var state := SnapshotManager.EnemyState.new()
		state.net_id = enemy_index + 1
		state.position = Vector2(enemy_index * 2.0, enemy_index * -1.5)
		state.velocity = Vector2(1.0, -1.0)
		state.health = 100 + enemy_index
		state.visual_status_mask = 0b1101 if enemy_index == 0 else 0
		states.append(state)
	var keyframe := sender.encode_enemy_snapshots_for_peer(8, states, true)
	_expect(keyframe.size() <= 1200, "A 56-enemy full chunk must stay within 1200 bytes.")
	var decoded_keyframe := receiver.decode_enemy_snapshots_with_baseline(keyframe)
	_expect(decoded_keyframe.size() == 56, "The complete 56-enemy keyframe must decode.")
	if decoded_keyframe.is_empty():
		return
	_expect(
		decoded_keyframe[0].visual_status_mask == 0b1101,
		"Enemy visual status bits must round-trip in a keyframe."
	)
	states[0].position.x += 2.0
	states[0].visual_status_mask = 0b0100
	var delta := sender.encode_enemy_snapshots_for_peer(8, states, false)
	var decoded_delta := receiver.decode_enemy_snapshots_with_baseline(delta)
	_expect(
		decoded_delta.size() == 56
		and is_same(decoded_keyframe[0], decoded_delta[0])
		and decoded_delta[0].visual_status_mask == 0b0100,
		"Enemy delta output must reuse per-enemy objects and update visual status bits."
	)
	receiver.prune_enemy_receive_baseline_to_ids({1: true})
	_expect(
		receiver.enemy_receive_baselines.size() == 1
		and receiver.enemy_receive_output_states.size() == 1,
		"Enemy pruning must release stale baseline and output-object entries together."
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
	_expect(
		request_body.contains("multiplayer.get_remote_sender_id()")
		and request_body.contains("game.get_player_for_peer(sender_id) == null"),
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
