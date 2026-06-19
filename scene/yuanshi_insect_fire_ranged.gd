extends YuanshiInsect
class_name YuanshiInsectFireRanged

const WORLD_COLLISION_MASK := 1
const FireConfig := preload("res://resources/config/enemies/yuanshi_insect_fire_ranged_config.gd")

enum CombatState {
	CHASE,
	ATTACK,
}

@onready var attack_audio: AudioStreamPlayer2D = $AttackAudio

var combat_state: CombatState = CombatState.CHASE
var attack_cooldown_left: float = 0.0
var attack_has_fired: bool = false


func _ready() -> void:
	super._ready()
	animated_sprite.animation_finished.connect(_on_attack_animation_finished)
	animated_sprite.frame_changed.connect(_on_attack_animation_frame_changed)


func _physics_process(delta: float) -> void:
	_update_attack_cooldown(delta)

	if is_dead or not is_instance_valid(target_player):
		super._physics_process(delta)
		return

	if combat_state == CombatState.ATTACK:
		_update_hurt_blink(delta)
		_update_touch_damage(delta)
		velocity = Vector2.ZERO
		return

	if _try_start_ranged_attack():
		_update_hurt_blink(delta)
		_update_touch_damage(delta)
		velocity = Vector2.ZERO
		return

	super._physics_process(delta)


func _apply_config() -> void:
	super._apply_config()
	combat_state = CombatState.CHASE
	attack_cooldown_left = 0.0
	attack_has_fired = false

	var fire_config := config as FireConfig
	if fire_config != null:
		attack_audio.stream = fire_config.attack_audio_stream


func _die() -> void:
	combat_state = CombatState.CHASE
	attack_has_fired = true
	super._die()


func _update_attack_cooldown(delta: float) -> void:
	if attack_cooldown_left <= 0.0:
		return
	attack_cooldown_left = maxf(attack_cooldown_left - delta, 0.0)


func _try_start_ranged_attack() -> bool:
	var fire_config := config as FireConfig
	if fire_config == null:
		return false
	if attack_cooldown_left > 0.0:
		return false
	if not is_instance_valid(target_player):
		return false
	if fire_config.projectile_scene == null:
		return false
	if fire_config.enemy_frames == null:
		return false
	if not fire_config.enemy_frames.has_animation(fire_config.attack_animation_name):
		return false
	if global_position.distance_to(target_player.global_position) > fire_config.attack_range:
		return false
	if not _has_clear_world_line_to_target():
		return false

	combat_state = CombatState.ATTACK
	attack_has_fired = false
	attack_cooldown_left = maxf(fire_config.attack_interval, 0.01)
	_clear_navigation_path()
	_update_facing(global_position.direction_to(target_player.global_position))
	animated_sprite.play(fire_config.attack_animation_name)
	return true


func _has_clear_world_line_to_target() -> bool:
	if not is_instance_valid(target_player):
		return false

	var query := PhysicsRayQueryParameters2D.create(
		global_position,
		target_player.global_position,
		WORLD_COLLISION_MASK,
		[get_rid()]
	)
	query.collide_with_bodies = true
	query.collide_with_areas = false
	return get_world_2d().direct_space_state.intersect_ray(query).is_empty()


func _try_fire_ranged_projectile() -> bool:
	var fire_config := config as FireConfig
	if is_dead or combat_state != CombatState.ATTACK or fire_config == null:
		return false
	if fire_config.projectile_scene == null:
		return false
	if not is_instance_valid(target_player):
		return false
	if not _has_clear_world_line_to_target():
		return false

	var shoot_direction := global_position.direction_to(target_player.global_position)
	if shoot_direction == Vector2.ZERO:
		return false

	var projectile := fire_config.projectile_scene.instantiate() as YuanshiInsectFireProjectile
	if projectile == null:
		push_warning("Fire projectile scene must instantiate YuanshiInsectFireProjectile.")
		return false

	var spawn_parent := get_tree().current_scene
	if spawn_parent == null:
		projectile.queue_free()
		return false

	projectile.top_level = true
	projectile.setup(
		shoot_direction,
		fire_config.attack_damage,
		fire_config.projectile_speed,
		fire_config.projectile_lifetime
	)
	spawn_parent.add_child(projectile)
	projectile.global_position = (
		global_position + shoot_direction * fire_config.projectile_spawn_distance
	)
	if spawn_parent.has_method("register_local_projectile"):
		spawn_parent.call(
			"register_local_projectile",
			projectile,
			&"yuanshi_fire_projectile",
			0,
			projectile.global_position,
			shoot_direction,
			fire_config.attack_damage,
			fire_config.projectile_speed,
			fire_config.projectile_lifetime
		)
	attack_audio.pitch_scale = random_generator.randf_range(0.94, 1.06)
	attack_audio.play()
	return true


func _finish_ranged_attack() -> void:
	combat_state = CombatState.CHASE
	attack_has_fired = false
	var fire_config := config as FireConfig
	if fire_config == null or fire_config.enemy_frames == null:
		return
	if fire_config.enemy_frames.has_animation(fire_config.move_animation_name):
		animated_sprite.play(fire_config.move_animation_name)


func _on_attack_animation_finished() -> void:
	var fire_config := config as FireConfig
	if is_dead or combat_state != CombatState.ATTACK or fire_config == null:
		return
	if animated_sprite.animation == fire_config.attack_animation_name:
		_finish_ranged_attack()


func _on_attack_animation_frame_changed() -> void:
	var fire_config := config as FireConfig
	if is_dead or combat_state != CombatState.ATTACK or fire_config == null:
		return
	if attack_has_fired:
		return
	if animated_sprite.animation != fire_config.attack_animation_name:
		return
	if animated_sprite.frame != fire_config.attack_fire_frame:
		return

	attack_has_fired = true
	_try_fire_ranged_projectile()
