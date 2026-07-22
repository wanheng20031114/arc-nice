extends CharacterBody2D
class_name Enemy

signal defeated(enemy: Enemy)

const SLOW_OVERLAY_STRENGTH_SHADER_PARAMETER := &"slow_overlay_strength"
const BURN_OVERLAY_STRENGTH_SHADER_PARAMETER := &"burn_overlay_strength"
const BLEED_OVERLAY_STRENGTH_SHADER_PARAMETER := &"bleed_overlay_strength"
const PATH_DIRECTION_PROBE_DISTANCE := 1.0
# Home objectives are static, so distant enemies can approach them with a cheap,
# collision-tested normalized step instead of requesting the shared flow field
# every other physics frame. Once an obstacle is reached, navigation immediately
# falls back to the complete-route flow field below.
const FAR_STATIC_OBJECTIVE_DISTANCE := 320.0
const FAR_STATIC_OBJECTIVE_DISTANCE_SQUARED := (
	FAR_STATIC_OBJECTIVE_DISTANCE * FAR_STATIC_OBJECTIVE_DISTANCE
)
const FAR_STATIC_OBJECTIVE_UPDATE_INTERVAL_FRAMES := 8
# The tower-defense plant aggro radius is eight 16 px cells. Sweep that entire
# local approach so a visible plant on open ground never needs a flow field;
# any wall or water collision still falls back to complete navigation.
const NEAR_STATIC_DIRECT_OBJECTIVE_DISTANCE := 128.0
const NEAR_STATIC_DIRECT_OBJECTIVE_DISTANCE_SQUARED := (
	NEAR_STATIC_DIRECT_OBJECTIVE_DISTANCE * NEAR_STATIC_DIRECT_OBJECTIVE_DISTANCE
)
# Ordinary modes retain their authored 200 px shortcut. Tower defense raises
# this per enemy to its 16-cell aggro radius without changing shared Enemy
# behavior elsewhere.
const DEFAULT_NEAR_MOVING_TARGET_DIRECT_DISTANCE := 200.0
const DEFAULT_NEAR_MOVING_TARGET_DIRECT_DISTANCE_SQUARED := (
	DEFAULT_NEAR_MOVING_TARGET_DIRECT_DISTANCE
	* DEFAULT_NEAR_MOVING_TARGET_DIRECT_DISTANCE
)
const AUDIO_LIMITER := preload("res://scene/explosion_audio_limiter.gd")
const HIT_EFFECT_SCENE := preload("res://scene/enemy/enemy_hit_effect.tscn")
const MOVE_SPEED_TRAIL_EFFECT_SCENE := preload("res://scene/move_speed_trail_effect.tscn")
const WORLD_EFFECT_VISIBILITY := preload("res://scene/world_effect_visibility.gd")
const ENEMY_DROP_PICKUP_SCENE := preload("res://scene/pickup.tscn")
const ENEMY_DROP_INNER_RING_RADIUS := 10.0
const ENEMY_DROP_OUTER_RING_RADIUS := 20.0
const SLOW_OVERLAY_ACTIVE_STRENGTH := 0.36
const BURN_OVERLAY_ACTIVE_STRENGTH := 0.26
const BLEED_OVERLAY_ACTIVE_STRENGTH := 0.42
const BURN_STATUS_TICK_INTERVAL := 1.0
const COLD_STATUS_SCHEDULER_PATH := NodePath("/root/ColdStatusScheduler")
const COLD_MOVE_SPEED_SOURCE_ID := -2_147_400_001
const WATER_TERRAIN_COLLISION_LAYER := 1 << 11
const DEATH_ANIMATION_SPEED_SCALES: Array[float] = [0.92, 0.96, 1.0, 1.04, 1.08]
const DEFAULT_NAVIGATION_UPDATE_INTERVAL_FRAMES := 6
# Attack acquisition may lag by at most two physics ticks while committed
# windups, bursts, movement and hit resolution continue at 60 Hz.
const DEFAULT_COMBAT_SENSE_UPDATE_INTERVAL_FRAMES := 3
# A moving flow field is rebuilt in bounded slices. While the replacement is
# pending, its published anchor may legitimately lag behind the live player.
# Once that lag reaches two cells, prefer the live target immediately whenever
# the immutable agent profile can prove the entire correction corridor open.
const DYNAMIC_FLOW_DIRECT_CORRECTION_DISTANCE_CELLS := 2
const DYNAMIC_FLOW_PREFETCH_LOOKAHEAD_CELLS := 3.0
# Three cells of lookahead provide substantially more warning than one 10 Hz
# sample interval even for the fastest current pursuer. The per-agent throttle
# prevents retries outside an admitted navigation refresh after cache invalidation.
const DYNAMIC_FLOW_PREFETCH_INTERVAL_PHYSICS_FRAMES := 6
const DYNAMIC_TARGET_FINAL_ALIGNMENT_MARGIN := 2.0
const BLOCKED_WORLD_LOS_RETRY_MIN_MSEC := 80
const BLOCKED_WORLD_LOS_RETRY_MAX_MSEC := 120
const BLOCKED_WORLD_LOS_MOTION_INVALIDATION_DISTANCE := 8.0
const BLOCKED_WORLD_LOS_MOTION_INVALIDATION_DISTANCE_SQUARED := (
	BLOCKED_WORLD_LOS_MOTION_INVALIDATION_DISTANCE
	* BLOCKED_WORLD_LOS_MOTION_INVALIDATION_DISTANCE
)
const RANGED_COMBAT_LOS_REFRESH_INTERVAL_PHYSICS_FRAMES := 6
const RANGED_COMBAT_LOS_MOTION_INVALIDATION_DISTANCE := 8.0
const RANGED_COMBAT_LOS_MOTION_INVALIDATION_DISTANCE_SQUARED := (
	RANGED_COMBAT_LOS_MOTION_INVALIDATION_DISTANCE
	* RANGED_COMBAT_LOS_MOTION_INVALIDATION_DISTANCE
)

enum DeathSequenceStage {
	NONE,
	DEATH,
	EXPLOSION,
}

enum LocomotionState {
	IDLE,
	MOVING,
}

static var performance_metrics_enabled := false
static var dynamic_flow_obstacle_lookahead_enabled := true
static var navigation_render_frame_dedupe_enabled := true
static var navigation_process_frame_budget_enabled := true
static var combat_sense_throttling_enabled := true
# Explicit A/B switch for the former behavior where every movement modifier,
# including a visually static slow, enabled one render-frame callback per enemy.
# Configure it before creating/applying the measured cohort; it deliberately
# does not walk every live enemy to migrate process state during a benchmark.
static var slow_only_status_process_optimization_enabled := true
static var _next_navigation_phase_offset := 0
static var _performance_metrics := {
	"touch_damage_calls": 0,
	"touch_damage_usec": 0,
	"navigation_calls": 0,
	"navigation_usec": 0,
	"navigation_refresh_calls": 0,
	"navigation_same_render_skips": 0,
	"navigation_budget_deferrals": 0,
	"navigation_lookahead_calls": 0,
	"navigation_lookahead_usec": 0,
	"navigation_flow_prefetches": 0,
	"navigation_flow_prefetch_deduplicated": 0,
	"test_move_calls": 0,
	"test_move_usec": 0,
	"move_and_slide_calls": 0,
	"move_and_slide_usec": 0,
	"verified_direct_move_calls": 0,
	"verified_direct_move_distance": 0.0,
	"status_process_calls": 0,
	"status_process_usec": 0,
	"ranged_los_calls": 0,
	"ranged_los_usec": 0,
}

@export var config: EnemyConfig
@export var touch_damage_interval: float = 0.5
@export var sprite_faces_left_by_default: bool = false
# Navigation direction is refreshed at 10 Hz by default. Instance offsets split
# a 60 Hz physics cadence into six deterministic groups; movement itself stays
# at the authored physics rate so animation, contact and multiplayer state remain
# smooth between direction samples.
@export_range(1, 8, 1, "or_greater") var navigation_update_interval_frames: int = (
	DEFAULT_NAVIGATION_UPDATE_INTERVAL_FRAMES
)
@export_range(1, 8, 1, "or_greater") var combat_sense_update_interval_frames: int = (
	DEFAULT_COMBAT_SENSE_UPDATE_INTERVAL_FRAMES
)
@export_flags("Land", "Water") var terrain_traversal_types: int = DualGridTilemap.TraversalType.LAND

@onready var animated_sprite: AnimatedSprite2D = $AnimatedSprite2D
@onready var collision_shape: CollisionShape2D = null
@onready var touch_damage_area: Area2D = $TouchDamageArea
@onready var touch_damage_shape: CollisionShape2D = null
@onready var hit_audio: AudioStreamPlayer2D = $HitAudio
@onready var death_audio: AudioStreamPlayer2D = $DeathAudio

var target_player: Player = null
var objective_target: Node2D = null
var pathfinder: Node = null
var projectile_motion_system: Node = null
var current_health: int = 1
var is_dead: bool = false
var touch_damage_cooldown_left: float = 0.0
var touched_player: Player = null
var touching_players: Dictionary[int, Player] = {}
var touched_plant: PlantDefense = null
var touching_plants: Dictionary[int, PlantDefense] = {}
var touching_plant_entry_distances: Dictionary[int, float] = {}
var death_sequence_stage: DeathSequenceStage = DeathSequenceStage.NONE
var death_animation_name_in_use: StringName = &""
var physical_defense_modifiers: Dictionary = {}
var physical_defense_modifier_total := 0
var move_speed_modifiers: Dictionary = {}
var cold_stack_count := 0
var damage_taken_multiplier_modifiers: Dictionary = {}
var collectible_status_effects: Dictionary = {}
var stale_collectible_status_keys: Array = []
var active_collectible_status_keys: Array = []
var network_visual_status_mask: int = 0
var multiplayer_proxy_visual_active: bool = true
var multiplayer_proxy_authored_animation_speed: float = 1.0
var multiplayer_proxy_locomotion_state: int = LocomotionState.IDLE
var collectible_status_tween: Tween = null
var is_multiplayer_proxy: bool = false
var last_damage_taken: int = 0
var body_collision_shapes: Array[CollisionShape2D] = []
var touch_damage_shapes: Array[CollisionShape2D] = []
var mirrored_collision_shapes: Array[CollisionShape2D] = []
var body_collision_extent_radius: float = 0.0
var touch_damage_extent_radius: float = 0.0
var body_collision_half_extents: Vector2 = Vector2.ZERO
var collision_shape_mirror_states: Dictionary = {}
var facing_left: bool = false
var proxy_action_animation_name_in_use: StringName = &""
var proxy_action_restore_token: int = 0
var navigation_update_frame_offset: int = 0
var last_navigation_update_render_frame: int = -1
var last_navigation_refresh_process_frame: int = -1
var navigation_refresh_deferred: bool = false
var cached_navigation_move_direction := Vector2.ZERO
var cached_navigation_uses_direct_objective_approach: bool = false
var cached_navigation_verified_direct_motion_clearance: float = 0.0
var cached_navigation_generation: int = -1
var cached_navigation_tracks_live_target_direction: bool = false
var navigation_next_refresh_physics_frame: int = 0
var navigation_scheduled_refresh_interval_frames: int = 0
var navigation_zero_direction_retry_frame: int = 0
var navigation_flow_prefetch_next_physics_frame: int = 0
var navigation_collision_probe := KinematicCollision2D.new()
var navigation_step_result: GridPathfinder.NavigationStepResult = null
var _world_los_query: PhysicsRayQueryParameters2D = null
var _world_los_exclude: Array[RID] = []
var _blocked_world_los_target_instance_id: int = 0
var _blocked_world_los_target_position := Vector2.ZERO
var _blocked_world_los_source_position := Vector2.ZERO
var _blocked_world_los_collision_mask: int = 0
var _blocked_world_los_retry_after_msec: int = 0
var _blocked_world_los_retry_interval_msec: int = BLOCKED_WORLD_LOS_RETRY_MIN_MSEC
var _ranged_combat_los_target_instance_id: int = 0
var _ranged_combat_los_target_position := Vector2.ZERO
var _ranged_combat_los_source_position := Vector2.ZERO
var _ranged_combat_los_collision_mask: int = 0
var _ranged_combat_los_navigation_generation: int = -1
var _ranged_combat_los_result := false
var _ranged_combat_los_has_result := false
var _ranged_combat_los_last_query_physics_frame: int = -1
var _ranged_combat_los_next_query_physics_frame: int = 0
var _ranged_attack_position_held := false
var navigation_flow_context: GridPathfinder.FlowQueryContext = null
var navigation_agent_profile: GridPathfinder.AgentNavigationProfile = null
var near_moving_target_direct_distance := DEFAULT_NEAR_MOVING_TARGET_DIRECT_DISTANCE
var near_moving_target_direct_distance_squared := (
	DEFAULT_NEAR_MOVING_TARGET_DIRECT_DISTANCE_SQUARED
)
var animated_sprite_base_position := Vector2.ZERO
# Per-enemy combat variation (spread, attack-side choice, and audio pitch).
# Pickup drops deliberately use the separate material_drop_random_generator.
var random_generator := RandomNumberGenerator.new()
var material_drop_random_generator := RandomNumberGenerator.new()
var cached_effective_physical_defense := 0
var cached_effective_move_speed := 0.0
var cached_effective_move_speed_multiplier := 1.0
var status_visual_material: ShaderMaterial = null
var slow_overlay_strength := 0.0
var burn_overlay_strength := 0.0
var bleed_overlay_strength := 0.0
var speed_trail_effect: Node2D = null
var speed_trail_owner_pool: SessionObjectPool = null
var combat_target_index_binding: CombatTargetIndex = null
var combat_target_index_net_id: int = 0
var combat_target_index_bucket := Vector2i.MAX
var combat_target_index_bucket_size := 0.0
var combat_target_index_bucket_minimum := Vector2.ZERO
var combat_target_index_bucket_maximum := Vector2.ZERO


static func set_performance_metrics_enabled(enabled: bool) -> void:
	performance_metrics_enabled = enabled
	reset_performance_metrics()


static func set_slow_only_status_process_optimization_enabled(enabled: bool) -> void:
	slow_only_status_process_optimization_enabled = enabled


static func reset_performance_metrics() -> void:
	_performance_metrics["touch_damage_calls"] = 0
	_performance_metrics["touch_damage_usec"] = 0
	_performance_metrics["navigation_calls"] = 0
	_performance_metrics["navigation_usec"] = 0
	_performance_metrics["navigation_refresh_calls"] = 0
	_performance_metrics["navigation_same_render_skips"] = 0
	_performance_metrics["navigation_budget_deferrals"] = 0
	_performance_metrics["navigation_lookahead_calls"] = 0
	_performance_metrics["navigation_lookahead_usec"] = 0
	_performance_metrics["navigation_flow_prefetches"] = 0
	_performance_metrics["navigation_flow_prefetch_deduplicated"] = 0
	_performance_metrics["test_move_calls"] = 0
	_performance_metrics["test_move_usec"] = 0
	_performance_metrics["move_and_slide_calls"] = 0
	_performance_metrics["move_and_slide_usec"] = 0
	_performance_metrics["verified_direct_move_calls"] = 0
	_performance_metrics["verified_direct_move_distance"] = 0.0
	_performance_metrics["status_process_calls"] = 0
	_performance_metrics["status_process_usec"] = 0
	_performance_metrics["ranged_los_calls"] = 0
	_performance_metrics["ranged_los_usec"] = 0


