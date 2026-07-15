extends Area2D
class_name LinglanSkill2SakuraRocket

signal projectile_finished(projectile_id: int, projectile: Node)

const COMPLETE_SHAPE_QUERY_2D := preload("res://scene/complete_shape_query_2d.gd")
const WORLD_COLLISION_MASK := 1
const PLAYER_COLLISION_MASK := 2
const ENEMY_BODY_COLLISION_MASK := 4
const BOSS_BODY_COLLISION_MASK := 256
const WEISHIDAIER_SKILL1_EXPLOSION_RADIUS := 44.0
const COLLECTIBLE_SAKURA_EXPLOSION_RADIUS := WEISHIDAIER_SKILL1_EXPLOSION_RADIUS + 3.0
const HIT_COLLISION_MASK := (
	WORLD_COLLISION_MASK
	| PLAYER_COLLISION_MASK
	| ENEMY_BODY_COLLISION_MASK
	| BOSS_BODY_COLLISION_MASK
)
const EXPLOSION_DAMAGE_MASK := (
	PLAYER_COLLISION_MASK
	| ENEMY_BODY_COLLISION_MASK
	| BOSS_BODY_COLLISION_MASK
)
const ENEMY_ONLY_HIT_COLLISION_MASK := (
	WORLD_COLLISION_MASK
	| ENEMY_BODY_COLLISION_MASK
	| BOSS_BODY_COLLISION_MASK
)
const ENEMY_ONLY_EXPLOSION_DAMAGE_MASK := (
	ENEMY_BODY_COLLISION_MASK
	| BOSS_BODY_COLLISION_MASK
)
const EXPLOSION_QUERY_BATCH_SIZE := 64

@export var speed: float = 210.0
@export var max_lifetime: float = 5.0
@export var explosion_radius: float = 78.0
@export var homing_turn_rate: float = 1.2
@export var explosion_scene: PackedScene
@export_range(0.0, 10.0, 0.05, "or_greater") var flash_lead_time: float = 1.2
@export_range(1.0, 30.0, 0.1, "or_greater") var flash_frequency: float = 9.0

@onready var animated_sprite: AnimatedSprite2D = $AnimatedSprite2D
@onready var collision_shape: CollisionShape2D = $CollisionShape2D
@onready var explosion_shape: CollisionShape2D = $ExplosionShape

var direction := Vector2.RIGHT
var target_player: Player = null
var target_node: Node2D = null
var damage: int = 80
var damage_type: EnemyConfig.DamageType = EnemyConfig.DamageType.PHYSICAL
var remaining_lifetime: float = 0.0
var has_exploded: bool = false
var enemies_only: bool = false
var projectile_id: int = 0
var owner_peer_id: int = 0
var source_type: StringName = &"linglan_skill2_rocket"
var base_sprite_modulate: Color = Color.WHITE
var pool_active := true
var _authored_speed := 210.0
var _authored_max_lifetime := 5.0
var _authored_explosion_radius := 78.0
var _authored_homing_turn_rate := 1.2
var _authored_collision_layer := 128
var _authored_collision_mask := HIT_COLLISION_MASK
var hit_collision_exclude: Array[RID] = []
var hit_collision_query := PhysicsRayQueryParameters2D.create(
	Vector2.ZERO,
	Vector2.ZERO,
	HIT_COLLISION_MASK
)
var explosion_query := PhysicsShapeQueryParameters2D.new()
var explosion_damaged_ids: Dictionary = {}


func _ready() -> void:
	_authored_speed = speed
	_authored_max_lifetime = max_lifetime
	_authored_explosion_radius = explosion_radius
	_authored_homing_turn_rate = homing_turn_rate
	_authored_collision_layer = collision_layer
	_authored_collision_mask = collision_mask
	remaining_lifetime = maxf(max_lifetime, 0.01)
	hit_collision_exclude.append(get_rid())
	hit_collision_query.exclude = hit_collision_exclude
	hit_collision_query.collide_with_bodies = true
	hit_collision_query.collide_with_areas = false
	explosion_query.collide_with_bodies = true
	explosion_query.collide_with_areas = false
	explosion_query.exclude = hit_collision_exclude
	body_entered.connect(_on_body_entered)
	_apply_collision_masks()
	_apply_explosion_radius()
	base_sprite_modulate = animated_sprite.modulate
	if animated_sprite.sprite_frames != null and animated_sprite.sprite_frames.has_animation(&"fly"):
		animated_sprite.play(&"fly")
	_update_flash_visual()
	pool_active = not has_meta(SessionObjectPool.POOL_OWNER_META)


