extends RefCounted
class_name RogueSupplyRegistry

const OPTION_CORE_REPAIR := &"core_repair"
const OPTION_GAIN_LIGHT_STONES := &"gain_light_stones"
const OPTION_LIGHT_STONE_XIRANG := &"light_stone_xirang"
const OPTION_LIGHT_STONE_COLLECTIBLES := &"light_stone_collectibles"
const OPTION_GAIN_XIRANG := &"gain_xirang"
const OPTION_FLYING_ENVELOPE := &"flying_envelope"
const OPTION_GAIN_ACTION_POINTS := &"gain_action_points"
const OPTION_LIGHT_STONE_ACTION_POINTS := &"light_stone_action_points"

const CHOICE_COUNT := 3
const LIGHT_STONE_COST := 1

const _ORDERED_OPTIONS: Array[StringName] = [
	OPTION_CORE_REPAIR,
	OPTION_GAIN_LIGHT_STONES,
	OPTION_LIGHT_STONE_XIRANG,
	OPTION_LIGHT_STONE_COLLECTIBLES,
	OPTION_GAIN_XIRANG,
	OPTION_FLYING_ENVELOPE,
	OPTION_GAIN_ACTION_POINTS,
	OPTION_LIGHT_STONE_ACTION_POINTS,
]

const _DEFINITIONS := {
	OPTION_CORE_REPAIR: {
		"display_name": "修复核心",
		"description": "获得10点核心生命值上限并回复10点核心生命值",
		"light_stone_cost": 0,
	},
	OPTION_GAIN_LIGHT_STONES: {
		"display_name": "搜集光石",
		"description": "获得3块光石",
		"light_stone_cost": 0,
	},
	OPTION_LIGHT_STONE_XIRANG: {
		"display_name": "水晶分配",
		"description": "失去1块光石，每个玩家获得5000息壤水晶",
		"light_stone_cost": LIGHT_STONE_COST,
	},
	OPTION_LIGHT_STONE_COLLECTIBLES: {
		"display_name": "珍藏补给",
		"description": "失去1块光石，每个玩家获得一个收藏品",
		"light_stone_cost": LIGHT_STONE_COST,
	},
	OPTION_GAIN_XIRANG: {
		"display_name": "基础补给",
		"description": "每个玩家获得1000息壤水晶",
		"light_stone_cost": 0,
	},
	OPTION_FLYING_ENVELOPE: {
		"display_name": "漂泊来信",
		"description": "获得“会飞的信封”",
		"light_stone_cost": 0,
	},
	OPTION_GAIN_ACTION_POINTS: {
		"display_name": "整顿行装",
		"description": "获得2点行动力",
		"light_stone_cost": 0,
	},
	OPTION_LIGHT_STONE_ACTION_POINTS: {
		"display_name": "光石驱动",
		"description": "失去1块光石，获得3点行动力",
		"light_stone_cost": LIGHT_STONE_COST,
	},
}


static func get_all_option_ids() -> Array[StringName]:
	return _ORDERED_OPTIONS.duplicate()


static func has_option(option_id: StringName) -> bool:
	return _DEFINITIONS.has(option_id)


static func get_option_definition(option_id: StringName) -> Dictionary:
	var raw_value: Variant = _DEFINITIONS.get(option_id)
	return (
		(raw_value as Dictionary).duplicate(true)
		if typeof(raw_value) == TYPE_DICTIONARY
		else {}
	)


static func get_light_stone_cost(option_id: StringName) -> int:
	return maxi(int(get_option_definition(option_id).get(
		"light_stone_cost",
		0
	)), 0)


static func is_paid_option(option_id: StringName) -> bool:
	return get_light_stone_cost(option_id) > 0


## 先对八项执行稳定洗牌并取前三项。若恰好抽中全部三项付费选项，
## 使用洗牌序列中最先出现的免费项替换最后一张，确保至少能做出选择。
static func select_options(
	node_content_seed: int,
	excluded_option_ids: Array[StringName] = []
) -> Array[StringName]:
	var candidate_options: Array[StringName] = []
	for option_id in _ORDERED_OPTIONS:
		if not excluded_option_ids.has(option_id):
			candidate_options.append(option_id)
	var order := RogueSupplyRandom.shuffled_indices(
		node_content_seed,
		&"supply_option_order",
		candidate_options.size()
	)
	var selected: Array[StringName] = []
	for index in order:
		if selected.size() >= CHOICE_COUNT:
			break
		selected.append(candidate_options[index])
	var has_free_option := false
	for option_id in selected:
		if not is_paid_option(option_id):
			has_free_option = true
			break
	if has_free_option:
		return selected
	for index in order:
		var candidate := candidate_options[index]
		if not selected.has(candidate) and not is_paid_option(candidate):
			selected[selected.size() - 1] = candidate
			break
	return selected
