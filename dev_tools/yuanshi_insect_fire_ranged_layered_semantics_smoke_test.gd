extends SceneTree

const POLICY := preload(
	"res://scene/combat/simulation/enemy_simulation_policy.gd"
)
const RUNTIME_SCENE := preload(
	"res://dev_tools/fixtures/enemy_gameplay_gateway_test_runtime.tscn"
)
const HARNESS_SCENE := preload(
	"res://dev_tools/fixtures/yuanshi_insect_fire_ranged_layered_semantic_harness.tscn"
)
const FIRE_CONFIG := preload(
	"res://resources/config/enemies/yuanshi_insect_fire_ranged.tres"
)

const PHYSICS_DELTA := 1.0 / 60.0
const COOLDOWN_TICKS := 3
const TEST_MODES: Array[int] = [
	POLICY.Mode.LEGACY,
	POLICY.Mode.LAYERED_AREA,
	POLICY.Mode.LAYERED_CONTACT,
]

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var tested_mode_names: Array[String] = []
	for simulation_mode in TEST_MODES:
		tested_mode_names.append(POLICY.mode_to_name(simulation_mode))
		await _verify_mode_semantics(simulation_mode)
	var result := {
		"status": "ok" if failures.is_empty() else "failed",
		"modes": tested_mode_names,
		"failures": failures.duplicate(),
	}
	print(
		"YUANSHI_FIRE_RANGED_LAYERED_SEMANTICS_JSON %s"
		% JSON.stringify(result)
	)
	if failures.is_empty():
		print("YUANSHI_FIRE_RANGED_LAYERED_SEMANTICS_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _verify_mode_semantics(simulation_mode: int) -> void:
	var mode_name := POLICY.mode_to_name(simulation_mode)
	var runtime := RUNTIME_SCENE.instantiate() as EnemyGameplayGatewayTestRuntime
	root.add_child(runtime)
	await process_frame

	var coordinator := runtime.get_enemy_simulation_coordinator()
	coordinator.set_mode(simulation_mode)
	var target := Node2D.new()
	target.name = "DeterministicRangedTarget"
	target.position = Vector2(64.0, 0.0)
	runtime.add_child(target)
	# The fixture script is intentionally loaded through its authored scene. Use a
	# Variant here so standalone --script runs do not depend on editor class-cache
	# discovery for this dev_tools-only class_name.
	var enemy: Variant = HARNESS_SCENE.instantiate()
	enemy.forced_target = target
	runtime.enemy_container.add_child(enemy)
	enemy.setup(FIRE_CONFIG, null, null, runtime)
	enemy.set_objective_target(target)
	enemy.set_physics_process(false)
	coordinator.set_physics_process(false)

	_expect(
		enemy.combat_state == YuanshiInsectFireRanged.CombatState.CHASE
		and enemy.animated_sprite != null
		and enemy.animated_sprite.sprite_frames.has_animation(
			FIRE_CONFIG.attack_animation_name
		),
		"%s fixture must retain the authored CHASE state and attack animation."
		% mode_name
	)
	if simulation_mode == POLICY.Mode.LEGACY:
		_expect(
			not enemy.is_centrally_simulated(),
			"LEGACY must keep the fire-ranged enemy outside coordinator ownership."
		)
	else:
		_expect(
			enemy.is_centrally_simulated()
			and coordinator.owns_enemy(
				enemy,
				enemy.enemy_simulation_token
			),
			"%s must own the authored fire-ranged scene through the coordinator."
			% mode_name
		)

	enemy.forced_combat_sense_due = false
	enemy.attack_cooldown_left = PHYSICS_DELTA * (COOLDOWN_TICKS - 0.5)
	for tick_index in range(COOLDOWN_TICKS):
		await _advance_one_tick(simulation_mode, coordinator, enemy)
		var expected_cooldown := maxf(
			PHYSICS_DELTA * (COOLDOWN_TICKS - 0.5 - float(tick_index + 1)),
			0.0
		)
		_expect(
			is_equal_approx(enemy.attack_cooldown_left, expected_cooldown),
			"%s cooldown must decrement once on 60 Hz tick %d (expected %.6f, got %.6f)."
			% [
				mode_name,
				tick_index + 1,
				expected_cooldown,
				enemy.attack_cooldown_left,
			]
		)
		_expect(
			enemy.combat_state == YuanshiInsectFireRanged.CombatState.CHASE,
			"%s must not begin an attack without a due combat-sense decision."
			% mode_name
		)
	_expect(
		enemy.touch_update_deltas.size() == COOLDOWN_TICKS,
		"%s event/touch semantics must also remain at 60 Hz during cooldown."
		% mode_name
	)

	enemy.forced_combat_sense_due = true
	var movement_before_attack: int = enemy.movement_submission_count
	await _advance_one_tick(simulation_mode, coordinator, enemy)
	_expect(
		enemy.combat_state == YuanshiInsectFireRanged.CombatState.ATTACK
		and enemy.committed_attack_target == target
		and is_equal_approx(
			enemy.attack_cooldown_left,
			FIRE_CONFIG.attack_interval
		),
		"%s must start ATTACK when the expired cooldown reaches a due decision."
		% mode_name
	)
	var expected_start_phase: StringName = (
		&"legacy"
		if simulation_mode == POLICY.Mode.LEGACY
		else &"decision"
	)
	_expect(
		enemy.attack_start_phases == [expected_start_phase],
		"%s attack may start only in %s, never in the layered event phase (got %s)."
		% [mode_name, expected_start_phase, enemy.attack_start_phases]
	)
	_expect(
		enemy.movement_submission_count == movement_before_attack
		and enemy.velocity == Vector2.ZERO
		and enemy.projectile_fire_attempt_count == 0
		and enemy.action_broadcast_count == 1
		and enemy.navigation_clear_count == 1,
		"%s ATTACK entry must stop motion and commit exactly one action without firing."
		% mode_name
	)

	# Freeze only visual time. The authored state/cooldown keeps advancing through
	# the physics driver, proving that physics ticks themselves are not a fire edge.
	enemy.animated_sprite.pause()
	await _advance_one_tick(simulation_mode, coordinator, enemy)
	_expect(
		enemy.combat_state == YuanshiInsectFireRanged.CombatState.ATTACK
		and enemy.movement_submission_count == movement_before_attack
		and enemy.projectile_fire_attempt_count == 0
		and enemy.action_broadcast_count == 1
		and is_equal_approx(
			enemy.attack_cooldown_left,
			FIRE_CONFIG.attack_interval - PHYSICS_DELTA
		),
		"%s ATTACK must keep 60 Hz cooldown while submitting no movement or duplicate action."
		% mode_name
	)

	_verify_single_frame_changed_fire_edge(enemy, mode_name)

	var fire_attempts_before_invalidation: int = enemy.projectile_fire_attempt_count
	enemy.forced_target_valid = false
	await _advance_one_tick(simulation_mode, coordinator, enemy)
	_expect(
		enemy.combat_state == YuanshiInsectFireRanged.CombatState.CHASE
		and enemy.committed_attack_target == null
		and not enemy.attack_has_fired
		and enemy.animated_sprite.animation == FIRE_CONFIG.move_animation_name,
		"%s must return to CHASE immediately when its committed target becomes invalid."
		% mode_name
	)
	enemy.call("_on_attack_animation_frame_changed")
	_expect(
		enemy.projectile_fire_attempt_count
		== fire_attempts_before_invalidation,
		"%s stale frame callbacks after target invalidation must not fire."
		% mode_name
	)

	if simulation_mode == POLICY.Mode.LAYERED_CONTACT:
		var contact_metrics: Dictionary = coordinator.get_metrics()
		_expect(
			coordinator.mode == POLICY.Mode.LAYERED_CONTACT
			and int(contact_metrics["contact_registrations"]) == 1
			and int(contact_metrics["contact_registration_rejections"]) == 0
			and int(contact_metrics["indexed_touch_authority_enables"]) == 1
			and enemy.is_indexed_touch_authority_enabled(),
			"LAYERED_CONTACT must retain shared/indexed contact ownership without fallback."
		)

	runtime.queue_free()
	await process_frame
	await physics_frame


func _advance_one_tick(
	simulation_mode: int,
	coordinator: EnemySimulationCoordinator,
	enemy: Variant
) -> void:
	coordinator.set_physics_process(false)
	enemy.set_physics_process(false)
	await physics_frame
	coordinator.set_physics_process(false)
	enemy.set_physics_process(false)
	if simulation_mode == POLICY.Mode.LEGACY:
		enemy.call("_run_authoritative_physics_step", PHYSICS_DELTA)
		return
	coordinator._physics_process(PHYSICS_DELTA)
	coordinator.set_physics_process(false)


func _verify_single_frame_changed_fire_edge(
	enemy: Variant,
	mode_name: String
) -> void:
	var callback := Callable(enemy, "_on_attack_animation_frame_changed")
	_expect(
		enemy.animated_sprite.frame_changed.is_connected(callback),
		"%s authored frame_changed signal must remain the projectile edge."
		% mode_name
	)
	enemy.animated_sprite.pause()
	var frame_count: int = enemy.animated_sprite.sprite_frames.get_frame_count(
		FIRE_CONFIG.attack_animation_name
	)
	var alternate_frame := (
		0 if FIRE_CONFIG.attack_fire_frame != 0 else mini(1, frame_count - 1)
	)
	enemy.animated_sprite.frame = alternate_frame
	var fire_attempts_before_edge: int = enemy.projectile_fire_attempt_count
	enemy.animated_sprite.frame = FIRE_CONFIG.attack_fire_frame
	_expect(
		enemy.projectile_fire_attempt_count == fire_attempts_before_edge + 1
		and enemy.attack_has_fired,
		"%s entering the authored fire frame must emit exactly one projectile attempt."
		% mode_name
	)
	enemy.call("_on_attack_animation_frame_changed")
	enemy.call("_on_attack_animation_frame_changed")
	enemy.animated_sprite.frame = alternate_frame
	enemy.animated_sprite.frame = FIRE_CONFIG.attack_fire_frame
	_expect(
		enemy.projectile_fire_attempt_count == fire_attempts_before_edge + 1,
		"%s repeated callbacks/re-entry into the same attack fire frame must not duplicate the shot."
		% mode_name
	)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
