extends Area2D
class_name CollectibleArrowProjectile

signal projectile_finished(projectile_id: int, projectile: Node)

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
var pool_active: bool = true
var _authored_speed: float = 360.0
var _authored_max_lifetime: float = 1.8
var _authored_collision_layer: int = 16
var _authored_collision_mask: int = 5
var world_collision_exclude: Array[RID] = []
var world_collision_query := PhysicsRayQueryParameters2D.create(
	Vector2.ZERO,
	Vector2.ZERO,
	WORLD_COLLISION_MASK
)


func _ready() -> void:
	_authored_speed = speed
	_authored_max_lifetime = max_lifetime
	_authored_collision_layer = collision_layer
	_authored_collision_mask = collision_mask
	remaining_lifetime = maxf(max_lifetime, 0.01)
	pool_active = not has_meta(SessionObjectPool.POOL_OWNER_META)
	world_collision_exclude.append(get_rid())
	world_collision_query.exclude = world_collision_exclude
	world_collision_query.collide_with_bodies = true
	world_collision_query.collide_with_areas = false


func on_pool_acquired(_generation: int) -> void:
	pool_active = true
	has_hit = false
	direction = Vector2.RIGHT
	damage = 1
	speed = _authored_speed
	max_lifetime = _authored_max_lifetime
	remaining_lifetime = maxf(max_lifetime, 0.01)
	projectile_id = 0
	owner_peer_id = 0
	source_type = &"collectible_arrow"
	rotation = 0.0
	collision_layer = _authored_collision_layer
	collision_mask = _authored_collision_mask
	monitoring = true
	monitorable = true
	set_physics_process(true)


func on_pool_released(_generation: int) -> void:
	pool_active = false
	has_hit = true
	set_physics_process(false)
	set_deferred("monitoring", false)
	set_deferred("monitorable", false)


func setup(initial_direction: Vector2, initial_damage: int = 1) -> void:
	pool_active = true
	has_hit = false
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
	if has_hit or not pool_active:
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
	world_collision_query.from = from_position
	world_collision_query.to = to_position
	return not get_world_2d().direct_space_state.intersect_ray(world_collision_query).is_empty()


func _on_body_entered(body: Node2D) -> void:
	if has_hit or not pool_active:
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
	if has_hit or not pool_active:
		return
	has_hit = true
	pool_active = false
	set_physics_process(false)
	set_deferred("monitoring", false)
	set_deferred("monitorable", false)
	projectile_finished.emit(projectile_id, self)
	if SessionObjectPool.release_to_owner(self):
		return
	queue_free()
