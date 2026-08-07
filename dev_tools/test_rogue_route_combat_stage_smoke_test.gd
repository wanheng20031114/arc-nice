extends SceneTree

const ROUTE_SCENE := preload(
	"res://scene/game_modes/rogue/route/rogue_route_game.tscn"
)
const GENERATION_CONFIG := preload(
	"res://resources/config/rogue_route/p3_generation_config.tres"
)
const MAX_SEED_SEARCH := 2048

var _failures: Array[String] = []


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	var fixture := _find_adjacent_normal_combat_fixture()
	_expect(not fixture.is_empty(), "测试种子范围内必须存在与起点相邻的普通作战节点。")
	if fixture.is_empty():
		_finish()
		return

	var host := ROUTE_SCENE.instantiate() as RogueRouteGame
	host.auto_initialize = false
	host.manage_return_locally = false
	root.add_child(host)
	await process_frame
	_expect(
		host.start_authoritative_session(int(fixture["seed"]), false),
		"房主路线必须能以夹具种子启动。"
	)
	await process_frame
	# 路线展开演出由专项测试覆盖；本用例只验证作战阶段持有的输入锁。
	host.route_board.complete_entry_reveal()

	var host_starts: Array[Dictionary] = []
	var host_combat_consumer := (
		func(node_id: int, content_seed: int, occurrence_key: String) -> void:
			host_starts.append({
				"node_id": node_id,
				"content_seed": content_seed,
				"occurrence_key": occurrence_key,
			})
	)
	host.normal_combat_requested.connect(host_combat_consumer)
	var host_cover_commits: Array[bool] = []
	var host_cover_consumer := (
		func(
			occurrence_key: String,
			briefing_revision: int,
			expected_route_revision: int
		) -> void:
			host_cover_commits.append(host.host_commit_briefed_move(
				occurrence_key,
				briefing_revision,
				expected_route_revision
			))
	)
	host.briefing_cover_completed.connect(host_cover_consumer)
	var runtime := host.get("_runtime_state") as RogueRouteRuntimeState
	var graph := host.get("_route_graph") as RogueRouteGraph
	var initial_state := host.export_state_snapshot()
	var layout_snapshot := host.export_layout_snapshot()
	var start_node_id := runtime.current_node_id
	var combat_node_id := int(fixture["combat_node_id"])
	var content_seed := graph.get_node_content_seed(combat_node_id)

	# 第一次打开只验证取消事务：路线本体字段必须完全不动，只有简报 revision
	# 从 PRESENTED 推进到 NONE。
	host.call(&"_on_route_board_node_pressed", combat_node_id)
	var first_presented_state := host.export_state_snapshot()
	var first_presented_briefing := (
		first_presented_state["briefing_state"] as Dictionary
	)
	_expect(
		host.node_briefing.visible
		and not host.move_confirmation.visible
		and int(first_presented_briefing["phase"])
		== RogueRouteGame.BriefingPhase.PRESENTED
		and int(first_presented_briefing["node_id"]) == combat_node_id
		and int(first_presented_briefing["expected_route_revision"])
		== int(initial_state["revision"]),
		"普通作战点击必须只打开新简报，并记录待提交的路线 revision。"
	)
	_expect(
		_same_route_runtime_fields(first_presented_state, initial_state),
		"简报 PRESENTED 前后 AP、路线 revision、当前位置和 visits 必须不变。"
	)
	host.node_briefing.cancel_button.pressed.emit()
	await process_frame
	var canceled_state := host.export_state_snapshot()
	var canceled_briefing := canceled_state["briefing_state"] as Dictionary
	_expect(
		_same_route_runtime_fields(canceled_state, initial_state)
		and int(canceled_briefing["phase"])
		== RogueRouteGame.BriefingPhase.NONE
		and int(canceled_briefing["revision"])
		== int(first_presented_briefing["revision"]) + 1
		and not host.node_briefing.visible
		and not host.move_confirmation.visible,
		"取消普通作战简报必须只关闭待决状态，不扣 AP、不移动或增加 visits。"
	)

	# 第二次打开用于全量快照与确认防重验证。
	host.call(&"_on_route_board_node_pressed", combat_node_id)
	var presented_state := host.export_state_snapshot()
	var presented_briefing := presented_state["briefing_state"] as Dictionary
	_expect(
		_same_route_runtime_fields(presented_state, initial_state)
		and host.node_briefing.visible
		and not host.move_confirmation.visible
		and int(presented_briefing["phase"])
		== RogueRouteGame.BriefingPhase.PRESENTED,
		"再次点击普通作战必须恢复唯一的新简报，不提前提交路线移动。"
	)

	var client := ROUTE_SCENE.instantiate() as RogueRouteGame
	client.auto_initialize = false
	client.manage_return_locally = false
	root.add_child(client)
	await process_frame
	client.start_client_waiting()
	_expect(
		client.apply_full_snapshot(layout_snapshot, presented_state),
		"PRESENTED 全量快照必须在客户端恢复普通作战简报。"
	)
	_expect(
		client.node_briefing.visible
		and not client.node_briefing.can_decide()
		and not client.move_confirmation.visible
		and client.export_briefing_state_snapshot() == presented_briefing,
		"客户端必须显示只读等待态简报，并保持旧确认框隐藏。"
	)
	_expect(
		client.apply_full_snapshot(layout_snapshot, presented_state),
		"完全相同的 PRESENTED 全量快照必须幂等接受。"
	)
	_expect(
		not client.apply_full_snapshot(layout_snapshot, initial_state),
		"当前路线未回滚时，旧简报 revision 的全量包必须被拒绝。"
	)
	var conflicting_state := presented_state.duplicate(true)
	var conflicting_briefing := (
		conflicting_state["briefing_state"] as Dictionary
	)
	conflicting_briefing["phase"] = RogueRouteGame.BriefingPhase.ENTERING
	_expect(
		not client.apply_full_snapshot(layout_snapshot, conflicting_state),
		"相同简报 revision 但内容冲突的全量包必须被拒绝。"
	)
	_expect(
		client.apply_briefing_state_snapshot(
			initial_state["briefing_state"] as Dictionary
		)
		and client.apply_briefing_state_snapshot(presented_briefing)
		and not client.apply_briefing_state_snapshot(conflicting_briefing)
		and client.export_briefing_state_snapshot() == presented_briefing
		and client.node_briefing.visible,
		"低层简报同步必须忽略旧包、幂等接受同包并拒绝同 revision 冲突。"
	)

	var state_before_confirm := host.export_state_snapshot()
	host.node_briefing.confirm_button.pressed.emit()
	host.node_briefing.confirm_button.pressed.emit()
	await process_frame
	var entering_pre_move_state := host.export_state_snapshot()
	var entering_pre_move_briefing := (
		entering_pre_move_state["briefing_state"] as Dictionary
	)
	_expect(
		_same_route_runtime_fields(entering_pre_move_state, state_before_confirm)
		and int(entering_pre_move_briefing["phase"])
		== RogueRouteGame.BriefingPhase.ENTERING
		and int(entering_pre_move_briefing["revision"])
		== int(presented_briefing["revision"]) + 1
		and not host.node_briefing.visible
		and not host.move_confirmation.visible,
		"双击确认只能提交一次 ENTERING；遮盖完成前路线本体不得变化。"
	)
	_expect(
		client.apply_full_snapshot(layout_snapshot, entering_pre_move_state)
		and int(client.export_briefing_state_snapshot()["phase"])
		== RogueRouteGame.BriefingPhase.ENTERING
		and not client.node_briefing.visible,
		"移动提交前的 ENTERING 全量快照必须同步关闭客户端简报并开始遮盖。"
	)
	await create_timer(RogueSceneTransition.COVER_DURATION_SECONDS + 0.08).timeout
	var entering_post_move_state := host.export_state_snapshot()
	var entering_post_move_briefing := (
		entering_post_move_state["briefing_state"] as Dictionary
	)
	_expect(
		int(entering_post_move_briefing["phase"])
		== RogueRouteGame.BriefingPhase.ENTERING,
		"遮盖后、准备屏障完成前，简报状态必须保持 ENTERING。"
	)
	_expect(
		int(entering_post_move_state["revision"])
		== int(initial_state["revision"]) + 1
		and int(entering_post_move_state["action_points"])
		== int(initial_state["action_points"])
		- host.generation_config.move_action_cost
		and int(entering_post_move_state["current_node_id"])
		== combat_node_id
		and _visit_count(entering_post_move_state, combat_node_id)
		== _visit_count(initial_state, combat_node_id) + 1,
		(
			"遮盖后确认必须只提交一次路线移动、扣一次 AP 并增加一次 visits；"
			+ "实际 revision=%d AP=%d current=%d visits=%d cover=%.3f。"
		) % [
			int(entering_post_move_state["revision"]),
			int(entering_post_move_state["action_points"]),
			int(entering_post_move_state["current_node_id"]),
			_visit_count(entering_post_move_state, combat_node_id),
			host.combat_scene_transition.progress,
		]
	)
	_expect(
		host_cover_commits == [true] and host_starts.size() == 1,
		(
			"遮盖后必须且只能提交一次权威移动并发出一次作战启动；"
			+ "实际 cover commits=%s，starts=%d。"
		) % [host_cover_commits, host_starts.size()]
	)
	if host_starts.is_empty():
		_cleanup_route(client)
		_cleanup_route(host)
		_finish()
		return
	var first_start := host_starts[0]
	var first_key := str(first_start["occurrence_key"])
	_expect(
		not host.host_commit_briefed_move(
			str(entering_post_move_briefing["occurrence_key"]),
			int(entering_post_move_briefing["revision"]),
			int(entering_post_move_briefing["expected_route_revision"])
		)
		and host.export_state_snapshot() == entering_post_move_state,
		"相同 ENTERING tuple 的重复 cover-ready 不得再次扣 AP 或提交路线。"
	)
	_expect(
		host.is_normal_combat_active()
		and host.is_encounter_active()
		and first_key == "combat:%s:%d:%d:1" % [
			graph.compute_layout_hash(),
			combat_node_id,
			content_seed,
		],
		"房主必须用布局、节点、内容种子与访问次数构造确定 occurrence。"
	)
	_expect(
		bool(host.route_board.get("_interaction_locked")),
		"普通作战开始后必须锁定路线输入。"
	)
	_expect(
		client.apply_full_snapshot(layout_snapshot, entering_post_move_state),
		"路线提交后的 ENTERING 全量快照必须接受已移动状态。"
	)
	_expect(
		not client.apply_normal_combat_started(
			combat_node_id,
			content_seed + 1,
			first_key
		)
		and not client.apply_normal_combat_started(
			start_node_id,
			content_seed,
			first_key
		)
		and not client.apply_normal_combat_started(
			combat_node_id,
			content_seed,
			first_key.left(-1) + "2"
		),
		"客户端必须拒绝伪造的节点、内容种子与访问次数 occurrence。"
	)
	_expect(
		client.apply_normal_combat_started(
			combat_node_id,
			content_seed,
			first_key
		)
		and client.apply_normal_combat_started(
			combat_node_id,
			content_seed,
			first_key
		),
		"客户端必须接受严格匹配的启动数据并幂等接受重放。"
	)
	_expect(
		host.complete_briefing_entry(first_key),
		"房主在战场准备完成后必须结束权威 ENTERING 状态。"
	)
	var completed_briefing := host.export_briefing_state_snapshot()
	_expect(
		int(completed_briefing["phase"])
		== RogueRouteGame.BriefingPhase.NONE
		and client.apply_briefing_state_snapshot(completed_briefing)
		and int(client.export_briefing_state_snapshot()["phase"])
		== RogueRouteGame.BriefingPhase.NONE,
		"准备屏障结束后，双方简报状态必须收敛到 NONE。"
	)

	var world := client.get_node("World") as Node2D
	var hud := client.get_node("HUD") as CanvasLayer
	var confirmation_visible := client.move_confirmation.visible
	var briefing_visible := client.node_briefing.visible
	var encounter_visible := client.encounter_overlay.visible
	var camera_enabled := client.map_camera.enabled
	client.set_route_presentation_enabled(false)
	_expect(
		not world.visible
		and not hud.visible
		and not client.move_confirmation.visible
		and not client.node_briefing.visible
		and not client.encounter_overlay.visible
		and not client.map_camera.enabled,
		"关闭路线表现时必须隐藏地图、HUD、旧确认框、简报、遭遇层与路线相机。"
	)
	client.set_route_presentation_enabled(true)
	_expect(
		world.visible
		and hud.visible
		and client.move_confirmation.visible == confirmation_visible
		and client.node_briefing.visible == briefing_visible
		and client.encounter_overlay.visible == encounter_visible
		and client.map_camera.enabled == camera_enabled,
		"恢复路线表现时必须还原原可见状态，不重建或误开模态层。"
	)

	_test_result_overlay(client)
	_expect(
		not client.complete_normal_combat(first_key + ":wrong")
		and client.is_normal_combat_active(),
		"错误 occurrence 不得结束客户端作战阶段。"
	)
	_expect(
		client.complete_normal_combat(first_key)
		and not client.is_encounter_active(),
		"匹配 occurrence 必须结束作战阶段并解锁路线。"
	)

	# 重新应用同一当前访问 occurrence 后用旧 revision 全量快照回滚，
	# 验证断线重同步不会留下战斗锁或隐藏的路线表现。
	_expect(
		client.apply_normal_combat_started(
			combat_node_id,
			content_seed,
			first_key
		),
		"回滚夹具必须能重新进入当前作战阶段。"
	)
	client.set_route_presentation_enabled(false)
	_expect(
		client.apply_full_snapshot(layout_snapshot, initial_state),
		"客户端必须接受同布局的较旧全量状态作为显式回滚。"
	)
	_expect(
		not client.is_normal_combat_active()
		and not client.is_encounter_active()
		and world.visible
		and hud.visible
		and client.map_camera.enabled == camera_enabled,
		"全量快照回滚必须清理战斗锁并恢复路线表现。"
	)

	_expect(host.complete_normal_combat(first_key), "房主必须能完成首次作战阶段。")
	_expect(
		runtime.try_move(
			start_node_id,
			host.generation_config.move_action_cost,
			runtime.state_revision
		)
		and runtime.try_move(
			combat_node_id,
			host.generation_config.move_action_cost,
			runtime.state_revision
		),
		"房主必须能离开并再次进入同一普通作战节点。"
	)
	_expect(
		host_starts.size() == 1
		and not host.is_normal_combat_active()
		and not host.is_encounter_active(),
		"已走过的普通作战节点只能作为普通移动目标，不能生成第二份简报或作战 occurrence。"
	)
	host.normal_combat_requested.disconnect(host_combat_consumer)
	host.briefing_cover_completed.disconnect(host_cover_consumer)
	_expect(
		runtime.try_move(
			start_node_id,
			host.generation_config.move_action_cost,
			runtime.state_revision
		)
		and runtime.try_move(
			combat_node_id,
			host.generation_config.move_action_cost,
			runtime.state_revision
		),
		"无协调器夹具仍必须能移动进入普通作战节点。"
	)
	_expect(
		host_starts.size() == 1
		and not host.is_encounter_active()
		and not bool(host.route_board.get("_interaction_locked")),
		"重复进入已走过作战节点时，即使没有 normal_combat_requested 消费者也不得进入状态或锁死测试地图。"
	)

	_cleanup_route(client)
	_cleanup_route(host)
	await process_frame
	_finish()


