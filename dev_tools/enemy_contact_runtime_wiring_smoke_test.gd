extends SceneTree

const POLICY := preload(
	"res://scene/combat/simulation/enemy_simulation_policy.gd"
)
const RELATIONS := preload(
	"res://scene/combat/faction/combat_relation_service.gd"
)
const RUNTIME_SCENE := preload(
	"res://dev_tools/fixtures/enemy_gameplay_gateway_test_runtime.tscn"
)
const FAST_CONFIG := preload(
	"res://resources/config/enemies/yuanshi_insect_fast.tres"
)
const PREDICTIVE_HARNESS_SCENE := preload(
	"res://dev_tools/fixtures/predictive_contact_yuanshi_harness.tscn"
)

const PRODUCTION_SCENES: Array[String] = [
	"res://scene/game_modes/standard/standard_game.tscn",
	"res://scene/game_modes/tower_defense/tower_defense_game.tscn",
	"res://scene/game_modes/rogue/combat/rogue_combat_game_01.tscn",
	"res://scene/game_modes/rogue/combat/rogue_combat_game_02.tscn",
	"res://scene/game_modes/rogue/combat/rogue_combat_game_03.tscn",
	"res://scene/game_modes/rogue/combat/rogue_combat_game_04.tscn",
]

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_authored_scene_contracts()
	await _test_runtime_ownership_contact_phase_and_rollback()
	await _test_high_speed_opposing_motion_clips_before_crossing()
	await _test_same_direction_pursuit_closes_without_false_stop()
	await _test_third_enemy_objective_remains_shadow_and_reaches_contact()
	await _test_non_mutual_transverse_crossing_is_not_frozen()
	await _test_asymmetric_mutual_shell_converges_without_crossing()
	await _test_same_tick_facing_mirror_recaptures_offset_segment()
	if failures.is_empty():
		print("ENEMY_CONTACT_RUNTIME_WIRING_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_authored_scene_contracts() -> void:
	for scene_path in PRODUCTION_SCENES:
		var source := FileAccess.get_file_as_string(scene_path)
		var has_coordinator := source.contains(
			"[node name=\"EnemySimulationCoordinator\" parent=\".\""
		)
		var has_contact_service := source.contains(
			"[node name=\"EnemyContactService\" parent=\".\""
		) and source.contains(
			"res://scene/combat/contact/enemy_contact_service.tscn"
		)
		_expect(
			has_coordinator and has_contact_service,
			"%s must author both simulation and contact siblings." % scene_path
		)


func _test_runtime_ownership_contact_phase_and_rollback() -> void:
	var runtime := RUNTIME_SCENE.instantiate() as EnemyGameplayGatewayTestRuntime
	root.add_child(runtime)
	await process_frame
	var coordinator := runtime.get_enemy_simulation_coordinator()
	var service := runtime.get_enemy_contact_service()
	_expect(coordinator != null and service != null, "The runtime fixture must author both services.")
	if coordinator == null or service == null:
		runtime.queue_free()
		await process_frame
		return
	_expect(
		runtime.get_combat_relation_service()
		== runtime.get_combat_relation_service()
		and runtime.get_combat_query_facade()
		== runtime.get_combat_query_facade(),
		"Combat relation and query services must have one stable runtime owner."
	)
	_expect(
		coordinator.mode == POLICY.Mode.LEGACY
		and service.mode == EnemyContactService.Mode.DISABLED
		and not service.automatic_physics_step,
		"LEGACY must leave the explicitly scheduled contact service disabled."
	)

	runtime.enable_singleplayer_combat_target_index(true)
	coordinator.set_mode(POLICY.Mode.LAYERED_AREA)
	var attacker := FAST_CONFIG.enemy_scene.instantiate() as YuanshiInsect
	var target := FAST_CONFIG.enemy_scene.instantiate() as YuanshiInsect
	attacker.global_position = Vector2.ZERO
	target.global_position = Vector2.ZERO
	runtime.enemy_container.add_child(attacker)
	runtime.enemy_container.add_child(target)
	attacker.setup(FAST_CONFIG, null, runtime.grid_pathfinder, runtime)
	target.setup(FAST_CONFIG, null, runtime.grid_pathfinder, runtime)
	target.set_combat_faction_id(RELATIONS.PLAYER_ALLIED)
	var attacker_id := coordinator.get_simulation_id(
		attacker,
		attacker.enemy_simulation_token
	)
	var target_id := coordinator.get_simulation_id(
		target,
		target.enemy_simulation_token
	)
	await physics_frame
	await physics_frame
	_expect(
		attacker_id > 0
		and target_id > 0
		and service.owns_enemy(attacker, attacker_id)
		and service.owns_enemy(target, target_id),
		"Layered enemies with authored touch/body shapes must register contact proxies."
	)

	await physics_frame
	var service_metrics: Dictionary = service.get_metrics()
	var coordinator_metrics: Dictionary = coordinator.get_metrics()
	_expect(
		service.mode == EnemyContactService.Mode.HYBRID_ENEMY_CONTACT
		and int(coordinator_metrics["contact_phases"]) > 0
		and int(service_metrics["hybrid_enemy_contact_ticks"]) > 0
		and int(service_metrics["predicted_event_stream_skips_total"]) > 0,
		"Contact must step exactly inside LAYERED_AREA between event and decision phases."
	)
	_expect(
		service.has_directed_contact(attacker, target)
		and service.has_directed_contact(target, attacker),
		"Runtime hostile AABB wiring must expose overlapping enemy-enemy contact."
	)

	coordinator.set_mode(POLICY.Mode.LEGACY)
	service_metrics = service.get_metrics()
	_expect(
		service.mode == EnemyContactService.Mode.DISABLED
		and int(service_metrics["registered_count"]) == 0
		and not service.has_directed_contact(attacker, target),
		"Tick-boundary rollback must clear proxies and restore DISABLED immediately."
	)
	_expect(
		not attacker.is_centrally_simulated()
		and not target.is_centrally_simulated(),
		"Contact rollback must not interfere with legacy enemy callback restoration."
	)
	runtime.queue_free()
	await process_frame
	await physics_frame


func _test_high_speed_opposing_motion_clips_before_crossing() -> void:
	var runtime := RUNTIME_SCENE.instantiate() as EnemyGameplayGatewayTestRuntime
	root.add_child(runtime)
	await process_frame
	runtime.enable_singleplayer_combat_target_index(true)
	var coordinator := runtime.get_enemy_simulation_coordinator()
	var service := runtime.get_enemy_contact_service()
	coordinator.set_mode(POLICY.Mode.LAYERED_AREA)
	var high_speed_config := FAST_CONFIG.duplicate(true) as YuanshiInsectConfig
	var left := PREDICTIVE_HARNESS_SCENE.instantiate() as YuanshiInsect
	var right := PREDICTIVE_HARNESS_SCENE.instantiate() as YuanshiInsect
	left.set("forced_move_direction", Vector2.RIGHT)
	right.set("forced_move_direction", Vector2.LEFT)
	left.set("forced_move_speed", 2400.0)
	right.set("forced_move_speed", 2400.0)
	left.global_position = Vector2(-20.0, 0.0)
	right.global_position = Vector2(20.0, 0.0)
	runtime.enemy_container.add_child(left)
	runtime.enemy_container.add_child(right)
	left.setup(high_speed_config, null, runtime.grid_pathfinder, runtime)
	right.setup(high_speed_config, null, runtime.grid_pathfinder, runtime)
	right.set_combat_faction_id(RELATIONS.PLAYER_ALLIED)
	left.set_objective_target(right)
	right.set_objective_target(left)
	# Keep the test deterministic: advance the authored coordinator manually only
	# after the registration activation frame has elapsed.
	coordinator.set_physics_process(false)
	await physics_frame
	var left_start := left.global_position
	var right_start := right.global_position
	coordinator._physics_process(1.0 / 60.0)
	var first_left := left.global_position
	var first_right := right.global_position
	_expect(
		first_left.x < first_right.x,
		"Opposing 2400 px/s enemies must not exchange sides in their first movement tick."
	)
	_expect(
		first_left.x > left_start.x
		and first_right.x < right_start.x
		and first_left.distance_to(first_right) >= 11.9,
		"Predictive TOI must advance both enemies to, but not through, the authored shell."
	)
	_expect(
		left.velocity == Vector2.ZERO and right.velocity == Vector2.ZERO,
		"A TOI-clipped enemy must report stopped velocity in the same tick."
	)

	await physics_frame
	coordinator._physics_process(1.0 / 60.0)
	_expect(
		left.global_position.is_equal_approx(first_left)
		and right.global_position.is_equal_approx(first_right)
		and service.has_directed_contact(left, right)
		and service.has_directed_contact(right, left),
		"The next current snapshot must confirm shell contact without a one-frame overshoot."
	)
	coordinator.set_mode(POLICY.Mode.LEGACY)
	runtime.queue_free()
	await process_frame
	await physics_frame


func _test_same_direction_pursuit_closes_without_false_stop() -> void:
	var runtime := RUNTIME_SCENE.instantiate() as EnemyGameplayGatewayTestRuntime
	root.add_child(runtime)
	await process_frame
	runtime.enable_singleplayer_combat_target_index(true)
	var coordinator := runtime.get_enemy_simulation_coordinator()
	var service := runtime.get_enemy_contact_service()
	coordinator.set_mode(POLICY.Mode.LAYERED_AREA)
	var pursuer := _spawn_harness(runtime, Vector2.ZERO, Vector2.RIGHT, 120.0)
	var target := _spawn_harness(runtime, Vector2(30.0, 0.0), Vector2.RIGHT, 60.0)
	target.set_combat_faction_id(RELATIONS.PLAYER_ALLIED)
	var non_enemy_objective := Node2D.new()
	non_enemy_objective.position = Vector2(300.0, 0.0)
	runtime.add_child(non_enemy_objective)
	pursuer.set_objective_target(target)
	target.set_objective_target(non_enemy_objective)
	coordinator.set_physics_process(false)
	await physics_frame
	var previous_gap := target.global_position.x - pursuer.global_position.x
	var reached_shell := false
	var pursuer_start_x := pursuer.global_position.x
	for _tick in range(30):
		coordinator._physics_process(1.0 / 60.0)
		var gap := target.global_position.x - pursuer.global_position.x
		if gap > 12.1 and not service.has_directed_contact(pursuer, target):
			_expect(
				is_equal_approx(
					service.get_directed_safe_motion_fraction(pursuer, target),
					1.0
				),
				"A separated moving non-mutual target must remain shadow-only."
			)
		_expect(
			gap > 0.0,
			"A faster same-direction pursuer must never pass through its moving target."
		)
		if not reached_shell:
			_expect(
				gap <= previous_gap + 0.001,
				"Committed same-direction pursuit must close distance monotonically."
			)
		if gap <= 12.1:
			reached_shell = true
		previous_gap = gap
		await physics_frame
	_expect(
		reached_shell
		and pursuer.global_position.x > pursuer_start_x + 5.0
		and int(service.get_metrics()["uncommitted_pair_shadow_hits_total"]) > 0,
		"A faster pursuer must reach the authored shell instead of freezing at expanded range."
	)
	coordinator.set_mode(POLICY.Mode.LEGACY)
	runtime.queue_free()
	await process_frame
	await physics_frame


func _test_third_enemy_objective_remains_shadow_and_reaches_contact() -> void:
	var runtime := RUNTIME_SCENE.instantiate() as EnemyGameplayGatewayTestRuntime
	root.add_child(runtime)
	await process_frame
	runtime.enable_singleplayer_combat_target_index(true)
	var coordinator := runtime.get_enemy_simulation_coordinator()
	var service := runtime.get_enemy_contact_service()
	coordinator.set_mode(POLICY.Mode.LAYERED_AREA)
	var pursuer := _spawn_harness(runtime, Vector2.ZERO, Vector2.RIGHT, 120.0)
	var middle := _spawn_harness(runtime, Vector2(24.0, 0.0), Vector2.RIGHT, 60.0)
	var leader := _spawn_harness(runtime, Vector2(100.0, 0.0), Vector2.RIGHT, 60.0)
	middle.set_combat_faction_id(RELATIONS.PLAYER_ALLIED)
	pursuer.set_objective_target(middle)
	middle.set_objective_target(leader)
	var leader_objective := Node2D.new()
	leader_objective.position = Vector2(300.0, 0.0)
	runtime.add_child(leader_objective)
	leader.set_objective_target(leader_objective)
	coordinator.set_physics_process(false)
	await physics_frame
	var reached_current_contact := false
	for _tick in range(30):
		coordinator._physics_process(1.0 / 60.0)
		_expect(
			pursuer.global_position.x < middle.global_position.x,
			"A shadow-only dependency pair must not pass through at normal authored speed."
		)
		if service.has_directed_contact(pursuer, middle):
			reached_current_contact = true
		await physics_frame
	_expect(
		reached_current_contact
		and int(service.get_metrics()["uncommitted_pair_shadow_hits_total"]) > 0,
		"A->B->C must remain shadow-only yet still reach exact current contact."
	)
	coordinator.set_mode(POLICY.Mode.LEGACY)
	runtime.queue_free()
	await process_frame
	await physics_frame


func _test_non_mutual_transverse_crossing_is_not_frozen() -> void:
	var runtime := RUNTIME_SCENE.instantiate() as EnemyGameplayGatewayTestRuntime
	root.add_child(runtime)
	await process_frame
	runtime.enable_singleplayer_combat_target_index(true)
	var coordinator := runtime.get_enemy_simulation_coordinator()
	var service := runtime.get_enemy_contact_service()
	coordinator.set_mode(POLICY.Mode.LAYERED_AREA)
	var horizontal := _spawn_harness(
		runtime, Vector2(-20.0, 0.0), Vector2.RIGHT, 2400.0
	)
	var vertical := _spawn_harness(
		runtime, Vector2(0.0, -20.0), Vector2.DOWN, 2400.0
	)
	var third := _spawn_harness(
		runtime, Vector2(0.0, 100.0), Vector2.ZERO, 0.0
	)
	vertical.set_combat_faction_id(RELATIONS.PLAYER_ALLIED)
	horizontal.set_objective_target(vertical)
	vertical.set_objective_target(third)
	var third_objective := Node2D.new()
	third_objective.position = third.position
	runtime.add_child(third_objective)
	third.set_objective_target(third_objective)
	coordinator.set_physics_process(false)
	await physics_frame
	coordinator._physics_process(1.0 / 60.0)
	_expect(
		horizontal.global_position.x > 19.5
		and vertical.global_position.y > 19.5
		and is_equal_approx(
			service.get_directed_safe_motion_fraction(horizontal, vertical),
			1.0
		),
		"A non-mutual transverse shadow pair must execute full plans instead of freezing."
	)
	_expect(
		int(service.get_metrics()["uncommitted_pair_shadow_hits_total"]) > 0,
		"A transverse authority skip must be explicitly measured."
	)
	coordinator.set_mode(POLICY.Mode.LEGACY)
	runtime.queue_free()
	await process_frame
	await physics_frame


func _test_asymmetric_mutual_shell_converges_without_crossing() -> void:
	var runtime := RUNTIME_SCENE.instantiate() as EnemyGameplayGatewayTestRuntime
	root.add_child(runtime)
	await process_frame
	runtime.enable_singleplayer_combat_target_index(true)
	var coordinator := runtime.get_enemy_simulation_coordinator()
	coordinator.set_mode(POLICY.Mode.LAYERED_AREA)
	var left := _spawn_harness(
		runtime, Vector2(-20.0, 0.0), Vector2.RIGHT, 2400.0
	)
	var right := PREDICTIVE_HARNESS_SCENE.instantiate() as YuanshiInsect
	right.set("forced_move_direction", Vector2.LEFT)
	right.set("forced_move_speed", 2400.0)
	right.global_position = Vector2(20.0, 0.0)
	var large_touch := CapsuleShape2D.new()
	large_touch.radius = 5.0
	large_touch.height = 20.0
	right.get_node("TouchDamageArea/CollisionShape2D").shape = large_touch
	runtime.enemy_container.add_child(right)
	right.setup(FAST_CONFIG, null, runtime.grid_pathfinder, runtime)
	right.set_combat_faction_id(RELATIONS.PLAYER_ALLIED)
	left.set_objective_target(right)
	right.set_objective_target(left)
	coordinator.set_physics_process(false)
	await physics_frame
	var gaps: Array[float] = []
	for _tick in range(3):
		coordinator._physics_process(1.0 / 60.0)
		gaps.append(right.global_position.x - left.global_position.x)
		_expect(
			left.global_position.x < right.global_position.x,
			"Asymmetric mutual shells must never swap sides across follow-up ticks."
		)
		await physics_frame
	_expect(
		gaps[1] < gaps[0] - 0.01
		and gaps[2] <= gaps[1] + 0.01
		and gaps[2] >= 11.9,
		"After the larger shell stops, the smaller shell must keep closing without oscillation."
	)
	var service := runtime.get_enemy_contact_service()
	_expect(
		service.has_directed_contact(left, right)
		and service.has_directed_contact(right, left),
		"Asymmetric mutual pursuit must finish inside both directed attack shells."
	)
	coordinator.set_mode(POLICY.Mode.LEGACY)
	runtime.queue_free()
	await process_frame
	await physics_frame


func _test_same_tick_facing_mirror_recaptures_offset_segment() -> void:
	var runtime := RUNTIME_SCENE.instantiate() as EnemyGameplayGatewayTestRuntime
	root.add_child(runtime)
	await process_frame
	runtime.enable_singleplayer_combat_target_index(true)
	var coordinator := runtime.get_enemy_simulation_coordinator()
	var service := runtime.get_enemy_contact_service()
	coordinator.set_mode(POLICY.Mode.LAYERED_AREA)
	var turner := PREDICTIVE_HARNESS_SCENE.instantiate() as YuanshiInsect
	turner.set("forced_move_direction", Vector2.LEFT)
	turner.set("forced_move_speed", 2400.0)
	turner.global_position = Vector2(20.0, 0.0)
	var touch_shape_node := (
		turner.get_node("TouchDamageArea/CollisionShape2D") as CollisionShape2D
	)
	touch_shape_node.position = Vector2(1.0, 0.0)
	var authored_segment := SegmentShape2D.new()
	authored_segment.a = Vector2(-2.0, 0.0)
	authored_segment.b = Vector2(4.0, 0.0)
	touch_shape_node.shape = authored_segment
	var body_shape_node := turner.get_node("CollisionShape2D") as CollisionShape2D
	body_shape_node.position = Vector2(1.0, 0.0)
	runtime.enemy_container.add_child(turner)
	turner.setup(FAST_CONFIG, null, runtime.grid_pathfinder, runtime)
	turner.set_combat_faction_id(RELATIONS.PLAYER_ALLIED)
	var target := _spawn_harness(
		runtime, Vector2.ZERO, Vector2.ZERO, 0.0
	)
	var target_objective := Node2D.new()
	target_objective.position = target.position
	runtime.add_child(target_objective)
	turner.set_objective_target(target)
	target.set_objective_target(target_objective)
	coordinator.set_physics_process(false)
	await physics_frame
	coordinator._physics_process(1.0 / 60.0)
	var mirrored_segment := touch_shape_node.shape as SegmentShape2D
	_expect(
		turner.facing_left
		and is_equal_approx(touch_shape_node.position.x, -1.0)
		and mirrored_segment != null
		and mirrored_segment.a.is_equal_approx(Vector2(2.0, 0.0))
		and mirrored_segment.b.is_equal_approx(Vector2(-4.0, 0.0)),
		"Decision must commit offset/Segment facing geometry before planned contact sampling."
	)
	_expect(
		absf(turner.global_position.x - 7.0) <= 0.01
		and int(service.get_metrics()["shape_proxy_updates_total"]) >= 1,
		(
			"Same-tick TOI must use the recaptured mirrored segment, not its stale +X core "
			+ "(source_x=%.3f, target_x=%.3f, fraction=%.5f, proxy_updates=%d)."
		) % [
			turner.global_position.x,
			target.global_position.x,
			service.get_directed_safe_motion_fraction(turner, target),
			int(service.get_metrics()["shape_proxy_updates_total"]),
		]
	)
	await physics_frame
	coordinator._physics_process(1.0 / 60.0)
	_expect(
		service.has_directed_contact(turner, target)
		and turner.global_position.x >= target.global_position.x,
		"The mirrored offset shell must become exact current contact without crossing."
	)
	coordinator.set_mode(POLICY.Mode.LEGACY)
	runtime.queue_free()
	await process_frame
	await physics_frame


func _spawn_harness(
	runtime: EnemyGameplayGatewayTestRuntime,
	spawn_position: Vector2,
	move_direction: Vector2,
	move_speed: float
) -> YuanshiInsect:
	var enemy := PREDICTIVE_HARNESS_SCENE.instantiate() as YuanshiInsect
	enemy.set("forced_move_direction", move_direction)
	enemy.set("forced_move_speed", move_speed)
	enemy.global_position = spawn_position
	runtime.enemy_container.add_child(enemy)
	enemy.setup(FAST_CONFIG, null, runtime.grid_pathfinder, runtime)
	return enemy


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
