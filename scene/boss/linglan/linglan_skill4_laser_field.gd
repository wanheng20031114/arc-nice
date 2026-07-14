extends Area2D
class_name LinglanSkill4LaserField

const PLAYER_COLLISION_MASK := 2

static var _next_damage_event_source_id: int = 1

@export var damage: int = 50
@export var core_width: float = 6.0
@export var warning_core_width: float = 1.5
@export var warning_duration: float = 1.6
@export var shrink_duration: float = 3.0
@export var contact_damage_interval: float = 0.5
@export var damage_enabled: bool = true
@export var lifetime_duration: float = 0.0

@onready var top_shape: CollisionShape2D = $TopShape
@onready var bottom_shape: CollisionShape2D = $BottomShape
@onready var left_shape: CollisionShape2D = $LeftShape
@onready var right_shape: CollisionShape2D = $RightShape
@onready var top_glow: Line2D = $VisualRoot/TopGlow
@onready var top_core: Line2D = $VisualRoot/TopCore
@onready var top_center: Line2D = $VisualRoot/TopCenter
@onready var bottom_glow: Line2D = $VisualRoot/BottomGlow
@onready var bottom_core: Line2D = $VisualRoot/BottomCore
@onready var bottom_center: Line2D = $VisualRoot/BottomCenter
@onready var left_glow: Line2D = $VisualRoot/LeftGlow
@onready var left_core: Line2D = $VisualRoot/LeftCore
@onready var left_center: Line2D = $VisualRoot/LeftCenter
@onready var right_glow: Line2D = $VisualRoot/RightGlow
@onready var right_core: Line2D = $VisualRoot/RightCore
@onready var right_center: Line2D = $VisualRoot/RightCenter

var start_min := Vector2(-48.0, -16.0)
var start_max := Vector2(288.0, 256.0)
var final_min := Vector2(32.0, 64.0)
var final_max := Vector2(208.0, 176.0)
var elapsed: float = 0.0
var overlapping_players: Dictionary[int, Player] = {}
var player_next_damage_times: Dictionary[int, float] = {}
var _last_geometry_progress: float = -1.0
var _last_geometry_warning: bool = false
var _geometry_update_count: int = 0
var field_id: int = 0
var source_type: StringName = &"linglan_skill4_laser"
var field_finished: bool = false


func _ready() -> void:
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)
	_apply_current_geometry()
	_set_damage_collision_enabled(damage_enabled)


func setup(
	initial_start_min: Vector2,
	initial_start_max: Vector2,
	initial_final_min: Vector2,
	initial_final_max: Vector2,
	initial_damage: int,
	initial_core_width: float,
	initial_shrink_duration: float,
	initial_warning_duration: float = 1.6,
	initial_damage_enabled: bool = true,
	initial_lifetime_duration: float = 0.0
) -> void:
	start_min = _normalized_min(initial_start_min, initial_start_max)
	start_max = _normalized_max(initial_start_min, initial_start_max)
	final_min = _normalized_min(initial_final_min, initial_final_max)
	final_max = _normalized_max(initial_final_min, initial_final_max)
	damage = maxi(initial_damage, 0)
	core_width = maxf(initial_core_width, 1.0)
	shrink_duration = maxf(initial_shrink_duration, 0.01)
	warning_duration = maxf(initial_warning_duration, 0.0)
	damage_enabled = initial_damage_enabled
	lifetime_duration = maxf(initial_lifetime_duration, 0.0)
	elapsed = 0.0
	field_finished = false
	overlapping_players.clear()
	player_next_damage_times.clear()
	_invalidate_geometry_cache()
	if is_node_ready():
		_apply_current_geometry()
		_set_damage_collision_enabled(damage_enabled)


func setup_multiplayer_visual_only() -> void:
	damage_enabled = false
	_set_damage_collision_enabled(false)


