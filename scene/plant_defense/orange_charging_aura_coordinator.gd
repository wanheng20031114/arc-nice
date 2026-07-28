extends Node
class_name OrangeChargingAuraCoordinator

const RECONCILE_INTERVAL_SECONDS := 2.0

@onready var reconcile_timer: Timer = $ReconcileTimer

var plant_system: PlantSystem = null
var sources_by_id: Dictionary[int, OrangeChargingTower] = {}
var source_rects: Dictionary[int, Rect2i] = {}
var source_targets: Dictionary = {}
var source_ids_by_cell: Dictionary = {}
var pending_sources: Dictionary[OrangeChargingTower, Callable] = {}
var reconcile_cursor := 0


func _exit_tree() -> void:
	_shutdown()


func setup(new_plant_system: PlantSystem) -> void:
	if plant_system == new_plant_system:
		_rebuild_from_registered_plants()
		return
	_shutdown()
	plant_system = new_plant_system
	if plant_system == null:
		return
	plant_system.plant_placed.connect(_on_plant_placed)
	plant_system.plant_removed.connect(_on_plant_removed)
	_rebuild_from_registered_plants()
	reconcile_timer.start(RECONCILE_INTERVAL_SECONDS)


func get_registered_source_count() -> int:
	return sources_by_id.size()


func get_source_ids_at_cell(cell: Vector2i) -> Array[int]:
	var result: Array[int] = []
	if not source_ids_by_cell.has(cell):
		return result
	var source_set: Dictionary = source_ids_by_cell[cell]
	for source_id in source_set:
		result.append(int(source_id))
	result.sort()
	return result


func _shutdown() -> void:
	if plant_system != null and is_instance_valid(plant_system):
		if plant_system.plant_placed.is_connected(_on_plant_placed):
			plant_system.plant_placed.disconnect(_on_plant_placed)
		if plant_system.plant_removed.is_connected(_on_plant_removed):
			plant_system.plant_removed.disconnect(_on_plant_removed)
	var pending_source_list: Array = pending_sources.keys()
	for source_variant in pending_source_list:
		var source := source_variant as OrangeChargingTower
		_disconnect_pending_source(source)
	var registered_source_ids: Array = sources_by_id.keys()
	for source_id_variant in registered_source_ids:
		_unregister_source(int(source_id_variant))
	pending_sources.clear()
	sources_by_id.clear()
	source_rects.clear()
	source_targets.clear()
	source_ids_by_cell.clear()
	plant_system = null
	reconcile_cursor = 0
	if reconcile_timer != null:
		reconcile_timer.stop()


func _rebuild_from_registered_plants() -> void:
	if plant_system == null:
		return
	var registered_plants: Array = plant_system.plant_footprints.keys()
	for plant_variant in registered_plants:
		var plant := plant_variant as PlantDefense
		if plant != null and is_instance_valid(plant):
			_on_plant_placed(plant)


func _on_plant_placed(plant: PlantDefense) -> void:
	if plant == null or not is_instance_valid(plant):
		return
	var orange_tower := plant as OrangeChargingTower
	if orange_tower != null:
		_track_source_lifecycle(orange_tower)
	_apply_existing_sources_to_target(plant)


func _on_plant_removed(plant: PlantDefense) -> void:
	if plant == null:
		return
	var orange_tower := plant as OrangeChargingTower
	if orange_tower != null:
		_disconnect_pending_source(orange_tower)
		_unregister_source(orange_tower.get_support_source_id())
	_remove_target_from_intersecting_sources(plant)


func _track_source_lifecycle(source: OrangeChargingTower) -> void:
	if source.is_operational and not source.is_removing and not source.is_dead:
		_register_source(source)
		return
	if pending_sources.has(source):
		return
	var callback := Callable(self, "_on_source_construction_finished").bind(source)
	pending_sources[source] = callback
	source.construction_finished.connect(callback, CONNECT_ONE_SHOT)


func _on_source_construction_finished(source: OrangeChargingTower) -> void:
	pending_sources.erase(source)
	if source == null or not is_instance_valid(source):
		return
	_register_source(source)


func _disconnect_pending_source(source: OrangeChargingTower) -> void:
	if not pending_sources.has(source):
		return
	var callback: Callable = pending_sources[source]
	if (
		source != null
		and is_instance_valid(source)
		and source.construction_finished.is_connected(callback)
	):
		source.construction_finished.disconnect(callback)
	pending_sources.erase(source)


func _register_source(source: OrangeChargingTower) -> void:
	if (
		plant_system == null
		or source == null
		or not is_instance_valid(source)
		or source.orange_config == null
		or not source.is_operational
		or source.is_dead
		or source.is_removing
	):
		return
	var source_id := source.get_support_source_id()
	var aura_rect := source.get_aura_cell_rect()
	if source_id <= 0 or aura_rect.size.x <= 0 or aura_rect.size.y <= 0:
		return
	if sources_by_id.get(source_id) == source and source_rects.get(source_id) == aura_rect:
		_reconcile_source(source_id)
		return
	_unregister_source(source_id)
	sources_by_id[source_id] = source
	source_rects[source_id] = aura_rect
	source_targets[source_id] = {}
	for cell in _cells_in_rect(aura_rect):
		var source_set: Dictionary = source_ids_by_cell.get(cell, {})
		source_set[source_id] = true
		source_ids_by_cell[cell] = source_set
	_reconcile_source(source_id)


