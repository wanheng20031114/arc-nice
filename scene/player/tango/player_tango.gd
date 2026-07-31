extends Player
class_name PlayerTango

enum CastingState {
	ORBIT,
	CHARGING,
	CONVERGING,
	FIRING,
	RETURNING,
}

const LASER_BULLET_SCENE := preload(
	"res://scene/player/tango/tango_laser_bullet.tscn"
)
const LASER_BULLET_TYPE: StringName = &"tango_laser_bullet"
const MIN_CHARGE_DURATION := 0.2
const MAX_CHARGE_DURATION := 2.4
const LOW_CHARGE_DAMAGE_THRESHOLD := 0.5
const LOW_CHARGE_DAMAGE_MULTIPLIER := 0.75
const NORMAL_CHARGE_DAMAGE_MULTIPLIER := 1.0
const FULL_CHARGE_DAMAGE_MULTIPLIER := 1.5
const MIN_BARRAGE_DURATION := 2.0
const MAX_BARRAGE_DURATION := 5.0
const CHARGE_THRESHOLD_EPSILON := 0.0001
const UNIT_ORBIT_RADIUS := Vector2(14.0, 8.0)
const UNIT_ORBIT_PERIOD := 6.0
const UNIT_CONVERGE_DURATION := 0.14
const UNIT_RETURN_DURATION := 0.18
const UNIT_PHASE_STEP := TAU / 3.0
const UNIT_FORWARD_ROTATION_OFFSET := PI / 2.0
const UNIT_FIRE_FORWARD_OFFSETS := [19.0, 17.0, 18.0]
const UNIT_FIRE_LATERAL_OFFSETS := [0.0, 5.0, -5.0]
const PROJECTILE_MUZZLE_DISTANCE := 6.0
const PROJECTILES_PER_VOLLEY := 3
const BARRAGE_EPSILON := 0.0001

@onready var casting_units: Node2D = $CastingUnits
@onready var unit_a: AnimatedSprite2D = $CastingUnits/UnitA
@onready var unit_b: AnimatedSprite2D = $CastingUnits/UnitB
@onready var unit_c: AnimatedSprite2D = $CastingUnits/UnitC
@onready var primary_attack_audio: AudioStreamPlayer2D = get_node_or_null(
	"PrimaryAttackAudio"
) as AudioStreamPlayer2D

var _casting_state := CastingState.ORBIT
var _casting_unit_sprites: Array[AnimatedSprite2D] = []
var _unit_orbit_phase := 0.0
var _unit_converge_elapsed := 0.0
var _unit_converge_starts: Array[Vector2] = []
var _unit_converge_start_rotations: Array[float] = []
var _unit_return_elapsed := 0.0
var _unit_return_starts: Array[Vector2] = []
var _unit_return_start_rotations: Array[float] = []
var _charge_elapsed := 0.0
var _charge_direction := Vector2.RIGHT
var _local_charge_input_active := false
var _barrage_direction := Vector2.RIGHT
var _barrage_charge_ratio := 0.0
var _barrage_charge_seconds := 0.0
var _barrage_damage_multiplier := NORMAL_CHARGE_DAMAGE_MULTIPLIER
var _barrage_duration := 0.0
var _barrage_elapsed := 0.0
var _barrage_next_volley_time := 0.0
var _barrage_damage_snapshot := 0
var _barrage_is_authoritative := false
var _barrage_volley_count := 0
var _attack_aim_uses_mouse := false
var _requires_neutral_before_charge := false
var _latest_remote_action_sequence := 0
var _latest_remote_action_phase := 0
var _casting_units_base_position := Vector2.ZERO


func _init() -> void:
	character_id = &"tango"
	skill1_unlocked = false


func is_tango() -> bool:
	return true


func uses_attack_interval_bar() -> bool:
	return true


func supports_projectile_attack_patterns() -> bool:
	# Tango's three-cannon volley has one atomic network contract. Projectile-only
	# piercing/homing collectibles stay disabled until those per-shot parameters
	# are represented by the batch RPC instead of diverging between peers.
	return false


func supports_research_technology() -> bool:
	return false


func get_tango_max_charge_duration() -> float:
	return MAX_CHARGE_DURATION


func get_tango_charge_ratio() -> float:
	if _casting_state != CastingState.CHARGING:
		return 0.0
	return clampf(_charge_elapsed / MAX_CHARGE_DURATION, 0.0, 1.0)


func get_tango_release_ratio() -> float:
	return _barrage_charge_ratio


