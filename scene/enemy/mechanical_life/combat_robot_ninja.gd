extends Enemy
class_name CombatRobotNinja

const NinjaConfig := preload(
	"res://resources/config/enemies/combat_robot_ninja_config.gd"
)
const ENEMY_ATTACK_AUDIO_LIMITER := preload(
	"res://scene/combat/audio/enemy_attack_audio_limiter.gd"
)
const ACTION_BOOST: StringName = &"combat_robot_ninja_boost"
const BOOST_VISUAL_STATUS_MASK := 1 << 5
const BASE_VISUAL_STATUS_MASK := 0x1f
const AFTERIMAGE_STRENGTH_PARAMETER := &"ninja_afterimage_strength"
const AFTERIMAGE_DIRECTION_PARAMETER := &"ninja_afterimage_direction"
const AFTERIMAGE_DIRECTION_EPSILON_SQUARED := 0.0001

@export var path_refresh_interval: float = 0.25
@export var waypoint_arrival_distance: float = 4.0

@onready var boost_timer: Timer = $BoostTimer
@onready var cooldown_timer: Timer = $CooldownTimer
@onready var slash_audio: AudioStreamPlayer2D = $SlashAudio
@onready var move_rear_blade_shape: CollisionShape2D = (
	$TouchDamageArea/MoveRearBladeCollisionShape2D
)
@onready var move_front_blade_shape: CollisionShape2D = (
	$TouchDamageArea/MoveFrontBladeCollisionShape2D
)
@onready var boost_upper_blade_shape: CollisionShape2D = (
	$TouchDamageArea/BoostUpperBladeCollisionShape2D
)
@onready var boost_lower_blade_shape: CollisionShape2D = (
	$TouchDamageArea/BoostLowerBladeCollisionShape2D
)

var ninja_config_cache: NinjaConfig = null
var boost_active := false
var boost_cooldown_active := false
var action_sequence := 0
var latest_proxy_action_id := 0
var proxy_boost_status_latched := false
var proxy_boost_started_from_action := false
var afterimage_world_direction := Vector2.RIGHT


func _ready() -> void:
	super._ready()
	_sync_blade_contact_shapes()
	_update_afterimage_direction(_get_facing_direction(), true)


func _physics_process(delta: float) -> void:
	if is_dead:
		velocity = Vector2.ZERO
		return

	_update_touch_damage(maxf(delta, 0.0))
	if not is_instance_valid(objective_target):
		velocity = Vector2.ZERO
		_move_until_player_contact()
		return
	if _has_player_contact():
		velocity = Vector2.ZERO
		return

	var move_direction := _get_safe_navigation_move_direction(
		objective_target,
		pathfinder,
		waypoint_arrival_distance
	)
	_update_facing(move_direction)
	velocity = move_direction * get_effective_move_speed()
	var position_before_move := global_position
	_move_until_player_contact()
	if boost_active:
		var actual_displacement := global_position - position_before_move
		if actual_displacement != Vector2.ZERO:
			_update_afterimage_direction(actual_displacement)


func _apply_config() -> void:
	boost_active = false
	boost_cooldown_active = false
	action_sequence = 0
	latest_proxy_action_id = 0
	proxy_boost_status_latched = false
	proxy_boost_started_from_action = false
	afterimage_world_direction = _get_facing_direction()
	_stop_boost_timers()
	super._apply_config()
	ninja_config_cache = config as NinjaConfig
	if slash_audio != null:
		slash_audio.stop()
		slash_audio.stream = (
			ninja_config_cache.boost_audio_stream
			if ninja_config_cache != null
			else null
		)
	_set_afterimage_strength(0.0)
	_sync_blade_contact_shapes()


func get_effective_move_speed() -> float:
	var effective_speed := super.get_effective_move_speed()
	if boost_active and ninja_config_cache != null:
		effective_speed *= maxf(ninja_config_cache.boost_speed_multiplier, 0.0)
	return effective_speed


func get_effective_move_speed_multiplier() -> float:
	var effective_multiplier := super.get_effective_move_speed_multiplier()
	if boost_active and ninja_config_cache != null:
		effective_multiplier *= maxf(
			ninja_config_cache.boost_speed_multiplier,
			0.0
		)
	return effective_multiplier


func is_damage_boost_active() -> bool:
	return boost_active


func is_damage_boost_on_cooldown() -> bool:
	return boost_cooldown_active


func _on_combat_damage_applied(result: DamageResult) -> void:
	super._on_combat_damage_applied(result)
	if (
		result == null
		or not result.accepted
		or result.applied_damage <= 0
		or result.lethal
		or is_dead
		or is_multiplayer_proxy
	):
		return
	_try_start_damage_boost()


