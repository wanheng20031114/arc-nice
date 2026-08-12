extends Enemy
class_name CombatRobotMainBattleElite

const MainBattleConfig := preload(
	"res://resources/config/enemies/combat_robot_main_battle_elite_config.gd"
)
const COMPLETE_SHAPE_QUERY_2D := preload(
	"res://scene/combat/physics/complete_shape_query_2d.gd"
)
const EXPECTED_RUNTIME_SPRITE_FRAMES_PATH := (
	"res://resources/animation/combat_robot_main_battle_elite.tres"
)
const PLAYER_COLLISION_MASK := 1 << 1
const PLANT_COLLISION_MASK := 1 << 9
const TARGET_COLLISION_MASK := PLAYER_COLLISION_MASK | PLANT_COLLISION_MASK
const AIRBORNE_VISUAL_STATUS_MASK := 1 << 5
const BASE_VISUAL_STATUS_MASK := 0x1f
const ANGLE_EPSILON_RADIANS := 0.000001
const ACTION_EXPIRY_TOLERANCE_SECONDS := 0.05

const ACTION_ATTACK_WINDUP := &"main_battle_attack_windup"
const ACTION_ATTACK_SLASH := &"main_battle_attack_slash"
const ACTION_SKILL1_WINDUP := &"main_battle_skill1_windup"
const ACTION_SKILL1_DASH := &"main_battle_skill1_dash"
const ACTION_SKILL1_CIRCLE := &"main_battle_skill1_circle"
const ACTION_SKILL2_TAKEOFF := &"main_battle_skill2_takeoff"
const ACTION_SKILL2_DROP := &"main_battle_skill2_drop"
const RUNTIME_ANIMATION_FRAME_COUNTS := {
	&"move": 8,
	&"attack": 8,
	&"skill1_windup": 4,
	&"skill1_dash": 4,
	&"skill1_circle_slash": 8,
	&"skill2_takeoff": 5,
	&"skill2_drop_slash": 8,
	&"death": 8,
}


enum CombatState {
	CHASE,
	ATTACK_WINDUP,
	ATTACK_SLASH,
	SKILL1_WINDUP,
	SKILL1_DASH,
	SKILL1_CIRCLE,
	SKILL2_TAKEOFF,
	SKILL2_TRACK,
	SKILL2_DROP,
	SKILL2_RECOVERY,
}


@export var waypoint_arrival_distance := 6.0
@onready var attack_warning: Polygon2D = $AttackWarning
@onready var skill1_warning_line: Line2D = $Skill1WarningLine
@onready var skill1_circle_ring: Line2D = $Skill1CircleRing
@onready var skill2_cross_marker: Node2D = $Skill2CrossMarker
@onready var skill2_fan_warning: Polygon2D = $Skill2FanWarning

var main_config: MainBattleConfig = null
var combat_state := CombatState.CHASE
var state_time_left := 0.0
var attack_cooldown_left := 0.0
var skill1_cooldown_left := 0.0
var skill2_cooldown_left := 0.0
var committed_target: Node2D = null
var locked_direction := Vector2.RIGHT
var skill1_locked_position := Vector2.ZERO
var skill2_last_target_position := Vector2.ZERO
var skill2_last_tracking_direction := Vector2.RIGHT
var action_sequence := 0
var latest_proxy_action_id := 0
var airborne := false
var proxy_airborne_from_snapshot := false
var proxy_visual_override_action_id := 0
var proxy_takeoff_visual_override := false
var proxy_drop_visual_override := false
var proxy_grounded_after_drop_latched := false
var action_damage_done := false

var target_query := PhysicsShapeQueryParameters2D.new()
var target_query_shape := CircleShape2D.new()
var hit_target_ids: Dictionary = {}


func _ready() -> void:
	super._ready()
	_hide_all_action_indicators()


func _physics_process(delta: float) -> void:
	if is_dead:
		velocity = Vector2.ZERO
		return
	var safe_delta := maxf(delta, 0.0)
	_update_cooldowns(safe_delta)

	match combat_state:
		CombatState.ATTACK_WINDUP:
			_update_attack_windup(safe_delta)
			return
		CombatState.ATTACK_SLASH:
			_update_attack_slash(safe_delta)
			return
		CombatState.SKILL1_WINDUP:
			_update_skill1_windup(safe_delta)
			return
		CombatState.SKILL1_DASH:
			_update_skill1_dash(safe_delta)
			return
		CombatState.SKILL1_CIRCLE:
			_update_recovery(safe_delta, true)
			return
		CombatState.SKILL2_TAKEOFF:
			_update_skill2_takeoff(safe_delta)
			return
		CombatState.SKILL2_TRACK:
			_update_skill2_tracking(safe_delta)
			return
		CombatState.SKILL2_DROP:
			_update_skill2_drop(safe_delta)
			return
		CombatState.SKILL2_RECOVERY:
			_update_recovery(safe_delta, false)
			return

	_update_touch_damage(safe_delta)
	if _is_combat_sense_refresh_due() and _try_start_ready_action():
		return
	if _has_player_contact():
		velocity = Vector2.ZERO
		return
	if not is_instance_valid(objective_target):
		velocity = Vector2.ZERO
		_move_until_player_contact()
		return
	var move_direction := _get_safe_navigation_move_direction(
		objective_target,
		pathfinder,
		waypoint_arrival_distance
	)
	_update_facing(move_direction)
	velocity = move_direction * get_effective_move_speed()
	_move_until_player_contact()


