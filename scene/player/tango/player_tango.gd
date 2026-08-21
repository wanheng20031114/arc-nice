extends Player
class_name PlayerTango

enum CastingState {
	ORBIT,
	CHARGING,
	CONVERGING,
	FIRING,
	RETURNING,
}

const LASER_BULLET_SCENE := preload(
	"res://scene/player/tango/tango_laser_bullet.tscn"
)
const ELECTRIC_SURGE_FIELD_SCENE := preload(
	"res://scene/player/tango/tango_electric_surge_field.tscn"
)
const LASER_BULLET_TYPE: StringName = &"tango_laser_bullet"
const MIN_CHARGE_DURATION := 0.2
const MAX_CHARGE_DURATION := 2.4
const LOW_CHARGE_DAMAGE_THRESHOLD := 0.5
const LOW_CHARGE_DAMAGE_MULTIPLIER := 0.75
const NORMAL_CHARGE_DAMAGE_MULTIPLIER := 1.0
const FULL_CHARGE_DAMAGE_MULTIPLIER := 1.5
const MIN_BARRAGE_DURATION := 2.0
const MAX_BARRAGE_DURATION := 5.0
const CHARGE_THRESHOLD_EPSILON := 0.0001
const INVALID_CHARGE_RATIO := -1.0
const UNIT_ORBIT_RADIUS := Vector2(14.0, 8.0)
const UNIT_ORBIT_PERIOD := 6.0
const UNIT_CONVERGE_DURATION := 0.14
const UNIT_RETURN_DURATION := 0.18
const UNIT_PHASE_STEP := TAU / 3.0
const UNIT_FORWARD_ROTATION_OFFSET := PI / 2.0
const UNIT_CHARGE_MIN_SPEED_SCALE := 0.55
const UNIT_CHARGE_MAX_SPEED_SCALE := 2.25
const UNIT_FIRE_FORWARD_OFFSETS := [19.0, 17.0, 18.0]
const UNIT_FIRE_LATERAL_OFFSETS := [0.0, 5.0, -5.0]
const PROJECTILE_MUZZLE_DISTANCE := 6.0
const PROJECTILES_PER_VOLLEY := 3
const BARRAGE_EPSILON := 0.0001
const ELECTRIC_SURGE_DURATION := 8.0
const ELECTRIC_SURGE_FIRE_RATE_MULTIPLIER := 1.5
const ELECTRIC_SURGE_ATTACHED_DAMAGE_MULTIPLIER := 1.2
const ELECTRIC_SURGE_REMOTE_CAST_AUDIO_WINDOW := 1.0

@onready var casting_units: Node2D = $CastingUnits
@onready var unit_a: AnimatedSprite2D = $CastingUnits/UnitA
@onready var unit_b: AnimatedSprite2D = $CastingUnits/UnitB
@onready var unit_c: AnimatedSprite2D = $CastingUnits/UnitC
@onready var electric_surge_duration_timer: Timer = $ElectricSurgeDurationTimer
@onready var snow_wolf_full_charge_timer: Timer = $SnowWolfFullChargeTimer
@onready var primary_attack_audio: AudioStreamPlayer2D = get_node_or_null(
	"PrimaryAttackAudio"
) as AudioStreamPlayer2D
@onready var charge_audio: AudioStreamPlayer2D = get_node_or_null(
	"ChargeAudio"
) as AudioStreamPlayer2D
@onready var unit_converge_audio: AudioStreamPlayer2D = get_node_or_null(
	"UnitConvergeAudio"
) as AudioStreamPlayer2D
@onready var unit_return_audio: AudioStreamPlayer2D = get_node_or_null(
	"UnitReturnAudio"
) as AudioStreamPlayer2D
@onready var electric_surge_audio: AudioStreamPlayer2D = get_node_or_null(
	"ElectricSurgeAudio"
) as AudioStreamPlayer2D

var _casting_state := CastingState.ORBIT
var _casting_unit_sprites: Array[AnimatedSprite2D] = []
var _unit_orbit_phase := 0.0
var _unit_converge_elapsed := 0.0
var _unit_converge_starts: Array[Vector2] = []
var _unit_converge_start_rotations: Array[float] = []
var _unit_return_elapsed := 0.0
var _unit_return_starts: Array[Vector2] = []
var _unit_return_start_rotations: Array[float] = []
var _unit_fire_layout_ready := false
var _unit_fire_layout_direction := Vector2.RIGHT
var _charge_elapsed := 0.0
var _charge_direction := Vector2.RIGHT
var _local_charge_input_active := false
var _barrage_direction := Vector2.RIGHT
var _barrage_charge_ratio := 0.0
var _barrage_charge_seconds := 0.0
var _barrage_damage_multiplier := NORMAL_CHARGE_DAMAGE_MULTIPLIER
var _barrage_duration := 0.0
var _barrage_elapsed := 0.0
var _barrage_next_volley_time := 0.0
var _barrage_damage_snapshot := 0
var _barrage_is_authoritative := false
var _barrage_volley_count := 0
var _attack_aim_uses_mouse := false
var _requires_neutral_before_charge := false
var _latest_remote_action_sequence := 0
var _latest_remote_action_phase := 0
var _casting_units_base_position := Vector2.ZERO
var _electric_surge_active := false
var _electric_surge_authoritative := false
var _electric_surge_activation_id := 0
var _electric_surge_last_seen_activation_id := 0
var _electric_surge_origin := Vector2.ZERO
var _electric_surge_auto_fire_activation_id := 0
var _electric_surge_auto_fire_charge_sequence := 0
var _empowered_auto_fire_charge_sequence := 0
var _empowered_auto_fire_finished_barrage_sequence := 0


func _init() -> void:
	character_id = &"tango"
	skill1_unlocked = true


func is_tango() -> bool:
	return true


func uses_attack_interval_bar() -> bool:
	return true


func supports_projectile_attack_patterns() -> bool:
	# Tango's three-cannon volley has one atomic network contract. Projectile-only
	# piercing/homing collectibles stay disabled until those per-shot parameters
	# are represented by the batch RPC instead of diverging between peers.
	return false


func supports_research_technology() -> bool:
	return true


func _apply_character_pickup(config: PickupConfig, _buff_duration: float) -> bool:
	if (
		config == null
		or config.pickup_type != PickupConfig.PickupType.SPIRAL
		or config.player_form_mode != PickupConfig.PlayerFormMode.ARMED
		or config.shot_pattern != PickupConfig.ShotPattern.SPIRAL
		or config.tango_full_charge_duration <= 0.0
		or snow_wolf_full_charge_timer == null
	):
		return false
	return _activate_snow_wolf_full_charge(
		config.tango_full_charge_duration,
		true,
		_should_run_authoritative_collectible_effects()
	)


func _activate_snow_wolf_full_charge(
	duration_seconds: float,
	refresh_duration: bool,
	authoritative: bool = false
) -> bool:
	if (
		snow_wolf_full_charge_timer == null
		or is_dead
		or are_combat_actions_locked()
	):
		return false
	var was_active := is_snow_wolf_full_charge_active()
	var previous_remaining_seconds := get_snow_wolf_full_charge_remaining_seconds()
	if refresh_duration or snow_wolf_full_charge_timer.is_stopped():
		snow_wolf_full_charge_timer.start(maxf(duration_seconds, 0.001))
	var initial_direction := _get_empowered_auto_fire_direction()
	var needs_new_sequence := not was_active or not is_tango_barrage_active()
	if (
		authoritative
		and needs_new_sequence
		and _requires_multiplayer_gameplay_gateway()
	):
		if gameplay_gateway == null:
			_restore_snow_wolf_lease_after_failed_activation(
				was_active,
				previous_remaining_seconds
			)
			return false
		var charge_sequence := (
			gameplay_gateway.begin_authoritative_tango_snow_wolf_auto_fire(
				self,
				initial_direction
			)
		)
		if charge_sequence <= 0:
			_restore_snow_wolf_lease_after_failed_activation(
				was_active,
				previous_remaining_seconds
			)
			return false
		_empowered_auto_fire_charge_sequence = maxi(
			_empowered_auto_fire_charge_sequence,
			charge_sequence
		)
	_ensure_empowered_auto_fire(initial_direction, authoritative)
	_refresh_empowered_attack_bar_state()
	_update_attack_interval_bar()
	return is_tango_empowered_auto_fire_active()


