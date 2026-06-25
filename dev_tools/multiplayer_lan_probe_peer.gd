extends SceneTree

const MP_GAME_SCENE := preload("res://scene/multiplayer/mp_game.tscn")
const BASIC_ENEMY_CONFIG := preload("res://resources/config/enemies/yuanshi_insect_basic.tres")
const LINGLAN_BOSS_ENTRY := preload("res://resources/config/bosses/boss_01_linglan.tres")
const XIRANG_DROP_SCENE := preload("res://scene/xirang_drop.tscn")

const STATE_HOSTING_LAN := 1
const STATE_LOADING_GAME := 4
const STATE_IN_GAME := 5
const DEFAULT_TIMEOUT_SECONDS := 12.0
const DEFAULT_RUN_SECONDS := 3.0
const PROBE_XIRANG_AMOUNT := 7
const PROBE_MODE_LAN := "lan"
const PROBE_MODE_RELAY := "relay"
const CLIENT2_PLAYER_NAME := "client2"
const CLIENT4_PLAYER_NAME := "client4"
const PROBE_SCENARIO_FULL := "full"
const PROBE_SCENARIO_LEAVE := "leave"
const PROBE_SCENARIO_WAVE := "wave"
const PROBE_SCENARIO_BOSS := "boss"
const PROBE_OWNED_ROOT_NODE_NAMES := {
	"MpGame": true,
	"Game": true,
	"MultiplayerLobby": true,
}

var failures: Array[String] = []
var probe_scenario := PROBE_SCENARIO_FULL


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var options := _parse_probe_options()
	var role := str(options.get("role", ""))
	var port := int(options.get("port", "29170"))
	var expected_players := int(options.get("expected_players", "4"))
	var timeout_seconds := float(options.get("timeout_seconds", str(DEFAULT_TIMEOUT_SECONDS)))
	var run_seconds := float(options.get("run_seconds", str(DEFAULT_RUN_SECONDS)))
	var linger_seconds := float(options.get("linger_seconds", "0.0"))
	var events_enabled := _parse_bool(str(options.get("events", "false")))
	var host_ip := str(options.get("host", "127.0.0.1"))
	var mode := str(options.get("mode", PROBE_MODE_LAN)).strip_edges().to_lower()
	var relay_host_peer_id := int(options.get("relay_host_peer_id", "0"))
	var player_name := str(options.get("name", "Probe%s" % role.capitalize()))
	probe_scenario = str(options.get("scenario", PROBE_SCENARIO_FULL)).strip_edges().to_lower()
	if probe_scenario.is_empty():
		probe_scenario = PROBE_SCENARIO_FULL

	var net_manager := root.get_node_or_null("NetManager")
	if net_manager == null:
		_fail("NetManager autoload is missing.")
		_finish()
		return
	net_manager.local_player_name = player_name

	match role:
		"host":
			await _run_host(
				net_manager,
				mode,
				host_ip,
				port,
				expected_players,
				timeout_seconds,
				run_seconds,
				linger_seconds
			)
		"client":
			await _run_client(
				net_manager,
				mode,
				host_ip,
				port,
				relay_host_peer_id,
				expected_players,
				timeout_seconds,
				run_seconds,
				linger_seconds,
				events_enabled
			)
		_:
			_fail("Unsupported probe role: %s" % role)

	if net_manager.has_method("disconnect_from_game"):
		net_manager.disconnect_from_game()
	await _wait_frames(3)
	await _cleanup_current_scene()
	_finish()


func _run_host(
	net_manager: Node,
	mode: String,
	host_ip: String,
	port: int,
	expected_players: int,
	timeout_seconds: float,
	run_seconds: float,
	linger_seconds: float
) -> void:
	var err: Error = OK
	if mode == PROBE_MODE_RELAY:
		err = net_manager.host_create_relay_room(host_ip, port)
	else:
		err = net_manager.host_create_lan_server(port)
	if err != OK:
		_fail("Host failed to create %s connection: %s" % [mode, error_string(err)])
		return
	if mode == PROBE_MODE_RELAY:
		if not await _wait_for_exact_connection_state(net_manager, STATE_HOSTING_LAN, timeout_seconds):
			_print_peer_debug("RELAY_PROBE_HOST_TIMEOUT", net_manager)
			_fail("Relay host did not finish connecting to relay.")
			return
		var host_peer_id := int(net_manager.get_host_peer_id())
		if host_peer_id <= 1:
			_fail("Relay host peer id must be a real relay client id, saw %d." % host_peer_id)
			return
		print("RELAY_PROBE_HOST_READY host_peer_id=%d" % host_peer_id)
	if not await _wait_for_player_count(net_manager, expected_players, timeout_seconds):
		_fail(
			"Host timed out waiting for %d players; saw %d."
			% [expected_players, _get_connected_player_count(net_manager)]
		)
		return
	net_manager.host_start_game()
	if not await _wait_for_connection_state(net_manager, STATE_LOADING_GAME, 3.0):
		_fail("Host did not enter loading state.")
		return
	await _run_mp_game_probe(net_manager, expected_players, true, run_seconds, linger_seconds)


func _run_client(
	net_manager: Node,
	mode: String,
	host_ip: String,
	port: int,
	relay_host_peer_id: int,
	expected_players: int,
	timeout_seconds: float,
	run_seconds: float,
	linger_seconds: float,
	events_enabled: bool
) -> void:
	var err: Error = OK
	if mode == PROBE_MODE_RELAY:
		if relay_host_peer_id <= 1:
			_fail("Relay client missing valid host peer id.")
			return
		err = net_manager.client_join_relay_room(host_ip, port, relay_host_peer_id)
	else:
		err = net_manager.client_connect_lan(host_ip, port)
	if err != OK:
		_fail("Client failed to connect to %s host: %s" % [mode, error_string(err)])
		return
	if not await _wait_for_player_count(net_manager, expected_players, timeout_seconds):
		_fail(
			"Client timed out waiting for %d players; saw %d."
			% [expected_players, _get_connected_player_count(net_manager)]
		)
		return
	if not await _wait_for_connection_state(net_manager, STATE_LOADING_GAME, timeout_seconds):
		_fail("Client did not receive Host start-game event.")
		return
	await _run_mp_game_probe(
		net_manager,
		expected_players,
		false,
		run_seconds,
		linger_seconds,
		events_enabled
	)


