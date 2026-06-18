extends Node
class_name NetManagerStore

const NetConstants := preload("res://scene/multiplayer/net_constants.gd")

signal connection_state_changed(new_state: ConnectionState)
signal player_joined(peer_id: int, player_name: String)
signal player_left(peer_id: int)
signal player_list_changed
signal connection_failed(reason: String)

enum NetRole { NONE, HOST, CLIENT }
enum ConnMode { DIRECT, RELAY }
enum ConnectionState {
	DISCONNECTED,
	HOSTING_LAN,
	CONNECTING_LAN,
	CONNECTED_IN_LOBBY,
	LOADING_GAME,
	IN_GAME,
}

var net_role: NetRole = NetRole.NONE
var conn_mode: ConnMode = ConnMode.DIRECT
var connection_state: ConnectionState = ConnectionState.DISCONNECTED
var local_player_name: String = ""
var current_room_id: String = ""
var lobby_server_url: String = "http://127.0.0.1:8000"
var lan_port: int = NetConstants.ENET_PORT_DEFAULT
var connected_players: Dictionary = {}

var _physics_frame_count: int = 0
var _enet_peer: ENetMultiplayerPeer = null


func _physics_process(_delta: float) -> void:
	_physics_frame_count += 1


func get_physics_frame_count() -> int:
	return _physics_frame_count


func is_multiplayer_active() -> bool:
	return net_role != NetRole.NONE and connection_state != ConnectionState.DISCONNECTED


func is_host() -> bool:
	return net_role == NetRole.HOST


func is_client() -> bool:
	return net_role == NetRole.CLIENT


func host_create_lan_server(port: int = NetConstants.ENET_PORT_DEFAULT) -> Error:
	if _enet_peer != null:
		disconnect_from_game()

	lan_port = port
	_enet_peer = ENetMultiplayerPeer.new()
	var err: Error = _enet_peer.create_server(port, NetConstants.MAX_PLAYERS, 0, 0, NetConstants.CHANNEL_COUNT)
	if err != OK:
		_enet_peer = null
		connection_failed.emit("创建局域网主机失败: %s" % error_string(err))
		return err

	multiplayer.multiplayer_peer = _enet_peer
	_connect_multiplayer_signals(false)
	net_role = NetRole.HOST
	conn_mode = ConnMode.DIRECT
	connected_players.clear()
	connected_players[1] = _get_safe_local_name()
	_physics_frame_count = 0
	_set_connection_state(ConnectionState.HOSTING_LAN)
	player_joined.emit(1, connected_players[1])
	player_list_changed.emit()
	print("NetManager: LAN Host 已创建, port=%d" % port)
	return OK


func host_create_server(port: int = NetConstants.ENET_PORT_DEFAULT) -> Error:
	return host_create_lan_server(port)


func client_connect_lan(host_ip: String, port: int = NetConstants.ENET_PORT_DEFAULT) -> Error:
	if _enet_peer != null:
		disconnect_from_game()

	var trimmed_ip := host_ip.strip_edges()
	if trimmed_ip.is_empty():
		connection_failed.emit("主机 IP 不能为空")
		return ERR_INVALID_PARAMETER

	lan_port = port
	_enet_peer = ENetMultiplayerPeer.new()
	var err: Error = _enet_peer.create_client(trimmed_ip, port, NetConstants.CHANNEL_COUNT)
	if err != OK:
		_enet_peer = null
		connection_failed.emit("连接局域网主机失败: %s" % error_string(err))
		return err

	multiplayer.multiplayer_peer = _enet_peer
	_connect_multiplayer_signals(true)
	net_role = NetRole.CLIENT
	conn_mode = ConnMode.DIRECT
	connected_players.clear()
	_physics_frame_count = 0
	_set_connection_state(ConnectionState.CONNECTING_LAN)
	print("NetManager: Client 正在连接 LAN Host %s:%d" % [trimmed_ip, port])
	return OK


func client_connect_direct(host_ip: String, port: int = NetConstants.ENET_PORT_DEFAULT) -> Error:
	return client_connect_lan(host_ip, port)


func disconnect_from_game() -> void:
	_cleanup_multiplayer_signals()
	if multiplayer.has_multiplayer_peer():
		multiplayer.multiplayer_peer = null

	_enet_peer = null
	net_role = NetRole.NONE
	conn_mode = ConnMode.DIRECT
	current_room_id = ""
	connected_players.clear()
	_physics_frame_count = 0
	_set_connection_state(ConnectionState.DISCONNECTED)
	player_list_changed.emit()
	print("NetManager: 已断开连接")


func host_start_game() -> void:
	if not is_host():
		return
	_set_connection_state(ConnectionState.LOADING_GAME)
	_rpc_start_game.rpc()


