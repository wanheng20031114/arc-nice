extends RefCounted
class_name CombatTargetIndex

const COMBAT_RELATIONS := preload(
	"res://scene/combat/faction/combat_relation_service.gd"
)

const DEFAULT_BUCKET_SIZE := 96.0
const SAFETY_AUDIT_ENTRIES_PER_PHYSICS_FRAME := 16
# Interleaved 300-caster/five-hit probes put the direct/ring crossover between
# 32 and 64 registered enemies. Registries through 32 use direct linear work;
# 33..64 use ring pruning. Larger registries pre-count at most sixteen local
# buckets, selecting flat iteration only when that local membership stays <=32.
# Every bounded query first compares its bucket-cell span with compact registry
# membership, so sparse broad radii never walk more empty cells than targets.
const NEAREST_LINEAR_TARGET_THRESHOLD := 32
const NEAREST_LOCAL_PRECOUNT_MIN_TARGET_COUNT := 65
const NEAREST_LOCAL_PRECOUNT_MAX_BUCKET_CELLS := 16
const MIN_VECTOR2I_COMPONENT := -2147483648.0
const MAX_VECTOR2I_COMPONENT_EXCLUSIVE := 2147483648.0

var bucket_size: float = DEFAULT_BUCKET_SIZE
var enemies_by_net_id: Dictionary[int, Enemy] = {}
var buckets: Dictionary[Vector2i, Array] = {}
var bucket_by_net_id: Dictionary[int, Vector2i] = {}
var bucket_slot_by_net_id: Dictionary[int, int] = {}
# Faction partitions share the same authoritative enemy registry and spatial
# cell math. They avoid scanning friendly occupants while retaining the legacy
# all-enemy buckets for player/tower callers that have not migrated yet.
var faction_by_net_id: Dictionary[int, int] = {}
var faction_buckets: Dictionary[int, Dictionary] = {}
var faction_bucket_slot_by_net_id: Dictionary[int, int] = {}
var safety_audit_net_ids: Array[int] = []
var safety_audit_slot_by_net_id: Dictionary[int, int] = {}
var safety_audit_cursor := 0
var _stale_enemy_net_ids: Array[int] = []
var _empty_excluded_instance_ids: Dictionary = {}
var _last_refresh_physics_frame: int = -1
var event_bucket_migrations_total := 0
var full_bucket_audits_total := 0
var safety_audit_entries_total := 0
var safety_audit_max_entries_per_frame := 0


static func is_enemy_queryable(enemy: Enemy) -> bool:
	return (
		enemy != null
		and is_instance_valid(enemy)
		and not enemy.is_dead
		and not enemy.is_queued_for_deletion()
		and enemy.global_position.is_finite()
	)


func register_enemy(net_id: int, enemy: Enemy) -> void:
	if net_id <= 0 or enemy == null or not is_instance_valid(enemy):
		return
	var world_position := enemy.global_position
	if not world_position.is_finite() or not _can_convert_to_bucket(world_position):
		return
	if enemies_by_net_id.has(net_id):
		_remove_enemy_entry(net_id)
	enemies_by_net_id[net_id] = enemy
	faction_by_net_id[net_id] = COMBAT_RELATIONS.normalize_faction_id(
		enemy.get_combat_faction_id(),
		COMBAT_RELATIONS.HOSTILE_WAVE
	)
	_add_net_id_to_bucket(net_id, _to_bucket(world_position))
	_add_net_id_to_safety_audit(net_id)
	# Binding happens after the initial slot exists. A spawner may assign the final
	# position after child_entered_tree; the transform notification then migrates
	# only that entry instead of forcing the next query to audit every enemy.
	enemy.bind_combat_target_index(self, net_id)
	if _last_refresh_physics_frame < 0:
		_last_refresh_physics_frame = Engine.get_physics_frames()


func update_enemy_bucket(
	net_id: int,
	enemy: Enemy = null,
	known_bucket: Vector2i = Vector2i.MAX
) -> bool:
	if net_id <= 0 or not enemies_by_net_id.has(net_id):
		return false
	var registered_enemy := enemies_by_net_id.get(net_id) as Enemy
	if (
		registered_enemy == null
		or not is_instance_valid(registered_enemy)
		or (enemy != null and registered_enemy != enemy)
	):
		return false
	var world_position := registered_enemy.global_position
	if not world_position.is_finite() or not _can_convert_to_bucket(world_position):
		_remove_enemy_entry(net_id)
		return false
	var next_cell := known_bucket
	if next_cell == Vector2i.MAX:
		next_cell = _to_bucket(world_position)
	var previous_cell: Vector2i = bucket_by_net_id.get(net_id, Vector2i.MAX)
	if previous_cell == next_cell:
		return true
	_remove_net_id_from_bucket(net_id)
	_add_net_id_to_bucket(net_id, next_cell)
	event_bucket_migrations_total += 1
	return true


func update_faction(
	enemy: Enemy,
	old_faction_id: int,
	new_faction_id: int
) -> bool:
	if enemy == null or not is_instance_valid(enemy):
		return false
	var net_id := enemy.combat_target_index_net_id
	if net_id <= 0 or enemies_by_net_id.get(net_id) != enemy:
		return false
	var current_faction_id := int(
		faction_by_net_id.get(net_id, COMBAT_RELATIONS.HOSTILE_WAVE)
	)
	if (
		COMBAT_RELATIONS.is_valid_faction_id(old_faction_id)
		and current_faction_id != old_faction_id
	):
		# The index state is authoritative for migration. A stale caller hint must
		# not strand the entry in two partitions.
		old_faction_id = current_faction_id
	var safe_new_faction_id := COMBAT_RELATIONS.normalize_faction_id(
		new_faction_id,
		current_faction_id
	)
	if current_faction_id == safe_new_faction_id:
		return true
	var cell: Vector2i = bucket_by_net_id.get(net_id, Vector2i.MAX)
	if cell == Vector2i.MAX:
		return false
	_remove_net_id_from_faction_bucket(net_id, current_faction_id, cell)
	faction_by_net_id[net_id] = safe_new_faction_id
	_add_net_id_to_faction_bucket(net_id, safe_new_faction_id, cell)
	return true


