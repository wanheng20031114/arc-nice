extends Node2D
class_name FireSorcererFireballVolley

signal projectile_finished(projectile_id: int, projectile: Node)

const BALL_COUNT := 3
const ALL_BALLS_ACTIVE_MASK := (1 << BALL_COUNT) - 1
const WORLD_COLLISION_MASK := 1
const DAMAGEABLE_COLLISION_MASK := 2 | 4 | 512
const AUTHORED_COLLISION_LAYER := 128
const AUTHORED_COLLISION_MASK := WORLD_COLLISION_MASK | DAMAGEABLE_COLLISION_MASK
const IMPACT_VISUAL_DURATION := 4.0 / 12.0
const EXPIRE_VISUAL_DURATION := 4.0 / 12.0
const COMPENSATION_STEP := 1.0 / 60.0
const TARGET_REFRESH_INTERVAL := 0.35
const TARGET_QUERY_METHOD := &"find_nearest_enemy_attack_target_world"
const PROJECTILE_SHAPE_SWEEP_2D_SCRIPT := preload(
	"res://scene/combat/physics/projectile_shape_sweep_2d.gd"
)
static var performance_metrics_enabled := false
static var _performance_metrics := {
	"physics_calls": 0,
	"physics_usec": 0,
	"active_ball_steps": 0,
	"homing_updates": 0,
	"compensation_sweep_calls": 0,
}

@export var speed: float = 100.0
@export var max_lifetime: float = 7.0
@export var homing_turn_rate: float = 6.0
@export_group("燃烧")
@export var burn_duration: float = 5.0
@export var burn_level: int = 5
@export_group("多人投射物身份")
@export var projectile_source_type: StringName = (
	&"fire_sorcerer_fireball_volley"
)
@export var ball_source_type_a: StringName = &"fire_sorcerer_fireball_a"
@export var ball_source_type_b: StringName = &"fire_sorcerer_fireball_b"
@export var ball_source_type_c: StringName = &"fire_sorcerer_fireball_c"

@onready var ball_areas: Array[Area2D] = [
	$FireballA,
	$FireballB,
	$FireballC,
]
@onready var ball_sprites: Array[AnimatedSprite2D] = [
	$FireballA/VisualRoot/AnimatedSprite2D,
	$FireballB/VisualRoot/AnimatedSprite2D,
	$FireballC/VisualRoot/AnimatedSprite2D,
]
@onready var ball_emission_sprites: Array[AnimatedSprite2D] = [
	$FireballA/VisualRoot/AnimatedSprite2D/EmissionOverlay,
	$FireballB/VisualRoot/AnimatedSprite2D/EmissionOverlay,
	$FireballC/VisualRoot/AnimatedSprite2D/EmissionOverlay,
]
@onready var ball_collision_shapes: Array[CollisionShape2D] = [
	$FireballA/CollisionShape2D,
	$FireballB/CollisionShape2D,
	$FireballC/CollisionShape2D,
]

var motion_sweep := PROJECTILE_SHAPE_SWEEP_2D_SCRIPT.new()

var direction := Vector2.RIGHT
var damage: int = 1
var remaining_lifetime: float = 7.0
var target: Node2D = null
var target_runtime: CombatRuntimeBase = null
var target_refresh_left: float = 0.0
var projectile_id: int = 0
var owner_peer_id: int = 0
var source_type: StringName = &"fire_sorcerer_fireball_volley"
var damage_source_snapshot: DamageSourceSnapshot = null
var pool_active := true
var combat_runtime: CombatRuntimeBase = null
var gameplay_gateway: MultiplayerGameplayGateway = null
var active_ball_mask: int = ALL_BALLS_ACTIVE_MASK
var visible_effect_mask: int = 0
var ball_directions := PackedVector2Array([
	Vector2.RIGHT,
	Vector2.RIGHT,
	Vector2.RIGHT,
])
var ball_effect_times := PackedFloat32Array([0.0, 0.0, 0.0])
var authored_ball_positions := PackedVector2Array()
var _authored_speed: float = 100.0
var _authored_max_lifetime: float = 7.0
var _authored_homing_turn_rate: float = 6.0
var _authored_burn_duration: float = 5.0
var _authored_burn_level: int = 5
var _pending_setup := false


static func set_performance_metrics_enabled(enabled: bool) -> void:
	performance_metrics_enabled = enabled
	reset_performance_metrics()