func _set_damage_collision_enabled(enabled: bool) -> void:
	if not enabled:
		overlapping_players.clear()
		player_next_damage_times.clear()
	monitoring = enabled
	monitorable = enabled
	collision_layer = 128 if enabled else 0
	collision_mask = PLAYER_COLLISION_MASK if enabled else 0
	for shape_node in [top_shape, bottom_shape, left_shape, right_shape]:
		if shape_node != null:
			shape_node.disabled = not enabled


func get_laser_progress() -> float:
	var active_elapsed := maxf(elapsed - warning_duration, 0.0)
	return clampf(active_elapsed / maxf(shrink_duration, 0.01), 0.0, 1.0)


func is_warning_active() -> bool:
	return elapsed < warning_duration


func get_current_bounds() -> Rect2:
	var progress := get_laser_progress()
	var current_min := start_min.lerp(final_min, progress)
	var current_max := start_max.lerp(final_max, progress)
	return Rect2(current_min, current_max - current_min)


func _physics_process(delta: float) -> void:
	if field_finished:
		return
	var safe_delta := maxf(delta, 0.0)
	elapsed += safe_delta
	_apply_current_geometry()
	if damage_enabled:
		_update_overlapping_player_damage()
	if lifetime_duration > 0.0 and elapsed >= lifetime_duration:
		finish()


func finish() -> void:
	if field_finished:
		return
	field_finished = true
	_set_damage_collision_enabled(false)
	set_physics_process(false)
	queue_free()


func _apply_current_geometry() -> void:
	var progress := get_laser_progress()
	var warning_active := is_warning_active()
	if (
		is_equal_approx(progress, _last_geometry_progress)
		and warning_active == _last_geometry_warning
	):
		return
	_last_geometry_progress = progress
	_last_geometry_warning = warning_active
	_geometry_update_count += 1

	var current_min := start_min.lerp(final_min, progress)
	var current_max := start_max.lerp(final_max, progress)
	var bounds := Rect2(current_min, current_max - current_min)
	var min_position := bounds.position
	var max_position := bounds.end
	var top_a := Vector2(min_position.x, min_position.y)
	var top_b := Vector2(max_position.x, min_position.y)
	var bottom_a := Vector2(min_position.x, max_position.y)
	var bottom_b := Vector2(max_position.x, max_position.y)
	var left_a := Vector2(min_position.x, min_position.y)
	var left_b := Vector2(min_position.x, max_position.y)
	var right_a := Vector2(max_position.x, min_position.y)
	var right_b := Vector2(max_position.x, max_position.y)

	_set_line_points(top_glow, top_a, top_b)
	_set_line_points(top_core, top_a, top_b)
	_set_line_points(top_center, top_a, top_b)
	_set_line_points(bottom_glow, bottom_a, bottom_b)
	_set_line_points(bottom_core, bottom_a, bottom_b)
	_set_line_points(bottom_center, bottom_a, bottom_b)
	_set_line_points(left_glow, left_a, left_b)
	_set_line_points(left_core, left_a, left_b)
	_set_line_points(left_center, left_a, left_b)
	_set_line_points(right_glow, right_a, right_b)
	_set_line_points(right_core, right_a, right_b)
	_set_line_points(right_center, right_a, right_b)

	var active_core_width := _get_active_core_width()
	_apply_current_line_widths(active_core_width)

	var horizontal_length := maxf(absf(max_position.x - min_position.x), active_core_width)
	var vertical_length := maxf(absf(max_position.y - min_position.y), active_core_width)
	_set_rectangle_shape(
		top_shape,
		Vector2((min_position.x + max_position.x) * 0.5, min_position.y),
		Vector2(horizontal_length, active_core_width)
	)
	_set_rectangle_shape(
		bottom_shape,
		Vector2((min_position.x + max_position.x) * 0.5, max_position.y),
		Vector2(horizontal_length, active_core_width)
	)
	_set_rectangle_shape(
		left_shape,
		Vector2(min_position.x, (min_position.y + max_position.y) * 0.5),
		Vector2(active_core_width, vertical_length)
	)
	_set_rectangle_shape(
		right_shape,
		Vector2(max_position.x, (min_position.y + max_position.y) * 0.5),
		Vector2(active_core_width, vertical_length)
	)


