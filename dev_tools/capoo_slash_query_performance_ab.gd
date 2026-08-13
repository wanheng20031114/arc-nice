extends SceneTree

# Same-process A/B certificate for CapooKnight's slash-query allocation path.
# Both arms use the same production CapooKnight, PlantDefense bodies, collision
# shapes and Physics2D space. The optimized arm calls production
# `_apply_slash_damage()` directly. The legacy arm mirrors only the retired
# per-slash query/Dictionary allocation while preserving the former filtering
# and damage dispatch logic.

const KNIGHT_SCENE := preload("res://scene/enemy/capoo/capoo_knight.tscn")
const KNIGHT_CONFIG: CapooKnightConfig = preload(
	"res://resources/config/enemies/capoo_knight.tres"
)

const PLAYER_COLLISION_LAYER := 1 << 1
const PLANT_COLLISION_LAYER := 1 << 9
const SLASH_COLLISION_MASK := PLAYER_COLLISION_LAYER | PLANT_COLLISION_LAYER
const PRODUCTION_MAX_RESULTS := 16
const QUERY_CENTER := Vector2(256.0, 192.0)
const QUERY_DIRECTION := Vector2.RIGHT
const SLASH_ANGLE_EPSILON_RADIANS := 0.000001

# Targets 1-8 are strictly inside the authored 48 px / 60 degree slash. Each
# owns two shapes, so the production max_results=16 query returns exactly 16
# shape hits that deduplicate to eight damage dispatches. Targets 9-16 are well
# outside the query circle and prove the fixed fixture does not leak hits.
const TARGET_OFFSETS := [
	Vector2(12.0, 0.0),
	Vector2(18.0, -5.0),
	Vector2(18.0, 5.0),
	Vector2(28.0, -10.0),
	Vector2(28.0, 10.0),
	Vector2(38.0, 0.0),
	Vector2(42.0, -15.0),
	Vector2(42.0, 15.0),
	Vector2(96.0, 0.0),
	Vector2(96.0, 24.0),
	Vector2(96.0, -24.0),
	Vector2(0.0, 96.0),
	Vector2(0.0, -96.0),
	Vector2(-96.0, 0.0),
	Vector2(-96.0, 24.0),
	Vector2(-96.0, -24.0),
]
const EXPECTED_HITS_PER_QUERY := 8

const WARMUP_PAIRS := 4
const WARMUP_QUERIES_PER_ARM := 512
# Thirty paired samples retain 15 AB and 15 BA orders while giving median and
# paired-p90 gates enough observations to ignore isolated scheduler noise.
const SAMPLE_PAIRS := 30
const QUERIES_PER_SAMPLE := 3072
const CHECKSUM_MODULUS := 2_147_483_647
# The complete production damage path still measured 3.9%-4.8% faster over
# repeated runs. Require a modest 1% paired-median gain, while allowing the
# noisiest decile a 2% scheduling excursion and requiring 80% pair wins.
const MAX_PAIRED_MEDIAN_RATIO := 0.99
const MAX_PAIRED_P90_RATIO := 1.02
const MIN_OPTIMIZED_WIN_PAIRS := 24
const CLEANUP_FRAMES := 4


class ObservablePlant:
	extends PlantDefense

	var fixture_id := 0
	var expected_source: Node = null
	var expected_damage := 0
	var expected_direction := Vector2.ZERO
	var observed_hit_count := 0
	var observed_damage_sum := 0
	var contract_mismatch_count := 0


	func reset_observation() -> void:
		observed_hit_count = 0
		observed_damage_sum = 0
		contract_mismatch_count = 0


	func receive_damage(
		amount: int,
		source: Node = null,
		impact_direction: Vector2 = Vector2.ZERO,
		damage_type: EnemyConfig.DamageType = EnemyConfig.DamageType.PHYSICAL
	) -> bool:
		observed_hit_count += 1
		observed_damage_sum += amount
		if (
			source != expected_source
			or amount != expected_damage
			or damage_type != EnemyConfig.DamageType.PHYSICAL
			or not impact_direction.is_equal_approx(expected_direction)
		):
			contract_mismatch_count += 1
		return true


