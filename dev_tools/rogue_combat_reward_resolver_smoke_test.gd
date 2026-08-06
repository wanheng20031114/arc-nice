extends SceneTree

const REWARD_RESOLVER := preload(
	"res://scene/game_modes/rogue/combat/rogue_combat_reward_resolver.gd"
)

var _failures: PackedStringArray = []


class CountingRunState:
	extends RunStateStore

	var local_add_attempts := 0
	var peer_add_attempts := 0

	func try_add_item(item: PickupConfig) -> bool:
		local_add_attempts += 1
		return super.try_add_item(item)

	func try_add_item_for_peer(peer_id: int, item: PickupConfig) -> bool:
		peer_add_attempts += 1
		return super.try_add_item_for_peer(peer_id, item)


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	_test_strict_common_reward_and_extra_xirang()
	_test_peer_rolls_are_independent_and_reproducible()
	_test_explicit_player_compatibility_filter()
	_test_full_inventory_keeps_the_first_roll()

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
