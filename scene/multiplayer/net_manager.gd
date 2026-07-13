extends Node
class_name NetManagerStore

const NetConstants := preload("res://scene/multiplayer/net_constants.gd")

signal connection_state_changed(new_state: ConnectionState)
signal player_joined(peer_id: int, player_name: String)
signal player_left(peer_id: int)
signal player_list_changed
signal player_character_changed(peer_id: int, character_id: StringName, confirmed: bool)
signal connection_failed(reason: String)
signal game_mode_changed(new_game_mode: GameMode)
signal game_load_progress_changed(ready_count: int, total_count: int)

const DEFAULT_CHARACTER_ID := &"weishidaier"

enum NetRole { NONE, HOST, CLIENT }
enum ConnMode { DIRECT, RELAY }
enum GameMode { STANDARD, TOWER_DEFENSE }
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
var local_character_id: StringName = DEFAULT_CHARACTER_ID
var local_character_confirmed: bool = true
var lan_port: int = NetConstants.ENET_PORT_DEFAULT
var relay_ip: String = ""
var relay_port: int = 0
var connected_players: Dictionary = {}
var connected_player_characters: Dictionary = {}
var confirmed_character_peers: Dictionary = {}
var host_peer_id: int = 1
var host_game_ready: bool = false
var public_room_id: String = ""
var public_host_token: String = ""
var public_is_host: bool = false
var current_game_mode: GameMode = GameMode.STANDARD
var loading_session_id: int = 0

var _physics_frame_count: int = 0
var _enet_peer: ENetMultiplayerPeer = null
var _disconnect_in_progress: bool = false
var _relay_register_pending: bool = false
var _connect_started_msec: int = 0
var _connect_timeout_ms: int = 0
var _connect_target_description: String = ""
var _connected_signal_handled: bool = false
var _expected_game_load_peers: Dictionary = {}
var _ready_game_load_peers: Dictionary = {}
var _reported_game_load_ready_count: int = 0
var _reported_game_load_total_count: int = 0


func _physics_process(_delta: float) -> void:
	_physics_frame_count += 1
	_poll_pending_connection()
	if _relay_register_pending:
		_try_send_relay_registration()


func get_physics_frame_count() -> int:
	return _physics_frame_count


func set_public_room_context(room_id: String, host_token: String, is_public_host: bool) -> void:
	public_room_id = room_id.strip_edges()
	public_host_token = host_token.strip_edges()
	public_is_host = is_public_host


func clear_public_room_context() -> void:
	public_room_id = ""
	public_host_token = ""
	public_is_host = false


func set_host_game_mode(game_mode: GameMode) -> bool:
	if not _is_valid_game_mode(int(game_mode)):
		return false
	if is_client() or connection_state >= ConnectionState.LOADING_GAME:
		return false
	_set_current_game_mode(game_mode)
	if is_host():
		_broadcast_player_list_to_clients()
	return true


func set_pending_game_mode(game_mode: GameMode) -> bool:
	if not _is_valid_game_mode(int(game_mode)):
		return false
	if is_multiplayer_active() or net_role != NetRole.NONE:
		return false
	_set_current_game_mode(game_mode)
	return true


func get_current_game_mode() -> GameMode:
	return current_game_mode


static func game_mode_to_key(game_mode: GameMode) -> String:
	return "tower_defense" if game_mode == GameMode.TOWER_DEFENSE else "standard"


static func game_mode_from_key(game_mode_key: String) -> GameMode:
	return (
		GameMode.TOWER_DEFENSE
		if game_mode_key.strip_edges().to_lower() == "tower_defense"
		else GameMode.STANDARD
	)


static func get_game_mode_display_name(game_mode: GameMode) -> String:
	return "塔防模式" if game_mode == GameMode.TOWER_DEFENSE else "普通模式"


func is_multiplayer_active() -> bool:
	return (
		not _disconnect_in_progress
		and net_role != NetRole.NONE
		and connection_state != ConnectionState.DISCONNECTED
	)


func is_host() -> bool:
	return not _disconnect_in_progress and net_role == NetRole.HOST


func is_client() -> bool:
	return not _disconnect_in_progress and net_role == NetRole.CLIENT


