extends SceneTree

const WOOD: PickupConfig = preload(
	"res://resources/config/materials/material_wood.tres"
)

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_unstarted_reads_and_wire_validation_are_pure()
	_test_batch_registration_is_atomic()
	_test_unknown_peer_mutations_are_atomic_rejections()
	_test_same_revision_snapshot_conflict_is_rejected()
	_test_commit_does_not_repair_broken_member_state()
	_test_membership_remap_and_final_departure()
	_test_remap_preflight_rejects_partial_or_conflicting_state()
	_test_final_departure_clears_remap_alias_family()
	_test_session_membership_reconcile_is_monotonic()
	call_deferred("_finish")


func _test_unstarted_reads_and_wire_validation_are_pure() -> void:
	var store := RunStateStore.new()
	root.add_child(store)
	var signal_counts := _connect_signal_counts(store)
	var envelope := _make_empty_inventory_envelope(41, 3)
	_expect(
		store.validate_inventory_snapshot_envelope(41, envelope),
		"wire envelope 校验不得依赖 Run 或 peer 注册状态。"
	)
	_expect(not store.has_multiplayer_peer_state(41), "只读成员查询不得创建未知 peer。")
	_expect(store.get_registered_multiplayer_peer_ids().is_empty(), "未开始 Run 不得存在多人成员。")
	_expect(store.get_inventory_revision_for_peer(41) == -1, "未知 peer revision 必须使用 -1 哨兵。")
	_expect(store.get_item_for_peer(41, 0) == null, "未知 peer 物品读取必须返回空。")
	_expect(store.get_item_count_for_peer(41, 0) == 0, "未知 peer 数量读取必须返回 0。")
	_expect(store.export_inventory_snapshot_for_peer(41).is_empty(), "未知 peer 不得导出幽灵背包。")
	_expect(store.export_party_economy_snapshot().is_empty(), "未开始 Run 不得隐式导出并创建状态。")
	_expect(store.export_party_status_ledger().is_empty(), "未开始 Run 的状态导出必须为空。")
	_expect(store.export_party_xirang_ledger().is_empty(), "未开始 Run 的息壤导出必须为空。")
	_expect(store.export_party_light_stone_ledger().is_empty(), "未开始 Run 的光石导出必须为空。")
	_expect(store.export_rogue_encounter_history_ledger().is_empty(), "未开始 Run 的遭遇导出必须为空。")
	_expect(not store.run_started, "任意 getter/export/validator 都不得隐式开始 Run。")
	_expect(_all_signal_counts_are_zero(signal_counts), "纯读取不得发布信号。")
	_expect(
		store.multiplayer_inventories.is_empty()
		and store.multiplayer_inventory_stack_counts.is_empty()
		and store.multiplayer_inventory_revisions.is_empty(),
		"纯读取不得留下任何多人背包副本。"
	)
	var invalid_envelope := envelope.duplicate(true)
	(invalid_envelope["slots"] as Array)[0]["revision"] = 2
	_expect(
		not store.validate_inventory_snapshot_envelope(41, invalid_envelope),
		"槽内冗余 revision 与 envelope 不一致时必须拒绝。"
	)
	store.queue_free()


