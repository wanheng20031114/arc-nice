extends CharacterBody2D

class_name Player

signal xirang_changed(total: int, added_amount: int)
signal health_changed(current: int, maximum: int)
signal attack_speed_changed(attack_speed: float)
signal dodge_changed(chance: float)
signal died

@export var character_id: StringName = &""
@export var move_speed: float = 120.0
@export var max_health: int = 1
@export var invincibility_duration: float = 1.0
@export_range(1.0, 200.0, 1.0, "or_greater") var dash_distance: float = 35.0
@export_range(0.05, 1.0, 0.01, "or_greater") var dash_duration: float = 0.12
@export_range(0.0, 30.0, 0.1, "or_greater") var dash_cooldown: float = 5.0
@export var attack_damage: int = 1
@export var physical_defense: int = 0
@export var magic_defense: int = 0

var current_health: int = 0
var current_xirang: int = 0
var invincibility_time_left: float = 0.0
var dash_time_left: float = 0.0
var dash_distance_left: float = 0.0
var dash_direction: Vector2 = Vector2.ZERO
var _active_dash_distance: float = 0.0
var multiplayer_dash_protection_time_left: float = 0.0
var remote_dash_visual_time_left: float = 0.0
var is_dead: bool = false
var controls_locked: bool = false
var peer_id: int = 0
var uses_local_input: bool = true
var network_move_input: Vector2 = Vector2.ZERO
var network_shoot_input: Vector2 = Vector2.ZERO
var network_reload_requested: bool = false
var mouse_fire_held: bool = false
var mouse_viewport_position: Vector2 = Vector2.ZERO
var multiplayer_display_name: String = ""
var client_movement_prediction_only: bool = false

@export var fire_interval: float = 1.0
@export_range(1.0, 1000.0, 1.0, "or_greater") var attack_speed_units_per_attack: float = 100.0
@export var auxiliary_projectile_spawn_distance: float = 12.0
@export var footstep_interval: float = 0.28
@export var skill1_charge_duration: float = 18.0

@onready var body_sprite: AnimatedSprite2D = $BodySprite
@onready var speed_trail_effect: Node2D = $MoveSpeedTrailEffect
@onready var dash_ready_indicator: Control = $DashReadyIndicator
@onready var collision_shape: CollisionShape2D = $CollisionShape2D
@onready var shooting_timer: Timer = $ShootingTimer
@onready var dash_cooldown_timer: Timer = $DashCooldownTimer
@onready var footstep_audio: AudioStreamPlayer2D = $FootstepAudio
@onready var death_audio: AudioStreamPlayer2D = $DeathAudio
@onready var powerup_audio: AudioStreamPlayer2D = $PowerupAudio
@onready var secret_audio: AudioStreamPlayer2D = $SecretAudio
@onready var xirang_pickup_audio: AudioStreamPlayer2D = $XirangPickupAudio
@onready var lucky_upgrade_audio: AudioStreamPlayer2D = $LuckyUpgradeAudio
@onready var health_bar: Control = $HealthBar
@onready var skill1_charge_bar: Skill1ChargeBar = $Skill1ChargeBar
@onready var attack_interval_bar: Control = get_node_or_null("AttackIntervalBar") as Control
@onready var name_label: Label = $NameLabel
@onready var nameplate_layer: CanvasLayer = $NameplateLayer
@onready var nameplate_label: Label = $NameplateLayer/NameplateLabel

const COLLECTIBLE_AREA_EFFECT_SCENE := preload("res://scene/collectible_area_effect.tscn")
const COLLECTIBLE_FROST_AREA_EFFECT_SCENE := preload("res://scene/collectible_frost_area_effect.tscn")
const COLLECTIBLE_LIGHTNING_EFFECT_SCENE := preload("res://scene/collectible_lightning_effect.tscn")
const COLLECTIBLE_MOON_SHIELD_SCENE := preload("res://scene/collectible_moon_shield.tscn")
const COLLECTIBLE_ARROW_PROJECTILE_SCENE := preload("res://scene/collectible_arrow_projectile.tscn")
const LINGLAN_SKILL2_CONFIG_PATH := "res://resources/config/bosses/linglan_skill2.tres"
const LINGLAN_SKILL2_ROCKET_SCENE := preload("res://scene/boss/linglan/linglan_skill2_sakura_rocket.tscn")
const NORMAL_ANIMATION_PREFIX := &"normal"
const DEFAULT_FIRE_RATE_MULTIPLIER := 1.0
const DEFAULT_MOVE_SPEED_MULTIPLIER := 1.0
const CHEAT_XIRANG_AMOUNT := 1000
const SKILL1_MAX_UPGRADE_LEVEL := 4
const SKILL1_UPGRADE_CHARGE_REDUCTION := 2.0
const SKILL1_UPGRADE_COSTS := [500, 750, 1000, 2000]
const MAX_MULTIPLAYER_NAME_LENGTH := 12
const NAMEPLATE_SIZE := Vector2(160.0, 30.0)
const NAMEPLATE_WORLD_OFFSET := Vector2(0.0, -19.0)
const DEFAULT_NAMEPLATE_FONT_COLOR := Color(0.96, 0.98, 1.0, 1.0)
const LOCAL_NAMEPLATE_FONT_COLOR := Color(0.38, 1.0, 0.42, 1.0)
const HOMING_ENEMY_BODY_MASK := 4
const HOMING_TARGET_RADIUS := 256.0
const HOMING_TARGET_HALF_ANGLE := PI / 3.0
const HOMING_QUERY_MAX_RESULTS := 64
const MIN_SKILL_ACTIVATION_INTERVAL_MSEC := 100
const MULTIPLAYER_VISUAL_OFFSET_LERP_RATE := 36.0
const MULTIPLAYER_VISUAL_OFFSET_EPSILON := 0.05
const MULTIPLAYER_VISUAL_SNAP_DISTANCE := 96.0
const WORLD_COLLISION_MASK := 1
const WALL_ESCAPE_MAX_STEP_DISTANCE := 3.0
const WALL_ESCAPE_MIN_OUTWARD_DOT := 0.12
const WALL_ESCAPE_QUERY_MAX_RESULTS := 8
	
const BLINK_ENABLED_SHADER_PARAMETER := &"blink_enabled"
const DODGE_EFFECT_STRENGTH_SHADER_PARAMETER := &"dodge_effect_strength"
const DODGE_SWEEP_SHADER_PARAMETER := &"dodge_sweep"
const DASH_EFFECT_STRENGTH_SHADER_PARAMETER := &"dash_effect_strength"
const DASH_DIRECTION_SHADER_PARAMETER := &"dash_direction"
const DASH_READY_STRENGTH_SHADER_PARAMETER := &"ready_strength"
const SLOW_OVERLAY_STRENGTH_SHADER_PARAMETER := &"slow_overlay_strength"
const REVIVE_GLOW_STRENGTH_SHADER_PARAMETER := &"revive_glow_strength"
const REVIVE_GLOW_COLOR_SHADER_PARAMETER := &"revive_glow_color"
const REVIVE_GLOW_OUTLINE_WIDTH_SHADER_PARAMETER := &"revive_glow_outline_width"
const DODGE_EFFECT_DURATION := 0.28
const DASH_INPUT_MIN_LENGTH_SQUARED := 0.001
const DASH_VISUAL_FADE_DURATION := 0.06
const DASH_READY_REVEAL_DURATION := 0.2
const MULTIPLAYER_DASH_COOLDOWN_GRACE := 0.35
const REVIVE_GLOW_DURATION := 0.82
const REVIVE_GLOW_OUTLINE_WIDTH := 4.5
const REVIVE_GLOW_COLOR := Color(3.2, 3.2, 3.2, 1.0)
const SLOW_OVERLAY_ACTIVE_STRENGTH := 0.34
const ATTACK_SPEED_UPGRADE_INTERVAL_MULTIPLIER := 0.95
const DODGE_UPGRADE_CHANCE_STEP := 0.02
const DEFAULT_MAGIC_DEFENSE_LIMIT := 100
const RANGED_DIRECTION_SIDE_THRESHOLD := 0.35
const DEFAULT_SKILL1_DISPLAY_NAME := "技能"

var facing_suffix: StringName = &"right"

# 当前移动倍率，由道具效果驱动。
var current_move_speed_multiplier: float = DEFAULT_MOVE_SPEED_MULTIPLIER
# 当前射速道具提供的射速倍率。
var rapid_fire_rate_multiplier: float = DEFAULT_FIRE_RATE_MULTIPLIER
# 通用临时增益分别维护剩余持续时间，避免互相覆盖。
var speed_buff_time_left: float = 0.0
var rapid_buff_time_left: float = 0.0
var footstep_time_left: float = 0.0
var dodge_chance: float = 0.0
var skill1_unlocked: bool = false
var skill1_charge: float = 0.0
var skill1_upgrade_level: int = 0
var skill1_base_charge_duration: float = 0.0
var last_attack_direction: Vector2 = Vector2.RIGHT
var dodge_feedback_tween: Tween = null
var revive_glow_tween: Tween = null
var dash_ready_reveal_tween: Tween = null
var _dash_ready_visual_is_ready: bool = false
var damage_reduction_modifiers: Dictionary = {}
var collectible_periodic_cooldowns: Dictionary = {}
var collectible_shot_counters: Dictionary = {}
var collectible_trigger_cooldowns: Dictionary = {}
var collectible_swift_time_left: float = 0.0
var collectible_swift_move_speed_multiplier: float = 1.0
var collectible_physical_damage_bonus: int = 0
var collectible_magic_damage_bonus: int = 0
var collectible_dash_distance_bonus: float = 0.0
var collectible_dash_cooldown_reduction: float = 0.0
var collectible_attack_speed_bonus: float = 0.0
var collectible_skill_charge_bonus_per_second: float = 0.0
var collectible_skill_charge_preserve_chance: float = 0.0
var collectible_base_upgrade_free_chance: float = 0.0
var collectible_damage_against_burning_multiplier: float = 1.0
var collectible_damage_against_bleeding_multiplier: float = 1.0
var collectible_ranged_front_damage_multiplier: float = 1.0
var collectible_ranged_back_damage_multiplier: float = 1.0
var collectible_ranged_dodge_chance: float = 0.0
var linglan_skill2_config_cache: LinglanSkill2Config = null
var last_base_upgrade_was_free: bool = false
var _last_skill_activation_msec: int = -MIN_SKILL_ACTIVATION_INTERVAL_MSEC
var _base_stats_initialized: bool = false
var _base_move_speed: float = 0.0
var _base_max_health: int = 0
var _base_attack_damage: int = 0
var _base_physical_defense: int = 0
var _base_magic_defense: int = 0
var _base_fire_interval: float = 0.0
var multiplayer_visual_smoothing_enabled: bool = false
var multiplayer_visual_offset: Vector2 = Vector2.ZERO
var _body_sprite_base_position: Vector2 = Vector2.ZERO
var _speed_trail_effect_base_position: Vector2 = Vector2.ZERO
var _dash_ready_indicator_base_position: Vector2 = Vector2.ZERO
var _health_bar_base_position: Vector2 = Vector2.ZERO
var _attack_interval_bar_base_position: Vector2 = Vector2.ZERO
var _skill1_charge_bar_base_position: Vector2 = Vector2.ZERO
var _name_label_base_position: Vector2 = Vector2.ZERO
var _nameplate_label_settings: LabelSettings = null
var _nameplate_default_font_color: Color = DEFAULT_NAMEPLATE_FONT_COLOR


# 节点首次进入场景树时的初始化逻辑
func _ready() -> void:
	_initialize_base_stats()
	_connect_collectible_refresh_signals()
	_refresh_collectible_stats(false)
	_ensure_skill1_base_charge_duration()
	current_health = maxi(max_health, 1)
	_initialize_character_resources()
	shooting_timer.one_shot = true
	shooting_timer.wait_time = _get_effective_fire_interval()
	_set_hurt_blink_enabled(false)
	_set_dash_effect_strength(0.0)
	_set_revive_glow_strength(0.0)
	_update_movement_status_visuals(Vector2.ZERO)
	_cache_multiplayer_visual_base_positions()
	_refresh_dash_ready_visual()
	_initialize_nameplate_label_settings()
	health_bar.setup(max_health, current_health)
	name_label.visible = false
	nameplate_layer.visible = false
	health_changed.emit(current_health, max_health)
	_update_animation()
	_update_character_visual_state()
	_update_skill1_charge_bar()
	_update_attack_interval_bar()
	get_window().focus_exited.connect(_on_window_focus_exited)


func _initialize_base_stats() -> void:
	if _base_stats_initialized:
		return
	assert(character_id != &"", "Player subclasses must define a non-empty character_id.")
	var character_config := get_character_config()
	assert(character_config != null, "Missing PlayerCharacterConfig for '%s'." % character_id)
	move_speed = character_config.starting_move_speed
	max_health = character_config.starting_max_health
	attack_damage = character_config.starting_attack_damage
	attack_speed_units_per_attack = character_config.attack_speed_units_per_attack
	fire_interval = (
		attack_speed_units_per_attack
		/ maxf(character_config.starting_attack_speed, 1.0)
	)
	_base_move_speed = move_speed
	_base_max_health = max_health
	_base_attack_damage = attack_damage
	_base_physical_defense = physical_defense
	_base_magic_defense = magic_defense
	_base_fire_interval = fire_interval
	_base_stats_initialized = true


func _connect_collectible_refresh_signals() -> void:
	var run_state := get_node_or_null("/root/RunState") as RunStateStore
	if run_state != null and not run_state.inventory_changed.is_connected(_on_collectible_inventory_changed):
		run_state.inventory_changed.connect(_on_collectible_inventory_changed)
	if not xirang_changed.is_connected(_on_collectible_xirang_changed):
		xirang_changed.connect(_on_collectible_xirang_changed)


func _process(_delta: float) -> void:
	_update_remote_dash_visual(_delta)
	_update_multiplayer_visual_smoothing(_delta)
	_update_nameplate_position()
	_update_character_combat_state(_delta)


func _input(event: InputEvent) -> void:
	if not uses_local_input:
		return

	var mouse_motion := event as InputEventMouseMotion
	if mouse_motion != null:
		mouse_viewport_position = mouse_motion.position
		return

	var mouse_event := event as InputEventMouseButton
	if mouse_event == null:
		return
	mouse_viewport_position = mouse_event.position
	if mouse_event.button_index == MOUSE_BUTTON_LEFT and not mouse_event.pressed:
		mouse_fire_held = false


func _unhandled_input(event: InputEvent) -> void:
	if not uses_local_input:
		return

	if event.is_action_pressed("cheat_xirang"):
		_apply_cheat_xirang()
		get_viewport().set_input_as_handled()
		return

	if event.is_action_pressed("skill1"):
		if _try_use_skill1():
			get_viewport().set_input_as_handled()
		return

	if event.is_action_pressed("reload"):
		if _try_start_reload():
			get_viewport().set_input_as_handled()
		return

	var mouse_event := event as InputEventMouseButton
	if mouse_event == null or mouse_event.button_index != MOUSE_BUTTON_LEFT:
		return

	mouse_fire_held = mouse_event.pressed and not controls_locked and not is_dead
	if mouse_fire_held:
		get_viewport().set_input_as_handled()


