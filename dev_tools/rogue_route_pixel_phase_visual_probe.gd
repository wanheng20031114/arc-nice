extends SceneTree

## 可选实机路线像素相位探针（不要加 --headless）。
##
## 固定 720p 基准，在完成入场揭示后通过 RogueRouteGame 的正式鼠标拖拽
## 输入入口逐帧移动。每一帧都等待 RenderingServer.frame_post_draw，再记录
## 最终物理 transform、相机状态、一个静态节点 ROI 与 current-adjacent 静态
## 连线 ROI。该工具不替代 headless smoke；它提供 GPU/DisplayServer 相关的
## 截图与 JSON 证据，供 shimmer 回归人工/离线比较。

const ROUTE_SCENE := preload(
	"res://scene/game_modes/rogue/route/rogue_route_game.tscn"
)
const PROBE_SIZE := Vector2i(1280, 720)
const CONTENT_SCALE_SIZE := Vector2i(1152, 648)
const EXPECTED_VISIBLE_WORLD_SIZE := Vector2(640.0, 360.0)
const FIXED_SEED := 1
const MOTION_FRAME_COUNT := 18
const PLAYER_MOTION_FRAME_COUNT := 24
const NODE_ROI_SIZE := Vector2i(96, 96)
const RAIL_ROI_SIZE := Vector2i(128, 64)
const EPSILON := 0.001
const OUTPUT_DIRECTORY := "user://rogue_route_pixel_phase_probe"
const REPORT_PATH := OUTPUT_DIRECTORY + "/phase_report.json"

var failures: PackedStringArray = []
var frame_records: Array[Dictionary] = []


func _initialize() -> void:
	call_deferred(&"_run")


