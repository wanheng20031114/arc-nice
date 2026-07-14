extends SceneTree

const TargetIndexScript := preload("res://scene/combat_target_index.gd")

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var target_index: Variant = TargetIndexScript.new()
	var near_enemy := Enemy.new()
	var middle_enemy := Enemy.new()
	var boundary_enemy := Enemy.new()
	var corner_enemy := Enemy.new()
	var far_enemy := Enemy.new()
	near_enemy.position = Vector2(12.0, 0.0)
	middle_enemy.position = Vector2(70.0, 0.0)
	boundary_enemy.position = Vector2(100.0, 0.0)
	corner_enemy.position = Vector2(100.0, 100.0)
	far_enemy.position = Vector2(190.0, 0.0)
	target_index.call("register_enemy", 1, near_enemy)
	target_index.call("register_enemy", 2, middle_enemy)
	target_index.call("register_enemy", 3, boundary_enemy)
	target_index.call("register_enemy", 4, corner_enemy)
	target_index.call("register_enemy", 5, far_enemy)

	var bucket_by_net_id := target_index.get("bucket_by_net_id") as Dictionary
	var bucket_slot_by_net_id := target_index.get("bucket_slot_by_net_id") as Dictionary
	var buckets := target_index.get("buckets") as Dictionary
	var near_cell: Vector2i = target_index.call("_to_bucket", near_enemy.global_position)
	_expect(
		bucket_by_net_id.size() == 5
		and bucket_slot_by_net_id.size() == 5
		and bucket_by_net_id.get(1) == near_cell
		and buckets.has(near_cell)
		and (buckets[near_cell] as Array).has(1),
		"Registration must immediately populate both the reverse index and spatial bucket."
	)

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
		"Spatial buckets must return the nearest in-radius targets in deterministic order."
	)
	var full_boundary_query := target_index.call(
		"query_radius",
		Vector2.ZERO,
		100.0,
		0
	) as Array[Enemy]
	_expect(
		full_boundary_query.size() == 3
		and full_boundary_query[2] == boundary_enemy
		and not full_boundary_query.has(corner_enemy),
		"Radius queries must include the circular boundary and reject AABB-corner false positives."
	)
	var global_query := target_index.call(
		"query_radius",
		Vector2.ZERO,
		-10.0,
		1
	) as Array[Enemy]
	_expect(
		global_query.size() == 1 and global_query[0] == near_enemy,
		"Non-positive radius must keep the all-target semantic before applying max_count."
	)
	_expect(
		(target_index.call("query_radius", Vector2.ZERO, 0.0, 0) as Array).size() == 5
		and (target_index.call("query_radius", Vector2.ZERO, 100.0, -1) as Array)
		== full_boundary_query,
		"Zero radius must return all alive targets and non-positive max_count must stay unlimited."
	)

	var tie_index: Variant = TargetIndexScript.new()
	var tie_enemy_a := Enemy.new()
	var tie_enemy_b := Enemy.new()
	tie_enemy_a.position = Vector2(-25.0, 0.0)
	tie_enemy_b.position = Vector2(25.0, 0.0)
	tie_index.call("register_enemy", 1, tie_enemy_a)
	tie_index.call("register_enemy", 2, tie_enemy_b)
	var tie_query := tie_index.call("query_radius", Vector2.ZERO, 25.0, 0) as Array[Enemy]
	var expected_tie_first := (
		tie_enemy_a
		if tie_enemy_a.get_instance_id() < tie_enemy_b.get_instance_id()
		else tie_enemy_b
	)
	_expect(
		tie_query.size() == 2 and tie_query[0] == expected_tie_first,
		"Equal-distance targets must retain the stable instance-id tie break."
	)
	tie_index.call("clear")
	tie_enemy_a.free()
	tie_enemy_b.free()

	var reusable_result: Array[Enemy] = [far_enemy]
	target_index.call("query_radius_into", Vector2.ZERO, 100.0, reusable_result, 2)
	_expect(
		reusable_result == nearest_two,
		"query_radius_into must clear and refill the caller-owned result without changing semantics."
	)

	var stable_bucket := buckets[near_cell] as Array
	var stale_buffer := target_index.get("_stale_enemy_net_ids") as Array
	await physics_frame
	target_index.call("query_radius", Vector2.ZERO, 100.0, 0)
	_expect(
		is_same(stable_bucket, (target_index.get("buckets") as Dictionary)[near_cell])
		and is_same(stale_buffer, target_index.get("_stale_enemy_net_ids")),
		"A stable physics refresh must retain bucket arrays and reuse the stale-id buffer."
	)

	middle_enemy.position = Vector2(250.0, 0.0)
	await physics_frame
	target_index.call("query_radius", Vector2.ZERO, 100.0, 0)
	var middle_cell: Vector2i = target_index.call("_to_bucket", middle_enemy.global_position)
	bucket_by_net_id = target_index.get("bucket_by_net_id") as Dictionary
	buckets = target_index.get("buckets") as Dictionary
	_expect(
		bucket_by_net_id.get(2) == middle_cell
		and buckets.has(middle_cell)
		and (buckets[middle_cell] as Array).has(2)
		and not (buckets[near_cell] as Array).has(2),
		"A cross-bucket move must update the reverse map and remove the old membership."
	)

	# Register after this frame has already refreshed, then assign the final spawn
	# position. The next same-frame query must still see the reconciled position.
	var late_enemy := Enemy.new()
	target_index.call("register_enemy", 6, late_enemy)
	late_enemy.position = Vector2(350.0, 0.0)
	_expect(
		(target_index.call("query_radius", Vector2(350.0, 0.0), 1.0, 0) as Array).has(
			late_enemy
		),
		"A same-frame query must see a newly registered enemy at its final spawn position."
	)
	var replacement_enemy := Enemy.new()
	replacement_enemy.position = Vector2(40.0, 0.0)
	target_index.call("register_enemy", 6, replacement_enemy)
	_expect(
		(target_index.call("query_radius", Vector2.ZERO, 50.0, 0) as Array).has(
			replacement_enemy
		)
		and not (target_index.call(
			"query_radius",
			Vector2(350.0, 0.0),
			1.0,
			0
		) as Array).has(late_enemy),
		"Replacing a net id must remove the previous object's bucket membership immediately."
	)

	target_index.call("unregister_enemy", 2)
	_expect(
		target_index.call("get_enemy", 2) == null
		and not (target_index.get("bucket_by_net_id") as Dictionary).has(2),
		"Unregistering a target must synchronously clear registry and bucket mappings."
	)
	boundary_enemy.is_dead = true
	await physics_frame
	target_index.call("get_all_alive")
	_expect(
		target_index.call("get_enemy", 3) == null
		and not (target_index.get("bucket_by_net_id") as Dictionary).has(3),
		"Dead enemies must be pruned from all index structures on refresh."
	)
	near_enemy.free()
	_expect(
		target_index.call("get_enemy", 1) == null
		and not (target_index.get("bucket_by_net_id") as Dictionary).has(1),
		"Freed enemies must be pruned without retaining bucket mappings."
	)
	target_index.call("clear")
	_expect(
		(target_index.call("get_all_alive") as Array).is_empty()
		and (target_index.get("buckets") as Dictionary).is_empty()
		and (target_index.get("bucket_by_net_id") as Dictionary).is_empty(),
		"Target-index teardown must release the registry, buckets, and reverse mappings."
	)
	_expect(
		(target_index.get("bucket_slot_by_net_id") as Dictionary).is_empty(),
		"Target-index teardown must release bucket slot mappings."
	)

	var crowded_index: Variant = TargetIndexScript.new()
	crowded_index.set("bucket_size", 32.0)
	var crowded_enemies: Array[Enemy] = []
	for net_id in range(1, 129):
		var crowded_enemy := Enemy.new()
		crowded_enemy.position = Vector2(1.0, 1.0)
		crowded_enemies.append(crowded_enemy)
		crowded_index.call("register_enemy", net_id, crowded_enemy)
	for crowded_enemy in crowded_enemies:
		crowded_enemy.position = Vector2(65.0, 1.0)
	await physics_frame
	var crowded_result := crowded_index.call(
		"query_radius",
		Vector2(65.0, 1.0),
		2.0,
		0
	) as Array[Enemy]
	var crowded_buckets := crowded_index.get("buckets") as Dictionary
	var crowded_slots := crowded_index.get("bucket_slot_by_net_id") as Dictionary
	var destination_cell := Vector2i(2, 0)
	var destination_bucket := crowded_buckets.get(destination_cell, []) as Array
	var slot_mappings_are_exact := destination_bucket.size() == crowded_enemies.size()
	for slot in range(destination_bucket.size()):
		var net_id := int(destination_bucket[slot])
		if int(crowded_slots.get(net_id, -1)) != slot:
			slot_mappings_are_exact = false
			break
	_expect(
		crowded_result.size() == crowded_enemies.size()
		and not crowded_buckets.has(Vector2i.ZERO)
		and slot_mappings_are_exact,
		"A crowded whole-bucket migration must preserve every target and exact swap-remove slots."
	)
	crowded_index.call("clear")
	for crowded_enemy in crowded_enemies:
		crowded_enemy.free()

	for enemy in [
		middle_enemy,
		boundary_enemy,
		corner_enemy,
		far_enemy,
		late_enemy,
		replacement_enemy,
	]:
		if enemy != null and is_instance_valid(enemy):
			enemy.free()
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
