extends SceneTree

const WRAPPER_SCENE := preload("res://scene/multiplayer/mp_rogue_route.tscn")
const ROUTE_SCENE := preload("res://scene/game_modes/rogue/route/rogue_route_game.tscn")
const LOBBY_SCENE := preload("res://scene/multiplayer/multiplayer_lobby.tscn")
const NetManagerScript := preload("res://scene/multiplayer/net_manager.gd")
const NetConstants := preload("res://scene/multiplayer/net_constants.gd")
const MP_GAME_SCRIPT := preload("res://scene/multiplayer/mp_game.gd")
const MP_WORLD_FLOW_SCRIPT := preload(
	"res://scene/multiplayer/world_flow/mp_world_flow_coordinator.gd"
)
const OAK_WAREHOUSE_SCENE := preload(
	"res://scene/plant_defense/oak_warehouse.tscn"
)
const PLANK := preload("res://resources/config/materials/material_plank.tres")
const WRAPPER_SCENE_PATH := "res://scene/multiplayer/mp_rogue_route.tscn"
const ROUTE_SCENE_PATH := "res://scene/game_modes/rogue/route/rogue_route_game.tscn"
const WEISHIDAIER_SCENE_PATH := (
	"res://scene/player/weishidaier/player_weishidaier.tscn"
)
const TANGO_SCENE_PATH := "res://scene/player/tango/player_tango.tscn"
const BRIEFING_SEED_SEARCH_LIMIT := 4096


class FakeNetManager:
	extends NetManagerStore

	var host_role := false
	var gameplay_admitted := true
	var fixture_membership_revision := 1
	var fixture_stable_participant_keys: Dictionary[int, String] = {}
	var fixture_pending_reconnect_old_peers: Dictionary[int, int] = {}
	var fixture_runtime_projection_reports: Array[Dictionary] = []


	func _init() -> void:
		host_peer_id = 7
		connection_state = NetManagerStore.ConnectionState.IN_GAME


	func get_host_peer_id() -> int:
		return host_peer_id


	func is_host() -> bool:
		return host_role


	func is_client() -> bool:
		return not host_role


	func is_peer_send_ready(peer_id: int) -> bool:
		return peer_id > 0 and peer_id != host_peer_id


	func is_gameplay_ingress_admitted(peer_id: int) -> bool:
		return gameplay_admitted and peer_id > 0


	func get_player_character_map() -> Dictionary:
		return connected_player_characters.duplicate(true)


	func get_stable_participant_key(peer_id: int) -> String:
		if peer_id <= 0:
			return ""
		return fixture_stable_participant_keys.get(
			peer_id,
			"test-participant:%d" % peer_id
		)


	func is_session_member_active(peer_id: int) -> bool:
		return (
			peer_id > 0
			and connected_players.has(peer_id)
			and not fixture_pending_reconnect_old_peers.has(peer_id)
		)


	func is_session_member_reconnecting(peer_id: int) -> bool:
		return (
			peer_id > 0
			and connected_players.has(peer_id)
			and fixture_pending_reconnect_old_peers.has(peer_id)
		)


	func has_session_member(peer_id: int) -> bool:
		return peer_id > 0 and connected_players.has(peer_id)


	func get_session_member_peer_ids() -> PackedInt32Array:
		var peer_ids := PackedInt32Array()
		for raw_peer_id in connected_players.keys():
			var peer_id := int(raw_peer_id)
			if peer_id > 0:
				peer_ids.append(peer_id)
		peer_ids.sort()
		return peer_ids


	func get_session_membership_revision() -> int:
		return fixture_membership_revision


	func begin_fixture_reconnect(old_peer_id: int, new_peer_id: int) -> bool:
		if (
			old_peer_id <= 0
			or new_peer_id <= 0
			or old_peer_id == new_peer_id
			or not connected_players.has(new_peer_id)
			or fixture_pending_reconnect_old_peers.has(new_peer_id)
		):
			return false
		fixture_pending_reconnect_old_peers[new_peer_id] = old_peer_id
		return true


	func cancel_fixture_reconnect(new_peer_id: int) -> void:
		fixture_pending_reconnect_old_peers.erase(new_peer_id)


	func report_reconnected_runtime_projection(
		old_peer_id: int,
		new_peer_id: int,
		outcome: MultiplayerReconnectTypes.RuntimeProjectionOutcome
	) -> bool:
		if (
			not host_role
			or int(fixture_pending_reconnect_old_peers.get(new_peer_id, 0))
			!= old_peer_id
			or outcome not in [
				MultiplayerReconnectTypes.RuntimeProjectionOutcome.RESTORED,
				MultiplayerReconnectTypes.RuntimeProjectionOutcome.SUSPENDED,
			]
		):
			return false
		fixture_runtime_projection_reports.append({
			"old_peer_id": old_peer_id,
			"new_peer_id": new_peer_id,
			"outcome": int(outcome),
			"membership_revision": fixture_membership_revision,
		})
		fixture_pending_reconnect_old_peers.erase(new_peer_id)
		return true


class ManifestNetManager:
	extends NetManagerStore


	func get_player_character_map() -> Dictionary:
		return {
			1: PlayerCharacterRegistry.WEISHIDAIER_ID,
			2: PlayerCharacterRegistry.TANGO_ID,
		}


class WarehouseRuntimeStub:
	extends TowerDefenseGame

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


class WarehouseTowerModeAdapterStub:
	extends TowerDefenseMultiplayerModeAdapter

	var warehouses: Dictionary = {}


	func get_multiplayer_plant_snapshots() -> Array[Dictionary]:
		var result: Array[Dictionary] = []
		for peer_id_variant in warehouses.keys():
			result.append({"net_id": int(peer_id_variant)})
		return result


	func get_multiplayer_plant_node(net_id: int) -> PlantDefense:
		return warehouses.get(net_id) as PlantDefense


class RogueFlowGateAdapterStub:
	extends TowerDefenseMultiplayerModeAdapter

	var exploration_active := false
	var presentation_pending := false
	var fate_interlude_active := false
	var terminal_state := false


	func is_rogue_exploration_active() -> bool:
		return exploration_active


	func is_rogue_tower_world_suspended() -> bool:
		return exploration_active or presentation_pending


	func is_fate_interlude_active() -> bool:
		return fate_interlude_active


	func is_terminal_combat_state() -> bool:
		return terminal_state


class TowerGateSessionProbe:
	extends MpSessionCoordinator

	var update_calls := 0


	func update_transport(_delta: float) -> void:
		update_calls += 1


class RogueFlowWorldProbe:
	extends MP_WORLD_FLOW_SCRIPT

	var received_states: Array[int] = []


	func receive_flow_state(
		_step_id: StringName,
		state: int,
		_countdown_seconds: int
	) -> void:
		received_states.append(state)


class TowerGatePlayerProbe:
	extends MpPlayerCoordinator

	var state_calls := 0
	var dash_calls := 0


	func handle_client_player_state(
		_sender_id: int,
		_sequence: int,
		_reported_position: Vector2,
		_reported_velocity: Vector2,
		_move_input: Vector2,
		_shoot_input: Vector2,
		_buttons: int,
		_dash_request_sequence: int,
		_dash_direction: Vector2,
		_dash_start_move_input: Vector2
	) -> void:
		state_calls += 1


	func handle_dash_request(
		_sender_id: int,
		_dash_request_sequence: int,
		_direction: Vector2,
		_start_move_input: Vector2
	) -> void:
		dash_calls += 1


class TowerGateWorldProbe:
	extends MpTowerWorldCoordinator

	var placement_calls := 0


	func handle_remote_plant_placement_request(
		_sender_id: int,
		_request_id: int,
		_plant_id: String,
		_anchor: Vector2i
	) -> void:
		placement_calls += 1


	func handle_remote_inventory_plant_placement_request(
		_sender_id: int,
		_request_id: int,
		_plant_id: String,
		_anchor: Vector2i,
		_slot_index: int,
		_expected_inventory_revision: int,
		_item_config_path: String
	) -> void:
		placement_calls += 1


class TowerGateEconomyProbe:
	extends MpTowerEconomyCoordinator

	var request_calls := 0


	func handle_authoritative_warehouse_command(
		_peer_id: int,
		_raw_command: Dictionary
	) -> void:
		request_calls += 1


	func handle_authoritative_warehouse_snapshot_request(
		_sender_id: int,
		_warehouse_net_id: int
	) -> bool:
		request_calls += 1
		return true


	func handle_authoritative_production_command(
		_peer_id: int,
		_raw_command: Dictionary
	) -> void:
		request_calls += 1


	func handle_authoritative_production_snapshot_request(
		_sender_id: int,
		_building_net_id: int
	) -> bool:
		request_calls += 1
		return true


	func handle_authoritative_research_command(
		_peer_id: int,
		_raw_command: Dictionary
	) -> void:
		request_calls += 1


class TowerGateTransactionsProbe:
	extends MpTransactionsCoordinator

	var admission_calls := 0
	var local_request_calls := 0
	var remote_request_calls := 0


	func request_upgrade(_stat_type: int) -> void:
		local_request_calls += 1


	func request_inventory_item_use(_slot_index: int) -> void:
		local_request_calls += 1


	func request_inventory_item_discard(_slot_index: int) -> void:
		local_request_calls += 1


	func request_simple_crafting(
		_recipe_id: StringName,
		_ui_request_token: int
	) -> void:
		local_request_calls += 1


	func request_skill1_purchase() -> void:
		local_request_calls += 1


	func handle_remote_upgrade_selection(
		_sender_id: int,
		_stat_type: int
	) -> void:
		remote_request_calls += 1


	func handle_remote_inventory_item_use_request(
		_sender_id: int,
		_slot_index: int,
		_expected_inventory_revision: int
	) -> void:
		remote_request_calls += 1


	func handle_remote_inventory_item_discard_request(
		_sender_id: int,
		_slot_index: int,
		_expected_inventory_revision: int
	) -> void:
		remote_request_calls += 1


	func handle_remote_simple_crafting_request(
		_sender_id: int,
		_request_id: int,
		_recipe_id: String,
		_expected_inventory_revision: int
	) -> void:
		remote_request_calls += 1


	func handle_remote_skill1_purchase_request(_sender_id: int) -> void:
		remote_request_calls += 1


	func consume_remote_transaction_admission(
		_peer_id: int,
		_now_seconds: float = -1.0
	) -> bool:
		admission_calls += 1
		return true


class TowerGateMerchantProbe:
	extends MpMerchantTransactionsCoordinator

	var local_request_calls := 0
	var remote_request_calls := 0


	func request_luoxi_collectible_offer() -> void:
		local_request_calls += 1


	func request_luoxi_collectible_choice(
		_choice_index: int,
		_offer_revision: int = 0
	) -> void:
		local_request_calls += 1


	func request_luoxi_collectible_refresh(_offer_revision: int = 0) -> void:
		local_request_calls += 1


	func request_luoxi_special_game_start() -> void:
		local_request_calls += 1


	func request_luoxi_special_game_card_reveal(
		_session_revision: int,
		_card_index: int
	) -> void:
		local_request_calls += 1


	func request_luoxi_special_game_finish(_session_revision: int) -> void:
		local_request_calls += 1


	func handle_remote_luoxi_collectible_offer_requested(
		_peer_id: int
	) -> void:
		remote_request_calls += 1


	func handle_remote_luoxi_collectible_choice_requested(
		_peer_id: int,
		_choice_index: int,
		_offer_revision: int
	) -> void:
		remote_request_calls += 1


	func handle_remote_luoxi_collectible_refresh_requested(
		_peer_id: int,
		_offer_revision: int
	) -> void:
		remote_request_calls += 1


	func handle_remote_luoxi_special_game_start_requested(
		_peer_id: int
	) -> void:
		remote_request_calls += 1


	func handle_remote_luoxi_special_game_card_reveal_requested(
		_peer_id: int,
		_session_revision: int,
		_card_index: int
	) -> void:
		remote_request_calls += 1


	func handle_remote_luoxi_special_game_finish_requested(
		_peer_id: int,
		_session_revision: int
	) -> void:
		remote_request_calls += 1


class TowerGateMpGameProbe:
	extends MP_GAME_SCRIPT

	var host_physics_tick_calls := 0
	var interpolation_calls := 0
	var outbound_rpc_calls := 0


	func _ready() -> void:
		pass


	func _get_rpc_sender_id() -> int:
		return 42


	func _update_recent_event_cache_prune(_delta: float) -> void:
		pass


	func _update_snapshot_packet_warning_timer(_delta: float) -> void:
		pass


	func _update_batched_network_events(_delta: float) -> void:
		pass


	func _update_authoritative_tango_charge_lifecycle() -> void:
		pass


	func _host_physics_tick(_frame: int, _delta: float) -> void:
		host_physics_tick_calls += 1


	func _client_interpolate_entities() -> void:
		interpolation_calls += 1


	func _rpc_to_peer(
		_peer_id: int,
		_method_name: StringName,
		_args: Array = [],
		_record_outbound: bool = true
	) -> bool:
		outbound_rpc_calls += 1
		return true