func _apply_config() -> void:
	super._apply_config()
	main_config = config as MainBattleConfig
	combat_state = CombatState.CHASE
	state_time_left = 0.0
	attack_cooldown_left = 0.0
	skill1_cooldown_left = (
		maxf(main_config.skill1_initial_delay, 0.0)
		if main_config != null
		else 0.0
	)
	skill2_cooldown_left = (
		maxf(main_config.skill2_initial_delay, 0.0)
		if main_config != null
		else 0.0
	)
	committed_target = null
	locked_direction = Vector2.RIGHT
	skill1_locked_position = global_position
	skill2_last_target_position = global_position
	skill2_last_tracking_direction = Vector2.RIGHT
	action_sequence = 0
	latest_proxy_action_id = 0
	action_damage_done = false
	airborne = false
	proxy_airborne_from_snapshot = false
	proxy_visual_override_action_id = 0
	proxy_takeoff_visual_override = false
	proxy_drop_visual_override = false
	proxy_grounded_after_drop_latched = false
	if main_config != null:
		target_query.shape = target_query_shape
		target_query.collision_mask = TARGET_COLLISION_MASK
		target_query.collide_with_bodies = true
		target_query.collide_with_areas = false
		target_query.exclude = []
	_hide_all_action_indicators()


func _update_cooldowns(delta: float) -> void:
	attack_cooldown_left = maxf(attack_cooldown_left - delta, 0.0)
	skill1_cooldown_left = maxf(skill1_cooldown_left - delta, 0.0)
	skill2_cooldown_left = maxf(skill2_cooldown_left - delta, 0.0)


func _try_start_ready_action() -> bool:
	if main_config == null:
		return false
	var skill2_target := _find_nearest_target_in_range(
		main_config.skill2_trigger_range
	)
	if skill2_cooldown_left <= 0.0 and skill2_target != null:
		_start_skill2_takeoff(skill2_target)
		return true
	var target := _get_preferred_ranged_combat_target()
	if target == null:
		return false
	if (
		skill1_cooldown_left <= 0.0
		and _is_ranged_combat_target_in_range(
			target,
			main_config.skill1_trigger_range
		)
	):
		_start_skill1_windup(target)
		return true
	if (
		attack_cooldown_left <= 0.0
		and _is_ranged_combat_target_in_range(target, main_config.attack_range)
	):
		_start_attack_windup(target)
		return true
	return false


func _start_attack_windup(target: Node2D) -> void:
	committed_target = target
	combat_state = CombatState.ATTACK_WINDUP
	state_time_left = maxf(main_config.attack_windup, 0.0)
	locked_direction = _direction_to_target(target)
	velocity = Vector2.ZERO
	_clear_navigation_path()
	_update_facing(locked_direction)
	_set_attack_warning(0.0, locked_direction)
	_broadcast_action(ACTION_ATTACK_WINDUP, locked_direction)


func _update_attack_windup(delta: float) -> void:
	if not _is_ranged_combat_target_valid(committed_target):
		_cancel_to_chase()
		return
	locked_direction = _direction_to_target(committed_target)
	_update_facing(locked_direction)
	state_time_left = maxf(state_time_left - delta, 0.0)
	var progress := 1.0 - state_time_left / maxf(main_config.attack_windup, 0.001)
	_set_attack_warning(progress, locked_direction)
	if state_time_left <= 0.0:
		_start_attack_slash()


func _start_attack_slash() -> void:
	combat_state = CombatState.ATTACK_SLASH
	state_time_left = maxf(main_config.attack_slash_duration, 0.01)
	action_damage_done = false
	_restart_scene_animation(main_config.attack_animation_name)
	_set_attack_warning(0.0, locked_direction)
	_broadcast_action(ACTION_ATTACK_SLASH, locked_direction)


func _update_attack_slash(delta: float) -> void:
	velocity = Vector2.ZERO
	state_time_left = maxf(state_time_left - delta, 0.0)
	var elapsed := main_config.attack_slash_duration - state_time_left
	if not action_damage_done and elapsed >= main_config.attack_damage_delay:
		_apply_fan_damage(
			main_config.attack_range,
			main_config.attack_angle_degrees,
			get_effective_attack_damage(main_config.attack_damage),
			&"combat_robot_main_battle_elite_attack",
			false,
			false
		)
		action_damage_done = true
	if state_time_left <= 0.0:
		attack_cooldown_left = maxf(main_config.attack_cooldown, 0.0)
		_finish_to_chase()


