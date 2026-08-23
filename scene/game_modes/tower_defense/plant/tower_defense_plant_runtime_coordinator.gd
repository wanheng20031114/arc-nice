extends Node
class_name TowerDefensePlantRuntimeCoordinator

signal terrain_delta(revision: int, cell_xy: PackedInt32Array, terrain_types: PackedInt32Array)
signal plant_removed_for_target_cleanup(plant: PlantDefense)
signal plant_health_changed(net_id: int, current_health: int, maximum_health: int, revision: int)
signal plant_damage_status_changed(net_id: int, status_mask: int, revision: int)
signal plant_damage_applied(
	net_id: int,
	amount: int,
	direction: Vector2,
	damage_type: EnemyConfig.DamageType,
	position: Vector2
)
signal plant_healing_applied(net_id: int, amount: int, position: Vector2)
signal plant_spawned(
	request_id: int,
	owner_peer_id: int,
	net_id: int,
	plant_id: StringName,
	anchor: Vector2i,
	current_health: int,
	maximum_health: int,
	health_revision: int
)
signal plant_placement_rejected(request_id: int, requester_peer_id: int, reason: StringName)
signal placement_request_succeeded(request_id: int, placement_player: Player)
signal inventory_changed(peer_id: int)
signal enemy_retarget_requested
signal placement_presentation_requested(plant: PlantDefense)
signal removal_presentation_requested(plant: PlantDefense)
signal modal_ui_visibility_changed(is_open: bool)
signal progression_plant_placed(plant: PlantDefense)
signal network_plant_removed(net_id: int, was_destroyed: bool)

const PLACEMENT_REJECT_INVALID_REQUEST := &"invalid_request"
const PLACEMENT_REJECT_INVALID_PLAYER := &"invalid_player"
const PLACEMENT_REJECT_INVALID_CONFIG := &"invalid_config"
const PLACEMENT_REJECT_INVALID_POSITION := &"invalid_position"
const PLACEMENT_REJECT_INVALID_INVENTORY_ITEM := &"invalid_inventory_item"
const PLACEMENT_REJECT_STALE_INVENTORY := &"stale_inventory"
const PLACEMENT_REJECT_FREE_DISABLED := &"free_placement_disabled"
const PLACEMENT_REJECT_FLOW_LOCKED := &"flow_locked"
const TERRAIN_NETWORK_BATCH_MAX_CELLS := 96
const UNSUPPORTED_PLANT_DAMAGE_INTERVAL_SECONDS := 1.0
const PLAYER_PLANT_DESTRUCTION_RADIUS_CELLS := 3.0

@export_group("场景依赖")
@export var authored_ground_tile_map_layer: TileMapLayer
@export var authored_dual_grid_terrain: DualGridTilemap
@export var authored_vegetation_spread_system: VegetationSpreadSystem
@export var authored_plant_system: PlantSystem
@export var authored_plant_placement_controller: PlantPlacementController
@export var authored_plant_container: Node2D
@export var authored_gameplay_port: TowerPlantGameplayPort
@export var authored_orange_aura_coordinator: OrangeChargingAuraCoordinator
@export var authored_player_spawn: Marker2D
@export var authored_home_gate_controller: HomeGateController
@export var authored_enemy_spawn_points_root: Node2D
@export var authored_merchant: Node2D
@export var authored_luoxi_merchant: Node2D
@export var authored_terrain_decay_timer: Timer
@export var authored_production_coordinator: ProductionCoordinator
@export var authored_research_coordinator: ResearchCoordinator
@export var authored_oak_warehouse_panel: OakWarehousePanel
@export var authored_production_building_panel: ProductionBuildingPanel
@export var authored_research_center_panel: ResearchCenterPanel
@export var authored_bamboo_mortar_combat_system: BambooMortarCombatSystem

var multiplayer_terrain_revision := 0
var authored_terrain_baseline: Dictionary = {}
var multiplayer_terrain_overrides: Dictionary = {}
var next_multiplayer_plant_net_id := 1

var _runtime_mode := CombatRuntimeBase.RuntimeMode.SINGLEPLAYER
var _dual_grid_terrain: DualGridTilemap
var _vegetation_spread_system: VegetationSpreadSystem
var _plant_system: PlantSystem
var _plant_placement_controller: PlantPlacementController
var _run_state: RunStateStore
var _production_coordinator: ProductionCoordinator
var _research_coordinator: ResearchCoordinator
var _oak_warehouse_panel: OakWarehousePanel
var _production_building_panel: ProductionBuildingPanel
var _research_center_panel: ResearchCenterPanel
var _bamboo_mortar_combat_system: BambooMortarCombatSystem
var _terrain_network_batch_max_cells := 1
var _recipe_notify_buildings: Array[ProductionBuilding] = []


func initialize_authored_runtime(
	new_runtime_mode: int,
	combat_runtime: CombatRuntimeBase,
	local_player: Player,
	run_state: RunStateStore,
	spawn_offsets: Array[Vector2]
) -> bool:
	if not _has_complete_authored_bindings():
		push_error("PlantRuntimeCoordinator: 静态植物场景依赖绑定不完整。")
		return false
	if combat_runtime == null or local_player == null:
		push_error("PlantRuntimeCoordinator: 缺少战斗运行时或本地玩家。")
		return false

	setup(
		new_runtime_mode,
		authored_dual_grid_terrain,
		authored_vegetation_spread_system,
		authored_plant_system,
		authored_plant_placement_controller
	)
	configure_mode_services(
		run_state,
		authored_production_coordinator,
		authored_research_coordinator,
		authored_oak_warehouse_panel,
		authored_production_building_panel,
		authored_research_center_panel,
		authored_bamboo_mortar_combat_system,
		TERRAIN_NETWORK_BATCH_MAX_CELLS
	)

	var placement_rect := PlantSystem.DEFAULT_PLACEMENT_AREA
	if authored_dual_grid_terrain.world_map_layer != null:
		var authored_terrain_rect := (
			authored_dual_grid_terrain.world_map_layer.get_used_rect()
		)
		if authored_terrain_rect.size.x > 0 and authored_terrain_rect.size.y > 0:
			placement_rect = authored_terrain_rect

	authored_plant_system.setup(
		authored_ground_tile_map_layer,
		local_player,
		authored_plant_container,
		placement_rect,
		authored_dual_grid_terrain,
		combat_runtime,
		authored_gameplay_port
	)
	authored_orange_aura_coordinator.setup(authored_plant_system)
	if not configure_vegetation(placement_rect):
		push_error("PlantRuntimeCoordinator: 植被传播节点或地形节点缺失。")
	_reserve_authored_cells(spawn_offsets)
	_configure_terrain_decay_timer(new_runtime_mode)
	return true


func _has_complete_authored_bindings() -> bool:
	return (
		authored_ground_tile_map_layer != null
		and authored_dual_grid_terrain != null
		and authored_vegetation_spread_system != null
		and authored_plant_system != null
		and authored_plant_placement_controller != null
		and authored_plant_container != null
		and authored_gameplay_port != null
		and authored_orange_aura_coordinator != null
		and authored_player_spawn != null
		and authored_home_gate_controller != null
		and authored_enemy_spawn_points_root != null
		and authored_merchant != null
		and authored_luoxi_merchant != null
		and authored_terrain_decay_timer != null
		and authored_production_coordinator != null
		and authored_research_coordinator != null
		and authored_oak_warehouse_panel != null
		and authored_production_building_panel != null
		and authored_research_center_panel != null
		and authored_bamboo_mortar_combat_system != null
	)


