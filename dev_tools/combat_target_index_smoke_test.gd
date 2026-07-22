extends SceneTree

const TargetIndexScript := preload("res://scene/combat_target_index.gd")


class AdaptiveProbeIndex:
	extends CombatTargetIndex

	var linear_query_count := 0
	var linear_bounded_query_count := 0
	var ring_query_count := 0
	var flat_query_count := 0
	var radius_registry_query_count := 0
	var radius_bucket_query_count := 0
	var random_registry_query_count := 0
	var random_bucket_query_count := 0
	var bucket_distance_query_count := 0

	func _find_nearest_alive_linear(
		center: Vector2,
		radius: float,
		excluded_instance_ids: Dictionary
	) -> Enemy:
		linear_query_count += 1
		return super._find_nearest_alive_linear(
			center,
			radius,
			excluded_instance_ids
		)

	func _find_nearest_alive_linear_bounded(
		center: Vector2,
		radius: float,
		excluded_instance_ids: Dictionary,
		enforce_radius: bool
	) -> Enemy:
		linear_bounded_query_count += 1
		return super._find_nearest_alive_linear_bounded(
			center,
			radius,
			excluded_instance_ids,
			enforce_radius
		)

	func _find_nearest_alive_ring_in_bounds(
		center: Vector2,
		radius: float,
		excluded_instance_ids: Dictionary,
		minimum_cell: Vector2i,
		maximum_cell: Vector2i,
		center_cell: Vector2i
	) -> Enemy:
		ring_query_count += 1
		return super._find_nearest_alive_ring_in_bounds(
			center,
			radius,
			excluded_instance_ids,
			minimum_cell,
			maximum_cell,
			center_cell
		)

	func _find_nearest_alive_flat(
		center: Vector2,
		radius: float,
		excluded_instance_ids: Dictionary,
		minimum_cell: Vector2i = Vector2i.MAX,
		maximum_cell: Vector2i = Vector2i.MAX
	) -> Enemy:
		flat_query_count += 1
		return super._find_nearest_alive_flat(
			center,
			radius,
			excluded_instance_ids,
			minimum_cell,
			maximum_cell
		)

	func _append_alive_in_radius_registry(
		center: Vector2,
		radius_squared: float,
		result: Array[Enemy]
	) -> void:
		radius_registry_query_count += 1
		super._append_alive_in_radius_registry(center, radius_squared, result)

	func _append_alive_in_radius_buckets(
		center: Vector2,
		radius_squared: float,
		minimum_cell: Vector2i,
		maximum_cell: Vector2i,
		result: Array[Enemy]
	) -> void:
		radius_bucket_query_count += 1
		super._append_alive_in_radius_buckets(
			center,
			radius_squared,
			minimum_cell,
			maximum_cell,
			result
		)

	func _pick_random_alive_in_radius_registry(
		center: Vector2,
		radius_squared: float
	) -> Enemy:
		random_registry_query_count += 1
		return super._pick_random_alive_in_radius_registry(center, radius_squared)

	func _pick_random_alive_in_radius_buckets(
		center: Vector2,
		radius_squared: float,
		minimum_cell: Vector2i,
		maximum_cell: Vector2i
	) -> Enemy:
		random_bucket_query_count += 1
		return super._pick_random_alive_in_radius_buckets(
			center,
			radius_squared,
			minimum_cell,
			maximum_cell
		)

	func _distance_squared_to_bucket(center: Vector2, cell: Vector2i) -> float:
		bucket_distance_query_count += 1
		return super._distance_squared_to_bucket(center, cell)