func _start_skill1_windup(target: Node2D) -> void:
	committed_target = target
	combat_state = CombatState.SKILL1_WINDUP
	state_time_left = maxf(main_config.skill1_windup, 0.0)
	locked_direction = _direction_to_target(target)
	velocity = Vector2.ZERO
	_clear_navigation_path()
	_update_facing(locked_direction)
	_play_scene_animation(main_config.skill1_windup_animation_name)
	_update_skill1_warning_line(target)
	_broadcast_target_or_action(ACTION_SKILL1_WINDUP, target, locked_direction)


func _update_skill1_windup(delta: float) -> void:
	if not _is_ranged_combat_target_valid(committed_target):
		_cancel_to_chase()
		return
	locked_direction = _direction_to_target(committed_target)
	_update_facing(locked_direction)
	_update_skill1_warning_line(committed_target)
	state_time_left = maxf(state_time_left - delta, 0.0)
	if state_time_left <= 0.0:
		_start_skill1_dash()


func _start_skill1_dash() -> void:
	skill1_locked_position = committed_target.global_position
	locked_direction = global_position.direction_to(skill1_locked_position)
	if locked_direction == Vector2.ZERO:
		locked_direction = _get_facing_direction()
	combat_state = CombatState.SKILL1_DASH
	state_time_left = maxf(main_config.skill1_dash_duration, 0.01)
	committed_target = null
	velocity = locked_direction * main_config.skill1_dash_speed
	_update_facing(locked_direction)
	_hide_skill1_warning_line()
	_play_scene_animation(main_config.skill1_dash_animation_name)
	_broadcast_action(ACTION_SKILL1_DASH, locked_direction)
	if global_position.is_equal_approx(skill1_locked_position):
		_finish_skill1_dash()


func _update_skill1_dash(delta: float) -> void:
	var step_time := minf(delta, state_time_left)
	var remaining := global_position.distance_to(skill1_locked_position)
	var step_distance := minf(
		maxf(main_config.skill1_dash_speed, 0.0) * step_time,
		remaining
	)
	velocity = locked_direction * main_config.skill1_dash_speed
	var collision: KinematicCollision2D = null
	if step_distance > 0.0:
		collision = move_and_collide(locked_direction * step_distance)
	state_time_left = maxf(state_time_left - step_time, 0.0)
	if collision != null or step_distance >= remaining or state_time_left <= 0.0:
		_finish_skill1_dash()


func _finish_skill1_dash() -> void:
	combat_state = CombatState.SKILL1_CIRCLE
	state_time_left = maxf(main_config.skill1_recovery, 0.01)
	velocity = Vector2.ZERO
	_play_scene_animation(main_config.skill1_circle_animation_name)
	_show_skill1_circle_ring()
	_broadcast_action(ACTION_SKILL1_CIRCLE, locked_direction)
	_apply_circle_damage(
		main_config.skill1_circle_radius,
		roundi(float(get_effective_attack_damage(main_config.attack_damage))
			* main_config.skill1_damage_multiplier),
		CombatAttackRegistry.COMBAT_ROBOT_MAIN_BATTLE_SKILL1
	)


func _start_skill2_takeoff(target: Node2D) -> void:
	committed_target = target
	skill2_last_target_position = target.global_position
	skill2_last_tracking_direction = _direction_to_target(target)
	locked_direction = skill2_last_tracking_direction
	combat_state = CombatState.SKILL2_TAKEOFF
	state_time_left = maxf(main_config.skill2_takeoff_duration, 0.01)
	velocity = Vector2.ZERO
	_clear_navigation_path()
	_update_facing(locked_direction)
	_set_airborne(true, true)
	_play_scene_animation(main_config.skill2_takeoff_animation_name)
	_broadcast_target_or_action(ACTION_SKILL2_TAKEOFF, target, locked_direction)


func _update_skill2_takeoff(delta: float) -> void:
	state_time_left = maxf(state_time_left - delta, 0.0)
	if state_time_left > 0.0:
		return
	combat_state = CombatState.SKILL2_TRACK
	state_time_left = maxf(main_config.skill2_tracking_duration, 0.01)
	if animated_sprite != null:
		animated_sprite.visible = false
	_set_skill2_cross_visible(true)


func _update_skill2_tracking(delta: float) -> void:
	velocity = Vector2.ZERO
	if _is_ranged_combat_target_valid(committed_target):
		skill2_last_target_position = committed_target.global_position
		var tracking_direction := global_position.direction_to(
			skill2_last_target_position
		)
		if tracking_direction != Vector2.ZERO:
			skill2_last_tracking_direction = tracking_direction
		global_position = global_position.move_toward(
			skill2_last_target_position,
			maxf(main_config.skill2_cross_speed, 0.0) * delta
		)
	state_time_left = maxf(state_time_left - delta, 0.0)
	if state_time_left <= 0.0:
		_start_skill2_drop()


