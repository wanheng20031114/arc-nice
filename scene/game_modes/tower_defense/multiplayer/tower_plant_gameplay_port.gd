@abstract
extends Node
class_name TowerPlantGameplayPort


@abstract
func broadcast_plant_projectile_visual(
	plant_net_id: int,
	spawn_position: Vector2,
	direction: Vector2,
	speed: float,
	explosion_radius: float,
	lifetime: float
) -> bool


@abstract
func queue_bamboo_mortar_visual(
	plant_net_id: int,
	action_id: int,
	stage: int,
	spawn_position: Vector2,
	landing_position: Vector2,
	committed_windup_duration_seconds: float
) -> bool


@abstract
func queue_hydrangea_rain_visual(
	plant_net_id: int,
	action_id: int,
	target_position: Vector2,
	action_elapsed_seconds: float
) -> bool


@abstract
func queue_corn_machine_gun_burst_visual(
	plant_net_id: int,
	action_id: int,
	direction: Vector2,
	shot_count: int
) -> bool


@abstract
func apply_authoritative_plant_enemy_damage(
	damage_source_id: int,
	enemy: Node2D,
	damage: int,
	impact_direction: Vector2,
	damage_type: int
) -> bool


@abstract
func apply_authoritative_plant_enemy_damage_batch(
	damage_source_id: int,
	enemy: Node2D,
	damage_amounts: PackedInt64Array,
	hit_counts: PackedInt32Array,
	impact_direction: Vector2,
	damage_type: int
) -> bool


@abstract
func request_bamboo_mortar_target(
	owner: Node2D,
	minimum_range: float,
	maximum_range: float,
	callback: Callable
) -> bool


@abstract
func cancel_bamboo_mortar_target_request(owner: Node) -> void


@abstract
func queue_bamboo_mortar_explosion(
	landing_position: Vector2,
	inner_radius: float,
	outer_radius: float,
	inner_damage: int,
	outer_damage: int,
	damage_source_id: int
) -> bool


@abstract
func query_living_plants_in_radius_into(
	center: Vector2,
	radius: float,
	result: Array
) -> void


@abstract
func begin_inventory_building_placement(
	slot_index: int,
	expected_inventory_revision: int
) -> bool
