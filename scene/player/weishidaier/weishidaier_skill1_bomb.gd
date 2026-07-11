extends Area2D
class_name WeishidaierSkill1Bomb

const EXPLOSION_SCENE := preload("res://scene/player/weishidaier/weishidaier_skill1_explosion.tscn")
const WORLD_MASK := 1
const ENEMY_BODY_MASK := 4
const PLAYER_MASK := 2
const EXPLOSION_QUERY_MAX_RESULTS := 32

@export var speed: float = 260.0
@export var max_lifetime: float = 1.4
@export var explosion_radius: float = 44.0

@onready var animated_sprite: AnimatedSprite2D = $AnimatedSprite2D
@onready var explosion_shape: CollisionShape2D = $ExplosionShape

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

	global_position += direction * speed * delta
	remaining_lifetime = maxf(remaining_lifetime - delta, 0.0)
	if remaining_lifetime <= 0.0:
		_explode()


func _on_body_entered(_body: Node2D) -> void:
	_explode()


func _on_area_entered(_area: Area2D) -> void:
	_explode()


func _explode() -> void:
	if has_exploded:
		return
	has_exploded = true
	_apply_explosion_damage()
	_spawn_explosion_effect()
	queue_free()


func _apply_explosion_damage() -> void:
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

	var results := space_state.intersect_shape(query, EXPLOSION_QUERY_MAX_RESULTS)
	var damaged_ids: Dictionary = {}
	for result in results:
		var enemy := result.get("collider") as Enemy
		if enemy == null:
			continue
		var enemy_id := enemy.get_instance_id()
		if damaged_ids.has(enemy_id):
			continue
		damaged_ids[enemy_id] = true
		if _try_report_multiplayer_enemy_hit(enemy):
			continue
		var resolved_damage := damage
		if owner_player != null and is_instance_valid(owner_player):
			resolved_damage = owner_player.resolve_attack_damage_against_enemy(damage, enemy)
		enemy.apply_damage(resolved_damage, enemy.global_position.direction_to(global_position))


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
		enemy.global_position.direction_to(global_position)
	)
	return true
