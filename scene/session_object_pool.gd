extends Node2D
class_name SessionObjectPool

signal pool_metrics_changed(scene_path: String, metrics: Dictionary)

const POOL_ACTIVE_META := &"pool_active"
const POOL_OWNER_META := &"pool_owner_id"
const POOL_KEY_META := &"pool_scene_path"
const POOL_GENERATION_META := &"pool_lease_generation"

var _buckets: Dictionary = {}
var _pending_nodes: Array[Node] = []
var _pending_available_frames: Array[int] = []
var _pending_keys: Array[String] = []
var _dirty_metric_keys: Dictionary[String, bool] = {}


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
	_mark_metrics_dirty(key)


func is_registered(scene: PackedScene) -> bool:
	return (
		scene != null
		and not scene.resource_path.is_empty()
		and _buckets.has(scene.resource_path)
	)


## Gameplay-safe elastic acquisition. If the retained pool is exhausted, an
## overflow instance is created and later discarded instead of dropping work.
func acquire(scene: PackedScene) -> Node:
	if scene == null or scene.resource_path.is_empty():
		return null
	var key := scene.resource_path
	var bucket := _get_or_create_bucket(scene, 1)
	var instance := _take_inactive_instance(key, bucket)
	if instance == null:
		instance = _create_instance(scene, key, bucket)
		if instance == null:
			return null
		if int(bucket["created"]) > int(bucket["retained_capacity"]):
			bucket["overflow"] = int(bucket["overflow"]) + 1
	return _activate_instance(instance, key, bucket)


## Strict visual-budget acquisition. This never grows beyond the registered
## retained capacity; a miss is counted and returns null.
func try_acquire(scene: PackedScene) -> Node:
	if not is_registered(scene):
		return null
	var key := scene.resource_path
	var bucket := _buckets[key] as Dictionary
	var instance := _take_inactive_instance(key, bucket)
	if instance == null:
		if int(bucket["created"]) >= int(bucket["retained_capacity"]):
			bucket["dropped"] = int(bucket["dropped"]) + 1
			_mark_metrics_dirty(key)
			return null
		instance = _create_instance(scene, key, bucket)
		if instance == null:
			bucket["dropped"] = int(bucket["dropped"]) + 1
			_mark_metrics_dirty(key)
			return null
	return _activate_instance(instance, key, bucket)


func release(instance: Node) -> bool:
	if instance == null or not is_instance_valid(instance):
		return false
	if int(instance.get_meta(POOL_OWNER_META, 0)) != get_instance_id():
		return false
	if not bool(instance.get_meta(POOL_ACTIVE_META, false)):
		return false

	var key := str(instance.get_meta(POOL_KEY_META, ""))
	instance.set_meta(POOL_ACTIVE_META, false)
	if instance.has_method("on_pool_released"):
		instance.call("on_pool_released", int(instance.get_meta(POOL_GENERATION_META, 0)))
	_prepare_inactive(instance)
	_pending_nodes.append(instance)
	_pending_available_frames.append(Engine.get_physics_frames() + 1)
	_pending_keys.append(key)

	var bucket := _buckets.get(key, {}) as Dictionary
	if not bucket.is_empty():
		bucket["in_use"] = maxi(int(bucket["in_use"]) - 1, 0)
		bucket["pending_release"] = int(bucket["pending_release"]) + 1
		_mark_metrics_dirty(key)
	return true


static func release_to_owner(instance: Node) -> bool:
	if instance == null or not is_instance_valid(instance):
		return false
	var owner_id := int(instance.get_meta(POOL_OWNER_META, 0))
	if owner_id <= 0:
		return false
	var owner := instance_from_id(owner_id) as SessionObjectPool
	return owner != null and is_instance_valid(owner) and owner.release(instance)


func get_metrics(scene_path: String) -> Dictionary:
	var bucket := _buckets.get(scene_path, {}) as Dictionary
	if bucket.is_empty():
		return {}
	return _build_metrics(bucket)


func _physics_process(_delta: float) -> void:
	_process_pending_releases()
	_flush_metric_signals()


func _process_pending_releases() -> void:
	if _pending_nodes.is_empty():
		return
	var current_frame := Engine.get_physics_frames()
	for index in range(_pending_nodes.size() - 1, -1, -1):
		if current_frame < _pending_available_frames[index]:
			continue
		var instance := _pending_nodes[index]
		var key := _pending_keys[index]
		_pending_nodes.remove_at(index)
		_pending_available_frames.remove_at(index)
		_pending_keys.remove_at(index)

		var bucket := _buckets.get(key, {}) as Dictionary
		if not bucket.is_empty():
			bucket["pending_release"] = maxi(int(bucket["pending_release"]) - 1, 0)
		if instance == null or not is_instance_valid(instance):
			if not bucket.is_empty():
				bucket["created"] = maxi(int(bucket["created"]) - 1, 0)
				_mark_metrics_dirty(key)
			continue
		if bucket.is_empty():
			instance.queue_free()
			continue

		var inactive := bucket["inactive"] as Array[Node]
		if inactive.size() < int(bucket["retained_capacity"]):
			inactive.append(instance)
		else:
			bucket["created"] = maxi(int(bucket["created"]) - 1, 0)
			instance.queue_free()
		_mark_metrics_dirty(key)


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
		"dropped": 0,
		"pending_release": 0,
	}
	_buckets[key] = bucket
	_mark_metrics_dirty(key)
	return bucket


func _take_inactive_instance(key: String, bucket: Dictionary) -> Node:
	var inactive := bucket["inactive"] as Array[Node]
	while not inactive.is_empty():
		var candidate := inactive.pop_back() as Node
		if candidate != null and is_instance_valid(candidate):
			return candidate
		bucket["created"] = maxi(int(bucket["created"]) - 1, 0)
		_mark_metrics_dirty(key)
	return null


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


func _activate_instance(instance: Node, key: String, bucket: Dictionary) -> Node:
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
	_mark_metrics_dirty(key)
	return instance


func _prepare_inactive(instance: Node) -> void:
	# Projectile leases are commonly released from Area2D body/area signals or
	# their physics tick. Disabling a CollisionObject2D through process_mode while
	# the physics server is flushing callbacks is forbidden. The lease is already
	# marked inactive and its release hook has stopped gameplay work, while the
	# one-physics-frame quarantine prevents reacquisition before this deferred
	# state change is committed.
	if Engine.is_in_physics_frame():
		instance.set_deferred("process_mode", Node.PROCESS_MODE_DISABLED)
	else:
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
		"dropped": int(bucket["dropped"]),
		"retained_capacity": int(bucket["retained_capacity"]),
		"pending_release": int(bucket["pending_release"]),
	}


func _mark_metrics_dirty(key: String) -> void:
	if not key.is_empty():
		_dirty_metric_keys[key] = true


func _flush_metric_signals() -> void:
	if _dirty_metric_keys.is_empty():
		return
	if not pool_metrics_changed.has_connections():
		_dirty_metric_keys.clear()
		return
	var dirty_keys := _dirty_metric_keys.keys()
	_dirty_metric_keys.clear()
	for key_variant in dirty_keys:
		var key := str(key_variant)
		var bucket := _buckets.get(key, {}) as Dictionary
		if not bucket.is_empty():
			pool_metrics_changed.emit(key, _build_metrics(bucket))
