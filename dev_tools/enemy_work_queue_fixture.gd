extends Node

class CountedWakeEnemy:
	extends Enemy
	var wake_count := 0

	func request_layered_area_urgent_decision() -> void:
		wake_count += 1
		super.request_layered_area_urgent_decision()

class LegacyCoordinator:
	extends EnemySimulationCoordinator

	func _insert_event_work_registration(registration: Registration, physics_frame: int, minimum_index: int = 0) -> void:
		if registration == null or registration.tombstone:
			return
		if registration.event_work_physics_frame == physics_frame:
			return
		registration.event_work_physics_frame = physics_frame
		registration.event_ready_enqueued = false
		var low := clampi(minimum_index, 0, _event_work_registrations.size())
		var high := _event_work_registrations.size()
		while low < high:
			var middle := (low + high) >> 1
			if _event_work_registrations[middle].simulation_id < registration.simulation_id:
				low = middle + 1
			else:
				high = middle
		_event_work_registrations.insert(low, registration)

	func _insert_decision_work_registration(registration: Registration, physics_frame: int, _urgent: bool, minimum_index: int = 0) -> void:
		if registration == null or registration.tombstone:
			return
		if registration.decision_work_physics_frame == physics_frame:
			return
		registration.decision_work_physics_frame = physics_frame
		var low := clampi(minimum_index, 0, _decision_work_registrations.size())
		var high := _decision_work_registrations.size()
		while low < high:
			var middle := (low + high) >> 1
			if _decision_work_registrations[middle].simulation_id < registration.simulation_id:
				low = middle + 1
			else:
				high = middle
		_decision_work_registrations.insert(low, registration)

var result: Dictionary = {}
var failures: Array[String] = []
var assertions := 0
var metrics := {}


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	var prototype := Enemy.new()
	_check_ordering(prototype)
	_check_phase_fences()
	_check_movement_invalidation_notifications()
	if "--benchmark" in OS.get_cmdline_user_args():
		_benchmark(prototype)
	prototype.free()
	metrics["assertions"] = assertions
	metrics["failures"] = failures
	print("ENEMY_WORK_QUEUE_REGRESSION ", JSON.stringify(metrics))
	var file := FileAccess.open("res://dev_tools/output/enemy_work_queue_regression.json", FileAccess.WRITE)
	file.store_string(JSON.stringify(metrics, "\t"))
	file.close()
	result["exit_code"] = 0 if failures.is_empty() else 1
	queue_free()


func _registrations(enemy: Enemy, count: int) -> Array[EnemySimulationCoordinator.Registration]:
	var records: Array[EnemySimulationCoordinator.Registration] = []
	for index in count:
		records.append(EnemySimulationCoordinator.Registration.new(enemy, index + 1, index + 1, -1))
	return records


func _ids(records: Array[EnemySimulationCoordinator.Registration]) -> Array[int]:
	var ids: Array[int] = []
	for registration in records:
		ids.append(registration.simulation_id)
	return ids


func _check_ordering(prototype: Enemy) -> void:
	for mode in ["event", "decision"]:
		for ordering in ["sorted", "reverse", "permuted"]:
			var coordinator := EnemySimulationCoordinator.new()
			var records := _registrations(prototype, 300)
			var expected: Array[int] = []
			for index in 300:
				expected.append(index + 1)
				var ordinal: int = index if ordering == "sorted" else (299 - index if ordering == "reverse" else index * 73 % 300)
				if mode == "event":
					coordinator._insert_event_work_registration(records[ordinal], 1)
					coordinator._insert_event_work_registration(records[ordinal], 1)
				else:
					coordinator._insert_decision_work_registration(records[ordinal], 1, false)
					coordinator._insert_decision_work_registration(records[ordinal], 1, true)
			var queue := coordinator._event_work_registrations if mode == "event" else coordinator._decision_work_registrations
			_check(_ids(queue) == expected, mode + " " + ordering + " keeps ascending unique simulation IDs")
			var removed := EnemySimulationCoordinator.Registration.new(prototype, 301, 301, -1)
			removed.tombstone = true
			if mode == "event":
				coordinator._insert_event_work_registration(null, 1)
				coordinator._insert_event_work_registration(removed, 1)
			else:
				coordinator._insert_decision_work_registration(null, 1, false)
				coordinator._insert_decision_work_registration(removed, 1, false)
			_check(queue.size() == 300, mode + " rejects vanished registrations")
			records.clear()
			coordinator.free()
	# The lower fence can be beyond the usual sorted position; never revisit the
	# already-consumed prefix even when a direct diagnostic caller supplies it.
	for mode in ["event", "decision"]:
		var coordinator := EnemySimulationCoordinator.new()
		var records := _registrations(prototype, 5)
		for ordinal in [1, 3, 4]:
			if mode == "event":
				coordinator._insert_event_work_registration(records[ordinal], 2)
			else:
				coordinator._insert_decision_work_registration(records[ordinal], 2, false)
		if mode == "event":
			coordinator._insert_event_work_registration(records[0], 2, 2)
		else:
			coordinator._insert_decision_work_registration(records[0], 2, false, 2)
		var queue := coordinator._event_work_registrations if mode == "event" else coordinator._decision_work_registrations
		_check(_ids(queue) == [2, 4, 1, 5], mode + " preserves the minimum-index consumed-prefix fence")
		coordinator.free()


