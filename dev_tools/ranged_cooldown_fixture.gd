extends Node

const Clock := preload("res://scene/combat/simulation/enemy_simulation_step_clock.gd")
const FAMILIES := ["capoo_ak47", "capoo_rpg"]

class CountedAK47:
	extends CapooAK47
	var hold_queries := 0
	var windup_attempts := 0

	func _try_hold_ranged_attack_position(target: Node2D, attack_range: float, collision_mask_value: int = 1) -> bool:
		hold_queries += 1
		return super._try_hold_ranged_attack_position(target, attack_range, collision_mask_value)

	func _try_start_windup(candidate_target: Node2D = null) -> bool:
		windup_attempts += 1
		return super._try_start_windup(candidate_target)

var result: Dictionary = {}
var failures: Array[String] = []
var assertions := 0
var runtime: TowerDefenseGame
var metrics := {}


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	(get_node("/root/RunState") as RunStateStore).begin_new_run(&"weishidaier", false)
	runtime = load("res://scene/game_modes/tower_defense/tower_defense_game.tscn").instantiate()
	runtime.auto_start_waves = false
	runtime.day_phase_announcements_enabled = false
	runtime.defer_runtime_activation()
	get_tree().root.add_child(runtime)
	get_tree().current_scene = runtime
	var deadline := Time.get_ticks_msec() + 30000
	while not runtime.is_runtime_preparation_complete() and Time.get_ticks_msec() < deadline:
		if runtime.is_runtime_preparation_failed():
			break
		await get_tree().process_frame
	_check(runtime.is_runtime_preparation_complete(), "Actual tower runtime finishes preparation")
	if runtime.is_runtime_preparation_complete():
		runtime.activate_runtime()
		runtime.process_mode = Node.PROCESS_MODE_DISABLED
		runtime.player.max_health = 10000000
		runtime.player.current_health = 10000000
		runtime.player.disable_mode = CollisionObject2D.DISABLE_MODE_KEEP_ACTIVE
		var coordinator := runtime.get_enemy_simulation_coordinator()
		coordinator.set_mode(EnemySimulationPolicy.Mode.LAYERED_CONTACT)
		var old_hz := Engine.physics_ticks_per_second
		Engine.physics_ticks_per_second = 240
		for family in FAMILIES:
			for hz in [30, 60, 120]:
				await _trace_original_and_sleep(family, hz)
			await _check_lifecycle(family, coordinator)
			_check_sleep_contact_boundaries(family)
			var reference := await _trace_full_scheduler(family, false, coordinator)
			var revised := await _trace_full_scheduler(family, true, coordinator)
			_check(reference["trace"] == revised["trace"], family + " full production coordinator state trace matches with sparse events")
			_check(int(revised["events"]) < int(reference["events"]), family + " production sparse queue actually omits events")
			metrics[family + "_full_scheduler"] = {"ticks": 480, "reference_events": reference["events"], "sleep_events": revised["events"], "same_trace": reference["trace"] == revised["trace"]}
		_check_other_family_scope()
		await _check_ak_hold_boundaries()
		Engine.physics_ticks_per_second = old_hz
		runtime.prepare_for_scene_teardown()
	runtime.queue_free()
	runtime = null
	for frame in 4:
		await get_tree().process_frame
	metrics["assertions"] = assertions
	metrics["failures"] = failures
	print("RANGED_COOLDOWN_REGRESSION ", JSON.stringify(metrics))
	var file := FileAccess.open("res://dev_tools/output/ranged_cooldown_regression.json", FileAccess.WRITE)
	file.store_string(JSON.stringify(metrics, "\t"))
	file.close()
	result["exit_code"] = 0 if failures.is_empty() else 1
	queue_free()


