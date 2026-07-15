extends RefCounted
class_name CombatTargetIndex

const DEFAULT_BUCKET_SIZE := 96.0

var bucket_size: float = DEFAULT_BUCKET_SIZE
var enemies_by_net_id: Dictionary[int, Enemy] = {}
var buckets: Dictionary[Vector2i, Array] = {}
var bucket_by_net_id: Dictionary[int, Vector2i] = {}
var bucket_slot_by_net_id: Dictionary[int, int] = {}
var _stale_enemy_net_ids: Array[int] = []
var _last_refresh_physics_frame: int = -1


func register_enemy(net_id: int, enemy: Enemy) -> void:
	if net_id <= 0 or enemy == null or not is_instance_valid(enemy):
		return
	if enemies_by_net_id.has(net_id):
		_remove_enemy_entry(net_id)
	enemies_by_net_id[net_id] = enemy
	_add_net_id_to_bucket(net_id, _to_bucket(enemy.global_position))
	# child_entered_tree can register before the spawner assigns its final position.
	# Force the next query to reconcile that immediate bucket within the same frame.
	_last_refresh_physics_frame = -1


func unregister_enemy(net_id: int) -> void:
	if net_id <= 0:
		return
	_remove_enemy_entry(net_id)


func get_enemy(net_id: int) -> Enemy:
	var enemy_variant: Variant = enemies_by_net_id.get(net_id)
	if enemy_variant == null or not is_instance_valid(enemy_variant):
		_remove_enemy_entry(net_id)
		return null
	var enemy := enemy_variant as Enemy
	if enemy == null or enemy.is_dead:
		_remove_enemy_entry(net_id)
		return null
	return enemy


func get_all_alive() -> Array[Enemy]:
	_refresh_buckets_once_per_physics_frame()
	var result: Array[Enemy] = []
	_append_all_alive(result)
	return result


func query_radius(center: Vector2, radius: float, max_count: int = 0) -> Array[Enemy]:
	var result: Array[Enemy] = []
	query_radius_into(center, radius, result, max_count)
	return result


func query_radius_into(
	center: Vector2,
	radius: float,
	result: Array[Enemy],
	max_count: int = 0
) -> void:
	result.clear()
	_refresh_buckets_once_per_physics_frame()
	var safe_radius := maxf(radius, 0.0)
	if max_count == 1:
		_append_nearest_alive(result, center, safe_radius)
		return
	query_radius_unordered_into(center, safe_radius, result)
	_sort_by_distance(result, center)
	_limit_result(result, max_count)


func query_radius_unordered_into(
	center: Vector2,
	radius: float,
	result: Array[Enemy]
) -> void:
	result.clear()
	_refresh_buckets_once_per_physics_frame()
	var safe_radius := maxf(radius, 0.0)
	if safe_radius <= 0.0:
		_append_all_alive(result)
		return
	var radius_squared := safe_radius * safe_radius
	var minimum_cell := _to_bucket(center - Vector2.ONE * safe_radius)
	var maximum_cell := _to_bucket(center + Vector2.ONE * safe_radius)
	for cell_x in range(minimum_cell.x, maximum_cell.x + 1):
		for cell_y in range(minimum_cell.y, maximum_cell.y + 1):
			var cell := Vector2i(cell_x, cell_y)
			if not buckets.has(cell):
				continue
			var bucket := buckets[cell] as Array
			for net_id_variant in bucket:
				var net_id := int(net_id_variant)
				var enemy_variant: Variant = enemies_by_net_id.get(net_id)
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


static func take_nearest_candidate(
	candidates: Array[Enemy],
	center: Vector2
) -> Enemy:
	if candidates.is_empty():
		return null
	var nearest_index := 0
	var nearest := candidates[0]
	var nearest_distance := center.distance_squared_to(nearest.global_position)
	var nearest_instance_id := nearest.get_instance_id()
	for candidate_index in range(1, candidates.size()):
		var candidate := candidates[candidate_index]
		var candidate_distance := center.distance_squared_to(candidate.global_position)
		var candidate_instance_id := candidate.get_instance_id()
		if (
			candidate_distance < nearest_distance
			and not is_equal_approx(candidate_distance, nearest_distance)
		) or (
			is_equal_approx(candidate_distance, nearest_distance)
			and candidate_instance_id < nearest_instance_id
		):
			nearest_index = candidate_index
			nearest = candidate
			nearest_distance = candidate_distance
			nearest_instance_id = candidate_instance_id
	var last_index := candidates.size() - 1
	if nearest_index != last_index:
		candidates[nearest_index] = candidates[last_index]
	candidates.pop_back()
	return nearest


