extends SceneTree

const FIREBALL_SCENE := preload("res://scene/enemy/capoo/capoo_mage_fireball.tscn")
const IMPACT_SCENE := preload("res://scene/enemy/capoo/capoo_mage_fireball_impact.tscn")

const BURST_SIZE := 48
const ROUNDS := 3
const COMPLETION_GUARD_FRAMES := 180


class PoolRuntime:
	extends Node2D

	var session_object_pool: SessionObjectPool = null
	var direct_impact_creations := 0

	func configure_pool(scene: PackedScene) -> void:
		session_object_pool = SessionObjectPool.new()
		session_object_pool.name = "SessionObjectPool"
		add_child(session_object_pool)
		session_object_pool.register_scene(scene, BURST_SIZE, 64)
		child_entered_tree.connect(_on_child_entered_tree)

	func has_session_object_pool_scene(scene: PackedScene) -> bool:
		return session_object_pool != null and session_object_pool.is_registered(scene)

	func acquire_session_object(scene: PackedScene, strict: bool = false) -> Node:
		if session_object_pool == null:
			return null
		return (
			session_object_pool.try_acquire(scene)
			if strict
			else session_object_pool.acquire(scene)
		)

	func _on_child_entered_tree(child: Node) -> void:
		if child is CapooMageFireballImpact:
			direct_impact_creations += 1


var failures: Array[String] = []
var runtime: PoolRuntime = null
var fireball: CapooMageFireball = null
var original_pool_mode := true


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	original_pool_mode = CapooMageFireball.pooled_impact_effect_enabled
	runtime = PoolRuntime.new()
	runtime.name = "CapooMageImpactPoolPerformanceAB"
	root.add_child(runtime)
	current_scene = runtime
	runtime.configure_pool(IMPACT_SCENE)

	fireball = FIREBALL_SCENE.instantiate() as CapooMageFireball
	runtime.add_child(fireball)
	fireball.global_position = Vector2.ZERO
	await process_frame

	# Load/compile the direct playback path before collecting either timing.
	CapooMageFireball.pooled_impact_effect_enabled = false
	fireball.call("_spawn_impact_effect")
	await _wait_for_direct_impacts()
	runtime.direct_impact_creations = 0

	var direct_times := await _measure_mode(false)
	var pooled_times := await _measure_mode(true)
	var metrics := runtime.session_object_pool.get_metrics(IMPACT_SCENE.resource_path)

	_expect(
		runtime.direct_impact_creations == BURST_SIZE * ROUNDS,
		"Direct A/B path did not create one impact node per request."
	)
	_expect(int(metrics.get("created", -1)) == BURST_SIZE, "Pooled A/B path grew beyond prewarm.")
	_expect(int(metrics.get("peak_in_use", -1)) == BURST_SIZE, "Pooled burst did not reuse all leases.")
	_expect(int(metrics.get("overflow", -1)) == 0, "Strict impact pool created overflow nodes.")
	_expect(int(metrics.get("dropped", -1)) == 0, "In-capacity pooled A/B burst dropped effects.")
	_expect(int(metrics.get("in_use", -1)) == 0, "Pooled A/B left active leases.")
	_expect(int(metrics.get("pending_release", -1)) == 0, "Pooled A/B left quarantined leases.")

	var direct_average := _average(direct_times)
	var pooled_average := _average(pooled_times)
	print(
		(
			"CAPOO_MAGE_IMPACT_POOL_AB direct_avg_usec=%.2f pooled_avg_usec=%.2f "
			+ "speedup=%.3fx direct_allocations=%d pooled_created=%d peak=%d"
		)
		% [
			direct_average,
			pooled_average,
			direct_average / maxf(pooled_average, 0.001),
			runtime.direct_impact_creations,
			int(metrics.get("created", 0)),
			int(metrics.get("peak_in_use", 0)),
		]
	)

	CapooMageFireball.pooled_impact_effect_enabled = original_pool_mode
	runtime.queue_free()
	await process_frame
	await physics_frame

	if failures.is_empty():
		print("CAPOO_MAGE_IMPACT_POOL_PERFORMANCE_AB_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _measure_mode(pooled: bool) -> PackedFloat64Array:
	CapooMageFireball.pooled_impact_effect_enabled = pooled
	var elapsed := PackedFloat64Array()
	for round_index in range(ROUNDS):
		var started_usec := Time.get_ticks_usec()
		for impact_index in range(BURST_SIZE):
			fireball.global_position = Vector2(
				float(impact_index % 8) * 4.0,
				float(impact_index / 8) * 4.0
			)
			fireball.call("_spawn_impact_effect")
		elapsed.append(float(Time.get_ticks_usec() - started_usec))
		if pooled:
			await _wait_for_pool_idle()
		else:
			await _wait_for_direct_impacts()
	return elapsed


func _wait_for_pool_idle() -> void:
	var guard := 0
	while guard < COMPLETION_GUARD_FRAMES:
		var metrics := runtime.session_object_pool.get_metrics(IMPACT_SCENE.resource_path)
		if (
			int(metrics.get("in_use", 0)) == 0
			and int(metrics.get("pending_release", 0)) == 0
		):
			return
		await process_frame
		guard += 1
	_expect(false, "Pooled A/B impacts did not drain.")


func _wait_for_direct_impacts() -> void:
	var guard := 0
	while guard < COMPLETION_GUARD_FRAMES:
		var found := false
		for child in runtime.get_children():
			if child is CapooMageFireballImpact:
				found = true
				break
		if not found:
			return
		await process_frame
		guard += 1
	_expect(false, "Direct A/B impacts did not drain.")


func _average(values: PackedFloat64Array) -> float:
	if values.is_empty():
		return 0.0
	var total := 0.0
	for value in values:
		total += value
	return total / float(values.size())


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
