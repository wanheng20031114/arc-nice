extends Area2D
class_name CollectibleMoonShield

const DAMAGE_REDUCTION := 0.5
const VISUAL_BASE_RADIUS := 64.0

@onready var collision_shape: CollisionShape2D = $CollisionShape2D
@onready var visual: AnimatedSprite2D = $Visual

var owner_player: Player = null
var shield_radius: float = 64.0
var duration_left: float = 8.0
var affected_players: Dictionary = {}
var source_id: int = 0


func setup(player: Player, radius: float, duration: float) -> void:
	owner_player = player
	shield_radius = maxf(radius, 1.0)
	duration_left = maxf(duration, 0.05)


func _ready() -> void:
	source_id = get_instance_id()
	var circle := collision_shape.shape as CircleShape2D
	if circle != null:
		circle.radius = shield_radius
	visual.scale = Vector2.ONE * (shield_radius / VISUAL_BASE_RADIUS)
	visual.play(&"pulse")
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)
	if owner_player != null:
		_apply_to_player(owner_player)
	call_deferred("_apply_existing_bodies")


func _process(delta: float) -> void:
	duration_left -= delta
	if duration_left <= 0.0:
		queue_free()
		return


func _exit_tree() -> void:
	for player in affected_players.values():
		var affected := player as Player
		if affected != null and is_instance_valid(affected):
			affected.remove_damage_reduction_modifier(source_id)
	affected_players.clear()


func _on_body_entered(body: Node2D) -> void:
	var player := body as Player
	if player == null:
		return
	_apply_to_player(player)


func _on_body_exited(body: Node2D) -> void:
	var player := body as Player
	if player == null:
		return
	_remove_from_player(player)


func _apply_existing_bodies() -> void:
	for body in get_overlapping_bodies():
		var player := body as Player
		if player != null:
			_apply_to_player(player)


func _apply_to_player(player: Player) -> void:
	if player == null or not is_instance_valid(player):
		return
	affected_players[player.get_instance_id()] = player
	player.add_damage_reduction_modifier(source_id, DAMAGE_REDUCTION)


func _remove_from_player(player: Player) -> void:
	if player == null or not is_instance_valid(player):
		return
	affected_players.erase(player.get_instance_id())
	player.remove_damage_reduction_modifier(source_id)
