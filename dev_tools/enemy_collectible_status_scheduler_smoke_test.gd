extends SceneTree

const BASIC_CONFIG := preload(
	"res://resources/config/enemies/yuanshi_insect_basic.tres"
)
const TEST_HEALTH := 500
const STATUS_DAMAGE := 10
const STABLE_FRAME_COUNT := 300


class DeadlineProbe extends Node:
	var callback_count := 0
	var repeat_interval := 0.0

	func _on_test_deadline(scheduler_time: float) -> float:
		callback_count += 1
		return (
			scheduler_time + repeat_interval
			if repeat_interval > 0.0
			else 0.0
		)


var failures: Array[String] = []
var test_root: Node2D
var scheduler: Node


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	test_root = Node2D.new()
	test_root.name = "EnemyCollectibleStatusSchedulerSmokeTest"
	root.add_child(test_root)
	current_scene = test_root
	scheduler = root.get_node("EnemyCollectibleStatusScheduler")
	scheduler.call("clear_all")

	await _test_hitch_and_frame_split_invariance()
	await _test_expiry_precedes_exact_boundary_tick()
	await _test_reapplication_resets_duration_and_tick_phase()
	await _test_strongest_burn_pauses_weaker_phase()
	await _test_death_and_queue_free_unregister_immediately()
	await _test_indexed_reschedule_stagger_and_clear()
	await _test_stable_frame_heap_ab(300)
	await _test_stable_frame_heap_ab(1000)
	await _test_due_cohort_dispatch(300)
	await _test_due_cohort_dispatch(1000)
	await _test_recurring_cohort_rebuild(1000)

	scheduler.call("set_performance_metrics_enabled", false)
	scheduler.call("clear_all")
	test_root.queue_free()
	await process_frame
	if failures.is_empty():
		print("ENEMY COLLECTIBLE STATUS SCHEDULER SMOKE TEST PASSED")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_hitch_and_frame_split_invariance() -> void:
	var hitch_health := await _run_bleed_timeline([2.4])
	var split_health := await _run_bleed_timeline([1.2, 1.2])
	var granular_deltas: Array[float] = []
	for _step in range(24):
		granular_deltas.append(0.1)
	var granular_health := await _run_bleed_timeline(granular_deltas)
	_expect(
		hitch_health == TEST_HEALTH - STATUS_DAMAGE * 4,
		"A 2.4-second hitch must preserve ticks at 0.5, 1.0, 1.5 and 2.0 before the 2.2-second expiry."
	)
	_expect(
		hitch_health == split_health and split_health == granular_health,
		"Collectible DoT results must be invariant across hitch, split and granular frame sequences."
	)


func _run_bleed_timeline(deltas: Array[float]) -> int:
	var enemy := _spawn_enemy(TEST_HEALTH)
	enemy.apply_collectible_status(
		&"bleed",
		81001,
		2.2,
		STATUS_DAMAGE,
		0.5,
		EnemyConfig.DamageType.PHYSICAL
	)
	for delta in deltas:
		scheduler.call("advance_for_test", delta)
	var final_health := enemy.current_health
	_expect(
		enemy.collectible_status_effects.is_empty(),
		"The 2.2-second bleed must be retired after advancing to 2.4 seconds."
	)
	enemy.queue_free()
	await process_frame
	return final_health


func _test_expiry_precedes_exact_boundary_tick() -> void:
	var enemy := _spawn_enemy(100)
	enemy.add_physical_defense_modifier(82000, 5)
	enemy.apply_collectible_status(
		&"mark", 82001, 0.5, 0, 0.5,
		EnemyConfig.DamageType.MAGIC, 1.0, 0, 2.0
	)
	enemy.apply_collectible_status(
		&"crack", 82002, 0.5, 0, 0.5,
		EnemyConfig.DamageType.MAGIC, 1.0, -4
	)
	enemy.apply_collectible_status(
		&"bleed", 82003, 1.0, 10, 0.5,
		EnemyConfig.DamageType.PHYSICAL
	)
	scheduler.call("advance_for_test", 0.5)
	_expect(
		enemy.current_health == 95,
		"Expiring mark/crack at the exact bleed deadline must be removed before the physical tick."
	)
	_expect(
		not enemy.collectible_status_effects.has("82001:mark")
		and not enemy.collectible_status_effects.has("82002:crack")
		and enemy.collectible_status_effects.has("82003:bleed")
		and enemy.get_effective_physical_defense() == 5
		and is_equal_approx(enemy.get_damage_taken_multiplier(), 1.0),
		"Exact-deadline expiry must revoke every modifier while retaining the later bleed."
	)
	enemy.queue_free()
	await process_frame


