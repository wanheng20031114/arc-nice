extends Enemy
class_name CombatRobotDroneOperator

const OperatorConfig := preload(
	"res://resources/config/enemies/combat_robot_drone_operator_config.gd"
)
const ACTION_DEPLOY: StringName = &"combat_robot_drone_operator_deploy"
const PROJECTILE_TYPE: StringName = &"combat_robot_suicide_drone"
const WORLD_COLLISION_MASK := 1
const DEPLOY_ANIMATION_FPS := 30.0
const DEPLOY_ANIMATION_FRAME_COUNT := 3

enum CombatState {
	TRACKING_READY,
	DEPLOY,
	TRACKING_COOLDOWN,
}

@export var path_refresh_interval: float = 0.25
@export var waypoint_arrival_distance: float = 4.0

@onready var attack_sense_area: Area2D = $AttackSenseArea
@onready var deploy_timer: Timer = $DeployTimer
@onready var cooldown_timer: Timer = $CooldownTimer
@onready var blocked_retry_timer: Timer = $BlockedRetryTimer
@onready var drone_spawn: Marker2D = $DroneSpawn

var combat_state: CombatState = CombatState.TRACKING_READY
var operator_config_cache: OperatorConfig = null
var drone_motion_system: CombatRobotDroneMotionSystem = null

var sensed_targets: Dictionary[int, Node2D] = {}
var last_attack_target: Node2D = null
var locked_target_position := Vector2.ZERO
var locked_deploy_direction := Vector2.RIGHT

var action_sequence := 0
var latest_proxy_action_id := 0

# Reused bounded selection buffers avoid sorting and allocating the complete
# sensed cohort. Only the nearest configured candidates can issue World rays.
var nearest_target_buffer: Array[Node2D] = []
var nearest_distance_buffer: Array[float] = []
var nearest_id_buffer: Array[int] = []
var stale_target_id_buffer: Array[int] = []


func _ready() -> void:
	super._ready()
	_refresh_drone_motion_system()


func can_target_water_plant_objectives() -> bool:
	return true


func _physics_process(delta: float) -> void:
	if is_dead:
		velocity = Vector2.ZERO
		return

	_update_touch_damage(maxf(delta, 0.0))
	if combat_state == CombatState.DEPLOY:
		velocity = Vector2.ZERO
		_update_facing(locked_deploy_direction)
		return

	var tracking_target: Node2D = null
	if combat_state == CombatState.TRACKING_COOLDOWN:
		tracking_target = _get_live_last_attack_target()
	_update_tracking_movement(tracking_target)


func _apply_config() -> void:
	super._apply_config()
	operator_config_cache = config as OperatorConfig
	combat_state = CombatState.TRACKING_READY
	last_attack_target = null
	locked_target_position = Vector2.ZERO
	locked_deploy_direction = Vector2.RIGHT
	sensed_targets.clear()
	nearest_target_buffer.clear()
	nearest_distance_buffer.clear()
	nearest_id_buffer.clear()
	stale_target_id_buffer.clear()
	_stop_operator_timers()
	_refresh_drone_motion_system()


func configure_multiplayer_proxy() -> void:
	_cancel_operator_state(false, true)
	super.configure_multiplayer_proxy()


func _die() -> void:
	if is_dead:
		return
	latest_proxy_action_id += 1
	_cancel_operator_state(false, true)
	super._die()


func play_multiplayer_death_sequence() -> void:
	if is_dead:
		return
	latest_proxy_action_id += 1
	_cancel_operator_state(false, true)
	super.play_multiplayer_death_sequence()


func set_multiplayer_proxy_visual_active(active: bool) -> void:
	super.set_multiplayer_proxy_visual_active(active)
	if active or not is_multiplayer_proxy:
		return
	_restore_proxy_move_animation()


func remove_for_home_escape() -> bool:
	if is_dead:
		return false
	latest_proxy_action_id += 1
	_cancel_operator_state(false, true)
	return super.remove_for_home_escape()


func _exit_tree() -> void:
	_cancel_operator_state(false, false)
	super._exit_tree()


func _on_attack_sense_area_body_entered(body: Node2D) -> void:
	if is_dead or is_multiplayer_proxy:
		return
	if not _is_ranged_combat_target_valid(body):
		return
	sensed_targets[body.get_instance_id()] = body
	if combat_state == CombatState.TRACKING_READY:
		_try_select_and_begin_deploy()


