extends RefCounted
class_name RogueEncounterRegistry

const MAGICAL_ENCOUNTER_POOL := &"magical_encounter"
const RUNTIME_CONTRACT_SCHEMA := 1

const CHICKEN_BRO := &"chicken_bro"
const SLIME_TALKERS := &"slime_talkers"
const GHOST_SHADOW := &"ghost_shadow"
const FLUORESCENT_PIT := &"fluorescent_pit"
const SUITCASE_FRENZY := &"suitcase_frenzy"
const INVISIBLE_SEA_CUCUMBER := &"invisible_sea_cucumber"

const OPTION_PURCHASE_BASKETBALL := &"purchase_basketball"
const OPTION_ASK_FOR_FREE := &"ask_for_free"
const OPTION_HELP_SLIMES := &"help_slimes"
const OPTION_KICK_SLIMES := &"kick_slimes"
const OPTION_LEAVE_SLIMES := &"leave_slimes"
const OPTION_GHOST_RUN_AWAY := &"ghost_run_away"
const OPTION_GHOST_WHO_ARE_YOU := &"ghost_who_are_you"
const OPTION_EXPLORE_PIT := &"explore_pit"
const OPTION_LEAVE_PIT := &"leave_pit"
const OPTION_CLAIM_SUITCASE := &"claim_suitcase"
const OPTION_JOIN_SUITCASE_SHOOTING := &"join_suitcase_shooting"
const OPTION_IGNORE_SUITCASE := &"ignore_suitcase"
const OPTION_STOMP_SEA_CUCUMBER := &"stomp_sea_cucumber"
const OPTION_GIVE_GOLD_WINE_CUP := &"give_gold_wine_cup"
const OPTION_COOK_SEA_CUCUMBER := &"cook_sea_cucumber"

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
	GHOST_SHADOW: {
		"display_name": "鬼影",
		"portrait_texture_path": (
			"res://resources/texture/rogue_encounter/ghost_shadow.png"
		),
		"encounter_hint": "",
		"intro_speaker": "",
		"intro_text": "你遇到了一个鬼影",
		"intro_is_narration": true,
		"resolving_speaker": "",
		"resolving_text": "鬼影正在消散……",
		"resolving_is_narration": true,
		"result_status": "鬼影已经离开",
		"default_result_speaker": "",
		"default_result_is_narration": true,
		"options": [
			{
				"option_id": OPTION_GHOST_RUN_AWAY,
				"title": "逃跑",
				"description": "鬼知道会发生什么，赶快逃",
				"icon_texture_path": "",
			},
			{
				"option_id": OPTION_GHOST_WHO_ARE_YOU,
				"title": "你是？",
				"description": "",
				"icon_texture_path": "",
			},
		],
	},
	FLUORESCENT_PIT: {
		"display_name": "荧光坑洞",
		"portrait_texture_path": (
			"res://resources/texture/rogue_encounter/fluorescent_pit.png"
		),
		"encounter_hint": "深不见底的遗址裂隙",
		"intro_speaker": "",
		"intro_text": "一道幽蓝的微光从坑洞深处传来",
		"intro_is_narration": true,
		"resolving_speaker": "",
		"resolving_text": "众人正小心翼翼地向下探寻……",
		"resolving_is_narration": true,
		"result_status": "坑洞深处传来了新的动静",
		"default_result_speaker": "",
		"default_result_is_narration": true,
		"requires_result_ack": true,
		"options": [
			{
				"option_id": OPTION_EXPLORE_PIT,
				"title": "往下探探！",
				"description": "谁也无法阻挡我们的好奇心！",
				"icon_texture_path": "",
			},
			{
				"option_id": OPTION_LEAVE_PIT,
				"title": "还是先走吧",
				"description": "这么深的坑还是别继续了",
				"icon_texture_path": "",
			},
		],
	},
	SUITCASE_FRENZY: {
		"display_name": "疯穿箱子",
		"portrait_texture_path": (
			"res://resources/texture/rogue_encounter/suitcase_frenzy.png"
		),
		"encounter_hint": "失控机器人围住的神秘皮箱",
		# intro_text 三字段保留给旧表现层；新表现层优先读取 intro_pages。
		"intro_speaker": "",
		"intro_text": "发现了一群失控的战斗机器人正在开枪疯穿箱子。",
		"intro_is_narration": true,
		"intro_pages": [
			{
				"speaker": "",
				"text": "发现了一群失控的战斗机器人正在开枪疯穿箱子。",
				"is_narration": true,
			},
			{
				"speaker": "",
				"text": "也不知道这皮箱有什么特别的",
				"is_narration": true,
			},
		],
		"resolving_speaker": "",
		"resolving_text": "机器人们仍在疯狂开火……",
		"resolving_is_narration": true,
		"result_status": "这次遭遇已经有了结果",
		"default_result_speaker": "",
		"default_result_is_narration": true,
		# 开火结果必须等所有当轮在线玩家读完，才能衔接特殊作战简报。
		"requires_result_ack": true,
		# 全员超时不得随机把队伍送入高难作战，固定采用安全离开。
		"no_vote_option_id": OPTION_IGNORE_SUITCASE,
		"options": [
			{
				"option_id": OPTION_CLAIM_SUITCASE,
				"title": "箱子是我的！",
				"description": "朝着机器人开火",
				"icon_texture_path": "",
			},
			{
				"option_id": OPTION_JOIN_SUITCASE_SHOOTING,
				"title": "凑热闹！",
				"description": "跟着一起射击皮箱！",
				"icon_texture_path": "",
			},
			{
				"option_id": OPTION_IGNORE_SUITCASE,
				"title": "一个皮箱有什么好在意的！",
				"description": "趁没被机器人发现前离开",
				"icon_texture_path": "",
			},
		],
	},
	INVISIBLE_SEA_CUCUMBER: {
		"display_name": "隐形海参",
		"portrait_texture_path": (
			"res://resources/texture/rogue_encounter/invisible_sea_cucumber.png"
		),
		"encounter_hint": "",
		"intro_speaker": "",
		"intro_text": "你注意到了隐形的海参",
		"intro_is_narration": true,
		"resolving_speaker": "",
		"resolving_text": "隐形的海参正在等待你的决定……",
		"resolving_is_narration": true,
		"result_status": "这次相遇已经有了结果",
		"default_result_speaker": "",
		"default_result_is_narration": true,
		# 结果页由玩家主动点击推进；房主等待当轮所有玩家读完再离开。
		"manual_result_page_advance": true,
		"requires_result_ack": true,
		"options": [
			{
				"option_id": OPTION_STOMP_SEA_CUCUMBER,
				"title": "什么路边玩意",
				"description": "直接一脚踩死",
				"icon_texture_path": "",
			},
			{
				"option_id": OPTION_GIVE_GOLD_WINE_CUP,
				"title": "给他一个奖杯",
				"description": "",
				"icon_texture_path": (
					"res://resources/texture/collectibles/gold_wine_cup.png"
				),
			},
			{
				"option_id": OPTION_COOK_SEA_CUCUMBER,
				"title": "海鲜大餐真不错！",
				"description": "管他会不会隐身直接做成海线大餐！",
				"icon_texture_path": "",
			},
		],
	},
}

