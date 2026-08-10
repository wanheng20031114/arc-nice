extends SceneTree

const MpProjectileCoordinator := preload(
	"res://scene/multiplayer/projectile/mp_projectile_coordinator.gd"
)
const MpWorldFlowCoordinator := preload(
	"res://scene/multiplayer/world_flow/mp_world_flow_coordinator.gd"
)
const MpGameScript := preload("res://scene/multiplayer/mp_game.gd")
const LOBBY_SCENE := preload("res://scene/multiplayer/multiplayer_lobby.tscn")
const MP_GAME_SCENE := preload("res://scene/multiplayer/mp_game.tscn")
const GAME_SCENE := preload("res://scene/game_modes/standard/standard_game.tscn")
const TOWER_DEFENSE_GAME_SCENE := preload("res://scene/game_modes/tower_defense/tower_defense_game.tscn")
const TEST_ARENA_SCENE := preload("res://scene/game_modes/tower_defense/test_arenas/test_grass_arena.tscn")
const TEST_ARENA_P2_SCENE := preload("res://scene/game_modes/tower_defense/test_arenas/test_grass_arena_p2.tscn")
const TEST_ARENA_MULTIPLAYER_CAMPAIGN := preload(
	"res://resources/config/campaigns/test_arena/multiplayer/campaign.tres"
)
const TEST_ARENA_P2_MULTIPLAYER_CAMPAIGN := preload(
	"res://resources/config/campaigns/test_arena/p2/multiplayer/campaign.tres"
)
const PLAYER_SCENE := preload("res://scene/player/weishidaier/player_weishidaier.tscn")
const BASIC_CONFIG := preload("res://resources/config/enemies/yuanshi_insect_basic.tres")
const BOMBER_CONFIG := preload("res://resources/config/enemies/yuanshi_insect_bomber.tres")
const KNIGHT_CONFIG := preload("res://resources/config/enemies/capoo_knight.tres")
const RPG_CONFIG := preload("res://resources/config/enemies/capoo_rpg.tres")
const SNIPER_CONFIG := preload("res://resources/config/enemies/capoo_sniper.tres")
const LINGLAN_SLIME_CONFIG_PATHS: Array[String] = [
	"res://resources/config/enemies/slime.tres",
	"res://resources/config/enemies/slime_green.tres",
	"res://resources/config/enemies/slime_golden.tres",
	"res://resources/config/enemies/slime_frost.tres",
	"res://resources/config/enemies/slime_fire.tres",
]
const PICKUP_SPEED_CONFIG := preload("res://resources/config/pickup_triggered_items/speed_boots.tres")
const PICKUP_SPIRAL_CONFIG := preload("res://resources/config/pickup_triggered_items/snow_wolf_pojun.tres")
const HEALTH_PICKUP := preload("res://resources/config/consumables/healing_potion.tres")
const WOOD_MATERIAL := preload("res://resources/config/materials/material_wood.tres")
const SAPLING_MATERIAL := preload("res://resources/config/materials/material_sapling.tres")
const WHITE_CRYSTAL_MATERIAL := preload(
	"res://resources/config/materials/material_white_crystal.tres"
)
const WATER_BOTTLE_MATERIAL := preload("res://resources/config/materials/material_water_bottle.tres")
const LINGLAN_SKILL2_ROCKET_SCENE := preload("res://scene/boss/linglan/linglan_skill2_sakura_rocket.tscn")
const APPLE_COLLECTIBLE := preload("res://resources/config/collectibles/collectible_apple.tres")
const ARCHER_COLLECTIBLE := preload("res://resources/config/collectibles/collectible_archer.tres")
const LIFE_CRYSTAL := preload("res://resources/config/collectibles/collectible_life_crystal.tres")
const LINGLAN_BOSS_CONFIG := preload("res://resources/config/bosses/boss_01_linglan.tres")
const NetConstants := preload("res://scene/multiplayer/net_constants.gd")
const PROJECTILE_EVENTS_ONLY_ARG := "--projectile-events-only"
const PROTOCOL_ONLY_ARG := "--protocol-only"

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	if OS.get_cmdline_user_args().has(PROTOCOL_ONLY_ARG):
		_test_net_manager_protocol_version_gate()
		_finish_test_run()
		return
	if OS.get_cmdline_user_args().has(PROJECTILE_EVENTS_ONLY_ARG):
		await _test_enemy_hit_dedupe_enemy_removed_and_pickup_confirm()
		for _cleanup_frame in range(4):
			await process_frame
			await physics_frame
		_finish_test_run()
		return

	await _test_scene_instantiation()
	_test_net_manager_protocol_version_gate()
	_test_net_manager_game_mode_authority()
	_test_net_manager_lan_lifecycle()
	_test_public_room_context_lifecycle()
	_test_net_manager_player_list_sync_diff()
	_test_recent_event_cache()
	_test_snapshot_packet_metrics()
	_test_enemy_snapshot_chunk_codec()
	_test_delta_snapshot_peer_cache_cleanup()
	_test_freed_pickup_index_cleanup()
	await _test_enemy_proxy_action_animation_restore()
	await _test_player_multiplayer_death_visual_state()
	await _test_multiplayer_revive_position_uses_living_players()
	await _test_tower_defense_spawn_slots_and_fixed_respawn()
	await _test_multiplayer_revive_resets_remote_visual_interpolator()
	await _test_client_local_damage_confirm_starts_hurt_blink()
	await _test_linglan_boss_registration_uses_boss_event_only()
	await _test_linglan_airdrop_replication_contract()
	await _test_linglan_boss_proxy_keeps_body_hit_collision()
	await _test_client_linglan_skill2_rocket_does_not_damage_enemy_proxy()
	await _test_multiplayer_cheat_xirang_confirm()
	await _test_multiplayer_peer_disconnect_cleanup()
	await _test_player_snapshot_roster_reconcile()
	await _test_enemy_snapshot_roster_requires_complete_batch()
	await _test_enemy_snapshot_death_and_empty_roster_cleanup()
	await _test_host_remote_player_position_writeback()
	await _test_projectile_time_compensation()
	await _test_enemy_action_uses_snapshot_timeline()
	await _test_host_remote_player_form_buff_expires()
	await _test_four_player_runtime_and_confirmed_events()
	await _test_multiplayer_character_scene_registry()
	await _test_host_authoritative_hoe_actions()
	await _test_host_authoritative_tiyi_protocol()
	await _test_enemy_hit_dedupe_enemy_removed_and_pickup_confirm()
	await _test_game_runtime_modes()
	await _test_test_arena_multiplayer_runtime_modes()
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
		_expect(
			mp_game.get_node_or_null("SessionCoordinator") is MpSessionCoordinator,
			"MpGame must statically instantiate its session coordinator."
		)
		_expect(
			mp_game.get_node_or_null("PlayerCoordinator") is MpPlayerCoordinator,
			"MpGame must statically instantiate its player snapshot coordinator."
		)
		_expect(
			mp_game.get_node_or_null("EnemyCoordinator") is MpEnemyCoordinator,
			"MpGame must statically instantiate its enemy synchronization coordinator."
		)
		_expect(
			mp_game.get_node_or_null("WorldFlowCoordinator") is MpWorldFlowCoordinator,
			"MpGame must statically instantiate its world-flow coordinator."
		)
		mp_game.free()

	var game := GAME_SCENE.instantiate()
	_expect(game != null, "game.tscn must instantiate as StandardGame.")
	if game != null:
		game.configure_multiplayer(2, 2, {1: "Host", 2: "Client"})
		_stop_audio_players(game)
		game.free()

	for arena_contract in [
		{
			"scene": TEST_ARENA_SCENE,
			"campaign": TEST_ARENA_MULTIPLAYER_CAMPAIGN,
			"name": "P1",
		},
		{
			"scene": TEST_ARENA_P2_SCENE,
			"campaign": TEST_ARENA_P2_MULTIPLAYER_CAMPAIGN,
			"name": "P2",
		},
	]:
		var arena_scene := arena_contract["scene"] as PackedScene
		var arena := arena_scene.instantiate() as TestGrassArena
		_expect(
			arena != null,
			"Test arena %s must instantiate as the tower-defense test runtime."
			% arena_contract["name"]
		)
		if arena != null:
			var arena_definition := arena.mode_definition as GameModeDefinition
			_expect(
				arena_definition != null
				and arena_definition.multiplayer_campaign_path
				== (arena_contract["campaign"] as WaveCampaignConfig).resource_path,
				"Test arena %s must bind its dedicated multiplayer Campaign definition."
				% arena_contract["name"]
			)
			arena.free()

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
	_expect(
		net_manager.set_host_game_mode(NetManagerStore.GameMode.TOWER_DEFENSE),
		"LAN Host must be able to choose tower-defense mode before creating the server."
	)
	var err: Error = net_manager.host_create_lan_server(29171, 3)
	_expect(err == OK, "NetManager must create a LAN host on test port.")
	_expect(net_manager.is_host(), "NetManager must enter host role.")
	_expect(net_manager.connected_players.has(1), "Host peer must be registered.")
	_expect(
		net_manager.get_current_game_mode() == NetManagerStore.GameMode.TOWER_DEFENSE,
		"Creating a LAN server must preserve the Host-selected game mode."
	)
	_expect(
		net_manager.get_room_max_players() == 3,
		"Creating a LAN server must preserve the selected total room capacity."
	)
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
	var loading_progress: Dictionary = net_manager.get_game_load_progress()
	_expect(
		int(loading_progress.get("ready", -1)) == 0
		and int(loading_progress.get("total", -1)) == 1
		and int(loading_progress.get("session_id", 0)) > 0,
		"Host start must freeze a one-peer loading roster with a valid session id."
	)
	net_manager.mark_in_game()
	_expect(
		int(net_manager.connection_state) == 4,
		"Host mark_in_game must not bypass the loading roster barrier."
	)
	net_manager.report_game_loaded()
	_expect(int(net_manager.connection_state) == 5, "The final loaded peer must enter in-game state.")
	_expect(bool(net_manager.host_game_ready), "The completed barrier must publish host ready state.")
	net_manager.disconnect_from_game()
	_expect(not net_manager.is_multiplayer_active(), "NetManager must cleanly disconnect after LAN host smoke.")