func on_pool_acquired(_generation: int) -> void:
	pool_active = true
	has_exploded = false
	direction = Vector2.RIGHT
	target_player = null
	target_node = null
	damage = 80
	damage_type = EnemyConfig.DamageType.PHYSICAL
	speed = _authored_speed
	max_lifetime = _authored_max_lifetime
	explosion_radius = _authored_explosion_radius
	homing_turn_rate = _authored_homing_turn_rate
	remaining_lifetime = maxf(max_lifetime, 0.01)
	enemies_only = false
	projectile_id = 0
	owner_peer_id = 0
	source_type = &"linglan_skill2_rocket"
	explosion_damaged_ids.clear()
	rotation = 0.0
	collision_layer = _authored_collision_layer
	collision_mask = _authored_collision_mask
	monitoring = true
	monitorable = true
	if collision_shape != null:
		collision_shape.disabled = false
	if animated_sprite != null:
		animated_sprite.modulate = base_sprite_modulate
		animated_sprite.stop()
		animated_sprite.frame = 0
		animated_sprite.frame_progress = 0.0
		if animated_sprite.sprite_frames != null and animated_sprite.sprite_frames.has_animation(&"fly"):
			animated_sprite.play(&"fly")
	_apply_collision_masks()
	_apply_explosion_radius()
	set_physics_process(true)


func on_pool_released(_generation: int) -> void:
	pool_active = false
	has_exploded = true
	target_player = null
	target_node = null
	explosion_damaged_ids.clear()
	set_physics_process(false)
	set_deferred("monitoring", false)
	set_deferred("monitorable", false)
	if collision_shape != null:
		collision_shape.set_deferred("disabled", true)
	if animated_sprite != null:
		animated_sprite.modulate = base_sprite_modulate
		animated_sprite.stop()


func setup(
	initial_direction: Vector2,
	initial_damage: int,
	initial_speed: float,
	initial_lifetime: float,
	initial_explosion_radius: float = 78.0,
	initial_target_player: Player = null,
	initial_homing_turn_rate: float = 1.2,
	initial_target_node: Node2D = null,
	initial_enemies_only: bool = false,
	initial_damage_type: EnemyConfig.DamageType = EnemyConfig.DamageType.PHYSICAL
) -> void:
	pool_active = true
	has_exploded = false
	set_physics_process(true)
	if initial_direction != Vector2.ZERO:
		direction = initial_direction.normalized()
		rotation = direction.angle()
	damage = maxi(initial_damage, 0)
	speed = maxf(initial_speed, 0.0)
	max_lifetime = maxf(initial_lifetime, 0.01)
	remaining_lifetime = max_lifetime
	explosion_radius = maxf(initial_explosion_radius, 0.0)
	target_player = initial_target_player
	if initial_target_node != null:
		target_node = initial_target_node
	else:
		target_node = initial_target_player
	homing_turn_rate = maxf(initial_homing_turn_rate, 0.0)
	enemies_only = initial_enemies_only
	damage_type = initial_damage_type
	_apply_collision_masks()
	_apply_explosion_radius()
	if is_node_ready():
		_update_flash_visual()


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
	var hit := _get_hit(current_position, next_position)
	if not hit.is_empty():
		global_position = hit.get("position", next_position)
		_explode(hit.get("collider") as Node2D)
		return

	global_position = next_position
	remaining_lifetime = maxf(remaining_lifetime - delta, 0.0)
	if remaining_lifetime <= 0.0:
		_explode()
		return
	_update_flash_visual()


func _update_homing(delta: float) -> void:
	if homing_turn_rate <= 0.0:
		return
	if not _is_homing_target_valid():
		return
	var desired_direction := global_position.direction_to(target_node.global_position)
	if desired_direction == Vector2.ZERO:
		return
	var angle_delta := direction.angle_to(desired_direction)
	var max_turn := homing_turn_rate * delta
	direction = direction.rotated(clampf(angle_delta, -max_turn, max_turn)).normalized()
	rotation = direction.angle()


func _get_hit(from_position: Vector2, to_position: Vector2) -> Dictionary:
	hit_collision_query.from = from_position
	hit_collision_query.to = to_position
	hit_collision_query.collision_mask = _get_hit_collision_mask()
	return get_world_2d().direct_space_state.intersect_ray(hit_collision_query)


func _on_body_entered(body: Node2D) -> void:
	_explode(body)


func _explode(direct_hit: Node2D = null) -> void:
	if has_exploded or not pool_active:
		return
	has_exploded = true
	set_deferred("monitoring", false)
	set_deferred("monitorable", false)
	collision_layer = 0
	collision_mask = 0
	if collision_shape != null:
		collision_shape.set_deferred("disabled", true)
	animated_sprite.modulate = base_sprite_modulate
	_apply_explosion_damage(direct_hit)
	_spawn_explosion_effect()
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


func _update_flash_visual() -> void:
	if animated_sprite == null:
		return
	var lead_time := maxf(flash_lead_time, 0.0)
	if lead_time <= 0.0 or remaining_lifetime > lead_time:
		animated_sprite.modulate = base_sprite_modulate
		return
	var flash_elapsed := lead_time - remaining_lifetime
	var wave := (sin(flash_elapsed * TAU * maxf(flash_frequency, 1.0)) + 1.0) * 0.5
	var next_modulate := base_sprite_modulate
	next_modulate.a *= lerpf(0.25, 1.0, wave)
	animated_sprite.modulate = next_modulate


