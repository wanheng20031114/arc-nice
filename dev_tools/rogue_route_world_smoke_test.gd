extends SceneTree

const ROUTE_SCENE := preload("res://scene/test_arena/test_rogue_route_p3.tscn")
const EXPECTED_WORLD_SIZE := Vector2(3200.0, 1920.0)

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
	var player_layer := route.get_node_or_null("World/Players") as Node2D
	var local_player := route.get("player") as Player
	var camera := route.get_node_or_null("World/Players/Player/Camera2D") as Camera2D
	if camera == null:
		camera = route.find_child("Camera2D", true, false) as Camera2D
	_expect(board != null, "P3 必须使用世界空间路线板。")
	_expect(player_layer != null, "P3 必须保留独立玩家渲染层。")
	_expect(local_player != null, "P3 必须实例化所选角色。")
	_expect(camera != null, "P3 必须保留唯一 Camera2D。")
	if board != null:
		var group_marker := board.get_node_or_null("GroupMarker") as Control
		_expect(
			player_layer != null
			and board.z_index < player_layer.z_index
			and group_marker != null
			and board.z_index + group_marker.z_index < player_layer.z_index,
			"路线底图与队伍标记必须始终绘制在玩家下方。"
		)
		_expect(
			board.size.is_equal_approx(EXPECTED_WORLD_SIZE),
			"11×9 路线世界必须固定为 3200×1920，而不是压进视口。"
		)
		var graph := board.graph
		if graph != null:
			var center_id := graph.start_node_id
			var neighbors := graph.get_neighbors(center_id)
			_expect(not neighbors.is_empty(), "中心节点必须至少存在一个相邻节点。")
			if not neighbors.is_empty():
				var delta := (
					board.get_node_position(int(neighbors[0]))
					- board.get_node_position(center_id)
				)
				var is_horizontal_step := (
					absf(delta.x) >= 240.0
					and absf(delta.x) <= 272.0
					and absf(delta.y) <= 10.0
				)
				var is_vertical_step := (
					absf(delta.y) >= 182.0
					and absf(delta.y) <= 202.0
					and absf(delta.x) <= 14.0
				)
				_expect(
					is_horizontal_step or is_vertical_step,
					"相邻节点必须使用固定大间距世界坐标。"
				)
			var connections := board.get_node("Connections") as RogueRouteConnections
			_expect(
				connections.get_base_line_count() == graph.edges.size() / 2,
				"每条逻辑边必须生成一个静态纹理 Line2D。"
			)
			_expect(
				connections.get_highlighted_line_count() <= 4,
				"动态高亮路线数量必须受当前节点度数限制。"
			)
	if local_player != null:
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
			camera != null and camera.get_parent() == local_player,
			"Camera2D 必须挂到本地角色并跟随移动。"
		)
		var state_before := route.export_state_snapshot()
		local_player.global_position += Vector2(24.0, 0.0)
		await physics_frame
		var state_after := route.export_state_snapshot()
		_expect(
			state_before.has("revision")
			and state_after.has("revision")
			and state_after.get("action_points") == state_before.get("action_points")
			and state_after.get("revision") == state_before.get("revision"),
			"自由行走不能消耗 AP 或修改共享路线 revision。"
		)

	var hud := route.get_node_or_null("HUD") as CanvasLayer
	var right_panel := route.get_node_or_null("HUD/Root/RightPanel") as NinePatchRect
	_expect(hud != null, "P3 信息层必须位于独立 CanvasLayer HUD。")
	_expect(
		right_panel != null and right_panel.texture != null,
		"P3 HUD 必须使用生成的像素面板纹理。"
	)
	_expect(
		right_panel != null
		and right_panel.mouse_filter == Control.MOUSE_FILTER_STOP,
		"P3 右侧 HUD 必须拦截鼠标，避免误触面板下方的路线节点。"
	)

	current_scene = null
	root.remove_child(route)
	route.free()
	await process_frame
	_finish()


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
