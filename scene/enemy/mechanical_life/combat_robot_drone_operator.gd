extends "res://scene/enemy/simple_chase_layered_enemy.gd"
class_name CombatRobotDroneOperator

const OperatorConfig := preload(
	"res://resources/config/enemies/combat_robot_drone_operator_config.gd"
)
const ACTION_DEPLOY: StringName = &"combat_robot_drone_operator_deploy"
const WORLD_COLLISION_MASK := 1
const DEPLOY_ANIMATION_FPS := 30.0
const DEPLOY_ANIMATION_FRAME_COUNT := 3
const LAYERED_FAMILY_SCRIPT_PATH := (
	"res://scene/enemy/mechanical_life/combat_robot_drone_operator.gd"
)

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

# Authored Timer nodes remain canonical for LEGACY/COMPAT. Layered admission
# snapshots their remaining time into this deterministic event lane and stops
# the nodes; rollback restores the exact remaining Timer contract.
var layered_operator_clock_authority := false
var layered_deploy_time_left := 0.0
var layered_cooldown_time_left := 0.0
var layered_blocked_retry_time_left := 0.0
var layered_blocked_retry_armed := false
var layered_deploy_zero_behavior_elapsed := false
var layered_cooldown_zero_behavior_elapsed := false
var layered_blocked_retry_zero_behavior_elapsed := false
var layered_deploy_started_after_event := false
var layered_cooldown_started_after_event := false
var layered_blocked_retry_started_after_event := false
var layered_operator_timer_commit_active := false
var layered_operator_physics_delta_hint := 1.0 / 60.0
var layered_operator_selection_requested := false
var layered_operator_motion_pending := false
var layered_operator_navigation_target: Node2D = null
var layered_operator_contact_target: Enemy = null

# Reused bounded selection buffers avoid sorting and allocating the complete
# sensed cohort. Only the nearest configured candidates can issue World rays.
var nearest_target_buffer: Array[Node2D] = []
var nearest_distance_buffer: Array[float] = []
var nearest_kind_buffer: Array[int] = []
var nearest_id_buffer: Array[int] = []
var stale_target_id_buffer: Array[int] = []


func supports_dynamic_enemy_targeting() -> bool:
	return true


func supports_layered_area_authoritative_simulation() -> bool:
	return _is_exact_layered_drone_operator_family()


func supports_layered_contact_authoritative_simulation() -> bool:
	# The exact ordinary/elite closure shares one authored body/touch rectangle.
	# Shared Enemy contact consumes the directed motion fraction below, while the
	# independent AttackSenseArea remains live for ranged acquisition.
	return _is_exact_layered_drone_operator_family()


func supports_indexed_touch_authority() -> bool:
	# Player/Plant touch and AttackSenseArea are independent authored Areas. Keep
	# both authoritative until this family has a dedicated indexed-shape proof.
	return false


func get_layered_area_decision_interval_frames() -> int:
	# READY and COOLDOWN both choose their tracking direction every authored tick.
	return 1


func _is_exact_layered_drone_operator_family() -> bool:
	var implementation := get_script() as Script
	return (
		implementation != null
		and implementation.resource_path == LAYERED_FAMILY_SCRIPT_PATH
	)


func _ready() -> void:
	super._ready()
	if not objective_target_changed.is_connected(_on_objective_target_changed):
		objective_target_changed.connect(_on_objective_target_changed)
	_refresh_drone_motion_system()


func can_target_water_plant_objectives() -> bool:
	return true


func supports_centralized_authoritative_simulation() -> bool:
	return true


func _run_authoritative_physics_step(delta: float) -> void:
	_restore_operator_timer_authority_if_needed()
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


func prepare_layered_area_authoritative_simulation() -> void:
	var layered_mode_active := _is_layered_operator_scheduler_mode()
	var entering_layered_authority := (
		layered_mode_active and not layered_operator_clock_authority
	)
	super.prepare_layered_area_authoritative_simulation()
	if entering_layered_authority:
		_capture_operator_timer_authority()
	elif not layered_mode_active and layered_operator_clock_authority:
		_restore_operator_timer_authority()
	# Admission/rollback resets projections only; authored velocity is part of the
	# live state transferred between runners and must not be reconstructed.
	_clear_layered_operator_motion_plan(false)
	if entering_layered_authority and combat_state == CombatState.TRACKING_READY:
		# Admission must observe an overlap/objective that became live before the
		# coordinator claimed this node. AREA<->CONTACT reconfiguration preserves
		# an already queued request instead of inventing a second deployment.
		layered_operator_selection_requested = (
			layered_operator_selection_requested
			or (
				not layered_blocked_retry_armed
				and (
					not sensed_targets.is_empty()
					or _has_in_range_attackable_objective()
				)
			)
		)
		if layered_operator_selection_requested:
			request_layered_area_urgent_decision()