var failures: Array[String] = []
var fixture: Node2D = null
var enemy: CapooKnight = null
var targets: Array[ObservablePlant] = []
var space_state: PhysicsDirectSpaceState2D = null


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	await _build_fixture()
	if not failures.is_empty():
		await _finish({})
		return

	var physics_oracle := _query_physics_oracle()
	_expect(
		int(physics_oracle.get("raw_result_count", -1)) == PRODUCTION_MAX_RESULTS,
		"The fixed production query must return exactly 16 shape results."
	)
	_expect(
		int(physics_oracle.get("unique_target_count", -1))
			== EXPECTED_HITS_PER_QUERY,
		"The 16 production shape results must deduplicate to eight targets."
	)
	_expect(
		int(physics_oracle.get("checksum", -1)) == _expected_query_checksum(),
		"The fixed Physics2D query returned the wrong target set."
	)

	var production_query_id := enemy.slash_query.get_instance_id()
	var production_shape_id := enemy.slash_query_shape.get_instance_id()
	var oracle_legacy := _run_legacy_batch(1)
	var oracle_optimized := _run_optimized_batch(1)
	_validate_behavior_pair(oracle_legacy, oracle_optimized, "oracle")
	var oracle_behavior := oracle_legacy["behavior"] as Dictionary
	_expect(
		oracle_behavior == _expected_behavior(1),
		"Both slash arms must dispatch the exact authored damage contract once."
	)
	_expect(
		enemy.slash_query.get_instance_id() == production_query_id
		and enemy.slash_query_shape.get_instance_id() == production_shape_id,
		"Production must retain the same slash query and shape instances."
	)

	for warmup_index in range(WARMUP_PAIRS):
		var warmup_legacy: Dictionary
		var warmup_optimized: Dictionary
		if warmup_index % 2 == 0:
			warmup_legacy = _run_legacy_batch(WARMUP_QUERIES_PER_ARM)
			warmup_optimized = _run_optimized_batch(WARMUP_QUERIES_PER_ARM)
		else:
			warmup_optimized = _run_optimized_batch(WARMUP_QUERIES_PER_ARM)
			warmup_legacy = _run_legacy_batch(WARMUP_QUERIES_PER_ARM)
		_validate_behavior_pair(
			warmup_legacy,
			warmup_optimized,
			"warmup_%d" % (warmup_index + 1)
		)

	var legacy_samples: Array[float] = []
	var optimized_samples: Array[float] = []
	var paired_ratios: Array[float] = []
	var optimized_wins := 0
	var reference_behavior: Dictionary = {}
	var ab_pairs := 0
	var ba_pairs := 0
	for pair_index in range(SAMPLE_PAIRS):
		var legacy_result: Dictionary
		var optimized_result: Dictionary
		if pair_index % 2 == 0:
			ab_pairs += 1
			legacy_result = _run_legacy_batch(QUERIES_PER_SAMPLE)
			optimized_result = _run_optimized_batch(QUERIES_PER_SAMPLE)
		else:
			ba_pairs += 1
			optimized_result = _run_optimized_batch(QUERIES_PER_SAMPLE)
			legacy_result = _run_legacy_batch(QUERIES_PER_SAMPLE)
		_validate_behavior_pair(
			legacy_result,
			optimized_result,
			"sample_%d" % (pair_index + 1)
		)
		var legacy_behavior := legacy_result["behavior"] as Dictionary
		if reference_behavior.is_empty():
			reference_behavior = legacy_behavior.duplicate(true)
		else:
			_expect(
				legacy_behavior == reference_behavior,
				"Slash-query behavior drifted between timed sample pairs."
			)
		var legacy_usec := float(legacy_result["elapsed_usec"])
		var optimized_usec := float(optimized_result["elapsed_usec"])
		legacy_samples.append(legacy_usec)
		optimized_samples.append(optimized_usec)
		paired_ratios.append(optimized_usec / maxf(legacy_usec, 1.0))
		if optimized_usec < legacy_usec:
			optimized_wins += 1

	_expect(
		reference_behavior == _expected_behavior(QUERIES_PER_SAMPLE),
		"Every timed production slash must preserve exact targets and damage."
	)
	_expect(
		ab_pairs >= 9 and ba_pairs >= 9,
		"The benchmark must retain at least nine samples of each AB/BA order."
	)

	var legacy_summary := _summarize(legacy_samples)
	var optimized_summary := _summarize(optimized_samples)
	var paired_summary := _summarize(paired_ratios)
	var paired_median_ratio := float(paired_summary["median"])
	var paired_p90_ratio := float(paired_summary["p90"])
	_expect(
		paired_median_ratio <= MAX_PAIRED_MEDIAN_RATIO,
		"Production slash reuse did not preserve a measurable paired median gain "
		+ "(ratio %.4f, limit %.2f)." % [
			paired_median_ratio,
			MAX_PAIRED_MEDIAN_RATIO,
		]
	)
	_expect(
		paired_p90_ratio <= MAX_PAIRED_P90_RATIO,
		"Production slash reuse has an unstable paired p90 "
		+ "(ratio %.4f, limit %.2f)." % [
			paired_p90_ratio,
			MAX_PAIRED_P90_RATIO,
		]
	)
	_expect(
		optimized_wins >= MIN_OPTIMIZED_WIN_PAIRS,
		"Production slash reuse must win at least 80%% of paired samples "
		+ "(%d/%d)." % [optimized_wins, SAMPLE_PAIRS]
	)
	_expect(
		enemy.slash_query.get_instance_id() == production_query_id
		and enemy.slash_query_shape.get_instance_id() == production_shape_id,
		"Timed production slashes replaced a retained query resource."
	)

	var result := {
		"schema_version": 2,
		"status": "ok" if failures.is_empty() else "failed",
		"production_binding": "CapooKnight._apply_slash_damage",
		"fixture": {
			"physics_target_count": targets.size(),
			"collision_shapes_per_target": 2,
			"collision_mask": SLASH_COLLISION_MASK,
			"max_results": PRODUCTION_MAX_RESULTS,
			"raw_results_per_query": int(
				physics_oracle.get("raw_result_count", 0)
			),
			"expected_hits_per_query": EXPECTED_HITS_PER_QUERY,
		},
		"sampling": {
			"warmup_pairs": WARMUP_PAIRS,
			"warmup_queries_per_arm": WARMUP_QUERIES_PER_ARM,
			"sample_pairs": SAMPLE_PAIRS,
			"ab_pairs": ab_pairs,
			"ba_pairs": ba_pairs,
			"queries_per_sample": QUERIES_PER_SAMPLE,
		},
		"behavior": reference_behavior,
		"legacy": legacy_summary,
		"optimized_production": optimized_summary,
		"paired_ratio": paired_summary,
		"paired_median_speedup": 1.0 / maxf(paired_median_ratio, 0.000001),
		"optimized_pair_wins": optimized_wins,
		"gates": {
			"maximum_paired_median_ratio": MAX_PAIRED_MEDIAN_RATIO,
			"maximum_paired_p90_ratio": MAX_PAIRED_P90_RATIO,
			"minimum_optimized_wins": MIN_OPTIMIZED_WIN_PAIRS,
		},
	}
	await _finish(result)


