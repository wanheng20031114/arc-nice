extends Control

const _NetConstants := preload("res://scene/multiplayer/net_constants.gd")
const USERNAME_CARET_SIZE := Vector2(2.0, 34.0)
const USERNAME_CARET_BLINK_INTERVAL := 0.48
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
	CONFIRM_ACQUISITION,
	HOST_READY,
	UPDATE_ROOM,
	ACQUISITION_PREFLIGHT,
}

@onready var username_panel: PanelContainer = $LobbyCenter/UsernamePanel
@onready var username_input: LineEdit = $LobbyCenter/UsernamePanel/MarginContainer/VBoxContainer/NameCard/CardVBox/InputSurface/InputLayer/UsernameInput
@onready var username_name_display: HBoxContainer = $LobbyCenter/UsernamePanel/MarginContainer/VBoxContainer/NameCard/CardVBox/InputSurface/InputLayer/BouncyNameDisplay
@onready var username_caret: ColorRect = $LobbyCenter/UsernamePanel/MarginContainer/VBoxContainer/NameCard/CardVBox/InputSurface/InputLayer/UsernameCaret
@onready var username_type_audio: AudioStreamPlayer = $LobbyCenter/UsernamePanel/TypingBlipAudio
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
@onready var browser_body_scroll: ScrollContainer = $LobbyCenter/RoomBrowserPanel/MarginContainer/VBoxContainer/BrowserBodyScroll
@onready var room_settings_card: PanelContainer = $LobbyCenter/RoomBrowserPanel/MarginContainer/VBoxContainer/BrowserBodyScroll/BrowserBodyVBox/RoomSettingsCard
@onready var room_settings_hint: Label = $LobbyCenter/RoomBrowserPanel/MarginContainer/VBoxContainer/BrowserBodyScroll/BrowserBodyVBox/RoomSettingsCard/SettingsMargin/SettingsVBox/SettingsHint
@onready var game_mode_selector: OptionButton = $LobbyCenter/RoomBrowserPanel/MarginContainer/VBoxContainer/BrowserBodyScroll/BrowserBodyVBox/RoomSettingsCard/SettingsMargin/SettingsVBox/GameModeRow/GameModeSelector
@onready var max_players_spin: SpinBox = $LobbyCenter/RoomBrowserPanel/MarginContainer/VBoxContainer/BrowserBodyScroll/BrowserBodyVBox/RoomSettingsCard/SettingsMargin/SettingsVBox/PlayerCountRow/MaxPlayersSpinBox
@onready var tab_container: TabContainer = $LobbyCenter/RoomBrowserPanel/MarginContainer/VBoxContainer/BrowserBodyScroll/BrowserBodyVBox/TabContainer
@onready var room_list_vbox: VBoxContainer = $LobbyCenter/RoomBrowserPanel/MarginContainer/VBoxContainer/BrowserBodyScroll/BrowserBodyVBox/TabContainer/RoomListTab/ScrollContainer/RoomListVBox
@onready var refresh_button: Button = $LobbyCenter/RoomBrowserPanel/MarginContainer/VBoxContainer/BrowserBodyScroll/BrowserBodyVBox/TabContainer/RoomListTab/RefreshButton
@onready var room_name_input: LineEdit = $LobbyCenter/RoomBrowserPanel/MarginContainer/VBoxContainer/BrowserBodyScroll/BrowserBodyVBox/TabContainer/CreateRoomTab/RoomNameInput
@onready var create_room_button: Button = $LobbyCenter/RoomBrowserPanel/MarginContainer/VBoxContainer/BrowserBodyScroll/BrowserBodyVBox/TabContainer/CreateRoomTab/CreateRoomButton
@onready var quick_match_button: Button = $LobbyCenter/RoomBrowserPanel/MarginContainer/VBoxContainer/BrowserBodyScroll/BrowserBodyVBox/TabContainer/QuickMatchTab/QuickMatchButton
@onready var browser_status_label: Label = $LobbyCenter/RoomBrowserPanel/MarginContainer/VBoxContainer/BrowserStatusLabel
@onready var browser_back_button: Button = $LobbyCenter/RoomBrowserPanel/MarginContainer/VBoxContainer/BackButton
@onready var lan_panel: VBoxContainer = $LobbyCenter/RoomBrowserPanel/MarginContainer/VBoxContainer/BrowserBodyScroll/BrowserBodyVBox/LanDirectPanel
@onready var host_ip_label: Label = $LobbyCenter/RoomBrowserPanel/MarginContainer/VBoxContainer/BrowserBodyScroll/BrowserBodyVBox/LanDirectPanel/HostIpLabel
@onready var join_ip_input: LineEdit = $LobbyCenter/RoomBrowserPanel/MarginContainer/VBoxContainer/BrowserBodyScroll/BrowserBodyVBox/LanDirectPanel/JoinIpInput
@onready var port_spin: SpinBox = $LobbyCenter/RoomBrowserPanel/MarginContainer/VBoxContainer/BrowserBodyScroll/BrowserBodyVBox/LanDirectPanel/PortRow/PortSpinBox
@onready var lan_status_label: Label = $LobbyCenter/RoomBrowserPanel/MarginContainer/VBoxContainer/LanStatusLabel
@onready var host_button: Button = $LobbyCenter/RoomBrowserPanel/MarginContainer/VBoxContainer/BrowserBodyScroll/BrowserBodyVBox/LanDirectPanel/HostButton
@onready var join_button: Button = $LobbyCenter/RoomBrowserPanel/MarginContainer/VBoxContainer/BrowserBodyScroll/BrowserBodyVBox/LanDirectPanel/JoinButton
@onready var back_button: Button = $LobbyCenter/RoomBrowserPanel/MarginContainer/VBoxContainer/LanBackButton
@onready var room_wait_panel: PanelContainer = $LobbyCenter/RoomWaitPanel
@onready var room_code_label: Label = $LobbyCenter/RoomWaitPanel/MarginContainer/VBoxContainer/RoomCodeLabel
@onready var room_mode_label: Label = $LobbyCenter/RoomWaitPanel/MarginContainer/VBoxContainer/RoomModeLabel
@onready var room_capacity_label: Label = $LobbyCenter/RoomWaitPanel/MarginContainer/VBoxContainer/RoomCapacityLabel
@onready var wait_player_list_vbox: VBoxContainer = $LobbyCenter/RoomWaitPanel/MarginContainer/VBoxContainer/PlayerListScroll/PlayerListVBox
@onready var choose_character_btn: Button = $LobbyCenter/RoomWaitPanel/MarginContainer/VBoxContainer/ChooseCharacterButton
@onready var start_game_btn: Button = $LobbyCenter/RoomWaitPanel/MarginContainer/VBoxContainer/StartGameButton
@onready var leave_room_btn: Button = $LobbyCenter/RoomWaitPanel/MarginContainer/VBoxContainer/LeaveButton
@onready var wait_status_label: Label = $LobbyCenter/RoomWaitPanel/MarginContainer/VBoxContainer/WaitStatusLabel
@onready var public_lobby_request: HTTPRequest = $PublicLobbyRequest
@onready var character_choice_overlay: PlayerCharacterChoiceOverlay = $PlayerCharacterChoiceOverlay
@onready var net_manager: NetManagerStore = NetManagerStore.get_autoload_instance()
@onready var public_room_lease: PublicRoomLeaseStore = (
	PublicRoomLeaseStore.get_autoload_instance()
)
@onready var run_state: RunStateStore = get_node_or_null("/root/RunState") as RunStateStore