# 物理帧更新，处理玩家移动、射击和无敌/增益状态更新
func _physics_process(delta: float) -> void:
	_update_invincibility(delta)
	_update_pickup_effects(delta)
	_update_collectible_runtime_effects(delta)
	_update_skill1_charge(delta)
	_update_character_resources(delta)
	_update_attack_interval_bar()
	
	if is_dead:
		velocity = Vector2.ZERO
		_update_movement_status_visuals(Vector2.ZERO)
		return

	if controls_locked:
		velocity = Vector2.ZERO
		_update_footstep_audio(delta, Vector2.ZERO)
		_update_animation()
		_update_character_visual_state()
		_update_movement_status_visuals(Vector2.ZERO)
		return
	
	var move_input := _get_current_move_input()
	var shoot_input := _get_current_shoot_input()
	if uses_local_input and Input.is_action_just_pressed(&"dash"):
		_try_start_dash(move_input)
	if uses_local_input and mouse_fire_held:
		shoot_input = _get_mouse_shoot_direction()
	if not uses_local_input and network_reload_requested:
		network_reload_requested = false
		_try_start_reload()

	var dash_was_active := is_dashing()
	var movement_visual_direction := dash_direction if dash_was_active else move_input
	if dash_was_active:
		_perform_dash_movement(delta)
	else:
		velocity = move_input * _get_effective_move_speed()
		if not _try_apply_wall_overlap_escape(move_input, delta):
			move_and_slide()
	_update_movement_status_visuals(movement_visual_direction)
	_update_footstep_audio(delta, Vector2.ZERO if dash_was_active else move_input)

	_handle_primary_attack_input(shoot_input)

	_update_facing(movement_visual_direction, shoot_input)
	_update_animation()
	_update_character_visual_state()


func _update_character_combat_state(_delta: float) -> void:
	pass


func _initialize_character_resources() -> void:
	pass


func _update_character_resources(_delta: float) -> void:
	pass


func _update_character_visual_state() -> void:
	pass


func _handle_primary_attack_input(shoot_input: Vector2) -> void:
	if shoot_input != Vector2.ZERO:
		_try_shoot(shoot_input)


# 根据玩家当前形态和朝向更新基础动画序列
func _update_animation() -> void:
	var animation_name := StringName("%s_%s" % [_get_animation_prefix(), facing_suffix])

	if not body_sprite.sprite_frames.has_animation(animation_name):
		var fallback_animation_name := StringName("%s_%s" % [NORMAL_ANIMATION_PREFIX, facing_suffix])
		if not body_sprite.sprite_frames.has_animation(fallback_animation_name):
			push_warning("Missing player animation: %s" % animation_name)
			return
		animation_name = fallback_animation_name

	if body_sprite.animation != animation_name or not body_sprite.is_playing():
		body_sprite.play(animation_name)


# 尝试进行一次常规射击
func _try_shoot(shoot_input: Vector2) -> void:
	if not shooting_timer.is_stopped():
		return
	if not _can_perform_primary_attack():
		return

	var shoot_direction := shoot_input.normalized()
	var attack_performed := _perform_primary_attack(shoot_direction)

	if attack_performed:
		_consume_primary_attack_resource()
		if shooting_timer.is_stopped():
			shooting_timer.start(_get_effective_fire_interval())
		_update_attack_interval_bar()


func _perform_primary_attack(_attack_direction: Vector2) -> bool:
	return false


func _can_perform_primary_attack() -> bool:
	return true


func _consume_primary_attack_resource() -> void:
	pass


func uses_ammunition() -> bool:
	return false


func supports_projectile_attack_patterns() -> bool:
	return false


func is_collectible_compatible(item: PickupConfig) -> bool:
	if item == null:
		return false
	if item.requires_projectile_primary_attack and not supports_projectile_attack_patterns():
		return false
	return true


func uses_attack_interval_bar() -> bool:
	return false


func plays_multiplayer_death_animation() -> bool:
	return false


func notify_primary_attack_performed() -> void:
	_trigger_collectible_primary_attack_effects()

# 应用道具效果，更新玩家形态、射速、移速等增益状态
func apply_pickup(config: PickupConfig) -> bool:
	if config == null:
		return false
		
	var applied := false
	var should_refresh_shooting_timer := false
	var buff_duration := maxf(config.duration, 0.0)
	var requests_projectile_form_override := (
		config.player_form_mode != PickupConfig.PlayerFormMode.NORMAL
		or config.shot_pattern != PickupConfig.ShotPattern.NORMAL
	)
	var has_form_override := requests_projectile_form_override and supports_projectile_attack_patterns()

	var has_fire_rate_override := not is_equal_approx(
		config.fire_rate_multiplier,
		DEFAULT_FIRE_RATE_MULTIPLIER
	)

	if not is_equal_approx(config.move_speed_multiplier, DEFAULT_MOVE_SPEED_MULTIPLIER):
		current_move_speed_multiplier = config.move_speed_multiplier
		speed_buff_time_left = buff_duration
		applied = true

	if config.heal_amount > 0:
		applied = _try_heal(config.heal_amount) or applied

	# 普通射速道具与形态专属射速提升维护，避免螺旋形态的射速被其他 Buff 状态覆盖。
	if has_fire_rate_override and not requests_projectile_form_override:
		rapid_fire_rate_multiplier = config.fire_rate_multiplier
		rapid_buff_time_left = buff_duration
		should_refresh_shooting_timer = true
		applied = true
	if has_form_override:
		var character_pickup_applied := _apply_character_pickup(config, buff_duration)
		should_refresh_shooting_timer = character_pickup_applied
		applied = character_pickup_applied or applied

	if should_refresh_shooting_timer:
		_refresh_shooting_timer_wait_time()
	if applied:
		_play_pickup_audio(config, has_form_override)
	return applied


func _apply_character_pickup(_config: PickupConfig, _buff_duration: float) -> bool:
	return false
	
# 敌人或其他伤害来源统一通过这个入口让玩家受伤。
func apply_damage(
	amount: int,
	damage_type: EnemyConfig.DamageType = EnemyConfig.DamageType.PHYSICAL,
	damage_context: Dictionary = {}
) -> bool:
	if is_dead:
		return false

	if amount <= 0:
		return false

	if is_dash_invulnerable() or invincibility_time_left > 0.0:
		return false

	if dodge_chance > 0.0 and randf() < dodge_chance:
		_start_dodge_feedback()
		_start_invincibility(false)
		return false

	if _try_collectible_ranged_dodge(damage_context):
		_start_dodge_feedback()
		_start_invincibility(false)
		return false

	var adjusted_amount := _apply_collectible_ranged_damage_multiplier(amount, damage_context)
	var final_damage := _calculate_incoming_damage(adjusted_amount, damage_type)
	current_health = maxi(current_health - final_damage, 0)
	health_bar.set_health(current_health, max_health)
	health_changed.emit(current_health, max_health)
	_refresh_collectible_stats(false)
	if current_health <= 0:
		_die()
		return true

	_trigger_collectible_hurt_effects()
	_start_invincibility()
	return true


func _try_collectible_ranged_dodge(damage_context: Dictionary) -> bool:
	if collectible_ranged_dodge_chance <= 0.0:
		return false
	if not _is_ranged_damage_context(damage_context):
		return false
	return randf() < collectible_ranged_dodge_chance


func _apply_collectible_ranged_damage_multiplier(
	amount: int,
	damage_context: Dictionary
) -> int:
	if amount <= 0 or not _is_ranged_damage_context(damage_context):
		return amount
	var source_side := _get_damage_source_side_direction(damage_context)
	if source_side == Vector2.ZERO:
		return amount
	var facing_direction := _facing_suffix_to_vector(facing_suffix)
	var side_dot := facing_direction.dot(source_side.normalized())
	var multiplier := 1.0
	if side_dot >= RANGED_DIRECTION_SIDE_THRESHOLD:
		multiplier = collectible_ranged_front_damage_multiplier
	elif side_dot <= -RANGED_DIRECTION_SIDE_THRESHOLD:
		multiplier = collectible_ranged_back_damage_multiplier
	if is_equal_approx(multiplier, 1.0):
		return amount
	return maxi(roundi(float(amount) * maxf(multiplier, 0.0)), 1)


func _is_ranged_damage_context(damage_context: Dictionary) -> bool:
	return bool(damage_context.get("is_ranged", false))


func _get_damage_source_side_direction(damage_context: Dictionary) -> Vector2:
	var source_direction_variant: Variant = damage_context.get("source_direction", Vector2.ZERO)
	if source_direction_variant is Vector2:
		var source_direction := source_direction_variant as Vector2
		if source_direction.length_squared() > 0.001:
			return source_direction.normalized()
	return Vector2.ZERO


func _calculate_incoming_damage(
	amount: int,
	damage_type: EnemyConfig.DamageType
) -> int:
	match damage_type:
		EnemyConfig.DamageType.MAGIC:
			var defense_ratio := float(100 - clampi(magic_defense, 0, 100)) / 100.0
			return _apply_damage_reduction(maxi(floori(float(amount) * defense_ratio), 1))
		_:
			return _apply_damage_reduction(maxi(amount - maxi(physical_defense, 0), 1))


func _apply_damage_reduction(amount: int) -> int:
	var strongest_reduction := 0.0
	for reduction in damage_reduction_modifiers.values():
		strongest_reduction = maxf(strongest_reduction, float(reduction))
	if strongest_reduction <= 0.0:
		return amount
	return maxi(floori(float(amount) * (1.0 - clampf(strongest_reduction, 0.0, 0.95))), 1)
	
# 获取当前生命值
func get_current_health() -> int:
	return current_health


func get_character_id() -> StringName:
	return character_id


func get_character_config() -> PlayerCharacterConfig:
	return PlayerCharacterRegistry.get_config(character_id)


func get_skill1_display_name() -> String:
	var config := get_character_config()
	if config != null and not config.skill_display_name.is_empty():
		return config.skill_display_name
	return DEFAULT_SKILL1_DISPLAY_NAME


func get_skill1_description() -> String:
	var config := get_character_config()
	if config != null and not config.skill_description.is_empty():
		return config.skill_description
	return ""


func get_skill1_icon() -> Texture2D:
	var config := get_character_config()
	if config != null and not config.skill_icon_texture.is_empty():
		return load(config.skill_icon_texture) as Texture2D
	return null


func get_skill1_icon_path() -> String:
	var icon := get_skill1_icon()
	return icon.resource_path if icon != null else ""


func get_attacks_per_second() -> float:
	return 1.0 / _get_effective_fire_interval()


func get_attack_speed() -> float:
	return get_attacks_per_second() * maxf(attack_speed_units_per_attack, 1.0)


func refresh_collectible_stats() -> void:
	_refresh_collectible_stats()


func has_collectible_effect(effect_id: String) -> bool:
	if effect_id.is_empty():
		return false
	for item in _get_active_collectible_items():
		if item.collectible_effect_id == effect_id:
			return true
	return false


func get_outgoing_damage(
	base_amount: int,
	damage_type: EnemyConfig.DamageType = EnemyConfig.DamageType.PHYSICAL
) -> int:
	var bonus := (
		collectible_magic_damage_bonus
		if damage_type == EnemyConfig.DamageType.MAGIC
		else collectible_physical_damage_bonus
	)
	return maxi(base_amount + bonus, 1)


func resolve_attack_damage_against_enemy(base_damage: int, enemy: Enemy) -> int:
	if base_damage <= 0:
		return 0
	if enemy == null or not is_instance_valid(enemy):
		return base_damage
	var target_multiplier := 1.0
	if enemy.has_collectible_status(&"burn"):
		target_multiplier *= collectible_damage_against_burning_multiplier
	if enemy.has_collectible_status(&"bleed"):
		target_multiplier *= collectible_damage_against_bleeding_multiplier
	return maxi(roundi(float(base_damage) * maxf(target_multiplier, 0.0)), 1)


func get_collectible_outgoing_damage(
	base_amount: int,
	damage_type: EnemyConfig.DamageType
) -> int:
	if base_amount <= 0:
		return 0
	return get_outgoing_damage(base_amount, damage_type)


func try_trigger_free_base_upgrade() -> bool:
	last_base_upgrade_was_free = false
	if collectible_base_upgrade_free_chance <= 0.0:
		return false
	if randf() >= collectible_base_upgrade_free_chance:
		return false
	last_base_upgrade_was_free = true
	if uses_local_input:
		play_lucky_upgrade_feedback()
	return true


func consume_last_base_upgrade_free_flag() -> bool:
	var was_free := last_base_upgrade_was_free
	last_base_upgrade_was_free = false
	return was_free


func play_lucky_upgrade_feedback() -> void:
	if lucky_upgrade_audio == null:
		return
	lucky_upgrade_audio.pitch_scale = 1.0
	lucky_upgrade_audio.play()


func get_skill1_projectile_damage() -> int:
	return 0


func add_damage_reduction_modifier(source_id: int, reduction: float) -> void:
	if source_id == 0:
		return
	damage_reduction_modifiers[source_id] = clampf(reduction, 0.0, 0.95)


func remove_damage_reduction_modifier(source_id: int) -> void:
	damage_reduction_modifiers.erase(source_id)


func set_controls_locked(locked: bool) -> void:
	controls_locked = locked
	if controls_locked:
		_finish_dash()
		mouse_fire_held = false
		velocity = Vector2.ZERO
		footstep_audio.stop()
	_refresh_dash_ready_visual()


func configure_multiplayer_control(
	new_peer_id: int,
	use_local_input: bool,
	display_name: String = "",
	predict_movement_only: bool = false,
	highlight_as_local_player: bool = false
) -> void:
	peer_id = new_peer_id
	uses_local_input = use_local_input
	client_movement_prediction_only = predict_movement_only
	mouse_fire_held = false
	network_move_input = Vector2.ZERO
	network_shoot_input = Vector2.ZERO
	network_reload_requested = false
	_finish_dash()
	_stop_remote_dash_visual()
	multiplayer_dash_protection_time_left = 0.0
	dash_cooldown_timer.stop()
	var safe_display_name := display_name.strip_edges()
	if safe_display_name.length() > MAX_MULTIPLAYER_NAME_LENGTH:
		safe_display_name = safe_display_name.left(MAX_MULTIPLAYER_NAME_LENGTH)
	multiplayer_display_name = safe_display_name
	name_label.visible = false
	nameplate_label.text = safe_display_name
	_set_nameplate_local_highlight(highlight_as_local_player)
	nameplate_layer.visible = not safe_display_name.is_empty()
	_update_nameplate_position()
	if not uses_local_input:
		controls_locked = false
	_refresh_dash_ready_visual()


func _set_nameplate_local_highlight(enabled: bool) -> void:
	if _nameplate_label_settings == null:
		_initialize_nameplate_label_settings()
	if _nameplate_label_settings == null:
		return
	nameplate_label.remove_theme_color_override(&"font_color")
	if enabled:
		_nameplate_label_settings.font_color = LOCAL_NAMEPLATE_FONT_COLOR
	else:
		_nameplate_label_settings.font_color = _nameplate_default_font_color


func _initialize_nameplate_label_settings() -> void:
	if nameplate_label == null:
		return
	var authored_settings := nameplate_label.label_settings
	if authored_settings == null:
		return
	_nameplate_default_font_color = authored_settings.font_color
	_nameplate_label_settings = authored_settings.duplicate() as LabelSettings
	nameplate_label.label_settings = _nameplate_label_settings


func set_multiplayer_visual_smoothing_enabled(enabled: bool) -> void:
	multiplayer_visual_smoothing_enabled = enabled
	if not enabled:
		_set_multiplayer_visual_offset(Vector2.ZERO)


func is_multiplayer_visual_smoothing_enabled() -> bool:
	return multiplayer_visual_smoothing_enabled


func get_multiplayer_visual_global_position() -> Vector2:
	return global_position + multiplayer_visual_offset


