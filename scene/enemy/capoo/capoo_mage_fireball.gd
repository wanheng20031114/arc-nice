extends Area2D
class_name CapooMageFireball

signal projectile_finished(projectile_id: int, projectile: Node)

const IMPACT_SCENE := preload("res://scene/enemy/capoo/capoo_mage_fireball_impact.tscn")
const COMPLETE_SHAPE_QUERY_2D := preload("res://scene/combat/physics/complete_shape_query_2d.gd")
const WORLD_EFFECT_VISIBILITY := preload("res://scene/combat/feedback/world_effect_visibility.gd")
const WORLD_COLLISION_MASK := 1
const DAMAGEABLE_COLLISION_MASK := 2 | 512
const EXPLOSION_QUERY_BATCH_SIZE := 64
const DAMAGE_TYPE := EnemyConfig.DamageType.MAGIC

# Focused performance probes can restore the old direct-instantiation path for
# a strict A/B. Production uses a bounded, strict visual-effect lease.
static var pooled_impact_effect_enabled := true

@export var speed: float = 155.0
@export var max_lifetime: float = 4.0
@export var fireball_radius: float = 10.5
@export var homing_turn_rate: float = 0.65

@onready var animated_sprite: AnimatedSprite2D = $AnimatedSprite2D
@onready var emission_overlay: AnimatedSprite2D = (
	$AnimatedSprite2D/EmissionOverlay
)
@onready var collision_shape: CollisionShape2D = $CollisionShape2D
@onready var explosion_shape: CollisionShape2D = $ExplosionShape

var direction := Vector2.RIGHT
var target_player: Node2D = null
var damage: int = 1
var remaining_lifetime: float = 0.0
var has_exploded: bool = false
var projectile_id: int = 0
var owner_peer_id: int = 0
var source_type: StringName = &"capoo_mage_fireball"
var pool_active: bool = true
var combat_runtime: CombatRuntimeBase = null
var gameplay_gateway: MultiplayerGameplayGateway = null
var _authored_speed: float = 155.0
var _authored_max_lifetime: float = 4.0
var _authored_radius: float = 10.5
var _authored_homing_turn_rate: float = 0.65
var _authored_collision_layer: int = 128
var _authored_collision_mask: int = WORLD_COLLISION_MASK | DAMAGEABLE_COLLISION_MASK
var world_collision_exclude: Array[RID] = []
var world_collision_query := PhysicsRayQueryParameters2D.create(
	Vector2.ZERO,
	Vector2.ZERO,
	WORLD_COLLISION_MASK
)
var explosion_query := PhysicsShapeQueryParameters2D.new()
var explosion_damaged_bodies: Dictionary = {}


func _ready() -> void:
	_authored_speed = speed
	_authored_max_lifetime = max_lifetime
	_authored_radius = fireball_radius
	_authored_homing_turn_rate = homing_turn_rate
	_authored_collision_layer = collision_layer
	_authored_collision_mask = collision_mask
	remaining_lifetime = maxf(max_lifetime, 0.01)
	pool_active = not has_meta(SessionObjectPool.POOL_OWNER_META)
	world_collision_exclude.clear()
	world_collision_exclude.append(get_rid())
	world_collision_query.exclude = world_collision_exclude
	world_collision_query.collide_with_bodies = true
	world_collision_query.collide_with_areas = false
	explosion_query.collide_with_bodies = true
	explosion_query.collide_with_areas = false
	explosion_query.exclude = world_collision_exclude
	body_entered.connect(_on_body_entered)
	_apply_radius()
	if animated_sprite.sprite_frames != null and animated_sprite.sprite_frames.has_animation(&"fly"):
		animated_sprite.play(&"fly")
		_restart_emission_animation()


func on_pool_acquired(_generation: int) -> void:
	combat_runtime = null
	gameplay_gateway = null
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
	explosion_damaged_bodies.clear()
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
			_restart_emission_animation()


func on_pool_released(_generation: int) -> void:
	pool_active = false
	has_exploded = true
	target_player = null
	explosion_damaged_bodies.clear()
	combat_runtime = null
	gameplay_gateway = null
	set_physics_process(false)
	set_deferred("monitoring", false)
	set_deferred("monitorable", false)
	collision_shape.set_deferred("disabled", true)
	if animated_sprite != null:
		animated_sprite.stop()
	if emission_overlay != null:
		emission_overlay.stop()


func bind_gameplay_context(
	runtime_context: CombatRuntimeBase,
	gateway: MultiplayerGameplayGateway
) -> void:
	combat_runtime = runtime_context
	gameplay_gateway = gateway


func _restart_emission_animation() -> void:
	if emission_overlay == null:
		return
	emission_overlay.stop()
	emission_overlay.animation = animated_sprite.animation
	emission_overlay.set_frame_and_progress(
		animated_sprite.frame,
		animated_sprite.frame_progress
	)
	emission_overlay.play(animated_sprite.animation)


