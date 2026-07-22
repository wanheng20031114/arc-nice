extends SceneTree

const MP_GAME_SCENE := preload("res://scene/multiplayer/mp_game.tscn")
const BASIC_ENEMY_CONFIG := preload("res://resources/config/enemies/yuanshi_insect_basic.tres")
const LINGLAN_BOSS_ENTRY := preload("res://resources/config/bosses/boss_01_linglan.tres")
const WOOD_MATERIAL := preload("res://resources/config/materials/material_wood.tres")
const PLANK_MATERIAL := preload("res://resources/config/materials/material_plank.tres")

const STATE_HOSTING_LAN := 1
const STATE_LOADING_GAME := 4
const STATE_IN_GAME := 5
const DEFAULT_TIMEOUT_SECONDS := 12.0
const DEFAULT_RUN_SECONDS := 3.0
const PROBE_MODE_LAN := "lan"
const PROBE_MODE_RELAY := "relay"
const CLIENT2_PLAYER_NAME := "client2"
const CLIENT4_PLAYER_NAME := "client4"
const PROBE_SCENARIO_FULL := "full"
const PROBE_SCENARIO_LEAVE := "leave"
const PROBE_SCENARIO_WAVE := "wave"
const PROBE_SCENARIO_BOSS := "boss"
const PROBE_SCENARIO_TOWER_DEFENSE := "tower_defense"
const PROBE_OWNED_ROOT_NODE_NAMES := {
	"MpGame": true,
	"Game": true,
	"GameTowerDefense": true,
	"MultiplayerLobby": true,
}

var failures: Array[String] = []
var probe_scenario := PROBE_SCENARIO_FULL
var probe_game_mode := "standard"
var probe_transport_mode := PROBE_MODE_LAN


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
	probe_transport_mode = mode
	var relay_host_peer_id := int(options.get("relay_host_peer_id", "0"))
	var player_name := str(options.get("name", "Probe%s" % role.capitalize()))
	probe_scenario = str(options.get("scenario", PROBE_SCENARIO_FULL)).strip_edges().to_lower()
	if probe_scenario.is_empty():
		probe_scenario = PROBE_SCENARIO_FULL
	probe_game_mode = str(options.get("game_mode", "standard")).strip_edges().to_lower()
	if probe_game_mode not in ["standard", "tower_defense"]:
		_fail("Unsupported probe game mode: %s" % probe_game_mode)
		_finish()
		return
	if probe_scenario == PROBE_SCENARIO_TOWER_DEFENSE and probe_game_mode != "tower_defense":
		_fail("Tower-defense runtime scenario requires --probe-game_mode=tower_defense.")
		_finish()
		return

	var net_manager := root.get_node_or_null("NetManager")
	if net_manager == null:
		_fail("NetManager autoload is missing.")
		_finish()
		return
	net_manager.local_player_name = player_name
	if probe_game_mode == "tower_defense":
		var character_id := _get_tower_defense_probe_character_id(role, player_name)
		if not bool(net_manager.call("set_local_character_id", character_id, true)):
			_fail("Failed to select tower-defense probe character: %s" % character_id)
			_finish()
			return

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
	if not bool(
		net_manager.call(
			"set_host_game_mode",
			NetManagerStore.game_mode_from_key(probe_game_mode)
		)
	):
		_fail("Host failed to select game mode: %s" % probe_game_mode)
		return
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
	var runtime_load_timeout := 30.0 if probe_game_mode == "tower_defense" else 10.0
	if not await _wait_for_connection_state(
		net_manager,
		STATE_IN_GAME,
		runtime_load_timeout
	):
		_fail("MpGame did not mark NetManager in-game.")
		mp_game.queue_free()
		return
	var game: Variant = mp_game.get("game")
	if game == null or not is_instance_valid(game) or not game is GameRuntimeBase:
		_fail("MpGame did not create a GameRuntimeBase.")
		mp_game.queue_free()
		return
	var expects_tower_defense := probe_game_mode == "tower_defense"
	if bool(game.call("supports_tower_defense")) != expects_tower_defense:
		_fail("MpGame instantiated the wrong runtime for mode %s." % probe_game_mode)
	if expects_tower_defense:
		var local_player := game.get_player_for_peer(int(net_manager.get_local_peer_id())) as Player
		var map_camera := game.get("map_camera") as Camera2D
		if local_player == null or map_camera == null or map_camera.get_parent() != local_player:
			_fail("Tower-defense camera is not parented to this endpoint's local player.")
		elif map_camera.position != Vector2.ZERO:
			_fail("Tower-defense camera did not preserve zero local offset.")
		elif map_camera.zoom != Vector2(2.0, 2.0):
			_fail("Tower-defense camera zoom is not the required 2x value.")
		elif map_camera.position_smoothing_enabled:
			_fail("Tower-defense camera unexpectedly enabled smoothing.")
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
	if probe_scenario == PROBE_SCENARIO_TOWER_DEFENSE:
		await _run_tower_defense_runtime_probe(net_manager, mp_game, game, is_host_probe)
		if is_host_probe and mp_game != null and is_instance_valid(mp_game):
			_validate_and_print_runtime_metrics(mp_game, true, expected_players)
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
		var states: Array = game.collect_player_snapshot_states()
		if states.size() != expected_players:
			_fail(
				"Host snapshot expected %d players, saw %d."
				% [expected_players, states.size()]
			)
	else:
		var interpolators := mp_game.get("player_visual_interpolators") as Dictionary
		if interpolators.size() < expected_players - 1:
			_fail(
				"Client expected at least %d remote player visual interpolators, saw %d."
				% [expected_players - 1, interpolators.size()]
			)
	if events_enabled and not is_host_probe:
		await _run_client_reliable_event_probe(mp_game, game)
	_validate_and_print_runtime_metrics(mp_game, is_host_probe, expected_players)
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


func _validate_and_print_runtime_metrics(
	mp_game: Node,
	is_host_probe: bool,
	expected_players: int
) -> void:
	var metrics := mp_game.call("get_snapshot_packet_metrics") as Dictionary
	var transaction_sample_count := int(metrics.get("transaction_latency_sample_count", 0))
	var transaction_p95_ms := float(metrics.get("transaction_latency_p95_ms", 0.0))
	if probe_scenario == PROBE_SCENARIO_TOWER_DEFENSE and not is_host_probe:
		var latency_limit_ms := 350.0 if probe_transport_mode == PROBE_MODE_RELAY else 100.0
		if transaction_sample_count <= 0 or transaction_p95_ms > latency_limit_ms:
			_fail(
				"Tower-defense warehouse transaction latency exceeded %.0fms: samples=%d p95=%.3fms."
				% [latency_limit_ms, transaction_sample_count, transaction_p95_ms]
			)
	print(
		(
			"LAN_PROBE_METRICS role=%s players=%d max_player_packet=%d "
			+ "max_enemy_packet=%d transaction_samples=%d transaction_p95_ms=%.3f"
		)
		% [
			"host" if is_host_probe else "client",
			expected_players,
			int(metrics.get("max_player_snapshot_packet_bytes", 0)),
			int(metrics.get("max_enemy_snapshot_packet_bytes", 0)),
			transaction_sample_count,
			transaction_p95_ms,
		]
	)


func _run_leave_probe(
	net_manager: Node,
	_mp_game: Node,
	game: Variant,
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
	game: Variant,
	is_host_probe: bool
) -> void:
	_configure_probe_wave_flow(game)
	await _wait_seconds(1.0)
	if is_host_probe:
		await _run_host_wave_probe(game)
	else:
		await _run_client_wave_probe(mp_game, game)