var current_view: LobbyView = LobbyView.USERNAME_INPUT
var is_starting_game: bool = false
var pending_public_request: PublicRequest = PublicRequest.NONE
var _pending_public_request_lease_generation := 0
var _pending_public_request_acquisition_token := ""
var _pending_public_acquisition_command: Dictionary = {}
var _pending_public_room_after_confirm: Dictionary = {}
var _public_request_in_flight := false
var _public_request_channel_quarantined := false
var _public_request_channel_quarantine_generation := 0
var _queued_public_request: Dictionary = {}
var relay_host_ready_sent: bool = false
var pending_start_after_public_status: bool = false
var keep_room_view_after_connection_failure: bool = false
var public_release_in_progress := false
var current_room_max_players: int = _NetConstants.DEFAULT_ROOM_MAX_PLAYERS
var _username_panel_intro_tween: Tween
var _username_panel_intro_target_position := Vector2.ZERO
var _username_panel_intro_active := false
var _username_caret_blink_elapsed := 0.0
var _game_mode_icon_cache: Dictionary = {}


func _ready() -> void:
	assert(public_room_lease != null, "MultiplayerLobby 缺少 PublicRoomLease 自动加载实例。")
	_sync_local_character_selection()
	_configure_game_mode_selector()
	max_players_spin.min_value = _NetConstants.MIN_ROOM_PLAYERS
	max_players_spin.max_value = _NetConstants.MAX_PLAYERS
	max_players_spin.value = _NetConstants.DEFAULT_ROOM_MAX_PLAYERS
	port_spin.value = _NetConstants.ENET_PORT_DEFAULT
	username_input.max_length = _NetConstants.MAX_PLAYER_NAME_LENGTH
	username_name_display.set("max_length", _NetConstants.MAX_PLAYER_NAME_LENGTH)
	username_name_display.set("input_audio", username_type_audio)
	_update_username_display(username_input.text, false)
	tab_container.set_tab_title(0, "房间列表")
	tab_container.set_tab_title(1, "创建房间")
	tab_container.set_tab_title(2, "快速匹配")
	username_confirm_btn.pressed.connect(_on_confirm_username)
	username_back_btn.pressed.connect(_on_back_to_main_menu)
	username_input.text_changed.connect(_on_username_text_changed)
	username_input.text_submitted.connect(_on_username_text_submitted)
	username_input.focus_entered.connect(_on_username_input_focus_changed)
	username_input.focus_exited.connect(_on_username_input_focus_changed)
	public_mode_button.pressed.connect(_on_public_mode_pressed)
	lan_mode_button.pressed.connect(_on_lan_mode_pressed)
	mode_back_btn.pressed.connect(_on_back_to_main_menu)
	host_button.pressed.connect(_on_host_lan_pressed)
	join_button.pressed.connect(_on_join_lan_pressed)
	back_button.pressed.connect(_on_back_to_mode_select)
	refresh_button.pressed.connect(_request_public_rooms)
	create_room_button.pressed.connect(_on_create_public_room_pressed)
	quick_match_button.pressed.connect(_on_quick_match_pressed)
	browser_back_button.pressed.connect(_on_back_to_mode_select)
	choose_character_btn.pressed.connect(_on_choose_character_pressed)
	start_game_btn.pressed.connect(_on_start_game)
	leave_room_btn.pressed.connect(_on_leave_room)
	character_choice_overlay.character_confirmed.connect(_on_character_confirmed)
	character_choice_overlay.selection_closed.connect(_on_character_selection_closed)
	public_lobby_request.request_completed.connect(_on_public_lobby_request_completed)
	game_mode_selector.item_selected.connect(_on_game_mode_selected)

	_connect_net_manager_signals()
	_show_view(LobbyView.USERNAME_INPUT)
	username_input.grab_focus()
	call_deferred("_refresh_username_caret")


func _exit_tree() -> void:
	_disconnect_net_manager_signals()


func _process(delta: float) -> void:
	_update_username_caret_blink(delta)


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
	if not net_manager.game_mode_changed.is_connected(_on_net_game_mode_changed):
		net_manager.game_mode_changed.connect(_on_net_game_mode_changed)
	if not net_manager.room_capacity_changed.is_connected(_on_net_room_capacity_changed):
		net_manager.room_capacity_changed.connect(_on_net_room_capacity_changed)


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
	if net_manager.game_mode_changed.is_connected(_on_net_game_mode_changed):
		net_manager.game_mode_changed.disconnect(_on_net_game_mode_changed)
	if net_manager.room_capacity_changed.is_connected(_on_net_room_capacity_changed):
		net_manager.room_capacity_changed.disconnect(_on_net_room_capacity_changed)


func _configure_game_mode_selector() -> void:
	game_mode_selector.clear()
	# 大厅只消费正式发布视图；开发 fixture 不因存在目录定义而自动曝光。
	for definition in GameModeCatalog.get_release_lobby_definitions():
		game_mode_selector.add_icon_item(
			_load_game_mode_icon(definition),
			definition.lobby_label,
			definition.mode_id
		)
	_select_game_mode_in_selector(
		net_manager.get_current_game_mode() as NetManagerStore.GameMode
	)


func _on_game_mode_selected(item_index: int) -> void:
	if item_index < 0 or item_index >= game_mode_selector.item_count:
		return
	var game_mode := game_mode_selector.get_item_id(item_index) as NetManagerStore.GameMode
	if net_manager.set_host_game_mode(game_mode):
		return
	_select_game_mode_in_selector(
		net_manager.get_current_game_mode() as NetManagerStore.GameMode
	)


func _get_selected_game_mode() -> NetManagerStore.GameMode:
	var item_index := game_mode_selector.selected
	if item_index < 0 or item_index >= game_mode_selector.item_count:
		return NetManagerStore.GameMode.STANDARD
	var item_id := game_mode_selector.get_item_id(item_index)
	if GameModeCatalog.is_release_selectable(item_id):
		return item_id as NetManagerStore.GameMode
	return NetManagerStore.GameMode.STANDARD


func _get_selected_game_mode_key() -> String:
	return NetManagerStore.game_mode_to_key(_get_selected_game_mode())


func _select_game_mode_in_selector(game_mode: NetManagerStore.GameMode) -> void:
	for item_index in range(game_mode_selector.item_count):
		if game_mode_selector.get_item_id(item_index) == int(game_mode):
			game_mode_selector.select(item_index)
			return


