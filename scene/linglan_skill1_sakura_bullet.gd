extends Area2D
class_name LinglanSakuraBullet

const WORLD_COLLISION_MASK := 1
const HIT_EFFECT_SCENE := preload("res://scene/linglan_sakura_hit_effect.tscn")

@export var speed: float = 300.0
@export var max_lifetime: float = 2.0

@onready var animated_sprite: AnimatedSprite2D = $AnimatedSprite2D

var direction := Vector2.RIGHT
var damage: int = 50
var remaining_lifetime: float = 0.0
var has_hit: bool = false
var projectile_id: int = 0
var owner_peer_id: int = 0
var source_type: StringName = &"linglan_skill1"


func _ready() -> void:
	remaining_lifetime = maxf(max_lifetime, 0.01)
	body_entered.connect(_on_body_entered)
	if animated_sprite.sprite_frames != null and animated_sprite.sprite_frames.has_animation(&"fly"):
		animated_sprite.play(&"fly")


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

	var player := body as Player
	if player == null:
		var collision_body := body as CollisionObject2D
		if collision_body != null and (collision_body.collision_layer & WORLD_COLLISION_MASK) != 0:
			_consume()
		return
	if not player.is_dead:
		var hit_registered := _try_report_multiplayer_player_hit(player)
		if not hit_registered:
			hit_registered = player.apply_damage(damage)
		if hit_registered:
			_spawn_hit_effect()
	_consume()


func _consume() -> void:
	if has_hit:
		return
	has_hit = true
	set_deferred("monitoring", false)
	set_deferred("monitorable", false)
	queue_free()


func _spawn_hit_effect() -> void:
	var spawn_parent := get_tree().current_scene
	if spawn_parent == null:
		return

	var effect := HIT_EFFECT_SCENE.instantiate() as LinglanSakuraHitEffect
	if effect == null:
		return

	effect.top_level = true
	effect.setup(direction)
	spawn_parent.add_child(effect)
	effect.global_position = global_position


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
