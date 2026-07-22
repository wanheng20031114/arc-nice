extends SceneTree

const TARGET_COUNT := 48
const RANDOM_OPERATION_COUNT := 600
const RANDOM_SEED := 0xC01D_5A7A
const EXPIRY_EPSILON := 0.000001
const MULTIPLIERS := [0.75, 0.60, 0.35, 0.10]


class CallbackSink:
	extends RefCounted

	var events: Array[String] = []

	func receive_state(
		stack_count: int,
		multiplier: float,
		target_index: int
	) -> void:
		events.append(
			"%d|%d|%.6f" % [target_index, stack_count, multiplier]
		)


class OracleState:
	extends RefCounted

	var target_index := -1
	var stack_count := 0
	var expires_at := 0.0
	var cohort_order := 0
	var expiry_update_queued := false


class ReentrantExpirySink:
	extends RefCounted

	var scheduler: Node = null
	var reapply_target: Enemy = null
	var reapply_callback := Callable()
	var did_reapply := false
	var events: Array[String] = []

	func receive_source(stack_count: int, _multiplier: float) -> void:
		events.append("source:%d" % stack_count)
		if stack_count != 0 or did_reapply:
			return
		did_reapply = true
		scheduler.call("apply_cold", reapply_target, reapply_callback)

	func receive_reapplied(stack_count: int, _multiplier: float) -> void:
		events.append("reapplied:%d" % stack_count)

	func receive_tail(stack_count: int, _multiplier: float) -> void:
		events.append("tail:%d" % stack_count)


class HitchReentrantSink:
	extends RefCounted

	var scheduler: Node = null
	var reapply_target: Enemy = null
	var reapply_callback := Callable()
	var source_reapplied := false
	var target_reapplied_itself := false
	var events: Array[String] = []

	func receive_source(stack_count: int, _multiplier: float) -> void:
		events.append("source:%d" % stack_count)
		if stack_count == 0 and not source_reapplied:
			source_reapplied = true
			scheduler.call("apply_cold", reapply_target, reapply_callback)

	func receive_target(stack_count: int, _multiplier: float) -> void:
		events.append("target:%d" % stack_count)
		if stack_count == 0 and not target_reapplied_itself:
			target_reapplied_itself = true
			scheduler.call("apply_cold", reapply_target, reapply_callback)


class ClearAllReentrantSink:
	extends RefCounted

	var scheduler: Node = null
	var target: Enemy = null
	var callback := Callable()
	var did_reapply := false
	var events: Array[int] = []

	func receive_state(stack_count: int, _multiplier: float) -> void:
		events.append(stack_count)
		if stack_count != 0 or did_reapply:
			return
		did_reapply = true
		scheduler.call("apply_cold", target, callback)


var failures: Array[String] = []
var scheduler: Node = null
var targets: Array[Enemy] = []
var callbacks: Array[Callable] = []
var oracle_states: Array[OracleState] = []
var oracle_expiry_update_queue: Array[OracleState] = []
var oracle_events: Array[String] = []
var callback_sink := CallbackSink.new()
var oracle_clock := 0.0
var next_cohort_order := 0


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	scheduler = root.get_node("ColdStatusScheduler")
	scheduler.call("clear_all")
	scheduler.set_physics_process(false)
	_make_targets()

	_run_randomized_oracle()
	_drain_oracle()
	_test_reentrant_expiry_reapplication()
	_test_hitch_reentrant_expired_application()
	_test_clear_all_reentrant_reapplication()
	_test_expiry_bucket_pool_bound()
	_test_freed_target_cleanup()

	scheduler.call("clear_all")
	scheduler.set_physics_process(false)
	_free_targets()
	await process_frame

	if failures.is_empty():
		print(
			"COLD_STATUS_SCHEDULER_SEMANTIC_ORACLE_OK "
			+ "operations=%d events=%d"
			% [RANDOM_OPERATION_COUNT, callback_sink.events.size()]
		)
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _make_targets() -> void:
	targets.resize(TARGET_COUNT)
	callbacks.resize(TARGET_COUNT)
	oracle_states.resize(TARGET_COUNT)
	for target_index in range(TARGET_COUNT):
		targets[target_index] = Enemy.new()
		callbacks[target_index] = Callable(
			callback_sink,
			"receive_state"
		).bind(target_index)