static func get_performance_metrics(reset_after_read: bool = false) -> Dictionary:
	var snapshot := _performance_metrics.duplicate()
	if reset_after_read:
		reset_performance_metrics()
	return snapshot


static func _record_performance_metric(
	calls_key: String,
	usec_key: String,
	started_usec: int
) -> void:
	_performance_metrics[calls_key] = int(_performance_metrics[calls_key]) + 1
	_performance_metrics[usec_key] = (
		int(_performance_metrics[usec_key])
		+ maxi(Time.get_ticks_usec() - started_usec, 0)
	)


func _ready() -> void:
	_apply_terrain_collision_profile()
	random_generator.randomize()
	material_drop_random_generator.randomize()
	_blocked_world_los_retry_interval_msec = (
		BLOCKED_WORLD_LOS_RETRY_MIN_MSEC
		+ (
			int(get_instance_id())
			% (BLOCKED_WORLD_LOS_RETRY_MAX_MSEC - BLOCKED_WORLD_LOS_RETRY_MIN_MSEC + 1)
		)
	)
	# Allocate offsets from one unbounded sequence so every authored navigation
	# interval receives uniform deterministic phase groups.
	navigation_update_frame_offset = Enemy._next_navigation_phase_offset
	Enemy._next_navigation_phase_offset += 1
	_ranged_combat_los_next_query_physics_frame = (
		_get_next_ranged_combat_los_phase_frame(Engine.get_physics_frames())
	)
	var initial_navigation_interval := _get_navigation_update_interval_frames(
		objective_target
	)
	navigation_zero_direction_retry_frame = _get_next_navigation_phase_frame(
		initial_navigation_interval
	)
	navigation_next_refresh_physics_frame = navigation_zero_direction_retry_frame
	navigation_scheduled_refresh_interval_frames = initial_navigation_interval
	_refresh_collision_shape_cache()
	_cache_collision_shape_mirror_states()
	if animated_sprite != null:
		multiplayer_proxy_authored_animation_speed = animated_sprite.speed_scale
		animated_sprite_base_position = animated_sprite.position
		status_visual_material = animated_sprite.material as ShaderMaterial
		# The default status shader is visually neutral but would split the normal
		# horde into extra CanvasItem batches. Attach the shared material only while
		# an enemy actually has a slow, burn or bleed overlay.
		animated_sprite.material = null
	_apply_sprite_facing()
	_apply_facing_mirror()
	touch_damage_area.body_entered.connect(_on_touch_damage_area_body_entered)
	touch_damage_area.body_exited.connect(_on_touch_damage_area_body_exited)
	animated_sprite.animation_finished.connect(_on_animated_sprite_animation_finished)
	_apply_config()
	_update_movement_status_visuals()
	_refresh_status_process_enabled()


func _notification(what: int) -> void:
	if what != NOTIFICATION_LOCAL_TRANSFORM_CHANGED:
		return
	if (
		combat_target_index_binding == null
		or combat_target_index_net_id <= 0
	):
		return
	# Transform notifications still occur on every physics movement. Keep the hot
	# path entirely local: four comparisons against the current bucket bounds.
	# Shared dictionaries are touched only when the body really crosses a 96 px
	# bucket boundary or teleports beyond it.
	var current_position := global_position
	if (
		current_position.x >= combat_target_index_bucket_minimum.x
		and current_position.x < combat_target_index_bucket_maximum.x
		and current_position.y >= combat_target_index_bucket_minimum.y
		and current_position.y < combat_target_index_bucket_maximum.y
	):
		return
	var safe_bucket_size := maxf(combat_target_index_bucket_size, 1.0)
	var next_bucket := Vector2i(
		floori(current_position.x / safe_bucket_size),
		floori(current_position.y / safe_bucket_size)
	)
	var bound_index := combat_target_index_binding
	var bound_net_id := combat_target_index_net_id
	if bound_index.update_enemy_bucket(bound_net_id, self, next_bucket):
		_cache_combat_target_index_bucket(next_bucket, safe_bucket_size)
		return
	# A replaced/pruned entry must not keep paying transform-notification cost or
	# retain the old RefCounted index for the rest of this enemy's lifetime.
	unbind_combat_target_index(bound_index, bound_net_id)


func bind_combat_target_index(index: CombatTargetIndex, net_id: int) -> void:
	if index == null or net_id <= 0:
		return
	if (
		combat_target_index_binding != null
		and (
			combat_target_index_binding != index
			or combat_target_index_net_id != net_id
		)
	):
		var previous_index := combat_target_index_binding
		var previous_net_id := combat_target_index_net_id
		previous_index.unregister_enemy(previous_net_id, self)
	combat_target_index_binding = index
	combat_target_index_net_id = net_id
	var safe_bucket_size := maxf(index.bucket_size, 1.0)
	var initial_bucket := Vector2i(
		floori(global_position.x / safe_bucket_size),
		floori(global_position.y / safe_bucket_size)
	)
	_cache_combat_target_index_bucket(initial_bucket, safe_bucket_size)
	# Enemies live under a stationary gameplay container. Local notifications are
	# synchronous for move_and_slide(), direct movement and snapshot teleports;
	# enabling global notifications as well would dispatch this hot callback twice
	# for every ordinary move. The bounded round-robin repair audit covers an
	# unexpected ancestor transform change without a full-cohort scan.
	set_notify_local_transform(true)


func sync_combat_target_index_bucket(
	index: CombatTargetIndex,
	net_id: int,
	bucket: Vector2i,
	bucket_size: float
) -> void:
	if (
		combat_target_index_binding != index
		or combat_target_index_net_id != net_id
	):
		return
	_cache_combat_target_index_bucket(bucket, bucket_size)


func unbind_combat_target_index(index: CombatTargetIndex, net_id: int) -> void:
	if (
		combat_target_index_binding != index
		or combat_target_index_net_id != net_id
	):
		return
	combat_target_index_binding = null
	combat_target_index_net_id = 0
	combat_target_index_bucket = Vector2i.MAX
	combat_target_index_bucket_size = 0.0
	combat_target_index_bucket_minimum = Vector2.ZERO
	combat_target_index_bucket_maximum = Vector2.ZERO
	set_notify_local_transform(false)


func _cache_combat_target_index_bucket(
	bucket: Vector2i,
	bucket_size: float
) -> void:
	var safe_bucket_size := maxf(bucket_size, 1.0)
	combat_target_index_bucket = bucket
	combat_target_index_bucket_size = safe_bucket_size
	combat_target_index_bucket_minimum = Vector2(bucket) * safe_bucket_size
	combat_target_index_bucket_maximum = (
		combat_target_index_bucket_minimum + Vector2.ONE * safe_bucket_size
	)


func _apply_terrain_collision_profile() -> void:
	var can_traverse_water := (
		terrain_traversal_types & DualGridTilemap.TraversalType.WATER
	) != 0
	if can_traverse_water:
		collision_mask &= ~WATER_TERRAIN_COLLISION_LAYER
	else:
		collision_mask |= WATER_TERRAIN_COLLISION_LAYER


func _process(delta: float) -> void:
	var metrics_started_usec := Time.get_ticks_usec() if Enemy.performance_metrics_enabled else 0
	if not _status_requires_render_process():
		# This also makes a runtime A/B switch converge without waiting for another
		# modifier mutation to call _refresh_status_process_enabled().
		set_process(false)
		if Enemy.performance_metrics_enabled:
			Enemy._record_performance_metric(
				"status_process_calls",
				"status_process_usec",
				metrics_started_usec
			)
		return
	_update_collectible_status_effects(delta)
	_update_movement_status_visuals()
	if Enemy.performance_metrics_enabled:
		Enemy._record_performance_metric(
			"status_process_calls",
			"status_process_usec",
			metrics_started_usec
		)


func _status_requires_render_process() -> bool:
	if not collectible_status_effects.is_empty():
		return true
	if not Enemy.slow_only_status_process_optimization_enabled:
		return not move_speed_modifiers.is_empty()
	# Slow overlays are static instance-shader parameters and are refreshed at
	# modifier add/remove time. Only haste needs render-frame work to follow the
	# enemy velocity and acquire/release its pooled trail while movement changes.
	return _has_move_speed_modifier_above_default()


func _refresh_status_process_enabled() -> void:
	if is_dead:
		set_process(false)
		return
	if is_multiplayer_proxy:
		return
	set_process(_status_requires_render_process())


func setup(enemy_config: EnemyConfig, player: Player, shared_pathfinder: Node = null) -> void:
	clear_cold_status()
	config = enemy_config
	target_player = player
	objective_target = player
	pathfinder = shared_pathfinder
	_refresh_projectile_motion_system()
	navigation_agent_profile = null
	navigation_flow_prefetch_next_physics_frame = 0
	last_navigation_update_render_frame = -1
	last_navigation_refresh_process_frame = -1
	navigation_refresh_deferred = false
	_invalidate_blocked_world_los_cache()
	_invalidate_ranged_combat_line_cache()
	_reset_ranged_attack_position_state()
	near_moving_target_direct_distance = DEFAULT_NEAR_MOVING_TARGET_DIRECT_DISTANCE
	near_moving_target_direct_distance_squared = (
		DEFAULT_NEAR_MOVING_TARGET_DIRECT_DISTANCE_SQUARED
	)
	if navigation_flow_context != null:
		navigation_flow_context.invalidate()
	_apply_config()


func set_target_player(player: Player) -> void:
	if target_player == player:
		if objective_target == null:
			objective_target = player
			_invalidate_ranged_combat_line_cache()
			_reset_ranged_attack_position_state()
			_clear_cached_navigation_move_direction()
		return

	var previous_target := target_player
	target_player = player
	navigation_flow_prefetch_next_physics_frame = 0
	_invalidate_blocked_world_los_cache()
	_invalidate_ranged_combat_line_cache()
	_reset_ranged_attack_position_state()
	if objective_target == null or objective_target == previous_target:
		objective_target = player
		_clear_cached_navigation_move_direction()


func set_objective_target(target: Node2D) -> void:
	if objective_target == target:
		return
	objective_target = target
	_invalidate_blocked_world_los_cache()
	_invalidate_ranged_combat_line_cache()
	_reset_ranged_attack_position_state()
	_clear_cached_navigation_move_direction()


func set_near_moving_target_direct_distance(distance: float) -> void:
	var normalized_distance := maxf(distance, 0.0)
	if is_equal_approx(near_moving_target_direct_distance, normalized_distance):
		return
	near_moving_target_direct_distance = normalized_distance
	near_moving_target_direct_distance_squared = normalized_distance * normalized_distance
	_clear_cached_navigation_move_direction()


func is_objective_targeting_player() -> bool:
	return (
		objective_target != null
		and is_instance_valid(objective_target)
		and target_player != null
		and is_instance_valid(target_player)
		and objective_target == target_player
	)


func get_attackable_objective() -> Node2D:
	if objective_target == null or not is_instance_valid(objective_target):
		return null
	var player_objective := objective_target as Player
	if player_objective != null:
		return null if player_objective.is_dead else player_objective
	var plant_objective := objective_target as PlantDefense
	if plant_objective != null:
		return null if plant_objective.is_dead or plant_objective.is_removing else plant_objective
	# Home gates and other navigation-only objectives must never become combat
	# targets merely because they are Node2D instances.
	return null


func has_attackable_objective() -> bool:
	return get_attackable_objective() != null


## Land-only melee enemies must not navigate toward water buildings they cannot
## reach. Amphibious enemies can still use them as objectives; ranged enemy
## families override this capability because they can attack from the shore.
func can_target_water_plant_objectives() -> bool:
	return (
		terrain_traversal_types & DualGridTilemap.TraversalType.WATER
	) != 0


func is_attackable_objective_in_range(attack_range: float) -> bool:
	var attack_target := get_attackable_objective()
	return (
		attack_target != null
		and global_position.distance_squared_to(attack_target.global_position)
			<= maxf(attack_range, 0.0) * maxf(attack_range, 0.0)
	)


func _get_preferred_ranged_combat_target() -> Node2D:
	# Tower-defense navigation may point at a Home gate which is deliberately not
	# damageable. Ranged enemies opt into this combat target without replacing
	# their navigation objective: a live plant/player objective wins, otherwise
	# the live session player remains a valid ranged target.
	var attackable_objective := get_attackable_objective()
	if attackable_objective != null:
		return attackable_objective
	if (
		target_player != null
		and is_instance_valid(target_player)
		and not target_player.is_dead
	):
		return target_player
	return null


func _is_ranged_combat_target_in_range(
	target: Node2D,
	attack_range: float
) -> bool:
	if not _is_ranged_combat_target_valid(target):
		return false
	var safe_attack_range := maxf(attack_range, 0.0)
	return (
		global_position.distance_squared_to(target.global_position)
		<= safe_attack_range * safe_attack_range
	)


func _is_ranged_combat_target_valid(target: Node2D) -> bool:
	return _is_live_ranged_combat_target(target)


func _has_ranged_combat_line(
	target: Node2D,
	collision_mask_value: int = 1,
	force_refresh: bool = false
) -> bool:
	if not _is_live_ranged_combat_target(target):
		_invalidate_ranged_combat_line_cache()
		return false

	var physics_frame := Engine.get_physics_frames()
	var target_position := target.global_position
	var navigation_generation := _get_current_navigation_generation()
	var cache_is_current := (
		_ranged_combat_los_has_result
		and _ranged_combat_los_target_instance_id == target.get_instance_id()
		and _ranged_combat_los_collision_mask == collision_mask_value
		and _ranged_combat_los_navigation_generation == navigation_generation
		and global_position.distance_squared_to(_ranged_combat_los_source_position)
			< RANGED_COMBAT_LOS_MOTION_INVALIDATION_DISTANCE_SQUARED
		and target_position.distance_squared_to(_ranged_combat_los_target_position)
			< RANGED_COMBAT_LOS_MOTION_INVALIDATION_DISTANCE_SQUARED
	)
	if (
		not force_refresh
		and cache_is_current
		and (
			physics_frame < _ranged_combat_los_next_query_physics_frame
			or physics_frame == _ranged_combat_los_last_query_physics_frame
		)
	):
		return _ranged_combat_los_result
	if (
		not force_refresh
		and (
			physics_frame + navigation_update_frame_offset
		) % RANGED_COMBAT_LOS_REFRESH_INTERVAL_PHYSICS_FRAMES != 0
	):
		# A stale clear result must never hold an enemy after either endpoint has
		# moved eight pixels, the target changed, or navigation was rebuilt.
		return _ranged_combat_los_result if cache_is_current else false

	var started_usec := Time.get_ticks_usec() if Enemy.performance_metrics_enabled else 0
	var has_clear_line := _is_world_segment_clear(
		target_position,
		collision_mask_value
	)
	if Enemy.performance_metrics_enabled:
		Enemy._record_performance_metric(
			"ranged_los_calls",
			"ranged_los_usec",
			started_usec
		)
	_seed_ranged_combat_line_cache(
		target,
		target_position,
		collision_mask_value,
		navigation_generation,
		has_clear_line,
		physics_frame
	)
	return has_clear_line


func _try_hold_ranged_attack_position(
	target: Node2D,
	attack_range: float,
	collision_mask_value: int = 1
) -> bool:
	var should_hold := (
		_is_ranged_combat_target_in_range(target, attack_range)
		and _has_ranged_combat_line(target, collision_mask_value)
	)
	_set_ranged_attack_position_held(should_hold)
	if should_hold:
		velocity = Vector2.ZERO
	return should_hold