func _run_mp_game_probe(
	net_manager: Node,
	expected_players: int,
	is_host_probe: bool,
	run_seconds: float,
	keepalive_seconds: float = 0.0,
	events_enabled: bool = false
) -> void:
	var mp_game := MP_GAME_SCENE.instantiate()
	if mp_game == null:
		_fail("MpGame scene did not instantiate.")
		return
	root.add_child(mp_game)
	current_scene = mp_game
	if not await _wait_for_connection_state(net_manager, STATE_IN_GAME, 3.0):
		_fail("MpGame did not mark NetManager in-game.")
		mp_game.queue_free()
		return
	var game := mp_game.get("game") as Game
	if game == null or not is_instance_valid(game):
		_fail("MpGame did not create Game.")
		mp_game.queue_free()
		return
	_disable_probe_wave_flow(game)
	if game.peer_players.size() != expected_players:
		_fail(
			"Game expected %d peer players, saw %d."
			% [expected_players, game.peer_players.size()]
		)
	if probe_scenario == PROBE_SCENARIO_LEAVE:
		await _run_leave_probe(net_manager, mp_game, game, is_host_probe)
		_detach_probe_scene_disconnect_handlers(net_manager, mp_game, game)
		await _cleanup_probe_game(net_manager, mp_game)
		return
	if probe_scenario == PROBE_SCENARIO_WAVE:
		await _run_wave_probe(net_manager, mp_game, game, is_host_probe)
		_detach_probe_scene_disconnect_handlers(net_manager, mp_game, game)
		await _cleanup_probe_game(net_manager, mp_game)
		return
	if probe_scenario == PROBE_SCENARIO_BOSS:
		await _run_boss_probe(mp_game, game, is_host_probe)
		_detach_probe_scene_disconnect_handlers(net_manager, mp_game, game)
		await _cleanup_probe_game(net_manager, mp_game)
		return
	await _wait_seconds(1.5)
	if is_host_probe:
		await _run_host_replication_probe(net_manager, mp_game, game)
	else:
		await _run_client_replication_probe(net_manager, mp_game, game, events_enabled)
	await _wait_seconds(run_seconds)
	if is_host_probe:
		var states := game.collect_player_snapshot_states()
		if states.size() != expected_players:
			_fail(
				"Host snapshot expected %d players, saw %d."
				% [expected_players, states.size()]
			)
	else:
		var interpolators := mp_game.get("player_interpolators") as Dictionary
		if interpolators.size() < expected_players - 1:
			_fail(
				"Client expected at least %d remote player interpolators, saw %d."
				% [expected_players - 1, interpolators.size()]
			)
	if events_enabled and not is_host_probe:
		await _run_client_reliable_event_probe(mp_game, game)
	var metrics := mp_game.call("get_snapshot_packet_metrics") as Dictionary
	print(
		"LAN_PROBE_METRICS role=%s players=%d max_player_packet=%d max_enemy_packet=%d"
		% [
			"host" if is_host_probe else "client",
			expected_players,
			int(metrics.get("max_player_snapshot_packet_bytes", 0)),
			int(metrics.get("max_enemy_snapshot_packet_bytes", 0)),
		]
	)
	_detach_probe_scene_disconnect_handlers(net_manager, mp_game, game)
	if keepalive_seconds > 0.0:
		await _wait_seconds(keepalive_seconds)
	_release_probe_input_actions()
	if failures.is_empty() and net_manager.has_method("disconnect_from_game"):
		net_manager.disconnect_from_game()
		await _wait_frames(8)
	if is_instance_valid(mp_game):
		mp_game.queue_free()
		await _wait_cleanup_frames(8)
	await _cleanup_current_scene()


func _run_leave_probe(
	net_manager: Node,
	_mp_game: Node,
	game: Game,
	is_host_probe: bool
) -> void:
	var leaving_peer_id := _get_peer_id_by_name(net_manager, CLIENT4_PLAYER_NAME)
	if leaving_peer_id <= 0:
		_fail("Leave probe could not find client4 peer id.")
		return
	if net_manager.local_player_name == CLIENT4_PLAYER_NAME:
		await _wait_seconds(1.0)
		print("LAN_PROBE_EVENT leave_client_disconnect peer=%d" % leaving_peer_id)
		net_manager.disconnect_from_game()
		return
	if is_host_probe:
		if not await _wait_for_peer_removed_from_host(net_manager, game, leaving_peer_id, 8.0):
			_fail("Host did not clear leaving client4.")
			return
		print("LAN_PROBE_EVENT host_peer_left_confirmed peer=%d" % leaving_peer_id)
		await _wait_seconds(3.0)
		return
	if not await _wait_for_peer_removed_from_client(game, leaving_peer_id, 10.0):
		_fail("Client did not clear leaving client4.")
		return
	print("LAN_PROBE_EVENT client_peer_left_confirmed peer=%d" % leaving_peer_id)
	await _wait_seconds(4.0)


func _run_wave_probe(
	_net_manager: Node,
	mp_game: Node,
	game: Game,
	is_host_probe: bool
) -> void:
	_configure_probe_wave_flow(game)
	await _wait_seconds(1.0)
	if is_host_probe:
		await _run_host_wave_probe(game)
	else:
		await _run_client_wave_probe(mp_game, game)


func _run_boss_probe(mp_game: Node, game: Game, is_host_probe: bool) -> void:
	_configure_probe_boss_flow(game)
	await _wait_seconds(1.0)
	if is_host_probe:
		await _run_host_boss_probe(game)
	else:
		await _run_client_boss_probe(mp_game, game)