func _start_skill2_drop() -> void:
	if _is_ranged_combat_target_valid(committed_target):
		var current_direction := global_position.direction_to(
			committed_target.global_position
		)
		locked_direction = (
			current_direction
			if current_direction != Vector2.ZERO
			else skill2_last_tracking_direction
		)
	else:
		locked_direction = skill2_last_tracking_direction
	if locked_direction == Vector2.ZERO:
		locked_direction = _get_facing_direction()
	combat_state = CombatState.SKILL2_DROP
	state_time_left = maxf(main_config.skill2_drop_duration, 0.01)
	_update_facing(locked_direction)
	_set_skill2_cross_visible(false)
	if animated_sprite != null:
		animated_sprite.visible = multiplayer_proxy_visual_active
	_play_scene_animation(main_config.skill2_drop_animation_name)
	_set_skill2_fan_warning(true, locked_direction)
	_broadcast_action(ACTION_SKILL2_DROP, locked_direction)


func _update_skill2_drop(delta: float) -> void:
	state_time_left = maxf(state_time_left - delta, 0.0)
	if state_time_left > 0.0:
		return
	_apply_fan_damage(
		main_config.skill2_fan_range,
		main_config.skill2_fan_angle_degrees,
		roundi(float(get_effective_attack_damage(main_config.attack_damage))
			* main_config.skill2_damage_multiplier),
		CombatAttackRegistry.COMBAT_ROBOT_MAIN_BATTLE_SKILL2,
		true,
		true
	)
	committed_target = null
	combat_state = CombatState.SKILL2_RECOVERY
	state_time_left = maxf(main_config.skill2_recovery, 0.01)
	_set_airborne(false, true)
	_set_skill2_fan_warning(false, locked_direction)


func _update_recovery(delta: float, is_skill1: bool) -> void:
	velocity = Vector2.ZERO
	state_time_left = maxf(state_time_left - delta, 0.0)
	if state_time_left > 0.0:
		return
	if is_skill1:
		skill1_cooldown_left = maxf(main_config.skill1_cooldown, 0.0)
		_hide_skill1_circle_ring()
	else:
		skill2_cooldown_left = maxf(main_config.skill2_cooldown, 0.0)
	_finish_to_chase()


func _apply_circle_damage(
	radius: float,
	damage: int,
	source_type: StringName
) -> void:
	_apply_shape_damage(radius, 360.0, damage, source_type, true, false)


func _apply_fan_damage(
	radius: float,
	angle_degrees: float,
	damage: int,
	source_type: StringName,
	apply_burn: bool,
	apply_slow: bool
) -> void:
	_apply_shape_damage(
		radius,
		angle_degrees,
		damage,
		source_type,
		apply_burn,
		apply_slow
	)


func _apply_shape_damage(
	radius: float,
	angle_degrees: float,
	damage: int,
	source_type: StringName,
	apply_burn: bool,
	apply_slow: bool
) -> void:
	if is_dead or is_multiplayer_proxy or main_config == null or damage <= 0:
		return
	target_query_shape.radius = maxf(radius, 0.0)
	target_query.transform = Transform2D(0.0, global_position)
	hit_target_ids.clear()
	var results := COMPLETE_SHAPE_QUERY_2D.intersect_shape_all(
		get_world_2d().direct_space_state,
		target_query,
		main_config.shape_query_batch_size
	)
	var half_angle := deg_to_rad(angle_degrees * 0.5)
	for result in results:
		var target := result.get("collider") as Node2D
		if not _is_ranged_combat_target_valid(target):
			continue
		var target_id := target.get_instance_id()
		if hit_target_ids.has(target_id):
			continue
		var offset := target.global_position - global_position
		if (
			angle_degrees < 360.0
			and offset != Vector2.ZERO
			and absf(locked_direction.angle_to(offset.normalized()))
				> half_angle + ANGLE_EPSILON_RADIANS
		):
			continue
		hit_target_ids[target_id] = true
		_dispatch_target_damage(
			target,
			damage,
			source_type,
			offset.normalized() if offset != Vector2.ZERO else locked_direction,
			apply_burn,
			apply_slow
		)