static func reset_performance_metrics() -> void:
	_performance_metrics["physics_calls"] = 0
	_performance_metrics["physics_usec"] = 0
	_performance_metrics["active_ball_steps"] = 0
	_performance_metrics["homing_updates"] = 0
	_performance_metrics["compensation_sweep_calls"] = 0


static func get_performance_metrics(reset_after_read := false) -> Dictionary:
	var snapshot := _performance_metrics.duplicate()
	if reset_after_read:
		reset_performance_metrics()
	return snapshot


func _ready() -> void:
	source_type = _get_default_projectile_source_type()
	_authored_speed = speed
	_authored_max_lifetime = max_lifetime
	_authored_homing_turn_rate = homing_turn_rate
	_authored_burn_duration = burn_duration
	_authored_burn_level = burn_level
	motion_sweep.configure(
		ball_collision_shapes[0].shape,
		AUTHORED_COLLISION_MASK
	)
	authored_ball_positions.resize(BALL_COUNT)
	for ball_index in range(BALL_COUNT):
		authored_ball_positions[ball_index] = ball_areas[ball_index].position
		ball_areas[ball_index].body_entered.connect(
			_on_ball_body_entered.bind(ball_index)
		)
	pool_active = not has_meta(SessionObjectPool.POOL_OWNER_META)
	if _pending_setup or pool_active:
		_activate_balls()
	else:
		_disable_all_balls()


func on_pool_acquired(_generation: int) -> void:
	remove_meta(&"damage_source_snapshot")
	combat_runtime = null
	gameplay_gateway = null
	pool_active = true
	speed = _authored_speed
	max_lifetime = _authored_max_lifetime
	homing_turn_rate = _authored_homing_turn_rate
	burn_duration = _authored_burn_duration
	burn_level = _authored_burn_level
	direction = Vector2.RIGHT
	damage = 1
	remaining_lifetime = maxf(max_lifetime, 0.01)
	target = null
	target_runtime = null
	target_refresh_left = 0.0
	projectile_id = 0
	owner_peer_id = 0
	source_type = _get_default_projectile_source_type()
	damage_source_snapshot = null
	_pending_setup = false
	rotation = 0.0
	_activate_balls()
	set_physics_process(true)


func on_pool_released(_generation: int) -> void:
	remove_meta(&"damage_source_snapshot")
	pool_active = false
	target = null
	target_runtime = null
	combat_runtime = null
	gameplay_gateway = null
	damage_source_snapshot = null
	target_refresh_left = 0.0
	active_ball_mask = 0
	visible_effect_mask = 0
	set_physics_process(false)
	_disable_all_balls()


func bind_gameplay_context(
	runtime_context: CombatRuntimeBase,
	gateway: MultiplayerGameplayGateway
) -> void:
	combat_runtime = runtime_context
	gameplay_gateway = gateway
	target_runtime = runtime_context


func setup(
	initial_direction: Vector2,
	initial_damage: int,
	initial_speed: float,
	initial_lifetime: float,
	initial_target: Node2D = null,
	initial_homing_turn_rate: float = 6.0,
	initial_target_runtime: CombatRuntimeBase = null,
	initial_burn_duration: float = -1.0,
	initial_burn_level: int = -1,
	initial_damage_source_snapshot: DamageSourceSnapshot = null
) -> void:
	pool_active = true
	direction = (
		initial_direction.normalized()
		if initial_direction != Vector2.ZERO
		else Vector2.RIGHT
	)
	damage = maxi(initial_damage, 0)
	speed = maxf(initial_speed, 0.0)
	max_lifetime = maxf(initial_lifetime, 0.01)
	remaining_lifetime = max_lifetime
	target = initial_target
	target_runtime = initial_target_runtime
	target_refresh_left = 0.0
	homing_turn_rate = maxf(initial_homing_turn_rate, 0.0)
	if initial_burn_duration >= 0.0:
		burn_duration = maxf(initial_burn_duration, 0.0)
	if initial_burn_level >= 0:
		burn_level = maxi(initial_burn_level, 0)
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
	rotation = direction.angle()
	_pending_setup = true
	if is_node_ready():
		_activate_balls()
		_pending_setup = false
	set_physics_process(true)


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
	if not pool_active:
		return
	var started_usec := (
		Time.get_ticks_usec()
		if FireSorcererFireballVolley.performance_metrics_enabled
		else 0
	)
	_advance_motion(maxf(delta, 0.0))
	_update_effects(maxf(delta, 0.0))
	if FireSorcererFireballVolley.performance_metrics_enabled:
		FireSorcererFireballVolley._performance_metrics["physics_calls"] = (
			int(FireSorcererFireballVolley._performance_metrics["physics_calls"]) + 1
		)
		FireSorcererFireballVolley._performance_metrics["physics_usec"] = (
			int(FireSorcererFireballVolley._performance_metrics["physics_usec"])
			+ maxi(Time.get_ticks_usec() - started_usec, 0)
		)


