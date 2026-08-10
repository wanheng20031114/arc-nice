extends SceneTree

const ROUTE_SCENE := preload(
	"res://scene/game_modes/rogue/route/rogue_route_game.tscn"
)
const BASE_ENCOUNTER_CONFIG := preload(
	"res://resources/config/rogue_combat/encounter_01.tres"
)
const FLOOR_DEFINITION_SCRIPT := preload(
	"res://resources/config/rogue_route/rogue_route_floor_definition.gd"
)
const SHALLOW_MINE_FLOOR := preload(
	"res://resources/config/rogue_route/shallow_mine_floor.tres"
)
const GENERATION_CONFIG := preload(
	"res://resources/config/rogue_route/p3_generation_config.tres"
)
const MAX_SEED_SEARCH := 2048
const MAX_BATTLE_READY_FRAMES := 600

var failures: Array[String] = []
var fixture: Dictionary = {}
var run_state: RunStateStore = null


func _initialize() -> void:
	call_deferred(&"_run")


func _run() -> void:
	run_state = root.get_node_or_null("RunState") as RunStateStore
	_expect(run_state != null, "单人 Rouge 作战测试需要 RunState 自动加载。")
	fixture = _find_adjacent_normal_combat_fixture()
	_expect(not fixture.is_empty(), "测试种子范围内必须存在相邻普通作战节点。")
	if run_state == null or fixture.is_empty():
		_finish()
		return

	await _test_formal_configuration_gate_and_multiplayer_isolation()
	await _test_normal_combat_briefing_cancel_confirm_and_entry()
	await _test_briefing_start_failure_cleanup()
	await _test_victory_reward_return_and_consumed_revisit()
	await _test_victory_presentation_route_reset_cancels_sequence()
	await _test_victory_reveal_route_reset_discards_old_result()
	await _test_full_inventory_and_runtime_content_policy()
	await _test_timeout_result_does_not_reenter()
	await _test_consumed_failure_and_non_inherited_xirang()
	_finish()


func _test_formal_configuration_gate_and_multiplayer_isolation() -> void:
	var default_route := ROUTE_SCENE.instantiate() as RogueRouteGame
	default_route.auto_initialize = false
	default_route.manage_return_locally = true
	root.add_child(default_route)
	await process_frame
	var default_coordinator := _get_coordinator(default_route)
	_expect(
		default_coordinator != null
		and default_coordinator.is_enabled()
		and not default_route.get_signal_connection_list(
			&"combat_requested"
		).is_empty()
		and not default_route.is_encounter_active(),
		"正式确认配置必须订阅统一combat_requested，但不能在移动前锁定路线。"
	)
	_cleanup_route(default_route)
	await process_frame

	var disabled_route := ROUTE_SCENE.instantiate() as RogueRouteGame
	disabled_route.auto_initialize = false
	disabled_route.manage_return_locally = true
	var disabled_coordinator := _get_coordinator(disabled_route)
	var unconfirmed := _make_confirmed_config()
	unconfirmed.decisions_confirmed = false
	_set_route_combat_config(disabled_route, unconfirmed)
	_expect(
		not disabled_route.floor_definition.validate_definition().is_empty()
		and not disabled_coordinator.is_enabled()
		and disabled_route.get_signal_connection_list(
			&"combat_requested"
		).is_empty(),
		"任一未确认配置必须先被 FloorDefinition 硬门控，不能进入路线生命周期。"
	)
	disabled_route.free()

	var multiplayer_route := ROUTE_SCENE.instantiate() as RogueRouteGame
	multiplayer_route.auto_initialize = false
	multiplayer_route.manage_return_locally = false
	var multiplayer_coordinator := _get_coordinator(multiplayer_route)
	_set_route_combat_config(multiplayer_route, _make_confirmed_config())
	root.add_child(multiplayer_route)
	await process_frame
	_expect(
		not multiplayer_coordinator.is_enabled()
		and multiplayer_route.get_signal_connection_list(
			&"combat_requested"
		).is_empty(),
		"MpRogueRoute 内嵌同一地图时，单人协调器绝不能连接或双重消费。"
	)
	_cleanup_route(multiplayer_route)
	await process_frame


