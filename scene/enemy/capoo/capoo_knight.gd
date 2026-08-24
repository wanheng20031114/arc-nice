extends "res://scene/enemy/simple_chase_layered_enemy.gd"
class_name CapooKnight

const PLAYER_COLLISION_MASK := 2
const ENEMY_COLLISION_MASK := 4
const PLANT_COLLISION_MASK := 1 << 9
const SLASH_COLLISION_MASK := (
	PLAYER_COLLISION_MASK | ENEMY_COLLISION_MASK | PLANT_COLLISION_MASK
)


const WORLD_COLLISION_MASK := 1
const CapooKnightConfigScript := preload("res://resources/config/enemies/capoo_knight_config.gd")
const ENEMY_ATTACK_AUDIO_LIMITER := preload(
	"res://scene/combat/audio/enemy_attack_audio_limiter.gd"
)
const WINDUP_WARNING_SEGMENTS := 12
const SLASH_ANGLE_EPSILON_RADIANS := 0.000001

enum CombatState {
	CHASE,
	WINDUP,
	SLASH,
}

@export var path_refresh_interval: float = 0.25
@export var waypoint_arrival_distance: float = 6.0
@export var direct_chase_extra_distance: float = 2.0

@onready var windup_warning: Polygon2D = $WindupWarning
@onready var attack_audio: AudioStreamPlayer2D = $AttackAudio

var combat_state: CombatState = CombatState.CHASE
var attack_cooldown_left: float = 0.0
var windup_time_left: float = 0.0
var slash_time_left: float = 0.0
var slash_damage_time_left: float = 0.0
var slash_direction := Vector2.RIGHT
var slash_damage_done := false
var action_sequence: int = 0
var latest_proxy_action_id: int = 0
var slash_query_shape := CircleShape2D.new()
var slash_query := PhysicsShapeQueryParameters2D.new()
var slash_hit_target_ids: Dictionary[int, bool] = {}
var committed_attack_target: Node2D = null
var slash_damage_source_snapshot: DamageSourceSnapshot = null
var layered_knight_motion_blocked_physics_frame := -1


func supports_dynamic_enemy_targeting() -> bool:
	return true


func _ready() -> void:
	super._ready()
	slash_query.shape = slash_query_shape
	slash_query.collision_mask = SLASH_COLLISION_MASK
	slash_query.collide_with_bodies = true
	slash_query.collide_with_areas = false
	_set_windup_warning(0.0, Vector2.RIGHT)


func supports_centralized_authoritative_simulation() -> bool:
	return true


func supports_layered_area_authoritative_simulation() -> bool:
	return true


# Knight's authored body and touch shells are two-shape non-convex unions. The
# compound proxy preserves each rectangle independently; indexed Player/Plant
# authority remains fail-closed until multi-shape spatial queries are proven.
func supports_layered_contact_authoritative_simulation() -> bool:
	return true


func supports_indexed_touch_authority() -> bool:
	return false


func _advances_layered_area_touch_damage_event() -> bool:
	return false


func get_layered_area_decision_interval_frames() -> int:
	if not Enemy.combat_sense_throttling_enabled:
		return 1
	return mini(
		super.get_layered_area_decision_interval_frames(),
		maxi(combat_sense_update_interval_frames, 1)
	)


func prepare_layered_area_authoritative_simulation() -> void:
	super.prepare_layered_area_authoritative_simulation()
	# This is a layered-only same-tick motion fence. Authored CHASE/WINDUP/SLASH
	# state, timers, target, snapshot, RNG and action sequence must survive both
	# forward admission and rollback to LEGACY.
	layered_knight_motion_blocked_physics_frame = -1


