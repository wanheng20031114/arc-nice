extends Enemy
class_name YuanshiInsect

# 寻路路径刷新间隔。多只敌人共享 GridPathfinder，但各自按这个节奏更新目标路径。
@export var path_refresh_interval: float = 0.25

# 距离当前路点小于该值时，切换到下一个路点。
@export var waypoint_arrival_distance: float = 2.0

# 足够接近玩家时直接追踪玩家当前位置，避免围绕玩家所在格子中心反复寻路。
@export var direct_chase_extra_distance: float = 2.0

# LAYERED_AREA only throttles perception/navigation decisions. Touch timers,
# Area2D contact observation and CharacterBody2D movement remain at physics rate.
@export_range(1, 60, 1, "or_greater") var layered_area_decision_interval_frames := (
	EnemySimulationPolicy.DEFAULT_LAYERED_AREA_DECISION_INTERVAL_FRAMES
)

var layered_area_planned_move_direction := Vector2.ZERO
var layered_area_last_can_move := false
var layered_area_motion_state_known := false

func _physics_process(delta: float) -> void:
	if not _should_run_individual_authoritative_physics():
		return
	_run_authoritative_physics_step(delta)


func supports_centralized_authoritative_simulation() -> bool:
	return true


func supports_layered_area_authoritative_simulation() -> bool:
	return true


func supports_dynamic_enemy_targeting() -> bool:
	return supports_layered_area_authoritative_simulation()


func get_layered_area_decision_interval_frames() -> int:
	return maxi(layered_area_decision_interval_frames, 1)


func get_layered_area_planned_displacement(delta: float) -> Vector2:
	if not _can_run_layered_area_motion():
		return Vector2.ZERO
	return (
		layered_area_planned_move_direction
		* _get_move_speed()
		* maxf(delta, 0.0)
	)


func prepare_layered_area_authoritative_simulation() -> void:
	super.prepare_layered_area_authoritative_simulation()
	layered_area_planned_move_direction = Vector2.ZERO
	layered_area_last_can_move = false
	layered_area_motion_state_known = false


func simulate_authoritative_physics_step(
	delta: float,
	_simulation_tick: int,
	token: int
) -> void:
	if not _accept_scheduled_authoritative_step(token):
		return
	_run_authoritative_physics_step(delta)


func simulate_layered_area_event_phase(
	delta: float,
	simulation_tick: int,
	token: int
) -> bool:
	if not _accept_layered_area_event_phase(token, simulation_tick):
		return false
	if is_dead:
		velocity = Vector2.ZERO
		layered_area_planned_move_direction = Vector2.ZERO
		return true

	# Touch cooldowns and overlap-derived damage are event semantics and must stay
	# at 60 Hz even when direction decisions are less frequent.
	_update_touch_damage(delta)
	var can_move := _can_run_layered_area_motion()
	if not layered_area_motion_state_known or can_move != layered_area_last_can_move:
		request_layered_area_urgent_decision()
	layered_area_motion_state_known = true
	layered_area_last_can_move = can_move
	if not can_move:
		layered_area_planned_move_direction = Vector2.ZERO
		velocity = Vector2.ZERO
	return true


func simulate_layered_area_decision_phase(
	delta: float,
	simulation_tick: int,
	token: int
) -> bool:
	if not _accept_layered_area_followup_phase(token, simulation_tick):
		return false
	refresh_dynamic_combat_target_decision(Engine.get_physics_frames())
	if not _can_run_layered_area_motion():
		layered_area_planned_move_direction = Vector2.ZERO
	else:
		layered_area_planned_move_direction = _get_navigation_move_direction(delta)
	# Facing can mirror collision-shape offsets, rotations and SegmentShape points.
	# Commit it before the coordinator captures planned contact geometry.
	_update_facing(layered_area_planned_move_direction)
	layered_area_decision_urgent = false
	return true


func simulate_layered_area_motion_phase(
	delta: float,
	simulation_tick: int,
	token: int
) -> bool:
	if not _accept_layered_area_followup_phase(token, simulation_tick):
		return false
	if not _can_run_layered_area_motion():
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
	_move_until_player_contact(delta)
	if safe_motion_fraction < 1.0:
		# The submitted displacement ends on the directed attack shell. Report a
		# stopped body immediately; the next current-contact snapshot will turn
		# this prediction into ordinary contact/attack state.
		velocity = Vector2.ZERO
	return true


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


func _get_move_speed() -> float:
	return get_effective_move_speed()


func _get_navigation_move_direction(_delta: float) -> Vector2:
	return _get_safe_navigation_move_direction(
		objective_target,
		pathfinder,
		waypoint_arrival_distance
	)


# 根据水平移动方向更新贴图翻转，竖直移动时保留当前朝向。
func _update_facing(move_direction: Vector2) -> void:
	if is_zero_approx(move_direction.x):
		return
	_set_facing_from_direction(move_direction)


func _apply_multiplayer_player_damage(
	hit_player: Player,
	damage_amount: int,
	source_id: int,
	source_type: StringName
) -> void:
	if hit_player == null or damage_amount <= 0:
		return
	if _try_request_player_damage(
			source_id,
			hit_player.peer_id,
			damage_amount,
			source_type
		):
		return
	if _has_explicit_singleplayer_authority():
		hit_player.apply_damage(damage_amount)


func _get_multiplayer_damage_source_id(source_suffix: int) -> int:
	var net_id := int(get_meta("net_id", get_instance_id()))
	return maxi(net_id, 1) * 1000000 + maxi(source_suffix, 0)