func _test_result_overlay(route: RogueRouteGame) -> void:
	var common_items := CollectibleRegistry.get_by_rarity(
		PickupConfig.CollectibleRarity.COMMON
	)
	_expect(not common_items.is_empty(), "结算展示测试需要普通收藏品配置。")
	if common_items.is_empty():
		return
	var item := common_items[0] as PickupConfig
	var dismissed_events: Array[bool] = []
	route.combat_result_dismissed.connect(
		func() -> void: dismissed_events.append(true)
	)
	_expect(
		route.show_combat_result({
			"victory": true,
			"extra_xirang": 500,
			"loot": {
				"config_path": item.resource_path,
				"granted": false,
				"failure_reason": &"inventory_full",
			},
		}),
		"路线必须能把权威胜利结算转换为结果面板。"
	)
	_expect(
		route.combat_result_overlay.visible
		and route.combat_result_overlay.result_title_label.text == "通过作战"
		and route.combat_result_overlay.extra_xirang_value_label.text == "+500"
		and route.combat_result_overlay.loot_name_label.text == item.display_name
		and route.combat_result_overlay.loot_icon_rect.texture == item.icon_texture
		and route.combat_result_overlay.loot_status_label.text.contains("背包已满"),
		"胜利面板必须展示额外息壤、配置图标与满包失效状态。"
	)
	route.combat_result_overlay.close_button.pressed.emit()
	_expect(dismissed_events.size() == 1, "关闭结果面板必须向路线协调器转发 dismissed。")
	_expect(
		route.show_combat_result({
			"victory": false,
			"failure_reason": "作战时间耗尽",
		})
		and route.combat_result_overlay.result_title_label.text == "作战失败"
		and route.combat_result_overlay.result_subtitle_label.text == "作战时间耗尽",
		"失败面板必须展示权威失败原因。"
	)
	route.hide_combat_result()
	_expect(not route.combat_result_overlay.visible, "路线必须能主动隐藏结果面板。")


