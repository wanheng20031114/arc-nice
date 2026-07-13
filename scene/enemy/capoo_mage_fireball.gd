extends Area2D
class_name CapooMageFireball

signal projectile_finished(projectile_id: int, projectile: Node)

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
var pool_active: bool = true
var _authored_speed: float = 155.0
var _authored_max_lifetime: float = 4.0
var _authored_radius: float = 10.5
var _authored_homing_turn_rate: float = 0.65
var _authored_collision_layer: int = 128
var _authored_collision_mask: int = 3


func _ready() -> void:
	_authored_speed = speed
	_authored_max_lifetime = max_lifetime
	_authored_radius = fireball_radius
	_authored_homing_turn_rate = homing_turn_rate
	_authored_collision_layer = collision_layer
	_authored_collision_mask = collision_mask
	remaining_lifetime = maxf(max_lifetime, 0.01)
	pool_active = not has_meta(SessionObjectPool.POOL_OWNER_META)
	body_entered.connect(_on_body_entered)
	_apply_radius()
	if animated_sprite.sprite_frames != null and animated_sprite.sprite_frames.has_animation(&"fly"):
		animated_sprite.play(&"fly")


func on_pool_acquired(_generation: int) -> void:
	pool_active = true
	has_exploded = false
	direction = Vector2.RIGHT
	target_player = null
	damage = 1
	speed = _authored_speed
	max_lifetime = _authored_max_lifetime
	fireball_radius = _authored_radius
	homing_turn_rate = _authored_homing_turn_rate
	remaining_lifetime = maxf(max_lifetime, 0.01)
	projectile_id = 0
	owner_peer_id = 0
	source_type = &"capoo_mage_fireball"
	rotation = 0.0
	collision_layer = _authored_collision_layer
	collision_mask = _authored_collision_mask
	monitoring = true
	monitorable = true
	collision_shape.disabled = false
	set_physics_process(true)
	_apply_radius()
	if animated_sprite != null:
		animated_sprite.stop()
		animated_sprite.frame = 0
		animated_sprite.frame_progress = 0.0
		if animated_sprite.sprite_frames != null and animated_sprite.sprite_frames.has_animation(&"fly"):
			animated_sprite.play(&"fly")


func on_pool_released(_generation: int) -> void:
	pool_active = false
	has_exploded = true
	target_player = null
	set_physics_process(false)
	set_deferred("monitoring", false)
	set_deferred("monitorable", false)
	collision_shape.set_deferred("disabled", true)
	if animated_sprite != null:
		animated_sprite.stop()


func setup(
	initial_direction: Vector2,
	initial_damage: int,
	initial_speed: float,
	initial_lifetime: float,
	initial_radius: float = 10.5,
	initial_target_player: Player = null,
	initial_homing_turn_rate: float = 0.65
) -> void:
	pool_active = true
	has_exploded = false
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
	if has_exploded or not pool_active:
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
	if has_exploded or not pool_active:
		return
	has_exploded = true
	set_deferred("monitoring", false)
	set_deferred("monitorable", false)
	collision_layer = 0
	collision_mask = 0
	collision_shape.set_deferred("disabled", true)
	_apply_explosion_damage()
	_spawn_impact_effect()
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
			player.apply_damage(
				damage,
				EnemyConfig.DamageType.PHYSICAL,
				_get_player_damage_context(player)
			)


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
		source_type,
		_get_source_direction_to_player(player),
		true
	))


func _get_player_damage_context(player: Player) -> Dictionary:
	return {
		"is_ranged": true,
		"source_direction": _get_source_direction_to_player(player),
	}


func _get_source_direction_to_player(player: Player) -> Vector2:
	if player == null:
		return Vector2.ZERO
	return player.global_position.direction_to(global_position)


func _apply_radius() -> void:
	if not is_node_ready():
		return
	var body_circle := collision_shape.shape as CircleShape2D
	if body_circle != null:
		body_circle.radius = fireball_radius
	var explosion_circle := explosion_shape.shape as CircleShape2D
	if explosion_circle != null:
		explosion_circle.radius = fireball_radius
