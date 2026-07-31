extends Player
class_name PlayerTango

enum CastingState {
	ORBIT,
	CHARGING,
	CONVERGING,
	FIRING,
}

const MIN_CHARGE_DURATION := 0.2
const MAX_CHARGE_DURATION := 2.5
const MIN_BEAM_LENGTH := 48.0
const MAX_BEAM_LENGTH := 96.0
const MIN_BEAM_DURATION := 0.1
const MAX_BEAM_DURATION := 1.0
const BEAM_DAMAGE_INTERVAL := 0.1
const CHARGE_THRESHOLD_EPSILON := 0.0001
const BEAM_WIDTH := 6.0
const BEAM_ORIGIN_DISTANCE := 18.0
const UNIT_ORBIT_RADIUS := Vector2(14.0, 8.0)
const UNIT_ORBIT_PERIOD := 6.0
const UNIT_CONVERGE_DURATION := 0.12
const UNIT_PHASE_STEP := TAU / 3.0
const BEAM_EPSILON := 0.0001

@onready var casting_units: Node2D = $CastingUnits
@onready var unit_a: AnimatedSprite2D = $CastingUnits/UnitA
@onready var unit_b: AnimatedSprite2D = $CastingUnits/UnitB
@onready var unit_c: AnimatedSprite2D = $CastingUnits/UnitC
@onready var beam_area: Area2D = $BeamArea
@onready var beam_collision: CollisionShape2D = $BeamArea/CollisionShape2D
@onready var beam_visual_root: Node2D = $BeamArea/VisualRoot
@onready var beam_glow: Line2D = $BeamArea/VisualRoot/Glow
@onready var beam_body: Line2D = $BeamArea/VisualRoot/Body
@onready var beam_core: Line2D = $BeamArea/VisualRoot/Core
@onready var primary_attack_audio: AudioStreamPlayer2D = get_node_or_null(
	"PrimaryAttackAudio"
) as AudioStreamPlayer2D

var _casting_state := CastingState.ORBIT
var _casting_unit_sprites: Array[AnimatedSprite2D] = []
var _unit_orbit_phase := 0.0
var _unit_converge_elapsed := 0.0
var _unit_converge_starts: Array[Vector2] = []
var _charge_elapsed := 0.0
var _charge_direction := Vector2.RIGHT
var _local_charge_input_active := false
var _beam_direction := Vector2.RIGHT
var _beam_charge_ratio := 0.0
var _beam_length := 0.0
var _beam_duration := 0.0
var _beam_elapsed := 0.0
var _beam_next_damage_time := BEAM_DAMAGE_INTERVAL
var _beam_damage_snapshot := 0
var _beam_is_authoritative := false
var _latest_remote_action_sequence := 0
var _latest_remote_action_phase := 0
var _casting_units_base_position := Vector2.ZERO
var _beam_visual_base_position := Vector2.ZERO


func _init() -> void:
	character_id = &"tango"
	skill1_unlocked = false


func is_tango() -> bool:
	return true


func uses_attack_interval_bar() -> bool:
	return true


func supports_projectile_attack_patterns() -> bool:
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
	return _beam_charge_ratio


func get_tango_beam_length() -> float:
	return _beam_length


func get_tango_beam_duration() -> float:
	return _beam_duration


func get_tango_casting_state() -> int:
	return _casting_state


