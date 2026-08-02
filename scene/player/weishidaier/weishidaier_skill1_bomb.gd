extends Area2D
class_name WeishidaierSkill1Bomb

const EXPLOSION_SCENE := preload("res://scene/player/weishidaier/weishidaier_skill1_explosion.tscn")
const COMPLETE_SHAPE_QUERY_2D := preload("res://scene/complete_shape_query_2d.gd")
const WORLD_MASK := 1
const ENEMY_BODY_MASK := 4
const PLAYER_MASK := 2
const PROJECTILE_SHIELD_MASK := 1 << 12
const EXPLOSION_QUERY_PAGE_SIZE := 32
const COLLISION_EPSILON := 0.01

@export var speed: float = 260.0
@export var max_lifetime: float = 1.4
@export var explosion_radius: float = 44.0

@onready var animated_sprite: AnimatedSprite2D = $AnimatedSprite2D
@onready var explosion_shape: CollisionShape2D = $ExplosionShape
@onready var shield_sweep: ShapeCast2D = $ShieldSweep

var direction: Vector2 = Vector2.RIGHT
var damage: int = 1
var remaining_lifetime: float = 0.0
var owner_player: Player = null
var has_exploded: bool = false
var projectile_id: int = 0
var owner_peer_id: int = 0
var source_type: StringName = &"skill1_bomb"


func _ready() -> void:
	remaining_lifetime = max_lifetime
	body_entered.connect(_on_body_entered)
	area_entered.connect(_on_area_entered)
	var circle_shape := explosion_shape.shape as CircleShape2D
	if circle_shape != null:
		circle_shape.radius = explosion_radius


func setup(initial_owner: Player, initial_direction: Vector2, initial_damage: int) -> void:
	owner_player = initial_owner
	if initial_direction != Vector2.ZERO:
		direction = initial_direction.normalized()
	rotation = direction.angle()
	damage = maxi(initial_damage, 0)


func setup_multiplayer(
	new_projectile_id: int,
	new_owner_peer_id: int,
	new_source_type: StringName
) -> void:
	projectile_id = maxi(new_projectile_id, 0)
	owner_peer_id = new_owner_peer_id
	source_type = new_source_type


func _physics_process(delta: float) -> void:
	if has_exploded:
		return

	var travel_distance := maxf(speed, 0.0) * maxf(delta, 0.0)
	var displacement := direction * travel_distance
	if travel_distance > COLLISION_EPSILON and _sweep_projectile_shield(travel_distance):
		return
	global_position += displacement
	remaining_lifetime = maxf(remaining_lifetime - delta, 0.0)
	if remaining_lifetime <= 0.0:
		_explode()


func _sweep_projectile_shield(travel_distance: float) -> bool:
	shield_sweep.target_position = Vector2(travel_distance, 0.0)
	shield_sweep.force_shapecast_update()
	var hit := _get_closest_shield_hit(travel_distance)
	if hit.is_empty():
		return false
	var shield := hit.get("collider") as ProjectileShieldArea
	if shield != null and shield.try_intercept(direction):
		_move_to_shield_impact(travel_distance)
		_explode()
		return true
	if shield == null:
		return false

	# The twentieth block can leave one stale physics result in this frame.
	# Exclude only that RID and repeat this authored sweep once.
	shield_sweep.add_exception(shield)
	shield_sweep.force_shapecast_update()
	var retry_hit := _get_closest_shield_hit(travel_distance)
	shield_sweep.remove_exception(shield)
	if retry_hit.is_empty():
		return false
	var retry_shield := retry_hit.get("collider") as ProjectileShieldArea
	if retry_shield == null or not retry_shield.try_intercept(direction):
		return false
	_move_to_shield_impact(travel_distance)
	_explode()
	return true


func _get_closest_shield_hit(travel_distance: float) -> Dictionary:
	var closest: Dictionary = {}
	var closest_distance := travel_distance
	for collision_index in range(shield_sweep.get_collision_count()):
		var collider := shield_sweep.get_collider(collision_index)
		if not (collider is ProjectileShieldArea):
			continue
		var collision_point := shield_sweep.get_collision_point(collision_index)
		var forward_distance := clampf(
			(collision_point - global_position).dot(direction),
			0.0,
			travel_distance
		)
		if closest.is_empty() or forward_distance < closest_distance:
			closest_distance = forward_distance
			closest = {
				"collider": collider,
				"position": collision_point,
				"distance": forward_distance,
			}
	return closest


