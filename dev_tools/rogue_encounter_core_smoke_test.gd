extends SceneTree

const PLANK := preload("res://resources/config/materials/material_plank.tres")
const BASKETBALL := preload(
	"res://resources/config/collectibles/collectible_basketball.tres"
)
const WATER_BOTTLE := preload(
	"res://resources/config/materials/material_water_bottle.tres"
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
	_test_route_map_unique_assignment()
	_test_run_history_persistence_and_exhausted_fallback()
	_test_dynamic_option_availability()
	_test_settled_result_and_spectator_migration()
	_test_slime_session_options_and_result_pages()
	_test_slime_result_page_contract()
	_test_ghost_shadow_results_and_no_economy()
	_test_suitcase_frenzy_results_and_safe_timeout()
	_test_fluorescent_pit_multiround_session()
	_test_fluorescent_pit_core_failure_session()
	if _failures.is_empty():
		print("ROGUE_ENCOUNTER_CORE_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in _failures:
		push_error(failure)
	quit(1)


func _test_warehouse_first_atomic_purchase() -> void:
	var run_state := _new_run_state()
	run_state.register_multiplayer_peer_state(1)
	run_state.register_multiplayer_peer_state(2)
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
		run_state.register_multiplayer_peer_state(peer_id)
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
	run_state.register_multiplayer_peer_state(3)
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
	run_state.register_multiplayer_peer_state(8)
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
		run_state.register_multiplayer_peer_state(peer_id)
	var economy := RogueEncounterEconomyCoordinator.new()
	economy.configure(run_state)
	var session := RogueEncounterSession.new()
	session.initialize_authority(economy, [1, 2])
	var seed := _seed_for_encounter(31337, RogueEncounterRegistry.SLIME_TALKERS)
	_expect(
		session.start_for_node(7, &"magical_encounter", seed, [1, 2]),
		"启用的史莱姆遭遇应从神奇遭遇池启动。"
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
			RogueEncounterRegistry.OPTION_KICK_SLIMES
		),
		"玩家1不等待玩家2即可投票。"
	)
	revision = session.get_revision()
	_expect(
		session.submit_vote(
			1,
			session.get_occurrence_key(),
			revision,
			RogueEncounterRegistry.OPTION_LEAVE_SLIMES
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
			RogueEncounterRegistry.OPTION_LEAVE_SLIMES
		),
		"过期 revision 请求必须被拒绝。"
	)
	session.free()
	economy.free()
	run_state.free()


func _test_snapshot_replay_and_peer_migration() -> void:
	var run_state := _new_run_state()
	for peer_id in [11, 12]:
		run_state.register_multiplayer_peer_state(peer_id)
	_expect(
		run_state.try_add_item_count_for_peer(12, WATER_BOTTLE, 10),
		"断线可用性测试应让玩家12独立持有10瓶水。"
	)
	var economy := RogueEncounterEconomyCoordinator.new()
	economy.configure(run_state)
	var authority := RogueEncounterSession.new()
	authority.initialize_authority(economy, [11, 12])
	var seed := _seed_for_encounter(7654, RogueEncounterRegistry.SLIME_TALKERS)
	_expect(
		authority.start_for_node(9, &"magical_encounter", seed, [11, 12]),
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
			RogueEncounterRegistry.OPTION_LEAVE_SLIMES
		),
		"迁移前应记录投票。"
	)
	_expect(authority.remove_peer(12), "掉线玩家应移出有效投票集合。")
	_expect(
		not bool(
			(authority.export_state()["option_availability"] as Dictionary).get(
				String(RogueEncounterRegistry.OPTION_HELP_SLIMES),
				true
			)
		),
		"唯一水瓶来源掉线后，史莱姆帮助选项必须立即禁用。"
	)
	_expect(
		run_state.remap_multiplayer_peer_state(
			12,
			22,
			run_state.get_multiplayer_session_membership_revision() + 1
		) == RunStateStore.MultiplayerPeerRemapResult.MIGRATED,
		"Session 迁移前应先原子迁移 RunState 背包。"
	)
	_expect(authority.migrate_peer(12, 22), "重连应迁移遭遇身份。")
	var migrated := authority.export_state()
	_expect(
		bool(
			(migrated["option_availability"] as Dictionary).get(
				String(RogueEncounterRegistry.OPTION_HELP_SLIMES),
				false
			)
		),
		"携带水瓶的玩家重连后，史莱姆帮助选项必须恢复可用。"
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
	_expect(
		remote_run_state.register_multiplayer_peer_states(
			PackedInt32Array([11, 22])
		),
		"远端遭遇快照应用前必须先投影权威会话成员。"
	)
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


func _test_route_map_unique_assignment() -> void:
	var node_ids := PackedInt32Array([3, 7, 11, 18])
	var assigned: Array[StringName] = []
	for node_id in node_ids:
		var encounter_id := RogueEncounterRegistry.select_encounter_for_map(
			RogueEncounterRegistry.MAGICAL_ENCOUNTER_POOL,
			0x45A771,
			node_ids,
			node_id
		)
		_expect(
			not encounter_id.is_empty()
			and not assigned.has(encounter_id)
			and not RogueEncounterRegistry.is_reserved_encounter(encounter_id),
			"同一地图的四个神奇遭遇节点必须得到互不重复的启用事件。"
		)
		assigned.append(encounter_id)
	var repeated: Array[StringName] = []
	for node_id in node_ids:
		repeated.append(RogueEncounterRegistry.select_encounter_for_map(
			RogueEncounterRegistry.MAGICAL_ENCOUNTER_POOL,
			0x45A771,
			node_ids,
			node_id
		))
	_expect(
		assigned == repeated,
		"地图遭遇分配必须仅由地图 seed 与稳定节点顺序确定。"
	)
	_expect(
		RogueEncounterRegistry.select_encounter_for_map(
			RogueEncounterRegistry.MAGICAL_ENCOUNTER_POOL,
			0x45A771,
			PackedInt32Array([7, 3]),
			3
		) == &"",
		"未按稳定升序提交的遭遇节点目录必须被拒绝。"
	)
	_expect(
		RogueEncounterRegistry.compute_runtime_contract_hash().length() == 64,
		"事件池顺序必须提供稳定的路线运行契约哈希。"
	)


func _test_run_history_persistence_and_exhausted_fallback() -> void:
	var host_run_state := _new_run_state()
	_expect(
		host_run_state.register_multiplayer_peer_state(1),
		"遭遇历史权威夹具必须先注册参与成员。"
	)
	var host_economy := RogueEncounterEconomyCoordinator.new()
	host_economy.configure(host_run_state)
	var host_session := RogueEncounterSession.new()
	host_session.initialize_authority(host_economy, [1], host_run_state)
	var pool := RogueEncounterRegistry.get_pool_entries(
		RogueEncounterRegistry.MAGICAL_ENCOUNTER_POOL
	)
	_expect(
		not host_run_state.record_rogue_encounter(
			RogueEncounterRegistry.CHICKEN_BRO
		)
		and not host_run_state.record_rogue_encounter(
			RogueEncounterRegistry.GHOST_SHADOW
		)
		and host_run_state.get_rogue_encountered_ids().is_empty(),
		"RunState 历史必须拒绝两个预留事件。"
	)
	for encounter_id in pool:
		_expect(
			host_run_state.record_rogue_encounter(encounter_id),
			"测试前置应能写入本局神奇遭遇历史。"
		)
	# Session 重建必须从同一个 RunState 恢复历史，而不是回到空池。
	host_session.reset_authority(host_economy, [1], host_run_state)
	_expect(
			host_session.start_for_node(
			991,
			RogueEncounterRegistry.MAGICAL_ENCOUNTER_POOL,
			12345,
			[1]
		),
		"启用事件历史耗尽后应能确定性复用一个启用事件。"
	)
	var exhausted_fallback := host_session.export_state()
	var fallback_encounter_id := StringName(
		exhausted_fallback.get("encounter_id", &"")
	)
	_expect(
		pool.has(fallback_encounter_id)
		and not RogueEncounterRegistry.is_reserved_encounter(fallback_encounter_id)
		and host_run_state.get_rogue_encountered_ids().size() == pool.size(),
		"RunState 应只记录四种启用遭遇，耗尽回退不得选择预留事件。"
	)
	var client_run_state := _new_run_state()
	_expect(
		client_run_state.register_multiplayer_peer_state(1),
		"遭遇历史远端夹具必须先注册权威参与成员。"
	)
	var client_economy := RogueEncounterEconomyCoordinator.new()
	client_economy.configure(client_run_state)
	var client_session := RogueEncounterSession.new()
	client_session.initialize_remote(client_economy, client_run_state)
	var forged_history := exhausted_fallback.duplicate(true)
	forged_history["encountered_encounter_ids"] = []
	_expect(
		not client_session.apply_remote_state(forged_history)
		and client_run_state.get_rogue_encountered_ids().is_empty(),
		"Session 历史与复合 RunState 快照不一致时必须原子拒绝。"
	)
	_expect(
		client_session.apply_remote_state(exhausted_fallback)
		and client_run_state.get_rogue_encountered_ids()
		== host_run_state.get_rogue_encountered_ids(),
		"重连快照必须原子恢复客户端 RunState 的完整遭遇历史。"
	)
	# Host 恢复/节点切换后历史仍耗尽，但只会按新 seed 重选启用事件。
	host_session.reset_authority(host_economy, [1], host_run_state)
	_expect(
		host_session.start_for_node(
			992,
			RogueEncounterRegistry.MAGICAL_ENCOUNTER_POOL,
			987654,
			[1]
		)
		and pool.has(StringName(
			host_session.export_state().get("encounter_id", &"")
		))
		and not RogueEncounterRegistry.is_reserved_encounter(StringName(
			host_session.export_state().get("encounter_id", &"")
		)),
		"全部启用事件耗尽后重建 Session 也不得回退预留事件。"
	)
	host_run_state.begin_new_run(&"weishidaier", false)
	_expect(
		host_run_state.get_rogue_encountered_ids().is_empty()
		and int(host_run_state.export_rogue_encounter_history_ledger().get(
			"revision",
			-1
		)) == 0,
		"开始新 run 必须清空神奇遭遇历史及其 revision。"
	)
	client_session.free()
	client_economy.free()
	client_run_state.free()
	host_session.free()
	host_economy.free()
	host_run_state.free()


func _test_dynamic_option_availability() -> void:
	var run_state := _new_run_state()
	run_state.register_multiplayer_peer_state(51)
	_expect(
		run_state.try_add_item_count_for_peer(51, WATER_BOTTLE, 10),
		"经济变更测试应准备10瓶水。"
	)
	var economy := RogueEncounterEconomyCoordinator.new()
	economy.configure(run_state)
	var session := RogueEncounterSession.new()
	session.initialize_authority(economy, [51])
	var seed := _seed_for_encounter(51051, RogueEncounterRegistry.SLIME_TALKERS)
	_expect(
		session.start_for_node(51, &"magical_encounter", seed, [51]),
		"动态史莱姆帮助可用性测试应启动遭遇。"
	)
	var revision_before_economy_change := session.get_revision()
	var external_result := economy.resolve_slime_talkers(
		RogueEncounterRegistry.OPTION_HELP_SLIMES,
		51100,
		[51],
		"external-economy-change"
	)
	var state := session.export_state()
	_expect(
		bool(external_result.get("resolved", false))
		and int(external_result.get("water_paid", 0)) == 10
		and not bool(
			(state["option_availability"] as Dictionary).get(
				String(RogueEncounterRegistry.OPTION_HELP_SLIMES),
				true
			)
		),
		"经济信号扣空水瓶后，进行中的遭遇必须刷新帮助选项。"
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
	run_state.register_multiplayer_peer_state(61)
	_expect(
		run_state.try_add_item_count_for_peer(61, WATER_BOTTLE, 10),
		"结算迁移测试应准备10瓶水。"
	)
	var economy := RogueEncounterEconomyCoordinator.new()
	economy.configure(run_state)
	var session := RogueEncounterSession.new()
	session.initialize_authority(economy, [61])
	var seed := _seed_for_encounter(61061, RogueEncounterRegistry.SLIME_TALKERS)
	_expect(
		session.start_for_node(61, &"magical_encounter", seed, [61]),
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
			RogueEncounterRegistry.OPTION_HELP_SLIMES
		),
		"单人帮助史莱姆应立即完成结算。"
	)
	_expect(
		run_state.remap_multiplayer_peer_state(
			61,
			62,
			run_state.get_multiplayer_session_membership_revision() + 1
		) == RunStateStore.MultiplayerPeerRemapResult.MIGRATED,
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
		payments.has(62)
		and not payments.has(61),
		"结果阶段迁移必须同步player_payments。"
	)
	_expect(
		settled_payments.has(62)
		and not settled_payments.has(61),
		"权威经济结算缓存不得在重连后继续输出旧peer ID。"
	)
	session.free()
	economy.free()
	run_state.free()


func _test_deterministic_tie_and_no_vote() -> void:
	var run_state := _new_run_state()
	for peer_id in [31, 32]:
		run_state.register_multiplayer_peer_state(peer_id)
	var economy := RogueEncounterEconomyCoordinator.new()
	economy.configure(run_state)
	var session := RogueEncounterSession.new()
	session.initialize_authority(economy, [31, 32])
	var seed := _seed_for_encounter(88021, RogueEncounterRegistry.SLIME_TALKERS)
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
	var first_option := RogueEncounterRegistry.OPTION_KICK_SLIMES
	var second_option := RogueEncounterRegistry.OPTION_LEAVE_SLIMES
	_expect(
		session.submit_vote(
			31,
			session.get_occurrence_key(),
			session.get_revision(),
			first_option
		),
		"玩家31应投踢走史莱姆。"
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
	var no_vote_seed := _seed_for_encounter(
		90210,
		RogueEncounterRegistry.SLIME_TALKERS
	)
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


func _test_slime_session_options_and_result_pages() -> void:
	var run_state := _new_run_state()
	run_state.register_multiplayer_peer_state(71)
	var economy := RogueEncounterEconomyCoordinator.new()
	economy.configure(run_state)
	var session := RogueEncounterSession.new()
	session.initialize_authority(economy, [71])
	var seed := _seed_for_encounter(
		71071,
		RogueEncounterRegistry.SLIME_TALKERS
	)
	_expect(
		session.start_for_node(71, &"magical_encounter", seed, [71]),
		"史莱姆遭遇应能通过通用 Session 启动。"
	)
	var started := session.export_state()
	var availability := started.get("option_availability", {}) as Dictionary
	_expect(
		StringName(started.get("encounter_id", &""))
		== RogueEncounterRegistry.SLIME_TALKERS
		and not bool(availability.get("help_slimes", true))
		and bool(availability.get("kick_slimes", false))
		and bool(availability.get("leave_slimes", false)),
		"史莱姆应按 encounter_id 输出三项权威可用性，缺水时只禁用帮助。"
	)
	_expect(
		session.submit_intro_ack(
			71,
			session.get_occurrence_key(),
			session.get_revision()
		),
		"史莱姆对白确认应复用通用确认请求。"
	)
	_expect(
		not session.submit_vote(
			71,
			session.get_occurrence_key(),
			session.get_revision(),
			RogueEncounterRegistry.OPTION_ASK_FOR_FREE
		),
		"Session 必须拒绝不属于当前史莱姆遭遇的鸡哥选项。"
	)
	_expect(
		session.submit_vote(
			71,
			session.get_occurrence_key(),
			session.get_revision(),
			RogueEncounterRegistry.OPTION_LEAVE_SLIMES
		),
		"单人选择离开后应立即完成权威结算。"
	)
	var result := session.export_state()
	var pages := result.get("result_pages", []) as Array
	_expect(
		int(result.get("schema_version", -1)) == RogueEncounterSession.SCHEMA_VERSION
		and StringName(result.get("phase", &"")) == RogueEncounterSession.PHASE_RESULT
		and pages.size() == 1
		and str((pages[0] as Dictionary).get("speaker", "")).is_empty()
		and bool((pages[0] as Dictionary).get("is_narration", false))
		and str((pages[0] as Dictionary).get("text", ""))
		== "真是一群神奇的生物，你记录了下来，然后便离开了"
		and str(result.get("result_text", ""))
		== str((pages[0] as Dictionary).get("text", "")),
		"史莱姆离开结果必须输出一页旁白，并让 result_text 等于末页正文。"
	)

	var remote_run_state := _new_run_state()
	_expect(
		remote_run_state.register_multiplayer_peer_state(71),
		"史莱姆远端快照应用前必须先注册权威参与成员。"
	)
	var remote_economy := RogueEncounterEconomyCoordinator.new()
	remote_economy.configure(remote_run_state)
	var remote_session := RogueEncounterSession.new()
	remote_session.initialize_remote(remote_economy)
	_expect(
		remote_session.apply_remote_state(result)
		and remote_session.export_state() == result,
		"v5 Session 快照必须无损同步三选项与 result_pages。"
	)
	var malformed := result.duplicate(true)
	malformed["revision"] = int(result["revision"]) + 1
	malformed["result_pages"] = [{
		"speaker": "",
		"text": "",
		"is_narration": true,
	}]
	_expect(
		not remote_session.apply_remote_state(malformed)
		and remote_session.export_state() == result,
		"空正文的 result_pages 必须在提交经济与阶段前被拒绝。"
	)
	remote_session.free()
	remote_economy.free()
	remote_run_state.free()
	session.free()
	economy.free()
	run_state.free()


func _test_ghost_shadow_results_and_no_economy() -> void:
	var pool_entries := RogueEncounterRegistry.get_pool_entries(
		RogueEncounterRegistry.MAGICAL_ENCOUNTER_POOL
	)
	_expect(
		pool_entries.size() == 4
		and pool_entries.has(RogueEncounterRegistry.SLIME_TALKERS)
		and pool_entries.has(RogueEncounterRegistry.FLUORESCENT_PIT)
		and pool_entries.has(RogueEncounterRegistry.SUITCASE_FRENZY)
		and pool_entries.has(RogueEncounterRegistry.INVISIBLE_SEA_CUCUMBER)
		and not pool_entries.has(RogueEncounterRegistry.CHICKEN_BRO)
		and not pool_entries.has(RogueEncounterRegistry.GHOST_SHADOW),
		"正式神奇遭遇池必须只包含四种启用事件。"
	)
	var ghost_config := RogueEncounterRegistry.get_encounter_config(
		RogueEncounterRegistry.GHOST_SHADOW
	)
	var ghost_options := RogueEncounterRegistry.get_option_configs(
		RogueEncounterRegistry.GHOST_SHADOW
	)
	_expect(
		str(ghost_config.get("display_name", "")) == "鬼影"
		and str(ghost_config.get("intro_text", "")) == "你遇到了一个鬼影"
		and bool(ghost_config.get("intro_is_narration", false))
		and ghost_options.size() == 2
		and str(ghost_options[0].get("title", "")) == "逃跑"
		and str(ghost_options[0].get("description", ""))
		== "鬼知道会发生什么，赶快逃"
		and str(ghost_options[1].get("title", "")) == "你是？"
		and str(ghost_options[1].get("description", "")).is_empty(),
		"鬼影必须使用旁白开场，并注册指定的两个选项文案。"
	)

	var run_state := _new_run_state()
	run_state.register_multiplayer_peer_state(71)
	var economy := RogueEncounterEconomyCoordinator.new()
	economy.configure(run_state)
	var economy_before := economy.export_snapshot([71])
	var flee_result := economy.resolve_ghost_shadow(
		RogueEncounterRegistry.OPTION_GHOST_RUN_AWAY,
		71071,
		[71],
		"reserved-ghost-flee"
	)
	_expect(
		bool(flee_result.get("resolved", false))
		and StringName(flee_result.get("result_code", &""))
		== RogueEncounterEconomyCoordinator.RESULT_GHOST_FLED,
		"预留的鬼影逃跑结算实现必须继续保留。"
	)
	var question_result := economy.resolve_ghost_shadow(
		RogueEncounterRegistry.OPTION_GHOST_WHO_ARE_YOU,
		72072,
		[71],
		"reserved-ghost-question"
	)
	_expect(
		bool(question_result.get("resolved", false))
		and StringName(question_result.get("result_code", &""))
		== RogueEncounterEconomyCoordinator.RESULT_GHOST_VANISHED
		and StringName(question_result.get("special_outcome_key", &""))
		== RogueEncounterEconomyCoordinator.GHOST_IDENTITY_SPECIAL_OUTCOME,
		"预留的鬼影身份结算与专用结果入口必须继续保留。"
	)
	_expect(
		economy.export_snapshot([71]) == economy_before,
		"鬼影的两个默认结果都不得改动队伍经济快照。"
	)

	var blocked_session := RogueEncounterSession.new()
	blocked_session.initialize_authority(economy, [71], run_state)
	_expect(
		not blocked_session.start_for_node(
			71,
			RogueEncounterRegistry.MAGICAL_ENCOUNTER_POOL,
			71071,
			[71],
			RogueEncounterRegistry.CHICKEN_BRO
		)
		and not blocked_session.start_for_node(
			72,
			RogueEncounterRegistry.MAGICAL_ENCOUNTER_POOL,
			72072,
			[71],
			RogueEncounterRegistry.GHOST_SHADOW
		)
		and not run_state.record_rogue_encounter(
			RogueEncounterRegistry.CHICKEN_BRO
		)
		and not run_state.record_rogue_encounter(
			RogueEncounterRegistry.GHOST_SHADOW
		),
		"Session 显式分配和 RunState 历史都必须拒绝两个预留事件。"
	)
	_expect(
		blocked_session.start_for_node(
			73,
			RogueEncounterRegistry.MAGICAL_ENCOUNTER_POOL,
			73073,
			[71],
			RogueEncounterRegistry.SLIME_TALKERS
		),
		"远端篡改边界测试应先建立合法的启用事件快照。"
	)
	var active_snapshot := blocked_session.export_state()
	for reserved_id in RogueEncounterRegistry.get_reserved_encounter_ids():
		var forged_snapshot := active_snapshot.duplicate(true)
		forged_snapshot["encounter_id"] = String(reserved_id)
		var state_before_forgery := blocked_session.export_state()
		_expect(
			not blocked_session.validate_remote_state_structure(forged_snapshot)
			and not blocked_session.apply_remote_state(forged_snapshot)
			and blocked_session.export_state() == state_before_forgery,
			"Session 远端快照必须原子拒绝预留事件 %s。" % reserved_id
		)
	blocked_session.free()
	economy.free()
	run_state.free()


func _test_suitcase_frenzy_results_and_safe_timeout() -> void:
	var run_state := _new_run_state()
	for peer_id in [81, 82]:
		run_state.register_multiplayer_peer_state(peer_id)
	var economy := RogueEncounterEconomyCoordinator.new()
	economy.configure(run_state)
	var economy_before := economy.export_snapshot([81, 82])
	var seed := _seed_for_encounter(
		810_000,
		RogueEncounterRegistry.SUITCASE_FRENZY
	)

	var fight_session := RogueEncounterSession.new()
	fight_session.initialize_authority(economy, [81, 82])
	_expect(
		fight_session.start_for_node(
			811,
			RogueEncounterRegistry.MAGICAL_ENCOUNTER_POOL,
			seed,
			[81, 82]
		),
		"疯穿箱子开火用例应从神奇遭遇池启动。"
	)
	var availability := (
		fight_session.export_state().get("option_availability", {})
		as Dictionary
	)
	_expect(
		bool(availability.get("claim_suitcase", false))
		and bool(availability.get("join_suitcase_shooting", false))
		and bool(availability.get("ignore_suitcase", false)),
		"疯穿箱子的三个选项必须全部可用。"
	)
	for peer_id in [81, 82]:
		_expect(
			fight_session.submit_intro_ack(
				peer_id,
				fight_session.get_occurrence_key(),
				fight_session.get_revision()
			),
			"疯穿箱子参与者应分别确认开场。"
		)
	for peer_id in [81, 82]:
		_expect(
			fight_session.submit_vote(
				peer_id,
				fight_session.get_occurrence_key(),
				fight_session.get_revision(),
				RogueEncounterRegistry.OPTION_CLAIM_SUITCASE
			),
			"疯穿箱子参与者应能共同选择开火。"
		)
	var fight_result := fight_session.export_state()
	var fight_payload := fight_result.get("economy_result", {}) as Dictionary
	var fight_pages := fight_result.get("result_pages", []) as Array
	_expect(
		int(fight_result.get("schema_version", -1)) == 5
		and fight_session.get_phase() == RogueEncounterSession.PHASE_RESULT
		and fight_pages.size() == 1
		and str((fight_pages[0] as Dictionary).get("text", ""))
		== "机器人注意到了你！"
		and str(fight_payload.get("followup_combat_id", ""))
		== "suitcase_battle"
		and StringName(fight_payload.get("result_code", &""))
		== RogueEncounterEconomyCoordinator.RESULT_SUITCASE_ROBOTS_ALERTED
		and fight_session.is_node_resolved(811),
		"开火必须生成精确结果页、显式后续作战ID并进入结果屏障。"
	)
	_expect(
		fight_session.submit_result_ack(
			81,
			fight_session.get_occurrence_key(),
			int(fight_result.get("result_sequence", -1))
		)
		and fight_session.get_phase() == RogueEncounterSession.PHASE_RESULT
		and fight_session.submit_result_ack(
			82,
			fight_session.get_occurrence_key(),
			int(fight_result.get("result_sequence", -1))
		)
		and fight_session.get_phase() == RogueEncounterSession.PHASE_COMPLETED,
		"开火结果必须等当轮所有玩家ACK后才完成遭遇。"
	)

	var join_session := RogueEncounterSession.new()
	join_session.initialize_authority(economy, [81])
	_expect(
		join_session.start_for_node(
			812,
			RogueEncounterRegistry.MAGICAL_ENCOUNTER_POOL,
			seed,
			[81]
		)
		and join_session.submit_intro_ack(
			81,
			join_session.get_occurrence_key(),
			join_session.get_revision()
		)
		and join_session.submit_vote(
			81,
			join_session.get_occurrence_key(),
			join_session.get_revision(),
			RogueEncounterRegistry.OPTION_JOIN_SUITCASE_SHOOTING
		),
		"跟着开火选项应完成权威结算。"
	)
	var join_result := join_session.export_state()
	var join_pages := join_result.get("result_pages", []) as Array
	_expect(
		join_pages.size() == 1
		and str((join_pages[0] as Dictionary).get("text", ""))
		== "皮箱很快就变得千疮百孔，什么都不剩下了。"
		and str((join_result.get("economy_result", {}) as Dictionary).get(
			"followup_combat_id",
			"missing"
		)).is_empty(),
		"凑热闹只能显示精确结果文本，不得触发后续作战。"
	)

	var timeout_session := RogueEncounterSession.new()
	timeout_session.initialize_authority(economy, [81, 82])
	_expect(
		timeout_session.start_for_node(
			813,
			RogueEncounterRegistry.MAGICAL_ENCOUNTER_POOL,
			seed,
			[81, 82]
		)
		and timeout_session.start_voting_timer(
			timeout_session.get_occurrence_key(),
			timeout_session.get_revision()
		),
		"疯穿箱子安全超时用例应启动计时。"
	)
	timeout_session.tick(RogueEncounterSession.VOTING_TIMEOUT_SECONDS)
	var timeout_result := timeout_session.export_state()
	var timeout_payload := (
		timeout_result.get("economy_result", {}) as Dictionary
	)
	_expect(
		timeout_session.get_phase() == RogueEncounterSession.PHASE_COMPLETED
		and StringName(timeout_result.get("winning_option", &""))
		== RogueEncounterRegistry.OPTION_IGNORE_SUITCASE
		and (timeout_result.get("result_pages", []) as Array).is_empty()
		and StringName(timeout_payload.get("result_presentation", &""))
		== RogueEncounterEconomyCoordinator.RESULT_PRESENTATION_IMMEDIATE
		and str(timeout_payload.get("followup_combat_id", "missing")).is_empty()
		and timeout_session.is_node_resolved(813),
		"全员超时必须固定安全离开、无结果页立即完成且不触发战斗。"
	)
	var remote_run_state := _new_run_state()
	_expect(
		remote_run_state.register_multiplayer_peer_states(
			PackedInt32Array([81, 82])
		),
		"疯穿箱子远端快照应用前必须先注册权威参与成员。"
	)
	var remote_economy := RogueEncounterEconomyCoordinator.new()
	remote_economy.configure(remote_run_state)
	var remote_session := RogueEncounterSession.new()
	remote_session.initialize_remote(remote_economy)
	_expect(
		remote_session.apply_remote_state(timeout_result)
		and remote_session.export_state() == timeout_result,
		"schema 5必须允许无结果页的immediate终局快照无损同步。"
	)
	_expect(
		economy.export_snapshot([81, 82]) == economy_before,
		"疯穿箱子的三个结果都不得改动队伍经济快照。"
	)

	remote_session.free()
	remote_economy.free()
	remote_run_state.free()
	timeout_session.free()
	join_session.free()
	fight_session.free()
	economy.free()
	run_state.free()


func _test_fluorescent_pit_multiround_session() -> void:
	var run_state := _new_run_state()
	for peer_id in [1, 2]:
		run_state.register_multiplayer_peer_state(peer_id)
	var economy := RogueEncounterEconomyCoordinator.new()
	economy.configure(run_state)
	var session := RogueEncounterSession.new()
	session.initialize_authority(economy, [1, 2])
	var seed := _seed_for_pit_bucket(900_000, 85, 99)
	_expect(
		session.start_for_node(
			901,
			RogueEncounterRegistry.MAGICAL_ENCOUNTER_POOL,
			seed,
			[1, 2]
		),
		"荧光坑洞多轮测试应从神奇遭遇池启动。"
	)
	for peer_id in [1, 2]:
		_expect(
			session.submit_intro_ack(
				peer_id,
				session.get_occurrence_key(),
				session.get_revision()
			),
			"坑洞玩家应分别确认开场旁白。"
		)
	for peer_id in [1, 2]:
		_expect(
			session.submit_vote(
				peer_id,
				session.get_occurrence_key(),
				session.get_revision(),
				RogueEncounterEconomyCoordinator.OPTION_EXPLORE_PIT
			),
			"坑洞玩家应能投票继续下探。"
		)
	var first_result := session.export_state()
	_expect(
		StringName(first_result.get("phase", &""))
		== RogueEncounterSession.PHASE_RESULT
		and int(first_result.get("schema_version", -1)) == 5
		and int(first_result.get("round_index", -1)) == 0
		and int(first_result.get("result_sequence", -1)) == 1
		and not bool(first_result.get("terminal_result", true))
		and not session.is_node_resolved(901)
		and (first_result.get("round_recipient_peer_ids", []) as Array)
		== [1, 2]
		and (first_result.get("disabled_option_ids", []) as Array)
		== [String(RogueEncounterEconomyCoordinator.OPTION_EXPLORE_PIT)],
		"到底结果必须保留节点、固定当轮在线玩家并永久禁用继续下探。"
	)
	_expect(
		not session.complete_result(
			session.get_occurrence_key(),
			session.get_revision()
		),
		"多轮坑洞不得被旧 complete_result 接口提前结束。"
	)
	_expect(session.remove_peer(2), "结果页期间掉线应移出ACK屏障。")
	_expect(
		run_state.remap_multiplayer_peer_state(
			2,
			22,
			run_state.get_multiplayer_session_membership_revision() + 1
		) == RunStateStore.MultiplayerPeerRemapResult.MIGRATED
		and session.migrate_peer(2, 22),
		"结果页期间重连应迁移身份但不加入本轮ACK对象。"
	)
	var migrated_result := session.export_state()
	_expect(
		(migrated_result.get("round_recipient_peer_ids", []) as Array)
		== [1]
		and not (migrated_result.get("active_peer_ids", []) as Array).has(22),
		"中途重连玩家不能重新加入已经固定的当轮结算对象。"
	)
	_expect(
		session.submit_result_ack(1, session.get_occurrence_key(), 1),
		"剩余结算对象确认后应解除首轮结果屏障。"
	)
	var second_round := session.export_state()
	var availability := second_round.get("option_availability", {}) as Dictionary
	_expect(
		session.get_phase() == RogueEncounterSession.PHASE_VOTING
		and int(second_round.get("round_index", -1)) == 1
		and int(second_round.get("result_sequence", -1)) == 1
		and bool(second_round.get("voting_timer_running", false))
		and is_equal_approx(
			float(second_round.get("remaining_seconds", 0.0)),
			60.0
		)
		and (second_round.get("active_peer_ids", []) as Array) == [1, 22]
		and bool(availability.get(
			String(RogueEncounterEconomyCoordinator.OPTION_LEAVE_PIT),
			false
		))
		and not bool(availability.get(
			String(RogueEncounterEconomyCoordinator.OPTION_EXPLORE_PIT),
			true
		)),
		"ACK齐全后应保留开场确认并重置60秒投票，同时让重连玩家从下一轮加入。"
	)
	for peer_id in [1, 22]:
		_expect(
			session.submit_vote(
				peer_id,
				session.get_occurrence_key(),
				session.get_revision(),
				RogueEncounterEconomyCoordinator.OPTION_LEAVE_PIT
			),
			"到底后在线玩家应能投票离开。"
		)
	var terminal_result := session.export_state()
	_expect(
		bool(terminal_result.get("terminal_result", false))
		and int(terminal_result.get("result_sequence", -1)) == 2
		and str(terminal_result.get("result_text", "")) == "还是赶紧走吧"
		and session.is_node_resolved(901),
		"主动离开必须产生第二个终局结果并消耗节点。"
	)
	_expect(
		not session.submit_result_ack(
			1,
			session.get_occurrence_key(),
			1
		)
		and session.submit_result_ack(
			1,
			session.get_occurrence_key(),
			2
		)
		and not session.submit_result_ack(
			1,
			session.get_occurrence_key(),
			2
		)
		and session.submit_result_ack(
			22,
			session.get_occurrence_key(),
			2
		)
		and session.get_phase() == RogueEncounterSession.PHASE_COMPLETED,
		"结果ACK必须校验序号、按peer幂等，并在全员确认终局后完成遭遇。"
	)
	var remote_run_state := _new_run_state()
	_expect(
		remote_run_state.register_multiplayer_peer_states(
			PackedInt32Array([1, 22])
		),
		"坑洞远端快照应用前必须先注册迁移后的权威参与成员。"
	)
	var remote_economy := RogueEncounterEconomyCoordinator.new()
	remote_economy.configure(remote_run_state)
	var remote_session := RogueEncounterSession.new()
	remote_session.initialize_remote(remote_economy)
	var completed := session.export_state()
	_expect(
		remote_session.apply_remote_state(completed)
		and remote_session.export_state() == completed,
		"schema 5多轮终局快照必须可无损同步。"
	)
	remote_session.free()
	remote_economy.free()
	remote_run_state.free()
	session.free()
	economy.free()
	run_state.free()


func _test_fluorescent_pit_core_failure_session() -> void:
	var run_state := _new_run_state()
	run_state.register_multiplayer_peer_state(51)
	_expect(run_state.set_party_core_health(2, 100), "核心归零测试应设置2点核心生命。")
	var economy := RogueEncounterEconomyCoordinator.new()
	economy.configure(run_state)
	var session := RogueEncounterSession.new()
	session.initialize_authority(economy, [51])
	var seed := _seed_for_pit_bucket(950_000, 50, 80)
	_expect(
		session.start_for_node(
			951,
			RogueEncounterRegistry.MAGICAL_ENCOUNTER_POOL,
			seed,
			[51]
		)
		and session.submit_intro_ack(
			51,
			session.get_occurrence_key(),
			session.get_revision()
		)
		and session.submit_vote(
			51,
			session.get_occurrence_key(),
			session.get_revision(),
			RogueEncounterEconomyCoordinator.OPTION_EXPLORE_PIT
		),
		"踩空归零用例应启动坑洞并完成一次下探。"
	)
	var failed_result := session.export_state()
	var payload := failed_result.get("economy_result", {}) as Dictionary
	_expect(
		bool(failed_result.get("terminal_result", false))
		and bool(failed_result.get("run_failed", false))
		and int(payload.get("core_before", -1)) == 2
		and int(payload.get("core_after", -1)) == 0
		and session.is_node_resolved(951),
		"共享核心降至0时，Session必须传播终局败局并消耗节点。"
	)
	_expect(
		session.submit_result_ack(
			51,
			session.get_occurrence_key(),
			int(failed_result.get("result_sequence", -1))
		)
		and session.get_phase() == RogueEncounterSession.PHASE_COMPLETED,
		"败局也必须在玩家看完结果并ACK后才进入完成阶段。"
	)
	session.free()
	economy.free()
	run_state.free()


func _test_slime_result_page_contract() -> void:
	var session := RogueEncounterSession.new()
	var collectible_pages := session.call(
		"_build_result_pages",
		RogueEncounterRegistry.SLIME_TALKERS,
		{"result_code": String(
			RogueEncounterEconomyCoordinator.RESULT_SLIME_HELP_COLLECTIBLES
		)}
	) as Array
	var xirang_pages := session.call(
		"_build_result_pages",
		RogueEncounterRegistry.SLIME_TALKERS,
		{"result_code": String(
			RogueEncounterEconomyCoordinator.RESULT_SLIME_HELP_XIRANG
		)}
	) as Array
	var kick_pages := session.call(
		"_build_result_pages",
		RogueEncounterRegistry.SLIME_TALKERS,
		{"result_code": String(
			RogueEncounterEconomyCoordinator.RESULT_SLIME_KICK_INVENTORY
		)}
	) as Array
	var dropped_pages := session.call(
		"_build_result_pages",
		RogueEncounterRegistry.SLIME_TALKERS,
		{"result_code": String(
			RogueEncounterEconomyCoordinator.RESULT_SLIME_KICK_DROPPED
		)}
	) as Array
	_expect(
		collectible_pages.size() == 2
		and (collectible_pages[0] as Dictionary) == {
			"speaker": "史莱姆",
			"text": "谢谢你，旅行者",
			"is_narration": false,
		}
		and str((collectible_pages[1] as Dictionary).get("text", ""))
		== "史莱姆回礼了你随机的三件收藏品",
		"收藏品回礼必须先显示史莱姆对白，再显示奖励旁白。"
	)
	_expect(
		xirang_pages.size() == 2
		and str((xirang_pages[1] as Dictionary).get("text", ""))
		== "史莱姆回礼了你一些息壤水晶",
		"息壤分支必须使用统一术语“息壤水晶”。"
	)
	_expect(
		kick_pages.size() == 2
		and str((kick_pages[0] as Dictionary).get("text", ""))
		== "把史莱姆当做路边野狗一样踢死了"
		and str((kick_pages[1] as Dictionary).get("text", ""))
		== "获得了10份凝胶",
		"成功取得凝胶时必须按两页顺序呈现。"
	)
	_expect(
		dropped_pages.size() == 2
		and str((dropped_pages[1] as Dictionary).get("text", ""))
		== "背包与仓库已满，10份凝胶被丢弃了。",
		"凝胶无处存放时结果页不得谎报已获得奖励。"
	)
	session.free()


func _seed_for_encounter(start_seed: int, encounter_id: StringName) -> int:
	for offset in 10_000:
		var candidate := start_seed + offset
		if RogueEncounterRegistry.select_encounter(
			RogueEncounterRegistry.MAGICAL_ENCOUNTER_POOL,
			candidate
		) == encounter_id:
			return candidate
	push_error("无法为遭遇 %s 找到测试 seed。" % encounter_id)
	return start_seed


func _seed_for_pit_bucket(
	start_seed: int,
	minimum_bucket: int,
	exclusive_maximum_bucket: int,
	round_index: int = 0
) -> int:
	for offset in 100_000:
		var candidate := start_seed + offset
		if (
			RogueEncounterRegistry.select_encounter(
				RogueEncounterRegistry.MAGICAL_ENCOUNTER_POOL,
				candidate
			) != RogueEncounterRegistry.FLUORESCENT_PIT
		):
			continue
		var bucket := RogueEncounterRandom.choose_index(
			candidate,
			StringName("fluorescent_pit_outcome|round:%d" % round_index),
			100
		)
		if bucket >= minimum_bucket and bucket < exclusive_maximum_bucket:
			return candidate
	push_error("无法为荧光坑洞找到指定概率桶测试 seed。")
	return start_seed


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