func _build_fixture() -> void:
	fixture = Node2D.new()
	fixture.name = "CapooSlashQueryPerformanceAB"
	root.add_child(fixture)
	current_scene = fixture

	enemy = KNIGHT_SCENE.instantiate() as CapooKnight
	_expect(enemy != null, "The fixture must instantiate production CapooKnight.")
	if enemy == null:
		return
	fixture.add_child(enemy)
	enemy.global_position = QUERY_CENTER
	enemy.setup(KNIGHT_CONFIG, null, null, null)
	enemy.slash_direction = QUERY_DIRECTION
	enemy.action_sequence = 1
	enemy.set_physics_process(false)
	enemy.set_process(false)
	enemy.touch_damage_area.monitoring = false
	enemy.touch_damage_area.monitorable = false

	var target_shape := CircleShape2D.new()
	target_shape.radius = 2.0
	var expected_damage := enemy.get_effective_attack_damage(
		KNIGHT_CONFIG.attack_damage
	)
	for target_index in range(TARGET_OFFSETS.size()):
		var target := ObservablePlant.new()
		target.name = "SlashTarget%02d" % (target_index + 1)
		target.fixture_id = target_index + 1
		target.expected_source = enemy
		target.expected_damage = expected_damage
		target.expected_direction = TARGET_OFFSETS[target_index].normalized()
		target.global_position = QUERY_CENTER + TARGET_OFFSETS[target_index]
		target.collision_layer = PLANT_COLLISION_LAYER
		target.collision_mask = 0
		target.input_pickable = false
		target.max_health = 1_000_000
		target.current_health = target.max_health
		fixture.add_child(target)
		for shape_index in range(2):
			var collision_shape := CollisionShape2D.new()
			collision_shape.name = "CollisionShape2D%d" % (shape_index + 1)
			collision_shape.position = Vector2(
				-1.0 if shape_index == 0 else 1.0,
				0.0
			)
			collision_shape.shape = target_shape
			target.add_child(collision_shape)
		targets.append(target)

	# Give PhysicsServer2D two synchronization opportunities before querying.
	await process_frame
	await physics_frame
	await physics_frame
	space_state = fixture.get_world_2d().direct_space_state
	_expect(space_state != null, "The slash A/B fixture requires a live Physics2D space.")
	_expect(
		enemy.slash_query.shape == enemy.slash_query_shape
		and enemy.slash_query.collision_mask == SLASH_COLLISION_MASK
		and is_equal_approx(
			enemy.slash_query_shape.radius,
			KNIGHT_CONFIG.slash_outer_radius
		),
		"Production CapooKnight must expose the authored reusable slash query."
	)


