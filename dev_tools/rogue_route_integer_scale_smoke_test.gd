extends SceneTree

## Rogue 路线整数显示缩放的无渲染器验收。
##
## 这里刻意只观察 RogueRouteWorld 的公开接口与最终 Canvas 变换，不复制
## 生产实现的内部选档条件。这样 CI 的 headless renderer 也能覆盖分辨率选档、
## resize、相机所有权 guard，以及量化后移动节奏不会以停顿替代闪烁。

const ROUTE_SCENE := preload(
	"res://scene/game_modes/rogue/route/rogue_route_game.tscn"
)
const BASE_CONTENT_SIZE := Vector2i(1152, 648)
const SAFE_VISIBLE_WORLD_SIZE := Vector2(640.0, 360.0)
const EPSILON := 0.001
const RESOLUTION_CASES := [
	{
		"size": Vector2i(1152, 648),
		"scale": 2,
		"canonical": false,
		"requires_reference_frame": false,
	},
	{"size": Vector2i(1280, 720), "scale": 2, "canonical": true},
	{"size": Vector2i(1366, 768), "scale": 2, "canonical": false},
	{"size": Vector2i(1600, 900), "scale": 2, "canonical": false},
	{"size": Vector2i(1920, 1080), "scale": 3, "canonical": true},
	{"size": Vector2i(1920, 1200), "scale": 3, "canonical": false},
	{"size": Vector2i(2560, 1080), "scale": 3, "canonical": false},
	{"size": Vector2i(2560, 1440), "scale": 4, "canonical": true},
	{"size": Vector2i(3440, 1440), "scale": 4, "canonical": false},
	{"size": Vector2i(3840, 2160), "scale": 6, "canonical": true},
]

var failures: PackedStringArray = []
var _original_window_size := Vector2i.ZERO
var _original_content_scale_size := Vector2i.ZERO
var _original_content_scale_mode := Window.CONTENT_SCALE_MODE_DISABLED
var _original_content_scale_aspect := Window.CONTENT_SCALE_ASPECT_IGNORE


func _initialize() -> void:
	call_deferred(&"_run")


func _run() -> void:
	_capture_window_state()
	_configure_test_window(Vector2i(1280, 720))
	_audit_pure_scale_contract()

	var route := ROUTE_SCENE.instantiate() as RogueRouteGame
	_expect(route != null, "路线整数缩放 smoke 必须能实例化 RogueRouteGame。")
	if route == null:
		_finish()
		return
	route.initial_generation_seed = 1
	route.manage_return_locally = true
	root.add_child(route)
	for _frame_index in range(8):
		await process_frame
	_expect(route.is_route_ready(), "整数缩放运行时夹具必须完成固定路线生成。")
	if route.route_board != null:
		route.route_board.complete_entry_reveal()
	await physics_frame

	var world := route.world as RogueRouteWorld
	_expect(world != null, "路线场景必须暴露 RogueRouteWorld。")
	_expect(route.player != null, "路线整数缩放运行时夹具必须创建本地玩家。")
	if world != null and route.player != null:
		await _audit_resolution_table(route, world)
		await _audit_live_resize(route, world)
		await _audit_camera_ownership_guard(route, world)
		await _audit_combat_handoff(route, world)
		await _audit_motion_cadence(route, world)

	# 最后让一个路线外 Camera2D 持有同一 Viewport；RouteWorld._exit_tree
	# 只能清理自己的开关，绝不能把外部相机已提交的原生 canvas 写回覆盖。
	var exit_camera := Camera2D.new()
	exit_camera.name = "IntegerScaleExitGuardCamera"
	exit_camera.position = Vector2(211.25, 133.75)
	exit_camera.process_callback = Camera2D.CAMERA2D_PROCESS_PHYSICS
	root.add_child(exit_camera)
	route.set_route_presentation_enabled(false)
	exit_camera.make_current()
	exit_camera.force_update_scroll()
	await process_frame
	var exit_canvas_before := root.get_viewport().canvas_transform
	root.remove_child(route)
	route.free()
	await process_frame
	_expect(
		root.get_viewport().get_camera_2d() == exit_camera
		and root.get_viewport().canvas_transform.is_equal_approx(exit_canvas_before),
		"离开路线时不得覆盖仍由外部 Camera2D 持有的原生 Canvas 变换。"
	)
	root.remove_child(exit_camera)
	exit_camera.free()
	await process_frame

	# 无后继 Camera2D 时，World 自身退出发生在其 Camera 子节点之后；此时
	# 必须恢复进入路线前的 Canvas，而不能把最后一次像素吸附留给下一场景。
	var direct_exit_canvas_before := root.get_viewport().canvas_transform
	var direct_exit_route := ROUTE_SCENE.instantiate() as RogueRouteGame
	_expect(direct_exit_route != null, "直接退出夹具必须能实例化路线场景。")
	if direct_exit_route != null:
		direct_exit_route.auto_initialize = false
		direct_exit_route.manage_return_locally = true
		root.add_child(direct_exit_route)
		for _frame_index in range(3):
			await process_frame
		_expect(
			direct_exit_route.get_viewport().get_camera_2d()
			== direct_exit_route.map_camera,
			"直接退出前路线 Camera2D 必须实际拥有 Viewport。"
		)
		var direct_exit_world := direct_exit_route.world as RogueRouteWorld
		var direct_exit_active_canvas := root.get_viewport().canvas_transform
		_expect(
			direct_exit_world != null
			and direct_exit_world.is_route_pixel_snap_active()
			and not direct_exit_active_canvas.is_equal_approx(
				direct_exit_canvas_before
			),
			"直接退出前路线必须已用像素吸附 Canvas 覆盖进入前变换。"
		)
		root.remove_child(direct_exit_route)
		direct_exit_route.free()
		await process_frame
		_expect(
			root.get_viewport().get_camera_2d() == null
			and root.get_viewport().canvas_transform.is_equal_approx(
				direct_exit_canvas_before
			),
			"无后继相机地离开路线时必须恢复进入路线前的 Canvas 变换。"
		)
	_restore_window_state()
	_finish()


