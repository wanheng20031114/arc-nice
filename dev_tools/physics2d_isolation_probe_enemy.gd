extends YuanshiInsect

# Test-only switch used by physics2d_isolation_ab_probe.gd. The production
# navigation direction is still computed by YuanshiInsect; this class only
# turns that already-computed direction into a generation-bound clearance
# certificate so Enemy._move_until_player_contact() takes its direct-transform
# branch instead of move_and_slide().
var probe_force_verified_direct := false


func _get_navigation_move_direction(delta: float) -> Vector2:
	var move_direction := super._get_navigation_move_direction(delta)
	if probe_force_verified_direct and move_direction != Vector2.ZERO:
		_cache_navigation_move_direction(move_direction, true, INF)
	return move_direction


func _can_use_verified_direct_objective_linear_movement(motion: Vector2) -> bool:
	if not probe_force_verified_direct:
		return super._can_use_verified_direct_objective_linear_movement(motion)
	var motion_distance := motion.length()
	if (
		motion_distance <= 0.0
		or cached_navigation_move_direction == Vector2.ZERO
		or not is_instance_valid(objective_target)
	):
		return false
	return (
		cached_navigation_uses_direct_objective_approach
		and cached_navigation_generation == _get_current_navigation_generation()
		and cached_navigation_move_direction.dot(motion)
			>= motion_distance * 0.999
		and cached_navigation_move_direction.dot(
			objective_target.global_position - global_position
		) > 0.0
		and motion_distance
			<= cached_navigation_verified_direct_motion_clearance + 0.0001
	)
