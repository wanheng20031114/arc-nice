extends RefCounted
class_name PlantObjectiveEnemyIndex

## Reverse ownership index for tower-defense plant objectives.
##
## Enemy target changes are lifecycle events, so removing one plant only visits
## enemies that currently point at that plant. Weak references prevent the index
## from extending an enemy's lifetime; stale entries are pruned only when their
## own plant bucket is accessed, never through a global safety scan.

var _tracked_enemy_refs: Dictionary[int, WeakRef] = {}
var _plant_id_by_enemy_id: Dictionary[int, int] = {}
var _enemy_ids_by_plant_id: Dictionary[int, Dictionary] = {}
var _last_take_candidate_visits := 0


func track(enemy: Enemy) -> bool:
	if (
		enemy == null
		or not is_instance_valid(enemy)
		or enemy.is_queued_for_deletion()
	):
		return false
	var enemy_id := enemy.get_instance_id()
	var existing_ref := _tracked_enemy_refs.get(enemy_id) as WeakRef
	var existing_enemy := (
		existing_ref.get_ref() as Enemy
		if existing_ref != null
		else null
	)
	if existing_enemy != null and is_instance_valid(existing_enemy):
		if existing_enemy != enemy:
			return false
		_set_enemy_plant_target(enemy_id, enemy.objective_target as PlantDefense)
		return true

	_tracked_enemy_refs[enemy_id] = weakref(enemy)
	var target_changed_callback := Callable(self, "_on_enemy_objective_target_changed")
	if not enemy.objective_target_changed.is_connected(target_changed_callback):
		enemy.objective_target_changed.connect(target_changed_callback)
	var exited_callback := _on_enemy_tree_exited.bind(enemy_id)
	if not enemy.tree_exited.is_connected(exited_callback):
		enemy.tree_exited.connect(exited_callback, CONNECT_ONE_SHOT)
	_set_enemy_plant_target(enemy_id, enemy.objective_target as PlantDefense)
	return true


func untrack(enemy_id: int) -> void:
	if enemy_id <= 0:
		return
	var enemy_ref := _tracked_enemy_refs.get(enemy_id) as WeakRef
	var enemy := enemy_ref.get_ref() as Enemy if enemy_ref != null else null
	if enemy != null and is_instance_valid(enemy):
		var target_changed_callback := Callable(
			self, "_on_enemy_objective_target_changed"
		)
		if enemy.objective_target_changed.is_connected(target_changed_callback):
			enemy.objective_target_changed.disconnect(target_changed_callback)
		var exited_callback := _on_enemy_tree_exited.bind(enemy_id)
		if enemy.tree_exited.is_connected(exited_callback):
			enemy.tree_exited.disconnect(exited_callback)
	_remove_enemy_membership(enemy_id)
	_tracked_enemy_refs.erase(enemy_id)


func clear() -> void:
	var tracked_enemy_ids: Array[int] = []
	tracked_enemy_ids.assign(_tracked_enemy_refs.keys())
	for enemy_id in tracked_enemy_ids:
		untrack(enemy_id)
	_tracked_enemy_refs.clear()
	_plant_id_by_enemy_id.clear()
	_enemy_ids_by_plant_id.clear()
	_last_take_candidate_visits = 0


## Atomically detaches one plant bucket before returning its live members. Any
## target-change signal emitted while the caller clears those enemies therefore
## cannot mutate the collection being iterated or resurrect the removed bucket.
func take_enemies_targeting_plant(plant: PlantDefense) -> Array[Enemy]:
	var result: Array[Enemy] = []
	_last_take_candidate_visits = 0
	if plant == null or not is_instance_valid(plant):
		return result
	var plant_id := plant.get_instance_id()
	if not _enemy_ids_by_plant_id.has(plant_id):
		return result
	var enemy_ids: Dictionary = _enemy_ids_by_plant_id[plant_id]
	_enemy_ids_by_plant_id.erase(plant_id)

	for enemy_id_variant in enemy_ids:
		_last_take_candidate_visits += 1
		var enemy_id := int(enemy_id_variant)
		if int(_plant_id_by_enemy_id.get(enemy_id, 0)) != plant_id:
			continue
		_plant_id_by_enemy_id.erase(enemy_id)
		var enemy_ref := _tracked_enemy_refs.get(enemy_id) as WeakRef
		var enemy := enemy_ref.get_ref() as Enemy if enemy_ref != null else null
		if enemy == null or not is_instance_valid(enemy):
			_tracked_enemy_refs.erase(enemy_id)
			continue
		if enemy.objective_target == plant:
			result.append(enemy)
	return result