func _reserve_authored_cells(spawn_offsets: Array[Vector2]) -> void:
	authored_plant_system.clear_reserved_cells()
	for spawn_offset in spawn_offsets:
		authored_plant_system.reserve_world_position(
			authored_player_spawn.global_position + spawn_offset
		)
	for home_cell in authored_home_gate_controller.get_home_gate_cells():
		authored_plant_system.reserve_cell(home_cell)
	for child in authored_enemy_spawn_points_root.get_children():
		var spawn_point := child as Marker2D
		if spawn_point != null:
			authored_plant_system.reserve_world_position(spawn_point.global_position, 1)
	authored_plant_system.reserve_world_position(authored_merchant.global_position)
	authored_plant_system.reserve_world_position(authored_luoxi_merchant.global_position)


func _configure_terrain_decay_timer(new_runtime_mode: int) -> void:
	authored_terrain_decay_timer.one_shot = false
	authored_terrain_decay_timer.wait_time = UNSUPPORTED_PLANT_DAMAGE_INTERVAL_SECONDS
	authored_terrain_decay_timer.process_callback = Timer.TIMER_PROCESS_PHYSICS
	if new_runtime_mode == CombatRuntimeBase.RuntimeMode.CLIENT_VIEW:
		authored_terrain_decay_timer.stop()
	else:
		authored_terrain_decay_timer.start()


func setup(
	runtime_mode: int,
	dual_grid_terrain: DualGridTilemap,
	vegetation_spread_system: VegetationSpreadSystem,
	plant_system: PlantSystem,
	plant_placement_controller: PlantPlacementController
) -> void:
	_runtime_mode = runtime_mode
	_dual_grid_terrain = dual_grid_terrain
	_vegetation_spread_system = vegetation_spread_system
	_plant_system = plant_system
	_plant_placement_controller = plant_placement_controller


func configure_mode_services(
	run_state: RunStateStore,
	production_coordinator: ProductionCoordinator,
	research_coordinator: ResearchCoordinator,
	oak_warehouse_panel: OakWarehousePanel,
	production_building_panel: ProductionBuildingPanel,
	research_center_panel: ResearchCenterPanel,
	bamboo_mortar_combat_system: BambooMortarCombatSystem,
	terrain_network_batch_max_cells: int
) -> void:
	_disconnect_research_spread_signal()
	_run_state = run_state
	_production_coordinator = production_coordinator
	_research_coordinator = research_coordinator
	_oak_warehouse_panel = oak_warehouse_panel
	_production_building_panel = production_building_panel
	_research_center_panel = research_center_panel
	_bamboo_mortar_combat_system = bamboo_mortar_combat_system
	_terrain_network_batch_max_cells = maxi(terrain_network_batch_max_cells, 1)
	_connect_research_spread_signal()
	_refresh_vegetation_spread_speed()


func close_economy_modals_for_mode_transfer() -> void:
	_oak_warehouse_panel.close()
	_production_building_panel.close()
	_research_center_panel.close()


func configure_vegetation(placement_rect: Rect2i) -> bool:
	authored_terrain_baseline.clear()
	multiplayer_terrain_overrides.clear()
	multiplayer_terrain_revision = 0
	if _dual_grid_terrain == null or _vegetation_spread_system == null:
		return false
	for y in range(placement_rect.position.y, placement_rect.end.y):
		for x in range(placement_rect.position.x, placement_rect.end.x):
			var cell := Vector2i(x, y)
			authored_terrain_baseline[cell] = _dual_grid_terrain.get_terrain_type(cell)
	_vegetation_spread_system.setup(
		_dual_grid_terrain,
		placement_rect,
		_runtime_mode != CombatRuntimeBase.RuntimeMode.CLIENT_VIEW
	)
	_refresh_vegetation_spread_speed()
	if not _vegetation_spread_system.authoritative_terrain_changed.is_connected(
		_on_authoritative_vegetation_terrain_changed
	):
		_vegetation_spread_system.authoritative_terrain_changed.connect(
			_on_authoritative_vegetation_terrain_changed
		)
	return true


func set_runtime_mode(runtime_mode: int) -> void:
	_runtime_mode = runtime_mode


func get_terrain_snapshot() -> Dictionary:
	var cells: Array[Vector2i] = []
	for cell_variant in multiplayer_terrain_overrides:
		cells.append(cell_variant as Vector2i)
	cells.sort_custom(_sort_terrain_cells)
	var cell_xy := PackedInt32Array()
	var terrain_types := PackedInt32Array()
	for cell in cells:
		cell_xy.append(cell.x)
		cell_xy.append(cell.y)
		terrain_types.append(int(multiplayer_terrain_overrides[cell]))
	return {
		"revision": multiplayer_terrain_revision,
		"cell_xy": cell_xy,
		"terrain_types": terrain_types,
	}


func has_multiplayer_plant(net_id: int) -> bool:
	var plant := get_multiplayer_plant(net_id)
	return (
		plant != null
		and is_instance_valid(plant)
		and not plant.is_dead
		and not plant.is_removing
	)


func get_multiplayer_plant(net_id: int) -> PlantDefense:
	return _plant_system.get_plant_by_net_id(net_id) if _plant_system != null and net_id > 0 else null


func get_multiplayer_plant_snapshots() -> Array[Dictionary]:
	var snapshots: Array[Dictionary] = []
	if _plant_system == null:
		return snapshots
	var net_ids: Array[int] = []
	for net_id_variant in _plant_system.plants_by_net_id:
		net_ids.append(int(net_id_variant))
	net_ids.sort()
	for net_id in net_ids:
		var plant := _plant_system.get_plant_by_net_id(net_id)
		if (
			plant == null
			or not is_instance_valid(plant)
			or plant.is_dead
			or plant.is_removing
			or plant.config == null
			or plant.footprint_cells.is_empty()
		):
			continue
		var owner_peer_id := (
			plant.owner_player.peer_id
			if plant.owner_player != null and is_instance_valid(plant.owner_player)
			else 0
		)
		snapshots.append({
			"owner_peer_id": owner_peer_id,
			"net_id": net_id,
			"plant_id": plant.config.plant_id,
			"anchor": plant.footprint_cells[0],
			"current_health": plant.current_health,
			"maximum_health": plant.max_health,
			"health_revision": plant.health_revision,
		})
	return snapshots


func get_authoritative_team_plant_count() -> int:
	return _plant_system.plants_by_net_id.size() if _plant_system != null else -1


func find_nearest_operational_interaction_building(
	world_position: Vector2,
	maximum_distance: float
) -> PlantDefense:
	if _plant_system == null:
		return null
	return _plant_system.find_nearest_operational_interaction_building_world(
		world_position,
		maximum_distance
	)


