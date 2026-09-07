extends SceneTree

## Uses the real enemy scene/index/facade. The runtime is kept outside the tree:
## this fixture exercises queries, not waves, AI or native rendering throughput.
var _failures: Array[String] = []
var _enemies: Array[Enemy] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var runtime := TowerDefenseGame.new()
	var facade := CombatQueryFacade.new(runtime)
	var packed := load("res://scene/enemy/enemy.tscn") as PackedScene
	for index in 300:
		var enemy := packed.instantiate() as Enemy
		root.add_child(enemy)
		enemy.set_physics_process(false)
		enemy.global_position = Vector2((index % 25) * 20, (index / 25) * 20)
		enemy.set_meta(&"net_id", 300 - index)
		runtime.combat_target_index.register_enemy(300 - index, enemy)
		_enemies.append(enemy)
	var ordered: Array[Node2D] = []
	var unordered: Array[Node2D] = []
	var indexed: Array[Enemy] = []
	var whole := Rect2(-20, -20, 1000, 1000)
	for bounds in [whole, Rect2(10, 10, 80, 70), Rect2(100, 100, -80, -70), Rect2(), Rect2(Vector2(INF, 0), Vector2.ONE)]:
		facade.query_world_aabb_into(bounds, ordered, null, 0, false, false, true)
		facade.query_world_aabb_unordered_into(bounds, unordered, null, false, false, true)
		_check(_sorted_ids(ordered) == _sorted_ids(unordered), "Candidate set differs for " + str(bounds))
		_check(_ids(ordered) == _sorted_ids(ordered), "Ordered query lost stable IDs")
	facade.query_world_aabb_into(whole, ordered, null, 7, false, false, true)
	_check(_ids(ordered) == [1, 2, 3, 4, 5, 6, 7], "Count limit must follow stable ordering")
	facade.query_world_aabb_unordered_into(whole, unordered, _enemies[0], false, false, true)
	_check(unordered.size() == 299 and not unordered.has(_enemies[0]), "Excluded target returned")
	_enemies[1].is_dead = true
	_enemies[2].queue_free()
	facade.query_world_aabb_unordered_into(whole, unordered, null, false, false, true)
	_check(unordered.size() == 298, "Dead or queued enemy remained visible")
	_enemies[3].global_position = Vector2(5000, 5000)
	facade.query_world_aabb_unordered_into(whole, unordered, null, false, false, true)
	_check(unordered.size() == 297, "Moved enemy remained in the overview")
	var timings := {}
	for mode in ["legacy_double_sort", "ordered_once", "presentation_unordered"]:
		var started := Time.get_ticks_usec()
		for iteration in 200:
			match mode:
				"legacy_double_sort":
					runtime.combat_target_index.query_world_aabb_into(whole, indexed)
					ordered.clear()
					for enemy in indexed:
						ordered.append(enemy)
					ordered.sort_custom(facade._is_stable_candidate_before)
				"ordered_once":
					facade.query_world_aabb_into(whole, ordered, null, 0, false, false, true)
				"presentation_unordered":
					facade.query_world_aabb_unordered_into(whole, unordered, null, false, false, true)
			timings[mode + "_200_queries_usec"] = Time.get_ticks_usec() - started
	var final_count := unordered.size()
	runtime.combat_target_index.clear()
	facade.bind_runtime(null)
	runtime.free()
	ordered.clear()
	unordered.clear()
	indexed.clear()
	for enemy in _enemies:
		if not enemy.is_queued_for_deletion():
			enemy.queue_free()
	_enemies.clear()
	for frame in 3:
		await process_frame
	print("MINIMAP_QUERY_REGRESSION ", JSON.stringify({"failures": _failures, "live_visible": final_count, "timings": timings}))
	quit(0 if _failures.is_empty() else 1)


func _ids(targets: Array[Node2D]) -> Array[int]:
	var result: Array[int] = []
	for target in targets:
		result.append(int(target.get_meta(&"net_id")))
	return result


func _sorted_ids(targets: Array[Node2D]) -> Array[int]:
	var result := _ids(targets)
	result.sort()
	return result


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
		push_error(message)
