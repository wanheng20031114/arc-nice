extends Node
class_name PlantSystem

const PlantTargetSpatialIndexScript := preload(
	"res://scene/combat/targeting/plant_target_spatial_index.gd"
)

signal plant_placed(plant: PlantDefense)
signal plant_removed(plant: PlantDefense)
signal occupancy_changed

const DEFAULT_PLACEMENT_AREA: Rect2i = Rect2i(-3, -1, 22, 18)
const MAX_PLACEMENT_MANHATTAN_DISTANCE: int = 6
# Building placement is authoritative on terrain, reserved/occupied cells and
# persistent world/player bodies. Enemies, bosses and loose pickups are transient
# and can crowd every cell around the player, so treating them as placement
# blockers can erase every otherwise-valid anchor. Their layers (4, 32 and 256)
# are intentionally excluded; a newly placed building still becomes an immediate
# contact-attack target through the normal combat Area2D.
const ENTITY_BLOCKING_MASK: int = 1 | 2
const FOOTPRINT_COLLISION_INSET: Vector2 = Vector2(4.0, 4.0)
const UNSUPPORTED_TERRAIN_DAMAGE_RATIO: float = 0.10
const UNSUPPORTED_TERRAIN_MIN_DAMAGE: int = 50
# Three-cell chain bounces dominate repeated plant targeting. After direct-nearest
# ring pruning, the A/B-tested 48 px bucket visits the fewest dense candidates
# and wins the complete-chain workload. Every stationary plant owns one member;
# longer attacks reuse the same index instead of adding radius-specific tiers.
const PLANT_TARGET_SPATIAL_BUCKET_SIZE_PIXELS := 48.0
const CARDINAL_REFRESH_OFFSETS := [
	Vector2i.ZERO,
	Vector2i.UP,
	Vector2i.RIGHT,
	Vector2i.DOWN,
	Vector2i.LEFT,
]
const CARDINAL_NEIGHBOR_OFFSETS := [
	Vector2i.UP,
	Vector2i.RIGHT,
	Vector2i.DOWN,
	Vector2i.LEFT,
]
# Cardinal topology bits: up=1, right=2, down=4, left=8.
const CARDINAL_NEIGHBOR_BITS := [1, 2, 4, 8]
const WATER_COLLECTOR_RESEARCH_MODIFIER_SOURCE_ID := -10001

@export_range(0, 64, 1) var max_placement_manhattan_distance: int = (
	MAX_PLACEMENT_MANHATTAN_DISTANCE
)

var ground_tile_map: TileMapLayer = null
var terrain_map: DualGridTilemap = null
var owner_player: Player = null
var plant_container: Node2D = null
var combat_runtime: CombatRuntimeBase = null
var tower_multiplayer_mode_adapter: TowerPlantGameplayPort = null
var global_physical_defense_bonus := 0
var global_fence_max_health_bonus := 0
var global_fence_physical_defense_bonus := 0
var global_water_collector_duration_multiplier := 1.0
var global_agave_cannon_attack_damage_bonus := 0
var global_corn_machine_gun_burst_shot_count_bonus := 0
var global_grape_electromagnetic_attachment_duration_seconds := 0.0
var global_grape_electromagnetic_damage_multiplier := 1.0
var placement_area: Rect2i = DEFAULT_PLACEMENT_AREA

var occupied_cells: Dictionary = {}
var plant_footprints: Dictionary = {}
var reserved_cells: Dictionary = {}
var plants_by_net_id: Dictionary[int, PlantDefense] = {}
# All plants stay in this index for friendly auras and building interaction.
var _plant_target_spatial_index = PlantTargetSpatialIndexScript.new(
	PLANT_TARGET_SPATIAL_BUCKET_SIZE_PIXELS
)
var _plant_target_query_scratch: Array = []
# Enemy objective/attack queries only see plants admitted as PROACTIVE at
# registration. CONTACT_ONLY plants therefore add no membership or query work.
var _enemy_target_spatial_index = PlantTargetSpatialIndexScript.new(
	PLANT_TARGET_SPATIAL_BUCKET_SIZE_PIXELS
)
var _enemy_target_plants: Dictionary = {}
var _enemy_target_query_scratch: Array = []
var _registered_plant_configs: Dictionary = {}
var _unsupported_terrain_plants: Dictionary = {}
var _terrain_support_plants_by_cell: Dictionary = {}
var _terrain_support_cells_by_plant: Dictionary = {}
var _last_unsupported_terrain_tick_metrics := {
	"plants_visited": 0,
	"plants_damaged": 0,
}
var _last_terrain_support_change_metrics := {
	"affected_candidates": 0,
	"plants_recomputed": 0,
}
var _last_terrain_support_rebuild_plants_visited := 0
var _last_cardinal_connection_refresh_metrics := {
	"cells_visited": 0,
	"plants_updated": 0,
	"masks_changed": 0,
}


func setup(
	new_ground_tile_map: TileMapLayer,
	new_owner_player: Player,
	new_plant_container: Node2D,
	new_placement_area: Rect2i = DEFAULT_PLACEMENT_AREA,
	new_terrain_map: DualGridTilemap = null,
	new_combat_runtime: CombatRuntimeBase = null,
	new_tower_multiplayer_mode_adapter: TowerPlantGameplayPort = null
) -> void:
	_disconnect_terrain_changed_signal()
	ground_tile_map = new_ground_tile_map
	terrain_map = new_terrain_map
	owner_player = new_owner_player
	plant_container = new_plant_container
	combat_runtime = new_combat_runtime
	tower_multiplayer_mode_adapter = new_tower_multiplayer_mode_adapter
	placement_area = new_placement_area
	_connect_terrain_changed_signal()
	_rebuild_plant_target_spatial_index()
	_rebuild_unsupported_terrain_plants()


func _exit_tree() -> void:
	_disconnect_terrain_changed_signal()
	terrain_map = null
	_unsupported_terrain_plants.clear()
	_terrain_support_plants_by_cell.clear()
	_terrain_support_cells_by_plant.clear()


func configure(
	new_ground_tile_map: TileMapLayer,
	new_owner_player: Player,
	new_plant_container: Node2D,
	new_placement_area: Rect2i = DEFAULT_PLACEMENT_AREA,
	new_terrain_map: DualGridTilemap = null,
	new_combat_runtime: CombatRuntimeBase = null,
	new_tower_multiplayer_mode_adapter: TowerPlantGameplayPort = null
) -> void:
	setup(
		new_ground_tile_map,
		new_owner_player,
		new_plant_container,
		new_placement_area,
		new_terrain_map,
		new_combat_runtime,
		new_tower_multiplayer_mode_adapter
	)


func get_available_configs() -> Array[PlantDefenseConfig]:
	return PlantDefenseRegistry.get_all_configs()


func get_config(plant_id: StringName) -> PlantDefenseConfig:
	return PlantDefenseRegistry.get_config(plant_id)


func get_footprint_cells(
	top_left_cell: Vector2i,
	config: PlantDefenseConfig
) -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	if config == null:
		return cells

	for y in range(config.footprint_size.y):
		for x in range(config.footprint_size.x):
			cells.append(top_left_cell + Vector2i(x, y))
	return cells


