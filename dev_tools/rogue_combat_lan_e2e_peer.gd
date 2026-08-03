extends SceneTree

## 真双进程 Rouge「狭路相逢」LAN E2E 端点。
##
## 由 run_rogue_combat_lan_e2e.ps1 启动 Host + Client。两进程通过正式
## NetManager / MpRogueRoute / RogueCombatMultiplayerCoordinator 协议通信；
## 临时 marker 文件只用于探针阶段 barrier，不携带或替代任何游戏状态。

const WRAPPER_SCENE := preload("res://scene/multiplayer/mp_rogue_route.tscn")
const FORMAL_CONFIG := preload(
	"res://resources/config/rogue_combat/encounter_01.tres"
)
const COMBAT_ROBOT_CONFIG_PATH := (
	"res://resources/config/enemies/combat_robot.tres"
)
const STATE_LOADING_GAME := NetManagerStore.ConnectionState.LOADING_GAME
const STATE_IN_GAME := NetManagerStore.ConnectionState.IN_GAME
const PLAYER_COUNT := 2
const ROUTE_SEED_SEARCH_LIMIT := 4096
const NETWORK_TIMEOUT_SECONDS := 30.0
const COMBAT_TIMEOUT_SECONDS := 35.0
const EXPECTED_ENEMY_COUNT := 10
const EXPECTED_KILL_XIRANG := 100
const EXPECTED_EXTRA_XIRANG := 500
const EXPECTED_TOTAL_XIRANG_DELTA := 600

var failures: Array[String] = []
var sync_dir := ""
var host_spawn_ids: Array[int] = []
var host_spawn_positions: Array[Vector2] = []
var host_spawn_config_paths: PackedStringArray = []
var host_spawn_ticks: PackedInt64Array = []
var watched_coordinator: RogueCombatMultiplayerCoordinator = null
var watched_result_overlay: RogueCombatResultOverlay = null
var watched_settlement: Dictionary = {}


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	var options := _parse_options()
	var role := str(options.get("role", ""))
	var port := int(options.get("port", "29472"))
	sync_dir = str(options.get("sync_dir", ""))
	var net_manager := root.get_node_or_null("NetManager") as NetManagerStore
	if net_manager == null:
		_fail("NetManager autoload missing")
		_finish(role)
		return
	if sync_dir.is_empty() or not DirAccess.dir_exists_absolute(sync_dir):
		_fail("probe sync directory is missing: %s" % sync_dir)
		_finish(role)
		return

	net_manager.disconnect_from_game()
	net_manager.local_player_name = "RogueE2E%s" % role.capitalize()
	match role:
		"host":
			await _run_host(net_manager, port)
		"client":
			await _run_client(net_manager, port)
		_:
			_fail("unsupported role: %s" % role)

	# Transport first, then scene. This preserves every RPC NodePath until both
	# endpoints have completed their probe lifecycle.
	if net_manager.is_multiplayer_active():
		net_manager.disconnect_from_game()
	await _wait_frames(8)
	if current_scene != null and is_instance_valid(current_scene):
		current_scene.queue_free()
		current_scene = null
	await _wait_frames(8)
	_finish(role)


