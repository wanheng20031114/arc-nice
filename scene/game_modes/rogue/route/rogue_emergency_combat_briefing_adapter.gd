extends "res://scene/game_modes/rogue/route/rogue_route_node_briefing_adapter.gd"
class_name RogueEmergencyCombatBriefingAdapter

const PRIMARY_ACTION_TEXT := "进入紧急作战"
const EVENT_TITLE_SEPARATOR := "："

var encounter_config: RogueCombatEncounterConfig
var hero_visual: Texture2D


func _init(
	new_encounter_config: RogueCombatEncounterConfig,
	new_hero_visual: Texture2D = null
) -> void:
	encounter_config = new_encounter_config
	hero_visual = new_hero_visual


func get_node_type() -> int:
	return RogueRouteGraph.NodeType.EMERGENCY_COMBAT


func build_model(
	node_config: RogueRouteNodeTypeConfig,
	current_action_points: int,
	move_action_cost: int
) -> BRIEFING_MODEL_SCRIPT:
	if not _can_build(node_config, current_action_points, move_action_cost):
		return null
	return build_encounter_model(
		BRIEFING_MODEL_SCRIPT.SOURCE_KIND_EMERGENCY_COMBAT,
		encounter_config.encounter_id,
		node_config.display_name,
		_get_briefing_summary(
			node_config.display_name,
			encounter_config.event_title
		),
		encounter_config,
		hero_visual,
		node_config.icon,
		"每人 1000～2000 息壤 · 两轮收藏品 2 选 1 · 基础物资 ×3 · 全队光石 +1",
		-move_action_cost,
		PRIMARY_ACTION_TEXT,
		true,
		BRIEFING_MODEL_SCRIPT.PRESENTATION_VARIANT_DANGER
	)


func _get_briefing_summary(node_title: String, event_title: String) -> String:
	var normalized_title := node_title.strip_edges()
	var normalized_event_title := event_title.strip_edges()
	var repeated_prefix := normalized_title + EVENT_TITLE_SEPARATOR
	if normalized_event_title.begins_with(repeated_prefix):
		return normalized_event_title.trim_prefix(repeated_prefix).strip_edges()
	return normalized_event_title


func _can_build(
	node_config: RogueRouteNodeTypeConfig,
	current_action_points: int,
	move_action_cost: int
) -> bool:
	if (
		node_config == null
		or not supports_node_type(node_config.node_type)
		or not node_config.validate_config().is_empty()
		or encounter_config == null
		or not encounter_config.is_ready_to_enable()
		or hero_visual == null
		or move_action_cost <= 0
		or current_action_points < move_action_cost
	):
		return false
	var waves := encounter_config.campaign.get_waves()
	return waves.size() == 1 and waves[0] != null and waves[0].get_total_enemy_count() > 0
