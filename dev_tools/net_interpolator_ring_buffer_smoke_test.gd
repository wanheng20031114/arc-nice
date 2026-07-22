extends SceneTree

const NetInterpolatorClass := preload("res://scene/multiplayer/net_interpolator.gd")

const BUFFER_CAPACITY := 18
const AB_ENTITY_COUNT := 300
const AB_STEADY_PUSH_COUNT := 900
const AB_ROUNDS := 3

var failures: Array[String] = []


class LegacyFrame:
	var timestamp: float = 0.0
	var position: Vector2 = Vector2.ZERO
	var velocity: Vector2 = Vector2.ZERO
	var facing: int = 0
	var anim_state: int = 0
	var health: int = 0
	var is_dead: bool = false


## 变更前实现的语义与热路径副本，仅作为确定性 oracle 和 A/B 基线。
class LegacyHeadDeleteInterpolator:
	var buffer: Array[LegacyFrame] = []
	var buffer_max_size: int = BUFFER_CAPACITY
	var render_delay: float = 0.1
	var max_extrapolation_seconds: float = 0.2
	var last_position: Vector2 = Vector2.ZERO
	var has_position: bool = false
	var has_cached_motion: bool = false

	func _init(
		snapshot_interval: float = 0.1,
		delay_factor: float = 1.0,
		max_extrapolation: float = 0.2
	) -> void:
		render_delay = snapshot_interval * delay_factor
		max_extrapolation_seconds = max_extrapolation

	func push_snapshot(
		timestamp: float,
		position: Vector2,
		velocity: Vector2,
		facing: int = 0,
		anim_state: int = 0,
		health: int = 0,
		is_dead: bool = false
	) -> void:
		has_cached_motion = false
		var appends_in_order := (
			buffer.is_empty()
			or timestamp > buffer[buffer.size() - 1].timestamp
		)
		var frame: LegacyFrame = null
		if appends_in_order and buffer.size() >= buffer_max_size:
			frame = buffer[0]
			buffer.remove_at(0)
		else:
			frame = LegacyFrame.new()
		frame.timestamp = timestamp
		frame.position = position
		frame.velocity = velocity
		frame.facing = facing
		frame.anim_state = anim_state
		frame.health = health
		frame.is_dead = is_dead

		if not buffer.is_empty() and timestamp <= buffer[buffer.size() - 1].timestamp:
			_insert_ordered_snapshot(frame)
		else:
			buffer.append(frame)
		last_position = position
		has_position = true

		while buffer.size() > buffer_max_size:
			buffer.remove_at(0)

	func sample(current_time: float) -> Dictionary:
		var render_time := current_time - render_delay
		if buffer.is_empty():
			return {
				"position": last_position if has_position else Vector2.ZERO,
				"velocity": Vector2.ZERO,
				"state": null,
			}
		if buffer.size() == 1:
			return _sample_from_frame(buffer[0])
		if render_time <= buffer[0].timestamp:
			return _sample_from_frame(buffer[0])

		var before: LegacyFrame = null
		var after: LegacyFrame = null
		for index in range(buffer.size() - 2, -1, -1):
			if (
				buffer[index].timestamp <= render_time
				and buffer[index + 1].timestamp >= render_time
			):
				before = buffer[index]
				after = buffer[index + 1]
				break
		if before == null or after == null:
			var latest := buffer[buffer.size() - 1]
			var extrapolation_time := clampf(
				render_time - latest.timestamp,
				0.0,
				max_extrapolation_seconds
			)
			return {
				"position": latest.position + latest.velocity * extrapolation_time,
				"velocity": latest.velocity,
				"state": latest,
			}
		var total := after.timestamp - before.timestamp
		if total <= 0.0:
			return _sample_from_frame(after)
		var weight := clampf((render_time - before.timestamp) / total, 0.0, 1.0)
		return {
			"position": before.position.lerp(after.position, weight),
			"velocity": before.velocity.lerp(after.velocity, weight),
			"state": after if render_time >= after.timestamp else before,
		}

	func clear() -> void:
		buffer.clear()
		has_position = false
		has_cached_motion = false

	func _insert_ordered_snapshot(frame: LegacyFrame) -> void:
		for index in range(buffer.size()):
			if is_equal_approx(buffer[index].timestamp, frame.timestamp):
				buffer[index] = frame
				return
			if frame.timestamp < buffer[index].timestamp:
				buffer.insert(index, frame)
				return
		buffer.append(frame)

	func _sample_from_frame(frame: LegacyFrame) -> Dictionary:
		return {
			"position": frame.position,
			"velocity": frame.velocity,
			"state": frame,
		}


