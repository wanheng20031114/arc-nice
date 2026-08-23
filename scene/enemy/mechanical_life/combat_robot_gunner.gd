extends Enemy
class_name CombatRobotGunner

const GunnerConfig := preload(
	"res://resources/config/enemies/combat_robot_gunner_config.gd"
)
const ENEMY_ATTACK_AUDIO_LIMITER := preload(
	"res://scene/combat/audio/enemy_attack_audio_limiter.gd"
)


const ACTION_FIRE: StringName = &"combat_robot_gunner_fire"
const WORLD_COLLISION_MASK := 1
const MUZZLE_RIGHT_POSITION := Vector2(14.0, 1.0)
const MUZZLE_WORLD_CLEARANCE := 5.0
const FIRE_UPPER_PHASE_COUNT := 4
const FIRE_LEG_PHASE_COUNT := 8
const FIRE_UPPER_FPS := 25.0
const FIRE_LEG_FPS := 7.0
const FIRE_VISUAL_DURATION := 0.08
const FIRE_VISUAL_TIME_EPSILON := 0.000001

enum CombatState {
	TRACKING_READY,
	BURST,
	TRACKING_COOLDOWN,
}

@export var path_refresh_interval: float = 0.25
@export var waypoint_arrival_distance: float = 4.0

@onready var muzzle: Marker2D = $Muzzle
@onready var attack_audio: AudioStreamPlayer2D = $AttackAudio

var combat_state: CombatState = CombatState.TRACKING_READY
var attack_cooldown_left: float = 0.0
var burst_target: Node2D = null
var burst_shots_fired: int = 0
var burst_fire_time_left: float = 0.0
var locked_fire_direction := Vector2.RIGHT
var fire_upper_phase: float = 0.0
var fire_leg_phase: float = 0.0
var fire_visual_time_left: float = 0.0
var action_sequence: int = 0
var latest_proxy_action_id: int = 0


func supports_dynamic_enemy_targeting() -> bool:
	return true
var gunner_config_cache: GunnerConfig = null

var proxy_fire_visual_time_left: float = 0.0
var proxy_fire_upper_phase: float = 0.0
var proxy_fire_leg_phase: float = 0.0
var proxy_fire_visual_active: bool = false
var proxy_action_restore_animation_name: StringName = &""
var proxy_action_restore_token_snapshot: int = 0

var muzzle_world_query := PhysicsRayQueryParameters2D.create(
	Vector2.ZERO,
	Vector2.ZERO,
	WORLD_COLLISION_MASK
)


func _ready() -> void:
	super._ready()
	muzzle_world_query.collide_with_bodies = true
	muzzle_world_query.collide_with_areas = false
	muzzle_world_query.exclude = [get_rid()]
	_sync_muzzle_facing()


func can_target_water_plant_objectives() -> bool:
	return true


func _physics_process(delta: float) -> void:
	if is_dead:
		velocity = Vector2.ZERO
		return

	var safe_delta := maxf(delta, 0.0)
	_update_touch_damage(safe_delta)

	if combat_state == CombatState.BURST:
		_update_burst(safe_delta)
		return

	if combat_state == CombatState.TRACKING_COOLDOWN:
		attack_cooldown_left = maxf(
			attack_cooldown_left - safe_delta,
			0.0
		)
		if attack_cooldown_left <= 0.0:
			combat_state = CombatState.TRACKING_READY

	if combat_state == CombatState.TRACKING_READY and _is_combat_sense_refresh_due():
		var candidate_target := _get_preferred_ranged_combat_target()
		if _try_start_burst(candidate_target):
			# Zero elapsed time emits the immediate first shot while the whole
			# commit physics tick already uses burst movement semantics.
			_update_burst(0.0)
			return

	var tracking_target := _get_preferred_ranged_combat_target()
	var legs_stopped := _update_tracking_movement(
		1.0,
		false,
		tracking_target,
		false
	)
	_update_post_burst_fire_visual(safe_delta, legs_stopped)


