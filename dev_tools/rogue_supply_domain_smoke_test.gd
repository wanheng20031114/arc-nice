extends SceneTree

const DEFAULT_CONFIG: RogueRouteGenerationConfig = preload(
	"res://resources/config/rogue_route/p3_generation_config.tres"
)

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_option_rolls()
	var run_state := RunStateStore.new()
	root.add_child(run_state)
	run_state.begin_new_run(PlayerCharacterRegistry.DEFAULT_CHARACTER_ID, false)
	run_state.ensure_multiplayer_peer_state(1)
	run_state.ensure_multiplayer_peer_state(2)
	var graph := RogueRouteGenerator.generate(DEFAULT_CONFIG, 0x51A77E)
	_expect(graph != null, "物资测试必须能生成路线图。")
	if graph == null:
		_finish()
		return
	var route_state := RogueRouteRuntimeState.new()
	_expect(
		route_state.initialize(graph, DEFAULT_CONFIG.initial_action_points),
		"物资测试必须能初始化路线运行状态。"
	)
	var economy := RogueSupplyEconomyCoordinator.new()
	root.add_child(economy)
	economy.reset_runtime(
		run_state,
		route_state,
		{
			1: PlayerCharacterRegistry.DEFAULT_CHARACTER_ID,
			2: PlayerCharacterRegistry.DEFAULT_CHARACTER_ID,
		}
	)
	var peers: Array[int] = [1, 2]

	_test_economy_options(economy, run_state, route_state, peers)
	_test_collectible_flow(economy, run_state, peers)
	_test_session_vote(economy, run_state, peers)
	_test_timeout_and_pending_lifecycle(economy, run_state, peers)
	_test_full_inventory_collectible_retry()
	await _test_full_inventory_envelope_drop()

	economy.queue_free()
	run_state.queue_free()
	await process_frame
	_finish()


func _test_option_rolls() -> void:
	for seed_value in range(256):
		var option_ids := RogueSupplyRegistry.select_options(seed_value)
		var unique: Dictionary = {}
		var has_free := false
		for option_id in option_ids:
			unique[option_id] = true
			has_free = has_free or not RogueSupplyRegistry.is_paid_option(option_id)
		_expect(
			option_ids.size() == 3 and unique.size() == 3 and has_free,
			"任意种子都必须生成三项不重复且至少一项免费的物资选项。"
		)
	var without_envelope: Array[StringName] = [
		RogueSupplyRegistry.OPTION_FLYING_ENVELOPE,
	]
	for seed_value in range(64):
		_expect(
			not RogueSupplyRegistry.select_options(
				seed_value,
				without_envelope
			).has(RogueSupplyRegistry.OPTION_FLYING_ENVELOPE),
			"全队已有信封后不得再次把信封抽入物资选项。"
		)


