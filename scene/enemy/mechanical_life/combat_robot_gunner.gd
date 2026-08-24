extends "res://scene/enemy/layered_ranged_enemy.gd"
class_name CombatRobotGunner

const GunnerConfig := preload(
	"res://resources/config/enemies/combat_robot_gunner_config.gd"
)
const ENEMY_ATTACK_AUDIO_LIMITER := preload(
	"res://scene/combat/audio/enemy_attack_audio_limiter.gd"
)
const EnemyRapidFireNetworkCodec := preload(
	"res://scene/multiplayer/projectile/enemy_rapid_fire_network_codec.gd"
)
const ACTION_FIRE: StringName = &"combat_robot_gunner_fire"
const ACTION_BURST: StringName = &"combat_robot_gunner_burst"
const LAYERED_FAMILY_SCRIPT_PATH := (
	"res://scene/enemy/mechanical_life/combat_robot_gunner.gd"
)
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
var latest_proxy_action_id: int = 0
var layered_gunner_burst_finalize_pending := false
var layered_gunner_motion_pending := false
var layered_gunner_legs_stopped := false
var layered_gunner_contact_target: Enemy = null


func supports_dynamic_enemy_targeting() -> bool:
	return true


var gunner_config_cache: GunnerConfig = null
var local_data_projectile_sequence: int = 0
var network_burst_projectile_ids := PackedInt64Array()
var network_burst_attached_states := PackedByteArray()
var network_burst_descriptor := PackedByteArray()
var network_burst_descriptor_sent := false

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


func supports_centralized_authoritative_simulation() -> bool:
	return true


func _supports_layered_ranged_authoritative_simulation() -> bool:
	var implementation := get_script() as Script
	return (
		implementation != null
		and implementation.resource_path == LAYERED_FAMILY_SCRIPT_PATH
	)


func _supports_layered_ranged_contact_authority() -> bool:
	# Only the exact ordinary/elite script closure publishes Gunner's authored
	# rectangle and consumes the directed TOI fraction below. Future scripts must
	# prove their own movement/attack state machine before contact admission.
	return _supports_layered_ranged_authoritative_simulation()


func _supports_layered_ranged_indexed_touch_authority() -> bool:
	return false


func _uses_inherited_touch_damage() -> bool:
	# LayeredRangedEnemy inherits Capoo's weapon-only default; Gunner explicitly
	# retains its authored physical body touch during and between bursts.
	return true


func get_layered_area_decision_interval_frames() -> int:
	# Authored tracking reacquires its preferred movement target every physics
	# tick, independently from the 3-tick burst-acquisition throttle.
	return 1


func _run_authoritative_physics_step(delta: float) -> void:
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


func _prepare_layered_ranged_authoritative_simulation() -> void:
	layered_gunner_burst_finalize_pending = false
	layered_gunner_motion_pending = false
	layered_gunner_legs_stopped = false
	layered_gunner_contact_target = null


func _layered_area_touch_damage_precedes_family_event() -> bool:
	return true


func _advance_layered_ranged_event_phase(delta: float) -> void:
	layered_gunner_burst_finalize_pending = false
	layered_gunner_motion_pending = false
	layered_gunner_legs_stopped = false
	if combat_state == CombatState.BURST:
		_prepare_layered_gunner_burst_tick(maxf(delta, 0.0))
		return
	if combat_state != CombatState.TRACKING_COOLDOWN:
		return
	attack_cooldown_left = maxf(
		attack_cooldown_left - maxf(delta, 0.0),
		0.0
	)
	if attack_cooldown_left <= 0.0:
		combat_state = CombatState.TRACKING_READY
		request_layered_area_urgent_decision()


func _can_sleep_layered_ranged_event_phase() -> bool:
	return combat_state == CombatState.TRACKING_READY