func _dispatch_target_damage(
	target: Node2D,
	damage: int,
	source_type: StringName,
	impact_direction: Vector2,
	apply_burn: bool,
	apply_slow: bool
) -> bool:
	var player := target as Player
	if player != null:
		var source_id := _get_multiplayer_damage_source_id(action_sequence)
		if _try_request_player_damage(
			source_id,
			player.peer_id,
			damage,
			source_type,
			EnemyConfig.DamageType.PHYSICAL,
			-impact_direction
		):
			return true
		if not _has_explicit_singleplayer_authority():
			return false
		var accepted := player.apply_damage(
			damage,
			EnemyConfig.DamageType.PHYSICAL
		)
		if accepted and player.last_damage_taken > 0 and not player.is_dead:
			if apply_burn:
				player.apply_burn_status(
					CombatAttackRegistry.COMBAT_ROBOT_MAIN_BATTLE_BURN_FAMILY,
					main_config.burn_duration,
					main_config.burn_level
				)
			if apply_slow:
				player.apply_timed_move_slow(
					CombatAttackRegistry.COMBAT_ROBOT_MAIN_BATTLE_SLOW_FAMILY,
					main_config.skill2_slow_duration,
					main_config.skill2_slow_multiplier
				)
		return accepted
	var plant := target as PlantDefense
	if plant == null:
		return false
	var accepted := plant.receive_damage(
		damage,
		self,
		impact_direction,
		EnemyConfig.DamageType.PHYSICAL
	)
	if accepted and not plant.is_dead and not plant.is_removing and apply_burn:
		plant.apply_burn_status(
			CombatAttackRegistry.COMBAT_ROBOT_MAIN_BATTLE_BURN_FAMILY,
			main_config.burn_duration,
			main_config.burn_level
		)
	return accepted


func _finish_to_chase() -> void:
	combat_state = CombatState.CHASE
	state_time_left = 0.0
	committed_target = null
	action_damage_done = false
	velocity = Vector2.ZERO
	_hide_all_action_indicators()
	_clear_navigation_path()
	if main_config != null and not is_dead:
		_play_scene_animation(main_config.move_animation_name)


func _cancel_to_chase() -> void:
	if airborne:
		_set_airborne(false, true)
	_finish_to_chase()


func _die() -> void:
	if is_dead:
		return
	airborne = false
	latest_proxy_action_id += 1
	_hide_all_action_indicators()
	# Skill 2 intentionally hides the body during tracking. A periodic status
	# can still kill the enemy in that window, so restore the body before the
	# inherited death sequence starts instead of playing death invisibly.
	if animated_sprite != null:
		animated_sprite.visible = true
	super._die()


func play_multiplayer_death_sequence() -> void:
	if is_dead:
		return
	airborne = false
	proxy_airborne_from_snapshot = false
	proxy_takeoff_visual_override = false
	proxy_drop_visual_override = false
	proxy_grounded_after_drop_latched = false
	latest_proxy_action_id += 1
	_hide_all_action_indicators()
	if animated_sprite != null:
		animated_sprite.visible = multiplayer_proxy_visual_active
	super.play_multiplayer_death_sequence()


func is_temporarily_direct_damage_immune() -> bool:
	return airborne


func _uses_inherited_touch_damage() -> bool:
	return combat_state == CombatState.CHASE and not airborne


func get_collectible_visual_status_mask() -> int:
	return (
		super.get_collectible_visual_status_mask()
		| (AIRBORNE_VISUAL_STATUS_MASK if airborne else 0)
	)


func apply_multiplayer_visual_status_mask(status_mask: int) -> void:
	if not is_multiplayer_proxy or is_dead:
		return
	proxy_airborne_from_snapshot = (
		status_mask & AIRBORNE_VISUAL_STATUS_MASK
	) != 0
	if not proxy_airborne_from_snapshot:
		proxy_grounded_after_drop_latched = false
	_apply_proxy_airborne_visual(proxy_airborne_from_snapshot)
	super.apply_multiplayer_visual_status_mask(status_mask & BASE_VISUAL_STATUS_MASK)


func set_multiplayer_proxy_visual_active(active: bool) -> void:
	super.set_multiplayer_proxy_visual_active(active)
	if not is_multiplayer_proxy:
		return
	_apply_proxy_airborne_visual(proxy_airborne_from_snapshot)


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
	if not _accept_proxy_action(action_name, action_id, action_elapsed):
		return
	_play_proxy_action(
		action_name,
		direction,
		null,
		action_id,
		action_elapsed
	)


func play_multiplayer_enemy_target_action(
	action_name: StringName,
	target: Node2D,
	action_id: int
) -> void:
	play_multiplayer_enemy_target_action_with_context(
		action_name,
		target,
		global_position,
		action_id,
		0.0
	)


func play_multiplayer_enemy_target_action_with_context(
	action_name: StringName,
	target: Node2D,
	_action_position: Vector2,
	action_id: int,
	action_elapsed: float
) -> void:
	if not _accept_proxy_action(action_name, action_id, action_elapsed):
		return
	var direction := _direction_to_target(target)
	_play_proxy_action(
		action_name,
		direction,
		target,
		action_id,
		action_elapsed
	)


func _accept_proxy_action(
	action_name: StringName,
	action_id: int,
	action_elapsed: float
) -> bool:
	if not is_multiplayer_proxy or is_dead or action_id <= latest_proxy_action_id:
		return false
	latest_proxy_action_id = action_id
	if not is_finite(action_elapsed) or action_elapsed < 0.0:
		return false
	var lifetime := _get_proxy_action_lifetime(action_name)
	return (
		lifetime > 0.0
		and action_elapsed <= lifetime + ACTION_EXPIRY_TOLERANCE_SECONDS
	)


