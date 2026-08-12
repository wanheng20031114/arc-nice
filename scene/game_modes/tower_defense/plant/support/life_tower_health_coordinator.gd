extends Node
class_name LifeTowerHealthCoordinator

@export var plant_system: PlantSystem
@export var player_roster_coordinator: TowerDefensePlayerRosterCoordinator

var active_sources: Dictionary[LifeTower, bool] = {}
var pending_sources: Dictionary[LifeTower, Callable] = {}
var total_bonus_ratio := 0.0


func _ready() -> void:
	if plant_system == null or player_roster_coordinator == null:
		push_error("LifeTowerHealthCoordinator requires PlantSystem and player roster.")
		return
	plant_system.plant_placed.connect(_on_plant_placed)
	plant_system.plant_removed.connect(_on_plant_removed)
	player_roster_coordinator.player_runtime_binding_requested.connect(
		_on_player_runtime_binding_requested
	)
	_rebuild_from_registered_plants()


func _exit_tree() -> void:
	if plant_system != null and is_instance_valid(plant_system):
		if plant_system.plant_placed.is_connected(_on_plant_placed):
			plant_system.plant_placed.disconnect(_on_plant_placed)
		if plant_system.plant_removed.is_connected(_on_plant_removed):
			plant_system.plant_removed.disconnect(_on_plant_removed)
	if (
		player_roster_coordinator != null
		and is_instance_valid(player_roster_coordinator)
		and player_roster_coordinator.player_runtime_binding_requested.is_connected(
			_on_player_runtime_binding_requested
		)
	):
		player_roster_coordinator.player_runtime_binding_requested.disconnect(
			_on_player_runtime_binding_requested
		)
	for source in pending_sources.keys():
		_disconnect_pending_source(source)
	active_sources.clear()
	pending_sources.clear()


func get_active_source_count() -> int:
	return active_sources.size()


func get_total_bonus_ratio() -> float:
	return total_bonus_ratio


func _rebuild_from_registered_plants() -> void:
	if plant_system == null:
		return
	for plant_variant in plant_system.plant_footprints.keys():
		_on_plant_placed(plant_variant as PlantDefense)
	_refresh_total_bonus()


func _on_plant_placed(plant: PlantDefense) -> void:
	var source := plant as LifeTower
	if source == null or not is_instance_valid(source):
		return
	if source.is_operational and not source.is_dead and not source.is_removing:
		_activate_source(source)
		return
	if pending_sources.has(source):
		return
	var callback := Callable(self, "_on_source_construction_finished").bind(source)
	pending_sources[source] = callback
	source.construction_finished.connect(callback, CONNECT_ONE_SHOT)


func _on_plant_removed(plant: PlantDefense) -> void:
	var source := plant as LifeTower
	if source == null:
		return
	_disconnect_pending_source(source)
	if active_sources.erase(source):
		_refresh_total_bonus()


func _on_source_construction_finished(source: LifeTower) -> void:
	pending_sources.erase(source)
	if source == null or not is_instance_valid(source):
		return
	_activate_source(source)


func _activate_source(source: LifeTower) -> void:
	if (
		source == null
		or not is_instance_valid(source)
		or source.life_tower_config == null
		or not source.is_operational
		or source.is_dead
		or source.is_removing
	):
		return
	if active_sources.has(source):
		return
	active_sources[source] = true
	_refresh_total_bonus()


func _disconnect_pending_source(source: LifeTower) -> void:
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


func _refresh_total_bonus() -> void:
	var next_total := 0.0
	var stale_sources: Array[LifeTower] = []
	for source in active_sources:
		if (
			source == null
			or not is_instance_valid(source)
			or source.is_dead
			or source.is_removing
			or not source.is_operational
		):
			stale_sources.append(source)
			continue
		next_total += source.get_player_max_health_bonus_ratio()
	for source in stale_sources:
		active_sources.erase(source)
	total_bonus_ratio = maxf(next_total, 0.0)
	if player_roster_coordinator == null:
		return
	for player in player_roster_coordinator.get_all_players():
		_apply_bonus_to_player(player)


func _on_player_runtime_binding_requested(player: Player) -> void:
	_apply_bonus_to_player(player)


func _apply_bonus_to_player(player: Player) -> void:
	if player == null or not is_instance_valid(player):
		return
	player.set_tower_defense_life_tower_bonus_ratio(total_bonus_ratio)