func _spawn(family: String) -> LayeredRangedEnemy:
	var config := load("res://resources/config/enemies/" + family + ".tres").duplicate() as EnemyConfig
	config.attack_damage = 0
	config.set("attack_range", 200.0)
	var enemy := config.enemy_scene.instantiate() as LayeredRangedEnemy
	enemy.disable_mode = CollisionObject2D.DISABLE_MODE_KEEP_ACTIVE
	enemy.config = config
	runtime.enemy_container.add_child(enemy)
	enemy.setup(config, runtime.player, null, runtime)
	enemy.position = Vector2(2000, 2000)
	enemy.collision_layer = 0
	enemy.collision_mask = 0
	enemy.navigation_update_frame_offset = 0
	return enemy


func _trace_original_and_sleep(family: String, hz: int) -> void:
	var original := _spawn(family)
	var revised := _spawn(family)
	for enemy in [original, revised]:
		enemy._release_authoritative_simulation_driver(Enemy.AuthoritativeSimulationDriver.INDIVIDUAL)
		enemy.set_physics_process(false)
		enemy.set("attack_cooldown_left", 0.4)
		enemy.set_objective_target(runtime.player)
		enemy.set("chase_cooldown_event_sleep_enabled", enemy == revised)
	var clock := Clock.new()
	revised.get("_attack_cooldown").bind_clock(clock)
	var events := 0
	var original_events := 0
	var attacks := 0
	var final_shot_frames := 0
	var previous_actions := 0
	var last_event_tick := 0
	var mismatches := 0
	var rows := []
	for tick in 480:
		await get_tree().physics_frame
		var delta := 1.0 / float(hz)
		if tick >= 60 and tick < 120:
			delta *= 0.5
		elif tick >= 320:
			delta *= 2.0
		if tick >= 150 and tick < 154:
			delta = 0.0
		clock.advance(delta)
		runtime.player.is_dead = tick >= 200 and tick < 211
		runtime.player.global_position = Vector2(2080 if tick < 280 else 1920, 2000)
		# Both objects sample the exact same Engine physics frame, target and LOS.
		for enemy in [original, revised]:
			enemy.refresh_dynamic_combat_target_decision(Engine.get_physics_frames())
		var old_scalar := float(original.get("attack_cooldown_left"))
		_advance_original_event(original, delta)
		original_events += 1
		# Before decision commits a new attack, the old scalar event must perform
		# precisely the literal one-step float subtraction, independently of helper.
		if int(original.get("combat_state")) != 2 or family == "capoo_rpg":
			_check(float(original.get("attack_cooldown_left")) == maxf(old_scalar - delta, 0.0), family + " original scalar event quantum")
		if tick == 0 or not revised.can_sleep_layered_area_event_phase():
			revised._simulate_layered_area_event_body(delta * float(tick - last_event_tick if tick > 0 else 1), delta, tick - last_event_tick if tick > 0 else 1)
			last_event_tick = tick
			events += 1
		_advance_original_decision(original, delta)
		revised._simulate_layered_area_decision_body(delta)
		for enemy in [original, revised]:
			if enemy.layered_area_motion_phase_due:
				enemy._simulate_layered_area_motion_body(delta)
		var expected := _state(original)
		var actual := _state(revised)
		if expected != actual:
			mismatches += 1
			if rows.size() < 6:
				rows.append({"tick": tick, "expected": expected, "actual": actual})
		_check(expected == actual, family + " original/sleep exact state at %d Hz tick %d" % [hz, tick])
		var actions := int(revised.action_sequence)
		if actions != previous_actions:
			attacks += 1
			previous_actions = actions
		var consumed := bool(revised.get("layered_ak47_event_consumes_tick" if family == "capoo_ak47" else "layered_rpg_event_consumes_tick"))
		if consumed and int(revised.get("combat_state")) == 0:
			final_shot_frames += 1
			_check(not revised.layered_area_motion_phase_due and not revised.can_sleep_layered_area_event_phase(), family + " final event consumes motion and cannot sleep before flag reset")
	_check(attacks > 0 and final_shot_frames > 0, family + " trace reaches attacks and final-event movement fences")
	_check(events < original_events, family + " positive CHASE cooldown removes real event visits")
	metrics[family + "_%d_hz" % hz] = {"ticks": 480, "original_events": original_events, "sleep_events": events, "attacks": attacks, "final_event_frames": final_shot_frames, "mismatches": mismatches, "first_mismatches": rows}
	original.free()
	revised.free()
	runtime.player.is_dead = false


