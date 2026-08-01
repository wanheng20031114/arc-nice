extends SceneTree

const WRAPPER_SCENE := preload("res://scene/multiplayer/mp_rogue_route.tscn")
const ROUTE_SCENE := preload("res://scene/test_arena/test_rogue_route_p3.tscn")
const LOBBY_SCENE := preload("res://scene/multiplayer/multiplayer_lobby.tscn")
const NetManagerScript := preload("res://scene/multiplayer/net_manager.gd")
const NetConstants := preload("res://scene/multiplayer/net_constants.gd")
const WRAPPER_SCENE_PATH := "res://scene/multiplayer/mp_rogue_route.tscn"
const ROUTE_SCENE_PATH := "res://scene/test_arena/test_rogue_route_p3.tscn"


class FakeNetManager:
	extends Node

	var host_peer_id := 7
	var host_role := false
	var connection_state := NetManagerStore.ConnectionState.IN_GAME


	func get_host_peer_id() -> int:
		return host_peer_id


	func is_host() -> bool:
		return host_role


	func is_client() -> bool:
		return not host_role


	func is_peer_send_ready(peer_id: int) -> bool:
		return peer_id > 0 and peer_id != host_peer_id


var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_mode_and_loading_contract()
	await _test_lobby_contract()
	await _test_snapshot_and_delta_contract()
	_test_host_start_without_character_confirmation()
	_finish()


func _test_mode_and_loading_contract() -> void:
	_expect(NetConstants.PROTOCOL_VERSION == 32, "P3 wire 模式必须使用协议 v32。")
	_expect(
		NetManagerStore.game_mode_to_key(NetManagerStore.GameMode.TEST_ARENA_P3)
		== "test_arena_p3"
		and NetManagerStore.game_mode_from_key("test_arena_p3")
		== NetManagerStore.GameMode.TEST_ARENA_P3,
		"P3 多人模式必须稳定往返 wire key。"
	)
	var coordinator := root.get_node_or_null("GameLoadCoordinator")
	var net_manager := root.get_node_or_null("NetManager")
	_expect(coordinator != null and net_manager != null, "P3 加载测试需要常驻加载器与 NetManager。")
	if coordinator == null or net_manager == null:
		return
	var manifest := coordinator.call(
		"_build_multiplayer_manifest",
		NetManagerStore.GameMode.TEST_ARENA_P3,
		net_manager
	) as Array
	_expect(
		manifest == [WRAPPER_SCENE_PATH, ROUTE_SCENE_PATH],
		"P3 多人加载清单必须只包含专用包装和路线子场景。"
	)
	_expect(
		str(coordinator.call(
			"_get_multiplayer_entry_path",
			NetManagerStore.GameMode.TEST_ARENA_P3
		)) == WRAPPER_SCENE_PATH
		and str(coordinator.call(
			"_get_multiplayer_runtime_path",
			NetManagerStore.GameMode.TEST_ARENA_P3
		)) == ROUTE_SCENE_PATH
		and str(coordinator.call(
			"_get_multiplayer_campaign_path",
			NetManagerStore.GameMode.TEST_ARENA_P3
		)).is_empty()
		and not bool(coordinator.call("_uses_tower_defense_runtime", ROUTE_SCENE_PATH)),
		"P3 必须绕过 campaign、角色、背包和塔防运行时。"
	)