func _test_economy_options(
	economy: RogueSupplyEconomyCoordinator,
	run_state: RunStateStore,
	route_state: RogueRouteRuntimeState,
	peers: Array[int]
) -> void:
	var core_before := run_state.get_party_core_health()
	var core_max_before := run_state.get_party_core_maximum_health()
	var core_result := economy.resolve_option(
		RogueSupplyRegistry.OPTION_CORE_REPAIR,
		1,
		peers,
		"supply:test:core"
	)
	_expect(
		bool(core_result.get("resolved", false))
		and run_state.get_party_core_health() == core_before + 10
		and run_state.get_party_core_maximum_health() == core_max_before + 10,
		"核心补给必须同时增加10点上限和当前生命。"
	)
	var duplicate_core := economy.resolve_option(
		RogueSupplyRegistry.OPTION_CORE_REPAIR,
		1,
		peers,
		"supply:test:core"
	)
	_expect(
		duplicate_core == core_result
		and run_state.get_party_core_health() == core_before + 10,
		"同一 occurrence 重放不得重复结算核心奖励。"
	)

	var light_result := economy.resolve_option(
		RogueSupplyRegistry.OPTION_GAIN_LIGHT_STONES,
		2,
		peers,
		"supply:test:light"
	)
	_expect(
		bool(light_result.get("resolved", false))
		and run_state.get_party_light_stone_amount() == 3,
		"光石补给必须获得3块共享光石。"
	)
	var xirang_result := economy.resolve_option(
		RogueSupplyRegistry.OPTION_LIGHT_STONE_XIRANG,
		3,
		peers,
		"supply:test:large_xirang"
	)
	_expect(
		bool(xirang_result.get("resolved", false))
		and run_state.get_party_light_stone_amount() == 2
		and run_state.get_party_xirang_balance(1) == 5000
		and run_state.get_party_xirang_balance(2) == 5000,
		"光石换水晶必须只扣1块共享光石，并给每位玩家5000水晶。"
	)

	var ap_before := route_state.action_points
	var ap_result := economy.resolve_option(
		RogueSupplyRegistry.OPTION_GAIN_ACTION_POINTS,
		4,
		peers,
		"supply:test:ap"
	)
	_expect(
		bool(ap_result.get("resolved", false))
		and route_state.action_points == ap_before + 2,
		"免费行动补给必须增加2点行动力。"
	)
	var paid_ap_result := economy.resolve_option(
		RogueSupplyRegistry.OPTION_LIGHT_STONE_ACTION_POINTS,
		5,
		peers,
		"supply:test:paid_ap"
	)
	_expect(
		bool(paid_ap_result.get("resolved", false))
		and run_state.get_party_light_stone_amount() == 1
		and route_state.action_points == ap_before + 5,
		"光石行动补给必须扣1块光石并增加3点行动力。"
	)
	var light_before_failed_ap := run_state.get_party_light_stone_amount()
	var light_revision_before_failed_ap := (
		run_state.get_party_light_stone_ledger_revision()
	)
	var saved_action_points := route_state.action_points
	route_state.action_points = RogueRouteRuntimeState.MAX_ACTION_POINTS
	var failed_paid_ap := economy.resolve_option(
		RogueSupplyRegistry.OPTION_LIGHT_STONE_ACTION_POINTS,
		55,
		peers,
		"supply:test:paid_ap_overflow"
	)
	_expect(
		not bool(failed_paid_ap.get("resolved", false))
		and run_state.get_party_light_stone_amount() == light_before_failed_ap
		and run_state.get_party_light_stone_ledger_revision()
		== light_revision_before_failed_ap,
		"行动力达到上限时付费补给必须在扣光石前失败。"
	)
	route_state.action_points = saved_action_points
	var small_xirang_result := economy.resolve_option(
		RogueSupplyRegistry.OPTION_GAIN_XIRANG,
		6,
		peers,
		"supply:test:small_xirang"
	)
	_expect(
		bool(small_xirang_result.get("resolved", false))
		and run_state.get_party_xirang_balance(1) == 6000
		and run_state.get_party_xirang_balance(2) == 6000,
		"免费水晶补给必须给每位玩家增加1000息壤水晶。"
	)
	var envelope_result := economy.resolve_option(
		RogueSupplyRegistry.OPTION_FLYING_ENVELOPE,
		7,
		peers,
		"supply:test:envelope"
	)
	var envelope := load(
		RogueSupplyEconomyCoordinator.FLYING_ENVELOPE_PATH
	) as PickupConfig
	_expect(
		bool(envelope_result.get("resolved", false))
		and bool(envelope_result.get("reward_granted", false))
		and envelope != null
		and run_state.get_party_item_total(
			envelope,
			PackedInt32Array(peers)
		) == 1,
		"会飞的信封必须稳定发给一名有空位的参与玩家且全队只有一份。"
	)
	_expect(
		not bool(economy.resolve_option(
			RogueSupplyRegistry.OPTION_FLYING_ENVELOPE,
			8,
			peers,
			"supply:test:duplicate_envelope"
		).get("resolved", false)),
		"全队已有会飞的信封时不得再次发放。"
	)


