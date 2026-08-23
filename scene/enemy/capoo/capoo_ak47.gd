extends Enemy
class_name CapooAK47

const WORLD_COLLISION_MASK := 1
const CapooConfig := preload("res://resources/config/enemies/capoo_ak47_config.gd")
const ENEMY_ATTACK_AUDIO_LIMITER := preload(
	"res://scene/combat/audio/enemy_attack_audio_limiter.gd"
)
# Center-first ordering keeps every complete five-agent group at zero mean while
# spreading the five-physics-tick authored burst cadence across all five phases.
const ATTACK_PHASE_OFFSETS_PHYSICS_FRAMES: Array[int] = [0, -1, 1, -2, 2]

static var attack_phase_stagger_enabled := true

enum ProjectileBackend {
	LEGACY,
	SHADOW,
	DATA,
}

# The fixed-seed kernel, authored collision fixture and production SHADOW path
# certify the DATA backend. The process-wide switch remains explicit for
# deterministic regression probes; a live cohort never mixes authority paths.
static var projectile_backend: ProjectileBackend = ProjectileBackend.DATA

enum CombatState {
	CHASE,
	WINDUP,
	BURST,
}

@export var path_refresh_interval: float = 0.25
@export var waypoint_arrival_distance: float = 6.0
@export var direct_chase_extra_distance: float = 2.0

@onready var attack_audio: AudioStreamPlayer2D = $AttackAudio
@onready var muzzle_heat: Polygon2D = $MuzzleHeat

var combat_state: CombatState = CombatState.CHASE
var attack_cooldown_left: float = 0.0
var windup_time_left: float = 0.0
var burst_shot_direction := Vector2.RIGHT
var burst_shots_fired: int = 0
var burst_fire_time_left: float = 0.0
var burst_audio_step: int = 0
var action_sequence: int = 0
var latest_proxy_action_id: int = 0
var attack_target: Node2D = null
var committed_attack_phase_offset_seconds: float = 0.0
var committed_windup_duration_seconds: float = 0.0
var local_data_projectile_sequence: int = 0
var shadow_registration_failures: int = 0


func _ready() -> void:
	super._ready()
	_set_muzzle_heat(0.0, Vector2.RIGHT)


func can_target_water_plant_objectives() -> bool:
	return true


static func calculate_attack_phase_offset_physics_frames(phase_identity: int) -> int:
	return ATTACK_PHASE_OFFSETS_PHYSICS_FRAMES[
		posmod(phase_identity, ATTACK_PHASE_OFFSETS_PHYSICS_FRAMES.size())
	]


static func calculate_attack_phase_offset_seconds(
	phase_identity: int,
	physics_ticks_per_second: int
) -> float:
	return (
		float(calculate_attack_phase_offset_physics_frames(phase_identity))
		/ float(maxi(physics_ticks_per_second, 1))
	)


func _physics_process(delta: float) -> void:
	if is_dead:
		velocity = Vector2.ZERO
		return

	_update_touch_damage(delta)
	_update_attack_cooldown(delta)
	if (
		combat_state != CombatState.CHASE
		and not _is_ranged_combat_target_valid(attack_target)
	):
		_cancel_attack()

	match combat_state:
		CombatState.WINDUP:
			_update_windup(delta)
			return
		CombatState.BURST:
			_update_burst(delta)
			return

	var capoo_config := config as CapooConfig
	if _is_combat_sense_refresh_due():
		var preferred_target := _get_preferred_ranged_combat_target()
		if (
			capoo_config != null
			and _try_hold_ranged_attack_position(
				preferred_target,
				capoo_config.attack_range,
				WORLD_COLLISION_MASK
			)
		):
			if _try_start_windup(preferred_target):
				return
			# The attack commit performs an exact LOS query. If that invalidated a
			# previously clear sampled line, leave standoff in the same tick.
			if _try_hold_ranged_attack_position(
				preferred_target,
				capoo_config.attack_range,
				WORLD_COLLISION_MASK
			):
				_update_facing(
					global_position.direction_to(preferred_target.global_position)
				)
				return
		else:
			_reset_ranged_attack_position_state()
	elif _ranged_attack_position_held:
		# Reuse the sampled standoff decision between 20 Hz sensing ticks. Active
		# windup/burst states returned above and therefore retain their 60 Hz timing.
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
	burst_shots_fired = 0
	burst_fire_time_left = 0.0
	burst_audio_step = 0
	attack_target = null
	local_data_projectile_sequence = 0
	shadow_registration_failures = 0
	_clear_committed_attack_timing()
	_reset_ranged_attack_position_state()

	var capoo_config := config as CapooConfig
	if capoo_config != null:
		attack_audio.stream = capoo_config.attack_audio_stream


