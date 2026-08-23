extends Area2D
class_name FrostSorcererIceSpike

signal projectile_finished(projectile_id: int, projectile: Node)

const PROJECTILE_TYPE := &"frost_sorcerer_ice_spike"
const WORLD_COLLISION_MASK := 1
const DAMAGEABLE_COLLISION_MASK := 2 | 4 | 512
const AUTHORED_COLLISION_LAYER := 128
const AUTHORED_COLLISION_MASK := WORLD_COLLISION_MASK | DAMAGEABLE_COLLISION_MASK
const EFFECT_VISUAL_DURATION := 4.0 / 12.0
const COMPENSATION_STEP := 1.0 / 60.0
# The authored horizontal capsule spans 12 px. At 100 px/s, ordinary 30/60 Hz
# motion advances only 3.33/1.67 px, so Area2D overlap sampling remains
# continuous. Sweep only unusually large steps and network catch-up motion.
const MAX_UNSWEPT_DISTANCE := 4.0
const MAX_UNSWEPT_DISTANCE_SQUARED := MAX_UNSWEPT_DISTANCE * MAX_UNSWEPT_DISTANCE
const PROJECTILE_SHAPE_SWEEP_2D_SCRIPT := preload(
	"res://scene/combat/physics/projectile_shape_sweep_2d.gd"
)

@export var speed: float = 100.0
@export var max_lifetime: float = 7.0

@onready var animated_sprite: AnimatedSprite2D = $AnimatedSprite2D
@onready var collision_shape: CollisionShape2D = $CollisionShape2D

var motion_sweep := PROJECTILE_SHAPE_SWEEP_2D_SCRIPT.new()

var direction := Vector2.RIGHT
var damage: int = 1
var remaining_lifetime: float = 7.0
var projectile_id: int = 0
var owner_peer_id: int = 0
var source_type: StringName = PROJECTILE_TYPE
var damage_source_snapshot: DamageSourceSnapshot = null
var pool_active := true
var combat_runtime: CombatRuntimeBase = null
var gameplay_gateway: MultiplayerGameplayGateway = null
var has_hit := false
var effect_time_left := 0.0
var multiplayer_contact_consumed := false
var motion_sweep_query_count := 0
var _authored_speed := 100.0
var _authored_max_lifetime := 7.0
var _authored_collision_layer := AUTHORED_COLLISION_LAYER
var _authored_collision_mask := AUTHORED_COLLISION_MASK
var _pending_setup := false


func _ready() -> void:
	_authored_speed = speed
	_authored_max_lifetime = max_lifetime
	_authored_collision_layer = collision_layer
	_authored_collision_mask = collision_mask
	motion_sweep.configure(collision_shape.shape, AUTHORED_COLLISION_MASK)
	body_entered.connect(_on_body_entered)
	pool_active = not has_meta(SessionObjectPool.POOL_OWNER_META)
	if _pending_setup or pool_active:
		_activate_projectile()
		_pending_setup = false
	else:
		_disable_projectile()


func on_pool_acquired(_generation: int) -> void:
	remove_meta(&"damage_source_snapshot")
	combat_runtime = null
	gameplay_gateway = null
	pool_active = true
	has_hit = false
	effect_time_left = 0.0
	direction = Vector2.RIGHT
	damage = 1
	speed = _authored_speed
	max_lifetime = _authored_max_lifetime
	remaining_lifetime = maxf(max_lifetime, 0.01)
	projectile_id = 0
	owner_peer_id = 0
	source_type = PROJECTILE_TYPE
	damage_source_snapshot = null
	multiplayer_contact_consumed = false
	motion_sweep_query_count = 0
	_pending_setup = false
	rotation = 0.0
	_activate_projectile()


func on_pool_released(_generation: int) -> void:
	remove_meta(&"damage_source_snapshot")
	pool_active = false
	has_hit = true
	effect_time_left = 0.0
	combat_runtime = null
	gameplay_gateway = null
	damage_source_snapshot = null
	_pending_setup = false
	_disable_projectile()


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
	effect_time_left = 0.0
	direction = (
		initial_direction.normalized()
		if initial_direction != Vector2.ZERO
		else Vector2.RIGHT
	)
	damage = maxi(initial_damage, 0)
	speed = maxf(initial_speed, 0.0)
	max_lifetime = maxf(initial_lifetime, 0.01)
	remaining_lifetime = max_lifetime
	projectile_id = 0
	owner_peer_id = 0
	source_type = PROJECTILE_TYPE
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
	multiplayer_contact_consumed = false
	motion_sweep_query_count = 0
	rotation = direction.angle()
	_pending_setup = true
	if is_node_ready():
		_activate_projectile()
		_pending_setup = false
	set_physics_process(true)


