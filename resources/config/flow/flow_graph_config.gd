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
	# 运行时与校验都以序列化 step_id 为准；瞬态编辑器引用只负责提供该 ID。
	return get_step_by_id(flow_exit.get_target_step_id())


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

	# 引用合法并不代表流程可执行；可达性和终点闭包必须从 start_step 统一证明。
	if start_step != null and get_step_index(start_step) >= 0:
		_append_topology_errors(errors)
	return errors


func _append_topology_errors(errors: PackedStringArray) -> void:
	var reachable_step_ids: Dictionary = {}
	var pending_steps: Array[FlowStepConfig] = [start_step]
	while not pending_steps.is_empty():
		var current_step: FlowStepConfig = pending_steps.pop_back()
		if current_step == null:
			continue
		var current_instance_id: int = current_step.get_instance_id()
		if reachable_step_ids.has(current_instance_id):
			continue
		reachable_step_ids[current_instance_id] = true
		var target_step := get_default_next_step(current_step)
		if target_step != null and get_step_index(target_step) >= 0:
			pending_steps.append(target_step)

	for step in steps:
		if step != null and not reachable_step_ids.has(step.get_instance_id()):
			errors.append("流程节点 %s 无法从 start_step 到达。" % step.get_flow_display_name())

	var can_reach_terminal: Dictionary = {}
	for step in steps:
		if step != null and step.exits.is_empty():
			can_reach_terminal[step.get_instance_id()] = true
	if can_reach_terminal.is_empty():
		errors.append("流程图不存在终点节点。")

	# 当前运行时只消费 default 出口；闭包证明必须与真实推进语义完全一致。
	var changed := true
	while changed:
		changed = false
		for step in steps:
			if step == null or can_reach_terminal.has(step.get_instance_id()):
				continue
			var target_step := get_default_next_step(step)
			if target_step != null and can_reach_terminal.has(target_step.get_instance_id()):
				can_reach_terminal[step.get_instance_id()] = true
				changed = true

	for step in steps:
		if (
			step != null
			and reachable_step_ids.has(step.get_instance_id())
			and not can_reach_terminal.has(step.get_instance_id())
		):
			errors.append("从流程节点 %s 无法到达终点。" % step.get_flow_display_name())
