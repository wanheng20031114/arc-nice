extends RefCounted
class_name RogueRouteGraph

## 肉鸽路线图的纯数据快照。
##
## 图使用 row-major 节点 id，并把无向边规范化为 [较小 id, 较大 id]。
## adjacency 只由 edges 派生，不参与网络传输或布局哈希。

enum NodeType {
	EMPTY = 0,
	MAGICAL_ENCOUNTER = 1,
	EMERGENCY_COMBAT = 2,
	NORMAL_COMBAT = 3,
	WILDERNESS_RESOURCE = 4,
	UNDERGROUND_SHOP = 5,
	PREPARE_AHEAD = 6,
}

const SCHEMA_VERSION := 1
const NODE_TYPE_COUNT := 7

var generation_seed: int = 0
var width: int = 0
var height: int = 0
var start_node_id: int = -1
var node_types := PackedByteArray()
var node_content_seeds := PackedInt64Array()
var visual_offsets := PackedVector2Array()
var edges := PackedInt32Array()
var adjacency: Array[PackedInt32Array] = []


func initialize_layout(
	new_generation_seed: int,
	new_width: int,
	new_height: int,
	new_start_node_id: int,
	new_node_types: PackedByteArray,
	new_node_content_seeds: PackedInt64Array,
	new_visual_offsets: PackedVector2Array,
	new_edges: PackedInt32Array
) -> PackedStringArray:
	generation_seed = new_generation_seed
	width = new_width
	height = new_height
	start_node_id = new_start_node_id
	node_types = new_node_types.duplicate()
	node_content_seeds = new_node_content_seeds.duplicate()
	visual_offsets = new_visual_offsets.duplicate()
	edges = new_edges.duplicate()

	var errors := validate_layout()
	if errors.is_empty():
		_rebuild_adjacency()
	else:
		adjacency.clear()
	return errors


func get_node_count() -> int:
	return width * height


func get_edge_count() -> int:
	return edges.size() / 2


func get_max_cardinal_edge_count() -> int:
	if width <= 0 or height <= 0:
		return 0
	return (width - 1) * height + width * (height - 1)


func is_valid_node_id(node_id: int) -> bool:
	return node_id >= 0 and node_id < get_node_count()


func coord_to_id(coord: Vector2i) -> int:
	if coord.x < 0 or coord.x >= width or coord.y < 0 or coord.y >= height:
		return -1
	return coord.y * width + coord.x


func id_to_coord(node_id: int) -> Vector2i:
	if not is_valid_node_id(node_id):
		return Vector2i(-1, -1)
	return Vector2i(node_id % width, node_id / width)


func get_start_coord() -> Vector2i:
	return id_to_coord(start_node_id)


func get_node_type(node_id: int) -> int:
	if not is_valid_node_id(node_id) or node_id >= node_types.size():
		return NodeType.EMPTY
	return int(node_types[node_id])


func get_node_content_seed(node_id: int) -> int:
	if not is_valid_node_id(node_id) or node_id >= node_content_seeds.size():
		return 0
	return int(node_content_seeds[node_id])


func get_visual_offset(node_id: int) -> Vector2:
	if not is_valid_node_id(node_id) or node_id >= visual_offsets.size():
		return Vector2.ZERO
	return visual_offsets[node_id]


func get_neighbors(node_id: int) -> PackedInt32Array:
	if node_id < 0 or node_id >= adjacency.size():
		return PackedInt32Array()
	return adjacency[node_id].duplicate()


func has_edge(first_node_id: int, second_node_id: int) -> bool:
	if not is_valid_node_id(first_node_id) or not is_valid_node_id(second_node_id):
		return false
	if first_node_id >= adjacency.size():
		return false
	return adjacency[first_node_id].has(second_node_id)


func get_node_ids_by_type(node_type: int) -> PackedInt32Array:
	var result := PackedInt32Array()
	for node_id in range(node_types.size()):
		if int(node_types[node_id]) == node_type:
			result.append(node_id)
	return result