func unregister_enemy(net_id: int, expected_enemy: Enemy = null) -> void:
	if net_id <= 0:
		return
	if expected_enemy != null:
		var registered_enemy := enemies_by_net_id.get(net_id) as Enemy
		if registered_enemy != expected_enemy:
			expected_enemy.unbind_combat_target_index(self, net_id)
			return
	_remove_enemy_entry(net_id)


func get_enemy(net_id: int) -> Enemy:
	var enemy_variant: Variant = enemies_by_net_id.get(net_id)
	if enemy_variant == null or not is_instance_valid(enemy_variant):
		_remove_enemy_entry(net_id)
		return null
	var enemy := enemy_variant as Enemy
	if not is_enemy_queryable(enemy):
		_remove_enemy_entry(net_id)
		return null
	return enemy


func get_all_alive() -> Array[Enemy]:
	var result: Array[Enemy] = []
	# A full-list query does not consume bucket positions, so reconciling every
	# moving enemy first would be redundant O(n) work.
	_append_all_alive(result)
	return result


func pick_random_alive() -> Enemy:
	# The safety-audit order is also a dense, swap-removed registry of every live
	# net id. Random access therefore stays O(1) in the normal lifecycle path and
	# does not need to allocate an all-target array.
	while not safety_audit_net_ids.is_empty():
		var random_slot := randi() % safety_audit_net_ids.size()
		var enemy := get_enemy(safety_audit_net_ids[random_slot])
		if enemy != null:
			return enemy
		# get_enemy() removes a stale/dead entry in O(1); retry the compacted slot
		# set until a live target is found or the registry becomes empty.
	return null


func pick_random_alive_in_radius(center: Vector2, radius: float) -> Enemy:
	if not center.is_finite() or not is_finite(radius):
		return null
	var safe_radius := maxf(radius, 0.0)
	if safe_radius <= 0.0:
		return pick_random_alive()
	_advance_safety_audit_once_per_physics_frame()
	var radius_squared := safe_radius * safe_radius
	var radius_vector := Vector2.ONE * safe_radius
	var minimum := center - radius_vector
	var maximum := center + radius_vector
	if _should_scan_radius_registry(minimum, maximum):
		return _pick_random_alive_in_radius_registry(center, radius_squared)
	var minimum_cell := _to_bucket(minimum)
	var maximum_cell := _to_bucket(maximum)
	return _pick_random_alive_in_radius_buckets(
		center,
		radius_squared,
		minimum_cell,
		maximum_cell
	)


func _pick_random_alive_in_radius_registry(
	center: Vector2,
	radius_squared: float
) -> Enemy:
	var selected_enemy: Enemy = null
	var candidate_count := 0
	_stale_enemy_net_ids.clear()
	for net_id_variant in enemies_by_net_id:
		var net_id := int(net_id_variant)
		var enemy_variant: Variant = enemies_by_net_id.get(net_id)
		if enemy_variant == null or not is_instance_valid(enemy_variant):
			_stale_enemy_net_ids.append(net_id)
			continue
		var enemy := enemy_variant as Enemy
		if not is_enemy_queryable(enemy):
			_stale_enemy_net_ids.append(net_id)
			continue
		if center.distance_squared_to(enemy.global_position) > radius_squared:
			continue
		candidate_count += 1
		if randi() % candidate_count == 0:
			selected_enemy = enemy
	for net_id in _stale_enemy_net_ids:
		_remove_enemy_entry(net_id)
	return selected_enemy


func _pick_random_alive_in_radius_buckets(
	center: Vector2,
	radius_squared: float,
	minimum_cell: Vector2i,
	maximum_cell: Vector2i
) -> Enemy:
	var selected_enemy: Enemy = null
	var candidate_count := 0
	_stale_enemy_net_ids.clear()
	# Reservoir sampling keeps the result uniformly random without constructing a
	# candidate array. Narrow searches depend only on touched buckets and local
	# occupancy; broad sparse searches use the compact registry helper above.
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
					_stale_enemy_net_ids.append(net_id)
					continue
				var enemy := enemy_variant as Enemy
				if not is_enemy_queryable(enemy):
					_stale_enemy_net_ids.append(net_id)
					continue
				if center.distance_squared_to(enemy.global_position) > radius_squared:
					continue
				candidate_count += 1
				if randi() % candidate_count == 0:
					selected_enemy = enemy
	for net_id in _stale_enemy_net_ids:
		_remove_enemy_entry(net_id)
	return selected_enemy


func query_radius(center: Vector2, radius: float, max_count: int = 0) -> Array[Enemy]:
	var result: Array[Enemy] = []
	query_radius_into(center, radius, result, max_count)
	return result


func query_hostile_radius_into(
	center: Vector2,
	radius: float,
	source_faction_id: int,
	result: Array[Enemy],
	max_count: int = 0,
	excluded_enemy: Enemy = null,
	relation_service: CombatRelationService = null
) -> void:
	result.clear()
	if (
		not center.is_finite()
		or not is_finite(radius)
		or radius < 0.0
		or not COMBAT_RELATIONS.is_valid_faction_id(source_faction_id)
	):
		return
	_advance_safety_audit_once_per_physics_frame()
	var radius_squared := radius * radius
	var radius_vector := Vector2.ONE * radius
	var minimum := center - radius_vector
	var maximum := center + radius_vector
	if radius == 0.0 or _should_scan_radius_registry(minimum, maximum):
		_append_hostile_in_radius_registry(
			center,
			radius_squared,
			source_faction_id,
			result,
			excluded_enemy,
			relation_service
		)
	else:
		_append_hostile_in_radius_buckets(
			center,
			radius_squared,
			_to_bucket(minimum),
			_to_bucket(maximum),
			source_faction_id,
			result,
			excluded_enemy,
			relation_service
		)
	_sort_hostile_candidates_by_distance(result, center)
	_limit_result(result, max_count)


