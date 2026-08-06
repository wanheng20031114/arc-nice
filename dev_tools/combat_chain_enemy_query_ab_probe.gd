extends SceneTree

# Standalone A/B probe for a future player-to-enemy lightning chain.
#
# A reproduces the former caller-owned scratch-array path: collect every enemy
# in radius, reject already-hit instance IDs, then linearly select by
# distance-squared and instance ID. B calls CombatTargetIndex's ring-pruned
# nearest API directly. Each scenario gives both variants the exact same index,
# Enemy instances, positions, origins and exclusion semantics.

const TargetIndexScript := preload("res://scene/combat/targeting/combat_target_index.gd")

const INITIAL_RADIUS := 112.0
const BOUNCE_RADIUS := 48.0
const CASTER_COUNT := 300
const MAX_HITS := 5
const SAMPLE_COUNT := 60
const WARMUP_ROUNDS := 8
const CROSSOVER_SAMPLE_COUNT := 40
const CROSSOVER_WARMUP_ROUNDS := 6
const CROSSOVER_TARGET_COUNTS := [5, 8, 16, 32, 64]
const FLAT_EXPERIMENT_SAMPLE_COUNT := 40
const FLAT_EXPERIMENT_WARMUP_ROUNDS := 6
const TWO_STAGE_MAX_BUCKET_CELLS := 16
const THREE_WAY_SAMPLE_COUNT := 60
const THREE_WAY_WARMUP_ROUNDS := 6
const EXPECTED_QUERIES_PER_SWEEP := CASTER_COUNT * MAX_HITS
const PRODUCTION_BUCKET_SIZE := 96.0

const VARIANT_LEGACY := 0
const VARIANT_RING_PRUNED := 1
const VARIANT_DIRECT_LINEAR := 2
const VARIANT_ADAPTIVE := 3
const VARIANT_FLAT_SHORT := 4
const VARIANT_TWO_STAGE := 5

const SCENARIO_SPARSE_5: StringName = &"sparse5"
const SCENARIO_LOCAL_64: StringName = &"local64"
const SCENARIO_DENSE_361: StringName = &"dense361"
const SCENARIO_FAR_1024: StringName = &"far1024"
const SCENARIO_NAMES: Array[StringName] = [
	SCENARIO_SPARSE_5,
	SCENARIO_LOCAL_64,
	SCENARIO_DENSE_361,
	SCENARIO_FAR_1024,
]
const THREE_WAY_ORDERS := [
	[VARIANT_LEGACY, VARIANT_RING_PRUNED, VARIANT_ADAPTIVE],
	[VARIANT_LEGACY, VARIANT_ADAPTIVE, VARIANT_RING_PRUNED],
	[VARIANT_RING_PRUNED, VARIANT_LEGACY, VARIANT_ADAPTIVE],
	[VARIANT_RING_PRUNED, VARIANT_ADAPTIVE, VARIANT_LEGACY],
	[VARIANT_ADAPTIVE, VARIANT_LEGACY, VARIANT_RING_PRUNED],
	[VARIANT_ADAPTIVE, VARIANT_RING_PRUNED, VARIANT_LEGACY],
]


class ScenarioFixture:
	extends RefCounted

	var label: StringName
	var target_index: Variant = null
	var enemies: Array[Enemy] = []
	var local_enemy_count := 0
	var far_enemy_count := 0

	func _init(new_label: StringName) -> void:
		label = new_label


var failures: Array[String] = []
var caster_origins := PackedVector2Array()
var legacy_scratch: Array[Enemy] = []
var legacy_candidate_visits := 0
var flat_membership_visits := 0
var last_sweep_hits := 0
var last_sweep_queries := 0
var blackhole_checksum := 0
var next_net_id := 1


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	caster_origins = _build_caster_origins()
	if OS.get_cmdline_user_args().has("--flat-only"):
		_run_flat_ring_experiment()
		_finish()
		return
	if OS.get_cmdline_user_args().has("--two-stage-only"):
		_run_two_stage_ring_experiment()
		_finish()
		return
	if OS.get_cmdline_user_args().has("--three-stage-only"):
		_run_three_stage_validation()
		_finish()
		return
	_run_direct_ring_crossover()
	if OS.get_cmdline_user_args().has("--crossover-only"):
		_finish()
		return
	var sparse_legacy_candidates := -1
	for scenario_name in SCENARIO_NAMES:
		var fixture := _build_fixture(scenario_name)
		var parity_ok := _verify_hard_parity(fixture)
		if parity_ok:
			var benchmark := _measure_interleaved_ab(fixture)
			_print_benchmark(fixture, benchmark)
			var candidate_summary := benchmark["legacy_candidates"] as Dictionary
			var candidate_p50 := int(candidate_summary["p50"])
			if scenario_name == SCENARIO_SPARSE_5:
				sparse_legacy_candidates = candidate_p50
			elif (
				scenario_name == SCENARIO_FAR_1024
				and candidate_p50 != sparse_legacy_candidates
			):
				failures.append(
					"far1024 changed local legacy candidates: sparse=%d far=%d."
					% [sparse_legacy_candidates, candidate_p50]
				)
		_cleanup_fixture(fixture)

	_finish()


func _finish() -> void:
	legacy_scratch.clear()
	if failures.is_empty():
		print(
			"COMBAT_CHAIN_ENEMY_QUERY_AB_PROBE_OK checksum=%d"
			% blackhole_checksum
		)
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _build_caster_origins() -> PackedVector2Array:
	var result := PackedVector2Array()
	for caster_index in range(CASTER_COUNT):
		var column := caster_index % 20
		var row := caster_index / 20
		result.append(Vector2(
			(float(column) - 9.5) * 0.20,
			(float(row) - 7.0) * 0.20
		))
	return result


func _build_fixture(scenario_name: StringName) -> ScenarioFixture:
	var fixture := ScenarioFixture.new(scenario_name)
	fixture.target_index = TargetIndexScript.new()
	fixture.target_index.set("bucket_size", PRODUCTION_BUCKET_SIZE)
	match scenario_name:
		SCENARIO_SPARSE_5:
			_add_sparse_chain(fixture)
		SCENARIO_LOCAL_64:
			_add_centered_grid(fixture, 8, 12.0)
		SCENARIO_DENSE_361:
			_add_centered_grid(fixture, 19, 8.0)
		SCENARIO_FAR_1024:
			_add_sparse_chain(fixture)
			_add_far_grid(fixture, 32, 24.0, Vector2(2048.0, 2048.0))
	return fixture


func _build_crossover_fixture(target_count: int) -> ScenarioFixture:
	var fixture := ScenarioFixture.new(&"crossover_%d" % target_count)
	fixture.target_index = TargetIndexScript.new()
	fixture.target_index.set("bucket_size", PRODUCTION_BUCKET_SIZE)
	var positions: Array[Vector2] = []
	for grid_y in range(8):
		for grid_x in range(8):
			positions.append(Vector2(
				(float(grid_x) - 3.5) * 12.0,
				(float(grid_y) - 3.5) * 12.0
			))
	positions.sort_custom(
		func(a: Vector2, b: Vector2) -> bool:
			var a_distance := a.length_squared()
			var b_distance := b.length_squared()
			if a_distance != b_distance:
				return a_distance < b_distance
			if a.y != b.y:
				return a.y < b.y
			return a.x < b.x
	)
	for position_index in range(target_count):
		_register_enemy(fixture, positions[position_index], false)
	return fixture


