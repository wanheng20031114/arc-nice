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
const FAILURE_INVALID_REWARD_SELECTION := &"invalid_reward_selection"
const FAILURE_INCOMPLETE_REWARD_SELECTION := &"incomplete_reward_selection"
const FAILURE_TRANSACTION_CONFLICT := &"transaction_conflict"

const _ROLL_SALT_PREFIX := "rogue_combat_common_collectible"
const _PARTY_ROLL_SALT_PREFIX := "rogue_combat_collectible_batch"
const _EMERGENCY_RARITY_SALT_PREFIX := "rogue_emergency_collectible_rarity"
const _EMERGENCY_OFFER_SALT_PREFIX := "rogue_emergency_collectible_offer"
const _EMERGENCY_TIMEOUT_SALT_PREFIX := "rogue_emergency_collectible_timeout"
const _EMERGENCY_RESOURCE_SALT_PREFIX := "rogue_emergency_resource"


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
	if (
		reward_config == null
		or not reward_config.validate_config().is_empty()
		or reward_config.uses_collectible_choices()
	):
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


## 为紧急作战生成每名玩家的逐轮候选。玩家身份使用稳定键而非临时
## peer_id 进入 salt，因此断线重映射或主客机 peer 排列变化不会改签。
static func build_emergency_collectible_offers(
	occurrence_id: StringName,
	content_seed: int,
	peer_ids: Array[int],
	reward_config: RogueCombatRewardConfig,
	filter_by_player_compatibility: bool,
	stable_keys_by_peer: Dictionary,
	character_ids_by_peer: Dictionary = {}
) -> Dictionary:
	if (
		occurrence_id == &""
		or reward_config == null
		or not reward_config.validate_config().is_empty()
		or not reward_config.uses_collectible_choices()
	):
		return _make_emergency_offer_failure(FAILURE_INVALID_REWARD_CONFIG)
	var ordered_peer_ids := _normalize_peer_ids(peer_ids)
	if ordered_peer_ids.size() != peer_ids.size() or ordered_peer_ids.is_empty():
		return _make_emergency_offer_failure(FAILURE_INVALID_PARTICIPANTS)

	var identities: Dictionary = {}
	var seen_identities: Dictionary = {}
	for peer_id in ordered_peer_ids:
		var identity := str(stable_keys_by_peer.get(
			peer_id,
			stable_keys_by_peer.get(str(peer_id), "")
		)).strip_edges()
		var character_id := StringName(character_ids_by_peer.get(
			peer_id,
			character_ids_by_peer.get(str(peer_id), &"")
		))
		if (
			identity.is_empty()
			or seen_identities.has(identity)
			or (
				filter_by_player_compatibility
				and not PlayerCharacterRegistry.is_valid_character_id(character_id)
			)
		):
			return _make_emergency_offer_failure(FAILURE_INVALID_PARTICIPANTS)
		identities[peer_id] = identity
		seen_identities[identity] = true

	var offers_by_peer: Dictionary = {}
	var contract_hash := reward_config.compute_runtime_contract_hash()
	for peer_id in ordered_peer_ids:
		var identity := str(identities[peer_id])
		var character_id := StringName(character_ids_by_peer.get(
			peer_id,
			character_ids_by_peer.get(str(peer_id), &"")
		))
		var used_paths: Dictionary = {}
		var rounds: Array[Dictionary] = []
		for round_index in range(reward_config.collectible_choice_round_count):
			var rarity_choice := RogueEncounterRandom.choose_index(
				content_seed,
				StringName(
					"%s|occurrence:%s|identity:%s|contract:%s|round:%d"
					% [
						_EMERGENCY_RARITY_SALT_PREFIX,
						String(occurrence_id),
						identity,
						contract_hash,
						round_index,
					]
				),
				reward_config.collectible_choice_rarities.size()
			)
			if rarity_choice < 0:
				return _make_emergency_offer_failure(
					FAILURE_NO_ELIGIBLE_COLLECTIBLE
				)
			var rarity := int(
				reward_config.collectible_choice_rarities[rarity_choice]
			)
			var rarity_pool := _get_collectible_pool(
				rarity,
				filter_by_player_compatibility,
				null,
				character_id
			)
			var available: Array[PickupConfig] = []
			for item in rarity_pool:
				if (
					not reward_config.deduplicate_collectible_choices
					or not used_paths.has(item.resource_path)
				):
					available.append(item)
			if available.size() < reward_config.collectible_choice_offer_count:
				return _make_emergency_offer_failure(
					FAILURE_NO_ELIGIBLE_COLLECTIBLE
				)
			var paths: Array[String] = []
			for offer_index in range(
				reward_config.collectible_choice_offer_count
			):
				var chosen_index := RogueEncounterRandom.choose_index(
					content_seed,
					StringName(
						"%s|occurrence:%s|identity:%s|contract:%s|round:%d|offer:%d"
						% [
							_EMERGENCY_OFFER_SALT_PREFIX,
							String(occurrence_id),
							identity,
							contract_hash,
							round_index,
							offer_index,
						]
					),
					available.size()
				)
				if chosen_index < 0:
					return _make_emergency_offer_failure(
						FAILURE_NO_ELIGIBLE_COLLECTIBLE
					)
				var chosen := available[chosen_index]
				paths.append(chosen.resource_path)
				used_paths[chosen.resource_path] = true
				available.remove_at(chosen_index)
			rounds.append({
				"round_index": round_index,
				"rarity": rarity,
				"paths": paths,
			})
		offers_by_peer[peer_id] = rounds
	return {
		"resolved": true,
		"failure_reason": FAILURE_NONE,
		"offers_by_peer": offers_by_peer,
	}