var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_random_target_selection()
	_test_queued_target_query_contracts()
	_test_nearest_alive_excluding()
	_test_adaptive_nearest_threshold()
	_test_three_stage_local_adaptive()
	_test_adaptive_radius_queries()
	_test_whole_ring_nearest_cutoff()
	_test_strict_nearest_total_order()

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
	var unordered_query: Array[Enemy] = [far_enemy]
	var unordered_buffer := unordered_query
	target_index.call(
		"query_radius_unordered_into",
		Vector2.ZERO,
		100.0,
		unordered_query
	)
	_expect(
		is_same(unordered_buffer, unordered_query)
		and unordered_query.size() == full_boundary_query.size()
		and unordered_query.has(near_enemy)
		and unordered_query.has(middle_enemy)
		and unordered_query.has(boundary_enemy),
		"Unordered radius queries must reuse the caller buffer and preserve exact membership."
	)
	var first_unordered := CombatTargetIndex.take_nearest_candidate(
		unordered_query,
		Vector2.ZERO
	)
	var second_unordered := CombatTargetIndex.take_nearest_candidate(
		unordered_query,
		Vector2.ZERO
	)
	_expect(
		first_unordered == near_enemy
		and second_unordered == middle_enemy
		and unordered_query == [boundary_enemy],
		"Repeated linear extraction must preserve exact nearest order and remove each candidate once."
	)
	CombatTargetIndex.sort_candidates_by_distance(unordered_query, Vector2.ZERO)
	_expect(
		unordered_query == [boundary_enemy],
		"Sorting an adaptive fallback tail must preserve the remaining target exactly."
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
	var nearest_tie_query := tie_index.call(
		"query_radius",
		Vector2.ZERO,
		25.0,
		1
	) as Array[Enemy]
	var expected_tie_first := (
		tie_enemy_a
		if tie_enemy_a.get_instance_id() < tie_enemy_b.get_instance_id()
		else tie_enemy_b
	)
	_expect(
		tie_query.size() == 2
		and tie_query[0] == expected_tie_first
		and nearest_tie_query == [expected_tie_first],
		"Full and linear nearest queries must retain the stable instance-id tie break."
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

	_move_out_of_tree_fixture_enemy(
		middle_enemy,
		Vector2(250.0, 0.0)
	)
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
	_move_out_of_tree_fixture_enemy(
		late_enemy,
		Vector2(350.0, 0.0)
	)
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
		_move_out_of_tree_fixture_enemy(
			crowded_enemy,
			Vector2(65.0, 1.0)
		)
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


func _test_random_target_selection() -> void:
	var random_index: Variant = TargetIndexScript.new()
	var local_enemy := Enemy.new()
	var global_enemy_a := Enemy.new()
	var global_enemy_b := Enemy.new()
	local_enemy.position = Vector2(16.0, 0.0)
	global_enemy_a.position = Vector2(160.0, 0.0)
	global_enemy_b.position = Vector2(320.0, 0.0)
	random_index.call("register_enemy", 101, local_enemy)
	random_index.call("register_enemy", 102, global_enemy_a)
	random_index.call("register_enemy", 103, global_enemy_b)

	_expect(
		random_index.call(
			"pick_random_alive_in_radius",
			Vector2.ZERO,
			32.0
		) == local_enemy,
		"A bounded random query with one local target must return that target."
	)
	_expect(
		random_index.call(
			"pick_random_alive_in_radius",
			Vector2(800.0, 0.0),
			16.0
		) == null,
		"A bounded random query must return null when its local radius is empty."
	)

	seed(20260722)
	var observed_global_ids: Dictionary[int, bool] = {}
	var every_global_pick_was_alive := true
	for _pick_index in range(64):
		var picked_enemy := random_index.call("pick_random_alive") as Enemy
		if (
			picked_enemy == null
			or not is_instance_valid(picked_enemy)
			or picked_enemy.is_dead
		):
			every_global_pick_was_alive = false
			continue
		observed_global_ids[picked_enemy.get_instance_id()] = true
	_expect(
		every_global_pick_was_alive and observed_global_ids.size() > 1,
		"Repeated global random picks must return live registered targets without degenerating to one fixed entry."
	)
	random_index.call("clear")
	for enemy in [local_enemy, global_enemy_a, global_enemy_b]:
		enemy.free()

	var dead_index: Variant = TargetIndexScript.new()
	var dead_enemy := Enemy.new()
	dead_enemy.position = Vector2(8.0, 0.0)
	dead_index.call("register_enemy", 201, dead_enemy)
	dead_enemy.is_dead = true
	_expect(
		dead_index.call("pick_random_alive_in_radius", Vector2.ZERO, 32.0) == null
		and dead_index.call("pick_random_alive") == null
		and (dead_index.get("enemies_by_net_id") as Dictionary).is_empty()
		and (dead_index.get("bucket_by_net_id") as Dictionary).is_empty(),
		"Random selection must prune a dead target from both global and spatial index structures."
	)
	dead_enemy.free()

	var freed_index: Variant = TargetIndexScript.new()
	var freed_enemy := Enemy.new()
	freed_index.call("register_enemy", 301, freed_enemy)
	freed_enemy.free()
	_expect(
		freed_index.call("pick_random_alive") == null
		and (freed_index.get("enemies_by_net_id") as Dictionary).is_empty()
		and (freed_index.get("bucket_by_net_id") as Dictionary).is_empty(),
		"Global random selection must prune a freed target instead of returning a stale reference."
	)


func _test_queued_target_query_contracts() -> void:
	var queued_index: Variant = TargetIndexScript.new()
	var queued_get := _register_queued_enemy(queued_index, 601)
	_expect(
		not CombatTargetIndex.is_enemy_queryable(queued_get)
		and queued_index.call("get_enemy", 601) == null,
		"Direct indexed lookup must reject a still-valid enemy queued for deletion."
	)

	_register_queued_enemy(queued_index, 602)
	_expect(
		(queued_index.call("get_all_alive") as Array[Enemy]).is_empty(),
		"Full indexed queries must reject queued enemies."
	)
	_register_queued_enemy(queued_index, 603)
	_expect(
		queued_index.call("pick_random_alive") == null,
		"Global random indexed queries must reject queued enemies."
	)
	_register_queued_enemy(queued_index, 604)
	_expect(
		queued_index.call(
			"pick_random_alive_in_radius",
			Vector2.ZERO,
			32.0
		) == null,
		"Radius-random indexed queries must reject queued enemies."
	)
	_register_queued_enemy(queued_index, 605)
	_expect(
		(queued_index.call(
			"query_radius",
			Vector2.ZERO,
			32.0,
			0
		) as Array[Enemy]).is_empty(),
		"Sorted radius indexed queries must reject queued enemies."
	)
	_register_queued_enemy(queued_index, 606)
	var unordered: Array[Enemy] = []
	queued_index.call(
		"query_radius_unordered_into",
		Vector2.ZERO,
		32.0,
		unordered
	)
	_expect(
		unordered.is_empty()
		and (queued_index.get("enemies_by_net_id") as Dictionary).is_empty()
		and (queued_index.get("bucket_by_net_id") as Dictionary).is_empty(),
		"Every indexed query path must prune queued targets from dense and spatial registries."
	)


func _register_queued_enemy(target_index: Variant, net_id: int) -> Enemy:
	var enemy := Enemy.new()
	enemy.position = Vector2(8.0, 0.0)
	target_index.call("register_enemy", net_id, enemy)
	enemy.queue_free()
	return enemy


func _test_nearest_alive_excluding() -> void:
	var exclusion_index: Variant = TargetIndexScript.new()
	exclusion_index.set("bucket_size", 32.0)
	var nearest_enemy := Enemy.new()
	var middle_enemy := Enemy.new()
	var tie_enemy_a := Enemy.new()
	var tie_enemy_b := Enemy.new()
	var queued_enemy := Enemy.new()
	nearest_enemy.position = Vector2(8.0, 0.0)
	middle_enemy.position = Vector2(65.0, 0.0)
	tie_enemy_a.position = Vector2(-130.0, 0.0)
	tie_enemy_b.position = Vector2(130.0, 0.0)
	queued_enemy.position = Vector2(1.0, 0.0)
	exclusion_index.call("register_enemy", 401, nearest_enemy)
	exclusion_index.call("register_enemy", 402, middle_enemy)
	exclusion_index.call("register_enemy", 403, tie_enemy_a)
	exclusion_index.call("register_enemy", 404, tie_enemy_b)
	exclusion_index.call("register_enemy", 405, queued_enemy)
	queued_enemy.queue_free()
	_expect(
		queued_enemy.is_queued_for_deletion(),
		"Queued-target fixture must remain valid but be marked for deferred deletion."
	)

	var empty_exclusions: Dictionary = {}
	var invalid_exclusions: Dictionary = {-1: true, 9223372036854775807: true}
	_expect(
		exclusion_index.call(
			"find_nearest_alive_excluding",
			Vector2.ZERO,
			160.0,
			empty_exclusions
		) == nearest_enemy
		and exclusion_index.call(
			"find_nearest_alive_excluding",
			Vector2.ZERO,
			160.0,
			invalid_exclusions
		) == nearest_enemy,
		"Empty and unknown instance-id exclusions must preserve the nearest target."
	)
	_expect(
		not (exclusion_index.get("enemies_by_net_id") as Dictionary).has(405),
		"A positive-radius adaptive linear query must prune queued registry entries."
	)

	var excluded_nearest: Dictionary = {
		nearest_enemy.get_instance_id(): true,
	}
	_expect(
		exclusion_index.call(
			"find_nearest_alive_excluding",
			Vector2.ZERO,
			160.0,
			excluded_nearest
		) == middle_enemy,
		"A valid exclusion must skip the nearest target without building candidates."
	)

	var excluded_first_two: Dictionary = {
		nearest_enemy.get_instance_id(): true,
		middle_enemy.get_instance_id(): true,
	}
	var expected_tie_first := (
		tie_enemy_a
		if tie_enemy_a.get_instance_id() < tie_enemy_b.get_instance_id()
		else tie_enemy_b
	)
	_expect(
		exclusion_index.call(
			"find_nearest_alive_excluding",
			Vector2.ZERO,
			160.0,
			excluded_first_two
		) == expected_tie_first,
		"Excluded nearest targets must continue across buckets and retain the instance-id tie break."
	)
	_expect(
		exclusion_index.call(
			"find_nearest_alive_excluding",
			Vector2.ZERO,
			-1.0,
			excluded_nearest
		) == null
		and exclusion_index.call(
			"find_nearest_alive_excluding",
			Vector2.ZERO,
			0.0,
			excluded_nearest
		) == null,
		"A negative radius must be rejected and a zero radius must remain a closed point query."
	)
	_expect(
		exclusion_index.call(
			"find_nearest_alive_excluding",
			Vector2(NAN, 0.0),
			160.0,
			empty_exclusions
		) == null
		and exclusion_index.call(
			"find_nearest_alive_excluding",
			Vector2.ZERO,
			NAN,
			empty_exclusions
		) == null
		and exclusion_index.call(
			"find_nearest_alive_excluding",
			Vector2.ZERO,
			INF,
			empty_exclusions
		) == null,
		"Non-finite nearest-query inputs must be rejected before spatial conversion."
	)

	var excluded_all := excluded_first_two.duplicate()
	excluded_all[tie_enemy_a.get_instance_id()] = true
	excluded_all[tie_enemy_b.get_instance_id()] = true
	_expect(
		exclusion_index.call(
			"find_nearest_alive_excluding",
			Vector2.ZERO,
			160.0,
			excluded_all
		) == null,
		"Excluding every in-radius target must return null."
	)

	var coincident_enemy := Enemy.new()
	coincident_enemy.position = Vector2.ZERO
	exclusion_index.call("register_enemy", 406, coincident_enemy)
	_expect(
		exclusion_index.call(
			"find_nearest_alive_excluding",
			Vector2.ZERO,
			0.0,
			empty_exclusions
		) == coincident_enemy
		and exclusion_index.call(
			"find_nearest_alive_excluding",
			Vector2.ZERO,
			0.0,
			{coincident_enemy.get_instance_id(): true}
		) == null,
		"A zero-radius closed query must include only a co-located, non-excluded target."
	)

	exclusion_index.call("clear")
	for enemy in [
		nearest_enemy,
		middle_enemy,
		tie_enemy_a,
		tie_enemy_b,
		queued_enemy,
		coincident_enemy,
	]:
		if is_instance_valid(enemy):
			enemy.free()


func _test_adaptive_nearest_threshold() -> void:
	var adaptive_index := AdaptiveProbeIndex.new()
	var adaptive_enemies: Array[Enemy] = []
	for enemy_index in range(CombatTargetIndex.NEAREST_LINEAR_TARGET_THRESHOLD):
		var enemy := Enemy.new()
		enemy.position = Vector2(16.0 + float(enemy_index) * 8.0, 0.0)
		adaptive_enemies.append(enemy)
		adaptive_index.register_enemy(1_001 + enemy_index, enemy)

	var empty_exclusions: Dictionary = {}
	var expected_nearest := adaptive_enemies[0]
	_expect(
		adaptive_index.find_nearest_alive_excluding(
			Vector2.ZERO,
			48.0,
			empty_exclusions
		) == expected_nearest
		and adaptive_index.linear_query_count == 1
		and adaptive_index.ring_query_count == 0,
		"The inclusive adaptive threshold must use the no-candidate-array linear path."
	)
	_expect(
		adaptive_index.query_radius(Vector2.ZERO, 48.0, 1) == [expected_nearest]
		and adaptive_index.linear_query_count == 2,
		"max_count=1 queries must reuse the adaptive linear nearest path."
	)

	var queued_enemy := Enemy.new()
	queued_enemy.position = Vector2(1.0, 0.0)
	adaptive_enemies.append(queued_enemy)
	adaptive_index.register_enemy(2_001, queued_enemy)
	queued_enemy.queue_free()
	_expect(
		adaptive_index.find_nearest_alive_excluding(
			Vector2.ZERO,
			48.0,
			empty_exclusions
		) == expected_nearest
		and adaptive_index.linear_query_count == 2
		and adaptive_index.ring_query_count == 1,
		"A registry above the threshold must use ring pruning and skip a queued nearest entry."
	)
	_expect(
		adaptive_index.query_radius(Vector2.ZERO, 48.0, 1) == [expected_nearest]
		and adaptive_index.ring_query_count == 1
		and adaptive_index.linear_query_count == 3
		and adaptive_index.enemies_by_net_id.size()
			== CombatTargetIndex.NEAREST_LINEAR_TARGET_THRESHOLD,
		"After ring pruning removes a queued entry, max_count=1 must immediately return to the cheaper threshold-linear path."
	)

	adaptive_index.clear()
	for enemy in adaptive_enemies:
		if enemy != null and is_instance_valid(enemy):
			enemy.free()


func _test_three_stage_local_adaptive() -> void:
	var sparse_index := AdaptiveProbeIndex.new()
	var sparse_enemies: Array[Enemy] = []
	for local_index in range(5):
		var local_enemy := Enemy.new()
		local_enemy.position = Vector2(24.0 + float(local_index) * 32.0, 0.0)
		sparse_enemies.append(local_enemy)
		sparse_index.register_enemy(4_001 + local_index, local_enemy)
	for far_index in range(60):
		var far_enemy := Enemy.new()
		far_enemy.position = Vector2(2_048.0 + float(far_index) * 16.0, 2_048.0)
		sparse_enemies.append(far_enemy)
		sparse_index.register_enemy(4_101 + far_index, far_enemy)
	var queued_enemy := Enemy.new()
	queued_enemy.position = Vector2(1.0, 0.0)
	queued_enemy.queue_free()
	# Register after queue_free so the flat path must explicitly reject it.
	sparse_enemies.append(queued_enemy)
	sparse_index.register_enemy(4_999, queued_enemy)
	var empty_exclusions: Dictionary = {}
	_expect(
		sparse_index.find_nearest_alive_excluding(
			Vector2.ZERO,
			112.0,
			empty_exclusions
		) == sparse_enemies[0]
		and sparse_index.flat_query_count == 1
		and sparse_index.ring_query_count == 0,
		"A large sparse registry in at most sixteen buckets must use flat local selection and skip queued entries."
	)
	_expect(
		sparse_index.query_radius(Vector2.ZERO, 112.0, 1) == [sparse_enemies[0]]
		and sparse_index.flat_query_count == 2,
		"max_count=1 queries must reuse the three-stage flat nearest path."
	)
	_expect(
		sparse_index.find_nearest_alive_excluding(
			Vector2.ZERO,
			1_000.0,
			empty_exclusions
		) == sparse_enemies[0]
		and sparse_index.linear_bounded_query_count == 1
		and sparse_index.ring_query_count == 0,
		"A sparse broad query must scan the compact registry instead of hundreds of empty buckets."
	)

	var dense_index := AdaptiveProbeIndex.new()
	var dense_enemies: Array[Enemy] = []
	for dense_index_value in range(65):
		var dense_enemy := Enemy.new()
		dense_enemy.position = Vector2(
			float(dense_index_value % 9) * 8.0,
			float(dense_index_value / 9) * 8.0
		)
		dense_enemies.append(dense_enemy)
		dense_index.register_enemy(5_001 + dense_index_value, dense_enemy)
	_expect(
		dense_index.find_nearest_alive_excluding(
			Vector2.ZERO,
			112.0,
			empty_exclusions
		) == dense_enemies[0]
		and dense_index.flat_query_count == 0
		and dense_index.ring_query_count == 1,
		"A locally dense registry must stop counting above 32 memberships and retain ring pruning."
	)

	sparse_index.clear()
	dense_index.clear()
	for enemy in sparse_enemies + dense_enemies:
		if enemy != null and is_instance_valid(enemy):
			enemy.free()


func _test_adaptive_radius_queries() -> void:
	var adaptive_index := AdaptiveProbeIndex.new()
	adaptive_index.bucket_size = 32.0
	var non_finite_enemy := Enemy.new()
	non_finite_enemy.position = Vector2(NAN, 0.0)
	adaptive_index.register_enemy(5_999, non_finite_enemy)
	var out_of_range_enemy := Enemy.new()
	out_of_range_enemy.position = Vector2(1.0e20, 0.0)
	adaptive_index.register_enemy(6_000, out_of_range_enemy)
	_expect(
		adaptive_index.enemies_by_net_id.is_empty(),
		"Registration must reject non-finite or non-representable bucket positions."
	)
	non_finite_enemy.free()
	out_of_range_enemy.free()
	var enemies: Array[Enemy] = []
	for enemy_index in range(65):
		var enemy := Enemy.new()
		if enemy_index == 0:
			enemy.position = Vector2.ZERO
		else:
			enemy.position = Vector2(
				512.0 + float(enemy_index % 8) * 64.0,
				512.0 + float(enemy_index / 8) * 64.0
			)
		enemies.append(enemy)
		adaptive_index.register_enemy(6_001 + enemy_index, enemy)

	var narrow_result: Array[Enemy] = []
	adaptive_index.query_radius_unordered_into(
		Vector2.ZERO,
		20.0,
		narrow_result
	)
	_expect(
		narrow_result == [enemies[0]]
		and adaptive_index.radius_bucket_query_count == 1
		and adaptive_index.radius_registry_query_count == 0,
		"A narrow local radius must retain bucket-local query work."
	)

	var broad_result: Array[Enemy] = []
	adaptive_index.query_radius_unordered_into(
		Vector2.ZERO,
		4096.0,
		broad_result
	)
	_expect(
		broad_result.size() == enemies.size()
		and adaptive_index.radius_registry_query_count == 1,
		"A broad sparse radius must switch to one compact-registry pass with exact membership."
	)
	_expect(
		adaptive_index.pick_random_alive_in_radius(Vector2.ZERO, 20.0) == enemies[0]
		and adaptive_index.random_bucket_query_count == 1,
		"Narrow bounded random selection must retain reservoir sampling over local buckets."
	)
	var broad_random := adaptive_index.pick_random_alive_in_radius(
		Vector2.ZERO,
		4096.0
	)
	_expect(
		broad_random != null
		and broad_result.has(broad_random)
		and adaptive_index.random_registry_query_count == 1,
		"Broad bounded random selection must use the compact registry without changing membership."
	)

	var invalid_result: Array[Enemy] = [enemies[0]]
	adaptive_index.query_radius_unordered_into(
		Vector2(NAN, 0.0),
		64.0,
		invalid_result
	)
	_expect(
		invalid_result.is_empty()
		and adaptive_index.query_radius(Vector2.ZERO, INF).is_empty()
		and adaptive_index.pick_random_alive_in_radius(Vector2.ZERO, NAN) == null,
		"Non-finite bounded queries must fail closed before bucket conversion."
	)

	const BENCHMARK_ITERATIONS := 12
	var adaptive_checksum := 0
	var adaptive_started_usec := Time.get_ticks_usec()
	for _iteration in range(BENCHMARK_ITERATIONS):
		adaptive_index.query_radius_unordered_into(
			Vector2.ZERO,
			4096.0,
			broad_result
		)
		adaptive_checksum += broad_result.size()
	var adaptive_elapsed_usec := Time.get_ticks_usec() - adaptive_started_usec
	var legacy_checksum := 0
	var legacy_started_usec := Time.get_ticks_usec()
	for _iteration in range(BENCHMARK_ITERATIONS):
		_legacy_bucket_radius_query(
			adaptive_index,
			Vector2.ZERO,
			4096.0,
			broad_result
		)
		legacy_checksum += broad_result.size()
	var legacy_elapsed_usec := Time.get_ticks_usec() - legacy_started_usec
	_expect(
		adaptive_checksum == legacy_checksum
		and adaptive_elapsed_usec < legacy_elapsed_usec,
		"Adaptive registry and legacy bucket A/B must match exactly and avoid sparse empty-cell work."
	)
	print(
		"COMBAT_TARGET_RADIUS_ADAPTIVE_AB queries=%d targets=%d adaptive_ms=%.3f legacy_ms=%.3f speedup=%.2fx"
		% [
			BENCHMARK_ITERATIONS,
			enemies.size(),
			float(adaptive_elapsed_usec) / 1000.0,
			float(legacy_elapsed_usec) / 1000.0,
			float(legacy_elapsed_usec) / maxf(float(adaptive_elapsed_usec), 1.0),
		]
	)

	adaptive_index.clear()
	for enemy in enemies:
		enemy.free()


func _legacy_bucket_radius_query(
	target_index: CombatTargetIndex,
	center: Vector2,
	radius: float,
	result: Array[Enemy]
) -> void:
	result.clear()
	var radius_squared := radius * radius
	var minimum_cell := target_index.call(
		"_to_bucket",
		center - Vector2.ONE * radius
	) as Vector2i
	var maximum_cell := target_index.call(
		"_to_bucket",
		center + Vector2.ONE * radius
	) as Vector2i
	for cell_x in range(minimum_cell.x, maximum_cell.x + 1):
		for cell_y in range(minimum_cell.y, maximum_cell.y + 1):
			var bucket_variant: Variant = target_index.buckets.get(
				Vector2i(cell_x, cell_y)
			)
			if bucket_variant == null:
				continue
			var bucket := bucket_variant as Array
			for net_id_variant in bucket:
				var enemy := target_index.enemies_by_net_id.get(
					int(net_id_variant)
				) as Enemy
				if (
					CombatTargetIndex.is_enemy_queryable(enemy)
					and center.distance_squared_to(enemy.global_position)
						<= radius_squared
				):
					result.append(enemy)


func _test_whole_ring_nearest_cutoff() -> void:
	var cutoff_index := AdaptiveProbeIndex.new()
	var enemies: Array[Enemy] = []
	for enemy_index in range(500):
		var enemy := Enemy.new()
		enemy.position = (
			Vector2(48.0, 48.0)
			if enemy_index == 0
			else Vector2(900.0, 48.0)
		)
		enemies.append(enemy)
		cutoff_index.register_enemy(7_001 + enemy_index, enemy)
	var nearest := cutoff_index.find_nearest_alive_excluding(
		Vector2(48.0, 48.0),
		1000.0,
		{}
	)
	_expect(
		nearest == enemies[0]
		and cutoff_index.ring_query_count == 1
		and cutoff_index.bucket_distance_query_count == 1,
		"A zero-distance nearest target must terminate later square rings as one unit."
	)
	cutoff_index.clear()
	for enemy in enemies:
		enemy.free()


func _test_strict_nearest_total_order() -> void:
	var strict_index: Variant = TargetIndexScript.new()
	strict_index.set("bucket_size", 32.0)
	# Construct the slightly farther target first so it has the lower instance ID.
	# The old approximate-equality comparator incorrectly preferred that ID.
	var lower_id_farther := Enemy.new()
	var higher_id_nearer := Enemy.new()
	lower_id_farther.position = Vector2(-96.0001, 0.0)
	higher_id_nearer.position = Vector2(96.0, 0.0)
	strict_index.call("register_enemy", 3_001, lower_id_farther)
	strict_index.call("register_enemy", 3_002, higher_id_nearer)
	var empty_exclusions: Dictionary = {}
	var linear_nearest := strict_index.call(
		"_find_nearest_alive_linear",
		Vector2.ZERO,
		200.0,
		empty_exclusions
	) as Enemy
	var ring_nearest := strict_index.call(
		"_find_nearest_alive_ring",
		Vector2.ZERO,
		200.0,
		empty_exclusions
	) as Enemy
	var flat_nearest := strict_index.call(
		"_find_nearest_alive_flat",
		Vector2.ZERO,
		200.0,
		empty_exclusions
	) as Enemy
	var extraction_candidates: Array[Enemy] = [lower_id_farther, higher_id_nearer]
	var extracted := CombatTargetIndex.take_nearest_candidate(
		extraction_candidates,
		Vector2.ZERO
	)
	var sorted_candidates: Array[Enemy] = [lower_id_farther, higher_id_nearer]
	CombatTargetIndex.sort_candidates_by_distance(sorted_candidates, Vector2.ZERO)
	_expect(
		lower_id_farther.get_instance_id() < higher_id_nearer.get_instance_id()
		and linear_nearest == higher_id_nearer
		and ring_nearest == higher_id_nearer
		and flat_nearest == higher_id_nearer
		and extracted == higher_id_nearer
		and sorted_candidates == [higher_id_nearer, lower_id_farther],
		"Nearest selection must use strict distance-squared ordering before the exact instance-id tie break."
	)

	strict_index.call("clear")
	lower_id_farther.free()
	higher_id_nearer.free()


func _move_out_of_tree_fixture_enemy(
	enemy: Enemy,
	new_position: Vector2
) -> void:
	enemy.position = new_position
	# These lightweight Enemy.new() fixtures intentionally never enter a scene
	# tree, so Godot does not dispatch CanvasItem transform notifications for
	# them. Deliver the same notification explicitly to exercise the production
	# event-driven bucket migration instead of waiting for the bounded repair
	# audit to visit an arbitrary subset.
	enemy.notification(CanvasItem.NOTIFICATION_LOCAL_TRANSFORM_CHANGED)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
