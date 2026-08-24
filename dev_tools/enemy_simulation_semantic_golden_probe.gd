extends SceneTree

const RUNTIME_SCENE := preload(
	"res://dev_tools/fixtures/enemy_gameplay_gateway_test_runtime.tscn"
)
const PLAYER_SCENE := preload(
	"res://scene/player/weishidaier/player_weishidaier.tscn"
)
const AGAVE_SCENE := preload("res://scene/plant_defense/agave_cannon.tscn")
const AGAVE_CONFIG := preload(
	"res://resources/config/plant_defense/agave_cannon.tres"
)
const BASIC_CONFIG := preload(
	"res://resources/config/enemies/yuanshi_insect_basic.tres"
)
const KNIGHT_CONFIG := preload(
	"res://resources/config/enemies/capoo_knight.tres"
)
const WOOD_PICKUP := preload(
	"res://resources/config/materials/material_wood.tres"
)

const TEST_DELTA := 1.0 / 60.0
const TEST_TICKS := 150
const DEFAULT_SEED := 20_260_824
const ELIGIBLE_REWARD := 7
const VICTIM_HEALTH := 25

const PLAYER_ATTACKER_ID := 101
const PLANT_ATTACKER_ID := 102
const ENEMY_ATTACKER_ID := 103
const ENEMY_VICTIM_ID := 104
const KNIGHT_ATTACKER_ID := 105
const INELIGIBLE_VICTIM_ID := 106

var failures: Array[String] = []
var requested_mode := EnemySimulationPolicy.Mode.LEGACY
var actual_mode := EnemySimulationPolicy.Mode.LEGACY
var requested_seed := DEFAULT_SEED
var runtime: EnemyGameplayGatewayTestRuntime = null
var coordinator: EnemySimulationCoordinator = null
var player: Player = null
var plant: AgaveCannon = null
var knight_plant: AgaveCannon = null
var enemies: Array[Enemy] = []
var enemy_by_fixture_id: Dictionary[int, Enemy] = {}
var trace_lines := PackedStringArray()
var transition_events := PackedStringArray()
var previous_health: Dictionary[String, int] = {}
var previous_dead: Dictionary[int, bool] = {}
var death_snapshot_by_fixture_id: Dictionary[int, Dictionary] = {}
var damage_event_counts: Dictionary[String, int] = {
	"player": 0,
	"plant": 0,
	"knight_plant": 0,
	"enemy": 0,
}
var invariant_summary := {}
var final_knight_diagnostics := {}
var death_event_count := 0
var eligible_drop_rng_initial := 0
var ineligible_drop_rng_initial := 0
var knight_behavior_rng_initial := 0
var current_logical_tick := 0


func _init() -> void:
	_parse_arguments()
	call_deferred(&"_run")


func _parse_arguments() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--semantic-mode="):
			requested_mode = EnemySimulationPolicy.parse_mode_name(
				argument.get_slice("=", 1),
				EnemySimulationPolicy.Mode.LEGACY
			)
		elif argument.begins_with("--semantic-seed="):
			requested_seed = int(argument.get_slice("=", 1))