func _audit_resolution_table(
	route: RogueRouteGame,
	world: RogueRouteWorld
) -> void:
	for case_variant: Variant in RESOLUTION_CASES:
		var case := case_variant as Dictionary
		var physical_size := case["size"] as Vector2i
		var expected_scale := int(case["scale"])
		var is_canonical := bool(case["canonical"])
		var requires_reference_frame := bool(
			case.get("requires_reference_frame", true)
		)
		_configure_test_window(physical_size)
		await process_frame
		await process_frame
		_expect(
			world.refresh_integer_route_scale(),
			"%s 必须能强制重选路线整数倍率。" % physical_size
		)
		world.apply_route_canvas_pixel_snap()
		var actual_scale := world.get_integer_pixel_scale()
		var physical_world_scale := world.get_effective_physical_world_scale()
		_expect(
			actual_scale == expected_scale,
			"%s 路线整数倍率应为 K=%d，实际为 %d。"
			% [physical_size, expected_scale, actual_scale]
		)
		_expect(
			physical_world_scale.is_equal_approx(
				Vector2(expected_scale, expected_scale)
			),
			"%s 最终路线世界 basis 必须是等轴整数 K=%d，实际为 %s。"
			% [physical_size, expected_scale, physical_world_scale]
		)
		var expected_fov := Vector2(physical_size) / float(expected_scale)
		var visible_world := (
			route.get_viewport_rect().size / route.map_camera.zoom
		)
		_expect(
			visible_world.distance_to(expected_fov) <= 0.02,
			"%s 可见世界应为 %s，实际为 %s。"
			% [physical_size, expected_fov, visible_world]
		)
		if requires_reference_frame:
			_expect(
				visible_world.x + EPSILON >= SAFE_VISIBLE_WORLD_SIZE.x
				and visible_world.y + EPSILON >= SAFE_VISIBLE_WORLD_SIZE.y,
				"%s 必须完整显示至少 640×360 路线安全框，实际为 %s。"
				% [physical_size, visible_world]
			)
		else:
			_expect(
				physical_size == BASE_CONTENT_SIZE
				and visible_world.distance_to(Vector2(576.0, 324.0)) <= 0.02,
				"1152×648 设计画布必须以 K2 放大路线并显示 576×324，实际为 %s。"
				% visible_world
			)
		if is_canonical:
			_expect(
				visible_world.distance_to(SAFE_VISIBLE_WORLD_SIZE) <= 0.02,
				"标准 16:9 档 %s 必须与其他标准档同构图 640×360，实际为 %s。"
				% [physical_size, visible_world]
			)
		_audit_final_transform(route, world, "%s 选档后" % physical_size)
	await _audit_canonical_composition(route, world)


