extends SceneTree

const NetConstants := preload("res://scene/multiplayer/net_constants.gd")
const SnapshotManager := preload("res://scene/multiplayer/snapshot_manager.gd")
const MpGameScript := preload("res://scene/multiplayer/mp_game.gd")
const TOWER_DEFENSE_RUNTIME_PATH := "res://scene/game_tower_defense.gd"

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_channel_contract()
	_test_terrain_payload_contract()
	_test_runtime_state_send_order()
	_test_plant_removal_restore_order()
	_test_player_codec_and_reuse()
	_test_enemy_codec_reuse_and_packet_budget()
	if failures.is_empty():
		print("PROTOCOL_V6_SNAPSHOT_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_channel_contract() -> void:
	_expect(NetConstants.PROTOCOL_VERSION == 6, "Protocol must be v6.")
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
		"Protocol v6 channel assignments must remain stable."
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