func _run() -> void:
	runtime = RUNTIME_SCENE.instantiate() as EnemyGameplayGatewayTestRuntime
	_expect(runtime != null, "The authored enemy gameplay runtime must instantiate.")
	if runtime == null:
		_finish()
		return
	runtime.runtime_mode = CombatRuntimeBase.RuntimeMode.SINGLEPLAYER
	root.add_child(runtime)
	current_scene = runtime
	await process_frame
	coordinator = runtime.get_enemy_simulation_coordinator()
	_expect(coordinator != null, "The authored runtime must expose its coordinator.")
	if coordinator == null:
		await _dispose_runtime()
		_finish()
		return
	coordinator.set_mode(requested_mode)
	actual_mode = coordinator.mode
	_expect(
		actual_mode == requested_mode,
		"The coordinator must enter the requested semantic-golden mode exactly."
	)
	_spawn_targets()
	_spawn_enemies()
	_register_plant_damageables()
	# The probe advances the real authoritative entry points itself. Disable only
	# gameplay callbacks, leaving the authored collision objects active so the
	# PhysicsServer can synchronize the exact knight slash query fixtures.
	_disable_automatic_gameplay_callbacks()
	await physics_frame
	await physics_frame

	_seed_observer_state()
	_configure_combat_script()
	_capture_tick(0)
	for simulation_tick in range(1, TEST_TICKS + 1):
		current_logical_tick = simulation_tick
		if simulation_tick == 80:
			_apply_ineligible_lethal_damage()
		await _step_authoritative_simulation()
		_capture_tick(simulation_tick)

	# Rewards and pickup creation are deliberately deferred production paths.
	await process_frame
	await process_frame
	_capture_tick(TEST_TICKS + 1)
	_validate_invariants()
	final_knight_diagnostics = _capture_knight_diagnostics()
	await _dispose_runtime()
	_finish()


func _spawn_targets() -> void:
	player = PLAYER_SCENE.instantiate() as Player
	_expect(player != null, "The real Player scene must instantiate.")
	if player != null:
		runtime.add_child(player)
		player.peer_id = 1
		player.invincibility_time_left = 0.0
		player.set_xirang_balance(0)
		player.global_position = Vector2(-600.0, -300.0)
		runtime.player = player
		runtime.peer_players[1] = player

	plant = _spawn_agave(Vector2(-600.0, 0.0), "SemanticPlant")
	knight_plant = _spawn_agave(Vector2(620.0, 0.0), "SemanticKnightPlant")


func _spawn_agave(spawn_position: Vector2, node_name: String) -> AgaveCannon:
	var result := AGAVE_SCENE.instantiate() as AgaveCannon
	_expect(result != null, "%s must instantiate." % node_name)
	if result == null:
		return null
	result.name = node_name
	runtime.add_child(result)
	result.setup(AGAVE_CONFIG, null, [Vector2i.ZERO])
	result.global_position = spawn_position
	result.attack_timer.stop()
	return result


func _register_plant_damageables() -> void:
	var combat_services := coordinator.get_combat_services()
	var spatial_index := (
		combat_services.get_enemy_damageable_spatial_index()
		if combat_services != null
		else null
	)
	_expect(
		spatial_index != null and spatial_index.is_bound(),
		"The real damageable spatial index must be bound."
	)
	if spatial_index == null or not spatial_index.is_bound():
		return
	for damageable in [plant, knight_plant]:
		_expect(
			damageable != null and spatial_index.register_damageable(damageable),
			"Every semantic plant must register in the production spatial index."
		)


func _disable_automatic_gameplay_callbacks() -> void:
	coordinator.set_physics_process(false)
	for enemy in enemies:
		if enemy != null and is_instance_valid(enemy):
			enemy.set_physics_process(false)
	if player != null:
		player.set_process(false)
		player.set_physics_process(false)
	for damageable in [plant, knight_plant]:
		if damageable == null:
			continue
		damageable.set_process(false)
		damageable.set_physics_process(false)
		damageable.attack_timer.stop()