func find_nearest_hostile(
	center: Vector2,
	radius: float,
	source_faction_id: int,
	excluded_enemy: Enemy = null,
	relation_service: CombatRelationService = null
) -> Enemy:
	var result: Array[Enemy] = []
	query_hostile_radius_into(
		center,
		radius,
		source_faction_id,
		result,
		1,
		excluded_enemy,
		relation_service
	)
	return result[0] if not result.is_empty() else null


func query_world_aabb_into(
	world_aabb: Rect2,
	result: Array[Enemy],
	max_count: int = 0
) -> void:
	result.clear()
	if (
		not world_aabb.position.is_finite()
		or not world_aabb.size.is_finite()
	):
		return
	var normalized_aabb := world_aabb.abs()
	if normalized_aabb.size.x <= 0.0 or normalized_aabb.size.y <= 0.0:
		return
	var minimum := normalized_aabb.position
	var maximum := normalized_aabb.end
	_advance_safety_audit_once_per_physics_frame()
	_stale_enemy_net_ids.clear()
	if _should_scan_radius_registry(minimum, maximum):
		for net_id_variant in enemies_by_net_id:
			var net_id := int(net_id_variant)
			var enemy_variant: Variant = enemies_by_net_id.get(net_id)
			if enemy_variant == null or not is_instance_valid(enemy_variant):
				_stale_enemy_net_ids.append(net_id)
				continue
			var enemy := enemy_variant as Enemy
			if not is_enemy_queryable(enemy):
				_stale_enemy_net_ids.append(net_id)
				continue
			if normalized_aabb.has_point(enemy.global_position):
				result.append(enemy)
	else:
		var minimum_cell := _to_bucket(minimum)
		var maximum_cell := _to_bucket(maximum)
		for cell_y in range(minimum_cell.y, maximum_cell.y + 1):
			for cell_x in range(minimum_cell.x, maximum_cell.x + 1):
				var cell := Vector2i(cell_x, cell_y)
				if not buckets.has(cell):
					continue
				for net_id_variant in buckets[cell] as Array:
					var net_id := int(net_id_variant)
					var enemy_variant: Variant = enemies_by_net_id.get(net_id)
					if enemy_variant == null or not is_instance_valid(enemy_variant):
						_stale_enemy_net_ids.append(net_id)
						continue
					var enemy := enemy_variant as Enemy
					if not is_enemy_queryable(enemy):
						_stale_enemy_net_ids.append(net_id)
						continue
					if normalized_aabb.has_point(enemy.global_position):
						result.append(enemy)
	for stale_net_id in _stale_enemy_net_ids:
		_remove_enemy_entry(stale_net_id)
	_sort_candidates_by_stable_net_id(result)
	_limit_result(result, max_count)


## Unordered faction-aware broadphase for shared contact simulation. The caller
## owns and reuses `result`; only exact contact candidates are sorted later.
func query_hostile_world_aabb_unordered_into(
	world_aabb: Rect2,
	source_faction_id: int,
	result: Array[Enemy],
	excluded_enemy: Enemy = null,
	relation_service: CombatRelationService = null
) -> void:
	result.clear()
	if (
		not world_aabb.position.is_finite()
		or not world_aabb.size.is_finite()
		or not COMBAT_RELATIONS.is_valid_faction_id(source_faction_id)
	):
		return
	var normalized_aabb := world_aabb.abs()
	if normalized_aabb.size.x <= 0.0 or normalized_aabb.size.y <= 0.0:
		return
	var minimum := normalized_aabb.position
	var maximum := normalized_aabb.end
	_advance_safety_audit_once_per_physics_frame()
	_stale_enemy_net_ids.clear()
	if _should_scan_radius_registry(minimum, maximum):
		for net_id_variant in enemies_by_net_id:
			var net_id := int(net_id_variant)
			var enemy_variant: Variant = enemies_by_net_id.get(net_id)
			if enemy_variant == null or not is_instance_valid(enemy_variant):
				_stale_enemy_net_ids.append(net_id)
				continue
			var enemy := enemy_variant as Enemy
			if not is_enemy_queryable(enemy):
				_stale_enemy_net_ids.append(net_id)
				continue
			if enemy == excluded_enemy:
				continue
			var target_faction_id := int(faction_by_net_id.get(net_id, -1))
			if not _is_hostile_relation(
				source_faction_id,
				target_faction_id,
				relation_service
			):
				continue
			if normalized_aabb.has_point(enemy.global_position):
				result.append(enemy)
	else:
		var minimum_cell := _to_bucket(minimum)
		var maximum_cell := _to_bucket(maximum)
		for target_faction_id in range(COMBAT_RELATIONS.MAX_FACTION_COUNT):
			if not _is_hostile_relation(
				source_faction_id,
				target_faction_id,
				relation_service
			):
				continue
			var faction_cells_variant: Variant = faction_buckets.get(target_faction_id)
			if faction_cells_variant == null:
				continue
			var faction_cells := faction_cells_variant as Dictionary
			for cell_y in range(minimum_cell.y, maximum_cell.y + 1):
				for cell_x in range(minimum_cell.x, maximum_cell.x + 1):
					var cell := Vector2i(cell_x, cell_y)
					if not faction_cells.has(cell):
						continue
					for net_id_variant in faction_cells[cell] as Array:
						var net_id := int(net_id_variant)
						var enemy_variant: Variant = enemies_by_net_id.get(net_id)
						if enemy_variant == null or not is_instance_valid(enemy_variant):
							_stale_enemy_net_ids.append(net_id)
							continue
						var enemy := enemy_variant as Enemy
						if not is_enemy_queryable(enemy):
							_stale_enemy_net_ids.append(net_id)
							continue
						if enemy == excluded_enemy:
							continue
						if normalized_aabb.has_point(enemy.global_position):
							result.append(enemy)
	for stale_net_id in _stale_enemy_net_ids:
		_remove_enemy_entry(stale_net_id)