func _audit_canonical_composition(
	route: RogueRouteGame,
	world: RogueRouteWorld
) -> void:
	var normalized_node_samples: Array[Vector2] = []
	var rendered_center_samples: Array[Vector2] = []
	var graph := world.route_board.graph
	_expect(graph != null and graph.get_node_count() > 0, "跨档构图必须有路线节点锚点。")
	if graph == null or graph.get_node_count() <= 0:
		return
	var anchor_node_id := 0
	for node_id in range(graph.get_node_count()):
		if node_id != graph.start_node_id:
			anchor_node_id = node_id
			break
	for case_variant: Variant in RESOLUTION_CASES:
		var case := case_variant as Dictionary
		if not bool(case["canonical"]):
			continue
		var physical_size := case["size"] as Vector2i
		_configure_test_window(physical_size)
		await process_frame
		await process_frame
		world.refresh_integer_route_scale()
		route.map_camera.position = Vector2.ZERO
		route.map_camera.reset_physics_interpolation()
		route.map_camera.force_update_scroll()
		await process_frame
		var final_board_transform := (
			route.get_viewport().get_screen_transform()
			* world.route_board.get_global_transform_with_canvas()
		)
		var node_screen := (
			final_board_transform
			* world.route_board.get_node_position(anchor_node_id)
		)
		var normalized_node := node_screen / Vector2(physical_size)
		normalized_node_samples.append(normalized_node)
		rendered_center_samples.append(world.get_rendered_camera_center())
	for sample_index in range(1, normalized_node_samples.size()):
		_expect(
			normalized_node_samples[sample_index].distance_to(
				normalized_node_samples[0]
			) <= EPSILON,
			"720p/1080p/1440p/4K 的同一路线节点必须保持相同归一化屏幕构图。"
		)
		_expect(
			rendered_center_samples[sample_index].distance_to(
				rendered_center_samples[0]
			) <= 0.02,
			"720p/1080p/1440p/4K 必须保持同一世界相机中心。"
		)


