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

const RUNTIME_CONTRACT_SCHEMA := 2
const DEFAULT_ENCOUNTER_ID := &"narrow_road_01"
const DEFAULT_EVENT_TITLE := "狭路相逢"
const DEFAULT_OBJECTIVE_TEXT := "击败全部战斗机器人"
const DEFAULT_COMBAT_SCENE_PATH := (
	"res://scene/game_modes/rogue/combat/rogue_combat_game_01.tscn"
)
const DEFAULT_PREPARATION_SECONDS := 3
const DEFAULT_COMBAT_LIMIT_SECONDS := 90
const DEFAULT_EXTRA_XIRANG := 500
const REQUIRED_SCENE_SPAWN_POINT_MASK := (
	WaveConfig.SPAWN_POINT_1_MASK
	| WaveConfig.SPAWN_POINT_2_MASK
	| WaveConfig.SPAWN_POINT_3_MASK
)

@export_group("作战内容")
@export var encounter_id: StringName = DEFAULT_ENCOUNTER_ID
@export var event_title: String = DEFAULT_EVENT_TITLE
@export var objective_text: String = DEFAULT_OBJECTIVE_TEXT
@export_file("*.tscn") var combat_scene_path: String = DEFAULT_COMBAT_SCENE_PATH
@export var campaign: WaveCampaignConfig
@export_range(1, 3600, 1, "or_greater")
var preparation_seconds: int = DEFAULT_PREPARATION_SECONDS
@export_range(1, 3600, 1, "or_greater")
var combat_limit_seconds: int = DEFAULT_COMBAT_LIMIT_SECONDS
@export_range(0, 999999, 1, "or_greater") var extra_xirang: int = DEFAULT_EXTRA_XIRANG

@export_group("作战规则")
@export var decisions_confirmed: bool = false
@export var deadline_start: DeadlineStart = DeadlineStart.UNSPECIFIED
@export var keep_enemy_kill_xirang: Decision = Decision.UNSPECIFIED
@export var filter_loot_by_character: Decision = Decision.UNSPECIFIED
@export var reward_dead_players_on_victory: Decision = Decision.UNSPECIFIED
@export var return_to_route_before_result: Decision = Decision.UNSPECIFIED
@export var show_failure_result: Decision = Decision.UNSPECIFIED
@export var consume_node_on_failure: Decision = Decision.UNSPECIFIED
@export var enemy_pickup_drops: Decision = Decision.UNSPECIFIED
@export var inherit_route_xirang: Decision = Decision.UNSPECIFIED
@export var support_singleplayer: Decision = Decision.UNSPECIFIED
@export var support_multiplayer: Decision = Decision.UNSPECIFIED


func validate_config() -> PackedStringArray:
	var errors := PackedStringArray()
	_validate_content_fields(errors)
	_validate_campaign(errors)
	_validate_policy_decisions(errors)
	return errors


func is_ready_to_enable() -> bool:
	return validate_config().is_empty()


func get_total_enemy_count() -> int:
	var result := 0
	if campaign == null:
		return result
	for wave in campaign.get_waves():
		if wave != null:
			result += wave.get_total_enemy_count()
	return result


func get_spawn_point_mask() -> int:
	var result := 0
	if campaign == null:
		return result
	for wave in campaign.get_waves():
		if wave != null:
			result |= wave.spawn_point_mask
	return result