func host_create_lan_server(port: int = NetConstants.ENET_PORT_DEFAULT) -> Error:
	var configured_game_mode := current_game_mode
	if _enet_peer != null:
		disconnect_from_game()
	_set_current_game_mode(configured_game_mode)

	lan_port = port
	_enet_peer = ENetMultiplayerPeer.new()
	var err: Error = _enet_peer.create_server(
		port,
		NetConstants.MAX_PLAYERS,
		NetConstants.CHANNEL_COUNT
	)
	if err != OK:
		_enet_peer = null
		connection_failed.emit("创建局域网主机失败: %s" % error_string(err))
		return err

	_connect_multiplayer_signals(false)
	multiplayer.multiplayer_peer = _enet_peer
	net_role = NetRole.HOST
	conn_mode = ConnMode.DIRECT
	connected_players.clear()
	connected_player_characters.clear()
	confirmed_character_peers.clear()
	host_peer_id = get_local_peer_id()
	if host_peer_id <= 0:
		host_peer_id = 1
	set_multiplayer_authority(host_peer_id)
	connected_players[host_peer_id] = _sanitize_player_name(local_player_name)
	connected_player_characters[host_peer_id] = _sanitize_character_id(local_character_id)
	confirmed_character_peers[host_peer_id] = local_character_confirmed
	_physics_frame_count = 0
	_set_connection_state(ConnectionState.HOSTING_LAN)
	player_joined.emit(host_peer_id, connected_players[host_peer_id])
	player_list_changed.emit()
	_debug_log("NetManager: LAN Host 已创建, port=%d" % port)
	return OK


func host_create_server(port: int = NetConstants.ENET_PORT_DEFAULT) -> Error:
	return host_create_lan_server(port)


func client_connect_lan(host_ip: String, port: int = NetConstants.ENET_PORT_DEFAULT) -> Error:
	var pending_game_mode := current_game_mode
	if _enet_peer != null:
		disconnect_from_game()
	_set_current_game_mode(pending_game_mode)

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

	net_role = NetRole.CLIENT
	conn_mode = ConnMode.DIRECT
	connected_players.clear()
	connected_player_characters.clear()
	confirmed_character_peers.clear()
	host_peer_id = 1
	set_multiplayer_authority(host_peer_id)
	_physics_frame_count = 0
	_begin_connection_attempt(
		NetConstants.DIRECT_CONNECT_TIMEOUT_MS,
		"局域网主机 %s:%d" % [trimmed_ip, port]
	)
	_set_connection_state(ConnectionState.CONNECTING_LAN)
	_connect_multiplayer_signals(true)
	multiplayer.multiplayer_peer = _enet_peer
	_debug_log("NetManager: Client 正在连接 LAN Host %s:%d" % [trimmed_ip, port])
	return OK


func client_connect_direct(host_ip: String, port: int = NetConstants.ENET_PORT_DEFAULT) -> Error:
	return client_connect_lan(host_ip, port)


func host_create_relay_room(target_relay_ip: String, target_relay_port: int) -> Error:
	var configured_game_mode := current_game_mode
	if _enet_peer != null:
		disconnect_from_game()
	_set_current_game_mode(configured_game_mode)

	var trimmed_ip := target_relay_ip.strip_edges()
	if trimmed_ip.is_empty():
		connection_failed.emit("Relay 地址不能为空")
		return ERR_INVALID_PARAMETER
	if target_relay_port <= 0:
		connection_failed.emit("Relay 端口无效")
		return ERR_INVALID_PARAMETER

	relay_ip = trimmed_ip
	relay_port = target_relay_port
	_enet_peer = ENetMultiplayerPeer.new()
	var err: Error = _enet_peer.create_client(trimmed_ip, target_relay_port, NetConstants.CHANNEL_COUNT)
	if err != OK:
		_enet_peer = null
		connection_failed.emit("连接公网 Relay 失败: %s" % error_string(err))
		return err

	net_role = NetRole.HOST
	conn_mode = ConnMode.RELAY
	connected_players.clear()
	connected_player_characters.clear()
	confirmed_character_peers.clear()
	host_peer_id = 0
	set_multiplayer_authority(1)
	_relay_register_pending = false
	_physics_frame_count = 0
	_begin_connection_attempt(
		NetConstants.RELAY_CONNECT_TIMEOUT_MS,
		"公网 Relay %s:%d" % [trimmed_ip, target_relay_port]
	)
	_set_connection_state(ConnectionState.CONNECTING_LAN)
	_connect_multiplayer_signals(true)
	multiplayer.multiplayer_peer = _enet_peer
	_debug_log("NetManager: Host 正在连接 Relay %s:%d" % [trimmed_ip, target_relay_port])
	return OK