func _process(delta: float) -> void:
	if not is_multiplayer_proxy:
		super._process(delta)
		return
	if is_dead:
		set_process(false)
		return
	if not proxy_fire_visual_active:
		set_process(false)
		return

	var safe_delta := maxf(delta, 0.0)
	if safe_delta + FIRE_VISUAL_TIME_EPSILON >= proxy_fire_visual_time_left:
		proxy_fire_visual_time_left = 0.0
		_restore_proxy_move_animation_with_phase()
		set_process(false)
		return
	proxy_fire_visual_time_left -= safe_delta

	proxy_fire_upper_phase = fposmod(
		proxy_fire_upper_phase + safe_delta * FIRE_UPPER_FPS,
		float(FIRE_UPPER_PHASE_COUNT)
	)
	if velocity == Vector2.ZERO:
		proxy_fire_leg_phase = 0.0
	else:
		proxy_fire_leg_phase = fposmod(
			proxy_fire_leg_phase + safe_delta * FIRE_LEG_FPS,
			float(FIRE_LEG_PHASE_COUNT)
		)
	_apply_fire_composite_frame(
		proxy_fire_upper_phase,
		proxy_fire_leg_phase
	)


func _apply_config() -> void:
	super._apply_config()
	combat_state = CombatState.TRACKING_READY
	attack_cooldown_left = 0.0
	burst_target = null
	burst_shots_fired = 0
	burst_fire_time_left = 0.0
	locked_fire_direction = Vector2.RIGHT
	fire_upper_phase = 0.0
	fire_leg_phase = 0.0
	fire_visual_time_left = 0.0
	proxy_fire_visual_time_left = 0.0
	proxy_fire_upper_phase = 0.0
	proxy_fire_leg_phase = 0.0
	proxy_fire_visual_active = false
	proxy_action_restore_animation_name = &""
	proxy_action_restore_token_snapshot = 0
	gunner_config_cache = config as GunnerConfig
	if attack_audio != null:
		attack_audio.stream = (
			gunner_config_cache.attack_audio_stream
			if gunner_config_cache != null
			else null
		)
	_sync_muzzle_facing()


func _die() -> void:
	_cancel_burst(false)
	latest_proxy_action_id += 1
	super._die()


func play_multiplayer_death_sequence() -> void:
	latest_proxy_action_id += 1
	_clear_proxy_fire_visual(true)
	super.play_multiplayer_death_sequence()


func set_multiplayer_proxy_visual_active(active: bool) -> void:
	super.set_multiplayer_proxy_visual_active(active)
	if active or not is_multiplayer_proxy:
		return
	_clear_proxy_fire_visual(true)


func _try_start_burst(candidate_target: Node2D = null) -> bool:
	if gunner_config_cache == null:
		return false
	if combat_state != CombatState.TRACKING_READY:
		return false
	if gunner_config_cache.projectile_scene == null:
		return false
	if not _is_ranged_combat_target_in_range(
		candidate_target,
		gunner_config_cache.attack_range
	):
		return false

	burst_target = candidate_target
	locked_fire_direction = global_position.direction_to(
		candidate_target.global_position
	)
	if locked_fire_direction == Vector2.ZERO:
		locked_fire_direction = Vector2.LEFT if facing_left else Vector2.RIGHT
	else:
		locked_fire_direction = locked_fire_direction.normalized()
	combat_state = CombatState.BURST
	burst_shots_fired = 0
	burst_fire_time_left = 0.0
	fire_visual_time_left = 0.0
	_capture_authoritative_leg_phase()
	fire_upper_phase = 0.0
	_clear_cached_navigation_move_direction()
	_update_facing(locked_fire_direction)
	_apply_fire_composite_frame(fire_upper_phase, fire_leg_phase)
	return true


