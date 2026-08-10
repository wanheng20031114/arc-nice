extends SceneTree

const ROUTE_SCENE := preload(
	"res://scene/game_modes/rogue/route/rogue_route_game.tscn"
)
const WRAPPER_SCENE := preload("res://scene/multiplayer/mp_rogue_route.tscn")
const GENERATION_CONFIG := preload(
	"res://resources/config/rogue_route/p3_generation_config.tres"
)
const MAX_SEED_SEARCH := 8192
const HOST_PEER_ID := 7
const CLIENT_PEER_ID := 8


class FakeHostNetManager:
	extends NetManagerStore


	func _init() -> void:
		host_peer_id = HOST_PEER_ID
		connected_players = {
			HOST_PEER_ID: "Host",
			CLIENT_PEER_ID: "Client",
		}
		connection_state = NetManagerStore.ConnectionState.IN_GAME


	func get_host_peer_id() -> int:
		return host_peer_id


	func is_host() -> bool:
		return true


	func is_client() -> bool:
		return false


	func is_peer_send_ready(peer_id: int) -> bool:
		return peer_id == CLIENT_PEER_ID


var _failures: Array[String] = []


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	var suitcase_fixture := _find_adjacent_suitcase_fixture()
	var normal_fixture := _find_adjacent_normal_combat_fixture()
	_expect(
		not suitcase_fixture.is_empty(),
		"测试种子范围内必须存在起点相邻、且内容为疯穿箱子的神奇遭遇节点。"
	)
	_expect(
		not normal_fixture.is_empty(),
		"测试种子范围内必须存在起点相邻的普通作战节点。"
	)
	if suitcase_fixture.is_empty() or normal_fixture.is_empty():
		_finish()
		return

	await _test_suitcase_followup_route_contract(suitcase_fixture)
	await _test_normal_combat_schema_two_compatibility(normal_fixture)
	_finish()


