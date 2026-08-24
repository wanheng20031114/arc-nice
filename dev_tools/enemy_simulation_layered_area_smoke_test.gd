extends SceneTree

const POLICY := preload(
	"res://scene/combat/simulation/enemy_simulation_policy.gd"
)
const COORDINATOR := preload(
	"res://scene/combat/simulation/enemy_simulation_coordinator.gd"
)
const RUNTIME_SCENE := preload(
	"res://dev_tools/fixtures/enemy_gameplay_gateway_test_runtime.tscn"
)
const FAST_CONFIG := preload(
	"res://resources/config/enemies/yuanshi_insect_fast.tres"
)
const TEST_DELTA := 0.037


class LayeredPhaseEnemy extends Enemy:
	var test_name: StringName
	var shared_log: Array[String]
	var decision_interval := 3
	var urgent := true
	var event_count := 0
	var decision_count := 0
	var motion_count := 0
	var received_event_deltas: Array[float] = []
	var received_motion_deltas: Array[float] = []
	var urgent_on_tick := -1
	var rollback_coordinator: EnemySimulationCoordinator = null


	func _init(fixture_name: StringName, phase_log: Array[String]) -> void:
		test_name = fixture_name
		shared_log = phase_log


	func supports_centralized_authoritative_simulation() -> bool:
		return true


	func supports_layered_area_authoritative_simulation() -> bool:
		return true


	func get_layered_area_decision_interval_frames() -> int:
		return decision_interval


	func prepare_layered_area_authoritative_simulation() -> void:
		urgent = true


	func is_layered_area_decision_urgent() -> bool:
		return urgent


	func simulate_layered_area_event_phase(
		delta: float,
		tick: int,
		_token: int
	) -> bool:
		event_count += 1
		received_event_deltas.append(delta)
		shared_log.append("event:%s" % test_name)
		if tick == urgent_on_tick:
			urgent = true
		if rollback_coordinator != null:
			rollback_coordinator.set_mode(POLICY.Mode.LEGACY)
			rollback_coordinator = null
		return true


	func simulate_layered_area_decision_phase(
		_delta: float,
		_tick: int,
		_token: int
	) -> bool:
		decision_count += 1
		urgent = false
		shared_log.append("decision:%s" % test_name)
		return true


	func simulate_layered_area_motion_phase(
		delta: float,
		_tick: int,
		_token: int
	) -> bool:
		motion_count += 1
		received_motion_deltas.append(delta)
		shared_log.append("motion:%s" % test_name)
		return true


class LayeredYuanshiHarness extends YuanshiInsect:
	var event_deltas: Array[float] = []
	var decision_deltas: Array[float] = []
	var motion_deltas: Array[float] = []
	var test_has_contact := false


	func uses_trusted_layered_phase_entrypoints() -> bool:
		# This harness overrides authored contact/motion hooks to inject exact
		# transitions. Keep it on the observable checked path; production Yuanshi
		# instances still use the trusted no-dispatch fast path.
		return false


	func can_sleep_layered_area_event_phase() -> bool:
		# This harness injects contact through an override instead of the authored
		# Area/indexed snapshot, so every event tick must remain observable here.
		return false


	func _update_touch_damage(delta: float) -> void:
		event_deltas.append(delta)


	func _get_navigation_move_direction(delta: float) -> Vector2:
		decision_deltas.append(delta)
		return Vector2.RIGHT


	func _get_move_speed() -> float:
		return 10.0


	func _has_player_contact() -> bool:
		return test_has_contact


	func _update_facing(_move_direction: Vector2) -> void:
		pass


	func _move_after_confirmed_no_contact(delta: float = -1.0) -> void:
		motion_deltas.append(delta)
		global_position += velocity * delta


class NavigationDeadlineYuanshiHarness extends YuanshiInsect:
	const TEST_NAVIGATION_INTERVAL := 8

	var full_decision_frames: Array[int] = []
	var navigation_refresh_frames: Array[int] = []


	func can_sleep_layered_area_event_phase() -> bool:
		return false


	func _update_touch_damage(_delta: float) -> void:
		pass


	func refresh_dynamic_combat_target_decision(simulation_tick: int) -> void:
		full_decision_frames.append(simulation_tick)


	func _get_navigation_move_direction(_delta: float) -> Vector2:
		var physics_frame := Engine.get_physics_frames()
		if (
			cached_navigation_move_direction != Vector2.ZERO
			and navigation_scheduled_refresh_interval_frames
				== TEST_NAVIGATION_INTERVAL
			and physics_frame < navigation_next_refresh_physics_frame
		):
			return cached_navigation_move_direction
		navigation_refresh_frames.append(physics_frame)
		cached_navigation_move_direction = Vector2.RIGHT
		navigation_scheduled_refresh_interval_frames = (
			TEST_NAVIGATION_INTERVAL
		)
		navigation_next_refresh_physics_frame = (
			_get_next_navigation_phase_frame(TEST_NAVIGATION_INTERVAL)
		)
		navigation_zero_direction_retry_frame = 0
		return cached_navigation_move_direction


	func _get_move_speed() -> float:
		return 10.0


	func _update_facing(_move_direction: Vector2) -> void:
		pass


	func _move_after_confirmed_no_contact(delta: float = -1.0) -> void:
		global_position += velocity * delta


