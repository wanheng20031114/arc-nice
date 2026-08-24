extends SceneTree

const POLICY := preload(
	"res://scene/combat/simulation/enemy_simulation_policy.gd"
)
const RUNTIME_SCENE := preload(
	"res://dev_tools/fixtures/enemy_gameplay_gateway_test_runtime.tscn"
)
const FAILURE_COORDINATOR_SCRIPT := preload(
	"res://dev_tools/fixtures/enemy_simulation_atomic_rollback_coordinator.gd"
)
const ENEMY_SCENE := preload(
	"res://dev_tools/fixtures/enemy_contact_atomic_rollback_harness.tscn"
)
const TEST_DELTA := 1.0 / 60.0
const AUTHORED_TOUCH_LAYER := 16
const AUTHORED_TOUCH_MASK := 35

var failures: Array[String] = []


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	await _test_partial_proxy_admission_failure_is_tick_atomic()
	await _test_dirty_geometry_failure_is_tick_atomic()
	if failures.is_empty():
		print("ENEMY_SIMULATION_CONTACT_ATOMIC_ROLLBACK_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_partial_proxy_admission_failure_is_tick_atomic() -> void:
	var runtime: EnemyGameplayGatewayTestRuntime = await _create_runtime(2)
	var coordinator := (
		runtime.get_enemy_simulation_coordinator()
		as EnemySimulationAtomicRollbackCoordinator
	)
	var service := runtime.get_enemy_contact_service() as EnemyContactService
	var first: EnemyContactAtomicRollbackHarness = _spawn_enemy(
		runtime,
		&"AdmissionFirst"
	)
	var second: EnemyContactAtomicRollbackHarness = _spawn_enemy(
		runtime,
		&"AdmissionFailure"
	)
	_expect(
		first.is_centrally_simulated() and second.is_centrally_simulated(),
		"Admission fixture enemies must enter centralized ownership before the failure tick."
	)
	coordinator.set_physics_process(false)
	var first_before: Dictionary = first.capture_gameplay_state()
	var second_before: Dictionary = second.capture_gameplay_state()

	await physics_frame
	coordinator._physics_process(TEST_DELTA)
	coordinator.set_physics_process(false)
	var failed_tick := int(coordinator.get_metrics()["simulation_tick"])
	_expect(
		coordinator.mode == POLICY.Mode.COMPAT_60
		and first.capture_gameplay_state() == first_before
		and second.capture_gameplay_state() == second_before,
		"A partial contact admission failure must abort the complete cohort before event, decision, motion, damage, RNG or projectile work."
	)
	_expect(
		not service.owns_enemy(first)
		and not service.owns_enemy(second)
		and coordinator.is_contact_proxy_state_fully_released(first)
		and coordinator.is_contact_proxy_state_fully_released(second)
		and coordinator.contact_transaction_queues_are_empty(),
		"Admission rollback must remove earlier successful proxies and clear every contact transaction queue at the same tick boundary."
	)
	await process_frame
	_expect(
		_authored_touch_state_is_restored(first)
		and _authored_touch_state_is_restored(second),
		"Admission rollback must restore the authored Area, collision mask and touch/body shape state."
	)
	var rollback_metrics: Dictionary = coordinator.get_metrics()
	_expect(
		int(rollback_metrics["contact_atomic_rollbacks"]) == 1
		and int(rollback_metrics["event_phases"]) == 0
		and int(rollback_metrics["decision_phases"]) == 0
		and int(rollback_metrics["motion_phases"]) == 0
		and int(rollback_metrics["authoritative_steps"]) == 0,
		"The failed admission tick must report one atomic rollback and zero gameplay phase admissions."
	)

	await physics_frame
	coordinator._physics_process(TEST_DELTA)
	coordinator._physics_process(TEST_DELTA)
	coordinator.set_physics_process(false)
	_expect(
		first.compat_count == 1
		and second.compat_count == 1
		and first.compat_ticks == [failed_tick + 1]
		and second.compat_ticks == [failed_tick + 1]
		and first.event_count == 0
		and first.decision_count == 0
		and first.motion_count == 0
		and second.event_count == 0
		and second.decision_count == 0
		and second.motion_count == 0,
		"The next physics tick must execute exactly one COMPAT_60 step per enemy, including duplicate-dispatch rejection in the same frame."
	)
	await _dispose_runtime(runtime)


func _test_dirty_geometry_failure_is_tick_atomic() -> void:
	var runtime: EnemyGameplayGatewayTestRuntime = await _create_runtime(0)
	var coordinator := (
		runtime.get_enemy_simulation_coordinator()
		as EnemySimulationAtomicRollbackCoordinator
	)
	var service := runtime.get_enemy_contact_service() as EnemyContactService
	var enemy: EnemyContactAtomicRollbackHarness = _spawn_enemy(
		runtime,
		&"GeometryFailure"
	)
	coordinator.set_physics_process(false)

	# Establish real proxy and indexed Area ownership first, so the failure path
	# proves that rollback restores an already-taken-over authored sensor.
	await physics_frame
	coordinator._physics_process(TEST_DELTA)
	coordinator.set_physics_process(false)
	await process_frame
	var simulation_id: int = coordinator.get_simulation_id(
		enemy,
		enemy.enemy_simulation_token
	)
	_expect(
		service.owns_enemy(enemy, simulation_id)
		and enemy.is_indexed_touch_authority_enabled()
		and not enemy.touch_damage_area.monitoring
		and enemy.touch_damage_area.collision_layer == 0
		and enemy.touch_damage_area.collision_mask == 0,
		"Geometry fixture must begin with a real registered proxy and disabled authored Area."
	)

	var authored_shape: Shape2D = enemy.touch_damage_shape.shape
	var before_failure: Dictionary = enemy.capture_gameplay_state()
	enemy.touch_damage_shape.shape = null
	enemy.mark_contact_shape_geometry_changed()
	await physics_frame
	coordinator._physics_process(TEST_DELTA)
	coordinator.set_physics_process(false)
	var failed_tick := int(coordinator.get_metrics()["simulation_tick"])
	_expect(
		coordinator.mode == POLICY.Mode.COMPAT_60
		and enemy.capture_gameplay_state() == before_failure,
		"A dirty-geometry recapture failure must be discovered before every gameplay phase in that tick."
	)
	_expect(
		not service.owns_enemy(enemy)
		and coordinator.is_contact_proxy_state_fully_released(enemy)
		and coordinator.contact_transaction_queues_are_empty(),
		"Geometry rollback must atomically release the stale service proxy and all cached proxy geometry."
	)
	await process_frame
	_expect(
		_authored_touch_state_is_restored(enemy),
		"Geometry rollback must restore authored Area monitoring, layers, masks and enabled-shape state."
	)
	var rollback_metrics: Dictionary = coordinator.get_metrics()
	_expect(
		int(rollback_metrics["contact_atomic_rollbacks"]) == 1,
		"Dirty geometry failure must report exactly one atomic contact rollback."
	)

	# Restore the external fixture mutation, then prove the already-owned enemy is
	# stepped exactly once by COMPAT on the immediately following physics tick.
	enemy.touch_damage_shape.shape = authored_shape
	var compat_before: int = enemy.compat_count
	await physics_frame
	coordinator._physics_process(TEST_DELTA)
	coordinator._physics_process(TEST_DELTA)
	coordinator.set_physics_process(false)
	_expect(
		enemy.compat_count == compat_before + 1
		and enemy.compat_ticks.back() == failed_tick + 1
		and enemy.event_count == int(before_failure["event_count"])
		and enemy.decision_count == int(before_failure["decision_count"])
		and enemy.motion_count == int(before_failure["motion_count"]),
		"After geometry rollback, the next tick must execute one and only one COMPAT step without replaying layered phases."
	)
	await _dispose_runtime(runtime)


func _create_runtime(
	fail_admission_call: int
) -> EnemyGameplayGatewayTestRuntime:
	var runtime := RUNTIME_SCENE.instantiate() as EnemyGameplayGatewayTestRuntime
	var authored_coordinator := runtime.get_node(
		"EnemySimulationCoordinator"
	) as EnemySimulationCoordinator
	authored_coordinator.set_script(FAILURE_COORDINATOR_SCRIPT)
	authored_coordinator.set(
		&"fail_contact_admission_call",
		fail_admission_call
	)
	root.add_child(runtime)
	await process_frame
	runtime.enable_singleplayer_combat_target_index(true)
	var coordinator := (
		runtime.get_enemy_simulation_coordinator()
		as EnemySimulationAtomicRollbackCoordinator
	)
	coordinator.manual_dispatch_only = true
	coordinator.set_mode(POLICY.Mode.LAYERED_CONTACT)
	return runtime


func _spawn_enemy(
	runtime: EnemyGameplayGatewayTestRuntime,
	fixture_name: StringName
) -> EnemyContactAtomicRollbackHarness:
	var enemy := ENEMY_SCENE.instantiate() as EnemyContactAtomicRollbackHarness
	enemy.name = String(fixture_name)
	runtime.enemy_container.add_child(enemy)
	enemy.setup(null, null, runtime.grid_pathfinder, runtime)
	return enemy


func _authored_touch_state_is_restored(enemy: Enemy) -> bool:
	return (
		not enemy.is_indexed_touch_authority_enabled()
		and enemy.touch_damage_area.monitoring
		and enemy.touch_damage_area.monitorable
		and enemy.touch_damage_area.collision_layer == AUTHORED_TOUCH_LAYER
		and enemy.touch_damage_area.collision_mask == AUTHORED_TOUCH_MASK
		and not enemy.touch_damage_shape.disabled
		and not enemy.collision_shape.disabled
	)


func _dispose_runtime(runtime: EnemyGameplayGatewayTestRuntime) -> void:
	var coordinator := runtime.get_enemy_simulation_coordinator()
	coordinator.clear(false)
	runtime.queue_free()
	await process_frame
	await physics_frame


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
