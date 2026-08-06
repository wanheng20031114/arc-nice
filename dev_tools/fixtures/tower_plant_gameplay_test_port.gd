extends TowerPlantGameplayPort
class_name TowerPlantGameplayTestPort


func broadcast_plant_projectile_visual(
	_plant_net_id: int,
	_spawn_position: Vector2,
	_direction: Vector2,
	_speed: float,
	_explosion_radius: float,
	_lifetime: float
) -> bool:
	return false


func queue_bamboo_mortar_visual(
	_plant_net_id: int,
	_action_id: int,
	_stage: int,
	_spawn_position: Vector2,
	_landing_position: Vector2,
	_committed_windup_duration_seconds: float
) -> bool:
	return false


func queue_hydrangea_rain_visual(
	_plant_net_id: int,
	_action_id: int,
	_target_position: Vector2,
	_action_elapsed_seconds: float
) -> bool:
	return false


func queue_corn_machine_gun_burst_visual(
	_plant_net_id: int,
	_action_id: int,
	_direction: Vector2
) -> bool:
	return false


func apply_authoritative_plant_enemy_damage(
	_damage_source_id: int,
	_enemy: Node2D,
	_damage: int,
	_impact_direction: Vector2,
	_damage_type: int
) -> bool:
	return false


func apply_authoritative_plant_enemy_damage_batch(
	_damage_source_id: int,
	_enemy: Node2D,
	_damage_amounts: PackedInt64Array,
	_hit_counts: PackedInt32Array,
	_impact_direction: Vector2,
	_damage_type: int
) -> bool:
	return false


func request_bamboo_mortar_target(
	_owner: Node2D,
	_minimum_range: float,
	_maximum_range: float,
	_callback: Callable
) -> bool:
	return false


func cancel_bamboo_mortar_target_request(_owner: Node) -> void:
	pass


func queue_bamboo_mortar_explosion(
	_landing_position: Vector2,
	_inner_radius: float,
	_outer_radius: float,
	_inner_damage: int,
	_outer_damage: int,
	_damage_source_id: int
) -> bool:
	return false


func query_living_plants_in_radius_into(
	_center: Vector2,
	_radius: float,
	result: Array
) -> void:
	result.clear()


func begin_inventory_building_placement(
	_slot_index: int,
	_expected_inventory_revision: int
) -> bool:
	return false
