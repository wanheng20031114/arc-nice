extends SceneTree

const REWARD_RESOLVER := preload(
	"res://scene/game_modes/rogue/combat/rogue_combat_reward_resolver.gd"
)
const SUITCASE_REWARD: RogueCombatRewardConfig = preload(
	"res://resources/config/rogue_combat/reward_suitcase_battle.tres"
)
const PLANK_PATH := "res://resources/config/materials/material_plank.tres"

var _failures: PackedStringArray = []


class CountingRunState:
	extends RunStateStore

	var local_add_attempts := 0
	var peer_add_attempts := 0
	var party_transaction_attempts := 0

	func try_add_item(item: PickupConfig) -> bool:
		local_add_attempts += 1
		return super.try_add_item(item)

	func try_add_item_for_peer(peer_id: int, item: PickupConfig) -> bool:
		peer_add_attempts += 1
		return super.try_add_item_for_peer(peer_id, item)

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
	_test_strict_common_reward_and_extra_xirang()
	_test_peer_rolls_are_independent_and_reproducible()
	_test_explicit_player_compatibility_filter()
	_test_full_inventory_keeps_the_first_roll()
	_test_resource_driven_party_reward_transaction()
	_test_overflow_discards_items_but_keeps_currency()
	_test_eight_player_reward_batch_uses_one_cas()
	_test_disconnected_player_uses_frozen_character_identity()

	if _failures.is_empty():
		print("ROGUE_COMBAT_REWARD_RESOLVER_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in _failures:
		push_error(failure)
	quit(1)


func _test_strict_common_reward_and_extra_xirang() -> void:
	var run_state := CountingRunState.new()
	run_state.begin_new_run(&"weishidaier", false)
	var result := REWARD_RESOLVER.resolve_reward(
		run_state,
		&"narrow-road-encounter-1",
		481516,
		77,
		500,
		false,
		null
	)
	var loot := result.get("loot", {}) as Dictionary
	var item := load(String(loot.get("config_path", ""))) as PickupConfig

	_expect(bool(loot.get("granted", false)), "空背包应获得抽中的普通收藏品。")
	_expect(
		StringName(loot.get("failure_reason", &"invalid"))
		== REWARD_RESOLVER.FAILURE_NONE,
		"成功入包不得携带失败原因。"
	)
	_expect(item != null, "结算应返回可加载的收藏品配置路径。")
	if item != null:
		_expect(
			int(item.collectible_rarity) == PickupConfig.CollectibleRarity.COMMON,
			"奖励池必须严格限定为普通品质。"
		)
		_expect(
			int(loot.get("rarity", -1)) == PickupConfig.CollectibleRarity.COMMON,
			"结算结构必须携带普通品质值。"
		)
		_expect(
			String(loot.get("name", "")) == item.display_name,
			"结算结构中的名称必须来自已抽中的配置。"
		)
		_expect(
			String(loot.get("id", ""))
			== item.resource_path.get_file().get_basename(),
			"结算结构必须携带稳定的配置 ID。"
		)
	_expect(int(result.get("extra_xirang", -1)) == 500, "额外息壤字段应原样透传500。")
	_expect(run_state.peer_add_attempts == 1, "多人奖励必须恰好调用一次Peer背包写入。")
	_expect(run_state.local_add_attempts == 0, "多人奖励不得误写本地背包。")
	run_state.free()


func _test_peer_rolls_are_independent_and_reproducible() -> void:
	const OCCURRENCE := &"narrow-road-repro"
	const CONTENT_SEED := 90210
	var first := REWARD_RESOLVER.roll_common_collectible(
		OCCURRENCE,
		CONTENT_SEED,
		11,
		false,
		null
	)
	var replay := REWARD_RESOLVER.roll_common_collectible(
		OCCURRENCE,
		CONTENT_SEED,
		11,
		false,
		null
	)
	_expect(first != null, "普通收藏品池不应为空。")
	_expect(
		first != null and replay != null and first.resource_path == replay.resource_path,
		"相同 occurrence、content seed 与 peer_id 必须复现同一结果。"
	)

	var peer_results := {}
	for peer_id in range(1, 65):
		var item := REWARD_RESOLVER.roll_common_collectible(
			OCCURRENCE,
			CONTENT_SEED,
			peer_id,
			false,
			null
		)
		if item != null:
			peer_results[item.resource_path] = true
	_expect(
		peer_results.size() > 1,
		"peer_id 必须进入独立抽取 salt，而不是让所有玩家共享一次抽取。"
	)


func _test_explicit_player_compatibility_filter() -> void:
	var player := Player.new()
	var filtered_item := REWARD_RESOLVER.roll_common_collectible(
		&"narrow-road-compatible",
		7123,
		5,
		true,
		player
	)
	_expect(filtered_item != null, "兼容性过滤后仍应存在普通收藏品候选。")
	_expect(
		filtered_item != null and player.is_collectible_compatible(filtered_item),
		"开启兼容性过滤时，抽取结果必须与指定Player兼容。"
	)
	_expect(
		REWARD_RESOLVER.roll_common_collectible(
			&"narrow-road-missing-player",
			7123,
			5,
			true,
			null
		) == null,
		"明确开启兼容性过滤时必须提供Player。"
	)
	player.free()


func _test_full_inventory_keeps_the_first_roll() -> void:
	var filler := _get_non_stackable_common_collectible()
	_expect(filler != null, "测试需要一件可入包的非堆叠普通收藏品。")
	if filler == null:
		return

	var run_state := CountingRunState.new()
	run_state.begin_new_run(&"weishidaier", false)
	for slot_index in RunStateStore.INVENTORY_CAPACITY:
		_expect(
			run_state.try_add_item(filler),
			"满包夹具的第%d个槽位应能放入收藏品。" % slot_index
		)
	run_state.local_add_attempts = 0
	var before_paths := _get_inventory_paths(run_state.inventory)
	var before_revision := run_state.inventory_revision
	var expected_item := REWARD_RESOLVER.roll_common_collectible(
		&"narrow-road-full-bag",
		24680,
		0,
		false,
		null
	)
	var result := REWARD_RESOLVER.resolve_reward(
		run_state,
		&"narrow-road-full-bag",
		24680,
		0,
		500,
		false,
		null
	)
	var loot := result.get("loot", {}) as Dictionary

	_expect(run_state.local_add_attempts == 1, "满包时也只能尝试入包一次。")
	_expect(not bool(loot.get("granted", true)), "满包奖励必须标记为未获得。")
	_expect(
		StringName(loot.get("failure_reason", &""))
		== REWARD_RESOLVER.FAILURE_INVENTORY_FULL,
		"满包失败必须返回 inventory_full。"
	)
	_expect(
		expected_item != null
		and String(loot.get("config_path", "")) == expected_item.resource_path,
		"入包失败后必须保留首次抽中的物品，不得重抽。"
	)
	_expect(run_state.inventory_revision == before_revision, "满包失败不得推进背包revision。")
	_expect(
		_get_inventory_paths(run_state.inventory) == before_paths,
		"满包失败不得改变任何背包槽位。"
	)
	run_state.free()


func _test_resource_driven_party_reward_transaction() -> void:
	var run_state := CountingRunState.new()
	run_state.begin_new_run(&"weishidaier", false)
	var before_inventory_revision := run_state.inventory_revision
	var before_xirang_revision := run_state.get_party_xirang_ledger_revision()
	var before_snapshot := run_state.export_party_economy_snapshot(
		PackedInt32Array([0])
	)
	var before_warehouse_revision := int(
		(before_snapshot.get("warehouse_ledger", {}) as Dictionary).get(
			"revision",
			-1
		)
	)
	var peer_ids: Array[int] = [0]
	var result := REWARD_RESOLVER.resolve_party_rewards(
		run_state,
		&"suitcase-battle-reward-smoke",
		13579,
		peer_ids,
		SUITCASE_REWARD,
		false,
		{},
		{0: 1200},
		{0: "account:test-local"}
	)
	_expect(bool(result.get("resolved", false)), "皮箱之战奖励应以一次事务成功结算。")
	if not bool(result.get("resolved", false)):
		run_state.free()
		return
	var extra_xirang := int(result.get("extra_xirang", -1))
	_expect(
		extra_xirang >= 2000
		and extra_xirang <= 3000
		and extra_xirang % 100 == 0,
		"皮箱之战必须抽取2000至3000、个位数为0的全队同额息壤。"
	)
	var peer_result := (
		result.get("results_by_peer", {}) as Dictionary
	).get(0, {}) as Dictionary
	var item_rewards := peer_result.get("item_rewards", []) as Array
	_expect(item_rewards.size() == 3, "皮箱之战应展示2件收藏品与1项木板奖励。")
	if item_rewards.size() == 3:
		var first := item_rewards[0] as Dictionary
		var second := item_rewards[1] as Dictionary
		var planks := item_rewards[2] as Dictionary
		_expect(
			str(first.get("config_path", ""))
			!= str(second.get("config_path", "")),
			"同一玩家的两件随机普通收藏品不得重复。"
		)
		_expect(
			str(planks.get("config_path", "")) == PLANK_PATH
			and int(planks.get("rolled_count", 0)) == 6
			and int(planks.get("granted_count", 0)) == 6,
			"空背包玩家必须完整获得6个木板。"
		)
	_expect(
		int((result.get("final_xirang_by_peer", {}) as Dictionary).get(0, -1))
		== 1200 + extra_xirang,
		"作战奖励必须叠加到包含击杀收益的战后绝对息壤。"
	)
	_expect(
		run_state.inventory_revision == before_inventory_revision + 1
		and run_state.get_party_xirang_ledger_revision()
		== before_xirang_revision + 1,
		"多项奖励必须在一个背包revision与一个息壤revision内原子提交。"
	)
	_expect(
		_count_inventory_path(run_state, PLANK_PATH) == 6,
		"奖励事务提交后背包应精确包含6个木板。"
	)
	var committed_snapshot := run_state.export_party_economy_snapshot(
		PackedInt32Array([0])
	)
	var committed_xirang := committed_snapshot.get("xirang_ledger", {}) as Dictionary
	_expect(
		not run_state.apply_authoritative_party_transaction(
			committed_snapshot,
			before_warehouse_revision,
			{0: before_inventory_revision},
			before_xirang_revision,
			committed_xirang
		),
		"使用奖励前revision重放同一CAS必须被拒绝。"
	)
	_expect(
		run_state.inventory_revision == before_inventory_revision + 1
		and run_state.get_party_xirang_ledger_revision()
		== before_xirang_revision + 1,
		"被拒绝的CAS重放不得推进任何revision或重复发奖。"
	)
	run_state.free()


func _count_inventory_path(run_state: RunStateStore, config_path: String) -> int:
	var result := 0
	for slot_index in range(run_state.inventory.size()):
		var item := run_state.inventory[slot_index]
		if item != null and item.resource_path == config_path:
			result += run_state.get_item_count(slot_index)
	return result


func _test_overflow_discards_items_but_keeps_currency() -> void:
	var filler := _get_non_stackable_common_collectible()
	if filler == null:
		_expect(false, "溢出测试需要非堆叠普通收藏品。")
		return
	var run_state := CountingRunState.new()
	run_state.begin_new_run(&"weishidaier", false)
	for slot_index in range(RunStateStore.INVENTORY_CAPACITY - 1):
		_expect(run_state.try_add_item(filler), "溢出夹具应填充第%d槽。" % slot_index)
	var peer_ids: Array[int] = [0]
	var result := REWARD_RESOLVER.resolve_party_rewards(
		run_state,
		&"suitcase-battle-overflow-smoke",
		24681357,
		peer_ids,
		SUITCASE_REWARD,
		false,
		{},
		{0: 900},
		{0: "account:overflow"}
	)
	_expect(bool(result.get("resolved", false)), "物品溢出不得阻止整笔作战结算。")
	var rewards := (
		((result.get("results_by_peer", {}) as Dictionary).get(0, {}) as Dictionary)
		.get("item_rewards", []) as Array
	)
	if rewards.size() == 3:
		_expect(
			int((rewards[0] as Dictionary).get("granted_count", -1)) == 1
			and int((rewards[1] as Dictionary).get("granted_count", -1)) == 0
			and int((rewards[2] as Dictionary).get("granted_count", -1)) == 0,
			"仅剩一个槽位时应逐项保留首件收藏品，并丢弃后续收藏品与木板。"
		)
	else:
		_expect(false, "溢出结算仍必须返回完整三条奖励结果。")
	_expect(
		int((result.get("final_xirang_by_peer", {}) as Dictionary).get(0, -1))
		> 900,
		"背包溢出不得吞掉额外息壤。"
	)
	run_state.free()


func _test_eight_player_reward_batch_uses_one_cas() -> void:
	var run_state := CountingRunState.new()
	run_state.begin_new_run(&"weishidaier", false)
	var peer_ids: Array[int] = []
	var players_by_peer: Dictionary = {}
	var base_xirang_by_peer: Dictionary = {}
	var stable_keys_by_peer: Dictionary = {}
	for peer_id in range(1, 9):
		run_state.ensure_multiplayer_peer_state(peer_id)
		peer_ids.append(peer_id)
		players_by_peer[peer_id] = Player.new()
		base_xirang_by_peer[peer_id] = 1000 + peer_id * 10
		stable_keys_by_peer[peer_id] = "account:stress:%d" % peer_id
	var result := REWARD_RESOLVER.resolve_party_rewards(
		run_state,
		&"suitcase-battle-eight-player-smoke",
		97531,
		peer_ids,
		SUITCASE_REWARD,
		true,
		players_by_peer,
		base_xirang_by_peer,
		stable_keys_by_peer
	)
	_expect(bool(result.get("resolved", false)), "8人皮箱奖励批次应成功结算。")
	_expect(
		run_state.party_transaction_attempts == 1,
		"8名玩家的息壤、收藏品与木板必须只提交一次Party Economy CAS。"
	)
	var results_by_peer := result.get("results_by_peer", {}) as Dictionary
	var shared_extra := int(result.get("extra_xirang", -1))
	_expect(results_by_peer.size() == 8, "8人压力结算不得漏掉任何有效参战者。")
	for peer_id in peer_ids:
		var peer_result := results_by_peer.get(peer_id, {}) as Dictionary
		var rewards := peer_result.get("item_rewards", []) as Array
		_expect(rewards.size() == 3, "玩家%d必须得到完整三条奖励结果。" % peer_id)
		if rewards.size() == 3:
			_expect(
				str((rewards[0] as Dictionary).get("config_path", ""))
				!= str((rewards[1] as Dictionary).get("config_path", "")),
				"玩家%d的两件收藏品不得重复。" % peer_id
			)
			_expect(
				int((rewards[2] as Dictionary).get("granted_count", 0)) == 6,
				"玩家%d必须独立获得6个木板。" % peer_id
			)
		_expect(
			int(peer_result.get("extra_xirang", -1)) == shared_extra,
			"同一作战的8名玩家必须获得相同的额外息壤抽取值。"
		)
	for player_value in players_by_peer.values():
		(player_value as Player).free()
	run_state.free()


func _test_disconnected_player_uses_frozen_character_identity() -> void:
	var run_state := CountingRunState.new()
	run_state.begin_new_run(&"weishidaier", false)
	run_state.ensure_multiplayer_peer_state(7)
	var result := REWARD_RESOLVER.resolve_party_rewards(
		run_state,
		&"suitcase-battle-disconnected-smoke",
		86420,
		[7] as Array[int],
		SUITCASE_REWARD,
		true,
		{},
		{7: 1370},
		{7: "account:disconnected:7"},
		{7: &"tiyi"}
	)
	_expect(
		bool(result.get("resolved", false)),
		"已离开战斗树的原始参战者应使用冻结角色身份完成奖励结算。"
	)
	var peer_result := (
		result.get("results_by_peer", {}) as Dictionary
	).get(7, {}) as Dictionary
	_expect(
		(peer_result.get("item_rewards", []) as Array).size() == 3,
		"断线原始参战者仍应获得两件兼容收藏品与六块木板的完整结果。"
	)
	_expect(
		int((result.get("final_xirang_by_peer", {}) as Dictionary).get(7, -1))
		> 1370,
		"断线原始参战者仍应获得全队同额的额外息壤。"
	)
	run_state.free()


func _get_non_stackable_common_collectible() -> PickupConfig:
	for item in CollectibleRegistry.get_by_rarity(
		PickupConfig.CollectibleRarity.COMMON
	):
		if item.can_store_in_inventory and not item.stackable:
			return item
	return null


func _get_inventory_paths(items: Array[PickupConfig]) -> PackedStringArray:
	var paths := PackedStringArray()
	for item in items:
		paths.append(item.resource_path if item != null else "")
	return paths


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