func _get_proxy_action_lifetime(action_name: StringName) -> float:
	if main_config == null:
		return 0.0
	match action_name:
		ACTION_ATTACK_WINDUP:
			return main_config.attack_windup
		ACTION_ATTACK_SLASH:
			return main_config.attack_slash_duration
		ACTION_SKILL1_WINDUP:
			return main_config.skill1_windup
		ACTION_SKILL1_DASH:
			return main_config.skill1_dash_duration
		ACTION_SKILL1_CIRCLE:
			return main_config.skill1_recovery
		ACTION_SKILL2_TAKEOFF:
			return (
				main_config.skill2_takeoff_duration
				+ main_config.skill2_tracking_duration
			)
		ACTION_SKILL2_DROP:
			return (
				main_config.skill2_drop_duration
				+ main_config.skill2_recovery
			)
		_:
			return 0.0


func _play_proxy_action(
	action_name: StringName,
	direction: Vector2,
	target: Node2D,
	action_id: int,
	elapsed: float
) -> void:
	if main_config == null:
		return
	var safe_direction := direction.normalized() if direction != Vector2.ZERO else _get_facing_direction()
	var safe_elapsed := maxf(elapsed, 0.0)
	_update_facing(safe_direction)
	match action_name:
		ACTION_ATTACK_WINDUP:
			_play_proxy_attack_warning(safe_direction, action_id, safe_elapsed)
		ACTION_ATTACK_SLASH:
			_play_multiplayer_proxy_action_animation(
				main_config.attack_animation_name,
				maxf(main_config.attack_slash_duration - safe_elapsed, 0.0) + 0.05
			)
			_restart_scene_animation(main_config.attack_animation_name)
			_set_attack_warning(0.0, safe_direction)
		ACTION_SKILL1_WINDUP:
			_play_multiplayer_proxy_action_animation(
				main_config.skill1_windup_animation_name,
				maxf(main_config.skill1_windup - safe_elapsed, 0.0) + 0.05
			)
			_play_proxy_skill1_line(target, safe_direction, action_id, safe_elapsed)
		ACTION_SKILL1_DASH:
			_hide_skill1_warning_line()
			_play_multiplayer_proxy_action_animation(
				main_config.skill1_dash_animation_name,
				maxf(main_config.skill1_dash_duration - safe_elapsed, 0.0) + 0.05
			)
		ACTION_SKILL1_CIRCLE:
			_play_multiplayer_proxy_action_animation(
				main_config.skill1_circle_animation_name,
				maxf(main_config.skill1_recovery - safe_elapsed, 0.0) + 0.05
			)
			_show_skill1_circle_ring()
			_queue_indicator_hide(skill1_circle_ring, main_config.skill1_recovery, action_id, safe_elapsed)
		ACTION_SKILL2_TAKEOFF:
			proxy_grounded_after_drop_latched = false
			proxy_airborne_from_snapshot = true
			if safe_elapsed < main_config.skill2_takeoff_duration:
				_begin_proxy_takeoff_visual(action_id, safe_elapsed)
				_play_multiplayer_proxy_action_animation(
					main_config.skill2_takeoff_animation_name,
					maxf(
						main_config.skill2_takeoff_duration - safe_elapsed,
						0.0
					) + 0.05
				)
			else:
				_clear_proxy_visual_override(action_id)
				_apply_proxy_airborne_visual(true)
		ACTION_SKILL2_DROP:
			_begin_proxy_drop_visual(action_id, safe_elapsed)
			_play_multiplayer_proxy_action_animation(
				main_config.skill2_drop_animation_name,
				maxf(
					main_config.skill2_drop_duration
					+ main_config.skill2_recovery
					- safe_elapsed,
					0.0
				) + 0.05
			)
			_set_skill2_fan_warning(true, safe_direction)
			_queue_indicator_hide(
				skill2_fan_warning,
				main_config.skill2_drop_duration,
				action_id,
				safe_elapsed
			)


func _play_proxy_attack_warning(direction: Vector2, action_id: int, elapsed: float) -> void:
	var duration := maxf(main_config.attack_windup, 0.01)
	var initial := clampf(elapsed / duration, 0.0, 1.0)
	_set_attack_warning(initial, direction)
	var tween := create_tween()
	tween.tween_method(
		func(progress: float) -> void:
			if action_id == latest_proxy_action_id:
				_set_attack_warning(progress, direction),
		initial,
		1.0,
		maxf(duration - elapsed, 0.0)
	)
	tween.tween_callback(
		func() -> void:
			if action_id == latest_proxy_action_id:
				_set_attack_warning(0.0, direction)
	)


