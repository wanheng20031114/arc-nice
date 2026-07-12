extends "res://scene/enemy/capoo_ranged_enemy.gd"
class_name CapooMage

const MageConfig := preload("res://resources/config/enemies/capoo_mage_config.gd")

enum CombatState {
	CHASE,
	WINDUP,
	FIRE,
}

@onready var spell_glow: Polygon2D = $SpellGlow
@onready var attack_audio: AudioStreamPlayer2D = $AttackAudio

var combat_state: CombatState = CombatState.CHASE
var attack_cooldown_left: float = 0.0
var windup_time_left: float = 0.0
var fire_time_left: float = 0.0
var fire_direction := Vector2.RIGHT
var latest_proxy_action_id: int = 0


func _ready() -> void:
	super._ready()
	_set_spell_glow(0.0, Vector2.RIGHT)


func _physics_process(delta: float) -> void:
	if is_dead:
		velocity = Vector2.ZERO
		return

	_update_touch_damage(delta)
	_update_attack_cooldown(delta)
	if combat_state != CombatState.CHASE and not is_objective_targeting_player():
		_cancel_attack()

	match combat_state:
		CombatState.WINDUP:
			_update_windup(delta)
			return
		CombatState.FIRE:
			_update_fire(delta)
			return

	if not is_instance_valid(objective_target):
		velocity = Vector2.ZERO
		_move_until_player_contact()
		return

	if is_objective_targeting_player() and _try_start_windup():
		return
	if _has_player_contact():
		velocity = Vector2.ZERO
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
	fire_time_left = 0.0
	latest_proxy_action_id = 0
	var mage_config := config as MageConfig
	if mage_config != null:
		attack_audio.stream = mage_config.attack_audio_stream


func _die() -> void:
	combat_state = CombatState.CHASE
	_set_spell_glow(0.0, fire_direction)
	super._die()


func play_multiplayer_death_sequence() -> void:
	latest_proxy_action_id += 1
	_set_spell_glow(0.0, fire_direction)
	super.play_multiplayer_death_sequence()


func _update_attack_cooldown(delta: float) -> void:
	if attack_cooldown_left > 0.0:
		attack_cooldown_left = maxf(attack_cooldown_left - delta, 0.0)


func _try_start_windup() -> bool:
	if not is_objective_targeting_player():
		return false
	var mage_config := config as MageConfig
	if mage_config == null or mage_config.projectile_scene == null:
		return false
	if attack_cooldown_left > 0.0:
		return false
	if not is_instance_valid(target_player):
		return false
	if global_position.distance_to(target_player.global_position) > mage_config.attack_range:
		return false
	if not _has_clear_world_line_to_target():
		return false

	combat_state = CombatState.WINDUP
	windup_time_left = maxf(mage_config.attack_windup, 0.0)
	fire_direction = global_position.direction_to(target_player.global_position)
	if fire_direction == Vector2.ZERO:
		fire_direction = Vector2.RIGHT
	velocity = Vector2.ZERO
	_clear_navigation_path()
	_update_facing(fire_direction)
	_play_config_animation(mage_config.windup_animation_name)
	_set_spell_glow(0.15, fire_direction)
	_broadcast_enemy_action(&"windup", fire_direction)
	return true


func _update_windup(delta: float) -> void:
	var mage_config := config as MageConfig
	if (
		mage_config == null
		or not is_objective_targeting_player()
		or not is_instance_valid(target_player)
	):
		_cancel_attack()
		return

	velocity = Vector2.ZERO
	fire_direction = global_position.direction_to(target_player.global_position)
	if fire_direction == Vector2.ZERO:
		fire_direction = Vector2.RIGHT
	_update_facing(fire_direction)
	windup_time_left = maxf(windup_time_left - delta, 0.0)
	var progress := 1.0 - (windup_time_left / maxf(mage_config.attack_windup, 0.001))
	_set_spell_glow(progress, fire_direction)

	if windup_time_left > 0.0:
		return
	if not _has_clear_world_line_to_target():
		_cancel_attack()
		return

	_start_fire(fire_direction)


func _start_fire(direction: Vector2) -> void:
	var mage_config := config as MageConfig
	if mage_config == null:
		_cancel_attack()
		return

	combat_state = CombatState.FIRE
	fire_time_left = 0.18
	fire_direction = direction.normalized() if direction != Vector2.ZERO else Vector2.RIGHT
	attack_cooldown_left = maxf(mage_config.attack_interval, 0.01)
	velocity = Vector2.ZERO
	_update_facing(fire_direction)
	_play_config_animation(mage_config.attack_animation_name)
	_set_spell_glow(1.0, fire_direction)
	_fire_fireball()
	_broadcast_enemy_action(&"fire", fire_direction)
	if mage_config.attack_audio_stream != null:
		attack_audio.pitch_scale = random_generator.randf_range(0.95, 1.05)
		attack_audio.play()