func find_nearest_player_destroyable_plant(player: Player) -> PlantDefense:
	if (
		_plant_system == null
		or player == null
		or not is_instance_valid(player)
		or player.is_dead
	):
		return null
	return _plant_system.find_nearest_living_plant_in_logical_radius(
		player.global_position,
		PLAYER_PLANT_DESTRUCTION_RADIUS_CELLS
	)


## Authoritative one-shot destruction. Multiplayer callers pass the target seen
## by the client; the Host recomputes the nearest target and rejects any stale,
## spoofed or out-of-range id instead of deleting a different building.
func destroy_nearest_plant_for_player(
	player: Player,
	expected_net_id: int = 0
) -> bool:
	if _runtime_mode == CombatRuntimeBase.RuntimeMode.CLIENT_VIEW:
		return false
	var nearest := find_nearest_player_destroyable_plant(player)
	if nearest == null:
		return false
	if expected_net_id > 0:
		var authoritative_net_id := int(nearest.get_meta(&"net_id", 0))
		if authoritative_net_id != expected_net_id:
			return false
	if nearest.current_health <= 0:
		return false
	return nearest.receive_unmitigated_damage(nearest.current_health, player)


func find_nearest_enemy_attack_target_world(
	from_position: Vector2,
	max_distance: float,
	excluded_instance_ids: Dictionary,
	neutral_target: Node2D
) -> Node2D:
	if _plant_system == null or max_distance < 0.0 or not is_finite(max_distance):
		return neutral_target
	var nearest_plant := _plant_system.find_nearest_enemy_attack_target_world(
		from_position, max_distance, excluded_instance_ids
	)
	if nearest_plant == null:
		return neutral_target
	var plant_distance_squared := from_position.distance_squared_to(
		nearest_plant.global_position
	)
	if plant_distance_squared > max_distance * max_distance:
		return neutral_target
	if neutral_target == null:
		return nearest_plant
	var neutral_distance_squared := from_position.distance_squared_to(
		neutral_target.global_position
	)
	if plant_distance_squared < neutral_distance_squared:
		return nearest_plant
	if (
		plant_distance_squared == neutral_distance_squared
		and nearest_plant.get_instance_id() < neutral_target.get_instance_id()
	):
		return nearest_plant
	return neutral_target


func find_nearest_enemy_objective(
	from_position: Vector2,
	maximum_distance_cells: int,
	include_water_plants: bool
) -> PlantDefense:
	if _plant_system == null:
		return null
	return _plant_system.find_nearest_enemy_objective(
		from_position, maximum_distance_cells, include_water_plants
	)


func apply_remote_plant_health(
	net_id: int,
	current_health: int,
	maximum_health: int,
	health_revision: int
) -> void:
	if _runtime_mode != CombatRuntimeBase.RuntimeMode.CLIENT_VIEW:
		return
	var plant := get_multiplayer_plant(net_id)
	if plant != null and is_instance_valid(plant):
		plant.apply_remote_health(current_health, maximum_health, health_revision)


func apply_remote_plant_spawn(
	request_id: int,
	owner: Player,
	net_id: int,
	plant_id: StringName,
	anchor: Vector2i,
	current_health: int,
	maximum_health: int,
	health_revision: int
) -> void:
	if _runtime_mode != CombatRuntimeBase.RuntimeMode.CLIENT_VIEW or _plant_system == null:
		return
	var replica := _plant_system.spawn_multiplayer_replica(
		plant_id,
		anchor,
		owner,
		net_id,
		current_health,
		maximum_health,
		health_revision,
		request_id > 0
	)
	if replica != null:
		replica.apply_remote_health(current_health, maximum_health, health_revision)
		placement_request_succeeded.emit(request_id, owner)


func apply_remote_plant_removed(net_id: int, was_destroyed: bool, silent: bool) -> void:
	if _runtime_mode != CombatRuntimeBase.RuntimeMode.CLIENT_VIEW or _plant_system == null:
		return
	var plant := _plant_system.get_plant_by_net_id(net_id)
	if plant != null and is_instance_valid(plant) and was_destroyed:
		plant.current_health = 0
		plant.is_dead = true
	_plant_system.remove_plant_by_net_id(
		net_id,
		PlantDefense.RemovalMode.SILENT if silent else PlantDefense.RemovalMode.ANIMATED
	)


func apply_remote_placement_rejected(request_id: int) -> void:
	if (
		_runtime_mode == CombatRuntimeBase.RuntimeMode.SINGLEPLAYER
		or _plant_placement_controller == null
	):
		return
	_plant_placement_controller.notify_multiplayer_placement_rejected(request_id)


func request_singleplayer_catalog_placement(
	request_id: int,
	plant_id: StringName,
	anchor: Vector2i,
	run_state: RunStateStore,
	placement_player: Player,
	flow_locked: bool,
	free_building_enabled: bool
) -> void:
	if flow_locked or request_id <= 0 or not _is_valid_placement_player(placement_player):
		_notify_local_placement_rejected(request_id)
		return
	var plant_config := _plant_system.get_config(plant_id) if _plant_system != null else null
	if (
		plant_config == null
		or not plant_config.is_valid()
		or not _plant_system.is_placement_valid_for_player(
			anchor,
			plant_config,
			placement_player
		)
	):
		_notify_local_placement_rejected(request_id)
		return
	if free_building_enabled:
		if _plant_system.try_place_for_player(
			plant_config,
			anchor,
			placement_player
		) == null:
			_notify_local_placement_rejected(request_id)
		else:
			placement_request_succeeded.emit(request_id, placement_player)
		return
	if run_state == null:
		_notify_local_placement_rejected(request_id)
		return
	var building_item := BuildingItemRegistry.get_item(plant_id)
	if not _is_canonical_building_item(building_item, plant_id):
		_notify_local_placement_rejected(request_id)
		return
	var inventory_slot := _find_inventory_item_slot(
		run_state,
		0,
		building_item
	)
	if inventory_slot >= 0:
		var inventory_revision := run_state.get_inventory_revision()
		if not run_state.try_consume_item_at_slot_if_revision(
			inventory_slot,
			building_item,
			inventory_revision,
			false
		):
			_notify_local_placement_rejected(request_id)
			return
		var placed_plant := _plant_system.try_place_for_player(
			plant_config,
			anchor,
			placement_player
		)
		if placed_plant == null:
			var restored := run_state.try_add_item_count_to_slot_if_revision(
				building_item,
				1,
				inventory_slot,
				run_state.get_inventory_revision(),
				false
			)
			if not restored:
				push_error(
					"Failed to restore a catalog building item after placement."
				)
		run_state.notify_inventory_transaction_completed()
		if placed_plant == null:
			_notify_local_placement_rejected(request_id)
		else:
			placement_request_succeeded.emit(request_id, placement_player)
		return
	if _production_coordinator == null:
		_notify_local_placement_rejected(request_id)
		return
	var result := _production_coordinator.try_consume_item_requirements_with_action(
		[{"item": building_item, "count": 1}],
		func() -> bool:
			return _plant_system.try_place_for_player(
				plant_config,
				anchor,
				placement_player
			) != null
	)
	if result != ProductionCoordinator.RESULT_SUCCESS:
		_notify_local_placement_rejected(request_id)
	else:
		placement_request_succeeded.emit(request_id, placement_player)


