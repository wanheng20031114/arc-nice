extends "res://scene/enemy/capoo_ranged_enemy.gd"
class_name CapooMage

const MageConfig := preload("res://resources/config/enemies/capoo_mage_config.gd")
const ENEMY_ATTACK_AUDIO_LIMITER := preload(
	"res://scene/combat/audio/enemy_attack_audio_limiter.gd"
)
const CapooMageFireballSimulationServiceScript := preload(
	"res://scene/combat/simulation/capoo_mage_fireball_simulation_service.gd"
)

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
var attack_target: Node2D = null


func _ready() -> void:
	super._ready()
	_set_spell_glow(0.0, Vector2.RIGHT)


func _get_touch_damage_type() -> EnemyConfig.DamageType:
	return EnemyConfig.DamageType.MAGIC


func _physics_process(delta: float) -> void:
	if is_dead:
		velocity = Vector2.ZERO
		return

	_update_touch_damage(delta)
	_update_attack_cooldown(delta)

	match combat_state:
		CombatState.WINDUP:
			_update_windup(delta)
			return
		CombatState.FIRE:
			_update_fire(delta)
			return

	var mage_config := config as MageConfig
	var preferred_target := _get_preferred_ranged_combat_target()
	if (
		mage_config != null
		and _try_hold_ranged_attack_position(
			preferred_target,
			mage_config.attack_range,
			WORLD_COLLISION_MASK
		)
	):
		if _try_start_windup(preferred_target):
			return
		if _try_hold_ranged_attack_position(
			preferred_target,
			mage_config.attack_range,
			WORLD_COLLISION_MASK
		):
			_update_facing(global_position.direction_to(preferred_target.global_position))
			return
	else:
		_reset_ranged_attack_position_state()

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
	fire_time_left = 0.0
	latest_proxy_action_id = 0
	attack_target = null
	_reset_ranged_attack_position_state()
	var mage_config := config as MageConfig
	if mage_config != null:
		attack_audio.stream = mage_config.attack_audio_stream


func _die() -> void:
	combat_state = CombatState.CHASE
	attack_target = null
	_reset_ranged_attack_position_state()
	_set_spell_glow(0.0, fire_direction)
	super._die()


func play_multiplayer_death_sequence() -> void:
	latest_proxy_action_id += 1
	_set_spell_glow(0.0, fire_direction)
	super.play_multiplayer_death_sequence()


func _update_attack_cooldown(delta: float) -> void:
	if attack_cooldown_left > 0.0:
		attack_cooldown_left = maxf(attack_cooldown_left - delta, 0.0)