func _audit_live_resize(
	route: RogueRouteGame,
	world: RogueRouteWorld
) -> void:
	_configure_test_window(Vector2i(1280, 720))
	await process_frame
	world.refresh_integer_route_scale()
	world.apply_route_canvas_pixel_snap()
	var player_position_before := route.player.global_position
	var graph_before: RogueRouteGraph = world.route_board.graph
	_configure_test_window(BASE_CONTENT_SIZE)
	await process_frame
	await process_frame
	var compact_visible_world := (
		route.get_viewport_rect().size / route.map_camera.zoom
	)
	_expect(
		world.get_integer_pixel_scale() == 2
		and compact_visible_world.distance_to(Vector2(576.0, 324.0)) <= 0.02,
		"1280×720 → 1152×648 resize 必须保持 K2，并把路线放大到 576×324 FOV。"
	)
	_expect(
		route.player.global_position.is_equal_approx(player_position_before)
		and world.route_board.graph == graph_before,
		"紧凑设计画布 resize 不得移动玩家或重建权威路线图。"
	)
	_audit_final_transform(route, world, "1152×648 设计画布 resize 后")

	_configure_test_window(Vector2i(1280, 720))
	await process_frame
	await process_frame

	_configure_test_window(Vector2i(2560, 1440))
	await process_frame
	await process_frame
	_expect(
		world.refresh_integer_route_scale(),
		"运行时 resize 后必须检测并刷新路线整数倍率。"
	)
	world.apply_route_canvas_pixel_snap()
	_expect(
		world.get_integer_pixel_scale() == 4,
		"1280×720 → 2560×1440 resize 必须从 K2 切到 K4。"
	)
	_expect(
		route.player.global_position.is_equal_approx(player_position_before)
		and world.route_board.graph == graph_before,
		"显示 resize 不得移动玩家或重建权威路线图。"
	)
	_audit_final_transform(route, world, "运行时 resize 后")

	# 1920×1080 与 2560×1080 的 stretch basis 和 K 都相同，只有 EXPAND
	# 后的逻辑可见宽度变化；生产 _process 仍必须发现 viewport size 改变，
	# 重新 clamp 已拖到边缘的 camera offset。
	_configure_test_window(Vector2i(1920, 1080))
	await process_frame
	await process_frame
	world.refresh_integer_route_scale()
	world.apply_camera_drag(
		route.player,
		Vector2(-100000.0, 0.0),
		route.get_viewport_rect().size
	)
	route.map_camera.force_update_scroll()
	await process_frame
	var narrow_zoom := route.map_camera.zoom
	var narrow_center_x := (
		route.player.global_position.x + route.map_camera.position.x
	)
	_configure_test_window(Vector2i(2560, 1080))
	await process_frame
	await process_frame
	var wide_center_x := (
		route.player.global_position.x + route.map_camera.position.x
	)
	var bounds := world.route_board.get_world_bounds()
	var wide_half_view := (
		route.get_viewport_rect().size.x / route.map_camera.zoom.x * 0.5
	)
	var expected_wide_center_x := bounds.end.x - wide_half_view
	if bounds.position.x + wide_half_view > expected_wide_center_x:
		expected_wide_center_x = bounds.get_center().x
	_expect(
		world.get_integer_pixel_scale() == 3
		and route.map_camera.zoom.is_equal_approx(narrow_zoom),
		"同 stretch basis 的宽屏 resize 必须保持 K3/zoom，不应抖动选档。"
	)
	_expect(
		wide_center_x <= narrow_center_x + EPSILON
		and absf(wide_center_x - expected_wide_center_x) <= 0.02,
		"宽屏 resize 必须按新 FOV 自动收紧边缘 camera offset。"
	)
	_audit_final_transform(route, world, "同倍率宽屏 resize 后")

	# 从 K3 的标准 1080p 缩到 1600×900 必须立刻降到 K2；任何迟滞或
	# 上一档缓存都会把 640×360 安全框暂时裁成 533⅓×300。
	_configure_test_window(Vector2i(1920, 1080))
	await process_frame
	world.refresh_integer_route_scale()
	_expect(world.get_integer_pixel_scale() == 3, "迟滞降档夹具必须先建立 K3。")
	_configure_test_window(Vector2i(1600, 900))
	await process_frame
	var safe_visible_world := (
		route.get_viewport_rect().size / route.map_camera.zoom
	)
	_expect(
		world.get_integer_pixel_scale() == 2
		and safe_visible_world.x + EPSILON >= SAFE_VISIBLE_WORLD_SIZE.x
		and safe_visible_world.y + EPSILON >= SAFE_VISIBLE_WORLD_SIZE.y,
		"K3→900p resize 必须同帧降到 K2，不得因迟滞暂时裁掉 640×360 安全框。"
	)


func _audit_camera_ownership_guard(
	route: RogueRouteGame,
	world: RogueRouteWorld
) -> void:
	_configure_test_window(Vector2i(1920, 1080))
	await process_frame
	world.refresh_integer_route_scale()
	route.map_camera.make_current()
	await process_frame
	_expect(
		world.is_route_pixel_snap_active(),
		"路线可见且 map camera 为 current 时像素吸附必须激活。"
	)
	_expect(
		world.apply_route_canvas_pixel_snap(),
		"活动路线相机必须接受最终 Canvas 像素吸附。"
	)

	var combat_camera := Camera2D.new()
	combat_camera.name = "IntegerScaleGuardCombatCamera"
	combat_camera.position = Vector2(173.25, 91.75)
	route.add_child(combat_camera)
	combat_camera.make_current()
	combat_camera.force_update_scroll()
	await process_frame
	var guarded_center_before := world.get_rendered_camera_center()
	_expect(
		not world.is_route_pixel_snap_active()
		and not world.apply_route_canvas_pixel_snap(),
		"其他 Camera2D 为 current 时路线不得污染共享 Viewport Canvas。"
	)
	_expect(
		world.get_rendered_camera_center().is_equal_approx(guarded_center_before),
		"inactive guard 拒绝吸附时不得改写路线渲染中心。"
	)

	combat_camera.enabled = false
	route.map_camera.make_current()
	route.map_camera.force_update_scroll()
	await process_frame
	_expect(
		world.is_route_pixel_snap_active()
		and world.apply_route_canvas_pixel_snap(),
		"路线重新取得 current camera 后必须恢复像素吸附。"
	)
	route.remove_child(combat_camera)
	combat_camera.free()
	_audit_final_transform(route, world, "相机 guard 恢复后")


