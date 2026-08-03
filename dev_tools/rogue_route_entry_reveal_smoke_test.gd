extends SceneTree

const DEFAULT_CONFIG: RogueRouteGenerationConfig = preload(
	"res://resources/config/rogue_route/p3_generation_config.tres"
)
const BOARD_SCENE: PackedScene = preload(
	"res://scene/rogue_route/rogue_route_board.tscn"
)

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var graph := RogueRouteGenerator.generate(DEFAULT_CONFIG, 0x5EA1)
	_expect(graph != null, "入场动画测试必须生成合法路线图。")
	if graph == null:
		_finish()
		return
	var runtime := RogueRouteRuntimeState.new()
	_expect(
		runtime.initialize(graph, DEFAULT_CONFIG.initial_action_points),
		"入场动画测试必须初始化合法运行态。"
	)
	var board := BOARD_SCENE.instantiate() as RogueRouteBoard
	_expect(board != null, "入场动画测试必须实例化路线棋盘。")
	if board == null:
		_finish()
		return
	root.add_child(board)
	await process_frame

	_expect(
		board.present_graph(
			graph,
			DEFAULT_CONFIG,
			runtime.current_node_id,
			runtime.action_points,
			runtime.visited_counts,
			true
		),
		"路线棋盘必须接受默认预备入场动画的合法图。"
	)
	var connections := board.get_node("Connections") as RogueRouteConnections
	var depths := board.get("_entry_reveal_depths") as Dictionary
	var farthest_node_id := _find_farthest_node_id(depths)
	var root_cell := board.get_cell(graph.start_node_id)
	var farthest_cell := board.get_cell(farthest_node_id)
	_expect(
		board.is_entry_reveal_prepared()
		and not board.is_entry_reveal_playing()
		and is_zero_approx(board.get_entry_reveal_progress())
		and is_zero_approx(connections.get_entry_reveal_progress()),
		"present_graph 默认必须只预备动画，不得提前播放。"
	)
	_expect(
		depths.size() == graph.get_node_count()
		and int(depths.get(graph.start_node_id, -1)) == 0
		and farthest_node_id != graph.start_node_id,
		"入场动画必须从当前节点生成覆盖整张连通图的 BFS 深度。"
	)
	_expect(
		root_cell != null
		and farthest_cell != null
		and is_zero_approx(root_cell.get_entry_reveal_progress())
		and is_zero_approx(farthest_cell.get_entry_reveal_progress()),
		"动画预备态必须在首帧隐藏全部节点。"
	)

	board.call("_apply_entry_reveal_progress", 0.08)
	var near_node_id := int(graph.get_neighbors(graph.start_node_id)[0])
	var far_parent_id := _find_previous_depth_neighbor(
		graph,
		depths,
		farthest_node_id
	)
	var near_edge_progress := float(connections.call(
		"_get_edge_reveal_fraction",
		graph.start_node_id,
		near_node_id
	))
	var far_edge_progress := float(connections.call(
		"_get_edge_reveal_fraction",
		far_parent_id,
		farthest_node_id
	))
	_expect(
		root_cell.get_entry_reveal_progress() > 0.0
		and is_zero_approx(farthest_cell.get_entry_reveal_progress()),
		"BFS 动画前段必须先揭示根节点，最远节点仍保持隐藏。"
	)
	_expect(
		near_edge_progress > 0.0
		and is_zero_approx(far_edge_progress),
		"连线生长必须按 BFS 波次由根节点向外展开。"
	)

	var finished_events: Array[bool] = []
	board.entry_reveal_finished.connect(func() -> void:
		finished_events.append(true)
	)
	_expect(board.prepare_entry_reveal(), "已装配棋盘必须允许重新预备动画。")
	board.play_entry_reveal(0.5)
	_expect(board.is_entry_reveal_playing(), "play_entry_reveal 必须启动唯一 Tween。")
	await create_timer(0.60).timeout
	_expect(
		not board.is_entry_reveal_playing()
		and not board.is_entry_reveal_prepared()
		and is_equal_approx(board.get_entry_reveal_progress(), 1.0)
		and is_equal_approx(connections.get_entry_reveal_progress(), 1.0)
		and finished_events.size() == 1,
		"Tween 完成后必须归一视觉、释放播放态并只发出一次完成信号。"
	)
	_expect(
		is_equal_approx(root_cell.self_modulate.a, 1.0)
		and root_cell.scale.is_equal_approx(Vector2.ONE)
		and is_equal_approx(farthest_cell.self_modulate.a, 1.0)
		and farthest_cell.scale.is_equal_approx(Vector2.ONE),
		"动画完成后近端与远端节点都必须恢复精确的完整视觉状态。"
	)

	_expect(board.prepare_entry_reveal(), "棋盘必须支持再次预备可中断动画。")
	board.play_entry_reveal(0.5)
	await process_frame
	board.complete_entry_reveal()
	await create_timer(0.04).timeout
	_expect(
		not board.is_entry_reveal_playing()
		and finished_events.size() == 2
		and is_equal_approx(board.get_entry_reveal_progress(), 1.0),
		"complete_entry_reveal 必须安全中止 Tween，且不得留下延迟完成回调。"
	)

	_expect(
		board.present_graph(
			graph,
			DEFAULT_CONFIG,
			runtime.current_node_id,
			runtime.action_points,
			runtime.visited_counts,
			true,
			false
		),
		"旧式即时呈现路径必须可显式关闭入场动画。"
	)
	_expect(
		not board.is_entry_reveal_prepared()
		and not board.is_entry_reveal_playing()
		and is_equal_approx(board.get_entry_reveal_progress(), 1.0),
		"关闭动画的 present_graph 必须立即显示完整棋盘。"
	)

	root.remove_child(board)
	board.free()
	_finish()


func _find_farthest_node_id(depths: Dictionary) -> int:
	var farthest_node_id := -1
	var farthest_depth := -1
	for node_id_variant in depths:
		var node_id := int(node_id_variant)
		var depth := int(depths[node_id])
		if depth > farthest_depth or (
			depth == farthest_depth and node_id < farthest_node_id
		):
			farthest_node_id = node_id
			farthest_depth = depth
	return farthest_node_id


func _find_previous_depth_neighbor(
	graph: RogueRouteGraph,
	depths: Dictionary,
	node_id: int
) -> int:
	var node_depth := int(depths.get(node_id, -1))
	for neighbor_id_variant in graph.get_neighbors(node_id):
		var neighbor_id := int(neighbor_id_variant)
		if int(depths.get(neighbor_id, -1)) == node_depth - 1:
			return neighbor_id
	return node_id


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("ROGUE_ROUTE_ENTRY_REVEAL_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)