## DroneOperator settles inherited touch before its Timer/state work in the
## authored runner. Preserve that ordering in the centralized event phase.
func _layered_area_touch_damage_precedes_family_event() -> bool:
	return true


func _advance_layered_area_family_event_phase(delta: float) -> void:
	_clear_layered_operator_motion_plan()
	if not layered_operator_clock_authority or is_dead or is_multiplayer_proxy:
		return
	var safe_delta := maxf(delta, 0.0)
	if safe_delta > 0.0:
		layered_operator_physics_delta_hint = safe_delta
	# The event lane projects countdown values before the authored parent behavior.
	# A zero boundary is only marked here: the matching child Timer signal belongs
	# after that behavior, so the motion lane commits it later in the same tick.
	# Timers started by this tick's decision are advanced by that post-behavior lane
	# instead, exactly where their native physics Timer child would first run.
	match combat_state:
		CombatState.DEPLOY:
			if layered_deploy_started_after_event:
				pass
			elif layered_deploy_time_left > 0.0:
				layered_deploy_time_left = maxf(
					layered_deploy_time_left - safe_delta,
					0.0
				)
			else:
				layered_deploy_zero_behavior_elapsed = true
		CombatState.TRACKING_COOLDOWN:
			if layered_cooldown_started_after_event:
				pass
			elif layered_cooldown_time_left > 0.0:
				layered_cooldown_time_left = maxf(
					layered_cooldown_time_left - safe_delta,
					0.0
				)
			else:
				layered_cooldown_zero_behavior_elapsed = true
		CombatState.TRACKING_READY:
			if not layered_blocked_retry_armed:
				pass
			elif layered_blocked_retry_started_after_event:
				pass
			elif layered_blocked_retry_time_left > 0.0:
				layered_blocked_retry_time_left = maxf(
					layered_blocked_retry_time_left - safe_delta,
					0.0
				)
			else:
				layered_blocked_retry_zero_behavior_elapsed = true
	_publish_layered_operator_post_behavior_timer_due()


func _can_sleep_layered_area_family_event_phase() -> bool:
	return (
		combat_state == CombatState.TRACKING_READY
		and not layered_blocked_retry_armed
	)


func _simulate_layered_area_decision_body(delta: float) -> bool:
	if is_dead or is_multiplayer_proxy:
		velocity = Vector2.ZERO
		_clear_layered_operator_motion_plan()
		layered_area_decision_urgent = false
		_publish_layered_operator_post_behavior_timer_due()
		return true

	# A committed deployment deliberately retains its launch-time target and
	# faction snapshot. Target perception resumes only in tracking states.
	if combat_state == CombatState.DEPLOY:
		velocity = Vector2.ZERO
		_update_facing(locked_deploy_direction)
		_clear_layered_operator_motion_plan()
		layered_area_motion_state_known = true
		layered_area_decision_urgent = false
		_publish_layered_operator_post_behavior_timer_due()
		return true

	refresh_dynamic_combat_target_decision(Engine.get_physics_frames())
	if (
		combat_state == CombatState.TRACKING_READY
		and layered_operator_selection_requested
	):
		layered_operator_selection_requested = false
		if _try_select_and_begin_deploy():
			velocity = Vector2.ZERO
			_clear_layered_operator_motion_plan()
			layered_area_motion_state_known = true
			layered_area_decision_urgent = false
			_publish_layered_operator_post_behavior_timer_due()
			return true

	var tracking_target: Node2D = null
	if combat_state == CombatState.TRACKING_COOLDOWN:
		tracking_target = _get_live_last_attack_target()
	_update_tracking_movement(tracking_target, false)
	layered_operator_motion_pending = velocity != Vector2.ZERO
	layered_area_planned_move_direction = (
		velocity.normalized()
		if layered_operator_motion_pending
		else Vector2.ZERO
	)
	layered_area_motion_state_known = true
	layered_area_last_can_move = layered_operator_motion_pending
	layered_area_motion_phase_due = layered_operator_motion_pending
	layered_area_decision_urgent = false
	_publish_layered_operator_post_behavior_timer_due()
	return true


