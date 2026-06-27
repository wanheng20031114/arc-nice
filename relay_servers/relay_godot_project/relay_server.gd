extends Node

## Godot Headless Relay Server。
## 以无头模式运行，仅做 ENet 包转发（利用 Godot 内置 server_relay）。
## 命令行参数: --port=40001

const DEFAULT_PORT := 40001
const DEFAULT_IDLE_TIMEOUT_SEC := 10.0 * 60.0 * 60.0
const EMPTY_AFTER_CONNECTION_TIMEOUT_SEC := 1.0
const MAX_CLIENTS := 8
const CHANNEL_COUNT := 5

var _port: int = DEFAULT_PORT
var _idle_timeout_sec: float = DEFAULT_IDLE_TIMEOUT_SEC
var _idle_timer: float = 0.0
var _has_had_connections: bool = false
var _host_peer_id: int = 0


func _ready() -> void:
	_parse_command_line()
	_start_server()


func _parse_command_line() -> void:
	var args := OS.get_cmdline_user_args()
	for arg: String in args:
		if arg.begins_with("--port="):
			var port_str := arg.substr(7)
			if port_str.is_valid_int():
				_port = port_str.to_int()
				print("[Relay] 端口参数: %d" % _port)
		elif arg.begins_with("--idle-timeout="):
			var timeout_str := arg.substr(15)
			if timeout_str.is_valid_float():
				_idle_timeout_sec = maxf(timeout_str.to_float(), DEFAULT_IDLE_TIMEOUT_SEC)
				print("[Relay] 空闲超时参数: %d 秒" % int(_idle_timeout_sec))


func _start_server() -> void:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(_port, MAX_CLIENTS, CHANNEL_COUNT)
	if err != OK:
		push_error("[Relay] 创建服务器失败 (port=%d): %s" % [_port, error_string(err)])
		get_tree().quit(1)
		return

	# 开启 server_relay：服务器自动转发客户端之间的 RPC 和包
	multiplayer.server_relay = true

	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.multiplayer_peer = peer

	print("[Relay] 服务器已启动, port=%d, server_relay=true" % _port)


func _process(delta: float) -> void:
	# 空闲超时检测
	if not _has_had_connections:
		_idle_timer += delta
		if _idle_timer >= _idle_timeout_sec:
			print("[Relay] 空闲超时 (%d 秒), 自动退出" % int(_idle_timeout_sec))
			get_tree().quit(0)
		return

	# 有过连接后，检查是否全部断开
	if not multiplayer.has_multiplayer_peer():
		return

	var peer := multiplayer.multiplayer_peer as ENetMultiplayerPeer
	if peer == null:
		return

	var connected_peers := multiplayer.get_peers()
	if connected_peers.is_empty():
		_idle_timer += delta
		if _idle_timer >= EMPTY_AFTER_CONNECTION_TIMEOUT_SEC:
			print("[Relay] 所有玩家已离开，自动退出")
			get_tree().quit(0)
	else:
		_idle_timer = 0.0


func _on_peer_connected(peer_id: int) -> void:
	_has_had_connections = true
	_idle_timer = 0.0
	if _host_peer_id <= 0:
		_host_peer_id = peer_id
		var net_manager_stub := get_node_or_null("/root/NetManager")
		if net_manager_stub != null:
			net_manager_stub.set_multiplayer_authority(_host_peer_id)
		var mp_game_stub := get_node_or_null("/root/MpGame")
		if mp_game_stub != null:
			mp_game_stub.set_multiplayer_authority(_host_peer_id)
	var connected_count := multiplayer.get_peers().size()
	print("[Relay] 玩家连接 peer_id=%d (当前 %d 人)" % [peer_id, connected_count])


func _on_peer_disconnected(peer_id: int) -> void:
	var connected_count := multiplayer.get_peers().size()
	print("[Relay] 玩家断开 peer_id=%d (剩余 %d 人)" % [peer_id, connected_count])
