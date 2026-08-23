extends SceneTree

const RUNTIME_SCENE := preload(
	"res://dev_tools/fixtures/enemy_gameplay_gateway_test_runtime.tscn"
)
const FAST_CONFIG := preload(
	"res://resources/config/enemies/yuanshi_insect_fast.tres"
)
const TEST_DELTA := 1.0 / 60.0

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var runtime := RUNTIME_SCENE.instantiate() as EnemyGameplayGatewayTestRuntime
	root.add_child(runtime)
	current_scene = runtime
	await process_frame

	var coordinator := runtime.get_enemy_simulation_coordinator()
	_expect(coordinator != null, "The authored runtime must expose its coordinator.")
	if coordinator != null:
		await _test_real_enemy_handoff(runtime, coordinator)
		await _test_suspended_enemy_rollback(runtime, coordinator)
		await _test_live_forward_handoff(runtime, coordinator)
		await _test_compat_tick_matches_legacy(runtime, coordinator)

	runtime.queue_free()
	await process_frame
	await physics_frame

	var result := {
		"status": "ok" if failures.is_empty() else "failed",
		"failures": failures.duplicate(),
	}
	print("ENEMY_SIMULATION_COMPAT_INTEGRATION_JSON %s" % JSON.stringify(result))
	if failures.is_empty():
		print("ENEMY_SIMULATION_COMPAT_INTEGRATION_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_real_enemy_handoff(
	runtime: EnemyGameplayGatewayTestRuntime,
	coordinator: EnemySimulationCoordinator
) -> void:
	coordinator.set_mode(EnemySimulationPolicy.Mode.COMPAT_60)
	var enemy := _spawn_enemy(runtime)
	var token := enemy.enemy_simulation_token
	_expect(enemy.is_centrally_simulated(), "A supported authoritative Yuanshi must hand off atomically.")
	_expect(token > 0, "The handoff must assign a positive ownership token.")
	_expect(enemy.simulation_id > 0, "The handoff must assign a stable simulation ID.")
	_expect(
		coordinator.owns_enemy(enemy, token),
		"The enemy and coordinator must agree on exact ownership."
	)
	_expect(
		not enemy.is_physics_processing(),
		"A centrally owned enemy must disable its individual physics callback."
	)

	var scheduled_before := enemy.scheduled_authoritative_step_count
	await physics_frame
	await physics_frame
	_expect(
		enemy.scheduled_authoritative_step_count > scheduled_before,
		"The real Yuanshi authoritative step must advance through COMPAT_60."
	)
	var scheduled_after := enemy.scheduled_authoritative_step_count
	var suppressed_before := enemy.suppressed_direct_authoritative_step_count
	enemy._physics_process(TEST_DELTA)
	_expect(
		enemy.scheduled_authoritative_step_count == scheduled_after,
		"A direct callback must never duplicate a centrally scheduled step."
	)
	_expect(
		enemy.suppressed_direct_authoritative_step_count == suppressed_before + 1,
		"Suppressed direct entry must remain observable for A/B evidence."
	)

	coordinator.set_mode(EnemySimulationPolicy.Mode.LEGACY)
	_expect(
		not enemy.is_centrally_simulated(),
		"LEGACY rollback must release coordinator ownership."
	)
	_expect(
		enemy.is_physics_processing(),
		"An active enemy must resume its individual callback after rollback."
	)
	_expect(
		not coordinator.owns_enemy(enemy, token),
		"A released token must be invalid immediately after rollback."
	)
	enemy.touch_damage_cooldown_left = 1.0
	await physics_frame
	await physics_frame
	_expect(
		enemy.touch_damage_cooldown_left < 1.0,
		"The restored LEGACY callback must keep authoritative timers advancing."
	)
	_expect(
		enemy.scheduled_authoritative_step_count == scheduled_after,
		"No scheduled callback may run after a LEGACY rollback."
	)
	enemy.queue_free()
	await physics_frame


