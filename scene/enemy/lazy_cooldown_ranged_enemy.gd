@abstract
extends "res://scene/enemy/layered_ranged_enemy.gd"
class_name LazyCooldownRangedEnemy

## Only AK47/RPG opt into this timer contract. Their CHASE decisions still run
## every authored tick; reading cooldown catches up exact scalar subtractions.
const SimulationCooldown := preload("res://scene/combat/simulation/enemy_simulation_cooldown.gd")

var _attack_cooldown := SimulationCooldown.new()
var attack_cooldown_left: float:
	get:
		return _attack_cooldown.get_remaining()
	set(value):
		_attack_cooldown.set_remaining(value)
var chase_cooldown_event_sleep_enabled := true


func prepare_layered_area_authoritative_simulation() -> void:
	super.prepare_layered_area_authoritative_simulation()
	_refresh_attack_cooldown_clock_binding()


func try_attach_to_enemy_simulation_coordinator(coordinator: EnemySimulationCoordinator) -> bool:
	var attached := super.try_attach_to_enemy_simulation_coordinator(coordinator)
	if attached:
		_refresh_attack_cooldown_clock_binding()
	return attached


func on_authoritative_simulation_suspension_changed(coordinator: EnemySimulationCoordinator, suspended: bool) -> void:
	if suspended:
		_attack_cooldown.detach_clock()
	else:
		_attack_cooldown.bind_clock(coordinator.gameplay_step_clock)


func _refresh_attack_cooldown_clock_binding() -> void:
	if enemy_simulation_coordinator != null and authoritative_simulation_driver == AuthoritativeSimulationDriver.SCHEDULED_ACTIVE:
		_attack_cooldown.bind_clock(enemy_simulation_coordinator.gameplay_step_clock)
	else:
		_attack_cooldown.detach_clock()


func _update_attack_cooldown(delta: float) -> void:
	_attack_cooldown.advance_event(delta)


func _can_sleep_layered_area_family_event_phase() -> bool:
	# Ranged targets still need every authored contact-maintenance opportunity.
	# No cached touched object or dictionary member may enter this sparse lane.
	return indexed_touch_contact_snapshot_is_empty() and super._can_sleep_layered_area_family_event_phase()


func _can_sleep_layered_area_stationary_empty_contact_event() -> bool:
	return chase_cooldown_event_sleep_enabled