## 紧急作战的基础物资按场次抽一次，所有玩家复用同一结果。
static func roll_random_item_reward(
	occurrence_id: StringName,
	content_seed: int,
	reward_config: RogueCombatRewardConfig
) -> PickupConfig:
	if (
		occurrence_id == &""
		or reward_config == null
		or not reward_config.validate_config().is_empty()
		or not reward_config.uses_random_item_reward()
	):
		return null
	var pool: Array[PickupConfig] = []
	for item in reward_config.random_item_reward_pool:
		if item != null:
			pool.append(item)
	pool.sort_custom(
		func(left: PickupConfig, right: PickupConfig) -> bool:
			return left.resource_path < right.resource_path
	)
	var chosen_index := RogueEncounterRandom.choose_index(
		content_seed,
		StringName("%s|occurrence:%s|contract:%s" % [
			_EMERGENCY_RESOURCE_SALT_PREFIX,
			String(occurrence_id),
			reward_config.compute_runtime_contract_hash(),
		]),
		pool.size()
	)
	return pool[chosen_index] if chosen_index >= 0 else null


static func select_emergency_timeout_offer_index(
	occurrence_id: StringName,
	content_seed: int,
	stable_identity: String,
	round_index: int,
	reward_config: RogueCombatRewardConfig
) -> int:
	var identity := stable_identity.strip_edges()
	if (
		occurrence_id == &""
		or identity.is_empty()
		or reward_config == null
		or not reward_config.validate_config().is_empty()
		or not reward_config.uses_collectible_choices()
		or round_index < 0
		or round_index >= reward_config.collectible_choice_round_count
	):
		return -1
	return RogueEncounterRandom.choose_index(
		content_seed,
		StringName(
			"%s|occurrence:%s|identity:%s|contract:%s|round:%d" % [
				_EMERGENCY_TIMEOUT_SALT_PREFIX,
				String(occurrence_id),
				identity,
				reward_config.compute_runtime_contract_hash(),
				round_index,
			]
		),
		reward_config.collectible_choice_offer_count
	)