func get_targeting_enemy_count(plant: PlantDefense) -> int:
	if plant == null or not is_instance_valid(plant):
		return 0
	var plant_id := plant.get_instance_id()
	_prune_plant_bucket(plant_id)
	if not _enemy_ids_by_plant_id.has(plant_id):
		return 0
	var enemy_ids: Dictionary = _enemy_ids_by_plant_id[plant_id]
	return enemy_ids.size()


func get_tracked_enemy_count() -> int:
	return _tracked_enemy_refs.size()


func get_plant_membership_count() -> int:
	return _plant_id_by_enemy_id.size()


func get_plant_bucket_count() -> int:
	return _enemy_ids_by_plant_id.size()


func get_last_take_candidate_visits() -> int:
	return _last_take_candidate_visits


func _on_enemy_objective_target_changed(
	enemy: Enemy,
	current_target: Node2D
) -> void:
	if enemy == null or not is_instance_valid(enemy):
		return
	var enemy_id := enemy.get_instance_id()
	var enemy_ref := _tracked_enemy_refs.get(enemy_id) as WeakRef
	if enemy_ref == null or enemy_ref.get_ref() != enemy:
		return
	_set_enemy_plant_target(enemy_id, current_target as PlantDefense)


func _on_enemy_tree_exited(enemy_id: int) -> void:
	_remove_enemy_membership(enemy_id)
	_tracked_enemy_refs.erase(enemy_id)


func _set_enemy_plant_target(enemy_id: int, plant: PlantDefense) -> void:
	_remove_enemy_membership(enemy_id)
	if plant == null or not is_instance_valid(plant):
		return
	var plant_id := plant.get_instance_id()
	var enemy_ids: Dictionary
	if _enemy_ids_by_plant_id.has(plant_id):
		enemy_ids = _enemy_ids_by_plant_id[plant_id]
	else:
		enemy_ids = {}
		_enemy_ids_by_plant_id[plant_id] = enemy_ids
	enemy_ids[enemy_id] = true
	_plant_id_by_enemy_id[enemy_id] = plant_id


func _remove_enemy_membership(enemy_id: int) -> void:
	var plant_id := int(_plant_id_by_enemy_id.get(enemy_id, 0))
	if plant_id <= 0:
		return
	_plant_id_by_enemy_id.erase(enemy_id)
	if not _enemy_ids_by_plant_id.has(plant_id):
		return
	var enemy_ids: Dictionary = _enemy_ids_by_plant_id[plant_id]
	enemy_ids.erase(enemy_id)
	if enemy_ids.is_empty():
		_enemy_ids_by_plant_id.erase(plant_id)


func _prune_plant_bucket(plant_id: int) -> void:
	if not _enemy_ids_by_plant_id.has(plant_id):
		return
	var enemy_ids: Dictionary = _enemy_ids_by_plant_id[plant_id]
	var stale_enemy_ids: Array[int] = []
	for enemy_id_variant in enemy_ids:
		var enemy_id := int(enemy_id_variant)
		var enemy_ref := _tracked_enemy_refs.get(enemy_id) as WeakRef
		var enemy := enemy_ref.get_ref() as Enemy if enemy_ref != null else null
		var target_plant := (
			enemy.objective_target as PlantDefense
			if enemy != null and is_instance_valid(enemy)
			else null
		)
		if (
			enemy == null
			or not is_instance_valid(enemy)
			or target_plant == null
			or not is_instance_valid(target_plant)
			or target_plant.get_instance_id() != plant_id
			or int(_plant_id_by_enemy_id.get(enemy_id, 0)) != plant_id
		):
			stale_enemy_ids.append(enemy_id)
	for enemy_id in stale_enemy_ids:
		enemy_ids.erase(enemy_id)
		if int(_plant_id_by_enemy_id.get(enemy_id, 0)) == plant_id:
			_plant_id_by_enemy_id.erase(enemy_id)
		var enemy_ref := _tracked_enemy_refs.get(enemy_id) as WeakRef
		if enemy_ref == null or enemy_ref.get_ref() == null:
			_tracked_enemy_refs.erase(enemy_id)
	if enemy_ids.is_empty():
		_enemy_ids_by_plant_id.erase(plant_id)