func client_join_relay_room(
	target_relay_ip: String,
	target_relay_port: int,
	target_host_peer_id: int
) -> Error:
	var pending_game_mode := current_game_mode
	if _enet_peer != null:
		disconnect_from_game()
	_set_current_game_mode(pending_game_mode)

	var trimmed_ip := target_relay_ip.strip_edges()
	if trimmed_ip.is_empty():
		connection_failed.emit("Relay 地址不能为空")
		return ERR_INVALID_PARAMETER
	if target_relay_port <= 0 or target_host_peer_id <= 0:
		connection_failed.emit("Relay 房间信息无效")
		return ERR_INVALID_PARAMETER

	relay_ip = trimmed_ip
	relay_port = target_relay_port
	_enet_peer = ENetMultiplayerPeer.new()
	var err: Error = _enet_peer.create_client(trimmed_ip, target_relay_port, NetConstants.CHANNEL_COUNT)
	if err != OK:
		_enet_peer = null
		connection_failed.emit("连接公网 Relay 失败: %s" % error_string(err))
		return err

	net_role = NetRole.CLIENT
	conn_mode = ConnMode.RELAY
	connected_players.clear()
	connected_player_characters.clear()
	confirmed_character_peers.clear()
	host_peer_id = target_host_peer_id
	set_multiplayer_authority(host_peer_id)
	_relay_register_pending = false
	_physics_frame_count = 0
	_begin_connection_attempt(
		NetConstants.RELAY_CONNECT_TIMEOUT_MS,
		"公网 Relay %s:%d" % [trimmed_ip, target_relay_port]
	)
	_set_connection_state(ConnectionState.CONNECTING_LAN)
	_connect_multiplayer_signals(true)
	multiplayer.multiplayer_peer = _enet_peer
	_debug_log("NetManager: Client 正在连接 Relay %s:%d host=%d" % [trimmed_ip, target_relay_port, target_host_peer_id])
	return OK


func disconnect_from_game() -> void:
	_disconnect_in_progress = true
	_cleanup_multiplayer_signals()
	if multiplayer.has_multiplayer_peer():
		multiplayer.multiplayer_peer = null

	_enet_peer = null
	net_role = NetRole.NONE
	conn_mode = ConnMode.DIRECT
	relay_ip = ""
	relay_port = 0
	connected_players.clear()
	connected_player_characters.clear()
	confirmed_character_peers.clear()
	host_peer_id = 1
	set_multiplayer_authority(host_peer_id)
	host_game_ready = false
	loading_session_id = 0
	_expected_game_load_peers.clear()
	_ready_game_load_peers.clear()
	_reported_game_load_ready_count = 0
	_reported_game_load_total_count = 0
	clear_public_room_context()
	_set_current_game_mode(GameMode.STANDARD)
	_relay_register_pending = false
	_clear_connection_attempt()
	_physics_frame_count = 0
	_set_connection_state(ConnectionState.DISCONNECTED)
	player_list_changed.emit()
	_debug_log("NetManager: 已断开连接")
	_disconnect_in_progress = false


func host_start_game() -> void:
	if not is_host():
		return
	if connection_state >= ConnectionState.LOADING_GAME:
		return
	if not are_all_player_characters_confirmed():
		connection_failed.emit("仍有玩家尚未确认角色")
		return
	host_game_ready = false
	loading_session_id += 1
	_expected_game_load_peers.clear()
	_ready_game_load_peers.clear()
	for peer_id_variant in connected_players:
		_expected_game_load_peers[int(peer_id_variant)] = true
	_set_connection_state(ConnectionState.LOADING_GAME)
	_emit_game_load_progress()
	_send_start_game_to_clients()


func host_broadcast_start_game() -> void:
	if not is_host():
		return
	if connection_state != ConnectionState.LOADING_GAME:
		return
	_send_start_game_to_clients()


func mark_in_game() -> void:
	if not is_host():
		return
	if connection_state != ConnectionState.LOADING_GAME:
		return
	if not _are_all_game_load_peers_ready():
		return
	host_game_ready = true
	_set_connection_state(ConnectionState.IN_GAME)
	_send_host_game_ready_to_clients()


func report_game_loaded() -> void:
	if connection_state != ConnectionState.LOADING_GAME or loading_session_id <= 0:
		return
	var local_peer_id := get_local_peer_id()
	if local_peer_id <= 0 and is_host():
		local_peer_id = get_host_peer_id()
	if local_peer_id <= 0:
		return
	if is_host():
		_mark_peer_game_loaded(local_peer_id, loading_session_id)
	elif is_client():
		_rpc_report_game_loaded.rpc_id(get_host_peer_id(), loading_session_id)


func get_game_load_progress() -> Dictionary:
	return {
		"ready": _reported_game_load_ready_count,
		"total": _reported_game_load_total_count,
		"session_id": loading_session_id,
	}


