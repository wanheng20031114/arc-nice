extends "res://scene/enemy/capoo_ranged_enemy.gd"
class_name CapooSniper

const SniperConfig := preload("res://resources/config/enemies/capoo_sniper_config.gd")
const EnemyWarningPresentationSystemScript := preload(
	"res://scene/combat/presentation/enemy_warning_presentation_system.gd"
)
const ENEMY_ATTACK_AUDIO_LIMITER := preload(
	"res://scene/combat/audio/enemy_attack_audio_limiter.gd"
)
const AIM_LINE_START_DISTANCE := 10.0
const AIM_LINE_TARGET_PADDING := 10.0
const AIM_LINE_MIN_LENGTH := 8.0
# Dynamic enemies and plants share the existing positional wire actions. This
# keeps protocol-v93 peers compatible while making the semantics non-player
# rather than plant-specific inside the authoritative state machine.
const ACTION_NON_PLAYER_LOCK_START := &"sniper_plant_lock_start"
const ACTION_NON_PLAYER_LOCK_CANCEL := &"sniper_plant_lock_cancel"
const ACTION_NON_PLAYER_LOCK_FIRE := &"sniper_plant_lock_fire"

enum CombatState {
	CHASE,
	LOCK,
}

@onready var attack_audio: AudioStreamPlayer2D = $AttackAudio

var combat_state: CombatState = CombatState.CHASE
var attack_cooldown_left: float = 0.0
var lock_time_left: float = 0.0
var locked_target: Node2D = null
var locked_player: Player = null
var locked_non_player_target := false
var locked_non_player_target_offset := Vector2.ZERO
var lock_damage_source_snapshot: DamageSourceSnapshot = null
var sniper_line_warning_handle: int = 0
var sniper_reticle_warning_handle: int = 0
var sniper_reticle_target_id: int = 0
var _warning_presentation_system: EnemyWarningPresentationSystemScript = null
var latest_proxy_target_action_id: int = 0
var latest_proxy_action_id: int = 0
var proxy_locked_player: Player = null
var proxy_plant_lock_active := false
var proxy_locked_plant_position := Vector2.ZERO
var proxy_lock_duration: float = 0.0
var proxy_lock_elapsed: float = 0.0


func _ready() -> void:
	super._ready()


