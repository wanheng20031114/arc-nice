extends SceneTree

const SnapshotManagerScript := preload(
	"res://scene/multiplayer/snapshot_manager.gd"
)
const PlayerScript := preload("res://scene/player/player.gd")

const RECEIVER_ID := 77
const PLAYER_PEER_ID := 2
const LEGACY_VISUAL_LERP_RATE := 36.0
const VISUAL_SETTLE_RATIO := 0.05


func _init() -> void:
	var sender := SnapshotManagerScript.new()
	var legacy_receiver := SnapshotManagerScript.new()
	var candidate_receiver := SnapshotManagerScript.new()
	var moving := _make_state(
		1,
		Vector2(100.0, 100.0),
		Vector2(120.0, 0.0),
		0,
		1
	)
	var stopped := _make_state(
		2,
		Vector2(102.0, 100.0),
		Vector2.ZERO,
		1,
		0
	)
	var steady_stop := _make_state(
		3,
		stopped.position,
		stopped.velocity,
		stopped.facing,
		stopped.anim_state
	)

	var initial_packet := sender.encode_player_snapshots_for_peer(
		RECEIVER_ID,
		[moving],
		true
	)
	# This is the transition packet lost by unreliable_ordered transport. Encoding
	# it still advances the sender baseline, exactly as the live Host does.
	sender.encode_player_snapshots_for_peer(RECEIVER_ID, [stopped], false)
	var candidate_post_loss_packet := sender.encode_player_snapshots_for_peer(
		RECEIVER_ID,
		[steady_stop],
		false
	)
	var legacy_post_loss_packet := _make_legacy_unchanged_delta(steady_stop)

	legacy_receiver.decode_player_snapshots_with_baseline(initial_packet)
	var legacy_decoded := legacy_receiver.decode_player_snapshots_with_baseline(
		legacy_post_loss_packet
	)
	candidate_receiver.decode_player_snapshots_with_baseline(initial_packet)
	var candidate_decoded := candidate_receiver.decode_player_snapshots_with_baseline(
		candidate_post_loss_packet
	)
	assert(
		legacy_decoded.size() == 1 and candidate_decoded.size() == 1,
		"A/B fixture must decode one player in both arms."
	)
	var legacy_observed := legacy_decoded[0] as SnapshotManager.PlayerState
	var candidate_observed := candidate_decoded[0] as SnapshotManager.PlayerState
	var legacy_stale_motion := _motion_matches(legacy_observed, moving)
	var candidate_repaired_motion := _motion_matches(
		candidate_observed,
		steady_stop
	)
	var candidate_mask := int(candidate_post_loss_packet[9])
	var required_motion_mask := SnapshotManager.PLAYER_REALTIME_MOTION_MASK
	var legacy_overshoot := _measure_stop_overshoot(moving, legacy_observed)
	var candidate_overshoot := _measure_stop_overshoot(moving, candidate_observed)
	print(
		(
			"MULTIPLAYER_PLAYER_CHANNEL_AB legacy_stale=%s candidate_repaired=%s "
			+ "legacy_repair_bound_ms=500 candidate_repair_bound_ms=16.7 "
			+ "legacy_overshoot_px=%.1f candidate_overshoot_px=%.1f "
			+ "candidate_mask=%d"
		)
		% [
			str(legacy_stale_motion),
			str(candidate_repaired_motion),
			legacy_overshoot,
			candidate_overshoot,
			candidate_mask,
		]
	)
	assert(
		legacy_stale_motion,
		"Legacy A must reproduce the lost stop-transition delta desync."
	)
	assert(
		candidate_repaired_motion
		and (candidate_mask & required_motion_mask) == required_motion_mask,
		"Candidate B must repeat every realtime motion/presentation field."
	)
	assert(
		legacy_overshoot >= 3.9 and candidate_overshoot <= 0.001,
		"Candidate B must remove stale-velocity stop overshoot."
	)
	_run_eight_player_packet_budget()
	_run_visual_smoothing_ab()
	print("MULTIPLAYER_PLAYER_CHANNEL_AB_SMOKE_TEST_OK")
	quit()


func _make_legacy_unchanged_delta(
	state: SnapshotManager.PlayerState
) -> PackedByteArray:
	var stream := StreamPeerBuffer.new()
	stream.put_32(state.peer_id)
	stream.put_32(state.sequence)
	stream.put_u8(0)
	# 保持 v93 的四字节绝对实时状态；这个 A 分支只模拟旧“运动字段按变化
	# 发送”的语义，不伪造已经不兼容的旧 wire 长度。
	stream.put_u8(1 if state.void_battery_charged else 0)
	stream.put_u8(clampi(state.visual_status_mask, 0, 255))
	stream.put_u16(clampi(
		roundi(state.effective_fire_interval_seconds * 1000.0),
		0,
		65535
	))
	var packet := PackedByteArray([1])
	packet.append_array(stream.data_array)
	return packet


func _motion_matches(
	actual: SnapshotManager.PlayerState,
	expected: SnapshotManager.PlayerState
) -> bool:
	return (
		actual.position == expected.position
		and actual.velocity == expected.velocity
		and actual.facing == expected.facing
		and actual.anim_state == expected.anim_state
	)


