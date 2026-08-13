extends SceneTree

const FLOOR_DEFINITION_SCRIPT := preload(
	"res://resources/config/rogue_route/rogue_route_floor_definition.gd"
)
const FLOOR: FLOOR_DEFINITION_SCRIPT = preload(
	"res://resources/config/rogue_route/shallow_mine_floor.tres"
)
const ROUTE_SCENE: PackedScene = preload(
	"res://scene/game_modes/rogue/route/rogue_route_game.tscn"
)
const SUITCASE_BATTLE: RogueCombatEncounterConfig = preload(
	"res://resources/config/rogue_combat/suitcase_battle.tres"
)
const NARROW_ROAD: RogueCombatEncounterConfig = preload(
	"res://resources/config/rogue_combat/encounter_01.tres"
)
const UNDERGROUND_CHURCH: RogueCombatEncounterConfig = preload(
	"res://resources/config/rogue_combat/underground_church_01.tres"
)
const ABANDONED_MINE: RogueCombatEncounterConfig = preload(
	"res://resources/config/rogue_combat/abandoned_mine_01.tres"
)
const UNDERGROUND_SEWER: RogueCombatEncounterConfig = preload(
	"res://resources/config/rogue_combat/underground_sewer_01.tres"
)
const EMERGENCY_NARROW_ROAD: RogueCombatEncounterConfig = preload(
	"res://resources/config/rogue_combat/emergency_narrow_road_01.tres"
)
const EMERGENCY_UNDERGROUND_CHURCH: RogueCombatEncounterConfig = preload(
	"res://resources/config/rogue_combat/emergency_underground_church_01.tres"
)
const EMERGENCY_ABANDONED_MINE: RogueCombatEncounterConfig = preload(
	"res://resources/config/rogue_combat/emergency_abandoned_mine_01.tres"
)
const EMERGENCY_UNDERGROUND_SEWER: RogueCombatEncounterConfig = preload(
	"res://resources/config/rogue_combat/emergency_underground_sewer_01.tres"
)
const ELITE_GUNNER: EnemyConfig = preload(
	"res://resources/config/enemies/combat_robot_gunner_elite.tres"
)
const ELITE_SHIELD_BEARER: EnemyConfig = preload(
	"res://resources/config/enemies/combat_robot_shield_bearer_elite.tres"
)

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_definition_contract()
	await _test_floor_application()
	await _test_invalid_floor_is_atomic()
	_finish()