func _test_lobby_contract() -> void:
	var net_manager := root.get_node_or_null("NetManager") as NetManagerStore
	if net_manager == null:
		return
	net_manager.disconnect_from_game()
	net_manager.set_host_game_mode(NetManagerStore.GameMode.TEST_ARENA_P3)
	var lobby := LOBBY_SCENE.instantiate()
	root.add_child(lobby)
	await process_frame
	var selector := lobby.get_node(
		"LobbyCenter/RoomBrowserPanel/MarginContainer/VBoxContainer/"
		+ "BrowserBodyScroll/BrowserBodyVBox/RoomSettingsCard/"
		+ "SettingsMargin/SettingsVBox/GameModeRow/GameModeSelector"
	) as OptionButton
	var choose_button := lobby.get_node(
		"LobbyCenter/RoomWaitPanel/MarginContainer/VBoxContainer/ChooseCharacterButton"
	) as Button
	var character_overlay := lobby.get_node(
		"PlayerCharacterChoiceOverlay"
	) as PlayerCharacterChoiceOverlay
	_expect(selector.item_count == 5, "多人大厅必须暴露五个模式选项。")
	_expect(
		selector.get_item_id(4) == NetManagerStore.GameMode.TEST_ARENA_P3
		and selector.get_item_text(4).contains("P3")
		and selector.get_item_icon(4) != null,
		"大厅第五项必须是带图标的 P3 肉鸽路线。"
	)
	lobby.call("_update_choose_character_button")
	_expect(not choose_button.visible, "P3 房间不得要求玩家选择角色。")
	net_manager.set_host_game_mode(NetManagerStore.GameMode.TEST_ARENA_P2)
	character_overlay.open(PlayerCharacterRegistry.DEFAULT_CHARACTER_ID)
	await process_frame
	lobby.call(
		"_on_net_game_mode_changed",
		NetManagerStore.GameMode.TEST_ARENA_P2
	)
	_expect(character_overlay.is_open(), "P1/P2/标准模式同步不得误关角色选择。")
	character_overlay.close()
	net_manager.set_host_game_mode(NetManagerStore.GameMode.TEST_ARENA_P3)
	character_overlay.open(PlayerCharacterRegistry.DEFAULT_CHARACTER_ID)
	await process_frame
	lobby.call(
		"_on_net_game_mode_changed",
		NetManagerStore.GameMode.TEST_ARENA_P3
	)
	_expect(not character_overlay.is_open(), "同步为 P3 时必须关闭已抢先打开的选角层。")
	lobby.queue_free()
	await process_frame
	net_manager.disconnect_from_game()


func _test_snapshot_and_delta_contract() -> void:
	var host_route := ROUTE_SCENE.instantiate() as TestRogueRouteP3
	var client_route := ROUTE_SCENE.instantiate() as TestRogueRouteP3
	host_route.auto_initialize = false
	host_route.manage_return_locally = false
	client_route.auto_initialize = false
	client_route.manage_return_locally = false
	root.add_child(host_route)
	root.add_child(client_route)
	await process_frame

	_expect(
		host_route.start_authoritative_session(20260801, false),
		"Host 必须能用固定 seed 生成 P3 路线。"
	)
	client_route.start_client_waiting()
	var layout := host_route.export_layout_snapshot()
	var state := host_route.export_state_snapshot()

	var wrapper := WRAPPER_SCENE.instantiate() as Node
	var wrapped_route := wrapper.get_node("RogueRoute") as TestRogueRouteP3
	_expect(
		not wrapped_route.auto_initialize and not wrapped_route.manage_return_locally,
		"多人包装必须关闭 P3 的自动初始化与本地返回管理。"
	)
	var wrapper_script := wrapper.get_script() as Script
	var rpc_config: Dictionary = wrapper_script.get_rpc_config()
	for rpc_name in [&"net_route_full_snapshot", &"net_route_move_delta"]:
		var config := rpc_config.get(rpc_name, {}) as Dictionary
		_expect(
			int(config.get("transfer_mode", -1))
			== MultiplayerPeer.TRANSFER_MODE_RELIABLE
			and int(config.get("channel", -1)) == 0,
			"P3 完整快照与移动 delta 必须在可靠有序信道同步。"
		)

	var fake_net_manager := FakeNetManager.new()
	wrapper.set("_route", client_route)
	wrapper.set("_net_manager", fake_net_manager)
	_expect(
		not bool(wrapper.call(
			"_apply_full_snapshot_from_peer",
			fake_net_manager.host_peer_id + 1,
			layout,
			state
		))
		and not client_route.is_route_ready(),
		"客户端必须拒绝非 Host 发来的完整快照。"
	)
	_expect(
		bool(wrapper.call(
			"_apply_full_snapshot_from_peer",
			fake_net_manager.host_peer_id,
			layout,
			state
		))
		and client_route.is_route_ready(),
		"客户端必须接受 NetManager 指定 Host 的完整快照。"
	)

	var move_delta := _build_first_move_delta(layout, state)
	var original_client_state := client_route.export_state_snapshot()
	_expect(not move_delta.is_empty(), "P3 测试图必须能找到起点相邻格。")
	if not move_delta.is_empty():
		_expect(
			not bool(wrapper.call(
				"_apply_move_delta_from_peer",
				fake_net_manager.host_peer_id + 1,
				move_delta
			))
			and client_route.export_state_snapshot() == original_client_state,
			"客户端必须拒绝非 Host 发来的移动 delta。"
		)
		_expect(
			bool(wrapper.call(
				"_apply_move_delta_from_peer",
				fake_net_manager.host_peer_id,
				move_delta
			))
			and int(client_route.export_state_snapshot().get("current_node_id", -1))
			== int(move_delta["to_node_id"]),
			"可靠移动 delta 必须精确推进客户端共享位置。"
		)
		client_route.call("_on_route_board_node_pressed", int(move_delta["from_node_id"]))
		_expect(
			int(client_route.get("_pending_node_id")) == -1,
			"只读客户端点击节点不得创建移动确认。"
		)

	wrapper.free()
	fake_net_manager.free()
	host_route.queue_free()
	client_route.queue_free()
	await process_frame


