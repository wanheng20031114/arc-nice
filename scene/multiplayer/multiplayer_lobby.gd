extends Control

const _NetConstants := preload("res://scene/multiplayer/net_constants.gd")
const MULTIPLAYER_GAME_SCENE_PATH := "res://scene/multiplayer/mp_game.tscn"
const PUBLIC_LOBBY_API_BASE_URL := "http://47.123.6.127:8000"
const STATE_DISCONNECTED := NetManagerStore.ConnectionState.DISCONNECTED
const STATE_HOSTING_LAN := NetManagerStore.ConnectionState.HOSTING_LAN
const STATE_CONNECTING_LAN := NetManagerStore.ConnectionState.CONNECTING_LAN
const STATE_CONNECTED_IN_LOBBY := NetManagerStore.ConnectionState.CONNECTED_IN_LOBBY
const STATE_LOADING_GAME := NetManagerStore.ConnectionState.LOADING_GAME

enum LobbyView {
	USERNAME_INPUT,
	MODE_SELECT,
	PUBLIC_BROWSER,
	LAN_DIRECT,
	ROOM_WAIT,
}

enum PublicRequest {
	NONE,
	HEALTH,
	LIST_ROOMS,
	CREATE_ROOM,
	JOIN_ROOM,
	QUICK_MATCH,
	HOST_READY,
	UPDATE_ROOM,
	LEAVE_ROOM,
	DESTROY_ROOM,
}

@onready var username_panel: PanelContainer = $LobbyCenter/UsernamePanel
@onready var username_input: LineEdit = $LobbyCenter/UsernamePanel/MarginContainer/VBoxContainer/UsernameInput
@onready var username_confirm_btn: Button = $LobbyCenter/UsernamePanel/MarginContainer/VBoxContainer/ConfirmUsernameButton
@onready var username_back_btn: Button = $LobbyCenter/UsernamePanel/MarginContainer/VBoxContainer/BackToMenuButton
@onready var username_error_label: Label = $LobbyCenter/UsernamePanel/MarginContainer/VBoxContainer/UsernameErrorLabel
@onready var mode_select_panel: PanelContainer = $LobbyCenter/ModeSelectPanel
@onready var public_mode_button: Button = $LobbyCenter/ModeSelectPanel/MarginContainer/VBoxContainer/PublicGameButton
@onready var lan_mode_button: Button = $LobbyCenter/ModeSelectPanel/MarginContainer/VBoxContainer/LanGameButton
@onready var mode_status_label: Label = $LobbyCenter/ModeSelectPanel/MarginContainer/VBoxContainer/ModeStatusLabel
@onready var mode_back_btn: Button = $LobbyCenter/ModeSelectPanel/MarginContainer/VBoxContainer/BackToMenuButton
@onready var room_browser_panel: PanelContainer = $LobbyCenter/RoomBrowserPanel
@onready var browser_title: Label = $LobbyCenter/RoomBrowserPanel/MarginContainer/VBoxContainer/BrowserTitle
@onready var tab_container: TabContainer = $LobbyCenter/RoomBrowserPanel/MarginContainer/VBoxContainer/TabContainer
@onready var room_list_vbox: VBoxContainer = $LobbyCenter/RoomBrowserPanel/MarginContainer/VBoxContainer/TabContainer/RoomListTab/ScrollContainer/RoomListVBox
@onready var refresh_button: Button = $LobbyCenter/RoomBrowserPanel/MarginContainer/VBoxContainer/TabContainer/RoomListTab/RefreshButton
@onready var room_name_input: LineEdit = $LobbyCenter/RoomBrowserPanel/MarginContainer/VBoxContainer/TabContainer/CreateRoomTab/RoomNameInput
@onready var max_players_spin: SpinBox = $LobbyCenter/RoomBrowserPanel/MarginContainer/VBoxContainer/TabContainer/CreateRoomTab/MaxPlayersSpinBox
@onready var create_room_button: Button = $LobbyCenter/RoomBrowserPanel/MarginContainer/VBoxContainer/TabContainer/CreateRoomTab/CreateRoomButton
@onready var quick_match_button: Button = $LobbyCenter/RoomBrowserPanel/MarginContainer/VBoxContainer/TabContainer/QuickMatchTab/QuickMatchButton
@onready var browser_status_label: Label = $LobbyCenter/RoomBrowserPanel/MarginContainer/VBoxContainer/BrowserStatusLabel
@onready var browser_back_button: Button = $LobbyCenter/RoomBrowserPanel/MarginContainer/VBoxContainer/BackButton
@onready var room_wait_panel: PanelContainer = $LobbyCenter/RoomWaitPanel
@onready var room_code_label: Label = $LobbyCenter/RoomWaitPanel/MarginContainer/VBoxContainer/RoomCodeLabel
@onready var wait_player_list_vbox: VBoxContainer = $LobbyCenter/RoomWaitPanel/MarginContainer/VBoxContainer/PlayerListScroll/PlayerListVBox
@onready var start_game_btn: Button = $LobbyCenter/RoomWaitPanel/MarginContainer/VBoxContainer/StartGameButton
@onready var leave_room_btn: Button = $LobbyCenter/RoomWaitPanel/MarginContainer/VBoxContainer/LeaveButton
@onready var wait_status_label: Label = $LobbyCenter/RoomWaitPanel/MarginContainer/VBoxContainer/WaitStatusLabel
@onready var public_lobby_request: HTTPRequest = $PublicLobbyRequest
@onready var net_manager: Node = get_node("/root/NetManager")