func _prepare_selected_host_game_mode() -> bool:
	var selected_game_mode := _get_selected_game_mode()
	if net_manager.set_host_game_mode(selected_game_mode):
		return true
	_show_public_error("当前连接状态不能更改游戏模式。")
	return false


func _get_room_game_mode_key(room_data: Dictionary) -> String:
	var default_definition := GameModeCatalog.get_definition(
		GameModeCatalog.DEFAULT_MODE_ID
	)
	var default_key := (
		String(default_definition.wire_key)
		if default_definition != null
		else ""
	)
	var game_mode_key := str(
		room_data.get("game_mode", default_key)
	).strip_edges().to_lower()
	var definition := GameModeCatalog.get_definition_by_wire_key(game_mode_key)
	return (
		String(definition.wire_key)
		if (
			definition != null
			and GameModeCatalog.is_release_selectable(definition.mode_id)
		)
		else ""
	)


func _apply_room_game_mode(room_data: Dictionary, as_host: bool) -> bool:
	var game_mode_key := _get_room_game_mode_key(room_data)
	if game_mode_key.is_empty():
		_show_public_error("房间返回了无效的游戏模式。")
		return false
	var game_mode := NetManagerStore.game_mode_from_key(game_mode_key)
	var applied := false
	if as_host:
		applied = bool(net_manager.set_host_game_mode(game_mode))
	else:
		applied = bool(net_manager.set_pending_game_mode(game_mode))
	if not applied:
		_show_public_error("当前连接状态不能应用房间游戏模式。")
		return false
	_select_game_mode_in_selector(game_mode)
	_update_room_mode_label()
	return true


func _update_room_mode_label() -> void:
	if room_mode_label == null:
		return
	var game_mode := net_manager.get_current_game_mode() as NetManagerStore.GameMode
	room_mode_label.text = "模式: %s" % NetManagerStore.get_game_mode_display_name(game_mode)


func _refresh_game_mode_selector_state() -> void:
	var is_room_active: bool = bool(net_manager.is_multiplayer_active())
	game_mode_selector.disabled = is_room_active
	max_players_spin.editable = not is_room_active


func _show_view(view: LobbyView) -> void:
	current_view = view
	username_panel.visible = view == LobbyView.USERNAME_INPUT
	mode_select_panel.visible = view == LobbyView.MODE_SELECT
	room_browser_panel.visible = view == LobbyView.PUBLIC_BROWSER or view == LobbyView.LAN_DIRECT
	room_wait_panel.visible = view == LobbyView.ROOM_WAIT
	if room_browser_panel.visible:
		browser_body_scroll.set_deferred("scroll_vertical", 0)
	_refresh_game_mode_selector_state()
	if view != LobbyView.USERNAME_INPUT:
		username_caret.visible = false
	if view == LobbyView.PUBLIC_BROWSER:
		_apply_public_browser_state()
	elif view == LobbyView.LAN_DIRECT:
		_apply_lan_browser_state()
	elif view == LobbyView.MODE_SELECT:
		mode_status_label.text = "欢迎，%s。请选择联机方式。" % net_manager.local_player_name
	elif view == LobbyView.USERNAME_INPUT:
		call_deferred("_animate_username_panel_intro")
		call_deferred("_refresh_username_caret")


func _update_username_display(new_text: String, play_sound: bool) -> void:
	username_name_display.call("update_text", new_text, play_sound)
	_reset_username_caret_blink()
	call_deferred("_refresh_username_caret")


func _on_username_input_focus_changed() -> void:
	_reset_username_caret_blink()
	call_deferred("_refresh_username_caret")


func _refresh_username_caret() -> void:
	_position_username_caret()
	_update_username_caret_blink(0.0)


func _is_username_caret_active() -> bool:
	return (
		current_view == LobbyView.USERNAME_INPUT
		and username_panel.visible
		and username_input.has_focus()
	)


func _reset_username_caret_blink() -> void:
	_username_caret_blink_elapsed = 0.0
	if _is_username_caret_active():
		username_caret.visible = true


func _update_username_caret_blink(delta: float) -> void:
	if not _is_username_caret_active():
		username_caret.visible = false
		return

	_position_username_caret()
	_username_caret_blink_elapsed = fmod(
		_username_caret_blink_elapsed + delta,
		USERNAME_CARET_BLINK_INTERVAL * 2.0
	)
	username_caret.visible = _username_caret_blink_elapsed < USERNAME_CARET_BLINK_INTERVAL


func _position_username_caret() -> void:
	var display_text := str(username_name_display.call("get_displayed_text"))
	var visible_letter_count := mini(display_text.length(), username_name_display.get_child_count())
	var display_rect := username_name_display.get_rect()
	var caret_x := display_rect.position.x + display_rect.size.x * 0.5
	if visible_letter_count > 0:
		var last_letter := username_name_display.get_child(visible_letter_count - 1) as Control
		if last_letter != null:
			var separation := float(username_name_display.get_theme_constant(&"separation"))
			caret_x = display_rect.position.x + last_letter.position.x + last_letter.size.x + maxf(separation, 0.0) * 0.5

	username_caret.size = USERNAME_CARET_SIZE
	username_caret.position = Vector2(
		clampf(
			caret_x,
			display_rect.position.x,
			display_rect.end.x - USERNAME_CARET_SIZE.x
		),
		display_rect.position.y + (display_rect.size.y - USERNAME_CARET_SIZE.y) * 0.5 + 1.0
	)


func _animate_username_panel_intro() -> void:
	if not username_panel.visible:
		return
	if _username_panel_intro_tween != null:
		_username_panel_intro_tween.kill()
	if _username_panel_intro_active:
		username_panel.position = _username_panel_intro_target_position
	_username_panel_intro_target_position = username_panel.position.round()
	_username_panel_intro_active = true
	username_panel.scale = Vector2.ONE
	username_panel.modulate.a = 0.0
	_apply_username_panel_intro_offset(8.0)
	_username_panel_intro_tween = create_tween()
	_username_panel_intro_tween.tween_property(username_panel, "modulate:a", 1.0, 0.16)
	_username_panel_intro_tween.parallel().tween_method(
		_apply_username_panel_intro_offset,
		8.0,
		0.0,
		0.2
	).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	_username_panel_intro_tween.finished.connect(_finish_username_panel_intro)


func _apply_username_panel_intro_offset(offset_y: float) -> void:
	username_panel.position = _username_panel_intro_target_position + Vector2(0.0, roundf(offset_y))


func _finish_username_panel_intro() -> void:
	username_panel.position = _username_panel_intro_target_position
	username_panel.modulate.a = 1.0
	username_panel.scale = Vector2.ONE
	_username_panel_intro_active = false


