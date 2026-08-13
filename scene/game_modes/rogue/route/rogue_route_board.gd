extends Control
class_name RogueRouteBoard

signal node_pressed(node_id: int)
signal layout_bounds_changed(bounds: Rect2)
signal entry_reveal_finished

const CELL_SCENE: PackedScene = preload(
	"res://scene/game_modes/rogue/route/rogue_route_cell.tscn"
)
const INVALID_NODE_ID := -1
const ENTRY_REVEAL_DURATION_SECONDS := 1.45
const NODE_ROOT_REVEAL_SPAN := 0.16
const NODE_REVEAL_EDGE_OFFSET := 0.10
const NODE_REVEAL_SPAN := 0.12
@export var world_metrics: RogueRouteWorldMetrics

@onready var connections: RogueRouteConnections = $Connections
@onready var cell_layer: Control = $CellLayer
@onready var waiting_label: Label = $WaitingLabel

var graph: RogueRouteGraph = null
var generation_config: RogueRouteGenerationConfig = null
var current_node_id := INVALID_NODE_ID
var action_points := 0
var move_action_cost := 1
var selected_node_id := INVALID_NODE_ID
var visited_counts := PackedInt32Array()
var _authority_enabled := true
var _interaction_locked := false
var _cells: Dictionary[int, RogueRouteCell] = {}
var _node_positions: Dictionary[int, Vector2] = {}
var _entry_reveal_tween: Tween = null
var _entry_reveal_prepared := false
var _entry_reveal_progress := 1.0
var _entry_reveal_serial := 0
var _entry_reveal_depths: Dictionary[int, int] = {}
var _entry_reveal_max_depth := 0


func _ready() -> void:
	if world_metrics != null and world_metrics.validate_metrics().is_empty():
		_set_layout_size(world_metrics.get_layout_size(
			world_metrics.default_grid_size
		))
	waiting_label.hide()


func present_graph(
	new_graph: RogueRouteGraph,
	new_generation_config: RogueRouteGenerationConfig,
	initial_current_node_id: int,
	initial_action_points: int,
	initial_visited_counts: PackedInt32Array,
	authority_enabled: bool,
	prepare_entry_reveal_animation: bool = true
) -> bool:
	if (
		new_graph == null
		or new_generation_config == null
		or not new_graph.validate_layout().is_empty()
		or not new_generation_config.validate_config().is_empty()
		or not _is_graph_compatible_with_world(
			new_graph,
			new_generation_config
		)
		or not _is_valid_runtime_view(
			new_graph,
			initial_current_node_id,
			initial_action_points,
			initial_visited_counts
		)
	):
		return false
	_clear_cells()
	graph = new_graph
	generation_config = new_generation_config
	current_node_id = initial_current_node_id
	action_points = initial_action_points
	move_action_cost = generation_config.move_action_cost
	visited_counts = initial_visited_counts.duplicate()
	_authority_enabled = authority_enabled
	selected_node_id = INVALID_NODE_ID
	for node_id in range(graph.get_node_count()):
		var cell := CELL_SCENE.instantiate() as RogueRouteCell
		if cell == null:
			_clear_cells()
			return false
		cell_layer.add_child(cell)
		var node_type := graph.get_node_type(node_id)
		var is_empty := node_type == RogueRouteGraph.NodeType.EMPTY
		var display_name := "空白区域"
		var icon: Texture2D = null
		if not is_empty:
			var type_config := generation_config.get_type_config(node_type)
			if type_config != null:
				display_name = type_config.display_name
				icon = type_config.icon
		cell.setup(node_id, display_name, icon, is_empty)
		cell.node_pressed.connect(_on_cell_pressed)
		_cells[node_id] = cell
	waiting_label.hide()
	_layout_cells()
	_update_cell_states()
	if prepare_entry_reveal_animation:
		prepare_entry_reveal(initial_current_node_id)
	else:
		complete_entry_reveal()
	return true


func show_waiting_for_host() -> void:
	_clear_cells()
	waiting_label.text = "正在等待房主同步路线图…"
	waiting_label.show()