func _unregister_source(source_id: int) -> void:
	if source_id <= 0 or not sources_by_id.has(source_id):
		return
	var target_set: Dictionary = source_targets.get(source_id, {})
	for target_variant in target_set:
		_remove_source_modifier_from_target(
			target_variant as PlantDefense,
			source_id
		)
	var aura_rect: Rect2i = source_rects.get(source_id, Rect2i())
	for cell in _cells_in_rect(aura_rect):
		if not source_ids_by_cell.has(cell):
			continue
		var source_set: Dictionary = source_ids_by_cell[cell]
		source_set.erase(source_id)
		if source_set.is_empty():
			source_ids_by_cell.erase(cell)
	source_targets.erase(source_id)
	source_rects.erase(source_id)
	sources_by_id.erase(source_id)


func _apply_existing_sources_to_target(target: PlantDefense) -> void:
	if target == null or target.footprint_cells.is_empty():
		return
	var candidate_source_ids := _collect_source_ids_for_cells(
		target.footprint_cells
	)
	for source_id in candidate_source_ids:
		_apply_source_modifier_to_target(int(source_id), target)


func _remove_target_from_intersecting_sources(target: PlantDefense) -> void:
	if target == null:
		return
	var candidate_source_ids := _collect_source_ids_for_cells(
		target.footprint_cells
	)
	for source_id in candidate_source_ids:
		_remove_source_target(int(source_id), target)


func _collect_source_ids_for_cells(cells: Array[Vector2i]) -> Dictionary:
	var result := {}
	for cell in cells:
		if not source_ids_by_cell.has(cell):
			continue
		var source_set: Dictionary = source_ids_by_cell[cell]
		for source_id in source_set:
			result[source_id] = true
	return result


func _apply_source_modifier_to_target(
	source_id: int,
	target: PlantDefense
) -> void:
	var source := sources_by_id.get(source_id) as OrangeChargingTower
	if (
		source == null
		or not is_instance_valid(source)
		or target == null
		or not is_instance_valid(target)
		or target == source
		or target.is_dead
		or target.is_removing
		or not _footprint_intersects_rect(target, source_rects[source_id])
	):
		return
	var applied := false
	if (
		target.config != null
		and target.config.building_category
		== PlantDefenseConfig.BuildingCategory.DEFENSE_TOWER
	):
		target.add_attack_interval_multiplier_modifier(
			source_id,
			source.orange_config.defense_attack_interval_multiplier
		)
		applied = true
	var production_target := target as ProductionBuilding
	if (
		production_target != null
		and target.config != null
		and target.config.building_category
		== PlantDefenseConfig.BuildingCategory.PRODUCTION_BUILDING
	):
		production_target.add_production_duration_multiplier_modifier(
			source_id,
			source.orange_config.production_duration_multiplier
		)
		applied = true
	if applied:
		if not source_targets.has(source_id):
			return
		var target_set: Dictionary = source_targets[source_id]
		target_set[target] = true


func _remove_source_target(source_id: int, target: PlantDefense) -> void:
	_remove_source_modifier_from_target(target, source_id)
	if not source_targets.has(source_id):
		return
	var target_set: Dictionary = source_targets[source_id]
	target_set.erase(target)


func _remove_source_modifier_from_target(
	target: PlantDefense,
	source_id: int
) -> void:
	if target == null or not is_instance_valid(target):
		return
	target.remove_attack_interval_multiplier_modifier(source_id)
	var production_target := target as ProductionBuilding
	if production_target != null:
		production_target.remove_production_duration_multiplier_modifier(source_id)


func _reconcile_source(source_id: int) -> void:
	var source := sources_by_id.get(source_id) as OrangeChargingTower
	if (
		source == null
		or not is_instance_valid(source)
		or not source.is_operational
		or source.is_dead
		or source.is_removing
	):
		_unregister_source(source_id)
		return
	var aura_rect: Rect2i = source_rects.get(source_id, Rect2i())
	var expected_targets := {}
	for cell in _cells_in_rect(aura_rect):
		var target := plant_system.occupied_cells.get(cell) as PlantDefense
		if target == null or expected_targets.has(target):
			continue
		expected_targets[target] = true
		_apply_source_modifier_to_target(source_id, target)
	if not source_targets.has(source_id):
		return
	var current_targets: Dictionary = source_targets[source_id]
	var stale_targets: Array = []
	for target_variant in current_targets:
		var target := target_variant as PlantDefense
		if not expected_targets.has(target):
			stale_targets.append(target)
	for target_variant in stale_targets:
		_remove_source_target(source_id, target_variant as PlantDefense)


func _on_reconcile_timer_timeout() -> void:
	if sources_by_id.is_empty():
		reconcile_cursor = 0
		return
	var source_ids: Array = sources_by_id.keys()
	source_ids.sort()
	reconcile_cursor = posmod(reconcile_cursor, source_ids.size())
	_reconcile_source(int(source_ids[reconcile_cursor]))
	reconcile_cursor = posmod(reconcile_cursor + 1, maxi(source_ids.size(), 1))


func _footprint_intersects_rect(
	target: PlantDefense,
	aura_rect: Rect2i
) -> bool:
	for cell in target.footprint_cells:
		if aura_rect.has_point(cell):
			return true
	return false


func _cells_in_rect(rect: Rect2i) -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	for y in range(rect.position.y, rect.end.y):
		for x in range(rect.position.x, rect.end.x):
			cells.append(Vector2i(x, y))
	return cells