func _spawn_enemies() -> void:
	var ordinary_config := BASIC_CONFIG.duplicate(true) as EnemyConfig
	var victim_config := BASIC_CONFIG.duplicate(true) as EnemyConfig
	var ineligible_config := BASIC_CONFIG.duplicate(true) as EnemyConfig
	var knight_config := KNIGHT_CONFIG.duplicate(true) as EnemyConfig
	var guaranteed_drop_table := _make_guaranteed_drop_table()
	for config in [ordinary_config, victim_config, ineligible_config, knight_config]:
		if config != null:
			config.drop_table = guaranteed_drop_table
			config.xirang_kill_reward = ELIGIBLE_REWARD
	if victim_config != null:
		victim_config.max_health = VICTIM_HEALTH
	if ineligible_config != null:
		ineligible_config.max_health = VICTIM_HEALTH

	_spawn_enemy(ordinary_config, PLAYER_ATTACKER_ID, Vector2(-600.0, -300.0))
	_spawn_enemy(ordinary_config, PLANT_ATTACKER_ID, Vector2(-600.0, 0.0))
	_spawn_enemy(ordinary_config, ENEMY_ATTACKER_ID, Vector2(-600.0, 300.0))
	_spawn_enemy(victim_config, ENEMY_VICTIM_ID, Vector2(-600.0, 300.0))
	_spawn_enemy(knight_config, KNIGHT_ATTACKER_ID, Vector2(600.0, 0.0))
	_spawn_enemy(ineligible_config, INELIGIBLE_VICTIM_ID, Vector2(600.0, 300.0))


func _make_guaranteed_drop_table() -> EnemyDropTable:
	var table := EnemyDropTable.new()
	var rule := EnemyDropRule.new()
	rule.pickup_config = WOOD_PICKUP
	rule.chance = 1.0
	table.rules.append(rule)
	return table


func _spawn_enemy(config: EnemyConfig, fixture_id: int, spawn_position: Vector2) -> void:
	_expect(config != null and config.enemy_scene != null, "Enemy config %d is invalid." % fixture_id)
	if config == null or config.enemy_scene == null:
		return
	var enemy := config.enemy_scene.instantiate() as Enemy
	_expect(enemy != null, "Enemy %d must instantiate." % fixture_id)
	if enemy == null:
		return
	enemy.name = "SemanticEnemy%d" % fixture_id
	runtime.enemy_container.add_child(enemy)
	enemy.set_meta(&"net_id", fixture_id)
	enemy.random_generator.seed = requested_seed + fixture_id * 2
	enemy.material_drop_random_generator.seed = requested_seed + fixture_id * 2 + 1
	enemy.global_position = spawn_position
	enemy.setup(config, null, null, runtime)
	enemy.global_position = spawn_position
	enemy.defeated.connect(_on_fixture_enemy_defeated.bind(fixture_id))
	enemy.tree_exiting.connect(
		_on_fixture_enemy_tree_exiting.bind(enemy, fixture_id)
	)
	_expect(
		runtime.register_network_enemy(fixture_id, enemy),
		"Enemy %d must register in the real combat target index." % fixture_id
	)
	enemies.append(enemy)
	enemy_by_fixture_id[fixture_id] = enemy


func _configure_combat_script() -> void:
	var player_attacker := _enemy(PLAYER_ATTACKER_ID)
	var plant_attacker := _enemy(PLANT_ATTACKER_ID)
	var enemy_attacker := _enemy(ENEMY_ATTACKER_ID)
	var enemy_victim := _enemy(ENEMY_VICTIM_ID)
	var knight := _enemy(KNIGHT_ATTACKER_ID) as CapooKnight
	var ineligible_victim := _enemy(INELIGIBLE_VICTIM_ID)
	if (
		player_attacker == null
		or plant_attacker == null
		or enemy_attacker == null
		or enemy_victim == null
		or knight == null
		or ineligible_victim == null
		or player == null
		or plant == null
		or knight_plant == null
	):
		failures.append("The combat script is missing one or more real fixtures.")
		return

	player_attacker.set_objective_target(player)
	player_attacker.call(&"_on_touch_damage_area_body_entered", player)
	plant_attacker.set_objective_target(plant)
	plant_attacker.call(&"_on_touch_damage_area_body_entered", plant)
	enemy_attacker.set_combat_faction_id(
		CombatRelationService.PLAYER_ALLIED,
		1,
		true
	)
	enemy_attacker.set_objective_target(enemy_victim)
	ineligible_victim.set_combat_faction_id(
		CombatRelationService.PLAYER_ALLIED,
		1,
		true
	)
	knight.set_objective_target(knight_plant)
	_expect(
		knight.call(&"_try_start_windup", knight_plant),
		"The real knight attack must enter its authored windup."
	)

	trace_lines.append("target|0|%d|player|1" % PLAYER_ATTACKER_ID)
	trace_lines.append("target|0|%d|plant|1" % PLANT_ATTACKER_ID)
	trace_lines.append(
		"target|0|%d|enemy|%d" % [ENEMY_ATTACKER_ID, ENEMY_VICTIM_ID]
	)
	trace_lines.append("target|0|%d|plant|2" % KNIGHT_ATTACKER_ID)
	eligible_drop_rng_initial = enemy_victim.material_drop_random_generator.state
	ineligible_drop_rng_initial = ineligible_victim.material_drop_random_generator.state
	knight_behavior_rng_initial = knight.random_generator.state


