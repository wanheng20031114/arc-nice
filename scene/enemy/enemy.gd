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
const NEAR_STATIC_DIRECT_OBJECTIVE_DISTANCE := 96.0
const NEAR_STATIC_DIRECT_OBJECTIVE_DISTANCE_SQUARED := (
	NEAR_STATIC_DIRECT_OBJECTIVE_DISTANCE * NEAR_STATIC_DIRECT_OBJECTIVE_DISTANCE
)
const AUDIO_LIMITER := preload("res://scene/explosion_audio_limiter.gd")
const MATERIAL_PICKUP_SCENE := preload("res://scene/pickup.tscn")
const MATERIAL_WOOD := preload("res://resources/config/materials/material_wood.tres")
const MATERIAL_SAPLING := preload("res://resources/config/materials/material_sapling.tres")
const MATERIAL_DROP_CHANCE := 0.03
const MATERIAL_DROP_CONFIGS: Array[PickupConfig] = [MATERIAL_WOOD, MATERIAL_SAPLING]
const SLOW_OVERLAY_ACTIVE_STRENGTH := 0.36
const BURN_OVERLAY_ACTIVE_STRENGTH := 0.26
const BLEED_OVERLAY_ACTIVE_STRENGTH := 0.42
const BURN_STATUS_TICK_INTERVAL := 1.0
const WATER_TERRAIN_COLLISION_LAYER := 1 << 11
const DEATH_ANIMATION_SPEED_SCALES: Array[float] = [0.92, 0.96, 1.0, 1.04, 1.08]

enum DeathSequenceStage {
	NONE,
	DEATH,
	EXPLOSION,
}

@export var config: EnemyConfig
@export var touch_damage_interval: float = 0.5
@export var sprite_faces_left_by_default: bool = false
@export_range(1, 8, 1, "or_greater") var navigation_update_interval_frames: int = 2
@export_flags("Land", "Water") var terrain_traversal_types: int = DualGridTilemap.TraversalType.LAND

@onready var animated_sprite: AnimatedSprite2D = $AnimatedSprite2D
@onready var speed_trail_effect: Node2D = $MoveSpeedTrailEffect
@onready var collision_shape: CollisionShape2D = null
@onready var touch_damage_area: Area2D = $TouchDamageArea
@onready var touch_damage_shape: CollisionShape2D = null
@onready var hit_particles: GPUParticles2D = $HitParticles
@onready var hit_audio: AudioStreamPlayer2D = $HitAudio
@onready var death_audio: AudioStreamPlayer2D = $DeathAudio

var target_player: Player = null
var objective_target: Node2D = null
var reward_player: Player = null
var pathfinder: Node = null
var current_health: int = 1
var is_dead: bool = false
var touch_damage_cooldown_left: float = 0.0
var touched_player: Player = null
var touching_players: Dictionary[int, Player] = {}
var touched_plant: PlantDefense = null
var touching_plants: Dictionary[int, PlantDefense] = {}
var death_sequence_stage: DeathSequenceStage = DeathSequenceStage.NONE
var death_animation_name_in_use: StringName = &""
var physical_defense_modifiers: Dictionary = {}
var move_speed_modifiers: Dictionary = {}
var damage_taken_multiplier_modifiers: Dictionary = {}
var collectible_status_effects: Dictionary = {}
var collectible_status_tween: Tween = null
var is_multiplayer_proxy: bool = false
var last_damage_taken: int = 0
var body_collision_shapes: Array[CollisionShape2D] = []
var touch_damage_shapes: Array[CollisionShape2D] = []
var body_collision_extent_radius: float = 0.0
var body_collision_half_extents: Vector2 = Vector2.ZERO
var collision_shape_mirror_states: Dictionary = {}
var facing_left: bool = false
var proxy_action_animation_name_in_use: StringName = &""
var proxy_action_restore_token: int = 0
var navigation_update_frame_offset: int = 0
var cached_navigation_move_direction := Vector2.ZERO
var cached_navigation_uses_direct_objective_approach: bool = false
var navigation_zero_direction_retry_frame: int = 0
var navigation_collision_probe := KinematicCollision2D.new()
var navigation_step_result: GridPathfinder.NavigationStepResult = null
var navigation_flow_context: GridPathfinder.FlowQueryContext = null
var animated_sprite_base_position := Vector2.ZERO
var material_drop_random_generator := RandomNumberGenerator.new()
var cached_effective_move_speed := 0.0
var status_visual_material: ShaderMaterial = null
var slow_overlay_strength := 0.0
var burn_overlay_strength := 0.0
var bleed_overlay_strength := 0.0