func _advance_layered_area_family_event_phase(delta: float) -> void:
	super._advance_layered_area_family_event_phase(delta)
	_update_attack_cooldown(delta)
	if (
		combat_state != CombatState.CHASE
		and not (
			combat_state == CombatState.SLASH
			and slash_damage_done
		)
		and not _is_ranged_combat_target_valid(committed_attack_target)
	):
		# The authored runner performs this validation before its state match. A
		# cancellation here therefore returns to CHASE and may move in this tick.
		_cancel_attack()

	match combat_state:
		CombatState.WINDUP:
			_update_windup(delta)
			if combat_state == CombatState.CHASE:
				_block_layered_knight_motion_for_current_physics_frame()
		CombatState.SLASH:
			_update_slash(delta)
			if combat_state == CombatState.CHASE:
				_block_layered_knight_motion_for_current_physics_frame()
	_advance_capoo_knight_derived_event_phase(delta)


## Derived authored runners append their post-Knight event work here. StoneGolem
## uses it for the impact ring that historically advanced after super.
func _advance_capoo_knight_derived_event_phase(_delta: float) -> void:
	pass


func _can_sleep_layered_area_family_event_phase() -> bool:
	return (
		super._can_sleep_layered_area_family_event_phase()
		and combat_state == CombatState.CHASE
		and attack_cooldown_left <= 0.0
		and _can_sleep_capoo_knight_derived_event_phase()
	)


func _can_sleep_capoo_knight_derived_event_phase() -> bool:
	return true


func _try_consume_layered_area_family_decision_phase(delta: float) -> bool:
	if super._try_consume_layered_area_family_decision_phase(delta):
		return true
	if combat_state != CombatState.CHASE:
		return true
	if not _is_combat_sense_refresh_due():
		return false
	var combat_target := _get_preferred_ranged_combat_target()
	if combat_target == null or not _try_start_windup(combat_target):
		return false
	# The event phase may have published an indefinite CHASE sleep certificate
	# earlier in this tick. Revoke it at the attack commit; the coordinator
	# reconciles event readiness immediately after the decision phase.
	layered_area_event_phase_sleeping = false
	layered_area_event_sleep_until_physics_frame = -1
	return true


func _can_run_layered_area_motion() -> bool:
	return (
		combat_state == CombatState.CHASE
		and layered_knight_motion_blocked_physics_frame
			!= Engine.get_physics_frames()
		and super._can_run_layered_area_motion()
	)


func _block_layered_knight_motion_for_current_physics_frame() -> void:
	layered_knight_motion_blocked_physics_frame = Engine.get_physics_frames()


func _run_authoritative_physics_step(delta: float) -> void:
	if is_dead:
		velocity = Vector2.ZERO
		return

	_update_attack_cooldown(delta)
	if (
		combat_state != CombatState.CHASE
		and not (
			combat_state == CombatState.SLASH
			and slash_damage_done
		)
		and not _is_ranged_combat_target_valid(committed_attack_target)
	):
		_cancel_attack()

	match combat_state:
		CombatState.WINDUP:
			_update_windup(delta)
			return
		CombatState.SLASH:
			_update_slash(delta)
			return

	if _is_combat_sense_refresh_due():
		var combat_target := _get_preferred_ranged_combat_target()
		if combat_target != null and _try_start_windup(combat_target):
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
	attack_cooldown_left = 0.0
	windup_time_left = 0.0
	slash_time_left = 0.0
	slash_damage_time_left = 0.0
	slash_damage_done = false
	committed_attack_target = null
	slash_damage_source_snapshot = null

	var knight_config := config as CapooKnightConfigScript
	if knight_config != null:
		attack_audio.stream = knight_config.attack_audio_stream
		slash_query_shape.radius = knight_config.slash_outer_radius
		windup_warning.polygon = _build_slash_arc_polygon(
			knight_config.slash_inner_radius,
			knight_config.slash_outer_radius,
			deg_to_rad(knight_config.slash_angle_degrees),
			WINDUP_WARNING_SEGMENTS
		)
		_set_windup_warning(0.0, Vector2.RIGHT)


func _die() -> void:
	_cancel_attack()
	super._die()