func _die() -> void:
	combat_state = CombatState.CHASE
	attack_target = null
	_clear_committed_attack_timing()
	_reset_ranged_attack_position_state()
	_set_muzzle_heat(0.0, burst_shot_direction)
	super._die()


func play_multiplayer_death_sequence() -> void:
	latest_proxy_action_id += 1
	_clear_committed_attack_timing()
	_set_muzzle_heat(0.0, burst_shot_direction)
	super.play_multiplayer_death_sequence()


func _update_attack_cooldown(delta: float) -> void:
	if attack_cooldown_left <= 0.0:
		return
	attack_cooldown_left = maxf(attack_cooldown_left - delta, 0.0)


func _try_start_windup(candidate_target: Node2D = null) -> bool:
	var capoo_config := config as CapooConfig
	if capoo_config == null:
		return false
	if attack_cooldown_left > 0.0:
		return false
	if candidate_target == null:
		candidate_target = _get_preferred_ranged_combat_target()
	if candidate_target == null:
		return false
	if capoo_config.projectile_scene == null:
		return false
	if not _is_ranged_combat_target_in_range(
		candidate_target,
		capoo_config.attack_range
	):
		return false
	if not _has_ranged_combat_line(
		candidate_target,
		WORLD_COLLISION_MASK,
		true
	):
		_reset_ranged_attack_position_state()
		return false

	attack_target = candidate_target
	combat_state = CombatState.WINDUP
	committed_attack_phase_offset_seconds = (
		calculate_attack_phase_offset_seconds(
			navigation_update_frame_offset,
			Engine.physics_ticks_per_second
		)
		if CapooAK47.attack_phase_stagger_enabled
		else 0.0
	)
	committed_windup_duration_seconds = maxf(
		capoo_config.attack_windup + committed_attack_phase_offset_seconds,
		0.0
	)
	windup_time_left = committed_windup_duration_seconds
	velocity = Vector2.ZERO
	_set_ranged_attack_position_held(true)
	var target_direction := global_position.direction_to(attack_target.global_position)
	_update_facing(target_direction)
	_play_config_animation(capoo_config.windup_animation_name)
	_set_muzzle_heat(0.0, target_direction)
	_broadcast_enemy_action(&"windup", target_direction)
	return true


func _update_windup(delta: float) -> void:
	var capoo_config := config as CapooConfig
	if (
		capoo_config == null
		or not _is_ranged_combat_target_in_range(
			attack_target,
			capoo_config.attack_range
		)
	):
		_cancel_attack()
		return

	velocity = Vector2.ZERO
	var target_direction := global_position.direction_to(attack_target.global_position)
	_update_facing(target_direction)
	windup_time_left = maxf(windup_time_left - delta, 0.0)
	var progress := 1.0 - (
		windup_time_left / maxf(committed_windup_duration_seconds, 0.001)
	)
	_set_muzzle_heat(progress, target_direction)

	if windup_time_left > 0.0:
		return
	if not _has_ranged_combat_line(
		attack_target,
		WORLD_COLLISION_MASK,
		true
	):
		_cancel_attack()
		return

	_start_burst(target_direction)


