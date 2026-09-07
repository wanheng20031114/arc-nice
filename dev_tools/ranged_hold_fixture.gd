extends Node

var result: Dictionary = {}
var _failures: Array[String] = []
var _checks := 0
var _runtime: TowerDefenseGame


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
	for family in ["frost_sorcerer_elite", "lightning_sorcerer_elite"]:
		for scenario in ["cooling", "staggered", "ready", "blocked_commit", "out_of_range", "dead_target", "friendly_target"]:
			var traces: Array = []
			for use_original in [true, false]:
				$WorldWall/CollisionShape2D.set_deferred("disabled", scenario != "blocked_commit")
				_runtime.player.is_dead = scenario == "dead_target"
				_runtime.player.global_position = Vector2(2600, 2000) if scenario == "out_of_range" else Vector2(2080, 2000)
				var enemy := _create_enemy(family)
				enemy.attack_cooldown_left = 10.0 if scenario == "cooling" else 0.0
				enemy.initial_attack_stagger_left = 1.0 if scenario == "staggered" else 0.0
				if scenario == "friendly_target":
					enemy.set_combat_faction_id(CombatRelationService.PLAYER_ALLIED)
				await get_tree().physics_frame
				await get_tree().physics_frame
				# This is a previously sampled clear LOS made stale by a new native
				# wall. The actual commit must still raycast and revoke the hold.
				enemy._seed_ranged_combat_line_cache(_runtime.player, _runtime.player.global_position, 1, enemy._get_current_navigation_generation(), true, Engine.get_physics_frames())
				var consumed := _old_chase(enemy) if use_original else _new_chase(enemy)
				var trace := _snapshot(enemy, consumed)
				traces.append(trace)
				if scenario in ["cooling", "staggered"]:
					_check(consumed and enemy.combat_state == 0 and enemy._ranged_attack_position_held, family + " held without attacking: " + scenario)
				elif scenario == "ready":
					_check(consumed and enemy.combat_state != 0 and enemy.action_sequence > 0, family + " native attack committed")
				else:
					_check(not consumed and not enemy._ranged_attack_position_held and enemy.combat_state == 0, family + " invalid/blocked hold released: " + scenario)
				enemy.queue_free()
				await get_tree().process_frame
			_check(traces[0] == traces[1], family + " original and revised state agree: " + scenario)
	_runtime.prepare_for_scene_teardown()
	_runtime.queue_free()
	_runtime = null
	for frame in 4:
		await get_tree().process_frame
	print("RANGED_HOLD_REGRESSION ", JSON.stringify({"checks": _checks, "failures": _failures}))
	result["exit_code"] = 0 if _failures.is_empty() else 1
	queue_free()


func _create_enemy(family: String) -> Enemy:
	var config := load("res://resources/config/enemies/" + family + ".tres").duplicate() as EnemyConfig
	config.max_health = 10000000
	config.set("attack_range", 200.0)
	var enemy := config.enemy_scene.instantiate() as Enemy
	_runtime.enemy_container.add_child(enemy)
	enemy.global_position = Vector2(2000, 2000)
	enemy.setup(config, _runtime.player, null, _runtime)
	enemy.set_objective_target(_runtime.player)
	enemy.velocity = Vector2(3, 4)
	return enemy


func _new_chase(enemy: Enemy) -> bool:
	if enemy is FrostSorcerer:
		return (enemy as FrostSorcerer)._try_consume_frost_chase_decision()
	return (enemy as LightningSorcerer)._try_consume_lightning_chase_decision()


# Independent reference to the pre-change two-hold algorithm. All target,
# raycast and attack calls below still execute the actual production methods.
func _old_chase(enemy: Enemy) -> bool:
	var config := enemy.config
	var target := enemy.get_resolved_combat_target()
	if target == null:
		target = enemy.get_resolved_combat_target(enemy.call("_select_nearest_attack_target", enemy._get_family_proactive_ranged_combat_target(), config, enemy.get("initial_attack_stagger_left") <= 0.0 and enemy.get("attack_cooldown_left") <= 0.0))
	var can_spawn := not (enemy is FrostSorcerer) or config.get("ice_spike_scene") != null
	if target != null and can_spawn and enemy._try_hold_ranged_attack_position(target, float(config.get("attack_range")), 1):
		if float(enemy.get("initial_attack_stagger_left")) <= 0.0:
			var committed: bool = enemy.call("_try_start_summon" if enemy is FrostSorcerer else "_try_start_windup", target, config)
			if committed:
				return true
		if enemy._try_hold_ranged_attack_position(target, float(config.get("attack_range")), 1):
			enemy.velocity = Vector2.ZERO
			enemy.call("_update_facing", enemy.global_position.direction_to(target.global_position))
			return true
	else:
		enemy._reset_ranged_attack_position_state()
	return false


func _snapshot(enemy: Enemy, consumed: bool) -> Array:
	var is_frost := enemy is FrostSorcerer
	return [consumed, enemy.get("combat_state"), enemy.velocity, enemy._ranged_attack_position_held, enemy.get("summon_time_left" if is_frost else "windup_time_left"), enemy.get("summon_direction" if is_frost else "cast_direction"), enemy.get("summon_target" if is_frost else "cast_target") == _runtime.player, enemy.get("action_sequence"), enemy.get("attack_cooldown_left"), enemy.get("initial_attack_stagger_left")]
