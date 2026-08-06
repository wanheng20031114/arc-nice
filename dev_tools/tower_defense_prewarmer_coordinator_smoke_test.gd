extends SceneTree

const PREWARMER_SCENE := preload(
	"res://scene/game_modes/tower_defense/prewarm/tower_defense_prewarmer_coordinator.tscn"
)
const PLACEMENT_PARTICLES_SCENE := preload(
	"res://scene/plant_defense/effects/plant_placement_particles.tscn"
)
const REMOVAL_SMOKE_SCENE := preload(
	"res://scene/plant_defense/effects/plant_removal_smoke.tscn"
)
const GUARDIAN_POINT_LIGHT_TEXTURE := preload(
	"res://resources/texture/enemy/yuanshi_insect/guardian_point_light.png"
)
const AUTHORED_SHADER_NODE_NAMES: Array[StringName] = [
	&"PlantLifecycleShaderPrewarm",
	&"BambooMortarLifecycleShaderPrewarm",
	&"BambooMortarGlowShaderPrewarm",
]


class RuntimeProbe:
	extends TowerDefenseGame

	var can_continue_prewarm := true

	func _can_continue_runtime_prewarm() -> bool:
		return can_continue_prewarm


var failures: Array[String] = []


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	_test_static_scene_contract()
	_test_source_boundaries()
	var fixture := await _create_fixture()
	if fixture.is_empty():
		_finish()
		return
	var coordinator := fixture["coordinator"] as TowerDefensePrewarmerCoordinator
	var runtime := fixture["runtime"] as RuntimeProbe
	var pathfinder := fixture["pathfinder"] as GridPathfinder

	_test_authored_shader_node_ownership(coordinator)
	_test_strong_typed_binding(coordinator, pathfinder)
	_test_host_client_schedule_branches(coordinator, runtime)
	_test_wave_start_sync_fallback(coordinator, runtime, pathfinder)

	# Cancel the deferred host schedule before freeing the coordinator. This tests
	# no teardown policy and intentionally does not exercise the known cancel leak.
	runtime.can_continue_prewarm = false
	_cleanup_fixture(fixture)
	await process_frame
	_finish()


func _create_fixture() -> Dictionary:
	var coordinator := PREWARMER_SCENE.instantiate() as TowerDefensePrewarmerCoordinator
	_expect(coordinator != null, "PrewarmerCoordinator 场景必须可强类型实例化。")
	if coordinator == null:
		return {}
	root.add_child(coordinator)
	await process_frame

	var runtime := RuntimeProbe.new()
	var pathfinder := GridPathfinder.new()
	var map_camera := Camera2D.new()
	var object_pool := SessionObjectPool.new()
	var boss := TowerDefenseBossCoordinator.new()
	var fate := FateCoordinator.new()
	var no_waves: Array[WaveConfig] = []
	var configured := coordinator.setup(
		runtime,
		pathfinder,
		map_camera,
		object_pool,
		boss,
		fate,
		no_waves,
		PLACEMENT_PARTICLES_SCENE,
		REMOVAL_SMOKE_SCENE,
		GUARDIAN_POINT_LIGHT_TEXTURE
	)
	_expect(configured, "完整依赖必须成功绑定 PrewarmerCoordinator。")
	return {
		"coordinator": coordinator,
		"runtime": runtime,
		"pathfinder": pathfinder,
		"map_camera": map_camera,
		"object_pool": object_pool,
		"boss": boss,
		"fate": fate,
	}


func _test_static_scene_contract() -> void:
	var game_scene_source := FileAccess.get_file_as_string(
		"res://scene/game_modes/tower_defense/tower_defense_game.tscn"
	)
	_expect(
		game_scene_source.count(
			"[node name=\"PrewarmerCoordinator\" parent=\".\" instance="
		) == 1,
		"塔防生产场景必须且只能在稳定 NodePath 静态实例化一个 PrewarmerCoordinator。"
	)
	var misplaced_shader_nodes := false
	for node_name in AUTHORED_SHADER_NODE_NAMES:
		misplaced_shader_nodes = (
			misplaced_shader_nodes
			or game_scene_source.contains("[node name=\"%s\"" % node_name)
		)
	_expect(
		not misplaced_shader_nodes,
		"三个 authored shader 预热节点不得继续由 TowerDefenseGame 根场景持有。"
	)

	var prewarmer_scene_source := FileAccess.get_file_as_string(
		"res://scene/game_modes/tower_defense/prewarm/tower_defense_prewarmer_coordinator.tscn"
	)
	var authored_offsets: Array[int] = []
	for node_name in AUTHORED_SHADER_NODE_NAMES:
		authored_offsets.append(
			prewarmer_scene_source.find("[node name=\"%s\"" % node_name)
		)
	_expect(
		authored_offsets[0] >= 0
		and authored_offsets[0] < authored_offsets[1]
		and authored_offsets[1] < authored_offsets[2],
		"Prewarmer 场景必须按既有顺序 authored 三个 shader 预热子节点。"
	)