func _play_proxy_skill1_line(
	target: Node2D,
	direction: Vector2,
	action_id: int,
	elapsed: float
) -> void:
	if target != null and is_instance_valid(target):
		_update_skill1_warning_line(target)
	else:
		skill1_warning_line.points = PackedVector2Array([
			Vector2.ZERO,
			direction * main_config.skill1_trigger_range,
		])
		skill1_warning_line.visible = true
	var remaining := maxf(main_config.skill1_windup - elapsed, 0.0)
	if remaining <= 0.0:
		_hide_skill1_warning_line()
		return
	var tween := create_tween()
	tween.tween_method(
		func(_progress: float) -> void:
			if action_id != latest_proxy_action_id:
				return
			if target != null and is_instance_valid(target):
				_update_skill1_warning_line(target),
		0.0,
		1.0,
		remaining
	)
	tween.tween_callback(
		func() -> void:
			if action_id == latest_proxy_action_id:
				_hide_skill1_warning_line()
	)


func _queue_indicator_hide(
	indicator: CanvasItem,
	duration: float,
	action_id: int,
	elapsed: float
) -> void:
	var remaining := maxf(duration - elapsed, 0.0)
	if remaining <= 0.0:
		indicator.visible = false
		return
	var tween := create_tween()
	tween.tween_interval(remaining)
	tween.tween_callback(
		func() -> void:
			if action_id == latest_proxy_action_id:
				indicator.visible = false
	)


func _set_airborne(active: bool, update_physics_shapes: bool) -> void:
	airborne = active
	if not update_physics_shapes or is_multiplayer_proxy:
		return
	_set_collision_shapes_disabled(body_collision_shapes, active)
	_set_collision_shapes_disabled(touch_damage_shapes, active)
	if touch_damage_area != null:
		touch_damage_area.set_deferred("monitoring", not active)
		touch_damage_area.set_deferred("monitorable", not active)
	if active:
		_clear_touching_players()


func _apply_proxy_airborne_visual(active: bool) -> void:
	if not is_multiplayer_proxy:
		return
	var action_body_override := (
		proxy_takeoff_visual_override or proxy_drop_visual_override
	)
	var effective_airborne := (
		active
		and not action_body_override
		and not proxy_grounded_after_drop_latched
	)
	var show_cross := effective_airborne and multiplayer_proxy_visual_active
	_set_skill2_cross_visible(show_cross)
	if animated_sprite != null:
		animated_sprite.visible = (
			not effective_airborne and multiplayer_proxy_visual_active
		)


func _begin_proxy_takeoff_visual(action_id: int, elapsed: float) -> void:
	proxy_visual_override_action_id = action_id
	proxy_takeoff_visual_override = true
	proxy_drop_visual_override = false
	_apply_proxy_airborne_visual(proxy_airborne_from_snapshot)
	var remaining := maxf(main_config.skill2_takeoff_duration - elapsed, 0.0)
	var tween := create_tween()
	tween.tween_interval(remaining)
	tween.tween_callback(
		func() -> void:
			if action_id != proxy_visual_override_action_id:
				return
			proxy_takeoff_visual_override = false
			_apply_proxy_airborne_visual(proxy_airborne_from_snapshot)
	)


func _begin_proxy_drop_visual(action_id: int, elapsed: float) -> void:
	proxy_visual_override_action_id = action_id
	proxy_takeoff_visual_override = false
	proxy_drop_visual_override = elapsed < main_config.skill2_drop_duration
	proxy_grounded_after_drop_latched = (
		elapsed >= main_config.skill2_drop_duration
	)
	_apply_proxy_airborne_visual(proxy_airborne_from_snapshot)
	if not proxy_drop_visual_override:
		return
	var remaining := maxf(main_config.skill2_drop_duration - elapsed, 0.0)
	var tween := create_tween()
	tween.tween_interval(remaining)
	tween.tween_callback(
		func() -> void:
			if action_id != proxy_visual_override_action_id:
				return
			proxy_drop_visual_override = false
			proxy_grounded_after_drop_latched = true
			_apply_proxy_airborne_visual(proxy_airborne_from_snapshot)
	)


func _clear_proxy_visual_override(action_id: int = 0) -> void:
	if action_id > 0:
		proxy_visual_override_action_id = action_id
	proxy_takeoff_visual_override = false
	proxy_drop_visual_override = false


func _set_attack_warning(progress: float, direction: Vector2) -> void:
	if attack_warning == null:
		return
	var clamped := clampf(progress, 0.0, 1.0)
	attack_warning.visible = clamped > 0.0
	attack_warning.rotation = direction.angle()
	attack_warning.modulate = Color(1.0, 1.0, 1.0, lerpf(0.08, 0.34, clamped))


func _update_skill1_warning_line(target: Node2D) -> void:
	if skill1_warning_line == null or target == null or not is_instance_valid(target):
		_hide_skill1_warning_line()
		return
	skill1_warning_line.points = PackedVector2Array([
		Vector2.ZERO,
		to_local(target.global_position),
	])
	skill1_warning_line.visible = true