func _apply_explosion_damage(direct_hit: Node2D = null) -> void:
	var circle_shape := explosion_shape.shape as CircleShape2D
	if circle_shape == null:
		return

	explosion_query.shape = circle_shape
	explosion_query.transform = Transform2D(0.0, global_position)
	explosion_query.collision_mask = _get_explosion_damage_mask()
	explosion_damaged_ids.clear()
	_apply_explosion_damage_to_collider(direct_hit, explosion_damaged_ids)
	var results := COMPLETE_SHAPE_QUERY_2D.intersect_shape_all(
		get_world_2d().direct_space_state,
		explosion_query,
		EXPLOSION_QUERY_BATCH_SIZE
	)
	for result in results:
		var collider := result.get("collider") as Node2D
		_apply_explosion_damage_to_collider(collider, explosion_damaged_ids)


func _apply_explosion_damage_to_collider(collider: Node2D, damaged_ids: Dictionary) -> void:
	if collider == null or not is_instance_valid(collider):
		return
	var collider_id := collider.get_instance_id()
	if damaged_ids.has(collider_id):
		return
	var player := collider as Player
	if player != null:
		damaged_ids[collider_id] = true
		if not enemies_only:
			_apply_player_damage(player)
		return
	var enemy := collider as Enemy
	if enemy == null:
		return
	damaged_ids[collider_id] = true
	_apply_enemy_damage(enemy)


func _apply_player_damage(player: Player) -> void:
	if player.is_dead:
		return
	if _try_report_multiplayer_player_hit(player):
		return
	player.apply_damage(
		damage,
		damage_type,
		_get_player_damage_context(player)
	)


func _apply_enemy_damage(enemy: Enemy) -> void:
	if enemy.is_dead:
		return
	var current_scene := get_tree().current_scene
	if (
		current_scene != null
		and current_scene.has_method("is_client_view_runtime")
		and bool(current_scene.call("is_client_view_runtime"))
	):
		return
	var impact_direction := global_position.direction_to(enemy.global_position)
	if impact_direction == Vector2.ZERO:
		impact_direction = direction
	if enemies_only and _try_apply_multiplayer_collectible_enemy_damage(enemy, impact_direction):
		return
	if _try_report_multiplayer_enemy_hit(enemy, impact_direction):
		return
	enemy.apply_damage(damage, impact_direction, damage_type)


func _spawn_explosion_effect() -> void:
	if explosion_scene == null:
		return
	var spawn_parent := get_tree().current_scene
	if spawn_parent == null:
		spawn_parent = get_parent()
	if spawn_parent == null:
		return

	var explosion := explosion_scene.instantiate() as Node2D
	if explosion == null:
		return
	explosion.top_level = true
	if explosion.has_method("setup"):
		explosion.call("setup", explosion_radius)
	spawn_parent.add_child(explosion)
	explosion.global_position = global_position


func _try_report_multiplayer_player_hit(player: Player) -> bool:
	var source_id := _get_damage_source_id()
	if source_id <= 0:
		return false
	var current_scene := get_tree().current_scene
	if current_scene == null or not current_scene.has_method("request_multiplayer_player_damage"):
		return false
	return bool(current_scene.call(
		"request_multiplayer_player_damage",
		source_id,
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


func _try_report_multiplayer_enemy_hit(enemy: Enemy, impact_direction: Vector2) -> bool:
	if projectile_id <= 0 or owner_peer_id <= 0:
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
		impact_direction
	)
	return true


func _try_apply_multiplayer_collectible_enemy_damage(enemy: Enemy, impact_direction: Vector2) -> bool:
	var current_scene := get_tree().current_scene
	if current_scene == null or not current_scene.has_method("apply_multiplayer_collectible_enemy_damage"):
		return false
	return bool(current_scene.call(
		"apply_multiplayer_collectible_enemy_damage",
		enemy,
		damage,
		impact_direction,
		int(damage_type)
	))


func _get_damage_source_id() -> int:
	if projectile_id > 0:
		return projectile_id
	return get_instance_id()


func _apply_explosion_radius() -> void:
	if not is_node_ready():
		return
	var circle_shape := explosion_shape.shape as CircleShape2D
	if circle_shape != null:
		circle_shape.radius = maxf(explosion_radius, 0.0)


func _apply_collision_masks() -> void:
	collision_mask = ENEMY_ONLY_HIT_COLLISION_MASK if enemies_only else HIT_COLLISION_MASK


func _get_hit_collision_mask() -> int:
	return ENEMY_ONLY_HIT_COLLISION_MASK if enemies_only else HIT_COLLISION_MASK


func _get_explosion_damage_mask() -> int:
	return ENEMY_ONLY_EXPLOSION_DAMAGE_MASK if enemies_only else EXPLOSION_DAMAGE_MASK


func _is_homing_target_valid() -> bool:
	if target_node == null or not is_instance_valid(target_node):
		return false
	var player := target_node as Player
	if player != null:
		return not player.is_dead
	var enemy := target_node as Enemy
	if enemy != null:
		return not enemy.is_dead
	return true