func set_local_character_id(character_id: StringName, confirmed: bool = true) -> bool:
	if is_multiplayer_active() and connection_state >= ConnectionState.LOADING_GAME:
		return false
	var resolved_character_id := _sanitize_character_id(character_id)
	if resolved_character_id != character_id:
		return false
	local_character_id = resolved_character_id
	local_character_confirmed = confirmed
	var local_peer_id := get_local_peer_id()
	if local_peer_id <= 0 or not is_multiplayer_active():
		return true
	if is_host():
		_set_peer_character(local_peer_id, resolved_character_id, confirmed)
		_broadcast_player_list_to_clients()
	elif connection_state >= ConnectionState.CONNECTED_IN_LOBBY:
		_rpc_set_player_character.rpc_id(
			get_host_peer_id(),
			String(resolved_character_id),
			confirmed
		)
	return true


func confirm_local_character() -> void:
	set_local_character_id(local_character_id, true)


func get_player_character_id(peer_id: int) -> StringName:
	return StringName(connected_player_characters.get(peer_id, DEFAULT_CHARACTER_ID))


func get_player_character_map() -> Dictionary:
	return connected_player_characters.duplicate()


func is_player_character_confirmed(peer_id: int) -> bool:
	return bool(confirmed_character_peers.get(peer_id, false))


func are_all_player_characters_confirmed() -> bool:
	if connected_players.is_empty():
		return false
	for peer_id_variant in connected_players:
		var peer_id := int(peer_id_variant)
		if not connected_player_characters.has(peer_id):
			return false
		if not PlayerCharacterRegistry.is_valid_character_id(get_player_character_id(peer_id)):
			return false
		if not is_player_character_confirmed(peer_id):
			return false
	return true


func get_player_name_by_id(peer_id: int) -> String:
	return connected_players.get(peer_id, "")


func get_local_peer_id() -> int:
	if not multiplayer.has_multiplayer_peer():
		return 0
	return multiplayer.get_unique_id()


func get_host_peer_id() -> int:
	if is_host():
		var local_id := get_local_peer_id()
		if local_id > 0:
			return local_id
	return host_peer_id if host_peer_id > 0 else 1


func is_peer_send_ready(peer_id: int) -> bool:
	if peer_id <= 0 or _disconnect_in_progress:
		return false
	if _enet_peer == null or not multiplayer.has_multiplayer_peer():
		return false
	if conn_mode == ConnMode.RELAY:
		return connected_players.has(peer_id) or multiplayer.get_peers().has(peer_id)
	var packet_peer := _enet_peer.get_peer(peer_id)
	if packet_peer == null:
		return false
	return packet_peer.get_state() == ENetPacketPeer.STATE_CONNECTED


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
	_debug_log("NetManager: Peer 已连接, id=%d" % peer_id)
	if is_host() and not _is_registration_open() and peer_id != get_host_peer_id():
		call_deferred("_reject_late_connected_peer", peer_id)
		return
	if _relay_register_pending:
		_try_send_relay_registration()


func _reject_late_connected_peer(peer_id: int) -> void:
	if not is_host() or _is_registration_open() or peer_id <= 0:
		return
	if connected_players.has(peer_id):
		return
	if is_peer_send_ready(peer_id):
		_rpc_join_rejected.rpc_id(
			peer_id,
			"房间已经开始加载，暂不支持中途加入或断线重连。"
		)
	call_deferred("_disconnect_incompatible_peer", peer_id)


func _on_peer_disconnected(peer_id: int) -> void:
	var player_name: String = connected_players.get(peer_id, "Unknown")
	connected_players.erase(peer_id)
	connected_player_characters.erase(peer_id)
	confirmed_character_peers.erase(peer_id)
	if is_host() and connection_state == ConnectionState.LOADING_GAME:
		_expected_game_load_peers.erase(peer_id)
		_ready_game_load_peers.erase(peer_id)
		_emit_game_load_progress()
		_broadcast_game_load_progress()
		_try_finish_game_loading()
	player_left.emit(peer_id)
	player_list_changed.emit()
	if conn_mode == ConnMode.RELAY and net_role == NetRole.CLIENT and peer_id == get_host_peer_id():
		connection_failed.emit("主机已断开")
		disconnect_from_game()
		return
	if is_host() and connection_state != ConnectionState.IN_GAME:
		call_deferred("_broadcast_player_list_to_clients")
	_debug_log("NetManager: Peer 已断开, id=%d (%s)" % [peer_id, player_name])


func _on_connected_to_server() -> void:
	_handle_connected_to_server()