func _seed_observer_state() -> void:
	previous_health = {
		"player": player.current_health if player != null else -1,
		"plant": plant.current_health if plant != null else -1,
		"knight_plant": (
			knight_plant.current_health if knight_plant != null else -1
		),
		"enemy": (
			_enemy(ENEMY_VICTIM_ID).current_health
			if _enemy(ENEMY_VICTIM_ID) != null
			else -1
		),
	}
	for fixture_id in enemy_by_fixture_id:
		var enemy := _enemy(int(fixture_id))
		previous_dead[int(fixture_id)] = enemy != null and enemy.is_dead


func _apply_ineligible_lethal_damage() -> void:
	var target := _enemy(INELIGIBLE_VICTIM_ID)
	if target == null or target.is_dead:
		failures.append("The ineligible attribution target was unavailable.")
		return
	var request := DamageRequest.new(
		target.current_health + 100,
		CombatTypes.DamageType.PHYSICAL
	)
	request.with_source_snapshot(DamageSourceSnapshot.create(
		CombatRelationService.HOSTILE_WAVE,
		0,
		9001,
		9002,
		&"semantic_ineligible_hostile"
	))
	request.with_flag(CombatTypes.DamageFlag.SUPPRESS_HIT_PARTICLES)
	request.with_flag(CombatTypes.DamageFlag.SUPPRESS_HIT_FLASH)
	var result := target.apply_combat_damage(request)
	_expect(
		result.accepted and result.lethal,
		"The hostile-attributed lethal DamageRequest must settle the allied target."
	)


func _step_authoritative_simulation() -> void:
	# Engine physics-frame identity is part of navigation staggering, contact
	# synchronization and the coordinator's duplicate-dispatch fence. Advance one
	# real frame for every golden tick instead of invoking 150 callbacks inside a
	# single frame, which would test an impossible production schedule.
	await physics_frame
	for enemy in enemies:
		if (
			enemy == null
			or not is_instance_valid(enemy)
			or enemy.is_dead
			or enemy.is_centrally_simulated()
		):
			continue
		enemy.call(&"_physics_process", TEST_DELTA)
	if requested_mode != EnemySimulationPolicy.Mode.LEGACY:
		coordinator.call(&"_physics_process", TEST_DELTA)
		coordinator.set_physics_process(false)


func _on_fixture_enemy_defeated(enemy: Enemy, fixture_id: int) -> void:
	if enemy == null or death_snapshot_by_fixture_id.has(fixture_id):
		return
	death_event_count += 1
	transition_events.append(
		"death|%d|%d" % [current_logical_tick, fixture_id]
	)
	previous_dead[fixture_id] = true
	death_snapshot_by_fixture_id[fixture_id] = {
		"reward_eligible": (
			enemy.defeat_context != null
			and enemy.defeat_context.is_player_reward_eligible()
		),
		"source_type": _get_defeat_source_type(enemy),
		"drop_rng_state": enemy.material_drop_random_generator.state,
	}


