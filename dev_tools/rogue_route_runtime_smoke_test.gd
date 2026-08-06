extends SceneTree

const DEFAULT_CONFIG: RogueRouteGenerationConfig = preload(
	"res://resources/config/rogue_route/p3_generation_config.tres"
)
const BOARD_SCENE: PackedScene = preload(
	"res://scene/game_modes/rogue/route/rogue_route_board.tscn"
)

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var fixture := _find_empty_neighbor_fixture()
	_expect(not fixture.is_empty(), "运行态测试必须找到中心相邻的空节点。")
	if fixture.is_empty():
		_finish()
		return
	var graph := fixture["graph"] as RogueRouteGraph
	var empty_neighbor_id := int(fixture["empty_neighbor_id"])

	_test_layout_snapshot_boundaries(graph)
	_test_local_movement(graph, empty_neighbor_id)
	_test_remote_state_and_delta_boundaries(graph, empty_neighbor_id)
	await _test_board_contract(graph, empty_neighbor_id)
	_finish()


func _find_empty_neighbor_fixture() -> Dictionary:
	for seed_offset in range(256):
		var graph := RogueRouteGenerator.generate(DEFAULT_CONFIG, 0xA30000 + seed_offset)
		if graph == null:
			continue
		for neighbor_id in graph.get_neighbors(graph.start_node_id):
			if graph.get_node_type(int(neighbor_id)) == RogueRouteGraph.NodeType.EMPTY:
				return {
					"graph": graph,
					"empty_neighbor_id": int(neighbor_id),
				}
	return {}


func _test_layout_snapshot_boundaries(graph: RogueRouteGraph) -> void:
	var exported := graph.export_layout()
	var imported := RogueRouteGraph.import_layout(exported)
	_expect(
		imported != null and imported.compute_layout_hash() == graph.compute_layout_hash(),
		"合法布局快照必须无损导入。"
	)

	var wrong_scalar_type := exported.duplicate(true)
	wrong_scalar_type["width"] = str(graph.width)
	_expect(
		RogueRouteGraph.import_layout(wrong_scalar_type) == null,
		"布局快照不得把字符串宽度宽泛转换为整数。"
	)
	var wrong_array_entry_type := exported.duplicate(true)
	var node_types_as_array := Array(graph.node_types)
	node_types_as_array[0] = str(node_types_as_array[0])
	wrong_array_entry_type["node_types"] = node_types_as_array
	_expect(
		RogueRouteGraph.import_layout(wrong_array_entry_type) == null,
		"布局快照不得宽泛转换数组中的字符串节点类型。"
	)

	var regular_arrays := exported.duplicate(true)
	regular_arrays["node_types"] = Array(graph.node_types)
	regular_arrays["node_content_seeds"] = Array(graph.node_content_seeds)
	regular_arrays["visual_offsets"] = Array(graph.visual_offsets)
	regular_arrays["edges"] = Array(graph.edges)
	_expect(
		RogueRouteGraph.import_layout(regular_arrays) != null,
		"网络解包后的严格普通数组必须仍可导入。"
	)

	var disconnected := RogueRouteGraph.new()
	var disconnected_types := PackedByteArray()
	disconnected_types.resize(9)
	disconnected_types.fill(RogueRouteGraph.NodeType.EMPTY)
	var disconnected_seeds := PackedInt64Array()
	disconnected_seeds.resize(9)
	var disconnected_offsets := PackedVector2Array()
	disconnected_offsets.resize(9)
	var disconnected_errors := disconnected.initialize_layout(
		1,
		3,
		3,
		4,
		disconnected_types,
		disconnected_seeds,
		disconnected_offsets,
		PackedInt32Array([0, 1, 1, 2])
	)
	_expect(
		_has_error_containing(disconnected_errors, "连通"),
		"图契约必须拒绝不能从中心覆盖全部格子的布局。"
	)

	var unsorted_edges := graph.edges.duplicate()
	var first_a := unsorted_edges[0]
	var first_b := unsorted_edges[1]
	unsorted_edges[0] = unsorted_edges[2]
	unsorted_edges[1] = unsorted_edges[3]
	unsorted_edges[2] = first_a
	unsorted_edges[3] = first_b
	var unsorted := RogueRouteGraph.new()
	var unsorted_errors := unsorted.initialize_layout(
		graph.generation_seed,
		graph.width,
		graph.height,
		graph.start_node_id,
		graph.node_types,
		graph.node_content_seeds,
		graph.visual_offsets,
		unsorted_edges
	)
	_expect(
		_has_error_containing(unsorted_errors, "升序"),
		"图契约必须拒绝顺序不规范的边快照。"
	)

	var off_center := RogueRouteGraph.new()
	var off_center_errors := off_center.initialize_layout(
		graph.generation_seed,
		graph.width,
		graph.height,
		0,
		graph.node_types,
		graph.node_content_seeds,
		graph.visual_offsets,
		graph.edges
	)
	_expect(
		_has_error_containing(off_center_errors, "正中心"),
		"图契约必须拒绝不在正中心的起点。"
	)


