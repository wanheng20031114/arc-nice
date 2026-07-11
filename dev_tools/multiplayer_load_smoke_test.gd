extends SceneTree

const LOBBY_SCENE := preload("res://scene/multiplayer/multiplayer_lobby.tscn")
const MP_GAME_SCENE := preload("res://scene/multiplayer/mp_game.tscn")
const GAME_SCENE := preload("res://scene/game.tscn")
const PLAYER_SCENE := preload("res://scene/player/weishidaier/player_weishidaier.tscn")
const BASIC_CONFIG := preload("res://resources/config/enemies/yuanshi_insect_basic.tres")
const BOMBER_CONFIG := preload("res://resources/config/enemies/yuanshi_insect_bomber.tres")
const KNIGHT_CONFIG := preload("res://resources/config/enemies/capoo_knight.tres")
const RPG_CONFIG := preload("res://resources/config/enemies/capoo_rpg.tres")
const SNIPER_CONFIG := preload("res://resources/config/enemies/capoo_sniper.tres")
const PICKUP_SPEED_CONFIG := preload("res://resources/config/pickups/pickup_speed.tres")
const PICKUP_SPIRAL_CONFIG := preload("res://resources/config/pickups/pickup_spiral.tres")
const HEALTH_PICKUP := preload("res://resources/config/pickups/pickup_health.tres")
const XIRANG_DROP_SCENE := preload("res://scene/xirang_drop.tscn")
const XIRANG_DROP_CONFIG := preload("res://resources/config/xirang_drop.tres")
const LINGLAN_SKILL2_ROCKET_SCENE := preload("res://scene/boss/linglan/linglan_skill2_sakura_rocket.tscn")
const APPLE_COLLECTIBLE := preload("res://resources/config/collectibles/collectible_apple.tres")
const ARCHER_COLLECTIBLE := preload("res://resources/config/collectibles/collectible_archer.tres")
const LIFE_CRYSTAL := preload("res://resources/config/collectibles/collectible_life_crystal.tres")
const LINGLAN_BOSS_CONFIG := preload("res://resources/config/bosses/boss_01_linglan.tres")
const NetConstants := preload("res://scene/multiplayer/net_constants.gd")
const PROJECTILE_EVENTS_ONLY_ARG := "--projectile-events-only"

var failures: Array[String] = []


class ClientViewRuntimeStub:
	extends Node

	func is_client_view_runtime() -> bool:
		return true


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	if OS.get_cmdline_user_args().has(PROJECTILE_EVENTS_ONLY_ARG):
		await _test_enemy_hit_dedupe_enemy_removed_and_pickup_confirm()
		for _cleanup_frame in range(4):
			await process_frame
			await physics_frame
		_finish_test_run()
		return

	await _test_scene_instantiation()
	_test_net_manager_protocol_version_gate()
	_test_net_manager_lan_lifecycle()
	_test_public_room_context_lifecycle()
	_test_net_manager_player_list_sync_diff()
	_test_recent_event_cache()
	_test_snapshot_packet_metrics()
	_test_delta_snapshot_peer_cache_cleanup()
	_test_freed_pickup_index_cleanup()
	_test_xirang_drop_attraction_radius()
	await _test_enemy_proxy_action_animation_restore()
	await _test_player_multiplayer_death_visual_state()
	await _test_multiplayer_revive_position_uses_living_players()
	await _test_multiplayer_revive_resets_remote_visual_interpolator()
	await _test_client_local_damage_confirm_starts_hurt_blink()
	await _test_linglan_boss_registration_uses_boss_event_only()
	await _test_linglan_boss_proxy_keeps_body_hit_collision()
	await _test_client_linglan_skill2_rocket_does_not_damage_enemy_proxy()
	await _test_multiplayer_cheat_xirang_confirm()
	await _test_multiplayer_peer_disconnect_cleanup()
	await _test_player_snapshot_roster_reconcile()
	await _test_enemy_snapshot_roster_requires_complete_batch()
	await _test_enemy_snapshot_death_and_empty_roster_cleanup()
	await _test_host_remote_player_position_writeback()
	_test_projectile_time_compensation()
	await _test_enemy_action_uses_snapshot_timeline()
	await _test_host_remote_player_form_buff_expires()
	await _test_four_player_runtime_and_confirmed_events()
	await _test_multiplayer_character_scene_registry()
	await _test_host_authoritative_hoe_actions()
	await _test_host_authoritative_tiyi_protocol()
	await _test_enemy_hit_dedupe_enemy_removed_and_pickup_confirm()
	await _test_game_runtime_modes()
	_test_snapshot_round_trip()
	for _cleanup_frame in range(4):
		await process_frame
		await physics_frame
	_finish_test_run()


func _finish_test_run() -> void:

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
		_expect(
			mp_game.get_node_or_null("PublicRoomKeepaliveRequest") is HTTPRequest,
			"MpGame must keep a native HTTPRequest node for public room keepalive."
		)
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
	net_manager.set_local_character_id(&"weishidaier", true)
	var err: Error = net_manager.host_create_lan_server(29171)
	_expect(err == OK, "NetManager must create a LAN host on test port.")
	_expect(net_manager.is_host(), "NetManager must enter host role.")
	_expect(net_manager.connected_players.has(1), "Host peer must be registered.")
	_expect(
		net_manager.get_player_character_id(1) == &"weishidaier"
		and net_manager.is_player_character_confirmed(1),
		"Host character id and confirmation must be registered with the host roster."
	)
	net_manager.set_local_character_id(&"weishidaier", false)
	net_manager.host_start_game()
	_expect(
		int(net_manager.connection_state) == 1,
		"Host start must wait until every peer confirms a valid character."
	)
	net_manager.set_local_character_id(&"weishidaier", true)
	net_manager.host_start_game()
	_expect(int(net_manager.connection_state) == 4, "Host start must enter loading state.")
	_expect(not bool(net_manager.host_game_ready), "Host game ready must stay false until MpGame is ready.")
	net_manager.mark_in_game()
	_expect(int(net_manager.connection_state) == 5, "Host mark_in_game must enter in-game state.")
	_expect(bool(net_manager.host_game_ready), "Host mark_in_game must publish host ready state.")
	net_manager.disconnect_from_game()
	_expect(not net_manager.is_multiplayer_active(), "NetManager must cleanly disconnect after LAN host smoke.")


func _test_net_manager_protocol_version_gate() -> void:
	var net_manager := root.get_node_or_null("NetManager")
	_expect(net_manager != null, "NetManager autoload is missing for protocol version coverage.")
	if net_manager == null:
		return

	net_manager.disconnect_from_game()
	_expect(NetConstants.PROTOCOL_VERSION == 2, "The multiplayer protocol version must be 2.")
	_expect(
		bool(net_manager.call("_is_protocol_version_compatible", NetConstants.PROTOCOL_VERSION)),
		"NetManager must accept the current protocol version."
	)
	_expect(
		not bool(net_manager.call("_is_protocol_version_compatible", 1))
		and not bool(net_manager.call("_is_protocol_version_compatible", -1)),
		"NetManager must reject version 1 and legacy registrations with no version."
	)

	var rejection_reasons: Array[String] = []
	var rejection_callback := func(reason: String) -> void:
		rejection_reasons.append(reason)
	net_manager.connection_failed.connect(rejection_callback)
	net_manager.set("net_role", NetManagerStore.NetRole.CLIENT)
	net_manager.set("connection_state", NetManagerStore.ConnectionState.CONNECTED_IN_LOBBY)
	net_manager.call("_rpc_protocol_rejected", NetConstants.PROTOCOL_VERSION)
	net_manager.connection_failed.disconnect(rejection_callback)
	_expect(
		rejection_reasons.size() == 1
		and rejection_reasons[0].contains("版本 %d" % NetConstants.PROTOCOL_VERSION),
		"A rejected client must receive a same-build protocol mismatch reason."
	)
	_expect(
		not net_manager.is_multiplayer_active()
		and int(net_manager.connection_state) == NetManagerStore.ConnectionState.DISCONNECTED,
		"A protocol-rejected client must fully leave multiplayer state."
	)


func _test_public_room_context_lifecycle() -> void:
	var net_manager := root.get_node_or_null("NetManager")
	_expect(net_manager != null, "NetManager autoload is missing for public room context test.")
	if net_manager == null:
		return

	net_manager.disconnect_from_game()
	net_manager.set_public_room_context(" room-a ", " token-a ", true)
	_expect(
		str(net_manager.get("public_room_id")) == "room-a",
		"NetManager must trim and store public room id."
	)
	_expect(
		str(net_manager.get("public_host_token")) == "token-a",
		"NetManager must trim and store public host token."
	)
	_expect(bool(net_manager.get("public_is_host")), "NetManager must store public host role.")
	net_manager.disconnect_from_game()
	_expect(str(net_manager.get("public_room_id")).is_empty(), "Disconnect must clear public room id.")
	_expect(str(net_manager.get("public_host_token")).is_empty(), "Disconnect must clear public host token.")
	_expect(not bool(net_manager.get("public_is_host")), "Disconnect must clear public host role.")


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
	var connected_characters := net_manager.get("connected_player_characters") as Dictionary
	connected_characters.clear()
	connected_characters[1] = &"weishidaier"
	connected_characters[2] = &"weishidaier"
	connected_characters[3] = &"hoe_cat"
	var confirmed_characters := net_manager.get("confirmed_character_peers") as Dictionary
	confirmed_characters.clear()
	confirmed_characters[1] = true
	confirmed_characters[2] = true
	confirmed_characters[3] = true

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
			{"id": 1, "name": "Host", "character_id": "weishidaier", "character_confirmed": true},
			{"id": 2, "name": "Renamed", "character_id": "hoe_cat", "character_confirmed": true},
			{"id": 4, "name": "New", "character_id": "hoe_cat", "character_confirmed": false},
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
	_expect(
		net_manager.get_player_character_id(2) == &"hoe_cat"
		and net_manager.is_player_character_confirmed(2),
		"Player list sync must update a retained peer's confirmed character id."
	)
	_expect(
		net_manager.get_player_character_id(4) == &"hoe_cat"
		and not net_manager.is_player_character_confirmed(4),
		"Player list sync must preserve an unconfirmed character choice."
	)
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


