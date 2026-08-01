extends SceneTree

const WRAPPER_SCENE := preload("res://scene/multiplayer/mp_rogue_route.tscn")
const STATE_LOADING_GAME := NetManagerStore.ConnectionState.LOADING_GAME
const STATE_IN_GAME := NetManagerStore.ConnectionState.IN_GAME
const TIMEOUT_SECONDS := 12.0
const AVATAR_SYNC_TIMEOUT_SECONDS := 5.0
const AVATAR_TEST_MOVE_DISTANCE := 24.0

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var options := _parse_options()
	var role := str(options.get("role", ""))
	var port := int(options.get("port", "29191"))
	var net_manager := root.get_node_or_null("NetManager") as NetManagerStore
	if net_manager == null:
		_fail("NetManager autoload missing")
		_finish(role)
		return
	net_manager.disconnect_from_game()
	net_manager.local_player_name = "P3%s" % role.capitalize()

	match role:
		"host":
			await _run_host(net_manager, port)
		"client":
			await _run_client(net_manager, port)
		_:
			_fail("unsupported role: %s" % role)

	if net_manager.is_multiplayer_active():
		net_manager.disconnect_from_game()
	await _wait_frames(3)
	_finish(role)


func _run_host(net_manager: NetManagerStore, port: int) -> void:
	if not net_manager.set_host_game_mode(NetManagerStore.GameMode.TEST_ARENA_P3):
		_fail("Host could not select P3")
		return
	var error := net_manager.host_create_lan_server(port, 2)
	if error != OK:
		_fail("Host create failed: %s" % error_string(error))
		return
	if not await _wait_until(
		func() -> bool: return net_manager.connected_players.size() == 2,
		TIMEOUT_SECONDS
	):
		_fail("Host timed out waiting for client")
		return
	net_manager.host_start_game()
	if not await _wait_for_state(net_manager, STATE_LOADING_GAME, 3.0):
		_fail("Host did not enter loading")
		return
	var wrapper := await _mount_wrapper()
	if wrapper == null:
		return
	if not await _wait_for_state(net_manager, STATE_IN_GAME, TIMEOUT_SECONDS):
		_fail("Host did not pass loading barrier")
		return
	var route := wrapper.get_node("RogueRoute") as TestRogueRouteP3
	if not route.is_route_ready():
		_fail("Host route was not generated")
		return
	var host_peer_id := net_manager.get_host_peer_id()
	var client_peer_id := _find_other_peer_id(
		net_manager.connected_players,
		host_peer_id
	)
	var host_player := route.get_player_for_peer(host_peer_id)
	var client_player := route.get_player_for_peer(client_peer_id)
	if host_player == null or client_player == null:
		_fail("Host route did not instantiate both avatars")
		return
	var client_start := client_player.global_position
	if not await _wait_until(
		func() -> bool:
			return client_player.global_position.distance_to(client_start) > 8.0,
		AVATAR_SYNC_TIMEOUT_SECONDS
	):
		_fail("Host did not receive the client's avatar movement")
		return
	var host_start := host_player.global_position
	host_player.global_position = route.clamp_avatar_position(
		host_start + Vector2(AVATAR_TEST_MOVE_DISTANCE, 0.0)
	)
	host_player.velocity = Vector2.ZERO
	# Give the client time to observe Host movement and then exercise reliable
	# out-of-bounds correction before the route move teleports the party.
	await create_timer(1.5).timeout
	var state := route.export_state_snapshot()
	var target_node_id := _find_first_neighbor(
		route.export_layout_snapshot(),
		int(state.get("current_node_id", -1))
	)
	if target_node_id < 0:
		_fail("Host route start has no neighbor")
		return
	var runtime_state := route.get("_runtime_state") as RogueRouteRuntimeState
	var move_cost := int(route.generation_config.move_action_cost)
	if not runtime_state.try_move(
		target_node_id,
		move_cost,
		int(state.get("revision", -1))
	):
		_fail("Host authoritative move failed")
		return
	await create_timer(1.0).timeout


