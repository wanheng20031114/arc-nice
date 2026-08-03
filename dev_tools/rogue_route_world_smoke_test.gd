extends SceneTree

const ROUTE_SCENE := preload("res://scene/test_arena/test_rogue_route_p3.tscn")
const EXPECTED_WORLD_SIZE := Vector2(1072.0, 576.0)
const EXPECTED_CELL_SPACING := Vector2(88.0, 48.0)
const EXPECTED_BOARD_MARGIN := Vector2(96.0, 96.0)
const EXPECTED_VISUAL_JITTER := Vector2(5.0, 2.0)
const EXPECTED_BACKGROUND_SIZE := Vector2(2304.0, 1296.0)
const EXPECTED_CAMERA_ZOOM := 2.0
const PLAYER_BODY_HEIGHT := 24.0
const MIN_VISIBLE_COLUMNS := 7
const MIN_VISIBLE_ROWS := 5
const EXPECTED_EMPTY_BEAD_SIZE := Vector2(8.0, 8.0)
const EXPECTED_NODE_HIT_SIZE := Vector2(32.0, 32.0)
const EXPECTED_SCREEN_FONT_SIZE := 18.0
const MAX_SCREEN_LINE_WIDTH := 3.0
const ROUTE_CONTRACT_FIELD := "runtime_contract_hash"

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var run_state := root.get_node_or_null("RunState") as RunStateStore
	if run_state != null:
		run_state.begin_new_run(PlayerCharacterRegistry.TANGO_ID, false)
	var route := ROUTE_SCENE.instantiate() as TestRogueRouteP3
	_expect(route != null, "P3 世界场景必须能够实例化。")
	if route == null:
		_finish()
		return
	route.initial_generation_seed = 424242
	root.add_child(route)
	current_scene = route
	for _frame in range(8):
		await process_frame

	_expect(route.is_route_ready(), "P3 世界必须完成路线初始化。")
	var board := route.get_node_or_null("World/RouteBoard") as RogueRouteBoard
	# 本测试关注路线世界交互与镜头契约；入场动画有独立目标测试。
	# 完成预备动画并通过正式 signal 解锁宿主，避免把过渡期锁定误判为故障。
	if board != null:
		board.complete_entry_reveal()
	var player_layer := route.get_node_or_null("World/Players") as Node2D
	var local_player := route.get("player") as Player
	var camera := route.get_node_or_null("World/Players/Player/Camera2D") as Camera2D
	if camera == null:
		camera = route.find_child("Camera2D", true, false) as Camera2D
	_expect(board != null, "P3 必须使用世界空间路线板。")
	_expect(player_layer != null, "P3 必须保留独立玩家渲染层。")
	_expect(local_player != null, "P3 必须实例化所选角色。")
	_expect(camera != null, "P3 必须保留唯一 Camera2D。")
	_audit_backdrop(route)
	if board != null:
		_audit_board(route, board, player_layer, camera)
	_audit_snapshot_contract(route)
	if local_player != null:
		await _audit_player_and_camera(route, local_player, camera)
	_audit_hud(route)

	current_scene = null
	root.remove_child(route)
	route.free()
	await process_frame
	_finish()


