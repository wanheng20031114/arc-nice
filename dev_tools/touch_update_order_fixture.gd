extends "res://dev_tools/ranged_motion_gate_fixture.gd"

class CountedAK:
	extends CapooAK47
	var dynamic_queries := 0
	var touch_attempts := 0
	var wakes := 0
	func _has_dynamic_enemy_target_contact() -> bool:
		dynamic_queries += 1
		return super._has_dynamic_enemy_target_contact()
	func _try_deal_touch_damage() -> void:
		touch_attempts += 1
		super._try_deal_touch_damage()
	func request_layered_area_urgent_decision() -> void:
		wakes += 1
		super.request_layered_area_urgent_decision()

class CountedGunner:
	extends CombatRobotGunner
	var dynamic_queries := 0
	var touch_attempts := 0
	var wakes := 0
	func _has_dynamic_enemy_target_contact() -> bool:
		dynamic_queries += 1
		return super._has_dynamic_enemy_target_contact()
	func _try_deal_touch_damage() -> void:
		touch_attempts += 1
		super._try_deal_touch_damage()
	func request_layered_area_urgent_decision() -> void:
		wakes += 1
		super.request_layered_area_urgent_decision()


func _check_committed_target_lifetimes() -> void:
	await super._check_committed_target_lifetimes()
	await _check_touch_update_order()
	await _check_plant_selection_order()


func _create_touch_enemy(family: String) -> LayeredRangedEnemy:
	var config := load("res://resources/config/enemies/" + family + ".tres").duplicate() as EnemyConfig
	config.max_health = 10000000
	var enemy := config.enemy_scene.instantiate() as LayeredRangedEnemy
	if family == "capoo_ak47":
		enemy.set_script(CountedAK)
	elif family == "combat_robot_gunner":
		enemy.set_script(CountedGunner)
	enemy.disable_mode = CollisionObject2D.DISABLE_MODE_KEEP_ACTIVE
	_runtime.enemy_container.add_child(enemy)
	enemy.global_position = Vector2(2000, 2000)
	enemy.setup(config, _runtime.player, null, _runtime)
	enemy.set_objective_target(_runtime.player)
	return enemy


