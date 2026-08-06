extends SceneTree

const MP_GAME_SCRIPT := preload("res://scene/multiplayer/mp_game.gd")
const DEFAULT_PLAYER_SCENE := preload(
	"res://scene/player/weishidaier/player_weishidaier.tscn"
)

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_host_teleport_resets_client_admission_baseline()
	_test_client_teleport_resets_remote_interpolation()
	_test_client_queues_teleport_until_player_exists()
	if failures.is_empty():
		print("MULTIPLAYER_AUTHORITATIVE_TELEPORT_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_host_teleport_resets_client_admission_baseline() -> void:
	var multiplayer_game := MP_GAME_SCRIPT.new()
	var tower_defense_game := TowerDefenseGame.new()
	var host_player := Player.new()
	var remote_player := Player.new()
	tower_defense_game.runtime_mode = CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY
	tower_defense_game.multiplayer_local_peer_id = 1
	tower_defense_game.peer_players = {1: host_player, 2: remote_player}
	multiplayer_game.game = tower_defense_game

	var old_admitted_position := Vector2(420.0, 120.0)
	var restored_position := Vector2(16.0, 16.0)
	remote_player.move_speed = 120.0
	remote_player.global_position = restored_position
	multiplayer_game._accepted_player_state_positions[2] = old_admitted_position
	multiplayer_game._accepted_player_state_times[2] = (
		multiplayer_game._get_net_time() - 10.0
	)
	multiplayer_game._host_latest_client_player_snapshot_states[2] = {
		"position": old_admitted_position,
		"velocity": Vector2.ZERO,
		"facing": 0,
		"anim_state": 0,
	}

	_expect(
		not multiplayer_game._accept_client_player_state(
			2,
			1,
			restored_position,
			Vector2.ZERO
		),
		"The pre-fix stale admission baseline fixture must reject the restored position."
	)
	_expect(
		multiplayer_game._commit_authoritative_player_teleport(2, restored_position),
		"The Host must commit an authoritative teleport for an existing remote peer."
	)
	_expect(
		multiplayer_game._accepted_player_state_positions.get(2) == restored_position,
		"Authoritative teleport must reset the anti-teleport admission position."
	)
	var latest_state := (
		multiplayer_game._host_latest_client_player_snapshot_states.get(2, {})
		as Dictionary
	)
	_expect(
		latest_state.get("position") == restored_position,
		"Authoritative teleport must replace the client-authored snapshot position."
	)
	_expect(
		multiplayer_game._accept_client_player_state(
			2,
			2,
			restored_position,
			Vector2.ZERO
		),
		"The first post-teleport owner packet must be admitted from the new baseline."
	)

	var host_target := Vector2(32.0, 32.0)
	_expect(
		multiplayer_game._commit_authoritative_player_teleport(1, host_target),
		"The Host's local player must use the same node teleport path."
	)
	_expect(
		not multiplayer_game._host_latest_client_player_snapshot_states.has(1),
		"The local Host must never be inserted into the client-authored snapshot cache."
	)

	tower_defense_game.peer_players.clear()
	host_player.free()
	remote_player.free()
	tower_defense_game.free()
	multiplayer_game.free()


func _test_client_teleport_resets_remote_interpolation() -> void:
	var multiplayer_game := MP_GAME_SCRIPT.new()
	var tower_defense_game := TowerDefenseGame.new()
	var local_player := Player.new()
	var remote_player := DEFAULT_PLAYER_SCENE.instantiate() as Player
	root.add_child(remote_player)
	tower_defense_game.runtime_mode = CombatRuntimeBase.RuntimeMode.CLIENT_VIEW
	tower_defense_game.multiplayer_local_peer_id = 3
	tower_defense_game.peer_players = {2: remote_player, 3: local_player}
	tower_defense_game.player = local_player
	multiplayer_game.game = tower_defense_game

	var interpolator := multiplayer_game._create_player_interpolator()
	interpolator.push_snapshot(
		multiplayer_game._get_net_time() - 1.0,
		Vector2(600.0, 400.0),
		Vector2(10.0, 0.0)
	)
	multiplayer_game.player_visual_interpolators[2] = interpolator
	var fate_position := Vector2(8192.0, 8192.0)
	multiplayer_game.net_player_authoritative_teleported(2, fate_position, 7)

	_expect(
		remote_player.global_position == fate_position,
		"A reliable teleport must snap the remote player node to the Host position."
	)
	var reset_interpolator := (
		multiplayer_game.player_visual_interpolators.get(2) as NetInterpolator
	)
	_expect(
		reset_interpolator != null and reset_interpolator.get_buffer_size() == 1,
		"A reliable teleport must clear the remote interpolation history."
	)
	if reset_interpolator != null:
		_expect(
			reset_interpolator.get_interpolated_position(
				multiplayer_game._get_net_time()
			) == fate_position,
			"The replacement interpolation sample must be the teleport target."
		)
	_expect(
		not multiplayer_game._accept_player_snapshot_motion_after_teleport(2, 7),
		"A pre-teleport snapshot arriving on another channel must be ignored."
	)
	_expect(
		multiplayer_game._accept_player_snapshot_motion_after_teleport(2, 8),
		"The first newer Host snapshot must release the teleport motion barrier."
	)
	# Re-arm the exact production barrier, then traverse the complete v25 path:
	# reliable teleport S -> ordinary player snapshot S+1 -> remote interpolator.
	multiplayer_game.net_player_authoritative_teleported(2, fate_position, 7)
	var post_snapshot_position := Vector2(8192.4, 8191.6)
	var post_teleport_state := SnapshotManager.PlayerState.new()
	post_teleport_state.peer_id = 2
	post_teleport_state.sequence = 8
	post_teleport_state.character_id = remote_player.get_character_id()
	post_teleport_state.position = post_snapshot_position
	post_teleport_state.velocity = Vector2.ZERO
	post_teleport_state.current_health = 100000
	post_teleport_state.max_health = 100000
	var snapshot_sender := SnapshotManager.new()
	var post_teleport_packet := snapshot_sender.encode_player_snapshots_for_peer(
		3,
		[post_teleport_state],
		true
	)
	multiplayer_game._rpc_receive_player_snapshot(
		multiplayer_game._get_net_time(),
		post_teleport_packet
	)
	var post_snapshot_interpolator := (
		multiplayer_game.player_visual_interpolators.get(2) as NetInterpolator
	)
	_expect(
		post_snapshot_interpolator != null
		and post_snapshot_interpolator.get_buffer_size() >= 1
		and post_snapshot_interpolator.get_latest_state().position == post_snapshot_position,
		"Snapshot S+1 must reach the interpolator at the Xiaocong-room position."
	)
	if post_snapshot_interpolator != null:
		_expect(
			post_snapshot_interpolator.get_interpolated_position(
				post_snapshot_interpolator.get_latest_timestamp() + 1.0
			) == post_snapshot_position,
			"The interpolator must not pull a teleported player back to the int16 boundary."
		)

	tower_defense_game.peer_players.clear()
	local_player.free()
	remote_player.free()
	tower_defense_game.free()
	multiplayer_game.free()


func _test_client_queues_teleport_until_player_exists() -> void:
	var multiplayer_game := MP_GAME_SCRIPT.new()
	var tower_defense_game := TowerDefenseGame.new()
	var local_player := Player.new()
	tower_defense_game.runtime_mode = CombatRuntimeBase.RuntimeMode.CLIENT_VIEW
	tower_defense_game.multiplayer_local_peer_id = 3
	tower_defense_game.peer_players = {3: local_player}
	tower_defense_game.player = local_player
	multiplayer_game.game = tower_defense_game

	var fate_position := Vector2(8240.0, 8234.0)
	multiplayer_game.net_player_authoritative_teleported(2, fate_position, 12)
	_expect(
		multiplayer_game._pending_authoritative_player_teleports.has(2),
		"A teleport received before its player node exists must remain pending."
	)
	var remote_player := Player.new()
	tower_defense_game.peer_players[2] = remote_player
	_expect(
		multiplayer_game._try_apply_pending_authoritative_player_teleport(2),
		"The queued teleport must apply as soon as the player node exists."
	)
	_expect(
		remote_player.global_position == fate_position
		and not multiplayer_game._pending_authoritative_player_teleports.has(2),
		"Applying the queued teleport must snap the player and clear pending state."
	)

	tower_defense_game.peer_players.clear()
	local_player.free()
	remote_player.free()
	tower_defense_game.free()
	multiplayer_game.free()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