func mark_in_game() -> void:
	_set_connection_state(ConnectionState.IN_GAME)


func get_player_name_by_id(peer_id: int) -> String:
	return connected_players.get(peer_id, "")


func get_local_peer_id() -> int:
	if not multiplayer.has_multiplayer_peer():
		return 0
	return multiplayer.get_unique_id()


func get_lan_ip_candidates() -> PackedStringArray:
	var result := PackedStringArray()
	for address in IP.get_local_addresses():
		if address == "127.0.0.1" or address == "::1":
			continue
		if address.contains(":"):
			continue
		if address.begins_with("169.254."):
			continue
		result.append(address)
	return result


func _connect_multiplayer_signals(include_client_signals: bool) -> void:
	_cleanup_multiplayer_signals()
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	if include_client_signals:
		multiplayer.connected_to_server.connect(_on_connected_to_server)
		multiplayer.connection_failed.connect(_on_connection_failed)
		multiplayer.server_disconnected.connect(_on_server_disconnected)


func _cleanup_multiplayer_signals() -> void:
	if multiplayer.peer_connected.is_connected(_on_peer_connected):
		multiplayer.peer_connected.disconnect(_on_peer_connected)
	if multiplayer.peer_disconnected.is_connected(_on_peer_disconnected):
		multiplayer.peer_disconnected.disconnect(_on_peer_disconnected)
	if multiplayer.connected_to_server.is_connected(_on_connected_to_server):
		multiplayer.connected_to_server.disconnect(_on_connected_to_server)
	if multiplayer.connection_failed.is_connected(_on_connection_failed):
		multiplayer.connection_failed.disconnect(_on_connection_failed)
	if multiplayer.server_disconnected.is_connected(_on_server_disconnected):
		multiplayer.server_disconnected.disconnect(_on_server_disconnected)


func _on_peer_connected(peer_id: int) -> void:
	print("NetManager: Peer 已连接, id=%d" % peer_id)


func _on_peer_disconnected(peer_id: int) -> void:
	var player_name: String = connected_players.get(peer_id, "Unknown")
	connected_players.erase(peer_id)
	player_left.emit(peer_id)
	player_list_changed.emit()
	print("NetManager: Peer 已断开, id=%d (%s)" % [peer_id, player_name])


func _on_connected_to_server() -> void:
	connected_players.clear()
	_rpc_register_player.rpc_id(1, _get_safe_local_name())
	_set_connection_state(ConnectionState.CONNECTED_IN_LOBBY)
	print("NetManager: 已连接到 LAN Host")


func _on_connection_failed() -> void:
	connection_failed.emit("连接局域网主机失败")
	disconnect_from_game()


func _on_server_disconnected() -> void:
	connection_failed.emit("主机已断开")
	disconnect_from_game()


@rpc("any_peer", "call_remote", "reliable", 0)
func _rpc_register_player(player_name: String) -> void:
	if not is_host():
		return

	var sender_id: int = multiplayer.get_remote_sender_id()
	if sender_id <= 0:
		return
	if connected_players.size() >= NetConstants.MAX_PLAYERS:
		if _enet_peer != null:
			_enet_peer.get_peer(sender_id).peer_disconnect()
		return

	connected_players[sender_id] = player_name.strip_edges()
	player_joined.emit(sender_id, connected_players[sender_id])
	player_list_changed.emit()
	_rpc_sync_player_list.rpc(_build_player_list_array())
	print("NetManager: 玩家注册, id=%d, name=%s" % [sender_id, connected_players[sender_id]])


@rpc("authority", "call_remote", "reliable", 0)
func _rpc_sync_player_list(player_list: Array) -> void:
	connected_players.clear()
	for entry_variant in player_list:
		var entry := entry_variant as Dictionary
		if entry == null:
			continue
		var peer_id: int = int(entry.get("id", 0))
		var player_name: String = str(entry.get("name", ""))
		if peer_id <= 0:
			continue
		connected_players[peer_id] = player_name
		player_joined.emit(peer_id, player_name)
	player_list_changed.emit()


@rpc("authority", "call_remote", "reliable", 0)
func _rpc_start_game() -> void:
	_set_connection_state(ConnectionState.LOADING_GAME)


func _build_player_list_array() -> Array:
	var result: Array = []
	for peer_id_variant in connected_players:
		var peer_id: int = int(peer_id_variant)
		result.append({"id": peer_id, "name": connected_players[peer_id]})
	return result


func _set_connection_state(new_state: ConnectionState) -> void:
	if connection_state == new_state:
		return
	connection_state = new_state
	connection_state_changed.emit(new_state)


func _get_safe_local_name() -> String:
	var trimmed_name := local_player_name.strip_edges()
	return trimmed_name if not trimmed_name.is_empty() else "Player"
