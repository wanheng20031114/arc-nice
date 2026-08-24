extends "res://scene/enemy/layered_ranged_enemy.gd"
class_name CapooSMG

const SMGConfig := preload("res://resources/config/enemies/capoo_smg_config.gd")
const ENEMY_ATTACK_AUDIO_LIMITER := preload(
	"res://scene/combat/audio/enemy_attack_audio_limiter.gd"
)
const HITSCAN_COLLISION_MASK := 1 | 2 | 4 | 512
const TARGET_REFRESH_HZ := 20.0
const LAYERED_FAMILY_SCRIPT_PATH := "res://scene/enemy/capoo/capoo_smg.gd"

@onready var muzzle_flash: Polygon2D = $MuzzleFlash
@onready var muzzle_halo: Sprite2D = $MuzzleFlash/ProjectileHalo
@onready var attack_audio: AudioStreamPlayer2D = $AttackAudio

var fire_time_left: float = 0.0
var last_move_direction := Vector2.RIGHT
var muzzle_flash_time_left: float = 0.0
var latest_proxy_action_id: int = 0
var smg_config_cache: SMGConfig = null
var attack_range_squared: float = 0.0
var hitscan_shots_fired: int = 0
var last_shot_direction := Vector2.RIGHT
var proxy_muzzle_flash_time_left := 0.0
var proxy_action_restore_time_left := 0.0
var proxy_action_restore_animation_name: StringName = &""
var proxy_action_restore_token_snapshot := 0
var proxy_visual_direction := Vector2.RIGHT
var proxy_visual_timer_action_count := 0
var cached_combat_target: Node2D = null
var combat_target_cache_initialized := false
var combat_target_refresh_count := 0
var combat_target_last_refresh_physics_frame := -1
var immediate_hitscan_resolver: ImmediateHitscanResolver = null
var layered_smg_post_motion_fire_pending := false
var layered_smg_pending_target: Node2D = null
var layered_smg_pending_base_direction := Vector2.ZERO


func _ready() -> void:
	super._ready()
	_set_muzzle_flash(0.0, Vector2.RIGHT)
	_refresh_immediate_hitscan_resolver()


func bind_combat_runtime(runtime_instance: CombatRuntimeBase) -> void:
	super.bind_combat_runtime(runtime_instance)
	_refresh_immediate_hitscan_resolver()


func set_target_player(player: Player) -> void:
	super.set_target_player(player)
	_invalidate_combat_target_cache()


func set_objective_target(target: Node2D) -> void:
	super.set_objective_target(target)
	_invalidate_combat_target_cache()


func supports_centralized_authoritative_simulation() -> bool:
	return true


func _supports_layered_ranged_authoritative_simulation() -> bool:
	return _is_exact_layered_smg_family()


func _supports_layered_ranged_contact_authority() -> bool:
	return _is_exact_layered_smg_family()


func _supports_layered_ranged_indexed_touch_authority() -> bool:
	# Both production scenes author one CapsuleShape2D for body and touch. SMG
	# adds no inherited touch hit or secondary attack Area, so indexed authority
	# replaces only Player/Plant overlap bookkeeping while hitscan/projectile
	# commits remain in the weapon state machine.
	return _is_exact_layered_smg_family()


func _is_exact_layered_smg_family() -> bool:
	var implementation := get_script() as Script
	return (
		implementation != null
		and implementation.resource_path == LAYERED_FAMILY_SCRIPT_PATH
	)


func get_layered_area_decision_interval_frames() -> int:
	# The authored runner updates its short-range firing opportunity after every
	# physics movement. Keep this first migration at exact 60 Hz; the navigation
	# primitive still reuses its own cached path/direction between refreshes.
	return 1


func _prepare_layered_ranged_authoritative_simulation() -> void:
	layered_smg_post_motion_fire_pending = false
	layered_smg_pending_target = null
	layered_smg_pending_base_direction = Vector2.ZERO


func _layered_area_touch_damage_precedes_family_event() -> bool:
	# Authored order is touch, fire cooldown, muzzle presentation, then decision.
	return true


func _advance_layered_ranged_event_phase(delta: float) -> void:
	fire_time_left = maxf(fire_time_left - delta, 0.0)
	if muzzle_flash_time_left > 0.0:
		muzzle_flash_time_left = maxf(muzzle_flash_time_left - delta, 0.0)
		_set_muzzle_flash(muzzle_flash_time_left / 0.05, last_move_direction)
	elif muzzle_flash.visible:
		_set_muzzle_flash(0.0, last_move_direction)