func _test_reapplication_resets_duration_and_tick_phase() -> void:
	var enemy := _spawn_enemy(100)
	enemy.apply_collectible_status(
		&"bleed", 83001, 1.0, 10, 0.5,
		EnemyConfig.DamageType.PHYSICAL
	)
	scheduler.call("advance_for_test", 0.4)
	enemy.apply_collectible_status(
		&"bleed", 83001, 1.0, 10, 0.5,
		EnemyConfig.DamageType.PHYSICAL
	)
	scheduler.call("advance_for_test", 0.49)
	_expect(
		enemy.current_health == 100,
		"Same-source reapplication must reset the first-tick phase instead of retaining 0.1 seconds."
	)
	scheduler.call("advance_for_test", 0.01)
	_expect(
		enemy.current_health == 90,
		"The reapplied status must tick exactly one full interval after reapplication."
	)
	scheduler.call("advance_for_test", 0.5)
	_expect(
		enemy.current_health == 90
		and enemy.collectible_status_effects.is_empty(),
		"Reapplication must reset duration, with expiry winning over the coincident second tick."
	)
	enemy.queue_free()
	await process_frame


func _test_strongest_burn_pauses_weaker_phase() -> void:
	var enemy := _spawn_enemy(100)
	enemy.apply_collectible_status(&"burn", 84001, 3.0, 5, 0.2)
	enemy.apply_collectible_status(&"burn", 84002, 1.2, 15, 0.2)
	scheduler.call("advance_for_test", 1.01)
	_expect(
		enemy.current_health == 85,
		"Only the strongest burn may own the shared burn tick deadline."
	)
	scheduler.call("advance_for_test", 0.25)
	_expect(
		enemy.current_health == 85,
		"A weaker burn phase must stay paused while the stronger source expires."
	)
	scheduler.call("advance_for_test", 0.99)
	_expect(
		enemy.current_health == 80,
		"The weaker burn must resume its saved one-second phase after the stronger source expires."
	)
	enemy.queue_free()
	await process_frame


func _test_death_and_queue_free_unregister_immediately() -> void:
	var queued_enemy := _spawn_enemy(100)
	queued_enemy.apply_collectible_status(&"mark", 85001, 20.0, 0, 0.5)
	_expect(
		int(scheduler.call("get_active_target_count")) == 1,
		"An active collectible status must own exactly one scheduler entry."
	)
	queued_enemy.queue_free()
	await process_frame
	_expect(
		int(scheduler.call("get_active_target_count")) == 0,
		"Enemy _exit_tree must remove its deadline entry without waiting for expiry."
	)

	var dying_enemy := _spawn_enemy(5)
	dying_enemy.apply_collectible_status(
		&"bleed", 85002, 1.0, 10, 0.1,
		EnemyConfig.DamageType.PHYSICAL
	)
	scheduler.call("advance_for_test", 0.1)
	_expect(
		dying_enemy.is_dead
		and dying_enemy.collectible_status_effects.is_empty()
		and int(scheduler.call("get_active_target_count")) == 0,
		"A lethal deadline callback must clear statuses and must not reinsert the dead enemy."
	)
	dying_enemy.queue_free()
	await process_frame

	var proxy_enemy := _spawn_enemy(100)
	proxy_enemy.configure_multiplayer_proxy()
	proxy_enemy.apply_collectible_status(&"mark", 85003, 20.0, 0, 0.5)
	_expect(
		proxy_enemy.collectible_status_effects.is_empty()
		and int(scheduler.call("get_active_target_count")) == 0,
		"A multiplayer visual proxy must reject authoritative collectible status scheduling."
	)
	proxy_enemy.queue_free()
	await process_frame


