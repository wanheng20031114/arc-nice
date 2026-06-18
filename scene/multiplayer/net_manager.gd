extends Node

const NetConstants := preload("res://scene/multiplayer/net_constants.gd")

## 全局网络管理 Autoload。
## 管理连接生命周期、ENet peer 创建、直连 / Relay 切换、UPnP 端口映射。

signal connection_state_changed(new_state: ConnectionState)
signal player_joined(peer_id: int, player_name: String)
signal player_left(peer_id: int)
signal all_players_ready
signal relay_switch_requested
signal connection_failed(reason: String)

enum NetRole { NONE, HOST, CLIENT }
enum ConnMode { DIRECT, RELAY }
enum ConnectionState {
	DISCONNECTED,
	DISCOVERING_UPNP,
	CREATING_ROOM,
	JOINING_ROOM,
	CONNECTING_DIRECT,
	CONNECTING_RELAY,
	CONNECTED_IN_LOBBY,
	LOADING_GAME,
	IN_GAME,
}

## 当前状态
var net_role: NetRole = NetRole.NONE
var conn_mode: ConnMode = ConnMode.DIRECT
var connection_state: ConnectionState = ConnectionState.DISCONNECTED
var local_player_name: String = ""
var current_room_id: String = ""
var lobby_server_url: String = "http://127.0.0.1:8000"

## 已连接玩家信息  { peer_id: int → player_name: String }
var connected_players: Dictionary = {}

## UPnP 映射的外部端口（成功映射时 > 0）
var upnp_mapped_port: int = 0

## 用于跟踪物理帧计数，实现分频发送
var _physics_frame_count: int = 0

## ENet peer 引用
var _enet_peer: ENetMultiplayerPeer = null

## 直连超时计时器
var _direct_connect_timer: Timer = null


func _ready() -> void:
	# 创建直连超时计时器（不自动启动）
	_direct_connect_timer = Timer.new()
	_direct_connect_timer.one_shot = true
	_direct_connect_timer.wait_time = NetConstants.DIRECT_CONNECT_TIMEOUT_MS / 1000.0
	_direct_connect_timer.timeout.connect(_on_direct_connect_timeout)
	add_child(_direct_connect_timer)


func _physics_process(_delta: float) -> void:
	_physics_frame_count += 1


## 获取当前物理帧计数（供外部频率分频使用）
func get_physics_frame_count() -> int:
	return _physics_frame_count


## 判断是否处于多人模式
func is_multiplayer_active() -> bool:
	return net_role != NetRole.NONE and connection_state != ConnectionState.DISCONNECTED


## 判断本机是否为 Host
func is_host() -> bool:
	return net_role == NetRole.HOST


## 判断本机是否为 Client
func is_client() -> bool:
	return net_role == NetRole.CLIENT


# ─────────────────────────────────────────────
# 创建 / 加入 / 断开
# ─────────────────────────────────────────────

## Host 创建 ENet 服务器
func host_create_server(port: int = NetConstants.ENET_PORT_DEFAULT) -> Error:
	if _enet_peer != null:
		disconnect_from_game()

	_enet_peer = ENetMultiplayerPeer.new()
	var err := _enet_peer.create_server(port, NetConstants.MAX_PLAYERS, 0, 0, NetConstants.CHANNEL_COUNT)
	if err != OK:
		push_error("NetManager: create_server 失败, error=%s" % error_string(err))
		_enet_peer = null
		connection_failed.emit("创建服务器失败: %s" % error_string(err))
		return err

	multiplayer.multiplayer_peer = _enet_peer
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)

	net_role = NetRole.HOST
	conn_mode = ConnMode.DIRECT

	# Host 自己加入玩家列表，peer_id = 1
	connected_players[1] = local_player_name
	_set_connection_state(ConnectionState.CONNECTED_IN_LOBBY)

	print("NetManager: Host 服务器已创建, port=%d" % port)
	return OK


## Client 直连 Host
func client_connect_direct(host_ip: String, port: int = NetConstants.ENET_PORT_DEFAULT) -> Error:
	if _enet_peer != null:
		disconnect_from_game()

	_enet_peer = ENetMultiplayerPeer.new()
	var err := _enet_peer.create_client(host_ip, port, NetConstants.CHANNEL_COUNT)
	if err != OK:
		push_error("NetManager: create_client 失败, error=%s" % error_string(err))
		_enet_peer = null
		connection_failed.emit("连接失败: %s" % error_string(err))
		return err

	multiplayer.multiplayer_peer = _enet_peer
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)

	net_role = NetRole.CLIENT
	conn_mode = ConnMode.DIRECT
	_set_connection_state(ConnectionState.CONNECTING_DIRECT)

	# 启动直连超时计时器
	_direct_connect_timer.start()

	print("NetManager: Client 正在直连 %s:%d" % [host_ip, port])
	return OK