func _try_start_damage_boost() -> bool:
	if (
		is_dead
		or is_multiplayer_proxy
		or boost_active
		or boost_cooldown_active
		or ninja_config_cache == null
	):
		return false

	var boost_duration := maxf(ninja_config_cache.boost_duration, 0.0)
	if boost_duration <= 0.0:
		return false
	boost_active = true
	boost_cooldown_active = true
	boost_timer.start(boost_duration)
	var cooldown_duration := maxf(ninja_config_cache.boost_cooldown, 0.0)
	if cooldown_duration > 0.0:
		cooldown_timer.start(cooldown_duration)
	else:
		boost_cooldown_active = false

	_switch_locomotion_animation_preserving_phase(
		ninja_config_cache.boost_animation_name,
		true
	)
	_sync_blade_contact_shapes()
	_clear_cached_navigation_move_direction()
	var boost_direction := (
		velocity.normalized()
		if velocity != Vector2.ZERO
		else _get_facing_direction()
	)
	_update_afterimage_direction(boost_direction, true)
	_set_afterimage_strength(1.0)
	_play_boost_audio()
	_broadcast_enemy_action(boost_direction)
	return true


func _on_boost_timer_timeout() -> void:
	if is_dead or not boost_active:
		return
	_finish_damage_boost(true)


func _on_cooldown_timer_timeout() -> void:
	if is_multiplayer_proxy:
		return
	boost_cooldown_active = false


func _finish_damage_boost(restore_move_animation: bool) -> void:
	if not boost_active:
		return
	boost_active = false
	proxy_boost_started_from_action = false
	boost_timer.stop()
	_set_afterimage_strength(0.0)
	if slash_audio != null:
		slash_audio.stop()
	_sync_blade_contact_shapes()
	_clear_cached_navigation_move_direction()
	if restore_move_animation and not is_dead and config != null:
		_switch_locomotion_animation_preserving_phase(
			config.move_animation_name
		)
	if is_multiplayer_proxy:
		proxy_action_animation_name_in_use = &""
		proxy_action_restore_token += 1


func _cancel_damage_boost(
	restore_move_animation: bool,
	disable_contacts: bool
) -> void:
	boost_active = false
	boost_cooldown_active = false
	proxy_boost_started_from_action = false
	_stop_boost_timers()
	_set_afterimage_strength(0.0)
	if slash_audio != null:
		slash_audio.stop()
	if disable_contacts:
		_set_all_blade_contact_shapes_disabled()
	else:
		_sync_blade_contact_shapes()
	if restore_move_animation and not is_dead and config != null:
		_switch_locomotion_animation_preserving_phase(
			config.move_animation_name
		)
	proxy_action_animation_name_in_use = &""
	proxy_action_restore_token += 1
	_clear_cached_navigation_move_direction()


func configure_multiplayer_proxy() -> void:
	_cancel_damage_boost(false, true)
	proxy_boost_status_latched = false
	proxy_boost_started_from_action = false
	super.configure_multiplayer_proxy()
	_set_all_blade_contact_shapes_disabled()


func _die() -> void:
	if is_dead:
		return
	latest_proxy_action_id += 1
	_cancel_damage_boost(false, true)
	super._die()


func play_multiplayer_death_sequence() -> void:
	if is_dead:
		return
	latest_proxy_action_id += 1
	_cancel_damage_boost(false, true)
	super.play_multiplayer_death_sequence()


func remove_for_home_escape() -> bool:
	if is_dead:
		return false
	latest_proxy_action_id += 1
	_cancel_damage_boost(false, true)
	return super.remove_for_home_escape()


func _exit_tree() -> void:
	_cancel_damage_boost(false, true)
	super._exit_tree()


func _has_variant_visual_shader_effect() -> bool:
	return (
		boost_active
		and (
			not is_multiplayer_proxy
			or multiplayer_proxy_visual_active
		)
	)


func get_collectible_visual_status_mask() -> int:
	return (
		super.get_collectible_visual_status_mask()
		| (BOOST_VISUAL_STATUS_MASK if boost_active else 0)
	)