func _append_hostile_in_radius_registry(
	center: Vector2,
	radius_squared: float,
	source_faction_id: int,
	result: Array[Enemy],
	excluded_enemy: Enemy,
	relation_service: CombatRelationService
) -> void:
	_stale_enemy_net_ids.clear()
	for net_id_variant in enemies_by_net_id:
		var net_id := int(net_id_variant)
		var enemy_variant: Variant = enemies_by_net_id.get(net_id)
		if enemy_variant == null or not is_instance_valid(enemy_variant):
			_stale_enemy_net_ids.append(net_id)
			continue
		var enemy := enemy_variant as Enemy
		if not is_enemy_queryable(enemy):
			_stale_enemy_net_ids.append(net_id)
			continue
		if enemy == excluded_enemy:
			continue
		var target_faction_id := int(faction_by_net_id.get(net_id, -1))
		if not _is_hostile_relation(
			source_faction_id,
			target_faction_id,
			relation_service
		):
			continue
		if center.distance_squared_to(enemy.global_position) <= radius_squared:
			result.append(enemy)
	for stale_net_id in _stale_enemy_net_ids:
		_remove_enemy_entry(stale_net_id)


func _append_hostile_in_radius_buckets(
	center: Vector2,
	radius_squared: float,
	minimum_cell: Vector2i,
	maximum_cell: Vector2i,
	source_faction_id: int,
	result: Array[Enemy],
	excluded_enemy: Enemy,
	relation_service: CombatRelationService
) -> void:
	_stale_enemy_net_ids.clear()
	for target_faction_id in range(COMBAT_RELATIONS.MAX_FACTION_COUNT):
		if not _is_hostile_relation(
			source_faction_id,
			target_faction_id,
			relation_service
		):
			continue
		var faction_cells_variant: Variant = faction_buckets.get(target_faction_id)
		if faction_cells_variant == null:
			continue
		var faction_cells := faction_cells_variant as Dictionary
		for cell_y in range(minimum_cell.y, maximum_cell.y + 1):
			for cell_x in range(minimum_cell.x, maximum_cell.x + 1):
				var cell := Vector2i(cell_x, cell_y)
				if not faction_cells.has(cell):
					continue
				for net_id_variant in faction_cells[cell] as Array:
					var net_id := int(net_id_variant)
					var enemy_variant: Variant = enemies_by_net_id.get(net_id)
					if enemy_variant == null or not is_instance_valid(enemy_variant):
						_stale_enemy_net_ids.append(net_id)
						continue
					var enemy := enemy_variant as Enemy
					if not is_enemy_queryable(enemy):
						_stale_enemy_net_ids.append(net_id)
						continue
					if enemy == excluded_enemy:
						continue
					if center.distance_squared_to(enemy.global_position) <= radius_squared:
						result.append(enemy)
	for stale_net_id in _stale_enemy_net_ids:
		_remove_enemy_entry(stale_net_id)


func _is_hostile_relation(
	source_faction_id: int,
	target_faction_id: int,
	relation_service: CombatRelationService
) -> bool:
	if relation_service != null:
		return relation_service.is_hostile(source_faction_id, target_faction_id)
	return COMBAT_RELATIONS.is_default_hostile(
		source_faction_id,
		target_faction_id
	)


func _sort_hostile_candidates_by_distance(
	candidates: Array[Enemy],
	center: Vector2
) -> void:
	candidates.sort_custom(
		func(a: Enemy, b: Enemy) -> bool:
			var a_distance := center.distance_squared_to(a.global_position)
			var b_distance := center.distance_squared_to(b.global_position)
			if a_distance != b_distance:
				return a_distance < b_distance
			return _get_stable_enemy_id(a) < _get_stable_enemy_id(b)
	)


func _sort_candidates_by_stable_net_id(candidates: Array[Enemy]) -> void:
	candidates.sort_custom(
		func(a: Enemy, b: Enemy) -> bool:
			return _get_stable_enemy_id(a) < _get_stable_enemy_id(b)
	)


func _get_stable_enemy_id(enemy: Enemy) -> int:
	if enemy != null and enemy.combat_target_index_net_id > 0:
		return enemy.combat_target_index_net_id
	return enemy.get_instance_id() if enemy != null else 0


## Returns the nearest live target without allocating a candidate array.
## The radius is a closed-circle contract: zero only matches a co-located target,
## while negative or non-finite inputs are rejected before spatial conversion.
func find_nearest_alive_excluding(
	center: Vector2,
	radius: float,
	excluded_instance_ids: Dictionary
) -> Enemy:
	if not center.is_finite() or not is_finite(radius) or radius < 0.0:
		return null
	if radius == 0.0:
		return _find_nearest_alive_linear_bounded(
			center,
			radius,
			excluded_instance_ids,
			true
		)
	if radius > 0.0:
		_advance_safety_audit_once_per_physics_frame()
	return _find_nearest_alive(
		center,
		radius,
		excluded_instance_ids
	)


func query_radius_into(
	center: Vector2,
	radius: float,
	result: Array[Enemy],
	max_count: int = 0
) -> void:
	result.clear()
	if not center.is_finite() or not is_finite(radius):
		return
	var safe_radius := maxf(radius, 0.0)
	if max_count == 1:
		if safe_radius > 0.0:
			_advance_safety_audit_once_per_physics_frame()
		_append_nearest_alive(result, center, safe_radius)
		return
	if safe_radius <= 0.0:
		_append_all_alive(result)
		_sort_by_distance(result, center)
		_limit_result(result, max_count)
		return
	_advance_safety_audit_once_per_physics_frame()
	query_radius_unordered_into(center, safe_radius, result)
	_sort_by_distance(result, center)
	_limit_result(result, max_count)


