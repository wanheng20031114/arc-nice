extends Area2D
class_name CapooAK47Bullet

signal projectile_finished(projectile_id: int, projectile: Node)

const WORLD_COLLISION_MASK := 1
const DAMAGEABLE_COLLISION_MASK := 2 | 512
const HIT_EFFECT_SCENE := preload("res://scene/bullet_hit_effect.tscn")

@export var speed: float = 142.5
@export var max_lifetime: float = 2.0

@onready var animated_sprite: AnimatedSprite2D = $AnimatedSprite2D

var direction := Vector2.RIGHT
var damage: int = 1
var remaining_lifetime: float = 0.0
var has_hit: bool = false
var projectile_id: int = 0
var owner_peer_id: int = 0
var source_type: StringName = &"capoo_ak47_bullet"
var pool_active: bool = true
var _authored_speed: float = 142.5
var _authored_max_lifetime: float = 2.0
var _authored_collision_layer: int = 128
var _authored_collision_mask: int = DAMAGEABLE_COLLISION_MASK
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
	world_collision_query.collide_with_bodies = true
	world_collision_query.collide_with_areas = false
	body_entered.connect(_on_body_entered)
	if animated_sprite.sprite_frames != null and animated_sprite.sprite_frames.has_animation(&"fly"):
		animated_sprite.play(&"fly")


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
	source_type = &"capoo_ak47_bullet"
	rotation = 0.0
	collision_layer = _authored_collision_layer
	collision_mask = _authored_collision_mask
	monitoring = true
	monitorable = true
	set_physics_process(true)
	if animated_sprite != null:
		animated_sprite.stop()
		animated_sprite.frame = 0
		animated_sprite.frame_progress = 0.0
		if animated_sprite.sprite_frames != null and animated_sprite.sprite_frames.has_animation(&"fly"):
			animated_sprite.play(&"fly")


func on_pool_released(_generation: int) -> void:
	pool_active = false
	has_hit = true
	set_physics_process(false)
	set_deferred("monitoring", false)
	set_deferred("monitorable", false)
	if animated_sprite != null:
		animated_sprite.stop()


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
		_consume(true)
		return

	global_position = next_position
	remaining_lifetime -= delta
	if remaining_lifetime <= 0.0:
		_consume(false)


func _will_hit_world(from_position: Vector2, to_position: Vector2) -> bool:
	world_collision_query.from = from_position
	world_collision_query.to = to_position
	return not get_world_2d().direct_space_state.intersect_ray(
		world_collision_query
	).is_empty()


func _on_body_entered(body: Node2D) -> void:
	if has_hit or not pool_active:
		return

	var player := body as Player
	if player != null:
		if not _try_report_multiplayer_player_hit(player):
			player.apply_damage(
				damage,
				EnemyConfig.DamageType.PHYSICAL,
				_get_player_damage_context()
			)
	else:
		var plant := body as PlantDefense
		if plant != null and not plant.is_dead:
			plant.receive_damage(
				damage,
				self,
				direction,
				EnemyConfig.DamageType.PHYSICAL
			)
	_consume(true)


func _consume(play_hit_effect: bool = true) -> void:
	if has_hit or not pool_active:
		return
	has_hit = true
	pool_active = false
	set_physics_process(false)
	set_deferred("monitoring", false)
	set_deferred("monitorable", false)
	if play_hit_effect:
		_spawn_hit_effect()
	projectile_finished.emit(projectile_id, self)
	if SessionObjectPool.release_to_owner(self):
		return
	queue_free()


func retire(play_hit_effect: bool = false) -> void:
	_consume(play_hit_effect)


func _spawn_hit_effect() -> void:
	var spawn_parent := get_tree().current_scene
	if spawn_parent == null:
		return

	var effect: BulletHitEffect = null
	var uses_registered_pool := (
		spawn_parent.has_method("has_session_object_pool_scene")
		and bool(spawn_parent.call("has_session_object_pool_scene", HIT_EFFECT_SCENE))
	)
	if uses_registered_pool:
		effect = spawn_parent.call(
			"acquire_session_object",
			HIT_EFFECT_SCENE,
			true
		) as BulletHitEffect
	else:
		effect = HIT_EFFECT_SCENE.instantiate() as BulletHitEffect
	if effect == null:
		return

	effect.top_level = true
	if effect.get_parent() == null:
		spawn_parent.add_child(effect)
	effect.global_position = global_position
	effect.reset_physics_interpolation()
	effect.setup(direction)


func _try_report_multiplayer_player_hit(player: Player) -> bool:
	if projectile_id <= 0:
		return false
	var current_scene := get_tree().current_scene
	if current_scene == null or not current_scene.has_method("request_multiplayer_player_damage"):
		return false
	return bool(current_scene.call(
		"request_multiplayer_player_damage",
		projectile_id,
		player.peer_id,
		damage,
		source_type,
		-direction,
		true
	))


func _get_player_damage_context() -> Dictionary:
	return {
		"is_ranged": true,
		"source_direction": -direction,
	}
