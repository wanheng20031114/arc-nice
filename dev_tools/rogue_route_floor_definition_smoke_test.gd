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
		and FLOOR.default_combat_config != null,
		"FloorDefinition 必须集中持有楼层身份、生成、几何、背景与默认战斗配置。"
	)
	_expect(
		FLOOR.world_metrics.default_grid_size
		== Vector2i(FLOOR.generation_config.width, FLOOR.generation_config.height),
		"楼层世界默认网格必须与生成尺寸同源。"
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
		FLOOR_DEFINITION_SCRIPT.RUNTIME_CONTRACT_SCHEMA == 5
		and RogueCombatEncounterConfig.RUNTIME_CONTRACT_SCHEMA == 3,
		"楼层与作战运行契约必须分别升级至 schema5/schema3。"
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
	changed_combat_floor.default_combat_config = (
		FLOOR.default_combat_config.duplicate(false) as RogueCombatEncounterConfig
	)
	changed_combat_floor.default_combat_config.campaign = (
		FLOOR.default_combat_config.build_occurrence_campaign(
			"combat:test:floor-contract"
		)
	)
	changed_combat_floor.default_combat_config.campaign.get_waves()[0].max_alive_enemies = 9
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
		_has_error_containing(mismatched_floor.validate_definition(), "不一致"),
		"FloorDefinition 必须拒绝生成尺寸与世界网格不一致。"
	)


func _test_special_combat_catalog() -> void:
	_expect(
		FLOOR.special_combat_configs.size() == 1
		and FLOOR.get_combat_config(
			FLOOR.default_combat_config.encounter_id
		) == FLOOR.default_combat_config
		and FLOOR.get_combat_config(&"suitcase_battle")
		== SUITCASE_BATTLE
		and FLOOR.get_combat_config(&"missing") == null,
		"楼层必须按 config_id 统一解析默认作战与唯一的皮箱特殊作战。"
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
	var adapter := route.get(
		"_normal_combat_briefing_adapter"
	) as RogueNormalCombatBriefingAdapter
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
		and adapter != null
		and coordinator.encounter_config == FLOOR.default_combat_config
		and adapter.encounter_config == FLOOR.default_combat_config
		and coordinator.encounter_config == adapter.encounter_config,
		"单人战斗协调器与战斗简报必须共享 FloorDefinition 的同一配置实例。"
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

	current_scene = null
	route.queue_free()
	await process_frame
	await physics_frame
	await process_frame
	_expect(
		physics_interpolation == previous_interpolation,
		"FloorDefinition smoke 退出路线后必须恢复物理插值状态。"
	)


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
		and coordinator.encounter_config == null
		and not coordinator.is_enabled()
		and title != null
		and title.text.is_empty(),
		"子场景默认值必须为空，不得绕过 FloorDefinition 留下隐藏兜底。"
	)
	_expect(
		route.get("_normal_combat_briefing_adapter") == null,
		"无效楼层不得创建带默认兜底配置的战斗简报适配器。"
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
