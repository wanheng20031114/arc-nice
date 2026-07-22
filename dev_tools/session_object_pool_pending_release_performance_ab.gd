extends SceneTree

# Reproduces the real pool ordering when producers earlier in the physics tree
# append the current generation before SessionObjectPool drains the previous
# generation. Every frame therefore contains a due prefix and a newer suffix.
const RELEASES_PER_FRAME := 512
const MEASURED_FRAMES := 90
const WARMUP_RUNS := 2
const MEASURED_RUNS := 7
const COMPACT_MIN_HEAD := 1024


func _init() -> void:
	for _warmup in WARMUP_RUNS:
		_run_reverse_remove_at()
		_run_head_queue()

	var old_samples: Array[int] = []
	var head_samples: Array[int] = []
	var old_digest := 0
	var head_digest := 0
	for _run_index in MEASURED_RUNS:
		var old_result := _measure(Callable(self, "_run_reverse_remove_at"))
		var head_result := _measure(Callable(self, "_run_head_queue"))
		old_samples.append(int(old_result["usec"]))
		head_samples.append(int(head_result["usec"]))
		old_digest = int(old_result["digest"])
		head_digest = int(head_result["digest"])

	old_samples.sort()
	head_samples.sort()
	var old_median := old_samples[old_samples.size() / 2]
	var head_median := head_samples[head_samples.size() / 2]
	var speedup := float(old_median) / maxf(float(head_median), 1.0)
	print(
		"SESSION_OBJECT_POOL_PENDING_RELEASE_AB old_median_us=%d head_median_us=%d speedup=%.2fx frames=%d releases_per_frame=%d digest=%d"
		% [
			old_median,
			head_median,
			speedup,
			MEASURED_FRAMES,
			RELEASES_PER_FRAME,
			old_digest,
		]
	)
	if old_digest != head_digest:
		push_error(
			"Pending-release A/B semantic digest mismatch: old=%d head=%d"
			% [old_digest, head_digest]
		)
		quit(1)
		return
	quit()


func _measure(work: Callable) -> Dictionary:
	var started := Time.get_ticks_usec()
	var digest := int(work.call())
	return {
		"usec": Time.get_ticks_usec() - started,
		"digest": digest,
	}


func _run_reverse_remove_at() -> int:
	var nodes: Array[int] = []
	var available_frames: Array[int] = []
	var keys: Array[String] = []
	var digest := 0
	_append_generation(nodes, available_frames, keys, 1)
	for current_frame in range(1, MEASURED_FRAMES + 1):
		_append_generation(nodes, available_frames, keys, current_frame + 1)
		for index in range(nodes.size() - 1, -1, -1):
			if current_frame < available_frames[index]:
				continue
			digest = (digest * 31 + nodes[index]) & 0x7fffffff
			nodes.remove_at(index)
			available_frames.remove_at(index)
			keys.remove_at(index)
	# The final generation remains quarantined, exactly as in the real pool.
	return (digest * 31 + nodes.size() * 17 + available_frames[0]) & 0x7fffffff


func _run_head_queue() -> int:
	var nodes: Array[int] = []
	var available_frames: Array[int] = []
	var keys: Array[String] = []
	var head := 0
	var digest := 0
	_append_generation(nodes, available_frames, keys, 1)
	for current_frame in range(1, MEASURED_FRAMES + 1):
		_append_generation(nodes, available_frames, keys, current_frame + 1)
		var due_end := head
		while due_end < nodes.size() and current_frame >= available_frames[due_end]:
			due_end += 1
		for index in range(due_end - 1, head - 1, -1):
			digest = (digest * 31 + nodes[index]) & 0x7fffffff
			nodes[index] = 0
			available_frames[index] = 0
			keys[index] = ""
		head = due_end
		if head == nodes.size():
			nodes.clear()
			available_frames.clear()
			keys.clear()
			head = 0
		elif head >= COMPACT_MIN_HEAD and head * 2 >= nodes.size():
			nodes = nodes.slice(head)
			available_frames = available_frames.slice(head)
			keys = keys.slice(head)
			head = 0
	return (
		(digest * 31 + (nodes.size() - head) * 17 + available_frames[head])
		& 0x7fffffff
	)


func _append_generation(
	nodes: Array[int],
	available_frames: Array[int],
	keys: Array[String],
	available_frame: int
) -> void:
	var base_id := available_frame * RELEASES_PER_FRAME
	for offset in RELEASES_PER_FRAME:
		nodes.append(base_id + offset)
		available_frames.append(available_frame)
		keys.append("res://fixture_%d.tscn" % (offset & 3))
