extends SceneTree

const ROUTE_SCENE := preload(
	"res://scene/test_arena/test_rogue_route_p3.tscn"
)
const BASE_ENCOUNTER_CONFIG := preload(
	"res://resources/config/rogue_combat/encounter_01.tres"
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
	await _test_victory_reward_return_and_consumed_revisit()
	await _test_full_inventory_and_runtime_content_policy()
	await _test_timeout_result_then_retry()
	await _test_consumed_failure_and_non_inherited_xirang()
	_finish()


func _test_formal_configuration_gate_and_multiplayer_isolation() -> void:
	var default_route := ROUTE_SCENE.instantiate() as TestRogueRouteP3
	default_route.auto_initialize = false
	default_route.manage_return_locally = true
	root.add_child(default_route)
	await process_frame
	var default_coordinator := _get_coordinator(default_route)
	_expect(
		default_coordinator != null
		and default_coordinator.is_enabled()
		and not default_route.get_signal_connection_list(
			&"normal_combat_requested"
		).is_empty()
		and not default_route.is_encounter_active(),
		"正式确认配置必须订阅 normal_combat_requested，但不能在移动前锁定路线。"
	)
	_cleanup_route(default_route)
	await process_frame

	var disabled_route := ROUTE_SCENE.instantiate() as TestRogueRouteP3
	disabled_route.auto_initialize = false
	disabled_route.manage_return_locally = true
	var disabled_coordinator := _get_coordinator(disabled_route)
	var unconfirmed := _make_confirmed_config()
	unconfirmed.decisions_confirmed = false
	disabled_coordinator.encounter_config = unconfirmed
	root.add_child(disabled_route)
	await process_frame
	_expect(
		not disabled_coordinator.is_enabled()
		and disabled_route.get_signal_connection_list(
			&"normal_combat_requested"
		).is_empty(),
		"任一未确认配置仍必须保持硬门控，不能锁定路线。"
	)
	_cleanup_route(disabled_route)
	await process_frame

	var multiplayer_route := ROUTE_SCENE.instantiate() as TestRogueRouteP3
	multiplayer_route.auto_initialize = false
	multiplayer_route.manage_return_locally = false
	var multiplayer_coordinator := _get_coordinator(multiplayer_route)
	multiplayer_coordinator.encounter_config = _make_confirmed_config()
	root.add_child(multiplayer_route)
	await process_frame
	_expect(
		not multiplayer_coordinator.is_enabled()
		and multiplayer_route.get_signal_connection_list(
			&"normal_combat_requested"
		).is_empty(),
		"MpRogueRoute 内嵌同一地图时，单人协调器绝不能连接或双重消费。"
	)
	_cleanup_route(multiplayer_route)
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

	_expect(
		battle.auto_start_waves
		and battle.runtime_activation_deferred
		and battle.player.current_xirang == 321
		and not route.get_node("World").visible,
		"战场应先继承路线息壤并关闭路线表现，再等待完整预热激活。"
	)
	_expect(
		_validate_battle_campaign(battle, -1, true),
		"胜利夹具必须生成保留击杀息壤的一波十机器人 Campaign。"
	)
	_expect(
		await _wait_for_preparation(battle),
		"战场预热后必须自动进入三秒狭路相逢准备倒计时。"
	)
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
		battle.wave_state == GameRuntimeBase.WaveState.WAVE_ACTIVE
		and battle.current_wave_spawned == 10
		and battle.current_wave_total == 10
		and battle.active_wave_enemy_ids.size() == 10
		and bool(battle.get("_combat_deadline_started"))
		and battle.combat_seconds_remaining == 90,
		"三秒结束时必须同批生成10台机器人，并从此刻开始完整90秒计时。"
	)
	_expect(
		_validate_spawned_robots_at_red_doors(battle),
		"10台机器人必须随机分布在五扇红门的原始出生点上。"
	)

	var inventory_revision_before := run_state.inventory_revision
	_expect(
		_defeat_all_active_enemies(battle) == 10,
		"正式战斗夹具必须实际击败刚生成的10台机器人。"
	)
	_expect(
		await _wait_for_battle_return(coordinator),
		"击败全部敌人的胜利结果必须返回 Rouge 路线。"
	)
	var result := coordinator.get_last_result()
	var loot := result.get("loot", {}) as Dictionary
	var loot_config := load(str(loot.get("config_path", ""))) as PickupConfig
	_expect(
		route.player.current_xirang == 921
		and int(result.get("extra_xirang", -1)) == 500
		and bool(loot.get("granted", false))
		and loot_config != null
		and loot_config.collectible_rarity
		== PickupConfig.CollectibleRarity.COMMON
		and run_state.inventory_revision == inventory_revision_before + 1,
		"胜利必须保留100击杀息壤、额外发放500，并独立抽取一次普通收藏品。"
	)
	_expect(
		route.combat_result_overlay.visible
		and route.combat_result_overlay.result_title_label.text == "通过作战"
		and route.combat_result_overlay.extra_xirang_value_label.text == "+500"
		and not route.is_normal_combat_active()
		and route.get_node("World").visible
		and coordinator.is_node_consumed(combat_node_id),
		"先回图策略必须先完成/释放战斗，再在路线中央显示胜利结算并消费节点。"
	)
	route.combat_result_overlay.close_button.pressed.emit()

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
		),
		"消费节点复访夹具必须能离开后再次进入同一格。"
	)
	_expect(
		battle_starts.size() == 1
		and coordinator.get_active_battle() == null
		and not route.is_normal_combat_active(),
		"胜利后复访已消费节点必须立即完成，不得再次实例化战斗。"
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
		"keep_standard_merchants_pickups_and_drops": (
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
		"关闭普通奖励时，机器人击杀息壤覆盖必须为0且掉落表必须为空。"
	)
	for node_path in RogueCombatSingleplayerCoordinator.DISABLED_STANDARD_NODE_PATHS:
		var target := battle.get_node_or_null(node_path)
		_expect(
			target != null
			and target.process_mode == Node.PROCESS_MODE_DISABLED
			and (not target.visible if target is CanvasItem else true),
			"关闭普通内容时必须隐藏并禁用%s。" % String(node_path)
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


func _test_timeout_result_then_retry() -> void:
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
	battle.wave_state = GameRuntimeBase.WaveState.WAVE_ACTIVE
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
		and route.combat_result_overlay.result_subtitle_label.text
		== RogueCombatGame.TIMEOUT_FAILURE_REASON,
		"战场上结算策略必须冻结战斗并等待玩家关闭，再恢复路线。"
	)
	route.combat_result_overlay.close_button.pressed.emit()
	_expect(
		await _wait_for_battle_return(coordinator)
		and route.player.current_xirang == 777
		and not coordinator.is_node_consumed(combat_node_id),
		"超时失败不得发奖励；不消费策略必须允许后续重试。"
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
		and coordinator.get_active_battle() != null,
		"失败不消费节点时，再次访问必须生成新的作战实例。"
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
		battle != null and battle.player.current_xirang == Game.INITIAL_PLAYER_XIRANG,
		"不继承路线息壤时必须保留普通模式初始1000息壤。"
	)
	if battle == null:
		_cleanup_route(route)
		await process_frame
		return
	battle.call("_enter_defeat")
	_expect(
		await _wait_for_battle_return(coordinator)
		and route.player.current_xirang == Game.INITIAL_PLAYER_XIRANG
		and coordinator.is_node_consumed(combat_node_id)
		and not route.combat_result_overlay.visible,
		"全数阵亡失败必须回写战场息壤；关闭失败结算时应直接回图并消费节点。"
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
		and battle_starts.size() == 1
		and coordinator.get_active_battle() == null,
		"失败消费节点后再次进入必须立即完成，不得重开作战。"
	)
	_cleanup_route(route)
	await process_frame


func _create_ready_route(
	config: RogueCombatEncounterConfig
) -> TestRogueRouteP3:
	_expect(config.validate_config().is_empty(), "测试注入的确认配置必须合法。")
	var route := ROUTE_SCENE.instantiate() as TestRogueRouteP3
	if route == null:
		_expect(false, "P3 路线场景必须能实例化。")
		return null
	route.auto_initialize = false
	route.manage_return_locally = true
	var coordinator := _get_coordinator(route)
	coordinator.encounter_config = config
	root.add_child(route)
	await process_frame
	_expect(coordinator.is_enabled(), "确认后的单人配置必须启用协调器。")
	_expect(
		route.start_authoritative_session(int(fixture["seed"]), false),
		"单人路线必须能以普通作战夹具 seed 启动。"
	)
	await process_frame
	return route


func _make_confirmed_config(overrides: Dictionary = {}) -> RogueCombatEncounterConfig:
	var result := BASE_ENCOUNTER_CONFIG.duplicate(true) as RogueCombatEncounterConfig
	result.decisions_confirmed = true
	result.deadline_start = RogueCombatEncounterConfig.DeadlineStart.WAVE_START
	result.spawn_point_mask = WaveConfig.STANDARD_SPAWN_POINT_MASK
	result.spawn_count_per_tick = result.enemy_count
	result.keep_enemy_kill_xirang = RogueCombatEncounterConfig.Decision.YES
	result.filter_loot_by_character = RogueCombatEncounterConfig.Decision.YES
	result.reward_dead_players_on_victory = RogueCombatEncounterConfig.Decision.YES
	result.return_to_route_before_result = RogueCombatEncounterConfig.Decision.YES
	result.show_failure_result = RogueCombatEncounterConfig.Decision.YES
	result.consume_node_on_failure = RogueCombatEncounterConfig.Decision.YES
	result.keep_standard_merchants_pickups_and_drops = (
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
		wave.get_total_enemy_count() != 10
		or wave.enemy_entries.size() != 1
		or wave.spawn_point_mask != WaveConfig.STANDARD_SPAWN_POINT_MASK
		or wave.spawn_count_per_tick != 10
		or wave.max_alive_enemies < 10
	):
		return false
	var entry := wave.enemy_entries[0]
	return (
		entry != null
		and entry.enemy_config != null
		and entry.enemy_config.display_name == "战斗机器人"
		and entry.enemy_config.xirang_kill_reward == 10
		and not entry.enemy_config.resource_path.is_empty()
		and entry.enemy_config.drop_table != null
		and entry.xirang_kill_reward_override == expected_kill_reward_override
		and battle.allows_enemy_pickup_drops() != expect_drop_disabled
	)


func _validate_spawned_robots_at_red_doors(battle: RogueCombatGame) -> bool:
	if battle == null or battle.active_wave_spawn_points.size() != 5:
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
	return matched_enemy_count == 10 and used_spawn_points.size() >= 2


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
			and battle.wave_state == GameRuntimeBase.WaveState.PRE_WAVE
		):
			return true
		await process_frame
	return false


func _wait_for_battle_return(
	coordinator: RogueCombatSingleplayerCoordinator
) -> bool:
	for _frame in 120:
		if coordinator.get_active_battle() == null:
			return true
		await process_frame
	return false


func _wait_for_result_overlay(route: TestRogueRouteP3) -> bool:
	for _frame in 120:
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
	route: TestRogueRouteP3
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


func _cleanup_route(route: TestRogueRouteP3) -> void:
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