func _can_run_layered_area_motion() -> bool:
	return (
		not is_dead
		and combat_state != CombatState.DEPLOY
		and layered_operator_motion_pending
	)


func should_execute_layered_area_motion_phase() -> bool:
	return (
		_has_layered_operator_post_behavior_timer_work()
		or (_can_run_layered_area_motion() and velocity != Vector2.ZERO)
	)


func get_layered_area_planned_displacement(delta: float) -> Vector2:
	if not _can_run_layered_area_motion():
		return Vector2.ZERO
	return velocity * maxf(delta, 0.0)


func _simulate_layered_area_motion_body(delta: float) -> bool:
	var ordinary_motion_due := (
		_can_run_layered_area_motion() and velocity != Vector2.ZERO
	)
	if ordinary_motion_due:
		var safe_motion_fraction := 1.0
		var enemy_contact_target := get_layered_area_contact_target() as Enemy
		if enemy_contact_target != null:
			safe_motion_fraction = get_layered_area_directed_safe_motion_fraction(
				enemy_contact_target
			)
		velocity *= clampf(safe_motion_fraction, 0.0, 1.0)
		if velocity != Vector2.ZERO:
			_move_until_player_contact(maxf(delta, 0.0))
		if safe_motion_fraction < 1.0:
			velocity = Vector2.ZERO
	elif combat_state == CombatState.DEPLOY:
		velocity = Vector2.ZERO
	_clear_layered_operator_motion_plan(false)
	_advance_layered_operator_timers_started_after_event(delta)
	_commit_layered_operator_timeouts_after_behavior()
	return true


func _has_layered_operator_post_behavior_timer_work() -> bool:
	return (
		layered_deploy_zero_behavior_elapsed
		or layered_cooldown_zero_behavior_elapsed
		or layered_blocked_retry_zero_behavior_elapsed
		or layered_deploy_started_after_event
		or layered_cooldown_started_after_event
		or layered_blocked_retry_started_after_event
	)


func _publish_layered_operator_post_behavior_timer_due() -> void:
	if _has_layered_operator_post_behavior_timer_work():
		layered_area_motion_phase_due = true


func _advance_layered_operator_timers_started_after_event(delta: float) -> void:
	var safe_delta := maxf(delta, 0.0)
	if layered_deploy_started_after_event:
		layered_deploy_started_after_event = false
		if combat_state == CombatState.DEPLOY:
			layered_deploy_time_left = maxf(
				layered_deploy_time_left - safe_delta,
				0.0
			)
	if layered_cooldown_started_after_event:
		layered_cooldown_started_after_event = false
		if combat_state == CombatState.TRACKING_COOLDOWN:
			layered_cooldown_time_left = maxf(
				layered_cooldown_time_left - safe_delta,
				0.0
			)
	if layered_blocked_retry_started_after_event:
		layered_blocked_retry_started_after_event = false
		if (
			combat_state == CombatState.TRACKING_READY
			and layered_blocked_retry_armed
		):
			layered_blocked_retry_time_left = maxf(
				layered_blocked_retry_time_left - safe_delta,
				0.0
			)


func _commit_layered_operator_timeouts_after_behavior() -> void:
	if not layered_operator_clock_authority:
		return
	layered_operator_timer_commit_active = true
	# Scene child order is DeployTimer, CooldownTimer, BlockedRetryTimer. A Timer
	# started by one of these callbacks is intentionally not advanced again here.
	if layered_deploy_zero_behavior_elapsed:
		layered_deploy_zero_behavior_elapsed = false
		_complete_deploy_phase()
	if layered_cooldown_zero_behavior_elapsed:
		layered_cooldown_zero_behavior_elapsed = false
		_complete_cooldown_phase()
	if layered_blocked_retry_zero_behavior_elapsed:
		layered_blocked_retry_zero_behavior_elapsed = false
		_complete_blocked_retry_phase()
	layered_operator_timer_commit_active = false


