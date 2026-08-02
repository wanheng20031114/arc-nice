extends SceneTree

const PLANK := preload("res://resources/config/materials/material_plank.tres")
const BASKETBALL := preload(
	"res://resources/config/collectibles/collectible_basketball.tres"
)

var _failures: PackedStringArray = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_warehouse_first_atomic_purchase()
	_test_four_player_mixed_payment_and_receiver()
	_test_party_item_query_across_stores()
	_test_full_inventory_never_charges()
	_test_session_personal_progress_and_timeout()
	_test_deterministic_tie_and_no_vote()
	_test_snapshot_replay_and_peer_migration()
	_test_dynamic_option_availability()
	_test_settled_result_and_spectator_migration()
	if _failures.is_empty():
		print("ROGUE_ENCOUNTER_CORE_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in _failures:
		push_error(failure)
	quit(1)


func _test_warehouse_first_atomic_purchase() -> void:
	var run_state := _new_run_state()
	run_state.ensure_multiplayer_peer_state(1)
	run_state.ensure_multiplayer_peer_state(2)
	_expect(run_state.try_add_item_count_for_peer(1, PLANK, 4), "应能放入付款木板。")
	_expect(
		run_state.replace_shared_warehouse_snapshots([
			_make_warehouse_snapshot(101, 3, PLANK.resource_path, 8),
		]),
		"共享仓库快照应能持久化。"
	)
	var economy := RogueEncounterEconomyCoordinator.new()
	economy.configure(run_state)
	var result := economy.resolve_chicken_bro(
		RogueEncounterEconomyCoordinator.OPTION_PURCHASE,
		47823,
		[1, 2],
		"purchase-dedup"
	)
	_expect(bool(result.get("resolved", false)), "购买应完成权威结算。")
	_expect(bool(result.get("reward_granted", false)), "购买应发放篮球。")
	_expect(int(result.get("warehouse_paid", -1)) == 8, "必须先扣仓库的8块木板。")
	_expect(
		int((result.get("player_payments", {}) as Dictionary).values()[0]) == 2,
		"仓库不足部分应只从玩家背包补足2块。"
	)
	_expect(
		run_state.get_party_item_total(BASKETBALL, PackedInt32Array([1, 2])) == 1,
		"每次成功交易全队应只得到一个篮球。"
	)
	_expect(
		run_state.get_party_item_total(PLANK, PackedInt32Array([1, 2])) == 2,
		"交易后应剩余2块玩家木板。"
	)
	var ledger := run_state.export_shared_warehouse_ledger()
	var warehouse := (ledger["warehouses"] as Array)[0] as Dictionary
	_expect(int(warehouse["revision"]) == 4, "被扣款仓库 revision 应只前进一次。")
	_expect(int(ledger["revision"]) == 2, "仓库账本 revision 应只前进一次。")
	var after_first_resolution := run_state.export_party_economy_snapshot(
		PackedInt32Array([1, 2])
	)
	var replayed_result := economy.resolve_chicken_bro(
		RogueEncounterEconomyCoordinator.OPTION_PURCHASE,
		47823,
		[1, 2],
		"purchase-dedup"
	)
	_expect(replayed_result == result, "同一 occurrence 重放必须返回首次结算结果。")
	_expect(
		run_state.export_party_economy_snapshot(PackedInt32Array([1, 2]))
		== after_first_resolution,
		"同一 occurrence 重放不得重复扣款或发放篮球。"
	)
	economy.free()
	run_state.free()


func _test_four_player_mixed_payment_and_receiver() -> void:
	var run_state := _new_run_state()
	var peers: Array[int] = [41, 42, 43, 44]
	for peer_id in peers:
		run_state.ensure_multiplayer_peer_state(peer_id)
	for peer_id in [41, 42, 43]:
		_expect(
			run_state.try_add_item_count_for_peer(peer_id, PLANK, 2),
			"四人混合付款应为三名玩家各准备2块木板。"
		)
	for _slot_index in RunStateStore.INVENTORY_CAPACITY:
		_expect(
			run_state.try_add_item_for_peer(44, BASKETBALL),
			"接收者筛选测试应填满玩家44背包。"
		)
	_expect(
		run_state.replace_shared_warehouse_snapshots([
			_make_warehouse_snapshot(401, 0, PLANK.resource_path, 4),
		]),
		"四人混合付款应建立4块木板仓库快照。"
	)
	var economy := RogueEncounterEconomyCoordinator.new()
	economy.configure(run_state)
	var seed := 24680
	var result := economy.resolve_chicken_bro(
		RogueEncounterEconomyCoordinator.OPTION_PURCHASE,
		seed,
		peers,
		"four-player-mixed"
	)
	var payments := result.get("player_payments", {}) as Dictionary
	var expected_receivers: Array[int] = [41, 42, 43]
	var expected_receiver := expected_receivers[
		RogueEncounterRandom.choose_index(
			seed,
			&"receiver",
			expected_receivers.size()
		)
	]
	_expect(
		bool(result.get("reward_granted", false))
		and int(result.get("warehouse_paid", -1)) == 4
		and payments.size() == 3,
		"四人购买必须先扣4块仓库木板，再从三名玩家各补足2块。"
	)
	for peer_id in [41, 42, 43]:
		_expect(
			int(payments.get(peer_id, 0)) == 2
			and run_state.get_inventory_item_total_for_peer(peer_id, PLANK) == 0,
			"payer_rotation 只能改变付款起点，不能漏扣任一所需付款人。"
		)
	_expect(
		int(result.get("receiver_peer_id", -1)) == expected_receiver
		and int(result.get("receiver_peer_id", -1)) != 44,
		"确定性接收者必须只从仍在线且有空位的玩家中选择。"
	)
	_expect(
		run_state.get_party_item_total(
			BASKETBALL,
			PackedInt32Array(peers)
		) == RunStateStore.INVENTORY_CAPACITY + 1,
		"四人交易仍只能额外发放一个篮球。"
	)
	economy.free()
	run_state.free()


func _test_full_inventory_never_charges() -> void:
	var run_state := _new_run_state()
	run_state.ensure_multiplayer_peer_state(3)
	for _slot_index in RunStateStore.INVENTORY_CAPACITY:
		_expect(
			run_state.try_add_item_for_peer(3, BASKETBALL),
			"测试背包应能被不可堆叠篮球填满。"
		)
	_expect(
		run_state.replace_shared_warehouse_snapshots([
			_make_warehouse_snapshot(202, 0, PLANK.resource_path, 10),
		]),
		"满背包用例应建立仓库。"
	)
	var before := run_state.export_party_economy_snapshot(PackedInt32Array([3]))
	var economy := RogueEncounterEconomyCoordinator.new()
	economy.configure(run_state)
	var result := economy.resolve_chicken_bro(
		RogueEncounterEconomyCoordinator.OPTION_PURCHASE,
		911,
		[3]
	)
	_expect(
		StringName(result.get("result_code", &""))
		== RogueEncounterEconomyCoordinator.RESULT_ALL_INVENTORIES_FULL,
		"全员满背包应返回明确结果。"
	)
	_expect(
		run_state.export_party_economy_snapshot(PackedInt32Array([3])) == before,
		"无法接收篮球时不得扣除任何木板或推进 revision。"
	)
	economy.free()
	run_state.free()


func _test_party_item_query_across_stores() -> void:
	var run_state := _new_run_state()
	run_state.ensure_multiplayer_peer_state(8)
	_expect(run_state.try_add_item_for_peer(8, BASKETBALL), "玩家背包应能持有篮球。")
	_expect(
		run_state.replace_shared_warehouse_snapshots([
			_make_warehouse_snapshot(301, 0, BASKETBALL.resource_path, 1),
			_make_warehouse_snapshot(302, 0, BASKETBALL.resource_path, 1),
		]),
		"两个仓库篮球快照应能一起导入。"
	)
	_expect(
		run_state.get_party_item_total(BASKETBALL, PackedInt32Array([8])) == 3,
		"全队物品查询应聚合玩家背包与所有共享仓库。"
	)
	_expect(
		run_state.has_party_item(BASKETBALL, PackedInt32Array([8])),
		"任意存储中存在篮球时 has_party_item 应返回真。"
	)
	_expect(run_state.discard_item_for_peer(8, 0), "测试玩家篮球应可丢弃。")
	run_state.clear_shared_warehouse_ledger(false)
	_expect(
		not run_state.has_party_item(BASKETBALL, PackedInt32Array([8])),
		"背包和仓库全部移除篮球后查询应返回假。"
	)
	run_state.free()


func _test_session_personal_progress_and_timeout() -> void:
	var run_state := _new_run_state()
	for peer_id in [1, 2]:
		run_state.ensure_multiplayer_peer_state(peer_id)
	_expect(
		run_state.try_add_item_count_for_peer(1, PLANK, 10),
		"改票测试应准备可用的付费选项。"
	)
	var economy := RogueEncounterEconomyCoordinator.new()
	economy.configure(run_state)
	var session := RogueEncounterSession.new()
	session.initialize_authority(economy, [1, 2])
	_expect(
		session.start_for_node(7, &"magical_encounter", 31337, [1, 2]),
		"鸡哥遭遇应从神奇遭遇池启动。"
	)
	var started := session.export_state()
	_expect(not bool(started["voting_timer_running"]), "reveal前倒计时不得偷跑。")
	session.tick(30.0)
	_expect(
		is_equal_approx(float(session.export_state()["remaining_seconds"]), 60.0),
		"未显式启动时 tick 不得消耗倒计时。"
	)
	var revision := session.get_revision()
	_expect(
		session.start_voting_timer(session.get_occurrence_key(), revision),
		"reveal完成后应能显式启动倒计时。"
	)
	revision = session.get_revision()
	_expect(
		session.submit_intro_ack(1, session.get_occurrence_key(), revision),
		"玩家1应能独立完成对白。"
	)
	revision = session.get_revision()
	_expect(
		session.submit_vote(
			1,
			session.get_occurrence_key(),
			revision,
			RogueEncounterEconomyCoordinator.OPTION_PURCHASE
		),
		"玩家1不等待玩家2即可投票。"
	)
	revision = session.get_revision()
	_expect(
		session.submit_vote(
			1,
			session.get_occurrence_key(),
			revision,
			RogueEncounterEconomyCoordinator.OPTION_FREE
		),
		"全员锁票前玩家应能修改自己的选择。"
	)
	_expect(
		session.get_phase() == RogueEncounterSession.PHASE_VOTING,
		"仍有未投玩家时应继续处于投票阶段。"
	)
	session.tick(60.0)
	var result_state := session.export_state()
	_expect(
		session.get_phase() == RogueEncounterSession.PHASE_RESULT,
		"60秒后未投玩家弃票并完成结算。"
	)
	_expect(
		(result_state["abstained_peer_ids"] as Array).has(2),
		"玩家2应被记录为弃票。"
	)
	_expect(session.is_node_resolved(7), "结算节点应立即进入已解决集合。")
	_expect(
		not session.submit_vote(
			1,
			session.get_occurrence_key(),
			session.get_revision() - 1,
			RogueEncounterEconomyCoordinator.OPTION_FREE
		),
		"过期 revision 请求必须被拒绝。"
	)
	session.free()
	economy.free()
	run_state.free()


func _test_snapshot_replay_and_peer_migration() -> void:
	var run_state := _new_run_state()
	for peer_id in [11, 12]:
		run_state.ensure_multiplayer_peer_state(peer_id)
	_expect(
		run_state.try_add_item_count_for_peer(12, PLANK, 10),
		"断线可用性测试应让玩家12独立持有10块木板。"
	)
	var economy := RogueEncounterEconomyCoordinator.new()
	economy.configure(run_state)
	var authority := RogueEncounterSession.new()
	authority.initialize_authority(economy, [11, 12])
	_expect(
		authority.start_for_node(9, &"magical_encounter", 7654, [11, 12]),
		"迁移用例应启动遭遇。"
	)
	var revision := authority.get_revision()
	_expect(
		authority.submit_intro_ack(12, authority.get_occurrence_key(), revision),
		"迁移前应记录对白确认。"
	)
	revision = authority.get_revision()
	_expect(
		authority.submit_vote(
			12,
			authority.get_occurrence_key(),
			revision,
			RogueEncounterEconomyCoordinator.OPTION_FREE
		),
		"迁移前应记录投票。"
	)
	_expect(authority.remove_peer(12), "掉线玩家应移出有效投票集合。")
	_expect(
		not bool(
			(authority.export_state()["option_availability"] as Dictionary).get(
				String(RogueEncounterEconomyCoordinator.OPTION_PURCHASE),
				true
			)
		),
		"唯一木板来源掉线后，付费选项必须立即禁用。"
	)
	_expect(
		run_state.remap_multiplayer_peer_state(12, 22),
		"Session 迁移前应先原子迁移 RunState 背包。"
	)
	_expect(authority.migrate_peer(12, 22), "重连应迁移遭遇身份。")
	var migrated := authority.export_state()
	_expect(
		bool(
			(migrated["option_availability"] as Dictionary).get(
				String(RogueEncounterEconomyCoordinator.OPTION_PURCHASE),
				false
			)
		),
		"携带木板的玩家重连后，付费选项必须恢复可用。"
	)
	var migrated_economy := migrated.get("economy_snapshot", {}) as Dictionary
	var party_economy := (
		migrated_economy.get("party_economy", {}) as Dictionary
	)
	var inventory_snapshots := (
		party_economy.get("inventories", []) as Array
	)
	var economy_peer_ids: Array[int] = []
	for inventory_snapshot_variant in inventory_snapshots:
		var inventory_snapshot := inventory_snapshot_variant as Dictionary
		economy_peer_ids.append(int(inventory_snapshot.get("peer_id", -1)))
	_expect(
		(migrated["participant_peer_ids"] as Array).has(22)
		and not (migrated["participant_peer_ids"] as Array).has(12)
		and economy_peer_ids.has(22)
		and not economy_peer_ids.has(12),
		"参与者身份与内嵌经济快照都应迁移到新peer。"
	)
	var remote_run_state := _new_run_state()
	var remote_economy := RogueEncounterEconomyCoordinator.new()
	remote_economy.configure(remote_run_state)
	var remote := RogueEncounterSession.new()
	remote.initialize_remote(remote_economy)
	_expect(remote.apply_remote_state(migrated), "客户端应原子导入遭遇与经济快照。")
	_expect(remote.export_state() == migrated, "导入后的快照应可无损重放。")
	remote.free()
	remote_economy.free()
	remote_run_state.free()
	authority.free()
	economy.free()
	run_state.free()


func _test_dynamic_option_availability() -> void:
	var run_state := _new_run_state()
	run_state.ensure_multiplayer_peer_state(51)
	_expect(
		run_state.try_add_item_count_for_peer(51, PLANK, 10),
		"经济变更测试应准备10块木板。"
	)
	var economy := RogueEncounterEconomyCoordinator.new()
	economy.configure(run_state)
	var session := RogueEncounterSession.new()
	session.initialize_authority(economy, [51])
	_expect(
		session.start_for_node(51, &"magical_encounter", 51051, [51]),
		"动态购买可用性测试应启动遭遇。"
	)
	var revision_before_economy_change := session.get_revision()
	var external_result := economy.resolve_chicken_bro(
		RogueEncounterEconomyCoordinator.OPTION_PURCHASE,
		51100,
		[51],
		"external-economy-change"
	)
	var state := session.export_state()
	_expect(
		bool(external_result.get("reward_granted", false))
		and not bool(
			(state["option_availability"] as Dictionary).get(
				String(RogueEncounterEconomyCoordinator.OPTION_PURCHASE),
				true
			)
		),
		"经济信号扣空木板后，进行中的遭遇必须刷新付费选项。"
	)
	_expect(
		session.get_revision() == revision_before_economy_change + 1,
		"经济可用性变化只应推进一次遭遇 revision。"
	)
	session.free()
	economy.free()
	run_state.free()


func _test_settled_result_and_spectator_migration() -> void:
	var run_state := _new_run_state()
	run_state.ensure_multiplayer_peer_state(61)
	_expect(
		run_state.try_add_item_count_for_peer(61, PLANK, 10),
		"结算迁移测试应准备10块木板。"
	)
	var economy := RogueEncounterEconomyCoordinator.new()
	economy.configure(run_state)
	var session := RogueEncounterSession.new()
	session.initialize_authority(economy, [61])
	_expect(
		session.start_for_node(61, &"magical_encounter", 61061, [61]),
		"结算迁移测试应启动遭遇。"
	)
	_expect(
		session.add_spectator(90) and session.migrate_peer(90, 91),
		"旁观者重连时应迁移旁观身份。"
	)
	_expect(
		(session.export_state()["spectator_peer_ids"] as Array).has(91)
		and not (session.export_state()["spectator_peer_ids"] as Array).has(90),
		"旁观者快照不得继续保留旧peer ID。"
	)
	_expect(
		session.submit_intro_ack(
			61,
			session.get_occurrence_key(),
			session.get_revision()
		),
		"结算迁移测试玩家应完成对白。"
	)
	_expect(
		session.submit_vote(
			61,
			session.get_occurrence_key(),
			session.get_revision(),
			RogueEncounterEconomyCoordinator.OPTION_PURCHASE
		),
		"单人付费票应立即完成结算。"
	)
	_expect(
		run_state.remap_multiplayer_peer_state(61, 62),
		"结算结果迁移前应迁移RunState背包。"
	)
	_expect(session.migrate_peer(61, 62), "结果阶段也应迁移参与者身份。")
	var migrated := session.export_state()
	var result := migrated["economy_result"] as Dictionary
	var payments := result.get("player_payments", {}) as Dictionary
	var settled_entries := (
		(migrated["economy_snapshot"] as Dictionary).get(
			"settled_occurrences",
			[]
		) as Array
	)
	var settled_result := (
		(settled_entries[0] as Dictionary).get("result", {}) as Dictionary
		if not settled_entries.is_empty()
		else {}
	)
	var settled_payments := settled_result.get("player_payments", {}) as Dictionary
	_expect(
		int(result.get("receiver_peer_id", -1)) == 62
		and payments.has(62)
		and not payments.has(61),
		"结果阶段迁移必须同步receiver与player_payments。"
	)
	_expect(
		int(settled_result.get("receiver_peer_id", -1)) == 62
		and settled_payments.has(62)
		and not settled_payments.has(61),
		"权威经济结算缓存不得在重连后继续输出旧peer ID。"
	)
	session.free()
	economy.free()
	run_state.free()


func _test_deterministic_tie_and_no_vote() -> void:
	var run_state := _new_run_state()
	for peer_id in [31, 32]:
		run_state.ensure_multiplayer_peer_state(peer_id)
	_expect(run_state.try_add_item_count_for_peer(31, PLANK, 20), "平票测试应有木板。")
	var economy := RogueEncounterEconomyCoordinator.new()
	economy.configure(run_state)
	var session := RogueEncounterSession.new()
	session.initialize_authority(economy, [31, 32])
	var seed := 88021
	_expect(
		session.start_for_node(41, &"magical_encounter", seed, [31, 32]),
		"平票测试应启动遭遇。"
	)
	for peer_id in [31, 32]:
		_expect(
			session.submit_intro_ack(
				peer_id,
				session.get_occurrence_key(),
				session.get_revision()
			),
			"平票测试玩家应独立完成对白。"
		)
	var first_option := RogueEncounterEconomyCoordinator.OPTION_PURCHASE
	var second_option := RogueEncounterEconomyCoordinator.OPTION_FREE
	_expect(
		session.submit_vote(
			31,
			session.get_occurrence_key(),
			session.get_revision(),
			first_option
		),
		"玩家31应投付费票。"
	)
	_expect(
		session.submit_vote(
			32,
			session.get_occurrence_key(),
			session.get_revision(),
			second_option
		),
		"玩家32投票后应立即锁票结算。"
	)
	var tie_options: Array[StringName] = [first_option, second_option]
	var expected_tie := tie_options[
		RogueEncounterRandom.choose_index(seed, &"tie_break", tie_options.size())
	]
	_expect(
		StringName(session.export_state()["winning_option"]) == expected_tie,
		"平票结果应仅由节点seed与tie_break salt决定。"
	)

	var no_vote_session := RogueEncounterSession.new()
	no_vote_session.initialize_authority(economy, [31, 32])
	var no_vote_seed := 90210
	_expect(
		no_vote_session.start_for_node(
			42,
			&"magical_encounter",
			no_vote_seed,
			[31, 32]
		),
		"无人投票测试应启动遭遇。"
	)
	_expect(
		no_vote_session.start_voting_timer(
			no_vote_session.get_occurrence_key(),
			no_vote_session.get_revision()
		),
		"无人投票测试应启动计时。"
	)
	no_vote_session.tick(60.0)
	var available: Array[StringName] = [first_option, second_option]
	var expected_no_vote := available[
		RogueEncounterRandom.choose_index(
			no_vote_seed,
			&"no_vote",
			available.size()
		)
	]
	_expect(
		StringName(no_vote_session.export_state()["winning_option"])
		== expected_no_vote,
		"全员弃票应使用独立no_vote salt确定选择。"
	)
	no_vote_session.free()
	session.free()
	economy.free()
	run_state.free()


func _new_run_state() -> RunStateStore:
	var run_state := RunStateStore.new()
	run_state.begin_new_run(&"weishidaier", false)
	return run_state


func _make_warehouse_snapshot(
	warehouse_net_id: int,
	revision: int,
	config_path: String,
	count: int
) -> Dictionary:
	var slots: Array[Dictionary] = []
	for slot_index in RunStateStore.INVENTORY_CAPACITY:
		slots.append(
			{
				"slot_index": slot_index,
				"config_path": config_path if slot_index == 0 and count > 0 else "",
				"stack_count": count if slot_index == 0 else 0,
			}
		)
	return {
		"warehouse_net_id": warehouse_net_id,
		"revision": revision,
		"slots": slots,
	}


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