func _test_batch_registration_is_atomic() -> void:
	var store := RunStateStore.new()
	root.add_child(store)
	store.begin_new_run(PlayerCharacterRegistry.DEFAULT_CHARACTER_ID, false)
	var signal_counts := _connect_signal_counts(store)
	_expect(
		store.register_multiplayer_peer_states(PackedInt32Array([7, 3, 7])),
		"认证 roster 必须可整批注册并去重。"
	)
	_expect(
		store.get_registered_multiplayer_peer_ids() == PackedInt32Array([3, 7]),
		"成员列表必须来自唯一成员表并稳定排序。"
	)
	_expect(
		store.party_xirang_ledger_revision == 1
		and store.party_status_ledger_revision == 1,
		"任意规模的单批注册只能让每类 ledger revision 前进一步。"
	)
	_expect(
		int(signal_counts["xirang"]) == 1
		and int(signal_counts["status"]) == 1
		and int(signal_counts["inventory"]) == 1
		and int(signal_counts["upgrade"]) == 1
		and int(signal_counts["membership"]) == 1,
		"整批注册必须在所有分账本写齐后，每类观察信号恰好发布一次。"
	)
	var state_after_registration := _capture_authoritative_state(store)
	_reset_signal_counts(signal_counts)
	_expect(
		store.register_multiplayer_peer_states(PackedInt32Array([3, 7])),
		"重复 roster 注册必须幂等成功。"
	)
	_expect(
		_capture_authoritative_state(store) == state_after_registration
		and _all_signal_counts_are_zero(signal_counts),
		"幂等注册不得推进 revision、改写数据或发信号。"
	)
	_expect(
		not store.register_multiplayer_peer_states(PackedInt32Array([9, 0])),
		"含非法 peer 的整批注册必须整体拒绝。"
	)
	_expect(
		not store.has_multiplayer_peer_state(9)
		and _capture_authoritative_state(store) == state_after_registration,
		"注册 prepare 失败后不得留下先前已准备的半个成员。"
	)
	store.multiplayer_inventory_revisions[11] = 7
	var orphan_state := _capture_authoritative_state(store)
	_reset_signal_counts(signal_counts)
	_expect(
		not store.register_multiplayer_peer_states(PackedInt32Array([11, 13])),
		"任一待注册身份残留孤儿分账本时，整批注册必须拒绝。"
	)
	_expect(
		_capture_authoritative_state(store) == orphan_state
		and not store.has_multiplayer_peer_state(11)
		and not store.has_multiplayer_peer_state(13)
		and _all_signal_counts_are_zero(signal_counts),
		"成员注册不得覆盖孤儿账本、提交同批其他成员或发布半事务信号。"
	)
	store.multiplayer_inventory_revisions.erase(11)
	_expect(
		store.try_add_item_count_for_peer(7, WOOD, 2)
		and store.set_party_xirang_balance(7, 88)
		and store.set_max_health_penalty_for_peer(7, 4)
		and store.set_upgrade_level_for_peer(7, RunStateStore.StatType.ATTACK, 2),
		"已认证但尚无 Player 节点的成员必须仍可接收全部账本结果。"
	)
	store.queue_free()


func _test_unknown_peer_mutations_are_atomic_rejections() -> void:
	var store := RunStateStore.new()
	root.add_child(store)
	store.begin_new_run(PlayerCharacterRegistry.DEFAULT_CHARACTER_ID, false)
	_expect(store.register_multiplayer_peer_state(5), "基线成员必须注册成功。")
	var unknown_snapshot := _make_empty_inventory_envelope(99, 1)
	var party_snapshot := store.export_party_economy_snapshot(PackedInt32Array([5]))
	(party_snapshot["inventories"] as Array).append(unknown_snapshot)
	var signal_counts := _connect_signal_counts(store)
	var baseline := _capture_authoritative_state(store)
	_expect(not store.set_active_multiplayer_peer(99), "未知 peer 不得成为活动背包 owner。")
	_expect(not store.try_add_item_count_for_peer(99, WOOD, 1), "未知 peer 不得写入物品。")
	_expect(not store.apply_inventory_snapshot_for_peer(99, unknown_snapshot), "未知 peer 不得应用完整背包。")
	_expect(store.prepare_inventory_snapshot_for_peer(99, unknown_snapshot).is_empty(), "未知 peer 不得进入背包提交准备。")
	_expect(not store.apply_inventory_slot_state_for_peer(99, (unknown_snapshot["slots"] as Array)[0]), "未知 peer 不得应用单槽状态。")
	_expect(not store.set_party_xirang_balance(99, 100), "未知 peer 不得写入息壤。")
	_expect(not store.set_party_xirang_balances({5: 9, 99: 10}), "含未知 peer 的批量息壤必须整体拒绝。")
	_expect(not store.set_max_health_penalty_for_peer(99, 5), "未知 peer 不得写入最大生命惩罚。")
	_expect(not store.set_upgrade_level_for_peer(99, RunStateStore.StatType.ATTACK, 1), "未知 peer 不得写入升级。")
	_expect(not store.apply_party_economy_snapshot(party_snapshot), "含未知 peer 的完整经济快照必须整体拒绝。")
	_expect(
		_capture_authoritative_state(store) == baseline
		and not store.has_multiplayer_peer_state(99)
		and _all_signal_counts_are_zero(signal_counts),
		"未知 peer 的任意命令都必须原子拒绝，不得建账、推进 revision 或发信号。"
	)
	store.queue_free()