func validate_layout() -> PackedStringArray:
	var errors := PackedStringArray()
	if width < 3 or height < 3 or width > 31 or height > 31:
		errors.append("路线图宽高必须位于 3 到 31。")
		return errors
	if width % 2 == 0 or height % 2 == 0:
		errors.append("路线图宽高必须为奇数。")

	var node_count := get_node_count()
	if node_types.size() != node_count:
		errors.append(
			"node_types 长度必须等于 width * height：%d != %d。"
			% [node_types.size(), node_count]
		)
	if node_content_seeds.size() != node_count:
		errors.append(
			"node_content_seeds 长度必须等于节点数：%d != %d。"
			% [node_content_seeds.size(), node_count]
		)
	if visual_offsets.size() != node_count:
		errors.append(
			"visual_offsets 长度必须等于节点数：%d != %d。"
			% [visual_offsets.size(), node_count]
		)
	if start_node_id < 0 or start_node_id >= node_count:
		errors.append("start_node_id 超出路线图范围。")
	elif start_node_id != (height / 2) * width + width / 2:
		errors.append("start_node_id 必须精确位于路线图正中心。")
	elif (
		start_node_id < node_types.size()
		and int(node_types[start_node_id]) != NodeType.EMPTY
	):
		errors.append("起点必须是 EMPTY 节点。")

	for node_id in range(node_types.size()):
		var node_type := int(node_types[node_id])
		if node_type < NodeType.EMPTY or node_type >= NODE_TYPE_COUNT:
			errors.append("节点 %d 包含未知类型 %d。" % [node_id, node_type])
	for node_id in range(visual_offsets.size()):
		var offset := visual_offsets[node_id]
		if (
			not is_finite(offset.x)
			or not is_finite(offset.y)
			or not is_equal_approx(offset.x, float(roundi(offset.x)))
			or not is_equal_approx(offset.y, float(roundi(offset.y)))
		):
			errors.append("节点 %d 的视觉偏移必须是有限整数像素。" % node_id)

	if edges.size() % 2 != 0:
		errors.append("edges 必须由成对节点 id 组成。")
		return errors
	var seen_edges: Dictionary = {}
	var edges_are_structurally_valid := true
	var previous_edge := Vector2i(-1, -1)
	var has_previous_edge := false
	for edge_offset in range(0, edges.size(), 2):
		var first_node_id := int(edges[edge_offset])
		var second_node_id := int(edges[edge_offset + 1])
		if (
			first_node_id < 0
			or first_node_id >= node_count
			or second_node_id < 0
			or second_node_id >= node_count
		):
			edges_are_structurally_valid = false
			errors.append(
				"边 %d 的端点超出路线图范围。" % (edge_offset / 2)
			)
			continue
		if first_node_id >= second_node_id:
			edges_are_structurally_valid = false
			errors.append(
				"无向边必须按较小 id、较大 id 规范化：%d,%d。"
				% [first_node_id, second_node_id]
			)
			continue
		var first_coord := id_to_coord(first_node_id)
		var second_coord := id_to_coord(second_node_id)
		var manhattan_distance := (
			absi(first_coord.x - second_coord.x)
			+ absi(first_coord.y - second_coord.y)
		)
		if manhattan_distance != 1:
			edges_are_structurally_valid = false
			errors.append(
				"边 %d,%d 必须连接上下左右相邻格。"
				% [first_node_id, second_node_id]
			)
		var edge_key := "%d:%d" % [first_node_id, second_node_id]
		if seen_edges.has(edge_key):
			edges_are_structurally_valid = false
			errors.append("路线图包含重复边 %s。" % edge_key)
		else:
			seen_edges[edge_key] = true
		var current_edge := Vector2i(first_node_id, second_node_id)
		if (
			has_previous_edge
			and not (
				previous_edge.x < current_edge.x
				or (
					previous_edge.x == current_edge.x
					and previous_edge.y < current_edge.y
				)
			)
		):
			edges_are_structurally_valid = false
			errors.append("edges 必须按两个端点稳定升序排列。")
		previous_edge = current_edge
		has_previous_edge = true
	if edges_are_structurally_valid and not _are_all_nodes_connected(node_count):
		errors.append("路线图必须从中心连通全部格子。")
	return errors


func export_layout() -> Dictionary:
	return {
		"schema_version": SCHEMA_VERSION,
		"generation_seed": generation_seed,
		"width": width,
		"height": height,
		"start_node_id": start_node_id,
		"node_types": node_types.duplicate(),
		"node_content_seeds": node_content_seeds.duplicate(),
		"visual_offsets": visual_offsets.duplicate(),
		"edges": edges.duplicate(),
		"layout_hash": compute_layout_hash(),
	}


static func import_layout(serialized_layout: Dictionary) -> RogueRouteGraph:
	if not _has_valid_import_field_types(serialized_layout):
		return null
	if int(serialized_layout["schema_version"]) != SCHEMA_VERSION:
		return null
	var graph := RogueRouteGraph.new()
	var errors := graph.initialize_layout(
		int(serialized_layout["generation_seed"]),
		int(serialized_layout["width"]),
		int(serialized_layout["height"]),
		int(serialized_layout["start_node_id"]),
		_to_packed_byte_array(serialized_layout["node_types"]),
		_to_packed_int64_array(serialized_layout["node_content_seeds"]),
		_to_packed_vector2_array(serialized_layout["visual_offsets"]),
		_to_packed_int32_array(serialized_layout["edges"])
	)
	if not errors.is_empty():
		return null
	var expected_hash := str(serialized_layout["layout_hash"])
	if expected_hash.is_empty() or graph.compute_layout_hash() != expected_hash:
		return null
	return graph


func compute_topology_hash() -> String:
	var parts := PackedStringArray([
		"schema=%d" % SCHEMA_VERSION,
		"seed=%d" % generation_seed,
		"size=%d,%d" % [width, height],
		"start=%d" % start_node_id,
	])
	for edge_value in edges:
		parts.append("e=%d" % int(edge_value))
	return "\n".join(parts).sha256_text()


