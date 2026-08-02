extends SceneTree

const WRAPPER_SCENE := preload("res://scene/multiplayer/mp_rogue_route.tscn")
const ROUTE_SCENE := preload("res://scene/test_arena/test_rogue_route_p3.tscn")
const LOBBY_SCENE := preload("res://scene/multiplayer/multiplayer_lobby.tscn")
const NetManagerScript := preload("res://scene/multiplayer/net_manager.gd")
const NetConstants := preload("res://scene/multiplayer/net_constants.gd")
const WRAPPER_SCENE_PATH := "res://scene/multiplayer/mp_rogue_route.tscn"
const ROUTE_SCENE_PATH := "res://scene/test_arena/test_rogue_route_p3.tscn"
const WEISHIDAIER_SCENE_PATH := (
	"res://scene/player/weishidaier/player_weishidaier.tscn"
)
const TANGO_SCENE_PATH := "res://scene/player/tango/player_tango.tscn"


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


class ManifestNetManager:
	extends Node


	func get_player_character_map() -> Dictionary:
		return {
			1: PlayerCharacterRegistry.WEISHIDAIER_ID,
			2: PlayerCharacterRegistry.TANGO_ID,
		}


var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_mode_and_loading_contract()
	await _test_lobby_contract()
	await _test_snapshot_and_delta_contract()
	_test_host_requires_character_confirmation()
	_finish()