func _test_definition_contract() -> void:
	_expect(FLOOR != null, "浅层矿洞 FloorDefinition 必须能够加载。")
	if FLOOR == null:
		return
	_expect(
		FLOOR.validate_definition().is_empty(),
		"浅层矿洞 FloorDefinition 必须完整有效：%s"
		% [FLOOR.validate_definition()]
	)
	_expect(
		FLOOR.floor_id == &"shallow_mine"
		and FLOOR.display_name == "浅层矿洞"
		and FLOOR.generation_config != null
		and FLOOR.world_metrics != null
		and FLOOR.background_texture != null
		and FLOOR.normal_combat_pool != null
		and FLOOR.emergency_combat_pool != null,
		"FloorDefinition 必须集中持有楼层身份、生成、几何、背景与两类路线作战池。"
	)
	_expect(
		FLOOR.world_metrics.default_grid_size
		== Vector2i(FLOOR.generation_config.width, FLOOR.generation_config.height),
		"楼层世界默认网格必须与生成尺寸同源。"
	)
	var emergency_type_config := FLOOR.generation_config.get_type_config(
		RogueRouteGraph.NodeType.EMERGENCY_COMBAT
	)
	_expect(
		emergency_type_config != null
		and is_equal_approx(emergency_type_config.generation_weight, 1.0),
		"接入紧急关卡池不得改变紧急作战节点原有的地图生成权重1.0。"
	)
	_test_special_combat_catalog()
	var runtime_hash := FLOOR.compute_runtime_contract_hash()
	var content_hash := FLOOR.compute_content_contract_hash()
	_expect(
		runtime_hash.length() == 64
		and runtime_hash == FLOOR.compute_runtime_contract_hash(),
		"楼层 runtime contract hash 必须是稳定的 64 位 SHA-256。"
	)
	_expect(
		FLOOR_DEFINITION_SCRIPT.RUNTIME_CONTRACT_SCHEMA == 8
		and FLOOR_DEFINITION_SCRIPT.CONTENT_CONTRACT_SCHEMA == 3
		and RogueCombatPoolConfig.RUNTIME_CONTRACT_SCHEMA == 1
		and RogueCombatEncounterConfig.RUNTIME_CONTRACT_SCHEMA == 4,
		"楼层、内容、作战池与作战运行契约版本必须准确。"
	)
	_expect(
		content_hash.length() == 64
		and content_hash == FLOOR.compute_content_contract_hash(),
		"楼层 content contract hash 必须是稳定的 64 位 SHA-256。"
	)

	var renamed_floor := FLOOR.duplicate(false) as FLOOR_DEFINITION_SCRIPT
	renamed_floor.display_name = "仅修改表现标题"
	_expect(
		renamed_floor.compute_runtime_contract_hash() == runtime_hash
		and renamed_floor.compute_content_contract_hash() != content_hash,
		"楼层标题只应改变内容契约，不得改变权威运行契约。"
	)
	var changed_runtime_floor := FLOOR.duplicate(false) as FLOOR_DEFINITION_SCRIPT
	changed_runtime_floor.generation_config = (
		FLOOR.generation_config.duplicate(true) as RogueRouteGenerationConfig
	)
	changed_runtime_floor.generation_config.initial_action_points += 1
	_expect(
		changed_runtime_floor.compute_runtime_contract_hash() != runtime_hash,
		"生成规则变化必须改变楼层运行契约。"
	)
	var changed_combat_floor := FLOOR.duplicate(false) as FLOOR_DEFINITION_SCRIPT
	changed_combat_floor.normal_combat_pool = (
		FLOOR.normal_combat_pool.duplicate(false) as RogueCombatPoolConfig
	)
	changed_combat_floor.normal_combat_pool.entries = (
		FLOOR.normal_combat_pool.entries.duplicate()
	)
	var changed_entry := (
		FLOOR.normal_combat_pool.entries[0].duplicate(false)
		as RogueCombatPoolEntry
	)
	changed_combat_floor.normal_combat_pool.entries[0] = changed_entry
	changed_entry.combat_config = (
		changed_entry.combat_config.duplicate(false) as RogueCombatEncounterConfig
	)
	changed_entry.combat_config.campaign = (
		changed_entry.combat_config.build_occurrence_campaign(
			"combat:test:floor-contract"
		)
	)
	changed_entry.combat_config.campaign.get_waves()[0].max_alive_enemies = 9
	_expect(
		changed_combat_floor.compute_runtime_contract_hash() != runtime_hash,
		"作战 Wave 的场上敌人上限变化必须传导至楼层运行契约。"
	)
	var changed_special_floor := FLOOR.duplicate(false) as FLOOR_DEFINITION_SCRIPT
	var changed_special := (
		SUITCASE_BATTLE.duplicate(false) as RogueCombatEncounterConfig
	)
	changed_special.campaign = SUITCASE_BATTLE.build_occurrence_campaign(
		"combat:test:suitcase-floor-contract"
	)
	changed_special.campaign.get_waves()[0].max_alive_enemies = 39
	changed_special_floor.special_combat_configs = [changed_special]
	_expect(
		changed_special_floor.compute_runtime_contract_hash() != runtime_hash,
		"特殊作战 Wave 变化必须传导至楼层运行契约。"
	)
	var mismatched_floor := FLOOR.duplicate(false) as FLOOR_DEFINITION_SCRIPT
	mismatched_floor.world_metrics = (
		FLOOR.world_metrics.duplicate(true) as RogueRouteWorldMetrics
	)
	mismatched_floor.world_metrics.default_grid_size.x += 1
	_expect(
		mismatched_floor.validate_definition().is_empty()
		and mismatched_floor.compute_runtime_contract_hash() != runtime_hash,
		"模板化楼层应允许回退画布尺寸变化，并把世界度量变化纳入运行契约。"
	)


