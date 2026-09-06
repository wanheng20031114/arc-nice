extends Node

## Two independent SceneMultiplayer branches exercise real local ENet RPCs.
@onready var host: NetManagerStore = $HostContext/NetManager
@onready var client: NetManagerStore = $ClientContext/NetManager

var assertions := 0
var failures := 0


func _ready() -> void:
	get_tree().set_multiplayer(SceneMultiplayer.new(), $HostContext.get_path())
	get_tree().set_multiplayer(SceneMultiplayer.new(), $ClientContext.get_path())
	_run.call_deferred()


func _run() -> void:
	host.local_player_name = "MirageHost"
	client.local_player_name = "MirageClient"
	host.set_host_game_mode(NetManagerStore.GameMode.MIRAGE_PVP)
	var port := 34000 + (OS.get_process_id() % 20000)
	_expect(host.host_create_lan_server(port, 4) == OK, "real ENet host created")
	_expect(client.client_connect_lan("127.0.0.1", port) == OK, "real ENet client connects")
	if not await _until(func() -> bool:
		return client.connection_state == NetManagerStore.ConnectionState.CONNECTED_IN_LOBBY
	):
		_expect(false, "authenticated registration completed before timeout")
		_finish()
		return
	_expect(host.connected_players.size() == 2, "host has two authenticated players")
	_expect(client.get_current_game_mode() == NetManagerStore.GameMode.MIRAGE_PVP, "LAN client adopts host mode")
	var client_id := client.get_local_peer_id()
	_expect(host.get_player_character_id(client_id) == &"weishidaier", "host forces client character")
	_expect(host.set_local_team("CT"), "host selects CT")
	_expect(client.set_local_team("T"), "client sends T choice")
	_expect(await _until(func() -> bool:
		return host.are_pvp_teams_ready() and client.are_pvp_teams_ready()
	), "both sides receive committed teams")
	_expect(host.player_teams == client.player_teams, "team projections agree over ENet")
	client._rpc_set_player_team.rpc_id(1, "SPECTATOR")
	client._rpc_set_player_character.rpc_id(1, "hoe_cat", true)
	await get_tree().create_timer(0.1).timeout
	_expect(host.get_player_team(client_id) == "T", "invalid team RPC rejected")
	_expect(host.get_player_character_id(client_id) == &"weishidaier", "alternate character RPC rejected")

	# Submit a final swap immediately before start to exercise ordered CH8 delivery.
	host._handle_player_team_request(client_id, "CT")
	host.set_local_team("T")
	host.host_start_game()
	host.host_broadcast_start_game()
	_expect(await _until(func() -> bool:
		return client.connection_state == NetManagerStore.ConnectionState.LOADING_GAME
	), "PVP start reaches client")
	_expect(client.get_player_team(client_id) == "CT", "start sees last committed client team")
	_expect(client.get_player_team(1) == "T", "start sees last committed host team")
	_expect(client.loading_session_id == host.loading_session_id, "loading incarnation agrees")
	_expect(not client.set_local_team("T"), "client cannot change team after start")
	_finish()


func _until(predicate: Callable) -> bool:
	var deadline := Time.get_ticks_msec() + 5000
	while Time.get_ticks_msec() < deadline:
		if predicate.call():
			return true
		await get_tree().process_frame
	return false


func _finish() -> void:
	client.disconnect_from_game()
	host.disconnect_from_game()
	_expect(host.player_teams.is_empty() and client.player_teams.is_empty(), "both disconnect paths clear teams")
	print("MIRAGE_LAN: %d assertions, %d failures" % [assertions, failures])
	get_tree().quit(0 if failures == 0 else 1)


func _expect(condition: bool, message: String) -> void:
	assertions += 1
	if not condition:
		failures += 1
		push_error("MIRAGE_LAN: " + message)