func _run_boss_probe(mp_game: Node, game: Variant, is_host_probe: bool) -> void:
	_configure_probe_boss_flow(game)
	await _wait_seconds(1.0)
	if is_host_probe:
		await _run_host_boss_probe(game)
	else:
		await _run_client_boss_probe(mp_game, game)


func _run_tower_defense_runtime_probe(
	net_manager: Node,
	mp_game: Node,
	game: Variant,
	is_host_probe: bool
) -> void:
	if not bool(game.call("supports_tower_defense")):
		_fail("Tower-defense runtime probe received the standard Game runtime.")
		return
	await _wait_seconds(1.0)
	if not await _exercise_tower_defense_local_character(net_manager, mp_game, game):
		return
	var plant_config := PlantDefenseRegistry.get_config(&"agave_cannon")
	var shared_plant_anchor := _find_shared_multiplayer_plant_anchor(game, plant_config)
	if shared_plant_anchor == Vector2i.MAX:
		_fail("Tower-defense peers could not resolve a shared valid grass anchor.")
		return
	var run_state := root.get_node("RunState") as RunStateStore
	var wood_total_before_warehouse_competition := _count_peer_item_total(
		run_state,
		net_manager.connected_players,
		WOOD_MATERIAL
	)
	if is_host_probe:
		await _run_host_tower_defense_runtime_probe(
			net_manager,
			mp_game,
			game,
			shared_plant_anchor,
			wood_total_before_warehouse_competition
		)
	else:
		await _run_client_tower_defense_runtime_probe(
			net_manager,
			mp_game,
			game,
			shared_plant_anchor,
			wood_total_before_warehouse_competition
		)


func _get_tower_defense_probe_character_id(
	role: String,
	player_name: String
) -> StringName:
	if role == "host":
		return &"weishidaier"
	match player_name:
		"client2":
			return &"hoe_cat"
		"client3":
			return &"tiyi"
		_:
			return &"weishidaier"


func _exercise_tower_defense_local_character(
	net_manager: Node,
	mp_game: Node,
	game: Variant
) -> bool:
	var local_peer_id := int(net_manager.get_local_peer_id())
	var local_player := game.get_player_for_peer(local_peer_id) as Player
	if local_player == null or not is_instance_valid(local_player):
		_fail("Tower-defense character probe could not resolve its local player.")
		return false
	var ammo_player := local_player as AmmoRangedPlayer
	if (
		ammo_player != null
		and (
			ammo_player.ammo_bar == null
			or ammo_player.get_multiplayer_ammo_capacity() <= 0
			or ammo_player.get_multiplayer_current_ammo() < 0
		)
	):
		_fail("Tower-defense ammo HUD is not bound to authoritative ammo state.")
		return false
	var action_started := false
	match local_player.get_character_id():
		&"hoe_cat":
			action_started = bool(mp_game.call("request_hoe_primary_attack", Vector2.RIGHT))
		&"tiyi", &"weishidaier":
			action_started = bool(local_player.call("_spawn_bullet", Vector2.RIGHT))
		_:
			_fail("Tower-defense character probe received an unexpected character id.")
			return false
	if not action_started:
		_fail(
			"Tower-defense local action prediction failed for %s."
			% local_player.get_character_id()
		)
		return false
	await _wait_seconds(0.35)
	print(
		"LAN_PROBE_EVENT td_character_action peer=%d character=%s"
		% [local_peer_id, local_player.get_character_id()]
	)
	return true


