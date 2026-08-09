extends SceneTree

const ROUTE_SCENE := preload(
	"res://scene/game_modes/rogue/route/rogue_route_game.tscn"
)
const SHOP_CONFIG: RogueUndergroundShopConfig = preload(
	"res://resources/config/rogue_shop/shallow_mine_underground_shop.tres"
)
const BUILDING_ITEM: PickupConfig = preload(
	"res://resources/config/buildings/building_simple_fence.tres"
)

var failures: Array[String] = []


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	await _test_controller_route_and_snapshot_contracts()
	await process_frame
	await process_frame
	call_deferred(&"_finish")


func _test_controller_route_and_snapshot_contracts() -> void:
	var graph_and_state := _make_two_shop_route()
	var graph := graph_and_state.get("graph") as RogueRouteGraph
	var route_state := graph_and_state.get("state") as RogueRouteRuntimeState
	_expect(graph != null and route_state != null, "商店多人测试路线必须有效。")
	if graph == null or route_state == null:
		return

	var host_run_state := RunStateStore.new()
	host_run_state.begin_new_run(
		PlayerCharacterRegistry.DEFAULT_CHARACTER_ID,
		false
	)
	host_run_state.ensure_multiplayer_peer_state(1)
	_expect(
		host_run_state.set_party_xirang_balance(1, 20_000),
		"Host 必须能初始化个人息壤。"
	)
	_expect(
		host_run_state.try_add_item_for_peer(1, BUILDING_ITEM),
		"快照禁售校验必须具备建筑物品夹具。"
	)
	var host_route := ROUTE_SCENE.instantiate() as RogueRouteGame
	host_route.auto_initialize = false
	host_route.manage_return_locally = false
	root.add_child(host_route)
	var host_controller := host_route.underground_shop_controller
	_expect(
		host_controller.configure(SHOP_CONFIG, host_run_state),
		"Host 商店控制器必须完成显式配置。"
	)
	host_route.set_authority_enabled(true)
	host_controller.set_identity_context(
		true,
		99,
		{1: "玩家A"},
		{1: PlayerCharacterRegistry.DEFAULT_CHARACTER_ID},
		{1: "rogue-participant:v1:test-a"}
	)
	_expect(
		not host_controller.start_authoritative_for_node(
			graph.compute_layout_hash(),
			1,
			graph.get_node_content_seed(1),
			2,
			route_state.state_revision,
			[1]
		)
		and host_controller.get_phase()
		== RogueUndergroundShopSession.Phase.IDLE,
		"同一地下商店节点的 visit_count=2 重访不得重新打开商店。"
	)
	_expect(
		host_controller.start_authoritative_for_node(
			graph.compute_layout_hash(),
			1,
			graph.get_node_content_seed(1),
			1,
			route_state.state_revision,
			[1]
		),
		"Host 必须能为首次抵达的地下商店建立个人货架。"
	)
	var old_shopping := host_controller.export_snapshot_for_peer(1)
	_expect(
		(old_shopping.get("offers", []) as Array).size() == 8
		and int(old_shopping.get("schema_version", -1)) == 2
		and (old_shopping.get("consumable_prices", []) as Array).size()
		== SHOP_CONFIG.consumable_listings.size(),
		"目标私有快照必须携带8个报价与完整的 schema v2 会话价格表。"
	)

	var purchase_offer := (old_shopping.get("offers", []) as Array)[0] as Dictionary
	var expected_session_revision := int(old_shopping["session_revision"])
	var expected_shelf_revision := int(old_shopping["shelf_revision"])
	var expected_inventory_revision := int(old_shopping["inventory_revision"])
	var expected_xirang_revision := int(old_shopping["xirang_revision"])
	var balance_before_purchase := host_run_state.get_party_xirang_balance(1)
	_expect(
		host_route.host_submit_shop_purchase(
			1,
			"route-purchase-retry",
			str(old_shopping["occurrence_key"]),
			0,
			expected_session_revision,
			expected_shelf_revision,
			expected_inventory_revision,
			expected_xirang_revision
		),
		"Route façade 的首次购买必须成功。"
	)
	var balance_after_purchase := host_run_state.get_party_xirang_balance(1)
	var inventory_after_purchase := (
		host_run_state.export_inventory_snapshot_for_peer(1)
	)
	var shelf_after_purchase := host_controller.export_snapshot_for_peer(1)
	_expect(
		balance_after_purchase
		== balance_before_purchase - int(purchase_offer["price"]),
		"购买必须只扣除一次个人息壤。"
	)
	_expect(
		host_route.host_submit_shop_purchase(
			1,
			"route-purchase-retry",
			str(old_shopping["occurrence_key"]),
			0,
			expected_session_revision,
			expected_shelf_revision,
			expected_inventory_revision,
			expected_xirang_revision
		)
		and host_run_state.get_party_xirang_balance(1) == balance_after_purchase
		and host_run_state.export_inventory_snapshot_for_peer(1)
		== inventory_after_purchase
		and int(host_controller.export_snapshot_for_peer(1)["shelf_revision"])
		== int(shelf_after_purchase["shelf_revision"]),
		"同 request ID 的 Route 层可靠重试必须返回原成功结果且不产生第二次写入。"
	)

	var latest_old := host_controller.export_snapshot_for_peer(1)
	_expect(
		host_controller.host_submit_exit(
			1,
			str(latest_old["occurrence_key"]),
			int(latest_old["session_revision"])
		),
		"玩家完成退出转场后必须能提交退出回执。"
	)
	_expect(
		host_controller.begin_departing()
		and host_controller.close_departing(),
		"全员退出后 Host 必须封存并关闭旧商店会话。"
	)
	var old_closed := host_controller.export_snapshot_for_peer(1)

	_expect(
		route_state.try_move(4, 1, route_state.state_revision)
		and route_state.try_move(3, 1, route_state.state_revision),
		"测试队伍必须能抵达后续地下商店。"
	)
	_expect(
		host_controller.reset_runtime(
			true,
			99,
			{1: "玩家A"},
			{1: PlayerCharacterRegistry.DEFAULT_CHARACTER_ID},
			{1: "rogue-participant:v1:test-a"}
		),
		"Host 控制器必须能为后续 occurrence 重置会话。"
	)
	_expect(
		host_controller.start_authoritative_for_node(
			graph.compute_layout_hash(),
			3,
			graph.get_node_content_seed(3),
			1,
			route_state.state_revision,
			[1]
		),
		"后续地下商店必须建立新的 SHOPPING occurrence。"
	)
	var new_shopping := host_controller.export_snapshot_for_peer(1)

	var client_run_state := RunStateStore.new()
	client_run_state.begin_new_run(
		PlayerCharacterRegistry.DEFAULT_CHARACTER_ID,
		false
	)
	client_run_state.ensure_multiplayer_peer_state(1)
	var client_route := ROUTE_SCENE.instantiate() as RogueRouteGame
	client_route.auto_initialize = false
	client_route.manage_return_locally = false
	root.add_child(client_route)
	var client_controller := client_route.underground_shop_controller
	_expect(
		client_controller.configure(SHOP_CONFIG, client_run_state),
		"Client 商店控制器必须完成显式配置。"
	)
	client_controller.set_identity_context(
		false,
		1,
		{1: "玩家A"},
		{1: PlayerCharacterRegistry.DEFAULT_CHARACTER_ID},
		{1: "rogue-participant:v1:test-a"}
	)
	# 此测试只审计状态合同；锁住表现层，避免真实转场计时器跨越测试退出。
	client_controller.set("_transition_active", true)
	_expect(
		client_controller.apply_snapshot(new_shopping, graph, route_state),
		"Client 必须能应用后续商店的目标私有 SHOPPING 快照。"
	)
	var client_phase_after_new := client_controller.get_phase()
	var client_economy_after_new := client_run_state.export_party_economy_snapshot(
		PackedInt32Array([1])
	)
	_expect(
		not client_controller.apply_snapshot(old_closed, graph, route_state)
		and client_controller.get_phase() == client_phase_after_new
		and client_run_state.export_party_economy_snapshot(
			PackedInt32Array([1])
		) == client_economy_after_new,
		"新商店已开启后，旧 occurrence 的 CLOSED 快照不得覆盖会话或经济。"
	)

	await _test_full_snapshot_atomic_rejection(
		graph,
		route_state,
		new_shopping
	)
	_test_reconnect_snapshot_recovery(
		host_controller,
		host_run_state,
		client_controller,
		client_run_state,
		graph,
		route_state
	)

	host_route.queue_free()
	client_route.queue_free()
	await process_frame
	host_run_state.free()
	client_run_state.free()
	await process_frame