func update_runtime_state(
	new_current_node_id: int,
	new_action_points: int,
	new_visited_counts: PackedInt32Array,
	_animate_marker: bool = true
) -> bool:
	if (
		not _is_valid_runtime_view(
			graph,
			new_current_node_id,
			new_action_points,
			new_visited_counts
		)
	):
		return false
	current_node_id = new_current_node_id
	action_points = new_action_points
	visited_counts = new_visited_counts.duplicate()
	selected_node_id = INVALID_NODE_ID
	_update_cell_states()
	return true


func set_authority_enabled(enabled: bool) -> void:
	if _authority_enabled == enabled:
		return
	_authority_enabled = enabled
	_update_cell_states()


func set_interaction_locked(locked: bool) -> void:
	if _interaction_locked == locked:
		return
	_interaction_locked = locked
	_update_cell_states()


func select_node(node_id: int) -> void:
	if graph == null or not graph.is_valid_node_id(node_id):
		clear_selection()
		return
	selected_node_id = node_id
	for cell_node_id in _cells:
		_cells[cell_node_id].set_selected(cell_node_id == selected_node_id)


func clear_selection() -> void:
	if selected_node_id == INVALID_NODE_ID:
		return
	selected_node_id = INVALID_NODE_ID
	for cell in _cells.values():
		(cell as RogueRouteCell).set_selected(false)


func get_node_position(node_id: int) -> Vector2:
	return _node_positions.get(node_id, Vector2.ZERO)


func get_node_global_position(node_id: int) -> Vector2:
	return get_global_transform() * get_node_position(node_id)


func get_world_bounds() -> Rect2:
	var transform := get_global_transform()
	var bounds := Rect2(transform * Vector2.ZERO, Vector2.ZERO)
	bounds = bounds.expand(transform * Vector2(size.x, 0.0))
	bounds = bounds.expand(transform * size)
	bounds = bounds.expand(transform * Vector2(0.0, size.y))
	return bounds


func get_world_metrics() -> RogueRouteWorldMetrics:
	return world_metrics


func get_default_spawn_global_position(
	target_config: RogueRouteGenerationConfig = null
) -> Vector2:
	if (
		graph != null
		and graph.is_valid_node_id(graph.start_node_id)
		and _node_positions.has(graph.start_node_id)
	):
		return get_node_global_position(graph.start_node_id)
	if world_metrics == null:
		return global_position
	var width := (
		target_config.width
		if target_config != null
		else world_metrics.default_grid_size.x
	)
	var height := (
		target_config.height
		if target_config != null
		else world_metrics.default_grid_size.y
	)
	var center_coord := Vector2i(width / 2, height / 2)
	return get_global_transform() * (
		world_metrics.board_margin
		+ Vector2(center_coord.x, center_coord.y) * world_metrics.cell_spacing
	)


func can_interact_with_node(node_id: int) -> bool:
	return (
		graph != null
		and _authority_enabled
		and not _interaction_locked
		and action_points >= move_action_cost
		and graph.has_edge(current_node_id, node_id)
	)


func get_cell(node_id: int) -> RogueRouteCell:
	return _cells.get(node_id) as RogueRouteCell


func prepare_entry_reveal(root_node_id: int = INVALID_NODE_ID) -> bool:
	if graph == null or _cells.is_empty():
		return false
	var resolved_root_id := root_node_id
	if not graph.is_valid_node_id(resolved_root_id):
		resolved_root_id = current_node_id
	if not graph.is_valid_node_id(resolved_root_id):
		return false
	_stop_entry_reveal_tween()
	_entry_reveal_serial += 1
	_entry_reveal_depths = _build_entry_reveal_depths(resolved_root_id)
	if _entry_reveal_depths.size() != graph.get_node_count():
		_entry_reveal_depths.clear()
		_entry_reveal_max_depth = 0
		return false
	_entry_reveal_max_depth = 0
	for depth in _entry_reveal_depths.values():
		_entry_reveal_max_depth = maxi(_entry_reveal_max_depth, int(depth))
	_entry_reveal_prepared = true
	_entry_reveal_progress = 0.0
	connections.prepare_entry_reveal(
		_entry_reveal_depths,
		_entry_reveal_max_depth
	)
	for cell in _cells.values():
		(cell as RogueRouteCell).prepare_entry_reveal()
	_apply_entry_reveal_progress(0.0)
	return true


