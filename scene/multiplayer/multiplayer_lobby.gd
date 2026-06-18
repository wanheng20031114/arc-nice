extends Control

const _NetConstants := preload("res://scene/multiplayer/net_constants.gd")
const MULTIPLAYER_GAME_SCENE_PATH := "res://scene/multiplayer/mp_game.tscn"
const STATE_DISCONNECTED := 0
const STATE_HOSTING_LAN := 1
const STATE_CONNECTING_LAN := 2
const STATE_CONNECTED_IN_LOBBY := 3
const STATE_LOADING_GAME := 4

enum LobbyView {
	USERNAME_INPUT,
	LAN_DIRECT,
	ROOM_WAIT,
}

@onready var username_panel: PanelContainer = $LobbyCenter/UsernamePanel
@onready var username_input: LineEdit = $LobbyCenter/UsernamePanel/MarginContainer/VBoxContainer/UsernameInput
@onready var username_confirm_btn: Button = $LobbyCenter/UsernamePanel/MarginContainer/VBoxContainer/ConfirmUsernameButton
@onready var username_error_label: Label = $LobbyCenter/UsernamePanel/MarginContainer/VBoxContainer/UsernameErrorLabel
@onready var room_browser_panel: PanelContainer = $LobbyCenter/RoomBrowserPanel
@onready var room_wait_panel: PanelContainer = $LobbyCenter/RoomWaitPanel
@onready var room_code_label: Label = $LobbyCenter/RoomWaitPanel/MarginContainer/VBoxContainer/RoomCodeLabel
@onready var wait_player_list_vbox: VBoxContainer = $LobbyCenter/RoomWaitPanel/MarginContainer/VBoxContainer/PlayerListScroll/PlayerListVBox
@onready var start_game_btn: Button = $LobbyCenter/RoomWaitPanel/MarginContainer/VBoxContainer/StartGameButton
@onready var leave_room_btn: Button = $LobbyCenter/RoomWaitPanel/MarginContainer/VBoxContainer/LeaveButton
@onready var wait_status_label: Label = $LobbyCenter/RoomWaitPanel/MarginContainer/VBoxContainer/WaitStatusLabel
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


func _ready() -> void:
	_build_lan_direct_panel()
	username_input.max_length = _NetConstants.MAX_PLAYER_NAME_LENGTH
	username_confirm_btn.pressed.connect(_on_confirm_username)
	username_input.text_submitted.connect(_on_username_text_submitted)
	host_button.pressed.connect(_on_host_lan_pressed)
	join_button.pressed.connect(_on_join_lan_pressed)
	back_button.pressed.connect(_on_back_to_main_menu)
	start_game_btn.pressed.connect(_on_start_game)
	leave_room_btn.pressed.connect(_on_leave_room)

	net_manager.player_joined.connect(_on_net_player_list_changed.unbind(2))
	net_manager.player_left.connect(_on_net_player_list_changed.unbind(1))
	net_manager.player_list_changed.connect(_on_net_player_list_changed)
	net_manager.connection_failed.connect(_on_net_connection_failed)
	net_manager.connection_state_changed.connect(_on_net_state_changed)

	_show_view(LobbyView.USERNAME_INPUT)
	username_input.grab_focus()


func _build_lan_direct_panel() -> void:
	var browser_vbox := $LobbyCenter/RoomBrowserPanel/MarginContainer/VBoxContainer as VBoxContainer
	for child in browser_vbox.get_children():
		child.visible = false

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
	hint.text = "第一阶段使用局域网直连：一台设备创建主机，另一台输入主机 IP 加入。"
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
	room_browser_panel.visible = view == LobbyView.LAN_DIRECT
	room_wait_panel.visible = view == LobbyView.ROOM_WAIT
	if view == LobbyView.LAN_DIRECT:
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
	lan_status_label.text = "欢迎，%s。请选择创建主机或加入主机。" % raw_name
	_show_view(LobbyView.LAN_DIRECT)


func _on_username_text_submitted(_text: String) -> void:
	_on_confirm_username()


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

	var room_data := {
		"name": "局域网主机",
		"id": "%s:%d" % [host_ip, port],
	}
	_enter_room_wait(room_data)


func _enter_room_wait(room_data: Dictionary) -> void:
	_show_view(LobbyView.ROOM_WAIT)
	var room_name: String = str(room_data.get("name", "局域网房间"))
	var room_id: String = str(room_data.get("id", "LAN"))
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
		var is_host_marker := " (Host)" if peer_id == 1 else ""
		var is_local_marker: String = " <- 你" if peer_id == net_manager.get_local_peer_id() else ""
		label.text = "%s%s%s" % [player_name, is_host_marker, is_local_marker]
		wait_player_list_vbox.add_child(label)

	if net_manager.is_host():
		start_game_btn.disabled = net_manager.connected_players.size() < 2


func _on_net_player_list_changed() -> void:
	if current_view == LobbyView.ROOM_WAIT:
		_refresh_wait_player_list()


func _on_net_connection_failed(reason: String) -> void:
	if current_view == LobbyView.ROOM_WAIT:
		wait_status_label.text = "连接失败: %s" % reason
	else:
		lan_status_label.text = "连接失败: %s" % reason


func _on_net_state_changed(new_state: int) -> void:
	match new_state:
		STATE_CONNECTING_LAN:
			wait_status_label.text = "正在连接局域网主机..."
		STATE_HOSTING_LAN:
			wait_status_label.text = "局域网主机已创建，等待玩家加入。"
		STATE_CONNECTED_IN_LOBBY:
			wait_status_label.text = "已连接，等待开始。"
			_refresh_wait_player_list()
		STATE_LOADING_GAME:
			_start_multiplayer_game()
		STATE_DISCONNECTED:
			if current_view != LobbyView.USERNAME_INPUT:
				_show_view(LobbyView.LAN_DIRECT)
		_:
			pass


func _on_start_game() -> void:
	if not net_manager.is_host():
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
	net_manager.disconnect_from_game()
	_show_view(LobbyView.LAN_DIRECT)
	lan_status_label.text = "已离开房间。"


func _on_back_to_main_menu() -> void:
	net_manager.disconnect_from_game()
	get_tree().change_scene_to_file("res://scene/main_menu.tscn")
