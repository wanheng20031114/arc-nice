extends Node

## Bounded lobby/roster regression fixture. No sockets, HTTP requests or saves.
@onready var host: NetManagerStore = $Host
@onready var client: NetManagerStore = $Client

var assertions := 0
var failures := 0


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	_expect(NetManagerStore.NetConstants.PROTOCOL_VERSION == 97, "Mirage RPC surface uses protocol v97")
	_expect(not host._is_protocol_version_compatible(96), "v96 wire is rejected")
	_expect(host._is_protocol_version_compatible(97), "v97 wire is accepted")
	var definition := GameModeCatalog.get_definition(9)
	_expect(definition != null and definition.wire_key == &"mirage_pvp", "stable Mirage mode")
	_expect(GameModeCatalog.is_release_selectable(9), "Mirage is available in the lobby")
	_expect(not definition.supports_singleplayer and not definition.uses_wave_campaign, "multiplayer-only policy")
	_expect(definition.multiplayer_entry_scene_path == "res://scene/pvp/mirage_pvp.tscn", "Mirage entry")
	var lobby := load("res://scene/multiplayer/multiplayer_lobby.tscn") as PackedScene
	_expect(lobby != null, "authored lobby loads")
	if lobby != null:
		var instance := lobby.instantiate()
		var panel := instance.get_node("LobbyCenter/RoomWaitPanel/MarginContainer/VBoxContainer/PvpTeamPanel")
		_expect(panel.get_node("TeamButtons/CtButton") is Button, "authored CT button")
		_expect(panel.get_node("TeamButtons/TButton") is Button, "authored T button")
		instance.free()

	host.net_role = NetManagerStore.NetRole.HOST
	host.connection_state = NetManagerStore.ConnectionState.HOSTING_LAN
	_expect(host.set_host_game_mode(NetManagerStore.GameMode.MIRAGE_PVP), "host selects PVP")
	_expect(host.local_character_id == &"weishidaier", "local character forced")
	_expect(not host.set_local_character_id(&"hoe_cat"), "local alternate character rejected")
	_add_member(1, "Host", "11111111111111111111111111111111")
	_add_member(2, "Client", "22222222222222222222222222222222")
	_expect(host.get_player_character_id(2) == &"weishidaier", "joining alternate character forced")
	_expect(host.are_all_player_characters_confirmed(), "fixed characters confirmed automatically")
	_expect(not host.are_pvp_teams_ready(), "unselected roster cannot start")
	host.host_start_game()
	_expect(host.connection_state == NetManagerStore.ConnectionState.HOSTING_LAN, "server rejects premature start")
	_expect(not host._handle_player_team_request(99, "CT"), "unknown sender rejected")
	_expect(not host._handle_player_team_request(2, "spectator"), "invalid team rejected")
	_expect(not host._handle_player_character_request(2, "hoe_cat", true), "remote alternate character rejected")
	_expect(host.set_local_team("CT"), "host confirms CT")
	_expect(host._handle_player_team_request(2, "CT"), "client confirms CT")
	_expect(not host.are_pvp_teams_ready(), "one-sided roster cannot start")
	_expect(host._handle_player_team_request(2, "T"), "client confirms T")
	_expect(host.are_pvp_teams_ready(), "two confirmed sides can start")

	client.net_role = NetManagerStore.NetRole.CLIENT
	client.connection_state = NetManagerStore.ConnectionState.CONNECTED_IN_LOBBY
	_sync_to_client()
	_expect(client.player_teams == {1: "CT", 2: "T"}, "teams travel in authoritative roster")
	_expect(client.are_pvp_teams_ready(), "client projects ready teams")
	var stale_roster := host._build_session_member_list_array()
	var stale_revision := host.get_session_membership_revision()
	_expect(host._handle_player_team_request(2, "CT"), "team change submitted")
	_sync_to_client()
	client._rpc_sync_player_list(stale_roster, 1, 9, 8, stale_revision)
	_expect(client.get_player_team(2) == "CT", "stale roster cannot revert a team")
	_expect(host._handle_player_team_request(2, "T"), "client returns T")
	_sync_to_client()

	host.host_start_game()
	_expect(host.connection_state == NetManagerStore.ConnectionState.LOADING_GAME, "ready host enters load barrier")
	_expect(not host._handle_player_team_request(2, "CT"), "teams locked during loading")
	_expect(not host.set_host_game_mode(NetManagerStore.GameMode.STANDARD), "mode locked during loading")
	_expect(host._suspend_session_member_for_grace(2, "22222222222222222222222222222222", 999999), "member suspended")
	_expect(host._remap_session_member_identity(2, 3), "reconnect identity remapped")
	_expect(host.get_player_team(3) == "T" and not host.player_teams.has(2), "reconnect retains team once")
	_expect(host._suspend_session_member_for_grace(3, "22222222222222222222222222222222", 999999), "remapped member suspended")
	_expect(host._remap_session_member_identity(3, 4, false), "identity transaction defers membership signal")
	_expect(host.get_player_team(4) == "T", "identity callback can already read committed team")
	host._emit_session_membership_changed()
	host._finalize_session_member_departures(PackedInt32Array([4]), &"disconnected")
	_expect(not host.player_teams.has(4), "final departure clears team")

	host.connection_state = NetManagerStore.ConnectionState.HOSTING_LAN
	host.connected_players.erase(2)
	host.connected_player_characters.erase(2)
	host.confirmed_character_peers.erase(2)
	_expect(host.set_host_game_mode(NetManagerStore.GameMode.STANDARD), "host switches out of PVP")
	_expect(host.player_teams.is_empty(), "mode switch clears teams")
	_expect(host.set_host_game_mode(NetManagerStore.GameMode.MIRAGE_PVP), "host switches back to PVP")
	_expect(host.get_player_team(1).is_empty(), "new PVP mode requires fresh team selection")
	_expect(host.set_local_team("CT"), "host reselects CT")
	host._reset_session_membership(true)
	_expect(host.player_teams.is_empty(), "disconnect reset clears teams")
	print("MIRAGE_LOBBY: %d assertions, %d failures" % [assertions, failures])
	get_tree().quit(0 if failures == 0 else 1)


func _add_member(peer_id: int, player_name: String, token: String) -> void:
	host.connected_players[peer_id] = player_name
	host._set_peer_character(peer_id, &"hoe_cat", false)
	_expect(host._register_active_session_member(
		peer_id, player_name, host.get_player_character_id(peer_id),
		host.is_player_character_confirmed(peer_id), token
	), "member registered")


func _sync_to_client() -> void:
	client._rpc_sync_player_list(host._build_session_member_list_array(), 1, 9, 8,
		host.get_session_membership_revision())


func _expect(condition: bool, message: String) -> void:
	assertions += 1
	if not condition:
		failures += 1
		push_error("MIRAGE_LOBBY: " + message)