func _run_client(net_manager: NetManagerStore, port: int) -> void:
	var error := net_manager.client_connect_lan("127.0.0.1", port)
	if error != OK:
		_fail("Client connect failed: %s" % error_string(error))
		return
	if not await _wait_for_state(net_manager, STATE_LOADING_GAME, TIMEOUT_SECONDS):
		_fail("Client did not receive P3 start")
		return
	if net_manager.current_game_mode != NetManagerStore.GameMode.TEST_ARENA_P3:
		_fail("Client did not receive P3 mode")
		return
	var wrapper := await _mount_wrapper()
	if wrapper == null:
		return
	if not await _wait_for_state(net_manager, STATE_IN_GAME, TIMEOUT_SECONDS):
		_fail("Client did not pass loading barrier")
		return
	var route := wrapper.get_node("RogueRoute") as TestRogueRouteP3
	if not await _wait_until(route.is_route_ready, TIMEOUT_SECONDS):
		_fail("Client did not receive reliable full snapshot")
		return
	var local_peer_id := get_multiplayer().get_unique_id()
	var host_peer_id := net_manager.get_host_peer_id()
	var local_player := route.get_player_for_peer(local_peer_id)
	var host_player := route.get_player_for_peer(host_peer_id)
	if local_player == null or host_player == null:
		_fail("Client route did not instantiate both avatars")
		return
	var local_start := local_player.global_position
	var host_start := host_player.global_position
	local_player.global_position = route.clamp_avatar_position(
		local_start + Vector2(AVATAR_TEST_MOVE_DISTANCE, 0.0)
	)
	local_player.velocity = Vector2.ZERO
	if not await _wait_until(
		func() -> bool:
			return host_player.global_position.distance_to(host_start) > 8.0,
		AVATAR_SYNC_TIMEOUT_SECONDS
	):
		_fail("Client did not converge on the Host avatar broadcast")
		return
	local_player.global_position = Vector2(999999.0, 999999.0)
	local_player.velocity = Vector2.ZERO
	if not await _wait_until(
		func() -> bool:
			return route.is_avatar_position_in_world(local_player.global_position),
		AVATAR_SYNC_TIMEOUT_SECONDS
	):
		_fail("Client did not receive reliable out-of-bounds correction")
		return
	var initial_state := route.export_state_snapshot()
	var initial_revision := int(initial_state.get("revision", -1))
	if not await _wait_until(
		func() -> bool:
			return (
				route.is_route_ready()
				and int(route.export_state_snapshot().get("revision", -1))
				> initial_revision
			),
		TIMEOUT_SECONDS
	):
		_fail("Client did not receive reliable move delta")
		return
	var client_state := route.export_state_snapshot()
	var neighbor := _find_first_neighbor(
		route.export_layout_snapshot(),
		int(client_state.get("current_node_id", -1))
	)
	if neighbor >= 0:
		route.call("_on_route_board_node_pressed", neighbor)
	if int(route.get("_pending_node_id")) != -1:
		_fail("Read-only client accepted a route click")


func _mount_wrapper() -> Node:
	var wrapper := WRAPPER_SCENE.instantiate() as Node
	if wrapper == null:
		_fail("Wrapper could not instantiate")
		return null
	root.add_child(wrapper)
	current_scene = wrapper
	await process_frame
	return wrapper


func _find_first_neighbor(layout: Dictionary, node_id: int) -> int:
	var edges := layout.get("edges", PackedInt32Array()) as PackedInt32Array
	for edge_offset in range(0, edges.size(), 2):
		var first := int(edges[edge_offset])
		var second := int(edges[edge_offset + 1])
		if first == node_id:
			return second
		if second == node_id:
			return first
	return -1


func _find_other_peer_id(players: Dictionary, excluded_peer_id: int) -> int:
	for peer_id_variant in players:
		var peer_id := int(peer_id_variant)
		if peer_id > 0 and peer_id != excluded_peer_id:
			return peer_id
	return 0


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
	if failures.is_empty():
		print("MP_ROGUE_ROUTE_LAN_%s_OK" % role.to_upper())
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)
