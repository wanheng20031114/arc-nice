extends Area2D
class_name ProjectileShieldArea

## Passive, query-only projectile interceptor owned by a shield-bearing enemy.
##
## The area never scans, monitors, or processes. Friendly projectile sweeps hit
## its dedicated layer and call try_intercept() exactly at their existing
## collision point. Host/single-player calls synchronously consume durability;
## proxies only consume the local projectile visual and wait for replicated
## enemy actions/snapshots to update durability.

signal durability_changed(remaining: int, maximum: int)
signal shield_broken

const PROJECTILE_SHIELD_COLLISION_LAYER := 1 << 12
const FRONT_DOT_EPSILON := 0.0001

@export_range(1, 999, 1, "or_greater") var initial_max_durability := 20

var _owner_enemy: Enemy = null
var _max_durability := 20
var _remaining_durability := 20
var _shield_active := true
var _facing_direction := Vector2.RIGHT
var _visual_proxy_mode := false
var _configured := false


func _ready() -> void:
	collision_mask = 0
	if not _configured:
		_max_durability = maxi(initial_max_durability, 1)
		_remaining_durability = _max_durability
	_apply_collision_state()


func setup(owner_enemy: Enemy, max_durability: int) -> void:
	_configured = true
	_owner_enemy = owner_enemy
	_max_durability = maxi(max_durability, 1)
	_remaining_durability = _max_durability
	_shield_active = true
	_apply_collision_state()


func is_active() -> bool:
	return _shield_active and _remaining_durability > 0


func get_owner_enemy() -> Enemy:
	if _owner_enemy != null and is_instance_valid(_owner_enemy):
		return _owner_enemy
	return null


func get_remaining_durability() -> int:
	return _remaining_durability


func get_max_durability() -> int:
	return _max_durability


func set_shield_active(active: bool) -> void:
	_shield_active = active and _remaining_durability > 0
	_apply_collision_state()


func set_facing_direction(direction: Vector2) -> void:
	if direction == Vector2.ZERO:
		return
	_facing_direction = direction.normalized()


func get_facing_direction() -> Vector2:
	return _facing_direction


func set_visual_proxy_mode(enabled: bool) -> void:
	_visual_proxy_mode = enabled


func apply_proxy_durability_snapshot(remaining: int) -> void:
	if not _visual_proxy_mode:
		return
	var next_remaining := clampi(remaining, 0, _max_durability)
	# Proxy stages are monotonic. An older snapshot must never rebuild a shield
	# after a newer block/break action has already been presented.
	next_remaining = mini(next_remaining, _remaining_durability)
	if next_remaining == _remaining_durability:
		return
	_remaining_durability = next_remaining
	if _remaining_durability <= 0:
		_shield_active = false
	_apply_collision_state()
	durability_changed.emit(_remaining_durability, _max_durability)


func try_intercept(travel_direction: Vector2) -> bool:
	if not is_active() or not _is_front_contact(travel_direction):
		return false
	if _is_visual_proxy():
		# The proxy consumes only its local projectile representation. Durability,
		# FX and stage changes remain driven by authoritative enemy actions/snapshots.
		return true

	# Godot physics callbacks and queries execute on the main thread. Disabling
	# the layer before emitting the twentieth-block signals makes this synchronous
	# decrement atomic for all projectile callbacks in the same physics frame.
	_remaining_durability -= 1
	if _remaining_durability <= 0:
		_remaining_durability = 0
		_shield_active = false
		_apply_collision_state()
	durability_changed.emit(_remaining_durability, _max_durability)
	if _remaining_durability <= 0:
		shield_broken.emit()
	return true


func _is_front_contact(travel_direction: Vector2) -> bool:
	if travel_direction == Vector2.ZERO:
		return false
	return travel_direction.normalized().dot(_facing_direction) < -FRONT_DOT_EPSILON


func _is_visual_proxy() -> bool:
	# Public Relay hosts are ENet clients too, so Godot's server flag cannot
	# distinguish an authoritative game Host from a visual proxy. The owning
	# enemy explicitly enables proxy mode from configure_multiplayer_proxy().
	return _visual_proxy_mode


func _apply_collision_state() -> void:
	var enabled := is_active()
	# Direct ray/shape queries use the collision layer, so keep this transition
	# synchronous to preserve the twentieth-hit atomicity contract. Area2D
	# monitoring properties, however, cannot be changed while Godot is flushing
	# an area_entered/area_exited callback; defer those server mutations.
	collision_layer = PROJECTILE_SHIELD_COLLISION_LAYER if enabled else 0
	collision_mask = 0
	set_deferred(&"monitorable", enabled)
	set_deferred(&"monitoring", false)
