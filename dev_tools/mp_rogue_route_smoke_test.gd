extends SceneTree

const WRAPPER_SCENE := preload("res://scene/multiplayer/mp_rogue_route.tscn")
const ROUTE_SCENE := preload("res://scene/test_arena/test_rogue_route_p3.tscn")
const LOBBY_SCENE := preload("res://scene/multiplayer/multiplayer_lobby.tscn")
const NetManagerScript := preload("res://scene/multiplayer/net_manager.gd")
const NetConstants := preload("res://scene/multiplayer/net_constants.gd")
const MpGameScript := preload("res://scene/multiplayer/mp_game.gd")
const OAK_WAREHOUSE_SCENE := preload(
	"res://scene/plant_defense/oak_warehouse.tscn"
)
const PLANK := preload("res://resources/config/materials/material_plank.tres")
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
	var connected_players: Dictionary = {}
	var connected_player_characters: Dictionary = {}


	func get_host_peer_id() -> int:
		return host_peer_id


	func is_host() -> bool:
		return host_role


	func is_client() -> bool:
		return not host_role


	func is_peer_send_ready(peer_id: int) -> bool:
		return peer_id > 0 and peer_id != host_peer_id


	func get_player_character_map() -> Dictionary:
		return connected_player_characters.duplicate(true)


class ManifestNetManager:
	extends Node


	func get_player_character_map() -> Dictionary:
		return {
			1: PlayerCharacterRegistry.WEISHIDAIER_ID,
			2: PlayerCharacterRegistry.TANGO_ID,
		}


class WarehouseRuntimeStub:
	extends GameTowerDefense

	var warehouses: Dictionary = {}


	func _ready() -> void:
		pass


	func _physics_process(_delta: float) -> void:
		pass


	func get_multiplayer_plant_snapshots() -> Array[Dictionary]:
		var result: Array[Dictionary] = []
		for peer_id_variant in warehouses.keys():
			result.append({"net_id": int(peer_id_variant)})
		return result


	func get_multiplayer_plant_node(net_id: int) -> PlantDefense:
		return warehouses.get(net_id) as PlantDefense


class ReconnectWrapperStub:
	extends MpRogueRoute


	func _ready() -> void:
		pass


	func _exit_tree() -> void:
		pass


var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_mode_and_loading_contract()
	await _test_lobby_contract()
	await _test_snapshot_and_delta_contract()
	await _test_fluorescent_pit_route_integration()
	await _test_warehouse_route_persistence_contract()
	_test_host_requires_character_confirmation()
	_finish()


