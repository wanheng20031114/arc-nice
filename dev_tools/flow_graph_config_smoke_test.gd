extends SceneTree

const DEFAULT_FLOW := preload("res://resources/config/flow/default_combat_flow.tres")

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_default_flow_is_valid()
	_test_missing_start_is_invalid()
	_test_duplicate_exit_names_are_invalid()
	_test_non_terminal_step_requires_default_exit()
	_test_exit_target_must_be_in_steps()

	if failures.is_empty():
		print("FLOW_GRAPH_CONFIG_SMOKE_TEST_OK")
		quit()
		return

	for failure in failures:
		push_error(failure)
	quit(1)


func _test_default_flow_is_valid() -> void:
	_expect(DEFAULT_FLOW != null, "Default flow resource must load.")
	if DEFAULT_FLOW == null:
		return
	var errors := DEFAULT_FLOW.validate_graph()
	_expect(errors.is_empty(), "Default flow must validate without errors: %s" % str(errors))
	_expect(DEFAULT_FLOW.start_step != null, "Default flow must have a start step.")
	_expect(DEFAULT_FLOW.start_step.step_id == &"wave_01", "Default flow must start at wave_01.")
	_expect(DEFAULT_FLOW.get_step_by_id(&"boss_01_linglan") is BossConfig, "Default flow must include Linglan boss.")


func _test_missing_start_is_invalid() -> void:
	var graph := FlowGraphConfig.new()
	graph.steps = [_make_step(&"step_a")]
	var errors := graph.validate_graph()
	_expect(_has_error_containing(errors, "start_step"), "Missing start_step must be reported.")


func _test_duplicate_exit_names_are_invalid() -> void:
	var first_step := _make_step(&"step_a")
	var second_step := _make_step(&"step_b")
	var first_exit := _make_exit(&"default", second_step)
	var duplicate_exit := _make_exit(&"default", second_step)
	first_step.exits = [first_exit, duplicate_exit]

	var graph := _make_graph(first_step, [first_step, second_step])
	var errors := graph.validate_graph()
	_expect(_has_error_containing(errors, "重复出口"), "Duplicate exit names must be reported.")


func _test_non_terminal_step_requires_default_exit() -> void:
	var first_step := _make_step(&"step_a")
	var second_step := _make_step(&"step_b")
	first_step.exits = [_make_exit(&"branch_a", second_step)]

	var graph := _make_graph(first_step, [first_step, second_step])
	var errors := graph.validate_graph()
	_expect(_has_error_containing(errors, "default"), "A step with exits must include a default exit.")


func _test_exit_target_must_be_in_steps() -> void:
	var first_step := _make_step(&"step_a")
	var outside_step := _make_step(&"outside_step")
	first_step.exits = [_make_exit(&"default", outside_step)]

	var graph := _make_graph(first_step, [first_step])
	var errors := graph.validate_graph()
	_expect(_has_error_containing(errors, "不在 steps"), "Exit target outside the graph must be reported.")


func _make_graph(start_step: FlowStepConfig, steps: Array[FlowStepConfig]) -> FlowGraphConfig:
	var graph := FlowGraphConfig.new()
	graph.start_step = start_step
	graph.steps = steps
	return graph


func _make_step(step_id: StringName) -> FlowStepConfig:
	var step := FlowStepConfig.new()
	step.step_id = step_id
	step.display_name = String(step_id)
	return step


func _make_exit(exit_name: StringName, target_step: FlowStepConfig) -> FlowExitConfig:
	var flow_exit := FlowExitConfig.new()
	flow_exit.exit_name = exit_name
	flow_exit.target_step_id = target_step.step_id if target_step != null else &""
	return flow_exit


func _has_error_containing(errors: PackedStringArray, needle: String) -> bool:
	for error in errors:
		if error.contains(needle):
			return true
	return false


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