func _start_burst(shoot_direction: Vector2) -> void:
	var capoo_config := config as CapooConfig
	if capoo_config == null:
		_cancel_attack()
		return

	combat_state = CombatState.BURST
	burst_shot_direction = shoot_direction.normalized() if shoot_direction != Vector2.ZERO else Vector2.RIGHT
	burst_shots_fired = 0
	burst_fire_time_left = 0.0
	burst_audio_step = 0
	attack_cooldown_left = maxf(
		capoo_config.attack_interval - committed_attack_phase_offset_seconds,
		0.01
	)
	_clear_committed_attack_timing()
	_update_facing(burst_shot_direction)
	_play_config_animation(capoo_config.attack_animation_name)
	_set_muzzle_heat(1.0, burst_shot_direction)
	_broadcast_enemy_action(&"burst", burst_shot_direction)


func _update_burst(delta: float) -> void:
	var capoo_config := config as CapooConfig
	if capoo_config == null:
		_cancel_attack()
		return

	velocity = Vector2.ZERO
	_update_facing(burst_shot_direction)
	_set_muzzle_heat(1.0, burst_shot_direction)
	burst_fire_time_left = maxf(burst_fire_time_left - delta, 0.0)

	while burst_fire_time_left <= 0.0 and burst_shots_fired < capoo_config.burst_count:
		_fire_locked_bullet()
		burst_shots_fired += 1
		burst_fire_time_left += maxf(capoo_config.burst_fire_interval, 0.01)

	if burst_shots_fired >= capoo_config.burst_count:
		_finish_burst()


func _fire_locked_bullet() -> bool:
	var capoo_config := config as CapooConfig
	if capoo_config == null or capoo_config.projectile_scene == null:
		return false
	if (
		combat_runtime == null
		or not is_instance_valid(combat_runtime)
		or gameplay_gateway == null
		or not is_instance_valid(gameplay_gateway)
	):
		return false
	# Client enemies only replay the action. Their legacy projectile proxy is
	# created by MpProjectileCoordinator from the Host's existing 12-field RPC.
	if combat_runtime.runtime_mode == CombatRuntimeBase.RuntimeMode.CLIENT_VIEW:
		return false

	var fired := false
	match CapooAK47.projectile_backend:
		ProjectileBackend.LEGACY:
			fired = _fire_legacy_projectile(capoo_config, false)
		ProjectileBackend.SHADOW:
			fired = _fire_legacy_projectile(capoo_config, true)
		ProjectileBackend.DATA:
			fired = _fire_data_projectile(capoo_config)
	if not fired:
		return false

	# Keep the authored RNG and audio cadence after successful registration in
	# every backend. Backend migration therefore cannot perturb later spread or
	# pitch draws in the burst.
	if burst_audio_step % 2 == 0:
		attack_audio.pitch_scale = random_generator.randf_range(0.98, 1.03)
		ENEMY_ATTACK_AUDIO_LIMITER.play_rapid_fire(attack_audio)
	burst_audio_step += 1
	return true


