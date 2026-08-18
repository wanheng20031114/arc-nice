extends SceneTree

const LOBBY_SCENE := preload("res://scene/multiplayer/multiplayer_lobby.tscn")
const NetConstants := preload("res://scene/multiplayer/net_constants.gd")

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var net_manager := root.get_node_or_null("NetManager") as NetManagerStore
	_expect(net_manager != null, "NetManager autoload must exist.")
	if net_manager == null:
		_finish()
		return

	net_manager.disconnect_from_game()
	_expect(
		NetConstants.PROTOCOL_VERSION == 87,
		"协议v87必须保留内容摘要、同局成员身份和既有模式接线。"
	)
	_expect(
		not GameModeCatalog.is_selectable_for_audience(
			GameModeCatalog.MODE_TEST_ARENA_P1B,
			GameModeDefinition.SelectionAudience.RELEASE
		)
		and GameModeCatalog.is_selectable_for_audience(
			GameModeCatalog.MODE_TEST_ARENA_P1B,
			GameModeDefinition.SelectionAudience.DEVELOPMENT
		)
		and GameModeCatalog.is_selectable_for_audience(
			GameModeCatalog.MODE_ROGUE,
			GameModeDefinition.SelectionAudience.RELEASE
		),
		"Release-simulated policy must reject hidden fixtures while admitting Rogue."
	)
	_expect(
		net_manager.set_host_game_mode(NetManagerStore.GameMode.TOWER_DEFENSE),
		"A disconnected future Host must be able to select tower defense."
	)
	_expect(
		net_manager.get_current_game_mode() == NetManagerStore.GameMode.TOWER_DEFENSE,
		"Host selection must update authoritative current_game_mode."
	)
	_expect(
		not net_manager.set_host_game_mode(NetManagerStore.GameMode.TEST_ARENA_P1B)
		and net_manager.get_current_game_mode()
		== NetManagerStore.GameMode.TOWER_DEFENSE,
		"A production Host must reject a known but development-only wire mode."
	)
	_expect(
		net_manager.set_development_host_game_mode_for_fixture(
			NetManagerStore.GameMode.TEST_ARENA_P1B
		)
		and net_manager.get_current_game_mode()
		== NetManagerStore.GameMode.TEST_ARENA_P1B,
		"A debug fixture must opt into development Host admission explicitly."
	)
	net_manager.disconnect_from_game()
	net_manager.call(
		"_set_current_game_mode",
		NetManagerStore.GameMode.TEST_ARENA_P1B
	)
	_expect(
		net_manager.host_create_lan_server(29243, 2) == ERR_UNAVAILABLE
		and not net_manager.is_multiplayer_active(),
		"Disconnect must revoke fixture admission before direct state can create a Host."
	)
	_expect(
		net_manager.set_host_game_mode(NetManagerStore.GameMode.TOWER_DEFENSE),
		"Release Host selection must recover after fixture admission is revoked."
	)

	var lobby := LOBBY_SCENE.instantiate()
	root.add_child(lobby)
	await process_frame
	var selector := lobby.get_node_or_null(
		(
			"LobbyCenter/RoomBrowserPanel/MarginContainer/VBoxContainer/"
			+ "BrowserBodyScroll/BrowserBodyVBox/RoomSettingsCard/"
			+ "SettingsMargin/SettingsVBox/GameModeRow/GameModeSelector"
		)
	) as OptionButton
	var room_mode_label := lobby.get_node_or_null(
		"LobbyCenter/RoomWaitPanel/MarginContainer/VBoxContainer/RoomModeLabel"
	) as Label
	var room_capacity_label := lobby.get_node_or_null(
		"LobbyCenter/RoomWaitPanel/MarginContainer/VBoxContainer/RoomCapacityLabel"
	) as Label
	_expect(selector != null and selector.item_count == 3, "Lobby must expose only the three release modes.")
	_expect(room_mode_label != null, "Room wait panel must display the synchronized mode.")
	_expect(room_capacity_label != null, "Room wait panel must display synchronized room capacity.")
	if selector != null:
		var selector_ids: Array[int] = []
		for item_index in selector.item_count:
			selector_ids.append(selector.get_item_id(item_index))
		_expect(
			selector_ids == [
				NetManagerStore.GameMode.STANDARD,
				NetManagerStore.GameMode.TOWER_DEFENSE,
				NetManagerStore.GameMode.TEST_ARENA_P3,
			],
			"Lobby selector ids must be release policy, not the complete wire registry."
		)
		_expect(
			selector.get_item_id(selector.selected) == NetManagerStore.GameMode.TOWER_DEFENSE,
			"Lobby selector must follow NetManager state."
		)

	var room_list := lobby.get_node(
		"LobbyCenter/RoomBrowserPanel/MarginContainer/VBoxContainer/"
		+ "BrowserBodyScroll/BrowserBodyVBox/TabContainer/"
		+ "RoomListTab/ScrollContainer/RoomListVBox"
	) as VBoxContainer
	lobby.call("_render_public_rooms", [
		{
			"id": "standard-room",
			"name": "Standard",
			"host_name": "A",
			"player_count": 1,
			"max_players": 4,
			"game_mode": "standard",
		},
		{
			"id": "tower-room",
			"name": "Tower",
			"host_name": "B",
			"player_count": 2,
			"max_players": 4,
			"game_mode": "tower_defense",
		},
		{
			"id": "test-p1-room",
			"name": "Test P1A",
			"host_name": "C",
			"player_count": 3,
			"max_players": 6,
			"game_mode": "test_arena_p1",
		},
		{
			"id": "test-p1b-room",
			"name": "Test P1B",
			"host_name": "F",
			"player_count": 2,
			"max_players": 6,
			"game_mode": "test_arena_p1b",
		},
		{
			"id": "test-p1c-room",
			"name": "Test P1C",
			"host_name": "G",
			"player_count": 2,
			"max_players": 6,
			"game_mode": "test_arena_p1c",
		},
		{
			"id": "test-p2-room",
			"name": "Test P2",
			"host_name": "D",
			"player_count": 2,
			"max_players": 3,
			"game_mode": "test_arena_p2",
		},
		{
			"id": "test-p1e-room",
			"name": "Test P1E",
			"host_name": "I",
			"player_count": 2,
			"max_players": 6,
			"game_mode": "test_arena_p1e",
		},
		{
			"id": "test-p1d-room",
			"name": "Test P1D",
			"host_name": "H",
			"player_count": 2,
			"max_players": 6,
			"game_mode": "test_arena_p1d",
		},
		{
			"id": "test-p3-room",
			"name": "Test P3",
			"host_name": "E",
			"player_count": 2,
			"max_players": 4,
			"game_mode": "test_arena_p3",
		},
	])
	_expect(
		room_list.get_child_count() == 3,
		"Public room list must filter development-only room modes."
	)
	if room_list.get_child_count() == 3:
		_expect(
			(room_list.get_child(0) as Button).text.contains("普通模式")
			and (room_list.get_child(1) as Button).text.contains("塔防模式")
			and (room_list.get_child(2) as Button).text.contains("肉鸽模式"),
			"Room buttons must identify only Standard, Tower and Rogue."
		)

	net_manager.disconnect_from_game()
	net_manager.set("host_peer_id", 1)
	net_manager.call(
		"_rpc_sync_player_list",
		[{
			"id": 1,
			"participant_incarnation": 1,
			"name": "Host",
			"character_id": "weishidaier",
			"character_confirmed": true,
			"session_state": int(NetManagerStore.SessionMemberState.ACTIVE),
		}],
		1,
		NetManagerStore.GameMode.TEST_ARENA_P1B,
		3,
		1
	)
	_expect(
		net_manager.get_current_game_mode() == NetManagerStore.GameMode.TEST_ARENA_P1B,
		"Reliable Host roster sync must still decode the frozen P1B wire mode."
	)
	_expect(
		net_manager.get_room_max_players() == 3,
		"Reliable Host roster sync must carry the room capacity together with the mode."
	)
	lobby.queue_free()
	await process_frame
	var runtime_rejections: Array[String] = []
	var rejection_callback := func(reason: String) -> void:
		runtime_rejections.append(reason)
	net_manager.connection_failed.connect(rejection_callback)
	net_manager.set("net_role", NetManagerStore.NetRole.CLIENT)
	net_manager.set(
		"connection_state",
		NetManagerStore.ConnectionState.CONNECTED_IN_LOBBY
	)
	_expect(
		not bool(net_manager.call(
			"_apply_authoritative_start_game",
			int(NetManagerStore.GameMode.TEST_ARENA_P1B),
			1
		))
		and net_manager.connection_state
		== NetManagerStore.ConnectionState.DISCONNECTED
		and net_manager.get_current_game_mode() == NetManagerStore.GameMode.STANDARD
		and runtime_rejections.size() == 1
		and runtime_rejections[0].contains("test_arena_p1b"),
		"A release client must explain and fail-close a hidden-mode start request."
	)
	_expect(
		net_manager.enable_development_runtime_modes_for_fixture(),
		"A debug client fixture must opt into development runtime admission explicitly."
	)
	net_manager.set("net_role", NetManagerStore.NetRole.CLIENT)
	net_manager.set(
		"connection_state",
		NetManagerStore.ConnectionState.CONNECTED_IN_LOBBY
	)
	_expect(
		bool(net_manager.call(
			"_apply_authoritative_start_game",
			int(NetManagerStore.GameMode.TEST_ARENA_P1B),
			2
		))
		and net_manager.connection_state
		== NetManagerStore.ConnectionState.LOADING_GAME
		and net_manager.get_current_game_mode()
		== NetManagerStore.GameMode.TEST_ARENA_P1B
		and runtime_rejections.size() == 1,
		"An explicitly enabled debug client fixture must enter hidden-mode loading."
	)
	net_manager.connection_failed.disconnect(rejection_callback)

	net_manager.disconnect_from_game()
	for _frame in range(3):
		await process_frame
	_finish()


func _finish() -> void:
	if failures.is_empty():
		print("MULTIPLAYER_GAME_MODE_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