func _audit_combat_handoff(
	route: RogueRouteGame,
	world: RogueRouteWorld
) -> void:
	var scale_before := world.get_integer_pixel_scale()
	var camera_offset_before := route.map_camera.position
	var camera_zoom_before := route.map_camera.zoom
	route.set_route_presentation_enabled(false)
	_expect(
		not world.is_route_pixel_snap_active()
		and not world.apply_route_canvas_pixel_snap(),
		"作战 lease 隐藏路线时必须关闭路线像素吸附。"
	)

	var combat_camera := Camera2D.new()
	combat_camera.name = "IntegerScaleHandoffCombatCamera"
	combat_camera.position = Vector2(128.25, 128.75)
	combat_camera.zoom = Vector2(2.5, 2.5)
	route.add_child(combat_camera)
	combat_camera.make_current()
	combat_camera.force_update_scroll()
	await process_frame
	var combat_canvas := route.get_viewport().canvas_transform
	var viewport_center := route.get_viewport_rect().size * 0.5
	var combat_canvas_center := combat_canvas.affine_inverse() * viewport_center
	_expect(
		combat_canvas_center.distance_to(
			combat_camera.get_screen_center_position()
		) <= 0.51,
		"战斗相机必须保留自己的原生 Canvas 中心，不得继承路线像素相位。"
	)
	# 重复隐藏是重连/全量同步常见路径，不能在外部相机已 current 时由
	# RouteWorld 再 force_update_scroll 覆盖本帧 Canvas。
	route.set_route_presentation_enabled(false)
	await process_frame
	_expect(
		route.get_viewport().canvas_transform.is_equal_approx(combat_canvas),
		"重复作战 lease reconcile 不得污染战斗相机原生 Canvas。"
	)
	_expect(
		world.get_integer_pixel_scale() == scale_before
		and route.map_camera.position.is_equal_approx(camera_offset_before)
		and route.map_camera.zoom.is_equal_approx(camera_zoom_before),
		"战斗相机取得 Viewport 期间不得污染已选倍率或路线相机状态。"
	)

	combat_camera.hide()
	route.set_route_presentation_enabled(true)
	await physics_frame
	await process_frame
	_expect(
		world.is_route_pixel_snap_active()
		and route.get_viewport().get_camera_2d() == route.map_camera,
		"返回路线必须同时恢复 map camera 所有权与像素吸附。"
	)
	_expect(
		world.get_integer_pixel_scale() == scale_before,
		"战斗交接不得无 resize 地重选整数倍率。"
	)
	_audit_final_transform(route, world, "战斗交接返回后")
	route.remove_child(combat_camera)
	combat_camera.free()


func _audit_motion_cadence(
	route: RogueRouteGame,
	world: RogueRouteWorld
) -> void:
	# 13 world px/s 同时覆盖低于与高于 1 physical px/frame 的速度；
	# 60/120 Hz 能抓到“在 physics tick 粗暴 round、render tick 隔帧不动”。
	const WORLD_SPEED := 13.0
	const SAMPLE_SECONDS := 2.0
	for fps in [60, 120]:
		for pixel_scale in [2, 3, 4, 6]:
			var frame_count := int(SAMPLE_SECONDS * fps)
			var ideal_step_physical: float = (
				WORLD_SPEED * float(pixel_scale) / float(fps)
			)
			var stretch_scale := Vector2(1.37, 1.37)
			var stretch_transform := Transform2D(
				Vector2(stretch_scale.x, 0.0),
				Vector2(0.0, stretch_scale.y),
				Vector2.ZERO
			)
			var actual_positions := PackedFloat64Array()
			for frame_index in range(frame_count + 1):
				var ideal_physical: float = (
					float(frame_index) * ideal_step_physical
				)
				var canvas_transform := Transform2D(
					Vector2(1.0, 0.0),
					Vector2(0.0, 1.0),
					Vector2(ideal_physical / stretch_scale.x, 0.0)
				)
				var snapped := RogueRouteWorld.snap_canvas_transform_to_physical_pixels(
					canvas_transform,
					stretch_transform
				)
				var snapped_physical := stretch_transform * snapped
				actual_positions.append(snapped_physical.origin.x)
			_audit_quantized_cadence(
				actual_positions,
				ideal_step_physical,
				"%dHz/K%d" % [fps, pixel_scale]
			)

	# 运行时抽样只验证公共渲染中心确实位于所选物理像素 lattice；
	# 上面的纯序列负责完整 60/120 Hz 节奏不变量。
	_configure_test_window(Vector2i(1920, 1080))
	await process_frame
	world.refresh_integer_route_scale()
	route.map_camera.make_current()
	await process_frame
	var pixel_scale := world.get_integer_pixel_scale()
	var player_origin := route.player.global_position
	for sample_index in range(24):
		route.player.global_position = (
			player_origin + Vector2(float(sample_index) * 0.137, 0.0)
		)
		route.player.reset_physics_interpolation()
		route.map_camera.force_update_scroll()
		# 不直接调用 snap：让 Camera2D 先提交本帧变换，再由 World 较晚的
		# _process 自动吸附，覆盖实际 process_priority 时序合同。
		await process_frame
		var rendered_center := world.get_rendered_camera_center()
		var final_transform := (
			route.get_viewport().get_screen_transform()
			* world.route_board.get_global_transform_with_canvas()
		)
		_expect(
			_is_integer(rendered_center.x * pixel_scale)
			and _is_integer(rendered_center.y * pixel_scale)
			and _is_integer(final_transform.origin.x)
			and _is_integer(final_transform.origin.y),
			"运行时渲染中心必须落在 1/K world lattice（样本 %d，K%d，中心 %s）。"
			% [sample_index, pixel_scale, rendered_center]
		)
	route.player.global_position = player_origin
	route.player.reset_physics_interpolation()
	route.map_camera.force_update_scroll()
	await process_frame


