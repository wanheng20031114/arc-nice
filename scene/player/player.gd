extends CharacterBody2D

class_name Player

signal xirang_changed(total: int, added_amount: int)
signal health_changed(current: int, maximum: int)
signal attack_speed_changed(attack_speed: float)
signal dodge_changed(chance: float)
signal profile_display_changed
signal research_technology_level_changed(level: int)
signal died
signal revived

@export var character_id: StringName = &""
@export var move_speed: float = 120.0
@export var max_health: int = 1
@export var invincibility_duration: float = 1.0
@export_range(1.0, 200.0, 1.0, "or_greater") var dash_distance: float = 35.0
@export_range(0.05, 1.0, 0.01, "or_greater") var dash_duration: float = 0.12
@export_range(0.0, 30.0, 0.1, "or_greater") var dash_cooldown: float = 2.2
@export var attack_damage: int = 1
@export var physical_defense: int = 0
@export var magic_defense: int = 0
@export_flags("Land", "Water") var terrain_traversal_types: int = DualGridTilemap.TraversalType.LAND

var current_health: int = 0
var last_damage_taken: int = 0
var last_damage_result: DamageResult = null
var last_healing_received: int = 0
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
var combat_actions_locked: bool = false
var tower_defense_death_presentation_active: bool = false
var peer_id: int = 0
var uses_local_input: bool = true
var network_move_input: Vector2 = Vector2.ZERO
var network_shoot_input: Vector2 = Vector2.ZERO
var network_reload_requested: bool = false
var mouse_fire_held: bool = false
var mouse_viewport_position: Vector2 = Vector2.ZERO
var multiplayer_display_name: String = ""
var client_movement_prediction_only: bool = false
var navigation_collision_extent_radius: float = -1.0
var _pending_healing_number_amount: int = 0
var _healing_number_flush_queued := false

@export var fire_interval: float = 1.0
@export_range(1.0, 1000.0, 1.0, "or_greater") var attack_speed_units_per_attack: float = 100.0
@export var auxiliary_projectile_spawn_distance: float = 12.0
@export var footstep_interval: float = 0.28
@export var skill1_charge_duration: float = 18.0

@onready var body_sprite: AnimatedSprite2D = $BodySprite
@onready var night_light: NightPointLight2D = $NightLight
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
@onready var _net_manager := (
	get_node_or_null("/root/NetManager") as NetManagerStore
)

const COLLECTIBLE_AREA_EFFECT_SCENE := preload("res://scene/collectible_area_effect.tscn")
const COLLECTIBLE_FROST_AREA_EFFECT_SCENE := preload("res://scene/collectible_frost_area_effect.tscn")
const COLLECTIBLE_LIGHTNING_EFFECT_SCENE := preload("res://scene/collectible_lightning_effect.tscn")
const COLLECTIBLE_MOON_SHIELD_SCENE := preload("res://scene/collectible_moon_shield.tscn")
const COLLECTIBLE_ARROW_PROJECTILE_SCENE := preload("res://scene/collectible_arrow_projectile.tscn")
const COLLECTIBLE_SAKURA_ROCKET_SCENE_PATH := (
	"res://scene/collectible_sakura_rocket.tscn"
)
const NORMAL_ANIMATION_PREFIX := &"normal"
const DEFAULT_FIRE_RATE_MULTIPLIER := 1.0
const DEFAULT_MOVE_SPEED_MULTIPLIER := 1.0
const CHEAT_XIRANG_AMOUNT := 1000
const SKILL1_UPGRADE_CHARGE_REDUCTION := 2.0
const SKILL1_UPGRADE_COSTS := [200, 500, 1000, 5000, 10000, 20000]
const SKILL1_MAX_UPGRADE_LEVEL := 6
const RESEARCH_TECHNOLOGY_MAX_LEVEL := 3
const RESEARCH_TECHNOLOGY_COSTS := [2000, 5000, 15000]
const RESEARCH_WEISHIDAIER_BURN_DAMAGE := [10, 20, 30]
const RESEARCH_TIYI_SLOW_MULTIPLIERS := [0.75, 0.5, 0.2]
const RESEARCH_HOE_DEFENSE_BONUSES := [15, 30, 50]
const MAX_MULTIPLAYER_NAME_LENGTH := 12
const NAMEPLATE_SIZE := Vector2(160.0, 30.0)
const NAMEPLATE_WORLD_OFFSET := Vector2(0.0, -19.0)
const DEFAULT_NAMEPLATE_FONT_COLOR := Color(0.96, 0.98, 1.0, 1.0)
const LOCAL_NAMEPLATE_FONT_COLOR := Color(0.38, 1.0, 0.42, 1.0)
const HOMING_ENEMY_BODY_MASK := 4
const HOMING_TARGET_RADIUS := 256.0
const HOMING_TARGET_HALF_ANGLE := PI / 3.0
const HOMING_QUERY_MAX_RESULTS := 64
const THUNDER_LOCAL_TARGET_RADIUS := 256.0
const MIN_SKILL_ACTIVATION_INTERVAL_MSEC := 100
## 指数衰减常数。45/s 保留原实现约 67ms 的 60Hz 5% 收敛时间，
## 同时避免 delta * rate 在 30 FPS 时钳到 1 而退化成单帧跳变。
const MULTIPLAYER_VISUAL_OFFSET_DECAY_RATE := 45.0
const MULTIPLAYER_VISUAL_OFFSET_EPSILON := 0.05
const MULTIPLAYER_VISUAL_SNAP_DISTANCE := 96.0
const WORLD_COLLISION_MASK := 1
const WATER_TERRAIN_COLLISION_LAYER := 1 << 11
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
const BURN_OVERLAY_STRENGTH_SHADER_PARAMETER := &"burn_overlay_strength"
const BLEED_OVERLAY_STRENGTH_SHADER_PARAMETER := &"bleed_overlay_strength"
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
const BURN_OVERLAY_ACTIVE_STRENGTH := 0.26
const BLEED_OVERLAY_ACTIVE_STRENGTH := 0.42
const ATTACK_SPEED_UPGRADE_INTERVAL_MULTIPLIER := 0.95
const DODGE_UPGRADE_CHANCE_STEP := 0.02
const DEFAULT_MAGIC_DEFENSE_LIMIT := 100
const RANGED_DIRECTION_SIDE_THRESHOLD := 0.35
const DEFAULT_SKILL1_DISPLAY_NAME := "技能"
const STATUS_EFFECT_EXPIRY_SCHEDULER_PATH := NodePath("/root/StatusEffectExpiryScheduler")
const BURN_STATUS_SCHEDULER_PATH := NodePath("/root/BurnStatusScheduler")
const BLEED_STATUS_SCHEDULER_PATH := NodePath("/root/BleedStatusScheduler")
const COLD_STATUS_SCHEDULER_PATH := NodePath("/root/ColdStatusScheduler")
const BURN_STATUS_ID := &"burn"
const BLEED_STATUS_ID := &"bleed"
const DEFAULT_BLEED_TICK_INTERVAL_SECONDS := 0.5

static var _collectible_temporary_source_serial: int = 0
# Keep the former one-SceneTreeTimer-per-enemy path available for deterministic
# A/B probes. Production uses one expiry timer per area-slow application; its
# timeout only enqueues the cohort into the shared frame-budgeted scheduler.
static var collectible_slow_batch_expiry_enabled := true
static var collectible_slow_expiry_metrics_enabled := false
static var _collectible_slow_expiry_metrics := {
	"target_registrations": 0,
	"timer_count": 0,
	"batch_timer_count": 0,
	"legacy_timer_count": 0,
	"expiry_callback_count": 0,
	"removed_modifier_count": 0,
}

var facing_suffix: StringName = &"right"

# 当前移动倍率，由道具效果驱动。
var current_move_speed_multiplier: float = DEFAULT_MOVE_SPEED_MULTIPLIER
# 当前射速道具提供的射速倍率。
var rapid_fire_rate_multiplier: float = DEFAULT_FIRE_RATE_MULTIPLIER
# 通用临时增益分别维护剩余持续时间，避免互相覆盖。
var speed_buff_time_left: float = 0.0
var rapid_buff_time_left: float = 0.0
var attack_buff_time_left: float = 0.0
var temporary_attack_damage_multiplier: float = 1.0
var footstep_time_left: float = 0.0
var dodge_chance: float = 0.0
var skill1_unlocked: bool = true
var skill1_charge: float = 0.0
var skill1_upgrade_level: int = 0
var research_technology_level: int = 0
var research_global_move_speed_bonus: float = 0.0
var research_temporary_physical_defense_bonus: int = 0
var skill1_base_charge_duration: float = 0.0
var last_attack_direction: Vector2 = Vector2.RIGHT
var dodge_feedback_tween: Tween = null
var revive_glow_tween: Tween = null
var dash_ready_reveal_tween: Tween = null
var _dash_ready_visual_is_ready: bool = false
var damage_reduction_modifiers: Dictionary = {}
var collectible_periodic_deadlines: Dictionary = {}
var collectible_shot_counters: Dictionary = {}
var collectible_trigger_deadlines: Dictionary = {}
var collectible_swift_time_left: float = 0.0
var collectible_swift_move_speed_multiplier: float = 1.0
var cold_stack_count := 0
var cold_move_speed_multiplier := 1.0
var network_effective_move_speed_multiplier_override: float = 0.0
var tower_defense_fate_max_health_multiplier: float = 1.0
var tower_defense_fate_move_speed_multiplier: float = 1.0
var tower_defense_fate_dash_cooldown_reduction: float = 0.0
var tower_defense_fate_low_health_ratio := 0.0
var tower_defense_fate_low_health_damage_reduction := 0.0
var tower_defense_fate_hurt_move_speed_multiplier := 1.0
var tower_defense_fate_hurt_move_speed_duration := 0.0
var tower_defense_fate_hurt_speed_time_left := 0.0
var collectible_physical_damage_bonus: int = 0
var collectible_magic_damage_bonus: int = 0
var collectible_dash_distance_bonus: float = 0.0
var collectible_dash_cooldown_reduction: float = 0.0
var collectible_attack_speed_bonus: float = 0.0
var collectible_ammo_capacity_additive_bonus: int = 0
var collectible_ammo_capacity_bonus_ratio: float = 0.0
var collectible_reload_time_reduction: float = 0.0
var collectible_skill_charge_bonus_per_second: float = 0.0
var collectible_skill_charge_preserve_chance: float = 0.0
var collectible_base_upgrade_free_chance: float = 0.0
var collectible_damage_against_burning_multiplier: float = 1.0
var collectible_damage_against_bleeding_multiplier: float = 1.0
var collectible_ranged_front_damage_multiplier: float = 1.0
var collectible_ranged_back_damage_multiplier: float = 1.0
var collectible_ranged_dodge_chance: float = 0.0
var collectible_sakura_rocket_scene_cache: PackedScene = null
var active_collectible_items_cache: Array[PickupConfig] = []
var active_periodic_collectible_items_cache: Array[PickupConfig] = []
var active_periodic_collectible_keys_cache: Array[String] = []
var active_collectible_runtime_keys_cache: Dictionary = {}
var active_collectible_cache_initialized := false
var _expired_collectible_trigger_cooldown_keys: Array[String] = []
# Both clocks derive only from simulation delta, so pausing the SceneTree pauses
# cooldowns as before. Periodic time advances only while this peer is authoritative;
# this preserves an armed host cooldown across a temporary authority transition.
var _collectible_runtime_elapsed := 0.0
var _collectible_periodic_elapsed := 0.0
# Stable frames compare only these two minima. The bounded dictionaries are
# rescanned only when the earliest deadline expires or inventory state changes.
var _next_collectible_periodic_deadline := INF
var _next_collectible_trigger_deadline := INF
var _sakura_runtime_load_requested := false
var last_base_upgrade_was_free: bool = false
var _last_skill_activation_msec: int = -MIN_SKILL_ACTIVATION_INTERVAL_MSEC
var _base_stats_initialized: bool = false
var _base_move_speed: float = 0.0
var _base_max_health: int = 0
var _base_attack_damage: float = 0.0
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
var _wall_overlap_query := PhysicsShapeQueryParameters2D.new()
var _wall_overlap_query_exclude: Array[RID] = []
var _wall_overlap_probe_required: bool = true
var _wall_overlap_expected_position := Vector2.ZERO
var _homing_target_shape := CircleShape2D.new()
var _homing_target_query := PhysicsShapeQueryParameters2D.new()
var _slow_overlay_strength := -1.0
var _burn_overlay_strength := -1.0
var _bleed_overlay_strength := -1.0
var _speed_trail_effect_active := false
var _speed_trail_motion_direction := Vector2.ZERO


