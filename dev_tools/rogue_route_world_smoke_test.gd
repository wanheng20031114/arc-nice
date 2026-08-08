extends SceneTree

const ROUTE_SCENE := preload("res://scene/game_modes/rogue/route/rogue_route_game.tscn")
const EXPECTED_WORLD_SIZE := Vector2(1376.0, 864.0)
const EXPECTED_CELL_SPACING := Vector2(112.0, 80.0)
const EXPECTED_BOARD_MARGIN := Vector2(128.0, 112.0)
const EXPECTED_BACKGROUND_SIZE := Vector2(2304.0, 1296.0)
const EXPECTED_CAMERA_ZOOM := 2.0
const MIN_VISIBLE_COLUMNS := 5
const MIN_VISIBLE_ROWS := 3
const EXPECTED_NODE_DISPLAY_SIZE := Vector2(32.0, 32.0)
const EXPECTED_NODE_DISPLAY_OFFSET := Vector2(16.0, 16.0)
const ROUTE_CONTRACT_FIELD := "runtime_contract_hash"

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var render_viewport := root.get_viewport()
	var original_physics_interpolation := physics_interpolation
	var original_transform_pixel_snap := render_viewport.snap_2d_transforms_to_pixel
	var original_vertex_pixel_snap := render_viewport.snap_2d_vertices_to_pixel
	var run_state := root.get_node_or_null("RunState") as RunStateStore
	if run_state != null:
		run_state.begin_new_run(PlayerCharacterRegistry.TANGO_ID, false)
	var route := ROUTE_SCENE.instantiate() as RogueRouteGame
	_expect(route != null, "P3 世界场景必须能够实例化。")
	if route == null:
		_finish()
		return
	# 使用与旧路线覆盖相反的哨兵值，确保局部像素画问题不会再次通过
	# 篡改共享 Viewport 解决，同时覆盖场景拥有的物理插值生命周期。
	physics_interpolation = false
	render_viewport.snap_2d_transforms_to_pixel = false
	render_viewport.snap_2d_vertices_to_pixel = true
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
	_expect(
		physics_interpolation,
		"路线运行期必须启用原生物理插值，平滑玩家与跟随镜头的渲染位置。"
	)
	_expect(
		not render_viewport.snap_2d_transforms_to_pixel,
		"路线运行期不得篡改共享 Viewport 的 2D Transform 像素吸附。"
	)
	_expect(
		render_viewport.snap_2d_vertices_to_pixel,
		"路线运行期不得篡改共享 Viewport 的 2D 顶点像素吸附。"
	)
	_expect(
		route.physics_interpolation_mode == Node.PHYSICS_INTERPOLATION_MODE_OFF,
		"路线静态世界与视差背景必须保持在物理插值之外。"
	)
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
	_expect(
		not physics_interpolation,
		"离开路线场景后必须恢复进入前的 SceneTree 物理插值状态。"
	)
	_expect(
		not render_viewport.snap_2d_transforms_to_pixel,
		"路线运行与退出全过程不得改变共享 Transform 像素吸附。"
	)
	_expect(
		render_viewport.snap_2d_vertices_to_pixel,
		"路线运行与退出全过程不得改变共享顶点像素吸附。"
	)
	physics_interpolation = original_physics_interpolation
	render_viewport.snap_2d_transforms_to_pixel = original_transform_pixel_snap
	render_viewport.snap_2d_vertices_to_pixel = original_vertex_pixel_snap
	_finish()