func _cache_multiplayer_visual_base_positions() -> void:
	_body_sprite_base_position = body_sprite.position
	_speed_trail_effect_base_position = speed_trail_effect.position
	_dash_ready_indicator_base_position = dash_ready_indicator.position
	_health_bar_base_position = health_bar.position
	if attack_interval_bar != null:
		_attack_interval_bar_base_position = attack_interval_bar.position
	_skill1_charge_bar_base_position = skill1_charge_bar.position
	_name_label_base_position = name_label.position
	_cache_character_visual_base_positions()


func _cache_character_visual_base_positions() -> void:
	pass


func _get_multiplayer_visual_offset_after_position_change(next_position: Vector2) -> Vector2:
	if not multiplayer_visual_smoothing_enabled:
		return Vector2.ZERO
	var next_offset := get_multiplayer_visual_global_position() - next_position
	if next_offset.length_squared() > MULTIPLAYER_VISUAL_SNAP_DISTANCE * MULTIPLAYER_VISUAL_SNAP_DISTANCE:
		return Vector2.ZERO
	return next_offset


func _update_multiplayer_visual_smoothing(delta: float) -> void:
	if not multiplayer_visual_smoothing_enabled:
		return
	if multiplayer_visual_offset.length_squared() <= MULTIPLAYER_VISUAL_OFFSET_EPSILON * MULTIPLAYER_VISUAL_OFFSET_EPSILON:
		if multiplayer_visual_offset != Vector2.ZERO:
			_set_multiplayer_visual_offset(Vector2.ZERO)
		return
	var blend := clampf(delta * MULTIPLAYER_VISUAL_OFFSET_LERP_RATE, 0.0, 1.0)
	_set_multiplayer_visual_offset(multiplayer_visual_offset.lerp(Vector2.ZERO, blend))


func _set_multiplayer_visual_offset(offset: Vector2) -> void:
	multiplayer_visual_offset = offset
	if body_sprite == null:
		return
	body_sprite.position = _body_sprite_base_position + offset
	speed_trail_effect.position = _speed_trail_effect_base_position + offset
	dash_ready_indicator.position = _dash_ready_indicator_base_position + offset
	health_bar.position = _health_bar_base_position + offset
	if attack_interval_bar != null:
		attack_interval_bar.position = _attack_interval_bar_base_position + offset
	skill1_charge_bar.position = _skill1_charge_bar_base_position + offset
	name_label.position = _name_label_base_position + offset
	_set_character_visual_offset(offset)
	_update_nameplate_position()


func _set_character_visual_offset(_offset: Vector2) -> void:
	pass


func apply_network_input(
	move_input: Vector2,
	shoot_input: Vector2,
	_use_skill1: bool = false,
	use_reload: bool = false
) -> void:
	network_move_input = move_input.limit_length(1.0)
	network_shoot_input = shoot_input.limit_length(1.0)
	network_reload_requested = network_reload_requested or use_reload


func apply_remote_multiplayer_state(
	remote_position: Vector2,
	remote_velocity: Vector2,
	shoot_input: Vector2,
	use_skill1: bool = false,
	use_reload: bool = false
) -> void:
	var next_visual_offset := _get_multiplayer_visual_offset_after_position_change(remote_position)
	global_position = remote_position
	if multiplayer_visual_smoothing_enabled:
		_set_multiplayer_visual_offset(next_visual_offset)
	apply_remote_multiplayer_view_state(remote_velocity, shoot_input, use_skill1, use_reload)


func apply_remote_multiplayer_view_state(
	remote_velocity: Vector2,
	shoot_input: Vector2,
	_use_skill1: bool = false,
	use_reload: bool = false
) -> void:
	velocity = remote_velocity
	network_shoot_input = shoot_input.limit_length(1.0)
	if use_reload:
		_try_start_reload()
	_update_facing(remote_velocity, network_shoot_input)
	_update_animation()
	_update_character_visual_state()


func update_multiplayer_authority_passive_state(delta: float) -> void:
	_update_invincibility(delta)
	_update_multiplayer_dash_protection(delta)
	_update_pickup_effects(delta)
	_update_collectible_runtime_effects(delta)
	_update_skill1_charge(delta)
	_update_character_resources(delta)
	_update_attack_interval_bar()
	if is_dead:
		return
	_update_animation()
	_update_character_visual_state()


func consume_multiplayer_skill1_charge() -> bool:
	return try_begin_skill1_activation(true)


func try_begin_skill1_activation(authoritative_preserve_roll: bool = true) -> bool:
	if not skill1_unlocked:
		return false
	if is_dead or controls_locked:
		return false
	_sync_skill1_charge_duration_to_upgrade_level()
	if skill1_charge < skill1_charge_duration:
		return false
	var now_msec := Time.get_ticks_msec()
	if now_msec - _last_skill_activation_msec < MIN_SKILL_ACTIVATION_INTERVAL_MSEC:
		return false
	_last_skill_activation_msec = now_msec
	if not _should_preserve_skill1_charge(authoritative_preserve_roll):
		skill1_charge = 0.0
	_update_skill1_charge_bar()
	return true


func _should_preserve_skill1_charge(authoritative_roll: bool) -> bool:
	var preserve_chance := clampf(collectible_skill_charge_preserve_chance, 0.0, 1.0)
	if preserve_chance >= 1.0:
		return true
	if preserve_chance <= 0.0 or not authoritative_roll:
		return false
	return randf() < preserve_chance


func _uses_authoritative_skill_preserve_roll() -> bool:
	return not multiplayer.has_multiplayer_peer() or multiplayer.is_server()


func apply_multiplayer_snapshot_motion(
	remote_position: Vector2,
	remote_velocity: Vector2,
	facing_id: int,
	anim_state: int
) -> void:
	global_position = remote_position
	velocity = remote_velocity
	if is_dead:
		return
	_set_multiplayer_facing_id(facing_id)
	_apply_multiplayer_character_anim_state(anim_state)
	_update_animation()
	_update_character_visual_state()


func apply_multiplayer_realtime_state(
	new_current_health: int,
	new_max_health: int,
	new_current_xirang: int,
	new_is_dead: bool,
	new_invincibility_time_left: float,
	new_skill1_unlocked: bool,
	new_skill1_charge: float,
	new_skill1_charge_duration: float,
	new_form_mode: int,
	new_shot_pattern: int,
	new_skill1_upgrade_level: int = -1,
	new_ammo_capacity: int = -1,
	new_current_ammo: int = -1,
	new_is_reloading: bool = false,
	new_reload_progress: float = 0.0
) -> void:
	max_health = maxi(new_max_health, 1)
	current_xirang = maxi(new_current_xirang, 0)
	xirang_changed.emit(current_xirang, 0)
	_apply_multiplayer_character_realtime_state(
		new_form_mode,
		new_shot_pattern,
		new_ammo_capacity,
		new_current_ammo,
		new_is_reloading,
		new_reload_progress
	)
	skill1_unlocked = new_skill1_unlocked
	if not skill1_unlocked:
		skill1_upgrade_level = 0
	elif new_skill1_upgrade_level >= 0:
		skill1_upgrade_level = clampi(
			new_skill1_upgrade_level,
			0,
			SKILL1_MAX_UPGRADE_LEVEL
		)
	if (
		new_skill1_charge_duration > 0.0
		and new_skill1_upgrade_level < 0
		and skill1_base_charge_duration <= 0.0
	):
		_set_skill1_base_charge_duration_from_current_level(new_skill1_charge_duration)
	else:
		_ensure_skill1_base_charge_duration()
	_sync_skill1_charge_duration_to_upgrade_level()
	skill1_charge = clampf(new_skill1_charge, 0.0, skill1_charge_duration)
	rapid_buff_time_left = 0.0
	speed_buff_time_left = 0.0
	var clamped_health: int = clampi(new_current_health, 0, max_health)
	if new_is_dead or clamped_health <= 0:
		apply_multiplayer_death_state()
		_update_skill1_charge_bar()
		_update_character_visual_state()
		return
	if is_dead:
		revive_multiplayer(global_position, clamped_health, new_invincibility_time_left)
	else:
		current_health = clamped_health
		health_bar.visible = true
		health_bar.setup(max_health, current_health)
		health_changed.emit(current_health, max_health)
	invincibility_time_left = maxf(new_invincibility_time_left, 0.0)
	_set_hurt_blink_enabled(invincibility_time_left > 0.0)
	_refresh_shooting_timer_wait_time()
	_update_skill1_charge_bar()
	_update_animation()
	_update_character_visual_state()


func _apply_multiplayer_character_anim_state(_anim_state: int) -> void:
	pass


func _apply_multiplayer_character_realtime_state(
	_form_mode: int,
	_shot_pattern: int,
	_ammo_capacity: int,
	_current_ammo: int,
	_is_reloading: bool,
	_reload_progress: float
) -> void:
	pass


func has_active_multiplayer_character_state() -> bool:
	return false


func get_multiplayer_form_mode() -> int:
	return PickupConfig.PlayerFormMode.NORMAL


func get_multiplayer_shot_pattern() -> int:
	return PickupConfig.ShotPattern.NORMAL


func get_multiplayer_ammo_capacity() -> int:
	return 1


func get_multiplayer_current_ammo() -> int:
	return 0


func get_multiplayer_is_reloading() -> bool:
	return false


func get_multiplayer_reload_progress() -> float:
	return 0.0

func _update_nameplate_position() -> void:
	if not nameplate_layer.visible:
		return
	var anchor := get_global_transform_with_canvas() * (NAMEPLATE_WORLD_OFFSET + multiplayer_visual_offset)
	nameplate_label.position = (anchor - Vector2(NAMEPLATE_SIZE.x * 0.5, NAMEPLATE_SIZE.y)).round()


func set_multiplayer_health_state(new_health: int, new_is_dead: bool) -> void:
	var clamped_health := clampi(new_health, 0, max_health)
	current_health = clamped_health
	if new_is_dead or clamped_health <= 0:
		apply_multiplayer_death_state()
		return

	if is_dead:
		revive_multiplayer(global_position, clamped_health, 0.0)
		return

	health_bar.visible = true
	health_bar.set_health(current_health, max_health)
	health_changed.emit(current_health, max_health)


func revive_multiplayer(revive_position: Vector2, revived_health: int = -1, invincible_seconds: float = 0.0) -> void:
	var was_dead := is_dead
	global_position = revive_position
	_set_multiplayer_visual_offset(Vector2.ZERO)
	is_dead = false
	controls_locked = false
	mouse_fire_held = false
	velocity = Vector2.ZERO
	current_health = max_health if revived_health < 0 else clampi(revived_health, 1, max_health)
	body_sprite.visible = true
	_update_movement_status_visuals(Vector2.ZERO)
	if collision_shape != null:
		collision_shape.set_deferred("disabled", false)
	health_bar.visible = true
	health_bar.set_health(current_health, max_health)
	health_changed.emit(current_health, max_health)
	_reset_character_resources_on_revive()
	_update_multiplayer_nameplate_text(-1)
	_update_skill1_charge_bar()
	_update_animation()
	_update_character_visual_state()
	if invincible_seconds > 0.0:
		start_multiplayer_invincibility(invincible_seconds)
	else:
		invincibility_time_left = 0.0
		_set_hurt_blink_enabled(false)
	_refresh_dash_ready_visual()
	if was_dead and uses_local_input:
		_start_local_revive_glow_effect()


func start_multiplayer_invincibility(seconds: float) -> void:
	invincibility_time_left = maxf(seconds, 0.0)
	_set_hurt_blink_enabled(invincibility_time_left > 0.0)


func set_multiplayer_revive_countdown(seconds_left: int) -> void:
	_update_multiplayer_nameplate_text(seconds_left)


func apply_multiplayer_death_state() -> void:
	var was_dead := is_dead
	_set_multiplayer_visual_offset(Vector2.ZERO)
	is_dead = true
	controls_locked = true
	_finish_dash()
	_stop_remote_dash_visual()
	multiplayer_dash_protection_time_left = 0.0
	mouse_fire_held = false
	network_move_input = Vector2.ZERO
	network_shoot_input = Vector2.ZERO
	network_reload_requested = false
	velocity = Vector2.ZERO
	_update_movement_status_visuals(Vector2.ZERO)
	current_health = 0
	invincibility_time_left = 0.0
	_set_hurt_blink_enabled(false)
	_stop_dodge_feedback()
	_stop_revive_glow_effect()
	shooting_timer.stop()
	_cleanup_character_combat_on_death()
	footstep_audio.stop()
	health_bar.set_health(0, max_health)
	health_bar.visible = false
	_update_skill1_charge_bar()
	if plays_multiplayer_death_animation():
		if not was_dead or not body_sprite.visible or body_sprite.animation != &"death":
			_play_death_animation()
	else:
		body_sprite.visible = false
		body_sprite.stop()
	if collision_shape != null:
		collision_shape.set_deferred("disabled", true)
	_refresh_dash_ready_visual()
	health_changed.emit(current_health, max_health)
	if not was_dead:
		death_audio.play()
		died.emit()


func _reset_character_resources_on_revive() -> void:
	pass


func _cleanup_character_combat_on_death() -> void:
	pass


func grant_multiplayer_xirang(amount: int) -> bool:
	if amount <= 0:
		return false
	current_xirang += amount
	xirang_changed.emit(current_xirang, amount)
	if uses_local_input:
		xirang_pickup_audio.pitch_scale = randf_range(1.12, 1.26)
		xirang_pickup_audio.play()
	return true


func grant_cheat_xirang(amount: int = CHEAT_XIRANG_AMOUNT) -> bool:
	return _grant_xirang_unrestricted(amount)


func _update_multiplayer_nameplate_text(seconds_left: int) -> void:
	var base_name := multiplayer_display_name
	if seconds_left >= 0:
		var prefix: String = base_name if not base_name.is_empty() else name
		nameplate_label.text = "%s %ds" % [prefix, seconds_left]
		nameplate_layer.visible = true
	else:
		nameplate_label.text = base_name
		nameplate_layer.visible = not base_name.is_empty()
	_update_nameplate_position()

func get_xirang() -> int:
	return current_xirang


func add_xirang(amount: int) -> bool:
	if is_dead:
		return false
	if amount <= 0:
		return false

	current_xirang += amount
	xirang_changed.emit(current_xirang, amount)
	xirang_pickup_audio.pitch_scale = randf_range(1.12, 1.26)
	xirang_pickup_audio.play()
	return true


func _grant_xirang_unrestricted(amount: int) -> bool:
	if amount <= 0:
		return false

	current_xirang += amount
	xirang_changed.emit(current_xirang, amount)
	if uses_local_input:
		xirang_pickup_audio.pitch_scale = randf_range(1.12, 1.26)
		xirang_pickup_audio.play()
	return true


func _apply_cheat_xirang() -> void:
	var current_scene := get_tree().current_scene
	if current_scene != null and current_scene.has_method("request_multiplayer_cheat_xirang"):
		current_scene.call("request_multiplayer_cheat_xirang")
		return
	grant_cheat_xirang()


func has_skill1() -> bool:
	return skill1_unlocked


func try_purchase_skill1(cost: int) -> bool:
	if skill1_unlocked:
		return false
	if cost < 0:
		return false
	if current_xirang < cost:
		return false

	current_xirang -= cost
	xirang_changed.emit(current_xirang, -cost)
	unlock_skill1()
	return true


func unlock_skill1() -> bool:
	if skill1_unlocked:
		return false
	_ensure_skill1_base_charge_duration()
	skill1_unlocked = true
	skill1_charge = 0.0
	_sync_skill1_charge_duration_to_upgrade_level()
	_update_skill1_charge_bar()
	_refresh_collectible_stats(false)
	_play_skill_progress_feedback()
	return true


