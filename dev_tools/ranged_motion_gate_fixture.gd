extends Node

class TracedAK47:
	extends CapooAK47
	var reference_order := false
	var contact_queries := 0

	func _can_run_layered_area_motion() -> bool:
		if reference_order:
			return (not is_dead and is_instance_valid(objective_target)
				and not _has_player_contact()
				and _layered_ranged_attack_state_allows_motion())
		return super._can_run_layered_area_motion()

	func _has_player_contact() -> bool:
		contact_queries += 1
		return super._has_player_contact()

class CountedSleepEnemy:
	extends SimpleChaseLayeredEnemy
	var family_allows_sleep := true
	var cooldown_queries := 0

	func _get_navigation_move_direction(_delta: float) -> Vector2:
		return Vector2.ZERO

	func _update_facing(_direction: Vector2) -> void:
		pass

	func _can_sleep_layered_area_family_event_phase() -> bool:
		return family_allows_sleep

	func _has_sleepable_layered_touch_damage_cooldown() -> bool:
		cooldown_queries += 1
		return super._has_sleepable_layered_touch_damage_cooldown()

var result: Dictionary = {}
var _failures: Array[String] = []
var _checks := 0
var _runtime: TowerDefenseGame
var _traces: Dictionary = {}
const FAMILIES := ["capoo_ak47", "capoo_mage", "capoo_rpg", "capoo_sniper", "fire_sorcerer", "frost_sorcerer", "lightning_sorcerer"]
const CONSUMED_FLAGS := ["layered_ak47_event_consumes_tick", "layered_mage_event_consumes_tick", "layered_rpg_event_consumes_tick", "layered_sniper_event_consumes_tick", "layered_fire_event_consumes_tick", "layered_frost_event_consumes_tick", "layered_lightning_event_consumes_tick"]
const TARGET_FIELDS := ["attack_target", "attack_target", "committed_attack_target", "locked_target", "summon_target", "summon_target", "cast_target"]
const TIMER_FIELDS := ["windup_time_left", "windup_time_left", "windup_time_left", "lock_time_left", "summon_time_left", "summon_time_left", "windup_time_left"]
const DELTA := 1.0 / 60.0


func _ready() -> void:
	_run.call_deferred()


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures.append(message)


func _run() -> void:
	(get_tree().root.get_node("RunState") as RunStateStore).begin_new_run(&"weishidaier", false)
	_runtime = load("res://scene/game_modes/tower_defense/tower_defense_game.tscn").instantiate()
	_runtime.auto_start_waves = false
	_runtime.day_phase_announcements_enabled = false
	_runtime.defer_runtime_activation()
	get_tree().root.add_child(_runtime)
	get_tree().current_scene = _runtime
	while _runtime.get_runtime_preparation_snapshot().state == RuntimePreparationProvider.PreparationState.PREPARING:
		await get_tree().process_frame
	_check(_runtime.get_runtime_preparation_snapshot().state == RuntimePreparationProvider.PreparationState.READY, "Real TD prepared")
	_runtime.activate_runtime()
	_runtime.process_mode = Node.PROCESS_MODE_DISABLED
	_runtime.player.global_position = Vector2(2080, 2000)
	_runtime.player.current_health = 10000000
	_runtime.player.max_health = 10000000
	await _check_family_boundaries()
	await _check_authored_ak47_traces()
	await _check_committed_target_lifetimes()
	_check_sleep_predicate_order()
	_benchmark_locked_gate()
	_runtime.prepare_for_scene_teardown()
	_runtime.queue_free()
	_runtime = null
	for frame in 4:
		await get_tree().process_frame
	var summary := {"checks": _checks, "failures": _failures, "traces": _traces}
	print("RANGED_MOTION_GATE_REGRESSION ", JSON.stringify(summary))
	var file := FileAccess.open("res://dev_tools/output/ranged_motion_gate_regression.json", FileAccess.WRITE)
	file.store_string(JSON.stringify(summary, "\t"))
	file.close()
	result["exit_code"] = 0 if _failures.is_empty() else 1
	queue_free()