func _ready() -> void:
	_apply_terrain_collision_profile()
	material_drop_random_generator.randomize()
	navigation_update_frame_offset = int(get_instance_id()) % maxi(
		navigation_update_interval_frames,
		FAR_STATIC_OBJECTIVE_UPDATE_INTERVAL_FRAMES
	)
	_refresh_collision_shape_cache()
	_cache_collision_shape_mirror_states()
	if animated_sprite != null:
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
	touch_damage_area.area_entered.connect(_on_touch_damage_area_area_entered)
	animated_sprite.animation_finished.connect(_on_animated_sprite_animation_finished)
	_apply_config()
	_update_movement_status_visuals()
	_refresh_status_process_enabled()


func _apply_terrain_collision_profile() -> void:
	var can_traverse_water := (
		terrain_traversal_types & DualGridTilemap.TraversalType.WATER
	) != 0
	if can_traverse_water:
		collision_mask &= ~WATER_TERRAIN_COLLISION_LAYER
	else:
		collision_mask |= WATER_TERRAIN_COLLISION_LAYER


func _process(delta: float) -> void:
	if collectible_status_effects.is_empty() and move_speed_modifiers.is_empty():
		return
	_update_collectible_status_effects(delta)
	_update_movement_status_visuals()


func _refresh_status_process_enabled() -> void:
	if is_dead:
		set_process(false)
		return
	if is_multiplayer_proxy:
		return
	set_process(not collectible_status_effects.is_empty() or not move_speed_modifiers.is_empty())


func setup(enemy_config: EnemyConfig, player: Player, shared_pathfinder: Node = null) -> void:
	config = enemy_config
	target_player = player
	objective_target = player
	reward_player = player
	pathfinder = shared_pathfinder
	if navigation_flow_context != null:
		navigation_flow_context.invalidate()
	_apply_config()


func set_target_player(player: Player) -> void:
	if target_player == player:
		reward_player = player
		if objective_target == null:
			objective_target = player
			_clear_cached_navigation_move_direction()
		return

	var previous_target := target_player
	target_player = player
	reward_player = player
	if objective_target == null or objective_target == previous_target:
		objective_target = player
		_clear_cached_navigation_move_direction()


func set_objective_target(target: Node2D) -> void:
	if objective_target == target:
		return
	objective_target = target
	_clear_cached_navigation_move_direction()


func set_reward_player(player: Player) -> void:
	reward_player = player


func _request_xirang_reward(
	amount: int,
	reward_target: Player,
	spawn_position: Vector2,
	landing_offset: Vector2 = Vector2.ZERO
) -> bool:
	var current_scene := get_tree().current_scene
	if current_scene == null or not current_scene.has_method("spawn_xirang_reward"):
		return false
	return bool(current_scene.call(
		"spawn_xirang_reward",
		amount,
		reward_target,
		spawn_position,
		landing_offset
	))


func is_objective_targeting_player() -> bool:
	return (
		objective_target != null
		and is_instance_valid(objective_target)
		and target_player != null
		and is_instance_valid(target_player)
		and objective_target == target_player
	)


func set_pathfinder(shared_pathfinder: Node) -> void:
	pathfinder = shared_pathfinder
	if navigation_flow_context != null:
		navigation_flow_context.invalidate()


