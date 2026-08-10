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
	var runtime_hash := FLOOR.compute_runtime_contract_hash()
	var content_hash := FLOOR.compute_content_contract_hash()
	_expect(
		runtime_hash.length() == 64
		and runtime_hash == FLOOR.compute_runtime_contract_hash(),
		"楼层 runtime contract hash 必须是稳定的 64 位 SHA-256。"
	)
	_expect(
		FLOOR_DEFINITION_SCRIPT.RUNTIME_CONTRACT_SCHEMA == 4
		and RogueCombatEncounterConfig.RUNTIME_CONTRACT_SCHEMA == 2,
		"楼层与作战运行契约必须分别升级至 schema4/schema2。"
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
	var mismatched_floor := FLOOR.duplicate(false) as FLOOR_DEFINITION_SCRIPT
	mismatched_floor.world_metrics = (
		FLOOR.world_metrics.duplicate(true) as RogueRouteWorldMetrics
	)
	mismatched_floor.world_metrics.default_grid_size.x += 1
	_expect(
		_has_error_containing(mismatched_floor.validate_definition(), "不一致"),
		"FloorDefinition 必须拒绝生成尺寸与世界网格不一致。"
	)


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
