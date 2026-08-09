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
	_complete_test()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _complete_test() -> void:
	if failures.is_empty():
		print("ROGUE_SUPPLY_ROUTE_INTEGRATION_SMOKE_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)