func get_tango_release_charge_seconds() -> float:
	return _barrage_charge_seconds


func get_tango_barrage_duration() -> float:
	return _barrage_duration


func get_tango_barrage_damage() -> int:
	return _barrage_damage_snapshot


func get_tango_barrage_damage_multiplier() -> float:
	return _barrage_damage_multiplier


func get_tango_barrage_volley_count() -> int:
	return _barrage_volley_count


func get_tango_casting_state() -> int:
	return _casting_state


func is_tango_charge_active() -> bool:
	return _casting_state == CastingState.CHARGING


func is_tango_barrage_active() -> bool:
	return _casting_state in [CastingState.CONVERGING, CastingState.FIRING]


func uses_passive_tango_mouse_aim() -> bool:
	return is_tango_barrage_active() and _attack_aim_uses_mouse


func get_primary_attack_cooldown_ratio() -> float:
	return get_tango_charge_ratio()


func get_primary_cooldown_ratio() -> float:
	return get_primary_attack_cooldown_ratio()


func apply_multiplayer_tango_charge_snapshot(ratio: float, facing_id: int) -> void:
	var safe_ratio := clampf(ratio, 0.0, 1.0)
	if safe_ratio > 0.0 and _latest_remote_action_phase >= 2:
		# A realtime snapshot can cross the reliable terminal on another ENet
		# channel. Keep that stale ratio from flashing the bar after release/cancel.
		super.apply_multiplayer_primary_cooldown_ratio(0.0)
		return
	super.apply_multiplayer_primary_cooldown_ratio(safe_ratio)
	if safe_ratio <= 0.0:
		return
	# A joining client can receive the active charge bar before its reliable
	# `started` event. Reconstruct the visual from the snapshot's facing field;
	# a later reliable event still supplies the exact aim direction and sequence.
	if (
		_casting_state == CastingState.ORBIT
		and _latest_remote_action_phase < 2
	):
		_begin_charge_visual(_multiplayer_facing_id_to_direction(facing_id))
	if _casting_state == CastingState.CHARGING:
		_charge_elapsed = safe_ratio * MAX_CHARGE_DURATION


func _initialize_character_resources() -> void:
	super._initialize_character_resources()
	_casting_unit_sprites = [unit_a, unit_b, unit_c]
	_reset_tango_combat_state(true)
	casting_units.show()
	_update_orbit_visuals(0.0)


func _input(event: InputEvent) -> void:
	super._input(event)
	if not uses_local_input or not is_tango_barrage_active():
		return
	# The last active aiming device owns the barrage. A real mouse movement can
	# take control back after a right-stick adjustment without requiring another
	# click (the charge button has already been released by this point).
	if event is InputEventMouseMotion:
		_attack_aim_uses_mouse = true


func _get_current_shoot_input() -> Vector2:
	var shoot_input := super._get_current_shoot_input()
	if (
		uses_local_input
		and shoot_input.length_squared() <= 0.001
		and uses_passive_tango_mouse_aim()
	):
		return _get_mouse_shoot_direction()
	return shoot_input


func _update_character_resources(delta: float) -> void:
	super._update_character_resources(delta)
	if is_dead:
		return
	if are_combat_actions_locked():
		if _casting_state == CastingState.CHARGING:
			if uses_local_input:
				_request_local_charge_cancel()
			else:
				cancel_authoritative_tango_charge()
		return
	if _casting_state == CastingState.CHARGING:
		_charge_elapsed = minf(
			_charge_elapsed + maxf(delta, 0.0),
			MAX_CHARGE_DURATION
		)


func _handle_primary_attack_input(shoot_input: Vector2) -> void:
	if are_combat_actions_locked() or is_dead:
		return
	if shoot_input.length_squared() > 0.001:
		var safe_direction := _get_safe_tango_direction(shoot_input)
		if _casting_state in [CastingState.CONVERGING, CastingState.FIRING]:
			_set_barrage_direction(safe_direction)
		else:
			_charge_direction = safe_direction
			last_attack_direction = safe_direction
		if (
			uses_local_input
			and not _local_charge_input_active
			and not _requires_neutral_before_charge
			and _casting_state == CastingState.ORBIT
		):
			_begin_local_charge_request(safe_direction)
		return
	if uses_local_input and _local_charge_input_active:
		_release_local_charge_request(_charge_direction)
	elif _casting_state == CastingState.ORBIT:
		_requires_neutral_before_charge = false


