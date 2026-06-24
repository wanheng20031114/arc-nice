extends Enemy
class_name CapooRangedEnemy

const WORLD_COLLISION_MASK := 1
const XIRANG_DROP_SCENE := preload("res://scene/xirang_drop.tscn")
const PICKUP_SCENE := preload("res://scene/pickup.tscn")

@export var path_refresh_interval: float = 0.25
@export var waypoint_arrival_distance: float = 6.0
@export var direct_chase_extra_distance: float = 2.0

var random_generator := RandomNumberGenerator.new()
var current_path: PackedVector2Array = PackedVector2Array()
var current_path_index: int = 0
var path_refresh_time_left: float = 0.0
var action_sequence: int = 0


func _ready() -> void:
	super._ready()
	random_generator.randomize()


func _die() -> void:
	call_deferred("_drop_xirang")
	_try_drop_pickup()
	super._die()


func _get_move_speed() -> float:
	return get_effective_move_speed()


func _get_navigation_move_direction(delta: float) -> Vector2:
	path_refresh_time_left = maxf(path_refresh_time_left - delta, 0.0)
	if not _should_update_navigation_direction():
		return cached_navigation_move_direction

	if _should_direct_chase_target():
		var direct_move_direction := _get_shape_safe_move_direction_to_target(target_player)
		if direct_move_direction != Vector2.ZERO:
			_clear_navigation_path()
			return _cache_navigation_move_direction(direct_move_direction)
		path_refresh_time_left = minf(path_refresh_time_left, _get_navigation_retry_interval())

	if pathfinder == null or not pathfinder.get("is_built"):
		return _cache_navigation_move_direction(_get_shape_safe_move_direction_to_target(target_player))

	var flow_direction := _get_shared_flow_navigation_direction(target_player, pathfinder)
	if flow_direction != Vector2.ZERO:
		_clear_navigation_path()
		return _cache_navigation_move_direction(flow_direction)

	if path_refresh_time_left <= 0.0 or current_path.is_empty():
		_refresh_navigation_path()

	if current_path.is_empty():
		return _cache_navigation_move_direction(_get_navigation_fallback_move_direction())

	while current_path_index < current_path.size():
		var waypoint := current_path[current_path_index]
		if global_position.distance_to(waypoint) > waypoint_arrival_distance:
			return _cache_navigation_move_direction(_get_axis_aligned_waypoint_direction(waypoint, waypoint_arrival_distance))
		current_path_index += 1

	return _cache_navigation_move_direction(_get_navigation_fallback_move_direction())


func _refresh_navigation_path() -> void:
	if pathfinder.has_method("try_get_global_path"):
		var path_result: Variant = pathfinder.call(
			"try_get_global_path",
			global_position,
			target_player.global_position,
			_get_body_collision_half_extents()
		)
		if path_result == null:
			path_refresh_time_left = _get_navigation_retry_interval()
			return
		current_path = path_result
	else:
		current_path = pathfinder.get_global_path(global_position, target_player.global_position, _get_body_collision_half_extents())
	path_refresh_time_left = _get_navigation_refresh_interval()
	current_path_index = 0


func _get_navigation_refresh_interval() -> float:
	return maxf(path_refresh_interval, 0.05) * random_generator.randf_range(0.75, 1.25)


func _get_navigation_retry_interval() -> float:
	return random_generator.randf_range(0.03, 0.08)


func _clear_navigation_path() -> void:
	current_path = PackedVector2Array()
	current_path_index = 0
	path_refresh_time_left = 0.0
	_clear_cached_navigation_move_direction()


func _get_navigation_fallback_move_direction() -> Vector2:
	if _has_clear_world_line_to_target():
		var direct_direction := _get_shape_safe_move_direction_to_target(target_player)
		if direct_direction != Vector2.ZERO:
			return direct_direction
	path_refresh_time_left = minf(path_refresh_time_left, _get_navigation_retry_interval())
	return Vector2.ZERO


func _should_direct_chase_target() -> bool:
	var direct_chase_distance := _get_body_extent_radius() + _get_target_extent_radius() + direct_chase_extra_distance
	if global_position.distance_to(target_player.global_position) > direct_chase_distance:
		return false
	return _has_clear_world_line_to_target()