func _audit_backdrop(route: TestRogueRouteP3) -> void:
	var backdrop := route.get_node_or_null("World/Backdrop") as Parallax2D
	var ruins_background := (
		route.get_node_or_null("World/Backdrop/RuinsBackground") as Sprite2D
	)
	_expect(backdrop != null, "P3 地下遗址背景必须使用原生 Parallax2D。")
	_expect(ruins_background != null, "Parallax2D 下必须挂载 RuinsBackground。")
	if backdrop != null:
		_expect(
			backdrop.scroll_scale.x >= 0.08
			and backdrop.scroll_scale.x <= 0.12
			and backdrop.scroll_scale.y >= 0.08
			and backdrop.scroll_scale.y <= 0.12,
			"地下遗址背景必须以约 0.1 的 scroll_scale 轻微同向视差移动。"
		)
		_expect(backdrop.follow_viewport, "地下遗址视差层必须跟随活动视口。")
	if ruins_background != null:
		_expect(ruins_background.texture != null, "RuinsBackground 必须绑定生成背景。")
		if ruins_background.texture != null:
			_expect(
				ruins_background.texture.get_size().is_equal_approx(
					EXPECTED_BACKGROUND_SIZE
				),
				"地下遗址母图必须保持 2304×1296。"
			)
		_expect(
			ruins_background.texture_filter == CanvasItem.TEXTURE_FILTER_LINEAR,
			"非像素地下遗址背景必须使用 LINEAR 过滤。"
		)
		_expect(
			ruins_background.scale.is_equal_approx(Vector2(0.5, 0.5)),
			"2304×1296 地下遗址母图必须以 0.5 倍覆盖路线世界。"
		)
		var texture_half_size := ruins_background.texture.get_size() * 0.5
		var canvas_transform := ruins_background.get_global_transform_with_canvas()
		var screen_bounds := Rect2(
			canvas_transform * -texture_half_size,
			Vector2.ZERO
		)
		screen_bounds = screen_bounds.expand(
			canvas_transform * Vector2(texture_half_size.x, -texture_half_size.y)
		)
		screen_bounds = screen_bounds.expand(canvas_transform * texture_half_size)
		screen_bounds = screen_bounds.expand(
			canvas_transform * Vector2(-texture_half_size.x, texture_half_size.y)
		)
		_expect(
			screen_bounds.encloses(route.get_viewport_rect()),
			"地下遗址背景必须覆盖完整活动视口：背景=%s 视口=%s"
			% [screen_bounds, route.get_viewport_rect()]
		)
	var title := route.get_node_or_null("HUD/Root/TopBar/TopLayout/TitleBlock/Title") as Label
	_expect(title != null and title.text == "地下遗址勘探", "P3 顶部标题必须使用地下遗址主题。")


func _audit_board(
	route: TestRogueRouteP3,
	board: RogueRouteBoard,
	player_layer: Node2D,
	camera: Camera2D
) -> void:
	var obsolete_group_marker := board.get_node_or_null("GroupMarker")
	var metrics := board.get_world_metrics()
	_expect(
		player_layer != null
		and board.z_index < player_layer.z_index
		and obsolete_group_marker == null,
		"路线节点必须绘制在玩家下方，Board 不得再保留误导性的 GroupMarker。"
	)
	_expect(
		board.size.is_equal_approx(EXPECTED_WORLD_SIZE),
		"11×9 路线世界必须由统一度量计算为 1072×576。"
	)
	_expect(metrics != null, "路线板必须绑定统一 RogueRouteWorldMetrics。")
	if metrics == null:
		return
	_expect(
		metrics.validate_metrics().is_empty()
		and metrics.cell_spacing.is_equal_approx(EXPECTED_CELL_SPACING)
		and metrics.board_margin.is_equal_approx(EXPECTED_BOARD_MARGIN)
		and is_equal_approx(metrics.camera_zoom, EXPECTED_CAMERA_ZOOM)
		and metrics.get_layout_size(Vector2i(11, 9)).is_equal_approx(
			EXPECTED_WORLD_SIZE
		),
		"路线间距、边距、镜头缩放与世界尺寸必须来自同一份度量资源。"
	)
	_expect(
		board.texture_filter == CanvasItem.TEXTURE_FILTER_LINEAR,
		"路线节点与界面素材必须使用 LINEAR 过滤。"
	)

	var graph := board.graph
	if graph == null:
		_expect(false, "路线板必须持有已生成图数据。")
		return
	for node_id in range(graph.get_node_count()):
		var coord := graph.id_to_coord(node_id)
		var base_position := (
			metrics.board_margin
			+ Vector2(coord.x, coord.y) * metrics.cell_spacing
		)
		var jitter := board.get_node_position(node_id) - base_position
		_expect(
			absf(jitter.x) <= EXPECTED_VISUAL_JITTER.x
			and absf(jitter.y) <= EXPECTED_VISUAL_JITTER.y,
			"节点 #%d 的位置必须服从统一间距，视觉抖动不得越界。" % node_id
		)

	var connections := board.get_node_or_null("Connections") as RogueRouteConnections
	var cell_layer := board.get_node_or_null("CellLayer") as Control
	_expect(connections != null, "路线板必须包含独立连接线层。")
	_expect(cell_layer != null, "路线板必须包含独立节点层。")
	if connections != null:
		_expect(
			connections.get_base_line_count() == graph.edges.size() / 2,
			"连接层绘制结果必须覆盖每条逻辑边。"
		)
		_expect(
			connections.get_highlighted_line_count() <= 4,
			"动态高亮路线数量必须受当前节点度数限制。"
		)
		_expect(
			cell_layer != null and connections.get_index() < cell_layer.get_index(),
			"连接线层必须绘制在节点层下方。"
		)
		_expect(
			connections.get_child_count() == 0,
			"连接层必须单 Canvas 自绘，不能再为每条边生成 Line2D 子节点。"
		)
		if camera != null:
			var maximum_screen_width := maxf(
				connections.base_line_width,
				connections.reachable_line_width
			) * camera.zoom.x
			_expect(
				maximum_screen_width <= MAX_SCREEN_LINE_WIDTH + 0.001,
				"最粗路线在屏幕上不得超过 %.1f 像素（当前 %.2f）。"
				% [MAX_SCREEN_LINE_WIDTH, maximum_screen_width]
			)
	_audit_empty_cell(board, graph)
	_audit_event_cell_scale(board, graph, camera)
	_audit_density_budget(route, camera, metrics)
	_audit_world_bounds(route, board, camera, metrics)


