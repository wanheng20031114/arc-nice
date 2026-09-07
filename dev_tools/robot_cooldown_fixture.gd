extends Node

const Clock := preload("res://scene/combat/simulation/enemy_simulation_step_clock.gd")
const Cooldown := preload("res://scene/combat/simulation/enemy_simulation_cooldown.gd")

var result: Dictionary = {}
var failures: Array[String] = []
var assertions := 0
var runtime: TowerDefenseGame
var metrics := {}


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	_check_exact_clock()
	await _check_authored_robot()
	metrics["assertions"] = assertions
	metrics["failures"] = failures
	print("ROBOT_COOLDOWN_REGRESSION ", JSON.stringify(metrics))
	var file := FileAccess.open("res://dev_tools/output/robot_cooldown_regression.json", FileAccess.WRITE)
	file.store_string(JSON.stringify(metrics, "\t"))
	file.close()
	result["exit_code"] = 0 if failures.is_empty() else 1
	queue_free()


func _check_exact_clock() -> void:
	for initial in [0.0, 0.1, 0.5, 1.1, 2.6, 4.0]:
		for quantum in [1.0 / 30, 1.0 / 60, 1.0 / 120]:
			var clock := Clock.new()
			var timer := Cooldown.new()
			timer.set_remaining(initial)
			timer.bind_clock(clock)
			var expected: float = initial
			for tick in 700:
				var delta: float = quantum
				if tick >= 17 and tick < 28:
					delta *= 0.25
				elif tick >= 40 and tick < 44:
					delta = 0.0
				elif tick >= 150:
					delta *= 2.0
				clock.advance(delta)
				expected = maxf(expected - delta, 0.0)
				if tick == 0:
					timer.advance_event(delta)
				if tick % 3 == 0 or tick % 17 == 0:
					_check(timer.get_remaining() == expected, "Sparse cooldown equals every authored float subtraction exactly")
					_check(timer.get_remaining() == expected, "Repeated decision reads never consume a second tick")
			_check(clock.epoch_ticks.size() == 6, "Clock storage follows six delta epochs, not 700 physics ticks")
	var clock := Clock.new()
	var timer := Cooldown.new()
	timer.set_remaining(2.0)
	timer.bind_clock(clock)
	# A registration may wait several coordinator ticks before its activation.
	for tick in 8:
		clock.advance(0.1)
	_check(timer.get_remaining() == 2.0, "An unadmitted registration does not consume another enemy's clock ticks")
	timer.advance_event(0.1)
	_check(timer.get_remaining() == 1.9, "First admitted event consumes only its own current quantum")
	timer.detach_clock()
	for tick in 20:
		clock.advance(0.1)
	_check(timer.get_remaining() == 1.9, "A suspended or retired registration keeps its exact cooldown")
	timer.bind_clock(clock)
	clock.advance(0.025)
	timer.advance_event(0.025)
	_check(timer.get_remaining() == 1.9 - 0.025, "Resumption consumes only the first resumed quantum")
	timer.detach_clock()
	timer.advance_event(0.2)
	_check(timer.get_remaining() == (1.9 - 0.025) - 0.2, "Returning to individual simulation retains authored subtraction")


func _check_authored_robot() -> void:
	(get_node("/root/RunState") as RunStateStore).begin_new_run(&"weishidaier", false)
	runtime = load("res://scene/game_modes/tower_defense/tower_defense_game.tscn").instantiate()
	runtime.auto_start_waves = false
	runtime.day_phase_announcements_enabled = false
	runtime.defer_runtime_activation()
	get_tree().root.add_child(runtime)
	get_tree().current_scene = runtime
	var deadline := Time.get_ticks_msec() + 30000
	while not runtime.is_runtime_preparation_complete() and Time.get_ticks_msec() < deadline:
		if runtime.is_runtime_preparation_failed():
			break
		await get_tree().process_frame
	_check(runtime.is_runtime_preparation_complete(), "Actual tower runtime finishes preparation")
	if runtime.is_runtime_preparation_complete():
		runtime.activate_runtime()
		runtime.process_mode = Node.PROCESS_MODE_DISABLED
		var coordinator := runtime.get_enemy_simulation_coordinator()
		coordinator.set_mode(EnemySimulationPolicy.Mode.LAYERED_AREA)
		for hz in [30, 60, 120]:
			var reference := _trace_robot(false, hz)
			var optimized := _trace_robot(true, hz)
			_check(reference["trace"] == optimized["trace"], "Authored state/float/position/warning traces match with sleep on/off at %d Hz" % hz)
			_check(int(optimized["event_count"]) < int(reference["event_count"]), "Positive CHASE cooldown removes real family event visits")
			metrics["trace_%d_hz" % hz] = {"reference_events": reference["event_count"], "sleep_events": optimized["event_count"], "ticks": 600, "windups": optimized["windups"]}
		await _check_live_lifecycle(coordinator)
		var old_hz := Engine.physics_ticks_per_second
		Engine.physics_ticks_per_second = 240
		var full_reference := await _trace_full_scheduler(false, coordinator)
		var full_optimized := await _trace_full_scheduler(true, coordinator)
		Engine.physics_ticks_per_second = old_hz
		_check(full_reference["trace"] == full_optimized["trace"], "Real coordinator sleep on/off produces identical state, cooldown and native position traces")
		_check(int(full_optimized["events"]) < int(full_reference["events"]), "Real sparse scheduler omits CHASE events with a positive cooldown")
		metrics["full_scheduler"] = {"reference_events": full_reference["events"], "sleep_events": full_optimized["events"], "ticks": 240}
		runtime.prepare_for_scene_teardown()
	runtime.queue_free()
	runtime = null
	for frame in 4:
		await get_tree().process_frame