func _check_phase_fences() -> void:
	var coordinator := EnemySimulationCoordinator.new()
	coordinator._mode = EnemySimulationPolicy.Mode.LAYERED_CONTACT
	var enemies: Array[Enemy] = []
	var records: Array[EnemySimulationCoordinator.Registration] = []
	var frame := Engine.get_physics_frames()
	for index in 6:
		var enemy := Enemy.new()
		enemies.append(enemy)
		var registration := EnemySimulationCoordinator.Registration.new(enemy, (index + 1) * 5, index + 1, frame - 1)
		registration.uses_physics_phase_decisions = true
		records.append(registration)
		coordinator._registration_by_instance_id[enemy.get_instance_id()] = registration
	for index in [0, 1, 3]:
		coordinator._insert_event_work_registration(records[index], frame)
	coordinator._event_phase_active = true
	coordinator._event_phase_physics_frame = frame
	coordinator._event_phase_cursor = 1
	coordinator._event_phase_current_simulation_id = 10
	_check(coordinator._wake_event_registration(records[2]), "An event wakes a higher-ID registration in the same frame")
	_check(coordinator._wake_event_registration(records[4]), "An event can append a later same-frame registration")
	_check(_ids(coordinator._event_work_registrations) == [5, 10, 15, 20, 25], "Same-frame event insertions retain current cursor and future ordering")
	coordinator._wake_event_registration(records[2])
	coordinator._wake_event_registration(records[0])
	_check(_ids(coordinator._event_work_registrations) == [5, 10, 15, 20, 25] and records[0].event_ready_enqueued,
		"A duplicate wake is idempotent and an already-processed ID waits for the next frame")
	_check(coordinator._event_phase_cursor == 1, "Event insertion cannot rewind the phase cursor")
	coordinator._event_phase_active = false
	for index in [0, 1, 3]:
		coordinator._insert_decision_work_registration(records[index], frame, false)
	coordinator._decision_phase_active = true
	coordinator._decision_phase_physics_frame = frame
	coordinator._decision_phase_cursor = 1
	coordinator._decision_phase_current_simulation_id = 10
	_check(coordinator.mark_enemy_layered_decision_urgent(enemies[2], records[2].token), "An owned same-frame urgent decision is accepted")
	coordinator.mark_enemy_layered_decision_urgent(enemies[4], records[4].token)
	coordinator.mark_enemy_layered_decision_urgent(enemies[0], records[0].token)
	_check(_ids(coordinator._decision_work_registrations) == [5, 10, 15, 20, 25] and records[0].urgent_decision_enqueued,
		"Urgent decisions insert after the current ID and defer an already-processed ID")
	records[5].tombstone = true
	_check(not coordinator.mark_enemy_layered_decision_urgent(enemies[5], records[5].token), "A vanished owner cannot add same-frame work")
	records[5].tombstone = false
	records[5].activation_physics_frame = frame
	_check(not coordinator._ensure_registration_active_for_tick(records[5], frame), "A new registration keeps its initial-frame activation fence")
	_check(coordinator._ensure_registration_active_for_tick(records[5], frame + 1), "The new registration becomes eligible on the following frame")
	coordinator.free()
	records.clear()
	for enemy in enemies:
		enemy.free()


func _benchmark(prototype: Enemy) -> void:
	var measurements := []
	for phase in ["event", "decision"]:
		for mode in ["legacy", "optimized", "optimized", "legacy", "legacy", "optimized", "optimized", "legacy"]:
			var coordinator: EnemySimulationCoordinator = LegacyCoordinator.new() if mode == "legacy" else EnemySimulationCoordinator.new()
			var records := _registrations(prototype, 300)
			var started := Time.get_ticks_usec()
			for frame in range(1, 201):
				if phase == "event":
					coordinator._event_work_registrations.clear()
					for registration in records:
						coordinator._insert_event_work_registration(registration, frame)
				else:
					coordinator._decision_work_registrations.clear()
					for registration in records:
						coordinator._insert_decision_work_registration(registration, frame, false)
			measurements.append({"phase": phase, "mode": mode, "calls": 60000, "elapsed_usec": Time.get_ticks_usec() - started})
			var queue := coordinator._event_work_registrations if phase == "event" else coordinator._decision_work_registrations
			_check(queue.size() == 300 and queue[299].simulation_id == 300, "Microbenchmark inserts the same complete ordered cohort")
			coordinator.free()
	metrics["ordered_queue_abba"] = measurements


