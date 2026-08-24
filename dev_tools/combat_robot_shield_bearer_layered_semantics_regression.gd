extends SceneTree

## Future-migration acceptance for the B1 ShieldBearer family. This deliberately
## requires the production family to advertise both layered-area and indexed-
## touch capability, so it fails until that migration is actually implemented.

const POLICY := preload(
	"res://scene/combat/simulation/enemy_simulation_policy.gd"
)
const RUNTIME_SCENE := preload(
	"res://dev_tools/fixtures/enemy_gameplay_gateway_test_runtime.tscn"
)
const HARNESS_SCENE := preload(
	"res://dev_tools/fixtures/combat_robot_shield_bearer_layered_semantic_harness.tscn"
)
const PLAYER_SCENE := preload(
	"res://scene/player/weishidaier/player_weishidaier.tscn"
)
const SHIELD_CONFIG := preload(
	"res://resources/config/enemies/combat_robot_shield_bearer.tres"
)
const SHIELD_ELITE_CONFIG := preload(
	"res://resources/config/enemies/combat_robot_shield_bearer_elite.tres"
)

const PHYSICS_DELTA := 1.0 / 60.0
const TEST_TICKS := 17
const FIXED_SEED := 20_260_824
const SOURCE_NET_ID := 71_001
const TOUCH_DAMAGE := 11
const FAR_TARGET_POSITION := Vector2(256.0, 192.0)

const TEST_MODES: Array[int] = [
	POLICY.Mode.COMPAT_60,
	POLICY.Mode.LAYERED_AREA,
	POLICY.Mode.LAYERED_CONTACT,
]
const GAMEPLAY_FIELDS: PackedStringArray = [
	"tick",
	"position_x",
	"position_y",
	"velocity_x",
	"velocity_y",
	"touch_cooldown",
	"touching_players",
	"player_a_health",
	"player_b_health",
	"player_b_max_health",
	"objective",
	"faction",
	"faction_revision",
	"dead",
	"central_owned",
	"movement_submissions",
	"shield_durability",
	"behavior_rng",
	"drop_rng",
]