func get_anchor_world_position(
	top_left_cell: Vector2i,
	config: PlantDefenseConfig
) -> Vector2:
	if ground_tile_map == null or config == null:
		return Vector2.ZERO

	var bottom_right_cell := top_left_cell + config.footprint_size - Vector2i.ONE
	var first_center := ground_tile_map.to_global(ground_tile_map.map_to_local(top_left_cell))
	var last_center := ground_tile_map.to_global(ground_tile_map.map_to_local(bottom_right_cell))
	return (first_center + last_center) * 0.5


func get_valid_anchors(config: PlantDefenseConfig) -> Array[Vector2i]:
	return get_valid_anchors_for_player(config, owner_player)


func get_valid_anchors_for_player(
	config: PlantDefenseConfig,
	placement_player: Player
) -> Array[Vector2i]:
	var valid_anchors: Array[Vector2i] = []
	if not _is_ready_for_placement(placement_player) or config == null or not config.is_valid():
		return valid_anchors

	var player_cell := _get_player_cell(placement_player)
	var candidate_area := _get_candidate_anchor_area(config, player_cell)
	for y in range(candidate_area.position.y, candidate_area.end.y):
		for x in range(candidate_area.position.x, candidate_area.end.x):
			var top_left_cell := Vector2i(x, y)
			if (
				_get_footprint_manhattan_distance(
					top_left_cell,
					config.footprint_size,
					player_cell
				)
				> maxi(max_placement_manhattan_distance, 0)
			):
				continue
			if is_placement_valid_for_player(top_left_cell, config, placement_player):
				valid_anchors.append(top_left_cell)
	return valid_anchors


func is_placement_valid(top_left_cell: Vector2i, config: PlantDefenseConfig) -> bool:
	return is_placement_valid_for_player(top_left_cell, config, owner_player)


func is_placement_valid_for_player(
	top_left_cell: Vector2i,
	config: PlantDefenseConfig,
	placement_player: Player
) -> bool:
	if not _is_ready_for_placement(placement_player) or config == null or not config.is_valid():
		return false

	var cells := get_footprint_cells(top_left_cell, config)
	if cells.size() != config.footprint_size.x * config.footprint_size.y:
		return false
	if (
		_get_footprint_manhattan_distance(
			top_left_cell,
			config.footprint_size,
			_get_player_cell(placement_player)
		)
		> maxi(max_placement_manhattan_distance, 0)
	):
		return false

	for cell in cells:
		if not placement_area.has_point(cell):
			return false
		if reserved_cells.has(cell) or occupied_cells.has(cell):
			return false
		if not _is_floor_cell_available(cell, config):
			return false

	return _is_entity_space_clear(top_left_cell, config)


func try_place(config: PlantDefenseConfig, top_left_cell: Vector2i) -> PlantDefense:
	return try_place_for_player(config, top_left_cell, owner_player)


func try_place_for_player(
	config: PlantDefenseConfig,
	top_left_cell: Vector2i,
	placement_player: Player,
	net_id: int = 0
) -> PlantDefense:
	if net_id < 0:
		push_error("PlantSystem net_id cannot be negative.")
		return null
	if net_id > 0 and plants_by_net_id.has(net_id):
		push_error("PlantSystem duplicate authoritative net_id: %d." % net_id)
		return null
	if not is_placement_valid_for_player(top_left_cell, config, placement_player):
		return null
	return _instantiate_registered_plant(
		config,
		top_left_cell,
		placement_player,
		net_id,
		false,
		-1,
		0,
		-1,
		true
	)


func spawn_multiplayer_replica(
	plant_id: StringName,
	top_left_cell: Vector2i,
	placement_player: Player,
	net_id: int,
	current_health: int,
	maximum_health: int,
	health_revision: int,
	play_placement_effect: bool = false
) -> PlantDefense:
	var config := get_config(plant_id)
	if (
		config == null
		or not config.is_valid()
		or not config.supports_multiplayer
		or net_id <= 0
		or ground_tile_map == null
		or ground_tile_map.tile_set == null
		or not is_instance_valid(plant_container)
	):
		return null
	if plants_by_net_id.has(net_id):
		var existing_plant := plants_by_net_id[net_id] as PlantDefense
		if (
			existing_plant != null
			and is_instance_valid(existing_plant)
			and not existing_plant.is_queued_for_deletion()
		):
			return existing_plant
		plants_by_net_id.erase(net_id)
	var cells := get_footprint_cells(top_left_cell, config)
	for cell in cells:
		if not placement_area.has_point(cell):
			push_error("PlantSystem replica footprint is outside placement area at %s." % cell)
			return null
		if reserved_cells.has(cell) or occupied_cells.has(cell):
			push_error("PlantSystem replica footprint conflicts at %s." % cell)
			return null
	return _instantiate_registered_plant(
		config,
		top_left_cell,
		placement_player,
		net_id,
		true,
		clampi(current_health, 0, maxi(maximum_health, 1)),
		health_revision,
		maximum_health,
		play_placement_effect
	)


func _instantiate_registered_plant(
	config: PlantDefenseConfig,
	top_left_cell: Vector2i,
	placement_player: Player,
	net_id: int,
	as_multiplayer_proxy: bool,
	initial_health: int,
	initial_health_revision: int,
	initial_maximum_health: int,
	play_placement_effect: bool
) -> PlantDefense:

	var instance := config.plant_scene.instantiate()
	var plant := instance as PlantDefense
	if plant == null:
		push_error("Plant scene root must inherit PlantDefense: %s" % config.plant_id)
		instance.free()
		return null
	if config.uses_cardinal_connections() and not plant is CardinalConnectedPlant:
		push_error(
			"Cardinal-connected plant scene root must inherit CardinalConnectedPlant: %s"
			% config.plant_id
		)
		instance.free()
		return null

	var cells := get_footprint_cells(top_left_cell, config)
	plant.name = (
		"%s_net_%d" % [String(config.plant_id), net_id]
		if net_id > 0
		else "%s_%d" % [String(config.plant_id), plant.get_instance_id()]
	)
	plant.bind_gameplay_context(
		combat_runtime,
		tower_multiplayer_mode_adapter
	)
	plant_container.add_child(plant)
	plant.global_position = get_anchor_world_position(top_left_cell, config)
	if net_id > 0:
		plant.set_meta(&"net_id", net_id)
		plants_by_net_id[net_id] = plant
	_register_plant_footprint(plant, cells, config)
	plant.removal_started.connect(
		_on_plant_removal_started.bind(plant),
		CONNECT_ONE_SHOT
	)
	plant.tree_exiting.connect(_on_plant_tree_exiting.bind(plant), CONNECT_ONE_SHOT)
	plant.setup(
		config,
		placement_player,
		cells,
		as_multiplayer_proxy,
		initial_health,
		initial_health_revision,
		initial_maximum_health,
		play_placement_effect
	)
	_register_plant_terrain_support(plant)
	_apply_research_stat_bonuses(plant)
	_apply_water_collector_duration_multiplier(plant)
	if plant.is_dead:
		return null
	plant_placed.emit(plant)
	return plant


func set_global_physical_defense_bonus(bonus: int) -> void:
	global_physical_defense_bonus = maxi(bonus, 0)
	for plant_variant in plant_footprints.keys():
		var plant := plant_variant as PlantDefense
		if plant != null and is_instance_valid(plant):
			_apply_research_stat_bonuses(plant)