var current_view: LobbyView = LobbyView.USERNAME_INPUT
var lan_panel: VBoxContainer
var host_ip_label: Label
var join_ip_input: LineEdit
var port_spin: SpinBox
var lan_status_label: Label
var host_button: Button
var join_button: Button
var back_button: Button
var is_starting_game: bool = false
var pending_public_request: PublicRequest = PublicRequest.NONE
var current_public_room_id: String = ""
var current_public_host_token: String = ""
var current_public_room_name: String = ""
var current_public_is_host: bool = false
var relay_host_ready_sent: bool = false
var pending_start_after_public_status: bool = false
var keep_room_view_after_connection_failure: bool = false


func _ready() -> void:
	_build_lan_direct_panel()
	username_input.max_length = _NetConstants.MAX_PLAYER_NAME_LENGTH
	tab_container.set_tab_title(0, "房间列表")
	tab_container.set_tab_title(1, "创建房间")
	tab_container.set_tab_title(2, "快速匹配")
	username_confirm_btn.pressed.connect(_on_confirm_username)
	username_back_btn.pressed.connect(_on_back_to_main_menu)
	username_input.text_submitted.connect(_on_username_text_submitted)
	public_mode_button.pressed.connect(_on_public_mode_pressed)
	lan_mode_button.pressed.connect(_on_lan_mode_pressed)
	mode_back_btn.pressed.connect(_on_back_to_main_menu)
	host_button.pressed.connect(_on_host_lan_pressed)
	join_button.pressed.connect(_on_join_lan_pressed)
	back_button.pressed.connect(_on_back_to_main_menu)
	refresh_button.pressed.connect(_request_public_rooms)
	create_room_button.pressed.connect(_on_create_public_room_pressed)
	quick_match_button.pressed.connect(_on_quick_match_pressed)
	browser_back_button.pressed.connect(_on_back_to_mode_select)
	start_game_btn.pressed.connect(_on_start_game)
	leave_room_btn.pressed.connect(_on_leave_room)
	public_lobby_request.request_completed.connect(_on_public_lobby_request_completed)

	_connect_net_manager_signals()
	_show_view(LobbyView.USERNAME_INPUT)
	username_input.grab_focus()


func _exit_tree() -> void:
	_disconnect_net_manager_signals()


func _connect_net_manager_signals() -> void:
	var joined_callback := _on_net_player_list_changed.unbind(2)
	var left_callback := _on_net_player_list_changed.unbind(1)
	if not net_manager.player_joined.is_connected(joined_callback):
		net_manager.player_joined.connect(joined_callback)
	if not net_manager.player_left.is_connected(left_callback):
		net_manager.player_left.connect(left_callback)
	if not net_manager.player_list_changed.is_connected(_on_net_player_list_changed):
		net_manager.player_list_changed.connect(_on_net_player_list_changed)
	if not net_manager.connection_failed.is_connected(_on_net_connection_failed):
		net_manager.connection_failed.connect(_on_net_connection_failed)
	if not net_manager.connection_state_changed.is_connected(_on_net_state_changed):
		net_manager.connection_state_changed.connect(_on_net_state_changed)