func query_radius_unordered_into(
	center: Vector2,
	radius: float,
	result: Array[Enemy]
) -> void:
	result.clear()
	if not center.is_finite() or not is_finite(radius):
		return
	var safe_radius := maxf(radius, 0.0)
	if safe_radius <= 0.0:
		_append_all_alive(result)
		return
	_advance_safety_audit_once_per_physics_frame()
	var radius_squared := safe_radius * safe_radius
	var radius_vector := Vector2.ONE * safe_radius
	var minimum := center - radius_vector
	var maximum := center + radius_vector
	if _should_scan_radius_registry(minimum, maximum):
		_append_alive_in_radius_registry(center, radius_squared, result)
		return
	var minimum_cell := _to_bucket(minimum)
	var maximum_cell := _to_bucket(maximum)
	_append_alive_in_radius_buckets(
		center,
		radius_squared,
		minimum_cell,
		maximum_cell,
		result
	)


func _append_alive_in_radius_registry(
	center: Vector2,
	radius_squared: float,
	result: Array[Enemy]
) -> void:
	_stale_enemy_net_ids.clear()
	for net_id_variant in enemies_by_net_id:
		var net_id := int(net_id_variant)
		var enemy_variant: Variant = enemies_by_net_id.get(net_id)
		if enemy_variant == null or not is_instance_valid(enemy_variant):
			_stale_enemy_net_ids.append(net_id)
			continue
		var enemy := enemy_variant as Enemy
		if not is_enemy_queryable(enemy):
			_stale_enemy_net_ids.append(net_id)
			continue
		if center.distance_squared_to(enemy.global_position) <= radius_squared:
			result.append(enemy)
	for net_id in _stale_enemy_net_ids:
		_remove_enemy_entry(net_id)


func _append_alive_in_radius_buckets(
	center: Vector2,
	radius_squared: float,
	minimum_cell: Vector2i,
	maximum_cell: Vector2i,
	result: Array[Enemy]
) -> void:
	_stale_enemy_net_ids.clear()
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
					_stale_enemy_net_ids.append(net_id)
					continue
				var enemy := enemy_variant as Enemy
				if not is_enemy_queryable(enemy):
					_stale_enemy_net_ids.append(net_id)
					continue
				if center.distance_squared_to(enemy.global_position) > radius_squared:
					continue
				result.append(enemy)
	for net_id in _stale_enemy_net_ids:
		_remove_enemy_entry(net_id)


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
		) or (
			candidate_distance == nearest_distance
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
			if a_distance != b_distance:
				return a_distance < b_distance
			return a.get_instance_id() < b.get_instance_id()
	)


func clear() -> void:
	for net_id_variant in enemies_by_net_id:
		var net_id := int(net_id_variant)
		var enemy_variant: Variant = enemies_by_net_id.get(net_id)
		if enemy_variant != null and is_instance_valid(enemy_variant):
			var enemy := enemy_variant as Enemy
			if enemy != null:
				enemy.unbind_combat_target_index(self, net_id)
	enemies_by_net_id.clear()
	buckets.clear()
	bucket_by_net_id.clear()
	bucket_slot_by_net_id.clear()
	faction_by_net_id.clear()
	faction_buckets.clear()
	faction_bucket_slot_by_net_id.clear()
	safety_audit_net_ids.clear()
	safety_audit_slot_by_net_id.clear()
	safety_audit_cursor = 0
	_stale_enemy_net_ids.clear()
	_last_refresh_physics_frame = -1
	event_bucket_migrations_total = 0
	full_bucket_audits_total = 0
	safety_audit_entries_total = 0
	safety_audit_max_entries_per_frame = 0


func _advance_safety_audit_once_per_physics_frame() -> void:
	var physics_frame := Engine.get_physics_frames()
	if _last_refresh_physics_frame == physics_frame:
		return
	_last_refresh_physics_frame = physics_frame
	if safety_audit_net_ids.is_empty():
		safety_audit_cursor = 0
		return
	# Transform notifications are authoritative. This bounded round-robin slice is
	# only a repair net for unexpected ancestor transforms or lifecycle mistakes;
	# it must never reintroduce an O(enemy count) periodic query-frame spike.
	var initial_entry_count := safety_audit_net_ids.size()
	var maximum_entries := mini(
		SAFETY_AUDIT_ENTRIES_PER_PHYSICS_FRAME,
		initial_entry_count
	)
	var audited_entries := 0
	while (
		audited_entries < maximum_entries
		and not safety_audit_net_ids.is_empty()
	):
		if safety_audit_cursor >= safety_audit_net_ids.size():
			safety_audit_cursor = 0
			full_bucket_audits_total += 1
		var net_id := safety_audit_net_ids[safety_audit_cursor]
		safety_audit_cursor += 1
		audited_entries += 1
		var enemy_variant: Variant = enemies_by_net_id.get(net_id)
		if enemy_variant == null or not is_instance_valid(enemy_variant):
			_remove_enemy_entry(net_id)
			continue
		var enemy := enemy_variant as Enemy
		if not is_enemy_queryable(enemy):
			_remove_enemy_entry(net_id)
			continue
		var next_cell := _to_bucket(enemy.global_position)
		enemy.sync_combat_target_index_bucket(
			self,
			net_id,
			next_cell,
			bucket_size
		)
		if not bucket_by_net_id.has(net_id):
			_add_net_id_to_bucket(net_id, next_cell)
			continue
		var previous_cell: Vector2i = bucket_by_net_id[net_id]
		if previous_cell == next_cell:
			continue
		_remove_net_id_from_bucket(net_id)
		_add_net_id_to_bucket(net_id, next_cell)
	if (
		not safety_audit_net_ids.is_empty()
		and safety_audit_cursor >= safety_audit_net_ids.size()
	):
		safety_audit_cursor = 0
		full_bucket_audits_total += 1
	safety_audit_entries_total += audited_entries
	safety_audit_max_entries_per_frame = maxi(
		safety_audit_max_entries_per_frame,
		audited_entries
	)


func _append_all_alive(result: Array[Enemy]) -> void:
	_stale_enemy_net_ids.clear()
	for net_id_variant in enemies_by_net_id:
		var net_id := int(net_id_variant)
		var enemy_variant: Variant = enemies_by_net_id.get(net_id)
		if enemy_variant == null or not is_instance_valid(enemy_variant):
			_stale_enemy_net_ids.append(net_id)
			continue
		var enemy := enemy_variant as Enemy
		if not is_enemy_queryable(enemy):
			_stale_enemy_net_ids.append(net_id)
			continue
		result.append(enemy)
	for net_id in _stale_enemy_net_ids:
		_remove_enemy_entry(net_id)