func _find_adjacent_normal_combat_fixture() -> Dictionary:
	for seed in range(1, MAX_SEED_SEARCH + 1):
		var graph := RogueRouteGenerator.generate(GENERATION_CONFIG, seed)
		if graph == null:
			continue
		for neighbor_id in graph.get_neighbors(graph.start_node_id):
			if graph.get_node_type(neighbor_id) == RogueRouteGraph.NodeType.NORMAL_COMBAT:
				return {
					"seed": seed,
					"combat_node_id": int(neighbor_id),
				}
	return {}


func _same_route_runtime_fields(first: Dictionary, second: Dictionary) -> bool:
	return (
		int(first.get("revision", -1)) == int(second.get("revision", -1))
		and int(first.get("current_node_id", -1))
		== int(second.get("current_node_id", -1))
		and int(first.get("action_points", -1))
		== int(second.get("action_points", -1))
		and first.get("visited_counts") == second.get("visited_counts")
	)


func _visit_count(snapshot: Dictionary, node_id: int) -> int:
	var visits := snapshot.get("visited_counts") as PackedInt32Array
	if node_id < 0 or node_id >= visits.size():
		return -1
	return int(visits[node_id])


func _cleanup_route(route: RogueRouteGame) -> void:
	if route == null:
		return
	if route.get_parent() != null:
		route.get_parent().remove_child(route)
	route.free()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)


func _finish() -> void:
	if _failures.is_empty():
		print("TEST_ROGUE_ROUTE_COMBAT_STAGE_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in _failures:
		push_error(failure)
	quit(1)