## Committed bursts retain their locked target/direction and do not run the
## ordinary dynamic-target refresh. READY/COOLDOWN tracking remains a 60 Hz
## decision because that is the authored movement-target cadence.
func _simulate_layered_area_decision_body(delta: float) -> bool:
	if is_dead:
		velocity = Vector2.ZERO
		_clear_layered_gunner_tick_plan()
		return true
	if combat_state == CombatState.BURST:
		_publish_layered_gunner_motion_plan()
		layered_area_decision_urgent = false
		return true

	refresh_dynamic_combat_target_decision(Engine.get_physics_frames())
	if combat_state == CombatState.TRACKING_READY and _is_combat_sense_refresh_due():
		var candidate_target := _get_preferred_ranged_combat_target()
		if _try_start_burst(candidate_target):
			# COMPAT calls _update_burst(0) on the commit tick. Plan the same
			# half-speed physics movement now; motion submits it before the first
			# projectile is emitted at the moved muzzle position.
			_prepare_layered_gunner_burst_tick(0.0)
			_publish_layered_gunner_motion_plan()
			layered_area_decision_urgent = false
			return true

	var tracking_target := _get_preferred_ranged_combat_target()
	layered_gunner_legs_stopped = _update_tracking_movement(
		1.0,
		false,
		tracking_target,
		false,
		false
	)
	_update_post_burst_fire_visual(
		maxf(delta, 0.0),
		layered_gunner_legs_stopped
	)
	layered_gunner_motion_pending = velocity != Vector2.ZERO
	layered_area_planned_move_direction = (
		velocity.normalized()
		if layered_gunner_motion_pending
		else Vector2.ZERO
	)
	_publish_layered_gunner_motion_plan()
	layered_area_decision_urgent = false
	return true


func _can_run_layered_area_motion() -> bool:
	return (
		not is_dead
		and (
			layered_gunner_motion_pending
			or layered_gunner_burst_finalize_pending
		)
	)


func get_layered_area_planned_displacement(delta: float) -> Vector2:
	if not layered_gunner_motion_pending:
		return Vector2.ZERO
	return velocity * maxf(delta, 0.0)


func _simulate_layered_area_motion_body(delta: float) -> bool:
	if is_dead:
		velocity = Vector2.ZERO
		_clear_layered_gunner_tick_plan()
		return true
	if layered_gunner_motion_pending and velocity != Vector2.ZERO:
		# EnemyContactService samples the full displacement before this phase. Apply
		# its directed TOI only to the explicitly published hostile Enemy target;
		# Player/Plant contact remains owned by the authored Area2D.
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
			# Match SimpleChase's soft-contact contract: the submitted transform ends
			# on the shell and the shot below observes that moved muzzle, while the
			# externally visible velocity is stopped in this same physics tick.
			velocity = Vector2.ZERO

	if layered_gunner_burst_finalize_pending:
		_finalize_layered_gunner_burst_tick()
	else:
		layered_gunner_motion_pending = false
		layered_area_motion_phase_due = false
	return true


func _prepare_layered_gunner_burst_tick(delta: float) -> void:
	if is_dead or combat_state != CombatState.BURST:
		_clear_layered_gunner_tick_plan()
		return
	if gunner_config_cache == null:
		_cancel_burst(true)
		_clear_layered_gunner_tick_plan()
		return

	var locked_tracking_target := _get_live_burst_target()
	layered_gunner_legs_stopped = _update_tracking_movement(
		gunner_config_cache.burst_move_speed_multiplier,
		true,
		locked_tracking_target,
		true,
		false
	)
	_advance_authoritative_fire_composite(
		maxf(delta, 0.0),
		layered_gunner_legs_stopped
	)
	burst_fire_time_left -= maxf(delta, 0.0)
	layered_gunner_burst_finalize_pending = true
	layered_gunner_motion_pending = velocity != Vector2.ZERO
	layered_area_planned_move_direction = (
		velocity.normalized()
		if layered_gunner_motion_pending
		else locked_fire_direction
	)


func _finalize_layered_gunner_burst_tick() -> void:
	if is_dead or combat_state != CombatState.BURST:
		_clear_layered_gunner_tick_plan()
		return
	if gunner_config_cache == null:
		_cancel_burst(true)
		_clear_layered_gunner_tick_plan()
		return
	var shot_interval := maxf(gunner_config_cache.burst_fire_interval, 0.01)
	var shot_count := maxi(gunner_config_cache.burst_count, 1)
	while burst_fire_time_left <= 0.0 and burst_shots_fired < shot_count:
		if not _fire_locked_bullet():
			break
		burst_shots_fired += 1
		burst_fire_time_left += shot_interval

	layered_gunner_burst_finalize_pending = false
	layered_gunner_motion_pending = false
	if burst_shots_fired >= shot_count:
		_finish_burst()
		layered_area_planned_move_direction = Vector2.ZERO
		layered_area_motion_phase_due = false
		return
	# The next event tick replans movement and the overdue shot. Keep this
	# registration resident in the persistent motion lane without inventing a
	# second movement or fire on the current tick.
	layered_area_motion_phase_due = true