func _run_host_wave_probe(game: Game) -> void:
	game.call("_begin_wave", 0)
	if not await _wait_for_game_wave_state(game, Game.WaveState.WAVE_ACTIVE, 3.0):
		_fail("Host wave probe did not enter wave active state.")
		return
	if int(game.current_wave_total) != 1:
		_fail("Host wave probe expected one enemy, saw %d." % int(game.current_wave_total))
		return
	var enemy_id := await _wait_for_first_host_enemy_net_id(game, 5.0)
	if enemy_id <= 0:
		_fail("Host wave probe did not spawn a networked enemy.")
		return
	print("LAN_PROBE_EVENT host_wave_enemy_spawned net_id=%d" % enemy_id)

	await _wait_seconds(0.5)
	var enemy := game.get_enemy_for_net_id(enemy_id)
	if enemy == null or not is_instance_valid(enemy):
		_fail("Host wave probe enemy disappeared before damage.")
		return
	enemy.apply_damage(99999)
	if not await _wait_for_host_enemy_removed(game, enemy_id, 8.0):
		_fail("Host wave probe enemy was not removed after defeat.")
		return
	if not await _wait_for_game_wave_state(game, Game.WaveState.INTERMISSION, 5.0):
		_fail("Host wave probe did not enter intermission.")
		return
	print("LAN_PROBE_EVENT host_wave_intermission_confirmed")
	await _wait_seconds(1.0)


func _run_client_wave_probe(mp_game: Node, game: Game) -> void:
	if not await _wait_for_game_wave_state(game, Game.WaveState.WAVE_ACTIVE, 6.0):
		_fail("Client wave probe did not receive wave start.")
		return
	if not await _wait_for_wave_hud_text_contains(game, "第 1 波", 2.0):
		_fail("Client wave probe HUD did not show wave 1.")
		return
	var enemy_id := await _wait_for_first_client_enemy_id(mp_game, 6.0)
	if enemy_id <= 0:
		_fail("Client wave probe did not receive wave enemy spawn.")
		return
	print("LAN_PROBE_EVENT client_wave_enemy_spawned net_id=%d" % enemy_id)
	if not await _wait_for_client_enemy_removed(mp_game, enemy_id, 10.0):
		_fail("Client wave probe did not receive wave enemy removal.")
		return
	if not await _wait_for_game_wave_state(game, Game.WaveState.INTERMISSION, 6.0):
		_fail("Client wave probe did not receive intermission.")
		return
	if not await _wait_for_merchant_active(game, true, 2.0):
		_fail("Client wave probe merchant did not become active.")
		return
	print("LAN_PROBE_EVENT client_wave_intermission_confirmed")
	await _wait_seconds(4.0)


func _run_host_boss_probe(game: Game) -> void:
	game.multiplayer_enemy_spawned.connect(
		func(net_id: int, enemy_config: EnemyConfig, _spawn_position: Vector2) -> void:
			var config_path := enemy_config.resource_path if enemy_config != null else ""
			print("LAN_PROBE_EVENT host_boss_enemy_spawn_signal net_id=%d config=%s" % [net_id, config_path])
	)
	game.multiplayer_boss_started.connect(
		func(net_id: int, boss_config: BossConfig, _spawn_position: Vector2) -> void:
			var config_path := boss_config.resource_path if boss_config != null else ""
			print("LAN_PROBE_EVENT host_boss_started_signal net_id=%d config=%s" % [net_id, config_path])
	)
	game.call("_enter_pre_flow_step", LINGLAN_BOSS_ENTRY)
	await _wait_frames(2)
	if not await _wait_for_game_wave_state(game, Game.WaveState.BOSS_INTRO, 4.0):
		_fail("Host boss probe did not enter boss intro.")
		return
	print("LAN_PROBE_EVENT host_boss_intro_confirmed")
	game.call("_on_linglan_boss_intro_finished")
	if not await _wait_for_game_wave_state(game, Game.WaveState.BOSS_ACTIVE, 4.0):
		_fail("Host boss probe did not activate boss.")
		return
	var boss_id := await _wait_for_first_host_enemy_net_id(game, 4.0)
	if boss_id <= 0:
		_fail("Host boss probe did not register a networked boss.")
		return
	var boss := game.get_enemy_for_net_id(boss_id) as LinglanBoss
	if boss == null or not is_instance_valid(boss):
		_fail("Host boss probe missing Linglan boss instance.")
		return
	print("LAN_PROBE_EVENT host_boss_active net_id=%d" % boss_id)
	await _wait_seconds(2.0)

	var previous_health := boss.current_health
	boss.apply_damage(maxi(previous_health / 4, 1))
	if not await _wait_for_enemy_health_below(boss, previous_health, 2.0):
		_fail("Host boss probe did not apply partial boss damage.")
		return
	await _wait_seconds(3.0)

	if boss != null and is_instance_valid(boss):
		boss.apply_damage(boss.current_health)
	if not await _wait_for_game_wave_state(game, Game.WaveState.VICTORY, 6.0):
		_fail("Host boss probe did not enter victory after boss defeat.")
		return
	print("LAN_PROBE_EVENT host_boss_victory_confirmed")


func _run_client_boss_probe(mp_game: Node, game: Game) -> void:
	if not await _wait_for_game_wave_state(game, Game.WaveState.BOSS_INTRO, 6.0):
		_fail("Client boss probe did not receive boss intro.")
		return
	print("LAN_PROBE_EVENT client_boss_intro_confirmed")
	if not await _wait_for_game_wave_state(game, Game.WaveState.BOSS_ACTIVE, 8.0):
		_fail("Client boss probe did not receive boss active state.")
		return
	var boss_id := await _wait_for_first_client_enemy_id(mp_game, 8.0)
	if boss_id <= 0:
		_fail("Client boss probe did not receive boss spawn.")
		return
	var boss := game.linglan_boss
	if boss == null or not is_instance_valid(boss):
		_fail("Client boss probe did not bind Linglan boss proxy.")
		return
	print("LAN_PROBE_EVENT client_boss_active net_id=%d" % boss_id)

	var previous_health := boss.current_health
	if not await _wait_for_boss_health_below(game, previous_health, 8.0):
		_fail("Client boss probe did not receive boss health sync.")
		return
	print("LAN_PROBE_EVENT client_boss_health_confirmed")

	if not await _wait_for_game_wave_state(game, Game.WaveState.VICTORY, 10.0):
		_fail("Client boss probe did not receive victory after boss defeat.")
		return
	print("LAN_PROBE_EVENT client_boss_victory_confirmed")
	await _wait_seconds(2.0)


