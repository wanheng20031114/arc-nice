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
		NetConstants.PROTOCOL_VERSION == 18,
		"Targeted hydrangea-rain replication requires multiplayer protocol v18."
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
		"LobbyCenter/RoomBrowserPanel/MarginContainer/VBoxContainer/GameModeRow/GameModeSelector"
	) as OptionButton
	var room_mode_label := lobby.get_node_or_null(
		"LobbyCenter/RoomWaitPanel/MarginContainer/VBoxContainer/RoomModeLabel"
	) as Label
	_expect(selector != null and selector.item_count == 2, "Lobby must expose both native mode options.")
	_expect(room_mode_label != null, "Room wait panel must display the synchronized mode.")
	if selector != null:
		_expect(
			selector.get_item_id(selector.selected) == NetManagerStore.GameMode.TOWER_DEFENSE,
			"Lobby selector must follow NetManager state."
		)

	var room_list := lobby.get_node(
		"LobbyCenter/RoomBrowserPanel/MarginContainer/VBoxContainer/TabContainer/RoomListTab/ScrollContainer/RoomListVBox"
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
	])
	_expect(room_list.get_child_count() == 2, "Room list must retain both valid game modes.")
	if room_list.get_child_count() == 2:
		_expect(
			(room_list.get_child(0) as Button).text.contains("普通模式")
			and (room_list.get_child(1) as Button).text.contains("塔防模式"),
			"Room buttons must visibly identify their game mode."
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
		NetManagerStore.GameMode.TOWER_DEFENSE
	)
	_expect(
		net_manager.get_current_game_mode() == NetManagerStore.GameMode.TOWER_DEFENSE,
		"Reliable Host roster sync must make a client follow tower-defense mode."
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