func _run_host(net_manager: NetManagerStore, port: int) -> void:
	if not net_manager.set_host_game_mode(NetManagerStore.GameMode.TEST_ARENA_P3):
		_fail("Host could not select P3 mode")
		return
	var error := net_manager.host_create_lan_server(port, PLAYER_COUNT)
	if error != OK:
		_fail("Host create failed: %s" % error_string(error))
		return
	if not await _wait_until(
		func() -> bool: return net_manager.connected_players.size() == PLAYER_COUNT,
		NETWORK_TIMEOUT_SECONDS
	):
		_fail("Host timed out waiting for Client")
		return
	net_manager.host_start_game()
	if not await _wait_for_state(net_manager, STATE_LOADING_GAME, 3.0):
		_fail("Host did not enter loading state")
		return
	var wrapper := await _mount_wrapper()
	if wrapper == null:
		return
	if not await _wait_for_state(net_manager, STATE_IN_GAME, NETWORK_TIMEOUT_SECONDS):
		_fail("Host did not pass the P3 loading barrier")
		return

	var route := wrapper.get_node("RogueRoute") as TestRogueRouteP3
	var coordinator := wrapper.get_node(
		"RogueCombatCoordinator"
	) as RogueCombatMultiplayerCoordinator
	if route == null or coordinator == null or not coordinator.is_enabled():
		_fail("Host P3 runtime is missing the enabled combat coordinator")
		return
	_start_settlement_watch(coordinator, route)
	if not route.is_route_ready():
		_fail("Host route was not generated")
		return
	var fixture := _find_adjacent_normal_combat_fixture(route.generation_config)
	if fixture.is_empty():
		_fail("Could not find an adjacent NORMAL_COMBAT seed")
		return
	var route_seed := int(fixture["seed"])
	var combat_node_id := int(fixture["combat_node_id"])
	var content_seed := int(fixture["content_seed"])
	if not route.start_authoritative_session(route_seed, true):
		_fail("Host could not install the deterministic combat route")
		return
	if not _write_marker("host_route.json", JSON.stringify({
		"route_seed": route_seed,
		"combat_node_id": combat_node_id,
		"content_seed": content_seed,
	})):
		return
	if not await _wait_for_marker("client_route_ready", NETWORK_TIMEOUT_SECONDS):
		_fail("Host timed out waiting for Client deterministic route sync")
		return

	var peer_ids := _get_sorted_peer_ids(net_manager)
	if peer_ids.size() != PLAYER_COUNT:
		_fail("Host expected exactly two participant peers")
		return
	var baseline := _capture_route_and_inventory_baseline(route, peer_ids)
	if baseline.is_empty():
		return
	var runtime_state := route.get("_runtime_state") as RogueRouteRuntimeState
	if runtime_state == null or not runtime_state.try_move(
		combat_node_id,
		route.generation_config.move_action_cost,
		route.get_route_revision()
	):
		_fail("Host could not move onto the deterministic combat node")
		return
	var occurrence_key := route.get_normal_combat_occurrence_key()
	if occurrence_key.is_empty():
		_fail("Host route did not create a combat occurrence")
		return
	if not _write_marker("host_occurrence.txt", occurrence_key):
		return

	var game := await _wait_for_combat_game(coordinator, "Host")
	if game == null:
		return
	var expected_loot := _capture_expected_loot(
		game,
		peer_ids,
		occurrence_key,
		content_seed
	)
	if expected_loot.size() != PLAYER_COUNT:
		return
	if not game.multiplayer_enemy_spawned.is_connected(_on_host_enemy_spawned):
		game.multiplayer_enemy_spawned.connect(_on_host_enemy_spawned)
	if not await _wait_until(
		func() -> bool:
			return (
				game.current_wave_spawned == EXPECTED_ENEMY_COUNT
				and game.multiplayer_enemies_by_net_id.size()
				== EXPECTED_ENEMY_COUNT
				and host_spawn_ids.size() == EXPECTED_ENEMY_COUNT
			),
		COMBAT_TIMEOUT_SECONDS
	):
		_fail(
			"Host did not spawn the full robot batch: wave=%d network=%d signals=%d"
			% [
				game.current_wave_spawned,
				game.multiplayer_enemies_by_net_id.size(),
				host_spawn_ids.size(),
			]
		)
		return
	if not _validate_host_spawn_batch(game):
		return
	_freeze_host_enemies(game)
	var sorted_spawn_ids := host_spawn_ids.duplicate()
	sorted_spawn_ids.sort()
	var batch_msec := _get_spawn_batch_duration_msec()
	if not _write_marker("host_spawn.json", JSON.stringify({
		"occurrence_key": occurrence_key,
		"enemy_ids": sorted_spawn_ids,
		"batch_msec": batch_msec,
	})):
		return
	print(
		"ROGUE_COMBAT_LAN_HOST_SPAWN occurrence=%s count=10 batch_ms=%d"
		% [occurrence_key, batch_msec]
	)
	if not await _wait_for_marker("client_spawn_ready", NETWORK_TIMEOUT_SECONDS):
		_fail("Host timed out waiting for Client's ten synchronized robots")
		return

	for enemy_id in sorted_spawn_ids:
		var enemy := game.get_enemy_for_net_id(enemy_id) as Enemy
		if enemy == null or not is_instance_valid(enemy):
			_fail("Host robot disappeared before authoritative defeat: %d" % enemy_id)
			continue
		if not enemy.apply_damage(99999, Vector2.ZERO, EnemyConfig.DamageType.PHYSICAL, false):
			_fail("Host could not apply lethal damage to robot %d" % enemy_id)
	if not failures.is_empty():
		return
	if not await _wait_until(
		func() -> bool:
			return (
				game.current_wave_defeated == EXPECTED_ENEMY_COUNT
				and game.multiplayer_enemies_by_net_id.is_empty()
			),
		12.0
	):
		_fail(
			"Host robots did not fully resolve: defeated=%d network=%d"
			% [game.current_wave_defeated, game.multiplayer_enemies_by_net_id.size()]
		)
		return

	var settlement := await _wait_for_settlement_and_result(
		coordinator,
		route,
		"Host"
	)
	if settlement.is_empty():
		return
	_validate_victory_settlement(
		settlement,
		route,
		peer_ids,
		baseline,
		expected_loot,
		occurrence_key,
		combat_node_id,
		content_seed,
		"Host"
	)
	if not failures.is_empty():
		return
	if not await _wait_until(
		func() -> bool:
			return (
				coordinator.get("_phase")
				== RogueCombatMultiplayerCoordinator.ProtocolPhase.IDLE
				and bool(coordinator.get("_local_result_visible"))
			),
		NETWORK_TIMEOUT_SECONDS
	):
		_fail("Host did not reach terminal-safe IDLE with its result still open")
		return
	if not await _wait_for_marker("client_result_ready", NETWORK_TIMEOUT_SECONDS):
		_fail("Host timed out waiting for Client result readiness")
		return
	_route_dismiss_result(route)
	await process_frame
	if route.combat_result_overlay.visible or not str(
		coordinator.get("_local_result_occurrence_key")
	).is_empty():
		_fail("Host did not independently close its result")
		return
	if not _write_marker("host_result_closed", "ok"):
		return
	if not await _wait_for_marker("client_result_closed", NETWORK_TIMEOUT_SECONDS):
		_fail("Host timed out waiting for Client's independent result close")
		return
	print("ROGUE_COMBAT_LAN_HOST_INDEPENDENT_RESULT_OK")