func _test_same_revision_snapshot_conflict_is_rejected() -> void:
	var store := RunStateStore.new()
	root.add_child(store)
	store.begin_new_run(PlayerCharacterRegistry.DEFAULT_CHARACTER_ID, false)
	_expect(store.register_multiplayer_peer_state(8), "冲突测试成员必须注册。")
	var baseline_snapshot := store.export_inventory_snapshot_for_peer(8)
	var conflicting_snapshot := baseline_snapshot.duplicate(true)
	(conflicting_snapshot["slots"] as Array)[0]["config_path"] = WOOD.resource_path
	(conflicting_snapshot["slots"] as Array)[0]["stack_count"] = 1
	_expect(
		store.validate_inventory_snapshot_envelope(8, conflicting_snapshot),
		"内容冲突快照本身仍应通过纯 wire 结构校验。"
	)
	var signal_counts := _connect_signal_counts(store)
	_expect(
		not store.apply_inventory_snapshot_for_peer(8, conflicting_snapshot),
		"同 revision 不同内容必须判为冲突，不能覆盖本地状态。"
	)
	_expect(
		store.apply_inventory_snapshot_for_peer(8, baseline_snapshot),
		"同 revision 同内容必须幂等成功。"
	)
	_expect(
		store.export_inventory_snapshot_for_peer(8) == baseline_snapshot
		and _all_signal_counts_are_zero(signal_counts),
		"冲突拒绝及幂等重放都不得改写状态或发信号。"
	)
	var next_snapshot := conflicting_snapshot.duplicate(true)
	next_snapshot["revision"] = 1
	for raw_slot in next_snapshot["slots"] as Array:
		(raw_slot as Dictionary)["revision"] = 1
	_expect(store.apply_inventory_snapshot_for_peer(8, next_snapshot), "更高 revision 的合法快照必须提交。")
	_expect(int(signal_counts["inventory"]) == 1, "真实背包提交必须且只能发布一次信号。")
	store.queue_free()


func _test_commit_does_not_repair_broken_member_state() -> void:
	var store := RunStateStore.new()
	root.add_child(store)
	store.begin_new_run(PlayerCharacterRegistry.DEFAULT_CHARACTER_ID, false)
	_expect(store.register_multiplayer_peer_state(12), "提交边界测试成员必须注册。")
	var next_party_snapshot := store.export_party_economy_snapshot(PackedInt32Array([12]))
	var next_inventory := (next_party_snapshot["inventories"] as Array)[0] as Dictionary
	next_inventory["revision"] = 1
	for raw_slot in next_inventory["slots"] as Array:
		(raw_slot as Dictionary)["revision"] = 1
	store.multiplayer_inventory_stack_counts.erase(12)
	var signal_counts := _connect_signal_counts(store)
	_expect(
		not store.apply_party_economy_snapshot(next_party_snapshot),
		"party economy 在提交首写前发现成员账本残缺时必须整体拒绝。"
	)
	_expect(
		not store.multiplayer_inventory_stack_counts.has(12)
		and _all_signal_counts_are_zero(signal_counts),
		"commit 阶段禁止用 ensure 重建残缺成员或发信号。"
	)
	store.queue_free()


