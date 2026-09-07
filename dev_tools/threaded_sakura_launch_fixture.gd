extends Node

const LIFETIME := preload("res://scene/loading/threaded_resource_lifetime.gd")
const BLOCKER := "res://scene/encyclopedia/encyclopedia_screen.tscn"

var result: Dictionary = {}
var _failures: Array[String] = []

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	(get_tree().root.get_node("RunState") as RunStateStore).begin_new_run(&"weishidaier", false)
	var runtime := load("res://scene/game_modes/tower_defense/tower_defense_game.tscn").instantiate() as TowerDefenseGame
	runtime.auto_start_waves = false
	runtime.day_phase_announcements_enabled = false
	runtime.defer_runtime_activation()
	get_tree().root.add_child(runtime)
	get_tree().current_scene = runtime
	var deadline := Time.get_ticks_msec() + 30000
	while runtime.get_runtime_preparation_state() == RuntimePreparationProvider.PreparationState.PREPARING:
		if Time.get_ticks_msec() > deadline:
			_failures.append("Runtime preparation timed out")
			break
		await get_tree().process_frame
	_check(runtime.is_runtime_preparation_complete(), "Real tower runtime reaches READY")
	runtime.activate_runtime()
	var player := runtime.player
	player.current_health = 100000
	player.max_health = 100000
	var enemy_config := load("res://resources/config/enemies/yuanshi_insect_basic.tres").duplicate() as EnemyConfig
	enemy_config.max_health = 100000
	var target := enemy_config.enemy_scene.instantiate() as Enemy
	runtime.enemy_container.add_child(target)
	target.global_position = player.global_position + Vector2(100, 0)
	target.setup(enemy_config, player, null, runtime)
	runtime.enemy_coordinator.assign_enemy_targets(target, target.global_position)
	runtime.enemy_coordinator.finalize_authoritative_enemy_spawn(target, enemy_config, target.global_position, false)
	await get_tree().physics_frame
	for cache_mode in [ResourceLoader.CACHE_MODE_REUSE, ResourceLoader.CACHE_MODE_REPLACE, ResourceLoader.CACHE_MODE_IGNORE]:
		_check(LIFETIME.get_pending_request_count() == 0, "Previous owners are balanced before a fresh launch")
		player.collectible_sakura_rocket_scene_cache = null
		player.set("_sakura_runtime_load_requested", false)
		_check(LIFETIME.request(BLOCKER, "PackedScene", false, cache_mode) == OK, "Blocking task starts")
		_check(ResourceLoader.load_threaded_request(BLOCKER, "PackedScene", false, cache_mode) == OK,
			"A second native consumer retains the same in-flight task")
		player._request_sakura_runtime_resources()
		var path: String = Player.COLLECTIBLE_SAKURA_ROCKET_SCENE_PATH
		_check(LIFETIME.get_status(path) == ResourceLoader.THREAD_LOAD_IN_PROGRESS,
			"First-use rocket is waiting behind another resource")
		_check(ResourceLoader.load_threaded_get_status(path) == ResourceLoader.THREAD_LOAD_INVALID_RESOURCE,
			"The rocket's native request has not started yet")
		var before := _rockets(runtime)
		_check(player._spawn_collectible_sakura_rocket(target, 17), "Queued first-use rocket launches successfully")
		var after := _rockets(runtime)
		_check(after.size() == before.size() + 1, "Exactly one real projectile is emitted")
		var emitted: LinglanSkill2SakuraRocket = after[-1] if after.size() > before.size() else null
		_check(emitted != null and emitted.target_node == target and emitted.damage == 17,
			"The first projectile preserves its target and damage")
		_check(LIFETIME.get_pending_request_count() == 1, "Blocking wait does not consume the original owner's token")
		var original := LIFETIME.claim(BLOCKER)
		var second_consumer := ResourceLoader.load_threaded_get(BLOCKER)
		_check(original != null and original == second_consumer,
			"Both original consumers retain identical resources for cache mode %d" % cache_mode)
		_check(LIFETIME.get_pending_request_count() == 0, "Blocking first-use leaves the ledger balanced")
		original = null
		second_consumer = null
		if emitted != null:
			emitted.queue_free()
		await get_tree().process_frame
	print("THREADED_SAKURA_LAUNCH ", JSON.stringify({"cache_modes": 3, "failures": _failures}))
	runtime.prepare_for_scene_teardown()
	get_tree().current_scene = null
	runtime.queue_free()
	await get_tree().process_frame
	result["exit_code"] = 0 if _failures.is_empty() else 1
	queue_free()

func _rockets(runtime: Node) -> Array[LinglanSkill2SakuraRocket]:
	var rockets: Array[LinglanSkill2SakuraRocket] = []
	for child in runtime.get_children():
		if child is LinglanSkill2SakuraRocket:
			rockets.append(child)
	return rockets

func _check(condition: bool, description: String) -> void:
	if not condition:
		_failures.append(description)
		push_error(description)
