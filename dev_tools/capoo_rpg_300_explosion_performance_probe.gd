extends SceneTree

const ROCKET_SCENE := preload(
	"res://scene/enemy/capoo/capoo_rpg_rocket.tscn"
)
const RUNTIME_SCENE := preload(
	"res://dev_tools/fixtures/enemy_gameplay_gateway_test_runtime.tscn"
)
const NIGHT_FLASH_POOL_SCENE := preload(
	"res://scene/lighting/night_vfx_flash_pool.tscn"
)

const ROCKET_COUNT := 300
const DENSE_TARGET_COUNT := 65
const QUERY_WARMUP_COUNT := 2
const QUERY_SAMPLE_COUNT := 7
const TEST_DAMAGE := 20
const EXPLOSION_RADIUS := 44.0
const TARGET_COLLISION_LAYER := 512
const EXPECTED_DAMAGE_CALLS := ROCKET_COUNT * DENSE_TARGET_COUNT

# These are synchronous headless CPU limits, not GPU budgets. They preserve
# enough CI headroom to detect accidental extra queries, unbounded effects, or
# a new per-explosion traversal without treating machine jitter as a failure.
const QUERY_P95_LIMIT_MS := 33.333
const PRESENTATION_SYNC_LIMIT_MS := 18.0
const PRESENTATION_FRAME_LIMIT_MS := 33.333
const FULL_SYNC_LIMIT_MS := 33.333
const FULL_FRAME_LIMIT_MS := 33.333


class ProbePlant:
	extends PlantDefense

	var hit_count := 0

	func receive_damage(
		_amount: int,
		_source: Node = null,
		_impact_direction: Vector2 = Vector2.ZERO,
		_damage_type: EnemyConfig.DamageType = EnemyConfig.DamageType.PHYSICAL
	) -> bool:
		hit_count += 1
		return true


var failures: Array[String] = []
var budget_violations: Array[String] = []
var runtime: EnemyGameplayGatewayTestRuntime = null
var flash_pool: NightVfxFlashPool = null
var targets: Array[ProbePlant] = []


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	_build_fixture()
	await process_frame
	await physics_frame
	_spawn_dense_targets()
	await process_frame
	await physics_frame

	var query_rockets := _spawn_rockets("QueryRocket")
	await process_frame
	await physics_frame
	var query_result := await _measure_query_phase(query_rockets)
	var presentation_result := await _measure_presentation_phase(query_rockets)
	_free_rockets(query_rockets)
	await process_frame
	await physics_frame

	var full_rockets := _spawn_rockets("FullRocket")
	await process_frame
	await physics_frame
	var full_result := await _measure_full_phase(full_rockets)

	_validate(query_result, presentation_result, full_result)
	_print_result(query_result, presentation_result, full_result)
	await _finish()


func _build_fixture() -> void:
	runtime = RUNTIME_SCENE.instantiate() as EnemyGameplayGatewayTestRuntime
	if runtime == null:
		_expect(false, "RPG performance runtime fixture must instantiate.")
		return
	runtime.name = "CapooRPG300ExplosionPerformanceProbe"
	root.add_child(runtime)
	current_scene = runtime
	var simulation_coordinator := runtime.get_node_or_null(
		"EnemySimulationCoordinator"
	)
	if simulation_coordinator != null:
		simulation_coordinator.process_mode = Node.PROCESS_MODE_DISABLED

	var camera := Camera2D.new()
	camera.name = "Camera2D"
	camera.enabled = true
	runtime.add_child(camera)
	camera.global_position = Vector2.ZERO
	flash_pool = NIGHT_FLASH_POOL_SCENE.instantiate() as NightVfxFlashPool
	flash_pool.name = "NightVfxFlashPool"
	runtime.add_child(flash_pool)


func _spawn_dense_targets() -> void:
	for target_index in range(DENSE_TARGET_COUNT):
		var target := ProbePlant.new()
		target.name = "DenseTarget%02d" % target_index
		target.collision_layer = TARGET_COLLISION_LAYER
		target.collision_mask = 0
		var collision_shape := CollisionShape2D.new()
		var circle := CircleShape2D.new()
		circle.radius = 1.5
		collision_shape.shape = circle
		target.add_child(collision_shape)
		runtime.add_child(target)
		var angle := TAU * float(target_index) / float(DENSE_TARGET_COUNT)
		var ring := 9.0 + float(target_index % 5) * 5.0
		target.global_position = Vector2.RIGHT.rotated(angle) * ring
		targets.append(target)