func apply_multiplayer_visual_status_mask(status_mask: int) -> void:
	if not is_multiplayer_proxy or is_dead:
		return
	var remote_boost_active := (status_mask & BOOST_VISUAL_STATUS_MASK) != 0
	if remote_boost_active:
		if not proxy_boost_status_latched:
			proxy_boost_status_latched = true
			if not boost_active:
				var snapshot_direction := (
					velocity.normalized()
					if velocity != Vector2.ZERO
					else _get_facing_direction()
				)
				_begin_proxy_boost(
					snapshot_direction,
					_get_boost_duration(),
					0.0,
					false,
					false,
					false
				)
	else:
		# Enemy actions and snapshots use separate delivery paths. A clear snapshot
		# from just before a fresh action may arrive afterwards; the elapsed-corrected
		# action timer is authoritative for that presentation and must not be cut short.
		if not boost_active or not proxy_boost_started_from_action:
			proxy_boost_status_latched = false
			if boost_active:
				_finish_damage_boost(true)
	super.apply_multiplayer_visual_status_mask(
		status_mask & BASE_VISUAL_STATUS_MASK
	)


func set_multiplayer_proxy_visual_active(active: bool) -> void:
	super.set_multiplayer_proxy_visual_active(active)
	if not is_multiplayer_proxy:
		return
	_set_afterimage_strength(1.0 if boost_active and active else 0.0)


func apply_multiplayer_proxy_motion(
	proxy_position: Vector2,
	proxy_velocity: Vector2,
	proxy_locomotion_state: int
) -> void:
	super.apply_multiplayer_proxy_motion(
		proxy_position,
		proxy_velocity,
		proxy_locomotion_state
	)
	if not boost_active or proxy_velocity == Vector2.ZERO:
		return
	_update_facing(proxy_velocity)
	_update_afterimage_direction(proxy_velocity)


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
	if (
		not is_multiplayer_proxy
		or is_dead
		or action_name != ACTION_BOOST
		or action_id <= latest_proxy_action_id
	):
		return
	latest_proxy_action_id = action_id
	proxy_boost_status_latched = true
	var boost_duration := _get_boost_duration()
	var safe_elapsed := maxf(action_elapsed, 0.0)
	if boost_duration <= 0.0 or safe_elapsed >= boost_duration:
		_finish_damage_boost(true)
		return
	var safe_direction := (
		direction.normalized()
		if direction != Vector2.ZERO
		else _get_facing_direction()
	)
	_begin_proxy_boost(
		safe_direction,
		boost_duration - safe_elapsed,
		safe_elapsed,
		true,
		true,
		true
	)


func _begin_proxy_boost(
	direction: Vector2,
	remaining_duration: float,
	action_elapsed: float,
	seek_animation: bool,
	play_action_audio: bool,
	started_from_action: bool
) -> void:
	if not is_multiplayer_proxy or is_dead or ninja_config_cache == null:
		return
	boost_active = true
	boost_cooldown_active = false
	proxy_boost_started_from_action = started_from_action
	proxy_action_animation_name_in_use = ninja_config_cache.boost_animation_name
	proxy_action_restore_token += 1
	_update_facing(direction)
	_switch_locomotion_animation_preserving_phase(
		ninja_config_cache.boost_animation_name,
		true
	)
	if seek_animation:
		_seek_looping_animation(
			ninja_config_cache.boost_animation_name,
			action_elapsed
		)
	_update_afterimage_direction(direction, true)
	_set_afterimage_strength(
		1.0 if multiplayer_proxy_visual_active else 0.0
	)
	_set_all_blade_contact_shapes_disabled()
	boost_timer.start(maxf(remaining_duration, 0.001))
	if (
		play_action_audio
		and multiplayer_proxy_visual_active
		and action_elapsed < minf(0.3, _get_boost_duration())
	):
		_play_boost_audio(action_elapsed)


func _switch_locomotion_animation_preserving_phase(
	next_animation: StringName,
	force_play: bool = false
) -> void:
	if (
		animated_sprite == null
		or animated_sprite.sprite_frames == null
		or not animated_sprite.sprite_frames.has_animation(next_animation)
	):
		return
	if animated_sprite.animation == next_animation:
		if force_play and not animated_sprite.is_playing():
			animated_sprite.play(next_animation)
		return
	var previous_frame := animated_sprite.frame
	var previous_progress := animated_sprite.frame_progress
	var was_playing := animated_sprite.is_playing()
	animated_sprite.animation = next_animation
	var frame_count := animated_sprite.sprite_frames.get_frame_count(
		next_animation
	)
	if frame_count > 0:
		animated_sprite.set_frame_and_progress(
			clampi(previous_frame, 0, frame_count - 1),
			clampf(previous_progress, 0.0, 1.0)
		)
	if was_playing or force_play:
		animated_sprite.play(next_animation)
	else:
		animated_sprite.pause()