## Client 连接 Relay
func client_connect_relay(relay_ip: String, relay_port: int) -> Error:
	if _enet_peer != null:
		disconnect_from_game()

	_enet_peer = ENetMultiplayerPeer.new()
	var err := _enet_peer.create_client(relay_ip, relay_port, NetConstants.CHANNEL_COUNT)
	if err != OK:
		push_error("NetManager: Relay create_client 失败, error=%s" % error_string(err))
		_enet_peer = null
		connection_failed.emit("Relay 连接失败: %s" % error_string(err))
		return err

	multiplayer.multiplayer_peer = _enet_peer
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)

	net_role = NetRole.CLIENT
	conn_mode = ConnMode.RELAY
	_set_connection_state(ConnectionState.CONNECTING_RELAY)

	print("NetManager: Client 正在连接 Relay %s:%d" % [relay_ip, relay_port])
	return OK


## Host 切换到 Relay 模式
func host_switch_to_relay(relay_ip: String, relay_port: int) -> Error:
	# 先断开当前直连服务器
	if _enet_peer != null:
		_cleanup_multiplayer_signals()
		multiplayer.multiplayer_peer = null
		_enet_peer = null

	# 作为 client 连接到 Relay（Relay 本身是 ENet server）
	_enet_peer = ENetMultiplayerPeer.new()
	var err := _enet_peer.create_client(relay_ip, relay_port, NetConstants.CHANNEL_COUNT)
	if err != OK:
		push_error("NetManager: Host→Relay create_client 失败, error=%s" % error_string(err))
		_enet_peer = null
		connection_failed.emit("Host Relay 连接失败: %s" % error_string(err))
		return err

	multiplayer.multiplayer_peer = _enet_peer
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)

	conn_mode = ConnMode.RELAY
	_set_connection_state(ConnectionState.CONNECTING_RELAY)

	print("NetManager: Host 正在切换到 Relay %s:%d" % [relay_ip, relay_port])
	return OK


## 断开连接并清理所有状态
func disconnect_from_game() -> void:
	_direct_connect_timer.stop()
	_cleanup_upnp()
	_cleanup_multiplayer_signals()

	if multiplayer.has_multiplayer_peer():
		multiplayer.multiplayer_peer = null

	_enet_peer = null
	net_role = NetRole.NONE
	conn_mode = ConnMode.DIRECT
	connected_players.clear()
	current_room_id = ""
	_physics_frame_count = 0
	_set_connection_state(ConnectionState.DISCONNECTED)
	print("NetManager: 已断开连接")


# ─────────────────────────────────────────────
# UPnP 端口映射
# ─────────────────────────────────────────────

## 尝试 UPnP 端口映射（在后台线程执行以避免阻塞）
func try_upnp_port_mapping(port: int = NetConstants.ENET_PORT_DEFAULT) -> void:
	_set_connection_state(ConnectionState.DISCOVERING_UPNP)
	# UPnP 发现是阻塞操作，在单独线程中执行
	var thread := Thread.new()
	thread.start(_upnp_thread_func.bind(port, thread))


func _upnp_thread_func(port: int, thread: Thread) -> void:
	var upnp := UPNP.new()
	var discover_result := upnp.discover(NetConstants.UPNP_DISCOVER_TIMEOUT_MS)

	if discover_result != UPNP.UPNP_RESULT_SUCCESS:
		call_deferred("_on_upnp_completed", 0, thread)
		return

	if upnp.get_gateway() == null or not upnp.get_gateway().is_valid_gateway():
		call_deferred("_on_upnp_completed", 0, thread)
		return

	var map_result := upnp.add_port_mapping(port, port, "ArcNice", "UDP")
	if map_result != UPNP.UPNP_RESULT_SUCCESS:
		call_deferred("_on_upnp_completed", 0, thread)
		return

	call_deferred("_on_upnp_completed", port, thread)


func _on_upnp_completed(mapped_port: int, thread: Thread) -> void:
	if thread != null and thread.is_started():
		thread.wait_to_finish()

	upnp_mapped_port = mapped_port
	if mapped_port > 0:
		print("NetManager: UPnP 端口映射成功, port=%d" % mapped_port)
	else:
		print("NetManager: UPnP 端口映射失败（将依赖 Relay）")


func _cleanup_upnp() -> void:
	if upnp_mapped_port > 0:
		var upnp := UPNP.new()
		var discover_result := upnp.discover(1000)
		if discover_result == UPNP.UPNP_RESULT_SUCCESS:
			upnp.delete_port_mapping(upnp_mapped_port, "UDP")
		upnp_mapped_port = 0