func _run_client(net_manager: NetManagerStore, port: int) -> void:
	var error := net_manager.client_connect_lan("127.0.0.1", port)
	if error != OK:
		_fail("Client connect failed: %s" % error_string(error))
		return
	if not await _wait_for_state(net_manager, STATE_LOADING_GAME, NETWORK_TIMEOUT_SECONDS):
		_fail("Client did not receive P3 start")
		return
	if net_manager.current_game_mode != NetManagerStore.GameMode.TEST_ARENA_P3:
		_fail("Client received the wrong game mode")
		return
	var wrapper := await _mount_wrapper()
	if wrapper == null:
		return
	if not await _wait_for_state(net_manager, STATE_IN_GAME, NETWORK_TIMEOUT_SECONDS):
		_fail("Client did not pass the P3 loading barrier")
		return
	var route := wrapper.get_node("RogueRoute") as TestRogueRouteP3
	var coordinator := wrapper.get_node(
		"RogueCombatCoordinator"
	) as RogueCombatMultiplayerCoordinator
	if route == null or coordinator == null or not coordinator.is_enabled():
		_fail("Client P3 runtime is missing the enabled combat coordinator")
		return
	_start_settlement_watch(coordinator, route)
	if not await _wait_until(route.is_route_ready, NETWORK_TIMEOUT_SECONDS):
		_fail("Client did not receive the initial route snapshot")
		return
	var route_marker := await _wait_for_json_marker(
		"host_route.json",
		NETWORK_TIMEOUT_SECONDS
	)
	if route_marker.is_empty():
		return
	var route_seed := int(route_marker.get("route_seed", 0))
	var combat_node_id := int(route_marker.get("combat_node_id", -1))
	var content_seed := int(route_marker.get("content_seed", 0))
	if not await _wait_until(
		func() -> bool:
			return (
				route.is_route_ready()
				and int(route.export_layout_snapshot().get("generation_seed", 0))
				== route_seed
			),
		NETWORK_TIMEOUT_SECONDS
	):
		_fail("Client did not converge on the deterministic Host route")
		return
	var layout := route.export_layout_snapshot()
	var node_types := layout.get("node_types", PackedByteArray()) as PackedByteArray
	var content_seeds := layout.get(
		"node_content_seeds",
		PackedInt64Array()
	) as PackedInt64Array
	if (
		combat_node_id < 0
		or combat_node_id >= node_types.size()
		or int(node_types[combat_node_id])
		!= RogueRouteGraph.NodeType.NORMAL_COMBAT
		or combat_node_id >= content_seeds.size()
		or int(content_seeds[combat_node_id]) != content_seed
	):
		_fail("Client deterministic route marker does not describe NORMAL_COMBAT")
		return
	var peer_ids := _get_sorted_peer_ids(net_manager)
	if peer_ids.size() != PLAYER_COUNT:
		_fail("Client expected exactly two participant peers")
		return
	var baseline := _capture_route_and_inventory_baseline(route, peer_ids)
	if baseline.is_empty():
		return
	if not _write_marker("client_route_ready", "ok"):
		return
	if not await _wait_until(
		func() -> bool:
			return (
				route.is_normal_combat_active()
				and not route.get_normal_combat_occurrence_key().is_empty()
			),
		NETWORK_TIMEOUT_SECONDS
	):
		_fail("Client did not enter the Host combat occurrence")
		return
	var occurrence_key := await _wait_for_text_marker(
		"host_occurrence.txt",
		NETWORK_TIMEOUT_SECONDS
	)
	if occurrence_key.is_empty():
		return
	if route.get_normal_combat_occurrence_key() != occurrence_key:
		_fail("Client and Host combat occurrence keys differ")
		return
	var game := await _wait_for_combat_game(coordinator, "Client")
	if game == null:
		return
	var expected_loot := _capture_expected_loot(
		game,
		peer_ids,
		occurrence_key,
		content_seed
	)
	if expected_loot.size() != PLAYER_COUNT:
		return
	var spawn_marker := await _wait_for_json_marker(
		"host_spawn.json",
		COMBAT_TIMEOUT_SECONDS
	)
	if spawn_marker.is_empty():
		return
	var host_ids := _variant_array_to_sorted_ints(
		spawn_marker.get("enemy_ids", []) as Array
	)
	if host_ids.size() != EXPECTED_ENEMY_COUNT:
		_fail("Host spawn marker did not contain ten network enemy IDs")
		return
	if not await _wait_until(
		func() -> bool:
			return game.multiplayer_enemies_by_net_id.size() == EXPECTED_ENEMY_COUNT,
		NETWORK_TIMEOUT_SECONDS
	):
		_fail(
			"Client did not materialize ten robot proxies; saw %d"
			% game.multiplayer_enemies_by_net_id.size()
		)
		return
	var client_ids: Array[int] = []
	for peer_id_variant in game.multiplayer_enemies_by_net_id.keys():
		client_ids.append(int(peer_id_variant))
	client_ids.sort()
	if client_ids != host_ids:
		_fail("Client network enemy IDs differ from Host's batch")
		return
	for enemy_id in client_ids:
		var enemy := game.get_enemy_for_net_id(enemy_id) as Enemy
		if (
			enemy == null
			or not is_instance_valid(enemy)
			or not enemy.is_multiplayer_proxy
			or enemy.config == null
			or enemy.config.resource_path != COMBAT_ROBOT_CONFIG_PATH
		):
			_fail("Client enemy %d is not a synchronized combat robot proxy" % enemy_id)
	if not failures.is_empty():
		return
	print(
		"ROGUE_COMBAT_LAN_CLIENT_SPAWN occurrence=%s count=10 ids_match=true"
		% occurrence_key
	)
	if not _write_marker("client_spawn_ready", "ok"):
		return

	var settlement := await _wait_for_settlement_and_result(
		coordinator,
		route,
		"Client"
	)
	if settlement.is_empty():
		return
	_validate_victory_settlement(
		settlement,
		route,
		peer_ids,
		baseline,
		expected_loot,
		occurrence_key,
		combat_node_id,
		content_seed,
		"Client"
	)
	if not failures.is_empty():
		return
	if not await _wait_until(
		func() -> bool:
			return (
				coordinator.get("_phase")
				== RogueCombatMultiplayerCoordinator.ProtocolPhase.IDLE
				and bool(coordinator.get("_local_result_visible"))
			),
		NETWORK_TIMEOUT_SECONDS
	):
		_fail("Client did not reach terminal-safe IDLE with its result still open")
		return
	if not _write_marker("client_result_ready", "ok"):
		return
	if not await _wait_for_marker("host_result_closed", NETWORK_TIMEOUT_SECONDS):
		_fail("Client timed out waiting for Host result close")
		return
	if (
		not route.combat_result_overlay.visible
		or not bool(coordinator.get("_local_result_visible"))
		or str(coordinator.get("_local_result_occurrence_key")) != occurrence_key
	):
		_fail("Host result close incorrectly closed Client's independent result")
		return
	_route_dismiss_result(route)
	await process_frame
	if route.combat_result_overlay.visible or not str(
		coordinator.get("_local_result_occurrence_key")
	).is_empty():
		_fail("Client did not independently close its result")
		return
	if not _write_marker("client_result_closed", "ok"):
		return
	print("ROGUE_COMBAT_LAN_CLIENT_INDEPENDENT_RESULT_OK")


