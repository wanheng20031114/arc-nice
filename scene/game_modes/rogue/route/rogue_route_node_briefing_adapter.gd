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
