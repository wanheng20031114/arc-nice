extends SceneTree

const ROUTE_SCENE: PackedScene = preload(
	"res://scene/game_modes/rogue/route/rogue_route_game.tscn"
)

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var run_state := root.get_node_or_null("RunState") as RunStateStore
	if run_state == null:
		run_state = RunStateStore.new()
		run_state.name = "RunState"
		root.add_child(run_state)
	run_state.begin_new_run(PlayerCharacterRegistry.DEFAULT_CHARACTER_ID, false)
	var route := ROUTE_SCENE.instantiate() as RogueRouteGame
	route.auto_initialize = false
	route.manage_return_locally = true
	root.add_child(route)
	await process_frame
	_expect(
		route.start_authoritative_session(0x5A771, false),
		"物资路线集成测试必须能建立权威路线。"
	)
	_expect(
		route.supply_session.start_for_node(77, 0x5100, [0]),
		"物资 Session 必须能在路线根节点上启动。"
	)
	var combined_state := route.export_encounter_snapshot()
	var combined_economy := route.export_encounter_economy_snapshot()
	_expect(
		typeof(combined_state.get("supply_state")) == TYPE_DICTIONARY
		and not (combined_state["supply_state"] as Dictionary).is_empty()
		and typeof(combined_economy.get("supply_economy")) == TYPE_DICTIONARY
		and not (combined_economy["supply_economy"] as Dictionary).is_empty(),
		"既有遭遇快照信道必须原子携带物资状态与物资经济账本。"
	)
	var state := route.supply_session.export_state()
	_expect(
		route.host_submit_encounter_intro_ack(
			0,
			str(state["occurrence_key"]),
			int(state["revision"])
		),
		"路线的既有引导确认入口必须正确分派至物资 Session。"
	)
	state = route.supply_session.export_state()
	var availability := state.get("option_availability", {}) as Dictionary
	var selected_option: StringName = &""
	for raw_option_id in state.get("option_ids", []) as Array:
		var option_id := StringName(raw_option_id)
		if bool(availability.get(String(option_id), false)):
			selected_option = option_id
			break
	_expect(not selected_option.is_empty(), "物资路线必须至少提供一项可投票选项。")
	_expect(
		route.host_submit_encounter_vote(
			0,
			str(state["occurrence_key"]),
			int(state["revision"]),
			selected_option
		),
		"路线的既有投票入口必须正确分派至物资 Session。"
	)
	state = route.supply_session.export_state()
	_expect(
		StringName(state.get("phase", &"")) == RogueSupplySession.PHASE_RESULT,
		"单人投票后必须完成一次权威结算并进入结果阶段。"
	)
	_expect(
		route.host_submit_encounter_result_ack(
			0,
			str(state["occurrence_key"]),
			int(state["revision"])
		),
		"路线的既有结果确认入口必须正确分派至物资 Session。"
	)
	_expect(
		route.supply_session.get_phase() == RogueSupplySession.PHASE_COMPLETED
		and route.supply_session.is_node_resolved(77)
		and not route.supply_session.start_for_node(77, 0x5100, [0]),
		"物资节点完成后必须记录首次访问，回访不得重复启动或结算。"
	)
	run_state.set_party_light_stone_amount(1)
	var collectible_seed := -1
	var excluded_options: Array[StringName] = []
	if route.supply_economy.party_has_flying_envelope():
		excluded_options.append(RogueSupplyRegistry.OPTION_FLYING_ENVELOPE)
	for candidate_seed in range(512):
		if RogueSupplyRegistry.select_options(
			candidate_seed,
			excluded_options
		).has(
			RogueSupplyRegistry.OPTION_LIGHT_STONE_COLLECTIBLES
		):
			collectible_seed = candidate_seed
			break
	_expect(collectible_seed >= 0, "路线集成测试必须找到收藏品选项种子。")
	_expect(
		route.supply_session.start_for_node(78, collectible_seed, [0]),
		"路线集成测试必须能开启第二个物资节点。"
	)
	state = route.supply_session.export_state()
	_expect(
		(state.get("option_ids", []) as Array).has(
			String(RogueSupplyRegistry.OPTION_LIGHT_STONE_COLLECTIBLES)
		)
		and bool((state.get("option_availability", {}) as Dictionary).get(
			String(RogueSupplyRegistry.OPTION_LIGHT_STONE_COLLECTIBLES),
			false
		)),
		"收藏品种子必须生成可用的收藏品三选一选项。"
	)
	if StringName(state.get("phase", &"")) == RogueSupplySession.PHASE_INTRO:
		_expect(
			route.host_submit_encounter_intro_ack(
				0,
				str(state["occurrence_key"]),
				int(state["revision"])
			),
			"第二个物资节点必须能完成引导确认。"
		)
	state = route.supply_session.export_state()
	_expect(
		route.host_submit_encounter_vote(
			0,
			str(state["occurrence_key"]),
			int(state["revision"]),
			RogueSupplyRegistry.OPTION_LIGHT_STONE_COLLECTIBLES
		),
		"路线必须能进入个人收藏品三选一阶段。"
	)
	state = route.supply_session.export_state()
	var post_supply_economy := route.export_encounter_economy_snapshot()
	var base_party_economy := post_supply_economy.get(
		"party_economy",
		{}
	) as Dictionary
	var supply_party_economy := (
		post_supply_economy.get("supply_economy", {}) as Dictionary
	).get("party_economy", {}) as Dictionary
	_expect(
		not base_party_economy.is_empty()
		and base_party_economy == supply_party_economy,
		"先有遭遇缓存再结算物资时，双经济快照必须都实时导出同一账本。"
	)
	var discard_item := load(
		"res://resources/config/collectibles/collectible_basketball.tres"
	) as PickupConfig
	_expect(
		discard_item != null and run_state.try_add_item(discard_item),
		"路线丢弃事务测试必须先放入一件可丢弃物品。"
	)
	var discard_slot := -1
	for slot_index in range(RunStateStore.INVENTORY_CAPACITY):
		if run_state.get_item(slot_index) == discard_item:
			discard_slot = slot_index
			break
	var discard_revision := run_state.get_inventory_revision()
	_expect(
		discard_slot >= 0
		and route.host_submit_supply_inventory_discard(
			0,
			str(state["occurrence_key"]),
			int(state["revision"]),
			discard_slot,
			discard_revision,
			discard_item.resource_path.sha256_text()
		)
		and run_state.get_item(discard_slot) == null
		and run_state.get_inventory_revision() == discard_revision + 1,
		"收藏品选择期间的整理背包必须由Host按revision与物品指纹权威丢弃。"
	)

	# 先领取本地第二个节点的收藏品并完成 Session，为双人断线夹具清场。
	state = route.supply_session.export_state()
	_expect(
		route.host_submit_supply_collectible_choice(
			0,
			str(state["occurrence_key"]),
			int(state["revision"]),
			0
		),
		"本地收藏品领取必须成功。"
	)
	state = route.supply_session.export_state()
	_expect(
		StringName(state.get("phase", &"")) == RogueSupplySession.PHASE_RESULT
		and route.host_submit_encounter_result_ack(
			0,
			str(state["occurrence_key"]),
			int(state["revision"])
		),
		"领取完成后必须能结束第二个物资节点。"
	)

	# 合法多人交叠：玩家2在收藏品阶段断线，玩家0完成节点后可继续路线；
	# 玩家2的 completed+pending 奖励必须跨作战/商店暂压并在最后 lease
	# 释放后从 Session 快照完整恢复，不能丢失或盖住外部场景。
	run_state.set_party_light_stone_amount(1)
	run_state.register_multiplayer_peer_state(2)
	_expect(
		route.supply_session.start_for_node(
			79,
			collectible_seed,
			[0, 2]
		),
		"双人物资断线夹具必须能启动。"
	)
	state = route.supply_session.export_state()
	for peer_id in [0, 2]:
		_expect(
			route.host_submit_encounter_intro_ack(
				peer_id,
				str(state["occurrence_key"]),
				int(state["revision"])
			),
			"双人物资夹具的引导确认必须成功。"
		)
		state = route.supply_session.export_state()
	for peer_id in [0, 2]:
		_expect(
			route.host_submit_encounter_vote(
				peer_id,
				str(state["occurrence_key"]),
				int(state["revision"]),
				RogueSupplyRegistry.OPTION_LIGHT_STONE_COLLECTIBLES
			),
			"双人物资夹具必须能一致选择收藏品奖励。"
		)
		state = route.supply_session.export_state()
	_expect(
		StringName(state.get("phase", &""))
		== RogueSupplySession.PHASE_COLLECTIBLE_CHOICE,
		"双人投票后必须进入个人收藏品选择阶段。"
	)
	route.host_remove_encounter_peer(2)
	state = route.supply_session.export_state()
	_expect(
		(route.supply_session.has_pending_collectible_for_peer(2))
		and (state.get("disconnected_peer_ids", []) as Array).has(2),
		"玩家2断线后必须保留其私有收藏品 offer。"
	)
	_expect(
		route.host_submit_supply_collectible_choice(
			0,
			str(state["occurrence_key"]),
			int(state["revision"]),
			0
		),
		"仍在线玩家必须能完成自己的收藏品选择。"
	)
	state = route.supply_session.export_state()
	_expect(
		StringName(state.get("phase", &"")) == RogueSupplySession.PHASE_RESULT
		and route.host_submit_encounter_result_ack(
			0,
			str(state["occurrence_key"]),
			int(state["revision"])
		),
		"在线玩家确认后节点必须进入 completed，不能等待断线玩家。"
	)
	state = route.supply_session.export_state()
	_expect(
		route.supply_session.get_phase() == RogueSupplySession.PHASE_COMPLETED
		and route.supply_session.has_pending_collectible_for_peer(2),
		"completed 终态必须继续保存玩家2的待领取奖励。"
	)

	# 模拟玩家2重连并首次收到 completed 快照：Supply 抢占已打开 Profile，
	# 但只派生本地输入锁，不重新把全局 encounter active 标为 true。
	route.player_profile_panel.open()
	route.set("_local_peer_id", 2)
	route.set("_local_supply_modal_owner_active", false)
	route.call(&"_configure_supply_overlay_context")
	route.call(&"_on_supply_state_changed", state)
	await process_frame
	_expect(
		not route.player_profile_panel.is_open()
		and route.supply_overlay.visible
		and route.supply_overlay.rendered_phase
		== RogueSupplySession.PHASE_COMPLETED
		and route.supply_overlay.collectible_modal.visible
		and bool(route.call(&"_is_route_input_locked"))
		and not bool(route.get("_encounter_input_locked")),
		"重连玩家的 completed+pending Supply 必须关闭旧 Profile、显示领取层并仅锁本地路线输入。"
	)

	# Stage 的直接结束与 ResultOverlay 自身关闭都是独立 owner 释放边界；
	# 不能假设协调器随后一定还会释放 lease 或再次调用 hide_result。
	route.set("_normal_combat_active", true)
	route.set("_normal_combat_occurrence_key", "combat:direct-complete")
	route.call(&"_reconcile_local_modal_presentations")
	_expect(
		not route.supply_overlay.visible
		and route.complete_normal_combat("combat:direct-complete")
		and route.supply_overlay.visible,
		"直接结束作战 stage 必须在同一事件边界恢复 pending Supply。"
	)
	_expect(
		route.show_combat_result({
			"victory": false,
			"failure_reason": "测试结算",
		})
		and not route.supply_overlay.visible,
		"作战结算展示期间必须暂压 pending Supply。"
	)
	route.combat_result_overlay.call(&"_on_close_button_pressed")
	await process_frame
	_expect(
		not route.combat_result_overlay.visible
		and route.supply_overlay.visible,
		"结算面板自行 dismiss 后必须直接恢复 pending Supply。"
	)

	# 作战与商店 lease 可乱序交叠；重复 full-state 回放不能让 Supply 在
	# 高优先级场景上方重开。只有最后 owner 释放才从 export_state 恢复。
	route.set_route_presentation_enabled(false)
	route.call(&"_set_shop_route_presentation_active", false)
	route.call(&"_on_supply_state_changed", state)
	_expect(
		not route.supply_overlay.visible
		and route.supply_session.has_pending_collectible_for_peer(2),
		"作战/商店期间重放 Supply 快照必须保持隐藏且不能消费待领取奖励。"
	)
	route.set_route_presentation_enabled(true)
	_expect(
		not route.supply_overlay.visible,
		"仍有商店 lease 时释放作战不得提前恢复 Supply。"
	)
	route.call(&"_set_shop_route_presentation_active", true)
	await process_frame
	_expect(
		route.supply_overlay.visible
		and route.supply_overlay.rendered_phase
		== RogueSupplySession.PHASE_COMPLETED
		and route.supply_overlay.collectible_modal.visible
		and bool(route.call(&"_is_route_input_locked")),
		"最后 lease 释放后必须从 Session 快照恢复完整待领取层与输入 owner。"
	)

	# Supply 显式背包入口仍可用；新的 exclusive owner 会关闭 Profile，
	# 返回路线后只恢复领取层，不能重开陈旧 Profile。
	route.call(&"_on_supply_inventory_requested")
	_expect(route.player_profile_panel.is_open(), "Supply 必须仍能显式打开整理背包。")
	route.call(&"_set_shop_route_presentation_active", false)
	_expect(
		not route.player_profile_panel.is_open()
		and not route.supply_overlay.visible,
		"商店 owner 必须同时关闭 Supply 显式 Profile 并暂压领取层。"
	)
	route.call(&"_set_shop_route_presentation_active", true)
	_expect(
		not route.player_profile_panel.is_open()
		and route.supply_overlay.visible,
		"商店退出只能恢复仍有效的 Supply Session，不能恢复陈旧 Profile。"
	)

	var pending_occurrence := (
		route.supply_session.get_pending_collectible_occurrence_for_peer(2)
	)
	_expect(
		route.host_submit_supply_collectible_choice(
			2,
			pending_occurrence,
			route.supply_session.get_revision(),
			0
		),
		"重连玩家必须能在 completed 终态领取保留的收藏品。"
	)
	await process_frame
	_expect(
		not route.supply_session.has_pending_collectible_for_peer(2)
		and not route.supply_overlay.visible
		and not bool(route.call(&"_is_route_input_locked")),
		"领取完成后必须释放本地 Supply owner 与路线输入锁。"
	)

	# Profile 已打开时远端 Rare Chest 首帧到达也必须立即抢占，避免 layer25
	# 盖住限时选择层；重置后不留下陈旧输入 owner。
	route.set("_local_peer_id", 0)
	route.call(&"_configure_supply_overlay_context")
	route.player_profile_panel.open()
	_expect(
		route.rare_chest_session.start_for_node(
			80,
			0x8055,
			[0],
			{0: "singleplayer:local"}
		),
		"Rare Chest Profile 抢占夹具必须能启动。"
	)
	await process_frame
	_expect(
		not route.player_profile_panel.is_open()
		and route.rare_chest_overlay.visible,
		"Rare Chest active 快照必须关闭已打开的 Profile。"
	)
	route.call(&"_reset_rare_chest_runtime", true)

	# Briefing PRESENTED/ENTERING 过去只手工锁 board/player，Profile 的全局
	# Bag 门禁会陈旧。通过统一 refresh 后，Briefing 期间 Bag 不得重开面板。
	route.player_profile_panel.open()
	var runtime_state := route.get("_runtime_state") as RogueRouteRuntimeState
	route.set("_briefing_phase", RogueRouteGame.BriefingPhase.ENTERING)
	route.set("_briefing_node_id", runtime_state.current_node_id)
	route.set("_briefing_expected_route_revision", runtime_state.state_revision)
	route.set("_briefing_occurrence_key", "briefing-input-owner-test")
	route.set("_briefing_revision", 1)
	route.combat_scene_transition.visible = true
	route.call(&"_sync_briefing_presentation", RogueRouteGame.BriefingPhase.NONE)
	await _send_bag_action()
	_expect(
		not route.player_profile_panel.is_open()
		and not route.player_profile_panel.is_processing_unhandled_input()
		and bool(route.call(&"_is_route_input_locked")),
		"Briefing ENTERING 必须关闭 Profile、禁用 Bag 重开并保持统一路线锁。"
	)
	route.set("_briefing_phase", RogueRouteGame.BriefingPhase.NONE)
	route.call(
		&"_sync_briefing_presentation",
		RogueRouteGame.BriefingPhase.ENTERING
	)
	await process_frame
	_complete_test()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _send_bag_action() -> void:
	var pressed := InputEventAction.new()
	pressed.action = &"bag"
	pressed.pressed = true
	Input.parse_input_event(pressed)
	await process_frame
	var released := InputEventAction.new()
	released.action = &"bag"
	released.pressed = false
	Input.parse_input_event(released)
	await process_frame


func _complete_test() -> void:
	if failures.is_empty():
		print("ROGUE_SUPPLY_ROUTE_INTEGRATION_SMOKE_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)