func _audit_empty_cell(board: RogueRouteBoard, graph: RogueRouteGraph) -> void:
	var empty_cell: RogueRouteCell = null
	for node_id in range(graph.get_node_count()):
		if graph.get_node_type(node_id) == RogueRouteGraph.NodeType.EMPTY:
			empty_cell = board.get_cell(node_id)
			break
	_expect(empty_cell != null, "固定测试 seed 必须生成至少一个空节点。")
	if empty_cell == null:
		return
	var button := empty_cell.get_node_or_null("NodeButton") as Button
	var bead := empty_cell.get_node_or_null("NodeButton/EmptyBead") as Control
	_expect(
		button != null and button.size.is_equal_approx(EXPECTED_NODE_HIT_SIZE),
		"空节点必须以 8×8 视觉和 32×32 命中区解耦。"
	)
	_expect(
		bead != null and bead.size.is_equal_approx(EXPECTED_EMPTY_BEAD_SIZE),
		"空节点视觉主体必须为 8×8 小圆珠（当前 %s）。"
		% (bead.size if bead != null else Vector2.ZERO)
	)


func _audit_event_cell_scale(
	board: RogueRouteBoard,
	graph: RogueRouteGraph,
	camera: Camera2D
) -> void:
	var event_cell: RogueRouteCell = null
	for node_id in range(graph.get_node_count()):
		if graph.get_node_type(node_id) != RogueRouteGraph.NodeType.EMPTY:
			event_cell = board.get_cell(node_id)
			break
	_expect(event_cell != null, "固定 seed 必须生成至少一个事件节点。")
	if event_cell == null:
		return
	var disc_size := event_cell.content_disc.size
	var largest_disc_side := maxf(disc_size.x, disc_size.y)
	_expect(
		largest_disc_side >= PLAYER_BODY_HEIGHT * 0.75
		and largest_disc_side <= PLAYER_BODY_HEIGHT * 1.25,
		"事件圆盘必须与 24px 高角色同量级（当前 %s）。" % disc_size
	)
	var name_label := event_cell.name_label
	var net_scale := name_label.scale
	if camera != null:
		net_scale *= camera.zoom
	var screen_font_size := (
		float(name_label.get_theme_font_size(&"font_size")) * net_scale.y
	)
	_expect(
		net_scale.is_equal_approx(Vector2.ONE),
		"世界节点名称必须在 2×镜头下保持净 1× 栅格化，避免二次缩放模糊。"
	)
	_expect(
		is_equal_approx(screen_font_size, EXPECTED_SCREEN_FONT_SIZE),
		"节点名称屏幕字号必须稳定为 18px（当前 %.2f）。" % screen_font_size
	)


func _audit_density_budget(
	route: TestRogueRouteP3,
	camera: Camera2D,
	metrics: RogueRouteWorldMetrics
) -> void:
	if camera == null or metrics == null:
		return
	var top_bar := route.get_node_or_null("HUD/Root/TopBar") as Control
	var bottom_bar := route.get_node_or_null("HUD/Root/BottomBar") as Control
	_expect(
		top_bar != null and bottom_bar != null,
		"视野密度预算需要完整的顶部与底部 HUD。"
	)
	if top_bar == null or bottom_bar == null:
		return
	var viewport_size := route.get_viewport_rect().size
	var safe_screen_height := (
		bottom_bar.get_global_rect().position.y
		- top_bar.get_global_rect().end.y
	)
	var visible_world_size := Vector2(
		viewport_size.x / camera.zoom.x,
		maxf(safe_screen_height, 0.0) / camera.zoom.y
	)
	var visible_columns := floori(
		visible_world_size.x / metrics.cell_spacing.x
	) + 1
	var visible_rows := floori(
		visible_world_size.y / metrics.cell_spacing.y
	) + 1
	_expect(
		visible_columns >= MIN_VISIBLE_COLUMNS
		and visible_rows >= MIN_VISIBLE_ROWS,
		"中央安全视野必须至少容纳 %d 列×%d 行节点预算（当前 %d×%d）。"
		% [MIN_VISIBLE_COLUMNS, MIN_VISIBLE_ROWS, visible_columns, visible_rows]
	)


