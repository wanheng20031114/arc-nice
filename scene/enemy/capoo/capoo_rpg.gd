extends "res://scene/enemy/layered_ranged_enemy.gd"
class_name CapooRPG

const CapooRPGConfigScript := preload("res://resources/config/enemies/capoo_rpg_config.gd")
const ENEMY_ATTACK_AUDIO_LIMITER := preload(
	"res://scene/combat/audio/enemy_attack_audio_limiter.gd"
)
const CapooRPGRocketSimulationServiceScript := preload(
	"res://scene/combat/simulation/capoo_rpg_rocket_simulation_service.gd"
)


enum CombatState {
	CHASE,
	WINDUP,
	FIRE,
}

@onready var muzzle_heat: Polygon2D = $MuzzleHeat
@onready var attack_audio: AudioStreamPlayer2D = $AttackAudio

var combat_state: CombatState = CombatState.CHASE
var attack_cooldown_left: float = 0.0
var windup_time_left: float = 0.0
var fire_time_left: float = 0.0
var fire_direction := Vector2.RIGHT
var latest_proxy_action_id: int = 0
var committed_attack_target: Node2D = null
var layered_rpg_event_consumes_tick := false
var layered_rpg_windup_ready_to_fire := false


func supports_dynamic_enemy_targeting() -> bool:
	return true


func _ready() -> void:
	super._ready()
	_set_muzzle_heat(0.0, Vector2.RIGHT)


func can_target_water_plant_objectives() -> bool:
	return true


func supports_centralized_authoritative_simulation() -> bool:
	return true


func _supports_layered_ranged_authoritative_simulation() -> bool:
	return true


func _supports_layered_ranged_contact_authority() -> bool:
	return true


func _supports_layered_ranged_indexed_touch_authority() -> bool:
	# RPG contact has no inherited touch hit. Indexed authority replaces its only
	# authored TouchDamageArea, while rockets remain in the data simulation service.
	return true


func get_layered_area_decision_interval_frames() -> int:
	# Legacy attempts target/range/LOS acquisition on every CHASE physics tick.
	return 1


func _prepare_layered_ranged_authoritative_simulation() -> void:
	layered_rpg_event_consumes_tick = false
	layered_rpg_windup_ready_to_fire = false


func _advance_layered_ranged_event_phase(delta: float) -> void:
	layered_rpg_event_consumes_tick = false
	layered_rpg_windup_ready_to_fire = false
	_update_attack_cooldown(delta)
	if (
		combat_state != CombatState.CHASE
		and not _is_ranged_combat_target_valid(committed_attack_target)
	):
		# The authored runner cancels before its state match, so CHASE decision and
		# motion remain eligible later in this same tick.
		_cancel_attack()
		request_layered_area_urgent_decision()
	match combat_state:
		CombatState.WINDUP:
			layered_rpg_event_consumes_tick = true
			if _advance_windup_state(delta):
				layered_rpg_windup_ready_to_fire = true
				request_layered_area_urgent_decision()
		CombatState.FIRE:
			layered_rpg_event_consumes_tick = true
			_update_fire(delta)


func _can_sleep_layered_ranged_event_phase() -> bool:
	# Cooldown and authored visual timers are public per-tick state.
	return (
		combat_state == CombatState.CHASE
		and attack_cooldown_left <= 0.0
	)


func _try_consume_layered_ranged_decision_phase(_delta: float) -> bool:
	if layered_rpg_event_consumes_tick:
		if layered_rpg_windup_ready_to_fire:
			_resolve_expired_windup()
			layered_rpg_windup_ready_to_fire = false
		return true
	var started := _try_start_chase_attack_decision()
	if started:
		# Wake a CHASE event lane that may have been sleeping before the commit.
		request_layered_area_urgent_decision()
	return started


func _layered_ranged_attack_state_allows_motion() -> bool:
	return (
		combat_state == CombatState.CHASE
		and not layered_rpg_event_consumes_tick
	)


func _run_authoritative_physics_step(delta: float) -> void:
	if is_dead:
		velocity = Vector2.ZERO
		return

	_update_touch_damage(delta)
	_update_attack_cooldown(delta)
	if (
		combat_state != CombatState.CHASE
		and not _is_ranged_combat_target_valid(committed_attack_target)
	):
		_cancel_attack()

	match combat_state:
		CombatState.WINDUP:
			_update_windup(delta)
			return
		CombatState.FIRE:
			_update_fire(delta)
			return

	if _try_start_chase_attack_decision():
		return
	if _has_player_contact():
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


func _try_start_chase_attack_decision() -> bool:
	var combat_target := _get_preferred_ranged_combat_target()
	return combat_target != null and _try_start_windup(combat_target)