func _can_sleep_layered_ranged_event_phase() -> bool:
	# These are authored per-tick public/presentation fields. Sleep only after
	# both countdowns have reached the exact legacy edge and the flash is hidden.
	return (
		fire_time_left <= 0.0
		and muzzle_flash_time_left <= 0.0
		and not muzzle_flash.visible
	)


func _try_consume_layered_ranged_decision_phase(_delta: float) -> bool:
	layered_smg_post_motion_fire_pending = false
	layered_smg_pending_target = null
	layered_smg_pending_base_direction = Vector2.ZERO
	var combat_target := _get_cached_combat_target()
	if _has_player_contact():
		velocity = Vector2.ZERO
		if fire_time_left <= 0.0 and combat_target != null:
			_commit_layered_smg_fire(last_move_direction, combat_target)
		return true
	if not is_instance_valid(objective_target):
		velocity = Vector2.ZERO
		return false
	# Legacy commits this attempt after `_move_until_player_contact()`. Defer it
	# until the cached motion plan has either been submitted or proven empty.
	layered_smg_post_motion_fire_pending = true
	layered_smg_pending_target = combat_target
	return false


func _simulate_layered_area_decision_body(delta: float) -> bool:
	var completed := super._simulate_layered_area_decision_body(delta)
	if not completed or not layered_smg_post_motion_fire_pending:
		return completed
	var move_direction := layered_area_planned_move_direction
	if move_direction != Vector2.ZERO:
		last_move_direction = move_direction.normalized()
	layered_smg_pending_base_direction = (
		last_move_direction if move_direction != Vector2.ZERO else Vector2.ZERO
	)
	if not should_execute_layered_area_motion_phase():
		# The authored runner assigns `move_direction * speed` before every
		# attempt. When the plan is zero (or effective speed is zero), clear a
		# velocity left by the previous tick even though no motion job is queued.
		velocity = Vector2.ZERO
		_commit_pending_layered_smg_fire()
	return completed


func _simulate_layered_area_motion_body(delta: float) -> bool:
	var completed := super._simulate_layered_area_motion_body(delta)
	if completed:
		_commit_pending_layered_smg_fire()
	return completed


func _layered_ranged_attack_state_allows_motion() -> bool:
	# SMG has no windup/recovery state; cooldown never blocks authored movement.
	return true


func _commit_pending_layered_smg_fire() -> void:
	if not layered_smg_post_motion_fire_pending:
		return
	var attack_target := layered_smg_pending_target
	var base_direction := layered_smg_pending_base_direction
	layered_smg_post_motion_fire_pending = false
	layered_smg_pending_target = null
	layered_smg_pending_base_direction = Vector2.ZERO
	_commit_layered_smg_fire(base_direction, attack_target)


func _commit_layered_smg_fire(
	base_direction: Vector2,
	attack_target: Node2D
) -> bool:
	var fired := _try_fire_scatter(base_direction, attack_target)
	if fired:
		# A sleeping event lane must resume on the following physics tick so both
		# countdowns reproduce the authored repeated-subtraction sequence.
		request_layered_area_urgent_decision()
	return fired


func _run_authoritative_physics_step(delta: float) -> void:
	if is_dead:
		velocity = Vector2.ZERO
		return

	_update_touch_damage(delta)
	fire_time_left = maxf(fire_time_left - delta, 0.0)
	if muzzle_flash_time_left > 0.0:
		muzzle_flash_time_left = maxf(muzzle_flash_time_left - delta, 0.0)
		_set_muzzle_flash(muzzle_flash_time_left / 0.05, last_move_direction)
	elif muzzle_flash.visible:
		_set_muzzle_flash(0.0, last_move_direction)

	var combat_target := _get_cached_combat_target()
	if _has_player_contact():
		velocity = Vector2.ZERO
		if fire_time_left <= 0.0:
			if combat_target == null:
				return
			_try_fire_scatter(last_move_direction, combat_target)
		return
	if not is_instance_valid(objective_target):
		velocity = Vector2.ZERO
		_move_until_player_contact()
		return

	var move_direction := _get_navigation_move_direction(delta)
	if move_direction != Vector2.ZERO:
		last_move_direction = move_direction.normalized()
	_update_facing(move_direction)
	velocity = move_direction * _get_move_speed()
	_move_until_player_contact()
	_try_fire_scatter(
		last_move_direction if move_direction != Vector2.ZERO else Vector2.ZERO,
		combat_target
	)