func _create_enemy(family: String, traced := false) -> LayeredRangedEnemy:
	var config := load("res://resources/config/enemies/" + family + ".tres").duplicate() as EnemyConfig
	config.max_health = 10000000
	var enemy := config.enemy_scene.instantiate() as LayeredRangedEnemy
	if traced:
		enemy.set_script(TracedAK47)
	enemy.disable_mode = CollisionObject2D.DISABLE_MODE_KEEP_ACTIVE
	_runtime.enemy_container.add_child(enemy)
	enemy.global_position = Vector2(2000, 2000)
	enemy.setup(config, _runtime.player, null, _runtime)
	enemy.navigation_update_frame_offset = 0
	enemy.set_objective_target(_runtime.player)
	return enemy


# Independent pre-change gate; all actual contact and family predicates remain
# production methods. No cached contact dictionary is compared as gameplay state.
func _reference_gate(enemy: LayeredRangedEnemy) -> bool:
	return (not enemy.is_dead and is_instance_valid(enemy.objective_target)
		and not enemy._has_player_contact()
		and enemy._layered_ranged_attack_state_allows_motion())


func _check_family_boundaries() -> void:
	var config := _runtime.plant_system.get_config(&"corn_machine_gun").duplicate() as PlantDefenseConfig
	var plant := _runtime.plant_system._instantiate_registered_plant(config, Vector2i(4, 4), _runtime.player, 5001, false, -1, 0, -1, false)
	plant.global_position = Vector2(2010, 2000)
	for family in FAMILIES:
		var enemy := _create_enemy(family)
		_check(enemy.get_layered_area_decision_interval_frames() == 1, family + " continues a full targeting decision every tick")
		for scenario in ["empty", "player", "dead_player", "plant", "dead_plant", "removing_plant", "friendly", "restored_hostility", "freed_player"]:
			enemy._clear_touching_players()
			_runtime.player.is_dead = scenario == "dead_player"
			plant.is_dead = scenario == "dead_plant"
			plant.is_removing = scenario == "removing_plant"
			enemy.set_combat_faction_id(CombatRelationService.HOSTILE_WAVE, -1, true)
			if scenario in ["player", "dead_player", "friendly", "restored_hostility"]:
				enemy.touching_players[_runtime.player.get_instance_id()] = _runtime.player
			if scenario in ["plant", "dead_plant", "removing_plant"]:
				enemy.touching_plants[plant.get_instance_id()] = plant
				enemy.touching_plant_entry_distances[plant.get_instance_id()] = 100.0
			if scenario in ["friendly", "restored_hostility"]:
				enemy.set_combat_faction_id(CombatRelationService.PLAYER_ALLIED, -1, true)
				if scenario == "restored_hostility":
					enemy.set_combat_faction_id(CombatRelationService.HOSTILE_WAVE, -1, true)
			if scenario == "freed_player":
				var temporary := Player.new()
				enemy.touching_players[temporary.get_instance_id()] = temporary
				temporary.free()
			enemy.set("combat_state", 1)
			_check(not enemy._can_run_layered_area_motion(), family + " locked state forbids motion: " + scenario)
			_check(not enemy._can_sleep_layered_ranged_event_phase(), family + " committed state stays in event lane")
			var selected := enemy.get_contact_combat_target()
			var expected: Node2D = null
			if scenario in ["player", "restored_hostility"]:
				expected = _runtime.player
			elif scenario == "plant":
				expected = plant
			_check(selected == expected, family + " real attack resolution validates current contact: " + scenario)
			_check(not _reference_gate(enemy), family + " prior gate also forbids motion: " + scenario)
			enemy.set("combat_state", 0)
			enemy._prepare_layered_ranged_authoritative_simulation()
			enemy._reset_ranged_attack_position_state()
			var revised := enemy._can_run_layered_area_motion()
			_check(revised == _reference_gate(enemy), family + " immediate CHASE gate parity: " + scenario)
			_check(revised == (expected == null), family + " CHASE resumes or stops on actual live contact: " + scenario)
			enemy.is_dead = true
			_check(not enemy._can_run_layered_area_motion(), family + " dead attacker never moves")
			enemy.is_dead = false
		enemy._clear_touching_players()
		enemy.set("combat_state", 0)
		enemy.set(CONSUMED_FLAGS[FAMILIES.find(family)], true)
		_check(not enemy._can_run_layered_area_motion(), family + " final event consumes CHASE motion until next tick")
		enemy._prepare_layered_ranged_authoritative_simulation()
		enemy._reset_ranged_attack_position_state()
		_check(enemy._can_run_layered_area_motion(), family + " clearing consumed flag allows next-tick CHASE query")
		enemy.queue_free()
		await get_tree().process_frame
	_runtime.player.is_dead = false
	plant.is_dead = false
	plant.is_removing = false
	plant.queue_free()
	await get_tree().process_frame