func _apply_config() -> void:
	super._apply_config()
	combat_state = CombatState.CHASE
	attack_cooldown_left = 0.0
	windup_time_left = 0.0
	fire_time_left = 0.0
	committed_attack_target = null
	layered_rpg_event_consumes_tick = false
	layered_rpg_windup_ready_to_fire = false

	var rpg_config := config as CapooRPGConfigScript
	if rpg_config != null:
		attack_audio.stream = rpg_config.attack_audio_stream
		_set_muzzle_heat(0.0, Vector2.RIGHT)


func _die() -> void:
	combat_state = CombatState.CHASE
	committed_attack_target = null
	_set_muzzle_heat(0.0, fire_direction)
	super._die()


func play_multiplayer_death_sequence() -> void:
	latest_proxy_action_id += 1
	committed_attack_target = null
	_set_muzzle_heat(0.0, fire_direction)
	super.play_multiplayer_death_sequence()


func _update_attack_cooldown(delta: float) -> void:
	if attack_cooldown_left <= 0.0:
		return
	attack_cooldown_left = maxf(attack_cooldown_left - delta, 0.0)


func _try_start_windup(candidate_target: Node2D = null) -> bool:
	var rpg_config := config as CapooRPGConfigScript
	if rpg_config == null:
		return false
	if attack_cooldown_left > 0.0:
		return false
	if candidate_target == null:
		candidate_target = _get_preferred_ranged_combat_target()
	if not _is_ranged_combat_target_valid(candidate_target):
		return false
	if not _is_ranged_combat_target_in_range(
		candidate_target,
		rpg_config.attack_range
	):
		return false
	if not _has_clear_world_line_to_rpg_target(candidate_target):
		return false

	committed_attack_target = candidate_target
	combat_state = CombatState.WINDUP
	windup_time_left = maxf(rpg_config.attack_windup, 0.0)
	fire_direction = global_position.direction_to(
		committed_attack_target.global_position
	)
	if fire_direction == Vector2.ZERO:
		fire_direction = Vector2.RIGHT
	velocity = Vector2.ZERO
	_clear_navigation_path()
	_update_facing(fire_direction)
	_play_config_animation(rpg_config.windup_animation_name)
	_set_muzzle_heat(0.15, fire_direction)
	_broadcast_enemy_action(&"windup", fire_direction)
	return true


func _update_windup(delta: float) -> void:
	if not _advance_windup_state(delta):
		return
	_resolve_expired_windup()


func _advance_windup_state(delta: float) -> bool:
	var rpg_config := config as CapooRPGConfigScript
	if (
		rpg_config == null
		or not _is_ranged_combat_target_valid(committed_attack_target)
	):
		_cancel_attack()
		return false

	velocity = Vector2.ZERO
	fire_direction = global_position.direction_to(
		committed_attack_target.global_position
	)
	if fire_direction == Vector2.ZERO:
		fire_direction = Vector2.RIGHT
	_update_facing(fire_direction)
	windup_time_left = maxf(windup_time_left - delta, 0.0)
	var progress := 1.0 - (windup_time_left / maxf(rpg_config.attack_windup, 0.001))
	_set_muzzle_heat(progress, fire_direction)

	if windup_time_left > 0.0:
		return false
	return true


func _resolve_expired_windup() -> void:
	if not _has_clear_world_line_to_rpg_target(committed_attack_target):
		_cancel_attack()
		return

	_start_fire(fire_direction)


func _start_fire(direction: Vector2) -> void:
	var rpg_config := config as CapooRPGConfigScript
	if rpg_config == null:
		_cancel_attack()
		return

	combat_state = CombatState.FIRE
	fire_time_left = 0.18
	fire_direction = direction.normalized() if direction != Vector2.ZERO else Vector2.RIGHT
	attack_cooldown_left = maxf(rpg_config.attack_interval, 0.01)
	velocity = Vector2.ZERO
	_update_facing(fire_direction)
	_play_config_animation(rpg_config.attack_animation_name)
	_set_muzzle_heat(1.0, fire_direction)
	_fire_rocket()
	_broadcast_enemy_action(&"fire", fire_direction)
	if rpg_config.attack_audio_stream != null:
		attack_audio.pitch_scale = random_generator.randf_range(0.96, 1.04)
		ENEMY_ATTACK_AUDIO_LIMITER.play_heavy_attack(attack_audio)


func _update_fire(delta: float) -> void:
	velocity = Vector2.ZERO
	_update_facing(fire_direction)
	fire_time_left = maxf(fire_time_left - delta, 0.0)
	_set_muzzle_heat(fire_time_left / 0.18, fire_direction)
	if fire_time_left <= 0.0:
		_finish_fire()