func _append_nearest_alive(
	result: Array[Enemy],
	center: Vector2,
	radius: float
) -> void:
	var nearest := _find_nearest_alive(
		center,
		radius,
		_empty_excluded_instance_ids
	)
	if nearest != null:
		result.append(nearest)


func _find_nearest_alive(
	center: Vector2,
	radius: float,
	excluded_instance_ids: Dictionary
) -> Enemy:
	var registered_count := enemies_by_net_id.size()
	if (
		radius <= 0.0
		or registered_count <= NEAREST_LINEAR_TARGET_THRESHOLD
	):
		return _find_nearest_alive_linear(
			center,
			radius,
			excluded_instance_ids
		)
	var radius_vector := Vector2.ONE * radius
	var minimum := center - radius_vector
	var maximum := center + radius_vector
	if _should_scan_radius_registry(minimum, maximum):
		return _find_nearest_alive_linear_bounded(
			center,
			radius,
			excluded_instance_ids,
			true
		)
	if registered_count < NEAREST_LOCAL_PRECOUNT_MIN_TARGET_COUNT:
		return _find_nearest_alive_ring(center, radius, excluded_instance_ids)

	var minimum_cell := _to_bucket(minimum)
	var maximum_cell := _to_bucket(maximum)
	var bucket_columns := maximum_cell.x - minimum_cell.x + 1
	var bucket_rows := maximum_cell.y - minimum_cell.y + 1
	if (
		bucket_columns <= 0
		or bucket_rows <= 0
		or bucket_columns > NEAREST_LOCAL_PRECOUNT_MAX_BUCKET_CELLS
		or bucket_rows > NEAREST_LOCAL_PRECOUNT_MAX_BUCKET_CELLS
		or bucket_columns * bucket_rows
			> NEAREST_LOCAL_PRECOUNT_MAX_BUCKET_CELLS
	):
		return _find_nearest_alive_ring(center, radius, excluded_instance_ids)

	var local_membership_count := _count_bucket_memberships_until(
		minimum_cell,
		maximum_cell,
		NEAREST_LINEAR_TARGET_THRESHOLD
	)
	if local_membership_count <= NEAREST_LINEAR_TARGET_THRESHOLD:
		return _find_nearest_alive_flat(
			center,
			radius,
			excluded_instance_ids,
			minimum_cell,
			maximum_cell
		)
	return _find_nearest_alive_ring_in_bounds(
		center,
		radius,
		excluded_instance_ids,
		minimum_cell,
		maximum_cell,
		_to_bucket(center)
	)


func _find_nearest_alive_linear(
	center: Vector2,
	radius: float,
	excluded_instance_ids: Dictionary
) -> Enemy:
	return _find_nearest_alive_linear_bounded(
		center,
		radius,
		excluded_instance_ids,
		radius > 0.0
	)


func _find_nearest_alive_linear_bounded(
	center: Vector2,
	radius: float,
	excluded_instance_ids: Dictionary,
	enforce_radius: bool
) -> Enemy:
	var nearest: Enemy = null
	var nearest_distance := INF
	var nearest_instance_id := 0
	var radius_squared := radius * radius
	_stale_enemy_net_ids.clear()
	for net_id_variant in enemies_by_net_id:
		var net_id := int(net_id_variant)
		var enemy_variant: Variant = enemies_by_net_id.get(net_id)
		if enemy_variant == null or not is_instance_valid(enemy_variant):
			_stale_enemy_net_ids.append(net_id)
			continue
		var enemy := enemy_variant as Enemy
		if not is_enemy_queryable(enemy):
			_stale_enemy_net_ids.append(net_id)
			continue
		if excluded_instance_ids.has(enemy.get_instance_id()):
			continue
		var distance := center.distance_squared_to(enemy.global_position)
		if enforce_radius and distance > radius_squared:
			continue
		var instance_id := enemy.get_instance_id()
		if (
			nearest == null
			or distance < nearest_distance
			or (
				distance == nearest_distance
				and instance_id < nearest_instance_id
			)
		):
			nearest = enemy
			nearest_distance = distance
			nearest_instance_id = instance_id
	for net_id in _stale_enemy_net_ids:
		_remove_enemy_entry(net_id)
	return nearest


func _find_nearest_alive_ring(
	center: Vector2,
	radius: float,
	excluded_instance_ids: Dictionary
) -> Enemy:
	var minimum_cell := _to_bucket(center - Vector2.ONE * radius)
	var maximum_cell := _to_bucket(center + Vector2.ONE * radius)
	var center_cell := _to_bucket(center)
	return _find_nearest_alive_ring_in_bounds(
		center,
		radius,
		excluded_instance_ids,
		minimum_cell,
		maximum_cell,
		center_cell
	)