func _restore_snow_wolf_lease_after_failed_activation(
	was_active: bool,
	previous_remaining_seconds: float
) -> void:
	if was_active and previous_remaining_seconds > 0.0:
		snow_wolf_full_charge_timer.start(previous_remaining_seconds)
	else:
		snow_wolf_full_charge_timer.stop()


func is_snow_wolf_full_charge_active() -> bool:
	return (
		snow_wolf_full_charge_timer != null
		and not snow_wolf_full_charge_timer.is_stopped()
	)


func get_snow_wolf_full_charge_remaining_seconds() -> float:
	if not is_snow_wolf_full_charge_active():
		return 0.0
	return snow_wolf_full_charge_timer.time_left


func is_tango_empowered_auto_fire_active() -> bool:
	return _is_empowered_auto_fire_requested() and is_tango_barrage_active()


func _is_empowered_auto_fire_requested() -> bool:
	return is_snow_wolf_full_charge_active() or _electric_surge_active


func _get_empowered_auto_fire_remaining_seconds() -> float:
	return maxf(
		get_snow_wolf_full_charge_remaining_seconds(),
		get_electric_surge_remaining_seconds()
	)


func _get_empowered_auto_fire_direction() -> Vector2:
	var directional_input := _get_current_shoot_input()
	if directional_input.length_squared() > 0.001:
		if uses_local_input:
			_attack_aim_uses_mouse = false
		return _get_safe_tango_direction(directional_input)
	if uses_local_input:
		# Automatic barrages follow the pointer without requiring the attack button.
		_attack_aim_uses_mouse = true
		var mouse_direction := _get_mouse_shoot_direction()
		if mouse_direction.length_squared() > 0.001:
			return _get_safe_tango_direction(mouse_direction)
	else:
		_attack_aim_uses_mouse = false
	return _get_safe_tango_direction(last_attack_direction)


func _ensure_empowered_auto_fire(
	direction: Vector2,
	authoritative: bool
) -> void:
	if (
		not _is_empowered_auto_fire_requested()
		or is_dead
		or are_combat_actions_locked()
	):
		return
	var safe_direction := _get_safe_tango_direction(direction)
	if _casting_state == CastingState.CHARGING:
		_local_charge_input_active = false
		_cancel_charge_visual()
	if is_tango_barrage_active():
		_set_barrage_direction(safe_direction)
		_apply_barrage_release_profile(1.0)
		_barrage_is_authoritative = _barrage_is_authoritative or authoritative
		_refresh_empowered_auto_fire_lifetime()
		return
	_start_barrage_sequence(safe_direction, 1.0, authoritative)
	_refresh_empowered_auto_fire_lifetime()


func _refresh_empowered_auto_fire_lifetime() -> void:
	if not _is_empowered_auto_fire_requested() or not is_tango_barrage_active():
		return
	_barrage_duration = maxf(
		_barrage_elapsed + _get_empowered_auto_fire_remaining_seconds(),
		BARRAGE_EPSILON
	)


func _release_empowered_auto_fire_if_unrequested() -> void:
	if _is_empowered_auto_fire_requested():
		_refresh_empowered_auto_fire_lifetime()
		return
	_empowered_auto_fire_finished_barrage_sequence = maxi(
		_empowered_auto_fire_finished_barrage_sequence,
		maxi(
			_latest_remote_action_sequence,
			_empowered_auto_fire_charge_sequence
		)
	)
	_empowered_auto_fire_charge_sequence = 0
	_barrage_is_authoritative = false
	if _casting_state in [CastingState.CONVERGING, CastingState.FIRING]:
		_begin_return_to_orbit()


func _clear_snow_wolf_auto_fire_state() -> void:
	if snow_wolf_full_charge_timer != null:
		snow_wolf_full_charge_timer.stop()
	_release_empowered_auto_fire_if_unrequested()
	_refresh_empowered_attack_bar_state()
	_update_attack_interval_bar()


func _suspend_snow_wolf_auto_fire_for_lock() -> void:
	if not is_snow_wolf_full_charge_active() or not is_tango_barrage_active():
		return
	# Combat/life locks stop gameplay execution but do not consume the timed pickup
	# lease. Keep its sequence/remaining time so unlock/revive resumes the source.
	_barrage_is_authoritative = false
	_begin_return_to_orbit()


func _resume_snow_wolf_auto_fire_after_lock() -> void:
	if (
		not is_snow_wolf_full_charge_active()
		or is_dead
		or are_combat_actions_locked()
		or is_tango_barrage_active()
	):
		return
	_ensure_empowered_auto_fire(
		_get_empowered_auto_fire_direction(),
		_should_run_authoritative_collectible_effects()
	)
	_refresh_empowered_attack_bar_state()
	_update_attack_interval_bar()


func resolve_authoritative_tango_charge_progress_ratio(
	elapsed_seconds: float
) -> float:
	if _casting_state != CastingState.CHARGING or not is_finite(elapsed_seconds):
		return 0.0
	if is_snow_wolf_full_charge_active():
		return 1.0
	if _charge_elapsed >= MAX_CHARGE_DURATION - CHARGE_THRESHOLD_EPSILON:
		return 1.0
	return clampf(maxf(elapsed_seconds, 0.0) / MAX_CHARGE_DURATION, 0.0, 1.0)


func resolve_authoritative_tango_charge_release_ratio(
	elapsed_seconds: float
) -> float:
	if _casting_state != CastingState.CHARGING or not is_finite(elapsed_seconds):
		return INVALID_CHARGE_RATIO
	if is_snow_wolf_full_charge_active():
		return 1.0
	if _charge_elapsed >= MAX_CHARGE_DURATION - CHARGE_THRESHOLD_EPSILON:
		return 1.0
	if elapsed_seconds + CHARGE_THRESHOLD_EPSILON < MIN_CHARGE_DURATION:
		return INVALID_CHARGE_RATIO
	return _charge_elapsed_to_release_ratio(elapsed_seconds)


func set_research_technology_level(level: int) -> void:
	super.set_research_technology_level(level)
	if _electric_surge_active:
		_refresh_electric_surge_research_defense()


func _try_use_skill1() -> bool:
	if (
		not skill1_unlocked
		or is_dead
		or are_combat_actions_locked()
		or _electric_surge_active
	):
		return false
	_sync_skill1_charge_duration_to_upgrade_level()
	if not has_void_battery_charge() and skill1_charge < skill1_charge_duration:
		return false

	if _requires_multiplayer_gameplay_gateway():
		return (
			gameplay_gateway != null
			and gameplay_gateway.request_tango_electric_surge()
		)
	if not _is_explicit_singleplayer_authority():
		return false
	return try_start_authoritative_electric_surge(
		_electric_surge_last_seen_activation_id + 1,
		global_position
	)


func try_start_authoritative_electric_surge(
	activation_id: int,
	origin: Vector2,
	auto_fire_charge_sequence: int = 0
) -> bool:
	if (
		activation_id <= _electric_surge_last_seen_activation_id
		or _electric_surge_active
		or not is_finite(origin.x)
		or not is_finite(origin.y)
		or not _has_valid_combat_runtime()
	):
		return false
	var had_void_battery_charge := has_void_battery_charge()
	var previous_skill1_charge := skill1_charge
	if not try_begin_skill1_activation(true):
		return false
	var previous_last_seen_activation_id := _electric_surge_last_seen_activation_id
	_begin_electric_surge(
		activation_id,
		origin,
		ELECTRIC_SURGE_DURATION,
		true,
		auto_fire_charge_sequence
	)
	if not _spawn_authoritative_electric_surge_field(activation_id, origin):
		# Field creation is part of the authoritative transaction. Restore a usable
		# charge and activation sequence instead of leaving the player on cooldown
		# or making the Host retry the same id forever without the skill effect.
		_clear_electric_surge_state()
		_electric_surge_last_seen_activation_id = previous_last_seen_activation_id
		skill1_charge = previous_skill1_charge
		if had_void_battery_charge:
			void_battery_charged = true
		_update_skill1_charge_bar()
		return false
	_play_electric_surge_audio()
	_activate_collectible_skill_effects()
	return true


