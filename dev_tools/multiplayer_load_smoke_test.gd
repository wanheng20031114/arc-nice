extends SceneTree

const LOBBY_SCENE := preload("res://scene/multiplayer/multiplayer_lobby.tscn")
const MP_GAME_SCENE := preload("res://scene/multiplayer/mp_game.tscn")
const GAME_SCENE := preload("res://scene/game.tscn")
const PLAYER_SCENE := preload("res://scene/player.tscn")
const BASIC_CONFIG := preload("res://resources/config/enemies/yuanshi_insect_basic.tres")
const BOMBER_CONFIG := preload("res://resources/config/enemies/yuanshi_insect_bomber.tres")
const KNIGHT_CONFIG := preload("res://resources/config/enemies/capoo_knight.tres")
const RPG_CONFIG := preload("res://resources/config/enemies/capoo_rpg.tres")
const PICKUP_SPEED_CONFIG := preload("res://resources/config/pickups/pickup_speed.tres")

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	await _test_scene_instantiation()
	_test_net_manager_lan_lifecycle()
	_test_net_manager_player_list_sync_diff()
	_test_recent_event_cache()
	_test_snapshot_packet_metrics()
	_test_freed_pickup_index_cleanup()
	await _test_enemy_proxy_action_animation_restore()
	await _test_player_multiplayer_death_visual_state()
	await _test_multiplayer_cheat_xirang_confirm()
	await _test_multiplayer_peer_disconnect_cleanup()
	await _test_player_snapshot_roster_reconcile()
	await _test_enemy_snapshot_roster_requires_complete_batch()
	await _test_four_player_runtime_and_confirmed_events()
	await _test_enemy_hit_dedupe_enemy_removed_and_pickup_confirm()
	await _test_game_runtime_modes()
	_test_snapshot_round_trip()
	for _cleanup_frame in range(4):
		await process_frame
		await physics_frame

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
		root.add_child(lobby)
		await process_frame
		_expect(lobby.is_inside_tree(), "multiplayer_lobby.tscn must enter the scene tree.")
		lobby.queue_free()
		await process_frame

	var mp_game := MP_GAME_SCENE.instantiate()
	_expect(mp_game != null, "mp_game.tscn must instantiate.")
	if mp_game != null:
		mp_game.free()

	var game := GAME_SCENE.instantiate()
	_expect(game != null, "game.tscn must instantiate as Game.")
	if game != null:
		game.configure_multiplayer(2, 2, {1: "Host", 2: "Client"})
		_stop_audio_players(game)
		game.free()

	var player := PLAYER_SCENE.instantiate() as Player
	_expect(player != null, "Player scene must instantiate for collision layer contract.")
	if player != null:
		_expect((player.collision_layer & 2) != 0, "Player body must live on the Player collision layer.")
		_expect((player.collision_mask & 2) == 0, "Player body must not collide with other Player bodies.")
		player.free()

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
	net_manager.host_start_game()
	_expect(int(net_manager.connection_state) == 4, "Host start must enter loading state.")
	_expect(not bool(net_manager.host_game_ready), "Host game ready must stay false until MpGame is ready.")
	net_manager.mark_in_game()
	_expect(int(net_manager.connection_state) == 5, "Host mark_in_game must enter in-game state.")
	_expect(bool(net_manager.host_game_ready), "Host mark_in_game must publish host ready state.")
	net_manager.disconnect_from_game()
	_expect(not net_manager.is_multiplayer_active(), "NetManager must cleanly disconnect after LAN host smoke.")


func _test_net_manager_player_list_sync_diff() -> void:
	var net_manager := root.get_node_or_null("NetManager")
	_expect(net_manager != null, "NetManager autoload is missing for player list sync diff test.")
	if net_manager == null:
		return
	net_manager.disconnect_from_game()
	net_manager.set("host_peer_id", 1)
	var connected_players := net_manager.get("connected_players") as Dictionary
	connected_players.clear()
	connected_players[1] = "Host"
	connected_players[2] = "Client"
	connected_players[3] = "Leaving"

	var left_events: Array[int] = []
	var joined_events: Array[int] = []
	var left_callback := func(peer_id: int) -> void:
		left_events.append(peer_id)
	var joined_callback := func(peer_id: int, _player_name: String) -> void:
		joined_events.append(peer_id)
	net_manager.player_left.connect(left_callback)
	net_manager.player_joined.connect(joined_callback)
	net_manager.call(
		"_rpc_sync_player_list",
		[
			{"id": 1, "name": "Host"},
			{"id": 2, "name": "Renamed"},
			{"id": 4, "name": "New"},
		],
		1
	)
	net_manager.player_left.disconnect(left_callback)
	net_manager.player_joined.disconnect(joined_callback)

	var synced_players := net_manager.get("connected_players") as Dictionary
	_expect(not synced_players.has(3), "Player list sync must remove peers missing from Host list.")
	_expect(synced_players.has(4), "Player list sync must add new peers from Host list.")
	_expect(str(synced_players.get(2, "")) == "Renamed", "Player list sync must update changed peer names.")
	_expect(left_events.has(3), "Player list sync must emit player_left for removed peers.")
	_expect(not left_events.has(2), "Player list sync must not emit player_left for retained peers.")
	_expect(joined_events.has(4), "Player list sync must emit player_joined for new peers.")
	_expect(joined_events.has(2), "Player list sync must emit player_joined for renamed peers.")
	net_manager.disconnect_from_game()


func _test_recent_event_cache() -> void:
	var mp_game := MP_GAME_SCENE.instantiate()
	_expect(mp_game != null, "MpGame scene must instantiate for recent event cache test.")
	if mp_game == null:
		return

	var cache := {}
	mp_game.call("_remember_recent_event", cache, "hit-a", 30.0, 10.0)
	_expect(
		bool(mp_game.call("_is_recent_event_cached", cache, "hit-a", 39.0)),
		"Recent event cache must keep entries inside the retention window."
	)
	_expect(
		not bool(mp_game.call("_is_recent_event_cached", cache, "hit-a", 41.0)),
		"Recent event cache must expire entries outside the retention window."
	)
	_expect(not cache.has("hit-a"), "Expired recent event cache entries must be erased on lookup.")

	mp_game.call("_remember_recent_event", cache, "hit-b", 5.0, 10.0)
	mp_game.call("_remember_recent_event", cache, "hit-c", 30.0, 10.0)
	mp_game.call("_prune_recent_event_cache", cache, 20.0)
	_expect(not cache.has("hit-b"), "Recent event prune must erase expired entries.")
	_expect(cache.has("hit-c"), "Recent event prune must keep live entries.")
	mp_game.free()