func _reset_ranged_attack_position_state() -> void:
	_set_ranged_attack_position_held(false)


func get_locomotion_state() -> int:
	# Locomotion is a discrete simulation fact, not a velocity-magnitude bucket.
	# In particular, a very slow authoritative velocity may quantize to zero on
	# the wire while the enemy continues to advance over successive snapshots.
	if is_dead:
		return LocomotionState.IDLE
	if is_multiplayer_proxy:
		return multiplayer_proxy_locomotion_state
	if _ranged_attack_position_held or velocity.is_zero_approx():
		return LocomotionState.IDLE
	return LocomotionState.MOVING


func _normalize_locomotion_state(state: int) -> int:
	return (
		LocomotionState.MOVING
		if state == LocomotionState.MOVING
		else LocomotionState.IDLE
	)


func _is_live_ranged_combat_target(target: Node2D) -> bool:
	if target == null or not is_instance_valid(target):
		return false
	var player_target := target as Player
	if player_target != null:
		return not player_target.is_dead
	var plant_target := target as PlantDefense
	if plant_target != null:
		return not plant_target.is_dead and not plant_target.is_removing
	return false


func _set_ranged_attack_position_held(held: bool) -> void:
	if _ranged_attack_position_held == held:
		return
	_ranged_attack_position_held = held
	_sync_move_animation_playback()
	# Entering discards a now-unneeded route; exiting discards the cached zero so
	# the next movement tick can immediately reacquire a route. No per-frame path
	# invalidation occurs while a ranged cohort is standing through cooldown.
	_clear_navigation_path()


func set_pathfinder(shared_pathfinder: Node) -> void:
	if pathfinder == shared_pathfinder:
		return
	pathfinder = shared_pathfinder
	_refresh_projectile_motion_system()
	navigation_agent_profile = null
	navigation_flow_prefetch_next_physics_frame = 0
	_invalidate_ranged_combat_line_cache()
	_reset_ranged_attack_position_state()
	_clear_cached_navigation_move_direction()


func configure_multiplayer_proxy() -> void:
	clear_cold_status()
	is_multiplayer_proxy = true
	multiplayer_proxy_locomotion_state = LocomotionState.IDLE
	# Proxy transforms are already interpolated from network snapshots during
	# render updates. Native physics interpolation here would apply a second,
	# mismatched timeline to the same visual transform.
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	reset_physics_interpolation()
	target_player = null
	objective_target = null
	pathfinder = null
	_invalidate_ranged_combat_line_cache()
	_reset_ranged_attack_position_state()
	projectile_motion_system = null
	touched_player = null
	touching_players.clear()
	touched_plant = null
	touching_plants.clear()
	touching_plant_entry_distances.clear()
	touch_damage_cooldown_left = 0.0
	proxy_action_animation_name_in_use = &""
	_update_movement_status_visuals()
	set_physics_process(false)
	set_process(false)
	collision_layer = 4
	collision_mask = 0
	_disable_proxy_area_collisions(self)
	_ensure_multiplayer_proxy_move_animation()


func _refresh_projectile_motion_system() -> void:
	projectile_motion_system = null
	if pathfinder == null:
		return
	var runtime := pathfinder.get_parent() as GameRuntimeBase
	if runtime != null:
		projectile_motion_system = runtime.capoo_projectile_motion_system


func remove_for_home_escape() -> bool:
	if is_dead:
		return false
	is_dead = true
	clear_cold_status()
	velocity = Vector2.ZERO
	set_process(false)
	set_physics_process(false)
	touched_player = null
	touching_players.clear()
	touched_plant = null
	touching_plants.clear()
	touching_plant_entry_distances.clear()
	objective_target = null
	proxy_action_animation_name_in_use = &""
	proxy_action_restore_token += 1
	_set_collision_shapes_disabled(body_collision_shapes, true)
	_set_collision_shapes_disabled(touch_damage_shapes, true)
	if touch_damage_area != null:
		touch_damage_area.set_deferred("monitoring", false)
		touch_damage_area.set_deferred("monitorable", false)
	_release_speed_trail_effect()
	visible = false
	queue_free()
	return true


func apply_multiplayer_proxy_motion(
	proxy_position: Vector2,
	proxy_velocity: Vector2,
	proxy_locomotion_state: int
) -> void:
	global_position = proxy_position
	velocity = proxy_velocity
	multiplayer_proxy_locomotion_state = _normalize_locomotion_state(
		proxy_locomotion_state
	)
	if (
		proxy_action_animation_name_in_use == &""
		and multiplayer_proxy_locomotion_state == LocomotionState.MOVING
	):
		_set_facing_from_direction(proxy_velocity)
	_ensure_multiplayer_proxy_move_animation()


func _disable_proxy_area_collisions(root: Node) -> void:
	for child in root.get_children():
		var area: Area2D = child as Area2D
		if area != null:
			area.monitoring = false
			area.monitorable = false
			area.collision_layer = 0
			area.collision_mask = 0
		_disable_proxy_area_collisions(child)


func apply_damage(
	amount: int,
	impact_direction: Vector2 = Vector2.ZERO,
	damage_type: EnemyConfig.DamageType = EnemyConfig.DamageType.PHYSICAL,
	show_hit_particles: bool = true
) -> bool:
	last_damage_taken = 0
	if is_dead:
		return false
	if amount <= 0:
		return false

	var final_damage := _calculate_incoming_damage(amount, damage_type)
	last_damage_taken = final_damage
	current_health -= final_damage
	show_damage_number(final_damage, impact_direction, damage_type)
	play_multiplayer_damage_feedback(impact_direction, show_hit_particles)

	if current_health <= 0:
		_die()
		return true

	AUDIO_LIMITER.play_enemy_hit(hit_audio)
	return true


func apply_damage_batch(
	damage_amounts: PackedInt32Array,
	hit_counts: PackedInt32Array,
	impact_direction: Vector2 = Vector2.ZERO,
	damage_type: EnemyConfig.DamageType = EnemyConfig.DamageType.PHYSICAL,
	show_hit_particles: bool = true
) -> bool:
	last_damage_taken = 0
	if is_dead or damage_amounts.is_empty():
		return false
	var damage_group_count := mini(
		damage_amounts.size(),
		hit_counts.size()
	)
	if damage_group_count <= 0:
		return false

	# Each group's mitigation is calculated for one hit before multiplication.
	# Physical/magic defense, damage multipliers and the one-point minimum stay
	# identical to repeated hits. The lethal aggregate is capped to remaining
	# health so merged damage groups cannot produce order-dependent overkill
	# health or multiplayer damage numbers.
	var accumulated_damage := 0
	for group_index in range(damage_group_count):
		var raw_damage := damage_amounts[group_index]
		var requested_hit_count := hit_counts[group_index]
		if raw_damage <= 0 or requested_hit_count <= 0:
			continue
		var damage_per_hit := _calculate_incoming_damage(
			raw_damage,
			damage_type
		)
		var remaining_health := current_health - accumulated_damage
		if remaining_health <= 0:
			break
		var hits_until_lethal := ceili(
			float(remaining_health) / float(damage_per_hit)
		)
		var accepted_hit_count := mini(
			requested_hit_count,
			hits_until_lethal
		)
		accumulated_damage += mini(
			damage_per_hit * accepted_hit_count,
			remaining_health
		)
		if accumulated_damage >= current_health:
			break
	if accumulated_damage <= 0:
		return false

	last_damage_taken = accumulated_damage
	current_health -= accumulated_damage
	show_damage_number(
		accumulated_damage,
		impact_direction,
		damage_type
	)
	play_multiplayer_damage_feedback(
		impact_direction,
		show_hit_particles
	)

	if current_health <= 0:
		_die()
		return true

	AUDIO_LIMITER.play_enemy_hit(hit_audio)
	return true


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
			damage_number_owner.call("show_damage_number", amount, global_position, impact_direction, damage_type)
			return
		damage_number_owner = damage_number_owner.get_parent()


func play_multiplayer_damage_feedback(
	impact_direction: Vector2 = Vector2.ZERO,
	show_hit_particles: bool = true
) -> void:
	if show_hit_particles:
		_play_hit_particles(impact_direction)


func play_multiplayer_death_sequence() -> void:
	if is_dead:
		return

	is_dead = true
	clear_cold_status()
	velocity = Vector2.ZERO
	_update_movement_status_visuals()
	set_process(false)
	set_physics_process(false)
	touched_player = null
	touching_players.clear()
	touched_plant = null
	touching_plants.clear()
	touching_plant_entry_distances.clear()
	proxy_action_animation_name_in_use = &""
	proxy_action_restore_token += 1
	_set_collision_shapes_disabled(body_collision_shapes, true)
	_set_collision_shapes_disabled(touch_damage_shapes, true)
	if touch_damage_area != null:
		touch_damage_area.set_deferred("monitoring", false)
		touch_damage_area.set_deferred("monitorable", false)
	if death_audio != null:
		AUDIO_LIMITER.play_enemy_death(death_audio)
	_start_death_sequence()

func add_physical_defense_modifier(source_id: int, amount: int) -> void:
	if source_id == 0:
		return
	if amount == 0:
		return
	var previous_amount := int(physical_defense_modifiers.get(source_id, 0))
	if previous_amount == amount:
		return

	physical_defense_modifiers[source_id] = amount
	physical_defense_modifier_total += amount - previous_amount
	_refresh_effective_physical_defense_cache()


func remove_physical_defense_modifier(source_id: int) -> void:
	if not physical_defense_modifiers.has(source_id):
		return
	physical_defense_modifier_total -= int(physical_defense_modifiers[source_id])
	physical_defense_modifiers.erase(source_id)
	_refresh_effective_physical_defense_cache()


func get_effective_physical_defense() -> int:
	return cached_effective_physical_defense


func _refresh_effective_physical_defense_cache() -> void:
	var base_defense := config.physical_defense if config != null else 0
	cached_effective_physical_defense = maxi(
		base_defense + physical_defense_modifier_total,
		0
	)


func get_effective_magic_defense() -> int:
	return clampi(config.magic_defense if config != null else 0, 0, 100)


func add_damage_taken_multiplier_modifier(source_id: int, multiplier: float) -> void:
	if source_id == 0:
		return
	if multiplier <= 0.0 or is_equal_approx(multiplier, 1.0):
		return
	damage_taken_multiplier_modifiers[source_id] = multiplier


func remove_damage_taken_multiplier_modifier(source_id: int) -> void:
	damage_taken_multiplier_modifiers.erase(source_id)


func get_damage_taken_multiplier() -> float:
	var total := 1.0
	for source_id in damage_taken_multiplier_modifiers:
		total *= maxf(float(damage_taken_multiplier_modifiers[source_id]), 0.0)
	return maxf(total, 0.0)


func apply_cold_status() -> bool:
	if is_dead or is_multiplayer_proxy or not is_inside_tree():
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
	if safe_stack_count <= 0:
		if (
			cold_stack_count == 0
			and not move_speed_modifiers.has(COLD_MOVE_SPEED_SOURCE_ID)
		):
			return
		cold_stack_count = 0
		remove_move_speed_modifier(COLD_MOVE_SPEED_SOURCE_ID)
		return
	var safe_multiplier := clampf(multiplier, 0.0, 1.0)
	if (
		cold_stack_count == safe_stack_count
		and move_speed_modifiers.has(COLD_MOVE_SPEED_SOURCE_ID)
		and is_equal_approx(
			float(move_speed_modifiers[COLD_MOVE_SPEED_SOURCE_ID]),
			safe_multiplier
		)
	):
		return
	cold_stack_count = safe_stack_count
	add_move_speed_modifier(COLD_MOVE_SPEED_SOURCE_ID, safe_multiplier)


func add_move_speed_modifier(source_id: int, multiplier: float) -> void:
	if source_id == 0:
		return
	move_speed_modifiers[source_id] = maxf(multiplier, 0.0)
	_refresh_effective_move_speed_cache()
	_clear_cached_navigation_move_direction()
	_update_movement_status_visuals()
	_refresh_status_process_enabled()


func remove_move_speed_modifier(source_id: int) -> void:
	if not move_speed_modifiers.has(source_id):
		return
	move_speed_modifiers.erase(source_id)
	_refresh_effective_move_speed_cache()
	_clear_cached_navigation_move_direction()
	_update_movement_status_visuals()
	_refresh_status_process_enabled()


func get_effective_move_speed() -> float:
	return cached_effective_move_speed


func get_effective_move_speed_multiplier() -> float:
	return cached_effective_move_speed_multiplier


func _refresh_effective_move_speed_cache() -> void:
	var total_multiplier := 1.0
	for source_id in move_speed_modifiers:
		total_multiplier *= maxf(float(move_speed_modifiers[source_id]), 0.0)
	cached_effective_move_speed_multiplier = maxf(total_multiplier, 0.0)
	var base_move_speed := config.move_speed if config != null else 0.0
	cached_effective_move_speed = maxf(
		base_move_speed * cached_effective_move_speed_multiplier,
		0.0
	)


func _update_movement_status_visuals() -> void:
	if is_dead:
		_set_slow_overlay_strength(0.0)
		_set_burn_overlay_strength(0.0)
		_set_bleed_overlay_strength(0.0)
		_release_speed_trail_effect()
		return

	var is_slowed := _has_move_speed_modifier_below_default()
	_set_slow_overlay_strength(SLOW_OVERLAY_ACTIVE_STRENGTH if is_slowed else 0.0)
	_set_burn_overlay_strength(BURN_OVERLAY_ACTIVE_STRENGTH if _has_collectible_status(&"burn") else 0.0)
	_set_bleed_overlay_strength(BLEED_OVERLAY_ACTIVE_STRENGTH if _has_collectible_status(&"bleed") else 0.0)

	var is_temporarily_hasted := _has_move_speed_modifier_above_default()
	var is_moving := velocity.length_squared() > 0.001
	if not is_temporarily_hasted or not is_moving:
		_release_speed_trail_effect()
		return

	var acquired_new_lease := false
	if speed_trail_effect == null or not is_instance_valid(speed_trail_effect):
		speed_trail_effect = _acquire_speed_trail_effect()
		acquired_new_lease = speed_trail_effect != null
	if speed_trail_effect == null:
		return
	if acquired_new_lease:
		# 2D interpolation is inherited through local parent transforms. Temporarily
		# parent the pooled effect to the enemy so its emitter follows the same
		# interpolated timeline as the sprite instead of stepping as a pool sibling.
		speed_trail_effect.reparent(self, false)
		speed_trail_effect.position = Vector2.ZERO
		speed_trail_effect.rotation = 0.0
		speed_trail_effect.scale = Vector2.ONE
		speed_trail_effect.reset_physics_interpolation()
	speed_trail_effect.call("set_motion_direction", velocity)
	speed_trail_effect.call("set_effect_active", true)


func _acquire_speed_trail_effect() -> Node2D:
	var ancestor := get_parent()
	while ancestor != null:
		var pool := ancestor.get_node_or_null("SessionObjectPool") as SessionObjectPool
		if pool != null and pool.is_registered(MOVE_SPEED_TRAIL_EFFECT_SCENE):
			var effect := pool.acquire(MOVE_SPEED_TRAIL_EFFECT_SCENE) as Node2D
			if effect != null:
				speed_trail_owner_pool = pool
			return effect
		ancestor = ancestor.get_parent()
	return null


