extends SceneTree

## 真双进程 Rouge「地下教会」LAN E2E 端点。
##
## 由 run_rogue_combat_lan_e2e.ps1 启动 Host + Client。两进程通过正式
## NetManager / MpRogueRoute / RogueCombatMultiplayerCoordinator 协议通信；
## 临时 marker 文件只用于探针阶段 barrier，不携带或替代任何游戏状态。

const WRAPPER_SCENE := preload("res://scene/multiplayer/mp_rogue_route.tscn")
const FORMAL_CONFIG := preload(
	"res://resources/config/rogue_combat/underground_church_01.tres"
)
const CARDBOARD_MONSTER_CONFIG_PATH := (
	"res://resources/config/enemies/cardboard_monster.tres"
)
const COMBAT_ROBOT_GUNNER_CONFIG_PATH := (
	"res://resources/config/enemies/combat_robot_gunner.tres"
)
const SLIME_CONFIG_PATH := "res://resources/config/enemies/slime.tres"
const EXPECTED_COMBAT_CONFIG_ID := &"underground_church_01"
const EXPECTED_COMBAT_SCENE_PATH := (
	"res://scene/game_modes/rogue/combat/rogue_combat_game_02.tscn"
)
const STATE_LOADING_GAME := NetManagerStore.ConnectionState.LOADING_GAME
const STATE_IN_GAME := NetManagerStore.ConnectionState.IN_GAME
const PLAYER_COUNT := 2
const ROUTE_SEED_SEARCH_LIMIT := 4096
const NETWORK_TIMEOUT_SECONDS := 30.0
const COMBAT_TIMEOUT_SECONDS := 55.0
const EXPECTED_ENEMY_COUNT := 70
const EXPECTED_MAX_ALIVE_ENEMIES := 20
const EXPECTED_SPAWN_INTERVAL_MSEC := 200
const SPAWN_INTERVAL_SCHEDULING_TOLERANCE_MSEC := 75
const EXPECTED_SPAWN_BATCH_TARGETS: Array[int] = [20, 40, 60, 70]
const EXPECTED_CONFIG_COUNTS := {
	CARDBOARD_MONSTER_CONFIG_PATH: 20,
	COMBAT_ROBOT_GUNNER_CONFIG_PATH: 20,
	SLIME_CONFIG_PATH: 30,
}
const EXPECTED_KILL_XIRANG := 290
const EXPECTED_EXTRA_XIRANG := 500
const EXPECTED_TOTAL_XIRANG_DELTA := (
	EXPECTED_KILL_XIRANG + EXPECTED_EXTRA_XIRANG
)

