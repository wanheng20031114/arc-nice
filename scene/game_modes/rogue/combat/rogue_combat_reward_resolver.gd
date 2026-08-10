extends RefCounted
class_name RogueCombatRewardResolver

## Rouge 作战结算的权威奖励解析器。
##
## 新作战使用 resolve_party_rewards()，先完整生成全队奖励与背包快照，再通过
## RunStateStore 的 Party Economy CAS 一次提交。resolve_reward() 保留旧调用约定。

const FAILURE_NONE := &""
const FAILURE_INVALID_RUN_STATE := &"invalid_run_state"
const FAILURE_MISSING_COMPATIBILITY_PLAYER := &"missing_compatibility_player"
const FAILURE_NO_ELIGIBLE_COLLECTIBLE := &"no_eligible_collectible"
const FAILURE_INVENTORY_FULL := &"inventory_full"
const FAILURE_INVALID_REWARD_CONFIG := &"invalid_reward_config"
const FAILURE_INVALID_PARTICIPANTS := &"invalid_participants"
const FAILURE_TRANSACTION_CONFLICT := &"transaction_conflict"

const _ROLL_SALT_PREFIX := "rogue_combat_common_collectible"
const _PARTY_ROLL_SALT_PREFIX := "rogue_combat_collectible_batch"


## 为所有符合奖励条件的玩家生成并原子提交一次结算。base_xirang_by_peer 是
## 战斗结束时（已含击杀收益、尚未加作战奖励）的绝对息壤值。
static func resolve_party_rewards(
	run_state: RunStateStore,
	occurrence_id: StringName,
	content_seed: int,
	peer_ids: Array[int],
	reward_config: RogueCombatRewardConfig,
	filter_by_player_compatibility: bool,
	players_by_peer: Dictionary,
	base_xirang_by_peer: Dictionary,
	stable_keys_by_peer: Dictionary = {},
	character_ids_by_peer: Dictionary = {}
) -> Dictionary:
	var failure_result := _make_party_failure(FAILURE_INVALID_RUN_STATE)
	if run_state == null:
		return failure_result
	if reward_config == null or not reward_config.validate_config().is_empty():
		return _make_party_failure(FAILURE_INVALID_REWARD_CONFIG)

	var ordered_peer_ids := _normalize_peer_ids(peer_ids)
	if ordered_peer_ids.size() != peer_ids.size() or ordered_peer_ids.is_empty():
		return _make_party_failure(FAILURE_INVALID_PARTICIPANTS)
	for peer_id in ordered_peer_ids:
		var compatibility_player := players_by_peer.get(peer_id) as Player
		var compatibility_character_id := StringName(
			character_ids_by_peer.get(
				peer_id,
				character_ids_by_peer.get(str(peer_id), &"")
			)
		)
		if (
			not base_xirang_by_peer.has(peer_id)
			or typeof(base_xirang_by_peer[peer_id]) != TYPE_INT
			or int(base_xirang_by_peer[peer_id]) < 0
			or (
				filter_by_player_compatibility
				and compatibility_player == null
				and not PlayerCharacterRegistry.is_valid_character_id(
					compatibility_character_id
				)
			)
		):
			return _make_party_failure(FAILURE_INVALID_PARTICIPANTS)

	var packed_peer_ids := PackedInt32Array()
	for peer_id in ordered_peer_ids:
		packed_peer_ids.append(peer_id)
	var party_snapshot := run_state.export_party_economy_snapshot(packed_peer_ids)
	var next_snapshot := party_snapshot.duplicate(true)
	var inventory_snapshots := _index_inventory_snapshots(party_snapshot)
	var next_inventory_snapshots := _index_inventory_snapshots(next_snapshot)
	if (
		inventory_snapshots.size() != ordered_peer_ids.size()
		or next_inventory_snapshots.size() != ordered_peer_ids.size()
	):
		return _make_party_failure(FAILURE_INVALID_PARTICIPANTS)
	var expected_inventory_revisions: Dictionary = {}
	for peer_id in ordered_peer_ids:
		expected_inventory_revisions[peer_id] = int(
			(inventory_snapshots[peer_id] as Dictionary).get("revision", -1)
		)

	var extra_xirang := reward_config.roll_xirang(content_seed, occurrence_id)
	var results_by_peer: Dictionary = {}
	var final_xirang_by_peer: Dictionary = {}
	var touched_peer_ids: Dictionary = {}
	for peer_id in ordered_peer_ids:
		var player := players_by_peer.get(peer_id) as Player
		var character_id := StringName(
			character_ids_by_peer.get(
				peer_id,
				character_ids_by_peer.get(str(peer_id), &"")
			)
		)
		var inventory_snapshot := next_inventory_snapshots[peer_id] as Dictionary
		var peer_result := _build_peer_reward(
			occurrence_id,
			content_seed,
			peer_id,
			reward_config,
			filter_by_player_compatibility,
			player,
			character_id,
			str(stable_keys_by_peer.get(
				peer_id,
				stable_keys_by_peer.get(str(peer_id), "")
			)),
			inventory_snapshot
		)
		if not bool(peer_result.get("resolved", false)):
			return _make_party_failure(
				StringName(peer_result.get(
					"failure_reason",
					FAILURE_NO_ELIGIBLE_COLLECTIBLE
				))
			)
		if bool(peer_result.get("inventory_changed", false)):
			touched_peer_ids[peer_id] = true
		peer_result.erase("resolved")
		peer_result.erase("inventory_changed")
		peer_result["extra_xirang"] = extra_xirang
		results_by_peer[peer_id] = peer_result
		final_xirang_by_peer[peer_id] = int(base_xirang_by_peer[peer_id]) + extra_xirang

	for raw_peer_id in touched_peer_ids.keys():
		var peer_id := int(raw_peer_id)
		var inventory_snapshot := next_inventory_snapshots[peer_id] as Dictionary
		inventory_snapshot["revision"] = int(expected_inventory_revisions[peer_id]) + 1

	var current_xirang_ledger := party_snapshot.get("xirang_ledger", {}) as Dictionary
	var next_xirang_ledger := current_xirang_ledger.duplicate(true)
	var next_xirang_values := next_xirang_ledger.get("values", {}) as Dictionary
	var xirang_changed := false
	for peer_id in ordered_peer_ids:
		var peer_key := str(peer_id)
		var next_amount := int(final_xirang_by_peer[peer_id])
		if int(next_xirang_values.get(peer_key, 0)) != next_amount:
			next_xirang_values[peer_key] = next_amount
			xirang_changed = true
	next_xirang_ledger["values"] = next_xirang_values
	if xirang_changed:
		next_xirang_ledger["revision"] = int(current_xirang_ledger.get("revision", -1)) + 1

	var warehouse_ledger := party_snapshot.get("warehouse_ledger", {}) as Dictionary
	if not run_state.apply_authoritative_party_transaction(
		next_snapshot,
		int(warehouse_ledger.get("revision", -1)),
		expected_inventory_revisions,
		int(current_xirang_ledger.get("revision", -1)),
		next_xirang_ledger
	):
		return _make_party_failure(FAILURE_TRANSACTION_CONFLICT)
	return {
		"resolved": true,
		"failure_reason": FAILURE_NONE,
		"extra_xirang": extra_xirang,
		"results_by_peer": results_by_peer,
		"final_xirang_by_peer": final_xirang_by_peer,
		"inventory_snapshots_by_peer": next_inventory_snapshots,
	}


