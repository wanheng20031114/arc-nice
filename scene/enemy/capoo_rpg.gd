extends Enemy
class_name CapooRPG

const WORLD_COLLISION_MASK := 1
const XIRANG_DROP_SCENE := preload("res://scene/xirang_drop.tscn")
const PICKUP_SCENE := preload("res://scene/pickup.tscn")
const CapooRPGConfigScript := preload("res://resources/config/enemies/capoo_rpg_config.gd")

enum CombatState {
	CHASE,
	WINDUP,
	FIRE,
}

@export var path_refresh_interval: float = 0.25
@export var waypoint_arrival_distance: float = 6.0
@export var direct_chase_extra_distance: float = 2.0

@onready var muzzle_heat: Polygon2D = $MuzzleHeat
@onready var attack_audio: AudioStreamPlayer2D = $AttackAudio

var random_generator := RandomNumberGenerator.new()
var combat_state: CombatState = CombatState.CHASE
var attack_cooldown_left: float = 0.0
var windup_time_left: float = 0.0
var fire_time_left: float = 0.0
var fire_direction := Vector2.RIGHT
var action_sequence: int = 0
var latest_proxy_action_id: int = 0
var current_path: PackedVector2Array = PackedVector2Array()
var current_path_index: int = 0
var path_refresh_time_left: float = 0.0


func _ready() -> void:
	super._ready()
	random_generator.randomize()
	_set_muzzle_heat(0.0, Vector2.RIGHT)


func _physics_process(delta: float) -> void:
	_update_hurt_blink(delta)
	_update_touch_damage(delta)
	_update_attack_cooldown(delta)

	if is_dead:
		velocity = Vector2.ZERO
		return

	match combat_state:
		CombatState.WINDUP:
			_update_windup(delta)
			return
		CombatState.FIRE:
			_update_fire(delta)
			return

	if not is_instance_valid(target_player):
		velocity = Vector2.ZERO
		move_and_slide()
		return

	if _try_start_windup():
		return

	var move_direction := _get_navigation_move_direction(delta)
	_update_facing(move_direction)
	velocity = move_direction * _get_move_speed()
	move_and_slide()


func _apply_config() -> void:
	super._apply_config()
	combat_state = CombatState.CHASE
	attack_cooldown_left = 0.0
	windup_time_left = 0.0
	fire_time_left = 0.0

	var rpg_config := config as CapooRPGConfigScript
	if rpg_config != null:
		attack_audio.stream = rpg_config.attack_audio_stream
		_set_muzzle_heat(0.0, Vector2.RIGHT)


func _die() -> void:
	combat_state = CombatState.CHASE
	_set_muzzle_heat(0.0, fire_direction)
	call_deferred("_drop_xirang")
	_try_drop_pickup()
	super._die()


func _update_attack_cooldown(delta: float) -> void:
	if attack_cooldown_left <= 0.0:
		return
	attack_cooldown_left = maxf(attack_cooldown_left - delta, 0.0)


func _try_start_windup() -> bool:
	var rpg_config := config as CapooRPGConfigScript
	if rpg_config == null:
		return false
	if attack_cooldown_left > 0.0:
		return false
	if not is_instance_valid(target_player):
		return false
	if rpg_config.projectile_scene == null:
		return false
	if global_position.distance_to(target_player.global_position) > rpg_config.attack_range:
		return false
	if not _has_clear_world_line_to_target():
		return false

	combat_state = CombatState.WINDUP
	windup_time_left = maxf(rpg_config.attack_windup, 0.0)
	fire_direction = global_position.direction_to(target_player.global_position)
	if fire_direction == Vector2.ZERO:
		fire_direction = Vector2.RIGHT
	velocity = Vector2.ZERO
	_clear_navigation_path()
	_update_facing(fire_direction)
	_play_config_animation(rpg_config.windup_animation_name)
	_set_muzzle_heat(0.15, fire_direction)
	_broadcast_enemy_action(&"windup", fire_direction)
	return true


