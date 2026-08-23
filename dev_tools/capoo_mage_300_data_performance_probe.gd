extends SceneTree

const MageSimulationServiceScript := preload(
	"res://scene/combat/simulation/capoo_mage_fireball_simulation_service.gd"
)
const RUNTIME_SCENE := preload(
	"res://dev_tools/fixtures/enemy_gameplay_gateway_test_runtime.tscn"
)

const SCHEMA_VERSION := 1
const FIREBALL_COUNT := 300
const TEST_DELTA := 1.0 / 60.0
const LIVE_TARGET_FRAMES := 600
const DEAD_TARGET_FRAMES := 600
const SAMPLE_FRAMES := LIVE_TARGET_FRAMES + DEAD_TARGET_FRAMES
const ADVANCES_PER_REALTIME_PACE := 4
const REALTIME_PACE_COUNT := SAMPLE_FRAMES / ADVANCES_PER_REALTIME_PACE
const MINIMUM_REAL_SAMPLE_SECONDS := 5.0
const MINIMUM_SIMULATED_SECONDS := 20.0
const SPEED := 15.0
const LIFETIME := 40.0
const DAMAGE := 18
const P95_BUDGET_MS := 14.0
const P99_BUDGET_MS := 33.333
const FIRST_PROJECTILE_ID := 810_000

