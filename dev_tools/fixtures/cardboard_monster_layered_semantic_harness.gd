extends CardboardMonster

@export var indexed_touch_opt_in := true

var event_order: Array[StringName] = []


# The default inherits the verified production indexed capability. Setting this
# false authors the proxy-only cohort used to test the independent gate.
func supports_indexed_touch_authority() -> bool:
	return indexed_touch_opt_in


func run_whole_event_probe(
	delta: float,
	target: Node2D,
	tick_count: int = 1
) -> Array[StringName]:
	_reset_probe(target)
	for _tick_index in range(maxi(tick_count, 0)):
		_run_authoritative_physics_step(delta)
	return event_order.duplicate()


func run_layered_event_probe(
	delta: float,
	target: Node2D,
	tick_count: int = 1
) -> Array[StringName]:
	_reset_probe(target)
	prepare_layered_area_authoritative_simulation()
	for _tick_index in range(maxi(tick_count, 0)):
		_simulate_layered_area_event_body(delta, delta, 1)
	return event_order.duplicate()


func _reset_probe(target: Node2D) -> void:
	event_order.clear()
	combat_state = CombatState.CHASE
	attack_cooldown_left = 1.0
	objective_target = target
	velocity = Vector2.ZERO


func _update_touch_damage(_delta: float) -> void:
	event_order.append(&"touch")


func _update_attack_cooldown(delta: float) -> void:
	event_order.append(&"knight")
	super._update_attack_cooldown(delta)


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
