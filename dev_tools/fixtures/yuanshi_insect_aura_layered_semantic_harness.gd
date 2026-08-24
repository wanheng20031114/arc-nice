extends YuanshiInsectAura
class_name YuanshiInsectAuraLayeredSemanticHarness

## Retains the authored AuraArea, collision geometry, damage resolver and shared
## layered runner. Only world navigation is frozen so Aura event semantics can
## be compared without pathfinding or CharacterBody collision noise.

var aura_event_deltas: Array[float] = []
var aura_damage_apply_count := 0
var last_aura_damage_target_id := 0
var enemy_defeat_wake_count := 0


func reset_aura_semantic_trace() -> void:
	aura_event_deltas.clear()
	aura_damage_apply_count = 0
	last_aura_damage_target_id = 0
	enemy_defeat_wake_count = 0


func _get_safe_navigation_move_direction(
	_target_node: Node2D,
	_shared_pathfinder: Node,
	_waypoint_arrival_distance: float
) -> Vector2:
	return Vector2.ZERO


func _move_after_confirmed_no_contact(_delta: float = -1.0) -> void:
	velocity = Vector2.ZERO


func _update_aura_damage(delta: float) -> void:
	aura_event_deltas.append(delta)
	super._update_aura_damage(delta)


func _try_deal_aura_damage(target: Node2D = null) -> bool:
	var accepted := super._try_deal_aura_damage(target)
	if accepted:
		aura_damage_apply_count += 1
		last_aura_damage_target_id = (
			target.get_instance_id()
			if target != null and is_instance_valid(target)
			else 0
		)
	return accepted


func _on_aura_enemy_defeated(enemy: Enemy) -> void:
	super._on_aura_enemy_defeated(enemy)
	if layered_area_decision_urgent:
		enemy_defeat_wake_count += 1