## 为一名玩家抽取并尝试写入一次背包。
## filter_by_player_compatibility 没有默认值，调用方必须明确选择口径。
static func resolve_reward(
	run_state: RunStateStore,
	occurrence_id: StringName,
	content_seed: int,
	peer_id: int,
	extra_xirang: int,
	filter_by_player_compatibility: bool,
	player: Player
) -> Dictionary:
	var result := {
		"occurrence_id": String(occurrence_id),
		"content_seed": content_seed,
		"peer_id": peer_id,
		"extra_xirang": extra_xirang,
		"loot": _make_empty_loot(FAILURE_NONE),
		"item_rewards": [],
	}
	if run_state == null:
		result["loot"] = _make_empty_loot(FAILURE_INVALID_RUN_STATE)
		return result
	if filter_by_player_compatibility and player == null:
		result["loot"] = _make_empty_loot(FAILURE_MISSING_COMPATIBILITY_PLAYER)
		return result

	var item := roll_common_collectible(
		occurrence_id,
		content_seed,
		peer_id,
		filter_by_player_compatibility,
		player
	)
	if item == null:
		result["loot"] = _make_empty_loot(FAILURE_NO_ELIGIBLE_COLLECTIBLE)
		return result

	# 每次结算只发起这一次背包写入。失败后保留本次抽取结果，不重抽。
	var granted := (
		run_state.try_add_item_for_peer(peer_id, item)
		if peer_id > 0
		else run_state.try_add_item(item)
	)
	result["loot"] = _make_loot(
		item,
		granted,
		FAILURE_NONE if granted else FAILURE_INVENTORY_FULL
	)
	result["item_rewards"] = [
		_make_collectible_reward(item, granted)
	]
	return result


## 纯抽取 API：不写背包，可用于预览或复核权威结果。
static func roll_common_collectible(
	occurrence_id: StringName,
	content_seed: int,
	peer_id: int,
	filter_by_player_compatibility: bool,
	player: Player
) -> PickupConfig:
	if filter_by_player_compatibility and player == null:
		return null
	var pool := _get_common_pool(filter_by_player_compatibility, player)
	var chosen_index := RogueEncounterRandom.choose_index(
		content_seed,
		_make_roll_salt(occurrence_id, peer_id),
		pool.size()
	)
	return pool[chosen_index] if chosen_index >= 0 else null