## 选择阶段的只读容量预检。此前已选收藏品与本场固定随机物资一起模拟，
## 保证第二轮确认后最终原子事务不会因为已知容量不足才被迫丢弃奖励。
static func preflight_emergency_peer_rewards(
	run_state: RunStateStore,
	peer_id: int,
	selected_collectible_paths: Array[String],
	random_item: PickupConfig,
	random_item_count: int
) -> Dictionary:
	if run_state == null or peer_id < 0:
		return {
			"can_commit": false,
			"failure_reason": FAILURE_INVALID_RUN_STATE,
		}
	var items: Array[PickupConfig] = []
	var counts: Array[int] = []
	var seen_paths: Dictionary = {}
	for config_path in selected_collectible_paths:
		var item := CollectibleRegistry.get_for_path(config_path)
		if (
			item == null
			or not CollectibleRegistry.is_standard_random_collectible(item)
			or seen_paths.has(config_path)
		):
			return {
				"can_commit": false,
				"failure_reason": FAILURE_INVALID_REWARD_SELECTION,
			}
		seen_paths[config_path] = true
		items.append(item)
		counts.append(1)
	if random_item_count > 0:
		if (
			random_item == null
			or random_item.pickup_type != PickupConfig.PickupType.MATERIAL
			or not random_item.can_store_in_inventory
		):
			return {
				"can_commit": false,
				"failure_reason": FAILURE_INVALID_REWARD_CONFIG,
			}
		items.append(random_item)
		counts.append(random_item_count)
	var can_commit := (
		run_state.can_add_item_counts(items, counts)
		if peer_id == 0
		else run_state.can_add_item_counts_for_peer(peer_id, items, counts)
	)
	return {
		"can_commit": can_commit,
		"failure_reason": FAILURE_NONE if can_commit else FAILURE_INVENTORY_FULL,
	}


