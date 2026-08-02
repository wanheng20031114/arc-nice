extends Node2D
class_name AgaveCannonball

signal projectile_finished(projectile_id: int, projectile: Node)

const COMPLETE_SHAPE_QUERY_2D := preload("res://scene/complete_shape_query_2d.gd")
const PROJECTILE_SHIELD_COLLISION_MASK := 1 << 12
const WORLD_AND_ENEMY_COLLISION_MASK := 5
const WORLD_ENEMY_AND_PROJECTILE_SHIELD_MASK := (
	WORLD_AND_ENEMY_COLLISION_MASK | PROJECTILE_SHIELD_COLLISION_MASK
)
const ENEMY_COLLISION_MASK := 4
const EXPLOSION_QUERY_BATCH_SIZE := 64
const COLLISION_EPSILON := 0.01

@export var speed := 180.0
@export var max_lifetime := 1.25
@export var explosion_radius := 18.0

@onready var cannonball_sprite: Sprite2D = $CannonballSprite
@onready var flight_cast: ShapeCast2D = $FlightCast
@onready var explosion_shape: CollisionShape2D = $ExplosionQueryArea/CollisionShape2D
@onready var impact_audio: AudioStreamPlayer2D = $ImpactAudio

var direction := Vector2.RIGHT
var damage := 25
var remaining_lifetime := 0.0
var has_exploded := false
var authoritative_damage := true
var damage_source_id := 0
var projectile_id := 0
var owner_peer_id := 0
var source_type: StringName = &"agave_cannonball"
var pool_active := true
var explosion_query := PhysicsShapeQueryParameters2D.new()
var explosion_targets: Dictionary[int, Enemy] = {}


func _ready() -> void:
	remaining_lifetime = maxf(max_lifetime, 0.01)
	flight_cast.collision_mask = WORLD_ENEMY_AND_PROJECTILE_SHIELD_MASK
	flight_cast.collide_with_bodies = true
	flight_cast.collide_with_areas = true
	explosion_query.collision_mask = ENEMY_COLLISION_MASK
	explosion_query.collide_with_bodies = true
	explosion_query.collide_with_areas = false
	pool_active = not has_meta(SessionObjectPool.POOL_OWNER_META)


func on_pool_acquired(_generation: int) -> void:
	pool_active = true
	explosion_targets.clear()
	has_exploded = false
	direction = Vector2.RIGHT
	damage = 25
	remaining_lifetime = maxf(max_lifetime, 0.01)
	authoritative_damage = true
	damage_source_id = 0
	projectile_id = 0
	owner_peer_id = 0
	source_type = &"agave_cannonball"
	rotation = 0.0
	flight_cast.clear_exceptions()
	flight_cast.enabled = true
	cannonball_sprite.visible = true
	impact_audio.stop()
	set_physics_process(true)


func on_pool_released(_generation: int) -> void:
	pool_active = false
	explosion_targets.clear()
	has_exploded = true
	set_physics_process(false)
	flight_cast.clear_exceptions()
	flight_cast.set_deferred("enabled", false)
	cannonball_sprite.visible = false
	impact_audio.stop()


func setup(
	initial_direction: Vector2,
	initial_damage: int = 25,
	initial_speed: float = 180.0,
	initial_explosion_radius: float = 18.0,
	initial_lifetime: float = 1.25,
	can_apply_damage: bool = true,
	initial_damage_source_id: int = 0
) -> void:
	pool_active = true
	has_exploded = false
	set_physics_process(true)
	flight_cast.clear_exceptions()
	flight_cast.enabled = true
	cannonball_sprite.visible = true
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


func setup_multiplayer(
	new_projectile_id: int,
	new_owner_peer_id: int,
	new_source_type: StringName
) -> void:
	projectile_id = maxi(new_projectile_id, 0)
	owner_peer_id = new_owner_peer_id
	source_type = new_source_type


func _physics_process(delta: float) -> void:
	if has_exploded or not pool_active:
		return

	var travel_distance := speed * maxf(delta, 0.0)
	var displacement := direction * travel_distance
	rotation = direction.angle()
	flight_cast.target_position = Vector2(travel_distance, 0.0)
	flight_cast.force_shapecast_update()

	if flight_cast.is_colliding():
		var hit := _resolve_closest_flight_hit(travel_distance)
		if hit.is_empty():
			global_position += displacement
			remaining_lifetime = maxf(remaining_lifetime - delta, 0.0)
			if remaining_lifetime <= 0.0:
				_retire()
			return
		var direct_enemy := hit.get("collider") as Enemy
		var safe_fraction := clampf(
			float(hit.get("safe_fraction", 0.0)),
			0.0,
			1.0
		)
		global_position += displacement * safe_fraction
		_explode(direct_enemy)
		return

	global_position += displacement
	remaining_lifetime = maxf(remaining_lifetime - delta, 0.0)
	if remaining_lifetime <= 0.0:
		_retire()


