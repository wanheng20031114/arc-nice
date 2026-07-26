extends Area2D

class_name Bullet

signal projectile_finished(projectile_id: int, projectile: Node)

# 世界碰撞层的掩码
const WORLD_COLLISION_MASK := 1
const HOMING_TURN_SPEED := 5.5
const PIERCING_TINT := Color(1.0, 0.36, 0.34, 1.0)
const HOMING_TINT := Color(0.48, 1.0, 0.62, 1.0)
const PIERCING_HOMING_TINT := Color(1.0, 0.72, 0.26, 1.0)

# 子弹飞行速度
@export var speed:float = 320.0
# 子弹最大存活时间（秒）
@export var max_lifetime: float = 2.0

# 子弹当前的飞行方向
var direction : Vector2 = Vector2.RIGHT
# 由发射者在生成时写入，命中目标时读取。
var damage: int = 1
# 剩余存活时间
var remaining_lifetime : float = 0.0
var projectile_id: int = 0
var owner_peer_id: int = 0
var source_type: StringName = &"player_bullet"
var pierces_enemies: bool = false
var hit_enemy_instance_ids: Dictionary = {}
var collectible_owner: Player = null
var homing_target: Enemy = null
var is_homing: bool = false
var pool_active: bool = true
var _authored_speed: float = 320.0
var _authored_max_lifetime: float = 2.0
var _authored_collision_layer: int = 16
var _authored_collision_mask: int = 4
var world_collision_query := PhysicsRayQueryParameters2D.create(
	Vector2.ZERO,
	Vector2.ZERO,
	WORLD_COLLISION_MASK
)


func _ready() -> void:
	_authored_speed = speed
	_authored_max_lifetime = max_lifetime
	_authored_collision_layer = collision_layer
	_authored_collision_mask = collision_mask
	remaining_lifetime = max_lifetime
	pool_active = not has_meta(SessionObjectPool.POOL_OWNER_META)
	world_collision_query.collide_with_bodies = true
	world_collision_query.collide_with_areas = false


func on_pool_acquired(_generation: int) -> void:
	pool_active = true
	direction = Vector2.RIGHT
	damage = 1
	speed = _authored_speed
	max_lifetime = _authored_max_lifetime
	remaining_lifetime = max_lifetime
	projectile_id = 0
	owner_peer_id = 0
	source_type = &"player_bullet"
	pierces_enemies = false
	hit_enemy_instance_ids.clear()
	collectible_owner = null
	homing_target = null
	is_homing = false
	rotation = 0.0
	modulate = Color.WHITE
	collision_layer = _authored_collision_layer
	collision_mask = _authored_collision_mask
	monitoring = true
	monitorable = true
	set_physics_process(true)


func on_pool_released(_generation: int) -> void:
	pool_active = false
	set_physics_process(false)
	set_deferred("monitoring", false)
	set_deferred("monitorable", false)
	hit_enemy_instance_ids.clear()
	collectible_owner = null
	homing_target = null
	is_homing = false


func retire() -> void:
	if not pool_active:
		return
	pool_active = false
	set_physics_process(false)
	set_deferred("monitoring", false)
	set_deferred("monitorable", false)
	projectile_finished.emit(projectile_id, self)
	if SessionObjectPool.release_to_owner(self):
		return
	queue_free()


# 外部生成子弹后调用，用来设置方向
func setup(
	initial_direction: Vector2,
	initial_damage: int = 1,
	initial_pierces_enemies: bool = false
) -> void:
	if initial_direction != Vector2.ZERO:
		direction = initial_direction.normalized()
		rotation = direction.angle()
	damage = maxi(initial_damage, 0)
	pierces_enemies = initial_pierces_enemies
	_update_collectible_tint()


func setup_homing(target: Enemy) -> void:
	homing_target = target if target != null and is_instance_valid(target) and not target.is_dead else null
	is_homing = homing_target != null
	_update_collectible_tint()


func setup_multiplayer(
	new_projectile_id: int,
	new_owner_peer_id: int,
	new_source_type: StringName
) -> void:
	projectile_id = maxi(new_projectile_id, 0)
	owner_peer_id = new_owner_peer_id
	source_type = new_source_type


func setup_collectible_owner(owner_player: Player) -> void:
	collectible_owner = owner_player