func _test_normal_combat_briefing_cancel_confirm_and_entry() -> void:
	run_state.begin_new_run(&"weishidaier", false)
	var route := await _create_ready_route(_make_confirmed_config())
	if route == null:
		return
	var coordinator := _get_coordinator(route)
	var runtime := route.get("_runtime_state") as RogueRouteRuntimeState
	var combat_node_id := int(fixture["combat_node_id"])
	var action_points_before := runtime.action_points
	var revision_before := runtime.state_revision
	var visit_count_before := int(runtime.visited_counts[combat_node_id])
	route.route_board.complete_entry_reveal()
	await process_frame

	route.route_board.node_pressed.emit(combat_node_id)
	await process_frame
	var presented_snapshot := route.export_briefing_state_snapshot()
	_expect(
		route.node_briefing.visible
		and route.node_briefing.can_decide()
		and not route.node_briefing.is_decision_locked()
		and route.node_briefing.confirm_button.text == "进入作战"
		and not route.move_confirmation.visible
		and int(presented_snapshot.get("phase", -1))
		== RogueRouteGame.BriefingPhase.PRESENTED,
		"点击相邻普通作战节点必须显示原生作战简报，并替代旧移动确认框。"
	)
	route.node_briefing.cancel_button.pressed.emit()
	await process_frame
	_expect(
		runtime.current_node_id != combat_node_id
		and runtime.action_points == action_points_before
		and runtime.state_revision == revision_before
		and int(runtime.visited_counts[combat_node_id]) == visit_count_before
		and not route.node_briefing.visible
		and not route.combat_scene_transition.visible
		and int(route.export_briefing_state_snapshot().get("phase", -1))
		== RogueRouteGame.BriefingPhase.NONE,
		"取消简报不得扣行动力、推进 revision/访问次数或遗留简报与黑幕。"
	)

	var move_commit_count := [0]
	var battle_start_count := [0]
	var battle_started_under_full_cover := [false]
	var battle_started_deferred := [false]
	var preparation_seen := [false]
	var preparation_under_full_cover := [false]
	route.host_move_committed.connect(
		func(_delta: Dictionary) -> void:
			move_commit_count[0] = int(move_commit_count[0]) + 1
	)
	coordinator.battle_started.connect(
		func(
			_node_id: int,
			_occurrence_key: String,
			_battle: RogueCombatGame
		) -> void:
			battle_start_count[0] = int(battle_start_count[0]) + 1
			battle_started_under_full_cover[0] = (
				route.combat_scene_transition.is_covered()
			)
			battle_started_deferred[0] = _battle.runtime_activation_deferred
			if _battle.is_runtime_preparation_complete():
				preparation_seen[0] = true
				preparation_under_full_cover[0] = (
					_battle.runtime_activation_deferred
					and route.combat_scene_transition.is_covered()
				)
			else:
				_battle.runtime_preparation_completed.connect(
					func() -> void:
						preparation_seen[0] = true
						preparation_under_full_cover[0] = (
							_battle.runtime_activation_deferred
							and route.combat_scene_transition.is_covered()
						),
					CONNECT_ONE_SHOT
				)
	)
	route.route_board.node_pressed.emit(combat_node_id)
	await process_frame
	_expect(route.node_briefing.visible, "取消后再次点击必须能重新打开作战简报。")
	route.node_briefing.confirm_button.pressed.emit()
	# 直接重复发出按钮信号，验证简报自身的单次决策锁与路线 phase 双重门控。
	route.node_briefing.confirm_button.pressed.emit()
	await create_timer(0.06, true).timeout
	_expect(
		runtime.action_points == action_points_before
		and runtime.state_revision == revision_before
		and int(runtime.visited_counts[combat_node_id]) == visit_count_before
		and int(move_commit_count[0]) == 0
		and int(battle_start_count[0]) == 0
		and not route.node_briefing.visible
		and route.combat_scene_transition.visible
		and not route.combat_scene_transition.is_covered()
		and int(route.export_briefing_state_snapshot().get("phase", -1))
		== RogueRouteGame.BriefingPhase.ENTERING,
		"确认后必须先锁定并关闭简报、播放遮盖，遮盖完成前不能移动或创建战场。"
	)

	var battle := await _wait_for_active_battle(coordinator)
	_expect(
		battle != null
		and runtime.current_node_id == combat_node_id
		and runtime.action_points
		== action_points_before - route.generation_config.move_action_cost
		and runtime.state_revision == revision_before + 1
		and int(runtime.visited_counts[combat_node_id])
		== visit_count_before + 1
		and int(move_commit_count[0]) == 1
		and int(battle_start_count[0]) == 1
		and bool(battle_started_under_full_cover[0])
		and bool(battle_started_deferred[0]),
		"遮盖完成后才能且只能提交一次移动、扣一次行动力并创建一个延迟激活战场。"
	)
	if battle != null:
		var preparation_ready := await _wait_for_preparation(battle)
		_expect(
			preparation_ready
			and bool(preparation_seen[0])
			and bool(preparation_under_full_cover[0])
			and not route.combat_scene_transition.visible
			and is_zero_approx(route.combat_scene_transition.progress)
			and not battle.runtime_activation_deferred
			and battle.wave_state == CombatFlowState.State.PRE_WAVE
			and battle.countdown_seconds == 3,
			"战场 prepared 时必须仍处于完整遮盖；reveal 完成后才可激活三秒准备倒计时。"
		)
	_cleanup_route(route)
	await process_frame


func _test_briefing_start_failure_cleanup() -> void:
	run_state.begin_new_run(&"weishidaier", false)
	var route := await _create_ready_route(_make_confirmed_config())
	if route == null:
		return
	var coordinator := _get_coordinator(route)
	var runtime := route.get("_runtime_state") as RogueRouteRuntimeState
	var combat_node_id := int(fixture["combat_node_id"])
	var revision_before := runtime.state_revision
	route.route_board.complete_entry_reveal()
	await process_frame

	route.route_board.node_pressed.emit(combat_node_id)
	await process_frame
	_expect(route.node_briefing.visible, "启动失败夹具必须先进入真实简报路径。")
	# 简报展示后只替换协调器侧夹具，保持 FloorDefinition/Adapter 的合法
	# 简报契约不变，从而覆盖“移动已提交、战场启动失败”的恢复分支。
	var rejected_start_config := (
		coordinator.encounter_config.duplicate(true)
		as RogueCombatEncounterConfig
	)
	rejected_start_config.decisions_confirmed = false
	coordinator.encounter_config = rejected_start_config
	route.node_briefing.confirm_button.pressed.emit()
	route.node_briefing.confirm_button.pressed.emit()
	_expect(
		await _wait_for_briefing_entry_cleanup(
			route,
			coordinator,
			runtime,
			revision_before + 1
		),
		"战场启动失败必须恢复路线，并清除简报、ENTERING 状态与转场黑幕。"
	)
	_cleanup_route(route)
	await process_frame