static func set_collectible_slow_batch_expiry_enabled(enabled: bool) -> void:
	collectible_slow_batch_expiry_enabled = enabled


static func set_collectible_slow_expiry_metrics_enabled(enabled: bool) -> void:
	collectible_slow_expiry_metrics_enabled = enabled
	reset_collectible_slow_expiry_metrics()


static func reset_collectible_slow_expiry_metrics() -> void:
	for metric_key in _collectible_slow_expiry_metrics:
		_collectible_slow_expiry_metrics[metric_key] = 0


static func get_collectible_slow_expiry_metrics(reset_after_read: bool = false) -> Dictionary:
	var snapshot := _collectible_slow_expiry_metrics.duplicate()
	if reset_after_read:
		reset_collectible_slow_expiry_metrics()
	return snapshot


static func _increment_collectible_slow_expiry_metric(metric_key: String, amount: int = 1) -> void:
	if not collectible_slow_expiry_metrics_enabled:
		return
	_collectible_slow_expiry_metrics[metric_key] = (
		int(_collectible_slow_expiry_metrics.get(metric_key, 0)) + amount
	)


func get_navigation_collision_extent_radius() -> float:
	if navigation_collision_extent_radius >= 0.0:
		return navigation_collision_extent_radius
	if collision_shape == null or collision_shape.shape == null:
		return 0.0
	var shape_rect := collision_shape.shape.get_rect()
	var corners: Array[Vector2] = [
		shape_rect.position,
		Vector2(shape_rect.end.x, shape_rect.position.y),
		shape_rect.end,
		Vector2(shape_rect.position.x, shape_rect.end.y),
	]
	navigation_collision_extent_radius = 0.0
	for corner in corners:
		navigation_collision_extent_radius = maxf(
			navigation_collision_extent_radius,
			(collision_shape.transform * corner).length()
		)
	return navigation_collision_extent_radius


# 节点首次进入场景树时的初始化逻辑
func _ready() -> void:
	_apply_terrain_collision_profile()
	_configure_wall_overlap_query()
	_configure_homing_target_query()
	_wall_overlap_expected_position = global_position
	_initialize_base_stats()
	_connect_collectible_refresh_signals()
	_rebuild_active_collectible_items_cache()
	# Conditional health effects must evaluate an entering player as healthy,
	# rather than against the construction-time current_health value of zero.
	current_health = _get_collectible_health_condition_maximum(
		active_collectible_items_cache
	)
	_refresh_collectible_stats(false)
	_ensure_skill1_base_charge_duration()
	current_health = maxi(max_health, 1)
	_initialize_character_resources()
	shooting_timer.one_shot = true
	shooting_timer.wait_time = _get_effective_fire_interval()
	_set_hurt_blink_enabled(false)
	_set_dash_effect_strength(0.0)
	_set_revive_glow_strength(0.0)
	_set_burn_overlay_strength(0.0)
	_set_bleed_overlay_strength(0.0)
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
	night_light.set_emission_allowed(not is_dead)
	body_sprite.animation_finished.connect(_on_body_sprite_animation_finished)
	get_window().focus_exited.connect(_on_window_focus_exited)


func _exit_tree() -> void:
	clear_damage_over_time_statuses()
	clear_cold_status()


func _apply_terrain_collision_profile() -> void:
	var can_traverse_water := (
		terrain_traversal_types & DualGridTilemap.TraversalType.WATER
	) != 0
	if can_traverse_water:
		collision_mask &= ~WATER_TERRAIN_COLLISION_LAYER
	else:
		collision_mask |= WATER_TERRAIN_COLLISION_LAYER


func _configure_wall_overlap_query() -> void:
	_wall_overlap_query.shape = collision_shape.shape if collision_shape != null else null
	_wall_overlap_query.collision_mask = WORLD_COLLISION_MASK
	_wall_overlap_query.collide_with_bodies = true
	_wall_overlap_query.collide_with_areas = false
	_wall_overlap_query_exclude.clear()
	_wall_overlap_query_exclude.append(get_rid())
	_wall_overlap_query.exclude = _wall_overlap_query_exclude


func _configure_homing_target_query() -> void:
	_homing_target_shape.radius = HOMING_TARGET_RADIUS
	_homing_target_query.shape = _homing_target_shape
	_homing_target_query.collision_mask = HOMING_ENEMY_BODY_MASK
	_homing_target_query.collide_with_bodies = true
	_homing_target_query.collide_with_areas = false


func _refresh_wall_overlap_probe_gate() -> void:
	# World collision comes from static authored TileMap geometry. A transform
	# change outside this movement loop (spawn, revive or network correction) is
	# therefore the only way to become newly embedded without a preceding slide.
	if not global_position.is_equal_approx(_wall_overlap_expected_position):
		_wall_overlap_probe_required = true


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

	mouse_fire_held = (
		mouse_event.pressed
		and not are_combat_actions_locked()
		and not is_dead
	)
	if mouse_fire_held:
		get_viewport().set_input_as_handled()


# 物理帧更新，处理玩家移动、射击和无敌/增益状态更新
func _physics_process(delta: float) -> void:
	_update_invincibility(delta)
	_update_pickup_effects(delta)
	_update_tower_defense_fate_effects(delta)
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
	var combat_input_locked := are_combat_actions_locked()
	var shoot_input := (
		Vector2.ZERO
		if combat_input_locked
		else _get_current_shoot_input()
	)
	_refresh_wall_overlap_probe_gate()
	if uses_local_input and Input.is_action_just_pressed(&"dash"):
		_try_start_dash(move_input)
	if uses_local_input and mouse_fire_held and not combat_input_locked:
		shoot_input = _get_mouse_shoot_direction()
	if not uses_local_input and network_reload_requested:
		network_reload_requested = false
		if not combat_input_locked:
			_try_start_reload()

	var dash_was_active := is_dashing()
	var movement_visual_direction := dash_direction if dash_was_active else move_input
	if dash_was_active:
		_perform_dash_movement(delta)
		# A dash can finish against a wall or be corrected by collision recovery.
		# Probe once when ordinary movement resumes.
		_wall_overlap_probe_required = true
	else:
		velocity = move_input * _get_effective_move_speed()
		var applied_wall_overlap_escape := false
		if _wall_overlap_probe_required:
			applied_wall_overlap_escape = _try_apply_wall_overlap_escape(
				move_input,
				delta
			)
		if applied_wall_overlap_escape:
			# Keep checking until the authored body has completely left the wall.
			_wall_overlap_probe_required = true
		else:
			move_and_slide()
			if move_input != Vector2.ZERO:
				_wall_overlap_probe_required = get_slide_collision_count() > 0
	_wall_overlap_expected_position = global_position
	_update_movement_status_visuals(movement_visual_direction)
	_update_footstep_audio(delta, Vector2.ZERO if dash_was_active else move_input)

	if not combat_input_locked:
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
	if are_combat_actions_locked():
		return
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
	if are_combat_actions_locked():
		return
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
	if item.requires_ammunition and not uses_ammunition():
		return false
	return true


func uses_attack_interval_bar() -> bool:
	return false


func plays_multiplayer_death_animation() -> bool:
	return (
		body_sprite != null
		and body_sprite.sprite_frames != null
		and body_sprite.sprite_frames.has_animation(&"death")
	)


func notify_primary_attack_performed() -> void:
	if not _should_run_authoritative_collectible_effects():
		return
	_trigger_collectible_primary_attack_effects()

# 应用道具效果，更新玩家形态、射速、移速等增益状态
func apply_pickup(config: PickupConfig, apply_healing: bool = true) -> bool:
	if config == null:
		return false
	if config.pickup_type in [
		PickupConfig.PickupType.MATERIAL,
		PickupConfig.PickupType.BUILDING,
	]:
		return false
		
	var applied := false
	var should_refresh_shooting_timer := false
	var buff_duration := maxf(config.duration, 0.0)
	var requests_character_form_override := (
		config.player_form_mode != PickupConfig.PlayerFormMode.NORMAL
		or config.shot_pattern != PickupConfig.ShotPattern.NORMAL
	)
	var character_pickup_applied := false

	var has_fire_rate_override := not is_equal_approx(
		config.fire_rate_multiplier,
		DEFAULT_FIRE_RATE_MULTIPLIER
	)

	if not is_equal_approx(config.move_speed_multiplier, DEFAULT_MOVE_SPEED_MULTIPLIER):
		current_move_speed_multiplier = config.move_speed_multiplier
		speed_buff_time_left = buff_duration
		applied = true

	# Multiplayer clients replay the non-health parts of a reliable pickup/item
	# event, then receive health through net_player_healed. This prevents a
	# cross-channel ordering race from applying the same healing twice.
	if apply_healing and config.heal_amount > 0:
		applied = _try_heal(config.heal_amount) or applied
	elif not apply_healing and config.heal_amount > 0:
		# The authoritative health event is delivered separately, but this reliable
		# replay still represents a successfully consumed healing pickup/item.
		applied = true

	# 普通射速道具与形态专属射速提升维护，避免螺旋形态的射速被其他 Buff 状态覆盖。
	if has_fire_rate_override and not requests_character_form_override:
		rapid_fire_rate_multiplier = config.fire_rate_multiplier
		rapid_buff_time_left = buff_duration
		should_refresh_shooting_timer = true
		applied = true
	if not is_equal_approx(config.attack_damage_multiplier, 1.0):
		temporary_attack_damage_multiplier = maxf(config.attack_damage_multiplier, 0.1)
		attack_buff_time_left = buff_duration
		_refresh_collectible_stats(false)
		applied = true
	# Form-pattern pickups may have a character-specific non-projectile
	# interpretation, so the character hook decides whether it can consume one.
	if requests_character_form_override:
		character_pickup_applied = _apply_character_pickup(config, buff_duration)
		should_refresh_shooting_timer = character_pickup_applied
		applied = character_pickup_applied or applied

	if should_refresh_shooting_timer:
		_refresh_shooting_timer_wait_time()
	if applied:
		_play_pickup_audio(config, character_pickup_applied)
	return applied


## 播放成功收入背包的世界掉落反馈；库存生产、转移等非拾取事务不应调用此入口。
func play_world_inventory_pickup_feedback(config: PickupConfig) -> void:
	if config == null or not config.can_store_in_inventory:
		return
	_play_pickup_audio(config, false)


func _apply_character_pickup(_config: PickupConfig, _buff_duration: float) -> bool:
	return false
	
# 敌人或其他伤害来源统一通过这个入口让玩家受伤。
func apply_damage(
	amount: int,
	damage_type: EnemyConfig.DamageType = EnemyConfig.DamageType.PHYSICAL,
	damage_context: Dictionary = {}
) -> bool:
	var request := DamageRequest.new(amount, int(damage_type))
	var is_ranged := bool(damage_context.get("is_ranged", false))
	request.with_flag(CombatTypes.DamageFlag.RANGED, is_ranged)
	var source_direction := Vector2.ZERO
	var source_direction_variant: Variant = damage_context.get(
		"source_direction",
		Vector2.ZERO
	)
	if source_direction_variant is Vector2:
		source_direction = source_direction_variant as Vector2
	request.with_directions(-source_direction, source_direction)
	return apply_combat_damage(request).accepted


