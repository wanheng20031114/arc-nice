@tool
extends Resource
class_name RogueCombatRewardConfig

const CONTRACT_SCHEMA := 1
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

@export_group("固定物品奖励")
@export var item_rewards: Array[RogueCombatRewardItemEntry] = []


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
	if collectible_count + item_rewards.size() > MAX_DISPLAY_REWARDS:
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
	])
	for entry_index in range(item_rewards.size()):
		var entry := item_rewards[entry_index]
		parts.append(
			"item=%d:%s" % [
				entry_index,
				entry.compute_contract_fragment() if entry != null else "",
			]
		)
	return "\n".join(parts).sha256_text()
