extends YuanshiInsect
class_name PredictiveContactYuanshiHarness

## Authored-scene integration harness: collision shapes and movement remain the
## production Yuanshi implementation; only navigation output and its static
## straight-translation proof are deterministic for continuous-contact tests.

var forced_move_direction := Vector2.ZERO
var forced_move_speed := 0.0
var force_straight_plan_certified := true
var request_compat_mode_on_next_event := false


func simulate_trusted_layered_area_event_phase(
	delta: float,
	simulation_tick: int
) -> bool:
	var completed := super.simulate_trusted_layered_area_event_phase(
		delta,
		simulation_tick
	)
	if (
		request_compat_mode_on_next_event
		and enemy_simulation_coordinator != null
		and is_instance_valid(enemy_simulation_coordinator)
	):
		request_compat_mode_on_next_event = false
		enemy_simulation_coordinator.set_mode(
			EnemySimulationPolicy.Mode.COMPAT_60
		)
	return completed


func _get_navigation_move_direction(_delta: float) -> Vector2:
	return forced_move_direction.normalized()


func _get_move_speed() -> float:
	return maxf(forced_move_speed, 0.0)


func is_layered_area_contact_plan_certified(
	_delta: float,
	_counterpart: Node2D
) -> bool:
	return force_straight_plan_certified