func play_remote_electric_surge_started(
	activation_id: int,
	origin: Vector2,
	remaining_seconds: float,
	spawn_visual: bool = true,
	auto_fire_charge_sequence: int = 0
) -> void:
	if (
		activation_id <= 0
		or not is_finite(origin.x)
		or not is_finite(origin.y)
		or not is_finite(remaining_seconds)
	):
		return
	var safe_remaining := clampf(
		remaining_seconds,
		0.0,
		ELECTRIC_SURGE_DURATION
	)
	if _electric_surge_active:
		if activation_id != _electric_surge_activation_id:
			return
		if auto_fire_charge_sequence > 0:
			_electric_surge_auto_fire_charge_sequence = maxi(
				_electric_surge_auto_fire_charge_sequence,
				auto_fire_charge_sequence
			)
		# A duplicate/recovery snapshot may shorten stale local time, but must never
		# extend an already-running replica when reliable packets are reordered.
		if (
			safe_remaining > 0.0
			and electric_surge_duration_timer.time_left > safe_remaining
		):
			electric_surge_duration_timer.start(safe_remaining)
		return
	if activation_id <= _electric_surge_last_seen_activation_id:
		return
	_electric_surge_last_seen_activation_id = activation_id
	if safe_remaining <= 0.0:
		return
	if spawn_visual:
		_spawn_remote_electric_surge_visual_field(
			activation_id,
			origin,
			safe_remaining
		)
	if is_dead or are_combat_actions_locked():
		return
	_begin_electric_surge(
		activation_id,
		origin,
		safe_remaining,
		false,
		auto_fire_charge_sequence
	)
	if (
		safe_remaining
		>= ELECTRIC_SURGE_DURATION - ELECTRIC_SURGE_REMOTE_CAST_AUDIO_WINDOW
	):
		_play_electric_surge_audio()


func is_electric_surge_active() -> bool:
	return _electric_surge_active


func is_electric_surge_auto_fire_active() -> bool:
	return (
		_electric_surge_active
		and _electric_surge_auto_fire_activation_id
			== _electric_surge_activation_id
		and is_tango_empowered_auto_fire_active()
	)


func get_electric_surge_activation_id() -> int:
	return _electric_surge_activation_id


func get_electric_surge_remaining_seconds() -> float:
	if not _electric_surge_active or electric_surge_duration_timer == null:
		return 0.0
	return electric_surge_duration_timer.time_left


func get_electric_surge_origin() -> Vector2:
	return _electric_surge_origin


func cancel_remote_electric_surge(activation_id: int) -> void:
	if (
		not _electric_surge_active
		or _electric_surge_authoritative
		or activation_id != _electric_surge_activation_id
	):
		return
	_clear_electric_surge_state()


func _begin_electric_surge(
	activation_id: int,
	origin: Vector2,
	duration: float,
	authoritative: bool,
	auto_fire_charge_sequence: int = 0
) -> void:
	_electric_surge_active = true
	_electric_surge_authoritative = authoritative
	_electric_surge_activation_id = activation_id
	_electric_surge_last_seen_activation_id = maxi(
		_electric_surge_last_seen_activation_id,
		activation_id
	)
	_electric_surge_origin = origin
	_electric_surge_auto_fire_charge_sequence = maxi(
		auto_fire_charge_sequence,
		0
	)
	if _casting_state == CastingState.CHARGING:
		_local_charge_input_active = false
		_cancel_charge_visual()
	electric_surge_duration_timer.start(
		clampf(duration, 0.01, ELECTRIC_SURGE_DURATION)
	)
	_refresh_electric_surge_research_defense()
	_refresh_shooting_timer_wait_time()
	_set_electric_surge_visual_state(true)
	_start_electric_surge_auto_fire(activation_id, authoritative)


func _start_electric_surge_auto_fire(
	activation_id: int,
	authoritative: bool
) -> void:
	if (
		activation_id <= 0
		or not _electric_surge_active
		or activation_id != _electric_surge_activation_id
		or is_dead
		or are_combat_actions_locked()
	):
		return
	if (
		_electric_surge_auto_fire_activation_id == activation_id
		and is_tango_barrage_active()
	):
		return
	_electric_surge_auto_fire_activation_id = activation_id
	_empowered_auto_fire_charge_sequence = maxi(
		_empowered_auto_fire_charge_sequence,
		_electric_surge_auto_fire_charge_sequence
	)
	_ensure_empowered_auto_fire(
		_get_empowered_auto_fire_direction(),
		authoritative
	)


func _stop_electric_surge_auto_fire(activation_id: int) -> void:
	if (
		activation_id <= 0
		or activation_id != _electric_surge_auto_fire_activation_id
	):
		return
	_electric_surge_auto_fire_activation_id = 0
	_release_empowered_auto_fire_if_unrequested()


func _spawn_authoritative_electric_surge_field(
	activation_id: int,
	origin: Vector2
) -> bool:
	var spawn_parent := _get_combat_spawn_parent()
	if spawn_parent == null:
		return false
	if _requires_multiplayer_gameplay_gateway():
		return (
			gameplay_gateway != null
			and gameplay_gateway.spawn_authoritative_tango_electric_surge_field(
			self,
			activation_id,
			origin
			)
		)
	if not _is_explicit_singleplayer_authority():
		return false
	var field := ELECTRIC_SURGE_FIELD_SCENE.instantiate() as TangoElectricSurgeField
	if field == null:
		return false
	field.top_level = true
	field.bind_gameplay_context(combat_runtime, gameplay_gateway)
	spawn_parent.add_child(field)
	field.global_position = origin
	field.setup(self, activation_id, ELECTRIC_SURGE_DURATION, true)
	return true


func _spawn_remote_electric_surge_visual_field(
	activation_id: int,
	origin: Vector2,
	remaining_seconds: float
) -> void:
	if _requires_multiplayer_gameplay_gateway() and gameplay_gateway != null:
		gameplay_gateway.spawn_remote_tango_electric_surge_visual_field(
			activation_id,
			origin,
			remaining_seconds
		)
		return
	if not _is_explicit_singleplayer_authority():
		return
	var spawn_parent := _get_combat_spawn_parent()
	if spawn_parent == null:
		return
	var field := ELECTRIC_SURGE_FIELD_SCENE.instantiate() as TangoElectricSurgeField
	if field == null:
		return
	field.top_level = true
	field.bind_gameplay_context(combat_runtime, gameplay_gateway)
	spawn_parent.add_child(field)
	field.global_position = origin
	field.setup_multiplayer_visual_only(activation_id, remaining_seconds)


func _on_electric_surge_duration_timer_timeout() -> void:
	_finish_electric_surge_state()


func _on_snow_wolf_full_charge_timer_timeout() -> void:
	_release_empowered_auto_fire_if_unrequested()
	_refresh_empowered_attack_bar_state()
	_update_attack_interval_bar()


func _finish_electric_surge_state() -> void:
	if not _electric_surge_active:
		return
	_clear_electric_surge_state()


func _clear_electric_surge_state() -> void:
	var ending_activation_id := _electric_surge_activation_id
	if electric_surge_duration_timer != null:
		electric_surge_duration_timer.stop()
	_electric_surge_active = false
	_electric_surge_authoritative = false
	_electric_surge_activation_id = 0
	_electric_surge_origin = Vector2.ZERO
	_stop_electric_surge_auto_fire(ending_activation_id)
	_electric_surge_auto_fire_charge_sequence = 0
	_refresh_electric_surge_research_defense()
	if electric_surge_audio != null:
		electric_surge_audio.stop()
	if is_node_ready():
		_refresh_shooting_timer_wait_time()
	_set_electric_surge_visual_state(false)


func _refresh_electric_surge_research_defense() -> void:
	var bonus := get_research_tango_defense_bonus() if _electric_surge_active else 0
	set_research_temporary_defense_bonuses(bonus, bonus)


func _set_electric_surge_visual_state(active: bool) -> void:
	_refresh_empowered_attack_bar_state()
	var surge_strength := 1.0 if active else 0.0
	for unit in _casting_unit_sprites:
		unit.set_instance_shader_parameter(
			&"electric_surge_strength",
			surge_strength
		)
	if is_node_ready():
		_update_attack_interval_bar()


func _refresh_empowered_attack_bar_state() -> void:
	var tango_attack_bar := attack_interval_bar as PlayerAttackIntervalBar
	if tango_attack_bar != null:
		tango_attack_bar.set_empowered_active(
			_is_empowered_auto_fire_requested()
		)


