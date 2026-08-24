extends CombatRobotShieldBearer
class_name CombatRobotShieldBearerLayeredSemanticHarness

## Keep the authored ShieldBearer scene, collision shapes, shield state, damage
## pipeline and authoritative runner intact. The fixture replaces only the
## world-dependent navigation answer and CharacterBody motion submission so one
## fixed path can be replayed byte-for-byte in every simulation mode.

const FIXED_PHYSICS_DELTA := 1.0 / 60.0

var forced_move_direction := Vector2.RIGHT
var movement_submission_count := 0
var touch_update_count := 0
var touch_apply_count := 0
var last_touch_update_delta := 0.0
var last_touch_cooldown_before := 0.0
var last_touch_cooldown_after := 0.0
var last_touch_selected_peer_before := 0
var last_touch_selected_peer_after := 0


func _get_safe_navigation_move_direction(
	_target_node: Node2D,
	_shared_pathfinder: Node,
	_waypoint_arrival_distance: float
) -> Vector2:
	return forced_move_direction.normalized()


func _move_after_confirmed_no_contact(delta: float = -1.0) -> void:
	if velocity == Vector2.ZERO:
		return
	movement_submission_count += 1
	var motion_delta := delta if delta >= 0.0 else FIXED_PHYSICS_DELTA
	global_position += velocity * motion_delta


func _update_touch_damage(delta: float) -> void:
	touch_update_count += 1
	last_touch_update_delta = delta
	last_touch_cooldown_before = touch_damage_cooldown_left
	last_touch_selected_peer_before = (
		touched_player.peer_id
		if touched_player != null and is_instance_valid(touched_player)
		else 0
	)
	super._update_touch_damage(delta)
	last_touch_cooldown_after = touch_damage_cooldown_left
	last_touch_selected_peer_after = (
		touched_player.peer_id
		if touched_player != null and is_instance_valid(touched_player)
		else 0
	)


func _on_touch_damage_applied(
	target: Node,
	source_snapshot: DamageSourceSnapshot
) -> void:
	touch_apply_count += 1
	super._on_touch_damage_applied(target, source_snapshot)