func _fire_legacy_projectile(
	capoo_config: CapooConfig,
	register_shadow: bool
) -> bool:
	var rapid_fire_service: RapidFireSimulationService = null
	if register_shadow:
		rapid_fire_service = _get_rapid_fire_simulation_service()
	var spawn_parent: Node = combat_runtime
	var projectile: CapooAK47Bullet = null
	var uses_registered_pool := combat_runtime.has_session_object_pool_scene(
		capoo_config.projectile_scene
	)
	if uses_registered_pool:
		projectile = combat_runtime.acquire_session_object(
			capoo_config.projectile_scene,
			false
		) as CapooAK47Bullet
	else:
		projectile = capoo_config.projectile_scene.instantiate() as CapooAK47Bullet
	if projectile == null:
		push_warning("AK 猫猫虫子弹场景必须实例化 CapooAK47Bullet。")
		return false

	var outgoing_damage := get_effective_attack_damage(
		capoo_config.attack_damage
	)
	projectile.bind_gameplay_context(combat_runtime, gameplay_gateway)
	projectile.top_level = true
	if projectile.get_parent() == null:
		spawn_parent.add_child(projectile)
	elif projectile.get_parent() != spawn_parent:
		projectile.reparent(spawn_parent)
	projectile.setup(
		burst_shot_direction,
		outgoing_damage,
		capoo_config.projectile_speed,
		capoo_config.projectile_lifetime,
		pathfinder as GridPathfinder,
		projectile_motion_system
	)
	projectile.global_position = global_position + burst_shot_direction * capoo_config.projectile_spawn_distance
	projectile.reset_physics_interpolation()
	gameplay_gateway.register_local_projectile(
		projectile,
		&"capoo_ak47_bullet",
		0,
		projectile.global_position,
		burst_shot_direction,
		outgoing_damage,
		capoo_config.projectile_speed,
		capoo_config.projectile_lifetime
	)
	if register_shadow and rapid_fire_service != null:
		var shadow_projectile_id := projectile.projectile_id
		var shadow_phase_identity := (
			shadow_projectile_id
			if shadow_projectile_id > 0
			else int(projectile.get_instance_id())
		)
		var shadow_handle := rapid_fire_service.register_projectile(
			RapidFireSimulationService.Mode.SHADOW,
			RapidFireSimulationService.Profile.AK,
			projectile.global_position,
			burst_shot_direction,
			capoo_config.projectile_speed,
			capoo_config.projectile_lifetime,
			outgoing_damage,
			_get_stable_source_enemy_id(),
			shadow_projectile_id,
			CapooAK47Bullet.WORLD_COLLISION_CHECK_INTERVAL_FRAMES,
			posmod(
				shadow_phase_identity,
				CapooAK47Bullet.WORLD_COLLISION_CHECK_INTERVAL_FRAMES
			)
		)
		if (
			shadow_handle <= RapidFireSimulationService.INVALID_HANDLE
			or not projectile.bind_shadow_simulation(
				rapid_fire_service,
				shadow_handle
			)
		):
			if rapid_fire_service.is_handle_live(shadow_handle):
				rapid_fire_service.release_projectile(shadow_handle)
			shadow_registration_failures += 1
	elif register_shadow:
		shadow_registration_failures += 1
	return true


func _fire_data_projectile(capoo_config: CapooConfig) -> bool:
	var rapid_fire_service := _get_rapid_fire_simulation_service()
	if rapid_fire_service == null:
		return false

	var safe_direction := (
		burst_shot_direction.normalized()
		if burst_shot_direction != Vector2.ZERO
		else Vector2.RIGHT
	)
	var spawn_position := (
		global_position
		+ safe_direction * capoo_config.projectile_spawn_distance
	)
	var outgoing_damage := get_effective_attack_damage(
		capoo_config.attack_damage
	)
	var phase_identity := _next_local_data_phase_identity()
	var handle := rapid_fire_service.register_projectile(
		RapidFireSimulationService.Mode.DATA,
		RapidFireSimulationService.Profile.AK,
		spawn_position,
		safe_direction,
		capoo_config.projectile_speed,
		capoo_config.projectile_lifetime,
		outgoing_damage,
		_get_stable_source_enemy_id(),
		0,
		CapooAK47Bullet.WORLD_COLLISION_CHECK_INTERVAL_FRAMES,
		posmod(
			phase_identity,
			CapooAK47Bullet.WORLD_COLLISION_CHECK_INTERVAL_FRAMES
		)
	)
	if handle <= RapidFireSimulationService.INVALID_HANDLE:
		return false

	var projectile_id := 0
	if (
		combat_runtime.runtime_mode
		== CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY
	):
		projectile_id = gameplay_gateway.register_local_data_projectile(
			rapid_fire_service,
			handle,
			&"capoo_ak47_bullet",
			0,
			spawn_position,
			safe_direction,
			outgoing_damage,
			capoo_config.projectile_speed,
			capoo_config.projectile_lifetime
		)
		# Identity assignment and network record creation are one operation in
		# the gateway. Failure releases the inert handle and never falls back to
		# an Area2D authority backend.
		if projectile_id <= 0:
			rapid_fire_service.release_projectile(handle)
			return false

	return true


func _get_rapid_fire_simulation_service() -> RapidFireSimulationService:
	var combat_services := combat_runtime.get_enemy_combat_services()
	if combat_services == null:
		return null
	return combat_services.get_rapid_fire_simulation_service()