func _hide_skill1_warning_line() -> void:
	if skill1_warning_line != null:
		skill1_warning_line.visible = false


func _show_skill1_circle_ring() -> void:
	if skill1_circle_ring == null:
		return
	skill1_circle_ring.visible = true
	skill1_circle_ring.scale = Vector2.ONE * (
		main_config.skill1_circle_radius / 36.0
		if main_config != null
		else 1.0
	)


func _hide_skill1_circle_ring() -> void:
	if skill1_circle_ring != null:
		skill1_circle_ring.visible = false


func _set_skill2_cross_visible(active: bool) -> void:
	if skill2_cross_marker != null:
		skill2_cross_marker.visible = active


func _set_skill2_fan_warning(active: bool, direction: Vector2) -> void:
	if skill2_fan_warning == null:
		return
	skill2_fan_warning.visible = active
	skill2_fan_warning.rotation = direction.angle()


func _hide_all_action_indicators() -> void:
	_set_attack_warning(0.0, Vector2.RIGHT)
	_hide_skill1_warning_line()
	_hide_skill1_circle_ring()
	_set_skill2_cross_visible(false)
	_set_skill2_fan_warning(false, Vector2.RIGHT)


func _direction_to_target(target: Node2D) -> Vector2:
	if target != null and is_instance_valid(target):
		var direction := global_position.direction_to(target.global_position)
		if direction != Vector2.ZERO:
			return direction
	return _get_facing_direction()


func _get_facing_direction() -> Vector2:
	return Vector2.LEFT if facing_left else Vector2.RIGHT


func _update_facing(direction: Vector2) -> void:
	if not is_zero_approx(direction.x):
		_set_facing_from_direction(direction)


func _broadcast_target_or_action(
	action_name: StringName,
	target: Node2D,
	direction: Vector2
) -> void:
	var player := target as Player
	if player != null and player.peer_id > 0:
		_broadcast_target_action(action_name, player.peer_id)
		return
	_broadcast_action(action_name, direction)


func _broadcast_action(action_name: StringName, direction: Vector2) -> void:
	action_sequence += 1
	if gameplay_gateway != null and is_instance_valid(gameplay_gateway):
		gameplay_gateway.broadcast_enemy_action(
			int(get_meta("net_id", 0)),
			action_name,
			direction,
			global_position,
			action_sequence
		)


func _broadcast_target_action(action_name: StringName, target_peer_id: int) -> void:
	action_sequence += 1
	if gameplay_gateway != null and is_instance_valid(gameplay_gateway):
		gameplay_gateway.broadcast_enemy_target_action(
			int(get_meta("net_id", 0)),
			action_name,
			target_peer_id,
			global_position,
			action_sequence
		)


func _get_multiplayer_damage_source_id(source_suffix: int) -> int:
	var net_id := int(get_meta("net_id", get_instance_id()))
	return maxi(net_id, 1) * 1000000 + maxi(source_suffix, 0)


func _find_nearest_target_in_range(radius: float) -> Node2D:
	if is_multiplayer_proxy or main_config == null or radius < 0.0:
		return null
	target_query_shape.radius = maxf(radius, 0.0)
	target_query.transform = Transform2D(0.0, global_position)
	var results := COMPLETE_SHAPE_QUERY_2D.intersect_shape_all(
		get_world_2d().direct_space_state,
		target_query,
		main_config.shape_query_batch_size
	)
	var nearest: Node2D = null
	var nearest_distance_squared := INF
	var nearest_instance_id := 0
	for result in results:
		var candidate := result.get("collider") as Node2D
		if not _is_ranged_combat_target_valid(candidate):
			continue
		var distance_squared := global_position.distance_squared_to(
			candidate.global_position
		)
		var instance_id := int(candidate.get_instance_id())
		if (
			nearest == null
			or distance_squared < nearest_distance_squared
			or (
				is_equal_approx(distance_squared, nearest_distance_squared)
				and instance_id < nearest_instance_id
			)
		):
			nearest = candidate
			nearest_distance_squared = distance_squared
			nearest_instance_id = instance_id
	return nearest


func _restart_scene_animation(animation_name: StringName) -> bool:
	if not _play_scene_animation(animation_name):
		return false
	animated_sprite.stop()
	animated_sprite.play(animation_name)
	animated_sprite.set_frame_and_progress(0, 0.0)
	return true


func has_released_runtime_visuals() -> bool:
	if animated_sprite == null or animated_sprite.sprite_frames == null:
		return false
	for animation_name: StringName in RUNTIME_ANIMATION_FRAME_COUNTS:
		if (
			not animated_sprite.sprite_frames.has_animation(animation_name)
			or animated_sprite.sprite_frames.get_frame_count(animation_name)
			!= int(RUNTIME_ANIMATION_FRAME_COUNTS[animation_name])
			or animated_sprite.sprite_frames.get_animation_loop(animation_name)
			!= (animation_name in [&"move", &"skill1_dash"])
		):
			return false
	return true