func configure_multiplayer_proxy() -> void:
	is_multiplayer_proxy = true
	target_player = null
	objective_target = null
	reward_player = null
	pathfinder = null
	touched_player = null
	touching_players.clear()
	touched_plant = null
	touching_plants.clear()
	touch_damage_cooldown_left = 0.0
	proxy_action_animation_name_in_use = &""
	_update_movement_status_visuals()
	set_physics_process(false)
	set_process(false)
	collision_layer = 4
	collision_mask = 0
	_disable_proxy_area_collisions(self)
	_ensure_multiplayer_proxy_move_animation()


func remove_for_home_escape() -> bool:
	if is_dead:
		return false
	is_dead = true
	velocity = Vector2.ZERO
	set_process(false)
	set_physics_process(false)
	touched_player = null
	touching_players.clear()
	touched_plant = null
	touching_plants.clear()
	objective_target = null
	proxy_action_animation_name_in_use = &""
	proxy_action_restore_token += 1
	_set_collision_shapes_disabled(body_collision_shapes, true)
	_set_collision_shapes_disabled(touch_damage_shapes, true)
	if touch_damage_area != null:
		touch_damage_area.set_deferred("monitoring", false)
		touch_damage_area.set_deferred("monitorable", false)
	visible = false
	queue_free()
	return true


func apply_multiplayer_proxy_motion(proxy_position: Vector2, proxy_velocity: Vector2) -> void:
	global_position = proxy_position
	velocity = proxy_velocity
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
	velocity = Vector2.ZERO
	_update_movement_status_visuals()
	set_process(false)
	touched_player = null
	touching_players.clear()
	touched_plant = null
	touching_plants.clear()
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

	physical_defense_modifiers[source_id] = amount


func remove_physical_defense_modifier(source_id: int) -> void:
	physical_defense_modifiers.erase(source_id)


func get_effective_physical_defense() -> int:
	var total := config.physical_defense if config != null else 0
	for source_id in physical_defense_modifiers:
		total += maxi(int(physical_defense_modifiers[source_id]), 0)
	return maxi(total, 0)


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


func _refresh_effective_move_speed_cache() -> void:
	var total := config.move_speed if config != null else 0.0
	for source_id in move_speed_modifiers:
		total *= maxf(float(move_speed_modifiers[source_id]), 0.0)
	cached_effective_move_speed = maxf(total, 0.0)


func _update_movement_status_visuals() -> void:
	if is_dead:
		_set_slow_overlay_strength(0.0)
		_set_burn_overlay_strength(0.0)
		_set_bleed_overlay_strength(0.0)
		speed_trail_effect.call("set_effect_active", false)
		return

	var is_slowed := _has_move_speed_modifier_below_default()
	_set_slow_overlay_strength(SLOW_OVERLAY_ACTIVE_STRENGTH if is_slowed else 0.0)
	_set_burn_overlay_strength(BURN_OVERLAY_ACTIVE_STRENGTH if _has_collectible_status(&"burn") else 0.0)
	_set_bleed_overlay_strength(BLEED_OVERLAY_ACTIVE_STRENGTH if _has_collectible_status(&"bleed") else 0.0)

	var is_temporarily_hasted := _has_move_speed_modifier_above_default()
	var is_moving := velocity.length_squared() > 0.001
	speed_trail_effect.call("set_effect_active", is_temporarily_hasted and is_moving)
	if is_moving:
		speed_trail_effect.call("set_motion_direction", velocity)


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
	var active_burn_damage_key: Variant = _get_highest_damage_status_key(&"burn")
	for effect_key in collectible_status_effects.keys():
		var status: Dictionary = collectible_status_effects.get(effect_key, {})
		if status.is_empty():
			collectible_status_effects.erase(effect_key)
			continue
		var time_left := float(status.get("time_left", 0.0)) - delta
		if time_left <= 0.0 or is_dead:
			_remove_collectible_status(effect_key, status)
			continue
		status["time_left"] = time_left
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
		cached_effective_move_speed = 0.0
		return

	terrain_traversal_types = config.terrain_traversal_types
	_apply_terrain_collision_profile()
	current_health = config.max_health
	_refresh_effective_move_speed_cache()
	_play_scene_animation(config.move_animation_name)