func _test_special_combat_catalog() -> void:
	var narrow_bucket_count := 0
	var church_bucket_count := 0
	var abandoned_mine_bucket_count := 0
	var underground_sewer_bucket_count := 0
	for bucket in range(FLOOR.normal_combat_pool.get_total_selection_weight()):
		var selected := FLOOR.normal_combat_pool.select_config_for_weight_bucket(
			bucket
		)
		if selected == NARROW_ROAD:
			narrow_bucket_count += 1
		elif selected == UNDERGROUND_CHURCH:
			church_bucket_count += 1
		elif selected == ABANDONED_MINE:
			abandoned_mine_bucket_count += 1
		elif selected == UNDERGROUND_SEWER:
			underground_sewer_bucket_count += 1
	var emergency_counts := {
		EMERGENCY_NARROW_ROAD: 0,
		EMERGENCY_UNDERGROUND_CHURCH: 0,
		EMERGENCY_ABANDONED_MINE: 0,
		EMERGENCY_UNDERGROUND_SEWER: 0,
	}
	for bucket in range(FLOOR.emergency_combat_pool.get_total_selection_weight()):
		var selected := (
			FLOOR.emergency_combat_pool.select_config_for_weight_bucket(bucket)
		)
		if emergency_counts.has(selected):
			emergency_counts[selected] = int(emergency_counts[selected]) + 1
	_expect(
		FLOOR.normal_combat_pool.pool_id == &"normal_combat"
		and FLOOR.normal_combat_pool.entries.size() == 4
		and FLOOR.normal_combat_pool.get_total_selection_weight() == 4
		and narrow_bucket_count == 1
		and church_bucket_count == 1
		and abandoned_mine_bucket_count == 1
		and underground_sewer_bucket_count == 1
		and FLOOR.normal_combat_pool.select_config_for_weight_bucket(-1) == null
		and FLOOR.normal_combat_pool.select_config_for_weight_bucket(4) == null
		and FLOOR.get_combat_config(&"narrow_road_01") == NARROW_ROAD
		and FLOOR.get_combat_config(&"underground_church_01")
		== UNDERGROUND_CHURCH
		and FLOOR.get_combat_config(&"abandoned_mine_01")
		== ABANDONED_MINE
		and FLOOR.get_combat_config(&"underground_sewer_01")
		== UNDERGROUND_SEWER
		and FLOOR.emergency_combat_pool.pool_id == &"emergency_combat"
		and FLOOR.emergency_combat_pool.entries.size() == 4
		and FLOOR.emergency_combat_pool.get_total_selection_weight() == 4
		and int(emergency_counts[EMERGENCY_NARROW_ROAD]) == 1
		and int(emergency_counts[EMERGENCY_UNDERGROUND_CHURCH]) == 1
		and int(emergency_counts[EMERGENCY_ABANDONED_MINE]) == 1
		and int(emergency_counts[EMERGENCY_UNDERGROUND_SEWER]) == 1
		and FLOOR.get_combat_config(&"emergency_narrow_road_01")
		== EMERGENCY_NARROW_ROAD
		and FLOOR.get_combat_config(&"emergency_underground_church_01")
		== EMERGENCY_UNDERGROUND_CHURCH
		and FLOOR.get_combat_config(&"emergency_abandoned_mine_01")
		== EMERGENCY_ABANDONED_MINE
		and FLOOR.get_combat_config(&"emergency_underground_sewer_01")
		== EMERGENCY_UNDERGROUND_SEWER
		and FLOOR.special_combat_configs.size() == 1
		and FLOOR.get_combat_config(&"suitcase_battle")
		== SUITCASE_BATTLE
		and FLOOR.get_combat_config(&"missing") == null,
		"楼层必须提供各四项等权的普通/紧急池，并统一解析全部作战。"
	)
	var reordered_pool := (
		FLOOR.normal_combat_pool.duplicate(false) as RogueCombatPoolConfig
	)
	reordered_pool.entries = FLOOR.normal_combat_pool.entries.duplicate()
	reordered_pool.entries.reverse()
	_expect(
		reordered_pool.compute_runtime_contract_hash()
		== FLOOR.normal_combat_pool.compute_runtime_contract_hash()
		and reordered_pool.select_config(20260811)
		== FLOOR.normal_combat_pool.select_config(20260811),
		"普通作战池的 authored 顺序不得改变合同或同种子选择结果。"
	)
	_expect(
		SUITCASE_BATTLE.is_ready_to_enable()
		and SUITCASE_BATTLE.preparation_seconds == 3
		and SUITCASE_BATTLE.combat_limit_seconds == 300
		and SUITCASE_BATTLE.get_total_enemy_count() == 100,
		"皮箱之战必须是 3 秒准备、300 秒时限、共 100 敌人的可启用配置。"
	)
	var waves := SUITCASE_BATTLE.campaign.get_waves()
	_expect(waves.size() == 1, "皮箱之战 Campaign 必须只有一个波次。")
	if waves.size() != 1:
		return
	var wave := waves[0]
	_expect(
		is_equal_approx(wave.spawn_interval, 0.1)
		and wave.spawn_count_per_tick == 1
		and wave.max_alive_enemies == 40
		and wave.spawn_point_mask
		== RogueCombatEncounterConfig.REQUIRED_SCENE_SPAWN_POINT_MASK
		and wave.spawn_point_order
		== WaveConfig.SpawnPointOrder.BALANCED_SHUFFLE_BAG,
		"皮箱之战必须使用 0.1 秒、批 1、cap40 与三红门均衡生成。"
	)
	_expect(
		_count_enemy(wave, ELITE_GUNNER) == 95
		and _count_enemy(wave, ELITE_SHIELD_BEARER) == 5,
		"皮箱之战敌人组成必须严格为 95 精英枪手与 5 精英盾兵。"
	)

	var alpha := SUITCASE_BATTLE.duplicate(false) as RogueCombatEncounterConfig
	alpha.encounter_id = &"alpha_test_special"
	var first_order := FLOOR.duplicate(false) as FLOOR_DEFINITION_SCRIPT
	first_order.special_combat_configs = [SUITCASE_BATTLE, alpha]
	var second_order := FLOOR.duplicate(false) as FLOOR_DEFINITION_SCRIPT
	second_order.special_combat_configs = [alpha, SUITCASE_BATTLE]
	_expect(
		first_order.compute_runtime_contract_hash()
		== second_order.compute_runtime_contract_hash(),
		"特殊作战目录的 authored 顺序不得改变排序后的运行契约。"
	)
	var duplicate_ids := FLOOR.duplicate(false) as FLOOR_DEFINITION_SCRIPT
	duplicate_ids.special_combat_configs = [SUITCASE_BATTLE, SUITCASE_BATTLE]
	_expect(
		_has_error_containing(duplicate_ids.validate_definition(), "重复 ID"),
		"楼层必须拒绝重复的特殊作战 config_id。"
	)
	var duplicate_pool_id_floor := (
		FLOOR.duplicate(false) as FLOOR_DEFINITION_SCRIPT
	)
	duplicate_pool_id_floor.emergency_combat_pool = (
		FLOOR.emergency_combat_pool.duplicate(true) as RogueCombatPoolConfig
	)
	duplicate_pool_id_floor.emergency_combat_pool.entries[0].combat_config = (
		NARROW_ROAD
	)
	_expect(
		_has_error_containing(
			duplicate_pool_id_floor.validate_definition(),
			"紧急作战 ID 与普通作战池重复"
		),
		"楼层必须拒绝普通与紧急池之间重复的作战 ID。"
	)