func _cleanup_probe_game(net_manager: Node, mp_game) -> void:
	_release_probe_input_actions()
	if failures.is_empty() and net_manager.has_method("disconnect_from_game"):
		net_manager.disconnect_from_game()
		await _wait_frames(8)
	if is_instance_valid(mp_game):
		mp_game.queue_free()
		await _wait_cleanup_frames(8)
	await _cleanup_current_scene()


func _run_host_replication_probe(net_manager: Node, mp_game: Node, game: Game) -> void:
	var client2_peer_id := _get_peer_id_by_name(net_manager, CLIENT2_PLAYER_NAME)
	if client2_peer_id <= 0:
		_fail("Host replication probe could not find client2 peer id.")
		return

	var client2_player := game.get_player_for_peer(client2_peer_id) as Player
	if client2_player == null or not is_instance_valid(client2_player):
		_fail("Host replication probe missing client2 player node.")
		return
	var initial_position := client2_player.global_position
	if not await _wait_for_player_position_delta(client2_player, initial_position, 6.0, 8.0):
		_fail("Host did not receive client2 movement input.")
		return
	print("LAN_PROBE_EVENT host_motion_confirmed peer=%d" % client2_peer_id)

	var spawned_enemy_id := await _spawn_host_probe_enemy(game)
	if spawned_enemy_id <= 0:
		return
	print("LAN_PROBE_EVENT host_enemy_spawned net_id=%d" % spawned_enemy_id)
	if not await _run_host_projectile_hit_probe(mp_game, game, client2_peer_id, spawned_enemy_id):
		return
	await _wait_seconds(2.5)
	var spawned_enemy := game.get_enemy_for_net_id(spawned_enemy_id)
	if spawned_enemy == null or not is_instance_valid(spawned_enemy):
		_fail("Host probe enemy disappeared before explicit removal.")
		return
	spawned_enemy.queue_free()
	if not await _wait_for_host_enemy_removed(game, spawned_enemy_id, 2.0):
		_fail("Host probe enemy net id was not cleared after removal.")
		return
	print("LAN_PROBE_EVENT host_enemy_removed net_id=%d" % spawned_enemy_id)

	var revision_before := int(mp_game.get("_xirang_revision"))
	var orb_id := int(mp_game.get("_next_xirang_orb_id"))
	var drop := XIRANG_DROP_SCENE.instantiate() as XirangDrop
	if drop == null:
		_fail("Host probe could not instantiate xirang drop.")
		return
	game.enemy_container.add_child(drop)
	drop.global_position = game.player.global_position + Vector2(48.0, -24.0)
	mp_game.call("register_xirang_orb", drop, PROBE_XIRANG_AMOUNT)
	var orbs := mp_game.get("_xirang_orbs") as Dictionary
	if not orbs.has(orb_id):
		_fail("Host probe xirang orb was not registered.")
		return
	if not await _wait_for_mp_game_int_at_least(
		mp_game,
		"_xirang_revision",
		revision_before + 1,
		5.0
	):
		_fail("Host did not receive client xirang orb collection.")
		return
	print("LAN_PROBE_EVENT host_xirang_confirmed orb_id=%d" % orb_id)
	if not await _wait_for_player_dead(client2_player, 10.0):
		_fail("Host did not observe client2 death.")
		return
	print("LAN_PROBE_EVENT host_death_confirmed peer=%d" % client2_peer_id)
	if not await _wait_for_player_revived(client2_player, 14.0):
		_fail("Host did not revive client2.")
		return
	if not await _wait_for_player_invincibility_clear(client2_player, 5.0):
		_fail("Host client2 invincibility did not clear after revive.")
		return
	print("LAN_PROBE_EVENT host_revive_confirmed peer=%d" % client2_peer_id)


func _run_host_projectile_hit_probe(
	mp_game: Node,
	game: Game,
	owner_peer_id: int,
	enemy_net_id: int
) -> bool:
	var enemy := game.get_enemy_for_net_id(enemy_net_id)
	if enemy == null or not is_instance_valid(enemy):
		_fail("Host projectile hit probe missing enemy.")
		return false
	var health_before := enemy.current_health
	if health_before <= 1:
		_fail("Host projectile hit probe enemy health is too low.")
		return false
	if not await _wait_for_enemy_health_below(enemy, health_before, 6.0):
		_fail("Host did not apply client projectile hit report.")
		return false
	var projectile_id := _get_latest_projectile_record_for_peer(mp_game, owner_peer_id)
	print(
		"LAN_PROBE_EVENT host_projectile_hit_confirmed projectile_id=%d enemy=%d health=%d"
		% [projectile_id, enemy_net_id, enemy.current_health]
	)
	return true


func _run_client_replication_probe(
	net_manager: Node,
	mp_game: Node,
	game: Game,
	collect_orb: bool
) -> void:
	if collect_orb:
		await _drive_local_player_motion(mp_game, game)

	var enemy_id := await _wait_for_first_client_enemy_id(mp_game, 4.0)
	if enemy_id <= 0:
		_fail("Client did not receive probe enemy spawn.")
		return
	print("LAN_PROBE_EVENT client_enemy_spawned net_id=%d" % enemy_id)
	if collect_orb:
		await _run_client_projectile_hit_probe(mp_game, game, enemy_id)
	if not await _wait_for_client_enemy_removed(mp_game, enemy_id, 7.0):
		_fail("Client did not receive probe enemy removal.")
		return
	print("LAN_PROBE_EVENT client_enemy_removed net_id=%d" % enemy_id)

	var player := game.player as Player
	if player == null or not is_instance_valid(player):
		_fail("Client replication probe missing local player.")
		return
	var xirang_before := player.current_xirang
	var orb := await _wait_for_first_xirang_orb(mp_game, 4.0)
	var orb_id := int(orb.get("id", 0))
	var amount := int(orb.get("amount", 0))
	if orb_id <= 0 or amount <= 0:
		_fail("Client did not receive probe xirang orb.")
		return
	if collect_orb:
		await _wait_seconds(0.25)
		mp_game.call("request_xirang_orb_collected", orb_id)
	if not await _wait_for_player_xirang_at_least(player, xirang_before + amount, 5.0):
		_fail("Client did not receive probe xirang grant.")
		return
	print(
		"LAN_PROBE_EVENT client_xirang_confirmed orb_id=%d current_xirang=%d"
		% [orb_id, player.current_xirang]
	)
	if not collect_orb:
		await _run_remote_client2_death_view_probe(net_manager, game)