func get_skill1_upgrade_cost() -> int:
	if not skill1_unlocked:
		return -1
	if is_skill1_upgrade_maxed():
		return -1
	return int(SKILL1_UPGRADE_COSTS[skill1_upgrade_level])


func is_skill1_upgrade_maxed() -> bool:
	return skill1_upgrade_level >= SKILL1_MAX_UPGRADE_LEVEL


func try_upgrade_skill1(free: bool = false) -> bool:
	if not skill1_unlocked:
		return false
	if is_skill1_upgrade_maxed():
		return false
	var upgrade_cost := get_skill1_upgrade_cost()
	if upgrade_cost < 0:
		return false
	if not free:
		if current_xirang < upgrade_cost:
			return false
		current_xirang -= upgrade_cost
		xirang_changed.emit(current_xirang, -upgrade_cost)

	_apply_next_skill1_upgrade()
	return true


func try_upgrade_skill1_free() -> bool:
	return try_upgrade_skill1(true)


func apply_skill1_upgrade_state(upgrade_level: int, _charge_duration: float = -1.0) -> void:
	skill1_upgrade_level = clampi(upgrade_level, 0, SKILL1_MAX_UPGRADE_LEVEL)
	_ensure_skill1_base_charge_duration()
	_sync_skill1_charge_duration_to_upgrade_level()
	_update_skill1_charge_bar()


func _apply_next_skill1_upgrade() -> void:
	_ensure_skill1_base_charge_duration()
	skill1_upgrade_level = mini(skill1_upgrade_level + 1, SKILL1_MAX_UPGRADE_LEVEL)
	_sync_skill1_charge_duration_to_upgrade_level()
	_update_skill1_charge_bar()
	_play_skill_progress_feedback()


func _play_skill_progress_feedback() -> void:
	if powerup_audio != null:
		powerup_audio.play()


func _ensure_skill1_base_charge_duration() -> void:
	if skill1_base_charge_duration > 0.0:
		return
	skill1_base_charge_duration = maxf(
		skill1_charge_duration
		+ float(skill1_upgrade_level) * SKILL1_UPGRADE_CHARGE_REDUCTION,
		0.01
	)


func _set_skill1_base_charge_duration_from_current_level(current_duration: float) -> void:
	skill1_base_charge_duration = maxf(
		current_duration
		+ float(skill1_upgrade_level) * SKILL1_UPGRADE_CHARGE_REDUCTION,
		0.01
	)


func _sync_skill1_charge_duration_to_upgrade_level() -> void:
	_ensure_skill1_base_charge_duration()
	skill1_charge_duration = _get_skill1_duration_for_level(skill1_upgrade_level)
	skill1_charge = minf(skill1_charge, skill1_charge_duration)


func _get_skill1_duration_for_level(level: int) -> float:
	return maxf(
		skill1_base_charge_duration
		- float(clampi(level, 0, SKILL1_MAX_UPGRADE_LEVEL)) * SKILL1_UPGRADE_CHARGE_REDUCTION,
		0.01
	)


func _try_heal(amount: int) -> bool:
	if is_dead:
		return false
	if amount <= 0:
		return false
	if current_health >= max_health:
		return false

	current_health = mini(current_health + amount, max_health)
	health_bar.set_health(current_health, max_health)
	health_changed.emit(current_health, max_health)
	_refresh_collectible_stats(false)
	return true


func try_consume_authoritative_player_bullet_ammo() -> bool:
	return false


func _try_start_reload() -> bool:
	return false


func _update_skill1_charge(delta: float) -> void:
	if not skill1_unlocked:
		return
	if is_dead:
		return
	_sync_skill1_charge_duration_to_upgrade_level()
	if skill1_charge >= skill1_charge_duration:
		return

	var charge_rate := 1.0 + maxf(collectible_skill_charge_bonus_per_second, 0.0)
	skill1_charge = minf(skill1_charge + delta * charge_rate, skill1_charge_duration)
	_update_skill1_charge_bar()


func _try_use_skill1() -> bool:
	return false


func can_request_multiplayer_projectile(_projectile_type: StringName) -> bool:
	return false


func get_multiplayer_projectile_spawn_distance(_projectile_type: StringName) -> float:
	return 0.0


func _register_multiplayer_projectile(
	projectile: Node,
	projectile_type: StringName,
	spawn_position: Vector2,
	shoot_direction: Vector2,
	projectile_damage: int,
	projectile_speed: float,
	projectile_lifetime: float,
	pierces_enemies: bool = false,
	target_peer_id: int = 0,
	target_enemy_net_id: int = 0
) -> void:
	if projectile == null:
		return
	var current_scene := get_tree().current_scene
	if current_scene == null or not current_scene.has_method("register_local_projectile"):
		return
	current_scene.call(
		"register_local_projectile",
		projectile,
		projectile_type,
		peer_id,
		spawn_position,
		shoot_direction,
		projectile_damage,
		projectile_speed,
		projectile_lifetime,
		pierces_enemies,
		target_peer_id,
		target_enemy_net_id
	)


func _should_fire_piercing_bullet() -> bool:
	var pierce_chance := _get_inventory_bullet_pierce_chance()
	if pierce_chance <= 0.0:
		return false
	return randf() < pierce_chance


func _should_fire_homing_bullet() -> bool:
	var homing_chance := _get_inventory_bullet_homing_chance()
	if homing_chance <= 0.0:
		return false
	return randf() < homing_chance


func _get_inventory_bullet_pierce_chance() -> float:
	if not supports_projectile_attack_patterns():
		return 0.0
	var run_state := get_node_or_null("/root/RunState") as RunStateStore
	if run_state == null:
		return 0.0

	var total_chance := 0.0
	for item in _get_active_collectible_items():
		total_chance += item.bullet_pierce_chance
		if _is_collectible_condition_active(item):
			total_chance += item.conditional_bullet_pierce_chance
	return clampf(total_chance, 0.0, 1.0)


func get_inventory_bullet_pierce_chance() -> float:
	return _get_inventory_bullet_pierce_chance()


func _get_inventory_bullet_homing_chance() -> float:
	if not supports_projectile_attack_patterns():
		return 0.0
	var total_chance := 0.0
	for item in _get_active_collectible_items():
		total_chance += item.bullet_homing_chance
	return clampf(total_chance, 0.0, 1.0)


func _find_homing_bullet_target(shoot_direction: Vector2) -> Enemy:
	if shoot_direction == Vector2.ZERO:
		return null
	var space_state := get_world_2d().direct_space_state
	if space_state == null:
		return null
	var target_shape := CircleShape2D.new()
	target_shape.radius = HOMING_TARGET_RADIUS
	var query := PhysicsShapeQueryParameters2D.new()
	query.shape = target_shape
	query.transform = Transform2D(0.0, global_position)
	query.collision_mask = HOMING_ENEMY_BODY_MASK
	query.collide_with_bodies = true
	query.collide_with_areas = false
	var normalized_direction := shoot_direction.normalized()
	var best_target: Enemy = null
	var best_distance_squared := INF
	for result in space_state.intersect_shape(query, HOMING_QUERY_MAX_RESULTS):
		var enemy := result.get("collider") as Enemy
		if enemy == null or not is_instance_valid(enemy) or enemy.is_dead:
			continue
		var offset := enemy.global_position - global_position
		if offset.length_squared() <= 0.001:
			continue
		if abs(normalized_direction.angle_to(offset.normalized())) > HOMING_TARGET_HALF_ANGLE:
			continue
		var distance_squared := offset.length_squared()
		if distance_squared >= best_distance_squared:
			continue
		best_distance_squared = distance_squared
		best_target = enemy
	return best_target


func _on_collectible_inventory_changed() -> void:
	_refresh_collectible_stats()


func _on_collectible_xirang_changed(_total: int, _added_amount: int) -> void:
	_refresh_collectible_stats()


func _refresh_collectible_stats(emit_changes: bool = true) -> void:
	_initialize_base_stats()

	var attack_bonus := 0
	var max_health_bonus := 0
	var move_speed_bonus := 0.0
	var physical_defense_bonus := 0
	var magic_defense_bonus := 0
	var physical_damage_bonus := 0
	var magic_damage_bonus := 0
	var dash_distance_bonus := 0.0
	var dash_cooldown_reduction := 0.0
	var attack_speed_bonus := 0.0
	var skill_charge_bonus := 0.0
	var skill_charge_preserve_chance := 0.0
	var base_upgrade_free_chance := 0.0
	var damage_against_burning_multiplier := 1.0
	var damage_against_bleeding_multiplier := 1.0
	var ranged_front_damage_multiplier := 1.0
	var ranged_back_damage_multiplier := 1.0
	var ranged_dodge_chance := 0.0
	var active_periodic_keys: Dictionary = {}

	for item in _get_active_collectible_items():
		attack_bonus += item.collectible_attack_bonus
		max_health_bonus += item.collectible_max_health_bonus
		move_speed_bonus += item.collectible_move_speed_bonus
		physical_defense_bonus += item.collectible_physical_defense_bonus
		magic_defense_bonus += item.collectible_magic_defense_bonus
		physical_damage_bonus += item.collectible_physical_damage_bonus
		magic_damage_bonus += item.collectible_magic_damage_bonus
		dash_distance_bonus += item.collectible_dash_distance_bonus
		dash_cooldown_reduction += item.collectible_dash_cooldown_reduction
		skill_charge_bonus += item.collectible_skill_charge_bonus_per_second
		skill_charge_preserve_chance += item.skill_charge_preserve_chance
		base_upgrade_free_chance += item.base_upgrade_free_chance
		damage_against_burning_multiplier *= item.damage_against_burning_multiplier
		damage_against_bleeding_multiplier *= item.damage_against_bleeding_multiplier
		ranged_front_damage_multiplier *= item.incoming_ranged_front_damage_multiplier
		ranged_back_damage_multiplier *= item.incoming_ranged_back_damage_multiplier
		ranged_dodge_chance += item.incoming_ranged_dodge_chance
		if item.attack_speed_xirang_step > 0:
			attack_speed_bonus += (
				floori(float(current_xirang) / float(item.attack_speed_xirang_step))
				* item.attack_speed_bonus_per_xirang_step
			)
		if item.defense_xirang_step > 0:
			var defense_steps := floori(float(current_xirang) / float(item.defense_xirang_step))
			var dynamic_defense := defense_steps * item.defense_bonus_per_xirang_step
			physical_defense_bonus += dynamic_defense
			magic_defense_bonus += dynamic_defense
		if _is_collectible_condition_active(item):
			attack_bonus += item.conditional_attack_bonus
			max_health_bonus += item.conditional_max_health_bonus
			move_speed_bonus += item.conditional_move_speed_bonus
			physical_defense_bonus += item.conditional_physical_defense_bonus
			magic_defense_bonus += item.conditional_magic_defense_bonus
			physical_damage_bonus += item.conditional_physical_damage_bonus
			magic_damage_bonus += item.conditional_magic_damage_bonus
			skill_charge_bonus += item.conditional_skill_charge_bonus_per_second
		if not item.periodic_effect_id.is_empty():
			active_periodic_keys[_get_collectible_runtime_key(item)] = true
		if _has_collectible_trigger(item):
			active_periodic_keys[_get_collectible_runtime_key(item)] = true
		if _has_collectible_bullet_or_kill_effect(item):
			active_periodic_keys[_get_collectible_runtime_key(item)] = true

	var old_max_health := max_health
	attack_damage = maxi(_base_attack_damage + attack_bonus, 1)
	max_health = maxi(_base_max_health + max_health_bonus, 1)
	move_speed = maxf(_base_move_speed + move_speed_bonus, 0.0)
	physical_defense = maxi(_base_physical_defense + physical_defense_bonus, 0)
	magic_defense = clampi(_base_magic_defense + magic_defense_bonus, 0, DEFAULT_MAGIC_DEFENSE_LIMIT)
	fire_interval = maxf(_base_fire_interval, 0.01)
	collectible_physical_damage_bonus = physical_damage_bonus
	collectible_magic_damage_bonus = magic_damage_bonus
	collectible_dash_distance_bonus = dash_distance_bonus
	collectible_dash_cooldown_reduction = dash_cooldown_reduction
	collectible_attack_speed_bonus = attack_speed_bonus
	collectible_skill_charge_bonus_per_second = skill_charge_bonus
	collectible_skill_charge_preserve_chance = clampf(skill_charge_preserve_chance, 0.0, 1.0)
	collectible_base_upgrade_free_chance = clampf(base_upgrade_free_chance, 0.0, 1.0)
	collectible_damage_against_burning_multiplier = maxf(damage_against_burning_multiplier, 0.0)
	collectible_damage_against_bleeding_multiplier = maxf(damage_against_bleeding_multiplier, 0.0)
	collectible_ranged_front_damage_multiplier = maxf(ranged_front_damage_multiplier, 0.0)
	collectible_ranged_back_damage_multiplier = maxf(ranged_back_damage_multiplier, 0.0)
	collectible_ranged_dodge_chance = clampf(ranged_dodge_chance, 0.0, 1.0)

	for cooldown_key in collectible_periodic_cooldowns.keys():
		if not active_periodic_keys.has(cooldown_key):
			collectible_periodic_cooldowns.erase(cooldown_key)
	for counter_key in collectible_shot_counters.keys():
		if not active_periodic_keys.has(counter_key):
			collectible_shot_counters.erase(counter_key)
	for trigger_key in collectible_trigger_cooldowns.keys():
		if not active_periodic_keys.has(_get_collectible_trigger_owner_key(trigger_key)):
			collectible_trigger_cooldowns.erase(trigger_key)

	if old_max_health != max_health:
		current_health = clampi(current_health, 0, max_health)
		if health_bar != null:
			health_bar.set_health(current_health, max_health)
		if emit_changes:
			health_changed.emit(current_health, max_health)
	_refresh_shooting_timer_wait_time()


func _get_active_collectible_items() -> Array[PickupConfig]:
	var result: Array[PickupConfig] = []
	var run_state := get_node_or_null("/root/RunState") as RunStateStore
	if run_state == null:
		return result

	var seen_unique_effects: Dictionary = {}
	for slot_index in range(RunStateStore.INVENTORY_CAPACITY):
		var item := _get_inventory_item(run_state, slot_index)
		if item == null:
			continue
		if item.pickup_type != PickupConfig.PickupType.COLLECTIBLE:
			continue
		if item.collectible_stacks_by_copy:
			result.append(item)
			continue
		var effect_key := _get_collectible_runtime_key(item)
		if seen_unique_effects.has(effect_key):
			continue
		seen_unique_effects[effect_key] = true
		result.append(item)
	return result


func _get_inventory_item(run_state: RunStateStore, slot_index: int) -> PickupConfig:
	if peer_id > 0:
		return run_state.get_item_for_peer(peer_id, slot_index)
	return run_state.get_item(slot_index)


func _get_collectible_runtime_key(item: PickupConfig) -> String:
	if item == null:
		return ""
	if not item.collectible_effect_id.is_empty():
		return item.collectible_effect_id
	return item.resource_path


