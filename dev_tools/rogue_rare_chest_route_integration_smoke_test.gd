extends SceneTree

const ROUTE_SCENE: PackedScene = preload(
	"res://scene/game_modes/rogue/route/rogue_route_game.tscn"
)

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var run_state := root.get_node_or_null("RunState") as RunStateStore
	if run_state == null:
		run_state = RunStateStore.new()
		run_state.name = "RunState"
		root.add_child(run_state)
	run_state.begin_new_run(PlayerCharacterRegistry.DEFAULT_CHARACTER_ID, false)
	var route := ROUTE_SCENE.instantiate() as RogueRouteGame
	route.auto_initialize = false
	route.manage_return_locally = true
	root.add_child(route)
	await process_frame
	_expect(
		route.start_authoritative_session(0x7A2E, false),
		"稀有宝箱路线集成测试必须能建立权威路线。"
	)
	var valid_options := route.rare_chest_economy.get_valid_option_ids(0)
	var selected_seed := -1
	for seed_value in range(512):
		if RogueRareChestRegistry.select_options(
			seed_value,
			"singleplayer:local",
			valid_options
		).has(RogueRareChestRegistry.OPTION_MAX_HEALTH):
			selected_seed = seed_value
			break
	_expect(selected_seed >= 0, "测试必须找到包含生命强化的稳定 seed。")
	_expect(
		route.rare_chest_session.start_for_node(
			77,
			selected_seed,
			[0],
			{0: "singleplayer:local"}
		),
		"RareChest Session 必须能作为路线原生节点启动。"
	)
	var public_state := route.export_encounter_snapshot()
	var private_state := route.export_encounter_snapshot(0)
	var public_rare := public_state.get("rare_chest_state", {}) as Dictionary
	var private_rare := private_state.get("rare_chest_state", {}) as Dictionary
	_expect(
		(public_rare.get("local_option_ids", []) as Array).is_empty()
		and (private_rare.get("local_option_ids", []) as Array).size() == 3
		and route.is_encounter_active(),
		"公共路线快照必须脱敏，目标 peer 快照才可携带三项私人候选并锁定路线。"
	)
	var public_economy_before := route.export_encounter_economy_snapshot()
	_expect(
		(public_economy_before.get("rare_chest_economy", {}) as Dictionary)
		.get("settled_choices", []).is_empty(),
		"未结算的公共 RareChest Economy 快照不得携带私人记录。"
	)
	var health_before := 0
	if route.player != null:
		route.player.current_health = maxi(route.player.max_health - 20, 1)
		health_before = route.player.current_health
	var status_revision_before := run_state.get_party_status_ledger_revision()
	_expect(
		route.host_submit_encounter_vote(
			0,
			str(private_rare["occurrence_key"]),
			int(private_rare["offer_revision"]),
			RogueRareChestRegistry.OPTION_MAX_HEALTH
		),
		"既有 encounter vote RPC 入口必须分派到 RareChest 私人选择事务。"
	)
	_expect(
		route.rare_chest_session.get_phase()
		== RogueRareChestSession.PHASE_COMPLETED
		and route.rare_chest_session.is_node_resolved(77)
		and run_state.get_player_stat_bonus_value(0, &"max_health") == 10
		and run_state.get_party_status_ledger_revision()
		== status_revision_before + 1,
		"单人选择必须原子提交一次永久属性并完成节点。"
	)
	_expect(
		route.rare_chest_overlay.visible,
		"全员完成后必须短暂保留权威选中结果，不能同帧关闭界面。"
	)
	if route.player != null:
		_expect(
			route.player.current_health == health_before + 10,
			"生命值永久强化必须在账本成功后为目标玩家回复10点生命值。"
		)
	var private_economy := route.export_encounter_economy_snapshot(0)
	var public_economy := route.export_encounter_economy_snapshot()
	_expect(
		(private_economy.get("rare_chest_economy", {}) as Dictionary)
		.get("settled_choices", []).size() == 1
		and (public_economy.get("rare_chest_economy", {}) as Dictionary)
		.get("settled_choices", []).is_empty(),
		"结算后仅目标 peer 的经济快照可见私人结果，公共快照仍需脱敏。"
	)
	_expect(
		not route.rare_chest_session.start_for_node(
			77,
			selected_seed,
			[0],
			{0: "singleplayer:local"}
		),
		"稀有宝箱回访不得重新生成候选或重复结算。"
	)
	await create_timer(0.85).timeout
	_expect(
		not route.rare_chest_overlay.visible,
		"权威选中结果展示完成后必须自动关闭稀有宝箱界面。"
	)
	var completed_replay := route.rare_chest_session.export_state_for_peer(0)
	route.call("_on_rare_chest_state_changed", completed_replay)
	_expect(
		not route.rare_chest_overlay.visible,
		"completed 同 revision 重放不得重新打开已关闭的稀有宝箱界面。"
	)
	_test_client_health_reward_reconciliation(route)

	route.queue_free()
	await process_frame
	_finish()


func _test_client_health_reward_reconciliation(route: RogueRouteGame) -> void:
	if route.player == null:
		_expect(false, "客户端生命奖励回归需要本地 Player。")
		return
	route.set_authority_enabled(false)
	route.player.current_health = maxi(route.player.max_health - 20, 1)
	var health_before := route.player.current_health
	var choosing := {
		"phase": String(RogueRareChestSession.PHASE_CHOOSING),
		"occurrence_key": "client:seen:rare_chest",
		"local_option_ids": [
			String(RogueRareChestRegistry.OPTION_MAX_HEALTH),
			String(RogueRareChestRegistry.OPTION_ATTACK_DAMAGE),
			String(RogueRareChestRegistry.OPTION_MOVE_SPEED),
		],
		"local_selected_option_id": "",
	}
	route.call("_apply_remote_rare_chest_local_health_reward", choosing)
	var selected := choosing.duplicate(true)
	selected["phase"] = String(RogueRareChestSession.PHASE_WAITING)
	selected["local_selected_option_id"] = String(
		RogueRareChestRegistry.OPTION_MAX_HEALTH
	)
	route.call("_apply_remote_rare_chest_local_health_reward", selected)
	var health_after_first := route.player.current_health
	route.call("_apply_remote_rare_chest_local_health_reward", selected)
	_expect(
		health_after_first == health_before + 10
		and route.player.current_health == health_after_first,
		"已看过私人候选的客户端必须在首次权威选择快照后治疗10点，重放不得重复治疗。"
	)
	var reconnect_selected := selected.duplicate(true)
	reconnect_selected["occurrence_key"] = "client:reconnect:rare_chest"
	var reconnect_health_before := route.player.current_health
	route.call(
		"_apply_remote_rare_chest_local_health_reward",
		reconnect_selected
	)
	_expect(
		route.player.current_health == reconnect_health_before,
		"重连后首次只收到已结算快照的新 Player 不得重复取得生命奖励。"
	)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
		push_error(message)


func _finish() -> void:
	if failures.is_empty():
		print("ROGUE_RARE_CHEST_ROUTE_INTEGRATION_SMOKE_TEST_OK")
		quit(0)
		return
	for message in failures:
		print("FAILED: %s" % message)
	quit(1)
