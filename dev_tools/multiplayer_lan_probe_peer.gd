extends SceneTree

const MP_GAME_SCENE := preload("res://scene/multiplayer/mp_game.tscn")

const STATE_LOADING_GAME := 4
const STATE_IN_GAME := 5
const DEFAULT_TIMEOUT_SECONDS := 12.0
const DEFAULT_RUN_SECONDS := 3.0

var failures: Array[String] = []


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
	var host_ip := str(options.get("host", "127.0.0.1"))
	var player_name := str(options.get("name", "Probe%s" % role.capitalize()))

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
				port,
				expected_players,
				timeout_seconds,
				run_seconds,
				linger_seconds
			)
		"client":
			await _run_client(
				net_manager,
				host_ip,
				port,
				expected_players,
				timeout_seconds,
				run_seconds
			)
		_:
			_fail("Unsupported probe role: %s" % role)

	if net_manager.has_method("disconnect_from_game"):
		net_manager.disconnect_from_game()
	await _wait_frames(3)
	_finish()


func _run_host(
	net_manager: Node,
	port: int,
	expected_players: int,
	timeout_seconds: float,
	run_seconds: float,
	linger_seconds: float
) -> void:
	var err: Error = net_manager.host_create_lan_server(port)
	if err != OK:
		_fail("Host failed to create LAN server: %s" % error_string(err))
		return
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
	host_ip: String,
	port: int,
	expected_players: int,
	timeout_seconds: float,
	run_seconds: float
) -> void:
	var err: Error = net_manager.client_connect_lan(host_ip, port)
	if err != OK:
		_fail("Client failed to connect to LAN host: %s" % error_string(err))
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
	await _run_mp_game_probe(net_manager, expected_players, false, run_seconds)


func _run_mp_game_probe(
	net_manager: Node,
	expected_players: int,
	is_host_probe: bool,
	run_seconds: float,
	keepalive_seconds: float = 0.0
) -> void:
	var mp_game := MP_GAME_SCENE.instantiate()
	if mp_game == null:
		_fail("MpGame scene did not instantiate.")
		return
	root.add_child(mp_game)
	if not await _wait_for_connection_state(net_manager, STATE_IN_GAME, 3.0):
		_fail("MpGame did not mark NetManager in-game.")
		mp_game.queue_free()
		return
	var game := mp_game.get("game") as Game
	if game == null or not is_instance_valid(game):
		_fail("MpGame did not create Game.")
		mp_game.queue_free()
		return
	if game.peer_players.size() != expected_players:
		_fail(
			"Game expected %d peer players, saw %d."
			% [expected_players, game.peer_players.size()]
		)
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
	if keepalive_seconds > 0.0:
		await _wait_seconds(keepalive_seconds)
	mp_game.queue_free()
	await _wait_frames(2)


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


func _wait_seconds(seconds: float) -> void:
	var end_time := _now_seconds() + maxf(seconds, 0.0)
	while _now_seconds() <= end_time:
		await process_frame


func _wait_frames(frame_count: int) -> void:
	for _frame_index in range(frame_count):
		await process_frame


func _get_connected_player_count(net_manager: Node) -> int:
	var connected_players := net_manager.get("connected_players") as Dictionary
	return connected_players.size()


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
