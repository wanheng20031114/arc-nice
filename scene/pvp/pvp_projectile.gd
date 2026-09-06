extends Node2D
class_name PvpProjectile

const Rules := preload("res://scene/pvp/pvp_rules.gd")
var projectile_id := 0
var shooter_id := 0
var shooter_team := "CT"
var weapon := "deagle"
var direction := Vector2.RIGHT
var age := 0.0
var expired := false
var exclusion_rids: Array[RID] = []

func setup(id: int, shooter: PvpPlayer, weapon_id: String, origin: Vector2, aim: Vector2, exclusions: Array[RID]) -> void:
	projectile_id = id
	shooter_id = shooter.peer_id
	shooter_team = shooter.team
	weapon = weapon_id
	global_position = origin
	direction = aim.normalized()
	rotation = direction.angle()
	exclusion_rids = exclusions

## A swept segment checks the complete 500 px/s step, including small head areas.
func authority_step(delta: float) -> Dictionary:
	age += delta
	if age >= Rules.BULLET_LIFETIME:
		expired = true
		return {}
	var end := global_position + direction * Rules.BULLET_SPEED * delta
	var query := PhysicsRayQueryParameters2D.create(global_position, end, 1 | 4 | 8, exclusion_rids)
	query.collide_with_areas = true
	query.hit_from_inside = true
	var hit := get_world_2d().direct_space_state.intersect_ray(query)
	if not hit.is_empty():
		global_position = hit.position
		expired = true
		return hit
	global_position = end
	return {}

func serialize() -> Dictionary:
	return {"id": projectile_id, "shooter": shooter_id, "team": shooter_team,
		"weapon": weapon, "position": global_position, "direction": direction}
