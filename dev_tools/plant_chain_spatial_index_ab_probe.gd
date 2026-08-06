extends SceneTree

# Standalone, headless-safe A/B/C probe for plant chain-target spatial queries.
#
# A reconstructs the former resident radius-nine inverse influence index.
# B and C store each plant once in a 48 px or 64 px world-anchor bucket. All
# variants share the exact same PlantDefense objects, insertion order, query
# origins, exclusion sets, distance test, and instance-id tie break.
#
# Default invocation:
#   Godot_console.exe --headless --path . --script \
#     res://dev_tools/plant_chain_spatial_index_ab_probe.gd
#
# Development-only shorter run:
#   ... -- --samples=2 --warmup=1

const TILE_SIZE := 16.0
const LEGACY_INFLUENCE_RADIUS_CELLS := 9
const ANCHOR_48_BUCKET_SIZE := 48.0
const ANCHOR_64_BUCKET_SIZE := 64.0
const QUERY_RANGE_SHORT := 48.0
const QUERY_RANGE_LONG := 112.0
const CASTER_COUNT := 300
const CHAIN_HIT_COUNT := 5
const DEFAULT_SAMPLE_COUNT := 60
const DEFAULT_WARMUP_ROUNDS := 6
const MIN_TIMED_BATCH_USEC := 2_000.0
const MAX_BATCH_REPEATS := 8
const MAINTENANCE_TARGET_COUNT := 64
const PROBE_HEALTH := 1_000_000_000

const VARIANT_LEGACY := 0
const VARIANT_ANCHOR_48 := 1
const VARIANT_ANCHOR_64 := 2
const VARIANT_NAMES := ["legacy_r9", "anchor_48", "anchor_64"]
const ORDER_PERMUTATIONS := [
	[VARIANT_LEGACY, VARIANT_ANCHOR_48, VARIANT_ANCHOR_64],
	[VARIANT_LEGACY, VARIANT_ANCHOR_64, VARIANT_ANCHOR_48],
	[VARIANT_ANCHOR_48, VARIANT_LEGACY, VARIANT_ANCHOR_64],
	[VARIANT_ANCHOR_48, VARIANT_ANCHOR_64, VARIANT_LEGACY],
	[VARIANT_ANCHOR_64, VARIANT_LEGACY, VARIANT_ANCHOR_48],
	[VARIANT_ANCHOR_64, VARIANT_ANCHOR_48, VARIANT_LEGACY],
]

const ACTION_QUERY_SHORT := 0
const ACTION_QUERY_LONG := 1
const ACTION_CHAIN := 2


class ProbeIndex:
	extends RefCounted

	var label := ""
	var query_count := 0
	var bucket_probes := 0
	var bucket_pruned_by_radius := 0
	var bucket_pruned_by_nearest := 0
	var nonempty_bucket_reads := 0
	var index_candidate_visits := 0
	var candidate_visits := 0
	var registry_queries := 0
	var bucket_queries := 0
	var register_writes := 0
	var unregister_writes := 0
	var membership_count := 0
	var collect_diagnostics := true


	func register_target(_target: PlantDefense) -> void:
		pass


	func unregister_target(_target: PlantDefense) -> void:
		pass


	func query_nearest(
		_center: Vector2,
		_radius: float,
		_excluded_instance_ids: Dictionary
	) -> PlantDefense:
		return null


	func reset_query_metrics() -> void:
		query_count = 0
		bucket_probes = 0
		bucket_pruned_by_radius = 0
		bucket_pruned_by_nearest = 0
		nonempty_bucket_reads = 0
		index_candidate_visits = 0
		candidate_visits = 0
		registry_queries = 0
		bucket_queries = 0


	func reset_write_metrics() -> void:
		register_writes = 0
		unregister_writes = 0


	func set_collect_diagnostics(enabled: bool) -> void:
		collect_diagnostics = enabled


	func get_bucket_count() -> int:
		return 0


	func recount_memberships() -> int:
		return 0


	func clear_index() -> void:
		membership_count = 0


	func get_query_metrics() -> Dictionary:
		return {
			"queries": query_count,
			"bucket_probes": bucket_probes,
			"bucket_pruned_by_radius": bucket_pruned_by_radius,
			"bucket_pruned_by_nearest": bucket_pruned_by_nearest,
			"nonempty_bucket_reads": nonempty_bucket_reads,
			"index_candidate_visits": index_candidate_visits,
			"candidate_visits": candidate_visits,
			"registry_queries": registry_queries,
			"bucket_queries": bucket_queries,
		}


	func get_structure_metrics() -> Dictionary:
		return {
			"buckets": get_bucket_count(),
			"memberships": membership_count,
			"recounted_memberships": recount_memberships(),
			"register_writes": register_writes,
			"unregister_writes": unregister_writes,
		}