func _check_authored_ak47_traces() -> void:
	for scenario in ["windup", "last_shot", "dead_target", "friendly_target", "freed_contact", "removing_target", "freed_target"]:
		_runtime.player.is_dead = false
		_runtime.player.global_position = Vector2(2080, 2000)
		var committed_target: Node2D = _runtime.player
		if scenario == "removing_target":
			var plant_config := _runtime.plant_system.get_config(&"corn_machine_gun").duplicate() as PlantDefenseConfig
			var removed := _runtime.plant_system._instantiate_registered_plant(plant_config, Vector2i(5, 5), _runtime.player, 5002, false, -1, 0, -1, false)
			removed.global_position = Vector2(2080, 2000)
			removed.is_removing = true
			committed_target = removed
		elif scenario == "freed_target":
			committed_target = Player.new()
		var service := _runtime.get_enemy_combat_services().get_rapid_fire_simulation_service()
		var registered_before := service.get_active_slot_count()
		var enemies: Array[TracedAK47] = []
		var alternatives: Array = [[], [], []]
		for mode in ["legacy", "prior_layered", "revised_layered"]:
			var enemy := _create_enemy("capoo_ak47", true) as TracedAK47
			enemy.reference_order = mode == "prior_layered"
			var ak_config := enemy.config as CapooAK47.CapooConfig
			ak_config.attack_range = 200.0
			ak_config.burst_count = 1
			enemy.attack_cooldown_left = 10.0
			enemy.attack_target = committed_target
			enemy.combat_state = CapooAK47.CombatState.BURST if scenario == "last_shot" else CapooAK47.CombatState.WINDUP
			enemy.windup_time_left = 0.025
			enemy.committed_windup_duration_seconds = 0.025
			enemy.burst_shot_direction = Vector2.RIGHT
			if scenario == "friendly_target":
				enemy.set_combat_faction_id(CombatRelationService.PLAYER_ALLIED, -1, true)
			if scenario == "freed_contact":
				var obsolete := Player.new()
				enemy.touching_players[obsolete.get_instance_id()] = obsolete
				obsolete.free()
			enemies.append(enemy)
		if scenario == "freed_target":
			committed_target.free()
		_runtime.player.is_dead = scenario == "dead_target"
		# All references observe the same real physics frame and sense cadence.
		# KEEP_ACTIVE retains native bodies while automatic runtime processing is
		# disabled; no mock replaces authored movement or projectile registration.
		for tick in 4:
			await get_tree().physics_frame
			if tick == 1 and scenario == "last_shot":
				_runtime.player.global_position = Vector2(2400, 2000)
			for mode in 3:
				var enemy := enemies[mode]
				if mode == 0:
					enemy._run_authoritative_physics_step(DELTA)
				else:
					enemy._simulate_layered_area_event_body(DELTA, DELTA, 1)
					enemy._simulate_layered_area_decision_body(DELTA)
					enemy._simulate_layered_area_motion_body(DELTA)
				alternatives[mode].append([enemy.combat_state, enemy.velocity.length() > 0.001,
					enemy.local_data_projectile_sequence, enemy.burst_shots_fired,
					snappedf(enemy.attack_cooldown_left, 0.000001),
					snappedf(enemy.windup_time_left, 0.000001), enemy.attack_target == _runtime.player])
		_check(alternatives[1] == alternatives[2], scenario + " complete prior/revised layered attack and movement trace")
		_check(alternatives[0] == alternatives[2], scenario + " authored LEGACY attack and movement trace")
		if scenario == "last_shot":
			_check(service.get_active_slot_count() == registered_before + 3, "All three authored final shots register actual live data projectiles")
			_check(alternatives[2][0][2] == 1 and not alternatives[2][0][1] and alternatives[2][1][1], "Actual final projectile consumes current tick; motion resumes on the next tick")
		if scenario in ["dead_target", "friendly_target", "removing_target", "freed_target"]:
			_check(alternatives[2][0][0] == 0 and alternatives[2][3][2] == 0, scenario + " cancels before firing")
		_traces[scenario] = alternatives
		if scenario == "removing_target":
			committed_target.queue_free()
		for enemy in enemies:
			enemy.queue_free()
		await get_tree().process_frame
	_runtime.player.is_dead = false


