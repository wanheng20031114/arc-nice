@tool
extends Resource
class_name RogueCombatEncounterConfig

enum Decision {
	UNSPECIFIED,
	NO,
	YES,
}

enum DeadlineStart {
	UNSPECIFIED,
	PREPARATION_START,
	WAVE_START,
}

const DEFAULT_ENCOUNTER_ID := &"narrow_road_01"
const DEFAULT_EVENT_TITLE := "狭路相逢"
const DEFAULT_COMBAT_SCENE_PATH := (
	"res://scene/rogue_combat/rogue_combat_game.tscn"
)
const DEFAULT_PREPARATION_SECONDS := 3
const DEFAULT_COMBAT_LIMIT_SECONDS := 90
const DEFAULT_ENEMY_COUNT := 10
const DEFAULT_EXTRA_XIRANG := 500
const COMBAT_ROBOT_CONFIG_PATH := (
	"res://resources/config/enemies/combat_robot.tres"
)

@export_group("已确认基础规则")
@export var encounter_id: StringName = DEFAULT_ENCOUNTER_ID
@export var event_title: String = DEFAULT_EVENT_TITLE
@export_file("*.tscn") var combat_scene_path: String = DEFAULT_COMBAT_SCENE_PATH
@export var campaign: WaveCampaignConfig
@export_range(1, 3600, 1, "or_greater")
var preparation_seconds: int = DEFAULT_PREPARATION_SECONDS
@export_range(1, 3600, 1, "or_greater")
var combat_limit_seconds: int = DEFAULT_COMBAT_LIMIT_SECONDS
@export_range(1, 999, 1, "or_greater") var enemy_count: int = DEFAULT_ENEMY_COUNT
@export_range(0, 999999, 1, "or_greater") var extra_xirang: int = DEFAULT_EXTRA_XIRANG

@export_group("待玩家确认的规则")
@export var decisions_confirmed: bool = false
@export var deadline_start: DeadlineStart = DeadlineStart.UNSPECIFIED
@export_flags("Spawn1", "Spawn2", "Spawn3", "Spawn4", "Spawn5")
var spawn_point_mask: int = 0
@export_range(0, 999, 1, "or_greater") var spawn_count_per_tick: int = 0
@export var keep_enemy_kill_xirang: Decision = Decision.UNSPECIFIED
@export var filter_loot_by_character: Decision = Decision.UNSPECIFIED
@export var reward_dead_players_on_victory: Decision = Decision.UNSPECIFIED
@export var return_to_route_before_result: Decision = Decision.UNSPECIFIED
@export var show_failure_result: Decision = Decision.UNSPECIFIED
@export var consume_node_on_failure: Decision = Decision.UNSPECIFIED
@export var keep_standard_merchants_pickups_and_drops: Decision = Decision.UNSPECIFIED
@export var inherit_route_xirang: Decision = Decision.UNSPECIFIED
@export var support_singleplayer: Decision = Decision.UNSPECIFIED
@export var support_multiplayer: Decision = Decision.UNSPECIFIED


func validate_config() -> PackedStringArray:
	var errors := PackedStringArray()
	_validate_fixed_fields(errors)
	_validate_campaign(errors)
	_validate_pending_decisions(errors)
	return errors


func is_ready_to_enable() -> bool:
	return validate_config().is_empty()


func _validate_fixed_fields(errors: PackedStringArray) -> void:
	if encounter_id != DEFAULT_ENCOUNTER_ID:
		errors.append("狭路相逢的 encounter_id 必须固定为 narrow_road_01。")
	if event_title != DEFAULT_EVENT_TITLE:
		errors.append("Rouge 战斗 1 的事件标题必须固定为狭路相逢。")
	if combat_scene_path != DEFAULT_COMBAT_SCENE_PATH:
		errors.append("Rouge 战斗 1 必须使用专用的狭路相逢战斗场景。")
	if combat_scene_path.strip_edges().is_empty():
		errors.append("Rouge 战斗配置缺少战斗场景路径。")
	elif not ResourceLoader.exists(combat_scene_path, "PackedScene"):
		errors.append("Rouge 战斗场景不存在或不是 PackedScene：%s。" % combat_scene_path)
	if preparation_seconds != DEFAULT_PREPARATION_SECONDS:
		errors.append("狭路相逢的准备倒计时必须固定为 3 秒。")
	if combat_limit_seconds != DEFAULT_COMBAT_LIMIT_SECONDS:
		errors.append("狭路相逢的作战时限必须固定为 90 秒。")
	if enemy_count != DEFAULT_ENEMY_COUNT:
		errors.append("狭路相逢必须固定生成 10 个敌人。")
	if extra_xirang != DEFAULT_EXTRA_XIRANG:
		errors.append("狭路相逢的通关额外息壤必须固定为 500。")


