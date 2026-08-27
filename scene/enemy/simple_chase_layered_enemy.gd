@abstract
extends Enemy
class_name SimpleChaseLayeredEnemy

## Shared authoritative runner for enemies whose default behavior is a
## navigation-driven chase with touch damage. Family state machines may extend
## the event/decision/motion gates below, but must keep gameplay mutations in
## their matching phase.

## LAYERED_AREA throttles target and navigation decisions. Event timers and
## accepted movement remain expressed in physics ticks.
@export_range(1, 60, 1, "or_greater") var layered_area_decision_interval_frames := (
	EnemySimulationPolicy.DEFAULT_LAYERED_AREA_DECISION_INTERVAL_FRAMES
)

var layered_area_planned_move_direction := Vector2.ZERO
var layered_area_last_can_move := false
var layered_area_motion_state_known := false


## Supplies the family-specific navigation policy used by both COMPAT and
## layered decisions. Implementations should use Enemy's safe navigation cache
## so get_next_layered_area_decision_physics_frame() remains an exact deadline.
@abstract func _get_navigation_move_direction(delta: float) -> Vector2


## Commits orientation-dependent visuals and collision geometry before planned
## contact geometry is captured for the tick.
@abstract func _update_facing(move_direction: Vector2) -> void


func supports_centralized_authoritative_simulation() -> bool:
	return true


func supports_layered_area_authoritative_simulation() -> bool:
	return true


## The base SimpleChase contract has already passed shared-contact shadow
## parity. Composite or semantically different subclasses must explicitly
## fail-close this capability without giving up LAYERED_AREA scheduling.
func supports_layered_contact_authoritative_simulation() -> bool:
	return supports_layered_area_authoritative_simulation()


func supports_dynamic_enemy_targeting() -> bool:
	return true


func supports_indexed_touch_authority() -> bool:
	return supports_layered_area_authoritative_simulation()


func get_layered_area_decision_interval_frames() -> int:
	return maxi(layered_area_decision_interval_frames, 1)


func uses_layered_area_physics_phase_decisions() -> bool:
	return true


func is_layered_area_decision_due_for_physics_frame(physics_frame: int) -> bool:
	var interval := get_layered_area_decision_interval_frames()
	return (
		interval <= 1
		or posmod(physics_frame + navigation_update_frame_offset, interval) == 0
	)


func get_layered_area_decision_phase_offset() -> int:
	return navigation_update_frame_offset


## The full-decision cadence is only an upper bound. A deferred navigation
## request, zero-direction retry, or cached-path refresh may require an earlier
## decision without re-running a family state machine.
func get_next_layered_area_decision_physics_frame(
	after_physics_frame: int
) -> int:
	var full_decision_frame := super.get_next_layered_area_decision_physics_frame(
		after_physics_frame
	)
	if (
		not layered_area_motion_state_known
		or not layered_area_last_can_move
		or objective_target == null
		or not is_instance_valid(objective_target)
	):
		return full_decision_frame
	if navigation_refresh_deferred:
		return mini(full_decision_frame, after_physics_frame + 1)
	var navigation_deadline := (
		navigation_zero_direction_retry_frame
		if cached_navigation_move_direction == Vector2.ZERO
		else navigation_next_refresh_physics_frame
	)
	if navigation_deadline <= after_physics_frame:
		return full_decision_frame
	return mini(full_decision_frame, navigation_deadline)


func get_layered_area_planned_displacement(delta: float) -> Vector2:
	if not _can_run_layered_area_motion():
		return Vector2.ZERO
	return (
		layered_area_planned_move_direction
		* _get_move_speed()
		* maxf(delta, 0.0)
	)


## Coordinator admission and rollback both enter through this reset boundary.
## Subclasses overriding it must call super before restoring family state.
func prepare_layered_area_authoritative_simulation() -> void:
	super.prepare_layered_area_authoritative_simulation()
	layered_area_planned_move_direction = Vector2.ZERO
	layered_area_last_can_move = false
	layered_area_motion_state_known = false
	layered_area_event_phase_sleeping = false
	layered_area_event_sleep_until_physics_frame = -1
	layered_area_motion_phase_due = false


func request_layered_area_urgent_decision() -> void:
	layered_area_event_phase_sleeping = false
	layered_area_event_sleep_until_physics_frame = -1
	super.request_layered_area_urgent_decision()


func uses_trusted_layered_phase_entrypoints() -> bool:
	return true


func simulate_layered_area_event_phase(
	delta: float,
	simulation_tick: int,
	token: int
) -> bool:
	var previous_event_tick := layered_area_last_event_tick
	if not _accept_layered_area_event_phase(token, simulation_tick):
		return false
	var elapsed_ticks := _get_layered_area_elapsed_event_ticks(
		simulation_tick,
		previous_event_tick
	)
	return _simulate_layered_area_event_body(
		delta * float(elapsed_ticks),
		delta,
		elapsed_ticks
	)