func _get_body_extent_radius() -> float:
	return _get_body_collision_extent_radius()


func _get_target_extent_radius() -> float:
	var target_collision_shape := target_player.get_node_or_null("CollisionShape2D") as CollisionShape2D
	if target_collision_shape == null:
		return 0.0
	return _get_collision_shape_extent_radius(target_collision_shape)


func _update_facing(move_direction: Vector2) -> void:
	if is_zero_approx(move_direction.x):
		return
	_set_facing_from_direction(move_direction)


func _play_config_animation(animation_name: StringName) -> void:
	_play_scene_animation(animation_name)


func _has_clear_world_line_to_target() -> bool:
	if not is_instance_valid(target_player):
		return false
	return _has_clear_world_line_to_position(target_player.global_position)


func _has_clear_world_line_to_position(target_position: Vector2) -> bool:
	var query := PhysicsRayQueryParameters2D.create(
		global_position,
		target_position,
		WORLD_COLLISION_MASK,
		[get_rid()]
	)
	query.collide_with_bodies = true
	query.collide_with_areas = false
	return get_world_2d().direct_space_state.intersect_ray(query).is_empty()


func _broadcast_enemy_action(action_name: StringName, direction: Vector2) -> void:
	action_sequence += 1
	var current_scene := get_tree().current_scene
	if current_scene != null and current_scene.has_method("broadcast_enemy_action"):
		current_scene.call(
			"broadcast_enemy_action",
			int(get_meta("net_id", 0)),
			action_name,
			direction,
			global_position,
			action_sequence
		)


func _broadcast_enemy_target_action(action_name: StringName, target_peer_id: int) -> void:
	action_sequence += 1
	var current_scene := get_tree().current_scene
	if current_scene != null and current_scene.has_method("broadcast_enemy_target_action"):
		current_scene.call(
			"broadcast_enemy_target_action",
			int(get_meta("net_id", 0)),
			action_name,
			target_peer_id,
			global_position,
			action_sequence
		)


func _get_multiplayer_damage_source_id(source_suffix: int) -> int:
	var net_id := int(get_meta("net_id", get_instance_id()))
	return maxi(net_id, 1) * 1000000 + maxi(source_suffix, 0)


func _drop_xirang() -> void:
	if config == null or config.xirang_drop_amount <= 0:
		return
	if not is_instance_valid(target_player):
		return
	var drop_parent := get_parent()
	if drop_parent == null:
		return
	var drop := XIRANG_DROP_SCENE.instantiate() as XirangDrop
	if drop == null:
		return
	drop_parent.add_child(drop)
	drop.setup(config.xirang_drop_amount, target_player, global_position, Vector2.ZERO)


func _try_drop_pickup() -> void:
	if config == null or config.pickup_drop_configs.is_empty():
		return
	if random_generator.randf() > config.pickup_drop_chance:
		return
	var pickup_config := _pick_pickup_drop_config()
	if pickup_config != null:
		call_deferred("_spawn_dropped_pickup", pickup_config, global_position)


func _pick_pickup_drop_config() -> PickupConfig:
	var available_pickup_configs: Array[PickupConfig] = []
	var total_weight := 0.0
	for pickup_config in config.pickup_drop_configs:
		if pickup_config == null or pickup_config.drop_weight <= 0.0:
			continue
		available_pickup_configs.append(pickup_config)
		total_weight += pickup_config.drop_weight
	if available_pickup_configs.is_empty() or total_weight <= 0.0:
		return null
	var target_weight := random_generator.randf_range(0.0, total_weight)
	var accumulated_weight := 0.0
	for pickup_config in available_pickup_configs:
		accumulated_weight += pickup_config.drop_weight
		if target_weight <= accumulated_weight:
			return pickup_config
	return available_pickup_configs.back()


func _spawn_dropped_pickup(pickup_config: PickupConfig, spawn_position: Vector2) -> void:
	var drop_parent := get_parent()
	if drop_parent == null:
		return
	var pickup_instance := PICKUP_SCENE.instantiate() as Pickup
	if pickup_instance == null:
		return
	pickup_instance.config = pickup_config
	drop_parent.add_child(pickup_instance)
	pickup_instance.global_position = spawn_position