func _query_physics_oracle() -> Dictionary:
	var query := PhysicsShapeQueryParameters2D.new()
	_configure_legacy_query(query)
	var results := space_state.intersect_shape(query, PRODUCTION_MAX_RESULTS)
	var unique_ids: Dictionary[int, bool] = {}
	var checksum := 0
	for result in results:
		var target := result.get("collider") as ObservablePlant
		if target == null:
			continue
		var instance_id := target.get_instance_id()
		if unique_ids.has(instance_id):
			continue
		unique_ids[instance_id] = true
		checksum = posmod(
			checksum + _checksum_term(target.fixture_id),
			CHECKSUM_MODULUS
		)
	return {
		"raw_result_count": results.size(),
		"unique_target_count": unique_ids.size(),
		"checksum": checksum,
	}


func _run_legacy_batch(iterations: int) -> Dictionary:
	_reset_observations()
	var started_usec := Time.get_ticks_usec()
	for _query_index in range(iterations):
		_legacy_apply_slash_damage()
	var elapsed_usec := Time.get_ticks_usec() - started_usec
	return {
		"elapsed_usec": elapsed_usec,
		"behavior": _collect_behavior(),
	}


func _run_optimized_batch(iterations: int) -> Dictionary:
	_reset_observations()
	var started_usec := Time.get_ticks_usec()
	for _query_index in range(iterations):
		enemy._apply_slash_damage()
	var elapsed_usec := Time.get_ticks_usec() - started_usec
	return {
		"elapsed_usec": elapsed_usec,
		"behavior": _collect_behavior(),
	}


# Exact retired CapooKnight control flow: the query parameters and dedup
# Dictionary are allocated per slash, while filtering and dispatch use the same
# production enemy/config/targets as the optimized arm.
func _legacy_apply_slash_damage() -> void:
	if enemy.is_dead:
		return
	var query := PhysicsShapeQueryParameters2D.new()
	_configure_legacy_query(query)
	var results := space_state.intersect_shape(query, PRODUCTION_MAX_RESULTS)
	var half_angle := deg_to_rad(KNIGHT_CONFIG.slash_angle_degrees * 0.5)
	var outgoing_damage := enemy.get_effective_attack_damage(
		KNIGHT_CONFIG.attack_damage
	)
	var hit_targets: Dictionary = {}
	for result in results:
		var hit_target := result.get("collider") as Node2D
		if hit_target == null:
			continue
		var player := hit_target as Player
		var plant := hit_target as PlantDefense
		if (
			(player != null and player.is_dead)
			or (plant != null and (plant.is_dead or plant.is_removing))
			or (player == null and plant == null)
		):
			continue
		var target_id := hit_target.get_instance_id()
		if hit_targets.has(target_id):
			continue
		var offset := hit_target.global_position - enemy.global_position
		var distance := offset.length()
		if not bool(enemy._is_slash_target_in_radial_range(
			hit_target,
			distance,
			KNIGHT_CONFIG.slash_inner_radius,
			KNIGHT_CONFIG.slash_outer_radius
		)):
			continue
		if (
			offset == Vector2.ZERO
			or abs(enemy.slash_direction.angle_to(offset.normalized()))
				> half_angle + SLASH_ANGLE_EPSILON_RADIANS
		):
			continue
		hit_targets[target_id] = true
		if player != null:
			enemy._apply_multiplayer_player_damage(
				player,
				outgoing_damage,
				enemy._get_multiplayer_damage_source_id(enemy.action_sequence),
				enemy._get_slash_damage_source_type()
			)
		elif plant != null:
			plant.receive_damage(
				outgoing_damage,
				enemy,
				offset.normalized(),
				EnemyConfig.DamageType.PHYSICAL
			)