func _apply_public_browser_state() -> void:
	browser_title.text = "公网游戏"
	room_settings_hint.text = "以下选项用于创建房间；快速匹配仅使用所选模式。"
	tab_container.visible = true
	browser_status_label.visible = true
	browser_back_button.visible = true
	lan_panel.visible = false
	lan_status_label.visible = false
	back_button.visible = false


func _apply_lan_browser_state() -> void:
	browser_title.text = "局域网游戏"
	room_settings_hint.text = "以下选项由房主在创建局域网房间前确定。"
	tab_container.visible = false
	browser_status_label.visible = false
	browser_back_button.visible = false
	lan_panel.visible = true
	lan_status_label.visible = true
	back_button.visible = true
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


func _on_username_text_changed(new_text: String) -> void:
	username_error_label.visible = false
	_update_username_display(new_text, true)


func _on_username_text_submitted(_text: String) -> void:
	_on_confirm_username()


func _on_public_mode_pressed() -> void:
	_show_view(LobbyView.PUBLIC_BROWSER)
	_request_public_health()


func _on_lan_mode_pressed() -> void:
	lan_status_label.text = "欢迎，%s。请选择创建主机或加入主机。" % net_manager.local_player_name
	_show_view(LobbyView.LAN_DIRECT)


func _on_back_to_mode_select() -> void:
	if public_release_in_progress:
		return
	if public_room_lease.has_active_lease():
		public_release_in_progress = true
		_cancel_pending_public_command_for_release()
		await public_room_lease.release_current_and_wait(
			&"lobby_back_to_mode_select"
		)
		if not is_inside_tree():
			return
		public_release_in_progress = false
	elif pending_public_request != PublicRequest.NONE:
		_cancel_pending_public_command_for_release()
	_show_view(LobbyView.MODE_SELECT)


func _refresh_lan_info() -> void:
	var ip_candidates: PackedStringArray = net_manager.get_lan_ip_candidates()
	if ip_candidates.is_empty():
		host_ip_label.text = "未找到局域网 IPv4 地址；可先用 127.0.0.1 做本机回环测试。"
	else:
		host_ip_label.text = "本机可用 IP：%s" % ", ".join(ip_candidates)


func _on_host_lan_pressed() -> void:
	if not _prepare_selected_host_game_mode():
		lan_status_label.text = "当前连接状态不能更改游戏模式。"
		return
	var port: int = int(port_spin.value)
	var max_players := int(max_players_spin.value)
	var err: Error = net_manager.host_create_lan_server(port, max_players)
	if err != OK:
		lan_status_label.text = "创建主机失败: %s" % error_string(err)
		return

	_clear_public_room_state()
	var room_data := {
		"name": "%s 的局域网房间" % net_manager.local_player_name,
		"id": "LAN:%d" % port,
		"game_mode": _get_selected_game_mode_key(),
		"max_players": max_players,
	}
	_enter_room_wait(room_data)


func _on_join_lan_pressed() -> void:
	var host_ip: String = join_ip_input.text.strip_edges()
	var port: int = int(port_spin.value)
	if not net_manager.set_pending_game_mode(NetManagerStore.GameMode.STANDARD):
		lan_status_label.text = "当前连接状态不能加入主机。"
		return
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
	room_mode_label.text = "模式: 等待主机同步…"
	room_capacity_label.text = "游玩人数：等待主机同步…"


func _request_public_health() -> void:
	browser_status_label.text = "正在连接公网大厅..."
	_send_public_request(PublicRequest.HEALTH, "/health", HTTPClient.METHOD_GET)


func _request_public_rooms() -> void:
	if (
		current_view != LobbyView.PUBLIC_BROWSER
		or public_release_in_progress
		or public_room_lease.has_active_lease()
	):
		return
	browser_status_label.text = "正在刷新房间列表..."
	_send_public_request(PublicRequest.LIST_ROOMS, "/rooms", HTTPClient.METHOD_GET)


func _on_create_public_room_pressed() -> void:
	if not _can_begin_public_membership():
		return
	if not _prepare_selected_host_game_mode():
		return
	var body := {
		"name": room_name_input.text.strip_edges(),
		"host_name": str(net_manager.local_player_name).strip_edges(),
		"max_players": int(max_players_spin.value),
		"game_mode": _get_selected_game_mode_key(),
	}
	if not _begin_public_acquisition_request(
		&"create",
		PublicRequest.CREATE_ROOM,
		"/rooms",
		body,
		body
	):
		_show_public_error("无法建立创建房间的临时身份，请稍后重试。")
		return
	browser_status_label.text = "正在创建公网房间..."


func _on_quick_match_pressed() -> void:
	if not _can_begin_public_membership():
		return
	if not _prepare_selected_host_game_mode():
		return
	var body := {
		"player_name": str(net_manager.local_player_name).strip_edges(),
		"game_mode": _get_selected_game_mode_key(),
	}
	if not _begin_public_acquisition_request(
		&"quick_match",
		PublicRequest.QUICK_MATCH,
		"/matchmaking/quick",
		body,
		body
	):
		_show_public_error("无法建立快速匹配的临时身份，请稍后重试。")
		return
	browser_status_label.text = "正在快速匹配..."


func _on_public_room_selected(room_id: String, game_mode_key: String) -> void:
	if not _can_begin_public_membership():
		return
	var definition := GameModeCatalog.get_definition_by_wire_key(game_mode_key)
	if (
		definition == null
		or not GameModeCatalog.is_release_selectable(definition.mode_id)
	):
		_show_public_error("房间返回了无效的游戏模式。")
		return
	var game_mode := definition.mode_id as NetManagerStore.GameMode
	if not net_manager.set_pending_game_mode(game_mode):
		_show_public_error("当前连接状态不能加入房间。")
		return
	_select_game_mode_in_selector(game_mode)
	var body := {
		"player_name": str(net_manager.local_player_name).strip_edges(),
		"game_mode": game_mode_key,
	}
	var preflight_payload := body.duplicate(true)
	preflight_payload["room_id"] = room_id
	if not _begin_public_acquisition_request(
		&"join",
		PublicRequest.JOIN_ROOM,
		"/rooms/%s/join" % room_id,
		body,
		preflight_payload
	):
		_show_public_error("无法建立加入房间的临时身份，请稍后重试。")
		return
	browser_status_label.text = "正在加入房间..."


func _begin_public_acquisition_request(
	action_name: StringName,
	request_action: PublicRequest,
	path: String,
	actual_body: Dictionary,
	preflight_payload: Dictionary
) -> bool:
	var lease_generation := public_room_lease.begin_acquisition(
		str(net_manager.local_player_name),
		action_name
	)
	if lease_generation <= 0:
		return false
	_pending_public_acquisition_command = {
		"lease_generation": lease_generation,
		"action_name": action_name,
		"request_action": request_action,
		"path": path,
		"body": actual_body.duplicate(true),
	}
	_send_public_request(
		PublicRequest.ACQUISITION_PREFLIGHT,
		"/acquisitions/preflight",
		HTTPClient.METHOD_POST,
		{
			"action": str(action_name),
			"payload": preflight_payload.duplicate(true),
		}
	)
	return true