func _measure_stop_overshoot(
	moving: SnapshotManager.PlayerState,
	observed: SnapshotManager.PlayerState
) -> float:
	var interpolator := NetInterpolator.new(
		1.0 / 60.0,
		2.0,
		0.05
	)
	interpolator.push_snapshot(
		0.0,
		moving.position,
		moving.velocity,
		moving.facing,
		moving.anim_state
	)
	interpolator.push_snapshot(
		2.0 / 60.0,
		observed.position,
		observed.velocity,
		observed.facing,
		observed.anim_state
	)
	var rendered_position := interpolator.get_interpolated_position(0.2)
	return rendered_position.distance_to(Vector2(102.0, 100.0))


func _run_visual_smoothing_ab() -> void:
	var frame_rates := PackedInt32Array([30, 60, 144])
	var legacy_settle_ms: Array[float] = []
	var candidate_settle_ms: Array[float] = []
	for frame_rate in frame_rates:
		legacy_settle_ms.append(
			_measure_legacy_visual_settle_seconds(frame_rate) * 1000.0
		)
		candidate_settle_ms.append(
			_measure_candidate_visual_settle_seconds(frame_rate) * 1000.0
		)
	var legacy_spread_ms: float = (
		float(legacy_settle_ms.max()) - float(legacy_settle_ms.min())
	)
	var candidate_spread_ms: float = (
		float(candidate_settle_ms.max()) - float(candidate_settle_ms.min())
	)
	print(
		(
			"MULTIPLAYER_VISUAL_SMOOTHING_AB "
			+ "legacy_settle_ms=%.1f/%.1f/%.1f legacy_spread_ms=%.1f "
			+ "candidate_settle_ms=%.1f/%.1f/%.1f candidate_spread_ms=%.1f"
		)
		% [
			legacy_settle_ms[0],
			legacy_settle_ms[1],
			legacy_settle_ms[2],
			legacy_spread_ms,
			candidate_settle_ms[0],
			candidate_settle_ms[1],
			candidate_settle_ms[2],
			candidate_spread_ms,
		]
	)
	assert(
		legacy_spread_ms >= 40.0,
		"Legacy A must reproduce frame-rate-dependent visual settling."
	)
	assert(
		candidate_spread_ms <= 4.0
		and float(candidate_settle_ms.max()) <= 70.0,
		"Candidate B must keep visual settling consistent across 30/60/144 FPS."
	)
	assert(
		absf(candidate_settle_ms[1] - legacy_settle_ms[1]) <= 0.1,
		"Candidate B must preserve the established 60 FPS settling time."
	)


func _run_eight_player_packet_budget() -> void:
	var sender := SnapshotManagerScript.new()
	var states: Array[SnapshotManager.PlayerState] = []
	for peer_id in range(1, 9):
		var state := _make_state(
			peer_id,
			Vector2(100.0 + float(peer_id), 200.0),
			Vector2.ZERO,
			0,
			0
		)
		state.peer_id = peer_id
		states.append(state)
	var full_packet := sender.encode_player_snapshots_for_peer(
		RECEIVER_ID,
		states,
		true
	)
	var steady_packet := sender.encode_player_snapshots_for_peer(
		RECEIVER_ID,
		states,
		false
	)
	print(
		"MULTIPLAYER_PLAYER_CHANNEL_BUDGET players=8 full_bytes=%d steady_bytes=%d"
		% [full_packet.size(), steady_packet.size()]
	)
	assert(
		full_packet.size() == 585,
		"Eight-player full snapshot must remain at the v93 585-byte budget."
	)
	assert(
		steady_packet.size() == 217,
		"Eight-player repeated-motion snapshot must remain at the v93 217-byte budget."
	)


func _measure_legacy_visual_settle_seconds(frame_rate: int) -> float:
	var delta := 1.0 / float(frame_rate)
	var offset := 1.0
	var frame_count := 0
	while offset > VISUAL_SETTLE_RATIO and frame_count < 1000:
		var blend := clampf(delta * LEGACY_VISUAL_LERP_RATE, 0.0, 1.0)
		offset = lerpf(offset, 0.0, blend)
		frame_count += 1
	return float(frame_count) * delta


func _measure_candidate_visual_settle_seconds(frame_rate: int) -> float:
	var delta := 1.0 / float(frame_rate)
	var player := PlayerScript.new() as Player
	player.multiplayer_visual_smoothing_enabled = true
	player.multiplayer_visual_offset = Vector2.RIGHT
	var frame_count := 0
	while (
		player.multiplayer_visual_offset.length() > VISUAL_SETTLE_RATIO
		and frame_count < 1000
	):
		player._update_multiplayer_visual_smoothing(delta)
		frame_count += 1
	player.free()
	return float(frame_count) * delta


func _make_state(
	sequence: int,
	position: Vector2,
	velocity: Vector2,
	facing: int,
	anim_state: int
) -> SnapshotManager.PlayerState:
	var state := SnapshotManager.PlayerState.new()
	state.peer_id = PLAYER_PEER_ID
	state.sequence = sequence
	state.position = position
	state.velocity = velocity
	state.facing = facing
	state.anim_state = anim_state
	state.current_health = 100
	state.max_health = 100
	state.ammo_capacity = 1
	return state