func get_global_physical_defense_bonus() -> int:
	return global_physical_defense_bonus


func set_global_fence_max_health_bonus(bonus: int) -> void:
	global_fence_max_health_bonus = maxi(bonus, 0)
	for plant_variant in plant_footprints.keys():
		var plant := plant_variant as PlantDefense
		if plant != null and is_instance_valid(plant):
			_apply_research_stat_bonuses(plant)


func get_global_fence_max_health_bonus() -> int:
	return global_fence_max_health_bonus


func set_global_fence_physical_defense_bonus(bonus: int) -> void:
	global_fence_physical_defense_bonus = maxi(bonus, 0)
	for plant_variant in plant_footprints.keys():
		var plant := plant_variant as PlantDefense
		if plant != null and is_instance_valid(plant):
			_apply_research_stat_bonuses(plant)


func get_global_fence_physical_defense_bonus() -> int:
	return global_fence_physical_defense_bonus


func _apply_research_stat_bonuses(plant: PlantDefense) -> void:
	var is_fence := (
		plant.config != null
		and plant.config.building_category
		== PlantDefenseConfig.BuildingCategory.FENCE
	)
	plant.set_global_physical_defense_bonus(
		global_physical_defense_bonus
		+ (global_fence_physical_defense_bonus if is_fence else 0)
	)
	plant.set_research_max_health_bonus(
		global_fence_max_health_bonus if is_fence else 0
	)
	var agave_cannon := plant as AgaveCannon
	if agave_cannon != null:
		agave_cannon.set_research_attack_damage_bonus(
			global_agave_cannon_attack_damage_bonus
		)
	var corn_machine_gun := plant as CornMachineGun
	if corn_machine_gun != null:
		corn_machine_gun.set_research_burst_shot_count_bonus(
			global_corn_machine_gun_burst_shot_count_bonus
		)
	var grape_arc_tower := plant as GrapeArcTower
	if grape_arc_tower != null:
		grape_arc_tower.set_research_electromagnetic_upgrade(
			global_grape_electromagnetic_attachment_duration_seconds,
			global_grape_electromagnetic_damage_multiplier
		)


func set_global_agave_cannon_attack_damage_bonus(bonus: int) -> void:
	global_agave_cannon_attack_damage_bonus = maxi(bonus, 0)
	_reapply_research_stat_bonuses_to_all_plants()


func get_global_agave_cannon_attack_damage_bonus() -> int:
	return global_agave_cannon_attack_damage_bonus


func set_global_corn_machine_gun_burst_shot_count_bonus(bonus: int) -> void:
	global_corn_machine_gun_burst_shot_count_bonus = maxi(bonus, 0)
	_reapply_research_stat_bonuses_to_all_plants()


func get_global_corn_machine_gun_burst_shot_count_bonus() -> int:
	return global_corn_machine_gun_burst_shot_count_bonus


func set_global_grape_electromagnetic_upgrade(
	attachment_duration_seconds: float,
	damage_multiplier: float
) -> void:
	# 两条 typed effect 独立投射：临时附着与条件增伤可以各自启停，
	# 不因另一条缺失而被意外清空。
	global_grape_electromagnetic_attachment_duration_seconds = (
		attachment_duration_seconds
		if is_finite(attachment_duration_seconds)
		and attachment_duration_seconds > 0.0
		else 0.0
	)
	global_grape_electromagnetic_damage_multiplier = (
		damage_multiplier
		if is_finite(damage_multiplier) and damage_multiplier > 1.0
		else 1.0
	)
	_reapply_research_stat_bonuses_to_all_plants()


func get_global_grape_electromagnetic_attachment_duration_seconds() -> float:
	return global_grape_electromagnetic_attachment_duration_seconds


func get_global_grape_electromagnetic_damage_multiplier() -> float:
	return global_grape_electromagnetic_damage_multiplier


func _reapply_research_stat_bonuses_to_all_plants() -> void:
	for plant_variant in plant_footprints.keys():
		var plant := plant_variant as PlantDefense
		if plant != null and is_instance_valid(plant):
			_apply_research_stat_bonuses(plant)


func set_global_water_collector_duration_multiplier(multiplier: float) -> void:
	global_water_collector_duration_multiplier = (
		clampf(multiplier, ProductionBuilding.MIN_PRODUCTION_DURATION_MULTIPLIER, 1.0)
		if is_finite(multiplier) and multiplier > 0.0
		else 1.0
	)
	for plant_variant in plant_footprints.keys():
		var plant := plant_variant as PlantDefense
		if plant != null and is_instance_valid(plant):
			_apply_water_collector_duration_multiplier(plant)


func get_global_water_collector_duration_multiplier() -> float:
	return global_water_collector_duration_multiplier


func _apply_water_collector_duration_multiplier(plant: PlantDefense) -> void:
	var collector := plant as WaterCollector
	if collector == null:
		return
	if is_equal_approx(global_water_collector_duration_multiplier, 1.0):
		collector.remove_production_duration_multiplier_modifier(
			WATER_COLLECTOR_RESEARCH_MODIFIER_SOURCE_ID
		)
		return
	collector.add_production_duration_multiplier_modifier(
		WATER_COLLECTOR_RESEARCH_MODIFIER_SOURCE_ID,
		global_water_collector_duration_multiplier
	)


func try_place_by_id(plant_id: StringName, top_left_cell: Vector2i) -> PlantDefense:
	return try_place(get_config(plant_id), top_left_cell)


func get_plant_at_cell(cell: Vector2i) -> PlantDefense:
	return occupied_cells.get(cell) as PlantDefense


static func calculate_unsupported_terrain_damage(current_health: int) -> int:
	if current_health <= 0:
		return 0
	return maxi(
		ceili(float(current_health) * UNSUPPORTED_TERRAIN_DAMAGE_RATIO),
		UNSUPPORTED_TERRAIN_MIN_DAMAGE
	)


func apply_unsupported_terrain_damage_tick() -> int:
	_last_unsupported_terrain_tick_metrics["plants_visited"] = 0
	_last_unsupported_terrain_tick_metrics["plants_damaged"] = 0
	if terrain_map == null or _unsupported_terrain_plants.is_empty():
		return 0

	# Keep the unsupported membership snapshot stable for the complete tick. A
	# dying vegetation stake can synchronously restore terrain and update the live
	# set, but every plant unsupported at tick start must receive the same result
	# regardless of Dictionary traversal order.
	var unsupported_plants := _unsupported_terrain_plants.keys()
	_last_unsupported_terrain_tick_metrics["plants_visited"] = unsupported_plants.size()
	for plant_variant in unsupported_plants:
		var plant := plant_variant as PlantDefense
		if (
			plant == null
			or not is_instance_valid(plant)
			or plant.is_dead
			or plant.is_removing
			or plant.is_multiplayer_proxy
			or plant.is_queued_for_deletion()
		):
			continue
		var damage := calculate_unsupported_terrain_damage(plant.current_health)
		if plant.receive_unmitigated_damage(damage, self):
			_last_unsupported_terrain_tick_metrics["plants_damaged"] += 1
	return int(_last_unsupported_terrain_tick_metrics["plants_damaged"])