func _disconnect_net_manager_signals() -> void:
	if net_manager == null:
		return
	var joined_callback := _on_net_player_list_changed.unbind(2)
	var left_callback := _on_net_player_list_changed.unbind(1)
	if net_manager.player_joined.is_connected(joined_callback):
		net_manager.player_joined.disconnect(joined_callback)
	if net_manager.player_left.is_connected(left_callback):
		net_manager.player_left.disconnect(left_callback)
	if net_manager.player_list_changed.is_connected(_on_net_player_list_changed):
		net_manager.player_list_changed.disconnect(_on_net_player_list_changed)
	if net_manager.connection_failed.is_connected(_on_net_connection_failed):
		net_manager.connection_failed.disconnect(_on_net_connection_failed)
	if net_manager.connection_state_changed.is_connected(_on_net_state_changed):
		net_manager.connection_state_changed.disconnect(_on_net_state_changed)


func _build_lan_direct_panel() -> void:
	var browser_vbox := $LobbyCenter/RoomBrowserPanel/MarginContainer/VBoxContainer as VBoxContainer
	lan_panel = VBoxContainer.new()
	lan_panel.name = "LanDirectPanel"
	lan_panel.add_theme_constant_override("separation", 12)
	browser_vbox.add_child(lan_panel)

	var title := Label.new()
	title.text = "局域网合作"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 26)
	lan_panel.add_child(title)

	var hint := Label.new()
	hint.text = "一台设备创建主机，另一台输入主机 IP 加入。"
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lan_panel.add_child(hint)

	host_ip_label = Label.new()
	host_ip_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	host_ip_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lan_panel.add_child(host_ip_label)

	port_spin = SpinBox.new()
	port_spin.min_value = 1024.0
	port_spin.max_value = 65535.0
	port_spin.value = _NetConstants.ENET_PORT_DEFAULT
	port_spin.step = 1.0
	port_spin.prefix = "端口 "
	lan_panel.add_child(port_spin)

	host_button = Button.new()
	host_button.text = "创建局域网主机"
	lan_panel.add_child(host_button)

	join_ip_input = LineEdit.new()
	join_ip_input.placeholder_text = "输入主机 IP，例如 192.168.1.23"
	join_ip_input.text = "127.0.0.1"
	lan_panel.add_child(join_ip_input)

	join_button = Button.new()
	join_button.text = "加入局域网主机"
	lan_panel.add_child(join_button)

	lan_status_label = Label.new()
	lan_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lan_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lan_panel.add_child(lan_status_label)

	back_button = Button.new()
	back_button.text = "返回主菜单"
	lan_panel.add_child(back_button)


func _show_view(view: LobbyView) -> void:
	current_view = view
	username_panel.visible = view == LobbyView.USERNAME_INPUT
	mode_select_panel.visible = view == LobbyView.MODE_SELECT
	room_browser_panel.visible = view == LobbyView.PUBLIC_BROWSER or view == LobbyView.LAN_DIRECT
	room_wait_panel.visible = view == LobbyView.ROOM_WAIT
	if view == LobbyView.PUBLIC_BROWSER:
		_apply_public_browser_state()
	elif view == LobbyView.LAN_DIRECT:
		_apply_lan_browser_state()
	elif view == LobbyView.MODE_SELECT:
		mode_status_label.text = "欢迎，%s。请选择联机方式。" % net_manager.local_player_name


func _apply_public_browser_state() -> void:
	browser_title.text = "公网游戏"
	tab_container.visible = true
	browser_status_label.visible = true
	browser_back_button.visible = true
	lan_panel.visible = false


func _apply_lan_browser_state() -> void:
	browser_title.text = "局域网游戏"
	tab_container.visible = false
	browser_status_label.visible = false
	browser_back_button.visible = false
	lan_panel.visible = true
	_refresh_lan_info()