func compute_content_hash() -> String:
	var parts := PackedStringArray([
		"schema=%d" % SCHEMA_VERSION,
		"seed=%d" % generation_seed,
		"size=%d,%d" % [width, height],
		"start=%d" % start_node_id,
	])
	for node_type in node_types:
		parts.append("t=%d" % int(node_type))
	for content_seed in node_content_seeds:
		parts.append("c=%d" % int(content_seed))
	return "\n".join(parts).sha256_text()


func compute_structure_hash() -> String:
	return (
		"%s\n%s" % [compute_topology_hash(), compute_content_hash()]
	).sha256_text()


func compute_layout_hash() -> String:
	var parts := PackedStringArray([
		compute_structure_hash(),
		"visual_count=%d" % visual_offsets.size(),
	])
	for offset in visual_offsets:
		parts.append("v=%d,%d" % [roundi(offset.x), roundi(offset.y)])
	return "\n".join(parts).sha256_text()


func _rebuild_adjacency() -> void:
	adjacency.clear()
	adjacency.resize(get_node_count())
	for node_id in range(adjacency.size()):
		adjacency[node_id] = PackedInt32Array()
	for edge_offset in range(0, edges.size(), 2):
		var first_node_id := int(edges[edge_offset])
		var second_node_id := int(edges[edge_offset + 1])
		var first_neighbors := adjacency[first_node_id]
		first_neighbors.append(second_node_id)
		adjacency[first_node_id] = first_neighbors
		var second_neighbors := adjacency[second_node_id]
		second_neighbors.append(first_node_id)
		adjacency[second_node_id] = second_neighbors
	for node_id in range(adjacency.size()):
		var neighbors := adjacency[node_id]
		neighbors.sort()
		adjacency[node_id] = neighbors


func _are_all_nodes_connected(node_count: int) -> bool:
	if node_count <= 0 or not is_valid_node_id(start_node_id):
		return false
	var local_adjacency: Array[PackedInt32Array] = []
	local_adjacency.resize(node_count)
	for node_id in range(node_count):
		local_adjacency[node_id] = PackedInt32Array()
	for edge_offset in range(0, edges.size(), 2):
		var first_node_id := int(edges[edge_offset])
		var second_node_id := int(edges[edge_offset + 1])
		var first_neighbors := local_adjacency[first_node_id]
		first_neighbors.append(second_node_id)
		local_adjacency[first_node_id] = first_neighbors
		var second_neighbors := local_adjacency[second_node_id]
		second_neighbors.append(first_node_id)
		local_adjacency[second_node_id] = second_neighbors
	var visited := PackedByteArray()
	visited.resize(node_count)
	var pending := PackedInt32Array([start_node_id])
	visited[start_node_id] = 1
	var cursor := 0
	while cursor < pending.size():
		var node_id := int(pending[cursor])
		cursor += 1
		for neighbor_id in local_adjacency[node_id]:
			if visited[neighbor_id] != 0:
				continue
			visited[neighbor_id] = 1
			pending.append(neighbor_id)
	return cursor == node_count


static func _has_valid_import_field_types(serialized_layout: Dictionary) -> bool:
	for field_name in [
		"schema_version",
		"generation_seed",
		"width",
		"height",
		"start_node_id",
	]:
		if typeof(serialized_layout.get(field_name)) != TYPE_INT:
			return false
	if typeof(serialized_layout.get("layout_hash")) != TYPE_STRING:
		return false
	return (
		serialized_layout.has("node_types")
		and serialized_layout.has("node_content_seeds")
		and serialized_layout.has("visual_offsets")
		and serialized_layout.has("edges")
	)


static func _to_packed_byte_array(value: Variant) -> PackedByteArray:
	if value is PackedByteArray:
		return (value as PackedByteArray).duplicate()
	var result := PackedByteArray()
	if value is Array:
		for entry in value:
			if typeof(entry) != TYPE_INT or int(entry) < 0 or int(entry) > 255:
				return PackedByteArray()
			result.append(int(entry))
	return result


static func _to_packed_int32_array(value: Variant) -> PackedInt32Array:
	if value is PackedInt32Array:
		return (value as PackedInt32Array).duplicate()
	var result := PackedInt32Array()
	if value is Array:
		for entry in value:
			if (
				typeof(entry) != TYPE_INT
				or int(entry) < -2147483648
				or int(entry) > 2147483647
			):
				return PackedInt32Array()
			result.append(int(entry))
	return result


static func _to_packed_int64_array(value: Variant) -> PackedInt64Array:
	if value is PackedInt64Array:
		return (value as PackedInt64Array).duplicate()
	var result := PackedInt64Array()
	if value is Array:
		for entry in value:
			if typeof(entry) != TYPE_INT:
				return PackedInt64Array()
			result.append(int(entry))
	return result


static func _to_packed_vector2_array(value: Variant) -> PackedVector2Array:
	if value is PackedVector2Array:
		return (value as PackedVector2Array).duplicate()
	var result := PackedVector2Array()
	if value is Array:
		for entry in value:
			if not (entry is Vector2 or entry is Vector2i):
				return PackedVector2Array()
			result.append(Vector2(entry))
	return result