func simulate_compensated_motion(seconds: float) -> void:
	var time_left := clampf(seconds, 0.0, maxf(remaining_lifetime, 0.0))
	while time_left > 0.0 and active_ball_mask != 0:
		var step := minf(time_left, COMPENSATION_STEP)
		_advance_compensated_ball_positions(step)
		time_left -= step


func _advance_motion(delta: float) -> void:
	if active_ball_mask == 0:
		return
	_update_homing_target(delta)
	_advance_ball_positions(delta)
	remaining_lifetime = maxf(remaining_lifetime - delta, 0.0)
	if remaining_lifetime <= 0.0:
		for ball_index in range(BALL_COUNT):
			if _is_ball_active(ball_index):
				_begin_ball_effect(ball_index, &"expire", EXPIRE_VISUAL_DURATION)


func _update_homing_target(delta: float) -> void:
	if target_runtime == null or not is_instance_valid(target_runtime):
		target_runtime = null
		target_refresh_left = 0.0
		return
	if _is_target_alive():
		target_refresh_left = 0.0
		return
	target = null
	target_refresh_left = maxf(target_refresh_left - delta, 0.0)
	if target_refresh_left > 0.0:
		return
	target_refresh_left = TARGET_REFRESH_INTERVAL
	var query_position := _get_active_ball_center()
	var reachable_distance := maxf(speed * remaining_lifetime, 0.0)
	var refreshed_target := target_runtime.find_nearest_hostile_enemy_attack_target_world(
		query_position,
		reachable_distance,
		_get_frozen_source_faction_id()
	)
	if _is_damage_target_alive(refreshed_target):
		target = refreshed_target
		target_refresh_left = 0.0


func _get_active_ball_center() -> Vector2:
	var position_sum := Vector2.ZERO
	var active_count := 0
	for ball_index in range(BALL_COUNT):
		if not _is_ball_active(ball_index):
			continue
		position_sum += ball_areas[ball_index].global_position
		active_count += 1
	if active_count <= 0:
		return global_position
	return position_sum / float(active_count)


func _advance_ball_positions(delta: float) -> void:
	var target_is_alive := _is_target_alive()
	for ball_index in range(BALL_COUNT):
		if not _is_ball_active(ball_index):
			continue
		var ball_direction := _update_ball_direction(
			ball_index,
			delta,
			target_is_alive
		)
		var ball := ball_areas[ball_index]
		ball.global_position += ball_direction * speed * delta
		ball.global_rotation = ball_direction.angle()


func _advance_compensated_ball_positions(delta: float) -> void:
	if not is_inside_tree():
		_advance_ball_positions(delta)
		return
	var target_is_alive := _is_target_alive()
	for ball_index in range(BALL_COUNT):
		if not _is_ball_active(ball_index):
			continue
		var ball_direction := _update_ball_direction(
			ball_index,
			delta,
			target_is_alive
		)
		var ball := ball_areas[ball_index]
		var start_position := ball.global_position
		var motion_delta := ball_direction * speed * delta
		var end_position := start_position + motion_delta
		if FireSorcererFireballVolley.performance_metrics_enabled:
			FireSorcererFireballVolley._performance_metrics[
				"compensation_sweep_calls"
			] = (
				int(
					FireSorcererFireballVolley._performance_metrics[
						"compensation_sweep_calls"
					]
				) + 1
			)
		var hit_result := motion_sweep.cast(
			get_world_2d().direct_space_state,
			ball_collision_shapes[ball_index].global_transform,
			motion_delta
		)
		if hit_result.is_empty():
			ball.global_position = end_position
			ball.global_rotation = ball_direction.angle()
			continue
		var unsafe_fraction := float(hit_result["fraction"])
		var collider := hit_result.get("collider") as Node2D
		ball.global_position = start_position + motion_delta * unsafe_fraction
		ball.global_rotation = ball_direction.angle()
		if collider != null and is_instance_valid(collider):
			_on_ball_body_entered(collider, ball_index)
		else:
			_begin_ball_effect(
				ball_index,
				&"expire",
				EXPIRE_VISUAL_DURATION
			)