func _test_indexed_reschedule_stagger_and_clear() -> void:
	scheduler.call("clear_all")
	var first_probe := DeadlineProbe.new()
	var second_probe := DeadlineProbe.new()
	test_root.add_child(first_probe)
	test_root.add_child(second_probe)
	var now := float(scheduler.call("get_clock"))
	scheduler.call(
		"schedule_target", first_probe, now + 0.25, &"_on_test_deadline"
	)
	scheduler.call(
		"schedule_target", second_probe, now + 0.5, &"_on_test_deadline"
	)
	scheduler.call(
		"schedule_target", first_probe, now + 0.75, &"_on_test_deadline"
	)
	scheduler.call("advance_for_test", 0.5)
	_expect(
		first_probe.callback_count == 0
		and second_probe.callback_count == 1
		and int(scheduler.call("get_active_target_count")) == 1,
		"Rescheduling one indexed target later must preserve the earlier staggered target."
	)
	_expect(
		bool(scheduler.call("clear_target", first_probe))
		and int(scheduler.call("get_active_target_count")) == 0
		and int(scheduler.call("get_heap_size")) == 0,
		"Explicit clear must remove the rescheduled target from both dictionary and heap."
	)
	scheduler.call("advance_for_test", 0.5)
	_expect(
		first_probe.callback_count == 0,
		"A cleared rescheduled target must never receive its old deadline callback."
	)
	first_probe.queue_free()
	second_probe.queue_free()
	await process_frame


func _test_stable_frame_heap_ab(target_count: int) -> void:
	var probes: Array[DeadlineProbe] = []
	scheduler.call("clear_all")
	scheduler.call("set_performance_metrics_enabled", true)
	var deadline := float(scheduler.call("get_clock")) + 60.0
	var schedule_started_usec := Time.get_ticks_usec()
	for target_index in range(target_count):
		var probe := DeadlineProbe.new()
		probe.name = "DeadlineProbe%d" % target_index
		test_root.add_child(probe)
		probes.append(probe)
		_expect(
			bool(scheduler.call(
				"schedule_target",
				probe,
				deadline,
				&"_on_test_deadline"
			)),
			"A valid deadline probe must be admitted."
		)
	var schedule_usec := Time.get_ticks_usec() - schedule_started_usec
	_expect(
		int(scheduler.call("get_active_target_count")) == target_count
		and int(scheduler.call("get_heap_size")) == target_count,
		"The indexed heap must keep one entry per active target."
	)

	scheduler.call("reset_performance_metrics")
	var heap_started_usec := Time.get_ticks_usec()
	for _frame in range(STABLE_FRAME_COUNT):
		scheduler.call("advance_for_test", 1.0 / 60.0)
	var heap_usec := Time.get_ticks_usec() - heap_started_usec
	var metrics := scheduler.call("get_performance_metrics") as Dictionary
	_expect(
		int(metrics.get("heap_root_checks", -1)) == STABLE_FRAME_COUNT
		and int(metrics.get("deadline_callbacks", -1)) == 0,
		"Stable frames must perform one heap-root check, not one scan per active status."
	)

	var legacy_remaining := PackedFloat64Array()
	legacy_remaining.resize(target_count)
	legacy_remaining.fill(60.0)
	var legacy_started_usec := Time.get_ticks_usec()
	for _frame in range(STABLE_FRAME_COUNT):
		for target_index in range(target_count):
			legacy_remaining[target_index] -= 1.0 / 60.0
	var legacy_usec := Time.get_ticks_usec() - legacy_started_usec
	_expect(
		heap_usec < legacy_usec,
		"The deadline heap stable-frame path must outperform the legacy full-target scan."
	)
	print(
		"ENEMY_COLLECTIBLE_STATUS_AB targets=%d frames=%d schedule_usec=%d heap_usec=%d legacy_scan_usec=%d speedup=%.2fx"
		% [
			target_count,
			STABLE_FRAME_COUNT,
			schedule_usec,
			heap_usec,
			legacy_usec,
			float(legacy_usec) / maxf(float(heap_usec), 1.0),
		]
	)

	scheduler.call("clear_all")
	for probe in probes:
		probe.queue_free()
	await process_frame