func get_layered_area_contact_target() -> Node2D:
	if (
		layered_operator_contact_target == null
		or not is_instance_valid(layered_operator_contact_target)
		or not can_attack_combat_target(layered_operator_contact_target)
	):
		return null
	return layered_operator_contact_target


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
	nearest_kind_buffer.clear()
	nearest_id_buffer.clear()
	stale_target_id_buffer.clear()
	_stop_operator_timers()
	layered_operator_clock_authority = false
	layered_deploy_time_left = 0.0
	layered_cooldown_time_left = 0.0
	layered_blocked_retry_time_left = 0.0
	layered_blocked_retry_armed = false
	layered_deploy_zero_behavior_elapsed = false
	layered_cooldown_zero_behavior_elapsed = false
	layered_blocked_retry_zero_behavior_elapsed = false
	layered_deploy_started_after_event = false
	layered_cooldown_started_after_event = false
	layered_blocked_retry_started_after_event = false
	layered_operator_timer_commit_active = false
	layered_operator_physics_delta_hint = 1.0 / 60.0
	layered_operator_selection_requested = false
	_clear_layered_operator_motion_plan()
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
		if _is_layered_operator_scheduler_mode():
			_request_operator_selection()
		else:
			_try_select_and_begin_deploy()


func _on_attack_sense_area_body_exited(body: Node2D) -> void:
	if body != null:
		sensed_targets.erase(body.get_instance_id())
	if combat_state == CombatState.TRACKING_READY and sensed_targets.is_empty():
		if not _has_in_range_attackable_objective():
			_stop_blocked_retry()
	if _is_layered_operator_scheduler_mode():
		request_layered_area_urgent_decision()


func _on_objective_target_changed(
	_enemy: Enemy,
	_current_target: Node2D
) -> void:
	if (
		is_dead
		or is_multiplayer_proxy
		or combat_state != CombatState.TRACKING_READY
	):
		return
	if _is_layered_operator_scheduler_mode():
		_request_operator_selection()
	else:
		_try_select_and_begin_deploy()


func _on_deploy_timer_timeout() -> void:
	if layered_operator_clock_authority:
		return
	if is_dead or is_multiplayer_proxy or combat_state != CombatState.DEPLOY:
		return
	_complete_deploy_phase()


func _complete_deploy_phase() -> void:
	if is_dead or is_multiplayer_proxy or combat_state != CombatState.DEPLOY:
		return
	layered_deploy_time_left = 0.0
	layered_deploy_zero_behavior_elapsed = false
	layered_deploy_started_after_event = false
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
		_complete_cooldown_phase()
		return
	_start_cooldown(cooldown)


func _on_cooldown_timer_timeout() -> void:
	if layered_operator_clock_authority:
		return
	if (
		is_dead
		or is_multiplayer_proxy
		or combat_state != CombatState.TRACKING_COOLDOWN
	):
		return
	_complete_cooldown_phase()


func _complete_cooldown_phase() -> void:
	if (
		is_dead
		or is_multiplayer_proxy
		or combat_state != CombatState.TRACKING_COOLDOWN
	):
		return
	layered_cooldown_time_left = 0.0
	layered_cooldown_zero_behavior_elapsed = false
	layered_cooldown_started_after_event = false
	combat_state = CombatState.TRACKING_READY
	last_attack_target = null
	_reset_ranged_attack_position_state()
	_clear_cached_navigation_move_direction()
	if layered_operator_clock_authority and not layered_operator_timer_commit_active:
		_request_operator_selection()
	else:
		_try_select_and_begin_deploy()


func _on_blocked_retry_timer_timeout() -> void:
	if layered_operator_clock_authority:
		return
	_complete_blocked_retry_phase()


func _complete_blocked_retry_phase() -> void:
	layered_blocked_retry_armed = false
	layered_blocked_retry_time_left = 0.0
	layered_blocked_retry_zero_behavior_elapsed = false
	layered_blocked_retry_started_after_event = false
	if is_dead or is_multiplayer_proxy or combat_state != CombatState.TRACKING_READY:
		return
	if layered_operator_clock_authority and not layered_operator_timer_commit_active:
		_request_operator_selection()
	else:
		_try_select_and_begin_deploy()


func _try_select_and_begin_deploy() -> bool:
	if (
		is_dead
		or is_multiplayer_proxy
		or combat_state != CombatState.TRACKING_READY
		or operator_config_cache == null
	):
		return false
	var designated_target := _get_active_designated_attack_target()
	if designated_target != null:
		if not _is_target_within_attack_range(designated_target):
			_stop_blocked_retry()
			return false
		if _is_world_segment_clear(
			designated_target.global_position,
			WORLD_COLLISION_MASK
		) and _begin_deploy(designated_target):
			_stop_blocked_retry()
			return true
		_arm_blocked_retry_if_needed(true)
		return false

	_collect_nearest_attack_candidates()
	for candidate_target in nearest_target_buffer:
		if not _is_world_segment_clear(
			candidate_target.global_position,
			WORLD_COLLISION_MASK
		):
			continue
		if _begin_deploy(candidate_target):
			_stop_blocked_retry()
			return true

	_arm_blocked_retry_if_needed()
	return false