func _update_burst(delta: float) -> void:
	if is_dead or combat_state != CombatState.BURST:
		return
	if gunner_config_cache == null:
		_cancel_burst(true)
		return

	var locked_tracking_target := _get_live_burst_target()
	var legs_stopped := _update_tracking_movement(
		gunner_config_cache.burst_move_speed_multiplier,
		true,
		locked_tracking_target,
		true
	)
	_advance_authoritative_fire_composite(delta, legs_stopped)

	burst_fire_time_left -= maxf(delta, 0.0)
	var shot_interval := maxf(gunner_config_cache.burst_fire_interval, 0.01)
	var shot_count := maxi(gunner_config_cache.burst_count, 1)
	while burst_fire_time_left <= 0.0 and burst_shots_fired < shot_count:
		if not _fire_locked_bullet():
			# Keep the overdue shot pending for the next physics frame. Counting
			# only successful spawns preserves the authored 12-projectile burst.
			break
		burst_shots_fired += 1
		burst_fire_time_left += shot_interval

	if burst_shots_fired >= shot_count:
		_finish_burst()


func _finish_burst() -> void:
	if combat_state != CombatState.BURST:
		return
	combat_state = CombatState.TRACKING_COOLDOWN
	attack_cooldown_left = (
		maxf(gunner_config_cache.attack_cooldown, 0.0)
		if gunner_config_cache != null
		else 0.0
	)
	burst_target = null
	burst_fire_time_left = 0.0
	_clear_cached_navigation_move_direction()


func _cancel_burst(play_move_animation: bool) -> void:
	combat_state = CombatState.TRACKING_READY
	attack_cooldown_left = 0.0
	burst_target = null
	burst_shots_fired = 0
	burst_fire_time_left = 0.0
	fire_visual_time_left = 0.0
	velocity = Vector2.ZERO
	_clear_cached_navigation_move_direction()
	if play_move_animation and config != null and not is_dead:
		_restore_move_animation_with_phase(fire_leg_phase)


func _get_live_burst_target() -> Node2D:
	if _is_ranged_combat_target_valid(burst_target):
		return burst_target
	if burst_target != null:
		burst_target = null
		_clear_cached_navigation_move_direction()
	return null


func _update_tracking_movement(
	speed_multiplier: float,
	preserve_fire_direction: bool,
	tracking_target: Node2D,
	use_tracking_target_for_navigation: bool
) -> bool:
	var live_tracking_target := (
		tracking_target
		if _is_ranged_combat_target_valid(tracking_target)
		else null
	)
	var stop_distance := (
		maxf(gunner_config_cache.stop_distance, 0.0)
		if gunner_config_cache != null
		else 0.0
	)
	var within_stop_distance := (
		live_tracking_target != null
		and global_position.distance_squared_to(
			live_tracking_target.global_position
		) <= stop_distance * stop_distance
	)
	var contact_stopped := _has_player_contact()
	if contact_stopped or within_stop_distance:
		velocity = Vector2.ZERO
		if preserve_fire_direction:
			_update_facing(locked_fire_direction)
		elif live_tracking_target != null:
			_update_facing(
				global_position.direction_to(live_tracking_target.global_position)
			)
		return true

	var navigation_target := (
		live_tracking_target
		if use_tracking_target_for_navigation and live_tracking_target != null
		else objective_target
	)
	if not is_instance_valid(navigation_target):
		velocity = Vector2.ZERO
		if preserve_fire_direction:
			_update_facing(locked_fire_direction)
		return false

	var move_direction := _get_navigation_move_direction(navigation_target)
	velocity = (
		move_direction
		* get_effective_move_speed()
		* clampf(speed_multiplier, 0.0, 1.0)
	)
	if preserve_fire_direction:
		_update_facing(locked_fire_direction)
	else:
		_update_facing(move_direction)
	_move_until_player_contact()
	return false