func _build_first_move_delta(layout: Dictionary, state: Dictionary) -> Dictionary:
	var current_node_id := int(state.get("current_node_id", -1))
	var edges := layout.get("edges", PackedInt32Array()) as PackedInt32Array
	var target_node_id := -1
	for edge_offset in range(0, edges.size(), 2):
		var first_node_id := int(edges[edge_offset])
		var second_node_id := int(edges[edge_offset + 1])
		if first_node_id == current_node_id:
			target_node_id = second_node_id
			break
		if second_node_id == current_node_id:
			target_node_id = first_node_id
			break
	if target_node_id < 0:
		return {}
	var visited := state.get("visited_counts", PackedInt32Array()) as PackedInt32Array
	return {
		"schema_version": RogueRouteRuntimeState.SCHEMA_VERSION,
		"layout_hash": str(state.get("layout_hash", "")),
		"revision": int(state.get("revision", -1)) + 1,
		"from_node_id": current_node_id,
		"to_node_id": target_node_id,
		"move_cost": 1,
		"action_points": int(state.get("action_points", 0)) - 1,
		"target_visit_count": int(visited[target_node_id]) + 1,
	}


func _test_host_start_without_character_confirmation() -> void:
	var net_manager := NetManagerScript.new() as NetManagerStore
	root.add_child(net_manager)
	net_manager.net_role = NetManagerStore.NetRole.HOST
	net_manager.connection_state = NetManagerStore.ConnectionState.CONNECTED_IN_LOBBY
	net_manager.current_game_mode = NetManagerStore.GameMode.TEST_ARENA_P3
	net_manager.connected_players = {1: "Host", 2: "Client"}
	net_manager.connected_player_characters = {}
	net_manager.confirmed_character_peers = {}
	net_manager.host_start_game()
	_expect(
		net_manager.connection_state == NetManagerStore.ConnectionState.LOADING_GAME,
		"P3 Host 必须能在没有角色确认的情况下开始加载。"
	)
	root.remove_child(net_manager)
	net_manager.free()


func _finish() -> void:
	if failures.is_empty():
		print("MP_ROGUE_ROUTE_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