func play_multiplayer_death_sequence() -> void:
	latest_proxy_action_id += 1
	_set_windup_warning(0.0, slash_direction)
	super.play_multiplayer_death_sequence()


func _update_attack_cooldown(delta: float) -> void:
	if attack_cooldown_left <= 0.0:
		return
	attack_cooldown_left = maxf(attack_cooldown_left - delta, 0.0)


func _try_start_windup(candidate_target: Node2D = null) -> bool:
	var knight_config := config as CapooKnightConfigScript
	if knight_config == null:
		return false
	if attack_cooldown_left > 0.0:
		return false
	if candidate_target == null:
		candidate_target = _get_preferred_ranged_combat_target()
	if not _is_ranged_combat_target_valid(candidate_target):
		return false
	if not _is_slash_target_in_start_range(
		candidate_target,
		knight_config.attack_range
	):
		return false
	if not _has_clear_world_line_to_target(candidate_target):
		return false

	committed_attack_target = candidate_target
	combat_state = CombatState.WINDUP
	windup_time_left = maxf(knight_config.attack_windup, 0.0)
	slash_direction = global_position.direction_to(
		committed_attack_target.global_position
	)
	if slash_direction == Vector2.ZERO:
		slash_direction = Vector2.RIGHT
	velocity = Vector2.ZERO
	_clear_navigation_path()
	_update_facing(slash_direction)
	_play_config_animation(knight_config.windup_animation_name)
	_set_windup_warning(0.25, slash_direction)
	slash_damage_source_snapshot = create_damage_source_snapshot(
		_get_multiplayer_damage_source_id(action_sequence + 1),
		_get_slash_damage_source_type()
	)
	_broadcast_enemy_action(&"windup", slash_direction)
	return true


func _update_windup(delta: float) -> void:
	var knight_config := config as CapooKnightConfigScript
	if (
		knight_config == null
		or not _is_ranged_combat_target_valid(committed_attack_target)
	):
		_cancel_attack()
		return

	velocity = Vector2.ZERO
	slash_direction = global_position.direction_to(
		committed_attack_target.global_position
	)
	if slash_direction == Vector2.ZERO:
		slash_direction = Vector2.RIGHT
	_update_facing(slash_direction)
	windup_time_left = maxf(windup_time_left - delta, 0.0)
	var progress := 1.0 - (windup_time_left / maxf(knight_config.attack_windup, 0.001))
	_set_windup_warning(progress, slash_direction)

	if windup_time_left > 0.0:
		return

	_start_slash(slash_direction)


func _start_slash(direction: Vector2) -> void:
	var knight_config := config as CapooKnightConfigScript
	if knight_config == null:
		_cancel_attack()
		return

	combat_state = CombatState.SLASH
	slash_direction = direction.normalized() if direction != Vector2.ZERO else Vector2.RIGHT
	slash_time_left = maxf(knight_config.slash_duration, 0.01)
	slash_damage_time_left = maxf(knight_config.slash_damage_delay, 0.0)
	slash_damage_done = false
	velocity = Vector2.ZERO
	_update_facing(slash_direction)
	_play_config_animation(knight_config.attack_animation_name)
	_set_windup_warning(0.0, slash_direction)
	_play_slash_effect(slash_direction)
	_broadcast_enemy_action(&"slash", slash_direction)
	if knight_config.attack_audio_stream != null:
		attack_audio.pitch_scale = random_generator.randf_range(0.96, 1.04)
		ENEMY_ATTACK_AUDIO_LIMITER.play_heavy_attack(attack_audio)


