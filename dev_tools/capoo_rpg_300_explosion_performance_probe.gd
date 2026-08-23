extends SceneTree

const RocketSimulationServiceScript := preload(
	"res://scene/combat/simulation/capoo_rpg_rocket_simulation_service.gd"
)
const ExplosionResolutionServiceScript := preload(
	"res://scene/combat/simulation/explosion_resolution_service.gd"
)
const ExplosionPresentationServiceScript := preload(
	"res://scene/combat/presentation/explosion_presentation_service.gd"
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
	var rejected_request_count := 0

	func apply_combat_damage(request: DamageRequest) -> DamageResult:
		var result := super.apply_combat_damage(request)
		if result.accepted:
			hit_count += 1
		else:
			rejected_request_count += 1
		return result


var failures: Array[String] = []
var budget_violations: Array[String] = []
var runtime: EnemyGameplayGatewayTestRuntime = null
var flash_pool: NightVfxFlashPool = null
var targets: Array[ProbePlant] = []
var rocket_service: RocketSimulationServiceScript = null
var explosion_service: ExplosionResolutionServiceScript = null
var explosion_presentation: ExplosionPresentationServiceScript = null
var damageable_index: EnemyDamageableSpatialIndex = null
var next_projectile_id := 90000


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	_build_fixture()
	await process_frame
	await physics_frame
	if (
		rocket_service == null
		or explosion_service == null
		or explosion_presentation == null
	):
		print(
			"CAPOO_RPG_300_EXPLOSION_PERFORMANCE_RESULT %s"
			% JSON.stringify({
				"schema_version": 1,
				"valid": false,
				"verdict": "failed",
				"violations": failures.duplicate(),
			})
		)
		await _finish()
		return
	_spawn_dense_targets()
	await process_frame
	await physics_frame

	var query_result := await _measure_query_phase()
	var presentation_result := await _measure_presentation_phase()
	var full_result := await _measure_full_phase()

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
	var combat_services := runtime.get_enemy_combat_services()
	if simulation_coordinator == null or combat_services == null:
		_expect(false, "RPG performance runtime must expose combat services.")
		return
	damageable_index = combat_services.get_enemy_damageable_spatial_index()
	rocket_service = combat_services.get_capoo_rpg_rocket_simulation_service()
	explosion_service = combat_services.get_explosion_resolution_service()
	explosion_presentation = combat_services.get_explosion_presentation_service()
	if (
		rocket_service == null
		or explosion_service == null
		or explosion_presentation == null
	):
		_expect(false, "Runtime must author RPG simulation, resolution, and presentation services.")
		return
	rocket_service.process_mode = Node.PROCESS_MODE_DISABLED
	_expect(
		rocket_service.is_bound() and rocket_service.reserve(ROCKET_COUNT),
		"Rocket simulation service must bind and reserve exactly the probe batch."
	)
	_expect(
		explosion_service.is_bound_to(runtime, simulation_coordinator),
		"Explosion resolution service must bind to the probe runtime."
	)
	_expect(
		explosion_presentation.is_bound(),
		"Explosion presentation service must bind to the probe runtime."
	)

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
		target.max_health = 100_000_000
		target.current_health = 100_000_000
		target.physical_defense = 0
		target.magic_defense = 0
		target.bind_gameplay_context(runtime, null)
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
		_expect(
			damageable_index != null
			and damageable_index.register_damageable(target),
			"Every dense target must register in the shared spatial index."
		)


func _spawn_rocket_batch() -> int:
	rocket_service.clear()
	var spawned_count := 0
	for rocket_index in range(ROCKET_COUNT):
		next_projectile_id += 1
		var snapshot := DamageSourceSnapshot.create(
			CombatRelationService.HOSTILE_WAVE,
			0,
			700,
			next_projectile_id,
			&"capoo_rpg_rocket"
		)
		var handle := rocket_service.spawn_authoritative(
			next_projectile_id,
			Vector2.ZERO,
			Vector2.RIGHT,
			TEST_DAMAGE,
			0.0,
			0.01,
			EXPLOSION_RADIUS,
			snapshot
		)
		if handle != RocketSimulationServiceScript.INVALID_HANDLE:
			spawned_count += 1
	return spawned_count


func _measure_query_phase() -> Dictionary:
	for _warmup_index in range(QUERY_WARMUP_COUNT):
		_spawn_rocket_batch()
		await physics_frame
		_reset_target_hits()
		rocket_service.advance(0.02)
		_resolve_completion_batch(false)
		await physics_frame

	var samples_ms: Array[float] = []
	var minimum_damage_calls := 1_000_000_000
	var maximum_damage_calls := 0
	for _sample_index in range(QUERY_SAMPLE_COUNT):
		var spawned_count := _spawn_rocket_batch()
		await physics_frame
		_reset_target_hits()
		var started_usec := Time.get_ticks_usec()
		rocket_service.advance(0.02)
		var batch_result := _resolve_completion_batch(false)
		samples_ms.append(
			float(Time.get_ticks_usec() - started_usec) / 1000.0
		)
		var damage_calls := _get_target_hit_count()
		_expect(
			spawned_count == ROCKET_COUNT
			and int(batch_result["completion_count"]) == ROCKET_COUNT
			and int(batch_result["accepted_damage_count"]) == damage_calls,
			"Every timed data batch must spawn, complete, and synchronously settle 300 rockets."
		)
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

func _measure_presentation_phase() -> Dictionary:
	var metrics_before := explosion_presentation.get_metrics()
	var started_usec := Time.get_ticks_usec()
	var queued_count := 0
	for _explosion_index in range(ROCKET_COUNT):
		if explosion_presentation.queue_explosion(
			ExplosionPresentationServiceScript.Profile.CAPOO_RPG,
			Vector2.ZERO
		):
			queued_count += 1
	var visible_count := explosion_presentation.flush_presenter(0.0)
	var sync_ms := float(Time.get_ticks_usec() - started_usec) / 1000.0
	await process_frame
	var frame_ms := float(Time.get_ticks_usec() - started_usec) / 1000.0
	var metrics_after := explosion_presentation.get_metrics()
	var structure := _get_presentation_structure_counts()
	return {
		"sync_ms": sync_ms,
		"frame_ms": frame_ms,
		"queued_count": queued_count,
		"presentation_request_count": (
			int(metrics_after["queue_requests"])
			- int(metrics_before["queue_requests"])
		),
		"flush_count": (
			int(metrics_after["flushes"])
			- int(metrics_before["flushes"])
		),
		"visible_count": visible_count,
		"visual_write_count": (
			int(metrics_after["visual_writes"])
			- int(metrics_before["visual_writes"])
		),
		"headless_omission_count": (
			int(metrics_after["headless_omissions"])
			- int(metrics_before["headless_omissions"])
		),
		"active_flash_count": flash_pool.get_active_flash_count(),
		"active_audio_count": int(metrics_after["active_audio_voices"]),
		"draw_family_count": int(metrics_after["draw_family_count"]),
		"visual_capacity": int(metrics_after["visual_capacity"]),
		"headless_disabled": bool(metrics_after["headless_disabled"]),
		"legacy_explosion_node_count": structure["legacy_explosion_nodes"],
		"area_node_count": structure["area_nodes"],
		"collision_shape_node_count": structure["collision_shape_nodes"],
	}


func _measure_full_phase() -> Dictionary:
	var registered_rocket_count := _spawn_rocket_batch()
	await physics_frame
	_reset_target_hits()
	var presentation_before := explosion_presentation.get_metrics()
	var started_usec := Time.get_ticks_usec()
	rocket_service.advance(0.02)
	var batch_result := _resolve_completion_batch(true)
	var visible_count := explosion_presentation.flush_presenter(0.0)
	var sync_ms := float(Time.get_ticks_usec() - started_usec) / 1000.0
	var damage_calls := _get_target_hit_count()
	var retired_count := int(batch_result["completion_count"])
	await process_frame
	var frame_ms := float(Time.get_ticks_usec() - started_usec) / 1000.0
	var presentation_after := explosion_presentation.get_metrics()
	var structure := _get_presentation_structure_counts()
	return {
		"sync_ms": sync_ms,
		"frame_ms": frame_ms,
		"queued_count": int(batch_result["presentation_request_count"]),
		"presentation_request_count": (
			int(presentation_after["queue_requests"])
			- int(presentation_before["queue_requests"])
		),
		"visible_count": visible_count,
		"visual_write_count": (
			int(presentation_after["visual_writes"])
			- int(presentation_before["visual_writes"])
		),
		"headless_omission_count": (
			int(presentation_after["headless_omissions"])
			- int(presentation_before["headless_omissions"])
		),
		"damage_calls": damage_calls,
		"retired_count": retired_count,
		"active_flash_count": flash_pool.get_active_flash_count(),
		"active_audio_count": int(presentation_after["active_audio_voices"]),
		"registered_rocket_count": registered_rocket_count,
		"accepted_damage_count": int(batch_result["accepted_damage_count"]),
		"draw_family_count": int(presentation_after["draw_family_count"]),
		"visual_capacity": int(presentation_after["visual_capacity"]),
		"headless_disabled": bool(presentation_after["headless_disabled"]),
		"legacy_explosion_node_count": structure["legacy_explosion_nodes"],
		"area_node_count": structure["area_nodes"],
		"collision_shape_node_count": structure["collision_shape_nodes"],
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
		int(presentation_result["queued_count"]) == ROCKET_COUNT
		and int(presentation_result["presentation_request_count"]) == ROCKET_COUNT
		and int(presentation_result["flush_count"]) == 1,
		"The presentation phase must queue 300 requests and flush exactly once."
	)
	_expect(
		int(presentation_result["draw_family_count"]) == 2
		and int(presentation_result["visual_capacity"]) == 96
		and int(presentation_result["active_flash_count"]) <= 8
		and int(presentation_result["active_audio_count"]) <= 6,
		"Shared presentation must retain two fixed draw families, 96 visuals, 8 lights, and 6 audio voices."
	)
	_expect(
		int(presentation_result["legacy_explosion_node_count"]) == 0
		and int(presentation_result["area_node_count"]) == 0
		and int(presentation_result["collision_shape_node_count"]) == 0,
		"Shared explosion presentation must not author legacy explosion, Area2D, or CollisionShape2D nodes."
	)
	if bool(presentation_result["headless_disabled"]):
		_expect(
			int(presentation_result["visible_count"]) == 0
			and int(presentation_result["visual_write_count"]) == 0
			and int(presentation_result["headless_omission_count"]) == ROCKET_COUNT,
			"Headless presentation must consume all requests without visual writes."
		)
	_expect_budget(
		float(presentation_result["sync_ms"])
			<= PRESENTATION_SYNC_LIMIT_MS
		and float(presentation_result["frame_ms"])
			<= PRESENTATION_FRAME_LIMIT_MS,
		"The 300-explosion presentation phase exceeded its CPU gate."
	)
	_expect(
		int(full_result["registered_rocket_count"]) == ROCKET_COUNT
		and int(full_result["queued_count"]) == ROCKET_COUNT
		and int(full_result["presentation_request_count"]) == ROCKET_COUNT
		and int(full_result["damage_calls"]) == EXPECTED_DAMAGE_CALLS
		and int(full_result["accepted_damage_count"]) == EXPECTED_DAMAGE_CALLS
		and int(full_result["retired_count"]) == ROCKET_COUNT,
		"The full phase must simulate, settle, present, and retire all 300 data rockets."
	)
	_expect(
		_get_target_rejected_request_count() == 0,
		"All workload counts must come from accepted DamageRequest sink results."
	)
	_expect(
		int(full_result["draw_family_count"]) == 2
		and int(full_result["visual_capacity"]) == 96
		and int(full_result["active_flash_count"]) <= 8
		and int(full_result["active_audio_count"]) <= 6,
		"The full phase must preserve shared light and audio limits."
	)
	_expect(
		int(full_result["legacy_explosion_node_count"]) == 0
		and int(full_result["area_node_count"]) == 0
		and int(full_result["collision_shape_node_count"]) == 0,
		"The full data path must remain free of legacy explosion physics/presentation nodes."
	)
	if bool(full_result["headless_disabled"]):
		_expect(
			int(full_result["visible_count"]) == 0
			and int(full_result["visual_write_count"]) == 0
			and int(full_result["headless_omission_count"]) == ROCKET_COUNT,
			"Headless full-frame settlement must perform no visual writes."
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
		"rocket_service_metrics": rocket_service.get_metrics(),
		"explosion_service_metrics": explosion_service.get_metrics(),
		"explosion_presentation_metrics": explosion_presentation.get_metrics(),
		"diagnostic_blocker": (
			"dense_300x65_cpu_budget"
			if not budget_violations.is_empty()
			else ""
		),
		"workload_violations": failures,
		"budget_violations": budget_violations,
		"violations": failures + budget_violations,
	}
	print(
		"CAPOO_RPG_300_EXPLOSION_PERFORMANCE_RESULT ",
		JSON.stringify(structured)
	)


func _resolve_completion_batch(queue_presentations: bool) -> Dictionary:
	var completion_count := rocket_service.get_completion_count()
	var accepted_damage_count := 0
	var presentation_request_count := 0
	for completion_index in range(completion_count):
		accepted_damage_count += explosion_service.resolve_hostile_explosion(
			rocket_service.get_completion_position(completion_index),
			rocket_service.get_completion_radius(completion_index),
			rocket_service.get_completion_damage(completion_index),
			rocket_service.get_completion_direct_hit(completion_index),
			rocket_service.get_completion_damage_source_snapshot(completion_index),
			700,
			rocket_service.get_completion_projectile_id(completion_index),
			&"capoo_rpg_rocket",
			EnemyConfig.DamageType.PHYSICAL
		)
		if queue_presentations:
			if explosion_presentation.queue_explosion(
				ExplosionPresentationServiceScript.Profile.CAPOO_RPG,
				rocket_service.get_completion_position(completion_index)
			):
				presentation_request_count += 1
	rocket_service.clear_completion_records()
	return {
		"completion_count": completion_count,
		"accepted_damage_count": accepted_damage_count,
		"presentation_request_count": presentation_request_count,
	}


func _get_presentation_structure_counts() -> Dictionary:
	var counts := {
		"legacy_explosion_nodes": 0,
		"area_nodes": 0,
		"collision_shape_nodes": 0,
	}
	_count_legacy_explosion_nodes(runtime, counts)
	_count_presentation_physics_nodes(explosion_presentation, counts)
	return counts


func _count_legacy_explosion_nodes(node: Node, counts: Dictionary) -> void:
	var script := node.get_script() as Script
	if (
		script != null
		and script.resource_path
			== "res://scene/enemy/capoo/capoo_rpg_explosion.gd"
	):
		counts["legacy_explosion_nodes"] = int(counts["legacy_explosion_nodes"]) + 1
	for child in node.get_children():
		_count_legacy_explosion_nodes(child, counts)


func _count_presentation_physics_nodes(node: Node, counts: Dictionary) -> void:
	if node is Area2D:
		counts["area_nodes"] = int(counts["area_nodes"]) + 1
	if node is CollisionShape2D:
		counts["collision_shape_nodes"] = int(counts["collision_shape_nodes"]) + 1
	for child in node.get_children():
		_count_presentation_physics_nodes(child, counts)


func _reset_target_hits() -> void:
	for target in targets:
		target.hit_count = 0
		target.rejected_request_count = 0


func _get_target_hit_count() -> int:
	var total := 0
	for target in targets:
		total += target.hit_count
	return total


func _get_target_rejected_request_count() -> int:
	var total := 0
	for target in targets:
		total += target.rejected_request_count
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
