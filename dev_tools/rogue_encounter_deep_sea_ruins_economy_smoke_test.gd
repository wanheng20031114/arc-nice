extends SceneTree

const BASKETBALL := preload(
	"res://resources/config/collectibles/collectible_basketball.tres"
)

var _failures: PackedStringArray = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_ring_pool_contract()
	_test_light_stone_reward_and_idempotency()
	_test_independent_deterministic_ring_rewards()
	_test_ring_rolls_allow_duplicates()
	_test_full_inventory_discards_only_for_that_peer()
	_test_all_full_inventories_leave_party_economy_unchanged()
	_test_stale_revisions_reject_whole_transactions()
	_test_remote_snapshot_and_peer_migration_keep_personal_attribution()
	if _failures.is_empty():
		print("ROGUE_ENCOUNTER_DEEP_SEA_RUINS_ECONOMY_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in _failures:
		push_error(failure)
	quit(1)


func _test_ring_pool_contract() -> void:
	var pool := CollectibleRegistry.get_ring_random_pool()
	var actual_paths: Array[String] = []
	for item in pool:
		actual_paths.append(item.resource_path if item != null else "")
	_expect(
		pool.size() == 8
		and actual_paths == CollectibleRegistry.RING_CONFIG_PATHS,
		"戒指奖励池必须按显式稳定顺序精确包含8件配置。"
	)
	for item in pool:
		_expect(
			item != null
			and item.pickup_type == PickupConfig.PickupType.COLLECTIBLE
			and item.can_store_in_inventory
			and item.collectible_design_id.ends_with("_ring"),
			"戒指奖励池不得混入非戒指或不可入背包的配置。"
		)


func _test_light_stone_reward_and_idempotency() -> void:
	var peers: Array[int] = [11, 12]
	var run_state := _new_run_state(peers)
	_expect(run_state.set_party_light_stone_amount(4), "应能设置共享光石基线。")
	var revision_before := run_state.get_party_light_stone_ledger_revision()
	var economy := RogueEncounterEconomyCoordinator.new()
	economy.configure(run_state)
	var availability := economy.get_option_availability(
		RogueEncounterEconomyCoordinator.ENCOUNTER_DEEP_SEA_RUINS,
		peers
	)
	_expect(
		bool(availability.get(String(
			RogueEncounterEconomyCoordinator.OPTION_TAKE_CRYSTALS
		), false))
		and bool(availability.get(String(
			RogueEncounterEconomyCoordinator.OPTION_TAKE_RINGS
		), false)),
		"深海遗迹两项奖励都应始终可投票。"
	)
	var result := economy.resolve_encounter(
		RogueEncounterEconomyCoordinator.ENCOUNTER_DEEP_SEA_RUINS,
		RogueEncounterEconomyCoordinator.OPTION_TAKE_CRYSTALS,
		1112,
		peers,
		"deep-sea-light-stones"
	)
	_expect(
		bool(result.get("resolved", false))
		and StringName(result.get("result_code", &""))
		== RogueEncounterEconomyCoordinator.RESULT_DEEP_SEA_LIGHT_STONES
		and int(result.get("light_stone_delta", 0)) == 2
		and int(result.get("light_stone_amount", -1)) == 6,
		"拿走水晶应返回共享光石+2的明确结果。"
	)
	_expect(
		run_state.get_party_light_stone_amount() == 6
		and run_state.get_party_light_stone_ledger_revision()
		== revision_before + 1,
		"拿走水晶必须只推进一次共享光石账本revision。"
	)
	var replayed := economy.resolve_deep_sea_ruins(
		RogueEncounterEconomyCoordinator.OPTION_TAKE_RINGS,
		9999,
		peers,
		"deep-sea-light-stones"
	)
	_expect(replayed == result, "同一深海遗迹occurrence必须返回首次结算结果。")
	_expect(
		run_state.get_party_light_stone_amount() == 6
		and run_state.get_party_light_stone_ledger_revision()
		== revision_before + 1,
		"occurrence重放不得再次增加光石或改为另一奖励。"
	)
	economy.free()
	run_state.free()


func _test_independent_deterministic_ring_rewards() -> void:
	var peers: Array[int] = [21, 22]
	var seed := _find_ring_seed(peers[0], peers[1], false)
	_expect(seed >= 0, "应能找到证明逐玩家独立抽取的戒指seed。")
	if seed < 0:
		return
	var run_state := _new_run_state(peers)
	var revisions_before := {
		21: run_state.get_inventory_revision_for_peer(21),
		22: run_state.get_inventory_revision_for_peer(22),
	}
	var economy := RogueEncounterEconomyCoordinator.new()
	economy.configure(run_state)
	var result := economy.resolve_deep_sea_ruins(
		RogueEncounterEconomyCoordinator.OPTION_TAKE_RINGS,
		seed,
		peers,
		"deep-sea-independent-rings"
	)
	var rewards := result.get("collectible_rewards", []) as Array
	_expect(
		bool(result.get("resolved", false))
		and StringName(result.get("result_code", &""))
		== RogueEncounterEconomyCoordinator.RESULT_DEEP_SEA_RINGS
		and rewards.size() == peers.size(),
		"戒指选项必须为每个有效玩家生成一条奖励记录。"
	)
	var rolled_paths: Array[String] = []
	for raw_reward in rewards:
		var reward := raw_reward as Dictionary
		var peer_id := int(reward.get("peer_id", -1))
		var expected_path := _expected_ring_path(seed, peer_id)
		var rolled_path := str(reward.get("rolled_path", ""))
		rolled_paths.append(rolled_path)
		_expect(
			rolled_path == expected_path
			and bool(reward.get("granted", false))
			and (reward.get("granted_paths", []) as Array) == [expected_path]
			and _count_rings_for_peer(run_state, peer_id) == 1
			and run_state.get_inventory_revision_for_peer(peer_id)
			== int(revisions_before[peer_id]) + 1,
			"空背包玩家必须获得由node seed与peer ID确定的唯一一件戒指。"
		)
	_expect(
		rolled_paths.size() == 2 and rolled_paths[0] != rolled_paths[1],
		"指定seed应证明两个玩家使用彼此独立的随机salt。"
	)
	var snapshot_after := run_state.export_party_economy_snapshot(
		PackedInt32Array(peers)
	)
	var replayed := economy.resolve_deep_sea_ruins(
		RogueEncounterEconomyCoordinator.OPTION_TAKE_RINGS,
		seed,
		[22, 21],
		"deep-sea-independent-rings"
	)
	_expect(
		replayed == result
		and run_state.export_party_economy_snapshot(PackedInt32Array(peers))
		== snapshot_after,
		"戒指结算重放不得受玩家输入顺序影响或重复写入背包。"
	)
	economy.free()
	run_state.free()


func _test_ring_rolls_allow_duplicates() -> void:
	var peers: Array[int] = [23, 24]
	var seed := _find_ring_seed(peers[0], peers[1], true)
	_expect(seed >= 0, "应能找到两名玩家抽中同一戒指的确定性seed。")
	if seed < 0:
		return
	var run_state := _new_run_state(peers)
	var economy := RogueEncounterEconomyCoordinator.new()
	economy.configure(run_state)
	var result := economy.resolve_deep_sea_ruins(
		RogueEncounterEconomyCoordinator.OPTION_TAKE_RINGS,
		seed,
		peers,
		"deep-sea-duplicate-rings"
	)
	var rewards := result.get("collectible_rewards", []) as Array
	_expect(
		rewards.size() == 2
		and str((rewards[0] as Dictionary).get("rolled_path", ""))
		== str((rewards[1] as Dictionary).get("rolled_path", ""))
		and bool((rewards[0] as Dictionary).get("granted", false))
		and bool((rewards[1] as Dictionary).get("granted", false)),
		"逐玩家随机允许不同玩家各自获得同一种戒指。"
	)
	economy.free()
	run_state.free()


func _test_full_inventory_discards_only_for_that_peer() -> void:
	var peers: Array[int] = [31, 32]
	var run_state := _new_run_state(peers)
	_fill_inventory(run_state, 31)
	var full_revision_before := run_state.get_inventory_revision_for_peer(31)
	var open_revision_before := run_state.get_inventory_revision_for_peer(32)
	var economy := RogueEncounterEconomyCoordinator.new()
	economy.configure(run_state)
	var result := economy.resolve_deep_sea_ruins(
		RogueEncounterEconomyCoordinator.OPTION_TAKE_RINGS,
		3132,
		peers,
		"deep-sea-partial-capacity"
	)
	var rewards_by_peer := _index_rewards_by_peer(
		result.get("collectible_rewards", []) as Array
	)
	var discarded := rewards_by_peer.get(31, {}) as Dictionary
	var granted := rewards_by_peer.get(32, {}) as Dictionary
	_expect(
		not bool(discarded.get("granted", true))
		and str(discarded.get("failure_reason", "")) == "inventory_full"
		and int(discarded.get("discarded_count", 0)) == 1
		and run_state.get_inventory_revision_for_peer(31) == full_revision_before,
		"满背包玩家应丢失自己的戒指且不得推进背包revision。"
	)
	_expect(
		bool(granted.get("granted", false))
		and _count_rings_for_peer(run_state, 32) == 1
		and run_state.get_inventory_revision_for_peer(32)
		== open_revision_before + 1,
		"一名玩家满包不得阻塞其他玩家领取戒指。"
	)
	economy.free()
	run_state.free()


func _test_all_full_inventories_leave_party_economy_unchanged() -> void:
	var peers: Array[int] = [41, 42]
	var run_state := _new_run_state(peers)
	_fill_inventory(run_state, 41)
	_fill_inventory(run_state, 42)
	var before := run_state.export_party_economy_snapshot(PackedInt32Array(peers))
	var economy := RogueEncounterEconomyCoordinator.new()
	economy.configure(run_state)
	var result := economy.resolve_deep_sea_ruins(
		RogueEncounterEconomyCoordinator.OPTION_TAKE_RINGS,
		4142,
		peers,
		"deep-sea-all-full"
	)
	var rewards := result.get("collectible_rewards", []) as Array
	var all_discarded := rewards.size() == peers.size()
	for raw_reward in rewards:
		var reward := raw_reward as Dictionary
		all_discarded = (
			all_discarded
			and not bool(reward.get("granted", true))
			and int(reward.get("discarded_count", 0)) == 1
		)
	_expect(
		bool(result.get("resolved", false))
		and not bool(result.get("reward_granted", true))
		and all_discarded,
		"全员满包时遭遇仍应完成，并记录每人的戒指均已丢失。"
	)
	_expect(
		run_state.export_party_economy_snapshot(PackedInt32Array(peers)) == before,
		"全员满包丢失奖励不得推进任何Party Economy账本。"
	)
	var replayed := economy.resolve_deep_sea_ruins(
		RogueEncounterEconomyCoordinator.OPTION_TAKE_RINGS,
		4142,
		peers,
		"deep-sea-all-full"
	)
	_expect(replayed == result, "全员满包结果也必须按occurrence幂等缓存。")
	economy.free()
	run_state.free()


func _test_stale_revisions_reject_whole_transactions() -> void:
	var light_state := _new_run_state([51])
	var light_snapshot := light_state.export_party_economy_snapshot(
		PackedInt32Array([51])
	)
	var stale_light := (
		light_snapshot["light_stone_ledger"] as Dictionary
	).duplicate(true)
	var expected_light_revision := int(stale_light["revision"])
	stale_light["revision"] = expected_light_revision + 1
	stale_light["amount"] = int(stale_light["amount"]) + 2
	var light_inventory := (
		(light_snapshot["inventories"] as Array)[0] as Dictionary
	)
	var expected_light_inventories := {
		51: int(light_inventory["revision"]),
	}
	_expect(
		light_state.try_change_party_light_stone_amount(
			1,
			expected_light_revision
		),
		"光石陈旧测试应先提交一笔竞争变更。"
	)
	var stale_light_accepted := light_state.apply_authoritative_party_transaction(
		light_snapshot,
		int((light_snapshot["warehouse_ledger"] as Dictionary)["revision"]),
		expected_light_inventories,
		-1,
		{},
		-1,
		{},
		expected_light_revision,
		stale_light
	)
	_expect(
		not stale_light_accepted
		and light_state.get_party_light_stone_amount() == 1
		and light_state.get_party_light_stone_ledger_revision()
		== expected_light_revision + 1,
		"共享光石revision陈旧时，深海+2候选事务必须完整拒绝。"
	)
	light_state.free()

	var ring_peers: Array[int] = [52, 53]
	var ring_state := _new_run_state(ring_peers)
	var ring_snapshot := ring_state.export_party_economy_snapshot(
		PackedInt32Array(ring_peers)
	)
	var next_ring_snapshot := ring_snapshot.duplicate(true)
	var expected_ring_inventories: Dictionary = {}
	var ring_item := CollectibleRegistry.get_ring_random_pool()[0]
	for raw_inventory in next_ring_snapshot["inventories"] as Array:
		var inventory := raw_inventory as Dictionary
		var peer_id := int(inventory["peer_id"])
		var expected_revision := int(inventory["revision"])
		expected_ring_inventories[peer_id] = expected_revision
		var first_slot := (inventory["slots"] as Array)[0] as Dictionary
		first_slot["config_path"] = ring_item.resource_path
		first_slot["stack_count"] = 1
		inventory["revision"] = expected_revision + 1
	_expect(
		ring_state.try_add_item_for_peer(52, BASKETBALL),
		"戒指陈旧测试应先推进玩家52的背包revision。"
	)
	var stale_ring_accepted := ring_state.apply_authoritative_party_transaction(
		next_ring_snapshot,
		int((ring_snapshot["warehouse_ledger"] as Dictionary)["revision"]),
		expected_ring_inventories
	)
	_expect(
		not stale_ring_accepted
		and _count_rings_for_peer(ring_state, 52) == 0
		and _count_rings_for_peer(ring_state, 53) == 0
		and ring_state.get_inventory_item_total_for_peer(52, BASKETBALL) == 1,
		"任一玩家背包revision陈旧时，多人戒指批次不得向其他玩家部分提交。"
	)
	ring_state.free()


func _test_remote_snapshot_and_peer_migration_keep_personal_attribution() -> void:
	var old_peer_id := 61
	var new_peer_id := 69
	var stable_peer_id := 62
	var initial_peers: Array[int] = [old_peer_id, stable_peer_id]
	var host_state := _new_run_state(initial_peers)
	var host_economy := RogueEncounterEconomyCoordinator.new()
	host_economy.configure(host_state)
	var original_result := host_economy.resolve_deep_sea_ruins(
		RogueEncounterEconomyCoordinator.OPTION_TAKE_RINGS,
		6162,
		initial_peers,
		"deep-sea-migrated-rings"
	)
	var old_reward := _index_rewards_by_peer(
		original_result.get("collectible_rewards", []) as Array
	).get(old_peer_id, {}) as Dictionary
	var old_ring_path := str(old_reward.get("rolled_path", ""))
	var remap_result := host_state.remap_multiplayer_peer_state(
		old_peer_id,
		new_peer_id,
		1
	)
	_expect(
		remap_result == RunStateStore.MultiplayerPeerRemapResult.MIGRATED,
		"远端快照测试必须先原子迁移RunState玩家身份。"
	)
	_expect(
		host_economy.migrate_peer_references(old_peer_id, new_peer_id),
		"已缓存的深海戒指结果必须随重连身份迁移。"
	)
	var migrated_result := host_economy.migrate_result_peer_references(
		original_result,
		old_peer_id,
		new_peer_id
	)
	var migrated_details := (
		migrated_result.get("personal_detail_by_peer", {}) as Dictionary
	)
	var migrated_rewards := _index_rewards_by_peer(
		migrated_result.get("collectible_rewards", []) as Array
	)
	_expect(
		migrated_details.has(new_peer_id)
		and not migrated_details.has(old_peer_id)
		and migrated_rewards.has(new_peer_id)
		and not migrated_rewards.has(old_peer_id)
		and str((migrated_rewards[new_peer_id] as Dictionary).get(
			"rolled_path",
			""
		)) == old_ring_path
		and _count_rings_for_peer(host_state, new_peer_id) == 1,
		"peer迁移必须同时保留个人结果文案、奖励记录与实际戒指归属。"
	)
	var migrated_peers: Array[int] = [stable_peer_id, new_peer_id]
	var host_snapshot := host_economy.export_snapshot(migrated_peers)
	var settled_result := _get_settled_result(
		host_snapshot,
		"deep-sea-migrated-rings"
	)
	var settled_rewards := _index_rewards_by_peer(
		settled_result.get("collectible_rewards", []) as Array
	)
	_expect(
		settled_rewards.has(new_peer_id)
		and not settled_rewards.has(old_peer_id)
		and (settled_result.get("personal_detail_by_peer", {}) as Dictionary).has(
			new_peer_id
		),
		"权威经济快照中的缓存结果必须只引用迁移后的peer ID。"
	)

	var remote_state := _new_run_state(migrated_peers)
	var remote_economy := RogueEncounterEconomyCoordinator.new()
	remote_economy.configure(remote_state)
	_expect(
		remote_economy.apply_remote_snapshot(host_snapshot),
		"客户端应能原子应用包含戒指归属的权威经济快照。"
	)
	var remote_snapshot := remote_economy.export_snapshot(migrated_peers)
	var remote_result := _get_settled_result(
		remote_snapshot,
		"deep-sea-migrated-rings"
	)
	var remote_rewards := _index_rewards_by_peer(
		remote_result.get("collectible_rewards", []) as Array
	)
	_expect(
		remote_snapshot == host_snapshot
		and remote_rewards.has(new_peer_id)
		and not remote_rewards.has(old_peer_id)
		and str((remote_rewards[new_peer_id] as Dictionary).get(
			"rolled_path",
			""
		)) == old_ring_path
		and (remote_result.get("personal_detail_by_peer", {}) as Dictionary).has(
			new_peer_id
		)
		and _count_rings_for_peer(remote_state, new_peer_id) == 1,
		"远端快照恢复后必须无损保留迁移后的个人奖励归属。"
	)
	remote_economy.free()
	remote_state.free()
	host_economy.free()
	host_state.free()


func _expected_ring_path(seed: int, peer_id: int) -> String:
	var pool := CollectibleRegistry.get_ring_random_pool()
	return pool[RogueEncounterRandom.choose_index(
		seed,
		StringName("deep_sea_ruins_ring|peer:%d" % peer_id),
		pool.size()
	)].resource_path


func _find_ring_seed(
	first_peer_id: int,
	second_peer_id: int,
	expect_same: bool
) -> int:
	var pool_size := CollectibleRegistry.get_ring_random_pool().size()
	for seed in range(1, 10000):
		var first_index := RogueEncounterRandom.choose_index(
			seed,
			StringName("deep_sea_ruins_ring|peer:%d" % first_peer_id),
			pool_size
		)
		var second_index := RogueEncounterRandom.choose_index(
			seed,
			StringName("deep_sea_ruins_ring|peer:%d" % second_peer_id),
			pool_size
		)
		if (first_index == second_index) == expect_same:
			return seed
	return -1


func _new_run_state(peer_ids: Array[int]) -> RunStateStore:
	var run_state := RunStateStore.new()
	run_state.begin_new_run(&"weishidaier", false)
	for peer_id in peer_ids:
		run_state.register_multiplayer_peer_state(peer_id)
	return run_state


func _fill_inventory(run_state: RunStateStore, peer_id: int) -> void:
	for _slot_index in RunStateStore.INVENTORY_CAPACITY:
		_expect(
			run_state.try_add_item_for_peer(peer_id, BASKETBALL),
			"测试背包应能被不可堆叠篮球填满。"
		)


func _count_rings_for_peer(run_state: RunStateStore, peer_id: int) -> int:
	var result := 0
	for slot_index in RunStateStore.INVENTORY_CAPACITY:
		var item := run_state.get_item_for_peer(peer_id, slot_index)
		if item != null and CollectibleRegistry.RING_CONFIG_PATHS.has(
			item.resource_path
		):
			result += 1
	return result


func _index_rewards_by_peer(rewards: Array) -> Dictionary:
	var result: Dictionary = {}
	for raw_reward in rewards:
		var reward := raw_reward as Dictionary
		result[int(reward.get("peer_id", -1))] = reward
	return result


func _get_settled_result(snapshot: Dictionary, occurrence_key: String) -> Dictionary:
	for raw_entry in snapshot.get("settled_occurrences", []) as Array:
		var entry := raw_entry as Dictionary
		if str(entry.get("occurrence_key", "")) == occurrence_key:
			return (entry.get("result", {}) as Dictionary).duplicate(true)
	return {}


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
