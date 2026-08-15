extends RefCounted
class_name StandardBossEncounterScope

## Standard Boss 的短生命周期实体所有者。
## 协调器创建并独占该作用域；generation 使旧 timer/tween 醒来后只能退出，
## close 则幂等回收本次遭遇的召唤物与预警，实体退出只反向清理派生索引。

var _generation: int = 0
var _open: bool = false
var _entities_by_instance_id: Dictionary[int, WeakRef] = {}


func begin() -> int:
	close()
	_generation += 1
	_open = true
	return _generation


func close() -> bool:
	var changed := _open or not _entities_by_instance_id.is_empty()
	_open = false
	for entity_ref in _entities_by_instance_id.values():
		var entity := (entity_ref as WeakRef).get_ref() as Node
		if (
			entity != null
			and is_instance_valid(entity)
			and not entity.is_queued_for_deletion()
		):
			entity.queue_free()
	_entities_by_instance_id.clear()
	return changed


func track(entity: Node, generation: int) -> bool:
	if (
		entity == null
		or not is_instance_valid(entity)
		or not is_current(generation)
	):
		return false
	var instance_id := entity.get_instance_id()
	_entities_by_instance_id[instance_id] = weakref(entity)
	var exited_callback := untrack.bind(instance_id)
	if not entity.tree_exited.is_connected(exited_callback):
		entity.tree_exited.connect(exited_callback)
	return true


func untrack(instance_id: int) -> void:
	_entities_by_instance_id.erase(instance_id)


func is_current(generation: int) -> bool:
	return _open and generation > 0 and generation == _generation


func is_open() -> bool:
	return _open


func get_generation() -> int:
	return _generation


func get_live_entity_count() -> int:
	_prune_released_entities()
	return _entities_by_instance_id.size()


func _prune_released_entities() -> void:
	var released_ids: Array[int] = []
	for instance_id in _entities_by_instance_id:
		var entity_ref := _entities_by_instance_id[instance_id] as WeakRef
		var entity := entity_ref.get_ref() as Node
		if entity == null or not is_instance_valid(entity):
			released_ids.append(instance_id)
	for instance_id in released_ids:
		_entities_by_instance_id.erase(instance_id)
