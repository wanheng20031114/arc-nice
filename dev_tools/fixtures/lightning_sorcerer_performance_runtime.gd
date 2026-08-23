extends EnemyGameplayGatewayTestRuntime
class_name LightningSorcererPerformanceRuntime

## Real CombatRuntimeBase fixture for the Lightning Sorcerer performance gate.
## It keeps production target-query dispatch intact while routing plant targets
## through the same PlantSystem spatial index used by tower-defense gameplay.

var plant_system: PlantSystem = null
var attack_target_query_count := 0
var broad_attack_target_query_count := 0


func find_nearest_enemy_attack_target_world(
	from_position: Vector2,
	max_distance: float,
	excluded_instance_ids: Dictionary = {}
) -> Node2D:
	attack_target_query_count += 1
	if plant_system == null or not is_instance_valid(plant_system):
		return super.find_nearest_enemy_attack_target_world(
			from_position,
			max_distance,
			excluded_instance_ids
		)
	return plant_system.find_nearest_enemy_attack_target_world(
		from_position,
		max_distance,
		excluded_instance_ids
	)


func find_nearest_hostile_enemy_attack_target_world(
	from_position: Vector2,
	max_distance: float,
	_source_faction_id: int,
	excluded_instance_ids: Dictionary = {}
) -> Node2D:
	return find_nearest_enemy_attack_target_world(
		from_position,
		max_distance,
		excluded_instance_ids
	)


func query_hostile_enemy_attack_targets_world_into(
	from_position: Vector2,
	max_distance: float,
	source_faction_id: int,
	result: Array[Node2D],
	excluded_target: Node2D = null,
	max_count: int = 0
) -> void:
	broad_attack_target_query_count += 1
	super.query_hostile_enemy_attack_targets_world_into(
		from_position,
		max_distance,
		source_faction_id,
		result,
		excluded_target,
		max_count
	)
