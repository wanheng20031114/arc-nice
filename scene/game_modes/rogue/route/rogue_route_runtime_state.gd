extends RefCounted
class_name RogueRouteRuntimeState

## 路线图的房主权威运行态。
##
## 布局由 RogueRouteGraph 持有且在一局内不可变；这里只保存共享小队位置、
## 行动力与访问次数。移动只检查当前节点的邻接表，因此确认路径为 O(1)。

signal state_changed(snapshot: Dictionary)
signal move_committed(delta: Dictionary)

const SCHEMA_VERSION := 2
const INVALID_NODE_ID := -1
const MAX_ACTION_POINTS := 0x7FFFFFFF

var graph: RogueRouteGraph = null
var layout_hash := ""
var state_revision := 0
## 行动力奖励与移动使用不同 revision。移动 revision 仍严格对应访问次数；
## 奖励只推进该 revision，避免把“访问一次”与“获得行动力”混为一谈。
var action_points_revision := 0
var current_node_id := INVALID_NODE_ID
var action_points := 0
var visited_counts := PackedInt32Array()


func initialize(
	new_graph: RogueRouteGraph,
	initial_action_points: int
) -> bool:
	if new_graph == null or not new_graph.validate_layout().is_empty():
		return false
	if initial_action_points < 0 or initial_action_points > MAX_ACTION_POINTS:
		return false
	graph = new_graph
	layout_hash = graph.compute_layout_hash()
	state_revision = 0
	action_points_revision = 0
	current_node_id = graph.start_node_id
	action_points = initial_action_points
	visited_counts.resize(graph.get_node_count())
	visited_counts.fill(0)
	visited_counts[current_node_id] = 1
	return true


func is_initialized() -> bool:
	return (
		graph != null
		and not layout_hash.is_empty()
		and graph.is_valid_node_id(current_node_id)
		and state_revision >= 0
		and action_points_revision >= 0
		and action_points >= 0
		and visited_counts.size() == graph.get_node_count()
		and visited_counts[current_node_id] > 0
	)


func can_move_to(
	target_node_id: int,
	move_cost: int,
	expected_revision: int = -1
) -> bool:
	return get_move_rejection_reason(
		target_node_id,
		move_cost,
		expected_revision
	).is_empty()


func get_move_rejection_reason(
	target_node_id: int,
	move_cost: int,
	expected_revision: int = -1
) -> String:
	if not is_initialized():
		return "路线状态尚未初始化"
	if expected_revision >= 0 and expected_revision != state_revision:
		return "路线状态已变化，请重新选择"
	if move_cost <= 0:
		return "移动消耗配置无效"
	if not graph.is_valid_node_id(target_node_id):
		return "目标格不存在"
	if target_node_id == current_node_id:
		return "小队已经位于该格"
	if not graph.has_edge(current_node_id, target_node_id):
		return "该格与当前位置没有路线连接"
	if action_points < move_cost:
		return "行动力不足"
	return ""


func try_move(
	target_node_id: int,
	move_cost: int,
	expected_revision: int
) -> bool:
	if not can_move_to(target_node_id, move_cost, expected_revision):
		return false
	var from_node_id := current_node_id
	current_node_id = target_node_id
	action_points -= move_cost
	visited_counts[target_node_id] += 1
	state_revision += 1
	var delta := {
		"schema_version": SCHEMA_VERSION,
		"layout_hash": layout_hash,
		"revision": state_revision,
		"action_points_revision": action_points_revision,
		"from_node_id": from_node_id,
		"to_node_id": target_node_id,
		"move_cost": move_cost,
		"action_points": action_points,
		"target_visit_count": visited_counts[target_node_id],
	}
	move_committed.emit(delta.duplicate(true))
	state_changed.emit(export_state())
	return true


## 仅由 Host 的权威内容结算调用。行动力奖励通过 full route snapshot 同步；
## 它不会伪装成移动 delta，也不会改变位置或访问次数。
func grant_action_points(amount: int) -> bool:
	if (
		not is_initialized()
		or amount <= 0
		or action_points > MAX_ACTION_POINTS - amount
	):
		return false
	action_points += amount
	action_points_revision += 1
	state_changed.emit(export_state())
	return true


func export_state() -> Dictionary:
	return {
		"schema_version": SCHEMA_VERSION,
		"layout_hash": layout_hash,
		"revision": state_revision,
		"action_points_revision": action_points_revision,
		"current_node_id": current_node_id,
		"action_points": action_points,
		"visited_counts": visited_counts.duplicate(),
	}


