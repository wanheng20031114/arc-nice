extends Control

const _NetConstants := preload("res://scene/multiplayer/net_constants.gd")
const MULTIPLAYER_GAME_SCENE_PATH := "res://scene/multiplayer/mp_game.tscn"
const MULTIPLAYER_ROGUE_ROUTE_SCENE_PATH := (
	"res://scene/multiplayer/mp_rogue_route.tscn"
)
const PUBLIC_LOBBY_API_BASE_URL := _NetConstants.PUBLIC_LOBBY_API_BASE_URL
const USERNAME_CARET_SIZE := Vector2(2.0, 34.0)
const USERNAME_CARET_BLINK_INTERVAL := 0.48
const STATE_DISCONNECTED := NetManagerStore.ConnectionState.DISCONNECTED
const STATE_HOSTING_LAN := NetManagerStore.ConnectionState.HOSTING_LAN
const STATE_CONNECTING_LAN := NetManagerStore.ConnectionState.CONNECTING_LAN
const STATE_CONNECTED_IN_LOBBY := NetManagerStore.ConnectionState.CONNECTED_IN_LOBBY
const STATE_LOADING_GAME := NetManagerStore.ConnectionState.LOADING_GAME
const GAME_MODE_STANDARD_KEY := "standard"
const GAME_MODE_TOWER_DEFENSE_KEY := "tower_defense"
const GAME_MODE_TEST_ARENA_P1_KEY := "test_arena_p1"
const GAME_MODE_TEST_ARENA_P1B_KEY := "test_arena_p1b"
const GAME_MODE_TEST_ARENA_P2_KEY := "test_arena_p2"
const GAME_MODE_TEST_ARENA_P3_KEY := "test_arena_p3"
const GAME_MODE_STANDARD_ICON: Texture2D = preload(
	"res://resources/texture/ui/multiplayer/mode_standard.png"
)
const GAME_MODE_TOWER_DEFENSE_ICON: Texture2D = preload(
	"res://resources/texture/ui/multiplayer/mode_tower_defense.png"
)
const GAME_MODE_TEST_ARENA_P1_ICON: Texture2D = preload(
	"res://resources/texture/ui/multiplayer/mode_test_p1.png"
)
const GAME_MODE_TEST_ARENA_P2_ICON: Texture2D = preload(
	"res://resources/texture/ui/multiplayer/mode_test_p2.png"
)
const GAME_MODE_TEST_ARENA_P3_ICON: Texture2D = preload(
	"res://resources/texture/rogue_route/party_marker.png"
)

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
@onready var net_manager: Node = get_node("/root/NetManager")
@onready var run_state: Node = get_node_or_null("/root/RunState")

var current_view: LobbyView = LobbyView.USERNAME_INPUT
var is_starting_game: bool = false
var pending_public_request: PublicRequest = PublicRequest.NONE
var current_public_room_id: String = ""
var current_public_host_token: String = ""
var current_public_member_token: String = ""
var current_public_room_name: String = ""
var current_public_is_host: bool = false
var current_public_room_game_mode: NetManagerStore.GameMode = NetManagerStore.GameMode.STANDARD
var relay_host_ready_sent: bool = false
var pending_start_after_public_status: bool = false
var keep_room_view_after_connection_failure: bool = false
var public_cleanup_in_progress: bool = false
var public_cleanup_pending_dispatch: bool = false
var public_cleanup_status_message: String = ""
var current_room_max_players: int = _NetConstants.DEFAULT_ROOM_MAX_PLAYERS
var _username_panel_intro_tween: Tween
var _username_panel_intro_target_position := Vector2.ZERO
var _username_panel_intro_active := false
var _username_caret_blink_elapsed := 0.0


