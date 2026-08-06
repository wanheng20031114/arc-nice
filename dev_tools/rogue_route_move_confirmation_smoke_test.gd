extends SceneTree

const CONFIRMATION_SCENE := preload(
	"res://scene/game_modes/rogue/route/rogue_route_move_confirmation.tscn"
)
const ROUTE_SCENE := preload("res://scene/game_modes/rogue/route/rogue_route_game.tscn")
const GENERATION_CONFIG := preload(
	"res://resources/config/rogue_route/p3_generation_config.tres"
)
const RUINS_BACKGROUND := preload(
	"res://resources/texture/rogue_route/underground_ruins_background.png"
)
const EXPECTED_FRAME_PATH := (
	"res://resources/texture/rogue_route/route_move_confirmation_frame.png"
)
const MAX_SEED_SEARCH := 4096

var failures: Array[String] = []
var confirmed_count := 0
var canceled_count := 0
var return_requested_count := 0


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	root.size = Vector2i(1280, 720)
	var background := TextureRect.new()
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	background.texture = RUINS_BACKGROUND
	background.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	background.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	root.add_child(background)

	var confirmation := CONFIRMATION_SCENE.instantiate() as RogueRouteMoveConfirmation
	root.add_child(confirmation)
	await process_frame
	_expect(not confirmation.visible, "路线移动确认层初始必须隐藏。")
	_expect(confirmation.layer == 30, "确认层必须位于路线 HUD 与遭遇层之间。")

	var frame := confirmation.get_node_or_null("Root/PanelStage/Frame") as NinePatchRect
	_expect(frame != null, "确认层必须使用 NinePatchRect 承载生成框体。")
	if frame != null:
		_expect(
			frame.texture != null
			and frame.texture.resource_path == EXPECTED_FRAME_PATH,
			"确认层必须绑定专用暖棕色生成框体。"
		)
		_expect(
			frame.texture_filter == CanvasItem.TEXTURE_FILTER_NEAREST,
			"生成框体必须使用 nearest，避免边缘缩放发糊。"
		)
		_expect(
			frame.patch_margin_left >= 28
			and frame.patch_margin_top >= 28
			and frame.patch_margin_right >= 28
			and frame.patch_margin_bottom >= 28,
			"NinePatch 边距必须保护木框角部不被拉伸。"
		)

	confirmation.confirmed.connect(func() -> void: confirmed_count += 1)
	confirmation.canceled.connect(func() -> void: canceled_count += 1)
	confirmation.present("神奇遭遇", 12, 1)
	await process_frame
	_expect(confirmation.visible, "present 后确认层必须可见。")
	_expect(confirmation.destination_label.text == "神奇遭遇", "目标节点标题必须独立显示。")
	_expect(confirmation.current_ap_label.text == "12", "必须显示移动前行动力。")
	_expect(confirmation.remaining_ap_label.text == "11", "必须显示移动后行动力。")
	_expect(confirmation.cost_label.text == "消耗 1 行动力", "必须明确显示本次消耗。")
	_expect(
		root.gui_get_focus_owner() == confirmation.confirm_button,
		"弹窗打开时确认按钮必须获得键盘/手柄焦点。"
	)
	await create_timer(RogueRouteMoveConfirmation.OPEN_DURATION_SECONDS + 0.03).timeout
	_expect(
		confirmation.panel_stage.scale.is_equal_approx(Vector2.ONE),
		"短暂入场动效结束后面板必须回到原始尺寸。"
	)
	_save_preview()

	var cancel_event := InputEventAction.new()
	cancel_event.action = &"ui_cancel"
	cancel_event.pressed = true
	confirmation._input(cancel_event)
	_expect(not confirmation.visible, "ui_cancel 必须关闭确认层。")
	_expect(canceled_count == 1 and confirmed_count == 0, "取消只能发出一次 canceled。")

	confirmation.present("紧急作战", 7, 2)
	confirmation.confirm_button.pressed.emit()
	_expect(not confirmation.visible, "确认后必须立即关闭确认层。")
	_expect(confirmed_count == 1 and canceled_count == 1, "确认只能发出一次 confirmed。")

	root.remove_child(confirmation)
	confirmation.free()
	root.remove_child(background)
	background.free()
	await _audit_p3_integration()
	_finish()


