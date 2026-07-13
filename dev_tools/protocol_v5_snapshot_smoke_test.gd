extends SceneTree

const NetConstants := preload("res://scene/multiplayer/net_constants.gd")
const SnapshotManager := preload("res://scene/multiplayer/snapshot_manager.gd")

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_channel_contract()
	_test_player_codec_and_reuse()
	_test_enemy_codec_reuse_and_packet_budget()
	if failures.is_empty():
		print("PROTOCOL_V5_SNAPSHOT_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_channel_contract() -> void:
	_expect(NetConstants.PROTOCOL_VERSION == 5, "Protocol must be v5.")
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
		"Protocol v5 channel assignments must remain stable."
	)
	_expect(
		NetConstants.CH_STATE == NetConstants.CH_PLAYER_STATE
		and NetConstants.CH_EVENT == NetConstants.CH_WORLD_EVENT,
		"Legacy channel aliases must remain compatible during migration."
	)


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


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
