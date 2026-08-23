extends "res://scene/enemy/capoo_ranged_enemy.gd"
class_name LightningSorcerer

const LightningConfig := preload(
	"res://resources/config/enemies/lightning_sorcerer_config.gd"
)
const LightningVfx := preload(
	"res://scene/enemy/sorcerer/lightning_sorcerer_lightning_vfx.gd"
)
const EnemyWarningPresentationSystemScript := preload(
	"res://scene/combat/presentation/enemy_warning_presentation_system.gd"
)
const ATTACK_TARGET_REFRESH_INTERVAL := 0.35
const ATTACK_TARGET_QUERY_METHOD := &"find_nearest_enemy_attack_target_world"
const DAMAGE_SOURCE_TYPE := &"lightning_sorcerer_chain"
const TARGET_WARNING_RETRY_DELAY := 0.2
const PLAYER_WINDUP_ACTION := &"lightning_windup"
const PLAYER_WINDUP_RETRY_ACTION := &"lightning_windup_retry"
const PLANT_WINDUP_ACTION := &"lightning_plant_windup"
const PLANT_WINDUP_RETRY_ACTION := &"lightning_plant_windup_retry"

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
var cast_damage_source_snapshot: DamageSourceSnapshot = null
var latest_proxy_action_id := 0
var latest_proxy_terminal_action_id := 0
var latest_proxy_presentation_revision := 0
var latest_proxy_presentation_terminal_revision := 0
var proxy_warning_generation := 0
var cached_runtime_attack_target: Node2D = null
var attack_target_refresh_left := 0.0
var warning_retry_time_left := 0.0
var warning_retry_sent := false
var proxy_warning_target: Node2D = null
var proxy_warning_plant_position := Vector2.ZERO
var proxy_warning_duration := 0.0
var proxy_warning_elapsed := 0.0
var target_warning_handle := 0
var target_warning_chain_radius := 0.0
var _warning_presentation_system: EnemyWarningPresentationSystemScript = null
var _chain_candidates: Array[Node2D] = []
var _chain_excluded_instance_ids: Dictionary = {}
var _chain_world_path := PackedVector2Array()


func _get_touch_damage_type() -> EnemyConfig.DamageType:
	return EnemyConfig.DamageType.MAGIC


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
	if combat_runtime == null or not is_instance_valid(combat_runtime):
		return null
	var target := combat_runtime.find_nearest_hostile_enemy_attack_target_world(
		from_position,
		max_distance,
		_get_frozen_attack_source_faction_id(),
		excluded_instance_ids
	)
	return target if _is_frozen_source_hostile_target_valid(target) else null


func _get_frozen_attack_source_faction_id() -> int:
	if cast_damage_source_snapshot != null:
		return cast_damage_source_snapshot.source_faction_id
	return get_combat_faction_id()


func _is_frozen_source_hostile_target_valid(candidate: Node2D) -> bool:
	if candidate == null or not is_instance_valid(candidate) or candidate == self:
		return false
	var player_target := candidate as Player
	var target_faction_id := CombatRelationService.NEUTRAL
	if player_target != null:
		if player_target.is_dead or player_target.is_queued_for_deletion():
			return false
		target_faction_id = player_target.get_combat_faction_id()
	var plant_target := candidate as PlantDefense
	if plant_target != null:
		if (
			plant_target.is_dead
			or plant_target.is_removing
			or plant_target.is_queued_for_deletion()
		):
			return false
		target_faction_id = plant_target.get_combat_faction_id()
	var enemy_target := candidate as Enemy
	if enemy_target != null:
		if enemy_target.is_dead or enemy_target.is_queued_for_deletion():
			return false
		target_faction_id = enemy_target.get_combat_faction_id()
	elif player_target == null and plant_target == null:
		return false
	var relation_service := (
		combat_runtime.get_combat_relation_service()
		if combat_runtime != null and is_instance_valid(combat_runtime)
		else combat_relation_service
	)
	if relation_service != null:
		return relation_service.is_hostile(
			_get_frozen_attack_source_faction_id(),
			target_faction_id
		)
	return CombatRelationService.is_default_hostile(
		_get_frozen_attack_source_faction_id(),
		target_faction_id
	)