func _audit_world_bounds(
	route: TestRogueRouteP3,
	board: RogueRouteBoard,
	camera: Camera2D,
	metrics: RogueRouteWorldMetrics
) -> void:
	if camera == null or metrics == null:
		return
	var world := route.get_node_or_null("World") as RogueRouteWorld
	_expect(world != null, "P3 世界必须由 RogueRouteWorld 统一派生边界。")
	if world == null:
		return
	var board_bounds := board.get_world_bounds()
	var camera_bounds := Rect2(
		Vector2(camera.limit_left, camera.limit_top),
		Vector2(
			camera.limit_right - camera.limit_left,
			camera.limit_bottom - camera.limit_top
		)
	)
	_expect(
		board_bounds.is_equal_approx(camera_bounds),
		"Board bounds 必须与 Camera limits 完全同源。"
	)
	var local_start := world.to_local(board_bounds.position)
	var local_end := world.to_local(board_bounds.end)
	var local_bounds := Rect2(local_start, local_end - local_start).abs()
	var thickness := metrics.boundary_thickness
	_audit_boundary_shape(
		world.left_boundary,
		Vector2(thickness, local_bounds.size.y + thickness * 2.0),
		Vector2(local_bounds.position.x - thickness * 0.5, local_bounds.get_center().y),
		"左"
	)
	_audit_boundary_shape(
		world.right_boundary,
		Vector2(thickness, local_bounds.size.y + thickness * 2.0),
		Vector2(local_bounds.end.x + thickness * 0.5, local_bounds.get_center().y),
		"右"
	)
	_audit_boundary_shape(
		world.top_boundary,
		Vector2(local_bounds.size.x + thickness * 2.0, thickness),
		Vector2(local_bounds.get_center().x, local_bounds.position.y - thickness * 0.5),
		"上"
	)
	_audit_boundary_shape(
		world.bottom_boundary,
		Vector2(local_bounds.size.x + thickness * 2.0, thickness),
		Vector2(local_bounds.get_center().x, local_bounds.end.y + thickness * 0.5),
		"下"
	)
	_expect(
		world.ruins_background.position.is_equal_approx(local_bounds.get_center()),
		"地下遗址背景中心必须由当前 Board bounds 动态派生。"
	)


func _audit_boundary_shape(
	boundary: CollisionShape2D,
	expected_size: Vector2,
	expected_position: Vector2,
	direction: String
) -> void:
	var rectangle: RectangleShape2D = null
	if boundary != null:
		rectangle = boundary.shape as RectangleShape2D
	_expect(
		boundary != null
		and rectangle != null
		and rectangle.size.is_equal_approx(expected_size)
		and boundary.position.is_equal_approx(expected_position),
		"%s侧碰撞墙必须由 Board bounds 与统一厚度动态推导。" % direction
	)


func _audit_snapshot_contract(route: TestRogueRouteP3) -> void:
	var layout_snapshot := route.export_layout_snapshot()
	var state_snapshot := route.export_state_snapshot()
	var expected_hash := route.get_runtime_contract_hash()
	_expect(
		expected_hash.length() == 64
		and str(layout_snapshot.get(ROUTE_CONTRACT_FIELD, "")) == expected_hash,
		"完整布局快照必须携带当前 64 字符十六进制 runtime_contract_hash。"
	)
	var missing_contract := layout_snapshot.duplicate(true)
	missing_contract.erase(ROUTE_CONTRACT_FIELD)
	var wrong_contract := layout_snapshot.duplicate(true)
	wrong_contract[ROUTE_CONTRACT_FIELD] = "wrong-contract"
	var state_before := route.export_state_snapshot()
	_expect(
		not route.apply_full_snapshot(missing_contract, state_snapshot)
		and not route.apply_full_snapshot(wrong_contract, state_snapshot)
		and route.export_state_snapshot() == state_before,
		"缺失或不匹配的运行契约哈希必须零副作用拒绝。"
	)