func _test_membership_remap_and_final_departure() -> void:
	var store := RunStateStore.new()
	root.add_child(store)
	store.begin_new_run(PlayerCharacterRegistry.DEFAULT_CHARACTER_ID, false)
	_expect(
		store.reconcile_multiplayer_session_membership(
			PackedInt32Array([2, 4]),
			0
		),
		"重连基线 roster 必须由权威成员 revision 注册。"
	)
	_expect(store.set_party_xirang_balance(2, 77), "旧身份账本必须能建立测试值。")
	var signal_counts := _connect_signal_counts(store)
	var observed_states: Array[Dictionary] = []
	_connect_atomic_remap_observers(store, observed_states)
	var state_before_preparation := _capture_authoritative_state(store)
	_expect(
		store.prepare_multiplayer_peer_state_remap(2, 6, 1)
		== RunStateStore.MultiplayerPeerRemapResult.MIGRATED
		and _capture_authoritative_state(store) == state_before_preparation
		and _all_signal_counts_are_zero(signal_counts)
		and observed_states.is_empty(),
		"重连 prepare 必须复用正式 validator，但不得写账本、推进 revision 或发信号。"
	)
	_expect(
		store.remap_multiplayer_peer_state(2, 6, 1)
		== RunStateStore.MultiplayerPeerRemapResult.MIGRATED,
		"重连身份必须迁移成员资格和全部账本。"
	)
	_expect(
		store.get_registered_multiplayer_peer_ids() == PackedInt32Array([4, 6])
		and not store.has_multiplayer_peer_state(2)
		and store.get_party_xirang_balance(6) == 77
		and store.get_multiplayer_session_membership_revision() == 1,
		"remap 后旧身份必须消失，新身份必须成为唯一账本成员。"
	)
	_expect(
		observed_states.size() == 5
		and _all_observed_states_are_atomic_remap(observed_states, 2, 6, 1),
		"所有迁移信号都只能观察到完整 new 身份和已推进的成员 revision。"
	)
	var committed_state := _capture_authoritative_state(store)
	_reset_signal_counts(signal_counts)
	observed_states.clear()
	_expect(
		store.remap_multiplayer_peer_state(2, 6, 1)
		== RunStateStore.MultiplayerPeerRemapResult.ALREADY_CURRENT
		and _capture_authoritative_state(store) == committed_state
		and _all_signal_counts_are_zero(signal_counts)
		and observed_states.is_empty(),
		"同一 old/new/revision 只能凭本局 alias 证明幂等成功，且不得重复发信号。"
	)
	_expect(
		store.remap_multiplayer_peer_state(2, 7, 1)
		== RunStateStore.MultiplayerPeerRemapResult.CONFLICT
		and store.remap_multiplayer_peer_state(2, 6, 2)
		== RunStateStore.MultiplayerPeerRemapResult.CONFLICT
		and _capture_authoritative_state(store) == committed_state,
		"同一退役 old 身份不得被另一 new 或另一 revision 重新解释。"
	)
	_expect(
		store.reconcile_multiplayer_session_membership(
			PackedInt32Array([4, 6]),
			2
		),
		"非身份变化的较新 roster revision 必须可继续前进。"
	)
	var before_final_departure := store.party_status_ledger_revision
	_expect(
		store.reconcile_multiplayer_session_membership(
			PackedInt32Array([6]),
			3
		)
		and store.get_registered_multiplayer_peer_ids() == PackedInt32Array([6])
		and not store.multiplayer_inventories.has(4)
		and not store.party_xirang_balances.has(4)
		and store.party_status_ledger_revision == before_final_departure + 1,
		"最终离场只能经较新权威 roster，从成员表与全部分账本原子移除。"
	)
	store.queue_free()