func play_entry_reveal(
	duration_seconds: float = ENTRY_REVEAL_DURATION_SECONDS
) -> void:
	if graph == null or _cells.is_empty():
		return
	if not _entry_reveal_prepared and not prepare_entry_reveal(current_node_id):
		return
	_stop_entry_reveal_tween()
	if duration_seconds <= 0.0 or _entry_reveal_progress >= 0.9999:
		complete_entry_reveal()
		return
	_entry_reveal_serial += 1
	var play_serial := _entry_reveal_serial
	var tween := create_tween()
	_entry_reveal_tween = tween
	tween.tween_method(
		_apply_entry_reveal_progress,
		_entry_reveal_progress,
		1.0,
		duration_seconds * (1.0 - _entry_reveal_progress)
	).set_trans(Tween.TRANS_LINEAR).set_ease(Tween.EASE_IN_OUT)
	tween.finished.connect(
		_on_entry_reveal_tween_finished.bind(tween, play_serial),
		CONNECT_ONE_SHOT
	)


func complete_entry_reveal() -> void:
	var had_pending_reveal := (
		_entry_reveal_prepared
		or _entry_reveal_tween != null
		or not is_equal_approx(_entry_reveal_progress, 1.0)
	)
	_stop_entry_reveal_tween()
	_entry_reveal_serial += 1
	_entry_reveal_prepared = false
	_entry_reveal_progress = 1.0
	_entry_reveal_depths.clear()
	_entry_reveal_max_depth = 0
	connections.complete_entry_reveal()
	for cell in _cells.values():
		(cell as RogueRouteCell).complete_entry_reveal()
	if had_pending_reveal:
		entry_reveal_finished.emit()


func is_entry_reveal_playing() -> bool:
	return _entry_reveal_tween != null and _entry_reveal_tween.is_running()


func is_entry_reveal_prepared() -> bool:
	return _entry_reveal_prepared


func get_entry_reveal_progress() -> float:
	return _entry_reveal_progress


func _layout_cells() -> void:
	if graph == null or _cells.is_empty() or world_metrics == null:
		return
	_node_positions.clear()
	_set_layout_size(world_metrics.get_layout_size(
		Vector2i(graph.width, graph.height)
	))
	for node_id in range(graph.get_node_count()):
		var coord := graph.id_to_coord(node_id)
		var anchor := (
			world_metrics.board_margin
			+ Vector2(float(coord.x), float(coord.y)) * world_metrics.cell_spacing
		)
		var cell := _cells[node_id]
		cell.position = anchor - cell.get_connection_anchor()
		_node_positions[node_id] = anchor
	connections.set_node_positions(_node_positions)


func _update_cell_states() -> void:
	if graph == null:
		return
	var neighbors := graph.get_neighbors(current_node_id)
	var near_lookup: Dictionary[int, bool] = {current_node_id: true}
	for neighbor_id in neighbors:
		near_lookup[int(neighbor_id)] = true
	var has_action_points := action_points >= move_action_cost
	for node_id in _cells:
		var cell := _cells[node_id]
		cell.set_authority_enabled(_authority_enabled)
		cell.set_click_enabled(
			_authority_enabled
			and not _interaction_locked
			and has_action_points
			and neighbors.has(node_id)
		)
		cell.set_near(near_lookup.has(node_id))
		cell.set_selected(node_id == selected_node_id)
		cell.set_current(node_id == current_node_id)
		cell.set_visited(
			node_id < visited_counts.size() and visited_counts[node_id] > 0
		)
	connections.setup(
		_node_positions,
		graph.edges,
		current_node_id,
		neighbors
	)