func _test_source_boundaries() -> void:
	var coordinator_source := FileAccess.get_file_as_string(
		"res://scene/game_modes/tower_defense/prewarm/tower_defense_prewarmer_coordinator.gd"
	)
	var root_source := FileAccess.get_file_as_string(
		"res://scene/game_modes/tower_defense/tower_defense_game.gd"
	)
	var base_source := FileAccess.get_file_as_string(
		"res://scene/combat/runtime/combat_runtime_base.gd"
	)
	_expect(
		coordinator_source.contains("var tower_grid_pathfinder: GridPathfinder")
		and root_source.contains(
			"@onready var tower_grid_pathfinder: GridPathfinder = grid_pathfinder as GridPathfinder"
		)
		and base_source.contains("@onready var grid_pathfinder: Node = $GridPathfinder"),
		"塔防必须在模式边界强类型绑定 GridPathfinder，且不得修改中性基类字段类型。"
	)
	for forbidden_probe in [
		"tower_grid_pathfinder.has_method(",
		"tower_grid_pathfinder.get(",
		"tower_grid_pathfinder.call(",
	]:
		_expect(
			not coordinator_source.contains(forbidden_probe),
			"塔防专属寻路预热不得再动态探测或调用：%s。" % forbidden_probe
		)
	_expect(
		root_source.contains(
			"prewarmer_coordinator.setup(\n\t\tself,\n\t\ttower_grid_pathfinder"
		)
		and root_source.contains("\t\tPLANT_PLACEMENT_PARTICLES_SCENE,")
		and root_source.contains("\t\tPLANT_REMOVAL_SMOKE_SCENE,"),
		"TowerDefenseGame 必须显式注入强类型寻路器与两个 authored PackedScene。"
	)


func _test_authored_shader_node_ownership(
	coordinator: TowerDefensePrewarmerCoordinator
) -> void:
	for node_name in AUTHORED_SHADER_NODE_NAMES:
		var authored_node := coordinator.get_node_or_null(NodePath(node_name))
		_expect(
			authored_node != null
			and authored_node.get_parent() == coordinator
			and authored_node.owner == coordinator,
			"%s 必须由 PrewarmerCoordinator 场景直接 authored 并持有。" % node_name
		)
	_expect(
		coordinator.plant_lifecycle_shader_prewarm is Sprite2D
		and coordinator.bamboo_mortar_lifecycle_shader_prewarm is Sprite2D
		and coordinator.bamboo_mortar_glow_shader_prewarm is Polygon2D,
		"三个 shader 预热节点必须保持原生 Sprite2D/Sprite2D/Polygon2D 类型。"
	)


func _test_strong_typed_binding(
	coordinator: TowerDefensePrewarmerCoordinator,
	pathfinder: GridPathfinder
) -> void:
	_expect(
		coordinator.is_bound()
		and coordinator.tower_grid_pathfinder == pathfinder
		and coordinator.tower_grid_pathfinder is GridPathfinder,
		"PrewarmerCoordinator 必须保存显式注入的强类型 GridPathfinder。"
	)


func _test_host_client_schedule_branches(
	coordinator: TowerDefensePrewarmerCoordinator,
	runtime: RuntimeProbe
) -> void:
	runtime.runtime_mode = CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY
	coordinator.navigation_prewarm_requested = false
	coordinator.navigation_prewarmed = false
	coordinator.schedule_enemy_navigation_prewarm()
	coordinator.schedule_enemy_navigation_prewarm()
	_expect(
		coordinator.navigation_prewarm_requested,
		"Host 必须只排队一次 deferred navigation 预热并立即设置 requested。"
	)

	runtime.runtime_mode = CombatRuntimeBase.RuntimeMode.CLIENT_VIEW
	coordinator.navigation_prewarm_requested = false
	coordinator.schedule_enemy_navigation_prewarm()
	_expect(
		not coordinator.navigation_prewarm_requested,
		"Client view 必须跳过 navigation 预热调度。"
	)


func _test_wave_start_sync_fallback(
	coordinator: TowerDefensePrewarmerCoordinator,
	runtime: RuntimeProbe,
	pathfinder: GridPathfinder
) -> void:
	pathfinder.is_built = false
	runtime.runtime_mode = CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY
	coordinator.navigation_prewarmed = false
	coordinator.ensure_navigation_prewarmed_sync()
	_expect(
		coordinator.navigation_prewarmed,
		"Host 的 wave-start 同步 fallback 即使网格未构建也必须消费一次尝试并置位。"
	)

	runtime.runtime_mode = CombatRuntimeBase.RuntimeMode.CLIENT_VIEW
	coordinator.navigation_prewarmed = false
	coordinator.ensure_navigation_prewarmed_sync()
	_expect(
		not coordinator.navigation_prewarmed,
		"Client view 的 wave-start fallback 不得改变 navigation_prewarmed。"
	)


func _cleanup_fixture(fixture: Dictionary) -> void:
	(fixture["coordinator"] as TowerDefensePrewarmerCoordinator).free()
	(fixture["runtime"] as RuntimeProbe).free()
	(fixture["pathfinder"] as GridPathfinder).free()
	(fixture["map_camera"] as Camera2D).free()
	(fixture["object_pool"] as SessionObjectPool).free()
	(fixture["boss"] as TowerDefenseBossCoordinator).free()
	(fixture["fate"] as FateCoordinator).free()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("TOWER_DEFENSE_PREWARMER_COORDINATOR_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)