class LegacyInfluenceIndex:
	extends ProbeIndex

	const CELL_SIZE := 16.0
	const INFLUENCE_RADIUS := 9

	var buckets: Dictionary = {}


	func _init() -> void:
		label = "legacy_r9"


	func register_target(target: PlantDefense) -> void:
		if target == null or not is_instance_valid(target):
			return
		var target_id := int(target.get_instance_id())
		var anchor_cell := _world_to_cell(target.position)
		for cell_y in range(
			anchor_cell.y - INFLUENCE_RADIUS,
			anchor_cell.y + INFLUENCE_RADIUS + 1
		):
			for cell_x in range(
				anchor_cell.x - INFLUENCE_RADIUS,
				anchor_cell.x + INFLUENCE_RADIUS + 1
			):
				var cell := Vector2i(cell_x, cell_y)
				var candidates: Dictionary
				if buckets.has(cell):
					candidates = buckets[cell] as Dictionary
				else:
					candidates = {}
					buckets[cell] = candidates
				if candidates.has(target_id):
					continue
				candidates[target_id] = target
		# Probe fixtures never duplicate-register. Counting once after the real
		# legacy writes keeps diagnostics entirely out of maintenance timings.
		if collect_diagnostics:
			register_writes += 361
			membership_count += 361


	func unregister_target(target: PlantDefense) -> void:
		if target == null or not is_instance_valid(target):
			return
		var target_id := int(target.get_instance_id())
		var anchor_cell := _world_to_cell(target.position)
		for cell_y in range(
			anchor_cell.y - INFLUENCE_RADIUS,
			anchor_cell.y + INFLUENCE_RADIUS + 1
		):
			for cell_x in range(
				anchor_cell.x - INFLUENCE_RADIUS,
				anchor_cell.x + INFLUENCE_RADIUS + 1
			):
				var cell := Vector2i(cell_x, cell_y)
				if not buckets.has(cell):
					continue
				var candidates := buckets[cell] as Dictionary
				if candidates.get(target_id) != target:
					continue
				candidates.erase(target_id)
				if candidates.is_empty():
					buckets.erase(cell)
		# Probe fixtures always unregister a fully registered target.
		if collect_diagnostics:
			unregister_writes += 361
			membership_count -= 361


	func query_nearest(
		center: Vector2,
		radius: float,
		excluded_instance_ids: Dictionary
	) -> PlantDefense:
		if collect_diagnostics:
			query_count += 1
			bucket_probes += 1
		var center_cell := _world_to_cell(center)
		var candidates := buckets.get(center_cell, {}) as Dictionary
		if candidates.is_empty():
			return null
		if collect_diagnostics:
			nonempty_bucket_reads += 1
			bucket_queries += 1
			index_candidate_visits += candidates.size()
			candidate_visits += candidates.size()
		var maximum_distance_squared := radius * radius
		var nearest: PlantDefense = null
		var nearest_distance_squared := maximum_distance_squared
		var nearest_instance_id := 0
		for candidate_id_variant in candidates:
			var candidate_id := int(candidate_id_variant)
			if excluded_instance_ids.has(candidate_id):
				continue
			var candidate := candidates[candidate_id_variant] as PlantDefense
			if (
				candidate == null
				or not is_instance_valid(candidate)
				or candidate.is_dead
				or candidate.is_removing
				or candidate.is_queued_for_deletion()
			):
				continue
			var delta_x := float(candidate.position.x) - float(center.x)
			var delta_y := float(candidate.position.y) - float(center.y)
			var distance_squared := delta_x * delta_x + delta_y * delta_y
			if distance_squared > maximum_distance_squared:
				continue
			if (
				nearest == null
				or distance_squared < nearest_distance_squared
				or (
					distance_squared == nearest_distance_squared
					and candidate_id < nearest_instance_id
				)
			):
				nearest = candidate
				nearest_distance_squared = distance_squared
				nearest_instance_id = candidate_id
		return nearest


	func get_bucket_count() -> int:
		return buckets.size()


	func recount_memberships() -> int:
		var count := 0
		for cell_variant in buckets:
			count += (buckets[cell_variant] as Dictionary).size()
		return count


	func clear_index() -> void:
		buckets.clear()
		membership_count = 0


	func _world_to_cell(world_position: Vector2) -> Vector2i:
		return Vector2i(
			floori(world_position.x / CELL_SIZE),
			floori(world_position.y / CELL_SIZE)
		)


class WorldAnchorIndex:
	extends ProbeIndex

	const SPATIAL_INDEX_SCRIPT := preload(
		"res://scene/combat/targeting/plant_target_spatial_index.gd"
	)

	var bucket_size := 64.0
	var spatial_index: Variant = null


	func _init(new_bucket_size: float, new_label: String) -> void:
		bucket_size = maxf(new_bucket_size, 1.0)
		label = new_label
		spatial_index = SPATIAL_INDEX_SCRIPT.new(bucket_size)
		# Production metrics are opt-in and remain disabled for parity/warmup/
		# timed sweeps. _capture_action_metrics enables them only while untimed.
		spatial_index.set_query_metrics_enabled(false)


	func set_collect_diagnostics(enabled: bool) -> void:
		super.set_collect_diagnostics(enabled)
		if spatial_index != null:
			spatial_index.set_query_metrics_enabled(enabled)


	func register_target(target: PlantDefense) -> void:
		if (
			target == null
			or not is_instance_valid(target)
			or spatial_index == null
		):
			return
		if not bool(spatial_index.register(target, target.position)):
			return
		# The fixture never duplicate-registers. Keep observability outside the
		# production call so maintenance timing measures the real API itself.
		if collect_diagnostics:
			register_writes += 1
			membership_count += 1


	func unregister_target(target: PlantDefense) -> void:
		if (
			target == null
			or not is_instance_valid(target)
			or spatial_index == null
		):
			return
		if not bool(spatial_index.unregister(target)):
			return
		if collect_diagnostics:
			unregister_writes += 1
			membership_count -= 1


	func query_nearest(
		center: Vector2,
		radius: float,
		excluded_instance_ids: Dictionary
	) -> PlantDefense:
		if collect_diagnostics:
			query_count += 1
		var safe_radius := maxf(radius, 0.0)
		if spatial_index == null:
			return null
		var nearest_variant: Variant = spatial_index.find_nearest_world_anchor(
			center,
			safe_radius,
			excluded_instance_ids
		)
		if collect_diagnostics:
			# Production callers do not read this Dictionary in the hot path. Only
			# the separate untimed diagnostic sweep pays this observability cost.
			var spatial_metrics := (
				spatial_index.get_last_query_metrics() as Dictionary
			)
			bucket_probes += int(
				spatial_metrics.get("bucket_cells_considered", 0)
			)
			bucket_pruned_by_radius += int(
				spatial_metrics.get("bucket_cells_pruned_by_radius", 0)
			)
			bucket_pruned_by_nearest += int(
				spatial_metrics.get("bucket_cells_pruned_by_nearest", 0)
			)
			nonempty_bucket_reads += int(
				spatial_metrics.get("non_empty_buckets_visited", 0)
			)
			var visited_candidates := int(
				spatial_metrics.get("candidates_visited", 0)
			)
			index_candidate_visits += visited_candidates
			candidate_visits += visited_candidates
			match spatial_metrics.get("query_mode", &"none") as StringName:
				&"registry":
					registry_queries += 1
				&"buckets":
					bucket_queries += 1
		return nearest_variant as PlantDefense


	func get_bucket_count() -> int:
		if spatial_index == null:
			return 0
		var metrics := spatial_index.get_structure_metrics() as Dictionary
		return int(metrics.get("bucket_count", 0))


	func recount_memberships() -> int:
		if spatial_index == null:
			return 0
		var metrics := spatial_index.get_structure_metrics() as Dictionary
		return int(metrics.get("membership_count", 0))


	func clear_index() -> void:
		if spatial_index != null:
			spatial_index.clear()
		membership_count = 0