func _wait_for_combat_game(
	coordinator: RogueCombatMultiplayerCoordinator,
	label: String
) -> RogueCombatGame:
	var deadline := Time.get_ticks_msec() + int(
		NETWORK_TIMEOUT_SECONDS * 1000.0
	)
	var candidate: Variant = null
	while Time.get_ticks_msec() < deadline:
		if coordinator == null or not is_instance_valid(coordinator):
			_fail("%s coordinator was released during combat prepare" % label)
			return null
		candidate = coordinator.get("_combat_game")
		if candidate != null and is_instance_valid(candidate):
			break
		await process_frame
	if candidate == null or not is_instance_valid(candidate):
		_fail("%s combat runtime was not prepared" % label)
		return null
	var game := coordinator.get("_combat_game") as RogueCombatGame
	if game == null:
		_fail("%s embedded runtime is not RogueCombatGame" % label)
		return null
	while (
		Time.get_ticks_msec() < deadline
		and is_instance_valid(coordinator)
		and coordinator.get("_phase")
		!= RogueCombatMultiplayerCoordinator.ProtocolPhase.ACTIVE
	):
		await process_frame
	if (
		coordinator == null
		or not is_instance_valid(coordinator)
		or coordinator.get("_phase")
		!= RogueCombatMultiplayerCoordinator.ProtocolPhase.ACTIVE
	):
		_fail("%s combat prepare barrier never activated" % label)
		return null
	if (
		game.event_title != "狭路相逢"
		or not is_equal_approx(game.pre_wave_duration, 3.0)
		or not is_equal_approx(game.combat_time_limit_seconds, 90.0)
		or game.deadline_start != RogueCombatGame.DeadlineStart.WAVE_START
	):
		_fail("%s combat runtime does not carry the formal 3s/90s contract" % label)
		return null
	return game


