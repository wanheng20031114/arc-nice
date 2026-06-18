extends Node

## Godot Headless Relay Server。
## 以无头模式运行，仅做 ENet 包转发（利用 Godot 内置 server_relay）。
## 命令行参数: --port=40001

const DEFAULT_PORT := 40001
const IDLE_TIMEOUT_SEC := 300.0
const MAX_CLIENTS := 8

var _port: int = DEFAULT_PORT
var _idle_timer: float = 0.0
var _has_had_connections: bool = false


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


func _start_server() -> void:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(_port, MAX_CLIENTS)
	if err != OK:
		push_error("[Relay] 创建服务器失败 (port=%d): %s" % [_port, error_string(err)])
		get_tree().quit(1)
		return

	multiplayer.multiplayer_peer = peer

	# 开启 server_relay：服务器自动转发客户端之间的 RPC 和包
	multiplayer.server_relay = true

	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)

	print("[Relay] 服务器已启动, port=%d, server_relay=true" % _port)


func _process(delta: float) -> void:
	# 空闲超时检测
	if not _has_had_connections:
		_idle_timer += delta
		if _idle_timer >= IDLE_TIMEOUT_SEC:
			print("[Relay] 空闲超时 (%d 秒), 自动退出" % int(IDLE_TIMEOUT_SEC))
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
		if _idle_timer >= IDLE_TIMEOUT_SEC:
			print("[Relay] 所有玩家已离开，空闲超时, 自动退出")
			get_tree().quit(0)
	else:
		_idle_timer = 0.0


func _on_peer_connected(peer_id: int) -> void:
	_has_had_connections = true
	_idle_timer = 0.0
	var connected_count := multiplayer.get_peers().size()
	print("[Relay] 玩家连接 peer_id=%d (当前 %d 人)" % [peer_id, connected_count])


func _on_peer_disconnected(peer_id: int) -> void:
	var connected_count := multiplayer.get_peers().size()
	print("[Relay] 玩家断开 peer_id=%d (剩余 %d 人)" % [peer_id, connected_count])
