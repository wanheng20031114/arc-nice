extends SceneTree

const POLICY := preload(
	"res://scene/combat/simulation/enemy_simulation_policy.gd"
)
const RUNTIME_SCENE := preload(
	"res://dev_tools/fixtures/combat_robot_gunner_layered_semantic_runtime.tscn"
)
const GUNNER_CONFIG := preload(
	"res://resources/config/enemies/combat_robot_gunner.tres"
)
const TARGET_CONFIG := preload(
	"res://resources/config/enemies/yuanshi_insect_basic.tres"
)

const PHYSICS_DELTA := 1.0 / 60.0
const SOURCE_NET_ID := 93_201
const TARGET_A_NET_ID := 93_202
const TARGET_B_NET_ID := 93_203

var failures: Array[String] = []


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	await _verify_shared_contact_three_state_gate()

	var result := {
		"status": "ok" if failures.is_empty() else "failed",
		"shared_contact_promoted": true,
		"indexed_touch_promoted": false,
		"failures": failures.duplicate(),
	}
	print(
		"COMBAT_ROBOT_GUNNER_SHARED_CONTACT_JSON %s"
		% JSON.stringify(result)
	)
	if failures.is_empty():
		print("COMBAT_ROBOT_GUNNER_SHARED_CONTACT_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _verify_shared_contact_three_state_gate() -> void:
	var runtime := RUNTIME_SCENE.instantiate() as EnemyGameplayGatewayTestRuntime
	runtime.runtime_mode = CombatRuntimeBase.RuntimeMode.SINGLEPLAYER
	var coordinator := runtime.get_enemy_simulation_coordinator()
	coordinator.set_mode(POLICY.Mode.LAYERED_CONTACT)
	root.add_child(runtime)
	coordinator.set_physics_process(false)
	var service := runtime.get_enemy_contact_service()
	var source: Variant = runtime.get_node("EnemyContainer/GunnerSource")
	var target_a := runtime.get_node("EnemyContainer/TargetA") as Enemy
	var target_b := runtime.get_node("EnemyContainer/TargetB") as Enemy

	var source_config := GUNNER_CONFIG.duplicate(true) as CombatRobotGunnerConfig
	source_config.move_speed = 2400.0
	source_config.stop_distance = 0.0
	source_config.attack_range = 200.0
	source_config.burst_count = 4
	source_config.burst_fire_interval = PHYSICS_DELTA * 2.0
	source_config.burst_move_speed_multiplier = 0.5
	source_config.attack_cooldown = PHYSICS_DELTA * 4.0
	source_config.drop_table = null
	source_config.xirang_kill_reward = 0
	_setup_source(source, source_config, runtime)
	_setup_target(target_a, runtime, TARGET_A_NET_ID)
	_setup_target(target_b, runtime, TARGET_B_NET_ID)
	_reset_source(source, target_a)
	target_a.global_position = Vector2.ZERO
	target_b.global_position = Vector2(-200.0, 0.0)
	target_a.set_objective_target(null)
	target_b.set_objective_target(null)
	var authored_area_contract := _capture_authored_area_contract(source)

	await physics_frame
	_disable_automatic_callbacks(coordinator, source, [target_a, target_b])
	_expect(
		source.supports_layered_contact_authoritative_simulation()
		and not source.supports_indexed_touch_authority()
		and not source.is_indexed_touch_authority_enabled(),
		"Gunner must admit shared Enemy contact without indexed Player/Plant authority."
	)
	_expect(
		_capture_authored_area_contract(source) == authored_area_contract,
		"CONTACT admission must leave the authored Player/Plant Area untouched."
	)

	# State 1: outside -> swept ENTER. A 2400 px/s plan crosses the complete
	# 30-pixel gap, so authoritative TOI must clip at the exact rectangle/capsule
	# shell before motion and the immediate shot scheduler observe the transform.
	var outside_position: Vector2 = source.global_position
	await _advance_one_tick(coordinator, source, [target_a, target_b])
	# Contact registrations are deliberately admitted only at a coordinator tick
	# boundary. The fixture keeps automatic processing disabled, so tick 1 is both
	# the first legal admission point and the outside-to-swept-ENTER transition.
	var source_contact_owned: bool = service.owns_enemy(source)
	var target_a_contact_owned: bool = service.owns_enemy(target_a)
	var target_b_contact_owned: bool = service.owns_enemy(target_b)
	_expect(
		source_contact_owned
		and target_a_contact_owned
		and target_b_contact_owned,
		(
			"CONTACT must own Gunner and both hostile-target fixtures "
			+ "(source=%s, target_a=%s, target_b=%s)."
			% [source_contact_owned, target_a_contact_owned, target_b_contact_owned]
		)
	)
	var swept_position: Vector2 = source.global_position
	var swept_fraction := service.get_directed_safe_motion_fraction(
		source,
		target_a
	)
	_expect(
		service.has_planned_directed_contact(source, target_a)
		and not service.has_directed_contact(source, target_a)
		and swept_fraction > 0.0
		and swept_fraction < 1.0,
		"Outside pursuit must publish a planned swept ENTER and a strict TOI fraction."
	)
	_expect(
		swept_position.x > outside_position.x
		and swept_position.x < target_a.global_position.x
		and target_a.global_position.x - swept_position.x >= 11.9
		and source.velocity == Vector2.ZERO,
		"Gunner motion must consume TOI, stop on the shell, and never cross the Enemy target."
	)
	_expect(
		source.get_layered_area_contact_target() == target_a,
		"Tracking must explicitly publish the hostile Enemy it is pursuing."
	)

	# State 2: the following current snapshot confirms STAY. No transform or
	# projectile side effect may occur merely because shared contact is current.
	await _advance_one_tick(coordinator, source, [target_a, target_b])
	_expect(
		service.has_directed_contact(source, target_a)
		and source.global_position.is_equal_approx(swept_position)
		and source.velocity == Vector2.ZERO
		and source.shot_records.is_empty(),
		"Current STAY must keep the tracking Gunner stopped without inventing a shot."
	)

	# State 3: relation mutation produces EXIT and clears the explicit target.
	# Because indexed contact remains disabled, this transition cannot rewrite the
	# Player/Plant Area's monitoring, masks, shape, or signal connections.
	target_a.set_combat_faction_id(
		CombatRelationService.HOSTILE_WAVE,
		2,
		true
	)
	source.forced_move_direction = Vector2.LEFT
	source.request_layered_area_urgent_decision()
	await _advance_one_tick(coordinator, source, [target_a, target_b])
	_expect(
		not service.has_directed_contact(source, target_a)
		and not service.has_planned_directed_contact(source, target_a)
		and source.get_layered_area_contact_target() == null
		and source.global_position.x < swept_position.x,
		"Faction change must emit EXIT, clear the shared target, and release movement."
	)
	_expect(
		_capture_authored_area_contract(source) == authored_area_contract,
		"Shared EXIT must not disturb authored Player/Plant Area state."
	)

	# Ordinary tracking switches to B and republishes it. The next accepted burst
	# freezes B even when objective/automatic preference changes to A mid-burst.
	source.forced_target = target_b
	source.forced_target_valid = true
	source.forced_target_in_range = false
	source.forced_move_direction = Vector2.LEFT
	source.set_objective_target(target_b)
	source.request_layered_area_urgent_decision()
	await _advance_one_tick(coordinator, source, [target_a, target_b])
	_expect(
		source.combat_state == CombatRobotGunner.CombatState.TRACKING_READY
		and source.get_layered_area_contact_target() == target_b,
		"Tracking target changes must be published in the same decision tick."
	)

	source.forced_target_in_range = true
	source.request_layered_area_urgent_decision()
	await _advance_one_tick(coordinator, source, [target_a, target_b])
	_expect(
		source.combat_state == CombatRobotGunner.CombatState.BURST
		and source.burst_target == target_b
		and source.get_layered_area_contact_target() == target_b
		and source.shot_records.size() == 1,
		"Burst commit must publish its frozen hostile Enemy and fire only after motion."
	)
	var first_shot := source.shot_records[0] as Dictionary
	_expect(
		int(first_shot.get("position_x", 0))
		== roundi((source.global_position.x - 14.0) * 1_000_000.0),
		"The immediate burst projectile must observe the post-motion mirrored muzzle."
	)

	# Change the navigation objective independently from the already committed
	# burst. The preferred-target fixture remains B so B is still a valid combat
	# node; this isolates Gunner's authored burst lock from ordinary retargeting.
	source.set_objective_target(target_a)
	source.request_layered_area_urgent_decision()
	await _advance_one_tick(coordinator, source, [target_a, target_b])
	_expect(
		source.combat_state == CombatRobotGunner.CombatState.BURST
		and source.burst_target == target_b
		and source.get_layered_area_contact_target() == target_b,
		"A committed burst contact target must not follow later objective changes."
	)

	target_b.set_combat_faction_id(
		CombatRelationService.HOSTILE_WAVE,
		2,
		true
	)
	await _advance_one_tick(coordinator, source, [target_a, target_b])
	_expect(
		source.combat_state == CombatRobotGunner.CombatState.BURST
		and source.burst_target == null
		and source.get_layered_area_contact_target() == null
		and not service.has_directed_contact(source, target_b),
		"Burst target faction change must clear shared authority without truncating the burst."
	)

	var rollback_state := _capture_burst_state(source)
	coordinator.set_mode(POLICY.Mode.LEGACY)
	_expect(
		_capture_burst_state(source) == rollback_state
		and not source.is_centrally_simulated()
		and source.is_physics_processing()
		and not service.owns_enemy(source)
		and not source.is_indexed_touch_authority_enabled()
		and _capture_authored_area_contract(source) == authored_area_contract,
		"Rollback must preserve burst state, release shared authority, and restore the untouched Area."
	)
	source.set_physics_process(false)
	coordinator.set_physics_process(false)
	runtime.queue_free()
	await process_frame


func _setup_source(
	source: Variant,
	config: CombatRobotGunnerConfig,
	runtime: EnemyGameplayGatewayTestRuntime
) -> void:
	source.set_meta(&"net_id", SOURCE_NET_ID)
	source.setup(config, null, null, runtime)
	runtime.register_network_enemy(SOURCE_NET_ID, source)
	source.set_combat_faction_id(
		CombatRelationService.HOSTILE_WAVE,
		1,
		true
	)


func _setup_target(
	target: Enemy,
	runtime: EnemyGameplayGatewayTestRuntime,
	net_id: int
) -> void:
	var config := TARGET_CONFIG.duplicate(true) as EnemyConfig
	config.move_speed = 0.0
	config.drop_table = null
	config.xirang_kill_reward = 0
	target.set_meta(&"net_id", net_id)
	target.setup(config, null, null, runtime)
	runtime.register_network_enemy(net_id, target)
	target.set_combat_faction_id(
		CombatRelationService.PLAYER_ALLIED,
		1,
		true
	)


func _reset_source(source: Variant, target: Enemy) -> void:
	source.global_position = Vector2(-30.0, 0.0)
	source.velocity = Vector2.ZERO
	source.combat_state = CombatRobotGunner.CombatState.TRACKING_READY
	source.attack_cooldown_left = 0.0
	source.burst_target = null
	source.burst_shots_fired = 0
	source.burst_fire_time_left = 0.0
	source.locked_fire_direction = Vector2.RIGHT
	source.forced_target = target
	source.forced_target_valid = true
	source.forced_target_in_range = false
	source.forced_move_direction = Vector2.RIGHT
	source.force_straight_contact_plan_certified = true
	source.semantic_tick = 0
	source.reset_semantic_trace()
	source.random_generator.seed = 20_260_824
	source.material_drop_random_generator.seed = 20_260_825
	source.set_objective_target(target)
	source.request_layered_area_urgent_decision()


func _advance_one_tick(
	coordinator: EnemySimulationCoordinator,
	source: Variant,
	other_nodes: Array
) -> void:
	await physics_frame
	_disable_automatic_callbacks(coordinator, source, other_nodes)
	coordinator.call(&"_physics_process", PHYSICS_DELTA)
	coordinator.set_physics_process(false)


func _disable_automatic_callbacks(
	coordinator: EnemySimulationCoordinator,
	source: Variant,
	other_nodes: Array
) -> void:
	coordinator.set_physics_process(false)
	if source != null and is_instance_valid(source):
		source.set_process(false)
		source.set_physics_process(false)
	for node_variant in other_nodes:
		if node_variant == null or not is_instance_valid(node_variant):
			continue
		var node := node_variant as Node
		node.set_process(false)
		node.set_physics_process(false)


func _capture_authored_area_contract(source: Enemy) -> Dictionary:
	var area := source.touch_damage_area
	var shape := area.get_node("CollisionShape2D") as CollisionShape2D
	return {
		"monitoring": area.monitoring,
		"monitorable": area.monitorable,
		"collision_layer": area.collision_layer,
		"collision_mask": area.collision_mask,
		"shape_disabled": shape.disabled,
		"shape_resource_id": shape.shape.get_instance_id(),
		"shape_position": shape.position,
		"shape_rotation": shape.rotation,
		"body_entered_connected": area.body_entered.is_connected(
			Callable(source, &"_on_touch_damage_area_body_entered")
		),
		"body_exited_connected": area.body_exited.is_connected(
			Callable(source, &"_on_touch_damage_area_body_exited")
		),
	}


func _capture_burst_state(source: Variant) -> Dictionary:
	return {
		"state": source.combat_state,
		"position": source.global_position,
		"velocity": source.velocity,
		"shots": source.burst_shots_fired,
		"fire_left": source.burst_fire_time_left,
		"direction": source.locked_fire_direction,
		"action_sequence": source.action_sequence,
		"shot_records": source.shot_records.duplicate(true),
		"rng": source.random_generator.state,
	}


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