func _test_reconnect_snapshot_recovery(
	host_controller: RogueUndergroundShopController,
	host_run_state: RunStateStore,
	client_controller: RogueUndergroundShopController,
	client_run_state: RunStateStore,
	graph: RogueRouteGraph,
	route_state: RogueRouteRuntimeState
) -> void:
	var published_snapshots: Array[Dictionary] = []
	host_controller.host_snapshot_committed.connect(
		func(_peer_id: int, snapshot: Dictionary) -> void:
			published_snapshots.append(snapshot.duplicate(true))
	)
	host_controller.remove_peer(1)
	_expect(
		host_run_state.remap_multiplayer_peer_state(1, 70),
		"认证重连前必须先原子迁移个人背包与息壤。"
	)
	host_controller.set_identity_context(
		true,
		99,
		{70: "玩家A"},
		{70: PlayerCharacterRegistry.DEFAULT_CHARACTER_ID},
		{70: "rogue-participant:v1:test-a"}
	)
	host_controller.migrate_peer_as_exited(1, 70)
	var spectator_snapshot := host_controller.export_snapshot_for_peer(70)
	var every_published_snapshot_decodes := not published_snapshots.is_empty()
	for snapshot in published_snapshots:
		if not RogueUndergroundShopSession.new().apply_snapshot(snapshot):
			every_published_snapshot_decodes = false
			break
	_expect(
		every_published_snapshot_decodes
		and bool(spectator_snapshot.get("target_exited", false))
		and (spectator_snapshot.get("offers", []) as Array).is_empty(),
		"断线→重连过程中每个实际发布的目标快照都必须可解码，且 new peer 不重开商店。"
	)
	client_controller.set_identity_context(
		false,
		70,
		{70: "玩家A"},
		{70: PlayerCharacterRegistry.DEFAULT_CHARACTER_ID},
		{70: "rogue-participant:v1:test-a"}
	)
	_expect(
		client_controller.apply_snapshot(
			spectator_snapshot,
			graph,
			route_state
		)
		and bool(spectator_snapshot.get("target_exited", false))
		and client_run_state.has_multiplayer_peer_state(70),
		"Client Session 仍缓存 old target 时，必须仅靠 new spectator 全量快照恢复到路线地图。"
	)


