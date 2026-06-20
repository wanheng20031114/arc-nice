extends Area2D
class_name CapooRPGRocket

const EXPLOSION_SCENE := preload("res://scene/capoo_rpg_explosion.tscn")
const WORLD_COLLISION_MASK := 1
const PLAYER_COLLISION_MASK := 2
const EXPLOSION_QUERY_MAX_RESULTS := 16

@export var speed: float = 210.0
@export var max_lifetime: float = 3.0
@export var explosion_radius: float = 44.0

@onready var animated_sprite: AnimatedSprite2D = $AnimatedSprite2D
@onready var explosion_shape: CollisionShape2D = $ExplosionShape

var direction := Vector2.RIGHT
var damage: int = 20
var remaining_lifetime: float = 0.0
var has_exploded: bool = false
var projectile_id: int = 0
var owner_peer_id: int = 0
var source_type: StringName = &"capoo_rpg_rocket"


func _ready() -> void:
	remaining_lifetime = maxf(max_lifetime, 0.01)
	_apply_explosion_radius()
	body_entered.connect(_on_body_entered)
	if animated_sprite.sprite_frames != null and animated_sprite.sprite_frames.has_animation(&"fly"):
		animated_sprite.play(&"fly")


func setup(
	initial_direction: Vector2,
	initial_damage: int,
	initial_speed: float,
	initial_lifetime: float,
	initial_explosion_radius: float = 44.0
) -> void:
	if initial_direction != Vector2.ZERO:
		direction = initial_direction.normalized()
		rotation = direction.angle()
	damage = maxi(initial_damage, 0)
	speed = maxf(initial_speed, 0.0)
	max_lifetime = maxf(initial_lifetime, 0.01)
	remaining_lifetime = max_lifetime
	explosion_radius = maxf(initial_explosion_radius, 0.0)
	_apply_explosion_radius()


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

	var current_position := global_position
	var next_position := current_position + direction * speed * delta
	var world_hit := _get_world_hit(current_position, next_position)
	if not world_hit.is_empty():
		global_position = world_hit.get("position", next_position)
		_explode()
		return

	global_position = next_position
	remaining_lifetime = maxf(remaining_lifetime - delta, 0.0)
	if remaining_lifetime <= 0.0:
		_explode()


func _get_world_hit(from_position: Vector2, to_position: Vector2) -> Dictionary:
	var query := PhysicsRayQueryParameters2D.create(
		from_position,
		to_position,
		WORLD_COLLISION_MASK,
		[get_rid()]
	)
	query.collide_with_bodies = true
	query.collide_with_areas = false
	return get_world_2d().direct_space_state.intersect_ray(query)


func _on_body_entered(_body: Node2D) -> void:
	_explode()


func _explode() -> void:
	if has_exploded:
		return
	has_exploded = true
	set_deferred("monitoring", false)
	_apply_explosion_damage()
	_spawn_explosion_effect()
	queue_free()


func _apply_explosion_damage() -> void:
	var circle_shape := explosion_shape.shape as CircleShape2D
	if circle_shape == null:
		return

	var query := PhysicsShapeQueryParameters2D.new()
	query.shape = circle_shape
	query.transform = Transform2D(0.0, global_position)
	query.collision_mask = PLAYER_COLLISION_MASK
	query.collide_with_bodies = true
	query.collide_with_areas = false
	query.exclude = [get_rid()]

	var results := get_world_2d().direct_space_state.intersect_shape(query, EXPLOSION_QUERY_MAX_RESULTS)
	var damaged_players: Dictionary = {}
	for result in results:
		var player := result.get("collider") as Player
		if player == null or player.is_dead:
			continue
		var player_id := player.get_instance_id()
		if damaged_players.has(player_id):
			continue
		damaged_players[player_id] = true
		if not _try_report_multiplayer_player_hit(player):
			player.apply_damage(damage)


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
		source_type
	))


func _apply_explosion_radius() -> void:
	if not is_node_ready():
		return
	var circle_shape := explosion_shape.shape as CircleShape2D
	if circle_shape != null:
		circle_shape.radius = maxf(explosion_radius, 0.0)