## 直接生命损失用于规则明确要求“扣除精确生命”的非战斗事务。
## 它不经过防御、减伤、闪避、无敌帧或受击触发，但仍复用玩家的血条、
## 属性条件刷新与死亡生命周期。minimum_health 可用于“只保留 1 HP”。
func apply_direct_health_loss(amount: int, minimum_health: int = 0) -> int:
	if is_dead or amount <= 0:
		return 0
	var health_floor := clampi(minimum_health, 0, current_health)
	var next_health := maxi(current_health - amount, health_floor)
	var applied_loss := current_health - next_health
	if applied_loss <= 0:
		return 0
	current_health = next_health
	last_damage_taken = applied_loss
	if peer_id <= 0:
		show_damage_number(
			applied_loss,
			Vector2.ZERO,
			EnemyConfig.DamageType.PHYSICAL
		)
	health_bar.set_health(current_health, max_health)
	health_changed.emit(current_health, max_health)
	_refresh_collectible_stats(false)
	if current_health <= 0:
		_die()
	return applied_loss


## Unified damage sink. Avoidance remains target-owned because it depends on
## live dash, invincibility, facing and collectible state; all numeric stages
## after acceptance are delegated to DamageResolver.
func apply_combat_damage(request: DamageRequest) -> DamageResult:
	last_damage_taken = 0
	if request == null:
		return _reject_combat_damage(
			request,
			CombatTypes.DamageRejectionReason.INVALID_REQUEST
		)
	if is_dead:
		return _reject_combat_damage(
			request,
			CombatTypes.DamageRejectionReason.TARGET_DEAD
		)
	if request.amount <= 0:
		return _reject_combat_damage(
			request,
			CombatTypes.DamageRejectionReason.INVALID_AMOUNT
		)
	if (
		not request.has_flag(CombatTypes.DamageFlag.BYPASS_INVULNERABILITY)
		and (is_dash_invulnerable() or invincibility_time_left > 0.0)
	):
		return _reject_combat_damage(
			request,
			CombatTypes.DamageRejectionReason.INVULNERABLE
		)
	if not request.has_flag(CombatTypes.DamageFlag.BYPASS_DODGE):
		if dodge_chance > 0.0 and randf() < dodge_chance:
			_start_dodge_feedback()
			_start_invincibility(false)
			return _reject_combat_damage(
				request,
				CombatTypes.DamageRejectionReason.DODGED
			)
		if _try_collectible_ranged_dodge_request(request):
			_start_dodge_feedback()
			_start_invincibility(false)
			return _reject_combat_damage(
				request,
				CombatTypes.DamageRejectionReason.DODGED
			)

	var result := DamageResolver.resolve(
		request,
		_create_damage_target_profile(request)
	)
	last_damage_result = result
	if not result.accepted:
		return result

	current_health = result.health_after
	last_damage_taken = result.applied_damage
	if (
		last_damage_taken > 0
		and tower_defense_fate_hurt_move_speed_duration > 0.0
	):
		_activate_tower_defense_fate_hurt_speed_penalty()
	if peer_id <= 0:
		show_damage_number(
			result.applied_damage,
			_get_damage_number_impact_direction_request(request),
			request.damage_type as EnemyConfig.DamageType
		)
	health_bar.set_health(current_health, max_health)
	health_changed.emit(current_health, max_health)
	_refresh_collectible_stats(false)
	if result.lethal:
		_die()
		return result

	_trigger_collectible_hurt_effects()
	if not request.has_flag(CombatTypes.DamageFlag.NO_HIT_INVINCIBILITY):
		_start_invincibility()
	return result


## Applies an already-established periodic effect. It still respects the
## matching defense and damage-reduction rules, but intentionally cannot be
## dodged and neither consumes nor grants ordinary hit invincibility.
func apply_periodic_damage(
	amount: int,
	damage_type: EnemyConfig.DamageType = EnemyConfig.DamageType.MAGIC
) -> bool:
	var request := DamageRequest.new(amount, int(damage_type))
	request.flags = (
		CombatTypes.DamageFlag.PERIODIC
		| CombatTypes.DamageFlag.BYPASS_INVULNERABILITY
		| CombatTypes.DamageFlag.BYPASS_DODGE
		| CombatTypes.DamageFlag.NO_HIT_INVINCIBILITY
	)
	return apply_combat_damage(request).accepted


func apply_burn_status(
	source_family: StringName,
	duration: float,
	tick_damage: int
) -> bool:
	if (
		is_dead
		or not is_inside_tree()
		or source_family == &""
		or duration <= 0.0
		or tick_damage <= 0
	):
		return false
	var scheduler := get_node_or_null(BURN_STATUS_SCHEDULER_PATH)
	if scheduler == null:
		push_error("BurnStatusScheduler autoload is missing.")
		return false
	return bool(scheduler.call(
		"apply_burn",
		self,
		Callable(self, "_receive_incoming_burn_tick"),
		source_family,
		duration,
		tick_damage,
		Callable(self, "_on_burn_status_active_changed")
	))


func clear_burn_status() -> void:
	_set_burn_overlay_strength(0.0)
	if not is_inside_tree():
		return
	var scheduler := get_node_or_null(BURN_STATUS_SCHEDULER_PATH)
	if scheduler != null:
		scheduler.call("clear_target", self)


func apply_bleed_status(
	source_family: StringName,
	duration: float,
	tick_damage: int,
	tick_interval: float = DEFAULT_BLEED_TICK_INTERVAL_SECONDS
) -> bool:
	if (
		is_dead
		or not is_inside_tree()
		or source_family == &""
		or duration <= 0.0
		or tick_damage <= 0
		or tick_interval <= 0.0
	):
		return false
	var scheduler := get_node_or_null(BLEED_STATUS_SCHEDULER_PATH)
	if scheduler == null:
		push_error("BleedStatusScheduler autoload is missing.")
		return false
	return bool(scheduler.call(
		"apply_bleed",
		self,
		Callable(self, "_receive_incoming_bleed_tick"),
		source_family,
		duration,
		tick_damage,
		tick_interval,
		Callable(self, "_on_bleed_status_active_changed")
	))


func clear_bleed_status() -> void:
	_set_bleed_overlay_strength(0.0)
	if not is_inside_tree():
		return
	var scheduler := get_node_or_null(BLEED_STATUS_SCHEDULER_PATH)
	if scheduler != null:
		scheduler.call("clear_target", self)


func has_damage_over_time_status(
	status_id: StringName,
	source_family: StringName = &""
) -> bool:
	var scheduler_path := NodePath()
	match status_id:
		BURN_STATUS_ID:
			scheduler_path = BURN_STATUS_SCHEDULER_PATH
		BLEED_STATUS_ID:
			scheduler_path = BLEED_STATUS_SCHEDULER_PATH
		_:
			return false
	var scheduler := get_node_or_null(scheduler_path)
	return (
		scheduler != null
		and bool(scheduler.call("has_status", self, source_family))
	)


func clear_damage_over_time_status(status_id: StringName) -> bool:
	match status_id:
		BURN_STATUS_ID:
			clear_burn_status()
			return true
		BLEED_STATUS_ID:
			clear_bleed_status()
			return true
		_:
			return false


func clear_damage_over_time_statuses() -> void:
	clear_burn_status()
	clear_bleed_status()


func _on_burn_status_active_changed(active: bool) -> void:
	_set_burn_overlay_strength(
		BURN_OVERLAY_ACTIVE_STRENGTH if active else 0.0
	)


func _on_bleed_status_active_changed(active: bool) -> void:
	_set_bleed_overlay_strength(
		BLEED_OVERLAY_ACTIVE_STRENGTH if active else 0.0
	)


func apply_cold_status() -> bool:
	if is_dead or not is_inside_tree():
		return false
	var scheduler := get_node_or_null(COLD_STATUS_SCHEDULER_PATH)
	if scheduler == null:
		push_error("ColdStatusScheduler autoload is missing.")
		return false
	return bool(scheduler.call(
		"apply_cold",
		self,
		Callable(self, "_apply_cold_runtime_state")
	))


func clear_cold_status() -> void:
	var scheduler := (
		get_node_or_null(COLD_STATUS_SCHEDULER_PATH)
		if is_inside_tree()
		else null
	)
	if scheduler != null and bool(scheduler.call("clear_target", self)):
		return
	_apply_cold_runtime_state(0, 1.0)


func get_cold_stack_count() -> int:
	return cold_stack_count


func _apply_cold_runtime_state(stack_count: int, multiplier: float) -> void:
	var safe_stack_count := clampi(stack_count, 0, 4)
	var safe_multiplier := (
		clampf(multiplier, 0.0, 1.0)
		if safe_stack_count > 0
		else 1.0
	)
	if (
		cold_stack_count == safe_stack_count
		and is_equal_approx(cold_move_speed_multiplier, safe_multiplier)
	):
		return
	cold_stack_count = safe_stack_count
	cold_move_speed_multiplier = safe_multiplier
	_update_movement_status_visuals(Vector2.ZERO)


func _receive_incoming_burn_tick(
	source_family: StringName,
	tick_damage: int
) -> bool:
	return _receive_incoming_damage_over_time_tick(
		BURN_STATUS_ID,
		source_family,
		tick_damage,
		EnemyConfig.DamageType.MAGIC
	)


func _receive_incoming_bleed_tick(
	source_family: StringName,
	tick_damage: int
) -> bool:
	return _receive_incoming_damage_over_time_tick(
		BLEED_STATUS_ID,
		source_family,
		tick_damage,
		EnemyConfig.DamageType.PHYSICAL
	)


func _receive_incoming_damage_over_time_tick(
	status_id: StringName,
	source_family: StringName,
	tick_damage: int,
	damage_type: EnemyConfig.DamageType
) -> bool:
	if is_dead:
		return false
	if peer_id > 0:
		var current_scene := get_tree().current_scene
		if (
			current_scene != null
			and current_scene.has_method(
				"request_multiplayer_player_damage_over_time_tick"
			)
		):
			return bool(current_scene.call(
				"request_multiplayer_player_damage_over_time_tick",
				peer_id,
				status_id,
				source_family,
				tick_damage
			))
	return apply_periodic_damage(
		tick_damage,
		damage_type
	)


func _try_collectible_ranged_dodge(damage_context: Dictionary) -> bool:
	if collectible_ranged_dodge_chance <= 0.0:
		return false
	if not _is_ranged_damage_context(damage_context):
		return false
	return randf() < collectible_ranged_dodge_chance


func _try_collectible_ranged_dodge_request(request: DamageRequest) -> bool:
	return (
		request.has_flag(CombatTypes.DamageFlag.RANGED)
		and collectible_ranged_dodge_chance > 0.0
		and randf() < collectible_ranged_dodge_chance
	)


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
		if not source_direction.is_finite():
			return Vector2.ZERO
		if source_direction.length_squared() > 0.001:
			return source_direction.normalized()
	return Vector2.ZERO


func _get_damage_number_impact_direction(damage_context: Dictionary) -> Vector2:
	return -_get_damage_source_side_direction(damage_context)


func _get_collectible_ranged_damage_multiplier_request(
	request: DamageRequest
) -> float:
	if not request.has_flag(CombatTypes.DamageFlag.RANGED):
		return 1.0
	var source_side := request.get_safe_source_direction()
	if source_side == Vector2.ZERO:
		return 1.0
	var facing_direction := _facing_suffix_to_vector(facing_suffix)
	var side_dot := facing_direction.dot(source_side)
	if side_dot >= RANGED_DIRECTION_SIDE_THRESHOLD:
		return maxf(collectible_ranged_front_damage_multiplier, 0.0)
	if side_dot <= -RANGED_DIRECTION_SIDE_THRESHOLD:
		return maxf(collectible_ranged_back_damage_multiplier, 0.0)
	return 1.0


