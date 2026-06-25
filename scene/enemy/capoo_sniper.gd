extends "res://scene/enemy/capoo_ranged_enemy.gd"
class_name CapooSniper

const SniperConfig := preload("res://resources/config/enemies/capoo_sniper_config.gd")
const AIM_LINE_START_DISTANCE := 10.0
const AIM_LINE_TARGET_PADDING := 10.0
const AIM_LINE_MIN_LENGTH := 8.0

enum CombatState {
	CHASE,
	LOCK,
}

@onready var aim_glow: Polygon2D = $AimGlow
@onready var attack_audio: AudioStreamPlayer2D = $AttackAudio

var combat_state: CombatState = CombatState.CHASE
var attack_cooldown_left: float = 0.0
var lock_time_left: float = 0.0
var locked_player: Player = null
var lock_reticle: CapooSniperLockReticle = null
var latest_proxy_target_action_id: int = 0


func _ready() -> void:
	super._ready()
	_set_aim_glow(0.0, global_position + Vector2.RIGHT)


func _physics_process(delta: float) -> void:
	if is_dead:
		velocity = Vector2.ZERO
		return

	_update_touch_damage(delta)
	_update_attack_cooldown(delta)

	if combat_state == CombatState.LOCK:
		_update_lock(delta)
		return

	if not is_instance_valid(target_player):
		velocity = Vector2.ZERO
		move_and_slide()
		return

	if _try_start_lock():
		return

	var move_direction := _get_navigation_move_direction(delta)
	_update_facing(move_direction)
	velocity = move_direction * _get_move_speed()
	move_and_slide()


func _apply_config() -> void:
	super._apply_config()
	combat_state = CombatState.CHASE
	attack_cooldown_left = 0.0
	lock_time_left = 0.0
	locked_player = null
	_clear_lock_reticle()
	var sniper_config := config as SniperConfig
	if sniper_config != null:
		attack_audio.stream = sniper_config.attack_audio_stream


func _die() -> void:
	_cancel_lock()
	super._die()


func _update_attack_cooldown(delta: float) -> void:
	if attack_cooldown_left > 0.0:
		attack_cooldown_left = maxf(attack_cooldown_left - delta, 0.0)


func _try_start_lock() -> bool:
	var sniper_config := config as SniperConfig
	if sniper_config == null or sniper_config.lock_reticle_scene == null:
		return false
	if attack_cooldown_left > 0.0:
		return false
	if not is_instance_valid(target_player):
		return false
	if global_position.distance_to(target_player.global_position) > sniper_config.attack_range:
		return false
	if not _has_clear_world_line_to_target():
		return false

	combat_state = CombatState.LOCK
	locked_player = target_player
	lock_time_left = maxf(sniper_config.lock_duration, 0.01)
	velocity = Vector2.ZERO
	_clear_navigation_path()
	_update_facing(global_position.direction_to(locked_player.global_position))
	_play_config_animation(sniper_config.aim_animation_name)
	_show_lock_reticle(locked_player, sniper_config.lock_duration)
	_set_aim_glow(0.35, locked_player.global_position)
	_broadcast_enemy_target_action(&"sniper_lock_start", locked_player.peer_id)
	return true


func _update_lock(delta: float) -> void:
	var sniper_config := config as SniperConfig
	if sniper_config == null or not _is_lock_target_valid(sniper_config):
		_cancel_lock()
		return

	velocity = Vector2.ZERO
	var direction := global_position.direction_to(locked_player.global_position)
	if direction == Vector2.ZERO:
		direction = Vector2.RIGHT
	_update_facing(direction)
	lock_time_left = maxf(lock_time_left - delta, 0.0)
	var progress := 1.0 - lock_time_left / maxf(sniper_config.lock_duration, 0.01)
	_set_aim_glow(progress, locked_player.global_position)
	if lock_reticle != null and is_instance_valid(lock_reticle):
		lock_reticle.set_progress(progress)

	if lock_time_left > 0.0:
		return

	_fire_locked_shot(direction)


func _is_lock_target_valid(sniper_config: SniperConfig) -> bool:
	if locked_player == null or not is_instance_valid(locked_player) or locked_player.is_dead:
		return false
	if global_position.distance_to(locked_player.global_position) > sniper_config.attack_range:
		return false
	return _has_clear_world_line_to_position(locked_player.global_position)