func _test_snapshot_packet_metrics() -> void:
	var mp_game := MP_GAME_SCENE.instantiate()
	_expect(mp_game != null, "MpGame scene must instantiate for snapshot metrics test.")
	if mp_game == null:
		return
	mp_game.call("_record_snapshot_packet_size", &"player", 128, 4)
	var metrics := mp_game.call("get_snapshot_packet_metrics") as Dictionary
	_expect(
		int(metrics.get("max_player_snapshot_packet_bytes", 0)) == 128,
		"Snapshot metrics must track max player packet size."
	)
	_expect(
		int(metrics.get("large_player_snapshot_packet_count", -1)) == 0,
		"Snapshot metrics must not count small player packets as large."
	)
	mp_game.call("_record_snapshot_packet_size", &"enemy", 1400, 90)
	metrics = mp_game.call("get_snapshot_packet_metrics") as Dictionary
	_expect(
		int(metrics.get("max_enemy_snapshot_packet_bytes", 0)) == 1400,
		"Snapshot metrics must track max enemy packet size."
	)
	_expect(
		int(metrics.get("large_enemy_snapshot_packet_count", 0)) == 1,
		"Snapshot metrics must count enemy packets over the warning threshold."
	)
	mp_game.call("_update_snapshot_packet_warning_timer", 10.0)
	mp_game.call("_record_snapshot_packet_size", &"enemy", 1500, 91)
	metrics = mp_game.call("get_snapshot_packet_metrics") as Dictionary
	_expect(
		int(metrics.get("large_enemy_snapshot_packet_count", 0)) == 2,
		"Snapshot metrics must keep counting large packets after warning cooldown."
	)
	mp_game.free()


func _test_freed_pickup_index_cleanup() -> void:
	var game := Game.new()
	_expect(game != null, "Game object must instantiate for pickup index cleanup test.")
	if game == null:
		return
	var pickup := Pickup.new()
	_expect(pickup != null, "Pickup object must instantiate for pickup index cleanup test.")
	if pickup == null:
		game.free()
		return
	game.multiplayer_pickups[77] = pickup
	pickup.free()
	_expect(game.get_pickup_for_net_id(77) == null, "Game must ignore freed pickup references by net id.")
	_expect(not game.multiplayer_pickups.has(77), "Game must erase freed pickup references from the net id index.")
	game.free()