func _test_full_snapshot_atomic_rejection(
	graph: RogueRouteGraph,
	route_state: RogueRouteRuntimeState,
	valid_shop_snapshot: Dictionary
) -> void:
	var client_run_state := RunStateStore.new()
	client_run_state.begin_new_run(
		PlayerCharacterRegistry.DEFAULT_CHARACTER_ID,
		false
	)
	client_run_state.ensure_multiplayer_peer_state(1)
	var route := ROUTE_SCENE.instantiate() as RogueRouteGame
	route.auto_initialize = false
	route.manage_return_locally = false
	root.add_child(route)
	var controller := route.underground_shop_controller
	_expect(
		controller.configure(SHOP_CONFIG, client_run_state),
		"全量快照原子性测试控制器必须配置成功。"
	)
	controller.set_identity_context(
		false,
		1,
		{1: "玩家A"},
		{1: PlayerCharacterRegistry.DEFAULT_CHARACTER_ID},
		{1: "rogue-participant:v1:test-a"}
	)
	_expect(
		controller.preflight_snapshot(valid_shop_snapshot, graph, route_state),
		"未篡改的商店经济附加字段必须通过只读预检。"
	)
	var layout_snapshot := graph.export_layout().duplicate(true)
	layout_snapshot["runtime_contract_hash"] = route.get_runtime_contract_hash()
	var state_snapshot := route_state.export_state().duplicate(true)
	state_snapshot["briefing_state"] = {
		"schema_version": 1,
		"layout_hash": graph.compute_layout_hash(),
		"revision": 0,
		"phase": 0,
		"node_id": -1,
		"occurrence_key": "",
		"expected_route_revision": -1,
	}
	var economy_before := client_run_state.export_party_economy_snapshot(
		PackedInt32Array([1])
	)
	var phase_before := controller.get_phase()
	var route_before := {
		"ready": route.is_route_ready(),
		"layout": route.export_layout_snapshot(),
		"state": route.export_state_snapshot(),
		"briefing": route.export_briefing_state_snapshot(),
		"encounter": route.export_encounter_snapshot(),
	}

	var bad_party := valid_shop_snapshot.duplicate(true)
	var bad_party_economy := bad_party["party_economy"] as Dictionary
	bad_party_economy["schema_version"] = -1
	bad_party["party_economy"] = bad_party_economy
	_expect(
		not route.apply_full_snapshot(
			layout_snapshot,
			state_snapshot,
			{},
			{},
			bad_party
		)
		and _route_and_economy_are_unchanged(
			route,
			controller,
			client_run_state,
			phase_before,
			economy_before,
			route_before
		),
		"坏 party_economy 必须在路线呈现前原子拒绝，不能写入任一状态。"
	)

	var bad_session_price := valid_shop_snapshot.duplicate(true)
	var consumable_prices := bad_session_price["consumable_prices"] as Array
	var first_price_entry := (consumable_prices[0] as Dictionary).duplicate(true)
	first_price_entry["price"] = int(first_price_entry["price"]) + 1
	consumable_prices[0] = first_price_entry
	bad_session_price["consumable_prices"] = consumable_prices
	_expect(
		not route.apply_full_snapshot(
			layout_snapshot,
			state_snapshot,
			{},
			{},
			bad_session_price
		)
		and _route_and_economy_are_unchanged(
			route,
			controller,
			client_run_state,
			phase_before,
			economy_before,
			route_before
		),
		"未按10量化的个人会话价格表必须在全量快照提交前原子拒绝。"
	)

	var bad_price := valid_shop_snapshot.duplicate(true)
	var price_slots := bad_price["sell_slots"] as Array
	var priced_slot_index := _find_first_priced_slot(price_slots)
	_expect(priced_slot_index >= 0, "售价篡改测试必须找到可售槽位。")
	if priced_slot_index >= 0:
		var priced_slot := (price_slots[priced_slot_index] as Dictionary).duplicate(true)
		priced_slot["sell_price"] = int(priced_slot["sell_price"]) + 1
		price_slots[priced_slot_index] = priced_slot
		bad_price["sell_slots"] = price_slots
		_expect(
			not route.apply_full_snapshot(
				layout_snapshot,
				state_snapshot,
				{},
				{},
				bad_price
			)
			and _route_and_economy_are_unchanged(
				route,
				controller,
				client_run_state,
				phase_before,
				economy_before,
				route_before
			),
			"伪造回收价必须原子拒绝，不能改变路线、简报、遭遇、Session 或账本。"
		)

	var bad_building := valid_shop_snapshot.duplicate(true)
	var building_slots := bad_building["sell_slots"] as Array
	var building_slot_index := _find_slot_for_path(
		building_slots,
		BUILDING_ITEM.resource_path
	)
	_expect(building_slot_index >= 0, "禁售篡改测试必须找到建筑槽位。")
	if building_slot_index >= 0:
		var building_slot := (
			building_slots[building_slot_index] as Dictionary
		).duplicate(true)
		building_slot["can_sell"] = true
		building_slot["sell_price"] = SHOP_CONFIG.material_sell_price
		building_slot["disabled_reason"] = ""
		building_slots[building_slot_index] = building_slot
		bad_building["sell_slots"] = building_slots
		_expect(
			not route.apply_full_snapshot(
				layout_snapshot,
				state_snapshot,
				{},
				{},
				bad_building
			)
			and _route_and_economy_are_unchanged(
				route,
				controller,
				client_run_state,
				phase_before,
				economy_before,
				route_before
			),
			"把禁售建筑伪造成可售商品必须在全量快照提交前原子拒绝。"
		)

	route.queue_free()
	await process_frame
	client_run_state.free()
	await process_frame


