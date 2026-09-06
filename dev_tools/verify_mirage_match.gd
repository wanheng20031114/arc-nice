extends Node

## Run in two processes with -- --role=host|client --port=<local test port>.
## Uses production autoload registration, GameLoadCoordinator, gameplay RPCs and teardown.
var role := "host"
var port := 48961
var assertions := 0
var failures := 0
var net: NetManagerStore
var loader: Node
var runtime: MiragePvp
var _deadline := 0
var _finishing := false
var _load_requested := false
var _relay_config: Dictionary = {}
var _relay_config_path := ""


func _ready() -> void:
	# Keep this fixture alongside the production scene when the loader changes it.
	get_tree().current_scene = null
	process_mode = Node.PROCESS_MODE_ALWAYS
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--role="):
			role = argument.trim_prefix("--role=")
		elif argument.begins_with("--port="):
			port = int(argument.trim_prefix("--port="))
		elif argument.begins_with("--relay-admission="):
			_relay_config_path = argument.trim_prefix("--relay-admission=")
			_relay_config = JSON.parse_string(FileAccess.get_file_as_string(_relay_config_path))
	net = NetManagerStore.get_autoload_instance()
	loader = get_node("/root/GameLoadCoordinator")
	net.connection_state_changed.connect(_on_state)
	loader.loading_failed.connect(_on_load_failed)
	_deadline = Time.get_ticks_msec() + 30000
	_run.call_deferred()


func _process(_delta: float) -> void:
	if not _finishing and Time.get_ticks_msec() > _deadline:
		_expect(false, "full match integration completes within 30 seconds")
		_finish()


func _on_state(state: int) -> void:
	if state == NetManagerStore.ConnectionState.HOSTING_LAN and role == "host":
		net.set_local_team("CT")
		if not _relay_config.is_empty():
			var host_id_file := FileAccess.open(_relay_config_path + ".host_id", FileAccess.WRITE)
			host_id_file.store_string(str(net.get_host_peer_id()))
			host_id_file.close()
	if state == NetManagerStore.ConnectionState.CONNECTED_IN_LOBBY and role == "client":
		net.set_local_team("T")
	if state == NetManagerStore.ConnectionState.LOADING_GAME and not _load_requested:
		_load_requested = true
		get_node("/root/RunState").begin_new_run(&"weishidaier", false)
		loader.begin_multiplayer()


func _on_load_failed(message: String) -> void:
	_expect(false, "loader succeeds: " + message)
	_finish.call_deferred()


func _run() -> void:
	net.local_player_name = "PvpE2EHost" if role == "host" else "PvpE2EClient"
	if role == "host":
		net.set_host_game_mode(NetManagerStore.GameMode.MIRAGE_PVP)
		if _relay_config.is_empty():
			_expect(net.host_create_lan_server(port, 4) == OK, "host socket opens")
		else:
			_expect(net.host_create_relay_room("127.0.0.1", port, 4,
				str(_relay_config.room_id), str(_relay_config.host_ticket)) == OK, "authenticated Relay host connects")
		if not await _until(func() -> bool: return net.are_pvp_teams_ready()):
			_expect(false, "both teams register")
			_finish()
			return
		net.host_start_game()
	else:
		if _relay_config.is_empty():
			_expect(net.client_connect_lan("127.0.0.1", port) == OK, "client socket opens")
		else:
			net.set_pending_game_mode(NetManagerStore.GameMode.MIRAGE_PVP)
			if not await _until(func() -> bool: return FileAccess.file_exists(_relay_config_path + ".host_id")):
				_expect(false, "authenticated Relay host becomes available")
				_finish()
				return
			var host_id := int(FileAccess.get_file_as_string(_relay_config_path + ".host_id"))
			_expect(net.client_join_relay_room("127.0.0.1", port, host_id,
				str(_relay_config.room_id), str(_relay_config.member_ticket)) == OK, "authenticated Relay client connects")
	if not await _until(func() -> bool:
		return (get_tree().current_scene is MiragePvp and not loader.is_loading()
			and net.connection_state == NetManagerStore.ConnectionState.IN_GAME)
	):
		_expect(false, "production loader and two-player barrier finish")
		_finish()
		return
	runtime = get_tree().current_scene as MiragePvp
	_expect(runtime.name == &"MpGame", "production RPC root is MpGame")
	_expect(runtime.players.size() == 2, "both actual players spawned")
	_expect(runtime.local_player.team == ("CT" if role == "host" else "T"), "correct spawn team")
	_expect(runtime.local_player.health == 100 and runtime.local_player.current_weapon == "deagle", "100 HP and sidearm at spawn")
	if role == "host":
		await _check_host_actions()
	else:
		await _check_client_actions()
	_finish()


func _check_client_actions() -> void:
	if not await _until(func() -> bool: return runtime.phase == "buy"):
		_expect(false, "client receives initial round snapshot")
		return
	runtime.request_action("buy_ak")
	_expect(await _until(func() -> bool: return runtime.local_player.loadout.has("ak")), "purchase RPC synchronizes AK")
	_expect(runtime.local_player.money == 1300, "host charges AK price exactly once")
	_expect(runtime.local_player.ammo == 30, "AK starts with 30 bullets")
	await get_tree().create_timer(0.18).timeout
	runtime.request_action("drop")
	_expect(await _until(func() -> bool:
		return not runtime.local_player.loadout.has("ak") and runtime.pickups.size() == 1
	), "drop RPC creates one shared pickup")
	_expect(runtime.local_player.current_weapon == "deagle", "sidearm equips after AK drop")
	await get_tree().create_timer(0.18).timeout
	runtime.request_action("pickup")
	_expect(await _until(func() -> bool:
		return runtime.local_player.loadout.has("ak") and runtime.pickups.is_empty()
	), "pickup RPC restores AK and removes world pickup")
	_expect(runtime.local_player.money == 1300, "pickup does not repurchase weapon")
	await get_tree().create_timer(0.2).timeout
	net.disconnect_from_game()


func _check_host_actions() -> void:
	var client_id := 0
	for id: int in runtime.players:
		if id != net.get_local_peer_id():
			client_id = id
	var player: PvpPlayer = runtime.players[client_id]
	_expect(await _until(func() -> bool: return player.loadout.has("ak")), "host applies client AK purchase")
	_expect(player.money == 1300, "host owns client balance")
	_expect(await _until(func() -> bool: return runtime.pickups.size() == 1), "host sees one dropped gun")
	_expect(await _until(func() -> bool:
		return player.loadout.has("ak") and runtime.pickups.is_empty()
	), "host applies pickup without duplication")
	_expect(await _until(func() -> bool: return not net.connected_players.has(client_id)), "client departure reaches host")
	_expect(not net.has_session_member(client_id), "PVP departure has no unsupported reconnect grace")
	_expect(runtime.phase == "match_end" and runtime.winner_team == "CT", "empty opposing team concludes match")


func _until(predicate: Callable) -> bool:
	var deadline := Time.get_ticks_msec() + 12000
	while not _finishing and Time.get_ticks_msec() < deadline:
		if predicate.call():
			return true
		await get_tree().process_frame
	return false


func _finish() -> void:
	if _finishing:
		return
	_finishing = true
	net.disconnect_from_game()
	print("MIRAGE_MATCH_%s: %d assertions, %d failures" % [role.to_upper(), assertions, failures])
	get_tree().quit(0 if failures == 0 else 1)


func _expect(condition: bool, message: String) -> void:
	assertions += 1
	if not condition:
		failures += 1
		push_error("MIRAGE_MATCH_%s: %s" % [role.to_upper(), message])