func _fire_locked_bullet() -> bool:
	if gunner_config_cache == null or gunner_config_cache.projectile_scene == null:
		return false
	if (
		combat_runtime == null
		or not is_instance_valid(combat_runtime)
		or gameplay_gateway == null
		or not is_instance_valid(gameplay_gateway)
	):
		return false
	var spawn_parent: Node = combat_runtime

	var spread_radians := deg_to_rad(
		maxf(gunner_config_cache.spread_angle_degrees, 0.0)
	)
	var shot_direction := locked_fire_direction.rotated(
		random_generator.randf_range(-spread_radians, spread_radians)
	).normalized()
	var projectile: CapooAK47Bullet = null
	var uses_registered_pool := combat_runtime.has_session_object_pool_scene(
		gunner_config_cache.projectile_scene
	)
	if uses_registered_pool:
		projectile = combat_runtime.acquire_session_object(
			gunner_config_cache.projectile_scene,
			false
		) as CapooAK47Bullet
	else:
		projectile = (
			gunner_config_cache.projectile_scene.instantiate()
			as CapooAK47Bullet
		)
	if projectile == null:
		push_warning("持枪战斗机器人弹丸场景必须实例化 CapooAK47Bullet。")
		return false

	var outgoing_damage := get_effective_attack_damage(
		gunner_config_cache.attack_damage
	)
	var projectile_spawn_position := _get_safe_muzzle_spawn_position()
	projectile.top_level = true
	var gunner_bullet := projectile as CombatRobotGunnerBullet
	if gunner_bullet == null:
		push_warning("持枪战斗机器人弹丸必须使用 CombatRobotGunnerBullet。")
		if uses_registered_pool:
			combat_runtime.release_session_object(projectile)
		else:
			projectile.queue_free()
		return false
	gunner_bullet.bind_gameplay_context(combat_runtime, gameplay_gateway)
	if projectile.get_parent() == null:
		spawn_parent.add_child(projectile)
	elif projectile.get_parent() != spawn_parent:
		projectile.reparent(spawn_parent)
	projectile.setup(
		shot_direction,
		outgoing_damage,
		gunner_config_cache.projectile_speed,
		gunner_config_cache.projectile_lifetime,
		pathfinder as GridPathfinder,
		projectile_motion_system,
		create_damage_source_snapshot(0, gunner_bullet.authored_source_type)
	)
	projectile.global_position = projectile_spawn_position
	projectile.reset_physics_interpolation()
	gameplay_gateway.register_local_projectile(
		projectile,
		gunner_config_cache.projectile_type,
		0,
		projectile.global_position,
		shot_direction,
		outgoing_damage,
		gunner_config_cache.projectile_speed,
		gunner_config_cache.projectile_lifetime
	)

	_show_authoritative_shot_phase(burst_shots_fired)
	if burst_shots_fired % 2 == 0:
		attack_audio.pitch_scale = random_generator.randf_range(0.98, 1.03)
		ENEMY_ATTACK_AUDIO_LIMITER.play_rapid_fire(attack_audio)
	_broadcast_enemy_action(ACTION_FIRE, locked_fire_direction)
	return true


func _get_safe_muzzle_spawn_position() -> Vector2:
	_sync_muzzle_facing()
	var center_position := global_position
	var desired_position := muzzle.global_position
	var muzzle_segment := desired_position - center_position
	var muzzle_distance := muzzle_segment.length()
	if muzzle_distance <= 0.0:
		return center_position

	muzzle_world_query.from = center_position
	muzzle_world_query.to = desired_position
	var hit := get_world_2d().direct_space_state.intersect_ray(
		muzzle_world_query
	)
	if hit.is_empty():
		return desired_position

	var hit_position := hit.get("position", center_position) as Vector2
	var safe_distance := maxf(
		center_position.distance_to(hit_position) - MUZZLE_WORLD_CLEARANCE,
		0.0
	)
	return center_position + muzzle_segment.normalized() * minf(
		safe_distance,
		muzzle_distance
	)


func _capture_authoritative_leg_phase() -> void:
	fire_leg_phase = _read_current_leg_phase(fire_leg_phase)