# These are the literal pre-change ranged event state machines and scalar
# cooldown operation. No new cooldown advance or new family event method is
# called by the reference branch. Only unchanged authored attacks/motion remain.
func _advance_original_event(enemy: LayeredRangedEnemy, delta: float) -> void:
	enemy._update_touch_damage(delta)
	var cooldown := float(enemy.get("attack_cooldown_left"))
	if cooldown > 0.0:
		enemy.set("attack_cooldown_left", maxf(cooldown - delta, 0.0))
	if enemy is CapooAK47:
		var ak := enemy as CapooAK47
		ak.layered_ak47_event_consumes_tick = false
		if ak.combat_state != CapooAK47.CombatState.CHASE and (not is_instance_valid(ak.attack_target) or not ak._is_ranged_combat_target_valid(ak.attack_target)):
			ak._cancel_attack()
		match ak.combat_state:
			CapooAK47.CombatState.WINDUP:
				ak.layered_ak47_event_consumes_tick = true
				ak._update_windup(delta)
				if ak.combat_state == CapooAK47.CombatState.BURST:
					ak.request_layered_area_urgent_decision()
			CapooAK47.CombatState.BURST:
				ak.layered_ak47_event_consumes_tick = true
				ak._update_burst(delta)
	else:
		var rpg := enemy as CapooRPG
		rpg.layered_rpg_event_consumes_tick = false
		rpg.layered_rpg_windup_ready_to_fire = false
		if rpg.combat_state != CapooRPG.CombatState.CHASE and (not is_instance_valid(rpg.committed_attack_target) or not rpg._is_ranged_combat_target_valid(rpg.committed_attack_target)):
			rpg._cancel_attack()
			rpg.request_layered_area_urgent_decision()
		match rpg.combat_state:
			CapooRPG.CombatState.WINDUP:
				rpg.layered_rpg_event_consumes_tick = true
				if rpg._advance_windup_state(delta):
					rpg.layered_rpg_windup_ready_to_fire = true
					rpg.request_layered_area_urgent_decision()
			CapooRPG.CombatState.FIRE:
				rpg.layered_rpg_event_consumes_tick = true
				rpg._update_fire(delta)
	var can_move := enemy._can_run_layered_area_motion()
	if not enemy.layered_area_motion_state_known or can_move != enemy.layered_area_last_can_move:
		enemy.request_layered_area_urgent_decision()
	enemy.layered_area_motion_state_known = true
	enemy.layered_area_last_can_move = can_move
	if not can_move:
		enemy.layered_area_planned_move_direction = Vector2.ZERO
		enemy.velocity = Vector2.ZERO
	enemy.layered_area_motion_phase_due = can_move and not enemy.layered_area_planned_move_direction.is_zero_approx()


func _state(enemy: LayeredRangedEnemy) -> Array:
	var common := [enemy.get("combat_state"), enemy.get("attack_cooldown_left"), enemy.get("windup_time_left"), enemy.position, enemy.velocity,
		enemy.layered_area_last_can_move, enemy.layered_area_motion_phase_due, enemy.action_sequence,
		enemy.get("muzzle_heat").visible, enemy.get("muzzle_heat").color, enemy.get("muzzle_heat").scale]
	if enemy is CapooAK47:
		var ak := enemy as CapooAK47
		common.append_array([ak.burst_shots_fired, ak.burst_fire_time_left, ak.burst_shot_direction, ak.layered_ak47_event_consumes_tick,
			ak.attack_target == runtime.player, ak.local_data_projectile_sequence])
	else:
		var rpg := enemy as CapooRPG
		common.append_array([rpg.fire_time_left, rpg.fire_direction, rpg.layered_rpg_event_consumes_tick,
			rpg.layered_rpg_windup_ready_to_fire, rpg.committed_attack_target == runtime.player])
	return common