func _test_local_movement(graph: RogueRouteGraph, empty_neighbor_id: int) -> void:
	var runtime := RogueRouteRuntimeState.new()
	var committed_deltas: Array[Dictionary] = []
	runtime.move_committed.connect(func(delta: Dictionary) -> void:
		committed_deltas.append(delta)
	)
	_expect(runtime.initialize(graph, 3), "运行态必须接受合法图和三点行动力。")
	_expect(
		runtime.current_node_id == graph.start_node_id
		and runtime.state_revision == 0
		and runtime.action_points == 3
		and runtime.visited_counts[graph.start_node_id] == 1,
		"初始化必须把共享小队放在中心并记录一次访问。"
	)

	var initial_snapshot := runtime.export_state()
	_expect(
		runtime.try_move(empty_neighbor_id, 1, 0),
		"与中心连通的 EMPTY 节点必须可正常行走。"
	)
	_expect(
		runtime.current_node_id == empty_neighbor_id
		and runtime.action_points == 2
		and runtime.state_revision == 1
		and runtime.visited_counts[empty_neighbor_id] == 1,
		"移动到空节点必须原子扣除行动力、推进 revision 并累计访问。"
	)
	var after_first_move := runtime.export_state()
	_expect(
		not runtime.try_move(graph.start_node_id, 1, 0)
		and runtime.export_state() == after_first_move,
		"旧 revision 的重复请求必须零副作用拒绝。"
	)

	var non_neighbor_id := _find_non_neighbor(graph, runtime.current_node_id)
	_expect(
		non_neighbor_id >= 0
		and not runtime.try_move(non_neighbor_id, 1, runtime.state_revision)
		and runtime.export_state() == after_first_move,
		"未连接格不得通过点击直接跨越。"
	)
	_expect(
		not runtime.try_move(graph.start_node_id, 0, runtime.state_revision)
		and runtime.export_state() == after_first_move,
		"零或负移动消耗必须被拒绝，不能成为免费移动。"
	)

	_expect(
		runtime.try_move(graph.start_node_id, 1, 1),
		"路线必须允许沿原边回退到中心。"
	)
	_expect(
		runtime.try_move(empty_neighbor_id, 1, 2),
		"路线必须允许重复访问同一空节点。"
	)
	_expect(
		runtime.action_points == 0
		and runtime.state_revision == 3
		and runtime.visited_counts[graph.start_node_id] == 2
		and runtime.visited_counts[empty_neighbor_id] == 2
		and committed_deltas.size() == 3,
		"回退和重复访问必须每格扣费并分别累加访问次数。"
	)
	var exhausted_snapshot := runtime.export_state()
	_expect(
		not runtime.can_move_to(graph.start_node_id, 1, 3)
		and runtime.get_move_rejection_reason(graph.start_node_id, 1, 3) == "行动力不足"
		and not runtime.try_move(graph.start_node_id, 1, 3)
		and runtime.export_state() == exhausted_snapshot,
		"行动力耗尽后所有后续移动必须零副作用拒绝。"
	)
	_expect(
		int(initial_snapshot["revision"]) == 0,
		"导出的历史快照必须是独立副本，不能被后续移动回写。"
	)