func get_unsupported_terrain_metrics() -> Dictionary:
	return {
		"unsupported_plant_count": _unsupported_terrain_plants.size(),
		"tracked_plant_count": _terrain_support_cells_by_plant.size(),
		"tracked_terrain_cell_count": _terrain_support_plants_by_cell.size(),
		"last_tick_plants_visited": int(
			_last_unsupported_terrain_tick_metrics["plants_visited"]
		),
		"last_tick_plants_damaged": int(
			_last_unsupported_terrain_tick_metrics["plants_damaged"]
		),
		"last_change_affected_candidates": int(
			_last_terrain_support_change_metrics["affected_candidates"]
		),
		"last_change_plants_recomputed": int(
			_last_terrain_support_change_metrics["plants_recomputed"]
		),
		"last_rebuild_plants_visited": _last_terrain_support_rebuild_plants_visited,
	}


func find_nearest_enemy_objective(
	from_global_position: Vector2,
	max_radius_cells: float,
	include_water_plants: bool = true,
	excluded_instance_ids: Dictionary = {}
) -> PlantDefense:
	if (
		ground_tile_map == null
		or ground_tile_map.tile_set == null
		or not from_global_position.is_finite()
		or max_radius_cells < 0.0
		or not is_finite(max_radius_cells)
	):
		return null

	var tile_size := Vector2(ground_tile_map.tile_set.tile_size).abs()
	if tile_size.x <= 0.0 or tile_size.y <= 0.0:
		return null
	var from_local := ground_tile_map.to_local(from_global_position)
	var center_cell := ground_tile_map.local_to_map(from_local)
	var search_radius := _get_bounded_enemy_candidate_search_radius(
		center_cell,
		max_radius_cells
	)
	var maximum_distance_squared := max_radius_cells * max_radius_cells
	var nearest_plant: PlantDefense = null
	var nearest_distance_squared := INF
	var candidates := _query_enemy_targets_for_logical_radius(
		from_global_position,
		tile_size,
		max_radius_cells
	)
	for candidate_variant in candidates:
		var plant := candidate_variant as PlantDefense
		if plant == null or not is_instance_valid(plant):
			continue
		var candidate_instance_id := int(plant.get_instance_id())
		if excluded_instance_ids.has(candidate_instance_id):
			continue
		if (
			plant.is_dead
			or plant.is_removing
			or plant.is_queued_for_deletion()
		):
			continue
		var registered_config := (
			_registered_plant_configs.get(plant) as PlantDefenseConfig
		)
		if registered_config == null:
			push_error(
				"PlantSystem is missing an enemy-objective config for a registered plant."
			)
			continue
		if not include_water_plants and registered_config.is_water_building():
			continue
		# Eligibility and distance stay in the typed exact pass. The shared spatial
		# index is deliberately only a broad phase, so future attack rules do not
		# multiply resident indices or contaminate their lifecycle bookkeeping.
		var plant_local := ground_tile_map.to_local(plant.global_position)
		var offset_in_cells := Vector2(
			(plant_local.x - from_local.x) / tile_size.x,
			(plant_local.y - from_local.y) / tile_size.y
		)
		var distance_squared := offset_in_cells.length_squared()
		if distance_squared > maximum_distance_squared:
			continue
		if (
			distance_squared < nearest_distance_squared
			or (
				distance_squared == nearest_distance_squared
				and _is_plant_candidate_before(
					plant,
					nearest_plant,
					center_cell,
					search_radius
				)
			)
		):
			nearest_distance_squared = distance_squared
			nearest_plant = plant
	return nearest_plant


## Fills caller-owned storage with living buildings inside an exact logical-cell
## circle. The stationary plant index is only the broad phase, so callers can
## cache this result without walking the complete building population.
func query_living_plants_in_logical_radius_into(
	from_global_position: Vector2,
	max_radius_cells: float,
	result: Array[PlantDefense]
) -> void:
	result.clear()
	if (
		ground_tile_map == null
		or ground_tile_map.tile_set == null
		or plant_footprints.is_empty()
		or not from_global_position.is_finite()
		or max_radius_cells < 0.0
		or not is_finite(max_radius_cells)
	):
		return
	var tile_size := Vector2(ground_tile_map.tile_set.tile_size).abs()
	if tile_size.x <= 0.0 or tile_size.y <= 0.0:
		return
	var from_local := ground_tile_map.to_local(from_global_position)
	var maximum_distance_squared := max_radius_cells * max_radius_cells
	var candidates := _query_plant_targets_for_logical_radius(
		from_global_position,
		tile_size,
		max_radius_cells
	)
	for candidate_variant in candidates:
		var plant := candidate_variant as PlantDefense
		if not _is_living_plant_target(plant):
			continue
		var plant_local := ground_tile_map.to_local(plant.global_position)
		var offset_in_cells := Vector2(
			(plant_local.x - from_local.x) / tile_size.x,
			(plant_local.y - from_local.y) / tile_size.y
		)
		if offset_in_cells.length_squared() <= maximum_distance_squared:
			result.append(plant)


## Returns the single nearest living building inside an exact logical-cell
## circle. This uses the complete plant index (not the enemy-objective subset),
## so warehouses, research centers, support towers and fences are all eligible.
## Equal-distance candidates use the stable multiplayer net-id/position order.
func find_nearest_living_plant_in_logical_radius(
	from_global_position: Vector2,
	max_radius_cells: float
) -> PlantDefense:
	if (
		ground_tile_map == null
		or ground_tile_map.tile_set == null
		or plant_footprints.is_empty()
		or not from_global_position.is_finite()
		or max_radius_cells < 0.0
		or not is_finite(max_radius_cells)
	):
		return null
	var tile_size := Vector2(ground_tile_map.tile_set.tile_size).abs()
	if tile_size.x <= 0.0 or tile_size.y <= 0.0:
		return null
	var from_local := ground_tile_map.to_local(from_global_position)
	var maximum_distance_squared := max_radius_cells * max_radius_cells
	var nearest: PlantDefense = null
	var nearest_distance_squared := INF
	var candidates := _query_plant_targets_for_logical_radius(
		from_global_position,
		tile_size,
		max_radius_cells
	)
	for candidate_variant in candidates:
		var candidate := candidate_variant as PlantDefense
		if not _is_living_plant_target(candidate):
			continue
		var candidate_local := ground_tile_map.to_local(candidate.global_position)
		var offset_in_cells := Vector2(
			(candidate_local.x - from_local.x) / tile_size.x,
			(candidate_local.y - from_local.y) / tile_size.y
		)
		var distance_squared := offset_in_cells.length_squared()
		if distance_squared > maximum_distance_squared:
			continue
		if PlantDefense.is_interaction_candidate_preferred(
			candidate,
			distance_squared,
			nearest,
			nearest_distance_squared
		):
			nearest = candidate
			nearest_distance_squared = distance_squared
	return nearest


## Fills caller-owned storage with living buildings whose authoritative anchors
## are inside the exact closed world AABB. This is the allocation-free viewport
## query for systems such as the minimap: distant stationary populations remain
## in the complete building index without being copied into each local sample.
func query_living_plants_in_world_aabb_into(
	world_aabb: Rect2,
	result: Array[PlantDefense]
) -> void:
	result.clear()
	if (
		not world_aabb.position.is_finite()
		or not world_aabb.size.is_finite()
	):
		return
	_plant_target_spatial_index.query_world_aabb_into(
		world_aabb,
		_plant_target_query_scratch,
		true
	)
	for candidate_variant in _plant_target_query_scratch:
		var plant := candidate_variant as PlantDefense
		if _is_living_plant_target(plant):
			result.append(plant)