func _update_windup(delta: float) -> void:
	var rpg_config := config as CapooRPGConfigScript
	if rpg_config == null or not is_instance_valid(target_player):
		_cancel_attack()
		return

	velocity = Vector2.ZERO
	fire_direction = global_position.direction_to(target_player.global_position)
	if fire_direction == Vector2.ZERO:
		fire_direction = Vector2.RIGHT
	_update_facing(fire_direction)
	windup_time_left = maxf(windup_time_left - delta, 0.0)
	var progress := 1.0 - (windup_time_left / maxf(rpg_config.attack_windup, 0.001))
	_set_muzzle_heat(progress, fire_direction)

	if windup_time_left > 0.0:
		return
	if not _has_clear_world_line_to_target():
		_cancel_attack()
		return

	_start_fire(fire_direction)


func _start_fire(direction: Vector2) -> void:
	var rpg_config := config as CapooRPGConfigScript
	if rpg_config == null:
		_cancel_attack()
		return

	combat_state = CombatState.FIRE
	fire_time_left = 0.18
	fire_direction = direction.normalized() if direction != Vector2.ZERO else Vector2.RIGHT
	attack_cooldown_left = maxf(rpg_config.attack_interval, 0.01)
	velocity = Vector2.ZERO
	_update_facing(fire_direction)
	_play_config_animation(rpg_config.attack_animation_name)
	_set_muzzle_heat(1.0, fire_direction)
	_fire_rocket()
	_broadcast_enemy_action(&"fire", fire_direction)
	if rpg_config.attack_audio_stream != null:
		attack_audio.pitch_scale = random_generator.randf_range(0.96, 1.04)
		attack_audio.play()


func _update_fire(delta: float) -> void:
	velocity = Vector2.ZERO
	_update_facing(fire_direction)
	fire_time_left = maxf(fire_time_left - delta, 0.0)
	_set_muzzle_heat(fire_time_left / 0.18, fire_direction)
	if fire_time_left <= 0.0:
		_finish_fire()


func _fire_rocket() -> bool:
	var rpg_config := config as CapooRPGConfigScript
	if rpg_config == null or rpg_config.projectile_scene == null:
		return false

	var rocket := rpg_config.projectile_scene.instantiate() as CapooRPGRocket
	if rocket == null:
		push_warning("Capoo RPG projectile scene must instantiate CapooRPGRocket.")
		return false

	var spawn_parent := get_tree().current_scene
	if spawn_parent == null:
		rocket.queue_free()
		return false

	rocket.top_level = true
	rocket.setup(
		fire_direction,
		rpg_config.attack_damage,
		rpg_config.projectile_speed,
		rpg_config.projectile_lifetime,
		rpg_config.explosion_radius
	)
	spawn_parent.add_child(rocket)
	rocket.global_position = global_position + fire_direction * rpg_config.projectile_spawn_distance
	if spawn_parent.has_method("register_local_projectile"):
		spawn_parent.call(
			"register_local_projectile",
			rocket,
			&"capoo_rpg_rocket",
			0,
			rocket.global_position,
			fire_direction,
			rpg_config.attack_damage,
			rpg_config.projectile_speed,
			rpg_config.projectile_lifetime
		)
	return true


func _finish_fire() -> void:
	combat_state = CombatState.CHASE
	fire_time_left = 0.0
	_set_muzzle_heat(0.0, fire_direction)
	var rpg_config := config as CapooRPGConfigScript
	if rpg_config != null:
		_play_config_animation(rpg_config.move_animation_name)


func _cancel_attack() -> void:
	combat_state = CombatState.CHASE
	windup_time_left = 0.0
	fire_time_left = 0.0
	_set_muzzle_heat(0.0, fire_direction)


