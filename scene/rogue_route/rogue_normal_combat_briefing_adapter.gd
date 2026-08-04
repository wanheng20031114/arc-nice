extends "res://scene/rogue_route/rogue_route_node_briefing_adapter.gd"
class_name RogueNormalCombatBriefingAdapter

const DEFAULT_ENCOUNTER_CONFIG: RogueCombatEncounterConfig = preload(
	"res://resources/config/rogue_combat/encounter_01.tres"
)
const DEFAULT_HERO_VISUAL_PATH := (
	"res://resources/texture/rogue_route/normal_combat_briefing_visual.png"
)
const COMMON_COLLECTIBLE_REWARD_TEXT := "随机 1 件普通收藏品"
const PRIMARY_ACTION_TEXT := "进入作战"

var encounter_config: RogueCombatEncounterConfig
var hero_visual: Texture2D


func _init(
	new_encounter_config: RogueCombatEncounterConfig = DEFAULT_ENCOUNTER_CONFIG,
	new_hero_visual: Texture2D = null
) -> void:
	encounter_config = new_encounter_config
	hero_visual = new_hero_visual
	if (
		hero_visual == null
		and ResourceLoader.exists(DEFAULT_HERO_VISUAL_PATH, "Texture2D")
	):
		hero_visual = load(DEFAULT_HERO_VISUAL_PATH) as Texture2D


func get_node_type() -> int:
	return RogueRouteGraph.NodeType.NORMAL_COMBAT


func build_model(
	node_config: RogueRouteNodeTypeConfig,
	current_action_points: int,
	move_action_cost: int
) -> BRIEFING_MODEL_SCRIPT:
	if not _can_build(node_config, current_action_points, move_action_cost):
		return null

	var wave := encounter_config.campaign.get_waves()[0]
	var enemy_entry := wave.enemy_entries[0]
	var enemy_name := enemy_entry.enemy_config.display_name.strip_edges()
	var model := BRIEFING_MODEL_SCRIPT.new(
		node_config.display_name,
		encounter_config.event_title,
		hero_visual,
		node_config.icon,
		"消灭全部%s" % enemy_name,
		encounter_config.combat_limit_seconds,
		encounter_config.enemy_count,
		"额外 +%d 息壤 · %s" % [
			encounter_config.extra_xirang,
			COMMON_COLLECTIBLE_REWARD_TEXT,
		],
		-move_action_cost,
		PRIMARY_ACTION_TEXT
	)
	return model if model.is_valid() else null


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
	if waves.size() != 1:
		return false
	var wave := waves[0]
	if wave == null or wave.enemy_entries.size() != 1:
		return false
	var enemy_entry := wave.enemy_entries[0]
	return (
		enemy_entry != null
		and enemy_entry.enemy_config != null
		and not enemy_entry.enemy_config.display_name.strip_edges().is_empty()
	)