func _on_attack_sense_area_body_exited(body: Node2D) -> void:
	if body != null:
		sensed_targets.erase(body.get_instance_id())
	if combat_state == CombatState.TRACKING_READY and sensed_targets.is_empty():
		blocked_retry_timer.stop()


func _on_deploy_timer_timeout() -> void:
	if is_dead or is_multiplayer_proxy or combat_state != CombatState.DEPLOY:
		return
	combat_state = CombatState.TRACKING_COOLDOWN
	velocity = Vector2.ZERO
	_reset_ranged_attack_position_state()
	_clear_cached_navigation_move_direction()
	if config != null:
		_play_scene_animation(config.move_animation_name)

	var cooldown := (
		maxf(operator_config_cache.attack_cooldown, 0.0)
		if operator_config_cache != null
		else 0.0
	)
	if cooldown <= 0.0:
		_on_cooldown_timer_timeout()
		return
	cooldown_timer.start(cooldown)


func _on_cooldown_timer_timeout() -> void:
	if (
		is_dead
		or is_multiplayer_proxy
		or combat_state != CombatState.TRACKING_COOLDOWN
	):
		return
	combat_state = CombatState.TRACKING_READY
	last_attack_target = null
	_reset_ranged_attack_position_state()
	_clear_cached_navigation_move_direction()
	_try_select_and_begin_deploy()


func _on_blocked_retry_timer_timeout() -> void:
	if is_dead or is_multiplayer_proxy or combat_state != CombatState.TRACKING_READY:
		return
	_try_select_and_begin_deploy()


func _try_select_and_begin_deploy() -> bool:
	if (
		is_dead
		or is_multiplayer_proxy
		or combat_state != CombatState.TRACKING_READY
		or operator_config_cache == null
	):
		return false

	_collect_nearest_attack_candidates()
	for candidate_target in nearest_target_buffer:
		if not _is_world_segment_clear(
			candidate_target.global_position,
			WORLD_COLLISION_MASK
		):
			continue
		if _begin_deploy(candidate_target):
			blocked_retry_timer.stop()
			return true

	_arm_blocked_retry_if_needed()
	return false


func _collect_nearest_attack_candidates() -> void:
	nearest_target_buffer.clear()
	nearest_distance_buffer.clear()
	nearest_id_buffer.clear()
	stale_target_id_buffer.clear()
	if operator_config_cache == null:
		return

	var attack_range := maxf(operator_config_cache.attack_range, 0.0)
	var attack_range_squared := attack_range * attack_range
	var check_limit := maxi(operator_config_cache.visible_target_check_limit, 1)
	for target_id_variant in sensed_targets:
		var target_id := int(target_id_variant)
		var target := sensed_targets.get(target_id) as Node2D
		if not _is_ranged_combat_target_valid(target):
			stale_target_id_buffer.append(target_id)
			continue
		var distance_squared := global_position.distance_squared_to(
			target.global_position
		)
		# Area2D overlap includes the target body's own radius. The explicit center
		# check preserves the authored 80-pixel targeting boundary.
		if distance_squared > attack_range_squared:
			continue
		_insert_nearest_candidate(
			target,
			distance_squared,
			target_id,
			check_limit
		)

	for stale_target_id in stale_target_id_buffer:
		sensed_targets.erase(stale_target_id)


func _insert_nearest_candidate(
	target: Node2D,
	distance_squared: float,
	target_id: int,
	check_limit: int
) -> void:
	var insert_index := nearest_target_buffer.size()
	for candidate_index in range(nearest_target_buffer.size()):
		var existing_distance := nearest_distance_buffer[candidate_index]
		var existing_id := nearest_id_buffer[candidate_index]
		if (
			distance_squared < existing_distance
			or (
				distance_squared == existing_distance
				and target_id < existing_id
			)
		):
			insert_index = candidate_index
			break

	if insert_index >= check_limit:
		return
	nearest_target_buffer.insert(insert_index, target)
	nearest_distance_buffer.insert(insert_index, distance_squared)
	nearest_id_buffer.insert(insert_index, target_id)
	if nearest_target_buffer.size() <= check_limit:
		return
	nearest_target_buffer.pop_back()
	nearest_distance_buffer.pop_back()
	nearest_id_buffer.pop_back()