func _test_victory_reward_return_and_consumed_revisit() -> void:
	run_state.begin_new_run(&"weishidaier", false)
	var config: RogueCombatEncounterConfig = BASE_ENCOUNTER_CONFIG
	var route := await _create_ready_route(config)
	if route == null:
		return
	_set_player_xirang(route.player, 321)
	var coordinator := _get_coordinator(route)
	var runtime := route.get("_runtime_state") as RogueRouteRuntimeState
	var combat_node_id := int(fixture["combat_node_id"])
	var start_node_id := runtime.current_node_id
	var battle_starts: Array[RogueCombatGame] = []
	var victory_playback_count := [0]
	route.combat_victory_presentation.playback_finished.connect(
		func() -> void:
			victory_playback_count[0] = int(victory_playback_count[0]) + 1
	)
	coordinator.battle_started.connect(
		func(
			_node_id: int,
			_occurrence_key: String,
			_battle: RogueCombatGame
		) -> void:
			battle_starts.append(_battle)
	)
	_expect(
		runtime.try_move(
			combat_node_id,
			route.generation_config.move_action_cost,
			runtime.state_revision
		),
		"胜利夹具必须能进入普通作战节点。"
	)
	var battle := coordinator.get_active_battle()
	_expect(battle != null, "进入普通作战节点必须整体实例化 RogueCombatGame。")
	if battle == null:
		_cleanup_route(route)
		await process_frame
		return
	_expect_fixed_underground_night(battle, "战场创建")

	_expect(
		battle.auto_start_waves
		and battle.runtime_activation_deferred
		and battle.player.current_xirang == 321
		and not route.get_node("World").visible,
		"战场应先继承路线息壤并关闭路线表现，再等待完整预热激活。"
	)
	_expect(
		_validate_battle_campaign(battle, -1, true),
		"胜利夹具必须生成保留击杀息壤的一波22机器人 Campaign。"
	)
	var preparation_ready := await _wait_for_preparation(battle)
	_expect(
		preparation_ready,
		"战场预热后必须自动进入三秒狭路相逢准备倒计时。"
	)
	if preparation_ready:
		_expect_fixed_underground_night(battle, "准备阶段")
	_expect(
		battle.countdown_seconds == 3
		and battle.combat_time_limit_seconds == 90.0
		and battle.deadline_start == RogueCombatGame.DeadlineStart.WAVE_START
		and not bool(battle.get("_combat_deadline_started")),
		"单人作战必须以配置的3秒准备、90秒正式开战计时启动。"
	)
	for _second in 3:
		battle.call("_on_state_timer_timeout")
	_expect(
		battle.wave_state == CombatFlowState.State.WAVE_ACTIVE
		and battle.current_wave_spawned == 1
		and battle.current_wave_total == 22
		and battle.active_wave_enemy_ids.size() == 1
		and bool(battle.get("_combat_deadline_started"))
		and battle.combat_seconds_remaining == 90,
		"三秒结束时必须生成首台机器人，并从此刻开始完整90秒计时。"
	)
	for _spawn_tick in 9:
		battle.call("_on_enemy_spawn_timer_timeout")
	_expect(
		battle.current_wave_spawned == 10
		and battle.active_wave_enemy_ids.size() == 10,
		"逐个生成达到10名场上上限后必须暂停并保留后续队列。"
	)
	_expect_fixed_underground_night(battle, "ACTIVE 阶段")
	_expect(
		_validate_spawned_robots_at_red_doors(battle),
		"前10台机器人必须从三扇红门低方差随机生成并覆盖全部三门。"
	)

	var inventory_revision_before := run_state.inventory_revision
	_expect(
		await _defeat_entire_authored_wave(battle) == 22,
		"正式战斗夹具必须分批实际击败全部22台机器人。"
	)
	_expect(
		await _wait_for_victory_presentation(route),
		"胜利确认后必须先显示“胜者为王”表现。"
	)
	_expect(
		not route.combat_result_overlay.visible
		and not route.get_node("World").visible
		and coordinator.get_active_battle() == battle
		and battle.process_mode == Node.PROCESS_MODE_DISABLED,
		"标题播放期间不得提前回图、释放战场或显示原有结算。"
	)
	coordinator.call("_on_battle_outcome_started", true, "", battle)
	_expect(
		await _wait_for_battle_return(coordinator),
		"击败全部敌人的胜利结果必须返回 Rouge 路线。"
	)
	var result := coordinator.get_last_result()
	var loot := result.get("loot", {}) as Dictionary
	var loot_config := load(str(loot.get("config_path", ""))) as PickupConfig
	_expect(
		route.player.current_xirang == 1041
		and int(result.get("extra_xirang", -1)) == 500
		and bool(loot.get("granted", false))
		and loot_config != null
		and loot_config.collectible_rarity
		== PickupConfig.CollectibleRarity.COMMON
		and run_state.inventory_revision == inventory_revision_before + 1,
		"胜利必须保留220击杀息壤、额外发放500，并独立抽取一次普通收藏品。"
	)
	_expect(
		route.combat_result_overlay.visible
		and route.combat_result_overlay.result_title_label.text == "通过作战"
		and route.combat_result_overlay.extra_xirang_value_label.text == "+500"
		and not route.is_normal_combat_active()
		and route.get_node("World").visible
		and route.player.controls_locked
		and bool(route.route_board.get("_interaction_locked"))
		and coordinator.is_node_consumed(combat_node_id)
		and int(victory_playback_count[0]) == 1,
		"先回图策略必须先完成/释放战斗，再在路线中央显示胜利结算并消费节点。"
	)
	_expect_route_camera_contract(route, "胜利返回路线后")
	route.combat_result_overlay.close_button.pressed.emit()
	_expect(
		not route.player.controls_locked
		and not bool(route.route_board.get("_interaction_locked")),
		"关闭作战结算后必须同步释放路线玩家与节点交互锁。"
	)

	_expect(
		runtime.try_move(
			start_node_id,
			route.generation_config.move_action_cost,
			runtime.state_revision
		),
		"消费节点复访夹具必须能先离开已消费作战格。"
	)
	var revisit_revision_before := runtime.state_revision
	route.route_board.node_pressed.emit(combat_node_id)
	await process_frame
	_expect(
		not route.node_briefing.visible
		and route.move_confirmation.visible,
		"复访已走过普通作战节点不得短暂打开作战简报，只能走普通移动确认。"
	)
	route.move_confirmation.confirm_button.pressed.emit()
	await process_frame
	_expect(
		runtime.state_revision == revisit_revision_before + 1
		and battle_starts.size() == 1
		and coordinator.get_active_battle() == null
		and not route.is_normal_combat_active()
		and not route.node_briefing.visible
		and not route.combat_scene_transition.visible,
		"胜利后复访已走过节点只能完成普通移动，不得重开战斗或遗留简报/黑幕。"
	)
	_cleanup_route(route)
	await process_frame