func _add_sparse_chain(fixture: ScenarioFixture) -> void:
	for local_index in range(5):
		_register_enemy(
			fixture,
			Vector2(24.0 + float(local_index) * 32.0, 0.0),
			false
		)


func _add_centered_grid(
	fixture: ScenarioFixture,
	side_length: int,
	spacing: float
) -> void:
	var half_extent := float(side_length - 1) * 0.5
	for grid_y in range(side_length):
		for grid_x in range(side_length):
			_register_enemy(
				fixture,
				Vector2(
					(float(grid_x) - half_extent) * spacing,
					(float(grid_y) - half_extent) * spacing
				),
				false
			)


func _add_far_grid(
	fixture: ScenarioFixture,
	side_length: int,
	spacing: float,
	origin: Vector2
) -> void:
	for grid_y in range(side_length):
		for grid_x in range(side_length):
			_register_enemy(
				fixture,
				origin + Vector2(float(grid_x), float(grid_y)) * spacing,
				true
			)


func _register_enemy(
	fixture: ScenarioFixture,
	world_position: Vector2,
	is_far: bool
) -> void:
	var enemy := Enemy.new()
	enemy.position = world_position
	fixture.enemies.append(enemy)
	fixture.target_index.call("register_enemy", next_net_id, enemy)
	next_net_id += 1
	if is_far:
		fixture.far_enemy_count += 1
	else:
		fixture.local_enemy_count += 1


func _verify_hard_parity(fixture: ScenarioFixture) -> bool:
	var failure_count_before := failures.size()
	for origin_index in range(caster_origins.size()):
		var origin := caster_origins[origin_index]
		var empty_exclusions: Dictionary = {}
		var expected_single := _oracle_find_nearest(
			fixture,
			origin,
			INITIAL_RADIUS,
			empty_exclusions
		)
		var legacy_single := _legacy_find_nearest(
			fixture,
			origin,
			INITIAL_RADIUS,
			empty_exclusions
		)
		var adaptive_single := fixture.target_index.call(
			"find_nearest_alive_excluding",
			origin,
			INITIAL_RADIUS,
			empty_exclusions
		) as Enemy
		var ring_single := _ring_pruned_find_nearest(
			fixture,
			origin,
			INITIAL_RADIUS,
			empty_exclusions
		)
		var expected_single_id := _instance_id_or_zero(expected_single)
		if (
			_instance_id_or_zero(legacy_single) != expected_single_id
			or _instance_id_or_zero(adaptive_single) != expected_single_id
			or _instance_id_or_zero(ring_single) != expected_single_id
		):
			failures.append(
				"%s single-nearest parity failed at origin %d: expected=%d legacy=%d adaptive=%d ring=%d."
				% [
					fixture.label,
					origin_index,
					expected_single_id,
					_instance_id_or_zero(legacy_single),
					_instance_id_or_zero(adaptive_single),
					_instance_id_or_zero(ring_single),
				]
			)
			break

		var expected_path := _build_chain_path(fixture, origin, -1)
		var legacy_path := _build_chain_path(fixture, origin, VARIANT_LEGACY)
		var adaptive_path := _build_chain_path(fixture, origin, VARIANT_ADAPTIVE)
		var ring_path := _build_chain_path(
			fixture,
			origin,
			VARIANT_RING_PRUNED
		)
		if expected_path.size() != MAX_HITS:
			failures.append(
				"%s fixture did not provide a complete %d-hit path at origin %d: %s."
				% [fixture.label, MAX_HITS, origin_index, expected_path]
			)
			break
		if (
			legacy_path != expected_path
			or adaptive_path != expected_path
			or ring_path != expected_path
		):
			failures.append(
				"%s chain parity failed at origin %d: expected=%s legacy=%s adaptive=%s ring=%s."
				% [
					fixture.label,
					origin_index,
					expected_path,
					legacy_path,
					adaptive_path,
					ring_path,
				]
			)
			break

	var parity_ok := failures.size() == failure_count_before
	print(
		(
			"COMBAT_CHAIN_ENEMY_QUERY_PARITY scenario=%s total=%d local=%d far=%d "
			+ "origins=%d single_nearest=%s full_%d_hit_path=%s comparator=distance2_then_instance_id"
		)
		% [
			fixture.label,
			fixture.enemies.size(),
			fixture.local_enemy_count,
			fixture.far_enemy_count,
			caster_origins.size(),
			"OK" if parity_ok else "FAIL",
			MAX_HITS,
			"OK" if parity_ok else "FAIL",
		]
	)
	return parity_ok


func _build_chain_path(
	fixture: ScenarioFixture,
	origin: Vector2,
	variant: int
) -> PackedInt64Array:
	var result := PackedInt64Array()
	var excluded_instance_ids: Dictionary = {}
	var current_position := origin
	for hit_index in range(MAX_HITS):
		var radius := INITIAL_RADIUS if hit_index == 0 else BOUNCE_RADIUS
		var target: Enemy
		match variant:
			VARIANT_LEGACY:
				target = _legacy_find_nearest(
					fixture,
					current_position,
					radius,
					excluded_instance_ids
				)
			VARIANT_RING_PRUNED:
				target = _ring_pruned_find_nearest(
					fixture,
					current_position,
					radius,
					excluded_instance_ids
				)
			VARIANT_ADAPTIVE:
				target = fixture.target_index.call(
					"find_nearest_alive_excluding",
					current_position,
					radius,
					excluded_instance_ids
				) as Enemy
			VARIANT_DIRECT_LINEAR:
				target = _direct_registry_find_nearest(
					fixture,
					current_position,
					radius,
					excluded_instance_ids
				)
			VARIANT_FLAT_SHORT:
				target = _flat_short_find_nearest(
					fixture,
					current_position,
					radius,
					excluded_instance_ids
				)
			VARIANT_TWO_STAGE:
				target = _two_stage_find_nearest(
					fixture,
					current_position,
					radius,
					excluded_instance_ids
				)
			_:
				target = _oracle_find_nearest(
					fixture,
					current_position,
					radius,
					excluded_instance_ids
				)
		if target == null:
			break
		var instance_id := int(target.get_instance_id())
		excluded_instance_ids[instance_id] = true
		result.append(instance_id)
		current_position = target.global_position
	return result


func _legacy_find_nearest(
	fixture: ScenarioFixture,
	center: Vector2,
	radius: float,
	excluded_instance_ids: Dictionary
) -> Enemy:
	fixture.target_index.call(
		"query_radius_unordered_into",
		center,
		radius,
		legacy_scratch
	)
	legacy_candidate_visits += legacy_scratch.size()
	var nearest: Enemy = null
	var nearest_distance := INF
	var nearest_instance_id := 0
	for candidate in legacy_scratch:
		if (
			candidate == null
			or not is_instance_valid(candidate)
			or candidate.is_dead
			or candidate.is_queued_for_deletion()
		):
			continue
		var instance_id := int(candidate.get_instance_id())
		if excluded_instance_ids.has(instance_id):
			continue
		var distance := center.distance_squared_to(candidate.global_position)
		if _candidate_precedes(
			nearest,
			distance,
			instance_id,
			nearest_distance,
			nearest_instance_id
		):
			nearest = candidate
			nearest_distance = distance
			nearest_instance_id = instance_id
	return nearest


