extends SceneTree

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_strict_schema_and_authority_replacement()
	_test_prepared_commit_cas_and_forgery_guard()
	if failures.is_empty():
		print("RUN_STATE_PLAYER_UPGRADE_LEDGER_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_strict_schema_and_authority_replacement() -> void:
	var store := RunStateStore.new()
	_expect(store.export_player_upgrade_ledger().is_empty(), "未开始 Run 不得导出成长账本。")
	store.begin_new_run(&"weishidaier", false)
	_expect(
		store.register_multiplayer_peer_states(PackedInt32Array([11, 22])),
		"测试成员必须整批注册。"
	)
	var base := store.export_player_upgrade_ledger()
	_expect(
		base.size() == 4
		and int(base["schema_version"])
		== RunStateStore.PLAYER_UPGRADE_LEDGER_SCHEMA_VERSION
		and (base["values"] as Dictionary).size() == 3,
		"完整成长账本必须只含 schema/revision/membership/values，并覆盖 owner0 与全部成员。"
	)

	var missing_skill := base.duplicate(true)
	((missing_skill["values"] as Dictionary)["11"] as Dictionary).erase(
		"skill1_upgrade_level"
	)
	var extra_field := base.duplicate(true)
	(extra_field["values"] as Dictionary)["11"]["extra"] = 1
	var missing_peer := base.duplicate(true)
	(missing_peer["values"] as Dictionary).erase("22")
	var malformed_level := base.duplicate(true)
	(
		(malformed_level["values"] as Dictionary)["11"]["upgrade_levels"]
		as Dictionary
	)[str(RunStateStore.StatType.ATTACK)] = "4"
	var before_rejections := store.export_player_upgrade_ledger()
	_expect(
		not store.apply_player_upgrade_ledger(missing_skill)
		and not store.apply_player_upgrade_ledger(extra_field)
		and not store.apply_player_upgrade_ledger(missing_peer)
		and not store.apply_player_upgrade_ledger(malformed_level)
		and store.export_player_upgrade_ledger() == before_rejections,
		"同版缺字段、额外字段、缺成员或错类型必须整体拒绝且零写入。"
	)
	_expect(
		store.apply_player_upgrade_ledger(base)
		and store.export_player_upgrade_ledger() == base,
		"原样完整快照必须幂等成功。"
	)

	var host_revision_one := _with_entry_levels(
		base,
		1,
		11,
		{RunStateStore.StatType.ATTACK: 4, RunStateStore.StatType.HEALTH: 2},
		2
	)
	host_revision_one = _with_entry_levels(
		host_revision_one,
		1,
		22,
		{RunStateStore.StatType.ATTACK: 1, RunStateStore.StatType.DODGE: 3},
		1
	)
	_expect(
		store.apply_player_upgrade_ledger(host_revision_one)
		and store.get_upgrade_level_for_peer(11, RunStateStore.StatType.ATTACK) == 4
		and store.get_skill1_upgrade_level_for_peer(11) == 2
		and store.get_upgrade_level_for_peer(22, RunStateStore.StatType.DODGE) == 3,
		"首份 Host 权威账本必须按成员绝对提交且不得串玩家。"
	)

	# CH6 是本地字段高水位，不得伪造 authority revision；更高 Host revision
	# 可以纠正旧客户端本地误投影出的过高等级。
	_expect(
		store.set_upgrade_level_for_peer(11, RunStateStore.StatType.ATTACK, 8)
		and store.set_skill1_upgrade_level_for_peer(11, 5)
		and store.get_player_upgrade_ledger_revision() == 1,
		"逐字段修复不得推进 Host authority revision。"
	)
	var host_revision_two := _with_entry_levels(
		host_revision_one,
		2,
		11,
		{RunStateStore.StatType.ATTACK: 5, RunStateStore.StatType.HEALTH: 3},
		3
	)
	_expect(
		store.apply_player_upgrade_ledger(host_revision_two)
		and store.get_upgrade_level_for_peer(11, RunStateStore.StatType.ATTACK) == 5
		and store.get_skill1_upgrade_level_for_peer(11) == 3
		and store.get_upgrade_level_for_peer(22, RunStateStore.StatType.DODGE) == 3,
		"更高 authority revision 必须精确替换，可降回 Host 值且保持其他成员不串线。"
	)
	var committed := store.export_player_upgrade_ledger()
	_expect(
		store.apply_player_upgrade_ledger(host_revision_two)
		and store.export_player_upgrade_ledger() == committed,
		"权威账本重复投递必须幂等。"
	)
	_expect(
		not store.apply_player_upgrade_ledger(host_revision_one)
		and store.export_player_upgrade_ledger() == committed,
		"旧 authority revision 必须拒绝且不能回滚。"
	)
	var equal_conflict := _with_entry_levels(
		host_revision_two,
		2,
		11,
		{RunStateStore.StatType.ATTACK: 4},
		2
	)
	_expect(
		not store.apply_player_upgrade_ledger(equal_conflict)
		and store.apply_player_upgrade_ledger(equal_conflict, true)
		and store.get_upgrade_level_for_peer(11, RunStateStore.StatType.ATTACK) == 4
		and store.get_skill1_upgrade_level_for_peer(11) == 2,
		"同 revision 冲突默认拒绝；仅显式 Host repair 可精确覆盖。"
	)
	store.free()


func _test_prepared_commit_cas_and_forgery_guard() -> void:
	var store := RunStateStore.new()
	store.begin_new_run(&"weishidaier", false)
	_expect(
		store.register_multiplayer_peer_states(PackedInt32Array([31])),
		"CAS 测试成员必须注册。"
	)
	var next := _with_entry_levels(
		store.export_player_upgrade_ledger(),
		1,
		31,
		{RunStateStore.StatType.ATTACK_SPEED: 6},
		4
	)
	var prepared := store.prepare_player_upgrade_ledger(next)
	_expect(not prepared.is_empty(), "合法 Host 快照必须可在 Route 写入前完成冻结预检。")
	var concurrent := _with_entry_levels(
		store.export_player_upgrade_ledger(),
		2,
		31,
		{RunStateStore.StatType.DODGE: 2},
		1
	)
	_expect(store.apply_player_upgrade_ledger(concurrent), "并发权威提交夹具必须成功。")
	var before_stale_commit := store.export_player_upgrade_ledger()
	_expect(
		not store.commit_prepared_player_upgrade_ledger(prepared)
		and store.export_player_upgrade_ledger() == before_stale_commit,
		"prepare 后 authority 基线变化必须让旧冻结提交 fail-close。"
	)
	var forged := {
		"expected_authority_revision": store.get_player_upgrade_ledger_revision(),
		"expected_membership_revision": int(
			store.export_player_upgrade_ledger()["membership_revision"]
		),
		"incoming_revision": store.get_player_upgrade_ledger_revision() + 1,
		"values": {
			0: {"upgrade_levels": {}, "skill1_upgrade_level": 0},
			31: {"upgrade_levels": {}, "skill1_upgrade_level": 0},
		},
		"changed": true,
	}
	_expect(
		not store.commit_prepared_player_upgrade_ledger(forged)
		and store.export_player_upgrade_ledger() == before_stale_commit,
		"commit 公共边界必须重新验证冻结值，伪造 malformed prepared 不得写入。"
	)
	store.free()


func _with_entry_levels(
	snapshot: Dictionary,
	revision: int,
	peer_id: int,
	level_overrides: Dictionary,
	skill_level: int
) -> Dictionary:
	var result := snapshot.duplicate(true)
	result["revision"] = revision
	var values := result["values"] as Dictionary
	var entry := values[str(peer_id)] as Dictionary
	var levels := entry["upgrade_levels"] as Dictionary
	for raw_stat_type in level_overrides.keys():
		levels[str(int(raw_stat_type))] = int(level_overrides[raw_stat_type])
	entry["skill1_upgrade_level"] = skill_level
	return result


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