static func _get_common_pool(
	filter_by_player_compatibility: bool,
	player: Player
) -> Array[PickupConfig]:
	var result: Array[PickupConfig] = []
	for item in CollectibleRegistry.get_by_rarity(
		PickupConfig.CollectibleRarity.COMMON
	):
		# 只有可写入背包的配置才能成为战利品，以保证写入失败明确表示满包。
		if not item.can_store_in_inventory:
			continue
		if filter_by_player_compatibility and not player.is_collectible_compatible(item):
			continue
		result.append(item)
	return result


static func _get_collectible_pool(
	rarity: PickupConfig.CollectibleRarity,
	filter_by_player_compatibility: bool,
	player: Player,
	character_id: StringName = &""
) -> Array[PickupConfig]:
	var result: Array[PickupConfig] = []
	for item in CollectibleRegistry.get_by_rarity(rarity):
		if not item.can_store_in_inventory or item.resource_path.is_empty():
			continue
		if filter_by_player_compatibility:
			var compatible := (
				player.is_collectible_compatible(item)
				if player != null
				else _is_collectible_compatible_with_character(item, character_id)
			)
			if not compatible:
				continue
		result.append(item)
	result.sort_custom(
		func(left: PickupConfig, right: PickupConfig) -> bool:
			return left.resource_path < right.resource_path
	)
	return result


static func _is_collectible_compatible_with_character(
	item: PickupConfig,
	character_id: StringName
) -> bool:
	if item == null or not PlayerCharacterRegistry.is_valid_character_id(character_id):
		return false
	# 当前角色兼容性合同仅区分弹药/投射物攻击。以稳定角色 ID 判定，
	# 让已离开战斗树的原始参战者仍可获得与其角色相容的奖励。
	var supports_ammunition := (
		PlayerCharacterRegistry.supports_ammunition_reward(character_id)
	)
	if item.requires_projectile_primary_attack and not supports_ammunition:
		return false
	if item.requires_ammunition and not supports_ammunition:
		return false
	return true


static func _build_peer_reward(
	occurrence_id: StringName,
	content_seed: int,
	peer_id: int,
	reward_config: RogueCombatRewardConfig,
	filter_by_player_compatibility: bool,
	player: Player,
	character_id: StringName,
	stable_key: String,
	inventory_snapshot: Dictionary
) -> Dictionary:
	var item_rewards: Array[Dictionary] = []
	var inventory_changed := false
	var pool := _get_collectible_pool(
		reward_config.collectible_rarity,
		filter_by_player_compatibility,
		player,
		character_id
	)
	if (
		reward_config.collectible_count > 0
		and (
			pool.is_empty()
			or (
				reward_config.deduplicate_collectibles
				and pool.size() < reward_config.collectible_count
			)
		)
	):
		return {
			"resolved": false,
			"failure_reason": FAILURE_NO_ELIGIBLE_COLLECTIBLE,
		}
	var identity := stable_key.strip_edges()
	if identity.is_empty():
		identity = "peer:%d" % peer_id
	var available_pool := pool.duplicate()
	for roll_index in range(reward_config.collectible_count):
		var source_pool: Array[PickupConfig] = (
			available_pool if reward_config.deduplicate_collectibles else pool
		)
		var chosen_index := RogueEncounterRandom.choose_index(
			content_seed,
			StringName("%s|occurrence:%s|identity:%s|contract:%s|roll:%d" % [
				_PARTY_ROLL_SALT_PREFIX,
				String(occurrence_id),
				identity,
				reward_config.compute_runtime_contract_hash(),
				roll_index,
			]),
			source_pool.size()
		)
		if chosen_index < 0:
			return {
				"resolved": false,
				"failure_reason": FAILURE_NO_ELIGIBLE_COLLECTIBLE,
			}
		var item: PickupConfig = source_pool[chosen_index]
		if reward_config.deduplicate_collectibles:
			available_pool.remove_at(chosen_index)
		var granted_count := _add_item_count_to_wire_inventory(
			inventory_snapshot,
			item,
			1
		)
		inventory_changed = inventory_changed or granted_count > 0
		item_rewards.append(_make_collectible_reward(item, granted_count > 0))

	for entry in reward_config.item_rewards:
		var granted_count := _add_item_count_to_wire_inventory(
			inventory_snapshot,
			entry.item,
			entry.count
		)
		inventory_changed = inventory_changed or granted_count > 0
		item_rewards.append(_make_fixed_item_reward(
			entry.item,
			entry.count,
			granted_count
		))
	var loot := (
		item_rewards[0].duplicate(true)
		if reward_config.collectible_count > 0
		else _make_empty_loot(FAILURE_NONE)
	)
	return {
		"resolved": true,
		"inventory_changed": inventory_changed,
		"occurrence_id": String(occurrence_id),
		"content_seed": content_seed,
		"peer_id": peer_id,
		"loot": loot,
		"item_rewards": item_rewards,
	}