func _publish_layered_gunner_motion_plan() -> void:
	layered_area_motion_state_known = true
	layered_area_last_can_move = _can_run_layered_area_motion()
	if not layered_area_last_can_move:
		layered_area_planned_move_direction = Vector2.ZERO
	layered_area_motion_phase_due = layered_area_last_can_move


func _clear_layered_gunner_tick_plan() -> void:
	layered_gunner_burst_finalize_pending = false
	layered_gunner_motion_pending = false
	layered_gunner_legs_stopped = false
	layered_gunner_contact_target = null
	layered_area_planned_move_direction = Vector2.ZERO
	layered_area_last_can_move = false
	layered_area_motion_phase_due = false


func get_layered_area_contact_target() -> Node2D:
	if (
		layered_gunner_contact_target == null
		or not is_instance_valid(layered_gunner_contact_target)
		or not can_attack_combat_target(layered_gunner_contact_target)
	):
		return null
	return layered_gunner_contact_target


func _publish_layered_gunner_contact_target(target: Node2D) -> void:
	layered_gunner_contact_target = null
	if target == null or not is_instance_valid(target):
		return
	var enemy_target := target as Enemy
	if enemy_target == null or not can_attack_combat_target(enemy_target):
		return
	layered_gunner_contact_target = enemy_target


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
	_release_unused_network_burst_ids()
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
	local_data_projectile_sequence = 0
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
	_prepare_network_burst()
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
	_release_unused_network_burst_ids()
	combat_state = CombatState.TRACKING_COOLDOWN
	attack_cooldown_left = (
		maxf(gunner_config_cache.attack_cooldown, 0.0)
		if gunner_config_cache != null
		else 0.0
	)
	burst_target = null
	burst_fire_time_left = 0.0
	layered_gunner_contact_target = null
	_clear_cached_navigation_move_direction()


func _cancel_burst(play_move_animation: bool) -> void:
	_release_unused_network_burst_ids()
	combat_state = CombatState.TRACKING_READY
	attack_cooldown_left = 0.0
	burst_target = null
	burst_shots_fired = 0
	burst_fire_time_left = 0.0
	fire_visual_time_left = 0.0
	velocity = Vector2.ZERO
	layered_gunner_contact_target = null
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
	use_tracking_target_for_navigation: bool,
	submit_motion: bool = true
) -> bool:
	var live_tracking_target := (
		tracking_target
		if _is_ranged_combat_target_valid(tracking_target)
		else null
	)
	_publish_layered_gunner_contact_target(live_tracking_target)
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

	var move_direction := _get_gunner_navigation_move_direction(navigation_target)
	velocity = (
		move_direction
		* get_effective_move_speed()
		* clampf(speed_multiplier, 0.0, 1.0)
	)
	if preserve_fire_direction:
		_update_facing(locked_fire_direction)
	else:
		_update_facing(move_direction)
	if submit_motion:
		_move_until_player_contact()
	return false


func _fire_locked_bullet() -> bool:
	if gunner_config_cache == null:
		return false
	if (
		combat_runtime == null
		or not is_instance_valid(combat_runtime)
		or gameplay_gateway == null
		or not is_instance_valid(gameplay_gateway)
	):
		return false
	# Client enemies replay Host actions while MpProjectileCoordinator rebuilds
	# visual-only REPLICA rows. They never own an authority backend.
	if combat_runtime.runtime_mode == CombatRuntimeBase.RuntimeMode.CLIENT_VIEW:
		return false

	var spread_radians := deg_to_rad(
		maxf(gunner_config_cache.spread_angle_degrees, 0.0)
	)
	var shot_direction := locked_fire_direction.rotated(
		random_generator.randf_range(-spread_radians, spread_radians)
	).normalized()
	if not _fire_data_projectile(shot_direction):
		return false

	# Preserve animation, pitch RNG, audio cadence and action broadcast ordering
	# after successful data registration.
	_show_authoritative_shot_phase(burst_shots_fired)
	if burst_shots_fired % 2 == 0:
		attack_audio.pitch_scale = random_generator.randf_range(0.98, 1.03)
		ENEMY_ATTACK_AUDIO_LIMITER.play_rapid_fire(attack_audio)
	if not network_burst_descriptor_sent:
		_broadcast_enemy_action(ACTION_FIRE, locked_fire_direction)
	return true

