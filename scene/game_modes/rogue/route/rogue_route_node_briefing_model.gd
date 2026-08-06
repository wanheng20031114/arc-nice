extends RefCounted
class_name RogueRouteNodeBriefingModel

## 通用作战节点简报的只读式数据载体。
##
## 适配器负责从具体节点内容生成模型；表现层只消费这些字段，因而不需要
## 知道普通作战、紧急作战或其他未来作战类型的配置结构。

var title: String
var summary: String
var hero_visual: Texture2D
var icon: Texture2D
var objective: String
var time_limit_seconds: int
var enemy_count: int
var reward_summary: String
var action_point_delta: int
var primary_action_text: String


func _init(
	new_title: String = "",
	new_summary: String = "",
	new_hero_visual: Texture2D = null,
	new_icon: Texture2D = null,
	new_objective: String = "",
	new_time_limit_seconds: int = 0,
	new_enemy_count: int = 0,
	new_reward_summary: String = "",
	new_action_point_delta: int = 0,
	new_primary_action_text: String = ""
) -> void:
	title = new_title
	summary = new_summary
	hero_visual = new_hero_visual
	icon = new_icon
	objective = new_objective
	time_limit_seconds = new_time_limit_seconds
	enemy_count = new_enemy_count
	reward_summary = new_reward_summary
	action_point_delta = new_action_point_delta
	primary_action_text = new_primary_action_text


func validate() -> PackedStringArray:
	var errors := PackedStringArray()
	if title.strip_edges().is_empty():
		errors.append("作战简报缺少标题。")
	if summary.strip_edges().is_empty():
		errors.append("作战简报缺少摘要。")
	if hero_visual == null:
		errors.append("作战简报缺少主视觉。")
	if icon == null:
		errors.append("作战简报缺少节点图标。")
	if objective.strip_edges().is_empty():
		errors.append("作战简报缺少作战目标。")
	if time_limit_seconds <= 0:
		errors.append("作战简报的时限必须大于零。")
	if enemy_count <= 0:
		errors.append("作战简报的敌人数必须大于零。")
	if reward_summary.strip_edges().is_empty():
		errors.append("作战简报缺少胜利奖励说明。")
	if action_point_delta >= 0:
		errors.append("作战简报的行动力变化必须为负数。")
	if primary_action_text.strip_edges().is_empty():
		errors.append("作战简报缺少主操作文案。")
	return errors


func is_valid() -> bool:
	return validate().is_empty()
