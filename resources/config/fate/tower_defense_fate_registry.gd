extends RefCounted
class_name TowerDefenseFateRegistry

const MAX_WIRE_ID_LENGTH := 64

const OPTION_PERMANENT_CONTRACT: StringName = &"permanent_contract"
const OPTION_BASE_REBUILD: StringName = &"base_rebuild"
const OPTION_COLLECTIBLE_REWARD: StringName = &"collectible_reward"
const OPTION_FATE_STONE: StringName = &"fate_stone"
const OPTION_XIRANG_GIFT: StringName = &"xirang_gift"
const OPTION_DASH_COOLDOWN: StringName = &"dash_cooldown"
const OPTION_MAX_HEALTH: StringName = &"max_health"
const OPTION_CRITICAL_CORE: StringName = &"critical_core"
const OPTION_DOUBLE_XIRANG: StringName = &"double_xirang"
const OPTION_DANGEROUS_SPEED: StringName = &"dangerous_speed"

const BUFF_BUILDING_REGENERATION: StringName = &"building_regeneration"
const BUFF_YUANSHI_ATTACK_REDUCTION: StringName = &"yuanshi_attack_reduction"
const BUFF_ARTIFICIAL_DEFENSE_REDUCTION: StringName = &"artificial_defense_reduction"
const BUFF_PLAYER_REGENERATION: StringName = &"player_regeneration"
const BUFF_SLIME_SPEED_REDUCTION: StringName = &"slime_speed_reduction"
const BUFF_ENEMY_MAX_HEALTH_REDUCTION: StringName = &"enemy_max_health_reduction"
const BUFF_ENEMY_SPEED_REDUCTION: StringName = &"enemy_speed_reduction"
const BUFF_LUOXI_EXTRA_CHOICE: StringName = &"luoxi_extra_choice"
const BUFF_LOW_HEALTH_REDUCTION: StringName = &"low_health_reduction"

const OPTION_CONFIGS: Array[TowerDefenseFateOptionConfig] = [
	preload("res://resources/config/fate/options/permanent_contract.tres"),
	preload("res://resources/config/fate/options/base_rebuild.tres"),
	preload("res://resources/config/fate/options/collectible_reward.tres"),
	preload("res://resources/config/fate/options/fate_stone.tres"),
	preload("res://resources/config/fate/options/xirang_gift.tres"),
	preload("res://resources/config/fate/options/dash_cooldown.tres"),
	preload("res://resources/config/fate/options/max_health.tres"),
	preload("res://resources/config/fate/options/critical_core.tres"),
	preload("res://resources/config/fate/options/double_xirang.tres"),
	preload("res://resources/config/fate/options/dangerous_speed.tres"),
]

const PERMANENT_BUFF_CONFIGS: Array[TowerDefensePermanentBuffConfig] = [
	preload("res://resources/config/fate/permanent_buffs/building_regeneration.tres"),
	preload("res://resources/config/fate/permanent_buffs/yuanshi_attack_reduction.tres"),
	preload("res://resources/config/fate/permanent_buffs/artificial_defense_reduction.tres"),
	preload("res://resources/config/fate/permanent_buffs/player_regeneration.tres"),
	preload("res://resources/config/fate/permanent_buffs/slime_speed_reduction.tres"),
	preload("res://resources/config/fate/permanent_buffs/enemy_max_health_reduction.tres"),
	preload("res://resources/config/fate/permanent_buffs/enemy_speed_reduction.tres"),
	preload("res://resources/config/fate/permanent_buffs/luoxi_extra_choice.tres"),
	preload("res://resources/config/fate/permanent_buffs/low_health_reduction.tres"),
]


static func get_all_option_configs() -> Array[TowerDefenseFateOptionConfig]:
	var result: Array[TowerDefenseFateOptionConfig] = []
	for config in OPTION_CONFIGS:
		if config != null and config.is_valid():
			result.append(config)
	result.sort_custom(func(left: TowerDefenseFateOptionConfig, right: TowerDefenseFateOptionConfig) -> bool:
		return left.menu_order < right.menu_order
	)
	return result


static func get_all_option_ids() -> Array[StringName]:
	var result: Array[StringName] = []
	for config in get_all_option_configs():
		result.append(config.option_id)
	return result


static func get_option_config(option_id: StringName) -> TowerDefenseFateOptionConfig:
	for config in OPTION_CONFIGS:
		if config != null and config.option_id == option_id and config.is_valid():
			return config
	return null


static func get_option_config_by_wire_id(wire_id: String) -> TowerDefenseFateOptionConfig:
	if wire_id.is_empty() or wire_id.length() > MAX_WIRE_ID_LENGTH:
		return null
	return get_option_config(StringName(wire_id))


static func get_all_permanent_buff_configs() -> Array[TowerDefensePermanentBuffConfig]:
	var result: Array[TowerDefensePermanentBuffConfig] = []
	for config in PERMANENT_BUFF_CONFIGS:
		if config != null and config.is_valid():
			result.append(config)
	result.sort_custom(func(left: TowerDefensePermanentBuffConfig, right: TowerDefensePermanentBuffConfig) -> bool:
		return left.menu_order < right.menu_order
	)
	return result


static func get_all_permanent_buff_ids() -> Array[StringName]:
	var result: Array[StringName] = []
	for config in get_all_permanent_buff_configs():
		result.append(config.buff_id)
	return result


static func get_permanent_buff_config(
	buff_id: StringName
) -> TowerDefensePermanentBuffConfig:
	for config in PERMANENT_BUFF_CONFIGS:
		if config != null and config.buff_id == buff_id and config.is_valid():
			return config
	return null


static func get_permanent_buff_config_by_wire_id(
	wire_id: String
) -> TowerDefensePermanentBuffConfig:
	if wire_id.is_empty() or wire_id.length() > MAX_WIRE_ID_LENGTH:
		return null
	return get_permanent_buff_config(StringName(wire_id))


static func is_valid_contract() -> bool:
	var option_ids := get_all_option_ids()
	var buff_ids := get_all_permanent_buff_ids()
	if option_ids.size() != 10 or buff_ids.size() != 9:
		return false
	var unique_options := {}
	var unique_option_orders := {}
	var unique_option_effects := {}
	for option_config in get_all_option_configs():
		var option_id := option_config.option_id
		if unique_options.has(option_id):
			return false
		if (
			unique_option_orders.has(option_config.menu_order)
			or unique_option_effects.has(option_config.effect_type)
		):
			return false
		unique_options[option_id] = true
		unique_option_orders[option_config.menu_order] = true
		unique_option_effects[option_config.effect_type] = true
	var unique_buffs := {}
	var unique_buff_orders := {}
	var unique_buff_effects := {}
	for buff_config in get_all_permanent_buff_configs():
		var buff_id := buff_config.buff_id
		if unique_buffs.has(buff_id):
			return false
		if (
			unique_buff_orders.has(buff_config.menu_order)
			or unique_buff_effects.has(buff_config.effect_type)
		):
			return false
		unique_buffs[buff_id] = true
		unique_buff_orders[buff_config.menu_order] = true
		unique_buff_effects[buff_config.effect_type] = true
	return true
