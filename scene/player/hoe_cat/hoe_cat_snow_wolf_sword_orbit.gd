extends Area2D
class_name HoeCatSnowWolfSwordOrbit

const DAMAGE_TYPE := EnemyConfig.DamageType.PHYSICAL
const COOLDOWN_PRUNE_INTERVAL := 0.1

@export_range(1, 9999, 1, "or_greater") var contact_damage: int = 30
@export_range(0.0, 20.0, 0.05, "or_greater") var angular_speed: float = TAU * 2.0
@export_range(0.05, 10.0, 0.05, "or_greater") var contact_damage_interval: float = 0.5

@onready var visual_root: Node2D = $VisualRoot
@onready var sword_a_sprite: Sprite2D = $VisualRoot/SwordA
@onready var sword_b_sprite: Sprite2D = $VisualRoot/SwordB
@onready var damage_shapes: Array[CollisionShape2D] = [
	$SwordAShape,
	$SwordBShape,
	$SwordCShape,
	$SwordDShape,
]

var owner_player: Player = null
var duration_left: float = 0.0
var elapsed: float = 0.0
var damage_enabled: bool = false
var overlapping_enemies: Dictionary[int, Enemy] = {}
var enemy_next_damage_times: Dictionary[int, float] = {}
var detached_cooldown_enemy_ids: Dictionary[int, bool] = {}
var _stale_enemy_ids: Array[int] = []
var _stale_cooldown_ids: Array[int] = []
var _next_cooldown_prune_time: float = 0.0
var _active: bool = false


func _ready() -> void:
	owner_player = get_parent() as Player
	visible = false
	monitoring = false
	monitorable = false
	set_physics_process(false)


func activate(duration: float, enable_authoritative_damage: bool) -> void:
	var preserve_contact_state := (
		_active
		and damage_enabled
		and enable_authoritative_damage
	)
	duration_left = maxf(duration, 0.05)
	if not _active:
		elapsed = 0.0
		rotation = 0.0
	_active = true
	visible = true
	if not preserve_contact_state:
		overlapping_enemies.clear()
		enemy_next_damage_times.clear()
		detached_cooldown_enemy_ids.clear()
		_next_cooldown_prune_time = 0.0
	_set_damage_collision_enabled(enable_authoritative_damage)
	set_physics_process(true)


func deactivate() -> void:
	duration_left = 0.0
	elapsed = 0.0
	rotation = 0.0
	_active = false
	visible = false
	_set_damage_collision_enabled(false)
	overlapping_enemies.clear()
	enemy_next_damage_times.clear()
	detached_cooldown_enemy_ids.clear()
	_stale_enemy_ids.clear()
	_stale_cooldown_ids.clear()
	_next_cooldown_prune_time = 0.0
	set_physics_process(false)


func is_active() -> bool:
	return _active


func set_visual_offset(offset: Vector2) -> void:
	if visual_root != null:
		visual_root.position = offset


func _physics_process(delta: float) -> void:
	if not _active:
		return
	if owner_player == null or not is_instance_valid(owner_player) or owner_player.is_dead:
		deactivate()
		return
	var safe_delta := maxf(delta, 0.0)
	duration_left = maxf(duration_left - safe_delta, 0.0)
	elapsed += safe_delta
	rotation = fposmod(elapsed * angular_speed, TAU)
	if duration_left <= 0.0:
		deactivate()
		return
	if damage_enabled:
		_update_overlapping_enemy_damage()
		_prune_expired_damage_cooldowns()


func _set_damage_collision_enabled(enabled: bool) -> void:
	damage_enabled = enabled
	for shape_node in damage_shapes:
		if shape_node != null:
			shape_node.set_deferred(&"disabled", not enabled)
	# Enable shapes before monitoring so the Area2D registers initial overlaps
	# on the first authoritative physics step.
	set_deferred(&"monitoring", enabled)
	if not enabled:
		overlapping_enemies.clear()


func _on_body_entered(body: Node2D) -> void:
	if not _active or not damage_enabled:
		return
	var enemy := body as Enemy
	if enemy == null or not is_instance_valid(enemy) or enemy.is_dead:
		return
	var enemy_id := enemy.get_instance_id()
	overlapping_enemies[enemy_id] = enemy
	detached_cooldown_enemy_ids.erase(enemy_id)
	_try_damage_enemy(enemy)


func _on_body_exited(body: Node2D) -> void:
	var enemy := body as Enemy
	if enemy == null:
		return
	# Keep the short cooldown after exit so a border-jittering body cannot force
	# repeated enter damage every physics frame.
	var enemy_id := enemy.get_instance_id()
	overlapping_enemies.erase(enemy_id)
	if enemy_next_damage_times.has(enemy_id):
		detached_cooldown_enemy_ids[enemy_id] = true


func _update_overlapping_enemy_damage() -> void:
	if overlapping_enemies.is_empty():
		return
	_stale_enemy_ids.clear()
	for enemy_id in overlapping_enemies:
		var enemy := overlapping_enemies[enemy_id]
		if enemy == null or not is_instance_valid(enemy) or enemy.is_dead:
			_stale_enemy_ids.append(enemy_id)
			continue
		if float(enemy_next_damage_times.get(enemy_id, 0.0)) > elapsed:
			continue
		_try_damage_enemy(enemy)
	for enemy_id in _stale_enemy_ids:
		overlapping_enemies.erase(enemy_id)
		enemy_next_damage_times.erase(enemy_id)
		detached_cooldown_enemy_ids.erase(enemy_id)


func _prune_expired_damage_cooldowns() -> void:
	if detached_cooldown_enemy_ids.is_empty():
		return
	if elapsed < _next_cooldown_prune_time:
		return
	_next_cooldown_prune_time = elapsed + COOLDOWN_PRUNE_INTERVAL
	_stale_cooldown_ids.clear()
	for enemy_id in detached_cooldown_enemy_ids:
		if (
			not enemy_next_damage_times.has(enemy_id)
			or float(enemy_next_damage_times[enemy_id]) <= elapsed
		):
			_stale_cooldown_ids.append(enemy_id)
	for enemy_id in _stale_cooldown_ids:
		detached_cooldown_enemy_ids.erase(enemy_id)
		enemy_next_damage_times.erase(enemy_id)


func _try_damage_enemy(enemy: Enemy) -> bool:
	if (
		not _active
		or not damage_enabled
		or owner_player == null
		or not is_instance_valid(owner_player)
		or enemy == null
		or not is_instance_valid(enemy)
		or enemy.is_dead
	):
		return false
	var enemy_id := enemy.get_instance_id()
	if float(enemy_next_damage_times.get(enemy_id, 0.0)) > elapsed:
		return false
	var outgoing_damage := owner_player.get_outgoing_damage(contact_damage, DAMAGE_TYPE)
	outgoing_damage = owner_player.resolve_attack_damage_against_enemy(
		outgoing_damage,
		enemy
	)
	var impact_direction := global_position.direction_to(enemy.global_position)
	if impact_direction == Vector2.ZERO:
		impact_direction = Vector2.DOWN
	var damage_applied := owner_player._apply_authoritative_collectible_enemy_damage(
		enemy,
		outgoing_damage,
		impact_direction,
		DAMAGE_TYPE,
		false
	)
	# Preserve the authored contact cadence even if the target rejects this
	# pulse; otherwise an overlap would retry every physics frame.
	enemy_next_damage_times[enemy_id] = (
		elapsed + maxf(contact_damage_interval, 0.05)
	)
	if damage_applied:
		owner_player.apply_collectible_attack_hit_effects(enemy, outgoing_damage)
	return damage_applied
