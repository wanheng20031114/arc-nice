extends SceneTree

## Measures retained objects between complete production-scene lifetimes. An
## empty run is the autoload-only control; shutdown warnings alone are not a
## per-session leak measurement. No application scripts are preloaded here.
var _cycles := 3
var _enemy_count := 30
var _output_path := "res://dev_tools/output/deep_audit_20260908/resource_lifecycle.json"
var _samples: Array[Dictionary] = []
var _failures: Array[String] = []
var _deadline_msec := 0


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--cycles="):
			_cycles = int(arg.trim_prefix("--cycles="))
		elif arg.begins_with("--enemies="):
			_enemy_count = int(arg.trim_prefix("--enemies="))
		elif arg.begins_with("--output="):
			_output_path = arg.trim_prefix("--output=")
	_deadline_msec = Time.get_ticks_msec() + 90000
	_run.call_deferred()


func _process(_delta: float) -> bool:
	if Time.get_ticks_msec() > _deadline_msec:
		push_error("Resource lifecycle probe exceeded 90 seconds")
		quit(2)
	return false


func _run() -> void:
	Engine.max_fps = 60
	for frame in 3:
		await process_frame
	_samples.append(_capture("autoload_only"))
	for cycle in _cycles:
		await _run_scene_cycle(cycle)
		for frame in 8:
			await process_frame
		_samples.append(_capture("after_cycle_%d" % cycle))
		if _samples[-1]["nodes"] != _samples[0]["nodes"]:
			_failures.append("Scene %d retained nodes after teardown" % cycle)
		if _samples[-1]["orphan_nodes"] != 0:
			_failures.append("Scene %d retained orphan nodes after teardown" % cycle)
		if cycle > 0:
			for key in ["objects", "resources"]:
				if _samples[-1][key] > _samples[2][key]:
					_failures.append("Scene %d grew %s after initial warmup" % [cycle, key])
		for key in ["cold_targets", "cold_heap", "collectible_targets", "collectible_heap"]:
			if _samples[-1][key] != 0:
				_failures.append("Scene %d retained %s" % [cycle, key])
	var result := {"cycles": _cycles, "enemies": _enemy_count, "samples": _samples, "failures": _failures}
	var output := FileAccess.open(_output_path, FileAccess.WRITE)
	output.store_string(JSON.stringify(result, "\t"))
	output.close()
	print("RESOURCE_LIFECYCLE ", JSON.stringify(result))
	root.get_node("PublicRoomLease").call("request_application_shutdown", 0 if _failures.is_empty() else 1)


func _run_scene_cycle(cycle: int) -> void:
	root.get_node("RunState").call("begin_new_run", &"weishidaier", false)
	var packed := load("res://scene/game_modes/tower_defense/tower_defense_game.tscn") as PackedScene
	var runtime := packed.instantiate()
	var runtime_ref: WeakRef = weakref(runtime)
	runtime.set("auto_start_waves", false)
	runtime.set("day_phase_announcements_enabled", false)
	root.add_child(runtime)
	current_scene = runtime
	runtime.call("activate_runtime")
	var player: Node2D = runtime.get("player")
	player.set("current_health", 1000000)
	player.set("max_health", 1000000)
	var enemy_container := runtime.get("enemy_container") as Node
	var coordinator := runtime.get("enemy_coordinator") as Node
	var config := load("res://resources/config/enemies/yuanshi_insect_basic.tres").duplicate() as Resource
	config.set("max_health", 100000)
	var enemy_scene := config.get("enemy_scene") as PackedScene
	for index in _enemy_count:
		var enemy := enemy_scene.instantiate() as Node2D
		enemy_container.add_child(enemy)
		enemy.position = Vector2(420 + index % 10 * 18, 200 + index / 10 * 18)
		enemy.call("setup", config, player, null, runtime)
		coordinator.call("assign_enemy_targets", enemy, enemy.global_position)
		coordinator.call("finalize_authoritative_enemy_spawn", enemy, config, enemy.global_position, false)
		enemy.call("apply_cold_status")
		enemy.call("apply_burn_status", &"lifecycle_probe", 600.0, 1)
	for frame in 12:
		await physics_frame
	_samples.append(_capture("active_cycle_%d" % cycle))
	runtime.call("prepare_for_scene_teardown")
	current_scene = null
	runtime.queue_free()
	for frame in 6:
		await process_frame
	if runtime_ref.get_ref() != null:
		_failures.append("Scene %d root survived queue_free" % cycle)


func _capture(label: String) -> Dictionary:
	var cold := root.get_node("ColdStatusScheduler")
	var collectibles := root.get_node("EnemyCollectibleStatusScheduler")
	return {
		"label": label,
		"nodes": int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
		"orphan_nodes": int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)),
		"objects": int(Performance.get_monitor(Performance.OBJECT_COUNT)),
		"resources": int(Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT)),
		"memory_bytes": int(Performance.get_monitor(Performance.MEMORY_STATIC)),
		"cold_targets": int(cold.call("get_active_target_count")),
		"cold_heap": int(cold.call("get_heap_size")),
		"collectible_targets": int(collectibles.call("get_active_target_count")),
		"collectible_heap": int(collectibles.call("get_heap_size")),
	}