func _release_speed_trail_effect() -> void:
	if speed_trail_effect == null:
		return
	if is_instance_valid(speed_trail_effect):
		speed_trail_effect.call("set_effect_active", false)
		if (
			speed_trail_owner_pool != null
			and is_instance_valid(speed_trail_owner_pool)
			and speed_trail_owner_pool.is_inside_tree()
			and speed_trail_effect.get_parent() != speed_trail_owner_pool
		):
			speed_trail_effect.reparent(speed_trail_owner_pool, true)
		SessionObjectPool.release_to_owner(speed_trail_effect)
	speed_trail_effect = null
	speed_trail_owner_pool = null


func _exit_tree() -> void:
	clear_cold_status()
	if combat_target_index_binding != null and combat_target_index_net_id > 0:
		var bound_index := combat_target_index_binding
		var bound_net_id := combat_target_index_net_id
		bound_index.unregister_enemy(bound_net_id, self)
	_release_speed_trail_effect()


func _has_move_speed_modifier_below_default() -> bool:
	for source_id in move_speed_modifiers:
		if float(move_speed_modifiers[source_id]) < 1.0:
			return true
	return false


func _has_move_speed_modifier_above_default() -> bool:
	for source_id in move_speed_modifiers:
		if float(move_speed_modifiers[source_id]) > 1.0:
			return true
	return false


func _set_slow_overlay_strength(strength: float) -> void:
	_set_visual_shader_parameter(
		SLOW_OVERLAY_STRENGTH_SHADER_PARAMETER,
		clampf(strength, 0.0, 1.0)
	)


func _set_burn_overlay_strength(strength: float) -> void:
	_set_visual_shader_parameter(
		BURN_OVERLAY_STRENGTH_SHADER_PARAMETER,
		clampf(strength, 0.0, 1.0)
	)


func _set_bleed_overlay_strength(strength: float) -> void:
	_set_visual_shader_parameter(
		BLEED_OVERLAY_STRENGTH_SHADER_PARAMETER,
		clampf(strength, 0.0, 1.0)
	)


func _has_collectible_status(status_id: StringName) -> bool:
	for effect_key in collectible_status_effects:
		var status_data := collectible_status_effects[effect_key] as Dictionary
		if status_data.is_empty():
			continue
		if (
			StringName(status_data.get("status_id", &"")) == status_id
			and float(status_data.get("time_left", 0.0)) > 0.0
		):
			return true
	return false


func has_collectible_status(status_id: StringName) -> bool:
	return _has_collectible_status(status_id)


func get_collectible_visual_status_mask() -> int:
	var result := 0
	if _has_collectible_status(&"burn"):
		result |= 1
	if _has_collectible_status(&"bleed"):
		result |= 2
	if cold_stack_count > 0 or _has_collectible_status(&"chill"):
		result |= 4
	if _has_collectible_status(&"mark"):
		result |= 8
	return result


func apply_multiplayer_visual_status_mask(status_mask: int) -> void:
	if not is_multiplayer_proxy:
		return
	var safe_mask := status_mask & 0x0f
	var added_mask := safe_mask & ~network_visual_status_mask
	network_visual_status_mask = safe_mask
	_set_visual_shader_parameter(
		SLOW_OVERLAY_STRENGTH_SHADER_PARAMETER,
		0.6 if (safe_mask & 4) != 0 else 0.0
	)
	_set_visual_shader_parameter(
		BURN_OVERLAY_STRENGTH_SHADER_PARAMETER,
		0.72 if (safe_mask & 1) != 0 else 0.0
	)
	_set_visual_shader_parameter(
		BLEED_OVERLAY_STRENGTH_SHADER_PARAMETER,
		0.7 if (safe_mask & 2) != 0 else 0.0
	)
	if (added_mask & 8) != 0:
		_play_collectible_status_feedback(&"mark")


func set_multiplayer_proxy_visual_active(active: bool) -> void:
	if not is_multiplayer_proxy or multiplayer_proxy_visual_active == active:
		return
	multiplayer_proxy_visual_active = active
	if animated_sprite != null:
		animated_sprite.speed_scale = (
			multiplayer_proxy_authored_animation_speed if active else 0.0
		)
	for child in find_children("", "GPUParticles2D", true, false):
		var particles := child as GPUParticles2D
		if particles != null:
			particles.process_mode = (
				Node.PROCESS_MODE_INHERIT if active else Node.PROCESS_MODE_DISABLED
			)


func _set_visual_shader_parameter(parameter_name: StringName, value: Variant) -> void:
	if animated_sprite == null or status_visual_material == null:
		return
	var strength := clampf(float(value), 0.0, 1.0)
	match parameter_name:
		SLOW_OVERLAY_STRENGTH_SHADER_PARAMETER:
			slow_overlay_strength = strength
		BURN_OVERLAY_STRENGTH_SHADER_PARAMETER:
			burn_overlay_strength = strength
		BLEED_OVERLAY_STRENGTH_SHADER_PARAMETER:
			bleed_overlay_strength = strength
		_:
			if animated_sprite.material == null:
				animated_sprite.material = status_visual_material
			animated_sprite.set_instance_shader_parameter(parameter_name, value)
			return

	var has_status_overlay := (
		slow_overlay_strength > 0.0
		or burn_overlay_strength > 0.0
		or bleed_overlay_strength > 0.0
	)
	if has_status_overlay and animated_sprite.material == null:
		animated_sprite.material = status_visual_material
	if animated_sprite.material != null:
		animated_sprite.set_instance_shader_parameter(parameter_name, strength)
	if not has_status_overlay:
		animated_sprite.material = null


func _calculate_incoming_damage(
	amount: int,
	damage_type: EnemyConfig.DamageType
) -> int:
	var mitigated_damage := 1
	match damage_type:
		EnemyConfig.DamageType.MAGIC:
			var defense_ratio := float(100 - get_effective_magic_defense()) / 100.0
			mitigated_damage = maxi(floori(float(amount) * defense_ratio), 1)
		_:
			mitigated_damage = maxi(amount - get_effective_physical_defense(), 1)
	return maxi(roundi(float(mitigated_damage) * get_damage_taken_multiplier()), 1)


func apply_collectible_status(
	status_id: StringName,
	source_id: int,
	duration: float,
	tick_damage: int = 0,
	tick_interval: float = 0.5,
	damage_type: EnemyConfig.DamageType = EnemyConfig.DamageType.MAGIC,
	slow_multiplier: float = 1.0,
	physical_defense_modifier: int = 0,
	damage_taken_multiplier: float = 1.0
) -> void:
	if is_dead or source_id == 0 or status_id == &"":
		return
	var normalized_duration := maxf(duration, 0.05)
	var normalized_tick_interval := maxf(tick_interval, 0.1)
	if status_id == &"burn":
		normalized_tick_interval = BURN_STATUS_TICK_INTERVAL
	var effect_key := "%s:%s" % [source_id, status_id]
	var status := {
		"status_id": status_id,
		"source_id": source_id,
		"time_left": normalized_duration,
		"tick_damage": maxi(tick_damage, 0),
		"tick_interval": normalized_tick_interval,
		"tick_time_left": normalized_tick_interval,
		"damage_type": int(damage_type),
		"slow_source_id": 0,
		"physical_defense_source_id": 0,
		"damage_multiplier_source_id": 0,
	}
	if slow_multiplier < 1.0:
		var slow_source_id := source_id + absi(String(status_id).hash()) % 100000
		status["slow_source_id"] = slow_source_id
		add_move_speed_modifier(slow_source_id, slow_multiplier)
	if physical_defense_modifier != 0:
		var defense_source_id := source_id + 200000 + absi(String(status_id).hash()) % 100000
		status["physical_defense_source_id"] = defense_source_id
		add_physical_defense_modifier(defense_source_id, physical_defense_modifier)
	if not is_equal_approx(damage_taken_multiplier, 1.0):
		var multiplier_source_id := source_id + 400000 + absi(String(status_id).hash()) % 100000
		status["damage_multiplier_source_id"] = multiplier_source_id
		add_damage_taken_multiplier_modifier(multiplier_source_id, damage_taken_multiplier)
	collectible_status_effects[effect_key] = status
	_play_collectible_status_feedback(status_id)
	_refresh_status_process_enabled()


func _update_collectible_status_effects(delta: float) -> void:
	if collectible_status_effects.is_empty():
		return
	stale_collectible_status_keys.clear()
	active_collectible_status_keys.clear()
	# Resolve every expiry before any tick damage. This makes the boundary frame
	# independent of Dictionary insertion order: an expiring armor break or mark
	# cannot still modify another status whose tick is due in the same frame.
	for effect_key in collectible_status_effects:
		var status: Dictionary = collectible_status_effects.get(effect_key, {})
		if status.is_empty():
			stale_collectible_status_keys.append(effect_key)
			continue
		var time_left := float(status.get("time_left", 0.0)) - delta
		if time_left <= 0.0 or is_dead:
			stale_collectible_status_keys.append(effect_key)
			continue
		status["time_left"] = time_left
		collectible_status_effects[effect_key] = status
		active_collectible_status_keys.append(effect_key)
	for effect_key in stale_collectible_status_keys:
		var stale_status := collectible_status_effects.get(effect_key, {}) as Dictionary
		if stale_status.is_empty():
			collectible_status_effects.erase(effect_key)
			continue
		_remove_collectible_status(effect_key, stale_status)
	if active_collectible_status_keys.is_empty() or is_dead:
		return

	var active_burn_damage_key: Variant = _get_highest_damage_status_key(&"burn")
	for effect_key in active_collectible_status_keys:
		var status := collectible_status_effects.get(effect_key, {}) as Dictionary
		if status.is_empty():
			continue
		var tick_damage := int(status.get("tick_damage", 0))
		if tick_damage > 0:
			if StringName(status.get("status_id", &"")) == &"burn" and effect_key != active_burn_damage_key:
				collectible_status_effects[effect_key] = status
				continue
			var tick_time_left := float(status.get("tick_time_left", 0.1)) - delta
			while tick_time_left <= 0.0 and tick_damage > 0 and not is_dead:
				tick_time_left += float(status.get("tick_interval", 0.5))
				var tick_damage_type := EnemyConfig.DamageType.MAGIC
				if int(status.get("damage_type", EnemyConfig.DamageType.MAGIC)) == int(EnemyConfig.DamageType.PHYSICAL):
					tick_damage_type = EnemyConfig.DamageType.PHYSICAL
				apply_damage(
					tick_damage,
					Vector2.ZERO,
					tick_damage_type
				)
			status["tick_time_left"] = tick_time_left
		collectible_status_effects[effect_key] = status


func _get_highest_damage_status_key(status_id: StringName) -> Variant:
	var strongest_key: Variant = null
	var strongest_damage := -1
	for effect_key in collectible_status_effects:
		var status: Dictionary = collectible_status_effects.get(effect_key, {})
		if status.is_empty():
			continue
		if StringName(status.get("status_id", &"")) != status_id:
			continue
		if float(status.get("time_left", 0.0)) <= 0.0:
			continue
		var tick_damage := int(status.get("tick_damage", 0))
		if tick_damage > strongest_damage:
			strongest_damage = tick_damage
			strongest_key = effect_key
	return strongest_key


func _remove_collectible_status(effect_key: Variant, status: Dictionary) -> void:
	var slow_source_id := int(status.get("slow_source_id", 0))
	if slow_source_id != 0:
		remove_move_speed_modifier(slow_source_id)
	var defense_source_id := int(status.get("physical_defense_source_id", 0))
	if defense_source_id != 0:
		remove_physical_defense_modifier(defense_source_id)
	var multiplier_source_id := int(status.get("damage_multiplier_source_id", 0))
	if multiplier_source_id != 0:
		remove_damage_taken_multiplier_modifier(multiplier_source_id)
	collectible_status_effects.erase(effect_key)
	_refresh_status_process_enabled()


func _play_collectible_status_feedback(status_id: StringName) -> void:
	if animated_sprite == null:
		return
	var flash_color := Color(1.0, 1.0, 1.0, 1.0)
	match status_id:
		&"burn":
			flash_color = Color(1.45, 0.7, 0.34, 1.0)
		&"bleed":
			flash_color = Color(1.35, 0.22, 0.25, 1.0)
		&"chill":
			flash_color = Color(0.65, 0.95, 1.35, 1.0)
		&"mark":
			flash_color = Color(1.2, 0.8, 1.6, 1.0)
		&"crack":
			flash_color = Color(1.35, 1.22, 0.72, 1.0)
	if collectible_status_tween != null:
		collectible_status_tween.kill()
	collectible_status_tween = create_tween()
	animated_sprite.modulate = flash_color
	collectible_status_tween.tween_property(animated_sprite, "modulate", Color.WHITE, 0.24)


func _apply_config() -> void:
	if config == null:
		cached_effective_physical_defense = 0
		cached_effective_move_speed = 0.0
		return

	terrain_traversal_types = config.terrain_traversal_types
	navigation_agent_profile = null
	_apply_terrain_collision_profile()
	current_health = config.max_health
	_refresh_effective_physical_defense_cache()
	_refresh_effective_move_speed_cache()
	_play_scene_animation(config.move_animation_name)


func _play_scene_animation(animation_name: StringName) -> bool:
	if not _has_scene_animation(animation_name):
		return false
	animated_sprite.play(animation_name)
	# Ranged enemies can restore their move animation while deliberately holding
	# an attack position (for example, immediately after a windup/attack finishes).
	# Apply the standing pose at that transition instead of polling every frame.
	# Multiplayer proxies use the same path after action restoration, with their
	# delayed discrete locomotion state deciding whether the walk cycle is active.
	if config != null and animation_name == config.move_animation_name:
		_sync_move_animation_playback()
	return true


func _play_multiplayer_proxy_action_animation(
	animation_name: StringName,
	restore_delay: float = -1.0
) -> bool:
	if not _play_scene_animation(animation_name):
		return false
	if not is_multiplayer_proxy:
		return true

	proxy_action_animation_name_in_use = animation_name
	proxy_action_restore_token += 1
	var restore_token := proxy_action_restore_token
	if restore_delay > 0.0 and is_inside_tree():
		var tween := create_tween()
		tween.tween_interval(restore_delay)
		tween.tween_callback(
			func() -> void:
				_restore_multiplayer_proxy_move_animation(restore_token, animation_name)
		)
	return true


func _restore_multiplayer_proxy_move_animation(
	restore_token: int,
	expected_animation: StringName
) -> void:
	if not is_multiplayer_proxy:
		return
	if is_dead or config == null or animated_sprite == null:
		return
	if restore_token != proxy_action_restore_token:
		return
	if expected_animation != &"" and animated_sprite.animation != expected_animation:
		return

	proxy_action_animation_name_in_use = &""
	_play_scene_animation(config.move_animation_name)


func _ensure_multiplayer_proxy_move_animation() -> void:
	if not is_multiplayer_proxy:
		return
	if is_dead or config == null or animated_sprite == null:
		return
	if proxy_action_animation_name_in_use != &"":
		return
	if animated_sprite.animation != config.move_animation_name:
		_play_scene_animation(config.move_animation_name)
		return
	_sync_move_animation_playback()


func _sync_move_animation_playback() -> void:
	if is_dead or config == null or animated_sprite == null:
		return
	if animated_sprite.animation != config.move_animation_name:
		return

	var should_freeze := _ranged_attack_position_held
	if is_multiplayer_proxy:
		should_freeze = (
			multiplayer_proxy_locomotion_state == LocomotionState.IDLE
		)
	if should_freeze:
		# pause() preserves the authored speed_scale. That distinction matters for
		# proxy visual culling, which independently sets speed_scale to zero while
		# the proxy is off screen and restores it when visible again.
		if animated_sprite.frame != 0 or not is_zero_approx(animated_sprite.frame_progress):
			animated_sprite.set_frame_and_progress(0, 0.0)
		if animated_sprite.is_playing():
			animated_sprite.pause()
		return

	if not animated_sprite.is_playing():
		animated_sprite.play(config.move_animation_name)