func _can_begin_public_membership() -> bool:
	if (
		not public_release_in_progress
		and pending_public_request == PublicRequest.NONE
		and not public_room_lease.has_active_lease()
		and not net_manager.is_multiplayer_active()
	):
		return true
	browser_status_label.text = "上一房间会话或身份仍在释放，请稍候。"
	return false


func _send_public_request(
	action: PublicRequest,
	path: String,
	method: HTTPClient.Method,
	body: Dictionary = {}
) -> void:
	if pending_public_request != PublicRequest.NONE:
		return
	pending_public_request = action
	_pending_public_request_lease_generation = (
		public_room_lease.get_lease_generation()
		if public_room_lease.has_active_lease()
		else 0
	)
	_pending_public_request_acquisition_token = (
		public_room_lease.get_acquisition_token()
		if public_room_lease.has_active_lease()
		else ""
	)
	var headers := PackedStringArray()
	var body_text := ""
	if method != HTTPClient.METHOD_GET:
		headers.append("Content-Type: application/json")
		body_text = JSON.stringify(body)
	if _public_request_channel_quarantined:
		# 冻结隔离期内的唯一下一条命令；token/payload 不从后续 UI 状态重建。
		_queued_public_request = {
			"action": action,
			"path": path,
			"headers": headers,
			"method": method,
			"body_text": body_text,
		}
		return
	_dispatch_public_request(path, headers, method, body_text)


func _dispatch_public_request(
	path: String,
	headers: PackedStringArray,
	method: HTTPClient.Method,
	body_text: String
) -> void:
	if pending_public_request == PublicRequest.NONE or _public_request_in_flight:
		return
	_public_request_in_flight = true
	var err := public_lobby_request.request(
		public_room_lease.get_public_lobby_api_base_url() + path,
		headers,
		method,
		body_text
	)
	if err != OK:
		_public_request_in_flight = false
		_quarantine_public_request_channel()
		var action := pending_public_request
		pending_public_request = PublicRequest.NONE
		_pending_public_request_lease_generation = 0
		_pending_public_request_acquisition_token = ""
		_queued_public_request.clear()
		_cancel_public_request_side_effect(action)
		var message := "请求公网大厅失败: %s" % error_string(err)
		if _is_membership_acquisition_action(action):
			call_deferred("_cleanup_failed_public_membership", message)
		else:
			_show_public_error(message)


func _on_public_lobby_request_completed(
	result: int,
	response_code: int,
	_headers: PackedStringArray,
	body: PackedByteArray
) -> void:
	# Godot 会 deferred 派发完成，且内部回调先取消节点；隔离到本轮队列排空，
	# 避免同步失败/超时留下的第二个旧回调取消下一条真实请求。
	_quarantine_public_request_channel()
	if not _public_request_in_flight:
		return
	_public_request_in_flight = false
	var action := pending_public_request
	var expected_lease_generation := _pending_public_request_lease_generation
	var expected_acquisition_token := _pending_public_request_acquisition_token
	pending_public_request = PublicRequest.NONE
	_pending_public_request_lease_generation = 0
	_pending_public_request_acquisition_token = ""
	_queued_public_request.clear()
	# 离房会主动取消普通命令；迟到的取消回调不能覆盖清理反馈。
	if action == PublicRequest.NONE:
		return
	if (
		expected_lease_generation > 0
		and (
			not public_room_lease.has_active_lease()
			or public_room_lease.get_lease_generation()
			!= expected_lease_generation
			or public_room_lease.get_acquisition_token()
			!= expected_acquisition_token
		)
	):
		return
	var body_text := body.get_string_from_utf8()
	if result != HTTPRequest.RESULT_SUCCESS or response_code < 200 or response_code >= 300:
		_cancel_public_request_side_effect(action)
		var message := _format_public_request_error(response_code, body_text)
		if _is_membership_acquisition_action(action):
			_cleanup_failed_public_membership(message)
		else:
			_show_public_error(message)
		return

	var parsed: Variant = null
	if not body_text.is_empty():
		parsed = JSON.parse_string(body_text)
	if action == PublicRequest.ACQUISITION_PREFLIGHT:
		_handle_acquisition_preflight_response(
			parsed as Dictionary,
			expected_lease_generation
		)
		return
	if _is_acquisition_command_action(action):
		var acquisition_response := parsed as Dictionary
		if acquisition_response == null or not acquisition_response.has(
			"acquisition_token"
		):
			_cleanup_failed_public_membership("公网大厅响应缺少 acquisition 身份。")
			return
		if str(acquisition_response.get("acquisition_token", "")) != (
			expected_acquisition_token
		):
			_cleanup_failed_public_membership(
				"公网大厅响应的 capability 与当前命令不匹配。"
			)
			return

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
		PublicRequest.CONFIRM_ACQUISITION:
			_pending_public_room_after_confirm.clear()
			wait_status_label.text = "成员身份已确认，等待开始。"
			_refresh_wait_player_list()
		PublicRequest.HOST_READY:
			relay_host_ready_sent = true
			wait_status_label.text = "公网房间已创建，等待玩家加入。"
			_refresh_wait_player_list()
		PublicRequest.UPDATE_ROOM:
			if pending_start_after_public_status:
				pending_start_after_public_status = false
				net_manager.host_start_game()
				if int(net_manager.connection_state) == int(STATE_LOADING_GAME):
					_start_multiplayer_game()
				else:
					# 云端已经进入 IN_GAME，不能退回一份表面仍可等待的本地房间。
					_cleanup_failed_public_membership(
						"开局已取消：仍有玩家尚未确认角色"
					)
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
	elif action == PublicRequest.CONFIRM_ACQUISITION:
		_pending_public_room_after_confirm.clear()
	elif action == PublicRequest.ACQUISITION_PREFLIGHT:
		_pending_public_acquisition_command.clear()


func _is_membership_acquisition_action(action: PublicRequest) -> bool:
	return action in [
		PublicRequest.ACQUISITION_PREFLIGHT,
		PublicRequest.CREATE_ROOM,
		PublicRequest.JOIN_ROOM,
		PublicRequest.QUICK_MATCH,
		PublicRequest.CONFIRM_ACQUISITION,
		PublicRequest.HOST_READY,
	]


func _is_acquisition_command_action(action: PublicRequest) -> bool:
	return action in [
		PublicRequest.CREATE_ROOM,
		PublicRequest.JOIN_ROOM,
		PublicRequest.QUICK_MATCH,
	]