func _test_collectible_flow(
	economy: RogueSupplyEconomyCoordinator,
	run_state: RunStateStore,
	peers: Array[int]
) -> void:
	var offers := economy.build_collectible_offers(7, peers)
	var light_before_invalid_offer := run_state.get_party_light_stone_amount()
	var light_revision_before_invalid_offer := (
		run_state.get_party_light_stone_ledger_revision()
	)
	var invalid_begin := economy.resolve_option(
		RogueSupplyRegistry.OPTION_LIGHT_STONE_COLLECTIBLES,
		7,
		peers,
		"supply:test:invalid_collectibles",
		{}
	)
	_expect(
		not bool(invalid_begin.get("resolved", false))
		and run_state.get_party_light_stone_amount() == light_before_invalid_offer
		and run_state.get_party_light_stone_ledger_revision()
		== light_revision_before_invalid_offer,
		"候选未完整生成时不得先扣除收藏品选项的光石。"
	)
	var begin_result := economy.resolve_option(
		RogueSupplyRegistry.OPTION_LIGHT_STONE_COLLECTIBLES,
		7,
		peers,
		"supply:test:collectibles",
		offers
	)
	_expect(
		bool(begin_result.get("resolved", false))
		and run_state.get_party_light_stone_amount() == 0,
		"收藏品三选一阶段必须先且只扣除1块共享光石。"
	)
	_expect(
		offers.size() == 2
		and (offers.get(1, []) as Array).size() == 3
		and (offers.get(2, []) as Array).size() == 3,
		"每位参与玩家必须获得独立的三张兼容收藏品候选。"
	)
	var peer_one_paths: Array[String] = []
	for raw_path in offers.get(1, []) as Array:
		peer_one_paths.append(str(raw_path))
	var claim := economy.claim_collectible(
		1,
		peer_one_paths,
		0,
		"supply:test:collectibles"
	)
	var duplicate_claim := economy.claim_collectible(
		1,
		peer_one_paths,
		0,
		"supply:test:collectibles"
	)
	_expect(
		bool(claim.get("claimed", false)) and duplicate_claim == claim,
		"个人收藏品领取必须成功且相同请求只能结算一次。"
	)
	var peer_two_paths: Array[String] = []
	for raw_path in offers.get(2, []) as Array:
		peer_two_paths.append(str(raw_path))
	_expect(
		bool(economy.claim_collectible(
			2,
			peer_two_paths,
			0,
			"supply:test:collectibles"
		).get("claimed", false)),
		"测试夹具必须领取第二名玩家的候选以清空待领取队列。"
	)


func _test_session_vote(
	economy: RogueSupplyEconomyCoordinator,
	run_state: RunStateStore,
	peers: Array[int]
) -> void:
	var session := RogueSupplySession.new()
	root.add_child(session)
	session.reset_authority(economy, peers)
	_expect(session.start_for_node(41, 0x7711, peers), "物资 Session 必须能首次启动。")
	var started := session.export_state()
	var option_ids := started.get("option_ids", []) as Array
	var availability := started.get("option_availability", {}) as Dictionary
	var available_option := &""
	for raw_option_id in option_ids:
		var option_id := StringName(raw_option_id)
		if bool(availability.get(String(option_id), false)):
			available_option = option_id
			break
	_expect(not available_option.is_empty(), "零光石状态的三项候选中仍必须至少一项可选。")
	_expect(
		session.submit_intro_ack(
			1,
			str(started["occurrence_key"]),
			int(started["revision"])
		),
		"参与玩家必须能确认物资引导。"
	)
	var after_first_ack := session.export_state()
	_expect(
		session.submit_intro_ack(
			2,
			str(after_first_ack["occurrence_key"]),
			int(after_first_ack["revision"])
		),
		"第二名参与玩家必须能确认物资引导。"
	)
	var voting := session.export_state()
	_expect(
		session.submit_vote(
			1,
			str(voting["occurrence_key"]),
			int(voting["revision"]),
			available_option
		),
		"参与玩家必须能提交首票。"
	)
	var after_first_vote := session.export_state()
	_expect(
		session.submit_vote(
			2,
			str(after_first_vote["occurrence_key"]),
			int(after_first_vote["revision"]),
			available_option
		),
		"全员完成投票后必须进入权威结算。"
	)
	var resolved := session.export_state()
	_expect(
		StringName(resolved.get("winning_option", &"")) == available_option
		and StringName(resolved.get("phase", &"")) in [
			RogueSupplySession.PHASE_RESULT,
			RogueSupplySession.PHASE_COLLECTIBLE_CHOICE,
		],
		"全员同票必须选出该项且只进入一次结果流程。"
	)
	session.queue_free()

	run_state.set_party_light_stone_amount(10)
	var tie_session := RogueSupplySession.new()
	root.add_child(tie_session)
	tie_session.reset_authority(economy, peers)
	var tie_seed := 0x4499
	_expect(tie_session.start_for_node(42, tie_seed, peers), "平票测试必须能启动新物资节点。")
	var tie_intro := tie_session.export_state()
	for peer_id in peers:
		_expect(
			tie_session.submit_intro_ack(
				peer_id,
				str(tie_intro["occurrence_key"]),
				int(tie_intro["revision"])
			),
			"平票测试的每名玩家都必须完成引导确认。"
		)
		tie_intro = tie_session.export_state()
	var tie_options := tie_intro.get("option_ids", []) as Array
	var first_option := StringName(tie_options[0])
	var second_option := StringName(tie_options[1])
	_expect(
		tie_session.submit_vote(
			1,
			str(tie_intro["occurrence_key"]),
			int(tie_intro["revision"]),
			first_option
		),
		"平票测试必须接受第一张票。"
	)
	var tie_after_first := tie_session.export_state()
	_expect(
		tie_session.submit_vote(
			2,
			str(tie_after_first["occurrence_key"]),
			int(tie_after_first["revision"]),
			second_option
		),
		"平票测试必须接受第二张票。"
	)
	var tie_candidates: Array[StringName] = [first_option, second_option]
	var expected_tie_winner: StringName = tie_candidates[
		RogueSupplyRandom.choose_index(tie_seed, &"supply_vote_tie", 2)
	]
	_expect(
		StringName(tie_session.export_state().get("winning_option", &""))
		== expected_tie_winner,
		"一比一平票必须由节点种子稳定决定胜项。"
	)
	tie_session.queue_free()