func _run_randomized_oracle() -> void:
	var random := RandomNumberGenerator.new()
	random.seed = RANDOM_SEED
	for operation_index in range(RANDOM_OPERATION_COUNT):
		var operation_roll := random.randi_range(0, 99)
		if operation_roll < 58:
			var target_index := random.randi_range(0, TARGET_COUNT - 1)
			_oracle_apply(target_index)
			_expect(
				bool(scheduler.call(
					"apply_cold",
					targets[target_index],
					callbacks[target_index]
				)),
				"Operation %d rejected a valid target."
				% operation_index
			)
		elif operation_roll < 73:
			var target_index := random.randi_range(0, TARGET_COUNT - 1)
			var expected_clear := _oracle_clear(target_index)
			var actual_clear := bool(scheduler.call(
				"clear_target",
				targets[target_index]
			))
			_expect(
				actual_clear == expected_clear,
				"Operation %d clear result diverged for target %d."
				% [operation_index, target_index]
			)
		else:
			var delta := _choose_advance_delta(random, operation_index)
			_oracle_advance(delta)
			scheduler.call("_advance_active_colds", delta)

		_compare_event_stream(operation_index)
		_compare_runtime_state(operation_index, random)


func _choose_advance_delta(
	random: RandomNumberGenerator,
	operation_index: int
) -> float:
	if operation_index % 19 == 0:
		var next_expiry := _find_next_oracle_expiry()
		if is_finite(next_expiry):
			# Land exactly on a deadline often enough to make the <= boundary an
			# oracle invariant rather than an incidental smoke-test case.
			return maxf(next_expiry - oracle_clock, 0.0)
	var deltas := [0.0, 1.0 / 60.0, 0.125, 0.25, 0.5, 1.0, 2.0]
	return float(deltas[random.randi_range(0, deltas.size() - 1)])


func _oracle_apply(target_index: int) -> void:
	var state := oracle_states[target_index]
	if (
		state != null
		and state.expires_at <= oracle_clock + EXPIRY_EPSILON
	):
		_oracle_publish(target_index, 0, 1.0)
		state.expiry_update_queued = false
		oracle_states[target_index] = null
		state = null
	if state == null:
		state = OracleState.new()
		state.target_index = target_index
		state.stack_count = 1
		state.expires_at = oracle_clock + 3.0
		state.cohort_order = _claim_cohort_order()
		oracle_states[target_index] = state
	else:
		state.stack_count = mini(state.stack_count + 1, 4)
		state.expires_at += 1.0
		if not state.expiry_update_queued:
			state.expiry_update_queued = true
			oracle_expiry_update_queue.append(state)
	_oracle_publish(
		target_index,
		state.stack_count,
		float(MULTIPLIERS[state.stack_count - 1])
	)


func _oracle_clear(target_index: int) -> bool:
	var state := oracle_states[target_index]
	if state == null:
		return false
	state.expiry_update_queued = false
	oracle_states[target_index] = null
	_oracle_publish(target_index, 0, 1.0)
	return true


func _oracle_advance(delta: float) -> void:
	oracle_clock += maxf(delta, 0.0)
	_oracle_flush_expiry_updates()
	var due_states: Array[OracleState] = []
	for state in oracle_states:
		if (
			state != null
			and state.expires_at <= oracle_clock + EXPIRY_EPSILON
		):
			due_states.append(state)
	due_states.sort_custom(_oracle_state_is_earlier)
	for state in due_states:
		if oracle_states[state.target_index] != state:
			continue
		oracle_states[state.target_index] = null
		_oracle_publish(state.target_index, 0, 1.0)


func _oracle_flush_expiry_updates() -> void:
	for state in oracle_expiry_update_queue:
		if not state.expiry_update_queued:
			continue
		state.expiry_update_queued = false
		if oracle_states[state.target_index] != state:
			continue
		state.cohort_order = _claim_cohort_order()
	oracle_expiry_update_queue.clear()


func _oracle_state_is_earlier(
	first: OracleState,
	second: OracleState
) -> bool:
	if first.expires_at != second.expires_at:
		return first.expires_at < second.expires_at
	return first.cohort_order < second.cohort_order


func _claim_cohort_order() -> int:
	next_cohort_order += 1
	return next_cohort_order


func _oracle_publish(
	target_index: int,
	stack_count: int,
	multiplier: float
) -> void:
	oracle_events.append(
		"%d|%d|%.6f" % [target_index, stack_count, multiplier]
	)


func _compare_event_stream(operation_index: int) -> void:
	_expect(
		callback_sink.events.size() == oracle_events.size(),
		"Operation %d event count diverged: actual=%d oracle=%d."
		% [
			operation_index,
			callback_sink.events.size(),
			oracle_events.size(),
		]
	)
	var comparable_count := mini(
		callback_sink.events.size(),
		oracle_events.size()
	)
	for event_index in range(comparable_count):
		if callback_sink.events[event_index] == oracle_events[event_index]:
			continue
		_expect(
			false,
			"Operation %d event %d diverged: actual=%s oracle=%s."
			% [
				operation_index,
				event_index,
				callback_sink.events[event_index],
				oracle_events[event_index],
			]
		)
		return


