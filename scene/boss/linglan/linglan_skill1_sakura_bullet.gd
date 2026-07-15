extends Area2D
class_name LinglanSakuraBullet

signal projectile_finished(projectile_id: int, projectile: Node)

const WORLD_COLLISION_MASK := 1
const HIT_EFFECT_SCENE := preload("res://scene/boss/linglan/linglan_sakura_hit_effect.tscn")
const WORLD_EFFECT_VISIBILITY := preload("res://scene/world_effect_visibility.gd")

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
var pool_active: bool = true
var _authored_speed: float = 300.0
var _authored_max_lifetime: float = 2.0
var _authored_damage: int = 50
var _authored_collision_layer: int = 128
var _authored_collision_mask: int = 3
var world_collision_exclude: Array[RID] = []
var world_collision_query := PhysicsRayQueryParameters2D.create(
	Vector2.ZERO,
	Vector2.ZERO,
	WORLD_COLLISION_MASK
)


func _ready() -> void:
	_authored_speed = speed
	_authored_max_lifetime = max_lifetime
	_authored_damage = damage
	_authored_collision_layer = collision_layer
	_authored_collision_mask = collision_mask
	remaining_lifetime = maxf(max_lifetime, 0.01)
	pool_active = not has_meta(SessionObjectPool.POOL_OWNER_META)
	world_collision_exclude.clear()
	world_collision_exclude.append(get_rid())
	world_collision_query.exclude = world_collision_exclude
	world_collision_query.collide_with_bodies = true
	world_collision_query.collide_with_areas = false
	if not body_entered.is_connected(_on_body_entered):
		body_entered.connect(_on_body_entered)
	if animated_sprite.sprite_frames != null and animated_sprite.sprite_frames.has_animation(&"fly"):
		animated_sprite.play(&"fly")
	if not pool_active:
		monitoring = false
		monitorable = false
		set_physics_process(false)
		if animated_sprite != null:
			animated_sprite.stop()


func on_pool_acquired(_generation: int) -> void:
	pool_active = true
	has_hit = false
	direction = Vector2.RIGHT
	damage = _authored_damage
	speed = _authored_speed
	max_lifetime = _authored_max_lifetime
	remaining_lifetime = maxf(max_lifetime, 0.01)
	projectile_id = 0
	owner_peer_id = 0
	source_type = &"linglan_skill1"
	position = Vector2.ZERO
	rotation = 0.0
	modulate = Color.WHITE
	self_modulate = Color.WHITE
	collision_layer = _authored_collision_layer
	collision_mask = _authored_collision_mask
	monitoring = true
	monitorable = true
	show()
	set_physics_process(true)
	if animated_sprite != null:
		animated_sprite.show()
		animated_sprite.modulate = Color.WHITE
		animated_sprite.self_modulate = Color.WHITE
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
	pool_active = true
	has_hit = false
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

	var player := body as Player
	if player == null:
		var collision_body := body as CollisionObject2D
		if collision_body != null and (collision_body.collision_layer & WORLD_COLLISION_MASK) != 0:
			_consume()
		return
	if not player.is_dead:
		var hit_registered := _try_report_multiplayer_player_hit(player)
		if not hit_registered:
			hit_registered = player.apply_damage(
				damage,
				EnemyConfig.DamageType.PHYSICAL,
				{
					"is_ranged": true,
					"source_direction": -direction,
				}
			)
		if hit_registered:
			_spawn_hit_effect()
	_consume()


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


func retire() -> void:
	_consume()


func _spawn_hit_effect() -> void:
	var spawn_parent := get_tree().current_scene
	if spawn_parent == null:
		return
	if not WORLD_EFFECT_VISIBILITY.is_position_near_viewport(self, global_position):
		return

	var effect: LinglanSakuraHitEffect = null
	var uses_registered_pool := (
		spawn_parent.has_method("has_session_object_pool_scene")
		and bool(spawn_parent.call("has_session_object_pool_scene", HIT_EFFECT_SCENE))
	)
	if uses_registered_pool:
		effect = spawn_parent.call(
			"acquire_session_object",
			HIT_EFFECT_SCENE,
			false
		) as LinglanSakuraHitEffect
	else:
		effect = HIT_EFFECT_SCENE.instantiate() as LinglanSakuraHitEffect
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
	if (
		source_type == &"linglan_skill1"
		and current_scene.has_method("is_client_view_runtime")
		and bool(current_scene.call("is_client_view_runtime"))
	):
		return true
	return bool(current_scene.call(
		"request_multiplayer_player_damage",
		projectile_id,
		player.peer_id,
		damage,
		source_type,
		-direction,
		true
	))