func _spawn_rockets(name_prefix: String) -> Array[CapooRPGRocket]:
	var rockets: Array[CapooRPGRocket] = []
	for rocket_index in range(ROCKET_COUNT):
		var rocket := ROCKET_SCENE.instantiate() as CapooRPGRocket
		if rocket == null:
			continue
		runtime.add_child(rocket)
		rocket.name = "%s%03d" % [name_prefix, rocket_index]
		rocket.global_position = Vector2.ZERO
		rocket.setup(
			Vector2.RIGHT,
			TEST_DAMAGE,
			0.0,
			10.0,
			EXPLOSION_RADIUS
		)
		rocket.bind_gameplay_context(
			runtime,
			runtime.get_multiplayer_gameplay_gateway()
		)
		# The probe invokes the three explosion phases explicitly. Suppress the
		# rocket body's overlap signal so the dense fixture cannot detonate it
		# during the physics-settle frame.
		rocket.collision_layer = 0
		rocket.collision_mask = 0
		rocket.set_physics_process(false)
		rockets.append(rocket)
	return rockets


func _measure_query_phase(
	rockets: Array[CapooRPGRocket]
) -> Dictionary:
	for _warmup_index in range(QUERY_WARMUP_COUNT):
		_reset_target_hits()
		_run_query_batch(rockets)
		await physics_frame

	var samples_ms: Array[float] = []
	var minimum_damage_calls := 1_000_000_000
	var maximum_damage_calls := 0
	for _sample_index in range(QUERY_SAMPLE_COUNT):
		_reset_target_hits()
		var started_usec := Time.get_ticks_usec()
		_run_query_batch(rockets)
		samples_ms.append(
			float(Time.get_ticks_usec() - started_usec) / 1000.0
		)
		var damage_calls := _get_target_hit_count()
		minimum_damage_calls = mini(minimum_damage_calls, damage_calls)
		maximum_damage_calls = maxi(maximum_damage_calls, damage_calls)
		await physics_frame
	return {
		"timing": _summarize(samples_ms),
		"minimum_damage_calls": minimum_damage_calls,
		"maximum_damage_calls": maximum_damage_calls,
		"queries": ROCKET_COUNT,
		"targets_per_query": DENSE_TARGET_COUNT,
	}


func _run_query_batch(rockets: Array[CapooRPGRocket]) -> void:
	for rocket in rockets:
		rocket.call("_apply_explosion_damage")


func _measure_presentation_phase(
	rockets: Array[CapooRPGRocket]
) -> Dictionary:
	var before_count := _count_explosions()
	var started_usec := Time.get_ticks_usec()
	for rocket in rockets:
		rocket.call("_spawn_explosion_effect")
	var sync_ms := float(Time.get_ticks_usec() - started_usec) / 1000.0
	var spawned_count := _count_explosions() - before_count
	await process_frame
	var frame_ms := float(Time.get_ticks_usec() - started_usec) / 1000.0
	var active_flash_count := flash_pool.get_active_flash_count()
	var active_audio_count := get_nodes_in_group(
		&"limited_explosion_audio_players"
	).size()
	_cleanup_explosions()
	await process_frame
	await physics_frame
	return {
		"sync_ms": sync_ms,
		"frame_ms": frame_ms,
		"spawned_count": spawned_count,
		"active_flash_count": active_flash_count,
		"active_audio_count": active_audio_count,
	}


func _measure_full_phase(
	rockets: Array[CapooRPGRocket]
) -> Dictionary:
	_reset_target_hits()
	var before_count := _count_explosions()
	var started_usec := Time.get_ticks_usec()
	for rocket in rockets:
		rocket.call("_explode")
	var sync_ms := float(Time.get_ticks_usec() - started_usec) / 1000.0
	var spawned_count := _count_explosions() - before_count
	var damage_calls := _get_target_hit_count()
	var retired_count := 0
	for rocket in rockets:
		if rocket.has_exploded and not rocket.pool_active:
			retired_count += 1
	await process_frame
	var frame_ms := float(Time.get_ticks_usec() - started_usec) / 1000.0
	var active_flash_count := flash_pool.get_active_flash_count()
	var active_audio_count := get_nodes_in_group(
		&"limited_explosion_audio_players"
	).size()
	_cleanup_explosions()
	return {
		"sync_ms": sync_ms,
		"frame_ms": frame_ms,
		"spawned_count": spawned_count,
		"damage_calls": damage_calls,
		"retired_count": retired_count,
		"active_flash_count": active_flash_count,
		"active_audio_count": active_audio_count,
	}


