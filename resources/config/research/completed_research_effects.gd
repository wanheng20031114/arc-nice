extends RefCounted
class_name CompletedResearchEffects

## 已完成科研的不可变、具名投影。该对象不持有或解释原始效果 Resource；
## 只有 GlobalResearchEffectResolver 可以把配置折叠为这些绝对运行时值。

var building_physical_defense_bonus: int:
	get:
		return _building_physical_defense_bonus
var player_move_speed_bonus: float:
	get:
		return _player_move_speed_bonus
var grass_heal_max_health_ratio_bonus: float:
	get:
		return _grass_heal_max_health_ratio_bonus
var fence_max_health_bonus: int:
	get:
		return _fence_max_health_bonus
var fence_physical_defense_bonus: int:
	get:
		return _fence_physical_defense_bonus
var agave_cannon_attack_damage_bonus: int:
	get:
		return _agave_cannon_attack_damage_bonus
var corn_machine_gun_burst_count_bonus: int:
	get:
		return _corn_machine_gun_burst_count_bonus
var vegetation_stake_spread_speed_multiplier: float:
	get:
		return _vegetation_stake_spread_speed_multiplier
var water_collector_cycle_duration_multiplier: float:
	get:
		return _water_collector_cycle_duration_multiplier
var bamboo_mortar_slow_ratio: float:
	get:
		return _bamboo_mortar_slow_ratio
var bamboo_mortar_slow_duration_seconds: float:
	get:
		return _bamboo_mortar_slow_duration_seconds
var grape_electromagnetic_duration_seconds: float:
	get:
		return _grape_electromagnetic_duration_seconds
var grape_electromagnetic_bonus_damage_ratio: float:
	get:
		return _grape_electromagnetic_bonus_damage_ratio

var _building_physical_defense_bonus: int
var _player_move_speed_bonus: float
var _grass_heal_max_health_ratio_bonus: float
var _fence_max_health_bonus: int
var _fence_physical_defense_bonus: int
var _agave_cannon_attack_damage_bonus: int
var _corn_machine_gun_burst_count_bonus: int
var _vegetation_stake_spread_speed_multiplier: float
var _water_collector_cycle_duration_multiplier: float
var _bamboo_mortar_slow_ratio: float
var _bamboo_mortar_slow_duration_seconds: float
var _grape_electromagnetic_duration_seconds: float
var _grape_electromagnetic_bonus_damage_ratio: float
var _simple_crafting_recipe_ids: Array[StringName]
var _production_recipe_ids: Array[StringName]


func _init(
	new_building_physical_defense_bonus: int,
	new_player_move_speed_bonus: float,
	new_grass_heal_max_health_ratio_bonus: float,
	new_fence_max_health_bonus: int,
	new_fence_physical_defense_bonus: int,
	new_agave_cannon_attack_damage_bonus: int,
	new_corn_machine_gun_burst_count_bonus: int,
	new_vegetation_stake_spread_speed_multiplier: float,
	new_water_collector_cycle_duration_multiplier: float,
	new_bamboo_mortar_slow_ratio: float,
	new_bamboo_mortar_slow_duration_seconds: float,
	new_grape_electromagnetic_duration_seconds: float,
	new_grape_electromagnetic_bonus_damage_ratio: float,
	new_simple_crafting_recipe_ids: Array[StringName],
	new_production_recipe_ids: Array[StringName]
) -> void:
	_building_physical_defense_bonus = new_building_physical_defense_bonus
	_player_move_speed_bonus = new_player_move_speed_bonus
	_grass_heal_max_health_ratio_bonus = new_grass_heal_max_health_ratio_bonus
	_fence_max_health_bonus = new_fence_max_health_bonus
	_fence_physical_defense_bonus = new_fence_physical_defense_bonus
	_agave_cannon_attack_damage_bonus = new_agave_cannon_attack_damage_bonus
	_corn_machine_gun_burst_count_bonus = new_corn_machine_gun_burst_count_bonus
	_vegetation_stake_spread_speed_multiplier = (
		new_vegetation_stake_spread_speed_multiplier
	)
	_water_collector_cycle_duration_multiplier = (
		new_water_collector_cycle_duration_multiplier
	)
	_bamboo_mortar_slow_ratio = new_bamboo_mortar_slow_ratio
	_bamboo_mortar_slow_duration_seconds = new_bamboo_mortar_slow_duration_seconds
	_grape_electromagnetic_duration_seconds = (
		new_grape_electromagnetic_duration_seconds
	)
	_grape_electromagnetic_bonus_damage_ratio = (
		new_grape_electromagnetic_bonus_damage_ratio
	)
	_simple_crafting_recipe_ids = new_simple_crafting_recipe_ids.duplicate()
	_production_recipe_ids = new_production_recipe_ids.duplicate()


func get_simple_crafting_recipe_ids() -> Array[StringName]:
	return _simple_crafting_recipe_ids.duplicate()


func get_production_recipe_ids() -> Array[StringName]:
	return _production_recipe_ids.duplicate()