## 为本次节点复制一份独立资源图。敌人组成与生成节奏完整继承 authored Wave，
## occurrence 只负责按遭遇规则覆盖击杀息壤，单人和多人共同使用此入口。
func build_occurrence_campaign(occurrence_key: String) -> WaveCampaignConfig:
	if occurrence_key.is_empty() or campaign == null or campaign.flow_graph == null:
		return null
	var source_waves := campaign.get_waves()
	if source_waves.size() != 1:
		return null
	var source_wave := source_waves[0]
	if source_wave == null or source_wave.enemy_entries.is_empty():
		return null

	var occurrence_entries: Array[WaveEnemyEntry] = []
	for source_entry in source_wave.enemy_entries:
		if source_entry == null or source_entry.enemy_config == null:
			return null
		var entry := source_entry.duplicate(false) as WaveEnemyEntry
		if entry == null:
			return null
		# 保留正式 EnemyConfig 的资源路径，确保多人刷怪序列化身份稳定。
		entry.enemy_config = source_entry.enemy_config
		entry.xirang_kill_reward_override = (
			-1 if keep_enemy_kill_xirang == Decision.YES else 0
		)
		occurrence_entries.append(entry)

	var wave := source_wave.duplicate(false) as WaveConfig
	var flow := campaign.flow_graph.duplicate(false) as FlowGraphConfig
	var occurrence_campaign := campaign.duplicate(false) as WaveCampaignConfig
	if wave == null or flow == null or occurrence_campaign == null:
		return null

	wave.enemy_entries = occurrence_entries
	wave.exits = []
	flow.start_step = wave
	flow.steps = [wave]
	occurrence_campaign.campaign_id = StringName(
		"%s|%s" % [String(campaign.campaign_id), occurrence_key]
	)
	occurrence_campaign.flow_graph = flow
	if not occurrence_campaign.validate_campaign().is_empty():
		return null
	return occurrence_campaign


func compute_runtime_contract_hash() -> String:
	if campaign == null or campaign.flow_graph == null:
		return ""
	var waves := campaign.get_waves()
	if waves.size() != 1:
		return ""
	var parts := PackedStringArray([
		"schema=%d" % RUNTIME_CONTRACT_SCHEMA,
		"config_path=%s" % resource_path,
		"encounter_id=%s" % String(encounter_id),
		"combat_scene=%s" % combat_scene_path,
		"campaign_path=%s" % campaign.resource_path,
		"campaign_id=%s" % String(campaign.campaign_id),
		"preparation=%d" % preparation_seconds,
		"limit=%d" % combat_limit_seconds,
		"extra_xirang=%d" % extra_xirang,
		"decisions_confirmed=%d" % int(decisions_confirmed),
		"deadline_start=%d" % int(deadline_start),
		"decisions=%d,%d,%d,%d,%d,%d,%d,%d,%d,%d" % [
			int(keep_enemy_kill_xirang),
			int(filter_loot_by_character),
			int(reward_dead_players_on_victory),
			int(return_to_route_before_result),
			int(show_failure_result),
			int(consume_node_on_failure),
			int(enemy_pickup_drops),
			int(inherit_route_xirang),
			int(support_singleplayer),
			int(support_multiplayer),
		],
	])
	for wave_index in range(waves.size()):
		var wave := waves[wave_index]
		if wave == null:
			return ""
		parts.append(
			"wave=%d:%s:%s:%d:%d:%d:%.6f:%d:%d:%.6f" % [
				wave_index,
				wave.resource_path,
				String(wave.step_id),
				wave.spawn_point_mask,
				int(wave.spawn_point_order),
				int(wave.spawn_order),
				wave.spawn_interval,
				wave.spawn_count_per_tick,
				wave.max_alive_enemies,
				wave.post_clear_rest_duration,
			]
		)
		for entry_index in range(wave.enemy_entries.size()):
			var entry := wave.enemy_entries[entry_index]
			if entry == null or entry.enemy_config == null:
				return ""
			parts.append(
				"entry=%d:%d:%s:%d:%d" % [
					wave_index,
					entry_index,
					entry.enemy_config.resource_path,
					entry.count,
					entry.xirang_kill_reward_override,
				]
			)
	return "\n".join(parts).sha256_text()