func _test_multiplayer_peer_disconnect_cleanup() -> void:
	var game := GAME_SCENE.instantiate() as Game
	_expect(game != null, "Game scene must instantiate for multiplayer peer cleanup test.")
	if game == null:
		return
	game.configure_multiplayer(1, 1, {1: "Host", 2: "Client", 3: "Third"})
	game.set("auto_start_waves", false)
	root.add_child(game)
	await process_frame
	_expect(game.peer_players.has(2), "Game must create peer player 2 before cleanup.")
	var remote_player := game.peer_players.get(2) as Player
	if remote_player != null:
		remote_player.attack_damage = 37
	var parameter_mp_game := MP_GAME_SCENE.instantiate()
	parameter_mp_game.set("game", game)
	var accepted_parameters := parameter_mp_game.call(
		"_get_authoritative_client_projectile_parameters",
		&"player_bullet",
		2
	) as Dictionary
	_expect(
		int(accepted_parameters.get("damage", 0)) == 37,
		"Host must rebuild client player bullet damage from the authoritative player."
	)
	_expect(
		not accepted_parameters.is_empty() and float(accepted_parameters.get("speed", 0.0)) > 0.0,
		"Host must rebuild client player bullet speed from the scene default."
	)
	var rejected_parameters := parameter_mp_game.call(
		"_get_authoritative_client_projectile_parameters",
		&"capoo_ak47_bullet",
		2
	) as Dictionary
	_expect(rejected_parameters.is_empty(), "Host must reject client-spawned enemy projectile types.")
	_expect(
		bool(parameter_mp_game.call("_is_projectile_id_valid_for_owner", 2000001, 2)),
		"Projectile id namespace must match its owner peer."
	)
	_expect(
		not bool(parameter_mp_game.call("_is_projectile_id_valid_for_owner", 3000001, 2)),
		"Projectile id namespace must reject another peer's id."
	)
	var valid_direction := parameter_mp_game.call(
		"_get_valid_client_projectile_direction",
		Vector2(0.75, 0.0)
	) as Vector2
	_expect(valid_direction.is_equal_approx(Vector2.RIGHT), "Client projectile direction must be normalized.")
	var invalid_direction := parameter_mp_game.call(
		"_get_valid_client_projectile_direction",
		Vector2.ZERO
	) as Vector2
	_expect(invalid_direction == Vector2.ZERO, "Client projectile direction must reject zero vectors.")
	var near_spawn := remote_player.global_position + Vector2.RIGHT * remote_player.bullet_spawn_distance
	var far_spawn := remote_player.global_position + Vector2(1024.0, 0.0)
	_expect(
		bool(parameter_mp_game.call(
			"_is_client_projectile_spawn_position_allowed",
			&"player_bullet",
			2,
			near_spawn
		)),
		"Host must accept client projectile spawns near the authoritative player."
	)
	_expect(
		not bool(parameter_mp_game.call(
			"_is_client_projectile_spawn_position_allowed",
			&"player_bullet",
			2,
			far_spawn
		)),
		"Host must reject client projectile spawns far from the authoritative player."
	)
	_expect(
		int(parameter_mp_game.call("_get_authoritative_projectile_damage", 2999999, 2, 999)) == 37,
		"Host must cap recordless projectile hit damage to the authoritative player attack."
	)
	_expect(
		int(parameter_mp_game.call("_get_authoritative_projectile_damage", 3999999, 2, 999)) == -1,
		"Host must reject recordless projectile damage from another peer namespace."
	)
	if remote_player != null:
		remote_player.unlock_skill1()
		remote_player.skill1_charge_duration = 1.0
		remote_player.skill1_charge = 0.0
		var uncharged_skill1_parameters := parameter_mp_game.call(
			"_get_authoritative_client_projectile_parameters",
			&"skill1_bomb",
			2
		) as Dictionary
		_expect(uncharged_skill1_parameters.is_empty(), "Host must reject skill1 projectile before charge is full.")
		remote_player.skill1_charge = remote_player.skill1_charge_duration
		var charged_skill1_parameters := parameter_mp_game.call(
			"_get_authoritative_client_projectile_parameters",
			&"skill1_bomb",
			2
		) as Dictionary
		_expect(
			int(charged_skill1_parameters.get("damage", 0)) == floori(float(remote_player.attack_damage) * 3.3),
			"Host must rebuild skill1 projectile damage from authoritative player attack."
		)
		_expect(
			is_equal_approx(remote_player.skill1_charge, 0.0),
			"Host must consume authoritative skill1 charge when accepting a skill1 projectile."
		)
	parameter_mp_game.free()
	await process_frame
	await physics_frame
	game.remove_multiplayer_player(2)
	await process_frame
	_expect(not game.peer_players.has(2), "Game must erase disconnected peer players.")
	_expect(not game.multiplayer_player_names.has(2), "Game must erase disconnected peer names.")
	_expect(game.peer_players.has(1), "Game must keep the local host player during peer cleanup.")
	_expect(remote_player == null or not is_instance_valid(remote_player), "Game must free disconnected peer player nodes.")
	_stop_audio_players(game)
	game.queue_free()
	await process_frame
	await physics_frame

	var mp_game := MP_GAME_SCENE.instantiate()
	_expect(mp_game != null, "MpGame scene must instantiate for network peer cleanup test.")
	if mp_game == null:
		return
	mp_game.player_interpolators[2] = NetInterpolator.new(0.1)
	var sequence_cache := mp_game.get("_last_player_state_sequences") as Dictionary
	var accepted_positions := mp_game.get("_accepted_player_state_positions") as Dictionary
	var accepted_times := mp_game.get("_accepted_player_state_times") as Dictionary
	var health_revisions := mp_game.get("_player_health_revisions") as Dictionary
	var revive_times := mp_game.get("_dead_player_revive_times") as Dictionary
	var revive_seconds := mp_game.get("_dead_player_revive_last_seconds") as Dictionary
	sequence_cache[2] = 10
	accepted_positions[2] = Vector2(12.0, 34.0)
	accepted_times[2] = 5.0
	health_revisions[2] = 3
	revive_times[2] = 8.0
	revive_seconds[2] = 7

	var projectile := Bullet.new()
	projectile.owner_peer_id = 2
	root.add_child(projectile)
	var known_projectiles := mp_game.get("_known_projectiles") as Dictionary
	var projectile_records := mp_game.get("_projectile_records") as Dictionary
	known_projectiles[2000001] = projectile
	mp_game.call("_remember_projectile_record", 2000001, 2, &"player_bullet", 19, 2.0)
	_expect(
		int(mp_game.call("_get_authoritative_projectile_damage", 2000001, 2, 999)) == 19,
		"MpGame must read projectile damage from host projectile records."
	)
	_expect(
		int(mp_game.call("_get_authoritative_projectile_damage", 2000001, 3, 19)) == -1,
		"MpGame must reject projectile damage records with the wrong owner."
	)

	mp_game.call("_clear_peer_network_state", 2)
	_expect(not mp_game.player_interpolators.has(2), "MpGame must clear disconnected peer interpolators.")
	_expect(not sequence_cache.has(2), "MpGame must clear disconnected peer input sequence state.")
	_expect(not accepted_positions.has(2), "MpGame must clear disconnected peer accepted position state.")
	_expect(not accepted_times.has(2), "MpGame must clear disconnected peer accepted time state.")
	_expect(not health_revisions.has(2), "MpGame must clear disconnected peer health revisions.")
	_expect(not revive_times.has(2), "MpGame must clear disconnected peer revive timers.")
	_expect(not revive_seconds.has(2), "MpGame must clear disconnected peer revive countdown state.")
	_expect(not known_projectiles.has(2000001), "MpGame must erase disconnected peer projectile indexes.")
	_expect(not projectile_records.has(2000001), "MpGame must erase disconnected peer projectile records.")
	await process_frame
	_expect(not is_instance_valid(projectile), "MpGame must free disconnected peer projectile nodes.")
	mp_game.free()
	await process_frame
	await physics_frame