func _run_client_projectile_hit_probe(mp_game: Node, game: Game, enemy_id: int) -> void:
	var player := game.player as Player
	if player == null or not is_instance_valid(player):
		_fail("Client projectile hit probe missing local player.")
		return
	var enemy := _get_valid_client_enemy(mp_game, enemy_id)
	if enemy == null:
		_fail("Client projectile hit probe missing enemy.")
		return
	await _wait_seconds(0.5)
	var previous_ids := _get_projectile_ids_for_peer(mp_game, int(player.peer_id))
	var warmup_spawned := bool(player.call("_spawn_bullet", Vector2.LEFT))
	if not warmup_spawned:
		_fail("Client projectile hit probe could not spawn warmup bullet.")
		return
	var warmup_projectile_id := await _wait_for_new_projectile_id_for_peer(
		mp_game,
		int(player.peer_id),
		previous_ids,
		3.0
	)
	if warmup_projectile_id <= 0:
		_fail("Client projectile hit probe did not register warmup projectile.")
		return
	await _wait_seconds(0.2)
	var direction := (enemy.global_position - player.global_position).normalized()
	if direction == Vector2.ZERO:
		direction = Vector2.RIGHT
	previous_ids = _get_projectile_ids_for_peer(mp_game, int(player.peer_id))
	var spawned := bool(player.call("_spawn_bullet", direction))
	if not spawned:
		_fail("Client projectile hit probe could not spawn bullet.")
		return
	var projectile_id := await _wait_for_new_projectile_id_for_peer(
		mp_game,
		int(player.peer_id),
		previous_ids,
		3.0
	)
	if projectile_id <= 0:
		_fail("Client projectile hit probe did not register local projectile.")
		return
	var health_before := enemy.current_health
	mp_game.call(
		"request_enemy_hit_report",
		projectile_id,
		int(player.peer_id),
		enemy_id,
		player.attack_damage,
		direction
	)
	if not await _wait_for_enemy_health_below(enemy, health_before, 6.0):
		_fail("Client did not receive projectile damage confirmation.")
		return
	print(
		"LAN_PROBE_EVENT client_projectile_hit_confirmed projectile_id=%d enemy=%d health=%d"
		% [projectile_id, enemy_id, enemy.current_health]
	)


func _run_client_reliable_event_probe(mp_game: Node, game: Game) -> void:
	var player := game.player as Player
	if player == null or not is_instance_valid(player):
		_fail("Reliable event probe missing local player.")
		return

	var base_xirang := player.current_xirang
	mp_game.call("request_multiplayer_cheat_xirang")
	if not await _wait_for_player_xirang_at_least(player, base_xirang + 1000, 5.0):
		_fail("Reliable event probe timed out waiting for cheat xirang confirm.")
		return
	print("LAN_PROBE_EVENT cheat_confirmed current_xirang=%d" % player.current_xirang)

	var attack_before := player.attack_damage
	var xirang_before_upgrade := player.current_xirang
	mp_game.call("request_multiplayer_upgrade", RunStateStore.StatType.ATTACK)
	if not await _wait_for_player_attack_above(player, attack_before, 5.0):
		_fail("Reliable event probe timed out waiting for upgrade confirm.")
		return
	if player.current_xirang >= xirang_before_upgrade:
		_fail("Reliable event probe upgrade did not deduct xirang.")
		return
	print(
		"LAN_PROBE_EVENT upgrade_confirmed attack=%d current_xirang=%d"
		% [player.attack_damage, player.current_xirang]
	)

	var xirang_before_skill := player.current_xirang
	mp_game.call("request_multiplayer_skill1_purchase")
	if not await _wait_for_player_skill1(player, 5.0):
		_fail("Reliable event probe timed out waiting for skill1 purchase confirm.")
		return
	if player.current_xirang >= xirang_before_skill:
		_fail("Reliable event probe skill1 purchase did not deduct xirang.")
		return
	print("LAN_PROBE_EVENT skill1_confirmed current_xirang=%d" % player.current_xirang)
	await _run_client_death_revive_probe(mp_game, game)


func _run_client_death_revive_probe(mp_game: Node, game: Game) -> void:
	var player := game.player as Player
	if player == null or not is_instance_valid(player):
		_fail("Death/revive probe missing local player.")
		return
	var local_peer_id := int(game.multiplayer_local_peer_id)
	var source_id := local_peer_id * 1000000 + 770001
	var accepted := bool(mp_game.call(
		"request_multiplayer_player_damage",
		source_id,
		local_peer_id,
		player.max_health + 999,
		&"probe_death"
	))
	if not accepted:
		_fail("Death/revive probe damage request was rejected.")
		return
	if not await _wait_for_player_dead(player, 3.0):
		_fail("Death/revive probe did not enter dead state.")
		return
	print("LAN_PROBE_EVENT death_confirmed peer=%d" % local_peer_id)
	if not await _wait_for_player_revived(player, 13.0):
		_fail("Death/revive probe did not receive Host revive.")
		return
	if not await _wait_for_player_invincibility_clear(player, 5.0):
		_fail("Death/revive probe invincibility did not clear after revive.")
		return
	print(
		"LAN_PROBE_EVENT revive_confirmed peer=%d health=%d"
		% [local_peer_id, player.current_health]
	)


func _run_remote_client2_death_view_probe(net_manager: Node, game: Game) -> void:
	var client2_peer_id := _get_peer_id_by_name(net_manager, CLIENT2_PLAYER_NAME)
	if client2_peer_id <= 0:
		_fail("Remote death view probe could not find client2 peer id.")
		return
	var remote_player := game.get_player_for_peer(client2_peer_id) as Player
	if remote_player == null or not is_instance_valid(remote_player):
		_fail("Remote death view probe missing client2 player node.")
		return
	if not await _wait_for_player_dead(remote_player, 8.0):
		_fail("Remote clients did not see client2 death.")
		return
	print("LAN_PROBE_EVENT remote_death_confirmed peer=%d" % client2_peer_id)
	if not await _wait_for_player_revived(remote_player, 14.0):
		_fail("Remote clients did not see client2 revive.")
		return
	print("LAN_PROBE_EVENT remote_revive_confirmed peer=%d" % client2_peer_id)


