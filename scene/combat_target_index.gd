extends RefCounted
class_name CombatTargetIndex

const DEFAULT_BUCKET_SIZE := 96.0

var bucket_size: float = DEFAULT_BUCKET_SIZE
var enemies_by_net_id: Dictionary[int, Enemy] = {}
var buckets: Dictionary[Vector2i, Array] = {}
var _last_refresh_physics_frame: int = -1


func register_enemy(net_id: int, enemy: Enemy) -> void:
	if net_id <= 0 or enemy == null:
		return
	enemies_by_net_id[net_id] = enemy
	_last_refresh_physics_frame = -1


func unregister_enemy(net_id: int) -> void:
	if net_id <= 0:
		return
	enemies_by_net_id.erase(net_id)
	_last_refresh_physics_frame = -1


func get_enemy(net_id: int) -> Enemy:
	var enemy_variant: Variant = enemies_by_net_id.get(net_id)
	if enemy_variant == null or not is_instance_valid(enemy_variant):
		enemies_by_net_id.erase(net_id)
		return null
	var enemy := enemy_variant as Enemy
	if enemy == null or enemy.is_dead:
		enemies_by_net_id.erase(net_id)
		return null
	return enemy


func get_all_alive() -> Array[Enemy]:
	_refresh_buckets_once_per_physics_frame()
	var result: Array[Enemy] = []
	for enemy_variant in enemies_by_net_id.values():
		if enemy_variant == null or not is_instance_valid(enemy_variant):
			continue
		var enemy := enemy_variant as Enemy
		if enemy != null and not enemy.is_dead:
			result.append(enemy)
	return result


func query_radius(center: Vector2, radius: float, max_count: int = 0) -> Array[Enemy]:
	_refresh_buckets_once_per_physics_frame()
	var result: Array[Enemy] = []
	var safe_radius := maxf(radius, 0.0)
	if safe_radius <= 0.0:
		result = get_all_alive()
		result.sort_custom(
			func(a: Enemy, b: Enemy) -> bool:
				var a_distance := center.distance_squared_to(a.global_position)
				var b_distance := center.distance_squared_to(b.global_position)
				if not is_equal_approx(a_distance, b_distance):
					return a_distance < b_distance
				return a.get_instance_id() < b.get_instance_id()
		)
		if max_count > 0 and result.size() > max_count:
			result.resize(max_count)
		return result
	var radius_squared := safe_radius * safe_radius
	var minimum_cell := _to_bucket(center - Vector2.ONE * safe_radius)
	var maximum_cell := _to_bucket(center + Vector2.ONE * safe_radius)
	for cell_x in range(minimum_cell.x, maximum_cell.x + 1):
		for cell_y in range(minimum_cell.y, maximum_cell.y + 1):
			var bucket := buckets.get(Vector2i(cell_x, cell_y), []) as Array
			for enemy_variant in bucket:
				if enemy_variant == null or not is_instance_valid(enemy_variant):
					continue
				var enemy := enemy_variant as Enemy
				if (
					enemy == null
					or enemy.is_dead
					or center.distance_squared_to(enemy.global_position) > radius_squared
				):
					continue
				result.append(enemy)
	result.sort_custom(
		func(a: Enemy, b: Enemy) -> bool:
			var a_distance := center.distance_squared_to(a.global_position)
			var b_distance := center.distance_squared_to(b.global_position)
			if not is_equal_approx(a_distance, b_distance):
				return a_distance < b_distance
			return a.get_instance_id() < b.get_instance_id()
	)
	if max_count > 0 and result.size() > max_count:
		result.resize(max_count)
	return result


func clear() -> void:
	enemies_by_net_id.clear()
	buckets.clear()
	_last_refresh_physics_frame = -1


func _refresh_buckets_once_per_physics_frame() -> void:
	var physics_frame := Engine.get_physics_frames()
	if _last_refresh_physics_frame == physics_frame:
		return
	_last_refresh_physics_frame = physics_frame
	buckets.clear()
	var stale_ids: Array[int] = []
	for net_id_variant in enemies_by_net_id.keys():
		var net_id := int(net_id_variant)
		var enemy_variant: Variant = enemies_by_net_id.get(net_id)
		if enemy_variant == null or not is_instance_valid(enemy_variant):
			stale_ids.append(net_id)
			continue
		var enemy := enemy_variant as Enemy
		if enemy == null or enemy.is_dead:
			stale_ids.append(net_id)
			continue
		var cell := _to_bucket(enemy.global_position)
		var bucket := buckets.get(cell, []) as Array
		bucket.append(enemy)
		buckets[cell] = bucket
	for net_id in stale_ids:
		enemies_by_net_id.erase(net_id)


func _to_bucket(world_position: Vector2) -> Vector2i:
	var safe_bucket_size := maxf(bucket_size, 1.0)
	return Vector2i(
		floori(world_position.x / safe_bucket_size),
		floori(world_position.y / safe_bucket_size)
	)