func _test_player_snapshot_roster_reconcile() -> void:
	var game := GAME_SCENE.instantiate() as Game
	_expect(game != null, "Game scene must instantiate for player roster reconcile test.")
	if game == null:
		return
	game.configure_multiplayer(2, 2, {1: "Host", 2: "Client", 3: "Leaving", 4: "Other"})
	game.set("auto_start_waves", false)
	root.add_child(game)
	await process_frame
	_expect(game.peer_players.size() == 4, "Client view must start with four visual peer players.")
	var stale_player := game.get_player_for_peer(3) as Player
	_expect(stale_player != null, "Client view must have the soon-stale peer before roster reconcile.")

	var mp_game := MP_GAME_SCENE.instantiate()
	_expect(mp_game != null, "MpGame scene must instantiate for player roster reconcile test.")
	if mp_game == null:
		_stop_audio_players(game)
		game.queue_free()
		await process_frame
		await physics_frame
		return
	mp_game.set("game", game)
	mp_game.player_interpolators[3] = NetInterpolator.new(0.1)
	var sequence_cache := mp_game.get("_last_player_state_sequences") as Dictionary
	var health_revisions := mp_game.get("_player_health_revisions") as Dictionary
	sequence_cache[3] = 12
	health_revisions[3] = 4

	var projectile := Bullet.new()
	projectile.owner_peer_id = 3
	root.add_child(projectile)
	var known_projectiles := mp_game.get("_known_projectiles") as Dictionary
	var projectile_records := mp_game.get("_projectile_records") as Dictionary
	known_projectiles[3000001] = projectile
	mp_game.call("_remember_projectile_record", 3000001, 3, &"player_bullet", 21, 2.0)

	mp_game.call("_reconcile_player_roster", {})
	_expect(game.peer_players.has(3), "Empty player roster snapshots must not remove peers.")
	mp_game.call("_reconcile_player_roster", {1: true, 2: true, 4: true})
	await process_frame
	_expect(not game.peer_players.has(3), "Client view must remove peers missing from a complete Host snapshot.")
	_expect(game.peer_players.has(2), "Client view roster reconcile must keep the local player.")
	_expect(game.peer_players.has(4), "Client view roster reconcile must keep peers still present in the Host snapshot.")
	_expect(not mp_game.player_interpolators.has(3), "Roster reconcile must clear missing peer interpolators.")
	_expect(not sequence_cache.has(3), "Roster reconcile must clear missing peer input sequence state.")
	_expect(not health_revisions.has(3), "Roster reconcile must clear missing peer health revisions.")
	_expect(not known_projectiles.has(3000001), "Roster reconcile must clear missing peer projectiles.")
	_expect(not projectile_records.has(3000001), "Roster reconcile must clear missing peer projectile records.")
	_expect(stale_player == null or not is_instance_valid(stale_player), "Roster reconcile must free missing peer player nodes.")
	_expect(not is_instance_valid(projectile), "Roster reconcile must free missing peer projectile nodes.")

	_stop_audio_players(game)
	mp_game.free()
	game.queue_free()
	await process_frame
	await physics_frame


func _test_enemy_snapshot_roster_requires_complete_batch() -> void:
	var game := GAME_SCENE.instantiate() as Game
	_expect(game != null, "Game scene must instantiate for enemy roster snapshot test.")
	if game == null:
		return
	game.configure_multiplayer(2, 2, {1: "Host", 2: "Client"})
	game.set("auto_start_waves", false)
	root.add_child(game)
	await process_frame

	var enemy_a := BASIC_CONFIG.enemy_scene.instantiate() as Enemy
	var enemy_b := BASIC_CONFIG.enemy_scene.instantiate() as Enemy
	_expect(enemy_a != null and enemy_b != null, "Enemy roster snapshot test must instantiate enemies.")
	if enemy_a == null or enemy_b == null:
		if enemy_a != null:
			enemy_a.queue_free()
		if enemy_b != null:
			enemy_b.queue_free()
		_stop_audio_players(game)
		game.queue_free()
		await process_frame
		await physics_frame
		return
	game.enemy_container.add_child(enemy_a)
	game.enemy_container.add_child(enemy_b)

	var mp_game := MP_GAME_SCENE.instantiate()
	_expect(mp_game != null, "MpGame scene must instantiate for enemy roster snapshot test.")
	if mp_game == null:
		enemy_a.queue_free()
		enemy_b.queue_free()
		_stop_audio_players(game)
		game.queue_free()
		await process_frame
		await physics_frame
		return
	mp_game.set("game", game)
	var net_enemies := mp_game.get("_net_enemies") as Dictionary
	var enemy_spawn_times := mp_game.get("_enemy_spawn_snapshot_times") as Dictionary
	net_enemies[7] = enemy_a
	net_enemies[8] = enemy_b
	enemy_spawn_times[7] = 0.0
	enemy_spawn_times[8] = 0.0

	var snapshot_mgr := SnapshotManager.new()
	var state_a := SnapshotManager.EnemyState.new()
	state_a.net_id = 7
	state_a.position = Vector2(10.0, 20.0)
	state_a.velocity = Vector2.RIGHT
	state_a.health = 12
	var state_b := SnapshotManager.EnemyState.new()
	state_b.net_id = 8
	state_b.position = Vector2(30.0, 40.0)
	state_b.velocity = Vector2.LEFT
	state_b.health = 11

	var two_enemy_data := snapshot_mgr.encode_all_enemy_snapshots([state_a, state_b])
	var truncated_two_enemy_data := two_enemy_data.duplicate()
	truncated_two_enemy_data.resize(maxi(two_enemy_data.size() - 3, 0))
	var partial_states := SnapshotManager.decode_all_enemy_snapshots(truncated_two_enemy_data)
	_expect(
		partial_states.size() == 1,
		"Two-enemy truncated snapshots should decode the complete leading enemy only."
	)
	mp_game.call("_rpc_receive_enemy_snapshot", 0.0, truncated_two_enemy_data)
	_expect(net_enemies.has(8), "Incomplete enemy snapshot batches must not reconcile away unseen enemies.")
	_expect(is_instance_valid(enemy_b), "Incomplete enemy snapshot batches must not free unseen enemies.")

	var one_enemy_data := snapshot_mgr.encode_all_enemy_snapshots([state_a])
	mp_game.call("_rpc_receive_enemy_snapshot", 0.0, one_enemy_data)
	await process_frame
	_expect(not net_enemies.has(8), "Complete enemy snapshot batches must reconcile stale enemies.")
	_expect(not is_instance_valid(enemy_b), "Complete enemy snapshot batches must free stale enemies.")
	_expect(net_enemies.has(7), "Complete enemy snapshot batches must keep seen enemies.")

	enemy_a.queue_free()
	mp_game.free()
	_stop_audio_players(game)
	game.queue_free()
	await process_frame
	await physics_frame