func _get_damage_number_impact_direction_request(
	request: DamageRequest
) -> Vector2:
	var impact_direction := request.get_safe_impact_direction()
	if impact_direction != Vector2.ZERO:
		return impact_direction
	return -request.get_safe_source_direction()


func show_damage_number(
	amount: int,
	impact_direction: Vector2 = Vector2.ZERO,
	damage_type: EnemyConfig.DamageType = EnemyConfig.DamageType.PHYSICAL
) -> void:
	if amount <= 0:
		return
	var damage_number_owner := get_parent()
	while damage_number_owner != null:
		if damage_number_owner.has_method("show_damage_number"):
			damage_number_owner.call(
				"show_damage_number",
				amount,
				global_position,
				impact_direction,
				damage_type,
				DamageNumberPool.DisplayPriority.IMPORTANT
			)
			return
		damage_number_owner = damage_number_owner.get_parent()


func queue_healing_number(amount: int) -> void:
	if amount <= 0:
		return
	_pending_healing_number_amount += amount
	if _healing_number_flush_queued:
		return
	_healing_number_flush_queued = true
	call_deferred("_flush_pending_healing_number")


func _flush_pending_healing_number() -> void:
	_healing_number_flush_queued = false
	var amount := _pending_healing_number_amount
	_pending_healing_number_amount = 0
	if amount <= 0:
		return
	var combat_number_owner := get_parent()
	while combat_number_owner != null:
		if combat_number_owner.has_method("show_combat_number"):
			combat_number_owner.call(
				"show_combat_number",
				amount,
				global_position,
				DamageNumberPool.CombatNumberKind.HEALING,
				Vector2.ZERO,
				EnemyConfig.DamageType.PHYSICAL,
				DamageNumberPool.DisplayPriority.IMPORTANT
			)
			return
		combat_number_owner = combat_number_owner.get_parent()


func _create_damage_target_profile(request: DamageRequest) -> DamageTargetProfile:
	var profile := DamageTargetProfile.new(
		current_health,
		physical_defense,
		magic_defense
	)
	profile.pre_mitigation_multiplier = (
		_get_collectible_ranged_damage_multiplier_request(request)
	)
	profile.pre_multiplier_rounding = CombatTypes.RoundingMode.NEAREST
	var strongest_reduction := 0.0
	for reduction in damage_reduction_modifiers.values():
		strongest_reduction = maxf(strongest_reduction, float(reduction))
	if (
		tower_defense_fate_low_health_damage_reduction > 0.0
		and tower_defense_fate_low_health_ratio > 0.0
		and current_health > 0
		and float(current_health)
			< float(maxi(max_health, 1)) * tower_defense_fate_low_health_ratio
	):
		strongest_reduction = maxf(
			strongest_reduction,
			tower_defense_fate_low_health_damage_reduction
		)
	profile.post_mitigation_multiplier = (
		1.0 - clampf(strongest_reduction, 0.0, 0.95)
	)
	profile.post_multiplier_rounding = CombatTypes.RoundingMode.FLOOR
	return profile


func _reject_combat_damage(
	request: DamageRequest,
	reason: int
) -> DamageResult:
	last_damage_result = DamageResult.rejected(request, reason, current_health)
	return last_damage_result
	
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
	_rebuild_active_collectible_items_cache()
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


## Applies the tower-defense fate modifiers as absolute run state. Calling this
## repeatedly is idempotent and never mutates the shared character resource.
func configure_tower_defense_fate_modifiers(
	max_health_multiplier: float,
	move_speed_multiplier: float,
	dash_cooldown_reduction: float,
	low_health_ratio: float,
	low_health_damage_reduction: float,
	hurt_move_speed_multiplier: float,
	hurt_move_speed_duration: float
) -> void:
	var safe_max_health_multiplier := maxf(max_health_multiplier, 0.01)
	var safe_move_speed_multiplier := maxf(move_speed_multiplier, 0.0)
	var safe_dash_cooldown_reduction := maxf(dash_cooldown_reduction, 0.0)
	var profile_values_changed := (
		not is_equal_approx(
			tower_defense_fate_move_speed_multiplier,
			safe_move_speed_multiplier
		)
		or not is_equal_approx(
			tower_defense_fate_dash_cooldown_reduction,
			safe_dash_cooldown_reduction
		)
	)
	tower_defense_fate_max_health_multiplier = safe_max_health_multiplier
	tower_defense_fate_move_speed_multiplier = safe_move_speed_multiplier
	tower_defense_fate_dash_cooldown_reduction = safe_dash_cooldown_reduction
	tower_defense_fate_low_health_ratio = clampf(low_health_ratio, 0.0, 1.0)
	tower_defense_fate_low_health_damage_reduction = clampf(
		low_health_damage_reduction,
		0.0,
		0.95
	)
	tower_defense_fate_hurt_move_speed_multiplier = maxf(
		hurt_move_speed_multiplier,
		0.0
	)
	tower_defense_fate_hurt_move_speed_duration = maxf(
		hurt_move_speed_duration,
		0.0
	)
	if tower_defense_fate_hurt_move_speed_duration <= 0.0:
		tower_defense_fate_hurt_speed_time_left = 0.0

	if _base_stats_initialized:
		_refresh_collectible_stats()
		_update_movement_status_visuals(Vector2.ZERO)
		_refresh_dash_ready_visual()
		if profile_values_changed:
			profile_display_changed.emit()


func clear_tower_defense_fate_modifiers() -> void:
	configure_tower_defense_fate_modifiers(
		1.0,
		1.0,
		0.0,
		0.0,
		0.0,
		1.0,
		0.0
	)


func set_controls_locked(locked: bool) -> void:
	controls_locked = locked
	if controls_locked:
		_finish_dash()
		mouse_fire_held = false
		velocity = Vector2.ZERO
		footstep_audio.stop()
	_refresh_dash_ready_visual()


func set_combat_actions_locked(locked: bool) -> void:
	combat_actions_locked = locked
	if combat_actions_locked:
		mouse_fire_held = false
		network_shoot_input = Vector2.ZERO
		network_reload_requested = false
	_on_combat_actions_lock_changed(combat_actions_locked)


func are_combat_actions_locked() -> bool:
	return controls_locked or combat_actions_locked


func _on_combat_actions_lock_changed(_locked: bool) -> void:
	pass


func configure_multiplayer_control(
	new_peer_id: int,
	use_local_input: bool,
	display_name: String = "",
	predict_movement_only: bool = false,
	highlight_as_local_player: bool = false
) -> void:
	var was_alive_at_full_health := (
		is_node_ready()
		and not is_dead
		and current_health >= max_health
	)
	peer_id = new_peer_id
	# Multiplayer inventories are keyed by peer. Rebind the immutable item cache
	# as soon as this scene instance receives its authoritative peer identity.
	_rebuild_active_collectible_items_cache()
	if is_node_ready():
		if was_alive_at_full_health:
			current_health = _get_collectible_health_condition_maximum(
				active_collectible_items_cache
			)
		_refresh_collectible_stats(false)
		# Players enter the tree before their peer id is assigned. If the active
		# RunState peer had a different max-health inventory, preserve the intended
		# full-health spawn instead of retaining that temporary peer's old maximum.
		if was_alive_at_full_health:
			current_health = max_health
			health_bar.set_health(current_health, max_health)
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
	var blend := 1.0 - exp(
		-MULTIPLAYER_VISUAL_OFFSET_DECAY_RATE * maxf(delta, 0.0)
	)
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
	network_shoot_input = (
		Vector2.ZERO
		if are_combat_actions_locked()
		else shoot_input.limit_length(1.0)
	)
	if use_reload and not are_combat_actions_locked():
		_try_start_reload()
	_update_facing(remote_velocity, network_shoot_input)
	_update_animation()
	_update_character_visual_state()


func update_multiplayer_authority_passive_state(delta: float) -> void:
	_update_invincibility(delta)
	_update_multiplayer_dash_protection(delta)
	_update_pickup_effects(delta)
	_update_tower_defense_fate_effects(delta)
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
	if is_dead or are_combat_actions_locked():
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
	var previous_health := current_health
	var previous_max_health := max_health
	var previous_skill1_unlocked := skill1_unlocked
	var previous_skill1_upgrade_level := skill1_upgrade_level
	var previous_skill1_charge_duration := skill1_charge_duration
	max_health = maxi(new_max_health, 1)
	var clamped_xirang := maxi(new_current_xirang, 0)
	if current_xirang != clamped_xirang:
		current_xirang = clamped_xirang
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
	var clamped_health: int = clampi(new_current_health, 0, max_health)
	if new_is_dead or clamped_health <= 0:
		apply_multiplayer_death_state()
		_update_skill1_charge_bar()
		_update_character_visual_state()
		if tower_defense_death_presentation_active:
			_apply_tower_defense_hidden_death_state()
		return
	# Tower-defense revives are reliable authoritative events. An older alive
	# realtime snapshot must never unlock a dead player or clear spectator HUD.
	if is_dead and tower_defense_death_presentation_active:
		_apply_tower_defense_hidden_death_state()
		return
	if is_dead:
		revive_multiplayer(global_position, clamped_health, new_invincibility_time_left)
	else:
		current_health = clamped_health
		if (
			current_health != previous_health
			or max_health != previous_max_health
			or skill1_unlocked != previous_skill1_unlocked
		):
			_refresh_collectible_stats(false)
		health_bar.visible = true
		health_bar.setup(max_health, current_health)
		health_changed.emit(current_health, max_health)
	invincibility_time_left = maxf(new_invincibility_time_left, 0.0)
	_set_hurt_blink_enabled(invincibility_time_left > 0.0)
	_refresh_shooting_timer_wait_time()
	_update_skill1_charge_bar()
	_update_animation()
	_update_character_visual_state()
	if (
		skill1_unlocked != previous_skill1_unlocked
		or skill1_upgrade_level != previous_skill1_upgrade_level
		or not is_equal_approx(
			skill1_charge_duration,
			previous_skill1_charge_duration
		)
	):
		profile_display_changed.emit()


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
	if (
		is_dead
		and tower_defense_death_presentation_active
		and not new_is_dead
		and clamped_health > 0
	):
		_apply_tower_defense_hidden_death_state()
		return
	current_health = clamped_health
	_refresh_collectible_stats(false)
	if new_is_dead or current_health <= 0:
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
	clear_damage_over_time_statuses()
	clear_cold_status()
	tower_defense_death_presentation_active = false
	global_position = revive_position
	reset_physics_interpolation()
	_set_multiplayer_visual_offset(Vector2.ZERO)
	is_dead = false
	night_light.set_emission_allowed(true)
	controls_locked = false
	mouse_fire_held = false
	velocity = Vector2.ZERO
	current_health = max_health if revived_health < 0 else clampi(revived_health, 1, max_health)
	_refresh_collectible_stats(false)
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
	if was_dead:
		revived.emit()
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
	night_light.set_emission_allowed(false)
	clear_damage_over_time_statuses()
	clear_cold_status()
	controls_locked = true
	_finish_dash()
	_stop_remote_dash_visual()
	multiplayer_dash_protection_time_left = 0.0
	tower_defense_fate_hurt_speed_time_left = 0.0
	mouse_fire_held = false
	network_move_input = Vector2.ZERO
	network_shoot_input = Vector2.ZERO
	network_reload_requested = false
	velocity = Vector2.ZERO
	_update_movement_status_visuals(Vector2.ZERO)
	var health_condition_may_change := current_health != 0
	current_health = 0
	if health_condition_may_change:
		_refresh_collectible_stats(false)
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
		var keep_completed_tower_death_hidden := (
			tower_defense_death_presentation_active
			and was_dead
			and not body_sprite.visible
		)
		if (
			not keep_completed_tower_death_hidden
			and (not was_dead or not body_sprite.visible or body_sprite.animation != &"death")
		):
			_play_death_animation()
	else:
		body_sprite.visible = false
		body_sprite.stop()
	if collision_shape != null:
		collision_shape.set_deferred("disabled", true)
	if tower_defense_death_presentation_active:
		_apply_tower_defense_hidden_death_state()
	_refresh_dash_ready_visual()
	health_changed.emit(current_health, max_health)
	if not was_dead:
		death_audio.play()
		died.emit()