var failures: Array[String] = []
var sample_count := DEFAULT_SAMPLE_COUNT
var warmup_rounds := DEFAULT_WARMUP_ROUNDS
var sparse_action_metrics: Dictionary = {}
var blackhole_checksum := 0


func _init() -> void:
	_parse_user_arguments()
	call_deferred(&"_run")


func _run() -> void:
	print(
		"PLANT_CHAIN_SPATIAL_AB_BEGIN samples=%d warmup=%d casters=%d"
		% [sample_count, warmup_rounds, CASTER_COUNT]
	)
	for scenario_name in ["sparse5", "local64", "dense361", "far1024"]:
		if not await _run_scenario(scenario_name):
			break
	if failures.is_empty():
		await _run_maintenance_benchmark()
	await _finish()


func _run_scenario(scenario_name: String) -> bool:
	print("PLANT_CHAIN_SPATIAL_SCENARIO_BEGIN scenario=%s" % scenario_name)
	var fixture := _build_scenario_fixture(scenario_name)
	var targets := fixture["targets"] as Array[PlantDefense]
	var origins := fixture["origins"] as PackedVector2Array
	var indices := _create_indices()
	_register_all_indices(indices, targets)
	_validate_structure_after_build(scenario_name, indices, targets.size())
	_verify_query_and_chain_parity(scenario_name, indices, targets, origins)
	if not failures.is_empty():
		_cleanup_fixture(indices, targets)
		return false

	_print_structure_metrics(scenario_name, indices, targets.size())
	var action_results: Dictionary = {}
	for action_kind in [ACTION_QUERY_SHORT, ACTION_QUERY_LONG, ACTION_CHAIN]:
		var benchmark := _measure_three_way_action(
			indices,
			origins,
			action_kind
		)
		var metrics := _capture_action_metrics(indices, origins, action_kind)
		var action_name := _action_name(action_kind)
		action_results[action_name] = metrics
		_validate_action_metrics(
			scenario_name,
			action_kind,
			metrics,
			origins.size()
		)
		_print_action_result(
			scenario_name,
			action_name,
			benchmark,
			metrics
		)

	if scenario_name == "sparse5":
		sparse_action_metrics = action_results.duplicate(true)
	elif scenario_name == "far1024":
		_validate_far_population_independence(action_results)

	_cleanup_fixture(indices, targets)
	await process_frame
	return failures.is_empty()


func _build_scenario_fixture(scenario_name: String) -> Dictionary:
	var targets: Array[PlantDefense] = []
	match scenario_name:
		"sparse5":
			_append_sparse_targets(targets)
		"local64":
			for cell_y in range(-4, 4):
				for cell_x in range(-4, 4):
					targets.append(_create_target(Vector2i(cell_x, cell_y)))
		"dense361":
			for cell_y in range(-9, 10):
				for cell_x in range(-9, 10):
					targets.append(_create_target(Vector2i(cell_x, cell_y)))
		"far1024":
			_append_sparse_targets(targets)
			for far_y in range(32):
				for far_x in range(32):
					targets.append(_create_target(
						Vector2i(256 + far_x, 256 + far_y)
					))
		_:
			_fail("Unknown plant-chain spatial scenario: %s" % scenario_name)
	var origins := PackedVector2Array()
	for caster_index in range(CASTER_COUNT):
		origins.append(Vector2(
			-8.0 + float(caster_index % 20) * 0.25,
			float(caster_index / 20 - 7) * 0.5
		))
	return {"targets": targets, "origins": origins}


func _append_sparse_targets(targets: Array[PlantDefense]) -> void:
	for cell_x in [0, 2, 4, 6, 8]:
		targets.append(_create_target(Vector2i(cell_x, 0)))


func _create_target(cell: Vector2i) -> PlantDefense:
	var target := PlantDefense.new()
	target.position = _cell_to_world(cell)
	target.max_health = PROBE_HEALTH
	target.current_health = PROBE_HEALTH
	target.is_dead = false
	target.is_removing = false
	target.collision_layer = 0
	target.collision_mask = 0
	return target


func _cell_to_world(cell: Vector2i) -> Vector2:
	return (Vector2(cell) + Vector2.ONE * 0.5) * TILE_SIZE


func _create_indices() -> Array[ProbeIndex]:
	var indices: Array[ProbeIndex] = []
	indices.append(LegacyInfluenceIndex.new())
	indices.append(WorldAnchorIndex.new(
		ANCHOR_48_BUCKET_SIZE,
		"anchor_48"
	))
	indices.append(WorldAnchorIndex.new(
		ANCHOR_64_BUCKET_SIZE,
		"anchor_64"
	))
	return indices


func _register_all_indices(
	indices: Array[ProbeIndex],
	targets: Array[PlantDefense]
) -> void:
	for target in targets:
		for index in indices:
			index.register_target(target)