func request_singleplayer_inventory_placement(
	request_id: int,
	plant_id: StringName,
	anchor: Vector2i,
	slot_index: int,
	expected_inventory_revision: int,
	item_config_path: String,
	run_state: RunStateStore,
	placement_player: Player,
	flow_locked: bool
) -> void:
	if flow_locked:
		_notify_local_placement_rejected(request_id)
		return
	var stored_item := run_state.get_item(slot_index)
	var config := _plant_system.get_config(plant_id) if _plant_system != null else null
	if (
		request_id <= 0
		or stored_item == null
		or stored_item.resource_path != item_config_path
		or stored_item.pickup_type != PickupConfig.PickupType.BUILDING
		or stored_item.placeable_plant_id != plant_id
		or config == null
		or not config.is_valid()
		or not _plant_system.is_placement_valid_for_player(anchor, config, placement_player)
	):
		_notify_local_placement_rejected(request_id)
		return
	if not run_state.try_consume_item_at_slot_if_revision(
		slot_index, stored_item, expected_inventory_revision, false
	):
		_notify_local_placement_rejected(request_id)
		return
	var placed_plant := _plant_system.try_place_for_player(config, anchor, placement_player)
	if placed_plant == null:
		var restored := run_state.try_add_item_count_to_slot_if_revision(
			stored_item,
			1,
			slot_index,
			run_state.get_inventory_revision(),
			false
		)
		if not restored:
			push_error("Failed to restore a consumed building item after placement.")
		run_state.notify_inventory_transaction_completed()
		_notify_local_placement_rejected(request_id)
		return
	run_state.notify_inventory_transaction_completed()
	placement_request_succeeded.emit(request_id, placement_player)


func request_multiplayer_free_placement(
	requester_peer_id: int,
	request_id: int,
	plant_id: StringName,
	anchor: Vector2i,
	placement_player: Player,
	flow_locked: bool,
	free_building_enabled: bool
) -> void:
	if _runtime_mode != CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY:
		return
	if flow_locked:
		_reject_placement(request_id, requester_peer_id, PLACEMENT_REJECT_FLOW_LOCKED)
		return
	if not free_building_enabled:
		_reject_placement(request_id, requester_peer_id, PLACEMENT_REJECT_FREE_DISABLED)
		return
	if request_id <= 0 or requester_peer_id <= 0:
		_reject_placement(request_id, requester_peer_id, PLACEMENT_REJECT_INVALID_REQUEST)
		return
	if not _is_valid_placement_player(placement_player):
		_reject_placement(request_id, requester_peer_id, PLACEMENT_REJECT_INVALID_PLAYER)
		return
	var plant_config := _plant_system.get_config(plant_id) if _plant_system != null else null
	if plant_config == null or not plant_config.is_valid() or not plant_config.supports_multiplayer:
		_reject_placement(request_id, requester_peer_id, PLACEMENT_REJECT_INVALID_CONFIG)
		return
	_spawn_authoritative_plant(
		requester_peer_id, request_id, plant_config, anchor, placement_player
	)


func request_multiplayer_catalog_placement(
	requester_peer_id: int,
	request_id: int,
	plant_id: StringName,
	anchor: Vector2i,
	run_state: RunStateStore,
	placement_player: Player,
	flow_locked: bool,
	free_building_enabled: bool
) -> void:
	if _runtime_mode != CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY:
		return
	if free_building_enabled:
		request_multiplayer_free_placement(
			requester_peer_id,
			request_id,
			plant_id,
			anchor,
			placement_player,
			flow_locked,
			true
		)
		return
	if flow_locked:
		_reject_placement(request_id, requester_peer_id, PLACEMENT_REJECT_FLOW_LOCKED)
		return
	if request_id <= 0 or requester_peer_id <= 0 or run_state == null:
		_reject_placement(request_id, requester_peer_id, PLACEMENT_REJECT_INVALID_REQUEST)
		return
	if not _is_valid_placement_player(placement_player):
		_reject_placement(request_id, requester_peer_id, PLACEMENT_REJECT_INVALID_PLAYER)
		return
	var plant_config := _plant_system.get_config(plant_id) if _plant_system != null else null
	if plant_config == null or not plant_config.is_valid() or not plant_config.supports_multiplayer:
		_reject_placement(request_id, requester_peer_id, PLACEMENT_REJECT_INVALID_CONFIG)
		return
	if not _plant_system.is_placement_valid_for_player(anchor, plant_config, placement_player):
		_reject_placement(request_id, requester_peer_id, PLACEMENT_REJECT_INVALID_POSITION)
		return
	var building_item := BuildingItemRegistry.get_item(plant_id)
	if not _is_canonical_building_item(building_item, plant_id):
		_reject_placement(
			request_id,
			requester_peer_id,
			PLACEMENT_REJECT_INVALID_INVENTORY_ITEM
		)
		return
	var inventory_slot := _find_inventory_item_slot(
		run_state,
		requester_peer_id,
		building_item
	)
	if inventory_slot >= 0:
		var inventory_revision := run_state.get_inventory_revision_for_peer(
			requester_peer_id
		)
		if not run_state.try_consume_item_at_slot_for_peer_if_revision(
			requester_peer_id,
			inventory_slot,
			building_item,
			inventory_revision,
			false
		):
			_reject_placement(
				request_id,
				requester_peer_id,
				PLACEMENT_REJECT_STALE_INVENTORY
			)
			return
		var placed_plant := _spawn_authoritative_plant(
			requester_peer_id,
			request_id,
			plant_config,
			anchor,
			placement_player
		)
		if placed_plant == null:
			var restored := run_state.try_add_item_count_to_slot_for_peer_if_revision(
				requester_peer_id,
				building_item,
				1,
				inventory_slot,
				run_state.get_inventory_revision_for_peer(requester_peer_id),
				false
			)
			if not restored:
				push_error(
					"Failed to restore a peer catalog building item after placement."
				)
		run_state.notify_inventory_transaction_completed()
		inventory_changed.emit(requester_peer_id)
		return
	if _production_coordinator == null:
		_reject_placement(
			request_id,
			requester_peer_id,
			PLACEMENT_REJECT_INVALID_INVENTORY_ITEM
		)
		return
	var result := _production_coordinator.try_consume_item_requirements_with_action(
		[{"item": building_item, "count": 1}],
		func() -> bool:
			return _spawn_authoritative_plant(
				requester_peer_id,
				request_id,
				plant_config,
				anchor,
				placement_player
			) != null
	)
	if result not in [
		ProductionCoordinator.RESULT_SUCCESS,
		ProductionCoordinator.RESULT_ACTION_FAILED,
	]:
		_reject_placement(
			request_id,
			requester_peer_id,
			PLACEMENT_REJECT_INVALID_INVENTORY_ITEM
		)