func _collect_nearest_attack_candidates() -> void:
	nearest_target_buffer.clear()
	nearest_distance_buffer.clear()
	nearest_kind_buffer.clear()
	nearest_id_buffer.clear()
	stale_target_id_buffer.clear()
	if operator_config_cache == null:
		return

	var attack_range := maxf(operator_config_cache.attack_range, 0.0)
	var attack_range_squared := attack_range * attack_range
	var check_limit := maxi(operator_config_cache.visible_target_check_limit, 1)
	var proactive_target := get_attackable_objective()
	if proactive_target != null:
		_insert_attack_candidate_if_in_range(
			proactive_target,
			attack_range_squared,
			check_limit
		)
	for target_id_variant in sensed_targets:
		var target_id := int(target_id_variant)
		var target_variant: Variant = sensed_targets.get(target_id)
		if target_variant == null or not is_instance_valid(target_variant):
			stale_target_id_buffer.append(target_id)
			continue
		var target := target_variant as Node2D
		if not _is_ranged_combat_target_valid(target):
			stale_target_id_buffer.append(target_id)
			continue
		_insert_attack_candidate_if_in_range(
			target,
			attack_range_squared,
			check_limit
		)

	for stale_target_id in stale_target_id_buffer:
		sensed_targets.erase(stale_target_id)


func _insert_attack_candidate_if_in_range(
	target: Node2D,
	attack_range_squared: float,
	check_limit: int
) -> void:
	if not _is_ranged_combat_target_valid(target):
		return
	for existing_target in nearest_target_buffer:
		if existing_target == target:
			return
	var distance_squared := global_position.distance_squared_to(
		target.global_position
	)
	# Area2D overlap includes the target body's own radius. The explicit center
	# check preserves the authored 80-pixel targeting boundary.
	if distance_squared > attack_range_squared:
		return
	_insert_nearest_candidate(
		target,
		distance_squared,
		_get_target_stable_kind(target),
		_get_target_stable_id(target),
		check_limit
	)


func _insert_nearest_candidate(
	target: Node2D,
	distance_squared: float,
	target_kind: int,
	target_id: int,
	check_limit: int
) -> void:
	var insert_index := nearest_target_buffer.size()
	for candidate_index in range(nearest_target_buffer.size()):
		var existing_distance := nearest_distance_buffer[candidate_index]
		var existing_kind := nearest_kind_buffer[candidate_index]
		var existing_id := nearest_id_buffer[candidate_index]
		if (
			distance_squared < existing_distance
			or (
				distance_squared == existing_distance
				and (
					target_kind < existing_kind
					or (
						target_kind == existing_kind
						and target_id < existing_id
					)
				)
			)
		):
			insert_index = candidate_index
			break

	if insert_index >= check_limit:
		return
	nearest_target_buffer.insert(insert_index, target)
	nearest_distance_buffer.insert(insert_index, distance_squared)
	nearest_kind_buffer.insert(insert_index, target_kind)
	nearest_id_buffer.insert(insert_index, target_id)
	if nearest_target_buffer.size() <= check_limit:
		return
	nearest_target_buffer.pop_back()
	nearest_distance_buffer.pop_back()
	nearest_kind_buffer.pop_back()
	nearest_id_buffer.pop_back()


func _get_active_designated_attack_target() -> Node2D:
	if not targeting_state.is_active_target_assigned():
		return null
	return get_attackable_objective()


func _has_in_range_attackable_objective() -> bool:
	var target := get_attackable_objective()
	return target != null and _is_target_within_attack_range(target)


func _is_target_within_attack_range(target: Node2D) -> bool:
	if operator_config_cache == null or not _is_ranged_combat_target_valid(target):
		return false
	var attack_range := maxf(operator_config_cache.attack_range, 0.0)
	return global_position.distance_squared_to(target.global_position) <= (
		attack_range * attack_range
	)