func _seek_looping_animation(
	animation_name: StringName,
	elapsed: float
) -> void:
	if (
		animated_sprite == null
		or animated_sprite.sprite_frames == null
		or not animated_sprite.sprite_frames.has_animation(animation_name)
	):
		return
	var frames := animated_sprite.sprite_frames
	var frame_count := frames.get_frame_count(animation_name)
	var animation_speed := frames.get_animation_speed(animation_name)
	if frame_count <= 0 or animation_speed <= 0.0:
		return
	var cycle_duration_units := 0.0
	for frame_index in range(frame_count):
		cycle_duration_units += maxf(
			frames.get_frame_duration(animation_name, frame_index),
			0.000001
		)
	var phase := fposmod(
		maxf(elapsed, 0.0) * animation_speed,
		cycle_duration_units
	)
	for frame_index in range(frame_count):
		var frame_duration := maxf(
			frames.get_frame_duration(animation_name, frame_index),
			0.000001
		)
		if phase < frame_duration:
			animated_sprite.set_frame_and_progress(
				frame_index,
				clampf(phase / frame_duration, 0.0, 1.0)
			)
			return
		phase -= frame_duration


func _sync_blade_contact_shapes() -> void:
	if is_multiplayer_proxy or is_dead:
		_set_all_blade_contact_shapes_disabled()
		return
	_set_collision_shape_disabled_deferred(
		move_rear_blade_shape,
		boost_active
	)
	_set_collision_shape_disabled_deferred(
		move_front_blade_shape,
		boost_active
	)
	_set_collision_shape_disabled_deferred(
		boost_upper_blade_shape,
		not boost_active
	)
	_set_collision_shape_disabled_deferred(
		boost_lower_blade_shape,
		not boost_active
	)


func _set_all_blade_contact_shapes_disabled() -> void:
	for shape_node in _get_blade_contact_shapes():
		_set_collision_shape_disabled_deferred(shape_node, true)


func _get_blade_contact_shapes() -> Array[CollisionShape2D]:
	return [
		move_rear_blade_shape,
		move_front_blade_shape,
		boost_upper_blade_shape,
		boost_lower_blade_shape,
	]


func _set_collision_shape_disabled_deferred(
	shape_node: CollisionShape2D,
	disabled: bool
) -> void:
	if shape_node == null or shape_node.disabled == disabled:
		return
	shape_node.set_deferred("disabled", disabled)


func _set_afterimage_strength(strength: float) -> void:
	_set_visual_shader_parameter(
		AFTERIMAGE_STRENGTH_PARAMETER,
		clampf(strength, 0.0, 1.0)
	)


func _update_afterimage_direction(
	world_direction: Vector2,
	force: bool = false
) -> void:
	if world_direction == Vector2.ZERO:
		return
	var normalized_direction := world_direction.normalized()
	if (
		not force
		and normalized_direction.distance_squared_to(
			afterimage_world_direction
		) <= AFTERIMAGE_DIRECTION_EPSILON_SQUARED
	):
		return
	afterimage_world_direction = normalized_direction
	var sprite_local_direction := normalized_direction
	if animated_sprite != null and animated_sprite.flip_h:
		sprite_local_direction.x *= -1.0
	_set_visual_shader_parameter(
		AFTERIMAGE_DIRECTION_PARAMETER,
		sprite_local_direction
	)


func _play_boost_audio(start_offset: float = 0.0) -> void:
	if slash_audio == null or slash_audio.stream == null:
		return
	slash_audio.pitch_scale = random_generator.randf_range(0.96, 1.04)
	if ENEMY_ATTACK_AUDIO_LIMITER.play_heavy_attack(slash_audio):
		slash_audio.seek(maxf(start_offset, 0.0))


func _stop_boost_timers() -> void:
	if boost_timer != null:
		boost_timer.stop()
	if cooldown_timer != null:
		cooldown_timer.stop()


func _get_boost_duration() -> float:
	return (
		maxf(ninja_config_cache.boost_duration, 0.0)
		if ninja_config_cache != null
		else 0.0
	)


func _update_facing(move_direction: Vector2) -> void:
	if is_zero_approx(move_direction.x):
		return
	_set_facing_from_direction(move_direction)


func _get_facing_direction() -> Vector2:
	return Vector2.LEFT if facing_left else Vector2.RIGHT


func _broadcast_enemy_action(direction: Vector2) -> void:
	action_sequence += 1
	if gameplay_gateway == null or not is_instance_valid(gameplay_gateway):
		return
	gameplay_gateway.broadcast_enemy_action(
		int(get_meta("net_id", 0)),
		ACTION_BOOST,
		direction,
		global_position,
		action_sequence
	)