class PhysicsCadenceEnemy extends Enemy:
	var test_name: StringName
	var shared_log: Array[String]
	var decision_interval := 1_000_000
	var decision_phase_offset := 0
	var event_count := 0
	var decision_count := 0
	var motion_count := 0
	var on_decision: Callable


	func _init(fixture_name: StringName, phase_log: Array[String]) -> void:
		test_name = fixture_name
		shared_log = phase_log


	func supports_centralized_authoritative_simulation() -> bool:
		return true


	func supports_layered_area_authoritative_simulation() -> bool:
		return true


	func uses_layered_area_physics_phase_decisions() -> bool:
		return true


	func get_layered_area_decision_interval_frames() -> int:
		return decision_interval


	func get_layered_area_decision_phase_offset() -> int:
		return decision_phase_offset


	func simulate_layered_area_event_phase(
		_delta: float,
		_tick: int,
		_token: int
	) -> bool:
		event_count += 1
		shared_log.append("event:%s" % test_name)
		return true


	func simulate_layered_area_decision_phase(
		_delta: float,
		_tick: int,
		_token: int
	) -> bool:
		decision_count += 1
		shared_log.append("decision:%s" % test_name)
		if on_decision.is_valid():
			on_decision.call()
		layered_area_decision_urgent = false
		return true


	func simulate_layered_area_motion_phase(
		_delta: float,
		_tick: int,
		_token: int
	) -> bool:
		motion_count += 1
		shared_log.append("motion:%s" % test_name)
		return true


class SparseSleepingEnemy extends Enemy:
	var event_count := 0
	var decision_count := 0
	var motion_count := 0
	var sleep_deadline_frames := -1
	var on_event: Callable


	func supports_centralized_authoritative_simulation() -> bool:
		return true


	func supports_layered_area_authoritative_simulation() -> bool:
		return true


	func uses_layered_area_physics_phase_decisions() -> bool:
		return true


	func get_layered_area_decision_interval_frames() -> int:
		return 1_000_000


	func uses_trusted_layered_phase_entrypoints() -> bool:
		return true


	func prepare_layered_area_authoritative_simulation() -> void:
		super.prepare_layered_area_authoritative_simulation()
		layered_area_motion_phase_due = true


	func simulate_trusted_layered_area_event_phase(
		_delta: float,
		simulation_tick: int
	) -> bool:
		event_count += 1
		if on_event.is_valid():
			on_event.call()
		scheduled_authoritative_step_count += 1
		layered_area_last_event_tick = simulation_tick
		layered_area_motion_phase_due = true
		layered_area_event_phase_sleeping = true
		layered_area_event_sleep_until_physics_frame = (
			Engine.get_physics_frames() + sleep_deadline_frames
			if sleep_deadline_frames > 0
			else -1
		)
		return true


	func simulate_trusted_layered_area_decision_phase(
		_delta: float,
		_simulation_tick: int
	) -> bool:
		decision_count += 1
		layered_area_decision_urgent = false
		return true


	func simulate_trusted_layered_area_motion_phase(
		_delta: float,
		_simulation_tick: int
	) -> bool:
		motion_count += 1
		return true


class ContactCooldownSleepingYuanshi extends YuanshiInsect:
	var event_deltas: Array[float] = []
	var touch_attempt_count := 0


	func _advance_layered_area_family_event_phase(delta: float) -> void:
		event_deltas.append(delta)


	func _try_deal_touch_damage() -> void:
		touch_attempt_count += 1
		touch_damage_cooldown_left = touch_damage_interval


	func track_player_for_test(player: Player) -> void:
		_track_touching_player(player)


	func track_plant_for_test(plant: PlantDefense) -> void:
		_track_touching_plant(plant)


	func clear_contacts_for_test() -> void:
		_clear_touching_players()