func _test_delta_snapshot_peer_cache_cleanup() -> void:
	var mp_game := MP_GAME_SCENE.instantiate()
	_expect(mp_game != null, "MpGame scene must instantiate for delta snapshot cache test.")
	if mp_game == null:
		return
	var snapshot_mgr := mp_game.get("snapshot_mgr") as SnapshotManager
	_expect(snapshot_mgr != null, "MpGame must own a SnapshotManager for delta snapshot cache test.")
	if snapshot_mgr != null:
		var state := SnapshotManager.PlayerState.new()
		state.peer_id = 11
		state.position = Vector2(10.0, 20.0)
		state.velocity = Vector2.RIGHT
		state.current_health = 9
		state.max_health = 10
		snapshot_mgr.encode_player_snapshots_for_peer(11, [state], true)
		snapshot_mgr.encode_player_snapshots_for_peer(12, [state], true)
		_expect(
			snapshot_mgr.player_send_baselines_by_peer.has(11),
			"Delta snapshot cache test must create receiver peer baseline."
		)
		mp_game.call("_clear_peer_network_state", 11)
		_expect(
			not snapshot_mgr.player_send_baselines_by_peer.has(11),
			"Peer cleanup must clear the departed peer receiver baseline."
		)
		var peer_12_baseline := snapshot_mgr.player_send_baselines_by_peer.get(12) as Dictionary
		_expect(
			peer_12_baseline == null or not peer_12_baseline.has(11),
			"Peer cleanup must remove the departed peer from other player send baselines."
		)
	_expect(
		bool(mp_game.call("_should_force_player_delta_keyframe", 12, 0.0)),
		"Unknown player snapshot receiver must force a keyframe."
	)
	mp_game.set("_last_player_keyframe_time_by_peer", {12: 0.0})
	_expect(
		not bool(mp_game.call("_should_force_player_delta_keyframe", 12, 0.25)),
		"Player delta keyframe interval must not fire early."
	)
	_expect(
		bool(mp_game.call("_should_force_player_delta_keyframe", 12, 0.5)),
		"Player delta keyframe interval must force a full snapshot at 0.5 seconds."
	)
	_expect(
		bool(mp_game.call("_should_force_enemy_delta_keyframe", 12, 0.0)),
		"Unknown enemy snapshot receiver must force a keyframe."
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


func _test_xirang_drop_attraction_radius() -> void:
	_expect(
		XIRANG_DROP_CONFIG.attraction_radius >= 4096.0,
		"Xirang drops must use a full-map attraction radius."
	)
	var drop := XIRANG_DROP_SCENE.instantiate()
	var amount_label := drop.get_node("AmountLabel") as Label
	_expect(amount_label.size.y >= 20.0, "Xirang drop amount label must leave room for outlined text.")
	drop.free()


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
	var run_state := root.get_node_or_null("RunState") as RunStateStore
	if run_state != null:
		run_state.begin_new_run()
	var remote_player := game.peer_players.get(2) as PlayerWeishidaier
	if remote_player != null:
		remote_player.attack_damage = 37
		remote_player.apply_multiplayer_ammo_state(remote_player.get_ammo_capacity(), 2, false, 0.0)
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
	if remote_player != null:
		_expect(
			remote_player.get_multiplayer_current_ammo() == 1,
			"Host must consume authoritative ammo when accepting a client player bullet."
		)
		_expect(
			not remote_player.shooting_timer.is_stopped(),
			"Host must start the authoritative Weishidaier firing cooldown atomically."
		)
		remote_player.shooting_timer.stop()
		remote_player.apply_multiplayer_ammo_state(remote_player.get_ammo_capacity(), 0, false, 0.0)
		var empty_ammo_parameters := parameter_mp_game.call(
			"_get_authoritative_client_projectile_parameters",
			&"player_bullet",
			2
		) as Dictionary
		_expect(
			empty_ammo_parameters.is_empty(),
			"Host must reject client player bullets when authoritative ammo is empty."
		)
		_expect(
			remote_player.get_multiplayer_is_reloading(),
			"Host empty-ammo rejection must start authoritative reload."
		)
		remote_player.shooting_timer.stop()
		remote_player.apply_multiplayer_ammo_state(remote_player.get_ammo_capacity(), 1, true, 0.25)
		var reloading_parameters := parameter_mp_game.call(
			"_get_authoritative_client_projectile_parameters",
			&"player_bullet",
			2
		) as Dictionary
		_expect(
			reloading_parameters.is_empty(),
			"Host must reject client player bullets during authoritative reload."
		)
		remote_player.shooting_timer.stop()
		remote_player.current_shot_pattern = PickupConfig.ShotPattern.SPIRAL
		var spiral_parameters := parameter_mp_game.call(
			"_get_authoritative_client_projectile_parameters",
			&"player_bullet",
			2
		) as Dictionary
		_expect(
			not spiral_parameters.is_empty(),
			"Host must allow spiral player bullets without ammo even during reload."
		)
		_expect(
			remote_player.get_multiplayer_current_ammo() == 1
			and remote_player.get_multiplayer_is_reloading(),
			"Host spiral validation must not consume ammo or cancel reload."
		)
		remote_player.current_shot_pattern = PickupConfig.ShotPattern.NORMAL
		remote_player.current_form_mode = PickupConfig.PlayerFormMode.NORMAL
		remote_player.apply_multiplayer_ammo_state(remote_player.get_ammo_capacity(), remote_player.get_ammo_capacity(), false, 0.0)
	if run_state != null:
		_expect(run_state.try_add_item_for_peer(2, ARCHER_COLLECTIBLE), "Peer 2 archer collectible must fit before projectile validation.")
	if remote_player != null:
		remote_player.attack_damage = 37
	var accepted_arrow_parameters := parameter_mp_game.call(
		"_get_authoritative_client_projectile_parameters",
		&"collectible_arrow",
		2
	) as Dictionary
	_expect(
		not accepted_arrow_parameters.is_empty(),
		"Host must accept client archer collectible arrow projectiles."
	)
	var expected_arrow_damage := remote_player.attack_damage * 2 if remote_player != null else 0
	_expect(
		int(accepted_arrow_parameters.get("damage", 0)) == expected_arrow_damage,
		"Host must rebuild archer arrow damage from the authoritative player and collectible."
	)
	_expect(
		float(accepted_arrow_parameters.get("speed", 0.0)) > 0.0
		and float(accepted_arrow_parameters.get("lifetime", 0.0)) > 0.0,
		"Host must rebuild archer arrow motion parameters from the scene default."
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
	var near_spawn := (
		remote_player.global_position
		+ Vector2.RIGHT
		* remote_player.get_multiplayer_projectile_spawn_distance(&"player_bullet")
	)
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
			int(charged_skill1_parameters.get("damage", 0))
			== remote_player.get_skill1_projectile_damage(),
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
	mp_game.player_visual_interpolators[2] = NetInterpolator.new(0.1)
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
	_expect(not mp_game.player_visual_interpolators.has(2), "MpGame must clear disconnected peer visual interpolators.")
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
	mp_game.player_visual_interpolators[3] = NetInterpolator.new(0.1)
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
	_expect(not mp_game.player_visual_interpolators.has(3), "Roster reconcile must clear missing peer visual interpolators.")
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


func _test_enemy_snapshot_death_and_empty_roster_cleanup() -> void:
	var game := GAME_SCENE.instantiate() as Game
	_expect(game != null, "Game scene must instantiate for enemy snapshot cleanup test.")
	if game == null:
		return
	game.configure_multiplayer(2, 2, {1: "Host", 2: "Client"})
	game.set("auto_start_waves", false)
	root.add_child(game)
	await process_frame

	var enemy_dead := BASIC_CONFIG.enemy_scene.instantiate() as Enemy
	var enemy_stale := BASIC_CONFIG.enemy_scene.instantiate() as Enemy
	_expect(
		enemy_dead != null and enemy_stale != null,
		"Enemy snapshot cleanup test must instantiate enemies."
	)
	if enemy_dead == null or enemy_stale == null:
		if enemy_dead != null:
			enemy_dead.queue_free()
		if enemy_stale != null:
			enemy_stale.queue_free()
		_stop_audio_players(game)
		game.queue_free()
		await process_frame
		await physics_frame
		return
	game.enemy_container.add_child(enemy_dead)
	game.enemy_container.add_child(enemy_stale)
	enemy_dead.setup(BASIC_CONFIG, game.player, game.grid_pathfinder)
	enemy_stale.setup(BASIC_CONFIG, game.player, game.grid_pathfinder)

	var mp_game := MP_GAME_SCENE.instantiate()
	_expect(mp_game != null, "MpGame scene must instantiate for enemy snapshot cleanup test.")
	if mp_game == null:
		enemy_dead.queue_free()
		enemy_stale.queue_free()
		_stop_audio_players(game)
		game.queue_free()
		await process_frame
		await physics_frame
		return
	mp_game.set("game", game)
	var net_enemies := mp_game.get("_net_enemies") as Dictionary
	var enemy_spawn_times := mp_game.get("_enemy_spawn_snapshot_times") as Dictionary
	net_enemies[21] = enemy_dead
	net_enemies[22] = enemy_stale
	enemy_spawn_times[21] = 0.0
	enemy_spawn_times[22] = 0.0
	mp_game.enemy_interpolators[21] = NetInterpolator.new(0.1)
	mp_game.enemy_interpolators[22] = NetInterpolator.new(0.1)

	var snapshot_mgr := SnapshotManager.new()
	var dead_state := SnapshotManager.EnemyState.new()
	dead_state.net_id = 21
	dead_state.position = Vector2(12.0, 34.0)
	dead_state.velocity = Vector2.ZERO
	dead_state.health = 0
	dead_state.is_dead = true
	mp_game.call("_rpc_receive_enemy_snapshot", 1.0, snapshot_mgr.encode_all_enemy_snapshots([dead_state]))
	await process_frame
	_expect(not net_enemies.has(21), "Dead enemy snapshots must erase the client enemy index.")
	_expect(not enemy_spawn_times.has(21), "Dead enemy snapshots must erase spawn timing.")
	_expect(not mp_game.enemy_interpolators.has(21), "Dead enemy snapshots must clear interpolation state.")
	_expect(enemy_dead.is_dead, "Dead enemy snapshots must start the proxy death state.")

	mp_game.call("_rpc_receive_enemy_snapshot", 2.0, snapshot_mgr.encode_all_enemy_snapshots([]))
	await process_frame
	_expect(not net_enemies.has(22), "Empty complete enemy snapshots must reconcile stale enemies.")
	_expect(not enemy_spawn_times.has(22), "Empty complete enemy snapshots must erase stale spawn timing.")
	_expect(not mp_game.enemy_interpolators.has(22), "Empty complete enemy snapshots must clear stale interpolation.")

	mp_game.free()
	_stop_audio_players(game)
	game.queue_free()
	await process_frame
	await physics_frame


func _test_host_remote_player_position_writeback() -> void:
	var host_game := GAME_SCENE.instantiate() as Game
	_expect(host_game != null, "Game scene must instantiate for remote player writeback test.")
	if host_game == null:
		return
	host_game.configure_multiplayer(1, 1, {1: "Host", 2: "Client"})
	host_game.set("auto_start_waves", false)
	root.add_child(host_game)
	await process_frame
	var remote_player := host_game.get_player_for_peer(2) as Player
	_expect(remote_player != null, "Remote player writeback test must create peer 2.")
	if remote_player != null:
		_expect(
			remote_player.is_multiplayer_visual_smoothing_enabled(),
			"Host remote players must smooth visual nodes without delaying gameplay position."
		)
		var net_manager := root.get_node_or_null("NetManager")
		var previous_role := 0
		if net_manager != null:
			previous_role = int(net_manager.get("net_role"))
			net_manager.set("net_role", 1)
		var mp_game := MP_GAME_SCENE.instantiate()
		mp_game.set("game", host_game)
		if net_manager != null:
			mp_game.set("net_manager", net_manager)
		var previous_visual_position := remote_player.get_multiplayer_visual_global_position()
		var accepted_position := remote_player.global_position + Vector2(24.0, 8.0)
		var accepted_velocity := Vector2(120.0, 0.0)
		mp_game.call(
			"_apply_accepted_client_player_state",
			2,
			remote_player,
			accepted_position,
			accepted_velocity,
			Vector2.RIGHT,
			false
		)
		_expect(
			remote_player.global_position.is_equal_approx(accepted_position),
			"Host must write accepted client position back to the remote player node."
		)
		_expect(
			remote_player.velocity.is_equal_approx(accepted_velocity),
			"Host must write accepted client velocity back to the remote player node."
		)
		_expect(
			remote_player.get_multiplayer_visual_global_position().is_equal_approx(previous_visual_position),
			"Host remote player visuals must hold the previous rendered position when gameplay position advances."
		)
		var previous_visual_distance := previous_visual_position.distance_to(accepted_position)
		remote_player.call("_update_multiplayer_visual_smoothing", 1.0 / 60.0)
		_expect(
			remote_player.get_multiplayer_visual_global_position().distance_to(accepted_position) < previous_visual_distance,
			"Host remote player visual smoothing must move rendered position toward gameplay position."
		)
		_expect(
			remote_player.global_position.is_equal_approx(accepted_position),
			"Host remote player visual smoothing must not move gameplay position."
		)
		_expect(
			not mp_game.player_visual_interpolators.has(2),
			"Host must not create player visual interpolation state for accepted remote player positions."
		)
		if net_manager != null:
			net_manager.set("net_role", previous_role)
		mp_game.free()
	_stop_audio_players(host_game)
	host_game.queue_free()
	await process_frame
	await physics_frame


func _test_projectile_time_compensation() -> void:
	var mp_game := MP_GAME_SCENE.instantiate()
	_expect(mp_game != null, "MpGame scene must instantiate for projectile compensation test.")
	if mp_game == null:
		return
	var now_origin := Time.get_ticks_msec() / 1000.0 - 10.0
	mp_game.set("_net_time_origin", now_origin)
	mp_game.set("_has_host_time_offset", true)
	mp_game.set("_host_to_client_time_offset", 0.0)
	var now := float(mp_game.call("_get_net_time"))
	var spawn_position := Vector2(10.0, 20.0)
	var direction := Vector2.RIGHT
	var speed := 100.0
	var lifetime := 2.0
	mp_game.call(
		"_spawn_network_projectile",
		2000001,
		&"player_bullet",
		2,
		spawn_position,
		direction,
		7,
		speed,
		lifetime,
		false,
		0,
		now - 0.12
	)
	var known_projectiles := mp_game.get("_known_projectiles") as Dictionary
	var projectile := known_projectiles.get(2000001) as Bullet
	_expect(projectile != null, "Projectile compensation test must spawn a bullet.")
	if projectile != null:
		var actual_compensation_age := (
			(projectile.global_position.x - spawn_position.x)
			/ speed
		)
		_expect(
			absf(actual_compensation_age - 0.12) <= 0.03,
			"Client projectile visuals must advance by network age."
		)
		_expect(
			absf(projectile.remaining_lifetime - (lifetime - actual_compensation_age)) <= 0.01,
			"Client projectile visuals must reduce remaining lifetime by network age."
		)
		projectile.free()
	mp_game.free()


func _test_enemy_action_uses_snapshot_timeline() -> void:
	var client_game := GAME_SCENE.instantiate() as Game
	_expect(client_game != null, "Game scene must instantiate for enemy action timeline test.")
	if client_game == null:
		return
	client_game.configure_multiplayer(2, 2, {1: "Host", 2: "Client"})
	client_game.set("auto_start_waves", false)
	root.add_child(client_game)
	await process_frame
	var enemy := KNIGHT_CONFIG.enemy_scene.instantiate() as Enemy
	_expect(enemy != null, "Enemy action timeline test must instantiate an enemy.")
	if enemy != null:
		client_game.enemy_container.add_child(enemy)
		enemy.setup(KNIGHT_CONFIG, client_game.player, client_game.grid_pathfinder)
		enemy.configure_multiplayer_proxy()
		enemy.set_meta("net_id", 42)
		enemy.global_position = Vector2(5.0, 5.0)
		var sprite := enemy.get_node_or_null("AnimatedSprite2D") as AnimatedSprite2D
		_expect(sprite != null, "Enemy action timeline test must find the proxy sprite.")
		var mp_game := MP_GAME_SCENE.instantiate()
		mp_game.set("game", client_game)
		var net_manager := root.get_node_or_null("NetManager")
		if net_manager != null:
			mp_game.set("net_manager", net_manager)
		mp_game.set("_net_time_origin", Time.get_ticks_msec() / 1000.0 - 10.0)
		mp_game.set("_has_host_time_offset", true)
		mp_game.set("_host_to_client_time_offset", 0.0)
		var net_enemies := mp_game.get("_net_enemies") as Dictionary
		net_enemies[42] = enemy
		var interp := NetInterpolator.new(0.05, 0.0)
		interp.push_snapshot(9.5, Vector2(5.0, 5.0), Vector2.ZERO)
		mp_game.enemy_interpolators[42] = interp
		mp_game.call("net_enemy_action", 42, "windup", Vector2.RIGHT, Vector2(100.0, 100.0), 1, 9.0)
		_expect(
			enemy.global_position.is_equal_approx(Vector2(5.0, 5.0)),
			"Stale enemy action events must not pull proxy position off the snapshot timeline."
		)
		if sprite != null:
			_expect(
				sprite.animation == KNIGHT_CONFIG.move_animation_name,
				"Stale enemy action events must not replay outdated proxy action animation."
			)
		mp_game.call("net_enemy_action", 42, "windup", Vector2.RIGHT, Vector2(20.0, 5.0), 2, 10.0)
		var latest_timestamp := (mp_game.enemy_interpolators[42] as NetInterpolator).get_latest_timestamp()
		_expect(
			is_equal_approx(latest_timestamp, 10.0),
			"Fresh enemy action events must enter the enemy interpolation timeline."
		)
		if sprite != null:
			_expect(
				sprite.animation == KNIGHT_CONFIG.windup_animation_name,
				"Fresh enemy action events must still play the proxy action animation."
			)

		var sniper := SNIPER_CONFIG.enemy_scene.instantiate() as CapooSniper
		_expect(sniper != null, "Enemy target action timeline test must instantiate a sniper.")
		if sniper != null:
			client_game.enemy_container.add_child(sniper)
			sniper.setup(SNIPER_CONFIG, client_game.player, client_game.grid_pathfinder)
			sniper.configure_multiplayer_proxy()
			sniper.set_meta("net_id", 43)
			sniper.global_position = Vector2(12.0, 8.0)
			var sniper_interp := NetInterpolator.new(0.05, 0.0)
			sniper_interp.push_snapshot(9.5, sniper.global_position, Vector2.ZERO)
			mp_game.enemy_interpolators[43] = sniper_interp
			var aim_glow := sniper.get_node_or_null("AimGlow") as Polygon2D
			var net_enemies_for_target_action := mp_game.get("_net_enemies") as Dictionary
			net_enemies_for_target_action[43] = sniper
			mp_game.call(
				"net_enemy_target_action",
				43,
				"sniper_lock_start",
				2,
				Vector2(100.0, 100.0),
				1,
				9.0
			)
			_expect(
				sniper.global_position.is_equal_approx(Vector2(12.0, 8.0)),
				"Stale enemy target action events must not pull proxy position off the snapshot timeline."
			)
			_expect(
				sniper.lock_reticle == null and (aim_glow == null or not aim_glow.visible),
				"Stale enemy target action events must not start outdated target lock visuals."
			)
			mp_game.call(
				"net_enemy_target_action",
				43,
				"sniper_lock_start",
				2,
				Vector2(20.0, 8.0),
				2,
				10.0
			)
			_expect(
				sniper.lock_reticle != null and aim_glow != null and aim_glow.visible,
				"Fresh enemy target action events must still start target lock visuals."
			)

		var boss_enemy_config := LINGLAN_BOSS_CONFIG.call("get_enemy_config") as EnemyConfig
		var linglan := boss_enemy_config.enemy_scene.instantiate() as LinglanBoss
		_expect(linglan != null, "Enemy action timeline test must instantiate Linglan.")
		if linglan != null:
			client_game.enemy_container.add_child(linglan)
			linglan.setup(boss_enemy_config, client_game.player, client_game.grid_pathfinder)
			linglan.configure_multiplayer_proxy()
			linglan.set_meta("net_id", 44)
			linglan.global_position = Vector2(18.0, 18.0)
			var linglan_interp := NetInterpolator.new(0.05, 0.0)
			linglan_interp.push_snapshot(9.5, linglan.global_position, Vector2.ZERO)
			mp_game.enemy_interpolators[44] = linglan_interp
			var net_enemies_for_linglan_action := mp_game.get("_net_enemies") as Dictionary
			net_enemies_for_linglan_action[44] = linglan
			current_scene = client_game
			mp_game.call(
				"net_enemy_action",
				44,
				"linglan_skill1_warning",
				Vector2.ZERO,
				Vector2(180.0, 180.0),
				1,
				9.46
			)
			_expect(
				linglan.global_position.is_equal_approx(Vector2(18.0, 18.0)),
				"Slightly reordered enemy action events must not pull proxy position off the snapshot timeline."
			)
			var expected_warning_ray_count := (
				linglan.skill1_config.ring_direction_count
				if linglan.skill1_config != null
				else 0
			)
			_expect(
				_count_linglan_skill1_warning_rays(client_game) == expected_warning_ray_count,
				"Slightly reordered Linglan Skill1 warning action must still spawn warning rays."
			)
		mp_game.free()
	_stop_audio_players(client_game)
	client_game.queue_free()
	await process_frame
	await physics_frame


func _test_host_remote_player_form_buff_expires() -> void:
	var game := GAME_SCENE.instantiate() as Game
	_expect(game != null, "Game scene must instantiate for remote form buff test.")
	if game == null:
		return
	game.configure_multiplayer(1, 1, {1: "Host", 2: "Client"})
	game.set("auto_start_waves", false)
	root.add_child(game)
	await process_frame

	var remote_player := game.get_player_for_peer(2) as PlayerWeishidaier
	_expect(remote_player != null, "Remote form buff test must create peer 2 player.")
	if remote_player == null:
		_stop_audio_players(game)
		game.queue_free()
		await process_frame
		await physics_frame
		return

	_expect(remote_player.apply_pickup(PICKUP_SPIRAL_CONFIG), "Remote player must apply spiral pickup.")
	remote_player.update_multiplayer_authority_passive_state(0.0)
	_expect(
		remote_player.get_multiplayer_form_mode() == PickupConfig.PlayerFormMode.ARMED,
		"Remote player must enter armed form after spiral pickup."
	)
	_expect(remote_player.armed_effect_sprite.visible, "Remote armed effect must become visible.")
	var remaining_before_input := remote_player.form_buff_time_left
	_expect(remaining_before_input > 0.0, "Remote form buff timer must start.")

	var mp_game := MP_GAME_SCENE.instantiate()
	_expect(mp_game != null, "MpGame scene must instantiate for remote form buff test.")
	if mp_game != null:
		var net_manager := root.get_node_or_null("NetManager")
		if net_manager != null:
			mp_game.set("net_manager", net_manager)
		mp_game.set("game", game)
		mp_game.call(
			"_apply_accepted_client_player_state",
			2,
			remote_player,
			remote_player.global_position,
			Vector2.RIGHT,
			Vector2.ZERO,
			false
		)
		_expect(
			remote_player.form_buff_time_left > 0.0,
			"Accepted client state must not clear the Host-side form buff timer."
		)
		mp_game.free()

	remote_player.update_multiplayer_authority_passive_state(PICKUP_SPIRAL_CONFIG.duration + 0.1)
	_expect(
		remote_player.get_multiplayer_form_mode() == PickupConfig.PlayerFormMode.NORMAL,
		"Remote form buff must expire on Host authority."
	)
	_expect(
		remote_player.get_multiplayer_shot_pattern() == PickupConfig.ShotPattern.NORMAL,
		"Remote shot pattern must reset when the form buff expires."
	)
	_expect(not remote_player.armed_effect_sprite.visible, "Remote armed effect must hide after buff expiry.")

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
		var luoxi_merchant := game.get("luoxi_merchant") as LuoxiMerchant
		_expect(luoxi_merchant != null, "Multiplayer game must expose its Luoxi merchant for intermission refreshes.")
		if luoxi_merchant != null:
			luoxi_merchant.set_active(true)
		peer_four.current_xirang = 1800
		var expected_refresh_xirang := 1800
		for refresh_index in range(LuoxiMerchant.get_refresh_limit()):
			var refresh_cost := LuoxiMerchant.get_refresh_cost(refresh_index)
			_expect(
				game.try_refresh_luoxi_collectibles_for_peer(4) == LuoxiMerchant.REFRESH_RESULT_SUCCESS,
				"Luoxi host-authoritative refresh %d must succeed." % refresh_index
			)
			expected_refresh_xirang -= refresh_cost
			_expect(peer_four.current_xirang == expected_refresh_xirang, "Luoxi refresh must deduct its authoritative xirang cost.")
		_expect(game.get_luoxi_collectible_refresh_count(4) == 4, "Luoxi must track four refreshes per peer and intermission.")
		_expect(
			game.try_refresh_luoxi_collectibles_for_peer(4) == LuoxiMerchant.REFRESH_RESULT_LIMIT_REACHED,
			"Luoxi must reject a fifth refresh without spending xirang."
		)
		var luoxi_claim_result := game.try_claim_luoxi_collectible_for_peer(4, APPLE_COLLECTIBLE.resource_path)
		_expect(
			luoxi_claim_result == LuoxiMerchant.COLLECTIBLE_RESULT_SUCCESS,
			"Luoxi collectible claim must succeed for a valid peer."
		)
		_expect(
			run_state.get_item_for_peer(4, 0) == APPLE_COLLECTIBLE,
			"Luoxi collectible claim must add the apple to the selected peer inventory."
		)
		_expect(
			is_equal_approx(peer_four.call("_get_inventory_bullet_pierce_chance"), 0.2),
			"Peer 4 apple collectible must grant a 20% piercing chance."
		)
		_expect(game.has_luoxi_collectible_claimed(4), "One Luoxi claim must exhaust the selected peer's intermission choice.")
		_expect(
			game.try_claim_luoxi_collectible_for_peer(4, APPLE_COLLECTIBLE.resource_path) == LuoxiMerchant.COLLECTIBLE_RESULT_ALREADY_CLAIMED,
			"Luoxi must reject a second collectible choice in the same intermission."
		)
		for _slot_index in range(RunStateStore.INVENTORY_CAPACITY):
			_expect(run_state.try_add_item_for_peer(2, HEALTH_PICKUP), "Peer 2 inventory must fill before testing Luoxi's full bag result.")
		var full_luoxi_claim_result := game.try_claim_luoxi_collectible_for_peer(2, APPLE_COLLECTIBLE.resource_path)
		_expect(
			full_luoxi_claim_result == LuoxiMerchant.COLLECTIBLE_RESULT_INVENTORY_FULL,
			"Luoxi must reject collectible claims when the selected peer inventory is full."
		)
		_expect(
			not game.has_luoxi_collectible_claimed(2),
			"A full peer inventory must not spend Luoxi's collectible choices."
		)
		_expect(run_state.discard_item_for_peer(2, 0), "Peer 2 must be able to free one inventory slot after a full Luoxi claim.")
		_expect(
			game.try_claim_luoxi_collectible_for_peer(2, APPLE_COLLECTIBLE.resource_path) == LuoxiMerchant.COLLECTIBLE_RESULT_SUCCESS,
			"Luoxi must allow the original peer choice after the peer frees an inventory slot."
		)
		_expect(game.has_luoxi_collectible_claimed(2), "A successful retry must spend the peer's only Luoxi choice.")
		_expect(run_state.get_item_for_peer(2, 0) == APPLE_COLLECTIBLE, "The successful Luoxi retry must fill the freed peer inventory slot.")
		_expect(run_state.try_add_item_for_peer(4, HEALTH_PICKUP), "Peer 4 health pickup must fit in inventory for use testing.")
		peer_four.current_health = maxi(peer_four.max_health - HEALTH_PICKUP.heal_amount, 1)
		mp_game.call("_apply_inventory_item_use_for_peer", 4, 1)
		_expect(run_state.get_item_for_peer(4, 1) == null, "Host inventory use must remove the consumed peer item.")
		_expect(peer_four.current_health == peer_four.max_health, "Host inventory use must apply the pickup effect to the selected peer.")
		mp_game.call("_apply_inventory_item_discard_for_peer", 4, 0)
		_expect(run_state.get_item_for_peer(4, 0) == null, "Host inventory discard must remove the selected peer item.")
		_expect(
			is_equal_approx(peer_four.call("_get_inventory_bullet_pierce_chance"), 0.0),
			"Discarding peer 4's only apple must remove the piercing chance."
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
		_expect(run_state.try_add_item_for_peer(3, HEALTH_PICKUP), "Peer 3 health pickup must fit for inventory use confirmation testing.")
		peer_three.current_health = maxi(peer_three.max_health - HEALTH_PICKUP.heal_amount, 1)
		mp_game.call("net_inventory_item_used", 3, 0, HEALTH_PICKUP.resource_path, true)
		_expect(run_state.get_item_for_peer(3, 0) == null, "Inventory use confirm must remove the confirmed peer item.")
		_expect(peer_three.current_health == peer_three.max_health, "Inventory use confirm must apply the pickup effect to the confirmed peer.")
		_expect(run_state.try_add_item_for_peer(3, APPLE_COLLECTIBLE), "Peer 3 apple must fit for inventory discard confirmation testing.")
		mp_game.call("net_inventory_item_discarded", 3, 0, true)
		_expect(run_state.get_item_for_peer(3, 0) == null, "Inventory discard confirm must remove the confirmed peer item.")
		var peer_inventories := run_state.get("multiplayer_inventories") as Dictionary
		mp_game.call("net_inventory_item_used", 99, 0, HEALTH_PICKUP.resource_path, true)
		mp_game.call("net_inventory_item_discarded", 99, 0, true)
		_expect(not peer_inventories.has(99), "Inventory confirms for missing peers must not create peer run state.")
		mp_game.call(
			"net_luoxi_collectible_confirmed",
			3,
			0,
			APPLE_COLLECTIBLE.resource_path,
			LuoxiMerchant.COLLECTIBLE_RESULT_SUCCESS
		)
		_expect(
			run_state.get_item_for_peer(3, 0) == APPLE_COLLECTIBLE,
			"Luoxi collectible confirm must add apple to the confirmed peer inventory."
		)
		_expect(
			game.has_luoxi_collectible_claimed(3),
			"One Luoxi collectible confirm must exhaust the confirmed peer choice."
		)

	mp_game.free()
	_stop_audio_players(game)
	game.queue_free()
	await process_frame
	await physics_frame


func _test_multiplayer_character_scene_registry() -> void:
	var game := GAME_SCENE.instantiate() as Game
	_expect(game != null, "Game must instantiate for multiplayer character registry test.")
	if game == null:
		return
	game.configure_multiplayer(
		2,
		2,
		{1: "Host", 2: "Client", 3: "Tiyi"},
		{1: &"weishidaier", 2: &"hoe_cat", 3: &"tiyi"}
	)
	_stop_audio_players(game)
	root.add_child(game)
	await process_frame
	var host_player := game.get_player_for_peer(1)
	var local_player := game.get_player_for_peer(2)
	var tiyi_player := game.get_player_for_peer(3) as PlayerTiyi
	_expect(
		host_player != null and host_player.get_character_id() == &"weishidaier",
		"Game must instantiate the registered Weishidaier scene for the host peer."
	)
	_expect(
		local_player != null and local_player.get_character_id() == &"hoe_cat",
		"Game must instantiate the registered Hoe Cat scene for the client peer."
	)
	_expect(
		tiyi_player != null and tiyi_player.get_character_id() == &"tiyi",
		"Game must instantiate the registered Tiyi scene for a standard multiplayer peer."
	)
	if tiyi_player != null:
		var mp_game := MP_GAME_SCENE.instantiate()
		mp_game.set("game", game)
		_expect(
			int(mp_game.call(
				"_get_player_projectile_damage_type",
				&"tiyi_sniper_bullet"
			)) == EnemyConfig.DamageType.MAGIC,
			"Host must derive Tiyi sniper bullets as magic damage."
		)
		_expect(
			int(mp_game.call(
				"_get_player_projectile_damage_type",
				&"player_bullet"
			)) == EnemyConfig.DamageType.PHYSICAL,
			"Host must preserve ordinary player bullets as physical damage."
		)
		var authoritative_direction := Vector2(3.0, 4.0).normalized()
		var authoritative_spawn := mp_game.call(
			"_get_authoritative_client_projectile_spawn_position",
			&"tiyi_sniper_bullet",
			3,
			Vector2(99999.0, -99999.0),
			authoritative_direction
		) as Vector2
		_expect(
			authoritative_spawn.is_equal_approx(
				tiyi_player.global_position + authoritative_direction * 16.0
			),
			"Host must ignore a client-reported Tiyi spawn point and rebuild it from the muzzle."
		)
		var ammo_before := tiyi_player.current_ammo
		var sniper_parameters := mp_game.call(
			"_get_authoritative_client_projectile_parameters",
			&"tiyi_sniper_bullet",
			3
		) as Dictionary
		_expect(
			int(sniper_parameters.get("damage", 0)) == 100
			and is_equal_approx(float(sniper_parameters.get("speed", 0.0)), 1920.0)
			and is_equal_approx(float(sniper_parameters.get("lifetime", 0.0)), 0.35),
			"Host must replace client-reported Tiyi sniper stats with authoritative values."
		)
		_expect(
			tiyi_player.current_ammo == ammo_before - 1
			and not tiyi_player.shooting_timer.is_stopped(),
			"Host must atomically consume one Tiyi round and start the authoritative cooldown."
		)
		_expect(
			(mp_game.call(
				"_get_authoritative_client_projectile_parameters",
				&"tiyi_sniper_bullet",
				3
			) as Dictionary).is_empty()
			and tiyi_player.current_ammo == ammo_before - 1,
			"Host must reject a repeated Tiyi shot during cooldown without consuming ammo."
		)
		_expect(
			(mp_game.call(
				"_get_authoritative_client_projectile_parameters",
				&"player_bullet",
				3
			) as Dictionary).is_empty(),
			"Tiyi must not be able to forge another character's projectile type."
		)
		tiyi_player.shooting_timer.stop()
		tiyi_player.set_controls_locked(true)
		_expect(
			(mp_game.call(
				"_get_authoritative_client_projectile_parameters",
				&"tiyi_sniper_bullet",
				3
			) as Dictionary).is_empty()
			and tiyi_player.current_ammo == ammo_before - 1,
			"Host must reject Tiyi shots while controls are locked without consuming ammo."
		)
		tiyi_player.set_controls_locked(false)
		mp_game.free()
	_expect(
		game.player == local_player,
		"Game.player must reference the local peer even when the host sorts first."
	)
	_stop_audio_players(game)
	game.queue_free()
	await process_frame


func _test_host_authoritative_hoe_actions() -> void:
	var host_game := GAME_SCENE.instantiate() as Game
	_expect(host_game != null, "Game must instantiate for authoritative Hoe Cat action coverage.")
	if host_game == null:
		return
	host_game.configure_multiplayer(
		1,
		1,
		{1: "Host"},
		{1: &"hoe_cat"}
	)
	host_game.set("auto_start_waves", false)
	_stop_audio_players(host_game)
	root.add_child(host_game)
	await process_frame
	var hoe_player := host_game.get_player_for_peer(1) as PlayerHoeCat
	_expect(hoe_player != null, "Host roster must instantiate Hoe Cat for authoritative action coverage.")
	if hoe_player == null:
		host_game.queue_free()
		await process_frame
		return

	var mp_game := MP_GAME_SCENE.instantiate()
	var net_manager := root.get_node_or_null("NetManager")
	_expect(net_manager != null, "NetManager must exist for authoritative Hoe Cat action coverage.")
	if net_manager == null:
		mp_game.free()
		host_game.queue_free()
		await process_frame
		return
	var previous_role := int(net_manager.get("net_role"))
	var connected_players := net_manager.get("connected_players") as Dictionary
	var previous_players := connected_players.duplicate()
	net_manager.set("net_role", 1)
	connected_players.clear()
	connected_players[1] = "Host"
	mp_game.set("game", host_game)
	mp_game.set("net_manager", net_manager)
	var free_aim_direction := Vector2(2.0, 1.0).normalized()
	_expect(
		(mp_game.call(
			"_get_authoritative_client_projectile_parameters",
			&"player_bullet",
			1
		) as Dictionary).is_empty(),
		"Hoe Cat must not be able to forge Weishidaier player bullets."
	)
	_expect(
		(mp_game.call(
			"_get_authoritative_client_projectile_parameters",
			&"skill1_bomb",
			1
		) as Dictionary).is_empty(),
		"Hoe Cat must not be able to forge Weishidaier skill bombs."
	)

	var contact_enemy := BASIC_CONFIG.enemy_scene.instantiate() as Enemy
	_expect(contact_enemy != null, "Host Hoe Cat coverage must instantiate a real enemy target.")
	var contact_enemy_health_before := 0
	if contact_enemy != null:
		host_game.enemy_container.add_child(contact_enemy)
		contact_enemy.setup(BASIC_CONFIG, hoe_player, host_game.grid_pathfinder)
		contact_enemy.set_physics_process(false)
		# The horizontal capsule has less support along a diagonal than on the X
		# axis. A centre distance of 54 remains near the radius-48 outer edge while
		# still overlapping for this non-cardinal attack direction.
		contact_enemy.global_position = (
			hoe_player.global_position + free_aim_direction * 54.0
		)
		contact_enemy_health_before = contact_enemy.current_health
		await process_frame
		await physics_frame
	var outside_cone_enemy := BASIC_CONFIG.enemy_scene.instantiate() as Enemy
	_expect(
		outside_cone_enemy != null,
		"Host Hoe Cat coverage must instantiate a real enemy outside the 60-degree cone."
	)
	var outside_cone_enemy_health_before := 0
	if outside_cone_enemy != null:
		host_game.enemy_container.add_child(outside_cone_enemy)
		outside_cone_enemy.setup(BASIC_CONFIG, hoe_player, host_game.grid_pathfinder)
		outside_cone_enemy.set_physics_process(false)
		# Fifty pixels still overlaps the radius-48 query once the real insect
		# collision shape is considered, so exclusion must come from its 31-degree
		# direction rather than from range.
		outside_cone_enemy.global_position = (
			hoe_player.global_position
			+ free_aim_direction.rotated(deg_to_rad(31.0)) * 50.0
		)
		outside_cone_enemy_health_before = outside_cone_enemy.current_health
		await process_frame
		await physics_frame

	hoe_player.shooting_timer.stop()
	_expect(
		bool(mp_game.call("_apply_authoritative_hoe_action", 1, &"primary", Vector2(2.0, 1.0))),
		"Host must accept a valid Hoe Cat primary attack request."
	)
	_expect(
		hoe_player.last_attack_direction.is_equal_approx(free_aim_direction)
		and (hoe_player.get("_pending_primary_direction") as Vector2).is_equal_approx(free_aim_direction),
		"Host authority must preserve the normalized non-cardinal attack direction."
	)
	_expect(
		is_equal_approx(hoe_player.basic_slash_effect.rotation, free_aim_direction.angle()),
		"Host-authoritative slash VFX must rotate to the exact free-aim direction."
	)
	if contact_enemy != null:
		_expect(
			contact_enemy.current_health == contact_enemy_health_before,
			"Host-authoritative Hoe Cat damage must wait for the authored impact frame."
		)
	await hoe_player.primary_impact_timer.timeout
	if contact_enemy != null:
		_expect(
			contact_enemy.current_health == contact_enemy_health_before - 15,
			"Host-authoritative Hoe Cat impact frame must damage a real insect at the expanded radius-48 boundary."
		)
	if outside_cone_enemy != null:
		_expect(
			outside_cone_enemy.current_health == outside_cone_enemy_health_before,
			"Host-authoritative Hoe Cat impact must exclude a real insect beyond the 60-degree cone."
		)
	var action_sequences := mp_game.get("_hoe_action_sequences_by_peer") as Dictionary
	_expect(int(action_sequences.get(1, 0)) == 1, "Host must assign an increasing sequence to an accepted Hoe Cat attack.")
	_expect(
		not bool(mp_game.call("_apply_authoritative_hoe_action", 1, &"primary", free_aim_direction)),
		"Host must reject a Hoe Cat primary request inside the minimum attack interval."
	)
	_expect(int(action_sequences.get(1, 0)) == 1, "Rejected Hoe Cat attacks must not advance the action sequence.")

	while float(hoe_player.get("_primary_visual_time_left")) > 0.0:
		await process_frame
	hoe_player.unlock_skill1()
	hoe_player.skill1_charge = hoe_player.skill1_charge_duration
	hoe_player.current_health = 70
	_expect(
		bool(mp_game.call("_apply_authoritative_hoe_action", 1, &"whirlwind", Vector2.ZERO)),
		"Host must accept a fully charged Hoe Cat whirlwind request."
	)
	_expect(int(action_sequences.get(1, 0)) == 2, "Accepted whirlwind must advance the authoritative action sequence.")
	_expect(hoe_player.current_health == 70, "Whirlwind healing must wait for its impact frame.")
	_expect(
		not bool(mp_game.call("_apply_authoritative_hoe_action", 1, &"primary", free_aim_direction)),
		"Host must reject primary attacks during the whirlwind action lock."
	)
	await hoe_player.whirlwind_impact_timer.timeout
	_expect(hoe_player.current_health == 75, "Host-authoritative whirlwind impact must heal exactly 5 health.")

	connected_players.clear()
	connected_players.merge(previous_players, true)
	net_manager.set("net_role", previous_role)
	mp_game.free()
	_stop_audio_players(host_game)
	host_game.queue_free()
	await process_frame
	await physics_frame


func _test_host_authoritative_tiyi_protocol() -> void:
	var host_game := GAME_SCENE.instantiate() as Game
	_expect(host_game != null, "Game must instantiate for authoritative Tiyi protocol coverage.")
	if host_game == null:
		return
	host_game.configure_multiplayer(
		1,
		1,
		{1: "Host"},
		{1: &"tiyi"}
	)
	host_game.set("auto_start_waves", false)
	_stop_audio_players(host_game)
	root.add_child(host_game)
	await process_frame
	var tiyi_player := host_game.get_player_for_peer(1) as PlayerTiyi
	_expect(tiyi_player != null, "Host roster must instantiate Tiyi for protocol coverage.")
	if tiyi_player == null:
		host_game.queue_free()
		await process_frame
		return

	var mp_game := MP_GAME_SCENE.instantiate()
	var net_manager := root.get_node_or_null("NetManager")
	_expect(net_manager != null, "NetManager must exist for authoritative Tiyi protocol coverage.")
	if net_manager == null:
		mp_game.free()
		host_game.queue_free()
		await process_frame
		return
	var previous_role := int(net_manager.get("net_role"))
	var connected_players := net_manager.get("connected_players") as Dictionary
	var previous_players := connected_players.duplicate()
	net_manager.set("net_role", 1)
	connected_players.clear()
	connected_players[1] = "Host"
	mp_game.set("game", host_game)
	mp_game.set("net_manager", net_manager)

	_expect(
		is_equal_approx(tiyi_player.skill1_charge_duration, 28.0),
		"Tiyi must enter multiplayer with a default skill charge requirement of 28."
	)
	tiyi_player.unlock_skill1()
	tiyi_player.skill1_charge = tiyi_player.skill1_charge_duration
	_expect(
		bool(mp_game.call("_apply_authoritative_tiyi_high_noon_request", 1, 1)),
		"Host must accept a charged Tiyi high-noon request with activation id 1."
	)
	var active_activations := mp_game.get("_active_tiyi_activations_by_peer") as Dictionary
	var activation_sequences := mp_game.get("_tiyi_activation_sequences_by_peer") as Dictionary
	_expect(
		int(active_activations.get(1, 0)) == 1
		and int(activation_sequences.get(1, 0)) == 1
		and tiyi_player.is_high_noon_active(),
		"Accepted high noon must register the authoritative monotonic activation."
	)
	var active_id_before_repeat := int(active_activations.get(1, 0))
	var sequence_before_repeat := int(activation_sequences.get(1, 0))
	var player_activation_before_repeat := tiyi_player.get_high_noon_activation_id()
	tiyi_player.skill1_charge = tiyi_player.skill1_charge_duration
	_expect(
		not bool(mp_game.call("_apply_authoritative_tiyi_high_noon_request", 1, 2)),
		"Host must reject a fully recharged second high-noon request while one is active."
	)
	_expect(
		int(active_activations.get(1, 0)) == active_id_before_repeat
		and int(activation_sequences.get(1, 0)) == sequence_before_repeat
		and tiyi_player.get_high_noon_activation_id() == player_activation_before_repeat
		and tiyi_player.is_high_noon_active(),
		"Rejected active high noon must not replace the current activation or advance its sequence."
	)
	mp_game.call("cancel_tiyi_high_noon", 1, 1)
	tiyi_player.cancel_remote_high_noon(1)
	_expect(
		not active_activations.has(1),
		"Cancelling high noon must clear its authoritative active state."
	)

	tiyi_player.set("_last_skill_activation_msec", Time.get_ticks_msec() - 1000)
	tiyi_player.skill1_charge = tiyi_player.skill1_charge_duration
	_expect(
		not bool(mp_game.call("_apply_authoritative_tiyi_high_noon_request", 1, 1)),
		"Host must ignore a replayed high-noon activation id."
	)
	_expect(
		bool(mp_game.call("_apply_authoritative_tiyi_high_noon_request", 1, 2)),
		"Host must accept the next monotonic high-noon activation id."
	)
	var high_noon_target_config := BASIC_CONFIG.duplicate(true) as EnemyConfig
	high_noon_target_config.max_health = 1000
	high_noon_target_config.physical_defense = 999
	high_noon_target_config.magic_defense = 25
	_expect(
		host_game.call("_try_spawn_enemy", high_noon_target_config),
		"Host must spawn a target for high-noon resolution coverage."
	)
	var target_enemy := host_game.get_enemy_for_net_id(1)
	_expect(target_enemy != null, "High-noon target must have a Host net id.")
	if target_enemy != null:
		target_enemy.set_physics_process(false)
		var target_health_before := target_enemy.current_health
		var expected_magic_damage := floori(
			float(floori(float(tiyi_player.attack_damage) * 3.5)) * 0.75
		)
		mp_game.call(
			"notify_tiyi_high_noon_targets_changed",
			1,
			2,
			PackedInt32Array([1])
		)
		mp_game.call(
			"resolve_tiyi_high_noon",
			1,
			2,
			PackedInt32Array([1]),
			PackedVector2Array([target_enemy.global_position])
		)
		_expect(
			target_enemy.last_damage_taken == expected_magic_damage
			and target_enemy.current_health == target_health_before - expected_magic_damage,
			"Host high-noon completion must apply authoritative 350% magic damage using only magic defense."
		)
	_expect(
		not active_activations.has(1) and int(activation_sequences.get(1, 0)) == 2,
		"High-noon completion must clear active state without rewinding its sequence."
	)
	tiyi_player.cancel_remote_high_noon(2)

	connected_players.clear()
	connected_players.merge(previous_players, true)
	net_manager.set("net_role", previous_role)
	mp_game.free()
	_stop_audio_players(host_game)
	host_game.queue_free()
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
	_expect(host_game.call("_try_spawn_enemy", BASIC_CONFIG), "Host must spawn a second enemy for projectile hit-limit tests.")
	var host_enemy := host_game.get_enemy_for_net_id(1)
	var second_host_enemy := host_game.get_enemy_for_net_id(2)
	_expect(host_enemy != null, "Host spawned enemy must be indexed by net id for hit dedupe test.")
	_expect(second_host_enemy != null, "Second host enemy must be indexed for projectile hit-limit tests.")
	if host_enemy != null and second_host_enemy != null:
		var mp_game := MP_GAME_SCENE.instantiate()
		mp_game.set("game", host_game)
		var host_net_manager := root.get_node_or_null("NetManager")
		var previous_role := 0
		if host_net_manager != null:
			previous_role = int(host_net_manager.get("net_role"))
			host_net_manager.set("net_role", 1)
			mp_game.set("net_manager", host_net_manager)
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
		var second_health_before_non_piercing_hit := second_host_enemy.current_health
		mp_game.call("_apply_enemy_hit_report", 2000001, 2, 2, 999, Vector2.LEFT)
		_expect(
			second_host_enemy.current_health == second_health_before_non_piercing_hit,
			"One non-piercing player bullet must accept only its first authoritative enemy hit."
		)
		var projectile_records := mp_game.get("_projectile_records") as Dictionary
		var non_piercing_record := projectile_records.get(2000001, {}) as Dictionary
		_expect(
			bool(non_piercing_record.get("confirmed_hit_consumed", false)),
			"A confirmed non-piercing bullet hit must consume its projectile record hit."
		)
		mp_game.call(
			"_remember_projectile_record",
			2000003,
			2,
			&"tiyi_sniper_bullet",
			1,
			0.35
		)
		var health_before_forged_sniper_hit := second_host_enemy.current_health
		var forged_sniper_hit_allowed := bool(mp_game.call(
			"_is_client_enemy_hit_report_allowed",
			2000003,
			2,
			2
		))
		_expect(
			not forged_sniper_hit_allowed
			and second_host_enemy.current_health == health_before_forged_sniper_hit,
			"Client-style hit reports must never settle Tiyi sniper damage."
		)
		mp_game.call(
			"_apply_enemy_hit_report",
			2000003,
			2,
			2,
			999,
			Vector2.LEFT
		)
		_expect(
			second_host_enemy.current_health < health_before_forged_sniper_hit,
			"Host-simulated Tiyi sniper hits must use the authoritative projectile record."
		)
		mp_game.call("_remember_projectile_record", 2000002, 2, &"player_bullet", 1, 2.0, true)
		var first_health_before_piercing_hit := host_enemy.current_health
		var second_health_before_piercing_hit := second_host_enemy.current_health
		mp_game.call("_apply_enemy_hit_report", 2000002, 2, 1, 999, Vector2.LEFT)
		mp_game.call("_apply_enemy_hit_report", 2000002, 2, 2, 999, Vector2.LEFT)
		_expect(
			host_enemy.current_health < first_health_before_piercing_hit
			and second_host_enemy.current_health < second_health_before_piercing_hit,
			"A piercing player bullet must retain independent hits against different enemies."
		)
		var health_before_collectible := host_enemy.current_health
		var collectible_result := bool(mp_game.call(
			"apply_multiplayer_collectible_enemy_damage",
			host_enemy,
			7,
			Vector2.RIGHT,
			int(EnemyConfig.DamageType.MAGIC)
		))
		_expect(collectible_result, "Host collectible enemy damage must use the multiplayer confirmation path.")
		_expect(
			host_enemy.current_health < health_before_collectible,
			"Host collectible enemy damage must reduce enemy health."
		)
		var peer_two := host_game.get_player_for_peer(2) as Player
		if peer_two != null:
			peer_two.current_health = 5
			var heal_result := bool(mp_game.call(
				"apply_multiplayer_player_heal",
				peer_two,
				LIFE_CRYSTAL.periodic_heal
			))
			_expect(heal_result, "Host-authoritative player heal must use the reliable multiplayer confirmation path.")
			_expect(peer_two.current_health == 15, "Host-authoritative player heal must restore health.")
			var health_revisions := mp_game.get("_player_health_revisions") as Dictionary
			var heal_revision := int(health_revisions.get(2, 0))
			_expect(heal_revision > 0, "Host-authoritative player heal must allocate a health revision.")
			peer_two.current_health = 5
			health_revisions.erase(2)
			mp_game.call("net_player_healed", 2, 15, 1)
			_expect(peer_two.current_health == 15, "Heal confirm must update the selected peer's health.")
			mp_game.call("net_player_healed", 2, 35, 1)
			_expect(peer_two.current_health == 15, "Stale heal revisions must be ignored.")
		if host_net_manager != null:
			host_net_manager.set("net_role", previous_role)
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
	var client_run_state := root.get_node_or_null("RunState") as RunStateStore
	if client_run_state != null:
		client_run_state.begin_new_run()
		client_run_state.set_active_multiplayer_peer(2)
		client_mp_game.set("run_state", client_run_state)

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

	var magic_enemy := BASIC_CONFIG.enemy_scene.instantiate() as Enemy
	_expect(magic_enemy != null, "Client magic damage test must instantiate an enemy.")
	if magic_enemy != null:
		client_game.enemy_container.add_child(magic_enemy)
		magic_enemy.setup(BASIC_CONFIG, client_game.player, client_game.grid_pathfinder)
		magic_enemy.configure_multiplayer_proxy()
		magic_enemy.set_meta("net_id", 78)
		magic_enemy.global_position = Vector2(88.0, 99.0)
		var client_net_enemies := client_mp_game.get("_net_enemies") as Dictionary
		client_net_enemies[78] = magic_enemy
		var health_after_magic := maxi(magic_enemy.current_health - 5, 1)
		client_mp_game.call(
			"net_enemy_damage_applied",
			78,
			health_after_magic,
			false,
			5,
			Vector2.LEFT,
			int(EnemyConfig.DamageType.MAGIC)
		)
		_expect(magic_enemy.current_health == health_after_magic, "Client magic damage confirm must update enemy health.")
		_expect(
			_has_active_damage_number_text(client_game, "5"),
			"Client magic damage confirm must spawn a damage number effect."
		)
		magic_enemy.queue_free()
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
		client_mp_game.call(
			"net_pickup_spawned",
			9002,
			HEALTH_PICKUP.resource_path,
			45.0,
			56.0
		)
		client_mp_game.call(
			"net_pickup_collected",
			9002,
			2,
			HEALTH_PICKUP.resource_path,
			false
		)
		await process_frame
		_expect(not client_game.multiplayer_pickups.has(9002), "Stored pickup confirm must erase pickup index.")
		_expect(
			client_run_state != null and client_run_state.get_item_for_peer(2, 0) == HEALTH_PICKUP,
			"Stored pickup confirm must add the item to the collector inventory."
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


func _count_linglan_skill1_warning_rays(node: Node) -> int:
	var count := 0
	for child in node.get_children():
		if child.name.begins_with("LinglanSkill1WarningRay"):
			count += 1
		count += _count_linglan_skill1_warning_rays(child)
	return count


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


func _test_multiplayer_revive_position_uses_living_players() -> void:
	var game := GAME_SCENE.instantiate() as Game
	_expect(game != null, "Game scene must instantiate for revive position test.")
	if game == null:
		return
	game.configure_multiplayer(1, 1, {1: "Host", 2: "Dead", 3: "RemoteAlive"})
	game.set("auto_start_waves", false)
	root.add_child(game)
	await process_frame

	var mp_game := MP_GAME_SCENE.instantiate()
	_expect(mp_game != null, "MpGame scene must instantiate for revive position test.")
	if mp_game == null:
		_stop_audio_players(game)
		game.queue_free()
		await process_frame
		return
	mp_game.set("game", game)

	var host_player := game.get_player_for_peer(1) as Player
	var dead_player := game.get_player_for_peer(2) as Player
	var remote_alive_player := game.get_player_for_peer(3) as Player
	_expect(host_player != null and dead_player != null and remote_alive_player != null, "Revive position test must have host, dead, and remote alive players.")
	if host_player != null and dead_player != null and remote_alive_player != null:
		host_player.global_position = Vector2(12.0, 34.0)
		dead_player.global_position = Vector2(90.0, 90.0)
		remote_alive_player.global_position = Vector2(-20.0, -30.0)
		dead_player.is_dead = true
		var accepted_positions := mp_game.get("_accepted_player_state_positions") as Dictionary
		var accepted_remote_position := Vector2(240.0, 320.0)
		accepted_positions[3] = accepted_remote_position

		var revive_positions := mp_game.call("_collect_living_player_revive_positions") as Array
		_expect(revive_positions.size() == 2, "Revive anchors must include only living players.")
		_expect(revive_positions.has(host_player.global_position), "Revive anchors must include the living host position.")
		_expect(revive_positions.has(accepted_remote_position), "Revive anchors must use accepted remote player positions.")
		_expect(not revive_positions.has(dead_player.global_position), "Revive anchors must exclude dead players.")

		var picked_position := mp_game.call("_pick_multiplayer_revive_position", revive_positions) as Vector2
		_expect(
			picked_position == host_player.global_position or picked_position == accepted_remote_position,
			"Random revive position must be selected from living player anchors."
		)

	mp_game.free()
	_stop_audio_players(game)
	game.queue_free()
	await process_frame


func _test_multiplayer_revive_resets_remote_visual_interpolator() -> void:
	var game := GAME_SCENE.instantiate() as Game
	_expect(game != null, "Game scene must instantiate for revive interpolation test.")
	if game == null:
		return
	game.configure_multiplayer(2, 2, {1: "Host", 2: "Local", 3: "Remote"})
	game.set("auto_start_waves", false)
	root.add_child(game)
	await process_frame

	var remote_player := game.get_player_for_peer(3) as Player
	_expect(remote_player != null, "Revive interpolation test must create remote peer 3.")
	if remote_player != null:
		var mp_game := MP_GAME_SCENE.instantiate()
		_expect(mp_game != null, "MpGame scene must instantiate for revive interpolation test.")
		if mp_game != null:
			mp_game.set("game", game)
			var old_position := Vector2(-400.0, -300.0)
			var revive_position := Vector2(96.0, 144.0)
			remote_player.global_position = old_position
			remote_player.apply_multiplayer_death_state()
			var stale_interp := NetInterpolator.new(0.1)
			stale_interp.push_snapshot(0.0, old_position, Vector2.ZERO)
			mp_game.player_visual_interpolators[3] = stale_interp
			var health_revisions := mp_game.get("_player_health_revisions") as Dictionary
			health_revisions[3] = 1

			mp_game.call(
				"net_player_revived",
				3,
				revive_position,
				remote_player.max_health,
				0.5,
				2
			)
			mp_game.call("_client_interpolate_entities")
			_expect(
				remote_player.global_position.is_equal_approx(revive_position),
				"Revive confirm must reset remote interpolation to the revive position."
			)
			var refreshed_interp := mp_game.player_visual_interpolators.get(3) as NetInterpolator
			_expect(
				refreshed_interp != null and refreshed_interp.get_buffer_size() == 1,
				"Revive confirm must leave exactly one fresh interpolation sample."
			)
			mp_game.free()
	_stop_audio_players(game)
	game.queue_free()
	await process_frame
	await physics_frame


func _test_client_local_damage_confirm_starts_hurt_blink() -> void:
	var game := GAME_SCENE.instantiate() as Game
	_expect(game != null, "Game scene must instantiate for client damage confirm blink test.")
	if game == null:
		return
	game.configure_multiplayer(2, 2, {1: "Host", 2: "Local"})
	game.set("auto_start_waves", false)
	root.add_child(game)
	await process_frame

	var local_player := game.get_player_for_peer(2) as Player
	var host_player := game.get_player_for_peer(1) as Player
	_expect(local_player != null, "Client damage confirm blink test must create the local player.")
	_expect(host_player != null, "Client damage confirm blink test must create the host player.")
	if local_player != null and host_player != null:
		var mp_game := MP_GAME_SCENE.instantiate()
		_expect(mp_game != null, "MpGame scene must instantiate for client damage confirm blink test.")
		if mp_game != null:
			mp_game.set("game", game)
			local_player.current_health = local_player.max_health
			local_player.invincibility_time_left = 0.0
			local_player.call("_set_hurt_blink_enabled", false)
			var sprite_material := local_player.body_sprite.material as ShaderMaterial
			_expect(sprite_material != null, "Local player body sprite must use a ShaderMaterial.")

			mp_game.call("net_player_damage_applied", 2, local_player.max_health - 7, false, 1)
			_expect(local_player.current_health == local_player.max_health - 7, "Local damage confirm must update health.")
			_expect(local_player.invincibility_time_left > 0.0, "Local damage confirm must start local blink time.")
			if sprite_material != null:
				_expect(
					bool(sprite_material.get_shader_parameter(&"blink_enabled")),
					"Local damage confirm must enable hurt blink on the local player."
				)

			local_player.invincibility_time_left = 0.0
			local_player.call("_set_hurt_blink_enabled", false)
			mp_game.call("net_player_damage_applied", 2, local_player.current_health, false, 2)
			_expect(
				local_player.invincibility_time_left > 0.0,
				"Local damage confirm must restore blink even when predicted health already matches."
			)
			if sprite_material != null:
				_expect(
					bool(sprite_material.get_shader_parameter(&"blink_enabled")),
					"Local same-health damage confirm must enable hurt blink on the local player."
				)

			local_player.invincibility_time_left = 0.0
			local_player.call("_set_hurt_blink_enabled", false)
			mp_game.call("net_player_damage_applied", 1, host_player.max_health - 5, false, 2)
			if sprite_material != null:
				_expect(
					not bool(sprite_material.get_shader_parameter(&"blink_enabled")),
					"Remote damage confirms must not enable hurt blink on the local player."
				)
			mp_game.free()
	_stop_audio_players(game)
	game.queue_free()
	await process_frame
	await physics_frame


func _test_linglan_boss_registration_uses_boss_event_only() -> void:
	var game := GAME_SCENE.instantiate() as Game
	_expect(game != null, "Game scene must instantiate for Linglan boss registration test.")
	if game == null:
		return
	game.configure_multiplayer(1, 1, {1: "Host", 2: "Client"})
	game.set("auto_start_waves", false)
	root.add_child(game)
	await process_frame

	var boss_enemy_config := LINGLAN_BOSS_CONFIG.call("get_enemy_config") as EnemyConfig
	_expect(boss_enemy_config != null, "Linglan boss config must resolve its enemy config.")
	var boss_enemy: LinglanBoss = null
	if boss_enemy_config != null and boss_enemy_config.enemy_scene != null:
		boss_enemy = boss_enemy_config.enemy_scene.instantiate() as LinglanBoss
	_expect(boss_enemy != null, "Linglan boss scene must instantiate as LinglanBoss.")
	if boss_enemy != null:
		game.boss_container.add_child(boss_enemy)
		boss_enemy.setup(boss_enemy_config, game.player, game.grid_pathfinder)
		var spawn_events: Array[int] = []
		var spawn_callback := func(net_id: int, _enemy_config: EnemyConfig, _spawn_position: Vector2) -> void:
			spawn_events.append(net_id)
		game.multiplayer_enemy_spawned.connect(spawn_callback)
		var net_id := int(game.call(
			"_register_multiplayer_enemy_instance",
			boss_enemy,
			boss_enemy_config,
			Vector2(42.0, 64.0),
			false
		))
		game.multiplayer_enemy_spawned.disconnect(spawn_callback)
		_expect(net_id > 0, "Linglan boss registration must allocate a net id.")
		_expect(spawn_events.is_empty(), "Linglan boss registration must not emit generic enemy spawn.")
		_expect(
			game.get_enemy_for_net_id(net_id) == boss_enemy,
			"Linglan boss registration must still index the boss by net id."
		)

	_stop_audio_players(game)
	game.queue_free()
	await process_frame
	await physics_frame


func _test_linglan_boss_proxy_keeps_body_hit_collision() -> void:
	var boss_enemy_config := LINGLAN_BOSS_CONFIG.call("get_enemy_config") as EnemyConfig
	_expect(boss_enemy_config != null, "Linglan proxy collision test must resolve enemy config.")
	if boss_enemy_config == null or boss_enemy_config.enemy_scene == null:
		return
	var boss_enemy := boss_enemy_config.enemy_scene.instantiate() as LinglanBoss
	_expect(boss_enemy != null, "Linglan proxy collision test must instantiate Linglan boss.")
	if boss_enemy == null:
		return
	root.add_child(boss_enemy)
	await process_frame
	boss_enemy.setup(boss_enemy_config, null, null)
	boss_enemy.configure_multiplayer_proxy()
	await process_frame
	await physics_frame

	_expect(boss_enemy.visible, "Linglan proxy must be visible after multiplayer proxy configuration.")
	_expect(
		boss_enemy.collision_shape != null and not boss_enemy.collision_shape.disabled,
		"Linglan proxy must keep body collision enabled so client bullets can hit it."
	)
	_expect(
		boss_enemy.touch_damage_shape != null and boss_enemy.touch_damage_shape.disabled,
		"Linglan proxy must keep touch damage collision disabled."
	)
	_expect(
		boss_enemy.touch_damage_area == null or not boss_enemy.touch_damage_area.monitoring,
		"Linglan proxy touch damage area must not monitor players."
	)

	boss_enemy.queue_free()
	await process_frame
	await physics_frame


func _test_client_linglan_skill2_rocket_does_not_damage_enemy_proxy() -> void:
	var previous_scene := current_scene
	var client_runtime_stub := ClientViewRuntimeStub.new()
	root.add_child(client_runtime_stub)
	current_scene = client_runtime_stub

	var enemy := BASIC_CONFIG.enemy_scene.instantiate() as Enemy
	var rocket := LINGLAN_SKILL2_ROCKET_SCENE.instantiate() as LinglanSkill2SakuraRocket
	_expect(enemy != null and rocket != null, "Linglan skill2 client proxy damage test must instantiate enemy and rocket.")
	if enemy != null and rocket != null:
		root.add_child(enemy)
		root.add_child(rocket)
		await process_frame
		enemy.setup(BASIC_CONFIG, null, null)
		enemy.configure_multiplayer_proxy()
		var health_before_client_proxy_hit := enemy.current_health
		rocket.damage = 1
		rocket.call("_apply_enemy_damage", enemy)
		_expect(
			enemy.current_health == health_before_client_proxy_hit,
			"Client-view Linglan skill2 rocket must not apply local damage to enemy proxies."
		)

		current_scene = previous_scene
		rocket.call("_apply_enemy_damage", enemy)
		_expect(
			enemy.current_health == health_before_client_proxy_hit - 1,
			"Linglan skill2 rocket must still damage enemies outside client-view proxy runtime."
		)

	if rocket != null:
		rocket.queue_free()
	if enemy != null:
		enemy.queue_free()
	client_runtime_stub.queue_free()
	current_scene = previous_scene
	await process_frame
	await physics_frame

	var game := GAME_SCENE.instantiate() as Game
	_expect(game != null, "Sakura rocket multiplayer test must instantiate Game.")
	if game == null:
		return
	game.configure_multiplayer(1, 1, {1: "Host", 2: "Client"})
	game.set("auto_start_waves", false)
	root.add_child(game)
	await process_frame
	var mp_game := MP_GAME_SCENE.instantiate()
	_expect(mp_game != null, "Sakura rocket multiplayer test must instantiate MpGame.")
	if mp_game == null:
		_stop_audio_players(game)
		game.queue_free()
		await process_frame
		return
	mp_game.set("game", game)
	var net_manager := root.get_node_or_null("NetManager")
	var previous_role := 0
	if net_manager != null:
		previous_role = int(net_manager.get("net_role"))
		net_manager.set("net_role", 1)
		mp_game.set("net_manager", net_manager)

	var target_enemy := BASIC_CONFIG.enemy_scene.instantiate() as Enemy
	_expect(target_enemy != null, "Sakura rocket multiplayer test must instantiate target enemy.")
	if target_enemy != null:
		var enemy_config := BASIC_CONFIG.duplicate(true) as EnemyConfig
		enemy_config.max_health = 500
		enemy_config.magic_defense = 0
		game.enemy_container.add_child(target_enemy)
		target_enemy.global_position = Vector2(64.0, 0.0)
		target_enemy.setup(enemy_config, game.player, game.grid_pathfinder)
		target_enemy.set_meta("net_id", 501)
		game.multiplayer_enemies_by_net_id[501] = target_enemy

		mp_game.call(
			"net_projectile_fired",
			2000009,
			"collectible_sakura_rocket",
			2,
			Vector2.ZERO,
			Vector2.RIGHT,
			100,
			210.0,
			5.0,
			false,
			0,
			-1.0,
			501
		)
		await process_frame
		var known_projectiles := mp_game.get("_known_projectiles") as Dictionary
		var spawned_rocket := known_projectiles.get(2000009) as LinglanSkill2SakuraRocket
		_expect(spawned_rocket != null, "Sakura rocket network spawn must create a tracked projectile.")
		if spawned_rocket != null:
			_expect(spawned_rocket.target_node == target_enemy, "Sakura rocket network spawn must resolve target_enemy_net_id.")
			_expect(spawned_rocket.enemies_only, "Sakura rocket network spawn must be enemy-only.")
			_expect(spawned_rocket.damage_type == EnemyConfig.DamageType.MAGIC, "Sakura rocket network spawn must use magic damage.")
			_expect(
				is_equal_approx(
					spawned_rocket.explosion_radius,
					LinglanSkill2SakuraRocket.COLLECTIBLE_SAKURA_EXPLOSION_RADIUS
				),
				"Sakura rocket network spawn must use the collectible Sakura explosion radius."
			)
		var health_before := target_enemy.current_health
		var applied := bool(mp_game.call(
			"apply_multiplayer_collectible_enemy_damage",
			target_enemy,
			100,
			Vector2.RIGHT,
			int(EnemyConfig.DamageType.MAGIC)
		))
		_expect(applied, "Host must accept Sakura collectible enemy damage confirmation.")
		_expect(target_enemy.current_health == health_before - 100, "Sakura collectible enemy damage must apply as magic damage.")

	if net_manager != null:
		net_manager.set("net_role", previous_role)
	mp_game.free()
	_stop_audio_players(game)
	game.queue_free()
	await process_frame
	await physics_frame


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
		var run_state := root.get_node("RunState") as RunStateStore
		run_state.begin_new_run()
		mp_game.set("run_state", run_state)
		mp_game.call("net_debug_collectible_granted", 2, APPLE_COLLECTIBLE.resource_path, true)
		_expect(
			run_state.get_item_for_peer(2, 0) == APPLE_COLLECTIBLE,
			"Debug collectible confirm must add the selected collectible to the selected peer inventory."
		)

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
	_expect(host_player.nameplate_label.custom_minimum_size.y >= 30.0, "Multiplayer nameplate must leave room for outlined player names.")
	_expect(host_player.current_xirang == Game.INITIAL_PLAYER_XIRANG, "Host player must start with initial xirang.")
	_expect(
		host_player.nameplate_label.label_settings.font_color.is_equal_approx(Player.LOCAL_NAMEPLATE_FONT_COLOR),
		"Local host nameplate text must be green."
	)
	var host_remote_player := host_game.get_player_for_peer(2) as Player
	_expect(
		host_remote_player != null
		and host_remote_player.nameplate_label.label_settings.font_color.is_equal_approx(Player.DEFAULT_NAMEPLATE_FONT_COLOR)
		and host_remote_player.nameplate_label.label_settings != host_player.nameplate_label.label_settings,
		"Remote player nameplate must keep the normal color on the host."
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
	var client_local_player := client_game.get_player_for_peer(2) as Player
	var client_remote_player := client_game.get_player_for_peer(1) as Player
	_expect(
		client_local_player != null
		and client_local_player.nameplate_label.label_settings.font_color.is_equal_approx(Player.LOCAL_NAMEPLATE_FONT_COLOR),
		"Local client nameplate text must be green."
	)
	_expect(
		client_local_player != null
		and client_local_player.current_xirang == Game.INITIAL_PLAYER_XIRANG,
		"Client local player must start with initial xirang."
	)
	_expect(
		client_remote_player != null
		and client_remote_player.nameplate_label.label_settings.font_color.is_equal_approx(Player.DEFAULT_NAMEPLATE_FONT_COLOR)
		and client_remote_player.nameplate_label.label_settings != client_local_player.nameplate_label.label_settings,
		"Remote host nameplate must keep the normal color on the client."
	)
	_stop_audio_players(client_game)
	client_game.queue_free()
	await process_frame


func _test_snapshot_round_trip() -> void:
	var snapshot_mgr := SnapshotManager.new()
	_expect(
		SnapshotManager._encode_character_id(&"weishidaier") == 0
		and SnapshotManager._encode_character_id(&"hoe_cat") == 1
		and SnapshotManager._encode_character_id(&"tiyi") == 2,
		"Snapshot character codes must preserve 0/1 and assign 2 to Tiyi."
	)
	var player_state := SnapshotManager.PlayerState.new()
	player_state.peer_id = 2
	player_state.character_id = &"hoe_cat"
	player_state.position = Vector2(11.5, 23.25)
	player_state.velocity = Vector2(1.0, -2.0)
	player_state.current_health = 42
	player_state.max_health = 100
	player_state.skill1_unlocked = true
	player_state.skill1_charge = 3.0
	player_state.skill1_charge_duration = 14.0
	player_state.skill1_upgrade_level = 2
	player_state.ammo_capacity = 30
	player_state.current_ammo = 17
	player_state.is_reloading = true
	player_state.reload_progress = 0.4
	player_state.primary_cooldown_ratio = 0.37
	var player_data := snapshot_mgr.encode_all_player_snapshots([player_state])
	var player_states := SnapshotManager.decode_all_player_snapshots(player_data)
	_expect(player_states.size() == 1, "Player snapshot count mismatch.")
	if player_states.size() == 1:
		_expect(player_states[0].peer_id == 2, "Player snapshot peer_id mismatch.")
		_expect(player_states[0].current_health == 42, "Player snapshot health mismatch.")
		_expect(player_states[0].skill1_upgrade_level == 2, "Player snapshot skill1 upgrade level mismatch.")
		_expect(player_states[0].ammo_capacity == 30, "Player snapshot ammo capacity mismatch.")
		_expect(player_states[0].current_ammo == 17, "Player snapshot current ammo mismatch.")
		_expect(player_states[0].is_reloading, "Player snapshot reload state mismatch.")
		_expect(is_equal_approx(player_states[0].reload_progress, 0.4), "Player snapshot reload progress mismatch.")
		_expect(player_states[0].character_id == &"hoe_cat", "Player snapshot character id mismatch.")
		_expect(
			absf(player_states[0].primary_cooldown_ratio - 0.37) <= 1.0 / 255.0,
			"Player snapshot primary cooldown ratio mismatch."
		)
	var tiyi_state := SnapshotManager.PlayerState.new()
	tiyi_state.peer_id = 3
	tiyi_state.character_id = &"tiyi"
	tiyi_state.current_health = 50
	tiyi_state.max_health = 50
	tiyi_state.ammo_capacity = 5
	tiyi_state.current_ammo = 4
	var tiyi_data := snapshot_mgr.encode_all_player_snapshots([tiyi_state])
	var tiyi_states := snapshot_mgr.decode_all_player_snapshots(tiyi_data)
	_expect(
		tiyi_states.size() == 1
		and tiyi_states[0].peer_id == 3
		and tiyi_states[0].character_id == &"tiyi"
		and tiyi_states[0].ammo_capacity == 5
		and tiyi_states[0].current_ammo == 4,
		"Player snapshot character code 2 must round-trip Tiyi without changing legacy codes."
	)
	var player_data_2 := snapshot_mgr.encode_all_player_snapshots([player_state])
	var player_states_2 := SnapshotManager.decode_all_player_snapshots(player_data_2)
	_expect(
		player_states_2.size() == 1 and player_states_2[0].position.distance_to(player_state.position) < 0.12,
		"Legacy repeated player snapshots must remain full snapshots."
	)
	var delta_player_mgr := SnapshotManager.new()
	var player_keyframe := delta_player_mgr.encode_player_snapshots_for_peer(10, [player_state], true)
	var received_player_keyframe := delta_player_mgr.decode_player_snapshots_with_baseline(player_keyframe)
	_expect(received_player_keyframe.size() == 1, "Player keyframe delta path must decode one state.")
	var repeated_player_delta := delta_player_mgr.encode_player_snapshots_for_peer(10, [player_state], false)
	_expect(
		repeated_player_delta.size() < player_keyframe.size(),
		"Repeated per-peer player snapshots must encode as a smaller delta."
	)
	var repeated_player_states := delta_player_mgr.decode_player_snapshots_with_baseline(repeated_player_delta)
	_expect(repeated_player_states.size() == 1, "Repeated player delta must decode through baseline.")
	if repeated_player_states.size() == 1:
		_expect(repeated_player_states[0].current_health == 42, "Player delta must preserve health through baseline.")
		_expect(repeated_player_states[0].skill1_upgrade_level == 2, "Player delta must preserve skill upgrade through baseline.")
		_expect(repeated_player_states[0].ammo_capacity == 30, "Player delta must preserve ammo capacity through baseline.")
		_expect(repeated_player_states[0].current_ammo == 17, "Player delta must preserve current ammo through baseline.")
		_expect(repeated_player_states[0].is_reloading, "Player delta must preserve reload state through baseline.")
		_expect(is_equal_approx(repeated_player_states[0].reload_progress, 0.4), "Player delta must preserve reload progress through baseline.")
		_expect(repeated_player_states[0].character_id == &"hoe_cat", "Player delta must preserve character id through baseline.")
		_expect(
			absf(repeated_player_states[0].primary_cooldown_ratio - 0.37) <= 1.0 / 255.0,
			"Player delta must preserve primary cooldown through baseline."
		)
	var player_copy_sender := SnapshotManager.new()
	var player_copy_receiver := SnapshotManager.new()
	var reused_player_state := SnapshotManager.PlayerState.new()
	reused_player_state.peer_id = 6
	reused_player_state.position = Vector2(4.0, 5.0)
	reused_player_state.velocity = Vector2.ZERO
	reused_player_state.current_health = 70
	reused_player_state.max_health = 100
	reused_player_state.ammo_capacity = 30
	reused_player_state.current_ammo = 12
	reused_player_state.is_reloading = true
	reused_player_state.reload_progress = 0.25
	player_copy_receiver.decode_player_snapshots_with_baseline(
		player_copy_sender.encode_player_snapshots_for_peer(30, [reused_player_state], true)
	)
	reused_player_state.position = Vector2(44.0, 55.0)
	reused_player_state.velocity = Vector2(6.0, 7.0)
	var reused_player_delta := player_copy_sender.encode_player_snapshots_for_peer(30, [reused_player_state], false)
	var reused_player_states := player_copy_receiver.decode_player_snapshots_with_baseline(reused_player_delta)
	_expect(
		reused_player_states.size() == 1
		and reused_player_states[0].position.distance_to(reused_player_state.position) < 0.12
		and reused_player_states[0].velocity.distance_to(reused_player_state.velocity) < 0.12,
		"Player send baselines must store state copies, not references to reused state objects."
	)
	var moved_player_state := SnapshotManager.PlayerState.new()
	moved_player_state.peer_id = 2
	moved_player_state.sequence = 2
	moved_player_state.character_id = &"hoe_cat"
	moved_player_state.position = Vector2(20.5, 30.25)
	moved_player_state.velocity = Vector2(3.0, -4.0)
	moved_player_state.current_health = 42
	moved_player_state.max_health = 100
	moved_player_state.skill1_unlocked = true
	moved_player_state.skill1_charge = 3.0
	moved_player_state.skill1_charge_duration = 14.0
	moved_player_state.skill1_upgrade_level = 2
	moved_player_state.ammo_capacity = 30
	moved_player_state.current_ammo = 17
	moved_player_state.is_reloading = true
	moved_player_state.reload_progress = 0.4
	moved_player_state.primary_cooldown_ratio = 0.37
	var moved_player_delta := delta_player_mgr.encode_player_snapshots_for_peer(10, [moved_player_state], false)
	_expect(
		moved_player_delta.size() < player_keyframe.size(),
		"Moved player snapshot must still be smaller than a keyframe."
	)
	var moved_player_states := delta_player_mgr.decode_player_snapshots_with_baseline(moved_player_delta)
	_expect(moved_player_states.size() == 1, "Moved player delta must decode through baseline.")
	if moved_player_states.size() == 1:
		_expect(
			moved_player_states[0].position.distance_to(moved_player_state.position) < 0.12,
			"Moved player delta must update position."
		)
		_expect(moved_player_states[0].current_health == 42, "Moved player delta must preserve unchanged health.")
		_expect(moved_player_states[0].skill1_upgrade_level == 2, "Moved player delta must preserve unchanged skill state.")
		_expect(moved_player_states[0].current_ammo == 17, "Moved player delta must preserve unchanged ammo state.")
	var peer_11_player_data := delta_player_mgr.encode_player_snapshots_for_peer(11, [moved_player_state], false)
	_expect(
		peer_11_player_data.size() == player_keyframe.size(),
		"A different receiver peer must get a player keyframe until it has its own baseline."
	)
	var missing_player_baseline_mgr := SnapshotManager.new()
	var skipped_player_delta := missing_player_baseline_mgr.decode_player_snapshots_with_baseline(moved_player_delta)
	_expect(skipped_player_delta.is_empty(), "Player delta without receive baseline must be skipped.")
	var recovered_player_keyframe := missing_player_baseline_mgr.decode_player_snapshots_with_baseline(player_keyframe)
	_expect(recovered_player_keyframe.size() == 1, "Player keyframe must recover after a skipped delta.")
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
		"Legacy repeated enemy snapshots must remain full snapshots."
	)
	var delta_enemy_mgr := SnapshotManager.new()
	var enemy_keyframe := delta_enemy_mgr.encode_enemy_snapshots_for_peer(20, [enemy_state], true)
	var received_enemy_keyframe := delta_enemy_mgr.decode_enemy_snapshots_with_baseline(enemy_keyframe)
	_expect(received_enemy_keyframe.size() == 1, "Enemy keyframe delta path must decode one state.")
	var repeated_enemy_delta := delta_enemy_mgr.encode_enemy_snapshots_for_peer(20, [enemy_state], false)
	_expect(
		repeated_enemy_delta.size() < enemy_keyframe.size(),
		"Repeated per-peer enemy snapshots must encode as a smaller delta."
	)
	var repeated_enemy_states := delta_enemy_mgr.decode_enemy_snapshots_with_baseline(repeated_enemy_delta)
	_expect(repeated_enemy_states.size() == 1, "Repeated enemy delta must decode through baseline.")
	if repeated_enemy_states.size() == 1:
		_expect(repeated_enemy_states[0].health == 3, "Enemy delta must preserve health through baseline.")
	var enemy_copy_sender := SnapshotManager.new()
	var enemy_copy_receiver := SnapshotManager.new()
	var reused_enemy_state := SnapshotManager.EnemyState.new()
	reused_enemy_state.net_id = 19
	reused_enemy_state.position = Vector2(7.0, 8.0)
	reused_enemy_state.velocity = Vector2.ZERO
	reused_enemy_state.health = 12
	enemy_copy_receiver.decode_enemy_snapshots_with_baseline(
		enemy_copy_sender.encode_enemy_snapshots_for_peer(40, [reused_enemy_state], true)
	)
	reused_enemy_state.position = Vector2(27.0, 38.0)
	reused_enemy_state.velocity = Vector2(-3.0, 2.0)
	reused_enemy_state.health = 9
	var reused_enemy_delta := enemy_copy_sender.encode_enemy_snapshots_for_peer(40, [reused_enemy_state], false)
	var reused_enemy_states := enemy_copy_receiver.decode_enemy_snapshots_with_baseline(reused_enemy_delta)
	_expect(
		reused_enemy_states.size() == 1
		and reused_enemy_states[0].position.distance_to(reused_enemy_state.position) < 0.12
		and reused_enemy_states[0].velocity.distance_to(reused_enemy_state.velocity) < 0.12
		and reused_enemy_states[0].health == 9,
		"Enemy send baselines must store state copies, not references to reused state objects."
	)
	var moved_enemy_state := SnapshotManager.EnemyState.new()
	moved_enemy_state.net_id = 7
	moved_enemy_state.position = Vector2(91.0, 100.0)
	moved_enemy_state.velocity = Vector2.RIGHT
	moved_enemy_state.health = 3
	var moved_enemy_delta := delta_enemy_mgr.encode_enemy_snapshots_for_peer(20, [moved_enemy_state], false)
	_expect(
		moved_enemy_delta.size() < enemy_keyframe.size(),
		"Moved enemy snapshot must still be smaller than a keyframe."
	)
	var moved_enemy_states := delta_enemy_mgr.decode_enemy_snapshots_with_baseline(moved_enemy_delta)
	_expect(moved_enemy_states.size() == 1, "Moved enemy delta must decode through baseline.")
	if moved_enemy_states.size() == 1:
		_expect(
			moved_enemy_states[0].position.distance_to(moved_enemy_state.position) < 0.12,
			"Moved enemy delta must update position."
		)
		_expect(moved_enemy_states[0].health == 3, "Moved enemy delta must preserve unchanged health.")
	var missing_enemy_baseline_mgr := SnapshotManager.new()
	var skipped_enemy_delta := missing_enemy_baseline_mgr.decode_enemy_snapshots_with_baseline(moved_enemy_delta)
	_expect(skipped_enemy_delta.is_empty(), "Enemy delta without receive baseline must be skipped.")
	var recovered_enemy_keyframe := missing_enemy_baseline_mgr.decode_enemy_snapshots_with_baseline(enemy_keyframe)
	_expect(recovered_enemy_keyframe.size() == 1, "Enemy keyframe must recover after a skipped delta.")
	var empty_enemy_keyframe := delta_enemy_mgr.encode_enemy_snapshots_for_peer(20, [], true)
	var empty_enemy_states := delta_enemy_mgr.decode_enemy_snapshots_with_baseline(empty_enemy_keyframe)
	_expect(empty_enemy_states.is_empty(), "Empty enemy keyframe must decode as an empty roster.")
	_expect(delta_enemy_mgr.enemy_receive_baselines.is_empty(), "Empty enemy keyframe must prune receive baselines.")
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


func _has_active_damage_number_text(game: Game, expected_text: String) -> bool:
	if game == null or game.damage_number_pool == null:
		return false
	for number in game.damage_number_pool.pooled_numbers:
		var damage_number := number as DamageNumber
		if damage_number == null or not damage_number.is_active():
			continue
		if damage_number.label != null and damage_number.label.text == expected_text:
			return true
	return false


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
