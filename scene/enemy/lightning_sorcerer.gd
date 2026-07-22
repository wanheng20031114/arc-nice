extends "res://scene/enemy/capoo_ranged_enemy.gd"
class_name LightningSorcerer

const LightningConfig := preload(
	"res://resources/config/enemies/lightning_sorcerer_config.gd"
)
const LightningVfx := preload(
	"res://scene/enemy/lightning_sorcerer_lightning_vfx.gd"
)
const ATTACK_TARGET_REFRESH_INTERVAL := 0.35
const ATTACK_TARGET_QUERY_METHOD := &"find_nearest_enemy_attack_target"
const DAMAGE_SOURCE_TYPE := &"lightning_sorcerer_chain"

enum CombatState {
	CHASE,
	WINDUP,
}

@onready var cast_pivot: Node2D = $CastPivot
@onready var staff_tip: Marker2D = $CastPivot/StaffTip

var combat_state: CombatState = CombatState.CHASE
var attack_cooldown_left := 0.0
var initial_attack_stagger_left := 0.0
var windup_time_left := 0.0
var cast_direction := Vector2.RIGHT
var cast_target: Node2D = null
var latest_proxy_action_id := 0
var cached_runtime_attack_target: Node2D = null
var attack_target_refresh_left := 0.0


func _get_touch_damage_type() -> EnemyConfig.DamageType:
	return EnemyConfig.DamageType.MAGIC


func _get_preferred_ranged_combat_target() -> Node2D:
	var objective_candidate := get_attackable_objective()
	var player_candidate: Player = null
	if (
		target_player != null
		and is_instance_valid(target_player)
		and not target_player.is_dead
	):
		player_candidate = target_player
	if objective_candidate == null:
		return player_candidate
	if player_candidate == null or objective_candidate == player_candidate:
		return objective_candidate
	var objective_distance_squared := global_position.distance_squared_to(
		objective_candidate.global_position
	)
	var player_distance_squared := global_position.distance_squared_to(
		player_candidate.global_position
	)
	return (
		objective_candidate
		if objective_distance_squared <= player_distance_squared
		else player_candidate
	)


func _select_nearest_attack_target(
	fallback_target: Node2D,
	lightning_config: LightningConfig,
	allow_runtime_refresh: bool
) -> Node2D:
	if not _is_ranged_combat_target_valid(cached_runtime_attack_target):
		cached_runtime_attack_target = null
		attack_target_refresh_left = 0.0
	if allow_runtime_refresh and attack_target_refresh_left <= 0.0:
		attack_target_refresh_left = ATTACK_TARGET_REFRESH_INTERVAL
		cached_runtime_attack_target = _query_runtime_attack_target(
			global_position,
			lightning_config.attack_range
		)
	if cached_runtime_attack_target == null:
		return fallback_target
	if not _is_ranged_combat_target_valid(fallback_target):
		return cached_runtime_attack_target
	var cached_distance_squared := global_position.distance_squared_to(
		cached_runtime_attack_target.global_position
	)
	var fallback_distance_squared := global_position.distance_squared_to(
		fallback_target.global_position
	)
	if cached_distance_squared < fallback_distance_squared:
		return cached_runtime_attack_target
	if (
		cached_distance_squared == fallback_distance_squared
		and cached_runtime_attack_target.get_instance_id()
			< fallback_target.get_instance_id()
	):
		return cached_runtime_attack_target
	return fallback_target


func _query_runtime_attack_target(
	from_position: Vector2,
	max_distance: float,
	excluded_instance_ids: Dictionary = {}
) -> Node2D:
	var runtime := _get_attack_target_runtime()
	if runtime == null:
		return null
	var target := runtime.call(
		ATTACK_TARGET_QUERY_METHOD,
		from_position,
		max_distance,
		excluded_instance_ids
	) as Node2D
	return target if _is_ranged_combat_target_valid(target) else null


func _get_attack_target_runtime() -> Node:
	if pathfinder == null:
		return null
	var runtime := pathfinder.get_parent()
	if runtime != null and runtime.has_method(ATTACK_TARGET_QUERY_METHOD):
		return runtime
	return null


func _physics_process(delta: float) -> void:
	if is_dead:
		velocity = Vector2.ZERO
		return

	_update_touch_damage(delta)
	_update_attack_cooldown(delta)
	if combat_state == CombatState.WINDUP:
		_update_windup(delta)
		return

	var lightning_config := config as LightningConfig
	var combat_target := _get_preferred_ranged_combat_target()
	if lightning_config != null:
		combat_target = _select_nearest_attack_target(
			combat_target,
			lightning_config,
			initial_attack_stagger_left <= 0.0
				and attack_cooldown_left <= 0.0
		)
	if (
		combat_target != null
		and lightning_config != null
		and _try_hold_ranged_attack_position(
			combat_target,
			lightning_config.attack_range,
			WORLD_COLLISION_MASK
		)
	):
		if (
			initial_attack_stagger_left <= 0.0
			and _try_start_windup(combat_target, lightning_config)
		):
			return
		if _try_hold_ranged_attack_position(
			combat_target,
			lightning_config.attack_range,
			WORLD_COLLISION_MASK
		):
			velocity = Vector2.ZERO
			_update_facing(global_position.direction_to(combat_target.global_position))
			return
	else:
		_reset_ranged_attack_position_state()

	if not is_instance_valid(objective_target):
		velocity = Vector2.ZERO
		_move_until_player_contact()
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
	var lightning_config := config as LightningConfig
	initial_attack_stagger_left = (
		_get_initial_attack_stagger(lightning_config)
		if lightning_config != null
		else 0.0
	)
	windup_time_left = 0.0
	cast_direction = Vector2.RIGHT
	cast_target = null
	latest_proxy_action_id = 0
	cached_runtime_attack_target = null
	attack_target_refresh_left = 0.0
	_reset_ranged_attack_position_state()