func _has_scene_animation(animation_name: StringName) -> bool:
	if animated_sprite == null:
		return false
	if animated_sprite.sprite_frames == null:
		return false
	return animated_sprite.sprite_frames.has_animation(animation_name)


func _get_scene_animation_duration(animation_name: StringName) -> float:
	if not _has_scene_animation(animation_name):
		return 0.0
	var frame_count := animated_sprite.sprite_frames.get_frame_count(animation_name)
	var animation_speed := animated_sprite.sprite_frames.get_animation_speed(animation_name)
	if frame_count <= 0 or animation_speed <= 0.0:
		return 0.0
	var duration := 0.0
	for frame_index in range(frame_count):
		duration += animated_sprite.sprite_frames.get_frame_duration(animation_name, frame_index)
	return duration / animation_speed


func _refresh_collision_shape_cache() -> void:
	body_collision_shapes = _collect_direct_collision_shapes(self)
	touch_damage_shapes = _collect_direct_collision_shapes(touch_damage_area)
	mirrored_collision_shapes.clear()
	mirrored_collision_shapes.append_array(body_collision_shapes)
	mirrored_collision_shapes.append_array(touch_damage_shapes)
	collision_shape = null
	if not body_collision_shapes.is_empty():
		collision_shape = body_collision_shapes[0]
	touch_damage_shape = null
	if not touch_damage_shapes.is_empty():
		touch_damage_shape = touch_damage_shapes[0]
	body_collision_extent_radius = _get_collision_shapes_extent_radius(body_collision_shapes)
	touch_damage_extent_radius = _get_collision_shapes_extent_radius(touch_damage_shapes)
	body_collision_half_extents = _get_collision_shapes_half_extents(body_collision_shapes)


func get_configured_body_collision_half_extents() -> Vector2:
	var shape_nodes: Array[CollisionShape2D] = body_collision_shapes
	if shape_nodes.is_empty():
		shape_nodes = _collect_direct_collision_shapes(self)
	return _get_collision_shapes_half_extents(shape_nodes)


func get_dynamic_target_contact_goal_radius(target_node: Node2D) -> float:
	var target_extent_radius := 0.0
	var player_target := target_node as Player
	if player_target != null:
		target_extent_radius = player_target.get_navigation_collision_extent_radius()
	var grid_half_diagonal := 0.0
	var grid_pathfinder := pathfinder as GridPathfinder
	if grid_pathfinder != null:
		grid_half_diagonal = grid_pathfinder.get_navigation_cell_half_diagonal()
	return (
		maxf(touch_damage_extent_radius, body_collision_extent_radius)
		+ target_extent_radius
		+ grid_half_diagonal
	)


func _collect_direct_collision_shapes(parent_node: Node) -> Array[CollisionShape2D]:
	var shapes: Array[CollisionShape2D] = []
	if parent_node == null:
		return shapes
	for child in parent_node.get_children():
		var shape_node := child as CollisionShape2D
		if shape_node != null:
			shapes.append(shape_node)
	return shapes


func _is_world_segment_clear(
	target_position: Vector2,
	collision_mask_value: int = 1
) -> bool:
	# Lazily reuse one native query and RID exclusion Array per enemy. Callers
	# that can retry a blocked target continuously use the bounded cache below;
	# this primitive remains exact for one-shot and attack-commit checks.
	if _world_los_query == null:
		_world_los_query = PhysicsRayQueryParameters2D.create(
			Vector2.ZERO,
			Vector2.ZERO,
			collision_mask_value
		)
		_world_los_exclude.clear()
		_world_los_exclude.append(get_rid())
		_world_los_query.exclude = _world_los_exclude
		_world_los_query.collide_with_bodies = true
		_world_los_query.collide_with_areas = false
	_world_los_query.from = global_position
	_world_los_query.to = target_position
	_world_los_query.collision_mask = collision_mask_value
	return get_world_2d().direct_space_state.intersect_ray(_world_los_query).is_empty()


func _has_throttled_world_line_of_sight(
	target_node: Node2D,
	collision_mask_value: int = 1
) -> bool:
	# Cache only blocked results. A clear attempt may commit an attack immediately,
	# while a blocked enemy otherwise repeats the same ray every physics frame.
	if target_node == null or not is_instance_valid(target_node):
		_invalidate_blocked_world_los_cache()
		return false
	var target_instance_id := target_node.get_instance_id()
	var target_position := target_node.global_position
	var current_msec := int(Time.get_ticks_msec())
	var blocked_cache_is_current := (
		_blocked_world_los_target_instance_id == target_instance_id
		and _blocked_world_los_collision_mask == collision_mask_value
		and global_position.distance_squared_to(_blocked_world_los_source_position)
			<= BLOCKED_WORLD_LOS_MOTION_INVALIDATION_DISTANCE_SQUARED
		and target_position.distance_squared_to(_blocked_world_los_target_position)
			<= BLOCKED_WORLD_LOS_MOTION_INVALIDATION_DISTANCE_SQUARED
		and current_msec < _blocked_world_los_retry_after_msec
	)
	if blocked_cache_is_current:
		return false

	var has_clear_line := _is_world_segment_clear(target_position, collision_mask_value)
	if has_clear_line:
		_invalidate_blocked_world_los_cache()
		return true
	_blocked_world_los_target_instance_id = target_instance_id
	_blocked_world_los_target_position = target_position
	_blocked_world_los_source_position = global_position
	_blocked_world_los_collision_mask = collision_mask_value
	_blocked_world_los_retry_after_msec = (
		current_msec + _blocked_world_los_retry_interval_msec
	)
	return false


func _invalidate_blocked_world_los_cache() -> void:
	_blocked_world_los_target_instance_id = 0
	_blocked_world_los_collision_mask = 0
	_blocked_world_los_retry_after_msec = 0


func _seed_ranged_combat_line_cache(
	target: Node2D,
	target_position: Vector2,
	collision_mask_value: int,
	navigation_generation: int,
	has_clear_line: bool,
	physics_frame: int
) -> void:
	_ranged_combat_los_target_instance_id = target.get_instance_id()
	_ranged_combat_los_target_position = target_position
	_ranged_combat_los_source_position = global_position
	_ranged_combat_los_collision_mask = collision_mask_value
	_ranged_combat_los_navigation_generation = navigation_generation
	_ranged_combat_los_result = has_clear_line
	_ranged_combat_los_has_result = true
	_ranged_combat_los_last_query_physics_frame = physics_frame
	_ranged_combat_los_next_query_physics_frame = (
		_get_next_ranged_combat_los_phase_frame(physics_frame + 1)
	)


func _invalidate_ranged_combat_line_cache() -> void:
	_ranged_combat_los_target_instance_id = 0
	_ranged_combat_los_collision_mask = 0
	_ranged_combat_los_navigation_generation = -1
	_ranged_combat_los_result = false
	_ranged_combat_los_has_result = false
	_ranged_combat_los_last_query_physics_frame = -1
	_ranged_combat_los_next_query_physics_frame = (
		_get_next_ranged_combat_los_phase_frame(Engine.get_physics_frames())
	)


func _get_next_ranged_combat_los_phase_frame(start_frame: int) -> int:
	var next_frame := maxi(start_frame, 0)
	var phase_remainder := (
		next_frame + navigation_update_frame_offset
	) % RANGED_COMBAT_LOS_REFRESH_INTERVAL_PHYSICS_FRAMES
	if phase_remainder != 0:
		next_frame += (
			RANGED_COMBAT_LOS_REFRESH_INTERVAL_PHYSICS_FRAMES
			- phase_remainder
		)
	return next_frame


func _cache_collision_shape_mirror_states() -> void:
	collision_shape_mirror_states.clear()
	for shape_node in mirrored_collision_shapes:
		if shape_node == null:
			continue
		var state := {
			"position": shape_node.position,
			"rotation": shape_node.rotation,
			"segment_a": Vector2.ZERO,
			"segment_b": Vector2.ZERO,
			"has_segment": false,
		}
		var segment_shape := shape_node.shape as SegmentShape2D
		if segment_shape != null:
			state["segment_a"] = segment_shape.a
			state["segment_b"] = segment_shape.b
			state["has_segment"] = true
		collision_shape_mirror_states[shape_node.get_instance_id()] = state


func _set_facing_from_direction(direction: Vector2) -> void:
	if is_zero_approx(direction.x):
		return
	_set_facing_left(direction.x < 0.0)


func _set_facing_left(new_facing_left: bool) -> void:
	if facing_left == new_facing_left:
		return
	facing_left = new_facing_left
	_apply_sprite_facing()
	_apply_facing_mirror()


func _apply_sprite_facing() -> void:
	if animated_sprite == null:
		return
	animated_sprite.flip_h = facing_left != sprite_faces_left_by_default
	# Enemy scenes are authored around their local x=0 axis. Mirror any visual offset
	# around the entity origin so wide logical frames do not drift from collision shapes.
	var mirror_sign := -1.0 if facing_left else 1.0
	animated_sprite.position = Vector2(animated_sprite_base_position.x * mirror_sign, animated_sprite_base_position.y)


func _apply_facing_mirror() -> void:
	var mirror_sign := -1.0 if facing_left else 1.0
	for shape_node in mirrored_collision_shapes:
		_apply_collision_shape_mirror(shape_node, mirror_sign)


func _apply_collision_shape_mirror(shape_node: CollisionShape2D, mirror_sign: float) -> void:
	if shape_node == null:
		return
	var state: Dictionary = collision_shape_mirror_states.get(shape_node.get_instance_id(), {})
	if state.is_empty():
		return

	var original_position := state["position"] as Vector2
	var original_rotation := float(state["rotation"])
	shape_node.position = Vector2(original_position.x * mirror_sign, original_position.y)
	shape_node.rotation = original_rotation * mirror_sign

	if not bool(state.get("has_segment", false)):
		return
	var segment_shape := shape_node.shape as SegmentShape2D
	if segment_shape == null:
		return
	var original_a := state["segment_a"] as Vector2
	var original_b := state["segment_b"] as Vector2
	segment_shape.a = Vector2(original_a.x * mirror_sign, original_a.y)
	segment_shape.b = Vector2(original_b.x * mirror_sign, original_b.y)


func _get_body_collision_extent_radius() -> float:
	return body_collision_extent_radius


func _get_body_collision_half_extents() -> Vector2:
	return body_collision_half_extents


func _get_collision_shapes_extent_radius(shape_nodes: Array[CollisionShape2D]) -> float:
	var max_radius := 0.0
	for shape_node in shape_nodes:
		max_radius = maxf(max_radius, _get_collision_shape_extent_radius(shape_node))
	return max_radius


func _get_collision_shapes_half_extents(shape_nodes: Array[CollisionShape2D]) -> Vector2:
	var half_extents := Vector2.ZERO
	for shape_node in shape_nodes:
		var shape_extents := _get_collision_shape_half_extents(shape_node)
		half_extents.x = maxf(half_extents.x, shape_extents.x)
		half_extents.y = maxf(half_extents.y, shape_extents.y)
	return half_extents


func _get_collision_shape_extent_radius(shape_node: CollisionShape2D) -> float:
	if shape_node == null or shape_node.shape == null:
		return 0.0

	var shape_rect := shape_node.shape.get_rect()
	var local_transform := shape_node.transform
	var max_radius := 0.0
	var corners := [
		shape_rect.position,
		shape_rect.position + Vector2(shape_rect.size.x, 0.0),
		shape_rect.position + Vector2(0.0, shape_rect.size.y),
		shape_rect.position + shape_rect.size,
	]
	for corner in corners:
		max_radius = maxf(max_radius, (local_transform * corner).length())
	return max_radius


func _get_collision_shape_half_extents(shape_node: CollisionShape2D) -> Vector2:
	if shape_node == null or shape_node.shape == null:
		return Vector2.ZERO

	var shape_rect := shape_node.shape.get_rect()
	var local_transform := shape_node.transform
	var min_position := Vector2(INF, INF)
	var max_position := Vector2(-INF, -INF)
	var corners := [
		shape_rect.position,
		shape_rect.position + Vector2(shape_rect.size.x, 0.0),
		shape_rect.position + Vector2(0.0, shape_rect.size.y),
		shape_rect.position + shape_rect.size,
	]
	for corner in corners:
		var transformed_corner: Vector2 = local_transform * (corner as Vector2)
		min_position.x = minf(min_position.x, transformed_corner.x)
		min_position.y = minf(min_position.y, transformed_corner.y)
		max_position.x = maxf(max_position.x, transformed_corner.x)
		max_position.y = maxf(max_position.y, transformed_corner.y)

	return Vector2(
		maxf(absf(min_position.x), absf(max_position.x)),
		maxf(absf(min_position.y), absf(max_position.y))
	)


func _get_safe_navigation_move_direction(
	target_node: Node2D,
	shared_pathfinder: Node,
	waypoint_arrival_distance: float
) -> Vector2:
	var current_refresh_interval := _get_navigation_update_interval_frames(
		objective_target
	)
	if (
		not navigation_refresh_deferred
		and navigation_next_refresh_physics_frame > Engine.get_physics_frames()
		and navigation_scheduled_refresh_interval_frames == current_refresh_interval
	):
		return cached_navigation_move_direction
	if not Enemy.performance_metrics_enabled:
		return _get_safe_navigation_move_direction_unprofiled(
			target_node,
			shared_pathfinder,
			waypoint_arrival_distance
		)
	var started_usec := Time.get_ticks_usec()
	var move_direction := _get_safe_navigation_move_direction_unprofiled(
		target_node,
		shared_pathfinder,
		waypoint_arrival_distance
	)
	Enemy._record_performance_metric(
		"navigation_calls",
		"navigation_usec",
		started_usec
	)
	return move_direction