func _test_due_cohort_dispatch(target_count: int) -> void:
	var probes: Array[DeadlineProbe] = []
	scheduler.call("clear_all")
	scheduler.call("set_performance_metrics_enabled", true)
	var deadline := float(scheduler.call("get_clock")) + 0.5
	for target_index in range(target_count):
		var probe := DeadlineProbe.new()
		probe.name = "DueDeadlineProbe%d" % target_index
		test_root.add_child(probe)
		probes.append(probe)
		scheduler.call(
			"schedule_target",
			probe,
			deadline,
			&"_on_test_deadline"
		)
	scheduler.call("reset_performance_metrics")
	var dispatch_started_usec := Time.get_ticks_usec()
	scheduler.call("advance_for_test", 0.5)
	var dispatch_usec := Time.get_ticks_usec() - dispatch_started_usec
	var metrics := scheduler.call("get_performance_metrics") as Dictionary
	var callback_count := 0
	for probe in probes:
		callback_count += probe.callback_count
	_expect(
		callback_count == target_count
		and int(metrics.get("deadline_callbacks", -1)) == target_count
		and int(scheduler.call("get_active_target_count")) == 0
		and int(scheduler.call("get_heap_size")) == 0,
		"A coincident deadline cohort must dispatch each target exactly once and drain the indexed heap."
	)
	print(
		"ENEMY_COLLECTIBLE_STATUS_DUE_COHORT targets=%d dispatch_usec=%d"
		% [target_count, dispatch_usec]
	)
	for probe in probes:
		probe.queue_free()
	await process_frame


func _test_recurring_cohort_rebuild(target_count: int) -> void:
	var probes: Array[DeadlineProbe] = []
	scheduler.call("clear_all")
	scheduler.call("set_performance_metrics_enabled", true)
	var deadline := float(scheduler.call("get_clock")) + 0.5
	for target_index in range(target_count):
		var probe := DeadlineProbe.new()
		probe.name = "RecurringDeadlineProbe%d" % target_index
		probe.repeat_interval = 0.5
		test_root.add_child(probe)
		probes.append(probe)
		scheduler.call(
			"schedule_target",
			probe,
			deadline,
			&"_on_test_deadline"
		)
	scheduler.call("reset_performance_metrics")
	var dispatch_started_usec := Time.get_ticks_usec()
	scheduler.call("advance_for_test", 0.5)
	scheduler.call("advance_for_test", 0.5)
	var dispatch_usec := Time.get_ticks_usec() - dispatch_started_usec
	var metrics := scheduler.call("get_performance_metrics") as Dictionary
	var callback_count := 0
	for probe in probes:
		callback_count += probe.callback_count
	_expect(
		callback_count == target_count * 2
		and int(metrics.get("deadline_callbacks", -1)) == target_count * 2
		and int(metrics.get("bulk_cohort_dispatches", -1)) == 2
		and int(scheduler.call("get_active_target_count")) == target_count
		and int(scheduler.call("get_heap_size")) == target_count,
		"Recurring coincident ticks must rebuild one indexed entry per target and bulk-dispatch again."
	)
	print(
		"ENEMY_COLLECTIBLE_STATUS_RECURRING_COHORT targets=%d waves=2 dispatch_usec=%d"
		% [target_count, dispatch_usec]
	)
	scheduler.call("clear_all")
	for probe in probes:
		probe.queue_free()
	await process_frame


func _spawn_enemy(health: int) -> Enemy:
	var enemy := BASIC_CONFIG.enemy_scene.instantiate() as Enemy
	test_root.add_child(enemy)
	enemy.setup(BASIC_CONFIG, null, null)
	enemy.current_health = health
	enemy.set_physics_process(false)
	return enemy


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