func _update_fire(delta: float) -> void:
	velocity = Vector2.ZERO
	_update_facing(fire_direction)
	fire_time_left = maxf(fire_time_left - delta, 0.0)
	_set_spell_glow(fire_time_left / 0.18, fire_direction)
	if fire_time_left <= 0.0:
		_finish_fire()


func _fire_fireball() -> bool:
	var mage_config := config as MageConfig
	if mage_config == null or mage_config.projectile_scene == null:
		return false

	var fireball := mage_config.projectile_scene.instantiate() as CapooMageFireball
	if fireball == null:
		push_warning("Mage Capoo projectile scene must instantiate CapooMageFireball.")
		return false

	var spawn_parent := get_tree().current_scene
	if spawn_parent == null:
		fireball.queue_free()
		return false

	fireball.top_level = true
	fireball.setup(
		fire_direction,
		mage_config.attack_damage,
		mage_config.projectile_speed,
		mage_config.projectile_lifetime,
		mage_config.fireball_radius,
		target_player,
		mage_config.fireball_homing_turn_rate
	)
	spawn_parent.add_child(fireball)
	fireball.global_position = global_position + fire_direction * mage_config.projectile_spawn_distance
	if spawn_parent.has_method("register_local_projectile"):
		spawn_parent.call(
			"register_local_projectile",
			fireball,
			&"capoo_mage_fireball",
			0,
			fireball.global_position,
			fire_direction,
			mage_config.attack_damage,
			mage_config.projectile_speed,
			mage_config.projectile_lifetime
		)
	return true


func _finish_fire() -> void:
	combat_state = CombatState.CHASE
	fire_time_left = 0.0
	_set_spell_glow(0.0, fire_direction)
	var mage_config := config as MageConfig
	if mage_config != null:
		_play_config_animation(mage_config.move_animation_name)


func _cancel_attack() -> void:
	combat_state = CombatState.CHASE
	windup_time_left = 0.0
	fire_time_left = 0.0
	_set_spell_glow(0.0, fire_direction)


func play_multiplayer_enemy_action(action_name: StringName, direction: Vector2, action_id: int) -> void:
	if action_id <= latest_proxy_action_id:
		return
	latest_proxy_action_id = action_id
	var safe_direction := direction.normalized() if direction != Vector2.ZERO else Vector2.RIGHT
	var mage_config := config as MageConfig
	if action_name == &"windup":
		if mage_config != null:
			_play_multiplayer_proxy_action_animation(mage_config.windup_animation_name, mage_config.attack_windup + 0.15)
			_play_proxy_spell_glow(safe_direction, mage_config.attack_windup, action_id)
		_update_facing(safe_direction)
	elif action_name == &"fire":
		if mage_config != null:
			_play_multiplayer_proxy_action_animation(mage_config.attack_animation_name, 0.23)
		_update_facing(safe_direction)
		_set_spell_glow(1.0, safe_direction)
		var fire_action_id := action_id
		var tween := create_tween()
		tween.tween_method(
			func(progress: float) -> void:
				if fire_action_id != latest_proxy_action_id:
					return
				_set_spell_glow(progress, safe_direction),
			1.0,
			0.0,
			0.18
		)


func _play_proxy_spell_glow(direction: Vector2, duration: float, action_id: int) -> void:
	_set_spell_glow(0.15, direction)
	var tween := create_tween()
	tween.tween_method(
		func(progress: float) -> void:
			if action_id != latest_proxy_action_id:
				return
			_set_spell_glow(progress, direction),
		0.15,
		1.0,
		maxf(duration, 0.01)
	)


func _set_spell_glow(progress: float, direction: Vector2) -> void:
	var clamped_progress := clampf(progress, 0.0, 1.0)
	spell_glow.visible = clamped_progress > 0.0
	if not spell_glow.visible:
		return
	var safe_direction := direction.normalized() if direction != Vector2.ZERO else Vector2.RIGHT
	spell_glow.position = safe_direction * 14.0
	spell_glow.rotation = safe_direction.angle()
	spell_glow.scale = Vector2.ONE * lerpf(0.75, 1.65, clamped_progress)
	spell_glow.color = Color(0.92, 0.42, 1.0, lerpf(0.18, 0.72, clamped_progress))
