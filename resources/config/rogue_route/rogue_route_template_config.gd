@tool
extends Resource
class_name RogueRouteTemplateConfig

## 路线模板的稳定标识；同时进入拓扑哈希与联机运行契约。
@export var template_id: StringName = &""
## 模板选择权重。默认模板均为 1，因此会被等概率选中。
@export_range(0.0, 1000.0, 0.01, "or_greater") var selection_weight := 1.0
@export_range(1, 31, 1, "or_greater") var width := 1
@export_range(1, 31, 1, "or_greater") var height := 1
## 紧凑节点 ID 对应的整数网格坐标，必须按 row-major 严格升序排列。
@export var node_coords := PackedVector2Array()
## 每两个整数表示一条无向边；端点与整组边均须按紧凑节点 ID 升序排列。
@export var edges := PackedInt32Array()


func get_node_count() -> int:
	return node_coords.size()


func get_node_coord(node_id: int) -> Vector2i:
	if node_id < 0 or node_id >= node_coords.size():
		return Vector2i(-1, -1)
	var coord := node_coords[node_id]
	return Vector2i(roundi(coord.x), roundi(coord.y))


func find_node_id(coord: Vector2i) -> int:
	for node_id in range(node_coords.size()):
		if get_node_coord(node_id) == coord:
			return node_id
	return -1


func get_valid_start_node_ids(
	max_manhattan_distance: int = 2,
	minimum_nearby_node_count: int = 6
) -> PackedInt32Array:
	var candidates := PackedInt32Array()
	if node_coords.is_empty() or max_manhattan_distance < 0:
		return candidates
	var minimum_coord := get_node_coord(0)
	var maximum_coord := minimum_coord
	for node_id in range(1, node_coords.size()):
		var coord := get_node_coord(node_id)
		minimum_coord.x = mini(minimum_coord.x, coord.x)
		minimum_coord.y = mini(minimum_coord.y, coord.y)
		maximum_coord.x = maxi(maximum_coord.x, coord.x)
		maximum_coord.y = maxi(maximum_coord.y, coord.y)
	for node_id in range(node_coords.size()):
		var coord := get_node_coord(node_id)
		if (
			coord.x == minimum_coord.x
			or coord.x == maximum_coord.x
			or coord.y == minimum_coord.y
			or coord.y == maximum_coord.y
		):
			continue
		var nearby_node_count := 0
		for other_node_id in range(node_coords.size()):
			if other_node_id == node_id:
				continue
			var other_coord := get_node_coord(other_node_id)
			if (
				absi(other_coord.x - coord.x) + absi(other_coord.y - coord.y)
				<= max_manhattan_distance
			):
				nearby_node_count += 1
		if nearby_node_count >= minimum_nearby_node_count:
			candidates.append(node_id)
	return candidates


func compute_topology_hash() -> String:
	var parts := PackedStringArray([
		"schema=1",
		"template=%s" % String(template_id),
		"size=%d,%d" % [width, height],
	])
	for node_id in range(node_coords.size()):
		var coord := get_node_coord(node_id)
		parts.append("n=%d:%d,%d" % [node_id, coord.x, coord.y])
	for edge_offset in range(0, edges.size() - 1, 2):
		parts.append(
			"e=%d,%d" % [int(edges[edge_offset]), int(edges[edge_offset + 1])]
		)
	return "\n".join(parts).sha256_text()


func validate() -> PackedStringArray:
	var errors := PackedStringArray()
	if template_id == &"":
		errors.append("路线模板缺少 template_id。")
	if not is_finite(selection_weight) or selection_weight <= 0.0:
		errors.append("路线模板 %s 的 selection_weight 必须大于零。" % String(template_id))
	if width <= 0 or height <= 0:
		errors.append("路线模板 %s 的宽高必须大于零。" % String(template_id))
	if node_coords.is_empty():
		errors.append("路线模板 %s 至少需要一个节点。" % String(template_id))

	var previous_grid_index := -1
	var seen_coords: Dictionary = {}
	for node_id in range(node_coords.size()):
		var raw_coord := node_coords[node_id]
		if (
			not is_finite(raw_coord.x)
			or not is_finite(raw_coord.y)
			or not is_equal_approx(raw_coord.x, roundf(raw_coord.x))
			or not is_equal_approx(raw_coord.y, roundf(raw_coord.y))
		):
			errors.append("路线模板 %s 的节点 %d 必须使用整数坐标。" % [template_id, node_id])
			continue
		var coord := get_node_coord(node_id)
		if coord.x < 0 or coord.x >= width or coord.y < 0 or coord.y >= height:
			errors.append("路线模板 %s 的节点 %d 坐标越界。" % [template_id, node_id])
		var coord_key := "%d,%d" % [coord.x, coord.y]
		if seen_coords.has(coord_key):
			errors.append("路线模板 %s 包含重复节点坐标 %s。" % [template_id, coord_key])
		else:
			seen_coords[coord_key] = true
		var grid_index := coord.y * width + coord.x
		if grid_index <= previous_grid_index:
			errors.append("路线模板 %s 的 node_coords 必须按 row-major 严格升序排列。" % template_id)
		previous_grid_index = grid_index

	if edges.size() % 2 != 0:
		errors.append("路线模板 %s 的 edges 必须由完整端点对组成。" % template_id)
	var previous_edge_key := -1
	var valid_edges: Array[Vector2i] = []
	for edge_offset in range(0, edges.size() - 1, 2):
		var first_node_id := int(edges[edge_offset])
		var second_node_id := int(edges[edge_offset + 1])
		if (
			first_node_id < 0
			or second_node_id < 0
			or first_node_id >= node_coords.size()
			or second_node_id >= node_coords.size()
		):
			errors.append("路线模板 %s 包含越界边端点。" % template_id)
			continue
		if first_node_id >= second_node_id:
			errors.append("路线模板 %s 的无向边端点必须严格升序。" % template_id)
			continue
		var edge_key := first_node_id * node_coords.size() + second_node_id
		if edge_key <= previous_edge_key:
			errors.append("路线模板 %s 的 edges 必须按端点对严格升序排列。" % template_id)
		previous_edge_key = edge_key
		var first_coord := get_node_coord(first_node_id)
		var second_coord := get_node_coord(second_node_id)
		if (
			absi(first_coord.x - second_coord.x)
			+ absi(first_coord.y - second_coord.y)
			!= 1
		):
			errors.append("路线模板 %s 只能连接正交相邻节点。" % template_id)
			continue
		valid_edges.append(Vector2i(first_node_id, second_node_id))

	if not node_coords.is_empty():
		var visited: Dictionary = {0: true}
		var pending: Array[int] = [0]
		while not pending.is_empty():
			var node_id: int = pending.pop_back()
			for edge in valid_edges:
				var neighbor_id := -1
				if edge.x == node_id:
					neighbor_id = edge.y
				elif edge.y == node_id:
					neighbor_id = edge.x
				if neighbor_id >= 0 and not visited.has(neighbor_id):
					visited[neighbor_id] = true
					pending.append(neighbor_id)
		if visited.size() != node_coords.size():
			errors.append("路线模板 %s 的全部节点必须连通。" % template_id)
		if get_valid_start_node_ids().is_empty():
			errors.append("路线模板 %s 不存在满足两格六邻点规则的非边缘出生节点。" % template_id)
	return errors


func validate_config() -> PackedStringArray:
	return validate()
