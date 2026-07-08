extends Area2D

class_name Bullet

# 世界碰撞层的掩码
const WORLD_COLLISION_MASK := 1

# 子弹飞行速度
@export var speed:float = 320.0
# 子弹最大存活时间（秒）
@export var max_lifetime: float = 2.0

# 子弹当前的飞行方向
var direction : Vector2 = Vector2.RIGHT
# 由发射者在生成时写入，命中目标时读取。
var damage: int = 1
# 剩余存活时间
var remaining_lifetime : float = 0.0
var projectile_id: int = 0
var owner_peer_id: int = 0
var source_type: StringName = &"player_bullet"
var pierces_enemies: bool = false
var hit_enemy_instance_ids: Dictionary = {}
var collectible_owner: Player = null


func _ready() -> void:
	remaining_lifetime = max_lifetime


# 外部生成子弹后调用，用来设置方向
func setup(
	initial_direction: Vector2,
	initial_damage: int = 1,
	initial_pierces_enemies: bool = false
) -> void:
	if initial_direction != Vector2.ZERO:
		direction = initial_direction.normalized()
		rotation = direction.angle()
	damage = maxi(initial_damage, 0)
	pierces_enemies = initial_pierces_enemies


func setup_multiplayer(
	new_projectile_id: int,
	new_owner_peer_id: int,
	new_source_type: StringName
) -> void:
	projectile_id = maxi(new_projectile_id, 0)
	owner_peer_id = new_owner_peer_id
	source_type = new_source_type


func setup_collectible_owner(owner: Player) -> void:
	collectible_owner = owner


# 物理帧更新逻辑，处理子弹移动和碰撞检测
func _physics_process(delta: float) -> void:
	var current_position: Vector2 = global_position
	var next_position: Vector2 = current_position + direction * speed * delta
	
	# 检查这一帧移动路径是否撞到世界
	if _will_hit_world(current_position, next_position):
		queue_free()
		return
	
	global_position = next_position
	
	# 生命周期结束后自动删除
	remaining_lifetime -= delta
	if remaining_lifetime <= 0.0:
		queue_free()


# 检测从当前位置到下一位置之间是否撞到墙体/世界
func _will_hit_world(from_position: Vector2, to_position: Vector2) -> bool:
	var space_state := get_world_2d().direct_space_state
	
	if space_state == null:
		return false
	
	var query := PhysicsRayQueryParameters2D.create(
		from_position,
		to_position,
		WORLD_COLLISION_MASK
	)
	
	query.collide_with_bodies = true
	query.collide_with_areas = false
	
	var hit_result: Dictionary = space_state.intersect_ray(query)
	
	return not hit_result.is_empty()


# 撞到其他 Area2D 时
func _on_area_entered(area: Area2D) -> void:
	if area is Bullet :
		return
	queue_free()


# 撞到 PhysicsBody2D 时，比如 StaticBody2D / CharacterBody2D / RigidBody2D
func _on_body_entered(body: Node2D) -> void:
	var enemy := body as Enemy
	if enemy != null:
		try_hit_enemy(enemy)
		return

	queue_free()


func try_hit_enemy(enemy: Enemy) -> bool:
	if is_queued_for_deletion():
		return false
	if enemy == null or not is_instance_valid(enemy):
		return false
	if not _try_mark_enemy_hit(enemy):
		return false

	var hit_registered := false
	if _try_report_multiplayer_enemy_hit(enemy):
		hit_registered = true
	else:
		hit_registered = enemy.apply_damage(damage, -direction)

	if not hit_registered:
		hit_enemy_instance_ids.erase(enemy.get_instance_id())
		return false
	if collectible_owner != null and is_instance_valid(collectible_owner):
		collectible_owner.apply_collectible_bullet_hit_effects(enemy, damage)
	if not pierces_enemies:
		queue_free()
	return true


func _try_mark_enemy_hit(enemy: Enemy) -> bool:
	var enemy_id := enemy.get_instance_id()
	if hit_enemy_instance_ids.has(enemy_id):
		return false
	hit_enemy_instance_ids[enemy_id] = true
	return true


func _try_report_multiplayer_enemy_hit(enemy: Enemy) -> bool:
	if projectile_id <= 0:
		return false
	var current_scene := get_tree().current_scene
	if current_scene == null or not current_scene.has_method("request_enemy_hit_report"):
		return false
	var enemy_net_id := int(enemy.get_meta("net_id", 0))
	if enemy_net_id <= 0:
		return false
	current_scene.call(
		"request_enemy_hit_report",
		projectile_id,
		owner_peer_id,
		enemy_net_id,
		damage,
		-enemy.global_position.direction_to(global_position)
	)
	return true