func request_multiplayer_inventory_placement(
	requester_peer_id: int,
	request_id: int,
	plant_id: StringName,
	anchor: Vector2i,
	slot_index: int,
	expected_inventory_revision: int,
	item_config_path: String,
	run_state: RunStateStore,
	placement_player: Player,
	flow_locked: bool
) -> void:
	if _runtime_mode != CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY:
		return
	if flow_locked:
		_reject_placement(request_id, requester_peer_id, PLACEMENT_REJECT_FLOW_LOCKED)
		return
	if (
		request_id <= 0
		or requester_peer_id <= 0
		or slot_index < 0
		or expected_inventory_revision < 0
		or item_config_path.is_empty()
	):
		_reject_placement(request_id, requester_peer_id, PLACEMENT_REJECT_INVALID_REQUEST)
		return
	if not _is_valid_placement_player(placement_player):
		_reject_placement(request_id, requester_peer_id, PLACEMENT_REJECT_INVALID_PLAYER)
		return
	if run_state.get_inventory_revision_for_peer(requester_peer_id) != expected_inventory_revision:
		_reject_placement(request_id, requester_peer_id, PLACEMENT_REJECT_STALE_INVENTORY)
		return
	var stored_item := run_state.get_item_for_peer(requester_peer_id, slot_index)
	if (
		stored_item == null
		or stored_item.resource_path != item_config_path
		or stored_item.pickup_type != PickupConfig.PickupType.BUILDING
		or stored_item.placeable_plant_id != plant_id
	):
		_reject_placement(request_id, requester_peer_id, PLACEMENT_REJECT_INVALID_INVENTORY_ITEM)
		return
	var plant_config := _plant_system.get_config(plant_id) if _plant_system != null else null
	if plant_config == null or not plant_config.is_valid() or not plant_config.supports_multiplayer:
		_reject_placement(request_id, requester_peer_id, PLACEMENT_REJECT_INVALID_CONFIG)
		return
	if not _plant_system.is_placement_valid_for_player(anchor, plant_config, placement_player):
		_reject_placement(request_id, requester_peer_id, PLACEMENT_REJECT_INVALID_POSITION)
		return
	if not run_state.try_consume_item_at_slot_for_peer_if_revision(
		requester_peer_id,
		slot_index,
		stored_item,
		expected_inventory_revision,
		false
	):
		_reject_placement(request_id, requester_peer_id, PLACEMENT_REJECT_STALE_INVENTORY)
		return
	var placed_plant := _spawn_authoritative_plant(
		requester_peer_id, request_id, plant_config, anchor, placement_player
	)
	if placed_plant == null:
		var restored := run_state.try_add_item_count_to_slot_for_peer_if_revision(
			requester_peer_id,
			stored_item,
			1,
			slot_index,
			run_state.get_inventory_revision_for_peer(requester_peer_id),
			false
		)
		if not restored:
			push_error("Failed to restore a peer building item after placement.")
		run_state.notify_inventory_transaction_completed()
		inventory_changed.emit(requester_peer_id)
		return
	run_state.notify_inventory_transaction_completed()
	inventory_changed.emit(requester_peer_id)


func handle_plant_placed(plant: PlantDefense) -> void:
	if plant == null:
		return
	if _runtime_mode == CombatRuntimeBase.RuntimeMode.SINGLEPLAYER:
		_assign_singleplayer_plant_net_id(plant)
	progression_plant_placed.emit(plant)
	var hydrangea := plant as HydrangeaRainTower
	if hydrangea != null:
		hydrangea.set_plant_system(_plant_system)
	var orange_charging_tower := plant as OrangeChargingTower
	if orange_charging_tower != null:
		orange_charging_tower.set_ground_tile_map(_plant_system.ground_tile_map)
	if plant.config.is_proactive_enemy_target():
		enemy_retarget_requested.emit()
	if _runtime_mode == CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY:
		var damage_callback := report_authoritative_damage.bind(plant)
		if not plant.damage_applied.is_connected(damage_callback):
			plant.damage_applied.connect(damage_callback)
		var healing_callback := report_authoritative_healing.bind(plant)
		if not plant.healing_applied.is_connected(healing_callback):
			plant.healing_applied.connect(healing_callback)
	if plant.is_construction_visual_active():
		placement_presentation_requested.emit(plant)
	var oak_warehouse := plant as OakWarehouse
	if oak_warehouse != null:
		oak_warehouse.set_shared_storage_panel(_oak_warehouse_panel)
		if _runtime_mode == CombatRuntimeBase.RuntimeMode.SINGLEPLAYER:
			_configure_singleplayer_warehouse_persistence(oak_warehouse)
	if _production_coordinator != null:
		_production_coordinator.register_plant(plant)
	var production_building := plant as ProductionBuilding
	if production_building != null:
		if not _recipe_notify_buildings.has(production_building):
			_recipe_notify_buildings.append(production_building)
		var exit_callback := _on_recipe_notify_building_tree_exiting.bind(
			production_building
		)
		if not production_building.tree_exited.is_connected(exit_callback):
			production_building.tree_exited.connect(exit_callback, CONNECT_ONE_SHOT)
		production_building.set_recipe_unlock_checker(
			Callable(_research_coordinator, "is_global_research_completed")
		)
		production_building.set_shared_production_panel(_production_building_panel)
	var research_center := plant as ResearchCenter
	if research_center != null:
		research_center.set_research_services(
			_research_coordinator, _research_center_panel
		)
	if not plant.modal_ui_visibility_changed.is_connected(
		modal_ui_visibility_changed.emit
	):
		plant.modal_ui_visibility_changed.connect(modal_ui_visibility_changed.emit)
	var vegetation_stake := plant as VegetationStake
	if vegetation_stake == null or _vegetation_spread_system == null:
		return
	vegetation_stake.set_spread_speed_multiplier(
		_vegetation_spread_system.get_spread_speed_multiplier()
	)
	if vegetation_stake.is_operational:
		_activate_vegetation_stake_source(vegetation_stake)
		return
	var construction_callback := _on_vegetation_stake_construction_finished.bind(
		vegetation_stake
	)
	if not vegetation_stake.construction_finished.is_connected(construction_callback):
		vegetation_stake.construction_finished.connect(
			construction_callback, CONNECT_ONE_SHOT
		)


func handle_plant_removed(plant: PlantDefense) -> void:
	if plant == null:
		return
	if _production_coordinator != null:
		_production_coordinator.unregister_plant(plant)
	if plant.config.is_proactive_enemy_target():
		notify_plant_removed(plant)
		enemy_retarget_requested.emit()
	if plant.removal_mode == PlantDefense.RemovalMode.ANIMATED:
		removal_presentation_requested.emit(plant)
	var oak_warehouse := plant as OakWarehouse
	if oak_warehouse != null:
		oak_warehouse.close_storage_panel()
	var production_building := plant as ProductionBuilding
	if production_building != null:
		production_building.close_production_panel()
	var net_id := int(plant.get_meta(&"net_id", 0))
	if _runtime_mode == CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY and net_id > 0:
		network_plant_removed.emit(net_id, plant.is_dead)
	if plant is VegetationStake and _vegetation_spread_system != null:
		_vegetation_spread_system.cancel_source(_get_vegetation_source_id(plant))


func notify_recipe_unlocks_changed() -> void:
	for index in range(_recipe_notify_buildings.size() - 1, -1, -1):
		var building := _recipe_notify_buildings[index]
		if building == null or not is_instance_valid(building):
			_recipe_notify_buildings.remove_at(index)
	var snapshot := _recipe_notify_buildings.duplicate()
	for building in snapshot:
		if building != null and is_instance_valid(building):
			building.notify_recipe_unlocks_changed()