func _get_character_fire_rate_multiplier() -> float:
	var multiplier := super._get_character_fire_rate_multiplier()
	if _electric_surge_active:
		multiplier *= ELECTRIC_SURGE_FIRE_RATE_MULTIPLIER
	return multiplier


func resolve_attack_damage_against_enemy(base_damage: int, enemy: Enemy) -> int:
	var resolved_damage := super.resolve_attack_damage_against_enemy(
		base_damage,
		enemy
	)
	if (
		resolved_damage <= 0
		or not _electric_surge_active
		or enemy == null
		or not is_instance_valid(enemy)
		or not enemy.has_electromagnetic_attachment()
	):
		return resolved_damage
	return maxi(
		roundi(
			float(resolved_damage)
			* ELECTRIC_SURGE_ATTACHED_DAMAGE_MULTIPLIER
		),
		1
	)


func get_tango_max_charge_duration() -> float:
	return MAX_CHARGE_DURATION


func get_tango_charge_ratio() -> float:
	if is_snow_wolf_full_charge_active():
		return 1.0
	if _casting_state != CastingState.CHARGING:
		return 0.0
	return clampf(_charge_elapsed / MAX_CHARGE_DURATION, 0.0, 1.0)


func get_tango_release_ratio() -> float:
	return _barrage_charge_ratio


func get_tango_release_charge_seconds() -> float:
	return _barrage_charge_seconds


func get_tango_barrage_duration() -> float:
	return _barrage_duration


func get_tango_barrage_damage() -> int:
	return _barrage_damage_snapshot


func get_tango_barrage_damage_multiplier() -> float:
	return _barrage_damage_multiplier


func get_tango_barrage_volley_count() -> int:
	return _barrage_volley_count


func get_tango_casting_state() -> int:
	return _casting_state


func is_tango_charge_active() -> bool:
	return _casting_state == CastingState.CHARGING


func is_tango_barrage_active() -> bool:
	return _casting_state in [CastingState.CONVERGING, CastingState.FIRING]


func uses_passive_tango_mouse_aim() -> bool:
	return is_tango_barrage_active() and _attack_aim_uses_mouse


func get_primary_attack_cooldown_ratio() -> float:
	return get_tango_charge_ratio()


func get_primary_cooldown_ratio() -> float:
	# Snapshot cooldown represents an actual charge transaction. Snow Wolf keeps
	# the local HUD ready while idle, but publishing 1.0 here would make remote
	# replicas reconstruct a CHARGING state that never started.
	if _casting_state != CastingState.CHARGING:
		return 0.0
	return get_tango_charge_ratio()


func has_active_multiplayer_character_state() -> bool:
	return is_snow_wolf_full_charge_active()


func get_multiplayer_form_mode() -> int:
	if is_snow_wolf_full_charge_active():
		return PickupConfig.PlayerFormMode.ARMED
	return PickupConfig.PlayerFormMode.NORMAL


func get_multiplayer_shot_pattern() -> int:
	if is_snow_wolf_full_charge_active():
		return PickupConfig.ShotPattern.SPIRAL
	return PickupConfig.ShotPattern.NORMAL


func _apply_multiplayer_character_realtime_state(
	form_mode: int,
	shot_pattern: int,
	_ammo_capacity: int,
	_current_ammo: int,
	_is_reloading: bool,
	_reload_progress: float
) -> void:
	if snow_wolf_full_charge_timer == null:
		return
	var should_apply_full_charge := (
		form_mode == PickupConfig.PlayerFormMode.ARMED
		and shot_pattern == PickupConfig.ShotPattern.SPIRAL
	)
	if should_apply_full_charge:
		if snow_wolf_full_charge_timer.is_stopped():
			_activate_snow_wolf_full_charge(
				snow_wolf_full_charge_timer.wait_time,
				false,
				false
			)
	elif not snow_wolf_full_charge_timer.is_stopped():
		_clear_snow_wolf_auto_fire_state()


func apply_multiplayer_tango_charge_snapshot(ratio: float, facing_id: int) -> void:
	if _is_empowered_auto_fire_requested():
		super.apply_multiplayer_primary_cooldown_ratio(0.0)
		return
	var safe_ratio := clampf(ratio, 0.0, 1.0)
	if safe_ratio > 0.0 and _latest_remote_action_phase >= 2:
		# A realtime snapshot can cross the reliable terminal on another ENet
		# channel. Keep that stale ratio from flashing the bar after release/cancel.
		super.apply_multiplayer_primary_cooldown_ratio(0.0)
		return
	super.apply_multiplayer_primary_cooldown_ratio(safe_ratio)
	if safe_ratio <= 0.0:
		return
	# A joining client can receive the active charge bar before its reliable
	# `started` event. Reconstruct the visual from the snapshot's facing field;
	# a later reliable event still supplies the exact aim direction and sequence.
	var reconstructed_charge_visual := false
	if (
		_casting_state == CastingState.ORBIT
		and _latest_remote_action_phase < 2
	):
		_begin_charge_visual(_multiplayer_facing_id_to_direction(facing_id))
		reconstructed_charge_visual = true
	if _casting_state == CastingState.CHARGING:
		_charge_elapsed = safe_ratio * MAX_CHARGE_DURATION
		_update_charge_animation_speed()
		if reconstructed_charge_visual:
			_sync_charge_audio_to_elapsed()


func _initialize_character_resources() -> void:
	super._initialize_character_resources()
	_casting_unit_sprites = [unit_a, unit_b, unit_c]
	_reset_tango_combat_state(true)
	casting_units.show()
	_update_orbit_visuals(0.0)


func _input(event: InputEvent) -> void:
	super._input(event)
	if not uses_local_input or not is_tango_barrage_active():
		return
	# The last active aiming device owns the barrage. A real mouse movement can
	# take control back after a right-stick adjustment without requiring another
	# click (the charge button has already been released by this point).
	if event is InputEventMouseMotion:
		_attack_aim_uses_mouse = true


func _get_current_shoot_input() -> Vector2:
	var shoot_input := super._get_current_shoot_input()
	if (
		uses_local_input
		and shoot_input.length_squared() <= 0.001
		and uses_passive_tango_mouse_aim()
	):
		return _get_mouse_shoot_direction()
	return shoot_input


func _update_character_resources(delta: float) -> void:
	super._update_character_resources(delta)
	if is_dead:
		return
	if are_combat_actions_locked():
		if _casting_state == CastingState.CHARGING:
			if uses_local_input:
				_request_local_charge_cancel()
			else:
				cancel_authoritative_tango_charge()
		return
	if is_tango_empowered_auto_fire_active() and not uses_local_input:
		var network_aim := _get_current_shoot_input()
		if network_aim.length_squared() > 0.001:
			_set_barrage_direction(network_aim)
	if _casting_state == CastingState.CHARGING:
		_charge_elapsed = minf(
			_charge_elapsed + maxf(delta, 0.0),
			MAX_CHARGE_DURATION
		)
		_update_charge_animation_speed()


func _handle_primary_attack_input(shoot_input: Vector2) -> void:
	if are_combat_actions_locked() or is_dead:
		return
	if _is_empowered_auto_fire_requested():
		if shoot_input.length_squared() > 0.001:
			_set_barrage_direction(shoot_input)
		return
	if shoot_input.length_squared() > 0.001:
		var safe_direction := _get_safe_tango_direction(shoot_input)
		if _casting_state in [CastingState.CONVERGING, CastingState.FIRING]:
			_set_barrage_direction(safe_direction)
		else:
			_charge_direction = safe_direction
			last_attack_direction = safe_direction
		if (
			uses_local_input
			and not _local_charge_input_active
			and not _requires_neutral_before_charge
			and _casting_state == CastingState.ORBIT
		):
			_begin_local_charge_request(safe_direction)
		return
	if uses_local_input and _local_charge_input_active:
		_release_local_charge_request(_charge_direction)
	elif _casting_state == CastingState.ORBIT:
		_requires_neutral_before_charge = false