func _begin_local_charge_request(direction: Vector2) -> void:
	var accepted := false
	var current_scene := get_tree().current_scene
	if current_scene != null and current_scene.has_method("request_tango_charge_started"):
		accepted = bool(current_scene.call("request_tango_charge_started", direction))
	else:
		accepted = try_authoritative_tango_charge_started(direction)
	if not accepted:
		_local_charge_input_active = false
		return
	_local_charge_input_active = true
	if _casting_state == CastingState.ORBIT:
		_begin_charge_visual(direction)


func _release_local_charge_request(direction: Vector2) -> void:
	_local_charge_input_active = false
	var local_charge_elapsed := _charge_elapsed
	var current_scene := get_tree().current_scene
	if current_scene != null and current_scene.has_method("request_tango_charge_released"):
		var accepted := bool(current_scene.call("request_tango_charge_released", direction))
		if not accepted:
			_cancel_charge_visual()
			return
		# Single-player and a local Host resolve the authoritative transition inside
		# the request bridge. Only a client prediction remains in CHARGING here.
		if _casting_state != CastingState.CHARGING:
			return
		if local_charge_elapsed + CHARGE_THRESHOLD_EPSILON < MIN_CHARGE_DURATION:
			_cancel_charge_visual()
		else:
			_start_barrage_sequence(
				direction,
				_charge_elapsed_to_release_ratio(local_charge_elapsed),
				false
			)
		return
	if local_charge_elapsed + CHARGE_THRESHOLD_EPSILON < MIN_CHARGE_DURATION:
		cancel_authoritative_tango_charge()
		return
	try_authoritative_tango_charge_released(
		direction,
		_charge_elapsed_to_release_ratio(local_charge_elapsed)
	)


func try_authoritative_tango_charge_started(direction: Vector2) -> bool:
	if (
		is_dead
		or are_combat_actions_locked()
		or _casting_state != CastingState.ORBIT
	):
		return false
	_begin_charge_visual(_get_safe_tango_direction(direction))
	return true


func try_authoritative_tango_charge_released(
	direction: Vector2,
	authoritative_charge_ratio: float
) -> Dictionary:
	if (
		is_dead
		or are_combat_actions_locked()
		or _casting_state != CastingState.CHARGING
		or not is_finite(authoritative_charge_ratio)
	):
		return {
			"accepted": false,
			"fired": false,
			"direction": Vector2.ZERO,
		}
	var safe_direction := _get_safe_tango_direction(direction)
	var safe_ratio := clampf(authoritative_charge_ratio, 0.0, 1.0)
	_start_barrage_sequence(safe_direction, safe_ratio, true)
	return {
		"accepted": true,
		"fired": true,
		"direction": safe_direction,
		"charge_ratio": safe_ratio,
	}


func cancel_authoritative_tango_charge() -> void:
	_local_charge_input_active = false
	if _casting_state == CastingState.CHARGING:
		_cancel_charge_visual()


func _request_local_charge_cancel() -> void:
	if _casting_state != CastingState.CHARGING:
		return
	_local_charge_input_active = false
	var current_scene := get_tree().current_scene
	if current_scene != null and current_scene.has_method("request_tango_charge_cancelled"):
		current_scene.call("request_tango_charge_cancelled")
	cancel_authoritative_tango_charge()


func play_remote_tango_charge_started(direction: Vector2, sequence: int) -> void:
	if not _accept_remote_tango_charge_started(sequence):
		return
	if is_dead or are_combat_actions_locked():
		return
	_begin_charge_visual(_get_safe_tango_direction(direction))


func play_remote_tango_barrage_started(
	direction: Vector2,
	charge_ratio: float,
	sequence: int
) -> void:
	if not _accept_remote_tango_charge_terminal(sequence):
		return
	if is_dead or are_combat_actions_locked() or not is_finite(charge_ratio):
		return
	_start_barrage_sequence(
		_get_safe_tango_direction(direction),
		clampf(charge_ratio, 0.0, 1.0),
		false
	)