func _connect_research_spread_signal() -> void:
	if (
		_research_coordinator != null
		and not _research_coordinator.research_state_changed.is_connected(
			_refresh_vegetation_spread_speed
		)
	):
		_research_coordinator.research_state_changed.connect(
			_refresh_vegetation_spread_speed
		)


func _disconnect_research_spread_signal() -> void:
	if (
		_research_coordinator != null
		and _research_coordinator.research_state_changed.is_connected(
			_refresh_vegetation_spread_speed
		)
	):
		_research_coordinator.research_state_changed.disconnect(
			_refresh_vegetation_spread_speed
		)


func _refresh_vegetation_spread_speed() -> void:
	var multiplier := 1.0
	if _research_coordinator != null:
		multiplier = (
			_research_coordinator.get_vegetation_spread_speed_multiplier()
		)
	if _vegetation_spread_system != null:
		# 全局科研不可逆；跨信道到达的较旧科研进度不能覆盖植被桩
		# 运行时快照已经携带的更高权威倍率。
		multiplier = maxf(
			multiplier,
			_vegetation_spread_system.get_spread_speed_multiplier()
		)
	if (
		_vegetation_spread_system == null
		or is_equal_approx(
			_vegetation_spread_system.get_spread_speed_multiplier(),
			multiplier
		)
	):
		return
	_vegetation_spread_system.set_spread_speed_multiplier(multiplier)
	if _plant_system == null:
		return
	for plant_variant in _plant_system.plant_footprints:
		var vegetation_stake := plant_variant as VegetationStake
		if vegetation_stake != null and is_instance_valid(vegetation_stake):
			vegetation_stake.set_spread_speed_multiplier(multiplier)


func _on_recipe_notify_building_tree_exiting(building: ProductionBuilding) -> void:
	_recipe_notify_buildings.erase(building)


func apply_unsupported_terrain_damage_tick() -> void:
	if (
		_runtime_mode != CombatRuntimeBase.RuntimeMode.CLIENT_VIEW
		and _plant_system != null
	):
		_plant_system.apply_unsupported_terrain_damage_tick()


func report_authoritative_health(
	current_health: int,
	maximum_health: int,
	health_revision: int,
	net_id: int
) -> void:
	if (
		_runtime_mode == CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY
		and net_id > 0
		and get_multiplayer_plant(net_id) != null
	):
		plant_health_changed.emit(net_id, current_health, maximum_health, health_revision)


func report_authoritative_damage_status(
	status_mask: int,
	status_revision: int,
	net_id: int
) -> void:
	if (
		_runtime_mode == CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY
		and net_id > 0
		and get_multiplayer_plant(net_id) != null
	):
		plant_damage_status_changed.emit(net_id, status_mask, status_revision)


func report_authoritative_damage(
	applied_damage: int,
	impact_direction: Vector2,
	damage_type: EnemyConfig.DamageType,
	plant: PlantDefense
) -> void:
	if (
		_runtime_mode != CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY
		or applied_damage <= 0
		or plant == null
		or not is_instance_valid(plant)
	):
		return
	var net_id := int(plant.get_meta(&"net_id", 0))
	if net_id > 0:
		plant_damage_applied.emit(
			net_id,
			applied_damage,
			impact_direction,
			damage_type,
			plant.get_lifecycle_vfx_global_position()
		)


func report_authoritative_healing(applied_healing: int, plant: PlantDefense) -> void:
	if (
		_runtime_mode != CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY
		or applied_healing <= 0
		or plant == null
		or not is_instance_valid(plant)
	):
		return
	var net_id := int(plant.get_meta(&"net_id", 0))
	if net_id > 0:
		plant_healing_applied.emit(
			net_id, applied_healing, plant.get_lifecycle_vfx_global_position()
		)


func apply_remote_terrain_snapshot(
	revision: int,
	cell_xy: PackedInt32Array,
	terrain_types: PackedInt32Array
) -> bool:
	if _runtime_mode != CombatRuntimeBase.RuntimeMode.CLIENT_VIEW or revision < 0:
		return false
	if terrain_types.is_empty():
		if not cell_xy.is_empty() or _dual_grid_terrain == null:
			return false
	elif not is_valid_terrain_payload(cell_xy, terrain_types):
		return false
	var next_overrides: Dictionary = {}
	for index in range(terrain_types.size()):
		var cell := Vector2i(cell_xy[index * 2], cell_xy[index * 2 + 1])
		var terrain_type := terrain_types[index]
		if terrain_type == int(authored_terrain_baseline[cell]):
			return false
		next_overrides[cell] = terrain_type
	for cell_variant in multiplayer_terrain_overrides:
		var previous_cell := cell_variant as Vector2i
		if not next_overrides.has(previous_cell):
			_dual_grid_terrain.set_tile(
				previous_cell,
				int(authored_terrain_baseline[previous_cell])
			)
	for cell_variant in next_overrides:
		var cell := cell_variant as Vector2i
		_dual_grid_terrain.set_tile(cell, int(next_overrides[cell]))
	multiplayer_terrain_overrides = next_overrides
	multiplayer_terrain_revision = revision
	_refresh_remote_vegetation_overlay()
	return true


func apply_remote_terrain_delta(
	revision: int,
	cell_xy: PackedInt32Array,
	terrain_types: PackedInt32Array
) -> bool:
	if (
		_runtime_mode != CombatRuntimeBase.RuntimeMode.CLIENT_VIEW
		or revision != multiplayer_terrain_revision + 1
		or not is_valid_terrain_payload(cell_xy, terrain_types)
	):
		return false
	for index in range(terrain_types.size()):
		var cell := Vector2i(cell_xy[index * 2], cell_xy[index * 2 + 1])
		var terrain_type := terrain_types[index]
		_dual_grid_terrain.set_tile(cell, terrain_type)
		if terrain_type == int(authored_terrain_baseline[cell]):
			multiplayer_terrain_overrides.erase(cell)
		else:
			multiplayer_terrain_overrides[cell] = terrain_type
	multiplayer_terrain_revision = revision
	_refresh_remote_vegetation_overlay()
	return true


func apply_authoritative_terrain_changes(
	cell_xy: PackedInt32Array,
	terrain_types: PackedInt32Array,
	max_network_batch_cells: int
) -> bool:
	if not is_valid_terrain_payload(cell_xy, terrain_types):
		push_error("PlantRuntimeCoordinator: 植被传播提交了非法地形批次。")
		return false
	for index in range(terrain_types.size()):
		var cell := Vector2i(cell_xy[index * 2], cell_xy[index * 2 + 1])
		var terrain_type := terrain_types[index]
		if terrain_type == int(authored_terrain_baseline[cell]):
			multiplayer_terrain_overrides.erase(cell)
		else:
			multiplayer_terrain_overrides[cell] = terrain_type
	if _runtime_mode != CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY:
		return true
	var batch_size := maxi(max_network_batch_cells, 1)
	for start_index in range(0, terrain_types.size(), batch_size):
		var end_index := mini(start_index + batch_size, terrain_types.size())
		var chunk_cell_xy := PackedInt32Array()
		var chunk_terrain_types := PackedInt32Array()
		for index in range(start_index, end_index):
			chunk_cell_xy.append(cell_xy[index * 2])
			chunk_cell_xy.append(cell_xy[index * 2 + 1])
			chunk_terrain_types.append(terrain_types[index])
		multiplayer_terrain_revision += 1
		terrain_delta.emit(
			multiplayer_terrain_revision,
			chunk_cell_xy,
			chunk_terrain_types
		)
	return true