func _test_remote_state_and_delta_boundaries(
	graph: RogueRouteGraph,
	empty_neighbor_id: int
) -> void:
	var host := RogueRouteRuntimeState.new()
	var client := RogueRouteRuntimeState.new()
	var deltas: Array[Dictionary] = []
	host.move_committed.connect(func(delta: Dictionary) -> void:
		deltas.append(delta)
	)
	_expect(
		host.initialize(graph, 5) and client.initialize(graph, 5),
		"Host 与 Client 运行态必须从同一布局和行动力初始化。"
	)
	var revision_zero_snapshot := host.export_state()
	_expect(
		host.try_move(empty_neighbor_id, 1, 0)
		and host.try_move(graph.start_node_id, 1, 1)
		and deltas.size() == 2,
		"Host 必须产生两个连续、可应用的移动 delta。"
	)
	if deltas.size() != 2:
		return

	_expect(
		client.apply_remote_move_delta(deltas[0]),
		"Client 必须接受恰好 revision+1 的合法移动 delta。"
	)
	var client_after_first_delta := client.export_state()
	_expect(
		not client.apply_remote_move_delta(deltas[0])
		and client.export_state() == client_after_first_delta,
		"重复 delta 必须被幂等拒绝且不改变 Client。"
	)
	var wrong_layout_delta := deltas[1].duplicate(true)
	wrong_layout_delta["layout_hash"] = "wrong-layout"
	_expect(
		not client.apply_remote_move_delta(wrong_layout_delta)
		and client.apply_remote_move_delta(deltas[1]),
		"错误布局 delta 必须拒绝，随后正确连续 delta 仍应接受。"
	)
	_expect(
		client.export_state() == host.export_state(),
		"顺序应用 Host delta 后，Client 状态必须逐字段一致。"
	)

	var late_client := RogueRouteRuntimeState.new()
	_expect(
		late_client.initialize(graph, 5)
		and late_client.apply_remote_state(host.export_state())
		and late_client.export_state() == host.export_state(),
		"晚加入 Client 必须能通过完整状态快照一次追平。"
	)
	_expect(
		late_client.apply_remote_state(host.export_state()),
		"完全相同 revision 的快照必须作为幂等重放接受。"
	)
	_expect(
		not late_client.apply_remote_state(revision_zero_snapshot),
		"旧 revision 全量快照不得回滚状态。"
	)

	var inconsistent_visits := host.export_state()
	inconsistent_visits["revision"] = 3
	_expect(
		not late_client.apply_remote_state(inconsistent_visits),
		"revision 与总访问次数不一致的快照必须拒绝。"
	)
	var negative_visits := host.export_state()
	negative_visits["revision"] = 3
	var negative_counts := host.visited_counts.duplicate()
	negative_counts[0] = -1
	negative_visits["visited_counts"] = negative_counts
	_expect(
		not late_client.apply_remote_state(negative_visits),
		"包含负访问次数的快照必须拒绝。"
	)
	var increased_action_points := host.export_state()
	increased_action_points["revision"] = 3
	increased_action_points["action_points"] = host.action_points + 1
	var increased_counts := host.visited_counts.duplicate()
	increased_counts[graph.start_node_id] += 1
	increased_action_points["visited_counts"] = increased_counts
	_expect(
		not late_client.apply_remote_state(increased_action_points),
		"仅消费模型下，高 revision 快照不得凭空增加行动力。"
	)
	var rolled_back_visit := host.export_state()
	rolled_back_visit["revision"] = 3
	rolled_back_visit["action_points"] = host.action_points - 1
	var rollback_counts := host.visited_counts.duplicate()
	rollback_counts[graph.start_node_id] -= 1
	var untouched_node_id := _find_unvisited_node(graph, rollback_counts)
	if untouched_node_id >= 0:
		rollback_counts[untouched_node_id] += 2
	rolled_back_visit["visited_counts"] = rollback_counts
	_expect(
		untouched_node_id >= 0
		and not late_client.apply_remote_state(rolled_back_visit),
		"高 revision 快照不得回滚任一节点的既有访问次数。"
	)
	var wrong_scalar_type := host.export_state()
	wrong_scalar_type["revision"] = str(host.state_revision)
	_expect(
		not late_client.apply_remote_state(wrong_scalar_type),
		"运行态快照不得把字符串 revision 宽泛转换为整数。"
	)


