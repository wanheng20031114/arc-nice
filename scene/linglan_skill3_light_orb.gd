extends Area2D
class_name LinglanSkill3LightOrb

const PLAYER_COLLISION_MASK := 2
const DAMAGE_QUERY_MAX_RESULTS := 16
const FLASH_PULSE_MIN := 0.72
const FLASH_PULSE_MAX := 1.18
const EXPANDED_PULSE := 1.08

enum OrbState {
	FLYING,
	EXPANDED,
}

@export var speed: float = 90.0
@export var damage: int = 50
@export var base_radius: float = 15.0
@export var grow_scale: float = 3.0
@export var grow_delay: float = 2.2
@export var expanded_hold_duration: float = 0.5
@export var flash_lead_time: float = 2.0
@export var flash_frequency: float = 9.0

@onready var collision_shape: CollisionShape2D = $CollisionShape2D
@onready var visual_root: Node2D = $VisualRoot

var direction := Vector2.RIGHT
var elapsed: float = 0.0
var expanded_elapsed: float = 0.0
var orb_state: OrbState = OrbState.FLYING
var damaged_player_ids: Dictionary = {}
var projectile_id: int = 0
var owner_peer_id: int = 0
var source_type: StringName = &"linglan_skill3_orb"


func _ready() -> void:
	body_entered.connect(_on_body_entered)
	_duplicate_polygon_materials()
	_apply_current_radius()
	_update_visual_pulse()


func setup(
	initial_direction: Vector2,
	initial_damage: int,
	initial_speed: float,
	initial_grow_delay: float,
	initial_base_radius: float = 15.0,
	initial_grow_scale: float = 3.0,
	initial_expanded_hold_duration: float = 0.5,
	initial_flash_lead_time: float = 2.0
) -> void:
	direction = initial_direction.normalized() if initial_direction != Vector2.ZERO else Vector2.RIGHT
	damage = maxi(initial_damage, 0)
	speed = maxf(initial_speed, 0.0)
	grow_delay = maxf(initial_grow_delay, 0.0)
	base_radius = maxf(initial_base_radius, 1.0)
	grow_scale = maxf(initial_grow_scale, 1.0)
	expanded_hold_duration = maxf(initial_expanded_hold_duration, 0.0)
	flash_lead_time = maxf(initial_flash_lead_time, 0.0)
	rotation = direction.angle()
	if is_node_ready():
		_apply_current_radius()
		_update_visual_pulse()


func setup_multiplayer(
	new_projectile_id: int,
	new_owner_peer_id: int,
	new_source_type: StringName
) -> void:
	projectile_id = maxi(new_projectile_id, 0)
	owner_peer_id = new_owner_peer_id
	source_type = new_source_type


func is_flashing() -> bool:
	return orb_state == OrbState.FLYING and elapsed >= maxf(grow_delay - flash_lead_time, 0.0)


func is_expanded() -> bool:
	return orb_state == OrbState.EXPANDED


func get_current_radius() -> float:
	return base_radius * (grow_scale if is_expanded() else 1.0)


func get_visual_scale() -> Vector2:
	return visual_root.scale if visual_root != null else Vector2.ZERO


func _physics_process(delta: float) -> void:
	var safe_delta := maxf(delta, 0.0)
	if orb_state == OrbState.FLYING:
		elapsed += safe_delta
		global_position += direction * speed * safe_delta
		if elapsed + 0.0001 >= grow_delay:
			_grow()
	elif orb_state == OrbState.EXPANDED:
		expanded_elapsed += safe_delta
		if expanded_elapsed >= expanded_hold_duration:
			queue_free()
			return

	_update_visual_pulse()
	_apply_overlap_damage()


func _grow() -> void:
	if orb_state == OrbState.EXPANDED:
		return
	orb_state = OrbState.EXPANDED
	speed = 0.0
	expanded_elapsed = 0.0
	_apply_current_radius()
	_apply_overlap_damage()


func _apply_current_radius() -> void:
	if collision_shape != null:
		var circle_shape := collision_shape.shape as CircleShape2D
		if circle_shape != null:
			circle_shape.radius = get_current_radius()
	if visual_root != null:
		visual_root.scale = Vector2.ONE * (grow_scale if is_expanded() else 1.0)


func _update_visual_pulse() -> void:
	var pulse := 1.0
	if is_flashing():
		var wave := (sin(elapsed * TAU * flash_frequency) + 1.0) * 0.5
		pulse = lerpf(FLASH_PULSE_MIN, FLASH_PULSE_MAX, wave)
	elif is_expanded():
		pulse = EXPANDED_PULSE
	_set_visual_pulse(pulse)


func _set_visual_pulse(pulse: float) -> void:
	if visual_root == null:
		return
	for child in visual_root.get_children():
		var polygon := child as Polygon2D
		if polygon == null:
			continue
		var shader_material := polygon.material as ShaderMaterial
		if shader_material != null:
			shader_material.set_shader_parameter(&"pulse", pulse)


func _duplicate_polygon_materials() -> void:
	if visual_root == null:
		return
	for child in visual_root.get_children():
		var polygon := child as Polygon2D
		if polygon != null and polygon.material != null:
			polygon.material = polygon.material.duplicate()


func _on_body_entered(body: Node2D) -> void:
	_apply_player_damage(body as Player)


func _apply_overlap_damage() -> void:
	var circle_shape := collision_shape.shape as CircleShape2D
	if circle_shape == null:
		return
	var query := PhysicsShapeQueryParameters2D.new()
	query.shape = circle_shape
	query.transform = Transform2D(0.0, global_position)
	query.collision_mask = PLAYER_COLLISION_MASK
	query.collide_with_bodies = true
	query.collide_with_areas = false
	query.exclude = [get_rid()]

	var results := get_world_2d().direct_space_state.intersect_shape(query, DAMAGE_QUERY_MAX_RESULTS)
	for result in results:
		_apply_player_damage(result.get("collider") as Player)


func _apply_player_damage(player: Player) -> void:
	if player == null or player.is_dead:
		return
	var player_id := player.get_instance_id()
	if damaged_player_ids.has(player_id):
		return
	damaged_player_ids[player_id] = true
	if _try_report_multiplayer_player_hit(player):
		return
	player.apply_damage(damage)


func _try_report_multiplayer_player_hit(player: Player) -> bool:
	var source_id := _get_damage_source_id()
	if source_id <= 0:
		return false
	var current_scene := get_tree().current_scene
	if current_scene == null or not current_scene.has_method("request_multiplayer_player_damage"):
		return false
	return bool(current_scene.call(
		"request_multiplayer_player_damage",
		source_id,
		player.peer_id,
		damage,
		source_type
	))


func _get_damage_source_id() -> int:
	if projectile_id > 0:
		return projectile_id
	return get_instance_id()