func _on_host_enemy_spawned(
	net_id: int,
	enemy_config: EnemyConfig,
	spawn_position: Vector2
) -> void:
	host_spawn_ids.append(net_id)
	host_spawn_positions.append(spawn_position)
	host_spawn_config_paths.append(
		enemy_config.resource_path if enemy_config != null else ""
	)
	host_spawn_ticks.append(Time.get_ticks_msec())


func _validate_host_spawn_batch(game: RogueCombatGame) -> bool:
	if game.current_wave_total != EXPECTED_ENEMY_COUNT:
		_fail("Host formal wave total is not ten")
		return false
	if host_spawn_ids.size() != _unique_int_count(host_spawn_ids):
		_fail("Host spawn batch contains duplicate network IDs")
		return false
	for config_path in host_spawn_config_paths:
		if config_path != COMBAT_ROBOT_CONFIG_PATH:
			_fail(
				"Host spawn used a non-serializable/non-robot config path: %s"
				% config_path
			)
			return false
	var door_positions: Array[Vector2] = []
	for marker in game.active_wave_spawn_points:
		if marker != null and is_instance_valid(marker):
			door_positions.append(marker.global_position)
	if door_positions.size() != 3:
		_fail("Host formal wave did not activate all three red doors")
		return false
	for spawn_position in host_spawn_positions:
		var found_door := false
		for door_position in door_positions:
			if spawn_position.distance_to(door_position) <= 0.1:
				found_door = true
				break
		if not found_door:
			_fail("Host robot did not originate at an active red door")
			return false
	if _get_spawn_batch_duration_msec() > 50:
		_fail("Ten robots were not emitted in one spawn batch")
		return false
	return true


func _freeze_host_enemies(game: RogueCombatGame) -> void:
	for enemy_variant in game.multiplayer_enemies_by_net_id.values():
		var enemy := enemy_variant as Enemy
		if enemy == null or not is_instance_valid(enemy):
			continue
		enemy.velocity = Vector2.ZERO
		enemy.set_physics_process(false)


func _get_spawn_batch_duration_msec() -> int:
	if host_spawn_ticks.is_empty():
		return -1
	var minimum_tick := int(host_spawn_ticks[0])
	var maximum_tick := minimum_tick
	for tick in host_spawn_ticks:
		minimum_tick = mini(minimum_tick, int(tick))
		maximum_tick = maxi(maximum_tick, int(tick))
	return maximum_tick - minimum_tick


