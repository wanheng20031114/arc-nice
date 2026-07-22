extends SceneTree

const POOL_SCRIPT := preload("res://scene/session_object_pool.gd")
const EFFECT_SCENE := preload("res://scene/enemy/yuanshi_insect_spawn_effect.tscn")

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	await _test_two_generation_settlement()
	await _test_compaction_preserves_newer_suffix()
	if failures.is_empty():
		print("SESSION_OBJECT_POOL_PENDING_RELEASE_QUEUE_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_two_generation_settlement() -> void:
	var pool := POOL_SCRIPT.new() as SessionObjectPool
	root.add_child(pool)
	pool.set_physics_process(false)
	pool.register_scene(EFFECT_SCENE, 2, 2)

	var leases: Array[Node] = []
	for _index in 6:
		leases.append(pool.acquire(EFFECT_SCENE))
	for index in 4:
		_expect(pool.release(leases[index]), "First generation lease must release.")
	pool._process_pending_releases()
	_assert_metrics(pool, 6, 2, 0, 4, "same-frame quarantine")

	await physics_frame
	for index in range(4, 6):
		_expect(pool.release(leases[index]), "Second generation lease must release.")
	_assert_metrics(pool, 6, 0, 0, 6, "two-generation queue before drain")
	pool._process_pending_releases()
	_assert_metrics(pool, 4, 0, 2, 2, "due-prefix drain")

	var first_reused := pool.acquire(EFFECT_SCENE)
	var second_reused := pool.acquire(EFFECT_SCENE)
	_expect(
		first_reused == leases[2] and second_reused == leases[3],
		"Due-prefix drain must preserve the previous newest-first retention/reuse order."
	)
	_assert_metrics(pool, 4, 2, 0, 2, "first-generation reuse")

	# The newer suffix must remain quarantined until its own absolute frame.
	pool._process_pending_releases()
	_assert_metrics(pool, 4, 2, 0, 2, "newer suffix same-frame isolation")
	await physics_frame
	pool._process_pending_releases()
	_assert_metrics(pool, 4, 2, 2, 0, "newer suffix drain")

	# A lease can disappear externally while quarantined. The queue must still
	# decrement both pending_release and created without retaining an invalid ref.
	_expect(pool.release(first_reused), "Invalid-instance fixture must release lease one.")
	first_reused.free()
	_expect(pool.release(second_reused), "Capacity fixture must release lease two.")
	await physics_frame
	pool._process_pending_releases()
	_assert_metrics(pool, 2, 0, 2, 0, "invalid and over-capacity settlement")

	pool.queue_free()
	await process_frame


func _test_compaction_preserves_newer_suffix() -> void:
	var pool := POOL_SCRIPT.new() as SessionObjectPool
	root.add_child(pool)
	pool.set_physics_process(false)
	var current_frame := Engine.get_physics_frames()
	for index in 1400:
		pool._pending_nodes.append(null)
		pool._pending_available_frames.append(current_frame if index < 1200 else current_frame + 1)
		pool._pending_keys.append("res://missing_fixture.tscn")
	pool._process_pending_releases()
	_expect(
		pool._pending_head == 0
		and pool._pending_nodes.size() == 200
		and pool._pending_available_frames.size() == 200
		and pool._pending_keys.size() == 200
		and pool._pending_available_frames[0] == current_frame + 1,
		"Compaction must discard the consumed prefix and preserve the complete newer suffix."
	)
	pool._process_pending_releases()
	_expect(
		pool._pending_nodes.size() == 200,
		"A compacted newer suffix must remain quarantined in the same physics frame."
	)
	await physics_frame
	pool._process_pending_releases()
	_expect(
		pool._pending_head == 0
		and pool._pending_nodes.is_empty()
		and pool._pending_available_frames.is_empty()
		and pool._pending_keys.is_empty(),
		"The compacted suffix must drain and reset all queue storage at its deadline."
	)
	pool.queue_free()
	await process_frame


func _assert_metrics(
	pool: SessionObjectPool,
	created: int,
	in_use: int,
	inactive: int,
	pending: int,
	phase: String
) -> void:
	var metrics := pool.get_metrics(EFFECT_SCENE.resource_path)
	_expect(
		int(metrics.get("created", -1)) == created
		and int(metrics.get("in_use", -1)) == in_use
		and int(metrics.get("inactive", -1)) == inactive
		and int(metrics.get("pending_release", -1)) == pending,
		"%s metrics mismatch: expected c=%d u=%d i=%d p=%d, got %s"
		% [phase, created, in_use, inactive, pending, metrics]
	)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