func _validate(
	query_result: Dictionary,
	presentation_result: Dictionary,
	full_result: Dictionary
) -> void:
	var query_timing := query_result["timing"] as Dictionary
	_expect(
		int(query_result["minimum_damage_calls"]) == EXPECTED_DAMAGE_CALLS
		and int(query_result["maximum_damage_calls"]) == EXPECTED_DAMAGE_CALLS,
		"Every query phase must resolve all 300 x 65 dense target hits."
	)
	_expect_budget(
		float(query_timing["p95"]) <= QUERY_P95_LIMIT_MS,
		"The 300-rocket dense query phase exceeded its CPU p95 gate."
	)
	_expect(
		int(presentation_result["spawned_count"]) == ROCKET_COUNT,
		"The presentation phase must instantiate exactly 300 production explosions."
	)
	_expect(
		int(presentation_result["active_flash_count"]) == 8
		and int(presentation_result["active_audio_count"]) <= 6,
		"The 300-explosion presentation must retain the 8-light and 6-audio budgets."
	)
	_expect_budget(
		float(presentation_result["sync_ms"])
			<= PRESENTATION_SYNC_LIMIT_MS
		and float(presentation_result["frame_ms"])
			<= PRESENTATION_FRAME_LIMIT_MS,
		"The 300-explosion presentation phase exceeded its CPU gate."
	)
	_expect(
		int(full_result["spawned_count"]) == ROCKET_COUNT
		and int(full_result["damage_calls"]) == EXPECTED_DAMAGE_CALLS
		and int(full_result["retired_count"]) == ROCKET_COUNT,
		"The full phase must query, present, and retire all 300 rockets."
	)
	_expect(
		int(full_result["active_flash_count"]) == 8
		and int(full_result["active_audio_count"]) <= 6,
		"The full phase must preserve shared light and audio limits."
	)
	_expect_budget(
		float(full_result["sync_ms"]) <= FULL_SYNC_LIMIT_MS
		and float(full_result["frame_ms"]) <= FULL_FRAME_LIMIT_MS,
		"The 300-rocket full explosion frame exceeded its CPU gate."
	)


func _print_result(
	query_result: Dictionary,
	presentation_result: Dictionary,
	full_result: Dictionary
) -> void:
	var structured := {
		"schema_version": 1,
		"valid": failures.is_empty(),
		"verdict": (
			"passed"
			if failures.is_empty() and budget_violations.is_empty()
			else "failed"
		),
		"rocket_count": ROCKET_COUNT,
		"dense_target_count": DENSE_TARGET_COUNT,
		"thresholds_ms": {
			"query_p95": QUERY_P95_LIMIT_MS,
			"presentation_sync": PRESENTATION_SYNC_LIMIT_MS,
			"presentation_frame": PRESENTATION_FRAME_LIMIT_MS,
			"full_sync": FULL_SYNC_LIMIT_MS,
			"full_frame": FULL_FRAME_LIMIT_MS,
		},
		"query": query_result,
		"presentation": presentation_result,
		"full_frame": full_result,
		"workload_violations": failures,
		"budget_violations": budget_violations,
		"violations": failures + budget_violations,
	}
	print(
		"CAPOO_RPG_300_EXPLOSION_PERFORMANCE_RESULT ",
		JSON.stringify(structured)
	)


func _count_explosions() -> int:
	var count := 0
	for child in runtime.get_children():
		if child is CapooRPGExplosion and not child.is_queued_for_deletion():
			count += 1
	return count


func _cleanup_explosions() -> void:
	for child in runtime.get_children():
		if child is CapooRPGExplosion:
			child.queue_free()


func _free_rockets(rockets: Array[CapooRPGRocket]) -> void:
	for rocket in rockets:
		if is_instance_valid(rocket) and not rocket.is_queued_for_deletion():
			rocket.queue_free()


func _reset_target_hits() -> void:
	for target in targets:
		target.hit_count = 0


func _get_target_hit_count() -> int:
	var total := 0
	for target in targets:
		total += target.hit_count
	return total


func _summarize(samples: Array[float]) -> Dictionary:
	if samples.is_empty():
		return {"p50": 0.0, "p95": 0.0, "p99": 0.0, "max": 0.0}
	var sorted := samples.duplicate()
	sorted.sort()
	return {
		"p50": _percentile(sorted, 0.50),
		"p95": _percentile(sorted, 0.95),
		"p99": _percentile(sorted, 0.99),
		"max": sorted.back(),
	}


func _percentile(sorted: Array[float], ratio: float) -> float:
	var rank := ceili(clampf(ratio, 0.0, 1.0) * float(sorted.size()))
	return sorted[clampi(rank - 1, 0, sorted.size() - 1)]


func _finish() -> void:
	current_scene = null
	if runtime != null and is_instance_valid(runtime):
		runtime.queue_free()
	for _cleanup_frame in range(6):
		await process_frame
		await physics_frame
	if failures.is_empty() and budget_violations.is_empty():
		print("CAPOO_RPG_300_EXPLOSION_PERFORMANCE_PROBE_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	for violation in budget_violations:
		push_error(violation)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _expect_budget(condition: bool, message: String) -> void:
	if not condition:
		budget_violations.append(message)