func _compare_runtime_state(
	operation_index: int,
	random: RandomNumberGenerator
) -> void:
	var expected_active_count := 0
	for state in oracle_states:
		if state != null:
			expected_active_count += 1
	_expect(
		int(scheduler.call("get_active_target_count"))
			== expected_active_count,
		"Operation %d active count diverged: actual=%d oracle=%d."
		% [
			operation_index,
			int(scheduler.call("get_active_target_count")),
			expected_active_count,
		]
	)
	_expect(
		int(scheduler.call("get_expiry_cohort_count"))
			<= expected_active_count,
		"Operation %d exposed more active cohorts than active targets."
		% operation_index
	)

	# A full state scan every 25 operations catches residue; sampling two targets
	# on other operations keeps this oracle focused on scheduler semantics rather
	# than spending most of its runtime allocating diagnostic dictionaries.
	var checked_indices: Array[int] = []
	if operation_index % 25 == 0:
		checked_indices.assign(range(TARGET_COUNT))
	else:
		checked_indices.append(random.randi_range(0, TARGET_COUNT - 1))
		checked_indices.append(random.randi_range(0, TARGET_COUNT - 1))
	for target_index in checked_indices:
		var expected_state := oracle_states[target_index]
		var actual_snapshot := (
			scheduler.call("get_state_snapshot", targets[target_index])
			as Dictionary
		)
		if expected_state == null:
			_expect(
				actual_snapshot.is_empty(),
				"Operation %d target %d retained an unexpected state: %s."
				% [operation_index, target_index, actual_snapshot]
			)
			continue
		_expect(
			int(actual_snapshot.get("stack_count", -1))
				== expected_state.stack_count
			and absf(
				float(actual_snapshot.get("multiplier", -1.0))
				- float(MULTIPLIERS[expected_state.stack_count - 1])
			) <= EXPIRY_EPSILON
			and absf(
				float(actual_snapshot.get("time_left", -1.0))
				- maxf(expected_state.expires_at - oracle_clock, 0.0)
			) <= EXPIRY_EPSILON * 4.0,
			(
				"Operation %d target %d state diverged: actual=%s "
				+ "oracle_stack=%d oracle_time=%.6f."
			)
			% [
				operation_index,
				target_index,
				actual_snapshot,
				expected_state.stack_count,
				maxf(expected_state.expires_at - oracle_clock, 0.0),
			]
		)


func _find_next_oracle_expiry() -> float:
	var next_expiry := INF
	for state in oracle_states:
		if state != null:
			next_expiry = minf(next_expiry, state.expires_at)
	return next_expiry


func _drain_oracle() -> void:
	_oracle_advance(10_000.0)
	scheduler.call("_advance_active_colds", 10_000.0)
	_compare_event_stream(RANDOM_OPERATION_COUNT)
	_expect(
		int(scheduler.call("get_active_target_count")) == 0
		and int(scheduler.call("get_expiry_cohort_count")) == 0
		and int(scheduler.call("get_heap_size")) == 0,
		"The randomized oracle must drain every state and deadline cohort."
	)


func _test_freed_target_cleanup() -> void:
	var stale_target := Enemy.new()
	var stale_sink := CallbackSink.new()
	var stale_callback := Callable(
		stale_sink,
		"receive_state"
	).bind(TARGET_COUNT)
	_expect(
		bool(scheduler.call("apply_cold", stale_target, stale_callback)),
		"The stale-target fixture must accept its initial cold hit."
	)
	stale_target.free()
	scheduler.call("_advance_active_colds", 3.0)
	_expect(
		stale_sink.events.size() == 1
		and int(scheduler.call("get_active_target_count")) == 0
		and int(scheduler.call("get_expiry_cohort_count")) == 0,
		"A freed target must leave no state and receive no expiry callback."
	)


func _test_reentrant_expiry_reapplication() -> void:
	scheduler.call("clear_all")
	var sink := ReentrantExpirySink.new()
	sink.scheduler = scheduler
	sink.reapply_target = targets[1]
	sink.reapply_callback = Callable(sink, "receive_reapplied")
	_expect(
		bool(scheduler.call(
			"apply_cold",
			targets[0],
			Callable(sink, "receive_source")
		))
		and bool(scheduler.call(
			"apply_cold",
			targets[1],
			sink.reapply_callback
		))
		and bool(scheduler.call(
			"apply_cold",
			targets[2],
			Callable(sink, "receive_tail")
		)),
		"The reentrant expiry fixture must accept all three targets."
	)
	scheduler.call("_advance_active_colds", 3.0)
	var expected_events: Array[String] = [
		"source:1",
		"reapplied:1",
		"tail:1",
		"source:0",
		"reapplied:1",
		"tail:0",
	]
	_expect(
		sink.events == expected_events
		and int(scheduler.call("get_stack_count", targets[1])) == 1
		and int(scheduler.call("get_active_target_count")) == 1,
		"A callback-time reapplication must survive the retired cohort and "
		+ "must not truncate later callbacks: actual=%s."
		% [sink.events]
	)
	_expect(
		bool(scheduler.call("clear_target", targets[1]))
		and sink.events.back() == "reapplied:0",
		"The reentrant replacement state must remain independently clearable."
	)


