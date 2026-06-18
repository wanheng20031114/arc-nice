extends Control

## 多人模式大厅场景的主控脚本。
## 负责用户名输入、房间列表、创建/加入房间、以及等待面板。

const _NetConstants := preload("res://scene/multiplayer/net_constants.gd")

const MULTIPLAYER_GAME_SCENE_PATH := "res://scene/multiplayer/mp_game.tscn"

enum LobbyView {
	USERNAME_INPUT,
	ROOM_BROWSER,
	ROOM_WAIT,
}

@onready var username_panel: PanelContainer = $LobbyCenter/UsernamePanel
@onready var username_input: LineEdit = $LobbyCenter/UsernamePanel/MarginContainer/VBoxContainer/UsernameInput
@onready var username_confirm_btn: Button = $LobbyCenter/UsernamePanel/MarginContainer/VBoxContainer/ConfirmUsernameButton
@onready var username_error_label: Label = $LobbyCenter/UsernamePanel/MarginContainer/VBoxContainer/UsernameErrorLabel

@onready var room_browser_panel: PanelContainer = $LobbyCenter/RoomBrowserPanel
@onready var room_list_vbox: VBoxContainer = $LobbyCenter/RoomBrowserPanel/MarginContainer/VBoxContainer/TabContainer/RoomListTab/ScrollContainer/RoomListVBox
@onready var refresh_btn: Button = $LobbyCenter/RoomBrowserPanel/MarginContainer/VBoxContainer/TabContainer/RoomListTab/RefreshButton
@onready var room_name_input: LineEdit = $LobbyCenter/RoomBrowserPanel/MarginContainer/VBoxContainer/TabContainer/CreateRoomTab/RoomNameInput
@onready var max_players_spin: SpinBox = $LobbyCenter/RoomBrowserPanel/MarginContainer/VBoxContainer/TabContainer/CreateRoomTab/MaxPlayersSpinBox
@onready var create_room_btn: Button = $LobbyCenter/RoomBrowserPanel/MarginContainer/VBoxContainer/TabContainer/CreateRoomTab/CreateRoomButton
@onready var quick_match_btn: Button = $LobbyCenter/RoomBrowserPanel/MarginContainer/VBoxContainer/TabContainer/QuickMatchTab/QuickMatchButton
@onready var browser_status_label: Label = $LobbyCenter/RoomBrowserPanel/MarginContainer/VBoxContainer/BrowserStatusLabel
@onready var browser_back_btn: Button = $LobbyCenter/RoomBrowserPanel/MarginContainer/VBoxContainer/BackButton

@onready var room_wait_panel: PanelContainer = $LobbyCenter/RoomWaitPanel
@onready var room_code_label: Label = $LobbyCenter/RoomWaitPanel/MarginContainer/VBoxContainer/RoomCodeLabel
@onready var wait_player_list_vbox: VBoxContainer = $LobbyCenter/RoomWaitPanel/MarginContainer/VBoxContainer/PlayerListScroll/PlayerListVBox
@onready var start_game_btn: Button = $LobbyCenter/RoomWaitPanel/MarginContainer/VBoxContainer/StartGameButton
@onready var leave_room_btn: Button = $LobbyCenter/RoomWaitPanel/MarginContainer/VBoxContainer/LeaveButton
@onready var wait_status_label: Label = $LobbyCenter/RoomWaitPanel/MarginContainer/VBoxContainer/WaitStatusLabel

@onready var net_manager: Node = get_node("/root/NetManager")

var current_view: LobbyView = LobbyView.USERNAME_INPUT

## HTTP 请求节点（动态创建）
var _http_request: HTTPRequest = null

## 当前等待的 HTTP 操作
var _pending_http_action: String = ""


