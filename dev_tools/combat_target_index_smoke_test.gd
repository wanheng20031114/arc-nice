extends SceneTree

const TargetIndexScript := preload("res://scene/combat_target_index.gd")

var failures: Array[String] = []


func _init() -> void:
	var target_index: Variant = TargetIndexScript.new()
	var near_enemy := Enemy.new()
	var middle_enemy := Enemy.new()
	var far_enemy := Enemy.new()
	near_enemy.position = Vector2(12.0, 0.0)
	middle_enemy.position = Vector2(70.0, 0.0)
	far_enemy.position = Vector2(190.0, 0.0)
	target_index.call("register_enemy", 1, near_enemy)
	target_index.call("register_enemy", 2, middle_enemy)
	target_index.call("register_enemy", 3, far_enemy)

	var nearest_two := target_index.call(
		"query_radius",
		Vector2.ZERO,
		100.0,
		2
	) as Array[Enemy]
	_expect(
		nearest_two.size() == 2
		and nearest_two[0] == near_enemy
		and nearest_two[1] == middle_enemy,
		"Spatial buckets must return only in-radius targets in deterministic distance order."
	)
	_expect(
		target_index.call("get_enemy", 3) == far_enemy,
		"Direct net-id lookup must reuse the shared target registry."
	)
	target_index.call("unregister_enemy", 2)
	_expect(
		(target_index.call("query_radius", Vector2.ZERO, 100.0, 0) as Array).size() == 1,
		"Unregistering a terminal enemy must remove it from radius queries."
	)
	near_enemy.free()
	_expect(
		target_index.call("get_enemy", 1) == null,
		"Freed enemies must be pruned without retaining invalid ObjectDB references."
	)
	target_index.call("clear")
	_expect(
		(target_index.call("get_all_alive") as Array).is_empty(),
		"Target-index teardown must release every session mapping."
	)
	middle_enemy.free()
	far_enemy.free()
	if failures.is_empty():
		print("COMBAT_TARGET_INDEX_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