func _count_enemy(wave: WaveConfig, enemy_config: EnemyConfig) -> int:
	var result := 0
	for entry in wave.enemy_entries:
		if entry != null and entry.enemy_config == enemy_config:
			result += entry.count
	return result


func _test_floor_application() -> void:
	var previous_interpolation := physics_interpolation
	var route := ROUTE_SCENE.instantiate() as RogueRouteGame
	_expect(route != null, "路线场景必须能够实例化。")
	if route == null:
		return
	route.auto_initialize = false
	route.manage_return_locally = false
	root.add_child(route)
	current_scene = route
	await process_frame

	var board := route.get_node_or_null("World/RouteBoard") as RogueRouteBoard
	var world := route.get_node_or_null("World") as RogueRouteWorld
	var background := route.get_node_or_null(
		"World/Backdrop/RuinsBackground"
	) as Sprite2D
	var coordinator := route.get_node_or_null(
		"SingleplayerCombatCoordinator"
	) as RogueCombatSingleplayerCoordinator
	var top_bar := route.get_node_or_null(
		"HUD/Root/TopBar"
	) as RogueRouteTopBar
	var adapters := route.get("_normal_combat_briefing_adapters") as Dictionary
	var emergency_adapters := (
		route.get("_emergency_combat_briefing_adapters") as Dictionary
	)
	_expect(
		route.floor_definition == FLOOR
		and route.generation_config == FLOOR.generation_config,
		"路线根节点必须仅通过 FloorDefinition 暴露只读 generation_config。"
	)
	_expect(
		board != null
		and world != null
		and world.route_board == board
		and board.world_metrics == FLOOR.world_metrics
		and board.size.is_equal_approx(
			FLOOR.world_metrics.get_layout_size(
				FLOOR.world_metrics.default_grid_size
			)
		),
		"父 _enter_tree 必须在 Board/World ready 前注入同一 world_metrics。"
	)
	_expect(
		background != null
		and background.texture == FLOOR.background_texture
		and world.ruins_background == background,
		"路线背景必须直接来自当前 FloorDefinition。"
	)
	_expect(
		coordinator != null
		and adapters.size() == 4
		and (adapters[&"narrow_road_01"] as RogueNormalCombatBriefingAdapter).encounter_config
		== NARROW_ROAD
		and (adapters[&"narrow_road_01"] as RogueNormalCombatBriefingAdapter).hero_visual
		== NARROW_ROAD.briefing_visual
		and (adapters[&"underground_church_01"] as RogueNormalCombatBriefingAdapter).encounter_config
		== UNDERGROUND_CHURCH
		and (adapters[&"underground_church_01"] as RogueNormalCombatBriefingAdapter).hero_visual
		== UNDERGROUND_CHURCH.briefing_visual
		and (adapters[&"abandoned_mine_01"] as RogueNormalCombatBriefingAdapter).encounter_config
		== ABANDONED_MINE
		and (adapters[&"abandoned_mine_01"] as RogueNormalCombatBriefingAdapter).hero_visual
		== ABANDONED_MINE.briefing_visual
		and (adapters[&"underground_sewer_01"] as RogueNormalCombatBriefingAdapter).encounter_config
		== UNDERGROUND_SEWER
		and (adapters[&"underground_sewer_01"] as RogueNormalCombatBriefingAdapter).hero_visual
		== UNDERGROUND_SEWER.briefing_visual,
		"协调器不得保留默认兜底，普通作战池中的每项必须建立专属简报适配器。"
	)
	_expect(
		emergency_adapters.size() == 4
		and (
			emergency_adapters[&"emergency_narrow_road_01"]
			as RogueEmergencyCombatBriefingAdapter
		).encounter_config == EMERGENCY_NARROW_ROAD
		and (
			emergency_adapters[&"emergency_underground_church_01"]
			as RogueEmergencyCombatBriefingAdapter
		).encounter_config == EMERGENCY_UNDERGROUND_CHURCH
		and (
			emergency_adapters[&"emergency_abandoned_mine_01"]
			as RogueEmergencyCombatBriefingAdapter
		).encounter_config == EMERGENCY_ABANDONED_MINE
		and (
			emergency_adapters[&"emergency_underground_sewer_01"]
			as RogueEmergencyCombatBriefingAdapter
		).encounter_config == EMERGENCY_UNDERGROUND_SEWER
		and route.emergency_reward_choice_overlay != null,
		"四个紧急作战必须各自建立危险简报适配器，并静态装配奖励选择层。"
	)
	_expect(
		top_bar != null
		and top_bar.floor_title.text == FLOOR.display_name,
		"路线 ready 必须把 FloorDefinition.display_name 应用到 TopBar。"
	)
	_expect(
		route.get_runtime_contract_hash()
		== FLOOR.compute_runtime_contract_hash(),
		"路线快照契约必须完全委托给当前 FloorDefinition。"
	)
	var emergency_fixture := _find_adjacent_emergency_fixture()
	_expect(not emergency_fixture.is_empty(), "测试种子范围内必须存在相邻紧急作战。")
	if not emergency_fixture.is_empty():
		_expect(
			route.start_authoritative_session(
				int(emergency_fixture["seed"]),
				false
			),
			"路线必须能以含相邻紧急作战的确定种子启动。"
		)
		await process_frame
		var graph := route.get("_route_graph") as RogueRouteGraph
		var runtime := route.get("_runtime_state") as RogueRouteRuntimeState
		var emergency_node_id := int(emergency_fixture["node_id"])
		var config := route.resolve_emergency_combat_config_for_node(
			emergency_node_id
		)
		var model := route.call(
			"_build_emergency_combat_briefing_model",
			emergency_node_id,
			runtime.action_points,
			config.encounter_id if config != null else &""
		) as RogueRouteNodeBriefingModel
		var occurrence_key := "emergency_combat:%s:%d:%d:1" % [
			graph.compute_layout_hash(),
			emergency_node_id,
			graph.get_node_content_seed(emergency_node_id),
		]
		var occurrence := (
			config.build_occurrence_campaign(occurrence_key)
			if config != null
			else null
		)
		var expected_enemy_count := 0
		if occurrence != null:
			for wave in occurrence.get_waves():
				expected_enemy_count += wave.get_total_enemy_count()
		_expect(
			model != null
			and model.source_kind
			== RogueRouteNodeBriefingModel.SOURCE_KIND_EMERGENCY_COMBAT
			and model.is_danger_presentation()
			and model.enemy_count == expected_enemy_count,
			"紧急简报必须使用危险变体，并显示本 occurrence 的实际敌人数。"
		)

	current_scene = null
	route.queue_free()
	await process_frame
	await physics_frame
	await process_frame
	_expect(
		physics_interpolation == previous_interpolation,
		"FloorDefinition smoke 退出路线后必须恢复物理插值状态。"
	)