func _oracle_find_nearest(
	fixture: ScenarioFixture,
	center: Vector2,
	radius: float,
	excluded_instance_ids: Dictionary
) -> Enemy:
	var safe_radius := maxf(radius, 0.0)
	var radius_squared := safe_radius * safe_radius
	var nearest: Enemy = null
	var nearest_distance := INF
	var nearest_instance_id := 0
	for candidate in fixture.enemies:
		if (
			candidate == null
			or not is_instance_valid(candidate)
			or candidate.is_dead
			or candidate.is_queued_for_deletion()
		):
			continue
		var instance_id := int(candidate.get_instance_id())
		if excluded_instance_ids.has(instance_id):
			continue
		var distance := center.distance_squared_to(candidate.global_position)
		if safe_radius > 0.0 and distance > radius_squared:
			continue
		if _candidate_precedes(
			nearest,
			distance,
			instance_id,
			nearest_distance,
			nearest_instance_id
		):
			nearest = candidate
			nearest_distance = distance
			nearest_instance_id = instance_id
	return nearest


func _direct_registry_find_nearest(
	fixture: ScenarioFixture,
	center: Vector2,
	radius: float,
	excluded_instance_ids: Dictionary
) -> Enemy:
	var radius_squared := maxf(radius, 0.0) * maxf(radius, 0.0)
	var nearest: Enemy = null
	var nearest_distance := INF
	var nearest_instance_id := 0
	var registry := fixture.target_index.get("enemies_by_net_id") as Dictionary
	for net_id_variant in registry:
		var candidate_variant: Variant = registry.get(int(net_id_variant))
		if candidate_variant == null or not is_instance_valid(candidate_variant):
			continue
		var candidate := candidate_variant as Enemy
		if (
			candidate == null
			or candidate.is_dead
			or candidate.is_queued_for_deletion()
		):
			continue
		var instance_id := int(candidate.get_instance_id())
		if excluded_instance_ids.has(instance_id):
			continue
		var distance := center.distance_squared_to(candidate.global_position)
		if radius > 0.0 and distance > radius_squared:
			continue
		if _candidate_precedes(
			nearest,
			distance,
			instance_id,
			nearest_distance,
			nearest_instance_id
		):
			nearest = candidate
			nearest_distance = distance
			nearest_instance_id = instance_id
	return nearest


func _ring_pruned_find_nearest(
	fixture: ScenarioFixture,
	center: Vector2,
	radius: float,
	excluded_instance_ids: Dictionary
) -> Enemy:
	return fixture.target_index.call(
		"_find_nearest_alive_ring",
		center,
		radius,
		excluded_instance_ids
	) as Enemy


func _flat_short_find_nearest(
	fixture: ScenarioFixture,
	center: Vector2,
	radius: float,
	excluded_instance_ids: Dictionary
) -> Enemy:
	var bucket_size := float(fixture.target_index.get("bucket_size"))
	if radius > bucket_size:
		return _ring_pruned_find_nearest(
			fixture,
			center,
			radius,
			excluded_instance_ids
		)
	return _flat_bucket_find_nearest(
		fixture,
		center,
		radius,
		excluded_instance_ids
	)


func _flat_bucket_find_nearest(
	fixture: ScenarioFixture,
	center: Vector2,
	radius: float,
	excluded_instance_ids: Dictionary,
	known_minimum_bucket: Vector2i = Vector2i.MAX,
	known_maximum_bucket: Vector2i = Vector2i.MAX
) -> Enemy:
	var safe_radius := maxf(radius, 0.0)
	var radius_squared := safe_radius * safe_radius
	var bucket_size := maxf(float(fixture.target_index.get("bucket_size")), 1.0)
	var minimum_bucket := known_minimum_bucket
	var maximum_bucket := known_maximum_bucket
	if minimum_bucket == Vector2i.MAX or maximum_bucket == Vector2i.MAX:
		minimum_bucket = Vector2i(
			floori((center.x - safe_radius) / bucket_size),
			floori((center.y - safe_radius) / bucket_size)
		)
		maximum_bucket = Vector2i(
			floori((center.x + safe_radius) / bucket_size),
			floori((center.y + safe_radius) / bucket_size)
		)
	var buckets := fixture.target_index.get("buckets") as Dictionary
	var registry := fixture.target_index.get("enemies_by_net_id") as Dictionary
	var nearest: Enemy = null
	var nearest_distance := INF
	var nearest_instance_id := 0
	for bucket_y in range(minimum_bucket.y, maximum_bucket.y + 1):
		for bucket_x in range(minimum_bucket.x, maximum_bucket.x + 1):
			var bucket_cell := Vector2i(bucket_x, bucket_y)
			if not buckets.has(bucket_cell):
				continue
			var bucket := buckets[bucket_cell] as Array
			for net_id_variant in bucket:
				flat_membership_visits += 1
				var candidate_variant: Variant = registry.get(int(net_id_variant))
				if candidate_variant == null or not is_instance_valid(candidate_variant):
					continue
				var candidate := candidate_variant as Enemy
				if (
					candidate == null
					or candidate.is_dead
					or candidate.is_queued_for_deletion()
				):
					continue
				var instance_id := int(candidate.get_instance_id())
				if excluded_instance_ids.has(instance_id):
					continue
				var distance := center.distance_squared_to(candidate.global_position)
				if safe_radius > 0.0 and distance > radius_squared:
					continue
				if _candidate_precedes(
					nearest,
					distance,
					instance_id,
					nearest_distance,
					nearest_instance_id
				):
					nearest = candidate
					nearest_distance = distance
					nearest_instance_id = instance_id
	return nearest


func _two_stage_find_nearest(
	fixture: ScenarioFixture,
	center: Vector2,
	radius: float,
	excluded_instance_ids: Dictionary
) -> Enemy:
	var bucket_size := float(fixture.target_index.get("bucket_size"))
	var minimum_bucket := Vector2i(
		floori((center.x - radius) / bucket_size),
		floori((center.y - radius) / bucket_size)
	)
	var maximum_bucket := Vector2i(
		floori((center.x + radius) / bucket_size),
		floori((center.y + radius) / bucket_size)
	)
	var covered_bucket_cells := (
		(maximum_bucket.x - minimum_bucket.x + 1)
		* (maximum_bucket.y - minimum_bucket.y + 1)
	)
	if covered_bucket_cells > TWO_STAGE_MAX_BUCKET_CELLS:
		return _ring_pruned_find_nearest(
			fixture,
			center,
			radius,
			excluded_instance_ids
		)
	var local_membership_count := _count_local_bucket_memberships(
		fixture,
		minimum_bucket,
		maximum_bucket,
		CombatTargetIndex.NEAREST_LINEAR_TARGET_THRESHOLD
	)
	if local_membership_count <= CombatTargetIndex.NEAREST_LINEAR_TARGET_THRESHOLD:
		return _flat_bucket_find_nearest(
			fixture,
			center,
			radius,
			excluded_instance_ids,
			minimum_bucket,
			maximum_bucket
		)
	return _ring_pruned_find_nearest(
		fixture,
		center,
		radius,
		excluded_instance_ids
	)