func _on_fixture_enemy_tree_exiting(enemy: Enemy, fixture_id: int) -> void:
	if enemy == null or not enemy.is_dead:
		return
	var snapshot: Dictionary = death_snapshot_by_fixture_id.get(
		fixture_id,
		{}
	)
	snapshot["reward_eligible"] = (
		enemy.defeat_context != null
		and enemy.defeat_context.is_player_reward_eligible()
	)
	snapshot["source_type"] = _get_defeat_source_type(enemy)
	snapshot["drop_rng_state"] = enemy.material_drop_random_generator.state
	death_snapshot_by_fixture_id[fixture_id] = snapshot
	enemy_by_fixture_id.erase(fixture_id)


func _capture_tick(simulation_tick: int) -> void:
	_capture_health_transition(simulation_tick, "player", player.current_health if player != null else -1)
	_capture_health_transition(simulation_tick, "plant", plant.current_health if plant != null else -1)
	_capture_health_transition(
		simulation_tick,
		"knight_plant",
		knight_plant.current_health if knight_plant != null else -1
	)
	var victim := _enemy(ENEMY_VICTIM_ID)
	_capture_health_transition(
		simulation_tick,
		"enemy",
		victim.current_health if victim != null else 0
	)
	for fixture_id in enemy_by_fixture_id.keys():
		var enemy := _enemy(int(fixture_id))
		if enemy == null or not is_instance_valid(enemy):
			continue
		var was_dead := bool(previous_dead.get(int(fixture_id), false))
		if enemy.is_dead and not was_dead:
			_on_fixture_enemy_defeated(enemy, int(fixture_id))
		previous_dead[int(fixture_id)] = enemy.is_dead

	var knight := _enemy(KNIGHT_ATTACKER_ID) as CapooKnight
	var player_attacker := _enemy(PLAYER_ATTACKER_ID)
	var plant_attacker := _enemy(PLANT_ATTACKER_ID)
	var enemy_attacker := _enemy(ENEMY_ATTACKER_ID)
	var ineligible := _enemy(INELIGIBLE_VICTIM_ID)
	var pickups := _get_pickup_signature()
	trace_lines.append(
		(
			"tick|%d|hp=%d,%d,%d,%d|dead=%d,%d|cool=%d,%d,%d|"
			+ "knight=%d,%d,%d,%d|rng=%d,%d,%d|reward=%d|pickups=%s"
		) % [
			simulation_tick,
			player.current_health if player != null else -1,
			plant.current_health if plant != null else -1,
			knight_plant.current_health if knight_plant != null else -1,
			victim.current_health if victim != null else 0,
			1 if victim != null and victim.is_dead else 0,
			1 if ineligible != null and ineligible.is_dead else 0,
			_quantize_seconds(player_attacker.touch_damage_cooldown_left if player_attacker != null else -1.0),
			_quantize_seconds(plant_attacker.touch_damage_cooldown_left if plant_attacker != null else -1.0),
			_quantize_seconds(enemy_attacker.touch_damage_cooldown_left if enemy_attacker != null else -1.0),
			knight.combat_state if knight != null else -1,
			_quantize_seconds(knight.attack_cooldown_left if knight != null else -1.0),
			_quantize_seconds(knight.windup_time_left if knight != null else -1.0),
			knight.action_sequence if knight != null else -1,
			knight.random_generator.state if knight != null else 0,
			_get_fixture_drop_rng_state(ENEMY_VICTIM_ID, victim),
			_get_fixture_drop_rng_state(INELIGIBLE_VICTIM_ID, ineligible),
			player.get_xirang() if player != null else -1,
			pickups,
		]
	)


func _capture_health_transition(simulation_tick: int, key: String, health: int) -> void:
	var previous := int(previous_health.get(key, health))
	if health < previous:
		damage_event_counts[key] = int(damage_event_counts.get(key, 0)) + 1
		transition_events.append(
			"damage|%d|%s|%d|%d" % [simulation_tick, key, previous - health, health]
		)
	previous_health[key] = health