func _benchmark_locked_gate() -> void:
	_runtime.player.global_position = Vector2(2080, 2000)
	var enemy := _create_enemy("capoo_ak47", true) as TracedAK47
	enemy.combat_state = CapooAK47.CombatState.WINDUP
	enemy.touching_players[_runtime.player.get_instance_id()] = _runtime.player
	var samples: Array = []
	for original in [true, false]:
		enemy.reference_order = original
		enemy.contact_queries = 0
		var started := Time.get_ticks_usec()
		for iteration in 60000:
			enemy._can_run_layered_area_motion()
		samples.append({"original": original, "usec": Time.get_ticks_usec() - started, "contact_queries": enemy.contact_queries})
	_check(samples[0].contact_queries == 60000 and samples[1].contact_queries == 0, "Locked motion queries eliminate contact scans exactly")
	_traces["gate_microbenchmark"] = samples
	enemy.queue_free()


# Previous evaluation order as a separate reference. Production predicates are
# pure reads; the fixture counts only how often the cooldown proof is requested.
func _reference_sleep(enemy: CountedSleepEnemy) -> bool:
	var stable := enemy._has_sleepable_layered_touch_damage_cooldown()
	return (not enemy.is_dead and enemy.objective_target != null
		and is_instance_valid(enemy.objective_target)
		and not (enemy.objective_target is Enemy)
		and enemy.layered_area_motion_state_known
		and enemy._can_sleep_layered_area_family_event_phase()
		and (stable or (enemy.indexed_touch_contact_snapshot_is_empty()
			and enemy.layered_area_last_can_move)))


