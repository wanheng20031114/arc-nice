extends TowerPlantGameplayPort
class_name TowerPlantGameplayBridge

@onready var mode_adapter: TowerDefenseMultiplayerModeAdapter = (
	get_node("../MultiplayerModeAdapter") as TowerDefenseMultiplayerModeAdapter
)


func broadcast_plant_projectile_visual(
	plant_net_id: int,
	spawn_position: Vector2,
	direction: Vector2,
	speed: float,
	explosion_radius: float,
	lifetime: float
) -> bool:
	return (
		mode_adapter != null
		and mode_adapter.broadcast_plant_projectile_visual(
			plant_net_id,
			spawn_position,
			direction,
			speed,
			explosion_radius,
			lifetime
		)
	)


func queue_bamboo_mortar_visual(
	plant_net_id: int,
	action_id: int,
	stage: int,
	spawn_position: Vector2,
	landing_position: Vector2,
	committed_windup_duration_seconds: float
) -> bool:
	return (
		mode_adapter != null
		and mode_adapter.queue_bamboo_mortar_visual(
			plant_net_id,
			action_id,
			stage,
			spawn_position,
			landing_position,
			committed_windup_duration_seconds
		)
	)


func queue_hydrangea_rain_visual(
	plant_net_id: int,
	action_id: int,
	target_position: Vector2,
	action_elapsed_seconds: float
) -> bool:
	return (
		mode_adapter != null
		and mode_adapter.queue_hydrangea_rain_visual(
			plant_net_id,
			action_id,
			target_position,
			action_elapsed_seconds
		)
	)


func queue_corn_machine_gun_burst_visual(
	plant_net_id: int,
	action_id: int,
	direction: Vector2,
	shot_count: int
) -> bool:
	return (
		mode_adapter != null
		and mode_adapter.queue_corn_machine_gun_burst_visual(
			plant_net_id,
			action_id,
			direction,
			shot_count
		)
	)


func apply_authoritative_plant_enemy_damage(
	damage_source_id: int,
	enemy_node: Node2D,
	damage: int,
	impact_direction: Vector2,
	damage_type: int
) -> bool:
	var enemy := enemy_node as Enemy
	return (
		mode_adapter != null
		and enemy != null
		and mode_adapter.apply_authoritative_plant_enemy_damage(
			damage_source_id,
			enemy,
			damage,
			impact_direction,
			damage_type
		)
	)


func apply_authoritative_plant_enemy_damage_batch(
	damage_source_id: int,
	enemy_node: Node2D,
	damage_amounts: PackedInt64Array,
	hit_counts: PackedInt32Array,
	impact_direction: Vector2,
	damage_type: int
) -> bool:
	var enemy := enemy_node as Enemy
	return (
		mode_adapter != null
		and enemy != null
		and mode_adapter.apply_authoritative_plant_enemy_damage_batch(
			damage_source_id,
			enemy,
			damage_amounts,
			hit_counts,
			impact_direction,
			damage_type
		)
	)


func request_bamboo_mortar_target(
	owner: Node2D,
	minimum_range: float,
	maximum_range: float,
	callback: Callable
) -> bool:
	return (
		mode_adapter != null
		and mode_adapter.request_bamboo_mortar_target(
			owner,
			minimum_range,
			maximum_range,
			callback
		)
	)


func cancel_bamboo_mortar_target_request(owner: Node) -> void:
	if mode_adapter != null:
		mode_adapter.cancel_bamboo_mortar_target_request(owner)


func queue_bamboo_mortar_explosion(
	landing_position: Vector2,
	inner_radius: float,
	outer_radius: float,
	inner_damage: int,
	outer_damage: int,
	damage_source_id: int
) -> bool:
	return (
		mode_adapter != null
		and mode_adapter.queue_bamboo_mortar_explosion(
			landing_position,
			inner_radius,
			outer_radius,
			inner_damage,
			outer_damage,
			damage_source_id
		)
	)


func query_living_plants_in_radius_into(
	center: Vector2,
	radius: float,
	result: Array
) -> void:
	if mode_adapter == null:
		result.clear()
		return
	mode_adapter.query_living_plants_in_radius_into(center, radius, result)


func begin_inventory_building_placement(
	slot_index: int,
	expected_inventory_revision: int
) -> bool:
	return (
		mode_adapter != null
		and mode_adapter.begin_inventory_building_placement(
			slot_index,
			expected_inventory_revision
		)
	)