## Exact world-space query for enemy attacks. All finite radii share the same
## one-membership anchor index; only the number of covered coarse buckets varies.
func find_nearest_enemy_attack_target_world(
	from_global_position: Vector2,
	max_world_distance: float,
	excluded_instance_ids: Dictionary = {}
) -> PlantDefense:
	if (
		not from_global_position.is_finite()
		or max_world_distance < 0.0
		or not is_finite(max_world_distance)
	):
		return null
	var nearest_plant := _enemy_target_spatial_index.find_nearest_world_anchor(
		from_global_position,
		max_world_distance,
		excluded_instance_ids
	) as PlantDefense
	if _is_living_plant_target(nearest_plant):
		return nearest_plant
	if nearest_plant == null or not is_instance_valid(nearest_plant):
		return null

	# Plant death marks is_dead before removal_started synchronously unregisters the
	# footprint. A query re-entered from a died signal can therefore briefly observe
	# that one stale-but-valid member. Allocate a retry exclusion set only on this
	# exceptional lifecycle edge and continue exact nearest selection; the ordinary
	# chain hot path remains one allocation-free index query.
	var retry_exclusions: Dictionary = excluded_instance_ids.duplicate()
	while nearest_plant != null and is_instance_valid(nearest_plant):
		retry_exclusions[nearest_plant.get_instance_id()] = true
		nearest_plant = _enemy_target_spatial_index.find_nearest_world_anchor(
			from_global_position,
			max_world_distance,
			retry_exclusions
		) as PlantDefense
		if _is_living_plant_target(nearest_plant):
			return nearest_plant
	return null


## Exact allocation-free world-radius query for friendly plant auras. The
## shared stationary index performs the broad phase while the caller owns the
## result array and the final circular filter.
func query_living_plants_in_world_radius_into(
	center: Vector2,
	radius: float,
	result: Array[PlantDefense]
) -> void:
	result.clear()
	if not center.is_finite() or not is_finite(radius) or radius < 0.0:
		return
	var candidates := _query_plant_targets_in_world_aabb(
		center,
		Vector2.ONE * radius
	)
	var radius_squared := radius * radius
	for candidate_variant in candidates:
		var plant := candidate_variant as PlantDefense
		if not _is_living_plant_target(plant):
			continue
		if center.distance_squared_to(plant.global_position) > radius_squared:
			continue
		result.append(plant)


## Exact nearest-building query for authoritative multiplayer interaction.
##
## Interaction commands are infrequent, but their old implementation rebuilt a
## sorted snapshot of every plant for each warehouse/production/research request.
## Reuse the stationary target spatial index as a broad phase, then apply the
## exact circular distance, lifecycle contract and the same deterministic tie
## break as local interaction selection. The shared scratch array is retained by
## PlantSystem, so the steady path creates neither a snapshot nor a candidate
## array and distant populations do not increase local work.
func find_nearest_operational_interaction_building_world(
	from_global_position: Vector2,
	max_world_distance: float
) -> PlantDefense:
	if (
		plant_footprints.is_empty()
		or not from_global_position.is_finite()
		or not is_finite(max_world_distance)
		or max_world_distance < 0.0
	):
		return null
	var candidates := _query_plant_targets_in_world_aabb(
		from_global_position,
		Vector2.ONE * max_world_distance
	)
	var maximum_distance_squared := max_world_distance * max_world_distance
	var nearest: PlantDefense = null
	var nearest_distance_squared := INF
	for candidate_variant in candidates:
		var candidate := candidate_variant as PlantDefense
		if not PlantDefense.is_operational_interaction_candidate(candidate):
			continue
		var distance_squared := from_global_position.distance_squared_to(
			candidate.global_position
		)
		if distance_squared > maximum_distance_squared:
			continue
		if PlantDefense.is_interaction_candidate_preferred(
			candidate,
			distance_squared,
			nearest,
			nearest_distance_squared
		):
			nearest = candidate
			nearest_distance_squared = distance_squared
	return nearest


func _is_living_plant_target(plant: PlantDefense) -> bool:
	return (
		plant != null
		and is_instance_valid(plant)
		and not plant.is_dead
		and not plant.is_removing
		and not plant.is_queued_for_deletion()
	)


func _get_bounded_enemy_candidate_search_radius(
	center_cell: Vector2i,
	max_radius_cells: float
) -> int:
	# This radius is used only to reproduce the historical footprint scan-order
	# tie break. Gameplay radii convert directly; extreme finite caller values are
	# bounded by existing occupancy before float-to-int conversion can overflow.
	if max_radius_cells <= 1024.0:
		return ceili(max_radius_cells) + 1
	var maximum_relevant_radius := 1
	for plant_variant in _enemy_target_plants:
		var plant := plant_variant as PlantDefense
		var footprint: Array = plant_footprints.get(plant, [])
		for footprint_cell_variant in footprint:
			var footprint_cell := footprint_cell_variant as Vector2i
			var delta := (footprint_cell - center_cell).abs()
			maximum_relevant_radius = maxi(
				maximum_relevant_radius,
				maxi(delta.x, delta.y) + 1
			)
	if max_radius_cells >= float(maximum_relevant_radius):
		return maximum_relevant_radius
	return ceili(max_radius_cells) + 1


func _query_plant_targets_for_logical_radius(
	from_global_position: Vector2,
	tile_size: Vector2,
	max_radius_cells: float
) -> Array:
	var local_half_extent := tile_size * max_radius_cells
	if not local_half_extent.is_finite():
		return _collect_all_plant_targets_into_scratch()
	# Transform the four corners of the logical ellipse's bounding rectangle.
	# The absolute projected axes form a conservative world AABB under rotation,
	# non-uniform scale and skew; the caller still performs exact logical distance.
	var world_origin := ground_tile_map.to_global(Vector2.ZERO)
	var projected_x := (
		ground_tile_map.to_global(Vector2(local_half_extent.x, 0.0))
		- world_origin
	)
	var projected_y := (
		ground_tile_map.to_global(Vector2(0.0, local_half_extent.y))
		- world_origin
	)
	var world_half_extent := Vector2(
		absf(projected_x.x) + absf(projected_y.x),
		absf(projected_x.y) + absf(projected_y.y)
	)
	return _query_plant_targets_in_world_aabb(
		from_global_position,
		world_half_extent
	)


func _query_enemy_targets_for_logical_radius(
	from_global_position: Vector2,
	tile_size: Vector2,
	max_radius_cells: float
) -> Array:
	var local_half_extent := tile_size * max_radius_cells
	if not local_half_extent.is_finite():
		return _collect_all_enemy_targets_into_scratch()
	var world_origin := ground_tile_map.to_global(Vector2.ZERO)
	var projected_x := (
		ground_tile_map.to_global(Vector2(local_half_extent.x, 0.0))
		- world_origin
	)
	var projected_y := (
		ground_tile_map.to_global(Vector2(0.0, local_half_extent.y))
		- world_origin
	)
	var world_half_extent := Vector2(
		absf(projected_x.x) + absf(projected_y.x),
		absf(projected_x.y) + absf(projected_y.y)
	)
	return _query_enemy_targets_in_world_aabb(
		from_global_position,
		world_half_extent
	)