func _run() -> void:
	if DisplayServer.get_name().to_lower() == "headless":
		push_error(
			"ROGUE_ROUTE_PIXEL_PHASE_VISUAL_PROBE 需要真实显示 renderer，请移除 --headless。"
		)
		quit(2)
		return

	root.content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
	root.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_EXPAND
	root.content_scale_size = CONTENT_SCALE_SIZE
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	DisplayServer.window_set_size(PROBE_SIZE)
	root.size = PROBE_SIZE
	await process_frame

	var route := ROUTE_SCENE.instantiate() as RogueRouteGame
	_expect(route != null, "像素相位探针必须能实例化 RogueRouteGame。")
	if route == null:
		_finish()
		return
	route.initial_generation_seed = FIXED_SEED
	root.add_child(route)
	current_scene = route
	for _frame_index in range(12):
		await process_frame
	if not route.is_route_ready():
		failures.append("固定 seed 路线等待后仍未就绪。")
		await _teardown_route(route)
		_finish()
		return

	var world := route.world as RogueRouteWorld
	var board := route.route_board as RogueRouteBoard
	_expect(world != null and board != null, "探针必须取得路线 World 与 Board。")
	if world == null or board == null:
		await _teardown_route(route)
		_finish()
		return
	board.complete_entry_reveal()
	await process_frame
	route.map_camera.make_current()
	route.map_camera.force_update_scroll()
	world.refresh_integer_route_scale()
	world.apply_route_canvas_pixel_snap()
	await RenderingServer.frame_post_draw
	var visible_world_size := (
		route.get_viewport_rect().size / route.map_camera.zoom
	)
	_expect(
		world.get_integer_pixel_scale() == 2
		and visible_world_size.distance_to(EXPECTED_VISIBLE_WORLD_SIZE) <= EPSILON,
		"720p 实机探针必须使用 K2 与标准同构图 640×360，实际 K%d/FOV%s。"
		% [world.get_integer_pixel_scale(), visible_world_size]
	)

	var current_node_id := board.current_node_id
	var neighbor_node_id := _select_neighbor(board, current_node_id)
	_expect(
		current_node_id >= 0 and neighbor_node_id >= 0,
		"固定路线必须有 current-adjacent 节点用于静态 ROI。"
	)
	if current_node_id < 0 or neighbor_node_id < 0:
		await _teardown_route(route)
		_finish()
		return

	var output_absolute := ProjectSettings.globalize_path(OUTPUT_DIRECTORY)
	var make_error := DirAccess.make_dir_recursive_absolute(output_absolute)
	_expect(
		make_error in [OK, ERR_ALREADY_EXISTS],
		"无法创建像素相位探针输出目录：%s。" % error_string(make_error)
	)

	var drag_delta := _choose_drag_delta(route, board)
	var initial_camera_position := route.map_camera.position
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	route.call(&"_unhandled_input", press)

	await _capture_frame(route, world, board, neighbor_node_id, 0, &"drag")
	for frame_index in range(1, MOTION_FRAME_COUNT + 1):
		var motion := InputEventMouseMotion.new()
		motion.relative = drag_delta
		motion.button_mask = MOUSE_BUTTON_MASK_LEFT
		route.call(&"_unhandled_input", motion)
		# process_frame 后 World 的 late _process 会对 Camera2D 本帧最终提交的
		# canvas_transform 做物理像素量化；随后再等实际 draw 完成才读回。
		await process_frame
		await RenderingServer.frame_post_draw
		await _capture_frame(
			route,
			world,
			board,
			neighbor_node_id,
			frame_index,
			&"drag"
		)

	var release := InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_LEFT
	release.pressed = false
	route.call(&"_unhandled_input", release)
	_expect(
		not route.map_camera.position.is_equal_approx(initial_camera_position),
		"逐帧正式鼠标拖拽必须实际改变路线 Camera2D 偏移。"
	)

	# 原问题发生在玩家移动/Camera2D 物理插值跟随，而非鼠标拖拽。
	# 确认正式路线输入已解锁，再通过 InputMap 持续按住 move_right；每帧
	# 依旧在 post_draw 后采样，覆盖 physics→interpolation→camera→late snap。
	_expect(
		not bool(route.call(&"_is_route_input_locked"))
		and not route.player.controls_locked,
		"玩家移动 phase 开始前路线输入必须已解锁。"
	)
	route.call(&"_recenter_camera_on_player")
	await process_frame
	await RenderingServer.frame_post_draw
	var player_position_before := route.player.global_position
	var board_center_x := board.get_world_bounds().get_center().x
	var player_move_action: StringName = (
		&"move_left"
		if world.get_rendered_camera_center().x > board_center_x
		else &"move_right"
	)
	Input.action_press(player_move_action)
	for player_frame_index in range(PLAYER_MOTION_FRAME_COUNT):
		await process_frame
		await RenderingServer.frame_post_draw
		await _capture_frame(
			route,
			world,
			board,
			neighbor_node_id,
			player_frame_index,
			&"player_move"
		)
	Input.action_release(player_move_action)
	await physics_frame
	_expect(
		absf(route.player.global_position.x - player_position_before.x) > EPSILON,
		"%s phase 必须实际移动玩家世界位置。" % player_move_action
	)
	var player_phase_origins: Dictionary[String, bool] = {}
	for record: Dictionary in frame_records:
		if StringName(record.get("motion_kind", &"")) != &"player_move":
			continue
		var origin_variant: Variant = record.get("physical_origin", [])
		if typeof(origin_variant) != TYPE_ARRAY:
			continue
		var origin := origin_variant as Array
		if origin.size() == 2:
			player_phase_origins["%.3f,%.3f" % [
				float(origin[0]),
				float(origin[1]),
			]] = true
	_expect(
		player_phase_origins.size() >= 2,
		"玩家移动 phase 的最终 physical origin 必须实际跨越至少两个整数像素。"
	)

	var report := {
		"schema": 1,
		"seed": FIXED_SEED,
		"display_server": DisplayServer.get_name(),
		"rendering_method": RenderingServer.get_current_rendering_method(),
		"rendering_device": RenderingServer.get_video_adapter_name(),
		"window_size": [root.size.x, root.size.y],
		"content_scale_size": [
			root.content_scale_size.x,
			root.content_scale_size.y,
		],
		"integer_pixel_scale": world.get_integer_pixel_scale(),
		"visible_world_size": [visible_world_size.x, visible_world_size.y],
		"safe_visible_world_size": [
			EXPECTED_VISIBLE_WORLD_SIZE.x,
			EXPECTED_VISIBLE_WORLD_SIZE.y,
		],
		"drag_delta_per_frame": [drag_delta.x, drag_delta.y],
		"player_move_action": player_move_action,
		"current_node_id": current_node_id,
		"static_neighbor_node_id": neighbor_node_id,
		"frames": frame_records,
		"failures": failures,
	}
	var report_absolute := ProjectSettings.globalize_path(REPORT_PATH)
	var report_file := FileAccess.open(report_absolute, FileAccess.WRITE)
	_expect(report_file != null, "无法写入探针报告：%s。" % report_absolute)
	if report_file != null:
		report_file.store_string(JSON.stringify(report, "\t"))
		report_file.close()

	await _teardown_route(route)
	if failures.is_empty():
		print(
			"ROGUE_ROUTE_PIXEL_PHASE_VISUAL_PROBE_OK frames=%d report=%s"
			% [frame_records.size(), report_absolute]
		)
		quit(0)
		return
	_finish()


