extends YuanshiInsect
class_name YuanshiInsectFireRanged

const WORLD_COLLISION_MASK := 1
const FireConfig := preload("res://resources/config/enemies/yuanshi_insect_fire_ranged_config.gd")
const ENEMY_ATTACK_AUDIO_LIMITER := preload(
	"res://scene/enemy_attack_audio_limiter.gd"
)

enum CombatState {
	CHASE,
	ATTACK,
}

@onready var attack_audio: AudioStreamPlayer2D = $AttackAudio

var combat_state: CombatState = CombatState.CHASE
var attack_cooldown_left: float = 0.0
var attack_has_fired: bool = false
var action_sequence: int = 0
var latest_proxy_action_id: int = 0


func _ready() -> void:
	super._ready()
	animated_sprite.animation_finished.connect(_on_attack_animation_finished)
	animated_sprite.frame_changed.connect(_on_attack_animation_frame_changed)


func can_target_water_plant_objectives() -> bool:
	return true


func _physics_process(delta: float) -> void:
	_update_attack_cooldown(delta)

	if is_dead:
		velocity = Vector2.ZERO
		return
	if combat_state == CombatState.ATTACK and not has_attackable_objective():
		_finish_ranged_attack()

	if not has_attackable_objective():
		super._physics_process(delta)
		return

	if combat_state == CombatState.ATTACK:
		_update_touch_damage(delta)
		velocity = Vector2.ZERO
		return

	if _try_start_ranged_attack():
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
	var attack_target := get_attackable_objective()
	if attack_target == null:
		return false
	if fire_config.projectile_scene == null:
		return false
	if not _has_scene_animation(fire_config.attack_animation_name):
		return false
	if not is_attackable_objective_in_range(fire_config.attack_range):
		return false
	if not _has_clear_world_line_to_target():
		return false

	combat_state = CombatState.ATTACK
	attack_has_fired = false
	attack_cooldown_left = maxf(fire_config.attack_interval, 0.01)
	_clear_navigation_path()
	var attack_direction := global_position.direction_to(attack_target.global_position)
	_update_facing(attack_direction)
	_play_scene_animation(fire_config.attack_animation_name)
	_broadcast_enemy_action(&"attack", attack_direction)
	return true


func _has_clear_world_line_to_target() -> bool:
	var attack_target := get_attackable_objective()
	if attack_target == null:
		return false

	return _has_throttled_world_line_of_sight(attack_target, WORLD_COLLISION_MASK)


func _try_fire_ranged_projectile() -> bool:
	var fire_config := config as FireConfig
	if is_dead or combat_state != CombatState.ATTACK or fire_config == null:
		return false
	if fire_config.projectile_scene == null:
		return false
	var attack_target := get_attackable_objective()
	if attack_target == null:
		return false
	if not _has_clear_world_line_to_target():
		return false

	var shoot_direction := global_position.direction_to(attack_target.global_position)
	if shoot_direction == Vector2.ZERO:
		return false

	var spawn_parent := get_tree().current_scene
	if spawn_parent == null:
		return false
	var projectile: YuanshiInsectFireProjectile = null
	if (
		spawn_parent.has_method("has_session_object_pool_scene")
		and bool(
			spawn_parent.call(
				"has_session_object_pool_scene",
				fire_config.projectile_scene
			)
		)
	):
		projectile = spawn_parent.call(
			"acquire_session_object",
			fire_config.projectile_scene,
			false
		) as YuanshiInsectFireProjectile
	else:
		projectile = fire_config.projectile_scene.instantiate() as YuanshiInsectFireProjectile
	if projectile == null:
		push_warning("Fire projectile scene must instantiate YuanshiInsectFireProjectile.")
		return false

	projectile.top_level = true
	projectile.setup(
		shoot_direction,
		fire_config.attack_damage,
		fire_config.projectile_speed,
		fire_config.projectile_lifetime
	)
	if projectile.get_parent() == null:
		spawn_parent.add_child(projectile)
	projectile.global_position = (
		global_position + shoot_direction * fire_config.projectile_spawn_distance
	)
	projectile.reset_physics_interpolation()
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
	ENEMY_ATTACK_AUDIO_LIMITER.play_heavy_attack(attack_audio)
	return true


func _finish_ranged_attack() -> void:
	combat_state = CombatState.CHASE
	attack_has_fired = false
	var fire_config := config as FireConfig
	if fire_config == null:
		return
	_play_scene_animation(fire_config.move_animation_name)


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


func play_multiplayer_enemy_action(action_name: StringName, direction: Vector2, action_id: int) -> void:
	if action_id <= latest_proxy_action_id:
		return
	latest_proxy_action_id = action_id
	if action_name != &"attack":
		return
	var fire_config := config as FireConfig
	if fire_config == null:
		return
	var safe_direction := direction.normalized() if direction != Vector2.ZERO else Vector2.RIGHT
	_update_facing(safe_direction)
	_play_multiplayer_proxy_action_animation(
		fire_config.attack_animation_name,
		_get_scene_animation_duration(fire_config.attack_animation_name) + 0.05
	)


func _broadcast_enemy_action(action_name: StringName, direction: Vector2) -> void:
	action_sequence += 1
	var current_scene := get_tree().current_scene
	if current_scene != null and current_scene.has_method("broadcast_enemy_action"):
		current_scene.call(
			"broadcast_enemy_action",
			int(get_meta("net_id", 0)),
			action_name,
			direction,
			global_position,
			action_sequence
		)