func _fire_locked_shot(direction: Vector2) -> void:
	var sniper_config := config as SniperConfig
	if sniper_config == null or locked_player == null:
		_cancel_lock()
		return

	attack_cooldown_left = maxf(sniper_config.attack_interval, 0.01)
	var hit_source_id := _get_multiplayer_damage_source_id(Time.get_ticks_msec() % 1000000)
	var current_scene := get_tree().current_scene
	var reported := false
	if current_scene != null and current_scene.has_method("request_multiplayer_player_damage"):
		reported = bool(current_scene.call(
			"request_multiplayer_player_damage",
			hit_source_id,
			locked_player.peer_id,
			sniper_config.attack_damage,
			&"capoo_sniper_lock"
		))
	if not reported:
		locked_player.apply_damage(sniper_config.attack_damage)
	if sniper_config.attack_audio_stream != null:
		attack_audio.pitch_scale = random_generator.randf_range(0.96, 1.03)
		attack_audio.play()
	_broadcast_enemy_target_action(&"sniper_lock_fire", locked_player.peer_id)
	_clear_lock_reticle()
	locked_player = null
	combat_state = CombatState.CHASE
	_set_aim_glow(0.0, global_position + direction)
	_play_config_animation(sniper_config.move_animation_name)


func _cancel_lock() -> void:
	if locked_player != null and is_instance_valid(locked_player):
		_broadcast_enemy_target_action(&"sniper_lock_cancel", locked_player.peer_id)
	combat_state = CombatState.CHASE
	lock_time_left = 0.0
	locked_player = null
	_clear_lock_reticle()
	_set_aim_glow(0.0, global_position + Vector2.RIGHT)
	var sniper_config := config as SniperConfig
	if sniper_config != null:
		_play_config_animation(sniper_config.move_animation_name)


func _show_lock_reticle(target: Player, duration: float) -> void:
	_clear_lock_reticle()
	var sniper_config := config as SniperConfig
	if sniper_config == null or sniper_config.lock_reticle_scene == null:
		return
	var reticle := sniper_config.lock_reticle_scene.instantiate() as CapooSniperLockReticle
	if reticle == null:
		return
	target.add_child(reticle)
	reticle.position = Vector2.ZERO
	reticle.start(duration)
	lock_reticle = reticle


func _clear_lock_reticle() -> void:
	if lock_reticle != null and is_instance_valid(lock_reticle):
		var reticle_parent := lock_reticle.get_parent()
		if reticle_parent != null:
			reticle_parent.remove_child(lock_reticle)
		lock_reticle.free()
	lock_reticle = null


func play_multiplayer_enemy_target_action(
	action_name: StringName,
	target: Player,
	action_id: int
) -> void:
	if action_id <= latest_proxy_target_action_id:
		return
	latest_proxy_target_action_id = action_id
	var sniper_config := config as SniperConfig
	if action_name == &"sniper_lock_start":
		if sniper_config != null:
			_play_multiplayer_proxy_action_animation(sniper_config.aim_animation_name, sniper_config.lock_duration + 0.15)
			if target != null and is_instance_valid(target):
				_show_lock_reticle(target, sniper_config.lock_duration)
				_set_aim_glow(0.35, target.global_position)
	elif action_name == &"sniper_lock_cancel" or action_name == &"sniper_lock_fire":
		_clear_lock_reticle()
		_set_aim_glow(0.0, global_position + Vector2.RIGHT)


func _set_aim_glow(progress: float, target_global_position: Vector2) -> void:
	var clamped_progress := clampf(progress, 0.0, 1.0)
	aim_glow.visible = clamped_progress > 0.0
	if not aim_glow.visible:
		return
	var target_local_position := to_local(target_global_position)
	var target_distance := target_local_position.length()
	if target_distance <= AIM_LINE_MIN_LENGTH:
		target_local_position = Vector2.RIGHT * AIM_LINE_MIN_LENGTH
		target_distance = AIM_LINE_MIN_LENGTH
	var safe_direction := target_local_position / target_distance
	var start_position := safe_direction * minf(AIM_LINE_START_DISTANCE, target_distance * 0.35)
	var end_position := target_local_position - safe_direction * minf(AIM_LINE_TARGET_PADDING, target_distance * 0.25)
	var half_width := lerpf(0.45, 0.9, clamped_progress)
	var perpendicular := safe_direction.orthogonal() * half_width
	aim_glow.position = Vector2.ZERO
	aim_glow.rotation = 0.0
	aim_glow.scale = Vector2.ONE
	aim_glow.polygon = PackedVector2Array([
		start_position + perpendicular,
		end_position + perpendicular,
		end_position - perpendicular,
		start_position - perpendicular,
	])
	aim_glow.color = Color(1.0, 0.05, 0.03, lerpf(0.14, 0.38, clamped_progress))