func _query_plant_targets_in_world_aabb(
	center: Vector2,
	half_extent: Vector2
) -> Array:
	if (
		not center.is_finite()
		or not half_extent.is_finite()
		or half_extent.x < 0.0
		or half_extent.y < 0.0
	):
		return _collect_all_plant_targets_into_scratch()
	var minimum := center - half_extent
	var size := half_extent * 2.0
	if not minimum.is_finite() or not size.is_finite():
		return _collect_all_plant_targets_into_scratch()
	_plant_target_spatial_index.query_world_aabb_into(
		Rect2(minimum, size),
		_plant_target_query_scratch
	)
	return _plant_target_query_scratch


func _query_enemy_targets_in_world_aabb(
	center: Vector2,
	half_extent: Vector2
) -> Array:
	if (
		not center.is_finite()
		or not half_extent.is_finite()
		or half_extent.x < 0.0
		or half_extent.y < 0.0
	):
		return _collect_all_enemy_targets_into_scratch()
	var minimum := center - half_extent
	var size := half_extent * 2.0
	if not minimum.is_finite() or not size.is_finite():
		return _collect_all_enemy_targets_into_scratch()
	_enemy_target_spatial_index.query_world_aabb_into(
		Rect2(minimum, size),
		_enemy_target_query_scratch
	)
	return _enemy_target_query_scratch


func _collect_all_plant_targets_into_scratch() -> Array:
	_plant_target_query_scratch.clear()
	for plant_variant in plant_footprints:
		_plant_target_query_scratch.append(plant_variant)
	return _plant_target_query_scratch


func _collect_all_enemy_targets_into_scratch() -> Array:
	_enemy_target_query_scratch.clear()
	for plant_variant in _enemy_target_plants:
		_enemy_target_query_scratch.append(plant_variant)
	return _enemy_target_query_scratch


func _rebuild_plant_target_spatial_index() -> void:
	_plant_target_spatial_index.clear()
	_enemy_target_spatial_index.clear()
	_plant_target_query_scratch.clear()
	_enemy_target_query_scratch.clear()
	_enemy_target_plants.clear()
	for plant_variant in plant_footprints:
		var plant := plant_variant as PlantDefense
		if plant == null or not is_instance_valid(plant):
			continue
		if not _plant_target_spatial_index.register(plant, plant.global_position):
			push_error("PlantSystem failed to rebuild a plant target spatial entry.")
		var config := _registered_plant_configs.get(plant) as PlantDefenseConfig
		if config == null:
			push_error("PlantSystem is missing a registered plant config during index rebuild.")
			continue
		if not config.is_proactive_enemy_target():
			continue
		_enemy_target_plants[plant] = true
		if not _enemy_target_spatial_index.register(plant, plant.global_position):
			push_error("PlantSystem failed to rebuild an enemy target spatial entry.")


func set_plant_target_query_metrics_enabled(enabled: bool) -> void:
	_plant_target_spatial_index.set_query_metrics_enabled(enabled)


func get_plant_target_spatial_index_metrics() -> Dictionary:
	return _plant_target_spatial_index.get_structure_metrics()


func get_last_plant_target_query_metrics() -> Dictionary:
	return _plant_target_spatial_index.get_last_query_metrics()


func set_enemy_target_query_metrics_enabled(enabled: bool) -> void:
	_enemy_target_spatial_index.set_query_metrics_enabled(enabled)


func get_enemy_target_spatial_index_metrics() -> Dictionary:
	return _enemy_target_spatial_index.get_structure_metrics()


func get_last_enemy_target_query_metrics() -> Dictionary:
	return _enemy_target_spatial_index.get_last_query_metrics()


func get_last_cardinal_connection_refresh_metrics() -> Dictionary:
	return _last_cardinal_connection_refresh_metrics.duplicate()


func _is_plant_candidate_before(
	candidate: PlantDefense,
	current: PlantDefense,
	center_cell: Vector2i,
	search_radius: int
) -> bool:
	if current == null:
		return true
	var candidate_cell := _get_first_scanned_footprint_cell(
		candidate,
		center_cell,
		search_radius
	)
	var current_cell := _get_first_scanned_footprint_cell(
		current,
		center_cell,
		search_radius
	)
	if candidate_cell.y != current_cell.y:
		return candidate_cell.y < current_cell.y
	if candidate_cell.x != current_cell.x:
		return candidate_cell.x < current_cell.x
	return candidate.get_instance_id() < current.get_instance_id()


func _get_first_scanned_footprint_cell(
	plant: PlantDefense,
	center_cell: Vector2i,
	search_radius: int
) -> Vector2i:
	var first_cell := Vector2i(2147483647, 2147483647)
	var footprint: Array = plant_footprints.get(plant, [])
	var safe_search_radius := maxi(search_radius, 0)
	var minimum_query_cell := center_cell - Vector2i(
		safe_search_radius,
		safe_search_radius
	)
	var maximum_query_cell := center_cell + Vector2i(
		safe_search_radius,
		safe_search_radius
	)
	for cell_variant in footprint:
		var cell := cell_variant as Vector2i
		if (
			cell.x < minimum_query_cell.x
			or cell.x > maximum_query_cell.x
			or cell.y < minimum_query_cell.y
			or cell.y > maximum_query_cell.y
		):
			continue
		if cell.y < first_cell.y or (cell.y == first_cell.y and cell.x < first_cell.x):
			first_cell = cell
	return first_cell


func get_plant_by_net_id(net_id: int) -> PlantDefense:
	return plants_by_net_id.get(net_id) as PlantDefense


func remove_plant_by_net_id(
	net_id: int,
	mode: int = PlantDefense.RemovalMode.ANIMATED
) -> bool:
	var plant := get_plant_by_net_id(net_id)
	if plant == null or not is_instance_valid(plant):
		plants_by_net_id.erase(net_id)
		return false
	plant.begin_removal(mode)
	return true


func is_cell_occupied(cell: Vector2i) -> bool:
	return occupied_cells.has(cell)


func set_reserved_cells(cells: Array[Vector2i]) -> void:
	reserved_cells.clear()
	for cell in cells:
		reserved_cells[cell] = true


func reserve_cell(cell: Vector2i) -> void:
	reserved_cells[cell] = true


func reserve_world_position(world_position: Vector2, cell_radius: int = 0) -> void:
	if ground_tile_map == null:
		return

	var center_cell := ground_tile_map.local_to_map(ground_tile_map.to_local(world_position))
	var radius := maxi(cell_radius, 0)
	for y in range(center_cell.y - radius, center_cell.y + radius + 1):
		for x in range(center_cell.x - radius, center_cell.x + radius + 1):
			reserved_cells[Vector2i(x, y)] = true


func clear_reserved_cells() -> void:
	reserved_cells.clear()


func clear_all_plants() -> void:
	var plants := plant_footprints.keys()
	for plant_variant in plants:
		var plant := plant_variant as PlantDefense
		if is_instance_valid(plant):
			plant.begin_removal(PlantDefense.RemovalMode.SILENT)
		else:
			_release_plant_footprint(plant)