func is_valid_terrain_payload(
	cell_xy: PackedInt32Array,
	terrain_types: PackedInt32Array
) -> bool:
	if (
		terrain_types.is_empty()
		or cell_xy.size() != terrain_types.size() * 2
		or _dual_grid_terrain == null
	):
		return false
	var previous_cell := Vector2i.ZERO
	var has_previous := false
	for index in range(terrain_types.size()):
		var cell := Vector2i(cell_xy[index * 2], cell_xy[index * 2 + 1])
		var terrain_type := terrain_types[index]
		if not authored_terrain_baseline.has(cell):
			return false
		if terrain_type not in [
			DualGridTilemap.TerrainType.EMPTY,
			DualGridTilemap.TerrainType.GRASS,
			DualGridTilemap.TerrainType.DIRT,
			DualGridTilemap.TerrainType.WATER,
			DualGridTilemap.TerrainType.METAL,
		]:
			return false
		if has_previous and not _sort_terrain_cells(previous_cell, cell):
			return false
		previous_cell = cell
		has_previous = true
	return true


func notify_plant_removed(plant: PlantDefense) -> void:
	if plant != null:
		plant_removed_for_target_cleanup.emit(plant)


func request_bamboo_mortar_target(
	owner: Node2D,
	minimum_range: float,
	maximum_range: float,
	callback: Callable
) -> bool:
	if (
		_runtime_mode == CombatRuntimeBase.RuntimeMode.CLIENT_VIEW
		or _bamboo_mortar_combat_system == null
	):
		return false
	return _bamboo_mortar_combat_system.request_target(
		owner, minimum_range, maximum_range, callback
	)


func cancel_bamboo_mortar_target_request(owner: Node) -> void:
	if _bamboo_mortar_combat_system != null:
		_bamboo_mortar_combat_system.cancel_target_request(owner)


func select_bamboo_mortar_target_sync_for_fixture(
	from_position: Vector2,
	minimum_range: float,
	maximum_range: float
) -> Enemy:
	if _bamboo_mortar_combat_system == null:
		return null
	return _bamboo_mortar_combat_system.select_target_sync_for_fixture(
		from_position, minimum_range, maximum_range
	)


func queue_bamboo_mortar_explosion(
	landing_position: Vector2,
	inner_radius: float,
	outer_radius: float,
	inner_damage: int,
	outer_damage: int,
	damage_source_id: int
) -> bool:
	if (
		_runtime_mode == CombatRuntimeBase.RuntimeMode.CLIENT_VIEW
		or _bamboo_mortar_combat_system == null
	):
		return false
	return _bamboo_mortar_combat_system.queue_explosion(
		landing_position,
		inner_radius,
		outer_radius,
		inner_damage,
		outer_damage,
		damage_source_id
	)


func query_living_plants_in_radius_into(
	center: Vector2,
	radius: float,
	result: Array[PlantDefense]
) -> void:
	result.clear()
	if _plant_system != null:
		_plant_system.query_living_plants_in_world_radius_into(center, radius, result)


func query_living_plants_in_world_aabb_into(
	world_aabb: Rect2,
	result: Array[PlantDefense]
) -> void:
	result.clear()
	if _plant_system != null:
		_plant_system.query_living_plants_in_world_aabb_into(world_aabb, result)


func get_combat_target_plant_net_id(plant: PlantDefense) -> int:
	if plant == null or not is_instance_valid(plant):
		return 0
	var net_id := int(plant.get_meta(&"net_id", 0))
	if net_id <= 0 or _plant_system == null:
		return 0
	return net_id if _plant_system.get_plant_by_net_id(net_id) == plant else 0


func apply_authoritative_enemy_damage_batch(
	damage_source_id: int,
	enemy: Enemy,
	damage_amounts: PackedInt64Array,
	hit_counts: PackedInt32Array,
	impact_direction: Vector2,
	damage_type: EnemyConfig.DamageType
) -> bool:
	if (
		_runtime_mode == CombatRuntimeBase.RuntimeMode.CLIENT_VIEW
		or enemy == null
		or not is_instance_valid(enemy)
		or enemy.is_dead
		or damage_amounts.is_empty()
	):
		return false
	var safe_direction := impact_direction if impact_direction.is_finite() else Vector2.ZERO
	var request := DamageBatchRequest.new(
		damage_amounts, hit_counts, int(damage_type)
	)
	var source_plant := get_multiplayer_plant(damage_source_id)
	var source_snapshot := (
		source_plant.create_damage_source_snapshot(
			damage_source_id,
			&"plant_damage_batch"
		)
		if source_plant != null and is_instance_valid(source_plant)
		else DamageSourceSnapshot.create(
			CombatRelationService.PLAYER_ALLIED,
			0,
			maxi(damage_source_id, 0),
			maxi(damage_source_id, 0),
			&"plant_damage_batch"
		)
	)
	request.with_source_snapshot(source_snapshot)
	request.with_directions(safe_direction)
	return enemy.apply_combat_damage(request).accepted


func get_bamboo_mortar_combat_metrics() -> Dictionary:
	return (
		_bamboo_mortar_combat_system.get_metrics_snapshot()
		if _bamboo_mortar_combat_system != null
		else {}
	)


func _assign_singleplayer_plant_net_id(plant: PlantDefense) -> int:
	var existing_net_id := int(plant.get_meta(&"net_id", 0))
	if existing_net_id > 0:
		next_multiplayer_plant_net_id = maxi(
			next_multiplayer_plant_net_id, existing_net_id + 1
		)
		return existing_net_id
	var assigned_net_id := next_multiplayer_plant_net_id
	plant.set_meta(&"net_id", assigned_net_id)
	next_multiplayer_plant_net_id += 1
	return assigned_net_id


func _configure_singleplayer_warehouse_persistence(warehouse: OakWarehouse) -> void:
	if warehouse == null or _run_state == null:
		return
	var warehouse_net_id := int(warehouse.get_meta(&"net_id", 0))
	if warehouse_net_id <= 0:
		push_error("PlantRuntimeCoordinator: 单人共享仓库缺少稳定运行时ID。")
		return
	var saved_snapshot := _run_state.get_shared_warehouse_snapshot(warehouse_net_id)
	if saved_snapshot.is_empty():
		if not SharedWarehouseLedgerBridge.persist_to_ledger(
			_run_state, warehouse, warehouse_net_id
		):
			push_warning("PlantRuntimeCoordinator: 无法初始化共享仓库跨场景账本。")
	elif not SharedWarehouseLedgerBridge.restore_from_ledger(
		_run_state, warehouse, warehouse_net_id
	):
		push_warning("PlantRuntimeCoordinator: 无法恢复共享仓库跨场景快照。")
	var storage_callback := _on_singleplayer_warehouse_storage_changed.bind(warehouse)
	if not warehouse.storage_changed.is_connected(storage_callback):
		warehouse.storage_changed.connect(storage_callback)
	var removal_callback := _on_singleplayer_warehouse_removal_started.bind(warehouse)
	if not warehouse.removal_started.is_connected(removal_callback):
		warehouse.removal_started.connect(removal_callback)