func _play_scene_animation(animation_name: StringName) -> bool:
	if not _has_scene_animation(animation_name):
		return false
	animated_sprite.play(animation_name)
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
	if animated_sprite.animation == config.move_animation_name and animated_sprite.is_playing():
		return

	_play_scene_animation(config.move_animation_name)


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
	collision_shape = null
	if not body_collision_shapes.is_empty():
		collision_shape = body_collision_shapes[0]
	touch_damage_shape = null
	if not touch_damage_shapes.is_empty():
		touch_damage_shape = touch_damage_shapes[0]
	body_collision_extent_radius = _get_collision_shapes_extent_radius(body_collision_shapes)
	body_collision_half_extents = _get_collision_shapes_half_extents(body_collision_shapes)


func get_configured_body_collision_half_extents() -> Vector2:
	var shape_nodes: Array[CollisionShape2D] = body_collision_shapes
	if shape_nodes.is_empty():
		shape_nodes = _collect_direct_collision_shapes(self)
	return _get_collision_shapes_half_extents(shape_nodes)


func _collect_direct_collision_shapes(parent_node: Node) -> Array[CollisionShape2D]:
	var shapes: Array[CollisionShape2D] = []
	if parent_node == null:
		return shapes
	for child in parent_node.get_children():
		var shape_node := child as CollisionShape2D
		if shape_node != null:
			shapes.append(shape_node)
	return shapes