var failures: Array[String] = []
var sync_dir := ""
var host_spawn_ids: Array[int] = []
var host_spawn_positions: Array[Vector2] = []
var host_spawn_config_paths: PackedStringArray = []
var host_spawn_ticks: PackedInt64Array = []
var watched_host_game: RogueCombatGame = null
var host_peak_alive_count := 0
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

	var route := wrapper.get_node("RogueRoute") as RogueRouteGame
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
	var fixture := _find_adjacent_normal_combat_fixture(
		route.generation_config,
		route.floor_definition
	)
	if fixture.is_empty():
		_fail("Could not find an adjacent underground-church NORMAL_COMBAT seed")
		return
	var route_seed := int(fixture["seed"])
	var combat_node_id := int(fixture["combat_node_id"])
	var content_seed := int(fixture["content_seed"])
	if not route.start_authoritative_session(route_seed, true):
		_fail("Host could not install the deterministic combat route")
		return
	var selected_config := route.resolve_normal_combat_config_for_node(
		combat_node_id
	)
	if (
		selected_config == null
		or selected_config.encounter_id != EXPECTED_COMBAT_CONFIG_ID
	):
		_fail("Host formal combat pool did not resolve underground_church_01")
		return
	if not _write_marker("host_route.json", JSON.stringify({
		"route_seed": route_seed,
		"combat_node_id": combat_node_id,
		"content_seed": content_seed,
		"combat_config_id": String(selected_config.encounter_id),
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
	if runtime_state == null:
		_fail("Host route runtime state is missing")
		return
	var route_node_before := runtime_state.current_node_id
	var action_points_before := runtime_state.action_points
	var route_revision_before := runtime_state.state_revision
	var visit_count_before := int(
		runtime_state.visited_counts[combat_node_id]
	)
	route.route_board.complete_entry_reveal()
	route.route_board.node_pressed.emit(combat_node_id)
	if not await _wait_until(
		func() -> bool: return route.node_briefing.visible,
		NETWORK_TIMEOUT_SECONDS
	):
		_fail("Host did not present the normal-combat briefing")
		return
	if (
		route.move_confirmation.visible
		or not route.node_briefing.can_decide()
		or runtime_state.current_node_id != route_node_before
		or runtime_state.action_points != action_points_before
		or runtime_state.state_revision != route_revision_before
		or int(runtime_state.visited_counts[combat_node_id])
		!= visit_count_before
	):
		_fail("Host briefing presentation changed route state before confirmation")
		return
	if not await _wait_for_marker(
		"client_briefing_presented_1",
		NETWORK_TIMEOUT_SECONDS
	):
		_fail("Host timed out waiting for Client read-only briefing")
		return
	route.node_briefing.cancel_button.pressed.emit()
	if not await _wait_until(
		func() -> bool: return not route.node_briefing.visible,
		NETWORK_TIMEOUT_SECONDS
	):
		_fail("Host briefing did not close after cancel")
		return
	if not await _wait_for_marker(
		"client_briefing_canceled",
		NETWORK_TIMEOUT_SECONDS
	):
		_fail("Host timed out waiting for synchronized Client cancel")
		return
	if (
		runtime_state.current_node_id != route_node_before
		or runtime_state.action_points != action_points_before
		or runtime_state.state_revision != route_revision_before
		or int(runtime_state.visited_counts[combat_node_id])
		!= visit_count_before
	):
		_fail("Cancel changed AP, route revision, node, or visit count")
		return
	route.route_board.node_pressed.emit(combat_node_id)
	if not await _wait_until(
		func() -> bool: return route.node_briefing.visible,
		NETWORK_TIMEOUT_SECONDS
	):
		_fail("Host could not reopen the normal-combat briefing")
		return
	if not await _wait_for_marker(
		"client_briefing_presented_2",
		NETWORK_TIMEOUT_SECONDS
	):
		_fail("Host timed out waiting for Client reopened briefing")
		return
	route.node_briefing.confirm_button.pressed.emit()
	route.node_briefing.confirm_button.pressed.emit()
	if not await _wait_until(
		func() -> bool:
			return (
				route.is_normal_combat_active()
				and not route.get_normal_combat_occurrence_key().is_empty()
			),
		NETWORK_TIMEOUT_SECONDS
	):
		_fail("Host cover-ready barrier did not commit the combat move")
		return
	if (
		runtime_state.current_node_id != combat_node_id
		or runtime_state.action_points
		!= action_points_before - route.generation_config.move_action_cost
		or runtime_state.state_revision != route_revision_before + 1
		or int(runtime_state.visited_counts[combat_node_id])
		!= visit_count_before + 1
	):
		_fail("Confirmed briefing did not commit exactly one route move")
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
		coordinator,
		peer_ids,
		occurrence_key,
		content_seed
	)
	if expected_loot.size() != PLAYER_COUNT:
		return
	var gameplay_gateway := game.get_multiplayer_gameplay_gateway()
	if gameplay_gateway == null:
		_fail("Host combat runtime is missing MultiplayerGameplayGateway")
		return
	watched_host_game = game
	if not gameplay_gateway.enemy_spawned.is_connected(_on_host_enemy_spawned):
		gameplay_gateway.enemy_spawned.connect(_on_host_enemy_spawned)
	var previous_spawn_count := 0
	for target_count in EXPECTED_SPAWN_BATCH_TARGETS:
		var expected_active_count := mini(
			EXPECTED_MAX_ALIVE_ENEMIES,
			EXPECTED_ENEMY_COUNT - previous_spawn_count
		)
		if not await _wait_for_host_spawn_target(
			game,
			target_count,
			expected_active_count,
			COMBAT_TIMEOUT_SECONDS
		):
			return
		_freeze_host_enemies(game)
		var batch_ids: Array[int] = []
		for spawn_index in range(previous_spawn_count, target_count):
			batch_ids.append(host_spawn_ids[spawn_index])
		var cumulative_ids := host_spawn_ids.duplicate()
		cumulative_ids.sort()
		var marker_name := _host_spawn_marker_name(target_count)
		if not _write_marker(marker_name, JSON.stringify({
			"occurrence_key": occurrence_key,
			"target_count": target_count,
			"batch_ids": batch_ids,
			"all_enemy_ids": cumulative_ids,
			"spawn_ticks": Array(host_spawn_ticks),
			"spawn_positions": _vector2_array_to_json(host_spawn_positions),
		})):
			return
		if not await _wait_for_marker(
			_client_spawn_ready_marker_name(target_count),
			NETWORK_TIMEOUT_SECONDS
		):
			_fail(
				"Host timed out waiting for Client spawn batch %d confirmation"
				% target_count
			)
			return
		if not await _defeat_host_enemy_batch(game, batch_ids):
			return
		previous_spawn_count = target_count
	if not _validate_host_spawn_contract(game):
		return
	print(
		(
			"ROGUE_COMBAT_LAN_HOST_SPAWN occurrence=%s config=%s count=70 "
			+ "types=20/20/30 max_alive=20 interval_ms=%d"
		)
		% [
			occurrence_key,
			String(EXPECTED_COMBAT_CONFIG_ID),
			_get_minimum_adjacent_spawn_interval_msec(),
		]
	)
	if not await _wait_until(
		func() -> bool:
			return (
				game.current_wave_defeated == EXPECTED_ENEMY_COUNT
				and game.multiplayer_enemies_by_net_id.is_empty()
			),
		12.0
	):
		_fail(
			"Host enemies did not fully resolve: defeated=%d network=%d"
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
	var route := wrapper.get_node("RogueRoute") as RogueRouteGame
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
	var expected_config_id := StringName(
		route_marker.get("combat_config_id", "")
	)
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
	var selected_config := route.resolve_normal_combat_config_for_node(
		combat_node_id
	)
	if (
		expected_config_id != EXPECTED_COMBAT_CONFIG_ID
		or selected_config == null
		or selected_config.encounter_id != expected_config_id
	):
		_fail("Client combat-pool resolution differs from Host underground church")
		return
	var peer_ids := _get_sorted_peer_ids(net_manager)
	if peer_ids.size() != PLAYER_COUNT:
		_fail("Client expected exactly two participant peers")
		return
	var baseline := _capture_route_and_inventory_baseline(route, peer_ids)
	if baseline.is_empty():
		return
	var runtime_state := route.get("_runtime_state") as RogueRouteRuntimeState
	if runtime_state == null:
		_fail("Client route runtime state is missing")
		return
	var route_node_before := runtime_state.current_node_id
	var action_points_before := runtime_state.action_points
	var route_revision_before := runtime_state.state_revision
	var visit_count_before := int(
		runtime_state.visited_counts[combat_node_id]
	)
	if not _write_marker("client_route_ready", "ok"):
		return
	if not await _wait_until(
		func() -> bool: return route.node_briefing.visible,
		NETWORK_TIMEOUT_SECONDS
	):
		_fail("Client did not receive the Host briefing")
		return
	var first_briefing_revision := int(
		route.export_briefing_state_snapshot().get("revision", -1)
	)
	if (
		route.node_briefing.can_decide()
		or not route.node_briefing.cancel_button.disabled
		or not route.node_briefing.confirm_button.disabled
		or route.move_confirmation.visible
		or runtime_state.current_node_id != route_node_before
		or runtime_state.action_points != action_points_before
		or runtime_state.state_revision != route_revision_before
		or int(runtime_state.visited_counts[combat_node_id])
		!= visit_count_before
	):
		_fail("Client briefing was interactive or changed route state")
		return
	if not _write_marker("client_briefing_presented_1", "ok"):
		return
	if not await _wait_until(
		func() -> bool:
			return (
				not route.node_briefing.visible
				and int(route.export_briefing_state_snapshot().get("phase", -1))
				== RogueRouteGame.BriefingPhase.NONE
			),
		NETWORK_TIMEOUT_SECONDS
	):
		_fail("Client did not synchronize the Host briefing cancel")
		return
	if (
		runtime_state.current_node_id != route_node_before
		or runtime_state.action_points != action_points_before
		or runtime_state.state_revision != route_revision_before
		or int(runtime_state.visited_counts[combat_node_id])
		!= visit_count_before
	):
		_fail("Synchronized briefing cancel changed Client route state")
		return
	if not _write_marker("client_briefing_canceled", "ok"):
		return
	if not await _wait_until(
		func() -> bool:
			return (
				route.node_briefing.visible
				and int(route.export_briefing_state_snapshot().get("revision", -1))
				> first_briefing_revision
			),
		NETWORK_TIMEOUT_SECONDS
	):
		_fail("Client did not receive the reopened Host briefing")
		return
	if route.node_briefing.can_decide():
		_fail("Client reopened briefing unexpectedly allowed decisions")
		return
	if not _write_marker("client_briefing_presented_2", "ok"):
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
	if route.get_active_combat_config_id() != expected_config_id:
		_fail("Client route froze a combat config different from Host")
		return
	var game := await _wait_for_combat_game(coordinator, "Client")
	if game == null:
		return
	# 收藏品现由Host按稳定玩家身份权威抽取；Client不再按本地可见身份
	# 预演远端玩家结果，只验证收到的权威奖励合同与背包快照。
	var expected_loot := {}
	for peer_id in peer_ids:
		expected_loot[peer_id] = ""
	var observed_ids: Dictionary[int, bool] = {}
	var observed_config_counts: Dictionary[String, int] = {}
	var observed_door_counts: Array[int] = [0, 0, 0]
	var final_host_ids: Array[int] = []
	var final_host_spawn_ticks: PackedInt64Array = []
	var final_host_spawn_positions: Array[Vector2] = []
	for target_count in EXPECTED_SPAWN_BATCH_TARGETS:
		var spawn_marker := await _wait_for_json_marker(
			_host_spawn_marker_name(target_count),
			COMBAT_TIMEOUT_SECONDS
		)
		if spawn_marker.is_empty():
			return
		if (
			str(spawn_marker.get("occurrence_key", "")) != occurrence_key
			or int(spawn_marker.get("target_count", -1)) != target_count
		):
			_fail("Host spawn marker %d describes the wrong occurrence" % target_count)
			return
		var batch_ids := _variant_array_to_sorted_ints(
			spawn_marker.get("batch_ids", []) as Array
		)
		var expected_batch_size := mini(
			EXPECTED_MAX_ALIVE_ENEMIES,
			EXPECTED_ENEMY_COUNT - observed_ids.size()
		)
		if batch_ids.size() != expected_batch_size:
			_fail(
				"Host spawn marker %d has wrong batch size: %d"
				% [target_count, batch_ids.size()]
			)
			return
		if not await _wait_for_client_enemy_batch(game, batch_ids):
			return
		for enemy_id in batch_ids:
			if observed_ids.has(enemy_id):
				_fail("Client observed duplicate network enemy ID %d" % enemy_id)
				continue
			var enemy := game.get_enemy_for_net_id(enemy_id) as Enemy
			if not _record_client_enemy_contract(
				enemy_id,
				enemy,
				observed_config_counts
			):
				continue
			observed_ids[enemy_id] = true
		if not failures.is_empty():
			return
		final_host_ids = _variant_array_to_sorted_ints(
			spawn_marker.get("all_enemy_ids", []) as Array
		)
		final_host_spawn_ticks = _variant_array_to_packed_int64(
			spawn_marker.get("spawn_ticks", []) as Array
		)
		final_host_spawn_positions = _variant_array_to_vector2s(
			spawn_marker.get("spawn_positions", []) as Array
		)
		if not _write_marker(
			_client_spawn_ready_marker_name(target_count),
			"ok"
		):
			return
	if not _validate_client_spawn_contract(
		observed_ids,
		observed_config_counts,
		observed_door_counts,
		final_host_ids,
		final_host_spawn_ticks,
		final_host_spawn_positions,
		game
	):
		return
	print(
		(
			"ROGUE_COMBAT_LAN_CLIENT_SPAWN occurrence=%s config=%s count=70 "
			+ "types=20/20/30 doors=%s ids_match=true interval_ms=%d"
		)
		% [
			occurrence_key,
			String(EXPECTED_COMBAT_CONFIG_ID),
			observed_door_counts,
			_get_minimum_interval_from_ticks(final_host_spawn_ticks),
		]
	)

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
		coordinator.get("_active_combat_config_id")
		!= EXPECTED_COMBAT_CONFIG_ID
		or game.scene_file_path != EXPECTED_COMBAT_SCENE_PATH
		or game.event_title != "地下教会"
		or not is_equal_approx(game.pre_wave_duration, 3.0)
		or not is_equal_approx(game.combat_time_limit_seconds, 90.0)
		or game.deadline_start != RogueCombatGame.DeadlineStart.WAVE_START
	):
		_fail(
			"%s combat runtime does not carry the formal church/config/3s/90s contract"
			% label
		)
		return null
	if not _validate_fixed_underground_night(game, label):
		return null
	return game


func _validate_fixed_underground_night(
	game: RogueCombatGame,
	label: String
) -> bool:
	var controller := game.day_night_controller
	if (
		game.world_lighting_policy
		!= CombatRuntimeBase.WorldLightingPolicy.FIXED_NIGHT
		or controller == null
		or not controller.night_color.is_equal_approx(
			RogueCombatGame.UNDERGROUND_NIGHT_COLOR
		)
		or not controller.color.is_equal_approx(
			RogueCombatGame.UNDERGROUND_NIGHT_COLOR
		)
		or not is_equal_approx(controller.night_factor, 1.0)
		or not controller.is_night()
		or controller.is_transitioning()
		or controller.get("_transition_tween") != null
	):
		_fail(
			(
				"%s combat runtime must keep FIXED_NIGHT, factor=1, "
				+ "UNDERGROUND_NIGHT_COLOR, and no lighting Tween"
			)
			% label
		)
		return false
	return true


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
	if watched_host_game != null and is_instance_valid(watched_host_game):
		host_peak_alive_count = maxi(
			host_peak_alive_count,
			watched_host_game.multiplayer_enemies_by_net_id.size()
		)
		if host_peak_alive_count > EXPECTED_MAX_ALIVE_ENEMIES:
			_fail(
				"Host exceeded the configured twenty-enemy alive cap: %d"
				% host_peak_alive_count
			)


func _wait_for_host_spawn_target(
	game: RogueCombatGame,
	target_count: int,
	expected_active_count: int,
	timeout_seconds: float
) -> bool:
	var deadline := Time.get_ticks_msec() + int(timeout_seconds * 1000.0)
	while Time.get_ticks_msec() < deadline:
		_freeze_host_enemies(game)
		var active_count := game.multiplayer_enemies_by_net_id.size()
		if active_count > EXPECTED_MAX_ALIVE_ENEMIES:
			_fail(
				"Host exceeded the configured twenty-enemy alive cap: %d"
				% active_count
			)
			return false
		if (
			game.current_wave_spawned == target_count
			and host_spawn_ids.size() == target_count
			and active_count == expected_active_count
		):
			return true
		await process_frame
	_fail(
		(
			"Host did not reach spawn target %d: wave=%d network=%d "
			+ "signals=%d defeated=%d"
		)
		% [
			target_count,
			game.current_wave_spawned,
			game.multiplayer_enemies_by_net_id.size(),
			host_spawn_ids.size(),
			game.current_wave_defeated,
		]
	)
	return false


func _defeat_host_enemy_batch(
	game: RogueCombatGame,
	batch_ids: Array[int]
) -> bool:
	for enemy_id in batch_ids:
		var enemy := game.get_enemy_for_net_id(enemy_id) as Enemy
		if enemy == null or not is_instance_valid(enemy):
			_fail("Host enemy disappeared before authoritative defeat: %d" % enemy_id)
			continue
		if not enemy.apply_damage(
			99999,
			Vector2.ZERO,
			EnemyConfig.DamageType.PHYSICAL,
			false
		):
			_fail("Host could not apply lethal damage to enemy %d" % enemy_id)
			continue
		# 纸箱怪使用每次命中固定1点的受伤规则；测试需要结算整批，而不是
		# 绕过 defeated 信号直接释放尚未死亡的实例。
		if not enemy.is_dead:
			enemy.call("_die")
		if not enemy.is_dead:
			_fail("Host could not authoritatively defeat enemy %d" % enemy_id)
			continue
		if enemy.has_method("_finish_after_death_animation"):
			enemy.call_deferred("_finish_after_death_animation")
	if not failures.is_empty():
		return false
	if not await _wait_until(
		func() -> bool:
			for enemy_id in batch_ids:
				if game.get_enemy_for_net_id(enemy_id) != null:
					return false
			return true,
		12.0
	):
		_fail("Host authoritative defeated batch did not leave the network roster")
		return false
	return true


func _validate_host_spawn_contract(game: RogueCombatGame) -> bool:
	if game.current_wave_total != EXPECTED_ENEMY_COUNT:
		_fail("Host formal wave total is not seventy")
		return false
	if host_spawn_ids.size() != _unique_int_count(host_spawn_ids):
		_fail("Host spawn sequence contains duplicate network IDs")
		return false
	if host_spawn_ids.size() != EXPECTED_ENEMY_COUNT:
		_fail("Host did not emit all seventy network enemy IDs")
		return false
	var wave := game.current_flow_step as WaveConfig
	if (
		wave == null
		or not is_equal_approx(wave.spawn_interval, 0.2)
		or wave.spawn_count_per_tick != 1
		or wave.max_alive_enemies != EXPECTED_MAX_ALIVE_ENEMIES
		or wave.spawn_point_order
		!= WaveConfig.SpawnPointOrder.BALANCED_SHUFFLE_BAG
	):
		_fail("Host formal wave does not use 0.2s/one/twenty/balanced spawn policy")
		return false
	if host_peak_alive_count != EXPECTED_MAX_ALIVE_ENEMIES:
		_fail(
			"Host peak alive count must reach but never exceed twenty: %d"
			% host_peak_alive_count
		)
		return false
	var config_counts: Dictionary[String, int] = {}
	for config_path in host_spawn_config_paths:
		if not EXPECTED_CONFIG_COUNTS.has(config_path):
			_fail(
				"Host spawn used an unexpected/non-serializable config path: %s"
				% config_path
			)
			return false
		config_counts[config_path] = config_counts.get(config_path, 0) + 1
	if not _config_counts_match_expected(config_counts):
		_fail("Host enemy composition is not 20 cardboard / 20 gunner / 30 slime")
		return false
	var door_positions: Array[Vector2] = []
	for marker in game.active_wave_spawn_points:
		if marker != null and is_instance_valid(marker):
			door_positions.append(marker.global_position)
	if door_positions.size() != 3:
		_fail("Host formal wave did not activate all three red doors")
		return false
	var door_counts: Array[int] = [0, 0, 0]
	for spawn_position in host_spawn_positions:
		var found_door_index := -1
		for door_index in range(door_positions.size()):
			var door_position := door_positions[door_index]
			if spawn_position.distance_to(door_position) <= 0.1:
				found_door_index = door_index
				break
		if found_door_index < 0:
			_fail("Host enemy did not originate at an active red door")
			return false
		door_counts[found_door_index] += 1
	if _int_count_spread(door_counts) > 1:
		_fail("Host red-door spawn distribution is not balanced: %s" % [door_counts])
		return false
	var minimum_interval := _get_minimum_adjacent_spawn_interval_msec()
	if minimum_interval < (
		EXPECTED_SPAWN_INTERVAL_MSEC
		- SPAWN_INTERVAL_SCHEDULING_TOLERANCE_MSEC
	):
		_fail(
			"Host spawned adjacent enemies too quickly: %d ms"
			% minimum_interval
		)
		return false
	return true


func _freeze_host_enemies(game: RogueCombatGame) -> void:
	for enemy_variant in game.multiplayer_enemies_by_net_id.values():
		var enemy := enemy_variant as Enemy
		if enemy == null or not is_instance_valid(enemy):
			continue
		enemy.velocity = Vector2.ZERO
		enemy.set_physics_process(false)


func _get_minimum_adjacent_spawn_interval_msec() -> int:
	return _get_minimum_interval_from_ticks(host_spawn_ticks)


func _get_minimum_interval_from_ticks(ticks: PackedInt64Array) -> int:
	if ticks.size() < 2:
		return -1
	var minimum_interval := 2147483647
	for index in range(1, ticks.size()):
		minimum_interval = mini(
			minimum_interval,
			int(ticks[index] - ticks[index - 1])
		)
	return minimum_interval


func _wait_for_client_enemy_batch(
	game: RogueCombatGame,
	batch_ids: Array[int]
) -> bool:
	var ready := await _wait_until(
		func() -> bool:
			if (
				game.multiplayer_enemies_by_net_id.size()
				> EXPECTED_MAX_ALIVE_ENEMIES
			):
				return false
			for enemy_id in batch_ids:
				var enemy := game.get_enemy_for_net_id(enemy_id) as Enemy
				if (
					enemy == null
					or not is_instance_valid(enemy)
					or not enemy.is_multiplayer_proxy
					or enemy.config == null
				):
					return false
			return true,
		NETWORK_TIMEOUT_SECONDS
	)
	if not ready:
		_fail(
			"Client did not materialize synchronized proxy batch: %s"
			% [batch_ids]
		)
		return false
	if game.multiplayer_enemies_by_net_id.size() > EXPECTED_MAX_ALIVE_ENEMIES:
		_fail("Client observed more than twenty simultaneous enemy proxies")
		return false
	return true


func _record_client_enemy_contract(
	enemy_id: int,
	enemy: Enemy,
	config_counts: Dictionary[String, int]
) -> bool:
	if (
		enemy == null
		or not is_instance_valid(enemy)
		or not enemy.is_multiplayer_proxy
		or enemy.config == null
	):
		_fail("Client enemy %d is not a synchronized proxy" % enemy_id)
		return false
	var config_path := enemy.config.resource_path
	if not EXPECTED_CONFIG_COUNTS.has(config_path):
		_fail(
			"Client enemy %d used unexpected config path %s"
			% [enemy_id, config_path]
		)
		return false
	config_counts[config_path] = config_counts.get(config_path, 0) + 1
	return true


func _validate_client_spawn_contract(
	observed_ids: Dictionary[int, bool],
	config_counts: Dictionary[String, int],
	door_counts: Array[int],
	host_ids: Array[int],
	host_spawn_ticks: PackedInt64Array,
	host_spawn_positions: Array[Vector2],
	game: RogueCombatGame
) -> bool:
	if observed_ids.size() != EXPECTED_ENEMY_COUNT:
		_fail("Client did not observe seventy unique network enemy IDs")
		return false
	var client_ids: Array[int] = []
	for enemy_id in observed_ids.keys():
		client_ids.append(enemy_id)
	client_ids.sort()
	if (
		host_ids.size() != EXPECTED_ENEMY_COUNT
		or host_ids.size() != _unique_int_count(host_ids)
		or client_ids != host_ids
	):
		_fail("Client cumulative enemy IDs differ from Host's seventy IDs")
		return false
	if not _config_counts_match_expected(config_counts):
		_fail("Client enemy composition is not 20 cardboard / 20 gunner / 30 slime")
		return false
	if host_spawn_positions.size() != EXPECTED_ENEMY_COUNT:
		_fail("Client did not receive seventy authoritative spawn positions")
		return false
	var client_door_positions := _get_authored_red_door_positions(game)
	if client_door_positions.size() != 3:
		_fail("Client formal wave did not activate all three red doors")
		return false
	for spawn_position in host_spawn_positions:
		var found_door_index := -1
		for door_index in range(client_door_positions.size()):
			if spawn_position.distance_to(client_door_positions[door_index]) <= 0.1:
				found_door_index = door_index
				break
		if found_door_index < 0:
			_fail("Client received a spawn outside all active red doors")
			return false
		door_counts[found_door_index] += 1
	if door_counts.size() != 3 or _int_count_spread(door_counts) > 1:
		_fail("Client red-door spawn distribution is not balanced: %s" % [door_counts])
		return false
	if host_spawn_ticks.size() != EXPECTED_ENEMY_COUNT:
		_fail("Client did not receive seventy authoritative spawn timestamps")
		return false
	var minimum_interval := _get_minimum_interval_from_ticks(host_spawn_ticks)
	if minimum_interval < (
		EXPECTED_SPAWN_INTERVAL_MSEC
		- SPAWN_INTERVAL_SCHEDULING_TOLERANCE_MSEC
	):
		_fail(
			"Client found adjacent authoritative spawns too close: %d ms"
			% minimum_interval
		)
		return false
	return true


func _config_counts_match_expected(counts: Dictionary[String, int]) -> bool:
	if counts.size() != EXPECTED_CONFIG_COUNTS.size():
		return false
	for config_path in EXPECTED_CONFIG_COUNTS:
		if int(counts.get(config_path, 0)) != int(
			EXPECTED_CONFIG_COUNTS[config_path]
		):
			return false
	return true


func _int_count_spread(counts: Array[int]) -> int:
	if counts.is_empty():
		return 0
	return int(counts.max()) - int(counts.min())


func _get_authored_red_door_positions(game: RogueCombatGame) -> Array[Vector2]:
	var result: Array[Vector2] = []
	var spawn_root := game.get_node_or_null("EnemySpawnPoints") as Node2D
	if spawn_root == null:
		return result
	for spawn_name in [&"Spawn1", &"Spawn2", &"Spawn3"]:
		var marker := spawn_root.get_node_or_null(NodePath(String(spawn_name))) as Marker2D
		if marker != null:
			result.append(marker.global_position)
	return result


func _host_spawn_marker_name(target_count: int) -> String:
	return "host_spawn_%d.json" % target_count


func _client_spawn_ready_marker_name(target_count: int) -> String:
	return "client_spawn_%d_ready" % target_count


func _capture_expected_loot(
	game: RogueCombatGame,
	coordinator: RogueCombatMultiplayerCoordinator,
	peer_ids: Array[int],
	occurrence_key: String,
	content_seed: int
) -> Dictionary:
	var result := {}
	var stable_keys := coordinator.get("_participant_stable_keys") as Dictionary
	for peer_id in peer_ids:
		var player := game.get_player_for_peer(peer_id) as Player
		var pool: Array[PickupConfig] = []
		for candidate in CollectibleRegistry.get_by_rarity(
			PickupConfig.CollectibleRarity.COMMON
		):
			if (
				candidate.can_store_in_inventory
				and player != null
				and player.is_collectible_compatible(candidate)
			):
				pool.append(candidate)
		pool.sort_custom(
			func(left: PickupConfig, right: PickupConfig) -> bool:
				return left.resource_path < right.resource_path
		)
		var identity := str(stable_keys.get(peer_id, "")).strip_edges()
		if identity.is_empty():
			identity = "peer:%d" % peer_id
		var chosen_index := RogueEncounterRandom.choose_index(
			content_seed,
			StringName(
				"rogue_combat_collectible_batch|occurrence:%s|identity:%s|contract:%s|roll:0"
				% [
					occurrence_key,
					identity,
					FORMAL_CONFIG.reward_config.compute_runtime_contract_hash(),
				]
			),
			pool.size()
		)
		if chosen_index < 0:
			_fail("No compatible common collectible for peer %d" % peer_id)
			return {}
		var item := pool[chosen_index]
		result[peer_id] = item.resource_path
	return result


func _capture_route_and_inventory_baseline(
	route: RogueRouteGame,
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
	route: RogueRouteGame,
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
	route: RogueRouteGame
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
	route: RogueRouteGame,
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
				"%s peer %d did not receive 290 kill + 500 extra Xirang"
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
			or (
				not str(expected_loot[peer_id]).is_empty()
				and str(loot.get("config_path", ""))
				!= str(expected_loot[peer_id])
			)
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
	config: RogueRouteGenerationConfig,
	floor_definition: RogueRouteFloorDefinition
) -> Dictionary:
	if floor_definition == null or floor_definition.normal_combat_pool == null:
		return {}
	for seed in range(1, ROUTE_SEED_SEARCH_LIMIT + 1):
		var graph := RogueRouteGenerator.generate(config, seed)
		if graph == null:
			continue
		for neighbor_id in graph.get_neighbors(graph.start_node_id):
			if (
				graph.get_node_type(neighbor_id)
				!= RogueRouteGraph.NodeType.NORMAL_COMBAT
			):
				continue
			var content_seed := graph.get_node_content_seed(neighbor_id)
			var selected_config := floor_definition.select_normal_combat_config(
				content_seed
			)
			if (
				selected_config == null
				or selected_config.encounter_id != EXPECTED_COMBAT_CONFIG_ID
			):
				continue
			return {
				"seed": seed,
				"combat_node_id": int(neighbor_id),
				"content_seed": content_seed,
			}
	return {}


func _snapshot_item_total(snapshot: Dictionary) -> int:
	var total := 0
	for slot_variant in snapshot.get("slots", []) as Array:
		var slot := slot_variant as Dictionary
		total += maxi(int(slot.get("stack_count", 0)), 0)
	return total


func _route_dismiss_result(route: RogueRouteGame) -> void:
	# Same signal path as the real close button, without synthesizing GUI input.
	route.call("_on_combat_result_overlay_dismissed")


func _variant_array_to_sorted_ints(values: Array) -> Array[int]:
	var result: Array[int] = []
	for value in values:
		result.append(int(value))
	result.sort()
	return result


func _variant_array_to_packed_int64(values: Array) -> PackedInt64Array:
	var result := PackedInt64Array()
	for value in values:
		result.append(int(value))
	return result


func _vector2_array_to_json(values: Array[Vector2]) -> Array:
	var result := []
	for value in values:
		result.append([value.x, value.y])
	return result


func _variant_array_to_vector2s(values: Array) -> Array[Vector2]:
	var result: Array[Vector2] = []
	for value_variant in values:
		var components := value_variant as Array
		if components.size() != 2:
			_fail("Spawn marker contains an invalid Vector2 encoding")
			continue
		result.append(Vector2(float(components[0]), float(components[1])))
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
