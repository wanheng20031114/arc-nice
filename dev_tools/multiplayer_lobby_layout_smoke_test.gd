extends SceneTree

const LOBBY_SCENE := preload("res://scene/multiplayer/multiplayer_lobby.tscn")
const PUBLIC_BROWSER_VIEW := 2
const LAN_DIRECT_VIEW := 3
const ROOM_WAIT_VIEW := 4
const DESIGN_VIEWPORT_SIZE := Vector2(1152.0, 648.0)
const BROWSER_ROOT := "LobbyCenter/RoomBrowserPanel/MarginContainer/VBoxContainer"
const BROWSER_BODY := BROWSER_ROOT + "/BrowserBodyScroll/BrowserBodyVBox"

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var lobby := LOBBY_SCENE.instantiate() as Control
	_expect(lobby != null, "Multiplayer lobby scene must instantiate.")
	if lobby == null:
		_finish()
		return

	root.add_child(lobby)
	await process_frame
	await process_frame
	_expect(
		lobby.size == DESIGN_VIEWPORT_SIZE,
		"Lobby layout test must run at the 1152x648 logical design viewport."
	)

	var browser_panel := lobby.get_node_or_null(
		"LobbyCenter/RoomBrowserPanel"
	) as PanelContainer
	var browser_scroll := lobby.get_node_or_null(
		BROWSER_ROOT + "/BrowserBodyScroll"
	) as ScrollContainer
	var settings_card := lobby.get_node_or_null(
		BROWSER_BODY + "/RoomSettingsCard"
	) as PanelContainer
	var game_mode_selector := lobby.get_node_or_null(
		BROWSER_BODY
		+ "/RoomSettingsCard/SettingsMargin/SettingsVBox/GameModeRow/GameModeSelector"
	) as OptionButton
	var max_players_spin := lobby.get_node_or_null(
		BROWSER_BODY
		+ "/RoomSettingsCard/SettingsMargin/SettingsVBox/PlayerCountRow/MaxPlayersSpinBox"
	) as SpinBox
	var public_tabs := lobby.get_node_or_null(
		BROWSER_BODY + "/TabContainer"
	) as TabContainer
	var public_status := lobby.get_node_or_null(
		BROWSER_ROOT + "/BrowserStatusLabel"
	) as Label
	var public_back := lobby.get_node_or_null(
		BROWSER_ROOT + "/BackButton"
	) as Button
	var lan_panel := lobby.get_node_or_null(
		BROWSER_BODY + "/LanDirectPanel"
	) as VBoxContainer
	var host_ip_label := lobby.get_node_or_null(
		BROWSER_BODY + "/LanDirectPanel/HostIpLabel"
	) as Label
	var port_spin := lobby.get_node_or_null(
		BROWSER_BODY + "/LanDirectPanel/PortRow/PortSpinBox"
	) as SpinBox
	var host_button := lobby.get_node_or_null(
		BROWSER_BODY + "/LanDirectPanel/HostButton"
	) as Button
	var join_ip_input := lobby.get_node_or_null(
		BROWSER_BODY + "/LanDirectPanel/JoinIpInput"
	) as LineEdit
	var join_button := lobby.get_node_or_null(
		BROWSER_BODY + "/LanDirectPanel/JoinButton"
	) as Button
	var lan_status := lobby.get_node_or_null(
		BROWSER_ROOT + "/LanStatusLabel"
	) as Label
	var lan_back := lobby.get_node_or_null(
		BROWSER_ROOT + "/LanBackButton"
	) as Button
	var wait_panel := lobby.get_node_or_null(
		"LobbyCenter/RoomWaitPanel"
	) as PanelContainer
	var wait_player_scroll := lobby.get_node_or_null(
		"LobbyCenter/RoomWaitPanel/MarginContainer/VBoxContainer/PlayerListScroll"
	) as ScrollContainer
	var choose_character_button := lobby.get_node_or_null(
		"LobbyCenter/RoomWaitPanel/MarginContainer/VBoxContainer/ChooseCharacterButton"
	) as Button
	var start_game_button := lobby.get_node_or_null(
		"LobbyCenter/RoomWaitPanel/MarginContainer/VBoxContainer/StartGameButton"
	) as Button
	var leave_room_button := lobby.get_node_or_null(
		"LobbyCenter/RoomWaitPanel/MarginContainer/VBoxContainer/LeaveButton"
	) as Button

	_expect(browser_panel != null, "Room browser must keep its styled panel shell.")
	_expect(browser_scroll != null, "Room browser body must use a native ScrollContainer.")
	_expect(settings_card != null, "Room settings card must remain available.")
	_expect(game_mode_selector != null, "Game-mode selector must remain available.")
	_expect(max_players_spin != null, "Room-capacity selector must remain available.")
	_expect(public_tabs != null, "Public room tabs must remain available.")
	_expect(public_status != null, "Public room status must remain available.")
	_expect(public_back != null, "Public room back action must remain available.")
	_expect(lan_panel != null, "LAN direct-connect content must remain available.")
	_expect(host_ip_label != null, "LAN host IP information must remain available.")
	_expect(port_spin != null, "LAN port selector must remain available.")
	_expect(host_button != null, "LAN host action must remain available.")
	_expect(join_ip_input != null, "LAN host-address input must remain available.")
	_expect(join_button != null, "LAN join action must remain available.")
	_expect(lan_status != null, "LAN status information must remain available.")
	_expect(lan_back != null, "LAN back action must remain available.")
	_expect(wait_panel != null, "Room wait panel must remain available.")
	_expect(wait_player_scroll != null, "Room wait player list must remain scrollable.")
	_expect(choose_character_button != null, "Character selection action must remain available.")
	_expect(start_game_button != null, "Host start action must remain available.")
	_expect(leave_room_button != null, "Leave-room action must remain available.")

	if browser_scroll != null:
		_expect(browser_scroll.follow_focus, "Room browser body must follow keyboard and gamepad focus.")
		_expect(
			browser_scroll.horizontal_scroll_mode == ScrollContainer.SCROLL_MODE_DISABLED,
			"Room browser body must never require horizontal scrolling."
		)
		_expect(
			browser_scroll.vertical_scroll_mode == ScrollContainer.SCROLL_MODE_AUTO,
			"Room browser body must enable vertical scrolling only when content overflows."
		)
	if browser_panel != null:
		_expect(
			_rect_fully_inside(browser_panel.get_global_rect(), lobby.get_global_rect()),
			"Room browser panel must stay fully inside the lobby viewport."
		)
	if browser_scroll != null and public_back != null and lan_back != null:
		_expect(
			not browser_scroll.is_ancestor_of(public_back)
			and not browser_scroll.is_ancestor_of(lan_back),
			"Public and LAN back actions must stay in the fixed footer."
		)

	if public_status != null:
		public_status.text = "正在检查公网大厅；房间与匹配状态会显示在这里。"
	lobby.call("_show_view", PUBLIC_BROWSER_VIEW)
	await process_frame
	await process_frame
	if browser_panel != null and browser_scroll != null and public_tabs != null and public_back != null:
		_expect(public_tabs.visible, "Public room tabs must be visible in the public browser.")
		_expect(public_back.visible, "Public browser back action must be visible.")
		_expect(lan_status != null and not lan_status.visible, "LAN status must hide in public mode.")
		_expect(lan_back != null and not lan_back.visible, "LAN back action must hide in public mode.")
		_expect(
			_rect_fully_inside(public_back.get_global_rect(), browser_panel.get_global_rect()),
			"Public browser back action must remain visible in the fixed footer."
		)

	if lan_status != null:
		lan_status.text = (
			"欢迎进入局域网模式；创建与加入结果会完整显示在这里，"
			+ "较长错误信息也不能遮挡返回按钮。"
		)
	lobby.call("_show_view", LAN_DIRECT_VIEW)
	await process_frame
	await process_frame
	if (
		browser_panel != null
		and browser_scroll != null
		and lan_panel != null
		and join_button != null
		and lan_back != null
	):
		_expect(lan_panel.visible, "LAN controls must be visible in LAN direct-connect mode.")
		_expect(lan_status != null and lan_status.visible, "LAN status must be visible in LAN mode.")
		_expect(lan_back.visible, "LAN back action must be visible in LAN mode.")
		_expect(public_status != null and not public_status.visible, "Public status must hide in LAN mode.")
		_expect(public_back != null and not public_back.visible, "Public back action must hide in LAN mode.")
		_expect(
			_rect_fully_inside(lan_back.get_global_rect(), browser_panel.get_global_rect()),
			"LAN back action must remain visible in the fixed footer."
		)
		var vertical_bar := browser_scroll.get_v_scroll_bar()
		_expect(
			vertical_bar.max_value > vertical_bar.page,
			"LAN content must expose a vertical scroll range when it exceeds the panel."
		)
		join_button.grab_focus()
		await process_frame
		await process_frame
		_expect(
			browser_scroll.scroll_vertical > 0,
			"Focusing the LAN join action must scroll the lower controls into view."
		)
		_expect(
			_control_visible_in_scroll(join_button, browser_scroll),
			"LAN join action must be fully reachable after focus scrolling."
		)

	lobby.call("_show_view", PUBLIC_BROWSER_VIEW)
	await process_frame
	await process_frame
	if browser_scroll != null:
		_expect(
			browser_scroll.scroll_vertical == 0,
			"Switching lobby modes must reset the shared browser scroll to the top."
		)

	lobby.call("_show_view", ROOM_WAIT_VIEW)
	if start_game_button != null:
		start_game_button.visible = true
	await process_frame
	await process_frame
	if wait_panel != null and start_game_button != null and leave_room_button != null:
		_expect(
			_rect_fully_inside(wait_panel.get_global_rect(), lobby.get_global_rect()),
			"Room wait panel must stay fully inside the lobby viewport for hosts."
		)
		_expect(
			_rect_fully_inside(start_game_button.get_global_rect(), wait_panel.get_global_rect()),
			"Host start action must stay visible in the room wait panel."
		)
		_expect(
			_rect_fully_inside(leave_room_button.get_global_rect(), wait_panel.get_global_rect()),
			"Leave-room action must stay visible when the host start action is shown."
		)

	(root.get_node("NetManager") as NetManagerStore).disconnect_from_game()
	lobby.queue_free()
	for _cleanup_frame in range(3):
		await process_frame
	_finish()


func _control_visible_in_scroll(control: Control, scroll: ScrollContainer) -> bool:
	return _rect_fully_inside(control.get_global_rect(), scroll.get_global_rect())


func _rect_fully_inside(inner: Rect2, outer: Rect2) -> bool:
	return (
		inner.position.x >= outer.position.x
		and inner.position.y >= outer.position.y
		and inner.end.x <= outer.end.x
		and inner.end.y <= outer.end.y
	)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("MULTIPLAYER_LOBBY_LAYOUT_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)