func _die() -> void:
	_cancel_windup(false)
	super._die()


func play_multiplayer_death_sequence() -> void:
	latest_proxy_action_id += 1
	super.play_multiplayer_death_sequence()


func _update_attack_cooldown(delta: float) -> void:
	if initial_attack_stagger_left > 0.0:
		initial_attack_stagger_left = maxf(initial_attack_stagger_left - delta, 0.0)
	if attack_cooldown_left > 0.0:
		attack_cooldown_left = maxf(attack_cooldown_left - delta, 0.0)
	if attack_target_refresh_left > 0.0:
		attack_target_refresh_left = maxf(attack_target_refresh_left - delta, 0.0)


func _get_initial_attack_stagger(lightning_config: LightningConfig) -> float:
	var window := maxf(lightning_config.initial_attack_stagger_window, 0.0)
	if window <= 0.0:
		return 0.0
	var physics_ticks_per_second := maxi(Engine.physics_ticks_per_second, 1)
	var bucket_count := maxi(ceili(window * float(physics_ticks_per_second)), 1)
	var bucket_index := posmod(navigation_update_frame_offset, bucket_count)
	return float(bucket_index) / float(physics_ticks_per_second)


func _try_start_windup(
	attack_target: Node2D,
	lightning_config: LightningConfig
) -> bool:
	if attack_cooldown_left > 0.0:
		return false
	attack_target = _select_nearest_attack_target(
		attack_target,
		lightning_config,
		true
	)
	if not _is_ranged_combat_target_in_range(
		attack_target,
		lightning_config.attack_range
	):
		return false
	if not _has_ranged_combat_line(attack_target, WORLD_COLLISION_MASK, true):
		return false

	combat_state = CombatState.WINDUP
	cast_target = attack_target
	windup_time_left = maxf(lightning_config.windup_duration, 0.01)
	cast_direction = global_position.direction_to(attack_target.global_position)
	if cast_direction == Vector2.ZERO:
		cast_direction = Vector2.RIGHT
	velocity = Vector2.ZERO
	_set_ranged_attack_position_held(true)
	_update_facing(cast_direction)
	cast_pivot.rotation = cast_direction.angle()
	_play_config_animation(lightning_config.windup_animation_name)
	_broadcast_enemy_action(&"windup", cast_direction)
	return true


func _update_windup(delta: float) -> void:
	var lightning_config := config as LightningConfig
	if (
		lightning_config == null
		or not _is_ranged_combat_target_valid(cast_target)
	):
		_cancel_windup()
		return
	if not _is_ranged_combat_target_in_range(
		cast_target,
		lightning_config.attack_range
	):
		_cancel_windup()
		return

	velocity = Vector2.ZERO
	cast_direction = global_position.direction_to(cast_target.global_position)
	if cast_direction == Vector2.ZERO:
		cast_direction = Vector2.RIGHT
	cast_pivot.rotation = cast_direction.angle()
	_update_facing(cast_direction)
	windup_time_left = maxf(windup_time_left - delta, 0.0)
	if windup_time_left > 0.0:
		return
	if not _has_ranged_combat_line(cast_target, WORLD_COLLISION_MASK, true):
		_cancel_windup()
		return
	_finish_windup_and_strike(lightning_config)


func _finish_windup_and_strike(lightning_config: LightningConfig) -> void:
	var first_target := cast_target
	_play_config_animation(lightning_config.attack_animation_name)
	_broadcast_enemy_action(&"fire", cast_direction)
	var damage_source_id := _get_multiplayer_damage_source_id(action_sequence)
	var world_path := _resolve_chain_hits(
		first_target,
		lightning_config,
		damage_source_id
	)
	if world_path.size() >= 2:
		LightningVfx.try_spawn(self, world_path)
		var current_scene := get_tree().current_scene
		if (
			current_scene != null
			and current_scene.has_method("broadcast_enemy_lightning_chain")
		):
			current_scene.call("broadcast_enemy_lightning_chain", world_path)
	attack_cooldown_left = maxf(lightning_config.attack_interval, 0.01)
	combat_state = CombatState.CHASE
	windup_time_left = 0.0
	cast_target = null