func _handle_acquisition_preflight_response(
	data: Dictionary,
	expected_lease_generation: int
) -> void:
	if data == null:
		_pending_public_acquisition_command.clear()
		_cleanup_failed_public_membership("公网大厅 preflight 响应为空。")
		return
	var acquisition_token := str(data.get("acquisition_token", "")).strip_edges()
	var command := _pending_public_acquisition_command.duplicate(true)
	if (
		acquisition_token.is_empty()
		or command.is_empty()
		or int(command.get("lease_generation", 0))
		!= expected_lease_generation
	):
		_pending_public_acquisition_command.clear()
		_cleanup_failed_public_membership("公网大厅 preflight 响应缺少有效 capability。")
		return
	var action_name := StringName(command.get("action_name", &""))
	if not public_room_lease.bind_acquisition_capability(
		expected_lease_generation,
		action_name,
		acquisition_token
	):
		_pending_public_acquisition_command.clear()
		_cleanup_failed_public_membership("公网大厅返回了无法绑定的 capability。")
		return
	var body := (command.get("body", {}) as Dictionary).duplicate(true)
	body["acquisition_token"] = acquisition_token
	_pending_public_acquisition_command.clear()
	_send_public_request(
		int(command.get("request_action", PublicRequest.NONE)) as PublicRequest,
		str(command.get("path", "")),
		HTTPClient.METHOD_POST,
		body
	)


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
		var game_mode_key := _get_room_game_mode_key(room)
		if game_mode_key.is_empty():
			continue
		var game_mode := NetManagerStore.game_mode_from_key(game_mode_key)
		var button := Button.new()
		button.text = "[%s] %s  %d/%d  房主：%s" % [
			NetManagerStore.get_game_mode_display_name(game_mode),
			str(room.get("name", "房间")),
			int(room.get("player_count", 0)),
			int(room.get("max_players", 0)),
			str(room.get("host_name", "")),
		]
		button.icon = _get_game_mode_icon(game_mode)
		button.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		button.pressed.connect(_on_public_room_selected.bind(room_id, game_mode_key))
		room_list_vbox.add_child(button)
	browser_status_label.text = "房间列表已刷新。"


func _begin_public_host_room(data: Dictionary) -> void:
	if data == null:
		_cleanup_failed_public_membership("创建公网房间失败：响应为空")
		return
	var relay_ip := str(data.get("relay_ip", ""))
	var relay_port := int(data.get("relay_port", 0))
	var room_id := _get_public_room_id(data)
	var host_token := str(data.get("host_token", ""))
	var member_token := str(data.get("member_token", ""))
	var acquisition_token := str(data.get("acquisition_token", ""))
	relay_host_ready_sent = false
	var identity_adopted := public_room_lease.adopt_room(
		room_id,
		str(net_manager.local_player_name),
		member_token,
		host_token,
		true,
		acquisition_token
	)

	if (
		relay_ip.is_empty()
		or relay_port <= 0
		or not identity_adopted
	):
		_cleanup_failed_public_membership(
			"创建公网房间失败：Relay 或认证信息不完整"
		)
		return
	if not _apply_room_game_mode(data, true):
		_cleanup_failed_public_membership("创建公网房间失败：游戏模式无效")
		return

	var max_players := _get_room_max_players(data)
	var err: Error = net_manager.host_create_relay_room(relay_ip, relay_port, max_players)
	if err != OK:
		_cleanup_failed_public_membership("连接 Relay 失败: %s" % error_string(err))
		return
	_enter_room_wait(data)
	wait_status_label.text = "正在连接公网 Relay..."


func _begin_public_client_room(data: Dictionary) -> void:
	if data == null:
		_cleanup_failed_public_membership("加入公网房间失败：响应为空")
		return
	var relay_ip := str(data.get("relay_ip", ""))
	var relay_port := int(data.get("relay_port", 0))
	var host_peer_id := int(data.get("host_peer_id", 0))
	var room_id := _get_public_room_id(data)
	var member_token := str(data.get("member_token", ""))
	var acquisition_token := str(data.get("acquisition_token", ""))
	relay_host_ready_sent = false
	var identity_adopted := public_room_lease.adopt_room(
		room_id,
		str(net_manager.local_player_name),
		member_token,
		"",
		false,
		acquisition_token
	)

	if (
		relay_ip.is_empty()
		or relay_port <= 0
		or host_peer_id <= 0
		or not identity_adopted
	):
		_cleanup_failed_public_membership(
			"加入公网房间失败：Relay 或认证信息不完整"
		)
		return
	if not _apply_room_game_mode(data, false):
		_cleanup_failed_public_membership("加入公网房间失败：游戏模式无效")
		return
	var max_players := _get_room_max_players(data)
	if not net_manager.set_pending_room_max_players(max_players):
		_cleanup_failed_public_membership("加入公网房间失败：无法应用房间人数上限")
		return
	# HTTP 响应只取得 provisional 占位；Relay 真正连通后才向目录确认长租约。
	_pending_public_room_after_confirm = data.duplicate(true)
	var err: Error = net_manager.client_join_relay_room(relay_ip, relay_port, host_peer_id)
	if err != OK:
		_cleanup_failed_public_membership("连接 Relay 失败: %s" % error_string(err))
		return
	_enter_room_wait(data)
	wait_status_label.text = "正在连接公网 Relay，成员身份尚未确认…"


func _request_public_member_confirmation() -> void:
	if (
		_pending_public_room_after_confirm.is_empty()
		or public_room_lease.is_public_host()
		or pending_public_request != PublicRequest.NONE
	):
		return
	var room_id := public_room_lease.get_room_id()
	var player_name := public_room_lease.get_player_name()
	var member_token := public_room_lease.get_member_token()
	if room_id.is_empty() or player_name.is_empty() or member_token.is_empty():
		_cleanup_failed_public_membership("确认公网成员身份失败：成员身份缺失")
		return
	wait_status_label.text = "Relay 已连接，正在确认成员身份…"
	_send_public_request(
		PublicRequest.CONFIRM_ACQUISITION,
		"/acquisitions/confirm",
		HTTPClient.METHOD_POST,
		{
			"room_id": room_id,
			"player_name": player_name,
			"member_token": member_token,
		}
	)


func _request_public_host_ready() -> void:
	var room_id := public_room_lease.get_room_id()
	var host_token := public_room_lease.get_host_token()
	if room_id.is_empty() or host_token.is_empty():
		return
	if relay_host_ready_sent or pending_public_request != PublicRequest.NONE:
		return
	var host_peer_id := int(net_manager.get_host_peer_id())
	if host_peer_id <= 0:
		return
	var body := {
		"host_token": host_token,
		"host_peer_id": host_peer_id,
	}
	_send_public_request(
		PublicRequest.HOST_READY,
		"/rooms/%s/host_ready" % room_id,
		HTTPClient.METHOD_POST,
		body
	)


func _request_public_room_status(status: String) -> void:
	var room_id := public_room_lease.get_room_id()
	var host_token := public_room_lease.get_host_token()
	if room_id.is_empty() or host_token.is_empty():
		return
	if pending_public_request != PublicRequest.NONE:
		return
	var body := {
		"host_token": host_token,
		"status": status,
	}
	_send_public_request(
		PublicRequest.UPDATE_ROOM,
		"/rooms/%s" % room_id,
		HTTPClient.METHOD_PATCH,
		body
	)