func _spawn_robot() -> CombatRobot:
	var config := load("res://resources/config/enemies/combat_robot_elite.tres").duplicate() as EnemyConfig
	var robot := config.enemy_scene.instantiate() as CombatRobot
	robot.disable_mode = CollisionObject2D.DISABLE_MODE_KEEP_ACTIVE
	robot.config = config
	runtime.enemy_container.add_child(robot)
	robot.setup(config, runtime.player, runtime.grid_pathfinder, runtime)
	robot.position = Vector2(120, 120)
	return robot


func _trace_robot(sleep_enabled: bool, hz: int) -> Dictionary:
	var robot := _spawn_robot()
	robot._release_authoritative_simulation_driver(Enemy.AuthoritativeSimulationDriver.INDIVIDUAL)
	robot.set_physics_process(false)
	# The old branch runs the authored scalar cooldown every event. The sleep
	# branch runs the real production helper, while both use native robot nodes.
	var clock := Clock.new()
	if sleep_enabled:
		robot._dash_cooldown.bind_clock(clock)
	robot.chase_cooldown_event_sleep_enabled = sleep_enabled
	robot.dash_cooldown_left = 0.4
	var trace := []
	var event_count := 0
	var windups := 0
	var saw_dash_first_frame := false
	var previous_state := CombatRobot.CombatState.CHASE
	for tick in 600:
		var delta := 1.0 / float(hz)
		if tick >= 75 and tick < 131:
			delta *= 0.5
		if tick >= 350:
			delta *= 2.0
		clock.advance(delta)
		if tick == 0 or not robot._can_sleep_layered_area_family_event_phase():
			if sleep_enabled:
				robot._advance_layered_area_family_event_phase(delta)
			else:
				_advance_original_family_event(robot, delta)
			event_count += 1
		# A moving objective changes between ordinary acquisition opportunities.
		runtime.player.global_position = robot.global_position + Vector2(60 if tick < 180 else -60, 0)
		if tick % 3 == 0 and robot.combat_state == CombatRobot.CombatState.CHASE:
			var candidate: Node2D = null if tick >= 120 and tick < 144 else runtime.player
			if candidate != null and robot._try_start_windup(candidate):
				windups += 1
		if previous_state == CombatRobot.CombatState.WINDUP and robot.combat_state == CombatRobot.CombatState.DASH:
			_check(not robot.layered_dash_step_prepared, "WINDUP to DASH transition does not submit movement on the transition tick")
			saw_dash_first_frame = true
		if robot.combat_state == CombatRobot.CombatState.DASH and robot.layered_dash_step_prepared:
			robot._simulate_layered_area_motion_body(delta)
		trace.append([robot.combat_state, robot.dash_cooldown_left, robot.windup_time_left, robot.dash_time_left, robot.position, robot.dash_direction, robot.layered_dash_step_prepared, robot.windup_warning.visible, robot.windup_warning.polygon])
		previous_state = robot.combat_state
	_check(saw_dash_first_frame and windups > 0, "Trace contains real windup, dash and cooldown cycles")
	_check(not robot.supports_indexed_touch_authority(), "Compound robot retains authored Area2D Player/Plant contact authority")
	robot.free()
	return {"trace": trace, "event_count": event_count, "windups": windups}


func _advance_original_family_event(robot: CombatRobot, delta: float) -> void:
	# Literal pre-optimization family event: this reference does not invoke the
	# new helper's event advancement or new production family event method.
	robot.layered_dash_step_time = 0.0
	robot.layered_dash_speed = 0.0
	robot.layered_dash_step_prepared = false
	var previous_cooldown := robot.dash_cooldown_left
	if previous_cooldown > 0.0:
		robot.dash_cooldown_left = maxf(previous_cooldown - maxf(delta, 0.0), 0.0)
	match robot.combat_state:
		CombatRobot.CombatState.WINDUP:
			robot._update_windup(delta)
		CombatRobot.CombatState.DASH:
			robot._prepare_layered_dash_step(delta)