func _capture_expected_loot(
	game: RogueCombatGame,
	peer_ids: Array[int],
	occurrence_key: String,
	content_seed: int
) -> Dictionary:
	var result := {}
	for peer_id in peer_ids:
		var player := game.get_player_for_peer(peer_id) as Player
		var item := RogueCombatRewardResolver.roll_common_collectible(
			StringName(occurrence_key),
			content_seed,
			peer_id,
			true,
			player
		)
		if item == null:
			_fail("No compatible common collectible for peer %d" % peer_id)
			return {}
		result[peer_id] = item.resource_path
	return result


func _capture_route_and_inventory_baseline(
	route: TestRogueRouteP3,
	peer_ids: Array[int]
) -> Dictionary:
	var run_state := root.get_node_or_null("RunState") as RunStateStore
	if run_state == null:
		_fail("RunState autoload missing")
		return {}
	var xirang_by_peer := {}
	var inventory_total_by_peer := {}
	for peer_id in peer_ids:
		var player := route.get_player_for_peer(peer_id) as Player
		if player == null or not is_instance_valid(player):
			_fail("Route player missing for baseline peer %d" % peer_id)
			return {}
		xirang_by_peer[peer_id] = player.get_xirang()
		inventory_total_by_peer[peer_id] = _snapshot_item_total(
			run_state.export_inventory_snapshot_for_peer(peer_id)
		)
	return {
		"xirang_by_peer": xirang_by_peer,
		"inventory_total_by_peer": inventory_total_by_peer,
	}


