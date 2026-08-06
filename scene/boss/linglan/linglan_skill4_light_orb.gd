extends Area2D
class_name LinglanSkill4LightOrb

const GPU_PULSE_FREQUENCY := 3.5
const SHADER_TIME_ROLLOVER_SECONDS := 3600.0
const LIFETIME_DESPAWN_SHRINK_DURATION := 0.4

@export var speed: float = 40.0
@export var damage: int = 50
@export var orb_radius: float = 8.0
@export var damage_radius: float = 6.0
@export var max_lifetime: float = 12.0

@onready var collision_shape: CollisionShape2D = $CollisionShape2D
@onready var visual_root: Node2D = $VisualRoot

var direction := Vector2.RIGHT
var remaining_lifetime: float = 12.0
var damaged_player_ids: Dictionary = {}
var projectile_id: int = 0
var owner_peer_id: int = 0
var source_type: StringName = &"linglan_skill4_orb"
var gpu_pulse_phase: float = 0.0
var gpu_pulse_origin_msec: int = 0
var is_lifetime_despawning: bool = false
var lifetime_despawn_time_left: float = 0.0
var lifetime_despawn_start_scale := Vector2.ONE
var combat_runtime: CombatRuntimeBase = null
var gameplay_gateway: MultiplayerGameplayGateway = null


func bind_gameplay_context(
	runtime_context: CombatRuntimeBase,
	gateway: MultiplayerGameplayGateway
) -> void:
	combat_runtime = runtime_context
	gameplay_gateway = gateway


func _ready() -> void:
	body_entered.connect(_on_body_entered)
	_apply_current_radius()
	_apply_gpu_pulse_phase()


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
	is_lifetime_despawning = false
	lifetime_despawn_time_left = 0.0
	lifetime_despawn_start_scale = Vector2.ONE
	scale = Vector2.ONE
	orb_radius = maxf(initial_radius, 1.0)
	damage_radius = clampf(initial_damage_radius, 1.0, orb_radius)
	rotation = direction.angle()
	if is_node_ready():
		_apply_current_radius()


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
	if is_lifetime_despawning:
		_update_lifetime_despawn(safe_delta)
		return
	remaining_lifetime = maxf(remaining_lifetime - safe_delta, 0.0)
	if remaining_lifetime <= 0.0:
		_begin_lifetime_despawn()
		return
	global_position += direction * speed * safe_delta


func _begin_lifetime_despawn() -> void:
	if is_lifetime_despawning:
		return
	is_lifetime_despawning = true
	lifetime_despawn_time_left = LIFETIME_DESPAWN_SHRINK_DURATION
	lifetime_despawn_start_scale = scale
	remaining_lifetime = 0.0
	speed = 0.0
	collision_layer = 0
	collision_mask = 0
	set_deferred("monitoring", false)
	set_deferred("monitorable", false)


func _update_lifetime_despawn(delta: float) -> void:
	lifetime_despawn_time_left = maxf(lifetime_despawn_time_left - delta, 0.0)
	var shrink_progress := clampf(
		lifetime_despawn_time_left / LIFETIME_DESPAWN_SHRINK_DURATION,
		0.0,
		1.0
	)
	scale = lifetime_despawn_start_scale * shrink_progress
	if lifetime_despawn_time_left <= 0.0:
		queue_free()


func _apply_current_radius() -> void:
	if collision_shape == null:
		return
	var circle_shape := collision_shape.shape as CircleShape2D
	if circle_shape != null:
		circle_shape.radius = damage_radius


func _apply_gpu_pulse_phase() -> void:
	# Shader TIME is global. Offset it once per orb so every newly spawned orb
	# starts at the authored local-time midpoint without duplicating materials or
	# writing shader parameters every physics frame.
	gpu_pulse_origin_msec = Time.get_ticks_msec()
	var shader_time := fmod(
		float(gpu_pulse_origin_msec) * 0.001,
		SHADER_TIME_ROLLOVER_SECONDS
	)
	gpu_pulse_phase = fposmod(-shader_time * TAU * GPU_PULSE_FREQUENCY, TAU)
	for child in visual_root.get_children():
		var canvas_item := child as CanvasItem
		if canvas_item != null:
			canvas_item.set_instance_shader_parameter(&"gpu_pulse_phase", gpu_pulse_phase)


func _on_body_entered(body: Node2D) -> void:
	# The radius is constant, so Area2D events replace per-frame overlap polling.
	_apply_player_damage(body as Player)


func _apply_player_damage(player: Player) -> void:
	if is_lifetime_despawning or player == null or player.is_dead:
		return
	var player_id := player.get_instance_id()
	if damaged_player_ids.has(player_id):
		return
	damaged_player_ids[player_id] = true
	if _try_report_multiplayer_player_hit(player):
		return
	if not _has_explicit_singleplayer_authority():
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
	if gameplay_gateway == null or not is_instance_valid(gameplay_gateway):
		return false
	return gameplay_gateway.request_player_damage(
		source_id,
		player.peer_id,
		damage,
		source_type,
		EnemyConfig.DamageType.MAGIC,
		_get_source_direction_to_player(player),
		true
	)


func _has_explicit_singleplayer_authority() -> bool:
	return (
		combat_runtime != null
		and is_instance_valid(combat_runtime)
		and combat_runtime.runtime_mode
			== CombatRuntimeBase.RuntimeMode.SINGLEPLAYER
	)


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