func _process(delta: float) -> void:
	if not is_multiplayer_proxy:
		super._process(delta)
		return
	if is_dead:
		set_process(false)
		return

	var needs_next_frame := false
	if proxy_muzzle_flash_time_left > 0.0:
		proxy_muzzle_flash_time_left = maxf(
			proxy_muzzle_flash_time_left - delta,
			0.0
		)
		_set_muzzle_flash(
			proxy_muzzle_flash_time_left / 0.08,
			proxy_visual_direction
		)
		needs_next_frame = proxy_muzzle_flash_time_left > 0.0
	elif muzzle_flash.visible:
		_set_muzzle_flash(0.0, proxy_visual_direction)

	if proxy_action_restore_time_left > 0.0:
		proxy_action_restore_time_left = maxf(
			proxy_action_restore_time_left - delta,
			0.0
		)
		if proxy_action_restore_time_left <= 0.0:
			_restore_multiplayer_proxy_move_animation(
				proxy_action_restore_token_snapshot,
				proxy_action_restore_animation_name
			)
			proxy_action_restore_animation_name = &""
		else:
			needs_next_frame = true
	if not needs_next_frame:
		set_process(false)


func _apply_config() -> void:
	super._apply_config()
	fire_time_left = 0.0
	muzzle_flash_time_left = 0.0
	hitscan_shots_fired = 0
	last_shot_direction = Vector2.RIGHT
	proxy_muzzle_flash_time_left = 0.0
	proxy_action_restore_time_left = 0.0
	proxy_action_restore_animation_name = &""
	proxy_action_restore_token_snapshot = 0
	proxy_visual_direction = Vector2.RIGHT
	proxy_visual_timer_action_count = 0
	cached_combat_target = null
	combat_target_cache_initialized = false
	combat_target_refresh_count = 0
	combat_target_last_refresh_physics_frame = -1
	smg_config_cache = config as SMGConfig
	if smg_config_cache != null:
		attack_audio.stream = smg_config_cache.attack_audio_stream
		attack_range_squared = (
			maxf(smg_config_cache.attack_range, 0.0)
			* maxf(smg_config_cache.attack_range, 0.0)
		)
	else:
		attack_range_squared = 0.0


func _die() -> void:
	_set_muzzle_flash(0.0, last_move_direction)
	super._die()


func play_multiplayer_death_sequence() -> void:
	latest_proxy_action_id += 1
	proxy_muzzle_flash_time_left = 0.0
	proxy_action_restore_time_left = 0.0
	proxy_action_restore_animation_name = &""
	_set_muzzle_flash(0.0, last_move_direction)
	super.play_multiplayer_death_sequence()


func set_multiplayer_proxy_visual_active(active: bool) -> void:
	super.set_multiplayer_proxy_visual_active(active)
	if active or not is_multiplayer_proxy:
		return
	if proxy_action_animation_name_in_use != &"":
		_restore_multiplayer_proxy_move_animation(
			proxy_action_restore_token,
			proxy_action_animation_name_in_use
		)
	proxy_muzzle_flash_time_left = 0.0
	proxy_action_restore_time_left = 0.0
	proxy_action_restore_animation_name = &""
	proxy_action_restore_token_snapshot = 0
	_set_muzzle_flash(0.0, proxy_visual_direction)
	set_process(false)


func _try_fire_scatter(
	base_direction: Vector2,
	attack_target: Node2D = null
) -> bool:
	if fire_time_left > 0.0:
		return false
	if smg_config_cache == null:
		return false
	if attack_target == null:
		attack_target = _get_cached_combat_target()
		if attack_target == null:
			return false

	var target_offset := attack_target.global_position - global_position
	if target_offset.length_squared() > attack_range_squared:
		return false
	var aim_direction := target_offset.normalized()
	if aim_direction == Vector2.ZERO:
		return false

	var spread := deg_to_rad(smg_config_cache.spread_angle_degrees)
	var shot_direction := aim_direction.rotated(
		random_generator.randf_range(-spread, spread)
	).normalized()
	if not _fire_bullet(shot_direction):
		return false
	last_shot_direction = shot_direction
	fire_time_left = maxf(smg_config_cache.fire_interval, 0.01)
	muzzle_flash_time_left = 0.05
	_update_facing(aim_direction)
	_set_muzzle_flash(1.0, shot_direction)
	_play_config_animation(smg_config_cache.attack_animation_name)
	_broadcast_enemy_action(&"fire", shot_direction)
	if (
		smg_config_cache.attack_audio_stream != null
		and random_generator.randi_range(0, 1) == 0
	):
		attack_audio.pitch_scale = random_generator.randf_range(0.98, 1.04)
		ENEMY_ATTACK_AUDIO_LIMITER.play_rapid_fire(attack_audio)
	return true


func _fire_bullet(shoot_direction: Vector2) -> bool:
	if smg_config_cache == null:
		return false
	return _fire_hitscan(shoot_direction)