class ReconnectWrapperStub:
	extends MpRogueRoute
	var embedded_transport_call_count := 0


	func _ready() -> void:
		pass


	func _exit_tree() -> void:
		pass


	func capture_embedded_transport_call(
		_peer_id: int,
		_method_name: StringName,
		_arguments: Array
	) -> bool:
		embedded_transport_call_count += 1
		return true


class JoinRegistrationRouteProbe:
	extends RogueRouteGame

	var run_state: RunStateStore = null
	var add_called := false
	var ledger_registered_before_add := false
	var stable_key_recorded := false


	func _ready() -> void:
		pass


	func get_player_for_peer(_peer_id: int) -> Player:
		return null


	func add_multiplayer_player(
		peer_id: int,
		_player_name: String,
		_character_id: StringName,
		_spawn_position: Vector2
	) -> bool:
		add_called = true
		ledger_registered_before_add = (
			run_state != null
			and run_state.has_multiplayer_peer_state(peer_id)
		)
		return true


	func set_multiplayer_participant_stable_key(
		_peer_id: int,
		stable_key: String
	) -> bool:
		stable_key_recorded = not stable_key.is_empty()
		return stable_key_recorded


class BriefingTimeoutRouteStub:
	extends RogueRouteGame

	var aborted_occurrence_key := ""


	func abort_briefing_entry(occurrence_key: String) -> void:
		aborted_occurrence_key = occurrence_key


var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_mode_and_loading_contract()
	_test_stable_participant_identity_contract()
	_test_p3_player_joined_registers_ledger_before_projection()
	_test_briefing_cover_timeout_contract()
	_test_embedded_inactive_gate_contract()
	_test_tower_rogue_cross_channel_flow_gate()
	_test_tower_world_suspension_gate()
	await _test_lobby_contract()
	await _test_snapshot_and_delta_contract()
	await _test_briefing_network_contract()
	await _test_fluorescent_pit_route_integration()
	await _test_warehouse_route_persistence_contract()
	_test_host_requires_character_confirmation()
	_finish()


func _test_embedded_inactive_gate_contract() -> void:
	var wrapper := ReconnectWrapperStub.new()
	wrapper.set("_embedded_campaign_mode", true)
	wrapper.set("_runtime_prepared", true)
	wrapper.set("_embedded_exploration_active", false)
	wrapper.set(
		"_rpc_transport",
		Callable(wrapper, "capture_embedded_transport_call")
	)
	var stale_calls := [
		[&"net_request_route_full_snapshot", []],
		[&"net_route_upgrade_requested", [0, 0, 0]],
		[&"net_route_full_snapshot", [{}, {}, {}, {}, {}, {}]],
		[&"net_route_move_delta", [{}]],
		[&"net_route_briefing_state", [{}]],
		[&"net_route_briefing_cover_ready", ["briefing", 1, 1]],
		[&"net_route_encounter_intro_ack", ["encounter", 1]],
		[&"net_route_encounter_vote", ["encounter", 1, &"option"]],
		[&"net_route_encounter_result_ack", ["encounter", 1]],
		[&"net_route_encounter_snapshot", [{}, {}]],
		[
			&"net_shop_purchase_request",
			["request", "shop", 0, 1, 1, 1, 1],
		],
		[
			&"net_shop_sell_request",
			["request", "shop", 0, "item", 1, 1, 1],
		],
		[&"net_shop_exit_ack", ["shop", 1]],
		[&"net_shop_snapshot", [{}]],
		[&"net_route_avatar_input", [1, 1, PackedInt32Array()]],
		[&"net_route_avatar_snapshot", [1, 1, PackedInt32Array()]],
		[&"net_route_avatar_corrected", [1, PackedInt32Array()]],
	]
	for stale_call in stale_calls:
		_expect(
			not bool(wrapper.apply_embedded_route_rpc(
				stale_call[0] as StringName,
				42,
				stale_call[1] as Array
			)),
			"塔防非探索阶段必须拒绝陈旧 RPC：%s。" % stale_call[0]
		)
	_expect(
		not bool(wrapper.call(
			"_send_route_rpc",
			7,
			&"net_route_move_delta",
			[{}]
		))
		and wrapper.embedded_transport_call_count == 0,
		"塔防非探索阶段的隐藏路线不得继续发包。"
	)
	wrapper.set("_snapshot_request_pending", true)
	wrapper.set("_pending_shop_exit_ack", {"occurrence_key": "old"})
	wrapper.set("_briefing_cover_occurrence_key", "old")
	wrapper.set("_briefing_cover_deadline_msec", 123)
	wrapper.set("_route_shop_command_rate_buckets", {42: {"tokens": 0.0}})
	wrapper.set("_embedded_exploration_active", true)
	wrapper.set_embedded_exploration_active(false)
	_expect(
		not bool(wrapper.get("_snapshot_request_pending"))
		and (wrapper.get("_pending_shop_exit_ack") as Dictionary).is_empty()
		and str(wrapper.get("_briefing_cover_occurrence_key")).is_empty()
		and int(wrapper.get("_briefing_cover_deadline_msec")) == 0
		and (wrapper.get("_route_shop_command_rate_buckets") as Dictionary).is_empty(),
		"探索返回后必须清理快照重试、商店回执、简报屏障和限流会话。"
	)
	var manager := FakeNetManager.new()
	var refresh_counter := {"count": 0}
	manager.host_role = true
	wrapper.set("_net_manager", manager)
	wrapper.embedded_authoritative_snapshot_changed.connect(func() -> void:
		refresh_counter["count"] = int(refresh_counter["count"]) + 1
	)
	wrapper.call(
		"_on_host_layout_committed",
		{"schema": 1, "template_id": "entry"},
		{"schema": 1, "revision": 1}
	)
	_expect(
		int(refresh_counter["count"]) == 0,
		"首次建图但探索尚未 active 时不得广播半进入会话快照。"
	)
	wrapper.set("_embedded_exploration_active", true)
	wrapper.call(
		"_on_host_layout_committed",
		{"schema": 1, "template_id": "active"},
		{"schema": 1, "revision": 2}
	)
	_expect(
		int(refresh_counter["count"]) == 1,
		"探索正式 active 后路线布局提交必须恢复会话刷新通知。"
	)
	manager.free()
	wrapper.free()


func _test_tower_rogue_cross_channel_flow_gate() -> void:
	var game := MP_GAME_SCRIPT.new()
	var adapter := RogueFlowGateAdapterStub.new()
	var bridge := ReconnectWrapperStub.new()
	var world_flow := RogueFlowWorldProbe.new()
	bridge.set("_embedded_campaign_mode", true)
	bridge.set("_embedded_exploration_active", false)
	game.set("tower_mode_adapter", adapter)
	game.set("tower_rogue_route_bridge", bridge)
	game.set("world_flow_coordinator", world_flow)
	game.call(
		"_receive_or_defer_tower_flow_state",
		"rogue_day_1",
		CombatFlowState.State.ROGUE_EXPLORATION,
		0
	)
	_expect(
		int((game.get("_pending_tower_rogue_flow_state") as Dictionary).get(
			"state",
			-1
		)) == CombatFlowState.State.ROGUE_EXPLORATION,
		"CH5 探索流程先到时必须等待 CH0 会话快照，不能进入空路线。"
	)
	adapter.exploration_active = true
	bridge.set("_embedded_exploration_active", true)
	game.call("_flush_pending_tower_rogue_flow_state", true)
	_expect(
		(game.get("_pending_tower_rogue_flow_state") as Dictionary).is_empty(),
		"active 会话快照落地后必须提交等待中的探索流程。"
	)
	_expect(
		world_flow.received_states == [CombatFlowState.State.ROGUE_EXPLORATION],
		"重复刷新边界前，探索流程必须且只能提交一次。"
	)
	game.call(
		"_receive_or_defer_tower_flow_state",
		"wave_05",
		CombatFlowState.State.FATE_INTERLUDE,
		0
	)
	_expect(
		int((game.get("_pending_tower_rogue_flow_state") as Dictionary).get(
			"state",
			-1
		)) == CombatFlowState.State.FATE_INTERLUDE,
		"CH5 命运流程先到时必须等待 CH0 active=false，不能跳过探索退出边界。"
	)
	game.call("_flush_pending_tower_rogue_flow_state", true)
	_expect(
		int((game.get("_pending_tower_rogue_flow_state") as Dictionary).get(
			"state",
			-1
		)) == CombatFlowState.State.FATE_INTERLUDE
		and world_flow.received_states.size() == 1,
		"重复 active=true 快照不得提前提交或丢弃等待中的 Fate 流程。"
	)
	adapter.exploration_active = false
	bridge.set("_embedded_exploration_active", false)
	game.call("_flush_pending_tower_rogue_flow_state", false)
	_expect(
		(game.get("_pending_tower_rogue_flow_state") as Dictionary).is_empty(),
		"active=false 会话快照落地后必须提交等待中的命运流程。"
	)
	game.call("_flush_pending_tower_rogue_flow_state", false)
	_expect(
		world_flow.received_states == [
			CombatFlowState.State.ROGUE_EXPLORATION,
			CombatFlowState.State.FATE_INTERLUDE,
		],
		"重复 active=false 快照不得重复提交 Fate 流程。"
	)
	game.free()
	adapter.free()
	bridge.free()
	world_flow.free()


func _test_tower_world_suspension_gate() -> void:
	var game := TowerGateMpGameProbe.new()
	var adapter := RogueFlowGateAdapterStub.new()
	var manager := FakeNetManager.new()
	var session := TowerGateSessionProbe.new()
	var players := TowerGatePlayerProbe.new()
	var tower_world := TowerGateWorldProbe.new()
	var economy := TowerGateEconomyProbe.new()
	var transactions := TowerGateTransactionsProbe.new()
	var merchants := TowerGateMerchantProbe.new()
	var runtime := WarehouseRuntimeStub.new()
	manager.host_role = true
	adapter.exploration_active = true
	game.set("tower_mode_adapter", adapter)
	game.set("net_manager", manager)
	game.set("session_coordinator", session)
	game.set("player_coordinator", players)
	game.set("tower_world_coordinator", tower_world)
	game.set("tower_economy_coordinator", economy)
	game.set("transactions_coordinator", transactions)
	game.set("merchant_transactions_coordinator", merchants)
	game.set("game", runtime)

	game.call("_physics_process", 0.016)
	game.call("_process", 0.016)
	_dispatch_tower_gate_probe_requests(game, 1)
	_dispatch_tower_local_transaction_requests(game, 1)
	_dispatch_tower_host_transaction_requests(game, 1)
	_expect(
		game.host_physics_tick_calls == 0
		and game.interpolation_calls == 0
		and session.update_calls == 1,
		"探索激活时外层塔防必须冻结物理帧和插值，但继续会话保活。"
	)
	_expect(
		players.state_calls == 0
		and players.dash_calls == 0
		and tower_world.placement_calls == 0
		and economy.request_calls == 0
		and transactions.admission_calls == 0
		and transactions.local_request_calls == 0
		and transactions.remote_request_calls == 0
		and merchants.local_request_calls == 0
		and merchants.remote_request_calls == 0,
		"探索激活时玩家、塔防经济及通用 RunState 管理请求必须零下游调用。"
	)

	adapter.exploration_active = false
	adapter.presentation_pending = true
	game.call("_physics_process", 0.016)
	game.call("_process", 0.016)
	_dispatch_tower_gate_probe_requests(game, 10)
	_dispatch_tower_local_transaction_requests(game, 10)
	_dispatch_tower_host_transaction_requests(game, 10)
	_expect(
		game.host_physics_tick_calls == 0
		and game.interpolation_calls == 0
		and session.update_calls == 2
		and players.state_calls == 0
		and tower_world.placement_calls == 0
		and transactions.local_request_calls == 0
		and transactions.remote_request_calls == 0
		and merchants.local_request_calls == 0
		and merchants.remote_request_calls == 0,
		"Rogue 最后一帧等待 Fate 遮罩时必须继续冻结全部管理请求入口。"
	)

	adapter.presentation_pending = false
	adapter.fate_interlude_active = true
	game.call("_physics_process", 0.016)
	game.call("_process", 0.016)
	_dispatch_tower_gate_probe_requests(game, 20)
	_dispatch_tower_local_transaction_requests(game, 20)
	_dispatch_tower_host_transaction_requests(game, 20)
	_expect(
		game.host_physics_tick_calls == 1
		and game.interpolation_calls == 1
		and session.update_calls == 3,
		"Fate 黑屋必须恢复外层玩家物理帧和插值，并继续会话保活。"
	)
	_expect(
		players.state_calls == 1
		and players.dash_calls == 1
		and tower_world.placement_calls == 0
		and economy.request_calls == 0
		and transactions.admission_calls == 0
		and transactions.local_request_calls == 0
		and transactions.remote_request_calls == 0
		and merchants.local_request_calls == 0
		and merchants.remote_request_calls == 0,
		"Fate 黑屋只能恢复玩家 transport，全部 Tower/RunState 管理请求必须拒绝。"
	)
	manager.host_role = false
	_dispatch_tower_client_management_requests(game, 20)
	_dispatch_tower_client_transaction_requests(game, 20)
	_expect(
		game.outbound_rpc_calls == 0,
		"Fate 黑屋的客户端发送端不得发出任何 Tower/RunState 管理 RPC。"
	)
	manager.host_role = true

	adapter.fate_interlude_active = false
	game.call("_physics_process", 0.016)
	game.call("_process", 0.016)
	_dispatch_tower_gate_probe_requests(game, 30)
	_expect(
		game.host_physics_tick_calls == 2
		and game.interpolation_calls == 2
		and session.update_calls == 4,
		"Fate 结束后外层塔防物理帧、插值和会话保活必须保持运行。"
	)
	_expect(
		players.state_calls == 2
		and players.dash_calls == 2
		and tower_world.placement_calls == 2
		and economy.request_calls == 5
		and transactions.admission_calls == 3,
		"Fate 结束后玩家、建造和塔防经济入口必须恢复下游分发。"
	)
	manager.host_role = false
	_dispatch_tower_client_management_requests(game, 30)
	_dispatch_tower_client_transaction_requests(game, 30)
	_expect(
		game.outbound_rpc_calls == 9,
		"Fate 结束后客户端塔防、通用事务与商人 RPC 发送端必须恢复。"
	)
	manager.host_role = true
	_dispatch_tower_local_transaction_requests(game, 30)
	_dispatch_tower_host_transaction_requests(game, 30)
	_expect(
		transactions.local_request_calls == 5
		and transactions.remote_request_calls == 5
		and merchants.local_request_calls == 6
		and merchants.remote_request_calls == 6
		and transactions.admission_calls == 9,
		"正常塔防阶段必须恢复 Host 本地与远端通用事务、洛曦请求分发。"
	)

	adapter.terminal_state = true
	_dispatch_tower_gate_probe_requests(game, 40)
	_dispatch_tower_local_transaction_requests(game, 40)
	_dispatch_tower_host_transaction_requests(game, 40)
	manager.host_role = false
	_dispatch_tower_client_management_requests(game, 40)
	_dispatch_tower_client_transaction_requests(game, 40)
	_expect(
		tower_world.placement_calls == 2
		and economy.request_calls == 5
		and transactions.local_request_calls == 5
		and transactions.remote_request_calls == 5
		and merchants.local_request_calls == 6
		and merchants.remote_request_calls == 6
		and transactions.admission_calls == 9
		and game.outbound_rpc_calls == 9,
		"胜利/失败终局必须拒绝迟到的塔防、事务及商人管理请求。"
	)

	runtime.free()
	merchants.free()
	transactions.free()
	economy.free()
	tower_world.free()
	players.free()
	session.free()
	manager.free()
	adapter.free()
	game.free()


