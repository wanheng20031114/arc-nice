extends Area2D

class_name Bullet

const WORLD_COLLISION_MASK := 1

@export var speed:float = 320.0
@export var max_lifetime: float = 2.0
# Called when the node enters the scene tree for the first time.

var direction : Vector2 = Vector2.RIGHT
var remaining_lifetime : float = 0.0


func _ready() -> void:
	remaining_lifetime = max_lifetime
	
	# 连接 Area2D 碰撞信号
	area_entered.connect(_on_area_entered)
	body_entered.connect(_on_body_entered)


# 外部生成子弹后调用，用来设置方向
func setup(initial_direction: Vector2) -> void:
	if initial_direction != Vector2.ZERO:
		direction = initial_direction.normalized()
		rotation = direction.angle()


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
	# 这里之后可以写伤害逻辑
	# 例如：
	# if body.has_method("take_damage"):
	# 	body.take_damage(1)
	
	queue_free()
	
	