func _cache_collision_shape_mirror_states() -> void:
	collision_shape_mirror_states.clear()
	var all_shape_nodes: Array[CollisionShape2D] = []
	all_shape_nodes.append_array(body_collision_shapes)
	all_shape_nodes.append_array(touch_damage_shapes)
	for shape_node in all_shape_nodes:
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
	var all_shape_nodes: Array[CollisionShape2D] = []
	all_shape_nodes.append_array(body_collision_shapes)
	all_shape_nodes.append_array(touch_damage_shapes)
	for shape_node in all_shape_nodes:
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
			return _cache_navigation_move_direction(direct_direction, true)
	elif _is_near_static_objective(target_node):
		# Near a static objective, a full body sweep is cheaper than another flow
		# query when the remaining corridor is open. This is also the physical
		# final-approach tier: a flow target may resolve to the nearest conservative
		# grid cell, but Home damage still happens only after the body actually
		# enters the gate Area2D.
		var direct_direction := _get_collision_safe_near_static_objective_direction(
			target_node.global_position
		)
		if direct_direction != Vector2.ZERO:
			return _cache_navigation_move_direction(direct_direction, true)

	return _get_flow_navigation_move_direction(
		target_node,
		shared_pathfinder,
		waypoint_arrival_distance
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
				return _cache_navigation_move_direction(Vector2.ZERO)
			var move_direction := _get_waypoint_move_direction(
				waypoint,
				waypoint_arrival_distance
			)
			return _cache_navigation_move_direction(move_direction)
		GridPathfinder.NavigationStepStatus.DEFERRED:
			if _is_cached_navigation_direction_shape_safe():
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
	if test_move(global_transform, probe_motion):
		return Vector2.ZERO

	# Physical clearance alone can still place a large body inside a grid cell
	# that is deliberately blocked by the inflated navigation profile. Keep the
	# cheap straight-line tier outside that conservative band, otherwise the
	# later handoff to flow navigation may have no valid start cell.
	var grid_pathfinder := pathfinder as GridPathfinder
	if (
		grid_pathfinder != null
		and not grid_pathfinder.is_navigation_segment_walkable(
			global_position,
			global_position + probe_motion,
			_get_body_collision_half_extents(),
			terrain_traversal_types
		)
	):
		return Vector2.ZERO
	return direct_direction


func _get_collision_safe_near_static_objective_direction(
	objective_position: Vector2
) -> Vector2:
	var offset := objective_position - global_position
	if offset == Vector2.ZERO:
		return Vector2.ZERO
	# Sweep the complete remaining segment with the real CharacterBody shape.
	# The near tier continues through move_and_slide(), so this check is only a
	# line-of-sight shortcut and never enables the lightweight far translation.
	if test_move(global_transform, offset):
		return Vector2.ZERO
	return offset.normalized()


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
	if cached_navigation_move_direction == Vector2.ZERO:
		return Engine.get_physics_frames() >= navigation_zero_direction_retry_frame
	var interval := _get_navigation_update_interval_frames(target_node)
	if interval <= 1:
		return true
	return (Engine.get_physics_frames() + navigation_update_frame_offset) % interval == 0


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


func _cache_navigation_move_direction(
	move_direction: Vector2,
	uses_direct_objective_approach: bool = false
) -> Vector2:
	cached_navigation_move_direction = move_direction
	cached_navigation_uses_direct_objective_approach = (
		uses_direct_objective_approach and move_direction != Vector2.ZERO
	)
	if move_direction == Vector2.ZERO:
		navigation_zero_direction_retry_frame = (
			Engine.get_physics_frames()
			+ _get_navigation_update_interval_frames(objective_target)
		)
	else:
		navigation_zero_direction_retry_frame = 0
	return move_direction


func _clear_cached_navigation_move_direction() -> void:
	cached_navigation_move_direction = Vector2.ZERO
	cached_navigation_uses_direct_objective_approach = false
	navigation_zero_direction_retry_frame = 0
	if navigation_flow_context != null:
		navigation_flow_context.invalidate()


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
	if not test_move(global_transform, motion):
		return true

	# test_move() can report an existing side contact even when the requested
	# motion is exactly tangent to that surface. Treat that contact as safe so an
	# enemy touching a wall can still follow a flow-field waypoint along it. A
	# motion pointing into the collision normal remains blocked.
	test_move(global_transform, motion, navigation_collision_probe)
	return normalized_direction.dot(navigation_collision_probe.get_normal()) >= -0.001


func _move_until_player_contact() -> void:
	if _has_player_contact():
		velocity = Vector2.ZERO
		return
	if velocity == Vector2.ZERO:
		return
	if _can_use_far_static_objective_linear_movement():
		global_position += velocity * get_physics_process_delta_time()
		return
	move_and_slide()


func _can_use_far_static_objective_linear_movement() -> bool:
	return (
		cached_navigation_uses_direct_objective_approach
		and _is_far_static_objective(objective_target)
	)


func _has_player_contact() -> bool:
	return not touching_plants.is_empty() or not touching_players.is_empty()


func _clear_touching_players() -> void:
	touching_players.clear()
	touched_player = null
	touching_plants.clear()
	touched_plant = null


func _on_touch_damage_area_body_entered(body: Node2D) -> void:
	if is_dead:
		return

	var plant := body as PlantDefense
	if plant != null:
		if plant.is_dead:
			return
		touching_plants[plant.get_instance_id()] = plant
		touched_plant = plant
		var died_callback := _on_touched_plant_died.bind(plant)
		if not plant.died.is_connected(died_callback):
			plant.died.connect(died_callback, CONNECT_ONE_SHOT)
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
		touching_plants.erase(plant.get_instance_id())
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
		if is_instance_valid(plant) and not plant.is_dead:
			return plant
	touching_plants.clear()
	return null


func _on_touched_plant_died(plant: PlantDefense) -> void:
	if plant == null:
		return
	touching_plants.erase(plant.get_instance_id())
	if touched_plant == plant:
		touched_plant = _select_touching_plant()


func _on_touch_damage_area_area_entered(area: Area2D) -> void:
	if is_dead:
		return

	var bullet := area as Bullet
	if bullet == null:
		return

	bullet.try_hit_enemy(self)


func _update_touch_damage(delta: float) -> void:
	if touch_damage_cooldown_left > 0.0:
		touch_damage_cooldown_left = maxf(touch_damage_cooldown_left - delta, 0.0)
	if touching_plants.is_empty() and touching_players.is_empty():
		touched_plant = null
		touched_player = null
		return

	if touched_plant == null or not is_instance_valid(touched_plant) or touched_plant.is_dead:
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
	if touched_plant != null and is_instance_valid(touched_plant) and not touched_plant.is_dead:
		var impact_direction := global_position.direction_to(touched_plant.global_position)
		if touched_plant.receive_damage(
			config.attack_damage,
			self,
			impact_direction,
			EnemyConfig.DamageType.PHYSICAL
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
			&"enemy_touch"
		)
		touch_damage_cooldown_left = touch_damage_interval
		return
	touched_player.apply_damage(config.attack_damage)
	touch_damage_cooldown_left = touch_damage_interval


func _get_multiplayer_touch_source_id() -> int:
	var net_id := int(get_meta("net_id", get_instance_id()))
	var tick := int(Time.get_ticks_msec())
	return maxi(net_id, 1) * 1000000 + tick

func _play_hit_particles(impact_direction: Vector2) -> void:
	if impact_direction == Vector2.ZERO:
		return

	hit_particles.rotation = impact_direction.angle()
	hit_particles.restart()
	hit_particles.emitting = true


func _die() -> void:
	if is_dead:
		return

	_try_drop_material()
	is_dead = true
	defeated.emit(self)
	velocity = Vector2.ZERO
	_update_movement_status_visuals()
	set_process(false)
	touched_player = null
	touching_players.clear()
	touched_plant = null
	touching_plants.clear()
	_set_collision_shapes_disabled(body_collision_shapes, true)
	_set_collision_shapes_disabled(touch_damage_shapes, true)
	touch_damage_area.set_deferred("monitoring", false)
	touch_damage_area.set_deferred("monitorable", false)
	AUDIO_LIMITER.play_enemy_death(death_audio)
	_start_death_sequence()


func _try_drop_material() -> void:
	if is_multiplayer_proxy:
		return
	if material_drop_random_generator.randf() >= MATERIAL_DROP_CHANCE:
		return
	var material := _pick_material_drop_config(
		material_drop_random_generator.randf_range(0.0, _get_material_drop_total_weight())
	)
	if material == null:
		return
	call_deferred("_spawn_material_drop", material, global_position)


func _pick_material_drop_config(target_weight: float) -> PickupConfig:
	var total_weight := _get_material_drop_total_weight()
	if total_weight <= 0.0:
		return null
	var clamped_target := clampf(target_weight, 0.0, total_weight)
	var accumulated_weight := 0.0
	for material in MATERIAL_DROP_CONFIGS:
		if material == null or material.drop_weight <= 0.0:
			continue
		accumulated_weight += material.drop_weight
		if clamped_target < accumulated_weight:
			return material
	return MATERIAL_DROP_CONFIGS.back()


func _get_material_drop_total_weight() -> float:
	var total_weight := 0.0
	for material in MATERIAL_DROP_CONFIGS:
		if material != null:
			total_weight += maxf(material.drop_weight, 0.0)
	return total_weight


func _spawn_material_drop(material: PickupConfig, spawn_position: Vector2) -> void:
	if material == null:
		return
	var drop_parent := get_parent()
	if drop_parent == null:
		return
	var pickup := MATERIAL_PICKUP_SCENE.instantiate() as Pickup
	if pickup == null:
		return
	pickup.config = material
	drop_parent.add_child(pickup)
	pickup.global_position = spawn_position


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