func _test_net_manager_protocol_version_gate() -> void:
	var net_manager := root.get_node_or_null("NetManager")
	_expect(net_manager != null, "NetManager autoload is missing for protocol version coverage.")
	if net_manager == null:
		return

	net_manager.disconnect_from_game()
	_expect(NetConstants.PROTOCOL_VERSION == 55, "The multiplayer protocol version must be 55.")
	_expect(NetConstants.CHANNEL_COUNT == 8, "Protocol v55 must retain eight ENet channels.")
	_expect(
		bool(net_manager.call("_is_protocol_version_compatible", NetConstants.PROTOCOL_VERSION)),
		"NetManager must accept the current protocol version."
	)
	_expect(
		not bool(net_manager.call("_is_protocol_version_compatible", 53))
		and not bool(net_manager.call("_is_protocol_version_compatible", 52))
		and not bool(net_manager.call("_is_protocol_version_compatible", 51))
		and not bool(net_manager.call("_is_protocol_version_compatible", 50))
		and not bool(net_manager.call("_is_protocol_version_compatible", 49))
		and not bool(net_manager.call("_is_protocol_version_compatible", 48))
		and not bool(net_manager.call("_is_protocol_version_compatible", 47))
		and not bool(net_manager.call("_is_protocol_version_compatible", 46))
		and not bool(net_manager.call("_is_protocol_version_compatible", 45))
		and not bool(net_manager.call("_is_protocol_version_compatible", 44))
		and not bool(net_manager.call("_is_protocol_version_compatible", 43))
		and not bool(net_manager.call("_is_protocol_version_compatible", 42))
		and not bool(net_manager.call("_is_protocol_version_compatible", 41))
		and not bool(net_manager.call("_is_protocol_version_compatible", 40))
		and not bool(net_manager.call("_is_protocol_version_compatible", 39))
		and not bool(net_manager.call("_is_protocol_version_compatible", 38))
		and not bool(net_manager.call("_is_protocol_version_compatible", 37))
		and not bool(net_manager.call("_is_protocol_version_compatible", 36))
		and not bool(net_manager.call("_is_protocol_version_compatible", 35))
		and not bool(net_manager.call("_is_protocol_version_compatible", 34))
		and not bool(net_manager.call("_is_protocol_version_compatible", 33))
		and not bool(net_manager.call("_is_protocol_version_compatible", 32))
		and not bool(net_manager.call("_is_protocol_version_compatible", 31))
		and not bool(net_manager.call("_is_protocol_version_compatible", 30))
		and not bool(net_manager.call("_is_protocol_version_compatible", 29))
		and not bool(net_manager.call("_is_protocol_version_compatible", 28))
		and not bool(net_manager.call("_is_protocol_version_compatible", 27))
		and not bool(net_manager.call("_is_protocol_version_compatible", 26))
		and not bool(net_manager.call("_is_protocol_version_compatible", 25))
		and not bool(net_manager.call("_is_protocol_version_compatible", 24))
		and not bool(net_manager.call("_is_protocol_version_compatible", 23))
		and not bool(net_manager.call("_is_protocol_version_compatible", 22))
		and not bool(net_manager.call("_is_protocol_version_compatible", 21))
		and not bool(net_manager.call("_is_protocol_version_compatible", 20))
		and not bool(net_manager.call("_is_protocol_version_compatible", 16))
		and not bool(net_manager.call("_is_protocol_version_compatible", 15))
		and not bool(net_manager.call("_is_protocol_version_compatible", 14))
		and not bool(net_manager.call("_is_protocol_version_compatible", 13))
		and not bool(net_manager.call("_is_protocol_version_compatible", 12))
		and not bool(net_manager.call("_is_protocol_version_compatible", 11))
		and not bool(net_manager.call("_is_protocol_version_compatible", 10))
		and not bool(net_manager.call("_is_protocol_version_compatible", 9))
		and not bool(net_manager.call("_is_protocol_version_compatible", 8))
		and not bool(net_manager.call("_is_protocol_version_compatible", 7))
		and not bool(net_manager.call("_is_protocol_version_compatible", 6))
		and not bool(net_manager.call("_is_protocol_version_compatible", 5))
		and not bool(net_manager.call("_is_protocol_version_compatible", 4))
		and not bool(net_manager.call("_is_protocol_version_compatible", 3))
		and not bool(net_manager.call("_is_protocol_version_compatible", 2))
		and not bool(net_manager.call("_is_protocol_version_compatible", -1)),
		"Protocol v55 must reject v54 and all older or unversioned clients."
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
	_expect(
		bool(net_manager.call("_is_registration_open")),
		"A disconnected/lobby NetManager must keep registration open."
	)
	var join_rejection_reasons: Array[String] = []
	var join_rejection_callback := func(reason: String) -> void:
		join_rejection_reasons.append(reason)
	net_manager.connection_failed.connect(join_rejection_callback)
	net_manager.set("net_role", NetManagerStore.NetRole.CLIENT)
	net_manager.set("connection_state", NetManagerStore.ConnectionState.LOADING_GAME)
	_expect(
		not bool(net_manager.call("_is_registration_open")),
		"The frozen loading roster must reject late registrations."
	)
	net_manager.set("connection_state", NetManagerStore.ConnectionState.IN_GAME)
	_expect(
		not bool(net_manager.call("_is_registration_open")),
		"An active game must keep the room locked against late joins and reconnects."
	)
	net_manager.set("connection_state", NetManagerStore.ConnectionState.LOADING_GAME)
	net_manager.call("_rpc_join_rejected", "房间已经开始加载")
	net_manager.connection_failed.disconnect(join_rejection_callback)
	_expect(
		join_rejection_reasons == ["房间已经开始加载"]
		and not net_manager.is_multiplayer_active(),
		"A late-join rejection must explain the failure and fully disconnect the client."
	)


func _test_net_manager_game_mode_authority() -> void:
	var net_manager := root.get_node_or_null("NetManager")
	_expect(net_manager != null, "NetManager autoload is missing for game-mode coverage.")
	if net_manager == null:
		return

	net_manager.disconnect_from_game()
	var mode_events: Array[int] = []
	var mode_callback := func(game_mode: NetManagerStore.GameMode) -> void:
		mode_events.append(int(game_mode))
	net_manager.game_mode_changed.connect(mode_callback)
	_expect(
		net_manager.get_current_game_mode() == NetManagerStore.GameMode.STANDARD,
		"Disconnected NetManager must default to standard mode."
	)
	_expect(
		net_manager.set_host_game_mode(NetManagerStore.GameMode.TOWER_DEFENSE),
		"A disconnected future Host must be able to select tower-defense mode."
	)
	_expect(
		net_manager.get_current_game_mode() == NetManagerStore.GameMode.TOWER_DEFENSE,
		"Host game-mode selection must update authoritative state."
	)
	_expect(
		NetManagerStore.game_mode_to_key(NetManagerStore.GameMode.TOWER_DEFENSE)
		== "tower_defense",
		"Tower-defense mode must expose a stable API key."
	)
	_expect(
		int(NetManagerStore.GameMode.STANDARD) == 0
		and int(NetManagerStore.GameMode.TOWER_DEFENSE) == 1
		and int(NetManagerStore.GameMode.TEST_ARENA_P1) == 2
		and int(NetManagerStore.GameMode.TEST_ARENA_P2) == 3
		and int(NetManagerStore.GameMode.TEST_ARENA_P3) == 4
		and int(NetManagerStore.GameMode.TEST_ARENA_P1B) == 5,
		"P1B must append wire value 5 without renumbering existing game modes."
	)
	for mode_contract in [
		[NetManagerStore.GameMode.STANDARD, "standard", "普通模式"],
		[NetManagerStore.GameMode.TOWER_DEFENSE, "tower_defense", "塔防模式"],
		[NetManagerStore.GameMode.TEST_ARENA_P1, "test_arena_p1", "测试场景 P1A"],
		[NetManagerStore.GameMode.TEST_ARENA_P2, "test_arena_p2", "测试场景 P2"],
		[NetManagerStore.GameMode.TEST_ARENA_P3, "test_arena_p3", "测试场景 P3 · 肉鸽路线"],
		[NetManagerStore.GameMode.TEST_ARENA_P1B, "test_arena_p1b", "测试场景 P1B"],
	]:
		var mode := int(mode_contract[0]) as NetManagerStore.GameMode
		var key := str(mode_contract[1])
		_expect(
			NetManagerStore.game_mode_to_key(mode) == key
			and NetManagerStore.game_mode_from_key(key) == mode
			and NetManagerStore.get_game_mode_display_name(mode) == str(mode_contract[2]),
			"Every multiplayer mode must round-trip through its stable key and display name."
		)
	net_manager.set("net_role", NetManagerStore.NetRole.CLIENT)
	net_manager.set("connection_state", NetManagerStore.ConnectionState.CONNECTED_IN_LOBBY)
	_expect(
		not net_manager.set_host_game_mode(NetManagerStore.GameMode.STANDARD),
		"A connected client must not overwrite the Host-authoritative game mode."
	)
	_expect(
		net_manager.get_current_game_mode() == NetManagerStore.GameMode.TOWER_DEFENSE,
		"Rejected client mode edits must preserve the Host-selected mode."
	)
	net_manager.disconnect_from_game()
	net_manager.game_mode_changed.disconnect(mode_callback)
	_expect(
		net_manager.get_current_game_mode() == NetManagerStore.GameMode.STANDARD,
		"Disconnect must reset game mode to the backward-compatible standard default."
	)
	_expect(
		mode_events.has(NetManagerStore.GameMode.TOWER_DEFENSE)
		and mode_events.has(NetManagerStore.GameMode.STANDARD),
		"StandardGame-mode changes must emit both selection and reset events."
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
		1,
		NetManagerStore.GameMode.TEST_ARENA_P2,
		5
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
	_expect(
		net_manager.get_current_game_mode() == NetManagerStore.GameMode.TEST_ARENA_P2,
		"Reliable player-list sync must make clients follow the Host game mode."
	)
	_expect(
		net_manager.get_room_max_players() == 5,
		"Reliable player-list sync must make clients follow the Host room capacity."
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
	_expect(
		int(metrics.get("enemy_snapshot_payload_bytes_total", 0)) == 2900
		and int(metrics.get("enemy_snapshot_packet_count", 0)) == 2,
		"Snapshot metrics must accumulate enemy payload bytes and packet count."
	)
	mp_game.free()


func _test_enemy_snapshot_chunk_codec() -> void:
	const CHUNK_SIZE := 46
	const ENTITY_COUNT := 300
	const PACKET_BUDGET := 1200
	var sender := SnapshotManager.new()
	var receiver := SnapshotManager.new()
	var states: Array[SnapshotManager.EnemyState] = []
	var live_ids: Dictionary = {}
	for enemy_index in range(ENTITY_COUNT):
		var state := SnapshotManager.EnemyState.new()
		state.net_id = enemy_index + 1
		state.position = Vector2(enemy_index, enemy_index * 0.5)
		state.velocity = Vector2.RIGHT
		state.locomotion_state = SnapshotManager.ENEMY_LOCOMOTION_MOVING
		state.health = 100
		states.append(state)
		live_ids[state.net_id] = true

	var decoded_total := 0
	for chunk_start in range(0, states.size(), CHUNK_SIZE):
		var chunk_count := mini(CHUNK_SIZE, states.size() - chunk_start)
		var packet := sender.encode_enemy_snapshot_range_for_peer(
			77,
			states,
			chunk_start,
			chunk_count,
			true
		)
		_expect(
			packet.size() <= PACKET_BUDGET,
			"A full 46-enemy snapshot chunk must stay below the packet budget."
		)
		var decoded := receiver.decode_enemy_snapshots_with_baseline(packet, false)
		decoded_total += decoded.size()
		var expected_baseline_size := mini(chunk_start + CHUNK_SIZE, ENTITY_COUNT)
		var send_baseline := sender.enemy_send_baselines_by_peer.get(77, {}) as Dictionary
		_expect(
			send_baseline.size() == expected_baseline_size,
			"Encoding a chunk must retain every earlier chunk in the send baseline."
		)
		_expect(
			receiver.enemy_receive_baselines.size() == expected_baseline_size,
			"Decoding a chunk must retain every earlier chunk in the receive baseline."
		)
	sender.prune_enemy_send_baseline_to_ids(77, live_ids)
	receiver.prune_enemy_receive_baseline_to_ids(live_ids)
	_expect(decoded_total == ENTITY_COUNT, "All chunked keyframe enemies must decode exactly once.")

	for state in states:
		state.position += Vector2(1.0, 0.0)
	states[299].health = 73
	states[299].health_revision += 1
	decoded_total = 0
	var last_health := -1
	for chunk_start in range(0, states.size(), CHUNK_SIZE):
		var chunk_count := mini(CHUNK_SIZE, states.size() - chunk_start)
		var packet := sender.encode_enemy_snapshot_range_for_peer(
			77,
			states,
			chunk_start,
			chunk_count,
			false
		)
		_expect(
			packet.size() <= PACKET_BUDGET,
			"A moving 46-enemy delta chunk must stay below the packet budget."
		)
		var decoded := receiver.decode_enemy_snapshots_with_baseline(packet, false)
		decoded_total += decoded.size()
		for decoded_state in decoded:
			if decoded_state.net_id == 300:
				last_health = decoded_state.health
	sender.prune_enemy_send_baseline_to_ids(77, live_ids)
	receiver.prune_enemy_receive_baseline_to_ids(live_ids)
	_expect(
		decoded_total == ENTITY_COUNT and last_health == 73,
		"Chunked deltas must retain cross-chunk baselines and late-chunk health."
	)

	var reduced_live_ids: Dictionary = {}
	for net_id in range(1, 251):
		reduced_live_ids[net_id] = true
	sender.prune_enemy_send_baseline_to_ids(77, reduced_live_ids)
	receiver.prune_enemy_receive_baseline_to_ids(reduced_live_ids)
	var reduced_send_baseline := sender.enemy_send_baselines_by_peer.get(77, {}) as Dictionary
	_expect(
		reduced_send_baseline.size() == 250
		and receiver.enemy_receive_baselines.size() == 250,
		"Whole-batch pruning must remove stale send and receive baselines together."
	)


func _test_delta_snapshot_peer_cache_cleanup() -> void:
	var mp_game := MP_GAME_SCENE.instantiate()
	_expect(mp_game != null, "MpGame scene must instantiate for delta snapshot cache test.")
	if mp_game == null:
		return
	var player_coordinator := _bind_mp_game_coordinators(mp_game)
	var snapshot_mgr := (
		player_coordinator.get("_snapshot_manager") as SnapshotManager
	)
	_expect(
		snapshot_mgr != null,
		"PlayerCoordinator must own the player delta snapshot cache."
	)
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
	var cohort_peers: Dictionary = {}
	var keyframe_times: Dictionary = {}
	var ready_peers: Array[int] = [12]
	_expect(
		bool(mp_game.call(
			"_snapshot_cohort_requires_keyframe",
			cohort_peers,
			keyframe_times,
			ready_peers,
			0.0,
			0.5
		)),
		"A receiver outside the shared snapshot cohort must force a keyframe."
	)
	mp_game.call(
		"_commit_snapshot_cohort_send",
		cohort_peers,
		keyframe_times,
		ready_peers,
		0.0,
		true
	)
	_expect(
		not bool(mp_game.call(
			"_snapshot_cohort_requires_keyframe",
			cohort_peers,
			keyframe_times,
			ready_peers,
			0.25,
			0.5
		)),
		"A stable cohort must retain deltas before the periodic keyframe interval."
	)
	_expect(
		bool(mp_game.call(
			"_snapshot_cohort_requires_keyframe",
			cohort_peers,
			keyframe_times,
			ready_peers,
			0.5,
			0.5
		)),
		"A stable cohort must force a full snapshot at the 0.5 second boundary."
	)
	mp_game.free()


func _test_freed_pickup_index_cleanup() -> void:
	var game := StandardGame.new()
	_expect(game != null, "StandardGame object must instantiate for pickup index cleanup test.")
	if game == null:
		return
	var pickup := Pickup.new()
	_expect(pickup != null, "Pickup object must instantiate for pickup index cleanup test.")
	if pickup == null:
		game.free()
		return
	game.multiplayer_pickups[77] = pickup
	pickup.free()
	_expect(game.get_pickup_for_net_id(77) == null, "StandardGame must ignore freed pickup references by net id.")
	_expect(not game.multiplayer_pickups.has(77), "StandardGame must erase freed pickup references from the net id index.")
	game.free()


func _test_multiplayer_peer_disconnect_cleanup() -> void:
	var game := GAME_SCENE.instantiate() as StandardGame
	_expect(game != null, "StandardGame scene must instantiate for multiplayer peer cleanup test.")
	if game == null:
		return
	game.configure_multiplayer(1, 1, {1: "Host", 2: "Client", 3: "Third"})
	game.set("auto_start_waves", false)
	root.add_child(game)
	await process_frame
	_expect(game.peer_players.has(2), "StandardGame must create peer player 2 before cleanup.")
	var run_state := root.get_node_or_null("RunState") as RunStateStore
	if run_state != null:
		run_state.begin_new_run(&"weishidaier", false)
	var remote_player := game.peer_players.get(2) as PlayerWeishidaier
	if remote_player != null:
		remote_player.attack_damage = 37
		remote_player.apply_multiplayer_ammo_state(remote_player.get_ammo_capacity(), 2, false, 0.0)
	var parameter_mp_game := MP_GAME_SCENE.instantiate()
	_bind_multiplayer_runtime(parameter_mp_game, game)
	var parameter_projectile_coordinator := (
		parameter_mp_game.get_node("ProjectileCoordinator")
		as MpProjectileCoordinator
	)
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
	var peer_two_projectile_id := MpProjectileCoordinator.encode_projectile_id(
		2,
		1
	)
	var peer_three_projectile_id := MpProjectileCoordinator.encode_projectile_id(
		3,
		1
	)
	_expect(
		MpProjectileCoordinator.is_projectile_id_valid_for_owner(
			peer_two_projectile_id,
			2
		),
		"Projectile id namespace must match its owner peer."
	)
	_expect(
		not MpProjectileCoordinator.is_projectile_id_valid_for_owner(
			peer_three_projectile_id,
			2
		),
		"Projectile id namespace must reject another peer's id."
	)
	var valid_direction := MpProjectileCoordinator.get_valid_client_projectile_direction(
		Vector2(0.75, 0.0)
	)
	_expect(valid_direction.is_equal_approx(Vector2.RIGHT), "Client projectile direction must be normalized.")
	var invalid_direction := MpProjectileCoordinator.get_valid_client_projectile_direction(
		Vector2.ZERO
	)
	_expect(invalid_direction == Vector2.ZERO, "Client projectile direction must reject zero vectors.")
	var near_spawn := (
		remote_player.global_position
		+ Vector2.RIGHT
		* remote_player.get_multiplayer_projectile_spawn_distance(&"player_bullet")
	)
	var far_spawn := remote_player.global_position + Vector2(1024.0, 0.0)
	_expect(
		parameter_projectile_coordinator.is_client_projectile_spawn_position_allowed(
			&"player_bullet",
			2,
			near_spawn,
			null,
			MpGameScript.CLIENT_PROJECTILE_SPAWN_POSITION_TOLERANCE
		),
		"Host must accept client projectile spawns near the authoritative player."
	)
	_expect(
		not parameter_projectile_coordinator.is_client_projectile_spawn_position_allowed(
			&"player_bullet",
			2,
			far_spawn,
			null,
			MpGameScript.CLIENT_PROJECTILE_SPAWN_POSITION_TOLERANCE
		),
		"Host must reject client projectile spawns far from the authoritative player."
	)
	_expect(
		parameter_projectile_coordinator.get_authoritative_projectile_damage(
			peer_two_projectile_id,
			2,
			999
		) == 37,
		"Host must cap recordless projectile hit damage to the authoritative player attack."
	)
	_expect(
		parameter_projectile_coordinator.get_authoritative_projectile_damage(
			peer_three_projectile_id,
			2,
			999
		) == -1,
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
	_expect(not game.peer_players.has(2), "StandardGame must erase disconnected peer players.")
	_expect(not game.multiplayer_player_names.has(2), "StandardGame must erase disconnected peer names.")
	_expect(game.peer_players.has(1), "StandardGame must keep the local host player during peer cleanup.")
	_expect(remote_player == null or not is_instance_valid(remote_player), "StandardGame must free disconnected peer player nodes.")
	_stop_audio_players(game)
	game.queue_free()
	await process_frame
	await physics_frame

	var mp_game := MP_GAME_SCENE.instantiate()
	_expect(mp_game != null, "MpGame scene must instantiate for network peer cleanup test.")
	if mp_game == null:
		return
	var player_coordinator := _bind_mp_game_coordinators(mp_game)
	var projectile_coordinator := (
		mp_game.get_node("ProjectileCoordinator") as MpProjectileCoordinator
	)
	player_coordinator.reset_visual_interpolator_to_state(
		2, Vector2.ZERO, Vector2.ZERO, 0, 0, 0.0
	)
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
	var known_projectiles := (
		projectile_coordinator.get("_known_projectiles") as Dictionary
	)
	var cleanup_projectile_id := MpProjectileCoordinator.encode_projectile_id(
		2,
		1
	)
	known_projectiles[cleanup_projectile_id] = projectile
	projectile_coordinator.remember_projectile_record(
		cleanup_projectile_id,
		2,
		&"player_bullet",
		19,
		2.0,
		false,
		0.0
	)
	_expect(
		projectile_coordinator.get_authoritative_projectile_damage(
			cleanup_projectile_id,
			2,
			999
		) == 19,
		"MpGame must read projectile damage from host projectile records."
	)
	_expect(
		projectile_coordinator.get_authoritative_projectile_damage(
			cleanup_projectile_id,
			3,
			19
		) == -1,
		"MpGame must reject projectile damage records with the wrong owner."
	)

	mp_game.call("_clear_peer_network_state", 2)
	_expect(
		not player_coordinator.has_visual_interpolator(2),
		"MpGame must clear disconnected peer visual interpolators."
	)
	_expect(not sequence_cache.has(2), "MpGame must clear disconnected peer input sequence state.")
	_expect(not accepted_positions.has(2), "MpGame must clear disconnected peer accepted position state.")
	_expect(not accepted_times.has(2), "MpGame must clear disconnected peer accepted time state.")
	_expect(not health_revisions.has(2), "MpGame must clear disconnected peer health revisions.")
	_expect(not revive_times.has(2), "MpGame must clear disconnected peer revive timers.")
	_expect(not revive_seconds.has(2), "MpGame must clear disconnected peer revive countdown state.")
	_expect(not known_projectiles.has(cleanup_projectile_id), "MpGame must erase disconnected peer projectile indexes.")
	_expect(
		not projectile_coordinator.has_projectile_record(cleanup_projectile_id),
		"MpGame must erase disconnected peer projectile records."
	)
	await process_frame
	_expect(not is_instance_valid(projectile), "MpGame must free disconnected peer projectile nodes.")
	mp_game.free()
	await process_frame
	await physics_frame


func _test_player_snapshot_roster_reconcile() -> void:
	var game := GAME_SCENE.instantiate() as StandardGame
	_expect(game != null, "StandardGame scene must instantiate for player roster reconcile test.")
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
	_bind_multiplayer_runtime(mp_game, game)
	var projectile_coordinator := (
		mp_game.get_node("ProjectileCoordinator") as MpProjectileCoordinator
	)
	var player_coordinator := (
		mp_game.get_node("PlayerCoordinator") as MpPlayerCoordinator
	)
	player_coordinator.reset_visual_interpolator_to_state(
		3, Vector2.ZERO, Vector2.ZERO, 0, 0, 0.0
	)
	var sequence_cache := mp_game.get("_last_player_state_sequences") as Dictionary
	var health_revisions := mp_game.get("_player_health_revisions") as Dictionary
	sequence_cache[3] = 12
	health_revisions[3] = 4

	var projectile := Bullet.new()
	projectile.owner_peer_id = 3
	root.add_child(projectile)
	var known_projectiles := (
		projectile_coordinator.get("_known_projectiles") as Dictionary
	)
	var stale_projectile_id := MpProjectileCoordinator.encode_projectile_id(
		3,
		1
	)
	known_projectiles[stale_projectile_id] = projectile
	projectile_coordinator.remember_projectile_record(
		stale_projectile_id,
		3,
		&"player_bullet",
		21,
		2.0,
		false,
		0.0
	)

	mp_game.call(
		"_rpc_receive_player_snapshot",
		0.0,
		PackedByteArray()
	)
	_expect(game.peer_players.has(3), "Empty player roster snapshots must not remove peers.")
	var roster_states: Array[SnapshotManager.PlayerState] = []
	for player_state in game.collect_player_snapshot_states():
		if player_state != null and player_state.peer_id != 3:
			roster_states.append(player_state)
	var roster_sender := SnapshotManager.new()
	mp_game.call(
		"_rpc_receive_player_snapshot",
		0.0,
		roster_sender.encode_player_snapshots_for_peer(
			2,
			roster_states,
			true
		)
	)
	await process_frame
	_expect(not game.peer_players.has(3), "Client view must remove peers missing from a complete Host snapshot.")
	_expect(game.peer_players.has(2), "Client view roster reconcile must keep the local player.")
	_expect(game.peer_players.has(4), "Client view roster reconcile must keep peers still present in the Host snapshot.")
	_expect(
		not player_coordinator.has_visual_interpolator(3),
		"Roster reconcile must clear missing peer visual interpolators."
	)
	_expect(not sequence_cache.has(3), "Roster reconcile must clear missing peer input sequence state.")
	_expect(not health_revisions.has(3), "Roster reconcile must clear missing peer health revisions.")
	_expect(not known_projectiles.has(stale_projectile_id), "Roster reconcile must clear missing peer projectiles.")
	_expect(
		not projectile_coordinator.has_projectile_record(stale_projectile_id),
		"Roster reconcile must clear missing peer projectile records."
	)
	_expect(stale_player == null or not is_instance_valid(stale_player), "Roster reconcile must free missing peer player nodes.")
	_expect(not is_instance_valid(projectile), "Roster reconcile must free missing peer projectile nodes.")

	_stop_audio_players(game)
	mp_game.free()
	game.queue_free()
	await process_frame
	await physics_frame


func _test_enemy_snapshot_roster_requires_complete_batch() -> void:
	var game := GAME_SCENE.instantiate() as StandardGame
	_expect(game != null, "StandardGame scene must instantiate for enemy roster snapshot test.")
	if game == null:
		return
	game.configure_multiplayer(2, 2, {1: "Host", 2: "Client"})
	game.set("auto_start_waves", false)
	root.add_child(game)
	await process_frame

	var enemy_a := BASIC_CONFIG.enemy_scene.instantiate() as Enemy
	var enemy_b := BASIC_CONFIG.enemy_scene.instantiate() as Enemy
	var enemy_c := BASIC_CONFIG.enemy_scene.instantiate() as Enemy
	_expect(
		enemy_a != null and enemy_b != null and enemy_c != null,
		"Enemy roster snapshot test must instantiate enemies."
	)
	if enemy_a == null or enemy_b == null or enemy_c == null:
		if enemy_a != null:
			enemy_a.queue_free()
		if enemy_b != null:
			enemy_b.queue_free()
		if enemy_c != null:
			enemy_c.queue_free()
		_stop_audio_players(game)
		game.queue_free()
		await process_frame
		await physics_frame
		return
	game.enemy_container.add_child(enemy_a)
	game.enemy_container.add_child(enemy_b)
	game.enemy_container.add_child(enemy_c)

	var mp_game := MP_GAME_SCENE.instantiate()
	_expect(mp_game != null, "MpGame scene must instantiate for enemy roster snapshot test.")
	if mp_game == null:
		enemy_a.queue_free()
		enemy_b.queue_free()
		enemy_c.queue_free()
		_stop_audio_players(game)
		game.queue_free()
		await process_frame
		await physics_frame
		return
	_bind_multiplayer_runtime(mp_game, game)
	var net_enemies: Dictionary = mp_game.enemy_coordinator.net_enemies
	var enemy_spawn_times: Dictionary = mp_game.enemy_coordinator.enemy_spawn_snapshot_times
	net_enemies[7] = enemy_a
	net_enemies[8] = enemy_b
	net_enemies[9] = enemy_c
	enemy_spawn_times[7] = 0.0
	enemy_spawn_times[8] = 0.0
	enemy_spawn_times[9] = 0.0

	var snapshot_mgr := SnapshotManager.new()
	var state_a := SnapshotManager.EnemyState.new()
	state_a.net_id = 7
	state_a.position = Vector2(10.0, 20.0)
	state_a.velocity = Vector2.RIGHT * 0.01
	state_a.locomotion_state = SnapshotManager.ENEMY_LOCOMOTION_MOVING
	state_a.health = 12
	var state_b := SnapshotManager.EnemyState.new()
	state_b.net_id = 8
	state_b.position = Vector2(30.0, 40.0)
	state_b.velocity = Vector2.LEFT
	state_b.locomotion_state = SnapshotManager.ENEMY_LOCOMOTION_MOVING
	state_b.health = 11
	var state_c := SnapshotManager.EnemyState.new()
	state_c.net_id = 9
	state_c.position = Vector2(50.0, 60.0)
	state_c.velocity = Vector2.UP
	state_c.locomotion_state = SnapshotManager.ENEMY_LOCOMOTION_MOVING
	state_c.health = 10
	var first_chunk := snapshot_mgr.encode_all_enemy_snapshots([state_a])
	var second_chunk := snapshot_mgr.encode_all_enemy_snapshots([state_b, state_c])
	mp_game.call("_rpc_receive_enemy_snapshot", 0.0, first_chunk, 10, 0, 2)
	var state_a_frame := (
		(mp_game.enemy_coordinator.enemy_interpolators[7] as NetInterpolator).get_latest_state()
	)
	_expect(
		net_enemies.has(7)
		and net_enemies.has(8)
		and net_enemies.has(9)
		and state_a_frame.velocity == Vector2.ZERO
		and state_a_frame.anim_state == Enemy.LocomotionState.MOVING,
		"Incomplete chunks must retain the roster and preserve locomotion despite quantized zero velocity."
	)
	mp_game.call("_rpc_receive_enemy_snapshot", 0.0, second_chunk, 10, 1, 2)
	_expect(
		net_enemies.has(7) and net_enemies.has(8) and net_enemies.has(9),
		"A complete chunk batch must reconcile against the union of every chunk."
	)

	# Batch 11 loses its second chunk. Seeing a newer partial batch must not make
	# either incomplete roster authoritative.
	mp_game.call("_rpc_receive_enemy_snapshot", 1.0, first_chunk, 11, 0, 2)
	mp_game.call("_rpc_receive_enemy_snapshot", 2.0, first_chunk, 12, 0, 2)
	_expect(
		net_enemies.has(7) and net_enemies.has(8) and net_enemies.has(9),
		"A lost chunk must never reconcile either its batch or a newer partial batch."
	)

	# Completing batch 12 makes only its 7+8 union authoritative and retires every
	# older pending batch. A late chunk from batch 11 must then be ignored.
	var state_b_chunk := snapshot_mgr.encode_all_enemy_snapshots([state_b])
	mp_game.call("_rpc_receive_enemy_snapshot", 2.0, state_b_chunk, 12, 1, 2)
	await process_frame
	_expect(
		net_enemies.has(7) and net_enemies.has(8) and not net_enemies.has(9),
		"A complete newer batch must reconcile only against its own chunk union."
	)
	_expect(not is_instance_valid(enemy_c), "The complete newer batch must free stale enemy 9.")
	var empty_chunk := snapshot_mgr.encode_all_enemy_snapshots([])
	mp_game.call("_rpc_receive_enemy_snapshot", 1.0, empty_chunk, 11, 1, 2)
	_expect(
		net_enemies.has(7) and net_enemies.has(8),
		"A late chunk from an older batch must not re-run stale roster reconciliation."
	)
	var snapshot_metrics := mp_game.call("get_snapshot_packet_metrics") as Dictionary
	_expect(
		int(snapshot_metrics.get("enemy_snapshot_completed_batch_count", 0)) == 2
		and int(snapshot_metrics.get("enemy_snapshot_incomplete_batch_evict_count", 0)) == 1
		and int(snapshot_metrics.get("enemy_snapshot_stale_chunk_count", 0)) == 1,
		"Snapshot telemetry must classify completed, evicted incomplete, and stale chunks."
	)

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
	var game := GAME_SCENE.instantiate() as StandardGame
	_expect(game != null, "StandardGame scene must instantiate for enemy snapshot cleanup test.")
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
	_bind_multiplayer_runtime(mp_game, game)
	var net_enemies: Dictionary = mp_game.enemy_coordinator.net_enemies
	var enemy_spawn_times: Dictionary = mp_game.enemy_coordinator.enemy_spawn_snapshot_times
	net_enemies[21] = enemy_dead
	net_enemies[22] = enemy_stale
	enemy_spawn_times[21] = 0.0
	enemy_spawn_times[22] = 0.0
	mp_game.enemy_coordinator.enemy_interpolators[21] = NetInterpolator.new(0.1)
	mp_game.enemy_coordinator.enemy_interpolators[22] = NetInterpolator.new(0.1)

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
	_expect(
		not mp_game.enemy_coordinator.enemy_interpolators.has(21),
		"Dead enemy snapshots must clear interpolation state."
	)
	_expect(enemy_dead.is_dead, "Dead enemy snapshots must start the proxy death state.")

	mp_game.call(
		"_rpc_receive_enemy_snapshot",
		2.0,
		snapshot_mgr.encode_all_enemy_snapshots([]),
		30,
		0,
		1
	)
	await process_frame
	_expect(not net_enemies.has(22), "An empty chunked roster must reconcile stale enemies.")
	_expect(not enemy_spawn_times.has(22), "An empty chunked roster must erase stale spawn timing.")
	_expect(
		not mp_game.enemy_coordinator.enemy_interpolators.has(22),
		"An empty chunked roster must clear stale interpolation."
	)
	_expect(
		mp_game.snapshot_mgr.enemy_receive_baselines.is_empty(),
		"An empty chunked roster must prune the receive baseline only after completion."
	)

	mp_game.free()
	_stop_audio_players(game)
	game.queue_free()
	await process_frame
	await physics_frame


func _test_host_remote_player_position_writeback() -> void:
	var host_game := GAME_SCENE.instantiate() as StandardGame
	_expect(host_game != null, "StandardGame scene must instantiate for remote player writeback test.")
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
		_bind_multiplayer_runtime(mp_game, host_game)
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
			not (
				mp_game.get_node("PlayerCoordinator") as MpPlayerCoordinator
			).has_visual_interpolator(2),
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
	var game := GAME_SCENE.instantiate() as StandardGame
	_expect(game != null, "StandardGame scene must instantiate for projectile compensation.")
	if game == null:
		return
	game.configure_multiplayer(
		CombatRuntimeBase.RuntimeMode.CLIENT_VIEW,
		2,
		{1: "Host", 2: "Client"}
	)
	game.auto_start_waves = false
	root.add_child(game)
	await process_frame
	var mp_game := MP_GAME_SCENE.instantiate()
	_expect(mp_game != null, "MpGame scene must instantiate for projectile compensation test.")
	if mp_game == null:
		_stop_audio_players(game)
		game.queue_free()
		await process_frame
		return
	_bind_multiplayer_runtime(mp_game, game)
	var projectile_coordinator := (
		mp_game.get_node("ProjectileCoordinator") as MpProjectileCoordinator
	)
	var now_origin := Time.get_ticks_msec() / 1000.0 - 10.0
	mp_game.set("_net_time_origin", now_origin)
	mp_game.set("_has_host_time_offset", true)
	mp_game.set("_host_to_client_time_offset", 0.0)
	var now := float(mp_game.call("_get_net_time"))
	var spawn_position := Vector2(10.0, 20.0)
	var direction := Vector2.RIGHT
	var speed := 100.0
	var lifetime := 2.0
	var projectile_id := MpProjectileCoordinator.encode_projectile_id(2, 1)
	projectile_coordinator.receive_projectile_fired(
		projectile_id,
		&"player_bullet",
		2,
		spawn_position,
		direction,
		7,
		speed,
		lifetime,
		false,
		0,
		0,
		0.12,
		now
	)
	var projectile := projectile_coordinator.get_projectile(projectile_id) as Bullet
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
	var expired_projectile_id := MpProjectileCoordinator.encode_projectile_id(
		2,
		2
	)
	projectile_coordinator.receive_projectile_fired(
		expired_projectile_id,
		&"player_bullet",
		2,
		spawn_position,
		direction,
		7,
		320.0,
		0.1,
		false,
		0,
		0,
		0.1,
		now
	)
	_expect(
		not projectile_coordinator.has_projectile(expired_projectile_id),
		"A view-bounded player projectile that expired in transit must not gain a 0.05s visual extension."
	)
	_expect(
		projectile_coordinator.has_projectile_record(expired_projectile_id),
		"An in-transit expiry must retain its multiplayer de-duplication record."
	)
	mp_game.free()
	_stop_audio_players(game)
	game.queue_free()
	await process_frame
	await physics_frame


func _test_enemy_action_uses_snapshot_timeline() -> void:
	var client_game := GAME_SCENE.instantiate() as StandardGame
	_expect(client_game != null, "StandardGame scene must instantiate for enemy action timeline test.")
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
		_bind_multiplayer_runtime(mp_game, client_game)
		var net_manager := root.get_node_or_null("NetManager")
		if net_manager != null:
			mp_game.set("net_manager", net_manager)
		mp_game.set("_net_time_origin", Time.get_ticks_msec() / 1000.0 - 10.0)
		mp_game.set("_has_host_time_offset", true)
		mp_game.set("_host_to_client_time_offset", 0.0)
		var net_enemies: Dictionary = mp_game.enemy_coordinator.net_enemies
		net_enemies[42] = enemy
		var interp := NetInterpolator.new(0.05, 0.0)
		interp.push_snapshot(
			9.5,
			Vector2(5.0, 5.0),
			Vector2.ZERO,
			0,
			Enemy.LocomotionState.MOVING
		)
		mp_game.enemy_coordinator.enemy_interpolators[42] = interp
		mp_game.call("net_enemy_action", 42, "windup", Vector2.RIGHT, Vector2(100.0, 100.0), 1, 9.0)
		_expect(
			enemy.global_position.is_equal_approx(Vector2(5.0, 5.0)),
			"Stale enemy action events must not pull proxy position off the snapshot timeline."
		)
		if sprite != null:
			_expect(
				sprite.animation == KNIGHT_CONFIG.windup_animation_name
				and int(enemy.get("latest_proxy_action_id")) == 1,
				"A transform-stale enemy action must leave snapshot position untouched while its newer action id still advances proxy visuals."
			)
		mp_game.call("net_enemy_action", 42, "windup", Vector2.RIGHT, Vector2(20.0, 5.0), 2, 10.0)
		var latest_timestamp := (
			mp_game.enemy_coordinator.enemy_interpolators[42] as NetInterpolator
		).get_latest_timestamp()
		_expect(
			is_equal_approx(latest_timestamp, 10.0),
			"Fresh enemy action events must enter the enemy interpolation timeline."
		)
		var latest_action_state := (
			(mp_game.enemy_coordinator.enemy_interpolators[42] as NetInterpolator).get_latest_state()
		)
		_expect(
			latest_action_state.velocity == Vector2.ZERO
			and latest_action_state.anim_state == Enemy.LocomotionState.MOVING,
			"Position-only action samples must suppress extrapolation without overwriting locomotion."
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
			mp_game.enemy_coordinator.enemy_interpolators[43] = sniper_interp
			var aim_glow := sniper.get_node_or_null("AimGlow") as Polygon2D
			var net_enemies_for_target_action: Dictionary = (
				mp_game.enemy_coordinator.net_enemies
			)
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
				sniper.lock_reticle != null
				and aim_glow != null
				and aim_glow.visible
				and sniper.latest_proxy_target_action_id == 1,
				"A transform-stale enemy target action must leave snapshot position untouched while its newer action id still advances target-lock visuals."
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
			linglan.setup(
				boss_enemy_config,
				client_game.player,
				client_game.grid_pathfinder,
				client_game,
				client_game.linglan_boss_runtime_port
			)
			linglan.configure_multiplayer_proxy()
			linglan.set_meta("net_id", 44)
			linglan.global_position = Vector2(18.0, 18.0)
			var linglan_interp := NetInterpolator.new(0.05, 0.0)
			linglan_interp.push_snapshot(9.5, linglan.global_position, Vector2.ZERO)
			mp_game.enemy_coordinator.enemy_interpolators[44] = linglan_interp
			var net_enemies_for_linglan_action: Dictionary = (
				mp_game.enemy_coordinator.net_enemies
			)
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
	var game := GAME_SCENE.instantiate() as StandardGame
	_expect(game != null, "StandardGame scene must instantiate for remote form buff test.")
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
		_bind_multiplayer_runtime(mp_game, game)
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
	var game := GAME_SCENE.instantiate() as StandardGame
	_expect(game != null, "StandardGame scene must instantiate for four-player smoke test.")
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
	_bind_multiplayer_runtime(mp_game, game)
	var net_manager := root.get_node_or_null("NetManager")
	if net_manager != null:
		mp_game.set("net_manager", net_manager)
	var run_state := root.get_node_or_null("RunState")
	if run_state != null:
		var typed_run_state := run_state as RunStateStore
		typed_run_state.begin_new_run()
		for starting_peer_id in [1, 2, 3, 4]:
			typed_run_state.ensure_multiplayer_peer_state(starting_peer_id)
			_expect(
				typed_run_state.get_item_for_peer(starting_peer_id, 0)
				== WOOD_MATERIAL
				and typed_run_state.get_item_count_for_peer(starting_peer_id, 0)
				== RunStateStore.STARTING_WOOD_COUNT
				and typed_run_state.get_inventory_revision_for_peer(starting_peer_id) == 0,
				"Every multiplayer peer must start with five wood at revision zero."
			)
		var starting_snapshot := typed_run_state.export_inventory_snapshot_for_peer(2)
		var snapshot_client := RunStateStore.new()
		root.add_child(snapshot_client)
		snapshot_client.begin_new_run()
		_expect(
			snapshot_client.apply_inventory_snapshot_for_peer(2, starting_snapshot)
			and snapshot_client.apply_inventory_snapshot_for_peer(2, starting_snapshot)
			and snapshot_client.get_item_count_for_peer(2, 0)
			== RunStateStore.STARTING_WOOD_COUNT,
			"Replaying the initial peer snapshot must not duplicate starting wood."
		)
		snapshot_client.free()
		typed_run_state.begin_new_run(&"weishidaier", false)
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
		var previous_net_role := (
			int(net_manager.get("net_role"))
			if net_manager != null
			else 0
		)
		if net_manager != null and typed_run_state != null:
			net_manager.set("net_role", NetManagerStore.NetRole.HOST)
			_expect(
				typed_run_state.try_add_item_count_for_peer(
					4,
					SAPLING_MATERIAL,
					1
				)
				and typed_run_state.try_add_item_count_for_peer(
					4,
					WATER_BOTTLE_MATERIAL,
					1
				),
				"Host简易制造测试必须能为目标Peer准备背包材料。"
			)
			var crafting_revision := (
				typed_run_state.get_inventory_revision_for_peer(4)
			)
			mp_game.call(
				"_apply_authoritative_simple_crafting_request",
				4,
				101,
				String(SimpleCraftingRegistry.HERBAL_HEALTH_POTION_ID),
				crafting_revision
			)
			var committed_revision := (
				typed_run_state.get_inventory_revision_for_peer(4)
			)
			_expect(
				typed_run_state.get_inventory_item_total_for_peer(
					4,
					SAPLING_MATERIAL
				) == 0
				and typed_run_state.get_inventory_item_total_for_peer(
					4,
					WATER_BOTTLE_MATERIAL
				) == 0
				and typed_run_state.get_inventory_item_total_for_peer(
					4,
					HEALTH_PICKUP
				) == 1
				and committed_revision == crafting_revision + 1,
				"Host必须只为请求Peer原子扣料、发放产物并推进一次revision。"
			)
			mp_game.call(
				"_apply_authoritative_simple_crafting_request",
				4,
				101,
				String(SimpleCraftingRegistry.HERBAL_HEALTH_POTION_ID),
				crafting_revision
			)
			_expect(
				typed_run_state.get_inventory_revision_for_peer(4)
				== committed_revision
				and typed_run_state.get_inventory_item_total_for_peer(
					4,
					HEALTH_PICKUP
				) == 1,
				"重复的简易制造request_id必须命中幂等缓存，不能重复产出。"
			)
			mp_game.call(
				"_apply_authoritative_simple_crafting_request",
				4,
				102,
				String(SimpleCraftingRegistry.HERBAL_HEALTH_POTION_ID),
				crafting_revision
			)
			var crafting_cache := (
				mp_game.get("_simple_crafting_results_by_peer") as Dictionary
			)
			var peer_crafting_cache := (
				crafting_cache.get(4, {}) as Dictionary
			)
			var stale_result := (
				peer_crafting_cache.get(102, {}) as Dictionary
			)
			_expect(
				typed_run_state.get_inventory_revision_for_peer(4)
				== committed_revision
				and str(stale_result.get("result", ""))
				== String(RunStateStore.CRAFT_RESULT_STALE_REVISION)
				and bool(stale_result.get("force_inventory_repair", false)),
				"Host必须拒绝过期revision，并缓存带强制背包修复标记的结果。"
			)
			_expect(
				typed_run_state.discard_item_for_peer(4, 0),
				"Host简易制造测试结束后必须清理目标Peer的测试产物。"
			)
			var revision_after_cleanup := (
				typed_run_state.get_inventory_revision_for_peer(4)
			)
			mp_game.call(
				"_apply_authoritative_simple_crafting_request",
				4,
				102,
				String(SimpleCraftingRegistry.HERBAL_HEALTH_POTION_ID),
				crafting_revision
			)
			peer_crafting_cache = (
				(mp_game.get(
					"_simple_crafting_results_by_peer"
				) as Dictionary).get(4, {}) as Dictionary
			)
			stale_result = (
				peer_crafting_cache.get(102, {}) as Dictionary
			)
			var replay_snapshot := (
				stale_result.get("inventory_snapshot", {}) as Dictionary
			)
			_expect(
				int(replay_snapshot.get("revision", -1))
				== revision_after_cleanup,
				"重放缓存的过期请求必须改用Host当前快照，不能携带旧revision回退背包。"
			)
			net_manager.set("net_role", previous_net_role)

	var peer_four := game.get_player_for_peer(4) as Player
	_expect(peer_four != null, "Peer 4 must exist for confirmed event test.")
	if peer_four != null:
		var health_revisions := mp_game.get("_player_health_revisions") as Dictionary
		mp_game.call(
			"net_player_damage_applied",
			99,
			0,
			true,
			8,
			0,
			Vector2.ZERO,
			EnemyConfig.DamageType.PHYSICAL
		)
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
		_expect(peer_four.has_skill1(), "Skill1 state confirm must preserve the selected peer's starting skill.")
		_expect(peer_four.current_xirang == 25, "Skill1 state confirm must update xirang.")
		peer_four.current_xirang = 225
		var skill1_duration_before_upgrade := peer_four.skill1_charge_duration
		var skill1_upgrade_result := game.try_purchase_skill1_for_peer(4)
		_expect(
			skill1_upgrade_result == MerchantPurchaseResult.SkillUpgrade.UPGRADE_SUCCESS,
			"Owned skill1 transaction must upgrade skill1 on host."
		)
		_expect(peer_four.current_xirang == 25, "Skill1 upgrade must deduct the first 200 xirang cost.")
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
			MerchantPurchaseResult.SkillUpgrade.UPGRADE_SUCCESS,
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
				game.try_refresh_luoxi_collectibles_for_peer(4) == MerchantPurchaseResult.OfferRefresh.SUCCESS,
				"Luoxi host-authoritative refresh %d must succeed." % refresh_index
			)
			expected_refresh_xirang -= refresh_cost
			_expect(peer_four.current_xirang == expected_refresh_xirang, "Luoxi refresh must deduct its authoritative xirang cost.")
		_expect(game.get_luoxi_collectible_refresh_count(4) == 4, "Luoxi must track four refreshes per peer and intermission.")
		_expect(
			game.try_refresh_luoxi_collectibles_for_peer(4) == MerchantPurchaseResult.OfferRefresh.LIMIT_REACHED,
			"Luoxi must reject a fifth refresh without spending xirang."
		)
		var luoxi_claim_result := game.try_claim_luoxi_collectible_for_peer(4, APPLE_COLLECTIBLE.resource_path)
		_expect(
			luoxi_claim_result == MerchantPurchaseResult.CollectibleClaim.SUCCESS,
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
			game.try_claim_luoxi_collectible_for_peer(4, APPLE_COLLECTIBLE.resource_path) == MerchantPurchaseResult.CollectibleClaim.ALREADY_CLAIMED,
			"Luoxi must reject a second collectible choice in the same intermission."
		)
		for _slot_index in range(RunStateStore.INVENTORY_CAPACITY):
			_expect(run_state.try_add_item_for_peer(2, APPLE_COLLECTIBLE), "Peer 2 inventory must fill with non-stackable apples before testing Luoxi's full bag result.")
		var full_luoxi_claim_result := game.try_claim_luoxi_collectible_for_peer(2, APPLE_COLLECTIBLE.resource_path)
		_expect(
			full_luoxi_claim_result == MerchantPurchaseResult.CollectibleClaim.INVENTORY_FULL,
			"Luoxi must reject collectible claims when the selected peer inventory is full."
		)
		_expect(
			not game.has_luoxi_collectible_claimed(2),
			"A full peer inventory must not spend Luoxi's collectible choices."
		)
		_expect(run_state.discard_item_for_peer(2, 0), "Peer 2 must be able to free one inventory slot after a full Luoxi claim.")
		_expect(
			game.try_claim_luoxi_collectible_for_peer(2, APPLE_COLLECTIBLE.resource_path) == MerchantPurchaseResult.CollectibleClaim.SUCCESS,
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
		_expect(
			run_state.try_add_item_for_peer(4, HEALTH_PICKUP),
			"Peer 4 health pickup must fit for inventory revision conflict testing."
		)
		var peer_four_inventory_revision: int = (
			run_state.get_inventory_revision_for_peer(4)
		)
		mp_game.call(
			"_apply_inventory_item_discard_for_peer",
			4,
			0,
			peer_four_inventory_revision - 1
		)
		_expect(
			run_state.get_item_for_peer(4, 0) == HEALTH_PICKUP
			and run_state.get_inventory_revision_for_peer(4) == peer_four_inventory_revision,
			"Host must reject stale inventory commands without mutating the authoritative slot."
		)
		mp_game.call(
			"_apply_inventory_item_discard_for_peer",
			4,
			0,
			peer_four_inventory_revision
		)
		_expect(
			run_state.get_item_for_peer(4, 0) == null,
			"Host must accept the same inventory command when its expected revision matches."
		)
		peer_four.skill1_charge_duration = 1.0
		peer_four.skill1_charge = 0.0
		game.call("_update_multiplayer_remote_player_passive_state", 0.5)
		_expect(peer_four.skill1_charge > 0.0, "Host passive tick must charge remote players' skill1.")
		mp_game.call(
			"net_player_damage_applied",
			4,
			0,
			true,
			2,
			peer_four.current_health,
			Vector2.LEFT,
			EnemyConfig.DamageType.PHYSICAL
		)
		_expect(peer_four.is_dead, "Damage confirm must put the selected peer into death state.")
		mp_game.call(
			"net_player_damage_applied",
			4,
			peer_four.max_health,
			false,
			1,
			0,
			Vector2.ZERO,
			EnemyConfig.DamageType.PHYSICAL
		)
		_expect(peer_four.is_dead, "Stale damage revisions must be ignored.")
		mp_game.call("net_player_revived", 4, Vector2(32.0, 48.0), peer_four.max_health, 1.25, 3)
		_expect(not peer_four.is_dead, "Revive confirm must clear the selected peer death state.")
		_expect(peer_four.global_position == Vector2(32.0, 48.0), "Revive confirm must move the selected peer.")

	var peer_two := game.get_player_for_peer(2) as Player
	var peer_three := game.get_player_for_peer(3) as Player
	if peer_two != null and peer_three != null:
		var xirang_before_by_peer: Dictionary = {}
		for peer_id in [1, 2, 3, 4]:
			var initial_reward_player := game.get_player_for_peer(peer_id) as Player
			if initial_reward_player != null:
				initial_reward_player.xirang_pickup_audio.stop()
				xirang_before_by_peer[peer_id] = initial_reward_player.current_xirang
		peer_two.is_dead = true
		_expect(
			game.grant_xirang_kill_reward(BASIC_CONFIG.xirang_kill_reward),
			"Host runtime must accept a configured positive Xirang kill reward."
		)
		await process_frame
		for peer_id in [1, 2, 3, 4]:
			var settled_reward_player := game.get_player_for_peer(peer_id) as Player
			_expect(
				settled_reward_player != null
				and settled_reward_player.current_xirang
				== int(xirang_before_by_peer.get(peer_id, 0))
				+ BASIC_CONFIG.xirang_kill_reward,
				"A multiplayer enemy kill reward must settle for peer %d by frame end."
				% peer_id
			)
			_expect(
				settled_reward_player != null
				and not settled_reward_player.xirang_pickup_audio.playing,
				"A direct enemy kill reward must not imitate an absorbed Xirang orb."
			)
		peer_two.is_dead = false
		_expect(run_state.try_add_item_for_peer(3, HEALTH_PICKUP), "Peer 3 health pickup must fit for inventory use confirmation testing.")
		peer_three.current_health = maxi(peer_three.max_health - HEALTH_PICKUP.heal_amount, 1)
		var inventory_before_missing_use: Dictionary = (
			run_state.export_inventory_snapshot_for_peer(3)
		)
		var health_before_missing_use := peer_three.current_health
		mp_game.call(
			"net_inventory_item_used",
			3,
			0,
			HEALTH_PICKUP.resource_path,
			true,
			{}
		)
		_expect(
			run_state.export_inventory_snapshot_for_peer(3) == inventory_before_missing_use
			and peer_three.current_health == health_before_missing_use,
			"Inventory use confirmations missing an authoritative snapshot must not mutate inventory or apply an item effect."
		)
		_expect(
			run_state.discard_item_for_peer(3, 0),
			"Missing-use-snapshot coverage must clean up its inventory fixture."
		)
		_expect(run_state.try_add_item_for_peer(3, APPLE_COLLECTIBLE), "Peer 3 apple must fit for inventory discard confirmation testing.")
		var inventory_before_missing_discard: Dictionary = (
			run_state.export_inventory_snapshot_for_peer(3)
		)
		mp_game.call("net_inventory_item_discarded", 3, 0, true, {})
		_expect(
			run_state.export_inventory_snapshot_for_peer(3) == inventory_before_missing_discard,
			"Inventory discard confirmations missing an authoritative snapshot must not mutate inventory."
		)
		_expect(
			run_state.discard_item_for_peer(3, 0),
			"Missing-discard-snapshot coverage must clean up its inventory fixture."
		)
		_expect(
			run_state.try_add_item_count_for_peer(3, WOOD_MATERIAL, 3),
			"Peer 3 stacked material must fit for authoritative inventory snapshot testing."
		)
		var stacked_inventory_snapshot: Dictionary = (
			run_state.export_inventory_snapshot_for_peer(3)
		)
		stacked_inventory_snapshot["revision"] = (
			run_state.get_inventory_revision_for_peer(3) + 1
		)
		var stacked_slots := stacked_inventory_snapshot.get("slots", []) as Array
		var first_stacked_slot := stacked_slots[0] as Dictionary
		first_stacked_slot["stack_count"] = 2
		for stacked_slot_value in stacked_slots:
			var stacked_slot := stacked_slot_value as Dictionary
			stacked_slot["revision"] = int(
				stacked_inventory_snapshot["revision"]
			)
		mp_game.call(
			"net_inventory_item_used",
			3,
			0,
			"",
			true,
			stacked_inventory_snapshot
		)
		_expect(
			run_state.get_item_count_for_peer(3, 0) == 2,
			"Authoritative inventory use confirmation must preserve the remainder of a stack."
		)
		var stale_host_repair_snapshot: Dictionary = (
			run_state.export_inventory_snapshot_for_peer(3)
		)
		var settlement_inventory_snapshot := (
			stale_host_repair_snapshot.duplicate(true) as Dictionary
		)
		settlement_inventory_snapshot["revision"] = (
			int(stale_host_repair_snapshot.get("revision", -1)) + 1
		)
		var settlement_slots := (
			settlement_inventory_snapshot.get("slots", []) as Array
		)
		for settlement_slot_value in settlement_slots:
			var settlement_slot := settlement_slot_value as Dictionary
			settlement_slot["revision"] = int(
				settlement_inventory_snapshot["revision"]
			)
		var settlement_first_slot := settlement_slots[0] as Dictionary
		settlement_first_slot["stack_count"] = 3
		_expect(
			run_state.apply_inventory_snapshot_for_peer(
				3,
				settlement_inventory_snapshot,
				true
			),
			"The CH0 settlement fixture must commit revision R+1 before the delayed repair."
		)
		mp_game.call(
			"net_inventory_item_discarded",
			3,
			0,
			false,
			stale_host_repair_snapshot,
			true
		)
		_expect(
			run_state.get_item_count_for_peer(3, 0) == 3
			and run_state.get_inventory_revision_for_peer(3)
			== int(settlement_inventory_snapshot.get("revision", -1)),
			"A delayed forced CH6 repair at revision R must not rewind the already-applied CH0 settlement at R+1."
		)
		var inventory_before_second_missing_discard: Dictionary = (
			run_state.export_inventory_snapshot_for_peer(3)
		)
		mp_game.call("net_inventory_item_discarded", 3, 0, true, {})
		_expect(
			run_state.export_inventory_snapshot_for_peer(3)
			== inventory_before_second_missing_discard,
			"A successful discard confirmation without an authoritative snapshot must leave inventory unchanged."
		)
		_expect(
			run_state.discard_item_for_peer(3, 0),
			"Second missing-discard-snapshot coverage must clean up its inventory fixture."
		)
		var peer_inventories := run_state.get("multiplayer_inventories") as Dictionary
		mp_game.call(
			"net_inventory_item_used",
			99,
			0,
			HEALTH_PICKUP.resource_path,
			true,
			{}
		)
		mp_game.call("net_inventory_item_discarded", 99, 0, true, {})
		_expect(not peer_inventories.has(99), "Inventory confirms for missing peers must not create peer run state.")
		var bound_mode_adapter: MultiplayerModeAdapter = mp_game._mode_adapter
		var inventory_before_unbound_confirm: Dictionary = (
			run_state.export_inventory_snapshot_for_peer(3)
		)
		mp_game._mode_adapter = null
		mp_game.call(
			"net_luoxi_collectible_confirmed",
			3,
			0,
			APPLE_COLLECTIBLE.resource_path,
			MerchantPurchaseResult.CollectibleClaim.SUCCESS
		)
		_expect(
			run_state.export_inventory_snapshot_for_peer(3)
			== inventory_before_unbound_confirm,
			"Luoxi confirmation must fail closed while the typed mode adapter is unavailable."
		)
		mp_game._mode_adapter = bound_mode_adapter
		mp_game.call(
			"net_luoxi_collectible_confirmed",
			3,
			0,
			APPLE_COLLECTIBLE.resource_path,
			MerchantPurchaseResult.CollectibleClaim.SUCCESS
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
	var game := GAME_SCENE.instantiate() as StandardGame
	_expect(game != null, "StandardGame must instantiate for multiplayer character registry test.")
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
	var local_hoe_player := local_player as PlayerHoeCat
	var tiyi_player := game.get_player_for_peer(3) as PlayerTiyi
	_expect(
		host_player != null and host_player.get_character_id() == &"weishidaier",
		"StandardGame must instantiate the registered Weishidaier scene for the host peer."
	)
	_expect(
		local_player != null and local_player.get_character_id() == &"hoe_cat",
		"StandardGame must instantiate the registered Hoe Cat scene for the client peer."
	)
	_expect(
		tiyi_player != null and tiyi_player.get_character_id() == &"tiyi",
		"StandardGame must instantiate the registered Tiyi scene for a standard multiplayer peer."
	)
	if tiyi_player != null:
		var mp_game := MP_GAME_SCENE.instantiate()
		_bind_multiplayer_runtime(mp_game, game)
		var weishidaier_player := host_player as AmmoRangedPlayer
		if weishidaier_player != null:
			var weishidaier_ammo_before := weishidaier_player.current_ammo
			var bullet_parameters := mp_game.call(
				"_get_authoritative_client_projectile_parameters",
				&"player_bullet",
				1
			) as Dictionary
			_expect(
				is_equal_approx(float(bullet_parameters.get("speed", 0.0)), 320.0)
				and is_equal_approx(
					float(bullet_parameters.get("lifetime", 0.0)),
					1.083
				),
				"Host must rebuild Weishidaier bullets with the shared view-bounded envelope."
			)
			_expect(
				weishidaier_player.current_ammo == weishidaier_ammo_before - 1,
				"Host view-bounded bullet validation must consume exactly one round."
			)
			weishidaier_player.shooting_timer.stop()
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
			and is_equal_approx(float(sniper_parameters.get("lifetime", 0.0)), 0.181),
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
	if local_hoe_player != null:
		var remote_orbit := local_hoe_player.get_node(
			"SnowWolfSwordOrbit"
		) as HoeCatSnowWolfSwordOrbit
		var remote_shape_a := remote_orbit.get_node("SwordAShape") as CollisionShape2D
		var remote_shape_b := remote_orbit.get_node("SwordBShape") as CollisionShape2D
		var remote_shape_c := remote_orbit.get_node("SwordCShape") as CollisionShape2D
		var remote_shape_d := remote_orbit.get_node("SwordDShape") as CollisionShape2D
		local_hoe_player.apply_multiplayer_realtime_state(
			local_hoe_player.current_health,
			local_hoe_player.max_health,
			local_hoe_player.current_xirang,
			false,
			0.0,
			local_hoe_player.skill1_unlocked,
			local_hoe_player.skill1_charge,
			local_hoe_player.skill1_charge_duration,
			PickupConfig.PlayerFormMode.ARMED,
			PickupConfig.ShotPattern.NORMAL,
			local_hoe_player.skill1_upgrade_level
		)
		_expect(
			remote_orbit.is_active()
			and remote_orbit.visible
			and not remote_orbit.monitoring
			and remote_shape_a.disabled
			and remote_shape_b.disabled
			and remote_shape_c.disabled
			and remote_shape_d.disabled,
			"A client Hoe Cat ARMED/NORMAL snapshot must show visual-only orbit swords."
		)
		remote_orbit.duration_left = 2.5
		local_hoe_player.apply_multiplayer_realtime_state(
			local_hoe_player.current_health,
			local_hoe_player.max_health,
			local_hoe_player.current_xirang,
			false,
			0.0,
			local_hoe_player.skill1_unlocked,
			local_hoe_player.skill1_charge,
			local_hoe_player.skill1_charge_duration,
			PickupConfig.PlayerFormMode.ARMED,
			PickupConfig.ShotPattern.NORMAL,
			local_hoe_player.skill1_upgrade_level
		)
		_expect(
			is_equal_approx(remote_orbit.duration_left, 2.5),
			"Repeated Hoe Cat ARMED/NORMAL snapshots must not restart the client timer."
		)
		local_hoe_player.apply_multiplayer_realtime_state(
			local_hoe_player.current_health,
			local_hoe_player.max_health,
			local_hoe_player.current_xirang,
			false,
			0.0,
			local_hoe_player.skill1_unlocked,
			local_hoe_player.skill1_charge,
			local_hoe_player.skill1_charge_duration,
			PickupConfig.PlayerFormMode.NORMAL,
			PickupConfig.ShotPattern.NORMAL,
			local_hoe_player.skill1_upgrade_level
		)
		_expect(
			not remote_orbit.is_active() and not remote_orbit.visible,
			"A client Hoe Cat NORMAL snapshot must clear the orbit swords."
		)
		local_hoe_player.death_audio.stream = null
		local_hoe_player.apply_multiplayer_realtime_state(
			0,
			local_hoe_player.max_health,
			local_hoe_player.current_xirang,
			true,
			0.0,
			local_hoe_player.skill1_unlocked,
			local_hoe_player.skill1_charge,
			local_hoe_player.skill1_charge_duration,
			PickupConfig.PlayerFormMode.ARMED,
			PickupConfig.ShotPattern.NORMAL,
			local_hoe_player.skill1_upgrade_level
		)
		_expect(
			not remote_orbit.is_active()
			and not remote_orbit.visible
			and not remote_orbit.monitoring,
			"A dead client Hoe Cat must not retain swords reopened by the same snapshot."
		)
	_expect(
		game.player == local_player,
		"StandardGame.player must reference the local peer even when the host sorts first."
	)
	_stop_audio_players(game)
	game.queue_free()
	await process_frame


func _test_host_authoritative_hoe_actions() -> void:
	var host_game := GAME_SCENE.instantiate() as StandardGame
	_expect(host_game != null, "StandardGame must instantiate for authoritative Hoe Cat action coverage.")
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
	_bind_multiplayer_runtime(mp_game, host_game)
	mp_game.set("net_manager", net_manager)
	var host_orbit := hoe_player.get_node(
		"SnowWolfSwordOrbit"
	) as HoeCatSnowWolfSwordOrbit
	var host_shape_a := host_orbit.get_node("SwordAShape") as CollisionShape2D
	var host_shape_b := host_orbit.get_node("SwordBShape") as CollisionShape2D
	var host_shape_c := host_orbit.get_node("SwordCShape") as CollisionShape2D
	var host_shape_d := host_orbit.get_node("SwordDShape") as CollisionShape2D
	_expect(
		hoe_player.apply_pickup(PICKUP_SPIRAL_CONFIG),
		"Host Hoe Cat must apply Snow Wolf Po Jun through the public pickup path."
	)
	await process_frame
	await physics_frame
	_expect(
		host_orbit.is_active()
		and host_orbit.monitoring
		and not host_shape_a.disabled
		and not host_shape_b.disabled
		and not host_shape_c.disabled
		and not host_shape_d.disabled,
		"Host Hoe Cat Snow Wolf Po Jun must enable authoritative sword collision."
	)
	var host_hoe_snapshot: SnapshotManager.PlayerState = null
	for state in host_game.collect_player_snapshot_states():
		if state.peer_id == 1:
			host_hoe_snapshot = state
			break
	_expect(
		host_hoe_snapshot != null
		and host_hoe_snapshot.form_mode == PickupConfig.PlayerFormMode.ARMED
		and host_hoe_snapshot.shot_pattern == PickupConfig.ShotPattern.NORMAL,
		"Host Hoe Cat snapshots must encode active swords as ARMED/NORMAL."
	)
	host_orbit.deactivate()
	await process_frame
	_stop_audio_players(hoe_player)
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

	_expect(
		float(hoe_player.get("_primary_visual_time_left")) > 0.0,
		"Host skill-priority coverage must begin while the primary presentation is still active."
	)
	hoe_player.unlock_skill1()
	hoe_player.skill1_charge = hoe_player.skill1_charge_duration
	hoe_player.current_health = 70
	_expect(
		bool(mp_game.call("_apply_authoritative_hoe_action", 1, &"whirlwind", Vector2.ZERO)),
		"Host must let a fully charged Hoe Cat whirlwind interrupt the primary presentation."
	)
	_expect(
		is_zero_approx(float(hoe_player.get("_primary_visual_time_left")))
		and hoe_player.primary_impact_timer.is_stopped(),
		"Host-authoritative whirlwind must clear the interrupted primary presentation and timer."
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
	var host_game := GAME_SCENE.instantiate() as StandardGame
	_expect(host_game != null, "StandardGame must instantiate for authoritative Tiyi protocol coverage.")
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
	_bind_multiplayer_runtime(mp_game, host_game)
	mp_game.set("net_manager", net_manager)
	var oversized_target_ids := PackedInt32Array()
	for enemy_net_id in range(1, 28):
		oversized_target_ids.append(enemy_net_id)
	var sanitized_target_ids := mp_game.call(
		"_sanitize_tiyi_target_ids",
		oversized_target_ids,
		false
	) as PackedInt32Array
	_expect(
		sanitized_target_ids.size() == 25
		and sanitized_target_ids[0] == 1
		and sanitized_target_ids[24] == 25,
		"Tiyi multiplayer target sanitization must preserve the new 25-target hard cap."
	)

	_expect(
		is_equal_approx(tiyi_player.skill1_charge_duration, 24.0),
		"Tiyi must enter multiplayer with a default skill charge requirement of 24."
	)
	_expect(tiyi_player.has_skill1(), "Tiyi must enter multiplayer with High Noon unlocked.")
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
		_prepare_direct_enemy_spawn_points(host_game),
		"High-noon test must resolve its Campaign wave spawn-point mask."
	)
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
	var host_game := GAME_SCENE.instantiate() as StandardGame
	_expect(host_game != null, "StandardGame scene must instantiate for enemy hit dedupe test.")
	if host_game == null:
		return
	host_game.configure_multiplayer(1, 1, {1: "Host", 2: "Client"})
	host_game.set("auto_start_waves", false)
	root.add_child(host_game)
	await process_frame
	_expect(
		_prepare_direct_enemy_spawn_points(host_game),
		"Enemy hit test must resolve its Campaign wave spawn-point mask."
	)
	_expect(host_game.call("_try_spawn_enemy", BASIC_CONFIG), "Host must spawn an enemy for hit dedupe test.")
	_expect(host_game.call("_try_spawn_enemy", BASIC_CONFIG), "Host must spawn a second enemy for projectile hit-limit tests.")
	var host_enemy := host_game.get_enemy_for_net_id(1)
	var second_host_enemy := host_game.get_enemy_for_net_id(2)
	_expect(host_enemy != null, "Host spawned enemy must be indexed by net id for hit dedupe test.")
	_expect(second_host_enemy != null, "Second host enemy must be indexed for projectile hit-limit tests.")
	if host_enemy != null and second_host_enemy != null:
		var mp_game := MP_GAME_SCENE.instantiate()
		_bind_multiplayer_runtime(mp_game, host_game)
		var projectile_coordinator := (
			mp_game.get_node("ProjectileCoordinator")
			as MpProjectileCoordinator
		)
		var host_net_manager := root.get_node_or_null("NetManager")
		var previous_role := 0
		if host_net_manager != null:
			previous_role = int(host_net_manager.get("net_role"))
			host_net_manager.set("net_role", 1)
			mp_game.set("net_manager", host_net_manager)
		var non_piercing_projectile_id := (
			MpProjectileCoordinator.encode_projectile_id(
			2,
			1
			)
		)
		var piercing_projectile_id := MpProjectileCoordinator.encode_projectile_id(
			2,
			2
		)
		var sniper_projectile_id := MpProjectileCoordinator.encode_projectile_id(
			2,
			3
		)
		var skill1_bomb_projectile_id := (
			MpProjectileCoordinator.encode_projectile_id(
			2,
			4
			)
		)
		projectile_coordinator.remember_projectile_record(
			non_piercing_projectile_id,
			2,
			&"player_bullet",
			11,
			2.0,
			false,
			0.0
		)
		var health_before_hit := host_enemy.current_health
		mp_game.call(
			"_apply_enemy_hit_report",
			non_piercing_projectile_id,
			2,
			1,
			999,
			Vector2.LEFT
		)
		var health_after_first_hit := host_enemy.current_health
		mp_game.call(
			"_apply_enemy_hit_report",
			non_piercing_projectile_id,
			2,
			1,
			999,
			Vector2.LEFT
		)
		_expect(health_after_first_hit < health_before_hit, "First enemy hit report must damage the enemy.")
		_expect(
			host_enemy.current_health == health_after_first_hit,
			"Duplicate enemy hit reports for the same projectile/enemy pair must be ignored."
		)
		var second_health_before_non_piercing_hit := second_host_enemy.current_health
		mp_game.call(
			"_apply_enemy_hit_report",
			non_piercing_projectile_id,
			2,
			2,
			999,
			Vector2.LEFT
		)
		_expect(
			second_host_enemy.current_health == second_health_before_non_piercing_hit,
			"One non-piercing player bullet must accept only its first authoritative enemy hit."
		)
		var non_piercing_record := projectile_coordinator.get_projectile_record(
			non_piercing_projectile_id
		)
		_expect(
			bool(non_piercing_record.get("confirmed_hit_consumed", false)),
			"A confirmed non-piercing bullet hit must consume its projectile record hit."
		)
		projectile_coordinator.remember_projectile_record(
			sniper_projectile_id,
			2,
			&"tiyi_sniper_bullet",
			1,
			0.35,
			false,
			0.0
		)
		var health_before_forged_sniper_hit := second_host_enemy.current_health
		mp_game.call(
			"_rpc_enemy_hit_report",
			sniper_projectile_id,
			2,
			2,
			999,
			Vector2.LEFT
		)
		_expect(
			second_host_enemy.current_health == health_before_forged_sniper_hit,
			"The disabled client enemy-hit RPC must never settle Tiyi sniper damage."
		)
		projectile_coordinator.remember_projectile_record(
			skill1_bomb_projectile_id,
			2,
			&"skill1_bomb",
			11,
			2.0,
			false,
			0.0
		)
		var health_before_forged_bomb_hit := second_host_enemy.current_health
		mp_game.call(
			"_rpc_enemy_hit_report",
			skill1_bomb_projectile_id,
			2,
			2,
			999,
			Vector2.LEFT
		)
		_expect(
			second_host_enemy.current_health == health_before_forged_bomb_hit,
			"The disabled client enemy-hit RPC must never settle Host-authoritative Skill1 bomb damage."
		)
		mp_game.call(
			"_apply_enemy_hit_report",
			sniper_projectile_id,
			2,
			2,
			999,
			Vector2.LEFT
		)
		_expect(
			second_host_enemy.current_health < health_before_forged_sniper_hit,
			"Host-simulated Tiyi sniper hits must use the authoritative projectile record."
		)
		projectile_coordinator.remember_projectile_record(
			piercing_projectile_id,
			2,
			&"player_bullet",
			1,
			2.0,
			true,
			0.0
		)
		var first_health_before_piercing_hit := host_enemy.current_health
		var second_health_before_piercing_hit := second_host_enemy.current_health
		mp_game.call(
			"_apply_enemy_hit_report",
			piercing_projectile_id,
			2,
			1,
			999,
			Vector2.LEFT
		)
		mp_game.call(
			"_apply_enemy_hit_report",
			piercing_projectile_id,
			2,
			2,
			999,
			Vector2.LEFT
		)
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
			var damage_number_pool := host_game.get_node("DamageNumberPool") as DamageNumberPool
			_expect(
				damage_number_pool != null,
				"Multiplayer healing confirmation must share the fixed combat-number pool."
			)
			peer_two.current_health = 5
			var host_healing_number_count_before := (
				damage_number_pool.get_active_count() if damage_number_pool != null else 0
			)
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
			await process_frame
			if damage_number_pool != null:
				_expect(
					damage_number_pool.get_active_count() == host_healing_number_count_before + 1
					and damage_number_pool.has_active_text("+10"),
					"Host-authoritative healing must display its confirmed actual gain exactly once."
				)

			# Simulate a realtime snapshot arriving before the reliable heal confirm.
			# The health delta is already gone, but the explicit confirmed value must
			# still produce feedback once.
			peer_two.current_health = 5
			health_revisions.erase(2)
			peer_two.set_multiplayer_health_state(15, false)
			var confirmed_healing_number_count_before := (
				damage_number_pool.get_active_count() if damage_number_pool != null else 0
			)
			mp_game.call("net_player_healed", 2, 15, 1, 10)
			_expect(
				peer_two.current_health == 15,
				"Heal confirm must preserve health that an earlier realtime snapshot already applied."
			)
			await process_frame
			if damage_number_pool != null:
				_expect(
					damage_number_pool.get_active_count()
					== confirmed_healing_number_count_before + 1
					and damage_number_pool.has_active_text("+10"),
					"Reliable heal confirmation must display confirmed_healing even after the snapshot."
				)
			var count_before_stale_heal := (
				damage_number_pool.get_active_count() if damage_number_pool != null else 0
			)
			mp_game.call("net_player_healed", 2, 35, 1, 99)
			await process_frame
			_expect(peer_two.current_health == 15, "Stale heal revisions must be ignored.")
			if damage_number_pool != null:
				_expect(
					damage_number_pool.get_active_count() == count_before_stale_heal
					and not damage_number_pool.has_active_text("+99"),
					"A duplicate heal revision must neither display again nor enqueue stale feedback."
				)
		if host_net_manager != null:
			host_net_manager.set("net_role", previous_role)
		mp_game.free()
	_stop_audio_players(host_game)
	host_game.queue_free()
	await process_frame
	await physics_frame

	var client_game := GAME_SCENE.instantiate() as StandardGame
	_expect(client_game != null, "StandardGame scene must instantiate for client event cleanup test.")
	if client_game == null:
		return
	client_game.configure_multiplayer(2, 2, {1: "Host", 2: "Client"})
	client_game.set("auto_start_waves", false)
	root.add_child(client_game)
	await process_frame
	var client_mp_game := MP_GAME_SCENE.instantiate()
	_bind_multiplayer_runtime(client_mp_game, client_game)
	var net_manager := root.get_node_or_null("NetManager")
	if net_manager != null:
		client_mp_game.set("net_manager", net_manager)
	var client_run_state := root.get_node_or_null("RunState") as RunStateStore
	if client_run_state != null:
		client_run_state.begin_new_run(&"weishidaier", false)
		client_run_state.set_active_multiplayer_peer(2)
		client_mp_game.set("run_state", client_run_state)

	var client_enemy := BOMBER_CONFIG.enemy_scene.instantiate() as Enemy
	_expect(client_enemy != null, "Client bomber scene must instantiate for enemy removed test.")
	if client_enemy != null:
		client_game.enemy_container.add_child(client_enemy)
		client_enemy.setup(BOMBER_CONFIG, client_game.player, client_game.grid_pathfinder)
		client_enemy.configure_multiplayer_proxy()
		_expect(
			client_enemy.physics_interpolation_mode == Node.PHYSICS_INTERPOLATION_MODE_OFF,
			"Client enemy proxies must not stack native physics interpolation on network interpolation."
		)
		client_enemy.set_meta("net_id", 77)
		var client_net_enemies: Dictionary = client_mp_game.enemy_coordinator.net_enemies
		var spawn_times: Dictionary = (
			client_mp_game.enemy_coordinator.enemy_spawn_snapshot_times
		)
		client_net_enemies[77] = client_enemy
		spawn_times[77] = 0.0
		client_mp_game.enemy_coordinator.enemy_interpolators[77] = NetInterpolator.new(0.1)
		client_mp_game.call("net_enemy_defeated", 77, Vector2(44.0, 55.0))
		await process_frame
		_expect(not client_net_enemies.has(77), "Client enemy defeated event must erase the enemy index.")
		_expect(not spawn_times.has(77), "Client enemy defeated event must erase spawn timing.")
		_expect(
			not client_mp_game.enemy_coordinator.enemy_interpolators.has(77),
			"Client enemy defeated event must clear interpolation state."
		)
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
		magic_enemy.setup(
			BASIC_CONFIG,
			client_game.player,
			client_game.grid_pathfinder,
			client_game
		)
		magic_enemy.configure_multiplayer_proxy()
		magic_enemy.set_meta("net_id", 78)
		magic_enemy.global_position = Vector2(88.0, 99.0)
		var client_net_enemies: Dictionary = client_mp_game.enemy_coordinator.net_enemies
		client_net_enemies[78] = magic_enemy
		var health_after_magic := maxi(magic_enemy.current_health - 5, 1)
		client_mp_game.call(
			"net_enemy_damage_applied",
			78,
			health_after_magic,
			magic_enemy.health_revision + 1,
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
			WHITE_CRYSTAL_MATERIAL.resource_path,
			45.0,
			56.0
		)
		var spawned_material := client_game.get_pickup_for_net_id(9002)
		_expect(
			spawned_material != null
			and spawned_material.config == WHITE_CRYSTAL_MATERIAL
			and spawned_material.global_position.is_equal_approx(
				Vector2(45.0, 56.0)
			),
			"New crystal resource paths must recreate the correct network pickup."
		)
		var pickup_inventory_snapshot: Dictionary = (
			client_run_state.export_inventory_snapshot_for_peer(2)
		)
		pickup_inventory_snapshot["revision"] = (
			client_run_state.get_inventory_revision_for_peer(2) + 1
		)
		var pickup_slots := pickup_inventory_snapshot.get("slots", []) as Array
		var pickup_slot := pickup_slots[0] as Dictionary
		pickup_slot["config_path"] = WHITE_CRYSTAL_MATERIAL.resource_path
		pickup_slot["stack_count"] = 1
		for pickup_slot_value in pickup_slots:
			var authoritative_pickup_slot := pickup_slot_value as Dictionary
			authoritative_pickup_slot["revision"] = int(
				pickup_inventory_snapshot["revision"]
			)
		client_player.powerup_audio.stop()
		client_mp_game.call(
			"net_pickup_collected",
			9002,
			2,
			WHITE_CRYSTAL_MATERIAL.resource_path,
			false,
			pickup_inventory_snapshot
		)
		await process_frame
		_expect(not client_game.multiplayer_pickups.has(9002), "Stored pickup confirm must erase pickup index.")
		_expect(
			client_run_state != null
			and client_run_state.get_item_for_peer(2, 0)
				== WHITE_CRYSTAL_MATERIAL,
			"Stored material confirm must load the new crystal path and add it to inventory."
		)
		_expect(
			client_player.powerup_audio.playing,
			"A newly applied stored-pickup snapshot must replay the pickup cue on clients."
		)
		client_player.powerup_audio.stop()
		client_mp_game.call(
			"net_pickup_collected",
			9002,
			2,
			WHITE_CRYSTAL_MATERIAL.resource_path,
			false,
			pickup_inventory_snapshot
		)
		_expect(
			not client_player.powerup_audio.playing,
			"A duplicate stored-pickup snapshot must not replay pickup feedback."
		)
		var revision_before_malformed_pickup := (
			client_run_state.get_inventory_revision_for_peer(2)
		)
		client_mp_game.call(
			"net_pickup_spawned",
			9003,
			HEALTH_PICKUP.resource_path,
			46.0,
			57.0
		)
		client_mp_game.call(
			"net_pickup_collected",
			9003,
			2,
			HEALTH_PICKUP.resource_path,
			false
		)
		_expect(
			client_run_state.get_inventory_revision_for_peer(2)
			== revision_before_malformed_pickup,
			"A stored-pickup confirmation without its v8 inventory snapshot must not invent a local item."
		)
		_expect(
			not client_player.powerup_audio.playing,
			"A rejected stored-pickup confirmation must not replay pickup feedback."
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

	enemy.apply_multiplayer_proxy_motion(
		enemy.global_position,
		Vector2.ZERO,
		Enemy.LocomotionState.MOVING
	)
	sprite.speed_scale = 24.0
	enemy.call("play_multiplayer_enemy_action", action_name, Vector2.RIGHT, 1)
	_expect(sprite.animation == expected_action_animation, message + " Action animation did not start.")
	await _wait_for_sprite_animation(sprite, enemy_config.move_animation_name, 1.0)
	_expect(sprite.animation == enemy_config.move_animation_name, message)
	_expect(
		sprite.is_playing() and sprite.get_playing_speed() > 0.0,
		message + " Move animation must keep advancing."
	)
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
	_expect(
		player.body_sprite.visible
		and player.body_sprite.animation == &"death"
		and player.body_sprite.is_playing(),
		"Multiplayer death must play the character's authored death animation."
	)
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
	await create_timer(0.6).timeout
	_expect(
		player.body_sprite.visible and player.body_sprite.animation != &"death",
		"A stale death-animation completion must never hide a character revived before it finished."
	)

	player.queue_free()
	await process_frame


func _test_multiplayer_revive_position_uses_living_players() -> void:
	var game := GAME_SCENE.instantiate() as StandardGame
	_expect(game != null, "StandardGame scene must instantiate for revive position test.")
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
	_bind_multiplayer_runtime(mp_game, game)

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
		_expect(
			game.get_multiplayer_mode_adapter().get_fixed_multiplayer_respawn_position(2)
			== null,
			"Standard mode must not opt into a fixed multiplayer respawn position."
		)
		var resolved_position: Variant = mp_game.call(
			"_resolve_multiplayer_revive_position",
			2,
			revive_positions
		)
		_expect(
			resolved_position is Vector2 and revive_positions.has(resolved_position),
			"Standard mode revive resolver must preserve living-player random respawns."
		)

	mp_game.free()
	_stop_audio_players(game)
	game.queue_free()
	await process_frame


func _test_tower_defense_spawn_slots_and_fixed_respawn() -> void:
	var game := TOWER_DEFENSE_GAME_SCENE.instantiate() as TowerDefenseGame
	_disable_tower_fixture_background_loads(game)
	_expect(game != null, "Tower-defense game must instantiate for spawn-slot coverage.")
	if game == null:
		return
	var player_names := {
		1: "Host",
		2: "Peer 2",
		3: "Peer 3",
		4: "Peer 4",
	}
	game.configure_multiplayer(CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY, 1, player_names)
	game.auto_start_waves = false
	_expect(game.linglan_boss_enabled, "Tower-defense Linglan must be enabled by the authored scene.")
	root.add_child(game)
	await process_frame
	await physics_frame
	var mode_adapter := (
		game.get_multiplayer_mode_adapter()
		as TowerDefenseMultiplayerModeAdapter
	)
	_expect(mode_adapter != null, "Tower-defense runtime must expose its typed mode adapter.")

	_expect(
		game.player_spawn.position == Vector2(117.0, 367.0),
		"Tower-defense PlayerSpawn must match the blue-gate reference position."
	)
	_expect(
		game.player_spawn.global_position
		== game.position + game.player_spawn.position,
		"Tower-defense PlayerSpawn world position must include the scene root offset."
	)
	var expected_offsets: Array[Vector2] = [
		Vector2.ZERO,
		Vector2(18.0, 0.0),
		Vector2(0.0, 18.0),
		Vector2(18.0, 18.0),
	]
	for index in range(expected_offsets.size()):
		var peer_id := index + 1
		var player_node := game.get_player_for_peer(peer_id)
		var expected_position := game.player_spawn.global_position + expected_offsets[index]
		_expect(player_node != null, "Tower-defense spawn test must create peer %d." % peer_id)
		if player_node == null:
			continue
		_expect(
			player_node.global_position.is_equal_approx(expected_position),
			"Tower-defense peer %d must start in its stable spawn slot." % peer_id
		)
		var fixed_position: Variant = mode_adapter.get_fixed_multiplayer_respawn_position(peer_id)
		_expect(
			fixed_position is Vector2
			and (fixed_position as Vector2).is_equal_approx(expected_position),
			"Tower-defense peer %d fixed respawn must match its initial slot." % peer_id
		)

	var mp_game := MP_GAME_SCENE.instantiate()
	_expect(mp_game != null, "MpGame scene must instantiate for tower-defense respawn resolver coverage.")
	if mp_game != null:
		_bind_multiplayer_runtime(mp_game, game)
		var unrelated_living_positions: Array[Vector2] = [Vector2(-400.0, -300.0)]
		for peer_id in player_names:
			var resolved_position: Variant = mp_game.call(
				"_resolve_multiplayer_revive_position",
				int(peer_id),
				unrelated_living_positions
			)
			var expected_position: Variant = mode_adapter.get_fixed_multiplayer_respawn_position(
				int(peer_id)
			)
			_expect(
				resolved_position is Vector2
				and expected_position is Vector2
				and (resolved_position as Vector2).is_equal_approx(expected_position as Vector2),
				"Tower-defense revive resolver must prefer peer %d's fixed slot." % int(peer_id)
			)

		var peer_four_position: Variant = mode_adapter.get_fixed_multiplayer_respawn_position(4)
		game.remove_multiplayer_player(2)
		_expect(
			peer_four_position is Vector2
			and mode_adapter.get_fixed_multiplayer_respawn_position(4) is Vector2
			and (
				mode_adapter.get_fixed_multiplayer_respawn_position(4) as Vector2
			).is_equal_approx(peer_four_position as Vector2),
			"Removing a lower peer id must not shift another peer's respawn slot."
		)
		mp_game.free()

	_stop_audio_players(game)
	game.queue_free()
	await process_frame
	await physics_frame


func _test_multiplayer_revive_resets_remote_visual_interpolator() -> void:
	var game := GAME_SCENE.instantiate() as StandardGame
	_expect(game != null, "StandardGame scene must instantiate for revive interpolation test.")
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
			_bind_multiplayer_runtime(mp_game, game)
			var old_position := Vector2(-400.0, -300.0)
			var revive_position := Vector2(96.0, 144.0)
			remote_player.global_position = old_position
			remote_player.apply_multiplayer_death_state()
			var stale_interp := NetInterpolator.new(0.1)
			stale_interp.push_snapshot(0.0, old_position, Vector2.ZERO)
			var player_coordinator := (
				mp_game.get_node("PlayerCoordinator") as MpPlayerCoordinator
			)
			player_coordinator.reset_visual_interpolator_to_state(
				3, old_position, Vector2.ZERO, 0, 0, 0.0
			)
			stale_interp = player_coordinator.get_visual_interpolator(3)
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
			var refreshed_interp := player_coordinator.get_visual_interpolator(3)
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
	var game := GAME_SCENE.instantiate() as StandardGame
	_expect(game != null, "StandardGame scene must instantiate for client damage confirm blink test.")
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
		var damage_number_pool := game.get_node("DamageNumberPool") as DamageNumberPool
		_expect(mp_game != null, "MpGame scene must instantiate for client damage confirm blink test.")
		_expect(damage_number_pool != null, "Client damage confirmation must share the game damage-number pool.")
		if mp_game != null:
			_bind_multiplayer_runtime(mp_game, game)
			local_player.current_health = local_player.max_health
			local_player.invincibility_time_left = 0.0
			local_player.call("_set_hurt_blink_enabled", false)
			var sprite_material := local_player.body_sprite.material as ShaderMaterial
			_expect(sprite_material != null, "Local player body sprite must use a ShaderMaterial.")
			var damage_number_count_before := (
				damage_number_pool.get_active_count() if damage_number_pool != null else 0
			)

			mp_game.call(
				"net_player_damage_applied",
				2,
				local_player.max_health - 7,
				false,
				1,
				7,
				Vector2.LEFT,
				EnemyConfig.DamageType.PHYSICAL
			)
			_expect(local_player.current_health == local_player.max_health - 7, "Local damage confirm must update health.")
			if damage_number_pool != null:
				_expect(
					damage_number_pool.get_active_count() == damage_number_count_before + 1
					and damage_number_pool.has_active_text("7"),
					"A new reliable player-damage revision must display its confirmed amount once."
				)
				mp_game.call(
					"net_player_damage_applied",
					2,
					local_player.current_health,
					false,
					1,
					7,
					Vector2.LEFT,
					EnemyConfig.DamageType.PHYSICAL
				)
				_expect(
					damage_number_pool.get_active_count() == damage_number_count_before + 1,
					"A duplicate reliable player-damage revision must not display twice."
				)
			_expect(local_player.invincibility_time_left > 0.0, "Local damage confirm must start local blink time.")
			if sprite_material != null:
				_expect(
					bool(sprite_material.get_shader_parameter(&"blink_enabled")),
					"Local damage confirm must enable hurt blink on the local player."
				)

			local_player.invincibility_time_left = 0.0
			local_player.call("_set_hurt_blink_enabled", false)
			mp_game.call(
				"net_player_damage_applied",
				2,
				local_player.current_health,
				false,
				2,
				7,
				Vector2.RIGHT,
				EnemyConfig.DamageType.MAGIC
			)
			_expect(
				local_player.invincibility_time_left > 0.0,
				"Local damage confirm must restore blink even when predicted health already matches."
			)
			if damage_number_pool != null:
				_expect(
					damage_number_pool.get_active_count() == damage_number_count_before + 2
					and not damage_number_pool.get_first_active_debug_snapshot(
						EnemyConfig.DamageType.MAGIC
					).is_empty(),
					"A confirmation after local prediction must still show one typed damage number."
				)
			if sprite_material != null:
				_expect(
					bool(sprite_material.get_shader_parameter(&"blink_enabled")),
					"Local same-health damage confirm must enable hurt blink on the local player."
				)

			local_player.invincibility_time_left = 0.0
			local_player.call("_set_hurt_blink_enabled", false)
			mp_game.call(
				"net_player_damage_applied",
				1,
				host_player.max_health - 5,
				false,
				2,
				5,
				Vector2.LEFT,
				EnemyConfig.DamageType.PHYSICAL
			)
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
	var game := GAME_SCENE.instantiate() as StandardGame
	_expect(game != null, "StandardGame scene must instantiate for Linglan boss registration test.")
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
		boss_enemy.setup(
			boss_enemy_config,
			game.player,
			game.grid_pathfinder,
			game,
			game.linglan_boss_runtime_port
		)
		var spawn_events: Array[int] = []
		var spawn_callback := func(net_id: int, _enemy_config: EnemyConfig, _spawn_position: Vector2) -> void:
			spawn_events.append(net_id)
		var gameplay_gateway := game.get_multiplayer_gameplay_gateway()
		_expect(gameplay_gateway != null, "Standard runtime must expose its gameplay gateway.")
		if gameplay_gateway == null:
			boss_enemy.queue_free()
			return
		gameplay_gateway.enemy_spawned.connect(spawn_callback)
		var net_id := int(game.call(
			"_register_multiplayer_enemy_instance",
			boss_enemy,
			boss_enemy_config,
			Vector2(42.0, 64.0),
			false
		))
		gameplay_gateway.enemy_spawned.disconnect(spawn_callback)
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


func _test_linglan_airdrop_replication_contract() -> void:
	var game := TOWER_DEFENSE_GAME_SCENE.instantiate() as TowerDefenseGame
	_disable_tower_fixture_background_loads(game)
	_expect(game != null, "Tower game must instantiate for Linglan airdrop replication.")
	if game == null:
		return
	game.configure_multiplayer(1, 1, {1: "Host", 2: "Client"})
	game.auto_start_waves = false
	root.add_child(game)
	await process_frame
	game.wave_state = CombatFlowState.State.BOSS_ACTIVE
	var replicated_events: Array[Dictionary] = []
	var spawned_events: Array[Dictionary] = []
	game.linglan_boss_runtime_port.airdrop_started.connect(
		func(
			enemy_config: EnemyConfig,
			landing_position: Vector2,
			warning_duration: float,
			drop_height: float,
			drop_duration: float
		) -> void:
			replicated_events.append({
				"enemy_config": enemy_config,
				"landing_position": landing_position,
				"warning_duration": warning_duration,
				"drop_height": drop_height,
				"drop_duration": drop_duration,
			})
	)
	game.get_multiplayer_gameplay_gateway().enemy_spawned.connect(
		func(net_id: int, enemy_config: EnemyConfig, spawn_position: Vector2) -> void:
			spawned_events.append({
				"net_id": net_id,
				"enemy_config": enemy_config,
				"spawn_position": spawn_position,
			})
	)
	var warning_scene := load(
		"res://scene/boss/linglan/linglan_airdrop_warning_marker.tscn"
	) as PackedScene
	game.boss_coordinator.spawn_airdrop_sniper(
		SNIPER_CONFIG,
		warning_scene,
		0.01,
		48.0,
		0.02
	)
	_expect(
		replicated_events.size() == 1,
		"A host Linglan airdrop must emit one reliable presentation event before landing."
	)
	if not replicated_events.is_empty():
		var event := replicated_events[0]
		_expect(
			event.get("enemy_config") == SNIPER_CONFIG
			and (event.get("landing_position") as Vector2).is_finite()
			and is_equal_approx(float(event.get("warning_duration", -1.0)), 0.01)
			and is_equal_approx(float(event.get("drop_height", -1.0)), 48.0)
			and is_equal_approx(float(event.get("drop_duration", -1.0)), 0.02),
			"The airdrop event must preserve config, landing point, warning, and drop timing."
		)
	await create_timer(0.20).timeout
	_expect(
		spawned_events.size() == 1,
		"A landed Linglan sniper airdrop must enter the normal multiplayer enemy-spawn stream."
	)
	if not spawned_events.is_empty() and not replicated_events.is_empty():
		var sniper_spawn := spawned_events[0]
		_expect(
			int(sniper_spawn.get("net_id", 0)) > 0
			and sniper_spawn.get("enemy_config") == SNIPER_CONFIG
			and (sniper_spawn.get("spawn_position") as Vector2).is_equal_approx(
				replicated_events[0].get("landing_position") as Vector2
			),
			"The authoritative sniper spawn must preserve its config and announced landing point."
		)

	var slime_spawn_position := Vector2(512.0, 320.0)
	var spawn_count_before_slime := spawned_events.size()
	game.boss_coordinator.spawn_random_slime(slime_spawn_position)
	_expect(
		spawned_events.size() == spawn_count_before_slime + 1,
		"A Linglan random slime must enter the normal multiplayer enemy-spawn stream."
	)
	if spawned_events.size() > spawn_count_before_slime:
		var slime_spawn := spawned_events[spawn_count_before_slime]
		var slime_config := slime_spawn.get("enemy_config") as EnemyConfig
		_expect(
			int(slime_spawn.get("net_id", 0)) > 0
			and slime_config != null
			and LINGLAN_SLIME_CONFIG_PATHS.has(slime_config.resource_path)
			and (slime_spawn.get("spawn_position") as Vector2).is_equal_approx(
				slime_spawn_position
			),
			"The random slime spawn must preserve one configured slime type and Linglan's position."
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
	var explicit_runtime := GAME_SCENE.instantiate() as StandardGame
	_expect(explicit_runtime != null, "Linglan skill2 fixture must instantiate a typed runtime.")
	if explicit_runtime == null:
		return
	explicit_runtime.configure_multiplayer(
		CombatRuntimeBase.RuntimeMode.CLIENT_VIEW,
		2,
		{1: "Host", 2: "Client"}
	)
	explicit_runtime.auto_start_waves = false
	root.add_child(explicit_runtime)
	await process_frame
	var gameplay_gateway := explicit_runtime.get_multiplayer_gameplay_gateway()

	var enemy := BASIC_CONFIG.enemy_scene.instantiate() as Enemy
	var authoritative_enemy: Enemy = null
	var rocket := LINGLAN_SKILL2_ROCKET_SCENE.instantiate() as LinglanSkill2SakuraRocket
	_expect(enemy != null and rocket != null, "Linglan skill2 client proxy damage test must instantiate enemy and rocket.")
	if enemy != null and rocket != null:
		rocket.bind_gameplay_context(explicit_runtime, gameplay_gateway)
		rocket.set_physics_process(false)
		explicit_runtime.enemy_container.add_child(enemy)
		explicit_runtime.add_child(rocket)
		# `_ready()` re-enables projectile processing. Disable it immediately after
		# entering the tree so this isolated authority fixture cannot self-retire.
		enemy.setup(BASIC_CONFIG, null, null, explicit_runtime)
		enemy.configure_multiplayer_proxy()
		rocket.set_physics_process(false)
		var health_before_client_proxy_hit := enemy.current_health
		rocket.damage = 1
		rocket.call("_apply_enemy_damage", enemy)
		_expect(
			enemy.current_health == health_before_client_proxy_hit,
			"Client-view Linglan skill2 rocket must not apply local damage to enemy proxies."
		)

		explicit_runtime.runtime_mode = CombatRuntimeBase.RuntimeMode.SINGLEPLAYER
		authoritative_enemy = BASIC_CONFIG.enemy_scene.instantiate() as Enemy
		_expect(
			authoritative_enemy != null,
			"Linglan skill2 authority test must instantiate an authoritative enemy."
		)
		if authoritative_enemy != null:
			authoritative_enemy.global_position = Vector2(256.0, 256.0)
			explicit_runtime.enemy_container.add_child(authoritative_enemy)
			authoritative_enemy.setup(BASIC_CONFIG, null, null, explicit_runtime)
			authoritative_enemy.set_physics_process(false)
			var authoritative_health_before := authoritative_enemy.current_health
			rocket.call("_apply_enemy_damage", authoritative_enemy)
			_expect(
				authoritative_enemy.current_health == authoritative_health_before - 1,
				"Linglan skill2 rocket must damage authoritative enemies outside client-view runtime."
			)

	if rocket != null:
		rocket.queue_free()
	if enemy != null:
		enemy.queue_free()
	if authoritative_enemy != null:
		authoritative_enemy.queue_free()
	_stop_audio_players(explicit_runtime)
	explicit_runtime.queue_free()
	await process_frame
	await physics_frame

	var game := GAME_SCENE.instantiate() as StandardGame
	_expect(game != null, "Sakura rocket multiplayer test must instantiate StandardGame.")
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
	_bind_multiplayer_runtime(mp_game, game)
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

		var projectile_coordinator := (
			mp_game.get_node("ProjectileCoordinator")
			as MpProjectileCoordinator
		)
		var sakura_rocket_projectile_id := (
			MpProjectileCoordinator.encode_projectile_id(
			2,
			1
			)
		)
		mp_game.call(
			"net_projectile_fired",
			sakura_rocket_projectile_id,
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
		var spawned_rocket := projectile_coordinator.get_projectile(
			sakura_rocket_projectile_id
		) as LinglanSkill2SakuraRocket
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
		if spawned_rocket != null and is_instance_valid(spawned_rocket):
			spawned_rocket.call("_retire")
		await process_frame

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
	_expect(host_game != null, "StandardGame scene must instantiate for cheat xirang confirm test.")
	if host_game == null:
		mp_game.free()
		return

	host_game.configure_multiplayer(1, 1, {1: "Host", 2: "Client"})
	host_game.set("auto_start_waves", false)
	root.add_child(host_game)
	await process_frame
	_bind_multiplayer_runtime(mp_game, host_game)

	var remote_player := host_game.get_player_for_peer(2) as Player
	_expect(remote_player != null, "Remote player must exist for cheat xirang confirm test.")
	if remote_player != null:
		remote_player.current_xirang = 15
		mp_game.call("net_cheat_xirang_confirmed", 2, 1015, 1000)
		_expect(remote_player.current_xirang == 1015, "Cheat confirm must update the selected peer's xirang.")
		var run_state := root.get_node("RunState") as RunStateStore
		run_state.begin_new_run(&"weishidaier", false)
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
	var host_guardian_system := host_game.get_node(
		"GuardianAuraSystem"
	) as GuardianAuraSystem
	_expect(
		host_guardian_system.authoritative_processing_enabled
		and host_guardian_system.is_physics_processing(),
		"Host authority must keep Guardian aura processing enabled."
	)
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
	_expect(host_player.current_xirang == StandardGame.INITIAL_PLAYER_XIRANG, "Host player must start with initial xirang.")
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
	_expect(
		_prepare_direct_enemy_spawn_points(host_game),
		"Runtime-mode test must resolve its Campaign wave spawn-point mask."
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
	var client_guardian_system := client_game.get_node(
		"GuardianAuraSystem"
	) as GuardianAuraSystem
	_expect(
		not client_guardian_system.authoritative_processing_enabled
		and not client_guardian_system.is_physics_processing()
		and client_guardian_system.tracked_enemy_ids.is_empty(),
		"Client view must not spend CPU maintaining authoritative Guardian auras."
	)
	var client_local_player := client_game.get_player_for_peer(2) as Player
	var client_remote_player := client_game.get_player_for_peer(1) as Player
	_expect(
		client_local_player != null
		and client_local_player.nameplate_label.label_settings.font_color.is_equal_approx(Player.LOCAL_NAMEPLATE_FONT_COLOR),
		"Local client nameplate text must be green."
	)
	_expect(
		client_local_player != null
		and client_local_player.current_xirang == StandardGame.INITIAL_PLAYER_XIRANG,
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

	var tower_client_game := TOWER_DEFENSE_GAME_SCENE.instantiate() as TowerDefenseGame
	_disable_tower_fixture_background_loads(tower_client_game)
	tower_client_game.configure_multiplayer(
		CombatRuntimeBase.RuntimeMode.CLIENT_VIEW,
		2,
		{1: "Host", 2: "Client"}
	)
	tower_client_game.set("auto_start_waves", false)
	root.add_child(tower_client_game)
	await process_frame
	var tower_client_guardian_system := tower_client_game.get_node(
		"GuardianAuraSystem"
	) as GuardianAuraSystem
	_expect(
		not tower_client_guardian_system.authoritative_processing_enabled
		and not tower_client_guardian_system.is_physics_processing()
		and tower_client_guardian_system.tracked_enemy_ids.is_empty(),
		"Tower-defense client view must disable Guardian aura processing."
	)
	_stop_audio_players(tower_client_game)
	tower_client_game.queue_free()
	await process_frame


func _test_test_arena_multiplayer_runtime_modes() -> void:
	for arena_contract in [
		{
			"scene": TEST_ARENA_SCENE,
			"campaign": TEST_ARENA_MULTIPLAYER_CAMPAIGN,
			"runtime_class": "TestGrassArena",
			"enemy_count": 1000,
		},
		{
			"scene": TEST_ARENA_P2_SCENE,
			"campaign": TEST_ARENA_P2_MULTIPLAYER_CAMPAIGN,
			"runtime_class": "TestGrassArenaP2",
			"enemy_count": 1,
		},
	]:
		var arena_scene := arena_contract["scene"] as PackedScene
		var arena := arena_scene.instantiate() as TestGrassArena
		_disable_tower_fixture_background_loads(arena)
		_expect(
			arena != null,
			"%s multiplayer runtime must instantiate." % arena_contract["runtime_class"]
		)
		if arena == null:
			continue
		arena.configure_multiplayer(
			CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY,
			1,
			{1: "Host", 2: "Client"},
			{1: &"weishidaier", 2: &"weishidaier"}
		)
		arena.auto_start_waves = false
		root.add_child(arena)
		await process_frame
		await physics_frame
		var waves: Array[WaveConfig] = arena.active_campaign.get_waves()
		_expect(
			arena.active_campaign == arena_contract["campaign"]
			and arena.multiplayer_campaign == arena_contract["campaign"],
			"%s must select its exact multiplayer Campaign."
			% arena_contract["runtime_class"]
		)
		_expect(
			waves.size() == 1
			and waves[0].get_total_enemy_count() == int(arena_contract["enemy_count"]),
			"%s multiplayer Campaign must retain its authored enemy count."
			% arena_contract["runtime_class"]
		)
		_expect(
			is_zero_approx(
				arena.progression_config.enemy_count_per_extra_player_ratio
			),
			"%s must not scale test enemy counts with extra players."
			% arena_contract["runtime_class"]
		)
		_expect(
			arena.supports_tower_defense()
			and arena.supports_test_arena_manual_night_sync(),
			"%s must expose tower-defense and manual day/night multiplayer contracts."
			% arena_contract["runtime_class"]
		)
		_stop_audio_players(arena)
		arena.queue_free()
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
	player_state.form_mode = PickupConfig.PlayerFormMode.ARMED
	player_state.shot_pattern = PickupConfig.ShotPattern.NORMAL
	player_state.primary_cooldown_ratio = 0.37
	player_state.effective_move_speed_multiplier = 1.375
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
		_expect(
			player_states[0].form_mode == PickupConfig.PlayerFormMode.ARMED
			and player_states[0].shot_pattern == PickupConfig.ShotPattern.NORMAL,
			"Hoe Cat sword form must round-trip as ARMED/NORMAL."
		)
		_expect(player_states[0].character_id == &"hoe_cat", "Player snapshot character id mismatch.")
		_expect(
			absf(player_states[0].primary_cooldown_ratio - 0.37) <= 1.0 / 255.0,
			"Player snapshot primary cooldown ratio mismatch."
		)
		_expect(
			absf(player_states[0].effective_move_speed_multiplier - 1.375) <= 0.001,
			"Player snapshot authoritative movement multiplier mismatch."
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
	var tango_state := SnapshotManager.PlayerState.new()
	tango_state.peer_id = 4
	tango_state.character_id = &"tango"
	tango_state.current_health = 60
	tango_state.max_health = 60
	var tango_data := snapshot_mgr.encode_all_player_snapshots([tango_state])
	var tango_states := snapshot_mgr.decode_all_player_snapshots(tango_data)
	_expect(
		tango_states.size() == 1
		and tango_states[0].peer_id == 4
		and tango_states[0].character_id == &"tango"
		and tango_states[0].current_health == 60,
		"Player snapshot character code 3 must round-trip Tango."
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
	_expect(
		received_player_keyframe.size() == 1
		and repeated_player_states.size() == 1
		and is_same(received_player_keyframe[0], repeated_player_states[0]),
		"Player delta decoding must reuse its per-peer output state."
	)
	if repeated_player_states.size() == 1:
		_expect(repeated_player_states[0].current_health == 42, "Player delta must preserve health through baseline.")
		_expect(repeated_player_states[0].skill1_upgrade_level == 2, "Player delta must preserve skill upgrade through baseline.")
		_expect(repeated_player_states[0].ammo_capacity == 30, "Player delta must preserve ammo capacity through baseline.")
		_expect(repeated_player_states[0].current_ammo == 17, "Player delta must preserve current ammo through baseline.")
		_expect(repeated_player_states[0].is_reloading, "Player delta must preserve reload state through baseline.")
		_expect(is_equal_approx(repeated_player_states[0].reload_progress, 0.4), "Player delta must preserve reload progress through baseline.")
		_expect(
			repeated_player_states[0].form_mode == PickupConfig.PlayerFormMode.ARMED
			and repeated_player_states[0].shot_pattern == PickupConfig.ShotPattern.NORMAL,
			"Player delta must preserve the active Hoe Cat sword form."
		)
		_expect(repeated_player_states[0].character_id == &"hoe_cat", "Player delta must preserve character id through baseline.")
		_expect(
			absf(repeated_player_states[0].primary_cooldown_ratio - 0.37) <= 1.0 / 255.0,
			"Player delta must preserve primary cooldown through baseline."
		)
		_expect(
			absf(repeated_player_states[0].effective_move_speed_multiplier - 1.375) <= 0.001,
			"Player delta must preserve the authoritative movement multiplier."
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
		moved_player_delta.size() == player_keyframe.size(),
		"A player snapshot with changed meta must carry a full-sized payload."
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
		_expect(
			moved_player_states[0].form_mode == PickupConfig.PlayerFormMode.NORMAL
			and moved_player_states[0].shot_pattern == PickupConfig.ShotPattern.NORMAL,
			"Player delta must carry the Hoe Cat sword form transition back to NORMAL."
		)
	var peer_11_player_data := delta_player_mgr.encode_player_snapshots_for_peer(11, [moved_player_state], false)
	_expect(
		peer_11_player_data.size() == player_keyframe.size(),
		"A different receiver peer must get a player keyframe until it has its own baseline."
	)
	var missing_player_baseline_mgr := SnapshotManager.new()
	var skipped_player_delta := missing_player_baseline_mgr.decode_player_snapshots_with_baseline(
		repeated_player_delta
	)
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
			is_equal_approx(distant_player_states[0].position.x, 99999.0)
			and is_equal_approx(distant_player_states[0].position.y, -99999.0),
			"Player positions must round-trip through the dedicated scaled int32 fields."
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
	enemy_state.locomotion_state = SnapshotManager.ENEMY_LOCOMOTION_MOVING
	enemy_state.health = 3
	enemy_state.visual_status_mask = 0b11101
	var enemy_data := snapshot_mgr.encode_all_enemy_snapshots([enemy_state])
	var enemy_states := SnapshotManager.decode_all_enemy_snapshots(enemy_data)
	_expect(enemy_states.size() == 1, "Enemy snapshot count mismatch.")
	if enemy_states.size() == 1:
		_expect(enemy_states[0].net_id == 7, "Enemy snapshot net_id mismatch.")
		_expect(enemy_states[0].health == 3, "Enemy snapshot health mismatch.")
		_expect(enemy_states[0].visual_status_mask == 0b11101, "Enemy visual status mask mismatch.")
		_expect(
			enemy_states[0].locomotion_state == SnapshotManager.ENEMY_LOCOMOTION_MOVING,
			"Enemy locomotion state mismatch."
		)
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
	_expect(
		received_enemy_keyframe.size() == 1
		and repeated_enemy_states.size() == 1
		and is_same(received_enemy_keyframe[0], repeated_enemy_states[0]),
		"Enemy delta decoding must reuse its per-enemy output state."
	)
	if repeated_enemy_states.size() == 1:
		_expect(repeated_enemy_states[0].health == 3, "Enemy delta must preserve health through baseline.")
		_expect(
			repeated_enemy_states[0].visual_status_mask == 0b11101,
			"Enemy delta must preserve the visual status mask through baseline."
		)
		_expect(
			repeated_enemy_states[0].locomotion_state
				== SnapshotManager.ENEMY_LOCOMOTION_MOVING,
			"Enemy delta must preserve locomotion through its baseline."
		)
	enemy_state.position += Vector2(0.01, 0.0)
	var sub_quantum_enemy_delta := delta_enemy_mgr.encode_enemy_snapshots_for_peer(
		20,
		[enemy_state],
		false
	)
	_expect(
		sub_quantum_enemy_delta.size() == repeated_enemy_delta.size(),
		"Enemy motion below the 0.1-pixel wire quantum must not emit a redundant position field."
	)
	var sub_quantum_enemy_states := delta_enemy_mgr.decode_enemy_snapshots_with_baseline(
		sub_quantum_enemy_delta
	)
	_expect(
		sub_quantum_enemy_states.size() == 1
		and sub_quantum_enemy_states[0].position.distance_to(Vector2(88.0, 99.0)) < 0.01,
		"Sub-quantum motion must preserve the receiver's last representable position."
	)
	var enemy_copy_sender := SnapshotManager.new()
	var enemy_copy_receiver := SnapshotManager.new()
	var reused_enemy_state := SnapshotManager.EnemyState.new()
	reused_enemy_state.net_id = 19
	reused_enemy_state.position = Vector2(7.0, 8.0)
	reused_enemy_state.velocity = Vector2.ZERO
	reused_enemy_state.locomotion_state = SnapshotManager.ENEMY_LOCOMOTION_IDLE
	reused_enemy_state.health = 12
	enemy_copy_receiver.decode_enemy_snapshots_with_baseline(
		enemy_copy_sender.encode_enemy_snapshots_for_peer(40, [reused_enemy_state], true)
	)
	reused_enemy_state.position = Vector2(27.0, 38.0)
	reused_enemy_state.velocity = Vector2(-3.0, 2.0)
	reused_enemy_state.locomotion_state = SnapshotManager.ENEMY_LOCOMOTION_MOVING
	reused_enemy_state.health = 9
	var reused_enemy_delta := enemy_copy_sender.encode_enemy_snapshots_for_peer(40, [reused_enemy_state], false)
	var reused_enemy_states := enemy_copy_receiver.decode_enemy_snapshots_with_baseline(reused_enemy_delta)
	_expect(
		reused_enemy_states.size() == 1
		and reused_enemy_states[0].position.distance_to(reused_enemy_state.position) < 0.12
		and reused_enemy_states[0].velocity.distance_to(reused_enemy_state.velocity) < 0.12
		and reused_enemy_states[0].locomotion_state
			== SnapshotManager.ENEMY_LOCOMOTION_MOVING
		and reused_enemy_states[0].health == 9,
		"Enemy send baselines must store state copies, not references to reused state objects."
	)
	var moved_enemy_state := SnapshotManager.EnemyState.new()
	moved_enemy_state.net_id = 7
	moved_enemy_state.position = Vector2(91.0, 100.0)
	moved_enemy_state.velocity = Vector2.RIGHT
	moved_enemy_state.locomotion_state = SnapshotManager.ENEMY_LOCOMOTION_MOVING
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


func _has_active_damage_number_text(game: StandardGame, expected_text: String) -> bool:
	if game == null or game.damage_number_pool == null:
		return false
	return game.damage_number_pool.has_active_text(expected_text)


func _bind_multiplayer_runtime(
	mp_game,
	game: CombatRuntimeBase
) -> void:
	if mp_game == null or game == null:
		return
	_bind_mp_game_coordinators(mp_game, game)
	var gameplay_gateway := game.get_multiplayer_gameplay_gateway()
	var mode_adapter := game.get_multiplayer_mode_adapter()
	mp_game.game = game
	mp_game._gameplay_gateway = gameplay_gateway
	mp_game._mode_adapter = mode_adapter
	mp_game.tower_mode_adapter = (
		mode_adapter as TowerDefenseMultiplayerModeAdapter
	)
	if gameplay_gateway != null:
		gameplay_gateway.attach_multiplayer_session(mp_game)
	if mode_adapter != null:
		mode_adapter.attach_multiplayer_session(mp_game)


func _bind_mp_game_coordinators(
	mp_game,
	game: CombatRuntimeBase = null
) -> MpPlayerCoordinator:
	var session_coordinator := (
		mp_game.get_node("SessionCoordinator") as MpSessionCoordinator
	)
	mp_game.session_coordinator = session_coordinator
	var player_coordinator := (
		mp_game.get_node("PlayerCoordinator") as MpPlayerCoordinator
	)
	mp_game.player_coordinator = player_coordinator
	var enemy_coordinator := (
		mp_game.get_node("EnemyCoordinator") as MpEnemyCoordinator
	)
	mp_game.enemy_coordinator = enemy_coordinator
	var projectile_coordinator := (
		mp_game.get_node("ProjectileCoordinator") as MpProjectileCoordinator
	)
	mp_game.projectile_coordinator = projectile_coordinator
	if game != null:
		session_coordinator.bind_runtime(game)
		player_coordinator.bind_runtime(game)
		enemy_coordinator.bind_runtime(game)
		projectile_coordinator.bind_runtime(game)
		enemy_coordinator.bind_damage_dependencies(projectile_coordinator, mp_game)
	return player_coordinator


func _prepare_direct_enemy_spawn_points(game: StandardGame) -> bool:
	if game == null:
		return false
	var campaign_waves: Array = game.get("waves")
	if campaign_waves.is_empty():
		return false
	var wave_config := campaign_waves[0] as WaveConfig
	if wave_config == null:
		return false
	return bool(game.call("_resolve_wave_spawn_points", wave_config))


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _wait_process_frames(frame_count: int) -> void:
	for _frame_index in range(frame_count):
		await process_frame


func _disable_tower_fixture_background_loads(game: TowerDefenseGame) -> void:
	if game == null:
		return
	var fate_coordinator := game.get_node_or_null("FateCoordinator") as FateCoordinator
	if fate_coordinator != null:
		fate_coordinator.elite_enemy_config_loads_requested = true


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