func _begin_local_charge_request(direction: Vector2) -> void:
	var accepted := false
	if _requires_multiplayer_gameplay_gateway():
		accepted = (
			gameplay_gateway != null
			and gameplay_gateway.request_tango_charge_started(direction)
		)
	elif _is_explicit_singleplayer_authority():
		accepted = try_authoritative_tango_charge_started(direction)
	if not accepted:
		_local_charge_input_active = false
		return
	_local_charge_input_active = true
	if _casting_state == CastingState.ORBIT:
		_begin_charge_visual(direction)


func _release_local_charge_request(direction: Vector2) -> void:
	_local_charge_input_active = false
	var local_charge_elapsed := _charge_elapsed
	if _requires_multiplayer_gameplay_gateway():
		var accepted := (
			gameplay_gateway != null
			and gameplay_gateway.request_tango_charge_released(direction)
		)
		if not accepted:
			_cancel_charge_visual()
			return
		# Single-player and a local Host resolve the authoritative transition inside
		# the request bridge. Only a client prediction remains in CHARGING here.
		if _casting_state != CastingState.CHARGING:
			return
		if local_charge_elapsed + CHARGE_THRESHOLD_EPSILON < MIN_CHARGE_DURATION:
			_cancel_charge_visual()
		else:
			_start_barrage_sequence(
				direction,
				_charge_elapsed_to_release_ratio(local_charge_elapsed),
				false
			)
		return
	if not _is_explicit_singleplayer_authority():
		_cancel_charge_visual()
		return
	if local_charge_elapsed + CHARGE_THRESHOLD_EPSILON < MIN_CHARGE_DURATION:
		cancel_authoritative_tango_charge()
		return
	try_authoritative_tango_charge_released(
		direction,
		_charge_elapsed_to_release_ratio(local_charge_elapsed)
	)


func try_authoritative_tango_charge_started(direction: Vector2) -> bool:
	if (
		is_dead
		or are_combat_actions_locked()
		or _is_empowered_auto_fire_requested()
		or _casting_state != CastingState.ORBIT
	):
		return false
	var safe_direction := _get_safe_tango_direction(direction)
	_begin_charge_visual(safe_direction)
	return true


func try_authoritative_tango_charge_released(
	direction: Vector2,
	authoritative_charge_ratio: float
) -> Dictionary:
	if (
		is_dead
		or are_combat_actions_locked()
		or _casting_state != CastingState.CHARGING
		or not is_finite(authoritative_charge_ratio)
	):
		return {
			"accepted": false,
			"fired": false,
			"direction": Vector2.ZERO,
		}
	var safe_direction := _get_safe_tango_direction(direction)
	var safe_ratio := clampf(authoritative_charge_ratio, 0.0, 1.0)
	_start_barrage_sequence(safe_direction, safe_ratio, true)
	return {
		"accepted": true,
		"fired": true,
		"direction": safe_direction,
		"charge_ratio": safe_ratio,
	}


func cancel_authoritative_tango_charge() -> void:
	_local_charge_input_active = false
	if _casting_state == CastingState.CHARGING:
		_cancel_charge_visual()


func _request_local_charge_cancel() -> void:
	if _casting_state != CastingState.CHARGING:
		return
	_local_charge_input_active = false
	if _requires_multiplayer_gameplay_gateway() and gameplay_gateway != null:
		gameplay_gateway.request_tango_charge_cancelled()
	cancel_authoritative_tango_charge()


func play_remote_tango_charge_started(direction: Vector2, sequence: int) -> void:
	if not _accept_remote_tango_charge_started(sequence):
		return
	if is_dead or are_combat_actions_locked():
		return
	var safe_direction := _get_safe_tango_direction(direction)
	if _is_empowered_auto_fire_requested():
		_set_barrage_direction(safe_direction)
		return
	_begin_charge_visual(safe_direction)


func play_remote_tango_barrage_started(
	direction: Vector2,
	charge_ratio: float,
	sequence: int
) -> void:
	if not _accept_remote_tango_charge_terminal(sequence):
		return
	if is_dead or are_combat_actions_locked() or not is_finite(charge_ratio):
		return
	if _is_empowered_auto_fire_requested():
		_empowered_auto_fire_charge_sequence = maxi(
			_empowered_auto_fire_charge_sequence,
			sequence
		)
		_ensure_empowered_auto_fire(direction, false)
		return
	_start_barrage_sequence(
		_get_safe_tango_direction(direction),
		clampf(charge_ratio, 0.0, 1.0),
		false
	)


func reconcile_predicted_tango_barrage_started(
	direction: Vector2,
	charge_ratio: float,
	sequence: int
) -> void:
	if not _accept_remote_tango_charge_terminal(sequence):
		return
	if is_dead or are_combat_actions_locked() or not is_finite(charge_ratio):
		if not _is_empowered_auto_fire_requested():
			_cancel_charge_visual()
		return
	var safe_direction := _get_safe_tango_direction(direction)
	var safe_ratio := clampf(charge_ratio, 0.0, 1.0)
	if _is_empowered_auto_fire_requested():
		_empowered_auto_fire_charge_sequence = maxi(
			_empowered_auto_fire_charge_sequence,
			sequence
		)
		_ensure_empowered_auto_fire(safe_direction, false)
		return
	if _casting_state in [CastingState.CONVERGING, CastingState.FIRING]:
		_set_barrage_direction(safe_direction)
		_apply_barrage_release_profile(safe_ratio)
		if _casting_state == CastingState.FIRING:
			_set_units_to_fire_positions()
			if _barrage_elapsed >= _barrage_duration - BARRAGE_EPSILON:
				_begin_return_to_orbit()
		return
	# A prediction that already completed keeps its resolved profile. Do not
	# replay it when the reliable Host confirmation arrives late.
	if (
		_casting_state in [CastingState.ORBIT, CastingState.RETURNING]
		and _barrage_duration > 0.0
	):
		_set_barrage_direction(safe_direction)
		_apply_barrage_release_profile(safe_ratio)
		return
	_start_barrage_sequence(safe_direction, safe_ratio, false)


func play_remote_tango_charge_cancelled(sequence: int) -> void:
	if not _accept_remote_tango_charge_terminal(sequence):
		return
	if _is_empowered_auto_fire_requested():
		return
	_cancel_charge_visual()


func confirm_predicted_tango_charge_started(sequence: int) -> void:
	if sequence > _latest_remote_action_sequence:
		_latest_remote_action_sequence = sequence
		_latest_remote_action_phase = 1


func reconcile_predicted_tango_charge_started(
	direction: Vector2,
	sequence: int
) -> void:
	if (
		sequence <= 0
		or sequence < _latest_remote_action_sequence
		or (
			sequence == _latest_remote_action_sequence
			and _latest_remote_action_phase >= 1
		)
	):
		return
	_latest_remote_action_sequence = sequence
	_latest_remote_action_phase = 1
	if is_dead or are_combat_actions_locked():
		reject_predicted_tango_charge()
		return
	if _is_empowered_auto_fire_requested():
		return
	if _casting_state == CastingState.CHARGING:
		return
	if _casting_state not in [CastingState.CONVERGING, CastingState.FIRING]:
		return
	# The client predicted an instant full-charge surge attack, while the Host's
	# eight-second clock had already expired. Remove every predicted barrage field
	# before rebuilding the ordinary held-charge state for the same input request.
	_cancel_charge_visual()
	_local_charge_input_active = true
	_begin_charge_visual(_get_safe_tango_direction(direction))


func reject_predicted_tango_charge() -> void:
	_local_charge_input_active = false
	if _is_empowered_auto_fire_requested():
		return
	_cancel_charge_visual()


func _accept_remote_tango_charge_started(sequence: int) -> bool:
	if sequence <= _latest_remote_action_sequence:
		return false
	_latest_remote_action_sequence = sequence
	_latest_remote_action_phase = 1
	return true


func _accept_remote_tango_charge_terminal(sequence: int) -> bool:
	if (
		sequence < _latest_remote_action_sequence
		or (
			sequence == _latest_remote_action_sequence
			and _latest_remote_action_phase >= 2
		)
	):
		return false
	_latest_remote_action_sequence = sequence
	_latest_remote_action_phase = 2
	return true


func _begin_charge_visual(direction: Vector2) -> void:
	_casting_state_to(CastingState.CHARGING)
	_charge_elapsed = 0.0
	_charge_direction = direction
	_attack_aim_uses_mouse = uses_local_input and mouse_fire_held
	last_attack_direction = direction
	_update_facing(Vector2.ZERO, direction)
	_set_casting_unit_animation(&"charge")
	_update_charge_animation_speed()
	_play_charge_audio()