func _test_four_player_runtime_and_confirmed_events() -> void:
	var game := GAME_SCENE.instantiate() as Game
	_expect(game != null, "Game scene must instantiate for four-player smoke test.")
	if game == null:
		return
	var player_names := {
		1: "Host",
		2: "ClientA",
		3: "ClientB",
		4: "ClientC",
	}
	game.configure_multiplayer(1, 1, player_names)
	game.set("auto_start_waves", false)
	root.add_child(game)
	await process_frame
	_expect(game.peer_players.size() == 4, "Host authority game must create four peer players.")
	_expect(game.collect_player_snapshot_states().size() == 4, "Four-player host snapshots must include every peer.")
	for peer_id in [1, 2, 3, 4]:
		var player := game.get_player_for_peer(peer_id) as Player
		_expect(player != null, "Four-player game missing peer %d." % peer_id)
		if player == null:
			continue
		_expect(player.peer_id == peer_id, "Four-player player peer id mismatch for peer %d." % peer_id)
		if peer_id == 1:
			_expect(player.uses_local_input, "Host player must keep local input.")
		else:
			_expect(not player.uses_local_input, "Remote host-side players must not use local input.")

	var mp_game := MP_GAME_SCENE.instantiate()
	_expect(mp_game != null, "MpGame scene must instantiate for four-player confirmed event test.")
	if mp_game == null:
		_stop_audio_players(game)
		game.queue_free()
		await process_frame
		await physics_frame
		return
	mp_game.set("game", game)
	var net_manager := root.get_node_or_null("NetManager")
	if net_manager != null:
		mp_game.set("net_manager", net_manager)
	var run_state := root.get_node_or_null("RunState")
	if run_state != null:
		run_state.call("begin_new_run")
		mp_game.set("run_state", run_state)
		mp_game.call("_apply_upgrade_for_peer", 0, RunStateStore.StatType.ATTACK)
		mp_game.call("_apply_skill1_purchase_for_peer", 0)
		_expect(
			not (run_state.get("multiplayer_upgrade_levels") as Dictionary).has(0),
			"Invalid peer upgrade requests must not create peer 0 run state."
		)
		mp_game.call("net_upgrade_confirmed", 99, RunStateStore.StatType.ATTACK, 1, 25, true)
		_expect(
			not (run_state.get("multiplayer_upgrade_levels") as Dictionary).has(99),
			"Upgrade confirms for missing peers must not create run state."
		)

	var peer_four := game.get_player_for_peer(4) as Player
	_expect(peer_four != null, "Peer 4 must exist for confirmed event test.")
	if peer_four != null:
		var health_revisions := mp_game.get("_player_health_revisions") as Dictionary
		mp_game.call("net_player_damage_applied", 99, 0, true, 8)
		mp_game.call("net_player_revived", 99, Vector2(4.0, 8.0), 10, 0.5, 9)
		_expect(
			not health_revisions.has(99),
			"Invalid player damage/revive confirms must not pollute health revisions."
		)
		var base_attack := peer_four.attack_damage
		mp_game.call("net_upgrade_confirmed", 4, RunStateStore.StatType.ATTACK, 1, 75, true)
		_expect(peer_four.attack_damage == base_attack + 4, "Upgrade confirm must apply to the selected peer.")
		_expect(peer_four.current_xirang == 75, "Upgrade confirm must update the selected peer's xirang.")
		mp_game.call("net_skill1_purchase_confirmed", 4, 25, true, 0)
		_expect(peer_four.has_skill1(), "Skill1 purchase confirm must unlock the selected peer.")
		_expect(peer_four.current_xirang == 25, "Skill1 purchase confirm must update xirang.")
		peer_four.current_xirang = 525
		var skill1_duration_before_upgrade := peer_four.skill1_charge_duration
		var skill1_upgrade_result := game.try_purchase_skill1_for_peer(4)
		_expect(
			skill1_upgrade_result == Game.PURCHASE_RESULT_SKILL1_UPGRADE_SUCCESS,
			"Owned skill1 transaction must upgrade skill1 on host."
		)
		_expect(peer_four.current_xirang == 25, "Skill1 upgrade must deduct the first 500 xirang cost.")
		_expect(peer_four.skill1_upgrade_level == 1, "Skill1 upgrade must increment the player level.")
		_expect(
			is_equal_approx(peer_four.skill1_charge_duration, skill1_duration_before_upgrade - 2.0),
			"Skill1 upgrade must reduce charge duration by 2 seconds."
		)
		mp_game.call(
			"net_skill1_purchase_confirmed",
			4,
			777,
			true,
			Game.PURCHASE_RESULT_SKILL1_UPGRADE_SUCCESS,
			2,
			peer_four.skill1_charge_duration - 2.0
		)
		_expect(peer_four.current_xirang == 777, "Skill1 upgrade confirm must update xirang.")
		_expect(peer_four.skill1_upgrade_level == 2, "Skill1 upgrade confirm must update upgrade level.")
		_expect(
			is_equal_approx(peer_four.skill1_charge_duration, skill1_duration_before_upgrade - 4.0),
			"Skill1 upgrade confirm must update charge duration."
		)
		peer_four.skill1_charge_duration = 1.0
		peer_four.skill1_charge = 0.0
		game.call("_update_multiplayer_remote_player_passive_state", 0.5)
		_expect(peer_four.skill1_charge > 0.0, "Host passive tick must charge remote players' skill1.")
		mp_game.call("net_player_damage_applied", 4, 0, true, 2)
		_expect(peer_four.is_dead, "Damage confirm must put the selected peer into death state.")
		mp_game.call("net_player_damage_applied", 4, peer_four.max_health, false, 1)
		_expect(peer_four.is_dead, "Stale damage revisions must be ignored.")
		mp_game.call("net_player_revived", 4, Vector2(32.0, 48.0), peer_four.max_health, 1.25, 3)
		_expect(not peer_four.is_dead, "Revive confirm must clear the selected peer death state.")
		_expect(peer_four.global_position == Vector2(32.0, 48.0), "Revive confirm must move the selected peer.")

	var peer_two := game.get_player_for_peer(2) as Player
	var peer_three := game.get_player_for_peer(3) as Player
	if peer_two != null and peer_three != null:
		var xirang_orbs := mp_game.get("_xirang_orbs") as Dictionary
		xirang_orbs[440] = {"amount": 9, "drop": null}
		var peer_two_xirang := peer_two.current_xirang
		var peer_three_xirang := peer_three.current_xirang
		mp_game.call("_apply_xirang_orb_collected", 440, 0)
		mp_game.call("_apply_xirang_orb_collected", 440, 99)
		_expect(peer_two.current_xirang == peer_two_xirang, "Invalid xirang collectors must not grant peer 2.")
		_expect(peer_three.current_xirang == peer_three_xirang, "Invalid xirang collectors must not grant peer 3.")
		_expect(xirang_orbs.has(440), "Invalid xirang collectors must not remove the orb.")
		mp_game.call("_apply_xirang_orb_collected", 440, 2)
		_expect(peer_two.current_xirang == peer_two_xirang + 9, "Valid xirang collector must grant peer 2.")
		_expect(peer_three.current_xirang == peer_three_xirang + 9, "Valid xirang collector must grant peer 3.")
		_expect(not xirang_orbs.has(440), "Valid xirang collector must remove the collected orb.")
		peer_two_xirang = peer_two.current_xirang
		peer_three_xirang = peer_three.current_xirang
		mp_game.call("_grant_xirang_to_all_players", 12)
		_expect(peer_two.current_xirang == peer_two_xirang + 12, "Xirang grant must update peer 2.")
		_expect(peer_three.current_xirang == peer_three_xirang + 12, "Xirang grant must update peer 3.")

	mp_game.free()
	_stop_audio_players(game)
	game.queue_free()
	await process_frame
	await physics_frame