const _POOLS := {
	MAGICAL_ENCOUNTER_POOL: [
		CHICKEN_BRO,
		SLIME_TALKERS,
		GHOST_SHADOW,
		FLUORESCENT_PIT,
		SUITCASE_FRENZY,
		INVISIBLE_SEA_CUCUMBER,
	],
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


## 房主基于本局权威历史抽取尚未遭遇过的内容。候选始终沿注册表稳定顺序
## 过滤，因而相同 seed 与相同历史跨平台可复算；全部耗尽后固定回退鬼影。
static func select_encounter_for_run(
	content_pool_id: StringName,
	node_content_seed: int,
	encountered_ids: Array[StringName]
) -> StringName:
	var available: Array[StringName] = []
	for encounter_id in get_pool_entries(content_pool_id):
		if not encountered_ids.has(encounter_id):
			available.append(encounter_id)
	if available.is_empty():
		return (
			GHOST_SHADOW
			if content_pool_id == MAGICAL_ENCOUNTER_POOL
			else &""
		)
	var index := RogueEncounterRandom.choose_index(
		node_content_seed,
		&"content_selection",
		available.size()
	)
	return available[index]


## 为一张路线图中的全部遭遇节点建立稳定且不重复的内容映射。
## ordered_node_ids 必须使用路线图的稳定节点顺序；同一地图 seed 下，节点分配
## 与访问先后无关。下一张地图使用新的 generation_seed，因此允许再次出现
## 上一张地图已经触发过的事件。
static func select_encounter_for_map(
	content_pool_id: StringName,
	generation_seed: int,
	ordered_node_ids: PackedInt32Array,
	node_id: int
) -> StringName:
	var entries := get_pool_entries(content_pool_id)
	if (
		entries.is_empty()
		or ordered_node_ids.is_empty()
		or ordered_node_ids.size() > entries.size()
	):
		return &""
	var node_index := ordered_node_ids.find(node_id)
	if node_index < 0:
		return &""
	for index in range(1, ordered_node_ids.size()):
		if ordered_node_ids[index - 1] >= ordered_node_ids[index]:
			return &""
	var shuffled := entries.duplicate()
	for source_index in range(shuffled.size() - 1, 0, -1):
		var target_index := RogueEncounterRandom.choose_index(
			generation_seed,
			StringName(
				"route_map_assignment:%s:%d"
				% [String(content_pool_id), source_index]
			),
			source_index + 1
		)
		var temporary: StringName = shuffled[source_index]
		shuffled[source_index] = shuffled[target_index]
		shuffled[target_index] = temporary
	return shuffled[node_index]


## 事件池的稳定顺序会直接影响按地图 seed 进行的一一分配，必须进入路线
## runtime contract，避免不同客户端用相同布局推导出不同事件。
static func compute_runtime_contract_hash() -> String:
	var pool_ids: Array[StringName] = []
	for raw_pool_id in _POOLS.keys():
		pool_ids.append(StringName(raw_pool_id))
	pool_ids.sort_custom(func(first: StringName, second: StringName) -> bool:
		return String(first) < String(second)
	)
	var parts := PackedStringArray([
		"schema=%d" % RUNTIME_CONTRACT_SCHEMA,
	])
	for pool_id in pool_ids:
		var entries := get_pool_entries(pool_id)
		parts.append("pool=%s:%d" % [String(pool_id), entries.size()])
		for encounter_id in entries:
			parts.append("encounter=%s" % String(encounter_id))
	return "\n".join(parts).sha256_text()


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


## 多页开场是公开的确定性内容，不进入权威快照。旧事件会从既有
## intro_text / intro_speaker / intro_is_narration 字段合成单页。
static func get_intro_pages(encounter_id: StringName) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var config := get_encounter_config(encounter_id)
	var raw_pages: Variant = config.get("intro_pages", [])
	if typeof(raw_pages) == TYPE_ARRAY:
		for raw_page in raw_pages as Array:
			if typeof(raw_page) != TYPE_DICTIONARY:
				continue
			var page := raw_page as Dictionary
			var text := str(page.get("text", ""))
			if text.is_empty():
				continue
			result.append({
				"speaker": str(page.get("speaker", "")),
				"text": text,
				"is_narration": bool(page.get("is_narration", true)),
			})
	if not result.is_empty():
		return result
	var legacy_text := str(config.get("intro_text", ""))
	if legacy_text.is_empty():
		return result
	result.append({
		"speaker": str(config.get("intro_speaker", "")),
		"text": legacy_text,
		"is_narration": bool(config.get("intro_is_narration", true)),
	})
	return result


static func requires_result_ack(encounter_id: StringName) -> bool:
	return bool(
		get_encounter_config(encounter_id).get("requires_result_ack", false)
	)


static func get_no_vote_option_id(encounter_id: StringName) -> StringName:
	var option_id := StringName(
		get_encounter_config(encounter_id).get("no_vote_option_id", &"")
	)
	return option_id if is_valid_option(encounter_id, option_id) else &""

static func is_valid_option(
	encounter_id: StringName,
	option_id: StringName
) -> bool:
	return not option_id.is_empty() and get_option_ids(encounter_id).has(option_id)
