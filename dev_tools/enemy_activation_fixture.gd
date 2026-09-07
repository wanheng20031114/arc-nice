extends Node


# Literal pre-optimization admission methods. In particular, this reference
# never delegates the same-tick liveness decision to the production helper.
class OriginalCoordinator:
	extends EnemySimulationCoordinator

	func _ensure_registration_active_for_tick(registration: Registration, physics_frame: int) -> bool:
		if registration == null or registration.tombstone:
			return false
		if registration.activation_check_physics_frame == physics_frame:
			return _original_registration_remains_active_this_tick(registration, physics_frame)
		registration.activation_check_physics_frame = physics_frame
		registration.active_this_tick = false
		var enemy := registration.enemy
		if enemy == null or not is_instance_valid(enemy) or enemy.is_queued_for_deletion() or enemy.is_dead:
			_mark_tombstone(registration, true)
			return false
		if registration.suspended:
			_metric_suspended_skip_count += 1
			return false
		if physics_frame <= registration.activation_physics_frame:
			_metric_activation_skip_count += 1
			return false
		registration.last_authoritative_physics_frame = physics_frame
		registration.active_this_tick = true
		return true

	func _original_registration_remains_active_this_tick(registration: Registration, physics_frame: int) -> bool:
		if registration == null or registration.tombstone or not registration.active_this_tick \
		or registration.activation_check_physics_frame != physics_frame \
		or registration.last_authoritative_physics_frame != physics_frame or registration.suspended:
			return false
		var enemy := registration.enemy
		if enemy == null or not is_instance_valid(enemy) or enemy.is_queued_for_deletion() or enemy.is_dead:
			_mark_tombstone(registration, true)
			return false
		return true


class Probe:
	extends RefCounted
	var coordinator: EnemySimulationCoordinator
	var enemy: Enemy
	var registration: EnemySimulationCoordinator.Registration

	func _init(original: bool, activation_frame: int = 10) -> void:
		coordinator = OriginalCoordinator.new() if original else EnemySimulationCoordinator.new()
		enemy = Enemy.new()
		registration = EnemySimulationCoordinator.Registration.new(enemy, 1, 1, activation_frame)
		coordinator._registrations.append(registration)
		coordinator._registration_by_instance_id[enemy.get_instance_id()] = registration
		coordinator._registered_count = 1

	func dispose() -> void:
		coordinator.free()
		if is_instance_valid(enemy):
			enemy.free()
		registration = null
		coordinator = null
		enemy = null


var result: Dictionary = {}
var failures: Array[String] = []
var assertions := 0
var metrics := {}


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	_check_null()
	_check_state_matrix()
	_check_phase_mutations()
	_check_activation_and_anchor_fences()
	_check_retirement_and_registration()
	if "--benchmark" in OS.get_cmdline_user_args():
		_benchmark()
	metrics["assertions"] = assertions
	metrics["failures"] = failures
	print("ENEMY_ACTIVATION_REGRESSION ", JSON.stringify(metrics))
	var file := FileAccess.open("res://dev_tools/output/enemy_activation_regression.json", FileAccess.WRITE)
	file.store_string(JSON.stringify(metrics, "\t"))
	file.close()
	result["exit_code"] = 0 if failures.is_empty() else 1
	queue_free()


func _snapshot(probe: Probe) -> Array:
	var r := probe.registration
	var c := probe.coordinator
	return [r.activation_check_physics_frame, r.last_authoritative_physics_frame,
		r.active_this_tick, r.suspended, r.tombstone, is_instance_valid(r.enemy),
		r.scheduled_decision_physics_frame, r.scheduled_event_physics_frame,
		r.event_ready_enqueued, r.urgent_decision_enqueued, r.motion_listed,
		c._registered_count, c._suspended_count, c._tombstone_count,
		c._metric_suspended_skip_count, c._metric_activation_skip_count,
		c._metric_invalid_enemy_release_count, c._metric_suspension_count,
		c._metric_resumption_count, c._metric_unregistration_count,
		c._registration_by_instance_id.has(r.instance_id)]


