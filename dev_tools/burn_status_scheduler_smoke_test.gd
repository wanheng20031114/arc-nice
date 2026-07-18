extends SceneTree

const NORMAL_BURN_FAMILY := &"fire_sorcerer_fireball_volley"
const ELITE_BURN_FAMILY := &"fire_sorcerer_elite_fireball_volley"
const PERFORMANCE_TARGET_COUNT := 300
const PERFORMANCE_FRAME_COUNT := 60
const FRAME_BUDGET_USEC := 16600


class BurnProbe:
	extends RefCounted

	var tick_count := 0
	var tick_damage_total := 0
	var last_source_family := StringName()

	func receive_burn_tick(
		source_family: StringName,
		tick_damage: int
	) -> bool:
		tick_count += 1
		tick_damage_total += tick_damage
		last_source_family = source_family
		return true


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
	_test_expiry_boundary_matches_enemy_burn()
	_test_three_hundred_active_target_cost()

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
	var target := BurnProbe.new()
	for _ball_index in range(3):
		_apply_burn(target, NORMAL_BURN_FAMILY, 5.0, 5)
	_expect(
		int(scheduler.call("get_active_target_count")) == 1
		and int(scheduler.call("get_source_count", target)) == 1,
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
		"A weaker burn's tick clock must pause while Elite burn is strongest."
	)
	scheduler.call("_advance_active_burns", 0.51)
	_expect(
		target.tick_count == 2
		and target.tick_damage_total == 15
		and target.last_source_family == NORMAL_BURN_FAMILY,
		"Normal burn must resume its paused clock after Elite burn expires."
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
			== PERFORMANCE_TARGET_COUNT,
		"All 300 five-second burns must remain active after the first second."
	)
	_expect(
		p95_usec < FRAME_BUDGET_USEC,
		"300 active burn targets must stay below the 16.6 ms frame budget at p95."
	)


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
