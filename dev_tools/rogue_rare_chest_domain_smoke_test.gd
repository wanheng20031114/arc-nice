extends SceneTree

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_registry_contract()
	var run_state := RunStateStore.new()
	root.add_child(run_state)
	run_state.begin_new_run(PlayerCharacterRegistry.DEFAULT_CHARACTER_ID, false)
	run_state.register_multiplayer_peer_state(1)
	run_state.register_multiplayer_peer_state(2)
	var economy := RogueRareChestEconomyCoordinator.new()
	root.add_child(economy)
	economy.reset_runtime(run_state, {
		1: PlayerCharacterRegistry.WEISHIDAIER_ID,
		2: PlayerCharacterRegistry.HOE_CAT_ID,
	})
	_test_availability_and_settlement(economy, run_state)

	var session_run_state := RunStateStore.new()
	root.add_child(session_run_state)
	session_run_state.begin_new_run(
		PlayerCharacterRegistry.DEFAULT_CHARACTER_ID,
		false
	)
	session_run_state.register_multiplayer_peer_state(1)
	session_run_state.register_multiplayer_peer_state(2)
	var session_economy := RogueRareChestEconomyCoordinator.new()
	root.add_child(session_economy)
	session_economy.reset_runtime(session_run_state, {
		1: PlayerCharacterRegistry.WEISHIDAIER_ID,
		2: PlayerCharacterRegistry.HOE_CAT_ID,
	})
	var session := RogueRareChestSession.new()
	root.add_child(session)
	session.reset_authority(session_economy)
	_test_session_lifecycle(session, session_run_state)

	session.queue_free()
	session_economy.queue_free()
	session_run_state.queue_free()
	economy.queue_free()
	run_state.queue_free()
	await process_frame
	_finish()


func _test_registry_contract() -> void:
	var all_options := RogueRareChestRegistry.get_all_option_ids()
	_expect(
		all_options.size() == 7
		and all_options.has(RogueRareChestRegistry.OPTION_MAX_HEALTH)
		and all_options.has(RogueRareChestRegistry.OPTION_AMMO_CAPACITY),
		"稀有宝箱必须注册七种永久强化。"
	)
	_expect(
		str(RogueRareChestRegistry.get_option_definition(
			RogueRareChestRegistry.OPTION_MAX_HEALTH
		).get("effect_text", "")) == "生命值永久+10"
		and str(RogueRareChestRegistry.get_option_definition(
			RogueRareChestRegistry.OPTION_MAX_HEALTH
		).get("detail_text", "")) == "同时回复10点生命值"
		and int(RogueRareChestRegistry.get_option_definition(
			RogueRareChestRegistry.OPTION_DODGE_PERCENT_POINTS
		).get("stat_delta", 0)) == 1,
		"稀有宝箱 Registry 必须保留锁定数值与玩家文案。"
	)
	for seed_value in range(128):
		var first := RogueRareChestRegistry.select_options(
			seed_value,
			"player:stable:1",
			all_options
		)
		var replay := RogueRareChestRegistry.select_options(
			seed_value,
			"player:stable:1",
			all_options
		)
		var unique: Dictionary = {}
		for option_id in first:
			unique[option_id] = true
		_expect(
			first == replay and first.size() == 3 and unique.size() == 3,
			"每位玩家必须按固定 seed 等概率、不放回生成三项候选。"
		)
	_expect(
		not RogueRareChestRegistry.compute_runtime_contract_hash().is_empty(),
		"稀有宝箱运行合同哈希不能为空。"
	)


