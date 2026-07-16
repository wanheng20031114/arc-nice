extends SceneTree

const TARGET_COUNT := 1000
const INVALID_REF_COUNT := 64
const SOURCE_A := -920001
const SOURCE_B := -920002
const SOURCE_INVALID := -920003
const SOURCE_HEAVY_A := -920004
const SOURCE_HEAVY_B := -920005
const SOURCE_HEAVY_INVALID := -920006
const SOURCE_HARD_CAP := -920007
const HEAVY_LIVE_TARGETS_PER_SOURCE := 7
const HEAVY_INVALID_REF_COUNT := 8
const HEAVY_CALLBACK_USEC := 250
const HARD_CAP_JOB_COUNT := 19
const HARD_CAP_TARGETS_PER_JOB := 7


class ProbeTarget extends RefCounted:
	var sources: Dictionary = {}


var failures: Array[String] = []
var removed_by_source := {
	SOURCE_A: 0,
	SOURCE_B: 0,
	SOURCE_INVALID: 0,
}
var heavy_callbacks_by_source := {
	SOURCE_HEAVY_A: 0,
	SOURCE_HEAVY_B: 0,
	SOURCE_HEAVY_INVALID: 0,
}
var heavy_removals_by_source := {
	SOURCE_HEAVY_A: 0,
	SOURCE_HEAVY_B: 0,
}
var hard_cap_callback_count := 0


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var scheduler := root.get_node("StatusEffectExpiryScheduler")
	scheduler.call("set_metrics_enabled", true)
	_expect(
		int(scheduler.call("get_pending_job_count")) == 0,
		"The shared expiry scheduler must start without stale jobs."
	)

	var targets: Array[ProbeTarget] = []
	var source_a_refs: Array[WeakRef] = []
	var source_b_refs: Array[WeakRef] = []
	for _target_index in range(TARGET_COUNT):
		var target := ProbeTarget.new()
		target.sources[SOURCE_A] = true
		target.sources[SOURCE_B] = true
		targets.append(target)
		source_a_refs.append(weakref(target))
		source_b_refs.append(weakref(target))

	var invalid_refs: Array[WeakRef] = []
	for _invalid_index in range(INVALID_REF_COUNT):
		var temporary_target := ProbeTarget.new()
		temporary_target.sources[SOURCE_INVALID] = true
		invalid_refs.append(weakref(temporary_target))
	# Drop the last strong loop-local reference too. Visiting dead enemies must be
	# safe and must still consume the same bounded scheduler work unit.
	var temporary_target: ProbeTarget = null

	var remover := Callable(self, "_remove_probe_source")
	scheduler.call("enqueue_weak_ref_batch", source_a_refs, SOURCE_A, remover)
	scheduler.call("enqueue_weak_ref_batch", source_b_refs, SOURCE_B, remover)
	scheduler.call("enqueue_weak_ref_batch", invalid_refs, SOURCE_INVALID, remover)
	var total_refs := TARGET_COUNT * 2 + INVALID_REF_COUNT
	_expect(
		int(scheduler.call("get_pending_target_count")) == total_refs,
		"All simultaneously expired source/target pairs must enter one shared backlog."
	)

	var observed_drain_frames := 0
	var last_a_progress_frame := 0
	var last_b_progress_frame := 0
	var previous_a_removed := 0
	var previous_b_removed := 0
	var deadline_usec := Time.get_ticks_usec() + 3_000_000
	while (
		int(scheduler.call("get_pending_target_count")) > 0
		and Time.get_ticks_usec() < deadline_usec
	):
		# process_frame is emitted before Node._process. The second signal observes
		# the scheduler work performed during the preceding render frame.
		await process_frame
		var metrics := scheduler.call("get_metrics") as Dictionary
		var drain_frames := int(metrics.get("drain_frames", 0))
		if drain_frames <= observed_drain_frames:
			continue
		observed_drain_frames = drain_frames
		var a_removed := int(removed_by_source[SOURCE_A])
		var b_removed := int(removed_by_source[SOURCE_B])
		if a_removed > previous_a_removed:
			last_a_progress_frame = drain_frames
		if b_removed > previous_b_removed:
			last_b_progress_frame = drain_frames
		previous_a_removed = a_removed
		previous_b_removed = b_removed
		if drain_frames >= 3 and a_removed < TARGET_COUNT:
			_expect(
				drain_frames - last_a_progress_frame <= 3,
				"Source A must not be starved behind another expired cohort."
			)
		if drain_frames >= 3 and b_removed < TARGET_COUNT:
			_expect(
				drain_frames - last_b_progress_frame <= 3,
				"Source B must not be starved behind another expired cohort."
			)

	var final_metrics := scheduler.call("get_metrics") as Dictionary
	_expect(
		int(scheduler.call("get_pending_target_count")) == 0,
		"The shared scheduler must eventually drain the complete backlog."
	)
	_expect(
		not scheduler.is_processing(),
		"The one shared scheduler must leave the render process list when idle."
	)
	_expect(
		int(final_metrics.get("completed_jobs", -1)) == 3,
		"All three independent jobs, including dead WeakRefs, must complete once."
	)
	_expect(
		int(removed_by_source[SOURCE_A]) == TARGET_COUNT
		and int(removed_by_source[SOURCE_B]) == TARGET_COUNT,
		"Both independent source IDs must be removed from all 1000 live targets."
	)
	for target in targets:
		_expect(
			target.sources.is_empty(),
			"A target must keep neither source after both expiry jobs complete."
		)
	_expect(
		int(final_metrics.get("visited_targets", -1)) == total_refs,
		"Dead WeakRefs must be visited safely without preventing job completion: %s."
		% [final_metrics]
	)
	_expect(
		int(final_metrics.get("max_targets_per_frame", 0))
		<= int(scheduler.MAX_TARGETS_PER_FRAME),
		"No expiry frame may exceed the global target-count budget: %s."
		% [final_metrics]
	)
	var minimum_drain_frames := ceili(
		float(total_refs) / float(scheduler.MAX_TARGETS_PER_FRAME)
	)
	var conservative_max_drain_frames := ceili(
		float(total_refs) / float(scheduler.TIME_CHECK_INTERVAL_TARGETS)
	)
	_expect(
		int(final_metrics.get("drain_frames", 0)) >= minimum_drain_frames
		and int(final_metrics.get("drain_frames", 0)) <= conservative_max_drain_frames,
		"Drain frames must respect both the per-frame maximum and the exposed minimum-throughput bound: %s."
		% [final_metrics]
	)
	_expect(
		int(final_metrics.get("max_estimated_drain_frames", -1))
		== conservative_max_drain_frames,
		"The scheduler must expose a conservative backlog-delay bound: %s."
		% [final_metrics]
	)
	_expect(
		int(final_metrics.get("max_frame_usec", 0)) <= 5000,
		"A 1000-target/two-source expiry frame must stay below the 5ms smoke-test ceiling: %s."
		% [final_metrics]
	)

	print(
		"STATUS_EFFECT_EXPIRY_SCHEDULER_METRICS targets=%d drain_frames=%d max_targets=%d max_usec=%d"
		% [
			total_refs,
			int(final_metrics.get("drain_frames", -1)),
			int(final_metrics.get("max_targets_per_frame", -1)),
			int(final_metrics.get("max_frame_usec", -1)),
		]
	)
	await _test_exact_global_target_cap(scheduler)
	await _test_expensive_callback_budget(scheduler)
	scheduler.call("set_metrics_enabled", false)
	if failures.is_empty():
		print("STATUS_EFFECT_EXPIRY_SCHEDULER_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _remove_probe_source(target_ref: WeakRef, source_id: int) -> void:
	var target: ProbeTarget = null
	if target_ref != null:
		target = target_ref.get_ref() as ProbeTarget
	if target == null or not target.sources.has(source_id):
		return
	target.sources.erase(source_id)
	removed_by_source[source_id] = int(removed_by_source[source_id]) + 1


func _test_exact_global_target_cap(scheduler: Node) -> void:
	scheduler.call("reset_metrics")
	hard_cap_callback_count = 0
	var targets: Array[ProbeTarget] = []
	for _job_index in range(HARD_CAP_JOB_COUNT):
		var refs: Array[WeakRef] = []
		for _target_index in range(HARD_CAP_TARGETS_PER_JOB):
			var target := ProbeTarget.new()
			targets.append(target)
			refs.append(weakref(target))
		scheduler.call(
			"enqueue_weak_ref_batch",
			refs,
			SOURCE_HARD_CAP,
			Callable(self, "_count_hard_cap_callback")
		)
		refs.clear()
	var total_targets := HARD_CAP_JOB_COUNT * HARD_CAP_TARGETS_PER_JOB
	var deadline_usec := Time.get_ticks_usec() + 1_000_000
	while (
		int(scheduler.call("get_pending_target_count")) > 0
		and Time.get_ticks_usec() < deadline_usec
	):
		await process_frame
	var metrics := scheduler.call("get_metrics") as Dictionary
	_expect(
		hard_cap_callback_count == total_targets
		and int(metrics.get("visited_targets", -1)) == total_targets,
		"Odd-sized jobs must all drain through the exact global target cap."
	)
	_expect(
		int(metrics.get("max_targets_per_frame", -1)) == 128
		and int(metrics.get("drain_frames", 0)) >= 2,
		(
			"Nineteen seven-target jobs must stop exactly at 128, not overshoot "
			+ "to the next complete quantum: %s."
		) % [metrics]
	)


func _count_hard_cap_callback(_target_ref: WeakRef, _source_id: int) -> void:
	hard_cap_callback_count += 1


func _test_expensive_callback_budget(scheduler: Node) -> void:
	# Seven callbacks deliberately exceed the 1.5 ms frame budget. Using an odd
	# tail proves that the scheduler checks after every job quantum: it must not
	# enter the next seven-target job and create a hidden 14-callback burst.
	scheduler.call("reset_metrics")
	for source_id in heavy_callbacks_by_source:
		heavy_callbacks_by_source[source_id] = 0
	for source_id in heavy_removals_by_source:
		heavy_removals_by_source[source_id] = 0

	var targets_a: Array[ProbeTarget] = []
	var targets_b: Array[ProbeTarget] = []
	var refs_a: Array[WeakRef] = []
	var refs_b: Array[WeakRef] = []
	for _target_index in range(HEAVY_LIVE_TARGETS_PER_SOURCE):
		var target_a := ProbeTarget.new()
		target_a.sources[SOURCE_HEAVY_A] = true
		targets_a.append(target_a)
		refs_a.append(weakref(target_a))
		var target_b := ProbeTarget.new()
		target_b.sources[SOURCE_HEAVY_B] = true
		targets_b.append(target_b)
		refs_b.append(weakref(target_b))

	var invalid_refs: Array[WeakRef] = []
	for _invalid_index in range(HEAVY_INVALID_REF_COUNT):
		var temporary_target := ProbeTarget.new()
		temporary_target.sources[SOURCE_HEAVY_INVALID] = true
		invalid_refs.append(weakref(temporary_target))
	var temporary_target: ProbeTarget = null

	var remover := Callable(self, "_remove_expensive_probe_source")
	scheduler.call("enqueue_weak_ref_batch", refs_a, SOURCE_HEAVY_A, remover)
	scheduler.call("enqueue_weak_ref_batch", refs_b, SOURCE_HEAVY_B, remover)
	scheduler.call(
		"enqueue_weak_ref_batch",
		invalid_refs,
		SOURCE_HEAVY_INVALID,
		remover
	)
	# The scheduler owns a snapshot rather than borrowing caller arrays.
	refs_a.clear()
	refs_b.clear()
	invalid_refs.clear()

	var first_progress_frame := {
		SOURCE_HEAVY_A: 0,
		SOURCE_HEAVY_B: 0,
		SOURCE_HEAVY_INVALID: 0,
	}
	var observed_drain_frames := 0
	var deadline_usec := Time.get_ticks_usec() + 1_000_000
	while (
		int(scheduler.call("get_pending_target_count")) > 0
		and Time.get_ticks_usec() < deadline_usec
	):
		await process_frame
		var metrics := scheduler.call("get_metrics") as Dictionary
		observed_drain_frames = int(metrics.get("drain_frames", 0))
		for source_id in first_progress_frame:
			if (
				int(first_progress_frame[source_id]) == 0
				and int(heavy_callbacks_by_source[source_id]) > 0
			):
				first_progress_frame[source_id] = observed_drain_frames

	var final_metrics := scheduler.call("get_metrics") as Dictionary
	var total_callbacks := (
		HEAVY_LIVE_TARGETS_PER_SOURCE * 2 + HEAVY_INVALID_REF_COUNT
	)
	_expect(
		int(scheduler.call("get_pending_target_count")) == 0,
		"Expensive expiry callbacks must still drain their complete backlog."
	)
	_expect(
		int(final_metrics.get("visited_targets", -1)) == total_callbacks,
		"Every expensive live/dead WeakRef callback must consume one work unit: %s."
		% [final_metrics]
	)
	_expect(
		int(final_metrics.get("max_targets_per_frame", 0))
		<= int(scheduler.JOB_QUANTUM_TARGETS),
		(
			"Once a short 7-callback tail exhausts the clock budget, the scheduler "
			+ "must yield instead of entering the retired 64-callback burst: %s."
		)
		% [final_metrics]
	)
	_expect(
		int(first_progress_frame[SOURCE_HEAVY_A]) in range(1, 4)
		and int(first_progress_frame[SOURCE_HEAVY_B]) in range(1, 4)
		and int(first_progress_frame[SOURCE_HEAVY_INVALID]) in range(1, 4),
		"Round-robin scheduling must start every expensive cohort within three frames: %s."
		% [first_progress_frame]
	)
	_expect(
		int(heavy_removals_by_source[SOURCE_HEAVY_A])
		== HEAVY_LIVE_TARGETS_PER_SOURCE
		and int(heavy_removals_by_source[SOURCE_HEAVY_B])
		== HEAVY_LIVE_TARGETS_PER_SOURCE,
		"Both expensive live cohorts must remove every source exactly once."
	)
	_expect(
		int(heavy_callbacks_by_source[SOURCE_HEAVY_INVALID])
		== HEAVY_INVALID_REF_COUNT,
		"Dead WeakRefs must remain safe under the expensive-callback budget path."
	)
	_expect(
		int(final_metrics.get("max_frame_usec", 0)) <= 6000,
		"One synthetic 250us callback quantum must not recreate a multi-frame hitch: %s."
		% [final_metrics]
	)
	_expect(
		not scheduler.is_processing(),
		"The scheduler must return to idle after the expensive callback cohort."
	)
	print(
		"STATUS_EFFECT_EXPIRY_HEAVY_METRICS targets=%d drain_frames=%d max_targets=%d max_usec=%d first_progress=%s"
		% [
			total_callbacks,
			int(final_metrics.get("drain_frames", -1)),
			int(final_metrics.get("max_targets_per_frame", -1)),
			int(final_metrics.get("max_frame_usec", -1)),
			str(first_progress_frame),
		]
	)


func _remove_expensive_probe_source(target_ref: WeakRef, source_id: int) -> void:
	heavy_callbacks_by_source[source_id] = (
		int(heavy_callbacks_by_source[source_id]) + 1
	)
	var busy_until_usec := Time.get_ticks_usec() + HEAVY_CALLBACK_USEC
	while Time.get_ticks_usec() < busy_until_usec:
		pass
	var target: ProbeTarget = null
	if target_ref != null:
		target = target_ref.get_ref() as ProbeTarget
	if target == null or not target.sources.has(source_id):
		return
	target.sources.erase(source_id)
	heavy_removals_by_source[source_id] = (
		int(heavy_removals_by_source[source_id]) + 1
	)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
