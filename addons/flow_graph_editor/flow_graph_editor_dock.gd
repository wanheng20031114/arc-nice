@tool
extends Control

const DEFAULT_GRAPH_PATH := "res://resources/config/flow/default_combat_flow.tres"
const PORT_TYPE_FLOW := 0
const INPUT_PORT_COLOR := Color(0.45, 0.74, 1.0)
const OUTPUT_PORT_COLOR := Color(0.78, 0.55, 1.0)

var _editor_interface
var _current_graph: FlowGraphConfig
var _selected_step: FlowStepConfig
var _step_by_node_name: Dictionary = {}
var _node_name_by_step: Dictionary = {}
var _last_node_positions: Dictionary = {}

var _path_edit: LineEdit
var _step_path_edit: LineEdit
var _status_label: Label
var _graph_edit: GraphEdit
var _selected_label: Label
var _rest_spin: SpinBox
var _exit_selector: OptionButton
var _exit_name_edit: LineEdit


func setup(editor_interface) -> void:
	_editor_interface = editor_interface


func _ready() -> void:
	set_process(true)
	_build_ui()
	_path_edit.text = DEFAULT_GRAPH_PATH
	_load_graph_from_path(DEFAULT_GRAPH_PATH)


func _process(_delta: float) -> void:
	if _current_graph == null:
		return
	for node_name in _step_by_node_name.keys():
		var graph_node := _graph_edit.get_node_or_null(NodePath(str(node_name))) as GraphNode
		if graph_node == null:
			continue
		var step := _step_by_node_name[node_name] as FlowStepConfig
		if step == null:
			continue
		var position := graph_node.position_offset
		if not _last_node_positions.has(node_name) or _last_node_positions[node_name] != position:
			_last_node_positions[node_name] = position
			step.editor_position = position


func _build_ui() -> void:
	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(root)

	var graph_row := HBoxContainer.new()
	root.add_child(graph_row)

	_path_edit = LineEdit.new()
	_path_edit.placeholder_text = "res://path/to/flow_graph.tres"
	_path_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	graph_row.add_child(_path_edit)

	var load_button := Button.new()
	load_button.text = "Load"
	load_button.pressed.connect(_on_load_pressed)
	graph_row.add_child(load_button)

	var save_button := Button.new()
	save_button.text = "Save"
	save_button.pressed.connect(_on_save_pressed)
	graph_row.add_child(save_button)

	var add_row := HBoxContainer.new()
	root.add_child(add_row)

	_step_path_edit = LineEdit.new()
	_step_path_edit.placeholder_text = "res://path/to/wave_or_boss.tres"
	_step_path_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_row.add_child(_step_path_edit)

	var add_step_button := Button.new()
	add_step_button.text = "Add Step"
	add_step_button.pressed.connect(_on_add_step_pressed)
	add_row.add_child(add_step_button)

	root.add_child(HSeparator.new())

	var inspector := VBoxContainer.new()
	root.add_child(inspector)

	_selected_label = Label.new()
	_selected_label.text = "No step selected"
	inspector.add_child(_selected_label)

	var rest_row := HBoxContainer.new()
	inspector.add_child(rest_row)

	var rest_label := Label.new()
	rest_label.text = "Rest"
	rest_row.add_child(rest_label)

	_rest_spin = SpinBox.new()
	_rest_spin.min_value = 0.0
	_rest_spin.max_value = 600.0
	_rest_spin.step = 1.0
	_rest_spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_rest_spin.value_changed.connect(_on_rest_value_changed)
	rest_row.add_child(_rest_spin)

	var exit_row := HBoxContainer.new()
	inspector.add_child(exit_row)

	_exit_selector = OptionButton.new()
	_exit_selector.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_exit_selector.item_selected.connect(_on_exit_selected)
	exit_row.add_child(_exit_selector)

	_exit_name_edit = LineEdit.new()
	_exit_name_edit.placeholder_text = "exit_name"
	_exit_name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	exit_row.add_child(_exit_name_edit)

	var rename_exit_button := Button.new()
	rename_exit_button.text = "Rename"
	rename_exit_button.pressed.connect(_on_rename_exit_pressed)
	exit_row.add_child(rename_exit_button)

	var add_exit_button := Button.new()
	add_exit_button.text = "Add Exit"
	add_exit_button.pressed.connect(_on_add_exit_pressed)
	exit_row.add_child(add_exit_button)

	var delete_exit_button := Button.new()
	delete_exit_button.text = "Delete Exit"
	delete_exit_button.pressed.connect(_on_delete_exit_pressed)
	exit_row.add_child(delete_exit_button)

	_status_label = Label.new()
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(_status_label)

	_graph_edit = GraphEdit.new()
	_graph_edit.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_graph_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_graph_edit.connection_request.connect(_on_connection_request)
	_graph_edit.disconnection_request.connect(_on_disconnection_request)
	if _graph_edit.has_signal("node_selected"):
		_graph_edit.node_selected.connect(_on_graph_node_selected)
	root.add_child(_graph_edit)