var workload_violations := PackedStringArray()
var budget_violations := PackedStringArray()
var runtime: EnemyGameplayGatewayTestRuntime = null
var combat_services: EnemyCombatServices = null
var service: MageSimulationServiceScript = null
var target: PlantDefense = null
var next_projectile_id := FIRST_PROJECTILE_ID
var unexpected_completion_count := 0


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	_build_authored_fixture()
	await process_frame
	await physics_frame
	if service == null or not service.is_bound():
		_expect_workload(false, "探针必须取得真实 authored runtime 中已绑定的 Mage DATA 服务。")
		await _print_and_finish({}, {}, {})
		return

	# The target belongs to the fixture but has no physics shape. It therefore
	# exercises the production weak-target homing path without adding a native
	# collision contact to the 300-projectile workload.
	_spawn_soft_homing_target()
	await process_frame
	await physics_frame
	service.process_mode = Node.PROCESS_MODE_DISABLED
	combat_services.set_physics_process(false)
	service.clear()
	_expect_workload(
		service.reserve(FIREBALL_COUNT),
		"Mage DATA 服务必须预留并接纳 300 条记录。"
	)

	var structure_before := _count_authoritative_structure(runtime)
	var handles := _spawn_data_batch(target)
	var structure_after := _count_authoritative_structure(runtime)
	var structure_delta := {
		"legacy_capoo_mage_fireball_nodes": (
			int(structure_after["legacy_capoo_mage_fireball_nodes"])
			- int(structure_before["legacy_capoo_mage_fireball_nodes"])
		),
		"authoritative_area2d_nodes": (
			int(structure_after["area2d_nodes"])
			- int(structure_before["area2d_nodes"])
		),
		"authoritative_collision_shape2d_nodes": (
			int(structure_after["collision_shape2d_nodes"])
			- int(structure_before["collision_shape2d_nodes"])
		),
	}
	_expect_workload(
		handles.size() == FIREBALL_COUNT
		and _count_live_handles(handles) == FIREBALL_COUNT
		and service.get_live_count() == FIREBALL_COUNT,
		"探针必须同时保有完整 300 个 DATA 法球。"
	)
	_expect_workload(
		int(structure_delta["legacy_capoo_mage_fireball_nodes"]) == 0
		and int(structure_delta["authoritative_area2d_nodes"]) == 0
		and int(structure_delta["authoritative_collision_shape2d_nodes"]) == 0,
		"DATA 注册不得创建旧 CapooMageFireball、Area2D 或 CollisionShape2D 权威节点。"
	)

	# Registration-frame rows are inert. The physics-frame yield crosses the
	# authored next-frame activation boundary while processing remains disabled.
	await physics_frame
	service.process_mode = Node.PROCESS_MODE_DISABLED
	combat_services.set_physics_process(false)

	var samples_ms: Array[float] = []
	var death_positions := PackedVector2Array()
	var death_directions := PackedVector2Array()
	death_positions.resize(FIREBALL_COUNT)
	death_directions.resize(FIREBALL_COUNT)
	var minimum_live_count := FIREBALL_COUNT
	var sampling_started_usec := Time.get_ticks_usec()
	for simulated_frame in range(SAMPLE_FRAMES):
		if simulated_frame == LIVE_TARGET_FRAMES:
			_capture_stable_motion(death_positions, death_directions)
			target.is_dead = true
		var started_usec := Time.get_ticks_usec()
		service.advance(TEST_DELTA)
		samples_ms.append(float(Time.get_ticks_usec() - started_usec) / 1000.0)
		service.process_mode = Node.PROCESS_MODE_DISABLED
		minimum_live_count = mini(minimum_live_count, service.get_live_count())
		_consume_without_damage_and_replenish()
		minimum_live_count = mini(minimum_live_count, service.get_live_count())
		if (simulated_frame + 1) % ADVANCES_PER_REALTIME_PACE == 0:
			await create_timer(TEST_DELTA, true, false, true).timeout
			service.process_mode = Node.PROCESS_MODE_DISABLED
			combat_services.set_physics_process(false)
	var real_sample_seconds := (
		float(Time.get_ticks_usec() - sampling_started_usec) / 1_000_000.0
	)
	var simulated_seconds := float(SAMPLE_FRAMES) * TEST_DELTA

	var live_segment_rotated_count := 0
	var dead_segment_straight_count := 0
	var dead_segment_position_match_count := 0
	var dead_segment_max_position_error := 0.0
	for stable_index in range(FIREBALL_COUNT):
		var death_direction := death_directions[stable_index]
		if death_direction.y > 0.001 and death_direction != Vector2.RIGHT:
			live_segment_rotated_count += 1
		var final_direction := service.get_direction_at_stable_index(stable_index)
		if final_direction.is_equal_approx(death_direction):
			dead_segment_straight_count += 1
		var expected_position := (
			death_positions[stable_index]
			+ death_direction * SPEED * float(DEAD_TARGET_FRAMES) * TEST_DELTA
		)
		var position_error := service.get_position_at_stable_index(
			stable_index
		).distance_to(expected_position)
		dead_segment_max_position_error = maxf(
			dead_segment_max_position_error,
			position_error
		)
		# Positions are stored in PackedVector2Array (float32). At a 5,000 px
		# origin, 600 accumulated 0.25 px steps can legitimately differ from
		# the one-shot analytical sum by a few tenths of a pixel.
		if position_error <= 0.5:
			dead_segment_position_match_count += 1

	var timing := _summarize(samples_ms)
	var metrics_before_teardown := service.get_metrics()
	_expect_workload(
		samples_ms.size() == SAMPLE_FRAMES
		and real_sample_seconds >= MINIMUM_REAL_SAMPLE_SECONDS
		and simulated_seconds >= MINIMUM_SIMULATED_SECONDS,
		"探针必须完成至少 5 秒真实采样和 20 秒固定 60Hz 模拟等价工作量。"
	)
	_expect_workload(
		minimum_live_count == FIREBALL_COUNT
		and service.get_live_count() == FIREBALL_COUNT
		and unexpected_completion_count == 0,
		"全程必须保持 300 个 DATA 法球存活，且长寿命空场工作负载不应产生 completion。"
	)
	_expect_workload(
		live_segment_rotated_count == FIREBALL_COUNT,
		"存活目标阶段必须让全部 300 个法球执行软追踪转向。"
	)
	_expect_workload(
		dead_segment_straight_count == FIREBALL_COUNT
		and dead_segment_position_match_count == FIREBALL_COUNT,
		"目标死亡后全部法球必须保持死亡瞬间方向直飞，禁止重捕或继续回转。"
	)
	_expect_workload(
		int(metrics_before_teardown.get("data_live_count", -1)) == FIREBALL_COUNT
		and int(metrics_before_teardown.get("replica_live_count", -1)) == 0
		and int(metrics_before_teardown.get("advances", 0))
			>= FIREBALL_COUNT * SAMPLE_FRAMES
		and int(metrics_before_teardown.get("world_queries", 0))
			>= FIREBALL_COUNT * SAMPLE_FRAMES
		and int(metrics_before_teardown.get("direct_queries", 0))
			>= FIREBALL_COUNT * SAMPLE_FRAMES
		and int(metrics_before_teardown.get("homing_updates", 0))
			>= FIREBALL_COUNT * LIVE_TARGET_FRAMES
		and int(metrics_before_teardown.get("homing_targets_lost", 0))
			== FIREBALL_COUNT,
		"服务指标必须证明 300 条记录实际完成两段逐帧运动、查询和目标失效处理。"
	)
	_expect_budget(
		float(timing["p95_ms"]) <= P95_BUDGET_MS,
		"300 DATA 法球总服务 advance p95 超过 14ms。"
	)
	_expect_budget(
		float(timing["p99_ms"]) <= P99_BUDGET_MS,
		"300 DATA 法球总服务 advance p99 超过 33.333ms。"
	)

	service.teardown()
	var teardown_metrics := service.get_metrics()
	var teardown := {
		"live_count": int(teardown_metrics.get("live_count", -1)),
		"dense_record_count": int(teardown_metrics.get("dense_record_count", -1)),
		"pending_completions": int(teardown_metrics.get("pending_completions", -1)),
		"teardown_prepared": bool(teardown_metrics.get("teardown_prepared", false)),
	}
	_expect_workload(
		int(teardown["live_count"]) == 0
		and int(teardown["dense_record_count"]) == 0
		and int(teardown["pending_completions"]) == 0
		and bool(teardown["teardown_prepared"]),
		"teardown 后 live、dense 与 completion 必须全部归零。"
	)

	var workload := {
		"fireball_count": FIREBALL_COUNT,
		"sample_frames": samples_ms.size(),
		"fixed_delta_seconds": TEST_DELTA,
		"simulated_seconds": simulated_seconds,
		"real_sample_seconds": real_sample_seconds,
		"live_target_frames": LIVE_TARGET_FRAMES,
		"dead_target_frames": DEAD_TARGET_FRAMES,
		"minimum_live_count": minimum_live_count,
		"unexpected_completion_count": unexpected_completion_count,
		"live_segment_rotated_count": live_segment_rotated_count,
		"dead_segment_straight_count": dead_segment_straight_count,
		"dead_segment_position_match_count": dead_segment_position_match_count,
		"dead_segment_max_position_error": dead_segment_max_position_error,
	}
	await _print_and_finish(
		timing,
		{
			"workload": workload,
			"structure": structure_delta,
			"service_metrics": metrics_before_teardown,
			"teardown": teardown,
		},
		{
			"advance_p95_ms": P95_BUDGET_MS,
			"advance_p99_ms": P99_BUDGET_MS,
		}
	)