func _count_local_bucket_memberships(
	fixture: ScenarioFixture,
	minimum_bucket: Vector2i,
	maximum_bucket: Vector2i,
	stop_after: int
) -> int:
	var buckets := fixture.target_index.get("buckets") as Dictionary
	var membership_count := 0
	for bucket_y in range(minimum_bucket.y, maximum_bucket.y + 1):
		for bucket_x in range(minimum_bucket.x, maximum_bucket.x + 1):
			var bucket_cell := Vector2i(bucket_x, bucket_y)
			if not buckets.has(bucket_cell):
				continue
			membership_count += (buckets[bucket_cell] as Array).size()
			if membership_count > stop_after:
				return membership_count
	return membership_count


func _candidate_precedes(
	current: Enemy,
	candidate_distance: float,
	candidate_instance_id: int,
	current_distance: float,
	current_instance_id: int
) -> bool:
	return (
		current == null
		or candidate_distance < current_distance
		or (
			candidate_distance == current_distance
			and candidate_instance_id < current_instance_id
		)
	)


func _measure_interleaved_ab(fixture: ScenarioFixture) -> Dictionary:
	for warmup_index in range(WARMUP_ROUNDS):
		var warmup_order := (
			[VARIANT_LEGACY, VARIANT_ADAPTIVE]
			if warmup_index % 2 == 0
			else [VARIANT_ADAPTIVE, VARIANT_LEGACY]
		)
		for variant in warmup_order:
			blackhole_checksum = _mix_checksum(
				blackhole_checksum,
				_run_chain_sweep(fixture, int(variant))
			)

	var legacy_samples: Array[float] = []
	var adaptive_samples: Array[float] = []
	var legacy_candidate_samples: Array[float] = []
	var sample_orders: Array[int] = []
	for sample_index in range(SAMPLE_COUNT):
		var legacy_first := sample_index % 2 == 0
		sample_orders.append(VARIANT_LEGACY if legacy_first else VARIANT_ADAPTIVE)
		var order := (
			[VARIANT_LEGACY, VARIANT_ADAPTIVE]
			if legacy_first
			else [VARIANT_ADAPTIVE, VARIANT_LEGACY]
		)
		var paired_checksums := [0, 0, 0, 0]
		for variant_variant in order:
			var variant := int(variant_variant)
			legacy_candidate_visits = 0
			var started_usec := Time.get_ticks_usec()
			var checksum := _run_chain_sweep(fixture, variant)
			var elapsed_ms := float(
				Time.get_ticks_usec() - started_usec
			) / 1000.0
			paired_checksums[variant] = checksum
			blackhole_checksum = _mix_checksum(blackhole_checksum, checksum)
			if variant == VARIANT_LEGACY:
				legacy_samples.append(elapsed_ms)
				legacy_candidate_samples.append(float(legacy_candidate_visits))
			else:
				adaptive_samples.append(elapsed_ms)
			if (
				last_sweep_hits != EXPECTED_QUERIES_PER_SWEEP
				or last_sweep_queries != EXPECTED_QUERIES_PER_SWEEP
			):
				failures.append(
					"%s sample %d variant %d expected %d hits/queries, observed %d/%d."
					% [
						fixture.label,
						sample_index,
						variant,
						EXPECTED_QUERIES_PER_SWEEP,
						last_sweep_hits,
						last_sweep_queries,
					]
				)
		if paired_checksums[VARIANT_LEGACY] != paired_checksums[VARIANT_ADAPTIVE]:
			failures.append(
				"%s paired checksum diverged at sample %d: legacy=%d adaptive=%d."
				% [
					fixture.label,
					sample_index,
					paired_checksums[VARIANT_LEGACY],
					paired_checksums[VARIANT_ADAPTIVE],
				]
			)

	return _build_benchmark_result(
		legacy_samples,
		adaptive_samples,
		legacy_candidate_samples,
		sample_orders
	)


func _run_direct_ring_crossover() -> void:
	for target_count_variant in CROSSOVER_TARGET_COUNTS:
		var target_count := int(target_count_variant)
		var fixture := _build_crossover_fixture(target_count)
		if _verify_direct_ring_crossover_parity(fixture):
			var benchmark := _measure_direct_ring_crossover(fixture)
			_print_direct_ring_crossover(target_count, benchmark)
		_cleanup_fixture(fixture)


func _run_flat_ring_experiment() -> void:
	for scenario_name in SCENARIO_NAMES:
		var fixture := _build_fixture(scenario_name)
		if _verify_flat_ring_parity(fixture):
			var benchmark := _measure_flat_ring(fixture)
			_print_flat_ring(fixture, benchmark)
		_cleanup_fixture(fixture)


func _run_two_stage_ring_experiment() -> void:
	for scenario_name in SCENARIO_NAMES:
		var fixture := _build_fixture(scenario_name)
		if _verify_two_stage_ring_parity(fixture):
			var benchmark := _measure_two_stage_ring(fixture)
			_print_two_stage_ring(fixture, benchmark)
		_cleanup_fixture(fixture)


func _run_three_stage_validation() -> void:
	var sparse_legacy_candidates := -1
	for scenario_name in SCENARIO_NAMES:
		var fixture := _build_fixture(scenario_name)
		if _verify_hard_parity(fixture):
			var benchmark := _measure_three_stage_validation(fixture)
			_print_three_stage_validation(fixture, benchmark)
			var candidate_summary := benchmark["legacy_candidates"] as Dictionary
			var candidate_p50 := int(candidate_summary["p50"])
			if scenario_name == SCENARIO_SPARSE_5:
				sparse_legacy_candidates = candidate_p50
			elif (
				scenario_name == SCENARIO_FAR_1024
				and candidate_p50 != sparse_legacy_candidates
			):
				failures.append(
					"three-stage far1024 changed local legacy candidates: sparse=%d far=%d."
					% [sparse_legacy_candidates, candidate_p50]
				)
		_cleanup_fixture(fixture)


func _measure_three_stage_validation(fixture: ScenarioFixture) -> Dictionary:
	for warmup_index in range(THREE_WAY_WARMUP_ROUNDS):
		var order: Array = THREE_WAY_ORDERS[warmup_index % THREE_WAY_ORDERS.size()]
		for variant_variant in order:
			blackhole_checksum = _mix_checksum(
				blackhole_checksum,
				_run_chain_sweep(fixture, int(variant_variant))
			)

	var samples_by_variant: Dictionary = {
		VARIANT_LEGACY: [],
		VARIANT_RING_PRUNED: [],
		VARIANT_ADAPTIVE: [],
	}
	var sample_orders: Array = []
	var legacy_candidate_samples: Array[float] = []
	for sample_index in range(THREE_WAY_SAMPLE_COUNT):
		var order: Array = THREE_WAY_ORDERS[sample_index % THREE_WAY_ORDERS.size()]
		sample_orders.append(order)
		var checksums: Dictionary = {}
		for variant_variant in order:
			var variant := int(variant_variant)
			legacy_candidate_visits = 0
			var started_usec := Time.get_ticks_usec()
			var checksum := _run_chain_sweep(fixture, variant)
			var elapsed_ms := float(Time.get_ticks_usec() - started_usec) / 1000.0
			(samples_by_variant[variant] as Array).append(elapsed_ms)
			checksums[variant] = checksum
			blackhole_checksum = _mix_checksum(blackhole_checksum, checksum)
			if variant == VARIANT_LEGACY:
				legacy_candidate_samples.append(float(legacy_candidate_visits))
			if (
				last_sweep_hits != EXPECTED_QUERIES_PER_SWEEP
				or last_sweep_queries != EXPECTED_QUERIES_PER_SWEEP
			):
				failures.append(
					"%s three-stage sample %d variant %d expected %d hits/queries, observed %d/%d."
					% [
						fixture.label,
						sample_index,
						variant,
						EXPECTED_QUERIES_PER_SWEEP,
						last_sweep_hits,
						last_sweep_queries,
					]
				)
		if (
			int(checksums[VARIANT_LEGACY]) != int(checksums[VARIANT_RING_PRUNED])
			or int(checksums[VARIANT_LEGACY]) != int(checksums[VARIANT_ADAPTIVE])
		):
			failures.append(
				"%s three-stage checksum diverged at sample %d: %s."
				% [fixture.label, sample_index, checksums]
			)

	return {
		"legacy": _summarize(samples_by_variant[VARIANT_LEGACY] as Array),
		"ring": _summarize(samples_by_variant[VARIANT_RING_PRUNED] as Array),
		"adaptive": _summarize(samples_by_variant[VARIANT_ADAPTIVE] as Array),
		"legacy_adaptive_pair": _build_three_way_pair(
			VARIANT_LEGACY,
			VARIANT_ADAPTIVE,
			samples_by_variant,
			sample_orders
		),
		"adaptive_ring_pair": _build_three_way_pair(
			VARIANT_ADAPTIVE,
			VARIANT_RING_PRUNED,
			samples_by_variant,
			sample_orders
		),
		"legacy_candidates": _summarize(legacy_candidate_samples),
	}


