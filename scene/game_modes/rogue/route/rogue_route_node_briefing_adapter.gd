extends RefCounted
class_name RogueRouteNodeBriefingAdapter

const BRIEFING_MODEL_SCRIPT := preload(
	"res://scene/game_modes/rogue/route/rogue_route_node_briefing_model.gd"
)

## 作战节点到通用简报模型的适配器接口。
##
## 新作战类型只需要提供另一份适配器，不应在简报表现层中增加类型分支。


func get_node_type() -> int:
	return RogueRouteGraph.NodeType.EMPTY


func supports_node_type(node_type: int) -> bool:
	return node_type == get_node_type()


func build_model(
	_node_config: RogueRouteNodeTypeConfig,
	_current_action_points: int,
	_move_action_cost: int
) -> BRIEFING_MODEL_SCRIPT:
	return null


func build_encounter_model(
	source_kind: StringName,
	config_id: StringName,
	title: String,
	summary: String,
	encounter_config: RogueCombatEncounterConfig,
	hero_visual: Texture2D,
	icon: Texture2D,
	reward_summary: String,
	action_point_delta: int,
	primary_action_text: String,
	can_cancel: bool,
	presentation_variant: StringName = (
		BRIEFING_MODEL_SCRIPT.PRESENTATION_VARIANT_DEFAULT
	)
) -> BRIEFING_MODEL_SCRIPT:
	if (
		source_kind == &""
		or config_id == &""
		or encounter_config == null
		or encounter_config.encounter_id != config_id
		or not encounter_config.is_ready_to_enable()
		or hero_visual == null
		or icon == null
	):
		return null
	var model := BRIEFING_MODEL_SCRIPT.new(
		title,
		summary,
		hero_visual,
		icon,
		encounter_config.objective_text,
		encounter_config.combat_limit_seconds,
		encounter_config.get_total_enemy_count(),
		reward_summary,
		action_point_delta,
		primary_action_text,
		source_kind,
		config_id,
		can_cancel,
		presentation_variant
	)
	return model if model.is_valid() else null