func _wait_for_player_xirang_at_least(player: Player, target_xirang: int, timeout_seconds: float) -> bool:
	var end_time := _now_seconds() + timeout_seconds
	while _now_seconds() <= end_time:
		if player != null and is_instance_valid(player) and player.current_xirang >= target_xirang:
			return true
		await process_frame
	return false


func _wait_for_player_attack_above(player: Player, previous_attack: int, timeout_seconds: float) -> bool:
	var end_time := _now_seconds() + timeout_seconds
	while _now_seconds() <= end_time:
		if player != null and is_instance_valid(player) and player.attack_damage > previous_attack:
			return true
		await process_frame
	return false


func _wait_for_player_skill1(player: Player, timeout_seconds: float) -> bool:
	var end_time := _now_seconds() + timeout_seconds
	while _now_seconds() <= end_time:
		if player != null and is_instance_valid(player) and player.has_skill1():
			return true
		await process_frame
	return false


func _wait_for_player_dead(player: Player, timeout_seconds: float) -> bool:
	var end_time := _now_seconds() + timeout_seconds
	while _now_seconds() <= end_time:
		if player != null and is_instance_valid(player) and player.is_dead:
			return true
		await process_frame
	return false


func _wait_for_player_revived(player: Player, timeout_seconds: float) -> bool:
	var end_time := _now_seconds() + timeout_seconds
	while _now_seconds() <= end_time:
		if (
			player != null
			and is_instance_valid(player)
			and not player.is_dead
			and player.current_health > 0
		):
			return true
		await process_frame
	return false


func _wait_for_player_invincibility_clear(player: Player, timeout_seconds: float) -> bool:
	var end_time := _now_seconds() + timeout_seconds
	while _now_seconds() <= end_time:
		if (
			player != null
			and is_instance_valid(player)
			and not player.is_dead
			and player.invincibility_time_left <= 0.0
		):
			return true
		await process_frame
	return false


func _wait_for_player_position_delta(
	player: Player,
	initial_position: Vector2,
	minimum_delta: float,
	timeout_seconds: float
) -> bool:
	var end_time := _now_seconds() + timeout_seconds
	while _now_seconds() <= end_time:
		if (
			player != null
			and is_instance_valid(player)
			and player.global_position.distance_to(initial_position) >= minimum_delta
		):
			return true
		await process_frame
	return false


func _wait_for_host_enemy_removed(game: Game, net_id: int, timeout_seconds: float) -> bool:
	var end_time := _now_seconds() + timeout_seconds
	while _now_seconds() <= end_time:
		if game == null or not is_instance_valid(game) or game.get_enemy_for_net_id(net_id) == null:
			return true
		await process_frame
	return false


func _wait_for_mp_game_int_at_least(
	mp_game: Node,
	property_name: StringName,
	target_value: int,
	timeout_seconds: float
) -> bool:
	var end_time := _now_seconds() + timeout_seconds
	while _now_seconds() <= end_time:
		if mp_game != null and is_instance_valid(mp_game) and int(mp_game.get(property_name)) >= target_value:
			return true
		await process_frame
	return false


func _wait_for_first_client_enemy_id(mp_game: Node, timeout_seconds: float) -> int:
	var end_time := _now_seconds() + timeout_seconds
	while _now_seconds() <= end_time:
		var enemies := mp_game.get("_net_enemies") as Dictionary
		for enemy_id_variant in enemies:
			var enemy_id := int(enemy_id_variant)
			var enemy_variant: Variant = enemies.get(enemy_id)
			if enemy_id > 0 and enemy_variant != null and is_instance_valid(enemy_variant):
				return enemy_id
		await process_frame
	return 0


func _wait_for_client_enemy_removed(mp_game: Node, enemy_id: int, timeout_seconds: float) -> bool:
	var end_time := _now_seconds() + timeout_seconds
	while _now_seconds() <= end_time:
		var enemies := mp_game.get("_net_enemies") as Dictionary
		var enemy_variant: Variant = enemies.get(enemy_id)
		if enemy_variant == null or not is_instance_valid(enemy_variant):
			return true
		await process_frame
	return false


func _wait_for_enemy_health_below(enemy: Enemy, previous_health: int, timeout_seconds: float) -> bool:
	var end_time := _now_seconds() + timeout_seconds
	while _now_seconds() <= end_time:
		if enemy == null or not is_instance_valid(enemy):
			return true
		if enemy.current_health < previous_health:
			return true
		await process_frame
	return false


func _wait_for_boss_health_below(game: Game, previous_health: int, timeout_seconds: float) -> bool:
	var end_time := _now_seconds() + timeout_seconds
	while _now_seconds() <= end_time:
		if game == null or not is_instance_valid(game):
			return false
		var boss := game.linglan_boss
		if boss != null and is_instance_valid(boss) and boss.current_health < previous_health:
			return true
		await process_frame
	return false


func _wait_for_first_host_enemy_net_id(game: Game, timeout_seconds: float) -> int:
	var end_time := _now_seconds() + timeout_seconds
	while _now_seconds() <= end_time:
		for net_id_variant in game.multiplayer_enemies_by_net_id:
			var net_id := int(net_id_variant)
			var enemy := game.get_enemy_for_net_id(net_id)
			if net_id > 0 and enemy != null and is_instance_valid(enemy):
				return net_id
		await process_frame
	return 0


func _wait_for_game_wave_state(game: Game, target_state: int, timeout_seconds: float) -> bool:
	var end_time := _now_seconds() + timeout_seconds
	while _now_seconds() <= end_time:
		if game != null and is_instance_valid(game) and int(game.wave_state) == target_state:
			return true
		await process_frame
	return false


func _wait_for_merchant_active(game: Game, expected_active: bool, timeout_seconds: float) -> bool:
	var end_time := _now_seconds() + timeout_seconds
	while _now_seconds() <= end_time:
		if (
			game != null
			and is_instance_valid(game)
			and game.merchant != null
			and game.merchant.is_active == expected_active
		):
			return true
		await process_frame
	return false


