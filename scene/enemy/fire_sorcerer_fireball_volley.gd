extends Node2D
class_name FireSorcererFireballVolley

signal projectile_finished(projectile_id: int, projectile: Node)

const BALL_COUNT := 3
const ALL_BALLS_ACTIVE_MASK := (1 << BALL_COUNT) - 1
const WORLD_COLLISION_MASK := 1
const DAMAGEABLE_COLLISION_MASK := 2 | 512
const AUTHORED_COLLISION_LAYER := 128
const AUTHORED_COLLISION_MASK := WORLD_COLLISION_MASK | DAMAGEABLE_COLLISION_MASK
const IMPACT_VISUAL_DURATION := 4.0 / 12.0
const EXPIRE_VISUAL_DURATION := 4.0 / 12.0
const COMPENSATION_STEP := 1.0 / 60.0
const TARGET_REFRESH_INTERVAL := 0.35
const TARGET_QUERY_METHOD := &"find_nearest_enemy_attack_target"
static var performance_metrics_enabled := false
static var _performance_metrics := {
	"physics_calls": 0,
	"physics_usec": 0,
	"active_ball_steps": 0,
	"homing_updates": 0,
	"compensation_sweep_calls": 0,
}
static var _compensation_ray_query: PhysicsRayQueryParameters2D = null

@export var speed: float = 125.0
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
@onready var ball_collision_shapes: Array[CollisionShape2D] = [
	$FireballA/CollisionShape2D,
	$FireballB/CollisionShape2D,
	$FireballC/CollisionShape2D,
]

var direction := Vector2.RIGHT
var damage: int = 1
var remaining_lifetime: float = 7.0
var target: Node2D = null
var target_runtime: Node = null
var target_refresh_left: float = 0.0
var projectile_id: int = 0
var owner_peer_id: int = 0
var source_type: StringName = &"fire_sorcerer_fireball_volley"
var pool_active := true
var active_ball_mask: int = ALL_BALLS_ACTIVE_MASK
var visible_effect_mask: int = 0
var ball_directions := PackedVector2Array([
	Vector2.RIGHT,
	Vector2.RIGHT,
	Vector2.RIGHT,
])
var ball_effect_times := PackedFloat32Array([0.0, 0.0, 0.0])
var authored_ball_positions := PackedVector2Array()
var _authored_speed: float = 125.0
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


static func _get_compensation_ray_query() -> PhysicsRayQueryParameters2D:
	if _compensation_ray_query == null:
		_compensation_ray_query = PhysicsRayQueryParameters2D.create(
			Vector2.ZERO,
			Vector2.ZERO,
			AUTHORED_COLLISION_MASK
		)
		_compensation_ray_query.collide_with_bodies = true
		_compensation_ray_query.collide_with_areas = false
		_compensation_ray_query.hit_from_inside = true
	return _compensation_ray_query


func _ready() -> void:
	source_type = _get_default_projectile_source_type()
	_authored_speed = speed
	_authored_max_lifetime = max_lifetime
	_authored_homing_turn_rate = homing_turn_rate
	_authored_burn_duration = burn_duration
	_authored_burn_level = burn_level
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
	_pending_setup = false
	rotation = 0.0
	_activate_balls()
	set_physics_process(true)


func on_pool_released(_generation: int) -> void:
	pool_active = false
	target = null
	target_runtime = null
	target_refresh_left = 0.0
	active_ball_mask = 0
	visible_effect_mask = 0
	set_physics_process(false)
	_disable_all_balls()