func _fire_hitscan(shoot_direction: Vector2) -> bool:
	if immediate_hitscan_resolver == null:
		_refresh_immediate_hitscan_resolver()
	if immediate_hitscan_resolver == null:
		return false
	var safe_direction := (
		shoot_direction.normalized()
		if shoot_direction != Vector2.ZERO
		else Vector2.RIGHT
	)
	var travel_distance := maxf(
		smg_config_cache.projectile_spawn_distance
		+ smg_config_cache.projectile_speed * smg_config_cache.projectile_lifetime,
		0.0
	)
	hitscan_shots_fired += 1
	var outgoing_damage := get_effective_attack_damage(
		smg_config_cache.attack_damage
	)
	var source_enemy_id := int(get_meta(&"net_id", 0))
	if source_enemy_id <= 0:
		source_enemy_id = int(get_instance_id())
	var source_projectile_id := _get_multiplayer_damage_source_id(
		action_sequence + 1
	)
	var source_snapshot := create_damage_source_snapshot(
		source_projectile_id,
		&"capoo_smg_hitscan"
	)
	immediate_hitscan_resolver.resolve_immediate_hitscan(
		global_position,
		global_position + safe_direction * travel_distance,
		HITSCAN_COLLISION_MASK,
		outgoing_damage,
		source_enemy_id,
		source_projectile_id,
		&"capoo_smg_hitscan",
		EnemyConfig.DamageType.PHYSICAL,
		source_snapshot,
		self
	)
	return true


func _get_cached_combat_target() -> Node2D:
	var physics_frame := Engine.get_physics_frames()
	var refresh_interval_frames := maxi(
		roundi(float(Engine.physics_ticks_per_second) / TARGET_REFRESH_HZ),
		1
	)
	var refresh_due := (
		not combat_target_cache_initialized
		or (
			physics_frame != combat_target_last_refresh_physics_frame
			and (
				physics_frame + navigation_update_frame_offset
			) % refresh_interval_frames == 0
		)
	)
	if refresh_due:
		cached_combat_target = _get_preferred_ranged_combat_target()
		combat_target_cache_initialized = true
		combat_target_refresh_count += 1
		combat_target_last_refresh_physics_frame = physics_frame
	elif not _is_ranged_combat_target_valid(cached_combat_target):
		cached_combat_target = null
	return cached_combat_target


func _invalidate_combat_target_cache() -> void:
	cached_combat_target = null
	combat_target_cache_initialized = false
	combat_target_last_refresh_physics_frame = -1


func _refresh_immediate_hitscan_resolver() -> void:
	immediate_hitscan_resolver = null
	if combat_runtime == null or not is_instance_valid(combat_runtime):
		return
	var combat_services := combat_runtime.get_enemy_combat_services()
	if combat_services != null:
		immediate_hitscan_resolver = (
			combat_services.get_immediate_hitscan_resolver()
		)


func play_multiplayer_enemy_action(action_name: StringName, direction: Vector2, action_id: int) -> void:
	if not is_multiplayer_proxy or is_dead:
		return
	if action_id <= latest_proxy_action_id:
		return
	latest_proxy_action_id = action_id
	if action_name != &"fire":
		return
	if not multiplayer_proxy_visual_active:
		return
	var safe_direction := direction.normalized() if direction != Vector2.ZERO else Vector2.RIGHT
	var smg_config := config as SMGConfig
	_update_facing(safe_direction)
	_set_muzzle_flash(1.0, safe_direction)
	if smg_config != null:
		_play_multiplayer_proxy_action_animation(
			smg_config.attack_animation_name,
			-1.0
		)
		proxy_action_restore_animation_name = smg_config.attack_animation_name
		proxy_action_restore_token_snapshot = proxy_action_restore_token
	else:
		proxy_action_restore_animation_name = &""
	proxy_action_restore_time_left = 0.14
	proxy_visual_direction = safe_direction
	proxy_muzzle_flash_time_left = 0.08
	proxy_visual_timer_action_count += 1
	set_process(true)


func _set_muzzle_flash(progress: float, direction: Vector2) -> void:
	var clamped_progress := clampf(progress, 0.0, 1.0)
	muzzle_flash.visible = clamped_progress > 0.0
	if not muzzle_flash.visible:
		return
	var safe_direction := direction.normalized() if direction != Vector2.ZERO else Vector2.RIGHT
	muzzle_flash.position = safe_direction * 13.0
	muzzle_flash.rotation = safe_direction.angle()
	muzzle_flash.scale = Vector2.ONE * lerpf(0.65, 1.25, clamped_progress)
	muzzle_flash.color = Color(1.0, 0.55, 0.08, lerpf(0.2, 0.82, clamped_progress))
	var halo_color := muzzle_halo.self_modulate
	halo_color.a = lerpf(0.035, 0.105, clamped_progress)
	muzzle_halo.self_modulate = halo_color