func _update_slash(delta: float) -> void:
	if is_dead:
		_cancel_attack()
		return
	# Once the authored damage frame has executed, the remainder of the slash no
	# longer reads its target.  Let the committed animation/cooldown finish even
	# when that hit removed the target; validating a freed target here would both
	# abort the action and, for long slam animations, strand derived families in
	# SLASH forever.
	if (
		not slash_damage_done
		and not _is_ranged_combat_target_valid(committed_attack_target)
	):
		_cancel_attack()
		return

	var knight_config := config as CapooKnightConfigScript
	if knight_config == null:
		_cancel_attack()
		return

	velocity = Vector2.ZERO
	_update_facing(slash_direction)
	slash_time_left = maxf(slash_time_left - delta, 0.0)
	if not slash_damage_done:
		slash_damage_time_left = maxf(slash_damage_time_left - delta, 0.0)
		if slash_damage_time_left <= 0.0:
			_apply_slash_damage()
			slash_damage_done = true
	if slash_time_left <= 0.0:
		_finish_slash()


func _apply_slash_damage() -> void:
	if is_dead:
		return

	var knight_config := config as CapooKnightConfigScript
	if knight_config == null:
		return
	if slash_damage_source_snapshot == null:
		slash_damage_source_snapshot = create_damage_source_snapshot(
			_get_multiplayer_damage_source_id(action_sequence),
			_get_slash_damage_source_type()
		)

	slash_query.transform = Transform2D(0.0, global_position)
	var results := get_world_2d().direct_space_state.intersect_shape(slash_query, 16)
	var half_angle := deg_to_rad(knight_config.slash_angle_degrees * 0.5)
	var outgoing_damage := get_effective_attack_damage(knight_config.attack_damage)
	slash_hit_target_ids.clear()
	for result in results:
		var hit_target := result.get("collider") as Node2D
		if not _is_ranged_combat_target_valid(hit_target):
			continue
		if (
			not (hit_target is Player)
			and not (hit_target is PlantDefense)
			and not (hit_target is Enemy)
		):
			continue
		var target_id := hit_target.get_instance_id()
		if slash_hit_target_ids.has(target_id):
			continue
		var offset := hit_target.global_position - global_position
		var distance := offset.length()
		if not _is_slash_target_in_radial_range(
			hit_target,
			distance,
			knight_config.slash_inner_radius,
			knight_config.slash_outer_radius
		):
			continue
		if (
			offset == Vector2.ZERO
			or abs(slash_direction.angle_to(offset.normalized()))
				> half_angle + SLASH_ANGLE_EPSILON_RADIANS
		):
			continue
		if not _dispatch_slash_damage(
			hit_target,
			outgoing_damage,
			offset.normalized()
		):
			continue
		slash_hit_target_ids[target_id] = true


func _finish_slash() -> void:
	combat_state = CombatState.CHASE
	committed_attack_target = null
	slash_damage_source_snapshot = null
	slash_time_left = 0.0
	slash_damage_time_left = 0.0
	slash_damage_done = false
	attack_cooldown_left = _get_attack_interval()
	var knight_config := config as CapooKnightConfigScript
	if knight_config != null:
		_play_config_animation(knight_config.move_animation_name)


func _cancel_attack() -> void:
	combat_state = CombatState.CHASE
	committed_attack_target = null
	slash_damage_source_snapshot = null
	slash_time_left = 0.0
	slash_damage_time_left = 0.0
	slash_damage_done = false
	_set_windup_warning(0.0, slash_direction)
	var knight_config := config as CapooKnightConfigScript
	if knight_config != null and not is_dead:
		_play_config_animation(knight_config.move_animation_name)


func play_multiplayer_enemy_action(action_name: StringName, direction: Vector2, action_id: int) -> void:
	if action_id <= latest_proxy_action_id:
		return
	latest_proxy_action_id = action_id
	var safe_direction := direction.normalized() if direction != Vector2.ZERO else Vector2.RIGHT
	var knight_config := config as CapooKnightConfigScript
	if action_name == &"windup":
		if knight_config != null:
			_play_multiplayer_proxy_action_animation(
				knight_config.windup_animation_name,
				knight_config.attack_windup + 0.15
			)
			_play_proxy_windup_warning(safe_direction, knight_config.attack_windup, action_id)
		_update_facing(safe_direction)
	elif action_name == &"slash":
		if knight_config != null:
			_play_multiplayer_proxy_action_animation(
				knight_config.attack_animation_name,
				knight_config.slash_duration + 0.05
			)
		_update_facing(safe_direction)
		_set_windup_warning(0.0, safe_direction)
		_play_slash_effect(safe_direction)


