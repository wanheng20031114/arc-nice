extends SceneTree

const RETICLE_SCENE := preload("res://scene/enemy/capoo/capoo_sniper_lock_reticle.tscn")
const COORDINATOR_SCRIPT := preload(
	"res://scene/enemy/capoo/capoo_sniper_lock_visual_coordinator.gd"
)

const RETICLE_COUNT := 240
const TARGET_STATIC_CHILD_COUNT := 16
const WARMUP_ITERATIONS := 12
const SAMPLE_ITERATIONS := 120

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var legacy_result := await _measure_phase(false)
	var batched_result := await _measure_phase(true)
	await _test_coordinated_behavior()

	var legacy_usec := int(legacy_result.get("elapsed_usec", 0))
	var batched_usec := int(batched_result.get("elapsed_usec", 0))
	var speedup := float(legacy_usec) / float(maxi(batched_usec, 1))
	var expected_passes := RETICLE_COUNT * SAMPLE_ITERATIONS
	var expected_candidate_ceiling := RETICLE_COUNT * SAMPLE_ITERATIONS
	_expect(
		int(batched_result.get("arbitration_passes", -1)) == SAMPLE_ITERATIONS + 1,
		"Batched arbitration must execute once per sample tick plus one coalesced teardown pass."
	)
	_expect(
		int(batched_result.get("candidate_visits", -1)) <= expected_candidate_ceiling,
		"Batched arbitration candidate visits must remain O(R), not O(R²)."
	)
	_expect(
		int(batched_result.get("unregister_count", -1)) == RETICLE_COUNT
		and int(batched_result.get("unregister_slot_lookups", -1)) == RETICLE_COUNT,
		"Same-frame teardown must use exactly one stored-slot lookup per reticle."
	)
	_expect(
		int(batched_result.get("unregister_swaps", -1)) <= RETICLE_COUNT - 1
		and int(batched_result.get("invalid_cleanups", -1)) == 0,
		"Normal teardown must remain bounded swap-pop work without invalid-entry scans."
	)
	_expect(
		int(batched_result.get("tracked_reticles", -1)) == 0
		and int(batched_result.get("tracked_targets", -1)) == 0
		and int(batched_result.get("dirty_targets", -1)) == 0,
		"Same-frame teardown must completely empty the coordinator registry."
	)
	_expect(
		speedup >= 3.0,
		"Shared lock arbitration should be materially faster than sibling scans. speedup=%.2fx"
		% speedup
	)
	print(
		(
			"CAPOO_SNIPER_LOCK_VISUAL_AB reticles=%d samples=%d legacy_usec=%d "
			+ "batched_usec=%d speedup=%.2fx legacy_implied_child_visits=%d "
			+ "batched_passes=%d batched_candidate_visits=%d legacy_teardown_usec=%d "
			+ "batched_teardown_usec=%d unregisters=%d slot_lookups=%d swaps=%d"
		)
		% [
			RETICLE_COUNT,
			SAMPLE_ITERATIONS,
			legacy_usec,
			batched_usec,
			speedup,
			2 * RETICLE_COUNT * expected_passes,
			int(batched_result.get("arbitration_passes", 0)),
			int(batched_result.get("candidate_visits", 0)),
			int(legacy_result.get("teardown_usec", 0)),
			int(batched_result.get("teardown_usec", 0)),
			int(batched_result.get("unregister_count", 0)),
			int(batched_result.get("unregister_slot_lookups", 0)),
			int(batched_result.get("unregister_swaps", 0)),
		]
	)

	for _cleanup_frame in range(4):
		await process_frame
		await physics_frame
	if failures.is_empty():
		print("CAPOO_SNIPER_LOCK_VISUAL_PERFORMANCE_AB_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _measure_phase(use_batched_arbitration: bool) -> Dictionary:
	var fixture := Node2D.new()
	fixture.name = "BatchedFixture" if use_batched_arbitration else "LegacyFixture"
	root.add_child(fixture)
	current_scene = fixture

	var coordinator := COORDINATOR_SCRIPT.new() as CapooSniperLockVisualCoordinator
	coordinator.use_batched_arbitration = use_batched_arbitration
	fixture.add_child(coordinator)
	var target := Node2D.new()
	target.name = "LockTarget"
	fixture.add_child(target)
	for static_child_index in range(TARGET_STATIC_CHILD_COUNT):
		var static_child := Node.new()
		static_child.name = "StaticChild%d" % static_child_index
		target.add_child(static_child)

	var reticles: Array[CapooSniperLockReticle] = []
	for reticle_index in range(RETICLE_COUNT):
		var reticle := RETICLE_SCENE.instantiate() as CapooSniperLockReticle
		target.add_child(reticle)
		reticle.start(3.0, false)
		reticles.append(reticle)
	await process_frame
	var all_reticles_use_expected_path := true
	for reticle in reticles:
		if reticle.uses_coordinated_arbitration() != use_batched_arbitration:
			all_reticles_use_expected_path = false
			break
	_expect(
		all_reticles_use_expected_path,
		"A/B fixture reticles selected the wrong arbitration path."
	)

	for warmup_index in range(WARMUP_ITERATIONS):
		_drive_reticles(reticles, warmup_index)
		if use_batched_arbitration:
			coordinator.flush_pending_updates()
	coordinator.reset_metrics()

	var started_usec := Time.get_ticks_usec()
	for sample_index in range(SAMPLE_ITERATIONS):
		_drive_reticles(reticles, WARMUP_ITERATIONS + sample_index)
		if use_batched_arbitration:
			coordinator.flush_pending_updates()
	var elapsed_usec := Time.get_ticks_usec() - started_usec

	var teardown_started_usec := Time.get_ticks_usec()
	for reticle in reticles:
		if reticle != null and is_instance_valid(reticle):
			target.remove_child(reticle)
			reticle.free()
	if use_batched_arbitration:
		coordinator.flush_pending_updates()
	var teardown_usec := Time.get_ticks_usec() - teardown_started_usec
	var metrics := coordinator.get_metrics()
	metrics["elapsed_usec"] = elapsed_usec
	metrics["teardown_usec"] = teardown_usec

	current_scene = null
	fixture.queue_free()
	await process_frame
	return metrics


func _drive_reticles(reticles: Array[CapooSniperLockReticle], iteration: int) -> void:
	for reticle_index in range(reticles.size()):
		var phase := (iteration * 17 + reticle_index * 29) % 997
		reticles[reticle_index].set_progress(float(phase + 1) / 998.0)


func _test_coordinated_behavior() -> void:
	var fixture := Node2D.new()
	root.add_child(fixture)
	current_scene = fixture
	var coordinator := COORDINATOR_SCRIPT.new() as CapooSniperLockVisualCoordinator
	fixture.add_child(coordinator)
	var target_a := Node2D.new()
	var target_b := Node2D.new()
	fixture.add_child(target_a)
	fixture.add_child(target_b)

	var reticles: Array[CapooSniperLockReticle] = []
	for _index in range(3):
		var reticle := RETICLE_SCENE.instantiate() as CapooSniperLockReticle
		target_a.add_child(reticle)
		reticle.start(3.0, false)
		reticle.set_progress(0.5)
		reticles.append(reticle)
	coordinator.flush_pending_updates()
	var tie_winner := reticles[0]
	for reticle in reticles:
		if reticle.get_instance_id() > tie_winner.get_instance_id():
			tie_winner = reticle
	_expect(tie_winner.is_progress_display_active(), "Tie break must select the newest reticle.")
	_expect(_visible_reticle_count(reticles) == 1, "Only one target reticle may be visible.")

	reticles[0].set_progress(0.9)
	coordinator.flush_pending_updates()
	_expect(reticles[0].is_progress_display_active(), "Higher progress must replace the tie winner.")
	reticles[0].get_parent().remove_child(reticles[0])
	reticles[0].free()
	coordinator.flush_pending_updates()
	_expect(_visible_reticle_count(reticles) == 1, "Cancelling a winner must promote exactly one survivor.")
	var remaining_slots: Dictionary[int, bool] = {}
	for reticle in reticles:
		if reticle != null and is_instance_valid(reticle):
			remaining_slots[reticle.get_coordinator_slot_index()] = true
	_expect(
		remaining_slots.size() == 2
		and remaining_slots.has(0)
		and remaining_slots.has(1),
		"Swap-pop cancellation must repair the moved reticle slot index."
	)

	var switched_reticle := RETICLE_SCENE.instantiate() as CapooSniperLockReticle
	target_b.add_child(switched_reticle)
	switched_reticle.start(3.0, false)
	switched_reticle.set_progress(0.7)
	coordinator.flush_pending_updates()
	_expect(
		switched_reticle.is_progress_display_active(),
		"A replacement lock on another target must arbitrate independently."
	)

	var stale_reticle: CapooSniperLockReticle = null
	var slot_survivor: CapooSniperLockReticle = null
	for reticle in reticles:
		if reticle == null or not is_instance_valid(reticle):
			continue
		if reticle.get_coordinator_slot_index() == 0:
			stale_reticle = reticle
		else:
			slot_survivor = reticle
	_expect(
		stale_reticle != null and slot_survivor != null,
		"Invalid-entry cleanup fixture requires two registered target-A reticles."
	)
	if stale_reticle != null and slot_survivor != null:
		# Simulate a stale registration left under target A. Refresh must remove it
		# with swap-pop and repair the survivor slot without a linear search.
		stale_reticle.set_coordinator_slot(
			target_b.get_instance_id(),
			stale_reticle.get_coordinator_slot_index()
		)
		slot_survivor.set_progress(0.91)
		coordinator.flush_pending_updates()
		var cleanup_metrics := coordinator.get_metrics()
		_expect(
			slot_survivor.get_coordinator_slot_index() == 0
			and int(cleanup_metrics.get("invalid_cleanups", 0)) == 1
			and int(cleanup_metrics.get("repaired_bindings", 0)) == 1
			and stale_reticle.uses_coordinated_arbitration()
			and stale_reticle.get_coordinator_slot_index() == 1,
			"Invalid-entry cleanup must repair the survivor and rebind the valid stale reticle."
		)
		stale_reticle.set_progress(0.99)
		coordinator.flush_pending_updates()
		_expect(
			stale_reticle.is_progress_display_active()
			and _visible_reticle_count(reticles) == 1,
			"A repaired reticle must remain in coordinated arbitration."
		)
		slot_survivor.set_progress(1.0)
		coordinator.flush_pending_updates()
		_expect(
			slot_survivor.is_progress_display_active()
			and not stale_reticle.is_progress_display_active()
			and _visible_reticle_count(reticles) == 1,
			"Bidirectional progress updates must never mix coordinated and fallback winners."
		)

	current_scene = null
	fixture.queue_free()
	await process_frame


func _visible_reticle_count(reticles: Array[CapooSniperLockReticle]) -> int:
	var count := 0
	for reticle in reticles:
		if reticle != null and is_instance_valid(reticle) and reticle.is_progress_display_active():
			count += 1
	return count


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
