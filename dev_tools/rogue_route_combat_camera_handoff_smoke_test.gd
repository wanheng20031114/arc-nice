extends SceneTree

const ROUTE_SCENE := preload(
	"res://scene/game_modes/rogue/route/rogue_route_game.tscn"
)

var failures: PackedStringArray = []


func _initialize() -> void:
	call_deferred(&"_run")


func _run() -> void:
	var route := ROUTE_SCENE.instantiate() as RogueRouteGame
	route.auto_initialize = false
	route.manage_return_locally = true
	root.add_child(route)
	await process_frame
	await physics_frame

	var route_camera := route.map_camera
	var viewport := route.get_viewport()
	route.set_route_presentation_enabled(true)
	await process_frame
	_expect(
		route.player != null
		and route_camera.get_parent() == route.player
		and viewport.get_camera_2d() == route_camera,
		"夹具必须先建立路线玩家跟随相机。"
	)

	# 多人终局安全屏障会让隐藏的战斗 runtime 暂时留树；隐藏 Node2D
	# 不会自动停用 Camera2D，正是实机截图中视角锁在 (128, 128) 的路径。
	route.set_route_presentation_enabled(false)
	var combat_runtime := Node2D.new()
	combat_runtime.name = "RetainedCombatRuntime"
	var combat_camera := Camera2D.new()
	combat_camera.name = "Camera2D"
	combat_camera.position = Vector2(128.0, 128.0)
	combat_camera.zoom = Vector2(2.0, 2.0)
	combat_runtime.add_child(combat_camera)
	route.add_child(combat_runtime)
	combat_camera.make_current()
	combat_camera.force_update_scroll()
	await process_frame
	_expect(
		viewport.get_camera_2d() == combat_camera,
		"进入作战后战斗相机必须取得同一 Viewport。"
	)

	combat_runtime.hide()
	route.set_route_presentation_enabled(true)
	await physics_frame
	await process_frame
	_expect_route_camera_and_canvas(route, "隐藏战场尚未释放时")

	# 覆盖 presentation 已是 true 的重复恢复：旧实现会在这里提前 return，
	# 让仍启用的战斗相机继续控制路线。
	combat_camera.make_current()
	combat_camera.force_update_scroll()
	route.set_route_presentation_enabled(true)
	await physics_frame
	await process_frame
	_expect_route_camera_and_canvas(route, "重复返回通知到达时")

	# 单人战斗会先移除 runtime 再揭示路线；同一 API 也必须稳定恢复。
	route.set_route_presentation_enabled(false)
	combat_runtime.show()
	combat_camera.make_current()
	combat_camera.force_update_scroll()
	route.remove_child(combat_runtime)
	combat_runtime.free()
	route.set_route_presentation_enabled(true)
	await physics_frame
	await process_frame
	_expect_route_camera_and_canvas(route, "战场已释放时")
	await _test_presentation_lease_composition(route)
	await _test_player_attach_during_lease()
	await _test_reconnect_defeat_and_profile_input_ownership()

	route.queue_free()
	await process_frame
	await process_frame
	if failures.is_empty():
		print("ROGUE_ROUTE_COMBAT_CAMERA_HANDOFF_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_presentation_lease_composition(route: RogueRouteGame) -> void:
	var retained_runtime := Node2D.new()
	retained_runtime.name = "RetainedCombatForLeaseTest"
	var retained_camera := Camera2D.new()
	retained_camera.name = "Camera2D"
	retained_camera.position = Vector2(384.0, 256.0)
	retained_runtime.add_child(retained_camera)
	route.add_child(retained_runtime)

	# COMBAT 独占完整路线画面；Player 自身的 visible 状态不能被改写。
	route.set_route_presentation_enabled(false)
	_expect_presentation_state(
		route,
		RogueRouteGame.RoutePresentationLease.COMBAT,
		false,
		false,
		true,
		"作战取得 lease 后"
	)
	_expect(
		route.player.visible and route.player.body_sprite.visible,
		"隐藏路线必须只操作父级表现，不能改写玩家自身 visible。"
	)

	# 乱序交叠：SHOP 不得让 COMBAT 隐藏的 HUD 重新出现；释放一个从未
	# 持有的 ENCOUNTER 也不能清除另外两个 owner。
	route.call(&"_set_shop_route_presentation_active", false)
	route.call(&"_set_route_presentation_active", true)
	var combat_and_shop := (
		RogueRouteGame.RoutePresentationLease.COMBAT
		| RogueRouteGame.RoutePresentationLease.UNDERGROUND_SHOP
	)
	_expect_presentation_state(
		route,
		combat_and_shop,
		false,
		false,
		false,
		"作战与商店交叠且释放未知 owner 后"
	)

	# 释放 COMBAT 后仍有 SHOP：只允许 TopBar 所在 HUD 出现，World、
	# BottomBar 与 Camera 必须继续隐藏。
	route.set_route_presentation_enabled(true)
	_expect_presentation_state(
		route,
		RogueRouteGame.RoutePresentationLease.UNDERGROUND_SHOP,
		false,
		true,
		false,
		"仅剩商店 lease 时"
	)

	# 再叠加遭遇并先释放商店，完整 HUD blocker 必须继续生效。
	route.call(&"_set_route_presentation_active", false)
	route.call(&"_set_shop_route_presentation_active", true)
	_expect_presentation_state(
		route,
		RogueRouteGame.RoutePresentationLease.MAGICAL_ENCOUNTER,
		false,
		false,
		true,
		"商店先退出但遭遇仍持有 lease 时"
	)

	# 暂留战场 Camera 在最后一个 lease 释放前取得 current；协调器必须在
	# 同一事件边界重新声明路线相机并恢复玩家可见性。
	retained_camera.make_current()
	retained_camera.force_update_scroll()
	route.call(&"_set_route_presentation_active", true)
	await physics_frame
	await process_frame
	_expect_presentation_state(route, 0, true, true, true, "最后 lease 释放后")
	_expect_route_camera_and_canvas(route, "交叠 lease 全部释放后")
	_expect_route_player_visible(route, "交叠 lease 全部释放后")

	# 重连/退出确认可重复 release 已释放的 owner；这次 reconcile 必须纠正
	# 后来抢占 current 的相机，同时保持 mask 为 0。
	retained_camera.make_current()
	retained_camera.force_update_scroll()
	route.call(&"_set_shop_route_presentation_active", true)
	await physics_frame
	await process_frame
	_expect_presentation_state(route, 0, true, true, true, "重复 release 后")
	_expect_route_camera_and_canvas(route, "重复 release 已释放的商店 lease 后")

	# full snapshot 的各 reset 只能释放自己的 owner。先让三者交叠，再按
	# 地下商店→遭遇→作战的重置顺序验证不会提前揭示路线。
	route.set_route_presentation_enabled(false)
	route.call(&"_set_route_presentation_active", false)
	route.call(&"_set_shop_route_presentation_active", false)
	route.call(&"_reset_underground_shop_runtime", false)
	var combat_and_encounter := (
		RogueRouteGame.RoutePresentationLease.COMBAT
		| RogueRouteGame.RoutePresentationLease.MAGICAL_ENCOUNTER
	)
	_expect_presentation_state(
		route,
		combat_and_encounter,
		false,
		false,
		true,
		"商店 runtime 重置后"
	)
	route.call(&"_reset_encounter_runtime", false)
	_expect_presentation_state(
		route,
		RogueRouteGame.RoutePresentationLease.COMBAT,
		false,
		false,
		true,
		"遭遇 runtime 重置后"
	)
	route.call(&"_reset_normal_combat_stage", true)
	await physics_frame
	await process_frame
	_expect_presentation_state(route, 0, true, true, true, "作战 runtime 重置后")
	_expect_route_player_visible(route, "完整快照式顺序重置后")

	# Supply/Rare Chest 是路线上的 Overlay owner，只能锁交互，绝不能取得
	# World/Camera lease。
	route.supply_overlay.show_supply()
	route.rare_chest_overlay.show_rare_chest()
	_expect_presentation_state(route, 0, true, true, true, "补给与稀有宝箱 Overlay 展示时")
	route.supply_overlay.hide_supply_immediately()
	route.rare_chest_overlay.hide_rare_chest_immediately()

	# Profile 是路线内 Modal：打开/关闭不取得表现 lease，但必须与统一输入
	# 锁联动，禁止面板打开时点击节点或拖拽相机。
	route.player_profile_panel.open()
	await process_frame
	_expect(
		route.player_profile_panel.is_open()
		and bool(route.call(&"_is_route_input_locked"))
		and bool(route.route_board.get("_interaction_locked"))
		and route.player.controls_locked
		and int(route.get("_route_presentation_leases")) == 0,
		"Profile 打开时必须统一锁住玩家、路线节点和镜头输入，但不隐藏路线。"
	)
	route.player_profile_panel.close()
	await process_frame
	_expect(
		not route.player_profile_panel.is_open()
		and not bool(route.call(&"_is_route_input_locked"))
		and not bool(route.route_board.get("_interaction_locked"))
		and not route.player.controls_locked,
		"Profile 关闭且没有其他 owner 时必须完整释放路线输入锁。"
	)

	# Exclusive lease 必须事件式关闭 Profile，并停用它的全局 Bag 监听；
	# 否则独立 CanvasLayer 会在地下商店或作战画面上方重新打开。
	route.player_profile_panel.open()
	route.call(&"_set_shop_route_presentation_active", false)
	await process_frame
	_expect(
		not route.player_profile_panel.is_open()
		and not route.player_profile_panel.is_processing_unhandled_input(),
		"商店 lease 取得时必须关闭 Profile 并禁用关闭态 Bag 监听。"
	)
	await _send_bag_action()
	_expect(
		not route.player_profile_panel.is_open(),
		"Exclusive lease 期间按 Bag 不得在外部场景上方重开 Profile。"
	)
	route.call(&"_set_shop_route_presentation_active", true)
	await process_frame

	# Supply 等路线 Overlay 可显式打开背包；打开后仍需接收 Bag/Esc 关闭，
	# 关闭后因为 Supply owner 尚在，应立即回到禁用全局监听与路线锁定。
	route.call(&"_set_encounter_input_locked", true)
	route.call(&"_on_route_inventory_bag_requested")
	_expect(
		not route.player_profile_panel.is_open(),
		"普通库存按钮在 Overlay 锁期间不得绕过 owner 打开 Profile。"
	)
	route.player_profile_panel.open()
	await process_frame
	_expect(
		route.player_profile_panel.is_open()
		and route.player_profile_panel.is_processing_unhandled_input()
		and bool(route.call(&"_is_route_input_locked")),
		"Supply 显式打开 Profile 后必须保留关闭输入并维持路线锁。"
	)
	await _send_bag_action()
	_expect(
		not route.player_profile_panel.is_open()
		and not route.player_profile_panel.is_processing_unhandled_input()
		and bool(route.call(&"_is_route_input_locked"))
		and route.player.controls_locked,
		"Supply 下关闭 Profile 后必须立即恢复外层 owner 的路线锁。"
	)
	route.call(&"_set_encounter_input_locked", false)
	await process_frame

	route.remove_child(retained_runtime)
	retained_runtime.free()


func _test_player_attach_during_lease() -> void:
	var route := ROUTE_SCENE.instantiate() as RogueRouteGame
	route.auto_initialize = false
	route.manage_return_locally = false
	root.add_child(route)
	await process_frame
	route.call(&"_set_shop_route_presentation_active", false)
	_expect(
		route.configure_multiplayer_players(
			1,
			{1: "重连玩家"},
			{1: PlayerCharacterRegistry.DEFAULT_CHARACTER_ID},
			{1: "rogue-participant:v1:lease-reattach"}
		),
		"lease 期间必须能重建本地多人路线玩家。"
	)
	await physics_frame
	await process_frame
	_expect_presentation_state(
		route,
		RogueRouteGame.RoutePresentationLease.UNDERGROUND_SHOP,
		false,
		true,
		false,
		"商店 lease 期间重建玩家后"
	)
	_expect(
		route.player != null
		and route.player.visible
		and route.player.body_sprite.visible
		and not route.map_camera.enabled,
		"重建玩家可保持自身可见，但 attach 不能绕过 lease 启用路线相机。"
	)
	route.call(&"_set_shop_route_presentation_active", true)
	await physics_frame
	await process_frame
	_expect_route_camera_and_canvas(route, "lease 期间重建玩家并退出商店后")
	_expect_route_player_visible(route, "lease 期间重建玩家并退出商店后")
	route.queue_free()
	await process_frame


func _test_reconnect_defeat_and_profile_input_ownership() -> void:
	var route := ROUTE_SCENE.instantiate() as RogueRouteGame
	route.auto_initialize = false
	route.manage_return_locally = true
	root.add_child(route)
	await process_frame
	route.set_authority_enabled(false)

	# 迟到加入/重连可能首次快照就是 completed+run_failed；本机没有
	# _encounter_presented_active，也必须直接恢复权威战败层。
	var completed_failure := {
		"occurrence_key": "encounter:reconnect-completed-failure",
		"revision": 7,
		"phase": &"completed",
		"encounter_id": &"",
		"run_failed": true,
	}
	route.call(&"_on_encounter_state_changed", completed_failure)
	await process_frame
	_expect(
		route.run_defeat_overlay.visible
		and bool(route.get("_run_failure_presented"))
		and bool(route.get("_encounter_input_locked"))
		and bool(route.call(&"_is_route_input_locked")),
		"首次即 completed+run_failed 的重连快照必须显示战败层并锁住路线。"
	)

	# 新局/full rewind 通过 encounter reset 只重置败局 owner，不能让旧战败
	# flag 或 Overlay 污染下一次运行。
	route.call(&"_reset_encounter_runtime", false)
	await process_frame
	_expect(
		not route.run_defeat_overlay.visible
		and not bool(route.get("_run_failure_presented"))
		and not bool(route.get("_encounter_input_locked"))
		and not bool(route.call(&"_is_route_input_locked")),
		"遭遇 runtime 重置必须清除上一局战败表现与锁。"
	)

	route.queue_free()
	await process_frame


func _expect_route_camera_and_canvas(
	route: RogueRouteGame,
	context: String
) -> void:
	var camera := route.map_camera
	var viewport := route.get_viewport()
	var viewport_center := route.get_viewport_rect().size * 0.5
	var canvas_world_center := (
		viewport.get_canvas_transform().affine_inverse() * viewport_center
	)
	var camera_center := camera.get_screen_center_position()
	_expect(
		camera.enabled
		and camera.get_parent() == route.player
		and viewport.get_camera_2d() == camera
		and canvas_world_center.distance_to(camera_center) <= 0.51
		and not canvas_world_center.is_equal_approx(Vector2(128.0, 128.0)),
		(
			"%s必须让路线相机成为 current，并立即清除战斗相机 (128,128) 的 Canvas 变换。"
			% context
		)
	)


func _send_bag_action() -> void:
	var pressed := InputEventAction.new()
	pressed.action = &"bag"
	pressed.pressed = true
	Input.parse_input_event(pressed)
	await process_frame
	var released := InputEventAction.new()
	released.action = &"bag"
	released.pressed = false
	Input.parse_input_event(released)
	await process_frame


func _expect_presentation_state(
	route: RogueRouteGame,
	expected_leases: int,
	expected_world_visible: bool,
	expected_hud_visible: bool,
	expected_bottom_bar_visible: bool,
	context: String
) -> void:
	var bottom_bar := route.get_node("HUD/Root/BottomBar") as Control
	_expect(
		int(route.get("_route_presentation_leases")) == expected_leases
		and route.world.visible == expected_world_visible
		and route.world.process_mode == (
			Node.PROCESS_MODE_INHERIT
			if expected_world_visible
			else Node.PROCESS_MODE_DISABLED
		)
		and route.route_hud.visible == expected_hud_visible
		and bottom_bar.visible == expected_bottom_bar_visible
		and route.map_camera.enabled == expected_world_visible,
		"%s的 World/HUD/BottomBar/Camera/process 必须完全由 lease owner 推导。"
		% context
	)


func _expect_route_player_visible(route: RogueRouteGame, context: String) -> void:
	_expect(
		route.player != null
		and route.player.visible
		and route.player.body_sprite.visible
		and route.player.is_visible_in_tree(),
		"%s必须恢复路线玩家主体可见性。" % context
	)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