func _compare_tick(old: Probe, current: Probe, frame: int, label: String, anchor: bool = false) -> bool:
	var expected := old.coordinator._activate_registration_for_tick(old.registration, frame) if anchor \
		else old.coordinator._ensure_registration_active_for_tick(old.registration, frame)
	var actual := current.coordinator._activate_registration_for_tick(current.registration, frame) if anchor \
		else current.coordinator._ensure_registration_active_for_tick(current.registration, frame)
	_check(actual == expected, label + " return equals the original method")
	_check(_snapshot(current) == _snapshot(old), label + " preserves registration mutations and metrics")
	return actual


func _check_null() -> void:
	var current := Probe.new(false)
	var old := Probe.new(true)
	for frame in [-1, 0, 11, 11]:
		_check(not current.coordinator._ensure_registration_active_for_tick(null, frame), "Null registration is rejected")
		_check(not current.coordinator._activate_registration_for_tick(null, frame), "Null anchor is rejected")
	_check(_snapshot(current) == _snapshot(old), "Null rejection does not mutate metrics or another registration")
	current.dispose()
	old.dispose()


func _check_state_matrix() -> void:
	var cases := 0
	for same_tick in [false, true]:
		for last_offset in [-1, 0, 1]:
			for active in [false, true]:
				for suspended in [false, true]:
					for tombstone in [false, true]:
						for condition in ["alive", "dead", "null", "queued", "freed"]:
							var old := Probe.new(true)
							var current := Probe.new(false)
							for probe: Probe in [old, current]:
								var r := probe.registration
								r.activation_check_physics_frame = 11 if same_tick else 10
								r.last_authoritative_physics_frame = 11 + last_offset
								r.active_this_tick = active
								r.suspended = suspended
								r.tombstone = tombstone
								probe.coordinator._suspended_count = int(suspended)
								match condition:
									"dead": probe.enemy.is_dead = true
									"null": r.enemy = null
									"queued": probe.enemy.queue_free()
									"freed": probe.enemy.free()
							var label := "Matrix %d/%d/%s/%s/%s/%s" % [int(same_tick), last_offset, active, suspended, tombstone, condition]
							_compare_tick(old, current, 11, label)
							_compare_tick(old, current, 11, label + " repeated phase")
							_compare_tick(old, current, 12, label + " next tick")
							old.dispose()
							current.dispose()
							cases += 1
	metrics["state_matrix_cases"] = cases


func _check_phase_mutations() -> void:
	for mutation in ["dead", "queued", "freed", "suspended", "suspended_dead"]:
		var old := Probe.new(true)
		var current := Probe.new(false)
		_check(_compare_tick(old, current, 11, mutation + " event phase"), "Live event is initially admitted")
		for probe: Probe in [old, current]:
			match mutation:
				"dead": probe.enemy.is_dead = true
				"queued": probe.enemy.queue_free()
				"freed": probe.enemy.free()
				"suspended", "suspended_dead":
					_check(probe.coordinator.suspend_enemy(probe.enemy, 1), "Live owner suspends between phases")
					if mutation == "suspended_dead":
						probe.enemy.is_dead = true
		_check(not _compare_tick(old, current, 11, mutation + " decision phase"), "Mid-tick removal blocks following decision")
		_check(not _compare_tick(old, current, 11, mutation + " motion phase"), "Mid-tick removal blocks following motion")
		if mutation == "suspended_dead":
			_check(not current.registration.tombstone, "Same-tick suspension still precedes the liveness tombstone check")
			_compare_tick(old, current, 12, "Next tick checks death before suspended counter")
			_check(current.registration.tombstone and current.coordinator._metric_suspended_skip_count == 0,
				"Next-tick dead suspension becomes one invalid release without a suspended skip")
		elif mutation == "suspended":
			for probe: Probe in [old, current]:
				_check(probe.coordinator.resume_enemy(probe.enemy, 1), "Valid owner resumes in the same tick")
			_check(_compare_tick(old, current, 11, "Same-tick resumed live motion"), "Existing same-tick admission resumes")
		old.dispose()
		current.dispose()


