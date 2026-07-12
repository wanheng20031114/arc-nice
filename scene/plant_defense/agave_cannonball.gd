extends Node2D
class_name AgaveCannonball

const WORLD_AND_ENEMY_COLLISION_MASK := 5
const ENEMY_COLLISION_MASK := 4
const EXPLOSION_QUERY_MAX_RESULTS := 128

@export var speed := 180.0
@export var max_lifetime := 1.25
@export var explosion_radius := 18.0

@onready var cannonball_sprite: Sprite2D = $CannonballSprite
@onready var flight_cast: ShapeCast2D = $FlightCast
@onready var explosion_shape: CollisionShape2D = $ExplosionQueryArea/CollisionShape2D
@onready var impact_audio: AudioStreamPlayer2D = $ImpactAudio

var direction := Vector2.RIGHT
var damage := 50
var remaining_lifetime := 0.0
var has_exploded := false
var authoritative_damage := true
var damage_source_id := 0


func _ready() -> void:
	remaining_lifetime = maxf(max_lifetime, 0.01)
	flight_cast.collision_mask = WORLD_AND_ENEMY_COLLISION_MASK


func setup(
	initial_direction: Vector2,
	initial_damage: int = 50,
	initial_speed: float = 180.0,
	initial_explosion_radius: float = 18.0,
	initial_lifetime: float = 1.25,
	can_apply_damage: bool = true,
	initial_damage_source_id: int = 0
) -> void:
	if initial_direction != Vector2.ZERO:
		direction = initial_direction.normalized()
	rotation = direction.angle()
	damage = maxi(initial_damage, 0)
	speed = maxf(initial_speed, 0.0)
	explosion_radius = maxf(initial_explosion_radius, 1.0)
	max_lifetime = maxf(initial_lifetime, 0.01)
	remaining_lifetime = max_lifetime
	authoritative_damage = can_apply_damage
	damage_source_id = maxi(initial_damage_source_id, 0)

	var blast_circle := explosion_shape.shape as CircleShape2D
	if blast_circle != null:
		blast_circle.radius = explosion_radius


func _physics_process(delta: float) -> void:
	if has_exploded:
		return

	var travel_distance := speed * maxf(delta, 0.0)
	var displacement := direction * travel_distance
	rotation = direction.angle()
	flight_cast.target_position = Vector2(travel_distance, 0.0)
	flight_cast.force_shapecast_update()

	if flight_cast.is_colliding():
		var direct_enemy := _get_closest_collision_enemy()
		var safe_fraction := clampf(
			flight_cast.get_closest_collision_safe_fraction(),
			0.0,
			1.0
		)
		global_position += displacement * safe_fraction
		_explode(direct_enemy)
		return

	global_position += displacement
	remaining_lifetime = maxf(remaining_lifetime - delta, 0.0)
	if remaining_lifetime <= 0.0:
		queue_free()


func _get_closest_collision_enemy() -> Enemy:
	var closest_collider: Object = null
	var closest_distance_squared := INF
	for collision_index in flight_cast.get_collision_count():
		var collision_point := flight_cast.get_collision_point(collision_index)
		var distance_squared := global_position.distance_squared_to(collision_point)
		if distance_squared < closest_distance_squared:
			closest_distance_squared = distance_squared
			closest_collider = flight_cast.get_collider(collision_index)
	return closest_collider as Enemy


func _explode(direct_enemy: Enemy = null) -> void:
	if has_exploded:
		return
	has_exploded = true
	set_physics_process(false)
	flight_cast.enabled = false
	cannonball_sprite.visible = false
	_apply_explosion_damage(direct_enemy)
	if impact_audio.stream != null:
		impact_audio.play()
	else:
		queue_free()


func _on_impact_audio_finished() -> void:
	if has_exploded:
		queue_free()


func _apply_explosion_damage(direct_enemy: Enemy) -> void:
	if not authoritative_damage:
		return
	var blast_circle := explosion_shape.shape as CircleShape2D
	if blast_circle == null:
		return
	var space_state := get_world_2d().direct_space_state
	if space_state == null:
		return

	var targets: Dictionary[int, Enemy] = {}
	_add_explosion_target(targets, direct_enemy)

	var query := PhysicsShapeQueryParameters2D.new()
	query.shape = blast_circle
	query.transform = Transform2D(0.0, global_position)
	query.collision_mask = ENEMY_COLLISION_MASK
	query.collide_with_bodies = true
	query.collide_with_areas = false
	for result: Dictionary in space_state.intersect_shape(query, EXPLOSION_QUERY_MAX_RESULTS):
		_add_explosion_target(targets, result.get("collider") as Enemy)

	for enemy: Enemy in targets.values():
		var impact_direction := global_position.direction_to(enemy.global_position)
		if impact_direction == Vector2.ZERO:
			impact_direction = direction
		var current_scene := get_tree().current_scene
		if current_scene != null and current_scene.has_method(
			"apply_authoritative_plant_enemy_damage"
		):
			current_scene.call(
				"apply_authoritative_plant_enemy_damage",
				damage_source_id,
				enemy,
				damage,
				impact_direction,
				EnemyConfig.DamageType.PHYSICAL
			)
		else:
			enemy.apply_damage(
				damage,
				impact_direction,
				EnemyConfig.DamageType.PHYSICAL
			)


func _add_explosion_target(targets: Dictionary[int, Enemy], enemy: Enemy) -> void:
	if enemy == null or not is_instance_valid(enemy) or enemy.is_dead:
		return
	targets[enemy.get_instance_id()] = enemy
