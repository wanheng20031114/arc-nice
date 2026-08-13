@tool
extends Resource
class_name RogueCombatRewardConfig

const CONTRACT_SCHEMA := 2
const MAX_DISPLAY_REWARDS := 3

@export_group("息壤奖励")
@export_range(0, 999999, 1, "or_greater") var xirang_minimum: int = 0
@export_range(0, 999999, 1, "or_greater") var xirang_maximum: int = 0
@export_range(1, 999999, 1, "or_greater") var xirang_step: int = 1

@export_group("收藏品奖励")
@export_range(0, 20, 1, "or_greater") var collectible_count: int = 0
@export var collectible_rarity: PickupConfig.CollectibleRarity = (
	PickupConfig.CollectibleRarity.COMMON
)
@export var deduplicate_collectibles: bool = true

@export_group("收藏品选择奖励")
## 0 表示沿用直接发放；大于0时由奖励选择会话逐轮提交选择。
@export_range(0, 20, 1, "or_greater") var collectible_choice_round_count: int = 0
@export_range(2, 8, 1, "or_greater") var collectible_choice_offer_count: int = 2
@export_range(1.0, 3600.0, 0.1, "or_greater")
var collectible_choice_seconds_per_round: float = 30.0
## 每轮先等概率抽取一个品质，再从该品质中无放回生成本轮候选。
@export var collectible_choice_rarities: PackedInt32Array = PackedInt32Array()
@export var deduplicate_collectible_choices: bool = true

@export_group("固定物品奖励")
@export var item_rewards: Array[RogueCombatRewardItemEntry] = []

@export_group("随机物资奖励")
## 每场只抽取一次，全体玩家获得同一种物资与相同数量。
@export var random_item_reward_pool: Array[PickupConfig] = []
@export_range(0, 999, 1, "or_greater") var random_item_reward_count: int = 0

@export_group("全队共享奖励")
@export_range(0, 999, 1, "or_greater") var shared_light_stone_reward: int = 0


func validate_config() -> PackedStringArray:
	var errors := PackedStringArray()
	if xirang_minimum < 0:
		errors.append("作战息壤奖励下限不能为负数。")
	if xirang_maximum < xirang_minimum:
		errors.append("作战息壤奖励上限不能小于下限。")
	if xirang_step <= 0:
		errors.append("作战息壤奖励步长必须大于0。")
	elif (xirang_maximum - xirang_minimum) % xirang_step != 0:
		errors.append("作战息壤奖励范围必须能被步长整除。")
	if collectible_count < 0:
		errors.append("作战收藏品奖励数量不能为负数。")
	if collectible_choice_round_count < 0:
		errors.append("作战收藏品选择轮数不能为负数。")
	elif collectible_choice_round_count > 0:
		if collectible_count > 0:
			errors.append("作战收藏品直接奖励与选择奖励不能同时启用。")
		if collectible_choice_offer_count < 2:
			errors.append("作战收藏品每轮至少需要两个候选。")
		if collectible_choice_seconds_per_round <= 0.0:
			errors.append("作战收藏品每轮选择时间必须大于0秒。")
		if collectible_choice_rarities.is_empty():
			errors.append("作战收藏品选择奖励至少需要一个候选品质。")
		var seen_rarities: Dictionary = {}
		for rarity in collectible_choice_rarities:
			if rarity in seen_rarities:
				errors.append("作战收藏品选择品质不能重复：%d。" % rarity)
				continue
			seen_rarities[rarity] = true
			if rarity < PickupConfig.CollectibleRarity.COMMON or rarity > PickupConfig.CollectibleRarity.LEGENDARY:
				errors.append("作战收藏品选择品质无效：%d。" % rarity)
	var random_reward_rows := 1 if random_item_reward_count > 0 else 0
	if (
		collectible_count
		+ collectible_choice_round_count
		+ item_rewards.size()
		+ random_reward_rows
		> MAX_DISPLAY_REWARDS
	):
		errors.append("作战结算最多支持%d条物品奖励。" % MAX_DISPLAY_REWARDS)
	if int(collectible_rarity) not in PickupConfig.CollectibleRarity.values():
		errors.append("作战收藏品奖励稀有度无效。")
	var seen_item_paths: Dictionary = {}
	for entry_index in range(item_rewards.size()):
		var entry := item_rewards[entry_index]
		if entry == null:
			errors.append("作战固定物品奖励条目%d为空。" % (entry_index + 1))
			continue
		errors.append_array(entry.validate_entry())
		if entry.item == null:
			continue
		var item_path := entry.item.resource_path
		if item_path.is_empty():
			errors.append("作战固定物品奖励条目%d必须引用磁盘资源。" % (entry_index + 1))
		elif seen_item_paths.has(item_path):
			errors.append("作战固定物品奖励不能重复配置：%s。" % item_path)
		else:
			seen_item_paths[item_path] = true
	if random_item_reward_count < 0:
		errors.append("作战随机物资奖励数量不能为负数。")
	elif random_item_reward_count == 0 and not random_item_reward_pool.is_empty():
		errors.append("作战随机物资池非空时奖励数量必须大于0。")
	elif random_item_reward_count > 0 and random_item_reward_pool.is_empty():
		errors.append("作战随机物资奖励缺少候选池。")
	var seen_random_item_paths: Dictionary = {}
	for item in random_item_reward_pool:
		if item == null:
			errors.append("作战随机物资池包含空配置。")
			continue
		var item_path := item.resource_path
		if (
			item.pickup_type != PickupConfig.PickupType.MATERIAL
			or not item.can_store_in_inventory
			or item_path.is_empty()
		):
			errors.append("作战随机物资必须是可入包的磁盘 MATERIAL：%s。" % item_path)
		elif seen_random_item_paths.has(item_path):
			errors.append("作战随机物资池不能重复配置：%s。" % item_path)
		else:
			seen_random_item_paths[item_path] = true
	if shared_light_stone_reward < 0:
		errors.append("作战共享光石奖励不能为负数。")
	return errors