func _test_hitch_reentrant_expired_application() -> void:
	scheduler.call("clear_all")
	var sink := HitchReentrantSink.new()
	sink.scheduler = scheduler
	sink.reapply_target = targets[1]
	sink.reapply_callback = Callable(sink, "receive_target")
	_expect(
		bool(scheduler.call(
			"apply_cold",
			targets[1],
			sink.reapply_callback
		))
		and bool(scheduler.call(
			"apply_cold",
			targets[1],
			sink.reapply_callback
		))
		and bool(scheduler.call(
			"apply_cold",
			targets[0],
			Callable(sink, "receive_source")
		)),
		"The hitch-reentrancy fixture must accept its setup hits."
	)
	# Materialize target 1 at t=4 and target 0 at t=3, then hitch past both.
	# The t=3 callback applies to the still-indexed but logically expired target
	# 1. Its old clear callback immediately reapplies itself once more.
	scheduler.call("_advance_active_colds", 0.0)
	scheduler.call("_advance_active_colds", 5.0)
	var expected_events: Array[String] = [
		"target:1",
		"target:2",
		"source:1",
		"source:0",
		"target:0",
		"target:1",
		"target:2",
	]
	_expect(
		sink.events == expected_events
		and int(scheduler.call("get_stack_count", targets[1])) == 2
		and int(scheduler.call("get_active_target_count")) == 1
		and int(scheduler.call("get_expiry_cohort_count")) == 1,
		"A hitch-time nested replacement must become the outer hit's L2 state "
		+ "without stranding a second cohort: actual=%s."
		% [sink.events]
	)
	_expect(
		bool(scheduler.call("clear_target", targets[1]))
		and int(scheduler.call("get_active_target_count")) == 0,
		"The hitch-time replacement must clear without residue."
	)


func _test_clear_all_reentrant_reapplication() -> void:
	scheduler.call("clear_all")
	var sink := ClearAllReentrantSink.new()
	sink.scheduler = scheduler
	sink.target = targets[0]
	sink.callback = Callable(sink, "receive_state")
	_expect(
		bool(scheduler.call("apply_cold", sink.target, sink.callback)),
		"The clear-all reentrancy fixture must accept its initial state."
	)
	scheduler.call("clear_all")
	_expect(
		sink.events == [1, 0, 1]
		and int(scheduler.call("get_stack_count", sink.target)) == 1
		and int(scheduler.call("get_active_target_count")) == 1
		and int(scheduler.call("get_expiry_cohort_count")) == 1,
		"A clear_all callback must be able to install a fresh independent L1 state: %s."
		% [sink.events]
	)
	_expect(
		bool(scheduler.call("clear_target", sink.target))
		and int(scheduler.call("get_active_target_count")) == 0,
		"The state reapplied from clear_all must remain independently clearable."
	)


func _test_expiry_bucket_pool_bound() -> void:
	scheduler.call("clear_all")
	var distinct_bucket_targets: Array[Enemy] = []
	var sink := CallbackSink.new()
	for target_index in range(160):
		var target := Enemy.new()
		distinct_bucket_targets.append(target)
		_expect(
			bool(scheduler.call(
				"apply_cold",
				target,
				Callable(sink, "receive_state").bind(target_index)
			)),
			"Distinct-deadline fixture rejected target %d." % target_index
		)
		scheduler.call("_advance_active_colds", 0.001)
	_expect(
		int(scheduler.call("get_expiry_cohort_count")) == 160,
		"Distinct deadlines must materialize 160 independent cohorts before cleanup."
	)
	scheduler.call("clear_all")
	var metrics := scheduler.call("get_performance_metrics") as Dictionary
	_expect(
		int(metrics.get("pooled_expiry_buckets", -1)) == 128
		and int(scheduler.call("get_heap_size")) == 0
		and int(scheduler.call("get_expiry_cohort_count")) == 0,
		"Expiry bucket recycling must remain strictly capped at 128 objects: %s."
		% [metrics]
	)
	for target in distinct_bucket_targets:
		target.free()


func _free_targets() -> void:
	for target in targets:
		if target != null and is_instance_valid(target):
			target.free()
	targets.clear()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
