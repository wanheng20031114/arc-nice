extends Area2D
class_name CollectibleArrowProjectile

const WORLD_COLLISION_MASK := 1

@export var speed: float = 360.0
@export var max_lifetime: float = 1.8

var direction := Vector2.RIGHT
var damage: int = 1
var remaining_lifetime: float = 0.0
var projectile_id: int = 0
var owner_peer_id: int = 0
var source_type: StringName = &"collectible_arrow"
var has_hit: bool = false


func _ready() -> void:
	remaining_lifetime = maxf(max_lifetime, 0.01)


func setup(initial_direction: Vector2, initial_damage: int = 1) -> void:
	if initial_direction != Vector2.ZERO:
		direction = initial_direction.normalized()
		rotation = direction.angle()
	damage = maxi(initial_damage, 0)
	remaining_lifetime = maxf(max_lifetime, 0.01)


func setup_multiplayer(
	new_projectile_id: int,
	new_owner_peer_id: int,
	new_source_type: StringName
) -> void:
	projectile_id = maxi(new_projectile_id, 0)
	owner_peer_id = new_owner_peer_id
	source_type = new_source_type


func _physics_process(delta: float) -> void:
	if has_hit:
		return
	var current_position := global_position
	var next_position := current_position + direction * speed * delta
	if _will_hit_world(current_position, next_position):
		_consume()
		return
	global_position = next_position
	remaining_lifetime = maxf(remaining_lifetime - delta, 0.0)
	if remaining_lifetime <= 0.0:
		_consume()


func _will_hit_world(from_position: Vector2, to_position: Vector2) -> bool:
	var query := PhysicsRayQueryParameters2D.create(
		from_position,
		to_position,
		WORLD_COLLISION_MASK,
		[get_rid()]
	)
	query.collide_with_bodies = true
	query.collide_with_areas = false
	return not get_world_2d().direct_space_state.intersect_ray(query).is_empty()


func _on_body_entered(body: Node2D) -> void:
	if has_hit:
		return
	var enemy := body as Enemy
	if enemy != null:
		var hit_registered := _try_report_multiplayer_enemy_hit(enemy)
		if not hit_registered:
			hit_registered = enemy.apply_damage(damage, -direction, EnemyConfig.DamageType.PHYSICAL)
		if hit_registered:
			_consume()
		return
	_consume()


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


func _consume() -> void:
	if has_hit:
		return
	has_hit = true
	set_deferred("monitoring", false)
	queue_free()