func _test_suitcase_followup_route_contract(fixture: Dictionary) -> void:
	var host := _new_route(true)
	await process_frame
	_expect(
		host.start_authoritative_session(int(fixture["seed"]), false),
		"疯穿箱子路线夹具必须能启动 Host 权威会话。"
	)
	host.route_board.complete_entry_reveal()
	var runtime := host.get("_runtime_state") as RogueRouteRuntimeState
	var graph := host.get("_route_graph") as RogueRouteGraph
	var encounter_node_id := int(fixture["encounter_node_id"])
	# 本 smoke 直接驱动权威 Session，不播放已由视觉测试覆盖的异步遭遇转场，
	# 以免测试退出时遗留仍在等待 Tween 的 GDScriptFunctionState。
	var encounter_state_callback := Callable(
		host,
		"_on_encounter_state_changed"
	)
	if host.encounter_session.state_changed.is_connected(
		encounter_state_callback
	):
		host.encounter_session.state_changed.disconnect(
			encounter_state_callback
		)
	_expect(
		runtime.try_move(
			encounter_node_id,
			host.generation_config.move_action_cost,
			runtime.state_revision
		),
		"Host 必须能首次进入疯穿箱子节点。"
	)
	var session := host.encounter_session
	_expect(
		session.get_phase() == RogueEncounterSession.PHASE_INTRO
		and StringName(session.export_state().get("encounter_id", &""))
		== RogueEncounterRegistry.SUITCASE_FRENZY,
		"首次进入夹具节点必须启动疯穿箱子的权威 intro。"
	)
	var source_occurrence_key := session.get_occurrence_key()
	_expect(
		session.submit_intro_ack(
			0,
			source_occurrence_key,
			session.get_revision()
		)
		and session.submit_vote(
			0,
			source_occurrence_key,
			session.get_revision(),
			RogueEncounterRegistry.OPTION_CLAIM_SUITCASE
		),
		"单人 Host 必须能完成开场确认并选择“箱子是我的！”。"
	)
	var result_state := session.export_state()
	_expect(
		session.get_phase() == RogueEncounterSession.PHASE_RESULT
		and session.submit_result_ack(
			0,
			source_occurrence_key,
			int(result_state.get("result_sequence", -1))
		),
		"机器人注意到玩家的结果页必须经 ACK 才进入 completed。"
	)
	var completed_state := session.export_state()
	_expect(
		StringName(completed_state.get("phase", &""))
		== RogueEncounterSession.PHASE_COMPLETED
		and StringName(completed_state.get("winning_option", &""))
		== RogueEncounterRegistry.OPTION_CLAIM_SUITCASE
		and StringName((completed_state.get(
			"economy_result",
			{}
		) as Dictionary).get("followup_combat_id", &""))
		== &"suitcase_battle",
		"只有 option1 completed 状态可以携带 suitcase_battle 跟随作战。"
	)

	# option2/3 的真实内容合同已经由 Encounter smoke 覆盖；路线层必须仅凭
	# completed 结果中的显式 followup 字段决定是否创建强制作战简报。
	var option_two_state := _without_followup(
		completed_state,
		RogueEncounterRegistry.OPTION_JOIN_SUITCASE_SHOOTING,
		RogueEncounterEconomyCoordinator.RESULT_SUITCASE_DESTROYED
	)
	var option_three_state := _without_followup(
		completed_state,
		RogueEncounterRegistry.OPTION_IGNORE_SUITCASE,
		RogueEncounterEconomyCoordinator.RESULT_SUITCASE_LEFT
	)
	_expect(
		not bool(host.call(
			"_try_present_followup_combat_briefing",
			option_two_state
		))
		and not bool(host.call(
			"_try_present_followup_combat_briefing",
			option_three_state
		))
		and int(host.export_briefing_state_snapshot().get("phase", -1))
		== RogueRouteGame.BriefingPhase.NONE,
		"凑热闹与安全离开 completed 状态都不得触发任何作战简报。"
	)

	# 模拟独立遭遇场景完全退出后的边界：路线画面先恢复，再展示不可取消简报。
	host.encounter_scene.hide_immediately()
	host.call("_set_route_presentation_active", true)
	host.set("_encounter_presented_active", false)
	var action_points_before_briefing := runtime.action_points
	var route_revision_before_briefing := runtime.state_revision
	_expect(
		bool(host.call(
			"_try_present_followup_combat_briefing",
			completed_state
		)),
		"option1 completed 状态必须在路线恢复后创建唯一的皮箱之战简报。"
	)
	var presented_state := host.export_state_snapshot()
	var presented := presented_state.get("briefing_state", {}) as Dictionary
	_expect(
		int(presented.get("schema_version", -1)) == 2
		and int(presented.get("phase", -1))
		== RogueRouteGame.BriefingPhase.PRESENTED
		and StringName(presented.get("source_kind", &""))
		== RogueRouteNodeBriefingModel.SOURCE_KIND_SPECIAL_COMBAT
		and StringName(presented.get("combat_config_id", &""))
		== &"suitcase_battle"
		and str(presented.get("source_encounter_occurrence_key", ""))
		== source_occurrence_key
		and int(presented.get("expected_route_revision", -1))
		== route_revision_before_briefing,
		"schema 2特殊简报必须带齐来源类型、配置 ID、来源 occurrence 与路线 revision。"
	)
	var model := host.call("_build_current_briefing_model") as RogueRouteNodeBriefingModel
	_expect(
		host.world.visible
		and host.route_hud.visible
		and host.node_briefing.visible
		and not host.node_briefing.can_cancel()
		and not host.node_briefing.cancel_button.visible
		and model != null
		and model.action_point_delta == 0
		and model.primary_action_text == "进入作战"
		and runtime.action_points == action_points_before_briefing
		and runtime.state_revision == route_revision_before_briefing,
		"路线恢复后必须显示不可取消、零 AP 的“进入作战”简报，且不得暗改路线。"
	)
	var before_cancel_attempt := host.export_briefing_state_snapshot()
	host.node_briefing.cancel_button.pressed.emit()
	_expect(
		host.export_briefing_state_snapshot() == before_cancel_attempt
		and host.node_briefing.visible,
		"即使伪造隐藏取消按钮信号，强制皮箱之战简报也不得关闭。"
	)

	var layout := host.export_layout_snapshot()
	var encounter_packet := host.export_encounter_snapshot(0)
	var economy_packet := host.export_encounter_economy_snapshot(0)
	var valid_client := _new_route(false)
	var invalid_clients: Array[RogueRouteGame] = []
	for _index in range(12):
		invalid_clients.append(_new_route(false))
	await process_frame
	valid_client.start_client_waiting()
	for client in invalid_clients:
		client.start_client_waiting()
	_expect(
		bool(host.call(
			"_validate_followup_encounter_snapshot",
			encounter_packet,
			encounter_node_id,
			source_occurrence_key,
			&"suitcase_battle"
		)),
		(
			"Host 必须能复算自身合法的皮箱跟随遭遇快照；"
			+ "source=%s seed=%s expected_seed=%s terminal=%s committed=%s failed=%s"
			% [
				source_occurrence_key,
				encounter_packet.get("node_content_seed", -1),
				graph.get_node_content_seed(encounter_node_id),
				encounter_packet.get("terminal_result", null),
				encounter_packet.get("settlement_committed", null),
				encounter_packet.get("run_failed", null),
			]
		)
	)
	_expect(
		valid_client.encounter_session.get_phase()
		== RogueEncounterSession.PHASE_IDLE
		and valid_client.apply_full_snapshot(
			layout,
			presented_state,
			encounter_packet,
			economy_packet
		)
		and valid_client.encounter_session.get_phase()
		== RogueEncounterSession.PHASE_COMPLETED
		and valid_client.node_briefing.visible
		and not valid_client.node_briefing.can_decide(),
		"完整快照必须使用同一包内 completed encounter 预检跟随简报，而非客户端旧 idle 状态。"
	)

	var forged_source_state := presented_state.duplicate(true)
	var forged_source_briefing := (
		forged_source_state["briefing_state"] as Dictionary
	)
	forged_source_briefing["source_encounter_occurrence_key"] = (
		source_occurrence_key + ":forged"
	)
	var forged_config_state := presented_state.duplicate(true)
	var forged_config_briefing := (
		forged_config_state["briefing_state"] as Dictionary
	)
	forged_config_briefing["combat_config_id"] = "narrow_road_01"
	var forged_winner_packet := encounter_packet.duplicate(true)
	forged_winner_packet["winning_option"] = String(
		RogueEncounterRegistry.OPTION_JOIN_SUITCASE_SHOOTING
	)
	var forged_result_packet := encounter_packet.duplicate(true)
	var forged_result := (
		forged_result_packet["economy_result"] as Dictionary
	)
	forged_result["followup_combat_id"] = "narrow_road_01"
	var forged_both_state := presented_state.duplicate(true)
	(forged_both_state["briefing_state"] as Dictionary)["combat_config_id"] = (
		"narrow_road_01"
	)
	var forged_both_packet := encounter_packet.duplicate(true)
	(forged_both_packet["economy_result"] as Dictionary)[
		"followup_combat_id"
	] = "narrow_road_01"
	var forged_code_packet := encounter_packet.duplicate(true)
	(forged_code_packet["economy_result"] as Dictionary)["result_code"] = (
		String(RogueEncounterEconomyCoordinator.RESULT_SUITCASE_DESTROYED)
	)
	var forged_presentation_packet := encounter_packet.duplicate(true)
	(forged_presentation_packet["economy_result"] as Dictionary)[
		"result_presentation"
	] = "immediate"
	var forged_source_occurrence := source_occurrence_key + ":forged"
	var forged_coordinated_source_state := presented_state.duplicate(true)
	var forged_coordinated_briefing := (
		forged_coordinated_source_state["briefing_state"] as Dictionary
	)
	forged_coordinated_briefing["source_encounter_occurrence_key"] = (
		forged_source_occurrence
	)
	forged_coordinated_briefing["occurrence_key"] = str(host.call(
		"_make_followup_combat_occurrence_key",
		encounter_node_id,
		graph.get_node_content_seed(encounter_node_id),
		forged_source_occurrence,
		&"suitcase_battle"
	))
	var forged_coordinated_source_packet := encounter_packet.duplicate(true)
	forged_coordinated_source_packet["occurrence_key"] = forged_source_occurrence
	var forged_terminal_packet := encounter_packet.duplicate(true)
	forged_terminal_packet["terminal_result"] = false
	var forged_settlement_packet := encounter_packet.duplicate(true)
	forged_settlement_packet["settlement_committed"] = false
	var forged_failed_packet := encounter_packet.duplicate(true)
	forged_failed_packet["run_failed"] = true
	var forged_unresolved_packet := encounter_packet.duplicate(true)
	forged_unresolved_packet["resolved_node_ids"] = []
	var invalid_cases := [
		{
			"state": forged_source_state,
			"encounter": encounter_packet,
			"label": "来源 occurrence",
		},
		{
			"state": forged_config_state,
			"encounter": encounter_packet,
			"label": "作战配置",
		},
		{
			"state": presented_state,
			"encounter": forged_winner_packet,
			"label": "option1 winner",
		},
		{
			"state": presented_state,
			"encounter": forged_result_packet,
			"label": "经济结果 followup",
		},
		{
			"state": forged_both_state,
			"encounter": forged_both_packet,
			"label": "同时伪造的作战配置与经济 followup",
		},
		{
			"state": presented_state,
			"encounter": forged_code_packet,
			"label": "经济结果 code",
		},
		{
			"state": presented_state,
			"encounter": forged_presentation_packet,
			"label": "经济结果展示策略",
		},
		{
			"state": forged_coordinated_source_state,
			"encounter": forged_coordinated_source_packet,
			"label": "协同伪造的来源 occurrence",
		},
		{
			"state": presented_state,
			"encounter": forged_terminal_packet,
			"label": "非终局 completed 标记",
		},
		{
			"state": presented_state,
			"encounter": forged_settlement_packet,
			"label": "未提交的遭遇结算",
		},
		{
			"state": presented_state,
			"encounter": forged_failed_packet,
			"label": "失败的遭遇终局",
		},
		{
			"state": presented_state,
			"encounter": forged_unresolved_packet,
			"label": "未消费的来源节点",
		},
	]
	for index in range(invalid_cases.size()):
		var invalid_case := invalid_cases[index] as Dictionary
		_expect(
			not invalid_clients[index].apply_full_snapshot(
				layout,
				invalid_case["state"] as Dictionary,
				invalid_case["encounter"] as Dictionary,
				economy_packet
			),
			"全量快照必须原子拒绝被篡改的%s。" % str(invalid_case["label"])
		)

	var combat_starts: Array[Dictionary] = []
	host.combat_requested.connect(
		func(
			node_id: int,
			content_seed: int,
			occurrence_key: String,
			combat_config_id: StringName
		) -> void:
			combat_starts.append({
				"node_id": node_id,
				"content_seed": content_seed,
				"occurrence_key": occurrence_key,
				"combat_config_id": combat_config_id,
			})
	)
	host.combat_scene_transition.visible = true
	host.call("_on_node_briefing_confirmed")
	var entering := host.export_briefing_state_snapshot()
	_expect(
		int(entering.get("phase", -1))
		== RogueRouteGame.BriefingPhase.ENTERING
		and runtime.action_points == action_points_before_briefing
		and runtime.state_revision == route_revision_before_briefing,
		"确认强制作战只能推进简报到 ENTERING，cover 屏障前 AP 与路线 revision 不变。"
	)

	var wrapper := WRAPPER_SCENE.instantiate() as MpRogueRoute
	var fake_net_manager := FakeHostNetManager.new()
	wrapper.set("_route", host)
	wrapper.set("_net_manager", fake_net_manager)
	wrapper.call("_configure_briefing_cover_barrier", entering)
	var briefing_revision := int(entering.get("revision", -1))
	var combat_occurrence_key := str(entering.get("occurrence_key", ""))
	var expected_route_revision := int(
		entering.get("expected_route_revision", -1)
	)
	var roster_players: Array[Player] = []
	for peer_id in [HOST_PEER_ID, CLIENT_PEER_ID, 99]:
		var roster_player := Player.new()
		roster_players.append(roster_player)
		host.peer_players[peer_id] = roster_player
	_expect(
		bool(wrapper.call(
			"_accept_briefing_cover_ready",
			CLIENT_PEER_ID,
			combat_occurrence_key,
			briefing_revision,
			expected_route_revision
		))
		and not bool(wrapper.call(
			"_accept_briefing_cover_ready",
			CLIENT_PEER_ID,
			combat_occurrence_key,
			briefing_revision,
			expected_route_revision
		))
		and combat_starts.is_empty(),
		"客户端 cover-ready 必须幂等，Host 未 ready 前不能启动皮箱之战。"
	)
	_expect(
		bool(wrapper.call(
			"_accept_briefing_cover_ready",
			HOST_PEER_ID,
			combat_occurrence_key,
			briefing_revision,
			expected_route_revision
		))
		and not bool(wrapper.call(
			"_accept_briefing_cover_ready",
			HOST_PEER_ID,
			combat_occurrence_key,
			briefing_revision,
			expected_route_revision
		))
		and combat_starts.size() == 1
		and StringName(combat_starts[0].get("combat_config_id", &""))
		== &"suitcase_battle"
		and int(combat_starts[0].get("node_id", -1)) == encounter_node_id
		and int(combat_starts[0].get("content_seed", -1))
		== graph.get_node_content_seed(encounter_node_id)
		and runtime.action_points == action_points_before_briefing
		and runtime.state_revision == route_revision_before_briefing,
		"全员 cover-ready 后 Host 必须只启动一次 suitcase_battle，且零 AP、零路线移动。"
	)
	var encounter_participants: Array[int] = [
		HOST_PEER_ID,
		CLIENT_PEER_ID,
		99,
	]
	var encounter_active_peers: Array[int] = [HOST_PEER_ID, CLIENT_PEER_ID]
	var encounter_spectators: Array[int] = [99]
	session._participant_peer_ids = encounter_participants
	session._active_peer_ids = encounter_active_peers
	session._spectator_peer_ids = encounter_spectators
	var frozen_followup_roster := host.get_followup_combat_participant_peer_ids(
		combat_occurrence_key,
		&"suitcase_battle"
	)
	_expect(
		frozen_followup_roster == PackedInt32Array([
			HOST_PEER_ID,
			CLIENT_PEER_ID,
		]),
		(
			"特殊作战必须继承来源遭遇 completed 时仍有效的 active roster；"
			+ "事件开始后迟到的 spectator 不得进入战场或奖励名单；"
			+ "actual=%s node=%s active=%s。"
			% [
				frozen_followup_roster,
				host.get("_normal_combat_node_id"),
				session.export_state().get("active_peer_ids", []),
			]
		)
	)
	for peer_id in [HOST_PEER_ID, CLIENT_PEER_ID, 99]:
		host.peer_players.erase(peer_id)
	for roster_player in roster_players:
		roster_player.free()
	_expect(
		not bool(host.call(
			"_try_present_followup_combat_briefing",
			completed_state
		))
		and combat_starts.size() == 1,
		"已经进入皮箱之战后重放同一 completed 遭遇不得再次启动作战。"
	)

	wrapper.free()
	fake_net_manager.free()
	_cleanup_route(valid_client)
	for client in invalid_clients:
		_cleanup_route(client)
	_cleanup_route(host)
	await process_frame