func _verify_query_and_chain_parity(
	scenario_name: String,
	indices: Array[ProbeIndex],
	targets: Array[PlantDefense],
	origins: PackedVector2Array
) -> void:
	var empty_excluded: Dictionary = {}
	for radius in [QUERY_RANGE_SHORT, QUERY_RANGE_LONG]:
		for origin_index in range(origins.size()):
			var origin := origins[origin_index]
			var expected := _reference_query_nearest(
				targets,
				origin,
				radius,
				empty_excluded
			)
			for index in indices:
				var actual := index.query_nearest(
					origin,
					radius,
					empty_excluded
				)
				if actual != expected:
					_fail(
						(
							"%s %s query parity failed at origin %d radius %.1f: "
							+ "expected=%d actual=%d"
						)
						% [
							scenario_name,
							index.label,
							origin_index,
							radius,
							_instance_id_or_zero(expected),
							_instance_id_or_zero(actual),
						]
					)
					return

	for origin_index in range(origins.size()):
		var origin := origins[origin_index]
		var expected_path := _build_reference_chain_path(targets, origin)
		var expected_ids := expected_path["ids"] as PackedInt64Array
		var expected_points := expected_path["points"] as PackedVector2Array
		if expected_ids.size() != CHAIN_HIT_COUNT:
			_fail(
				"%s reference chain at origin %d produced %d/%d hits."
				% [
					scenario_name,
					origin_index,
					expected_ids.size(),
					CHAIN_HIT_COUNT,
				]
			)
			return
		for index in indices:
			var actual_path := _build_index_chain_path(index, origin)
			var actual_ids := actual_path["ids"] as PackedInt64Array
			var actual_points := actual_path["points"] as PackedVector2Array
			if actual_ids != expected_ids or actual_points != expected_points:
				_fail(
					(
						"%s %s five-hit chain parity failed at origin %d: "
						+ "expected=%s actual=%s"
					)
					% [
						scenario_name,
						index.label,
						origin_index,
						str(expected_ids),
						str(actual_ids),
					]
				)
				return


func _reference_query_nearest(
	targets: Array[PlantDefense],
	center: Vector2,
	radius: float,
	excluded_instance_ids: Dictionary
) -> PlantDefense:
	var maximum_distance_squared := radius * radius
	var nearest: PlantDefense = null
	var nearest_distance_squared := maximum_distance_squared
	var nearest_instance_id := 0
	for candidate in targets:
		if (
			candidate == null
			or not is_instance_valid(candidate)
			or candidate.is_dead
			or candidate.is_removing
			or candidate.is_queued_for_deletion()
		):
			continue
		var candidate_id := int(candidate.get_instance_id())
		if excluded_instance_ids.has(candidate_id):
			continue
		var delta_x := float(candidate.position.x) - float(center.x)
		var delta_y := float(candidate.position.y) - float(center.y)
		var distance_squared := delta_x * delta_x + delta_y * delta_y
		if distance_squared > maximum_distance_squared:
			continue
		if (
			nearest == null
			or distance_squared < nearest_distance_squared
			or (
				distance_squared == nearest_distance_squared
				and candidate_id < nearest_instance_id
			)
		):
			nearest = candidate
			nearest_distance_squared = distance_squared
			nearest_instance_id = candidate_id
	return nearest


func _build_reference_chain_path(
	targets: Array[PlantDefense],
	origin: Vector2
) -> Dictionary:
	var excluded: Dictionary = {}
	var current_position := origin
	var ids := PackedInt64Array()
	var points := PackedVector2Array([origin])
	for hit_index in range(CHAIN_HIT_COUNT):
		var radius := QUERY_RANGE_LONG if hit_index == 0 else QUERY_RANGE_SHORT
		var target := _reference_query_nearest(
			targets,
			current_position,
			radius,
			excluded
		)
		if target == null:
			break
		var target_id := int(target.get_instance_id())
		excluded[target_id] = true
		ids.append(target_id)
		points.append(target.position)
		current_position = target.position
	return {"ids": ids, "points": points}


func _build_index_chain_path(index: ProbeIndex, origin: Vector2) -> Dictionary:
	var excluded: Dictionary = {}
	var current_position := origin
	var ids := PackedInt64Array()
	var points := PackedVector2Array([origin])
	for hit_index in range(CHAIN_HIT_COUNT):
		var radius := QUERY_RANGE_LONG if hit_index == 0 else QUERY_RANGE_SHORT
		var target := index.query_nearest(current_position, radius, excluded)
		if target == null:
			break
		var target_id := int(target.get_instance_id())
		excluded[target_id] = true
		ids.append(target_id)
		points.append(target.position)
		current_position = target.position
	return {"ids": ids, "points": points}


func _measure_three_way_action(
	indices: Array[ProbeIndex],
	origins: PackedVector2Array,
	action_kind: int
) -> Dictionary:
	var fastest_pilot_usec := INF
	for index in indices:
		index.set_collect_diagnostics(false)
		index.reset_query_metrics()
		var pilot_started := Time.get_ticks_usec()
		blackhole_checksum ^= _run_action(index, origins, action_kind, 1)
		var pilot_usec := maxi(Time.get_ticks_usec() - pilot_started, 1)
		fastest_pilot_usec = minf(fastest_pilot_usec, float(pilot_usec))
	var repeats := clampi(
		ceili(MIN_TIMED_BATCH_USEC / maxf(fastest_pilot_usec, 1.0)),
		1,
		MAX_BATCH_REPEATS
	)

	for warmup_index in range(warmup_rounds):
		var order: Array = ORDER_PERMUTATIONS[
			warmup_index % ORDER_PERMUTATIONS.size()
		]
		for variant_index in order:
			blackhole_checksum ^= _run_action(
				indices[int(variant_index)],
				origins,
				action_kind,
				repeats
			)

	var samples_by_variant: Array = [[], [], []]
	var sample_orders: Array = []
	for sample_index in range(sample_count):
		var order: Array = ORDER_PERMUTATIONS[
			sample_index % ORDER_PERMUTATIONS.size()
		]
		sample_orders.append(order.duplicate())
		for variant_index_variant in order:
			var variant_index := int(variant_index_variant)
			var index := indices[variant_index]
			index.reset_query_metrics()
			var started_usec := Time.get_ticks_usec()
			blackhole_checksum ^= _run_action(
				index,
				origins,
				action_kind,
				repeats
			)
			var elapsed_ms := float(
				Time.get_ticks_usec() - started_usec
			) / 1000.0
			(samples_by_variant[variant_index] as Array).append(elapsed_ms)
	return _build_three_way_result(
		samples_by_variant,
		sample_orders,
		repeats
	)