func _test_board_contract(
	graph: RogueRouteGraph,
	empty_neighbor_id: int
) -> void:
	var board := BOARD_SCENE.instantiate() as RogueRouteBoard
	_expect(board != null, "路线棋盘场景必须实例化为 RogueRouteBoard。")
	if board == null:
		return
	root.add_child(board)
	board.set_anchors_preset(Control.PRESET_TOP_LEFT)
	board.size = Vector2(1000.0, 560.0)
	await process_frame

	var runtime := RogueRouteRuntimeState.new()
	_expect(runtime.initialize(graph, 2), "棋盘测试运行态必须成功初始化。")
	_expect(
		board.present_graph(
			graph,
			DEFAULT_CONFIG,
			runtime.current_node_id,
			runtime.action_points,
			runtime.visited_counts,
			true
		),
		"棋盘必须接受合法图与合法运行态视图。"
	)
	_expect(
		(board.get("_cells") as Dictionary).size() == graph.get_node_count(),
		"棋盘必须为 99 个逻辑格各实例化一个复用 Cell 场景。"
	)
	var cell_layer := board.get_node_or_null("CellLayer") as Control
	var first_cells: Array[RogueRouteCell] = []
	for node_id in range(graph.get_node_count()):
		first_cells.append(board.get_cell(node_id))
	_expect(
		board.present_graph(
			graph,
			DEFAULT_CONFIG,
			runtime.current_node_id,
			runtime.action_points,
			runtime.visited_counts,
			true
		),
		"同一布局必须支持原子重呈现。"
	)
	var stale_cell_attached := false
	var stale_cell_reused := false
	for node_id in range(first_cells.size()):
		var old_cell := first_cells[node_id]
		if old_cell == null:
			stale_cell_attached = true
			continue
		stale_cell_attached = (
			stale_cell_attached
			or old_cell.get_parent() == cell_layer
		)
		stale_cell_reused = (
			stale_cell_reused
			or old_cell == board.get_cell(node_id)
		)
	_expect(
		cell_layer != null
		and cell_layer.get_child_count() == graph.get_node_count()
		and not stale_cell_attached
		and not stale_cell_reused,
		"同帧重呈现后 CellLayer 只能保留 99 个新 Cell，不得残留或复用旧实例。"
	)

	var start_cell := board.get_cell(graph.start_node_id)
	var empty_cell := board.get_cell(empty_neighbor_id)
	var far_node_id := _find_non_neighbor(graph, graph.start_node_id)
	var far_cell := board.get_cell(far_node_id)
	_expect(
		start_cell != null
		and empty_cell != null
		and empty_cell.is_empty
		and empty_cell.empty_bead.visible
		and not empty_cell.content_disc.visible
		and not empty_cell.name_label.visible
		and empty_cell.is_interaction_enabled(),
		"相邻空节点必须仅显示小圆珠、隐藏名称，并且无需玩家位置即可点击移动。"
	)
	var named_cell: RogueRouteCell = null
	for node_id in range(graph.get_node_count()):
		if graph.get_node_type(node_id) != RogueRouteGraph.NodeType.EMPTY:
			named_cell = board.get_cell(node_id)
			break
	_expect(
		named_cell != null
		and named_cell.name_label.visible
		and far_cell != null
		and not far_cell.is_interaction_enabled(),
		"事件节点名称必须常显，未连接远端不得可交互。"
	)

	var pressed_node_ids: Array[int] = []
	board.node_pressed.connect(func(node_id: int) -> void:
		pressed_node_ids.append(node_id)
	)
	board.call("_on_cell_pressed", far_node_id)
	board.call("_on_cell_pressed", empty_neighbor_id)
	_expect(
		pressed_node_ids == [empty_neighbor_id],
		"棋盘信号边界必须再次拒绝非邻格，只上报合法相邻格。"
	)
	board.set_authority_enabled(false)
	board.call("_on_cell_pressed", empty_neighbor_id)
	_expect(
		pressed_node_ids == [empty_neighbor_id]
		and not empty_cell.is_interaction_enabled(),
		"非房主棋盘不得发出移动选择。"
	)
	board.set_authority_enabled(true)

	_expect(runtime.try_move(empty_neighbor_id, 1, 0), "棋盘更新夹具必须完成首步移动。")
	_expect(
		board.update_runtime_state(
			runtime.current_node_id,
			runtime.action_points,
			runtime.visited_counts,
			false
		),
		"棋盘必须接受合法移动后的运行态。"
	)
	_expect(
		board.current_node_id == empty_neighbor_id
		and empty_cell.visited_mark.visible == false,
		"群体当前位置必须切换到目标；当前格不应叠加已访问角标。"
	)

	var previous_node_id := board.current_node_id
	var invalid_counts := runtime.visited_counts.duplicate()
	invalid_counts[empty_neighbor_id] = -1
	_expect(
		not board.update_runtime_state(empty_neighbor_id, 1, invalid_counts, false)
		and board.current_node_id == previous_node_id,
		"棋盘必须拒绝负访问次数并保持原视图。"
	)
	var zero_current_visit := runtime.visited_counts.duplicate()
	zero_current_visit[empty_neighbor_id] = 0
	_expect(
		not board.update_runtime_state(empty_neighbor_id, 1, zero_current_visit, false),
		"棋盘必须拒绝当前格从未访问的矛盾视图。"
	)
	_expect(
		not board.update_runtime_state(empty_neighbor_id, -1, runtime.visited_counts, false),
		"棋盘必须拒绝负行动力而不是静默夹成零。"
	)

	_expect(
		board.update_runtime_state(
			empty_neighbor_id,
			0,
			runtime.visited_counts,
			false
		),
		"棋盘必须允许显示恰好耗尽为零的行动力。"
	)
	var every_neighbor_disabled := true
	for neighbor_id in graph.get_neighbors(empty_neighbor_id):
		every_neighbor_disabled = (
			every_neighbor_disabled
			and not board.get_cell(int(neighbor_id)).is_interaction_enabled()
		)
	_expect(
		every_neighbor_disabled,
		"行动力耗尽时所有相邻格按钮都必须禁用。"
	)

	var mismatched_config := DEFAULT_CONFIG.duplicate(true) as RogueRouteGenerationConfig
	mismatched_config.width = 9
	_expect(
		not board.present_graph(
			graph,
			mismatched_config,
			empty_neighbor_id,
			0,
			runtime.visited_counts,
			true
		),
		"棋盘必须拒绝尺寸与布局不一致的生成配置。"
	)
	_expect(
		not board.present_graph(
			graph,
			DEFAULT_CONFIG,
			empty_neighbor_id,
			-1,
			runtime.visited_counts,
			true
		),
		"棋盘初始呈现也必须拒绝负行动力。"
	)

	var invalid_offset_graph := _make_graph_with_out_of_bounds_offset(graph)
	_expect(
		invalid_offset_graph != null,
		"越界视觉偏移测试夹具必须仍是结构合法的路线图。"
	)
	if invalid_offset_graph != null:
		var graph_before_rejection := board.graph
		var child_count_before_rejection := (
			cell_layer.get_child_count() if cell_layer != null else -1
		)
		_expect(
			not board.present_graph(
				invalid_offset_graph,
				DEFAULT_CONFIG,
				empty_neighbor_id,
				0,
				runtime.visited_counts,
				true
			)
			and board.graph == graph_before_rejection
			and cell_layer != null
			and cell_layer.get_child_count() == child_count_before_rejection,
			"超过配置 visual_jitter 的快照必须在清空现有棋盘前零副作用拒绝。"
		)

	board.queue_free()
	await process_frame
	await process_frame