func _capture_frame(
	route: RogueRouteGame,
	world: RogueRouteWorld,
	board: RogueRouteBoard,
	static_node_id: int,
	frame_index: int,
	motion_kind: StringName
) -> void:
	var viewport := route.get_viewport()
	var final_board_transform := (
		viewport.get_screen_transform()
		* board.get_global_transform_with_canvas()
	)
	var expected_scale := float(world.get_integer_pixel_scale())
	var origin_is_integer := (
		_is_integer(final_board_transform.origin.x)
		and _is_integer(final_board_transform.origin.y)
	)
	var basis_is_integer := (
		absf(final_board_transform.x.length() - expected_scale) <= EPSILON
		and absf(final_board_transform.y.length() - expected_scale) <= EPSILON
		and absf(final_board_transform.x.dot(final_board_transform.y)) <= EPSILON
	)
	_expect(
		origin_is_integer,
		"%s frame %d 最终物理 origin 不是整数：%s。"
		% [motion_kind, frame_index, final_board_transform.origin]
	)
	_expect(
		basis_is_integer,
		"%s frame %d 最终物理 basis 不等于无剪切整数 K%d。"
		% [motion_kind, frame_index, int(expected_scale)]
	)

	var current_position := board.get_node_position(board.current_node_id)
	var static_node_position := board.get_node_position(static_node_id)
	var rail_midpoint := (current_position + static_node_position) * 0.5
	var node_screen_position := final_board_transform * static_node_position
	var rail_screen_position := final_board_transform * rail_midpoint
	var frame_image := viewport.get_texture().get_image()
	_expect(
		frame_image != null and not frame_image.is_empty(),
		"%s frame %d 无法从真实 Viewport 读回图像。"
		% [motion_kind, frame_index]
	)
	if frame_image == null or frame_image.is_empty():
		return
	if bool(ProjectSettings.get_setting("rendering/viewport/hdr_2d", false)):
		if frame_image.get_format() not in [Image.FORMAT_RGB8, Image.FORMAT_RGBA8]:
			frame_image.convert(Image.FORMAT_RGBA8)
		frame_image.linear_to_srgb()

	var node_roi := _crop_centered(frame_image, node_screen_position, NODE_ROI_SIZE)
	var rail_roi := _crop_centered(frame_image, rail_screen_position, RAIL_ROI_SIZE)
	_expect(
		node_roi != null and rail_roi != null,
		"%s frame %d 静态 node/rail ROI 必须完整位于截图内。"
		% [motion_kind, frame_index]
	)
	var frame_label := "%s_%03d" % [motion_kind, frame_index]
	var full_path := ""
	var motion_last_frame := (
		PLAYER_MOTION_FRAME_COUNT - 1
		if motion_kind == &"player_move"
		else MOTION_FRAME_COUNT
	)
	if frame_index in [0, motion_last_frame / 2, motion_last_frame]:
		full_path = OUTPUT_DIRECTORY + "/full_%s.png" % frame_label
		_expect(
			frame_image.save_png(ProjectSettings.globalize_path(full_path)) == OK,
			"%s frame %d 全帧截图保存失败。"
			% [motion_kind, frame_index]
		)
	var node_path := OUTPUT_DIRECTORY + "/node_%s.png" % frame_label
	var rail_path := OUTPUT_DIRECTORY + "/rail_%s.png" % frame_label
	var node_hash := ""
	var rail_hash := ""
	if node_roi != null:
		_expect(
			node_roi.save_png(ProjectSettings.globalize_path(node_path)) == OK,
			"%s frame %d node ROI 保存失败。"
			% [motion_kind, frame_index]
		)
		node_hash = node_roi.get_data().hex_encode().sha256_text()
	if rail_roi != null:
		_expect(
			rail_roi.save_png(ProjectSettings.globalize_path(rail_path)) == OK,
			"%s frame %d rail ROI 保存失败。"
			% [motion_kind, frame_index]
		)
		rail_hash = rail_roi.get_data().hex_encode().sha256_text()

	frame_records.append({
		"frame": frame_index,
		"motion_kind": motion_kind,
		"physical_origin": [
			final_board_transform.origin.x,
			final_board_transform.origin.y,
		],
		"physical_basis_x": [
			final_board_transform.x.x,
			final_board_transform.x.y,
		],
		"physical_basis_y": [
			final_board_transform.y.x,
			final_board_transform.y.y,
		],
		"origin_integer": origin_is_integer,
		"basis_integer": basis_is_integer,
		"camera_position": [
			route.map_camera.position.x,
			route.map_camera.position.y,
		],
		"player_world_position": [
			route.player.global_position.x,
			route.player.global_position.y,
		],
		"rendered_camera_center": [
			world.get_rendered_camera_center().x,
			world.get_rendered_camera_center().y,
		],
		"node_screen_position": [node_screen_position.x, node_screen_position.y],
		"rail_screen_position": [rail_screen_position.x, rail_screen_position.y],
		"node_roi_path": node_path,
		"node_roi_sha256": node_hash,
		"rail_roi_path": rail_path,
		"rail_roi_sha256": rail_hash,
		"full_frame_path": full_path,
	})