func _find_adjacent_emergency_fixture() -> Dictionary:
	for seed in range(1, 4097):
		var graph := RogueRouteGenerator.generate(FLOOR.generation_config, seed)
		if graph == null:
			continue
		for neighbor_id in graph.get_neighbors(graph.start_node_id):
			if (
				graph.get_node_type(neighbor_id)
				== RogueRouteGraph.NodeType.EMERGENCY_COMBAT
			):
				return {"seed": seed, "node_id": int(neighbor_id)}
	return {}


func _test_invalid_floor_is_atomic() -> void:
	var invalid_floor := FLOOR.duplicate(false) as FLOOR_DEFINITION_SCRIPT
	invalid_floor.display_name = ""
	_expect(
		not invalid_floor.validate_definition().is_empty(),
		"无效 FloorDefinition 必须在进入场景前即可被校验拒绝。"
	)
	var route := ROUTE_SCENE.instantiate() as RogueRouteGame
	_expect(route != null, "无效楼层测试仍必须能够实例化路线场景。")
	if route == null:
		return
	route.floor_definition = invalid_floor
	route.auto_initialize = false
	var board := route.get_node_or_null("World/RouteBoard") as RogueRouteBoard
	var background := route.get_node_or_null(
		"World/Backdrop/RuinsBackground"
	) as Sprite2D
	var coordinator := route.get_node_or_null(
		"SingleplayerCombatCoordinator"
	) as RogueCombatSingleplayerCoordinator
	var title := route.get_node_or_null(
		"HUD/Root/TopBar/TopLayout/TitleBlock/Title"
	) as Label
	_expect(
		board != null
		and board.world_metrics == null
		and background != null
		and background.texture == null
		and coordinator != null
		and not coordinator.is_enabled()
		and title != null
		and title.text.is_empty(),
		"子场景默认值必须为空，不得绕过 FloorDefinition 留下隐藏兜底。"
	)
	_expect(
		(route.get("_normal_combat_briefing_adapters") as Dictionary).is_empty(),
		"无效楼层不得创建带默认兜底配置的战斗简报适配器。"
	)
	_expect(
		(route.get("_emergency_combat_briefing_adapters") as Dictionary).is_empty(),
		"无效楼层不得创建紧急作战简报适配器。"
	)
	route.free()
	await process_frame


func _has_error_containing(errors: PackedStringArray, fragment: String) -> bool:
	for error in errors:
		if error.contains(fragment):
			return true
	return false


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("Rogue route floor definition smoke test passed.")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)