static func sort_candidates_by_distance(
	candidates: Array[Enemy],
	center: Vector2
) -> void:
	candidates.sort_custom(
		func(a: Enemy, b: Enemy) -> bool:
			var a_distance := center.distance_squared_to(a.global_position)
			var b_distance := center.distance_squared_to(b.global_position)
			if not is_equal_approx(a_distance, b_distance):
				return a_distance < b_distance
			return a.get_instance_id() < b.get_instance_id()
	)


func clear() -> void:
	enemies_by_net_id.clear()
	buckets.clear()
	bucket_by_net_id.clear()
	bucket_slot_by_net_id.clear()
	_stale_enemy_net_ids.clear()
	_last_refresh_physics_frame = -1


func _refresh_buckets_once_per_physics_frame() -> void:
	var physics_frame := Engine.get_physics_frames()
	if _last_refresh_physics_frame == physics_frame:
		return
	_last_refresh_physics_frame = physics_frame
	_stale_enemy_net_ids.clear()
	for net_id_variant in enemies_by_net_id:
		var net_id := int(net_id_variant)
		var enemy_variant: Variant = enemies_by_net_id.get(net_id)
		if enemy_variant == null or not is_instance_valid(enemy_variant):
			_stale_enemy_net_ids.append(net_id)
			continue
		var enemy := enemy_variant as Enemy
		if enemy == null or enemy.is_dead:
			_stale_enemy_net_ids.append(net_id)
			continue
		var next_cell := _to_bucket(enemy.global_position)
		if not bucket_by_net_id.has(net_id):
			_add_net_id_to_bucket(net_id, next_cell)
			continue
		var previous_cell: Vector2i = bucket_by_net_id[net_id]
		if previous_cell == next_cell:
			continue
		_remove_net_id_from_bucket(net_id)
		_add_net_id_to_bucket(net_id, next_cell)
	for net_id in _stale_enemy_net_ids:
		_remove_enemy_entry(net_id)


func _append_all_alive(result: Array[Enemy]) -> void:
	for net_id_variant in enemies_by_net_id:
		var enemy_variant: Variant = enemies_by_net_id.get(int(net_id_variant))
		if enemy_variant == null or not is_instance_valid(enemy_variant):
			continue
		var enemy := enemy_variant as Enemy
		if enemy != null and not enemy.is_dead:
			result.append(enemy)


func _append_nearest_alive(
	result: Array[Enemy],
	center: Vector2,
	radius: float
) -> void:
	var nearest: Enemy = null
	var nearest_distance := INF
	var nearest_instance_id := 0
	var radius_squared := radius * radius
	if radius <= 0.0:
		for net_id_variant in enemies_by_net_id:
			var enemy_variant: Variant = enemies_by_net_id.get(int(net_id_variant))
			if enemy_variant == null or not is_instance_valid(enemy_variant):
				continue
			var enemy := enemy_variant as Enemy
			if enemy == null or enemy.is_dead:
				continue
			var distance := center.distance_squared_to(enemy.global_position)
			var instance_id := enemy.get_instance_id()
			if (
				nearest == null
				or (
					distance < nearest_distance
					and not is_equal_approx(distance, nearest_distance)
				)
				or (
					is_equal_approx(distance, nearest_distance)
					and instance_id < nearest_instance_id
				)
			):
				nearest = enemy
				nearest_distance = distance
				nearest_instance_id = instance_id
	else:
		var minimum_cell := _to_bucket(center - Vector2.ONE * radius)
		var maximum_cell := _to_bucket(center + Vector2.ONE * radius)
		var center_cell := _to_bucket(center)
		var maximum_ring := maxi(
			maxi(
				absi(minimum_cell.x - center_cell.x),
				absi(maximum_cell.x - center_cell.x)
			),
			maxi(
				absi(minimum_cell.y - center_cell.y),
				absi(maximum_cell.y - center_cell.y)
			)
		)
		# Visit the center bucket first, then square rings. Once a target is known,
		# a bucket whose AABB is strictly farther than that target cannot improve
		# the exact distance/id result and its enemy array is skipped completely.
		for ring in range(maximum_ring + 1):
			for cell_y in range(center_cell.y - ring, center_cell.y + ring + 1):
				for cell_x in range(center_cell.x - ring, center_cell.x + ring + 1):
					if maxi(absi(cell_x - center_cell.x), absi(cell_y - center_cell.y)) != ring:
						continue
					if (
						cell_x < minimum_cell.x
						or cell_x > maximum_cell.x
						or cell_y < minimum_cell.y
						or cell_y > maximum_cell.y
					):
						continue
					var cell := Vector2i(cell_x, cell_y)
					var cell_minimum_distance := _distance_squared_to_bucket(
						center,
						cell
					)
					if cell_minimum_distance > radius_squared:
						continue
					if (
						nearest != null
						and cell_minimum_distance > nearest_distance
						and not is_equal_approx(
							cell_minimum_distance,
							nearest_distance
						)
					):
						continue
					var cell_nearest := _find_nearest_alive_in_bucket(
						cell,
						center,
						radius_squared
					)
					if cell_nearest == null:
						continue
					var distance := center.distance_squared_to(
						cell_nearest.global_position
					)
					var instance_id := cell_nearest.get_instance_id()
					if (
						nearest == null
						or (
							distance < nearest_distance
							and not is_equal_approx(distance, nearest_distance)
						)
						or (
							is_equal_approx(distance, nearest_distance)
							and instance_id < nearest_instance_id
						)
					):
						nearest = cell_nearest
						nearest_distance = distance
						nearest_instance_id = instance_id
	if nearest != null:
		result.append(nearest)