func _on_load_pressed() -> void:
	_load_graph_from_path(_path_edit.text.strip_edges())


func _load_graph_from_path(path: String) -> void:
	if path.is_empty():
		_show_status("Enter a FlowGraphConfig path.")
		return
	var graph := ResourceLoader.load(path) as FlowGraphConfig
	if graph == null:
		_show_status("Could not load FlowGraphConfig: %s" % path)
		return
	_current_graph = graph
	_selected_step = null
	_render_graph()
	_show_status("Loaded %s" % path)


func _on_save_pressed() -> void:
	_save_current_graph()


func _save_current_graph() -> void:
	if _current_graph == null:
		_show_status("No graph loaded.")
		return
	for step in _current_graph.steps:
		if step != null and not step.resource_path.is_empty():
			ResourceSaver.save(step, step.resource_path)
	if _current_graph.resource_path.is_empty():
		_show_status("Graph has no resource path.")
		return
	var error := ResourceSaver.save(_current_graph, _current_graph.resource_path)
	if error == OK:
		_show_status("Saved %s" % _current_graph.resource_path)
	else:
		_show_status("Save failed: %s" % error_string(error))


func _on_add_step_pressed() -> void:
	if _current_graph == null:
		_show_status("Load a graph before adding steps.")
		return
	var path := _step_path_edit.text.strip_edges()
	var step := ResourceLoader.load(path) as FlowStepConfig
	if step == null:
		_show_status("Could not load FlowStepConfig: %s" % path)
		return
	if _current_graph.steps.has(step):
		_show_status("Step is already in the graph.")
		return
	if step.editor_position == Vector2.ZERO:
		step.editor_position = Vector2(80.0 + _current_graph.steps.size() * 260.0, 80.0)
	_current_graph.steps.append(step)
	if _current_graph.start_step == null:
		_current_graph.start_step = step
	_render_graph()
	_select_step(step)
	_show_status("Added %s" % step.get_flow_display_name())


func _render_graph() -> void:
	_clear_graph_edit()
	_step_by_node_name.clear()
	_node_name_by_step.clear()
	_last_node_positions.clear()
	if _current_graph == null:
		return

	for index in range(_current_graph.steps.size()):
		var step := _current_graph.steps[index]
		if step == null:
			continue
		var node_name := _get_unique_node_name_for_step(step, index)
		_step_by_node_name[node_name] = step
		_node_name_by_step[step] = node_name
		_add_graph_node(node_name, step, index)

	for step in _current_graph.steps:
		if step == null:
			continue
		var from_name := StringName(str(_node_name_by_step.get(step, "")))
		if from_name == &"":
			continue
		for exit_index in range(step.exits.size()):
			var flow_exit := step.exits[exit_index]
			if flow_exit == null:
				continue
			var target_step := _current_graph.get_exit_target_step(flow_exit)
			if target_step == null:
				continue
			var to_name := StringName(str(_node_name_by_step.get(target_step, "")))
			if to_name == &"":
				continue
			_graph_edit.connect_node(from_name, exit_index, to_name, 0)
	_update_selected_inspector()


func _clear_graph_edit() -> void:
	if _graph_edit == null:
		return
	for connection in _graph_edit.get_connection_list():
		_graph_edit.disconnect_node(
			connection["from_node"],
			int(connection["from_port"]),
			connection["to_node"],
			int(connection["to_port"])
		)
	for child in _graph_edit.get_children():
		if child is GraphNode:
			child.queue_free()


func _add_graph_node(node_name: StringName, step: FlowStepConfig, index: int) -> void:
	var graph_node := GraphNode.new()
	graph_node.name = String(node_name)
	graph_node.title = step.get_flow_display_name()
	graph_node.position_offset = (
		step.editor_position
		if step.editor_position != Vector2.ZERO
		else Vector2(80.0 + index * 260.0, 80.0)
	)
	graph_node.resizable = true
	graph_node.custom_minimum_size = Vector2(220.0, 80.0)
	graph_node.gui_input.connect(_on_graph_node_gui_input.bind(node_name))
	_graph_edit.add_child(graph_node)

	var exit_count := step.exits.size()
	if exit_count <= 0:
		var terminal_label := Label.new()
		terminal_label.text = "terminal"
		graph_node.add_child(terminal_label)
		graph_node.set_slot(0, true, PORT_TYPE_FLOW, INPUT_PORT_COLOR, false, PORT_TYPE_FLOW, OUTPUT_PORT_COLOR)
		_add_node_rest_editor(graph_node, step)
		return

	for exit_index in range(exit_count):
		var flow_exit := step.exits[exit_index]
		var exit_label := Label.new()
		exit_label.text = String(flow_exit.exit_name) if flow_exit != null else "<null exit>"
		graph_node.add_child(exit_label)
		graph_node.set_slot(
			exit_index,
			exit_index == 0,
			PORT_TYPE_FLOW,
			INPUT_PORT_COLOR,
			true,
			PORT_TYPE_FLOW,
			OUTPUT_PORT_COLOR
		)
	_add_node_rest_editor(graph_node, step)