func _test_remap_preflight_rejects_partial_or_conflicting_state() -> void:
	var store := RunStateStore.new()
	root.add_child(store)
	store.begin_new_run(PlayerCharacterRegistry.DEFAULT_CHARACTER_ID, false)
	_expect(
		store.reconcile_multiplayer_session_membership(PackedInt32Array([2]), 0),
		"深度预检夹具必须注册 old 身份。"
	)
	(store.player_stat_bonuses[2] as Dictionary).erase("move_speed")
	var partial_old_state := _capture_authoritative_state(store)
	var signal_counts := _connect_signal_counts(store)
	_expect(
		store.remap_multiplayer_peer_state(2, 3, 1)
		== RunStateStore.MultiplayerPeerRemapResult.INVALID
		and _capture_authoritative_state(store) == partial_old_state
		and _all_signal_counts_are_zero(signal_counts),
		"old 的任一嵌套分账本残缺时，迁移必须在首写前整体拒绝。"
	)

	store.begin_new_run(PlayerCharacterRegistry.DEFAULT_CHARACTER_ID, false)
	_expect(
		store.reconcile_multiplayer_session_membership(
			PackedInt32Array([2, 3]),
			0
		),
		"双身份冲突夹具必须建立两个完整成员。"
	)
	var both_present_state := _capture_authoritative_state(store)
	_reset_signal_counts(signal_counts)
	_expect(
		store.remap_multiplayer_peer_state(2, 3, 1)
		== RunStateStore.MultiplayerPeerRemapResult.CONFLICT
		and _capture_authoritative_state(store) == both_present_state
		and _all_signal_counts_are_zero(signal_counts),
		"old/new 同时存在时必须判冲突，禁止按 revision 合并两份玩家状态。"
	)

	store.begin_new_run(PlayerCharacterRegistry.DEFAULT_CHARACTER_ID, false)
	_expect(
		store.reconcile_multiplayer_session_membership(PackedInt32Array([2]), 0),
		"目标残留夹具必须重新建立 old 身份。"
	)
	store.multiplayer_inventory_revisions[3] = 9
	var orphan_target_state := _capture_authoritative_state(store)
	_reset_signal_counts(signal_counts)
	_expect(
		store.remap_multiplayer_peer_state(2, 3, 1)
		== RunStateStore.MultiplayerPeerRemapResult.CONFLICT
		and _capture_authoritative_state(store) == orphan_target_state
		and _all_signal_counts_are_zero(signal_counts),
		"目标未注册但残留任一分账本键时也必须判冲突，不能静默覆盖。"
	)

	store.begin_new_run(PlayerCharacterRegistry.DEFAULT_CHARACTER_ID, false)
	_expect(
		store.reconcile_multiplayer_session_membership(PackedInt32Array([2]), 0)
		and store.remap_multiplayer_peer_state(2, 3, 1)
		== RunStateStore.MultiplayerPeerRemapResult.MIGRATED,
		"幂等物理形态夹具必须先完成一次真实迁移。"
	)
	_reset_signal_counts(signal_counts)
	store.multiplayer_inventory_revisions[2] = 9
	var resurrected_old_state := _capture_authoritative_state(store)
	_expect(
		store.remap_multiplayer_peer_state(2, 3, 1)
		== RunStateStore.MultiplayerPeerRemapResult.CONFLICT
		and _capture_authoritative_state(store) == resurrected_old_state
		and _all_signal_counts_are_zero(signal_counts),
		"alias 精确但 old 又出现存储时必须判冲突，不能冒充幂等成功。"
	)
	store.multiplayer_inventory_revisions.erase(2)
	store.multiplayer_inventory_stack_counts.erase(3)
	var incomplete_new_state := _capture_authoritative_state(store)
	_expect(
		store.remap_multiplayer_peer_state(2, 3, 1)
		== RunStateStore.MultiplayerPeerRemapResult.INVALID
		and _capture_authoritative_state(store) == incomplete_new_state
		and _all_signal_counts_are_zero(signal_counts),
		"alias 精确但 new 已残缺时必须拒绝，不能用事务证明掩盖账本损坏。"
	)
	store.queue_free()


func _test_final_departure_clears_remap_alias_family() -> void:
	var store := RunStateStore.new()
	root.add_child(store)
	store.begin_new_run(PlayerCharacterRegistry.DEFAULT_CHARACTER_ID, false)
	_expect(
		store.reconcile_multiplayer_session_membership(PackedInt32Array([2]), 0)
		and store.remap_multiplayer_peer_state(2, 3, 1)
		== RunStateStore.MultiplayerPeerRemapResult.MIGRATED
		and store.remap_multiplayer_peer_state(3, 4, 2)
		== RunStateStore.MultiplayerPeerRemapResult.MIGRATED,
		"alias 清理夹具必须建立两段连续重连身份链。"
	)
	_expect(
		store._multiplayer_peer_remap_aliases.size() == 2
		and store.reconcile_multiplayer_session_membership(
			PackedInt32Array(),
			3
		)
		and store._multiplayer_peer_remap_aliases.is_empty(),
		"最终成员离场必须在同一提交中清除命中它的整条 alias 祖先链。"
	)
	_expect(
		store.reconcile_multiplayer_session_membership(PackedInt32Array([2]), 4)
		and store.remap_multiplayer_peer_state(2, 3, 5)
		== RunStateStore.MultiplayerPeerRemapResult.MIGRATED,
		"最终离场清除旧证明后，同局 transport ID 复用不得遭遇幽灵冲突。"
	)
	store.queue_free()