func _update_ball_direction(
	ball_index: int,
	delta: float,
	target_is_alive: bool
) -> Vector2:
	if FireSorcererFireballVolley.performance_metrics_enabled:
		FireSorcererFireballVolley._performance_metrics["active_ball_steps"] = (
			int(
				FireSorcererFireballVolley._performance_metrics[
					"active_ball_steps"
				]
			) + 1
		)
	var ball_direction := ball_directions[ball_index]
	if target_is_alive and homing_turn_rate > 0.0:
		var desired_direction := ball_areas[ball_index].global_position.direction_to(
			target.global_position
		)
		if desired_direction != Vector2.ZERO:
			var angle_delta := ball_direction.angle_to(desired_direction)
			var maximum_turn := homing_turn_rate * delta
			ball_direction = ball_direction.rotated(
				clampf(angle_delta, -maximum_turn, maximum_turn)
			).normalized()
			if FireSorcererFireballVolley.performance_metrics_enabled:
				FireSorcererFireballVolley._performance_metrics[
					"homing_updates"
				] = (
					int(
						FireSorcererFireballVolley._performance_metrics[
							"homing_updates"
						]
					) + 1
				)
	ball_directions[ball_index] = ball_direction
	return ball_direction


func _update_effects(delta: float) -> void:
	if visible_effect_mask == 0:
		if active_ball_mask == 0:
			_retire()
		return
	for ball_index in range(BALL_COUNT):
		var bit := 1 << ball_index
		if (visible_effect_mask & bit) == 0:
			continue
		ball_effect_times[ball_index] = maxf(
			ball_effect_times[ball_index] - delta,
			0.0
		)
		if ball_effect_times[ball_index] > 0.0:
			continue
		visible_effect_mask &= ~bit
		ball_sprites[ball_index].hide()
		ball_emission_sprites[ball_index].hide()
	if active_ball_mask == 0 and visible_effect_mask == 0:
		_retire()


func _on_ball_body_entered(body: Node2D, ball_index: int) -> void:
	if not pool_active or not _is_ball_active(ball_index):
		return
	var player := body as Player
	var plant := body as PlantDefense
	var enemy := body as Enemy
	if player == null and plant == null and enemy == null:
		# 世界接触不造成伤害，但仍要提交共享的首次接触账本，确保同一
		# 网络弹体的其他副本不能在穿墙后继续命中目标。
		_try_consume_multiplayer_contact(ball_index)
		_begin_ball_effect(ball_index, &"expire", EXPIRE_VISUAL_DURATION)
		return
	var request := _make_ball_damage_request(body, ball_index)
	if (
		_has_authoritative_runtime()
		and not _is_request_admitted(request, body)
	):
		# Friendly bodies neither consume the ball nor enter its hit ledger.
		return
	var contact_consumed := _try_consume_multiplayer_contact(ball_index)
	if player != null:
		if contact_consumed and not player.is_dead:
			var handled_by_multiplayer := (
				_try_report_multiplayer_player_hit(
					player,
					ball_index,
					true
				)
			)
			if (
				not handled_by_multiplayer
				and _has_explicit_singleplayer_authority()
			):
				var damage_was_applied := (
					player.apply_combat_damage(request).accepted
				)
				if damage_was_applied and not player.is_dead:
					player.apply_burn_status(
						_get_ball_burn_family(ball_index),
						burn_duration,
						burn_level,
						request.get_source_snapshot_copy()
					)
		_begin_ball_effect(ball_index, &"impact", IMPACT_VISUAL_DURATION)
		return
	if plant != null:
		if (
			contact_consumed
			and _has_authoritative_runtime()
			and not plant.is_dead
			and not plant.is_removing
		):
			var damage_was_applied := (
				plant.apply_combat_damage(request).accepted
			)
			if damage_was_applied and not plant.is_dead and not plant.is_removing:
				plant.apply_burn_status(
					_get_ball_burn_family(ball_index),
					burn_duration,
					burn_level,
					request.get_source_snapshot_copy()
				)
		_begin_ball_effect(ball_index, &"impact", IMPACT_VISUAL_DURATION)
		return
	if enemy != null:
		if contact_consumed and _has_authoritative_runtime() and not enemy.is_dead:
			var damage_was_applied := (
				enemy.apply_combat_damage(request).accepted
			)
			if damage_was_applied and not enemy.is_dead:
				enemy.apply_burn_status(
					_get_ball_burn_family(ball_index),
					burn_duration,
					burn_level,
					request.get_source_snapshot_copy()
				)
		_begin_ball_effect(ball_index, &"impact", IMPACT_VISUAL_DURATION)