## 所有选择完成后，以一次 Party Economy CAS 提交在线玩家的收藏品、同种物资、
## 全员同额息壤及一次共享光石。选择阶段断线者放弃尚未入包的全部物品，但仍
## 获得息壤，且不会因离线背包已满而阻塞在线玩家结算。在线玩家背包无法完整
## 容纳时整笔不写入，可整理后重试。
static func commit_emergency_party_rewards(
	run_state: RunStateStore,
	occurrence_id: StringName,
	content_seed: int,
	peer_ids: Array[int],
	reward_config: RogueCombatRewardConfig,
	filter_by_player_compatibility: bool,
	stable_keys_by_peer: Dictionary,
	character_ids_by_peer: Dictionary,
	base_xirang_by_peer: Dictionary,
	selected_paths_by_peer: Dictionary,
	forfeited_peer_ids: Array[int] = []
) -> Dictionary:
	if run_state == null:
		return _make_emergency_party_failure(FAILURE_INVALID_RUN_STATE)
	if (
		occurrence_id == &""
		or reward_config == null
		or not reward_config.validate_config().is_empty()
		or not reward_config.uses_collectible_choices()
		or not reward_config.uses_random_item_reward()
	):
		return _make_emergency_party_failure(FAILURE_INVALID_REWARD_CONFIG)
	var ordered_peer_ids := _normalize_peer_ids(peer_ids)
	if ordered_peer_ids.size() != peer_ids.size() or ordered_peer_ids.is_empty():
		return _make_emergency_party_failure(FAILURE_INVALID_PARTICIPANTS)
	var forfeited: Dictionary = {}
	for peer_id in forfeited_peer_ids:
		if peer_id not in ordered_peer_ids or forfeited.has(peer_id):
			return _make_emergency_party_failure(FAILURE_INVALID_PARTICIPANTS)
		forfeited[peer_id] = true

	var offer_result := build_emergency_collectible_offers(
		occurrence_id,
		content_seed,
		ordered_peer_ids,
		reward_config,
		filter_by_player_compatibility,
		stable_keys_by_peer,
		character_ids_by_peer
	)
	if not bool(offer_result.get("resolved", false)):
		return _make_emergency_party_failure(StringName(
			offer_result.get("failure_reason", FAILURE_INVALID_REWARD_CONFIG)
		))
	var offers_by_peer := offer_result["offers_by_peer"] as Dictionary
	var normalized_selected_paths: Dictionary = {}
	for peer_id in ordered_peer_ids:
		if (
			not base_xirang_by_peer.has(peer_id)
			or typeof(base_xirang_by_peer[peer_id]) != TYPE_INT
			or int(base_xirang_by_peer[peer_id]) < 0
		):
			return _make_emergency_party_failure(FAILURE_INVALID_PARTICIPANTS)
		var raw_paths := selected_paths_by_peer.get(
			peer_id,
			selected_paths_by_peer.get(str(peer_id), [])
		) as Array
		if (
			raw_paths.size() > reward_config.collectible_choice_round_count
			or (
				not forfeited.has(peer_id)
				and raw_paths.size()
				!= reward_config.collectible_choice_round_count
			)
		):
			return _make_emergency_party_failure(
				FAILURE_INCOMPLETE_REWARD_SELECTION
			)
		var paths: Array[String] = []
		var seen_paths: Dictionary = {}
		var peer_rounds := offers_by_peer[peer_id] as Array
		for round_index in range(raw_paths.size()):
			if typeof(raw_paths[round_index]) != TYPE_STRING:
				return _make_emergency_party_failure(
					FAILURE_INVALID_REWARD_SELECTION
				)
			var config_path := str(raw_paths[round_index])
			var round_paths := (
				(peer_rounds[round_index] as Dictionary).get("paths", []) as Array
			)
			if config_path not in round_paths or seen_paths.has(config_path):
				return _make_emergency_party_failure(
					FAILURE_INVALID_REWARD_SELECTION
				)
			seen_paths[config_path] = true
			paths.append(config_path)
		normalized_selected_paths[peer_id] = paths

	var random_item := roll_random_item_reward(
		occurrence_id,
		content_seed,
		reward_config
	)
	if random_item == null:
		return _make_emergency_party_failure(FAILURE_INVALID_REWARD_CONFIG)
	var packed_peer_ids := PackedInt32Array()
	for peer_id in ordered_peer_ids:
		packed_peer_ids.append(peer_id)
	var party_snapshot := run_state.export_party_economy_snapshot(packed_peer_ids)
	var next_snapshot := party_snapshot.duplicate(true)
	var current_inventories := _index_inventory_snapshots(party_snapshot)
	var next_inventories := _index_inventory_snapshots(next_snapshot)
	if (
		current_inventories.size() != ordered_peer_ids.size()
		or next_inventories.size() != ordered_peer_ids.size()
	):
		return _make_emergency_party_failure(FAILURE_INVALID_PARTICIPANTS)

	var expected_inventory_revisions: Dictionary = {}
	var results_by_peer: Dictionary = {}
	for peer_id in ordered_peer_ids:
		var current_inventory := current_inventories[peer_id] as Dictionary
		var next_inventory := next_inventories[peer_id] as Dictionary
		var expected_revision := int(current_inventory.get("revision", -1))
		expected_inventory_revisions[peer_id] = expected_revision
		var item_results: Array[Dictionary] = []
		if forfeited.has(peer_id):
			results_by_peer[peer_id] = {
				"occurrence_id": String(occurrence_id),
				"content_seed": content_seed,
				"peer_id": peer_id,
				"extra_xirang": 0,
				"loot": _make_empty_loot(FAILURE_NONE),
				"item_rewards": item_results,
				"reward_selection_forfeited": true,
			}
			continue
		for config_path in normalized_selected_paths[peer_id] as Array[String]:
			var collectible := CollectibleRegistry.get_for_path(config_path)
			if _add_item_count_to_wire_inventory(next_inventory, collectible, 1) != 1:
				return _make_emergency_party_failure(
					FAILURE_INVENTORY_FULL,
					[peer_id]
				)
			item_results.append(_make_collectible_reward(collectible, true))
		for entry in reward_config.item_rewards:
			if (
				_add_item_count_to_wire_inventory(
					next_inventory,
					entry.item,
					entry.count
				) != entry.count
			):
				return _make_emergency_party_failure(
					FAILURE_INVENTORY_FULL,
					[peer_id]
				)
			item_results.append(_make_fixed_item_reward(
				entry.item,
				entry.count,
				entry.count
			))
		if (
			_add_item_count_to_wire_inventory(
				next_inventory,
				random_item,
				reward_config.random_item_reward_count
			) != reward_config.random_item_reward_count
		):
			return _make_emergency_party_failure(
				FAILURE_INVENTORY_FULL,
				[peer_id]
			)
		item_results.append(_make_fixed_item_reward(
			random_item,
			reward_config.random_item_reward_count,
			reward_config.random_item_reward_count
		))
		next_inventory["revision"] = expected_revision + 1
		results_by_peer[peer_id] = {
			"occurrence_id": String(occurrence_id),
			"content_seed": content_seed,
			"peer_id": peer_id,
			"extra_xirang": 0,
			"loot": (
				item_results[0].duplicate(true)
				if not item_results.is_empty()
				else _make_empty_loot(FAILURE_NONE)
			),
			"item_rewards": item_results,
			"reward_selection_forfeited": false,
		}

	var extra_xirang := reward_config.roll_xirang(content_seed, occurrence_id)
	var final_xirang_by_peer: Dictionary = {}
	var current_xirang := party_snapshot.get("xirang_ledger", {}) as Dictionary
	var next_xirang := current_xirang.duplicate(true)
	var next_xirang_values := next_xirang.get("values", {}) as Dictionary
	var xirang_changed := false
	for peer_id in ordered_peer_ids:
		var amount := int(base_xirang_by_peer[peer_id]) + extra_xirang
		final_xirang_by_peer[peer_id] = amount
		(results_by_peer[peer_id] as Dictionary)["extra_xirang"] = extra_xirang
		var peer_key := str(peer_id)
		if int(next_xirang_values.get(peer_key, 0)) != amount:
			next_xirang_values[peer_key] = amount
			xirang_changed = true
	next_xirang["values"] = next_xirang_values
	if xirang_changed:
		next_xirang["revision"] = int(current_xirang.get("revision", -1)) + 1

	var current_light := party_snapshot.get("light_stone_ledger", {}) as Dictionary
	var next_light: Dictionary = {}
	if reward_config.shared_light_stone_reward > 0:
		next_light = current_light.duplicate(true)
		next_light["revision"] = int(current_light.get("revision", -1)) + 1
		next_light["amount"] = (
			int(current_light.get("amount", 0))
			+ reward_config.shared_light_stone_reward
		)
	var warehouse := party_snapshot.get("warehouse_ledger", {}) as Dictionary
	if not run_state.apply_authoritative_party_transaction(
		next_snapshot,
		int(warehouse.get("revision", -1)),
		expected_inventory_revisions,
		int(current_xirang.get("revision", -1)),
		next_xirang,
		-1,
		{},
		int(current_light.get("revision", -1)) if not next_light.is_empty() else -1,
		next_light
	):
		return _make_emergency_party_failure(FAILURE_TRANSACTION_CONFLICT)
	return {
		"resolved": true,
		"failure_reason": FAILURE_NONE,
		"extra_xirang": extra_xirang,
		"random_item_path": random_item.resource_path,
		"random_item_count": reward_config.random_item_reward_count,
		"shared_light_stone_reward": reward_config.shared_light_stone_reward,
		"light_stone_ledger": (
			next_light.duplicate(true)
			if not next_light.is_empty()
			else current_light.duplicate(true)
		),
		"results_by_peer": results_by_peer,
		"final_xirang_by_peer": final_xirang_by_peer,
		"inventory_snapshots_by_peer": next_inventories,
		"forfeited_peer_ids": forfeited_peer_ids.duplicate(),
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


static func _make_emergency_offer_failure(
	failure_reason: StringName
) -> Dictionary:
	return {
		"resolved": false,
		"failure_reason": failure_reason,
		"offers_by_peer": {},
	}


static func _make_emergency_party_failure(
	failure_reason: StringName,
	inventory_full_peer_ids: Array[int] = []
) -> Dictionary:
	return {
		"resolved": false,
		"failure_reason": failure_reason,
		"extra_xirang": 0,
		"random_item_path": "",
		"random_item_count": 0,
		"shared_light_stone_reward": 0,
		"light_stone_ledger": {},
		"results_by_peer": {},
		"final_xirang_by_peer": {},
		"inventory_snapshots_by_peer": {},
		"forfeited_peer_ids": [],
		"inventory_full_peer_ids": inventory_full_peer_ids.duplicate(),
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
