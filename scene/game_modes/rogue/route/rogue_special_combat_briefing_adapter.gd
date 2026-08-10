extends "res://scene/game_modes/rogue/route/rogue_route_node_briefing_adapter.gd"
class_name RogueSpecialCombatBriefingAdapter

const SPECIAL_SUMMARY := "紧急作战 · 遭遇后续特殊作战 · 不消耗行动力"
const DEFAULT_PRIMARY_ACTION_TEXT := "进入作战"

var encounter_config: RogueCombatEncounterConfig
var hero_visual: Texture2D
var reward_summary: String
var primary_action_text: String


func _init(
	new_encounter_config: RogueCombatEncounterConfig,
	new_hero_visual: Texture2D,
	new_reward_summary: String,
	new_primary_action_text: String = DEFAULT_PRIMARY_ACTION_TEXT
) -> void:
	encounter_config = new_encounter_config
	hero_visual = new_hero_visual
	reward_summary = new_reward_summary
	primary_action_text = new_primary_action_text


func get_node_type() -> int:
	return RogueRouteGraph.NodeType.MAGICAL_ENCOUNTER


func build_model(
	node_config: RogueRouteNodeTypeConfig,
	_current_action_points: int,
	_move_action_cost: int
) -> BRIEFING_MODEL_SCRIPT:
	if (
		node_config == null
		or not supports_node_type(node_config.node_type)
		or not node_config.validate_config().is_empty()
		or encounter_config == null
		or not encounter_config.is_ready_to_enable()
		or hero_visual == null
		or reward_summary.strip_edges().is_empty()
		or primary_action_text.strip_edges().is_empty()
	):
		return null
	return build_encounter_model(
		BRIEFING_MODEL_SCRIPT.SOURCE_KIND_SPECIAL_COMBAT,
		encounter_config.encounter_id,
		encounter_config.event_title,
		SPECIAL_SUMMARY,
		encounter_config,
		hero_visual,
		node_config.icon,
		reward_summary,
		0,
		primary_action_text,
		false
	)