func _is_live_multiplayer_proxy_target(candidate: Node2D) -> bool:
	if candidate == null or not is_instance_valid(candidate):
		return false
	var player_target := candidate as Player
	if player_target != null:
		return not player_target.is_dead and not player_target.is_queued_for_deletion()
	var plant_target := candidate as PlantDefense
	if plant_target != null:
		return (
			not plant_target.is_dead
			and not plant_target.is_removing
			and not plant_target.is_queued_for_deletion()
		)
	var enemy_target := candidate as Enemy
	return (
		enemy_target != null
		and not enemy_target.is_dead
		and not enemy_target.is_queued_for_deletion()
	)


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
	var combat_target := get_resolved_combat_target()
	if combat_target == null and lightning_config != null:
		var family_target := _select_nearest_attack_target(
			_get_family_proactive_ranged_combat_target(),
			lightning_config,
			initial_attack_stagger_left <= 0.0
				and attack_cooldown_left <= 0.0
		)
		combat_target = get_resolved_combat_target(family_target)
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


func _process(delta: float) -> void:
	super._process(delta)
	if is_multiplayer_proxy:
		_update_proxy_target_warning(delta)


func _status_requires_render_process() -> bool:
	return (
		is_multiplayer_proxy
		and proxy_warning_duration > 0.0
	) or super._status_requires_render_process()


func configure_multiplayer_proxy() -> void:
	super.configure_multiplayer_proxy()
	_clear_proxy_target_warning()


func _apply_config() -> void:
	super._apply_config()
	combat_state = CombatState.CHASE
	attack_cooldown_left = 0.0
	var lightning_config := config as LightningConfig
	initial_attack_stagger_left = (
		_get_deterministic_initial_stagger(
			lightning_config.initial_attack_stagger_window
		)
		if lightning_config != null
		else 0.0
	)
	windup_time_left = 0.0
	cast_direction = Vector2.RIGHT
	cast_target = null
	cast_damage_source_snapshot = null
	latest_proxy_action_id = 0
	latest_proxy_terminal_action_id = 0
	latest_proxy_presentation_revision = 0
	latest_proxy_presentation_terminal_revision = 0
	proxy_warning_generation = 0
	cached_runtime_attack_target = null
	attack_target_refresh_left = 0.0
	warning_retry_time_left = 0.0
	warning_retry_sent = false
	_clear_target_warning()
	_clear_proxy_target_warning()
	_reset_ranged_attack_position_state()


func _die() -> void:
	_cancel_windup(false)
	super._die()


func play_multiplayer_death_sequence() -> void:
	latest_proxy_action_id += 1
	_clear_proxy_target_warning()
	super.play_multiplayer_death_sequence()


func _update_attack_cooldown(delta: float) -> void:
	if initial_attack_stagger_left > 0.0:
		initial_attack_stagger_left = maxf(initial_attack_stagger_left - delta, 0.0)
	if attack_cooldown_left > 0.0:
		attack_cooldown_left = maxf(attack_cooldown_left - delta, 0.0)
	if attack_target_refresh_left > 0.0:
		attack_target_refresh_left = maxf(attack_target_refresh_left - delta, 0.0)


