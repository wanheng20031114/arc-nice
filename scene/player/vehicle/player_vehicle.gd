extends PlayerWeishidaier
class_name PlayerVehicle

const MAX_VEHICLE_SPEED := 100.0
const ACCELERATION_TO_MAX_DURATION := 1.0
const BRAKE_TO_STOP_DURATION := 0.20
const COAST_TO_STOP_DURATION := 0.45
const STEERING_SPEED_RADIANS := deg_to_rad(150.0)
const MUZZLE_DISTANCE := 12.0
const MIN_SPEED_EPSILON := 0.01
const PAINT_COLOR_SHADER_PARAMETER := &"paint_color"

@onready var muzzle_pivot: Node2D = $MuzzlePivot
@onready var muzzle: Marker2D = $MuzzlePivot/Muzzle

var heading := Vector2.RIGHT
var longitudinal_speed := 0.0


func _init() -> void:
	character_id = PlayerCharacterRegistry.VEHICLE_ID


func _ready() -> void:
	super._ready()
	_apply_selected_paint_color()
	_sync_vehicle_visuals()


func _apply_character_pickup(config: PickupConfig, buff_duration: float) -> bool:
	var applied := super._apply_character_pickup(config, buff_duration)
	if applied and current_shot_pattern == PickupConfig.ShotPattern.SPIRAL:
		current_shot_pattern = PickupConfig.ShotPattern.NORMAL
	return applied


func _physics_process(delta: float) -> void:
	super._physics_process(delta)
	if is_dead or controls_locked:
		longitudinal_speed = 0.0
		return
	if get_slide_collision_count() > 0:
		var collision_limited_speed := velocity.dot(heading)
		if absf(collision_limited_speed) < absf(longitudinal_speed):
			longitudinal_speed = collision_limited_speed


func _get_current_move_input() -> Vector2:
	var throttle_input := 0.0
	var steering_input := 0.0
	if uses_local_input:
		throttle_input = Input.get_axis(&"move_down", &"move_up")
		steering_input = Input.get_axis(&"move_left", &"move_right")
	else:
		throttle_input = clampf(network_move_input.dot(heading), -1.0, 1.0)

	var delta := get_physics_process_delta_time()
	_step_heading(steering_input, delta)
	var effective_move_speed := maxf(_get_effective_move_speed(), MIN_SPEED_EPSILON)
	var allowed_max_speed := minf(MAX_VEHICLE_SPEED, effective_move_speed)
	_step_longitudinal_speed(throttle_input, allowed_max_speed, delta)
	_sync_vehicle_visuals()
	return heading * (longitudinal_speed / effective_move_speed)


func _get_current_shoot_input() -> Vector2:
	var wants_to_shoot := (
		Input.get_vector(&"shoot_left", &"shoot_right", &"shoot_up", &"shoot_down")
		if uses_local_input
		else network_shoot_input
	)
	return heading if wants_to_shoot != Vector2.ZERO else Vector2.ZERO


func _get_mouse_shoot_direction() -> Vector2:
	return heading


func _handle_primary_attack_input(shoot_input: Vector2) -> void:
	if are_combat_actions_locked():
		return
	if shoot_input != Vector2.ZERO:
		_try_shoot(heading)


func _fire_bullets(_base_direction: Vector2) -> bool:
	var has_spawned_bullet := _spawn_bullet(heading)
	if has_spawned_bullet:
		notify_primary_attack_performed()
	return has_spawned_bullet


func _get_muzzle_distance() -> float:
	return muzzle.position.x if muzzle != null else MUZZLE_DISTANCE


func _try_start_dash(_move_direction: Vector2) -> bool:
	return false


func is_dash_ready() -> bool:
	return false


func _on_controls_lock_changed(locked: bool) -> void:
	super._on_controls_lock_changed(locked)
	if locked:
		longitudinal_speed = 0.0


func _cleanup_character_combat_on_death() -> void:
	super._cleanup_character_combat_on_death()
	longitudinal_speed = 0.0


func _clear_character_scene_transients() -> void:
	super._clear_character_scene_transients()
	longitudinal_speed = 0.0


func _reset_character_resources_on_revive() -> void:
	super._reset_character_resources_on_revive()
	longitudinal_speed = 0.0


func _play_death_animation() -> void:
	longitudinal_speed = 0.0
	body_sprite.stop()
	body_sprite.hide()


func _update_armed_effect() -> void:
	if armed_effect_sprite == null:
		return
	armed_effect_sprite.hide()
	armed_effect_sprite.stop()


func _update_facing(_move_input: Vector2, _shoot_input: Vector2) -> void:
	facing_suffix = _vector_to_facing_suffix(heading)
	_sync_vehicle_visuals()


func _step_heading(steering_input: float, delta: float) -> void:
	if absf(steering_input) <= MIN_SPEED_EPSILON or delta <= 0.0:
		return
	heading = heading.rotated(
		clampf(steering_input, -1.0, 1.0)
		* STEERING_SPEED_RADIANS
		* delta
	).normalized()


func _step_longitudinal_speed(
	throttle_input: float,
	allowed_max_speed: float,
	delta: float
) -> void:
	var safe_max_speed := clampf(allowed_max_speed, 0.0, MAX_VEHICLE_SPEED)
	var safe_delta := maxf(delta, 0.0)
	var normalized_throttle := clampf(throttle_input, -1.0, 1.0)
	if absf(normalized_throttle) <= MIN_SPEED_EPSILON:
		longitudinal_speed = move_toward(
			longitudinal_speed,
			0.0,
			(MAX_VEHICLE_SPEED / COAST_TO_STOP_DURATION) * safe_delta
		)
		return

	var requested_direction := signf(normalized_throttle)
	if (
		absf(longitudinal_speed) > MIN_SPEED_EPSILON
		and signf(longitudinal_speed) != requested_direction
	):
		longitudinal_speed = move_toward(
			longitudinal_speed,
			0.0,
			(MAX_VEHICLE_SPEED / BRAKE_TO_STOP_DURATION) * safe_delta
		)
		return

	var target_speed := requested_direction * safe_max_speed
	longitudinal_speed = move_toward(
		longitudinal_speed,
		target_speed,
		(MAX_VEHICLE_SPEED / ACCELERATION_TO_MAX_DURATION) * safe_delta
	)


func _sync_vehicle_visuals() -> void:
	if heading == Vector2.ZERO:
		heading = Vector2.RIGHT
	var heading_rotation := heading.angle()
	if body_sprite != null:
		body_sprite.rotation = heading_rotation
	if grass_healing_particles != null:
		grass_healing_particles.rotation = -heading_rotation
	if muzzle_pivot != null:
		muzzle_pivot.rotation = heading_rotation


func _apply_selected_paint_color() -> void:
	if body_sprite == null or not body_sprite.material is ShaderMaterial:
		return
	var run_state := get_node_or_null("/root/RunState") as RunStateStore
	var selected_color := (
		run_state.get_vehicle_paint_color()
		if run_state != null
		else RunStateStore.DEFAULT_VEHICLE_PAINT_COLOR
	)
	(body_sprite.material as ShaderMaterial).set_shader_parameter(
		PAINT_COLOR_SHADER_PARAMETER,
		selected_color
	)
