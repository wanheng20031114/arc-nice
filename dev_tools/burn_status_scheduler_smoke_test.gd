extends SceneTree

const NORMAL_BURN_FAMILY := &"fire_sorcerer_fireball_volley"
const ELITE_BURN_FAMILY := &"fire_sorcerer_elite_fireball_volley"
const PERFORMANCE_TARGET_COUNT := 300
const PERFORMANCE_FRAME_COUNT := 60
const FRAME_BUDGET_USEC := 16600
const AB_TARGET_COUNT := 1200
const AB_IDLE_FRAME_COUNT := 45
const STAGGERED_TARGET_COUNT := 1200
const STAGGERED_FRAME_COUNT := 60
const STRESS_TARGET_COUNT := 1000
const STRESS_TICK_BUDGET_USEC := 50000


class BurnProbe:
	extends RefCounted

	var tick_count := 0
	var tick_damage_total := 0
	var last_source_family := StringName()
	var scheduler: Node = null
	var clear_on_first_tick := false
	var state_events: Array[bool] = []
	var reapply_on_state_clear := false

	func receive_burn_tick(
		source_family: StringName,
		tick_damage: int
	) -> bool:
		tick_count += 1
		tick_damage_total += tick_damage
		last_source_family = source_family
		if clear_on_first_tick and tick_count == 1 and scheduler != null:
			scheduler.call("clear_target", self)
		return true

	func receive_burn_state(active: bool) -> void:
		state_events.append(active)
		if (
			active
			or not reapply_on_state_clear
			or scheduler == null
		):
			return
		reapply_on_state_clear = false
		scheduler.call(
			"apply_burn",
			self,
			Callable(self, "receive_burn_tick"),
			&"reentrant_burn",
			1.0,
			1,
			Callable(self, "receive_burn_state")
		)


class LegacyBurnState:
	extends RefCounted

	var time_left := 5.0
	var tick_time_left := 1.0