func _test_mode_and_loading_contract() -> void:
	_expect(
		NetConstants.PROTOCOL_VERSION == 42,
		"协议 v42 必须保留既有遭遇，并隔离荧光坑洞多轮结算。"
	)
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
	manifest_net_manager.free()
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
	var encounter_state := host_route.export_encounter_snapshot()
	var economy_state := host_route.export_encounter_economy_snapshot()
	_expect(
		(encounter_state.get("economy_snapshot", {}) as Dictionary).is_empty()
		and not economy_state.is_empty(),
		"P3 线路快照必须只发送一份独立经济账本，不能在遭遇快照内重复携带。"
	)

	var wrapper := WRAPPER_SCENE.instantiate() as Node
	var wrapped_route := wrapper.get_node("RogueRoute") as TestRogueRouteP3
	_expect(
		not wrapped_route.auto_initialize and not wrapped_route.manage_return_locally,
		"多人包装必须关闭 P3 的自动初始化与本地返回管理。"
	)
	var wrapper_script := wrapper.get_script() as Script
	var rpc_config: Dictionary = wrapper_script.get_rpc_config()
	for rpc_name in [
		&"net_route_full_snapshot",
		&"net_route_move_delta",
		&"net_route_encounter_intro_ack",
		&"net_route_encounter_vote",
		&"net_route_encounter_result_ack",
		&"net_route_encounter_snapshot",
	]:
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
			state,
			encounter_state,
			economy_state
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
			invalid_state,
			encounter_state,
			economy_state
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
			state,
			encounter_state,
			economy_state
		))
		and client_route.is_route_ready()
		and not bool(wrapper.get("_snapshot_request_pending"))
		and int(wrapper.get("_snapshot_request_retry_at_msec")) == 0
		and int(wrapper.get("_snapshot_request_retry_exponent")) == 0,
		"客户端必须在坏快照后接受 Host 的正确快照并重置退避状态。"
	)
	var client_peer_id := fake_net_manager.host_peer_id + 1
	_expect(
		client_route.configure_multiplayer_players(
			client_peer_id,
			{
				fake_net_manager.host_peer_id: "Host",
				client_peer_id: "Client",
			},
			{
				fake_net_manager.host_peer_id:
					PlayerCharacterRegistry.WEISHIDAIER_ID,
				client_peer_id: PlayerCharacterRegistry.TANGO_ID,
			}
		),
		"客户端路线必须能创建本地与远端自由移动角色。"
	)
	var client_local_player := client_route.get_player_for_peer(client_peer_id)
	var client_host_player := client_route.get_player_for_peer(
		fake_net_manager.host_peer_id
	)
	var client_camera := client_route.get("map_camera") as Camera2D
	if (
		client_local_player != null
		and client_host_player != null
		and client_camera != null
	):
		client_local_player.global_position = client_route.clamp_avatar_position(
			client_local_player.global_position + Vector2(23.0, 13.0)
		)
		client_host_player.global_position = client_route.clamp_avatar_position(
			client_host_player.global_position + Vector2(-19.0, 11.0)
		)
		client_route.call(&"_apply_camera_drag", Vector2(-112.0, -56.0))
	await physics_frame
	await process_frame
	var local_position_before_delta := (
		client_local_player.global_position
		if client_local_player != null
		else Vector2.ZERO
	)
	var host_position_before_delta := (
		client_host_player.global_position
		if client_host_player != null
		else Vector2.ZERO
	)
	var camera_local_before_delta := (
		client_camera.position if client_camera != null else Vector2.ZERO
	)
	var camera_global_before_delta := (
		client_camera.global_position if client_camera != null else Vector2.ZERO
	)
	var camera_center_before_delta := (
		client_camera.get_screen_center_position()
		if client_camera != null
		else Vector2.ZERO
	)
	var reapplied_full_snapshot := client_route.apply_full_snapshot(layout, state)
	await physics_frame
	await process_frame
	_expect(
		reapplied_full_snapshot
		and client_local_player != null
		and client_host_player != null
		and client_camera != null
		and client_local_player.global_position.is_equal_approx(
			local_position_before_delta
		)
		and client_host_player.global_position.is_equal_approx(
			host_position_before_delta
		)
		and client_camera.position.is_equal_approx(camera_local_before_delta)
		and client_camera.global_position.is_equal_approx(
			camera_global_before_delta
		)
		and client_camera.get_screen_center_position().is_equal_approx(
			camera_center_before_delta
		),
		"客户端全量重同步只能更新路线数据，不得传送玩家或移动镜头。"
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
		var accepted_host_delta := bool(wrapper.call(
			"_apply_move_delta_from_peer",
			fake_net_manager.host_peer_id,
			move_delta
		))
		await physics_frame
		await process_frame
		_expect(
			accepted_host_delta
			and int(client_route.export_state_snapshot().get("current_node_id", -1))
			== int(move_delta["to_node_id"]),
			"可靠移动 delta 必须精确推进客户端共享逻辑节点。"
		)
		_expect(
			client_local_player != null
			and client_host_player != null
			and client_camera != null
			and client_local_player.global_position.is_equal_approx(
				local_position_before_delta
			)
			and client_host_player.global_position.is_equal_approx(
				host_position_before_delta
			)
			and client_camera.position.is_equal_approx(
				camera_local_before_delta
			)
			and client_camera.global_position.is_equal_approx(
				camera_global_before_delta
			)
			and client_camera.get_screen_center_position().is_equal_approx(
				camera_center_before_delta
			),
			"客户端应用路线 delta 时不得传送任何玩家或移动本地镜头。"
		)
		client_route.call("_on_route_board_node_pressed", int(move_delta["from_node_id"]))
		_expect(
			int(client_route.get("_pending_node_id")) == -1,
			"只读客户端点击节点不得创建移动确认。"
		)

	await _test_encounter_network_contract(
		host_route,
		client_route,
		wrapper,
		fake_net_manager,
		layout
	)

	# 重连背包迁移必须在单一运行时中验证；同进程客户端夹具持有相同 peer
	# 的 Player，会在 Host remap 信号中人为重建旧背包，这不是实际部署拓扑。
	client_route.queue_free()
	await process_frame
	await _test_avatar_validation_contract(host_route, wrapper, fake_net_manager)

	if is_instance_valid(wrapper):
		wrapper.free()
	fake_net_manager.free()
	host_route.queue_free()
	if is_instance_valid(client_route):
		client_route.queue_free()
	await process_frame


func _test_encounter_network_contract(
	host_route: TestRogueRouteP3,
	client_route: TestRogueRouteP3,
	wrapper: Node,
	fake_net_manager: FakeNetManager,
	layout: Dictionary
) -> void:
	var client_local_player := client_route.get_player_for_peer(
		fake_net_manager.host_peer_id + 1
	)
	var client_camera := client_route.get("map_camera") as Camera2D
	var client_player_position_before := (
		client_local_player.global_position
		if client_local_player != null
		else Vector2.ZERO
	)
	var client_camera_position_before := (
		client_camera.position if client_camera != null else Vector2.ZERO
	)
	var client_camera_global_before := (
		client_camera.global_position if client_camera != null else Vector2.ZERO
	)
	var host_session_node := host_route.get_node("EncounterSession")
	var host_economy_node := host_route.get_node("EncounterEconomy")
	var client_session_node := client_route.get_node("EncounterSession")
	var client_economy_node := client_route.get_node("EncounterEconomy")
	var host_session_instance_id := host_session_node.get_instance_id()
	var host_economy_instance_id := host_economy_node.get_instance_id()
	var client_session_instance_id := client_session_node.get_instance_id()
	var client_economy_instance_id := client_economy_node.get_instance_id()
	var client_player_instance_id := (
		client_local_player.get_instance_id()
		if client_local_player != null
		else 0
	)
	var client_camera_instance_id := (
		client_camera.get_instance_id() if client_camera != null else 0
	)
	var node_types := layout.get("node_types", PackedByteArray()) as PackedByteArray
	var node_content_seeds := layout.get(
		"node_content_seeds",
		PackedInt64Array()
	) as PackedInt64Array
	var magical_node_id := -1
	for node_id in node_types.size():
		if (
			int(node_types[node_id])
			== RogueRouteGraph.NodeType.MAGICAL_ENCOUNTER
			and node_id < node_content_seeds.size()
			and RogueEncounterRegistry.select_encounter(
				RogueEncounterRegistry.MAGICAL_ENCOUNTER_POOL,
				int(node_content_seeds[node_id])
			) != RogueEncounterRegistry.FLUORESCENT_PIT
		):
			magical_node_id = node_id
			break
	_expect(
		magical_node_id >= 0,
		"固定 P3 路线必须包含一个旧式单轮神奇遭遇节点。"
	)
	if magical_node_id < 0:
		return
	_expect(
		bool(host_route.call("_try_start_encounter_for_node", magical_node_id)),
		"Host 必须能为未解决的神奇遭遇节点创建唯一 Session。"
	)
	var started := host_route.export_encounter_snapshot()
	var occurrence_key := str(started.get("occurrence_key", ""))
	var initial_revision := int(started.get("revision", -1))
	var participants := started.get("participant_peer_ids", []) as Array
	_expect(
		participants == [0],
		"P3 单人遭遇必须使用 RunState 的真实 peer=0 背包，不能伪装成多人 peer。"
	)
	var participant_peer_id := int(participants[0]) if not participants.is_empty() else -1
	_expect(
		host_route.host_submit_encounter_intro_ack(
			participant_peer_id,
			occurrence_key,
			initial_revision
		),
		"玩家可在 reveal 完成前确认对白。"
	)
	await create_timer(
		RogueEncounterOverlay.COVER_DURATION_SECONDS
		+ RogueEncounterOverlay.REVEAL_DURATION_SECONDS
		+ 0.08
	).timeout
	var voting := host_route.export_encounter_snapshot()
	_expect(
		bool(voting.get("voting_timer_running", false))
		and float(voting.get("remaining_seconds", 0.0)) > 0.0
		and float(voting.get("remaining_seconds", 0.0)) < 60.0,
		"独立遭遇场景的真实 reveal 信号必须使用最新 revision 启动60秒投票计时。"
	)
	var remaining_after_host_reveal := float(
		voting.get("remaining_seconds", 0.0)
	)
	var economy := host_route.export_encounter_economy_snapshot()
	var client_state_before := client_route.export_encounter_snapshot()
	_expect(
		not bool(wrapper.call(
			"_apply_encounter_snapshot_from_peer",
			fake_net_manager.host_peer_id + 1,
			voting,
			economy
		))
		and client_route.export_encounter_snapshot() == client_state_before,
		"客户端必须拒绝非 Host 的遭遇快照。"
	)
	var invalid_economy := economy.duplicate(true)
	invalid_economy["schema_version"] = -1
	var advanced_voting := voting.duplicate(true)
	advanced_voting["revision"] = int(voting.get("revision", 0)) + 1
	_expect(
		not client_route.apply_encounter_snapshot(
			advanced_voting,
			invalid_economy
		)
		and client_route.export_encounter_snapshot() == client_state_before,
		"独立经济快照无效时，客户端不得半提交遭遇 revision 或 phase。"
	)
	_expect(
		bool(wrapper.call(
			"_apply_encounter_snapshot_from_peer",
			fake_net_manager.host_peer_id,
			voting,
			economy
		))
		and client_route.is_encounter_active()
		and bool(client_route.get("_encounter_input_locked"))
		and not (
			client_route.get_node("EncounterSession").export_state().get(
				"economy_snapshot",
				{}
			) as Dictionary
		).is_empty(),
		"Host 遭遇快照必须开启覆盖层并锁定路线输入。"
	)
	await create_timer(
		RogueEncounterOverlay.COVER_DURATION_SECONDS
		+ RogueEncounterOverlay.REVEAL_DURATION_SECONDS
		+ 0.08
	).timeout
	var host_encounter_scene := host_route.get_node(
		"EncounterScene"
	) as RogueEncounterScene
	var client_encounter_scene := client_route.get_node(
		"EncounterScene"
	) as RogueEncounterScene
	_expect(
		host_encounter_scene != null
		and client_encounter_scene != null
		and host_encounter_scene.presentation.visible
		and client_encounter_scene.presentation.visible
		and host_encounter_scene.backdrop_layer.visible
		and client_encounter_scene.backdrop_layer.visible
		and not (host_route.get("world") as RogueRouteWorld).visible
		and not (client_route.get("world") as RogueRouteWorld).visible
		and (host_route.get("world") as RogueRouteWorld).process_mode
		== Node.PROCESS_MODE_DISABLED
		and (client_route.get("world") as RogueRouteWorld).process_mode
		== Node.PROCESS_MODE_DISABLED
		and not (host_route.get("route_hud") as CanvasLayer).visible
		and not (client_route.get("route_hud") as CanvasLayer).visible
		and float(host_route.export_encounter_snapshot().get(
			"remaining_seconds",
			remaining_after_host_reveal
		)) < remaining_after_host_reveal,
		"神奇遭遇必须切入独立表现场景；路线隐藏暂停时权威计时仍须继续。"
	)
	var stale := voting.duplicate(true)
	stale["revision"] = maxi(int(voting.get("revision", 0)) - 1, 0)
	_expect(
		not bool(wrapper.call(
			"_apply_encounter_snapshot_from_peer",
			fake_net_manager.host_peer_id,
			stale,
			economy
		)),
		"客户端必须拒绝倒退的遭遇 revision。"
	)
	var current_revision := int(voting.get("revision", -1))
	var encounter_options := RogueEncounterRegistry.get_option_ids(
		StringName(voting.get("encounter_id", &""))
	)
	_expect(
		not encounter_options.is_empty()
		and host_route.host_submit_encounter_vote(
			participant_peer_id,
			occurrence_key,
			current_revision,
			encounter_options[-1]
		),
		"Host 必须只接受当前 occurrence/revision 的投票。"
	)
	var result := host_route.export_encounter_snapshot()
	var result_pages := result.get("result_pages", []) as Array
	_expect(
		StringName(result.get("phase", &"")) == &"result"
		and bool(result.get("settlement_committed", false))
		and result_pages.size() == 1
		and str(result.get("result_text", ""))
		== str((result_pages[0] as Dictionary).get("text", "")),
		"投票完成后必须得到一次性权威结算及可无损同步的结果页。"
	)
	var result_economy := host_route.export_encounter_economy_snapshot()
	_expect(
		bool(wrapper.call(
			"_apply_encounter_snapshot_from_peer",
			fake_net_manager.host_peer_id,
			result,
			result_economy
		)),
		"客户端必须能先进入自己的结果逐字显示阶段。"
	)
	var session := host_route.get_node("EncounterSession") as RogueEncounterSession
	var result_revision := int(result.get("revision", -1))
	_expect(
		session.add_spectator(99),
		"结果停留期间加入的玩家必须作为旁观者推进权威 revision。"
	)
	host_route.call(
		"_on_encounter_result_hold_completed",
		occurrence_key,
		result_revision
	)
	_expect(
		session.get_phase() == &"completed"
		and host_route.is_encounter_active()
		and not bool(host_route.call(
			"_try_start_encounter_for_node",
			magical_node_id
		)),
		"结果停留期 revision 变化不得锁死退出，退出转场完成前仍须保持输入锁。"
	)
	var completed := host_route.export_encounter_snapshot()
	var completed_economy := host_route.export_encounter_economy_snapshot()
	_expect(
		bool(wrapper.call(
			"_apply_encounter_snapshot_from_peer",
			fake_net_manager.host_peer_id,
			completed,
			completed_economy
		))
		and client_route.is_encounter_active()
		and bool(client_route.get("_encounter_input_locked")),
		"房主 completed 不得强制关闭尚未读完结果的高延迟客户端。"
	)
	var client_overlay := client_encounter_scene.presentation
	client_overlay.typewriter.finish_line()
	await create_timer(RogueEncounterOverlay.RESULT_HOLD_SECONDS + 0.08).timeout
	_expect(
		client_route.is_encounter_active()
		and bool(client_route.get("_encounter_input_locked")),
		"客户端本地结果停留完成后，退出转场期间仍须保持输入锁。"
	)
	await create_timer(
		RogueEncounterOverlay.COVER_DURATION_SECONDS
		+ RogueEncounterOverlay.REVEAL_DURATION_SECONDS
		+ 0.08
	).timeout
	_expect(
		not host_route.is_encounter_active()
		and not bool(host_route.get("_encounter_input_locked"))
		and not client_route.is_encounter_active()
		and not bool(client_route.get("_encounter_input_locked"))
		and (host_route.get("world") as RogueRouteWorld).visible
		and (client_route.get("world") as RogueRouteWorld).visible
		and (host_route.get("route_hud") as CanvasLayer).visible
		and (client_route.get("route_hud") as CanvasLayer).visible
		and not host_encounter_scene.backdrop_layer.visible
		and not client_encounter_scene.backdrop_layer.visible
		and (host_route.get("world") as RogueRouteWorld).process_mode
		== Node.PROCESS_MODE_INHERIT
		and (client_route.get("world") as RogueRouteWorld).process_mode
		== Node.PROCESS_MODE_INHERIT
		and host_session_node.get_instance_id() == host_session_instance_id
		and host_economy_node.get_instance_id() == host_economy_instance_id
		and client_session_node.get_instance_id() == client_session_instance_id
		and client_economy_node.get_instance_id() == client_economy_instance_id
		and client_local_player != null
		and client_local_player.get_instance_id() == client_player_instance_id
		and client_local_player.global_position.is_equal_approx(
			client_player_position_before
		)
		and client_camera != null
		and client_camera.get_instance_id() == client_camera_instance_id
		and client_camera.position.is_equal_approx(
			client_camera_position_before
		)
		and client_camera.global_position.is_equal_approx(
			client_camera_global_before
		)
		and not bool(host_route.call(
			"_try_start_encounter_for_node",
			magical_node_id
		)),
		"退出转场后必须原位恢复路线、玩家与镜头，已解决节点仍不得重复触发。"
	)
	var previous_layout_hash := str(
		host_route.export_layout_snapshot().get("layout_hash", "")
	)
	_expect(
		host_route.start_authoritative_session(20260801, false),
		"Host 必须能以相同 seed 开启一局新的路线会话。"
	)
	var regenerated_layout := host_route.export_layout_snapshot()
	var regenerated_state := host_route.export_state_snapshot()
	var regenerated_encounter := host_route.export_encounter_snapshot()
	var regenerated_economy := host_route.export_encounter_economy_snapshot()
	_expect(
		str(regenerated_layout.get("layout_hash", "")) == previous_layout_hash
		and client_route.apply_full_snapshot(
			regenerated_layout,
			regenerated_state,
			regenerated_encounter,
			regenerated_economy
		)
		and not client_route.is_encounter_active()
		and (
			client_route.export_encounter_snapshot().get(
				"resolved_node_ids",
				[]
			) as Array
		).is_empty(),
		"相同布局 hash 的新局也必须按遭遇 revision 回退重置，不能继承旧节点完成态。"
	)
	var host_board := host_route.get("route_board") as RogueRouteBoard
	var client_board := client_route.get("route_board") as RogueRouteBoard
	_expect(
		host_board != null
		and client_board != null
		and host_board.is_entry_reveal_playing()
		and client_board.is_entry_reveal_playing()
		and bool(host_route.get("_route_reveal_input_locked"))
		and bool(client_route.get("_route_reveal_input_locked")),
		"同布局 hash 的新局也必须让房主与客户端一致重播路线入场动画。"
	)
	if host_board != null:
		host_board.complete_entry_reveal()
	if client_board != null:
		client_board.complete_entry_reveal()
	_expect(
		not bool(host_route.get("_route_reveal_input_locked"))
		and not bool(client_route.get("_route_reveal_input_locked")),
		"中止新局入场动画后不得残留路线输入锁。"
	)


func _test_fluorescent_pit_route_integration() -> void:
	var run_state := root.get_node_or_null("RunState") as RunStateStore
	_expect(run_state != null, "荧光坑洞外层测试需要 RunState。")
	if run_state == null:
		return

	# 放射性分支必须把最终生效后的真实最大生命前后值交给本地结果页，
	# 而不是只显示累计惩罚账本的 0 -> 20。
	run_state.begin_new_run(&"weishidaier", false)
	var radiation_route := ROUTE_SCENE.instantiate() as TestRogueRouteP3
	radiation_route.auto_initialize = false
	radiation_route.manage_return_locally = true
	root.add_child(radiation_route)
	await process_frame
	radiation_route.manage_return_locally = false
	radiation_route.call("_reset_encounter_runtime", true)
	var radiation_session := radiation_route.get_node(
		"EncounterSession"
	) as RogueEncounterSession
	var health_before := radiation_route.player.max_health
	var radiation_seed := _find_fluorescent_pit_seed_for_bucket(
		8_400_000,
		99,
		100
	)
	_expect(
		radiation_session.start_for_node(
			840,
			RogueEncounterRegistry.MAGICAL_ENCOUNTER_POOL,
			radiation_seed,
			[0]
		),
		"P3 路线必须能启动放射性荧光坑洞用例。"
	)
	var radiation_key := radiation_session.get_occurrence_key()
	_expect(
		radiation_route.host_submit_encounter_intro_ack(
			0,
			radiation_key,
			radiation_session.get_revision()
		)
		and radiation_route.host_submit_encounter_vote(
			0,
			radiation_key,
			radiation_session.get_revision(),
			RogueEncounterEconomyCoordinator.OPTION_EXPLORE_PIT
		),
		"放射性坑洞用例必须完成开场确认与下探投票。"
	)
	var radiation_result := radiation_session.export_state()
	var health_after := radiation_route.player.max_health
	var overlay_state := radiation_route.encounter_overlay.state
	var personal_pages := overlay_state.get(
		"personal_result_pages",
		{}
	) as Dictionary
	var local_pages := personal_pages.get(0, []) as Array
	_expect(
		StringName(radiation_result.get("phase", &"")) == &"result"
		and health_after == maxi(health_before - 20, 1)
		and local_pages.size() == 1
		and str((local_pages[0] as Dictionary).get("text", ""))
		== "最大生命：%d → %d" % [health_before, health_after],
		"放射性结果页必须显示本地角色真实最大生命前后值。"
	)
	var radiation_ack_forwarder := func(
		occurrence_key: String,
		result_sequence: int
	) -> void:
		radiation_route.host_submit_encounter_result_ack(
			0,
			occurrence_key,
			result_sequence
		)
	radiation_route.encounter_result_ack_requested.connect(
		radiation_ack_forwarder
	)
	radiation_route.call(
		"_on_encounter_result_ack_requested",
		radiation_key,
		int(radiation_result.get("result_sequence", 0))
	)
	_expect(
		radiation_session.get_phase() == &"completed"
		and bool(radiation_route.get("_encounter_input_locked")),
		"P3 本地 ACK 路由必须以 occurrence + sequence 完成终局，并在退场期间保持锁定。"
	)
	await create_timer(
		RogueEncounterOverlay.COVER_DURATION_SECONDS
		+ RogueEncounterOverlay.REVEAL_DURATION_SECONDS
		+ 0.08
	).timeout
	_expect(
		not bool(radiation_route.get("_encounter_input_locked"))
		and not (
			radiation_route.get_node("RunDefeatOverlay")
			as RogueRunDefeatOverlay
		).visible,
		"非败局强制离开应在转场后恢复路线，且不得显示战败层。"
	)
	radiation_route.queue_free()
	await process_frame

	# 核心归零必须先完成坑洞结果 ACK，再显示阻塞式战败确认。
	run_state.begin_new_run(&"weishidaier", false)
	_expect(
		run_state.set_party_core_health(2, 100),
		"核心归零外层测试应设置 2/100。"
	)
	var failure_route := ROUTE_SCENE.instantiate() as TestRogueRouteP3
	failure_route.auto_initialize = false
	failure_route.manage_return_locally = true
	root.add_child(failure_route)
	await process_frame
	failure_route.manage_return_locally = false
	failure_route.call("_reset_encounter_runtime", true)
	var core_value := failure_route.get_node(
		"HUD/Root/TopBar/TopLayout/TopStats/CoreStat/CoreRow/CoreValue"
	) as Label
	var core_progress := failure_route.get_node(
		"HUD/Root/TopBar/TopLayout/TopStats/CoreStat/CoreProgress"
	) as ProgressBar
	_expect(
		core_value.text == "2/100"
		and is_equal_approx(core_progress.value, 2.0),
		"P3 静态核心 HUD 必须读取共享账本当前值。"
	)
	var failure_session := failure_route.get_node(
		"EncounterSession"
	) as RogueEncounterSession
	var fall_seed := _find_fluorescent_pit_seed_for_bucket(
		8_500_000,
		50,
		80
	)
	_expect(
		failure_session.start_for_node(
			850,
			RogueEncounterRegistry.MAGICAL_ENCOUNTER_POOL,
			fall_seed,
			[0]
		),
		"P3 路线必须能启动踩空归零用例。"
	)
	var failure_key := failure_session.get_occurrence_key()
	_expect(
		failure_route.host_submit_encounter_intro_ack(
			0,
			failure_key,
			failure_session.get_revision()
		)
		and failure_route.host_submit_encounter_vote(
			0,
			failure_key,
			failure_session.get_revision(),
			RogueEncounterEconomyCoordinator.OPTION_EXPLORE_PIT
		),
		"踩空归零用例必须完成开场确认与下探投票。"
	)
	var failure_result := failure_session.export_state()
	_expect(
		bool(failure_result.get("run_failed", false))
		and core_value.text == "0/100"
		and is_zero_approx(core_progress.value),
		"共享核心 2 -> 0 时 P3 HUD 必须同步归零且 Session 标记败局。"
	)
	var failure_ack_forwarder := func(
		occurrence_key: String,
		result_sequence: int
	) -> void:
		failure_route.host_submit_encounter_result_ack(
			0,
			occurrence_key,
			result_sequence
		)
	failure_route.encounter_result_ack_requested.connect(failure_ack_forwarder)
	failure_route.call(
		"_on_encounter_result_ack_requested",
		failure_key,
		int(failure_result.get("result_sequence", 0))
	)
	await create_timer(
		RogueEncounterOverlay.COVER_DURATION_SECONDS
		+ RogueEncounterOverlay.REVEAL_DURATION_SECONDS
		+ 0.08
	).timeout
	var defeat_overlay := failure_route.get_node(
		"RunDefeatOverlay"
	) as RogueRunDefeatOverlay
	_expect(
		defeat_overlay.visible
		and bool(failure_route.get("_encounter_input_locked"))
		and defeat_overlay.title_label.text == "战败"
		and defeat_overlay.reason_label.text == "核心生命值归0，游戏结束"
		and defeat_overlay.confirm_button.text == "返回多人大厅",
		"核心归零必须在结果页完成后显示多人战败确认并继续锁定路线。"
	)
	var return_events := {"count": 0}
	failure_route.return_requested.connect(
		func() -> void:
			return_events["count"] = int(return_events["count"]) + 1
	)
	defeat_overlay.confirm_button.pressed.emit()
	_expect(
		int(return_events["count"]) == 1 and not defeat_overlay.visible,
		"多人战败确认必须只请求一次返回大厅。"
	)
	defeat_overlay.show_defeat(false)
	_expect(
		defeat_overlay.confirm_button.text == "返回主菜单",
		"同一战败层在单人模式必须明确返回主菜单。"
	)
	defeat_overlay.hide_immediately()
	failure_route.queue_free()
	await process_frame


func _find_fluorescent_pit_seed_for_bucket(
	start_seed: int,
	minimum_bucket: int,
	exclusive_maximum_bucket: int
) -> int:
	for offset in 100_000:
		var candidate := start_seed + offset
		if RogueEncounterRegistry.select_encounter(
			RogueEncounterRegistry.MAGICAL_ENCOUNTER_POOL,
			candidate
		) != RogueEncounterRegistry.FLUORESCENT_PIT:
			continue
		var bucket := RogueEncounterRandom.choose_index(
			candidate,
			&"fluorescent_pit_outcome|round:0",
			100
		)
		if bucket >= minimum_bucket and bucket < exclusive_maximum_bucket:
			return candidate
	push_error("无法为 P3 外层测试找到荧光坑洞概率桶 seed。")
	return start_seed


func _test_avatar_validation_contract(
	host_route: TestRogueRouteP3,
	wrapper: Node,
	fake_net_manager: FakeNetManager
) -> void:
	var client_peer_id := fake_net_manager.host_peer_id + 1
	var observer_peer_id := fake_net_manager.host_peer_id + 2
	fake_net_manager.host_role = true
	fake_net_manager.connected_players = {
		fake_net_manager.host_peer_id: "Host",
		client_peer_id: "Client",
		observer_peer_id: "Observer",
	}
	fake_net_manager.connected_player_characters = {
		fake_net_manager.host_peer_id:
			PlayerCharacterRegistry.WEISHIDAIER_ID,
		client_peer_id: PlayerCharacterRegistry.TANGO_ID,
		observer_peer_id: PlayerCharacterRegistry.WEISHIDAIER_ID,
	}
	var configure_wrapper := ReconnectWrapperStub.new()
	configure_wrapper.set("_route", host_route)
	configure_wrapper.set("_net_manager", fake_net_manager)
	root.add_child(configure_wrapper)
	var shared_run_state := root.get_node_or_null("RunState") as RunStateStore
	_expect(
		bool(configure_wrapper.call("_configure_route_players"))
		and shared_run_state != null
		and shared_run_state.active_multiplayer_peer_id
		== fake_net_manager.host_peer_id,
		"P3 配置玩家后必须按房间角色表创建节点并绑定本机活动背包。"
	)
	configure_wrapper.free()
	var remote_player := host_route.get_player_for_peer(client_peer_id)
	if remote_player == null:
		return
	wrapper.set("_route", host_route)
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
	await _test_incremental_avatar_reconnect(
		host_route,
		wrapper,
		fake_net_manager,
		client_peer_id,
		observer_peer_id
	)


func _test_incremental_avatar_reconnect(
	host_route: TestRogueRouteP3,
	wrapper: Node,
	fake_net_manager: FakeNetManager,
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
	# 该离树包装场景只用于前面的 RPC/姿态测试；其子玩家会订阅 RunState，
	# 在背包迁移前释放，避免用未入树的测试实例响应 inventory_changed。
	wrapper.free()
	var shared_run_state := root.get_node_or_null("RunState") as RunStateStore
	if shared_run_state == null:
		_expect(false, "重连测试必须取得常驻 RunState。")
		return
	shared_run_state.begin_new_run(&"weishidaier", false)
	shared_run_state.ensure_multiplayer_peer_state(old_peer_id)
	shared_run_state.set_active_multiplayer_peer(old_peer_id)
	_expect(
		shared_run_state.try_add_item_count_for_peer(old_peer_id, PLANK, 3),
		"重连夹具必须先写入旧 peer 背包。"
	)
	var old_inventory_revision: int = (
		shared_run_state.get_inventory_revision_for_peer(old_peer_id)
	)
	var reconnect_wrapper := ReconnectWrapperStub.new()
	reconnect_wrapper.set("_route", host_route)
	reconnect_wrapper.set("_net_manager", fake_net_manager)
	root.add_child(reconnect_wrapper)
	var live_reconnect_succeeded := bool(reconnect_wrapper.call(
		"_finish_player_reconnect",
		old_peer_id,
		migrated_peer_id,
		"ClientReconnected",
		PlayerCharacterRegistry.TANGO_ID
	))
	_expect(
		live_reconnect_succeeded
		and host_route.get_player_for_peer(old_peer_id) == null
		and host_route.get_player_for_peer(migrated_peer_id) == old_player,
		"仍在场的重连 peer 必须原位迁移同一角色节点。"
	)
	_expect(
		not shared_run_state.has_multiplayer_peer_state(old_peer_id)
		and shared_run_state.has_multiplayer_peer_state(migrated_peer_id)
		and shared_run_state.get_inventory_item_total_for_peer(
			migrated_peer_id,
			PLANK
		) == 3
		and shared_run_state.get_inventory_revision_for_peer(migrated_peer_id)
		== old_inventory_revision,
		"重连必须把旧 peer 的背包内容与 revision 原子迁移到新 peer。"
	)
	_expect(
		shared_run_state.active_multiplayer_peer_id == migrated_peer_id,
		"本机 peer 重连后通用背包 API 必须跟随迁移到新身份。"
	)
	_expect(
		old_player.global_position.is_equal_approx(old_position)
		and host_route.get_player_for_peer(observer_peer_id) == observer_player
		and observer_player.global_position.is_equal_approx(observer_position),
		"重连不得传送当前玩家或其他玩家。"
	)
	reconnect_wrapper.call("_on_player_left", migrated_peer_id)
	await process_frame
	_expect(
		host_route.get_player_for_peer(migrated_peer_id) == null
		and host_route.get_player_for_peer(observer_peer_id) == observer_player
		and observer_player.global_position.is_equal_approx(observer_position),
		"player_left 只能移除离线 peer，并保留其他玩家实例与位置。"
	)
	var replacement_peer_id := migrated_peer_id + 1
	_expect(
		bool(reconnect_wrapper.call(
			"_finish_player_reconnect",
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
		and not shared_run_state.has_multiplayer_peer_state(migrated_peer_id)
		and shared_run_state.get_inventory_item_total_for_peer(
			replacement_peer_id,
			PLANK
		) == 3
		and shared_run_state.active_multiplayer_peer_id == replacement_peer_id
		and replacement.global_position.is_equal_approx(old_position)
		and host_route.get_player_for_peer(observer_peer_id) == observer_player
		and observer_player.global_position.is_equal_approx(observer_position),
		"增量补建必须恢复离线玩家原位置，并保持未重连玩家完全不动。"
	)
	var collision_peer_id := replacement_peer_id + 1
	shared_run_state.ensure_multiplayer_peer_state(collision_peer_id)
	_expect(
		not bool(reconnect_wrapper.call(
			"_migrate_reconnected_run_state",
			replacement_peer_id,
			collision_peer_id
		))
		and shared_run_state.has_multiplayer_peer_state(replacement_peer_id)
		and shared_run_state.has_multiplayer_peer_state(collision_peer_id)
		and host_route.get_player_for_peer(replacement_peer_id) == replacement,
		"目标 peer 已有背包时必须原子拒绝迁移，并在迁移角色与遭遇前中止。"
	)
	_expect(
		shared_run_state.try_add_item_count_for_peer(
			collision_peer_id,
			PLANK,
			2
		),
		"客户端冲突夹具必须预建 new peer 背包。"
	)
	var source_revision := (
		shared_run_state.get_inventory_revision_for_peer(replacement_peer_id)
	)
	fake_net_manager.host_role = false
	_expect(
		bool(reconnect_wrapper.call(
			"_finish_player_reconnect",
			replacement_peer_id,
			collision_peer_id,
			"ClientRemapped",
			PlayerCharacterRegistry.TANGO_ID
		))
		and not shared_run_state.has_multiplayer_peer_state(replacement_peer_id)
		and shared_run_state.has_multiplayer_peer_state(collision_peer_id)
		and shared_run_state.get_inventory_item_total_for_peer(
			collision_peer_id,
			PLANK
		) == 3
		and shared_run_state.get_inventory_revision_for_peer(collision_peer_id)
		== source_revision
		and shared_run_state.active_multiplayer_peer_id == collision_peer_id
		and shared_run_state.get_party_item_total(PLANK) == 3
		and shared_run_state.has_party_item(PLANK),
		"既有客户端必须用 old peer 状态替换预建 new peer，且默认全队统计不得双计。"
	)
	var reconnecting_client_old_peer_id := collision_peer_id + 100
	shared_run_state.ensure_multiplayer_peer_state(
		reconnecting_client_old_peer_id
	)
	_expect(
		shared_run_state.try_add_item_count_for_peer(
			reconnecting_client_old_peer_id,
			PLANK,
			5
		),
		"重连者本人夹具必须保留一个未收到身份通知的 old peer。"
	)
	fake_net_manager.connected_players = {
		fake_net_manager.host_peer_id: "Host",
		observer_peer_id: "Observer",
		collision_peer_id: "ReconnectedClient",
	}
	var authoritative_economy := (
		host_route.get_node("EncounterEconomy")
		as RogueEncounterEconomyCoordinator
	).export_snapshot([collision_peer_id])
	_expect(
		bool(reconnect_wrapper.call(
			"_apply_full_snapshot_from_peer",
			fake_net_manager.host_peer_id,
			host_route.export_layout_snapshot(),
			host_route.export_state_snapshot(),
			host_route.export_encounter_snapshot(),
			authoritative_economy
		))
		and not shared_run_state.has_multiplayer_peer_state(
			reconnecting_client_old_peer_id
		)
		and shared_run_state.get_inventory_item_total_for_peer(
			collision_peer_id,
			PLANK
		) == 3
		and shared_run_state.get_inventory_revision_for_peer(collision_peer_id)
		== source_revision
		and shared_run_state.active_multiplayer_peer_id == collision_peer_id
		and shared_run_state.get_party_item_total(PLANK) == 3,
		"未收到 old→new 通知的重连者本人必须在首次 Host 全量后清除旧键且不重复统计。"
	)
	reconnect_wrapper.queue_free()


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


func _test_warehouse_route_persistence_contract() -> void:
	const WAREHOUSE_NET_ID := 41
	var run_state := RunStateStore.new()
	run_state.begin_new_run(&"weishidaier", false)
	var net_manager := FakeNetManager.new()
	net_manager.host_role = true
	net_manager.host_peer_id = 1
	var runtime := WarehouseRuntimeStub.new()
	var source := OAK_WAREHOUSE_SCENE.instantiate() as OakWarehouse
	root.add_child(source)
	await process_frame
	source.configure_multiplayer_storage(WAREHOUSE_NET_ID, 1, true)
	var slots: Array[Dictionary] = []
	for slot_index in RunStateStore.INVENTORY_CAPACITY:
		slots.append({
			"slot_index": slot_index,
			"config_path": PLANK.resource_path if slot_index == 0 else "",
			"stack_count": 6 if slot_index == 0 else 0,
		})
	_expect(
		source.apply_storage_snapshot({
			"warehouse_net_id": WAREHOUSE_NET_ID,
			"revision": 1,
			"slots": slots,
		}),
		"仓库持久化夹具必须能写入正 network id 的存储快照。"
	)
	runtime.warehouses = {WAREHOUSE_NET_ID: source}
	var mp_game := MpGameScript.new()
	mp_game.net_manager = net_manager
	mp_game.run_state = run_state
	mp_game.game = runtime
	_expect(
		bool(mp_game.call(
			"_persist_authoritative_warehouse_snapshot",
			source,
			WAREHOUSE_NET_ID
		))
		and run_state.get_shared_warehouse_item_total(PLANK) == 6,
		"Host 仓库存储变化必须进入跨场景共享账本。"
	)
	var restored := OAK_WAREHOUSE_SCENE.instantiate() as OakWarehouse
	root.add_child(restored)
	await process_frame
	restored.configure_multiplayer_storage(WAREHOUSE_NET_ID, 1, true)
	_expect(
		bool(mp_game.call(
			"_restore_authoritative_warehouse_from_ledger",
			restored,
			WAREHOUSE_NET_ID
		))
		and restored.get_storage_item_total(PLANK) == 6,
		"返回战斗并完成仓库网络配置后必须恢复路线期间保留的账本。"
	)
	_expect(
		bool(mp_game.call("_capture_shared_warehouse_ledger"))
		and run_state.get_shared_warehouse_item_total(PLANK) == 6,
		"离开战斗场景前必须从当前有效正 id 仓库全量刷新账本。"
	)
	restored.queue_free()
	source.queue_free()
	mp_game.free()
	runtime.free()
	net_manager.free()
	run_state.free()
	await process_frame


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