func _get_target_stable_kind(target: Node2D) -> int:
	if target is Player:
		return CombatTargetDescriptor.Kind.PLAYER
	if target is PlantDefense:
		return CombatTargetDescriptor.Kind.PLANT
	if target is Enemy:
		return CombatTargetDescriptor.Kind.ENEMY
	return CombatTargetDescriptor.Kind.NONE


func _get_target_stable_id(target: Node2D) -> int:
	var player_target := target as Player
	if player_target != null and player_target.peer_id > 0:
		return player_target.peer_id
	var enemy_target := target as Enemy
	if enemy_target != null:
		if enemy_target.combat_target_index_net_id > 0:
			return enemy_target.combat_target_index_net_id
		var enemy_net_id := int(enemy_target.get_meta(&"net_id", 0))
		if enemy_net_id > 0:
			return enemy_net_id
	var metadata_id := int(target.get_meta(&"net_id", 0))
	return metadata_id if metadata_id > 0 else target.get_instance_id()


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
	_stop_blocked_retry()
	_clear_navigation_path()
	_set_ranged_attack_position_held(true)
	_update_facing(locked_deploy_direction)
	_play_scene_animation(operator_config_cache.deploy_animation_name)
	_start_deploy_delay(maxf(operator_config_cache.deploy_delay, 0.001))
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

	if (
		combat_runtime == null
		or not is_instance_valid(combat_runtime)
		or gameplay_gateway == null
		or not is_instance_valid(gameplay_gateway)
	):
		return false
	var spawn_parent: Node = combat_runtime
	var acquired_node: Node = null
	var uses_registered_pool := combat_runtime.has_session_object_pool_scene(
		operator_config_cache.drone_scene
	)
	if uses_registered_pool:
		acquired_node = combat_runtime.acquire_session_object(
			operator_config_cache.drone_scene,
			false
		)
	else:
		acquired_node = operator_config_cache.drone_scene.instantiate()

	var drone := acquired_node as CombatRobotSuicideDrone
	if drone == null:
		_release_failed_drone_node(acquired_node)
		return false
	drone.bind_gameplay_context(combat_runtime, gameplay_gateway)
	if drone.get_parent() == null:
		spawn_parent.add_child(drone)
	elif drone.get_parent() != spawn_parent and not uses_registered_pool:
		drone.reparent(spawn_parent)

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
		drone_motion_system,
		create_damage_source_snapshot(
			0,
			operator_config_cache.projectile_type
		)
	)
	if not drone.begin_deployment():
		drone.retire()
		return false

	gameplay_gateway.register_local_projectile(
		drone,
		operator_config_cache.projectile_type,
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


func _arm_blocked_retry_if_needed(force_retry: bool = false) -> void:
	if (
		operator_config_cache == null
		or combat_state != CombatState.TRACKING_READY
		or (
			not force_retry
			and sensed_targets.is_empty()
			and not _has_in_range_attackable_objective()
		)
	):
		_stop_blocked_retry()
		return
	_start_blocked_retry(maxf(
		operator_config_cache.blocked_retry_interval,
		0.01
	))


func _get_live_last_attack_target() -> Node2D:
	if _is_ranged_combat_target_valid(last_attack_target):
		return last_attack_target
	last_attack_target = null
	return null


func _update_tracking_movement(
	tracking_target: Node2D,
	apply_motion: bool = true
) -> void:
	layered_operator_navigation_target = null
	layered_operator_contact_target = null
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
	layered_operator_navigation_target = navigation_target
	_publish_layered_operator_contact_target(navigation_target)
	var move_direction := _get_operator_navigation_move_direction(
		navigation_target
	)
	velocity = move_direction * get_effective_move_speed()
	_update_facing(move_direction)
	if apply_motion:
		_move_until_player_contact()


func _get_navigation_move_direction(_delta: float) -> Vector2:
	var navigation_target := layered_operator_navigation_target
	if navigation_target == null or not is_instance_valid(navigation_target):
		navigation_target = objective_target
	if navigation_target == null or not is_instance_valid(navigation_target):
		return Vector2.ZERO
	return _get_operator_navigation_move_direction(navigation_target)


func _get_operator_navigation_move_direction(target: Node2D) -> Vector2:
	return _get_safe_navigation_move_direction(
		target,
		pathfinder,
		waypoint_arrival_distance
	)


func _publish_layered_operator_contact_target(target: Node2D) -> void:
	layered_operator_contact_target = null
	if target == null or not is_instance_valid(target):
		return
	var enemy_target := target as Enemy
	if enemy_target == null or not can_attack_combat_target(enemy_target):
		return
	layered_operator_contact_target = enemy_target


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


func _is_layered_operator_scheduler_mode() -> bool:
	var coordinator := enemy_simulation_coordinator
	# Initial registration prepares the family before Enemy stores its coordinator
	# pointer. The bound runtime is therefore the admission-mode authority at that
	# boundary; rollback has already changed the same coordinator to LEGACY.
	if (
		(coordinator == null or not is_instance_valid(coordinator))
		and combat_runtime != null
		and is_instance_valid(combat_runtime)
	):
		coordinator = combat_runtime.get_enemy_simulation_coordinator()
	if coordinator == null or not is_instance_valid(coordinator):
		return false
	return coordinator.mode in [
		EnemySimulationPolicy.Mode.LAYERED_AREA,
		EnemySimulationPolicy.Mode.LAYERED_CONTACT,
	]


func _capture_operator_timer_authority() -> void:
	layered_operator_clock_authority = true
	layered_deploy_time_left = (
		maxf(deploy_timer.time_left, 0.0)
		if deploy_timer != null and not deploy_timer.is_stopped()
		else 0.0
	)
	layered_cooldown_time_left = (
		maxf(cooldown_timer.time_left, 0.0)
		if cooldown_timer != null and not cooldown_timer.is_stopped()
		else 0.0
	)
	layered_blocked_retry_time_left = (
		maxf(blocked_retry_timer.time_left, 0.0)
		if blocked_retry_timer != null and not blocked_retry_timer.is_stopped()
		else 0.0
	)
	layered_blocked_retry_armed = (
		blocked_retry_timer != null and not blocked_retry_timer.is_stopped()
	)
	layered_deploy_zero_behavior_elapsed = false
	layered_cooldown_zero_behavior_elapsed = false
	layered_blocked_retry_zero_behavior_elapsed = false
	layered_deploy_started_after_event = false
	layered_cooldown_started_after_event = false
	layered_blocked_retry_started_after_event = false
	layered_operator_timer_commit_active = false
	_stop_operator_timers()


func _restore_operator_timer_authority_if_needed() -> void:
	if (
		layered_operator_clock_authority
		and not _is_layered_operator_scheduler_mode()
	):
		_restore_operator_timer_authority()


func _restore_operator_timer_authority() -> void:
	if not layered_operator_clock_authority:
		return
	var deploy_time_left := layered_deploy_time_left
	var cooldown_time_left := layered_cooldown_time_left
	var blocked_retry_time_left := layered_blocked_retry_time_left
	var blocked_retry_armed := layered_blocked_retry_armed
	var deploy_zero_behavior_elapsed := layered_deploy_zero_behavior_elapsed
	var cooldown_zero_behavior_elapsed := layered_cooldown_zero_behavior_elapsed
	var blocked_retry_zero_behavior_elapsed := (
		layered_blocked_retry_zero_behavior_elapsed
	)
	layered_operator_clock_authority = false
	_stop_operator_timers()
	layered_deploy_time_left = 0.0
	layered_cooldown_time_left = 0.0
	layered_blocked_retry_time_left = 0.0
	layered_blocked_retry_armed = false
	layered_deploy_zero_behavior_elapsed = false
	layered_cooldown_zero_behavior_elapsed = false
	layered_blocked_retry_zero_behavior_elapsed = false
	layered_deploy_started_after_event = false
	layered_cooldown_started_after_event = false
	layered_blocked_retry_started_after_event = false
	layered_operator_timer_commit_active = false
	match combat_state:
		CombatState.DEPLOY:
			if deploy_zero_behavior_elapsed:
				_on_deploy_timer_timeout()
			elif deploy_time_left > 0.0 and deploy_timer != null:
				deploy_timer.start(deploy_time_left)
			elif deploy_timer != null:
				deploy_timer.start(_get_operator_zero_boundary_restore_delay())
		CombatState.TRACKING_COOLDOWN:
			if cooldown_zero_behavior_elapsed:
				_on_cooldown_timer_timeout()
			elif cooldown_time_left > 0.0 and cooldown_timer != null:
				cooldown_timer.start(cooldown_time_left)
			elif cooldown_timer != null:
				cooldown_timer.start(_get_operator_zero_boundary_restore_delay())
		CombatState.TRACKING_READY:
			if blocked_retry_armed:
				if blocked_retry_zero_behavior_elapsed:
					_on_blocked_retry_timer_timeout()
				elif (
					blocked_retry_time_left > 0.0
					and blocked_retry_timer != null
				):
					blocked_retry_timer.start(blocked_retry_time_left)
				elif blocked_retry_timer != null:
					blocked_retry_timer.start(
						_get_operator_zero_boundary_restore_delay()
					)


func _get_operator_zero_boundary_restore_delay() -> float:
	# A zero countdown with no elapsed zero-boundary behavior still owes exactly
	# one native parent callback before timeout. Keep the restored native Timer at
	# the same observable zero boundary while a tiny positive delay guarantees its
	# callback remains in the next child-Timer slot rather than mode-switch code.
	return minf(
		maxf(layered_operator_physics_delta_hint * 0.5, 0.000000001),
		0.000001
	)


func _start_deploy_delay(duration: float) -> void:
	layered_deploy_zero_behavior_elapsed = false
	layered_deploy_started_after_event = false
	if layered_operator_clock_authority:
		layered_deploy_time_left = maxf(duration, 0.001)
		layered_deploy_started_after_event = (
			not layered_operator_timer_commit_active
		)
		_publish_layered_operator_post_behavior_timer_due()
		return
	deploy_timer.start(maxf(duration, 0.001))


func _start_cooldown(duration: float) -> void:
	layered_cooldown_zero_behavior_elapsed = false
	layered_cooldown_started_after_event = false
	if layered_operator_clock_authority:
		layered_cooldown_time_left = maxf(duration, 0.0)
		layered_cooldown_started_after_event = (
			not layered_operator_timer_commit_active
		)
		_publish_layered_operator_post_behavior_timer_due()
		return
	cooldown_timer.start(maxf(duration, 0.0))


func _start_blocked_retry(duration: float) -> void:
	layered_blocked_retry_armed = true
	layered_blocked_retry_zero_behavior_elapsed = false
	layered_blocked_retry_started_after_event = false
	if layered_operator_clock_authority:
		layered_blocked_retry_time_left = maxf(duration, 0.01)
		layered_blocked_retry_started_after_event = (
			not layered_operator_timer_commit_active
		)
		# READY can hold an infinite sparse-event sleep certificate. A regular
		# decision is still allowed to discover a blocked candidate and arm this
		# Timer, so explicitly invalidate that certificate and enqueue the event
		# lane which now owns the retry deadline.
		request_layered_area_urgent_decision()
		_publish_layered_operator_post_behavior_timer_due()
		return
	blocked_retry_timer.start(maxf(duration, 0.01))


func _stop_blocked_retry() -> void:
	layered_blocked_retry_armed = false
	layered_blocked_retry_time_left = 0.0
	layered_blocked_retry_zero_behavior_elapsed = false
	layered_blocked_retry_started_after_event = false
	if blocked_retry_timer != null:
		blocked_retry_timer.stop()


func _request_operator_selection() -> void:
	if combat_state != CombatState.TRACKING_READY:
		return
	layered_operator_selection_requested = true
	request_layered_area_urgent_decision()


func _clear_layered_operator_motion_plan(clear_velocity: bool = true) -> void:
	layered_operator_motion_pending = false
	layered_operator_navigation_target = null
	layered_operator_contact_target = null
	layered_area_planned_move_direction = Vector2.ZERO
	layered_area_last_can_move = false
	layered_area_motion_phase_due = false
	if clear_velocity:
		velocity = Vector2.ZERO


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
	nearest_kind_buffer.clear()
	nearest_id_buffer.clear()
	stale_target_id_buffer.clear()
	layered_deploy_time_left = 0.0
	layered_cooldown_time_left = 0.0
	layered_blocked_retry_time_left = 0.0
	layered_blocked_retry_armed = false
	layered_deploy_zero_behavior_elapsed = false
	layered_cooldown_zero_behavior_elapsed = false
	layered_blocked_retry_zero_behavior_elapsed = false
	layered_deploy_started_after_event = false
	layered_cooldown_started_after_event = false
	layered_blocked_retry_started_after_event = false
	layered_operator_timer_commit_active = false
	layered_operator_selection_requested = false
	_clear_layered_operator_motion_plan()
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
	if gameplay_gateway != null and is_instance_valid(gameplay_gateway):
		gameplay_gateway.broadcast_enemy_action(
			int(get_meta("net_id", 0)),
			action_name,
			direction,
			global_position,
			action_sequence
		)
