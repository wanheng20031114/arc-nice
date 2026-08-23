extends SceneTree

const RUNTIME_SCENE := preload(
	"res://dev_tools/fixtures/enemy_gameplay_gateway_test_runtime.tscn"
)
const VOLLEY_COUNT := 300
const BALLS_PER_VOLLEY := FireSorcererVolleySimulationService.BALL_COUNT
const SAMPLE_FRAMES := 300
const WARMUP_FRAMES := 30
const TEST_DELTA := 1.0 / 60.0
const P95_BUDGET_MS := 16.667
const P99_BUDGET_MS := 33.333
const SCHEMA_VERSION := 1

var _violations := PackedStringArray()


func _initialize() -> void:
	call_deferred(&"_run")


func _run() -> void:
	var runtime := RUNTIME_SCENE.instantiate() as EnemyGameplayGatewayTestRuntime
	_expect(runtime != null, "共享战斗运行时测试场景必须可实例化。")
	if runtime == null:
		_finish({}, 0)
		return
	root.add_child(runtime)
	await process_frame
	await physics_frame

	var combat_services := runtime.get_enemy_combat_services()
	var service := (
		combat_services.get_fire_sorcerer_volley_simulation_service()
		if combat_services != null
		else null
	)
	_expect(
		service != null and service.is_bound(),
		"专用探针必须使用场景中静态挂载并已绑定的齐射服务。"
	)
	if service == null or not service.is_bound():
		runtime.queue_free()
		await process_frame
		_finish({}, 0)
		return

	# Disable the SceneTree driver while this probe advances the same production
	# kernel synchronously. No physics frame is yielded during timed sampling.
	service.set_physics_process(false)
	var node_count_before := _count_nodes_recursive(runtime)
	var handles := PackedInt64Array()
	handles.resize(VOLLEY_COUNT)
	var directions := PackedVector2Array([
		Vector2.RIGHT,
		Vector2.RIGHT,
		Vector2.RIGHT,
	])
	var normal_source_snapshot := DamageSourceSnapshot.create(
		CombatRelationService.HOSTILE_WAVE,
		0,
		9001,
		0,
		FireSorcererVolleySimulationService.NORMAL_FAMILY_SOURCE_TYPE
	)
	var elite_source_snapshot := DamageSourceSnapshot.create(
		CombatRelationService.HOSTILE_WAVE,
		0,
		9002,
		0,
		FireSorcererVolleySimulationService.ELITE_FAMILY_SOURCE_TYPE
	)
	for volley_index in range(VOLLEY_COUNT):
		var column := volley_index % 30
		var row := volley_index / 30
		var origin := Vector2(
			-1200.0 + float(column) * 24.0,
			-1200.0 + float(row) * 24.0
		)
		var positions := PackedVector2Array([
			origin + Vector2(24.0, 1.0),
			origin + Vector2(15.0, -5.0),
			origin + Vector2(23.0, 13.0),
		])
		var elite := volley_index % 2 != 0
		handles[volley_index] = service.register_volley(
			FireSorcererVolleySimulationService.Mode.DATA,
			(
				FireSorcererVolleySimulationService.Profile.ELITE
				if elite
				else FireSorcererVolleySimulationService.Profile.NORMAL
			),
			positions,
			directions,
			100.0,
			60.0,
			6.0,
			1,
			9002 if elite else 9001,
			0,
			null,
			5.0,
			10 if elite else 5,
			elite_source_snapshot if elite else normal_source_snapshot
		)
	_expect(
		_count_live_handles(service, handles) == VOLLEY_COUNT,
		"预分配共享内核必须接纳全部 300 组齐射。"
	)
	_expect(
		_count_nodes_recursive(runtime) == node_count_before,
		"数据齐射注册不得为 900 枚权威火球创建 Node/Area2D/CollisionShape2D。"
	)

	# Registration-frame records are intentionally inert. One real frame makes
	# the authored next-tick activation boundary observable before manual timing.
	await physics_frame
	service.set_physics_process(false)
	for _warmup_index in range(WARMUP_FRAMES):
		service.advance_authoritative(TEST_DELTA)
		service.set_physics_process(false)

	var samples_ms: Array[float] = []
	for _sample_index in range(SAMPLE_FRAMES):
		var started_usec := Time.get_ticks_usec()
		service.advance_authoritative(TEST_DELTA)
		samples_ms.append(
			float(Time.get_ticks_usec() - started_usec) / 1000.0
		)
		service.set_physics_process(false)
	samples_ms.sort()
	var p50_ms := _percentile(samples_ms, 0.50)
	var p95_ms := _percentile(samples_ms, 0.95)
	var p99_ms := _percentile(samples_ms, 0.99)
	var maximum_ms: float = samples_ms.back() if not samples_ms.is_empty() else 0.0
	var over_33_ms := 0
	for sample_ms in samples_ms:
		if sample_ms > P99_BUDGET_MS:
			over_33_ms += 1
	_expect(p95_ms <= P95_BUDGET_MS, "900 枚火球共享内核 p95 超过 16.667ms。")
	_expect(p99_ms <= P99_BUDGET_MS, "900 枚火球共享内核 p99 超过 33.333ms。")
	_expect(
		float(over_33_ms) / float(maxi(samples_ms.size(), 1)) <= 0.005,
		"超过 33.333ms 的采样比例高于 0.5%。"
	)

	var metrics := service.get_metrics()
	_expect(
		int(metrics.get("active_slots", 0)) == VOLLEY_COUNT,
		"计时结束时 300 组长寿命齐射必须仍全部存活。"
	)
	_expect(
		int(metrics.get("ball_advances", 0))
			>= VOLLEY_COUNT * BALLS_PER_VOLLEY * (WARMUP_FRAMES + SAMPLE_FRAMES),
		"探针必须实际推进全部 900 枚火球，禁止伪零工作负载。"
	)
	var result := {
		"volley_count": VOLLEY_COUNT,
		"normal_volley_count": VOLLEY_COUNT / 2,
		"elite_volley_count": VOLLEY_COUNT / 2,
		"ball_count": VOLLEY_COUNT * BALLS_PER_VOLLEY,
		"sample_frames": samples_ms.size(),
		"p50_ms": p50_ms,
		"p95_ms": p95_ms,
		"p99_ms": p99_ms,
		"max_ms": maximum_ms,
		"frames_over_33_333_ms": over_33_ms,
		"authoritative_projectile_nodes": (
			_count_nodes_recursive(runtime) - node_count_before
		),
		"kernel_metrics": metrics,
	}

	service.prepare_for_runtime_teardown()
	_expect(
		int(service.get_metrics().get("active_slots", -1)) == 0,
		"齐射服务 teardown 后 live handle 必须为 0。"
	)
	runtime.queue_free()
	await process_frame
	await physics_frame
	_finish(result, samples_ms.size())