func roll_xirang(content_seed: int, occurrence_id: StringName) -> int:
	if not validate_config().is_empty():
		return 0
	var choice_count := 1 + (xirang_maximum - xirang_minimum) / xirang_step
	var choice_index := RogueEncounterRandom.choose_index(
		content_seed,
		StringName("rogue_combat_xirang|occurrence:%s|contract:%s" % [
			String(occurrence_id),
			compute_runtime_contract_hash(),
		]),
		choice_count
	)
	return xirang_minimum + maxi(choice_index, 0) * xirang_step


func compute_runtime_contract_hash() -> String:
	var parts := PackedStringArray([
		"schema=%d" % CONTRACT_SCHEMA,
		"resource_path=%s" % resource_path,
		"xirang=%d:%d:%d" % [xirang_minimum, xirang_maximum, xirang_step],
		"collectibles=%d:%d:%d" % [
			collectible_count,
			int(collectible_rarity),
			int(deduplicate_collectibles),
		],
		"collectible_choices=%d:%d:%.3f:%s:%d" % [
			collectible_choice_round_count,
			collectible_choice_offer_count,
			collectible_choice_seconds_per_round,
			_collectible_choice_rarity_fragment(),
			int(deduplicate_collectible_choices),
		],
		"random_item_count=%d" % random_item_reward_count,
		"shared_light_stone=%d" % shared_light_stone_reward,
	])
	for entry_index in range(item_rewards.size()):
		var entry := item_rewards[entry_index]
		parts.append(
			"item=%d:%s" % [
				entry_index,
				entry.compute_contract_fragment() if entry != null else "",
			]
		)
	for item_index in range(random_item_reward_pool.size()):
		var item := random_item_reward_pool[item_index]
		parts.append(
			"random_item=%d:%s" % [
				item_index,
				item.resource_path if item != null else "",
			]
		)
	return "\n".join(parts).sha256_text()


func uses_collectible_choices() -> bool:
	return collectible_choice_round_count > 0


func uses_random_item_reward() -> bool:
	return random_item_reward_count > 0 and not random_item_reward_pool.is_empty()


func _collectible_choice_rarity_fragment() -> String:
	var parts := PackedStringArray()
	for rarity in collectible_choice_rarities:
		parts.append(str(rarity))
	return ",".join(parts)