func _resolve_closest_flight_hit(travel_distance: float) -> Dictionary:
	var hit := _get_closest_flight_hit(travel_distance)
	if hit.is_empty():
		return {}
	var shield := hit.get("collider") as ProjectileShieldArea
	if shield == null:
		return hit
	if shield.try_intercept(direction):
		return hit

	# A shield disabled by the twentieth hit can remain in this ShapeCast result
	# until the physics server flushes. Exclude that collider and update once.
	flight_cast.add_exception(shield)
	flight_cast.force_shapecast_update()
	var retry_hit := _get_closest_flight_hit(travel_distance)
	flight_cast.remove_exception(shield)
	if retry_hit.is_empty():
		return {}
	var retry_shield := retry_hit.get("collider") as ProjectileShieldArea
	if retry_shield != null and not retry_shield.try_intercept(direction):
		return {}
	return retry_hit


func _get_closest_flight_hit(travel_distance: float) -> Dictionary:
	var closest_collider: Object = null
	var closest_position := global_position + direction * travel_distance
	var closest_forward_distance := INF
	var closest_priority := 2
	for collision_index in flight_cast.get_collision_count():
		var collision_point := flight_cast.get_collision_point(collision_index)
		var collider := flight_cast.get_collider(collision_index)
		var forward_distance := clampf(
			(collision_point - global_position).dot(direction),
			0.0,
			travel_distance
		)
		# ShapeCast returns an unordered collision set. Resolve travel order along
		# the authored flight direction, not Euclidean distance to a tangential
		# contact point. At an exact tie the shield wins over the overlapped enemy
		# body so one projectile can consume at most one shield block before its
		# original explosion contract runs.
		var priority := 0 if collider is ProjectileShieldArea else 1
		if (
			forward_distance < closest_forward_distance - COLLISION_EPSILON
			or (
				absf(forward_distance - closest_forward_distance) <= COLLISION_EPSILON
				and priority < closest_priority
			)
		):
			closest_forward_distance = forward_distance
			closest_priority = priority
			closest_collider = collider
			closest_position = collision_point
	if closest_collider == null:
		return {}
	return {
		"collider": closest_collider,
		"position": closest_position,
		"forward_distance": closest_forward_distance,
		# Capture the safe fraction from this exact ShapeCast update. A stale
		# shield retry performs another update, so callers must not re-read the
		# cast after its temporary exception has been removed.
		"safe_fraction": flight_cast.get_closest_collision_safe_fraction(),
	}


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
		_retire()


func _on_impact_audio_finished() -> void:
	if has_exploded:
		_retire()


func _retire() -> void:
	if not pool_active:
		return
	pool_active = false
	set_physics_process(false)
	projectile_finished.emit(projectile_id, self)
	if SessionObjectPool.release_to_owner(self):
		return
	queue_free()


func _apply_explosion_damage(direct_enemy: Enemy) -> void:
	explosion_targets.clear()
	if not authoritative_damage:
		return
	var blast_circle := explosion_shape.shape as CircleShape2D
	if blast_circle == null:
		return
	var space_state := get_world_2d().direct_space_state
	if space_state == null:
		return

	_add_explosion_target(explosion_targets, direct_enemy)
	explosion_query.shape = blast_circle
	explosion_query.transform = Transform2D(0.0, global_position)
	for result: Dictionary in COMPLETE_SHAPE_QUERY_2D.intersect_shape_all(
		space_state,
		explosion_query,
		EXPLOSION_QUERY_BATCH_SIZE
	):
		_add_explosion_target(explosion_targets, result.get("collider") as Enemy)

	for enemy_id in explosion_targets:
		var enemy := explosion_targets[enemy_id] as Enemy
		if enemy == null:
			continue
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
	explosion_targets.clear()


func _add_explosion_target(targets: Dictionary[int, Enemy], enemy: Enemy) -> void:
	if enemy == null or not is_instance_valid(enemy) or enemy.is_dead:
		return
	targets[enemy.get_instance_id()] = enemy