func _make_graph_with_out_of_bounds_offset(
	source: RogueRouteGraph
) -> RogueRouteGraph:
	var offsets := source.visual_offsets.duplicate()
	var target_node_id := 0 if source.start_node_id != 0 else 1
	offsets[target_node_id] = Vector2(
		float(DEFAULT_CONFIG.visual_jitter_pixels.x + 1),
		0.0
	)
	var result := RogueRouteGraph.new()
	var errors := result.initialize_layout(
		source.generation_seed,
		source.width,
		source.height,
		source.start_node_id,
		source.node_types,
		source.node_content_seeds,
		offsets,
		source.edges
	)
	if not errors.is_empty():
		return null
	return result


func _find_non_neighbor(graph: RogueRouteGraph, source_node_id: int) -> int:
	for candidate_id in range(graph.get_node_count()):
		if candidate_id != source_node_id and not graph.has_edge(source_node_id, candidate_id):
			return candidate_id
	return -1


func _find_unvisited_node(
	graph: RogueRouteGraph,
	counts: PackedInt32Array
) -> int:
	for node_id in range(graph.get_node_count()):
		if counts[node_id] == 0:
			return node_id
	return -1


func _has_error_containing(errors: PackedStringArray, needle: String) -> bool:
	for error in errors:
		if error.contains(needle):
			return true
	return false


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("ROGUE_ROUTE_RUNTIME_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)
