extends SceneTree

const REWARD_RESOLVER := preload(
	"res://scene/game_modes/rogue/combat/rogue_combat_reward_resolver.gd"
)
const SESSION_SCRIPT := preload(
	"res://scene/game_modes/rogue/combat/reward/rogue_emergency_reward_selection_session.gd"
)
const EMERGENCY_REWARD: RogueCombatRewardConfig = preload(
	"res://resources/config/rogue_combat/reward_emergency_combat.tres"
)

var _failures := PackedStringArray()


class CountingRunState:
	extends RunStateStore

	var party_transaction_attempts := 0

	func apply_authoritative_party_transaction(
		next_snapshot: Dictionary,
		expected_warehouse_ledger_revision: int,
		expected_inventory_revisions: Dictionary,
		expected_xirang_ledger_revision: int = -1,
		next_xirang_ledger: Dictionary = {},
		expected_status_ledger_revision: int = -1,
		next_status_ledger: Dictionary = {},
		expected_light_stone_ledger_revision: int = -1,
		next_light_stone_ledger: Dictionary = {}
	) -> bool:
		party_transaction_attempts += 1
		return super.apply_authoritative_party_transaction(
			next_snapshot,
			expected_warehouse_ledger_revision,
			expected_inventory_revisions,
			expected_xirang_ledger_revision,
			next_xirang_ledger,
			expected_status_ledger_revision,
			next_status_ledger,
			expected_light_stone_ledger_revision,
			next_light_stone_ledger
		)


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	_test_config_and_deterministic_offers()
	_test_two_round_atomic_settlement_and_snapshot()
	_test_timeout_and_inventory_retry()
	_test_disconnect_remap_and_restore()
	_test_full_inventory_disconnect_does_not_block_party()
	if _failures.is_empty():
		print("ROGUE_EMERGENCY_REWARD_SELECTION_SESSION_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in _failures:
		push_error(failure)
	quit(1)


func _test_config_and_deterministic_offers() -> void:
	_expect(EMERGENCY_REWARD != null, "紧急作战奖励资源必须可加载。")
	if EMERGENCY_REWARD == null:
		return
	_expect(
		EMERGENCY_REWARD.validate_config().is_empty(),
		"紧急作战奖励资源必须通过合同校验：%s" % [
			EMERGENCY_REWARD.validate_config(),
		]
	)
	_expect(
		EMERGENCY_REWARD.collectible_count == 0
		and EMERGENCY_REWARD.collectible_choice_round_count == 2
		and EMERGENCY_REWARD.collectible_choice_offer_count == 2
		and is_equal_approx(
			EMERGENCY_REWARD.collectible_choice_seconds_per_round,
			30.0
		)
		and EMERGENCY_REWARD.collectible_choice_rarities
		== PackedInt32Array([0, 1, 2]),
		"紧急作战必须配置为连续两轮、每轮2选1、30秒及三品质等概率池。"
	)
	var resource_paths := PackedStringArray()
	for item in EMERGENCY_REWARD.random_item_reward_pool:
		resource_paths.append(item.resource_path)
	resource_paths.sort()
	var expected_resource_paths := PackedStringArray([
		"res://resources/config/materials/material_small_stone.tres",
		"res://resources/config/materials/material_water_bottle.tres",
		"res://resources/config/materials/material_wood.tres",
	])
	expected_resource_paths.sort()
	_expect(
		resource_paths == expected_resource_paths
		and EMERGENCY_REWARD.random_item_reward_count == 3
		and EMERGENCY_REWARD.shared_light_stone_reward == 1,
		"随机物资池必须仅含小石块、木头、水瓶，且每人3份、共享光石+1。"
	)
	var peer_ids: Array[int] = [1, 2]
	var first := REWARD_RESOLVER.build_emergency_collectible_offers(
		&"emergency-offer-contract",
		123456,
		peer_ids,
		EMERGENCY_REWARD,
		false,
		{1: "account:a", 2: "account:b"}
	)
	_expect(bool(first.get("resolved", false)), "紧急作战候选应成功生成。")
	if not bool(first.get("resolved", false)):
		return
	var offers_by_peer := first.get("offers_by_peer", {}) as Dictionary
	for peer_id in peer_ids:
		var rounds := offers_by_peer.get(peer_id, []) as Array
		_expect(rounds.size() == 2, "每名玩家必须生成两轮收藏品候选。")
		var seen_paths: Dictionary = {}
		for raw_round in rounds:
			var round_data := raw_round as Dictionary
			var rarity := int(round_data.get("rarity", -1))
			var paths := round_data.get("paths", []) as Array
			_expect(
				rarity in [
					PickupConfig.CollectibleRarity.COMMON,
					PickupConfig.CollectibleRarity.RARE,
					PickupConfig.CollectibleRarity.EPIC,
				]
				and paths.size() == 2,
				"每轮必须同属 COMMON/RARE/EPIC 之一且恰有两个候选。"
			)
			for raw_path in paths:
				var path := str(raw_path)
				var item := load(path) as PickupConfig
				_expect(
					item != null and int(item.collectible_rarity) == rarity,
					"同轮两个候选必须与该轮品质一致。"
				)
				_expect(not seen_paths.has(path), "两轮四个候选不得重复。")
				seen_paths[path] = true
		_expect(seen_paths.size() == 4, "两轮应得到四个不同收藏品候选。")
	var remapped := REWARD_RESOLVER.build_emergency_collectible_offers(
		&"emergency-offer-contract",
		123456,
		[99] as Array[int],
		EMERGENCY_REWARD,
		false,
		{99: "account:a"}
	)
	_expect(
		bool(remapped.get("resolved", false))
		and (remapped.get("offers_by_peer", {}) as Dictionary).get(99, [])
		== offers_by_peer.get(1, []),
		"候选必须由稳定身份而非临时 peer_id 确定。"
	)


func _test_two_round_atomic_settlement_and_snapshot() -> void:
	var run_state := CountingRunState.new()
	run_state.begin_new_run(&"weishidaier", false)
	var session := SESSION_SCRIPT.new()
	_expect(
		session.begin_authority(
			run_state,
			&"emergency-party-settlement",
			778899,
			[1, 2] as Array[int],
			EMERGENCY_REWARD,
			false,
			{1: "account:one", 2: "account:two"},
			{},
			{1: 120, 2: 340}
		),
		"两人紧急奖励选择会话应成功启动。"
	)
	var snapshot := session.export_state() as Dictionary
	var peer_one := _snapshot_peer(snapshot, 1)
	_expect(
		int(peer_one.get("current_round_index", -1)) == 0
		and (peer_one.get("current_offer_paths", []) as Array).size() == 2
		and is_equal_approx(
			float(peer_one.get("deadline_seconds_remaining", -1.0)),
			30.0
		)
		and (peer_one.get("selected_paths", []) as Array).is_empty()
		and not bool(peer_one.get("forfeited", true))
		and not bool(peer_one.get("complete", true)),
		"快照必须显式提供当前轮、候选、截止剩余时间、已选、弃权及完成状态。"
	)
	var remote := SESSION_SCRIPT.new()
	_expect(
		remote.reset_remote(EMERGENCY_REWARD)
		and remote.apply_snapshot(snapshot)
		and remote.get_peer_state(1) == session.get_peer_state(1),
		"奖励会话快照必须能在远端确定性重建。"
	)
	for _round_index in range(2):
		for peer_id in [1, 2]:
			var choice := session.submit_choice(
				peer_id,
				"emergency-party-settlement",
				int(session.get_peer_state(peer_id).get("round_index", -1)),
				0
			)
			_expect(bool(choice.get("accepted", false)), "空背包选择必须被接受。")
	_expect(session.is_ready_to_settle(), "全员完成两轮后会话应进入待结算阶段。")
	_expect(run_state.party_transaction_attempts == 0, "逐轮选择期间不得提前写奖励。")
	var result := session.complete_rewards() as Dictionary
	_expect(bool(result.get("resolved", false)), "完整紧急奖励应以原子事务结算。")
	_expect(run_state.party_transaction_attempts == 1, "全员奖励必须只提交一次 Party Economy CAS。")
	var extra_xirang := int(result.get("extra_xirang", -1))
	_expect(
		extra_xirang >= 1000
		and extra_xirang <= 2000
		and extra_xirang % 100 == 0
		and run_state.get_party_xirang_balance(1) == 120 + extra_xirang
		and run_state.get_party_xirang_balance(2) == 340 + extra_xirang,
		"同队玩家必须获得同一个1000至2000整百息壤结果。"
	)
	_expect(run_state.get_party_light_stone_amount() == 1, "全队共享光石必须只增加1。")
	var random_item := load(str(result.get("random_item_path", ""))) as PickupConfig
	for peer_id in [1, 2]:
		var peer_result := (
			result.get("results_by_peer", {}) as Dictionary
		).get(peer_id, {}) as Dictionary
		_expect(
			(peer_result.get("item_rewards", []) as Array).size() == 3,
			"每名在线玩家结算应包含两件收藏品及一项随机物资。"
		)
		_expect(
			random_item != null
			and run_state.get_inventory_item_total_for_peer(
				peer_id,
				random_item
			) == 3,
			"同一随机基础物资应向每名玩家发放3份。"
		)
	var replay := session.complete_rewards() as Dictionary
	_expect(
		replay == result and run_state.party_transaction_attempts == 1,
		"重复结算必须幂等，不能重复发奖或再次提交CAS。"
	)
	run_state.free()


func _test_timeout_and_inventory_retry() -> void:
	var timeout_state := CountingRunState.new()
	timeout_state.begin_new_run(&"weishidaier", false)
	var timeout_session := SESSION_SCRIPT.new()
	_expect(
		timeout_session.begin_authority(
			timeout_state,
			&"emergency-timeout",
			424242,
			[3] as Array[int],
			EMERGENCY_REWARD,
			false,
			{3: "account:timeout"},
			{},
			{3: 0}
		),
		"超时测试会话应启动。"
	)
	var first_offers := timeout_session.get_current_offer_paths(3)
	var expected_index := REWARD_RESOLVER.select_emergency_timeout_offer_index(
		&"emergency-timeout",
		424242,
		"account:timeout",
		0,
		EMERGENCY_REWARD
	)
	timeout_session.advance(30.0)
	var timed_state := timeout_session.get_peer_state(3)
	_expect(
		(timed_state.get("selected_paths", []) as Array).size() == 1
		and str((timed_state.get("selected_paths", []) as Array)[0])
		== first_offers[expected_index]
		and int(timed_state.get("round_index", -1)) == 1,
		"30秒超时必须按确定性随机项完成当前轮并推进下一轮。"
	)
	timeout_session.advance(30.0)
	_expect(timeout_session.is_ready_to_settle(), "第二轮超时后会话应可结算。")
	timeout_state.free()

	var filler := _get_non_stackable_common_collectible()
	_expect(filler != null, "满包重试测试需要不可堆叠收藏品。")
	if filler == null:
		return
	var full_state := CountingRunState.new()
	full_state.begin_new_run(&"weishidaier", false)
	for _slot_index in RunStateStore.INVENTORY_CAPACITY:
		_expect(full_state.try_add_item_for_peer(4, filler), "测试背包应可填满。")
	var full_session := SESSION_SCRIPT.new()
	_expect(
		full_session.begin_authority(
			full_state,
			&"emergency-full-bag",
			515151,
			[4] as Array[int],
			EMERGENCY_REWARD,
			false,
			{4: "account:full"},
			{},
			{4: 0}
		),
		"满包重试会话应启动。"
	)
	var rejected := full_session.submit_choice(4, "emergency-full-bag", 0, 0)
	_expect(
		not bool(rejected.get("accepted", true))
		and StringName(rejected.get("failure_reason", &""))
		== REWARD_RESOLVER.FAILURE_INVENTORY_FULL
		and int(full_session.get_peer_state(4).get("round_index", -1)) == 0
		and int(full_session.get_peer_state(4).get(
			"timeout_choice_index",
			-1
		)) == 0
		and is_zero_approx(float(full_session.get_peer_state(4).get(
			"remaining_seconds",
			-1.0
		)))
		and (full_session.get_peer_state(4).get("selected_paths", []) as Array).is_empty(),
		"满背包选择失败必须锁定该项、暂停倒计时并保持本轮待选。"
	)
	var alternate_rejected := full_session.submit_choice(
		4,
		"emergency-full-bag",
		0,
		1
	)
	_expect(
		not bool(alternate_rejected.get("accepted", true))
		and StringName(alternate_rejected.get("reason", &""))
		== SESSION_SCRIPT.REASON_TIMEOUT_CHOICE_LOCKED,
		"满包后不得改选或超时换成另一件收藏品。"
	)
	_expect(
		full_state.discard_item_for_peer(4, 0)
		and full_state.discard_item_for_peer(4, 1),
		"整理背包应能空出首轮所需容量。"
	)
	full_session.advance(1.0)
	_expect(
		int(full_session.get_peer_state(4).get("round_index", -1)) == 0,
		"整理背包后权威计时不得后台自动领奖，必须等待玩家显式重试。"
	)
	_expect(
		bool(full_session.submit_choice(4, "emergency-full-bag", 0, 0).get(
			"accepted",
			false
		)),
		"整理后必须可重试同一轮并成功。"
	)
	var second_rejected := full_session.submit_choice(
		4,
		"emergency-full-bag",
		1,
		0
	)
	_expect(
		not bool(second_rejected.get("accepted", true))
		and int(full_session.get_peer_state(4).get("round_index", -1)) == 1,
		"最终整批仍放不下时第二轮必须继续保持待选。"
	)
	_expect(full_state.discard_item_for_peer(4, 2), "应能再空出一个背包槽。")
	_expect(
		bool(full_session.submit_choice(4, "emergency-full-bag", 1, 0).get(
			"accepted",
			false
		))
		and bool(full_session.complete_rewards().get("resolved", false)),
		"再次整理后应完成第二轮并完整结算，不丢失奖励。"
	)
	full_state.free()


func _test_disconnect_remap_and_restore() -> void:
	var run_state := CountingRunState.new()
	run_state.begin_new_run(&"weishidaier", false)
	var session := SESSION_SCRIPT.new()
	_expect(
		session.begin_authority(
			run_state,
			&"emergency-disconnect",
			998877,
			[5, 6] as Array[int],
			EMERGENCY_REWARD,
			false,
			{5: "account:leaver", 6: "account:online"},
			{},
			{5: 50, 6: 60}
		),
		"断线测试会话应启动。"
	)
	_expect(
		bool(session.submit_choice(5, "emergency-disconnect", 0, 0).get(
			"accepted",
			false
		))
		and session.mark_peer_disconnected(5, "emergency-disconnect")
		and session.remap_disconnected_peer(5, 50),
		"断线玩家应立即结束选择，并可把奖励投递目标迁移到新peer。"
	)
	var remapped_state := session.get_peer_state(50)
	_expect(
		session.get_peer_state(5).is_empty()
		and bool(remapped_state.get("disconnected", false))
		and bool(remapped_state.get("completed", false))
		and (remapped_state.get("selected_paths", []) as Array).size() == 1
		and not bool(session.submit_choice(
			50,
			"emergency-disconnect",
			1,
			0
		).get("accepted", true)),
		"peer重映射必须保留身份、既有选择及弃权状态，且不得重新开放补选。"
	)
	for round_index in range(2):
		_expect(
			bool(session.submit_choice(
				6,
				"emergency-disconnect",
				round_index,
				0
			).get("accepted", false)),
			"在线玩家应完成两轮选择。"
		)
	_expect(session.is_ready_to_settle(), "断线弃权不应阻塞其余玩家完成奖励流程。")
	var snapshot := session.export_state() as Dictionary
	var remapped_wire := _snapshot_peer(snapshot, 50)
	_expect(
		bool(remapped_wire.get("forfeited", false))
		and bool(remapped_wire.get("complete", false)),
		"序列化快照必须保留重映射玩家的弃权与完成标记。"
	)
	var restored := SESSION_SCRIPT.new()
	_expect(
		restored.restore_authority(run_state, EMERGENCY_REWARD, snapshot),
		"权威会话必须可从序列化快照恢复。"
	)
	var result := restored.complete_rewards() as Dictionary
	var results_by_peer := result.get("results_by_peer", {}) as Dictionary
	_expect(
		bool(result.get("resolved", false))
		and results_by_peer.has(50)
		and not results_by_peer.has(5)
		and ((results_by_peer[50] as Dictionary).get("item_rewards", []) as Array).is_empty()
		and ((results_by_peer[6] as Dictionary).get("item_rewards", []) as Array).size()
		== 3
		and bool((results_by_peer[50] as Dictionary).get(
			"reward_selection_forfeited",
			false
		)),
		"断线玩家必须放弃所有尚未入包的物品，且不得补发剩余轮次。"
	)
	_expect(
		run_state.get_party_xirang_balance(50)
		== 50 + int(result.get("extra_xirang", 0)),
		"断线玩家放弃物品后仍必须获得本场同额息壤。"
	)
	_expect(
		run_state.get_party_light_stone_amount() == 1,
		"断线或阵亡原参战者不影响全队共享光石只发一次。"
	)
	run_state.free()


func _test_full_inventory_disconnect_does_not_block_party() -> void:
	var filler := _get_non_stackable_common_collectible()
	_expect(filler != null, "断线满包测试需要非堆叠普通收藏品。")
	if filler == null:
		return
	var run_state := CountingRunState.new()
	run_state.begin_new_run(&"weishidaier", false)
	run_state.ensure_multiplayer_peer_state(7)
	for slot_index in range(RunStateStore.INVENTORY_CAPACITY):
		_expect(
			run_state.try_add_item_for_peer(7, filler),
			"断线满包夹具应填充第%d槽。" % slot_index
		)
	var inventory_before := run_state.export_inventory_snapshot_for_peer(7)
	var revision_before := run_state.get_inventory_revision_for_peer(7)
	var session := SESSION_SCRIPT.new()
	_expect(
		session.begin_authority(
			run_state,
			&"emergency-full-disconnect",
			667788,
			[7, 8] as Array[int],
			EMERGENCY_REWARD,
			false,
			{7: "account:full-leaver", 8: "account:online"},
			{},
			{7: 700, 8: 800}
		),
		"断线满包测试会话应成功启动。"
	)
	var rejected := session.submit_choice(7, "emergency-full-disconnect", 0, 0)
	_expect(
		not bool(rejected.get("accepted", true))
		and StringName(rejected.get("failure_reason", &""))
		== REWARD_RESOLVER.FAILURE_INVENTORY_FULL
		and session.mark_peer_disconnected(7, "emergency-full-disconnect"),
		"满包选择被锁定后，玩家断线必须立即结束选择。"
	)
	for round_index in range(2):
		_expect(
			bool(session.submit_choice(
				8,
				"emergency-full-disconnect",
				round_index,
				0
			).get("accepted", false)),
			"在线玩家应完成第%d轮选择。" % (round_index + 1)
		)
	var light_before := run_state.get_party_light_stone_amount()
	var light_revision_before := run_state.get_party_light_stone_ledger_revision()
	var result := session.complete_rewards() as Dictionary
	var results_by_peer := result.get("results_by_peer", {}) as Dictionary
	var leaver_result := results_by_peer.get(7, {}) as Dictionary
	var online_result := results_by_peer.get(8, {}) as Dictionary
	_expect(
		bool(result.get("resolved", false))
		and (leaver_result.get("item_rewards", []) as Array).is_empty()
		and bool(leaver_result.get("reward_selection_forfeited", false))
		and (online_result.get("item_rewards", []) as Array).size() == 3,
		"断线满包不得阻塞结算；断线者无物品，在线者获得完整奖励。"
	)
	_expect(
		run_state.export_inventory_snapshot_for_peer(7) == inventory_before
		and run_state.get_inventory_revision_for_peer(7) == revision_before,
		"断线者背包内容与 revision 必须保持不变。"
	)
	_expect(
		run_state.get_party_xirang_balance(7)
		== 700 + int(result.get("extra_xirang", 0))
		and run_state.get_party_light_stone_amount() == light_before + 1
		and run_state.get_party_light_stone_ledger_revision()
		== light_revision_before + 1,
		"断线者仍应获得息壤，并且共享光石只增加一次。"
	)
	var random_item := load(str(result.get("random_item_path", ""))) as PickupConfig
	_expect(
		random_item != null
		and run_state.get_inventory_item_total_for_peer(8, random_item) == 3,
		"在线玩家必须获得全队抽中的基础物资3份。"
	)
	run_state.free()


func _snapshot_peer(snapshot: Dictionary, peer_id: int) -> Dictionary:
	for raw_participant in snapshot.get("participants", []) as Array:
		var participant := raw_participant as Dictionary
		if int(participant.get("peer_id", -1)) == peer_id:
			return participant
	return {}


func _get_non_stackable_common_collectible() -> PickupConfig:
	for item in CollectibleRegistry.get_by_rarity(
		PickupConfig.CollectibleRarity.COMMON
	):
		if item.can_store_in_inventory and not item.stackable:
			return item
	return null


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