func apply_tower_defense_death_presentation() -> void:
	if not is_dead:
		return
	tower_defense_death_presentation_active = true
	_apply_tower_defense_hidden_death_state()


func _apply_tower_defense_hidden_death_state(force_hide_body: bool = false) -> void:
	controls_locked = true
	mouse_fire_held = false
	velocity = Vector2.ZERO
	var keep_death_animation_visible := (
		not force_hide_body
		and body_sprite.visible
		and body_sprite.animation == &"death"
		and body_sprite.is_playing()
	)
	if not keep_death_animation_visible:
		body_sprite.stop()
		body_sprite.hide()
	nameplate_layer.hide()
	health_bar.hide()
	if attack_interval_bar != null:
		attack_interval_bar.hide()
	if collision_shape != null:
		collision_shape.set_deferred("disabled", true)
	_update_movement_status_visuals(Vector2.ZERO)
	_update_skill1_charge_bar()
	_refresh_dash_ready_visual()


func _on_body_sprite_animation_finished() -> void:
	if (
		is_dead
		and tower_defense_death_presentation_active
		and body_sprite.animation == &"death"
	):
		_apply_tower_defense_hidden_death_state(true)


func _reset_character_resources_on_revive() -> void:
	pass


func _cleanup_character_combat_on_death() -> void:
	pass


func grant_xirang_reward(
	amount: int,
	play_pickup_audio: bool = false
) -> bool:
	if amount <= 0:
		return false
	current_xirang += amount
	xirang_changed.emit(current_xirang, amount)
	# Enemy kill rewards are deposited directly and have no physical orb to
	# absorb, so their default path must stay silent. Keep the cue available for
	# a future explicit pickup mechanic instead of coupling it to every grant.
	if play_pickup_audio:
		_play_xirang_pickup_audio()
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


func try_spend_xirang(amount: int) -> bool:
	if amount <= 0 or current_xirang < amount:
		return false
	current_xirang -= amount
	xirang_changed.emit(current_xirang, -amount)
	return true


func get_research_technology_level() -> int:
	return research_technology_level


func set_research_technology_level(level: int) -> void:
	var resolved_level := clampi(level, 0, RESEARCH_TECHNOLOGY_MAX_LEVEL)
	if research_technology_level == resolved_level:
		return
	research_technology_level = resolved_level
	research_technology_level_changed.emit(research_technology_level)


func set_research_global_move_speed_bonus(bonus: float) -> void:
	var resolved_bonus := maxf(bonus, 0.0)
	if is_equal_approx(research_global_move_speed_bonus, resolved_bonus):
		return
	research_global_move_speed_bonus = resolved_bonus
	_refresh_collectible_stats(false)


func get_next_research_technology_cost() -> int:
	if research_technology_level >= RESEARCH_TECHNOLOGY_MAX_LEVEL:
		return 0
	return int(RESEARCH_TECHNOLOGY_COSTS[research_technology_level])


func get_research_burn_tick_damage() -> int:
	if character_id != &"weishidaier" or research_technology_level <= 0:
		return 0
	return int(RESEARCH_WEISHIDAIER_BURN_DAMAGE[research_technology_level - 1])


func get_research_tiyi_slow_multiplier() -> float:
	if character_id != &"tiyi" or research_technology_level <= 0:
		return 1.0
	return float(RESEARCH_TIYI_SLOW_MULTIPLIERS[research_technology_level - 1])


func get_research_hoe_physical_defense_bonus() -> int:
	if character_id != &"hoe_cat" or research_technology_level <= 0:
		return 0
	return int(RESEARCH_HOE_DEFENSE_BONUSES[research_technology_level - 1])


func set_research_temporary_physical_defense_bonus(bonus: int) -> void:
	research_temporary_physical_defense_bonus = maxi(bonus, 0)
	_refresh_collectible_stats(false)


func _grant_xirang_unrestricted(amount: int) -> bool:
	if amount <= 0:
		return false

	current_xirang += amount
	xirang_changed.emit(current_xirang, amount)
	_play_xirang_pickup_audio()
	return true


func _play_xirang_pickup_audio() -> void:
	if not uses_local_input:
		return
	xirang_pickup_audio.pitch_scale = randf_range(1.12, 1.26)
	xirang_pickup_audio.play()


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
	profile_display_changed.emit()
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
	var previous_level := skill1_upgrade_level
	var previous_duration := skill1_charge_duration
	skill1_upgrade_level = clampi(upgrade_level, 0, SKILL1_MAX_UPGRADE_LEVEL)
	_ensure_skill1_base_charge_duration()
	_sync_skill1_charge_duration_to_upgrade_level()
	_update_skill1_charge_bar()
	if (
		skill1_upgrade_level != previous_level
		or not is_equal_approx(skill1_charge_duration, previous_duration)
	):
		profile_display_changed.emit()


func _apply_next_skill1_upgrade() -> void:
	_ensure_skill1_base_charge_duration()
	skill1_upgrade_level = mini(skill1_upgrade_level + 1, SKILL1_MAX_UPGRADE_LEVEL)
	_sync_skill1_charge_duration_to_upgrade_level()
	_update_skill1_charge_bar()
	profile_display_changed.emit()
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


func _try_heal(amount: int, report_multiplayer: bool = true) -> bool:
	last_healing_received = 0
	if is_dead:
		return false
	if amount <= 0:
		return false
	if current_health >= max_health:
		return false

	var previous_health := current_health
	current_health = mini(current_health + amount, max_health)
	last_healing_received = current_health - previous_health
	health_bar.set_health(current_health, max_health)
	health_changed.emit(current_health, max_health)
	_refresh_collectible_stats(false)
	if peer_id <= 0:
		queue_healing_number(last_healing_received)
	elif report_multiplayer:
		var current_scene := get_tree().current_scene
		if (
			current_scene != null
			and current_scene.has_method("report_multiplayer_player_healing")
		):
			current_scene.call(
				"report_multiplayer_player_healing",
				self,
				last_healing_received
			)
	return true


## Public authoritative healing entry point. Returns the amount actually
## restored so periodic fate effects can account for maximum-health clamping.
func heal(amount: int, report_multiplayer: bool = true) -> int:
	if not _try_heal(amount, report_multiplayer):
		return 0
	return last_healing_received


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
	_homing_target_query.transform = Transform2D(0.0, global_position)
	var normalized_direction := shoot_direction.normalized()
	var best_target: Enemy = null
	var best_distance_squared := INF
	for result in space_state.intersect_shape(
		_homing_target_query,
		HOMING_QUERY_MAX_RESULTS
	):
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
	_rebuild_active_collectible_items_cache()
	_refresh_collectible_stats()


func _on_collectible_xirang_changed(_total: int, _added_amount: int) -> void:
	_refresh_collectible_stats()


func _refresh_collectible_stats(emit_changes: bool = true) -> void:
	_initialize_base_stats()
	var active_items := _get_active_collectible_items()
	var previous_attack_damage := attack_damage
	var previous_move_speed := move_speed
	var previous_physical_defense := physical_defense
	var previous_magic_defense := magic_defense

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
	var ammo_capacity_additive_bonus := 0
	var ammo_capacity_bonus_ratio := 0.0
	var reload_time_reduction := 0.0
	var skill_charge_bonus := 0.0
	var skill_charge_preserve_chance := 0.0
	var base_upgrade_free_chance := 0.0
	var damage_against_burning_multiplier := 1.0
	var damage_against_bleeding_multiplier := 1.0
	var ranged_front_damage_multiplier := 1.0
	var ranged_back_damage_multiplier := 1.0
	var ranged_dodge_chance := 0.0
	# Health-ratio conditions must use the maximum that this same refresh is
	# about to publish. Otherwise adding/removing a max-health collectible can
	# leave a threshold effect one refresh behind.
	var health_condition_maximum := _get_collectible_health_condition_maximum(
		active_items
	)

	for item in active_items:
		if item.periodic_effect_id == PickupConfig.PERIODIC_EFFECT_SAKURA_ROCKET:
			_request_sakura_runtime_resources()
		attack_bonus += item.collectible_attack_bonus
		max_health_bonus += item.collectible_max_health_bonus
		move_speed_bonus += item.collectible_move_speed_bonus
		attack_speed_bonus += item.collectible_attack_speed_bonus
		ammo_capacity_additive_bonus += item.collectible_ammo_capacity_additive_bonus
		ammo_capacity_bonus_ratio = maxf(
			ammo_capacity_bonus_ratio,
			item.collectible_ammo_capacity_bonus_ratio
		)
		reload_time_reduction = maxf(
			reload_time_reduction,
			item.collectible_reload_time_reduction
		)
		physical_defense_bonus += item.collectible_physical_defense_bonus
		magic_defense_bonus += item.collectible_magic_defense_bonus
		physical_damage_bonus += item.collectible_physical_damage_bonus
		magic_damage_bonus += item.collectible_magic_damage_bonus
		dash_distance_bonus += item.collectible_dash_distance_bonus
		dash_cooldown_reduction += clampf(
			item.collectible_dash_cooldown_reduction,
			0.0,
			PickupConfig.MAX_DASH_COOLDOWN_REDUCTION_PER_COLLECTIBLE
		)
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
		if _is_collectible_condition_active(item, health_condition_maximum):
			attack_bonus += item.conditional_attack_bonus
			max_health_bonus += item.conditional_max_health_bonus
			move_speed_bonus += item.conditional_move_speed_bonus
			physical_defense_bonus += item.conditional_physical_defense_bonus
			magic_defense_bonus += item.conditional_magic_defense_bonus
			physical_damage_bonus += item.conditional_physical_damage_bonus
			magic_damage_bonus += item.conditional_magic_damage_bonus
			skill_charge_bonus += item.conditional_skill_charge_bonus_per_second

	var old_max_health := max_health
	# 允许角色以半点为单位配置成长，但对外战斗伤害始终保持整数。
	attack_damage = maxi(
		ceili(
			float(roundi(_base_attack_damage) + attack_bonus)
			* maxf(temporary_attack_damage_multiplier, 0.1)
		),
		1
	)
	max_health = maxi(
		roundi(
			float(_base_max_health + max_health_bonus)
			* tower_defense_fate_max_health_multiplier
		),
		1
	)
	move_speed = maxf(
		_base_move_speed
		+ move_speed_bonus
		+ research_global_move_speed_bonus,
		0.0
	)
	physical_defense = maxi(
		_base_physical_defense
		+ physical_defense_bonus
		+ research_temporary_physical_defense_bonus,
		0
	)
	magic_defense = clampi(_base_magic_defense + magic_defense_bonus, 0, DEFAULT_MAGIC_DEFENSE_LIMIT)
	fire_interval = maxf(_base_fire_interval, 0.01)
	collectible_physical_damage_bonus = physical_damage_bonus
	collectible_magic_damage_bonus = magic_damage_bonus
	collectible_dash_distance_bonus = dash_distance_bonus
	collectible_dash_cooldown_reduction = dash_cooldown_reduction
	collectible_attack_speed_bonus = attack_speed_bonus
	collectible_ammo_capacity_additive_bonus = maxi(ammo_capacity_additive_bonus, 0)
	collectible_ammo_capacity_bonus_ratio = maxf(ammo_capacity_bonus_ratio, 0.0)
	collectible_reload_time_reduction = clampf(reload_time_reduction, 0.0, 0.95)
	collectible_skill_charge_bonus_per_second = skill_charge_bonus
	collectible_skill_charge_preserve_chance = clampf(skill_charge_preserve_chance, 0.0, 1.0)
	collectible_base_upgrade_free_chance = clampf(base_upgrade_free_chance, 0.0, 1.0)
	collectible_damage_against_burning_multiplier = maxf(damage_against_burning_multiplier, 0.0)
	collectible_damage_against_bleeding_multiplier = maxf(damage_against_bleeding_multiplier, 0.0)
	collectible_ranged_front_damage_multiplier = maxf(ranged_front_damage_multiplier, 0.0)
	collectible_ranged_back_damage_multiplier = maxf(ranged_back_damage_multiplier, 0.0)
	collectible_ranged_dodge_chance = clampf(ranged_dodge_chance, 0.0, 1.0)

	if old_max_health != max_health:
		current_health = clampi(current_health, 0, max_health)
		if health_bar != null:
			health_bar.set_health(current_health, max_health)
		if emit_changes:
			health_changed.emit(current_health, max_health)
	_on_collectible_ammunition_stats_refreshed()
	_refresh_shooting_timer_wait_time()
	if (
		attack_damage != previous_attack_damage
		or not is_equal_approx(move_speed, previous_move_speed)
		or physical_defense != previous_physical_defense
		or magic_defense != previous_magic_defense
	):
		profile_display_changed.emit()