func _begin_deploy(target: Node2D) -> bool:
	if not _is_ranged_combat_target_valid(target):
		return false
	var target_position := target.global_position
	var deploy_direction := global_position.direction_to(target_position)
	if deploy_direction == Vector2.ZERO:
		deploy_direction = Vector2.LEFT if facing_left else Vector2.RIGHT
	else:
		deploy_direction = deploy_direction.normalized()
	var outgoing_damage := get_effective_attack_damage(
		operator_config_cache.attack_damage
	)
	if not _spawn_committed_drone(
		target_position,
		deploy_direction,
		outgoing_damage
	):
		return false

	last_attack_target = target
	locked_target_position = target_position
	locked_deploy_direction = deploy_direction
	combat_state = CombatState.DEPLOY
	velocity = Vector2.ZERO
	blocked_retry_timer.stop()
	_clear_navigation_path()
	_set_ranged_attack_position_held(true)
	_update_facing(locked_deploy_direction)
	_play_scene_animation(operator_config_cache.deploy_animation_name)
	deploy_timer.start(maxf(operator_config_cache.deploy_delay, 0.001))
	_broadcast_enemy_action(ACTION_DEPLOY, locked_deploy_direction)
	return true


func _spawn_committed_drone(
	target_position: Vector2,
	deploy_direction: Vector2,
	outgoing_damage: int
) -> bool:
	if operator_config_cache == null or operator_config_cache.drone_scene == null:
		return false
	var drone_speed := maxf(operator_config_cache.drone_speed, 0.0)
	if drone_speed <= 0.0:
		return false
	if drone_motion_system == null or not is_instance_valid(drone_motion_system):
		_refresh_drone_motion_system()
	if drone_motion_system == null or not is_instance_valid(drone_motion_system):
		return false

	var spawn_parent := get_tree().current_scene
	if spawn_parent == null:
		return false
	var acquired_node: Node = null
	var uses_registered_pool := (
		spawn_parent.has_method("has_session_object_pool_scene")
		and bool(spawn_parent.call(
			"has_session_object_pool_scene",
			operator_config_cache.drone_scene
		))
	)
	if uses_registered_pool:
		acquired_node = spawn_parent.call(
			"acquire_session_object",
			operator_config_cache.drone_scene,
			false
		) as Node
	else:
		acquired_node = operator_config_cache.drone_scene.instantiate()

	var drone := acquired_node as CombatRobotSuicideDrone
	if drone == null:
		_release_failed_drone_node(acquired_node)
		return false
	if drone.get_parent() == null:
		spawn_parent.add_child(drone)

	var spawn_position := drone_spawn.global_position
	var flight_direction := spawn_position.direction_to(target_position)
	if flight_direction == Vector2.ZERO:
		flight_direction = deploy_direction
	else:
		flight_direction = flight_direction.normalized()
	var distance := spawn_position.distance_to(target_position)
	var flight_duration := distance / drone_speed
	drone.top_level = true
	drone.global_position = spawn_position
	drone.reset_physics_interpolation()
	drone.setup(
		flight_direction,
		outgoing_damage,
		drone_speed,
		flight_duration,
		maxf(operator_config_cache.explosion_radius, 0.0),
		drone_motion_system
	)
	if not drone.begin_deployment():
		drone.retire()
		return false

	if spawn_parent.has_method("register_local_projectile"):
		spawn_parent.call(
			"register_local_projectile",
			drone,
			PROJECTILE_TYPE,
			0,
			spawn_position,
			flight_direction,
			outgoing_damage,
			drone_speed,
			flight_duration
		)
	return true


func _release_failed_drone_node(node: Node) -> void:
	if node == null or not is_instance_valid(node):
		return
	if SessionObjectPool.release_to_owner(node):
		return
	node.queue_free()


func _arm_blocked_retry_if_needed() -> void:
	if (
		operator_config_cache == null
		or combat_state != CombatState.TRACKING_READY
		or sensed_targets.is_empty()
	):
		blocked_retry_timer.stop()
		return
	blocked_retry_timer.start(
		maxf(operator_config_cache.blocked_retry_interval, 0.01)
	)


func _get_live_last_attack_target() -> Node2D:
	if _is_ranged_combat_target_valid(last_attack_target):
		return last_attack_target
	last_attack_target = null
	return null