func _wait_for_settlement_and_result(
	coordinator: RogueCombatMultiplayerCoordinator,
	route: TestRogueRouteP3,
	label: String
) -> Dictionary:
	var captured := {}
	var deadline := Time.get_ticks_msec() + int(COMBAT_TIMEOUT_SECONDS * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if captured.is_empty() and not watched_settlement.is_empty():
			captured = watched_settlement.duplicate(true)
		var pending := coordinator.get("_pending_settlement") as Dictionary
		if captured.is_empty() and not pending.is_empty():
			captured = pending.duplicate(true)
		if (
			not captured.is_empty()
			and bool(coordinator.get("_local_result_visible"))
			and route.combat_result_overlay.visible
		):
			return captured
		await process_frame
	print(
		(
			"ROGUE_COMBAT_LAN_%s_RESULT_TIMEOUT phase=%s pending=%d captured=%d "
			+ "local_visible=%s overlay_visible=%s result_occurrence=%s"
		) % [
			label.to_upper(),
			str(coordinator.get("_phase")),
			(coordinator.get("_pending_settlement") as Dictionary).size(),
			captured.size(),
			str(bool(coordinator.get("_local_result_visible"))),
			str(route.combat_result_overlay.visible),
			str(coordinator.get("_local_result_occurrence_key")),
		]
	)
	_fail("%s did not receive a victory settlement and visible result" % label)
	return {}


func _start_settlement_watch(
	coordinator: RogueCombatMultiplayerCoordinator,
	route: TestRogueRouteP3
) -> void:
	# terminal-safe 会立即释放战场协议并清空 _pending_settlement，但会按设计
	# 保留各端独立的可见结算。探针从进入战斗起缓存结算，并监听结果层
	# visibility_changed，在 show_victory 的同步调用栈内读取 Host 的短暂
	# SETTLED 状态；只按帧轮询仍可能在一帧内同时 SETTLED -> IDLE 而错过。
	watched_coordinator = coordinator
	watched_result_overlay = route.combat_result_overlay
	watched_settlement.clear()
	var watcher := Callable(self, "_capture_pending_settlement")
	if not process_frame.is_connected(watcher):
		process_frame.connect(watcher)
	if (
		watched_result_overlay != null
		and not watched_result_overlay.visibility_changed.is_connected(watcher)
	):
		watched_result_overlay.visibility_changed.connect(watcher)


func _capture_pending_settlement() -> void:
	if (
		not watched_settlement.is_empty()
		or watched_coordinator == null
		or not is_instance_valid(watched_coordinator)
	):
		return
	var pending := watched_coordinator.get("_pending_settlement") as Dictionary
	if not pending.is_empty():
		watched_settlement = pending.duplicate(true)


func _stop_settlement_watch() -> void:
	var watcher := Callable(self, "_capture_pending_settlement")
	if process_frame.is_connected(watcher):
		process_frame.disconnect(watcher)
	if (
		watched_result_overlay != null
		and is_instance_valid(watched_result_overlay)
		and watched_result_overlay.visibility_changed.is_connected(watcher)
	):
		watched_result_overlay.visibility_changed.disconnect(watcher)
	watched_coordinator = null
	watched_result_overlay = null


func _validate_victory_settlement(
	settlement: Dictionary,
	route: TestRogueRouteP3,
	peer_ids: Array[int],
	baseline: Dictionary,
	expected_loot: Dictionary,
	occurrence_key: String,
	combat_node_id: int,
	content_seed: int,
	label: String
) -> void:
	if (
		not bool(settlement.get("victory", false))
		or not bool(settlement.get("consume_node", false))
		or str(settlement.get("occurrence_key", "")) != occurrence_key
		or int(settlement.get("node_id", -1)) != combat_node_id
		or int(settlement.get("content_seed", 0)) != content_seed
	):
		_fail("%s settlement does not describe the authoritative victory" % label)
		return
	var final_xirang := settlement.get("final_xirang_by_peer", {}) as Dictionary
	var snapshots := settlement.get(
		"inventory_snapshots_by_peer",
		{}
	) as Dictionary
	var results := settlement.get("results_by_peer", {}) as Dictionary
	var baseline_xirang := baseline["xirang_by_peer"] as Dictionary
	var baseline_inventory := baseline["inventory_total_by_peer"] as Dictionary
	if (
		final_xirang.size() != peer_ids.size()
		or snapshots.size() != peer_ids.size()
		or results.size() != peer_ids.size()
	):
		_fail("%s settlement does not contain one independent result per peer" % label)
		return
	var run_state := root.get_node("RunState") as RunStateStore
	for peer_id in peer_ids:
		var expected_final_xirang := int(baseline_xirang[peer_id]) + (
			EXPECTED_TOTAL_XIRANG_DELTA
		)
		var peer_result := results.get(peer_id, {}) as Dictionary
		var loot := peer_result.get("loot", {}) as Dictionary
		var authoritative_snapshot := snapshots.get(peer_id, {}) as Dictionary
		var route_player := route.get_player_for_peer(peer_id) as Player
		if int(final_xirang.get(peer_id, -1)) != expected_final_xirang:
			_fail(
				"%s peer %d did not receive 100 kill + 500 extra Xirang"
				% [label, peer_id]
			)
		if route_player == null or route_player.get_xirang() != expected_final_xirang:
			_fail("%s route Xirang was not restored for peer %d" % [label, peer_id])
		if (
			not bool(peer_result.get("victory", false))
			or int(peer_result.get("peer_id", -1)) != peer_id
			or int(peer_result.get("extra_xirang", -1)) != EXPECTED_EXTRA_XIRANG
			or not bool(loot.get("granted", false))
			or not str(loot.get("failure_reason", "")).is_empty()
			or int(loot.get("rarity", -1))
			!= PickupConfig.CollectibleRarity.COMMON
			or str(loot.get("config_path", "")) != str(expected_loot[peer_id])
		):
			_fail("%s peer %d did not receive its deterministic common loot" % [label, peer_id])
		if _snapshot_item_total(authoritative_snapshot) != (
			int(baseline_inventory[peer_id]) + 1
		):
			_fail("%s authoritative inventory did not gain exactly one item" % label)
		var local_snapshot := run_state.export_inventory_snapshot_for_peer(peer_id)
		if _snapshot_item_total(local_snapshot) != int(baseline_inventory[peer_id]) + 1:
			_fail("%s applied inventory did not gain exactly one item" % label)
		print(
			"ROGUE_COMBAT_LAN_%s_REWARD peer=%d xirang_delta=%d extra=500 loot=%s granted=true"
			% [
				label.to_upper(),
				peer_id,
				int(final_xirang.get(peer_id, -1)) - int(baseline_xirang[peer_id]),
				str(loot.get("config_path", "")),
			]
		)
	if route.is_normal_combat_active() or not bool(
		route.get("_route_presentation_enabled")
	):
		_fail("%s did not return to the Rouge route before showing result" % label)
	if (
		route.combat_result_overlay.result_title_label.text != "通过作战"
		or route.combat_result_overlay.extra_xirang_value_label.text != "+500"
		or route.combat_result_overlay.loot_name_label.text == "无"
	):
		_fail("%s result Overlay does not show pass/+500/common loot" % label)


func _find_adjacent_normal_combat_fixture(
	config: RogueRouteGenerationConfig
) -> Dictionary:
	for seed in range(1, ROUTE_SEED_SEARCH_LIMIT + 1):
		var graph := RogueRouteGenerator.generate(config, seed)
		if graph == null:
			continue
		for neighbor_id in graph.get_neighbors(graph.start_node_id):
			if graph.get_node_type(neighbor_id) == RogueRouteGraph.NodeType.NORMAL_COMBAT:
				return {
					"seed": seed,
					"combat_node_id": int(neighbor_id),
					"content_seed": graph.get_node_content_seed(neighbor_id),
				}
	return {}


func _snapshot_item_total(snapshot: Dictionary) -> int:
	var total := 0
	for slot_variant in snapshot.get("slots", []) as Array:
		var slot := slot_variant as Dictionary
		total += maxi(int(slot.get("stack_count", 0)), 0)
	return total


func _route_dismiss_result(route: TestRogueRouteP3) -> void:
	# Same signal path as the real close button, without synthesizing GUI input.
	route.call("_on_combat_result_overlay_dismissed")


func _variant_array_to_sorted_ints(values: Array) -> Array[int]:
	var result: Array[int] = []
	for value in values:
		result.append(int(value))
	result.sort()
	return result


func _unique_int_count(values: Array[int]) -> int:
	var index := {}
	for value in values:
		index[value] = true
	return index.size()


func _get_sorted_peer_ids(net_manager: NetManagerStore) -> Array[int]:
	var result: Array[int] = []
	for peer_id_variant in net_manager.connected_players.keys():
		var peer_id := int(peer_id_variant)
		if peer_id > 0:
			result.append(peer_id)
	result.sort()
	return result


func _mount_wrapper() -> Node:
	var wrapper := WRAPPER_SCENE.instantiate() as Node
	if wrapper == null:
		_fail("MpRogueRoute wrapper could not instantiate")
		return null
	root.add_child(wrapper)
	current_scene = wrapper
	await process_frame
	return wrapper


func _wait_for_state(
	net_manager: NetManagerStore,
	target_state: int,
	timeout_seconds: float
) -> bool:
	return await _wait_until(
		func() -> bool: return int(net_manager.connection_state) == target_state,
		timeout_seconds
	)


func _wait_until(predicate: Callable, timeout_seconds: float) -> bool:
	var deadline := Time.get_ticks_msec() + int(timeout_seconds * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if bool(predicate.call()):
			return true
		await process_frame
	return bool(predicate.call())


func _wait_for_marker(marker_name: String, timeout_seconds: float) -> bool:
	return await _wait_until(
		func() -> bool: return FileAccess.file_exists(_marker_path(marker_name)),
		timeout_seconds
	)


func _wait_for_text_marker(marker_name: String, timeout_seconds: float) -> String:
	if not await _wait_for_marker(marker_name, timeout_seconds):
		_fail("Timed out waiting for marker: %s" % marker_name)
		return ""
	return FileAccess.get_file_as_string(_marker_path(marker_name)).strip_edges()


func _wait_for_json_marker(marker_name: String, timeout_seconds: float) -> Dictionary:
	var text := await _wait_for_text_marker(marker_name, timeout_seconds)
	if text.is_empty():
		return {}
	var parsed: Variant = JSON.parse_string(text)
	if not parsed is Dictionary:
		_fail("Marker is not valid JSON: %s" % marker_name)
		return {}
	return parsed as Dictionary


func _write_marker(marker_name: String, contents: String) -> bool:
	var file := FileAccess.open(_marker_path(marker_name), FileAccess.WRITE)
	if file == null:
		_fail("Could not write marker: %s" % marker_name)
		return false
	file.store_string(contents)
	file.close()
	return true


func _marker_path(marker_name: String) -> String:
	return sync_dir.path_join(marker_name)


func _wait_frames(frame_count: int) -> void:
	for _frame in range(frame_count):
		await process_frame


func _parse_options() -> Dictionary:
	var result := {}
	for argument in OS.get_cmdline_user_args():
		if not argument.begins_with("--probe-") or not argument.contains("="):
			continue
		var separator := argument.find("=")
		result[argument.substr(8, separator - 8)] = argument.substr(separator + 1)
	return result


func _fail(message: String) -> void:
	failures.append(message)


func _finish(role: String) -> void:
	_stop_settlement_watch()
	if failures.is_empty():
		print("ROGUE_COMBAT_LAN_%s_OK" % role.to_upper())
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)
