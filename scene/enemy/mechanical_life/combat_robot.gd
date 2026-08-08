extends Enemy
class_name CombatRobot

const CombatRobotConfigScript := preload(
	"res://resources/config/enemies/combat_robot_config.gd"
)
const ACTION_WINDUP: StringName = &"combat_robot_windup"
const ACTION_DASH_START: StringName = &"combat_robot_dash_start"
const ACTION_DASH_END: StringName = &"combat_robot_dash_end"

enum CombatState {
	CHASE,
	WINDUP,
	DASH,
}

@export var path_refresh_interval: float = 0.25
@export var waypoint_arrival_distance: float = 4.0

@onready var windup_warning: Polygon2D = $WindupWarning

var combat_state: CombatState = CombatState.CHASE
var dash_cooldown_left: float = 0.0
var windup_time_left: float = 0.0
var dash_time_left: float = 0.0
var dash_direction := Vector2.RIGHT
var action_sequence: int = 0
var latest_proxy_action_id: int = 0


func _ready() -> void:
	super._ready()
	_hide_windup_warning()


func _physics_process(delta: float) -> void:
	if is_dead:
		velocity = Vector2.ZERO
		return

	_update_touch_damage(delta)
	_update_dash_cooldown(delta)

	match combat_state:
		CombatState.WINDUP:
			_update_windup(delta)
			return
		CombatState.DASH:
			_update_dash(delta)
			return

	var combat_target := _get_preferred_ranged_combat_target()
	if (
		_is_combat_sense_refresh_due()
		and combat_target != null
		and _try_start_windup(combat_target)
	):
		return
	if _has_player_contact():
		velocity = Vector2.ZERO
		return
	if not is_instance_valid(objective_target):
		velocity = Vector2.ZERO
		_move_until_player_contact()
		return

	var move_direction := _get_navigation_move_direction(delta)
	_update_facing(move_direction)
	velocity = move_direction * _get_move_speed()
	_move_until_player_contact()


func _apply_config() -> void:
	super._apply_config()
	combat_state = CombatState.CHASE
	dash_cooldown_left = 0.0
	windup_time_left = 0.0
	dash_time_left = 0.0
	dash_direction = Vector2.RIGHT
	_hide_windup_warning()


func _die() -> void:
	_reset_dash_state(false)
	super._die()


func play_multiplayer_death_sequence() -> void:
	latest_proxy_action_id += 1
	_hide_windup_warning()
	super.play_multiplayer_death_sequence()


func _update_dash_cooldown(delta: float) -> void:
	if dash_cooldown_left <= 0.0:
		return
	dash_cooldown_left = maxf(dash_cooldown_left - maxf(delta, 0.0), 0.0)


func _try_start_windup(candidate_target: Node2D = null) -> bool:
	var robot_config := config as CombatRobotConfigScript
	if robot_config == null or combat_state != CombatState.CHASE:
		return false
	if dash_cooldown_left > 0.0:
		return false
	if candidate_target == null:
		candidate_target = _get_preferred_ranged_combat_target()
	if not _is_ranged_combat_target_in_range(
		candidate_target,
		robot_config.dash_trigger_range
	):
		return false

	combat_state = CombatState.WINDUP
	windup_time_left = maxf(robot_config.dash_windup, 0.0)
	dash_direction = global_position.direction_to(candidate_target.global_position)
	if dash_direction == Vector2.ZERO:
		dash_direction = Vector2.LEFT if facing_left else Vector2.RIGHT
	velocity = Vector2.ZERO
	_clear_navigation_path()
	_update_facing(dash_direction)
	_play_scene_animation(robot_config.windup_animation_name)
	_set_windup_warning(0.0, dash_direction)
	_broadcast_enemy_action(ACTION_WINDUP, dash_direction)
	return true


func _update_windup(delta: float) -> void:
	var robot_config := config as CombatRobotConfigScript
	if robot_config == null:
		_reset_dash_state(true)
		return

	velocity = Vector2.ZERO
	_update_facing(dash_direction)
	windup_time_left = maxf(windup_time_left - maxf(delta, 0.0), 0.0)
	var windup_progress := 1.0 - (
		windup_time_left / maxf(robot_config.dash_windup, 0.001)
	)
	_set_windup_warning(windup_progress, dash_direction)
	if windup_time_left > 0.0:
		return
	_start_dash()


func _start_dash() -> void:
	var robot_config := config as CombatRobotConfigScript
	if robot_config == null:
		_reset_dash_state(true)
		return

	combat_state = CombatState.DASH
	windup_time_left = 0.0
	dash_time_left = maxf(robot_config.dash_duration, 0.0)
	dash_direction = (
		dash_direction.normalized()
		if dash_direction != Vector2.ZERO
		else Vector2.RIGHT
	)
	_update_facing(dash_direction)
	_hide_windup_warning()
	_play_scene_animation(robot_config.dash_animation_name)
	_broadcast_enemy_action(ACTION_DASH_START, dash_direction)
	if dash_time_left <= 0.0:
		_finish_dash()


func _update_dash(delta: float) -> void:
	var robot_config := config as CombatRobotConfigScript
	if robot_config == null:
		_reset_dash_state(true)
		return

	var step_time := minf(maxf(delta, 0.0), dash_time_left)
	var current_dash_speed := maxf(
		robot_config.dash_speed * get_effective_move_speed_multiplier(),
		0.0
	)
	velocity = dash_direction * current_dash_speed
	_update_facing(dash_direction)

	var collision: KinematicCollision2D = null
	if step_time > 0.0 and current_dash_speed > 0.0:
		collision = move_and_collide(velocity * step_time)
	dash_time_left = maxf(dash_time_left - step_time, 0.0)
	if collision != null or dash_time_left <= 0.0:
		_finish_dash()


