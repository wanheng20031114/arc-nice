extends Node2D
class_name SessionObjectPool

signal pool_metrics_changed(scene_path: String, metrics: Dictionary)

const POOL_ACTIVE_META := &"pool_active"
const POOL_OWNER_META := &"pool_owner_id"
const POOL_KEY_META := &"pool_scene_path"
const POOL_GENERATION_META := &"pool_lease_generation"

var _buckets: Dictionary = {}
var _pending_release: Array[Dictionary] = []


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_physics_process(true)


func register_scene(scene: PackedScene, prewarm_count: int, retained_capacity: int) -> void:
	if scene == null or scene.resource_path.is_empty():
		return
	var key := scene.resource_path
	var capacity := maxi(maxi(retained_capacity, prewarm_count), 1)
	var bucket := _get_or_create_bucket(scene, capacity)
	bucket["retained_capacity"] = capacity
	var inactive := bucket["inactive"] as Array[Node]
	while int(bucket["created"]) < maxi(prewarm_count, 0):
		var instance := _create_instance(scene, key, bucket)
		if instance == null:
			break
		_prepare_inactive(instance)
		inactive.append(instance)
	_emit_metrics(key, bucket)


func acquire(scene: PackedScene) -> Node:
	if scene == null or scene.resource_path.is_empty():
		return null
	var key := scene.resource_path
	var bucket := _get_or_create_bucket(scene, 1)
	var inactive := bucket["inactive"] as Array[Node]
	var instance: Node = null
	while not inactive.is_empty() and instance == null:
		var candidate := inactive.pop_back() as Node
		if candidate != null and is_instance_valid(candidate):
			instance = candidate
	if instance == null:
		instance = _create_instance(scene, key, bucket)
		if instance == null:
			return null
		if int(bucket["created"]) > int(bucket["retained_capacity"]):
			bucket["overflow"] = int(bucket["overflow"]) + 1

	var generation := int(instance.get_meta(POOL_GENERATION_META, 0)) + 1
	instance.set_meta(POOL_GENERATION_META, generation)
	instance.set_meta(POOL_ACTIVE_META, true)
	instance.process_mode = Node.PROCESS_MODE_INHERIT
	if instance is CanvasItem:
		(instance as CanvasItem).show()
	if instance.has_method("on_pool_acquired"):
		instance.call("on_pool_acquired", generation)
	bucket["in_use"] = int(bucket["in_use"]) + 1
	bucket["peak_in_use"] = maxi(int(bucket["peak_in_use"]), int(bucket["in_use"]))
	_emit_metrics(key, bucket)
	return instance


func release(instance: Node) -> bool:
	if instance == null or not is_instance_valid(instance):
		return false
	if int(instance.get_meta(POOL_OWNER_META, 0)) != get_instance_id():
		return false
	if not bool(instance.get_meta(POOL_ACTIVE_META, false)):
		return false
	instance.set_meta(POOL_ACTIVE_META, false)
	if instance.has_method("on_pool_released"):
		instance.call("on_pool_released", int(instance.get_meta(POOL_GENERATION_META, 0)))
	_prepare_inactive(instance)
	_pending_release.append({
		"node": instance,
		"available_frame": Engine.get_physics_frames() + 1,
	})
	var key := str(instance.get_meta(POOL_KEY_META, ""))
	var bucket := _buckets.get(key, {}) as Dictionary
	if not bucket.is_empty():
		bucket["in_use"] = maxi(int(bucket["in_use"]) - 1, 0)
		_emit_metrics(key, bucket)
	return true


func get_metrics(scene_path: String) -> Dictionary:
	var bucket := _buckets.get(scene_path, {}) as Dictionary
	if bucket.is_empty():
		return {}
	return _build_metrics(bucket)


func _physics_process(_delta: float) -> void:
	if _pending_release.is_empty():
		return
	var current_frame := Engine.get_physics_frames()
	for index in range(_pending_release.size() - 1, -1, -1):
		var pending := _pending_release[index] as Dictionary
		if current_frame < int(pending.get("available_frame", current_frame + 1)):
			continue
		_pending_release.remove_at(index)
		var instance := pending.get("node") as Node
		if instance == null or not is_instance_valid(instance):
			continue
		var key := str(instance.get_meta(POOL_KEY_META, ""))
		var bucket := _buckets.get(key, {}) as Dictionary
		if bucket.is_empty():
			instance.queue_free()
			continue
		var inactive := bucket["inactive"] as Array[Node]
		if inactive.size() < int(bucket["retained_capacity"]):
			inactive.append(instance)
		else:
			bucket["created"] = maxi(int(bucket["created"]) - 1, 0)
			instance.queue_free()
		_emit_metrics(key, bucket)


func _get_or_create_bucket(scene: PackedScene, retained_capacity: int) -> Dictionary:
	var key := scene.resource_path
	var existing := _buckets.get(key, {}) as Dictionary
	if not existing.is_empty():
		return existing
	var bucket := {
		"scene": scene,
		"inactive": [] as Array[Node],
		"retained_capacity": maxi(retained_capacity, 1),
		"created": 0,
		"in_use": 0,
		"peak_in_use": 0,
		"overflow": 0,
	}
	_buckets[key] = bucket
	return bucket


func _create_instance(scene: PackedScene, key: String, bucket: Dictionary) -> Node:
	var instance := scene.instantiate()
	if instance == null:
		return null
	instance.set_meta(POOL_OWNER_META, get_instance_id())
	instance.set_meta(POOL_KEY_META, key)
	instance.set_meta(POOL_ACTIVE_META, false)
	instance.set_meta(POOL_GENERATION_META, 0)
	add_child(instance)
	bucket["created"] = int(bucket["created"]) + 1
	return instance


func _prepare_inactive(instance: Node) -> void:
	instance.process_mode = Node.PROCESS_MODE_DISABLED
	if instance is CanvasItem:
		(instance as CanvasItem).hide()


func _build_metrics(bucket: Dictionary) -> Dictionary:
	var inactive := bucket["inactive"] as Array[Node]
	return {
		"created": int(bucket["created"]),
		"in_use": int(bucket["in_use"]),
		"inactive": inactive.size(),
		"peak_in_use": int(bucket["peak_in_use"]),
		"overflow": int(bucket["overflow"]),
		"retained_capacity": int(bucket["retained_capacity"]),
		"pending_release": _pending_release.size(),
	}


func _emit_metrics(key: String, bucket: Dictionary) -> void:
	pool_metrics_changed.emit(key, _build_metrics(bucket))