func simulate_trusted_layered_area_event_phase(
	delta: float,
	simulation_tick: int
) -> bool:
	var previous_event_tick := layered_area_last_event_tick
	scheduled_authoritative_step_count += 1
	layered_area_last_event_tick = simulation_tick
	var elapsed_ticks := _get_layered_area_elapsed_event_ticks(
		simulation_tick,
		previous_event_tick
	)
	return _simulate_layered_area_event_body(
		delta * float(elapsed_ticks),
		delta,
		elapsed_ticks
	)


func _get_layered_area_elapsed_event_delta(
	physics_delta: float,
	simulation_tick: int,
	previous_event_tick: int
) -> float:
	return physics_delta * float(_get_layered_area_elapsed_event_ticks(
		simulation_tick,
		previous_event_tick
	))


func _get_layered_area_elapsed_event_ticks(
	simulation_tick: int,
	previous_event_tick: int
) -> int:
	return (
		maxi(simulation_tick - previous_event_tick, 1)
		if previous_event_tick >= 0
		else 1
	)


func _simulate_layered_area_event_body(
	elapsed_delta: float,
	physics_delta: float,
	_elapsed_ticks: int
) -> bool:
	if is_dead:
		velocity = Vector2.ZERO
		layered_area_planned_move_direction = Vector2.ZERO
		return true

	# CardboardMonster's authored runner settles contact damage before its Knight
	# state machine. Most families do the inverse. Keep the default ordering byte-
	# for-byte compatible while allowing that explicit family contract to route
	# the same deadline-based touch settlement ahead of its event hook.
	var advances_touch_damage := _advances_layered_area_touch_damage_event()
	var touch_precedes_family := (
		advances_touch_damage
		and _layered_area_touch_damage_precedes_family_event()
	)
	if touch_precedes_family:
		_update_touch_damage(physics_delta)
	_advance_layered_area_family_event_phase(elapsed_delta)
	if advances_touch_damage and not touch_precedes_family:
		# Cooldown readiness is an absolute physics-frame deadline. Family timers
		# still receive their complete elapsed delta above, while touch damage does
		# no per-frame countdown work.
		_update_touch_damage(physics_delta)
	var can_move := _can_run_layered_area_motion()
	if not layered_area_motion_state_known or can_move != layered_area_last_can_move:
		request_layered_area_urgent_decision()
	layered_area_motion_state_known = true
	layered_area_last_can_move = can_move
	if not can_move:
		layered_area_planned_move_direction = Vector2.ZERO
		velocity = Vector2.ZERO
	layered_area_motion_phase_due = (
		can_move and not layered_area_planned_move_direction.is_zero_approx()
	)
	layered_area_event_phase_sleeping = _can_enter_layered_area_event_sleep()
	layered_area_event_sleep_until_physics_frame = (
		_get_layered_area_event_sleep_until_physics_frame(physics_delta)
		if layered_area_event_phase_sleeping
		else -1
	)
	return true


func can_sleep_layered_area_event_phase() -> bool:
	return (
		layered_area_event_phase_sleeping
		and (
			layered_area_event_sleep_until_physics_frame < 0
			or Engine.get_physics_frames()
				< layered_area_event_sleep_until_physics_frame
		)
	)


func acknowledge_trusted_sleeping_layered_area_event_phase(
	simulation_tick: int
) -> bool:
	scheduled_authoritative_step_count += 1
	layered_area_last_event_tick = simulation_tick
	return true


func _can_enter_layered_area_event_sleep() -> bool:
	var has_stable_touch_cooldown := (
		_has_sleepable_layered_touch_damage_cooldown()
	)
	return (
		not is_dead
		and objective_target != null
		and is_instance_valid(objective_target)
		and not (objective_target is Enemy)
		and layered_area_motion_state_known
		and _can_sleep_layered_area_family_event_phase()
		and (
			has_stable_touch_cooldown
			or (
				indexed_touch_contact_snapshot_is_empty()
				and layered_area_last_can_move
			)
		)
	)


## Event hook: advance deterministic family timers and validate committed state.
func _advance_layered_area_family_event_phase(_delta: float) -> void:
	pass


## Event-order hook: default families advance state before touch damage. Override
## only when the authored COMPAT runner explicitly settles touch first.
func _layered_area_touch_damage_precedes_family_event() -> bool:
	return false


## Event-presence hook: some state-machine runners inherit movement/contact
## selection from Enemy without ever advancing touch damage. Their layered path
## must not invent a new cooldown/damage tick. A derived family that explicitly
## authored the call may opt back in independently of event ordering.
func _advances_layered_area_touch_damage_event() -> bool:
	return true