func _on_confirm_username() -> void:
	var raw_name: String = username_input.text.strip_edges()
	if raw_name.length() < 1:
		username_error_label.text = "请输入用户名"
		username_error_label.visible = true
		return
	if raw_name.length() > _NetConstants.MAX_PLAYER_NAME_LENGTH:
		username_error_label.text = "用户名最多 %d 个字符" % _NetConstants.MAX_PLAYER_NAME_LENGTH
		username_error_label.visible = true
		return

	username_error_label.visible = false
	net_manager.local_player_name = raw_name
	_show_view(LobbyView.MODE_SELECT)


func _on_username_text_submitted(_text: String) -> void:
	_on_confirm_username()


func _on_public_mode_pressed() -> void:
	_show_view(LobbyView.PUBLIC_BROWSER)
	_request_public_health()


func _on_lan_mode_pressed() -> void:
	lan_status_label.text = "欢迎，%s。请选择创建主机或加入主机。" % net_manager.local_player_name
	_show_view(LobbyView.LAN_DIRECT)


func _on_back_to_mode_select() -> void:
	_show_view(LobbyView.MODE_SELECT)


func _refresh_lan_info() -> void:
	var ip_candidates: PackedStringArray = net_manager.get_lan_ip_candidates()
	if ip_candidates.is_empty():
		host_ip_label.text = "未找到局域网 IPv4 地址；可先用 127.0.0.1 做本机回环测试。"
	else:
		host_ip_label.text = "本机可用 IP：%s" % ", ".join(ip_candidates)


func _on_host_lan_pressed() -> void:
	var port: int = int(port_spin.value)
	var err: Error = net_manager.host_create_lan_server(port)
	if err != OK:
		lan_status_label.text = "创建主机失败: %s" % error_string(err)
		return

	_clear_public_room_state()
	var room_data := {
		"name": "%s 的局域网房间" % net_manager.local_player_name,
		"id": "LAN:%d" % port,
	}
	_enter_room_wait(room_data)


func _on_join_lan_pressed() -> void:
	var host_ip: String = join_ip_input.text.strip_edges()
	var port: int = int(port_spin.value)
	var err: Error = net_manager.client_connect_lan(host_ip, port)
	if err != OK:
		lan_status_label.text = "连接失败: %s" % error_string(err)
		return

	_clear_public_room_state()
	var room_data := {
		"name": "局域网主机",
		"id": "%s:%d" % [host_ip, port],
	}
	_enter_room_wait(room_data)


func _request_public_health() -> void:
	browser_status_label.text = "正在连接公网大厅..."
	_send_public_request(PublicRequest.HEALTH, "/health", HTTPClient.METHOD_GET)


func _request_public_rooms() -> void:
	if current_view != LobbyView.PUBLIC_BROWSER:
		return
	browser_status_label.text = "正在刷新房间列表..."
	_send_public_request(PublicRequest.LIST_ROOMS, "/rooms", HTTPClient.METHOD_GET)


func _on_create_public_room_pressed() -> void:
	var body := {
		"name": room_name_input.text.strip_edges(),
		"host_name": net_manager.local_player_name,
		"max_players": int(max_players_spin.value),
	}
	browser_status_label.text = "正在创建公网房间..."
	_send_public_request(PublicRequest.CREATE_ROOM, "/rooms", HTTPClient.METHOD_POST, body)


func _on_quick_match_pressed() -> void:
	var body := {"player_name": net_manager.local_player_name}
	browser_status_label.text = "正在快速匹配..."
	_send_public_request(PublicRequest.QUICK_MATCH, "/matchmaking/quick", HTTPClient.METHOD_POST, body)


func _on_public_room_selected(room_id: String) -> void:
	var body := {"player_name": net_manager.local_player_name}
	browser_status_label.text = "正在加入房间..."
	_send_public_request(PublicRequest.JOIN_ROOM, "/rooms/%s/join" % room_id, HTTPClient.METHOD_POST, body)