func reconcile_predicted_tango_barrage_started(
	direction: Vector2,
	charge_ratio: float,
	sequence: int
) -> void:
	if not _accept_remote_tango_charge_terminal(sequence):
		return
	if is_dead or are_combat_actions_locked() or not is_finite(charge_ratio):
		_cancel_charge_visual()
		return
	var safe_direction := _get_safe_tango_direction(direction)
	var safe_ratio := clampf(charge_ratio, 0.0, 1.0)
	if _casting_state in [CastingState.CONVERGING, CastingState.FIRING]:
		_set_barrage_direction(safe_direction)
		_apply_barrage_release_profile(safe_ratio)
		if _casting_state == CastingState.FIRING:
			_set_units_to_fire_positions()
			if _barrage_elapsed >= _barrage_duration - BARRAGE_EPSILON:
				_begin_return_to_orbit()
		return
	# A prediction that already completed keeps its resolved profile. Do not
	# replay it when the reliable Host confirmation arrives late.
	if (
		_casting_state in [CastingState.ORBIT, CastingState.RETURNING]
		and _barrage_duration > 0.0
	):
		_set_barrage_direction(safe_direction)
		_apply_barrage_release_profile(safe_ratio)
		return
	_start_barrage_sequence(safe_direction, safe_ratio, false)


func play_remote_tango_charge_cancelled(sequence: int) -> void:
	if not _accept_remote_tango_charge_terminal(sequence):
		return
	_cancel_charge_visual()


func confirm_predicted_tango_charge_started(sequence: int) -> void:
	if sequence > _latest_remote_action_sequence:
		_latest_remote_action_sequence = sequence
		_latest_remote_action_phase = 1


func reject_predicted_tango_charge() -> void:
	_local_charge_input_active = false
	_cancel_charge_visual()


func _accept_remote_tango_charge_started(sequence: int) -> bool:
	if sequence <= _latest_remote_action_sequence:
		return false
	_latest_remote_action_sequence = sequence
	_latest_remote_action_phase = 1
	return true


func _accept_remote_tango_charge_terminal(sequence: int) -> bool:
	if (
		sequence < _latest_remote_action_sequence
		or (
			sequence == _latest_remote_action_sequence
			and _latest_remote_action_phase >= 2
		)
	):
		return false
	_latest_remote_action_sequence = sequence
	_latest_remote_action_phase = 2
	return true


func _begin_charge_visual(direction: Vector2) -> void:
	_casting_state_to(CastingState.CHARGING)
	_charge_elapsed = 0.0
	_charge_direction = direction
	_attack_aim_uses_mouse = uses_local_input and mouse_fire_held
	last_attack_direction = direction
	_update_facing(Vector2.ZERO, direction)
	_set_casting_unit_animation(&"charge")


func _cancel_charge_visual() -> void:
	_charge_elapsed = 0.0
	_barrage_charge_ratio = 0.0
	_barrage_charge_seconds = 0.0
	_barrage_damage_multiplier = NORMAL_CHARGE_DAMAGE_MULTIPLIER
	_barrage_duration = 0.0
	_barrage_elapsed = 0.0
	_barrage_next_volley_time = 0.0
	_barrage_damage_snapshot = 0
	_barrage_is_authoritative = false
	_barrage_volley_count = 0
	_unit_converge_elapsed = 0.0
	_unit_return_elapsed = 0.0
	_requires_neutral_before_charge = false
	_casting_state_to(CastingState.ORBIT)
	_set_casting_unit_animation(&"orbit")
	_update_orbit_visuals(0.0)


func _start_barrage_sequence(
	direction: Vector2,
	charge_ratio: float,
	authoritative: bool
) -> void:
	var safe_ratio := clampf(charge_ratio, 0.0, 1.0)
	_barrage_direction = _get_safe_tango_direction(direction)
	_apply_barrage_release_profile(safe_ratio)
	_barrage_elapsed = 0.0
	_barrage_next_volley_time = 0.0
	_barrage_is_authoritative = authoritative
	_barrage_volley_count = 0
	_charge_elapsed = 0.0
	_local_charge_input_active = false
	_requires_neutral_before_charge = true
	last_attack_direction = _barrage_direction
	_update_facing(Vector2.ZERO, _barrage_direction)
	_capture_unit_converge_starts()
	_unit_converge_elapsed = 0.0
	_casting_state_to(CastingState.CONVERGING)
	_set_casting_unit_animation(&"fire")