func _test_availability_and_settlement(
	economy: RogueRareChestEconomyCoordinator,
	run_state: RunStateStore
) -> void:
	var ranged_options := economy.get_valid_option_ids(1)
	var melee_options := economy.get_valid_option_ids(2)
	_expect(
		ranged_options.has(RogueRareChestRegistry.OPTION_AMMO_CAPACITY)
		and not melee_options.has(RogueRareChestRegistry.OPTION_AMMO_CAPACITY),
		"弹夹容量奖励只能出现在 Registry 标记支持弹药的角色候选池。"
	)
	var revision_before := run_state.get_party_status_ledger_revision()
	var result := economy.resolve_choice(
		1,
		"7:701:rare_chest",
		RogueRareChestRegistry.OPTION_MAX_HEALTH
	)
	_expect(
		bool(result.get("resolved", false))
		and int(result.get("heal_delta", 0)) == 10
		and run_state.get_player_stat_bonus_value(1, &"max_health") == 10
		and run_state.get_party_status_ledger_revision() == revision_before + 1,
		"生命强化必须通过共享状态账本 CAS 永久增加10点，并只返回一次治疗元数据。"
	)
	var replay := economy.resolve_choice(
		1,
		"7:701:rare_chest",
		RogueRareChestRegistry.OPTION_MAX_HEALTH
	)
	_expect(
		bool(replay.get("replayed", false))
		and run_state.get_player_stat_bonus_value(1, &"max_health") == 10
		and run_state.get_party_status_ledger_revision() == revision_before + 1,
		"同一玩家同一 occurrence 的结算重放不得重复增加永久属性。"
	)
	var peer_one_snapshot := economy.export_snapshot(1)
	var peer_two_snapshot := economy.export_snapshot(2)
	_expect(
		(peer_one_snapshot.get("settled_choices", []) as Array).size() == 1
		and (peer_two_snapshot.get("settled_choices", []) as Array).is_empty(),
		"RareChest Economy 快照必须按目标 peer 隐藏他人的私人结算。"
	)
	var remote_economy := RogueRareChestEconomyCoordinator.new()
	root.add_child(remote_economy)
	remote_economy.reset_runtime(run_state)
	_expect(
		remote_economy.apply_remote_snapshot(peer_one_snapshot)
		and remote_economy.apply_remote_snapshot(peer_two_snapshot),
		"新 peer 重连为旁观者时，必须能在同一 economy revision 下用空私人子集替换旧身份结算。"
	)
	remote_economy.queue_free()
	_expect(
		_apply_stat_bonus(
			run_state,
			2,
			RogueRareChestRegistry.OPTION_MAGIC_DEFENSE,
			100
		)
		and not economy.get_valid_option_ids(2).has(
			RogueRareChestRegistry.OPTION_MAGIC_DEFENSE
		),
		"法术防御永久加成达到100后必须从有效候选池排除。"
	)