func _run_host_tower_defense_runtime_probe(
	net_manager: Node,
	mp_game: Node,
	game: Variant,
	shared_plant_anchor: Vector2i,
	wood_total_before_warehouse_competition: int
) -> void:
	game.call("_apply_base_damage", 7)
	if int(game.current_base_health) != 93:
		_fail("Host base damage did not update tower-defense health to 93.")
		return
	print("LAN_PROBE_EVENT host_td_base_health=%d" % int(game.current_base_health))
	await _wait_seconds(0.5)

	var escaped_enemy_id := await _spawn_host_probe_enemy(game)
	if escaped_enemy_id <= 0:
		return
	await _wait_seconds(1.0)
	var escaped_enemy: Enemy = game.get_enemy_for_net_id(escaped_enemy_id)
	if escaped_enemy == null or not is_instance_valid(escaped_enemy):
		_fail("Host tower-defense escape probe lost its enemy before Home resolution.")
		return
	game.call("_on_enemy_reached_home", escaped_enemy, Vector2i.ZERO)
	if int(game.current_base_health) != 92:
		_fail("Host Home escape did not apply the configured enemy base damage.")
		return
	if not await _wait_for_host_enemy_removed(game, escaped_enemy_id, 3.0):
		_fail("Host Home escape did not clear the enemy network mapping.")
		return
	print("LAN_PROBE_EVENT host_td_enemy_escaped net_id=%d" % escaped_enemy_id)
	for peer_id_variant in net_manager.connected_players:
		var peer_id := int(peer_id_variant)
		if peer_id == int(net_manager.get_local_peer_id()):
			continue
		mp_game.callv("rpc_id", [peer_id, &"net_base_health_changed", 91, 100, 1])
		mp_game.callv("rpc_id", [peer_id, &"net_base_health_changed", 50, 100, 2])
	await _wait_seconds(0.75)

	if not await _wait_for_host_plant_requests(mp_game, net_manager, 101, 5.0):
		_fail("Host did not receive every client's competing plant-placement request.")
		return
	await _wait_seconds(0.5)
	var plant := game.plant_system.get_plant_by_net_id(1) as PlantDefense
	if plant == null or not is_instance_valid(plant):
		_fail("Competing client plant requests did not create authoritative net_id 1.")
		return
	if game.plant_system.plants_by_net_id.size() != 1:
		_fail("Competing requests created more than one plant on the same footprint.")
		return
	if plant.footprint_cells.is_empty() or plant.footprint_cells[0] != shared_plant_anchor:
		_fail("Authoritative plant did not use the clients' shared requested anchor.")
		return
	for peer_id_variant in net_manager.connected_players:
		var peer_id := int(peer_id_variant)
		if peer_id != int(net_manager.get_local_peer_id()):
			mp_game.call("_send_runtime_state_to_peer", peer_id, false)
	await _wait_seconds(0.5)

	var damage_enemy_id := await _spawn_host_probe_enemy(game)
	if damage_enemy_id <= 0:
		return
	var damage_enemy := game.get_enemy_for_net_id(damage_enemy_id) as Enemy
	if damage_enemy == null or not is_instance_valid(damage_enemy):
		_fail("Host lost the authoritative plant-damage probe enemy.")
		return
	damage_enemy.set_physics_process(false)
	if not await _position_enemy_for_clear_plant_shot(plant as AgaveCannon, damage_enemy):
		_fail("Host could not find a clear line for the authoritative plant shot.")
		return
	var enemy_health_before := damage_enemy.current_health
	await _wait_seconds(0.75)
	var agave := plant as AgaveCannon
	agave.pending_target = damage_enemy
	agave.call("_fire_pending_projectile")
	if not await _wait_for_enemy_health_below(damage_enemy, enemy_health_before, 3.0):
		_fail("Host Agave cannonball did not damage its authoritative enemy target.")
		return
	if damage_enemy.current_health != enemy_health_before - agave.config.attack_damage:
		_fail("Host Agave cannonball damage was not applied exactly once.")
		return
	print(
		"LAN_PROBE_EVENT host_td_plant_projectile enemy_id=%d health=%d"
		% [damage_enemy_id, damage_enemy.current_health]
	)
	await _wait_seconds(0.5)

	var health_before_plant_damage := plant.current_health
	plant.receive_damage(10)
	if plant.current_health >= health_before_plant_damage:
		_fail("Host authoritative plant damage was not applied.")
		return
	print("LAN_PROBE_EVENT host_td_plant_health=%d" % plant.current_health)
	await _wait_seconds(0.75)
	game.plant_system.remove_plant_by_net_id(1)
	if damage_enemy != null and is_instance_valid(damage_enemy):
		damage_enemy.queue_free()
	await _wait_seconds(0.75)
	print("LAN_PROBE_EVENT host_td_plant_removed net_id=1")

	if not await _wait_for_host_plant_requests(mp_game, net_manager, 102, 5.0):
		_fail("Host did not receive every client's shared-warehouse placement request.")
		return
	var warehouse := game.plant_system.get_plant_by_net_id(2) as OakWarehouse
	if warehouse == null or not is_instance_valid(warehouse):
		_fail("Competing warehouse placement did not create authoritative net_id 2.")
		return
	if not warehouse.try_add_storage_item_count(WOOD_MATERIAL, 1):
		_fail("Host could not seed the shared warehouse transaction probe.")
		return
	# Keep the original warehouse competition setup deterministic; the second
	# seed below is intentionally left to storage_changed so production verifies
	# the new automatic warehouse broadcast path.
	mp_game.call("_broadcast_warehouse_snapshot", warehouse)
	await _wait_seconds(0.75)
	if not await _wait_for_host_warehouse_transactions(mp_game, net_manager, 5.0):
		_fail("Host did not settle every competing warehouse transaction.")
		return
	if warehouse.get_storage_item(0) != null:
		_fail("Competing shared-warehouse retrieval must consume its only source stack once.")
		return
	var run_state := root.get_node("RunState") as RunStateStore
	if (
		_count_peer_item_total(run_state, net_manager.connected_players, WOOD_MATERIAL)
		!= wood_total_before_warehouse_competition + 1
	):
		_fail("Shared-warehouse competition duplicated or lost the authoritative stack.")
		return
	print("LAN_PROBE_EVENT host_td_warehouse_atomic net_id=2")

	if not await _wait_for_host_plant_requests(mp_game, net_manager, 103, 5.0):
		_fail("Host did not receive every client's wood-station placement request.")
		return
	var station := game.plant_system.get_plant_by_net_id(3) as ProductionBuilding
	if station == null or not is_instance_valid(station):
		_fail("Competing wood-station placement did not create authoritative net_id 3.")
		return
	if not warehouse.try_add_storage_item_count(WOOD_MATERIAL, 1):
		_fail("Host could not seed the multiplayer production cycle.")
		return
	var remote_client_count := _get_connected_player_count(net_manager) - 1
	if not await _wait_for_host_production_results(
		mp_game,
		remote_client_count,
		8.0
	):
		_fail("Host did not settle every competing recipe selection.")
		return
	var recipe_outcomes := _count_host_production_result_reasons(mp_game, 1)
	if (
		int(recipe_outcomes.get(ProductionBuildingProtocol.RESULT_SUCCESS, 0)) != 1
		or int(recipe_outcomes.get(ProductionBuildingProtocol.RESULT_STALE_STATE, 0))
		!= remote_client_count - 1
	):
		_fail(
			"Concurrent recipe selection did not accept exactly one revision winner: %s"
			% str(recipe_outcomes)
		)
		return
	station.advance_shared_production_tick(10.0)
	if (
		warehouse.get_storage_item_total(WOOD_MATERIAL) != 0
		or warehouse.get_storage_item_total(PLANK_MATERIAL) != 2
	):
		_fail("Authoritative multiplayer production did not atomically consume 1 wood and create 2 planks.")
		return
	print("LAN_PROBE_EVENT host_td_production_atomic station=3 warehouse=2")
	if not await _wait_for_authoritative_production_enabled(station, false, 5.0):
		_fail("Host did not accept a revision-current production pause command.")
		return
	if station.production_enabled or not is_zero_approx(station.progress_elapsed_seconds):
		_fail("Multiplayer production pause did not clear the authoritative cycle.")
		return
	if not await _wait_for_authoritative_production_enabled(station, true, 5.0):
		_fail("Host did not receive the designated production resume command.")
		return
	if not station.production_enabled:
		_fail("Multiplayer production did not resume from the Host-confirmed state.")
		return
	await _wait_seconds(0.75)
	game.plant_system.remove_plant_by_net_id(3)
	game.plant_system.remove_plant_by_net_id(2)
	await _wait_seconds(0.75)