func _test_victory_presentation_route_reset_cancels_sequence() -> void:
	run_state.begin_new_run(&"weishidaier", false)
	var route := await _create_ready_route(_make_confirmed_config())
	if route == null:
		return
	var coordinator := _get_coordinator(route)
	var runtime := route.get("_runtime_state") as RogueRouteRuntimeState
	var combat_node_id := int(fixture["combat_node_id"])
	var returned_count := [0]
	coordinator.battle_returned.connect(
		func(_victory: bool, _key: String, _result: Dictionary) -> void:
			returned_count[0] = int(returned_count[0]) + 1
	)
	_expect(
		runtime.try_move(
			combat_node_id,
			route.generation_config.move_action_cost,
			runtime.state_revision
		),
		"胜利中断夹具必须能进入普通作战节点。"
	)
	var battle := coordinator.get_active_battle()
	if battle == null:
		_expect(false, "胜利中断夹具必须创建战场。")
		_cleanup_route(route)
		await process_frame
		return
	_expect(
		await _wait_for_preparation(battle),
		"胜利中断夹具必须先完成真实战场预热。"
	)
	battle.call("_enter_victory")
	_expect(
		await _wait_for_victory_presentation(route),
		"路线重置测试必须先进入胜利标题阶段。"
	)
	route.call("_reset_normal_combat_stage", true)
	await create_timer(0.12, true).timeout
	_expect(
		coordinator.get_active_battle() == null
		and not bool(coordinator.get("_settling_outcome"))
		and not route.is_normal_combat_active()
		and route.get_node("World").visible
		and not route.combat_victory_presentation.visible
		and not route.combat_scene_transition.visible
		and not route.combat_result_overlay.visible
		and int(returned_count[0]) == 0,
		"路线重置必须取消旧胜利协程并释放战场，不能延迟回图或显示旧结算。"
	)
	_cleanup_route(route)
	await process_frame


func _test_victory_reveal_route_reset_discards_old_result() -> void:
	run_state.begin_new_run(&"weishidaier", false)
	var route := await _create_ready_route(_make_confirmed_config())
	if route == null:
		return
	var coordinator := _get_coordinator(route)
	var runtime := route.get("_runtime_state") as RogueRouteRuntimeState
	var returned_count := [0]
	coordinator.battle_returned.connect(
		func(_victory: bool, _key: String, _result: Dictionary) -> void:
			returned_count[0] = int(returned_count[0]) + 1
	)
	_expect(
		runtime.try_move(
			int(fixture["combat_node_id"]),
			route.generation_config.move_action_cost,
			runtime.state_revision
		),
		"揭示中断夹具必须能进入普通作战节点。"
	)
	var battle := coordinator.get_active_battle()
	if battle == null:
		_expect(false, "揭示中断夹具必须创建战场。")
		_cleanup_route(route)
		await process_frame
		return
	_expect(
		await _wait_for_preparation(battle),
		"揭示中断夹具必须先完成真实战场预热。"
	)
	battle.call("_enter_victory")
	_expect(
		await _wait_for_victory_presentation(route),
		"揭示中断夹具必须先进入胜利标题阶段。"
	)
	await route.combat_victory_presentation.playback_finished
	await create_timer(0.34, true).timeout
	_expect(
		coordinator.get_active_battle() == null
		and route.get_node("World").visible
		and route.combat_scene_transition.visible
		and not route.combat_result_overlay.visible,
		"揭示中断必须发生在战场已释放、路线已恢复且结算尚未显示的窗口。"
	)
	route.call("_reset_normal_combat_stage", true)
	await create_timer(0.45, true).timeout
	_expect(
		not bool(coordinator.get("_settling_outcome"))
		and str(coordinator.get("_active_occurrence_key")).is_empty()
		and not route.combat_scene_transition.visible
		and not route.combat_result_overlay.visible
		and int(returned_count[0]) == 0,
		"揭示期间路线重置必须丢弃旧结算，不能弹到重置后的路线。"
	)
	_cleanup_route(route)
	await process_frame