func _read_current_leg_phase(previous_phase: float) -> float:
	if animated_sprite == null or config == null:
		return fposmod(previous_phase, float(FIRE_LEG_PHASE_COUNT))
	if animated_sprite.animation == config.move_animation_name:
		return fposmod(
			float(animated_sprite.frame) + animated_sprite.frame_progress,
			float(FIRE_LEG_PHASE_COUNT)
		)
	if (
		gunner_config_cache != null
		and animated_sprite.animation == gunner_config_cache.fire_walk_animation_name
	):
		return fposmod(
			float(animated_sprite.frame % FIRE_LEG_PHASE_COUNT),
			float(FIRE_LEG_PHASE_COUNT)
		)
	return fposmod(previous_phase, float(FIRE_LEG_PHASE_COUNT))


func _advance_authoritative_fire_composite(
	delta: float,
	legs_stopped: bool
) -> void:
	var safe_delta := maxf(delta, 0.0)
	fire_upper_phase = fposmod(
		fire_upper_phase + safe_delta * FIRE_UPPER_FPS,
		float(FIRE_UPPER_PHASE_COUNT)
	)
	if legs_stopped:
		fire_leg_phase = 0.0
	elif velocity != Vector2.ZERO:
		fire_leg_phase = fposmod(
			fire_leg_phase + safe_delta * FIRE_LEG_FPS,
			float(FIRE_LEG_PHASE_COUNT)
		)
	_apply_fire_composite_frame(fire_upper_phase, fire_leg_phase)


func _show_authoritative_shot_phase(shot_index: int) -> void:
	fire_upper_phase = 0.0 if shot_index % 2 == 0 else 2.0
	fire_visual_time_left = FIRE_VISUAL_DURATION
	_apply_fire_composite_frame(fire_upper_phase, fire_leg_phase)


func _update_post_burst_fire_visual(
	delta: float,
	legs_stopped: bool
) -> void:
	if fire_visual_time_left <= 0.0:
		return
	if delta + FIRE_VISUAL_TIME_EPSILON >= fire_visual_time_left:
		fire_visual_time_left = 0.0
		_restore_move_animation_with_phase(fire_leg_phase)
		return
	fire_visual_time_left -= delta
	_advance_authoritative_fire_composite(delta, legs_stopped)


func _apply_fire_composite_frame(
	upper_phase: float,
	leg_phase: float
) -> void:
	if animated_sprite == null or gunner_config_cache == null:
		return
	var animation_name := gunner_config_cache.fire_walk_animation_name
	if (
		animated_sprite.sprite_frames == null
		or not animated_sprite.sprite_frames.has_animation(animation_name)
	):
		return
	if animated_sprite.animation != animation_name:
		animated_sprite.play(animation_name)
	animated_sprite.pause()
	var upper_index := floori(fposmod(
		upper_phase,
		float(FIRE_UPPER_PHASE_COUNT)
	))
	var leg_index := floori(fposmod(
		leg_phase,
		float(FIRE_LEG_PHASE_COUNT)
	))
	animated_sprite.frame = upper_index * FIRE_LEG_PHASE_COUNT + leg_index
	animated_sprite.frame_progress = 0.0


