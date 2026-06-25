@tool
extends Resource
class_name FlowGraphConfig

@export var graph_name: String = "战斗流程"
@export var start_step: FlowStepConfig
@export var steps: Array[FlowStepConfig] = []


func get_step_by_id(step_id: StringName) -> FlowStepConfig:
	for step in steps:
		if step != null and step.step_id == step_id:
			return step
	return null


func get_step_index(step: FlowStepConfig) -> int:
	if step == null:
		return -1
	for index in range(steps.size()):
		if steps[index] == step:
			return index
	return -1


func get_exit_target_step(flow_exit: FlowExitConfig) -> FlowStepConfig:
	if flow_exit == null:
		return null
	if flow_exit.target_step != null:
		return flow_exit.target_step
	return get_step_by_id(flow_exit.target_step_id)


func get_default_next_step(step: FlowStepConfig) -> FlowStepConfig:
	if step == null:
		return null
	return get_exit_target_step(step.get_default_exit())


func validate_graph() -> PackedStringArray:
	var errors := PackedStringArray()
	if start_step == null:
		errors.append("流程图缺少 start_step。")
	elif get_step_index(start_step) < 0:
		errors.append("start_step 必须包含在 steps 中。")

	var seen_ids: Dictionary = {}
	for step in steps:
		if step == null:
			errors.append("steps 中包含空节点。")
			continue
		if step.step_id == &"":
			errors.append("节点缺少 step_id：%s" % step.resource_path)
		elif seen_ids.has(step.step_id):
			errors.append("重复的 step_id：%s" % String(step.step_id))
		else:
			seen_ids[step.step_id] = true

		var seen_exits: Dictionary = {}
		for exit in step.exits:
			if exit == null:
				errors.append("节点 %s 包含空出口。" % step.get_flow_display_name())
				continue
			if exit.exit_name == &"":
				errors.append("节点 %s 包含未命名出口。" % step.get_flow_display_name())
			elif seen_exits.has(exit.exit_name):
				errors.append(
					"节点 %s 包含重复出口 %s。"
					% [step.get_flow_display_name(), String(exit.exit_name)]
				)
			else:
				seen_exits[exit.exit_name] = true
			var target_step_id := exit.get_target_step_id()
			if target_step_id == &"":
				errors.append(
					"节点 %s 的出口 %s 缺少目标节点。"
					% [step.get_flow_display_name(), String(exit.exit_name)]
				)
			elif get_step_by_id(target_step_id) == null:
				errors.append(
					"节点 %s 的出口 %s 指向不在 steps 中的节点。"
					% [step.get_flow_display_name(), String(exit.exit_name)]
				)
		if not step.exits.is_empty() and not step.has_default_exit():
			errors.append("非终点节点 %s 缺少 default 出口。" % step.get_flow_display_name())
	return errors