func _get_stable_source_enemy_id() -> int:
	var network_enemy_id := int(get_meta(&"net_id", 0))
	if network_enemy_id > 0:
		return network_enemy_id
	return int(get_instance_id())


func _next_local_data_phase_identity() -> int:
	local_data_projectile_sequence += 1
	# Singleplayer previously derived the two-tick world-query phase from the
	# projectile Node instance id. DATA has no Node, so a stable per-enemy
	# monotonic identity preserves the same alternating cohort distribution.
	return int(get_instance_id()) + local_data_projectile_sequence


func _finish_burst() -> void:
	combat_state = CombatState.CHASE
	attack_target = null
	burst_shots_fired = 0
	burst_fire_time_left = 0.0
	burst_audio_step = 0
	_set_muzzle_heat(0.0, burst_shot_direction)
	var capoo_config := config as CapooConfig
	if capoo_config != null:
		_play_config_animation(capoo_config.move_animation_name)


func _cancel_attack() -> void:
	combat_state = CombatState.CHASE
	attack_target = null
	_clear_committed_attack_timing()
	burst_shots_fired = 0
	burst_fire_time_left = 0.0
	burst_audio_step = 0
	_set_muzzle_heat(0.0, burst_shot_direction)
	_reset_ranged_attack_position_state()


func _clear_committed_attack_timing() -> void:
	windup_time_left = 0.0
	committed_attack_phase_offset_seconds = 0.0
	committed_windup_duration_seconds = 0.0


func play_multiplayer_enemy_action(action_name: StringName, direction: Vector2, action_id: int) -> void:
	if action_id <= latest_proxy_action_id:
		return
	latest_proxy_action_id = action_id
	var safe_direction := direction.normalized() if direction != Vector2.ZERO else Vector2.RIGHT
	var capoo_config := config as CapooConfig
	if action_name == &"windup":
		if capoo_config != null:
			_play_multiplayer_proxy_action_animation(
				capoo_config.windup_animation_name,
				capoo_config.attack_windup + 0.15
			)
			_play_proxy_muzzle_heat(safe_direction, capoo_config.attack_windup, action_id)
		_update_facing(safe_direction)
	elif action_name == &"burst":
		if capoo_config != null:
			_play_multiplayer_proxy_action_animation(
				capoo_config.attack_animation_name,
				0.28
			)
		_update_facing(safe_direction)
		_set_muzzle_heat(1.0, safe_direction)
		var burst_action_id := action_id
		var tween := create_tween()
		tween.tween_method(
			func(progress: float) -> void:
				if burst_action_id != latest_proxy_action_id:
					return
				_set_muzzle_heat(progress, safe_direction),
			1.0,
			0.0,
			0.22
		)


func _play_proxy_muzzle_heat(direction: Vector2, duration: float, action_id: int) -> void:
	_set_muzzle_heat(0.12, direction)
	var tween := create_tween()
	tween.tween_method(
		func(progress: float) -> void:
			if action_id != latest_proxy_action_id:
				return
			_set_muzzle_heat(progress, direction),
		0.12,
		1.0,
		maxf(duration, 0.01)
	)


func _has_clear_world_line_to_target() -> bool:
	var resolved_target := _get_preferred_ranged_combat_target()
	if resolved_target == null:
		return false

	return _has_throttled_world_line_of_sight(
		resolved_target,
		WORLD_COLLISION_MASK
	)


func _uses_inherited_touch_damage() -> bool:
	return false


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


func _set_muzzle_heat(progress: float, direction: Vector2) -> void:
	var clamped_progress := clampf(progress, 0.0, 1.0)
	muzzle_heat.visible = clamped_progress > 0.0
	if not muzzle_heat.visible:
		return

	var safe_direction := direction.normalized() if direction != Vector2.ZERO else Vector2.RIGHT
	muzzle_heat.position = safe_direction * 12.0
	muzzle_heat.rotation = safe_direction.angle()
	muzzle_heat.scale = Vector2.ONE * lerpf(0.65, 1.35, clamped_progress)
	muzzle_heat.color = Color(1.0, lerpf(0.36, 0.82, clamped_progress), 0.12, lerpf(0.18, 0.72, clamped_progress))