func _check_touch_update_order() -> void:
	_runtime.player._refresh_collectible_stats(false)
	var player_health_before := _runtime.player.max_health
	var config := _runtime.plant_system.get_config(&"corn_machine_gun").duplicate() as PlantDefenseConfig
	var plant := _runtime.plant_system._instantiate_registered_plant(config, Vector2i(6, 6), _runtime.player, 5101, false, -1, 0, -1, false)
	plant.global_position = Vector2(2010, 2000)
	plant.max_health = 10000000
	var victim := _create_enemy("capoo_ak47")
	victim.global_position = Vector2(2000, 2000)
	victim.set_combat_faction_id(CombatRelationService.PLAYER_ALLIED, -1, true)
	var contact_traces := {}
	for family in ["capoo_ak47", "capoo_rpg", "combat_robot_gunner"]:
		for scenario in ["empty", "player", "plant", "both", "dead_player", "dead_plant", "freed_plant", "dynamic", "dynamic_plant", "dynamic_stale_plant"]:
			for active_cooldown in [false, true]:
				var alternatives: Array = []
				for original in [true, false]:
					_runtime.player.is_dead = scenario == "dead_player"
					_runtime.player.current_health = player_health_before
					_runtime.player.invincibility_time_left = 0.0
					plant.current_health = 10000000
					plant.is_dead = scenario in ["dead_plant", "dynamic_stale_plant"]
					victim.current_health = 10000000
					var enemy := _create_touch_enemy(family)
					if scenario in ["player", "both", "dead_player"]:
						enemy.touching_players[_runtime.player.get_instance_id()] = _runtime.player
					if scenario in ["plant", "both", "dead_plant", "dynamic_plant", "dynamic_stale_plant"]:
						enemy.touching_plants[plant.get_instance_id()] = plant
						enemy.touching_plant_entry_distances[plant.get_instance_id()] = 100.0
					if scenario == "freed_plant":
						var obsolete := PlantDefense.new()
						enemy.touching_plants[obsolete.get_instance_id()] = obsolete
						obsolete.free()
					if scenario.begins_with("dynamic"):
						enemy.set_objective_target(victim)
						enemy.touch_damage_extent_radius = 30.0
						_check(enemy._has_dynamic_enemy_target_contact(), family + " uses a real dynamic Enemy contact")
					enemy.touch_damage_last_physics_delta = 1.0 / 30.0
					if active_cooldown:
						enemy.touch_damage_cooldown_left = 0.5
					var counted := enemy is CountedAK or enemy is CountedGunner
					if counted:
						enemy.set("dynamic_queries", 0)
						enemy.set("touch_attempts", 0)
						enemy.set("wakes", 0)
					if original:
						_reference_touch_update(enemy, DELTA)
					else:
						enemy._update_touch_damage(DELTA)
					alternatives.append({"state": [enemy.touched_plant == plant, enemy.touched_player == _runtime.player,
						enemy.touching_plants.size(), enemy.touching_players.size(),
						enemy.touch_damage_last_physics_delta, enemy.touch_damage_cooldown_left,
						enemy.touch_damage_cooldown_deadline_physics_frame - Engine.get_physics_frames(),
						_runtime.player.current_health, plant.current_health, victim.current_health,
						enemy.get("wakes") if counted else 0, enemy.get("touch_attempts") if counted else 0],
						"dynamic_queries": enemy.get("dynamic_queries") if counted else -1})
					enemy.queue_free()
				_check(alternatives[0].state == alternatives[1].state, family + " contact/damage/deadline/wake parity " + scenario + str(active_cooldown))
				if family != "combat_robot_gunner":
					_check(alternatives[1].state[7] == player_health_before and alternatives[1].state[8] == 10000000 and alternatives[1].state[9] == 10000000,
						family + " never adds inherited touch damage")
				elif not active_cooldown and scenario in ["player", "plant", "both", "dynamic", "dynamic_stale_plant"]:
					_check(alternatives[1].state[7] + alternatives[1].state[8] + alternatives[1].state[9] < player_health_before + 20000000,
						"Gunner preserves its actual touch hit " + scenario)
				if family == "capoo_ak47" and scenario in ["plant", "both", "dynamic_plant"]:
					_check(alternatives[0].dynamic_queries == 1 and alternatives[1].dynamic_queries == 0,
						"Valid plant priority eliminates the discarded dynamic contact query")
				contact_traces[family + ":" + scenario + ":" + str(active_cooldown)] = alternatives
				await get_tree().process_frame
	plant.is_dead = false
	_runtime.player.is_dead = false
	var enemy := _create_touch_enemy("capoo_ak47") as CountedAK
	enemy.touching_plants[plant.get_instance_id()] = plant
	enemy.touching_plant_entry_distances[plant.get_instance_id()] = 100.0
	var samples: Array = []
	for original in [true, false]:
		enemy.dynamic_queries = 0
		var started := Time.get_ticks_usec()
		for iteration in 60000:
			if original:
				_reference_touch_update(enemy, DELTA)
			else:
				enemy._update_touch_damage(DELTA)
		samples.append({"original": original, "usec": Time.get_ticks_usec() - started, "dynamic_queries": enemy.dynamic_queries})
	_traces["touch_update_microbenchmark"] = samples
	_traces["touch_update_cases"] = contact_traces
	enemy.queue_free()
	plant.queue_free()
	victim.queue_free()
	await get_tree().process_frame


# Exact prior synchronous update, including the unreachable repeated empty guard.
# All selection, validation, damage and clock operations call production methods.
func _reference_touch_update(enemy: Enemy, delta: float) -> void:
	if is_finite(delta) and delta > 0.0:
		enemy.touch_damage_last_physics_delta = delta
	var has_dynamic := enemy._has_dynamic_enemy_target_contact()
	if enemy.touching_plants.is_empty() and enemy.touching_players.is_empty() and not has_dynamic:
		enemy.touched_plant = null
		enemy.touched_player = null
		return
	if enemy.touching_plants.is_empty() and enemy.touching_players.is_empty() and not has_dynamic:
		enemy.touched_plant = null
		enemy.touched_player = null
		return
	enemy.touched_plant = enemy._select_touching_plant()
	if enemy.touched_plant != null:
		if enemy.is_touch_damage_cooldown_ready():
			enemy._try_deal_touch_damage()
		return
	if has_dynamic:
		if enemy.is_touch_damage_cooldown_ready():
			enemy._try_deal_touch_damage()
		return
	if enemy.touched_player == null or not is_instance_valid(enemy.touched_player) or not enemy.can_attack_combat_target(enemy.touched_player):
		enemy.touched_player = enemy._select_touching_player()
		if enemy.touched_player == null:
			return
	if not enemy.is_touch_damage_cooldown_ready():
		return
	enemy._try_deal_touch_damage()