func _audit_backdrop(route: RogueRouteGame) -> void:
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
		_expect(
			backdrop.repeat_times >= 2,
			"背景视差层必须保留至少两圈原生重复，覆盖不同窗口比例下的镜头边缘。"
		)
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
			ruins_background.texture_filter == CanvasItem.TEXTURE_FILTER_NEAREST,
			"像素地下遗址背景必须使用 NEAREST 过滤。"
		)
		_expect(
			ruins_background.scale.is_equal_approx(Vector2(0.5, 0.5)),
			"2304×1296 地下遗址母图必须以 0.5 倍覆盖路线世界。"
		)
		_expect(
			backdrop != null
			and backdrop.repeat_size.is_equal_approx(
				ruins_background.texture.get_size() * ruins_background.scale.abs()
			),
			"地下遗址背景的重复尺寸必须由原图显示尺寸派生，避免固定比例窗口露底。"
		)
	var title := route.get_node_or_null("HUD/Root/TopBar/TopLayout/TitleBlock/Title") as Label
	_expect(title != null and title.text == "浅层矿洞", "路线顶部必须显示当前层名“浅层矿洞”。")
	var beacon_environment_node := route.get_node_or_null(
		"RouteBeaconGlowEnvironment"
	) as WorldEnvironment
	var beacon_environment := (
		beacon_environment_node.environment
		if beacon_environment_node != null
		else null
	)
	_expect(
		bool(ProjectSettings.get_setting("rendering/viewport/hdr_2d"))
		and beacon_environment != null
		and beacon_environment.background_mode == Environment.BG_CANVAS
		and beacon_environment.background_canvas_max_layer == 0
		and beacon_environment.glow_enabled
		and beacon_environment.glow_intensity <= 0.25
		and is_zero_approx(beacon_environment.glow_bloom),
		"路线 HDR 信标必须只处理世界层，并以低强度、无全局 Bloom 的方式保留像素外溢。"
	)


func _audit_board(
	route: RogueRouteGame,
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
		"11×9 路线世界必须由统一度量计算为 1376×864。"
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
		board.texture_filter == CanvasItem.TEXTURE_FILTER_NEAREST,
		"路线节点与界面素材必须使用 NEAREST 过滤。"
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
		var offset := board.get_node_position(node_id) - base_position
		_expect(
			offset.is_zero_approx(),
			"节点 #%d 必须精确落在方正网格上，不应存在视觉抖动。" % node_id
		)

	var connections := board.get_node_or_null("Connections") as RogueRouteConnections
	var cell_layer := board.get_node_or_null("CellLayer") as Control
	_expect(connections != null, "路线板必须包含独立连接线层。")
	_expect(cell_layer != null, "路线板必须包含独立节点层。")
	if connections != null:
		var rail_material := connections.material as ShaderMaterial
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
			"连接层必须单 Canvas 自绘独立金属轨道，不能生成 Line2D 子节点。"
		)
		_expect(
			connections.texture_filter == CanvasItem.TEXTURE_FILTER_NEAREST,
			"金属轨道必须使用 NEAREST 过滤。"
		)
		_expect(
			rail_material != null
			and rail_material.shader != null
			and is_equal_approx(
				float(rail_material.get_shader_parameter(&"wave_cycle_seconds")),
				4.8
			)
			and is_equal_approx(
				float(rail_material.get_shader_parameter(&"wave_amplitude_pixels")),
				1.0
			)
			and is_equal_approx(
				float(rail_material.get_shader_parameter(&"source_to_world_scale")),
				0.25
			),
			"连接线必须由着色器驱动慢速、带停顿的 1 像素分段起伏，而不是扫光或逐帧重绘。"
		)
	_audit_empty_cell(board, graph)
	_audit_event_cell_scale(board, graph, camera)
	_audit_current_node_glow(board)
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
	var empty_ring := empty_cell.get_node_or_null("NodeButton/EmptyRing") as TextureRect
	_expect(
		button != null
		and button.position.is_equal_approx(EXPECTED_NODE_DISPLAY_OFFSET)
		and button.size.is_equal_approx(EXPECTED_NODE_DISPLAY_SIZE),
		"2× 镜头下空节点必须使用居中的 32×32 世界像素圆环命中区。"
	)
	_expect(
		empty_ring != null
		and empty_ring.size.is_equal_approx(EXPECTED_NODE_DISPLAY_SIZE)
		and empty_ring.texture_filter == CanvasItem.TEXTURE_FILTER_NEAREST,
		"空节点必须使用与事件节点同构的 32×32 世界像素深铁圆环。"
	)


