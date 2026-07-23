extends SceneTree

# Focused semantic and CPU probe for the shared ranged-enemy world LOS query.
# The benchmark reports medians for the former allocating path and the reused
# path, but correctness never depends on host timing noise.
const BASIC_CONFIG := preload("res://resources/config/enemies/yuanshi_insect_basic.tres")

const WORLD_MASK := 1
const OTHER_MASK := 2
const BENCHMARK_ITERATIONS := 12000
const BENCHMARK_SAMPLES := 5
const HOT_ARCHETYPE_SOURCES: Array[String] = [
	"res://scene/enemy/capoo_ranged_enemy.gd",
	"res://scene/enemy/capoo/capoo_ak47.gd",
	"res://scene/enemy/capoo/capoo_rpg.gd",
	"res://scene/enemy/capoo/capoo_knight.gd",
	"res://scene/enemy/yuanshi_insect/yuanshi_insect_fire_ranged.gd",
]

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var fixture := Node2D.new()
	fixture.name = "EnemyWorldLosQuerySmokeTest"
	root.add_child(fixture)
	current_scene = fixture

	var enemy := BASIC_CONFIG.enemy_scene.instantiate() as Enemy
	enemy.set_process(false)
	enemy.set_physics_process(false)
	fixture.add_child(enemy)
	enemy.setup(BASIC_CONFIG, null, null)
	enemy.global_position = Vector2.ZERO

	var wall := _create_wall(Vector2(32.0, 0.0), Vector2(8.0, 24.0))
	fixture.add_child(wall)
	await physics_frame

	_test_hot_archetype_source_contract()
	_test_query_semantics(enemy)
	_test_blocked_retry_semantics(enemy)
	var benchmark := _measure_blocked_query_paths(enemy, Vector2(64.0, 0.0))

	fixture.queue_free()
	await process_frame
	await physics_frame
	for _cleanup_frame in range(3):
		await process_frame

	print(
		(
			"ENEMY_WORLD_LOS_QUERY_PROBE iterations=%d reused_ms=%.3f "
			+ "allocating_ms=%.3f speedup=%.2fx samples=%d reused_queries=1 "
			+ "allocating_queries_per_sample=%d"
		)
		% [
			BENCHMARK_ITERATIONS,
			float(benchmark["reused_ms"]),
			float(benchmark["allocating_ms"]),
			float(benchmark["allocating_ms"])
				/ maxf(float(benchmark["reused_ms"]), 0.001),
			BENCHMARK_SAMPLES,
			BENCHMARK_ITERATIONS,
		]
	)
	if failures.is_empty():
		print("ENEMY_WORLD_LOS_QUERY_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _create_wall(wall_position: Vector2, wall_size: Vector2) -> StaticBody2D:
	var wall := StaticBody2D.new()
	wall.position = wall_position
	wall.collision_layer = WORLD_MASK
	wall.collision_mask = 0
	var collision_shape := CollisionShape2D.new()
	var rectangle := RectangleShape2D.new()
	rectangle.size = wall_size
	collision_shape.shape = rectangle
	wall.add_child(collision_shape)
	return wall


func _test_query_semantics(enemy: Enemy) -> void:
	_expect(
		enemy.get("_world_los_query") == null,
		"The reusable LOS query must stay lazy until the first ranged check."
	)

	var blocked_target := Vector2(64.0, 0.0)
	_expect(
		not enemy._is_world_segment_clear(blocked_target, WORLD_MASK),
		"A layer-1 wall between enemy and target must block the shared LOS query."
	)
	var first_query := enemy.get("_world_los_query") as PhysicsRayQueryParameters2D
	_expect(first_query != null, "The first LOS check must initialize one query object.")
	if first_query == null:
		return
	var first_query_id := first_query.get_instance_id()
	_expect(first_query.from.is_equal_approx(Vector2.ZERO), "First query origin is stale.")
	_expect(first_query.to.is_equal_approx(blocked_target), "First query endpoint is stale.")
	_expect(first_query.collision_mask == WORLD_MASK, "First query mask is incorrect.")
	_expect(first_query.collide_with_bodies, "LOS must collide with world bodies.")
	_expect(not first_query.collide_with_areas, "LOS must ignore gameplay Areas.")
	_expect(first_query.exclude.size() == 1, "LOS must exclude exactly its own body RID.")
	if first_query.exclude.size() == 1:
		_expect(first_query.exclude[0] == enemy.get_rid(), "LOS self-exclusion RID is incorrect.")

	var clear_target := Vector2(64.0, 40.0)
	_expect(
		enemy._is_world_segment_clear(clear_target, WORLD_MASK),
		"A segment passing above the wall must remain clear."
	)
	var second_query := enemy.get("_world_los_query") as PhysicsRayQueryParameters2D
	_expect(
		second_query != null and second_query.get_instance_id() == first_query_id,
		"Repeated LOS checks must reuse the same PhysicsRayQueryParameters2D."
	)
	_expect(second_query.to.is_equal_approx(clear_target), "Repeated LOS endpoint was not refreshed.")

	# Moving both endpoints and changing the mask must overwrite every mutable
	# field rather than leaking the previous attempt's origin, endpoint, or mask.
	enemy.global_position = Vector2(0.0, 6.0)
	var moved_target := Vector2(64.0, 6.0)
	_expect(
		enemy._is_world_segment_clear(moved_target, OTHER_MASK),
		"Changing to a mask that excludes the wall must produce a clear segment."
	)
	var moved_query := enemy.get("_world_los_query") as PhysicsRayQueryParameters2D
	_expect(
		moved_query.get_instance_id() == first_query_id,
		"Mask changes must not allocate a replacement LOS query."
	)
	_expect(
		moved_query.from.is_equal_approx(enemy.global_position),
		"Moved enemy origin was not copied into the reused query."
	)
	_expect(moved_query.to.is_equal_approx(moved_target), "Moved endpoint was not refreshed.")
	_expect(moved_query.collision_mask == OTHER_MASK, "Changed collision mask was not refreshed.")
	_expect(
		not enemy._is_world_segment_clear(moved_target, WORLD_MASK),
		"Restoring the world mask must block the moved horizontal segment again."
	)


func _test_hot_archetype_source_contract() -> void:
	for source_path in HOT_ARCHETYPE_SOURCES:
		var source := FileAccess.get_file_as_string(source_path)
		_expect(not source.is_empty(), "Could not read hot archetype source: %s" % source_path)
		_expect(
			source.find("_has_throttled_world_line_of_sight(") >= 0,
			"Hot archetype does not use the shared blocked-LOS retry budget: %s" % source_path
		)
		_expect(
			source.find("PhysicsRayQueryParameters2D.create(") < 0,
			"Hot archetype still allocates a ray query per attempt: %s" % source_path
		)


func _test_blocked_retry_semantics(enemy: Enemy) -> void:
	var target := Node2D.new()
	var replacement_target := Node2D.new()
	enemy.get_parent().add_child(target)
	enemy.get_parent().add_child(replacement_target)
	enemy.global_position = Vector2(0.0, 6.0)
	target.global_position = Vector2(64.0, 6.0)
	replacement_target.global_position = target.global_position
	enemy.call("_invalidate_blocked_world_los_cache")
	var started_msec := int(Time.get_ticks_msec())
	_expect(
		not bool(enemy.call("_has_throttled_world_line_of_sight", target, WORLD_MASK)),
		"The first blocked ranged LOS attempt must still execute and report blocked."
	)
	var retry_after_msec := int(enemy.get("_blocked_world_los_retry_after_msec"))
	var retry_interval_msec := int(enemy.get("_blocked_world_los_retry_interval_msec"))
	_expect(
		retry_interval_msec >= Enemy.BLOCKED_WORLD_LOS_RETRY_MIN_MSEC
		and retry_interval_msec <= Enemy.BLOCKED_WORLD_LOS_RETRY_MAX_MSEC
		and retry_after_msec >= started_msec + retry_interval_msec,
		"Blocked LOS retries must be deterministically staggered inside the 80-120 ms budget."
	)
	var query := enemy.get("_world_los_query") as PhysicsRayQueryParameters2D
	var first_endpoint := query.to
	target.global_position += Vector2(1.0, 0.0)
	_expect(
		not bool(enemy.call("_has_throttled_world_line_of_sight", target, WORLD_MASK))
		and query.to.is_equal_approx(first_endpoint),
		"Sub-threshold target motion must reuse the cached blocked result without another raycast."
	)
	target.global_position += Vector2(8.0, 0.0)
	_expect(
		not bool(enemy.call("_has_throttled_world_line_of_sight", target, WORLD_MASK))
		and query.to.is_equal_approx(target.global_position),
		"Material target motion must invalidate the blocked cache immediately."
	)
	_expect(
		not bool(
			enemy.call(
				"_has_throttled_world_line_of_sight",
				replacement_target,
				WORLD_MASK
			)
		)
		and int(enemy.get("_blocked_world_los_target_instance_id"))
			== replacement_target.get_instance_id(),
		"Changing attack targets must invalidate and replace the blocked LOS cache immediately."
	)
	replacement_target.global_position = Vector2(64.0, 40.0)
	_expect(
		bool(enemy.call("_has_throttled_world_line_of_sight", replacement_target, WORLD_MASK)),
		"A materially moved target with a clear segment must bypass the old blocked cache."
	)
	target.queue_free()
	replacement_target.queue_free()


func _measure_blocked_query_paths(enemy: Enemy, target_position: Vector2) -> Dictionary:
	enemy.global_position = Vector2.ZERO
	# Warm both code paths before alternating their order across median samples.
	for _warmup in range(128):
		enemy._is_world_segment_clear(target_position, WORLD_MASK)
		_legacy_is_world_segment_clear(enemy, target_position, WORLD_MASK)

	var reused_samples: Array[float] = []
	var allocating_samples: Array[float] = []
	for sample_index in range(BENCHMARK_SAMPLES):
		if sample_index % 2 == 0:
			reused_samples.append(_measure_reused_blocked_loop(enemy, target_position))
			allocating_samples.append(_measure_allocating_blocked_loop(enemy, target_position))
		else:
			allocating_samples.append(_measure_allocating_blocked_loop(enemy, target_position))
			reused_samples.append(_measure_reused_blocked_loop(enemy, target_position))
	return {
		"reused_ms": _median(reused_samples),
		"allocating_ms": _median(allocating_samples),
	}


func _measure_reused_blocked_loop(enemy: Enemy, target_position: Vector2) -> float:
	var clear_count := 0
	var started := Time.get_ticks_usec()
	for _iteration in range(BENCHMARK_ITERATIONS):
		if enemy._is_world_segment_clear(target_position, WORLD_MASK):
			clear_count += 1
	var elapsed_ms := float(Time.get_ticks_usec() - started) / 1000.0
	_expect(clear_count == 0, "Reused blocked-loop benchmark unexpectedly crossed the wall.")
	return elapsed_ms


func _measure_allocating_blocked_loop(enemy: Enemy, target_position: Vector2) -> float:
	var clear_count := 0
	var started := Time.get_ticks_usec()
	for _iteration in range(BENCHMARK_ITERATIONS):
		if _legacy_is_world_segment_clear(enemy, target_position, WORLD_MASK):
			clear_count += 1
	var elapsed_ms := float(Time.get_ticks_usec() - started) / 1000.0
	_expect(clear_count == 0, "Allocating blocked-loop benchmark unexpectedly crossed the wall.")
	return elapsed_ms


func _legacy_is_world_segment_clear(
	enemy: Enemy,
	target_position: Vector2,
	collision_mask_value: int
) -> bool:
	var query := PhysicsRayQueryParameters2D.create(
		enemy.global_position,
		target_position,
		collision_mask_value,
		[enemy.get_rid()]
	)
	query.collide_with_bodies = true
	query.collide_with_areas = false
	return enemy.get_world_2d().direct_space_state.intersect_ray(query).is_empty()


func _median(values: Array[float]) -> float:
	var sorted := values.duplicate()
	sorted.sort()
	return sorted[sorted.size() / 2] if not sorted.is_empty() else 0.0


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