func _get_safe_navigation_move_direction_unprofiled(
	target_node: Node2D,
	shared_pathfinder: Node,
	waypoint_arrival_distance: float
) -> Vector2:
	if not _should_update_navigation_direction(target_node):
		return cached_navigation_move_direction
	if not is_instance_valid(target_node):
		return _cache_navigation_move_direction(Vector2.ZERO)
	if shared_pathfinder == null or not shared_pathfinder.get("is_built"):
		return _cache_navigation_move_direction(Vector2.ZERO)
	if not shared_pathfinder.has_method("try_get_safe_navigation_step"):
		return _cache_navigation_move_direction(Vector2.ZERO)
	if _is_far_static_objective(target_node):
		var direct_direction := _get_collision_safe_direct_objective_direction(
			target_node.global_position,
			waypoint_arrival_distance
		)
		if direct_direction != Vector2.ZERO:
			return _cache_navigation_move_direction(
				direct_direction,
				true,
				_get_far_direct_objective_probe_distance()
			)
	elif _is_near_static_objective(target_node):
		# Near a static objective, a precomputed open-area certificate plus a short
		# body probe avoids another flow query. Non-certified corridors retain the
		# full real-shape sweep. Home damage still happens only after the body
		# actually enters the gate Area2D.
		var direct_direction := _get_collision_safe_near_static_objective_direction(
			target_node.global_position
		)
		if direct_direction != Vector2.ZERO:
			return _cache_navigation_move_direction(
				direct_direction,
				true,
				minf(
					global_position.distance_to(target_node.global_position),
					_get_far_direct_objective_probe_distance()
				)
			)
	elif _is_near_moving_target(target_node):
		# Ordinary pursuit only certifies the distance that can be travelled before
		# the next staggered refresh. This stays cheap even near a wall: once the
		# short step is blocked, the shared flow field takes over obstacle routing.
		var direct_direction := _get_collision_safe_short_navigation_step_direction(
			target_node.global_position
		)
		if direct_direction != Vector2.ZERO:
			_prefetch_dynamic_player_flow_if_obstacle_ahead(target_node)
			return _cache_navigation_move_direction(
				direct_direction,
				true,
				minf(
					global_position.distance_to(target_node.global_position),
					_get_far_direct_objective_probe_distance()
				),
				true
			)
	elif target_node != target_player:
		# Between the near and far tiers, keep using the same bounded short-step
		# certificate. Static obstacles hand the enemy to the complete flow route
		# as soon as the next staggered probe reaches them.
		var direct_direction := _get_collision_safe_short_navigation_step_direction(
			target_node.global_position
		)
		if direct_direction != Vector2.ZERO:
			return _cache_navigation_move_direction(direct_direction)

	return _get_flow_navigation_move_direction(
		target_node,
		shared_pathfinder,
		waypoint_arrival_distance
	)


func _prefetch_dynamic_player_flow_if_obstacle_ahead(
	target_node: Node2D
) -> void:
	if (
		not Enemy.dynamic_flow_obstacle_lookahead_enabled
		or target_node == null
		or target_node != target_player
		or not is_instance_valid(target_node)
	):
		return
	var grid_pathfinder := pathfinder as GridPathfinder
	if grid_pathfinder == null or not grid_pathfinder.is_built:
		return
	var profile := _get_navigation_agent_profile()
	if profile == null:
		return
	var current_physics_frame := Engine.get_physics_frames()
	if current_physics_frame < navigation_flow_prefetch_next_physics_frame:
		return
	navigation_flow_prefetch_next_physics_frame = (
		current_physics_frame + DYNAMIC_FLOW_PREFETCH_INTERVAL_PHYSICS_FRAMES
	)
	var probe_distance := _get_far_direct_objective_probe_distance()
	var started_usec := Time.get_ticks_usec() if Enemy.performance_metrics_enabled else 0
	var obstacle_ahead: Variant = (
		grid_pathfinder.try_has_navigation_obstacle_ahead_with_profile(
			global_position,
			target_node.global_position,
			probe_distance,
			DYNAMIC_FLOW_PREFETCH_LOOKAHEAD_CELLS,
			profile
		)
	)
	if Enemy.performance_metrics_enabled:
		Enemy._performance_metrics["navigation_lookahead_calls"] = (
			int(Enemy._performance_metrics["navigation_lookahead_calls"]) + 1
		)
		Enemy._performance_metrics["navigation_lookahead_usec"] = (
			int(Enemy._performance_metrics["navigation_lookahead_usec"])
			+ maxi(Time.get_ticks_usec() - started_usec, 0)
		)
	if obstacle_ahead != true:
		return
	var issued_prefetch := grid_pathfinder.try_prefetch_dynamic_target_flow_with_profile(
		global_position,
		target_node,
		get_dynamic_target_contact_goal_radius(target_node),
		profile
	)
	if Enemy.performance_metrics_enabled:
		var metric_key := (
			"navigation_flow_prefetches"
			if issued_prefetch
			else "navigation_flow_prefetch_deduplicated"
		)
		Enemy._performance_metrics[metric_key] = (
			int(Enemy._performance_metrics[metric_key]) + 1
		)


func _get_flow_navigation_move_direction(
	target_node: Node2D,
	shared_pathfinder: Node,
	waypoint_arrival_distance: float
) -> Vector2:
	if not is_instance_valid(target_node):
		return _cache_navigation_move_direction(Vector2.ZERO)
	if shared_pathfinder == null or not shared_pathfinder.get("is_built"):
		return _cache_navigation_move_direction(Vector2.ZERO)
	if not shared_pathfinder.has_method("try_get_safe_navigation_step"):
		return _cache_navigation_move_direction(Vector2.ZERO)

	var status := GridPathfinder.NavigationStepStatus.UNREACHABLE
	var is_complete_route := false
	var waypoint := global_position
	var resolved_from_cell := Vector2i.MAX
	var next_cell := Vector2i.MAX
	var used_start_recovery := false
	var grid_pathfinder := shared_pathfinder as GridPathfinder
	if grid_pathfinder != null:
		if navigation_step_result == null:
			navigation_step_result = GridPathfinder.NavigationStepResult.new()
		if navigation_flow_context == null:
			navigation_flow_context = GridPathfinder.FlowQueryContext.new()
		if (
			target_node == target_player
			and grid_pathfinder.has_method(
				"try_write_dynamic_target_navigation_step"
			)
		):
			grid_pathfinder.try_write_dynamic_target_navigation_step(
				navigation_step_result,
				navigation_flow_context,
				global_position,
				target_node,
				_get_body_collision_half_extents(),
				terrain_traversal_types,
				get_dynamic_target_contact_goal_radius(target_node)
			)
		else:
			grid_pathfinder.try_write_safe_navigation_step(
				navigation_step_result,
				navigation_flow_context,
				global_position,
				target_node.global_position,
				_get_body_collision_half_extents(),
				terrain_traversal_types,
				target_node != target_player
			)
		status = navigation_step_result.status
		is_complete_route = navigation_step_result.is_complete_route
		waypoint = navigation_step_result.waypoint
		resolved_from_cell = navigation_step_result.resolved_from_cell
		next_cell = navigation_step_result.next_cell
		used_start_recovery = navigation_step_result.used_start_recovery
	else:
		var step: Dictionary = shared_pathfinder.call(
			"try_get_safe_navigation_step",
			global_position,
			target_node.global_position,
			_get_body_collision_half_extents(),
			terrain_traversal_types
		)
		status = int(step.get(
			"status",
			GridPathfinder.NavigationStepStatus.UNREACHABLE
		))
		is_complete_route = bool(step.get("is_complete_route", false))
		waypoint = step.get("waypoint", global_position) as Vector2
		resolved_from_cell = step.get("resolved_from_cell", Vector2i.MAX) as Vector2i
		next_cell = step.get("next_cell", Vector2i.MAX) as Vector2i
		used_start_recovery = bool(step.get("used_start_recovery", false))
	match status:
		GridPathfinder.NavigationStepStatus.READY:
			if not is_complete_route:
				return _cache_navigation_move_direction(Vector2.ZERO)
			var live_target_correction := (
				_get_outdated_dynamic_flow_direct_correction(
					target_node,
					DYNAMIC_FLOW_DIRECT_CORRECTION_DISTANCE_CELLS
				)
			)
			if live_target_correction != Vector2.ZERO:
				return _cache_live_target_direct_correction(
					live_target_correction,
					target_node
				)
			# A moving-target field is double-buffered: its published route remains
			# complete and collision-safe while the bounded replacement integrates.
			# Never turn the shared stale bit into a horde-wide stop. Open terrain was
			# already corrected toward the live player above; obstacle corridors keep
			# making progress on the old route until the atomic replacement arrives.
			var waypoint_arrival_radius := maxf(waypoint_arrival_distance, 0.0)
			var reached_resolved_flow_endpoint := (
				not used_start_recovery
				and resolved_from_cell != Vector2i.MAX
				and next_cell == resolved_from_cell
				and global_position.distance_squared_to(waypoint)
					<= waypoint_arrival_radius * waypoint_arrival_radius
			)
			if reached_resolved_flow_endpoint:
				if target_node != target_player:
					return _cache_navigation_move_direction(
						_get_static_objective_final_alignment_direction(
							target_node.global_position,
							waypoint_arrival_distance
						)
					)
				# Never wait at a superseded player anchor. A one-cell mismatch is
				# enough at the endpoint because the old field has no next step left;
				# the same conservative open-corridor certificate still gates motion.
				live_target_correction = (
					_get_outdated_dynamic_flow_direct_correction(target_node, 1)
				)
				if live_target_correction != Vector2.ZERO:
					return _cache_live_target_direct_correction(
						live_target_correction,
						target_node
					)
				var final_alignment_direction := (
					_get_dynamic_target_final_alignment_direction(target_node)
				)
				if final_alignment_direction != Vector2.ZERO:
					return _cache_live_target_direct_correction(
						final_alignment_direction,
						target_node
					)
				return _cache_navigation_move_direction(Vector2.ZERO)
			var move_direction := _get_waypoint_move_direction(
				waypoint,
				waypoint_arrival_distance
			)
			return _cache_flow_navigation_move_direction(
				move_direction,
				waypoint,
				target_node
			)
		GridPathfinder.NavigationStepStatus.DEFERRED:
			if _is_cached_navigation_direction_shape_safe():
				var refresh_interval := _get_navigation_update_interval_frames(
					target_node
				)
				navigation_next_refresh_physics_frame = (
					_get_next_navigation_phase_frame(refresh_interval)
				)
				navigation_scheduled_refresh_interval_frames = refresh_interval
				return cached_navigation_move_direction
			return _cache_navigation_move_direction(Vector2.ZERO)
		GridPathfinder.NavigationStepStatus.ARRIVED:
			if target_node != target_player:
				return _cache_navigation_move_direction(
					_get_static_objective_final_alignment_direction(
						target_node.global_position,
						waypoint_arrival_distance
					)
				)
			var live_target_correction := (
				_get_outdated_dynamic_flow_direct_correction(target_node, 1)
			)
			if live_target_correction != Vector2.ZERO:
				return _cache_live_target_direct_correction(
					live_target_correction,
					target_node
				)
			var final_alignment_direction := (
				_get_dynamic_target_final_alignment_direction(target_node)
			)
			if final_alignment_direction != Vector2.ZERO:
				return _cache_live_target_direct_correction(
					final_alignment_direction,
					target_node
				)
			return _cache_navigation_move_direction(Vector2.ZERO)
		_:
			return _cache_navigation_move_direction(Vector2.ZERO)


func _is_cached_navigation_direction_shape_safe() -> bool:
	return (
		cached_navigation_move_direction != Vector2.ZERO
		and _is_navigation_motion_shape_safe(
			cached_navigation_move_direction,
			PATH_DIRECTION_PROBE_DISTANCE
		)
	)


func _get_outdated_dynamic_flow_direct_correction(
	target_node: Node2D,
	minimum_anchor_distance_cells: int
) -> Vector2:
	if (
		target_node == null
		or target_node != target_player
		or navigation_step_result == null
		or navigation_flow_context == null
		or navigation_flow_context.dynamic_slot_key == ""
	):
		return Vector2.ZERO
	var live_target_cell := navigation_step_result.target_cell
	var published_anchor_cell := navigation_step_result.resolved_target_cell
	if (
		live_target_cell == Vector2i.MAX
		or published_anchor_cell == Vector2i.MAX
	):
		return Vector2.ZERO
	var anchor_delta := (live_target_cell - published_anchor_cell).abs()
	if (
		maxi(anchor_delta.x, anchor_delta.y)
		< maxi(minimum_anchor_distance_cells, 1)
	):
		return Vector2.ZERO
	# This O(1) integral certificate is deliberately stricter than a local
	# steering probe: it cannot pull an enemy back into a wall or U-shaped trap
	# merely because the newest reverse field has not finished publishing yet.
	return _get_collision_safe_full_open_corridor_direction(
		target_node.global_position
	)


func _get_dynamic_target_final_alignment_direction(
	target_node: Node2D
) -> Vector2:
	if (
		target_node == null
		or target_node != target_player
		or not is_instance_valid(target_node)
		or _has_player_contact()
	):
		return Vector2.ZERO
	# A multi-source player field ends on a reachable cell around the player,
	# not necessarily on the player's exact center. Only bridge that final
	# sub-cell gap: a stale field several cells away must keep waiting for its
	# staged replacement instead of issuing hundreds of long physics sweeps.
	if (
		global_position.distance_squared_to(target_node.global_position)
		> pow(
			get_dynamic_target_contact_goal_radius(target_node)
				+ DYNAMIC_TARGET_FINAL_ALIGNMENT_MARGIN,
			2.0
		)
	):
		return Vector2.ZERO
	return _get_collision_safe_near_moving_target_direction(
		target_node.global_position
	)


func _cache_live_target_direct_correction(
	move_direction: Vector2,
	target_node: Node2D
) -> Vector2:
	return _cache_navigation_move_direction(
		move_direction,
		true,
		minf(
			global_position.distance_to(target_node.global_position),
			_get_far_direct_objective_probe_distance()
		),
		true
	)


func _cache_flow_navigation_move_direction(
	move_direction: Vector2,
	waypoint: Vector2,
	target_node: Node2D
) -> Vector2:
	if move_direction == Vector2.ZERO or not is_instance_valid(target_node):
		return _cache_navigation_move_direction(move_direction)
	var ticks_per_second := maxi(Engine.physics_ticks_per_second, 1)
	var update_interval := maxi(
		_get_navigation_update_interval_frames(target_node),
		1
	)
	var interval_travel_distance := (
		get_effective_move_speed()
		* float(update_interval)
		/ float(ticks_per_second)
	)
	var waypoint_distance := global_position.distance_to(waypoint)
	var certified_clearance := minf(interval_travel_distance, waypoint_distance)
	if certified_clearance <= 0.0001:
		return _cache_navigation_move_direction(move_direction)
	# Sweep a small margin when the waypoint is far enough away. The cached
	# translation allowance never includes that margin, so the body cannot pass
	# beyond the exact interval/waypoint distance that was certified.
	var sweep_distance := minf(
		interval_travel_distance + PATH_DIRECTION_PROBE_DISTANCE,
		waypoint_distance
	)
	var normalized_direction := move_direction.normalized()
	var sweep_end := global_position + normalized_direction * sweep_distance
	if _try_is_navigation_segment_walkable(global_position, sweep_end) != true:
		return _cache_navigation_move_direction(move_direction)
	if _test_navigation_motion(
		global_transform,
		normalized_direction * sweep_distance
	):
		return _cache_navigation_move_direction(move_direction)
	return _cache_navigation_move_direction(
		move_direction,
		true,
		certified_clearance
	)


func _clear_navigation_path() -> void:
	_clear_cached_navigation_move_direction()


func _get_waypoint_move_direction(
	waypoint: Vector2,
	_arrival_distance: float
) -> Vector2:
	var offset := waypoint - global_position
	if offset == Vector2.ZERO:
		return Vector2.ZERO

	# Flow waypoints may be diagonal. Prefer the true normalized vector so open
	# terrain is crossed in a straight line; if the body is already touching an
	# obstacle, fall back to the safer dominant/tangent axis until it has cleared
	# the corner.
	var direct_direction := offset.normalized()
	if _is_navigation_motion_shape_safe(
		direct_direction,
		PATH_DIRECTION_PROBE_DISTANCE
	):
		return direct_direction
	var horizontal_direction := Vector2(signf(offset.x), 0.0)
	var vertical_direction := Vector2(0.0, signf(offset.y))
	if absf(offset.x) >= absf(offset.y):
		return _choose_unblocked_axis_direction(
			horizontal_direction,
			vertical_direction
		)
	return _choose_unblocked_axis_direction(
		vertical_direction,
		horizontal_direction
	)