func _check_activation_and_anchor_fences() -> void:
	var old := Probe.new(true)
	var current := Probe.new(false)
	for frame in [9, 10, 10, 11, 11, 12, 8, 8, 14]:
		_compare_tick(old, current, frame, "Arbitrary frame %d" % frame)
	_check(current.coordinator._metric_activation_skip_count == 3, "Activation fence counter increments once per newly checked blocked frame")
	_check(not _compare_tick(old, current, 14, "Anchor after layered admission", true), "Anchor cannot replay an admitted layered tick")
	_check(_compare_tick(old, current, 15, "First anchor on a new tick", true), "New anchor is admitted exactly once")
	_check(not _compare_tick(old, current, 15, "Duplicate anchor", true), "Repeated anchor is rejected")
	_check(_compare_tick(old, current, 15, "Layered phases after anchor"), "Idempotent layered phases may share the anchor admission")
	old.dispose()
	current.dispose()
	# Suspension before first admission must not become active just because it was
	# resumed later in the same tick; this fence is different from the case above.
	old = Probe.new(true)
	current = Probe.new(false)
	for probe: Probe in [old, current]:
		probe.coordinator.suspend_enemy(probe.enemy, 1)
	_check(not _compare_tick(old, current, 11, "Suspended first admission"), "Suspended first admission is rejected")
	for probe: Probe in [old, current]:
		probe.coordinator.resume_enemy(probe.enemy, 1)
	_check(not _compare_tick(old, current, 11, "Resume after rejected admission"), "Rejected tick does not gain a second admission")
	_check(_compare_tick(old, current, 12, "Resume on next admission boundary"), "Following tick admits the resumed owner")
	old.dispose()
	current.dispose()


func _check_retirement_and_registration() -> void:
	var old := Probe.new(true)
	var current := Probe.new(false)
	_compare_tick(old, current, 11, "Old owner admitted")
	for probe: Probe in [old, current]:
		_check(probe.coordinator.unregister_enemy(probe.enemy, 1), "Owned registration retires")
	_compare_tick(old, current, 11, "Retired registration later phase")
	for probe: Probe in [old, current]:
		probe.registration = EnemySimulationCoordinator.Registration.new(probe.enemy, 2, 2, 11)
		probe.coordinator._registrations.append(probe.registration)
		probe.coordinator._registration_by_instance_id[probe.enemy.get_instance_id()] = probe.registration
		probe.coordinator._registered_count += 1
		_check(not probe.coordinator.suspend_enemy(probe.enemy, 1), "Retired token cannot suspend the new owner")
		_check(not probe.coordinator.unregister_enemy(probe.enemy, 1), "Retired token cannot unregister the new owner")
	_check(not _compare_tick(old, current, 11, "Replacement owner initial frame"), "Replacement respects its own activation fence")
	_check(_compare_tick(old, current, 12, "Replacement owner following frame"), "Replacement activates with its new token")
	old.dispose()
	current.dispose()


func _benchmark() -> void:
	var measurements := []
	for original in [true, false, false, true, true, false, false, true]:
		var probe := Probe.new(original)
		probe.coordinator._ensure_registration_active_for_tick(probe.registration, 11)
		var accepted := 0
		var started := Time.get_ticks_usec()
		for call_index in 100000:
			if probe.coordinator._ensure_registration_active_for_tick(probe.registration, 11):
				accepted += 1
		var elapsed := Time.get_ticks_usec() - started
		_check(accepted == 100000, "Admission benchmark retains every live phase")
		measurements.append({"original": original, "calls": accepted, "elapsed_usec": elapsed})
		probe.dispose()
	metrics["same_tick_admission_abba"] = measurements


func _check(condition: bool, message: String) -> void:
	assertions += 1
	if not condition:
		failures.append(message)
		push_error(message)