func _cancel_charge_visual() -> void:
	_stop_charge_audio()
	_charge_elapsed = 0.0
	_barrage_charge_ratio = 0.0
	_barrage_charge_seconds = 0.0
	_barrage_damage_multiplier = NORMAL_CHARGE_DAMAGE_MULTIPLIER
	_barrage_duration = 0.0
	_barrage_elapsed = 0.0
	_barrage_next_volley_time = 0.0
	_barrage_damage_snapshot = 0
	_barrage_is_authoritative = false
	_barrage_volley_count = 0
	_unit_converge_elapsed = 0.0
	_unit_return_elapsed = 0.0
	_requires_neutral_before_charge = false
	_casting_state_to(CastingState.ORBIT)
	_set_casting_unit_animation(&"orbit")
	_update_orbit_visuals(0.0)


func _start_barrage_sequence(
	direction: Vector2,
	charge_ratio: float,
	authoritative: bool
) -> void:
	var safe_ratio := clampf(charge_ratio, 0.0, 1.0)
	_barrage_direction = _get_safe_tango_direction(direction)
	_apply_barrage_release_profile(safe_ratio)
	_barrage_elapsed = 0.0
	_barrage_next_volley_time = 0.0
	_barrage_is_authoritative = authoritative
	_barrage_volley_count = 0
	_charge_elapsed = 0.0
	_local_charge_input_active = false
	_requires_neutral_before_charge = true
	last_attack_direction = _barrage_direction
	_update_facing(Vector2.ZERO, _barrage_direction)
	_capture_unit_converge_starts()
	_unit_converge_elapsed = 0.0
	_casting_state_to(CastingState.CONVERGING)
	_set_casting_unit_animation(&"fire")
	_stop_charge_audio()
	_play_unit_converge_audio()


func _apply_barrage_release_profile(charge_ratio: float) -> void:
	_barrage_charge_ratio = clampf(charge_ratio, 0.0, 1.0)
	_barrage_charge_seconds = lerpf(
		MIN_CHARGE_DURATION,
		MAX_CHARGE_DURATION,
		_barrage_charge_ratio
	)
	var duration_progress := clampf(
		(_barrage_charge_seconds - LOW_CHARGE_DAMAGE_THRESHOLD)
		/ (MAX_CHARGE_DURATION - LOW_CHARGE_DAMAGE_THRESHOLD),
		0.0,
		1.0
	)
	_barrage_duration = lerpf(
		MIN_BARRAGE_DURATION,
		MAX_BARRAGE_DURATION,
		duration_progress
	)
	if _barrage_charge_ratio >= 1.0 - CHARGE_THRESHOLD_EPSILON:
		_barrage_damage_multiplier = FULL_CHARGE_DAMAGE_MULTIPLIER
	elif (
		_barrage_charge_seconds
		< LOW_CHARGE_DAMAGE_THRESHOLD - CHARGE_THRESHOLD_EPSILON
	):
		_barrage_damage_multiplier = LOW_CHARGE_DAMAGE_MULTIPLIER
	else:
		_barrage_damage_multiplier = NORMAL_CHARGE_DAMAGE_MULTIPLIER
	var physical_damage := get_outgoing_damage(
		attack_damage,
		EnemyConfig.DamageType.PHYSICAL
	)
	_barrage_damage_snapshot = maxi(
		roundi(float(physical_damage) * _barrage_damage_multiplier),
		1
	)


func _update_character_combat_state(delta: float) -> void:
	super._update_character_combat_state(delta)
	if is_dead:
		return
	var safe_delta := maxf(delta, 0.0)
	_unit_orbit_phase = fposmod(
		_unit_orbit_phase + safe_delta * TAU / UNIT_ORBIT_PERIOD,
		TAU
	)
	_update_local_barrage_aim()
	match _casting_state:
		CastingState.ORBIT, CastingState.CHARGING:
			_update_orbit_visuals(safe_delta)
		CastingState.CONVERGING:
			_update_unit_convergence(safe_delta)
		CastingState.FIRING:
			_update_active_barrage(safe_delta)
		CastingState.RETURNING:
			_update_unit_return(safe_delta)


func _update_local_barrage_aim() -> void:
	if not uses_local_input or not is_tango_barrage_active():
		return
	var stick_direction := Input.get_vector(
		"shoot_left",
		"shoot_right",
		"shoot_up",
		"shoot_down"
	)
	if stick_direction.length_squared() > 0.001:
		_attack_aim_uses_mouse = false
		_set_barrage_direction(stick_direction)
	elif _attack_aim_uses_mouse:
		_set_barrage_direction(_get_mouse_shoot_direction())


func _set_barrage_direction(direction: Vector2) -> void:
	_barrage_direction = _get_safe_tango_direction(direction)
	last_attack_direction = _barrage_direction
	_update_facing(Vector2.ZERO, _barrage_direction)
	if _casting_state == CastingState.FIRING:
		_set_units_to_fire_positions()


func apply_remote_tango_barrage_snapshot(
	direction: Vector2,
	charge_ratio: float,
	charge_sequence: int,
	barrage_remaining_seconds: float
) -> void:
	if (
		charge_sequence <= 0
		or charge_sequence <= _empowered_auto_fire_finished_barrage_sequence
		or charge_sequence < _latest_remote_action_sequence
		or not is_finite(charge_ratio)
		or not is_finite(barrage_remaining_seconds)
	):
		return
	var is_new_sequence := charge_sequence > _latest_remote_action_sequence
	_latest_remote_action_sequence = charge_sequence
	_latest_remote_action_phase = 2
	if is_dead or are_combat_actions_locked():
		return
	_set_barrage_direction(direction)
	_apply_barrage_release_profile(clampf(charge_ratio, 0.0, 1.0))
	var empowered_auto_fire_active := _is_empowered_auto_fire_requested()
	if empowered_auto_fire_active:
		_empowered_auto_fire_charge_sequence = maxi(
			_empowered_auto_fire_charge_sequence,
			charge_sequence
		)
		_barrage_duration = maxf(
			_get_empowered_auto_fire_remaining_seconds(),
			BARRAGE_EPSILON
		)
	var signed_remaining := clampf(
		barrage_remaining_seconds,
		-UNIT_RETURN_DURATION,
		_barrage_duration
	)
	if empowered_auto_fire_active:
		# Reliable empowered timers own replica lifetime. Volley snapshots reconcile
		# aim only, so cross-channel order cannot shorten the shared automatic barrage.
		signed_remaining = _barrage_duration
	# Remote replicas never emit gameplay bullets. The Host batch itself is the
	# cadence source, so skip their local predicted volley schedule after a sync.
	_barrage_next_volley_time = _barrage_duration
	_barrage_is_authoritative = false
	_charge_elapsed = 0.0
	_local_charge_input_active = false
	_requires_neutral_before_charge = true
	if is_new_sequence:
		_barrage_volley_count = 0
	if signed_remaining <= 0.0:
		if signed_remaining <= -UNIT_RETURN_DURATION + BARRAGE_EPSILON:
			_casting_state_to(CastingState.ORBIT)
			_set_casting_unit_animation(&"orbit")
			_update_orbit_visuals(0.0)
			return
		# A slightly late packet can reconstruct the quick return instead of
		# snapping a joining/reordered client straight from orbit to orbit.
		_casting_state_to(CastingState.FIRING)
		_set_units_to_fire_positions()
		_begin_return_to_orbit()
		_unit_return_elapsed = clampf(
			-signed_remaining,
			0.0,
			UNIT_RETURN_DURATION
		)
		_update_unit_return(0.0)
		return
	_barrage_elapsed = _barrage_duration - signed_remaining
	if _casting_state != CastingState.FIRING:
		_casting_state_to(CastingState.FIRING)
		_set_casting_unit_animation(&"fire")
	_set_units_to_fire_positions()


func _capture_unit_converge_starts() -> void:
	_unit_converge_starts.clear()
	_unit_converge_start_rotations.clear()
	for unit in _casting_unit_sprites:
		_unit_converge_starts.append(unit.position)
		_unit_converge_start_rotations.append(unit.rotation)


