extends SceneTree

var _failures: Array[String] = []
var _checks := 0


func _initialize() -> void:
	_run.call_deferred()


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures.append(message)


func _reference(enemy: Enemy) -> int:
	var result := 0
	if enemy._has_collectible_status(&"burn"): result |= 1
	if enemy._has_collectible_status(&"bleed"): result |= 2
	if enemy._has_move_speed_modifier_below_default(): result |= 4
	if enemy._has_collectible_status(&"mark"): result |= 8
	if enemy.has_electromagnetic_attachment(): result |= 16
	return result


func _set_statuses(enemy: Enemy, count: int, sample: int) -> void:
	enemy.collectible_status_effects.clear()
	enemy.collectible_status_clock = 10.0
	enemy.move_speed_modifiers.clear()
	if sample % 2 == 0:
		enemy.move_speed_modifiers[&"slow"] = 0.7
		enemy.move_speed_modifiers[&"boost"] = 1.4
	enemy.permanent_electromagnetic_attachment = sample % 3 == 0
	var status_ids := [&"burn", &"bleed", &"mark", &"electromagnetic_attachment", &"unrelated"]
	for index in count:
		var state: Dictionary = {"status_id": status_ids[(sample + index) % status_ids.size()]}
		match (sample + index) % 7:
			0: state["expires_at"] = 9.0
			1: state["expires_at"] = 10.0 + Enemy.COLLECTIBLE_STATUS_DEADLINE_EPSILON
			2: state["expires_at"] = 11.0
			3: state["time_left"] = 0.0
			4: state["time_left"] = 0.1
			5:
				state["time_left"] = 20.0
				state["expires_at"] = 9.0
			6: state.clear()
		enemy.collectible_status_effects[StringName("player_%d" % index)] = state


func _run() -> void:
	var enemy := Enemy.new()
	for count in [0, 1, 6, 24, 96]:
		for sample in 140:
			_set_statuses(enemy, count, sample)
			_check(enemy.get_collectible_visual_status_mask() == _reference(enemy), "Status/reference mismatch count=%d sample=%d" % [count, sample])
			enemy.collectible_status_clock = 12.0
			_check(enemy.get_collectible_visual_status_mask() == _reference(enemy), "Clock advance retained expired status")
			enemy.collectible_status_effects.erase(&"player_0")
			_check(enemy.get_collectible_visual_status_mask() == _reference(enemy), "Immediate removal retained visual state")
	var shield := CombatRobotShieldBearer.new()
	var ninja := CombatRobotNinja.new()
	var elite := CombatRobotMainBattleElite.new()
	for sample in 28:
		for typed_enemy: Enemy in [shield, ninja, elite]:
			_set_statuses(typed_enemy, 24, sample)
		shield.shield_stage = sample % 3
		ninja.boost_active = sample % 2 == 0
		elite.airborne = sample % 2 == 0
		_check(shield.get_collectible_visual_status_mask() == (_reference(shield) | ((int(shield.shield_stage) << shield.SHIELD_STAGE_VISUAL_STATUS_SHIFT) & shield.SHIELD_STAGE_VISUAL_STATUS_MASK)), "Shield subclass extension changed")
		_check(ninja.get_collectible_visual_status_mask() == (_reference(ninja) | (ninja.BOOST_VISUAL_STATUS_MASK if ninja.boost_active else 0)), "Ninja subclass extension changed")
		_check(elite.get_collectible_visual_status_mask() == (_reference(elite) | (elite.AIRBORNE_VISUAL_STATUS_MASK if elite.airborne else 0)), "Elite subclass extension changed")
	var timings: Array[Dictionary] = []
	for count in [0, 1, 6, 24]:
		_set_statuses(enemy, count, 5)
		var old_usec := 0
		var new_usec := 0
		for repeat_index in 4:
			var before := Time.get_ticks_usec()
			if repeat_index % 2 == 0:
				for iteration in 6000: _reference(enemy)
				old_usec += Time.get_ticks_usec() - before
				before = Time.get_ticks_usec()
				for iteration in 6000: enemy.get_collectible_visual_status_mask()
				new_usec += Time.get_ticks_usec() - before
			else:
				for iteration in 6000: enemy.get_collectible_visual_status_mask()
				new_usec += Time.get_ticks_usec() - before
				before = Time.get_ticks_usec()
				for iteration in 6000: _reference(enemy)
				old_usec += Time.get_ticks_usec() - before
		timings.append({"effect_keys": count, "samples": 24000, "reference_usec": old_usec, "single_pass_usec": new_usec})
	enemy.free()
	shield.free()
	ninja.free()
	elite.free()
	print("ENEMY_VISUAL_STATUS_SNAPSHOT ", JSON.stringify({"checks": _checks, "timings": timings, "failures": _failures}))
	quit(0 if _failures.is_empty() else 1)