func _restore_move_animation_with_phase(leg_phase: float) -> void:
	if animated_sprite == null or config == null or is_dead:
		return
	_play_scene_animation(config.move_animation_name)
	if animated_sprite.animation != config.move_animation_name:
		return
	var normalized_leg_phase := fposmod(
		leg_phase,
		float(FIRE_LEG_PHASE_COUNT)
	)
	animated_sprite.frame = floori(normalized_leg_phase)
	animated_sprite.frame_progress = normalized_leg_phase - floorf(
		normalized_leg_phase
	)
	_sync_move_animation_playback()


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
	if action_name != ACTION_FIRE:
		return
	if not multiplayer_proxy_visual_active:
		return

	var safe_elapsed := maxf(action_elapsed, 0.0)
	if safe_elapsed >= FIRE_VISUAL_DURATION:
		_clear_proxy_fire_visual(true)
		return
	var safe_direction := (
		direction.normalized()
		if direction != Vector2.ZERO
		else Vector2.RIGHT
	)
	_update_facing(safe_direction)
	if not proxy_fire_visual_active:
		proxy_fire_leg_phase = _read_current_leg_phase(
			proxy_fire_leg_phase
		)
	if velocity == Vector2.ZERO:
		proxy_fire_leg_phase = 0.0
	else:
		proxy_fire_leg_phase = fposmod(
			proxy_fire_leg_phase + safe_elapsed * FIRE_LEG_FPS,
			float(FIRE_LEG_PHASE_COUNT)
		)
	var proxy_base_upper_phase := 0.0 if action_id % 2 == 1 else 2.0
	proxy_fire_upper_phase = fposmod(
		proxy_base_upper_phase + safe_elapsed * FIRE_UPPER_FPS,
		float(FIRE_UPPER_PHASE_COUNT)
	)
	proxy_fire_visual_time_left = FIRE_VISUAL_DURATION - safe_elapsed
	proxy_fire_visual_active = true

	var animation_name := gunner_config_cache.fire_walk_animation_name
	_play_multiplayer_proxy_action_animation(animation_name, -1.0)
	proxy_action_restore_animation_name = animation_name
	proxy_action_restore_token_snapshot = proxy_action_restore_token
	_apply_fire_composite_frame(
		proxy_fire_upper_phase,
		proxy_fire_leg_phase
	)
	set_process(true)


func _restore_proxy_move_animation_with_phase() -> void:
	if not proxy_fire_visual_active:
		return
	var inherited_leg_phase := proxy_fire_leg_phase
	_restore_multiplayer_proxy_move_animation(
		proxy_action_restore_token_snapshot,
		proxy_action_restore_animation_name
	)
	proxy_fire_visual_active = false
	proxy_fire_visual_time_left = 0.0
	proxy_action_restore_animation_name = &""
	proxy_action_restore_token_snapshot = 0
	if animated_sprite != null and config != null:
		var normalized_leg_phase := fposmod(
			inherited_leg_phase,
			float(FIRE_LEG_PHASE_COUNT)
		)
		if animated_sprite.animation == config.move_animation_name:
			animated_sprite.frame = floori(normalized_leg_phase)
			animated_sprite.frame_progress = (
				normalized_leg_phase - floorf(normalized_leg_phase)
			)


func _clear_proxy_fire_visual(restore_move_animation: bool) -> void:
	if restore_move_animation:
		_restore_proxy_move_animation_with_phase()
	proxy_fire_visual_active = false
	proxy_fire_visual_time_left = 0.0
	proxy_action_restore_animation_name = &""
	proxy_action_restore_token_snapshot = 0
	set_process(false)


func _get_navigation_move_direction(target: Node2D) -> Vector2:
	return _get_safe_navigation_move_direction(
		target,
		pathfinder,
		waypoint_arrival_distance
	)


func _update_facing(move_direction: Vector2) -> void:
	if is_zero_approx(move_direction.x):
		return
	var previous_facing_left := facing_left
	_set_facing_from_direction(move_direction)
	if facing_left != previous_facing_left:
		_sync_muzzle_facing()


func _sync_muzzle_facing() -> void:
	if muzzle == null:
		return
	muzzle.position = Vector2(
		-MUZZLE_RIGHT_POSITION.x if facing_left else MUZZLE_RIGHT_POSITION.x,
		MUZZLE_RIGHT_POSITION.y
	)


func _broadcast_enemy_action(action_name: StringName, direction: Vector2) -> void:
	action_sequence += 1
	if gameplay_gateway == null or not is_instance_valid(gameplay_gateway):
		return
	gameplay_gateway.broadcast_enemy_action(
		int(get_meta("net_id", 0)),
		action_name,
		direction,
		global_position,
		action_sequence
	)