func _count_live_handles(
	service: FireSorcererVolleySimulationService,
	handles: PackedInt64Array
) -> int:
	var count := 0
	for handle in handles:
		if service.is_handle_live(int(handle)):
			count += 1
	return count


func _count_nodes_recursive(node: Node) -> int:
	var count := 1
	for child in node.get_children():
		count += _count_nodes_recursive(child)
	return count


func _percentile(sorted_values: Array[float], ratio: float) -> float:
	if sorted_values.is_empty():
		return 0.0
	var rank := ceili(clampf(ratio, 0.0, 1.0) * sorted_values.size())
	return sorted_values[clampi(rank - 1, 0, sorted_values.size() - 1)]


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_violations.append(message)


func _finish(result: Dictionary, sample_count: int) -> void:
	var valid := _violations.is_empty() and sample_count == SAMPLE_FRAMES
	var payload := {
		"schema_version": SCHEMA_VERSION,
		"valid": valid,
		"verdict": "pass" if valid else "fail",
		"violations": Array(_violations),
		"result": result,
	}
	print("FIRE_SORCERER_DATA_PERFORMANCE_JSON %s" % JSON.stringify(payload))
	if valid:
		print("FIRE_SORCERER_DATA_PERFORMANCE_PROBE_OK")
		quit(0)
		return
	for violation in _violations:
		push_error(violation)
	quit(1)