var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	await _test_global_phase_order_and_staggered_due_decisions()
	await _test_urgent_decision_does_not_throttle_event_or_motion()
	await _test_sparse_suspend_resume_preserves_same_tick_id_order()
	await _test_resume_physics_cadence_before_and_after_dispatch()
	await _test_sparse_cadence_recovers_after_skipped_physics_frames()
	await _test_sparse_event_sleep_wake_and_persistent_motion()
	await _test_contact_cooldown_sparse_sleep_and_lifetime_wakes()
	await _test_same_tick_event_wake_does_not_double_count_sleep_ack()
	await _test_tick_boundary_rollback_finishes_all_phases()
	_test_family_capability_whitelist()
	await _test_real_yuanshi_layered_pipeline_uses_explicit_delta()
	await _test_navigation_deadline_does_not_alias_full_decision_cadence()
	await _test_straight_chase_ab_equivalence()
	await _test_authored_runtime_handoff_and_rollback()
	var result := {
		"status": "ok" if failures.is_empty() else "failed",
		"failures": failures.duplicate(),
	}
	print("ENEMY_SIMULATION_LAYERED_AREA_JSON %s" % JSON.stringify(result))
	if failures.is_empty():
		print("ENEMY_SIMULATION_LAYERED_AREA_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_global_phase_order_and_staggered_due_decisions() -> void:
	var coordinator := _new_layered_coordinator()
	var phase_log: Array[String] = []
	var first := LayeredPhaseEnemy.new(&"first", phase_log)
	var second := LayeredPhaseEnemy.new(&"second", phase_log)
	var first_token := coordinator.try_register_enemy(first)
	var second_token := coordinator.try_register_enemy(second)
	_expect(first_token > 0 and second_token > 0, "Layered fixtures must register.")

	await physics_frame
	coordinator._physics_process(TEST_DELTA)
	_expect(
		phase_log == [
			"event:first", "event:second",
			"decision:first", "decision:second",
			"motion:first", "motion:second",
		],
		"LAYERED_AREA must run global event -> decision -> motion phases in stable-ID order."
	)
	phase_log.clear()
	await physics_frame
	coordinator._physics_process(TEST_DELTA)
	_expect(
		phase_log == [
			"event:first", "event:second",
			"decision:second",
			"motion:first", "motion:second",
		],
		"Due decisions must use deterministic simulation-ID staggering without throttling other phases."
	)
	_expect(
		first.received_event_deltas == [TEST_DELTA, TEST_DELTA]
		and second.received_motion_deltas == [TEST_DELTA, TEST_DELTA],
		"The coordinator must forward the exact physics delta to event and motion phases."
	)
	var metrics: Dictionary = coordinator.get_metrics()
	_expect(
		int(metrics["event_phases"]) == 4
		and int(metrics["motion_phases"]) == 4
		and int(metrics["decision_phases"]) == 3,
		"Layered phase metrics must distinguish 60 Hz work from due decisions."
	)
	_dispose_fixture(coordinator, [first, second])


func _test_urgent_decision_does_not_throttle_event_or_motion() -> void:
	var coordinator := _new_layered_coordinator()
	var phase_log: Array[String] = []
	var enemy := LayeredPhaseEnemy.new(&"urgent", phase_log)
	enemy.decision_interval = 8
	coordinator.try_register_enemy(enemy)
	await physics_frame
	coordinator._physics_process(TEST_DELTA)
	var first_tick := int(coordinator.get_metrics()["simulation_tick"])
	enemy.urgent_on_tick = first_tick + 1
	phase_log.clear()
	await physics_frame
	coordinator._physics_process(TEST_DELTA)
	_expect(
		phase_log == ["event:urgent", "decision:urgent", "motion:urgent"],
		"An urgent state change must force a same-tick decision between event and motion."
	)
	_expect(
		enemy.event_count == 2 and enemy.motion_count == 2,
		"Event and motion phases must remain 60 Hz across a long decision interval."
	)
	_expect(
		int(coordinator.get_metrics()["urgent_decisions"]) == 2,
		"Initial planning and the explicit urgent refresh must both be measured."
	)
	_dispose_fixture(coordinator, [enemy])


func _test_navigation_deadline_does_not_alias_full_decision_cadence() -> void:
	var coordinator := _new_layered_coordinator()
	var enemy := NavigationDeadlineYuanshiHarness.new()
	var objective := Node2D.new()
	objective.position = Vector2(1000.0, 0.0)
	enemy.set_objective_target(objective)
	var token := coordinator.try_register_enemy(enemy)
	_bind_direct_test_ownership(enemy, coordinator, token)
	for _step in range(30):
		await physics_frame
		coordinator._physics_process(TEST_DELTA)
	var navigation_only_frames: Array[int] = []
	for physics_frame in enemy.navigation_refresh_frames:
		if not enemy.full_decision_frames.has(physics_frame):
			navigation_only_frames.append(physics_frame)
	_expect(
		not navigation_only_frames.is_empty(),
		"An 8-frame navigation certificate deadline must wake independently of the 6-frame full decision cadence."
	)
	for physics_frame in navigation_only_frames:
		_expect(
			posmod(
				physics_frame + enemy.navigation_update_frame_offset,
				NavigationDeadlineYuanshiHarness.TEST_NAVIGATION_INTERVAL
			) == 0,
			"Navigation-only wakeups must retain the authored navigation phase."
		)
		_expect(
			posmod(
				physics_frame + enemy.get_layered_area_decision_phase_offset(),
				enemy.get_layered_area_decision_interval_frames()
			) != 0,
			"A navigation-only deadline must not run the full target/attack decision."
		)
	_dispose_fixture(coordinator, [enemy])
	objective.free()


func _test_sparse_suspend_resume_preserves_same_tick_id_order() -> void:
	var coordinator := _new_layered_coordinator()
	var phase_log: Array[String] = []
	var low := PhysicsCadenceEnemy.new(&"low", phase_log)
	var high := PhysicsCadenceEnemy.new(&"high", phase_log)
	var low_token := coordinator.try_register_enemy(low)
	var high_token := coordinator.try_register_enemy(high)
	_bind_direct_test_ownership(low, coordinator, low_token)
	_bind_direct_test_ownership(high, coordinator, high_token)
	await physics_frame
	coordinator._physics_process(TEST_DELTA)

	phase_log.clear()
	low.request_layered_area_urgent_decision()
	low.on_decision = func() -> void:
		coordinator.suspend_enemy(high, high_token)
		high.request_layered_area_urgent_decision()
		coordinator.resume_enemy(high, high_token)
		low.on_decision = Callable()
	await physics_frame
	coordinator._physics_process(TEST_DELTA)
	_expect(
		phase_log == [
			"event:low", "event:high",
			"decision:low", "decision:high",
			"motion:low", "motion:high",
		],
		"A high-ID enemy resumed from a low-ID decision must rejoin this tick in stable order."
	)

	phase_log.clear()
	high.request_layered_area_urgent_decision()
	high.on_decision = func() -> void:
		coordinator.suspend_enemy(low, low_token)
		low.request_layered_area_urgent_decision()
		coordinator.resume_enemy(low, low_token)
		high.on_decision = Callable()
	await physics_frame
	coordinator._physics_process(TEST_DELTA)
	_expect(
		not phase_log.has("decision:low"),
		"A low-ID enemy resumed after its slot must defer its urgent decision."
	)
	phase_log.clear()
	await physics_frame
	coordinator._physics_process(TEST_DELTA)
	_expect(
		phase_log.has("decision:low"),
		"A deferred low-ID urgent decision must run on the next admitted tick."
	)

	phase_log.clear()
	low.request_layered_area_urgent_decision()
	low.on_decision = func() -> void:
		coordinator.suspend_enemy(high, high_token)
		low.on_decision = Callable()
	await physics_frame
	coordinator._physics_process(TEST_DELTA)
	_expect(
		phase_log.has("event:high")
		and not phase_log.has("decision:high")
		and not phase_log.has("motion:high"),
		"A same-tick suspension after event admission must block later decision and motion."
	)
	coordinator.resume_enemy(high, high_token)

	phase_log.clear()
	coordinator.suspend_enemy(high, high_token)
	high.layered_area_decision_urgent = false
	low.request_layered_area_urgent_decision()
	low.on_decision = func() -> void:
		coordinator.resume_enemy(high, high_token)
		high.request_layered_area_urgent_decision()
		low.on_decision = Callable()
	await physics_frame
	coordinator._physics_process(TEST_DELTA)
	_expect(
		not phase_log.has("event:high")
		and not phase_log.has("decision:high"),
		"An enemy suspended at tick start must not enter decision before its resumed event admission."
	)
	phase_log.clear()
	await physics_frame
	coordinator._physics_process(TEST_DELTA)
	_expect(
		phase_log.has("event:high") and phase_log.has("decision:high"),
		"A tick-start suspended enemy must run event before its deferred urgent decision."
	)
	_dispose_fixture(coordinator, [low, high])


func _test_resume_physics_cadence_before_and_after_dispatch() -> void:
	var coordinator := _new_layered_coordinator()
	var phase_log: Array[String] = []
	var enemy := PhysicsCadenceEnemy.new(&"resume", phase_log)
	enemy.decision_interval = 1
	var token := coordinator.try_register_enemy(enemy)
	_bind_direct_test_ownership(enemy, coordinator, token)
	await physics_frame
	coordinator._physics_process(TEST_DELTA)

	coordinator.suspend_enemy(enemy, token)
	enemy.layered_area_decision_urgent = false
	await physics_frame
	coordinator.resume_enemy(enemy, token)
	coordinator._physics_process(TEST_DELTA)
	_expect(
		enemy.decision_count == 2,
		"A non-urgent resume before coordinator dispatch must retain a cadence due on the current frame."
	)

	coordinator.suspend_enemy(enemy, token)
	enemy.layered_area_decision_urgent = false
	coordinator.resume_enemy(enemy, token)
	coordinator._physics_process(TEST_DELTA)
	_expect(
		enemy.decision_count == 2,
		"A non-urgent resume after coordinator dispatch must not execute twice in the same frame."
	)
	await physics_frame
	coordinator._physics_process(TEST_DELTA)
	_expect(
		enemy.decision_count == 3,
		"A non-urgent post-dispatch resume must continue on the next cadence frame."
	)
	_dispose_fixture(coordinator, [enemy])


func _test_sparse_cadence_recovers_after_skipped_physics_frames() -> void:
	var coordinator := _new_layered_coordinator()
	var phase_log: Array[String] = []
	var enemy := PhysicsCadenceEnemy.new(&"cadence", phase_log)
	enemy.decision_interval = 3
	enemy.decision_phase_offset = 0
	var token := coordinator.try_register_enemy(enemy)
	_bind_direct_test_ownership(enemy, coordinator, token)
	await physics_frame
	coordinator._physics_process(TEST_DELTA)
	_expect(enemy.decision_count == 1, "Initial sparse planning must be urgent.")

	for _skipped_frame in range(5):
		await physics_frame
	var resumed_frame := Engine.get_physics_frames()
	coordinator._physics_process(TEST_DELTA)
	var expected_after_resume := 1 + (1 if posmod(resumed_frame, 3) == 0 else 0)
	_expect(
		enemy.decision_count == expected_after_resume,
		"A frame gap must restore the fixed modulo cadence without replaying missed decisions."
	)
	while posmod(Engine.get_physics_frames(), 3) != 0:
		await physics_frame
		coordinator._physics_process(TEST_DELTA)
	_expect(
		enemy.decision_count == 2,
		"The first cadence boundary after a gap must execute exactly once."
	)

	_expect(
		coordinator.unregister_enemy(enemy, token),
		"The final sparse registration must unregister cleanly."
	)
	var empty_metrics: Dictionary = coordinator.get_metrics()
	_expect(
		int(empty_metrics["registered_count"]) == 0
		and int(empty_metrics["decision_due_bucket_count"]) == 0
		and int(empty_metrics["decision_urgent_queue_count"]) == 0,
		"Removing the final enemy must release every scheduler-held Registration."
	)
	_dispose_fixture(coordinator, [enemy])


func _test_sparse_event_sleep_wake_and_persistent_motion() -> void:
	var coordinator := _new_layered_coordinator()
	var enemy := SparseSleepingEnemy.new()
	var token := coordinator.try_register_enemy(enemy)
	_bind_direct_test_ownership(enemy, coordinator, token)

	for _tick_index in range(3):
		await physics_frame
		coordinator._physics_process(TEST_DELTA)
	var sleeping_metrics: Dictionary = coordinator.get_metrics()
	_expect(
		enemy.event_count == 1
		and enemy.decision_count == 1
		and enemy.motion_count == 3,
		"An indefinite trusted event sleeper must leave Phase 1 while its certified motion remains at 60 Hz."
	)
	_expect(
		int(sleeping_metrics["event_sleep_acks"]) == 2
		and int(sleeping_metrics["event_sleeping_count"]) == 1
		and int(sleeping_metrics["event_ready_queue_count"]) == 0
		and int(sleeping_metrics["motion_active_count"]) == 1,
		"Sparse event metrics must preserve skipped-ack semantics without retaining the sleeper in the ready queue."
	)

	enemy.request_layered_area_urgent_decision()
	await physics_frame
	coordinator._physics_process(TEST_DELTA)
	_expect(
		enemy.event_count == 2
		and enemy.decision_count == 2
		and enemy.motion_count == 4,
		"An urgent mutation must wake a sleeping event and decision on the next stable tick without dropping motion."
	)

	enemy.sleep_deadline_frames = 2
	enemy.request_layered_area_urgent_decision()
	await physics_frame
	coordinator._physics_process(TEST_DELTA)
	var deadline_event_count := enemy.event_count
	var deadline_metrics: Dictionary = coordinator.get_metrics()
	_expect(
		int(deadline_metrics["event_due_bucket_count"]) == 1,
		"A finite event sleep certificate must occupy one exact-frame deadline bucket."
	)
	await physics_frame
	coordinator._physics_process(TEST_DELTA)
	_expect(
		enemy.event_count == deadline_event_count,
		"A finite sleeper must not run before its exact event deadline."
	)
	await physics_frame
	coordinator._physics_process(TEST_DELTA)
	_expect(
		enemy.event_count == deadline_event_count + 1,
		"The exact event deadline must wake the sleeper once without scanning all registrations."
	)
	_dispose_fixture(coordinator, [enemy])


func _test_contact_cooldown_sparse_sleep_and_lifetime_wakes() -> void:
	var coordinator := _new_layered_coordinator()
	var enemy := ContactCooldownSleepingYuanshi.new()
	var objective := Node2D.new()
	var player := Player.new()
	var cooldown_delta := 1.0 / 60.0
	enemy.objective_target = objective
	enemy.touch_damage_interval = 0.5
	enemy.touch_damage_cooldown_left = 0.0
	enemy.track_player_for_test(player)
	var token := coordinator.try_register_enemy(enemy)
	_bind_direct_test_ownership(enemy, coordinator, token)

	await physics_frame
	coordinator._physics_process(cooldown_delta)
	var first_event_frame := Engine.get_physics_frames()
	_expect(
		enemy.event_deltas == [cooldown_delta]
		and enemy.touch_attempt_count == 1
		and enemy.touch_damage_cooldown_left == 0.5
		and enemy.layered_area_event_phase_sleeping
		and enemy.layered_area_event_sleep_until_physics_frame
			== first_event_frame + 31,
		"A 0.5-second Player-contact cooldown at 60 Hz must preserve the legacy 31-subtraction deadline, not ceil it to 30."
	)
	var legacy_projected_cooldown := 0.5
	var every_projected_tick_matches_legacy := true
	for _before_deadline_tick in range(30):
		await physics_frame
		coordinator._physics_process(cooldown_delta)
		legacy_projected_cooldown = maxf(
			legacy_projected_cooldown - cooldown_delta,
			0.0
		)
		if enemy.touch_damage_cooldown_left != legacy_projected_cooldown:
			every_projected_tick_matches_legacy = false
	_expect(
		enemy.event_deltas.size() == 1
		and enemy.touch_attempt_count == 1
		and every_projected_tick_matches_legacy
		and enemy.touch_damage_cooldown_left > 0.0,
		"Every pre-deadline sparse timer projection must expose the exact legacy raw cooldown value without attacking early."
	)
	await physics_frame
	coordinator._physics_process(cooldown_delta)
	_expect(
		enemy.event_deltas.size() == 2
		and is_equal_approx(enemy.event_deltas[1], cooldown_delta * 31.0)
		and enemy.touch_attempt_count == 2
		and enemy.touch_damage_cooldown_left == 0.5
		and enemy.layered_touch_damage_projected_ticks_since_event == 0,
		"The cooldown deadline must preserve skipped-tick elapsed_delta and fire exactly once."
	)

	player.is_dead = true
	player.died.emit()
	_expect(
		enemy.touching_players.is_empty()
		and not enemy.layered_area_event_phase_sleeping,
		"Player death must synchronously invalidate contact membership and wake the sleeper."
	)
	await physics_frame
	coordinator._physics_process(cooldown_delta)
	_expect(
		enemy.event_deltas.size() == 3
		and is_equal_approx(enemy.event_deltas[2], cooldown_delta),
		"A Player death wake must advance only the actually elapsed physics tick."
	)

	var plant := PlantDefense.new()
	enemy.touch_damage_cooldown_left = enemy.touch_damage_interval
	enemy.track_plant_for_test(plant)
	enemy.request_layered_area_urgent_decision()
	await physics_frame
	coordinator._physics_process(cooldown_delta)
	_expect(
		enemy.layered_area_event_phase_sleeping
		and enemy.touching_plants.has(plant.get_instance_id()),
		"A stable Plant contact must enter the same deadline-backed cooldown sleep."
	)
	plant.is_removing = true
	plant.removal_started.emit(PlantDefense.RemovalMode.SILENT)
	_expect(
		enemy.touching_plants.is_empty()
		and not enemy.layered_area_event_phase_sleeping,
		"Plant removal must synchronously invalidate contact membership and wake the sleeper."
	)
	await physics_frame
	coordinator._physics_process(cooldown_delta)

	var dynamic_enemy_target := YuanshiInsect.new()
	var live_player := Player.new()
	enemy.objective_target = dynamic_enemy_target
	enemy.touch_damage_cooldown_left = enemy.touch_damage_interval
	enemy.track_player_for_test(live_player)
	await physics_frame
	coordinator._physics_process(cooldown_delta)
	_expect(
		not enemy.layered_area_event_phase_sleeping
		and enemy.layered_area_event_sleep_until_physics_frame < 0,
		"An Enemy dynamic objective must remain awake even during a Player/Plant touch cooldown."
	)

	enemy.clear_contacts_for_test()
	coordinator.clear(false)
	objective.free()
	player.free()
	plant.free()
	live_player.free()
	dynamic_enemy_target.free()
	enemy.free()
	coordinator.free()


func _test_same_tick_event_wake_does_not_double_count_sleep_ack() -> void:
	var coordinator := _new_layered_coordinator()
	var low := SparseSleepingEnemy.new()
	var high := SparseSleepingEnemy.new()
	var low_token := coordinator.try_register_enemy(low)
	var high_token := coordinator.try_register_enemy(high)
	_bind_direct_test_ownership(low, coordinator, low_token)
	_bind_direct_test_ownership(high, coordinator, high_token)
	await physics_frame
	coordinator._physics_process(TEST_DELTA)
	coordinator.get_metrics(true)

	low.on_event = func() -> void:
		high.request_layered_area_urgent_decision()
		low.on_event = Callable()
	low.request_layered_area_urgent_decision()
	await physics_frame
	coordinator._physics_process(TEST_DELTA)
	var metrics: Dictionary = coordinator.get_metrics()
	_expect(
		low.event_count == 2 and high.event_count == 2,
		"A low-ID event must wake a higher-ID trusted sleeper into the same event phase."
	)
	_expect(
		int(metrics["event_phases"]) == 2
		and int(metrics["event_sleep_acks"]) == 0,
		"A same-tick woken sleeper must record a real event instead of a provisional sleep acknowledgement."
	)
	_dispose_fixture(coordinator, [low, high])


func _test_tick_boundary_rollback_finishes_all_phases() -> void:
	var coordinator := _new_layered_coordinator()
	var phase_log: Array[String] = []
	var requester := LayeredPhaseEnemy.new(&"requester", phase_log)
	var final_entry := LayeredPhaseEnemy.new(&"final", phase_log)
	requester.rollback_coordinator = coordinator
	coordinator.try_register_enemy(requester)
	coordinator.try_register_enemy(final_entry)
	await physics_frame
	coordinator._physics_process(TEST_DELTA)
	_expect(
		phase_log == [
			"event:requester", "event:final",
			"decision:requester", "decision:final",
			"motion:requester", "motion:final",
		],
		"A rollback request in the event phase must finish the current stable tick."
	)
	_expect(
		coordinator.mode == POLICY.Mode.LEGACY,
		"LAYERED_AREA rollback must commit exactly at the completed tick boundary."
	)
	phase_log.clear()
	coordinator._physics_process(TEST_DELTA)
	_expect(
		phase_log.is_empty() and not coordinator.is_physics_processing(),
		"No centralized phase may run after rollback to LEGACY."
	)
	_dispose_fixture(coordinator, [requester, final_entry])


func _test_family_capability_whitelist() -> void:
	var coordinator := _new_layered_coordinator()
	var ordinary := YuanshiInsect.new()
	var aura := YuanshiInsectAura.new()
	var fire_ranged := YuanshiInsectFireRanged.new()
	var exploder := YuanshiInsectExploder.new()
	var slime := Slime.new()
	_expect(
		ordinary.supports_layered_area_authoritative_simulation(),
		"Ordinary Yuanshi melee must opt into LAYERED_AREA."
	)
	var accepted_families := {
		"Slime": slime,
		"Exploder": exploder,
		"FireRanged": fire_ranged,
		"Aura": aura,
	}
	for family_name in accepted_families:
		var accepted_enemy := accepted_families[family_name] as Enemy
		_expect(
			accepted_enemy != null
			and accepted_enemy.supports_layered_area_authoritative_simulation(),
			"Wave %s must declare LAYERED_AREA capability." % family_name
		)
		_expect(
			accepted_enemy != null
			and accepted_enemy.supports_indexed_touch_authority(),
			"Wave %s must declare indexed contact authority capability." % family_name
		)
		_expect(
			accepted_enemy != null
			and coordinator.try_register_enemy(accepted_enemy) > 0,
			"The LAYERED_AREA coordinator must admit wave %s." % family_name
		)
	_expect(
		coordinator.try_register_enemy(ordinary) > 0,
		"The LAYERED_AREA coordinator must accept ordinary Yuanshi melee."
	)
	_dispose_fixture(coordinator, [ordinary, aura, fire_ranged, exploder, slime])


func _test_real_yuanshi_layered_pipeline_uses_explicit_delta() -> void:
	var coordinator := _new_layered_coordinator()
	var enemy := LayeredYuanshiHarness.new()
	var target := Node2D.new()
	enemy.objective_target = target
	enemy.layered_area_decision_interval_frames = 8
	var token := coordinator.try_register_enemy(enemy)
	_bind_direct_test_ownership(enemy, coordinator, token)
	await physics_frame
	coordinator._physics_process(TEST_DELTA)
	_expect(
		enemy.event_deltas == [TEST_DELTA]
		and enemy.decision_deltas == [TEST_DELTA]
		and enemy.motion_deltas == [TEST_DELTA],
		"Ordinary Yuanshi must run touch timers, planning and movement through layered entry points."
	)
	_expect(
		is_equal_approx(enemy.global_position.x, 10.0 * TEST_DELTA),
		"Layered Yuanshi movement must use the coordinator delta, not a disabled node callback delta."
	)

	enemy.test_has_contact = true
	await physics_frame
	coordinator._physics_process(TEST_DELTA)
	_expect(
		enemy.velocity == Vector2.ZERO and enemy.motion_deltas.size() == 1,
		"A newly observed Area contact must stop motion in the same physics tick."
	)
	_expect(
		enemy.event_deltas.size() == 2
		and int(coordinator.get_metrics()["decision_phases"]) == 2,
		"Contact must preserve 60 Hz timers and force an urgent decision."
	)

	enemy.test_has_contact = false
	await physics_frame
	coordinator._physics_process(TEST_DELTA)
	_expect(
		enemy.motion_deltas.size() == 2
		and enemy.decision_deltas.size() == 2
		and int(coordinator.get_metrics()["decision_phases"]) == 3,
		"Contact exit must urgently rebuild the plan and resume 60 Hz movement."
	)
	coordinator.clear(false)
	target.free()
	enemy.free()
	coordinator.free()


func _test_authored_runtime_handoff_and_rollback() -> void:
	var runtime := RUNTIME_SCENE.instantiate() as EnemyGameplayGatewayTestRuntime
	root.add_child(runtime)
	await process_frame
	var coordinator := runtime.get_enemy_simulation_coordinator()
	coordinator.set_mode(POLICY.Mode.LAYERED_AREA)
	var enemy := FAST_CONFIG.enemy_scene.instantiate() as YuanshiInsect
	runtime.enemy_container.add_child(enemy)
	enemy.setup(FAST_CONFIG, null, runtime.grid_pathfinder, runtime)
	var owned_token := enemy.enemy_simulation_token
	_expect(
		enemy.is_centrally_simulated()
		and owned_token > 0
		and coordinator.owns_enemy(enemy, owned_token),
		"An authored ordinary Yuanshi must atomically hand off to LAYERED_AREA."
	)
	_expect(
		not enemy.is_physics_processing(),
		"The authored layered enemy must disable its per-node physics callback."
	)
	enemy.touch_damage_cooldown_left = 1.0
	var scheduled_before := enemy.scheduled_authoritative_step_count
	await physics_frame
	await physics_frame
	_expect(
		enemy.scheduled_authoritative_step_count > scheduled_before
		and enemy.touch_damage_cooldown_left < 1.0,
		"The authored runtime must keep ordinary Yuanshi event timers at physics rate."
	)

	var scheduled_after := enemy.scheduled_authoritative_step_count
	var suppressed_before := enemy.suppressed_direct_authoritative_step_count
	enemy._physics_process(TEST_DELTA)
	_expect(
		enemy.scheduled_authoritative_step_count == scheduled_after
		and enemy.suppressed_direct_authoritative_step_count == suppressed_before + 1,
		"A disabled per-enemy callback must not duplicate a layered authoritative tick."
	)
	coordinator.set_mode(POLICY.Mode.LEGACY)
	_expect(
		not enemy.is_centrally_simulated()
		and enemy.is_physics_processing()
		and not coordinator.owns_enemy(enemy, owned_token),
		"LAYERED_AREA must restore the authored enemy's legacy callback safely."
	)
	runtime.queue_free()
	await process_frame
	await physics_frame


func _test_straight_chase_ab_equivalence() -> void:
	var coordinator := _new_layered_coordinator()
	var target := Node2D.new()
	var legacy_enemy := LayeredYuanshiHarness.new()
	var layered_enemy := LayeredYuanshiHarness.new()
	legacy_enemy.objective_target = target
	layered_enemy.objective_target = target
	legacy_enemy.layered_area_decision_interval_frames = 3
	layered_enemy.layered_area_decision_interval_frames = 3
	legacy_enemy.touch_damage_cooldown_left = 1.0
	layered_enemy.touch_damage_cooldown_left = 1.0
	var token := coordinator.try_register_enemy(layered_enemy)
	_bind_direct_test_ownership(layered_enemy, coordinator, token)
	await physics_frame
	for _tick_index in range(8):
		legacy_enemy._physics_process(TEST_DELTA)
		coordinator._physics_process(TEST_DELTA)
		await physics_frame
	_expect(
		legacy_enemy.global_position.is_equal_approx(layered_enemy.global_position)
		and is_equal_approx(
			legacy_enemy.touch_damage_cooldown_left,
			layered_enemy.touch_damage_cooldown_left
		),
		"A/B stable straight pursuit must preserve 60 Hz movement and timer results."
	)
	_expect(
		layered_enemy.decision_deltas.size() < legacy_enemy.decision_deltas.size()
		and layered_enemy.motion_deltas.size() == legacy_enemy.motion_deltas.size(),
		"LAYERED_AREA must reduce direction decisions without reducing motion ticks."
	)
	coordinator.clear(false)
	target.free()
	legacy_enemy.free()
	layered_enemy.free()
	coordinator.free()


func _bind_direct_test_ownership(
	enemy: Enemy,
	coordinator: EnemySimulationCoordinator,
	token: int
) -> void:
	enemy.enemy_simulation_coordinator = coordinator
	enemy.enemy_simulation_token = token
	enemy.simulation_id = coordinator.get_simulation_id(enemy, token)
	enemy.authoritative_simulation_driver = (
		Enemy.AuthoritativeSimulationDriver.SCHEDULED_ACTIVE
	)


func _new_layered_coordinator() -> EnemySimulationCoordinator:
	var coordinator := COORDINATOR.new()
	coordinator._ready()
	coordinator.set_mode(POLICY.Mode.LAYERED_AREA)
	return coordinator


func _dispose_fixture(coordinator: Node, enemies: Array) -> void:
	if is_instance_valid(coordinator):
		coordinator.call("clear", false)
	for enemy in enemies:
		if is_instance_valid(enemy):
			enemy.free()
	if is_instance_valid(coordinator):
		coordinator.free()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