func _is_collectible_condition_active(item: PickupConfig) -> bool:
	if item == null or item.conditional_effect_id.is_empty():
		return false
	match item.conditional_effect_id:
		PickupConfig.CONDITION_HEALTH_BELOW:
			if max_health <= 0:
				return false
			return float(current_health) / float(max_health) <= item.conditional_health_ratio_threshold
		PickupConfig.CONDITION_HEALTH_ABOVE:
			if max_health <= 0:
				return false
			return float(current_health) / float(max_health) >= item.conditional_health_ratio_threshold
		PickupConfig.CONDITION_XIRANG_AT_LEAST:
			return current_xirang >= item.conditional_xirang_threshold
		PickupConfig.CONDITION_XIRANG_BELOW:
			return current_xirang < item.conditional_xirang_threshold
		PickupConfig.CONDITION_SKILL_UNLOCKED:
			return skill1_unlocked
		PickupConfig.CONDITION_SKILL_LOCKED:
			return not skill1_unlocked
		_:
			return false


func _has_collectible_trigger(item: PickupConfig) -> bool:
	return item != null and not item.trigger_effect_id.is_empty()


func _has_collectible_bullet_or_kill_effect(item: PickupConfig) -> bool:
	return item != null and (not item.on_hit_effect_id.is_empty() or not item.kill_effect_id.is_empty())


func _get_collectible_trigger_key(item: PickupConfig) -> String:
	if item == null:
		return ""
	return "%s::%s" % [_get_collectible_runtime_key(item), item.trigger_effect_id]


func _get_collectible_aux_key(item: PickupConfig, suffix: String) -> String:
	if item == null:
		return ""
	return "%s::%s" % [_get_collectible_runtime_key(item), suffix]


func _get_collectible_trigger_owner_key(trigger_key: Variant) -> String:
	var key_text := str(trigger_key)
	var separator_index := key_text.find("::")
	if separator_index < 0:
		return key_text
	return key_text.substr(0, separator_index)


func _trigger_collectible_primary_attack_effects() -> void:
	for item in _get_active_collectible_items():
		if not _is_collectible_trigger_event(item, &"primary_attack"):
			continue
		var runtime_key := _get_collectible_runtime_key(item)
		var shot_interval := maxi(item.trigger_shot_interval, 1)
		var shot_count := int(collectible_shot_counters.get(runtime_key, 0)) + 1
		if shot_count < shot_interval:
			collectible_shot_counters[runtime_key] = shot_count
			continue
		collectible_shot_counters[runtime_key] = 0
		_apply_collectible_trigger_effect(item)


# 旧测试工具和外部脚本仍可调用原入口；生产战斗链统一走 primary attack。
func _trigger_collectible_shot_effects() -> void:
	_trigger_collectible_primary_attack_effects()


func _trigger_collectible_hurt_effects() -> void:
	for item in _get_active_collectible_items():
		if _is_collectible_trigger_event(item, &"hurt"):
			_apply_collectible_trigger_effect(item)


func _is_collectible_trigger_event(item: PickupConfig, event_id: StringName) -> bool:
	if item == null or item.trigger_effect_id.is_empty():
		return false
	match event_id:
		&"primary_attack", &"shot":
			return item.trigger_effect_id in [
				PickupConfig.TRIGGER_SHOT_HEAL,
				PickupConfig.TRIGGER_SHOT_XIRANG,
				PickupConfig.TRIGGER_SHOT_CHARGE,
				PickupConfig.TRIGGER_SHOT_THUNDER,
				PickupConfig.TRIGGER_SHOT_FROST,
			]
		&"hurt":
			return item.trigger_effect_id in [
				PickupConfig.TRIGGER_HURT_HEAL,
				PickupConfig.TRIGGER_HURT_XIRANG,
				PickupConfig.TRIGGER_HURT_THUNDER,
				PickupConfig.TRIGGER_HURT_FROST,
			]
		&"skill":
			return item.trigger_effect_id in [
				PickupConfig.TRIGGER_SKILL_HEAL,
				PickupConfig.TRIGGER_SKILL_XIRANG,
				PickupConfig.TRIGGER_SKILL_CHARGE,
				PickupConfig.TRIGGER_SKILL_THUNDER,
				PickupConfig.TRIGGER_SKILL_FROST,
			]
	return false


func _apply_collectible_trigger_effect(item: PickupConfig) -> void:
	if not _try_start_collectible_trigger_cooldown(item):
		return
	match item.trigger_effect_id:
		PickupConfig.TRIGGER_SHOT_HEAL, PickupConfig.TRIGGER_HURT_HEAL, PickupConfig.TRIGGER_SKILL_HEAL:
			_try_heal(item.trigger_heal)
		PickupConfig.TRIGGER_SHOT_XIRANG, PickupConfig.TRIGGER_HURT_XIRANG, PickupConfig.TRIGGER_SKILL_XIRANG:
			_grant_xirang_unrestricted(item.trigger_xirang)
		PickupConfig.TRIGGER_SHOT_CHARGE, PickupConfig.TRIGGER_SKILL_CHARGE:
			_add_collectible_skill_charge(item.trigger_skill_charge)
		PickupConfig.TRIGGER_SHOT_THUNDER, PickupConfig.TRIGGER_HURT_THUNDER, PickupConfig.TRIGGER_SKILL_THUNDER:
			_trigger_collectible_custom_thunder(item)
		PickupConfig.TRIGGER_SHOT_FROST, PickupConfig.TRIGGER_HURT_FROST, PickupConfig.TRIGGER_SKILL_FROST:
			_trigger_collectible_custom_frost(item)


func _try_start_collectible_trigger_cooldown(item: PickupConfig) -> bool:
	if item.trigger_cooldown <= 0.0:
		return true
	var trigger_key := _get_collectible_trigger_key(item)
	if float(collectible_trigger_cooldowns.get(trigger_key, 0.0)) > 0.0:
		return false
	collectible_trigger_cooldowns[trigger_key] = item.trigger_cooldown
	return true


func _try_start_collectible_aux_cooldown(item: PickupConfig, suffix: String, cooldown: float) -> bool:
	if cooldown <= 0.0:
		return true
	var trigger_key := _get_collectible_aux_key(item, suffix)
	if float(collectible_trigger_cooldowns.get(trigger_key, 0.0)) > 0.0:
		return false
	collectible_trigger_cooldowns[trigger_key] = cooldown
	return true


func _add_collectible_skill_charge(amount: float) -> bool:
	if amount <= 0.0 or not skill1_unlocked or is_dead:
		return false
	_sync_skill1_charge_duration_to_upgrade_level()
	if skill1_charge >= skill1_charge_duration:
		return false
	skill1_charge = minf(skill1_charge + amount, skill1_charge_duration)
	_update_skill1_charge_bar()
	return true


func apply_collectible_attack_hit_effects(enemy: Enemy, hit_damage: int) -> void:
	if enemy == null or not is_instance_valid(enemy):
		return
	var was_dead_after_hit := enemy.is_dead
	if not was_dead_after_hit:
		for item in _get_active_collectible_items():
			if item.on_hit_effect_id.is_empty():
				continue
			_apply_collectible_on_hit_effect(item, enemy, hit_damage)
			if enemy.is_dead:
				break
	if enemy.is_dead:
		for item in _get_active_collectible_items():
			if item.kill_effect_id.is_empty():
				continue
			_apply_collectible_kill_effect(item, enemy)


func apply_collectible_bullet_hit_effects(enemy: Enemy, hit_damage: int) -> void:
	apply_collectible_attack_hit_effects(enemy, hit_damage)


func _apply_collectible_on_hit_effect(item: PickupConfig, enemy: Enemy, _hit_damage: int) -> void:
	if item == null or enemy == null or not is_instance_valid(enemy) or enemy.is_dead:
		return
	var on_hit_chance := clampf(item.on_hit_chance, 0.0, 1.0)
	if on_hit_chance <= 0.0 or randf() > on_hit_chance:
		return
	if not _try_start_collectible_aux_cooldown(item, "hit:%s" % item.on_hit_effect_id, item.on_hit_cooldown):
		return
	var source_id := _get_collectible_effect_source_id(item, 11000)
	match item.on_hit_effect_id:
		PickupConfig.HIT_EFFECT_BURN:
			enemy.apply_collectible_status(
				&"burn",
				source_id,
				item.on_hit_duration,
				get_collectible_outgoing_damage(
					item.on_hit_damage,
					EnemyConfig.DamageType.MAGIC
				),
				item.on_hit_tick_interval,
				EnemyConfig.DamageType.MAGIC
			)
			_spawn_collectible_area_at(enemy.global_position, 18.0, Color(1.0, 0.46, 0.18, 0.45), 0.28)
		PickupConfig.HIT_EFFECT_BLEED:
			enemy.apply_collectible_status(
				&"bleed",
				source_id,
				item.on_hit_duration,
				get_collectible_outgoing_damage(
					item.on_hit_damage,
					EnemyConfig.DamageType.PHYSICAL
				),
				item.on_hit_tick_interval,
				EnemyConfig.DamageType.PHYSICAL
			)
			_spawn_collectible_area_at(enemy.global_position, 14.0, Color(1.0, 0.08, 0.12, 0.38), 0.22)
		PickupConfig.HIT_EFFECT_CHILL:
			enemy.apply_collectible_status(
				&"chill",
				source_id,
				item.on_hit_duration,
				get_collectible_outgoing_damage(
					item.on_hit_damage,
					EnemyConfig.DamageType.MAGIC
				),
				item.on_hit_tick_interval,
				EnemyConfig.DamageType.MAGIC,
				item.on_hit_slow_multiplier
			)
			_spawn_collectible_area_at(enemy.global_position, maxf(item.on_hit_radius, 18.0), Color(0.52, 0.9, 1.0, 0.38), 0.28)
		PickupConfig.HIT_EFFECT_SHOCK:
			_apply_collectible_area_damage(
				enemy.global_position,
				maxf(item.on_hit_radius, 24.0),
				maxi(item.on_hit_damage, 1),
				EnemyConfig.DamageType.MAGIC
			)
			_spawn_collectible_lightning_effect(enemy.global_position)
		PickupConfig.HIT_EFFECT_MARK:
			enemy.apply_collectible_status(
				&"mark",
				source_id,
				item.on_hit_duration,
				0,
				item.on_hit_tick_interval,
				EnemyConfig.DamageType.MAGIC,
				1.0,
				0,
				maxf(item.on_hit_damage_taken_multiplier, 1.0)
			)
			_spawn_collectible_area_at(enemy.global_position, 16.0, Color(0.84, 0.46, 1.0, 0.36), 0.24)
		PickupConfig.HIT_EFFECT_CRACK:
			enemy.apply_collectible_status(
				&"crack",
				source_id,
				item.on_hit_duration,
				0,
				item.on_hit_tick_interval,
				EnemyConfig.DamageType.PHYSICAL,
				1.0,
				item.on_hit_physical_defense_modifier
			)
			_spawn_collectible_area_at(enemy.global_position, 16.0, Color(1.0, 0.82, 0.28, 0.36), 0.24)
		PickupConfig.HIT_EFFECT_LEECH:
			_try_heal(item.on_hit_heal)
			_spawn_collectible_area_at(global_position, 18.0, Color(0.45, 1.0, 0.58, 0.36), 0.22)
		PickupConfig.HIT_EFFECT_SIPHON:
			_add_collectible_skill_charge(item.on_hit_skill_charge)
			_spawn_collectible_area_at(global_position, 18.0, Color(0.42, 0.88, 1.0, 0.32), 0.22)
		PickupConfig.HIT_EFFECT_EXECUTE:
			var max_enemy_health := enemy.config.max_health if enemy.config != null else enemy.current_health
			var threshold := float(max_enemy_health) * item.on_hit_execute_health_ratio
			if threshold > 0.0 and float(enemy.current_health) <= threshold:
				_apply_authoritative_collectible_enemy_damage(
					enemy,
					enemy.current_health + max_enemy_health,
					enemy.global_position.direction_to(global_position),
					EnemyConfig.DamageType.PHYSICAL
				)
				_spawn_collectible_area_at(enemy.global_position, 20.0, Color(1.0, 0.16, 0.16, 0.42), 0.26)
		PickupConfig.HIT_EFFECT_BLOOM:
			_apply_collectible_area_heal(enemy.global_position, maxf(item.on_hit_radius, 36.0), item.on_hit_heal)
		PickupConfig.HIT_EFFECT_XIRANG:
			_grant_xirang_unrestricted(item.on_hit_xirang)
			_spawn_collectible_area_at(enemy.global_position, 12.0, Color(0.96, 0.76, 0.32, 0.36), 0.2)


func _apply_collectible_kill_effect(item: PickupConfig, enemy: Enemy) -> void:
	if item == null or enemy == null or not is_instance_valid(enemy):
		return
	if not _try_start_collectible_aux_cooldown(item, "kill:%s" % item.kill_effect_id, item.kill_cooldown):
		return
	match item.kill_effect_id:
		PickupConfig.KILL_EFFECT_HEAL:
			_try_heal(item.kill_heal)
			_spawn_collectible_area_at(global_position, 22.0, Color(0.45, 1.0, 0.58, 0.38), 0.26)
		PickupConfig.KILL_EFFECT_XIRANG:
			_grant_xirang_unrestricted(item.kill_xirang)
			_spawn_collectible_area_at(enemy.global_position, 18.0, Color(0.96, 0.76, 0.32, 0.36), 0.24)
		PickupConfig.KILL_EFFECT_CHARGE:
			_add_collectible_skill_charge(item.kill_skill_charge)
			_spawn_collectible_area_at(global_position, 22.0, Color(0.42, 0.88, 1.0, 0.32), 0.26)
		PickupConfig.KILL_EFFECT_THUNDER:
			_apply_collectible_area_damage(
				enemy.global_position,
				maxf(item.kill_radius, 28.0),
				maxi(item.kill_damage, 1),
				EnemyConfig.DamageType.MAGIC
			)
			_spawn_collectible_lightning_effect(enemy.global_position)
		PickupConfig.KILL_EFFECT_FROST:
			_apply_collectible_area_frost(
				enemy.global_position,
				maxf(item.kill_radius, 28.0),
				maxi(item.kill_damage, 1),
				item.kill_slow_multiplier,
				item.kill_duration
			)
		PickupConfig.KILL_EFFECT_HASTE:
			collectible_swift_time_left = maxf(item.kill_duration, 0.0)
			collectible_swift_move_speed_multiplier = maxf(item.kill_move_speed_multiplier, 1.0)
			_spawn_collectible_area_at(global_position, 22.0, Color(0.5, 1.0, 0.86, 0.34), 0.26)
		PickupConfig.KILL_EFFECT_BLOOM:
			_apply_collectible_area_heal(enemy.global_position, maxf(item.kill_radius, 36.0), item.kill_heal)
		PickupConfig.KILL_EFFECT_BURST:
			_apply_collectible_area_damage(
				enemy.global_position,
				maxf(item.kill_radius, 32.0),
				maxi(item.kill_damage, 1),
				EnemyConfig.DamageType.PHYSICAL
			)
			_spawn_collectible_area_at(enemy.global_position, maxf(item.kill_radius, 32.0), Color(1.0, 0.5, 0.28, 0.38), 0.28)