func _ready() -> void:
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
	game_mode_selector.add_icon_item(
		GAME_MODE_STANDARD_ICON,
		"普通冒险",
		NetManagerStore.GameMode.STANDARD
	)
	game_mode_selector.add_icon_item(
		GAME_MODE_TOWER_DEFENSE_ICON,
		"塔防模式",
		NetManagerStore.GameMode.TOWER_DEFENSE
	)
	game_mode_selector.add_icon_item(
		GAME_MODE_TEST_ARENA_P1_ICON,
		"测试场 P1A",
		NetManagerStore.GameMode.TEST_ARENA_P1
	)
	game_mode_selector.add_icon_item(
		GAME_MODE_TEST_ARENA_P1_ICON,
		"测试场 P1B",
		NetManagerStore.GameMode.TEST_ARENA_P1B
	)
	game_mode_selector.add_icon_item(
		GAME_MODE_TEST_ARENA_P2_ICON,
		"测试场 P2",
		NetManagerStore.GameMode.TEST_ARENA_P2
	)
	game_mode_selector.add_icon_item(
		GAME_MODE_TEST_ARENA_P3_ICON,
		"测试场 P3 · 肉鸽路线",
		NetManagerStore.GameMode.TEST_ARENA_P3
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
	match item_id:
		NetManagerStore.GameMode.TOWER_DEFENSE:
			return NetManagerStore.GameMode.TOWER_DEFENSE
		NetManagerStore.GameMode.TEST_ARENA_P1:
			return NetManagerStore.GameMode.TEST_ARENA_P1
		NetManagerStore.GameMode.TEST_ARENA_P1B:
			return NetManagerStore.GameMode.TEST_ARENA_P1B
		NetManagerStore.GameMode.TEST_ARENA_P2:
			return NetManagerStore.GameMode.TEST_ARENA_P2
		NetManagerStore.GameMode.TEST_ARENA_P3:
			return NetManagerStore.GameMode.TEST_ARENA_P3
		_:
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
	var game_mode_key := str(
		room_data.get("game_mode", GAME_MODE_STANDARD_KEY)
	).strip_edges().to_lower()
	if game_mode_key in [
		GAME_MODE_STANDARD_KEY,
		GAME_MODE_TOWER_DEFENSE_KEY,
		GAME_MODE_TEST_ARENA_P1_KEY,
		GAME_MODE_TEST_ARENA_P1B_KEY,
		GAME_MODE_TEST_ARENA_P2_KEY,
		GAME_MODE_TEST_ARENA_P3_KEY,
	]:
		return game_mode_key
	return ""


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
	current_public_room_game_mode = game_mode
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
	if current_view != LobbyView.PUBLIC_BROWSER:
		return
	browser_status_label.text = "正在刷新房间列表..."
	_send_public_request(PublicRequest.LIST_ROOMS, "/rooms", HTTPClient.METHOD_GET)


func _on_create_public_room_pressed() -> void:
	if not _prepare_selected_host_game_mode():
		return
	var body := {
		"name": room_name_input.text.strip_edges(),
		"host_name": net_manager.local_player_name,
		"max_players": int(max_players_spin.value),
		"game_mode": _get_selected_game_mode_key(),
	}
	browser_status_label.text = "正在创建公网房间..."
	_send_public_request(PublicRequest.CREATE_ROOM, "/rooms", HTTPClient.METHOD_POST, body)


func _on_quick_match_pressed() -> void:
	if not _prepare_selected_host_game_mode():
		return
	var body := {
		"player_name": net_manager.local_player_name,
		"game_mode": _get_selected_game_mode_key(),
	}
	browser_status_label.text = "正在快速匹配..."
	_send_public_request(PublicRequest.QUICK_MATCH, "/matchmaking/quick", HTTPClient.METHOD_POST, body)


func _on_public_room_selected(room_id: String, game_mode_key: String) -> void:
	var game_mode := NetManagerStore.game_mode_from_key(game_mode_key)
	if not net_manager.set_pending_game_mode(game_mode):
		_show_public_error("当前连接状态不能加入房间。")
		return
	_select_game_mode_in_selector(game_mode)
	var body := {
		"player_name": net_manager.local_player_name,
		"game_mode": game_mode_key,
	}
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
		if public_cleanup_pending_dispatch:
			call_deferred("_dispatch_failed_public_membership_cleanup")
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
				if int(net_manager.connection_state) == int(STATE_LOADING_GAME):
					_start_multiplayer_game()
				else:
					wait_status_label.text = "开局已取消：仍有玩家尚未确认角色。"
		PublicRequest.LEAVE_ROOM, PublicRequest.DESTROY_ROOM:
			var cleanup_message := public_cleanup_status_message
			var was_failure_cleanup := public_cleanup_in_progress
			_clear_public_room_state()
			if current_view != LobbyView.USERNAME_INPUT:
				_show_view(LobbyView.PUBLIC_BROWSER)
				_request_public_rooms()
				if was_failure_cleanup:
					browser_status_label.text = "%s；目录房间占位已释放，正在刷新列表…" % cleanup_message
		_:
			pass
	if public_cleanup_pending_dispatch:
		call_deferred("_dispatch_failed_public_membership_cleanup")


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
	if (
		public_cleanup_in_progress
		and action in [PublicRequest.LEAVE_ROOM, PublicRequest.DESTROY_ROOM]
	):
		_clear_public_room_state()
		if current_view != LobbyView.USERNAME_INPUT:
			_show_view(LobbyView.PUBLIC_BROWSER)


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
		_show_public_error("创建公网房间失败：响应为空")
		return
	var relay_ip := str(data.get("relay_ip", ""))
	var relay_port := int(data.get("relay_port", 0))
	var room_id := _get_public_room_id(data)
	var host_token := str(data.get("host_token", ""))
	var member_token := str(data.get("member_token", ""))

	current_public_room_id = room_id
	current_public_host_token = host_token
	current_public_member_token = member_token
	current_public_room_name = str(data.get("name", "公网房间"))
	current_public_is_host = true
	relay_host_ready_sent = false

	if (
		relay_ip.is_empty()
		or relay_port <= 0
		or room_id.is_empty()
		or host_token.is_empty()
		or member_token.is_empty()
	):
		_cleanup_failed_public_membership("创建公网房间失败：Relay 信息不完整")
		return
	if not _apply_room_game_mode(data, true):
		_cleanup_failed_public_membership("创建公网房间失败：游戏模式无效")
		return

	var max_players := _get_room_max_players(data)
	var err: Error = net_manager.host_create_relay_room(relay_ip, relay_port, max_players)
	if err != OK:
		net_manager.clear_public_room_context()
		_cleanup_failed_public_membership("连接 Relay 失败: %s" % error_string(err))
		return
	net_manager.set_public_room_context(room_id, host_token, true)
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
	var member_token := str(data.get("member_token", ""))

	current_public_room_id = room_id
	current_public_host_token = ""
	current_public_member_token = member_token
	current_public_room_name = str(data.get("name", "公网房间"))
	current_public_is_host = false
	relay_host_ready_sent = false

	if (
		relay_ip.is_empty()
		or relay_port <= 0
		or host_peer_id <= 0
		or room_id.is_empty()
		or member_token.is_empty()
	):
		_cleanup_failed_public_membership("加入公网房间失败：Relay 信息不完整")
		return
	if not _apply_room_game_mode(data, false):
		_cleanup_failed_public_membership("加入公网房间失败：游戏模式无效")
		return
	var max_players := _get_room_max_players(data)
	if not net_manager.set_pending_room_max_players(max_players):
		_cleanup_failed_public_membership("加入公网房间失败：无法应用房间人数上限")
		return

	var err: Error = net_manager.client_join_relay_room(relay_ip, relay_port, host_peer_id)
	if err != OK:
		net_manager.clear_public_room_context()
		_cleanup_failed_public_membership("连接 Relay 失败: %s" % error_string(err))
		return
	net_manager.set_public_room_context(room_id, "", false)
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
		var character_id := StringName(
			net_manager.call("get_player_character_id", peer_id)
		)
		var character_name := _get_character_display_name(character_id)
		var character_confirmed := bool(
			net_manager.call("is_player_character_confirmed", peer_id)
		)
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
			or not bool(
				net_manager.call("are_all_player_characters_confirmed")
			)
			or (current_public_is_host and not relay_host_ready_sent)
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
	var local_peer_id := int(net_manager.call("get_local_peer_id"))
	if local_peer_id > 0 and bool(net_manager.call("is_player_character_confirmed", local_peer_id)):
		return
	_on_choose_character_pressed()


func _on_choose_character_pressed() -> void:
	var selected_character_id := _get_local_selected_character_id()
	character_choice_overlay.open(selected_character_id)


func _on_character_confirmed(character_id: StringName) -> void:
	if not PlayerCharacterRegistry.is_valid_character_id(character_id):
		return
	if run_state != null and run_state.has_method("set_selected_character"):
		run_state.call("set_selected_character", character_id)
	net_manager.call("set_local_character_id", character_id, true)
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
	var local_peer_id := int(net_manager.call("get_local_peer_id"))
	var confirmed := (
		local_peer_id > 0
		and bool(net_manager.call("is_player_character_confirmed", local_peer_id))
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
		if not current_public_room_id.is_empty():
			_cleanup_failed_public_membership("连接失败: %s" % reason)
	else:
		lan_status_label.text = "连接失败: %s" % reason


func _on_net_state_changed(new_state: NetManagerStore.ConnectionState) -> void:
	var is_relay := int(net_manager.get("conn_mode")) == 1
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
	if not bool(net_manager.call("are_all_player_characters_confirmed")):
		wait_status_label.text = "请等待所有玩家确认角色。"
		_refresh_wait_player_list()
		return
	if current_public_is_host and not current_public_room_id.is_empty():
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
	if run_state != null and run_state.has_method("begin_new_run"):
		run_state.call(
			"begin_new_run",
			_get_local_selected_character_id(),
			not _is_rogue_route_mode()
		)
	var load_coordinator := get_node_or_null("/root/GameLoadCoordinator")
	if load_coordinator != null and load_coordinator.has_method("begin_multiplayer"):
		load_coordinator.call("begin_multiplayer")
		return
	tree.change_scene_to_file(
		MULTIPLAYER_ROGUE_ROUTE_SCENE_PATH
		if _is_rogue_route_mode()
		else MULTIPLAYER_GAME_SCENE_PATH
	)


func _on_leave_room() -> void:
	var was_public := not current_public_room_id.is_empty()
	var room_id := current_public_room_id
	var host_token := current_public_host_token
	var member_token := current_public_member_token
	var player_name: String = str(net_manager.local_player_name)
	var was_host := current_public_is_host
	net_manager.disconnect_from_game()
	if was_public and not room_id.is_empty():
		if not member_token.is_empty():
			_send_public_request(
				PublicRequest.LEAVE_ROOM,
				"/rooms/%s/leave" % room_id,
				HTTPClient.METHOD_POST,
				{
					"player_name": player_name,
					"member_token": member_token,
				}
			)
		elif was_host and not host_token.is_empty():
			_send_public_request(
				PublicRequest.DESTROY_ROOM,
				"/rooms/%s" % room_id,
				HTTPClient.METHOD_DELETE,
				{"host_token": host_token}
			)
	_clear_public_room_state()
	if was_public:
		_show_view(LobbyView.PUBLIC_BROWSER)
	else:
		_show_view(LobbyView.LAN_DIRECT)
		lan_status_label.text = "已离开房间。"


func _cleanup_failed_public_membership(message: String) -> void:
	if public_cleanup_in_progress:
		return
	if current_view == LobbyView.ROOM_WAIT:
		wait_status_label.text = "%s；正在释放公网房间占位…" % message

	if current_public_room_id.is_empty():
		_clear_public_room_state()
		if current_view != LobbyView.USERNAME_INPUT:
			_show_view(LobbyView.PUBLIC_BROWSER)
			browser_status_label.text = message
		return

	if (
		current_public_member_token.is_empty()
		and (
			not current_public_is_host
			or current_public_host_token.is_empty()
		)
	):
		_clear_public_room_state()
		if current_view != LobbyView.USERNAME_INPUT:
			_show_view(LobbyView.PUBLIC_BROWSER)
			browser_status_label.text = "%s；响应缺少成员令牌，无法自动释放目录房间。" % message
		return

	public_cleanup_in_progress = true
	public_cleanup_pending_dispatch = true
	public_cleanup_status_message = message
	pending_start_after_public_status = false
	_dispatch_failed_public_membership_cleanup()


func _dispatch_failed_public_membership_cleanup() -> void:
	if (
		not public_cleanup_in_progress
		or not public_cleanup_pending_dispatch
		or pending_public_request != PublicRequest.NONE
	):
		return

	public_cleanup_pending_dispatch = false
	var cleanup_action := PublicRequest.LEAVE_ROOM
	var cleanup_path := "/rooms/%s/leave" % current_public_room_id
	var cleanup_body := {
		"player_name": str(net_manager.local_player_name),
		"member_token": current_public_member_token,
	}
	if current_public_member_token.is_empty() and current_public_is_host:
		cleanup_action = PublicRequest.DESTROY_ROOM
		cleanup_path = "/rooms/%s" % current_public_room_id
		cleanup_body = {"host_token": current_public_host_token}

	var cleanup_method := HTTPClient.METHOD_POST
	if cleanup_action == PublicRequest.DESTROY_ROOM:
		cleanup_method = HTTPClient.METHOD_DELETE
	_send_public_request(
		cleanup_action,
		cleanup_path,
		cleanup_method,
		cleanup_body
	)


func _on_back_to_main_menu() -> void:
	net_manager.disconnect_from_game()
	get_tree().change_scene_to_file("res://scene/main_menu.tscn")


func _clear_public_room_state() -> void:
	current_public_room_id = ""
	current_public_host_token = ""
	current_public_member_token = ""
	current_public_room_name = ""
	current_public_is_host = false
	current_public_room_game_mode = NetManagerStore.GameMode.STANDARD
	relay_host_ready_sent = false
	pending_start_after_public_status = false
	keep_room_view_after_connection_failure = false
	public_cleanup_in_progress = false
	public_cleanup_pending_dispatch = false
	public_cleanup_status_message = ""
	current_room_max_players = _NetConstants.DEFAULT_ROOM_MAX_PLAYERS
	if net_manager != null:
		net_manager.clear_public_room_context()


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
	match game_mode:
		NetManagerStore.GameMode.TOWER_DEFENSE:
			return GAME_MODE_TOWER_DEFENSE_ICON
		NetManagerStore.GameMode.TEST_ARENA_P1:
			return GAME_MODE_TEST_ARENA_P1_ICON
		NetManagerStore.GameMode.TEST_ARENA_P1B:
			return GAME_MODE_TEST_ARENA_P1_ICON
		NetManagerStore.GameMode.TEST_ARENA_P2:
			return GAME_MODE_TEST_ARENA_P2_ICON
		NetManagerStore.GameMode.TEST_ARENA_P3:
			return GAME_MODE_TEST_ARENA_P3_ICON
		_:
			return GAME_MODE_STANDARD_ICON


func _is_rogue_route_mode() -> bool:
	return (
		net_manager != null
		and net_manager.get_current_game_mode()
		== NetManagerStore.GameMode.TEST_ARENA_P3
	)


func _sync_local_character_selection() -> void:
	net_manager.call("set_local_character_id", _get_local_selected_character_id(), false)


func _get_local_selected_character_id() -> StringName:
	var selected_character_id := PlayerCharacterRegistry.DEFAULT_CHARACTER_ID
	if run_state != null:
		if run_state.has_method("get_selected_character_id"):
			selected_character_id = StringName(run_state.call("get_selected_character_id"))
		else:
			selected_character_id = StringName(run_state.get("selected_character_id"))
	if not PlayerCharacterRegistry.is_valid_character_id(selected_character_id):
		selected_character_id = PlayerCharacterRegistry.DEFAULT_CHARACTER_ID
	return selected_character_id


func _get_character_display_name(character_id: StringName) -> String:
	var config: PlayerCharacterConfig = PlayerCharacterRegistry.get_config(character_id)
	if config != null and not config.display_name.is_empty():
		return config.display_name
	return "锄头猫猫" if character_id == &"hoe_cat" else "维什戴尔"
