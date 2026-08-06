extends Node2D
class_name RogueRouteConnections

const INVALID_NODE_ID := -1
const EDGE_FIRST_START_PROGRESS := 0.04
const EDGE_LAST_START_PROGRESS := 0.78
const EDGE_REVEAL_SPAN := 0.18

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
var _entry_reveal_progress := 1.0
var _entry_reveal_prepared := false
var _entry_reveal_depths: Dictionary[int, int] = {}
var _entry_reveal_max_depth := 0


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


func prepare_entry_reveal(
	node_depths: Dictionary[int, int],
	maximum_depth: int
) -> void:
	_entry_reveal_depths = node_depths.duplicate()
	_entry_reveal_max_depth = maxi(maximum_depth, 0)
	_entry_reveal_prepared = true
	set_entry_reveal_progress(0.0)


func set_entry_reveal_progress(progress: float) -> void:
	var clamped_progress := clampf(progress, 0.0, 1.0)
	if is_equal_approx(_entry_reveal_progress, clamped_progress):
		return
	_entry_reveal_progress = clamped_progress
	queue_redraw()


func complete_entry_reveal() -> void:
	var needs_redraw := (
		_entry_reveal_prepared
		or not is_equal_approx(_entry_reveal_progress, 1.0)
	)
	_entry_reveal_prepared = false
	_entry_reveal_progress = 1.0
	_entry_reveal_depths.clear()
	_entry_reveal_max_depth = 0
	if needs_redraw:
		queue_redraw()


func get_entry_reveal_progress() -> float:
	return _entry_reveal_progress


func get_wave_start_progress(wave_depth: int) -> float:
	return _get_wave_start_progress(wave_depth)


func _draw() -> void:
	for edge_offset in range(0, _edges.size(), 2):
		var from_id := int(_edges[edge_offset])
		var to_id := int(_edges[edge_offset + 1])
		if not _node_positions.has(from_id) or not _node_positions.has(to_id):
			continue
		var oriented_edge := _get_oriented_edge(from_id, to_id)
		var reveal_fraction := _get_edge_reveal_fraction(from_id, to_id)
		_draw_revealed_line(
			_node_positions[oriented_edge.x],
			_node_positions[oriented_edge.y],
			base_line_color,
			base_line_width,
			reveal_fraction
		)
	if not _node_positions.has(_current_node_id):
		return
	for reachable_node_id in _reachable_node_ids:
		if (
			not _node_positions.has(reachable_node_id)
			or not _edge_lookup.has(_edge_key(
				_current_node_id,
				int(reachable_node_id)
			))
		):
			continue
		var oriented_edge := _get_oriented_edge(
			_current_node_id,
			int(reachable_node_id)
		)
		var reveal_fraction := _get_edge_reveal_fraction(
			_current_node_id,
			int(reachable_node_id)
		)
		_draw_revealed_line(
			_node_positions[oriented_edge.x],
			_node_positions[oriented_edge.y],
			reachable_line_color,
			reachable_line_width,
			reveal_fraction
		)


func _draw_revealed_line(
	from_position: Vector2,
	to_position: Vector2,
	color: Color,
	width: float,
	reveal_fraction: float
) -> void:
	if reveal_fraction <= 0.0:
		return
	draw_line(
		from_position,
		from_position.lerp(to_position, clampf(reveal_fraction, 0.0, 1.0)),
		color,
		width,
		true
	)


func _get_oriented_edge(first_id: int, second_id: int) -> Vector2i:
	if not _entry_reveal_prepared:
		return Vector2i(first_id, second_id)
	var first_depth := int(_entry_reveal_depths.get(first_id, 0))
	var second_depth := int(_entry_reveal_depths.get(second_id, 0))
	if first_depth > second_depth:
		return Vector2i(second_id, first_id)
	if first_depth == second_depth and first_id > second_id:
		return Vector2i(second_id, first_id)
	return Vector2i(first_id, second_id)


func _get_edge_reveal_fraction(first_id: int, second_id: int) -> float:
	if not _entry_reveal_prepared:
		return 1.0
	var first_depth := int(_entry_reveal_depths.get(first_id, 0))
	var second_depth := int(_entry_reveal_depths.get(second_id, 0))
	var wave_depth: int = maxi(first_depth, second_depth)
	var start_progress := _get_wave_start_progress(wave_depth)
	return smoothstep(
		start_progress,
		start_progress + EDGE_REVEAL_SPAN,
		_entry_reveal_progress
	)


func _get_wave_start_progress(wave_depth: int) -> float:
	if _entry_reveal_max_depth <= 1:
		return EDGE_FIRST_START_PROGRESS
	var normalized_depth := clampf(
		float(maxi(wave_depth - 1, 0))
		/ float(_entry_reveal_max_depth - 1),
		0.0,
		1.0
	)
	return lerpf(
		EDGE_FIRST_START_PROGRESS,
		EDGE_LAST_START_PROGRESS,
		normalized_depth
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