func _dispatch_tower_gate_probe_requests(
	game: TowerGateMpGameProbe,
	request_id: int
) -> void:
	game.call(
		"_rpc_client_player_state",
		request_id,
		Vector2(100.0, 50.0),
		Vector2.ONE,
		Vector2.RIGHT,
		Vector2.RIGHT,
		0,
		request_id,
		Vector2.RIGHT,
		Vector2.RIGHT
	)
	game.call(
		"net_player_dash_requested",
		request_id,
		Vector2.RIGHT,
		Vector2.RIGHT
	)
	game.call(
		"net_plant_placement_requested",
		request_id,
		"pea",
		Vector2i(2, 3)
	)
	game.call(
		"net_inventory_plant_placement_requested",
		request_id + 1,
		"pea",
		Vector2i(3, 4),
		0,
		1,
		"res://test.tres"
	)
	game.call("net_warehouse_command_requested", {"request_id": request_id})
	game.call("net_warehouse_snapshot_requested", 101)
	game.call("net_production_command_requested", {"request_id": request_id + 1})
	game.call("net_research_command_requested", {"request_id": request_id + 2})
	game.call("net_production_snapshot_requested", 102)


func _dispatch_tower_client_management_requests(
	game: TowerGateMpGameProbe,
	request_id: int
) -> void:
	game.call(
		"_on_tower_world_plant_placement_request_to_host",
		request_id,
		"pea",
		Vector2i(2, 3)
	)
	game.call(
		"_on_tower_world_inventory_plant_placement_request_to_host",
		request_id + 1,
		"pea",
		Vector2i(3, 4),
		0,
		1,
		"res://test.tres"
	)
	game.call(
		"_on_tower_economy_rpc_to_host_requested",
		&"net_production_command_requested",
		[{"request_id": request_id + 2}]
	)


func _dispatch_tower_local_transaction_requests(
	game: TowerGateMpGameProbe,
	request_id: int
) -> void:
	game.request_multiplayer_upgrade(0)
	game.request_multiplayer_inventory_item_use(0)
	game.request_multiplayer_inventory_item_discard(0)
	game.request_multiplayer_simple_crafting(&"probe", request_id)
	game.request_multiplayer_skill1_purchase()
	game.request_luoxi_collectible_offer()
	game.request_luoxi_collectible_choice(0, "", request_id)
	game.request_luoxi_collectible_refresh(request_id)
	game.request_luoxi_special_game_start()
	game.request_luoxi_special_game_card_reveal(request_id, 0)
	game.request_luoxi_special_game_finish(request_id)


func _dispatch_tower_host_transaction_requests(
	game: TowerGateMpGameProbe,
	request_id: int
) -> void:
	game.call("net_upgrade_selected", 0)
	game.call("net_inventory_item_use_requested", 0, request_id)
	game.call("net_inventory_item_discard_requested", 0, request_id)
	game.call("net_simple_crafting_requested", request_id, "probe", request_id)
	game.call("net_skill1_purchase_requested")
	game.call("net_luoxi_collectible_offer_requested")
	game.call("net_luoxi_collectible_choice_requested", 0, request_id)
	game.call("net_luoxi_collectible_refresh_requested", request_id)
	game.call("net_luoxi_special_game_start_requested")
	game.call("net_luoxi_special_game_card_reveal_requested", request_id, 0)
	game.call("net_luoxi_special_game_finish_requested", request_id)


func _dispatch_tower_client_transaction_requests(
	game: TowerGateMpGameProbe,
	request_id: int
) -> void:
	game.call("_on_transaction_upgrade_request_to_host", 0)
	game.call("_on_transaction_inventory_item_use_request_to_host", 0, request_id)
	game.call(
		"_on_transaction_inventory_item_discard_request_to_host",
		0,
		request_id
	)
	game.call(
		"_on_transaction_simple_crafting_request_to_host",
		request_id,
		"probe",
		request_id
	)
	game.call("_on_transaction_skill1_purchase_request_to_host")
	game.call(
		"_on_merchant_transactions_rpc_to_host_requested",
		&"net_luoxi_collectible_offer_requested",
		[]
	)