func _build_three_way_pair(
	lhs_variant: int,
	rhs_variant: int,
	samples_by_variant: Dictionary,
	sample_orders: Array
) -> Dictionary:
	var lhs_samples := samples_by_variant[lhs_variant] as Array
	var rhs_samples := samples_by_variant[rhs_variant] as Array
	var ratios: Array[float] = []
	var lhs_first_ratios: Array[float] = []
	var rhs_first_ratios: Array[float] = []
	var lhs_wins := 0
	var rhs_wins := 0
	for sample_index in range(THREE_WAY_SAMPLE_COUNT):
		var lhs_ms := maxf(float(lhs_samples[sample_index]), 0.000001)
		var rhs_ms := maxf(float(rhs_samples[sample_index]), 0.000001)
		var ratio := lhs_ms / rhs_ms
		ratios.append(ratio)
		if lhs_ms < rhs_ms:
			lhs_wins += 1
		elif rhs_ms < lhs_ms:
			rhs_wins += 1
		var order := sample_orders[sample_index] as Array
		if order.find(lhs_variant) < order.find(rhs_variant):
			lhs_first_ratios.append(ratio)
		else:
			rhs_first_ratios.append(ratio)
	return {
		"ratio": _summarize(ratios),
		"lhs_win_rate": float(lhs_wins) / float(THREE_WAY_SAMPLE_COUNT),
		"rhs_win_rate": float(rhs_wins) / float(THREE_WAY_SAMPLE_COUNT),
		"lhs_first_ratio": _summarize(lhs_first_ratios),
		"rhs_first_ratio": _summarize(rhs_first_ratios),
	}


func _print_three_stage_validation(
	fixture: ScenarioFixture,
	benchmark: Dictionary
) -> void:
	var legacy := benchmark["legacy"] as Dictionary
	var ring := benchmark["ring"] as Dictionary
	var adaptive := benchmark["adaptive"] as Dictionary
	var legacy_adaptive := benchmark["legacy_adaptive_pair"] as Dictionary
	var adaptive_ring := benchmark["adaptive_ring_pair"] as Dictionary
	var legacy_adaptive_ratio := legacy_adaptive["ratio"] as Dictionary
	var adaptive_ring_ratio := adaptive_ring["ratio"] as Dictionary
	var legacy_candidates := benchmark["legacy_candidates"] as Dictionary
	print(
		(
			"COMBAT_CHAIN_ENEMY_QUERY_THREE_STAGE scenario=%s total=%d local=%d far=%d "
			+ "samples=%d warmup=%d legacy_p50=%.3f legacy_p95=%.3f "
			+ "ring_p50=%.3f ring_p95=%.3f adaptive_p50=%.3f adaptive_p95=%.3f "
			+ "legacy_over_adaptive_p50=%.3f p95=%.3f adaptive_win_vs_legacy=%.3f "
			+ "adaptive_over_ring_p50=%.3f p95=%.3f adaptive_win_vs_ring=%.3f "
			+ "legacy_first_ratio_p50=%.3f adaptive_first_vs_legacy_ratio_p50=%.3f "
			+ "adaptive_first_vs_ring_ratio_p50=%.3f ring_first_ratio_p50=%.3f "
			+ "legacy_candidate_visits_p50=%.0f"
		)
		% [
			fixture.label,
			fixture.enemies.size(),
			fixture.local_enemy_count,
			fixture.far_enemy_count,
			THREE_WAY_SAMPLE_COUNT,
			THREE_WAY_WARMUP_ROUNDS,
			float(legacy["p50"]),
			float(legacy["p95"]),
			float(ring["p50"]),
			float(ring["p95"]),
			float(adaptive["p50"]),
			float(adaptive["p95"]),
			float(legacy_adaptive_ratio["p50"]),
			float(legacy_adaptive_ratio["p95"]),
			float(legacy_adaptive["rhs_win_rate"]),
			float(adaptive_ring_ratio["p50"]),
			float(adaptive_ring_ratio["p95"]),
			float(adaptive_ring["lhs_win_rate"]),
			float((legacy_adaptive["lhs_first_ratio"] as Dictionary)["p50"]),
			float((legacy_adaptive["rhs_first_ratio"] as Dictionary)["p50"]),
			float((adaptive_ring["lhs_first_ratio"] as Dictionary)["p50"]),
			float((adaptive_ring["rhs_first_ratio"] as Dictionary)["p50"]),
			float(legacy_candidates["p50"]),
		]
	)


func _verify_two_stage_ring_parity(fixture: ScenarioFixture) -> bool:
	var failure_count_before := failures.size()
	for origin_index in range(caster_origins.size()):
		var origin := caster_origins[origin_index]
		var expected := _build_chain_path(fixture, origin, -1)
		var two_stage := _build_chain_path(fixture, origin, VARIANT_TWO_STAGE)
		var ring := _build_chain_path(fixture, origin, VARIANT_RING_PRUNED)
		if expected.size() != MAX_HITS or two_stage != expected or ring != expected:
			failures.append(
				"%s two-stage/ring parity failed at origin %d: expected=%s two_stage=%s ring=%s."
				% [fixture.label, origin_index, expected, two_stage, ring]
			)
			break
	return failures.size() == failure_count_before