func _wait_for_new_projectile_id_for_peer(
	mp_game: Node,
	peer_id: int,
	previous_ids: Array[int],
	timeout_seconds: float
) -> int:
	var end_time := _now_seconds() + timeout_seconds
	while _now_seconds() <= end_time:
		var projectile_ids := _get_projectile_ids_for_peer(mp_game, peer_id)
		projectile_ids.sort()
		for projectile_id in projectile_ids:
			if not previous_ids.has(projectile_id):
				return projectile_id
		await process_frame
	return 0


func _wait_for_wave_hud_text_contains(
	game: Game,
	expected_text: String,
	timeout_seconds: float
) -> bool:
	var end_time := _now_seconds() + timeout_seconds
	while _now_seconds() <= end_time:
		if (
			game != null
			and is_instance_valid(game)
			and game.wave_hud != null
			and game.wave_hud.status_label != null
			and str(game.wave_hud.status_label.text).contains(expected_text)
		):
			return true
		await process_frame
	return false


func _get_projectile_ids_for_peer(mp_game: Node, peer_id: int) -> Array[int]:
	var result: Array[int] = []
	if mp_game == null or not is_instance_valid(mp_game):
		return result
	var records := mp_game.get("_projectile_records") as Dictionary
	for projectile_id_variant in records:
		var projectile_id := int(projectile_id_variant)
		var record := records.get(projectile_id) as Dictionary
		if not record.is_empty() and int(record.get("owner_peer_id", 0)) == peer_id:
			result.append(projectile_id)
	return result


func _get_latest_projectile_record_for_peer(mp_game: Node, peer_id: int) -> int:
	var projectile_ids := _get_projectile_ids_for_peer(mp_game, peer_id)
	if projectile_ids.is_empty():
		return 0
	projectile_ids.sort()
	return projectile_ids.back()


func _get_valid_client_enemy(mp_game: Node, enemy_id: int) -> Enemy:
	if mp_game == null or not is_instance_valid(mp_game):
		return null
	var enemies := mp_game.get("_net_enemies") as Dictionary
	var enemy_variant: Variant = enemies.get(enemy_id)
	if enemy_variant == null or not is_instance_valid(enemy_variant):
		return null
	return enemy_variant as Enemy


func _wait_for_first_xirang_orb(mp_game: Node, timeout_seconds: float) -> Dictionary:
	var end_time := _now_seconds() + timeout_seconds
	while _now_seconds() <= end_time:
		var orbs := mp_game.get("_xirang_orbs") as Dictionary
		for orb_id_variant in orbs:
			var orb_id := int(orb_id_variant)
			var orb_data := orbs.get(orb_id) as Dictionary
			if orb_id > 0 and not orb_data.is_empty():
				return {
					"id": orb_id,
					"amount": int(orb_data.get("amount", 0)),
				}
		await process_frame
	return {}


func _wait_for_peer_removed_from_host(
	net_manager: Node,
	game: Game,
	peer_id: int,
	timeout_seconds: float
) -> bool:
	var end_time := _now_seconds() + timeout_seconds
	while _now_seconds() <= end_time:
		var connected_players := net_manager.get("connected_players") as Dictionary
		if not connected_players.has(peer_id) and not game.peer_players.has(peer_id):
			return true
		await process_frame
	return false


func _wait_for_peer_removed_from_client(game: Game, peer_id: int, timeout_seconds: float) -> bool:
	var end_time := _now_seconds() + timeout_seconds
	while _now_seconds() <= end_time:
		if not game.peer_players.has(peer_id):
			return true
		await process_frame
	return false


func _wait_for_player_count(net_manager: Node, expected_players: int, timeout_seconds: float) -> bool:
	var end_time := _now_seconds() + timeout_seconds
	while _now_seconds() <= end_time:
		if _get_connected_player_count(net_manager) >= expected_players:
			return true
		await process_frame
	return false


func _wait_for_connection_state(
	net_manager: Node,
	target_state: int,
	timeout_seconds: float
) -> bool:
	var end_time := _now_seconds() + timeout_seconds
	while _now_seconds() <= end_time:
		if int(net_manager.get("connection_state")) >= target_state:
			return true
		await process_frame
	return false


func _wait_for_exact_connection_state(
	net_manager: Node,
	target_state: int,
	timeout_seconds: float
) -> bool:
	var end_time := _now_seconds() + timeout_seconds
	while _now_seconds() <= end_time:
		if int(net_manager.get("connection_state")) == target_state:
			return true
		await process_frame
	return false


func _wait_seconds(seconds: float) -> void:
	var end_time := _now_seconds() + maxf(seconds, 0.0)
	while _now_seconds() <= end_time:
		await process_frame


func _wait_frames(frame_count: int) -> void:
	for _frame_index in range(frame_count):
		await process_frame


func _drive_local_player_motion(mp_game: Node, game: Game) -> void:
	var player := game.player as Player
	if player == null or not is_instance_valid(player):
		_fail("Client motion probe missing local player.")
		return
	for _step in range(8):
		player.global_position += Vector2.RIGHT * 4.0
		player.velocity = Vector2.RIGHT * 120.0
		mp_game.call("_client_send_input_if_needed", 0)
		await _wait_seconds(0.08)
	player.velocity = Vector2.ZERO
	mp_game.call("_client_send_input_if_needed", 0)
	await _wait_seconds(0.2)


func _release_probe_input_actions() -> void:
	Input.action_release("move_left")
	Input.action_release("move_right")
	Input.action_release("move_up")
	Input.action_release("move_down")
	Input.action_release("shoot_left")
	Input.action_release("shoot_right")
	Input.action_release("shoot_up")
	Input.action_release("shoot_down")


func _disable_probe_wave_flow(game: Game) -> void:
	game.auto_start_waves = false
	if game.enemy_spawn_timer != null:
		game.enemy_spawn_timer.stop()
	if game.state_timer != null:
		game.state_timer.stop()


func _configure_probe_wave_flow(game: Game) -> void:
	_disable_probe_wave_flow(game)
	game.waves = _create_probe_waves()
	var flow_graph := FlowGraphConfig.new()
	flow_graph.graph_name = "Probe Flow"
	for wave_config in game.waves:
		flow_graph.steps.append(wave_config)
	if not flow_graph.steps.is_empty():
		flow_graph.start_step = flow_graph.steps[0]
	game.flow_graph = flow_graph
	game.pre_wave_duration = 0.0
	game.current_wave_index = 0
	game.current_wave_total = 0
	game.current_wave_spawned = 0
	game.current_wave_defeated = 0