func _test_timeout_and_pending_lifecycle(
	_economy: RogueSupplyEconomyCoordinator,
	_run_state: RunStateStore,
	_peers: Array[int]
) -> void:
	var run_state := RunStateStore.new()
	root.add_child(run_state)
	run_state.begin_new_run(PlayerCharacterRegistry.DEFAULT_CHARACTER_ID, false)
	var peers: Array[int] = [101, 102]
	for peer_id in peers:
		run_state.ensure_multiplayer_peer_state(peer_id)
	run_state.set_party_light_stone_amount(20)
	var graph := RogueRouteGenerator.generate(DEFAULT_CONFIG, 0x771122)
	var route_state := RogueRouteRuntimeState.new()
	_expect(
		graph != null
		and route_state.initialize(graph, DEFAULT_CONFIG.initial_action_points),
		"pending 生命周期测试必须初始化独立路线状态。"
	)
	if graph == null or not route_state.is_initialized():
		run_state.queue_free()
		return
	var economy := RogueSupplyEconomyCoordinator.new()
	root.add_child(economy)
	economy.reset_runtime(
		run_state,
		route_state,
		{
			101: PlayerCharacterRegistry.DEFAULT_CHARACTER_ID,
			102: PlayerCharacterRegistry.DEFAULT_CHARACTER_ID,
		}
	)
	var session := RogueSupplySession.new()
	root.add_child(session)
	session.reset_authority(economy, peers)

	var timeout_seed := -1
	var timeout_winner: StringName = &""
	for candidate_seed in range(4096):
		var options := RogueSupplyRegistry.select_options(candidate_seed)
		var availability := economy.get_option_availability(options)
		var available: Array[StringName] = []
		for option_id in options:
			if bool(availability.get(String(option_id), false)):
				available.append(option_id)
		if available.is_empty():
			continue
		var candidate_winner := available[RogueSupplyRandom.choose_index(
			candidate_seed,
			&"supply_timeout_no_vote",
			available.size()
		)]
		if candidate_winner != RogueSupplyRegistry.OPTION_LIGHT_STONE_COLLECTIBLES:
			timeout_seed = candidate_seed
			timeout_winner = candidate_winner
			break
	_expect(timeout_seed >= 0, "超时测试必须找到非收藏品的稳定零票种子。")
	if timeout_seed >= 0:
		_expect(session.start_for_node(70, timeout_seed, peers), "超时物资节点必须启动。")
		var intro := session.export_state()
		session.tick(RogueSupplySession.VOTING_TIMEOUT_SECONDS)
		_expect(
			StringName(session.export_state().get("phase", ""))
			== RogueSupplySession.PHASE_INTRO,
			"倒计时不得在物资界面首个 reveal/ack 前偷跑。"
		)
		_expect(
			session.submit_intro_ack(
				101,
				str(intro["occurrence_key"]),
				int(intro["revision"])
			)
			and StringName(session.export_state().get("phase", ""))
			== RogueSupplySession.PHASE_VOTING,
			"首个玩家完成 reveal 后应立即开放投票，不等待慢客户端。"
		)
		session.tick(RogueSupplySession.VOTING_TIMEOUT_SECONDS)
		var timed_out := session.export_state()
		_expect(
			StringName(timed_out.get("winning_option", "")) == timeout_winner
			and StringName(timed_out.get("phase", ""))
			== RogueSupplySession.PHASE_RESULT,
			"全员零票超时必须由节点种子稳定选出可结算项。"
		)
		for peer_id in peers:
			if (timed_out.get("active_peer_ids", []) as Array).has(peer_id):
				session.submit_completion(
					peer_id,
					str(timed_out["occurrence_key"]),
					session.get_revision()
				)
				timed_out = session.export_state()

	var collectible_seed := -1
	for candidate_seed in range(4096):
		if RogueSupplyRegistry.select_options(candidate_seed).has(
			RogueSupplyRegistry.OPTION_LIGHT_STONE_COLLECTIBLES
		):
			collectible_seed = candidate_seed
			break
	_expect(collectible_seed >= 0, "pending 测试必须找到收藏品选项种子。")
	if collectible_seed >= 0:
		_expect(session.start_for_node(71, collectible_seed, peers), "A 物资节点必须启动。")
		var state := session.export_state()
		for peer_id in peers:
			_expect(session.submit_intro_ack(
				peer_id,
				str(state["occurrence_key"]),
				int(state["revision"])
			), "A 节点参与者必须完成 reveal。")
			state = session.export_state()
		for peer_id in peers:
			_expect(session.submit_vote(
				peer_id,
				str(state["occurrence_key"]),
				int(state["revision"]),
				RogueSupplyRegistry.OPTION_LIGHT_STONE_COLLECTIBLES
			), "A 节点必须接受收藏品投票。")
			state = session.export_state()
		var occurrence_a := str(state["occurrence_key"])
		_expect(session.remove_peer(102), "A 节点必须记录第二名玩家断线。")
		state = session.export_state()
		_expect(
			session.submit_collectible_choice(
				101,
				occurrence_a,
				int(state["revision"]),
				0
			)
			and session.get_phase() == RogueSupplySession.PHASE_RESULT
			and session.has_pending_collectible_for_peer(102),
			"在线玩家领完后必须进入结果，离线玩家 pending 不得锁住全队。"
		)
		state = session.export_state()
		_expect(session.submit_completion(
			101,
			str(state["occurrence_key"]),
			int(state["revision"])
		), "在线玩家必须能结束 A 节点。")

		# B 再次选择收藏品，证明不同 occurrence 的 pending 可同时存在。
		run_state.set_party_light_stone_amount(20)
		_expect(session.start_for_node(72, collectible_seed, [101]), "B 物资节点必须启动。")
		state = session.export_state()
		_expect(session.submit_intro_ack(
			101,
			str(state["occurrence_key"]),
			int(state["revision"])
		), "B 节点必须完成 reveal。")
		state = session.export_state()
		_expect(session.submit_vote(
			101,
			str(state["occurrence_key"]),
			int(state["revision"]),
			RogueSupplyRegistry.OPTION_LIGHT_STONE_COLLECTIBLES
		), "B 节点必须再次结算收藏品选项。")
		state = session.export_state()
		var occurrence_b := str(state["occurrence_key"])
		_expect(
			economy.has_pending_collectible_claims()
			and session.has_pending_collectible_for_peer(101)
			and session.has_pending_collectible_for_peer(102),
			"A/B 两个 occurrence 的个人 pending 必须并存。"
		)
		_expect(session.submit_collectible_choice(
			101,
			occurrence_b,
			int(state["revision"]),
			0
		), "B 节点在线玩家必须能领取自己的候选。")
		state = session.export_state()
		_expect(session.submit_completion(
			101,
			str(state["occurrence_key"]),
			int(state["revision"])
		), "在线玩家必须能结束 B 节点。")

		_expect(
			run_state.remap_multiplayer_peer_state(102, 122)
			and session.migrate_peer(102, 122)
			and session.has_pending_collectible_for_peer(122)
			and session.get_pending_collectible_occurrence_for_peer(122)
			== occurrence_a,
			"old 非 B participant 时，重连仍必须迁移 A 节点 pending。"
		)
		state = session.export_state()
		_expect(session.submit_collectible_choice(
			122,
			occurrence_a,
			int(state["revision"]) - 1,
			0
		), "重连玩家必须能用旧 offer 身份在 B 完成后领取，且不绑定当前节点 revision。")
		var inventory_snapshots := (
			(session.export_state()["economy_snapshot"] as Dictionary)
			.get("party_economy", {}) as Dictionary
		).get("inventories", []) as Array
		var exported_reconnect_inventory := false
		for raw_inventory in inventory_snapshots:
			if int((raw_inventory as Dictionary).get("peer_id", -1)) == 122:
				exported_reconnect_inventory = true
		_expect(
			exported_reconnect_inventory
			and not session.has_pending_collectible_for_peer(122),
			"领取后的组合快照必须携带重连玩家的新背包 revision。"
		)

		# A2 留下同一玩家 pending；该玩家在 B2 投票期先领 A2，再由
		# B2 新增 pending，旧 claimed 标志不得禁用新候选。
		run_state.set_party_light_stone_amount(20)
		_expect(session.start_for_node(73, collectible_seed, [101, 122]), "A2 节点必须启动。")
		state = session.export_state()
		for peer_id in [101, 122]:
			_expect(session.submit_intro_ack(
				peer_id,
				str(state["occurrence_key"]),
				int(state["revision"])
			), "A2 玩家必须完成 reveal。")
			state = session.export_state()
		for peer_id in [101, 122]:
			_expect(session.submit_vote(
				peer_id,
				str(state["occurrence_key"]),
				int(state["revision"]),
				RogueSupplyRegistry.OPTION_LIGHT_STONE_COLLECTIBLES
			), "A2 必须结算收藏品选项。")
			state = session.export_state()
		var occurrence_a2 := str(state["occurrence_key"])
		_expect(session.remove_peer(101), "A2 必须记录目标玩家断线。")
		state = session.export_state()
		_expect(session.submit_collectible_choice(
			122,
			occurrence_a2,
			int(state["revision"]),
			0
		), "A2 在线玩家必须完成领取。")
		state = session.export_state()
		_expect(session.submit_completion(
			122,
			str(state["occurrence_key"]),
			int(state["revision"])
		), "A2 在线玩家必须结束节点。")
		_expect(
			run_state.remap_multiplayer_peer_state(101, 121)
			and session.migrate_peer(101, 121),
			"A2 pending 身份必须迁移到重连 peer。"
		)
		run_state.set_party_light_stone_amount(20)
		_expect(session.start_for_node(74, collectible_seed, [121, 122]), "B2 节点必须启动。")
		state = session.export_state()
		for peer_id in [121, 122]:
			_expect(session.submit_intro_ack(
				peer_id,
				str(state["occurrence_key"]),
				int(state["revision"])
			), "B2 玩家必须完成 reveal。")
			state = session.export_state()
		_expect(session.submit_collectible_choice(
			121,
			occurrence_a2,
			int(state["revision"]),
			0
		), "重连玩家必须能在 B2 投票期先领 A2 pending。")
		state = session.export_state()
		for peer_id in [121, 122]:
			_expect(session.submit_vote(
				peer_id,
				str(state["occurrence_key"]),
				int(state["revision"]),
				RogueSupplyRegistry.OPTION_LIGHT_STONE_COLLECTIBLES
			), "B2 必须接受新收藏品投票。")
			state = session.export_state()
		_expect(
			session.get_phase() == RogueSupplySession.PHASE_COLLECTIBLE_CHOICE
			and session.has_pending_collectible_for_peer(121)
			and not (state.get("claimed_peer_ids", []) as Array).has(121)
			and session.submit_collectible_choice(
				121,
				str(state["occurrence_key"]),
				int(state["revision"]),
				0
			),
			"B2 新 pending 必须撤销旧 claimed 标志并保持可领取。"
		)

	session.queue_free()
	economy.queue_free()
	run_state.queue_free()