func setup_multiplayer(
	new_projectile_id: int,
	new_owner_peer_id: int,
	new_source_type: StringName
) -> void:
	projectile_id = maxi(new_projectile_id, 0)
	owner_peer_id = new_owner_peer_id
	source_type = (
		new_source_type
		if new_source_type != &""
		else PROJECTILE_TYPE
	)
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
	if not pool_active:
		return
	if has_hit:
		effect_time_left = maxf(effect_time_left - maxf(delta, 0.0), 0.0)
		if effect_time_left <= 0.0:
			_retire()
		return
	_advance_motion(maxf(delta, 0.0))


func simulate_compensated_motion(seconds: float) -> void:
	var time_left := clampf(
		seconds,
		0.0,
		maxf(remaining_lifetime, 0.0)
	)
	while time_left > 0.0 and pool_active and not has_hit:
		var step := minf(time_left, COMPENSATION_STEP)
		_advance_motion(step, true)
		time_left -= step


func _advance_motion(delta: float, force_sweep: bool = false) -> void:
	if delta <= 0.0 or has_hit or not pool_active:
		return
	var current_position := global_position
	var motion_delta := direction * speed * delta
	var next_position := current_position + motion_delta
	if (
		force_sweep
		or motion_delta.length_squared() > MAX_UNSWEPT_DISTANCE_SQUARED
	):
		var motion_hit := _get_motion_hit(current_position, next_position)
		if not motion_hit.is_empty():
			global_position = motion_hit.get("position", next_position)
			_handle_collision_body(motion_hit.get("collider") as Node2D)
			return
	global_position = next_position
	remaining_lifetime = maxf(remaining_lifetime - delta, 0.0)
	if remaining_lifetime <= 0.0:
		_begin_retire_effect(&"expire")


func _get_motion_hit(from_position: Vector2, to_position: Vector2) -> Dictionary:
	motion_sweep_query_count += 1
	var motion_delta := to_position - from_position
	var result := motion_sweep.cast(
		get_world_2d().direct_space_state,
		collision_shape.global_transform,
		motion_delta
	)
	if result.is_empty():
		return {}
	return {
		"collider": result.get("collider"),
		"position": from_position + motion_delta * float(result["fraction"]),
	}


func _on_body_entered(body: Node2D) -> void:
	if has_hit or not pool_active:
		return
	_handle_collision_body(body)


func _handle_collision_body(body: Node2D) -> void:
	if has_hit or not pool_active:
		return
	var player := body as Player
	var plant := body as PlantDefense
	var enemy := body as Enemy
	if player == null and plant == null and enemy == null:
		# 世界层碰撞会终止冰锥，且不会产生范围查询或额外伤害。
		_begin_retire_effect(&"expire")
		return
	var request := _make_damage_request(body)
	if (
		_has_authoritative_runtime()
		and not _is_request_admitted(request, body)
	):
		return
	var contact_preconsumed := _try_consume_multiplayer_contact()
	if projectile_id > 0 and not contact_preconsumed:
		_begin_retire_effect(&"impact")
		return
	if player != null:
		if not player.is_dead:
			var handled_by_multiplayer := _try_report_multiplayer_player_hit(
				player,
				contact_preconsumed
			)
			if (
				not handled_by_multiplayer
				and _has_explicit_singleplayer_authority()
			):
				var damage_was_applied := (
					player.apply_combat_damage(request).accepted
				)
				if damage_was_applied and not player.is_dead:
					player.apply_cold_status()
		_begin_retire_effect(&"impact")
		return

	if plant != null:
		if (
			_has_authoritative_runtime()
			and not plant.is_dead
			and not plant.is_removing
		):
			plant.apply_combat_damage(request)
		# 建筑只受到本次法术伤害，不附加寒冷状态。
		_begin_retire_effect(&"impact")
		return
	if enemy != null:
		if _has_authoritative_runtime() and not enemy.is_dead:
			var damage_was_applied := enemy.apply_combat_damage(request).accepted
			if damage_was_applied and not enemy.is_dead:
				enemy.apply_cold_status()
		_begin_retire_effect(&"impact")


