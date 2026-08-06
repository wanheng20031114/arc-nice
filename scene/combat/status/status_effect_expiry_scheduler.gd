extends Node

# Expiry timers enqueue whole cohorts here in O(1). The scheduler then removes
# modifiers under one shared render-frame budget, so multiple players or
# collectible procs cannot each create an independent same-frame cleanup spike.
const MAX_TARGETS_PER_FRAME := 128
const FRAME_BUDGET_USEC := 1500
# Check the clock after each small fair-share quantum. One unexpectedly costly
# remove callback can overshoot by at most the rest of this 8-target quantum;
# there is no unconditional 64-callback burst that can recreate the expiry peak.
const JOB_QUANTUM_TARGETS := 8
const TIME_CHECK_INTERVAL_TARGETS := JOB_QUANTUM_TARGETS


class ExpiryJob:
	var enemy_refs: Array[WeakRef] = []
	var source_id := 0
	var remove_callable := Callable()
	var cursor := 0
	var enqueued_process_frame := 0


var _jobs: Array[ExpiryJob] = []
var _next_job_index := 0
var _metrics_enabled := false
var _metrics := {
	"enqueued_jobs": 0,
	"enqueued_targets": 0,
	"drain_frames": 0,
	"completed_jobs": 0,
	"visited_targets": 0,
	"max_targets_per_frame": 0,
	"max_frame_usec": 0,
	"max_backlog_targets": 0,
	"max_estimated_drain_frames": 0,
	"max_job_completion_frames": 0,
}
var _pending_target_count := 0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_process(false)


func enqueue_weak_ref_batch(
	enemy_refs: Array[WeakRef],
	source_id: int,
	remove_callable: Callable
) -> void:
	if enemy_refs.is_empty() or not remove_callable.is_valid():
		return
	var job := ExpiryJob.new()
	# Own the queue snapshot. Callers may safely reuse or clear their temporary
	# array after enqueue without corrupting pending-count accounting.
	job.enemy_refs.assign(enemy_refs)
	job.source_id = source_id
	job.remove_callable = remove_callable
	job.enqueued_process_frame = Engine.get_process_frames()
	_jobs.append(job)
	_pending_target_count += job.enemy_refs.size()
	if _metrics_enabled:
		_metrics["enqueued_jobs"] = int(_metrics["enqueued_jobs"]) + 1
		_metrics["enqueued_targets"] = (
			int(_metrics["enqueued_targets"]) + job.enemy_refs.size()
		)
		_metrics["max_backlog_targets"] = maxi(
			int(_metrics["max_backlog_targets"]),
			_pending_target_count
		)
		# The scheduler always completes one small quantum before consulting the
		# time budget. With no newly arriving work, this is a conservative
		# render-frame bound even when odd job tails stop each frame at fewer than
		# eight targets.
		_metrics["max_estimated_drain_frames"] = maxi(
			int(_metrics["max_estimated_drain_frames"]),
			_get_pending_quantum_count()
		)
	set_process(true)


func _process(_delta: float) -> void:
	if _jobs.is_empty():
		set_process(false)
		return
	var frame_started_usec := Time.get_ticks_usec()
	var visited_this_frame := 0

	while not _jobs.is_empty():
		if visited_this_frame >= MAX_TARGETS_PER_FRAME:
			break
		# Rotate one small quantum at a time. A large earlier cohort cannot keep
		# another source that expired in the same window from making progress.
		if _next_job_index >= _jobs.size():
			_next_job_index = 0
		var job: ExpiryJob = _jobs[_next_job_index]
		var quantum_end := mini(
			mini(
				job.cursor + JOB_QUANTUM_TARGETS,
				job.enemy_refs.size()
			),
			job.cursor + MAX_TARGETS_PER_FRAME - visited_this_frame
		)
		while job.cursor < quantum_end:
			var enemy_ref: WeakRef = job.enemy_refs[job.cursor]
			job.cursor += 1
			visited_this_frame += 1
			_pending_target_count -= 1
			job.remove_callable.call(enemy_ref, job.source_id)

		if job.cursor >= job.enemy_refs.size():
			_jobs.remove_at(_next_job_index)
			if _next_job_index >= _jobs.size():
				_next_job_index = 0
			if _metrics_enabled:
				_metrics["completed_jobs"] = int(_metrics["completed_jobs"]) + 1
				_metrics["max_job_completion_frames"] = maxi(
					int(_metrics["max_job_completion_frames"]),
					Engine.get_process_frames() - job.enqueued_process_frame + 1
				)
		else:
			_next_job_index = (_next_job_index + 1) % _jobs.size()

		if (
			visited_this_frame >= MAX_TARGETS_PER_FRAME
			or Time.get_ticks_usec() - frame_started_usec >= FRAME_BUDGET_USEC
		):
			break

	var frame_usec := Time.get_ticks_usec() - frame_started_usec
	if _metrics_enabled:
		_metrics["drain_frames"] = int(_metrics["drain_frames"]) + 1
		_metrics["visited_targets"] = (
			int(_metrics["visited_targets"]) + visited_this_frame
		)
		_metrics["max_targets_per_frame"] = maxi(
			int(_metrics["max_targets_per_frame"]),
			visited_this_frame
		)
		_metrics["max_frame_usec"] = maxi(
			int(_metrics["max_frame_usec"]),
			frame_usec
		)
	if _jobs.is_empty():
		set_process(false)


func set_metrics_enabled(enabled: bool) -> void:
	_metrics_enabled = enabled
	reset_metrics()


func reset_metrics() -> void:
	for metric_key in _metrics:
		_metrics[metric_key] = 0


func get_metrics(reset_after_read: bool = false) -> Dictionary:
	var snapshot := _metrics.duplicate()
	if reset_after_read:
		reset_metrics()
	return snapshot


func get_pending_job_count() -> int:
	return _jobs.size()


func get_pending_target_count() -> int:
	return _pending_target_count


func _get_pending_quantum_count() -> int:
	var quantum_count := 0
	for job in _jobs:
		var remaining_targets := maxi(job.enemy_refs.size() - job.cursor, 0)
		quantum_count += ceili(
			float(remaining_targets) / float(JOB_QUANTUM_TARGETS)
		)
	return quantum_count
