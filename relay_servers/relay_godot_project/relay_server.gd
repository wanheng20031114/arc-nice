extends Node

## Godot Headless Relay Server。
## 以无头模式运行，仅做 ENet 包转发（利用 Godot 内置 server_relay）。
## 命令行参数包含端口、容量以及三段互不混用的生命周期租约。

const DEFAULT_PORT := 40001
const DEFAULT_STARTUP_IDLE_TIMEOUT_SEC := 120.0
const DEFAULT_EMPTY_IDLE_TIMEOUT_SEC := 120.0
const DEFAULT_MAX_LIFETIME_SEC := 10.0 * 60.0 * 60.0
const MIN_CLIENTS := 2
const MAX_CLIENTS := 8
const DEFAULT_MAX_CLIENTS := MAX_CLIENTS
const CHANNEL_COUNT := 8
const PROTOCOL_VERSION := 83

var _port: int = DEFAULT_PORT
var _startup_idle_timeout_sec: float = DEFAULT_STARTUP_IDLE_TIMEOUT_SEC
var _empty_idle_timeout_sec: float = DEFAULT_EMPTY_IDLE_TIMEOUT_SEC
var _max_lifetime_sec: float = DEFAULT_MAX_LIFETIME_SEC
var _max_clients: int = DEFAULT_MAX_CLIENTS
var _started_at_msec: int = 0
var _empty_since_msec: int = 0
var _has_had_connections: bool = false
var _host_peer_id: int = 0
var _has_invalid_argument: bool = false


func _ready() -> void:
	_parse_command_line()
	if _has_invalid_argument:
		get_tree().quit(2)
		return
	_start_server()


func _parse_command_line() -> void:
	var args := OS.get_cmdline_user_args()
	for arg: String in args:
		if arg.begins_with("--port="):
			var port_str := arg.substr(7)
			if port_str.is_valid_int():
				_port = port_str.to_int()
				print("[Relay] 端口参数: %d" % _port)
		elif arg.begins_with("--startup-idle-timeout="):
			var parsed_startup_timeout := _parse_positive_timeout(
				arg,
				"--startup-idle-timeout=",
				"首次连接空闲超时"
			)
			if parsed_startup_timeout > 0.0:
				_startup_idle_timeout_sec = parsed_startup_timeout
		elif arg.begins_with("--empty-idle-timeout="):
			var parsed_empty_timeout := _parse_positive_timeout(
				arg,
				"--empty-idle-timeout=",
				"断线后空载超时"
			)
			if parsed_empty_timeout > 0.0:
				_empty_idle_timeout_sec = parsed_empty_timeout
		elif arg.begins_with("--max-lifetime="):
			var parsed_max_lifetime := _parse_positive_timeout(
				arg,
				"--max-lifetime=",
				"绝对生命周期"
			)
			if parsed_max_lifetime > 0.0:
				_max_lifetime_sec = parsed_max_lifetime
		elif arg.begins_with("--max-clients="):
			var max_clients_str := arg.substr(14)
			if not max_clients_str.is_valid_int():
				push_error("[Relay] 最大连接数参数不是整数: %s" % max_clients_str)
				_has_invalid_argument = true
				continue
			var parsed_max_clients := max_clients_str.to_int()
			if parsed_max_clients < MIN_CLIENTS or parsed_max_clients > MAX_CLIENTS:
				push_error(
					"[Relay] 最大连接数必须在 %d..%d 之间: %d"
					% [MIN_CLIENTS, MAX_CLIENTS, parsed_max_clients]
				)
				_has_invalid_argument = true
				continue
			_max_clients = parsed_max_clients
			print("[Relay] 最大连接数参数: %d" % _max_clients)


func _parse_positive_timeout(arg: String, prefix: String, label: String) -> float:
	var timeout_str := arg.trim_prefix(prefix)
	if not timeout_str.is_valid_float():
		push_error("[Relay] %s参数不是数字: %s" % [label, timeout_str])
		_has_invalid_argument = true
		return -1.0
	var value := timeout_str.to_float()
	if not is_finite(value) or value <= 0.0:
		push_error("[Relay] %s必须大于 0: %s" % [label, timeout_str])
		_has_invalid_argument = true
		return -1.0
	print("[Relay] %s参数: %.3f 秒" % [label, value])
	return value


