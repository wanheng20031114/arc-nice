extends Resource
class_name TowerDefenseProgressionConfig

const RUNTIME_CONTRACT_SCHEMA := 2
const ROGUE_EXPLORATION_DAY_COUNT := 3

@export_group("阶段计时")
@export_range(0.0, 3600.0, 1.0, "or_greater")
var initial_preparation_seconds: float = 90.0
@export_range(0.0, 3600.0, 1.0, "or_greater")
var wave_intermission_seconds: float = 30.0
@export_range(0.0, 3600.0, 1.0, "or_greater")
var new_day_preparation_seconds: float = 60.0

@export_group("日终地下探索")
## 顺序固定对应第1、2、3日；数组顺序属于运行契约语义。
@export var daily_rogue_action_points: Array[int] = [5, 5, 5]

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
	return validate_config().is_empty()


func validate_config() -> PackedStringArray:
	var errors := PackedStringArray()
	if (
		not is_finite(initial_preparation_seconds)
		or initial_preparation_seconds < 0.0
		or not is_finite(wave_intermission_seconds)
		or wave_intermission_seconds < 0.0
		or not is_finite(new_day_preparation_seconds)
		or new_day_preparation_seconds < 0.0
		or not is_finite(enemy_count_per_extra_player_ratio)
		or enemy_count_per_extra_player_ratio < 0.0
	):
		errors.append("塔防阶段计时或多人敌人数倍率无效。")
	if daily_rogue_action_points.size() != ROGUE_EXPLORATION_DAY_COUNT:
		errors.append("地下探索行动力必须恰好配置第1至第3日共3项。")
	else:
		for day_index in daily_rogue_action_points.size():
			if (
				daily_rogue_action_points[day_index] < 0
				or daily_rogue_action_points[day_index] > 0x7FFFFFFF
			):
				errors.append("第%d日地下探索行动力必须位于0至2147483647。" % (day_index + 1))
	if per_player_items.size() != per_player_amounts.size():
		errors.append("每位玩家起步包物品与数量长度不一致。")
	if team_items.size() != team_amounts.size():
		errors.append("团队起步包物品与数量长度不一致。")
	if per_player_items.is_empty():
		errors.append("每位玩家起步包不能为空。")
	if tracked_materials.is_empty():
		errors.append("成长记录材料不能为空。")
	var starting_item_paths := {}
	for item_index in mini(per_player_items.size(), per_player_amounts.size()):
		var item := per_player_items[item_index]
		if (
			not _is_valid_starting_item(item, per_player_amounts[item_index])
			or starting_item_paths.has(item.resource_path)
		):
			errors.append("每位玩家起步包第%d项无效或重复。" % (item_index + 1))
			continue
		starting_item_paths[item.resource_path] = true
	for item_index in mini(team_items.size(), team_amounts.size()):
		var item := team_items[item_index]
		if (
			not _is_valid_starting_item(item, team_amounts[item_index])
			or starting_item_paths.has(item.resource_path)
		):
			errors.append("团队起步包第%d项无效或与其他起步物品重复。" % (item_index + 1))
			continue
		starting_item_paths[item.resource_path] = true
	var tracked_paths := {}
	for item in tracked_materials:
		if (
			item == null
			or item.pickup_type != PickupConfig.PickupType.MATERIAL
			or item.resource_path.is_empty()
			or tracked_paths.has(item.resource_path)
		):
			errors.append("成长记录材料存在空项、非材料或重复路径。")
			continue
		tracked_paths[item.resource_path] = true
	return errors


func get_daily_rogue_action_points(day_number: int) -> int:
	if day_number < 1 or day_number > daily_rogue_action_points.size():
		return 0
	return daily_rogue_action_points[day_number - 1]


## 数组顺序均具有语义：起步包按物品/数量配对，追踪材料与每日行动力按
## 编辑顺序参与契约。任何配置顺序变化都会得到不同 hash。
func compute_runtime_contract_hash() -> String:
	if not is_valid():
		return ""
	var parts := PackedStringArray([
		"schema=%d" % RUNTIME_CONTRACT_SCHEMA,
		"timers=%.6f,%.6f,%.6f" % [
			initial_preparation_seconds,
			wave_intermission_seconds,
			new_day_preparation_seconds,
		],
		"enemy_ratio=%.6f" % enemy_count_per_extra_player_ratio,
		"daily_rogue_ap=%s" % _join_ints(daily_rogue_action_points),
	])
	for item_index in per_player_items.size():
		parts.append("player_item=%s:%d" % [
			per_player_items[item_index].resource_path,
			per_player_amounts[item_index],
		])
	for item_index in team_items.size():
		parts.append("team_item=%s:%d" % [
			team_items[item_index].resource_path,
			team_amounts[item_index],
		])
	for item in tracked_materials:
		parts.append("tracked=%s" % item.resource_path)
	return "\n".join(parts).sha256_text()


static func _join_ints(values: Array[int]) -> String:
	var parts := PackedStringArray()
	for value in values:
		parts.append(str(value))
	return ",".join(parts)


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