func setup(
	initial_direction: Vector2,
	initial_damage: int,
	initial_speed: float,
	initial_lifetime: float,
	initial_radius: float = 10.5,
	initial_target_player: Node2D = null,
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
	if not _is_homing_target_alive():
		return
	var desired_direction := global_position.direction_to(target_player.global_position)
	if desired_direction == Vector2.ZERO:
		return
	var angle_delta := direction.angle_to(desired_direction)
	var max_turn := homing_turn_rate * delta
	direction = direction.rotated(clampf(angle_delta, -max_turn, max_turn)).normalized()
	rotation = direction.angle()


func _is_homing_target_alive() -> bool:
	if target_player == null or not is_instance_valid(target_player):
		return false
	var player := target_player as Player
	if player != null:
		return not player.is_dead
	var plant := target_player as PlantDefense
	return plant != null and not plant.is_dead and not plant.is_removing


func _get_world_hit(from_position: Vector2, to_position: Vector2) -> Dictionary:
	world_collision_query.from = from_position
	world_collision_query.to = to_position
	return get_world_2d().direct_space_state.intersect_ray(world_collision_query)


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
	collision_shape.set_deferred("disabled", true)
	if _has_authoritative_runtime():
		_apply_explosion_damage(direct_hit)
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


func _apply_explosion_damage(direct_hit: Node2D = null) -> void:
	var circle_shape := explosion_shape.shape as CircleShape2D
	if circle_shape == null:
		return

	explosion_query.shape = circle_shape
	explosion_query.transform = Transform2D(0.0, global_position)
	explosion_query.collision_mask = DAMAGEABLE_COLLISION_MASK
	explosion_damaged_bodies.clear()
	_apply_explosion_damage_to_body(direct_hit, explosion_damaged_bodies)
	var results := COMPLETE_SHAPE_QUERY_2D.intersect_shape_all(
		get_world_2d().direct_space_state,
		explosion_query,
		EXPLOSION_QUERY_BATCH_SIZE
	)
	for result in results:
		var body := result.get("collider") as Node2D
		_apply_explosion_damage_to_body(body, explosion_damaged_bodies)


func _apply_explosion_damage_to_body(body: Node2D, damaged_bodies: Dictionary) -> void:
	if body == null or not is_instance_valid(body):
		return
	var body_id := body.get_instance_id()
	if damaged_bodies.has(body_id):
		return
	var player := body as Player
	if player != null:
		damaged_bodies[body_id] = true
		if (
			not player.is_dead
			and not _try_report_multiplayer_player_hit(player)
			and _has_explicit_singleplayer_authority()
		):
			player.apply_damage(
				damage,
				DAMAGE_TYPE,
				_get_player_damage_context(player)
			)
		return
	var plant := body as PlantDefense
	if plant == null:
		return
	if plant.is_dead or plant.is_removing:
		return
	damaged_bodies[body_id] = true
	plant.receive_damage(
		damage,
		self,
		global_position.direction_to(plant.global_position),
		DAMAGE_TYPE
	)


func _spawn_impact_effect() -> void:
	if combat_runtime == null or not is_instance_valid(combat_runtime):
		return
	var spawn_parent: Node = combat_runtime
	var impact: CapooMageFireballImpact = null
	if pooled_impact_effect_enabled:
		if not WORLD_EFFECT_VISIBILITY.is_position_near_viewport(self, global_position):
			return
		if not combat_runtime.has_session_object_pool_scene(IMPACT_SCENE):
			return
		impact = combat_runtime.acquire_session_object(
			IMPACT_SCENE,
			true
		) as CapooMageFireballImpact
		# Strict acquisition deliberately omits the feedback when its visual
		# budget is exhausted. Explosion damage was already resolved above.
		if impact == null:
			return
	else:
		impact = IMPACT_SCENE.instantiate() as CapooMageFireballImpact
	if impact == null:
		return
	impact.top_level = true
	if impact.get_parent() == null:
		spawn_parent.add_child(impact)
	elif impact.get_parent() != spawn_parent:
		impact.reparent(spawn_parent)
	impact.global_position = global_position
	impact.restart()


func _try_report_multiplayer_player_hit(player: Player) -> bool:
	if (
		projectile_id <= 0
		or gameplay_gateway == null
		or not is_instance_valid(gameplay_gateway)
	):
		return false
	return gameplay_gateway.request_player_damage(
		projectile_id,
		player.peer_id,
		damage,
		source_type,
		DAMAGE_TYPE,
		_get_source_direction_to_player(player),
		true
	)


func _has_authoritative_runtime() -> bool:
	return (
		combat_runtime != null
		and is_instance_valid(combat_runtime)
		and combat_runtime.runtime_mode
			!= CombatRuntimeBase.RuntimeMode.CLIENT_VIEW
	)


func _has_explicit_singleplayer_authority() -> bool:
	return (
		_has_authoritative_runtime()
		and combat_runtime.runtime_mode
			== CombatRuntimeBase.RuntimeMode.SINGLEPLAYER
	)


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