func is_tango_charge_active() -> bool:
	return _casting_state == CastingState.CHARGING


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
		_charge_direction = safe_direction
		last_attack_direction = safe_direction
		if not _local_charge_input_active and _casting_state == CastingState.ORBIT:
			_begin_local_charge_request(safe_direction)
		return
	if _local_charge_input_active:
		_release_local_charge_request(_charge_direction)


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
			_start_beam_sequence(
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
	_start_beam_sequence(safe_direction, safe_ratio, true)
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


func play_remote_tango_laser_fired(
	direction: Vector2,
	charge_ratio: float,
	sequence: int
) -> void:
	if not _accept_remote_tango_charge_terminal(sequence):
		return
	if is_dead or are_combat_actions_locked() or not is_finite(charge_ratio):
		return
	_start_beam_sequence(
		_get_safe_tango_direction(direction),
		clampf(charge_ratio, 0.0, 1.0),
		false
	)


func reconcile_predicted_tango_laser_fired(
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
		_beam_direction = safe_direction
		_beam_charge_ratio = safe_ratio
		_beam_length = lerpf(MIN_BEAM_LENGTH, MAX_BEAM_LENGTH, safe_ratio)
		_beam_duration = lerpf(MIN_BEAM_DURATION, MAX_BEAM_DURATION, safe_ratio)
		last_attack_direction = safe_direction
		_configure_beam_geometry()
		if _casting_state == CastingState.FIRING:
			_set_units_to_fire_positions()
			if _beam_elapsed >= _beam_duration - BEAM_EPSILON:
				_finish_beam_sequence()
		return
	# A prediction that already completed keeps its resolved beam length. Do not
	# replay it when the reliable Host confirmation arrives late.
	if _casting_state == CastingState.ORBIT and _beam_length > 0.0:
		_beam_direction = safe_direction
		_beam_charge_ratio = safe_ratio
		_beam_length = lerpf(MIN_BEAM_LENGTH, MAX_BEAM_LENGTH, safe_ratio)
		_beam_duration = lerpf(MIN_BEAM_DURATION, MAX_BEAM_DURATION, safe_ratio)
		return
	_start_beam_sequence(safe_direction, safe_ratio, false)


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
	_stop_beam_visual()
	_casting_state_to(CastingState.CHARGING)
	_charge_elapsed = 0.0
	_charge_direction = direction
	last_attack_direction = direction
	_update_facing(Vector2.ZERO, direction)
	_set_casting_unit_animation(&"charge")


func _cancel_charge_visual() -> void:
	_stop_beam_visual()
	_charge_elapsed = 0.0
	_beam_charge_ratio = 0.0
	_beam_length = 0.0
	_beam_duration = 0.0
	_beam_elapsed = 0.0
	_beam_next_damage_time = BEAM_DAMAGE_INTERVAL
	_beam_damage_snapshot = 0
	_beam_is_authoritative = false
	_unit_converge_elapsed = 0.0
	_casting_state_to(CastingState.ORBIT)
	_set_casting_unit_animation(&"orbit")
	_update_orbit_visuals(0.0)


func _start_beam_sequence(
	direction: Vector2,
	charge_ratio: float,
	authoritative: bool
) -> void:
	var safe_ratio := clampf(charge_ratio, 0.0, 1.0)
	_beam_direction = _get_safe_tango_direction(direction)
	_beam_charge_ratio = safe_ratio
	_beam_length = lerpf(MIN_BEAM_LENGTH, MAX_BEAM_LENGTH, safe_ratio)
	_beam_duration = lerpf(MIN_BEAM_DURATION, MAX_BEAM_DURATION, safe_ratio)
	_beam_elapsed = 0.0
	_beam_next_damage_time = BEAM_DAMAGE_INTERVAL
	_beam_is_authoritative = authoritative
	_beam_damage_snapshot = (
		get_outgoing_damage(attack_damage, EnemyConfig.DamageType.PHYSICAL)
		if authoritative
		else 0
	)
	_charge_elapsed = 0.0
	_local_charge_input_active = false
	last_attack_direction = _beam_direction
	_update_facing(Vector2.ZERO, _beam_direction)
	_capture_unit_converge_starts()
	_unit_converge_elapsed = 0.0
	_casting_state_to(CastingState.CONVERGING)
	_set_casting_unit_animation(&"fire")
	_configure_beam_geometry()
	if authoritative:
		notify_primary_attack_performed()


func _update_character_combat_state(delta: float) -> void:
	super._update_character_combat_state(delta)
	if is_dead:
		return
	var safe_delta := maxf(delta, 0.0)
	_unit_orbit_phase = fposmod(
		_unit_orbit_phase + safe_delta * TAU / UNIT_ORBIT_PERIOD,
		TAU
	)
	match _casting_state:
		CastingState.ORBIT, CastingState.CHARGING:
			_update_orbit_visuals(safe_delta)
		CastingState.CONVERGING:
			_update_unit_convergence(safe_delta)
		CastingState.FIRING:
			_update_active_beam(safe_delta)


func _capture_unit_converge_starts() -> void:
	_unit_converge_starts.clear()
	for unit in _casting_unit_sprites:
		_unit_converge_starts.append(unit.position)


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
	var targets := _get_unit_fire_positions(_beam_direction)
	for index in _casting_unit_sprites.size():
		var start_position := _unit_converge_starts[index]
		_casting_unit_sprites[index].position = _round_vector(
			start_position.lerp(targets[index], eased_progress)
		)
		_casting_unit_sprites[index].z_index = 2
	if progress >= 1.0:
		_begin_beam_fire()


func _begin_beam_fire() -> void:
	_casting_state_to(CastingState.FIRING)
	_set_units_to_fire_positions()
	beam_area.set_deferred(&"monitoring", true)
	beam_collision.set_deferred(&"disabled", false)
	beam_visual_root.show()
	_play_primary_attack_audio()


func _update_active_beam(delta: float) -> void:
	_beam_elapsed = minf(_beam_elapsed + delta, _beam_duration)
	while (
		_beam_is_authoritative
		and _beam_next_damage_time <= _beam_elapsed + BEAM_EPSILON
		and _beam_next_damage_time <= _beam_duration + BEAM_EPSILON
	):
		_apply_beam_damage_tick()
		_beam_next_damage_time += BEAM_DAMAGE_INTERVAL
	if _beam_elapsed >= _beam_duration - BEAM_EPSILON:
		_finish_beam_sequence()


func _apply_beam_damage_tick() -> int:
	if not _beam_is_authoritative or _beam_damage_snapshot <= 0:
		return 0
	var damaged_ids: Dictionary = {}
	var hit_count := 0
	for body in beam_area.get_overlapping_bodies():
		var enemy := body as Enemy
		if enemy == null or not is_instance_valid(enemy) or enemy.is_dead:
			continue
		var enemy_id := enemy.get_instance_id()
		if damaged_ids.has(enemy_id):
			continue
		damaged_ids[enemy_id] = true
		var resolved_damage := resolve_attack_damage_against_enemy(
			_beam_damage_snapshot,
			enemy
		)
		if not _apply_authoritative_collectible_enemy_damage(
			enemy,
			resolved_damage,
			_beam_direction,
			EnemyConfig.DamageType.PHYSICAL,
			false
		):
			continue
		hit_count += 1
		apply_collectible_attack_hit_effects(enemy, resolved_damage)
	return hit_count


func _finish_beam_sequence() -> void:
	_stop_beam_visual()
	_beam_is_authoritative = false
	_beam_damage_snapshot = 0
	_beam_elapsed = 0.0
	_beam_next_damage_time = BEAM_DAMAGE_INTERVAL
	_casting_state_to(CastingState.ORBIT)
	_set_casting_unit_animation(&"orbit")
	_update_orbit_visuals(0.0)


func _configure_beam_geometry() -> void:
	beam_area.position = _round_vector(_beam_direction * BEAM_ORIGIN_DISTANCE)
	beam_area.rotation = _beam_direction.angle()
	var rectangle := beam_collision.shape as RectangleShape2D
	if rectangle != null:
		rectangle.size = Vector2(_beam_length, BEAM_WIDTH)
	beam_collision.position = Vector2(_beam_length * 0.5, 0.0)
	var beam_points := PackedVector2Array([Vector2.ZERO, Vector2(_beam_length, 0.0)])
	beam_glow.points = beam_points
	beam_body.points = beam_points
	beam_core.points = beam_points
	beam_visual_root.position = (
		_beam_visual_base_position
		+ multiplayer_visual_offset.rotated(-beam_area.rotation)
	)


func _stop_beam_visual() -> void:
	if beam_area == null:
		return
	beam_area.set_deferred(&"monitoring", false)
	beam_collision.set_deferred(&"disabled", true)
	beam_visual_root.hide()


func _update_orbit_visuals(_delta: float) -> void:
	if _casting_unit_sprites.is_empty():
		return
	for index in _casting_unit_sprites.size():
		var angle := _unit_orbit_phase + float(index) * UNIT_PHASE_STEP
		var orbit_position := Vector2(
			cos(angle) * UNIT_ORBIT_RADIUS.x,
			sin(angle) * UNIT_ORBIT_RADIUS.y
		)
		var unit := _casting_unit_sprites[index]
		unit.position = _round_vector(orbit_position)
		unit.z_index = 0 if unit.position.y < 0.0 else 2


func _get_unit_fire_positions(direction: Vector2) -> Array[Vector2]:
	var perpendicular := Vector2(-direction.y, direction.x)
	return [
		_round_vector(direction * BEAM_ORIGIN_DISTANCE),
		_round_vector(direction * 16.0 + perpendicular * 4.0),
		_round_vector(direction * 16.0 - perpendicular * 4.0),
	]


func _set_units_to_fire_positions() -> void:
	var targets := _get_unit_fire_positions(_beam_direction)
	for index in _casting_unit_sprites.size():
		_casting_unit_sprites[index].position = targets[index]
		_casting_unit_sprites[index].z_index = 2


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
	if beam_visual_root != null:
		_beam_visual_base_position = beam_visual_root.position


func _set_character_visual_offset(offset: Vector2) -> void:
	if casting_units != null:
		casting_units.position = _casting_units_base_position + offset
	if beam_visual_root != null:
		# BeamArea rotates with the attack direction, while the multiplayer
		# smoothing offset is expressed in player/world axes.
		beam_visual_root.position = (
			_beam_visual_base_position + offset.rotated(-beam_area.rotation)
		)


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
	_beam_charge_ratio = 0.0
	_beam_length = 0.0
	_beam_duration = 0.0
	_beam_elapsed = 0.0
	_beam_next_damage_time = BEAM_DAMAGE_INTERVAL
	_beam_damage_snapshot = 0
	_beam_is_authoritative = false
	_unit_converge_elapsed = 0.0
	_casting_state_to(CastingState.ORBIT)
	_stop_beam_visual()
	if not _casting_unit_sprites.is_empty():
		_set_casting_unit_animation(&"orbit")
	if casting_units != null:
		casting_units.visible = show_units


func _play_primary_attack_audio() -> void:
	if primary_attack_audio != null and primary_attack_audio.stream != null:
		primary_attack_audio.pitch_scale = randf_range(0.97, 1.03)
		primary_attack_audio.play()