func _get_pickup_signature() -> String:
	var paths := PackedStringArray()
	if runtime == null or runtime.enemy_container == null:
		return "-"
	for child in runtime.enemy_container.get_children():
		var pickup := child as Pickup
		if pickup == null or pickup.config == null:
			continue
		paths.append(pickup.config.resource_path)
	paths.sort()
	return ",".join(paths) if not paths.is_empty() else "-"


func _validate_invariants() -> void:
	var victim := _enemy(ENEMY_VICTIM_ID)
	var ineligible := _enemy(INELIGIBLE_VICTIM_ID)
	var victim_snapshot: Dictionary = death_snapshot_by_fixture_id.get(
		ENEMY_VICTIM_ID,
		{}
	)
	var ineligible_snapshot: Dictionary = death_snapshot_by_fixture_id.get(
		INELIGIBLE_VICTIM_ID,
		{}
	)
	var knight := _enemy(KNIGHT_ATTACKER_ID) as CapooKnight
	var pickup_signature := _get_pickup_signature()
	trace_lines.append(
		"attribution|eligible=%d,%s|ineligible=%d,%s"
		% [
			1 if (
				bool(victim_snapshot.get("reward_eligible", false))
			) else 0,
			String(victim_snapshot.get("source_type", "none")),
			1 if (
				bool(ineligible_snapshot.get("reward_eligible", false))
			) else 0,
			String(ineligible_snapshot.get("source_type", "none")),
		]
	)
	invariant_summary = {
		"player_damage_hits": int(damage_event_counts["player"]),
		"plant_damage_hits": int(damage_event_counts["plant"]),
		"knight_plant_damage_hits": int(damage_event_counts["knight_plant"]),
		"enemy_damage_hits": int(damage_event_counts["enemy"]),
		"death_events": death_event_count,
		"reward_total": player.get_xirang() if player != null else -1,
		"pickup_signature": pickup_signature,
		"eligible_drop_rng_advanced": (
			int(victim_snapshot.get("drop_rng_state", eligible_drop_rng_initial))
			!= eligible_drop_rng_initial
		),
		"ineligible_drop_rng_unchanged": (
			int(ineligible_snapshot.get("drop_rng_state", -1))
			== ineligible_drop_rng_initial
		),
		"behavior_rng_advanced": (
			knight != null and knight.random_generator.state != knight_behavior_rng_initial
		),
	}
	_expect(int(damage_event_counts["player"]) > 0, "Player must receive real enemy damage.")
	_expect(int(damage_event_counts["plant"]) > 0, "Plant must receive real touch damage.")
	_expect(
		int(damage_event_counts["knight_plant"]) > 0,
		"Plant must receive a real authored knight slash."
	)
	_expect(int(damage_event_counts["enemy"]) > 0, "Enemy must receive real dynamic-target damage.")
	_expect(
		death_snapshot_by_fixture_id.has(ENEMY_VICTIM_ID),
		"The dynamic Enemy target must die."
	)
	_expect(
		bool(victim_snapshot.get("reward_eligible", false)),
		"The allied-enemy lethal hit must retain player-eligible attribution."
	)
	_expect(
		death_snapshot_by_fixture_id.has(INELIGIBLE_VICTIM_ID)
		and not bool(ineligible_snapshot.get("reward_eligible", true)),
		"The hostile lethal hit must retain ineligible attribution."
	)
	_expect(
		player != null and player.get_xirang() == ELIGIBLE_REWARD,
		"Exactly one eligible death must grant the configured reward."
	)
	_expect(
		pickup_signature == WOOD_PICKUP.resource_path,
		"Exactly one eligible death must create the guaranteed real Pickup."
	)
	_expect(
		int(victim_snapshot.get("drop_rng_state", eligible_drop_rng_initial))
		!= eligible_drop_rng_initial,
		"Eligible death must consume its independent drop RNG stream."
	)
	_expect(
		int(ineligible_snapshot.get("drop_rng_state", -1))
		== ineligible_drop_rng_initial,
		"Ineligible death must not consume its drop RNG stream."
	)
	_expect(
		knight != null and knight.random_generator.state != knight_behavior_rng_initial,
		"The authored knight attack must consume behavior RNG."
	)
	_expect(death_event_count == 2, "Exactly two scripted deaths must be observed.")


