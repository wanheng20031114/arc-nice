extends CharacterBody2D
class_name Enemy

signal defeated(enemy: Enemy)

const BLINK_ENABLED_SHADER_PARAMETER := &"blink_enabled"
const DAMAGE_NUMBER_SCRIPT := preload("res://scene/damage_number.gd")
const DAMAGE_NUMBER_LIMIT := 80
const PATH_DIRECTION_PROBE_DISTANCE := 1.0

enum DeathSequenceStage {
	NONE,
	DEATH,
	EXPLOSION,
}

@export var config: EnemyConfig
@export var touch_damage_interval: float = 0.5
@export var hurt_blink_duration: float = 0.16

@onready var animated_sprite: AnimatedSprite2D = $AnimatedSprite2D
@onready var collision_shape: CollisionShape2D = null
@onready var touch_damage_area: Area2D = $TouchDamageArea
@onready var touch_damage_shape: CollisionShape2D = null
@onready var hit_particles: GPUParticles2D = $HitParticles
@onready var hit_audio: AudioStreamPlayer2D = $HitAudio
@onready var death_audio: AudioStreamPlayer2D = $DeathAudio

var target_player: Player = null
var pathfinder: Node = null
var current_health: int = 1
var is_dead: bool = false
var touch_damage_cooldown_left: float = 0.0
var touched_player: Player = null
var hurt_blink_time_left: float = 0.0
var death_sequence_stage: DeathSequenceStage = DeathSequenceStage.NONE
var death_animation_name_in_use: StringName = &""
var physical_defense_modifiers: Dictionary = {}
var is_multiplayer_proxy: bool = false
var last_damage_taken: int = 0
var body_collision_shapes: Array[CollisionShape2D] = []
var touch_damage_shapes: Array[CollisionShape2D] = []
var body_collision_extent_radius: float = 0.0
var body_collision_half_extents: Vector2 = Vector2.ZERO
var collision_shape_mirror_states: Dictionary = {}
var facing_left: bool = false


func _ready() -> void:
	_refresh_collision_shape_cache()
	_cache_collision_shape_mirror_states()
	_apply_facing_mirror()
	touch_damage_area.body_entered.connect(_on_touch_damage_area_body_entered)
	touch_damage_area.body_exited.connect(_on_touch_damage_area_body_exited)
	touch_damage_area.area_entered.connect(_on_touch_damage_area_area_entered)
	animated_sprite.animation_finished.connect(_on_animated_sprite_animation_finished)
	_apply_config()


func setup(enemy_config: EnemyConfig, player: Player, shared_pathfinder: Node = null) -> void:
	config = enemy_config
	target_player = player
	pathfinder = shared_pathfinder
	_apply_config()


func set_target_player(player: Player) -> void:
	target_player = player


func set_pathfinder(shared_pathfinder: Node) -> void:
	pathfinder = shared_pathfinder


func configure_multiplayer_proxy() -> void:
	is_multiplayer_proxy = true
	target_player = null
	pathfinder = null
	touched_player = null
	touch_damage_cooldown_left = 0.0
	set_physics_process(false)
	set_process(false)
	collision_layer = 4
	collision_mask = 0
	_disable_proxy_area_collisions(self)


func apply_multiplayer_proxy_motion(proxy_position: Vector2, proxy_velocity: Vector2) -> void:
	global_position = proxy_position
	velocity = proxy_velocity
	_set_facing_from_direction(proxy_velocity)


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
	damage_type: EnemyConfig.DamageType = EnemyConfig.DamageType.PHYSICAL
) -> bool:
	last_damage_taken = 0
	if is_dead:
		return false
	if amount <= 0:
		return false

	var final_damage := _calculate_incoming_damage(amount, damage_type)
	last_damage_taken = final_damage
	current_health -= final_damage
	show_damage_number(final_damage, impact_direction)
	play_multiplayer_damage_feedback(impact_direction)

	if current_health <= 0:
		_die()
		return true

	hit_audio.play()
	_start_hurt_blink()
	return true


func show_damage_number(amount: int, impact_direction: Vector2 = Vector2.ZERO) -> void:
	if amount <= 0:
		return
	var scene_root := get_tree().current_scene
	if scene_root == null:
		scene_root = get_parent()
	if scene_root == null:
		return
	var active_numbers := get_tree().get_nodes_in_group(&"damage_numbers")
	if active_numbers.size() >= DAMAGE_NUMBER_LIMIT:
		var oldest := active_numbers.front() as Node
		if oldest != null and is_instance_valid(oldest):
			oldest.queue_free()
	var number := DAMAGE_NUMBER_SCRIPT.new() as Node2D
	if number == null:
		return
	scene_root.add_child(number)
	number.setup(amount, global_position, impact_direction)


func play_multiplayer_damage_feedback(impact_direction: Vector2 = Vector2.ZERO) -> void:
	_play_hit_particles(impact_direction)

func add_physical_defense_modifier(source_id: int, amount: int) -> void:
	if source_id == 0:
		return
	if amount <= 0:
		return

	physical_defense_modifiers[source_id] = amount


func remove_physical_defense_modifier(source_id: int) -> void:
	physical_defense_modifiers.erase(source_id)


func get_effective_physical_defense() -> int:
	var total := config.physical_defense if config != null else 0
	for modifier in physical_defense_modifiers.values():
		total += maxi(modifier as int, 0)
	return maxi(total, 0)


func get_effective_magic_defense() -> int:
	return clampi(config.magic_defense if config != null else 0, 0, 100)