func _handle_connected_to_server() -> void:
	if _connected_signal_handled:
		return
	_connected_signal_handled = true
	_clear_connection_attempt()

	if conn_mode == ConnMode.RELAY and net_role == NetRole.HOST:
		host_peer_id = get_local_peer_id()
		if host_peer_id <= 0:
			connection_failed.emit("Relay 未分配有效 Host Peer ID")
			disconnect_from_game()
			return
		set_multiplayer_authority(host_peer_id)
		connected_players.clear()
		connected_player_characters.clear()
		confirmed_character_peers.clear()
		connected_players[host_peer_id] = _sanitize_player_name(local_player_name)
		connected_player_characters[host_peer_id] = _sanitize_character_id(local_character_id)
		confirmed_character_peers[host_peer_id] = local_character_confirmed
		player_joined.emit(host_peer_id, connected_players[host_peer_id])
		player_list_changed.emit()
		_set_connection_state(ConnectionState.HOSTING_LAN)
		_debug_log("NetManager: Host 已连接到 Relay, host_peer_id=%d" % host_peer_id)
		return

	connected_players.clear()
	if conn_mode == ConnMode.RELAY:
		_relay_register_pending = true
		_try_send_relay_registration()
		return
	_rpc_register_player.rpc_id(
		get_host_peer_id(),
		_get_safe_local_name(),
		String(local_character_id),
		local_character_confirmed,
		NetConstants.PROTOCOL_VERSION
	)
	_set_connection_state(ConnectionState.CONNECTED_IN_LOBBY)
	_debug_log("NetManager: 已连接到 LAN Host")


func _on_connection_failed() -> void:
	var reason := "连接局域网主机失败"
	if conn_mode == ConnMode.RELAY:
		reason = "连接公网 Relay 失败"
	_fail_pending_connection(reason)


func _on_server_disconnected() -> void:
	var reason := "主机已断开"
	if conn_mode == ConnMode.RELAY:
		reason = "Relay 已断开"
	connection_failed.emit(reason)
	disconnect_from_game()


func _begin_connection_attempt(timeout_ms: int, target_description: String) -> void:
	_connect_started_msec = Time.get_ticks_msec()
	_connect_timeout_ms = timeout_ms
	_connect_target_description = target_description
	_connected_signal_handled = false


func _clear_connection_attempt() -> void:
	_connect_started_msec = 0
	_connect_timeout_ms = 0
	_connect_target_description = ""


func _poll_pending_connection() -> void:
	if connection_state != ConnectionState.CONNECTING_LAN:
		return
	if _enet_peer == null:
		return

	var status: int = int(_enet_peer.get_connection_status())
	if status == int(MultiplayerPeer.CONNECTION_CONNECTED):
		_handle_connected_to_server()
		return

	if _connect_timeout_ms <= 0:
		return

	var elapsed_msec := Time.get_ticks_msec() - _connect_started_msec
	if elapsed_msec < _connect_timeout_ms:
		return

	var target := _connect_target_description
	if target.is_empty():
		target = "目标服务器"
	_fail_pending_connection("连接%s超时，请检查服务器 UDP 端口和防火墙" % target)


func _fail_pending_connection(reason: String) -> void:
	connection_failed.emit(reason)
	disconnect_from_game()


func _try_send_relay_registration() -> void:
	if conn_mode != ConnMode.RELAY or net_role != NetRole.CLIENT:
		_relay_register_pending = false
		return
	if not multiplayer.has_multiplayer_peer():
		return
	var target_host_id := get_host_peer_id()
	if target_host_id <= 0 or not multiplayer.get_peers().has(target_host_id):
		return
	_relay_register_pending = false
	_rpc_register_player.rpc_id(
		target_host_id,
		_get_safe_local_name(),
		String(local_character_id),
		local_character_confirmed,
		NetConstants.PROTOCOL_VERSION
	)
	_set_connection_state(ConnectionState.CONNECTED_IN_LOBBY)
	_debug_log("NetManager: 已连接到 Relay Host %d" % target_host_id)