func _test_full_inventory_collectible_retry() -> void:
	var run_state := RunStateStore.new()
	root.add_child(run_state)
	run_state.begin_new_run(PlayerCharacterRegistry.DEFAULT_CHARACTER_ID, false)
	var peer_id := 201
	run_state.ensure_multiplayer_peer_state(peer_id)
	var basketball := load(
		"res://resources/config/collectibles/collectible_basketball.tres"
	) as PickupConfig
	_expect(basketball != null, "满包收藏品测试必须载入填充道具。")
	if basketball == null:
		run_state.queue_free()
		return
	for _slot_index in range(RunStateStore.INVENTORY_CAPACITY + 1):
		if not run_state.try_add_item_for_peer(peer_id, basketball):
			break
	_expect(
		not run_state.can_add_item_count_for_peer(peer_id, basketball, 1),
		"满包收藏品测试必须先填满背包。"
	)
	run_state.set_party_light_stone_amount(1)
	var economy := RogueSupplyEconomyCoordinator.new()
	root.add_child(economy)
	economy.reset_runtime(
		run_state,
		null,
		{peer_id: PlayerCharacterRegistry.DEFAULT_CHARACTER_ID}
	)
	var peers: Array[int] = [peer_id]
	var occurrence_key := "supply:test:full_collectible"
	var offers := economy.build_collectible_offers(0x9988, peers)
	var begin_result := economy.resolve_option(
		RogueSupplyRegistry.OPTION_LIGHT_STONE_COLLECTIBLES,
		0x9988,
		peers,
		occurrence_key,
		offers
	)
	var paths: Array[String] = []
	for raw_path in offers.get(peer_id, []) as Array:
		paths.append(str(raw_path))
	var revision_before_failed_claim := int(
		economy.export_snapshot(peers).get("revision", -1)
	)
	var failed_claim := economy.claim_collectible(
		peer_id,
		paths,
		0,
		occurrence_key
	)
	_expect(
		bool(begin_result.get("resolved", false))
		and str(failed_claim.get("reason", "")) == "inventory_full"
		and economy.has_pending_collectible_claims()
		and int(economy.export_snapshot(peers).get("revision", -1))
		== revision_before_failed_claim,
		"满包领取失败不得删除 pending 或推进 economy revision。"
	)
	var discard_revision := run_state.get_inventory_revision_for_peer(peer_id)
	_expect(
		run_state.clear_item_slot_for_peer_if_revision(
			peer_id,
			0,
			discard_revision
		),
		"满包领取测试必须能清出一个槽位。"
	)
	var successful_claim := economy.claim_collectible(
		peer_id,
		paths,
		0,
		occurrence_key
	)
	var duplicate_claim := economy.claim_collectible(
		peer_id,
		paths,
		0,
		occurrence_key
	)
	_expect(
		bool(successful_claim.get("claimed", false))
		and duplicate_claim == successful_claim
		and not economy.has_pending_collectible_claims(),
		"腾位后收藏品必须只领取一次并清除 pending。"
	)
	economy.queue_free()
	run_state.queue_free()