func _physics_process(delta: float) -> void:
	if is_dead:
		velocity = Vector2.ZERO
		return

	_update_touch_damage(delta)
	_update_attack_cooldown(delta)

	if combat_state == CombatState.LOCK:
		_update_lock(delta)
		return

	var sniper_config := config as SniperConfig
	var preferred_target := _get_preferred_ranged_combat_target()
	if (
		sniper_config != null
		and _try_hold_ranged_attack_position(
			preferred_target,
			sniper_config.attack_range,
			WORLD_COLLISION_MASK
		)
	):
		if _try_start_lock(preferred_target):
			return
		if _try_hold_ranged_attack_position(
			preferred_target,
			sniper_config.attack_range,
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


func _process(delta: float) -> void:
	super._process(delta)
	if is_multiplayer_proxy:
		_update_proxy_lock_visual(delta)


func configure_multiplayer_proxy() -> void:
	super.configure_multiplayer_proxy()
	set_process(true)


func _apply_config() -> void:
	super._apply_config()
	combat_state = CombatState.CHASE
	attack_cooldown_left = 0.0
	lock_time_left = 0.0
	locked_target = null
	locked_player = null
	locked_non_player_target = false
	locked_non_player_target_offset = Vector2.ZERO
	lock_damage_source_snapshot = null
	_reset_ranged_attack_position_state()
	_clear_proxy_lock_visual()
	var sniper_config := config as SniperConfig
	if sniper_config != null:
		attack_audio.stream = sniper_config.attack_audio_stream


func _die() -> void:
	_cancel_lock()
	super._die()


func play_multiplayer_death_sequence() -> void:
	_clear_proxy_lock_visual()
	super.play_multiplayer_death_sequence()


func _update_attack_cooldown(delta: float) -> void:
	if attack_cooldown_left > 0.0:
		attack_cooldown_left = maxf(attack_cooldown_left - delta, 0.0)


func _try_start_lock(candidate_target: Node2D = null) -> bool:
	var sniper_config := config as SniperConfig
	if sniper_config == null:
		return false
	if attack_cooldown_left > 0.0:
		return false
	if candidate_target == null:
		candidate_target = _get_preferred_ranged_combat_target()
	if candidate_target == null:
		return false
	if not _is_ranged_combat_target_in_range(
		candidate_target,
		sniper_config.attack_range
	):
		return false
	if not _has_ranged_combat_line(
		candidate_target,
		WORLD_COLLISION_MASK,
		true
	):
		_reset_ranged_attack_position_state()
		return false

	combat_state = CombatState.LOCK
	locked_target = candidate_target
	locked_player = candidate_target as Player
	locked_non_player_target = locked_player == null
	locked_non_player_target_offset = (
		locked_target.global_position - global_position
		if locked_non_player_target
		else Vector2.ZERO
	)
	lock_damage_source_snapshot = create_damage_source_snapshot(
		_get_multiplayer_damage_source_id(action_sequence + 1),
		&"capoo_sniper_lock"
	)
	lock_time_left = maxf(sniper_config.lock_duration, 0.01)
	velocity = Vector2.ZERO
	_set_ranged_attack_position_held(true)
	var lock_direction := global_position.direction_to(locked_target.global_position)
	_update_facing(lock_direction)
	_play_config_animation(sniper_config.aim_animation_name)
	_start_lock_warning(locked_target, locked_target.global_position)
	if locked_player != null:
		_broadcast_enemy_target_action(&"sniper_lock_start", locked_player.peer_id)
	else:
		_broadcast_enemy_action(
			ACTION_NON_PLAYER_LOCK_START,
			locked_non_player_target_offset
		)
	return true


func _update_lock(delta: float) -> void:
	var sniper_config := config as SniperConfig
	if (
		sniper_config == null
		or not _is_lock_target_valid(sniper_config)
	):
		_cancel_lock()
		return

	velocity = Vector2.ZERO
	var direction := global_position.direction_to(locked_target.global_position)
	if locked_non_player_target:
		locked_non_player_target_offset = (
			locked_target.global_position - global_position
		)
	if direction == Vector2.ZERO:
		direction = Vector2.RIGHT
	_update_facing(direction)
	lock_time_left = maxf(lock_time_left - delta, 0.0)
	var progress := 1.0 - lock_time_left / maxf(sniper_config.lock_duration, 0.01)
	_update_lock_warning(locked_target.global_position, progress)

	if lock_time_left > 0.0:
		return

	_fire_locked_shot(direction)


func _is_lock_target_valid(sniper_config: SniperConfig) -> bool:
	return _is_ranged_combat_target_in_range(
		locked_target,
		sniper_config.attack_range
	)


func _fire_locked_shot(direction: Vector2) -> void:
	var sniper_config := config as SniperConfig
	if (
		sniper_config == null
		or not _is_ranged_combat_target_in_range(
			locked_target,
			sniper_config.attack_range
		)
		or not _has_ranged_combat_line(
			locked_target,
			WORLD_COLLISION_MASK,
			true
		)
	):
		_cancel_lock()
		return

	attack_cooldown_left = maxf(sniper_config.attack_interval, 0.01)
	var outgoing_damage := get_effective_attack_damage(sniper_config.attack_damage)
	var locked_plant := locked_target as PlantDefense
	if locked_plant != null:
		locked_plant.apply_combat_damage(
			_make_lock_damage_request(outgoing_damage, -direction)
		)
	elif locked_player != null:
		var player_request := _make_lock_damage_request(
			outgoing_damage,
			direction
		)
		var reported := false
		if CombatDamageAdmission.is_admitted(
			player_request,
			locked_player.get_combat_faction_id(),
			combat_relation_service
		):
			reported = (
				gameplay_gateway != null
				and is_instance_valid(gameplay_gateway)
				and gameplay_gateway.request_player_damage(
					lock_damage_source_snapshot.event_source_id,
					locked_player.peer_id,
					outgoing_damage,
					&"capoo_sniper_lock",
					EnemyConfig.DamageType.PHYSICAL,
					-direction,
					true,
					false,
					lock_damage_source_snapshot
				)
			)
		if not reported and _has_explicit_singleplayer_authority():
			locked_player.apply_combat_damage(player_request)
	else:
		var locked_enemy := locked_target as Enemy
		if locked_enemy != null:
			locked_enemy.apply_combat_damage(
				_make_lock_damage_request(outgoing_damage, direction)
			)
	if sniper_config.attack_audio_stream != null:
		attack_audio.pitch_scale = random_generator.randf_range(0.96, 1.03)
		ENEMY_ATTACK_AUDIO_LIMITER.play_heavy_attack(attack_audio)
	if locked_player != null:
		_broadcast_enemy_target_action(&"sniper_lock_fire", locked_player.peer_id)
	else:
		_broadcast_enemy_action(
			ACTION_NON_PLAYER_LOCK_FIRE,
			locked_non_player_target_offset
		)
	_clear_lock_warning()
	locked_target = null
	locked_player = null
	locked_non_player_target = false
	locked_non_player_target_offset = Vector2.ZERO
	lock_damage_source_snapshot = null
	combat_state = CombatState.CHASE
	_play_config_animation(sniper_config.move_animation_name)


func _cancel_lock() -> void:
	if locked_player != null and is_instance_valid(locked_player):
		_broadcast_enemy_target_action(&"sniper_lock_cancel", locked_player.peer_id)
	elif locked_non_player_target:
		_broadcast_enemy_action(
			ACTION_NON_PLAYER_LOCK_CANCEL,
			locked_non_player_target_offset
		)
	combat_state = CombatState.CHASE
	lock_time_left = 0.0
	locked_target = null
	locked_player = null
	locked_non_player_target = false
	locked_non_player_target_offset = Vector2.ZERO
	lock_damage_source_snapshot = null
	_clear_lock_warning()
	_reset_ranged_attack_position_state()
	var sniper_config := config as SniperConfig
	if sniper_config != null:
		_play_config_animation(sniper_config.move_animation_name)


func _make_lock_damage_request(
	outgoing_damage: int,
	direction: Vector2
) -> DamageRequest:
	var request := DamageRequest.new(
		outgoing_damage,
		EnemyConfig.DamageType.PHYSICAL
	)
	request.with_source_snapshot(lock_damage_source_snapshot)
	request.with_directions(direction, -direction)
	request.with_flag(CombatTypes.DamageFlag.RANGED, true)
	return request


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
				proxy_locked_player = target
				proxy_lock_duration = maxf(sniper_config.lock_duration, 0.01)
				proxy_lock_elapsed = 0.0
				_start_lock_warning(target, target.global_position)
	elif action_name == &"sniper_lock_cancel" or action_name == &"sniper_lock_fire":
		_clear_proxy_lock_visual()


func play_multiplayer_enemy_action(
	action_name: StringName,
	target_offset: Vector2,
	action_id: int
) -> void:
	if action_id <= latest_proxy_action_id:
		return
	latest_proxy_action_id = action_id
	if action_name == ACTION_NON_PLAYER_LOCK_START:
		var sniper_config := config as SniperConfig
		if sniper_config == null:
			return
		proxy_locked_player = null
		proxy_plant_lock_active = true
		proxy_locked_plant_position = global_position + target_offset
		proxy_lock_duration = maxf(sniper_config.lock_duration, 0.01)
		proxy_lock_elapsed = 0.0
		_play_multiplayer_proxy_action_animation(
			sniper_config.aim_animation_name,
			sniper_config.lock_duration + 0.15
		)
		var direction := target_offset.normalized()
		if direction == Vector2.ZERO:
			direction = Vector2.RIGHT
		_update_facing(direction)
		_start_lock_warning(
			null,
			proxy_locked_plant_position
		)
	elif (
		action_name == ACTION_NON_PLAYER_LOCK_CANCEL
		or action_name == ACTION_NON_PLAYER_LOCK_FIRE
	):
		_clear_proxy_lock_visual()


func _update_proxy_lock_visual(delta: float) -> void:
	var target_position := Vector2.ZERO
	if proxy_locked_player != null and is_instance_valid(proxy_locked_player):
		target_position = proxy_locked_player.global_position
	elif proxy_plant_lock_active:
		target_position = proxy_locked_plant_position
	else:
		_clear_proxy_lock_visual()
		return
	var sniper_config := config as SniperConfig
	if sniper_config == null:
		_clear_proxy_lock_visual()
		return
	proxy_lock_duration = maxf(proxy_lock_duration, 0.01)
	proxy_lock_elapsed = minf(proxy_lock_elapsed + maxf(delta, 0.0), proxy_lock_duration)
	var progress := clampf(proxy_lock_elapsed / proxy_lock_duration, 0.0, 1.0)
	var direction := global_position.direction_to(target_position)
	if direction == Vector2.ZERO:
		direction = Vector2.RIGHT
	_update_facing(direction)
	_update_lock_warning(target_position, progress)


func _clear_proxy_lock_visual() -> void:
	proxy_locked_player = null
	proxy_plant_lock_active = false
	proxy_locked_plant_position = Vector2.ZERO
	proxy_lock_duration = 0.0
	proxy_lock_elapsed = 0.0
	_clear_lock_warning()


func _start_lock_warning(
	target: Node2D,
	target_world_position: Vector2,
	target_id: int = 0
) -> void:
	_clear_lock_warning()
	var resolved_target_id := target_id
	if resolved_target_id <= 0 and target != null:
		resolved_target_id = _get_warning_target_id(target)
	_acquire_lock_warning(resolved_target_id)
	_update_lock_warning_channels(target_world_position, 0.35, 0.0)


func _update_lock_warning(
	target_world_position: Vector2,
	progress: float
) -> void:
	_update_lock_warning_channels(
		target_world_position,
		progress,
		progress
	)


func _acquire_lock_warning(target_id: int) -> void:
	sniper_reticle_target_id = target_id
	var warning_system := _get_warning_system()
	if warning_system == null:
		return
	var owner_id := _get_warning_owner_id()
	sniper_line_warning_handle = warning_system.acquire_sniper_line(owner_id)
	if target_id > 0:
		sniper_reticle_warning_handle = warning_system.acquire_sniper_reticle(
			owner_id,
			target_id
		)


func _update_lock_warning_channels(
	target_world_position: Vector2,
	line_progress: float,
	reticle_progress: float
) -> void:
	var warning_system := _get_warning_system()
	if warning_system == null:
		return
	if not warning_system.is_handle_live(sniper_line_warning_handle):
		sniper_line_warning_handle = warning_system.acquire_sniper_line(
			_get_warning_owner_id()
		)
	if (
		sniper_reticle_target_id > 0
		and not warning_system.is_handle_live(sniper_reticle_warning_handle)
	):
		sniper_reticle_warning_handle = warning_system.acquire_sniper_reticle(
			_get_warning_owner_id(),
			sniper_reticle_target_id
		)
	var warning_direction := global_position.direction_to(target_world_position)
	var target_distance := global_position.distance_to(target_world_position)
	if warning_direction == Vector2.ZERO:
		warning_direction = Vector2.RIGHT
		target_distance = AIM_LINE_MIN_LENGTH
	var line_start := global_position + warning_direction * minf(
		AIM_LINE_START_DISTANCE,
		target_distance * 0.35
	)
	var line_end := target_world_position - warning_direction * minf(
		AIM_LINE_TARGET_PADDING,
		target_distance * 0.25
	)
	if warning_system.is_handle_live(sniper_line_warning_handle):
		warning_system.update_sniper_line(
			sniper_line_warning_handle,
			line_start,
			line_end,
			clampf(line_progress, 0.0, 1.0)
		)
	if warning_system.is_handle_live(sniper_reticle_warning_handle):
		warning_system.update_sniper_reticle(
			sniper_reticle_warning_handle,
			target_world_position,
			clampf(reticle_progress, 0.0, 1.0)
		)


func _clear_lock_warning() -> void:
	var warning_system := _warning_presentation_system
	if warning_system != null and is_instance_valid(warning_system):
		if warning_system.is_handle_live(sniper_line_warning_handle):
			warning_system.release_warning(sniper_line_warning_handle)
		if warning_system.is_handle_live(sniper_reticle_warning_handle):
			warning_system.release_warning(sniper_reticle_warning_handle)
	sniper_line_warning_handle = 0
	sniper_reticle_warning_handle = 0
	sniper_reticle_target_id = 0


func _get_warning_system() -> EnemyWarningPresentationSystemScript:
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


func _get_warning_owner_id() -> int:
	if combat_target_index_net_id > 0:
		return combat_target_index_net_id
	var authored_net_id := int(get_meta(&"net_id", 0))
	if authored_net_id > 0:
		return authored_net_id
	return int(get_instance_id())


func _get_warning_target_id(target: Node2D) -> int:
	# Reticle arbitration is local presentation scoped to the exact target node.
	# Network ids from players, plants, and enemies occupy different domains and
	# may collide numerically, while every sniper on this client observes the
	# same target ObjectID.
	return int(target.get_instance_id())


func _exit_tree() -> void:
	_clear_lock_warning()
	_warning_presentation_system = null
	super._exit_tree()