# The old AK CHASE calls windup even while cooling, then rechecks its hold.
# Keep that literal sequence independent of the production early return.
func _original_ak_chase(ak: CapooAK47) -> bool:
	var config := ak.config as CapooAK47.CapooConfig
	if ak._is_combat_sense_refresh_due():
		var target := ak._get_preferred_ranged_combat_target()
		if config != null and ak._try_hold_ranged_attack_position(target, config.attack_range, 1):
			if ak._try_start_windup(target):
				return true
			if ak._try_hold_ranged_attack_position(target, config.attack_range, 1):
				ak._update_facing(ak.global_position.direction_to(target.global_position))
				return true
		else:
			ak._reset_ranged_attack_position_state()
	elif ak._ranged_attack_position_held:
		ak.velocity = Vector2.ZERO
		return true
	return false


func _advance_original_decision(enemy: LayeredRangedEnemy, delta: float) -> void:
	if not enemy is CapooAK47:
		enemy._simulate_layered_area_decision_body(delta)
		return
	var ak := enemy as CapooAK47
	var frame := Engine.get_physics_frames()
	var consumed := false
	if ak.layered_area_decision_urgent or ak.is_layered_area_decision_due_for_physics_frame(frame):
		ak.refresh_dynamic_combat_target_decision(frame)
		if ak.layered_ak47_event_consumes_tick:
			consumed = true
		else:
			var previous := ak.combat_state
			consumed = _original_ak_chase(ak)
			if previous == CapooAK47.CombatState.CHASE and ak.combat_state == CapooAK47.CombatState.WINDUP:
				ak.request_layered_area_urgent_decision()
	var can_move := not consumed and ak._can_run_layered_area_motion()
	ak.layered_area_motion_state_known = true
	ak.layered_area_last_can_move = can_move
	ak.layered_area_planned_move_direction = ak._get_navigation_move_direction(delta) if can_move else Vector2.ZERO
	ak._update_facing(ak.layered_area_planned_move_direction)
	ak.layered_area_motion_phase_due = can_move and not ak.layered_area_planned_move_direction.is_zero_approx()
	ak.layered_area_decision_urgent = false


func _check_ak_hold_boundaries() -> void:
	# Reuse the existing authored native wall fixture; remove its test script
	# before entering the tree so only this suite drives the physics geometry.
	var wall_rig := load("res://dev_tools/ranged_hold_fixture.tscn").instantiate() as Node
	wall_rig.set_script(null)
	add_child(wall_rig)
	var wall_shape := wall_rig.get_node("WorldWall/CollisionShape2D") as CollisionShape2D
	var counts := []
	for scenario in ["cooling", "ready", "blocked_commit", "out_of_range", "dead_target", "friendly_target"]:
		var traces := []
		for original in [true, false]:
			wall_shape.set_deferred("disabled", scenario != "blocked_commit")
			runtime.player.is_dead = scenario == "dead_target"
			runtime.player.global_position = Vector2(2600, 2000) if scenario == "out_of_range" else Vector2(2080, 2000)
			var config := load("res://resources/config/enemies/capoo_ak47.tres").duplicate() as CapooAK47.CapooConfig
			config.attack_range = 200.0
			var ak := config.enemy_scene.instantiate() as CapooAK47
			ak.set_script(CountedAK47)
			runtime.enemy_container.add_child(ak)
			ak.setup(config, runtime.player, null, runtime)
			ak.position = Vector2(2000, 2000)
			ak.attack_cooldown_left = 1.0 if scenario == "cooling" else 0.0
			if scenario == "friendly_target":
				ak.set_combat_faction_id(CombatRelationService.PLAYER_ALLIED, -1, true)
			await get_tree().physics_frame
			await get_tree().physics_frame
			while Engine.get_physics_frames() % 15 != 0:
				await get_tree().physics_frame
			ak.navigation_update_frame_offset = 0
			ak._seed_ranged_combat_line_cache(runtime.player, runtime.player.global_position, 1, ak._get_current_navigation_generation(), true, Engine.get_physics_frames())
			var consumed := _original_ak_chase(ak) if original else ak._try_consume_ak47_chase_decision()
			traces.append([consumed, ak.combat_state, ak.velocity, ak._ranged_attack_position_held, ak.attack_target == runtime.player, ak.windup_time_left, ak.action_sequence])
			var counted := ak as CountedAK47
			counts.append({"scenario": scenario, "original": original, "holds": counted.hold_queries, "windup_attempts": counted.windup_attempts})
			if scenario == "cooling":
				_check(consumed and ak.combat_state == 0 and counted.hold_queries == (2 if original else 1), "AK cooling retains its original hold with exactly one fewer query")
			elif scenario == "blocked_commit":
				_check(not consumed and ak.combat_state == 0 and not ak._ranged_attack_position_held and counted.hold_queries == 2,
					"A real native wall still revokes stale sampled LOS during attack commit")
			ak.free()
		_check(traces[0] == traces[1], "AK original/new same-call hold boundary: " + scenario)
	metrics["ak_hold_queries"] = counts
	runtime.player.is_dead = false
	wall_rig.free()