func _update_unit_convergence(delta: float) -> void:
	_unit_converge_elapsed = minf(
		_unit_converge_elapsed + delta,
		UNIT_CONVERGE_DURATION
	)
	var progress := clampf(
		_unit_converge_elapsed / UNIT_CONVERGE_DURATION,
		0.0,
		1.0
	)
	var eased_progress := progress * progress * (3.0 - 2.0 * progress)
	var target_rotation := _get_unit_fire_rotation(_barrage_direction)
	for index in _casting_unit_sprites.size():
		var start_position := _unit_converge_starts[index]
		var unit := _casting_unit_sprites[index]
		unit.position = _round_vector(
			start_position.lerp(
				_get_unit_fire_position(_barrage_direction, index),
				eased_progress
			)
		)
		unit.rotation = lerp_angle(
			_unit_converge_start_rotations[index],
			target_rotation,
			eased_progress
		)
		unit.z_index = 2
	if progress >= 1.0:
		_begin_barrage_fire()


func _begin_barrage_fire() -> void:
	if unit_converge_audio != null:
		unit_converge_audio.stop()
	_casting_state_to(CastingState.FIRING)
	_set_units_to_fire_positions()
	_barrage_elapsed = 0.0
	_barrage_next_volley_time = 0.0
	_update_active_barrage(0.0)


func _update_active_barrage(delta: float) -> void:
	var frame_end := minf(_barrage_elapsed + maxf(delta, 0.0), _barrage_duration)
	# Commit the Host sample time before emitting. Registration timestamps and
	# remaining-duration metadata must describe the same instant, including when
	# one long frame catches up multiple scheduled volleys.
	_barrage_elapsed = frame_end
	while (
		_barrage_next_volley_time < _barrage_duration - BARRAGE_EPSILON
		and _barrage_next_volley_time <= frame_end + BARRAGE_EPSILON
	):
		_emit_tango_volley()
		_barrage_next_volley_time += _get_effective_fire_interval()
	if _barrage_elapsed >= _barrage_duration - BARRAGE_EPSILON:
		_begin_return_to_orbit()


func _emit_tango_volley() -> void:
	_barrage_volley_count += 1
	if not _barrage_is_authoritative:
		return
	if not _spawn_authoritative_tango_volley():
		return
	notify_primary_attack_performed()
	_play_primary_attack_audio()


func _spawn_authoritative_tango_volley() -> bool:
	if _barrage_damage_snapshot <= 0 or _casting_unit_sprites.size() != PROJECTILES_PER_VOLLEY:
		return false
	var spawn_parent := _get_combat_spawn_parent()
	if spawn_parent == null:
		return false
	if _requires_multiplayer_gameplay_gateway() and gameplay_gateway == null:
		return false
	var projectiles: Array[Node] = []
	var spawn_positions := PackedVector2Array()
	var uses_registered_pool := spawn_parent.has_session_object_pool_scene(
		LASER_BULLET_SCENE
	)
	for unit_index in range(_casting_unit_sprites.size()):
		var bullet: TangoLaserBullet = null
		if uses_registered_pool:
			bullet = spawn_parent.acquire_session_object(
				LASER_BULLET_SCENE,
				false
			) as TangoLaserBullet
		else:
			bullet = LASER_BULLET_SCENE.instantiate() as TangoLaserBullet
		if bullet == null:
			_retire_spawned_tango_projectiles(projectiles)
			return false
		bullet.top_level = true
		bullet.bind_gameplay_context(combat_runtime, gameplay_gateway)
		bullet.source_type = LASER_BULLET_TYPE
		bullet.setup(_barrage_direction, _barrage_damage_snapshot, false)
		bullet.setup_collectible_owner(self)
		if bullet.get_parent() == null:
			spawn_parent.add_child(bullet)
		elif bullet.get_parent() != spawn_parent:
			bullet.reparent(spawn_parent)
		# CastingUnits carries multiplayer_visual_offset for rendering only. Build
		# the authoritative muzzle from the Player transform so interpolation can
		# never shift hit detection or push a shot through nearby world geometry.
		var intended_spawn_position := to_global(
			_casting_units_base_position
			+ _get_unit_fire_position(_barrage_direction, unit_index)
			+ _barrage_direction * PROJECTILE_MUZZLE_DISTANCE
		)
		var spawn_position := bullet.clamp_spawn_position_to_clear_path(
			to_global(_casting_units_base_position),
			intended_spawn_position,
			self
		)
		bullet.global_position = spawn_position
		bullet.reset_physics_interpolation()
		projectiles.append(bullet)
		spawn_positions.append(spawn_position)
	if _requires_multiplayer_gameplay_gateway():
		var registered := gameplay_gateway.register_local_tango_laser_volley(
			projectiles,
			spawn_positions,
			_barrage_direction,
			peer_id,
			_barrage_damage_snapshot,
			float(projectiles[0].get("speed")),
			float(projectiles[0].get("max_lifetime")),
			_barrage_charge_ratio,
			maxf(
				_barrage_duration - _barrage_elapsed,
				0.0
			)
		)
		if not registered:
			_retire_spawned_tango_projectiles(projectiles)
			return false
	return true


func _retire_spawned_tango_projectiles(projectiles: Array[Node]) -> void:
	for projectile in projectiles:
		var bullet := projectile as TangoLaserBullet
		if bullet != null and is_instance_valid(bullet):
			bullet.retire()


func _begin_return_to_orbit() -> void:
	if _casting_state == CastingState.RETURNING:
		return
	_barrage_is_authoritative = false
	_unit_return_elapsed = 0.0
	_unit_return_starts.clear()
	_unit_return_start_rotations.clear()
	for unit in _casting_unit_sprites:
		_unit_return_starts.append(unit.position)
		_unit_return_start_rotations.append(unit.rotation)
	_casting_state_to(CastingState.RETURNING)
	_set_casting_unit_animation(&"orbit")
	_play_unit_return_audio()


func _update_unit_return(delta: float) -> void:
	_unit_return_elapsed = minf(
		_unit_return_elapsed + delta,
		UNIT_RETURN_DURATION
	)
	var progress := clampf(_unit_return_elapsed / UNIT_RETURN_DURATION, 0.0, 1.0)
	var eased_progress := progress * progress * (3.0 - 2.0 * progress)
	for index in _casting_unit_sprites.size():
		var unit := _casting_unit_sprites[index]
		unit.position = _round_vector(
			_unit_return_starts[index].lerp(
				_get_unit_orbit_position(index),
				eased_progress
			)
		)
		unit.rotation = lerp_angle(
			_unit_return_start_rotations[index],
			0.0,
			eased_progress
		)
		unit.z_index = 0 if unit.position.y < 0.0 else 2
	if progress >= 1.0:
		_casting_state_to(CastingState.ORBIT)
		_update_orbit_visuals(0.0)


func _update_orbit_visuals(_delta: float) -> void:
	if _casting_unit_sprites.is_empty():
		return
	for index in _casting_unit_sprites.size():
		var unit := _casting_unit_sprites[index]
		unit.position = _get_unit_orbit_position(index)
		unit.rotation = 0.0
		unit.z_index = 0 if unit.position.y < 0.0 else 2


func _get_unit_orbit_position(index: int) -> Vector2:
	var angle := _unit_orbit_phase + float(index) * UNIT_PHASE_STEP
	return _round_vector(Vector2(
		cos(angle) * UNIT_ORBIT_RADIUS.x,
		sin(angle) * UNIT_ORBIT_RADIUS.y
	))


func _get_unit_fire_position(direction: Vector2, index: int) -> Vector2:
	var perpendicular := Vector2(-direction.y, direction.x)
	return _round_vector(
		direction * float(UNIT_FIRE_FORWARD_OFFSETS[index])
		+ perpendicular * float(UNIT_FIRE_LATERAL_OFFSETS[index])
	)


# Retained as a compact mechanics/tooling contract. Runtime visual updates use
# the indexed helper directly and no longer allocate a three-element Array on
# every rendered frame.
func _get_unit_fire_positions(direction: Vector2) -> Array[Vector2]:
	var positions: Array[Vector2] = []
	for index in PROJECTILES_PER_VOLLEY:
		positions.append(_get_unit_fire_position(direction, index))
	return positions