func _send_public_request(
	action: PublicRequest,
	path: String,
	method: HTTPClient.Method,
	body: Dictionary = {}
) -> void:
	if pending_public_request != PublicRequest.NONE:
		return
	pending_public_request = action
	var headers := PackedStringArray()
	var body_text := ""
	if method != HTTPClient.METHOD_GET:
		headers.append("Content-Type: application/json")
		body_text = JSON.stringify(body)
	var err := public_lobby_request.request(
		PUBLIC_LOBBY_API_BASE_URL + path,
		headers,
		method,
		body_text
	)
	if err != OK:
		pending_public_request = PublicRequest.NONE
		_cancel_public_request_side_effect(action)
		_show_public_error("请求公网大厅失败: %s" % error_string(err))


func _on_public_lobby_request_completed(
	result: int,
	response_code: int,
	_headers: PackedStringArray,
	body: PackedByteArray
) -> void:
	var action := pending_public_request
	pending_public_request = PublicRequest.NONE
	var body_text := body.get_string_from_utf8()
	if result != HTTPRequest.RESULT_SUCCESS or response_code < 200 or response_code >= 300:
		_cancel_public_request_side_effect(action)
		_show_public_error(_format_public_request_error(response_code, body_text))
		return

	var parsed: Variant = null
	if not body_text.is_empty():
		parsed = JSON.parse_string(body_text)

	match action:
		PublicRequest.HEALTH:
			browser_status_label.text = "公网大厅已连接。"
			_request_public_rooms()
		PublicRequest.LIST_ROOMS:
			_render_public_rooms(parsed as Array)
		PublicRequest.CREATE_ROOM:
			_begin_public_host_room(parsed as Dictionary)
		PublicRequest.JOIN_ROOM:
			_begin_public_client_room(parsed as Dictionary)
		PublicRequest.QUICK_MATCH:
			var data := parsed as Dictionary
			if data != null and data.has("host_token"):
				_begin_public_host_room(data)
			else:
				_begin_public_client_room(data)
		PublicRequest.HOST_READY:
			relay_host_ready_sent = true
			wait_status_label.text = "公网房间已创建，等待玩家加入。"
			_refresh_wait_player_list()
		PublicRequest.UPDATE_ROOM:
			if pending_start_after_public_status:
				pending_start_after_public_status = false
				net_manager.host_start_game()
				_start_multiplayer_game()
		PublicRequest.LEAVE_ROOM, PublicRequest.DESTROY_ROOM:
			_clear_public_room_state()
			if current_view != LobbyView.USERNAME_INPUT:
				_show_view(LobbyView.PUBLIC_BROWSER)
				_request_public_rooms()
		_:
			pass


func _format_public_request_error(response_code: int, body_text: String) -> String:
	var detail := body_text
	var parsed: Variant = null
	if not body_text.is_empty():
		parsed = JSON.parse_string(body_text)
	var parsed_dict := parsed as Dictionary
	if parsed_dict != null and parsed_dict.has("detail"):
		detail = str(parsed_dict["detail"])
	if response_code > 0:
		return "公网大厅请求失败 %d: %s" % [response_code, detail]
	return "公网大厅请求失败: %s" % detail


func _show_public_error(message: String) -> void:
	if current_view == LobbyView.ROOM_WAIT:
		wait_status_label.text = message
	else:
		browser_status_label.text = message


func _cancel_public_request_side_effect(action: PublicRequest) -> void:
	if action == PublicRequest.UPDATE_ROOM:
		pending_start_after_public_status = false


func _render_public_rooms(rooms: Array) -> void:
	for child in room_list_vbox.get_children():
		child.queue_free()
	if rooms == null or rooms.is_empty():
		var empty_label := Label.new()
		empty_label.text = "暂无可加入房间。"
		empty_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		room_list_vbox.add_child(empty_label)
		browser_status_label.text = "可以创建新房间。"
		return

	for room_variant in rooms:
		var room := room_variant as Dictionary
		if room == null:
			continue
		var room_id := _get_public_room_id(room)
		if room_id.is_empty():
			continue
		var button := Button.new()
		button.text = "%s  %d/%d  Host: %s" % [
			str(room.get("name", "房间")),
			int(room.get("player_count", 0)),
			int(room.get("max_players", 0)),
			str(room.get("host_name", "")),
		]
		button.pressed.connect(_on_public_room_selected.bind(room_id))
		room_list_vbox.add_child(button)
	browser_status_label.text = "房间列表已刷新。"