# ─────────────────────────────────────────────
# 信号回调
# ─────────────────────────────────────────────

func _on_peer_connected(peer_id: int) -> void:
	print("NetManager: Peer 已连接, id=%d" % peer_id)
	# 等待对方通过 RPC 发送玩家名


func _on_peer_disconnected(peer_id: int) -> void:
	var player_name: String = connected_players.get(peer_id, "Unknown")
	connected_players.erase(peer_id)
	player_left.emit(peer_id)
	print("NetManager: Peer 已断开, id=%d (%s)" % [peer_id, player_name])


func _on_connected_to_server() -> void:
	_direct_connect_timer.stop()
	print("NetManager: 已成功连接到服务器")
	# 向 Host 发送自己的玩家名
	_rpc_register_player.rpc_id(1, local_player_name)
	_set_connection_state(ConnectionState.CONNECTED_IN_LOBBY)


func _on_connection_failed() -> void:
	_direct_connect_timer.stop()
	print("NetManager: 连接失败")

	if conn_mode == ConnMode.DIRECT:
		# 直连失败，请求切换到 Relay
		relay_switch_requested.emit()
	else:
		connection_failed.emit("连接服务器失败")
		disconnect_from_game()


func _on_direct_connect_timeout() -> void:
	if connection_state == ConnectionState.CONNECTING_DIRECT:
		print("NetManager: 直连超时，请求切换到 Relay")
		_cleanup_multiplayer_signals()
		if multiplayer.has_multiplayer_peer():
			multiplayer.multiplayer_peer = null
		_enet_peer = null
		relay_switch_requested.emit()


# ─────────────────────────────────────────────
# RPC：玩家注册
# ─────────────────────────────────────────────

## Client → Host：注册玩家名
@rpc("any_peer", "call_remote", "reliable", 0)
func _rpc_register_player(player_name: String) -> void:
	var sender_id := multiplayer.get_remote_sender_id()
	if sender_id == 0:
		return

	if connected_players.size() >= NetConstants.MAX_PLAYERS:
		# 超过最大人数，踢掉
		_enet_peer.get_peer(sender_id).peer_disconnect()
		return

	connected_players[sender_id] = player_name
	player_joined.emit(sender_id, player_name)
	print("NetManager: 玩家注册, id=%d, name=%s" % [sender_id, player_name])

	# 向所有已连接的客户端广播最新的玩家列表
	_rpc_sync_player_list.rpc(_build_player_list_array())


## Host → All Clients：同步完整玩家列表
@rpc("authority", "call_remote", "reliable", 0)
func _rpc_sync_player_list(player_list: Array) -> void:
	connected_players.clear()
	for entry: Dictionary in player_list:
		var peer_id: int = entry.get("id", 0)
		var player_name: String = entry.get("name", "")
		if peer_id > 0:
			connected_players[peer_id] = player_name
			player_joined.emit(peer_id, player_name)


## Host → All Clients：通知开始加载游戏
@rpc("authority", "call_remote", "reliable", 0)
func _rpc_start_game() -> void:
	_set_connection_state(ConnectionState.LOADING_GAME)


## Host 调用：通知所有人开始游戏
func host_start_game() -> void:
	if net_role != NetRole.HOST:
		return
	_set_connection_state(ConnectionState.LOADING_GAME)
	_rpc_start_game.rpc()


# ─────────────────────────────────────────────
# 工具方法
# ─────────────────────────────────────────────

func _set_connection_state(new_state: ConnectionState) -> void:
	if connection_state == new_state:
		return
	connection_state = new_state
	connection_state_changed.emit(new_state)


func _build_player_list_array() -> Array:
	var result: Array = []
	for peer_id: int in connected_players:
		result.append({"id": peer_id, "name": connected_players[peer_id]})
	return result


func _cleanup_multiplayer_signals() -> void:
	if multiplayer.peer_connected.is_connected(_on_peer_connected):
		multiplayer.peer_connected.disconnect(_on_peer_connected)
	if multiplayer.peer_disconnected.is_connected(_on_peer_disconnected):
		multiplayer.peer_disconnected.disconnect(_on_peer_disconnected)
	if multiplayer.connected_to_server.is_connected(_on_connected_to_server):
		multiplayer.connected_to_server.disconnect(_on_connected_to_server)
	if multiplayer.connection_failed.is_connected(_on_connection_failed):
		multiplayer.connection_failed.disconnect(_on_connection_failed)


func get_player_name_by_id(peer_id: int) -> String:
	return connected_players.get(peer_id, "")


func get_local_peer_id() -> int:
	if not multiplayer.has_multiplayer_peer():
		return 0
	return multiplayer.get_unique_id()