func _test_full_inventory_envelope_drop() -> void:
	var run_state := RunStateStore.new()
	root.add_child(run_state)
	run_state.begin_new_run(PlayerCharacterRegistry.DEFAULT_CHARACTER_ID, false)
	var basketball := load(
		"res://resources/config/collectibles/collectible_basketball.tres"
	) as PickupConfig
	_expect(basketball != null, "满包信封测试必须能载入非堆叠收藏品。")
	if basketball == null:
		run_state.queue_free()
		return
	for peer_id in [11, 12]:
		run_state.ensure_multiplayer_peer_state(peer_id)
		for _slot_index in range(RunStateStore.INVENTORY_CAPACITY + 1):
			if not run_state.try_add_item_for_peer(peer_id, basketball):
				break
		_expect(
			not run_state.can_add_item_count_for_peer(peer_id, basketball, 1),
			"满包信封测试必须先填满每名玩家背包。"
		)
	var economy := RogueSupplyEconomyCoordinator.new()
	root.add_child(economy)
	economy.reset_runtime(run_state, null, {})
	var result := economy.resolve_option(
		RogueSupplyRegistry.OPTION_FLYING_ENVELOPE,
		99,
		[11, 12],
		"supply:test:full_inventory_envelope"
	)
	_expect(
		bool(result.get("resolved", false))
		and bool(result.get("reward_dropped", false))
		and not bool(result.get("reward_granted", false)),
		"所有参与玩家满包时信封必须正常完成结算并直接丢弃。"
	)
	economy.queue_free()
	run_state.queue_free()
	await process_frame


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("ROGUE_SUPPLY_DOMAIN_SMOKE_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)