func _invalidate_geometry_cache() -> void:
	_last_geometry_progress = -1.0


func _get_active_core_width() -> float:
	if is_warning_active():
		return maxf(warning_core_width, 1.0)
	return core_width


func _apply_current_line_widths(active_core_width: float) -> void:
	var glow_width := active_core_width * (4.0 if is_warning_active() else 3.0)
	var center_width := maxf(active_core_width * (0.5 if is_warning_active() else 0.3333), 1.0)
	for line in [top_glow, bottom_glow, left_glow, right_glow]:
		if line != null:
			line.width = glow_width
	for line in [top_core, bottom_core, left_core, right_core]:
		if line != null:
			line.width = active_core_width
	for line in [top_center, bottom_center, left_center, right_center]:
		if line != null:
			line.width = center_width


func _set_line_points(line: Line2D, start_point: Vector2, end_point: Vector2) -> void:
	if line == null:
		return
	line.points = PackedVector2Array([start_point, end_point])


func _set_rectangle_shape(shape_node: CollisionShape2D, center: Vector2, size: Vector2) -> void:
	if shape_node == null:
		return
	var rectangle := shape_node.shape as RectangleShape2D
	if rectangle == null:
		return
	rectangle.size = size
	shape_node.position = center


func _on_body_entered(body: Node2D) -> void:
	var player := body as Player
	if player == null:
		return
	var player_id := player.get_instance_id()
	overlapping_players[player_id] = player
	if damage_enabled:
		_apply_player_damage(player)


func _on_body_exited(body: Node2D) -> void:
	var player := body as Player
	if player == null:
		return
	var player_id := player.get_instance_id()
	overlapping_players.erase(player_id)


func _update_overlapping_player_damage() -> void:
	if overlapping_players.is_empty():
		return
	var stale_player_ids: Array[int] = []
	for player_id in overlapping_players:
		var player := overlapping_players[player_id]
		if not is_instance_valid(player) or player.is_dead:
			stale_player_ids.append(player_id)
			continue
		if player_next_damage_times.get(player_id, 0.0) > elapsed:
			continue
		_apply_player_damage(player)
	for player_id in stale_player_ids:
		overlapping_players.erase(player_id)
		player_next_damage_times.erase(player_id)


func _apply_player_damage(player: Player) -> void:
	if player == null or player.is_dead:
		return
	var player_id := player.get_instance_id()
	if player_next_damage_times.get(player_id, 0.0) > elapsed:
		return
	if _try_report_multiplayer_player_hit(player):
		player_next_damage_times[player_id] = elapsed + maxf(contact_damage_interval, 0.0)
		return
	player.apply_damage(damage, EnemyConfig.DamageType.MAGIC)
	# Preserve the authored contact cadence even when dash/invincibility rejects
	# this pulse; otherwise an overlapping player would be retried every frame.
	player_next_damage_times[player_id] = elapsed + maxf(contact_damage_interval, 0.0)


func _try_report_multiplayer_player_hit(player: Player) -> bool:
	var source_id := _allocate_damage_event_source_id()
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
		EnemyConfig.DamageType.MAGIC
	))


static func _allocate_damage_event_source_id() -> int:
	var source_id := maxi(_next_damage_event_source_id, 1)
	_next_damage_event_source_id = source_id + 1
	return source_id


func _normalized_min(first: Vector2, second: Vector2) -> Vector2:
	return Vector2(minf(first.x, second.x), minf(first.y, second.y))


func _normalized_max(first: Vector2, second: Vector2) -> Vector2:
	return Vector2(maxf(first.x, second.x), maxf(first.y, second.y))
