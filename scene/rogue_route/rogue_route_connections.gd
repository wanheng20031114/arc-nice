extends Node2D
class_name RogueRouteConnections

const INVALID_NODE_ID := -1

@export var base_line_color := Color(0.31, 0.39, 0.43, 0.44)
@export var reachable_line_color := Color(0.35, 0.76, 0.82, 0.76)
@export_range(0.5, 6.0, 0.25) var base_line_width := 1.0
@export_range(0.5, 8.0, 0.25) var reachable_line_width := 1.5

var _node_positions: Dictionary[int, Vector2] = {}
var _edges := PackedInt32Array()
var _edge_lookup: Dictionary[Vector2i, bool] = {}
var _current_node_id := INVALID_NODE_ID
var _reachable_node_ids := PackedInt32Array()
var _base_line_count := 0
var _highlighted_line_count := 0


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
		_rebuild_edge_lookup()
	_current_node_id = current_node_id
	_reachable_node_ids = normalized_reachable
	if highlight_changed:
		_recount_highlighted_lines()
	if layout_changed or highlight_changed:
		queue_redraw()


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
	return _base_line_count


func get_highlighted_line_count() -> int:
	return _highlighted_line_count


func _draw() -> void:
	for edge_offset in range(0, _edges.size(), 2):
		var from_id := int(_edges[edge_offset])
		var to_id := int(_edges[edge_offset + 1])
		if not _node_positions.has(from_id) or not _node_positions.has(to_id):
			continue
		draw_line(
			_node_positions[from_id],
			_node_positions[to_id],
			base_line_color,
			base_line_width,
			true
		)
	if not _node_positions.has(_current_node_id):
		return
	var current_position := _node_positions[_current_node_id]
	for reachable_node_id in _reachable_node_ids:
		if (
			not _node_positions.has(reachable_node_id)
			or not _edge_lookup.has(_edge_key(
				_current_node_id,
				int(reachable_node_id)
			))
		):
			continue
		draw_line(
			current_position,
			_node_positions[reachable_node_id],
			reachable_line_color,
			reachable_line_width,
			true
		)


func _rebuild_edge_lookup() -> void:
	_edge_lookup.clear()
	_base_line_count = 0
	for edge_offset in range(0, _edges.size(), 2):
		var from_id := int(_edges[edge_offset])
		var to_id := int(_edges[edge_offset + 1])
		if not _node_positions.has(from_id) or not _node_positions.has(to_id):
			continue
		_edge_lookup[_edge_key(from_id, to_id)] = true
		_base_line_count += 1


func _recount_highlighted_lines() -> void:
	_highlighted_line_count = 0
	if not _node_positions.has(_current_node_id):
		return
	for reachable_node_id in _reachable_node_ids:
		if (
			_node_positions.has(reachable_node_id)
			and _edge_lookup.has(_edge_key(
				_current_node_id,
				int(reachable_node_id)
			))
		):
			_highlighted_line_count += 1


func _edge_key(first_id: int, second_id: int) -> Vector2i:
	return Vector2i(mini(first_id, second_id), maxi(first_id, second_id))


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