func _begin_public_host_room(data: Dictionary) -> void:
	if data == null:
		_show_public_error("创建公网房间失败：响应为空")
		return
	var relay_ip := str(data.get("relay_ip", ""))
	var relay_port := int(data.get("relay_port", 0))
	var room_id := _get_public_room_id(data)
	var host_token := str(data.get("host_token", ""))
	if relay_ip.is_empty() or relay_port <= 0 or room_id.is_empty() or host_token.is_empty():
		_show_public_error("创建公网房间失败：Relay 信息不完整")
		return

	current_public_room_id = room_id
	current_public_host_token = host_token
	current_public_room_name = str(data.get("name", "公网房间"))
	current_public_is_host = true
	relay_host_ready_sent = false

	var err: Error = net_manager.host_create_relay_room(relay_ip, relay_port)
	if err != OK:
		_show_public_error("连接 Relay 失败: %s" % error_string(err))
		return
	_enter_room_wait(data)
	wait_status_label.text = "正在连接公网 Relay..."


func _begin_public_client_room(data: Dictionary) -> void:
	if data == null:
		_show_public_error("加入公网房间失败：响应为空")
		return
	var relay_ip := str(data.get("relay_ip", ""))
	var relay_port := int(data.get("relay_port", 0))
	var host_peer_id := int(data.get("host_peer_id", 0))
	var room_id := _get_public_room_id(data)
	if relay_ip.is_empty() or relay_port <= 0 or host_peer_id <= 0 or room_id.is_empty():
		_show_public_error("加入公网房间失败：Relay 信息不完整")
		return

	current_public_room_id = room_id
	current_public_host_token = ""
	current_public_room_name = str(data.get("name", "公网房间"))
	current_public_is_host = false
	relay_host_ready_sent = false

	var err: Error = net_manager.client_join_relay_room(relay_ip, relay_port, host_peer_id)
	if err != OK:
		_show_public_error("连接 Relay 失败: %s" % error_string(err))
		return
	_enter_room_wait(data)
	wait_status_label.text = "正在连接公网 Relay..."


func _request_public_host_ready() -> void:
	if current_public_room_id.is_empty() or current_public_host_token.is_empty():
		return
	if relay_host_ready_sent or pending_public_request != PublicRequest.NONE:
		return
	var host_peer_id := int(net_manager.get_host_peer_id())
	if host_peer_id <= 0:
		return
	var body := {
		"host_token": current_public_host_token,
		"host_peer_id": host_peer_id,
	}
	_send_public_request(
		PublicRequest.HOST_READY,
		"/rooms/%s/host_ready" % current_public_room_id,
		HTTPClient.METHOD_POST,
		body
	)


func _request_public_room_status(status: String) -> void:
	if current_public_room_id.is_empty() or current_public_host_token.is_empty():
		return
	if pending_public_request != PublicRequest.NONE:
		return
	var body := {
		"host_token": current_public_host_token,
		"status": status,
	}
	_send_public_request(
		PublicRequest.UPDATE_ROOM,
		"/rooms/%s" % current_public_room_id,
		HTTPClient.METHOD_PATCH,
		body
	)


func _enter_room_wait(room_data: Dictionary) -> void:
	_show_view(LobbyView.ROOM_WAIT)
	var room_name: String = str(room_data.get("name", "房间"))
	var room_id: String = _get_public_room_id(room_data)
	room_code_label.text = "房间: %s (%s)" % [room_name, room_id]
	start_game_btn.visible = net_manager.is_host()
	wait_status_label.text = "等待玩家加入..."
	_refresh_wait_player_list()


func _refresh_wait_player_list() -> void:
	for child in wait_player_list_vbox.get_children():
		child.queue_free()

	for peer_id_variant in net_manager.connected_players:
		var peer_id: int = int(peer_id_variant)
		var player_name: String = str(net_manager.connected_players[peer_id])
		var label := Label.new()
		var is_host_marker := " (Host)" if peer_id == net_manager.get_host_peer_id() else ""
		var is_local_marker: String = " <- 你" if peer_id == net_manager.get_local_peer_id() else ""
		label.text = "%s%s%s" % [player_name, is_host_marker, is_local_marker]
		wait_player_list_vbox.add_child(label)

	if net_manager.is_host():
		start_game_btn.disabled = (
			net_manager.connected_players.size() < 2
			or (current_public_is_host and not relay_host_ready_sent)
		)