func _audit_p3_integration() -> void:
	var fixture := _find_legacy_confirmation_fixture()
	_expect(
		not fixture.is_empty(),
		"测试种子范围内必须同时存在相邻紧急作战与非战斗节点。"
	)
	if fixture.is_empty():
		return
	var run_state := root.get_node_or_null("RunState") as RunStateStore
	if run_state != null:
		run_state.begin_new_run(PlayerCharacterRegistry.TANGO_ID, false)
	var route := ROUTE_SCENE.instantiate() as RogueRouteGame
	_expect(route != null, "P3 路线场景必须能够实例化自定义确认层。")
	if route == null:
		return
	route.initial_generation_seed = int(fixture["seed"])
	route.return_requested.connect(func() -> void: return_requested_count += 1)
	root.add_child(route)
	current_scene = route
	for _frame in range(8):
		await process_frame

	var runtime := route.get("_runtime_state") as RogueRouteRuntimeState
	var board := route.get_node_or_null("World/RouteBoard") as RogueRouteBoard
	var local_player := route.get("player") as Player
	var camera := route.find_child("Camera2D", true, false) as Camera2D
	_expect(
		runtime != null and board != null and local_player != null and camera != null,
		"P3 确认层回归夹具必须完成路线、玩家与镜头初始化。"
	)
	if runtime == null or board == null or local_player == null or camera == null:
		current_scene = null
		root.remove_child(route)
		route.free()
		return
	board.complete_entry_reveal()
	await process_frame

	var emergency_node_id := int(fixture["emergency_node_id"])
	var non_combat_node_id := int(fixture["non_combat_node_id"])
	local_player.global_position = board.get_node_global_position(
		runtime.current_node_id
	)
	local_player.velocity = Vector2.ZERO
	await physics_frame
	_expect(
		local_player.global_position.distance_to(
			board.get_node_global_position(emergency_node_id)
		) > 28.0,
		"远距点击夹具必须让玩家停留在当前节点附近，而非目标节点周围。"
	)
	route.call(&"_apply_camera_drag", Vector2(-96.0, -48.0))
	await process_frame
	var camera_position_before_modal := camera.position

	route.call(&"_on_route_board_node_pressed", emergency_node_id)
	_expect(
		int(route.get("_pending_node_id")) == emergency_node_id
		and route.move_confirmation.visible
		and not route.node_briefing.visible
		and int(route.get("_briefing_phase"))
		== RogueRouteGame.BriefingPhase.NONE,
		"紧急作战仍必须使用旧移动确认框，不得误接入普通作战简报。"
	)
	_expect(
		bool(board.get("_interaction_locked")) and local_player.controls_locked,
		"确认期间必须锁定路线节点与本地玩家操作。"
	)
	var state_before_guard_checks := route.export_state_snapshot()
	route.call(&"_on_regenerate_button_pressed")
	route.call(&"_on_recenter_button_pressed")
	var home_event := InputEventKey.new()
	home_event.pressed = true
	home_event.keycode = KEY_HOME
	route.call(&"_unhandled_input", home_event)
	_expect(
		route.export_state_snapshot() == state_before_guard_checks
		and camera.position.is_equal_approx(camera_position_before_modal)
		and int(route.get("_pending_node_id")) == emergency_node_id,
		"确认期间重生成、定位与 Home 输入均不得穿透到底层地图。"
	)
	route.call(&"_on_return_button_pressed")
	_expect(
		return_requested_count == 0
		and int(route.get("_pending_node_id")) == -1
		and not route.move_confirmation.visible
		and not route.node_briefing.visible
		and not bool(board.get("_interaction_locked"))
		and not local_player.controls_locked,
		"紧急作战确认期间按返回只能取消本次移动并恢复输入。"
	)

	route.call(&"_on_route_board_node_pressed", non_combat_node_id)
	_expect(
		int(route.get("_pending_node_id")) == non_combat_node_id
		and route.move_confirmation.visible
		and not route.node_briefing.visible
		and int(route.get("_briefing_phase"))
		== RogueRouteGame.BriefingPhase.NONE,
		"遗址物资、黑市或未雨绸缪节点仍必须使用旧移动确认框。"
	)
	var state_before_move := route.export_state_snapshot()
	var player_position_before_move := local_player.global_position
	var camera_local_before_move := camera.position
	var camera_global_before_move := camera.global_position
	var camera_center_before_move := camera.get_screen_center_position()
	route.move_confirmation.confirm_button.pressed.emit()
	route.move_confirmation.confirm_button.pressed.emit()
	await physics_frame
	await process_frame
	var state_after_move := route.export_state_snapshot()
	_expect(
		int(state_after_move.get("revision", -1))
		== int(state_before_move.get("revision", -1)) + 1
		and int(state_after_move.get("action_points", -1))
		== int(state_before_move.get("action_points", -1))
		- route.generation_config.move_action_cost
		and int(state_after_move.get("current_node_id", -1))
		== non_combat_node_id
		and int((state_after_move.get("visited_counts") as PackedInt32Array)[
			non_combat_node_id
		])
		== int((state_before_move.get("visited_counts") as PackedInt32Array)[
			non_combat_node_id
		]) + 1,
		"旧确认框连续确认也只能推进一次 revision、扣一次行动力并增加一次访问。"
	)
	_expect(
		local_player.global_position.is_equal_approx(player_position_before_move)
		and camera.position.is_equal_approx(camera_local_before_move)
		and camera.global_position.is_equal_approx(camera_global_before_move)
		and camera.get_screen_center_position().is_equal_approx(camera_center_before_move),
		"确认移动不得传送玩家或强制移动摄像机。"
	)

	current_scene = null
	root.remove_child(route)
	route.free()
	await process_frame