func _update_collectible_runtime_effects(delta: float) -> void:
	if collectible_swift_time_left > 0.0:
		collectible_swift_time_left = maxf(collectible_swift_time_left - delta, 0.0)
		if collectible_swift_time_left <= 0.0:
			collectible_swift_move_speed_multiplier = 1.0

	for trigger_key in collectible_trigger_cooldowns.keys():
		var cooldown := float(collectible_trigger_cooldowns.get(trigger_key, 0.0))
		cooldown = maxf(cooldown - delta, 0.0)
		if cooldown <= 0.0:
			collectible_trigger_cooldowns.erase(trigger_key)
		else:
			collectible_trigger_cooldowns[trigger_key] = cooldown

	if not _should_run_authoritative_collectible_effects():
		return

	for item in _get_active_collectible_items():
		if item.periodic_effect_id.is_empty() or item.periodic_interval <= 0.0:
			continue
		var cooldown_key := _get_collectible_runtime_key(item)
		var cooldown := float(
			collectible_periodic_cooldowns.get(cooldown_key, item.periodic_interval)
		)
		cooldown -= delta
		if cooldown > 0.0:
			collectible_periodic_cooldowns[cooldown_key] = cooldown
			continue
		_trigger_collectible_periodic_effect(item)
		collectible_periodic_cooldowns[cooldown_key] = maxf(item.periodic_interval, 0.1)


func _trigger_collectible_periodic_effect(item: PickupConfig) -> void:
	match item.periodic_effect_id:
		PickupConfig.PERIODIC_EFFECT_THUNDER:
			_trigger_thunder_crystal(item)
		PickupConfig.PERIODIC_EFFECT_FROST:
			_trigger_frost_crystal(item)
		PickupConfig.PERIODIC_EFFECT_HEAL:
			_trigger_life_crystal(item)
		PickupConfig.PERIODIC_EFFECT_ARCHER:
			_trigger_archer(item)
		PickupConfig.PERIODIC_EFFECT_SAKURA_ROCKET:
			_trigger_sakura_rocket(item)


func _trigger_thunder_crystal(item: PickupConfig) -> void:
	var enemies := _collect_alive_enemies()
	if enemies.is_empty():
		return
	var enemy := enemies[randi() % enemies.size()]
	if enemy == null or not is_instance_valid(enemy):
		return
	var impact_position := enemy.global_position
	var radius := maxf(item.periodic_radius, 1.0)
	var damage := get_collectible_outgoing_damage(
		item.periodic_damage,
		EnemyConfig.DamageType.MAGIC
	)
	for target_enemy in enemies:
		if target_enemy == null or not is_instance_valid(target_enemy):
			continue
		if target_enemy.global_position.distance_to(impact_position) > radius:
			continue
		var impact_direction := impact_position.direction_to(target_enemy.global_position)
		if impact_direction == Vector2.ZERO:
			impact_direction = Vector2.DOWN
		_apply_authoritative_collectible_enemy_damage(
			target_enemy,
			damage,
			impact_direction,
			EnemyConfig.DamageType.MAGIC
		)
	_spawn_collectible_lightning_effect(impact_position)


func _trigger_frost_crystal(item: PickupConfig) -> void:
	var radius := maxf(item.periodic_radius, 1.0)
	var damage := get_collectible_outgoing_damage(
		item.periodic_damage,
		EnemyConfig.DamageType.MAGIC
	)
	var slow_source_id := int(Time.get_ticks_msec() + get_instance_id())
	for enemy in _collect_alive_enemies():
		if enemy == null or not is_instance_valid(enemy):
			continue
		if global_position.distance_to(enemy.global_position) > radius:
			continue
		_apply_authoritative_collectible_enemy_damage(
			enemy,
			damage,
			enemy.global_position.direction_to(global_position),
			EnemyConfig.DamageType.MAGIC
		)
		enemy.add_move_speed_modifier(slow_source_id, item.periodic_slow_multiplier)
		if item.periodic_slow_duration > 0.0:
			get_tree().create_timer(item.periodic_slow_duration).timeout.connect(
				_remove_collectible_enemy_slow.bind(weakref(enemy), slow_source_id)
		)
	_spawn_collectible_frost_effect(radius, 0.4)


func _trigger_collectible_custom_thunder(item: PickupConfig) -> void:
	var enemies := _collect_alive_enemies()
	if enemies.is_empty():
		return
	var enemy := enemies[randi() % enemies.size()]
	if enemy == null or not is_instance_valid(enemy):
		return
	var impact_position := enemy.global_position
	var radius := maxf(item.trigger_radius, 1.0)
	var damage := get_collectible_outgoing_damage(
		item.trigger_damage,
		EnemyConfig.DamageType.MAGIC
	)
	for target_enemy in enemies:
		if target_enemy == null or not is_instance_valid(target_enemy):
			continue
		if target_enemy.global_position.distance_to(impact_position) > radius:
			continue
		var impact_direction := impact_position.direction_to(target_enemy.global_position)
		if impact_direction == Vector2.ZERO:
			impact_direction = Vector2.DOWN
		_apply_authoritative_collectible_enemy_damage(
			target_enemy,
			damage,
			impact_direction,
			EnemyConfig.DamageType.MAGIC
		)
	_spawn_collectible_lightning_effect(impact_position)


func _trigger_collectible_custom_frost(item: PickupConfig) -> void:
	var radius := maxf(item.trigger_radius, 1.0)
	var damage := get_collectible_outgoing_damage(
		item.trigger_damage,
		EnemyConfig.DamageType.MAGIC
	)
	var slow_source_id := int(Time.get_ticks_msec() + get_instance_id())
	for enemy in _collect_alive_enemies():
		if enemy == null or not is_instance_valid(enemy):
			continue
		if global_position.distance_to(enemy.global_position) > radius:
			continue
		_apply_authoritative_collectible_enemy_damage(
			enemy,
			damage,
			enemy.global_position.direction_to(global_position),
			EnemyConfig.DamageType.MAGIC
		)
		if item.trigger_slow_multiplier < 1.0:
			enemy.add_move_speed_modifier(slow_source_id, item.trigger_slow_multiplier)
			if item.trigger_slow_duration > 0.0:
				get_tree().create_timer(item.trigger_slow_duration).timeout.connect(
					_remove_collectible_enemy_slow.bind(weakref(enemy), slow_source_id)
				)
	_spawn_collectible_frost_effect(radius, 0.4)


func _trigger_life_crystal(item: PickupConfig) -> void:
	var radius := maxf(item.periodic_radius, 1.0)
	for target_player in _collect_alive_players():
		if target_player == null or not is_instance_valid(target_player):
			continue
		if global_position.distance_to(target_player.global_position) > radius:
			continue
		_apply_authoritative_collectible_player_heal(target_player, item.periodic_heal)
	_spawn_collectible_area_effect(radius, Color(0.45, 1.0, 0.58, 0.42), 0.52)


func _trigger_archer(item: PickupConfig) -> void:
	var targets := _collect_nearest_alive_enemies(
		maxi(item.periodic_target_count, 1),
		maxf(item.periodic_radius, 0.0)
	)
	if targets.is_empty():
		return
	var damage_multiplier := maxf(item.periodic_attack_damage_multiplier, 0.0)
	if damage_multiplier <= 0.0:
		damage_multiplier = 1.0
	var arrow_damage := get_collectible_outgoing_damage(
		maxi(roundi(float(attack_damage) * damage_multiplier), 1),
		EnemyConfig.DamageType.PHYSICAL
	)
	for enemy in targets:
		_spawn_collectible_arrow(enemy, arrow_damage)


func _trigger_sakura_rocket(item: PickupConfig) -> void:
	var targets := _collect_nearest_alive_enemies(
		maxi(item.periodic_target_count, 1),
		maxf(item.periodic_radius, 0.0)
	)
	if targets.is_empty():
		return
	var rocket_damage := get_collectible_outgoing_damage(
		maxi(item.periodic_damage, 1),
		EnemyConfig.DamageType.MAGIC
	)
	_spawn_collectible_sakura_rocket(targets[0], rocket_damage)


func _collect_nearest_alive_enemies(max_count: int, radius: float) -> Array[Enemy]:
	var enemies := _collect_alive_enemies()
	if enemies.is_empty():
		return []
	var max_distance_squared := radius * radius
	var filtered: Array[Enemy] = []
	for enemy in enemies:
		if enemy == null or not is_instance_valid(enemy):
			continue
		if radius > 0.0 and global_position.distance_squared_to(enemy.global_position) > max_distance_squared:
			continue
		filtered.append(enemy)
	filtered.sort_custom(_sort_enemies_by_distance_to_self)
	if filtered.size() > max_count:
		filtered.resize(max_count)
	return filtered


func _sort_enemies_by_distance_to_self(a: Enemy, b: Enemy) -> bool:
	if a == null:
		return false
	if b == null:
		return true
	return (
		global_position.distance_squared_to(a.global_position)
		< global_position.distance_squared_to(b.global_position)
	)


func _spawn_collectible_arrow(target_enemy: Enemy, arrow_damage: int) -> bool:
	if target_enemy == null or not is_instance_valid(target_enemy) or target_enemy.is_dead:
		return false
	var spawn_parent := get_tree().current_scene
	if spawn_parent == null:
		return false
	var shoot_direction := global_position.direction_to(target_enemy.global_position)
	if shoot_direction == Vector2.ZERO:
		shoot_direction = _facing_suffix_to_vector(facing_suffix)
	var arrow := COLLECTIBLE_ARROW_PROJECTILE_SCENE.instantiate()
	if arrow == null:
		return false
	arrow.top_level = true
	arrow.call("setup", shoot_direction, arrow_damage)
	spawn_parent.add_child(arrow)
	arrow.global_position = global_position + shoot_direction * auxiliary_projectile_spawn_distance
	_register_multiplayer_projectile(
		arrow,
		&"collectible_arrow",
		arrow.global_position,
		shoot_direction,
		arrow_damage,
		float(arrow.get("speed")),
		float(arrow.get("max_lifetime"))
	)
	return true


func _get_linglan_skill2_config() -> LinglanSkill2Config:
	if linglan_skill2_config_cache != null:
		return linglan_skill2_config_cache
	linglan_skill2_config_cache = load(LINGLAN_SKILL2_CONFIG_PATH) as LinglanSkill2Config
	return linglan_skill2_config_cache


func _spawn_collectible_sakura_rocket(target_enemy: Enemy, rocket_damage: int) -> bool:
	if target_enemy == null or not is_instance_valid(target_enemy) or target_enemy.is_dead:
		return false
	var spawn_parent := get_tree().current_scene
	if spawn_parent == null:
		return false
	var skill2_config := _get_linglan_skill2_config()
	if skill2_config == null:
		return false
	var shoot_direction := global_position.direction_to(target_enemy.global_position)
	if shoot_direction == Vector2.ZERO:
		shoot_direction = _facing_suffix_to_vector(facing_suffix)
	var rocket := LINGLAN_SKILL2_ROCKET_SCENE.instantiate() as LinglanSkill2SakuraRocket
	if rocket == null:
		return false
	rocket.top_level = true
	rocket.setup(
		shoot_direction,
		rocket_damage,
		skill2_config.rocket_speed,
		skill2_config.rocket_lifetime,
		LinglanSkill2SakuraRocket.COLLECTIBLE_SAKURA_EXPLOSION_RADIUS,
		null,
		skill2_config.rocket_homing_turn_rate,
		target_enemy,
		true,
		EnemyConfig.DamageType.MAGIC
	)
	spawn_parent.add_child(rocket)
	rocket.global_position = global_position + shoot_direction * auxiliary_projectile_spawn_distance
	var target_enemy_net_id := int(target_enemy.get_meta("net_id", 0))
	_register_multiplayer_projectile(
		rocket,
		&"collectible_sakura_rocket",
		rocket.global_position,
		shoot_direction,
		rocket_damage,
		rocket.speed,
		rocket.max_lifetime,
		false,
		0,
		target_enemy_net_id
	)
	return true


func _remove_collectible_enemy_slow(enemy_ref: WeakRef, source_id: int) -> void:
	var enemy: Enemy = null
	if enemy_ref != null:
		enemy = enemy_ref.get_ref() as Enemy
	if enemy == null or not is_instance_valid(enemy):
		return
	enemy.remove_move_speed_modifier(source_id)


func _apply_authoritative_collectible_enemy_damage(
	enemy: Enemy,
	damage: int,
	impact_direction: Vector2,
	damage_type: EnemyConfig.DamageType,
	show_hit_particles: bool = true
) -> bool:
	if enemy == null or not is_instance_valid(enemy):
		return false
	var current_scene := get_tree().current_scene
	if (
		current_scene != null
		and current_scene.has_method("apply_multiplayer_collectible_enemy_damage")
	):
		return bool(current_scene.call(
			"apply_multiplayer_collectible_enemy_damage",
			enemy,
			damage,
			impact_direction,
			int(damage_type),
			show_hit_particles
		))
	return enemy.apply_damage(damage, impact_direction, damage_type, show_hit_particles)


func _apply_authoritative_player_heal(target_player: Player, heal_amount: int) -> bool:
	if target_player == null or not is_instance_valid(target_player):
		return false
	var current_scene := get_tree().current_scene
	if (
		current_scene != null
		and current_scene.has_method("apply_multiplayer_player_heal")
	):
		return bool(current_scene.call(
			"apply_multiplayer_player_heal",
			target_player,
			heal_amount
		))
	return target_player._try_heal(heal_amount)


func _apply_authoritative_collectible_player_heal(target_player: Player, heal_amount: int) -> bool:
	return _apply_authoritative_player_heal(target_player, heal_amount)


func _get_collectible_effect_source_id(item: PickupConfig, salt: int) -> int:
	var key_text := _get_collectible_runtime_key(item)
	return absi(key_text.hash()) + salt + get_instance_id()


func _apply_collectible_area_damage(
	center_position: Vector2,
	radius: float,
	damage: int,
	damage_type: EnemyConfig.DamageType
) -> void:
	var effective_radius := maxf(radius, 1.0)
	var effective_damage := get_collectible_outgoing_damage(maxi(damage, 1), damage_type)
	for enemy in _collect_alive_enemies():
		if enemy == null or not is_instance_valid(enemy):
			continue
		if enemy.global_position.distance_to(center_position) > effective_radius:
			continue
		var impact_direction := center_position.direction_to(enemy.global_position)
		if impact_direction == Vector2.ZERO:
			impact_direction = Vector2.DOWN
		_apply_authoritative_collectible_enemy_damage(
			enemy,
			effective_damage,
			impact_direction,
			damage_type
		)


func _apply_collectible_area_heal(center_position: Vector2, radius: float, heal_amount: int) -> void:
	if heal_amount <= 0:
		return
	var effective_radius := maxf(radius, 1.0)
	for target_player in _collect_alive_players():
		if target_player == null or not is_instance_valid(target_player):
			continue
		if target_player.global_position.distance_to(center_position) > effective_radius:
			continue
		_apply_authoritative_collectible_player_heal(target_player, heal_amount)
	_spawn_collectible_area_at(center_position, effective_radius, Color(0.45, 1.0, 0.58, 0.36), 0.32)


func _apply_collectible_area_frost(
	center_position: Vector2,
	radius: float,
	damage: int,
	slow_multiplier: float,
	slow_duration: float
) -> void:
	var effective_radius := maxf(radius, 1.0)
	var effective_damage := get_collectible_outgoing_damage(
		maxi(damage, 1),
		EnemyConfig.DamageType.MAGIC
	)
	var slow_source_id := int(Time.get_ticks_msec() + get_instance_id())
	for enemy in _collect_alive_enemies():
		if enemy == null or not is_instance_valid(enemy):
			continue
		if enemy.global_position.distance_to(center_position) > effective_radius:
			continue
		_apply_authoritative_collectible_enemy_damage(
			enemy,
			effective_damage,
			center_position.direction_to(enemy.global_position),
			EnemyConfig.DamageType.MAGIC
		)
		if slow_multiplier < 1.0:
			enemy.add_move_speed_modifier(slow_source_id, slow_multiplier)
			if slow_duration > 0.0:
				get_tree().create_timer(slow_duration).timeout.connect(
					_remove_collectible_enemy_slow.bind(weakref(enemy), slow_source_id)
				)
	_spawn_collectible_frost_effect_at(center_position, effective_radius, 0.4)