func _test_full_inventory_and_runtime_content_policy() -> void:
	run_state.begin_new_run(&"weishidaier", false)
	var filler := _get_non_stackable_common_collectible()
	_expect(filler != null, "满包夹具需要普通品质非堆叠收藏品。")
	if filler == null:
		return
	for slot_index in RunStateStore.INVENTORY_CAPACITY:
		_expect(run_state.try_add_item(filler), "满包夹具槽位%d写入失败。" % slot_index)
	var inventory_revision_before := run_state.inventory_revision
	var inventory_before := _inventory_paths()

	var config := _make_confirmed_config({
		"keep_enemy_kill_xirang": RogueCombatEncounterConfig.Decision.NO,
		"enemy_pickup_drops": (
			RogueCombatEncounterConfig.Decision.NO
		),
	})
	var route := await _create_ready_route(config)
	if route == null:
		return
	_set_player_xirang(route.player, 50)
	var coordinator := _get_coordinator(route)
	var runtime := route.get("_runtime_state") as RogueRouteRuntimeState
	_expect(
		runtime.try_move(
			int(fixture["combat_node_id"]),
			route.generation_config.move_action_cost,
			runtime.state_revision
		),
		"满包夹具必须能进入作战节点。"
	)
	var battle := coordinator.get_active_battle()
	_expect(battle != null, "满包夹具必须创建战场。")
	if battle == null:
		_cleanup_route(route)
		await process_frame
		return
	_expect(
		_validate_battle_campaign(battle, 0, true),
		"关闭敌人掉落时，机器人击杀息壤覆盖必须为0且运行时不得生成拾取物。"
	)
	_expect(
		battle.get_node_or_null("ZhuangfangyiMerchant") == null
		and battle.get_node_or_null("LuoxiMerchant") == null
		and battle.get_node_or_null("WorldBounds") == null,
		"Rouge 专用战场不得重新引入庄方宜、洛茜或旧 WorldBounds 内容。"
	)
	var scene_contract_errors := battle.validate_encounter_scene_contract(
		RogueCombatEncounterConfig.REQUIRED_SCENE_SPAWN_POINT_MASK
	)
	_expect(
		scene_contract_errors.is_empty(),
		"正式战场必须满足三门、队伍出生点及无静态商人/拾取物契约：%s"
		% [scene_contract_errors]
	)
	battle.call("_enter_victory")
	_expect(
		await _wait_for_battle_return(coordinator),
		"满包胜利也必须正常返回路线。"
	)
	var result := coordinator.get_last_result()
	var loot := result.get("loot", {}) as Dictionary
	_expect(
		route.player.current_xirang == 550
		and not bool(loot.get("granted", true))
		and StringName(loot.get("failure_reason", &""))
		== RogueCombatRewardResolver.FAILURE_INVENTORY_FULL
		and not str(loot.get("config_path", "")).is_empty()
		and run_state.inventory_revision == inventory_revision_before
		and _inventory_paths() == inventory_before,
		"满包时必须保留首次抽中的展示结果，只失效一次且不修改背包。"
	)
	_expect(
		route.combat_result_overlay.loot_status_label.text.contains("背包已满"),
		"满包结算必须明确显示抽中物品未获得。"
	)
	_cleanup_route(route)
	await process_frame


