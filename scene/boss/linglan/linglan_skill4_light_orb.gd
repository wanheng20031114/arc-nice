extends Area2D
class_name LinglanSkill4LightOrb

const PLAYER_COLLISION_MASK := 2
const DAMAGE_QUERY_MAX_RESULTS := 16
const PULSE_MIN := 0.9
const PULSE_MAX := 1.12

@export var speed: float = 40.0
@export var damage: int = 50
@export var orb_radius: float = 8.0
@export var damage_radius: float = 6.0
@export var max_lifetime: float = 10.0

@onready var collision_shape: CollisionShape2D = $CollisionShape2D
@onready var visual_root: Node2D = $VisualRoot

var direction := Vector2.RIGHT
var elapsed: float = 0.0
var remaining_lifetime: float = 10.0
var damaged_player_ids: Dictionary = {}
var projectile_id: int = 0
var owner_peer_id: int = 0
var source_type: StringName = &"linglan_skill4_orb"


func _ready() -> void:
	body_entered.connect(_on_body_entered)
	_duplicate_polygon_materials()
	_apply_current_radius()
	_update_visual_pulse()


func setup(
	initial_direction: Vector2,
	initial_damage: int,
	initial_speed: float,
	initial_lifetime: float,
	initial_radius: float = 8.0,
	initial_damage_radius: float = 6.0
) -> void:
	direction = initial_direction.normalized() if initial_direction != Vector2.ZERO else Vector2.RIGHT
	damage = maxi(initial_damage, 0)
	speed = maxf(initial_speed, 0.0)
	max_lifetime = maxf(initial_lifetime, 0.01)
	remaining_lifetime = max_lifetime
	orb_radius = maxf(initial_radius, 1.0)
	damage_radius = clampf(initial_damage_radius, 1.0, orb_radius)
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


func get_current_radius() -> float:
	return orb_radius


func get_damage_radius() -> float:
	return damage_radius


func _physics_process(delta: float) -> void:
	var safe_delta := maxf(delta, 0.0)
	elapsed += safe_delta
	remaining_lifetime = maxf(remaining_lifetime - safe_delta, 0.0)
	if remaining_lifetime <= 0.0:
		queue_free()
		return
	global_position += direction * speed * safe_delta
	_update_visual_pulse()
	_apply_overlap_damage()


func _apply_current_radius() -> void:
	if collision_shape == null:
		return
	var circle_shape := collision_shape.shape as CircleShape2D
	if circle_shape != null:
		circle_shape.radius = damage_radius


func _update_visual_pulse() -> void:
	if visual_root == null:
		return
	var wave := (sin(elapsed * TAU * 3.5) + 1.0) * 0.5
	var pulse := lerpf(PULSE_MIN, PULSE_MAX, wave)
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
	player.apply_damage(
		damage,
		EnemyConfig.DamageType.MAGIC,
		_get_player_damage_context(player)
	)


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
		source_type,
		EnemyConfig.DamageType.MAGIC,
		_get_source_direction_to_player(player),
		true
	))


func _get_player_damage_context(player: Player) -> Dictionary:
	return {
		"is_ranged": true,
		"source_direction": _get_source_direction_to_player(player),
	}


func _get_source_direction_to_player(player: Player) -> Vector2:
	if player == null:
		return Vector2.ZERO
	return player.global_position.direction_to(global_position)


func _get_damage_source_id() -> int:
	if projectile_id > 0:
		return projectile_id
	return get_instance_id()