func _measure_two_stage_ring(fixture: ScenarioFixture) -> Dictionary:
	for warmup_index in range(FLAT_EXPERIMENT_WARMUP_ROUNDS):
		var order := (
			[VARIANT_TWO_STAGE, VARIANT_RING_PRUNED]
			if warmup_index % 2 == 0
			else [VARIANT_RING_PRUNED, VARIANT_TWO_STAGE]
		)
		for variant in order:
			blackhole_checksum = _mix_checksum(
				blackhole_checksum,
				_run_chain_sweep(fixture, int(variant))
			)

	var two_stage_samples: Array[float] = []
	var ring_samples: Array[float] = []
	var ratio_samples: Array[float] = []
	var two_stage_first_ratios: Array[float] = []
	var ring_first_ratios: Array[float] = []
	var two_stage_wins := 0
	for sample_index in range(FLAT_EXPERIMENT_SAMPLE_COUNT):
		var two_stage_first := sample_index % 2 == 0
		var order := (
			[VARIANT_TWO_STAGE, VARIANT_RING_PRUNED]
			if two_stage_first
			else [VARIANT_RING_PRUNED, VARIANT_TWO_STAGE]
		)
		var elapsed_by_variant := [0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
		var checksum_by_variant := [0, 0, 0, 0, 0, 0]
		for variant_variant in order:
			var variant := int(variant_variant)
			var started_usec := Time.get_ticks_usec()
			var checksum := _run_chain_sweep(fixture, variant)
			var elapsed_ms := float(Time.get_ticks_usec() - started_usec) / 1000.0
			elapsed_by_variant[variant] = elapsed_ms
			checksum_by_variant[variant] = checksum
			blackhole_checksum = _mix_checksum(blackhole_checksum, checksum)
		if checksum_by_variant[VARIANT_TWO_STAGE] != checksum_by_variant[VARIANT_RING_PRUNED]:
			failures.append(
				"%s two-stage/ring checksum diverged at sample %d."
				% [fixture.label, sample_index]
			)
		var two_stage_ms := maxf(
			float(elapsed_by_variant[VARIANT_TWO_STAGE]),
			0.000001
		)
		var ring_ms := maxf(float(elapsed_by_variant[VARIANT_RING_PRUNED]), 0.000001)
		two_stage_samples.append(two_stage_ms)
		ring_samples.append(ring_ms)
		var ratio := two_stage_ms / ring_ms
		ratio_samples.append(ratio)
		if two_stage_ms < ring_ms:
			two_stage_wins += 1
		if two_stage_first:
			two_stage_first_ratios.append(ratio)
		else:
			ring_first_ratios.append(ratio)
	return {
		"two_stage": _summarize(two_stage_samples),
		"ring": _summarize(ring_samples),
		"ratio": _summarize(ratio_samples),
		"two_stage_win_rate": (
			float(two_stage_wins) / float(FLAT_EXPERIMENT_SAMPLE_COUNT)
		),
		"two_stage_first_ratio": _summarize(two_stage_first_ratios),
		"ring_first_ratio": _summarize(ring_first_ratios),
	}


func _print_two_stage_ring(fixture: ScenarioFixture, benchmark: Dictionary) -> void:
	var two_stage := benchmark["two_stage"] as Dictionary
	var ring := benchmark["ring"] as Dictionary
	var ratio := benchmark["ratio"] as Dictionary
	var two_stage_first := benchmark["two_stage_first_ratio"] as Dictionary
	var ring_first := benchmark["ring_first_ratio"] as Dictionary
	print(
		(
			"COMBAT_CHAIN_ENEMY_QUERY_TWO_STAGE scenario=%s total=%d local=%d far=%d "
			+ "samples=%d warmup=%d two_stage_ms_p50=%.3f two_stage_ms_p95=%.3f "
			+ "ring_ms_p50=%.3f ring_ms_p95=%.3f paired_two_stage_over_ring_p50=%.3f "
			+ "paired_p95=%.3f two_stage_win_rate=%.3f two_stage_first_ratio_p50=%.3f "
			+ "ring_first_ratio_p50=%.3f"
		)
		% [
			fixture.label,
			fixture.enemies.size(),
			fixture.local_enemy_count,
			fixture.far_enemy_count,
			FLAT_EXPERIMENT_SAMPLE_COUNT,
			FLAT_EXPERIMENT_WARMUP_ROUNDS,
			float(two_stage["p50"]),
			float(two_stage["p95"]),
			float(ring["p50"]),
			float(ring["p95"]),
			float(ratio["p50"]),
			float(ratio["p95"]),
			float(benchmark["two_stage_win_rate"]),
			float(two_stage_first["p50"]),
			float(ring_first["p50"]),
		]
	)


func _verify_flat_ring_parity(fixture: ScenarioFixture) -> bool:
	var failure_count_before := failures.size()
	for origin_index in range(caster_origins.size()):
		var origin := caster_origins[origin_index]
		var expected := _build_chain_path(fixture, origin, -1)
		var flat := _build_chain_path(fixture, origin, VARIANT_FLAT_SHORT)
		var ring := _build_chain_path(fixture, origin, VARIANT_RING_PRUNED)
		if expected.size() != MAX_HITS or flat != expected or ring != expected:
			failures.append(
				"%s flat/ring parity failed at origin %d: expected=%s flat=%s ring=%s."
				% [fixture.label, origin_index, expected, flat, ring]
			)
			break
	return failures.size() == failure_count_before


func _measure_flat_ring(fixture: ScenarioFixture) -> Dictionary:
	for warmup_index in range(FLAT_EXPERIMENT_WARMUP_ROUNDS):
		var order := (
			[VARIANT_FLAT_SHORT, VARIANT_RING_PRUNED]
			if warmup_index % 2 == 0
			else [VARIANT_RING_PRUNED, VARIANT_FLAT_SHORT]
		)
		for variant in order:
			blackhole_checksum = _mix_checksum(
				blackhole_checksum,
				_run_chain_sweep(fixture, int(variant))
			)

	var flat_samples: Array[float] = []
	var ring_samples: Array[float] = []
	var ratio_samples: Array[float] = []
	var flat_first_ratios: Array[float] = []
	var ring_first_ratios: Array[float] = []
	var flat_visit_samples: Array[float] = []
	var flat_wins := 0
	for sample_index in range(FLAT_EXPERIMENT_SAMPLE_COUNT):
		var flat_first := sample_index % 2 == 0
		var order := (
			[VARIANT_FLAT_SHORT, VARIANT_RING_PRUNED]
			if flat_first
			else [VARIANT_RING_PRUNED, VARIANT_FLAT_SHORT]
		)
		var elapsed_by_variant := [0.0, 0.0, 0.0, 0.0, 0.0]
		var checksum_by_variant := [0, 0, 0, 0, 0]
		for variant_variant in order:
			var variant := int(variant_variant)
			flat_membership_visits = 0
			var started_usec := Time.get_ticks_usec()
			var checksum := _run_chain_sweep(fixture, variant)
			var elapsed_ms := float(Time.get_ticks_usec() - started_usec) / 1000.0
			elapsed_by_variant[variant] = elapsed_ms
			checksum_by_variant[variant] = checksum
			blackhole_checksum = _mix_checksum(blackhole_checksum, checksum)
			if variant == VARIANT_FLAT_SHORT:
				flat_visit_samples.append(float(flat_membership_visits))
		if checksum_by_variant[VARIANT_FLAT_SHORT] != checksum_by_variant[VARIANT_RING_PRUNED]:
			failures.append(
				"%s flat/ring checksum diverged at sample %d."
				% [fixture.label, sample_index]
			)
		var flat_ms := maxf(float(elapsed_by_variant[VARIANT_FLAT_SHORT]), 0.000001)
		var ring_ms := maxf(float(elapsed_by_variant[VARIANT_RING_PRUNED]), 0.000001)
		flat_samples.append(flat_ms)
		ring_samples.append(ring_ms)
		var ratio := flat_ms / ring_ms
		ratio_samples.append(ratio)
		if flat_ms < ring_ms:
			flat_wins += 1
		if flat_first:
			flat_first_ratios.append(ratio)
		else:
			ring_first_ratios.append(ratio)
	return {
		"flat": _summarize(flat_samples),
		"ring": _summarize(ring_samples),
		"ratio": _summarize(ratio_samples),
		"flat_win_rate": float(flat_wins) / float(FLAT_EXPERIMENT_SAMPLE_COUNT),
		"flat_first_ratio": _summarize(flat_first_ratios),
		"ring_first_ratio": _summarize(ring_first_ratios),
		"flat_membership_visits": _summarize(flat_visit_samples),
	}


func _print_flat_ring(fixture: ScenarioFixture, benchmark: Dictionary) -> void:
	var flat := benchmark["flat"] as Dictionary
	var ring := benchmark["ring"] as Dictionary
	var ratio := benchmark["ratio"] as Dictionary
	var flat_first := benchmark["flat_first_ratio"] as Dictionary
	var ring_first := benchmark["ring_first_ratio"] as Dictionary
	var visits := benchmark["flat_membership_visits"] as Dictionary
	print(
		(
			"COMBAT_CHAIN_ENEMY_QUERY_FLAT scenario=%s total=%d local=%d far=%d "
			+ "samples=%d warmup=%d flat_ms_p50=%.3f flat_ms_p95=%.3f "
			+ "ring_ms_p50=%.3f ring_ms_p95=%.3f paired_flat_over_ring_p50=%.3f "
			+ "paired_p95=%.3f flat_win_rate=%.3f flat_first_ratio_p50=%.3f "
			+ "ring_first_ratio_p50=%.3f flat_membership_visits_p50=%.0f"
		)
		% [
			fixture.label,
			fixture.enemies.size(),
			fixture.local_enemy_count,
			fixture.far_enemy_count,
			FLAT_EXPERIMENT_SAMPLE_COUNT,
			FLAT_EXPERIMENT_WARMUP_ROUNDS,
			float(flat["p50"]),
			float(flat["p95"]),
			float(ring["p50"]),
			float(ring["p95"]),
			float(ratio["p50"]),
			float(ratio["p95"]),
			float(benchmark["flat_win_rate"]),
			float(flat_first["p50"]),
			float(ring_first["p50"]),
			float(visits["p50"]),
		]
	)


func _verify_direct_ring_crossover_parity(fixture: ScenarioFixture) -> bool:
	var failure_count_before := failures.size()
	for origin_index in range(caster_origins.size()):
		var origin := caster_origins[origin_index]
		var expected := _build_chain_path(fixture, origin, -1)
		var direct := _build_chain_path(fixture, origin, VARIANT_DIRECT_LINEAR)
		var ring := _build_chain_path(fixture, origin, VARIANT_RING_PRUNED)
		if expected.size() != MAX_HITS or direct != expected or ring != expected:
			failures.append(
				"%s direct/ring crossover parity failed at origin %d: expected=%s direct=%s ring=%s."
				% [fixture.label, origin_index, expected, direct, ring]
			)
			break
	return failures.size() == failure_count_before


func _measure_direct_ring_crossover(fixture: ScenarioFixture) -> Dictionary:
	for warmup_index in range(CROSSOVER_WARMUP_ROUNDS):
		var order := (
			[VARIANT_DIRECT_LINEAR, VARIANT_RING_PRUNED]
			if warmup_index % 2 == 0
			else [VARIANT_RING_PRUNED, VARIANT_DIRECT_LINEAR]
		)
		for variant in order:
			blackhole_checksum = _mix_checksum(
				blackhole_checksum,
				_run_chain_sweep(fixture, int(variant))
			)

	var direct_samples: Array[float] = []
	var ring_samples: Array[float] = []
	var direct_first_ratios: Array[float] = []
	var ring_first_ratios: Array[float] = []
	var ratios: Array[float] = []
	var ring_wins := 0
	for sample_index in range(CROSSOVER_SAMPLE_COUNT):
		var direct_first := sample_index % 2 == 0
		var order := (
			[VARIANT_DIRECT_LINEAR, VARIANT_RING_PRUNED]
			if direct_first
			else [VARIANT_RING_PRUNED, VARIANT_DIRECT_LINEAR]
		)
		var elapsed_by_variant := [0.0, 0.0, 0.0]
		var checksum_by_variant := [0, 0, 0]
		for variant_variant in order:
			var variant := int(variant_variant)
			var started_usec := Time.get_ticks_usec()
			var checksum := _run_chain_sweep(fixture, variant)
			var elapsed_ms := float(Time.get_ticks_usec() - started_usec) / 1000.0
			elapsed_by_variant[variant] = elapsed_ms
			checksum_by_variant[variant] = checksum
			blackhole_checksum = _mix_checksum(blackhole_checksum, checksum)
		if (
			checksum_by_variant[VARIANT_DIRECT_LINEAR]
			!= checksum_by_variant[VARIANT_RING_PRUNED]
		):
			failures.append(
				"%s crossover checksum diverged at sample %d."
				% [fixture.label, sample_index]
			)
		var direct_ms := maxf(
			float(elapsed_by_variant[VARIANT_DIRECT_LINEAR]),
			0.000001
		)
		var ring_ms := maxf(
			float(elapsed_by_variant[VARIANT_RING_PRUNED]),
			0.000001
		)
		direct_samples.append(direct_ms)
		ring_samples.append(ring_ms)
		var ratio := direct_ms / ring_ms
		ratios.append(ratio)
		if ring_ms < direct_ms:
			ring_wins += 1
		if direct_first:
			direct_first_ratios.append(ratio)
		else:
			ring_first_ratios.append(ratio)
	return {
		"direct": _summarize(direct_samples),
		"ring": _summarize(ring_samples),
		"ratio": _summarize(ratios),
		"ring_win_rate": float(ring_wins) / float(CROSSOVER_SAMPLE_COUNT),
		"direct_first_ratio": _summarize(direct_first_ratios),
		"ring_first_ratio": _summarize(ring_first_ratios),
	}


func _print_direct_ring_crossover(target_count: int, benchmark: Dictionary) -> void:
	var direct := benchmark["direct"] as Dictionary
	var ring := benchmark["ring"] as Dictionary
	var ratio := benchmark["ratio"] as Dictionary
	var direct_first := benchmark["direct_first_ratio"] as Dictionary
	var ring_first := benchmark["ring_first_ratio"] as Dictionary
	print(
		(
			"COMBAT_CHAIN_ENEMY_QUERY_CROSSOVER targets=%d samples=%d warmup=%d "
			+ "direct_ms_p50=%.3f direct_ms_p95=%.3f ring_ms_p50=%.3f ring_ms_p95=%.3f "
			+ "paired_direct_over_ring_p50=%.3f paired_p95=%.3f ring_win_rate=%.3f "
			+ "direct_first_ratio_p50=%.3f ring_first_ratio_p50=%.3f"
		)
		% [
			target_count,
			CROSSOVER_SAMPLE_COUNT,
			CROSSOVER_WARMUP_ROUNDS,
			float(direct["p50"]),
			float(direct["p95"]),
			float(ring["p50"]),
			float(ring["p95"]),
			float(ratio["p50"]),
			float(ratio["p95"]),
			float(benchmark["ring_win_rate"]),
			float(direct_first["p50"]),
			float(ring_first["p50"]),
		]
	)


func _run_chain_sweep(fixture: ScenarioFixture, variant: int) -> int:
	var checksum := 0
	var hit_count := 0
	var query_count := 0
	for origin in caster_origins:
		var excluded_instance_ids: Dictionary = {}
		var current_position := origin
		for hit_index in range(MAX_HITS):
			var radius := INITIAL_RADIUS if hit_index == 0 else BOUNCE_RADIUS
			var target: Enemy
			if variant == VARIANT_LEGACY:
				target = _legacy_find_nearest(
					fixture,
					current_position,
					radius,
					excluded_instance_ids
				)
			elif variant == VARIANT_RING_PRUNED:
				target = _ring_pruned_find_nearest(
					fixture,
					current_position,
					radius,
					excluded_instance_ids
				)
			elif variant == VARIANT_DIRECT_LINEAR:
				target = _direct_registry_find_nearest(
					fixture,
					current_position,
					radius,
					excluded_instance_ids
				)
			elif variant == VARIANT_FLAT_SHORT:
				target = _flat_short_find_nearest(
					fixture,
					current_position,
					radius,
					excluded_instance_ids
				)
			elif variant == VARIANT_TWO_STAGE:
				target = _two_stage_find_nearest(
					fixture,
					current_position,
					radius,
					excluded_instance_ids
				)
			else:
				target = fixture.target_index.call(
					"find_nearest_alive_excluding",
					current_position,
					radius,
					excluded_instance_ids
				) as Enemy
			query_count += 1
			if target == null:
				break
			var instance_id := int(target.get_instance_id())
			excluded_instance_ids[instance_id] = true
			checksum = _mix_checksum(checksum, instance_id + hit_index)
			current_position = target.global_position
			hit_count += 1
	last_sweep_hits = hit_count
	last_sweep_queries = query_count
	return checksum


func _build_benchmark_result(
	legacy_samples: Array[float],
	adaptive_samples: Array[float],
	legacy_candidate_samples: Array[float],
	sample_orders: Array[int]
) -> Dictionary:
	var ratios: Array[float] = []
	var legacy_first_ratios: Array[float] = []
	var adaptive_first_ratios: Array[float] = []
	var adaptive_wins := 0
	for sample_index in range(SAMPLE_COUNT):
		var legacy_ms := maxf(legacy_samples[sample_index], 0.000001)
		var adaptive_ms := maxf(adaptive_samples[sample_index], 0.000001)
		var ratio := legacy_ms / adaptive_ms
		ratios.append(ratio)
		if adaptive_ms < legacy_ms:
			adaptive_wins += 1
		if sample_orders[sample_index] == VARIANT_LEGACY:
			legacy_first_ratios.append(ratio)
		else:
			adaptive_first_ratios.append(ratio)
	return {
		"legacy": _summarize(legacy_samples),
		"adaptive": _summarize(adaptive_samples),
		"ratio": _summarize(ratios),
		"adaptive_win_rate": float(adaptive_wins) / float(SAMPLE_COUNT),
		"legacy_first_ratio": _summarize(legacy_first_ratios),
		"adaptive_first_ratio": _summarize(adaptive_first_ratios),
		"legacy_first_count": legacy_first_ratios.size(),
		"adaptive_first_count": adaptive_first_ratios.size(),
		"legacy_candidates": _summarize(legacy_candidate_samples),
	}


func _print_benchmark(fixture: ScenarioFixture, benchmark: Dictionary) -> void:
	var legacy := benchmark["legacy"] as Dictionary
	var adaptive := benchmark["adaptive"] as Dictionary
	var ratio := benchmark["ratio"] as Dictionary
	var legacy_first := benchmark["legacy_first_ratio"] as Dictionary
	var adaptive_first := benchmark["adaptive_first_ratio"] as Dictionary
	var candidates := benchmark["legacy_candidates"] as Dictionary
	print(
		(
			"COMBAT_CHAIN_ENEMY_QUERY_AB scenario=%s total=%d local=%d far=%d "
			+ "samples=%d warmup=%d casters=%d max_hits=%d queries_per_sample=%d "
			+ "adaptive_mode=%s threshold=%d "
			+ "legacy_ms_p50=%.3f legacy_ms_p95=%.3f "
			+ "adaptive_ms_p50=%.3f adaptive_ms_p95=%.3f "
			+ "paired_legacy_over_adaptive_p50=%.3f paired_p95=%.3f adaptive_win_rate=%.3f "
			+ "order_legacy_first_n=%d ratio_p50=%.3f ratio_p95=%.3f "
			+ "order_adaptive_first_n=%d ratio_p50=%.3f ratio_p95=%.3f "
			+ "legacy_candidate_visits_min=%.0f p50=%.0f p95=%.0f max=%.0f per_query_p50=%.2f"
		)
		% [
			fixture.label,
			fixture.enemies.size(),
			fixture.local_enemy_count,
			fixture.far_enemy_count,
			SAMPLE_COUNT,
			WARMUP_ROUNDS,
			CASTER_COUNT,
			MAX_HITS,
			EXPECTED_QUERIES_PER_SWEEP,
			(
				"linear"
				if fixture.enemies.size()
					<= CombatTargetIndex.NEAREST_LINEAR_TARGET_THRESHOLD
				else "ring"
			),
			CombatTargetIndex.NEAREST_LINEAR_TARGET_THRESHOLD,
			float(legacy["p50"]),
			float(legacy["p95"]),
			float(adaptive["p50"]),
			float(adaptive["p95"]),
			float(ratio["p50"]),
			float(ratio["p95"]),
			float(benchmark["adaptive_win_rate"]),
			int(benchmark["legacy_first_count"]),
			float(legacy_first["p50"]),
			float(legacy_first["p95"]),
			int(benchmark["adaptive_first_count"]),
			float(adaptive_first["p50"]),
			float(adaptive_first["p95"]),
			float(candidates["min"]),
			float(candidates["p50"]),
			float(candidates["p95"]),
			float(candidates["max"]),
			float(candidates["p50"]) / float(EXPECTED_QUERIES_PER_SWEEP),
		]
	)


func _summarize(values: Array) -> Dictionary:
	if values.is_empty():
		return {"min": 0.0, "p50": 0.0, "p95": 0.0, "max": 0.0}
	var sorted := values.duplicate()
	sorted.sort()
	return {
		"min": float(sorted[0]),
		"p50": _nearest_rank(sorted, 0.50),
		"p95": _nearest_rank(sorted, 0.95),
		"max": float(sorted[sorted.size() - 1]),
	}


func _nearest_rank(sorted: Array, percentile: float) -> float:
	var index := clampi(
		ceili(clampf(percentile, 0.0, 1.0) * float(sorted.size())) - 1,
		0,
		sorted.size() - 1
	)
	return float(sorted[index])


func _instance_id_or_zero(enemy: Enemy) -> int:
	return int(enemy.get_instance_id()) if enemy != null else 0


func _mix_checksum(current: int, value: int) -> int:
	return int((current + (value % 1_000_003) * 33 + 17) % 2_147_483_647)


func _cleanup_fixture(fixture: ScenarioFixture) -> void:
	if fixture.target_index != null:
		fixture.target_index.call("clear")
		fixture.target_index = null
	for enemy in fixture.enemies:
		if enemy != null and is_instance_valid(enemy):
			enemy.free()
	fixture.enemies.clear()