func _apply_barrage_release_profile(charge_ratio: float) -> void:
	_barrage_charge_ratio = clampf(charge_ratio, 0.0, 1.0)
	_barrage_charge_seconds = lerpf(
		MIN_CHARGE_DURATION,
		MAX_CHARGE_DURATION,
		_barrage_charge_ratio
	)
	var duration_progress := clampf(
		(_barrage_charge_seconds - LOW_CHARGE_DAMAGE_THRESHOLD)
		/ (MAX_CHARGE_DURATION - LOW_CHARGE_DAMAGE_THRESHOLD),
		0.0,
		1.0
	)
	_barrage_duration = lerpf(
		MIN_BARRAGE_DURATION,
		MAX_BARRAGE_DURATION,
		duration_progress
	)
	if _barrage_charge_ratio >= 1.0 - CHARGE_THRESHOLD_EPSILON:
		_barrage_damage_multiplier = FULL_CHARGE_DAMAGE_MULTIPLIER
	elif (
		_barrage_charge_seconds
		< LOW_CHARGE_DAMAGE_THRESHOLD - CHARGE_THRESHOLD_EPSILON
	):
		_barrage_damage_multiplier = LOW_CHARGE_DAMAGE_MULTIPLIER
	else:
		_barrage_damage_multiplier = NORMAL_CHARGE_DAMAGE_MULTIPLIER
	var physical_damage := get_outgoing_damage(
		attack_damage,
		EnemyConfig.DamageType.PHYSICAL
	)
	_barrage_damage_snapshot = maxi(
		roundi(float(physical_damage) * _barrage_damage_multiplier),
		1
	)


func _update_character_combat_state(delta: float) -> void:
	super._update_character_combat_state(delta)
	if is_dead:
		return
	var safe_delta := maxf(delta, 0.0)
	_unit_orbit_phase = fposmod(
		_unit_orbit_phase + safe_delta * TAU / UNIT_ORBIT_PERIOD,
		TAU
	)
	_update_local_barrage_aim()
	match _casting_state:
		CastingState.ORBIT, CastingState.CHARGING:
			_update_orbit_visuals(safe_delta)
		CastingState.CONVERGING:
			_update_unit_convergence(safe_delta)
		CastingState.FIRING:
			_update_active_barrage(safe_delta)
		CastingState.RETURNING:
			_update_unit_return(safe_delta)


func _update_local_barrage_aim() -> void:
	if not uses_local_input or not is_tango_barrage_active():
		return
	var stick_direction := Input.get_vector(
		"shoot_left",
		"shoot_right",
		"shoot_up",
		"shoot_down"
	)
	if stick_direction.length_squared() > 0.001:
		_attack_aim_uses_mouse = false
		_set_barrage_direction(stick_direction)
	elif _attack_aim_uses_mouse:
		_set_barrage_direction(_get_mouse_shoot_direction())


func _set_barrage_direction(direction: Vector2) -> void:
	_barrage_direction = _get_safe_tango_direction(direction)
	last_attack_direction = _barrage_direction
	_update_facing(Vector2.ZERO, _barrage_direction)
	if _casting_state == CastingState.FIRING:
		_set_units_to_fire_positions()


func apply_remote_tango_barrage_snapshot(
	direction: Vector2,
	charge_ratio: float,
	charge_sequence: int,
	barrage_remaining_seconds: float
) -> void:
	if (
		charge_sequence <= 0
		or charge_sequence < _latest_remote_action_sequence
		or not is_finite(charge_ratio)
		or not is_finite(barrage_remaining_seconds)
	):
		return
	var is_new_sequence := charge_sequence > _latest_remote_action_sequence
	_latest_remote_action_sequence = charge_sequence
	_latest_remote_action_phase = 2
	if is_dead or are_combat_actions_locked():
		return
	_set_barrage_direction(direction)
	_apply_barrage_release_profile(clampf(charge_ratio, 0.0, 1.0))
	var signed_remaining := clampf(
		barrage_remaining_seconds,
		-UNIT_RETURN_DURATION,
		_barrage_duration
	)
	# Remote replicas never emit gameplay bullets. The Host batch itself is the
	# cadence source, so skip their local predicted volley schedule after a sync.
	_barrage_next_volley_time = _barrage_duration
	_barrage_is_authoritative = false
	_charge_elapsed = 0.0
	_local_charge_input_active = false
	_requires_neutral_before_charge = true
	if is_new_sequence:
		_barrage_volley_count = 0
	if signed_remaining <= 0.0:
		if signed_remaining <= -UNIT_RETURN_DURATION + BARRAGE_EPSILON:
			_casting_state_to(CastingState.ORBIT)
			_set_casting_unit_animation(&"orbit")
			_update_orbit_visuals(0.0)
			return
		# A slightly late packet can reconstruct the quick return instead of
		# snapping a joining/reordered client straight from orbit to orbit.
		_casting_state_to(CastingState.FIRING)
		_set_units_to_fire_positions()
		_begin_return_to_orbit()
		_unit_return_elapsed = clampf(
			-signed_remaining,
			0.0,
			UNIT_RETURN_DURATION
		)
		_update_unit_return(0.0)
		return
	_barrage_elapsed = _barrage_duration - signed_remaining
	if _casting_state != CastingState.FIRING:
		_casting_state_to(CastingState.FIRING)
		_set_casting_unit_animation(&"fire")
	_set_units_to_fire_positions()