func _test_mode_and_loading_contract() -> void:
	_expect(
		NetConstants.PROTOCOL_VERSION == 90,
		(
			"协议 v90 必须保留 v79 T 目录付费、v78 Route 升级事务与完整进度账本，同时保留v77内容摘要、v74旧局CH6结果、v73会话成员、v71地下水道、v69植被科研、v68六格扩散、v67攻速强化塔、v66移速强化塔、P1E入口、神奇遭遇本局历史、地下教会正式普通作战池、遭遇跟随作战、目标玩家私有的地下商店与稀有宝箱会话、"
			+ "狭路相逢波次资源合同，并隔离 P1C 与纸箱怪资源、"
			+ "精英战斗机器人、精英持枪机器人弹丸与消耗品资源合同，且保留"
			+ "精英操作员无人机、精英盾兵、物资节点共享光石/行动力状态、"
			+ "精英忍者资源、既有遭遇、忍者加速与重连激活确认。"
		)
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


func _test_p3_player_joined_registers_ledger_before_projection() -> void:
	const JOINED_PEER_ID := 81
	var run_state := RunStateStore.new()
	run_state.begin_new_run(PlayerCharacterRegistry.DEFAULT_CHARACTER_ID, false)
	var net_manager := FakeNetManager.new()
	net_manager.host_role = false
	net_manager.connected_players = {
		net_manager.host_peer_id: "Host",
		JOINED_PEER_ID: "LateJoin",
	}
	net_manager.connected_player_characters = {
		net_manager.host_peer_id: PlayerCharacterRegistry.WEISHIDAIER_ID,
		JOINED_PEER_ID: PlayerCharacterRegistry.TANGO_ID,
	}
	var route_probe := JoinRegistrationRouteProbe.new()
	route_probe.run_state = run_state
	var wrapper := ReconnectWrapperStub.new()
	wrapper.set("_runtime_prepared", true)
	wrapper.set("_route", route_probe)
	wrapper.set("_net_manager", net_manager)
	wrapper.set("_run_state", run_state)
	wrapper.call("_on_player_joined", JOINED_PEER_ID, "LateJoin")
	_expect(
		route_probe.add_called
		and route_probe.ledger_registered_before_add
		and route_probe.stable_key_recorded
		and run_state.has_multiplayer_peer_state(JOINED_PEER_ID),
		(
			"P3 运行中 player_joined 必须先显式注册完整持久账本，再创建路线 Player "
			+ "并绑定稳定参与者身份。"
		)
	)
	wrapper.free()
	route_probe.free()
	net_manager.free()
	run_state.free()


func _test_stable_participant_identity_contract() -> void:
	var net_manager := NetManagerScript.new() as NetManagerStore
	net_manager.net_role = NetManagerStore.NetRole.HOST
	net_manager.connection_state = NetManagerStore.ConnectionState.IN_GAME
	var first_token := "00112233445566778899aabbccddeeff"
	var second_token := "ffeeddccbbaa99887766554433221100"
	var reconnect_tokens := (
		net_manager.get("_peer_reconnect_tokens") as Dictionary
	)
	reconnect_tokens[41] = first_token
	reconnect_tokens[42] = second_token
	var first_key := net_manager.get_stable_participant_key(41)
	var second_key := net_manager.get_stable_participant_key(42)
	_expect(
		not first_key.is_empty()
		and not second_key.is_empty()
		and first_key != second_key
		and first_key.begins_with("rogue-participant:v1:")
		and not first_key.contains(first_token),
		"同名同角色但重连身份不同的玩家必须得到不同且不泄露令牌的稳定参与键。"
	)
	reconnect_tokens.clear()
	reconnect_tokens[84] = first_token
	_expect(
		net_manager.get_stable_participant_key(84) == first_key,
		"old→new peer 迁移同一重连令牌后，稳定参与键必须保持不变。"
	)
	net_manager.net_role = NetManagerStore.NetRole.NONE
	net_manager.connection_state = NetManagerStore.ConnectionState.DISCONNECTED
	_expect(
		net_manager.get_stable_participant_key(0)
		== "rogue-participant:v1:singleplayer",
		"单机 peer 0 必须使用固定参与键。"
	)
	net_manager.free()


func _test_briefing_cover_timeout_contract() -> void:
	var wrapper := ReconnectWrapperStub.new()
	var route := BriefingTimeoutRouteStub.new()
	var net_manager := FakeNetManager.new()
	net_manager.host_role = true
	wrapper.set("_route", route)
	wrapper.set("_net_manager", net_manager)
	wrapper.set("_briefing_cover_occurrence_key", "combat:cover-timeout")
	wrapper.set("_briefing_cover_deadline_msec", 10_000)
	_expect(
		not bool(wrapper.call("_poll_briefing_cover_timeout", 9_999))
		and route.aborted_occurrence_key.is_empty(),
		"briefing cover deadline 前不得取消作战进入。"
	)
	_expect(
		bool(wrapper.call("_poll_briefing_cover_timeout", 10_000))
		and route.aborted_occurrence_key == "combat:cover-timeout"
		and int(wrapper.get("_briefing_cover_deadline_msec")) == 0,
		"静默 cover peer 超时后必须取消进入，保留尚未提交的 AP/revision。"
	)
	wrapper.free()
	route.free()
	net_manager.free()


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
	_expect(selector.item_count == 3, "多人大厅只能暴露三个正式模式选项。")
	_expect(
		selector.get_item_id(2) == NetManagerStore.GameMode.TEST_ARENA_P3
		and selector.get_item_text(2) == "肉鸽模式"
		and selector.get_item_icon(2) != null,
		"大厅第三项必须是带图标的正式肉鸽模式。"
	)
	lobby.call("_update_choose_character_button")
	_expect(choose_button.visible, "P3 房间必须允许玩家选择并确认角色。")
	_expect(
		GameModeCatalog.is_development_selectable(
			GameModeCatalog.MODE_TEST_ARENA_P2
		),
		"P2 fixture 必须通过显式开发入口保持可测试。"
	)
	# 模拟旧 Host 的冻结 wire 解码；正式 Host setter 必须拒绝该模式。
	net_manager.call(
		"_set_current_game_mode",
		NetManagerStore.GameMode.TEST_ARENA_P2
	)
	character_overlay.open(PlayerCharacterRegistry.DEFAULT_CHARACTER_ID)
	await process_frame
	lobby.call(
		"_on_net_game_mode_changed",
		NetManagerStore.GameMode.TEST_ARENA_P2
	)
	_expect(character_overlay.is_open(), "P1A/P1B/P1C/P1D/P1E/P2/标准模式同步不得误关角色选择。")
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
	var shared_run_state := root.get_node_or_null("RunState") as RunStateStore
	_expect(shared_run_state != null, "P3 快照测试必须取得常驻 RunState。")
	if shared_run_state == null:
		return
	shared_run_state.begin_new_run(&"weishidaier", false)
	_expect(
		shared_run_state.register_multiplayer_peer_states(
			PackedInt32Array([7, 8])
		),
		"P3 快照测试必须先注册 Host 与 Client 的完整持久账本。"
	)
	var host_route := ROUTE_SCENE.instantiate() as RogueRouteGame
	var client_route := ROUTE_SCENE.instantiate() as RogueRouteGame
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
	var encounter_state := host_route.export_encounter_snapshot(8)
	var economy_state := host_route.export_encounter_economy_snapshot(8)
	_expect(
		(encounter_state.get("economy_snapshot", {}) as Dictionary).is_empty()
		and not economy_state.is_empty(),
		"P3 线路快照必须只发送一份独立经济账本，不能在遭遇快照内重复携带。"
	)

	var wrapper := WRAPPER_SCENE.instantiate() as Node
	var wrapped_route := wrapper.get_node("RogueRoute") as RogueRouteGame
	_expect(
		not wrapped_route.auto_initialize and not wrapped_route.manage_return_locally,
		"多人包装必须关闭 P3 的自动初始化与本地返回管理。"
	)
	var wrapper_script := wrapper.get_script() as Script
	var rpc_config: Dictionary = wrapper_script.get_rpc_config()
	_expect(
		rpc_config.size() == 17,
		"MpRogueRoute v90 必须严格保留 17 个 RPC 入口。"
	)
	for rpc_name in [
		&"net_request_route_full_snapshot",
		&"net_route_upgrade_requested",
		&"net_route_full_snapshot",
		&"net_route_move_delta",
		&"net_route_briefing_state",
		&"net_route_encounter_intro_ack",
		&"net_route_encounter_vote",
		&"net_route_encounter_result_ack",
		&"net_route_encounter_snapshot",
		&"net_shop_purchase_request",
		&"net_shop_sell_request",
		&"net_shop_exit_ack",
		&"net_shop_snapshot",
	]:
		var config := rpc_config.get(rpc_name, {}) as Dictionary
		_expect(
			int(config.get("transfer_mode", -1))
			== MultiplayerPeer.TRANSFER_MODE_RELIABLE
			and int(config.get("channel", -1)) == 0,
			"P3 完整快照与移动 delta 必须在可靠有序信道同步。"
		)
	for request_rpc_name in [
		&"net_route_upgrade_requested",
		&"net_shop_purchase_request",
		&"net_shop_sell_request",
		&"net_shop_exit_ack",
	]:
		var request_config := rpc_config.get(request_rpc_name, {}) as Dictionary
		_expect(
			int(request_config.get("rpc_mode", -1))
			== MultiplayerAPI.RPC_MODE_ANY_PEER
			and not bool(request_config.get("call_local", true)),
			"地下商店命令必须由客户端发往 Host，Host 从 RPC sender 取得身份。"
		)
	var shop_snapshot_config := rpc_config.get(
		&"net_shop_snapshot", {}
	) as Dictionary
	_expect(
		int(shop_snapshot_config.get("rpc_mode", -1))
		== MultiplayerAPI.RPC_MODE_AUTHORITY
		and not bool(shop_snapshot_config.get("call_local", true)),
		"地下商店目标私有快照只能由 Host 下发。"
	)
	var briefing_state_config := rpc_config.get(
		&"net_route_briefing_state", {}
	) as Dictionary
	var briefing_cover_ready_config := rpc_config.get(
		&"net_route_briefing_cover_ready", {}
	) as Dictionary
	_expect(
		int(briefing_state_config.get("rpc_mode", -1))
		== MultiplayerAPI.RPC_MODE_AUTHORITY
		and not bool(briefing_state_config.get("call_local", true))
		and int(briefing_state_config.get("transfer_mode", -1))
		== MultiplayerPeer.TRANSFER_MODE_RELIABLE
		and int(briefing_state_config.get("channel", -1)) == 0,
		"作战简报状态必须只允许 Host 通过可靠有序信道下发。"
	)
	_expect(
		int(briefing_cover_ready_config.get("rpc_mode", -1))
		== MultiplayerAPI.RPC_MODE_ANY_PEER
		and not bool(briefing_cover_ready_config.get("call_local", true))
		and int(briefing_cover_ready_config.get("transfer_mode", -1))
		== MultiplayerPeer.TRANSFER_MODE_RELIABLE
		and int(briefing_cover_ready_config.get("channel", -1)) == 0,
		"简报 cover-ready 必须允许客户端通过可靠有序信道向 Host 回执。"
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
	wrapper.set("_run_state", shared_run_state)
	fake_net_manager.gameplay_admitted = false
	wrapper.set("_route_encounter_command_rate_buckets", {})
	wrapper.set("_route_shop_command_rate_buckets", {})
	_expect(
		not bool(wrapper.call("_admit_route_encounter_command", 31))
		and not bool(wrapper.call("_admit_route_shop_command", 31))
		and (
			wrapper.get("_route_encounter_command_rate_buckets") as Dictionary
		).is_empty()
		and (
			wrapper.get("_route_shop_command_rate_buckets") as Dictionary
		).is_empty(),
		"重连玩法租约提交前，路线命令必须零写且不能消耗限流预算。"
	)
	fake_net_manager.gameplay_admitted = true
	_expect(
		bool(wrapper.call("_consume_route_repair_request", 21, 1000.0))
		and bool(wrapper.call("_consume_route_repair_request", 21, 1000.0))
		and not bool(wrapper.call("_consume_route_repair_request", 21, 1000.0))
		and bool(wrapper.call("_consume_route_repair_request", 22, 1000.0))
		and not bool(wrapper.call("_consume_route_repair_request", 21, 1001.0))
		and bool(wrapper.call("_consume_route_repair_request", 21, 1002.0)),
		(
			"Host route repair admission must allow a two-request burst, refill at "
			+ "0.5/s, and isolate each peer's budget."
		)
	)
	wrapper.set("_route_repair_request_rate_buckets", {})
	var encounter_command_buckets := (
		wrapper.get("_route_encounter_command_rate_buckets") as Dictionary
	)
	var command_admission_count := 0
	for _command_index in 7:
		if bool(wrapper.call(
			"_consume_peer_rate_token",
			encounter_command_buckets,
			31,
			4.0,
			6.0,
			1000.0
		)):
			command_admission_count += 1
	_expect(
		command_admission_count == 6,
		"Encounter commands must admit a six-request burst and reject the seventh."
	)
	wrapper.set("_route_encounter_command_rate_buckets", {})
	var shop_command_buckets := (
		wrapper.get("_route_shop_command_rate_buckets") as Dictionary
	)
	var shop_admission_count := 0
	for _command_index in 9:
		if bool(wrapper.call(
			"_consume_peer_rate_token",
			shop_command_buckets,
			32,
			6.0,
			8.0,
			1000.0
		)):
			shop_admission_count += 1
	_expect(
		shop_admission_count == 8,
		"地下商店命令必须允许八请求突发并拒绝第九个请求。"
	)
	wrapper.call(
		"_on_local_shop_exit_ack_requested",
		"shop:exit-retry",
		7
	)
	var pending_exit := wrapper.get("_pending_shop_exit_ack") as Dictionary
	_expect(
		str(pending_exit.get("occurrence_key", "")) == "shop:exit-retry",
		"买卖预算耗尽后，退出回执仍必须进入独立可靠重试状态。"
	)
	wrapper.call("_reconcile_pending_shop_exit_ack", {
		"occurrence_key": "shop:exit-retry",
		"session_revision": 8,
		"target_exited": false,
	})
	pending_exit = wrapper.get("_pending_shop_exit_ack") as Dictionary
	_expect(
		int(pending_exit.get("expected_session_revision", -1)) == 8,
		"Host 尚未确认退出时，客户端必须依据新快照 revision 继续重试。"
	)
	wrapper.call("_reconcile_pending_shop_exit_ack", {
		"occurrence_key": "shop:exit-retry",
		"session_revision": 9,
		"target_exited": true,
	})
	_expect(
		(wrapper.get("_pending_shop_exit_ack") as Dictionary).is_empty(),
		"只有目标私有快照确认 target_exited 后才能停止退出回执重试。"
	)
	wrapper.set("_route_shop_command_rate_buckets", {})
	_expect(
		not bool(wrapper.call(
			"_apply_full_snapshot_from_peer",
			fake_net_manager.host_peer_id + 1,
			layout,
			state,
			encounter_state,
			economy_state,
			{},
			shared_run_state.export_player_upgrade_ledger()
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
			economy_state,
			{},
			shared_run_state.export_player_upgrade_ledger()
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
	var state_before_bad_progression := client_route.export_state_snapshot()
	var economy_before_bad_progression := (
		client_route.export_encounter_economy_snapshot(0)
	)
	var malformed_progression := shared_run_state.export_player_upgrade_ledger()
	malformed_progression.erase("values")
	_expect(
		not bool(wrapper.call(
			"_apply_full_snapshot_from_peer",
			fake_net_manager.host_peer_id,
			layout,
			state,
			encounter_state,
			economy_state,
			{},
			malformed_progression
		))
		and client_route.export_state_snapshot() == state_before_bad_progression
		and client_route.export_encounter_economy_snapshot(0)
		== economy_before_bad_progression,
		"畸形成长账本必须在路线、经济与视觉提交前原子拒绝。"
	)
	var client_peer_id := fake_net_manager.host_peer_id + 1
	fake_net_manager.connected_players = {
		fake_net_manager.host_peer_id: "Host",
		client_peer_id: "Client",
	}
	var staged_identity := client_route.prepare_multiplayer_players(
		client_peer_id,
		fake_net_manager.connected_players,
		{
			fake_net_manager.host_peer_id:
				PlayerCharacterRegistry.WEISHIDAIER_ID,
			client_peer_id: PlayerCharacterRegistry.TANGO_ID,
		}
	)
	var staged_route := client_route.prepare_full_snapshot(
		layout,
		state,
		encounter_state,
		economy_state,
		{},
		client_peer_id
	)
	var staged_players: Array = []
	if not staged_identity.is_empty():
		staged_players = (
			staged_identity["players"] as Dictionary
		).values().duplicate()
	var staged_board_cells: Array = []
	if not staged_route.is_empty():
		staged_board_cells = (
			(staged_route["board"] as Dictionary)["cells"] as Array
		).duplicate()
	var rejected_late_progression := (
		client_route.prepare_authoritative_player_progression(
			{},
			staged_route,
			staged_identity
		).is_empty()
	)
	client_route.discard_prepared_full_snapshot(staged_route)
	client_route.discard_prepared_multiplayer_players(staged_identity)
	var staged_objects_freed := true
	for staged_player in staged_players:
		staged_objects_freed = staged_objects_freed and not is_instance_valid(
			staged_player
		)
	for staged_cell in staged_board_cells:
		staged_objects_freed = staged_objects_freed and not is_instance_valid(
			staged_cell
		)
	_expect(
		not staged_players.is_empty()
		and not staged_board_cells.is_empty()
		and rejected_late_progression
		and staged_objects_freed
		and not client_route.is_route_ready()
		and client_route.get_players_for_persistent_projection().is_empty()
		and client_route.get_player_for_peer(client_peer_id) == null,
		(
			"树外 roster 与 board 已准备后若后域成长畸形，必须释放全部 staged "
			+ "Player/cell，且零发布身份、路线、视觉与 Player。"
		)
	)
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
		"客户端路线必须能先按稳定账本创建本地与远端自由移动角色。"
	)
	var correct_snapshot_applied := bool(wrapper.call(
			"_apply_full_snapshot_from_peer",
			fake_net_manager.host_peer_id,
			layout,
			state,
			encounter_state,
			economy_state,
			{},
			shared_run_state.export_player_upgrade_ledger()
		))
	_expect(
		correct_snapshot_applied
		and client_route.is_route_ready()
		and not bool(wrapper.get("_snapshot_request_pending"))
		and int(wrapper.get("_snapshot_request_retry_at_msec")) == 0
		and int(wrapper.get("_snapshot_request_retry_exponent")) == 0,
		"客户端必须在坏快照后接受 Host 的正确快照并重置退避状态。"
	)
	var old_route_xirang_values := (
		shared_run_state.party_xirang_balances.duplicate(true)
	)
	var old_route_xirang_revision := (
		shared_run_state.party_xirang_ledger_revision
	)
	var repaired_peer_balance := (
		shared_run_state.get_party_xirang_balance(client_peer_id) + 77
	)
	_expect(
		shared_run_state.set_party_xirang_balance(
			client_peer_id,
			repaired_peer_balance,
			false
		),
		"MpRoute 重入夹具必须构造下一份 Host Party 息壤高水位。"
	)
	var reentry_layout := host_route.export_layout_snapshot()
	var reentry_state := host_route.export_state_snapshot()
	var reentry_encounter := host_route.export_encounter_snapshot(client_peer_id)
	var reentry_economy := (
		host_route.export_encounter_economy_snapshot(client_peer_id)
	)
	var reentry_shop := host_route.export_shop_snapshot_for_peer(client_peer_id)
	var reentry_progression := shared_run_state.export_player_upgrade_ledger()
	shared_run_state.party_xirang_balances = old_route_xirang_values
	shared_run_state.party_xirang_ledger_revision = old_route_xirang_revision
	var reentry_observation := {
		"owner_signal_count": 0,
		"nested_apply_rejected": false,
		"route_direct_apply_rejected": false,
	}
	var reentry_callback := func(_ledger: Dictionary) -> void:
		reentry_observation["owner_signal_count"] += 1
		reentry_observation["nested_apply_rejected"] = not bool(wrapper.call(
			"_apply_full_snapshot_from_peer",
			fake_net_manager.host_peer_id,
			reentry_layout,
			reentry_state,
			reentry_encounter,
			reentry_economy,
			reentry_shop,
			reentry_progression
		))
		reentry_observation["route_direct_apply_rejected"] = not (
			client_route.apply_full_snapshot(
				reentry_layout,
				reentry_state,
				reentry_encounter,
				reentry_economy,
				reentry_shop
			)
		)
	shared_run_state.party_xirang_ledger_changed.connect(reentry_callback)
	var reentry_outer_applied := bool(wrapper.call(
		"_apply_full_snapshot_from_peer",
		fake_net_manager.host_peer_id,
		reentry_layout,
		reentry_state,
		reentry_encounter,
		reentry_economy,
		reentry_shop,
		reentry_progression
	))
	shared_run_state.party_xirang_ledger_changed.disconnect(reentry_callback)
	_expect(
		reentry_outer_applied
		and int(reentry_observation["owner_signal_count"]) == 1
		and bool(reentry_observation["nested_apply_rejected"])
		and bool(reentry_observation["route_direct_apply_rejected"])
		and shared_run_state.get_party_xirang_balance(client_peer_id)
		== repaired_peer_balance
		and client_route.get_player_for_peer(client_peer_id).current_xirang
		== repaired_peer_balance,
		"MpRoute 首个 owner 回调同步重入必须零写拒绝，外层快照仍只提交/发布一次。"
	)
	var cas_layout_before := client_route.export_layout_snapshot()
	var cas_state_before := client_route.export_state_snapshot()
	var cas_encounter_before := client_route.export_encounter_snapshot(
		client_peer_id
	)
	var cas_economy_before := client_route.export_encounter_economy_snapshot(
		client_peer_id
	)
	var cas_shop_before := client_route.export_shop_snapshot_for_peer(
		client_peer_id
	)
	var cas_party_before := shared_run_state.export_party_economy_snapshot()
	var cas_progression_before := (
		shared_run_state.export_player_upgrade_ledger()
	)
	var cas_player_before := {
		"instance_id": client_route.get_player_for_peer(
			client_peer_id
		).get_instance_id(),
		"health": client_route.get_player_for_peer(client_peer_id).current_health,
		"max_health": client_route.get_player_for_peer(client_peer_id).max_health,
		"attack": client_route.get_player_for_peer(client_peer_id).attack_damage,
		"xirang": client_route.get_player_for_peer(client_peer_id).current_xirang,
	}
	var cas_prepared_progression := shared_run_state.prepare_player_upgrade_ledger(
		cas_progression_before,
		true
	)
	var cas_prepared_route := client_route.prepare_full_snapshot(
		reentry_layout,
		reentry_state,
		reentry_encounter,
		reentry_economy,
		reentry_shop,
		client_peer_id
	)
	var cas_prepared_player := client_route.prepare_authoritative_player_progression(
		cas_prepared_progression,
		cas_prepared_route
	)
	var staged_cells: Array = []
	if not cas_prepared_route.is_empty():
		staged_cells = (
			(cas_prepared_route["board"] as Dictionary)["cells"] as Array
		).duplicate()
	var previous_commit_generation := int(
		client_route.get("_full_snapshot_commit_generation")
	)
	client_route.set(
		"_full_snapshot_commit_generation",
		previous_commit_generation + 1
	)
	var route_cas_rejected := not client_route.can_commit_prepared_full_snapshot(
		cas_prepared_route
	)
	client_route.discard_prepared_full_snapshot(cas_prepared_route)
	client_route.set(
		"_full_snapshot_commit_generation",
		previous_commit_generation
	)
	var staged_cells_freed := true
	for staged_cell in staged_cells:
		staged_cells_freed = staged_cells_freed and not is_instance_valid(
			staged_cell
		)
	var cas_player_after := client_route.get_player_for_peer(client_peer_id)
	_expect(
		not cas_prepared_progression.is_empty()
		and not cas_prepared_player.is_empty()
		and route_cas_rejected
		and staged_cells_freed
		and client_route.export_layout_snapshot() == cas_layout_before
		and client_route.export_state_snapshot() == cas_state_before
		and client_route.export_encounter_snapshot(client_peer_id)
		== cas_encounter_before
		and client_route.export_encounter_economy_snapshot(client_peer_id)
		== cas_economy_before
		and client_route.export_shop_snapshot_for_peer(client_peer_id)
		== cas_shop_before
		and shared_run_state.export_party_economy_snapshot()
		== cas_party_before
		and shared_run_state.export_player_upgrade_ledger()
		== cas_progression_before
		and cas_player_after.get_instance_id()
		== int(cas_player_before["instance_id"])
		and cas_player_after.current_health == int(cas_player_before["health"])
		and cas_player_after.max_health == int(cas_player_before["max_health"])
		and cas_player_after.attack_damage == int(cas_player_before["attack"])
		and cas_player_after.current_xirang == int(cas_player_before["xirang"]),
		(
			"prepare 后 Route generation CAS 失效必须零写拒绝并释放全部树外 "
			+ "board cells；路线/Party Economy/成长/Shop/Encounter/Player 均保持原样。"
		)
	)
	var client_local_player := client_route.get_player_for_peer(client_peer_id)
	var client_host_player := client_route.get_player_for_peer(
		fake_net_manager.host_peer_id
	)
	var client_board := client_route.get("route_board") as RogueRouteBoard
	var client_graph: RogueRouteGraph = (
		client_board.graph if client_board != null else null
	)
	var client_start_position := (
		client_board.get_node_global_position(client_graph.start_node_id)
		if client_graph != null
		else Vector2.INF
	)
	_expect(
		client_local_player != null
		and client_host_player != null
		and client_local_player.global_position.is_equal_approx(
			client_start_position + RogueRouteGame.AVATAR_SPAWN_OFFSETS[1]
		)
		and client_host_player.global_position.is_equal_approx(
			client_start_position + RogueRouteGame.AVATAR_SPAWN_OFFSETS[0]
		),
		"客户端创建多人角色时必须按 peer 排序落在模板实际起点偏移。"
	)
	wrapper.set("_route_repair_request_rate_buckets", {})
	_expect(
		bool(wrapper.call("_admit_route_repair_request", client_peer_id))
		and bool(wrapper.call("_admit_route_repair_request", client_peer_id))
		and not bool(wrapper.call("_admit_route_repair_request", client_peer_id))
		and not bool(wrapper.call(
			"_admit_route_repair_request",
			client_peer_id + 100
		))
		and not (
			wrapper.get("_route_repair_request_rate_buckets") as Dictionary
		).has(client_peer_id + 100),
		(
			"Repair admission must require an in-game connected route Player, share "
			+ "one budget, and avoid allocating buckets for outsiders."
		)
	)
	wrapper.set("_route_repair_request_rate_buckets", {})
	fake_net_manager.connection_state = NetManagerStore.ConnectionState.CONNECTED_IN_LOBBY
	_expect(
		not bool(wrapper.call("_admit_route_repair_request", client_peer_id))
		and not (
			wrapper.get("_route_repair_request_rate_buckets") as Dictionary
		).has(client_peer_id),
		"Route repair admission must close outside the IN_GAME state."
	)
	fake_net_manager.connection_state = NetManagerStore.ConnectionState.IN_GAME
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
	wrapper.call("_on_player_left", client_peer_id)
	_expect(
		not (
			wrapper.get("_route_repair_request_rate_buckets") as Dictionary
		).has(client_peer_id)
		and not (
			wrapper.get("_route_encounter_command_rate_buckets") as Dictionary
		).has(client_peer_id)
		and not (
			wrapper.get("_route_shop_command_rate_buckets") as Dictionary
		).has(client_peer_id),
		"断线清理必须同时移除路线修复、遭遇和地下商店命令预算。"
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


func _test_briefing_network_contract() -> void:
	var shared_run_state := root.get_node_or_null("RunState") as RunStateStore
	_expect(shared_run_state != null, "简报联机测试必须取得常驻 RunState。")
	if shared_run_state == null:
		return
	shared_run_state.begin_new_run(&"weishidaier", false)
	_expect(
		shared_run_state.register_multiplayer_peer_states(
			PackedInt32Array([7, 8])
		),
		"简报联机测试必须先注册完整多人持久账本。"
	)
	var probe_route := ROUTE_SCENE.instantiate() as RogueRouteGame
	probe_route.auto_initialize = false
	probe_route.manage_return_locally = false
	var fixture := _find_adjacent_normal_combat_fixture(
		probe_route.generation_config
	)
	probe_route.free()
	_expect(
		not fixture.is_empty(),
		"简报联机测试必须找到起点相邻的普通作战节点。"
	)
	if fixture.is_empty():
		return

	var host_route := ROUTE_SCENE.instantiate() as RogueRouteGame
	var client_route := ROUTE_SCENE.instantiate() as RogueRouteGame
	var pre_move_rejoin := ROUTE_SCENE.instantiate() as RogueRouteGame
	var post_move_rejoin := ROUTE_SCENE.instantiate() as RogueRouteGame
	for route in [host_route, client_route, pre_move_rejoin, post_move_rejoin]:
		route.auto_initialize = false
		route.manage_return_locally = false
		root.add_child(route)
	await process_frame

	var seed := int(fixture["seed"])
	var combat_node_id := int(fixture["combat_node_id"])
	_expect(
		host_route.start_authoritative_session(seed, false),
		"Host 简报夹具必须能生成固定普通作战路线。"
	)
	host_route.normal_combat_requested.connect(
		func(
			_node_id: int,
			_content_seed: int,
			_occurrence_key: String
		) -> void:
			pass
	)
	host_route.route_board.complete_entry_reveal()
	client_route.start_client_waiting()
	pre_move_rejoin.start_client_waiting()
	post_move_rejoin.start_client_waiting()
	var layout := host_route.export_layout_snapshot()
	var route_state_before_briefing := host_route.export_state_snapshot()
	var route_revision_before := int(route_state_before_briefing["revision"])
	var action_points_before := int(route_state_before_briefing["action_points"])

	host_route.call(&"_on_route_board_node_pressed", combat_node_id)
	var presented_state := host_route.export_state_snapshot()
	var presented := (
		presented_state.get("briefing_state", {}) as Dictionary
	)
	_expect(
		int(presented.get("phase", -1))
		== RogueRouteGame.BriefingPhase.PRESENTED
		and int(presented_state.get("revision", -1)) == route_revision_before
		and int(presented_state.get("action_points", -1))
		== action_points_before,
		"打开普通作战简报只能推进独立简报 revision，不得扣 AP 或提交路线。"
	)

	var wrapper := WRAPPER_SCENE.instantiate() as MpRogueRoute
	var fake_net_manager := FakeNetManager.new()
	fake_net_manager.connected_players = {
		fake_net_manager.host_peer_id: "Host",
		fake_net_manager.host_peer_id + 1: "Client",
	}
	_expect(
		client_route.configure_multiplayer_players(
			fake_net_manager.host_peer_id + 1,
			fake_net_manager.connected_players,
			{
				fake_net_manager.host_peer_id:
					PlayerCharacterRegistry.WEISHIDAIER_ID,
				fake_net_manager.host_peer_id + 1:
					PlayerCharacterRegistry.TANGO_ID,
			}
		),
		"简报客户端必须在收权威全快照前按账本创建稳定 Player roster。"
	)
	wrapper.set("_route", client_route)
	wrapper.set("_net_manager", fake_net_manager)
	wrapper.set("_run_state", shared_run_state)
	var briefing_snapshot_peer_id := fake_net_manager.host_peer_id + 1
	var encounter_state := host_route.export_encounter_snapshot(
		briefing_snapshot_peer_id
	)
	var economy_state := host_route.export_encounter_economy_snapshot(
		briefing_snapshot_peer_id
	)
	_expect(
		bool(wrapper.call(
			"_apply_full_snapshot_from_peer",
			fake_net_manager.host_peer_id,
			layout,
			presented_state,
			encounter_state,
			economy_state,
			{},
			(
				shared_run_state.export_player_upgrade_ledger()
				if shared_run_state != null
				else {}
			)
		)),
		"客户端完整快照必须恢复 Host 的 PRESENTED 简报。"
	)
	await process_frame
	_expect(
		int(client_route.get("_briefing_phase"))
		== RogueRouteGame.BriefingPhase.PRESENTED
		and client_route.node_briefing.visible
		and not client_route.node_briefing.can_decide()
		and int(client_route.export_state_snapshot()["revision"])
		== route_revision_before
		and int(client_route.export_state_snapshot()["action_points"])
		== action_points_before,
		"重连客户端必须看到只读简报，且 PRESENTED 快照不得改变路线状态。"
	)

	var entering := presented.duplicate(true)
	entering["revision"] = int(presented["revision"]) + 1
	entering["phase"] = RogueRouteGame.BriefingPhase.ENTERING
	var pre_move_state := presented_state.duplicate(true)
	pre_move_state["briefing_state"] = entering.duplicate(true)
	_expect(
		pre_move_rejoin.apply_full_snapshot(layout, pre_move_state),
		"ENTERING 的 move 前完整快照必须可由 occurrence 与预期路线 revision 复算。"
	)
	await process_frame
	_expect(
		int(pre_move_rejoin.get("_briefing_phase"))
		== RogueRouteGame.BriefingPhase.ENTERING
		and not pre_move_rejoin.node_briefing.visible
		and pre_move_rejoin.combat_scene_transition.visible,
		"move 前重连必须关闭简报并恢复本地 shader cover。"
	)

	var client_state_before_wrong_sender := client_route.export_state_snapshot()
	_expect(
		not bool(wrapper.call(
			"_apply_briefing_state_from_peer",
			fake_net_manager.host_peer_id + 99,
			entering
		))
		and client_route.export_state_snapshot()
		== client_state_before_wrong_sender,
		"客户端必须原子拒绝非 Host 发来的简报状态。"
	)
	for invalid_kind in ["layout", "occurrence", "expected_revision"]:
		var invalid := entering.duplicate(true)
		match invalid_kind:
			"layout":
				invalid["layout_hash"] = "invalid-layout"
			"occurrence":
				invalid["occurrence_key"] = str(invalid["occurrence_key"]) + ":stale"
			"expected_revision":
				invalid["expected_route_revision"] = (
					int(invalid["expected_route_revision"]) + 1
				)
		var state_before_invalid := client_route.export_state_snapshot()
		_expect(
			not bool(wrapper.call(
				"_apply_briefing_state_from_peer",
				fake_net_manager.host_peer_id,
				invalid
			))
			and client_route.export_state_snapshot() == state_before_invalid
			and client_route.node_briefing.visible,
			"错误 %s 简报包必须原子拒绝，不能关闭当前 PRESENTED 界面。"
			% invalid_kind
		)

	_expect(
		bool(wrapper.call(
			"_apply_briefing_state_from_peer",
			fake_net_manager.host_peer_id,
			entering
		)),
		"客户端必须接受 Host 的当前 ENTERING 简报包。"
	)
	await process_frame
	var transition_serial := int(
		client_route.combat_scene_transition.get("_transition_serial")
	)
	var transition_tween: Variant = (
		client_route.combat_scene_transition.get("_transition_tween")
	)
	var entering_client_state := client_route.export_state_snapshot()
	_expect(
		bool(wrapper.call(
			"_apply_briefing_state_from_peer",
			fake_net_manager.host_peer_id,
			entering
		))
		and bool(wrapper.call(
			"_apply_briefing_state_from_peer",
			fake_net_manager.host_peer_id,
			presented
		))
		and client_route.export_state_snapshot() == entering_client_state
		and int(client_route.combat_scene_transition.get(
			"_transition_serial"
		)) == transition_serial
		and client_route.combat_scene_transition.get("_transition_tween")
		== transition_tween,
		"相同或旧简报包必须幂等忽略，不能重启 cover 动画。"
	)
	var same_revision_conflict := entering.duplicate(true)
	same_revision_conflict["phase"] = RogueRouteGame.BriefingPhase.PRESENTED
	_expect(
		not bool(wrapper.call(
			"_apply_briefing_state_from_peer",
			fake_net_manager.host_peer_id,
			same_revision_conflict
		))
		and client_route.export_state_snapshot() == entering_client_state
		and int(client_route.combat_scene_transition.get(
			"_transition_serial"
		)) == transition_serial,
		"同 revision 的冲突简报必须原子拒绝，不能倒退到 PRESENTED。"
	)

	# 模拟本地旧战场仍持有同一 occurrence，而权威 full snapshot 将路线
	# revision 回退并重建同 occurrence 的 Briefing。reconcile signal 只能
	# 释放旧 stage，绝不能由 listener 再把新 PRESENTED/ENTERING 清空。
	var combat_graph := client_route.get("_route_graph") as RogueRouteGraph
	var combat_content_seed := combat_graph.get_node_content_seed(combat_node_id)
	var reconcile_observation := {
		"count": 0,
		"occurrences": [],
		"phases": [],
		"route_reentry_rejected": true,
	}
	var reconcile_reentry_state := {"snapshot": presented_state}
	var reconcile_callback := func(reconciled_occurrence: String) -> void:
		reconcile_observation["count"] += 1
		(reconcile_observation["occurrences"] as Array).append(
			reconciled_occurrence
		)
		(reconcile_observation["phases"] as Array).append(
			int(client_route.get("_briefing_phase"))
		)
		reconcile_observation["route_reentry_rejected"] = (
			bool(reconcile_observation["route_reentry_rejected"])
			and not client_route.apply_full_snapshot(
				layout,
				reconcile_reentry_state["snapshot"] as Dictionary,
				encounter_state,
				economy_state
			)
		)
	client_route.normal_combat_snapshot_reconciled.connect(
		reconcile_callback
	)
	client_route.call(
		"_begin_normal_combat_stage",
		combat_node_id,
		combat_content_seed,
		str(presented["occurrence_key"]),
		StringName(presented.get("combat_config_id", ""))
	)
	var client_runtime_state := (
		client_route.get("_runtime_state") as RogueRouteRuntimeState
	)
	client_runtime_state.state_revision += 1
	var presented_reconcile_applied := bool(wrapper.call(
		"_apply_full_snapshot_from_peer",
		fake_net_manager.host_peer_id,
		layout,
		presented_state,
		encounter_state,
		economy_state,
		{},
		shared_run_state.export_player_upgrade_ledger()
	))
	_expect(
		presented_reconcile_applied
		and not client_route.is_normal_combat_active()
		and client_route.export_briefing_state_snapshot() == presented,
		"同 occurrence PRESENTED full snapshot 必须释放旧战场并精确保留新简报。"
	)
	client_route.call(
		"_begin_normal_combat_stage",
		combat_node_id,
		combat_content_seed,
		str(entering["occurrence_key"]),
		StringName(entering.get("combat_config_id", ""))
	)
	client_runtime_state = client_route.get("_runtime_state") as RogueRouteRuntimeState
	client_runtime_state.state_revision += 1
	reconcile_reentry_state["snapshot"] = pre_move_state
	var entering_reconcile_applied := bool(wrapper.call(
		"_apply_full_snapshot_from_peer",
		fake_net_manager.host_peer_id,
		layout,
		pre_move_state,
		encounter_state,
		economy_state,
		{},
		shared_run_state.export_player_upgrade_ledger()
	))
	client_route.normal_combat_snapshot_reconciled.disconnect(
		reconcile_callback
	)
	_expect(
		entering_reconcile_applied
		and not client_route.is_normal_combat_active()
		and client_route.export_briefing_state_snapshot() == entering
		and int(reconcile_observation["count"]) == 2
		and (reconcile_observation["occurrences"] as Array)
		== [str(entering["occurrence_key"]), str(entering["occurrence_key"])]
		and (reconcile_observation["phases"] as Array)
		== [
			RogueRouteGame.BriefingPhase.PRESENTED,
			RogueRouteGame.BriefingPhase.ENTERING,
		]
		and bool(reconcile_observation["route_reentry_rejected"]),
		(
			"同 occurrence ENTERING full snapshot 必须精确保留新简报；两次 delayed "
			+ "reconcile 回调都只能见到完整新状态且不得直接重入 Route。"
		)
	)

	host_route.call(&"_on_node_briefing_confirmed")
	var authoritative_entering := host_route.export_briefing_state_snapshot()
	_expect(
		int(authoritative_entering.get("phase", -1))
		== RogueRouteGame.BriefingPhase.ENTERING
		and int(host_route.export_state_snapshot()["revision"])
		== route_revision_before,
		"Host 确认后必须先进入 ENTERING，等待全员 cover-ready 才提交 move。"
	)

	fake_net_manager.host_role = true
	wrapper.set("_route", host_route)
	wrapper.call("_configure_briefing_cover_barrier", authoritative_entering)
	var host_peer_id := fake_net_manager.host_peer_id
	var client_peer_id := host_peer_id + 1
	var briefing_revision := int(authoritative_entering["revision"])
	var occurrence_key := str(authoritative_entering["occurrence_key"])
	var expected_route_revision := int(
		authoritative_entering["expected_route_revision"]
	)
	_expect(
		not bool(wrapper.call(
			"_accept_briefing_cover_ready",
			client_peer_id + 99,
			occurrence_key,
			briefing_revision,
			expected_route_revision
		))
		and not bool(wrapper.call(
			"_accept_briefing_cover_ready",
			client_peer_id,
			occurrence_key + ":expired",
			briefing_revision,
			expected_route_revision
		)),
		"cover-ready 屏障必须拒绝非参战 sender 与过期 occurrence。"
	)
	_expect(
		bool(wrapper.call(
			"_accept_briefing_cover_ready",
			client_peer_id,
			occurrence_key,
			briefing_revision,
			expected_route_revision
		))
		and not bool(wrapper.call(
			"_accept_briefing_cover_ready",
			client_peer_id,
			occurrence_key,
			briefing_revision,
			expected_route_revision
		))
		and int(host_route.export_state_snapshot()["revision"])
		== route_revision_before
		and (wrapper.get("_briefing_cover_ready_peers") as Dictionary).size()
		== 1,
		"客户端重复 cover-ready 必须幂等早退，Host 未 ready 前不得提交路线。"
	)
	_expect(
		bool(wrapper.call(
			"_accept_briefing_cover_ready",
			host_peer_id,
			occurrence_key,
			briefing_revision,
			expected_route_revision
		))
		and int(host_route.export_state_snapshot()["revision"])
		== route_revision_before + 1
		and int(host_route.export_state_snapshot()["action_points"])
		== action_points_before - host_route.generation_config.move_action_cost
		and bool(wrapper.get("_briefing_move_commit_started")),
		"全员 cover-ready 后 Host 必须只提交一次路线移动与 AP 扣除。"
	)
	var committed_state := host_route.export_state_snapshot()
	_expect(
		not bool(wrapper.call(
			"_accept_briefing_cover_ready",
			host_peer_id,
			occurrence_key,
			briefing_revision,
			expected_route_revision
		))
		and host_route.export_state_snapshot() == committed_state,
		"屏障完成后的重复 ready 不得再次推进路线 revision。"
	)

	_expect(
		post_move_rejoin.apply_full_snapshot(layout, committed_state),
		"ENTERING 的 move 后完整快照必须接受 expected+1 的路线 revision。"
	)
	await process_frame
	await process_frame
	_expect(
		int(post_move_rejoin.get("_briefing_phase"))
		== RogueRouteGame.BriefingPhase.ENTERING,
		"move 后重连必须保留 ENTERING 简报阶段。"
	)
	_expect(
		int(post_move_rejoin.export_state_snapshot()["current_node_id"])
		== combat_node_id,
		"move 后重连必须恢复到目标作战节点。"
	)
	_expect(
		post_move_rejoin.combat_scene_transition.visible,
		"move 后重连必须恢复同一 occurrence 的 cover。"
	)

	# 新一轮屏障只收到 Host ready 时，远端断线应收缩 expected roster，
	# 并立即触发唯一一次权威提交。
	_expect(
		host_route.start_authoritative_session(seed, false),
		"断线屏障夹具必须能重置到同一固定路线。"
	)
	host_route.route_board.complete_entry_reveal()
	host_route.call(&"_on_route_board_node_pressed", combat_node_id)
	host_route.call(&"_on_node_briefing_confirmed")
	var disconnect_entering := host_route.export_briefing_state_snapshot()
	wrapper.call("_configure_briefing_cover_barrier", disconnect_entering)
	var disconnect_occurrence := str(disconnect_entering["occurrence_key"])
	var disconnect_briefing_revision := int(disconnect_entering["revision"])
	var disconnect_route_revision := int(
		disconnect_entering["expected_route_revision"]
	)
	_expect(
		bool(wrapper.call(
			"_accept_briefing_cover_ready",
			host_peer_id,
			disconnect_occurrence,
			disconnect_briefing_revision,
			disconnect_route_revision
		))
		and int(host_route.export_state_snapshot()["revision"])
		== disconnect_route_revision,
		"远端尚未 ready 时，Host ready 不能越过 cover 屏障。"
	)
	wrapper.call("_on_player_left", client_peer_id)
	_expect(
		int(host_route.export_state_snapshot()["revision"])
		== disconnect_route_revision + 1
		and not (wrapper.get(
			"_briefing_cover_expected_peers"
		) as Dictionary).has(client_peer_id)
		and bool(wrapper.get("_briefing_move_commit_started")),
		"cover 等待期间断线必须收缩 expected 集合并幂等完成剩余成员提交。"
	)

	if is_instance_valid(wrapper):
		wrapper.free()
	fake_net_manager.free()
	for route in [host_route, client_route, pre_move_rejoin, post_move_rejoin]:
		if is_instance_valid(route):
			route.queue_free()
	await process_frame


func _test_encounter_network_contract(
	host_route: RogueRouteGame,
	client_route: RogueRouteGame,
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
	var encounter_graph := RogueRouteGraph.import_layout(layout)
	var magical_node_ids := (
		encounter_graph.get_node_ids_by_type(
			RogueRouteGraph.NodeType.MAGICAL_ENCOUNTER
		)
		if encounter_graph != null
		else PackedInt32Array()
	)
	var magical_node_id := -1
	var map_encounter_ids: Array[StringName] = []
	var active_encounter_ids := RogueEncounterRegistry.get_pool_entries(
		RogueEncounterRegistry.MAGICAL_ENCOUNTER_POOL
	)
	for node_id in magical_node_ids:
		var selected_encounter := RogueEncounterRegistry.select_encounter_for_map(
			RogueEncounterRegistry.MAGICAL_ENCOUNTER_POOL,
			encounter_graph.generation_seed,
			magical_node_ids,
			node_id
		)
		map_encounter_ids.append(selected_encounter)
		if (
			magical_node_id < 0
			and
			selected_encounter != RogueEncounterRegistry.FLUORESCENT_PIT
			and not RogueEncounterRegistry.requires_result_ack(
				selected_encounter
			)
		):
			magical_node_id = node_id
	var unique_map_encounter_ids := map_encounter_ids.duplicate()
	unique_map_encounter_ids.sort()
	for index in range(unique_map_encounter_ids.size() - 1, 0, -1):
		if unique_map_encounter_ids[index] == unique_map_encounter_ids[index - 1]:
			unique_map_encounter_ids.remove_at(index)
	var map_assignment_complete := (
		encounter_graph != null
		and not magical_node_ids.is_empty()
		and map_encounter_ids.size() == magical_node_ids.size()
		and not map_encounter_ids.has(&"")
	)
	var map_assignment_uses_only_active_pool := true
	for encounter_id in map_encounter_ids:
		if not active_encounter_ids.has(encounter_id):
			map_assignment_uses_only_active_pool = false
			break
	_expect(
		map_assignment_complete
		and unique_map_encounter_ids.size() == magical_node_ids.size(),
		"同一张路线图的神奇遭遇必须完整地按地图 seed 一一分配且互不重复。"
	)
	_expect(
		map_assignment_uses_only_active_pool,
		"正式路线图的神奇遭遇分配必须全部属于当前活跃事件池。"
	)
	_expect(
		not map_encounter_ids.has(RogueEncounterRegistry.CHICKEN_BRO)
		and not map_encounter_ids.has(RogueEncounterRegistry.GHOST_SHADOW),
		"正式路线图不得分配处于预留状态的鸡哥或鬼影事件。"
	)
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
	var client_peer_id := fake_net_manager.host_peer_id + 1
	var started := host_route.export_encounter_snapshot(client_peer_id)
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
	var voting := host_route.export_encounter_snapshot(client_peer_id)
	_expect(
		bool(voting.get("voting_timer_running", false))
		and float(voting.get("remaining_seconds", 0.0)) > 0.0
		and float(voting.get("remaining_seconds", 0.0)) < 60.0,
		"独立遭遇场景的真实 reveal 信号必须使用最新 revision 启动60秒投票计时。"
	)
	var remaining_after_host_reveal := float(
		voting.get("remaining_seconds", 0.0)
	)
	var economy := host_route.export_encounter_economy_snapshot(client_peer_id)
	var client_state_before := client_route.export_encounter_snapshot()
	var forged_encounter := voting.duplicate(true)
	for candidate_id in RogueEncounterRegistry.get_pool_entries(
		RogueEncounterRegistry.MAGICAL_ENCOUNTER_POOL
	):
		if candidate_id != StringName(voting.get("encounter_id", &"")):
			forged_encounter["encounter_id"] = String(candidate_id)
			break
	_expect(
		not bool(client_route.call(
			"_validate_map_encounter_assignment",
			forged_encounter
		))
		and not client_route.apply_encounter_snapshot(
			forged_encounter,
			economy
		)
		and client_route.export_encounter_snapshot() == client_state_before,
		"客户端必须拒绝与当前模板 seed 确定分配不一致的神奇遭遇快照。"
	)
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
	var result := host_route.export_encounter_snapshot(client_peer_id)
	var result_pages := result.get("result_pages", []) as Array
	_expect(
		StringName(result.get("phase", &"")) == &"result"
		and bool(result.get("settlement_committed", false))
		and result_pages.size() == 1
		and str(result.get("result_text", ""))
		== str((result_pages[0] as Dictionary).get("text", "")),
		"投票完成后必须得到一次性权威结算及可无损同步的结果页。"
	)
	var result_economy := host_route.export_encounter_economy_snapshot(
		client_peer_id
	)
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
	var completed := host_route.export_encounter_snapshot(client_peer_id)
	var completed_economy := host_route.export_encounter_economy_snapshot(
		client_peer_id
	)
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
	var regenerated_encounter := host_route.export_encounter_snapshot(
		client_peer_id
	)
	var regenerated_economy := host_route.export_encounter_economy_snapshot(
		client_peer_id
	)
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
	var radiation_route := ROUTE_SCENE.instantiate() as RogueRouteGame
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
		(
			"放射性结果页必须显示本地角色真实最大生命前后值："
			+ "before=%d after=%d phase=%s pages=%s。"
			% [
				health_before,
				health_after,
				str(radiation_result.get("phase", &"")),
				str(local_pages),
			]
		)
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
	var failure_route := ROUTE_SCENE.instantiate() as RogueRouteGame
	failure_route.auto_initialize = false
	failure_route.manage_return_locally = true
	root.add_child(failure_route)
	await process_frame
	failure_route.manage_return_locally = false
	failure_route.call("_reset_encounter_runtime", true)
	var core_value := failure_route.get_node(
		"HUD/Root/TopBar/TopLayout/CoreStat/CoreRow/CoreValue"
	) as Label
	_expect(
		core_value.text == "2/100",
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
		and core_value.text == "0/100",
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
	host_route: RogueRouteGame,
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
	configure_wrapper.set("_run_state", shared_run_state)
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
	host_route: RogueRouteGame,
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
	shared_run_state.register_multiplayer_peer_state(old_peer_id)
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
	reconnect_wrapper.set("_run_state", shared_run_state)
	root.add_child(reconnect_wrapper)
	fake_net_manager.fixture_stable_participant_keys[migrated_peer_id] = (
		fake_net_manager.get_stable_participant_key(old_peer_id)
	)
	fake_net_manager.connected_players[migrated_peer_id] = "ClientReconnected"
	_expect(
		fake_net_manager.begin_fixture_reconnect(old_peer_id, migrated_peer_id),
		"原位重连夹具必须先建立 RECONNECTING 投影租约。"
	)
	var live_reconnect_succeeded := bool(reconnect_wrapper.call(
		"_finish_player_reconnect",
		old_peer_id,
		migrated_peer_id,
		"ClientReconnected",
		PlayerCharacterRegistry.TANGO_ID,
		fake_net_manager.fixture_membership_revision
	))
	_expect(
		live_reconnect_succeeded
		and host_route.get_player_for_peer(old_peer_id) == null
		and host_route.get_player_for_peer(migrated_peer_id) == old_player,
		"仍在场的重连 peer 必须原位迁移同一角色节点。"
	)
	_expect(
		fake_net_manager.fixture_runtime_projection_reports.size() == 1
		and fake_net_manager.fixture_runtime_projection_reports[0]
		== {
			"old_peer_id": old_peer_id,
			"new_peer_id": migrated_peer_id,
			"outcome": int(
				MultiplayerReconnectTypes.RuntimeProjectionOutcome.RESTORED
			),
			"membership_revision": fake_net_manager.fixture_membership_revision,
		},
		"原位迁移完成后必须恰好提交一次 RESTORED 运行时终态。"
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
	fake_net_manager.fixture_membership_revision += 1
	fake_net_manager.fixture_stable_participant_keys[replacement_peer_id] = (
		fake_net_manager.get_stable_participant_key(migrated_peer_id)
	)
	fake_net_manager.connected_players[replacement_peer_id] = "ClientRestored"
	_expect(
		fake_net_manager.begin_fixture_reconnect(
			migrated_peer_id,
			replacement_peer_id
		),
		"离线姿态补建夹具必须先建立 RECONNECTING 投影租约。"
	)
	_expect(
		bool(reconnect_wrapper.call(
			"_finish_player_reconnect",
			migrated_peer_id,
			replacement_peer_id,
			"ClientRestored",
			PlayerCharacterRegistry.TANGO_ID,
			fake_net_manager.fixture_membership_revision
		)),
		"已收到 player_left 的重连 peer 必须从保存姿态增量补建。"
	)
	_expect(
		fake_net_manager.fixture_runtime_projection_reports.size() == 2
		and int(
			fake_net_manager.fixture_runtime_projection_reports[1].get(
				"old_peer_id",
				0
			)
		) == migrated_peer_id
		and int(
			fake_net_manager.fixture_runtime_projection_reports[1].get(
				"new_peer_id",
				0
			)
		) == replacement_peer_id
		and int(
			fake_net_manager.fixture_runtime_projection_reports[1].get(
				"outcome",
				-1
			)
		)
		== int(MultiplayerReconnectTypes.RuntimeProjectionOutcome.RESTORED),
		"离线补建完成后必须提交第二个独立 RESTORED 终态。"
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
	shared_run_state.register_multiplayer_peer_state(collision_peer_id)
	fake_net_manager.fixture_membership_revision += 1
	fake_net_manager.fixture_stable_participant_keys[collision_peer_id] = (
		fake_net_manager.get_stable_participant_key(replacement_peer_id)
	)
	fake_net_manager.connected_players[collision_peer_id] = "ClientRemapped"
	_expect(
		fake_net_manager.begin_fixture_reconnect(
			replacement_peer_id,
			collision_peer_id
		),
		"冲突夹具必须从真实 RECONNECTING 前置状态开始。"
	)
	var collision_route_preparation := (
		host_route.prepare_reconnected_multiplayer_player_identity(
			replacement_peer_id,
			collision_peer_id,
			"ClientRemapped",
			PlayerCharacterRegistry.TANGO_ID,
			fake_net_manager.get_stable_participant_key(collision_peer_id),
			replacement.global_position
		)
	)
	var collision_route_preflight := int(collision_route_preparation.get(
		"result",
		RogueRouteGame.ReconnectedPlayerIdentityProjectionResult.INVALID
	))
	var collision_run_state_preflight := (
		shared_run_state.prepare_multiplayer_peer_state_remap(
			replacement_peer_id,
			collision_peer_id,
			fake_net_manager.fixture_membership_revision
		)
	)
	host_route.discard_reconnected_multiplayer_player_identity(
		collision_route_preparation
	)
	_expect(
		collision_route_preflight
		== RogueRouteGame.ReconnectedPlayerIdentityProjectionResult.READY
		and collision_run_state_preflight
		== RunStateStore.MultiplayerPeerRemapResult.CONFLICT
		and shared_run_state.has_multiplayer_peer_state(replacement_peer_id)
		and shared_run_state.has_multiplayer_peer_state(collision_peer_id)
		and host_route.get_player_for_peer(replacement_peer_id) == replacement
		and replacement.peer_id == replacement_peer_id
		and host_route.get_player_for_peer(collision_peer_id) == null,
		"目标 peer 已有账本时必须在路线提交前拒绝，Player/字典不得留下半写。"
	)
	_expect(
		fake_net_manager.fixture_runtime_projection_reports.size() == 2,
		"身份预检冲突不得误报 RESTORED 或消费运行时投影租约。"
	)
	fake_net_manager.cancel_fixture_reconnect(collision_peer_id)
	_expect(
		shared_run_state.reconcile_multiplayer_session_membership(
			PackedInt32Array([replacement_peer_id]),
			fake_net_manager.fixture_membership_revision
		),
		"顺序测试前必须由同一会话 revision 清理冲突目标。"
	)
	fake_net_manager.fixture_membership_revision += 1
	_expect(
		shared_run_state.remap_multiplayer_peer_state(
			replacement_peer_id,
			collision_peer_id,
			fake_net_manager.fixture_membership_revision
		) == RunStateStore.MultiplayerPeerRemapResult.MIGRATED
		and shared_run_state.try_add_item_count_for_peer(
			collision_peer_id,
			PLANK,
			2
		)
		and shared_run_state.try_add_item_count_for_peer(
			collision_peer_id,
			PLANK,
			2
		),
		"MpGame 监听者先到夹具必须先完成严格 RunState alias 并推进 new-peer revision。"
	)
	var target_revision := shared_run_state.get_inventory_revision_for_peer(
		collision_peer_id
	)
	fake_net_manager.host_role = false
	_expect(
		bool(reconnect_wrapper.call(
			"_finish_player_reconnect",
			replacement_peer_id,
			collision_peer_id,
			"ClientRemapped",
			PlayerCharacterRegistry.TANGO_ID,
			fake_net_manager.fixture_membership_revision
		))
		and not shared_run_state.has_multiplayer_peer_state(replacement_peer_id)
		and shared_run_state.has_multiplayer_peer_state(collision_peer_id)
		and shared_run_state.get_inventory_item_total_for_peer(
			collision_peer_id,
			PLANK
		) == 7
		and shared_run_state.get_inventory_revision_for_peer(collision_peer_id)
		== target_revision
		and shared_run_state.active_multiplayer_peer_id == collision_peer_id
		and shared_run_state.get_party_item_total(PLANK) == 7
		and shared_run_state.has_party_item(PLANK),
		(
			"RunState/MpGame 监听者先到时，路线必须识别 ALREADY_CURRENT 并只投影"
			+ " Player 身份，不能覆盖 new-peer 账本。"
		)
	)
	var newer_old_peer_id := collision_peer_id + 10
	var older_target_peer_id := collision_peer_id + 11
	shared_run_state.register_multiplayer_peer_state(newer_old_peer_id)
	shared_run_state.register_multiplayer_peer_state(older_target_peer_id)
	_expect(
		shared_run_state.try_add_item_count_for_peer(
			newer_old_peer_id,
			PLANK,
			3
		)
		and shared_run_state.try_add_item_count_for_peer(
			newer_old_peer_id,
			PLANK,
			3
		)
		and shared_run_state.try_add_item_count_for_peer(
			older_target_peer_id,
			PLANK,
			1
		)
		and shared_run_state.remap_multiplayer_peer_state(
			newer_old_peer_id,
			older_target_peer_id,
			shared_run_state.get_multiplayer_session_membership_revision() + 1
		)
		== RunStateStore.MultiplayerPeerRemapResult.CONFLICT
		and shared_run_state.has_multiplayer_peer_state(newer_old_peer_id)
		and shared_run_state.has_multiplayer_peer_state(older_target_peer_id)
		and shared_run_state.get_inventory_item_total_for_peer(
			newer_old_peer_id,
			PLANK
		) == 6
		and shared_run_state.get_inventory_item_total_for_peer(
			older_target_peer_id,
			PLANK
		) == 1,
		"old/new 双份账本必须判为身份冲突，不能按 revision 拼接玩家状态。"
	)
	var desired_session_peer_ids := PackedInt32Array([
		fake_net_manager.host_peer_id,
		observer_peer_id,
		collision_peer_id,
	])
	var expanded_session_peer_ids := (
		shared_run_state.get_registered_multiplayer_peer_ids()
	)
	for session_peer_id in desired_session_peer_ids:
		if not expanded_session_peer_ids.has(session_peer_id):
			expanded_session_peer_ids.append(session_peer_id)
	_expect(
		shared_run_state.reconcile_multiplayer_session_membership(
			expanded_session_peer_ids,
			shared_run_state.get_multiplayer_session_membership_revision() + 1
		),
		"恢复真实会话夹具前必须先由 roster 补齐缺少的持久成员。"
	)
	_expect(
		shared_run_state.reconcile_multiplayer_session_membership(
			desired_session_peer_ids,
			shared_run_state.get_multiplayer_session_membership_revision() + 1
		),
		"随后必须由下一版 roster 原子移除冲突测试的候选身份。"
	)
	fake_net_manager.connected_players = {
		fake_net_manager.host_peer_id: "Host",
		observer_peer_id: "Observer",
		collision_peer_id: "ReconnectedClient",
	}
	fake_net_manager.connected_player_characters = {
		fake_net_manager.host_peer_id:
			PlayerCharacterRegistry.WEISHIDAIER_ID,
		observer_peer_id: PlayerCharacterRegistry.WEISHIDAIER_ID,
		collision_peer_id: PlayerCharacterRegistry.TANGO_ID,
	}
	var unseen_old_peer_id := collision_peer_id + 20
	var unseen_new_peer_id := collision_peer_id + 21
	fake_net_manager.connected_players[unseen_new_peer_id] = "LateReconnect"
	fake_net_manager.connected_player_characters[unseen_new_peer_id] = (
		PlayerCharacterRegistry.WEISHIDAIER_ID
	)
	shared_run_state.register_multiplayer_peer_state(unseen_old_peer_id)
	fake_net_manager.fixture_membership_revision = (
		shared_run_state.get_multiplayer_session_membership_revision() + 1
	)
	_expect(
		shared_run_state.remap_multiplayer_peer_state(
			unseen_old_peer_id,
			unseen_new_peer_id,
			fake_net_manager.fixture_membership_revision
		) == RunStateStore.MultiplayerPeerRemapResult.MIGRATED,
		"缺失旧 avatar 夹具必须先模拟较早监听者提交的持久身份 alias。"
	)
	var host_anchor := host_route.get_player_for_peer(fake_net_manager.host_peer_id)
	var host_anchor_position := (
		host_anchor.global_position if host_anchor != null else Vector2.ZERO
	)
	_expect(
		bool(reconnect_wrapper.call(
			"_finish_player_reconnect",
			unseen_old_peer_id,
			unseen_new_peer_id,
			"LateReconnect",
			PlayerCharacterRegistry.WEISHIDAIER_ID,
			fake_net_manager.fixture_membership_revision
		))
		and host_route.get_player_for_peer(unseen_new_peer_id) != null
		and host_route.get_player_for_peer(unseen_new_peer_id).global_position
			.is_equal_approx(host_route.clamp_avatar_position(host_anchor_position))
		and observer_player.global_position.is_equal_approx(observer_position),
		(
			"后加入客户端即使从未见过 old avatar，也必须为可信重连创建安全"
			+ "占位且不移动其他玩家。"
		)
	)
	reconnect_wrapper.call("_on_player_left", unseen_new_peer_id)
	await process_frame
	fake_net_manager.connected_players.erase(unseen_new_peer_id)
	fake_net_manager.connected_player_characters.erase(unseen_new_peer_id)
	var reconnecting_client_old_peer_id := collision_peer_id + 100
	shared_run_state.register_multiplayer_peer_state(
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
	fake_net_manager.fixture_membership_revision += 1
	_expect(
		bool(reconnect_wrapper.call(
			"_reconcile_run_state_to_session_membership"
		)),
		"重连者本人必须先用 CH0 会话 roster 清理已 final departure 的旧身份。"
	)
	# 此段把同一 Route 实例切作“重连者本人”夹具；私人 encounter 快照
	# 必须绑定其真实本地 transport id，不能再喂公共 target=-1。
	host_route.set("_local_peer_id", collision_peer_id)
	var authoritative_economy := (
		host_route.export_encounter_economy_snapshot(collision_peer_id)
	)
	var reconnect_full_applied := bool(reconnect_wrapper.call(
		"_apply_full_snapshot_from_peer",
		fake_net_manager.host_peer_id,
		host_route.export_layout_snapshot(),
		host_route.export_state_snapshot(),
		host_route.export_encounter_snapshot(collision_peer_id),
		authoritative_economy,
		{},
		shared_run_state.export_player_upgrade_ledger()
	))
	_expect(
		reconnect_full_applied
		and not shared_run_state.has_multiplayer_peer_state(
			reconnecting_client_old_peer_id
		)
		and shared_run_state.get_inventory_item_total_for_peer(
			collision_peer_id,
			PLANK
		) == 7
		and shared_run_state.get_inventory_revision_for_peer(collision_peer_id)
		== target_revision
		and shared_run_state.active_multiplayer_peer_id == collision_peer_id
		and shared_run_state.get_party_item_total(PLANK) == 7,
		"未收到 old→new 通知的重连者本人必须由 CH0 roster 清除旧键，经济全量不得按 transport roster 二次裁剪。"
	)
	# 塔防内嵌路线的玩家由 Tower coordinator 先从 roster 移除；Bridge
	# 必须在此之前保存非零独特姿态，并在 old→new 身份迁移后覆盖安全锚点。
	var embedded_old_peer_id := collision_peer_id
	var embedded_new_peer_id := collision_peer_id + 500
	var embedded_old_player := host_route.get_player_for_peer(
		embedded_old_peer_id
	)
	if embedded_old_player != null:
		var embedded_position := host_route.clamp_avatar_position(
			embedded_old_player.global_position + Vector2(31.0, -13.0)
		)
		embedded_old_player.global_position = embedded_position
		reconnect_wrapper.set("_embedded_campaign_mode", true)
		reconnect_wrapper.capture_embedded_route_peer_before_removal(
			embedded_old_peer_id
		)
		var embedded_character_id := embedded_old_player.get_character_id()
		# Tower 外层会先提交同一稳定参与者的 RunState 身份；路线只消费已经
		# 成为 new peer 的权威账本，不能在 Player 节点里猜测或复制旧账本。
		var embedded_ledger_migrated := (
			shared_run_state.remap_multiplayer_peer_state(
				embedded_old_peer_id,
				embedded_new_peer_id,
				shared_run_state.get_multiplayer_session_membership_revision() + 1
			)
			== RunStateStore.MultiplayerPeerRemapResult.MIGRATED
		)
		var coordinator_migrated := (
			embedded_ledger_migrated
			and host_route.migrate_multiplayer_player(
				embedded_old_peer_id,
				embedded_new_peer_id,
				"EmbeddedReconnect",
				embedded_character_id
			)
		)
		# 模拟 Tower coordinator 在旧节点已被移除时采用 Host 安全锚点；
		# Bridge 随后的 transport 迁移必须用缓存姿态覆盖该临时位置。
		if coordinator_migrated:
			host_route.get_player_for_peer(embedded_new_peer_id).global_position = (
				host_route.clamp_avatar_position(host_anchor_position)
			)
		reconnect_wrapper.migrate_embedded_peer_transport_state(
			embedded_old_peer_id,
			embedded_new_peer_id
		)
		_expect(
			embedded_ledger_migrated
			and coordinator_migrated
			and host_route.get_player_for_peer(embedded_new_peer_id) != null
			and host_route.get_player_for_peer(embedded_new_peer_id).global_position
			.is_equal_approx(embedded_position),
			"塔防内嵌路线断线重连必须恢复离线前的独特姿态，不能落到 Host 锚点。"
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
		"action_points_revision": int(
			state.get("action_points_revision", -1)
		),
		"from_node_id": current_node_id,
		"to_node_id": target_node_id,
		"move_cost": 1,
		"action_points": int(state.get("action_points", 0)) - 1,
		"target_visit_count": int(visited[target_node_id]) + 1,
	}


func _find_adjacent_normal_combat_fixture(
	config: RogueRouteGenerationConfig
) -> Dictionary:
	if config == null:
		return {}
	for seed in range(1, BRIEFING_SEED_SEARCH_LIMIT + 1):
		var graph := RogueRouteGenerator.generate(config, seed)
		if graph == null:
			continue
		for neighbor_id in graph.get_neighbors(graph.start_node_id):
			if (
				graph.get_node_type(neighbor_id)
				== RogueRouteGraph.NodeType.NORMAL_COMBAT
			):
				return {
					"seed": seed,
					"combat_node_id": int(neighbor_id),
				}
	return {}


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
	var tower_adapter := _bind_warehouse_tower_mode_adapter(runtime)
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
	tower_adapter.warehouses = runtime.warehouses
	var tower_economy := MpTowerEconomyCoordinator.new()
	tower_economy.bind_runtime(
		runtime,
		tower_adapter,
		run_state,
		net_manager,
		0.0
	)
	_expect(
		bool(tower_economy.call(
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
		bool(tower_economy.call(
			"_restore_authoritative_warehouse_from_ledger",
			restored,
			WAREHOUSE_NET_ID
		))
		and restored.get_storage_item_total(PLANK) == 6,
		"返回战斗并完成仓库网络配置后必须恢复路线期间保留的账本。"
	)
	_expect(
		tower_economy.capture_shared_warehouse_ledger()
		and run_state.get_shared_warehouse_item_total(PLANK) == 6,
		"离开战斗场景前必须从当前有效正 id 仓库全量刷新账本。"
	)
	restored.queue_free()
	source.queue_free()
	tower_economy.unbind_runtime(runtime)
	tower_economy.free()
	runtime.free()
	net_manager.free()
	run_state.free()
	await process_frame


func _bind_warehouse_tower_mode_adapter(
	runtime: WarehouseRuntimeStub
) -> WarehouseTowerModeAdapterStub:
	var adapter := WarehouseTowerModeAdapterStub.new()
	adapter.name = "MultiplayerModeAdapter"
	runtime.add_child(adapter)
	adapter.bind_runtime(runtime)
	runtime.multiplayer_mode_adapter = adapter
	runtime.tower_multiplayer_mode_adapter = adapter
	return adapter


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