func _test_timeout_result_does_not_reenter() -> void:
	run_state.begin_new_run(&"weishidaier", false)
	var config := _make_confirmed_config({
		"return_to_route_before_result": RogueCombatEncounterConfig.Decision.NO,
		"show_failure_result": RogueCombatEncounterConfig.Decision.YES,
		"consume_node_on_failure": RogueCombatEncounterConfig.Decision.NO,
	})
	var route := await _create_ready_route(config)
	if route == null:
		return
	_set_player_xirang(route.player, 777)
	var coordinator := _get_coordinator(route)
	var victory_playback_count := [0]
	route.combat_victory_presentation.playback_finished.connect(
		func() -> void:
			victory_playback_count[0] = int(victory_playback_count[0]) + 1
	)
	var runtime := route.get("_runtime_state") as RogueRouteRuntimeState
	var combat_node_id := int(fixture["combat_node_id"])
	var start_node_id := runtime.current_node_id
	_expect(
		runtime.try_move(
			combat_node_id,
			route.generation_config.move_action_cost,
			runtime.state_revision
		),
		"超时夹具必须能进入作战节点。"
	)
	var battle := coordinator.get_active_battle()
	_expect(
		battle != null and not battle.allows_player_respawn(0),
		"Rouge 作战中的单人死亡必须永久禁用复活。"
	)
	if battle == null:
		_cleanup_route(route)
		await process_frame
		return
	_expect(
		await _wait_for_preparation(battle),
		"超时夹具必须先完成战场预热，才能验证活动战场的安全冻结。"
	)
	battle.wave_state = CombatFlowState.State.WAVE_ACTIVE
	battle.combat_seconds_remaining = 1
	battle.set("_combat_deadline_started", true)
	battle.call("_on_combat_deadline_timer_timeout")
	_expect(
		battle.process_mode != Node.PROCESS_MODE_DISABLED,
		"结果信号回调不得在触发帧同步禁用含碰撞体的战场树。"
	)
	_expect(
		await _wait_for_result_overlay(route),
		"90秒耗尽的失败必须显示失败结算。"
	)
	_expect(
		coordinator.get_active_battle() == battle
		and battle.process_mode == Node.PROCESS_MODE_DISABLED
		and route.is_normal_combat_active()
		and not route.get_node("World").visible
		and route.combat_result_overlay.result_title_label.text == "作战失败"
		and not route.combat_victory_presentation.visible
		and int(victory_playback_count[0]) == 0
		and route.combat_result_overlay.result_subtitle_label.text
		== RogueCombatGame.TIMEOUT_FAILURE_REASON,
		"战场上结算策略必须冻结战斗并等待玩家关闭，再恢复路线。"
	)
	route.combat_result_overlay.close_button.pressed.emit()
	_expect(
		await _wait_for_battle_return(coordinator)
		and route.player.current_xirang == 777
		and not coordinator.is_node_consumed(combat_node_id)
		and int(victory_playback_count[0]) == 0,
		"超时失败不得发奖励；节点未消费不影响其已被路线访问的事实。"
	)
	_expect(
		runtime.try_move(
			start_node_id,
			route.generation_config.move_action_cost,
			runtime.state_revision
		)
		and runtime.try_move(
			combat_node_id,
			route.generation_config.move_action_cost,
			runtime.state_revision
		)
		and coordinator.get_active_battle() == null
		and not route.is_normal_combat_active(),
		"即使失败未消费，已走过的普通作战节点再次访问也不得生成新的作战实例。"
	)
	_cleanup_route(route)
	await process_frame


func _test_consumed_failure_and_non_inherited_xirang() -> void:
	run_state.begin_new_run(&"weishidaier", false)
	var config := _make_confirmed_config({
		"show_failure_result": RogueCombatEncounterConfig.Decision.NO,
		"consume_node_on_failure": RogueCombatEncounterConfig.Decision.YES,
		"inherit_route_xirang": RogueCombatEncounterConfig.Decision.NO,
	})
	var route := await _create_ready_route(config)
	if route == null:
		return
	_set_player_xirang(route.player, 222)
	var coordinator := _get_coordinator(route)
	var runtime := route.get("_runtime_state") as RogueRouteRuntimeState
	var combat_node_id := int(fixture["combat_node_id"])
	var start_node_id := runtime.current_node_id
	var battle_starts: Array[RogueCombatGame] = []
	coordinator.battle_started.connect(
		func(
			_node_id: int,
			_occurrence_key: String,
			_battle: RogueCombatGame
		) -> void:
			battle_starts.append(_battle)
	)
	_expect(
		runtime.try_move(
			combat_node_id,
			route.generation_config.move_action_cost,
			runtime.state_revision
		),
		"消费失败夹具必须能进入作战节点。"
	)
	var battle := coordinator.get_active_battle()
	_expect(
		battle != null and battle.player.current_xirang == RogueCombatGame.INITIAL_PLAYER_XIRANG,
		"不继承路线息壤时必须使用肉鸽作战初始1000息壤。"
	)
	if battle == null:
		_cleanup_route(route)
		await process_frame
		return
	battle.call("_enter_defeat")
	_expect(
		await _wait_for_battle_return(coordinator)
		and route.player.current_xirang == RogueCombatGame.INITIAL_PLAYER_XIRANG
		and coordinator.is_node_consumed(combat_node_id)
		and not route.combat_result_overlay.visible,
		"全数阵亡失败必须回写战场息壤；关闭失败结算时应直接回图并消费节点。"
	)
	_expect_route_camera_contract(route, "失败返回路线后")
	_expect(
		runtime.try_move(
			start_node_id,
			route.generation_config.move_action_cost,
			runtime.state_revision
		)
		and runtime.try_move(
			combat_node_id,
			route.generation_config.move_action_cost,
			runtime.state_revision
		)
		and battle_starts.size() == 1
		and coordinator.get_active_battle() == null,
		"失败消费节点后再次进入必须立即完成，不得重开作战。"
	)
	_cleanup_route(route)
	await process_frame


func _create_ready_route(
	config: RogueCombatEncounterConfig
) -> RogueRouteGame:
	_expect(config.validate_config().is_empty(), "测试注入的确认配置必须合法。")
	var route := ROUTE_SCENE.instantiate() as RogueRouteGame
	if route == null:
		_expect(false, "P3 路线场景必须能实例化。")
		return null
	route.auto_initialize = false
	route.manage_return_locally = true
	var coordinator := _get_coordinator(route)
	_set_route_combat_config(route, config)
	root.add_child(route)
	await process_frame
	_expect(coordinator.is_enabled(), "确认后的单人配置必须启用协调器。")
	_expect(
		route.start_authoritative_session(int(fixture["seed"]), false),
		"单人路线必须能以普通作战夹具 seed 启动。"
	)
	await process_frame
	return route


func _set_route_combat_config(
	route: RogueRouteGame,
	config: RogueCombatEncounterConfig
) -> void:
	var floor_definition := (
		SHALLOW_MINE_FLOOR.duplicate(false) as FLOOR_DEFINITION_SCRIPT
	)
	floor_definition.default_combat_config = config
	route.floor_definition = floor_definition