func _test_session_lifecycle(
	session: RogueRareChestSession,
	run_state: RunStateStore
) -> void:
	_expect(
		session.start_for_node(11, 0x7711, [1, 2], {
			1: "player:stable:1",
			2: "player:stable:2",
		}),
		"权威稀有宝箱 Session 必须能在首次访问时启动。"
	)
	var peer_one := session.export_state_for_peer(1)
	var peer_two := session.export_state_for_peer(2)
	_expect(
		StringName(peer_one.get("phase", &""))
		== RogueRareChestSession.PHASE_CHOOSING
		and (peer_one.get("local_option_ids", []) as Array).size() == 3
		and (peer_two.get("local_option_ids", []) as Array).size() == 3
		and int(peer_one.get("target_peer_id", -1)) == 1
		and int(peer_two.get("target_peer_id", -1)) == 2,
		"每位参与者必须收到恰好三项、只标记自身目标的私人候选。"
	)
	var peer_one_option := StringName(
		(peer_one["local_option_ids"] as Array)[0]
	)
	var revision_before := run_state.get_party_status_ledger_revision()
	_expect(
		session.submit_choice(
			1,
			str(peer_one["occurrence_key"]),
			int(peer_one["offer_revision"]),
			peer_one_option
		),
		"玩家必须能以自己的 offer revision 提交私人选项。"
	)
	peer_one = session.export_state_for_peer(1)
	peer_two = session.export_state_for_peer(2)
	_expect(
		StringName(peer_one.get("phase", &""))
		== RogueRareChestSession.PHASE_WAITING
		and StringName(peer_two.get("phase", &""))
		== RogueRareChestSession.PHASE_CHOOSING
		and not StringName(peer_one.get(
			"local_selected_option_id",
			&""
		)).is_empty()
		and StringName(peer_two.get(
			"local_selected_option_id",
			&""
		)).is_empty()
		and run_state.get_party_status_ledger_revision() == revision_before + 1,
		"先完成的玩家应进入等待，其他玩家仍保留独立选择且看不到前者结果。"
	)
	_expect(
		not session.submit_choice(
			1,
			str(peer_one["occurrence_key"]),
			int(peer_one["offer_revision"]) - 1,
			peer_one_option
		),
		"已结算或陈旧 offer revision 的请求必须被拒绝。"
	)
	_expect(
		session.remove_peer(2)
		and session.get_phase() == RogueRareChestSession.PHASE_COMPLETED
		and session.is_node_resolved(11),
		"断线未选玩家必须立即放弃并计入全员完成。"
	)
	var completed_for_peer_one := session.export_state_for_peer(1)
	_expect(
		(completed_for_peer_one.get("abandoned_peer_ids", []) as Array).has(2)
		and not session.start_for_node(11, 0x7711, [1, 2], {
			1: "player:stable:1",
			2: "player:stable:2",
		}),
		"已完成节点必须记录断线放弃，回访不得再次生成奖励。"
	)
	_expect(
		session.add_spectator(3)
		and (session.export_state_for_peer(3).get(
			"local_option_ids",
			[]
		) as Array).is_empty(),
		"迟到玩家只能旁观，不能取得本次私人候选。"
	)
	_expect(
		session.start_for_node(12, 0x7712, [1, 2], {
			1: "player:stable:1",
			2: "player:stable:2",
		}),
		"上一节点完成后必须能启动新的稀有宝箱 occurrence。"
	)
	var next_peer_one := session.export_state_for_peer(1)
	var next_peer_two := session.export_state_for_peer(2)
	_expect(
		session.submit_choice(
			1,
			str(next_peer_one["occurrence_key"]),
			int(next_peer_one["offer_revision"]),
			StringName((next_peer_one["local_option_ids"] as Array)[0])
		)
		and session.submit_choice(
			2,
			str(next_peer_two["occurrence_key"]),
			int(next_peer_two["offer_revision"]),
			StringName((next_peer_two["local_option_ids"] as Array)[0])
		)
		and session.get_phase() == RogueRareChestSession.PHASE_COMPLETED,
		"所有在线参与者各自选择后必须只完成一次全队节点。"
	)
	_expect(
		session.start_for_node(13, 0x7713, [1, 2], {
			1: "player:stable:1",
			2: "player:stable:2",
		}),
		"重连 revision 测试必须能启动第三个 occurrence。"
	)
	var revision_before_migration := session.get_revision()
	_expect(
		session.migrate_peer(2, 4)
		and session.get_revision() == revision_before_migration + 1
		and (session.export_state_for_peer(4).get(
			"spectator_peer_ids",
			[]
		) as Array).has(4)
		and (session.export_state_for_peer(1).get(
			"abandoned_peer_ids",
			[]
		) as Array).has(2),
		"重连必须以一次 revision 将旧参与者标记放弃、新身份改为旁观。"
	)


func _apply_stat_bonus(
	run_state: RunStateStore,
	peer_id: int,
	stat_id: StringName,
	delta: int
) -> bool:
	var next_status := run_state.build_party_status_ledger_with_player_stat_bonus(
		peer_id,
		stat_id,
		delta
	)
	if next_status.is_empty():
		return false
	var party_snapshot := run_state.export_party_economy_snapshot(
		PackedInt32Array([peer_id])
	)
	var expected_inventory_revisions: Dictionary = {}
	for raw_inventory_value in party_snapshot.get("inventories", []) as Array:
		var inventory := raw_inventory_value as Dictionary
		expected_inventory_revisions[int(inventory.get("peer_id", -1))] = int(
			inventory.get("revision", -1)
		)
	return run_state.apply_authoritative_party_transaction(
		party_snapshot,
		int((party_snapshot["warehouse_ledger"] as Dictionary)["revision"]),
		expected_inventory_revisions,
		-1,
		{},
		int((party_snapshot["party_status_ledger"] as Dictionary)["revision"]),
		next_status
	)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
		push_error(message)


func _finish() -> void:
	if failures.is_empty():
		print("ROGUE_RARE_CHEST_DOMAIN_SMOKE_TEST_OK")
		quit(0)
		return
	for message in failures:
		print("FAILED: %s" % message)
	quit(1)