func _move_to_shield_impact(travel_distance: float) -> void:
	var safe_fraction := clampf(
		shield_sweep.get_closest_collision_safe_fraction(),
		0.0,
		1.0
	)
	global_position += direction * maxf(
		travel_distance * safe_fraction - COLLISION_EPSILON,
		0.0
	)


func _on_body_entered(body: Node2D) -> void:
	_explode(body as Enemy)


func _on_area_entered(_area: Area2D) -> void:
	_explode()


func _explode(direct_enemy: Enemy = null) -> void:
	if has_exploded:
		return
	has_exploded = true
	_apply_explosion_damage(direct_enemy)
	_spawn_explosion_effect()
	queue_free()


func _apply_explosion_damage(direct_enemy: Enemy = null) -> void:
	if not _can_apply_authoritative_damage():
		return

	var circle_shape := explosion_shape.shape as CircleShape2D
	if circle_shape == null:
		return

	var space_state := get_world_2d().direct_space_state
	if space_state == null:
		return

	var query := PhysicsShapeQueryParameters2D.new()
	query.shape = circle_shape
	query.transform = Transform2D(0.0, global_position)
	query.collision_mask = ENEMY_BODY_MASK
	query.collide_with_bodies = true
	query.collide_with_areas = false
	query.exclude = [get_rid()]

	var damaged_ids: Dictionary = {}
	_apply_damage_to_enemy(direct_enemy, damaged_ids)
	var results := COMPLETE_SHAPE_QUERY_2D.intersect_shape_all(
		space_state,
		query,
		EXPLOSION_QUERY_PAGE_SIZE
	)
	for result: Dictionary in results:
		_apply_damage_to_enemy(result.get("collider") as Enemy, damaged_ids)


func _can_apply_authoritative_damage() -> bool:
	var current_scene := get_tree().current_scene
	return not (
		current_scene != null
		and current_scene.has_method("is_client_view_runtime")
		and bool(current_scene.call("is_client_view_runtime"))
	)


func _apply_damage_to_enemy(enemy: Enemy, damaged_ids: Dictionary) -> void:
	if enemy == null or not is_instance_valid(enemy):
		return
	var enemy_id := enemy.get_instance_id()
	if damaged_ids.has(enemy_id):
		return
	damaged_ids[enemy_id] = true
	var resolved_damage := damage
	if owner_player != null and is_instance_valid(owner_player):
		resolved_damage = owner_player.resolve_attack_damage_against_enemy(damage, enemy)
	var impact_direction := enemy.global_position.direction_to(global_position)
	var current_scene := get_tree().current_scene
	if (
		current_scene != null
		and current_scene.has_method("apply_multiplayer_collectible_enemy_damage")
	):
		current_scene.call(
			"apply_multiplayer_collectible_enemy_damage",
			enemy,
			resolved_damage,
			impact_direction,
			EnemyConfig.DamageType.PHYSICAL,
			true
		)
		_apply_research_burn(enemy)
		return
	enemy.apply_damage(
		resolved_damage,
		impact_direction,
		EnemyConfig.DamageType.PHYSICAL
	)
	_apply_research_burn(enemy)


func _apply_research_burn(enemy: Enemy) -> void:
	if (
		enemy == null
		or not is_instance_valid(enemy)
		or enemy.is_dead
		or owner_player == null
		or not is_instance_valid(owner_player)
	):
		return
	var burn_damage := owner_player.get_research_burn_tick_damage()
	if burn_damage <= 0:
		return
	enemy.apply_collectible_status(
		&"burn",
		maxi(int(get_instance_id()), 1),
		5.0,
		burn_damage,
		0.5,
		EnemyConfig.DamageType.MAGIC
	)


func _spawn_explosion_effect() -> void:
	var spawn_parent := get_tree().current_scene
	if spawn_parent == null:
		spawn_parent = get_parent()
	if spawn_parent == null:
		return

	var explosion := EXPLOSION_SCENE.instantiate() as Node2D
	if explosion == null:
		return
	explosion.top_level = true
	spawn_parent.add_child(explosion)
	explosion.global_position = global_position