func _ready() -> void:
	_http_request = HTTPRequest.new()
	add_child(_http_request)
	_http_request.request_completed.connect(_on_http_request_completed)

	# 连接按钮信号
	username_confirm_btn.pressed.connect(_on_confirm_username)
	username_input.text_submitted.connect(_on_username_text_submitted)
	refresh_btn.pressed.connect(_on_refresh_rooms)
	create_room_btn.pressed.connect(_on_create_room)
	quick_match_btn.pressed.connect(_on_quick_match)
	browser_back_btn.pressed.connect(_on_back_to_main_menu)
	start_game_btn.pressed.connect(_on_start_game)
	leave_room_btn.pressed.connect(_on_leave_room)

	# 连接网络管理器信号
	net_manager.player_joined.connect(_on_net_player_joined)
	net_manager.player_left.connect(_on_net_player_left)
	net_manager.connection_failed.connect(_on_net_connection_failed)
	net_manager.connection_state_changed.connect(_on_net_state_changed)
	net_manager.relay_switch_requested.connect(_on_relay_switch_requested)

	# 初始化界面
	_show_view(LobbyView.USERNAME_INPUT)
	username_input.grab_focus()


# ─────────────────────────────────────────────
# 视图切换
# ─────────────────────────────────────────────

func _show_view(view: LobbyView) -> void:
	current_view = view
	username_panel.visible = (view == LobbyView.USERNAME_INPUT)
	room_browser_panel.visible = (view == LobbyView.ROOM_BROWSER)
	room_wait_panel.visible = (view == LobbyView.ROOM_WAIT)


# ─────────────────────────────────────────────
# 用户名输入
# ─────────────────────────────────────────────

func _on_confirm_username() -> void:
	var raw_name := username_input.text.strip_edges()
	if raw_name.length() < 1:
		username_error_label.text = "请输入用户名"
		username_error_label.visible = true
		return
	if raw_name.length() > 16:
		username_error_label.text = "用户名最多 16 个字符"
		username_error_label.visible = true
		return

	username_error_label.visible = false
	net_manager.local_player_name = raw_name
	_show_view(LobbyView.ROOM_BROWSER)
	browser_status_label.text = "欢迎，%s！" % raw_name
	_on_refresh_rooms()


func _on_username_text_submitted(_text: String) -> void:
	_on_confirm_username()


# ─────────────────────────────────────────────
# 房间列表
# ─────────────────────────────────────────────

func _on_refresh_rooms() -> void:
	browser_status_label.text = "正在获取房间列表…"
	_pending_http_action = "list_rooms"
	var url := net_manager.lobby_server_url + "/rooms"
	var err := _http_request.request(url)
	if err != OK:
		browser_status_label.text = "请求失败: %s" % error_string(err)


func _populate_room_list(rooms: Array) -> void:
	# 清空旧列表
	for child in room_list_vbox.get_children():
		child.queue_free()

	if rooms.is_empty():
		browser_status_label.text = "暂无可加入的房间"
		return

	browser_status_label.text = "找到 %d 个房间" % rooms.size()

	for room_data: Dictionary in rooms:
		var btn := Button.new()
		var room_id: String = room_data.get("id", "")
		var room_name: String = room_data.get("name", "未命名")
		var player_count: int = room_data.get("player_count", 0)
		var max_count: int = room_data.get("max_players", _NetConstants.MAX_PLAYERS)
		btn.text = "%s  (%d/%d)" % [room_name, player_count, max_count]
		btn.pressed.connect(_on_join_room.bind(room_id))
		room_list_vbox.add_child(btn)


# ─────────────────────────────────────────────
# 创建房间
# ─────────────────────────────────────────────

func _on_create_room() -> void:
	var room_name := room_name_input.text.strip_edges()
	if room_name.is_empty():
		room_name = "%s 的房间" % net_manager.local_player_name
	var max_count := int(max_players_spin.value)

	browser_status_label.text = "正在创建房间…"
	_pending_http_action = "create_room"

	var body := JSON.stringify({
		"name": room_name,
		"host_name": net_manager.local_player_name,
		"max_players": max_count,
	})

	var url := net_manager.lobby_server_url + "/rooms"
	var headers := ["Content-Type: application/json"]
	var err := _http_request.request(url, headers, HTTPClient.METHOD_POST, body)
	if err != OK:
		browser_status_label.text = "创建房间请求失败: %s" % error_string(err)


# ─────────────────────────────────────────────
# 加入房间
# ─────────────────────────────────────────────

