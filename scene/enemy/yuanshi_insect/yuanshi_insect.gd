extends Enemy
class_name YuanshiInsect

# 寻路路径刷新间隔。多只敌人共享 GridPathfinder，但各自按这个节奏更新目标路径。
@export var path_refresh_interval: float = 0.25

# 距离当前路点小于该值时，切换到下一个路点。
@export var waypoint_arrival_distance: float = 2.0

# 足够接近玩家时直接追踪玩家当前位置，避免围绕玩家所在格子中心反复寻路。
@export var direct_chase_extra_distance: float = 2.0

func _physics_process(delta: float) -> void:
	if is_dead:
		velocity = Vector2.ZERO
		return

	_update_touch_damage(delta)

	if not is_instance_valid(objective_target):
		velocity = Vector2.ZERO
		_move_until_player_contact()
		return
	if _has_player_contact():
		velocity = Vector2.ZERO
		return

	var move_direction := _get_navigation_move_direction(delta)
	_update_facing(move_direction)
	velocity = move_direction * _get_move_speed()
	_move_until_player_contact()


func _get_move_speed() -> float:
	return get_effective_move_speed()


func _get_navigation_move_direction(_delta: float) -> Vector2:
	return _get_safe_navigation_move_direction(
		objective_target,
		pathfinder,
		waypoint_arrival_distance
	)


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
