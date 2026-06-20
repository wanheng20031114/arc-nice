extends SceneTree

const LOBBY_SCENE := preload("res://scene/multiplayer/multiplayer_lobby.tscn")
const MP_GAME_SCENE := preload("res://scene/multiplayer/mp_game.tscn")
const GAME_SCENE := preload("res://scene/game.tscn")

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_scene_instantiation()
	_test_net_manager_lan_lifecycle()
	await _test_game_runtime_modes()
	_test_snapshot_round_trip()

	if failures.is_empty():
		print("MULTIPLAYER_LOAD_SMOKE_TEST_OK")
		quit()
		return

	for failure in failures:
		push_error(failure)
	quit(1)


func _test_scene_instantiation() -> void:
	var lobby := LOBBY_SCENE.instantiate()
	_expect(lobby != null, "multiplayer_lobby.tscn must instantiate.")
	if lobby != null:
		lobby.free()

	var mp_game := MP_GAME_SCENE.instantiate()
	_expect(mp_game != null, "mp_game.tscn must instantiate.")
	if mp_game != null:
		mp_game.free()

	var game := GAME_SCENE.instantiate()
	_expect(game != null, "game.tscn must instantiate as Game.")
	if game != null:
		game.configure_multiplayer(2, 2, {1: "Host", 2: "Client"})
		game.free()

	var net_manager := root.get_node_or_null("NetManager")
	_expect(net_manager != null, "NetManager autoload must be NetManagerStore.")
	if net_manager != null:
		_expect(
			net_manager.get_lan_ip_candidates() is PackedStringArray,
			"LAN IP helper must return PackedStringArray."
		)


func _test_net_manager_lan_lifecycle() -> void:
	var net_manager := root.get_node_or_null("NetManager")
	_expect(net_manager != null, "NetManager autoload is missing.")
	if net_manager == null:
		return

	net_manager.local_player_name = "SmokeHost"
	var err: Error = net_manager.host_create_lan_server(29171)
	_expect(err == OK, "NetManager must create a LAN host on test port.")
	_expect(net_manager.is_host(), "NetManager must enter host role.")
	_expect(net_manager.connected_players.has(1), "Host peer must be registered.")
	net_manager.disconnect_from_game()
	_expect(not net_manager.is_multiplayer_active(), "NetManager must cleanly disconnect after LAN host smoke.")


func _test_game_runtime_modes() -> void:
	var host_game := GAME_SCENE.instantiate()
	host_game.configure_multiplayer(1, 1, {1: "Host", 2: "Client"})
	root.add_child(host_game)
	await process_frame
	_expect(host_game.peer_players.size() == 2, "Host authority game must create peer players.")
	_expect(host_game.get_player_for_peer(1) != null, "Host player must exist.")
	_expect(host_game.get_player_for_peer(2) != null, "Remote player must exist on host.")
	var host_player := host_game.get_player_for_peer(1) as Player
	_expect(
		host_player != null
		and not host_player.name_label.visible
		and host_player.nameplate_layer.visible
		and host_player.nameplate_label.text == "Host",
		"Multiplayer player scene nameplate must show the peer name."
	)
	host_game.queue_free()
	await process_frame

	var client_game := GAME_SCENE.instantiate()
	client_game.configure_multiplayer(2, 2, {1: "Host", 2: "Client"})
	root.add_child(client_game)
	await process_frame
	_expect(client_game.peer_players.size() == 2, "Client view game must create visual peer players.")
	_expect(not client_game.auto_start_waves, "Client view must not start local waves.")
	client_game.queue_free()
	await process_frame


func _test_snapshot_round_trip() -> void:
	var snapshot_mgr := SnapshotManager.new()
	var player_state := SnapshotManager.PlayerState.new()
	player_state.peer_id = 2
	player_state.position = Vector2(11.5, 23.25)
	player_state.velocity = Vector2(1.0, -2.0)
	player_state.current_health = 42
	player_state.max_health = 100
	var player_data := snapshot_mgr.encode_all_player_snapshots([player_state])
	var player_states := SnapshotManager.decode_all_player_snapshots(player_data)
	_expect(player_states.size() == 1, "Player snapshot count mismatch.")
	if player_states.size() == 1:
		_expect(player_states[0].peer_id == 2, "Player snapshot peer_id mismatch.")
		_expect(player_states[0].current_health == 42, "Player snapshot health mismatch.")
	var player_data_2 := snapshot_mgr.encode_all_player_snapshots([player_state])
	var player_states_2 := SnapshotManager.decode_all_player_snapshots(player_data_2)
	_expect(
		player_states_2.size() == 1 and player_states_2[0].position.distance_to(player_state.position) < 0.12,
		"Repeated player snapshots must remain full snapshots."
	)

	var enemy_state := SnapshotManager.EnemyState.new()
	enemy_state.net_id = 7
	enemy_state.position = Vector2(88.0, 99.0)
	enemy_state.velocity = Vector2.LEFT
	enemy_state.health = 3
	var enemy_data := snapshot_mgr.encode_all_enemy_snapshots([enemy_state])
	var enemy_states := SnapshotManager.decode_all_enemy_snapshots(enemy_data)
	_expect(enemy_states.size() == 1, "Enemy snapshot count mismatch.")
	if enemy_states.size() == 1:
		_expect(enemy_states[0].net_id == 7, "Enemy snapshot net_id mismatch.")
		_expect(enemy_states[0].health == 3, "Enemy snapshot health mismatch.")
	var enemy_data_2 := snapshot_mgr.encode_all_enemy_snapshots([enemy_state])
	var enemy_states_2 := SnapshotManager.decode_all_enemy_snapshots(enemy_data_2)
	_expect(
		enemy_states_2.size() == 1 and enemy_states_2[0].position.distance_to(enemy_state.position) < 0.12,
		"Repeated enemy snapshots must remain full snapshots."
	)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