func _configure_probe_boss_flow(game: Game) -> void:
	_disable_probe_wave_flow(game)
	var boss_resources: Array[Resource] = [LINGLAN_BOSS_ENTRY]
	game.bosses = boss_resources
	var flow_graph := FlowGraphConfig.new()
	flow_graph.graph_name = "Probe Boss Flow"
	flow_graph.start_step = LINGLAN_BOSS_ENTRY
	var flow_steps: Array[FlowStepConfig] = [LINGLAN_BOSS_ENTRY]
	flow_graph.steps = flow_steps
	game.flow_graph = flow_graph
	game.pre_wave_duration = 0.0
	game.current_flow_step = null
	game.next_flow_step_after_rest = null
	game.linglan_boss_started = false
	game.current_wave_index = 0
	game.current_wave_total = 0
	game.current_wave_spawned = 0
	game.current_wave_defeated = 0


func _create_probe_waves() -> Array[WaveConfig]:
	var result: Array[WaveConfig] = []
	for wave_index in range(2):
		var entry := WaveEnemyEntry.new()
		entry.enemy_config = BASIC_ENEMY_CONFIG
		entry.count = 1
		var wave_config := WaveConfig.new()
		wave_config.step_id = StringName("probe_wave_%02d" % (wave_index + 1))
		wave_config.wave_name = "Probe Wave %d" % (wave_index + 1)
		wave_config.enemy_entries = [entry]
		wave_config.spawn_interval = 60.0
		wave_config.spawn_count_per_tick = 1
		wave_config.max_alive_enemies = 1
		wave_config.post_clear_rest_duration = 30.0
		result.append(wave_config)
	for wave_index in range(result.size() - 1):
		var flow_exit := FlowExitConfig.new()
		flow_exit.exit_name = FlowExitConfig.DEFAULT_EXIT_NAME
		flow_exit.target_step_id = result[wave_index + 1].step_id
		result[wave_index].exits = [flow_exit]
	return result


func _detach_probe_scene_disconnect_handlers(net_manager: Node, mp_game, game) -> void:
	if not is_instance_valid(mp_game):
		return
	var connection_callable := Callable(mp_game, "_on_connection_state_changed")
	if net_manager.connection_state_changed.is_connected(connection_callable):
		net_manager.connection_state_changed.disconnect(connection_callable)
	var player_left_callable := Callable(mp_game, "_on_net_player_left")
	if net_manager.player_left.is_connected(player_left_callable):
		net_manager.player_left.disconnect(player_left_callable)
	if is_instance_valid(game):
		var lobby_callable := Callable(mp_game, "_on_game_return_to_lobby_requested")
		if game.return_to_lobby_requested.is_connected(lobby_callable):
			game.return_to_lobby_requested.disconnect(lobby_callable)


func _cleanup_current_scene() -> void:
	for _cleanup_pass in range(6):
		await _wait_cleanup_frames(4)
		var scene := current_scene
		if scene != null and is_instance_valid(scene):
			current_scene = null
			scene.queue_free()
		for child in root.get_children():
			if child == null or not is_instance_valid(child):
				continue
			if PROBE_OWNED_ROOT_NODE_NAMES.has(str(child.name)):
				child.queue_free()
	await _wait_cleanup_frames(12)


func _wait_cleanup_frames(frame_count: int) -> void:
	for _frame_index in range(frame_count):
		await process_frame
		await physics_frame


func _get_connected_player_count(net_manager: Node) -> int:
	var connected_players := net_manager.get("connected_players") as Dictionary
	return connected_players.size()


func _print_peer_debug(prefix: String, net_manager: Node) -> void:
	var peer := net_manager.multiplayer.multiplayer_peer
	var status := -1
	if peer != null:
		status = int(peer.get_connection_status())
	print(
		"%s state=%d status=%d unique_id=%d peers=%s"
		% [
			prefix,
			int(net_manager.get("connection_state")),
			status,
			int(net_manager.get_local_peer_id()),
			str(net_manager.multiplayer.get_peers()),
		]
	)


func _get_peer_id_by_name(net_manager: Node, player_name: String) -> int:
	var connected_players := net_manager.get("connected_players") as Dictionary
	for peer_id_variant in connected_players:
		var peer_id := int(peer_id_variant)
		if str(connected_players.get(peer_id_variant, "")) == player_name:
			return peer_id
	return 0


func _spawn_host_probe_enemy(game: Game) -> int:
	var previous_ids: Dictionary = {}
	for net_id_variant in game.multiplayer_enemies_by_net_id:
		previous_ids[int(net_id_variant)] = true
	var spawned := bool(game.call("_try_spawn_enemy", BASIC_ENEMY_CONFIG))
	if not spawned:
		_fail("Host probe failed to spawn test enemy.")
		return 0
	await _wait_frames(2)
	for net_id_variant in game.multiplayer_enemies_by_net_id:
		var net_id := int(net_id_variant)
		if net_id > 0 and not previous_ids.has(net_id):
			return net_id
	_fail("Host probe spawned enemy without a new net id.")
	return 0


func _parse_probe_options() -> Dictionary:
	var options: Dictionary = {}
	var args: Array[String] = []
	for arg in OS.get_cmdline_args():
		args.append(arg)
	for arg in OS.get_cmdline_user_args():
		if not args.has(arg):
			args.append(arg)
	for arg in args:
		if not arg.begins_with("--probe-"):
			continue
		var option := arg.substr("--probe-".length())
		var separator_index := option.find("=")
		if separator_index < 0:
			options[option] = "true"
			continue
		var key := option.substr(0, separator_index)
		var value := option.substr(separator_index + 1)
		options[key] = value
	return options


func _parse_bool(raw_value: String) -> bool:
	var normalized := raw_value.strip_edges().to_lower()
	return normalized == "1" or normalized == "true" or normalized == "yes"


func _now_seconds() -> float:
	return Time.get_ticks_msec() / 1000.0


func _fail(message: String) -> void:
	failures.append(message)
	push_error(message)


func _finish() -> void:
	if failures.is_empty():
		print("LAN_PROBE_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)