func _on_join_room(room_id: String) -> void:
	browser_status_label.text = "正在加入房间…"
	_pending_http_action = "join_room"

	var body := JSON.stringify({
		"player_name": net_manager.local_player_name,
	})

	var url := net_manager.lobby_server_url + "/rooms/%s/join" % room_id
	var headers := ["Content-Type: application/json"]
	var err := _http_request.request(url, headers, HTTPClient.METHOD_POST, body)
	if err != OK:
		browser_status_label.text = "加入房间请求失败: %s" % error_string(err)


# ─────────────────────────────────────────────
# 快速匹配
# ─────────────────────────────────────────────

func _on_quick_match() -> void:
	browser_status_label.text = "正在匹配…"
	_pending_http_action = "quick_match"

	var body := JSON.stringify({
		"player_name": net_manager.local_player_name,
	})

	var url := net_manager.lobby_server_url + "/matchmaking/quick"
	var headers := ["Content-Type: application/json"]
	var err := _http_request.request(url, headers, HTTPClient.METHOD_POST, body)
	if err != OK:
		browser_status_label.text = "匹配请求失败: %s" % error_string(err)


# ─────────────────────────────────────────────
# HTTP 响应处理
# ─────────────────────────────────────────────

func _on_http_request_completed(
	result: int,
	response_code: int,
	_headers: PackedStringArray,
	body: PackedByteArray,
) -> void:
	if result != HTTPRequest.RESULT_SUCCESS:
		browser_status_label.text = "网络请求失败 (result=%d)" % result
		_pending_http_action = ""
		return

	var body_text := body.get_string_from_utf8()
	var json := JSON.new()
	var parse_err := json.parse(body_text)
	if parse_err != OK:
		browser_status_label.text = "解析响应失败"
		_pending_http_action = ""
		return

	var data: Variant = json.data
	if response_code < 200 or response_code >= 300:
		var err_msg: String = data.get("detail", "未知错误") if data is Dictionary else "HTTP %d" % response_code
		browser_status_label.text = "服务器错误: %s" % err_msg
		_pending_http_action = ""
		return

	match _pending_http_action:
		"list_rooms":
			_handle_list_rooms_response(data)
		"create_room":
			_handle_create_room_response(data)
		"join_room":
			_handle_join_room_response(data)
		"quick_match":
			_handle_join_room_response(data)
		"request_relay":
			_handle_relay_response(data)

	_pending_http_action = ""


func _handle_list_rooms_response(data: Variant) -> void:
	if data is Array:
		_populate_room_list(data)
	else:
		browser_status_label.text = "房间列表数据格式错误"


func _handle_create_room_response(data: Variant) -> void:
	if not data is Dictionary:
		browser_status_label.text = "创建房间响应格式错误"
		return

	var room_data: Dictionary = data
	net_manager.current_room_id = room_data.get("id", "")
	var port: int = room_data.get("port", _NetConstants.ENET_PORT_DEFAULT)

	# Host: 先尝试 UPnP 端口映射，然后创建 ENet 服务器
	net_manager.try_upnp_port_mapping(port)

	# 给 UPnP 一点时间再创建服务器（UPnP 失败不影响局域网）
	await get_tree().create_timer(0.5).timeout
	var err := net_manager.host_create_server(port)
	if err != OK:
		browser_status_label.text = "创建服务器失败"
		return

	_enter_room_wait(room_data)


func _handle_join_room_response(data: Variant) -> void:
	if not data is Dictionary:
		browser_status_label.text = "加入房间响应格式错误"
		return

	var room_data: Dictionary = data
	net_manager.current_room_id = room_data.get("id", "")
	var host_ip: String = room_data.get("host_ip", "")
	var port: int = room_data.get("port", _NetConstants.ENET_PORT_DEFAULT)

	# Client: 尝试直连 Host
	var err := net_manager.client_connect_direct(host_ip, port)
	if err != OK:
		browser_status_label.text = "连接失败"
		return

	_enter_room_wait(room_data)


func _handle_relay_response(data: Variant) -> void:
	if not data is Dictionary:
		wait_status_label.text = "Relay 响应格式错误"
		return

	var relay_ip: String = data.get("relay_ip", "")
	var relay_port: int = data.get("relay_port", 0)

	if relay_ip.is_empty() or relay_port == 0:
		wait_status_label.text = "Relay 信息不完整"
		return

	if net_manager.is_host():
		net_manager.host_switch_to_relay(relay_ip, relay_port)
	else:
		net_manager.client_connect_relay(relay_ip, relay_port)