func _try_start_windup(candidate_target: Node2D = null) -> bool:
	var mage_config := config as MageConfig
	if mage_config == null:
		return false
	if attack_cooldown_left > 0.0:
		return false
	if candidate_target == null:
		candidate_target = _get_preferred_ranged_combat_target()
	if candidate_target == null:
		return false
	if not _is_ranged_combat_target_in_range(
		candidate_target,
		mage_config.attack_range
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
	windup_time_left = maxf(mage_config.attack_windup, 0.0)
	fire_direction = global_position.direction_to(attack_target.global_position)
	if fire_direction == Vector2.ZERO:
		fire_direction = Vector2.RIGHT
	velocity = Vector2.ZERO
	_set_ranged_attack_position_held(true)
	_update_facing(fire_direction)
	_play_config_animation(mage_config.windup_animation_name)
	_set_spell_glow(0.15, fire_direction)
	_broadcast_enemy_action(&"windup", fire_direction)
	return true


func _update_windup(delta: float) -> void:
	var mage_config := config as MageConfig
	if (
		mage_config == null
		or not _is_ranged_combat_target_in_range(
			attack_target,
			mage_config.attack_range
		)
	):
		_cancel_attack()
		return

	velocity = Vector2.ZERO
	fire_direction = global_position.direction_to(attack_target.global_position)
	if fire_direction == Vector2.ZERO:
		fire_direction = Vector2.RIGHT
	_update_facing(fire_direction)
	windup_time_left = maxf(windup_time_left - delta, 0.0)
	var progress := 1.0 - (windup_time_left / maxf(mage_config.attack_windup, 0.001))
	_set_spell_glow(progress, fire_direction)

	if windup_time_left > 0.0:
		return
	if not _has_ranged_combat_line(
		attack_target,
		WORLD_COLLISION_MASK,
		true
	):
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
		ENEMY_ATTACK_AUDIO_LIMITER.play_heavy_attack(attack_audio)


func _update_fire(delta: float) -> void:
	velocity = Vector2.ZERO
	_update_facing(fire_direction)
	fire_time_left = maxf(fire_time_left - delta, 0.0)
	_set_spell_glow(fire_time_left / 0.18, fire_direction)
	if fire_time_left <= 0.0:
		_finish_fire()


func _fire_fireball() -> bool:
	var mage_config := config as MageConfig
	if mage_config == null:
		return false

	if (
		combat_runtime == null
		or not is_instance_valid(combat_runtime)
	):
		return false
	var fireball_service := _get_capoo_mage_fireball_simulation_service()
	if fireball_service == null:
		return false

	var outgoing_damage := get_effective_attack_damage(mage_config.attack_damage)
	var safe_direction := (
		fire_direction.normalized()
		if fire_direction != Vector2.ZERO
		else Vector2.RIGHT
	)
	var spawn_position := (
		global_position + safe_direction * mage_config.projectile_spawn_distance
	)
	var source_snapshot := create_damage_source_snapshot(
		0,
		&"capoo_mage_fireball"
	)
	var handle := fireball_service.spawn_authoritative(
		spawn_position,
		safe_direction,
		outgoing_damage,
		mage_config.projectile_speed,
		mage_config.projectile_lifetime,
		mage_config.fireball_radius,
		attack_target,
		mage_config.fireball_homing_turn_rate,
		source_snapshot
	)
	if handle <= CapooMageFireballSimulationServiceScript.INVALID_HANDLE:
		return false
	if (
		combat_runtime.runtime_mode
		!= CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY
	):
		return true
	if gameplay_gateway == null or not is_instance_valid(gameplay_gateway):
		fireball_service.release(handle)
		return false
	var target_peer_id := 0
	var target_world_net_id := 0
	var player_target := attack_target as Player
	if player_target != null:
		target_peer_id = player_target.peer_id
	elif attack_target != null and is_instance_valid(attack_target):
		target_world_net_id = int(attack_target.get_meta(&"net_id", 0))
	var projectile_id := gameplay_gateway.register_local_capoo_mage_fireball_data(
		fireball_service,
		handle,
		&"capoo_mage_fireball",
		0,
		spawn_position,
		safe_direction,
		outgoing_damage,
		mage_config.projectile_speed,
		mage_config.projectile_lifetime,
		target_peer_id,
		target_world_net_id,
		source_snapshot
	)
	if projectile_id <= 0:
		fireball_service.release(handle)
		return false
	return true


func _get_capoo_mage_fireball_simulation_service() -> CapooMageFireballSimulationServiceScript:
	if combat_runtime == null or not is_instance_valid(combat_runtime):
		return null
	var combat_services := combat_runtime.get_enemy_combat_services()
	if combat_services == null:
		return null
	return combat_services.get_capoo_mage_fireball_simulation_service()


func _finish_fire() -> void:
	combat_state = CombatState.CHASE
	attack_target = null
	fire_time_left = 0.0
	_set_spell_glow(0.0, fire_direction)
	var mage_config := config as MageConfig
	if mage_config != null:
		_play_config_animation(mage_config.move_animation_name)


func _cancel_attack() -> void:
	combat_state = CombatState.CHASE
	attack_target = null
	windup_time_left = 0.0
	fire_time_left = 0.0
	_set_spell_glow(0.0, fire_direction)
	_reset_ranged_attack_position_state()


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
