extends Area2D
class_name CapooMageFireball

const IMPACT_SCENE := preload("res://scene/enemy/capoo_mage_fireball_impact.tscn")
const WORLD_COLLISION_MASK := 1
const PLAYER_COLLISION_MASK := 2
const EXPLOSION_QUERY_MAX_RESULTS := 8

@export var speed: float = 155.0
@export var max_lifetime: float = 4.0
@export var fireball_radius: float = 10.5
@export var homing_turn_rate: float = 0.65

@onready var animated_sprite: AnimatedSprite2D = $AnimatedSprite2D
@onready var collision_shape: CollisionShape2D = $CollisionShape2D
@onready var explosion_shape: CollisionShape2D = $ExplosionShape

var direction := Vector2.RIGHT
var target_player: Player = null
var damage: int = 1
var remaining_lifetime: float = 0.0
var has_exploded: bool = false
var projectile_id: int = 0
var owner_peer_id: int = 0
var source_type: StringName = &"capoo_mage_fireball"


func _ready() -> void:
	remaining_lifetime = maxf(max_lifetime, 0.01)
	body_entered.connect(_on_body_entered)
	_apply_radius()
	if animated_sprite.sprite_frames != null and animated_sprite.sprite_frames.has_animation(&"fly"):
		animated_sprite.play(&"fly")


func setup(
	initial_direction: Vector2,
	initial_damage: int,
	initial_speed: float,
	initial_lifetime: float,
	initial_radius: float = 10.5,
	initial_target_player: Player = null,
	initial_homing_turn_rate: float = 0.65
) -> void:
	if initial_direction != Vector2.ZERO:
		direction = initial_direction.normalized()
		rotation = direction.angle()
	damage = maxi(initial_damage, 0)
	speed = maxf(initial_speed, 0.0)
	max_lifetime = maxf(initial_lifetime, 0.01)
	remaining_lifetime = max_lifetime
	fireball_radius = maxf(initial_radius, 1.0)
	target_player = initial_target_player
	homing_turn_rate = maxf(initial_homing_turn_rate, 0.0)
	_apply_radius()


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

	_update_homing(delta)
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


func _update_homing(delta: float) -> void:
	if homing_turn_rate <= 0.0:
		return
	if target_player == null or not is_instance_valid(target_player) or target_player.is_dead:
		return
	var desired_direction := global_position.direction_to(target_player.global_position)
	if desired_direction == Vector2.ZERO:
		return
	var angle_delta := direction.angle_to(desired_direction)
	var max_turn := homing_turn_rate * delta
	direction = direction.rotated(clampf(angle_delta, -max_turn, max_turn)).normalized()
	rotation = direction.angle()


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
	set_deferred("monitorable", false)
	collision_layer = 0
	collision_mask = 0
	collision_shape.set_deferred("disabled", true)
	_apply_explosion_damage()
	_spawn_impact_effect()
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


func _spawn_impact_effect() -> void:
	var spawn_parent := get_tree().current_scene
	if spawn_parent == null:
		spawn_parent = get_parent()
	if spawn_parent == null:
		return
	var impact := IMPACT_SCENE.instantiate() as Node2D
	if impact == null:
		return
	impact.top_level = true
	spawn_parent.add_child(impact)
	impact.global_position = global_position


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


func _apply_radius() -> void:
	if not is_node_ready():
		return
	var body_circle := collision_shape.shape as CircleShape2D
	if body_circle != null:
		body_circle.radius = fireball_radius
	var explosion_circle := explosion_shape.shape as CircleShape2D
	if explosion_circle != null:
		explosion_circle.radius = fireball_radius