func _test_session_membership_reconcile_is_monotonic() -> void:
	var store := RunStateStore.new()
	root.add_child(store)
	store.begin_new_run(PlayerCharacterRegistry.DEFAULT_CHARACTER_ID, false)
	var observed := {"revision": -2}
	store.multiplayer_peer_membership_changed.connect(
		func(_peer_ids: PackedInt32Array) -> void:
			observed["revision"] = (
				store.get_multiplayer_session_membership_revision()
			)
	)
	_expect(
		store.reconcile_multiplayer_session_membership(
			PackedInt32Array([2, 4]),
			5
		)
		and int(observed["revision"]) == 5,
		"首次 client setup 必须直接接纳 Host 的较高成员 revision。"
	)
	_expect(
		store.try_add_item_count_for_peer(2, WOOD, 3)
		and store.set_party_xirang_balance(2, 77)
		and store.set_upgrade_level_for_peer(
			2,
			RunStateStore.StatType.ATTACK,
			2
		),
		"重连旧身份必须先建立非默认 CH6/升级/息壤状态。"
	)
	var inventory_revision := store.get_inventory_revision_for_peer(2)
	_expect(
		store.reconcile_multiplayer_session_membership(
			PackedInt32Array([4, 2]),
			6
		)
		and store.get_inventory_revision_for_peer(2) == inventory_revision,
		"仅在线/宽限状态变化时 roster revision 可前进，但不得改写任何分账本。"
	)
	var before_unmapped_replacement := _capture_authoritative_state(store)
	_expect(
		not store.reconcile_multiplayer_session_membership(
			PackedInt32Array([4, 6]),
			7
		)
		and _capture_authoritative_state(store) == before_unmapped_replacement,
		"old/new 替换必须先完成显式 remap，reconcile 不得删旧建新。"
	)
	_expect(
		store.remap_multiplayer_peer_state(2, 6, 7)
		== RunStateStore.MultiplayerPeerRemapResult.MIGRATED
		and store.reconcile_multiplayer_session_membership(
			PackedInt32Array([4, 6]),
			7
		),
		"重连身份事务完成后，同一 Host roster revision 必须可幂等收敛。"
	)
	_expect(
		store.get_inventory_item_total_for_peer(6, WOOD) == 3
		and store.get_inventory_revision_for_peer(6) == inventory_revision
		and store.get_party_xirang_balance(6) == 77
		and store.get_upgrade_level_for_peer(
			6,
			RunStateStore.StatType.ATTACK
		) == 2,
		"old→new 后必须精确保留库存 revision、升级和息壤，不得初始化新账本。"
	)
	var converged_state := _capture_authoritative_state(store)
	_expect(
		not store.reconcile_multiplayer_session_membership(
			PackedInt32Array([2, 4]),
			6
		)
		and not store.reconcile_multiplayer_session_membership(
			PackedInt32Array([6]),
			7
		)
		and _capture_authoritative_state(store) == converged_state,
		"旧 revision 与同 revision 不同 roster 都必须原子拒绝。"
	)
	_expect(
		store.reconcile_multiplayer_session_membership(
			PackedInt32Array([6]),
			8
		)
		and store.get_multiplayer_session_membership_revision() == 8
		and not store.has_multiplayer_peer_state(4),
		"final departure 的较新 roster 必须原子移除唯一离场成员。"
	)
	store.queue_free()


func _make_empty_inventory_envelope(peer_id: int, revision: int) -> Dictionary:
	var slots: Array[Dictionary] = []
	for slot_index in RunStateStore.INVENTORY_CAPACITY:
		slots.append({
			"slot_index": slot_index,
			"config_path": "",
			"stack_count": 0,
			"revision": revision,
		})
	return {
		"peer_id": peer_id,
		"revision": revision,
		"slots": slots,
	}


func _capture_authoritative_state(store: RunStateStore) -> Dictionary:
	return {
		"registered": store.get_registered_multiplayer_peer_ids(),
		"membership_revision": (
			store.get_multiplayer_session_membership_revision()
		),
		"remap_aliases": store._multiplayer_peer_remap_aliases.duplicate(true),
		"active": store.get_active_multiplayer_peer_id(),
		"inventories": store.multiplayer_inventories.duplicate(true),
		"counts": store.multiplayer_inventory_stack_counts.duplicate(true),
		"inventory_revisions": store.multiplayer_inventory_revisions.duplicate(true),
		"upgrades": store.multiplayer_upgrade_levels.duplicate(true),
		"xirang": store.party_xirang_balances.duplicate(true),
		"xirang_revision": store.party_xirang_ledger_revision,
		"penalties": store.max_health_penalties.duplicate(true),
		"bonuses": store.player_stat_bonuses.duplicate(true),
		"status_revision": store.party_status_ledger_revision,
	}