func _clear_cells() -> void:
	_stop_entry_reveal_tween()
	_entry_reveal_serial += 1
	_entry_reveal_prepared = false
	_entry_reveal_progress = 1.0
	_entry_reveal_depths.clear()
	_entry_reveal_max_depth = 0
	for cell in _cells.values():
		var route_cell := cell as RogueRouteCell
		if route_cell.get_parent() == cell_layer:
			cell_layer.remove_child(route_cell)
		route_cell.queue_free()
	_cells.clear()
	_node_positions.clear()
	graph = null
	generation_config = null
	current_node_id = INVALID_NODE_ID
	selected_node_id = INVALID_NODE_ID
	visited_counts = PackedInt32Array()
	connections.setup({}, PackedInt32Array(), INVALID_NODE_ID, PackedInt32Array())
	connections.complete_entry_reveal()


func _apply_entry_reveal_progress(progress: float) -> void:
	_entry_reveal_progress = clampf(progress, 0.0, 1.0)
	connections.set_entry_reveal_progress(_entry_reveal_progress)
	for node_id in _cells:
		var depth: int = _entry_reveal_depths.get(node_id, 0)
		var local_progress := _get_node_entry_reveal_progress(depth)
		_cells[node_id].set_entry_reveal_progress(local_progress)


func _get_node_entry_reveal_progress(depth: int) -> float:
	if depth <= 0:
		return smoothstep(
			0.0,
			NODE_ROOT_REVEAL_SPAN,
			_entry_reveal_progress
		)
	var start_progress := (
		connections.get_wave_start_progress(depth)
		+ NODE_REVEAL_EDGE_OFFSET
	)
	return smoothstep(
		start_progress,
		start_progress + NODE_REVEAL_SPAN,
		_entry_reveal_progress
	)


func _build_entry_reveal_depths(root_node_id: int) -> Dictionary[int, int]:
	var depths: Dictionary[int, int] = {root_node_id: 0}
	var pending := PackedInt32Array([root_node_id])
	var read_index := 0
	while read_index < pending.size():
		var node_id := int(pending[read_index])
		read_index += 1
		var next_depth := int(depths[node_id]) + 1
		for neighbor_id_variant in graph.get_neighbors(node_id):
			var neighbor_id := int(neighbor_id_variant)
			if depths.has(neighbor_id):
				continue
			depths[neighbor_id] = next_depth
			pending.append(neighbor_id)
	return depths


func _stop_entry_reveal_tween() -> void:
	if _entry_reveal_tween == null:
		return
	_entry_reveal_tween.kill()
	_entry_reveal_tween = null


func _on_entry_reveal_tween_finished(
	tween: Tween,
	play_serial: int
) -> void:
	if tween != _entry_reveal_tween or play_serial != _entry_reveal_serial:
		return
	_entry_reveal_tween = null
	complete_entry_reveal()


func _on_cell_pressed(node_id: int) -> void:
	if not can_interact_with_node(node_id):
		return
	node_pressed.emit(node_id)


func _is_valid_runtime_view(
	target_graph: RogueRouteGraph,
	target_node_id: int,
	target_action_points: int,
	target_visited_counts: PackedInt32Array
) -> bool:
	if (
		target_graph == null
		or not target_graph.is_valid_node_id(target_node_id)
		or target_action_points < 0
		or target_visited_counts.size() != target_graph.get_node_count()
		or target_visited_counts[target_node_id] <= 0
	):
		return false
	for visit_count in target_visited_counts:
		if visit_count < 0:
			return false
	return true


func _set_layout_size(layout_size: Vector2) -> void:
	if size.is_equal_approx(layout_size):
		return
	size = layout_size
	layout_bounds_changed.emit(get_world_bounds())


func _is_graph_compatible_with_world(
	target_graph: RogueRouteGraph,
	target_config: RogueRouteGenerationConfig
) -> bool:
	if world_metrics == null or not world_metrics.validate_metrics().is_empty():
		return false
	var maximum_jitter := target_config.visual_jitter_pixels
	if (
		float(maximum_jitter.x) * 2.0 >= world_metrics.cell_spacing.x
		or float(maximum_jitter.y) * 2.0 >= world_metrics.cell_spacing.y
	):
		return false
	for offset in target_graph.visual_offsets:
		if (
			absf(offset.x) > float(maximum_jitter.x)
			or absf(offset.y) > float(maximum_jitter.y)
		):
			return false
	return true