func _select_neighbor(board: RogueRouteBoard, current_node_id: int) -> int:
	if board.graph == null or not board.graph.is_valid_node_id(current_node_id):
		return -1
	var neighbors := board.graph.get_neighbors(current_node_id)
	return int(neighbors[0]) if not neighbors.is_empty() else -1


func _choose_drag_delta(
	route: RogueRouteGame,
	board: RogueRouteBoard
) -> Vector2:
	var bounds := board.get_world_bounds()
	var camera_center := route.player.global_position + route.map_camera.position
	var half_view := route.get_viewport_rect().size / route.map_camera.zoom * 0.5
	var left_room := camera_center.x - (bounds.position.x + half_view.x)
	var right_room := (bounds.end.x - half_view.x) - camera_center.x
	# apply_camera_drag 会做 camera.position -= screen_delta / zoom。
	return Vector2(-1.0, 0.0) if right_room >= left_room else Vector2(1.0, 0.0)


func _crop_centered(
	source: Image,
	center: Vector2,
	size: Vector2i
) -> Image:
	var top_left := Vector2i(roundi(center.x), roundi(center.y)) - size / 2
	var rect := Rect2i(top_left, size)
	if not Rect2i(Vector2i.ZERO, source.get_size()).encloses(rect):
		return null
	return source.get_region(rect)


func _teardown_route(route: RogueRouteGame) -> void:
	current_scene = null
	if route != null and is_instance_valid(route):
		root.remove_child(route)
		route.free()
	await process_frame


func _is_integer(value: float) -> bool:
	return absf(value - round(value)) <= EPSILON


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	for failure in failures:
		push_error(failure)
	quit(1)