func _is_ready_for_placement(placement_player: Player) -> bool:
	return (
		ground_tile_map != null
		and ground_tile_map.tile_set != null
		and is_instance_valid(placement_player)
		and is_instance_valid(plant_container)
	)


func _get_player_cell(placement_player: Player) -> Vector2i:
	return ground_tile_map.local_to_map(
		ground_tile_map.to_local(placement_player.global_position)
	)


func _get_candidate_anchor_area(
	config: PlantDefenseConfig,
	player_cell: Vector2i
) -> Rect2i:
	var placement_anchor_size := (
		placement_area.size - config.footprint_size + Vector2i.ONE
	)
	if placement_anchor_size.x <= 0 or placement_anchor_size.y <= 0:
		return Rect2i()

	var placement_anchor_area := Rect2i(placement_area.position, placement_anchor_size)
	var radius := maxi(max_placement_manhattan_distance, 0)
	var footprint_extension := config.footprint_size - Vector2i.ONE
	var nearby_anchor_area := Rect2i(
		player_cell - Vector2i(radius, radius) - footprint_extension,
		Vector2i(radius * 2 + 1, radius * 2 + 1) + footprint_extension
	)
	return placement_anchor_area.intersection(nearby_anchor_area)


func _get_footprint_manhattan_distance(
	top_left_cell: Vector2i,
	footprint_size: Vector2i,
	player_cell: Vector2i
) -> int:
	var bottom_right_cell := top_left_cell + footprint_size - Vector2i.ONE
	var x_distance := 0
	if player_cell.x < top_left_cell.x:
		x_distance = top_left_cell.x - player_cell.x
	elif player_cell.x > bottom_right_cell.x:
		x_distance = player_cell.x - bottom_right_cell.x

	var y_distance := 0
	if player_cell.y < top_left_cell.y:
		y_distance = top_left_cell.y - player_cell.y
	elif player_cell.y > bottom_right_cell.y:
		y_distance = player_cell.y - bottom_right_cell.y
	return x_distance + y_distance


func _is_floor_cell_available(
	cell: Vector2i,
	config: PlantDefenseConfig
) -> bool:
	var tile_data := ground_tile_map.get_cell_tile_data(cell)
	if tile_data != null and tile_data.get_collision_polygons_count(0) > 0:
		return false
	if terrain_map == null:
		return (
			tile_data != null
			and config != null
			and not config.is_water_building()
		)
	return _is_ground_cell_terrain_supported_for_config(cell, config)


func _is_ground_cell_terrain_supported_for_config(
	ground_cell: Vector2i,
	config: PlantDefenseConfig
) -> bool:
	if ground_tile_map == null or terrain_map == null:
		return false
	var world_cell_center := ground_tile_map.to_global(
		ground_tile_map.map_to_local(ground_cell)
	)
	return _is_terrain_supported_for_config(
		terrain_map.world_to_map(world_cell_center),
		config
	)


func _connect_terrain_changed_signal() -> void:
	if terrain_map == null or not is_instance_valid(terrain_map):
		return
	var callback := Callable(self, "_on_terrain_changed")
	if terrain_map.terrain_changed.is_connected(callback):
		push_error("PlantSystem terrain_changed signal was already connected.")
		return
	terrain_map.terrain_changed.connect(callback)


func _disconnect_terrain_changed_signal() -> void:
	if terrain_map == null or not is_instance_valid(terrain_map):
		return
	var callback := Callable(self, "_on_terrain_changed")
	if terrain_map.terrain_changed.is_connected(callback):
		terrain_map.terrain_changed.disconnect(callback)


func _on_terrain_changed(
	terrain_cell: Vector2i,
	_previous_terrain: int,
	_current_terrain: int
) -> void:
	_last_terrain_support_change_metrics["affected_candidates"] = 0
	_last_terrain_support_change_metrics["plants_recomputed"] = 0
	if terrain_map == null:
		return
	var affected_plants := (
		_terrain_support_plants_by_cell.get(terrain_cell, {}) as Dictionary
	)
	if affected_plants.is_empty():
		return
	var affected_snapshot := affected_plants.keys()
	_last_terrain_support_change_metrics["affected_candidates"] = (
		affected_snapshot.size()
	)
	for plant_variant in affected_snapshot:
		_last_terrain_support_change_metrics["plants_recomputed"] += 1
		_refresh_plant_terrain_support(plant_variant as PlantDefense)


func _rebuild_unsupported_terrain_plants() -> void:
	_unsupported_terrain_plants.clear()
	_terrain_support_plants_by_cell.clear()
	_terrain_support_cells_by_plant.clear()
	_last_terrain_support_rebuild_plants_visited = 0
	if (
		terrain_map == null
		or terrain_map.world_map_layer == null
		or ground_tile_map == null
	):
		return
	for plant_variant in plant_footprints:
		_last_terrain_support_rebuild_plants_visited += 1
		_register_plant_terrain_support(plant_variant as PlantDefense)


func _register_plant_terrain_support(plant: PlantDefense) -> void:
	_unregister_plant_terrain_support(plant)
	if (
		plant == null
		or not is_instance_valid(plant)
		or not plant_footprints.has(plant)
		or plant.is_dead
		or plant.is_removing
		or plant.is_multiplayer_proxy
		or plant.is_queued_for_deletion()
		or terrain_map == null
		or terrain_map.world_map_layer == null
		or ground_tile_map == null
	):
		return
	var terrain_cells_set: Dictionary = {}
	var footprint: Array = plant_footprints[plant]
	for cell_variant in footprint:
		var ground_cell: Vector2i = cell_variant
		var world_position := ground_tile_map.to_global(
			ground_tile_map.map_to_local(ground_cell)
		)
		terrain_cells_set[terrain_map.world_to_map(world_position)] = true
	var terrain_cells := terrain_cells_set.keys()
	_terrain_support_cells_by_plant[plant] = terrain_cells
	for cell_variant in terrain_cells:
		var terrain_cell: Vector2i = cell_variant
		var affected_plants := (
			_terrain_support_plants_by_cell.get(terrain_cell, {}) as Dictionary
		)
		affected_plants[plant] = true
		_terrain_support_plants_by_cell[terrain_cell] = affected_plants
	_refresh_plant_terrain_support(plant)


func _unregister_plant_terrain_support(plant: PlantDefense) -> void:
	_unsupported_terrain_plants.erase(plant)
	var terrain_cells: Array = _terrain_support_cells_by_plant.get(plant, [])
	_terrain_support_cells_by_plant.erase(plant)
	for cell_variant in terrain_cells:
		var terrain_cell: Vector2i = cell_variant
		var affected_plants := (
			_terrain_support_plants_by_cell.get(terrain_cell, {}) as Dictionary
		)
		affected_plants.erase(plant)
		if affected_plants.is_empty():
			_terrain_support_plants_by_cell.erase(terrain_cell)
		else:
			_terrain_support_plants_by_cell[terrain_cell] = affected_plants