func _capture_unit_converge_starts() -> void:
	_unit_converge_starts.clear()
	_unit_converge_start_rotations.clear()
	for unit in _casting_unit_sprites:
		_unit_converge_starts.append(unit.position)
		_unit_converge_start_rotations.append(unit.rotation)


func _update_unit_convergence(delta: float) -> void:
	_unit_converge_elapsed = minf(
		_unit_converge_elapsed + delta,
		UNIT_CONVERGE_DURATION
	)
	var progress := clampf(
		_unit_converge_elapsed / UNIT_CONVERGE_DURATION,
		0.0,
		1.0
	)
	var eased_progress := progress * progress * (3.0 - 2.0 * progress)
	var targets := _get_unit_fire_positions(_barrage_direction)
	var target_rotation := _get_unit_fire_rotation(_barrage_direction)
	for index in _casting_unit_sprites.size():
		var start_position := _unit_converge_starts[index]
		var unit := _casting_unit_sprites[index]
		unit.position = _round_vector(
			start_position.lerp(targets[index], eased_progress)
		)
		unit.rotation = lerp_angle(
			_unit_converge_start_rotations[index],
			target_rotation,
			eased_progress
		)
		unit.z_index = 2
	if progress >= 1.0:
		_begin_barrage_fire()


func _begin_barrage_fire() -> void:
	_casting_state_to(CastingState.FIRING)
	_set_units_to_fire_positions()
	_barrage_elapsed = 0.0
	_barrage_next_volley_time = 0.0
	_update_active_barrage(0.0)


func _update_active_barrage(delta: float) -> void:
	var frame_end := minf(_barrage_elapsed + maxf(delta, 0.0), _barrage_duration)
	# Commit the Host sample time before emitting. Registration timestamps and
	# remaining-duration metadata must describe the same instant, including when
	# one long frame catches up multiple scheduled volleys.
	_barrage_elapsed = frame_end
	while (
		_barrage_next_volley_time < _barrage_duration - BARRAGE_EPSILON
		and _barrage_next_volley_time <= frame_end + BARRAGE_EPSILON
	):
		_emit_tango_volley()
		_barrage_next_volley_time += _get_effective_fire_interval()
	if _barrage_elapsed >= _barrage_duration - BARRAGE_EPSILON:
		_begin_return_to_orbit()


func _emit_tango_volley() -> void:
	_barrage_volley_count += 1
	if not _barrage_is_authoritative:
		return
	if not _spawn_authoritative_tango_volley():
		return
	notify_primary_attack_performed()
	_play_primary_attack_audio()


func _spawn_authoritative_tango_volley() -> bool:
	if _barrage_damage_snapshot <= 0 or _casting_unit_sprites.size() != PROJECTILES_PER_VOLLEY:
		return false
	var spawn_parent := get_tree().current_scene
	if spawn_parent == null:
		return false
	var projectiles: Array[Node] = []
	var spawn_positions := PackedVector2Array()
	var fire_positions := _get_unit_fire_positions(_barrage_direction)
	for unit_index in range(_casting_unit_sprites.size()):
		var bullet: TangoLaserBullet = null
		var uses_registered_pool := (
			spawn_parent.has_method("has_session_object_pool_scene")
			and bool(spawn_parent.call("has_session_object_pool_scene", LASER_BULLET_SCENE))
		)
		if uses_registered_pool:
			bullet = spawn_parent.call(
				"acquire_session_object",
				LASER_BULLET_SCENE,
				false
			) as TangoLaserBullet
		else:
			bullet = LASER_BULLET_SCENE.instantiate() as TangoLaserBullet
		if bullet == null:
			_retire_spawned_tango_projectiles(projectiles)
			return false
		bullet.top_level = true
		bullet.source_type = LASER_BULLET_TYPE
		bullet.setup(_barrage_direction, _barrage_damage_snapshot, false)
		bullet.setup_collectible_owner(self)
		if bullet.get_parent() == null:
			spawn_parent.add_child(bullet)
		# CastingUnits carries multiplayer_visual_offset for rendering only. Build
		# the authoritative muzzle from the Player transform so interpolation can
		# never shift hit detection or push a shot through nearby world geometry.
		var intended_spawn_position := to_global(
			_casting_units_base_position
			+ fire_positions[unit_index]
			+ _barrage_direction * PROJECTILE_MUZZLE_DISTANCE
		)
		var spawn_position := bullet.clamp_spawn_position_to_clear_path(
			to_global(_casting_units_base_position),
			intended_spawn_position,
			self
		)
		bullet.global_position = spawn_position
		bullet.reset_physics_interpolation()
		projectiles.append(bullet)
		spawn_positions.append(spawn_position)
	if spawn_parent.has_method("register_local_tango_laser_volley"):
		var registered := bool(spawn_parent.call(
			"register_local_tango_laser_volley",
			projectiles,
			spawn_positions,
			_barrage_direction,
			peer_id,
			_barrage_damage_snapshot,
			float(projectiles[0].get("speed")),
			float(projectiles[0].get("max_lifetime")),
			_barrage_charge_ratio,
			maxf(
				_barrage_duration - _barrage_elapsed,
				0.0
			)
		))
		if not registered:
			_retire_spawned_tango_projectiles(projectiles)
			return false
	return true


