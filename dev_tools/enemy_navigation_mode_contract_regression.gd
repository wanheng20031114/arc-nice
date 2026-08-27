extends SceneTree

const TOWER_SCENE := (
	"res://scene/game_modes/tower_defense/tower_defense_game.tscn"
)
const COMPLEX_SCENES: Array[String] = [
	"res://scene/game_modes/standard/standard_game.tscn",
	"res://scene/game_modes/rogue/combat/rogue_combat_game_01.tscn",
	"res://scene/game_modes/rogue/combat/rogue_combat_game_02.tscn",
	"res://scene/game_modes/rogue/combat/rogue_combat_game_03.tscn",
	"res://scene/game_modes/rogue/combat/rogue_combat_game_04.tscn",
]
const TOWER_NAVIGATION_FORBIDDEN_SOURCES: Array[String] = [
	"res://scene/game_modes/tower_defense/tower_defense_game.gd",
	"res://scene/game_modes/tower_defense/enemy/tower_defense_enemy_coordinator.gd",
	"res://scene/game_modes/tower_defense/prewarm/tower_defense_prewarmer_coordinator.gd",
	"res://scene/game_modes/tower_defense/boss/tower_defense_boss_coordinator.gd",
]
const TOWER_NAVIGATION_FORBIDDEN_TERMS: Array[String] = [
	"GridPathfinder",
	"grid_pathfinder",
	"prewarm_agent_grid",
	"prewarm_flow_navigation_target",
	"try_acquire_agent_navigation_refresh",
]
const TEST_RUNTIME_SCRIPT := preload(
	"res://dev_tools/fixtures/enemy_gameplay_gateway_test_runtime.gd"
)
const SIMPLE_ENEMY_CONFIG := preload(
	"res://resources/config/enemies/yuanshi_insect_basic.tres"
)

var _errors: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	if CombatRuntimeBase.EnemyNavigationMode.COMPLEX_OBSTACLE_AWARE != 0:
		_errors.append("Complex navigation enum serialization value changed.")
	if CombatRuntimeBase.EnemyNavigationMode.SIMPLE_LINEAR != 1:
		_errors.append("Simple navigation enum serialization value changed.")
	_verify_tower_scene()
	for scene_path in COMPLEX_SCENES:
		_verify_complex_scene(scene_path)
	_verify_tower_sources_have_no_complex_navigation_dependency()
	await _verify_simple_enemy_freezes_policy_and_refreshes_target_immediately()
	if _errors.is_empty():
		print("Enemy navigation mode contract regression passed.")
		quit(0)
		return
	for message in _errors:
		push_error(message)
	quit(1)


func _verify_tower_scene() -> void:
	var scene_text := _read_text(TOWER_SCENE)
	if scene_text.is_empty():
		return
	var root_section := _node_section(scene_text, "[node name=\"TowerDefenseGame\"")
	if not root_section.contains("\nenemy_navigation_mode = 1\n"):
		_errors.append("Tower scene must explicitly serialize SIMPLE_LINEAR.")
	if scene_text.contains("[node name=\"GridPathfinder\""):
		_errors.append("Tower scene must not contain a GridPathfinder node.")
	if scene_text.contains("res://scene/combat/navigation/grid_pathfinder.gd"):
		_errors.append("Tower scene must not load the GridPathfinder script.")


func _verify_complex_scene(scene_path: String) -> void:
	var scene_text := _read_text(scene_path)
	if scene_text.is_empty():
		return
	var root_section := _node_section(scene_text, "[node name=")
	if not root_section.contains("\nenemy_navigation_mode = 0\n"):
		_errors.append("%s must explicitly serialize complex navigation." % scene_path)
	if not scene_text.contains("[node name=\"GridPathfinder\""):
		_errors.append("%s must contain GridPathfinder." % scene_path)


func _verify_tower_sources_have_no_complex_navigation_dependency() -> void:
	for source_path in TOWER_NAVIGATION_FORBIDDEN_SOURCES:
		var source_text := _read_text(source_path)
		for forbidden_term in TOWER_NAVIGATION_FORBIDDEN_TERMS:
			if source_text.contains(forbidden_term):
				_errors.append(
					"%s still references forbidden Tower navigation term %s."
					% [source_path, forbidden_term]
				)


func _verify_simple_enemy_freezes_policy_and_refreshes_target_immediately() -> void:
	var runtime := TEST_RUNTIME_SCRIPT.new() as CombatRuntimeBase
	runtime.enemy_navigation_mode = (
		CombatRuntimeBase.EnemyNavigationMode.SIMPLE_LINEAR
	)
	var enemy := SIMPLE_ENEMY_CONFIG.enemy_scene.instantiate() as Enemy
	var first_target := Node2D.new()
	var second_target := Node2D.new()
	root.add_child(enemy)
	root.add_child(first_target)
	root.add_child(second_target)
	await process_frame
	enemy.global_position = Vector2.ZERO
	first_target.global_position = Vector2(30.0, 40.0)
	second_target.global_position = Vector2(-40.0, 30.0)
	var forbidden_pathfinder := Node.new()
	enemy.setup(SIMPLE_ENEMY_CONFIG, null, forbidden_pathfinder, runtime)
	if (
		enemy.pathfinder != null
		or not enemy.uses_simple_enemy_navigation()
		or enemy.cached_navigation_uses_direct_objective_approach
	):
		_errors.append("Simple Enemy.setup() did not freeze and isolate its policy.")
	enemy.set_objective_target(first_target)
	var first_direction := enemy._get_safe_navigation_move_direction(
		first_target,
		forbidden_pathfinder,
		2.0
	)
	if not first_direction.is_equal_approx(Vector2(0.6, 0.8)):
		_errors.append("Simple navigation did not return normalized target delta.")
	# This second identity change occurs in the same process frame. The target
	# setter must invalidate the six-frame cache so it is reflected immediately.
	enemy.set_objective_target(second_target)
	var second_direction := enemy._get_safe_navigation_move_direction(
		second_target,
		forbidden_pathfinder,
		2.0
	)
	if not second_direction.is_equal_approx(Vector2(-0.8, 0.6)):
		_errors.append("Simple navigation delayed an objective identity change.")
	forbidden_pathfinder.free()
	runtime.free()
	enemy.queue_free()
	first_target.queue_free()
	second_target.queue_free()
	await process_frame


func _read_text(resource_path: String) -> String:
	if not FileAccess.file_exists(resource_path):
		_errors.append("Missing resource %s." % resource_path)
		return ""
	return FileAccess.get_file_as_string(resource_path).replace("\r\n", "\n")


func _node_section(scene_text: String, header_prefix: String) -> String:
	var section_start := scene_text.find(header_prefix)
	if section_start < 0:
		return ""
	var section_end := scene_text.find("\n[node ", section_start + header_prefix.length())
	if section_end < 0:
		section_end = scene_text.length()
	return scene_text.substr(section_start, section_end - section_start)