func _run_action(
	index: ProbeIndex,
	origins: PackedVector2Array,
	action_kind: int,
	repeats: int
) -> int:
	var checksum := 0
	for _repeat_index in range(repeats):
		match action_kind:
			ACTION_QUERY_SHORT:
				checksum = _run_query_sweep(
					index,
					origins,
					QUERY_RANGE_SHORT,
					checksum
				)
			ACTION_QUERY_LONG:
				checksum = _run_query_sweep(
					index,
					origins,
					QUERY_RANGE_LONG,
					checksum
				)
			ACTION_CHAIN:
				checksum = _run_chain_sweep(index, origins, checksum)
	return checksum


func _run_query_sweep(
	index: ProbeIndex,
	origins: PackedVector2Array,
	radius: float,
	seed_checksum: int
) -> int:
	var checksum := seed_checksum
	var empty_excluded: Dictionary = {}
	for origin in origins:
		var target := index.query_nearest(origin, radius, empty_excluded)
		if target != null:
			checksum = _mix_checksum(checksum, target.get_instance_id())
	return checksum


func _run_chain_sweep(
	index: ProbeIndex,
	origins: PackedVector2Array,
	seed_checksum: int
) -> int:
	var checksum := seed_checksum
	for origin in origins:
		var excluded: Dictionary = {}
		var current_position := origin
		for hit_index in range(CHAIN_HIT_COUNT):
			var radius := (
				QUERY_RANGE_LONG if hit_index == 0 else QUERY_RANGE_SHORT
			)
			var target := index.query_nearest(
				current_position,
				radius,
				excluded
			)
			if target == null:
				break
			var target_id := int(target.get_instance_id())
			excluded[target_id] = true
			checksum = _mix_checksum(checksum, target_id + hit_index)
			current_position = target.position
	return checksum


func _mix_checksum(current: int, value: int) -> int:
	return int((current + (value % 1_000_003) * 33 + 17) % 2_147_483_647)


func _capture_action_metrics(
	indices: Array[ProbeIndex],
	origins: PackedVector2Array,
	action_kind: int
) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var expected_checksum := -1
	for index in indices:
		index.set_collect_diagnostics(true)
		index.reset_query_metrics()
		var checksum := _run_action(index, origins, action_kind, 1)
		if expected_checksum < 0:
			expected_checksum = checksum
		else:
			_expect(
				checksum == expected_checksum,
				"Action checksum diverged for %s: expected=%d actual=%d."
				% [index.label, expected_checksum, checksum]
			)
		var metrics := index.get_query_metrics()
		metrics["checksum"] = checksum
		result.append(metrics)
		index.set_collect_diagnostics(false)
	return result


func _build_three_way_result(
	samples_by_variant: Array,
	sample_orders: Array,
	repeats: int
) -> Dictionary:
	var summaries: Array[Dictionary] = []
	for variant_index in range(VARIANT_NAMES.size()):
		summaries.append(_summarize(
			samples_by_variant[variant_index] as Array
		))
	var pairs: Array[Dictionary] = []
	pairs.append(_build_pair_result(
		VARIANT_LEGACY,
		VARIANT_ANCHOR_48,
		samples_by_variant,
		sample_orders
	))
	pairs.append(_build_pair_result(
		VARIANT_LEGACY,
		VARIANT_ANCHOR_64,
		samples_by_variant,
		sample_orders
	))
	pairs.append(_build_pair_result(
		VARIANT_ANCHOR_48,
		VARIANT_ANCHOR_64,
		samples_by_variant,
		sample_orders
	))
	return {
		"repeats": repeats,
		"summaries": summaries,
		"pairs": pairs,
	}


func _build_pair_result(
	lhs_index: int,
	rhs_index: int,
	samples_by_variant: Array,
	sample_orders: Array
) -> Dictionary:
	var lhs_samples := samples_by_variant[lhs_index] as Array
	var rhs_samples := samples_by_variant[rhs_index] as Array
	var ratios: Array[float] = []
	var lhs_first_ratios: Array[float] = []
	var rhs_first_ratios: Array[float] = []
	var rhs_wins := 0
	for sample_index in range(mini(lhs_samples.size(), rhs_samples.size())):
		var lhs_ms := maxf(float(lhs_samples[sample_index]), 0.000001)
		var rhs_ms := maxf(float(rhs_samples[sample_index]), 0.000001)
		var ratio := lhs_ms / rhs_ms
		ratios.append(ratio)
		if rhs_ms < lhs_ms:
			rhs_wins += 1
		var order := sample_orders[sample_index] as Array
		if order.find(lhs_index) < order.find(rhs_index):
			lhs_first_ratios.append(ratio)
		else:
			rhs_first_ratios.append(ratio)
	return {
		"lhs": lhs_index,
		"rhs": rhs_index,
		"ratio": _summarize(ratios),
		"rhs_win_rate": (
			float(rhs_wins) / maxf(float(ratios.size()), 1.0)
		),
		"lhs_first_ratio": _summarize(lhs_first_ratios),
		"rhs_first_ratio": _summarize(rhs_first_ratios),
	}