func _enter_room_wait(room_data: Dictionary) -> void:
	_show_view(LobbyView.ROOM_WAIT)
	var room_name: String = str(room_data.get("name", "房间"))
	var room_id: String = _get_public_room_id(room_data)
	room_code_label.text = "房间: %s (%s)" % [room_name, room_id]
	current_room_max_players = _get_room_max_players(room_data)
	_update_room_mode_label()
	_update_room_capacity_label()
	start_game_btn.visible = net_manager.is_host()
	wait_status_label.text = "等待玩家加入..."
	_refresh_wait_player_list()
	call_deferred("_open_character_choice_if_needed")


func _refresh_wait_player_list() -> void:
	for child in wait_player_list_vbox.get_children():
		child.queue_free()

	for peer_id_variant in net_manager.connected_players:
		var peer_id: int = int(peer_id_variant)
		var player_name: String = str(net_manager.connected_players[peer_id])
		var label := Label.new()
		var is_host_marker := " (Host)" if peer_id == net_manager.get_host_peer_id() else ""
		var is_local_marker: String = " <- 你" if peer_id == net_manager.get_local_peer_id() else ""
		var character_id := net_manager.get_player_character_id(peer_id)
		var character_name := _get_character_display_name(character_id)
		var character_confirmed := net_manager.is_player_character_confirmed(peer_id)
		var confirmation_marker := " ✓" if character_confirmed else "（角色未确认）"
		label.text = "%s · %s%s%s%s" % [
			player_name,
			character_name,
			confirmation_marker,
			is_host_marker,
			is_local_marker,
		]
		wait_player_list_vbox.add_child(label)

	_update_room_capacity_label()
	if net_manager.is_host():
		start_game_btn.disabled = (
			net_manager.connected_players.size() < 2
			or not net_manager.are_all_player_characters_confirmed()
			or (public_room_lease.is_public_host() and not relay_host_ready_sent)
		)
	_update_choose_character_button()


func _update_room_capacity_label(current_players: int = -1) -> void:
	if room_capacity_label == null:
		return
	if current_players < 0:
		current_players = net_manager.connected_players.size()
	room_capacity_label.text = "游玩人数：%d / %d（总人数含房主）" % [
		current_players,
		current_room_max_players,
	]


func _open_character_choice_if_needed() -> void:
	if current_view != LobbyView.ROOM_WAIT:
		return
	var local_peer_id := net_manager.get_local_peer_id()
	if local_peer_id > 0 and net_manager.is_player_character_confirmed(local_peer_id):
		return
	_on_choose_character_pressed()


func _on_choose_character_pressed() -> void:
	var selected_character_id := _get_local_selected_character_id()
	character_choice_overlay.open(selected_character_id)


func _on_character_confirmed(character_id: StringName) -> void:
	if not PlayerCharacterRegistry.is_valid_character_id(character_id):
		return
	if run_state != null:
		run_state.set_selected_character(character_id)
	net_manager.set_local_character_id(character_id, true)
	character_choice_overlay.close()
	_refresh_wait_player_list()
	wait_status_label.text = "角色已确认，等待其他玩家。"


func _on_character_selection_closed() -> void:
	if current_view == LobbyView.ROOM_WAIT:
		choose_character_btn.grab_focus()


func _update_choose_character_button() -> void:
	choose_character_btn.visible = true
	var character_id := _get_local_selected_character_id()
	var character_name := _get_character_display_name(character_id)
	var local_peer_id := net_manager.get_local_peer_id()
	var confirmed := (
		local_peer_id > 0
		and net_manager.is_player_character_confirmed(local_peer_id)
	)
	choose_character_btn.text = (
		"更换角色：%s（已确认）" % character_name
		if confirmed
		else "选择并确认角色：%s" % character_name
	)


func _on_net_player_list_changed() -> void:
	if current_view == LobbyView.ROOM_WAIT:
		_refresh_wait_player_list()


func _on_net_room_capacity_changed(current_players: int, max_players: int) -> void:
	current_room_max_players = clampi(
		max_players,
		_NetConstants.MIN_ROOM_PLAYERS,
		_NetConstants.MAX_PLAYERS
	)
	if current_view == LobbyView.ROOM_WAIT:
		_update_room_capacity_label(current_players)


func _on_net_game_mode_changed(new_game_mode: NetManagerStore.GameMode) -> void:
	_select_game_mode_in_selector(new_game_mode)
	_update_room_mode_label()
	_refresh_game_mode_selector_state()
	if current_view == LobbyView.ROOM_WAIT:
		_refresh_wait_player_list()


func _on_net_connection_failed(reason: String) -> void:
	if current_view == LobbyView.ROOM_WAIT:
		keep_room_view_after_connection_failure = true
		wait_status_label.text = "连接失败: %s" % reason
		if public_room_lease.has_active_lease():
			_cleanup_failed_public_membership("连接失败: %s" % reason)
	else:
		lan_status_label.text = "连接失败: %s" % reason


func _on_net_state_changed(new_state: NetManagerStore.ConnectionState) -> void:
	var is_relay := net_manager.conn_mode == NetManagerStore.ConnMode.RELAY
	_refresh_game_mode_selector_state()
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
			if (
				public_room_lease.has_active_lease()
				and not public_room_lease.is_public_host()
				and not _pending_public_room_after_confirm.is_empty()
			):
				_request_public_member_confirmation()
			else:
				wait_status_label.text = "已连接，等待开始。"
			_update_room_mode_label()
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
	if not net_manager.are_all_player_characters_confirmed():
		wait_status_label.text = "请等待所有玩家确认角色。"
		_refresh_wait_player_list()
		return
	if public_room_lease.is_public_host() and public_room_lease.has_active_lease():
		pending_start_after_public_status = true
		wait_status_label.text = "正在通知公网大厅开始游戏..."
		_request_public_room_status("in_game")
		if pending_public_request == PublicRequest.NONE:
			pending_start_after_public_status = false
		return
	net_manager.host_start_game()
	if int(net_manager.connection_state) == int(STATE_LOADING_GAME):
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
	var game_mode_definition := GameModeCatalog.get_definition(
		int(net_manager.get_current_game_mode())
	)
	if game_mode_definition == null:
		is_starting_game = false
		push_error("MultiplayerLobby: 当前联机模式没有目录定义。")
		return
	if not GameModeCatalog.is_release_selectable(game_mode_definition.mode_id):
		is_starting_game = false
		push_error("MultiplayerLobby: 当前联机模式尚未发布。")
		return
	if run_state != null:
		run_state.begin_new_run(
			_get_local_selected_character_id(),
			game_mode_definition.include_starting_inventory
		)
	var load_coordinator := get_node_or_null("/root/GameLoadCoordinator")
	if load_coordinator != null and load_coordinator.has_method("begin_multiplayer"):
		load_coordinator.call("begin_multiplayer")
		return
	tree.change_scene_to_file(game_mode_definition.multiplayer_entry_scene_path)