func _try_start_windup(
	attack_target: Node2D,
	lightning_config: LightningConfig
) -> bool:
	if attack_cooldown_left > 0.0:
		return false
	var priority_target := get_resolved_combat_target()
	if priority_target != null:
		attack_target = priority_target
	else:
		attack_target = get_resolved_combat_target(
			_select_nearest_attack_target(
				attack_target,
				lightning_config,
				true
			)
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
	cast_damage_source_snapshot = create_damage_source_snapshot(
		_get_multiplayer_damage_source_id(action_sequence + 1),
		DAMAGE_SOURCE_TYPE
	)
	windup_time_left = maxf(lightning_config.windup_duration, 0.01)
	cast_direction = global_position.direction_to(attack_target.global_position)
	if cast_direction == Vector2.ZERO:
		cast_direction = Vector2.RIGHT
	velocity = Vector2.ZERO
	_set_ranged_attack_position_held(true)
	_update_facing(cast_direction)
	cast_pivot.rotation = cast_direction.angle()
	_play_config_animation(lightning_config.windup_animation_name)
	warning_retry_time_left = minf(
		TARGET_WARNING_RETRY_DELAY,
		windup_time_left
	)
	warning_retry_sent = false
	_start_target_warning(
		cast_target,
		lightning_config.windup_duration,
		lightning_config.chain_range
	)
	_broadcast_windup_start(cast_target, false)
	return true


func _update_windup(delta: float) -> void:
	var lightning_config := config as LightningConfig
	if (
		lightning_config == null
		or not _is_frozen_source_hostile_target_valid(cast_target)
	):
		_cancel_windup()
		return
	var safe_attack_range := maxf(lightning_config.attack_range, 0.0)
	if (
		global_position.distance_squared_to(cast_target.global_position)
		> safe_attack_range * safe_attack_range
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
	var progress := 1.0 - windup_time_left / maxf(
		lightning_config.windup_duration,
		0.01
	)
	_update_target_warning(cast_target, progress)
	_update_windup_warning_retry(delta)
	if windup_time_left > 0.0:
		return
	if not _has_ranged_combat_line(cast_target, WORLD_COLLISION_MASK, true):
		_cancel_windup()
		return
	_finish_windup_and_strike(lightning_config)


func _finish_windup_and_strike(lightning_config: LightningConfig) -> void:
	if cast_damage_source_snapshot == null:
		cast_damage_source_snapshot = create_damage_source_snapshot(
			_get_multiplayer_damage_source_id(action_sequence),
			DAMAGE_SOURCE_TYPE
		)
	var first_target := cast_target
	_clear_target_warning()
	_play_config_animation(lightning_config.attack_animation_name)
	_broadcast_enemy_action(&"fire", cast_direction)
	_broadcast_windup_presentation_state(
		Enemy.TargetPresentationPhase.NONE,
		null,
		0.0
	)
	var damage_source_id := cast_damage_source_snapshot.event_source_id
	var world_path := _resolve_chain_hits(
		first_target,
		lightning_config,
		damage_source_id
	)
	if world_path.size() >= 2:
		if combat_runtime != null and is_instance_valid(combat_runtime):
			LightningVfx.try_spawn(combat_runtime, world_path)
		if gameplay_gateway != null and is_instance_valid(gameplay_gateway):
			gameplay_gateway.broadcast_enemy_lightning_chain(world_path)
	attack_cooldown_left = maxf(lightning_config.attack_interval, 0.01)
	combat_state = CombatState.CHASE
	windup_time_left = 0.0
	warning_retry_time_left = 0.0
	warning_retry_sent = false
	cast_target = null
	cast_damage_source_snapshot = null


func _resolve_chain_hits(
	first_target: Node2D,
	lightning_config: LightningConfig,
	damage_source_id: int
) -> PackedVector2Array:
	if cast_damage_source_snapshot == null:
		cast_damage_source_snapshot = create_damage_source_snapshot(
			damage_source_id,
			DAMAGE_SOURCE_TYPE
		)
	_chain_world_path.clear()
	_chain_world_path.append(staff_tip.global_position)
	_chain_excluded_instance_ids.clear()
	var current_target := first_target
	var current_target_was_prevalidated := false
	var previous_hit_position := staff_tip.global_position
	var maximum_hits := 1 + clampi(lightning_config.max_chain_bounces, 0, 4)
	_collect_chain_candidates(first_target, lightning_config, maximum_hits)
	var outgoing_damage := get_effective_attack_damage(
		lightning_config.attack_damage
	)
	for _hit_index in range(maximum_hits):
		if (
			current_target == null
			or not is_instance_valid(current_target)
			or (
				not current_target_was_prevalidated
				and not _is_frozen_source_hostile_target_valid(current_target)
			)
		):
			break
		var hit_position := current_target.global_position
		var target_instance_id := int(current_target.get_instance_id())
		_chain_excluded_instance_ids[target_instance_id] = true
		_chain_world_path.append(hit_position)
		# Chaining follows the authoritative contact sequence, not whether this
		# particular damage submission changed health. Invulnerability, multiplayer
		# de-duplication or another ability policy must not silently stop traversal.
		_apply_chain_damage(
			current_target,
			outgoing_damage,
			damage_source_id,
			previous_hit_position
		)
		previous_hit_position = hit_position
		if _chain_world_path.size() >= maximum_hits + 1:
			break
		current_target = _find_next_chain_target(
			hit_position,
			lightning_config.chain_range
		)
		current_target_was_prevalidated = true
	return _chain_world_path


func _collect_chain_candidates(
	first_target: Node2D,
	lightning_config: LightningConfig,
	maximum_hits: int
) -> void:
	_chain_candidates.clear()
	if (
		combat_runtime == null
		or not is_instance_valid(combat_runtime)
		or first_target == null
		or not is_instance_valid(first_target)
		or maximum_hits <= 1
	):
		return
	var maximum_chain_reach := (
		maxf(lightning_config.chain_range, 0.0)
		* float(maximum_hits - 1)
	)
	combat_runtime.query_hostile_enemy_attack_targets_world_into(
		first_target.global_position,
		maximum_chain_reach,
		_get_frozen_attack_source_faction_id(),
		_chain_candidates,
		self,
		0
	)


func _find_next_chain_target(
	from_position: Vector2,
	chain_range: float
) -> Node2D:
	var safe_chain_range := maxf(chain_range, 0.0)
	var maximum_distance_squared := safe_chain_range * safe_chain_range
	var best: Node2D = null
	var best_distance_squared := INF
	var query_facade := combat_runtime.get_combat_query_facade()
	for candidate in _chain_candidates:
		var candidate_distance_squared := from_position.distance_squared_to(
			candidate.global_position
		) if candidate != null and is_instance_valid(candidate) else INF
		if (
			candidate == null
			or not is_instance_valid(candidate)
			or _chain_excluded_instance_ids.has(candidate.get_instance_id())
			or not _is_frozen_source_hostile_target_valid(candidate)
			or candidate_distance_squared > maximum_distance_squared
		):
			continue
		if (
			best == null
			or candidate_distance_squared < best_distance_squared
			or (
				candidate_distance_squared == best_distance_squared
				and query_facade.is_radius_candidate_before(
					candidate,
					best,
					from_position
				)
			)
		):
			best = candidate
			best_distance_squared = candidate_distance_squared
	return best


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
		var player_request := _make_chain_damage_request(
			damage,
			source_position,
			player_target.global_position
		)
		if not CombatDamageAdmission.is_admitted(
			player_request,
			player_target.get_combat_faction_id(),
			combat_relation_service
		):
			return false
		if (
			gameplay_gateway != null
			and is_instance_valid(gameplay_gateway)
			and gameplay_gateway.request_player_damage(
				damage_source_id,
				player_target.peer_id,
				damage,
				DAMAGE_SOURCE_TYPE,
				EnemyConfig.DamageType.MAGIC,
				source_direction,
				true,
				false,
				cast_damage_source_snapshot
			)
		):
			return true
		if not _has_explicit_singleplayer_authority():
			return false
		return player_target.apply_combat_damage(player_request).accepted

	var plant_target := target as PlantDefense
	if not _has_authoritative_runtime():
		return false
	var target_request := _make_chain_damage_request(
		damage,
		source_position,
		target.global_position
	)
	if plant_target != null:
		if plant_target.is_dead or plant_target.is_removing:
			return false
		return plant_target.apply_combat_damage(target_request).accepted
	var enemy_target := target as Enemy
	if enemy_target == null or enemy_target.is_dead:
		return false
	return enemy_target.apply_combat_damage(target_request).accepted


func _make_chain_damage_request(
	damage_amount: int,
	source_position: Vector2,
	target_position: Vector2
) -> DamageRequest:
	var impact_direction := source_position.direction_to(target_position)
	var request := DamageRequest.new(
		damage_amount,
		EnemyConfig.DamageType.MAGIC
	)
	request.with_source_snapshot(cast_damage_source_snapshot)
	request.with_directions(impact_direction, -impact_direction)
	request.with_flag(CombatTypes.DamageFlag.RANGED, true)
	return request


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


func _get_target_warning_world_position(target: Node2D) -> Vector2:
	var player_target := target as Player
	if player_target != null:
		return player_target.get_multiplayer_visual_global_position()
	var plant_target := target as PlantDefense
	if plant_target != null:
		return plant_target.get_lifecycle_vfx_global_position()
	return target.global_position


func _start_target_warning(
	target: Node2D,
	_duration: float,
	chain_danger_radius: float
) -> void:
	target_warning_chain_radius = maxf(chain_danger_radius, 0.0)
	_write_target_warning(
		_get_target_warning_world_position(target),
		0.0
	)


func _update_target_warning(target: Node2D, progress: float) -> void:
	_write_target_warning(
		_get_target_warning_world_position(target),
		progress
	)


func _clear_target_warning() -> void:
	var warning_system := _warning_presentation_system
	if (
		warning_system != null
		and is_instance_valid(warning_system)
		and warning_system.is_handle_live(target_warning_handle)
	):
		warning_system.release_warning(target_warning_handle)
	target_warning_handle = 0
	target_warning_chain_radius = 0.0


func _write_target_warning(world_position: Vector2, progress: float) -> bool:
	var warning_system := _get_enemy_warning_presentation_system()
	if warning_system == null:
		return false
	if not warning_system.is_handle_live(target_warning_handle):
		target_warning_handle = warning_system.acquire_lightning_warning(
			int(get_instance_id())
		)
	if not warning_system.is_handle_live(target_warning_handle):
		target_warning_handle = 0
		return false
	return warning_system.update_lightning_warning(
		target_warning_handle,
		world_position,
		clampf(progress, 0.0, 1.0),
		target_warning_chain_radius
	)


func _get_enemy_warning_presentation_system(
) -> EnemyWarningPresentationSystemScript:
	if (
		_warning_presentation_system != null
		and is_instance_valid(_warning_presentation_system)
	):
		return _warning_presentation_system
	_warning_presentation_system = null
	if combat_runtime == null or not is_instance_valid(combat_runtime):
		return null
	var combat_services := combat_runtime.get_enemy_combat_services()
	if combat_services == null:
		return null
	_warning_presentation_system = (
		combat_services.get_enemy_warning_presentation_system()
	)
	return _warning_presentation_system


func _broadcast_windup_start(target: Node2D, is_retry: bool) -> void:
	if not is_retry:
		_broadcast_enemy_target_action(PLAYER_WINDUP_ACTION, target)
		_broadcast_windup_presentation_state(
			Enemy.TargetPresentationPhase.LIGHTNING_WINDUP,
			target,
			windup_time_left
		)
		return

	# Windup starts are transient unreliable-ordered messages. A single retry
	# uses the same action id, so clients that saw the first packet ignore it
	# without resetting progress while clients that missed it still get a cue.
	if action_sequence <= 0:
		return
	if gameplay_gateway == null or not is_instance_valid(gameplay_gateway):
		return
	var net_id := int(get_meta("net_id", 0))
	gameplay_gateway.broadcast_enemy_target_action(
		net_id,
		PLAYER_WINDUP_RETRY_ACTION,
		target,
		global_position,
		action_sequence
	)


func _update_windup_warning_retry(delta: float) -> void:
	if warning_retry_sent:
		return
	warning_retry_time_left = maxf(warning_retry_time_left - maxf(delta, 0.0), 0.0)
	if warning_retry_time_left > 0.0:
		return
	warning_retry_sent = true
	if _is_ranged_combat_target_valid(cast_target):
		_broadcast_windup_start(cast_target, true)


func _cancel_windup(restore_move_animation := true) -> void:
	var had_active_windup := combat_state == CombatState.WINDUP
	combat_state = CombatState.CHASE
	windup_time_left = 0.0
	warning_retry_time_left = 0.0
	warning_retry_sent = false
	_clear_target_warning()
	cast_target = null
	cast_damage_source_snapshot = null
	var lightning_config := config as LightningConfig
	if restore_move_animation and lightning_config != null:
		_play_config_animation(lightning_config.move_animation_name)
	if had_active_windup and not is_dead:
		_broadcast_enemy_action(&"cancel", cast_direction)
		_broadcast_windup_presentation_state(
			Enemy.TargetPresentationPhase.NONE,
			null,
			0.0
		)
	_reset_ranged_attack_position_state()


func _broadcast_windup_presentation_state(
	phase: int,
	target: Node2D,
	duration_seconds: float
) -> void:
	if gameplay_gateway == null or not is_instance_valid(gameplay_gateway):
		return
	gameplay_gateway.broadcast_enemy_target_presentation_state(
		int(get_meta("net_id", 0)),
		phase,
		target,
		duration_seconds,
		global_position,
		action_sequence
	)


func play_multiplayer_enemy_target_action(
	action_name: StringName,
	target: Node2D,
	action_id: int
) -> void:
	play_multiplayer_enemy_target_action_with_context(
		action_name,
		target,
		global_position,
		action_id,
		0.0
	)


func play_multiplayer_enemy_target_action_with_context(
	action_name: StringName,
	target: Node2D,
	_action_position: Vector2,
	action_id: int,
	action_elapsed: float
) -> void:
	if (
		is_dead
		or target == null
		or not is_instance_valid(target)
		or not _is_live_multiplayer_proxy_target(target)
		or action_id <= latest_proxy_action_id
		or (
			action_name in [PLAYER_WINDUP_ACTION, PLAYER_WINDUP_RETRY_ACTION]
			and action_id <= latest_proxy_presentation_terminal_revision
		)
	):
		return
	if (
		action_name != PLAYER_WINDUP_ACTION
		and action_name != PLAYER_WINDUP_RETRY_ACTION
	):
		return
	latest_proxy_action_id = action_id
	var lightning_config := config as LightningConfig
	if lightning_config == null:
		return
	var initial_progress := _get_proxy_windup_initial_progress(
		action_name,
		lightning_config.windup_duration,
		action_elapsed
	)
	_start_proxy_target_warning(target, Vector2.ZERO, initial_progress, action_id)


func apply_multiplayer_target_presentation_state(
	phase: int,
	target: Node2D,
	_action_position: Vector2,
	state_revision: int,
	elapsed_seconds: float,
	remaining_seconds: float
) -> void:
	if (
		state_revision < latest_proxy_presentation_revision
		or (
			state_revision == latest_proxy_presentation_revision
			and phase != Enemy.TargetPresentationPhase.NONE
		)
	):
		return
	latest_proxy_presentation_revision = state_revision
	if phase == Enemy.TargetPresentationPhase.NONE:
		latest_proxy_presentation_terminal_revision = maxi(
			latest_proxy_presentation_terminal_revision,
			state_revision
		)
	if (
		phase != Enemy.TargetPresentationPhase.LIGHTNING_WINDUP
		or is_dead
		or target == null
		or not is_instance_valid(target)
	):
		_clear_proxy_target_warning()
		var clear_config := config as LightningConfig
		if (
			clear_config != null
			and animated_sprite.animation == clear_config.windup_animation_name
		):
			_play_config_animation(clear_config.move_animation_name)
		return
	# CH5 presentation state and CH7 action edges are independent ordered
	# streams. An equal-revision start may still receive this reliable repair,
	# but a fire/cancel terminal edge is authoritative and must not be reopened.
	if state_revision <= latest_proxy_terminal_action_id:
		return
	var lightning_config := config as LightningConfig
	if lightning_config == null:
		_clear_proxy_target_warning()
		return
	var total_duration := maxf(
		maxf(elapsed_seconds, 0.0) + maxf(remaining_seconds, 0.0),
		0.01
	)
	var initial_progress := clampf(
		maxf(elapsed_seconds, 0.0) / total_duration,
		0.0,
		1.0
	)
	_start_proxy_target_warning(
		target,
		Vector2.ZERO,
		initial_progress,
		state_revision
	)


func play_multiplayer_enemy_action(
	action_name: StringName,
	direction: Vector2,
	action_id: int
) -> void:
	play_multiplayer_enemy_action_with_context(
		action_name,
		direction,
		global_position,
		action_id,
		0.0
	)


func play_multiplayer_enemy_action_with_context(
	action_name: StringName,
	direction: Vector2,
	action_position: Vector2,
	action_id: int,
	action_elapsed: float
) -> void:
	if (
		is_dead
		or action_id <= latest_proxy_action_id
		or action_id < latest_proxy_presentation_terminal_revision
		or (
			action_name in [PLANT_WINDUP_ACTION, PLANT_WINDUP_RETRY_ACTION]
			and action_id <= latest_proxy_presentation_terminal_revision
		)
	):
		return
	if (
		action_name == PLANT_WINDUP_ACTION
		or action_name == PLANT_WINDUP_RETRY_ACTION
	):
		if not direction.is_finite() or not action_position.is_finite():
			return
		latest_proxy_action_id = action_id
		var plant_config := config as LightningConfig
		if plant_config == null:
			return
		var plant_initial_progress := _get_proxy_windup_initial_progress(
			action_name,
			plant_config.windup_duration,
			action_elapsed
		)
		_start_proxy_target_warning(
			null,
			action_position + direction,
			plant_initial_progress,
			action_id
		)
		return
	latest_proxy_action_id = action_id
	if action_name == &"fire" or action_name == &"cancel":
		latest_proxy_terminal_action_id = action_id
	var lightning_config := config as LightningConfig
	if lightning_config == null:
		return
	var safe_direction := (
		direction.normalized() if direction != Vector2.ZERO else Vector2.RIGHT
	)
	_update_facing(safe_direction)
	if action_name == &"fire":
		_clear_proxy_target_warning()
		_play_multiplayer_proxy_action_animation(
			lightning_config.attack_animation_name,
			_get_scene_animation_duration(
				lightning_config.attack_animation_name
			) + 0.05
		)
	elif action_name == &"cancel":
		_clear_proxy_target_warning()
		_play_config_animation(lightning_config.move_animation_name)


func _get_proxy_windup_initial_progress(
	action_name: StringName,
	duration: float,
	action_elapsed: float
) -> float:
	var safe_duration := maxf(duration, 0.01)
	var elapsed := maxf(action_elapsed, 0.0)
	if (
		action_name == PLAYER_WINDUP_RETRY_ACTION
		or action_name == PLANT_WINDUP_RETRY_ACTION
	):
		elapsed += minf(TARGET_WARNING_RETRY_DELAY, safe_duration)
	return clampf(elapsed / safe_duration, 0.0, 1.0)


func _start_proxy_target_warning(
	target: Node2D,
	plant_world_position: Vector2,
	initial_progress: float,
	_state_revision: int
) -> void:
	var lightning_config := config as LightningConfig
	if lightning_config == null:
		return
	proxy_warning_target = target
	proxy_warning_plant_position = plant_world_position
	proxy_warning_duration = maxf(lightning_config.windup_duration, 0.01)
	proxy_warning_elapsed = clampf(initial_progress, 0.0, 1.0) * proxy_warning_duration
	var warning_position := (
		_get_target_warning_world_position(target)
		if target != null
		else plant_world_position
	)
	target_warning_chain_radius = maxf(lightning_config.chain_range, 0.0)
	_write_target_warning(
		warning_position,
		proxy_warning_elapsed / proxy_warning_duration
	)
	var direction := global_position.direction_to(warning_position)
	if direction == Vector2.ZERO:
		direction = Vector2.RIGHT
	cast_pivot.rotation = direction.angle()
	_update_facing(direction)
	var remaining_duration := maxf(
		proxy_warning_duration - proxy_warning_elapsed,
		0.01
	)
	_play_multiplayer_proxy_action_animation(
		lightning_config.windup_animation_name,
		remaining_duration + 0.15
	)
	set_process(true)
	proxy_warning_generation += 1
	_schedule_proxy_windup_timeout(
		proxy_warning_generation,
		remaining_duration + 0.2
	)


func _update_proxy_target_warning(delta: float) -> void:
	if proxy_warning_duration <= 0.0:
		set_process(false)
		return
	var warning_position := proxy_warning_plant_position
	if proxy_warning_target != null:
		if (
			not is_instance_valid(proxy_warning_target)
			or not _is_live_multiplayer_proxy_target(proxy_warning_target)
		):
			_clear_proxy_target_warning()
			return
		warning_position = _get_target_warning_world_position(proxy_warning_target)
	proxy_warning_elapsed = minf(
		proxy_warning_elapsed + maxf(delta, 0.0),
		proxy_warning_duration
	)
	_write_target_warning(
		warning_position,
		proxy_warning_elapsed / maxf(proxy_warning_duration, 0.01)
	)
	var direction := global_position.direction_to(warning_position)
	if direction == Vector2.ZERO:
		direction = Vector2.RIGHT
	cast_pivot.rotation = direction.angle()
	_update_facing(direction)


func _clear_proxy_target_warning() -> void:
	proxy_warning_generation += 1
	proxy_warning_target = null
	proxy_warning_plant_position = Vector2.ZERO
	proxy_warning_duration = 0.0
	proxy_warning_elapsed = 0.0
	_clear_target_warning()
	if is_multiplayer_proxy:
		set_process(false)


func _schedule_proxy_windup_timeout(generation: int, timeout: float) -> void:
	if not is_inside_tree():
		return
	var timeout_tween := create_tween()
	timeout_tween.tween_interval(maxf(timeout, 0.01))
	timeout_tween.tween_callback(_expire_proxy_windup.bind(generation))


func _expire_proxy_windup(generation: int) -> void:
	if generation != proxy_warning_generation or is_dead or config == null:
		return
	_clear_proxy_target_warning()
	var lightning_config := config as LightningConfig
	if (
		lightning_config != null
		and animated_sprite.animation == lightning_config.windup_animation_name
	):
		_play_config_animation(lightning_config.move_animation_name)


func _exit_tree() -> void:
	_clear_target_warning()
	_warning_presentation_system = null
	super._exit_tree()