func _fire_data_projectile(shot_direction: Vector2) -> bool:
	var rapid_fire_service := _get_rapid_fire_simulation_service()
	if rapid_fire_service == null:
		return false
	var profile := _get_rapid_fire_profile()
	if profile == RapidFireSimulationService.Profile.INVALID:
		return false

	var spawn_position := _get_safe_muzzle_spawn_position()
	var outgoing_damage := get_effective_attack_damage(
		gunner_config_cache.attack_damage
	)
	var phase_identity := _next_local_data_phase_identity()
	var profile_source_type := rapid_fire_service.get_profile_source_type(profile)
	var launch_source_snapshot := create_damage_source_snapshot(
		0,
		profile_source_type
	)
	var handle := rapid_fire_service.register_projectile(
		RapidFireSimulationService.Mode.DATA,
		profile,
		spawn_position,
		shot_direction,
		gunner_config_cache.projectile_speed,
		gunner_config_cache.projectile_lifetime,
		outgoing_damage,
		_get_stable_source_enemy_id(),
		0,
		RapidFireSimulationService.GUNNER_WORLD_CHECK_INTERVAL,
		posmod(
			phase_identity,
			RapidFireSimulationService.GUNNER_WORLD_CHECK_INTERVAL
		),
		launch_source_snapshot
	)
	if handle <= RapidFireSimulationService.INVALID_HANDLE:
		return false

	if (
		combat_runtime.runtime_mode
		== CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY
	):
		var projectile_id := _attach_network_data_projectile(
			rapid_fire_service,
			handle,
			outgoing_damage,
			gunner_config_cache.projectile_lifetime,
			launch_source_snapshot
		)
		# A rejected Host identity is terminal: release the inert handle and do
		# not silently reintroduce a Node authority backend.
		if projectile_id <= 0:
			rapid_fire_service.release_projectile(handle)
			return false
	return true


func _prepare_network_burst() -> bool:
	_release_unused_network_burst_ids()
	if (
		gunner_config_cache == null
		or combat_runtime == null
		or combat_runtime.runtime_mode
			!= CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY
		or gameplay_gateway == null
		or not is_instance_valid(gameplay_gateway)
	):
		return false
	var shot_count := maxi(gunner_config_cache.burst_count, 1)
	network_burst_projectile_ids = (
		gameplay_gateway.reserve_enemy_rapid_fire_projectile_ids(shot_count)
	)
	if network_burst_projectile_ids.size() != shot_count:
		network_burst_projectile_ids = PackedInt64Array()
		return false
	network_burst_attached_states.resize(shot_count)
	network_burst_attached_states.fill(0)
	var directions := _preview_network_burst_directions(shot_count)
	var profile := _get_rapid_fire_profile()
	var batch_action_id := action_sequence + 1
	network_burst_descriptor = EnemyRapidFireNetworkCodec.encode_burst(
		profile,
		batch_action_id,
		int(network_burst_projectile_ids[0]),
		_get_stable_source_enemy_id(),
		global_position,
		_get_safe_muzzle_spawn_position(),
		locked_fire_direction,
		maxf(gunner_config_cache.burst_fire_interval, 0.01),
		gunner_config_cache.projectile_speed,
		gunner_config_cache.projectile_lifetime,
		directions
	)
	if network_burst_descriptor.is_empty():
		_release_unused_network_burst_ids()
		return false
	action_sequence = batch_action_id
	return true


func _preview_network_burst_directions(
	shot_count: int
) -> PackedVector2Array:
	var preview_rng := RandomNumberGenerator.new()
	preview_rng.state = random_generator.state
	var spread_radians := deg_to_rad(
		maxf(gunner_config_cache.spread_angle_degrees, 0.0)
	)
	var directions := PackedVector2Array()
	directions.resize(shot_count)
	for shot_index in range(shot_count):
		directions[shot_index] = locked_fire_direction.rotated(
			preview_rng.randf_range(-spread_radians, spread_radians)
		).normalized()
		# Successful authored shots draw pitch only on even indices. Simulating
		# that draw on a cloned RNG keeps descriptor prediction bit-independent
		# from the real gameplay RNG stream.
		if shot_index % 2 == 0:
			var _discarded_pitch := preview_rng.randf_range(0.98, 1.03)
	return directions


