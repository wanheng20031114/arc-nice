extends Area2D
class_name YuanshiInsectFireProjectile

signal projectile_finished(projectile_id: int, projectile: Node)

const WORLD_COLLISION_MASK := 1
const DAMAGEABLE_COLLISION_MASK := 2 | 4 | 512

@export var speed: float = 142.5
@export var max_lifetime: float = 2.0

var direction := Vector2.RIGHT
var damage: int = 1
var remaining_lifetime: float = 0.0
var has_hit: bool = false
var projectile_id: int = 0
var owner_peer_id: int = 0
var source_type: StringName = &"yuanshi_fire_projectile"
var damage_source_snapshot: DamageSourceSnapshot = null
var pool_active: bool = true
var combat_runtime: CombatRuntimeBase = null
var gameplay_gateway: MultiplayerGameplayGateway = null
var _authored_speed: float = 142.5
var _authored_max_lifetime: float = 2.0
var _authored_collision_layer: int = 128
var _authored_collision_mask: int = DAMAGEABLE_COLLISION_MASK
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
	remaining_lifetime = maxf(max_lifetime, 0.01)
	pool_active = not has_meta(SessionObjectPool.POOL_OWNER_META)
	world_collision_query.collide_with_bodies = true
	world_collision_query.collide_with_areas = false
	body_entered.connect(_on_body_entered)


func on_pool_acquired(_generation: int) -> void:
	remove_meta(&"damage_source_snapshot")
	combat_runtime = null
	gameplay_gateway = null
	pool_active = true
	has_hit = false
	direction = Vector2.RIGHT
	damage = 1
	speed = _authored_speed
	max_lifetime = _authored_max_lifetime
	remaining_lifetime = maxf(max_lifetime, 0.01)
	projectile_id = 0
	owner_peer_id = 0
	source_type = &"yuanshi_fire_projectile"
	damage_source_snapshot = null
	rotation = 0.0
	collision_layer = _authored_collision_layer
	collision_mask = _authored_collision_mask
	monitoring = true
	monitorable = true
	set_physics_process(true)


func on_pool_released(_generation: int) -> void:
	remove_meta(&"damage_source_snapshot")
	pool_active = false
	has_hit = true
	combat_runtime = null
	gameplay_gateway = null
	damage_source_snapshot = null
	set_physics_process(false)
	set_deferred("monitoring", false)
	set_deferred("monitorable", false)


func bind_gameplay_context(
	runtime_context: CombatRuntimeBase,
	gateway: MultiplayerGameplayGateway
) -> void:
	combat_runtime = runtime_context
	gameplay_gateway = gateway


func setup(
	initial_direction: Vector2,
	initial_damage: int,
	initial_speed: float,
	initial_lifetime: float,
	initial_damage_source_snapshot: DamageSourceSnapshot = null
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
	damage_source_snapshot = (
		initial_damage_source_snapshot.duplicate_snapshot()
		if initial_damage_source_snapshot != null
		else null
	)
	if damage_source_snapshot != null:
		set_meta(
			&"damage_source_snapshot",
			damage_source_snapshot.duplicate_snapshot()
		)
	else:
		remove_meta(&"damage_source_snapshot")


func setup_multiplayer(
	new_projectile_id: int,
	new_owner_peer_id: int,
	new_source_type: StringName
) -> void:
	projectile_id = maxi(new_projectile_id, 0)
	owner_peer_id = new_owner_peer_id
	source_type = new_source_type
	_rebind_damage_source_snapshot_to_projectile_id()


func _rebind_damage_source_snapshot_to_projectile_id() -> void:
	if damage_source_snapshot == null or projectile_id <= 0:
		return
	damage_source_snapshot = DamageSourceSnapshot.create(
		damage_source_snapshot.source_faction_id,
		damage_source_snapshot.credit_peer_id,
		damage_source_snapshot.instigator_entity_id,
		projectile_id,
		damage_source_snapshot.source_type
	)
	set_meta(
		&"damage_source_snapshot",
		damage_source_snapshot.duplicate_snapshot()
	)


func _physics_process(delta: float) -> void:
	if has_hit or not pool_active:
		return

	var current_position := global_position
	var next_position := current_position + direction * speed * delta
	if _will_hit_world(current_position, next_position):
		_consume()
		return

	global_position = next_position
	remaining_lifetime -= delta
	if remaining_lifetime <= 0.0:
		_consume()


func _will_hit_world(from_position: Vector2, to_position: Vector2) -> bool:
	world_collision_query.from = from_position
	world_collision_query.to = to_position
	return not get_world_2d().direct_space_state.intersect_ray(
		world_collision_query
	).is_empty()


func _on_body_entered(body: Node2D) -> void:
	if has_hit or not pool_active:
		return

	var player := body as Player
	if player != null:
		if not _is_damage_admitted(player):
			return
		if (
			not _try_report_multiplayer_player_hit(player)
			and _has_explicit_singleplayer_authority()
		):
			var player_result := player.apply_combat_damage(
				_make_damage_request(direction, -direction)
			)
			if _should_ignore_non_hostile_result(player_result):
				return
		_consume()
		return
	else:
		var plant := body as PlantDefense
		if plant != null:
			if plant.is_dead or plant.is_removing:
				return
			if not _has_authoritative_runtime():
				_consume()
				return
			var plant_result := plant.apply_combat_damage(
				_make_damage_request(direction, -direction)
			)
			if _should_ignore_non_hostile_result(plant_result):
				return
			_consume()
			return

		var enemy := body as Enemy
		if enemy != null:
			if enemy.is_dead or not _has_authoritative_runtime():
				return
			var enemy_result := enemy.apply_combat_damage(
				_make_damage_request(direction, -direction)
			)
			if _should_ignore_non_hostile_result(enemy_result):
				return
			_consume()
			return

	_consume()


func _make_damage_request(
	impact_direction: Vector2,
	source_direction: Vector2
) -> DamageRequest:
	var request := DamageRequest.new(
		damage,
		EnemyConfig.DamageType.PHYSICAL
	)
	if damage_source_snapshot != null:
		request.with_source_snapshot(damage_source_snapshot)
	else:
		request.with_source(self, projectile_id, source_type)
	request.with_directions(impact_direction, source_direction)
	request.with_flag(CombatTypes.DamageFlag.RANGED, true)
	return request


func _should_ignore_non_hostile_result(result: DamageResult) -> bool:
	return (
		result != null
		and result.is_rejected_for(
			CombatTypes.DamageRejectionReason.NON_HOSTILE
		)
	)


func _consume() -> void:
	if has_hit or not pool_active:
		return
	has_hit = true
	pool_active = false
	set_physics_process(false)
	set_deferred("monitoring", false)
	set_deferred("monitorable", false)
	projectile_finished.emit(projectile_id, self)
	remove_meta(&"damage_source_snapshot")
	damage_source_snapshot = null
	if SessionObjectPool.release_to_owner(self):
		return
	queue_free()


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
		EnemyConfig.DamageType.PHYSICAL,
		-direction,
		true,
		false,
		damage_source_snapshot
	)


func _is_damage_admitted(target: Node) -> bool:
	if not _has_authoritative_runtime():
		return true
	if target == null or not target.has_method(&"get_combat_faction_id"):
		return false
	return CombatDamageAdmission.is_admitted(
		_make_damage_request(direction, -direction),
		int(target.call(&"get_combat_faction_id")),
		combat_runtime.get_combat_relation_service()
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
