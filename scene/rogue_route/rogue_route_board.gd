extends Control
class_name RogueRouteBoard

signal node_pressed(node_id: int)

const CELL_SCENE: PackedScene = preload(
	"res://scene/rogue_route/rogue_route_cell.tscn"
)
const INVALID_NODE_ID := -1
const CELL_ANCHOR_FALLBACK := Vector2(32.0, 28.0)
const CELL_SPACING := Vector2(256.0, 192.0)
const BOARD_MARGIN := Vector2(320.0, 192.0)
const NODE_INTERACTION_RADIUS := 88.0
const MARKER_MOVE_SECONDS := 0.24

@onready var connections: RogueRouteConnections = $Connections
@onready var cell_layer: Control = $CellLayer
@onready var group_marker: Control = $GroupMarker
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
var _local_player_position := Vector2.ZERO
var _has_local_player_position := false
var _nodes_in_player_range: Dictionary[int, bool] = {}
var _marker_tween: Tween = null


func _ready() -> void:
	group_marker.hide()
	waiting_label.hide()


func present_graph(
	new_graph: RogueRouteGraph,
	new_generation_config: RogueRouteGenerationConfig,
	initial_current_node_id: int,
	initial_action_points: int,
	initial_visited_counts: PackedInt32Array,
	authority_enabled: bool
) -> bool:
	if (
		new_graph == null
		or new_generation_config == null
		or not new_graph.validate_layout().is_empty()
		or not new_generation_config.validate_config().is_empty()
		or new_generation_config.width != new_graph.width
		or new_generation_config.height != new_graph.height
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
	group_marker.show()
	_layout_cells()
	_update_cell_states(false)
	return true


func show_waiting_for_host() -> void:
	_clear_cells()
	waiting_label.text = "正在等待房主同步路线图…"
	waiting_label.show()


func update_runtime_state(
	new_current_node_id: int,
	new_action_points: int,
	new_visited_counts: PackedInt32Array,
	animate_marker: bool = true
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
	var previous_node_id := current_node_id
	current_node_id = new_current_node_id
	action_points = new_action_points
	visited_counts = new_visited_counts.duplicate()
	selected_node_id = INVALID_NODE_ID
	_update_cell_states(animate_marker and previous_node_id != current_node_id)
	return true


func set_authority_enabled(enabled: bool) -> void:
	if _authority_enabled == enabled:
		return
	_authority_enabled = enabled
	_update_cell_states(false)


func set_interaction_locked(locked: bool) -> void:
	if _interaction_locked == locked:
		return
	_interaction_locked = locked
	_update_cell_states(false)


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
	return Rect2(get_global_transform() * Vector2.ZERO, size)


func get_default_spawn_global_position(
	target_config: RogueRouteGenerationConfig = null
) -> Vector2:
	var width := target_config.width if target_config != null else 11
	var height := target_config.height if target_config != null else 9
	var center_coord := Vector2i(width / 2, height / 2)
	return get_global_transform() * (
		BOARD_MARGIN
		+ Vector2(center_coord.x, center_coord.y) * CELL_SPACING
	)


func update_local_player_global_position(player_global_position: Vector2) -> void:
	_local_player_position = (
		get_global_transform().affine_inverse() * player_global_position
	)
	_has_local_player_position = true
	_refresh_player_range_interactions()


func clear_local_player_position() -> void:
	_has_local_player_position = false
	_nodes_in_player_range.clear()
	_refresh_neighbor_click_states()


func can_interact_with_node(node_id: int) -> bool:
	return (
		graph != null
		and _authority_enabled
		and not _interaction_locked
		and action_points >= move_action_cost
		and graph.has_edge(current_node_id, node_id)
		and _nodes_in_player_range.has(node_id)
	)


func is_node_in_player_range(node_id: int) -> bool:
	return _nodes_in_player_range.has(node_id)


func get_cell(node_id: int) -> RogueRouteCell:
	return _cells.get(node_id) as RogueRouteCell


func _layout_cells() -> void:
	if graph == null or _cells.is_empty():
		return
	_node_positions.clear()
	size = Vector2(
		BOARD_MARGIN.x * 2.0 + CELL_SPACING.x * float(maxi(graph.width - 1, 0)),
		BOARD_MARGIN.y * 2.0 + CELL_SPACING.y * float(maxi(graph.height - 1, 0))
	)
	for node_id in range(graph.get_node_count()):
		var coord := graph.id_to_coord(node_id)
		var anchor := (
			BOARD_MARGIN
			+ Vector2(float(coord.x), float(coord.y)) * CELL_SPACING
			+ graph.get_visual_offset(node_id)
		)
		var cell := _cells[node_id]
		cell.position = anchor - cell.get_connection_anchor()
		_node_positions[node_id] = anchor
	connections.set_node_positions(_node_positions)
	_position_marker_immediately()
	_refresh_player_range_interactions()


func _update_cell_states(animate_marker: bool) -> void:
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
			and _nodes_in_player_range.has(node_id)
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
	if animate_marker:
		_animate_marker_to_current()
	else:
		_position_marker_immediately()


func _position_marker_immediately() -> void:
	if graph == null or not _node_positions.has(current_node_id):
		return
	if _marker_tween != null:
		_marker_tween.kill()
		_marker_tween = null
	group_marker.position = _node_positions[current_node_id]


func _animate_marker_to_current() -> void:
	if graph == null or not _node_positions.has(current_node_id):
		return
	if _marker_tween != null:
		_marker_tween.kill()
	_marker_tween = create_tween()
	_marker_tween.tween_property(
		group_marker,
		"position",
		_node_positions[current_node_id],
		MARKER_MOVE_SECONDS
	).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	_marker_tween.finished.connect(func() -> void:
		_marker_tween = null
	)


func _clear_cells() -> void:
	if _marker_tween != null:
		_marker_tween.kill()
		_marker_tween = null
	for cell in _cells.values():
		(cell as RogueRouteCell).queue_free()
	_cells.clear()
	_node_positions.clear()
	_nodes_in_player_range.clear()
	graph = null
	generation_config = null
	current_node_id = INVALID_NODE_ID
	selected_node_id = INVALID_NODE_ID
	visited_counts = PackedInt32Array()
	group_marker.hide()
	connections.setup({}, PackedInt32Array(), INVALID_NODE_ID, PackedInt32Array())


func _on_cell_pressed(node_id: int) -> void:
	if not can_interact_with_node(node_id):
		return
	node_pressed.emit(node_id)


func _refresh_player_range_interactions() -> void:
	var next_nodes_in_range: Dictionary[int, bool] = {}
	if graph != null and _has_local_player_position:
		for neighbor_id in graph.get_neighbors(current_node_id):
			var target_id := int(neighbor_id)
			if (
				_node_positions.has(target_id)
				and _local_player_position.distance_to(
					_node_positions[target_id]
				) <= NODE_INTERACTION_RADIUS
			):
				next_nodes_in_range[target_id] = true
	if next_nodes_in_range == _nodes_in_player_range:
		return
	var affected_ids: Dictionary[int, bool] = {}
	for node_id in _nodes_in_player_range:
		affected_ids[node_id] = true
	for node_id in next_nodes_in_range:
		affected_ids[node_id] = true
	_nodes_in_player_range = next_nodes_in_range
	for node_id in affected_ids:
		_refresh_cell_click_state(node_id)


func _refresh_neighbor_click_states() -> void:
	if graph == null:
		return
	for neighbor_id in graph.get_neighbors(current_node_id):
		_refresh_cell_click_state(int(neighbor_id))


func _refresh_cell_click_state(node_id: int) -> void:
	var cell := _cells.get(node_id) as RogueRouteCell
	if cell == null:
		return
	cell.set_click_enabled(can_interact_with_node(node_id))


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
