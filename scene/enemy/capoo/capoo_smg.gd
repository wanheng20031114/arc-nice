extends "res://scene/enemy/capoo_ranged_enemy.gd"
class_name CapooSMG

const SMGConfig := preload("res://resources/config/enemies/capoo_smg_config.gd")
const ENEMY_ATTACK_AUDIO_LIMITER := preload(
	"res://scene/combat/audio/enemy_attack_audio_limiter.gd"
)
const HITSCAN_COLLISION_MASK := 1 | 2 | 512

static var short_range_targeting_enabled := true
static var hitscan_attack_enabled := true
static var allocation_free_proxy_visuals_enabled := true

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
var proxy_visual_tween_action_count := 0
var proxy_visual_token := 0
var cached_combat_target: Node2D = null
var combat_target_cache_initialized := false
var combat_target_refresh_count := 0
var combat_target_last_refresh_physics_frame := -1
var immediate_hitscan_resolver: ImmediateHitscanResolver = null


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


func _physics_process(delta: float) -> void:
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
	proxy_visual_tween_action_count = 0
	proxy_visual_token = 0
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
	proxy_visual_token += 1
	proxy_muzzle_flash_time_left = 0.0
	proxy_action_restore_time_left = 0.0
	proxy_action_restore_animation_name = &""
	_set_muzzle_flash(0.0, last_move_direction)
	super.play_multiplayer_death_sequence()


func set_multiplayer_proxy_visual_active(active: bool) -> void:
	super.set_multiplayer_proxy_visual_active(active)
	if active or not is_multiplayer_proxy:
		return
	proxy_visual_token += 1
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
	if (
		not CapooSMG.hitscan_attack_enabled
		and smg_config_cache.projectile_scene == null
	):
		return false
	if attack_target == null:
		attack_target = _get_cached_combat_target()
		if attack_target == null:
			return false

	var aim_direction := base_direction
	var contact_target := get_contact_combat_target()
	if (
		CapooSMG.short_range_targeting_enabled
		or attack_target == contact_target
	):
		var target_offset := attack_target.global_position - global_position
		if target_offset.length_squared() > attack_range_squared:
			return false
		aim_direction = target_offset.normalized()
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
	if CapooSMG.hitscan_attack_enabled:
		return _fire_hitscan(shoot_direction)
	if smg_config_cache.projectile_scene == null:
		return false
	if (
		combat_runtime == null
		or not is_instance_valid(combat_runtime)
		or gameplay_gateway == null
		or not is_instance_valid(gameplay_gateway)
	):
		return false
	var spawn_parent: Node = combat_runtime
	var projectile: CapooAK47Bullet = null
	var uses_registered_pool := combat_runtime.has_session_object_pool_scene(
		smg_config_cache.projectile_scene
	)
	if uses_registered_pool:
		projectile = combat_runtime.acquire_session_object(
			smg_config_cache.projectile_scene,
			false
		) as CapooAK47Bullet
	else:
		projectile = smg_config_cache.projectile_scene.instantiate() as CapooAK47Bullet
	if projectile == null:
		push_warning("SMG Capoo projectile scene must instantiate CapooAK47Bullet.")
		return false
	var outgoing_damage := get_effective_attack_damage(
		smg_config_cache.attack_damage
	)
	projectile.bind_gameplay_context(combat_runtime, gameplay_gateway)
	projectile.top_level = true
	if projectile.get_parent() == null:
		spawn_parent.add_child(projectile)
	elif projectile.get_parent() != spawn_parent:
		projectile.reparent(spawn_parent)
	projectile.setup(
		shoot_direction,
		outgoing_damage,
		smg_config_cache.projectile_speed,
		smg_config_cache.projectile_lifetime,
		pathfinder as GridPathfinder,
		projectile_motion_system
	)
	projectile.global_position = (
		global_position
		+ shoot_direction * smg_config_cache.projectile_spawn_distance
	)
	projectile.reset_physics_interpolation()
	gameplay_gateway.register_local_projectile(
		projectile,
		&"capoo_smg_bullet",
		0,
		projectile.global_position,
		shoot_direction,
		outgoing_damage,
		smg_config_cache.projectile_speed,
		smg_config_cache.projectile_lifetime
	)
	return true


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
	immediate_hitscan_resolver.resolve_immediate_hitscan(
		global_position,
		global_position + safe_direction * travel_distance,
		HITSCAN_COLLISION_MASK,
		outgoing_damage,
		source_enemy_id,
		source_projectile_id,
		&"capoo_smg_hitscan",
		EnemyConfig.DamageType.PHYSICAL
	)
	return true


func _get_cached_combat_target() -> Node2D:
	var physics_frame := Engine.get_physics_frames()
	var refresh_due := (
		not combat_target_cache_initialized
		or (
			physics_frame != combat_target_last_refresh_physics_frame
			and _is_combat_sense_refresh_due()
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
	proxy_visual_token += 1
	var safe_direction := direction.normalized() if direction != Vector2.ZERO else Vector2.RIGHT
	var smg_config := config as SMGConfig
	_update_facing(safe_direction)
	_set_muzzle_flash(1.0, safe_direction)
	if CapooSMG.allocation_free_proxy_visuals_enabled:
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
		return

	if smg_config != null:
		_play_multiplayer_proxy_action_animation(smg_config.attack_animation_name, 0.14)
	proxy_visual_tween_action_count += 1
	var fire_visual_token := proxy_visual_token
	var tween := create_tween()
	tween.tween_method(
		func(progress: float) -> void:
			if (
				fire_visual_token != proxy_visual_token
				or not multiplayer_proxy_visual_active
			):
				return
			_set_muzzle_flash(progress, safe_direction),
		1.0,
		0.0,
		0.08
	)


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
