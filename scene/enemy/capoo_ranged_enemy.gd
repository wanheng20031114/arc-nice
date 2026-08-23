extends Enemy
class_name CapooRangedEnemy

const WORLD_COLLISION_MASK := 1
const NO_PATHFINDER_DIRECT_CHASE_DISTANCE := 192.0
const NO_PATHFINDER_DIRECT_CHASE_DISTANCE_SQUARED := (
	NO_PATHFINDER_DIRECT_CHASE_DISTANCE * NO_PATHFINDER_DIRECT_CHASE_DISTANCE
)
@export var path_refresh_interval: float = 0.25
@export var waypoint_arrival_distance: float = 6.0
@export var direct_chase_extra_distance: float = 2.0

var action_sequence: int = 0


func can_target_water_plant_objectives() -> bool:
	return true


func supports_dynamic_enemy_targeting() -> bool:
	return true


# These families commit damage through their authored weapon state machines.
# Contact overlap remains active for target resolution and movement stopping,
# but must not add a second invisible touch hit.
func _uses_inherited_touch_damage() -> bool:
	return false


func _get_move_speed() -> float:
	return get_effective_move_speed()


func _get_navigation_move_direction(_delta: float) -> Vector2:
	if _can_direct_chase_player_without_pathfinder():
		return _cache_navigation_move_direction(
			_get_collision_safe_direct_objective_direction(
				target_player.global_position,
				waypoint_arrival_distance
			)
		)
	return _get_safe_navigation_move_direction(
		objective_target,
		pathfinder,
		waypoint_arrival_distance
	)


func _can_direct_chase_player_without_pathfinder() -> bool:
	return (
		(pathfinder == null or not bool(pathfinder.get("is_built")))
		and is_objective_targeting_player()
		and global_position.distance_squared_to(target_player.global_position)
			<= NO_PATHFINDER_DIRECT_CHASE_DISTANCE_SQUARED
		and _has_clear_world_line_to_target()
	)


func _update_facing(move_direction: Vector2) -> void:
	if is_zero_approx(move_direction.x):
		return
	_set_facing_from_direction(move_direction)


func _play_config_animation(animation_name: StringName) -> void:
	_play_scene_animation(animation_name)


func _has_clear_world_line_to_target() -> bool:
	var attack_target := get_attackable_objective()
	if attack_target == null:
		return false
	return _has_throttled_world_line_of_sight(attack_target, WORLD_COLLISION_MASK)


func _has_clear_world_line_to_objective() -> bool:
	if not is_instance_valid(objective_target):
		return false
	return _has_throttled_world_line_of_sight(objective_target, WORLD_COLLISION_MASK)


func _has_clear_world_line_to_position(target_position: Vector2) -> bool:
	return _is_world_segment_clear(target_position, WORLD_COLLISION_MASK)


func _broadcast_enemy_action(action_name: StringName, direction: Vector2) -> void:
	action_sequence += 1
	if gameplay_gateway != null and is_instance_valid(gameplay_gateway):
		gameplay_gateway.broadcast_enemy_action(
			int(get_meta("net_id", 0)),
			action_name,
			direction,
			global_position,
			action_sequence
		)


func _broadcast_enemy_target_action(action_name: StringName, target_peer_id: int) -> void:
	action_sequence += 1
	if gameplay_gateway != null and is_instance_valid(gameplay_gateway):
		gameplay_gateway.broadcast_enemy_target_action(
			int(get_meta("net_id", 0)),
			action_name,
			target_peer_id,
			global_position,
			action_sequence
		)


func _get_multiplayer_damage_source_id(source_suffix: int) -> int:
	var net_id := int(get_meta("net_id", get_instance_id()))
	return maxi(net_id, 1) * 1000000 + maxi(source_suffix, 0)