func _play_proxy_windup_warning(direction: Vector2, duration: float, action_id: int) -> void:
	_set_windup_warning(0.2, direction)
	var tween := create_tween()
	tween.tween_method(
		func(progress: float) -> void:
			if action_id != latest_proxy_action_id:
				return
			_set_windup_warning(progress, direction),
		0.2,
		1.0,
		maxf(duration, 0.01)
	)
	tween.tween_callback(
		func() -> void:
			if action_id == latest_proxy_action_id:
				_set_windup_warning(0.0, direction)
	)


func _play_slash_effect(direction: Vector2) -> void:
	var knight_config := config as CapooKnightConfigScript
	if knight_config == null or knight_config.slash_effect_scene == null:
		return
	var effect := knight_config.slash_effect_scene.instantiate() as Node2D
	if effect == null:
		return
	if combat_runtime == null or not is_instance_valid(combat_runtime):
		effect.queue_free()
		return
	combat_runtime.add_child(effect)
	var safe_direction := direction.normalized() if direction != Vector2.ZERO else Vector2.RIGHT
	var effect_distance := (knight_config.slash_inner_radius + knight_config.slash_outer_radius) * 0.5
	effect.global_position = global_position + safe_direction * effect_distance
	effect.rotation = safe_direction.angle()
	effect.z_index = 6


func _set_windup_warning(progress: float, direction: Vector2) -> void:
	var knight_config := config as CapooKnightConfigScript
	if knight_config == null or windup_warning == null:
		return
	var clamped_progress := clampf(progress, 0.0, 1.0)
	if clamped_progress <= 0.0:
		if windup_warning.visible:
			windup_warning.visible = false
		return
	if not windup_warning.visible:
		windup_warning.visible = true
	windup_warning.rotation = direction.angle()
	windup_warning.color = Color(1.0, 0.38, 0.32, lerpf(0.08, 0.34, clamped_progress))
	windup_warning.scale = Vector2.ONE * lerpf(0.88, 1.0, clamped_progress)


func _build_slash_arc_polygon(inner_radius: float, outer_radius: float, angle: float, segments: int) -> PackedVector2Array:
	var points := PackedVector2Array()
	var half_angle := angle * 0.5
	for index in range(segments + 1):
		var t := float(index) / float(segments)
		var a := lerpf(-half_angle, half_angle, t)
		points.append(Vector2.RIGHT.rotated(a) * outer_radius)
	for index in range(segments, -1, -1):
		var t := float(index) / float(segments)
		var a := lerpf(-half_angle, half_angle, t)
		points.append(Vector2.RIGHT.rotated(a) * inner_radius)
	return points


func _apply_multiplayer_player_damage(
	hit_player: Player,
	damage_amount: int,
	source_id: int,
	source_type: StringName,
	damage_type: int = EnemyConfig.DamageType.PHYSICAL,
	impact_direction: Vector2 = Vector2.ZERO
) -> bool:
	if hit_player == null or damage_amount <= 0:
		return false
	var resolved_impact_direction := (
		impact_direction.normalized()
		if impact_direction != Vector2.ZERO
		else slash_direction
	)
	var request := _make_slash_damage_request(
		damage_amount,
		resolved_impact_direction,
		damage_type
	)
	if not CombatDamageAdmission.is_admitted(
		request,
		hit_player.get_combat_faction_id(),
		combat_relation_service
	):
		return false
	if (
		gameplay_gateway != null
		and is_instance_valid(gameplay_gateway)
	):
		var previous_result := hit_player.last_damage_result
		var routed := gameplay_gateway.request_player_damage(
			source_id,
			hit_player.peer_id,
			damage_amount,
			source_type,
			damage_type as EnemyConfig.DamageType,
			-resolved_impact_direction,
			false,
			false,
			slash_damage_source_snapshot
		)
		if routed:
			var routed_result := hit_player.last_damage_result
			return (
				routed_result != null
				and routed_result != previous_result
				and routed_result.accepted
			)
	if _has_explicit_singleplayer_authority():
		var result := hit_player.apply_combat_damage(request)
		return result != null and result.accepted
	return false