func play_multiplayer_enemy_action(action_name: StringName, direction: Vector2, action_id: int) -> void:
	if action_id <= latest_proxy_action_id:
		return
	latest_proxy_action_id = action_id
	var safe_direction := direction.normalized() if direction != Vector2.ZERO else Vector2.RIGHT
	var rpg_config := config as CapooRPGConfigScript
	if action_name == &"windup":
		if rpg_config != null:
			_play_multiplayer_proxy_action_animation(
				rpg_config.windup_animation_name,
				rpg_config.attack_windup + 0.15
			)
			_play_proxy_muzzle_heat(safe_direction, rpg_config.attack_windup)
		_update_facing(safe_direction)
	elif action_name == &"fire":
		if rpg_config != null:
			_play_multiplayer_proxy_action_animation(
				rpg_config.attack_animation_name,
				0.23
			)
		_update_facing(safe_direction)
		_set_muzzle_heat(1.0, safe_direction)
		var tween := create_tween()
		tween.tween_method(
			func(progress: float) -> void:
				_set_muzzle_heat(progress, safe_direction),
			1.0,
			0.0,
			0.18
		)


func _play_proxy_muzzle_heat(direction: Vector2, duration: float) -> void:
	_set_muzzle_heat(0.15, direction)
	var tween := create_tween()
	tween.tween_method(
		func(progress: float) -> void:
			_set_muzzle_heat(progress, direction),
		0.15,
		1.0,
		maxf(duration, 0.01)
	)


func _broadcast_enemy_action(action_name: StringName, direction: Vector2) -> void:
	action_sequence += 1
	var current_scene := get_tree().current_scene
	if current_scene != null and current_scene.has_method("broadcast_enemy_action"):
		current_scene.call(
			"broadcast_enemy_action",
			int(get_meta("net_id", 0)),
			action_name,
			direction,
			global_position,
			action_sequence
		)


func _has_clear_world_line_to_target() -> bool:
	if not is_instance_valid(target_player):
		return false

	var query := PhysicsRayQueryParameters2D.create(
		global_position,
		target_player.global_position,
		WORLD_COLLISION_MASK,
		[get_rid()]
	)
	query.collide_with_bodies = true
	query.collide_with_areas = false
	return get_world_2d().direct_space_state.intersect_ray(query).is_empty()


func _get_move_speed() -> float:
	return config.move_speed if config != null else 0.0


func _get_navigation_move_direction(delta: float) -> Vector2:
	path_refresh_time_left = maxf(path_refresh_time_left - delta, 0.0)

	if _should_direct_chase_target():
		var direct_move_direction := _get_shape_safe_move_direction_to_target(target_player)
		if direct_move_direction != Vector2.ZERO:
			_clear_navigation_path()
			return direct_move_direction
		path_refresh_time_left = minf(path_refresh_time_left, _get_navigation_retry_interval())

	if pathfinder == null or not pathfinder.get("is_built"):
		return _get_shape_safe_move_direction_to_target(target_player)

	var flow_direction := _get_shared_flow_navigation_direction(target_player, pathfinder)
	if flow_direction != Vector2.ZERO:
		_clear_navigation_path()
		return flow_direction

	if path_refresh_time_left <= 0.0 or current_path.is_empty():
		_refresh_navigation_path()

	if current_path.is_empty():
		return _get_navigation_fallback_move_direction()

	while current_path_index < current_path.size():
		var waypoint := current_path[current_path_index]
		if global_position.distance_to(waypoint) > waypoint_arrival_distance:
			return _get_axis_aligned_waypoint_direction(waypoint, waypoint_arrival_distance)
		current_path_index += 1

	return _get_navigation_fallback_move_direction()


func _refresh_navigation_path() -> void:
	if pathfinder.has_method("try_get_global_path"):
		var path_result: Variant = pathfinder.call(
			"try_get_global_path",
			global_position,
			target_player.global_position,
			_get_body_collision_half_extents()
		)
		if path_result == null:
			path_refresh_time_left = _get_navigation_retry_interval()
			return
		current_path = path_result
	else:
		current_path = pathfinder.get_global_path(global_position, target_player.global_position, _get_body_collision_half_extents())
	path_refresh_time_left = _get_navigation_refresh_interval()
	current_path_index = 0


func _get_navigation_refresh_interval() -> float:
	return maxf(path_refresh_interval, 0.05) * random_generator.randf_range(0.75, 1.25)


func _get_navigation_retry_interval() -> float:
	return random_generator.randf_range(0.03, 0.08)


