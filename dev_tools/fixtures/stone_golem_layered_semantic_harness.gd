extends StoneGolem

var event_order: Array[StringName] = []


func run_whole_event_probe(
	delta: float,
	target: Node2D,
	tick_count: int = 1
) -> Array[StringName]:
	_reset_probe(delta, target)
	for _tick_index in range(maxi(tick_count, 0)):
		_run_authoritative_physics_step(delta)
	return event_order.duplicate()


func run_layered_event_probe(
	delta: float,
	target: Node2D,
	tick_count: int = 1
) -> Array[StringName]:
	_reset_probe(delta, target)
	prepare_layered_area_authoritative_simulation()
	for _tick_index in range(maxi(tick_count, 0)):
		_simulate_layered_area_event_body(delta, delta, 1)
	return event_order.duplicate()


func _reset_probe(delta: float, target: Node2D) -> void:
	event_order.clear()
	combat_state = CombatState.CHASE
	attack_cooldown_left = 1.0
	slam_impact_time_left = delta * 2.0
	objective_target = target
	velocity = Vector2.ZERO


func _update_attack_cooldown(delta: float) -> void:
	event_order.append(&"knight")
	super._update_attack_cooldown(delta)


func _update_slam_impact_visual(delta: float) -> void:
	event_order.append(&"stone_visual")
	slam_impact_time_left = maxf(slam_impact_time_left - delta, 0.0)


func _is_combat_sense_refresh_due() -> bool:
	return false


func _get_navigation_move_direction(_delta: float) -> Vector2:
	return Vector2.ZERO


func _has_player_contact() -> bool:
	return false


func _move_until_player_contact(_delta: float = -1.0) -> void:
	pass


func _move_after_confirmed_no_contact(_delta: float = -1.0) -> void:
	pass