func _finish_dash() -> void:
	if combat_state != CombatState.DASH:
		return
	var finished_direction := dash_direction
	var robot_config := config as CombatRobotConfigScript
	combat_state = CombatState.CHASE
	windup_time_left = 0.0
	dash_time_left = 0.0
	velocity = Vector2.ZERO
	_hide_windup_warning()
	dash_cooldown_left = (
		maxf(robot_config.dash_cooldown, 0.0)
		if robot_config != null
		else 0.0
	)
	_clear_navigation_path()
	if robot_config != null:
		_play_scene_animation(robot_config.move_animation_name)
	_broadcast_enemy_action(ACTION_DASH_END, finished_direction)


func _reset_dash_state(play_move_animation: bool) -> void:
	combat_state = CombatState.CHASE
	dash_cooldown_left = 0.0
	windup_time_left = 0.0
	dash_time_left = 0.0
	velocity = Vector2.ZERO
	_hide_windup_warning()
	_clear_navigation_path()
	var robot_config := config as CombatRobotConfigScript
	if play_move_animation and robot_config != null and not is_dead:
		_play_scene_animation(robot_config.move_animation_name)


func play_multiplayer_enemy_action(
	action_name: StringName,
	direction: Vector2,
	action_id: int
) -> void:
	play_multiplayer_enemy_action_with_context(
		action_name,
		direction,
		global_position,
		action_id,
		0.0
	)


func play_multiplayer_enemy_action_with_context(
	action_name: StringName,
	direction: Vector2,
	_action_position: Vector2,
	action_id: int,
	action_elapsed: float
) -> void:
	if is_dead or action_id <= latest_proxy_action_id:
		return
	latest_proxy_action_id = action_id
	var safe_direction := (
		direction.normalized()
		if direction != Vector2.ZERO
		else Vector2.RIGHT
	)
	_update_facing(safe_direction)

	var robot_config := config as CombatRobotConfigScript
	if robot_config == null:
		return
	var safe_elapsed := maxf(action_elapsed, 0.0)
	match action_name:
		ACTION_WINDUP:
			var remaining_windup := maxf(
				robot_config.dash_windup - safe_elapsed,
				0.0
			)
			if remaining_windup > 0.0:
				_play_multiplayer_proxy_action_animation(
					robot_config.windup_animation_name,
					remaining_windup + 0.05
				)
				_play_proxy_windup_warning(
					safe_direction,
					robot_config.dash_windup,
					safe_elapsed,
					action_id
				)
			else:
				_hide_windup_warning()
				_restore_proxy_move_animation()
		ACTION_DASH_START:
			_hide_windup_warning()
			var remaining_dash := maxf(
				robot_config.dash_duration - safe_elapsed,
				0.0
			)
			if remaining_dash > 0.0:
				_play_multiplayer_proxy_action_animation(
					robot_config.dash_animation_name,
					remaining_dash + 0.05
				)
			else:
				_restore_proxy_move_animation()
		ACTION_DASH_END:
			_hide_windup_warning()
			_restore_proxy_move_animation()


func _play_proxy_windup_warning(
	direction: Vector2,
	duration: float,
	elapsed: float,
	action_id: int
) -> void:
	var safe_duration := maxf(duration, 0.001)
	var initial_progress := clampf(elapsed / safe_duration, 0.0, 1.0)
	var remaining_duration := maxf(safe_duration - elapsed, 0.0)
	_set_windup_warning(initial_progress, direction)
	if remaining_duration <= 0.0 or not is_inside_tree():
		_hide_windup_warning()
		return
	var tween := create_tween()
	tween.tween_method(
		func(progress: float) -> void:
			if action_id != latest_proxy_action_id:
				return
			_set_windup_warning(progress, direction),
		initial_progress,
		1.0,
		remaining_duration
	)
	tween.tween_callback(
		func() -> void:
			if action_id == latest_proxy_action_id:
				_hide_windup_warning()
	)


func _set_windup_warning(progress: float, direction: Vector2) -> void:
	if windup_warning == null:
		return
	var robot_config := config as CombatRobotConfigScript
	if robot_config == null:
		return
	var safe_direction := (
		direction.normalized()
		if direction != Vector2.ZERO
		else Vector2.RIGHT
	)
	var clamped_progress := clampf(progress, 0.0, 1.0)
	var warning_color := robot_config.windup_warning_color
	windup_warning.visible = true
	windup_warning.rotation = safe_direction.angle()
	windup_warning.color = Color(
		warning_color.r,
		warning_color.g,
		warning_color.b,
		lerpf(0.06, 0.34, clamped_progress)
	)


func _hide_windup_warning() -> void:
	if windup_warning != null:
		windup_warning.visible = false


func _restore_proxy_move_animation() -> void:
	proxy_action_restore_token += 1
	proxy_action_animation_name_in_use = &""
	if config != null and not is_dead:
		_play_scene_animation(config.move_animation_name)


func _broadcast_enemy_action(action_name: StringName, direction: Vector2) -> void:
	action_sequence += 1
	if gameplay_gateway != null and is_instance_valid(gameplay_gateway):
		gameplay_gateway.broadcast_enemy_action(
			int(get_meta("net_id", 0)),
			action_name,
			direction,
			global_position,
			action_sequence
		)


func _get_move_speed() -> float:
	return get_effective_move_speed()


func _get_navigation_move_direction(_delta: float) -> Vector2:
	return _get_safe_navigation_move_direction(
		objective_target,
		pathfinder,
		waypoint_arrival_distance
	)


func _update_facing(move_direction: Vector2) -> void:
	if is_zero_approx(move_direction.x):
		return
	_set_facing_from_direction(move_direction)
