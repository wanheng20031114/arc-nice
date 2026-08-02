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
		NetConstants.PROTOCOL_VERSION == 36,
		"P1B wire 游戏模式接线要求协议v36。"
	)
	_expect(
		net_manager.set_host_game_mode(NetManagerStore.GameMode.TOWER_DEFENSE),
		"A disconnected future Host must be able to select tower defense."
	)
	_expect(
		net_manager.get_current_game_mode() == NetManagerStore.GameMode.TOWER_DEFENSE,
		"Host selection must update authoritative current_game_mode."
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
	_expect(selector != null and selector.item_count == 6, "Lobby must expose all six native mode options.")
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
				NetManagerStore.GameMode.TEST_ARENA_P1,
				NetManagerStore.GameMode.TEST_ARENA_P1B,
				NetManagerStore.GameMode.TEST_ARENA_P2,
				NetManagerStore.GameMode.TEST_ARENA_P3,
			],
			"Lobby selector ids must preserve the complete protocol mode order."
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
			"id": "test-p2-room",
			"name": "Test P2",
			"host_name": "D",
			"player_count": 2,
			"max_players": 3,
			"game_mode": "test_arena_p2",
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
	_expect(room_list.get_child_count() == 6, "Room list must retain all six valid game modes.")
	if room_list.get_child_count() == 6:
		_expect(
			(room_list.get_child(0) as Button).text.contains("普通模式")
			and (room_list.get_child(1) as Button).text.contains("塔防模式")
			and (room_list.get_child(2) as Button).text.contains("测试场景 P1A")
			and (room_list.get_child(3) as Button).text.contains("测试场景 P1B")
			and (room_list.get_child(4) as Button).text.contains("测试场景 P2")
			and (room_list.get_child(5) as Button).text.contains("测试场景 P3"),
			"Room buttons must visibly identify every game mode."
		)

	net_manager.disconnect_from_game()
	net_manager.set("host_peer_id", 1)
	net_manager.call(
		"_rpc_sync_player_list",
		[{
			"id": 1,
			"name": "Host",
			"character_id": "weishidaier",
			"character_confirmed": true,
		}],
		1,
		NetManagerStore.GameMode.TEST_ARENA_P1B,
		3
	)
	_expect(
		net_manager.get_current_game_mode() == NetManagerStore.GameMode.TEST_ARENA_P1B,
		"Reliable Host roster sync must make a client follow the selected P1B mode."
	)
	_expect(
		net_manager.get_room_max_players() == 3,
		"Reliable Host roster sync must carry the room capacity together with the mode."
	)

	lobby.queue_free()
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