func _validate_content_fields(errors: PackedStringArray) -> void:
	if encounter_id == &"":
		errors.append("Rouge 战斗配置缺少 encounter_id。")
	if event_title.strip_edges().is_empty():
		errors.append("Rouge 战斗配置缺少事件标题。")
	if objective_text.strip_edges().is_empty():
		errors.append("Rouge 战斗配置缺少作战目标文本。")
	if combat_scene_path.strip_edges().is_empty():
		errors.append("Rouge 战斗配置缺少战斗场景路径。")
	elif not ResourceLoader.exists(combat_scene_path, "PackedScene"):
		errors.append("Rouge 战斗场景不存在或不是 PackedScene：%s。" % combat_scene_path)
	if preparation_seconds <= 0:
		errors.append("Rouge 战斗的准备倒计时必须大于0秒。")
	if combat_limit_seconds <= 0:
		errors.append("Rouge 战斗的作战时限必须大于0秒。")
	if extra_xirang < 0:
		errors.append("Rouge 战斗的额外息壤不能为负数。")


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
	if wave == null:
		errors.append("Rouge 战斗 Campaign 缺少有效波次。")
		return
	if not wave.exits.is_empty():
		errors.append("Rouge 战斗的唯一波次必须是无出口的终点波次。")
	if wave.enemy_entries.is_empty():
		errors.append("Rouge 战斗波次必须至少包含一个敌人条目。")
	for entry_index in range(wave.enemy_entries.size()):
		var entry := wave.enemy_entries[entry_index]
		if entry == null or entry.enemy_config == null:
			errors.append("Rouge 战斗波次的敌人条目%d缺少配置。" % (entry_index + 1))
		elif entry.count <= 0:
			errors.append("Rouge 战斗波次的敌人条目%d数量必须大于0。" % (entry_index + 1))
	if wave.get_total_enemy_count() <= 0:
		errors.append("Rouge 战斗 Campaign 必须至少生成一个敌人。")
	if wave.spawn_point_mask <= 0:
		errors.append("Rouge 战斗波次必须启用至少一个出生点。")
	elif wave.spawn_point_mask & ~WaveConfig.ALL_SPAWN_POINT_MASK:
		errors.append("Rouge 战斗波次包含未知出生点。")
	if wave.spawn_interval <= 0.0:
		errors.append("Rouge 战斗波次的生成间隔必须大于0秒。")
	if wave.spawn_count_per_tick <= 0:
		errors.append("Rouge 战斗波次的单次生成数量必须大于0。")
	if wave.max_alive_enemies <= 0:
		errors.append("Rouge 战斗波次的场上敌人上限必须大于0。")
	elif wave.spawn_count_per_tick > wave.max_alive_enemies:
		errors.append("Rouge 战斗波次的单次生成数量不能超过场上敌人上限。")
	if int(wave.spawn_order) not in WaveConfig.SpawnOrder.values():
		errors.append("Rouge 战斗波次的敌人生成顺序无效。")
	if int(wave.spawn_point_order) not in WaveConfig.SpawnPointOrder.values():
		errors.append("Rouge 战斗波次的出生点选择顺序无效。")


func _validate_policy_decisions(errors: PackedStringArray) -> void:
	if not decisions_confirmed:
		errors.append("Rouge 战斗规则尚未由玩家确认，禁止启用。")
	if deadline_start == DeadlineStart.UNSPECIFIED:
		errors.append("Rouge 战斗的时限起点尚未指定。")
	elif deadline_start not in [
		DeadlineStart.PREPARATION_START,
		DeadlineStart.WAVE_START,
	]:
		errors.append("Rouge 战斗的时限起点无效。")

	_validate_decision(errors, keep_enemy_kill_xirang, "是否保留敌人击杀息壤")
	_validate_decision(errors, filter_loot_by_character, "战利品是否按角色兼容性筛选")
	_validate_decision(errors, reward_dead_players_on_victory, "胜利时是否奖励已阵亡玩家")
	_validate_decision(errors, return_to_route_before_result, "是否先返回路线再显示结算")
	_validate_decision(errors, show_failure_result, "失败时是否显示结算")
	_validate_decision(errors, consume_node_on_failure, "失败时是否消耗节点")
	_validate_decision(errors, enemy_pickup_drops, "是否允许敌人随机掉落拾取物")
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
