extends Enemy
class_name YuanshiInsect

const PICKUP_SCENE := preload("res://scene/pickup.tscn")
const XIRANG_DROP_SCENE := preload("res://scene/xirang_drop.tscn")
const MAX_XIRANG_ORBS_PER_ENEMY := 4

# 寻路路径刷新间隔。多只敌人共享 GridPathfinder，但各自按这个节奏更新目标路径。
@export var path_refresh_interval: float = 0.25

# 距离当前路点小于该值时，切换到下一个路点。
@export var waypoint_arrival_distance: float = 6.0

# 足够接近玩家时直接追踪玩家当前位置，避免围绕玩家所在格子中心反复寻路。
@export var direct_chase_extra_distance: float = 2.0

# 敌人实例自己的随机数生成器，用于掉落判定。
var random_generator: RandomNumberGenerator = RandomNumberGenerator.new()
# 当前缓存路径，避免每帧重复计算 A*。
var current_path: PackedVector2Array = PackedVector2Array()
var current_path_index: int = 0
var path_refresh_time_left: float = 0.0


func _ready() -> void:
	super._ready()
	random_generator.randomize()


func _physics_process(delta: float) -> void:
	_update_hurt_blink(delta)
	_update_touch_damage(delta)

	if is_dead:
		velocity = Vector2.ZERO
		return

	if not is_instance_valid(target_player):
		velocity = Vector2.ZERO
		move_and_slide()
		return

	var move_direction := _get_navigation_move_direction(delta)
	_update_facing(move_direction)
	velocity = move_direction * _get_move_speed()
	move_and_slide()


func _get_move_speed() -> float:
	if config == null:
		return 0.0
	return config.move_speed


func _get_navigation_move_direction(delta: float) -> Vector2:
	path_refresh_time_left = maxf(path_refresh_time_left - delta, 0.0)

	if _should_direct_chase_target():
		_clear_navigation_path()
		return global_position.direction_to(target_player.global_position)

	if pathfinder == null or not pathfinder.get("is_built"):
		return global_position.direction_to(target_player.global_position)

	if path_refresh_time_left <= 0.0 or current_path.is_empty():
		_refresh_navigation_path()

	if current_path.is_empty():
		return global_position.direction_to(target_player.global_position)

	while current_path_index < current_path.size():
		var waypoint := current_path[current_path_index]
		if global_position.distance_to(waypoint) > waypoint_arrival_distance:
			return global_position.direction_to(waypoint)
		current_path_index += 1

	return global_position.direction_to(target_player.global_position)


func _refresh_navigation_path() -> void:
	path_refresh_time_left = maxf(path_refresh_interval, 0.05)
	current_path = pathfinder.get_global_path(global_position, target_player.global_position)
	current_path_index = 0


func _clear_navigation_path() -> void:
	current_path = PackedVector2Array()
	current_path_index = 0
	path_refresh_time_left = 0.0


func _should_direct_chase_target() -> bool:
	var direct_chase_distance := _get_body_extent_radius() + _get_target_extent_radius() + direct_chase_extra_distance
	return global_position.distance_to(target_player.global_position) <= direct_chase_distance


func _get_body_extent_radius() -> float:
	return _get_body_collision_extent_radius()


func _get_target_extent_radius() -> float:
	var target_collision_shape := target_player.get_node_or_null("CollisionShape2D") as CollisionShape2D
	if target_collision_shape == null:
		return 0.0

	return _get_collision_shape_extent_radius(target_collision_shape)


# 根据水平移动方向更新贴图翻转，竖直移动时保留当前朝向。
func _update_facing(move_direction: Vector2) -> void:
	if is_zero_approx(move_direction.x):
		return
	_set_facing_from_direction(move_direction)


func _apply_multiplayer_player_damage(
	hit_player: Player,
	damage_amount: int,
	source_id: int,
	source_type: StringName
) -> void:
	if hit_player == null or damage_amount <= 0:
		return
	var current_scene := get_tree().current_scene
	if current_scene != null and current_scene.has_method("request_multiplayer_player_damage"):
		current_scene.call(
			"request_multiplayer_player_damage",
			source_id,
			hit_player.peer_id,
			damage_amount,
			source_type
		)
		return
	hit_player.apply_damage(damage_amount)


func _get_multiplayer_damage_source_id(source_suffix: int) -> int:
	var net_id := int(get_meta("net_id", get_instance_id()))
	return maxi(net_id, 1) * 1000000 + maxi(source_suffix, 0)


func _die() -> void:
	if is_dead:
		return

	call_deferred("_drop_xirang")
	_try_drop_pickup()
	super._die()


# 敌人死亡后按概率掉落一个随机道具。
func _try_drop_pickup() -> void:
	if config == null:
		return

	if config.pickup_drop_configs.is_empty():
		return

	if random_generator.randf() > config.pickup_drop_chance:
		return

	var pickup_config := _pick_pickup_drop_config()
	if pickup_config == null:
		return

	call_deferred("_spawn_dropped_pickup", pickup_config, global_position)


func _pick_pickup_drop_config() -> PickupConfig:
	if config == null:
		return null

	var available_pickup_configs: Array[PickupConfig] = []
	var total_weight := 0.0

	for pickup_config in config.pickup_drop_configs:
		if pickup_config == null:
			continue
		if pickup_config.drop_weight <= 0.0:
			continue

		available_pickup_configs.append(pickup_config)
		total_weight += pickup_config.drop_weight

	if available_pickup_configs.is_empty():
		return null
	if total_weight <= 0.0:
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


func _drop_xirang() -> void:
	if config == null:
		return
	if config.xirang_drop_amount <= 0:
		return
	if not is_instance_valid(target_player):
		return

	var drop_parent := get_parent()
	if drop_parent == null:
		return

	var orb_count := mini(config.xirang_drop_amount, MAX_XIRANG_ORBS_PER_ENEMY)
	var base_value := floori(float(config.xirang_drop_amount) / float(orb_count))
	var remainder := config.xirang_drop_amount % orb_count

	for orb_index in range(orb_count):
		var drop := XIRANG_DROP_SCENE.instantiate() as XirangDrop
		if drop == null:
			continue

		var orb_value := base_value + (1 if orb_index < remainder else 0)
		var angle := random_generator.randf_range(0.0, TAU)
		var distance := random_generator.randf_range(8.0, 18.0)
		var landing_offset := Vector2.RIGHT.rotated(angle) * distance
		drop_parent.add_child(drop)
		drop.setup(orb_value, target_player, global_position, landing_offset)