func _audit_pure_scale_contract() -> void:
	for case_variant: Variant in RESOLUTION_CASES:
		var case := case_variant as Dictionary
		var physical_size := case["size"] as Vector2i
		var expected_scale := int(case["scale"])
		var uniform_stretch := minf(
			float(physical_size.x) / float(BASE_CONTENT_SIZE.x),
			float(physical_size.y) / float(BASE_CONTENT_SIZE.y)
		)
		var stretch_scale := Vector2(uniform_stretch, uniform_stretch)
		var actual_scale := RogueRouteWorld.calculate_safe_integer_pixel_scale(
			Vector2(physical_size),
			SAFE_VISIBLE_WORLD_SIZE
		)
		var camera_zoom := RogueRouteWorld.calculate_compensated_camera_zoom(
			actual_scale,
			stretch_scale
		)
		_expect(
			actual_scale == expected_scale,
			"%s 纯选档合同应得到 K%d，实际为 K%d。"
			% [physical_size, expected_scale, actual_scale]
		)
		_expect(
			(stretch_scale * camera_zoom).is_equal_approx(
				Vector2(expected_scale, expected_scale)
			),
			"%s 补偿 zoom 必须让最终 basis 精确等于整数 K%d。"
			% [physical_size, expected_scale]
		)

	var fractional_stretch := Transform2D(
		Vector2(10.0 / 9.0, 0.0),
		Vector2(0.0, 10.0 / 9.0),
		Vector2.ZERO
	)
	var fractional_canvas := Transform2D(
		Vector2(1.8, 0.0),
		Vector2(0.0, 1.8),
		Vector2(17.23, -9.67)
	)
	var snapped := RogueRouteWorld.snap_canvas_transform_to_physical_pixels(
		fractional_canvas,
		fractional_stretch
	)
	var snapped_twice := RogueRouteWorld.snap_canvas_transform_to_physical_pixels(
		snapped,
		fractional_stretch
	)
	var physical := fractional_stretch * snapped
	_expect(
		_is_integer(physical.origin.x)
		and _is_integer(physical.origin.y)
		and physical.x.is_equal_approx(Vector2(2.0, 0.0))
		and physical.y.is_equal_approx(Vector2(0.0, 2.0)),
		"纯 Canvas 吸附必须只量化最终物理 origin，并保留整数 basis。"
	)
	_expect(
		snapped.is_equal_approx(snapped_twice),
		"纯 Canvas 吸附必须幂等，避免同帧重复 reconcile 继续漂移。"
	)
	_expect(
		RogueRouteWorld.calculate_safe_integer_pixel_scale(
			Vector2(NAN, 720.0),
			SAFE_VISIBLE_WORLD_SIZE
		) == 2
		and RogueRouteWorld.calculate_safe_integer_pixel_scale(
			Vector2(1280.0, 720.0),
			Vector2.ZERO
		) == 2,
		"无效 physical viewport/安全框必须安全退回 K2。"
	)
	_expect(
		RogueRouteWorld.calculate_safe_integer_pixel_scale(
			Vector2(1.0, 1.0),
			SAFE_VISIBLE_WORLD_SIZE
		) == 2
		and RogueRouteWorld.calculate_safe_integer_pixel_scale(
			Vector2(1279.0, 719.0),
			SAFE_VISIBLE_WORLD_SIZE
		) == 2
		and RogueRouteWorld.calculate_safe_integer_pixel_scale(
			Vector2(1919.0, 1079.0),
			SAFE_VISIBLE_WORLD_SIZE
		) == 2
		and RogueRouteWorld.calculate_safe_integer_pixel_scale(
			Vector2(1920.0, 1080.0),
			SAFE_VISIBLE_WORLD_SIZE
		) == 3,
		"最低倍率必须钳制为 K2，并只在完整 1080p 阈值升到 K3。"
	)
	_expect(
		RogueRouteWorld.calculate_compensated_camera_zoom(
			1,
			Vector2.ONE
		).is_equal_approx(Vector2(2.0, 2.0)),
		"补偿 zoom 的公开纯函数也必须执行 K2 最低倍率。"
	)