func _make_confirmed_config(overrides: Dictionary = {}) -> RogueCombatEncounterConfig:
	var result := BASE_ENCOUNTER_CONFIG.duplicate(true) as RogueCombatEncounterConfig
	result.decisions_confirmed = true
	result.deadline_start = RogueCombatEncounterConfig.DeadlineStart.WAVE_START
	result.keep_enemy_kill_xirang = RogueCombatEncounterConfig.Decision.YES
	result.filter_loot_by_character = RogueCombatEncounterConfig.Decision.YES
	result.reward_dead_players_on_victory = RogueCombatEncounterConfig.Decision.YES
	result.return_to_route_before_result = RogueCombatEncounterConfig.Decision.YES
	result.show_failure_result = RogueCombatEncounterConfig.Decision.YES
	result.consume_node_on_failure = RogueCombatEncounterConfig.Decision.YES
	result.enemy_pickup_drops = (
		RogueCombatEncounterConfig.Decision.NO
	)
	result.inherit_route_xirang = RogueCombatEncounterConfig.Decision.YES
	result.support_singleplayer = RogueCombatEncounterConfig.Decision.YES
	result.support_multiplayer = RogueCombatEncounterConfig.Decision.YES
	for key in overrides:
		result.set(StringName(key), overrides[key])
	return result


func _validate_battle_campaign(
	battle: RogueCombatGame,
	expected_kill_reward_override: int,
	expect_drop_disabled: bool
) -> bool:
	if battle.singleplayer_campaign == null:
		return false
	var waves := battle.singleplayer_campaign.get_waves()
	if waves.size() != 1:
		return false
	var wave := waves[0]
	if (
		wave.get_total_enemy_count() != 22
		or wave.enemy_entries.size() != 3
		or wave.spawn_point_mask
		!= RogueCombatEncounterConfig.REQUIRED_SCENE_SPAWN_POINT_MASK
		or not is_equal_approx(wave.spawn_interval, 0.3)
		or wave.spawn_count_per_tick != 1
		or wave.max_alive_enemies != 10
		or wave.spawn_point_order
		!= WaveConfig.SpawnPointOrder.BALANCED_SHUFFLE_BAG
	):
		return false
	var expected_counts: Array[int] = [10, 4, 8]
	for entry_index in range(wave.enemy_entries.size()):
		var entry := wave.enemy_entries[entry_index]
		if (
			entry == null
			or entry.enemy_config == null
			or entry.count != expected_counts[entry_index]
			or entry.enemy_config.xirang_kill_reward != 10
			or entry.enemy_config.resource_path.is_empty()
			or entry.enemy_config.drop_table == null
			or entry.xirang_kill_reward_override != expected_kill_reward_override
		):
			return false
	return battle.allows_enemy_pickup_drops() != expect_drop_disabled


func _validate_spawned_robots_at_red_doors(battle: RogueCombatGame) -> bool:
	if battle == null or battle.active_wave_spawn_points.size() != 3:
		return false
	var used_spawn_points: Dictionary = {}
	var matched_enemy_count := 0
	for child in battle.enemy_container.get_children():
		var enemy := child as Enemy
		if (
			enemy == null
			or not battle.active_wave_enemy_ids.has(enemy.get_instance_id())
		):
			continue
		for spawn_point in battle.active_wave_spawn_points:
			if enemy.global_position.is_equal_approx(spawn_point.global_position):
				matched_enemy_count += 1
				used_spawn_points[spawn_point.name] = true
				break
	return matched_enemy_count == 10 and used_spawn_points.size() == 3


func _defeat_entire_authored_wave(battle: RogueCombatGame) -> int:
	var defeated_total := 0
	while (
		battle != null
		and is_instance_valid(battle)
		and battle.current_wave_defeated < battle.current_wave_total
	):
		while (
			battle.pending_enemy_config_index < battle.pending_enemy_configs.size()
			and battle.active_wave_enemy_ids.size() < 10
		):
			battle.call("_on_enemy_spawn_timer_timeout")
		var defeated_batch := _defeat_all_active_enemies(battle)
		if defeated_batch <= 0:
			return defeated_total
		defeated_total += defeated_batch
		await process_frame
		await process_frame
	return defeated_total


func _defeat_all_active_enemies(battle: RogueCombatGame) -> int:
	if battle == null:
		return 0
	var defeated_count := 0
	for child in battle.enemy_container.get_children():
		var enemy := child as Enemy
		if (
			enemy == null
			or not battle.active_wave_enemy_ids.has(enemy.get_instance_id())
		):
			continue
		enemy.call("_die")
		enemy.queue_free()
		defeated_count += 1
	return defeated_count


func _wait_for_preparation(battle: RogueCombatGame) -> bool:
	for _frame in MAX_BATTLE_READY_FRAMES:
		if (
			is_instance_valid(battle)
			and not battle.runtime_activation_deferred
			and battle.wave_state == CombatFlowState.State.PRE_WAVE
		):
			return true
		await process_frame
	return false


func _wait_for_active_battle(
	coordinator: RogueCombatSingleplayerCoordinator
) -> RogueCombatGame:
	for _frame in MAX_BATTLE_READY_FRAMES:
		var battle := coordinator.get_active_battle()
		if battle != null and is_instance_valid(battle):
			return battle
		await process_frame
	return null