func _add_node_rest_editor(graph_node: GraphNode, step: FlowStepConfig) -> void:
	var rest_row := HBoxContainer.new()
	rest_row.name = "RestEditor"
	graph_node.add_child(rest_row)

	var rest_label := Label.new()
	rest_label.text = "Rest"
	rest_row.add_child(rest_label)

	var rest_spin := SpinBox.new()
	rest_spin.name = "RestSpin"
	rest_spin.min_value = 0.0
	rest_spin.max_value = 600.0
	rest_spin.step = 1.0
	rest_spin.value = step.post_clear_rest_duration
	rest_spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rest_spin.value_changed.connect(_on_node_rest_value_changed.bind(step))
	rest_row.add_child(rest_spin)


func _on_graph_node_gui_input(event: InputEvent, node_name: StringName) -> void:
	if event is InputEventMouseButton and event.pressed:
		var step := _step_by_node_name.get(node_name) as FlowStepConfig
		_select_step(step)


func _on_graph_node_selected(node: Node) -> void:
	if node == null:
		return
	var step := _step_by_node_name.get(StringName(node.name)) as FlowStepConfig
	_select_step(step)


func _select_step(step: FlowStepConfig) -> void:
	_selected_step = step
	_update_selected_inspector()


func _update_selected_inspector() -> void:
	_exit_selector.clear()
	_exit_name_edit.text = ""
	if _selected_step == null:
		_selected_label.text = "No step selected"
		_rest_spin.value = 0.0
		return
	_selected_label.text = "%s (%s)" % [_selected_step.get_flow_display_name(), String(_selected_step.step_id)]
	_rest_spin.value = _selected_step.post_clear_rest_duration
	for index in range(_selected_step.exits.size()):
		var flow_exit := _selected_step.exits[index]
		_exit_selector.add_item(String(flow_exit.exit_name) if flow_exit != null else "<null>", index)
	if _selected_step.exits.size() > 0:
		_exit_selector.select(0)
		var first_exit := _selected_step.exits[0]
		if first_exit != null:
			_exit_name_edit.text = String(first_exit.exit_name)


func _on_rest_value_changed(value: float) -> void:
	if _selected_step == null:
		return
	_selected_step.post_clear_rest_duration = value
	_sync_node_rest_spin(_selected_step)


func _on_node_rest_value_changed(value: float, step: FlowStepConfig) -> void:
	if step == null:
		return
	step.post_clear_rest_duration = value
	if step == _selected_step:
		_rest_spin.value = value
	_show_status("%s rest = %d" % [step.get_flow_display_name(), int(value)])


func _sync_node_rest_spin(step: FlowStepConfig) -> void:
	if step == null or _graph_edit == null:
		return
	var node_name := StringName(str(_node_name_by_step.get(step, "")))
	if node_name == &"":
		return
	var graph_node := _graph_edit.get_node_or_null(NodePath(String(node_name))) as GraphNode
	if graph_node == null:
		return
	var rest_spin := graph_node.get_node_or_null("RestEditor/RestSpin") as SpinBox
	if rest_spin != null:
		rest_spin.value = step.post_clear_rest_duration


func _on_exit_selected(index: int) -> void:
	if _selected_step == null:
		return
	if index < 0 or index >= _selected_step.exits.size():
		return
	var flow_exit := _selected_step.exits[index]
	_exit_name_edit.text = String(flow_exit.exit_name) if flow_exit != null else ""


func _on_rename_exit_pressed() -> void:
	if _selected_step == null:
		return
	var index := _exit_selector.get_selected()
	if index < 0 or index >= _selected_step.exits.size():
		return
	var exit_name := StringName(_exit_name_edit.text.strip_edges())
	if exit_name == &"":
		_show_status("Exit name cannot be empty.")
		return
	var flow_exit := _selected_step.exits[index]
	if flow_exit == null:
		return
	flow_exit.exit_name = exit_name
	_render_graph()
	_select_step(_selected_step)