func _check_plant_selection_order() -> void:
	var plants: Array[PlantDefense] = []
	var config := _runtime.plant_system.get_config(&"corn_machine_gun") as PlantDefenseConfig
	for index in 32:
		var plant := _runtime.plant_system._instantiate_registered_plant(config, Vector2i(20 + index, 20), _runtime.player, 6200 + index, false, -1, 0, -1, false)
		plant.global_position = Vector2(2010 + index, 2000)
		plants.append(plant)
	var enemy := _create_touch_enemy("capoo_ak47")
	var samples := {}
	for ordering in ["near_first", "near_last", "mixed", "ties"]:
		enemy._clear_touching_players()
		for index in 32:
			var ordinal: int = 31 - index if ordering == "near_last" else (index * 13 % 32 if ordering == "mixed" else index)
			var plant := plants[ordinal]
			plant.global_position = Vector2(2010, 2000) if ordering == "ties" else Vector2(2010 + ordinal, 2000)
			enemy.touching_plants[plant.get_instance_id()] = plant
		_check(_reference_plant_selection(enemy) == plants[0] and enemy._select_touching_plant() == plants[0],
			"Nearest/tied network ID order remains stable " + ordering)
		var timings: Array = []
		for original in [true, false]:
			var started := Time.get_ticks_usec()
			for iteration in 2000:
				if original:
					_reference_plant_selection(enemy)
				else:
					enemy._select_touching_plant()
			timings.append({"original": original, "usec": Time.get_ticks_usec() - started})
		samples[ordering] = timings
	# Eligibility and stale pruning must precede the distance shortcut.
	plants[31].is_removing = true
	_check(enemy._select_touching_plant() == plants[0] and not enemy.touching_plants.has(plants[31].get_instance_id()),
		"A farther removing building is still pruned before its stable ID can be skipped")
	_traces["plant_selection_microbenchmark"] = samples
	enemy.queue_free()
	for plant in plants:
		plant.queue_free()
	await get_tree().process_frame


func _reference_plant_selection(enemy: Enemy) -> PlantDefense:
	if enemy.touching_plants.is_empty():
		if enemy.touched_plant != null:
			enemy.touched_plant = null
			enemy._clear_cached_navigation_move_direction()
		return null
	# The typed eligibility gate below already checks removal, health and water
	# targeting. Re-entering the generic target gate repeated those same checks
	# and faction lookup for every neighboring building.
	var hostile_to_plants := enemy._is_hostile_combat_faction(CombatRelationService.PLAYER_ALLIED)
	var enemy_position := enemy.global_position
	var best_plant: PlantDefense = null
	var best_distance_squared := INF
	var best_network_id := 0
	var best_instance_id := 0
	var stale_plant_ids: Array[int] = []
	for instance_id in enemy.touching_plants:
		var plant := enemy._get_valid_touching_plant_record(instance_id)
		if not enemy.can_attack_plant_target(plant):
			stale_plant_ids.append(instance_id)
			continue
		if not hostile_to_plants:
			continue
		var distance_squared := enemy_position.distance_squared_to(
			plant.global_position
		)
		var network_id := int(plant.get_meta(&"net_id", 0))
		if network_id <= 0:
			network_id = instance_id
		var distance_ties := distance_squared == best_distance_squared
		if (
			best_plant == null
			or distance_squared < best_distance_squared
			or (
				distance_ties
				and (
					network_id < best_network_id
					or (
						network_id == best_network_id
						and instance_id < best_instance_id
					)
				)
			)
		):
			best_plant = plant
			best_distance_squared = distance_squared
			best_network_id = network_id
			best_instance_id = instance_id
	var stale_record_removed := false
	for stale_id in stale_plant_ids:
		stale_record_removed = (
			enemy._erase_touching_plant_record(stale_id, false)
			or stale_record_removed
		)
	if stale_record_removed:
		enemy._clear_cached_navigation_move_direction()
	return best_plant

