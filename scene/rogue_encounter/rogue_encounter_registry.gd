extends RefCounted
class_name RogueEncounterRegistry

const MAGICAL_ENCOUNTER_POOL := &"magical_encounter"

const CHICKEN_BRO := &"chicken_bro"
const SLIME_TALKERS := &"slime_talkers"

const OPTION_PURCHASE_BASKETBALL := &"purchase_basketball"
const OPTION_ASK_FOR_FREE := &"ask_for_free"
const OPTION_HELP_SLIMES := &"help_slimes"
const OPTION_KICK_SLIMES := &"kick_slimes"
const OPTION_LEAVE_SLIMES := &"leave_slimes"

const MAX_VISIBLE_OPTIONS := 3

## UI 内容只保存可由所有客户端从 encounter_id 确定的数据。投票可用性、
## 奖励结果和 result_pages 仍由房主快照提供，避免客户端自行推导权威状态。
const _CONTENT_CONFIGS := {
	CHICKEN_BRO: {
		"display_name": "鸡哥",
		"portrait_texture_path": (
			"res://resources/texture/rogue_encounter/chicken_bro.png"
		),
		"encounter_hint": "地下遗址里的神秘来客",
		"intro_speaker": "鸡哥",
		"intro_text": "鸡哥：练习时长2年半，会唱跳rap篮球。",
		"intro_is_narration": false,
		"resolving_speaker": "",
		"resolving_text": "鸡哥正在盘算……",
		"resolving_is_narration": true,
		"result_status": "鸡哥已经作出回应",
		"default_result_speaker": "鸡哥",
		"default_result_is_narration": false,
		"options": [
			{
				"option_id": OPTION_PURCHASE_BASKETBALL,
				"title": "购买篮球",
				"description": "花费10个木板购买一个篮球",
				"icon_texture_path": (
					"res://resources/texture/collectibles/basketball.png"
				),
			},
			{
				"option_id": OPTION_ASK_FOR_FREE,
				"title": "为什么不能0元购？",
				"description": "鸡哥有概率被你说服",
				"icon_texture_path": "",
			},
		],
	},
	SLIME_TALKERS: {
		"display_name": "会说话的史莱姆",
		"portrait_texture_path": (
			"res://resources/texture/rogue_encounter/talking_slime_group.png"
		),
		"encounter_hint": "聚在地下遗址里的奇妙生物",
		"intro_speaker": "",
		"intro_text": "你遇到了一群会说话的史莱姆",
		"intro_is_narration": true,
		"resolving_speaker": "",
		"resolving_text": "史莱姆们正在窃窃私语……",
		"resolving_is_narration": true,
		"result_status": "这次相遇已经有了结果",
		"default_result_speaker": "",
		"default_result_is_narration": true,
		"options": [
			{
				"option_id": OPTION_HELP_SLIMES,
				"title": "给予一些帮助",
				"description": "赠予这些史莱姆10个水瓶",
				"icon_texture_path": (
					"res://resources/texture/materials/water_bottle.png"
				),
			},
			{
				"option_id": OPTION_KICK_SLIMES,
				"title": "一脚踢死",
				"description": "杀死这些史莱姆",
				"icon_texture_path": "",
			},
			{
				"option_id": OPTION_LEAVE_SLIMES,
				"title": "这和我有什么关系？",
				"description": "离开该节点",
				"icon_texture_path": "",
			},
		],
	},
}

const _POOLS := {
	MAGICAL_ENCOUNTER_POOL: [CHICKEN_BRO, SLIME_TALKERS],
}


static func select_encounter(
	content_pool_id: StringName,
	node_content_seed: int
) -> StringName:
	var raw_entries: Variant = _POOLS.get(content_pool_id)
	if typeof(raw_entries) != TYPE_ARRAY:
		return &""
	var entries := raw_entries as Array
	if entries.is_empty():
		return &""
	var index := RogueEncounterRandom.choose_index(
		node_content_seed,
		&"content_selection",
		entries.size()
	)
	return StringName(entries[index])


static func has_pool(content_pool_id: StringName) -> bool:
	return _POOLS.has(content_pool_id)


static func get_pool_entries(content_pool_id: StringName) -> Array[StringName]:
	var result: Array[StringName] = []
	var raw_entries: Variant = _POOLS.get(content_pool_id)
	if typeof(raw_entries) != TYPE_ARRAY:
		return result
	for entry in raw_entries as Array:
		result.append(StringName(entry))
	return result


static func has_encounter(encounter_id: StringName) -> bool:
	return _CONTENT_CONFIGS.has(encounter_id)


static func get_encounter_config(encounter_id: StringName) -> Dictionary:
	var raw_config: Variant = _CONTENT_CONFIGS.get(encounter_id)
	if typeof(raw_config) != TYPE_DICTIONARY:
		return {}
	return (raw_config as Dictionary).duplicate(true)


## 权威 Session 使用的稳定命名；get_encounter_config 保留给表现层直读。
static func get_definition(encounter_id: StringName) -> Dictionary:
	return get_encounter_config(encounter_id)


static func get_option_configs(encounter_id: StringName) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var config := get_encounter_config(encounter_id)
	var raw_options: Variant = config.get("options", [])
	if typeof(raw_options) != TYPE_ARRAY:
		return result
	for raw_option in raw_options as Array:
		if typeof(raw_option) == TYPE_DICTIONARY:
			result.append((raw_option as Dictionary).duplicate(true))
	return result


static func get_option_ids(encounter_id: StringName) -> Array[StringName]:
	var result: Array[StringName] = []
	for option in get_option_configs(encounter_id):
		var option_id := StringName(option.get("option_id", &""))
		if not option_id.is_empty():
			result.append(option_id)
	return result


static func is_valid_option(
	encounter_id: StringName,
	option_id: StringName
) -> bool:
	return not option_id.is_empty() and get_option_ids(encounter_id).has(option_id)