func _test_mode_and_loading_contract() -> void:
	_expect(NetConstants.PROTOCOL_VERSION == 36, "P1B 模式接线必须使用协议 v36。")
	_expect(
		NetConstants.ROGUE_ROUTE_AVATAR_SYNC_HZ == 12,
		"P3 轻量角色姿态同步必须保持约 12Hz。"
	)
	_expect(
		NetManagerStore.game_mode_to_key(NetManagerStore.GameMode.TEST_ARENA_P3)
		== "test_arena_p3"
		and NetManagerStore.game_mode_from_key("test_arena_p3")
		== NetManagerStore.GameMode.TEST_ARENA_P3,
		"P3 多人模式必须稳定往返 wire key。"
	)
	var coordinator := root.get_node_or_null("GameLoadCoordinator")
	_expect(coordinator != null, "P3 加载测试需要常驻加载器。")
	if coordinator == null:
		return
	var manifest_net_manager := ManifestNetManager.new()
	var manifest := coordinator.call(
		"_build_multiplayer_manifest",
		NetManagerStore.GameMode.TEST_ARENA_P3,
		manifest_net_manager
	) as Array
	_expect(
		manifest == [
			WRAPPER_SCENE_PATH,
			ROUTE_SCENE_PATH,
			WEISHIDAIER_SCENE_PATH,
			TANGO_SCENE_PATH,
		],
		"P3 多人轻量加载清单必须追加所有已选角色场景。"
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
		"P3 必须绕过 campaign、背包和塔防运行时，但保留角色场景。"
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
	_expect(selector.item_count == 6, "多人大厅必须暴露六个模式选项。")
	_expect(
		selector.get_item_id(5) == NetManagerStore.GameMode.TEST_ARENA_P3
		and selector.get_item_text(5).contains("P3")
		and selector.get_item_icon(5) != null,
		"大厅第六项必须是带图标的 P3 肉鸽路线。"
	)
	lobby.call("_update_choose_character_button")
	_expect(choose_button.visible, "P3 房间必须允许玩家选择并确认角色。")
	net_manager.set_host_game_mode(NetManagerStore.GameMode.TEST_ARENA_P2)
	character_overlay.open(PlayerCharacterRegistry.DEFAULT_CHARACTER_ID)
	await process_frame
	lobby.call(
		"_on_net_game_mode_changed",
		NetManagerStore.GameMode.TEST_ARENA_P2
	)
	_expect(character_overlay.is_open(), "P1A/P1B/P2/标准模式同步不得误关角色选择。")
	character_overlay.close()
	net_manager.set_host_game_mode(NetManagerStore.GameMode.TEST_ARENA_P3)
	character_overlay.open(PlayerCharacterRegistry.DEFAULT_CHARACTER_ID)
	await process_frame
	lobby.call(
		"_on_net_game_mode_changed",
		NetManagerStore.GameMode.TEST_ARENA_P3
	)
	_expect(character_overlay.is_open(), "同步为 P3 时必须保留已打开的选角层。")
	character_overlay.close()
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
	var avatar_input_config := rpc_config.get(
		&"net_route_avatar_input", {}
	) as Dictionary
	var avatar_snapshot_config := rpc_config.get(
		&"net_route_avatar_snapshot", {}
	) as Dictionary
	var avatar_correction_config := rpc_config.get(
		&"net_route_avatar_corrected", {}
	) as Dictionary
	_expect(
		int(avatar_input_config.get("transfer_mode", -1))
		== MultiplayerPeer.TRANSFER_MODE_UNRELIABLE_ORDERED
		and int(avatar_input_config.get("channel", -1)) == NetConstants.CH_INPUT,
		"P3 Client 姿态必须走 CH_INPUT unreliable_ordered。"
	)
	_expect(
		int(avatar_snapshot_config.get("transfer_mode", -1))
		== MultiplayerPeer.TRANSFER_MODE_UNRELIABLE_ORDERED
		and int(avatar_snapshot_config.get("channel", -1))
		== NetConstants.CH_PLAYER_STATE,
		"P3 Host 姿态广播必须走 CH_PLAYER_STATE unreliable_ordered。"
	)
	_expect(
		int(avatar_correction_config.get("transfer_mode", -1))
		== MultiplayerPeer.TRANSFER_MODE_RELIABLE
		and int(avatar_correction_config.get("channel", -1)) == NetConstants.CH_AUTH,
		"P3 非法姿态纠正必须走可靠认证信道。"
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
	var invalid_state := state.duplicate(true)
	invalid_state["action_points"] = -1
	_expect(
		bool(wrapper.call("_reserve_full_snapshot_request", 1_000)),
		"客户端首次完整快照请求必须进入等待状态。"
	)
	var retry_at_msec := int(
		wrapper.get("_snapshot_request_retry_at_msec")
	)
	_expect(
		not bool(wrapper.call(
			"_apply_full_snapshot_from_peer",
			fake_net_manager.host_peer_id,
			layout,
			invalid_state
		))
		and bool(wrapper.get("_snapshot_request_pending"))
		and not bool(wrapper.call(
			"_reserve_full_snapshot_request",
			retry_at_msec - 1
		))
		and bool(wrapper.call(
			"_reserve_full_snapshot_request",
			retry_at_msec
		)),
		"Host 坏快照不得锁死客户端；退避窗口结束后必须允许重新请求。"
	)
	_expect(
		bool(wrapper.call(
			"_apply_full_snapshot_from_peer",
			fake_net_manager.host_peer_id,
			layout,
			state
		))
		and client_route.is_route_ready()
		and not bool(wrapper.get("_snapshot_request_pending"))
		and int(wrapper.get("_snapshot_request_retry_at_msec")) == 0
		and int(wrapper.get("_snapshot_request_retry_exponent")) == 0,
		"客户端必须在坏快照后接受 Host 的正确快照并重置退避状态。"
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

	_test_avatar_validation_contract(host_route, wrapper, fake_net_manager)

	wrapper.free()
	fake_net_manager.free()
	host_route.queue_free()
	client_route.queue_free()
	await process_frame


func _test_avatar_validation_contract(
	host_route: TestRogueRouteP3,
	wrapper: Node,
	fake_net_manager: FakeNetManager
) -> void:
	var client_peer_id := fake_net_manager.host_peer_id + 1
	var observer_peer_id := fake_net_manager.host_peer_id + 2
	_expect(
		host_route.configure_multiplayer_players(
			fake_net_manager.host_peer_id,
			{
				fake_net_manager.host_peer_id: "Host",
				client_peer_id: "Client",
				observer_peer_id: "Observer",
			},
			{
				fake_net_manager.host_peer_id:
					PlayerCharacterRegistry.WEISHIDAIER_ID,
				client_peer_id: PlayerCharacterRegistry.TANGO_ID,
				observer_peer_id:
					PlayerCharacterRegistry.WEISHIDAIER_ID,
			}
		),
		"P3 Host 测试必须能按房间名称与角色表创建玩家。"
	)
	var remote_player := host_route.get_player_for_peer(client_peer_id)
	if remote_player == null:
		return
	wrapper.set("_route", host_route)
	fake_net_manager.host_role = true
	var valid_pose := wrapper.call("_encode_avatar_pose", {
		"position": remote_player.global_position,
		"velocity": Vector2.ZERO,
		"facing": remote_player.get_multiplayer_facing_id(),
		"anim_state": remote_player.get_multiplayer_anim_state(),
	}) as PackedInt32Array
	var invalid_pose := wrapper.call("_encode_avatar_pose", {
		"position": Vector2(999999.0, 999999.0),
		"velocity": Vector2.ZERO,
		"facing": 0,
		"anim_state": 0,
	}) as PackedInt32Array
	var route_revision := host_route.get_route_revision()
	_expect(
		not bool(wrapper.call(
			"_accept_client_avatar_pose",
			client_peer_id,
			900,
			route_revision,
			invalid_pose
		)),
		"Host 必须拒绝超出 P3 世界边界的姿态。"
	)
	_expect(
		bool(wrapper.call(
			"_accept_client_avatar_pose",
			client_peer_id,
			1,
			route_revision,
			valid_pose
		)),
		"非法高 sequence 不得锁死后续合法 P3 姿态。"
	)
	_expect(
		not bool(wrapper.call(
			"_reserve_avatar_correction",
			client_peer_id,
			1,
			1000
		)),
		"已接受或过期的 avatar sequence 必须直接丢弃，不得触发可靠纠正。"
	)
	_expect(
		bool(wrapper.call(
			"_reserve_avatar_correction",
			client_peer_id,
			2,
			1000
		))
		and not bool(wrapper.call(
			"_reserve_avatar_correction",
			client_peer_id,
			2,
			1100
		))
		and not bool(wrapper.call(
			"_reserve_avatar_correction",
			client_peer_id,
			3,
			1083
		))
		and bool(wrapper.call(
			"_reserve_avatar_correction",
			client_peer_id,
			3,
			1084
		)),
		"可靠位置纠正必须按 peer 去重并限制在约 12Hz。"
	)
	_test_incremental_avatar_reconnect(
		host_route,
		wrapper,
		client_peer_id,
		observer_peer_id
	)


func _test_incremental_avatar_reconnect(
	host_route: TestRogueRouteP3,
	wrapper: Node,
	old_peer_id: int,
	observer_peer_id: int
) -> void:
	var old_player := host_route.get_player_for_peer(old_peer_id)
	var observer_player := host_route.get_player_for_peer(observer_peer_id)
	if old_player == null or observer_player == null:
		return
	old_player.global_position = host_route.clamp_avatar_position(
		old_player.global_position + Vector2(19.0, 11.0)
	)
	observer_player.global_position = host_route.clamp_avatar_position(
		observer_player.global_position + Vector2(-17.0, 9.0)
	)
	var old_position := old_player.global_position
	var observer_position := observer_player.global_position
	var migrated_peer_id := old_peer_id + 20
	_expect(
		bool(wrapper.call(
			"_migrate_reconnected_player",
			old_peer_id,
			migrated_peer_id,
			"ClientReconnected",
			PlayerCharacterRegistry.TANGO_ID
		))
		and host_route.get_player_for_peer(old_peer_id) == null
		and host_route.get_player_for_peer(migrated_peer_id) == old_player
		and old_player.global_position.is_equal_approx(old_position)
		and host_route.get_player_for_peer(observer_peer_id) == observer_player
		and observer_player.global_position.is_equal_approx(observer_position),
		"仍在场的重连 peer 必须原位迁移节点，且不得重建或传送其他玩家。"
	)
	wrapper.call("_on_player_left", migrated_peer_id)
	_expect(
		host_route.get_player_for_peer(migrated_peer_id) == null
		and host_route.get_player_for_peer(observer_peer_id) == observer_player
		and observer_player.global_position.is_equal_approx(observer_position),
		"player_left 只能移除离线 peer，并保留其他玩家实例与位置。"
	)
	var replacement_peer_id := migrated_peer_id + 1
	_expect(
		bool(wrapper.call(
			"_migrate_reconnected_player",
			migrated_peer_id,
			replacement_peer_id,
			"ClientRestored",
			PlayerCharacterRegistry.TANGO_ID
		)),
		"已收到 player_left 的重连 peer 必须从保存姿态增量补建。"
	)
	var replacement := host_route.get_player_for_peer(replacement_peer_id)
	_expect(
		replacement != null
		and replacement != old_player
		and replacement.global_position.is_equal_approx(old_position)
		and host_route.get_player_for_peer(observer_peer_id) == observer_player
		and observer_player.global_position.is_equal_approx(observer_position),
		"增量补建必须恢复离线玩家原位置，并保持未重连玩家完全不动。"
	)


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


func _test_host_requires_character_confirmation() -> void:
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
		net_manager.connection_state == NetManagerStore.ConnectionState.CONNECTED_IN_LOBBY,
		"P3 Host 必须阻止尚未全员确认角色的房间开始加载。"
	)
	net_manager.connected_player_characters = {
		1: PlayerCharacterRegistry.WEISHIDAIER_ID,
		2: PlayerCharacterRegistry.TANGO_ID,
	}
	net_manager.confirmed_character_peers = {1: true, 2: true}
	net_manager.host_start_game()
	_expect(
		net_manager.connection_state == NetManagerStore.ConnectionState.LOADING_GAME,
		"P3 Host 必须在全员确认角色后开始加载。"
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