func _resolve_chain_hits(
	first_target: Node2D,
	lightning_config: LightningConfig,
	damage_source_id: int
) -> PackedVector2Array:
	var world_path := PackedVector2Array([staff_tip.global_position])
	var excluded_instance_ids: Dictionary = {}
	var current_target := first_target
	var previous_hit_position := staff_tip.global_position
	var maximum_hits := 1 + clampi(lightning_config.max_chain_bounces, 0, 4)
	for _hit_index in range(maximum_hits):
		if not _is_ranged_combat_target_valid(current_target):
			break
		var hit_position := current_target.global_position
		var target_instance_id := int(current_target.get_instance_id())
		excluded_instance_ids[target_instance_id] = true
		world_path.append(hit_position)
		# Chaining follows the authoritative contact sequence, not whether this
		# particular damage submission changed health. Invulnerability, multiplayer
		# de-duplication or another ability policy must not silently stop traversal.
		_apply_chain_damage(
			current_target,
			lightning_config.attack_damage,
			damage_source_id,
			previous_hit_position
		)
		previous_hit_position = hit_position
		if world_path.size() >= maximum_hits + 1:
			break
		current_target = _query_runtime_attack_target(
			hit_position,
			lightning_config.chain_range,
			excluded_instance_ids
		)
	return world_path


func _apply_chain_damage(
	target: Node2D,
	damage: int,
	damage_source_id: int,
	source_position: Vector2
) -> bool:
	if damage <= 0:
		return false
	var player_target := target as Player
	if player_target != null:
		if player_target.is_dead:
			return false
		var source_direction := player_target.global_position.direction_to(
			source_position
		)
		var current_scene := get_tree().current_scene
		if (
			current_scene != null
			and current_scene.has_method("request_multiplayer_player_damage")
			and bool(current_scene.call(
				"request_multiplayer_player_damage",
				damage_source_id,
				player_target.peer_id,
				damage,
				DAMAGE_SOURCE_TYPE,
				EnemyConfig.DamageType.MAGIC,
				source_direction,
				true
			))
		):
			return true
		return player_target.apply_damage(
			damage,
			EnemyConfig.DamageType.MAGIC,
			{
				"is_ranged": true,
				"source_direction": source_direction,
			}
		)

	var plant_target := target as PlantDefense
	if plant_target == null or plant_target.is_dead or plant_target.is_removing:
		return false
	return plant_target.receive_damage(
		damage,
		self,
		source_position.direction_to(plant_target.global_position),
		EnemyConfig.DamageType.MAGIC
	)


func _on_animated_sprite_animation_finished() -> void:
	super._on_animated_sprite_animation_finished()
	var lightning_config := config as LightningConfig
	if (
		is_dead
		or combat_state != CombatState.CHASE
		or lightning_config == null
		or animated_sprite.animation != lightning_config.attack_animation_name
	):
		return
	_play_config_animation(lightning_config.move_animation_name)


func _cancel_windup(restore_move_animation := true) -> void:
	var had_active_windup := combat_state == CombatState.WINDUP
	combat_state = CombatState.CHASE
	windup_time_left = 0.0
	cast_target = null
	var lightning_config := config as LightningConfig
	if restore_move_animation and lightning_config != null:
		_play_config_animation(lightning_config.move_animation_name)
	if had_active_windup and not is_dead:
		_broadcast_enemy_action(&"cancel", cast_direction)
	_reset_ranged_attack_position_state()


func play_multiplayer_enemy_action(
	action_name: StringName,
	direction: Vector2,
	action_id: int
) -> void:
	if action_id <= latest_proxy_action_id:
		return
	latest_proxy_action_id = action_id
	var lightning_config := config as LightningConfig
	if lightning_config == null:
		return
	var safe_direction := (
		direction.normalized() if direction != Vector2.ZERO else Vector2.RIGHT
	)
	_update_facing(safe_direction)
	if action_name == &"windup":
		_play_multiplayer_proxy_action_animation(
			lightning_config.windup_animation_name,
			lightning_config.windup_duration + 0.15
		)
		_schedule_proxy_windup_timeout(
			action_id,
			lightning_config.windup_duration + 0.2
		)
	elif action_name == &"fire":
		_play_multiplayer_proxy_action_animation(
			lightning_config.attack_animation_name,
			_get_scene_animation_duration(
				lightning_config.attack_animation_name
			) + 0.05
		)
	elif action_name == &"cancel":
		_play_config_animation(lightning_config.move_animation_name)


func _schedule_proxy_windup_timeout(action_id: int, timeout: float) -> void:
	if not is_inside_tree():
		return
	var timeout_tween := create_tween()
	timeout_tween.tween_interval(maxf(timeout, 0.01))
	timeout_tween.tween_callback(_expire_proxy_windup.bind(action_id))


func _expire_proxy_windup(action_id: int) -> void:
	if action_id != latest_proxy_action_id or is_dead or config == null:
		return
	var lightning_config := config as LightningConfig
	if (
		lightning_config != null
		and animated_sprite.animation == lightning_config.windup_animation_name
	):
		_play_config_animation(lightning_config.move_animation_name)
