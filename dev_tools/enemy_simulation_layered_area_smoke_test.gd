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


	func _move_until_player_contact(delta: float = -1.0) -> void:
		motion_deltas.append(delta)
		global_position += velocity * delta


var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	await _test_global_phase_order_and_staggered_due_decisions()
	await _test_urgent_decision_does_not_throttle_event_or_motion()
	await _test_tick_boundary_rollback_finishes_all_phases()
	_test_family_capability_whitelist()
	await _test_real_yuanshi_layered_pipeline_uses_explicit_delta()
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
	for rejected_enemy in [aura, fire_ranged, exploder, slime]:
		_expect(
			coordinator.try_register_enemy(rejected_enemy) <= 0,
			"Special Yuanshi families must fail closed in the first LAYERED_AREA slice."
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