func _start_server() -> void:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(_port, _max_clients, CHANNEL_COUNT)
	if err != OK:
		push_error("[Relay] 创建服务器失败 (port=%d): %s" % [_port, error_string(err)])
		get_tree().quit(1)
		return

	# 开启 server_relay：服务器自动转发客户端之间的 RPC 和包
	multiplayer.server_relay = true

	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.multiplayer_peer = peer
	_started_at_msec = Time.get_ticks_msec()
	_empty_since_msec = _started_at_msec

	print(
		(
			"[Relay] 服务器已启动, port=%d, max_clients=%d, protocol=v%d, "
			+ "startup_idle=%.3f, empty_idle=%.3f, max_lifetime=%.3f, server_relay=true"
		)
		% [
			_port,
			_max_clients,
			PROTOCOL_VERSION,
			_startup_idle_timeout_sec,
			_empty_idle_timeout_sec,
			_max_lifetime_sec,
		]
	)


func _process(_delta: float) -> void:
	# ticks 是不受 wall clock 回拨与游戏 time scale 影响的进程单调时钟。
	var now_msec := Time.get_ticks_msec()
	if _elapsed_seconds(_started_at_msec, now_msec) >= _max_lifetime_sec:
		print("[Relay] 达到绝对生命周期上限，自动退出")
		get_tree().quit(0)
		return

	# 首次连接租约独立于游戏绝对时长，遗失创建响应不会长期占住进程。
	if not _has_had_connections:
		if _elapsed_seconds(_empty_since_msec, now_msec) >= _startup_idle_timeout_sec:
			print("[Relay] 首次连接超时，自动退出")
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
		if _elapsed_seconds(_empty_since_msec, now_msec) >= _empty_idle_timeout_sec:
			print("[Relay] 所有玩家离开且重连窗口已过，自动退出")
			get_tree().quit(0)
	else:
		_empty_since_msec = now_msec


static func _elapsed_seconds(started_at_msec: int, now_msec: int) -> float:
	return float(maxi(now_msec - started_at_msec, 0)) / 1000.0


func _on_peer_connected(peer_id: int) -> void:
	_has_had_connections = true
	_empty_since_msec = Time.get_ticks_msec()
	if _host_peer_id <= 0:
		_host_peer_id = peer_id
		var net_manager_stub := get_node_or_null("/root/NetManager")
		if net_manager_stub != null:
			net_manager_stub.set_multiplayer_authority(_host_peer_id)
		var mp_game_stub := get_node_or_null("/root/MpGame")
		if mp_game_stub != null:
			mp_game_stub.set_multiplayer_authority(_host_peer_id)
		var rogue_route_stub := get_node_or_null("/root/MpRogueRoute")
		if rogue_route_stub != null:
			rogue_route_stub.set_multiplayer_authority(_host_peer_id)
	var connected_count := multiplayer.get_peers().size()
	print("[Relay] 玩家连接 peer_id=%d (当前 %d 人)" % [peer_id, connected_count])


func _on_peer_disconnected(peer_id: int) -> void:
	var connected_count := multiplayer.get_peers().size()
	if connected_count == 0:
		# 空载宽限从最后一名玩家离开时起算，不吞掉任何重连窗口。
		_empty_since_msec = Time.get_ticks_msec()
	print("[Relay] 玩家断开 peer_id=%d (剩余 %d 人)" % [peer_id, connected_count])


## Relay 的 server_relay 拓扑下，逻辑 Host 只有到服务端（peer 1）的
## ENet 连接，不能自行取得其他逻辑客户端的 ENetPacketPeer。这个控制面只
## 接受本房间已登记 Host 发出的可靠请求；任何客户端都不能借此踢出他人。
func request_host_peer_disconnect(sender_peer_id: int, target_peer_id: int) -> bool:
	var connected_peers := multiplayer.get_peers()
	if not is_authorized_host_kick_request(
		_host_peer_id,
		sender_peer_id,
		target_peer_id,
		connected_peers
	):
		push_warning(
			"[Relay] 拒绝未经授权的断开请求 sender=%d target=%d host=%d"
			% [sender_peer_id, target_peer_id, _host_peer_id]
		)
		return false
	var peer := multiplayer.multiplayer_peer as ENetMultiplayerPeer
	if peer == null:
		return false
	peer.disconnect_peer(target_peer_id, true)
	return true


static func is_authorized_host_kick_request(
	registered_host_peer_id: int,
	sender_peer_id: int,
	target_peer_id: int,
	connected_peers: PackedInt32Array
) -> bool:
	return (
		registered_host_peer_id > 0
		and sender_peer_id == registered_host_peer_id
		and target_peer_id > 0
		and target_peer_id != registered_host_peer_id
		and connected_peers.has(sender_peer_id)
		and connected_peers.has(target_peer_id)
	)