func _on_collectible_ammunition_stats_refreshed() -> void:
	pass


func _get_active_collectible_items() -> Array[PickupConfig]:
	if not active_collectible_cache_initialized:
		_rebuild_active_collectible_items_cache()
	return active_collectible_items_cache


func _get_collectible_health_condition_maximum(
	active_items: Array[PickupConfig]
) -> int:
	var result := _base_max_health
	for item in active_items:
		result += item.collectible_max_health_bonus
	return maxi(
		roundi(float(result) * tower_defense_fate_max_health_multiplier),
		1
	)


func _rebuild_active_collectible_items_cache() -> void:
	active_collectible_items_cache.clear()
	active_periodic_collectible_items_cache.clear()
	active_periodic_collectible_keys_cache.clear()
	active_collectible_runtime_keys_cache.clear()
	_next_collectible_periodic_deadline = 0.0
	active_collectible_cache_initialized = false
	var run_state := get_node_or_null("/root/RunState") as RunStateStore
	if run_state == null:
		_prune_inactive_collectible_runtime_state()
		return

	var active_copy_counts: Dictionary = {}
	for slot_index in range(RunStateStore.INVENTORY_CAPACITY):
		var item := _get_inventory_item(run_state, slot_index)
		if item == null:
			continue
		if item.pickup_type != PickupConfig.PickupType.COLLECTIBLE:
			continue
		var effect_key := _get_collectible_runtime_key(item)
		var active_copies := int(active_copy_counts.get(effect_key, 0))
		if not item.collectible_stacks_by_copy:
			if active_copies > 0:
				continue
			active_copy_counts[effect_key] = 1
			active_collectible_items_cache.append(item)
			continue

		var copies_to_activate := _get_inventory_item_count(run_state, slot_index)
		if item.collectible_max_copies > 0:
			copies_to_activate = mini(
				copies_to_activate,
				maxi(item.collectible_max_copies - active_copies, 0)
			)
		for _copy_index in range(copies_to_activate):
			active_collectible_items_cache.append(item)
		active_copy_counts[effect_key] = active_copies + copies_to_activate
	for item in active_collectible_items_cache:
		if (
			not item.periodic_effect_id.is_empty()
			or _has_collectible_trigger(item)
			or _has_collectible_bullet_or_kill_effect(item)
		):
			active_collectible_runtime_keys_cache[
				_get_collectible_runtime_key(item)
			] = true
		if not item.periodic_effect_id.is_empty() and item.periodic_interval > 0.0:
			active_periodic_collectible_items_cache.append(item)
			active_periodic_collectible_keys_cache.append(
				_get_collectible_runtime_key(item)
			)
	_prune_inactive_collectible_runtime_state()
	active_collectible_cache_initialized = true


func _prune_inactive_collectible_runtime_state() -> void:
	var removed_periodic_deadline := false
	for cooldown_key in collectible_periodic_deadlines.keys():
		if active_collectible_runtime_keys_cache.has(cooldown_key):
			continue
		collectible_periodic_deadlines.erase(cooldown_key)
		removed_periodic_deadline = true
	for counter_key in collectible_shot_counters.keys():
		if not active_collectible_runtime_keys_cache.has(counter_key):
			collectible_shot_counters.erase(counter_key)

	var removed_trigger_deadline := false
	for trigger_key in collectible_trigger_deadlines.keys():
		var owner_key := _get_collectible_trigger_owner_key(trigger_key)
		if active_collectible_runtime_keys_cache.has(owner_key):
			continue
		collectible_trigger_deadlines.erase(trigger_key)
		removed_trigger_deadline = true

	# Removing the earliest entry invalidates its O(1) threshold. Additions need
	# no trigger rescan because starting a cooldown updates the threshold itself.
	if removed_periodic_deadline:
		_next_collectible_periodic_deadline = 0.0
	if removed_trigger_deadline:
		_next_collectible_trigger_deadline = 0.0


func _get_inventory_item(run_state: RunStateStore, slot_index: int) -> PickupConfig:
	if peer_id > 0:
		return run_state.get_item_for_peer(peer_id, slot_index)
	return run_state.get_item(slot_index)


func _get_inventory_item_count(run_state: RunStateStore, slot_index: int) -> int:
	if peer_id > 0:
		return run_state.get_item_count_for_peer(peer_id, slot_index)
	return run_state.get_item_count(slot_index)


func _get_collectible_runtime_key(item: PickupConfig) -> String:
	if item == null:
		return ""
	if not item.collectible_effect_id.is_empty():
		return item.collectible_effect_id
	return item.resource_path


func _is_collectible_condition_active(
	item: PickupConfig,
	health_condition_maximum: int = -1
) -> bool:
	if item == null or item.conditional_effect_id.is_empty():
		return false
	match item.conditional_effect_id:
		PickupConfig.CONDITION_HEALTH_BELOW:
			var health_below_maximum := (
				health_condition_maximum
				if health_condition_maximum > 0
				else max_health
			)
			if health_below_maximum <= 0:
				return false
			return (
				float(current_health) / float(health_below_maximum)
				<= item.conditional_health_ratio_threshold
			)
		PickupConfig.CONDITION_HEALTH_ABOVE:
			var health_above_maximum := (
				health_condition_maximum
				if health_condition_maximum > 0
				else max_health
			)
			if health_above_maximum <= 0:
				return false
			return (
				float(current_health) / float(health_above_maximum)
				>= item.conditional_health_ratio_threshold
			)
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
	if not _should_run_authoritative_collectible_effects():
		return
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
	if float(collectible_trigger_deadlines.get(trigger_key, 0.0)) > _collectible_runtime_elapsed:
		return false
	var deadline := _collectible_runtime_elapsed + item.trigger_cooldown
	collectible_trigger_deadlines[trigger_key] = deadline
	_next_collectible_trigger_deadline = minf(
		_next_collectible_trigger_deadline,
		deadline
	)
	return true


func _try_start_collectible_aux_cooldown(item: PickupConfig, suffix: String, cooldown: float) -> bool:
	if cooldown <= 0.0:
		return true
	var trigger_key := _get_collectible_aux_key(item, suffix)
	if float(collectible_trigger_deadlines.get(trigger_key, 0.0)) > _collectible_runtime_elapsed:
		return false
	var deadline := _collectible_runtime_elapsed + cooldown
	collectible_trigger_deadlines[trigger_key] = deadline
	_next_collectible_trigger_deadline = minf(
		_next_collectible_trigger_deadline,
		deadline
	)
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
			var max_enemy_health := enemy.get_runtime_max_health()
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
	var safe_delta := maxf(delta, 0.0)
	_collectible_runtime_elapsed += safe_delta

	if collectible_swift_time_left > 0.0:
		collectible_swift_time_left = maxf(collectible_swift_time_left - delta, 0.0)
		if collectible_swift_time_left <= 0.0:
			collectible_swift_move_speed_multiplier = 1.0

	if _collectible_runtime_elapsed >= _next_collectible_trigger_deadline:
		_expired_collectible_trigger_cooldown_keys.clear()
		var next_trigger_deadline := INF
		for trigger_key: String in collectible_trigger_deadlines:
			var deadline := float(collectible_trigger_deadlines.get(trigger_key, 0.0))
			if deadline <= _collectible_runtime_elapsed:
				_expired_collectible_trigger_cooldown_keys.append(trigger_key)
			else:
				next_trigger_deadline = minf(next_trigger_deadline, deadline)
		for trigger_key in _expired_collectible_trigger_cooldown_keys:
			collectible_trigger_deadlines.erase(trigger_key)
		_expired_collectible_trigger_cooldown_keys.clear()
		_next_collectible_trigger_deadline = next_trigger_deadline

	if not _should_run_authoritative_collectible_effects():
		return
	var periodic_frame_start_time := _collectible_periodic_elapsed
	_collectible_periodic_elapsed += safe_delta
	if active_periodic_collectible_items_cache.is_empty():
		_next_collectible_periodic_deadline = INF
		return
	if _collectible_periodic_elapsed < _next_collectible_periodic_deadline:
		return

	var next_periodic_deadline := INF
	for periodic_index in active_periodic_collectible_items_cache.size():
		var item := active_periodic_collectible_items_cache[periodic_index]
		var cooldown_key := active_periodic_collectible_keys_cache[periodic_index]
		var deadline := float(
			collectible_periodic_deadlines.get(
				cooldown_key,
				periodic_frame_start_time + item.periodic_interval
			)
		)
		if deadline <= _collectible_periodic_elapsed:
			_trigger_collectible_periodic_effect(item)
			deadline = (
				_collectible_periodic_elapsed
				+ maxf(item.periodic_interval, 0.1)
			)
		collectible_periodic_deadlines[cooldown_key] = deadline
		next_periodic_deadline = minf(next_periodic_deadline, deadline)
	_next_collectible_periodic_deadline = next_periodic_deadline


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
	var enemy := _pick_random_thunder_target()
	if enemy == null or not is_instance_valid(enemy):
		return
	var impact_position := enemy.global_position
	var radius := maxf(item.periodic_radius, 1.0)
	var damage := get_collectible_outgoing_damage(
		item.periodic_damage,
		EnemyConfig.DamageType.MAGIC
	)
	_apply_effective_collectible_area_damage(
		impact_position,
		radius,
		damage,
		EnemyConfig.DamageType.MAGIC
	)
	_spawn_collectible_lightning_effect(impact_position)


func _trigger_frost_crystal(item: PickupConfig) -> void:
	var radius := maxf(item.periodic_radius, 1.0)
	var damage := get_collectible_outgoing_damage(
		item.periodic_damage,
		EnemyConfig.DamageType.MAGIC
	)
	var slow_source_id := _next_collectible_temporary_source_id()
	var slow_enemy_refs: Array[WeakRef] = []
	var affected_enemies: Array[Enemy] = []
	_query_alive_enemies_in_radius_into(global_position, radius, affected_enemies)
	var radius_squared := radius * radius
	for enemy in affected_enemies:
		if enemy == null or not is_instance_valid(enemy):
			continue
		if global_position.distance_squared_to(enemy.global_position) > radius_squared:
			continue
		_apply_authoritative_collectible_enemy_damage(
			enemy,
			damage,
			enemy.global_position.direction_to(global_position),
			EnemyConfig.DamageType.MAGIC
		)
		enemy.add_move_speed_modifier(slow_source_id, item.periodic_slow_multiplier)
		_queue_collectible_enemy_slow_expiry(
			enemy,
			slow_source_id,
			item.periodic_slow_duration,
			slow_enemy_refs
		)
	_schedule_collectible_enemy_slow_batch_expiry(
		slow_enemy_refs,
		slow_source_id,
		item.periodic_slow_duration
	)
	_spawn_collectible_frost_effect(radius, 0.4)