func _run_client_tower_defense_runtime_probe(
	net_manager: Node,
	mp_game: Node,
	game: Variant,
	shared_plant_anchor: Vector2i,
	wood_total_before_warehouse_competition: int
) -> void:
	if not await _wait_for_int_property(game, &"current_base_health", 93, 5.0):
		_fail("Client did not receive the Host base-health update.")
		return
	var escaped_enemy_id := await _wait_for_first_client_enemy_id(mp_game, 5.0)
	if escaped_enemy_id <= 0:
		_fail("Client did not receive the tower-defense escape probe enemy.")
		return
	if not await _wait_for_client_enemy_removed(mp_game, escaped_enemy_id, 5.0):
		_fail("Client did not remove the escaped enemy silently.")
		return
	if not await _wait_for_int_property(game, &"current_base_health", 92, 5.0):
		_fail("Client did not receive Home escape base damage.")
		return
	await _wait_seconds(1.0)
	if int(game.current_base_health) != 92 or int(game.base_health_revision) != 2:
		_fail("Client accepted a stale or conflicting base-health revision.")
		return
	print("LAN_PROBE_EVENT client_td_enemy_escaped net_id=%d" % escaped_enemy_id)
	var rejection_state := {&"received": false}
	game.plant_placement_controller.selection_unavailable.connect(
		func() -> void: rejection_state[&"received"] = true
	)
	mp_game.call(
		"_on_local_plant_placement_requested",
		101,
		&"agave_cannon",
		shared_plant_anchor
	)
	var plant := await _wait_for_client_plant(game, 1, 5.0)
	if plant == null:
		_fail("Client did not spawn the authoritative plant replica.")
		return
	var local_player := game.get_player_for_peer(int(net_manager.get_local_peer_id())) as Player
	var won_competition := plant.owner_player == local_player
	if not won_competition:
		if not await _wait_for_dictionary_flag(rejection_state, &"received", 3.0):
			_fail("Losing client did not receive the authoritative placement rejection.")
			return
	elif bool(rejection_state[&"received"]):
		_fail("Winning client unexpectedly received a placement rejection.")
		return
	await _wait_seconds(0.75)
	if game.plant_system.plants_by_net_id.size() != 1:
		_fail("Client runtime-state replay duplicated the authoritative plant replica.")
		return
	var damage_enemy_id := await _wait_for_first_client_enemy_id(mp_game, 5.0)
	if damage_enemy_id <= 0:
		_fail("Client did not receive the plant-damage probe enemy.")
		return
	var damage_enemy := game.get_enemy_for_net_id(damage_enemy_id) as Enemy
	if damage_enemy == null or not is_instance_valid(damage_enemy):
		_fail("Client could not resolve the plant-damage probe enemy.")
		return
	var enemy_health_before := damage_enemy.current_health
	var visual_projectile := await _wait_for_client_plant_projectile_visual(mp_game, 5.0)
	if visual_projectile == null:
		_fail("Client did not receive the unreliable plant projectile visual.")
		return
	if visual_projectile.authoritative_damage or visual_projectile.damage != 0:
		_fail("Client plant projectile visual retained authoritative damage.")
		return
	if not await _wait_for_enemy_health_below(damage_enemy, enemy_health_before, 5.0):
		_fail("Client did not receive Host-authoritative plant damage.")
		return
	if not await _wait_for_plant_health_below(plant, plant.max_health, 5.0):
		_fail("Client did not apply the authoritative plant health revision.")
		return
	if not await _wait_for_client_plant_removed(game, 1, 5.0):
		_fail("Client did not remove the authoritative plant replica.")
		return
	print("LAN_PROBE_EVENT client_td_plant_lifecycle net_id=1")
	mp_game.call(
		"_on_local_plant_placement_requested",
		102,
		&"oak_warehouse",
		shared_plant_anchor
	)
	var warehouse_plant: PlantDefense = await _wait_for_client_plant(game, 2, 5.0)
	var warehouse := warehouse_plant as OakWarehouse
	if warehouse == null:
		_fail("Client did not spawn the authoritative shared warehouse replica.")
		return
	if local_player == null or not is_instance_valid(local_player):
		_fail("Client could not resolve its local player before warehouse interaction.")
		return
	var approach_direction := warehouse.global_position.direction_to(local_player.global_position)
	if approach_direction == Vector2.ZERO:
		approach_direction = Vector2.DOWN
	local_player.global_position = warehouse.global_position + approach_direction.normalized() * 24.0
	local_player.velocity = Vector2.ZERO
	mp_game.set("_has_sent_input", false)
	mp_game.call("_client_send_input_if_needed", 0)
	await _wait_seconds(0.5)
	if not await _wait_for_warehouse_storage_count(warehouse, 0, 1, 5.0):
		_fail("Client did not receive the seeded shared warehouse snapshot.")
		return
	if not warehouse.request_multiplayer_stack_transfer(
		OakWarehouseProtocol.TransferDirection.STORAGE_TO_PLAYER,
		0
	):
		_fail("Client could not submit the shared warehouse retrieval transaction.")
		return
	if not await _wait_for_warehouse_request_settled(warehouse, 5.0):
		_fail("Client warehouse transaction did not receive a Host result.")
		return
	if not await _wait_for_warehouse_storage_count(warehouse, 0, 0, 5.0):
		_fail("Client warehouse state did not converge after competing retrievals.")
		return
	var run_state := root.get_node("RunState") as RunStateStore
	if (
		_count_peer_item_total(run_state, net_manager.connected_players, WOOD_MATERIAL)
		!= wood_total_before_warehouse_competition + 1
	):
		_fail("Client inventory snapshots did not converge on one warehouse winner.")
		return
	var station_config := PlantDefenseRegistry.get_config(&"wood_processing_station")
	var station_anchor := _find_shared_multiplayer_plant_anchor(game, station_config)
	if station_anchor == Vector2i.MAX:
		_fail("Client could not resolve a valid shared wood-station anchor.")
		return
	mp_game.call(
		"_on_local_plant_placement_requested",
		103,
		&"wood_processing_station",
		station_anchor
	)
	var station_plant: PlantDefense = await _wait_for_client_plant(game, 3, 5.0)
	var station := station_plant as ProductionBuilding
	if station == null:
		_fail("Client did not spawn the authoritative wood-station replica.")
		return
	# Capture the shared pre-command revision before any peer may submit. Relay
	# peers can otherwise receive the first result while still repairing their
	# initial snapshot and would legitimately issue a newer no-op command.
	var competing_recipe_revision := station.production_revision
	await _wait_seconds(1.0)
	var station_approach := station.global_position.direction_to(local_player.global_position)
	if station_approach == Vector2.ZERO:
		station_approach = Vector2.DOWN
	local_player.global_position = (
		station.global_position + station_approach.normalized() * 24.0
	)
	local_player.velocity = Vector2.ZERO
	mp_game.set("_has_sent_input", false)
	mp_game.call("_client_send_input_if_needed", 0)
	await _wait_seconds(0.5)
	if not await _wait_for_warehouse_item_total(
		warehouse,
		WOOD_MATERIAL,
		1,
		5.0
	):
		_fail("Client did not receive the production input warehouse snapshot.")
		return
	if not await _wait_for_production_ready(station, 6.0):
		_fail(
			"Client production snapshot did not become ready: ready=%s pending=%s revision=%d"
			% [
				station.multiplayer_production_snapshot_ready,
				station.multiplayer_production_request_pending,
				station.production_revision,
			]
		)
		return
	var recipe_command := ProductionBuildingProtocol.make_select_recipe_command(
		station.next_multiplayer_production_request_id,
		station.building_net_id,
		station.multiplayer_production_peer_id,
		competing_recipe_revision,
		&"wood_to_plank"
	)
	if not bool(station.call("_submit_multiplayer_production_command", recipe_command)):
		_fail("Client could not submit the multiplayer production recipe command.")
		return
	if not await _wait_for_production_request_settled(station, 5.0):
		_fail("Client recipe command did not receive a Host result.")
		return
	if not await _wait_for_warehouse_item_total(
		warehouse,
		PLANK_MATERIAL,
		2,
		5.0
	):
		_fail("Client warehouse did not converge on the two produced planks.")
		return
	if (
		station.active_recipe_id != &"wood_to_plank"
		or station.production_revision < 2
		or station.production_coordinator.get_total_item_count(WOOD_MATERIAL) != 0
		or station.production_coordinator.get_total_item_count(PLANK_MATERIAL) != 2
	):
		_fail("Client production and proxy-warehouse state did not converge.")
		return
	if not await _request_production_enabled_until(station, false, 5.0):
		_fail("Client did not converge on the paused production state.")
		return
	if str(net_manager.get("local_player_name")) == CLIENT2_PLAYER_NAME:
		await _wait_seconds(0.5)
		if not await _request_production_enabled_until(station, true, 5.0):
			_fail("Designated client could not confirm the production resume command.")
			return
	if not await _wait_for_production_enabled(station, true, 5.0):
		_fail("Client did not converge on the resumed production state.")
		return
	if not await _wait_for_client_plant_removed(game, 3, 5.0):
		_fail("Client did not remove the wood station after Host teardown.")
		return
	if not await _wait_for_client_plant_removed(game, 2, 5.0):
		_fail("Client did not remove the shared warehouse after Host teardown.")
		return
	print("LAN_PROBE_EVENT client_td_production_atomic station=3 warehouse=2")
	_validate_and_print_runtime_metrics(
		mp_game,
		false,
		_get_connected_player_count(net_manager)
	)
	# Keep the RPC node alive until the Host finishes its final reliable event
	# and shuts down, avoiding a test-only disconnect/send race.
	await _wait_seconds(2.0)


func _run_host_wave_probe(game: Variant) -> void:
	game.call("_begin_flow_step", game.flow_graph.start_step)
	if not await _wait_for_game_wave_state(game, GameRuntimeBase.WaveState.WAVE_ACTIVE, 3.0):
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
	var enemy: Enemy = game.get_enemy_for_net_id(enemy_id)
	if enemy == null or not is_instance_valid(enemy):
		_fail("Host wave probe enemy disappeared before damage.")
		return
	enemy.apply_damage(99999)
	if not await _wait_for_host_enemy_removed(game, enemy_id, 8.0):
		_fail("Host wave probe enemy was not removed after defeat.")
		return
	if not await _wait_for_game_wave_state(game, GameRuntimeBase.WaveState.INTERMISSION, 5.0):
		var next_step: FlowStepConfig = game.call(
			"_get_default_next_flow_step",
			game.current_flow_step
		)
		_fail(
			(
				"Host wave probe did not enter intermission: state=%d step=%s "
				+ "next=%s resolved=%d/%d active=%d."
			)
			% [
				int(game.wave_state),
				String(game.current_flow_step.step_id) if game.current_flow_step != null else "<null>",
				String(next_step.step_id) if next_step != null else "<null>",
				int(game.current_wave_resolved),
				int(game.current_wave_total),
				game.active_wave_enemy_ids.size(),
			]
		)
		return
	print("LAN_PROBE_EVENT host_wave_intermission_confirmed")
	await _wait_seconds(1.0)