@rpc("any_peer", "call_remote", "reliable", 0)
func _rpc_register_player(
	player_name: String,
	character_id: String = "weishidaier",
	character_confirmed: bool = true,
	protocol_version: int = -1
) -> void:
	if not is_host():
		return

	var sender_id: int = multiplayer.get_remote_sender_id()
	if sender_id <= 0:
		return
	if not _is_protocol_version_compatible(protocol_version):
		push_warning(
			"NetManager: 拒绝 peer %d 的协议版本 %d，当前版本为 %d。"
			% [sender_id, protocol_version, NetConstants.PROTOCOL_VERSION]
		)
		_rpc_protocol_rejected.rpc_id(sender_id, NetConstants.PROTOCOL_VERSION)
		call_deferred("_disconnect_incompatible_peer", sender_id)
		return
	# A delayed or replayed reliable registration from a member of the frozen roster
	# is idempotent. It must not eject an already accepted player from the running game.
	if connected_players.has(sender_id) and not _is_registration_open():
		return
	if not _is_registration_open():
		_rpc_join_rejected.rpc_id(
			sender_id,
			"房间已经开始加载，暂不支持中途加入或断线重连。"
		)
		call_deferred("_disconnect_incompatible_peer", sender_id)
		return
	if connected_players.size() >= NetConstants.MAX_PLAYERS:
		if _enet_peer != null:
			_enet_peer.get_peer(sender_id).peer_disconnect()
		return

	connected_players[sender_id] = _sanitize_player_name(player_name)
	var requested_character_id := StringName(character_id)
	var character_is_valid := PlayerCharacterRegistry.is_valid_character_id(requested_character_id)
	_set_peer_character(
		sender_id,
		requested_character_id if character_is_valid else DEFAULT_CHARACTER_ID,
		character_confirmed and character_is_valid
	)
	player_joined.emit(sender_id, connected_players[sender_id])
	player_list_changed.emit()
	_broadcast_player_list_to_clients()
	_debug_log("NetManager: 玩家注册, id=%d, name=%s" % [sender_id, connected_players[sender_id]])


func _is_protocol_version_compatible(protocol_version: int) -> bool:
	return protocol_version == NetConstants.PROTOCOL_VERSION


func _is_registration_open() -> bool:
	return connection_state < ConnectionState.LOADING_GAME


func _disconnect_incompatible_peer(peer_id: int) -> void:
	if _enet_peer == null or peer_id <= 0:
		return
	await get_tree().create_timer(0.1).timeout
	if _enet_peer == null:
		return
	var packet_peer := _enet_peer.get_peer(peer_id)
	if packet_peer != null:
		packet_peer.peer_disconnect()


@rpc("authority", "call_remote", "reliable", 0)
func _rpc_protocol_rejected(expected_protocol_version: int) -> void:
	if is_host():
		return
	connection_failed.emit(
		"联机协议版本不匹配：需要版本 %d，请使用相同构建。"
		% expected_protocol_version
	)
	disconnect_from_game()


@rpc("authority", "call_remote", "reliable", 0)
func _rpc_join_rejected(reason: String) -> void:
	if is_host():
		return
	var resolved_reason := reason.strip_edges()
	if resolved_reason.is_empty():
		resolved_reason = "房间已经开始，无法加入。"
	connection_failed.emit(resolved_reason)
	disconnect_from_game()


@rpc("any_peer", "call_remote", "reliable", 0)
func _rpc_set_player_character(character_id: String, confirmed: bool) -> void:
	if not is_host():
		return
	if connection_state >= ConnectionState.LOADING_GAME:
		return
	var sender_id := multiplayer.get_remote_sender_id()
	if sender_id <= 0 or not connected_players.has(sender_id):
		return
	var requested_id := StringName(character_id)
	if not PlayerCharacterRegistry.is_valid_character_id(requested_id):
		return
	_set_peer_character(sender_id, requested_id, confirmed)
	_broadcast_player_list_to_clients()