func _audit_event_cell_scale(
	board: RogueRouteBoard,
	graph: RogueRouteGraph,
	camera: Camera2D
) -> void:
	var event_cell: RogueRouteCell = null
	var event_node_id := -1
	for node_id in range(graph.get_node_count()):
		if graph.get_node_type(node_id) != RogueRouteGraph.NodeType.EMPTY:
			event_cell = board.get_cell(node_id)
			event_node_id = node_id
			break
	_expect(event_cell != null, "固定 seed 必须生成至少一个事件节点。")
	if event_cell == null:
		return
	var node_art := event_cell.get_node_or_null("NodeButton/NodeArt") as TextureRect
	var active_ring := event_cell.get_node_or_null("ActiveRing") as TextureRect
	var type_config := board.generation_config.get_type_config(
		graph.get_node_type(event_node_id)
	)
	_expect(
		node_art != null
		and node_art.texture != null
		and type_config != null
		and node_art.texture == type_config.icon
		and node_art.size.is_equal_approx(EXPECTED_NODE_DISPLAY_SIZE)
		and node_art.texture_filter == CanvasItem.TEXTURE_FILTER_NEAREST,
		"事件节点必须直接使用类型配置中的唯一图标真源，并以 32×32 世界像素显示。"
	)
	_expect(
		active_ring != null
		and active_ring.position.is_equal_approx(EXPECTED_NODE_DISPLAY_OFFSET)
		and active_ring.size.is_equal_approx(EXPECTED_NODE_DISPLAY_SIZE)
		and event_cell.get_node_or_null("NameLabel") == null,
		"事件节点必须以独立激活环表示状态，且不得渲染下方文字。"
	)


func _audit_current_node_glow(board: RogueRouteBoard) -> void:
	var current_cell := board.get_cell(board.current_node_id)
	var current_glow := (
		current_cell.get_node_or_null("CurrentGlow") as ColorRect
		if current_cell != null
		else null
	)
	_expect(
		current_cell != null
		and current_glow != null
		and current_glow.visible
		and current_glow.position.is_equal_approx(Vector2(10.0, 10.0))
		and current_glow.size.is_equal_approx(Vector2(44.0, 44.0))
		and current_glow.material is ShaderMaterial
		and float((current_glow.material as ShaderMaterial).get_shader_parameter(
			&"hdr_energy"
		)) > 1.0,
		"玩家所在路线节点必须使用紧凑的 HDR 像素外缘信标，而非大面积雾状光圈。"
	)