func _test_normal_combat_schema_two_compatibility(fixture: Dictionary) -> void:
	var host := _new_route(true)
	await process_frame
	_expect(
		host.start_authoritative_session(int(fixture["seed"]), false),
		"普通作战兼容夹具必须能启动 Host 路线。"
	)
	host.route_board.complete_entry_reveal()
	var combat_node_id := int(fixture["combat_node_id"])
	var before := host.export_state_snapshot()
	var unified_starts: Array[Dictionary] = []
	var legacy_starts: Array[bool] = []
	host.combat_requested.connect(
		func(
			node_id: int,
			_content_seed: int,
			_occurrence_key: String,
			combat_config_id: StringName
		) -> void:
			unified_starts.append({
				"node_id": node_id,
				"combat_config_id": combat_config_id,
			})
	)
	host.normal_combat_requested.connect(
		func(
			_node_id: int,
			_content_seed: int,
			_occurrence_key: String
		) -> void:
			legacy_starts.append(true)
	)
	host.call("_on_route_board_node_pressed", combat_node_id)
	var presented := host.export_briefing_state_snapshot()
	_expect(
		int(presented.get("schema_version", -1)) == 2
		and int(presented.get("phase", -1))
		== RogueRouteGame.BriefingPhase.PRESENTED
		and StringName(presented.get("source_kind", &""))
		== RogueRouteNodeBriefingModel.SOURCE_KIND_DEFAULT_COMBAT
		and StringName(presented.get("combat_config_id", &""))
		== &"narrow_road_01"
		and str(presented.get("source_encounter_occurrence_key", "")).is_empty()
		and host.node_briefing.can_cancel(),
		"普通作战必须继续使用 schema 2 default_combat，并保持可取消。"
	)
	host.combat_scene_transition.visible = true
	host.call("_on_node_briefing_confirmed")
	var entering := host.export_briefing_state_snapshot()
	var normal_committed := host.host_commit_briefing_entry(
			str(entering.get("occurrence_key", "")),
			int(entering.get("revision", -1)),
			int(entering.get("expected_route_revision", -1))
		)
	_expect(
		normal_committed
		and unified_starts.size() == 1
		and legacy_starts.size() == 1
		and int(unified_starts[0].get("node_id", -1)) == combat_node_id
		and StringName(unified_starts[0].get("combat_config_id", &""))
		== &"narrow_road_01"
		and int(host.export_state_snapshot().get("action_points", -1))
		== int(before.get("action_points", -1))
		- host.generation_config.move_action_cost,
		"普通狭路相逢仍须同时发出统一/兼容信号，并按原规则移动与扣 AP。"
	)
	_cleanup_route(host)
	await process_frame