func _wait_for_briefing_entry_cleanup(
	route: RogueRouteGame,
	coordinator: RogueCombatSingleplayerCoordinator,
	runtime: RogueRouteRuntimeState,
	expected_revision: int
) -> bool:
	for _frame in MAX_BATTLE_READY_FRAMES:
		if (
			runtime.state_revision == expected_revision
			and coordinator.get_active_battle() == null
			and not route.is_normal_combat_active()
			and not route.node_briefing.visible
			and not route.combat_scene_transition.visible
			and route.get_node("World").visible
			and int(route.export_briefing_state_snapshot().get("phase", -1))
			== RogueRouteGame.BriefingPhase.NONE
		):
			return true
		await process_frame
	return false


func _expect_fixed_underground_night(
	battle: RogueCombatGame,
	context: String
) -> void:
	if battle == null or not is_instance_valid(battle):
		_expect(false, "%s缺少有效的 Rouge 作战实例。" % context)
		return
	var controller := battle.day_night_controller
	_expect(
		battle.world_lighting_policy
		== CombatRuntimeBase.WorldLightingPolicy.FIXED_NIGHT
		and controller != null
		and controller.night_color.is_equal_approx(
			RogueCombatGame.UNDERGROUND_NIGHT_COLOR
		)
		and controller.color.is_equal_approx(
			RogueCombatGame.UNDERGROUND_NIGHT_COLOR
		)
		and is_equal_approx(controller.night_factor, 1.0)
		and controller.is_night()
		and not controller.is_transitioning()
		and controller.get("_transition_tween") == null,
		(
			"%s必须保持 FIXED_NIGHT、factor=1 与地下夜色，且不能遗留昼夜 Tween。"
			% context
		)
	)


func _wait_for_battle_return(
	coordinator: RogueCombatSingleplayerCoordinator
) -> bool:
	for _frame in 240:
		if (
			coordinator.get_active_battle() == null
			and not bool(coordinator.get("_settling_outcome"))
		):
			return true
		await process_frame
	return false


func _expect_route_camera_contract(route: RogueRouteGame, context: String) -> void:
	var camera := route.map_camera
	var route_player := route.player
	_expect(
		camera != null
		and route_player != null
		and is_instance_valid(camera)
		and is_instance_valid(route_player)
		and camera.enabled
		and camera.get_parent() == route_player
		and route.get_viewport().get_camera_2d() == camera
		and (
			route.get_viewport().get_canvas_transform().affine_inverse()
			* (route.get_viewport_rect().size * 0.5)
		).distance_to(camera.get_screen_center_position()) <= 0.51
		and camera.physics_interpolation_mode
		== Node.PHYSICS_INTERPOLATION_MODE_INHERIT
		and route_player.physics_interpolation_mode
		== Node.PHYSICS_INTERPOLATION_MODE_ON,
		"%s必须重新建立本地玩家跟随相机并取得 Viewport 当前相机所有权。" % context
	)


func _wait_for_victory_presentation(route: RogueRouteGame) -> bool:
	for _frame in 60:
		if route.combat_victory_presentation.visible:
			return true
		await process_frame
	return false


func _wait_for_result_overlay(route: RogueRouteGame) -> bool:
	for _frame in 240:
		if route.combat_result_overlay.visible:
			return true
		await process_frame
	return false


func _find_adjacent_normal_combat_fixture() -> Dictionary:
	for seed in range(1, MAX_SEED_SEARCH + 1):
		var graph := RogueRouteGenerator.generate(GENERATION_CONFIG, seed)
		if graph == null:
			continue
		for neighbor_id in graph.get_neighbors(graph.start_node_id):
			if (
				graph.get_node_type(neighbor_id)
				== RogueRouteGraph.NodeType.NORMAL_COMBAT
			):
				return {
					"seed": seed,
					"combat_node_id": int(neighbor_id),
				}
	return {}


func _get_coordinator(
	route: RogueRouteGame
) -> RogueCombatSingleplayerCoordinator:
	return route.get_node_or_null(
		"SingleplayerCombatCoordinator"
	) as RogueCombatSingleplayerCoordinator


func _get_non_stackable_common_collectible() -> PickupConfig:
	for item in CollectibleRegistry.get_by_rarity(
		PickupConfig.CollectibleRarity.COMMON
	):
		if item.can_store_in_inventory and not item.stackable:
			return item
	return null


func _inventory_paths() -> PackedStringArray:
	var result := PackedStringArray()
	for item in run_state.inventory:
		result.append(item.resource_path if item != null else "")
	return result


func _set_player_xirang(player: Player, amount: int) -> void:
	player.current_xirang = amount
	player.xirang_changed.emit(amount, 0)


func _cleanup_route(route: RogueRouteGame) -> void:
	if route == null or not is_instance_valid(route):
		return
	if route.get_parent() != null:
		route.get_parent().remove_child(route)
	route.free()


func _expect(condition: bool, message: String) -> void:
	if condition:
		return
	failures.append(message)
	push_error(message)


func _finish() -> void:
	if failures.is_empty():
		print("ROGUE_COMBAT_SINGLEPLAYER_FLOW_SMOKE_TEST_OK")
		quit(0)
		return
	print(
		"ROGUE_COMBAT_SINGLEPLAYER_FLOW_SMOKE_TEST_FAILED count=%d"
		% failures.size()
	)
	for failure in failures:
		print(" - %s" % failure)
	quit(1)
