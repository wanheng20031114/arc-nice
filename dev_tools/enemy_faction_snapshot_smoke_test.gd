extends SceneTree

const SnapshotManagerScript := preload("res://scene/multiplayer/snapshot_manager.gd")
const NetConstantsScript := preload("res://scene/multiplayer/net_constants.gd")

const SAFE_KEYFRAME_ENTITY_COUNT := 41
const FULL_ENEMY_BYTES := 29
const SAFE_KEYFRAME_PACKET_BYTES := 1191
const PACKET_HEADER_BYTES := 2
const RECORD_MASK_OFFSET := 4
const RECORD_HEALTH_OFFSET := 14
const RECORD_HEALTH_REVISION_OFFSET := 18
const RECORD_FACTION_OFFSET := 24
const RECORD_FACTION_REVISION_OFFSET := 25

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_full_codec_layout_and_chunk_budget()
	_test_delta_then_keyframe_faction_repair()
	_test_validation_and_truncation_boundaries()
	_test_received_field_validation()
	_test_receive_packet_commit_is_atomic()
	_test_poisoned_delta_baseline_is_rejected()
	_test_wire_record_count_is_bounded()
	if failures.is_empty():
		print("ENEMY_FACTION_SNAPSHOT_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_full_codec_layout_and_chunk_budget() -> void:
	var states: Array[SnapshotManager.EnemyState] = []
	for enemy_index in range(SAFE_KEYFRAME_ENTITY_COUNT):
		var state := _make_state(enemy_index + 1)
		state.faction_id = enemy_index % 32
		state.faction_revision = enemy_index + 10
		states.append(state)

	var direct := SnapshotManagerScript.encode_enemy_snapshot(states[31], null)
	var direct_stream := StreamPeerBuffer.new()
	direct_stream.data_array = direct
	direct_stream.seek(25)
	_expect(
		direct.size() == FULL_ENEMY_BYTES
		and direct[24] == 31
		and direct_stream.get_u32() == 41,
		"Full enemy snapshots must append faction u8/revision u32 after the existing 24 bytes."
	)

	var packet := SnapshotManagerScript.new().encode_all_enemy_snapshots(states)
	var decoded := SnapshotManagerScript.decode_all_enemy_snapshots(packet)
	_expect(
		packet.size() == SAFE_KEYFRAME_PACKET_BYTES
		and decoded.size() == SAFE_KEYFRAME_ENTITY_COUNT,
		"A safe 41-entity keyframe chunk must use exactly 1191 bytes and decode fully."
	)
	if decoded.size() != SAFE_KEYFRAME_ENTITY_COUNT:
		return
	_expect(
		decoded[0].faction_id == 0
		and decoded[0].faction_revision == 10
		and decoded[31].faction_id == 31
		and decoded[31].faction_revision == 41,
		"Faction ID boundaries and revisions must round-trip through full keyframes."
	)


func _test_delta_then_keyframe_faction_repair() -> void:
	var sender := SnapshotManagerScript.new()
	var receiver := SnapshotManagerScript.new()
	var state := _make_state(77)
	state.faction_id = 2
	state.faction_revision = 5
	var states: Array[SnapshotManager.EnemyState] = [state]
	var initial := sender.encode_enemy_snapshots_for_peer(9, states, true)
	var initial_decoded := receiver.decode_enemy_snapshots_with_baseline(initial)
	_expect(
		initial.size() == FULL_ENEMY_BYTES + 2
		and initial_decoded.size() == 1
		and initial_decoded[0].faction_id == 2
		and initial_decoded[0].faction_revision == 5,
		"The initial full snapshot must establish the faction baseline."
	)
	if initial_decoded.is_empty():
		return

	state.position.x += 1.0
	state.faction_id = 31
	state.faction_revision = 6
	var delta := sender.encode_enemy_snapshots_for_peer(9, states, false)
	var delta_decoded := receiver.decode_enemy_snapshots_with_baseline(delta)
	_expect(
		delta.size() == 11
		and delta_decoded.size() == 1
		and delta_decoded[0].position.is_equal_approx(state.position)
		and delta_decoded[0].faction_id == 2
		and delta_decoded[0].faction_revision == 5,
		"Ordinary enemy deltas must not consume a mask bit or overwrite reliable faction state."
	)

	var repair := sender.encode_enemy_snapshots_for_peer(9, states, true)
	var repaired := receiver.decode_enemy_snapshots_with_baseline(repair)
	_expect(
		repair.size() == FULL_ENEMY_BYTES + 2
		and repaired.size() == 1
		and repaired[0].faction_id == 31
		and repaired[0].faction_revision == 6,
		"A subsequent full keyframe must repair faction state after loss or reconnection."
	)


func _test_validation_and_truncation_boundaries() -> void:
	var valid_max := _make_state(1)
	valid_max.net_id = NetConstantsScript.NETWORK_COMBAT_VALUE_MAX
	valid_max.health = NetConstantsScript.NETWORK_COMBAT_VALUE_MAX
	valid_max.health_revision = NetConstantsScript.NETWORK_COMBAT_VALUE_MAX
	valid_max.faction_id = 31
	valid_max.faction_revision = NetConstantsScript.NETWORK_COMBAT_VALUE_MAX
	var invalid_negative_faction := _make_state(2)
	invalid_negative_faction.faction_id = -1
	var invalid_overflow_faction := _make_state(3)
	invalid_overflow_faction.faction_id = 32
	var invalid_negative_revision := _make_state(4)
	invalid_negative_revision.faction_revision = -1
	var invalid_overflow_revision := _make_state(5)
	invalid_overflow_revision.faction_revision = (
		NetConstantsScript.NETWORK_COMBAT_VALUE_MAX + 1
	)
	_expect(
		SnapshotManagerScript.is_enemy_snapshot_state_serializable(valid_max)
		and not SnapshotManagerScript.is_enemy_snapshot_state_serializable(
			invalid_negative_faction
		)
		and not SnapshotManagerScript.is_enemy_snapshot_state_serializable(
			invalid_overflow_faction
		)
		and not SnapshotManagerScript.is_enemy_snapshot_state_serializable(
			invalid_negative_revision
		)
		and not SnapshotManagerScript.is_enemy_snapshot_state_serializable(
			invalid_overflow_revision
		),
		"Faction snapshots must accept 0..31 and reject invalid IDs or revisions."
	)

	var packet := SnapshotManagerScript.new().encode_all_enemy_snapshots([valid_max])
	var decoded_max := SnapshotManagerScript.decode_all_enemy_snapshots(packet)
	_expect(
		decoded_max.size() == 1
		and decoded_max[0].net_id == NetConstantsScript.NETWORK_COMBAT_VALUE_MAX
		and decoded_max[0].health == NetConstantsScript.NETWORK_COMBAT_VALUE_MAX
		and decoded_max[0].health_revision == (
			NetConstantsScript.NETWORK_COMBAT_VALUE_MAX
		)
		and decoded_max[0].faction_revision == (
			NetConstantsScript.NETWORK_COMBAT_VALUE_MAX
		),
		"Signed-int32 network maxima must round-trip through received enemy keyframes."
	)
	packet.resize(packet.size() - 1)
	_expect(
		SnapshotManagerScript.decode_all_enemy_snapshots(packet).is_empty(),
		"A keyframe truncated inside faction_revision must be rejected without a partial entity."
	)


func _test_received_field_validation() -> void:
	var invalid_packets: Array[PackedByteArray] = []
	var invalid_mask := _make_full_packet(_make_state(101))
	invalid_mask[PACKET_HEADER_BYTES + RECORD_MASK_OFFSET] |= (
		SnapshotManagerScript.MASK_FACING
	)
	invalid_packets.append(invalid_mask)

	var invalid_net_id := _make_full_packet(_make_state(102))
	_write_u32_le(invalid_net_id, PACKET_HEADER_BYTES, 0)
	invalid_packets.append(invalid_net_id)

	var invalid_health := _make_full_packet(_make_state(103))
	_write_u32_le(
		invalid_health,
		PACKET_HEADER_BYTES + RECORD_HEALTH_OFFSET,
		0xFFFFFFFF
	)
	invalid_packets.append(invalid_health)

	var invalid_health_revision := _make_full_packet(_make_state(104))
	_write_u32_le(
		invalid_health_revision,
		PACKET_HEADER_BYTES + RECORD_HEALTH_REVISION_OFFSET,
		0x80000000
	)
	invalid_packets.append(invalid_health_revision)

	var invalid_faction := _make_full_packet(_make_state(105))
	invalid_faction[PACKET_HEADER_BYTES + RECORD_FACTION_OFFSET] = 32
	invalid_packets.append(invalid_faction)

	var invalid_faction_revision := _make_full_packet(_make_state(106))
	_write_u32_le(
		invalid_faction_revision,
		PACKET_HEADER_BYTES + RECORD_FACTION_REVISION_OFFSET,
		0x80000000
	)
	invalid_packets.append(invalid_faction_revision)

	var all_rejected := true
	for invalid_packet in invalid_packets:
		if not SnapshotManagerScript.decode_all_enemy_snapshots(
			invalid_packet
		).is_empty():
			all_rejected = false
			break
	_expect(
		all_rejected,
		"Received full snapshots must reject invalid masks, IDs, health, revisions, and factions."
	)

	var direct_target := _make_state(107)
	var original_health := direct_target.health
	var invalid_direct := _make_full_packet(_make_state(107))
	_write_u32_le(
		invalid_direct,
		PACKET_HEADER_BYTES + RECORD_HEALTH_OFFSET,
		0xFFFFFFFF
	)
	var direct_offset := SnapshotManagerScript.decode_enemy_snapshot(
		invalid_direct,
		PACKET_HEADER_BYTES,
		direct_target
	)
	_expect(
		direct_offset == PACKET_HEADER_BYTES
		and direct_target.health == original_health,
		"Single-record decoding must not partially mutate its target on validation failure."
	)


func _test_receive_packet_commit_is_atomic() -> void:
	var receiver := SnapshotManagerScript.new()
	var initial := _make_state(201)
	initial.position = Vector2(10.0, 20.0)
	initial.health = 501
	initial.health_revision = 7
	initial.faction_id = 2
	initial.faction_revision = 9
	var established := receiver.decode_enemy_snapshots_with_baseline(
		_make_full_packet(initial)
	)
	if established.size() != 1:
		_expect(false, "A valid keyframe must establish the atomicity test baseline.")
		return
	var original_output: SnapshotManager.EnemyState = established[0]

	var updated := _make_state(201)
	updated.position = Vector2(30.0, 40.0)
	updated.health = 401
	updated.health_revision = 8
	updated.faction_id = 3
	updated.faction_revision = 10
	var added := _make_state(202)
	var malformed := SnapshotManagerScript.new().encode_all_enemy_snapshots(
		[updated, added]
	)
	_write_u32_le(
		malformed,
		PACKET_HEADER_BYTES + FULL_ENEMY_BYTES + RECORD_HEALTH_REVISION_OFFSET,
		0x80000000
	)
	var rejected := receiver.decode_enemy_snapshots_with_baseline(malformed)
	var stored := receiver.enemy_receive_baselines.get(201) as SnapshotManager.EnemyState
	_expect(
		rejected.is_empty()
		and stored != null
		and stored.position.is_equal_approx(initial.position)
		and stored.health == initial.health
		and stored.health_revision == initial.health_revision
		and stored.faction_id == initial.faction_id
		and stored.faction_revision == initial.faction_revision
		and original_output.position.is_equal_approx(initial.position)
		and original_output.health == initial.health
		and not receiver.enemy_receive_baselines.has(202)
		and not receiver.enemy_receive_output_states.has(202),
		"A malformed later record must reject the whole receive packet without advancing an earlier baseline or output."
	)

	var truncated := SnapshotManagerScript.new().encode_all_enemy_snapshots(
		[updated, added]
	)
	truncated.resize(truncated.size() - 1)
	receiver.decode_enemy_snapshots_with_baseline(truncated)
	_expect(
		stored.position.is_equal_approx(initial.position)
		and stored.health_revision == initial.health_revision
		and not receiver.enemy_receive_baselines.has(202),
		"A truncated later record must not partially commit an earlier complete record."
	)

	var recovered := receiver.decode_enemy_snapshots_with_baseline(
		SnapshotManagerScript.new().encode_all_enemy_snapshots([updated, added])
	)
	_expect(
		recovered.size() == 2
		and recovered[0].position.is_equal_approx(updated.position)
		and recovered[0].health_revision == updated.health_revision
		and recovered[1].net_id == added.net_id,
		"A valid keyframe after rejection must still advance both receive baselines."
	)


func _test_poisoned_delta_baseline_is_rejected() -> void:
	_test_one_poisoned_delta_baseline_is_rejected(301, true)
	_test_one_poisoned_delta_baseline_is_rejected(302, false)


func _test_wire_record_count_is_bounded() -> void:
	var receiver := SnapshotManagerScript.new()
	var valid_state := _make_state(401)
	var valid_result := receiver.decode_enemy_snapshots_with_baseline(
		_make_full_packet(valid_state)
	)
	var baseline_size_before := receiver.enemy_receive_baselines.size()
	var output_size_before := receiver.enemy_receive_output_states.size()
	var staging_size_before := receiver.enemy_receive_staging_states.size()
	for declared_count in [
		SnapshotManagerScript.ENEMY_SNAPSHOT_MAX_RECORDS_PER_PACKET + 1,
		0xFFFF,
	]:
		var oversized := PackedByteArray([
			declared_count & 0xFF,
			(declared_count >> 8) & 0xFF,
		])
		var rejected := receiver.decode_enemy_snapshots_with_baseline(oversized)
		_expect(
			rejected.is_empty()
			and receiver.enemy_receive_baselines.size() == baseline_size_before
			and receiver.enemy_receive_output_states.size() == output_size_before
			and receiver.enemy_receive_staging_states.size() == staging_size_before,
			"Enemy snapshot count above 41 must be rejected before allocating or mutating receive state."
		)
	_expect(
		valid_result.size() == 1,
		"The wire-count boundary fixture must first establish one valid receive state."
	)


func _test_one_poisoned_delta_baseline_is_rejected(
	net_id: int,
	poison_position: bool
) -> void:
	var sender := SnapshotManagerScript.new()
	var receiver := SnapshotManagerScript.new()
	var state := _make_state(net_id)
	var states: Array[SnapshotManager.EnemyState] = [state]
	var full := sender.encode_enemy_snapshots_for_peer(12, states, true)
	var established := receiver.decode_enemy_snapshots_with_baseline(full)
	if established.size() != 1:
		_expect(false, "A valid keyframe must establish the finite-value test baseline.")
		return
	var output: SnapshotManager.EnemyState = established[0]
	var original_health := output.health
	var baseline := receiver.enemy_receive_baselines.get(net_id) as SnapshotManager.EnemyState
	if poison_position:
		baseline.position = Vector2(NAN, 0.0)
	else:
		baseline.velocity = Vector2(NAN, 0.0)
	state.health += 1
	state.health_revision += 1
	var health_only_delta := sender.encode_enemy_snapshots_for_peer(12, states, false)
	var rejected := receiver.decode_enemy_snapshots_with_baseline(health_only_delta)
	_expect(
		rejected.is_empty()
		and output.health == original_health
		and output.position.is_finite()
		and output.velocity.is_finite(),
		"A delta reconstructed from a non-finite position or velocity baseline must be rejected without contaminating the prior output."
	)


func _make_full_packet(state: SnapshotManager.EnemyState) -> PackedByteArray:
	return SnapshotManagerScript.new().encode_all_enemy_snapshots([state])


func _write_u32_le(data: PackedByteArray, offset: int, value: int) -> void:
	data[offset] = value & 0xFF
	data[offset + 1] = (value >> 8) & 0xFF
	data[offset + 2] = (value >> 16) & 0xFF
	data[offset + 3] = (value >> 24) & 0xFF


func _make_state(net_id: int) -> SnapshotManager.EnemyState:
	var state := SnapshotManagerScript.EnemyState.new()
	state.net_id = net_id
	state.position = Vector2(float(net_id), float(-net_id))
	state.velocity = Vector2(3.0, -2.0)
	state.locomotion_state = SnapshotManagerScript.ENEMY_LOCOMOTION_MOVING
	state.health = 100 + net_id
	state.health_revision = net_id
	state.visual_status_mask = net_id % 0x80
	return state


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
