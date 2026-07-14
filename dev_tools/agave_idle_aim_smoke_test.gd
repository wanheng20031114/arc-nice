extends SceneTree

const AGAVE_SCENE := preload("res://scene/plant_defense/agave_cannon.tscn")
const TEST_SEED := 20260714
const SAMPLE_COUNT := 32

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var fixture := Node2D.new()
	fixture.name = "AgaveIdleAimFixture"
	root.add_child(fixture)
	var cannon := AGAVE_SCENE.instantiate() as AgaveCannon
	var matching_cannon := AGAVE_SCENE.instantiate() as AgaveCannon
	fixture.add_child(cannon)
	fixture.add_child(matching_cannon)

	_expect(
		is_equal_approx(AgaveCannon.IDLE_AIM_LIMIT, deg_to_rad(15.0)),
		"Idle aim must stay inside a 30-degree total arc."
	)
	cannon.set_idle_aim_random_seed(TEST_SEED)
	matching_cannon.set_idle_aim_random_seed(TEST_SEED)
	cannon.call("_start_idle_aim")
	matching_cannon.call("_start_idle_aim")
	_expect(
		is_equal_approx(cannon.idle_aim_timer.wait_time, matching_cannon.idle_aim_timer.wait_time),
		"Equal seeds must reproduce the initial idle interval."
	)

	var previous_rotation := cannon.cannon_pivot.rotation
	var previous_direction := 0
	var maximum_target_offset := 0.0
	var minimum_normal_interval := INF
	var maximum_normal_interval := 0.0
	for step_index in range(SAMPLE_COUNT):
		cannon.call("_on_idle_aim_timer_timeout")
		matching_cannon.call("_on_idle_aim_timer_timeout")
		var rotation_delta := cannon.cannon_pivot.rotation - previous_rotation
		var direction := signi(roundi(rotation_delta * 1000000.0))
		_expect(direction != 0, "Every idle move must have a non-zero direction.")
		if previous_direction != 0:
			_expect(
				direction == -previous_direction,
				"Consecutive idle moves must strictly alternate direction."
			)

		var relative_rotation := (
			cannon.cannon_pivot.rotation - cannon.idle_aim_center_rotation
		)
		var target_offset := absf(relative_rotation)
		maximum_target_offset = maxf(maximum_target_offset, target_offset)
		_expect(
			target_offset >= AgaveCannon.IDLE_AIM_MIN_TARGET_OFFSET - 0.00001
			and target_offset <= AgaveCannon.IDLE_AIM_LIMIT + 0.00001,
			"Every idle target must stay within its authored half arc."
		)
		_expect(
			signi(roundi(relative_rotation * 1000000.0)) == direction,
			"Each target must occupy the half arc matching its move direction."
		)
		_expect(
			is_equal_approx(
				cannon.cannon_pivot.rotation,
				matching_cannon.cannon_pivot.rotation
			)
			and is_equal_approx(
				cannon.idle_aim_timer.wait_time,
				matching_cannon.idle_aim_timer.wait_time
			),
			"Equal seeds must reproduce the complete target and interval sequence."
		)

		var is_burst_followup := step_index % 4 == 2
		if is_burst_followup:
			_expect(
				cannon.idle_aim_timer.wait_time
				>= AgaveCannon.IDLE_AIM_BURST_INTERVAL_MIN
				and cannon.idle_aim_timer.wait_time
				<= AgaveCannon.IDLE_AIM_BURST_INTERVAL_MAX,
				"Burst follow-up intervals must stay in their short random range."
			)
		else:
			minimum_normal_interval = minf(
				minimum_normal_interval,
				cannon.idle_aim_timer.wait_time
			)
			maximum_normal_interval = maxf(
				maximum_normal_interval,
				cannon.idle_aim_timer.wait_time
			)
			_expect(
				cannon.idle_aim_timer.wait_time >= AgaveCannon.IDLE_AIM_INTERVAL_MIN
				and cannon.idle_aim_timer.wait_time <= AgaveCannon.IDLE_AIM_INTERVAL_MAX,
				"Normal idle intervals must stay in their restrained random range."
			)

		previous_rotation = cannon.cannon_pivot.rotation
		previous_direction = direction

	_expect(
		maximum_target_offset >= deg_to_rad(12.0),
		"Seeded idle targets must use the wider arc instead of clustering near center."
	)
	_expect(
		maximum_normal_interval - minimum_normal_interval > 0.01,
		"Seeded normal idle intervals must contain visible timing variation."
	)
	cannon.call("_stop_idle_aim")
	matching_cannon.call("_stop_idle_aim")
	_expect(
		cannon.idle_aim_timer.is_stopped()
		and matching_cannon.idle_aim_timer.is_stopped()
		and not cannon.idle_aim_active
		and not matching_cannon.idle_aim_active,
		"Stopping idle aim must stop both timers and clear runtime activity."
	)

	fixture.queue_free()
	for _cleanup_frame in range(3):
		await process_frame
	if failures.is_empty():
		print("AGAVE_IDLE_AIM_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