func get_damage_type() -> EnemyConfig.DamageType:
	return EnemyConfig.DamageType.PHYSICAL


# 物理帧更新逻辑，处理子弹移动和碰撞检测
func _physics_process(delta: float) -> void:
	if not pool_active:
		return
	_update_homing(delta)
	var current_position: Vector2 = global_position
	var next_position: Vector2 = current_position + direction * speed * delta
	
	# 检查这一帧移动路径是否撞到世界
	if _will_hit_world(current_position, next_position):
		retire()
		return
	
	global_position = next_position
	
	# 生命周期结束后自动删除
	remaining_lifetime -= delta
	if remaining_lifetime <= 0.0:
		retire()


func _update_homing(delta: float) -> void:
	if not is_homing:
		return
	if homing_target == null or not is_instance_valid(homing_target) or homing_target.is_dead:
		_stop_homing()
		return
	var desired_direction := global_position.direction_to(homing_target.global_position)
	if desired_direction == Vector2.ZERO:
		return
	var turn_limit := HOMING_TURN_SPEED * maxf(delta, 0.0)
	var turn_angle := clampf(direction.angle_to(desired_direction), -turn_limit, turn_limit)
	direction = direction.rotated(turn_angle).normalized()
	rotation = direction.angle()


func _stop_homing() -> void:
	is_homing = false
	homing_target = null
	_update_collectible_tint()


func _update_collectible_tint() -> void:
	if pierces_enemies and is_homing:
		modulate = PIERCING_HOMING_TINT
	elif pierces_enemies:
		modulate = PIERCING_TINT
	elif is_homing:
		modulate = HOMING_TINT
	else:
		modulate = Color.WHITE


# 检测从当前位置到下一位置之间是否撞到墙体/世界
func _will_hit_world(from_position: Vector2, to_position: Vector2) -> bool:
	var space_state := get_world_2d().direct_space_state
	
	if space_state == null:
		return false
	
	world_collision_query.from = from_position
	world_collision_query.to = to_position
	var hit_result: Dictionary = space_state.intersect_ray(world_collision_query)
	
	return not hit_result.is_empty()


# 撞到其他 Area2D 时
func _on_area_entered(area: Area2D) -> void:
	if not pool_active:
		return
	if area is Bullet :
		return
	retire()


# 撞到 PhysicsBody2D 时，比如 StaticBody2D / CharacterBody2D / RigidBody2D
func _on_body_entered(body: Node2D) -> void:
	if not pool_active:
		return
	var enemy := body as Enemy
	if enemy != null:
		try_hit_enemy(enemy)
		return

	retire()


func try_hit_enemy(enemy: Enemy) -> bool:
	if not pool_active or is_queued_for_deletion():
		return false
	if enemy == null or not is_instance_valid(enemy):
		return false
	if not _try_mark_enemy_hit(enemy):
		return false

	var reported_multiplayer_hit := _try_report_multiplayer_enemy_hit(enemy)
	var hit_registered := false
	var resolved_damage := damage
	if collectible_owner != null and is_instance_valid(collectible_owner):
		resolved_damage = collectible_owner.resolve_attack_damage_against_enemy(damage, enemy)
	if reported_multiplayer_hit:
		hit_registered = true
	else:
		var request := DamageRequest.new(resolved_damage, int(get_damage_type()))
		request.with_source(
			collectible_owner if collectible_owner != null else self,
			projectile_id,
			&"player_bullet"
		)
		request.with_directions(-direction)
		hit_registered = enemy.apply_combat_damage(request).accepted

	if not hit_registered:
		hit_enemy_instance_ids.erase(enemy.get_instance_id())
		return false
	if not reported_multiplayer_hit and collectible_owner != null and is_instance_valid(collectible_owner):
		collectible_owner.apply_collectible_attack_hit_effects(enemy, resolved_damage)
	if is_homing and enemy == homing_target:
		_stop_homing()
	if not pierces_enemies:
		retire()
	return true


func _try_mark_enemy_hit(enemy: Enemy) -> bool:
	var enemy_id := enemy.get_instance_id()
	if hit_enemy_instance_ids.has(enemy_id):
		return false
	hit_enemy_instance_ids[enemy_id] = true
	return true


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
		-enemy.global_position.direction_to(global_position)
	)
	return true