@rpc("authority", "call_remote", "reliable", 0)
func _rpc_sync_player_list(
	player_list: Array,
	new_host_peer_id: int = 0,
	game_mode: int = 0
) -> void:
	if is_host():
		return
	var sender_id := multiplayer.get_remote_sender_id()
	var resolved_host_id := new_host_peer_id
	if resolved_host_id <= 0:
		resolved_host_id = sender_id
	if resolved_host_id <= 0:
		resolved_host_id = host_peer_id
	if sender_id > 0 and resolved_host_id > 0 and sender_id != resolved_host_id:
		return
	var previous_players := connected_players.duplicate()
	var previous_characters := connected_player_characters.duplicate()
	var previous_confirmations := confirmed_character_peers.duplicate()
	var synced_players: Dictionary = {}
	var synced_characters: Dictionary = {}
	var synced_confirmations: Dictionary = {}
	for entry_variant in player_list:
		var entry := entry_variant as Dictionary
		if entry == null:
			continue
		var peer_id: int = int(entry.get("id", 0))
		var player_name: String = _sanitize_player_name(str(entry.get("name", "")))
		if peer_id <= 0:
			continue
		synced_players[peer_id] = player_name
		synced_characters[peer_id] = _sanitize_character_id(
			StringName(entry.get("character_id", DEFAULT_CHARACTER_ID))
		)
		synced_confirmations[peer_id] = bool(entry.get("character_confirmed", false))
	if not synced_players.has(resolved_host_id):
		return
	if not _is_valid_game_mode(game_mode):
		return
	host_peer_id = resolved_host_id
	set_multiplayer_authority(host_peer_id)
	_set_current_game_mode(game_mode as GameMode)
	connected_players = synced_players
	connected_player_characters = synced_characters
	confirmed_character_peers = synced_confirmations
	var local_peer_id := get_local_peer_id()
	if local_peer_id > 0 and connected_player_characters.has(local_peer_id):
		local_character_id = get_player_character_id(local_peer_id)
		local_character_confirmed = is_player_character_confirmed(local_peer_id)
	for previous_peer_id_variant in previous_players:
		var previous_peer_id := int(previous_peer_id_variant)
		if not connected_players.has(previous_peer_id):
			player_left.emit(previous_peer_id)
	for peer_id_variant in connected_players:
		var peer_id := int(peer_id_variant)
		var player_name := str(connected_players[peer_id])
		if (
			not previous_players.has(peer_id)
			or str(previous_players.get(peer_id, "")) != player_name
		):
			player_joined.emit(peer_id, player_name)
		var character_id := get_player_character_id(peer_id)
		var character_confirmed := is_player_character_confirmed(peer_id)
		if (
			not previous_characters.has(peer_id)
			or StringName(previous_characters.get(peer_id, DEFAULT_CHARACTER_ID)) != character_id
			or bool(previous_confirmations.get(peer_id, false)) != character_confirmed
		):
			player_character_changed.emit(peer_id, character_id, character_confirmed)
	player_list_changed.emit()


@rpc("authority", "call_remote", "reliable", 0)
func _rpc_start_game(game_mode: int = 0, session_id: int = 0) -> void:
	if multiplayer.get_remote_sender_id() != get_host_peer_id():
		return
	if not _is_valid_game_mode(game_mode) or session_id <= 0:
		return
	if connection_state >= ConnectionState.LOADING_GAME:
		# Reliable delivery should only apply this transition once. Ignore a stale or
		# duplicated start packet instead of resetting already reported readiness.
		return
	_set_current_game_mode(game_mode as GameMode)
	host_game_ready = false
	loading_session_id = session_id
	_expected_game_load_peers.clear()
	_ready_game_load_peers.clear()
	for peer_id_variant in connected_players:
		_expected_game_load_peers[int(peer_id_variant)] = true
	_set_connection_state(ConnectionState.LOADING_GAME)
	_emit_game_load_progress()


@rpc("authority", "call_remote", "reliable", 0)
func _rpc_host_game_ready(session_id: int = 0) -> void:
	if multiplayer.get_remote_sender_id() != get_host_peer_id():
		return
	if session_id != loading_session_id:
		return
	host_game_ready = true
	if connection_state >= ConnectionState.LOADING_GAME:
		_set_connection_state(ConnectionState.IN_GAME)


@rpc("any_peer", "call_remote", "reliable", 0)
func _rpc_report_game_loaded(session_id: int) -> void:
	if not is_host() or connection_state != ConnectionState.LOADING_GAME:
		return
	var sender_id := multiplayer.get_remote_sender_id()
	_mark_peer_game_loaded(sender_id, session_id)


@rpc("authority", "call_remote", "reliable", 0)
func _rpc_game_load_progress(session_id: int, ready_count: int, total_count: int) -> void:
	if multiplayer.get_remote_sender_id() != get_host_peer_id():
		return
	if session_id != loading_session_id:
		return
	_reported_game_load_total_count = maxi(total_count, 0)
	_reported_game_load_ready_count = clampi(
		ready_count,
		0,
		_reported_game_load_total_count
	)
	game_load_progress_changed.emit(
		_reported_game_load_ready_count,
		_reported_game_load_total_count
	)


func _build_player_list_array() -> Array:
	var result: Array = []
	for peer_id_variant in connected_players:
		var peer_id: int = int(peer_id_variant)
		result.append({
			"id": peer_id,
			"name": connected_players[peer_id],
			"character_id": String(get_player_character_id(peer_id)),
			"character_confirmed": is_player_character_confirmed(peer_id),
		})
	return result


func _broadcast_player_list_to_clients() -> void:
	if not is_host() or _enet_peer == null or not multiplayer.has_multiplayer_peer():
		return
	var host_id := get_host_peer_id()
	var player_list := _build_player_list_array()
	for peer_id_variant in connected_players:
		var peer_id := int(peer_id_variant)
		if peer_id <= 0 or peer_id == host_id:
			continue
		if not is_peer_send_ready(peer_id):
			continue
		_rpc_sync_player_list.rpc_id(peer_id, player_list, host_id, int(current_game_mode))