func _get_defeat_source_type(enemy: Enemy) -> String:
	if (
		enemy == null
		or enemy.defeat_context == null
		or enemy.defeat_context.source_snapshot == null
	):
		return "none"
	return String(enemy.defeat_context.source_snapshot.source_type)


func _enemy(fixture_id: int) -> Enemy:
	var candidate: Variant = enemy_by_fixture_id.get(fixture_id)
	if candidate == null or not is_instance_valid(candidate):
		return null
	return candidate as Enemy


func _get_fixture_drop_rng_state(fixture_id: int, enemy: Enemy) -> int:
	if enemy != null and is_instance_valid(enemy):
		return enemy.material_drop_random_generator.state
	var snapshot: Dictionary = death_snapshot_by_fixture_id.get(fixture_id, {})
	return int(snapshot.get("drop_rng_state", 0))


func _quantize_seconds(value: float) -> int:
	return roundi(value * 1_000_000.0)


func _capture_knight_diagnostics() -> Dictionary:
	var knight := _enemy(KNIGHT_ATTACKER_ID) as CapooKnight
	return {
		"combat_state": knight.combat_state if knight != null else -1,
		"windup_usec": _quantize_seconds(
			knight.windup_time_left if knight != null else -1.0
		),
		"slash_usec": _quantize_seconds(
			knight.slash_time_left if knight != null else -1.0
		),
		"damage_delay_usec": _quantize_seconds(
			knight.slash_damage_time_left if knight != null else -1.0
		),
		"damage_done": knight.slash_damage_done if knight != null else false,
		"action_sequence": knight.action_sequence if knight != null else -1,
	}


func _dispose_runtime() -> void:
	if coordinator != null and is_instance_valid(coordinator):
		coordinator.clear(false)
	if runtime != null and is_instance_valid(runtime):
		runtime.clear_network_enemy_registry()
		current_scene = null
		runtime.queue_free()
	await process_frame
	await physics_frame
	# Release the probe's strong references after queued deletion and give the
	# rendering/physics servers one final frame to retire fixture-owned RIDs.
	enemies.clear()
	enemy_by_fixture_id.clear()
	player = null
	plant = null
	knight_plant = null
	coordinator = null
	runtime = null
	# A few deferred fixture effects (pickup/audio/physics resources) retire on
	# later idle-frame flushes even after their owner tree has been deleted.
	for flush_index in range(3):
		await process_frame


func _finish() -> void:
	var canonical_trace := "\n".join(trace_lines)
	var result := {
		"schema_version": 1,
		"status": "ok" if failures.is_empty() else "failed",
		"requested_mode": EnemySimulationPolicy.mode_to_name(
			requested_mode
		).to_lower(),
		"mode": EnemySimulationPolicy.mode_to_name(actual_mode).to_lower(),
		"seed": requested_seed,
		"tick_count": TEST_TICKS,
		"canonical_sha256": canonical_trace.sha256_text(),
		"canonical_line_count": trace_lines.size(),
		"event_counts": {
			"player_damage": int(damage_event_counts["player"]),
			"plant_damage": int(damage_event_counts["plant"]),
			"knight_plant_damage": int(damage_event_counts["knight_plant"]),
			"enemy_damage": int(damage_event_counts["enemy"]),
			"death": death_event_count,
		},
		"invariants": invariant_summary,
		"transition_events": transition_events,
		"final_knight": final_knight_diagnostics,
		"failures": failures.duplicate(),
	}
	print("ENEMY_SIMULATION_SEMANTIC_GOLDEN_JSON %s" % JSON.stringify(result))
	if failures.is_empty():
		print("ENEMY_SIMULATION_SEMANTIC_GOLDEN_PROBE_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
