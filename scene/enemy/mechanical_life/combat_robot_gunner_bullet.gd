extends CapooAK47Bullet
class_name CombatRobotGunnerBullet

const SOURCE_TYPE := &"combat_robot_gunner_bullet"
const PROJECTILE_SHAPE_SWEEP := preload("res://scene/combat/physics/projectile_shape_sweep_2d.gd")

@onready var sweep_collision_shape: CollisionShape2D = $CollisionShape2D

var damageable_sweep = PROJECTILE_SHAPE_SWEEP.new()
var sweep_exclude: Array[RID] = []


func _ready() -> void:
	super()
	source_type = SOURCE_TYPE
	_configure_damageable_sweep()


func on_pool_acquired(generation: int) -> void:
	super(generation)
	source_type = SOURCE_TYPE
	_clear_sweep_exclusions()
	damageable_sweep.reset_runtime_state()


func on_pool_released(generation: int) -> void:
	_clear_sweep_exclusions()
	damageable_sweep.reset_runtime_state()
	super(generation)


func simulate_compensated_motion(compensation_age: float) -> void:
	if has_hit or not pool_active:
		return
	var compensated_delta := minf(
		maxf(compensation_age, 0.0),
		maxf(remaining_lifetime, 0.0)
	)
	if compensated_delta <= 0.0:
		return
	_simulate_swept_compensation(compensated_delta)


func _simulate_swept_compensation(compensated_delta: float) -> void:
	var current_position := global_position
	var motion := direction * speed * compensated_delta
	if motion.is_zero_approx() or sweep_collision_shape == null:
		remaining_lifetime = maxf(remaining_lifetime - compensated_delta, 0.0)
		if remaining_lifetime <= 0.0:
			_consume(false)
		return

	_clear_sweep_exclusions()
	while true:
		damageable_sweep.query.exclude = sweep_exclude
		var hit := damageable_sweep.cast(
			get_world_2d().direct_space_state,
			sweep_collision_shape.global_transform,
			motion
		)
		var collider := hit.get("collider") as Node2D
		if collider == null or not is_instance_valid(collider):
			break
		var plant := collider as PlantDefense
		if plant == null or (not plant.is_dead and not plant.is_removing):
			var impact_fraction := clampf(
				float(hit.get("fraction", 1.0)),
				0.0,
				1.0
			)
			var impact_position := current_position + motion * impact_fraction
			if _will_hit_world(current_position, impact_position):
				global_position = last_world_collision_position
				_clear_sweep_exclusions()
				_consume(true)
				return
			global_position = impact_position
			remaining_lifetime = maxf(
				remaining_lifetime - compensated_delta * impact_fraction,
				0.0
			)
			_clear_sweep_exclusions()
			_on_body_entered(collider)
			return

		var collision_object := collider as CollisionObject2D
		if collision_object == null:
			break
		var collider_rid := collision_object.get_rid()
		if not collider_rid.is_valid() or sweep_exclude.has(collider_rid):
			break
		sweep_exclude.append(collider_rid)

	var destination := current_position + motion
	if _will_hit_world(current_position, destination):
		global_position = last_world_collision_position
		_clear_sweep_exclusions()
		_consume(true)
		return
	global_position = destination
	world_collision_anchor = destination
	world_collision_anchor_initialized = true
	remaining_lifetime = maxf(remaining_lifetime - compensated_delta, 0.0)
	_clear_sweep_exclusions()
	if remaining_lifetime <= 0.0:
		_consume(false)


func _on_body_entered(body: Node2D) -> void:
	if has_hit or not pool_active:
		return
	if _consume_if_unchecked_world_blocked():
		return

	var player := body as Player
	if player != null:
		if projectile_id > 0 and _request_player_damage_via_gateway(player):
			_consume(true)
			return
		if not _has_explicit_singleplayer_authority():
			# Missing or rejected multiplayer context must fail closed. Only an
			# explicitly bound single-player runtime may mutate health locally.
			_consume(true)
			return
		player.apply_damage(
			damage,
			EnemyConfig.DamageType.PHYSICAL,
			_get_player_damage_context()
		)
		_consume(true)
		return

	var plant := body as PlantDefense
	if plant != null:
		if plant.is_dead or plant.is_removing:
			return
		if not _has_authoritative_runtime():
			_consume(true)
			return
	super(body)


func _request_player_damage_via_gateway(player: Player) -> bool:
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
		true
	)


func _configure_damageable_sweep() -> void:
	if sweep_collision_shape == null or sweep_collision_shape.shape == null:
		return
	damageable_sweep.configure(
		sweep_collision_shape.shape,
		DAMAGEABLE_COLLISION_MASK
	)
	damageable_sweep.query.exclude = sweep_exclude


func _clear_sweep_exclusions() -> void:
	sweep_exclude.clear()
	damageable_sweep.query.exclude = sweep_exclude