func _find_nearest_alive_ring_in_bounds(
	center: Vector2,
	radius: float,
	excluded_instance_ids: Dictionary,
	minimum_cell: Vector2i,
	maximum_cell: Vector2i,
	center_cell: Vector2i
) -> Enemy:
	_stale_enemy_net_ids.clear()
	var nearest: Enemy = null
	var nearest_distance := INF
	var nearest_instance_id := 0
	var radius_squared := radius * radius
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
	var safe_bucket_size := _get_safe_bucket_size()
	var center_bucket_minimum := Vector2(center_cell) * safe_bucket_size
	var center_bucket_maximum := (
		center_bucket_minimum + Vector2.ONE * safe_bucket_size
	)
	# Visit the center bucket first, then square rings. Once a target is known,
	# a whole later ring that is strictly farther than the radius or known nearest
	# cannot improve the exact distance/id result and terminates the traversal.
	for ring in range(maximum_ring + 1):
		if ring > 0:
			var ring_offset := float(ring - 1) * safe_bucket_size
			var left_distance := (
				center.x - center_bucket_minimum.x + ring_offset
			)
			var right_distance := (
				center_bucket_maximum.x - center.x + ring_offset
			)
			var top_distance := (
				center.y - center_bucket_minimum.y + ring_offset
			)
			var bottom_distance := (
				center_bucket_maximum.y - center.y + ring_offset
			)
			var ring_minimum_distance := minf(
				minf(
					left_distance * left_distance,
					right_distance * right_distance
				),
				minf(
					top_distance * top_distance,
					bottom_distance * bottom_distance
				)
			)
			var cutoff_distance := radius_squared
			if nearest != null:
				cutoff_distance = nearest_distance
			if ring_minimum_distance > cutoff_distance:
				break
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
				var cell_minimum_distance := _distance_squared_to_bucket(center, cell)
				if cell_minimum_distance > radius_squared:
					continue
				if (
					nearest != null
					and cell_minimum_distance > nearest_distance
				):
					continue
				var cell_nearest := _find_nearest_alive_in_bucket(
					cell,
					center,
					radius_squared,
					excluded_instance_ids
				)
				if cell_nearest == null:
					continue
				var distance := center.distance_squared_to(cell_nearest.global_position)
				var instance_id := cell_nearest.get_instance_id()
				if (
					nearest == null
					or distance < nearest_distance
					or (
						distance == nearest_distance
						and instance_id < nearest_instance_id
					)
				):
					nearest = cell_nearest
					nearest_distance = distance
					nearest_instance_id = instance_id
	for net_id in _stale_enemy_net_ids:
		_remove_enemy_entry(net_id)
	return nearest


func _find_nearest_alive_flat(
	center: Vector2,
	radius: float,
	excluded_instance_ids: Dictionary,
	minimum_cell: Vector2i = Vector2i.MAX,
	maximum_cell: Vector2i = Vector2i.MAX
) -> Enemy:
	_stale_enemy_net_ids.clear()
	if minimum_cell == Vector2i.MAX or maximum_cell == Vector2i.MAX:
		minimum_cell = _to_bucket(center - Vector2.ONE * radius)
		maximum_cell = _to_bucket(center + Vector2.ONE * radius)
	var nearest: Enemy = null
	var nearest_distance := INF
	var nearest_instance_id := 0
	var radius_squared := radius * radius
	for cell_y in range(minimum_cell.y, maximum_cell.y + 1):
		for cell_x in range(minimum_cell.x, maximum_cell.x + 1):
			var cell := Vector2i(cell_x, cell_y)
			if not buckets.has(cell):
				continue
			var bucket := buckets[cell] as Array
			for net_id_variant in bucket:
				var net_id := int(net_id_variant)
				var enemy_variant: Variant = enemies_by_net_id.get(net_id)
				if enemy_variant == null or not is_instance_valid(enemy_variant):
					_stale_enemy_net_ids.append(net_id)
					continue
				var enemy := enemy_variant as Enemy
				if not is_enemy_queryable(enemy):
					_stale_enemy_net_ids.append(net_id)
					continue
				var instance_id := enemy.get_instance_id()
				if excluded_instance_ids.has(instance_id):
					continue
				var distance := center.distance_squared_to(enemy.global_position)
				if distance > radius_squared:
					continue
				if (
					nearest == null
					or distance < nearest_distance
					or (
						distance == nearest_distance
						and instance_id < nearest_instance_id
					)
				):
					nearest = enemy
					nearest_distance = distance
					nearest_instance_id = instance_id
	for net_id in _stale_enemy_net_ids:
		_remove_enemy_entry(net_id)
	return nearest


func _count_bucket_memberships_until(
	minimum_cell: Vector2i,
	maximum_cell: Vector2i,
	stop_after: int
) -> int:
	var membership_count := 0
	for cell_y in range(minimum_cell.y, maximum_cell.y + 1):
		for cell_x in range(minimum_cell.x, maximum_cell.x + 1):
			var cell := Vector2i(cell_x, cell_y)
			if not buckets.has(cell):
				continue
			membership_count += (buckets[cell] as Array).size()
			if membership_count > stop_after:
				return membership_count
	return membership_count


func _find_nearest_alive_in_bucket(
	cell: Vector2i,
	center: Vector2,
	radius_squared: float,
	excluded_instance_ids: Dictionary
) -> Enemy:
	if not buckets.has(cell):
		return null
	var nearest: Enemy = null
	var nearest_distance := INF
	var nearest_instance_id := 0
	var bucket := buckets[cell] as Array
	for net_id_variant in bucket:
		var net_id := int(net_id_variant)
		var enemy_variant: Variant = enemies_by_net_id.get(net_id)
		if enemy_variant == null or not is_instance_valid(enemy_variant):
			_stale_enemy_net_ids.append(net_id)
			continue
		var enemy := enemy_variant as Enemy
		if not is_enemy_queryable(enemy):
			_stale_enemy_net_ids.append(net_id)
			continue
		if excluded_instance_ids.has(enemy.get_instance_id()):
			continue
		var distance := center.distance_squared_to(enemy.global_position)
		if distance > radius_squared:
			continue
		var instance_id := enemy.get_instance_id()
		if (
			nearest == null
			or distance < nearest_distance
			or (
				distance == nearest_distance
				and instance_id < nearest_instance_id
			)
		):
			nearest = enemy
			nearest_distance = distance
			nearest_instance_id = instance_id
	return nearest


func _distance_squared_to_bucket(center: Vector2, cell: Vector2i) -> float:
	var safe_bucket_size := _get_safe_bucket_size()
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
	var faction_id := int(
		faction_by_net_id.get(net_id, COMBAT_RELATIONS.HOSTILE_WAVE)
	)
	_add_net_id_to_faction_bucket(net_id, faction_id, cell)


func _remove_net_id_from_bucket(net_id: int) -> void:
	if not bucket_by_net_id.has(net_id):
		return
	var cell: Vector2i = bucket_by_net_id[net_id]
	var slot := int(bucket_slot_by_net_id[net_id])
	var faction_id := int(
		faction_by_net_id.get(net_id, COMBAT_RELATIONS.HOSTILE_WAVE)
	)
	_remove_net_id_from_faction_bucket(net_id, faction_id, cell)
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