func _run_client_wave_probe(mp_game: Node, game: Variant) -> void:
	if not await _wait_for_game_wave_state(game, GameRuntimeBase.WaveState.WAVE_ACTIVE, 6.0):
		_fail("Client wave probe did not receive wave start.")
		return
	if not bool(game.call("supports_tower_defense")) and not await _wait_for_wave_hud_text_contains(game, "第 1 波", 2.0):
		_fail("Client wave probe HUD did not show wave 1.")
		return
	var enemy_id := await _wait_for_first_client_enemy_id(mp_game, 6.0)
	if enemy_id <= 0:
		_fail("Client wave probe did not receive wave enemy spawn.")
		return
	if (
		bool(game.call("supports_tower_defense"))
		and not await _wait_for_tower_defense_hud_metrics(game, 1, 1, 0, 2.0)
	):
		_fail("Tower-defense client HUD did not show the live enemy without overwriting wave progress.")
		return
	print("LAN_PROBE_EVENT client_wave_enemy_spawned net_id=%d" % enemy_id)
	if not await _wait_for_client_enemy_removed(mp_game, enemy_id, 10.0):
		_fail("Client wave probe did not receive wave enemy removal.")
		return
	if (
		bool(game.call("supports_tower_defense"))
		and not await _wait_for_tower_defense_hud_metrics(game, 1, 0, 100, 2.0)
	):
		_fail("Tower-defense client HUD did not settle enemy count and wave progress independently.")
		return
	if not await _wait_for_game_wave_state(game, GameRuntimeBase.WaveState.INTERMISSION, 6.0):
		_fail("Client wave probe did not receive intermission.")
		return
	if not await _wait_for_merchant_active(game, true, 2.0):
		_fail("Client wave probe merchant did not become active.")
		return
	print("LAN_PROBE_EVENT client_wave_intermission_confirmed")
	await _wait_seconds(4.0)


func _run_host_boss_probe(game: Variant) -> void:
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
	if not await _wait_for_game_wave_state(game, GameRuntimeBase.WaveState.BOSS_INTRO, 4.0):
		_fail("Host boss probe did not enter boss intro.")
		return
	print("LAN_PROBE_EVENT host_boss_intro_confirmed")
	game.call("_on_linglan_boss_intro_finished")
	if not await _wait_for_game_wave_state(game, GameRuntimeBase.WaveState.BOSS_ACTIVE, 4.0):
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
		boss.apply_damage(boss.current_health + boss.get_effective_physical_defense())
	if not await _wait_for_game_wave_state(game, GameRuntimeBase.WaveState.VICTORY, 6.0):
		_fail("Host boss probe did not enter victory after boss defeat.")
		return
	print("LAN_PROBE_EVENT host_boss_victory_confirmed")


func _run_client_boss_probe(mp_game: Node, game: Variant) -> void:
	if not await _wait_for_game_wave_state(game, GameRuntimeBase.WaveState.BOSS_INTRO, 6.0):
		_fail("Client boss probe did not receive boss intro.")
		return
	print("LAN_PROBE_EVENT client_boss_intro_confirmed")
	if not await _wait_for_game_wave_state(game, GameRuntimeBase.WaveState.BOSS_ACTIVE, 8.0):
		_fail("Client boss probe did not receive boss active state.")
		return
	var boss_id := await _wait_for_first_client_enemy_id(mp_game, 8.0)
	if boss_id <= 0:
		_fail("Client boss probe did not receive boss spawn.")
		return
	var boss: LinglanBoss = game.linglan_boss
	if boss == null or not is_instance_valid(boss):
		_fail("Client boss probe did not bind Linglan boss proxy.")
		return
	print("LAN_PROBE_EVENT client_boss_active net_id=%d" % boss_id)

	var previous_health: int = boss.current_health
	if not await _wait_for_boss_health_below(game, previous_health, 8.0):
		_fail("Client boss probe did not receive boss health sync.")
		return
	print("LAN_PROBE_EVENT client_boss_health_confirmed")

	if not await _wait_for_game_wave_state(game, GameRuntimeBase.WaveState.VICTORY, 10.0):
		_fail("Client boss probe did not receive victory after boss defeat.")
		return
	print("LAN_PROBE_EVENT client_boss_victory_confirmed")
	await _wait_seconds(2.0)


func _cleanup_probe_game(net_manager: Node, mp_game) -> void:
	_release_probe_input_actions()
	# Tear down the transport before freeing the RPC node even on assertion
	# failures. Otherwise still-connected peers can send into a missing MpGame
	# and bury the original probe failure under secondary packet errors.
	if net_manager.has_method("disconnect_from_game"):
		net_manager.disconnect_from_game()
		await _wait_frames(8)
	if is_instance_valid(mp_game):
		mp_game.queue_free()
		await _wait_cleanup_frames(8)
	await _cleanup_current_scene()


func _run_host_replication_probe(net_manager: Node, mp_game: Node, game: Variant) -> void:
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
	var spawned_enemy: Enemy = game.get_enemy_for_net_id(spawned_enemy_id)
	if spawned_enemy == null or not is_instance_valid(spawned_enemy):
		_fail("Host probe enemy disappeared before the configured kill-reward check.")
		return
	var xirang_before_by_peer: Dictionary = {}
	for peer_id_variant in game.peer_players:
		var initial_peer_id := int(peer_id_variant)
		var initial_reward_player := game.get_player_for_peer(initial_peer_id) as Player
		if initial_reward_player != null and is_instance_valid(initial_reward_player):
			xirang_before_by_peer[initial_peer_id] = initial_reward_player.current_xirang
	spawned_enemy.call("_die")
	if not await _wait_for_host_enemy_removed(game, spawned_enemy_id, 2.0):
		_fail("Host probe enemy net id was not cleared after death.")
		return
	print("LAN_PROBE_EVENT host_enemy_removed net_id=%d" % spawned_enemy_id)
	await process_frame
	for peer_id_variant in xirang_before_by_peer:
		var observed_peer_id := int(peer_id_variant)
		var observed_reward_player := game.get_player_for_peer(observed_peer_id) as Player
		if (
			observed_reward_player == null
			or observed_reward_player.current_xirang
			!= int(xirang_before_by_peer[observed_peer_id])
			+ BASIC_ENEMY_CONFIG.xirang_kill_reward
		):
			_fail(
				"Host did not grant the configured Xirang kill reward to peer %d."
				% observed_peer_id
			)
			return
	print(
		"LAN_PROBE_EVENT host_xirang_confirmed reward=%d players=%d"
		% [BASIC_ENEMY_CONFIG.xirang_kill_reward, xirang_before_by_peer.size()]
	)
	if not await _wait_for_player_dead(client2_player, 10.0):
		_fail("Host did not observe client2 death.")
		return
	print("LAN_PROBE_EVENT host_death_confirmed peer=%d" % client2_peer_id)
	var death_revision := _get_player_health_revision(mp_game, client2_peer_id)
	if not await _wait_for_player_state_at_revision(
		mp_game,
		client2_player,
		client2_peer_id,
		death_revision + 1,
		false,
		14.0
	):
		_fail("Host did not revive client2.")
		return
	if not await _wait_for_player_invincibility_clear(client2_player, 5.0):
		_fail("Host client2 invincibility did not clear after revive.")
		return
	print("LAN_PROBE_EVENT host_revive_confirmed peer=%d" % client2_peer_id)