func _build_authored_fixture() -> void:
	runtime = RUNTIME_SCENE.instantiate() as EnemyGameplayGatewayTestRuntime
	if runtime == null:
		return
	runtime.name = "CapooMage300DataPerformanceProbe"
	root.add_child(runtime)
	current_scene = runtime
	combat_services = runtime.get_enemy_combat_services()
	if combat_services == null:
		return
	service = combat_services.get_capoo_mage_fireball_simulation_service()
	combat_services.set_physics_process(false)
	if service != null:
		service.process_mode = Node.PROCESS_MODE_DISABLED


func _spawn_soft_homing_target() -> void:
	target = PlantDefense.new()
	target.name = "SoftHomingTarget"
	target.collision_layer = 0
	target.collision_mask = 0
	target.max_health = 1_000_000
	target.current_health = 1_000_000
	target.global_position = Vector2(10_000.0, 20_000.0)
	runtime.add_child(target)


func _spawn_data_batch(homing_target: Node2D) -> PackedInt64Array:
	var handles := PackedInt64Array()
	for fireball_index in range(FIREBALL_COUNT):
		var column := fireball_index % 30
		var row := fireball_index / 30
		var position := Vector2(
			-5000.0 + float(column) * 7.0,
			-5000.0 + float(row) * 7.0
		)
		var snapshot := DamageSourceSnapshot.create(
			CombatRelationService.HOSTILE_WAVE,
			0,
			9200 + fireball_index,
			0,
			MageSimulationServiceScript.SOURCE_TYPE
		)
		var handle := service.spawn_authoritative(
			position,
			Vector2.RIGHT,
			DAMAGE,
			SPEED,
			LIFETIME,
			MageSimulationServiceScript.DEFAULT_RADIUS,
			homing_target,
			MageSimulationServiceScript.DEFAULT_HOMING_TURN_RATE,
			snapshot,
			MageSimulationServiceScript.Profile.NORMAL
		)
		if handle == MageSimulationServiceScript.INVALID_HANDLE:
			continue
		next_projectile_id += 1
		if not service.assign_projectile_identity(handle, next_projectile_id):
			service.release(handle)
			continue
		handles.append(handle)
	return handles