func _dispatch_slash_damage(
	hit_target: Node2D,
	damage_amount: int,
	impact_direction: Vector2,
	damage_type: int = EnemyConfig.DamageType.PHYSICAL
) -> bool:
	var player := hit_target as Player
	if player != null:
		return _apply_multiplayer_player_damage(
			player,
			damage_amount,
			slash_damage_source_snapshot.event_source_id,
			_get_slash_damage_source_type(),
			damage_type,
			impact_direction
		)
	var request := _make_slash_damage_request(
		damage_amount,
		impact_direction,
		damage_type
	)
	var result: DamageResult = null
	var plant := hit_target as PlantDefense
	if plant != null:
		result = plant.apply_combat_damage(request)
	else:
		var enemy := hit_target as Enemy
		if enemy == null:
			return false
		result = enemy.apply_combat_damage(request)
	return result != null and result.accepted


func _make_slash_damage_request(
	damage_amount: int,
	impact_direction: Vector2,
	damage_type: int = EnemyConfig.DamageType.PHYSICAL
) -> DamageRequest:
	var request := DamageRequest.new(
		damage_amount,
		damage_type
	)
	request.with_source_snapshot(slash_damage_source_snapshot)
	request.with_directions(impact_direction, -impact_direction)
	return request


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


func _get_multiplayer_damage_source_id(source_suffix: int) -> int:
	var net_id := int(get_meta("net_id", get_instance_id()))
	return maxi(net_id, 1) * 1000000 + maxi(source_suffix, 0)


func _has_clear_world_line_to_target(attack_target: Node2D) -> bool:
	if not _is_ranged_combat_target_valid(attack_target):
		return false
	return _has_throttled_world_line_of_sight(attack_target, WORLD_COLLISION_MASK)


# Knight-family enemies commit damage through the authored windup/slash action.
# The inherited contact callback still tracks overlaps for movement stopping,
# but must never deal a second invisible touch hit unless a concrete enemy
# explicitly authors a damaging core.
func _try_deal_touch_damage() -> void:
	if not _uses_inherited_touch_damage():
		return
	super._try_deal_touch_damage()


func _uses_inherited_touch_damage() -> bool:
	return false


func _uses_contact_shape_slash_reach() -> bool:
	return false


func _is_slash_target_in_start_range(
	target: Node2D,
	attack_range: float
) -> bool:
	return (
		_is_ranged_combat_target_in_range(target, attack_range)
		or _is_contact_shape_slash_target(target)
	)


func _is_slash_target_in_radial_range(
	target: Node2D,
	distance: float,
	inner_radius: float,
	outer_radius: float
) -> bool:
	if distance < inner_radius:
		return false
	return distance <= outer_radius or _is_contact_shape_slash_target(target)


func _is_contact_shape_slash_target(target: Node2D) -> bool:
	# The authored radius still limits the physics query itself. This opt-in only
	# prevents a large or diagonal collider from being rejected a second time by
	# its node-center distance after its surface is already within reach.
	if (
		not _uses_contact_shape_slash_reach()
		or target == null
		or not is_instance_valid(target)
	):
		return false
	var target_id := target.get_instance_id()
	return touching_players.has(target_id) or touching_plants.has(target_id)


func _get_attack_interval() -> float:
	var knight_config := config as CapooKnightConfigScript
	return maxf(knight_config.attack_interval, 0.01) if knight_config != null else 4.0


func _get_slash_damage_source_type() -> StringName:
	return &"capoo_knight_slash"


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


func _play_config_animation(animation_name: StringName) -> void:
	_play_scene_animation(animation_name)