func _route_and_economy_are_unchanged(
	route: RogueRouteGame,
	controller: RogueUndergroundShopController,
	run_state: RunStateStore,
	expected_phase: int,
	expected_economy: Dictionary,
	expected_route: Dictionary
) -> bool:
	return (
		route.is_route_ready() == bool(expected_route.get("ready", false))
		and route.export_layout_snapshot() == expected_route.get("layout", {})
		and route.export_state_snapshot() == expected_route.get("state", {})
		and route.export_briefing_state_snapshot()
		== expected_route.get("briefing", {})
		and route.export_encounter_snapshot()
		== expected_route.get("encounter", {})
		and controller.get_phase() == expected_phase
		and run_state.export_party_economy_snapshot(
			PackedInt32Array([1])
		) == expected_economy
	)


func _make_two_shop_route() -> Dictionary:
	var node_types := PackedByteArray()
	node_types.resize(9)
	node_types.fill(RogueRouteGraph.NodeType.EMPTY)
	node_types[1] = RogueRouteGraph.NodeType.UNDERGROUND_SHOP
	node_types[3] = RogueRouteGraph.NodeType.UNDERGROUND_SHOP
	var content_seeds := PackedInt64Array()
	content_seeds.resize(9)
	for node_id in 9:
		content_seeds[node_id] = 80_000 + node_id
	var offsets := PackedVector2Array()
	offsets.resize(9)
	offsets.fill(Vector2.ZERO)
	var graph := RogueRouteGraph.new()
	var errors := graph.initialize_layout(
		99,
		3,
		3,
		4,
		node_types,
		content_seeds,
		offsets,
		PackedInt32Array([
			0, 1,
			0, 3,
			1, 2,
			1, 4,
			2, 5,
			3, 4,
			3, 6,
			4, 5,
			4, 7,
			5, 8,
			6, 7,
			7, 8,
		])
	)
	if not errors.is_empty():
		return {}
	var state := RogueRouteRuntimeState.new()
	if not state.initialize(graph, 20) or not state.try_move(1, 1, 0):
		return {}
	return {"graph": graph, "state": state}


func _find_first_priced_slot(slots: Array) -> int:
	for slot_index in slots.size():
		var slot := slots[slot_index] as Dictionary
		if bool(slot.get("can_sell", false)) and int(slot.get("sell_price", 0)) > 0:
			return slot_index
	return -1


func _find_slot_for_path(slots: Array, config_path: String) -> int:
	for slot_index in slots.size():
		var slot := slots[slot_index] as Dictionary
		if str(slot.get("config_path", "")) == config_path:
			return slot_index
	return -1


func _finish() -> void:
	if failures.is_empty():
		print("ROGUE_UNDERGROUND_SHOP_MULTIPLAYER_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