var failures: Array[String] = []
var scheduler: Node = null


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	scheduler = root.get_node("BurnStatusScheduler")
	scheduler.call("clear_all")
	scheduler.set_physics_process(false)

	_test_same_family_refreshes_without_stacking()
	_test_strongest_family_only()
	_test_fine_grained_transition_matches_production_contract()
	_test_equal_damage_family_order_is_stable()
	_test_expiry_boundary_matches_enemy_burn()
	_test_mixed_due_cohort_keeps_scheduler_active()
	_test_large_delta_catches_up_ticks()
	_test_callback_clear_stops_catch_up()
	_test_state_lifecycle_callbacks()
	await _test_destroyed_target_is_reclaimed_without_callback()
	_test_event_queue_ab_comparison()
	_test_staggered_due_events_stay_sparse()
	_test_three_hundred_active_target_cost()
	_test_thousand_target_tick_stress()

	scheduler.call("set_performance_metrics_enabled", false)
	scheduler.call("clear_all")
	await process_frame
	if failures.is_empty():
		print("BURN_STATUS_SCHEDULER_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_same_family_refreshes_without_stacking() -> void:
	scheduler.call("clear_all")
	scheduler.call("set_performance_metrics_enabled", true)
	var target := BurnProbe.new()
	_apply_burn(target, NORMAL_BURN_FAMILY, 5.0, 5)
	scheduler.call("_advance_active_burns", 0.25)
	var deferred_snapshot := scheduler.call(
		"get_source_snapshot",
		target,
		NORMAL_BURN_FAMILY
	) as Dictionary
	_expect(
		is_equal_approx(
			float(deferred_snapshot.get("time_left", 0.0)),
			4.75
		)
		and is_equal_approx(
			float(deferred_snapshot.get("tick_time_left", 0.0)),
			0.75
		),
		"Deferred event scheduling must still expose current burn countdowns."
	)
	# 两次同族补射都应原位刷新首个来源状态。
	_apply_burn(target, NORMAL_BURN_FAMILY, 5.0, 5)
	_apply_burn(target, NORMAL_BURN_FAMILY, 5.0, 5)
	var refresh_metrics := scheduler.call(
		"get_performance_metrics"
	) as Dictionary
	_expect(
		int(refresh_metrics.get("source_state_allocations", -1)) == 1
		and int(refresh_metrics.get("source_refreshes", -1)) == 2,
		"One three-ball family must allocate once and refresh in place twice."
	)
	scheduler.call("set_performance_metrics_enabled", false)
	_expect(
		int(scheduler.call("get_active_target_count")) == 1
		and int(scheduler.call("get_source_count", target)) == 1
		and int(scheduler.call("get_heap_size")) == 1,
		"Three fireballs from one volley family must refresh one burn, not stack."
	)
	scheduler.call("_advance_active_burns", 0.99)
	_expect(target.tick_count == 0, "Burn must not tick before one second.")
	scheduler.call("_advance_active_burns", 0.02)
	_expect(
		target.tick_count == 1
		and target.tick_damage_total == 5
		and target.last_source_family == NORMAL_BURN_FAMILY,
		"Normal burn must tick once for level-5 damage after one second."
	)


func _test_state_lifecycle_callbacks() -> void:
	scheduler.call("clear_all")
	var target := BurnProbe.new()
	target.scheduler = scheduler
	var state_callback := Callable(target, "receive_burn_state")
	_expect(
		bool(scheduler.call(
			"apply_burn",
			target,
			Callable(target, "receive_burn_tick"),
			NORMAL_BURN_FAMILY,
			0.2,
			5,
			state_callback
		)),
		"Burn state callback fixture must accept its first source."
	)
	scheduler.call(
		"apply_burn",
		target,
		Callable(target, "receive_burn_tick"),
		NORMAL_BURN_FAMILY,
		0.2,
		5,
		state_callback
	)
	scheduler.call(
		"apply_burn",
		target,
		Callable(target, "receive_burn_tick"),
		ELITE_BURN_FAMILY,
		0.4,
		10,
		state_callback
	)
	_expect(
		target.state_events == [true],
		"Burn refreshes and additional sources must not clear or restart an active visual."
	)
	scheduler.call("_advance_active_burns", 0.21)
	_expect(
		target.state_events == [true],
		"One expired source must not clear the visual while another burn remains."
	)
	scheduler.call("_advance_active_burns", 0.20)
	_expect(
		target.state_events == [true, false],
		"The final naturally expired burn source must clear the visual exactly once."
	)

	target.reapply_on_state_clear = true
	scheduler.call(
		"apply_burn",
		target,
		Callable(target, "receive_burn_tick"),
		NORMAL_BURN_FAMILY,
		1.0,
		5,
		state_callback
	)
	scheduler.call("clear_all")
	_expect(
		target.state_events == [true, false, true, false, true]
		and bool(scheduler.call("has_burn", target)),
		"A clear callback that reapplies burn must keep the replacement state and its active visual."
	)
	scheduler.call("clear_all")
	_expect(
		target.state_events == [true, false, true, false, true, false],
		"Clearing the replacement burn must emit one final inactive state."
	)


func _test_strongest_family_only() -> void:
	scheduler.call("clear_all")
	var target := BurnProbe.new()
	_apply_burn(target, NORMAL_BURN_FAMILY, 4.0, 5)
	_apply_burn(target, ELITE_BURN_FAMILY, 1.5, 10)
	scheduler.call("_advance_active_burns", 1.01)
	_expect(
		target.tick_count == 1
		and target.tick_damage_total == 10
		and target.last_source_family == ELITE_BURN_FAMILY,
		"Elite level-10 burn must suppress simultaneous level-5 tick damage."
	)
	scheduler.call("_advance_active_burns", 0.50)
	_expect(
		target.tick_count == 1,
		"A weaker burn's tick clock must remain paused through Elite expiry."
	)
	scheduler.call("_advance_active_burns", 0.51)
	_expect(
		target.tick_count == 1,
		"A coarse post-expiry step must not inherit pre-expiry elapsed time."
	)
	scheduler.call("_advance_active_burns", 0.49)
	_expect(
		target.tick_count == 2
		and target.tick_damage_total == 15
		and target.last_source_family == NORMAL_BURN_FAMILY,
		"Normal burn must tick one full second after Elite burn expires."
	)


func _test_fine_grained_transition_matches_production_contract() -> void:
	scheduler.call("clear_all")
	var elite_duration := 1.49
	var target := BurnProbe.new()
	_apply_burn(target, NORMAL_BURN_FAMILY, 4.0, 5)
	_apply_burn(target, ELITE_BURN_FAMILY, elite_duration, 10)
	var exact_normal_tick_frame := -1
	var frame_delta := 1.0 / float(Engine.physics_ticks_per_second)
	for frame_number in range(1, 181):
		scheduler.call("_advance_active_burns", frame_delta)
		if target.last_source_family == NORMAL_BURN_FAMILY:
			exact_normal_tick_frame = frame_number
			break
	var legacy_normal_tick_frame := _simulate_legacy_normal_tick_frame(
		frame_delta,
		180,
		elite_duration
	)
	print(
		(
			"BURN_STATUS_TRANSITION exact_frame=%d legacy_60hz_frame=%d "
			+ "frame_difference=%d"
		)
		% [
			exact_normal_tick_frame,
			legacy_normal_tick_frame,
			exact_normal_tick_frame - legacy_normal_tick_frame,
		]
	)
	_expect(
		exact_normal_tick_frame > 0
		and legacy_normal_tick_frame > 0
		and exact_normal_tick_frame >= legacy_normal_tick_frame
		and exact_normal_tick_frame - legacy_normal_tick_frame <= 1,
		"Exact transition timing may only remove the legacy <=1-frame early-tick error."
	)
	_expect(
		absf(
			float(exact_normal_tick_frame) * frame_delta
			- (elite_duration + 1.0)
		)
			<= frame_delta,
		"The weaker burn must resume from a full one-second clock at Elite expiry."
	)


func _simulate_legacy_normal_tick_frame(
	frame_delta: float,
	maximum_frames: int,
	elite_duration: float
) -> int:
	var normal_time_left := 4.0
	var elite_time_left := elite_duration
	var normal_tick_time_left := 1.0
	var elite_tick_time_left := 1.0
	for frame_number in range(1, maximum_frames + 1):
		normal_time_left -= frame_delta
		elite_time_left -= frame_delta
		# 旧生产循环每帧先统一删除到期来源，再把这一整帧记给当帧
		# 最强来源；这会让接班来源最多提前一个物理帧。
		if elite_time_left > 0.0:
			elite_tick_time_left -= frame_delta
			while elite_tick_time_left <= 0.0:
				elite_tick_time_left += 1.0
			continue
		if normal_time_left <= 0.0:
			return -1
		normal_tick_time_left -= frame_delta
		if normal_tick_time_left <= 0.0:
			return frame_number
	return -1


func _test_equal_damage_family_order_is_stable() -> void:
	scheduler.call("clear_all")
	var target := BurnProbe.new()
	_apply_burn(target, &"z_family", 3.0, 7)
	_apply_burn(target, &"a_family", 3.0, 7)
	scheduler.call("_advance_active_burns", 1.01)
	_expect(
		target.tick_count == 1
		and target.last_source_family == &"a_family",
		"Equal-damage burns must retain the lexicographically stable family tie-break."
	)


func _test_expiry_boundary_matches_enemy_burn() -> void:
	scheduler.call("clear_all")
	var target := BurnProbe.new()
	_apply_burn(target, NORMAL_BURN_FAMILY, 1.0, 5)
	scheduler.call("_advance_active_burns", 1.0)
	_expect(
		target.tick_count == 0
		and not bool(scheduler.call("has_burn", target)),
		"Burn expiry must resolve before a tick due on the exact same frame."
	)


func _test_mixed_due_cohort_keeps_scheduler_active() -> void:
	scheduler.call("clear_all")
	var expiring_target := BurnProbe.new()
	var continuing_target := BurnProbe.new()
	_apply_burn(expiring_target, NORMAL_BURN_FAMILY, 1.0, 5)
	_apply_burn(continuing_target, NORMAL_BURN_FAMILY, 5.0, 5)
	scheduler.call("_advance_active_burns", 1.0)
	_expect(
		expiring_target.tick_count == 0
		and continuing_target.tick_count == 1
		and int(scheduler.call("get_active_target_count")) == 1
		and int(scheduler.call("get_heap_size")) == 1
		and scheduler.is_physics_processing(),
		"An expiring member of a due cohort must not stop later active burn events."
	)


func _test_large_delta_catches_up_ticks() -> void:
	scheduler.call("clear_all")
	var target := BurnProbe.new()
	_apply_burn(target, NORMAL_BURN_FAMILY, 4.5, 5)
	scheduler.call("_advance_active_burns", 3.2)
	_expect(
		target.tick_count == 3
		and target.tick_damage_total == 15
		and bool(scheduler.call("has_burn", target)),
		"A long authoritative step must catch up every due tick while duration remains."
	)


func _test_callback_clear_stops_catch_up() -> void:
	scheduler.call("clear_all")
	var target := BurnProbe.new()
	target.scheduler = scheduler
	target.clear_on_first_tick = true
	_apply_burn(target, NORMAL_BURN_FAMILY, 5.0, 5)
	scheduler.call("_advance_active_burns", 3.2)
	_expect(
		target.tick_count == 1
		and not bool(scheduler.call("has_burn", target))
		and int(scheduler.call("get_heap_size")) == 0,
		"Death/clear re-entry on the first tick must stop same-step catch-up damage."
	)


func _test_destroyed_target_is_reclaimed_without_callback() -> void:
	scheduler.call("clear_all")
	var callback_probe := BurnProbe.new()
	var target := Node.new()
	root.add_child(target)
	_expect(
		bool(scheduler.call(
			"apply_burn",
			target,
			Callable(callback_probe, "receive_burn_tick"),
			NORMAL_BURN_FAMILY,
			5.0,
			5
		)),
		"Burn scheduler rejected a valid Node target."
	)
	target.queue_free()
	await process_frame
	scheduler.call("_advance_active_burns", 1.01)
	_expect(
		callback_probe.tick_count == 0
		and int(scheduler.call("get_active_target_count")) == 0
		and int(scheduler.call("get_heap_size")) == 0,
		"A freed weak target must be retired at its next event without a late callback."
	)


func _test_event_queue_ab_comparison() -> void:
	scheduler.call("clear_all")
	var targets: Array[BurnProbe] = []
	targets.resize(AB_TARGET_COUNT)
	for target_index in range(AB_TARGET_COUNT):
		var target := BurnProbe.new()
		targets[target_index] = target
		_apply_burn(target, NORMAL_BURN_FAMILY, 5.0, 5)
	scheduler.call("set_performance_metrics_enabled", true)
	var optimized_started_usec := Time.get_ticks_usec()
	for _frame_index in range(AB_IDLE_FRAME_COUNT):
		scheduler.call(
			"_advance_active_burns",
			1.0 / float(Engine.physics_ticks_per_second)
		)
	var optimized_usec := maxi(
		Time.get_ticks_usec() - optimized_started_usec,
		1
	)
	var optimized_metrics := scheduler.call(
		"get_performance_metrics"
	) as Dictionary

	var legacy_states: Array[LegacyBurnState] = []
	legacy_states.resize(AB_TARGET_COUNT)
	for target_index in range(AB_TARGET_COUNT):
		legacy_states[target_index] = LegacyBurnState.new()
	var legacy_started_usec := Time.get_ticks_usec()
	for _frame_index in range(AB_IDLE_FRAME_COUNT):
		var frame_delta := 1.0 / float(Engine.physics_ticks_per_second)
		for legacy_state in legacy_states:
			legacy_state.time_left -= frame_delta
			legacy_state.tick_time_left -= frame_delta
	var legacy_usec := maxi(
		Time.get_ticks_usec() - legacy_started_usec,
		1
	)
	var speedup := float(legacy_usec) / float(optimized_usec)
	print(
		(
			"BURN_STATUS_SCHEDULER_AB targets=%d frames=%d "
			+ "event_usec=%d legacy_scan_usec=%d speedup=%.2fx "
			+ "event_target_steps=%d legacy_target_steps=%d"
		)
		% [
			AB_TARGET_COUNT,
			AB_IDLE_FRAME_COUNT,
			optimized_usec,
			legacy_usec,
			speedup,
			int(optimized_metrics.get("target_steps", -1)),
			AB_TARGET_COUNT * AB_IDLE_FRAME_COUNT,
		]
	)
	_expect(
		int(optimized_metrics.get("target_steps", -1)) == 0
		and int(optimized_metrics.get("heap_root_checks", -1))
			== AB_IDLE_FRAME_COUNT,
		"Idle burn frames must perform one heap-root check and zero target scans."
	)
	_expect(
		optimized_usec < legacy_usec,
		"Event scheduling must beat the retired per-target-per-frame scan in A/B."
	)
	scheduler.call("set_performance_metrics_enabled", false)
	scheduler.call("clear_all")


func _test_staggered_due_events_stay_sparse() -> void:
	scheduler.call("clear_all")
	var targets: Array[BurnProbe] = []
	targets.resize(STAGGERED_TARGET_COUNT)
	var targets_per_frame := STAGGERED_TARGET_COUNT / STAGGERED_FRAME_COUNT
	var frame_delta := 1.0 / float(STAGGERED_FRAME_COUNT)
	for frame_index in range(STAGGERED_FRAME_COUNT):
		for local_index in range(targets_per_frame):
			var target_index := frame_index * targets_per_frame + local_index
			var target := BurnProbe.new()
			targets[target_index] = target
			_apply_burn(target, NORMAL_BURN_FAMILY, 5.0, 5)
		scheduler.call("_advance_active_burns", frame_delta)

	# The next second contains twenty due targets per frame: a realistic stream of
	# projectile impacts, not one synchronized debug cohort. No frame may fall back
	# to scanning all 1,200 active targets merely because one heap root is due.
	scheduler.call("set_performance_metrics_enabled", true)
	var started_usec := Time.get_ticks_usec()
	var maximum_frame_usec := 0
	for _frame_index in range(STAGGERED_FRAME_COUNT):
		var frame_started_usec := Time.get_ticks_usec()
		scheduler.call("_advance_active_burns", frame_delta)
		maximum_frame_usec = maxi(
			maximum_frame_usec,
			Time.get_ticks_usec() - frame_started_usec
		)
	var elapsed_usec := maxi(Time.get_ticks_usec() - started_usec, 0)
	var metrics := scheduler.call("get_performance_metrics") as Dictionary
	print(
		(
			"BURN_STATUS_STAGGERED targets=%d frames=%d event_usec=%d max_frame_usec=%d "
			+ "target_steps=%d sparse_pops=%d dense_scans=%d "
			+ "retired_full_scan_steps=%d"
		)
		% [
			STAGGERED_TARGET_COUNT,
			STAGGERED_FRAME_COUNT,
			elapsed_usec,
			maximum_frame_usec,
			int(metrics.get("target_steps", -1)),
			int(metrics.get("sparse_due_pops", -1)),
			int(metrics.get("dense_due_scans", -1)),
			STAGGERED_TARGET_COUNT * STAGGERED_FRAME_COUNT,
		]
	)
	_expect(
		int(metrics.get("target_steps", -1)) == STAGGERED_TARGET_COUNT
		and int(metrics.get("sparse_due_pops", -1)) == STAGGERED_TARGET_COUNT
		and int(metrics.get("dense_due_scans", -1)) == 0
		and int(metrics.get("dense_candidates_scanned", -1)) == 0
		and int(metrics.get("heap_size", -1)) == STAGGERED_TARGET_COUNT
		and maximum_frame_usec < FRAME_BUDGET_USEC,
		"Staggered burns must process only due heap roots and never rescan the full population."
	)
	scheduler.call("set_performance_metrics_enabled", false)
	scheduler.call("clear_all")


func _test_three_hundred_active_target_cost() -> void:
	scheduler.call("clear_all")
	var targets: Array[BurnProbe] = []
	targets.resize(PERFORMANCE_TARGET_COUNT)
	for target_index in range(PERFORMANCE_TARGET_COUNT):
		var target := BurnProbe.new()
		targets[target_index] = target
		_apply_burn(target, NORMAL_BURN_FAMILY, 5.0, 5)
	scheduler.set_physics_process(false)
	scheduler.call("set_performance_metrics_enabled", true)

	var frame_usecs: Array[int] = []
	for _frame_index in range(PERFORMANCE_FRAME_COUNT):
		var started_usec := Time.get_ticks_usec()
		scheduler.call(
			"_physics_process",
			1.0 / float(Engine.physics_ticks_per_second)
		)
		frame_usecs.append(
			maxi(Time.get_ticks_usec() - started_usec, 0)
		)
	frame_usecs.sort()
	var p95_index := clampi(
		ceili(float(frame_usecs.size()) * 0.95) - 1,
		0,
		frame_usecs.size() - 1
	)
	var p95_usec := frame_usecs[p95_index]
	var maximum_usec: int = frame_usecs.back()
	var metrics: Dictionary = scheduler.call(
		"get_performance_metrics"
	) as Dictionary
	print(
		(
			"BURN_STATUS_SCHEDULER_PERFORMANCE targets=%d p95_usec=%d "
			+ "max_usec=%d target_steps=%d damage_ticks=%d"
		)
		% [
			PERFORMANCE_TARGET_COUNT,
			p95_usec,
			maximum_usec,
			int(metrics.get("target_steps", 0)),
			int(metrics.get("damage_ticks", 0)),
		]
	)
	_expect(
		int(scheduler.call("get_active_target_count"))
			== PERFORMANCE_TARGET_COUNT
		and int(metrics.get("target_steps", -1))
			== PERFORMANCE_TARGET_COUNT
		and int(metrics.get("damage_ticks", -1))
			== PERFORMANCE_TARGET_COUNT
		and int(metrics.get("heap_size", -1))
			== PERFORMANCE_TARGET_COUNT,
		"All 300 five-second burns must remain active after the first second."
	)
	_expect(
		p95_usec < FRAME_BUDGET_USEC
		and maximum_usec < FRAME_BUDGET_USEC,
		"300 active burn targets must stay below 16.6 ms at p95 and peak tick."
	)


func _test_thousand_target_tick_stress() -> void:
	scheduler.call("clear_all")
	var targets: Array[BurnProbe] = []
	targets.resize(STRESS_TARGET_COUNT)
	for target_index in range(STRESS_TARGET_COUNT):
		var target := BurnProbe.new()
		targets[target_index] = target
		_apply_burn(target, NORMAL_BURN_FAMILY, 5.0, 5)
	scheduler.call("set_performance_metrics_enabled", true)
	var started_usec := Time.get_ticks_usec()
	scheduler.call("_advance_active_burns", 1.0)
	var elapsed_usec := maxi(Time.get_ticks_usec() - started_usec, 0)
	var metrics := scheduler.call("get_performance_metrics") as Dictionary
	print(
		(
			"BURN_STATUS_SCHEDULER_STRESS targets=%d tick_usec=%d "
			+ "target_steps=%d damage_ticks=%d"
		)
		% [
			STRESS_TARGET_COUNT,
			elapsed_usec,
			int(metrics.get("target_steps", -1)),
			int(metrics.get("damage_ticks", -1)),
		]
	)
	_expect(
		int(metrics.get("target_steps", -1)) == STRESS_TARGET_COUNT
		and int(metrics.get("damage_ticks", -1)) == STRESS_TARGET_COUNT
		and int(metrics.get("active_targets", -1)) == STRESS_TARGET_COUNT
		and int(metrics.get("heap_size", -1)) == STRESS_TARGET_COUNT,
		"A 1,000-target cohort must tick exactly once and retain every live burn."
	)
	_expect(
		elapsed_usec < STRESS_TICK_BUDGET_USEC,
		"A 1,000-target simultaneous burn tick must stay below the 50 ms stress budget."
	)
	scheduler.call("set_performance_metrics_enabled", false)
	scheduler.call("clear_all")


func _apply_burn(
	target: BurnProbe,
	source_family: StringName,
	duration: float,
	tick_damage: int
) -> void:
	_expect(
		bool(scheduler.call(
			"apply_burn",
			target,
			Callable(target, "receive_burn_tick"),
			source_family,
			duration,
			tick_damage
		)),
		"Burn scheduler rejected a valid target."
	)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