func _attach_network_data_projectile(
	service: RapidFireSimulationService,
	handle: int,
	damage: int,
	lifetime: float,
	damage_source_snapshot: DamageSourceSnapshot
) -> int:
	var shot_index := burst_shots_fired
	if (
		shot_index < 0
		or shot_index >= network_burst_projectile_ids.size()
		or shot_index >= network_burst_attached_states.size()
		or network_burst_attached_states[shot_index] != 0
	):
		return 0
	var projectile_id := int(network_burst_projectile_ids[shot_index])
	if not gameplay_gateway.attach_reserved_enemy_rapid_fire_projectile(
		service,
		handle,
		projectile_id,
		gunner_config_cache.projectile_type,
		0,
		damage,
		lifetime,
		damage_source_snapshot
	):
		return 0
	network_burst_attached_states[shot_index] = 1
	if not network_burst_descriptor_sent:
		network_burst_descriptor_sent = (
			gameplay_gateway.broadcast_enemy_rapid_fire_burst(
				network_burst_descriptor
			)
		)
	return projectile_id


func _release_unused_network_burst_ids() -> void:
	if (
		gameplay_gateway != null
		and is_instance_valid(gameplay_gateway)
		and not network_burst_projectile_ids.is_empty()
	):
		var unused_ids := PackedInt64Array()
		for projectile_index in range(network_burst_projectile_ids.size()):
			if (
				projectile_index >= network_burst_attached_states.size()
				or network_burst_attached_states[projectile_index] == 0
			):
				unused_ids.append(network_burst_projectile_ids[projectile_index])
		if not unused_ids.is_empty():
			gameplay_gateway.release_enemy_rapid_fire_projectile_ids(unused_ids)
	network_burst_projectile_ids = PackedInt64Array()
	network_burst_attached_states = PackedByteArray()
	network_burst_descriptor = PackedByteArray()
	network_burst_descriptor_sent = false


func _get_rapid_fire_simulation_service() -> RapidFireSimulationService:
	var combat_services := combat_runtime.get_enemy_combat_services()
	if combat_services == null:
		return null
	return combat_services.get_rapid_fire_simulation_service()


func _get_rapid_fire_profile() -> RapidFireSimulationService.Profile:
	match gunner_config_cache.projectile_type:
		&"combat_robot_gunner_bullet":
			return RapidFireSimulationService.Profile.GUNNER
		&"combat_robot_gunner_elite_bullet":
			return RapidFireSimulationService.Profile.GUNNER_ELITE
	return RapidFireSimulationService.Profile.INVALID


func _get_stable_source_enemy_id() -> int:
	var network_enemy_id := int(get_meta(&"net_id", 0))
	if network_enemy_id > 0:
		return network_enemy_id
	return int(get_instance_id())


func _next_local_data_phase_identity() -> int:
	local_data_projectile_sequence += 1
	return int(get_instance_id()) + local_data_projectile_sequence


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


func resolve_multiplayer_rapid_fire_spawn_position(
	_profile: int,
	direction: Vector2,
	fallback_position: Vector2
) -> Vector2:
	if (
		not is_inside_tree()
		or not global_position.is_finite()
		or not direction.is_finite()
		or direction.is_zero_approx()
	):
		return fallback_position
	locked_fire_direction = direction.normalized()
	_update_facing(locked_fire_direction)
	return _get_safe_muzzle_spawn_position()


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
	var is_batched_burst := action_name == ACTION_BURST
	if action_name != ACTION_FIRE and not is_batched_burst:
		return
	if not multiplayer_proxy_visual_active:
		return

	var visual_duration := FIRE_VISUAL_DURATION
	if is_batched_burst and gunner_config_cache != null:
		visual_duration += (
			maxi(gunner_config_cache.burst_count - 1, 0)
			* maxf(gunner_config_cache.burst_fire_interval, 0.01)
		)
	var safe_elapsed := maxf(action_elapsed, 0.0)
	if safe_elapsed >= visual_duration:
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
	var proxy_base_upper_phase := (
		0.0
		if is_batched_burst
		else (0.0 if action_id % 2 == 1 else 2.0)
	)
	proxy_fire_upper_phase = fposmod(
		proxy_base_upper_phase + safe_elapsed * FIRE_UPPER_FPS,
		float(FIRE_UPPER_PHASE_COUNT)
	)
	proxy_fire_visual_time_left = visual_duration - safe_elapsed
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


func _get_navigation_move_direction(_delta: float) -> Vector2:
	if not is_instance_valid(objective_target):
		return Vector2.ZERO
	return _get_gunner_navigation_move_direction(objective_target)


func _get_gunner_navigation_move_direction(target: Node2D) -> Vector2:
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