func _trigger_collectible_custom_thunder(item: PickupConfig) -> void:
	var enemy := _pick_random_thunder_target()
	if enemy == null or not is_instance_valid(enemy):
		return
	var impact_position := enemy.global_position
	var radius := maxf(item.trigger_radius, 1.0)
	var damage := get_collectible_outgoing_damage(
		item.trigger_damage,
		EnemyConfig.DamageType.MAGIC
	)
	_apply_effective_collectible_area_damage(
		impact_position,
		radius,
		damage,
		EnemyConfig.DamageType.MAGIC
	)
	_spawn_collectible_lightning_effect(impact_position)


func _pick_random_thunder_target() -> Enemy:
	var current_scene := get_tree().current_scene
	if current_scene != null and current_scene.has_method("pick_random_combat_target"):
		var nearby_enemy := current_scene.call(
			"pick_random_combat_target",
			global_position,
			THUNDER_LOCAL_TARGET_RADIUS
		) as Enemy
		if nearby_enemy != null:
			return nearby_enemy
		return current_scene.call(
			"pick_random_combat_target",
			global_position,
			0.0
		) as Enemy
	# Non-runtime fixtures keep exact behavior with a reservoir-selected local
	# preference. Production Game/MpGame scenes always use the indexed path above.
	var enemies := _collect_alive_enemies()
	var radius_squared := THUNDER_LOCAL_TARGET_RADIUS * THUNDER_LOCAL_TARGET_RADIUS
	var nearby_choice: Enemy = null
	var nearby_count := 0
	for enemy in enemies:
		if enemy == null or not is_instance_valid(enemy) or enemy.is_dead:
			continue
		if global_position.distance_squared_to(enemy.global_position) > radius_squared:
			continue
		nearby_count += 1
		if randi() % nearby_count == 0:
			nearby_choice = enemy
	if nearby_choice != null:
		return nearby_choice
	if enemies.is_empty():
		return null
	return enemies[randi() % enemies.size()]