func _count_live_handles(handles: PackedInt64Array) -> int:
	var count := 0
	for handle in handles:
		if service.is_handle_live(int(handle)):
			count += 1
	return count


func _capture_stable_motion(
	positions: PackedVector2Array,
	directions: PackedVector2Array
) -> void:
	for stable_index in range(FIREBALL_COUNT):
		positions[stable_index] = service.get_position_at_stable_index(stable_index)
		directions[stable_index] = service.get_direction_at_stable_index(stable_index)


func _consume_without_damage_and_replenish() -> void:
	var completion_count := service.get_completion_count()
	if completion_count <= 0:
		return
	unexpected_completion_count += completion_count
	service.clear_completion_records()
	while service.get_live_count() < FIREBALL_COUNT:
		var replacement := _spawn_data_batch(target)
		if replacement.is_empty():
			break


func _count_authoritative_structure(node: Node) -> Dictionary:
	var counts := {
		"legacy_capoo_mage_fireball_nodes": 0,
		"area2d_nodes": 0,
		"collision_shape2d_nodes": 0,
	}
	_count_authoritative_structure_recursive(node, counts)
	return counts


func _count_authoritative_structure_recursive(node: Node, counts: Dictionary) -> void:
	var script := node.get_script() as Script
	if (
		script != null
		and script.resource_path == "res://scene/enemy/capoo/capoo_mage_fireball.gd"
	):
		counts["legacy_capoo_mage_fireball_nodes"] = (
			int(counts["legacy_capoo_mage_fireball_nodes"]) + 1
		)
	if node is Area2D:
		counts["area2d_nodes"] = int(counts["area2d_nodes"]) + 1
	if node is CollisionShape2D:
		counts["collision_shape2d_nodes"] = int(counts["collision_shape2d_nodes"]) + 1
	for child in node.get_children():
		_count_authoritative_structure_recursive(child, counts)


func _summarize(samples_ms: Array[float]) -> Dictionary:
	if samples_ms.is_empty():
		return {
			"sample_count": 0,
			"p50_ms": 0.0,
			"p95_ms": 0.0,
			"p99_ms": 0.0,
			"max_ms": 0.0,
		}
	var sorted := samples_ms.duplicate()
	sorted.sort()
	return {
		"sample_count": sorted.size(),
		"p50_ms": _percentile(sorted, 0.50),
		"p95_ms": _percentile(sorted, 0.95),
		"p99_ms": _percentile(sorted, 0.99),
		"max_ms": sorted.back(),
	}


func _percentile(sorted: Array[float], ratio: float) -> float:
	var rank := ceili(clampf(ratio, 0.0, 1.0) * float(sorted.size()))
	return sorted[clampi(rank - 1, 0, sorted.size() - 1)]


func _expect_workload(condition: bool, message: String) -> void:
	if not condition:
		workload_violations.append(message)


func _expect_budget(condition: bool, message: String) -> void:
	if not condition:
		budget_violations.append(message)


func _print_and_finish(
	timing: Dictionary,
	result: Dictionary,
	thresholds_ms: Dictionary
) -> void:
	var violations := Array(workload_violations) + Array(budget_violations)
	var valid := workload_violations.is_empty()
	var verdict := "pass" if valid and budget_violations.is_empty() else "fail"
	var payload := {
		"schema_version": SCHEMA_VERSION,
		"valid": valid,
		"verdict": verdict,
		"violations": violations,
		"workload_violations": Array(workload_violations),
		"budget_violations": Array(budget_violations),
		"thresholds_ms": thresholds_ms,
		"advance_timing": timing,
		"result": result,
	}
	print("CAPOO_MAGE_300_DATA_PERFORMANCE_RESULT %s" % JSON.stringify(payload))
	if combat_services != null and is_instance_valid(combat_services):
		combat_services.prepare_for_runtime_teardown()
	current_scene = null
	if runtime != null and is_instance_valid(runtime):
		runtime.queue_free()
	for _cleanup_frame in range(6):
		await process_frame
		await physics_frame
	if verdict == "pass":
		print("CAPOO_MAGE_300_DATA_PERFORMANCE_PROBE_OK")
		quit(0)
		return
	for violation in violations:
		push_error(violation)
	quit(1)