# ─────────────────────────────────────────────
# 房间等待面板
# ─────────────────────────────────────────────

func _enter_room_wait(room_data: Dictionary) -> void:
	_show_view(LobbyView.ROOM_WAIT)
	var room_name: String = room_data.get("name", "")
	room_code_label.text = "房间: %s (ID: %s)" % [room_name, net_manager.current_room_id]
	start_game_btn.visible = net_manager.is_host()
	start_game_btn.disabled = true
	wait_status_label.text = "等待其他玩家加入…"
	_refresh_wait_player_list()


func _refresh_wait_player_list() -> void:
	for child in wait_player_list_vbox.get_children():
		child.queue_free()

	for peer_id: int in net_manager.connected_players:
		var player_name: String = net_manager.connected_players[peer_id]
		var label := Label.new()
		var is_host_marker := " (Host)" if peer_id == 1 else ""
		var is_local_marker := " ← 你" if peer_id == net_manager.get_local_peer_id() else ""
		label.text = "%s%s%s" % [player_name, is_host_marker, is_local_marker]
		wait_player_list_vbox.add_child(label)

	# Host 需要至少 2 人才能开始
	if net_manager.is_host():
		start_game_btn.disabled = net_manager.connected_players.size() < 2


# ─────────────────────────────────────────────
# 网络事件回调
# ─────────────────────────────────────────────

func _on_net_player_joined(_peer_id: int, _player_name: String) -> void:
	if current_view == LobbyView.ROOM_WAIT:
		_refresh_wait_player_list()


func _on_net_player_left(_peer_id: int) -> void:
	if current_view == LobbyView.ROOM_WAIT:
		_refresh_wait_player_list()


func _on_net_connection_failed(reason: String) -> void:
	if current_view == LobbyView.ROOM_WAIT:
		wait_status_label.text = "连接失败: %s" % reason
	elif current_view == LobbyView.ROOM_BROWSER:
		browser_status_label.text = "连接失败: %s" % reason


func _on_net_state_changed(new_state: int) -> void:
	# ConnectionState enum values: CONNECTING_DIRECT=4, CONNECTING_RELAY=5,
	# CONNECTED_IN_LOBBY=6, LOADING_GAME=7
	match new_state:
		4:  # CONNECTING_DIRECT
			wait_status_label.text = "正在直连 Host…"
		5:  # CONNECTING_RELAY
			wait_status_label.text = "正在通过 Relay 连接…"
		6:  # CONNECTED_IN_LOBBY
			wait_status_label.text = "已连接，等待开始"
			_refresh_wait_player_list()
		7:  # LOADING_GAME
			_start_multiplayer_game()


func _on_relay_switch_requested() -> void:
	wait_status_label.text = "直连失败，正在请求 Relay…"
	_pending_http_action = "request_relay"

	var body := JSON.stringify({
		"player_name": net_manager.local_player_name,
	})

	var url := net_manager.lobby_server_url + "/rooms/%s/request_relay" % net_manager.current_room_id
	var headers := ["Content-Type: application/json"]
	var err := _http_request.request(url, headers, HTTPClient.METHOD_POST, body)
	if err != OK:
		wait_status_label.text = "请求 Relay 失败: %s" % error_string(err)


# ─────────────────────────────────────────────
# 游戏开始 / 返回
# ─────────────────────────────────────────────

func _on_start_game() -> void:
	if not net_manager.is_host():
		return
	net_manager.host_start_game()
	_start_multiplayer_game()


func _start_multiplayer_game() -> void:
	get_tree().change_scene_to_file(MULTIPLAYER_GAME_SCENE_PATH)


func _on_leave_room() -> void:
	net_manager.disconnect_from_game()
	_show_view(LobbyView.ROOM_BROWSER)
	browser_status_label.text = "已离开房间"


func _on_back_to_main_menu() -> void:
	net_manager.disconnect_from_game()
	get_tree().change_scene_to_file("res://scene/main_menu.tscn")