func _without_followup(
	completed_state: Dictionary,
	option_id: StringName,
	result_code: StringName
) -> Dictionary:
	var result := completed_state.duplicate(true)
	result["winning_option"] = String(option_id)
	var economy_result := result["economy_result"] as Dictionary
	economy_result["option_id"] = String(option_id)
	economy_result["result_code"] = String(result_code)
	economy_result["followup_combat_id"] = ""
	return result


func _find_adjacent_suitcase_fixture() -> Dictionary:
	for seed in range(1, MAX_SEED_SEARCH + 1):
		var graph := RogueRouteGenerator.generate(GENERATION_CONFIG, seed)
		if graph == null:
			continue
		for neighbor_id in graph.get_neighbors(graph.start_node_id):
			if (
				graph.get_node_type(neighbor_id)
				!= RogueRouteGraph.NodeType.MAGICAL_ENCOUNTER
			):
				continue
			if RogueEncounterRegistry.select_encounter(
				RogueEncounterRegistry.MAGICAL_ENCOUNTER_POOL,
				graph.get_node_content_seed(neighbor_id)
			) == RogueEncounterRegistry.SUITCASE_FRENZY:
				return {
					"seed": seed,
					"encounter_node_id": int(neighbor_id),
				}
	return {}


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


func _new_route(authority: bool) -> RogueRouteGame:
	var route := ROUTE_SCENE.instantiate() as RogueRouteGame
	route.auto_initialize = false
	route.manage_return_locally = false
	root.add_child(route)
	if not authority:
		route.set_authority_enabled(false)
	return route


func _cleanup_route(route: RogueRouteGame) -> void:
	if route == null or not is_instance_valid(route):
		return
	if route.get_parent() != null:
		route.get_parent().remove_child(route)
	route.free()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)


func _finish() -> void:
	if _failures.is_empty():
		print("ROGUE_SUITCASE_FOLLOWUP_ROUTE_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in _failures:
		push_error(failure)
	quit(1)