func _initialize() -> void:
	_verify_ring_buffer_semantics()
	var ab_result := _run_head_delete_ab()
	print(
		"NET_INTERPOLATOR_RING_AB entities=%d steady_pushes=%d legacy_best_usec=%.1f ring_best_usec=%.1f speedup=%.2f"
		% [
			AB_ENTITY_COUNT,
			AB_STEADY_PUSH_COUNT,
			float(ab_result["legacy_usec"]),
			float(ab_result["ring_usec"]),
			float(ab_result["speedup"]),
		]
	)
	if failures.is_empty():
		print("NET_INTERPOLATOR_RING_BUFFER_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _verify_ring_buffer_semantics() -> void:
	var candidate := NetInterpolatorClass.new(0.1, 1.0, 0.2)
	var oracle := LegacyHeadDeleteInterpolator.new(0.1, 1.0, 0.2)
	_compare_all_samples(candidate, oracle, "empty")

	var events: Array[Dictionary] = []
	for sample_index in range(36):
		events.append(_make_event(float(sample_index) * 0.1, sample_index))
	# Cover in-window insertion, stale-before-head rejection, duplicate replacement,
	# another rollover, and insertion immediately behind the logical head.
	events.append(_make_event(3.15, 101))
	events.append(_make_event(1.2, 102))
	events.append(_make_event(2.25, 103))
	events.append(_make_event(3.15, 104))
	events.append(_make_event(3.6, 105))
	events.append(_make_event(1.85, 106))
	events.append(_make_event(3.7, 107))

	for event_index in range(events.size()):
		var event := events[event_index]
		_push_event(candidate, event)
		_push_legacy_event(oracle, event)
		_expect(
			candidate.get_buffer_size() == oracle.buffer.size(),
			"Logical buffer size must match the head-delete oracle after event %d." % event_index
		)
		_expect(
			is_equal_approx(
				candidate.get_latest_timestamp(),
				oracle.buffer[oracle.buffer.size() - 1].timestamp
			),
			"Latest timestamp must match the head-delete oracle after event %d." % event_index
		)
		_compare_buffer_contents(candidate, oracle, "event %d" % event_index)
		_compare_all_samples(candidate, oracle, "event %d" % event_index)

	var physical_buffer: Array = candidate.get("_buffer") as Array
	_expect(
		candidate.get_buffer_size() == BUFFER_CAPACITY
		and physical_buffer.size() == BUFFER_CAPACITY * 2,
		"The mirrored ring must retain 18 logical frames in 36 fixed reference slots."
	)
	for physical_index in range(BUFFER_CAPACITY):
		_expect(
			is_same(
				physical_buffer[physical_index],
				physical_buffer[physical_index + BUFFER_CAPACITY]
			),
			"Both physical halves must reference the same frame at slot %d."
			% physical_index
		)

	candidate.clear()
	oracle.clear()
	_compare_all_samples(candidate, oracle, "clear")
	_expect(
		candidate.get_buffer_size() == 0
		and (candidate.get("_buffer") as Array).is_empty(),
		"Clear must release physical frame references and reset the logical head."
	)
	for sample_index in range(25):
		var restarted_event := _make_event(10.0 + float(sample_index) * 0.05, 200 + sample_index)
		_push_event(candidate, restarted_event)
		_push_legacy_event(oracle, restarted_event)
	_compare_buffer_contents(candidate, oracle, "refill after clear")
	_compare_all_samples(candidate, oracle, "refill after clear")


func _compare_buffer_contents(
	candidate: NetInterpolator,
	oracle: LegacyHeadDeleteInterpolator,
	context: String
) -> void:
	for logical_index in range(oracle.buffer.size()):
		var actual := candidate.call("_get_buffer_frame", logical_index) as NetInterpolator.FrameSnapshot
		_expect(
			actual != null
			and _state_values_match(actual, oracle.buffer[logical_index]),
			"Logical frame %d must match the ordered oracle (%s)."
			% [logical_index, context]
		)


func _compare_all_samples(
	candidate: NetInterpolator,
	oracle: LegacyHeadDeleteInterpolator,
	context: String
) -> void:
	var sample_times := PackedFloat64Array([
		-1.0,
		0.0,
		1.85,
		2.25,
		3.15,
		3.55,
		4.0,
		10.0,
		11.25,
		20.0,
	])
	for current_time in sample_times:
		var expected := oracle.sample(current_time)
		var actual_position := candidate.get_interpolated_position(current_time)
		var actual_velocity := candidate.get_interpolated_velocity(current_time)
		var actual_state := candidate.get_current_state(current_time)
		_expect(
			actual_position.distance_to(expected["position"] as Vector2) <= 0.0001,
			"Interpolated position must match oracle at %.2f (%s)." % [current_time, context]
		)
		_expect(
			actual_velocity.distance_to(expected["velocity"] as Vector2) <= 0.0001,
			"Interpolated velocity must match oracle at %.2f (%s)." % [current_time, context]
		)
		var expected_state: Variant = expected["state"]
		if expected_state == null:
			_expect(
				actual_state.timestamp == 0.0
				and actual_state.position == Vector2.ZERO
				and actual_state.velocity == Vector2.ZERO,
				"Empty discrete state must remain reset (%s)." % context
			)
		else:
			_expect(
				_state_values_match(actual_state, expected_state as LegacyFrame),
				"Discrete state must match oracle at %.2f (%s)." % [current_time, context]
			)


func _state_values_match(actual: NetInterpolator.FrameSnapshot, expected: LegacyFrame) -> bool:
	return (
		is_equal_approx(actual.timestamp, expected.timestamp)
		and actual.position.is_equal_approx(expected.position)
		and actual.velocity.is_equal_approx(expected.velocity)
		and actual.facing == expected.facing
		and actual.anim_state == expected.anim_state
		and actual.health == expected.health
		and actual.is_dead == expected.is_dead
	)


func _run_head_delete_ab() -> Dictionary:
	# Warm both implementations until they are in the steady full-buffer state.
	_measure_ring_pushes(20)
	_measure_legacy_pushes(20)
	var ring_samples: Array[float] = []
	var legacy_samples: Array[float] = []
	for round_index in range(AB_ROUNDS):
		if round_index % 2 == 0:
			legacy_samples.append(_measure_legacy_pushes(AB_STEADY_PUSH_COUNT))
			ring_samples.append(_measure_ring_pushes(AB_STEADY_PUSH_COUNT))
		else:
			ring_samples.append(_measure_ring_pushes(AB_STEADY_PUSH_COUNT))
			legacy_samples.append(_measure_legacy_pushes(AB_STEADY_PUSH_COUNT))
	# Use the least interrupted sample for this microbenchmark. Correctness and
	# fixed-size O(1) structure are hard assertions above; wall-clock ratios stay
	# informational because unrelated editor/CI scheduling can skew either arm.
	var legacy_best := float(legacy_samples.min())
	var ring_best := float(ring_samples.min())
	return {
		"legacy_usec": legacy_best,
		"ring_usec": ring_best,
		"speedup": legacy_best / maxf(ring_best, 1.0),
	}


func _measure_ring_pushes(push_count: int) -> float:
	var interpolators: Array[NetInterpolator] = []
	for _entity_index in range(AB_ENTITY_COUNT):
		var interpolator := NetInterpolatorClass.new(0.05, 1.0, 0.2)
		for prefill_index in range(BUFFER_CAPACITY):
			interpolator.push_snapshot(
				float(prefill_index) * 0.05,
				Vector2(float(prefill_index), 1.0),
				Vector2(20.0, 0.0),
				prefill_index & 1,
				prefill_index % 3,
				100 - prefill_index,
				false
			)
		interpolators.append(interpolator)
	var started_usec := Time.get_ticks_usec()
	for push_index in range(push_count):
		var timestamp := 1.0 + float(push_index) * 0.05
		for interpolator in interpolators:
			interpolator.push_snapshot(
				timestamp,
				Vector2(timestamp * 20.0, 1.0),
				Vector2(20.0, 0.0),
				push_index & 1,
				push_index % 3,
				80,
				false
			)
	var elapsed_usec := float(Time.get_ticks_usec() - started_usec)
	_expect(
		interpolators[AB_ENTITY_COUNT - 1].get_buffer_size() == BUFFER_CAPACITY,
		"Ring A/B fixture must retain the configured capacity."
	)
	return elapsed_usec


func _measure_legacy_pushes(push_count: int) -> float:
	var interpolators: Array[LegacyHeadDeleteInterpolator] = []
	for _entity_index in range(AB_ENTITY_COUNT):
		var interpolator := LegacyHeadDeleteInterpolator.new(0.05, 1.0, 0.2)
		for prefill_index in range(BUFFER_CAPACITY):
			interpolator.push_snapshot(
				float(prefill_index) * 0.05,
				Vector2(float(prefill_index), 1.0),
				Vector2(20.0, 0.0),
				prefill_index & 1,
				prefill_index % 3,
				100 - prefill_index,
				false
			)
		interpolators.append(interpolator)
	var started_usec := Time.get_ticks_usec()
	for push_index in range(push_count):
		var timestamp := 1.0 + float(push_index) * 0.05
		for interpolator in interpolators:
			interpolator.push_snapshot(
				timestamp,
				Vector2(timestamp * 20.0, 1.0),
				Vector2(20.0, 0.0),
				push_index & 1,
				push_index % 3,
				80,
				false
			)
	var elapsed_usec := float(Time.get_ticks_usec() - started_usec)
	_expect(
		interpolators[AB_ENTITY_COUNT - 1].buffer.size() == BUFFER_CAPACITY,
		"Legacy A/B fixture must retain the configured capacity."
	)
	return elapsed_usec


func _make_event(timestamp: float, seed: int) -> Dictionary:
	return {
		"timestamp": timestamp,
		"position": Vector2(timestamp * 13.0 + float(seed % 5), float(seed % 7)),
		"velocity": Vector2(float(seed % 11) - 5.0, float(seed % 3)),
		"facing": seed & 1,
		"anim_state": seed % 4,
		"health": 200 - seed,
		"is_dead": seed % 13 == 0,
	}


func _push_event(candidate: NetInterpolator, event: Dictionary) -> void:
	candidate.push_snapshot(
		float(event["timestamp"]),
		event["position"] as Vector2,
		event["velocity"] as Vector2,
		int(event["facing"]),
		int(event["anim_state"]),
		int(event["health"]),
		bool(event["is_dead"])
	)


func _push_legacy_event(oracle: LegacyHeadDeleteInterpolator, event: Dictionary) -> void:
	oracle.push_snapshot(
		float(event["timestamp"]),
		event["position"] as Vector2,
		event["velocity"] as Vector2,
		int(event["facing"]),
		int(event["anim_state"]),
		int(event["health"]),
		bool(event["is_dead"])
	)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