func _check_movement_invalidation_notifications() -> void:
	var enemy := CountedWakeEnemy.new()
	var coordinator := EnemySimulationCoordinator.new()
	coordinator._mode = EnemySimulationPolicy.Mode.LAYERED_CONTACT
	var registration := EnemySimulationCoordinator.Registration.new(
		enemy, 1, 1, Engine.get_physics_frames() - 1
	)
	registration.uses_physics_phase_decisions = true
	coordinator._registration_by_instance_id[enemy.get_instance_id()] = registration
	enemy.enemy_simulation_coordinator = coordinator
	enemy.enemy_simulation_token = registration.token
	var first := Player.new()
	var second := Player.new()
	first.peer_id = 1
	second.peer_id = 2
	var navigation_target := Node2D.new()
	var plant := PlantDefense.new()
	# The setter's notification and its public objective_changed signal boundary
	# remain intact. Only the adjacent duplicate after movement invalidation goes.
	enemy.set_target_player(first)
	_check(enemy.wake_count == 2 and enemy.objective_target == first, "Player target change preserves setter + post-signal invalidation notifications")
	enemy.objective_target = null
	enemy.wake_count = 0
	enemy.set_target_player(first)
	_check(enemy.wake_count == 2 and enemy.objective_target == first, "Existing player regains a missing objective without a third identical wake")
	enemy.wake_count = 0
	enemy.set_objective_target(navigation_target)
	_check(enemy.wake_count == 2 and enemy.cached_navigation_move_direction == Vector2.ZERO, "Objective mutation invalidates movement and queues its real notification boundaries")
	enemy.wake_count = 0
	enemy.set_objective_target(navigation_target)
	_check(enemy.wake_count == 0, "Unchanged objective does not invent dirty work")
	var nested_wake := func(_source: Enemy, _target: Node2D) -> void:
		enemy.request_layered_area_urgent_decision()
	enemy.objective_target_changed.connect(nested_wake)
	enemy.wake_count = 0
	enemy.set_objective_target(first)
	_check(enemy.wake_count == 3, "A genuine synchronous objective listener wake is retained")
	enemy.objective_target_changed.disconnect(nested_wake)
	enemy.wake_count = 0
	enemy._on_touch_damage_area_body_entered(navigation_target)
	_check(enemy.wake_count == 1, "A new body invalidates its sweep with one adjacent notification")
	enemy.indexed_touch_authority_enabled = true
	enemy.wake_count = 0
	_check(enemy.synchronize_indexed_touch_contacts([first], []), "Indexed contact batch is accepted")
	_check(enemy.wake_count == 1 and enemy.touched_player == first, "A changed indexed batch selects the player and wakes once")
	enemy.wake_count = 0
	enemy.synchronize_indexed_touch_contacts([first], [])
	_check(enemy.wake_count == 0, "Identical indexed contact batch stays silent")
	enemy.touching_players[second.get_instance_id()] = second
	first.peer_id = 3
	enemy.wake_count = 0
	enemy.refresh_indexed_touch_contact_selection()
	_check(enemy.wake_count == 1 and enemy.touched_player == second, "A new nearest contact selection wakes once")
	enemy.wake_count = 0
	enemy._on_touched_player_died(second)
	_check(enemy.wake_count == 2 and enemy.touched_player == first, "Death preserves removal and following invalidation but removes their adjacent extra wake")
	enemy.wake_count = 0
	enemy._on_touched_plant_removal_started(0, plant)
	_check(enemy.wake_count == 1, "Plant removal callback retains its required invalidation even without an old membership record")
	_check(coordinator._event_ready_registrations.size() == 1 and coordinator._urgent_decision_registrations.size() == 1,
		"All real notifications retain one sparse event/decision registration")
	_check(enemy.layered_area_decision_urgent and registration.event_ready_enqueued and registration.urgent_decision_enqueued,
		"Movement invalidation still reaches the owned sparse queues")
	enemy._clear_touching_players()
	enemy.enemy_simulation_coordinator = null
	enemy.enemy_simulation_token = 0
	coordinator.free()
	enemy.free()
	first.free()
	second.free()
	navigation_target.free()
	plant.free()


func _check(condition: bool, message: String) -> void:
	assertions += 1
	if not condition:
		failures.append(message)
		push_error(message)