func _audit_player_and_camera(
	route: TestRogueRouteP3,
	local_player: Player,
	camera: Camera2D
) -> void:
	_expect(
		local_player.get_character_id() == PlayerCharacterRegistry.TANGO_ID,
		"P3 必须使用 RunState 中选定的角色。"
	)
	_expect(
		local_player.world_movement_mode
		and local_player.are_combat_actions_locked(),
		"P3 角色必须进入只移动、无战斗模式。"
	)
	_expect(
		not local_player.health_bar.visible
		and not local_player.skill1_charge_bar.visible,
		"路线移动模式必须隐藏战斗 HUD。"
	)
	_expect(
		local_player.texture_filter == CanvasItem.TEXTURE_FILTER_NEAREST,
		"只有低像素玩家本体必须显式保持 NEAREST 过滤。"
	)
	_expect(
		camera != null and camera.get_parent() == local_player,
		"Camera2D 必须挂到本地角色并跟随移动。"
	)

	var state_before := route.export_state_snapshot()
	local_player.global_position += Vector2(24.0, 0.0)
	await physics_frame
	var state_after_walk := route.export_state_snapshot()
	_expect_state_unchanged(
		state_before,
		state_after_walk,
		"自由行走不能消耗 AP 或修改共享路线 revision。"
	)
	if camera == null:
		return
	var camera_before_drag := camera.position
	route.call(&"_apply_camera_drag", Vector2(-160.0, -80.0))
	await process_frame
	_expect(
		not camera.position.is_equal_approx(camera_before_drag),
		"拖动地图必须改变 Camera2D 的局部偏移。"
	)
	var state_after_drag := route.export_state_snapshot()
	_expect_state_unchanged(
		state_before,
		state_after_drag,
		"拖动镜头不能消耗 AP 或修改共享路线 revision。"
	)

	var runtime := route.get("_runtime_state") as RogueRouteRuntimeState
	var board := route.get_node_or_null("World/RouteBoard") as RogueRouteBoard
	var graph: RogueRouteGraph = board.graph if board != null else null
	var target_node_id := -1
	if runtime != null and graph != null:
		var neighbors := graph.get_neighbors(runtime.current_node_id)
		if not neighbors.is_empty():
			target_node_id = int(neighbors[0])
	if board != null and target_node_id >= 0:
		local_player.global_position = board.get_node_global_position(target_node_id)
		local_player.velocity = Vector2.ZERO
		board.update_local_player_global_position(local_player.global_position)
	await physics_frame
	await process_frame
	_expect(
		board != null
		and target_node_id >= 0
		and board.is_node_in_player_range(target_node_id),
		"确认移动回归夹具必须先让玩家自由走入目标节点范围。"
	)
	route.call(&"_apply_camera_drag", Vector2(-96.0, -48.0))
	await process_frame
	var dragged_camera_position := camera.position
	var player_position_before_route_move := local_player.global_position
	var camera_global_before_route_move := camera.global_position
	var screen_center_before_route_move := camera.get_screen_center_position()
	var state_before_route_move := route.export_state_snapshot()
	route.call(&"_on_route_board_node_pressed", target_node_id)
	_expect(
		runtime != null
		and target_node_id >= 0
		and int(route.get("_pending_node_id")) == target_node_id,
		"确认移动回归夹具必须通过真实节点点击创建待确认目标。"
	)
	route.call(&"_on_move_confirmation_confirmed")
	await physics_frame
	await process_frame
	var state_after_route_move := route.export_state_snapshot()
	_expect(
		local_player.global_position.is_equal_approx(
			player_position_before_route_move
		)
		and camera.position.is_equal_approx(dragged_camera_position)
		and camera.global_position.is_equal_approx(
			camera_global_before_route_move
		)
		and camera.get_screen_center_position().is_equal_approx(
			screen_center_before_route_move
		),
		"确认路线只能更新逻辑节点与行动力，不得传送玩家或移动镜头。"
	)
	_expect(
		state_after_route_move.get("revision", -1)
		== int(state_before_route_move.get("revision", -1)) + 1
		and state_after_route_move.get("action_points", -1)
		== int(state_before_route_move.get("action_points", -1))
		- route.generation_config.move_action_cost,
		"合法路线移动仍必须精确推进 revision 并扣除行动力。"
	)
	# 节点可能恰好是神奇遭遇；该流程有独立联机/转场测试。这里立即重置
	# 遭遇表现层，继续验证纯路线的定位按钮与 Home 契约。
	if route.is_encounter_active():
		route.call("_reset_encounter_runtime", true)

	route.call(&"_on_recenter_button_pressed")
	await process_frame
	var recentered_camera_position := camera.position
	_expect(
		not recentered_camera_position.is_equal_approx(
			dragged_camera_position
		),
		"定位角色必须将 Camera2D 复位到距离玩家最近的合法镜头中心。"
	)
	var state_after_button_recenter := route.export_state_snapshot()
	_expect_state_unchanged(
		state_after_route_move,
		state_after_button_recenter,
		"定位角色复位镜头不能额外消耗 AP 或修改 revision。"
	)

	route.call(&"_apply_camera_drag", Vector2(-160.0, -80.0))
	await process_frame
	_expect(
		not camera.position.is_equal_approx(recentered_camera_position),
		"Home 回归前必须能再次建立合法镜头偏移。"
	)
	var home_event := InputEventKey.new()
	home_event.pressed = true
	home_event.keycode = KEY_HOME
	route.call(&"_unhandled_input", home_event)
	await process_frame
	_expect(
		camera.position.is_equal_approx(recentered_camera_position),
		"Home 必须与定位按钮一致，复位到最近的合法镜头中心。"
	)
	_expect_state_unchanged(
		state_after_route_move,
		route.export_state_snapshot(),
		"Home 复位镜头不能额外消耗 AP 或修改 revision。"
	)
	var player_position_before_regeneration := local_player.global_position
	var camera_local_before_regeneration := camera.position
	var camera_global_before_regeneration := camera.global_position
	var camera_center_before_regeneration := camera.get_screen_center_position()
	var regenerated := route.start_authoritative_session(20260802, false)
	await physics_frame
	await process_frame
	_expect(
		regenerated
		and local_player.global_position.is_equal_approx(
			player_position_before_regeneration
		)
		and camera.position.is_equal_approx(camera_local_before_regeneration)
		and camera.global_position.is_equal_approx(
			camera_global_before_regeneration
		)
		and camera.get_screen_center_position().is_equal_approx(
			camera_center_before_regeneration
		),
		"重新生成路线只能替换逻辑地图，不得传送玩家或移动镜头。"
	)