func _configure_legacy_query(query: PhysicsShapeQueryParameters2D) -> void:
	query.shape = enemy.slash_query_shape
	query.transform = Transform2D(0.0, enemy.global_position)
	query.collision_mask = SLASH_COLLISION_MASK
	query.collide_with_bodies = true
	query.collide_with_areas = false


func _reset_observations() -> void:
	enemy.slash_direction = QUERY_DIRECTION
	enemy.slash_hit_target_ids.clear()
	for target in targets:
		target.reset_observation()


func _collect_behavior() -> Dictionary:
	var hit_count := 0
	var damage_sum := 0
	var checksum := 0
	var contract_mismatches := 0
	var per_target_hits: Array[int] = []
	for target in targets:
		var target_hits := target.observed_hit_count
		per_target_hits.append(target_hits)
		hit_count += target_hits
		damage_sum += target.observed_damage_sum
		contract_mismatches += target.contract_mismatch_count
		checksum = posmod(
			checksum + _checksum_term(target.fixture_id) * target_hits,
			CHECKSUM_MODULUS
		)
	return {
		"hit_count": hit_count,
		"damage_sum": damage_sum,
		"checksum": checksum,
		"contract_mismatches": contract_mismatches,
		"per_target_hits": per_target_hits,
	}


func _expected_behavior(iterations: int) -> Dictionary:
	var per_target_hits: Array[int] = []
	for target_index in range(TARGET_OFFSETS.size()):
		per_target_hits.append(iterations if target_index < EXPECTED_HITS_PER_QUERY else 0)
	var expected_damage := enemy.get_effective_attack_damage(
		KNIGHT_CONFIG.attack_damage
	)
	return {
		"hit_count": EXPECTED_HITS_PER_QUERY * iterations,
		"damage_sum": EXPECTED_HITS_PER_QUERY * iterations * expected_damage,
		"checksum": posmod(
			_expected_query_checksum() * iterations,
			CHECKSUM_MODULUS
		),
		"contract_mismatches": 0,
		"per_target_hits": per_target_hits,
	}


func _expected_query_checksum() -> int:
	var checksum := 0
	for fixture_id in range(1, EXPECTED_HITS_PER_QUERY + 1):
		checksum = posmod(
			checksum + _checksum_term(fixture_id),
			CHECKSUM_MODULUS
		)
	return checksum


func _checksum_term(fixture_id: int) -> int:
	return fixture_id * fixture_id * 131 + fixture_id * 17


func _validate_behavior_pair(
	legacy_result: Dictionary,
	optimized_result: Dictionary,
	label: String
) -> void:
	_expect(
		legacy_result.get("behavior", {}) == optimized_result.get("behavior", {}),
		"Legacy and production slash behavior diverged at %s." % label
	)


func _summarize(samples: Array[float]) -> Dictionary:
	var sorted := samples.duplicate()
	sorted.sort()
	return {
		"sample_count": samples.size(),
		"samples": samples.duplicate(),
		"median": _median(sorted),
		"p90": _nearest_rank(sorted, 0.90),
		"p95": _nearest_rank(sorted, 0.95),
		"min": sorted.front() if not sorted.is_empty() else 0.0,
		"max": sorted.back() if not sorted.is_empty() else 0.0,
	}


func _median(samples: Array[float]) -> float:
	if samples.is_empty():
		return 0.0
	var sorted := samples.duplicate()
	sorted.sort()
	var middle := sorted.size() / 2
	if sorted.size() % 2 == 0:
		return (sorted[middle - 1] + sorted[middle]) * 0.5
	return sorted[middle]


func _nearest_rank(sorted: Array[float], percentile: float) -> float:
	if sorted.is_empty():
		return 0.0
	var rank := ceili(clampf(percentile, 0.0, 1.0) * sorted.size())
	return sorted[clampi(rank - 1, 0, sorted.size() - 1)]


func _finish(result: Dictionary) -> void:
	space_state = null
	current_scene = null
	if fixture != null:
		fixture.queue_free()
	for _cleanup_index in range(CLEANUP_FRAMES):
		await process_frame
		await physics_frame
	result["status"] = "ok" if failures.is_empty() else "failed"
	result["failures"] = failures.duplicate()
	print(
		"CAPOO_SLASH_QUERY_PERFORMANCE_AB_RESULT %s"
		% JSON.stringify(result)
	)
	if failures.is_empty():
		print("CAPOO_SLASH_QUERY_PERFORMANCE_AB_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