func _begin_ball_effect(
	ball_index: int,
	animation_name: StringName,
	duration: float
) -> void:
	if not _is_ball_active(ball_index):
		return
	var bit := 1 << ball_index
	active_ball_mask &= ~bit
	visible_effect_mask |= bit
	ball_effect_times[ball_index] = maxf(duration, 0.01)
	var area := ball_areas[ball_index]
	area.collision_layer = 0
	area.collision_mask = 0
	area.set_deferred("monitoring", false)
	area.set_deferred("monitorable", false)
	ball_collision_shapes[ball_index].set_deferred("disabled", true)
	var sprite := ball_sprites[ball_index]
	sprite.show()
	sprite.stop()
	sprite.frame = 0
	sprite.frame_progress = 0.0
	if (
		sprite.sprite_frames != null
		and sprite.sprite_frames.has_animation(animation_name)
	):
		sprite.play(animation_name)
	_play_emission_animation(ball_index, animation_name)


func _activate_balls() -> void:
	if not is_node_ready():
		return
	active_ball_mask = ALL_BALLS_ACTIVE_MASK
	visible_effect_mask = 0
	remaining_lifetime = maxf(max_lifetime, 0.01)
	motion_sweep.reset_runtime_state()
	for ball_index in range(BALL_COUNT):
		ball_directions[ball_index] = direction
		ball_effect_times[ball_index] = 0.0
		var area := ball_areas[ball_index]
		area.position = authored_ball_positions[ball_index]
		area.rotation = 0.0
		area.collision_layer = AUTHORED_COLLISION_LAYER
		area.collision_mask = AUTHORED_COLLISION_MASK
		area.monitoring = true
		area.monitorable = true
		ball_collision_shapes[ball_index].set_deferred("disabled", false)
		var sprite := ball_sprites[ball_index]
		sprite.show()
		sprite.stop()
		sprite.frame = 0
		sprite.frame_progress = 0.0
		if (
			sprite.sprite_frames != null
			and sprite.sprite_frames.has_animation(&"fly")
		):
			sprite.play(&"fly")
		_play_emission_animation(ball_index, &"fly")


func _disable_all_balls() -> void:
	if not is_node_ready():
		return
	for ball_index in range(BALL_COUNT):
		var area := ball_areas[ball_index]
		area.collision_layer = 0
		area.collision_mask = 0
		area.set_deferred("monitoring", false)
		area.set_deferred("monitorable", false)
		ball_collision_shapes[ball_index].set_deferred("disabled", true)
		ball_sprites[ball_index].stop()
		ball_sprites[ball_index].hide()
		ball_emission_sprites[ball_index].stop()
		ball_emission_sprites[ball_index].hide()


func _play_emission_animation(
	ball_index: int,
	animation_name: StringName
) -> void:
	var emission := ball_emission_sprites[ball_index]
	emission.show()
	emission.stop()
	emission.frame = 0
	emission.frame_progress = 0.0
	if (
		emission.sprite_frames != null
		and emission.sprite_frames.has_animation(animation_name)
	):
		emission.play(animation_name)


func _is_ball_active(ball_index: int) -> bool:
	return (active_ball_mask & (1 << ball_index)) != 0


func _is_target_alive() -> bool:
	return _is_damage_target_alive(target)


func _is_damage_target_alive(candidate: Node2D) -> bool:
	if candidate == null or not is_instance_valid(candidate):
		return false
	var player := candidate as Player
	if player != null:
		return (
			not player.is_dead
			and not player.is_queued_for_deletion()
			and _is_frozen_source_hostile_to(candidate)
		)
	var plant := candidate as PlantDefense
	if plant != null:
		return (
			not plant.is_dead
			and not plant.is_removing
			and not plant.is_queued_for_deletion()
			and _is_frozen_source_hostile_to(candidate)
		)
	var enemy := candidate as Enemy
	return (
		enemy != null
		and not enemy.is_dead
		and not enemy.is_queued_for_deletion()
		and _is_frozen_source_hostile_to(candidate)
	)