func _on_leave_room() -> void:
	if public_release_in_progress:
		return
	if not public_room_lease.has_active_lease():
		net_manager.disconnect_from_game()
		_clear_public_room_state()
		_show_view(LobbyView.LAN_DIRECT)
		lan_status_label.text = "已离开房间。"
		return
	public_release_in_progress = true
	leave_room_btn.disabled = true
	wait_status_label.text = "正在认证释放公网房间身份…"
	_cancel_pending_public_command_for_release()
	var result := await public_room_lease.release_current_and_wait(&"lobby_leave")
	if not is_inside_tree():
		return
	# 远端失败也已到达有界终点；此处才清本地传输和大厅表现。
	net_manager.disconnect_from_game()
	_clear_public_room_state()
	public_release_in_progress = false
	leave_room_btn.disabled = false
	_show_view(LobbyView.PUBLIC_BROWSER)
	_request_public_rooms()
	browser_status_label.text = (
		"已离开公网房间，正在刷新列表…"
		if bool(result.get("success", false))
		else "本地已离开；云端未确认释放，服务端租约将自动回收。"
	)


func _cleanup_failed_public_membership(message: String) -> void:
	if public_release_in_progress:
		return
	if current_view == LobbyView.ROOM_WAIT:
		wait_status_label.text = "%s；正在释放公网房间占位…" % message
	public_release_in_progress = true
	pending_start_after_public_status = false
	_cancel_pending_public_command_for_release()
	_release_failed_public_membership(message)


func _release_failed_public_membership(message: String) -> void:
	var had_authenticated_lease := public_room_lease.has_active_lease()
	var result := await public_room_lease.release_current_and_wait(
		&"membership_setup_failed"
	)
	if not is_inside_tree():
		return
	if net_manager.is_multiplayer_active():
		net_manager.disconnect_from_game()
	_clear_public_room_state()
	public_release_in_progress = false
	if current_view == LobbyView.USERNAME_INPUT:
		return
	_show_view(LobbyView.PUBLIC_BROWSER)
	if not had_authenticated_lease:
		browser_status_label.text = "%s；响应缺少可用认证身份，无法主动释放。" % message
	elif bool(result.get("success", false)):
		browser_status_label.text = "%s；目录房间占位已释放。" % message
	else:
		browser_status_label.text = "%s；本地已退出，云端将按租约自动回收。" % message


func _cancel_pending_public_command_for_release() -> void:
	var cancelled_action := pending_public_request
	_public_request_in_flight = false
	pending_public_request = PublicRequest.NONE
	_pending_public_request_lease_generation = 0
	_pending_public_request_acquisition_token = ""
	_queued_public_request.clear()
	_cancel_public_request_side_effect(cancelled_action)
	if public_lobby_request.get_http_client_status() != HTTPClient.STATUS_DISCONNECTED:
		public_lobby_request.cancel_request()
	_quarantine_public_request_channel()


func _quarantine_public_request_channel() -> void:
	_public_request_channel_quarantine_generation += 1
	_public_request_channel_quarantined = true
	_finish_public_request_channel_quarantine.call_deferred(
		_public_request_channel_quarantine_generation
	)


func _finish_public_request_channel_quarantine(generation: int) -> void:
	if generation != _public_request_channel_quarantine_generation:
		return
	_public_request_channel_quarantined = false
	if _queued_public_request.is_empty():
		return
	var queued := _queued_public_request.duplicate(true)
	_queued_public_request.clear()
	if (
		pending_public_request == PublicRequest.NONE
		or int(queued.get("action", PublicRequest.NONE))
		!= int(pending_public_request)
		or _public_request_in_flight
	):
		return
	_dispatch_public_request(
		str(queued.get("path", "")),
		queued.get("headers", PackedStringArray()) as PackedStringArray,
		int(queued.get("method", HTTPClient.METHOD_GET)) as HTTPClient.Method,
		str(queued.get("body_text", ""))
	)


func _on_back_to_main_menu() -> void:
	if public_release_in_progress:
		return
	public_release_in_progress = true
	_cancel_pending_public_command_for_release()
	await public_room_lease.release_current_and_wait(&"lobby_back_to_menu")
	if not is_inside_tree():
		return
	net_manager.disconnect_from_game()
	get_tree().change_scene_to_file("res://scene/main_menu.tscn")


func _clear_public_room_state() -> void:
	# 这里只重置场景表现；跨场景身份只能由 PublicRoomLease 在有界清理后释放。
	relay_host_ready_sent = false
	pending_start_after_public_status = false
	keep_room_view_after_connection_failure = false
	_pending_public_acquisition_command.clear()
	_pending_public_room_after_confirm.clear()
	current_room_max_players = _NetConstants.DEFAULT_ROOM_MAX_PLAYERS


func _get_public_room_id(room_data: Dictionary) -> String:
	var room_id := str(room_data.get("room_id", ""))
	if room_id.is_empty():
		room_id = str(room_data.get("id", ""))
	return room_id


func _get_room_max_players(room_data: Dictionary) -> int:
	return clampi(
		int(room_data.get("max_players", _NetConstants.DEFAULT_ROOM_MAX_PLAYERS)),
		_NetConstants.MIN_ROOM_PLAYERS,
		_NetConstants.MAX_PLAYERS
	)


func _get_game_mode_icon(game_mode: NetManagerStore.GameMode) -> Texture2D:
	return _load_game_mode_icon(GameModeCatalog.get_definition(int(game_mode)))


func _load_game_mode_icon(definition: GameModeDefinition) -> Texture2D:
	if definition == null:
		return null
	var icon_path := definition.lobby_icon_path.strip_edges()
	if icon_path.is_empty():
		return null
	if _game_mode_icon_cache.has(icon_path):
		return _game_mode_icon_cache[icon_path] as Texture2D
	var icon := load(icon_path) as Texture2D
	if icon != null:
		_game_mode_icon_cache[icon_path] = icon
	return icon


func _sync_local_character_selection() -> void:
	net_manager.set_local_character_id(_get_local_selected_character_id(), false)


func _get_local_selected_character_id() -> StringName:
	var selected_character_id := PlayerCharacterRegistry.DEFAULT_CHARACTER_ID
	if run_state != null:
		selected_character_id = run_state.get_selected_character_id()
	if not PlayerCharacterRegistry.is_valid_character_id(selected_character_id):
		selected_character_id = PlayerCharacterRegistry.DEFAULT_CHARACTER_ID
	return selected_character_id


func _get_character_display_name(character_id: StringName) -> String:
	var config: PlayerCharacterConfig = PlayerCharacterRegistry.get_config(character_id)
	if config != null and not config.display_name.is_empty():
		return config.display_name
	return "锄头猫猫" if character_id == &"hoe_cat" else "维什戴尔"