var failures: Array[String] = []


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	_verify_family_config_capabilities()
	var runs: Dictionary = {}
	for simulation_mode in TEST_MODES:
		runs[simulation_mode] = await _run_mode(simulation_mode)

	var compat_run: Dictionary = runs.get(POLICY.Mode.COMPAT_60, {})
	for layered_mode in [POLICY.Mode.LAYERED_AREA, POLICY.Mode.LAYERED_CONTACT]:
		_compare_gameplay_traces(
			compat_run,
			runs.get(layered_mode, {}),
			POLICY.mode_to_name(layered_mode)
		)

	var result := {
		"status": "ok" if failures.is_empty() else "failed",
		"fixed_seed": FIXED_SEED,
		"ticks": TEST_TICKS,
		"modes": _mode_names(),
		"trace_digests": _trace_digests(runs),
		"checkpoints": _checkpoint_diagnostics(runs),
		"failures": failures.duplicate(),
	}
	print(
		"SHIELD_BEARER_LAYERED_SEMANTICS_JSON %s"
		% JSON.stringify(result)
	)
	if failures.is_empty():
		print("SHIELD_BEARER_LAYERED_SEMANTICS_REGRESSION_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _verify_family_config_capabilities() -> void:
	for config in [SHIELD_CONFIG, SHIELD_ELITE_CONFIG]:
		var enemy := config.enemy_scene.instantiate() as CombatRobotShieldBearer
		_expect(
			enemy != null,
			"%s must instantiate the shared ShieldBearer runner."
			% config.resource_path
		)
		if enemy == null:
			continue
		_expect(
			enemy.supports_centralized_authoritative_simulation()
			and enemy.supports_layered_area_authoritative_simulation()
			and enemy.supports_dynamic_enemy_targeting()
			and enemy.supports_indexed_touch_authority(),
			"%s must publish the complete B1 layered capability set."
			% config.resource_path
		)
		enemy.free()


func _run_mode(simulation_mode: int) -> Dictionary:
	var mode_name := POLICY.mode_to_name(simulation_mode)
	var runtime := RUNTIME_SCENE.instantiate() as EnemyGameplayGatewayTestRuntime
	_expect(runtime != null, "%s must instantiate the authored runtime." % mode_name)
	if runtime == null:
		return {}
	runtime.runtime_mode = CombatRuntimeBase.RuntimeMode.SINGLEPLAYER
	root.add_child(runtime)
	await process_frame

	var coordinator := runtime.get_enemy_simulation_coordinator()
	_expect(coordinator != null, "%s must expose the coordinator." % mode_name)
	if coordinator == null:
		runtime.queue_free()
		await process_frame
		return {}
	coordinator.set_mode(simulation_mode)
	_expect(
		coordinator.mode == simulation_mode,
		"%s must enter the requested mode without a global fallback." % mode_name
	)

	var player_a := await _spawn_player(runtime, 1, "ShieldSemanticPlayerA")
	var player_b := await _spawn_player(runtime, 2, "ShieldSemanticPlayerB")
	runtime.player = player_a
	runtime.peer_players[1] = player_a
	runtime.peer_players[2] = player_b
	player_a.global_position = Vector2(256.0, 0.0)
	player_b.global_position = Vector2(-256.0, 0.0)

	# Load the test subclass through an inherited authored scene. Variant avoids a
	# dependency on editor class-cache discovery for the dev_tools-only class.
	var source: Variant = HARNESS_SCENE.instantiate()
	var source_config := SHIELD_CONFIG.duplicate(true) as EnemyConfig
	source_config.max_health = 80
	source_config.attack_damage = TOUCH_DAMAGE
	source_config.physical_defense = 0
	source_config.magic_defense = 0
	source_config.drop_table = null
	source_config.xirang_kill_reward = 0
	source.name = "ShieldBearerSemanticSource"
	source.set_meta(&"net_id", SOURCE_NET_ID)
	source.global_position = Vector2.ZERO
	runtime.enemy_container.add_child(source)
	source.setup(source_config, null, null, runtime)
	source.global_position = Vector2.ZERO
	_expect(
		runtime.register_network_enemy(SOURCE_NET_ID, source),
		"%s source must register in the production combat target index." % mode_name
	)

	_disable_automatic_callbacks(coordinator, source, player_a, player_b)
	await physics_frame
	await physics_frame
	_disable_automatic_callbacks(coordinator, source, player_a, player_b)
	# LAYERED_CONTACT enables indexed authority only when the coordinator admits
	# this exact registration for a real physics tick. Bootstrap every mode through
	# the same empty-objective tick, then reset observable fixture state before the
	# semantic trace begins.
	await _advance_one_tick(coordinator, source, player_a, player_b)
	source.global_position = Vector2.ZERO
	source.velocity = Vector2.ZERO
	source.touch_damage_cooldown_left = 0.0
	source.movement_submission_count = 0
	source.touch_update_count = 0
	source.touch_apply_count = 0
	# setup()/ready may initialize or consume family RNG. Seed after both lifecycle
	# boundaries (and after the admission bootstrap) so tick 0 is mode-independent.
	source.random_generator.seed = FIXED_SEED
	source.material_drop_random_generator.seed = FIXED_SEED + 1
	source.set_objective_target(player_a)

	# These are intentional future-facing hard gates. Today ShieldBearer only
	# advertises COMPAT and dynamic-target support, so this regression must fail.
	_expect(
		source.supports_dynamic_enemy_targeting(),
		"%s ShieldBearer must retain dynamic-target capability." % mode_name
	)
	_expect(
		bool(source.call(&"_uses_inherited_touch_damage")),
		"%s ShieldBearer must retain Enemy's inherited touch-damage contract."
		% mode_name
	)
	_expect(
		source.supports_layered_area_authoritative_simulation(),
		"%s B1 acceptance requires ShieldBearer layered-area capability." % mode_name
	)
	_expect(
		source.supports_indexed_touch_authority(),
		"%s B1 acceptance requires ShieldBearer indexed-touch capability." % mode_name
	)
	_expect(
		source.is_centrally_simulated()
		and coordinator.owns_enemy(source, source.enemy_simulation_token),
		"%s must centrally own ShieldBearer before the scripted ticks." % mode_name
	)
	if simulation_mode == POLICY.Mode.LAYERED_CONTACT:
		_expect(
			source.is_indexed_touch_authority_enabled(),
			"LAYERED_CONTACT must enable ShieldBearer indexed-touch authority."
		)
	else:
		_expect(
			not source.is_indexed_touch_authority_enabled(),
			"%s must keep the authored Area touch authority." % mode_name
		)

	var context := {
		"coordinator": coordinator,
		"source": source,
		"player_a": player_a,
		"player_b": player_b,
		"rollback_restored": false,
		"rollback_released_indexed": false,
		"lethal_result": false,
	}
	var snapshots: Array[Dictionary] = []
	snapshots.append(_capture_snapshot(0, source, player_a, player_b))
	for tick_index in range(1, TEST_TICKS + 1):
		_apply_pre_tick_script(tick_index, context)
		var scripted_contact_state := 0
		if tick_index >= 6 and tick_index <= 10:
			scripted_contact_state = 1
		elif tick_index == 11:
			scripted_contact_state = -1
		await _advance_one_tick(
			coordinator,
			source,
			player_a,
			player_b,
			scripted_contact_state
		)
		if tick_index == TEST_TICKS:
			context["lethal_result"] = _apply_lethal_damage(source)
		snapshots.append(
			_capture_snapshot(tick_index, source, player_a, player_b)
		)

	_validate_mode_invariants(mode_name, snapshots, context)
	var trace_lines := _canonical_trace_lines(snapshots)
	var run_result := {
		"mode": mode_name,
		"snapshots": snapshots,
		"trace_lines": trace_lines,
		"rollback_restored": context["rollback_restored"],
		"rollback_released_indexed": context["rollback_released_indexed"],
		"lethal_result": context["lethal_result"],
	}
	runtime.queue_free()
	await process_frame
	return run_result


func _spawn_player(
	runtime: EnemyGameplayGatewayTestRuntime,
	peer_id: int,
	node_name: String
) -> Player:
	var player := PLAYER_SCENE.instantiate() as Player
	_expect(player != null, "%s must instantiate." % node_name)
	if player == null:
		return null
	player.name = node_name
	runtime.add_child(player)
	await process_frame
	player.peer_id = peer_id
	player.bind_combat_runtime(runtime)
	# Preserve the character's initialized base maximum. Player damage refreshes
	# collectible stats after settlement; inventing a larger test-only max (for
	# example 200 over Weishidaier's authored 50) makes that refresh clamp health
	# and obscures the actual 11-point DamageResult.
	player.current_health = maxi(player.max_health, 1)
	player.physical_defense = 0
	player.magic_defense = 0
	player.is_dead = false
	player.invincibility_time_left = 0.0
	player.dash_time_left = 0.0
	player.multiplayer_dash_protection_time_left = 0.0
	player.dodge_chance = 0.0
	player.collectible_ranged_dodge_chance = 0.0
	player.damage_reduction_modifiers.clear()
	player.health_bar.set_health(player.current_health, player.max_health)
	player.set_process(false)
	player.set_physics_process(false)
	return player


func _apply_pre_tick_script(tick_index: int, context: Dictionary) -> void:
	var coordinator: EnemySimulationCoordinator = context["coordinator"]
	var source: Variant = context["source"]
	var player_a: Player = context["player_a"]
	var player_b: Player = context["player_b"]

	if tick_index == 4:
		source.forced_move_direction = Vector2.LEFT
		source.set_objective_target(player_b)
	elif tick_index == 6:
		player_b.global_position = source.global_position
		# Prevent Area's entry callback from settling ahead of the event phase.
		# Both Area and indexed contact then cross zero and settle on this tick.
		source.touch_damage_cooldown_left = PHYSICS_DELTA
	elif tick_index == 8:
		player_b.invincibility_time_left = 0.0
		source.touch_damage_cooldown_left = PHYSICS_DELTA
		_expect(
			source.set_combat_faction_id(
				CombatRelationService.PLAYER_ALLIED,
				1,
				true
			),
			"The scripted hostile-to-allied faction transition must apply."
		)
	elif tick_index == 10:
		player_b.global_position = source.global_position
		player_b.invincibility_time_left = 0.0
		source.touch_damage_cooldown_left = PHYSICS_DELTA
		_expect(
			source.set_combat_faction_id(
				CombatRelationService.HOSTILE_WAVE,
				2,
				true
			),
			"The scripted allied-to-hostile faction transition must apply."
		)
	elif tick_index == 11:
		player_b.global_position = -FAR_TARGET_POSITION
	elif tick_index == 12:
		source.forced_move_direction = Vector2.RIGHT
		source.set_objective_target(player_a)
	elif tick_index == 14:
		coordinator.set_mode(POLICY.Mode.LEGACY)
		context["rollback_restored"] = source.is_physics_processing()
		context["rollback_released_indexed"] = (
			not source.is_indexed_touch_authority_enabled()
		)
		# Subsequent ticks stay manually clocked; the value above observes the
		# production rollback handoff before the test disables the callback again.
		source.set_physics_process(false)
		coordinator.set_physics_process(false)


func _set_scripted_player_contact(
	source: Variant,
	player: Player,
	active: bool
) -> bool:
	if source.is_indexed_touch_authority_enabled():
		var players: Array[Player] = []
		if active:
			players.append(player)
		return (
			source.synchronize_indexed_touch_contacts(players, [])
			and source.touching_players.has(player.get_instance_id()) == active
		)
	if active:
		source.call(&"_on_touch_damage_area_body_entered", player)
	else:
		source.call(&"_on_touch_damage_area_body_exited", player)
	return source.touching_players.has(player.get_instance_id()) == active


func _advance_one_tick(
	coordinator: EnemySimulationCoordinator,
	source: Variant,
	player_a: Player,
	player_b: Player,
	scripted_contact_state: int = 0
) -> void:
	await physics_frame
	_disable_automatic_callbacks(coordinator, source, player_a, player_b)
	if source == null or not is_instance_valid(source) or source.is_dead:
		return
	# Inject after PhysicsServer/Area signal reconciliation and immediately before
	# the authoritative event phase. This makes the contact edge identical for
	# Area authority and the coordinator-owned indexed snapshot.
	if scripted_contact_state != 0:
		_expect(
			_set_scripted_player_contact(
				source,
				player_b,
				scripted_contact_state > 0
			),
			"The scripted contact snapshot must be committed before the event phase."
		)
	if source.is_centrally_simulated():
		coordinator.call(&"_physics_process", PHYSICS_DELTA)
		coordinator.set_physics_process(false)
	else:
		source.call(&"_physics_process", PHYSICS_DELTA)
		source.set_physics_process(false)


func _disable_automatic_callbacks(
	coordinator: EnemySimulationCoordinator,
	source: Variant,
	player_a: Player,
	player_b: Player
) -> void:
	coordinator.set_physics_process(false)
	if source != null and is_instance_valid(source):
		source.set_process(false)
		source.set_physics_process(false)
	for player in [player_a, player_b]:
		if player == null or not is_instance_valid(player):
			continue
		player.set_process(false)
		player.set_physics_process(false)


func _apply_lethal_damage(source: Variant) -> bool:
	if source == null or not is_instance_valid(source) or source.is_dead:
		return false
	var request := DamageRequest.new(
		source.current_health + 100,
		CombatTypes.DamageType.PHYSICAL
	)
	request.with_source_snapshot(DamageSourceSnapshot.create(
		CombatRelationService.PLAYER_ALLIED,
		1,
		91_001,
		91_002,
		&"shield_semantic_lethal"
	))
	request.with_flag(CombatTypes.DamageFlag.SUPPRESS_HIT_PARTICLES)
	request.with_flag(CombatTypes.DamageFlag.SUPPRESS_HIT_FLASH)
	var result: DamageResult = source.apply_combat_damage(request) as DamageResult
	return result.accepted and result.lethal and source.is_dead


func _capture_snapshot(
	tick_index: int,
	source: Variant,
	player_a: Player,
	player_b: Player
) -> Dictionary:
	return {
		"tick": tick_index,
		"position_x": _quantize(source.global_position.x),
		"position_y": _quantize(source.global_position.y),
		"velocity_x": _quantize(source.velocity.x),
		"velocity_y": _quantize(source.velocity.y),
		"touch_cooldown": _quantize(source.touch_damage_cooldown_left),
		"touching_players": source.touching_players.size(),
		"player_a_health": player_a.current_health,
		"player_b_health": player_b.current_health,
		"player_b_max_health": player_b.max_health,
		"objective": _objective_label(source.objective_target, player_a, player_b),
		"faction": source.get_combat_faction_id(),
		"faction_revision": source.get_faction_revision(),
		"dead": 1 if source.is_dead else 0,
		"central_owned": 1 if source.is_centrally_simulated() else 0,
		"indexed_touch": (
			1 if source.is_indexed_touch_authority_enabled() else 0
		),
		"movement_submissions": source.movement_submission_count,
		"shield_durability": source.get_shield_remaining_durability(),
		"behavior_rng": source.random_generator.state,
		"drop_rng": source.material_drop_random_generator.state,
		"expected_touch_damage": source.get_effective_attack_damage(
			source.config.attack_damage
		),
		"runtime_mode": source.combat_runtime.runtime_mode,
		"explicit_singleplayer": (
			1 if bool(source.call(&"_has_explicit_singleplayer_authority")) else 0
		),
		"touched_player_peer": (
			source.touched_player.peer_id
			if source.touched_player != null
			and is_instance_valid(source.touched_player)
			else 0
		),
		"can_attack_player_b": (
			1 if source.can_attack_combat_target(player_b) else 0
		),
		"touch_update_count": source.touch_update_count,
		"touch_apply_count": source.touch_apply_count,
		"last_touch_update_delta": _quantize(source.last_touch_update_delta),
		"last_touch_cooldown_before": _quantize(
			source.last_touch_cooldown_before
		),
		"last_touch_cooldown_after": _quantize(
			source.last_touch_cooldown_after
		),
		"last_touch_selected_peer_before": (
			source.last_touch_selected_peer_before
		),
		"last_touch_selected_peer_after": source.last_touch_selected_peer_after,
		"player_b_dead": 1 if player_b.is_dead else 0,
		"player_b_invincibility": _quantize(player_b.invincibility_time_left),
		"player_b_dash_time": _quantize(player_b.dash_time_left),
		"player_b_dash_protection": _quantize(
			player_b.multiplayer_dash_protection_time_left
		),
		"player_b_dodge": _quantize(player_b.get_effective_dodge_chance()),
		"player_b_last_damage_accepted": (
			1
			if player_b.last_damage_result != null
			and player_b.last_damage_result.accepted
			else 0
		),
		"player_b_last_damage_rejection": (
			player_b.last_damage_result.rejection_reason
			if player_b.last_damage_result != null
			else -1
		),
		"player_b_last_damage_applied": (
			player_b.last_damage_result.applied_damage
			if player_b.last_damage_result != null
			else 0
		),
		"player_b_last_source_faction": _last_damage_source_faction(player_b),
	}


func _objective_label(
	objective: Node2D,
	player_a: Player,
	player_b: Player
) -> String:
	if objective == player_a:
		return "player:1"
	if objective == player_b:
		return "player:2"
	return "none"


func _last_damage_source_faction(player: Player) -> int:
	if (
		player == null
		or player.last_damage_result == null
		or player.last_damage_result.request == null
		or player.last_damage_result.request.source_snapshot == null
	):
		return -1
	return player.last_damage_result.request.source_snapshot.source_faction_id


func _validate_mode_invariants(
	mode_name: String,
	snapshots: Array[Dictionary],
	context: Dictionary
) -> void:
	if snapshots.size() != TEST_TICKS + 1:
		failures.append("%s must capture every scripted tick." % mode_name)
		return
	_expect(
		snapshots[3]["objective"] == "player:1"
		and snapshots[4]["objective"] == "player:2"
		and snapshots[12]["objective"] == "player:1",
		"%s must preserve both scripted objective switches." % mode_name
	)
	_expect(
		int(snapshots[6]["player_b_health"])
		== int(snapshots[5]["player_b_health"])
		- int(snapshots[6]["expected_touch_damage"]),
		"%s must settle exactly one hostile touch on tick 6." % mode_name
	)
	_expect(
		int(snapshots[6]["touch_cooldown"])
		> int(snapshots[7]["touch_cooldown"])
		and int(snapshots[7]["touch_cooldown"]) > 0,
		"%s must decrement touch cooldown exactly once per following tick."
		% mode_name
	)
	_expect(
		int(snapshots[9]["player_b_health"])
		== int(snapshots[7]["player_b_health"]),
		"%s allied ticks 8-9 must reject friendly touch damage." % mode_name
	)
	_expect(
		int(snapshots[10]["player_b_health"])
		== int(snapshots[9]["player_b_health"])
		- int(snapshots[10]["expected_touch_damage"]),
		"%s must resume with exactly one hostile touch on tick 10."
		% mode_name
	)
	_expect(
		int(snapshots[6]["runtime_mode"])
		== CombatRuntimeBase.RuntimeMode.SINGLEPLAYER
		and int(snapshots[6]["explicit_singleplayer"]) == 1,
		"%s damage fixture must retain explicit SINGLEPLAYER authority."
		% mode_name
	)
	_expect(
		int(snapshots[6]["touched_player_peer"]) == 2
		and int(snapshots[6]["can_attack_player_b"]) == 1,
		"%s tick 6 must select the hostile scripted player contact."
		% mode_name
	)
	_expect(
		int(snapshots[6]["last_touch_cooldown_after"])
		== _quantize(0.5),
		"%s tick 6 touch event must consume the authored 0.5s cooldown."
		% mode_name
	)
	_expect(
		int(snapshots[6]["player_b_last_damage_accepted"]) == 1
		and int(snapshots[6]["player_b_last_damage_applied"])
		== int(snapshots[6]["expected_touch_damage"])
		and int(snapshots[6]["player_b_last_source_faction"])
		== CombatRelationService.HOSTILE_WAVE,
		"%s tick 6 must pass Player damage admission with hostile attribution."
		% mode_name
	)
	_expect(
		int(snapshots[8]["faction"]) == CombatRelationService.PLAYER_ALLIED
		and int(snapshots[10]["faction"]) == CombatRelationService.HOSTILE_WAVE,
		"%s must expose the scripted faction revisions in the tick trace."
		% mode_name
	)
	_expect(
		bool(context["rollback_restored"]),
		"%s rollback must restore ShieldBearer's individual physics callback."
		% mode_name
	)
	_expect(
		int(snapshots[13]["central_owned"]) == 1
		and int(snapshots[14]["central_owned"]) == 0,
		"%s must transfer from coordinator ownership to LEGACY at rollback."
		% mode_name
	)
	if mode_name == POLICY.mode_to_name(POLICY.Mode.LAYERED_CONTACT):
		_expect(
			int(snapshots[13]["indexed_touch"]) == 1
			and int(snapshots[14]["indexed_touch"]) == 0,
			"LAYERED_CONTACT rollback must atomically release indexed touch."
		)
	_expect(
		bool(context["rollback_released_indexed"]),
		"%s rollback must release indexed-touch authority." % mode_name
	)
	_expect(
		bool(context["lethal_result"])
		and int(snapshots[TEST_TICKS]["dead"]) == 1,
		"%s must preserve the lethal edge after rollback." % mode_name
	)


func _compare_gameplay_traces(
	compat_run: Dictionary,
	layered_run: Dictionary,
	layered_mode_name: String
) -> void:
	var compat_snapshots: Array = compat_run.get("snapshots", [])
	var layered_snapshots: Array = layered_run.get("snapshots", [])
	if compat_snapshots.size() != layered_snapshots.size():
		failures.append(
			"%s trace length differs from COMPAT_60 (%d vs %d)."
			% [layered_mode_name, layered_snapshots.size(), compat_snapshots.size()]
		)
		return
	var mismatch_count := 0
	for tick_index in range(compat_snapshots.size()):
		var compat_snapshot: Dictionary = compat_snapshots[tick_index]
		var layered_snapshot: Dictionary = layered_snapshots[tick_index]
		for field_name in GAMEPLAY_FIELDS:
			if compat_snapshot.get(field_name) == layered_snapshot.get(field_name):
				continue
			failures.append(
				(
					"%s diverged from COMPAT_60 at tick %d field %s: "
					+ "compat=%s layered=%s"
				) % [
					layered_mode_name,
					tick_index,
					field_name,
					str(compat_snapshot.get(field_name)),
					str(layered_snapshot.get(field_name)),
				]
			)
			mismatch_count += 1
			if mismatch_count >= 8:
				return


func _canonical_trace_lines(snapshots: Array[Dictionary]) -> PackedStringArray:
	var lines := PackedStringArray()
	for snapshot in snapshots:
		lines.append(JSON.stringify(snapshot))
	return lines


func _checkpoint_diagnostics(runs: Dictionary) -> Dictionary:
	var result := {}
	for simulation_mode in TEST_MODES:
		var run: Dictionary = runs.get(simulation_mode, {})
		var snapshots: Array = run.get("snapshots", [])
		var checkpoints := {}
		for tick_index in [6, 8, 10]:
			checkpoints[str(tick_index)] = (
				snapshots[tick_index].duplicate(true)
				if snapshots.size() > tick_index
				else {}
			)
		result[POLICY.mode_to_name(simulation_mode)] = checkpoints
	return result


func _trace_digests(runs: Dictionary) -> Dictionary:
	var result := {}
	for simulation_mode in TEST_MODES:
		var run: Dictionary = runs.get(simulation_mode, {})
		var lines: PackedStringArray = run.get("trace_lines", PackedStringArray())
		result[POLICY.mode_to_name(simulation_mode)] = "\n".join(lines).sha256_text()
	return result


func _mode_names() -> PackedStringArray:
	var names := PackedStringArray()
	for simulation_mode in TEST_MODES:
		names.append(POLICY.mode_to_name(simulation_mode))
	return names


func _quantize(value: float) -> int:
	return roundi(value * 1_000_000.0)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
