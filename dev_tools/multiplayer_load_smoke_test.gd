extends SceneTree

const LOBBY_SCENE := preload("res://scene/multiplayer/multiplayer_lobby.tscn")
const MP_GAME_SCENE := preload("res://scene/multiplayer/mp_game.tscn")
const GAME_SCENE := preload("res://scene/game.tscn")
const PLAYER_SCENE := preload("res://scene/player.tscn")
const BASIC_CONFIG := preload("res://resources/config/enemies/yuanshi_insect_basic.tres")
const KNIGHT_CONFIG := preload("res://resources/config/enemies/capoo_knight.tres")
const RPG_CONFIG := preload("res://resources/config/enemies/capoo_rpg.tres")

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_scene_instantiation()
	_test_net_manager_lan_lifecycle()
	_test_recent_event_cache()
	_test_freed_pickup_index_cleanup()
	await _test_enemy_proxy_action_animation_restore()
	await _test_player_multiplayer_death_visual_state()
	await _test_multiplayer_cheat_xirang_confirm()
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
	await _wait_process_frames(24)
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
	_expect(player.body_sprite.visible, "Multiplayer death must keep the body sprite visible.")
	_expect(player.body_sprite.animation == &"death", "Multiplayer death must play the death animation.")
	_expect(not player.health_bar.visible, "Multiplayer death must hide the health bar.")
	_expect(not player.skill1_charge_bar.visible, "Multiplayer death must hide the skill1 charge bar.")

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
	host_game.queue_free()
	await process_frame

	var client_game := GAME_SCENE.instantiate()
	client_game.configure_multiplayer(2, 2, {1: "Host", 2: "Client"})
	client_game.set("auto_start_waves", false)
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


func _wait_process_frames(frame_count: int) -> void:
	for _frame_index in range(frame_count):
		await process_frame