## Event hook: prevent sparse sleep while family event state needs polling.
func _can_sleep_layered_area_family_event_phase() -> bool:
	return true


## Event deadline hook. Family implementations may return an earlier wake frame
## after combining their own timer with super's touch-cooldown deadline.
func _get_layered_area_event_sleep_until_physics_frame(
	physics_delta: float
) -> int:
	if (
		not _has_sleepable_layered_touch_damage_cooldown()
	):
		return -1
	return get_touch_damage_cooldown_deadline_physics_frame()


func simulate_layered_area_decision_phase(
	delta: float,
	simulation_tick: int,
	token: int
) -> bool:
	if not _accept_layered_area_followup_phase(token, simulation_tick):
		return false
	return _simulate_layered_area_decision_body(delta)


func simulate_trusted_layered_area_decision_phase(
	delta: float,
	_simulation_tick: int
) -> bool:
	return _simulate_layered_area_decision_body(delta)


func _simulate_layered_area_decision_body(delta: float) -> bool:
	var physics_frame := Engine.get_physics_frames()
	var runs_full_decision := (
		layered_area_decision_urgent
		or is_layered_area_decision_due_for_physics_frame(physics_frame)
	)
	var family_consumed_decision := false
	if runs_full_decision:
		refresh_dynamic_combat_target_decision(physics_frame)
		family_consumed_decision = (
			_try_consume_layered_area_family_decision_phase(delta)
		)
	var can_move := (
		not family_consumed_decision
		and _can_run_layered_area_motion()
	)
	layered_area_motion_state_known = true
	layered_area_last_can_move = can_move
	if not can_move:
		layered_area_planned_move_direction = Vector2.ZERO
	else:
		layered_area_planned_move_direction = _get_navigation_move_direction(delta)
	# Facing can mirror collision-shape offsets, rotations and SegmentShape points.
	# Commit it before the coordinator captures planned contact geometry.
	_update_facing(layered_area_planned_move_direction)
	layered_area_motion_phase_due = (
		can_move and not layered_area_planned_move_direction.is_zero_approx()
	)
	layered_area_decision_urgent = false
	return true


## Decision hook: commit family attack/state transitions. Returning true consumes
## motion for this decision tick.
func _try_consume_layered_area_family_decision_phase(_delta: float) -> bool:
	return false


func simulate_layered_area_motion_phase(
	delta: float,
	simulation_tick: int,
	token: int
) -> bool:
	if not _accept_layered_area_followup_phase(token, simulation_tick):
		return false
	return _simulate_layered_area_motion_body(delta)


func simulate_trusted_layered_area_motion_phase(
	delta: float,
	_simulation_tick: int
) -> bool:
	return _simulate_layered_area_motion_body(delta)


func _simulate_layered_area_motion_body(delta: float) -> bool:
	if (
		not layered_area_motion_state_known
		or not layered_area_last_can_move
		or is_dead
		or not is_instance_valid(objective_target)
	):
		velocity = Vector2.ZERO
		return true

	var move_direction := layered_area_planned_move_direction
	var full_velocity := move_direction * _get_move_speed()
	var safe_motion_fraction := 1.0
	var enemy_target := objective_target as Enemy
	if enemy_target != null:
		safe_motion_fraction = get_layered_area_directed_safe_motion_fraction(
			enemy_target
		)
	velocity = full_velocity * safe_motion_fraction
	_move_after_confirmed_no_contact(delta)
	if safe_motion_fraction < 1.0:
		# The submitted displacement ends on the directed attack shell. Report a
		# stopped body immediately; the next current-contact snapshot will turn
		# this prediction into ordinary contact/attack state.
		velocity = Vector2.ZERO
	return true


func should_execute_layered_area_motion_phase() -> bool:
	return (
		layered_area_motion_phase_due
		and not is_dead
		and objective_target != null
		and is_instance_valid(objective_target)
		and not layered_area_planned_move_direction.is_zero_approx()
		and _get_move_speed() > 0.0
	)


## Motion hook: family state machines may add gates before delegating to super.
func _can_run_layered_area_motion() -> bool:
	return (
		not is_dead
		and is_instance_valid(objective_target)
		and not _has_player_contact()
	)


func _run_authoritative_physics_step(delta: float) -> void:
	if is_dead:
		velocity = Vector2.ZERO
		return

	_update_touch_damage(delta)

	if not is_instance_valid(objective_target):
		velocity = Vector2.ZERO
		_move_until_player_contact(delta)
		return
	if _has_player_contact():
		velocity = Vector2.ZERO
		return

	var move_direction := _get_navigation_move_direction(delta)
	_update_facing(move_direction)
	velocity = move_direction * _get_move_speed()
	_move_until_player_contact(delta)


## Motion hook: override only for a family-specific effective speed contract.
func _get_move_speed() -> float:
	return get_effective_move_speed()