func _add_net_id_to_faction_bucket(
	net_id: int,
	faction_id: int,
	cell: Vector2i
) -> void:
	var faction_cells: Dictionary = faction_buckets.get(faction_id, {})
	if faction_cells.has(cell):
		var bucket := faction_cells[cell] as Array
		faction_bucket_slot_by_net_id[net_id] = bucket.size()
		bucket.append(net_id)
	else:
		faction_cells[cell] = [net_id]
		faction_bucket_slot_by_net_id[net_id] = 0
	faction_buckets[faction_id] = faction_cells


func _remove_net_id_from_faction_bucket(
	net_id: int,
	faction_id: int,
	cell: Vector2i
) -> void:
	if not faction_bucket_slot_by_net_id.has(net_id):
		return
	var faction_cells_variant: Variant = faction_buckets.get(faction_id)
	if faction_cells_variant == null:
		faction_bucket_slot_by_net_id.erase(net_id)
		return
	var faction_cells := faction_cells_variant as Dictionary
	if not faction_cells.has(cell):
		faction_bucket_slot_by_net_id.erase(net_id)
		return
	var bucket := faction_cells[cell] as Array
	var slot := int(faction_bucket_slot_by_net_id[net_id])
	var last_slot := bucket.size() - 1
	faction_bucket_slot_by_net_id.erase(net_id)
	if slot < 0 or slot > last_slot:
		return
	if slot != last_slot:
		var moved_net_id := int(bucket[last_slot])
		bucket[slot] = moved_net_id
		faction_bucket_slot_by_net_id[moved_net_id] = slot
	bucket.pop_back()
	if bucket.is_empty():
		faction_cells.erase(cell)
	if faction_cells.is_empty():
		faction_buckets.erase(faction_id)
	else:
		faction_buckets[faction_id] = faction_cells


func _remove_enemy_entry(net_id: int) -> void:
	var enemy_variant: Variant = enemies_by_net_id.get(net_id)
	if enemy_variant != null and is_instance_valid(enemy_variant):
		var enemy := enemy_variant as Enemy
		if enemy != null:
			enemy.unbind_combat_target_index(self, net_id)
	_remove_net_id_from_bucket(net_id)
	_remove_net_id_from_safety_audit(net_id)
	faction_by_net_id.erase(net_id)
	faction_bucket_slot_by_net_id.erase(net_id)
	enemies_by_net_id.erase(net_id)


func _add_net_id_to_safety_audit(net_id: int) -> void:
	if safety_audit_slot_by_net_id.has(net_id):
		return
	safety_audit_slot_by_net_id[net_id] = safety_audit_net_ids.size()
	safety_audit_net_ids.append(net_id)


func _remove_net_id_from_safety_audit(net_id: int) -> void:
	if not safety_audit_slot_by_net_id.has(net_id):
		return
	var slot := int(safety_audit_slot_by_net_id[net_id])
	var last_slot := safety_audit_net_ids.size() - 1
	safety_audit_slot_by_net_id.erase(net_id)
	if slot != last_slot:
		var moved_net_id := safety_audit_net_ids[last_slot]
		safety_audit_net_ids[slot] = moved_net_id
		safety_audit_slot_by_net_id[moved_net_id] = slot
	safety_audit_net_ids.pop_back()
	# Revisit the swap-filled slot instead of skipping it until the next complete
	# cycle. This can repeat a few checks during mass removals, but the hard slice
	# cap remains unchanged.
	safety_audit_cursor = mini(safety_audit_cursor, slot)
	if safety_audit_cursor >= safety_audit_net_ids.size():
		safety_audit_cursor = 0


func _sort_by_distance(result: Array[Enemy], center: Vector2) -> void:
	sort_candidates_by_distance(result, center)


func _limit_result(result: Array[Enemy], max_count: int) -> void:
	if max_count > 0 and result.size() > max_count:
		result.resize(max_count)


func _to_bucket(world_position: Vector2) -> Vector2i:
	var safe_bucket_size := _get_safe_bucket_size()
	return Vector2i(
		floori(world_position.x / safe_bucket_size),
		floori(world_position.y / safe_bucket_size)
	)


func _should_scan_radius_registry(minimum: Vector2, maximum: Vector2) -> bool:
	if (
		not minimum.is_finite()
		or not maximum.is_finite()
		or not _can_convert_to_bucket(minimum)
		or not _can_convert_to_bucket(maximum)
	):
		return true
	var minimum_cell := _to_bucket(minimum)
	var maximum_cell := _to_bucket(maximum)
	var bucket_columns := int(maximum_cell.x) - int(minimum_cell.x) + 1
	var bucket_rows := int(maximum_cell.y) - int(minimum_cell.y) + 1
	var registered_count := enemies_by_net_id.size()
	if bucket_columns <= 0 or bucket_rows <= 0 or registered_count <= 0:
		return true
	# Avoid multiplying the dimensions: the quotient comparison is exact and
	# cannot overflow even for finite bounds near Vector2i's representable edge.
	return (
		bucket_columns >= registered_count
		or bucket_rows > registered_count / bucket_columns
	)


func _can_convert_to_bucket(world_position: Vector2) -> bool:
	var safe_bucket_size := _get_safe_bucket_size()
	var scaled_x := float(world_position.x) / safe_bucket_size
	var scaled_y := float(world_position.y) / safe_bucket_size
	return (
		is_finite(scaled_x)
		and is_finite(scaled_y)
		and scaled_x >= MIN_VECTOR2I_COMPONENT
		and scaled_x < MAX_VECTOR2I_COMPONENT_EXCLUSIVE
		and scaled_y >= MIN_VECTOR2I_COMPONENT
		and scaled_y < MAX_VECTOR2I_COMPONENT_EXCLUSIVE
	)


func _get_safe_bucket_size() -> float:
	if not is_finite(bucket_size):
		return DEFAULT_BUCKET_SIZE
	return maxf(bucket_size, 1.0)
