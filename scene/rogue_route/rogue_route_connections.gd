extends Node2D
class_name RogueRouteConnections

const INVALID_NODE_ID := -1

@export var route_texture: Texture2D
@export var base_line_color := Color(0.52, 0.62, 0.62, 0.78)
@export var reachable_line_color := Color(0.62, 1.0, 1.0, 1.0)
@export_range(4.0, 20.0, 1.0) var base_line_width := 10.0
@export_range(4.0, 24.0, 1.0) var reachable_line_width := 12.0

@onready var base_edges: Node2D = $BaseEdges
@onready var highlighted_edges: Node2D = $HighlightedEdges

var _node_positions: Dictionary[int, Vector2] = {}
var _edges := PackedInt32Array()
var _current_node_id := INVALID_NODE_ID
var _reachable_node_ids := PackedInt32Array()


func setup(
	node_positions: Dictionary[int, Vector2],
	edges: PackedInt32Array,
	current_node_id: int,
	reachable_node_ids: PackedInt32Array
) -> void:
	if not _has_valid_edge_pairs(edges):
		return
	var normalized_reachable := _normalize_node_ids(reachable_node_ids)
	var layout_changed := _node_positions != node_positions or _edges != edges
	var highlight_changed := (
		layout_changed
		or _current_node_id != current_node_id
		or _reachable_node_ids != normalized_reachable
	)
	if layout_changed:
		_node_positions = _copy_positions(node_positions)
		_edges = edges.duplicate()
		_rebuild_base_edges()
	_current_node_id = current_node_id
	_reachable_node_ids = normalized_reachable
	if highlight_changed:
		_rebuild_highlighted_edges()


func set_node_positions(node_positions: Dictionary[int, Vector2]) -> void:
	setup(node_positions, _edges, _current_node_id, _reachable_node_ids)


func set_edges(edges: PackedInt32Array) -> void:
	setup(_node_positions, edges, _current_node_id, _reachable_node_ids)


func set_current_node(node_id: int) -> void:
	setup(_node_positions, _edges, node_id, _reachable_node_ids)


func clear_current_node() -> void:
	set_current_node(INVALID_NODE_ID)


func set_reachable_nodes(node_ids: PackedInt32Array) -> void:
	setup(_node_positions, _edges, _current_node_id, node_ids)


func get_base_line_count() -> int:
	return base_edges.get_child_count()


func get_highlighted_line_count() -> int:
	return highlighted_edges.get_child_count()


func _rebuild_base_edges() -> void:
	_clear_line_layer(base_edges)
	for edge_offset in range(0, _edges.size(), 2):
		var from_id := _edges[edge_offset]
		var to_id := _edges[edge_offset + 1]
		if not _node_positions.has(from_id) or not _node_positions.has(to_id):
			continue
		base_edges.add_child(_create_textured_line(
			_node_positions[from_id],
			_node_positions[to_id],
			base_line_width,
			base_line_color
		))


func _rebuild_highlighted_edges() -> void:
	_clear_line_layer(highlighted_edges)
	if not _node_positions.has(_current_node_id):
		return
	var current_position := _node_positions[_current_node_id]
	for reachable_node_id in _reachable_node_ids:
		if (
			not _node_positions.has(reachable_node_id)
			or not _edge_exists(_current_node_id, reachable_node_id)
		):
			continue
		highlighted_edges.add_child(_create_textured_line(
			current_position,
			_node_positions[reachable_node_id],
			reachable_line_width,
			reachable_line_color
		))


func _create_textured_line(
	from_position: Vector2,
	to_position: Vector2,
	line_width: float,
	line_color: Color
) -> Line2D:
	var line := Line2D.new()
	line.name = "RouteLink"
	line.width = line_width
	line.default_color = line_color
	line.antialiased = false
	line.joint_mode = Line2D.LINE_JOINT_SHARP
	line.begin_cap_mode = Line2D.LINE_CAP_BOX
	line.end_cap_mode = Line2D.LINE_CAP_BOX
	line.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	line.texture_repeat = CanvasItem.TEXTURE_REPEAT_ENABLED
	if route_texture != null:
		line.texture = route_texture
		line.texture_mode = Line2D.LINE_TEXTURE_TILE
	line.add_point(from_position.round())
	line.add_point(to_position.round())
	return line


func _clear_line_layer(layer: Node2D) -> void:
	for child in layer.get_children():
		layer.remove_child(child)
		child.queue_free()


func _edge_exists(from_id: int, to_id: int) -> bool:
	for edge_offset in range(0, _edges.size(), 2):
		var edge_from := _edges[edge_offset]
		var edge_to := _edges[edge_offset + 1]
		if (
			edge_from == from_id and edge_to == to_id
		) or (
			edge_from == to_id and edge_to == from_id
		):
			return true
	return false


func _has_valid_edge_pairs(edges: PackedInt32Array) -> bool:
	if edges.size() % 2 == 0:
		return true
	push_error(
		"RogueRouteConnections: edges 必须是 [from_id, to_id, ...] 的偶数长度数组"
	)
	return false


func _copy_positions(
	source: Dictionary[int, Vector2]
) -> Dictionary[int, Vector2]:
	var copy: Dictionary[int, Vector2] = {}
	for node_id in source:
		copy[node_id] = source[node_id]
	return copy


func _normalize_node_ids(node_ids: PackedInt32Array) -> PackedInt32Array:
	var normalized := node_ids.duplicate()
	normalized.sort()
	var unique := PackedInt32Array()
	var previous := INVALID_NODE_ID
	var has_previous := false
	for node_id in normalized:
		if has_previous and node_id == previous:
			continue
		unique.append(node_id)
		previous = node_id
		has_previous = true
	return unique