func _validate_structure_after_build(
	scenario_name: String,
	indices: Array[ProbeIndex],
	target_count: int
) -> void:
	var expected_legacy_memberships := target_count * 361
	for variant_index in range(indices.size()):
		var index := indices[variant_index]
		var structure := index.get_structure_metrics()
		var expected_memberships := (
			expected_legacy_memberships
			if variant_index == VARIANT_LEGACY
			else target_count
		)
		_expect(
			int(structure["memberships"]) == expected_memberships,
			"%s %s membership count expected %d, observed %d."
			% [
				scenario_name,
				index.label,
				expected_memberships,
				int(structure["memberships"]),
			]
		)
		_expect(
			int(structure["recounted_memberships"]) == expected_memberships,
			"%s %s tracked/recounted membership mismatch."
			% [scenario_name, index.label]
		)
		_expect(
			int(structure["register_writes"]) == expected_memberships,
			"%s %s register writes expected %d, observed %d."
			% [
				scenario_name,
				index.label,
				expected_memberships,
				int(structure["register_writes"]),
			]
		)
		_expect(
			int(structure["buckets"]) > 0,
			"%s %s did not create any non-empty buckets."
			% [scenario_name, index.label]
		)


func _validate_action_metrics(
	scenario_name: String,
	action_kind: int,
	metrics_by_variant: Array[Dictionary],
	origin_count: int
) -> void:
	var expected_queries := (
		origin_count * CHAIN_HIT_COUNT
		if action_kind == ACTION_CHAIN
		else origin_count
	)
	for variant_index in range(metrics_by_variant.size()):
		var metrics := metrics_by_variant[variant_index]
		_expect(
			int(metrics["queries"]) == expected_queries,
			"%s %s %s expected %d queries, observed %d."
			% [
				scenario_name,
				VARIANT_NAMES[variant_index],
				_action_name(action_kind),
				expected_queries,
				int(metrics["queries"]),
			]
		)
		_expect(
			int(metrics["candidate_visits"]) > 0,
			"%s %s %s did not visit any candidates."
			% [
				scenario_name,
				VARIANT_NAMES[variant_index],
				_action_name(action_kind),
			]
		)


func _validate_far_population_independence(
	far_action_metrics: Dictionary
) -> void:
	_expect(
		not sparse_action_metrics.is_empty(),
		"Far-population validation requires sparse metrics."
	)
	if sparse_action_metrics.is_empty():
		return
	for action_name_variant in sparse_action_metrics:
		var action_name := str(action_name_variant)
		var sparse_metrics := (
			sparse_action_metrics[action_name_variant] as Array[Dictionary]
		)
		var far_metrics := far_action_metrics.get(action_name, []) as Array[Dictionary]
		_expect(
			far_metrics.size() == sparse_metrics.size(),
			"Far metrics are missing action %s." % action_name
		)
		if far_metrics.size() != sparse_metrics.size():
			continue
		for variant_index in range(sparse_metrics.size()):
			for metric_name in [
				"queries",
			]:
				_expect(
					int(far_metrics[variant_index][metric_name])
						== int(sparse_metrics[variant_index][metric_name]),
					(
						"Adding 1024 far targets changed %s for %s %s: "
						+ "%d -> %d."
					)
					% [
						metric_name,
						VARIANT_NAMES[variant_index],
						action_name,
						int(sparse_metrics[variant_index][metric_name]),
						int(far_metrics[variant_index][metric_name]),
					]
				)
			for bounded_metric_name in ["bucket_probes", "candidate_visits"]:
				_expect(
					int(far_metrics[variant_index][bounded_metric_name])
						<= int(
							sparse_metrics[variant_index][bounded_metric_name]
						),
					(
						"Adding 1024 far targets increased %s for %s %s: "
						+ "%d -> %d."
					)
					% [
						bounded_metric_name,
						VARIANT_NAMES[variant_index],
						action_name,
						int(
							sparse_metrics[variant_index][bounded_metric_name]
						),
						int(far_metrics[variant_index][bounded_metric_name]),
					]
				)
			_expect(
				int(far_metrics[variant_index]["index_candidate_visits"])
					<= int(
						sparse_metrics[variant_index]["index_candidate_visits"]
					),
				(
					"Adding 1024 far targets increased raw index candidates for "
					+ "%s %s: %d -> %d."
				)
				% [
					VARIANT_NAMES[variant_index],
					action_name,
					int(sparse_metrics[variant_index]["index_candidate_visits"]),
					int(far_metrics[variant_index]["index_candidate_visits"]),
				]
			)


