extends SceneTree

const ROUTE_SCENE := preload(
	"res://scene/test_arena/test_rogue_route_p3.tscn"
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

	var host := ROUTE_SCENE.instantiate() as TestRogueRouteP3
	host.auto_initialize = false
	host.manage_return_locally = false
	root.add_child(host)
	await process_frame
	_expect(
		host.start_authoritative_session(int(fixture["seed"]), false),
		"房主路线必须能以夹具种子启动。"
	)
	await process_frame

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
	var runtime := host.get("_runtime_state") as RogueRouteRuntimeState
	var graph := host.get("_route_graph") as RogueRouteGraph
	var initial_state := host.export_state_snapshot()
	var layout_snapshot := host.export_layout_snapshot()
	var start_node_id := runtime.current_node_id
	var combat_node_id := int(fixture["combat_node_id"])
	var revision := runtime.state_revision
	_expect(
		runtime.try_move(
			combat_node_id,
			host.generation_config.move_action_cost,
			revision
		),
		"权威移动进入普通作战节点必须成功。"
	)
	_expect(host_starts.size() == 1, "每次权威进入普通作战节点必须发出一次请求。")
	if host_starts.is_empty():
		_cleanup_route(host)
		_finish()
		return
	var first_start := host_starts[0]
	var first_key := str(first_start["occurrence_key"])
	var content_seed := graph.get_node_content_seed(combat_node_id)
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

	var client := ROUTE_SCENE.instantiate() as TestRogueRouteP3
	client.auto_initialize = false
	client.manage_return_locally = false
	root.add_child(client)
	await process_frame
	client.start_client_waiting()
	_expect(
		client.apply_full_snapshot(layout_snapshot, host.export_state_snapshot()),
		"客户端必须先接受当前路线全量快照。"
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

	var world := client.get_node("World") as Node2D
	var hud := client.get_node("HUD") as CanvasLayer
	var confirmation_visible := client.move_confirmation.visible
	var encounter_visible := client.encounter_overlay.visible
	var camera_enabled := client.map_camera.enabled
	client.set_route_presentation_enabled(false)
	_expect(
		not world.visible
		and not hud.visible
		and not client.move_confirmation.visible
		and not client.encounter_overlay.visible
		and not client.map_camera.enabled,
		"关闭路线表现时必须原生隐藏地图、HUD、两个模态层并关闭路线相机。"
	)
	client.set_route_presentation_enabled(true)
	_expect(
		world.visible
		and hud.visible
		and client.move_confirmation.visible == confirmation_visible
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
		host_starts.size() == 2
		and str(host_starts[1]["occurrence_key"]) == (
			"combat:%s:%d:%d:2" % [
				graph.compute_layout_hash(),
				combat_node_id,
				content_seed,
			]
		),
		"同节点再次访问必须生成访问次数为2的新 occurrence。"
	)
	var second_key := (
		str(host_starts[1]["occurrence_key"])
		if host_starts.size() >= 2
		else ""
	)
	_expect(
		host.complete_normal_combat(second_key),
		"房主必须能完成第二次作战阶段。"
	)
	host.normal_combat_requested.disconnect(host_combat_consumer)
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
		host_starts.size() == 2
		and not host.is_encounter_active()
		and not bool(host.route_board.get("_interaction_locked")),
		"没有 normal_combat_requested 消费者时不得进入状态或锁死测试地图。"
	)

	_cleanup_route(client)
	_cleanup_route(host)
	await process_frame
	_finish()


func _test_result_overlay(route: TestRogueRouteP3) -> void:
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


func _cleanup_route(route: TestRogueRouteP3) -> void:
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
