extends SceneTree

## Diagnostic isolation: load one resource without creating any game entity,
## release the caller's reference, and check whether the graph remains cached.
var _resource_path := "res://scene/game_modes/tower_defense/tower_defense_game.tscn"
var _resource_list_path := ""
var _check_enemy_inheritance := false


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--resource="):
			_resource_path = arg.trim_prefix("--resource=")
		elif arg.begins_with("--resources-file="):
			_resource_list_path = arg.trim_prefix("--resources-file=")
		elif arg == "--enemy-inheritance":
			_check_enemy_inheritance = true
	_run.call_deferred()


func _run() -> void:
	if _check_enemy_inheritance:
		var contract_valid := _verify_enemy_inheritance()
		for frame in 3:
			await process_frame
		quit(0 if contract_valid else 1)
		return
	if not _resource_list_path.is_empty():
		var paths: Variant = JSON.parse_string(FileAccess.get_file_as_string(_resource_list_path))
		var resources: Array[Resource] = []
		for path: String in paths:
			resources.append(load(path))
		print("RESOURCE_CYCLE group_loaded=", resources.size(), " list=", _resource_list_path)
		resources.clear()
		for frame in 3:
			await process_frame
		print("RESOURCE_CYCLE resources=", Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT))
		quit(0)
		return
	var resource := load(_resource_path)
	if resource == null:
		quit(1)
		return
	var resource_ref: WeakRef = weakref(resource)
	print("RESOURCE_CYCLE loaded=", _resource_path, " references=", resource.get_reference_count())
	resource = null
	for frame in 3:
		await process_frame
	print("RESOURCE_CYCLE retained=", resource_ref.get_ref() != null,
		" resources=", Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT),
		" nodes=", Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
	quit(0)


## Loading a sibling before a derived class with its own static storage exposed
## the Godot 4.6.2 retention defect. No game objects need to be instantiated.
func _verify_enemy_inheritance() -> bool:
	var failures: Array[String] = []
	var sibling := load("res://scene/enemy/yuanshi_insect/yuanshi_insect.gd")
	var derived := load("res://scene/enemy/artificial_creation/stone_golem.gd")
	var metrics := load("res://scene/enemy/artificial_creation/stone_golem_performance_metrics.gd")
	derived.call("set_slam_performance_metrics_enabled", true)
	if not bool(metrics.get("enabled")):
		failures.append("Metric enable API must address the shared owner")
	var counters: Dictionary = metrics.get("counters")
	counters["slam_query_calls"] = 7
	var snapshot: Dictionary = derived.call("get_slam_performance_metrics", true)
	if int(snapshot["slam_query_calls"]) != 7:
		failures.append("Snapshot must precede reset and must not alias shared state")
	if int(counters["slam_query_calls"]) != 0:
		failures.append("Reset must clear the shared counters")
	derived.call("set_slam_performance_metrics_enabled", false)
	if bool(metrics.get("enabled")):
		failures.append("Metric disable API must remain effective")
	for failure in failures:
		push_error(failure)
	print("RESOURCE_CYCLE enemy_inheritance_and_metric_contract=", "PASS" if failures.is_empty() else "FAIL")
	sibling = null
	derived = null
	metrics = null
	return failures.is_empty()