func _on_singleplayer_warehouse_storage_changed(warehouse: OakWarehouse) -> void:
	if (
		_runtime_mode != CombatRuntimeBase.RuntimeMode.SINGLEPLAYER
		or warehouse == null
		or not is_instance_valid(warehouse)
		or warehouse.is_removing
	):
		return
	var warehouse_net_id := int(warehouse.get_meta(&"net_id", 0))
	if not SharedWarehouseLedgerBridge.persist_to_ledger(
		_run_state, warehouse, warehouse_net_id
	):
		push_warning("PlantRuntimeCoordinator: 无法保存共享仓库跨场景快照。")


func _on_singleplayer_warehouse_removal_started(
	_removal_mode: int,
	warehouse: OakWarehouse
) -> void:
	if _runtime_mode != CombatRuntimeBase.RuntimeMode.SINGLEPLAYER or warehouse == null:
		return
	SharedWarehouseLedgerBridge.remove_from_ledger(
		_run_state,
		int(warehouse.get_meta(&"net_id", warehouse.warehouse_net_id))
	)


func _on_vegetation_stake_construction_finished(
	vegetation_stake: VegetationStake
) -> void:
	if (
		vegetation_stake == null
		or not is_instance_valid(vegetation_stake)
		or not vegetation_stake.is_operational
		or vegetation_stake.is_removing
	):
		return
	_activate_vegetation_stake_source(vegetation_stake)


func _activate_vegetation_stake_source(vegetation_stake: VegetationStake) -> void:
	if (
		_vegetation_spread_system == null
		or vegetation_stake == null
		or vegetation_stake.footprint_cells.is_empty()
	):
		return
	var source_id := _get_vegetation_source_id(vegetation_stake)
	var origin_cell := vegetation_stake.footprint_cells[0]
	_vegetation_spread_system.register_source(
		source_id, origin_cell, vegetation_stake.get_spread_elapsed_seconds()
	)
	var runtime_callback := _on_vegetation_runtime_state_changed.bind(
		vegetation_stake, source_id, origin_cell
	)
	if not vegetation_stake.spread_runtime_state_changed.is_connected(runtime_callback):
		vegetation_stake.spread_runtime_state_changed.connect(runtime_callback)


func _on_vegetation_runtime_state_changed(
	elapsed_seconds: float,
	vegetation_stake: VegetationStake,
	source_id: int,
	origin_cell: Vector2i
) -> void:
	if (
		_vegetation_spread_system == null
		or vegetation_stake == null
		or not is_instance_valid(vegetation_stake)
	):
		return
	var multiplier := maxf(
		vegetation_stake.get_spread_speed_multiplier(),
		_vegetation_spread_system.get_spread_speed_multiplier()
	)
	if _research_coordinator != null:
		multiplier = maxf(
			multiplier,
			_research_coordinator.get_vegetation_spread_speed_multiplier()
		)
	vegetation_stake.set_spread_speed_multiplier(multiplier)
	_vegetation_spread_system.set_spread_speed_multiplier(multiplier)
	_vegetation_spread_system.apply_source_runtime_state(
		source_id,
		origin_cell,
		{
			"schema": VegetationSpreadSystem.RUNTIME_STATE_SCHEMA,
			"spread_elapsed_seconds": elapsed_seconds,
		}
	)


func _on_authoritative_vegetation_terrain_changed(
	cell_xy: PackedInt32Array,
	terrain_types: PackedInt32Array
) -> void:
	apply_authoritative_terrain_changes(
		cell_xy, terrain_types, _terrain_network_batch_max_cells
	)


static func _get_vegetation_source_id(plant: PlantDefense) -> int:
	var net_id := int(plant.get_meta(&"net_id", 0))
	return net_id if net_id > 0 else int(plant.get_instance_id())


func _spawn_authoritative_plant(
	requester_peer_id: int,
	request_id: int,
	plant_config: PlantDefenseConfig,
	anchor: Vector2i,
	placement_player: Player
) -> PlantDefense:
	var plant_net_id := next_multiplayer_plant_net_id
	var plant := _plant_system.try_place_for_player(
		plant_config, anchor, placement_player, plant_net_id
	)
	if plant == null:
		_reject_placement(
			request_id,
			requester_peer_id,
			PLACEMENT_REJECT_INVALID_POSITION
		)
		return null
	next_multiplayer_plant_net_id += 1
	var health_callback := report_authoritative_health.bind(plant_net_id)
	if not plant.authoritative_health_changed.is_connected(health_callback):
		plant.authoritative_health_changed.connect(health_callback)
	var status_callback := report_authoritative_damage_status.bind(plant_net_id)
	if not plant.authoritative_damage_status_changed.is_connected(status_callback):
		plant.authoritative_damage_status_changed.connect(status_callback)
	plant_spawned.emit(
		request_id,
		requester_peer_id,
		plant_net_id,
		plant_config.plant_id,
		anchor,
		plant.current_health,
		plant.max_health,
		plant.health_revision
	)
	placement_request_succeeded.emit(request_id, placement_player)
	return plant


func _reject_placement(
	request_id: int,
	requester_peer_id: int,
	reason: StringName
) -> void:
	plant_placement_rejected.emit(request_id, requester_peer_id, reason)


func _notify_local_placement_rejected(request_id: int) -> void:
	if _plant_placement_controller != null:
		_plant_placement_controller.notify_multiplayer_placement_rejected(request_id)


static func _is_valid_placement_player(placement_player: Player) -> bool:
	return (
		placement_player != null
		and is_instance_valid(placement_player)
		and not placement_player.is_dead
	)


static func _find_inventory_item_slot(
	run_state: RunStateStore,
	peer_id: int,
	item: PickupConfig
) -> int:
	if run_state == null or item == null or peer_id < 0:
		return -1
	for slot_index in RunStateStore.INVENTORY_CAPACITY:
		var stored_item := (
			run_state.get_item_for_peer(peer_id, slot_index)
			if peer_id > 0
			else run_state.get_item(slot_index)
		)
		var stored_count := (
			run_state.get_item_count_for_peer(peer_id, slot_index)
			if peer_id > 0
			else run_state.get_item_count(slot_index)
		)
		if (
			stored_count > 0
			and PickupConfig.inventory_identity_matches(stored_item, item)
		):
			return slot_index
	return -1


static func _is_canonical_building_item(
	item: PickupConfig,
	plant_id: StringName
) -> bool:
	return (
		item != null
		and item.pickup_type == PickupConfig.PickupType.BUILDING
		and item.placeable_plant_id == plant_id
		and not item.resource_path.is_empty()
	)


func _refresh_remote_vegetation_overlay() -> void:
	if _vegetation_spread_system != null:
		_vegetation_spread_system.advance_time(0.0)


static func _sort_terrain_cells(a: Vector2i, b: Vector2i) -> bool:
	return a.x < b.x if a.y == b.y else a.y < b.y