func _test_suspended_enemy_rollback(
	runtime: EnemyGameplayGatewayTestRuntime,
	coordinator: EnemySimulationCoordinator
) -> void:
	coordinator.set_mode(EnemySimulationPolicy.Mode.COMPAT_60)
	var enemy := _spawn_enemy(runtime)
	_expect(enemy.is_centrally_simulated(), "The suspended fixture must first be centrally owned.")
	enemy.set_authoritative_simulation_enabled(false)
	_expect(
		enemy.authoritative_simulation_driver
		== Enemy.AuthoritativeSimulationDriver.SCHEDULED_SUSPENDED,
		"Central suspension must preserve ownership without simulation."
	)
	coordinator.set_mode(EnemySimulationPolicy.Mode.LEGACY)
	_expect(
		enemy.authoritative_simulation_driver
		== Enemy.AuthoritativeSimulationDriver.INDIVIDUAL,
		"Rollback must restore the individual driver even for a suspended enemy."
	)
	_expect(
		not enemy.is_physics_processing(),
		"A suspended enemy must remain paused when ownership returns to LEGACY."
	)
	enemy.queue_free()
	await physics_frame


func _test_compat_tick_matches_legacy(
	runtime: EnemyGameplayGatewayTestRuntime,
	coordinator: EnemySimulationCoordinator
) -> void:
	coordinator.set_mode(EnemySimulationPolicy.Mode.LEGACY)
	var legacy_enemy := FAST_CONFIG.enemy_scene.instantiate() as YuanshiInsect
	runtime.enemy_container.add_child(legacy_enemy)
	legacy_enemy.setup(FAST_CONFIG, null, runtime.grid_pathfinder, null)
	legacy_enemy.set_physics_process(false)

	coordinator.set_mode(EnemySimulationPolicy.Mode.COMPAT_60)
	var compat_enemy := _spawn_enemy(runtime)
	coordinator.set_physics_process(false)
	await physics_frame

	legacy_enemy.global_position = Vector2(-128.0, -128.0)
	compat_enemy.global_position = Vector2(128.0, 128.0)
	legacy_enemy.touch_damage_cooldown_left = 1.0
	compat_enemy.touch_damage_cooldown_left = 1.0
	legacy_enemy.velocity = Vector2(4.0, -2.0)
	compat_enemy.velocity = Vector2(4.0, -2.0)
	legacy_enemy._physics_process(TEST_DELTA)
	coordinator._physics_process(TEST_DELTA)

	var legacy_signature := _capture_tick_signature(legacy_enemy)
	var compat_signature := _capture_tick_signature(compat_enemy)
	_expect(
		legacy_signature == compat_signature,
		"COMPAT_60 must preserve the real Yuanshi per-tick state transition."
	)
	_expect(
		compat_enemy.scheduled_authoritative_step_count == 1,
		"The paired compatibility sample must consume exactly one scheduled step."
	)

	coordinator.set_mode(EnemySimulationPolicy.Mode.LEGACY)
	legacy_enemy.queue_free()
	compat_enemy.queue_free()
	await physics_frame


func _test_live_forward_handoff(
	runtime: EnemyGameplayGatewayTestRuntime,
	coordinator: EnemySimulationCoordinator
) -> void:
	coordinator.set_mode(EnemySimulationPolicy.Mode.LEGACY)
	var enemy := _spawn_enemy(runtime)
	_expect(
		not enemy.is_centrally_simulated() and enemy.is_physics_processing(),
		"A LEGACY enemy must begin with its individual callback."
	)
	coordinator.set_mode(EnemySimulationPolicy.Mode.COMPAT_60)
	_expect(
		enemy.is_centrally_simulated(),
		"A live forward A/B switch must claim existing supported enemies."
	)
	_expect(
		not enemy.is_physics_processing(),
		"A live forward handoff must atomically disable individual processing."
	)
	coordinator.set_mode(EnemySimulationPolicy.Mode.LEGACY)
	_expect(
		not enemy.is_centrally_simulated(),
		"The live forward sample must remain safely reversible."
	)
	enemy.queue_free()
	await physics_frame


func _capture_tick_signature(enemy: YuanshiInsect) -> Dictionary:
	return {
		"cooldown": snappedf(enemy.touch_damage_cooldown_left, 0.000001),
		"velocity": enemy.velocity,
		"position_delta": enemy.global_position.abs(),
		"is_dead": enemy.is_dead,
		"has_contact": enemy.call("_has_player_contact"),
	}


func _spawn_enemy(runtime: EnemyGameplayGatewayTestRuntime) -> YuanshiInsect:
	var enemy := FAST_CONFIG.enemy_scene.instantiate() as YuanshiInsect
	runtime.enemy_container.add_child(enemy)
	enemy.setup(FAST_CONFIG, null, runtime.grid_pathfinder, runtime)
	return enemy


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