func _validate_campaign(errors: PackedStringArray) -> void:
	if campaign == null:
		errors.append("Rouge 战斗配置缺少 Campaign。")
		return

	errors.append_array(campaign.validate_campaign())
	var waves := campaign.get_waves()
	if waves.size() != 1:
		errors.append("Rouge 战斗 Campaign 必须且只能包含一个波次。")
		return

	var wave := waves[0]
	if not wave.exits.is_empty():
		errors.append("Rouge 战斗的唯一波次必须是无出口的终点波次。")
	if wave.get_total_enemy_count() != enemy_count:
		errors.append(
			"Rouge 战斗 Campaign 的敌人数必须与 enemy_count 一致。"
		)
	if wave.enemy_entries.size() != 1:
		errors.append("狭路相逢波次必须且只能包含一个作战机器人条目。")
	else:
		var entry := wave.enemy_entries[0]
		if entry == null or entry.enemy_config == null:
			errors.append("狭路相逢波次缺少作战机器人配置。")
		elif entry.enemy_config.resource_path != COMBAT_ROBOT_CONFIG_PATH:
			errors.append("狭路相逢波次只能生成基础作战机器人。")
		elif entry.count != enemy_count:
			errors.append("狭路相逢作战机器人条目的数量必须与 enemy_count 一致。")
		if entry != null and entry.xirang_kill_reward_override != -1:
			errors.append("狭路相逢技术波次必须保留默认击杀息壤继承值 -1。")
	if wave.max_alive_enemies < enemy_count:
		errors.append("Rouge 战斗波次的场上敌人上限不能小于 enemy_count。")


func _validate_pending_decisions(errors: PackedStringArray) -> void:
	if not decisions_confirmed:
		errors.append("Rouge 战斗规则尚未由玩家确认，禁止启用。")
	if deadline_start == DeadlineStart.UNSPECIFIED:
		errors.append("Rouge 战斗的 90 秒时限起点尚未指定。")
	elif deadline_start not in [
		DeadlineStart.PREPARATION_START,
		DeadlineStart.WAVE_START,
	]:
		errors.append("Rouge 战斗的 90 秒时限起点无效。")
	if spawn_point_mask == 0:
		errors.append("Rouge 战斗使用哪些红门尚未指定。")
	elif spawn_point_mask & ~WaveConfig.STANDARD_SPAWN_POINT_MASK:
		errors.append("Rouge 战斗只能使用 Spawn1 至 Spawn5 红门。")
	if spawn_count_per_tick <= 0:
		errors.append("Rouge 战斗的单次生成数量尚未指定。")
	elif spawn_count_per_tick > enemy_count:
		errors.append("Rouge 战斗的单次生成数量不能超过固定敌人数 10。")

	_validate_decision(errors, keep_enemy_kill_xirang, "是否保留敌人击杀息壤")
	_validate_decision(errors, filter_loot_by_character, "战利品是否按角色兼容性筛选")
	_validate_decision(errors, reward_dead_players_on_victory, "胜利时是否奖励已阵亡玩家")
	_validate_decision(errors, return_to_route_before_result, "是否先返回路线再显示结算")
	_validate_decision(errors, show_failure_result, "失败时是否显示结算")
	_validate_decision(errors, consume_node_on_failure, "失败时是否消耗节点")
	_validate_decision(
		errors,
		keep_standard_merchants_pickups_and_drops,
		"是否保留普通模式商人、拾取物和掉落"
	)
	_validate_decision(errors, inherit_route_xirang, "是否继承 Rouge 路线息壤")
	_validate_decision(errors, support_singleplayer, "是否支持单人 Rouge")
	_validate_decision(errors, support_multiplayer, "是否支持多人 Rouge")


func _validate_decision(
	errors: PackedStringArray,
	decision: Decision,
	label: String
) -> void:
	if decision == Decision.UNSPECIFIED:
		errors.append("%s尚未指定。" % label)
	elif decision not in [Decision.NO, Decision.YES]:
		errors.append("%s的配置值无效。" % label)