func _trigger_collectible_custom_frost(item: PickupConfig) -> void:
	var radius := maxf(item.trigger_radius, 1.0)
	var damage := get_collectible_outgoing_damage(
		item.trigger_damage,
		EnemyConfig.DamageType.MAGIC
	)
	var slow_source_id := _next_collectible_temporary_source_id()
	var slow_enemy_refs: Array[WeakRef] = []
	var affected_enemies: Array[Enemy] = []
	_query_alive_enemies_in_radius_into(global_position, radius, affected_enemies)
	var radius_squared := radius * radius
	for enemy in affected_enemies:
		if enemy == null or not is_instance_valid(enemy):
			continue
		if global_position.distance_squared_to(enemy.global_position) > radius_squared:
			continue
		_apply_authoritative_collectible_enemy_damage(
			enemy,
			damage,
			enemy.global_position.direction_to(global_position),
			EnemyConfig.DamageType.MAGIC
		)
		if item.trigger_slow_multiplier < 1.0:
			enemy.add_move_speed_modifier(slow_source_id, item.trigger_slow_multiplier)
			_queue_collectible_enemy_slow_expiry(
				enemy,
				slow_source_id,
				item.trigger_slow_duration,
				slow_enemy_refs
			)
	_schedule_collectible_enemy_slow_batch_expiry(
		slow_enemy_refs,
		slow_source_id,
		item.trigger_slow_duration
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
	var current_scene := get_tree().current_scene
	if current_scene != null and current_scene.has_method("query_combat_targets"):
		return current_scene.call(
			"query_combat_targets",
			global_position,
			maxf(radius, 0.0),
			maxi(max_count, 0)
		) as Array[Enemy]
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
	if max_count > 0 and filtered.size() > max_count:
		filtered.resize(max_count)
	return filtered


func _sort_enemies_by_distance_to_self(a: Enemy, b: Enemy) -> bool:
	if a == null:
		return false
	if b == null:
		return true
	var a_distance := global_position.distance_squared_to(a.global_position)
	var b_distance := global_position.distance_squared_to(b.global_position)
	if not is_equal_approx(a_distance, b_distance):
		return a_distance < b_distance
	return a.get_instance_id() < b.get_instance_id()


func _spawn_collectible_arrow(target_enemy: Enemy, arrow_damage: int) -> bool:
	if target_enemy == null or not is_instance_valid(target_enemy) or target_enemy.is_dead:
		return false
	var spawn_parent := get_tree().current_scene
	if spawn_parent == null:
		return false
	var shoot_direction := global_position.direction_to(target_enemy.global_position)
	if shoot_direction == Vector2.ZERO:
		shoot_direction = _facing_suffix_to_vector(facing_suffix)
	var arrow: Node = null
	if (
		spawn_parent.has_method("has_session_object_pool_scene")
		and bool(
			spawn_parent.call(
				"has_session_object_pool_scene",
				COLLECTIBLE_ARROW_PROJECTILE_SCENE
			)
		)
	):
		arrow = spawn_parent.call(
			"acquire_session_object",
			COLLECTIBLE_ARROW_PROJECTILE_SCENE,
			false
		)
	else:
		arrow = COLLECTIBLE_ARROW_PROJECTILE_SCENE.instantiate()
	if arrow == null:
		return false
	arrow.top_level = true
	arrow.call("setup", shoot_direction, arrow_damage)
	if arrow.get_parent() == null:
		spawn_parent.add_child(arrow)
	arrow.global_position = global_position + shoot_direction * auxiliary_projectile_spawn_distance
	arrow.reset_physics_interpolation()
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


func _get_collectible_sakura_rocket_scene() -> PackedScene:
	if collectible_sakura_rocket_scene_cache != null:
		return collectible_sakura_rocket_scene_cache
	var status := ResourceLoader.load_threaded_get_status(
		COLLECTIBLE_SAKURA_ROCKET_SCENE_PATH
	)
	if (
		status == ResourceLoader.THREAD_LOAD_LOADED
		or status == ResourceLoader.THREAD_LOAD_IN_PROGRESS
	):
		collectible_sakura_rocket_scene_cache = ResourceLoader.load_threaded_get(
			COLLECTIBLE_SAKURA_ROCKET_SCENE_PATH
		) as PackedScene
	else:
		collectible_sakura_rocket_scene_cache = load(
			COLLECTIBLE_SAKURA_ROCKET_SCENE_PATH
		) as PackedScene
	return collectible_sakura_rocket_scene_cache


func _request_sakura_runtime_resources() -> void:
	if _sakura_runtime_load_requested or collectible_sakura_rocket_scene_cache != null:
		return
	_sakura_runtime_load_requested = true
	var status := ResourceLoader.load_threaded_get_status(
		COLLECTIBLE_SAKURA_ROCKET_SCENE_PATH
	)
	if (
		status == ResourceLoader.THREAD_LOAD_IN_PROGRESS
		or status == ResourceLoader.THREAD_LOAD_LOADED
	):
		return
	var error := ResourceLoader.load_threaded_request(
		COLLECTIBLE_SAKURA_ROCKET_SCENE_PATH,
		"",
		true,
		ResourceLoader.CACHE_MODE_REUSE
	)
	if error != OK:
		_sakura_runtime_load_requested = false
		push_warning("无法预加载樱花收藏品投射物：%s" % error_string(error))


func _spawn_collectible_sakura_rocket(target_enemy: Enemy, rocket_damage: int) -> bool:
	if target_enemy == null or not is_instance_valid(target_enemy) or target_enemy.is_dead:
		return false
	var spawn_parent := get_tree().current_scene
	if spawn_parent == null:
		return false
	var rocket_scene := _get_collectible_sakura_rocket_scene()
	if rocket_scene == null:
		return false
	var shoot_direction := global_position.direction_to(target_enemy.global_position)
	if shoot_direction == Vector2.ZERO:
		shoot_direction = _facing_suffix_to_vector(facing_suffix)
	var rocket: Node2D = null
	if (
		spawn_parent.has_method("has_session_object_pool_scene")
		and bool(spawn_parent.call("has_session_object_pool_scene", rocket_scene))
	):
		rocket = spawn_parent.call(
			"acquire_session_object",
			rocket_scene,
			false
		) as Node2D
	else:
		rocket = rocket_scene.instantiate() as Node2D
	if rocket == null:
		return false
	rocket.top_level = true
	var rocket_speed := float(rocket.get("speed"))
	var rocket_lifetime := float(rocket.get("max_lifetime"))
	var rocket_explosion_radius := float(rocket.get("explosion_radius"))
	var rocket_homing_turn_rate := float(rocket.get("homing_turn_rate"))
	rocket.call(
		"setup",
		shoot_direction,
		rocket_damage,
		rocket_speed,
		rocket_lifetime,
		rocket_explosion_radius,
		null,
		rocket_homing_turn_rate,
		target_enemy,
		true,
		EnemyConfig.DamageType.MAGIC
	)
	if rocket.get_parent() == null:
		spawn_parent.add_child(rocket)
	rocket.global_position = global_position + shoot_direction * auxiliary_projectile_spawn_distance
	rocket.reset_physics_interpolation()
	var target_enemy_net_id := int(target_enemy.get_meta("net_id", 0))
	_register_multiplayer_projectile(
		rocket,
		&"collectible_sakura_rocket",
		rocket.global_position,
		shoot_direction,
		rocket_damage,
		float(rocket.get("speed")),
		float(rocket.get("max_lifetime")),
		false,
		0,
		target_enemy_net_id
	)
	return true


func _queue_collectible_enemy_slow_expiry(
	enemy: Enemy,
	source_id: int,
	duration: float,
	batch_enemy_refs: Array[WeakRef]
) -> void:
	if duration <= 0.0:
		return
	var enemy_ref: WeakRef = weakref(enemy)
	Player._increment_collectible_slow_expiry_metric("target_registrations")
	if Player.collectible_slow_batch_expiry_enabled:
		batch_enemy_refs.append(enemy_ref)
		return
	Player._increment_collectible_slow_expiry_metric("timer_count")
	Player._increment_collectible_slow_expiry_metric("legacy_timer_count")
	get_tree().create_timer(duration).timeout.connect(
		Player._remove_collectible_enemy_slow.bind(enemy_ref, source_id)
	)


func _schedule_collectible_enemy_slow_batch_expiry(
	enemy_refs: Array[WeakRef],
	source_id: int,
	duration: float
) -> void:
	if (
		not Player.collectible_slow_batch_expiry_enabled
		or duration <= 0.0
		or enemy_refs.is_empty()
	):
		return
	Player._increment_collectible_slow_expiry_metric("timer_count")
	Player._increment_collectible_slow_expiry_metric("batch_timer_count")
	get_tree().create_timer(duration).timeout.connect(
		Player._remove_collectible_enemy_slow_batch.bind(enemy_refs, source_id)
	)


static func _remove_collectible_enemy_slow_batch(
	enemy_refs: Array[WeakRef],
	source_id: int
) -> void:
	Player._increment_collectible_slow_expiry_metric("expiry_callback_count")
	var scene_tree := Engine.get_main_loop() as SceneTree
	assert(scene_tree != null)
	var scheduler := scene_tree.root.get_node(STATUS_EFFECT_EXPIRY_SCHEDULER_PATH)
	scheduler.call(
		"enqueue_weak_ref_batch",
		enemy_refs,
		source_id,
		Player._remove_collectible_enemy_slow_from_ref
	)


static func _remove_collectible_enemy_slow(enemy_ref: WeakRef, source_id: int) -> void:
	Player._increment_collectible_slow_expiry_metric("expiry_callback_count")
	Player._remove_collectible_enemy_slow_from_ref(enemy_ref, source_id)


static func _remove_collectible_enemy_slow_from_ref(enemy_ref: WeakRef, source_id: int) -> void:
	var enemy: Enemy = null
	if enemy_ref != null:
		enemy = enemy_ref.get_ref() as Enemy
	if enemy == null or not is_instance_valid(enemy):
		return
	if not enemy.move_speed_modifiers.has(source_id):
		return
	enemy.remove_move_speed_modifier(source_id)
	Player._increment_collectible_slow_expiry_metric("removed_modifier_count")


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
	var request := DamageRequest.new(damage, int(damage_type))
	request.with_source(self, get_instance_id(), &"collectible_effect")
	request.with_directions(impact_direction)
	request.with_flag(
		CombatTypes.DamageFlag.SUPPRESS_HIT_PARTICLES,
		not show_hit_particles
	)
	return enemy.apply_combat_damage(request).accepted


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


func _next_collectible_temporary_source_id() -> int:
	# Persistent collectible status sources are positive. Transient area slows use
	# unique negative IDs so same-frame triggers cannot overwrite one another.
	_collectible_temporary_source_serial += 1
	return -_collectible_temporary_source_serial


func _apply_collectible_area_damage(
	center_position: Vector2,
	radius: float,
	damage: int,
	damage_type: EnemyConfig.DamageType
) -> void:
	var effective_radius := maxf(radius, 1.0)
	var effective_damage := get_collectible_outgoing_damage(maxi(damage, 1), damage_type)
	_apply_effective_collectible_area_damage(
		center_position,
		effective_radius,
		effective_damage,
		damage_type
	)


func _apply_effective_collectible_area_damage(
	center_position: Vector2,
	effective_radius: float,
	effective_damage: int,
	damage_type: EnemyConfig.DamageType
) -> void:
	var affected_enemies: Array[Enemy] = []
	_query_alive_enemies_in_radius_into(center_position, effective_radius, affected_enemies)
	var radius_squared := effective_radius * effective_radius
	for enemy in affected_enemies:
		if enemy == null or not is_instance_valid(enemy):
			continue
		if enemy.global_position.distance_squared_to(center_position) > radius_squared:
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


func _query_alive_enemies_in_radius_into(
	center_position: Vector2,
	radius: float,
	result: Array[Enemy]
) -> void:
	result.clear()
	var current_scene := get_tree().current_scene
	if (
		current_scene != null
		and current_scene.has_method("query_combat_targets_unordered_into")
	):
		current_scene.call(
			"query_combat_targets_unordered_into",
			center_position,
			maxf(radius, 0.0),
			result
		)
		return
	var radius_squared := maxf(radius, 0.0) * maxf(radius, 0.0)
	for enemy in _collect_alive_enemies():
		if enemy == null or not is_instance_valid(enemy) or enemy.is_dead:
			continue
		if center_position.distance_squared_to(enemy.global_position) <= radius_squared:
			result.append(enemy)


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
	var slow_source_id := _next_collectible_temporary_source_id()
	var slow_enemy_refs: Array[WeakRef] = []
	var affected_enemies: Array[Enemy] = []
	_query_alive_enemies_in_radius_into(
		center_position,
		effective_radius,
		affected_enemies
	)
	var radius_squared := effective_radius * effective_radius
	for enemy in affected_enemies:
		if enemy == null or not is_instance_valid(enemy):
			continue
		if enemy.global_position.distance_squared_to(center_position) > radius_squared:
			continue
		_apply_authoritative_collectible_enemy_damage(
			enemy,
			effective_damage,
			center_position.direction_to(enemy.global_position),
			EnemyConfig.DamageType.MAGIC
		)
		if slow_multiplier < 1.0:
			enemy.add_move_speed_modifier(slow_source_id, slow_multiplier)
			_queue_collectible_enemy_slow_expiry(
				enemy,
				slow_source_id,
				slow_duration,
				slow_enemy_refs
			)
	_schedule_collectible_enemy_slow_batch_expiry(
		slow_enemy_refs,
		slow_source_id,
		slow_duration
	)
	_spawn_collectible_frost_effect_at(center_position, effective_radius, 0.4)


func _collect_alive_enemies() -> Array[Enemy]:
	var result: Array[Enemy] = []
	var root := get_tree().current_scene
	if root == null:
		return result
	if root.has_method("get_all_combat_targets"):
		return root.call("get_all_combat_targets") as Array[Enemy]
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
	if _net_manager == null:
		return true
	if not _net_manager.is_multiplayer_active():
		return true
	return _net_manager.is_host()


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
	if not _should_run_authoritative_collectible_effects():
		return
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
	return maxf(
		_get_character_dash_cooldown()
		- collectible_dash_cooldown_reduction
		- tower_defense_fate_dash_cooldown_reduction,
		0.0
	)


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
	_set_speed_trail_motion_direction(dash_direction)
	_set_speed_trail_effect_active(true)
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
	_set_speed_trail_motion_direction(direction)
	_set_speed_trail_effect_active(true)


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
	_set_speed_trail_effect_active(false)


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
	if network_effective_move_speed_multiplier_override > 0.0:
		return move_speed * network_effective_move_speed_multiplier_override
	return move_speed * get_authoritative_move_speed_multiplier()


func get_authoritative_move_speed_multiplier() -> float:
	if tower_defense_fate_hurt_speed_time_left > 0.0:
		# Snapshot replication carries this multiplier. Expressing the absolute
		# starting-speed target as a ratio keeps local and remote movement equal
		# even when collectibles have changed the current move_speed value.
		if move_speed <= 0.0:
			return 0.0
		return (
			maxf(_base_move_speed, 0.0)
			* tower_defense_fate_hurt_move_speed_multiplier
			/ move_speed
		)
	return (
		current_move_speed_multiplier
		* collectible_swift_move_speed_multiplier
		* cold_move_speed_multiplier
		* tower_defense_fate_move_speed_multiplier
	)


func _activate_tower_defense_fate_hurt_speed_penalty() -> void:
	tower_defense_fate_hurt_speed_time_left = (
		tower_defense_fate_hurt_move_speed_duration
	)
	_update_movement_status_visuals(Vector2.ZERO)


func _update_tower_defense_fate_effects(delta: float) -> void:
	if tower_defense_fate_hurt_speed_time_left <= 0.0:
		return
	tower_defense_fate_hurt_speed_time_left = maxf(
		tower_defense_fate_hurt_speed_time_left - maxf(delta, 0.0),
		0.0
	)
	if tower_defense_fate_hurt_speed_time_left <= 0.0:
		_update_movement_status_visuals(Vector2.ZERO)


func apply_multiplayer_effective_move_speed_multiplier(multiplier: float) -> void:
	network_effective_move_speed_multiplier_override = clampf(multiplier, 0.05, 8.0)
	_update_movement_status_visuals(Vector2.ZERO)


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
	if is_equal_approx(shooting_timer.wait_time, new_interval):
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

	if attack_buff_time_left > 0.0:
		attack_buff_time_left = maxf(attack_buff_time_left - delta, 0.0)
		if attack_buff_time_left <= 0.0:
			temporary_attack_damage_multiplier = 1.0
			_refresh_collectible_stats(false)
	_update_character_pickup_effects(delta)


func _update_character_pickup_effects(_delta: float) -> void:
	pass


# 更新临时移速增减的视觉反馈
func _update_movement_status_visuals(move_direction: Vector2) -> void:
	var is_slowed := (
		tower_defense_fate_hurt_speed_time_left > 0.0
		or cold_stack_count > 0
		or (
			speed_buff_time_left > 0.0
			and current_move_speed_multiplier < DEFAULT_MOVE_SPEED_MULTIPLIER
		)
	)
	if network_effective_move_speed_multiplier_override > 0.0:
		is_slowed = (
			cold_stack_count > 0
			or network_effective_move_speed_multiplier_override
				< DEFAULT_MOVE_SPEED_MULTIPLIER
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
	var should_show_speed_trail := (
		(is_temporarily_hasted or is_dashing())
		and is_moving
	)
	if should_show_speed_trail:
		_set_speed_trail_motion_direction(visual_direction)
	_set_speed_trail_effect_active(should_show_speed_trail)


func _set_slow_overlay_strength(strength: float) -> void:
	if body_sprite.material == null:
		return
	var clamped_strength := clampf(strength, 0.0, 1.0)
	if is_equal_approx(_slow_overlay_strength, clamped_strength):
		return
	body_sprite.set_instance_shader_parameter(
		SLOW_OVERLAY_STRENGTH_SHADER_PARAMETER,
		clamped_strength
	)
	_slow_overlay_strength = clamped_strength


func _set_burn_overlay_strength(strength: float) -> void:
	_set_damage_status_overlay_strength(
		BURN_OVERLAY_STRENGTH_SHADER_PARAMETER,
		strength
	)


func _set_bleed_overlay_strength(strength: float) -> void:
	_set_damage_status_overlay_strength(
		BLEED_OVERLAY_STRENGTH_SHADER_PARAMETER,
		strength
	)


func _set_damage_status_overlay_strength(
	parameter_name: StringName,
	strength: float
) -> void:
	if body_sprite.material == null:
		return
	var clamped_strength := clampf(strength, 0.0, 1.0)
	match parameter_name:
		BURN_OVERLAY_STRENGTH_SHADER_PARAMETER:
			if is_equal_approx(_burn_overlay_strength, clamped_strength):
				return
			_burn_overlay_strength = clamped_strength
		BLEED_OVERLAY_STRENGTH_SHADER_PARAMETER:
			if is_equal_approx(_bleed_overlay_strength, clamped_strength):
				return
			_bleed_overlay_strength = clamped_strength
		_:
			return
	body_sprite.set_instance_shader_parameter(
		parameter_name,
		clamped_strength
	)


func _set_speed_trail_effect_active(enabled: bool) -> void:
	if _speed_trail_effect_active == enabled:
		return
	_speed_trail_effect_active = enabled
	speed_trail_effect.call("set_effect_active", enabled)


func _set_speed_trail_motion_direction(direction: Vector2) -> void:
	if direction.length_squared() < DASH_INPUT_MIN_LENGTH_SQUARED:
		return
	var normalized_direction := direction.normalized()
	if _speed_trail_motion_direction.is_equal_approx(normalized_direction):
		return
	_speed_trail_motion_direction = normalized_direction
	speed_trail_effect.call("set_motion_direction", normalized_direction)


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
	_wall_overlap_query.shape = collision_shape.shape
	_wall_overlap_query.transform = shape_transform
	var result := get_world_2d().direct_space_state.get_rest_info(
		_wall_overlap_query
	)
	if result.is_empty():
		return Vector2.ZERO
	var normal := result.get("normal", Vector2.ZERO) as Vector2
	return normal.normalized() if normal != Vector2.ZERO else Vector2.ZERO


func _count_world_shape_overlaps(shape_transform: Transform2D) -> int:
	_wall_overlap_query.shape = collision_shape.shape
	_wall_overlap_query.transform = shape_transform
	return get_world_2d().direct_space_state.intersect_shape(
		_wall_overlap_query,
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


## Presentation-only consumer for an authoritative multiplayer dodge result.
## It deliberately does not roll dodge or mutate health/invincibility.
func play_confirmed_dodge_feedback() -> void:
	if not is_dead:
		_start_dodge_feedback()


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
	night_light.set_emission_allowed(false)
	clear_damage_over_time_statuses()
	clear_cold_status()
	_finish_dash()
	_stop_remote_dash_visual()
	multiplayer_dash_protection_time_left = 0.0
	tower_defense_fate_hurt_speed_time_left = 0.0
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


# 按当前角色的平衡配置升级基础攻击力。
func upgrade_attack() -> void:
	_initialize_base_stats()
	var character_config := get_character_config()
	assert(character_config != null, "Missing PlayerCharacterConfig for '%s'." % character_id)
	_base_attack_damage += character_config.attack_damage_per_upgrade
	_refresh_collectible_stats()


# 升级生命值上限，每级 +5，并同步回满当前生命
func upgrade_max_health() -> void:
	_initialize_base_stats()
	_base_max_health += 5
	_refresh_collectible_stats(false)
	current_health = max_health
	# Full healing can deactivate health-threshold collectibles immediately.
	_refresh_collectible_stats(false)
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