func _calculate_incoming_damage(
	amount: int,
	damage_type: EnemyConfig.DamageType
) -> int:
	match damage_type:
		EnemyConfig.DamageType.MAGIC:
			var defense_ratio := float(100 - get_effective_magic_defense()) / 100.0
			return maxi(floori(float(amount) * defense_ratio), 1)
		_:
			return maxi(amount - get_effective_physical_defense(), 1)


func _apply_config() -> void:
	if config == null:
		return

	current_health = config.max_health
	_play_scene_animation(config.move_animation_name)


func _play_scene_animation(animation_name: StringName) -> bool:
	if not _has_scene_animation(animation_name):
		return false
	animated_sprite.play(animation_name)
	return true


func _has_scene_animation(animation_name: StringName) -> bool:
	if animated_sprite == null:
		return false
	if animated_sprite.sprite_frames == null:
		return false
	return animated_sprite.sprite_frames.has_animation(animation_name)


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
	facing_left = new_facing_left
	if animated_sprite != null:
		animated_sprite.flip_h = facing_left
	_apply_facing_mirror()


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


func _get_axis_aligned_waypoint_direction(waypoint: Vector2, arrival_distance: float) -> Vector2:
	var offset := waypoint - global_position
	if offset == Vector2.ZERO:
		return Vector2.ZERO

	var deadzone := maxf(arrival_distance, 0.0)
	var abs_x := absf(offset.x)
	var abs_y := absf(offset.y)
	if abs_x <= deadzone and abs_y > deadzone:
		return _choose_unblocked_axis_direction(Vector2(0.0, signf(offset.y)))
	if abs_y <= deadzone and abs_x > deadzone:
		return _choose_unblocked_axis_direction(Vector2(signf(offset.x), 0.0))
	if abs_x >= abs_y:
		return _choose_unblocked_axis_direction(Vector2(signf(offset.x), 0.0), Vector2(0.0, signf(offset.y)))
	return _choose_unblocked_axis_direction(Vector2(0.0, signf(offset.y)), Vector2(signf(offset.x), 0.0))


func _choose_unblocked_axis_direction(primary_direction: Vector2, secondary_direction: Vector2 = Vector2.ZERO) -> Vector2:
	if primary_direction == Vector2.ZERO:
		return secondary_direction
	if not test_move(global_transform, primary_direction * PATH_DIRECTION_PROBE_DISTANCE):
		return primary_direction
	if secondary_direction != Vector2.ZERO and not test_move(global_transform, secondary_direction * PATH_DIRECTION_PROBE_DISTANCE):
		return secondary_direction
	return Vector2.ZERO


func _on_touch_damage_area_body_entered(body: Node2D) -> void:
	if is_dead:
		return

	var player := body as Player
	if player == null:
		return

	touched_player = player
	_try_deal_touch_damage()


func _on_touch_damage_area_body_exited(body: Node2D) -> void:
	if body == touched_player:
		touched_player = null


func _on_touch_damage_area_area_entered(area: Area2D) -> void:
	if is_dead:
		return

	var bullet := area as Bullet
	if bullet == null:
		return

	var damaged := apply_damage(bullet.damage, -bullet.direction)
	if damaged:
		bullet.queue_free()


func _update_touch_damage(delta: float) -> void:
	if touch_damage_cooldown_left > 0.0:
		touch_damage_cooldown_left = maxf(touch_damage_cooldown_left - delta, 0.0)

	if touched_player == null:
		return
	if not is_instance_valid(touched_player):
		touched_player = null
		return
	if touch_damage_cooldown_left > 0.0:
		return

	_try_deal_touch_damage()


func _try_deal_touch_damage() -> void:
	if touched_player == null:
		return
	if config == null:
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

func _start_hurt_blink() -> void:
	hurt_blink_time_left = hurt_blink_duration
	_set_hurt_blink_enabled(true)


func _update_hurt_blink(delta: float) -> void:
	if hurt_blink_time_left <= 0.0:
		return

	hurt_blink_time_left = maxf(hurt_blink_time_left - delta, 0.0)
	if hurt_blink_time_left > 0.0:
		return

	_set_hurt_blink_enabled(false)


func _set_hurt_blink_enabled(enabled: bool) -> void:
	var sprite_material := animated_sprite.material as ShaderMaterial
	if sprite_material != null:
		sprite_material.set_shader_parameter(BLINK_ENABLED_SHADER_PARAMETER, enabled)


func _play_hit_particles(impact_direction: Vector2) -> void:
	if impact_direction == Vector2.ZERO:
		return

	hit_particles.rotation = impact_direction.angle()
	hit_particles.restart()
	hit_particles.emitting = true


func _die() -> void:
	if is_dead:
		return

	is_dead = true
	defeated.emit(self)
	velocity = Vector2.ZERO
	touched_player = null
	hurt_blink_time_left = 0.0
	_set_hurt_blink_enabled(false)
	_set_collision_shapes_disabled(body_collision_shapes, true)
	_set_collision_shapes_disabled(touch_damage_shapes, true)
	touch_damage_area.set_deferred("monitoring", false)
	touch_damage_area.set_deferred("monitorable", false)
	death_audio.play()
	_start_death_sequence()


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

	return _play_scene_animation(animation_name)


func _on_animated_sprite_animation_finished() -> void:
	if not is_dead:
		return
	if death_animation_name_in_use == &"":
		return
	if animated_sprite.animation != death_animation_name_in_use:
		return

	_finish_after_death_animation()