func _send_start_game_to_clients() -> void:
	var host_id := get_host_peer_id()
	for peer_id_variant in connected_players:
		var peer_id := int(peer_id_variant)
		if peer_id <= 0 or peer_id == host_id:
			continue
		if not is_peer_send_ready(peer_id):
			continue
		_rpc_start_game.rpc_id(peer_id, int(current_game_mode), loading_session_id)


func _send_host_game_ready_to_clients() -> void:
	var host_id := get_host_peer_id()
	for peer_id_variant in connected_players:
		var peer_id := int(peer_id_variant)
		if peer_id <= 0 or peer_id == host_id:
			continue
		if not is_peer_send_ready(peer_id):
			continue
		_rpc_host_game_ready.rpc_id(peer_id, loading_session_id)


func _mark_peer_game_loaded(peer_id: int, session_id: int) -> void:
	if not is_host() or connection_state != ConnectionState.LOADING_GAME:
		return
	if session_id != loading_session_id or not _expected_game_load_peers.has(peer_id):
		return
	if _ready_game_load_peers.has(peer_id):
		return
	_ready_game_load_peers[peer_id] = true
	_emit_game_load_progress()
	_broadcast_game_load_progress()
	_try_finish_game_loading()


func _try_finish_game_loading() -> void:
	if not is_host() or connection_state != ConnectionState.LOADING_GAME:
		return
	if not _are_all_game_load_peers_ready():
		return
	mark_in_game()


func _are_all_game_load_peers_ready() -> bool:
	if _expected_game_load_peers.is_empty():
		return false
	for peer_id_variant in _expected_game_load_peers:
		if not _ready_game_load_peers.has(int(peer_id_variant)):
			return false
	return true


func _emit_game_load_progress() -> void:
	_reported_game_load_ready_count = _ready_game_load_peers.size()
	_reported_game_load_total_count = _expected_game_load_peers.size()
	game_load_progress_changed.emit(
		_reported_game_load_ready_count,
		_reported_game_load_total_count
	)


func _broadcast_game_load_progress() -> void:
	if not is_host():
		return
	var host_id := get_host_peer_id()
	for peer_id_variant in _expected_game_load_peers:
		var peer_id := int(peer_id_variant)
		if peer_id <= 0 or peer_id == host_id or not is_peer_send_ready(peer_id):
			continue
		_rpc_game_load_progress.rpc_id(
			peer_id,
			loading_session_id,
			_ready_game_load_peers.size(),
			_expected_game_load_peers.size()
		)


func _set_connection_state(new_state: ConnectionState) -> void:
	if connection_state == new_state:
		return
	connection_state = new_state
	connection_state_changed.emit(new_state)


func _set_current_game_mode(game_mode: GameMode) -> void:
	if current_game_mode == game_mode:
		return
	current_game_mode = game_mode
	game_mode_changed.emit(current_game_mode)


func _is_valid_game_mode(game_mode: int) -> bool:
	return game_mode == GameMode.STANDARD or game_mode == GameMode.TOWER_DEFENSE


func _get_safe_local_name() -> String:
	return _sanitize_player_name(local_player_name)


func _set_peer_character(peer_id: int, character_id: StringName, confirmed: bool) -> void:
	if peer_id <= 0:
		return
	var resolved_character_id := _sanitize_character_id(character_id)
	var changed := (
		StringName(connected_player_characters.get(peer_id, DEFAULT_CHARACTER_ID))
		!= resolved_character_id
		or bool(confirmed_character_peers.get(peer_id, false)) != confirmed
	)
	connected_player_characters[peer_id] = resolved_character_id
	confirmed_character_peers[peer_id] = confirmed
	if changed:
		player_character_changed.emit(peer_id, resolved_character_id, confirmed)
		player_list_changed.emit()


func _sanitize_character_id(character_id: StringName) -> StringName:
	if PlayerCharacterRegistry.is_valid_character_id(character_id):
		return character_id
	return DEFAULT_CHARACTER_ID


func _sanitize_player_name(raw_name: String) -> String:
	var trimmed_name := raw_name.strip_edges()
	if trimmed_name.length() > NetConstants.MAX_PLAYER_NAME_LENGTH:
		trimmed_name = trimmed_name.left(NetConstants.MAX_PLAYER_NAME_LENGTH)
	return trimmed_name if not trimmed_name.is_empty() else "Player"


func _debug_log(message: String) -> void:
	if OS.is_debug_build():
		print(message)