func _on_net_player_list_changed() -> void:
	if current_view == LobbyView.ROOM_WAIT:
		_refresh_wait_player_list()


func _on_net_connection_failed(reason: String) -> void:
	if current_view == LobbyView.ROOM_WAIT:
		keep_room_view_after_connection_failure = true
		wait_status_label.text = "连接失败: %s" % reason
	else:
		lan_status_label.text = "连接失败: %s" % reason


func _on_net_state_changed(new_state: NetManagerStore.ConnectionState) -> void:
	var is_relay := int(net_manager.get("conn_mode")) == 1
	match new_state:
		STATE_CONNECTING_LAN:
			if current_view == LobbyView.ROOM_WAIT:
				wait_status_label.text = "正在连接公网 Relay..." if is_relay else "正在连接局域网主机..."
		STATE_HOSTING_LAN:
			if is_relay:
				wait_status_label.text = "已连接 Relay，正在开放房间。"
				_request_public_host_ready()
			else:
				wait_status_label.text = "局域网主机已创建，等待玩家加入。"
			_refresh_wait_player_list()
		STATE_CONNECTED_IN_LOBBY:
			wait_status_label.text = "已连接，等待开始。"
			_refresh_wait_player_list()
		STATE_LOADING_GAME:
			_start_multiplayer_game()
		STATE_DISCONNECTED:
			if keep_room_view_after_connection_failure:
				keep_room_view_after_connection_failure = false
				_refresh_wait_player_list()
				return
			if current_view != LobbyView.USERNAME_INPUT and not is_starting_game:
				_show_view(LobbyView.MODE_SELECT)
		_:
			pass


func _on_start_game() -> void:
	if not net_manager.is_host():
		return
	if current_public_is_host and not current_public_room_id.is_empty():
		pending_start_after_public_status = true
		wait_status_label.text = "正在通知公网大厅开始游戏..."
		_request_public_room_status("in_game")
		if pending_public_request == PublicRequest.NONE:
			pending_start_after_public_status = false
		return
	net_manager.host_start_game()
	_start_multiplayer_game()


func _start_multiplayer_game() -> void:
	if is_starting_game:
		return
	is_starting_game = true
	call_deferred("_change_to_multiplayer_game")


func _change_to_multiplayer_game() -> void:
	var tree := get_tree()
	if tree == null:
		return
	tree.change_scene_to_file(MULTIPLAYER_GAME_SCENE_PATH)


func _on_leave_room() -> void:
	var was_public := not current_public_room_id.is_empty()
	var room_id := current_public_room_id
	var host_token := current_public_host_token
	var player_name: String = str(net_manager.local_player_name)
	var was_host := current_public_is_host
	net_manager.disconnect_from_game()
	if was_public and not room_id.is_empty():
		if was_host and not host_token.is_empty():
			_send_public_request(
				PublicRequest.DESTROY_ROOM,
				"/rooms/%s" % room_id,
				HTTPClient.METHOD_DELETE,
				{"host_token": host_token}
			)
		else:
			_send_public_request(
				PublicRequest.LEAVE_ROOM,
				"/rooms/%s/leave" % room_id,
				HTTPClient.METHOD_POST,
				{"player_name": player_name}
			)
	_clear_public_room_state()
	if was_public:
		_show_view(LobbyView.PUBLIC_BROWSER)
	else:
		_show_view(LobbyView.LAN_DIRECT)
		lan_status_label.text = "已离开房间。"


func _on_back_to_main_menu() -> void:
	net_manager.disconnect_from_game()
	get_tree().change_scene_to_file("res://scene/main_menu.tscn")


func _clear_public_room_state() -> void:
	current_public_room_id = ""
	current_public_host_token = ""
	current_public_room_name = ""
	current_public_is_host = false
	relay_host_ready_sent = false
	pending_start_after_public_status = false
	keep_room_view_after_connection_failure = false


func _get_public_room_id(room_data: Dictionary) -> String:
	var room_id := str(room_data.get("room_id", ""))
	if room_id.is_empty():
		room_id = str(room_data.get("id", ""))
	return room_id