func _set_units_to_fire_positions() -> void:
	if (
		_unit_fire_layout_ready
		and _unit_fire_layout_direction.is_equal_approx(_barrage_direction)
	):
		return
	_unit_fire_layout_ready = true
	_unit_fire_layout_direction = _barrage_direction
	var target_rotation := _get_unit_fire_rotation(_barrage_direction)
	for index in _casting_unit_sprites.size():
		var unit := _casting_unit_sprites[index]
		unit.position = _get_unit_fire_position(_barrage_direction, index)
		unit.rotation = target_rotation
		unit.z_index = 2


func _get_unit_fire_rotation(direction: Vector2) -> float:
	return direction.angle() + UNIT_FORWARD_ROTATION_OFFSET


func _set_casting_unit_animation(animation_name: StringName) -> void:
	for unit in _casting_unit_sprites:
		if not unit.sprite_frames.has_animation(animation_name):
			continue
		if animation_name != &"charge":
			unit.speed_scale = 1.0
		if unit.animation != animation_name or not unit.is_playing():
			unit.play(animation_name)


func _update_charge_animation_speed() -> void:
	var charge_ratio := get_tango_charge_ratio()
	var eased_ratio := charge_ratio * charge_ratio * (3.0 - 2.0 * charge_ratio)
	var speed_scale := lerpf(
		UNIT_CHARGE_MIN_SPEED_SCALE,
		UNIT_CHARGE_MAX_SPEED_SCALE,
		eased_ratio
	)
	for unit in _casting_unit_sprites:
		unit.speed_scale = speed_scale


func _charge_elapsed_to_release_ratio(elapsed: float) -> float:
	return clampf(
		(elapsed - MIN_CHARGE_DURATION)
		/ (MAX_CHARGE_DURATION - MIN_CHARGE_DURATION),
		0.0,
		1.0
	)


func _get_safe_tango_direction(direction: Vector2) -> Vector2:
	if (
		is_finite(direction.x)
		and is_finite(direction.y)
		and direction.length_squared() > 0.001
	):
		return direction.normalized()
	var fallback := _facing_suffix_to_vector(facing_suffix)
	return fallback if fallback != Vector2.ZERO else Vector2.RIGHT


func _round_vector(value: Vector2) -> Vector2:
	return Vector2(roundf(value.x), roundf(value.y))


func _multiplayer_facing_id_to_direction(facing_id: int) -> Vector2:
	match facing_id:
		1:
			return Vector2.LEFT
		2:
			return Vector2.UP
		3:
			return Vector2.DOWN
		_:
			return Vector2.RIGHT


func _casting_state_to(next_state: CastingState) -> void:
	_casting_state = next_state
	if next_state != CastingState.FIRING:
		_unit_fire_layout_ready = false


func _cache_character_visual_base_positions() -> void:
	if casting_units != null:
		_casting_units_base_position = casting_units.position


func _set_character_visual_offset(offset: Vector2) -> void:
	if casting_units != null:
		casting_units.position = _casting_units_base_position + offset


func _update_animation() -> void:
	if velocity.length_squared() <= 0.01:
		var idle_animation := StringName("idle_%s" % facing_suffix)
		if body_sprite.sprite_frames.has_animation(idle_animation):
			if body_sprite.animation != idle_animation or not body_sprite.is_playing():
				body_sprite.play(idle_animation)
			return
	super._update_animation()


func _on_controls_lock_changed(locked: bool) -> void:
	super._on_controls_lock_changed(locked)
	if locked:
		# Snow Wolf is forced automatic fire; a local modal only removes steering
		# input and must not create Host/client authority differences in its cadence.
		_finish_electric_surge_state()
	else:
		_resume_snow_wolf_auto_fire_after_lock()


func _on_combat_actions_lock_changed(locked: bool) -> void:
	super._on_combat_actions_lock_changed(locked)
	if locked:
		var preserves_snow_wolf_lease := is_snow_wolf_full_charge_active()
		_suspend_snow_wolf_auto_fire_for_lock()
		_finish_electric_surge_state()
		if _casting_state == CastingState.CHARGING and uses_local_input:
			_request_local_charge_cancel()
		if not preserves_snow_wolf_lease:
			_reset_tango_combat_state(not is_dead)
	else:
		_resume_snow_wolf_auto_fire_after_lock()


func _cleanup_character_combat_on_death() -> void:
	super._cleanup_character_combat_on_death()
	_suspend_snow_wolf_auto_fire_for_lock()
	_finish_electric_surge_state()
	_reset_tango_combat_state(false)
	if casting_units != null:
		casting_units.hide()


func _clear_character_scene_transients() -> void:
	super._clear_character_scene_transients()
	_clear_snow_wolf_auto_fire_state()
	_finish_electric_surge_state()
	_reset_tango_combat_state(true)
	if casting_units != null:
		casting_units.show()
		_update_orbit_visuals(0.0)


func _reset_character_resources_on_revive() -> void:
	super._reset_character_resources_on_revive()
	_clear_electric_surge_state()
	_reset_tango_combat_state(true)
	if casting_units != null:
		casting_units.show()
		_update_orbit_visuals(0.0)
	_resume_snow_wolf_auto_fire_after_lock()


func _reset_tango_combat_state(show_units: bool) -> void:
	_stop_tango_casting_audio()
	_local_charge_input_active = false
	_charge_elapsed = 0.0
	_barrage_charge_ratio = 0.0
	_barrage_charge_seconds = 0.0
	_barrage_damage_multiplier = NORMAL_CHARGE_DAMAGE_MULTIPLIER
	_barrage_duration = 0.0
	_barrage_elapsed = 0.0
	_barrage_next_volley_time = 0.0
	_barrage_damage_snapshot = 0
	_barrage_is_authoritative = false
	_barrage_volley_count = 0
	_electric_surge_auto_fire_activation_id = 0
	_electric_surge_auto_fire_charge_sequence = 0
	_empowered_auto_fire_charge_sequence = 0
	_attack_aim_uses_mouse = false
	_requires_neutral_before_charge = false
	_unit_converge_elapsed = 0.0
	_unit_return_elapsed = 0.0
	_unit_converge_starts.clear()
	_unit_converge_start_rotations.clear()
	_unit_return_starts.clear()
	_unit_return_start_rotations.clear()
	_unit_fire_layout_ready = false
	_casting_state_to(CastingState.ORBIT)
	if not _casting_unit_sprites.is_empty():
		_set_casting_unit_animation(&"orbit")
		_update_orbit_visuals(0.0)
	if casting_units != null:
		casting_units.visible = show_units


func _play_primary_attack_audio() -> void:
	if primary_attack_audio != null and primary_attack_audio.stream != null:
		primary_attack_audio.pitch_scale = randf_range(0.97, 1.03)
		primary_attack_audio.play()


func play_remote_tango_volley_audio() -> void:
	_play_primary_attack_audio()


func _play_charge_audio() -> void:
	if charge_audio == null or charge_audio.stream == null:
		return
	charge_audio.pitch_scale = 1.0
	charge_audio.play()


func _sync_charge_audio_to_elapsed() -> void:
	if charge_audio == null or charge_audio.stream == null:
		return
	var stream_length := charge_audio.stream.get_length()
	if _charge_elapsed >= stream_length:
		charge_audio.stop()
		return
	charge_audio.play(clampf(_charge_elapsed, 0.0, stream_length))


func _stop_charge_audio() -> void:
	if charge_audio != null:
		charge_audio.stop()


func _play_unit_converge_audio() -> void:
	if unit_converge_audio == null or unit_converge_audio.stream == null:
		return
	unit_converge_audio.pitch_scale = randf_range(0.98, 1.02)
	unit_converge_audio.play()


func _play_unit_return_audio() -> void:
	if unit_return_audio == null or unit_return_audio.stream == null:
		return
	unit_return_audio.pitch_scale = randf_range(0.98, 1.02)
	unit_return_audio.play()


func _play_electric_surge_audio() -> void:
	if electric_surge_audio == null or electric_surge_audio.stream == null:
		return
	electric_surge_audio.pitch_scale = randf_range(0.99, 1.01)
	electric_surge_audio.play()


func _stop_tango_casting_audio() -> void:
	_stop_charge_audio()
	if unit_converge_audio != null:
		unit_converge_audio.stop()
	if unit_return_audio != null:
		unit_return_audio.stop()