func _audit_quantized_cadence(
	positions: PackedFloat64Array,
	ideal_step: float,
	context: String
) -> void:
	var maximum_dwell := int(ceil(1.0 / ideal_step)) if ideal_step < 1.0 else 0
	var current_dwell := 0
	var largest_dwell := 0
	for index in range(1, positions.size()):
		var step := positions[index] - positions[index - 1]
		var ideal_total := float(index) * ideal_step
		_expect(step >= 0.0, "%s 的量化屏幕位移不得倒退。" % context)
		_expect(
			absf(positions[index] - ideal_total) <= 0.5001,
			"%s 累计屏幕位置与理想位置误差必须保持在半像素内。" % context
		)
		_expect(
			absf(step - floor(ideal_step)) <= EPSILON
			or absf(step - ceil(ideal_step)) <= EPSILON,
			"%s 每帧位移只能在理想步长的 floor/ceil 间分配。" % context
		)
		if is_zero_approx(step):
			current_dwell += 1
			largest_dwell = maxi(largest_dwell, current_dwell)
		else:
			current_dwell = 0
	if ideal_step >= 1.0:
		_expect(largest_dwell == 0, "%s 理想位移≥1px/frame 时不得出现停顿帧。" % context)
	else:
		_expect(
			largest_dwell <= maximum_dwell,
			"%s 连续停顿帧不得超过均匀像素量化的理论上限 %d。"
			% [context, maximum_dwell]
		)


func _audit_final_transform(
	route: RogueRouteGame,
	world: RogueRouteWorld,
	context: String
) -> void:
	var final_transform := (
		route.get_viewport().get_screen_transform()
		* world.route_board.get_global_transform_with_canvas()
	)
	var expected_scale := float(world.get_integer_pixel_scale())
	_expect(
		absf(final_transform.x.length() - expected_scale) <= EPSILON
		and absf(final_transform.y.length() - expected_scale) <= EPSILON
		and absf(final_transform.x.dot(final_transform.y)) <= EPSILON,
		"%s最终物理 transform basis 必须为无旋转/剪切的整数 K%d。"
		% [context, int(expected_scale)]
	)
	_expect(
		_is_integer(final_transform.origin.x)
		and _is_integer(final_transform.origin.y),
		"%s最终物理 transform origin 必须落在整数像素，实际为 %s。"
		% [context, final_transform.origin]
	)


func _capture_window_state() -> void:
	_original_window_size = root.size
	_original_content_scale_size = root.content_scale_size
	_original_content_scale_mode = root.content_scale_mode
	_original_content_scale_aspect = root.content_scale_aspect


func _configure_test_window(physical_size: Vector2i) -> void:
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
	root.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_EXPAND
	root.content_scale_size = BASE_CONTENT_SIZE
	root.size = physical_size


func _restore_window_state() -> void:
	root.content_scale_mode = _original_content_scale_mode
	root.content_scale_aspect = _original_content_scale_aspect
	root.content_scale_size = _original_content_scale_size
	root.size = _original_window_size


func _is_integer(value: float) -> bool:
	return absf(value - round(value)) <= EPSILON


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("ROGUE_ROUTE_INTEGER_SCALE_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)