func setup(
	initial_direction: Vector2,
	initial_damage: int,
	initial_speed: float,
	initial_lifetime: float,
	initial_target: Node2D = null,
	initial_homing_turn_rate: float = 6.0,
	initial_target_runtime: Node = null,
	initial_burn_duration: float = -1.0,
	initial_burn_level: int = -1
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
	target_runtime = (
		initial_target_runtime
		if (
			initial_target_runtime != null
			and initial_target_runtime.has_method(TARGET_QUERY_METHOD)
		)
		else null
	)
	target_refresh_left = 0.0
	homing_turn_rate = maxf(initial_homing_turn_rate, 0.0)
	if initial_burn_duration >= 0.0:
		burn_duration = maxf(initial_burn_duration, 0.0)
	if initial_burn_level >= 0:
		burn_level = maxi(initial_burn_level, 0)
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
	var refreshed_target := target_runtime.call(
		TARGET_QUERY_METHOD,
		query_position,
		reachable_distance
	) as Node2D
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
	var direct_space_state := get_world_2d().direct_space_state
	var query := FireSorcererFireballVolley._get_compensation_ray_query()
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
		var end_position := start_position + ball_direction * speed * delta
		query.from = start_position
		query.to = end_position
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
		var hit_result := direct_space_state.intersect_ray(query)
		if hit_result.is_empty():
			ball.global_position = end_position
			ball.global_rotation = ball_direction.angle()
			continue
		ball.global_position = hit_result.get("position", start_position)
		ball.global_rotation = ball_direction.angle()
		var collider := hit_result.get("collider") as Node2D
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
	if active_ball_mask == 0 and visible_effect_mask == 0:
		_retire()


func _on_ball_body_entered(body: Node2D, ball_index: int) -> void:
	if not pool_active or not _is_ball_active(ball_index):
		return
	var contact_consumed := _try_consume_multiplayer_contact(ball_index)
	var player := body as Player
	if player != null:
		if contact_consumed and not player.is_dead:
			var handled_by_multiplayer := (
				_try_report_multiplayer_player_hit(
					player,
					ball_index,
					true
				)
			)
			if not handled_by_multiplayer:
				var damage_was_applied := player.apply_damage(
					damage,
					EnemyConfig.DamageType.MAGIC,
					{
						"is_ranged": true,
						"source_direction": (
							player.global_position.direction_to(
								ball_areas[ball_index].global_position
							)
						),
					}
				)
				if damage_was_applied and not player.is_dead:
					player.apply_burn_status(
						source_type,
						burn_duration,
						burn_level
					)
		_begin_ball_effect(ball_index, &"impact", IMPACT_VISUAL_DURATION)
		return
	var plant := body as PlantDefense
	if plant != null:
		if (
			contact_consumed
			and not plant.is_dead
			and not plant.is_removing
		):
			var damage_was_applied := plant.receive_damage(
				damage,
				self,
				ball_areas[ball_index].global_position.direction_to(
					plant.global_position
				),
				EnemyConfig.DamageType.MAGIC
			)
			if damage_was_applied and not plant.is_dead and not plant.is_removing:
				plant.apply_burn_status(
					source_type,
					burn_duration,
					burn_level
				)
		_begin_ball_effect(ball_index, &"impact", IMPACT_VISUAL_DURATION)
		return
	# 世界碰撞只熄灭当前火球，不产生范围查询或伤害。
	_begin_ball_effect(ball_index, &"expire", EXPIRE_VISUAL_DURATION)


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


func _activate_balls() -> void:
	if not is_node_ready():
		return
	active_ball_mask = ALL_BALLS_ACTIVE_MASK
	visible_effect_mask = 0
	remaining_lifetime = maxf(max_lifetime, 0.01)
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


func _is_ball_active(ball_index: int) -> bool:
	return (active_ball_mask & (1 << ball_index)) != 0


func _is_target_alive() -> bool:
	return _is_damage_target_alive(target)


func _is_damage_target_alive(candidate: Node2D) -> bool:
	if candidate == null or not is_instance_valid(candidate):
		return false
	var player := candidate as Player
	if player != null:
		return not player.is_dead
	var plant := candidate as PlantDefense
	return plant != null and not plant.is_dead and not plant.is_removing


func _try_report_multiplayer_player_hit(
	player: Player,
	ball_index: int,
	contact_preconsumed: bool
) -> bool:
	if projectile_id <= 0:
		return false
	var current_scene := get_tree().current_scene
	if (
		current_scene == null
		or not current_scene.has_method("request_multiplayer_player_damage")
	):
		return false
	return bool(current_scene.call(
		"request_multiplayer_player_damage",
		projectile_id,
		player.peer_id,
		damage,
		_get_ball_source_type(ball_index),
		EnemyConfig.DamageType.MAGIC,
		player.global_position.direction_to(
			ball_areas[ball_index].global_position
		),
		true,
		contact_preconsumed
	))


func _try_consume_multiplayer_contact(ball_index: int) -> bool:
	if projectile_id <= 0:
		return true
	var current_scene := get_tree().current_scene
	if (
		current_scene == null
		or not current_scene.has_method(
			"try_consume_fire_sorcerer_fireball_contact"
		)
	):
		return false
	return bool(current_scene.call(
		"try_consume_fire_sorcerer_fireball_contact",
		projectile_id,
		_get_ball_source_type(ball_index)
	))


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
	if SessionObjectPool.release_to_owner(self):
		return
	queue_free()
