extends SceneTree

const WATER := preload("res://resources/config/materials/material_water_bottle.tres")
const GEL := preload("res://resources/config/materials/material_gel.tres")
const BASKETBALL := preload(
	"res://resources/config/collectibles/collectible_basketball.tres"
)

var _failures: PackedStringArray = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_economy_snapshot_schema()
	_test_rarity_capped_pool()
	_test_help_grants_three_collectibles_to_each_peer()
	_test_help_uses_capacity_freed_by_payment_and_discards_overflow()
	_test_help_grants_one_shared_xirang_tier_idempotently()
	_test_kick_prefers_the_selected_player_inventory()
	_test_kick_falls_back_whole_batch_to_warehouse()
	_test_kick_discards_whole_batch_when_every_store_is_full()
	_test_leave_is_idempotent_and_does_not_mutate_economy()
	if _failures.is_empty():
		print("ROGUE_ENCOUNTER_SLIME_ECONOMY_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in _failures:
		push_error(failure)
	quit(1)


func _test_economy_snapshot_schema() -> void:
	var run_state := _new_run_state([1])
	var economy := RogueEncounterEconomyCoordinator.new()
	economy.configure(run_state)
	var snapshot := economy.export_snapshot([1])
	_expect(
		int(snapshot.get("schema_version", -1))
		== RogueEncounterEconomyCoordinator.SCHEMA_VERSION
		and RogueEncounterEconomyCoordinator.SCHEMA_VERSION == 3,
		"新增队伍状态账本后，遭遇经济外层快照必须使用schema 3。"
	)
	_expect(
		int((snapshot.get("party_economy", {}) as Dictionary).get(
			"schema_version",
			-1
		)) == RunStateStore.PARTY_ECONOMY_SCHEMA_VERSION,
		"遭遇经济快照应嵌入当前版本的队伍经济账本。"
	)
	economy.free()
	run_state.free()


func _test_rarity_capped_pool() -> void:
	var pool := CollectibleRegistry.get_standard_random_pool_up_to(
		PickupConfig.CollectibleRarity.RARE
	)
	var expected_size := (
		CollectibleRegistry.get_by_rarity(PickupConfig.CollectibleRarity.COMMON).size()
		+ CollectibleRegistry.get_by_rarity(PickupConfig.CollectibleRarity.RARE).size()
	)
	_expect(
		not pool.is_empty() and pool.size() == expected_size,
		"史莱姆奖励池应准确包含全部普通与稀有收藏品。"
	)
	for item in pool:
		_expect(
			item != null
			and item.pickup_type == PickupConfig.PickupType.COLLECTIBLE
			and int(item.collectible_rarity) <= PickupConfig.CollectibleRarity.RARE,
			"史莱姆收藏品池不得混入史诗、传说或特殊收藏品。"
		)


func _test_help_grants_three_collectibles_to_each_peer() -> void:
	var run_state := _new_run_state([11, 12])
	_expect(
		run_state.replace_shared_warehouse_snapshots([
			_make_warehouse_snapshot(101, 4, WATER.resource_path, 10),
		]),
		"收藏品回礼测试应准备10瓶仓库水。"
	)
	var economy := RogueEncounterEconomyCoordinator.new()
	economy.configure(run_state)
	var seed := _find_help_seed(true)
	var result := economy.resolve_encounter(
		RogueEncounterEconomyCoordinator.ENCOUNTER_SLIME_TALKERS,
		RogueEncounterEconomyCoordinator.OPTION_HELP_SLIMES,
		seed,
		[11, 12],
		"slime-collectibles-each"
	)
	_expect(
		StringName(result.get("result_code", &""))
		== RogueEncounterEconomyCoordinator.RESULT_SLIME_HELP_COLLECTIBLES,
		"帮助史莱姆的收藏品分支应返回明确结果。"
	)
	_expect(
		run_state.get_party_item_total(WATER, PackedInt32Array([11, 12])) == 0,
		"收藏品回礼必须在同一事务中扣除10瓶水。"
	)
	var rewards := result.get("collectible_rewards", []) as Array
	_expect(rewards.size() == 2, "每个有效玩家都应有独立收藏品回礼记录。")
	for raw_reward in rewards:
		var reward := raw_reward as Dictionary
		var peer_id := int(reward.get("peer_id", -1))
		var granted := reward.get("granted_paths", []) as Array
		_expect(
			granted.size() == 3
			and int(reward.get("discarded_count", -1)) == 0,
			"空背包玩家应各自完整获得3件收藏品。"
		)
		_expect(
			_count_collectibles_for_peer(run_state, peer_id) == 3,
			"收藏品路径记录必须与权威背包一致。"
		)
	economy.free()
	run_state.free()


func _test_help_uses_capacity_freed_by_payment_and_discards_overflow() -> void:
	var peer_id := 21
	var run_state := _new_run_state([peer_id])
	for _slot_index in RunStateStore.INVENTORY_CAPACITY - 1:
		_expect(
			run_state.try_add_item_for_peer(peer_id, BASKETBALL),
			"溢出测试应以篮球占满前19格。"
		)
	_expect(
		run_state.try_add_item_count_for_peer(peer_id, WATER, 10),
		"第20格应能放入10瓶付款用水。"
	)
	var revision_before := run_state.get_inventory_revision_for_peer(peer_id)
	var economy := RogueEncounterEconomyCoordinator.new()
	economy.configure(run_state)
	var result := economy.resolve_slime_talkers(
		RogueEncounterEconomyCoordinator.OPTION_HELP_SLIMES,
		_find_help_seed(true),
		[peer_id],
		"slime-overflow-after-payment"
	)
	var reward := (result.get("collectible_rewards", []) as Array)[0] as Dictionary
	_expect(
		(reward.get("granted_paths", []) as Array).size() == 1
		and int(reward.get("discarded_count", -1)) == 2,
		"扣水腾出的唯一空格应接收1件回礼，其余2件直接作废。"
	)
	_expect(
		run_state.get_inventory_revision_for_peer(peer_id) == revision_before + 1,
		"同一玩家扣水并收取回礼时背包revision只能前进一次。"
	)
	economy.free()
	run_state.free()


func _test_help_grants_one_shared_xirang_tier_idempotently() -> void:
	var peers: Array[int] = [31, 32]
	var run_state := _new_run_state(peers)
	_expect(run_state.set_party_xirang_balance(31, 100), "应能设置玩家31息壤基线。")
	_expect(run_state.set_party_xirang_balance(32, 250), "应能设置玩家32息壤基线。")
	_expect(
		run_state.replace_shared_warehouse_snapshots([
			_make_warehouse_snapshot(301, 2, WATER.resource_path, 10),
		]),
		"息壤回礼测试应准备10瓶仓库水。"
	)
	var economy := RogueEncounterEconomyCoordinator.new()
	economy.configure(run_state)
	var seed := _find_help_seed(false)
	var result := economy.resolve_slime_talkers(
		RogueEncounterEconomyCoordinator.OPTION_HELP_SLIMES,
		seed,
		peers,
		"slime-xirang-idempotent"
	)
	var amount := int(result.get("xirang_reward_each", 0))
	_expect(
		StringName(result.get("result_code", &""))
		== RogueEncounterEconomyCoordinator.RESULT_SLIME_HELP_XIRANG
		and RogueEncounterEconomyCoordinator.SLIME_XIRANG_REWARD_AMOUNTS.has(amount),
		"息壤回礼应只使用四个等概率配置档位。"
	)
	_expect(
		run_state.get_party_xirang_balance(31) == 100 + amount
		and run_state.get_party_xirang_balance(32) == 250 + amount,
		"所有有效玩家应获得同一次抽取的相同息壤数量。"
	)
	var replayed := economy.resolve_slime_talkers(
		RogueEncounterEconomyCoordinator.OPTION_HELP_SLIMES,
		seed,
		peers,
		"slime-xirang-idempotent"
	)
	_expect(replayed == result, "同一史莱姆occurrence重放应返回首次结果。")
	_expect(
		run_state.get_party_xirang_balance(31) == 100 + amount
		and run_state.get_party_xirang_balance(32) == 250 + amount,
		"重放不得再次发放息壤。"
	)
	economy.free()
	run_state.free()


func _test_kick_prefers_the_selected_player_inventory() -> void:
	var peers: Array[int] = [41, 42]
	var seed := 4142
	var receiver := peers[RogueEncounterRandom.choose_index(
		seed,
		&"slime_gel_receiver",
		peers.size()
	)]
	var run_state := _new_run_state(peers)
	var economy := RogueEncounterEconomyCoordinator.new()
	economy.configure(run_state)
	var result := economy.resolve_slime_talkers(
		RogueEncounterEconomyCoordinator.OPTION_KICK_SLIMES,
		seed,
		peers,
		"slime-gel-inventory"
	)
	_expect(
		int(result.get("receiver_peer_id", -1)) == receiver
		and str(result.get("gel_destination", "")) == "inventory"
		and run_state.get_inventory_item_total_for_peer(receiver, GEL) == 10,
		"踢死史莱姆应将完整10份凝胶交给确定性随机玩家。"
	)
	economy.free()
	run_state.free()


func _test_kick_falls_back_whole_batch_to_warehouse() -> void:
	var peers: Array[int] = [51, 52]
	var seed := 5152
	var receiver := peers[RogueEncounterRandom.choose_index(
		seed,
		&"slime_gel_receiver",
		peers.size()
	)]
	var run_state := _new_run_state(peers)
	_fill_inventory(run_state, receiver)
	_expect(
		run_state.replace_shared_warehouse_snapshots([
			_make_warehouse_snapshot(501, 7, "", 0),
		]),
		"仓库回退测试应准备空仓库。"
	)
	var economy := RogueEncounterEconomyCoordinator.new()
	economy.configure(run_state)
	var result := economy.resolve_slime_talkers(
		RogueEncounterEconomyCoordinator.OPTION_KICK_SLIMES,
		seed,
		peers,
		"slime-gel-warehouse"
	)
	var warehouse := (
		(run_state.export_shared_warehouse_ledger()["warehouses"] as Array)[0]
		as Dictionary
	)
	_expect(
		str(result.get("gel_destination", "")) == "warehouse"
		and run_state.get_shared_warehouse_item_total(GEL) == 10
		and run_state.get_inventory_item_total_for_peer(receiver, GEL) == 0,
		"随机玩家背包不足时，完整10份凝胶应回退共享仓库。"
	)
	_expect(
		int(warehouse.get("revision", -1)) == 8,
		"接收凝胶的仓库revision只能前进一次。"
	)
	economy.free()
	run_state.free()


func _test_kick_discards_whole_batch_when_every_store_is_full() -> void:
	var peers: Array[int] = [61]
	var run_state := _new_run_state(peers)
	_fill_inventory(run_state, 61)
	var before := run_state.export_party_economy_snapshot(PackedInt32Array(peers))
	var economy := RogueEncounterEconomyCoordinator.new()
	economy.configure(run_state)
	var result := economy.resolve_slime_talkers(
		RogueEncounterEconomyCoordinator.OPTION_KICK_SLIMES,
		6161,
		peers,
		"slime-gel-discarded"
	)
	_expect(
		str(result.get("gel_destination", "")) == "discarded"
		and not bool(result.get("reward_granted", true)),
		"玩家与仓库都无法完整容纳10份凝胶时应整批丢弃。"
	)
	_expect(
		run_state.export_party_economy_snapshot(PackedInt32Array(peers)) == before,
		"丢弃凝胶不得推进任何库存、仓库或息壤revision。"
	)
	economy.free()
	run_state.free()


func _test_leave_is_idempotent_and_does_not_mutate_economy() -> void:
	var peers: Array[int] = [71]
	var run_state := _new_run_state(peers)
	var before := run_state.export_party_economy_snapshot(PackedInt32Array(peers))
	var economy := RogueEncounterEconomyCoordinator.new()
	economy.configure(run_state)
	var first := economy.resolve_encounter(
		RogueEncounterEconomyCoordinator.ENCOUNTER_SLIME_TALKERS,
		RogueEncounterEconomyCoordinator.OPTION_LEAVE_SLIMES,
		7171,
		peers,
		"slime-leave"
	)
	var replayed := economy.resolve_encounter(
		RogueEncounterEconomyCoordinator.ENCOUNTER_SLIME_TALKERS,
		RogueEncounterEconomyCoordinator.OPTION_LEAVE_SLIMES,
		7171,
		peers,
		"slime-leave"
	)
	_expect(
		StringName(first.get("result_code", &""))
		== RogueEncounterEconomyCoordinator.RESULT_SLIME_LEFT
		and replayed == first,
		"离开选项应完成节点并缓存幂等结果。"
	)
	_expect(
		run_state.export_party_economy_snapshot(PackedInt32Array(peers)) == before,
		"离开选项不得改变任何经济状态。"
	)
	economy.free()
	run_state.free()


func _find_help_seed(expect_collectibles: bool) -> int:
	for seed in range(1, 10000):
		if RogueEncounterRandom.succeeds(
			seed,
			&"slime_help_reward_kind",
			RogueEncounterEconomyCoordinator.SLIME_HELP_COLLECTIBLE_CHANCE
		) == expect_collectibles:
			return seed
	return -1


func _new_run_state(peer_ids: Array[int]) -> RunStateStore:
	var run_state := RunStateStore.new()
	run_state.begin_new_run(&"weishidaier", false)
	for peer_id in peer_ids:
		run_state.ensure_multiplayer_peer_state(peer_id)
	return run_state


func _fill_inventory(run_state: RunStateStore, peer_id: int) -> void:
	for _slot_index in RunStateStore.INVENTORY_CAPACITY:
		_expect(
			run_state.try_add_item_for_peer(peer_id, BASKETBALL),
			"测试背包应能被不可堆叠篮球填满。"
		)


func _count_collectibles_for_peer(run_state: RunStateStore, peer_id: int) -> int:
	var result := 0
	for slot_index in RunStateStore.INVENTORY_CAPACITY:
		var item := run_state.get_item_for_peer(peer_id, slot_index)
		if item != null and item.pickup_type == PickupConfig.PickupType.COLLECTIBLE:
			result += 1
	return result


func _make_warehouse_snapshot(
	warehouse_net_id: int,
	revision: int,
	config_path: String,
	count: int
) -> Dictionary:
	var slots: Array[Dictionary] = []
	for slot_index in RunStateStore.INVENTORY_CAPACITY:
		slots.append({
			"slot_index": slot_index,
			"config_path": config_path if slot_index == 0 and count > 0 else "",
			"stack_count": count if slot_index == 0 else 0,
		})
	return {
		"warehouse_net_id": warehouse_net_id,
		"revision": revision,
		"slots": slots,
	}


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