func _test_enemy_hit_dedupe_enemy_removed_and_pickup_confirm() -> void:
	var host_game := GAME_SCENE.instantiate() as Game
	_expect(host_game != null, "Game scene must instantiate for enemy hit dedupe test.")
	if host_game == null:
		return
	host_game.configure_multiplayer(1, 1, {1: "Host", 2: "Client"})
	host_game.set("auto_start_waves", false)
	root.add_child(host_game)
	await process_frame
	_expect(host_game.call("_try_spawn_enemy", BASIC_CONFIG), "Host must spawn an enemy for hit dedupe test.")
	var host_enemy := host_game.get_enemy_for_net_id(1)
	_expect(host_enemy != null, "Host spawned enemy must be indexed by net id for hit dedupe test.")
	if host_enemy != null:
		var mp_game := MP_GAME_SCENE.instantiate()
		mp_game.set("game", host_game)
		mp_game.call("_remember_projectile_record", 2000001, 2, &"player_bullet", 11, 2.0)
		var health_before_hit := host_enemy.current_health
		mp_game.call("_apply_enemy_hit_report", 2000001, 2, 1, 999, Vector2.LEFT)
		var health_after_first_hit := host_enemy.current_health
		mp_game.call("_apply_enemy_hit_report", 2000001, 2, 1, 999, Vector2.LEFT)
		_expect(health_after_first_hit < health_before_hit, "First enemy hit report must damage the enemy.")
		_expect(
			host_enemy.current_health == health_after_first_hit,
			"Duplicate enemy hit reports for the same projectile/enemy pair must be ignored."
		)
		mp_game.free()
	_stop_audio_players(host_game)
	host_game.queue_free()
	await process_frame
	await physics_frame

	var client_game := GAME_SCENE.instantiate() as Game
	_expect(client_game != null, "Game scene must instantiate for client event cleanup test.")
	if client_game == null:
		return
	client_game.configure_multiplayer(2, 2, {1: "Host", 2: "Client"})
	client_game.set("auto_start_waves", false)
	root.add_child(client_game)
	await process_frame
	var client_mp_game := MP_GAME_SCENE.instantiate()
	client_mp_game.set("game", client_game)
	var net_manager := root.get_node_or_null("NetManager")
	if net_manager != null:
		client_mp_game.set("net_manager", net_manager)

	var client_enemy := BOMBER_CONFIG.enemy_scene.instantiate() as Enemy
	_expect(client_enemy != null, "Client bomber scene must instantiate for enemy removed test.")
	if client_enemy != null:
		client_game.enemy_container.add_child(client_enemy)
		client_enemy.setup(BOMBER_CONFIG, client_game.player, client_game.grid_pathfinder)
		client_enemy.configure_multiplayer_proxy()
		client_enemy.set_meta("net_id", 77)
		var client_net_enemies := client_mp_game.get("_net_enemies") as Dictionary
		var spawn_times := client_mp_game.get("_enemy_spawn_snapshot_times") as Dictionary
		client_net_enemies[77] = client_enemy
		spawn_times[77] = 0.0
		client_mp_game.enemy_interpolators[77] = NetInterpolator.new(0.1)
		client_mp_game.call("net_enemy_defeated", 77, Vector2(44.0, 55.0))
		await process_frame
		_expect(not client_net_enemies.has(77), "Client enemy defeated event must erase the enemy index.")
		_expect(not spawn_times.has(77), "Client enemy defeated event must erase spawn timing.")
		_expect(not client_mp_game.enemy_interpolators.has(77), "Client enemy defeated event must clear interpolation state.")
		_expect(is_instance_valid(client_enemy), "Client enemy defeated event must keep the node long enough to play death visuals.")
		_expect(client_enemy.global_position == Vector2(44.0, 55.0), "Client enemy defeated event must apply the authoritative death position.")
		_expect(client_enemy.is_dead, "Client enemy defeated event must start the proxy death sequence.")
		_expect(
			client_enemy.death_sequence_stage == Enemy.DeathSequenceStage.DEATH,
			"Client enemy defeated event must start with the death animation stage."
		)
		client_enemy.call("_finish_after_death_animation")
		_expect(
			client_enemy.death_sequence_stage == Enemy.DeathSequenceStage.EXPLOSION,
			"Client bomber death visuals must continue into the explosion stage."
		)

	client_mp_game.call(
		"net_pickup_spawned",
		9001,
		PICKUP_SPEED_CONFIG.resource_path,
		44.0,
		55.0
	)
	var spawned_pickup := client_game.get_pickup_for_net_id(9001)
	_expect(spawned_pickup != null, "Client pickup spawn event must create a pickup.")
	var client_player := client_game.get_player_for_peer(2) as Player
	_expect(client_player != null, "Client player must exist for pickup confirm test.")
	if client_player != null:
		var base_multiplier := client_player.current_move_speed_multiplier
		client_mp_game.call(
			"net_pickup_collected",
			9001,
			2,
			PICKUP_SPEED_CONFIG.resource_path,
			true
		)
		await process_frame
		_expect(not client_game.multiplayer_pickups.has(9001), "Pickup collected event must erase pickup index.")
		_expect(
			client_player.current_move_speed_multiplier > base_multiplier,
			"Pickup collected event must apply immediate pickup effects to the collector."
		)
	client_mp_game.free()
	_stop_audio_players(client_game)
	client_game.queue_free()
	await process_frame
	await physics_frame


