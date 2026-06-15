extends Area2D
class_name YuanshiInsectFireProjectile

const WORLD_COLLISION_MASK := 1

@export var speed: float = 142.5
@export var max_lifetime: float = 2.0

var direction := Vector2.RIGHT
var damage: int = 1
var remaining_lifetime: float = 0.0
var has_hit: bool = false


func _ready() -> void:
	remaining_lifetime = maxf(max_lifetime, 0.01)
	body_entered.connect(_on_body_entered)


func setup(
	initial_direction: Vector2,
	initial_damage: int,
	initial_speed: float,
	initial_lifetime: float
) -> void:
	if initial_direction != Vector2.ZERO:
		direction = initial_direction.normalized()
		rotation = direction.angle()
	damage = maxi(initial_damage, 0)
	speed = maxf(initial_speed, 0.0)
	max_lifetime = maxf(initial_lifetime, 0.01)
	remaining_lifetime = max_lifetime


func _physics_process(delta: float) -> void:
	if has_hit:
		return

	var current_position := global_position
	var next_position := current_position + direction * speed * delta
	if _will_hit_world(current_position, next_position):
		_consume()
		return

	global_position = next_position
	remaining_lifetime -= delta
	if remaining_lifetime <= 0.0:
		_consume()


func _will_hit_world(from_position: Vector2, to_position: Vector2) -> bool:
	var query := PhysicsRayQueryParameters2D.create(
		from_position,
		to_position,
		WORLD_COLLISION_MASK
	)
	query.collide_with_bodies = true
	query.collide_with_areas = false
	return not get_world_2d().direct_space_state.intersect_ray(query).is_empty()


func _on_body_entered(body: Node2D) -> void:
	if has_hit:
		return

	var player := body as Player
	if player != null:
		player.apply_damage(damage)
	_consume()


func _consume() -> void:
	if has_hit:
		return
	has_hit = true
	set_deferred("monitoring", false)
	queue_free()
