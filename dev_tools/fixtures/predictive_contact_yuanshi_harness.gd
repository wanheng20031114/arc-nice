extends YuanshiInsect
class_name PredictiveContactYuanshiHarness

## Authored-scene integration harness: collision shapes and movement remain the
## production Yuanshi implementation; only navigation output and its static
## straight-translation proof are deterministic for continuous-contact tests.

var forced_move_direction := Vector2.ZERO
var forced_move_speed := 0.0
var force_straight_plan_certified := true


func _get_navigation_move_direction(_delta: float) -> Vector2:
	return forced_move_direction.normalized()


func _get_move_speed() -> float:
	return maxf(forced_move_speed, 0.0)


func is_layered_area_contact_plan_certified(
	_delta: float,
	_counterpart: Node2D
) -> bool:
	return force_straight_plan_certified