func _get_collision_safe_direct_objective_direction(
	objective_position: Vector2,
	_arrival_distance: float
) -> Vector2:
	var offset := objective_position - global_position
	if offset == Vector2.ZERO:
		return Vector2.ZERO
	var direct_direction := offset.normalized()
	var probe_distance := _get_far_direct_objective_probe_distance()
	var probe_motion := direct_direction * probe_distance
	if _test_navigation_motion(global_transform, probe_motion):
		return Vector2.ZERO

	# Physical clearance alone can still place a large body inside a grid cell
	# that is deliberately blocked by the inflated navigation profile. Keep the
	# cheap straight-line tier outside that conservative band, otherwise the
	# later handoff to flow navigation may have no valid start cell.
	var grid_pathfinder := pathfinder as GridPathfinder
	if grid_pathfinder != null:
		var probe_end := global_position + probe_motion
		var segment_walkable: Variant = _try_is_navigation_segment_walkable(
			global_position,
			probe_end
		)
		if segment_walkable != true:
			return Vector2.ZERO
	return direct_direction


func _get_collision_safe_near_static_objective_direction(
	objective_position: Vector2
) -> Vector2:
	var precomputed_direction := (
		_get_collision_safe_short_navigation_step_direction(objective_position)
	)
	if precomputed_direction != Vector2.ZERO:
		return precomputed_direction
	var offset := objective_position - global_position
	if offset == Vector2.ZERO:
		return Vector2.ZERO
	# For a non-certified rectangle, sweep the complete remaining segment with
	# the real CharacterBody shape. The caller records only the shorter distance
	# needed before the next navigation update, so lightweight translation can
	# never travel beyond this exact collision certificate.
	if _test_navigation_motion(global_transform, offset):
		return Vector2.ZERO
	return offset.normalized()


func _get_collision_safe_near_moving_target_direction(
	objective_position: Vector2
) -> Vector2:
	var precomputed_direction := (
		_get_collision_safe_short_navigation_step_direction(objective_position)
	)
	if precomputed_direction != Vector2.ZERO:
		return precomputed_direction
	var offset := objective_position - global_position
	if offset == Vector2.ZERO:
		return Vector2.ZERO
	if _test_navigation_motion(global_transform, offset):
		return Vector2.ZERO
	return offset.normalized()


func _get_collision_safe_short_navigation_step_direction(
	objective_position: Vector2
) -> Vector2:
	var offset := objective_position - global_position
	if offset == Vector2.ZERO:
		return Vector2.ZERO
	var direct_direction := offset.normalized()
	var probe_distance := minf(
		offset.length(),
		_get_far_direct_objective_probe_distance()
	)
	var probe_motion := direct_direction * probe_distance
	# Certify only the distance that can actually be travelled before the next
	# staggered navigation refresh. Checking the complete rectangle to a moving
	# player makes almost every wall-adjacent query fail the O(1) integral test and
	# forces hundreds of redundant exact samples through distant map cells.
	if _try_is_navigation_segment_walkable(
		global_position,
		global_position + probe_motion
	) != true:
		return Vector2.ZERO
	if _test_navigation_motion(
		global_transform,
		probe_motion
	):
		return Vector2.ZERO
	return direct_direction


# A stale dynamic field may point at a superseded player position. Bypassing
# that complete route is safe only when the immutable agent-solid integral can
# conservatively prove the whole endpoint rectangle open. The O(1) certificate
# deliberately has no exact long-segment fallback; after it succeeds, the usual
# short grid/physics probe still protects against dynamic bodies and sub-cell
# collision geometry until the next staggered navigation refresh.
func _get_collision_safe_full_open_corridor_direction(
	objective_position: Vector2
) -> Vector2:
	if _try_get_navigation_open_plain(objective_position) != true:
		return Vector2.ZERO
	return _get_collision_safe_short_navigation_step_direction(
		objective_position
	)


func _try_get_navigation_open_plain(objective_position: Vector2) -> Variant:
	var grid_pathfinder := pathfinder as GridPathfinder
	if (
		grid_pathfinder == null
		or not grid_pathfinder.has_method("try_is_navigation_open_plain")
	):
		return null
	var profile := _get_navigation_agent_profile()
	if profile != null:
		return grid_pathfinder.try_is_navigation_open_plain_with_profile(
			global_position,
			objective_position,
			profile
		)
	return grid_pathfinder.try_is_navigation_open_plain(
		global_position,
		objective_position,
		_get_body_collision_half_extents(),
		terrain_traversal_types
	)


func _try_is_navigation_segment_walkable(
	from_position: Vector2,
	to_position: Vector2
) -> Variant:
	var grid_pathfinder := pathfinder as GridPathfinder
	if grid_pathfinder == null:
		return null
	var profile := _get_navigation_agent_profile()
	if profile != null:
		return grid_pathfinder.try_is_navigation_segment_walkable_with_profile(
			from_position,
			to_position,
			profile
		)
	return grid_pathfinder.try_is_navigation_segment_walkable(
		from_position,
		to_position,
		_get_body_collision_half_extents(),
		terrain_traversal_types
	)


func _get_navigation_agent_profile() -> GridPathfinder.AgentNavigationProfile:
	var grid_pathfinder := pathfinder as GridPathfinder
	if grid_pathfinder == null or not grid_pathfinder.is_built:
		navigation_agent_profile = null
		return null
	if grid_pathfinder.is_agent_navigation_profile_valid(navigation_agent_profile):
		return navigation_agent_profile
	navigation_agent_profile = grid_pathfinder.try_get_agent_navigation_profile(
		_get_body_collision_half_extents(),
		terrain_traversal_types
	)
	return navigation_agent_profile


func _test_navigation_motion(
	from_transform: Transform2D,
	motion: Vector2,
	collision: KinematicCollision2D = null
) -> bool:
	if not Enemy.performance_metrics_enabled:
		if collision == null:
			return test_move(from_transform, motion)
		return test_move(from_transform, motion, collision)
	var started_usec := Time.get_ticks_usec()
	var blocked := (
		test_move(from_transform, motion)
		if collision == null
		else test_move(from_transform, motion, collision)
	)
	Enemy._record_performance_metric(
		"test_move_calls",
		"test_move_usec",
		started_usec
	)
	return blocked


func _get_static_objective_final_alignment_direction(
	objective_position: Vector2,
	arrival_distance: float
) -> Vector2:
	# A conservative agent grid can finish beside a narrow entrance while the
	# real body still has a physically open final corridor. If a full diagonal
	# sweep clips the entrance corner, first align the smaller axis by one safe
	# local step; the regular near-direct tier takes over as soon as the full
	# segment clears. This never reports objective contact or bypasses Area2D.
	var offset := objective_position - global_position
	if offset == Vector2.ZERO:
		return Vector2.ZERO
	var deadzone := maxf(arrival_distance, 0.0)
	var horizontal_direction := Vector2(signf(offset.x), 0.0)
	var vertical_direction := Vector2(0.0, signf(offset.y))
	if absf(offset.x) <= deadzone:
		return _choose_unblocked_axis_direction(vertical_direction)
	if absf(offset.y) <= deadzone:
		return _choose_unblocked_axis_direction(horizontal_direction)
	if absf(offset.x) < absf(offset.y):
		return _choose_unblocked_axis_direction(
			horizontal_direction,
			vertical_direction
		)
	return _choose_unblocked_axis_direction(
		vertical_direction,
		horizontal_direction
	)


func _get_far_direct_objective_probe_distance() -> float:
	# The far-distance movement tier advances without a CharacterBody motion
	# query on every physics tick. Sweep the complete distance that can be
	# travelled before the next scheduled direction update, plus a small margin,
	# so a wall or water collider switches the enemy back to the full flow field
	# before the lightweight movement can reach it.
	var physics_ticks_per_second := maxi(Engine.physics_ticks_per_second, 1)
	var update_interval := maxi(
		_get_navigation_update_interval_frames(objective_target),
		1
	)
	var interval_travel_distance := (
		get_effective_move_speed()
		* float(update_interval)
		/ float(physics_ticks_per_second)
	)
	return maxf(
		PATH_DIRECTION_PROBE_DISTANCE,
		interval_travel_distance + PATH_DIRECTION_PROBE_DISTANCE
	)


func _should_update_navigation_direction(target_node: Node2D = objective_target) -> bool:
	if not navigation_refresh_deferred:
		if cached_navigation_move_direction == Vector2.ZERO:
			if Engine.get_physics_frames() < navigation_zero_direction_retry_frame:
				return false
		else:
			var interval := _get_navigation_update_interval_frames(target_node)
			if (
				interval > 1
				and (
					Engine.get_physics_frames() + navigation_update_frame_offset
				) % interval != 0
			):
				return false

	if Enemy.navigation_render_frame_dedupe_enabled:
		var render_frame := Engine.get_process_frames()
		if render_frame == last_navigation_update_render_frame:
			if Enemy.performance_metrics_enabled:
				Enemy._performance_metrics["navigation_same_render_skips"] = (
					int(Enemy._performance_metrics["navigation_same_render_skips"]) + 1
				)
			return false
		last_navigation_update_render_frame = render_frame
	if (
		Enemy.navigation_process_frame_budget_enabled
		and pathfinder != null
		and pathfinder.has_method("try_acquire_agent_navigation_refresh")
		and not bool(pathfinder.call(
			"try_acquire_agent_navigation_refresh",
			get_instance_id()
		))
	):
		navigation_refresh_deferred = true
		if Enemy.performance_metrics_enabled:
			Enemy._performance_metrics["navigation_budget_deferrals"] = (
				int(Enemy._performance_metrics["navigation_budget_deferrals"]) + 1
			)
		return false
	navigation_refresh_deferred = false
	if Enemy.performance_metrics_enabled:
		Enemy._performance_metrics["navigation_refresh_calls"] = (
			int(Enemy._performance_metrics["navigation_refresh_calls"]) + 1
		)
	last_navigation_refresh_process_frame = Engine.get_process_frames()
	return true


func _is_combat_sense_refresh_due() -> bool:
	if not Enemy.combat_sense_throttling_enabled:
		return true
	var interval := maxi(combat_sense_update_interval_frames, 1)
	return (
		interval <= 1
		or (
			Engine.get_physics_frames() + navigation_update_frame_offset
		) % interval == 0
	)


func _get_next_navigation_phase_frame(interval: int) -> int:
	var safe_interval := maxi(interval, 1)
	var next_frame := Engine.get_physics_frames() + 1
	if safe_interval <= 1:
		return next_frame
	var phase_remainder := (
		next_frame + navigation_update_frame_offset
	) % safe_interval
	if phase_remainder != 0:
		next_frame += safe_interval - phase_remainder
	return next_frame


func _get_navigation_update_interval_frames(target_node: Node2D) -> int:
	var interval := maxi(navigation_update_interval_frames, 1)
	if _is_far_static_objective(target_node):
		interval = maxi(interval, FAR_STATIC_OBJECTIVE_UPDATE_INTERVAL_FRAMES)
	return interval


func _is_far_static_objective(target_node: Node2D) -> bool:
	return (
		is_instance_valid(target_node)
		and target_node != target_player
		and global_position.distance_squared_to(target_node.global_position)
			>= FAR_STATIC_OBJECTIVE_DISTANCE_SQUARED
	)


func _is_near_static_objective(target_node: Node2D) -> bool:
	return (
		is_instance_valid(target_node)
		and target_node != target_player
		and global_position.distance_squared_to(target_node.global_position)
			<= NEAR_STATIC_DIRECT_OBJECTIVE_DISTANCE_SQUARED
	)


func _is_near_moving_target(target_node: Node2D) -> bool:
	return (
		is_instance_valid(target_node)
		and target_node == target_player
		and global_position.distance_squared_to(target_node.global_position)
			<= near_moving_target_direct_distance_squared
	)


func _cache_navigation_move_direction(
	move_direction: Vector2,
	uses_direct_objective_approach: bool = false,
	verified_direct_motion_clearance: float = 0.0,
	tracks_live_target_direction: bool = false
) -> Vector2:
	cached_navigation_move_direction = move_direction
	cached_navigation_uses_direct_objective_approach = (
		uses_direct_objective_approach and move_direction != Vector2.ZERO
	)
	cached_navigation_verified_direct_motion_clearance = (
		maxf(verified_direct_motion_clearance, 0.0)
		if cached_navigation_uses_direct_objective_approach
		else 0.0
	)
	cached_navigation_generation = (
		_get_current_navigation_generation()
		if cached_navigation_uses_direct_objective_approach
		else -1
	)
	cached_navigation_tracks_live_target_direction = (
		tracks_live_target_direction
		and cached_navigation_uses_direct_objective_approach
	)
	var refresh_interval := _get_navigation_update_interval_frames(objective_target)
	navigation_next_refresh_physics_frame = _get_next_navigation_phase_frame(
		refresh_interval
	)
	navigation_scheduled_refresh_interval_frames = refresh_interval
	if move_direction == Vector2.ZERO:
		navigation_zero_direction_retry_frame = navigation_next_refresh_physics_frame
	else:
		navigation_zero_direction_retry_frame = 0
	return move_direction


func _clear_cached_navigation_move_direction() -> void:
	last_navigation_update_render_frame = -1
	navigation_refresh_deferred = false
	cached_navigation_move_direction = Vector2.ZERO
	cached_navigation_uses_direct_objective_approach = false
	cached_navigation_verified_direct_motion_clearance = 0.0
	cached_navigation_generation = -1
	cached_navigation_tracks_live_target_direction = false
	navigation_next_refresh_physics_frame = 0
	navigation_scheduled_refresh_interval_frames = 0
	navigation_zero_direction_retry_frame = 0
	if navigation_flow_context != null:
		navigation_flow_context.invalidate()


func _get_current_navigation_generation() -> int:
	var grid_pathfinder := pathfinder as GridPathfinder
	return grid_pathfinder.navigation_generation if grid_pathfinder != null else -1


func _choose_unblocked_axis_direction(primary_direction: Vector2, secondary_direction: Vector2 = Vector2.ZERO) -> Vector2:
	if primary_direction == Vector2.ZERO:
		if _is_navigation_motion_shape_safe(secondary_direction, PATH_DIRECTION_PROBE_DISTANCE):
			return secondary_direction
		return Vector2.ZERO
	if _is_navigation_motion_shape_safe(primary_direction, PATH_DIRECTION_PROBE_DISTANCE):
		return primary_direction
	if _is_navigation_motion_shape_safe(secondary_direction, PATH_DIRECTION_PROBE_DISTANCE):
		return secondary_direction
	return Vector2.ZERO


func _is_navigation_motion_shape_safe(direction: Vector2, probe_distance: float) -> bool:
	if direction == Vector2.ZERO or probe_distance <= 0.0:
		return false
	var normalized_direction := direction.normalized()
	var motion := normalized_direction * probe_distance
	if not _test_navigation_motion(
		global_transform,
		motion,
		navigation_collision_probe
	):
		return true

	# test_move() can report an existing side contact even when the requested
	# motion is exactly tangent to that surface. Treat that contact as safe so an
	# enemy touching a wall can still follow a flow-field waypoint along it. A
	# motion pointing into the collision normal remains blocked.
	return normalized_direction.dot(navigation_collision_probe.get_normal()) >= -0.001