func _stop_audio_players(node: Node) -> void:
	for child in node.get_children():
		var audio_player := child as AudioStreamPlayer
		if audio_player != null:
			audio_player.stop()
			audio_player.stream = null
		var audio_player_2d := child as AudioStreamPlayer2D
		if audio_player_2d != null:
			audio_player_2d.stop()
			audio_player_2d.stream = null
		_stop_audio_players(child)


func _test_enemy_proxy_action_animation_restore() -> void:
	await _expect_proxy_action_restores_to_move(
		KNIGHT_CONFIG,
		&"slash",
		KNIGHT_CONFIG.attack_animation_name,
		"Knight proxy slash animation must restore to move."
	)
	await _expect_proxy_action_restores_to_move(
		RPG_CONFIG,
		&"fire",
		RPG_CONFIG.attack_animation_name,
		"RPG proxy fire animation must restore to move."
	)

	var short_windup_config := KNIGHT_CONFIG.duplicate(true) as EnemyConfig
	short_windup_config.set("attack_windup", 0.01)
	await _expect_proxy_action_restores_to_move(
		short_windup_config,
		&"windup",
		StringName(short_windup_config.get("windup_animation_name")),
		"Looping proxy windup animation must time out back to move."
	)


func _expect_proxy_action_restores_to_move(
	enemy_config: EnemyConfig,
	action_name: StringName,
	expected_action_animation: StringName,
	message: String
) -> void:
	var enemy := enemy_config.enemy_scene.instantiate() as Enemy
	_expect(enemy != null, "Proxy enemy scene must instantiate for action animation test.")
	if enemy == null:
		return

	root.add_child(enemy)
	await process_frame
	enemy.setup(enemy_config, null, null)
	enemy.configure_multiplayer_proxy()
	var sprite := enemy.get_node("AnimatedSprite2D") as AnimatedSprite2D
	_expect(sprite != null, "Proxy enemy must have an AnimatedSprite2D.")
	if sprite == null:
		enemy.queue_free()
		await process_frame
		return

	sprite.speed_scale = 24.0
	enemy.call("play_multiplayer_enemy_action", action_name, Vector2.RIGHT, 1)
	_expect(sprite.animation == expected_action_animation, message + " Action animation did not start.")
	await _wait_for_sprite_animation(sprite, enemy_config.move_animation_name, 1.0)
	_expect(sprite.animation == enemy_config.move_animation_name, message)
	_expect(sprite.is_playing(), message + " Move animation must keep playing.")
	enemy.queue_free()
	await process_frame


func _test_player_multiplayer_death_visual_state() -> void:
	var player := PLAYER_SCENE.instantiate() as Player
	_expect(player != null, "Player scene must instantiate for multiplayer death visual test.")
	if player == null:
		return

	root.add_child(player)
	await process_frame
	player.configure_multiplayer_control(2, false, "Client")
	player.unlock_skill1()
	player.call("_update_skill1_charge", player.skill1_charge_duration)
	_expect(player.skill1_charge_bar.visible, "Multiplayer player skill1 bar must be visible while alive.")

	player.apply_multiplayer_death_state()
	await process_frame
	_expect(player.is_dead, "Multiplayer player did not enter death state.")
	_expect(not player.body_sprite.visible, "Multiplayer death must hide the body sprite.")
	_expect(not player.health_bar.visible, "Multiplayer death must hide the health bar.")
	_expect(not player.skill1_charge_bar.visible, "Multiplayer death must hide the skill1 charge bar.")
	player.set_multiplayer_revive_countdown(7)
	await process_frame
	_expect(player.nameplate_layer.visible, "Multiplayer death countdown must keep the nameplate visible.")
	_expect(player.nameplate_label.text == "Client 7s", "Multiplayer death countdown text is incorrect.")

	player.revive_multiplayer(Vector2(8.0, 9.0), player.max_health, 0.0)
	await process_frame
	_expect(not player.is_dead, "Multiplayer revive must clear death state.")
	_expect(player.body_sprite.visible, "Multiplayer revive must show the body sprite.")
	_expect(player.health_bar.visible, "Multiplayer revive must show the health bar.")
	_expect(player.skill1_charge_bar.visible, "Multiplayer revive must restore unlocked skill1 charge bar.")

	player.queue_free()
	await process_frame


func _test_multiplayer_cheat_xirang_confirm() -> void:
	var mp_game := MP_GAME_SCENE.instantiate()
	_expect(mp_game != null, "MpGame scene must instantiate for cheat xirang confirm test.")
	if mp_game == null:
		return

	var host_game := GAME_SCENE.instantiate()
	_expect(host_game != null, "Game scene must instantiate for cheat xirang confirm test.")
	if host_game == null:
		mp_game.free()
		return

	host_game.configure_multiplayer(1, 1, {1: "Host", 2: "Client"})
	host_game.set("auto_start_waves", false)
	root.add_child(host_game)
	await process_frame
	mp_game.set("game", host_game)

	var remote_player := host_game.get_player_for_peer(2) as Player
	_expect(remote_player != null, "Remote player must exist for cheat xirang confirm test.")
	if remote_player != null:
		remote_player.current_xirang = 15
		mp_game.call("net_cheat_xirang_confirmed", 2, 1015, 1000)
		_expect(remote_player.current_xirang == 1015, "Cheat confirm must update the selected peer's xirang.")

	_stop_audio_players(host_game)
	host_game.queue_free()
	mp_game.free()
	await process_frame