func _refresh_plant_terrain_support(plant: PlantDefense) -> void:
	if (
		plant == null
		or not is_instance_valid(plant)
		or not plant_footprints.has(plant)
		or plant.is_dead
		or plant.is_removing
		or plant.is_multiplayer_proxy
		or plant.is_queued_for_deletion()
		or terrain_map == null
		or terrain_map.world_map_layer == null
		or ground_tile_map == null
	):
		_unregister_plant_terrain_support(plant)
		return
	var config := _registered_plant_configs.get(plant) as PlantDefenseConfig
	if config == null:
		push_error("PlantSystem is missing a config during terrain support refresh.")
		_unsupported_terrain_plants.erase(plant)
		return
	var footprint: Array = plant_footprints[plant]
	for cell_variant in footprint:
		var cell: Vector2i = cell_variant
		if not _is_ground_cell_terrain_supported_for_config(cell, config):
			_unsupported_terrain_plants[plant] = true
			return
	_unsupported_terrain_plants.erase(plant)


func _is_terrain_supported_for_config(
	cell: Vector2i,
	config: PlantDefenseConfig
) -> bool:
	if terrain_map == null or config == null:
		return false
	match config.placement_surface:
		PlantDefenseConfig.PlacementSurface.GRASS_ONLY:
			return terrain_map.is_cell_plantable(cell)
		PlantDefenseConfig.PlacementSurface.ANY_LAND:
			var terrain_type := terrain_map.get_terrain_type(cell)
			return (
				terrain_type == DualGridTilemap.TerrainType.GRASS
				or terrain_type == DualGridTilemap.TerrainType.DIRT
				or terrain_type == DualGridTilemap.TerrainType.METAL
			)
		PlantDefenseConfig.PlacementSurface.WATER_ONLY:
			return (
				terrain_map.get_terrain_type(cell)
				== DualGridTilemap.TerrainType.WATER
			)
		_:
			return false


func _is_entity_space_clear(
	top_left_cell: Vector2i,
	config: PlantDefenseConfig
) -> bool:
	if not is_inside_tree():
		return false

	var tile_size := Vector2(ground_tile_map.tile_set.tile_size)
	var query_shape := RectangleShape2D.new()
	query_shape.size = tile_size * Vector2(config.footprint_size) - FOOTPRINT_COLLISION_INSET

	var query := PhysicsShapeQueryParameters2D.new()
	query.shape = query_shape
	query.transform = Transform2D(0.0, get_anchor_world_position(top_left_cell, config))
	query.collision_mask = ENTITY_BLOCKING_MASK
	query.collide_with_areas = true
	query.collide_with_bodies = true
	return ground_tile_map.get_world_2d().direct_space_state.intersect_shape(query, 1).is_empty()


func _refresh_cardinal_connections_around(changed_cell: Vector2i) -> void:
	_last_cardinal_connection_refresh_metrics["cells_visited"] = 0
	_last_cardinal_connection_refresh_metrics["plants_updated"] = 0
	_last_cardinal_connection_refresh_metrics["masks_changed"] = 0
	for offset in CARDINAL_REFRESH_OFFSETS:
		_last_cardinal_connection_refresh_metrics["cells_visited"] += 1
		var cell: Vector2i = changed_cell + offset
		var plant := occupied_cells.get(cell) as PlantDefense
		if plant == null:
			continue
		var config := _registered_plant_configs.get(plant) as PlantDefenseConfig
		if config == null:
			push_error("PlantSystem is missing a config during cardinal refresh.")
			continue
		if not config.uses_cardinal_connections():
			continue
		var cardinal_plant := plant as CardinalConnectedPlant
		if cardinal_plant == null:
			push_error(
				"Cardinal connection config requires CardinalConnectedPlant: %s"
				% config.plant_id
			)
			continue
		var new_mask := _calculate_cardinal_connection_mask(cell, config)
		if new_mask == cardinal_plant.get_cardinal_connection_mask():
			continue
		_last_cardinal_connection_refresh_metrics["masks_changed"] += 1
		cardinal_plant.set_cardinal_connection_mask(new_mask)
		_last_cardinal_connection_refresh_metrics["plants_updated"] += 1


func _calculate_cardinal_connection_mask(
	cell: Vector2i,
	config: PlantDefenseConfig
) -> int:
	var mask := 0
	for neighbor_index in range(CARDINAL_NEIGHBOR_OFFSETS.size()):
		var neighbor_cell: Vector2i = cell + CARDINAL_NEIGHBOR_OFFSETS[neighbor_index]
		var neighbor := occupied_cells.get(neighbor_cell) as PlantDefense
		if neighbor == null:
			continue
		var neighbor_config := (
			_registered_plant_configs.get(neighbor) as PlantDefenseConfig
		)
		if neighbor_config == null:
			push_error("PlantSystem is missing a neighbor config during cardinal refresh.")
			continue
		if (
			neighbor_config.cardinal_connection_group
			!= config.cardinal_connection_group
		):
			continue
		mask |= CARDINAL_NEIGHBOR_BITS[neighbor_index]
	return mask


func _register_plant_footprint(
	plant: PlantDefense,
	cells: Array[Vector2i],
	config: PlantDefenseConfig
) -> void:
	_unregister_plant_terrain_support(plant)
	_registered_plant_configs[plant] = config
	plant_footprints[plant] = cells.duplicate()
	for cell in cells:
		occupied_cells[cell] = plant
	if not _plant_target_spatial_index.register(plant, plant.global_position):
		push_error("PlantSystem failed to register a plant target spatial entry.")
	if config.is_proactive_enemy_target():
		_enemy_target_plants[plant] = true
		if not _enemy_target_spatial_index.register(plant, plant.global_position):
			push_error("PlantSystem failed to register an enemy target spatial entry.")
	if config.uses_cardinal_connections():
		_refresh_cardinal_connections_around(cells[0])
	occupancy_changed.emit()


func _release_plant_footprint(plant: PlantDefense) -> void:
	if plant == null or not plant_footprints.has(plant):
		return

	var cells: Array = plant_footprints[plant]
	var config := _registered_plant_configs.get(plant) as PlantDefenseConfig
	if config == null:
		push_error("PlantSystem is missing the explicit config for a registered plant.")
		return
	if not _plant_target_spatial_index.unregister(plant):
		push_error("PlantSystem failed to unregister a plant target spatial entry.")
	if _enemy_target_plants.erase(plant):
		if not _enemy_target_spatial_index.unregister(plant):
			push_error("PlantSystem failed to unregister an enemy target spatial entry.")
	_unregister_plant_terrain_support(plant)
	plant_footprints.erase(plant)
	_registered_plant_configs.erase(plant)
	var net_id := int(plant.get_meta(&"net_id", 0)) if is_instance_valid(plant) else 0
	if net_id > 0 and plants_by_net_id.get(net_id) == plant:
		plants_by_net_id.erase(net_id)
	for cell_variant in cells:
		var cell: Vector2i = cell_variant
		if occupied_cells.get(cell) == plant:
			occupied_cells.erase(cell)
	if config.uses_cardinal_connections():
		_refresh_cardinal_connections_around(cells[0])
	occupancy_changed.emit()
	plant_removed.emit(plant)


func _on_plant_removal_started(_mode: int, plant: PlantDefense) -> void:
	_release_plant_footprint(plant)


func _on_plant_tree_exiting(plant: PlantDefense) -> void:
	_release_plant_footprint(plant)