func _run_host_projectile_hit_probe(
	mp_game: Node,
	game: Variant,
	owner_peer_id: int,
	enemy_net_id: int
) -> bool:
	var enemy: Enemy = game.get_enemy_for_net_id(enemy_net_id)
	if enemy == null or not is_instance_valid(enemy):
		_fail("Host projectile hit probe missing enemy.")
		return false
	var health_before: int = enemy.current_health
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
	game: Variant,
	drive_local_actions: bool
) -> void:
	if drive_local_actions:
		await _drive_local_player_motion(mp_game, game)

	var enemy_id := await _wait_for_first_client_enemy_id(mp_game, 4.0)
	if enemy_id <= 0:
		_fail("Client did not receive probe enemy spawn.")
		return
	print("LAN_PROBE_EVENT client_enemy_spawned net_id=%d" % enemy_id)
	var player := game.player as Player
	if player == null or not is_instance_valid(player):
		_fail("Client replication probe missing local player.")
		return
	var xirang_before := player.current_xirang
	if drive_local_actions:
		await _run_client_projectile_hit_probe(mp_game, game, enemy_id)
	if not await _wait_for_client_enemy_removed(mp_game, enemy_id, 7.0):
		_fail("Client did not receive probe enemy removal.")
		return
	print("LAN_PROBE_EVENT client_enemy_removed net_id=%d" % enemy_id)
	if not await _wait_for_player_xirang_at_least(
		player,
		xirang_before + BASIC_ENEMY_CONFIG.xirang_kill_reward,
		5.0
	):
		_fail("Client did not receive the configured direct Xirang kill reward.")
		return
	print(
		"LAN_PROBE_EVENT client_xirang_confirmed reward=%d current_xirang=%d"
		% [BASIC_ENEMY_CONFIG.xirang_kill_reward, player.current_xirang]
	)
	if not drive_local_actions:
		await _run_remote_client2_death_view_probe(net_manager, mp_game, game)


func _run_client_projectile_hit_probe(mp_game: Node, game: Variant, enemy_id: int) -> void:
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


func _run_client_reliable_event_probe(mp_game: Node, game: Variant) -> void:
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


func _run_client_death_revive_probe(mp_game: Node, game: Variant) -> void:
	var player := game.player as Player
	if player == null or not is_instance_valid(player):
		_fail("Death/revive probe missing local player.")
		return
	var local_peer_id := int(game.multiplayer_local_peer_id)
	var source_id := local_peer_id * 1000000 + 770001
	var revision_before_death := _get_player_health_revision(mp_game, local_peer_id)
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
	if not await _wait_for_player_state_at_revision(
		mp_game,
		player,
		local_peer_id,
		revision_before_death + 1,
		true,
		3.0
	):
		_fail("Death/revive probe did not enter dead state.")
		return
	print("LAN_PROBE_EVENT death_confirmed peer=%d" % local_peer_id)
	var death_revision := _get_player_health_revision(mp_game, local_peer_id)
	if not await _wait_for_player_state_at_revision(
		mp_game,
		player,
		local_peer_id,
		death_revision + 1,
		false,
		13.0
	):
		_fail("Death/revive probe did not receive Host revive.")
		return
	if not await _wait_for_player_invincibility_clear(player, 5.0):
		_fail("Death/revive probe invincibility did not clear after revive.")
		return
	print(
		"LAN_PROBE_EVENT revive_confirmed peer=%d health=%d"
		% [local_peer_id, player.current_health]
	)


func _run_remote_client2_death_view_probe(
	net_manager: Node,
	mp_game: Node,
	game: Variant
) -> void:
	var client2_peer_id := _get_peer_id_by_name(net_manager, CLIENT2_PLAYER_NAME)
	if client2_peer_id <= 0:
		_fail("Remote death view probe could not find client2 peer id.")
		return
	var remote_player := game.get_player_for_peer(client2_peer_id) as Player
	if remote_player == null or not is_instance_valid(remote_player):
		_fail("Remote death view probe missing client2 player node.")
		return
	var minimum_death_revision := maxi(
		_get_player_health_revision(mp_game, client2_peer_id),
		1
	)
	if not await _wait_for_player_state_at_revision(
		mp_game,
		remote_player,
		client2_peer_id,
		minimum_death_revision,
		true,
		8.0
	):
		_fail("Remote clients did not see client2 death.")
		return
	print("LAN_PROBE_EVENT remote_death_confirmed peer=%d" % client2_peer_id)
	var death_revision := _get_player_health_revision(mp_game, client2_peer_id)
	if not await _wait_for_player_state_at_revision(
		mp_game,
		remote_player,
		client2_peer_id,
		death_revision + 1,
		false,
		14.0
	):
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


func _get_player_health_revision(mp_game: Node, peer_id: int) -> int:
	if mp_game == null or not is_instance_valid(mp_game) or peer_id <= 0:
		return 0
	var revisions := mp_game.get("_player_health_revisions") as Dictionary
	return int(revisions.get(peer_id, 0))