func _clear_navigation_path() -> void:
	current_path = PackedVector2Array()
	current_path_index = 0
	path_refresh_time_left = 0.0


func _get_navigation_fallback_move_direction() -> Vector2:
	if _has_clear_world_line_to_target():
		var direct_direction := _get_shape_safe_move_direction_to_target(target_player)
		if direct_direction != Vector2.ZERO:
			return direct_direction
	path_refresh_time_left = minf(path_refresh_time_left, _get_navigation_retry_interval())
	return Vector2.ZERO


func _should_direct_chase_target() -> bool:
	var direct_chase_distance := _get_body_extent_radius() + _get_target_extent_radius() + direct_chase_extra_distance
	if global_position.distance_to(target_player.global_position) > direct_chase_distance:
		return false
	return _has_clear_world_line_to_target()


func _get_body_extent_radius() -> float:
	return _get_body_collision_extent_radius()


func _get_target_extent_radius() -> float:
	var target_collision_shape := target_player.get_node_or_null("CollisionShape2D") as CollisionShape2D
	if target_collision_shape == null:
		return 0.0
	return _get_collision_shape_extent_radius(target_collision_shape)


func _update_facing(move_direction: Vector2) -> void:
	if is_zero_approx(move_direction.x):
		return
	_set_facing_from_direction(move_direction)


func _play_config_animation(animation_name: StringName) -> void:
	_play_scene_animation(animation_name)


func _set_muzzle_heat(progress: float, direction: Vector2) -> void:
	var clamped_progress := clampf(progress, 0.0, 1.0)
	muzzle_heat.visible = clamped_progress > 0.0
	if not muzzle_heat.visible:
		return

	var safe_direction := direction.normalized() if direction != Vector2.ZERO else Vector2.RIGHT
	muzzle_heat.position = safe_direction * 14.0
	muzzle_heat.rotation = safe_direction.angle()
	muzzle_heat.scale = Vector2.ONE * lerpf(0.75, 1.55, clamped_progress)
	muzzle_heat.color = Color(1.0, lerpf(0.28, 0.78, clamped_progress), 0.08, lerpf(0.18, 0.74, clamped_progress))


func _drop_xirang() -> void:
	if config == null or config.xirang_drop_amount <= 0:
		return
	if not is_instance_valid(target_player):
		return
	var drop_parent := get_parent()
	if drop_parent == null:
		return
	var drop := XIRANG_DROP_SCENE.instantiate() as XirangDrop
	if drop == null:
		return
	drop_parent.add_child(drop)
	drop.setup(config.xirang_drop_amount, target_player, global_position, Vector2.ZERO)


func _try_drop_pickup() -> void:
	if config == null or config.pickup_drop_configs.is_empty():
		return
	if random_generator.randf() > config.pickup_drop_chance:
		return
	var pickup_config := _pick_pickup_drop_config()
	if pickup_config != null:
		call_deferred("_spawn_dropped_pickup", pickup_config, global_position)


func _pick_pickup_drop_config() -> PickupConfig:
	var available_pickup_configs: Array[PickupConfig] = []
	var total_weight := 0.0
	for pickup_config in config.pickup_drop_configs:
		if pickup_config == null or pickup_config.drop_weight <= 0.0:
			continue
		available_pickup_configs.append(pickup_config)
		total_weight += pickup_config.drop_weight
	if available_pickup_configs.is_empty() or total_weight <= 0.0:
		return null
	var target_weight := random_generator.randf_range(0.0, total_weight)
	var accumulated_weight := 0.0
	for pickup_config in available_pickup_configs:
		accumulated_weight += pickup_config.drop_weight
		if target_weight <= accumulated_weight:
			return pickup_config
	return available_pickup_configs.back()


func _spawn_dropped_pickup(pickup_config: PickupConfig, spawn_position: Vector2) -> void:
	var drop_parent := get_parent()
	if drop_parent == null:
		return
	var pickup_instance := PICKUP_SCENE.instantiate() as Pickup
	if pickup_instance == null:
		return
	pickup_instance.config = pickup_config
	drop_parent.add_child(pickup_instance)
	pickup_instance.global_position = spawn_position
