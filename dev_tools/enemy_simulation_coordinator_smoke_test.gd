extends SceneTree

const POLICY := preload(
	"res://scene/combat/simulation/enemy_simulation_policy.gd"
)
const COORDINATOR := preload(
	"res://scene/combat/simulation/enemy_simulation_coordinator.gd"
)
const TEST_DELTA := 1.0 / 60.0


class TestScheduledEnemy extends Enemy:
	var test_name: StringName
	var simulation_call_count := 0
	var received_ticks: Array[int] = []
	var received_tokens: Array[int] = []
	var call_log: Array[StringName]
	var on_simulate: Callable


	func _init(
		fixture_name: StringName,
		shared_call_log: Array[StringName]
	) -> void:
		test_name = fixture_name
		call_log = shared_call_log


	func supports_centralized_authoritative_simulation() -> bool:
		return true


	func simulate_authoritative_physics_step(
		delta: float,
		tick: int,
		token: int
	) -> void:
		simulation_call_count += 1
		received_ticks.append(tick)
		received_tokens.append(token)
		call_log.append(test_name)
		if on_simulate.is_valid():
			on_simulate.call(self, delta, tick, token)


var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	await _test_registration_during_tick_is_deferred()
	await _test_stable_simulation_id_order()
	await _test_suspend_and_resume()
	await _test_unregister_during_iteration()
	await _test_mode_rollback_waits_for_tick_boundary()
	await _test_token_mismatch_is_rejected()
	_test_clear_removes_every_registration()
	_test_empty_registry_stops_processing()
	_test_legacy_mode_does_not_take_ownership()
	var result := {
		"status": "ok" if failures.is_empty() else "failed",
		"failures": failures.duplicate(),
	}
	print("ENEMY_SIMULATION_COORDINATOR_JSON %s" % JSON.stringify(result))
	if failures.is_empty():
		print("ENEMY_SIMULATION_COORDINATOR_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_registration_during_tick_is_deferred() -> void:
	var coordinator = _new_compat_coordinator()
	var call_log: Array[StringName] = []
	var registrar := TestScheduledEnemy.new(&"registrar", call_log)
	var newcomer := TestScheduledEnemy.new(&"newcomer", call_log)
	var registration_state := {"registered": false, "token": 0}
	registrar.on_simulate = func(
		_enemy: TestScheduledEnemy,
		_delta: float,
		_tick: int,
		_token: int
	) -> void:
		if registration_state["registered"]:
			return
		registration_state["registered"] = true
		registration_state["token"] = coordinator.try_register_enemy(newcomer)
	var registrar_token: int = coordinator.try_register_enemy(registrar)
	_expect(registrar_token > 0, "COMPAT_60 must register a supported enemy.")

	coordinator._physics_process(TEST_DELTA)
	_expect(
		registrar.simulation_call_count == 0,
		"An enemy must not advance in the physics frame where it registered."
	)
	var same_frame_metrics: Dictionary = coordinator.get_metrics()
	_expect(
		int(same_frame_metrics["activation_skips"]) == 1,
		"Same-frame registration must be recorded as an activation skip."
	)

	await physics_frame
	coordinator._physics_process(TEST_DELTA)
	_expect(
		registrar.simulation_call_count == 1,
		"The registrar must advance exactly once on its first scheduled tick."
	)
	_expect(
		int(registration_state["token"]) > 0,
		"Registration requested during iteration must still return ownership."
	)
	_expect(
		newcomer.simulation_call_count == 0,
		"An enemy registered during the current tick must not advance in that tick."
	)

	coordinator._physics_process(TEST_DELTA)
	_expect(
		newcomer.simulation_call_count == 0,
		"A second dispatch in the registration frame must still skip the newcomer."
	)
	await physics_frame
	coordinator._physics_process(TEST_DELTA)
	_expect(
		newcomer.simulation_call_count == 1,
		"An enemy registered during a tick must advance exactly once on the next tick."
	)
	_expect(
		newcomer.received_tokens == [int(registration_state["token"])],
		"The deferred enemy must receive its current registration token."
	)
	_dispose_fixture(coordinator, [registrar, newcomer])


func _test_stable_simulation_id_order() -> void:
	var coordinator = _new_compat_coordinator()
	var call_log: Array[StringName] = []
	var enemies: Array[TestScheduledEnemy] = [
		TestScheduledEnemy.new(&"charlie", call_log),
		TestScheduledEnemy.new(&"alpha", call_log),
		TestScheduledEnemy.new(&"bravo", call_log),
	]
	var tokens: Array[int] = []
	var ordered_entries: Array[Dictionary] = []
	for enemy in enemies:
		var token: int = coordinator.try_register_enemy(enemy)
		var simulation_id: int = coordinator.get_simulation_id(enemy, token)
		tokens.append(token)
		ordered_entries.append({"id": simulation_id, "name": enemy.test_name})
		_expect(token > 0, "Every supported fixture enemy must receive a token.")
		_expect(simulation_id > 0, "Every owned enemy must receive a stable ID.")
	ordered_entries.sort_custom(func(left: Dictionary, right: Dictionary) -> bool:
		return int(left["id"]) < int(right["id"])
	)
	var expected_order: Array[StringName] = []
	for entry in ordered_entries:
		expected_order.append(StringName(entry["name"]))

	await physics_frame
	coordinator._physics_process(TEST_DELTA)
	_expect(
		call_log == expected_order,
		"A tick must visit enemies in ascending stable simulation-ID order."
	)
	call_log.clear()
	await physics_frame
	coordinator._physics_process(TEST_DELTA)
	_expect(
		call_log == expected_order,
		"Stable simulation-ID order must be identical on subsequent ticks."
	)
	for enemy_index in range(enemies.size()):
		var enemy := enemies[enemy_index]
		_expect(
			enemy.simulation_call_count == 2,
			"Each registered enemy must advance exactly once per coordinator tick."
		)
		_expect(
			enemy.received_tokens == [tokens[enemy_index], tokens[enemy_index]],
			"Every authoritative step must carry the enemy's current token."
		)
		_expect(
			enemy.received_ticks.size() == 2
			and enemy.received_ticks[1] > enemy.received_ticks[0],
			"Authoritative coordinator ticks must increase monotonically."
		)
	_dispose_fixture(coordinator, enemies)


func _test_suspend_and_resume() -> void:
	var coordinator = _new_compat_coordinator()
	var call_log: Array[StringName] = []
	var enemy := TestScheduledEnemy.new(&"suspendable", call_log)
	var token: int = coordinator.try_register_enemy(enemy)
	await physics_frame
	coordinator._physics_process(TEST_DELTA)
	coordinator.suspend_enemy(enemy, token)
	await physics_frame
	coordinator._physics_process(TEST_DELTA)
	_expect(
		enemy.simulation_call_count == 1,
		"A suspended enemy must remain owned without being advanced."
	)
	_expect(
		coordinator.owns_enemy(enemy, token),
		"Suspension must not discard registration ownership."
	)

	coordinator.resume_enemy(enemy, token)
	await physics_frame
	coordinator._physics_process(TEST_DELTA)
	_expect(
		enemy.simulation_call_count == 2,
		"A resumed enemy must advance once on the following tick."
	)
	_expect(
		enemy.received_tokens.back() == token,
		"Resume must preserve the original registration token."
	)
	_dispose_fixture(coordinator, [enemy])


func _test_unregister_during_iteration() -> void:
	var coordinator = _new_compat_coordinator()
	var call_log: Array[StringName] = []
	var remover := TestScheduledEnemy.new(&"remover", call_log)
	var victim := TestScheduledEnemy.new(&"victim", call_log)
	var remover_token: int = coordinator.try_register_enemy(remover)
	var victim_token: int = coordinator.try_register_enemy(victim)
	remover.on_simulate = func(
		current_enemy: TestScheduledEnemy,
		_delta: float,
		_tick: int,
		current_token: int
	) -> void:
		coordinator.unregister_enemy(victim, victim_token)
		coordinator.unregister_enemy(current_enemy, current_token)

	await physics_frame
	coordinator._physics_process(TEST_DELTA)
	_expect(
		remover.simulation_call_count == 1,
		"An enemy may unregister itself from inside its simulation callback."
	)
	_expect(
		victim.simulation_call_count == 0,
		"An enemy removed before its turn must not receive a stale callback."
	)
	_expect(
		not coordinator.owns_enemy(remover, remover_token)
		and not coordinator.owns_enemy(victim, victim_token),
		"Iteration-time unregister must remove both exact registrations."
	)
	_expect(
		not coordinator.is_physics_processing(),
		"Removing the final entries during iteration must stop physics processing."
	)
	_dispose_fixture(coordinator, [remover, victim])


func _test_mode_rollback_waits_for_tick_boundary() -> void:
	var coordinator = _new_compat_coordinator()
	var call_log: Array[StringName] = []
	var requester := TestScheduledEnemy.new(&"requester", call_log)
	var final_entry := TestScheduledEnemy.new(&"final_entry", call_log)
	requester.on_simulate = func(
		_enemy: TestScheduledEnemy,
		_delta: float,
		_tick: int,
		_token: int
	) -> void:
		coordinator.set_mode(POLICY.Mode.LEGACY)
	coordinator.try_register_enemy(requester)
	coordinator.try_register_enemy(final_entry)

	await physics_frame
	coordinator._physics_process(TEST_DELTA)
	_expect(
		call_log == [&"requester", &"final_entry"],
		"A rollback request inside iteration must complete the current stable tick."
	)
	_expect(
		coordinator.mode == POLICY.Mode.LEGACY,
		"The deferred rollback must commit immediately after the tick boundary."
	)
	coordinator._physics_process(TEST_DELTA)
	_expect(
		requester.simulation_call_count == 1
		and final_entry.simulation_call_count == 1,
		"No centralized callback may run after the boundary rollback."
	)
	_dispose_fixture(coordinator, [requester, final_entry])


func _test_token_mismatch_is_rejected() -> void:
	var coordinator = _new_compat_coordinator()
	var call_log: Array[StringName] = []
	var enemy := TestScheduledEnemy.new(&"token_guard", call_log)
	var token: int = coordinator.try_register_enemy(enemy)
	var wrong_token := token + 1
	var simulation_id: int = coordinator.get_simulation_id(enemy, token)
	_expect(
		coordinator.get_simulation_id(enemy, wrong_token) != simulation_id,
		"A mismatched token must not expose the owned simulation ID."
	)
	_expect(
		not coordinator.owns_enemy(enemy, wrong_token),
		"A mismatched token must never satisfy ownership."
	)

	coordinator.suspend_enemy(enemy, wrong_token)
	await physics_frame
	coordinator._physics_process(TEST_DELTA)
	_expect(
		enemy.simulation_call_count == 1,
		"A mismatched suspend token must not alter the live registration."
	)
	coordinator.unregister_enemy(enemy, wrong_token)
	_expect(
		coordinator.owns_enemy(enemy, token),
		"A mismatched unregister token must preserve the live registration."
	)
	coordinator.resume_enemy(enemy, wrong_token)
	await physics_frame
	coordinator._physics_process(TEST_DELTA)
	_expect(
		enemy.simulation_call_count == 2,
		"Mismatched token operations must leave scheduling unchanged."
	)
	_dispose_fixture(coordinator, [enemy])


func _test_clear_removes_every_registration() -> void:
	var coordinator = _new_compat_coordinator()
	var call_log: Array[StringName] = []
	var first := TestScheduledEnemy.new(&"first", call_log)
	var second := TestScheduledEnemy.new(&"second", call_log)
	var first_token: int = coordinator.try_register_enemy(first)
	var second_token: int = coordinator.try_register_enemy(second)
	coordinator.clear()
	coordinator._physics_process(TEST_DELTA)
	_expect(
		first.simulation_call_count == 0 and second.simulation_call_count == 0,
		"clear() must prevent all former registrations from advancing."
	)
	_expect(
		not coordinator.owns_enemy(first, first_token)
		and not coordinator.owns_enemy(second, second_token),
		"clear() must invalidate every registration token."
	)
	_expect(
		not coordinator.is_physics_processing(),
		"clear() must stop coordinator physics processing."
	)
	_dispose_fixture(coordinator, [first, second])


func _test_empty_registry_stops_processing() -> void:
	var coordinator = _new_compat_coordinator()
	var call_log: Array[StringName] = []
	var enemy := TestScheduledEnemy.new(&"single", call_log)
	_expect(
		not coordinator.is_physics_processing(),
		"A COMPAT_60 coordinator with an empty registry must stay idle."
	)
	var token: int = coordinator.try_register_enemy(enemy)
	_expect(
		coordinator.is_physics_processing(),
		"The first valid registration must enable coordinator processing."
	)
	coordinator.unregister_enemy(enemy, token)
	_expect(
		not coordinator.is_physics_processing(),
		"Removing the final registration must disable coordinator processing."
	)
	_dispose_fixture(coordinator, [enemy])


func _test_legacy_mode_does_not_take_ownership() -> void:
	var coordinator := COORDINATOR.new()
	coordinator._ready()
	coordinator.set_mode(POLICY.Mode.LEGACY)
	var call_log: Array[StringName] = []
	var enemy := TestScheduledEnemy.new(&"legacy", call_log)
	var token: int = coordinator.try_register_enemy(enemy)
	_expect(token <= 0, "LEGACY mode must reject centralized registration.")
	_expect(
		not coordinator.owns_enemy(enemy, token),
		"LEGACY mode must never claim ownership of an enemy."
	)
	_expect(
		not coordinator.is_physics_processing(),
		"LEGACY mode must leave centralized physics processing disabled."
	)
	coordinator._physics_process(TEST_DELTA)
	_expect(
		enemy.simulation_call_count == 0,
		"Manually invoking the coordinator in LEGACY mode must not advance enemies."
	)
	_dispose_fixture(coordinator, [enemy])


func _new_compat_coordinator():
	var coordinator := COORDINATOR.new()
	coordinator._ready()
	coordinator.set_mode(POLICY.Mode.COMPAT_60)
	return coordinator


func _dispose_fixture(coordinator: Node, enemies: Array) -> void:
	coordinator.call("clear")
	for enemy in enemies:
		if is_instance_valid(enemy):
			enemy.free()
	if is_instance_valid(coordinator):
		coordinator.free()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
