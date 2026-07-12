extends "res://scene/enemy/capoo_ranged_enemy.gd"
class_name CapooSMG

const SMGConfig := preload("res://resources/config/enemies/capoo_smg_config.gd")

@onready var muzzle_flash: Polygon2D = $MuzzleFlash
@onready var attack_audio: AudioStreamPlayer2D = $AttackAudio

var fire_time_left: float = 0.0
var last_move_direction := Vector2.RIGHT
var muzzle_flash_time_left: float = 0.0
var latest_proxy_action_id: int = 0


func _ready() -> void:
	super._ready()
	_set_muzzle_flash(0.0, Vector2.RIGHT)


func _physics_process(delta: float) -> void:
	if is_dead:
		velocity = Vector2.ZERO
		return

	_update_touch_damage(delta)
	fire_time_left = maxf(fire_time_left - delta, 0.0)
	muzzle_flash_time_left = maxf(muzzle_flash_time_left - delta, 0.0)
	_set_muzzle_flash(muzzle_flash_time_left / 0.05, last_move_direction)

	if not is_instance_valid(objective_target):
		velocity = Vector2.ZERO
		_move_until_player_contact()
		return
	if _has_player_contact():
		velocity = Vector2.ZERO
		if is_objective_targeting_player():
			var contact_aim_direction := global_position.direction_to(target_player.global_position)
			if contact_aim_direction != Vector2.ZERO:
				last_move_direction = contact_aim_direction
			_update_facing(contact_aim_direction)
			_try_fire_scatter(last_move_direction)
		return

	var move_direction := _get_navigation_move_direction(delta)
	if move_direction != Vector2.ZERO:
		last_move_direction = move_direction.normalized()
	_update_facing(move_direction)
	velocity = move_direction * _get_move_speed()
	_move_until_player_contact()
	if is_objective_targeting_player():
		_try_fire_scatter(last_move_direction if move_direction != Vector2.ZERO else Vector2.ZERO)


func _apply_config() -> void:
	super._apply_config()
	fire_time_left = 0.0
	muzzle_flash_time_left = 0.0
	var smg_config := config as SMGConfig
	if smg_config != null:
		attack_audio.stream = smg_config.attack_audio_stream


func _die() -> void:
	_set_muzzle_flash(0.0, last_move_direction)
	super._die()


func play_multiplayer_death_sequence() -> void:
	latest_proxy_action_id += 1
	_set_muzzle_flash(0.0, last_move_direction)
	super.play_multiplayer_death_sequence()


func _try_fire_scatter(base_direction: Vector2) -> bool:
	if not is_objective_targeting_player():
		return false
	var smg_config := config as SMGConfig
	if smg_config == null or smg_config.projectile_scene == null:
		return false
	if fire_time_left > 0.0:
		return false
	if base_direction == Vector2.ZERO:
		return false

	var spread := deg_to_rad(smg_config.spread_angle_degrees)
	var shot_direction := base_direction.rotated(random_generator.randf_range(-spread, spread)).normalized()
	if not _fire_bullet(shot_direction):
		return false
	fire_time_left = maxf(smg_config.fire_interval, 0.01)
	muzzle_flash_time_left = 0.05
	_set_muzzle_flash(1.0, shot_direction)
	_play_config_animation(smg_config.attack_animation_name)
	_broadcast_enemy_action(&"fire", shot_direction)
	if smg_config.attack_audio_stream != null and random_generator.randi_range(0, 1) == 0:
		attack_audio.pitch_scale = random_generator.randf_range(0.98, 1.04)
		attack_audio.play()
	return true


func _fire_bullet(shoot_direction: Vector2) -> bool:
	var smg_config := config as SMGConfig
	if smg_config == null or smg_config.projectile_scene == null:
		return false
	var spawn_parent := get_tree().current_scene
	if spawn_parent == null:
		return false
	var projectile: CapooAK47Bullet = null
	var uses_registered_pool := (
		spawn_parent.has_method("has_session_object_pool_scene")
		and bool(
			spawn_parent.call(
				"has_session_object_pool_scene",
				smg_config.projectile_scene
			)
		)
	)
	if uses_registered_pool:
		projectile = spawn_parent.call(
			"acquire_session_object",
			smg_config.projectile_scene,
			false
		) as CapooAK47Bullet
	else:
		projectile = smg_config.projectile_scene.instantiate() as CapooAK47Bullet
	if projectile == null:
		push_warning("SMG Capoo projectile scene must instantiate CapooAK47Bullet.")
		return false
	projectile.top_level = true
	projectile.setup(
		shoot_direction,
		smg_config.attack_damage,
		smg_config.projectile_speed,
		smg_config.projectile_lifetime
	)
	if projectile.get_parent() == null:
		spawn_parent.add_child(projectile)
	projectile.global_position = global_position + shoot_direction * smg_config.projectile_spawn_distance
	projectile.reset_physics_interpolation()
	if spawn_parent.has_method("register_local_projectile"):
		spawn_parent.call(
			"register_local_projectile",
			projectile,
			&"capoo_smg_bullet",
			0,
			projectile.global_position,
			shoot_direction,
			smg_config.attack_damage,
			smg_config.projectile_speed,
			smg_config.projectile_lifetime
		)
	return true


func play_multiplayer_enemy_action(action_name: StringName, direction: Vector2, action_id: int) -> void:
	if action_id <= latest_proxy_action_id:
		return
	latest_proxy_action_id = action_id
	if action_name != &"fire":
		return
	var safe_direction := direction.normalized() if direction != Vector2.ZERO else Vector2.RIGHT
	var smg_config := config as SMGConfig
	if smg_config != null:
		_play_multiplayer_proxy_action_animation(smg_config.attack_animation_name, 0.14)
	_update_facing(safe_direction)
	_set_muzzle_flash(1.0, safe_direction)
	var fire_action_id := action_id
	var tween := create_tween()
	tween.tween_method(
		func(progress: float) -> void:
			if fire_action_id != latest_proxy_action_id:
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