func _try_consume_multiplayer_contact() -> bool:
	if projectile_id <= 0:
		return true
	if multiplayer_contact_consumed:
		return true
	if gameplay_gateway == null or not is_instance_valid(gameplay_gateway):
		return false
	multiplayer_contact_consumed = (
		gameplay_gateway.try_consume_frost_sorcerer_ice_spike_contact(
			projectile_id,
			source_type
		)
	)
	return multiplayer_contact_consumed


func _try_report_multiplayer_player_hit(
	player: Player,
	contact_preconsumed: bool
) -> bool:
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
		EnemyConfig.DamageType.MAGIC,
		_get_source_direction_to_player(player),
		true,
		contact_preconsumed,
		damage_source_snapshot
	)


func _make_damage_request(target_body: Node2D) -> DamageRequest:
	var impact_direction := global_position.direction_to(
		target_body.global_position
	)
	var request := DamageRequest.new(damage, EnemyConfig.DamageType.MAGIC)
	if damage_source_snapshot != null:
		request.with_source_snapshot(damage_source_snapshot)
	else:
		request.with_source(self, projectile_id, source_type)
	request.with_directions(impact_direction, -impact_direction)
	request.with_flag(CombatTypes.DamageFlag.RANGED, true)
	return request


func _is_request_admitted(request: DamageRequest, target_body: Node) -> bool:
	if target_body == null or not target_body.has_method(&"get_combat_faction_id"):
		return false
	return CombatDamageAdmission.is_admitted(
		request,
		int(target_body.call(&"get_combat_faction_id")),
		combat_runtime.get_combat_relation_service()
			if combat_runtime != null and is_instance_valid(combat_runtime)
			else null
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


func _begin_retire_effect(animation_name: StringName) -> void:
	if has_hit or not pool_active:
		return
	_try_consume_multiplayer_contact()
	has_hit = true
	effect_time_left = EFFECT_VISUAL_DURATION
	collision_layer = 0
	collision_mask = 0
	set_deferred("monitoring", false)
	set_deferred("monitorable", false)
	if collision_shape != null:
		collision_shape.set_deferred("disabled", true)
	if animated_sprite != null:
		animated_sprite.show()
		animated_sprite.stop()
		animated_sprite.frame = 0
		animated_sprite.frame_progress = 0.0
		if (
			animated_sprite.sprite_frames != null
			and animated_sprite.sprite_frames.has_animation(animation_name)
		):
			animated_sprite.play(animation_name)


func _activate_projectile() -> void:
	if not is_node_ready():
		return
	pool_active = true
	motion_sweep.reset_runtime_state()
	has_hit = false
	effect_time_left = 0.0
	remaining_lifetime = maxf(max_lifetime, 0.01)
	collision_layer = _authored_collision_layer
	collision_mask = _authored_collision_mask
	monitoring = true
	monitorable = true
	collision_shape.disabled = false
	show()
	animated_sprite.show()
	animated_sprite.stop()
	animated_sprite.frame = 0
	animated_sprite.frame_progress = 0.0
	if (
		animated_sprite.sprite_frames != null
		and animated_sprite.sprite_frames.has_animation(&"fly")
	):
		animated_sprite.play(&"fly")
	set_physics_process(true)


func _disable_projectile() -> void:
	set_physics_process(false)
	collision_layer = 0
	collision_mask = 0
	if is_node_ready():
		set_deferred("monitoring", false)
		set_deferred("monitorable", false)
		collision_shape.set_deferred("disabled", true)
		animated_sprite.stop()
		hide()


func retire() -> void:
	if not pool_active:
		return
	_retire()


func _retire() -> void:
	if not pool_active:
		return
	_try_consume_multiplayer_contact()
	pool_active = false
	set_physics_process(false)
	projectile_finished.emit(projectile_id, self)
	remove_meta(&"damage_source_snapshot")
	damage_source_snapshot = null
	if SessionObjectPool.release_to_owner(self):
		return
	queue_free()