func _run_maintenance_benchmark() -> void:
	print("PLANT_CHAIN_SPATIAL_MAINTENANCE_BEGIN targets=%d" % MAINTENANCE_TARGET_COUNT)
	var targets: Array[PlantDefense] = []
	for cell_y in range(-4, 4):
		for cell_x in range(-4, 4):
			targets.append(_create_target(Vector2i(cell_x, cell_y)))
	var indices := _create_indices()
	for index in indices:
		# Timed maintenance measures only the index APIs. Probe-only write and
		# membership counters are collected in one untimed pass afterward.
		index.set_collect_diagnostics(false)

	for warmup_index in range(warmup_rounds):
		var register_order: Array = ORDER_PERMUTATIONS[
			warmup_index % ORDER_PERMUTATIONS.size()
		]
		for variant_index_variant in register_order:
			_register_all(
				indices[int(variant_index_variant)],
				targets
			)
		var unregister_order: Array = ORDER_PERMUTATIONS[
			(warmup_index + 3) % ORDER_PERMUTATIONS.size()
		]
		for variant_index_variant in unregister_order:
			_unregister_all(
				indices[int(variant_index_variant)],
				targets
			)

	var register_samples: Array = [[], [], []]
	var unregister_samples: Array = [[], [], []]
	var register_orders: Array = []
	var unregister_orders: Array = []
	var minimum_register_writes := [1_000_000_000, 1_000_000_000, 1_000_000_000]
	var maximum_register_writes := [0, 0, 0]
	var minimum_unregister_writes := [1_000_000_000, 1_000_000_000, 1_000_000_000]
	var maximum_unregister_writes := [0, 0, 0]
	for sample_index in range(sample_count):
		var register_order: Array = ORDER_PERMUTATIONS[
			sample_index % ORDER_PERMUTATIONS.size()
		]
		register_orders.append(register_order.duplicate())
		for variant_index_variant in register_order:
			var variant_index := int(variant_index_variant)
			var index := indices[variant_index]
			var started_usec := Time.get_ticks_usec()
			_register_all(index, targets)
			var elapsed_ms := float(
				Time.get_ticks_usec() - started_usec
			) / 1000.0
			(register_samples[variant_index] as Array).append(elapsed_ms)
		var unregister_order: Array = ORDER_PERMUTATIONS[
			(sample_index + 3) % ORDER_PERMUTATIONS.size()
		]
		unregister_orders.append(unregister_order.duplicate())
		for variant_index_variant in unregister_order:
			var variant_index := int(variant_index_variant)
			var index := indices[variant_index]
			var started_usec := Time.get_ticks_usec()
			_unregister_all(index, targets)
			var elapsed_ms := float(
				Time.get_ticks_usec() - started_usec
			) / 1000.0
			(unregister_samples[variant_index] as Array).append(elapsed_ms)

	# A single untimed sweep reports deterministic write amplification without
	# contaminating the paired maintenance timing samples.
	for variant_index in range(indices.size()):
		var index := indices[variant_index]
		index.set_collect_diagnostics(true)
		index.reset_write_metrics()
		_register_all(index, targets)
		minimum_register_writes[variant_index] = index.register_writes
		maximum_register_writes[variant_index] = index.register_writes
		index.reset_write_metrics()
		_unregister_all(index, targets)
		minimum_unregister_writes[variant_index] = index.unregister_writes
		maximum_unregister_writes[variant_index] = index.unregister_writes
		index.set_collect_diagnostics(false)

	var expected_writes := [
		MAINTENANCE_TARGET_COUNT * 361,
		MAINTENANCE_TARGET_COUNT,
		MAINTENANCE_TARGET_COUNT,
	]
	for variant_index in range(indices.size()):
		var expected := int(expected_writes[variant_index])
		_expect(
			int(minimum_register_writes[variant_index]) == expected
			and int(maximum_register_writes[variant_index]) == expected,
			"%s maintenance register writes were not exactly %d: %d/%d."
			% [
				VARIANT_NAMES[variant_index],
				expected,
				int(minimum_register_writes[variant_index]),
				int(maximum_register_writes[variant_index]),
			]
		)
		_expect(
			int(minimum_unregister_writes[variant_index]) == expected
			and int(maximum_unregister_writes[variant_index]) == expected,
			"%s maintenance unregister writes were not exactly %d: %d/%d."
			% [
				VARIANT_NAMES[variant_index],
				expected,
				int(minimum_unregister_writes[variant_index]),
				int(maximum_unregister_writes[variant_index]),
			]
		)
		var structure := indices[variant_index].get_structure_metrics()
		_expect(
			int(structure["buckets"]) == 0
			and int(structure["memberships"]) == 0
			and int(structure["recounted_memberships"]) == 0,
			"%s maintenance teardown leaked buckets or memberships: %s."
			% [VARIANT_NAMES[variant_index], str(structure)]
		)

	var register_result := _build_three_way_result(
		register_samples,
		register_orders,
		1
	)
	var unregister_result := _build_three_way_result(
		unregister_samples,
		unregister_orders,
		1
	)
	_print_maintenance_result(
		"register",
		register_result,
		minimum_register_writes,
		maximum_register_writes
	)
	_print_maintenance_result(
		"unregister",
		unregister_result,
		minimum_unregister_writes,
		maximum_unregister_writes
	)
	_cleanup_fixture(indices, targets)
	await process_frame


func _register_all(index: ProbeIndex, targets: Array[PlantDefense]) -> void:
	for target in targets:
		index.register_target(target)


func _unregister_all(index: ProbeIndex, targets: Array[PlantDefense]) -> void:
	for target in targets:
		index.unregister_target(target)


func _print_structure_metrics(
	scenario_name: String,
	indices: Array[ProbeIndex],
	target_count: int
) -> void:
	for index in indices:
		var metrics := index.get_structure_metrics()
		print(
			(
				"PLANT_CHAIN_SPATIAL_STRUCTURE scenario=%s variant=%s targets=%d "
				+ "buckets=%d memberships=%d recounted=%d register_writes=%d"
			)
			% [
				scenario_name,
				index.label,
				target_count,
				int(metrics["buckets"]),
				int(metrics["memberships"]),
				int(metrics["recounted_memberships"]),
				int(metrics["register_writes"]),
			]
		)


