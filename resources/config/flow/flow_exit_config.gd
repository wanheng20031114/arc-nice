@tool
extends Resource
class_name FlowExitConfig

const DEFAULT_EXIT_NAME := &"default"

@export var exit_name: StringName = DEFAULT_EXIT_NAME
@export var target_step_id: StringName = &""
var target_step: FlowStepConfig
@export var condition_key: StringName = &""


func is_default_exit() -> bool:
	return exit_name == DEFAULT_EXIT_NAME


func get_target_step_id() -> StringName:
	if target_step_id != &"":
		return target_step_id
	return target_step.step_id if target_step != null else &""