func _wait_for_player_state_at_revision(
	mp_game: Node,
	player: Player,
	peer_id: int,
	minimum_revision: int,
	expected_dead: bool,
	timeout_seconds: float
) -> bool:
	var end_time := _now_seconds() + timeout_seconds
	while _now_seconds() <= end_time:
		if (
			player != null
			and is_instance_valid(player)
			and _get_player_health_revision(mp_game, peer_id) >= minimum_revision
			and player.is_dead == expected_dead
			and (
				(expected_dead and player.current_health <= 0)
				or (not expected_dead and player.current_health > 0)
			)
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


func _wait_for_host_enemy_removed(game: Variant, net_id: int, timeout_seconds: float) -> bool:
	var end_time := _now_seconds() + timeout_seconds
	while _now_seconds() <= end_time:
		if game == null or not is_instance_valid(game) or game.get_enemy_for_net_id(net_id) == null:
			return true
		await process_frame
	return false


func _wait_for_first_client_enemy_id(mp_game: Node, timeout_seconds: float) -> int:
	var end_time := _now_seconds() + timeout_seconds
	while _now_seconds() <= end_time:
		if mp_game == null or not is_instance_valid(mp_game):
			return 0
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


func _wait_for_int_property(
	object: Object,
	property_name: StringName,
	expected_value: int,
	timeout_seconds: float
) -> bool:
	var end_time := _now_seconds() + timeout_seconds
	while _now_seconds() <= end_time:
		if object != null and is_instance_valid(object):
			if int(object.get(property_name)) == expected_value:
				return true
		await process_frame
	return false


func _find_shared_multiplayer_plant_anchor(
	game: Variant,
	config: PlantDefenseConfig
) -> Vector2i:
	if game == null or game.plant_system == null or config == null:
		return Vector2i.MAX
	var peer_ids: Array[int] = []
	for peer_id_variant in game.peer_players:
		peer_ids.append(int(peer_id_variant))
	peer_ids.sort()
	if peer_ids.is_empty():
		return Vector2i.MAX
	var placement_area: Rect2i = game.plant_system.placement_area
	var last_anchor_exclusive := placement_area.end - config.footprint_size + Vector2i.ONE
	for y in range(placement_area.position.y, last_anchor_exclusive.y):
		for x in range(placement_area.position.x, last_anchor_exclusive.x):
			var anchor := Vector2i(x, y)
			var valid_for_every_player := true
			for peer_id in peer_ids:
				var placement_player := game.get_player_for_peer(peer_id) as Player
				if not game.plant_system.is_placement_valid_for_player(
					anchor,
					config,
					placement_player
				):
					valid_for_every_player = false
					break
			if valid_for_every_player:
				return anchor
	return Vector2i.MAX


func _position_enemy_for_clear_plant_shot(plant: AgaveCannon, enemy: Enemy) -> bool:
	if plant == null or enemy == null:
		return false
	var directions := [
		Vector2.RIGHT,
		Vector2.LEFT,
		Vector2.UP,
		Vector2.DOWN,
		Vector2(1.0, 1.0).normalized(),
		Vector2(-1.0, 1.0).normalized(),
		Vector2(1.0, -1.0).normalized(),
		Vector2(-1.0, -1.0).normalized(),
	]
	for direction in directions:
		enemy.global_position = plant.global_position + direction * 48.0
		await physics_frame
		if bool(plant.call("_has_clear_world_line_to", enemy)):
			return true
	return false


func _wait_for_host_plant_requests(
	mp_game: Node,
	net_manager: Node,
	request_id: int,
	timeout_seconds: float
) -> bool:
	var expected_client_ids: Array[int] = []
	var local_peer_id := int(net_manager.get_local_peer_id())
	for peer_id_variant in net_manager.connected_players:
		var peer_id := int(peer_id_variant)
		if peer_id != local_peer_id:
			expected_client_ids.append(peer_id)
	var end_time := _now_seconds() + timeout_seconds
	while _now_seconds() <= end_time:
		var processed_requests := mp_game.get("_last_plant_placement_request_ids") as Dictionary
		var all_processed := not expected_client_ids.is_empty()
		for peer_id in expected_client_ids:
			if int(processed_requests.get(peer_id, 0)) != request_id:
				all_processed = false
				break
		if all_processed:
			return true
		await process_frame
	return false


func _wait_for_host_warehouse_transactions(
	mp_game: Node,
	net_manager: Node,
	timeout_seconds: float
) -> bool:
	var expected_client_ids: Array[int] = []
	var local_peer_id := int(net_manager.get_local_peer_id())
	for peer_id_variant in net_manager.connected_players:
		var peer_id := int(peer_id_variant)
		if peer_id != local_peer_id:
			expected_client_ids.append(peer_id)
	var end_time := _now_seconds() + timeout_seconds
	while _now_seconds() <= end_time:
		var results_by_peer := mp_game.get(
			"_warehouse_transaction_results_by_peer"
		) as Dictionary
		var all_processed := not expected_client_ids.is_empty()
		for peer_id in expected_client_ids:
			var peer_results := results_by_peer.get(peer_id, {}) as Dictionary
			if peer_results.is_empty():
				all_processed = false
				break
		if all_processed:
			return true
		await process_frame
	return false


func _wait_for_host_production_results(
	mp_game: Node,
	minimum_result_count: int,
	timeout_seconds: float
) -> bool:
	var end_time := _now_seconds() + timeout_seconds
	while _now_seconds() <= end_time:
		var results_by_peer := mp_game.get(
			"_production_command_results_by_peer"
		) as Dictionary
		var result_count := 0
		for peer_results_variant in results_by_peer.values():
			var peer_results := peer_results_variant as Dictionary
			result_count += peer_results.size()
		if result_count >= minimum_result_count:
			return true
		await process_frame
	return false


func _count_host_production_result_reasons(
	mp_game: Node,
	request_id: int
) -> Dictionary:
	var counts: Dictionary = {}
	var results_by_peer := mp_game.get(
		"_production_command_results_by_peer"
	) as Dictionary
	for peer_results_variant in results_by_peer.values():
		var peer_results := peer_results_variant as Dictionary
		for result_variant in peer_results.values():
			var result := result_variant as Dictionary
			if int(result.get("request_id", 0)) != request_id:
				continue
			var reason := StringName(result.get("reason", &""))
			counts[reason] = int(counts.get(reason, 0)) + 1
	return counts


func _wait_for_warehouse_request_settled(
	warehouse: OakWarehouse,
	timeout_seconds: float
) -> bool:
	var end_time := _now_seconds() + timeout_seconds
	while _now_seconds() <= end_time:
		if (
			warehouse == null
			or not is_instance_valid(warehouse)
			or not warehouse.multiplayer_storage_request_pending
		):
			return warehouse != null and is_instance_valid(warehouse)
		await process_frame
	return false


func _wait_for_warehouse_storage_count(
	warehouse: OakWarehouse,
	slot_index: int,
	expected_count: int,
	timeout_seconds: float
) -> bool:
	var end_time := _now_seconds() + timeout_seconds
	var next_snapshot_request_time := 0.0
	while _now_seconds() <= end_time:
		if warehouse == null or not is_instance_valid(warehouse):
			return false
		if warehouse.get_storage_item_count(slot_index) == expected_count:
			return true
		var now := _now_seconds()
		if now >= next_snapshot_request_time:
			warehouse.request_multiplayer_storage_snapshot()
			next_snapshot_request_time = now + 0.6
		await process_frame
	return false


func _wait_for_warehouse_item_total(
	warehouse: OakWarehouse,
	item: PickupConfig,
	expected_count: int,
	timeout_seconds: float
) -> bool:
	var end_time := _now_seconds() + timeout_seconds
	var next_snapshot_request_time := 0.0
	while _now_seconds() <= end_time:
		if warehouse == null or not is_instance_valid(warehouse):
			return false
		if warehouse.get_storage_item_total(item) == expected_count:
			return true
		var now := _now_seconds()
		if now >= next_snapshot_request_time:
			warehouse.request_multiplayer_storage_snapshot()
			next_snapshot_request_time = now + 0.6
		await process_frame
	return false


func _wait_for_production_request_settled(
	station: ProductionBuilding,
	timeout_seconds: float
) -> bool:
	var end_time := _now_seconds() + timeout_seconds
	while _now_seconds() <= end_time:
		if station == null or not is_instance_valid(station):
			return false
		if not station.multiplayer_production_request_pending:
			return true
		await process_frame
	return false


func _wait_for_production_ready(
	station: ProductionBuilding,
	timeout_seconds: float
) -> bool:
	var end_time := _now_seconds() + timeout_seconds
	var next_snapshot_request_time := 0.0
	while _now_seconds() <= end_time:
		if station == null or not is_instance_valid(station):
			return false
		if station.is_multiplayer_production_ready():
			return true
		var now := _now_seconds()
		if (
			now >= next_snapshot_request_time
			and not station.multiplayer_production_request_pending
		):
			station.request_multiplayer_production_snapshot()
			next_snapshot_request_time = now + 0.6
		await process_frame
	return false


func _request_production_enabled_until(
	station: ProductionBuilding,
	expected_enabled: bool,
	timeout_seconds: float
) -> bool:
	var end_time := _now_seconds() + timeout_seconds
	while _now_seconds() <= end_time:
		if station == null or not is_instance_valid(station):
			return false
		if (
			station.production_enabled == expected_enabled
			and station.multiplayer_production_snapshot_ready
			and not station.multiplayer_production_request_pending
		):
			return true
		if station.is_multiplayer_production_ready():
			station.request_multiplayer_enabled_change(expected_enabled)
		await process_frame
	return false


func _wait_for_authoritative_production_enabled(
	station: ProductionBuilding,
	expected_enabled: bool,
	timeout_seconds: float
) -> bool:
	var end_time := _now_seconds() + timeout_seconds
	while _now_seconds() <= end_time:
		if station == null or not is_instance_valid(station):
			return false
		if station.production_enabled == expected_enabled:
			return true
		await process_frame
	return false


func _wait_for_production_enabled(
	station: ProductionBuilding,
	expected_enabled: bool,
	timeout_seconds: float
) -> bool:
	var end_time := _now_seconds() + timeout_seconds
	var next_snapshot_request_time := 0.0
	while _now_seconds() <= end_time:
		if station == null or not is_instance_valid(station):
			return false
		if (
			station.production_enabled == expected_enabled
			and station.multiplayer_production_snapshot_ready
			and not station.multiplayer_production_request_pending
		):
			return true
		var now := _now_seconds()
		if (
			now >= next_snapshot_request_time
			and not station.multiplayer_production_request_pending
		):
			station.request_multiplayer_production_snapshot()
			next_snapshot_request_time = now + 0.6
		await process_frame
	return false


func _count_peer_item_total(
	run_state: RunStateStore,
	connected_players: Dictionary,
	item: PickupConfig
) -> int:
	if run_state == null or item == null:
		return 0
	var total := 0
	for peer_id_variant in connected_players.keys():
		var peer_id := int(peer_id_variant)
		for slot_index in range(RunStateStore.INVENTORY_CAPACITY):
			var stored_item := run_state.get_item_for_peer(peer_id, slot_index)
			if PickupConfig.inventory_identity_matches(stored_item, item):
				total += run_state.get_item_count_for_peer(peer_id, slot_index)
	return total


func _wait_for_dictionary_flag(
	state: Dictionary,
	key: Variant,
	timeout_seconds: float
) -> bool:
	var end_time := _now_seconds() + timeout_seconds
	while _now_seconds() <= end_time:
		if bool(state.get(key, false)):
			return true
		await process_frame
	return false


func _wait_for_client_plant_projectile_visual(
	mp_game: Node,
	timeout_seconds: float
) -> AgaveCannonball:
	var end_time := _now_seconds() + timeout_seconds
	while _now_seconds() <= end_time:
		if mp_game == null or not is_instance_valid(mp_game):
			return null
		var search_roots: Array[Node] = [mp_game]
		var game: Variant = mp_game.get("game")
		if game != null and is_instance_valid(game):
			var object_pool := game.get_node_or_null("SessionObjectPool") as Node
			if object_pool != null:
				search_roots.append(object_pool)
		for search_root in search_roots:
			for child in search_root.get_children():
				var projectile := child as AgaveCannonball
				if (
					projectile != null
					and is_instance_valid(projectile)
					and bool(projectile.get("pool_active"))
					and not projectile.is_queued_for_deletion()
				):
					return projectile
		await process_frame
	return null


func _wait_for_client_plant(
	game: Variant,
	net_id: int,
	timeout_seconds: float
) -> PlantDefense:
	var end_time := _now_seconds() + timeout_seconds
	while _now_seconds() <= end_time:
		var plant := game.plant_system.get_plant_by_net_id(net_id) as PlantDefense
		if plant != null and is_instance_valid(plant):
			return plant
		await process_frame
	return null


func _wait_for_plant_health_below(
	plant: PlantDefense,
	previous_health: int,
	timeout_seconds: float
) -> bool:
	var end_time := _now_seconds() + timeout_seconds
	while _now_seconds() <= end_time:
		if plant == null or not is_instance_valid(plant):
			return false
		if plant.current_health < previous_health:
			return true
		await process_frame
	return false


func _wait_for_client_plant_removed(
	game: Variant,
	net_id: int,
	timeout_seconds: float
) -> bool:
	var end_time := _now_seconds() + timeout_seconds
	while _now_seconds() <= end_time:
		var plant := game.plant_system.get_plant_by_net_id(net_id) as PlantDefense
		if plant == null or not is_instance_valid(plant):
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


func _wait_for_boss_health_below(game: Variant, previous_health: int, timeout_seconds: float) -> bool:
	var end_time := _now_seconds() + timeout_seconds
	while _now_seconds() <= end_time:
		if game == null or not is_instance_valid(game):
			return false
		var boss: LinglanBoss = game.linglan_boss
		if boss != null and is_instance_valid(boss) and boss.current_health < previous_health:
			return true
		await process_frame
	return false


func _wait_for_first_host_enemy_net_id(game: Variant, timeout_seconds: float) -> int:
	var end_time := _now_seconds() + timeout_seconds
	while _now_seconds() <= end_time:
		for net_id_variant in game.multiplayer_enemies_by_net_id:
			var net_id := int(net_id_variant)
			var enemy: Enemy = game.get_enemy_for_net_id(net_id)
			if net_id > 0 and enemy != null and is_instance_valid(enemy):
				return net_id
		await process_frame
	return 0


func _wait_for_game_wave_state(game: Variant, target_state: int, timeout_seconds: float) -> bool:
	var end_time := _now_seconds() + timeout_seconds
	while _now_seconds() <= end_time:
		if game != null and is_instance_valid(game) and int(game.wave_state) == target_state:
			return true
		await process_frame
	return false


func _wait_for_merchant_active(game: Variant, expected_active: bool, timeout_seconds: float) -> bool:
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
	game: Variant,
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


func _wait_for_tower_defense_hud_metrics(
	game: Variant,
	wave_number: int,
	expected_enemy_count: int,
	expected_progress_percent: int,
	timeout_seconds: float
) -> bool:
	var end_time := _now_seconds() + timeout_seconds
	while _now_seconds() <= end_time:
		if game != null and is_instance_valid(game) and game.wave_hud != null:
			var hud: WaveHUD = game.wave_hud
			if (
				hud.tower_defense_stats.visible
				and hud.wave_title_label.text == "第 %d 波" % wave_number
				and hud.wave_value_label.text == "%d%%" % expected_progress_percent
				and hud.enemy_value_label.text == str(expected_enemy_count)
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


func _wait_for_peer_removed_from_host(
	net_manager: Node,
	game: Variant,
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


func _wait_for_peer_removed_from_client(game: Variant, peer_id: int, timeout_seconds: float) -> bool:
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


func _drive_local_player_motion(mp_game: Node, game: Variant) -> void:
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


func _disable_probe_wave_flow(game: Variant) -> void:
	game.auto_start_waves = false
	if game.enemy_spawn_timer != null:
		game.enemy_spawn_timer.stop()
	if game.state_timer != null:
		game.state_timer.stop()


func _configure_probe_wave_flow(game: Variant) -> void:
	_disable_probe_wave_flow(game)
	game.waves = _create_probe_waves()
	var flow_graph := FlowGraphConfig.new()
	flow_graph.graph_name = "Probe Flow"
	for wave_config in game.waves:
		flow_graph.steps.append(wave_config)
	if not flow_graph.steps.is_empty():
		flow_graph.start_step = flow_graph.steps[0]
	game.flow_graph = flow_graph
	# The probe starts wave one directly, but still needs a non-zero rest duration
	# so clearing it can be observed in INTERMISSION before wave two begins.
	game.pre_wave_duration = 30.0
	game.current_wave_index = 0
	game.current_wave_total = 0
	game.current_wave_spawned = 0
	game.current_wave_defeated = 0


func _configure_probe_boss_flow(game: Variant) -> void:
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


func _spawn_host_probe_enemy(game: Variant) -> int:
	if game.active_wave_spawn_points.is_empty():
		if game.waves.is_empty() or not bool(game.call("_resolve_wave_spawn_points", game.waves[0])):
			_fail("Host probe could not resolve an active wave spawn-point mask.")
			return 0
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