func _update_tracking_movement(tracking_target: Node2D) -> void:
	var live_tracking_target := (
		tracking_target
		if _is_ranged_combat_target_valid(tracking_target)
		else null
	)
	var stop_distance := (
		maxf(operator_config_cache.stop_distance, 0.0)
		if operator_config_cache != null
		else 0.0
	)
	var within_stop_distance := (
		live_tracking_target != null
		and global_position.distance_squared_to(
			live_tracking_target.global_position
		) <= stop_distance * stop_distance
	)
	if _has_player_contact() or within_stop_distance:
		velocity = Vector2.ZERO
		_set_ranged_attack_position_held(true)
		if live_tracking_target != null:
			_update_facing(
				global_position.direction_to(live_tracking_target.global_position)
			)
		return

	_reset_ranged_attack_position_state()
	var navigation_target := (
		live_tracking_target
		if live_tracking_target != null
		else objective_target
	)
	if not is_instance_valid(navigation_target):
		velocity = Vector2.ZERO
		return
	var move_direction := _get_navigation_move_direction(navigation_target)
	velocity = move_direction * get_effective_move_speed()
	_update_facing(move_direction)
	_move_until_player_contact()


func _get_navigation_move_direction(target: Node2D) -> Vector2:
	return _get_safe_navigation_move_direction(
		target,
		pathfinder,
		waypoint_arrival_distance
	)


func _update_facing(direction: Vector2) -> void:
	if is_zero_approx(direction.x):
		return
	_set_facing_from_direction(direction)


func _refresh_drone_motion_system() -> void:
	drone_motion_system = null
	if pathfinder == null:
		return
	var runtime := pathfinder.get_parent()
	if runtime == null:
		return
	drone_motion_system = runtime.get_node_or_null(
		"CombatRobotDroneMotionSystem"
	) as CombatRobotDroneMotionSystem


func _stop_operator_timers() -> void:
	if deploy_timer != null:
		deploy_timer.stop()
	if cooldown_timer != null:
		cooldown_timer.stop()
	if blocked_retry_timer != null:
		blocked_retry_timer.stop()


func _cancel_operator_state(
	restore_move_animation: bool,
	disable_attack_sense: bool
) -> void:
	_stop_operator_timers()
	combat_state = CombatState.TRACKING_READY
	last_attack_target = null
	locked_target_position = Vector2.ZERO
	locked_deploy_direction = Vector2.RIGHT
	velocity = Vector2.ZERO
	sensed_targets.clear()
	nearest_target_buffer.clear()
	nearest_distance_buffer.clear()
	nearest_id_buffer.clear()
	stale_target_id_buffer.clear()
	_reset_ranged_attack_position_state()
	_clear_cached_navigation_move_direction()
	if disable_attack_sense and attack_sense_area != null:
		attack_sense_area.set_deferred("monitoring", false)
	if restore_move_animation and config != null and not is_dead:
		_play_scene_animation(config.move_animation_name)


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
	if not is_multiplayer_proxy or is_dead:
		return
	if action_id <= latest_proxy_action_id:
		return
	latest_proxy_action_id = action_id
	if action_name != ACTION_DEPLOY or operator_config_cache == null:
		return

	var deploy_duration := maxf(operator_config_cache.deploy_delay, 0.0)
	var safe_elapsed := maxf(action_elapsed, 0.0)
	if safe_elapsed >= deploy_duration:
		_restore_proxy_move_animation()
		return
	if not multiplayer_proxy_visual_active:
		return

	var safe_direction := (
		direction.normalized()
		if direction != Vector2.ZERO
		else (Vector2.LEFT if facing_left else Vector2.RIGHT)
	)
	_update_facing(safe_direction)
	var remaining_duration := deploy_duration - safe_elapsed
	if not _play_multiplayer_proxy_action_animation(
		operator_config_cache.deploy_animation_name,
		remaining_duration
	):
		return
	var frame_phase := safe_elapsed * DEPLOY_ANIMATION_FPS
	var frame_index := clampi(
		floori(frame_phase),
		0,
		DEPLOY_ANIMATION_FRAME_COUNT - 1
	)
	animated_sprite.set_frame_and_progress(
		frame_index,
		clampf(frame_phase - float(frame_index), 0.0, 1.0)
	)


func _restore_proxy_move_animation() -> void:
	proxy_action_restore_token += 1
	proxy_action_animation_name_in_use = &""
	if config != null and not is_dead:
		_play_scene_animation(config.move_animation_name)


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