func _find_legacy_confirmation_fixture() -> Dictionary:
	for seed in range(1, MAX_SEED_SEARCH + 1):
		var graph := RogueRouteGenerator.generate(GENERATION_CONFIG, seed)
		if graph == null:
			continue
		var emergency_node_id := -1
		var non_combat_node_id := -1
		for neighbor_id in graph.get_neighbors(graph.start_node_id):
			match graph.get_node_type(neighbor_id):
				RogueRouteGraph.NodeType.EMERGENCY_COMBAT:
					emergency_node_id = int(neighbor_id)
				RogueRouteGraph.NodeType.WILDERNESS_RESOURCE, \
				RogueRouteGraph.NodeType.MYSTERY_BLACK_MARKET, \
				RogueRouteGraph.NodeType.PREPARE_AHEAD:
					non_combat_node_id = int(neighbor_id)
		if emergency_node_id >= 0 and non_combat_node_id >= 0:
			return {
				"seed": seed,
				"emergency_node_id": emergency_node_id,
				"non_combat_node_id": non_combat_node_id,
			}
	return {}


func _save_preview() -> void:
	if DisplayServer.get_name() == "headless":
		print("ROGUE_ROUTE_MOVE_CONFIRMATION_PREVIEW_SKIPPED=dummy_renderer")
		return
	var image := root.get_texture().get_image()
	if image == null:
		print("ROGUE_ROUTE_MOVE_CONFIRMATION_PREVIEW_SKIPPED=dummy_renderer")
		return
	var path := "user://rogue_route_move_confirmation_preview.png"
	var error := image.save_png(path)
	_expect(error == OK, "确认弹窗视觉预览必须能够保存。")
	if error == OK:
		print("ROGUE_ROUTE_MOVE_CONFIRMATION_PREVIEW=", ProjectSettings.globalize_path(path))


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("ROGUE_ROUTE_MOVE_CONFIRMATION_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)