## 逐项写入：空间不足时尽可能写入，剩余数量按需求直接丢失。
static func _add_item_count_to_wire_inventory(
	inventory_snapshot: Dictionary,
	item: PickupConfig,
	requested_count: int
) -> int:
	if (
		item == null
		or requested_count <= 0
		or not item.can_store_in_inventory
		or item.resource_path.is_empty()
	):
		return 0
	var slots := inventory_snapshot.get("slots", []) as Array
	var remaining := requested_count
	var stack_limit := PickupConfig.get_inventory_stack_limit(item)
	if item.stackable:
		for raw_slot_value in slots:
			if remaining <= 0:
				break
			var slot := raw_slot_value as Dictionary
			if str(slot.get("config_path", "")) != item.resource_path:
				continue
			var room := maxi(stack_limit - int(slot.get("stack_count", 0)), 0)
			var added := mini(room, remaining)
			slot["stack_count"] = int(slot.get("stack_count", 0)) + added
			remaining -= added
	for raw_slot_value in slots:
		if remaining <= 0:
			break
		var slot := raw_slot_value as Dictionary
		if not str(slot.get("config_path", "")).is_empty():
			continue
		var added := mini(stack_limit, remaining)
		slot["config_path"] = item.resource_path
		slot["stack_count"] = added
		remaining -= added
	return requested_count - remaining


static func _index_inventory_snapshots(party_snapshot: Dictionary) -> Dictionary:
	var result: Dictionary = {}
	for raw_snapshot_value in party_snapshot.get("inventories", []) as Array:
		if typeof(raw_snapshot_value) != TYPE_DICTIONARY:
			return {}
		var snapshot := raw_snapshot_value as Dictionary
		var peer_id := int(snapshot.get("peer_id", -1))
		if peer_id < 0 or result.has(peer_id):
			return {}
		result[peer_id] = snapshot
	return result


static func _normalize_peer_ids(peer_ids: Array[int]) -> Array[int]:
	var result: Array[int] = []
	for peer_id in peer_ids:
		if peer_id < 0 or result.has(peer_id):
			continue
		result.append(peer_id)
	result.sort()
	return result


static func _make_roll_salt(occurrence_id: StringName, peer_id: int) -> StringName:
	return StringName(
		"%s|occurrence:%s|peer:%d" % [
			_ROLL_SALT_PREFIX,
			String(occurrence_id),
			peer_id,
		]
	)


static func _make_loot(
	item: PickupConfig,
	granted: bool,
	failure_reason: StringName
) -> Dictionary:
	return {
		"config_path": item.resource_path,
		"id": item.resource_path.get_file().get_basename(),
		"name": item.display_name,
		"rarity": int(item.collectible_rarity),
		"rarity_name": PickupConfig.get_collectible_rarity_label(
			int(item.collectible_rarity)
		),
		"granted": granted,
		"failure_reason": failure_reason,
	}


static func _make_collectible_reward(item: PickupConfig, granted: bool) -> Dictionary:
	var result := _make_loot(
		item,
		granted,
		FAILURE_NONE if granted else FAILURE_INVENTORY_FULL
	)
	result["kind"] = "collectible"
	result["rolled_count"] = 1
	result["granted_count"] = 1 if granted else 0
	result["discarded_count"] = 0 if granted else 1
	return result


static func _make_fixed_item_reward(
	item: PickupConfig,
	rolled_count: int,
	granted_count: int
) -> Dictionary:
	return {
		"kind": "item",
		"config_path": item.resource_path,
		"id": item.resource_path.get_file().get_basename(),
		"name": item.display_name,
		"rarity": -1,
		"rarity_name": "物资",
		"rolled_count": rolled_count,
		"granted_count": granted_count,
		"discarded_count": maxi(rolled_count - granted_count, 0),
		"granted": granted_count > 0,
		"failure_reason": (
			FAILURE_NONE
			if granted_count == rolled_count
			else FAILURE_INVENTORY_FULL
		),
	}


static func _make_empty_loot(failure_reason: StringName) -> Dictionary:
	return {
		"config_path": "",
		"id": "",
		"name": "",
		"rarity": -1,
		"rarity_name": "",
		"granted": false,
		"failure_reason": failure_reason,
	}


static func _make_party_failure(failure_reason: StringName) -> Dictionary:
	return {
		"resolved": false,
		"failure_reason": failure_reason,
		"extra_xirang": 0,
		"results_by_peer": {},
		"final_xirang_by_peer": {},
		"inventory_snapshots_by_peer": {},
	}