func _print_action_result(
	scenario_name: String,
	action_name: String,
	benchmark: Dictionary,
	metrics_by_variant: Array[Dictionary]
) -> void:
	var summaries := benchmark["summaries"] as Array[Dictionary]
	print(
		(
			"PLANT_CHAIN_SPATIAL_TIMING scenario=%s action=%s samples=%d repeats=%d "
			+ "legacy_ms=%s anchor48_ms=%s anchor64_ms=%s"
		)
		% [
			scenario_name,
			action_name,
			sample_count,
			int(benchmark["repeats"]),
			_format_summary(summaries[VARIANT_LEGACY]),
			_format_summary(summaries[VARIANT_ANCHOR_48]),
			_format_summary(summaries[VARIANT_ANCHOR_64]),
		]
	)
	for variant_index in range(metrics_by_variant.size()):
		var metrics := metrics_by_variant[variant_index]
		print(
			(
				"PLANT_CHAIN_SPATIAL_QUERY_METRICS scenario=%s action=%s variant=%s "
					+ "queries=%d bucket_probes=%d pruned_radius=%d "
					+ "pruned_nearest=%d nonempty_reads=%d candidates=%d "
					+ "index_candidates=%d registry_queries=%d bucket_queries=%d "
					+ "checksum=%d"
			)
			% [
				scenario_name,
				action_name,
				VARIANT_NAMES[variant_index],
				int(metrics["queries"]),
				int(metrics["bucket_probes"]),
				int(metrics["bucket_pruned_by_radius"]),
				int(metrics["bucket_pruned_by_nearest"]),
				int(metrics["nonempty_bucket_reads"]),
				int(metrics["candidate_visits"]),
				int(metrics["index_candidate_visits"]),
				int(metrics["registry_queries"]),
				int(metrics["bucket_queries"]),
				int(metrics["checksum"]),
			]
		)
	_print_pair_results(
		"scenario=%s action=%s" % [scenario_name, action_name],
		benchmark["pairs"] as Array[Dictionary]
	)


func _print_maintenance_result(
	action_name: String,
	benchmark: Dictionary,
	minimum_writes: Array,
	maximum_writes: Array
) -> void:
	var summaries := benchmark["summaries"] as Array[Dictionary]
	print(
		(
			"PLANT_CHAIN_SPATIAL_MAINTENANCE action=%s targets=%d samples=%d "
			+ "legacy_ms=%s anchor48_ms=%s anchor64_ms=%s "
			+ "writes_minmax=%d/%d,%d/%d,%d/%d"
		)
		% [
			action_name,
			MAINTENANCE_TARGET_COUNT,
			sample_count,
			_format_summary(summaries[VARIANT_LEGACY]),
			_format_summary(summaries[VARIANT_ANCHOR_48]),
			_format_summary(summaries[VARIANT_ANCHOR_64]),
			int(minimum_writes[VARIANT_LEGACY]),
			int(maximum_writes[VARIANT_LEGACY]),
			int(minimum_writes[VARIANT_ANCHOR_48]),
			int(maximum_writes[VARIANT_ANCHOR_48]),
			int(minimum_writes[VARIANT_ANCHOR_64]),
			int(maximum_writes[VARIANT_ANCHOR_64]),
		]
	)
	_print_pair_results(
		"maintenance=%s" % action_name,
		benchmark["pairs"] as Array[Dictionary]
	)


func _print_pair_results(context: String, pairs: Array[Dictionary]) -> void:
	for pair in pairs:
		var lhs_index := int(pair["lhs"])
		var rhs_index := int(pair["rhs"])
		var ratio := pair["ratio"] as Dictionary
		var lhs_first := pair["lhs_first_ratio"] as Dictionary
		var rhs_first := pair["rhs_first_ratio"] as Dictionary
		print(
			(
				"PLANT_CHAIN_SPATIAL_PAIR %s pair=%s_over_%s "
				+ "ratio_p50=%.3f ratio_p95=%.3f rhs_win_rate=%.3f "
				+ "lhs_first_ratio_p50=%.3f rhs_first_ratio_p50=%.3f"
			)
			% [
				context,
				VARIANT_NAMES[lhs_index],
				VARIANT_NAMES[rhs_index],
				float(ratio["p50"]),
				float(ratio["p95"]),
				float(pair["rhs_win_rate"]),
				float(lhs_first["p50"]),
				float(rhs_first["p50"]),
			]
		)


func _action_name(action_kind: int) -> String:
	match action_kind:
		ACTION_QUERY_SHORT:
			return "query_48px"
		ACTION_QUERY_LONG:
			return "query_112px"
		ACTION_CHAIN:
			return "chain_300x5"
	return "unknown"


func _instance_id_or_zero(target: PlantDefense) -> int:
	return int(target.get_instance_id()) if target != null else 0


func _summarize(values: Array) -> Dictionary:
	if values.is_empty():
		return {"p50": 0.0, "p95": 0.0, "p99": 0.0, "max": 0.0}
	var sorted := values.duplicate()
	sorted.sort()
	return {
		"p50": _nearest_rank(sorted, 0.50),
		"p95": _nearest_rank(sorted, 0.95),
		"p99": _nearest_rank(sorted, 0.99),
		"max": float(sorted[sorted.size() - 1]),
	}


func _nearest_rank(sorted: Array, percentile: float) -> float:
	if sorted.is_empty():
		return 0.0
	var index := clampi(
		ceili(clampf(percentile, 0.0, 1.0) * float(sorted.size())) - 1,
		0,
		sorted.size() - 1
	)
	return float(sorted[index])


func _format_summary(summary: Dictionary) -> String:
	return "%.3f/%.3f/%.3f/%.3f" % [
		float(summary["p50"]),
		float(summary["p95"]),
		float(summary["p99"]),
		float(summary["max"]),
	]


func _cleanup_fixture(
	indices: Array[ProbeIndex],
	targets: Array[PlantDefense]
) -> void:
	for index in indices:
		index.clear_index()
	indices.clear()
	for target in targets:
		if target != null and is_instance_valid(target):
			target.free()
	targets.clear()


func _parse_user_arguments() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--samples="):
			sample_count = maxi(
				int(argument.trim_prefix("--samples=")),
				1
			)
		elif argument.begins_with("--warmup="):
			warmup_rounds = maxi(
				int(argument.trim_prefix("--warmup=")),
				0
			)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_fail(message)


func _fail(message: String) -> void:
	if failures.size() < 64:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print(
			"PLANT_CHAIN_SPATIAL_INDEX_AB_PROBE_OK blackhole=%d"
			% blackhole_checksum
		)
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)
