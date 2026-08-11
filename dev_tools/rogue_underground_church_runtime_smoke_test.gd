extends SceneTree

## 正式普通作战池选中地下教会后的单人场景加载与客户端复算 smoke。

const ROUTE_SCENE := preload(
	"res://scene/game_modes/rogue/route/rogue_route_game.tscn"
)
const FLOOR_DEFINITION: RogueRouteFloorDefinition = preload(
	"res://resources/config/rogue_route/shallow_mine_floor.tres"
)
const GENERATION_CONFIG: RogueRouteGenerationConfig = preload(
	"res://resources/config/rogue_route/p3_generation_config.tres"
)
const TARGET_CONFIG: RogueCombatEncounterConfig = preload(
	"res://resources/config/rogue_combat/underground_church_01.tres"
)
const TARGET_CONFIG_ID := &"underground_church_01"
const TARGET_SCENE_PATH := (
	"res://scene/game_modes/rogue/combat/rogue_combat_game_02.tscn"
)
const MAX_SEED_SEARCH := 4096
const MAX_RUNTIME_READY_FRAMES := 600

var failures: PackedStringArray = []


func _initialize() -> void:
	call_deferred(&"_run")


func _run() -> void:
	var fixture := _find_adjacent_underground_church_fixture()
	_expect(not fixture.is_empty(), "正式90%普通作战池必须能找到相邻地下教会夹具。")
	if fixture.is_empty():
		_finish()
		return

	var run_state := root.get_node_or_null("RunState") as RunStateStore
	_expect(run_state != null, "地下教会单人运行烟测需要 RunState 自动加载。")
	if run_state == null:
		_finish()
		return
	run_state.begin_new_run(&"weishidaier", false)

	var host_route := ROUTE_SCENE.instantiate() as RogueRouteGame
	var client_route := ROUTE_SCENE.instantiate() as RogueRouteGame
	_expect(host_route != null and client_route != null, "正式路线场景必须能实例化。")
	if host_route == null or client_route == null:
		if host_route != null:
			host_route.free()
		if client_route != null:
			client_route.free()
		_finish()
		return

	host_route.auto_initialize = false
	host_route.manage_return_locally = true
	client_route.auto_initialize = false
	client_route.manage_return_locally = false
	root.add_child(host_route)
	root.add_child(client_route)
	await process_frame

	var route_seed := int(fixture["seed"])
	var combat_node_id := int(fixture["combat_node_id"])
	_expect(
		host_route.start_authoritative_session(route_seed, false),
		"Host路线必须能安装地下教会确定性夹具。"
	)
	client_route.start_client_waiting()
	_expect(
		client_route.apply_full_snapshot(
			host_route.export_layout_snapshot(),
			host_route.export_state_snapshot()
		),
		"Client必须接受Host地下教会夹具的完整路线快照。"
	)

	var host_config := host_route.resolve_normal_combat_config_for_node(
		combat_node_id
	)
	var client_config := client_route.resolve_normal_combat_config_for_node(
		combat_node_id
	)
	_expect(
		host_config != null
		and client_config != null
		and host_config.encounter_id == TARGET_CONFIG_ID
		and client_config.encounter_id == TARGET_CONFIG_ID
		and host_config.compute_runtime_contract_hash()
		== client_config.compute_runtime_contract_hash(),
		"Host与Client必须由同一节点内容种子复算出同一地下教会配置合同。"
	)

	var runtime := host_route.get("_runtime_state") as RogueRouteRuntimeState
	var coordinator := host_route.get_node_or_null(
		"SingleplayerCombatCoordinator"
	) as RogueCombatSingleplayerCoordinator
	_expect(runtime != null and coordinator != null, "单人路线必须具备运行状态与协调器。")
	if runtime != null and coordinator != null:
		_expect(
			runtime.try_move(
				combat_node_id,
				host_route.generation_config.move_action_cost,
				runtime.state_revision
			),
			"单人路线必须能进入池选的地下教会节点。"
		)
		var battle := await _wait_for_active_battle(coordinator)
		_expect(
			battle != null
			and host_route.get_active_combat_config_id() == TARGET_CONFIG_ID
			and coordinator.get("_active_encounter_config") == TARGET_CONFIG
			and battle.scene_file_path == TARGET_SCENE_PATH
			and battle.event_title == "地下教会"
			and battle.singleplayer_campaign != null
			and battle.singleplayer_campaign.get_waves().size() == 1
			and battle.singleplayer_campaign.get_waves()[0].get_total_enemy_count()
			== 70,
			"正式池选中地下教会后，单人协调器必须实际加载game02与70敌人Campaign。"
		)
		if battle != null:
			var controller := battle.day_night_controller
			_expect(
				battle.world_lighting_policy
				== CombatRuntimeBase.WorldLightingPolicy.FIXED_NIGHT
				and controller != null
				and controller.is_night()
				and is_equal_approx(controller.night_factor, 1.0),
				"池选加载的game02必须保持固定夜晚。"
			)

	_cleanup_route(client_route)
	_cleanup_route(host_route)
	await process_frame
	await physics_frame
	_finish()


func _find_adjacent_underground_church_fixture() -> Dictionary:
	for seed in range(1, MAX_SEED_SEARCH + 1):
		var graph := RogueRouteGenerator.generate(GENERATION_CONFIG, seed)
		if graph == null:
			continue
		for neighbor_id in graph.get_neighbors(graph.start_node_id):
			if (
				graph.get_node_type(neighbor_id)
				!= RogueRouteGraph.NodeType.NORMAL_COMBAT
			):
				continue
			var selected := FLOOR_DEFINITION.select_normal_combat_config(
				graph.get_node_content_seed(neighbor_id)
			)
			if selected != null and selected.encounter_id == TARGET_CONFIG_ID:
				return {
					"seed": seed,
					"combat_node_id": int(neighbor_id),
				}
	return {}


func _wait_for_active_battle(
	coordinator: RogueCombatSingleplayerCoordinator
) -> RogueCombatGame:
	for _frame in MAX_RUNTIME_READY_FRAMES:
		var battle := coordinator.get_active_battle()
		if battle != null and is_instance_valid(battle):
			return battle
		await process_frame
	return null


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
		print("ROGUE_UNDERGROUND_CHURCH_RUNTIME_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)