func _fire_rocket() -> bool:
	var rpg_config := config as CapooRPGConfigScript
	if rpg_config == null:
		return false

	if (
		combat_runtime == null
		or not is_instance_valid(combat_runtime)
	):
		return false
	var rocket_service := _get_capoo_rpg_rocket_simulation_service()
	if rocket_service == null:
		return false

	var outgoing_damage := get_effective_attack_damage(rpg_config.attack_damage)
	var safe_direction := (
		fire_direction.normalized()
		if fire_direction != Vector2.ZERO
		else Vector2.RIGHT
	)
	var spawn_position := (
		global_position + safe_direction * rpg_config.projectile_spawn_distance
	)
	var source_snapshot := create_damage_source_snapshot(
		0,
		&"capoo_rpg_rocket"
	)
	var handle := rocket_service.spawn_authoritative(
		0,
		spawn_position,
		safe_direction,
		outgoing_damage,
		rpg_config.projectile_speed,
		rpg_config.projectile_lifetime,
		rpg_config.explosion_radius,
		source_snapshot
	)
	if handle <= CapooRPGRocketSimulationServiceScript.INVALID_HANDLE:
		return false
	if (
		combat_runtime.runtime_mode
		== CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY
	):
		if gameplay_gateway == null or not is_instance_valid(gameplay_gateway):
			rocket_service.release(handle)
			return false
		var projectile_id := gameplay_gateway.register_local_capoo_rpg_data(
			rocket_service,
			handle,
			&"capoo_rpg_rocket",
			0,
			spawn_position,
			safe_direction,
			outgoing_damage,
			rpg_config.projectile_speed,
			rpg_config.projectile_lifetime,
			source_snapshot
		)
		if projectile_id <= 0:
			rocket_service.release(handle)
			return false
	return true


func _get_capoo_rpg_rocket_simulation_service() -> CapooRPGRocketSimulationServiceScript:
	if combat_runtime == null or not is_instance_valid(combat_runtime):
		return null
	var combat_services := combat_runtime.get_enemy_combat_services()
	if combat_services == null:
		return null
	return combat_services.get_capoo_rpg_rocket_simulation_service()


func _finish_fire() -> void:
	combat_state = CombatState.CHASE
	committed_attack_target = null
	fire_time_left = 0.0
	_set_muzzle_heat(0.0, fire_direction)
	var rpg_config := config as CapooRPGConfigScript
	if rpg_config != null:
		_play_config_animation(rpg_config.move_animation_name)


func _cancel_attack() -> void:
	combat_state = CombatState.CHASE
	committed_attack_target = null
	windup_time_left = 0.0
	fire_time_left = 0.0
	_set_muzzle_heat(0.0, fire_direction)


func play_multiplayer_enemy_action(action_name: StringName, direction: Vector2, action_id: int) -> void:
	if action_id <= latest_proxy_action_id:
		return
	latest_proxy_action_id = action_id
	var safe_direction := direction.normalized() if direction != Vector2.ZERO else Vector2.RIGHT
	var rpg_config := config as CapooRPGConfigScript
	if action_name == &"windup":
		if rpg_config != null:
			_play_multiplayer_proxy_action_animation(
				rpg_config.windup_animation_name,
				rpg_config.attack_windup + 0.15
			)
			_play_proxy_muzzle_heat(safe_direction, rpg_config.attack_windup, action_id)
		_update_facing(safe_direction)
	elif action_name == &"fire":
		if rpg_config != null:
			_play_multiplayer_proxy_action_animation(
				rpg_config.attack_animation_name,
				0.23
			)
		_update_facing(safe_direction)
		_set_muzzle_heat(1.0, safe_direction)
		var fire_action_id := action_id
		var tween := create_tween()
		tween.tween_method(
			func(progress: float) -> void:
				if fire_action_id != latest_proxy_action_id:
					return
				_set_muzzle_heat(progress, safe_direction),
			1.0,
			0.0,
			0.18
		)


func _play_proxy_muzzle_heat(direction: Vector2, duration: float, action_id: int) -> void:
	_set_muzzle_heat(0.15, direction)
	var tween := create_tween()
	tween.tween_method(
		func(progress: float) -> void:
			if action_id != latest_proxy_action_id:
				return
			_set_muzzle_heat(progress, direction),
		0.15,
		1.0,
		maxf(duration, 0.01)
	)


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


func _has_clear_world_line_to_rpg_target(attack_target: Node2D) -> bool:
	if not _is_ranged_combat_target_valid(attack_target):
		return false

	return _has_throttled_world_line_of_sight(attack_target, WORLD_COLLISION_MASK)


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


func _set_muzzle_heat(progress: float, direction: Vector2) -> void:
	var clamped_progress := clampf(progress, 0.0, 1.0)
	muzzle_heat.visible = clamped_progress > 0.0
	if not muzzle_heat.visible:
		return

	var safe_direction := direction.normalized() if direction != Vector2.ZERO else Vector2.RIGHT
	muzzle_heat.position = safe_direction * 14.0
	muzzle_heat.rotation = safe_direction.angle()
	muzzle_heat.scale = Vector2.ONE * lerpf(0.75, 1.55, clamped_progress)
	muzzle_heat.color = Color(1.0, lerpf(0.28, 0.78, clamped_progress), 0.08, lerpf(0.18, 0.74, clamped_progress))