func _check_lifecycle(family: String, coordinator: EnemySimulationCoordinator) -> void:
	var enemy := _spawn(family)
	var timer = enemy.get("_attack_cooldown")
	var clock = coordinator.gameplay_step_clock
	enemy.set("attack_cooldown_left", 2.0)
	for tick in 5:
		clock.advance(0.1)
	_check(enemy.get("attack_cooldown_left") == 2.0, family + " initial registration fence excludes unrelated clock quanta")
	enemy.call("_update_attack_cooldown", 0.1)
	_check(enemy.get("attack_cooldown_left") == 1.9, family + " first admitted event subtracts one current quantum")
	_check(coordinator.suspend_enemy(enemy, enemy.enemy_simulation_token), family + " direct suspension accepted")
	var frozen: float = enemy.get("attack_cooldown_left")
	clock.advance(0.8)
	_check(enemy.get("attack_cooldown_left") == frozen, family + " suspended timer excludes another enemy's clock")
	_check(coordinator.resume_enemy(enemy, enemy.enemy_simulation_token), family + " direct resumption accepted")
	clock.advance(0.025)
	enemy.call("_update_attack_cooldown", 0.025)
	_check(enemy.get("attack_cooldown_left") == frozen - 0.025, family + " resumption consumes only its first real quantum")
	frozen = enemy.get("attack_cooldown_left")
	get_tree().paused = true
	var frame := Engine.get_physics_frames()
	await get_tree().create_timer(0.12, true).timeout
	_check(Engine.get_physics_frames() > frame and enemy.get("attack_cooldown_left") == frozen, family + " SceneTree pause freezes lazy clock despite native wall frames")
	get_tree().paused = false
	enemy._release_authoritative_simulation_driver(Enemy.AuthoritativeSimulationDriver.INDIVIDUAL)
	clock.advance(0.5)
	_check(enemy.get("attack_cooldown_left") == frozen, family + " retired owner detaches old clock")
	_check(enemy.try_attach_to_enemy_simulation_coordinator(coordinator), family + " live owner can register afresh")
	clock.advance(0.01)
	enemy.call("_update_attack_cooldown", 0.01)
	_check(enemy.get("attack_cooldown_left") == frozen - 0.01, family + " fresh registration preserves cooldown and activation boundary")
	coordinator.set_mode(EnemySimulationPolicy.Mode.LEGACY)
	frozen = enemy.get("attack_cooldown_left")
	clock.advance(0.5)
	enemy.call("_update_attack_cooldown", 0.02)
	_check(enemy.get("attack_cooldown_left") == frozen - 0.02, family + " LEGACY resumes scalar subtraction after release")
	coordinator.set_mode(EnemySimulationPolicy.Mode.LAYERED_CONTACT)
	_check(timer._clock == coordinator.gameplay_step_clock, family + " layered readmission restores logical clock binding")
	coordinator.clear(true)
	_check(timer._clock == null, family + " coordinator clear releases timer ownership")
	enemy.free()
	enemy = _spawn(family)
	timer = enemy.get("_attack_cooldown")
	enemy.set("attack_cooldown_left", 1.0)
	enemy.call("_die")
	_check(enemy.is_dead and timer._clock == null, family + " real authored death releases cooldown clock ownership")
	frozen = enemy.get("attack_cooldown_left")
	clock.advance(0.5)
	_check(enemy.get("attack_cooldown_left") == frozen, family + " retired dead body cannot consume later scene ticks")
	enemy.free()