func _move_until_player_contact() -> void:
	if velocity == Vector2.ZERO:
		return
	if _has_player_contact():
		velocity = Vector2.ZERO
		return
	if (
		cached_navigation_tracks_live_target_direction
		and is_instance_valid(objective_target)
		and objective_target == target_player
		and cached_navigation_move_direction.dot(
			objective_target.global_position - global_position
		) <= 0.0
	):
		# The player crossed the origin of a direct-to-live-target sweep after this
		# tick's direction was chosen. Do not submit one last move in the obsolete
		# direction; clear the cache so the next physics tick recomputes immediately.
		velocity = Vector2.ZERO
		_clear_cached_navigation_move_direction()
		return
	var motion := velocity * get_physics_process_delta_time()
	if _can_use_verified_direct_objective_linear_movement(motion):
		global_position += motion
		cached_navigation_verified_direct_motion_clearance = maxf(
			cached_navigation_verified_direct_motion_clearance - motion.length(),
			0.0
		)
		if Enemy.performance_metrics_enabled:
			Enemy._performance_metrics["verified_direct_move_calls"] = (
				int(Enemy._performance_metrics["verified_direct_move_calls"]) + 1
			)
			Enemy._performance_metrics["verified_direct_move_distance"] = (
				float(Enemy._performance_metrics["verified_direct_move_distance"])
				+ motion.length()
			)
		return
	# A CharacterBody fallback changes (or can collision-recover) the origin that
	# the direct-motion sweep certified. Never reuse that certificate from the
	# resulting transform; the next scheduled navigation update must revalidate it.
	cached_navigation_uses_direct_objective_approach = false
	cached_navigation_verified_direct_motion_clearance = 0.0
	cached_navigation_generation = -1
	cached_navigation_tracks_live_target_direction = false
	if not Enemy.performance_metrics_enabled:
		move_and_slide()
		return
	var started_usec := Time.get_ticks_usec()
	move_and_slide()
	Enemy._record_performance_metric(
		"move_and_slide_calls",
		"move_and_slide_usec",
		started_usec
	)


func _can_use_verified_direct_objective_linear_movement(motion: Vector2) -> bool:
	var motion_distance := motion.length()
	var motion_matches_swept_direction := (
		motion_distance > 0.0
		and cached_navigation_move_direction != Vector2.ZERO
		and cached_navigation_move_direction.dot(motion)
			>= motion_distance * 0.999
	)
	var live_target_still_ahead := (
		not cached_navigation_tracks_live_target_direction
		or (
			objective_target == target_player
			and cached_navigation_move_direction.dot(
				objective_target.global_position - global_position
			) > 0.0
		)
	)
	return (
		cached_navigation_uses_direct_objective_approach
		and is_instance_valid(objective_target)
		and cached_navigation_generation == _get_current_navigation_generation()
		and motion_matches_swept_direction
		and live_target_still_ahead
		and motion_distance
			<= cached_navigation_verified_direct_motion_clearance + 0.0001
	)


# Kept as a static-objective contract for existing diagnostics. Production
# movement uses the general verified-direct predicate above, which additionally
# permits a nearby moving player within an exact, generation-bound sweep.
func _can_use_verified_static_objective_linear_movement(motion: Vector2) -> bool:
	return (
		objective_target != target_player
		and _can_use_verified_direct_objective_linear_movement(motion)
	)


func _has_player_contact() -> bool:
	if not touching_players.is_empty():
		return true
	for instance_id in touching_plants:
		var plant := touching_plants[instance_id] as PlantDefense
		if (
			plant == null
			or not is_instance_valid(plant)
			or plant.is_dead
			or plant.is_removing
		):
			continue
		var entry_distance := float(
			touching_plant_entry_distances.get(instance_id, INF)
		)
		if not is_finite(entry_distance):
			continue
		var stop_distance := maxf(
			entry_distance - plant.get_enemy_approach_depth(),
			minf(entry_distance, 1.0)
		)
		if global_position.distance_to(plant.global_position) <= stop_distance:
			return true
	return false


func _clear_touching_players() -> void:
	touching_players.clear()
	touched_player = null
	touching_plants.clear()
	touching_plant_entry_distances.clear()
	touched_plant = null


func _on_touch_damage_area_body_entered(body: Node2D) -> void:
	if is_dead:
		return
	# A contact changes movement semantics immediately. Never reuse a sweep that
	# was certified before the body/area overlap began.
	_clear_cached_navigation_move_direction()

	var plant := body as PlantDefense
	if plant != null:
		if plant.is_dead or plant.is_removing:
			return
		var plant_instance_id := plant.get_instance_id()
		touching_plants[plant_instance_id] = plant
		if not touching_plant_entry_distances.has(plant_instance_id):
			touching_plant_entry_distances[plant_instance_id] = (
				global_position.distance_to(plant.global_position)
			)
		touched_plant = plant
		var removal_callback := _on_touched_plant_removal_started.bind(plant)
		if not plant.removal_started.is_connected(removal_callback):
			plant.removal_started.connect(removal_callback, CONNECT_ONE_SHOT)
		_try_deal_touch_damage()
		return

	var player := body as Player
	if player == null:
		return

	touching_players[player.get_instance_id()] = player
	touched_player = player
	_try_deal_touch_damage()


func _on_touch_damage_area_body_exited(body: Node2D) -> void:
	var plant := body as PlantDefense
	if plant != null:
		var plant_instance_id := plant.get_instance_id()
		touching_plants.erase(plant_instance_id)
		touching_plant_entry_distances.erase(plant_instance_id)
		if plant == touched_plant:
			touched_plant = _select_touching_plant()
		return

	var player := body as Player
	if player == null:
		return
	touching_players.erase(player.get_instance_id())
	if player == touched_player:
		touched_player = _select_touching_player()


func _select_touching_player() -> Player:
	for instance_id in touching_players:
		var player := touching_players[instance_id] as Player
		if is_instance_valid(player):
			return player
	touching_players.clear()
	return null


func _select_touching_plant() -> PlantDefense:
	for instance_id in touching_plants:
		var plant := touching_plants[instance_id] as PlantDefense
		if is_instance_valid(plant) and not plant.is_dead and not plant.is_removing:
			return plant
	touching_plants.clear()
	touching_plant_entry_distances.clear()
	return null


func _on_touched_plant_removal_started(_mode: int, plant: PlantDefense) -> void:
	if plant == null:
		return
	var plant_instance_id := plant.get_instance_id()
	touching_plants.erase(plant_instance_id)
	touching_plant_entry_distances.erase(plant_instance_id)
	if touched_plant == plant:
		touched_plant = _select_touching_plant()


func _update_touch_damage(delta: float) -> void:
	if (
		touch_damage_cooldown_left <= 0.0
		and touching_plants.is_empty()
		and touching_players.is_empty()
	):
		touched_plant = null
		touched_player = null
		return
	if not Enemy.performance_metrics_enabled:
		_update_touch_damage_unprofiled(delta)
		return
	var started_usec := Time.get_ticks_usec()
	_update_touch_damage_unprofiled(delta)
	Enemy._record_performance_metric(
		"touch_damage_calls",
		"touch_damage_usec",
		started_usec
	)


func _update_touch_damage_unprofiled(delta: float) -> void:
	if touch_damage_cooldown_left > 0.0:
		touch_damage_cooldown_left = maxf(touch_damage_cooldown_left - delta, 0.0)
	if touching_plants.is_empty() and touching_players.is_empty():
		touched_plant = null
		touched_player = null
		return

	if (
		touched_plant == null
		or not is_instance_valid(touched_plant)
		or touched_plant.is_dead
		or touched_plant.is_removing
	):
		touched_plant = _select_touching_plant()
	if touched_plant != null:
		if touch_damage_cooldown_left <= 0.0:
			_try_deal_touch_damage()
		return

	if touched_player == null:
		touched_player = _select_touching_player()
		if touched_player == null:
			return
	if not is_instance_valid(touched_player):
		touched_player = _select_touching_player()
		if touched_player == null:
			return
	if touch_damage_cooldown_left > 0.0:
		return

	_try_deal_touch_damage()


func _try_deal_touch_damage() -> void:
	if is_dead:
		return
	if touch_damage_cooldown_left > 0.0:
		return
	if config == null:
		return
	var touch_damage_type := _get_touch_damage_type()
	if (
		touched_plant != null
		and is_instance_valid(touched_plant)
		and not touched_plant.is_dead
		and not touched_plant.is_removing
	):
		var impact_direction := global_position.direction_to(touched_plant.global_position)
		if touched_plant.receive_damage(
			config.attack_damage,
			self,
			impact_direction,
			touch_damage_type
		):
			touch_damage_cooldown_left = touch_damage_interval
		return
	if touched_player == null:
		return

	var current_scene := get_tree().current_scene
	if current_scene != null and current_scene.has_method("request_multiplayer_player_damage"):
		current_scene.call(
			"request_multiplayer_player_damage",
			_get_multiplayer_touch_source_id(),
			touched_player.peer_id,
			config.attack_damage,
			&"enemy_touch",
			touch_damage_type
		)
		touch_damage_cooldown_left = touch_damage_interval
		return
	touched_player.apply_damage(
		config.attack_damage,
		touch_damage_type
	)
	touch_damage_cooldown_left = touch_damage_interval


func _get_touch_damage_type() -> EnemyConfig.DamageType:
	return EnemyConfig.DamageType.PHYSICAL


func _get_multiplayer_touch_source_id() -> int:
	var net_id := int(get_meta("net_id", get_instance_id()))
	var tick := int(Time.get_ticks_msec())
	return maxi(net_id, 1) * 1000000 + tick

func _play_hit_particles(impact_direction: Vector2) -> void:
	if impact_direction == Vector2.ZERO:
		return
	var spawn_parent := get_tree().current_scene
	if spawn_parent == null:
		return
	if not WORLD_EFFECT_VISIBILITY.is_position_near_viewport(
		self,
		global_position
	):
		return
	var effect: BulletHitEffect = null
	var uses_registered_pool := (
		spawn_parent.has_method("has_session_object_pool_scene")
		and bool(spawn_parent.call("has_session_object_pool_scene", HIT_EFFECT_SCENE))
	)
	if uses_registered_pool:
		effect = spawn_parent.call(
			"acquire_session_object",
			HIT_EFFECT_SCENE,
			true
		) as BulletHitEffect
	else:
		effect = HIT_EFFECT_SCENE.instantiate() as BulletHitEffect
	if effect == null:
		return
	effect.top_level = true
	if effect.get_parent() == null:
		spawn_parent.add_child(effect)
	effect.global_position = global_position
	effect.reset_physics_interpolation()
	effect.setup(impact_direction)


func _die() -> void:
	if is_dead:
		return

	# Mark the death before rewards or drop resolution so any future callback
	# that re-enters _die cannot enqueue the same side effects twice.
	is_dead = true
	clear_cold_status()
	_queue_configured_xirang_kill_reward()
	_queue_configured_pickup_drops()
	defeated.emit(self)
	velocity = Vector2.ZERO
	_update_movement_status_visuals()
	set_process(false)
	set_physics_process(false)
	touched_player = null
	touching_players.clear()
	touched_plant = null
	touching_plants.clear()
	touching_plant_entry_distances.clear()
	_set_collision_shapes_disabled(body_collision_shapes, true)
	_set_collision_shapes_disabled(touch_damage_shapes, true)
	touch_damage_area.set_deferred("monitoring", false)
	touch_damage_area.set_deferred("monitorable", false)
	AUDIO_LIMITER.play_enemy_death(death_audio)
	_start_death_sequence()


func _queue_configured_xirang_kill_reward() -> void:
	if is_multiplayer_proxy or config == null or config.xirang_kill_reward <= 0:
		return
	var current_scene := get_tree().current_scene
	if current_scene == null or not current_scene.has_method("grant_xirang_kill_reward"):
		return
	current_scene.call("grant_xirang_kill_reward", config.xirang_kill_reward)


func _queue_configured_pickup_drops() -> void:
	if is_multiplayer_proxy or config == null or config.drop_table == null:
		return
	var drop_configs := config.drop_table.resolve_drop_configs(
		config.drop_tags,
		material_drop_random_generator
	)
	if drop_configs.is_empty():
		return
	call_deferred("_spawn_dropped_pickups", drop_configs, global_position)


func _spawn_dropped_pickups(
	drop_configs: Array[PickupConfig],
	spawn_position: Vector2
) -> void:
	if drop_configs.is_empty():
		return
	var drop_parent := get_parent()
	if drop_parent == null:
		return
	var valid_drop_configs: Array[PickupConfig] = []
	for drop_config in drop_configs:
		if drop_config != null:
			valid_drop_configs.append(drop_config)
	for drop_index in range(valid_drop_configs.size()):
		var drop_config := valid_drop_configs[drop_index]
		var pickup := ENEMY_DROP_PICKUP_SCENE.instantiate() as Pickup
		if pickup == null:
			continue
		pickup.config = drop_config
		drop_parent.add_child(pickup)
		pickup.global_position = (
			spawn_position
			+ _get_dropped_pickup_offset(
				drop_index,
				valid_drop_configs.size()
			)
		)


func _get_dropped_pickup_offset(drop_index: int, drop_count: int) -> Vector2:
	if drop_count <= 1:
		return Vector2.ZERO
	var ring_index := drop_index
	var ring_count := drop_count
	var radius := 9.0 + float(drop_count)
	var angle_offset := -PI * 0.5
	if drop_count > 6:
		var inner_count := drop_count >> 1
		if drop_index < inner_count:
			ring_count = inner_count
			radius = ENEMY_DROP_INNER_RING_RADIUS
		else:
			ring_index -= inner_count
			ring_count = drop_count - inner_count
			radius = ENEMY_DROP_OUTER_RING_RADIUS
			angle_offset += PI / float(ring_count)
	var angle := (
		angle_offset
		+ TAU * float(ring_index) / float(ring_count)
	)
	return Vector2.from_angle(angle) * radius


func _set_collision_shapes_disabled(shape_nodes: Array[CollisionShape2D], disabled: bool) -> void:
	for shape_node in shape_nodes:
		if shape_node != null:
			shape_node.set_deferred("disabled", disabled)


func _start_death_sequence() -> void:
	if config == null:
		queue_free()
		return

	if _play_death_sequence_animation(config.death_animation_name, DeathSequenceStage.DEATH):
		return

	_finish_after_death_animation()


func _finish_after_death_animation() -> void:
	queue_free()


func _play_death_sequence_animation(animation_name: StringName, stage: DeathSequenceStage) -> bool:
	death_sequence_stage = stage
	death_animation_name_in_use = animation_name
	if animated_sprite != null:
		animated_sprite.speed_scale = (
			_get_staggered_death_animation_speed_scale()
			if stage == DeathSequenceStage.DEATH
			else 1.0
		)

	return _play_scene_animation(animation_name)


func _get_staggered_death_animation_speed_scale() -> float:
	var stable_id := int(get_meta("net_id", get_instance_id()))
	var bucket_index := posmod(stable_id, DEATH_ANIMATION_SPEED_SCALES.size())
	return DEATH_ANIMATION_SPEED_SCALES[bucket_index]


func _on_animated_sprite_animation_finished() -> void:
	if (
		is_multiplayer_proxy
		and proxy_action_animation_name_in_use != &""
		and animated_sprite.animation == proxy_action_animation_name_in_use
	):
		_restore_multiplayer_proxy_move_animation(
			proxy_action_restore_token,
			proxy_action_animation_name_in_use
		)
		return

	if not is_dead:
		return
	if death_animation_name_in_use == &"":
		return
	if animated_sprite.animation != death_animation_name_in_use:
		return

	_finish_after_death_animation()