func _trace_full_scheduler(sleep_enabled: bool, coordinator: EnemySimulationCoordinator) -> Dictionary:
	var robot := _spawn_robot()
	robot.chase_cooldown_event_sleep_enabled = sleep_enabled
	robot.navigation_update_frame_offset = -int(Engine.get_physics_frames()) - 1
	robot.dash_cooldown_left = 0.4
	var trace := []
	var initial_events := coordinator._metric_event_phase_count
	var saw_windup := false
	var saw_dash := false
	for tick in 240:
		await get_tree().physics_frame
		var delta := 1.0 / 60
		if tick >= 75 and tick < 130:
			delta = 1.0 / 120
		runtime.player.global_position = robot.global_position + Vector2(60, 0)
		coordinator._physics_process(delta)
		saw_windup = saw_windup or robot.combat_state == CombatRobot.CombatState.WINDUP
		saw_dash = saw_dash or robot.combat_state == CombatRobot.CombatState.DASH
		trace.append([robot.combat_state, robot.dash_cooldown_left, robot.windup_time_left, robot.dash_time_left, robot.position])
	_check(saw_windup and saw_dash, "Real coordinator wakes a sleeping CHASE robot and completes WINDUP into DASH")
	var events := coordinator._metric_event_phase_count - initial_events
	robot.free()
	return {"trace": trace, "events": events}


func _check_live_lifecycle(coordinator: EnemySimulationCoordinator) -> void:
	var robot := _spawn_robot()
	_check(robot.enemy_simulation_coordinator == coordinator, "Real robot binds the coordinator clock through production setup")
	var clock = coordinator.gameplay_step_clock
	robot.dash_cooldown_left = 2.0
	clock.advance(0.1)
	robot._update_dash_cooldown(0.1)
	robot.set_authoritative_simulation_enabled(false)
	var frozen := robot.dash_cooldown_left
	for tick in 8:
		clock.advance(0.1)
	_check(robot.dash_cooldown_left == frozen, "Production suspension freezes an individual robot while other clock steps advance")
	robot.set_authoritative_simulation_enabled(true)
	clock.advance(0.02)
	robot._update_dash_cooldown(0.02)
	_check(robot.dash_cooldown_left == frozen - 0.02, "Production resume respects the registration fence")
	_check(coordinator.suspend_enemy(robot, robot.enemy_simulation_token), "Direct coordinator suspension accepts its live token")
	var direct_frozen := robot.dash_cooldown_left
	clock.advance(0.5)
	_check(robot.dash_cooldown_left == direct_frozen, "Direct coordinator suspension invokes the timer lifecycle hook")
	_check(coordinator.resume_enemy(robot, robot.enemy_simulation_token), "Direct coordinator resumption accepts its live token")
	clock.advance(0.01)
	robot._update_dash_cooldown(0.01)
	_check(robot.dash_cooldown_left == direct_frozen - 0.01, "Direct coordinator resumption excludes the suspended interval")
	robot._release_authoritative_simulation_driver(Enemy.AuthoritativeSimulationDriver.INDIVIDUAL)
	var released := robot.dash_cooldown_left
	clock.advance(0.5)
	_check(robot.dash_cooldown_left == released, "Retirement detaches the old coordinator clock")
	_check(robot.try_attach_to_enemy_simulation_coordinator(coordinator), "Retired robot can be registered again with a fresh token")
	clock.advance(0.01)
	robot._update_dash_cooldown(0.01)
	_check(robot.dash_cooldown_left == released - 0.01, "Re-registration preserves remaining cooldown without the detached gap")
	# Native SceneTree pause advances Engine.physics_frames, not this clock.
	var before_frame := Engine.get_physics_frames()
	var before_clock_tick: int = clock.tick
	var before_pause := robot.dash_cooldown_left
	get_tree().paused = true
	await get_tree().create_timer(0.25, true).timeout
	_check(Engine.get_physics_frames() > before_frame, "Native pause probe spans real wall-clock physics frames")
	_check(clock.tick == before_clock_tick and robot.dash_cooldown_left == before_pause, "Native pause leaves logical tick and lazy cooldown frozen")
	get_tree().paused = false
	_check(robot.dash_cooldown_left == before_pause, "Unpause does not consume paused wall frames")
	coordinator.set_mode(EnemySimulationPolicy.Mode.LEGACY)
	_check(robot.enemy_simulation_coordinator == null, "Changing mode to LEGACY releases clock ownership")
	var legacy_remaining := robot.dash_cooldown_left
	clock.advance(0.1)
	_check(robot.dash_cooldown_left == legacy_remaining, "Released legacy cooldown ignores the old shared clock")
	robot._update_dash_cooldown(0.05)
	_check(robot.dash_cooldown_left == legacy_remaining - 0.05, "Legacy physics resumes actual scalar countdown after coordinator release")
	coordinator.set_mode(EnemySimulationPolicy.Mode.LAYERED_AREA)
	_check(robot.enemy_simulation_coordinator == coordinator, "Returning to LAYERED_AREA claims and binds the authored robot")
	coordinator.clear(true)
	_check(robot.enemy_simulation_coordinator == null, "Coordinator clear releases the last timer owner")
	var cleared_remaining := robot.dash_cooldown_left
	clock.advance(0.1)
	robot._update_dash_cooldown(0.025)
	_check(robot.dash_cooldown_left == cleared_remaining - 0.025, "Cleared robot retains a progressing individual cooldown")
	robot.free()


func _check(condition: bool, message: String) -> void:
	assertions += 1
	if not condition:
		failures.append(message)
		push_error(message)