func _find_nearest_alive_in_bucket(
	cell: Vector2i,
	center: Vector2,
	radius_squared: float
) -> Enemy:
	if not buckets.has(cell):
		return null
	var nearest: Enemy = null
	var nearest_distance := INF
	var nearest_instance_id := 0
	var bucket := buckets[cell] as Array
	for net_id_variant in bucket:
		var enemy_variant: Variant = enemies_by_net_id.get(int(net_id_variant))
		if enemy_variant == null or not is_instance_valid(enemy_variant):
			continue
		var enemy := enemy_variant as Enemy
		if enemy == null or enemy.is_dead:
			continue
		var distance := center.distance_squared_to(enemy.global_position)
		if distance > radius_squared:
			continue
		var instance_id := enemy.get_instance_id()
		if (
			nearest == null
			or (
				distance < nearest_distance
				and not is_equal_approx(distance, nearest_distance)
			)
			or (
				is_equal_approx(distance, nearest_distance)
				and instance_id < nearest_instance_id
			)
		):
			nearest = enemy
			nearest_distance = distance
			nearest_instance_id = instance_id
	return nearest


func _distance_squared_to_bucket(center: Vector2, cell: Vector2i) -> float:
	var safe_bucket_size := maxf(bucket_size, 1.0)
	var bucket_minimum := Vector2(cell) * safe_bucket_size
	var bucket_maximum := bucket_minimum + Vector2.ONE * safe_bucket_size
	var closest_point := Vector2(
		clampf(center.x, bucket_minimum.x, bucket_maximum.x),
		clampf(center.y, bucket_minimum.y, bucket_maximum.y)
	)
	return center.distance_squared_to(closest_point)


func _add_net_id_to_bucket(net_id: int, cell: Vector2i) -> void:
	if buckets.has(cell):
		var bucket := buckets[cell] as Array
		bucket_slot_by_net_id[net_id] = bucket.size()
		bucket.append(net_id)
	else:
		buckets[cell] = [net_id]
		bucket_slot_by_net_id[net_id] = 0
	bucket_by_net_id[net_id] = cell


func _remove_net_id_from_bucket(net_id: int) -> void:
	if not bucket_by_net_id.has(net_id):
		return
	var cell: Vector2i = bucket_by_net_id[net_id]
	var slot := int(bucket_slot_by_net_id[net_id])
	bucket_by_net_id.erase(net_id)
	bucket_slot_by_net_id.erase(net_id)
	if not buckets.has(cell):
		return
	var bucket := buckets[cell] as Array
	var last_slot := bucket.size() - 1
	if slot != last_slot:
		var moved_net_id := int(bucket[last_slot])
		bucket[slot] = moved_net_id
		bucket_slot_by_net_id[moved_net_id] = slot
	bucket.pop_back()
	if bucket.is_empty():
		buckets.erase(cell)


func _remove_enemy_entry(net_id: int) -> void:
	_remove_net_id_from_bucket(net_id)
	enemies_by_net_id.erase(net_id)


func _sort_by_distance(result: Array[Enemy], center: Vector2) -> void:
	sort_candidates_by_distance(result, center)


func _limit_result(result: Array[Enemy], max_count: int) -> void:
	if max_count > 0 and result.size() > max_count:
		result.resize(max_count)


func _to_bucket(world_position: Vector2) -> Vector2i:
	var safe_bucket_size := maxf(bucket_size, 1.0)
	return Vector2i(
		floori(world_position.x / safe_bucket_size),
		floori(world_position.y / safe_bucket_size)
	)