func _on_add_exit_pressed() -> void:
	if _selected_step == null:
		_show_status("Select a step first.")
		return
	var exit_name := StringName(_exit_name_edit.text.strip_edges())
	if exit_name == &"":
		exit_name = FlowExitConfig.DEFAULT_EXIT_NAME
	for flow_exit in _selected_step.exits:
		if flow_exit != null and flow_exit.exit_name == exit_name:
			_show_status("Exit already exists: %s" % String(exit_name))
			return
	var new_exit := FlowExitConfig.new()
	new_exit.exit_name = exit_name
	_selected_step.exits.append(new_exit)
	_render_graph()
	_select_step(_selected_step)


func _on_delete_exit_pressed() -> void:
	if _selected_step == null:
		return
	var index := _exit_selector.get_selected()
	if index < 0 or index >= _selected_step.exits.size():
		return
	_selected_step.exits.remove_at(index)
	_render_graph()
	_select_step(_selected_step)


func _on_connection_request(
	from_node: StringName,
	from_port: int,
	to_node: StringName,
	_to_port: int
) -> void:
	if _current_graph == null:
		return
	var from_step := _step_by_node_name.get(from_node) as FlowStepConfig
	var to_step := _step_by_node_name.get(to_node) as FlowStepConfig
	if from_step == null or to_step == null:
		return
	if to_step.step_id == &"":
		_show_status("Target step is missing step_id.")
		return
	var structural_change := false
	while from_step.exits.size() <= from_port:
		var default_exit := FlowExitConfig.new()
		default_exit.exit_name = FlowExitConfig.DEFAULT_EXIT_NAME
		from_step.exits.append(default_exit)
		structural_change = true
	var flow_exit := from_step.exits[from_port]
	if flow_exit == null:
		flow_exit = FlowExitConfig.new()
		flow_exit.exit_name = FlowExitConfig.DEFAULT_EXIT_NAME
		from_step.exits[from_port] = flow_exit
		structural_change = true
	flow_exit.target_step_id = to_step.step_id
	flow_exit.target_step = null
	_select_step(from_step)
	if structural_change:
		call_deferred("_render_graph")
		return
	_disconnect_connections_from_port(from_node, from_port)
	_graph_edit.connect_node(from_node, from_port, to_node, _to_port)
	_show_status(
		"%s.%s -> %s"
		% [from_step.get_flow_display_name(), String(flow_exit.exit_name), to_step.get_flow_display_name()]
	)


func _on_disconnection_request(
	from_node: StringName,
	from_port: int,
	_to_node: StringName,
	_to_port: int
) -> void:
	var from_step := _step_by_node_name.get(from_node) as FlowStepConfig
	if from_step == null:
		return
	if from_port < 0 or from_port >= from_step.exits.size():
		return
	var flow_exit := from_step.exits[from_port]
	if flow_exit != null:
		flow_exit.target_step_id = &""
		flow_exit.target_step = null
	if _is_graph_connected(from_node, from_port, _to_node, _to_port):
		_graph_edit.disconnect_node(from_node, from_port, _to_node, _to_port)
	_select_step(from_step)


func _disconnect_connections_from_port(from_node: StringName, from_port: int) -> void:
	for connection in _graph_edit.get_connection_list():
		if connection["from_node"] == from_node and int(connection["from_port"]) == from_port:
			_graph_edit.disconnect_node(
				connection["from_node"],
				int(connection["from_port"]),
				connection["to_node"],
				int(connection["to_port"])
			)


func _is_graph_connected(
	from_node: StringName,
	from_port: int,
	to_node: StringName,
	to_port: int
) -> bool:
	for connection in _graph_edit.get_connection_list():
		if (
			connection["from_node"] == from_node
			and int(connection["from_port"]) == from_port
			and connection["to_node"] == to_node
			and int(connection["to_port"]) == to_port
		):
			return true
	return false


func _get_unique_node_name_for_step(step: FlowStepConfig, index: int) -> StringName:
	var base_name := String(step.step_id)
	if base_name.is_empty():
		base_name = "step_%02d" % index
	var node_name := _sanitize_node_name(base_name)
	if node_name.is_empty():
		node_name = "step_%02d" % index
	var candidate := node_name
	var suffix := 2
	while _step_by_node_name.has(StringName(candidate)):
		candidate = "%s_%d" % [node_name, suffix]
		suffix += 1
	return StringName(candidate)


func _sanitize_node_name(value: String) -> String:
	var result := ""
	for index in range(value.length()):
		var character := value.substr(index, 1)
		var code := character.unicode_at(0)
		var is_ascii_letter := (
			(code >= 65 and code <= 90)
			or (code >= 97 and code <= 122)
		)
		var is_ascii_digit := code >= 48 and code <= 57
		if is_ascii_letter or is_ascii_digit or character == "_":
			result += character
		else:
			result += "_"
	return result.strip_edges()


func _show_status(message: String) -> void:
	if _status_label != null:
		_status_label.text = message
