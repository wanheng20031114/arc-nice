@tool
extends Resource
class_name FlowStepConfig

const DEFAULT_EXIT_NAME := FlowExitConfig.DEFAULT_EXIT_NAME

@export_group("流程节点")
@export var step_id: StringName = &""
@export var display_name: String = ""
@export_range(0.0, 600.0, 1.0, "or_greater") var post_clear_rest_duration: float = 0.0
@export var exits: Array[FlowExitConfig] = []
@export var editor_position: Vector2 = Vector2.ZERO


func get_default_exit() -> FlowExitConfig:
	for exit in exits:
		if exit != null and exit.is_default_exit():
			return exit
	return null


func has_default_exit() -> bool:
	return get_default_exit() != null


func get_flow_display_name() -> String:
	if not display_name.strip_edges().is_empty():
		return display_name
	if not String(step_id).is_empty():
		return String(step_id)
	return resource_path.get_file().get_basename()
