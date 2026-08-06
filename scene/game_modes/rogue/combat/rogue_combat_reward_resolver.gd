extends RefCounted
class_name RogueCombatRewardResolver

## Rouge 作战结算的权威收藏品解析器。
##
## 额外息壤只作为结算数据透传；真正的息壤发放、以及战斗中的击杀息壤，
## 由调用方在各自的权威流程中处理。

const FAILURE_NONE := &""
const FAILURE_INVALID_RUN_STATE := &"invalid_run_state"
const FAILURE_MISSING_COMPATIBILITY_PLAYER := &"missing_compatibility_player"
const FAILURE_NO_ELIGIBLE_COLLECTIBLE := &"no_eligible_collectible"
const FAILURE_INVENTORY_FULL := &"inventory_full"

const _ROLL_SALT_PREFIX := "rogue_combat_common_collectible"


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
