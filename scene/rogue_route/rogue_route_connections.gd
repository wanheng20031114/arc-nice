extends Control
class_name RogueRouteConnections

const INVALID_NODE_ID := -1

@export var base_shadow_color := Color(0.018, 0.025, 0.03, 0.82)
@export var base_line_color := Color(0.25, 0.34, 0.36, 0.88)
@export var reachable_glow_color := Color(0.2, 0.86, 0.9, 0.2)
@export var reachable_line_color := Color(0.43, 0.94, 0.96, 0.98)
@export_range(1.0, 12.0, 1.0) var base_line_width := 2.0
@export_range(1.0, 12.0, 1.0) var reachable_line_width := 3.0

var _node_positions: Dictionary[int, Vector2] = {}
var _edges := PackedInt32Array()
var _current_node_id := INVALID_NODE_ID
var _reachable_node_ids := PackedInt32Array()
var _reachable_lookup: Dictionary[int, bool] = {}


func setup(
	node_positions: Dictionary[int, Vector2],
	edges: PackedInt32Array,
	current_node_id: int,
	reachable_node_ids: PackedInt32Array
) -> void:
	if not _has_valid_edge_pairs(edges):
		return
	var normalized_reachable := _normalize_node_ids(reachable_node_ids)
	var changed := (
		_node_positions != node_positions
		or _edges != edges
		or _current_node_id != current_node_id
		or _reachable_node_ids != normalized_reachable
	)
	if not changed:
		return
	_node_positions = _copy_positions(node_positions)
	_edges = edges.duplicate()
	_current_node_id = current_node_id
	_reachable_node_ids = normalized_reachable
	_rebuild_reachable_lookup()
	queue_redraw()


func set_node_positions(node_positions: Dictionary[int, Vector2]) -> void:
	if _node_positions == node_positions:
		return
	_node_positions = _copy_positions(node_positions)
	queue_redraw()


func set_edges(edges: PackedInt32Array) -> void:
	if not _has_valid_edge_pairs(edges) or _edges == edges:
		return
	_edges = edges.duplicate()
	queue_redraw()


func set_current_node(node_id: int) -> void:
	if _current_node_id == node_id:
		return
	_current_node_id = node_id
	queue_redraw()


func clear_current_node() -> void:
	set_current_node(INVALID_NODE_ID)


func set_reachable_nodes(node_ids: PackedInt32Array) -> void:
	var normalized_ids := _normalize_node_ids(node_ids)
	if _reachable_node_ids == normalized_ids:
		return
	_reachable_node_ids = normalized_ids
	_rebuild_reachable_lookup()
	queue_redraw()


func _draw() -> void:
	for edge_offset in range(0, _edges.size(), 2):
		var from_id := _edges[edge_offset]
		var to_id := _edges[edge_offset + 1]
		if not _node_positions.has(from_id) or not _node_positions.has(to_id):
			continue
		var from_position := _node_positions[from_id]
		var to_position := _node_positions[to_id]
		draw_line(
			from_position,
			to_position,
			base_shadow_color,
			base_line_width + 4.0,
			false
		)
		draw_line(
			from_position,
			to_position,
			base_line_color,
			base_line_width,
			false
		)

	for edge_offset in range(0, _edges.size(), 2):
		var from_id := _edges[edge_offset]
		var to_id := _edges[edge_offset + 1]
		if not _is_current_reachable_edge(from_id, to_id):
			continue
		if not _node_positions.has(from_id) or not _node_positions.has(to_id):
			continue
		var from_position := _node_positions[from_id]
		var to_position := _node_positions[to_id]
		draw_line(
			from_position,
			to_position,
			reachable_glow_color,
			reachable_line_width + 5.0,
			false
		)
		draw_line(
			from_position,
			to_position,
			reachable_line_color,
			reachable_line_width,
			false
		)


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


func _rebuild_reachable_lookup() -> void:
	_reachable_lookup.clear()
	for node_id in _reachable_node_ids:
		_reachable_lookup[node_id] = true


func _is_current_reachable_edge(from_id: int, to_id: int) -> bool:
	return (
		from_id == _current_node_id and _reachable_lookup.has(to_id)
	) or (
		to_id == _current_node_id and _reachable_lookup.has(from_id)
	)