func _check_sleep_predicate_order() -> void:
	var enemy := CountedSleepEnemy.new()
	var static_objective := Node2D.new()
	var dynamic_objective := Enemy.new()
	var contact := Player.new()
	var cases := 0
	for objective in [null, static_objective, dynamic_objective]:
		for dead in [false, true]:
			for known in [false, true]:
				for family_sleep in [false, true]:
					for cooldown_kind in ["inactive", "future", "expired", "paused"]:
						for contact_kind in ["empty", "live", "dead", "freed"]:
							for can_move in [false, true]:
								enemy.objective_target = objective
								enemy.is_dead = dead
								enemy.layered_area_motion_state_known = known
								enemy.layered_area_last_can_move = can_move
								enemy.family_allows_sleep = family_sleep
								enemy._touch_damage_pause_physics_frame = -1
								enemy.touch_damage_cooldown_deadline_physics_frame = -1
								if cooldown_kind == "future":
									enemy.touch_damage_cooldown_deadline_physics_frame = Engine.get_physics_frames() + 20
								elif cooldown_kind in ["expired", "paused"]:
									enemy.touch_damage_cooldown_deadline_physics_frame = Engine.get_physics_frames() - 1
									if cooldown_kind == "paused":
										enemy._touch_damage_pause_physics_frame = Engine.get_physics_frames() - 5
								contact.is_dead = contact_kind == "dead"
								enemy.touched_player = null if contact_kind == "empty" else contact
								if contact_kind == "freed":
									var vanished := Player.new()
									enemy.touched_player = vanished
									vanished.free()
								var deadline := enemy.touch_damage_cooldown_deadline_physics_frame
								var reference := _reference_sleep(enemy)
								enemy.cooldown_queries = 0
								var revised := enemy._can_enter_layered_area_event_sleep()
								_check(reference == revised, "Sleep predicate truth-table case " + str(cases))
								_check(enemy.touch_damage_cooldown_deadline_physics_frame == deadline, "Sleep proof never mutates its deadline")
								var expected_queries := int(not dead and objective == static_objective and known and family_sleep)
								_check(enemy.cooldown_queries == expected_queries, "Rejected sleep gates do not query contact cooldown")
								cases += 1
	_traces["sleep_truth_table_cases"] = cases
	enemy.is_dead = false
	enemy.objective_target = static_objective
	enemy.layered_area_motion_state_known = true
	enemy.family_allows_sleep = false
	enemy.touched_player = contact
	contact.is_dead = false
	enemy._touch_damage_pause_physics_frame = -1
	enemy.touch_damage_cooldown_deadline_physics_frame = Engine.get_physics_frames() + 20
	var samples: Array = []
	for original in [true, false]:
		enemy.cooldown_queries = 0
		var started := Time.get_ticks_usec()
		for iteration in 60000:
			if original:
				_reference_sleep(enemy)
			else:
				enemy._can_enter_layered_area_event_sleep()
		samples.append({"original": original, "usec": Time.get_ticks_usec() - started, "cooldown_queries": enemy.cooldown_queries})
	_check(samples[0].cooldown_queries == 60000 and samples[1].cooldown_queries == 0,
		"An awake family eliminates all unobservable sleep cooldown queries")
	_traces["sleep_gate_microbenchmark"] = samples
	enemy.touched_player = null
	enemy.objective_target = null
	enemy.free()
	contact.free()
	static_objective.free()
	dynamic_objective.free()


func _check_committed_target_lifetimes() -> void:
	for family_index in FAMILIES.size():
		var family: String = FAMILIES[family_index]
		for free_phase in ["before_event", "between_event_and_decision"]:
			var enemy := _create_enemy(family)
			var victim := _create_enemy("capoo_ak47")
			victim.global_position = Vector2(2080, 2000)
			victim.set_combat_faction_id(CombatRelationService.PLAYER_ALLIED, -1, true)
			enemy.set(TARGET_FIELDS[family_index], victim)
			enemy.set("combat_state", 1)
			enemy.set(TIMER_FIELDS[family_index], 0.0)
			enemy.set("attack_cooldown_left", 10.0)
			if free_phase == "before_event":
				victim.free()
			enemy._simulate_layered_area_event_body(DELTA, DELTA, 1)
			var cooldown_after_event: float = enemy.get("attack_cooldown_left")
			if free_phase == "between_event_and_decision":
				_check(enemy.get("combat_state") != 0, family + " actual event reached committed prefire edge")
				victim.free()
			enemy._simulate_layered_area_decision_body(DELTA)
			# AK47 transitions to BURST in event, then fires only on the next event.
			# Other families resolve their completed windup in this decision phase.
			enemy._simulate_layered_area_event_body(DELTA, DELTA, 1)
			_check(enemy.get("combat_state") == 0 and enemy.get(TARGET_FIELDS[family_index]) == null,
				family + " safely cancels a released committed target: " + free_phase)
			_check(is_equal_approx(float(enemy.get("attack_cooldown_left")), maxf(cooldown_after_event - DELTA, 0.0)),
				family + " target release does not start a replacement attack cooldown")
			enemy.queue_free()
			await get_tree().process_frame
		if family_index >= 4:
			var enemy := _create_enemy(family)
			var victim := _create_enemy("capoo_ak47")
			victim.set_combat_faction_id(CombatRelationService.PLAYER_ALLIED, -1, true)
			enemy.set("cached_runtime_attack_target", victim)
			victim.free()
			var selected: Variant = enemy.call("_select_nearest_attack_target", _runtime.player, enemy.config, false)
			_check(selected == _runtime.player and enemy.get("cached_runtime_attack_target") == null,
				family + " stale sense cache reuses the live fallback without typed-argument errors")
			enemy.queue_free()
			await get_tree().process_frame