func _check_sleep_contact_boundaries(family: String) -> void:
	var enemy := _spawn(family)
	enemy._release_authoritative_simulation_driver(Enemy.AuthoritativeSimulationDriver.INDIVIDUAL)
	enemy.set("attack_cooldown_left", 2.0)
	enemy.layered_area_motion_state_known = true
	enemy.layered_area_last_can_move = false
	enemy.set_objective_target(runtime.player)
	_check(enemy._can_enter_layered_area_event_sleep(), family + " empty stationary CHASE can sleep with a positive cooldown")
	enemy.touching_players[runtime.player.get_instance_id()] = runtime.player
	_check(not enemy._can_enter_layered_area_event_sleep(), family + " a nonempty contact dictionary always keeps maintenance active")
	enemy.touching_players.clear()
	enemy.touched_player = runtime.player
	enemy.touch_damage_cooldown_left = 1.0
	_check(not enemy._can_enter_layered_area_event_sleep(), family + " cached contact and touch cooldown cannot admit ranged CHASE sleep")
	enemy.touched_player = null
	var target_enemy := Enemy.new()
	enemy.objective_target = target_enemy
	_check(not enemy._can_enter_layered_area_event_sleep(), family + " dynamic enemy objective retains the existing no-sleep restriction")
	target_enemy.free()
	enemy.free()


func _trace_full_scheduler(family: String, sleep_enabled: bool, coordinator: EnemySimulationCoordinator) -> Dictionary:
	# Start each alternate run on the same authored combat-sense phase. Native
	# Engine frames advance normally; no frame counter or targeting cache is faked.
	while Engine.get_physics_frames() % 15 != 0:
		await get_tree().physics_frame
	var enemy := _spawn(family)
	enemy.set("chase_cooldown_event_sleep_enabled", sleep_enabled)
	enemy.set("attack_cooldown_left", 0.4)
	var registration := coordinator._get_owned_registration(enemy, enemy.enemy_simulation_token)
	_check(registration != null, family + " real scheduler owns its exact authored family")
	var trace := []
	var events := 0
	for tick in 480:
		await get_tree().physics_frame
		var delta := 1.0 / 60
		if tick >= 150 and tick < 210:
			delta = 1.0 / 120
		elif tick >= 350:
			delta = 1.0 / 30
		runtime.player.is_dead = false
		runtime.player.global_position = Vector2(2080 if tick < 300 else 1920, 2000)
		coordinator._physics_process(delta)
		if registration.event_admission_physics_frame == Engine.get_physics_frames():
			events += 1
		trace.append(_state(enemy))
	enemy.free()
	return {"trace": trace, "events": events}


func _check_other_family_scope() -> void:
	for family in ["capoo_mage", "capoo_sniper", "fire_sorcerer", "frost_sorcerer", "lightning_sorcerer"]:
		var config := load("res://resources/config/enemies/" + family + ".tres") as EnemyConfig
		var enemy := config.enemy_scene.instantiate() as LayeredRangedEnemy
		_check(not enemy._can_sleep_layered_area_stationary_empty_contact_event(), family + " retains its original stationary event gate")
		enemy.free()


func _check(condition: bool, message: String) -> void:
	assertions += 1
	if not condition:
		failures.append(message)
		if failures.size() <= 8:
			push_error(message)