func _collect_alive_enemies() -> Array[Enemy]:
	var result: Array[Enemy] = []
	var root := get_tree().current_scene
	if root == null:
		return result
	_collect_alive_enemies_recursive(root, result)
	return result


func _collect_alive_enemies_recursive(node: Node, result: Array[Enemy]) -> void:
	var enemy := node as Enemy
	if enemy != null and not enemy.is_dead:
		result.append(enemy)
	for child in node.get_children():
		_collect_alive_enemies_recursive(child, result)


func _collect_alive_players() -> Array[Player]:
	var result: Array[Player] = []
	var root := get_tree().current_scene
	if root == null:
		return result
	_collect_alive_players_recursive(root, result)
	return result


func _collect_alive_players_recursive(node: Node, result: Array[Player]) -> void:
	var player_node := node as Player
	if player_node != null and not player_node.is_dead:
		result.append(player_node)
	for child in node.get_children():
		_collect_alive_players_recursive(child, result)


func _should_run_authoritative_collectible_effects() -> bool:
	var net_manager := get_node_or_null("/root/NetManager")
	if net_manager == null or not net_manager.has_method("is_multiplayer_active"):
		return true
	if not bool(net_manager.call("is_multiplayer_active")):
		return true
	return bool(net_manager.call("is_host"))


func _spawn_collectible_area_effect(radius: float, color: Color, duration: float) -> void:
	_spawn_collectible_area_at(global_position, radius, color, duration)


func _spawn_collectible_area_at(
	spawn_position: Vector2,
	radius: float,
	color: Color,
	duration: float
) -> void:
	var effect := COLLECTIBLE_AREA_EFFECT_SCENE.instantiate() as CollectibleAreaEffect
	if effect == null:
		return
	var spawn_parent := get_tree().current_scene
	if spawn_parent == null:
		return
	effect.top_level = true
	effect.setup(radius, color, duration)
	spawn_parent.add_child(effect)
	effect.global_position = spawn_position
	_broadcast_collectible_visual(&"area", effect.global_position, radius, color, duration)


func _spawn_collectible_frost_effect(radius: float, duration: float) -> void:
	_spawn_collectible_frost_effect_at(global_position, radius, duration)


func _spawn_collectible_frost_effect_at(spawn_position: Vector2, radius: float, duration: float) -> void:
	var effect := COLLECTIBLE_FROST_AREA_EFFECT_SCENE.instantiate()
	if effect == null:
		return
	var spawn_parent := get_tree().current_scene
	if spawn_parent == null:
		return
	effect.top_level = true
	effect.call("setup", radius, duration)
	spawn_parent.add_child(effect)
	effect.global_position = spawn_position
	_broadcast_collectible_visual(&"frost_area", effect.global_position, radius, Color(0.66, 0.94, 1.0, 1.0), duration)


func _spawn_collectible_lightning_effect(spawn_position: Vector2) -> void:
	var effect := COLLECTIBLE_LIGHTNING_EFFECT_SCENE.instantiate() as CollectibleLightningEffect
	if effect == null:
		return
	var spawn_parent := get_tree().current_scene
	if spawn_parent == null:
		return
	effect.top_level = true
	effect.setup()
	spawn_parent.add_child(effect)
	effect.global_position = spawn_position
	_broadcast_collectible_visual(&"lightning", spawn_position, 0.0, Color(1.0, 0.88, 0.28, 1.0), 0.24)


func _broadcast_collectible_visual(
	effect_type: StringName,
	spawn_position: Vector2,
	radius: float,
	color: Color,
	duration: float
) -> void:
	var current_scene := get_tree().current_scene
	if current_scene == null or not current_scene.has_method("broadcast_collectible_visual_effect"):
		return
	current_scene.call(
		"broadcast_collectible_visual_effect",
		effect_type,
		spawn_position,
		radius,
		color,
		duration
	)


func _broadcast_collectible_follow_visual(
	effect_type: StringName,
	owner_peer_id: int,
	radius: float,
	duration: float
) -> void:
	var current_scene := get_tree().current_scene
	if current_scene == null or not current_scene.has_method("broadcast_collectible_follow_visual_effect"):
		return
	current_scene.call(
		"broadcast_collectible_follow_visual_effect",
		effect_type,
		owner_peer_id,
		radius,
		duration
	)


func _activate_collectible_skill_effects() -> void:
	for item in _get_active_collectible_items():
		match item.skill_effect_id:
			PickupConfig.SKILL_EFFECT_MOON_SHIELD:
				_spawn_moon_shield(item.skill_effect_radius, item.skill_effect_duration)
			PickupConfig.SKILL_EFFECT_SWIFT:
				collectible_swift_time_left = maxf(item.skill_effect_duration, 0.0)
				collectible_swift_move_speed_multiplier = maxf(item.skill_move_speed_multiplier, 1.0)
		if _is_collectible_trigger_event(item, &"skill"):
			_apply_collectible_trigger_effect(item)


func activate_collectible_skill_effects_from_multiplayer() -> void:
	_activate_collectible_skill_effects()


func _spawn_moon_shield(radius: float, duration: float) -> void:
	var shield := COLLECTIBLE_MOON_SHIELD_SCENE.instantiate() as CollectibleMoonShield
	if shield == null:
		return
	shield.setup(self, radius, duration)
	add_child(shield)
	shield.position = Vector2.ZERO
	_broadcast_collectible_follow_visual(
		&"moon_shield",
		peer_id,
		radius,
		duration
	)


func _update_skill1_charge_bar() -> void:
	if skill1_charge_bar == null:
		return
	skill1_charge_bar.set_unlocked(skill1_unlocked and not is_dead)
	skill1_charge_bar.set_charge(
		skill1_charge,
		skill1_charge_duration,
		skill1_unlocked and skill1_charge >= skill1_charge_duration
	)


# 具体角色可覆写对应的 _get_character_* 钩子，自定义自身冲刺参数。
func get_dash_distance() -> float:
	return maxf(_get_character_dash_distance() + collectible_dash_distance_bonus, 0.0)


func get_dash_cooldown() -> float:
	return maxf(_get_character_dash_cooldown() - collectible_dash_cooldown_reduction, 0.0)


func _get_character_dash_distance() -> float:
	return dash_distance


func _get_character_dash_cooldown() -> float:
	return dash_cooldown


func is_dashing() -> bool:
	return dash_time_left > 0.0 and dash_distance_left > 0.0


func is_dash_invulnerable() -> bool:
	return is_dashing() or multiplayer_dash_protection_time_left > 0.0


func is_dash_ready() -> bool:
	return (
		dash_cooldown_timer != null
		and dash_cooldown_timer.is_stopped()
		and not is_dashing()
		and not is_dead
		and not controls_locked
	)


func get_dash_cooldown_ratio() -> float:
	if dash_cooldown_timer == null or dash_cooldown_timer.is_stopped():
		return 1.0
	var cooldown_duration := maxf(dash_cooldown_timer.wait_time, 0.001)
	return clampf(1.0 - dash_cooldown_timer.time_left / cooldown_duration, 0.0, 1.0)


func _try_start_dash(move_direction: Vector2) -> bool:
	if move_direction.length_squared() < DASH_INPUT_MIN_LENGTH_SQUARED:
		return false
	if get_dash_distance() <= 0.0:
		return false
	if not is_dash_ready():
		return false

	_begin_dash(move_direction.normalized())
	_notify_multiplayer_dash_started(dash_direction, move_direction.limit_length(1.0))
	return true


func _begin_dash(direction: Vector2) -> void:
	dash_direction = direction.normalized()
	dash_time_left = maxf(dash_duration, 0.001)
	_active_dash_distance = get_dash_distance()
	dash_distance_left = _active_dash_distance
	var effective_dash_cooldown := get_dash_cooldown()
	if effective_dash_cooldown > 0.0:
		dash_cooldown_timer.start(effective_dash_cooldown)
	_set_dash_effect_direction(dash_direction)
	_set_dash_effect_strength(1.0)
	speed_trail_effect.call("set_motion_direction", dash_direction)
	speed_trail_effect.call("set_effect_active", true)
	_refresh_dash_ready_visual()


func _perform_dash_movement(delta: float) -> void:
	if not is_dashing():
		return
	var physics_delta := maxf(delta, 0.000001)
	var dash_speed := _active_dash_distance / maxf(dash_duration, 0.001)
	var step_distance := minf(dash_distance_left, dash_speed * physics_delta)
	var position_before_dash_step := global_position
	velocity = dash_direction * (step_distance / physics_delta)
	move_and_slide()
	var traveled_distance := minf(position_before_dash_step.distance_to(global_position), step_distance)
	dash_distance_left = maxf(dash_distance_left - traveled_distance, 0.0)
	dash_time_left = maxf(dash_time_left - physics_delta, 0.0)
	var fade_duration := minf(DASH_VISUAL_FADE_DURATION, maxf(dash_duration, 0.001))
	_set_dash_effect_strength(clampf(dash_time_left / fade_duration, 0.0, 1.0))
	if dash_time_left <= 0.0 or dash_distance_left <= 0.0:
		_finish_dash()


func _finish_dash() -> void:
	dash_time_left = 0.0
	dash_distance_left = 0.0
	dash_direction = Vector2.ZERO
	_active_dash_distance = 0.0
	_set_dash_effect_strength(0.0)
	_refresh_dash_ready_visual()


func _notify_multiplayer_dash_started(direction: Vector2, start_move_input: Vector2) -> void:
	var current_scene := get_tree().current_scene
	if current_scene == null or not current_scene.has_method("notify_local_player_dash_started"):
		return
	current_scene.call("notify_local_player_dash_started", direction, start_move_input)


func start_multiplayer_dash_protection(direction: Vector2) -> bool:
	if is_dead or controls_locked:
		return false
	if direction.length_squared() < DASH_INPUT_MIN_LENGTH_SQUARED:
		return false
	if get_dash_distance() <= 0.0:
		return false
	if dash_cooldown_timer == null:
		return false
	if not dash_cooldown_timer.is_stopped():
		if dash_cooldown_timer.time_left > MULTIPLAYER_DASH_COOLDOWN_GRACE:
			return false
		dash_cooldown_timer.stop()
	var effective_dash_cooldown := get_dash_cooldown()
	if effective_dash_cooldown > 0.0:
		dash_cooldown_timer.start(effective_dash_cooldown)
	multiplayer_dash_protection_time_left = maxf(dash_duration, 0.001)
	play_remote_dash_visual(direction)
	return true


func _update_multiplayer_dash_protection(delta: float) -> void:
	if multiplayer_dash_protection_time_left <= 0.0:
		return
	multiplayer_dash_protection_time_left = maxf(
		multiplayer_dash_protection_time_left - maxf(delta, 0.0),
		0.0
	)


func play_remote_dash_visual(direction: Vector2) -> void:
	if direction.length_squared() < DASH_INPUT_MIN_LENGTH_SQUARED:
		return
	remote_dash_visual_time_left = maxf(dash_duration, 0.001)
	_set_dash_effect_direction(direction.normalized())
	_set_dash_effect_strength(1.0)
	speed_trail_effect.call("set_motion_direction", direction)
	speed_trail_effect.call("set_effect_active", true)


func _update_remote_dash_visual(delta: float) -> void:
	if uses_local_input or remote_dash_visual_time_left <= 0.0:
		return
	remote_dash_visual_time_left = maxf(remote_dash_visual_time_left - maxf(delta, 0.0), 0.0)
	var fade_duration := minf(DASH_VISUAL_FADE_DURATION, maxf(dash_duration, 0.001))
	_set_dash_effect_strength(clampf(remote_dash_visual_time_left / fade_duration, 0.0, 1.0))
	if remote_dash_visual_time_left <= 0.0:
		_stop_remote_dash_visual()


func _stop_remote_dash_visual() -> void:
	remote_dash_visual_time_left = 0.0
	_set_dash_effect_strength(0.0)
	if speed_trail_effect != null:
		speed_trail_effect.call("set_effect_active", false)


func _set_dash_effect_direction(direction: Vector2) -> void:
	var sprite_material := body_sprite.material as ShaderMaterial
	if sprite_material != null:
		sprite_material.set_shader_parameter(DASH_DIRECTION_SHADER_PARAMETER, direction.normalized())


func _set_dash_effect_strength(strength: float) -> void:
	var sprite_material := body_sprite.material as ShaderMaterial
	if sprite_material != null:
		sprite_material.set_shader_parameter(
			DASH_EFFECT_STRENGTH_SHADER_PARAMETER,
			clampf(strength, 0.0, 1.0)
		)


func _refresh_dash_ready_visual() -> void:
	if dash_ready_indicator == null:
		return
	var can_show_indicator := uses_local_input and not is_dead and not controls_locked
	dash_ready_indicator.visible = can_show_indicator
	var should_show_ready := can_show_indicator and is_dash_ready()
	if should_show_ready == _dash_ready_visual_is_ready:
		if not should_show_ready:
			_set_dash_ready_strength(0.0)
		return
	_dash_ready_visual_is_ready = should_show_ready
	if not should_show_ready:
		_stop_dash_ready_reveal()
		_set_dash_ready_strength(0.0)
		return
	_start_dash_ready_reveal()


func _start_dash_ready_reveal() -> void:
	_stop_dash_ready_reveal()
	_set_dash_ready_strength(0.0)
	dash_ready_reveal_tween = create_tween()
	dash_ready_reveal_tween.set_process_mode(Tween.TWEEN_PROCESS_PHYSICS)
	dash_ready_reveal_tween.tween_method(
		_set_dash_ready_strength,
		0.0,
		1.0,
		DASH_READY_REVEAL_DURATION
	).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	dash_ready_reveal_tween.finished.connect(_on_dash_ready_reveal_finished)


func _stop_dash_ready_reveal() -> void:
	if dash_ready_reveal_tween == null:
		return
	dash_ready_reveal_tween.kill()
	dash_ready_reveal_tween = null


func _on_dash_ready_reveal_finished() -> void:
	dash_ready_reveal_tween = null
	if _dash_ready_visual_is_ready:
		_set_dash_ready_strength(1.0)


func _set_dash_ready_strength(strength: float) -> void:
	var indicator_material := dash_ready_indicator.material as ShaderMaterial
	if indicator_material == null:
		return
	indicator_material.set_shader_parameter(
		DASH_READY_STRENGTH_SHADER_PARAMETER,
		clampf(strength, 0.0, 1.0)
	)


func _on_dash_cooldown_timer_timeout() -> void:
	_refresh_dash_ready_visual()

# 获取当前实际移动速度（受移速加成影响）
func _get_effective_move_speed() -> float:
	return move_speed * current_move_speed_multiplier * collectible_swift_move_speed_multiplier


func _get_mouse_shoot_direction() -> Vector2:
	var mouse_world_position := get_canvas_transform().affine_inverse() * mouse_viewport_position
	return global_position.direction_to(mouse_world_position)


func _get_current_move_input() -> Vector2:
	if uses_local_input:
		return Input.get_vector("move_left", "move_right", "move_up", "move_down")
	return network_move_input


func _get_current_shoot_input() -> Vector2:
	if uses_local_input:
		return Input.get_vector("shoot_left", "shoot_right", "shoot_up", "shoot_down")
	return network_shoot_input


func _on_window_focus_exited() -> void:
	mouse_fire_held = false


