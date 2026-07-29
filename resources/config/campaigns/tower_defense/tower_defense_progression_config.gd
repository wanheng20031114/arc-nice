extends Resource
class_name TowerDefenseProgressionConfig

@export_group("阶段计时")
@export_range(0.0, 3600.0, 1.0, "or_greater")
var initial_preparation_seconds: float = 90.0
@export_range(0.0, 3600.0, 1.0, "or_greater")
var wave_intermission_seconds: float = 30.0
@export_range(0.0, 3600.0, 1.0, "or_greater")
var new_day_preparation_seconds: float = 60.0

@export_group("多人波次")
@export_range(0.0, 1.0, 0.05)
var enemy_count_per_extra_player_ratio: float = 0.25

@export_group("每位玩家起步包")
@export var per_player_items: Array[PickupConfig] = []
@export var per_player_amounts: Array[int] = []

@export_group("团队起步包")
@export var team_items: Array[PickupConfig] = []
@export var team_amounts: Array[int] = []

@export_group("成长记录")
@export var tracked_materials: Array[PickupConfig] = []


func is_valid() -> bool:
	if (
		not is_finite(initial_preparation_seconds)
		or initial_preparation_seconds < 0.0
		or not is_finite(wave_intermission_seconds)
		or wave_intermission_seconds < 0.0
		or not is_finite(new_day_preparation_seconds)
		or new_day_preparation_seconds < 0.0
		or not is_finite(enemy_count_per_extra_player_ratio)
		or enemy_count_per_extra_player_ratio < 0.0
		or per_player_items.size() != per_player_amounts.size()
		or team_items.size() != team_amounts.size()
		or per_player_items.is_empty()
		or tracked_materials.is_empty()
	):
		return false
	var starting_item_paths := {}
	for item_index in per_player_items.size():
		var item := per_player_items[item_index]
		if (
			not _is_valid_starting_item(item, per_player_amounts[item_index])
			or starting_item_paths.has(item.resource_path)
		):
			return false
		starting_item_paths[item.resource_path] = true
	for item_index in team_items.size():
		var item := team_items[item_index]
		if (
			not _is_valid_starting_item(item, team_amounts[item_index])
			or starting_item_paths.has(item.resource_path)
		):
			return false
		starting_item_paths[item.resource_path] = true
	var tracked_paths := {}
	for item in tracked_materials:
		if (
			item == null
			or item.pickup_type != PickupConfig.PickupType.MATERIAL
			or item.resource_path.is_empty()
			or tracked_paths.has(item.resource_path)
		):
			return false
		tracked_paths[item.resource_path] = true
	return true


func get_scaled_enemy_count(base_count: int, player_count: int) -> int:
	if base_count <= 0 or player_count <= 0:
		return 0
	var multiplier := 1.0 + (
		float(player_count - 1) * enemy_count_per_extra_player_ratio
	)
	return maxi(ceili(float(base_count) * multiplier), 1)


func get_starting_items(include_team_items: bool) -> Array[PickupConfig]:
	var result: Array[PickupConfig] = []
	result.assign(per_player_items)
	if include_team_items:
		result.append_array(team_items)
	return result


func get_starting_amounts(include_team_items: bool) -> Array[int]:
	var result: Array[int] = []
	result.assign(per_player_amounts)
	if include_team_items:
		result.append_array(team_amounts)
	return result


func _is_valid_starting_item(item: PickupConfig, amount: int) -> bool:
	return (
		item != null
		and amount > 0
		and item.can_store_in_inventory
		and not item.resource_path.is_empty()
	)