func _get_frozen_source_faction_id() -> int:
	if damage_source_snapshot != null:
		return damage_source_snapshot.source_faction_id
	# Compatibility for locally-authored/projectile tests created before source
	# snapshots were mandatory. Production enemy volleys always carry a frozen
	# snapshot from FireSorcerer at launch.
	return CombatRelationService.HOSTILE_WAVE


func _is_frozen_source_hostile_to(candidate: Node2D) -> bool:
	var runtime := target_runtime
	if runtime == null or not is_instance_valid(runtime):
		runtime = combat_runtime
	if runtime != null and is_instance_valid(runtime):
		return runtime.get_combat_query_facade().is_target_hostile(
			_get_frozen_source_faction_id(),
			candidate,
			runtime.get_combat_relation_service()
		)
	var target_faction_id := CombatRelationService.NEUTRAL
	var player_target := candidate as Player
	if player_target != null:
		target_faction_id = player_target.get_combat_faction_id()
	else:
		var plant_target := candidate as PlantDefense
		if plant_target != null:
			target_faction_id = plant_target.get_combat_faction_id()
		else:
			var enemy_target := candidate as Enemy
			if enemy_target != null:
				target_faction_id = enemy_target.get_combat_faction_id()
	return CombatRelationService.is_default_hostile(
		_get_frozen_source_faction_id(),
		target_faction_id
	)


func _try_report_multiplayer_player_hit(
	player: Player,
	ball_index: int,
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
		_get_ball_source_type(ball_index),
		EnemyConfig.DamageType.MAGIC,
		player.global_position.direction_to(
			ball_areas[ball_index].global_position
		),
		true,
		contact_preconsumed,
		_make_ball_source_snapshot(ball_index)
	)


func _make_ball_damage_request(
	target_body: Node2D,
	ball_index: int
) -> DamageRequest:
	var impact_direction := ball_areas[ball_index].global_position.direction_to(
		target_body.global_position
	)
	var request := DamageRequest.new(damage, EnemyConfig.DamageType.MAGIC)
	if damage_source_snapshot != null:
		request.with_source_snapshot(_make_ball_source_snapshot(ball_index))
	else:
		request.with_source(self, projectile_id, _get_ball_source_type(ball_index))
	request.with_directions(impact_direction, -impact_direction)
	request.with_flag(CombatTypes.DamageFlag.RANGED, true)
	return request


func _make_ball_source_snapshot(
	ball_index: int
) -> DamageSourceSnapshot:
	if damage_source_snapshot == null:
		return null
	return DamageSourceSnapshot.create(
		damage_source_snapshot.source_faction_id,
		damage_source_snapshot.credit_peer_id,
		damage_source_snapshot.instigator_entity_id,
		damage_source_snapshot.event_source_id,
		_get_ball_source_type(ball_index)
	)


func _get_ball_burn_family(_ball_index: int) -> StringName:
	# `source_type` is the authored volley family; A/B/C are contact subtypes.
	# Keep status refresh grouping on the family without importing the global
	# attack registry here (it preloads this projectile scene).
	return source_type


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


func _try_consume_multiplayer_contact(ball_index: int) -> bool:
	if projectile_id <= 0:
		return true
	if gameplay_gateway == null or not is_instance_valid(gameplay_gateway):
		return false
	return gameplay_gateway.try_consume_fire_sorcerer_fireball_contact(
		projectile_id,
		_get_ball_source_type(ball_index)
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


func _get_default_projectile_source_type() -> StringName:
	return projectile_source_type


func _get_ball_source_type(ball_index: int) -> StringName:
	match ball_index:
		0:
			return ball_source_type_a
		1:
			return ball_source_type_b
		2:
			return ball_source_type_c
		_:
			return &""


func _retire() -> void:
	if not pool_active:
		return
	pool_active = false
	set_physics_process(false)
	projectile_finished.emit(projectile_id, self)
	remove_meta(&"damage_source_snapshot")
	damage_source_snapshot = null
	if SessionObjectPool.release_to_owner(self):
		return
	queue_free()