func apply_remote_state(snapshot: Dictionary) -> bool:
	if not is_initialized() or not _validate_common_snapshot(snapshot):
		return false
	if not _has_integer_fields(
		snapshot,
		[
			"revision",
			"action_points_revision",
			"current_node_id",
			"action_points",
		]
	):
		return false
	if not snapshot.has("visited_counts"):
		return false
	var incoming_revision := int(snapshot["revision"])
	var incoming_action_points_revision := int(
		snapshot["action_points_revision"]
	)
	if (
		incoming_revision < state_revision
		or incoming_action_points_revision < action_points_revision
	):
		return false
	var incoming_node_id := int(snapshot["current_node_id"])
	var incoming_action_points := int(snapshot["action_points"])
	var incoming_visited := _to_packed_int32_array(
		snapshot["visited_counts"]
	)
	if (
		not graph.is_valid_node_id(incoming_node_id)
		or incoming_action_points < 0
		or incoming_action_points > MAX_ACTION_POINTS
		or incoming_action_points_revision < 0
		or incoming_visited.size() != graph.get_node_count()
		or not _has_consistent_visit_counts(
			incoming_visited,
			incoming_node_id,
			incoming_revision
		)
	):
		return false
	if (
		incoming_revision == state_revision
		and incoming_action_points_revision == action_points_revision
	):
		return (
			incoming_node_id == current_node_id
			and incoming_action_points == action_points
			and incoming_visited == visited_counts
		)
	# 未收到新的奖励 revision 时，行动力只能被移动消耗。奖励 revision 前进
	# 后则接受 Host 全量绝对值；这也覆盖以当前行动力初始化的中途加入水合。
	if (
		incoming_action_points_revision == action_points_revision
		and incoming_action_points > action_points
	):
		return false
	for node_id in range(incoming_visited.size()):
		if incoming_visited[node_id] < visited_counts[node_id]:
			return false
	state_revision = incoming_revision
	action_points_revision = incoming_action_points_revision
	current_node_id = incoming_node_id
	action_points = incoming_action_points
	visited_counts = incoming_visited
	state_changed.emit(export_state())
	return true


func apply_remote_move_delta(delta: Dictionary) -> bool:
	if not is_initialized() or not _validate_common_snapshot(delta):
		return false
	if not _has_integer_fields(
		delta,
		[
			"revision",
			"action_points_revision",
			"from_node_id",
			"to_node_id",
			"move_cost",
			"action_points",
			"target_visit_count",
		]
	):
		return false
	var incoming_revision := int(delta["revision"])
	var incoming_action_points_revision := int(delta["action_points_revision"])
	var from_node_id := int(delta["from_node_id"])
	var to_node_id := int(delta["to_node_id"])
	var move_cost := int(delta["move_cost"])
	var remaining_action_points := int(delta["action_points"])
	var target_visit_count := int(delta["target_visit_count"])
	if (
		incoming_revision != state_revision + 1
		or incoming_action_points_revision != action_points_revision
		or from_node_id != current_node_id
		or move_cost <= 0
		or remaining_action_points != action_points - move_cost
		or remaining_action_points < 0
		or not graph.has_edge(from_node_id, to_node_id)
		or target_visit_count != visited_counts[to_node_id] + 1
	):
		return false
	state_revision = incoming_revision
	current_node_id = to_node_id
	action_points = remaining_action_points
	visited_counts[to_node_id] = target_visit_count
	state_changed.emit(export_state())
	return true


func _validate_common_snapshot(snapshot: Dictionary) -> bool:
	return (
		typeof(snapshot.get("schema_version")) == TYPE_INT
		and int(snapshot["schema_version"]) == SCHEMA_VERSION
		and typeof(snapshot.get("layout_hash")) == TYPE_STRING
		and str(snapshot["layout_hash"]) == layout_hash
	)


func _has_consistent_visit_counts(
	counts: PackedInt32Array,
	node_id: int,
	revision: int
) -> bool:
	if revision < 0 or not graph.is_valid_node_id(node_id):
		return false
	var total_visits := 0
	for visit_count in counts:
		if visit_count < 0:
			return false
		total_visits += visit_count
	return counts[node_id] > 0 and total_visits == revision + 1


static func _has_integer_fields(snapshot: Dictionary, field_names: Array) -> bool:
	for field_name in field_names:
		if typeof(snapshot.get(field_name)) != TYPE_INT:
			return false
	return true


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
