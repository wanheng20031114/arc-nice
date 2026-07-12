extends Enemy
class_name CapooRangedEnemy

const WORLD_COLLISION_MASK := 1
const NO_PATHFINDER_DIRECT_CHASE_DISTANCE := 192.0
const NO_PATHFINDER_DIRECT_CHASE_DISTANCE_SQUARED := (
	NO_PATHFINDER_DIRECT_CHASE_DISTANCE * NO_PATHFINDER_DIRECT_CHASE_DISTANCE
)
const XIRANG_DROP_SCENE := preload("res://scene/xirang_drop.tscn")
const PICKUP_SCENE := preload("res://scene/pickup.tscn")

@export var path_refresh_interval: float = 0.25
@export var waypoint_arrival_distance: float = 6.0
@export var direct_chase_extra_distance: float = 2.0

var random_generator := RandomNumberGenerator.new()
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
	if not is_instance_valid(target_player):
		return false
	return _has_clear_world_line_to_position(target_player.global_position)


func _has_clear_world_line_to_objective() -> bool:
	if not is_instance_valid(objective_target):
		return false
	return _has_clear_world_line_to_position(objective_target.global_position)


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
	if not is_instance_valid(reward_player):
		return
	var drop_parent := get_parent()
	if drop_parent == null:
		return
	if _request_xirang_reward(
		config.xirang_drop_amount,
		reward_player,
		global_position,
		Vector2.ZERO
	):
		return
	var drop := XIRANG_DROP_SCENE.instantiate() as XirangDrop
	if drop == null:
		return
	drop_parent.add_child(drop)
	drop.setup(config.xirang_drop_amount, reward_player, global_position, Vector2.ZERO)


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