func _test_game_runtime_modes() -> void:
	var host_game := GAME_SCENE.instantiate()
	host_game.configure_multiplayer(1, 1, {1: "Host", 2: "Client"})
	host_game.set("auto_start_waves", false)
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
	_expect(host_game.call("_try_spawn_enemy", BASIC_CONFIG), "Host authority game must spawn an indexed enemy.")
	var spawned_enemy: Enemy = host_game.get_enemy_for_net_id(1)
	_expect(spawned_enemy != null, "Host authority game must index spawned enemies by net id.")
	if spawned_enemy != null:
		spawned_enemy.queue_free()
		await process_frame
		await physics_frame
	_expect(host_game.get_enemy_for_net_id(1) == null, "Host authority game must remove enemy net id indexes on exit.")
	_stop_audio_players(host_game)
	host_game.queue_free()
	await process_frame

	var client_game := GAME_SCENE.instantiate()
	client_game.configure_multiplayer(2, 2, {1: "Host", 2: "Client"})
	client_game.set("auto_start_waves", false)
	root.add_child(client_game)
	await process_frame
	_expect(client_game.peer_players.size() == 2, "Client view game must create visual peer players.")
	_expect(not client_game.auto_start_waves, "Client view must not start local waves.")
	_stop_audio_players(client_game)
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
	player_state.skill1_unlocked = true
	player_state.skill1_charge = 3.0
	player_state.skill1_charge_duration = 14.0
	player_state.skill1_upgrade_level = 2
	var player_data := snapshot_mgr.encode_all_player_snapshots([player_state])
	var player_states := SnapshotManager.decode_all_player_snapshots(player_data)
	_expect(player_states.size() == 1, "Player snapshot count mismatch.")
	if player_states.size() == 1:
		_expect(player_states[0].peer_id == 2, "Player snapshot peer_id mismatch.")
		_expect(player_states[0].current_health == 42, "Player snapshot health mismatch.")
		_expect(player_states[0].skill1_upgrade_level == 2, "Player snapshot skill1 upgrade level mismatch.")
	var player_data_2 := snapshot_mgr.encode_all_player_snapshots([player_state])
	var player_states_2 := SnapshotManager.decode_all_player_snapshots(player_data_2)
	_expect(
		player_states_2.size() == 1 and player_states_2[0].position.distance_to(player_state.position) < 0.12,
		"Repeated player snapshots must remain full snapshots."
	)
	var distant_player_state := SnapshotManager.PlayerState.new()
	distant_player_state.peer_id = 3
	distant_player_state.position = Vector2(99999.0, -99999.0)
	distant_player_state.velocity = Vector2(99999.0, -99999.0)
	var distant_player_data := snapshot_mgr.encode_all_player_snapshots([distant_player_state])
	var distant_player_states := SnapshotManager.decode_all_player_snapshots(distant_player_data)
	_expect(distant_player_states.size() == 1, "Out-of-range player snapshot must still decode one state.")
	if distant_player_states.size() == 1:
		_expect(
			is_equal_approx(distant_player_states[0].position.x, 3276.7)
			and is_equal_approx(distant_player_states[0].position.y, -3276.8),
			"Out-of-range player positions must saturate to the packed int16 range."
		)
		_expect(
			is_equal_approx(distant_player_states[0].velocity.x, 3276.7)
			and is_equal_approx(distant_player_states[0].velocity.y, -3276.8),
			"Out-of-range player velocities must saturate to the packed int16 range."
		)
	var truncated_player_data := player_data.duplicate()
	truncated_player_data.resize(maxi(player_data.size() - 3, 0))
	var truncated_player_states := SnapshotManager.decode_all_player_snapshots(truncated_player_data)
	_expect(truncated_player_states.is_empty(), "Truncated player snapshots must be ignored without decoding partial state.")
	var count_only_player_data := PackedByteArray([1])
	var count_only_player_states := SnapshotManager.decode_all_player_snapshots(count_only_player_data)
	_expect(count_only_player_states.is_empty(), "Player snapshot count without payload must decode to no states.")

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
	var distant_enemy_state := SnapshotManager.EnemyState.new()
	distant_enemy_state.net_id = 8
	distant_enemy_state.position = Vector2(-99999.0, 99999.0)
	distant_enemy_state.velocity = Vector2(-99999.0, 99999.0)
	var distant_enemy_data := snapshot_mgr.encode_all_enemy_snapshots([distant_enemy_state])
	var distant_enemy_states := SnapshotManager.decode_all_enemy_snapshots(distant_enemy_data)
	_expect(distant_enemy_states.size() == 1, "Out-of-range enemy snapshot must still decode one state.")
	if distant_enemy_states.size() == 1:
		_expect(
			is_equal_approx(distant_enemy_states[0].position.x, -3276.8)
			and is_equal_approx(distant_enemy_states[0].position.y, 3276.7),
			"Out-of-range enemy positions must saturate to the packed int16 range."
		)
		_expect(
			is_equal_approx(distant_enemy_states[0].velocity.x, -3276.8)
			and is_equal_approx(distant_enemy_states[0].velocity.y, 3276.7),
			"Out-of-range enemy velocities must saturate to the packed int16 range."
		)
	var truncated_enemy_data := enemy_data.duplicate()
	truncated_enemy_data.resize(maxi(enemy_data.size() - 2, 0))
	var truncated_enemy_states := SnapshotManager.decode_all_enemy_snapshots(truncated_enemy_data)
	_expect(truncated_enemy_states.is_empty(), "Truncated enemy snapshots must be ignored without decoding partial state.")
	var count_only_enemy_stream := StreamPeerBuffer.new()
	count_only_enemy_stream.put_u16(1)
	var count_only_enemy_states := SnapshotManager.decode_all_enemy_snapshots(count_only_enemy_stream.data_array)
	_expect(count_only_enemy_states.is_empty(), "Enemy snapshot count without payload must decode to no states.")


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _wait_process_frames(frame_count: int) -> void:
	for _frame_index in range(frame_count):
		await process_frame


func _wait_for_sprite_animation(
	sprite: AnimatedSprite2D,
	expected_animation: StringName,
	timeout_seconds: float
) -> void:
	var end_time := Time.get_ticks_msec() + int(timeout_seconds * 1000.0)
	while Time.get_ticks_msec() <= end_time:
		if sprite != null and is_instance_valid(sprite) and sprite.animation == expected_animation:
			return
		await process_frame