# 获取当前实际射击间隔（受射速加成影响）
func _get_effective_fire_interval() -> float:
	var speed_units := maxf(attack_speed_units_per_attack, 1.0)
	var base_attack_speed := (speed_units / maxf(fire_interval, 0.01)) + collectible_attack_speed_bonus
	var base_attacks_per_second := maxf(base_attack_speed, 1.0) / speed_units
	var effective_attacks_per_second := base_attacks_per_second * _get_effective_fire_rate_multiplier()
	return maxf(1.0 / maxf(effective_attacks_per_second, 0.01), 0.01)


# 获取当前实际射速倍率
func _get_effective_fire_rate_multiplier() -> float:
	return maxf(_get_character_fire_rate_multiplier(), 0.01)


func _get_character_fire_rate_multiplier() -> float:
	return maxf(rapid_fire_rate_multiplier, 0.01)

# 刷新射击定时器的等待时间，响应射速 buff 变化
func _refresh_shooting_timer_wait_time() -> void:
	var new_interval := _get_effective_fire_interval()
	if shooting_timer == null:
		return
	shooting_timer.wait_time = new_interval
	attack_speed_changed.emit(get_attack_speed())
	
	if shooting_timer.is_stopped():
		return
	if shooting_timer.time_left <= new_interval:
		return
		
	shooting_timer.start(new_interval)


func get_primary_attack_cooldown_ratio() -> float:
	if shooting_timer == null or shooting_timer.is_stopped():
		return 1.0
	var active_interval := maxf(shooting_timer.wait_time, 0.01)
	return clampf(1.0 - shooting_timer.time_left / active_interval, 0.0, 1.0)


func get_primary_cooldown_ratio() -> float:
	return get_primary_attack_cooldown_ratio()


func apply_multiplayer_primary_cooldown_ratio(ratio: float) -> void:
	if not uses_attack_interval_bar():
		return
	_set_attack_interval_bar_progress(clampf(ratio, 0.0, 1.0))


func _update_attack_interval_bar() -> void:
	if not uses_attack_interval_bar():
		if attack_interval_bar != null:
			attack_interval_bar.visible = false
		return
	_set_attack_interval_bar_progress(get_primary_attack_cooldown_ratio())


func _set_attack_interval_bar_progress(ratio: float) -> void:
	if attack_interval_bar == null:
		return
	var clamped_ratio := clampf(ratio, 0.0, 1.0)
	var is_ready := clamped_ratio >= 0.999
	attack_interval_bar.visible = not is_dead
	if attack_interval_bar.has_method("set_cooldown_progress"):
		attack_interval_bar.call("set_cooldown_progress", clamped_ratio, is_ready)

# 每帧更新道具 Buff 剩余时间，并在到期后恢复默认状态。
func _update_pickup_effects(delta: float) -> void:
	if speed_buff_time_left > 0.0:
		speed_buff_time_left = maxf(speed_buff_time_left - delta, 0.0)
		if speed_buff_time_left <= 0.0:
			current_move_speed_multiplier = DEFAULT_MOVE_SPEED_MULTIPLIER

	if rapid_buff_time_left > 0.0:
		rapid_buff_time_left = maxf(rapid_buff_time_left - delta, 0.0)
		if rapid_buff_time_left <= 0.0:
			rapid_fire_rate_multiplier = DEFAULT_FIRE_RATE_MULTIPLIER
			_refresh_shooting_timer_wait_time()
	_update_character_pickup_effects(delta)


func _update_character_pickup_effects(_delta: float) -> void:
	pass


# 更新临时移速增减的视觉反馈
func _update_movement_status_visuals(move_direction: Vector2) -> void:
	var is_slowed := (
		speed_buff_time_left > 0.0
		and current_move_speed_multiplier < DEFAULT_MOVE_SPEED_MULTIPLIER
	)
	_set_slow_overlay_strength(SLOW_OVERLAY_ACTIVE_STRENGTH if is_slowed else 0.0)

	var is_temporarily_hasted := (
		(
			speed_buff_time_left > 0.0
			and current_move_speed_multiplier > DEFAULT_MOVE_SPEED_MULTIPLIER
		)
		or (
			collectible_swift_time_left > 0.0
			and collectible_swift_move_speed_multiplier > 1.0
		)
	)
	var visual_direction := move_direction
	if visual_direction.length_squared() <= 0.001:
		visual_direction = velocity
	var is_moving := visual_direction.length_squared() > 0.001
	speed_trail_effect.call("set_effect_active", (is_temporarily_hasted or is_dashing()) and is_moving)
	if is_moving:
		speed_trail_effect.call("set_motion_direction", visual_direction)


func _set_slow_overlay_strength(strength: float) -> void:
	var sprite_material := body_sprite.material as ShaderMaterial
	if sprite_material == null:
		return
	sprite_material.set_shader_parameter(
		SLOW_OVERLAY_STRENGTH_SHADER_PARAMETER,
		clampf(strength, 0.0, 1.0)
	)


func _try_apply_wall_overlap_escape(move_input: Vector2, delta: float) -> bool:
	if move_input == Vector2.ZERO:
		return false
	if collision_shape == null or collision_shape.shape == null:
		return false
	var rest_normal := _get_world_overlap_rest_normal(collision_shape.global_transform)
	if rest_normal == Vector2.ZERO:
		return false
	var move_direction := move_input.normalized()
	if move_direction.dot(rest_normal) < WALL_ESCAPE_MIN_OUTWARD_DOT:
		return false
	var current_overlap_count := _count_world_shape_overlaps(collision_shape.global_transform)
	if current_overlap_count <= 0:
		return false
	var step_distance := minf(
		_get_effective_move_speed() * maxf(delta, 0.0),
		WALL_ESCAPE_MAX_STEP_DISTANCE
	)
	if step_distance <= 0.0:
		return false
	var step := move_direction * step_distance
	var next_transform := collision_shape.global_transform
	next_transform.origin += step
	if _count_world_shape_overlaps(next_transform) > current_overlap_count:
		return false
	global_position += step
	return true


func _get_world_overlap_rest_normal(shape_transform: Transform2D) -> Vector2:
	var query := PhysicsShapeQueryParameters2D.new()
	query.shape = collision_shape.shape
	query.transform = shape_transform
	query.collision_mask = WORLD_COLLISION_MASK
	query.collide_with_bodies = true
	query.collide_with_areas = false
	query.exclude = [get_rid()]
	var result := get_world_2d().direct_space_state.get_rest_info(query)
	if result.is_empty():
		return Vector2.ZERO
	var normal := result.get("normal", Vector2.ZERO) as Vector2
	return normal.normalized() if normal != Vector2.ZERO else Vector2.ZERO


func _count_world_shape_overlaps(shape_transform: Transform2D) -> int:
	var query := PhysicsShapeQueryParameters2D.new()
	query.shape = collision_shape.shape
	query.transform = shape_transform
	query.collision_mask = WORLD_COLLISION_MASK
	query.collide_with_bodies = true
	query.collide_with_areas = false
	query.exclude = [get_rid()]
	return get_world_2d().direct_space_state.intersect_shape(
		query,
		WALL_ESCAPE_QUERY_MAX_RESULTS
	).size()


# 处理移动脚步声播放及间隔控制
func _update_footstep_audio(delta: float, move_input: Vector2) -> void:
	footstep_time_left = maxf(footstep_time_left - delta, 0.0)
	if move_input == Vector2.ZERO:
		footstep_time_left = 0.0
		return
	if footstep_time_left > 0.0:
		return

	footstep_audio.play()
	footstep_time_left = maxf(footstep_interval, 0.05)


# 播放道具拾取和形态加载的音效
func _play_pickup_audio(config: PickupConfig, has_form_override: bool) -> void:
	if config.pickup_type == PickupConfig.PickupType.TENPURA:
		secret_audio.play()
	else:
		powerup_audio.play()

	if has_form_override:
		_play_character_pickup_feedback()


func _play_character_pickup_feedback() -> void:
	pass


func _get_animation_prefix() -> StringName:
	return NORMAL_ANIMATION_PREFIX


# 根据移动和射击输入方向决定玩家角色的朝向更新
func _update_facing(move_input: Vector2, shoot_input: Vector2) -> void:
	var facing_input := shoot_input if shoot_input != Vector2.ZERO else move_input
	if facing_input != Vector2.ZERO:
		facing_suffix = _vector_to_facing_suffix(facing_input)


# 将向量方向映射为预期的字符串后缀名（用于动画）
func _vector_to_facing_suffix(direction: Vector2) -> StringName:
	if abs(direction.x) >= abs(direction.y):
		return &"right" if direction.x > 0.0 else &"left"

	return &"down" if direction.y > 0.0 else &"up"


func get_multiplayer_facing_id() -> int:
	match facing_suffix:
		&"left":
			return 1
		&"up":
			return 2
		&"down":
			return 3
		_:
			return 0


func get_multiplayer_anim_state() -> int:
	return 0


func _set_multiplayer_facing_id(facing_id: int) -> void:
	match facing_id:
		1:
			facing_suffix = &"left"
		2:
			facing_suffix = &"up"
		3:
			facing_suffix = &"down"
		_:
			facing_suffix = &"right"

func _facing_suffix_to_vector(suffix: StringName) -> Vector2:
	match suffix:
		&"left":
			return Vector2.LEFT
		&"up":
			return Vector2.UP
		&"down":
			return Vector2.DOWN
		_:
			return Vector2.RIGHT

# 更新受击后的无敌状态计时
func _update_invincibility(delta: float) -> void:
	if invincibility_time_left <= 0.0:
		return

	invincibility_time_left = maxf(invincibility_time_left - delta, 0.0)
	if invincibility_time_left > 0.0:
		return
	
	_set_hurt_blink_enabled(false)
	_stop_dodge_feedback()


# 开启玩家受伤后的无敌闪烁状态。
func _start_invincibility(show_hurt_blink: bool = true) -> void:
	invincibility_time_left = maxf(invincibility_duration, 0.0)
	_set_hurt_blink_enabled(show_hurt_blink and invincibility_time_left > 0.0)


# 统一设置玩家受击闪烁开关，便于后续与其他表现逻辑解耦。
func _set_hurt_blink_enabled(enabled: bool) -> void:
	var sprite_material := body_sprite.material as ShaderMaterial
	if sprite_material != null:
		sprite_material.set_shader_parameter(BLINK_ENABLED_SHADER_PARAMETER, enabled)


func _start_local_revive_glow_effect() -> void:
	var sprite_material := body_sprite.material as ShaderMaterial
	if sprite_material == null:
		return
	_stop_revive_glow_effect()
	sprite_material.set_shader_parameter(REVIVE_GLOW_COLOR_SHADER_PARAMETER, REVIVE_GLOW_COLOR)
	sprite_material.set_shader_parameter(REVIVE_GLOW_OUTLINE_WIDTH_SHADER_PARAMETER, REVIVE_GLOW_OUTLINE_WIDTH)
	_set_revive_glow_strength(1.0)
	revive_glow_tween = create_tween()
	revive_glow_tween.tween_method(
		_set_revive_glow_strength,
		1.0,
		0.0,
		REVIVE_GLOW_DURATION
	).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	revive_glow_tween.finished.connect(_on_revive_glow_finished)


func _stop_revive_glow_effect() -> void:
	if revive_glow_tween != null:
		revive_glow_tween.kill()
		revive_glow_tween = null
	_set_revive_glow_strength(0.0)


func _on_revive_glow_finished() -> void:
	revive_glow_tween = null
	_set_revive_glow_strength(0.0)


func _set_revive_glow_strength(strength: float) -> void:
	var sprite_material := body_sprite.material as ShaderMaterial
	if sprite_material != null:
		sprite_material.set_shader_parameter(
			REVIVE_GLOW_STRENGTH_SHADER_PARAMETER,
			clampf(strength, 0.0, 1.0)
		)


func _start_dodge_feedback() -> void:
	var sprite_material := body_sprite.material as ShaderMaterial
	if sprite_material == null:
		return
	_stop_dodge_feedback()
	_set_dodge_effect_strength(1.0)
	_set_dodge_sweep(-0.2)
	dodge_feedback_tween = create_tween()
	dodge_feedback_tween.set_parallel(true)
	dodge_feedback_tween.tween_method(
		_set_dodge_sweep,
		-0.2,
		1.2,
		DODGE_EFFECT_DURATION
	).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	dodge_feedback_tween.tween_method(
		_set_dodge_effect_strength,
		1.0,
		0.0,
		DODGE_EFFECT_DURATION
	).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	dodge_feedback_tween.finished.connect(_on_dodge_feedback_finished)


func _stop_dodge_feedback() -> void:
	if dodge_feedback_tween != null:
		dodge_feedback_tween.kill()
		dodge_feedback_tween = null
	_set_dodge_effect_strength(0.0)
	_set_dodge_sweep(0.0)


func _on_dodge_feedback_finished() -> void:
	dodge_feedback_tween = null
	_set_dodge_effect_strength(0.0)


func _set_dodge_effect_strength(strength: float) -> void:
	var sprite_material := body_sprite.material as ShaderMaterial
	if sprite_material != null:
		sprite_material.set_shader_parameter(
			DODGE_EFFECT_STRENGTH_SHADER_PARAMETER,
			clampf(strength, 0.0, 1.0)
		)


func _set_dodge_sweep(progress: float) -> void:
	var sprite_material := body_sprite.material as ShaderMaterial
	if sprite_material != null:
		sprite_material.set_shader_parameter(DODGE_SWEEP_SHADER_PARAMETER, progress)


# 玩家生命值归零时进入死亡状态。
func _die() -> void:
	if peer_id > 0:
		apply_multiplayer_death_state()
		return
	is_dead = true
	_finish_dash()
	_stop_remote_dash_visual()
	multiplayer_dash_protection_time_left = 0.0
	mouse_fire_held = false
	velocity = Vector2.ZERO
	_update_movement_status_visuals(Vector2.ZERO)
	invincibility_time_left = 0.0
	_set_hurt_blink_enabled(false)
	_stop_dodge_feedback()
	_stop_revive_glow_effect()
	shooting_timer.stop()
	_cleanup_character_combat_on_death()
	footstep_audio.stop()
	death_audio.play()
	health_bar.set_health(0, max_health)
	health_bar.visible = false
	_update_skill1_charge_bar()
	_refresh_dash_ready_visual()
	_play_death_animation()
	died.emit()


func _play_death_animation() -> void:
	body_sprite.visible = true
	if body_sprite.sprite_frames != null and body_sprite.sprite_frames.has_animation(&"death"):
		body_sprite.play(&"death")


# 升级基础攻击力，每级 +4
func upgrade_attack() -> void:
	_initialize_base_stats()
	_base_attack_damage += 4
	_refresh_collectible_stats()


# 升级生命值上限，每级 +5，并同步回满当前生命
func upgrade_max_health() -> void:
	_initialize_base_stats()
	_base_max_health += 5
	_refresh_collectible_stats(false)
	current_health = max_health
	health_bar.set_health(current_health, max_health)
	health_changed.emit(current_health, max_health)


# 升级攻击速度，每级攻击间隔减少 5%
func upgrade_attack_speed() -> void:
	_initialize_base_stats()
	_base_fire_interval *= ATTACK_SPEED_UPGRADE_INTERVAL_MULTIPLIER
	fire_interval = _base_fire_interval
	_refresh_shooting_timer_wait_time()


# 升级闪避能力，每级闪避率 +2%
func upgrade_dodge() -> void:
	dodge_chance = minf(dodge_chance + DODGE_UPGRADE_CHANCE_STEP, 1.0)
	dodge_changed.emit(dodge_chance)