func _retire_spawned_tango_projectiles(projectiles: Array[Node]) -> void:
	for projectile in projectiles:
		if projectile != null and is_instance_valid(projectile):
			projectile.call("retire")


func _begin_return_to_orbit() -> void:
	if _casting_state == CastingState.RETURNING:
		return
	_barrage_is_authoritative = false
	_unit_return_elapsed = 0.0
	_unit_return_starts.clear()
	_unit_return_start_rotations.clear()
	for unit in _casting_unit_sprites:
		_unit_return_starts.append(unit.position)
		_unit_return_start_rotations.append(unit.rotation)
	_casting_state_to(CastingState.RETURNING)
	_set_casting_unit_animation(&"orbit")


func _update_unit_return(delta: float) -> void:
	_unit_return_elapsed = minf(
		_unit_return_elapsed + delta,
		UNIT_RETURN_DURATION
	)
	var progress := clampf(_unit_return_elapsed / UNIT_RETURN_DURATION, 0.0, 1.0)
	var eased_progress := progress * progress * (3.0 - 2.0 * progress)
	var orbit_targets := _get_unit_orbit_positions()
	for index in _casting_unit_sprites.size():
		var unit := _casting_unit_sprites[index]
		unit.position = _round_vector(
			_unit_return_starts[index].lerp(orbit_targets[index], eased_progress)
		)
		unit.rotation = lerp_angle(
			_unit_return_start_rotations[index],
			0.0,
			eased_progress
		)
		unit.z_index = 0 if unit.position.y < 0.0 else 2
	if progress >= 1.0:
		_casting_state_to(CastingState.ORBIT)
		_update_orbit_visuals(0.0)


func _update_orbit_visuals(_delta: float) -> void:
	if _casting_unit_sprites.is_empty():
		return
	var orbit_positions := _get_unit_orbit_positions()
	for index in _casting_unit_sprites.size():
		var unit := _casting_unit_sprites[index]
		unit.position = orbit_positions[index]
		unit.rotation = 0.0
		unit.z_index = 0 if unit.position.y < 0.0 else 2


func _get_unit_orbit_positions() -> Array[Vector2]:
	var positions: Array[Vector2] = []
	for index in PROJECTILES_PER_VOLLEY:
		var angle := _unit_orbit_phase + float(index) * UNIT_PHASE_STEP
		positions.append(_round_vector(Vector2(
			cos(angle) * UNIT_ORBIT_RADIUS.x,
			sin(angle) * UNIT_ORBIT_RADIUS.y
		)))
	return positions


func _get_unit_fire_positions(direction: Vector2) -> Array[Vector2]:
	var perpendicular := Vector2(-direction.y, direction.x)
	var positions: Array[Vector2] = []
	for index in PROJECTILES_PER_VOLLEY:
		positions.append(_round_vector(
			direction * float(UNIT_FIRE_FORWARD_OFFSETS[index])
			+ perpendicular * float(UNIT_FIRE_LATERAL_OFFSETS[index])
		))
	return positions


