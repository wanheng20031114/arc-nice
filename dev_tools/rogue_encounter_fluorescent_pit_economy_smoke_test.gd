extends SceneTree

const BASKETBALL := preload(
	"res://resources/config/collectibles/collectible_basketball.tres"
)

var _failures: PackedStringArray = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_snapshot_schema_and_result_contract()
	_test_probability_bucket_boundaries()
	_test_shared_xirang_and_round_idempotency()
	_test_fall_core_damage_and_failure()
	_test_character_compatibility_pools()
	_test_collectible_rewards_and_full_inventory_discard()
	_test_radiation_penalty_and_replay()
	_test_leave_contract()
	if _failures.is_empty():
		print("ROGUE_ENCOUNTER_FLUORESCENT_PIT_ECONOMY_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in _failures:
		push_error(failure)
	quit(1)


func _test_snapshot_schema_and_result_contract() -> void:
	var run_state := _new_run_state([0])
	var economy := RogueEncounterEconomyCoordinator.new()
	economy.configure(run_state)
	var snapshot := economy.export_snapshot([0])
	var party_economy := snapshot.get("party_economy", {}) as Dictionary
	_expect(
		RogueEncounterEconomyCoordinator.SCHEMA_VERSION == 3
		and int(snapshot.get("schema_version", -1)) == 3
		and int(party_economy.get("schema_version", -1))
		== RunStateStore.PARTY_ECONOMY_SCHEMA_VERSION
		and typeof(party_economy.get("party_status_ledger")) == TYPE_DICTIONARY,
		"坑洞结算快照必须使用schema 3并携带队伍状态账本。"
	)
	var nothing_seed := _find_seed_for_bucket(0, 0)
	var result := economy.resolve_encounter(
		RogueEncounterEconomyCoordinator.ENCOUNTER_FLUORESCENT_PIT,
		RogueEncounterEconomyCoordinator.OPTION_EXPLORE_PIT,
		nothing_seed,
		[0],
		"pit-contract",
		0
	)
	for field_name in [
		"resolved",
		"result_code",
		"encounter_id",
		"option_id",
		"terminal",
		"run_failed",
		"disable_explore",
		"round_index",
		"round_recipient_peer_ids",
		"common_result_text",
		"common_detail_text",
		"personal_detail_by_peer",
	]:
		_expect(result.has(field_name), "坑洞结果缺少统一字段：%s。" % field_name)
	economy.free()
	run_state.free()


func _test_probability_bucket_boundaries() -> void:
	var cases := [
		[0, RogueEncounterEconomyCoordinator.RESULT_PIT_NOTHING],
		[29, RogueEncounterEconomyCoordinator.RESULT_PIT_NOTHING],
		[30, RogueEncounterEconomyCoordinator.RESULT_PIT_XIRANG],
		[49, RogueEncounterEconomyCoordinator.RESULT_PIT_XIRANG],
		[50, RogueEncounterEconomyCoordinator.RESULT_PIT_FALL],
		[79, RogueEncounterEconomyCoordinator.RESULT_PIT_FALL],
		[80, RogueEncounterEconomyCoordinator.RESULT_PIT_COLLECTIBLE],
		[84, RogueEncounterEconomyCoordinator.RESULT_PIT_COLLECTIBLE],
		[85, RogueEncounterEconomyCoordinator.RESULT_PIT_BOTTOM],
		[98, RogueEncounterEconomyCoordinator.RESULT_PIT_BOTTOM],
		[99, RogueEncounterEconomyCoordinator.RESULT_PIT_RADIATION],
	]
	for raw_case in cases:
		var bucket := int(raw_case[0])
		var expected_code := StringName(raw_case[1])
		var run_state := _new_run_state([0])
		var economy := RogueEncounterEconomyCoordinator.new()
		economy.configure(run_state)
		var result := economy.resolve_encounter(
			RogueEncounterEconomyCoordinator.ENCOUNTER_FLUORESCENT_PIT,
			RogueEncounterEconomyCoordinator.OPTION_EXPLORE_PIT,
			_find_seed_for_bucket(bucket, 0),
			[0],
			"pit-boundary-%d" % bucket,
			0
		)
		_expect(
			StringName(result.get("result_code", &"")) == expected_code,
			"概率桶%d必须映射到%s。" % [bucket, String(expected_code)]
		)
		_expect(
			int(result.get("round_index", -1)) == 0
			and result.get("round_recipient_peer_ids", []) == [0],
			"每个概率边界结果都必须保留轮次与结算对象。"
		)
		if bucket == 85 or bucket == 98:
			_expect(
				bool(result.get("disable_explore", false))
				and not bool(result.get("terminal", true)),
				"到底分支必须只禁用继续下探，不直接结束事件。"
			)
		economy.free()
		run_state.free()


func _test_shared_xirang_and_round_idempotency() -> void:
	var run_state := _new_run_state([11, 12])
	var economy := RogueEncounterEconomyCoordinator.new()
	economy.configure(run_state)
	var round_zero := economy.resolve_encounter(
		RogueEncounterEconomyCoordinator.ENCOUNTER_FLUORESCENT_PIT,
		RogueEncounterEconomyCoordinator.OPTION_EXPLORE_PIT,
		_find_seed_for_bucket(30, 0),
		[12, 11, 12],
		"pit-xirang",
		0
	)
	var amount_zero := int(round_zero.get("xirang_reward_each", -1))
	_expect(
		amount_zero >= RogueEncounterEconomyCoordinator.PIT_XIRANG_MINIMUM
		and amount_zero <= RogueEncounterEconomyCoordinator.PIT_XIRANG_MAXIMUM
		and run_state.get_party_xirang_balance(11) == amount_zero
		and run_state.get_party_xirang_balance(12) == amount_zero,
		"息壤分支必须在5..100闭区间抽取，并给所有玩家相同数额。"
	)
	var replay := economy.resolve_encounter(
		RogueEncounterEconomyCoordinator.ENCOUNTER_FLUORESCENT_PIT,
		RogueEncounterEconomyCoordinator.OPTION_EXPLORE_PIT,
		_find_seed_for_bucket(49, 0),
		[11, 12],
		"pit-xirang",
		0
	)
	_expect(
		replay == round_zero
		and run_state.get_party_xirang_balance(11) == amount_zero
		and run_state.get_party_xirang_balance(12) == amount_zero,
		"同一 occurrence 与轮次的重放不得重复发放息壤。"
	)
	var round_one := economy.resolve_encounter(
		RogueEncounterEconomyCoordinator.ENCOUNTER_FLUORESCENT_PIT,
		RogueEncounterEconomyCoordinator.OPTION_EXPLORE_PIT,
		_find_seed_for_bucket(30, 1),
		[11, 12],
		"pit-xirang",
		1
	)
	var amount_one := int(round_one.get("xirang_reward_each", -1))
	_expect(
		int(round_one.get("round_index", -1)) == 1
		and run_state.get_party_xirang_balance(11) == amount_zero + amount_one
		and run_state.get_party_xirang_balance(12) == amount_zero + amount_one,
		"下一轮必须使用独立幂等键并再次正常结算。"
	)
	for endpoint_amount in [
		RogueEncounterEconomyCoordinator.PIT_XIRANG_MINIMUM,
		RogueEncounterEconomyCoordinator.PIT_XIRANG_MAXIMUM,
	]:
		var endpoint_result := economy.resolve_encounter(
			RogueEncounterEconomyCoordinator.ENCOUNTER_FLUORESCENT_PIT,
			RogueEncounterEconomyCoordinator.OPTION_EXPLORE_PIT,
			_find_seed_for_xirang_amount(endpoint_amount, 0),
			[11, 12],
			"pit-xirang-endpoint-%d" % endpoint_amount,
			0
		)
		_expect(
			int(endpoint_result.get("xirang_reward_each", -1))
			== endpoint_amount,
			"息壤闭区间必须实际包含端点%d。" % endpoint_amount
		)
	economy.free()
	run_state.free()


func _test_fall_core_damage_and_failure() -> void:
	var run_state := _new_run_state([21, 22])
	_expect(
		run_state.set_party_core_health(3, 100),
		"踩空测试必须先设置共享核心生命。"
	)
	var economy := RogueEncounterEconomyCoordinator.new()
	economy.configure(run_state)
	var first := economy.resolve_encounter(
		RogueEncounterEconomyCoordinator.ENCOUNTER_FLUORESCENT_PIT,
		RogueEncounterEconomyCoordinator.OPTION_EXPLORE_PIT,
		_find_seed_for_bucket(50, 0),
		[21, 22],
		"pit-fall",
		0
	)
	_expect(
		int(first.get("core_before", -1)) == 3
		and int(first.get("core_after", -1)) == 1
		and run_state.get_party_core_health() == 1
		and not bool(first.get("terminal", true))
		and not bool(first.get("run_failed", true)),
		"共享核心必须只扣2点，未归零时继续事件。"
	)
	var second := economy.resolve_encounter(
		RogueEncounterEconomyCoordinator.ENCOUNTER_FLUORESCENT_PIT,
		RogueEncounterEconomyCoordinator.OPTION_EXPLORE_PIT,
		_find_seed_for_bucket(79, 1),
		[21, 22],
		"pit-fall",
		1
	)
	_expect(
		int(second.get("core_before", -1)) == 1
		and int(second.get("core_after", -1)) == 0
		and bool(second.get("terminal", false))
		and bool(second.get("run_failed", false)),
		"核心归零的踩空结果必须结束事件并标记本局失败。"
	)
	var replay := economy.resolve_encounter(
		RogueEncounterEconomyCoordinator.ENCOUNTER_FLUORESCENT_PIT,
		RogueEncounterEconomyCoordinator.OPTION_EXPLORE_PIT,
		_find_seed_for_bucket(50, 1),
		[21, 22],
		"pit-fall",
		1
	)
	_expect(
		replay == second and run_state.get_party_core_health() == 0,
		"踩空结算重放不得再次扣除共享核心。"
	)
	economy.free()
	run_state.free()


func _test_collectible_rewards_and_full_inventory_discard() -> void:
	var run_state := _new_run_state([31, 32], PlayerCharacterRegistry.HOE_CAT_ID)
	var economy := RogueEncounterEconomyCoordinator.new()
	economy.configure(run_state)
	var collectible_seed := _find_distinct_collectible_seed(economy, 31, 32, 0)
	var result := economy.resolve_encounter(
		RogueEncounterEconomyCoordinator.ENCOUNTER_FLUORESCENT_PIT,
		RogueEncounterEconomyCoordinator.OPTION_EXPLORE_PIT,
		collectible_seed,
		[31, 32],
		"pit-collectible",
		0
	)
	var rewards := result.get("collectible_rewards", []) as Array
	_expect(rewards.size() == 2, "收藏品分支必须给每名玩家独立抽取一份。")
	if rewards.size() == 2:
		_expect(
			str((rewards[0] as Dictionary).get("rolled_path", ""))
			!= str((rewards[1] as Dictionary).get("rolled_path", "")),
			"不同玩家必须使用包含peer id的独立收藏品抽取salt。"
		)
	for raw_reward in rewards:
		var reward := raw_reward as Dictionary
		var item := CollectibleRegistry.get_for_path(
			str(reward.get("rolled_path", ""))
		)
		_expect(
			item != null
			and item.can_store_in_inventory
			and int(item.collectible_rarity)
			<= PickupConfig.CollectibleRarity.EPIC
			and not item.requires_ammunition
			and not item.requires_projectile_primary_attack
			and bool(reward.get("granted", false)),
			"锄头猫只能抽到可入包、兼容且不高于史诗的收藏品。"
		)
	var pool_size := economy._get_pit_collectible_pool_for_peer(31).size()
	var same_item_result := economy.resolve_encounter(
		RogueEncounterEconomyCoordinator.ENCOUNTER_FLUORESCENT_PIT,
		RogueEncounterEconomyCoordinator.OPTION_EXPLORE_PIT,
		_find_seed_for_same_collectible(pool_size, 31, 32, 1),
		[31, 32],
		"pit-collectible-same-item",
		1
	)
	var same_item_rewards := (
		same_item_result.get("collectible_rewards", []) as Array
	)
	_expect(
		same_item_rewards.size() == 2
		and str((same_item_rewards[0] as Dictionary).get("rolled_path", ""))
		== str((same_item_rewards[1] as Dictionary).get("rolled_path", "")),
		"逐玩家独立随机不得做队伍去重；不同玩家允许抽到同一收藏品。"
	)
	var full_run_state := _new_run_state([41])
	for _slot_index in RunStateStore.INVENTORY_CAPACITY:
		_expect(
			full_run_state.try_add_item_for_peer(41, BASKETBALL),
			"满包测试必须用非堆叠篮球填满全部格子。"
		)
	var full_economy := RogueEncounterEconomyCoordinator.new()
	full_economy.configure(full_run_state)
	var full_result := full_economy.resolve_encounter(
		RogueEncounterEconomyCoordinator.ENCOUNTER_FLUORESCENT_PIT,
		RogueEncounterEconomyCoordinator.OPTION_EXPLORE_PIT,
		_find_seed_for_bucket(84, 0),
		[41],
		"pit-full-inventory",
		0
	)
	var full_reward := (
		full_result.get("collectible_rewards", []) as Array
	)[0] as Dictionary
	var personal := full_result.get("personal_detail_by_peer", {}) as Dictionary
	_expect(
		not bool(full_reward.get("granted", true))
		and str(full_reward.get("failure_reason", "")) == "inventory_full"
		and str(personal.get(41, "")).begins_with("背包已满，未获得：")
		and full_run_state.get_inventory_revision_for_peer(41)
		== RunStateStore.INVENTORY_CAPACITY,
		"满包时必须保留抽中物品、标记未获得，且不得改写背包。"
	)
	full_economy.free()
	full_run_state.free()
	economy.free()
	run_state.free()


func _test_character_compatibility_pools() -> void:
	for character_id in [
		PlayerCharacterRegistry.WEISHIDAIER_ID,
		PlayerCharacterRegistry.TIYI_ID,
	]:
		var ranged_state := _new_run_state([0], character_id)
		var ranged_economy := RogueEncounterEconomyCoordinator.new()
		ranged_economy.configure(ranged_state)
		var ranged_pool := ranged_economy._get_pit_collectible_pool_for_peer(0)
		var has_ammunition_item := false
		var has_projectile_item := false
		for item in ranged_pool:
			has_ammunition_item = has_ammunition_item or item.requires_ammunition
			has_projectile_item = (
				has_projectile_item or item.requires_projectile_primary_attack
			)
		_expect(
			has_ammunition_item and has_projectile_item,
			"维斯戴尔与缇伊的坑洞池必须保留弹药及投射物收藏品。"
		)
		ranged_economy.free()
		ranged_state.free()
	for character_id in [
		PlayerCharacterRegistry.HOE_CAT_ID,
		PlayerCharacterRegistry.TANGO_ID,
	]:
		var melee_state := _new_run_state([0], character_id)
		var melee_economy := RogueEncounterEconomyCoordinator.new()
		melee_economy.configure(melee_state)
		var melee_pool := melee_economy._get_pit_collectible_pool_for_peer(0)
		for item in melee_pool:
			_expect(
				not item.requires_ammunition
				and not item.requires_projectile_primary_attack,
				"锄头猫与当前Tango运行时不得抽到弹药或投射物限定收藏品。"
			)
		melee_economy.free()
		melee_state.free()


func _test_radiation_penalty_and_replay() -> void:
	var run_state := _new_run_state([51, 52])
	var economy := RogueEncounterEconomyCoordinator.new()
	economy.configure(run_state)
	var result := economy.resolve_encounter(
		RogueEncounterEconomyCoordinator.ENCOUNTER_FLUORESCENT_PIT,
		RogueEncounterEconomyCoordinator.OPTION_EXPLORE_PIT,
		_find_seed_for_bucket(99, 0),
		[51, 52],
		"pit-radiation",
		0
	)
	_expect(
		bool(result.get("terminal", false))
		and not bool(result.get("run_failed", true))
		and run_state.get_max_health_penalty_for_peer(51) == 20
		and run_state.get_max_health_penalty_for_peer(52) == 20,
		"放射性分支必须给结算时在线玩家各累计20最大生命惩罚并离开事件。"
	)
	var replay := economy.resolve_encounter(
		RogueEncounterEconomyCoordinator.ENCOUNTER_FLUORESCENT_PIT,
		RogueEncounterEconomyCoordinator.OPTION_EXPLORE_PIT,
		_find_seed_for_bucket(99, 0),
		[51, 52],
		"pit-radiation|round:0",
		0
	)
	_expect(
		replay == result
		and run_state.get_max_health_penalty_for_peer(51) == 20
		and run_state.get_max_health_penalty_for_peer(52) == 20,
		"显式带轮次后缀的放射性重放也不得重复叠加惩罚。"
	)
	economy.free()
	run_state.free()


func _test_leave_contract() -> void:
	var run_state := _new_run_state([0])
	var economy := RogueEncounterEconomyCoordinator.new()
	economy.configure(run_state)
	var result := economy.resolve_encounter(
		RogueEncounterEconomyCoordinator.ENCOUNTER_FLUORESCENT_PIT,
		RogueEncounterEconomyCoordinator.OPTION_LEAVE_PIT,
		123,
		[0],
		"pit-leave",
		7
	)
	_expect(
		StringName(result.get("result_code", &""))
		== RogueEncounterEconomyCoordinator.RESULT_PIT_LEFT
		and str(result.get("common_result_text", "")) == "还是赶紧走吧"
		and bool(result.get("terminal", false))
		and not bool(result.get("run_failed", true))
		and int(result.get("round_index", -1)) == 7,
		"主动离开必须显示指定旁白、结束事件且不标记失败。"
	)
	economy.free()
	run_state.free()


func _find_seed_for_bucket(bucket: int, round_index: int) -> int:
	var salt := StringName("fluorescent_pit_outcome|round:%d" % round_index)
	for seed_value in range(20000):
		if RogueEncounterRandom.choose_index(seed_value, salt, 100) == bucket:
			return seed_value
	_expect(false, "无法为概率桶%d找到确定性seed。" % bucket)
	return 0


func _find_seed_for_xirang_amount(amount: int, round_index: int) -> int:
	var outcome_salt := StringName(
		"fluorescent_pit_outcome|round:%d" % round_index
	)
	var amount_salt := StringName(
		"fluorescent_pit_xirang|round:%d" % round_index
	)
	var target_index := amount - RogueEncounterEconomyCoordinator.PIT_XIRANG_MINIMUM
	for seed_value in range(100_000):
		var outcome := RogueEncounterRandom.choose_index(
			seed_value,
			outcome_salt,
			100
		)
		if outcome < 30 or outcome >= 50:
			continue
		if RogueEncounterRandom.choose_index(seed_value, amount_salt, 96) == target_index:
			return seed_value
	_expect(false, "无法为息壤端点%d找到确定性seed。" % amount)
	return 0


func _find_seed_for_same_collectible(
	pool_size: int,
	first_peer_id: int,
	second_peer_id: int,
	round_index: int
) -> int:
	var outcome_salt := StringName(
		"fluorescent_pit_outcome|round:%d" % round_index
	)
	var first_salt := StringName(
		"fluorescent_pit_collectible|round:%d|peer:%d"
		% [round_index, first_peer_id]
	)
	var second_salt := StringName(
		"fluorescent_pit_collectible|round:%d|peer:%d"
		% [round_index, second_peer_id]
	)
	for seed_value in range(200_000):
		var outcome := RogueEncounterRandom.choose_index(
			seed_value,
			outcome_salt,
			100
		)
		if outcome < 80 or outcome >= 85:
			continue
		if RogueEncounterRandom.choose_index(
			seed_value,
			first_salt,
			pool_size
		) == RogueEncounterRandom.choose_index(
			seed_value,
			second_salt,
			pool_size
		):
			return seed_value
	_expect(false, "无法找到允许两名玩家抽中同物的确定性seed。")
	return 0


func _find_distinct_collectible_seed(
	economy: RogueEncounterEconomyCoordinator,
	first_peer_id: int,
	second_peer_id: int,
	round_index: int
) -> int:
	var first_pool := economy._get_pit_collectible_pool_for_peer(first_peer_id)
	var second_pool := economy._get_pit_collectible_pool_for_peer(second_peer_id)
	var outcome_salt := StringName(
		"fluorescent_pit_outcome|round:%d" % round_index
	)
	for seed_value in range(20000):
		var bucket := RogueEncounterRandom.choose_index(
			seed_value,
			outcome_salt,
			100
		)
		if bucket < 80 or bucket >= 85:
			continue
		var first_index := RogueEncounterRandom.choose_index(
			seed_value,
			StringName(
				"fluorescent_pit_collectible|round:%d|peer:%d"
				% [round_index, first_peer_id]
			),
			first_pool.size()
		)
		var second_index := RogueEncounterRandom.choose_index(
			seed_value,
			StringName(
				"fluorescent_pit_collectible|round:%d|peer:%d"
				% [round_index, second_peer_id]
			),
			second_pool.size()
		)
		if (
			first_index >= 0
			and second_index >= 0
			and first_pool[first_index].resource_path
			!= second_pool[second_index].resource_path
		):
			return seed_value
	_expect(false, "无法找到能证明逐玩家独立抽取的确定性seed。")
	return 0


func _new_run_state(
	peer_ids: Array[int],
	character_id: StringName = PlayerCharacterRegistry.WEISHIDAIER_ID
) -> RunStateStore:
	var run_state := RunStateStore.new()
	run_state.begin_new_run(character_id, false)
	for peer_id in peer_ids:
		if peer_id > 0:
			run_state.ensure_multiplayer_peer_state(peer_id)
	return run_state


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