func _expect_state_unchanged(
	before: Dictionary,
	after: Dictionary,
	message: String
) -> void:
	_expect(
		before.has("revision")
		and after.has("revision")
		and after.get("action_points") == before.get("action_points")
		and after.get("revision") == before.get("revision"),
		message
	)


func _audit_hud(route: TestRogueRouteP3) -> void:
	var hud := route.get_node_or_null("HUD") as CanvasLayer
	var top_bar := route.get_node_or_null("HUD/Root/TopBar") as PanelContainer
	var bottom_bar := route.get_node_or_null("HUD/Root/BottomBar") as PanelContainer
	var old_right_panel := route.get_node_or_null("HUD/Root/RightPanel")
	_expect(hud != null, "P3 信息层必须位于独立 CanvasLayer HUD。")
	_expect(top_bar != null, "P3 HUD 必须在顶部布置 TopBar。")
	_expect(bottom_bar != null, "P3 HUD 必须在底部布置 BottomBar。")
	_expect(old_right_panel == null, "新版 HUD 不得保留挤占地图的 RightPanel。")
	_expect(
		top_bar != null and top_bar.mouse_filter == Control.MOUSE_FILTER_STOP,
		"顶部 HUD 必须拦截鼠标，避免误触下方地图。"
	)
	_expect(
		bottom_bar != null and bottom_bar.mouse_filter == Control.MOUSE_FILTER_STOP,
		"底部 HUD 必须拦截鼠标，避免误触下方地图。"
	)
	var ap_icon := route.get_node_or_null(
		"HUD/Root/TopBar/TopLayout/TopStats/ApIcon"
	) as TextureRect
	_expect(
		ap_icon != null
		and ap_icon.texture_filter == CanvasItem.TEXTURE_FILTER_LINEAR,
		"HUD 图标必须使用 LINEAR 过滤。"
	)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("ROGUE_ROUTE_WORLD_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)