func _audit_density_budget(
	route: RogueRouteGame,
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
	route: RogueRouteGame,
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


func _audit_snapshot_contract(route: RogueRouteGame) -> void:
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
	route: RogueRouteGame,
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
	_expect(
		local_player.physics_interpolation_mode
		== Node.PHYSICS_INTERPOLATION_MODE_ON,
		"本地玩家必须使用原生物理插值。"
	)
	_expect(
		camera != null
		and camera.physics_interpolation_mode
		== Node.PHYSICS_INTERPOLATION_MODE_INHERIT
		and camera.process_callback == Camera2D.CAMERA2D_PROCESS_PHYSICS,
		"跟随 Camera2D 必须继承玩家插值并在物理回调中采样。"
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
		for neighbor_id in neighbors:
			var node_type := graph.get_node_type(int(neighbor_id))
			if node_type not in [
				RogueRouteGraph.NodeType.NORMAL_COMBAT,
				RogueRouteGraph.NodeType.MAGICAL_ENCOUNTER,
			]:
				target_node_id = int(neighbor_id)
				break
	if board != null and target_node_id >= 0:
		local_player.global_position = board.get_node_global_position(
			runtime.current_node_id
		)
		local_player.velocity = Vector2.ZERO
	await physics_frame
	await process_frame
	_expect(
		board != null
		and target_node_id >= 0
		and local_player.global_position.distance_to(
			board.get_node_global_position(target_node_id)
		) > 28.0
		and board.can_interact_with_node(target_node_id),
		"玩家停留在远离目标的位置时，合法相邻节点仍必须允许点击。"
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


func _audit_hud(route: RogueRouteGame) -> void:
	var hud := route.get_node_or_null("HUD") as CanvasLayer
	var top_bar := route.get_node_or_null("HUD/Root/TopBar") as RogueRouteTopBar
	var bottom_bar := route.get_node_or_null("HUD/Root/BottomBar") as Control
	var old_right_panel := route.get_node_or_null("HUD/Root/RightPanel")
	var obsolete_return_button := route.get_node_or_null(
		"HUD/Root/TopBar/TopLayout/ReturnButton"
	)
	_expect(hud != null, "P3 信息层必须位于独立 CanvasLayer HUD。")
	_expect(top_bar != null, "P3 HUD 必须实例化独立 RogueRouteTopBar 组件。")
	_expect(bottom_bar != null, "P3 HUD 必须在底部布置 BottomBar。")
	_expect(old_right_panel == null, "新版 HUD 不得保留挤占地图的 RightPanel。")
	_expect(
		obsolete_return_button == null,
		"路线顶部 HUD 不得保留返回按钮或占位节点。"
	)
	_expect(
		top_bar != null and top_bar.mouse_filter == Control.MOUSE_FILTER_STOP,
		"顶部 HUD 必须拦截鼠标，避免误触下方地图。"
	)
	var top_panel_style := (
		top_bar.get_theme_stylebox(&"panel")
		if top_bar != null
		else null
	)
	var top_backdrop := route.get_node_or_null(
		"HUD/Root/TopBar/BackdropFade"
	) as TextureRect
	var top_gradient_texture := (
		top_backdrop.texture as GradientTexture2D
		if top_backdrop != null
		else null
	)
	var top_gradient := (
		top_gradient_texture.gradient
		if top_gradient_texture != null
		else null
	)
	var top_gradient_colors := (
		top_gradient.colors
		if top_gradient != null
		else PackedColorArray()
	)
	_expect(
		top_panel_style is StyleBoxEmpty
		and top_backdrop != null
		and top_gradient_colors.size() >= 3
		and top_gradient_colors[0].a >= 0.92
		and top_gradient_colors[0].a <= 0.97
		and top_gradient_colors[1].a >= 0.8
		and top_gradient_colors[0].a > top_gradient_colors[1].a
		and top_gradient_colors[1].a > top_gradient_colors[-1].a
		and top_gradient_colors[-1].a <= 0.01
		and top_bar.anchor_right == 1.0
		and is_zero_approx(top_bar.offset_left)
		and is_zero_approx(top_bar.offset_top)
		and is_zero_approx(top_bar.offset_right)
		and top_bar.offset_bottom >= 100.0,
		"顶部状态背景必须无边框覆盖全宽，以清晰深灰层向下渐隐。"
	)
	_expect(
		bottom_bar != null and bottom_bar.mouse_filter == Control.MOUSE_FILTER_STOP,
		"底部 HUD 必须拦截鼠标，避免误触下方地图。"
	)
	var core_icon := route.get_node_or_null(
		"HUD/Root/TopBar/TopLayout/CoreStat/CoreRow/CoreIcon"
	) as TextureRect
	var ap_icon := route.get_node_or_null(
		"HUD/Root/TopBar/TopLayout/TopStats/ActionStat/ApIcon"
	) as TextureRect
	var light_stone_icon := route.get_node_or_null(
		"HUD/Root/TopBar/TopLayout/TopStats/LightStoneStat/LightStoneIcon"
	) as TextureRect
	var xirang_icon := route.get_node_or_null(
		"HUD/Root/TopBar/TopLayout/TopStats/XirangStat/XirangIcon"
	) as TextureRect
	_expect(
		core_icon != null
		and ap_icon != null
		and light_stone_icon != null
		and xirang_icon != null
		and core_icon.texture != null
		and ap_icon.texture != null
		and light_stone_icon.texture != null
		and xirang_icon.texture != null
		and core_icon.texture_filter == CanvasItem.TEXTURE_FILTER_NEAREST
		and ap_icon.texture_filter == CanvasItem.TEXTURE_FILTER_NEAREST
		and light_stone_icon.texture_filter == CanvasItem.TEXTURE_FILTER_NEAREST
		and xirang_icon.texture_filter == CanvasItem.TEXTURE_FILTER_NEAREST
		and core_icon.stretch_mode == TextureRect.STRETCH_KEEP_CENTERED
		and ap_icon.stretch_mode == TextureRect.STRETCH_KEEP_CENTERED
		and light_stone_icon.stretch_mode == TextureRect.STRETCH_KEEP_CENTERED
		and xirang_icon.stretch_mode == TextureRect.STRETCH_KEEP_CENTERED,
		"顶部资源图标必须使用 NEAREST，并以原生像素尺寸居中显示。"
	)
	var light_stone_value := route.get_node_or_null(
		"HUD/Root/TopBar/TopLayout/TopStats/LightStoneStat/LightStoneValue"
	) as Label
	var xirang_value := route.get_node_or_null(
		"HUD/Root/TopBar/TopLayout/TopStats/XirangStat/XirangValue"
	) as Label
	route.set_shared_light_stone_amount(128)
	_expect(
		light_stone_value != null and light_stone_value.text == "128",
		"顶部全队光石显示必须可由路线会话更新。"
	)
	var inventory_strip := route.get_node_or_null(
		"HUD/Root/BottomBar/RogueRouteInventoryStrip"
	) as RogueRouteInventoryStrip
	_expect(
		inventory_strip != null
		and inventory_strip.get_node_or_null("BagButton") is Button
		and inventory_strip.get_node_or_null("Slot0") is Button
		and inventory_strip.get_node_or_null("Slot10") is Button,
		"底部 HUD 必须接入可打开背包、完整展示十一格的横向物品栏。"
	)
	if inventory_strip == null:
		return
	var last_visible_slot := inventory_strip.get_node_or_null(
		"Slot10"
	) as Button
	var previous_inventory_button := inventory_strip.get_node_or_null(
		"PreviousButton"
	) as Button
	var next_inventory_button := inventory_strip.get_node_or_null(
		"NextButton"
	) as Button
	_expect(
		RogueRouteInventoryStrip.VISIBLE_SLOT_COUNT == 11
		and inventory_strip.slot_buttons.size() == 11
		and inventory_strip.slot_frames.size() == 11
		and inventory_strip.item_icons.size() == 11
		and inventory_strip.stack_labels.size() == 11,
		"底部物品栏的节点、图标、边框与数量标签必须共同扩展到十一格。"
	)
	_expect(
		last_visible_slot != null
		and next_inventory_button != null
		and is_equal_approx(last_visible_slot.position.x, 896.0)
		and is_equal_approx(last_visible_slot.size.x, 64.0)
		and (
			last_visible_slot.position.x + last_visible_slot.size.x
			<= next_inventory_button.position.x
		),
		"第十一格必须利用右箭头左侧空间，且不得与翻页按钮重叠。"
	)
	var run_state := route.get_node_or_null("/root/RunState") as RunStateStore
	_expect(
		run_state != null and inventory_strip.inventory_owner_peer_id == 0,
		"单人路线物品栏必须绑定本地玩家的背包。"
	)
	if run_state != null:
		_expect(
			run_state.set_party_xirang_balance(0, 46),
			"测试前提：应能写入本地玩家的个人息壤余额。"
		)
		_expect(
			xirang_value != null and xirang_value.text == "46",
			"顶部个人息壤显示必须监听 RunState 的账本更新。"
		)
		_expect(
			run_state.try_add_item_count(RunStateStore.STARTING_WOOD, 5),
			"测试前提：应能向本地玩家背包放入木头。"
		)
		var first_icon := inventory_strip.get_node_or_null(
			"Slot0/ItemIcon"
		) as TextureRect
		var first_stack_count := inventory_strip.get_node_or_null(
			"Slot0/StackCount"
		) as Label
		_expect(
			first_icon != null
			and first_icon.visible
			and first_icon.texture == RunStateStore.STARTING_WOOD.icon_texture
			and first_stack_count != null
			and first_stack_count.visible
			and first_stack_count.text == "5",
			"底部物品栏必须实时显示本地玩家背包中的物品与叠放数量。"
		)
	inventory_strip.call("_on_next_button_pressed")
	_expect(
		inventory_strip.first_slot_index == 1,
		"底部物品栏的右箭头必须按槽位向后滚动。"
	)
	inventory_strip.call("_on_previous_button_pressed")
	_expect(
		inventory_strip.first_slot_index == 0,
		"底部物品栏的左箭头必须回到首个槽位。"
	)
	for _step in range(RunStateStore.INVENTORY_CAPACITY):
		inventory_strip.call("_on_next_button_pressed")
	_expect(
		inventory_strip.first_slot_index == 9
		and next_inventory_button != null
		and next_inventory_button.disabled,
		"十一格物品栏的末页必须稳定覆盖背包索引 9 到 19，且不能越界。"
	)
	inventory_strip.call("_on_next_button_pressed")
	_expect(
		inventory_strip.first_slot_index == 9,
		"物品栏到达末页后继续点击右箭头不得越过背包容量。"
	)
	for _step in range(RunStateStore.INVENTORY_CAPACITY):
		inventory_strip.call("_on_previous_button_pressed")
	_expect(
		inventory_strip.first_slot_index == 0
		and previous_inventory_button != null
		and previous_inventory_button.disabled,
		"十一格物品栏必须能够回到首格，并在起点禁用左箭头。"
	)
	inventory_strip.bag_requested.emit()
	var profile_panel := route.get_node_or_null(
		"RoguePlayerProfilePanel"
	) as RoguePlayerProfilePanel
	_expect(
		profile_panel != null and profile_panel.is_open(),
		"点击背包按钮必须打开复用的玩家背包界面。"
	)
	if profile_panel != null:
		profile_panel.close()


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