func _set_units_to_fire_positions() -> void:
	var targets := _get_unit_fire_positions(_barrage_direction)
	var target_rotation := _get_unit_fire_rotation(_barrage_direction)
	for index in _casting_unit_sprites.size():
		var unit := _casting_unit_sprites[index]
		unit.position = targets[index]
		unit.rotation = target_rotation
		unit.z_index = 2


func _get_unit_fire_rotation(direction: Vector2) -> float:
	return direction.angle() + UNIT_FORWARD_ROTATION_OFFSET


func _set_casting_unit_animation(animation_name: StringName) -> void:
	for unit in _casting_unit_sprites:
		if not unit.sprite_frames.has_animation(animation_name):
			continue
		if unit.animation != animation_name or not unit.is_playing():
			unit.play(animation_name)


func _charge_elapsed_to_release_ratio(elapsed: float) -> float:
	return clampf(
		(elapsed - MIN_CHARGE_DURATION)
		/ (MAX_CHARGE_DURATION - MIN_CHARGE_DURATION),
		0.0,
		1.0
	)


func _get_safe_tango_direction(direction: Vector2) -> Vector2:
	if (
		is_finite(direction.x)
		and is_finite(direction.y)
		and direction.length_squared() > 0.001
	):
		return direction.normalized()
	var fallback := _facing_suffix_to_vector(facing_suffix)
	return fallback if fallback != Vector2.ZERO else Vector2.RIGHT


func _round_vector(value: Vector2) -> Vector2:
	return Vector2(roundf(value.x), roundf(value.y))


func _multiplayer_facing_id_to_direction(facing_id: int) -> Vector2:
	match facing_id:
		1:
			return Vector2.LEFT
		2:
			return Vector2.UP
		3:
			return Vector2.DOWN
		_:
			return Vector2.RIGHT


func _casting_state_to(next_state: CastingState) -> void:
	_casting_state = next_state


func _cache_character_visual_base_positions() -> void:
	if casting_units != null:
		_casting_units_base_position = casting_units.position


func _set_character_visual_offset(offset: Vector2) -> void:
	if casting_units != null:
		casting_units.position = _casting_units_base_position + offset


func _update_animation() -> void:
	if velocity.length_squared() <= 0.01:
		var idle_animation := StringName("idle_%s" % facing_suffix)
		if body_sprite.sprite_frames.has_animation(idle_animation):
			if body_sprite.animation != idle_animation or not body_sprite.is_playing():
				body_sprite.play(idle_animation)
			return
	super._update_animation()


func _on_combat_actions_lock_changed(locked: bool) -> void:
	super._on_combat_actions_lock_changed(locked)
	if locked:
		if _casting_state == CastingState.CHARGING and uses_local_input:
			_request_local_charge_cancel()
		_reset_tango_combat_state(not is_dead)


func _cleanup_character_combat_on_death() -> void:
	super._cleanup_character_combat_on_death()
	_reset_tango_combat_state(false)
	if casting_units != null:
		casting_units.hide()


func _reset_character_resources_on_revive() -> void:
	super._reset_character_resources_on_revive()
	_reset_tango_combat_state(true)
	if casting_units != null:
		casting_units.show()
		_update_orbit_visuals(0.0)


func _reset_tango_combat_state(show_units: bool) -> void:
	_local_charge_input_active = false
	_charge_elapsed = 0.0
	_barrage_charge_ratio = 0.0
	_barrage_charge_seconds = 0.0
	_barrage_damage_multiplier = NORMAL_CHARGE_DAMAGE_MULTIPLIER
	_barrage_duration = 0.0
	_barrage_elapsed = 0.0
	_barrage_next_volley_time = 0.0
	_barrage_damage_snapshot = 0
	_barrage_is_authoritative = false
	_barrage_volley_count = 0
	_attack_aim_uses_mouse = false
	_requires_neutral_before_charge = false
	_unit_converge_elapsed = 0.0
	_unit_return_elapsed = 0.0
	_unit_converge_starts.clear()
	_unit_converge_start_rotations.clear()
	_unit_return_starts.clear()
	_unit_return_start_rotations.clear()
	_casting_state_to(CastingState.ORBIT)
	if not _casting_unit_sprites.is_empty():
		_set_casting_unit_animation(&"orbit")
		_update_orbit_visuals(0.0)
	if casting_units != null:
		casting_units.visible = show_units


func _play_primary_attack_audio() -> void:
	if primary_attack_audio != null and primary_attack_audio.stream != null:
		primary_attack_audio.pitch_scale = randf_range(0.97, 1.03)
		primary_attack_audio.play()