func _connect_atomic_remap_observers(
	store: RunStateStore,
	observed_states: Array[Dictionary]
) -> void:
	var capture := func() -> void:
		observed_states.append(_capture_authoritative_state(store))
	store.inventory_changed.connect(capture)
	store.upgrade_changed.connect(capture)
	store.party_xirang_ledger_changed.connect(
		func(_snapshot: Dictionary) -> void: capture.call()
	)
	store.party_status_ledger_changed.connect(
		func(_snapshot: Dictionary) -> void: capture.call()
	)
	store.multiplayer_peer_membership_changed.connect(
		func(_peer_ids: PackedInt32Array) -> void: capture.call()
	)


func _all_observed_states_are_atomic_remap(
	observed_states: Array[Dictionary],
	old_peer_id: int,
	new_peer_id: int,
	membership_revision: int
) -> bool:
	for state in observed_states:
		var registered := state.get("registered", PackedInt32Array()) as PackedInt32Array
		var inventories := state.get("inventories", {}) as Dictionary
		var counts := state.get("counts", {}) as Dictionary
		var inventory_revisions := state.get("inventory_revisions", {}) as Dictionary
		var upgrades := state.get("upgrades", {}) as Dictionary
		var xirang := state.get("xirang", {}) as Dictionary
		var penalties := state.get("penalties", {}) as Dictionary
		var bonuses := state.get("bonuses", {}) as Dictionary
		var aliases := state.get("remap_aliases", {}) as Dictionary
		var alias := aliases.get(old_peer_id, {}) as Dictionary
		if (
			int(state.get("membership_revision", -1)) != membership_revision
			or int(alias.get("new_peer_id", 0)) != new_peer_id
			or int(alias.get("membership_revision", -1)) != membership_revision
			or registered.has(old_peer_id)
			or not registered.has(new_peer_id)
			or inventories.has(old_peer_id)
			or counts.has(old_peer_id)
			or inventory_revisions.has(old_peer_id)
			or upgrades.has(old_peer_id)
			or xirang.has(old_peer_id)
			or penalties.has(old_peer_id)
			or bonuses.has(old_peer_id)
			or not inventories.has(new_peer_id)
			or not counts.has(new_peer_id)
			or not inventory_revisions.has(new_peer_id)
			or not upgrades.has(new_peer_id)
			or not xirang.has(new_peer_id)
			or not penalties.has(new_peer_id)
			or not bonuses.has(new_peer_id)
		):
			return false
	return true


func _connect_signal_counts(store: RunStateStore) -> Dictionary:
	var counts := {
		"inventory": 0,
		"upgrade": 0,
		"xirang": 0,
		"status": 0,
		"membership": 0,
	}
	store.inventory_changed.connect(func() -> void:
		counts["inventory"] = int(counts["inventory"]) + 1
	)
	store.upgrade_changed.connect(func() -> void:
		counts["upgrade"] = int(counts["upgrade"]) + 1
	)
	store.party_xirang_ledger_changed.connect(func(_snapshot: Dictionary) -> void:
		counts["xirang"] = int(counts["xirang"]) + 1
	)
	store.party_status_ledger_changed.connect(func(_snapshot: Dictionary) -> void:
		counts["status"] = int(counts["status"]) + 1
	)
	store.multiplayer_peer_membership_changed.connect(
		func(_peer_ids: PackedInt32Array) -> void:
			counts["membership"] = int(counts["membership"]) + 1
	)
	return counts


func _reset_signal_counts(signal_counts: Dictionary) -> void:
	for key in signal_counts.keys():
		signal_counts[key] = 0


func _all_signal_counts_are_zero(signal_counts: Dictionary) -> bool:
	for count in signal_counts.values():
		if int(count) != 0:
			return false
	return true


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("RUN_STATE_PEER_MEMBERSHIP_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)
