extends Node
class_name BambooMortarCombatSystem

const TARGET_CACHE_CELL_SIZE := 64.0
const TARGET_CACHE_CELL_HALF_DIAGONAL := (
	TARGET_CACHE_CELL_SIZE * 0.70710678118
)
const EXPLOSION_GRID_CELL_SIZE := 32.0
const EXPLOSION_GRID_BATCH_THRESHOLD := 4
# Exact landing positions inside one small cell may share a conservative
# distance envelope. This is broad-phase only: enemies near either damage
# boundary are still tested against every original landing position.
const EXPLOSION_EXACT_CLUSTER_CELL_SIZE := 2.0

@export_range(1, 64, 1) var target_requests_per_physics_frame := 12
# 100座合法10×10布局通常在约3ms内即可处理12个请求。保留6ms硬上限，
# 既能在9个物理帧内排空100座同步索敌，也给60 FPS主帧留出大部分预算。
@export_range(100, 10000, 50, "or_greater") var target_budget_usec := 6000

var _combat_runtime: CombatRuntimeBase = null
var _tower_multiplayer_mode_adapter: TowerPlantGameplayPort = null
var _authoritative_processing_enabled := false
var research_concussion_move_speed_multiplier := 1.0
var research_concussion_duration_seconds := 0.0

var _pending_target_owner_ids: Array[int] = []
var _pending_target_requests: Dictionary[int, Dictionary] = {}
var _pending_target_cursor := 0
var _target_candidate_cache: Dictionary[Vector3i, Array] = {}
var _target_result_cache: Dictionary = {}

var _pending_explosions: Array[Dictionary] = []
var target_requests_enqueued_total := 0
var target_requests_deduplicated_total := 0
var target_requests_resolved_total := 0
var target_candidate_cache_hits_total := 0
var target_candidate_cache_misses_total := 0
var target_result_cache_hits_total := 0
var target_result_cache_misses_total := 0
var target_queue_peak := 0
var target_processing_peak_usec := 0
var explosion_requests_total := 0
var explosion_groups_total := 0
var explosion_request_merges_total := 0
var explosion_enemy_grid_builds_total := 0
var explosion_index_queries_total := 0
var explosion_logical_hits_total := 0
var explosion_enemy_batch_calls_total := 0
var explosion_processing_peak_usec := 0
var last_target_processing_usec := 0
var last_explosion_processing_usec := 0


func setup(
	combat_runtime: CombatRuntimeBase,
	mode_adapter: TowerPlantGameplayPort
) -> void:
	_combat_runtime = combat_runtime
	_tower_multiplayer_mode_adapter = mode_adapter


## Receives the Coordinator's absolute research projection. Values that do not
## describe an actual slow disable the upgrade instead of leaving partial state.
func set_research_concussion_effect(
	move_speed_multiplier: float,
	duration_seconds: float
) -> void:
	if (
		not is_finite(move_speed_multiplier)
		or not is_finite(duration_seconds)
		or move_speed_multiplier < 0.0
		or move_speed_multiplier >= 1.0
		or duration_seconds <= 0.0
	):
		research_concussion_move_speed_multiplier = 1.0
		research_concussion_duration_seconds = 0.0
		return
	research_concussion_move_speed_multiplier = move_speed_multiplier
	research_concussion_duration_seconds = duration_seconds


func get_research_concussion_move_speed_multiplier() -> float:
	return research_concussion_move_speed_multiplier


func get_research_concussion_duration_seconds() -> float:
	return research_concussion_duration_seconds


func set_authoritative_processing_enabled(enabled: bool) -> void:
	_authoritative_processing_enabled = enabled
	set_physics_process(enabled)
	if enabled:
		return
	_resolve_pending_target_requests_as_cancelled()
	_pending_target_owner_ids.clear()
	_pending_target_requests.clear()
	_pending_target_cursor = 0
	_target_candidate_cache.clear()
	_target_result_cache.clear()
	_pending_explosions.clear()


func _resolve_pending_target_requests_as_cancelled() -> void:
	for request_variant in _pending_target_requests.values():
		var request := request_variant as Dictionary
		var callback := request.get("callback") as Callable
		if callback.is_valid():
			callback.call(null)


func request_target(
	owner: Node2D,
	minimum_range: float,
	maximum_range: float,
	callback: Callable
) -> bool:
	if (
		not _authoritative_processing_enabled
		or owner == null
		or not is_instance_valid(owner)
		or not callback.is_valid()
	):
		return false
	var safe_maximum_range := maxf(maximum_range, 0.0)
	var safe_minimum_range := clampf(
		minimum_range,
		0.0,
		safe_maximum_range
	)
	var owner_id := owner.get_instance_id()
	var request := {
		"owner": weakref(owner),
		"minimum_range": safe_minimum_range,
		"maximum_range": safe_maximum_range,
		"callback": callback,
	}
	if _pending_target_requests.has(owner_id):
		_pending_target_requests[owner_id] = request
		target_requests_deduplicated_total += 1
		return true
	_pending_target_requests[owner_id] = request
	_pending_target_owner_ids.append(owner_id)
	target_requests_enqueued_total += 1
	target_queue_peak = maxi(
		target_queue_peak,
		_pending_target_requests.size()
	)
	return true


func cancel_target_request(owner: Node) -> void:
	if owner == null or not is_instance_valid(owner):
		return
	_pending_target_requests.erase(owner.get_instance_id())


func select_target_sync_for_fixture(
	center: Vector2,
	minimum_range: float,
	maximum_range: float
) -> Enemy:
	if not _has_query_runtime():
		return null
	var candidates: Array[Enemy] = []
	_combat_runtime.query_combat_targets_unordered_into(
		center,
		maxf(maximum_range, 0.0),
		candidates
	)
	return _select_nearest_target_exact(
		center,
		minimum_range,
		maximum_range,
		candidates
	)


func queue_explosion(
	landing_position: Vector2,
	inner_radius: float,
	outer_radius: float,
	inner_damage: int,
	outer_damage: int,
	damage_source_id: int
) -> bool:
	if (
		not _authoritative_processing_enabled
		or not landing_position.is_finite()
		or outer_radius <= 0.0
		or (inner_damage <= 0 and outer_damage <= 0)
	):
		return false
	_pending_explosions.append(
		{
			"position": landing_position,
			"inner_radius": clampf(inner_radius, 0.0, outer_radius),
			"outer_radius": maxf(outer_radius, 0.0),
			"inner_damage": maxi(inner_damage, 0),
			"outer_damage": maxi(outer_damage, 0),
			"damage_source_id": maxi(damage_source_id, 0),
		}
	)
	explosion_requests_total += 1
	return true


func get_metrics_snapshot() -> Dictionary:
	return {
		"pending_target_requests": _pending_target_requests.size(),
		"pending_explosions": _pending_explosions.size(),
		"target_requests_enqueued_total": target_requests_enqueued_total,
		"target_requests_deduplicated_total": (
			target_requests_deduplicated_total
		),
		"target_requests_resolved_total": target_requests_resolved_total,
		"target_candidate_cache_hits_total": (
			target_candidate_cache_hits_total
		),
		"target_candidate_cache_misses_total": (
			target_candidate_cache_misses_total
		),
		"target_result_cache_hits_total": (
			target_result_cache_hits_total
		),
		"target_result_cache_misses_total": (
			target_result_cache_misses_total
		),
		"target_queue_peak": target_queue_peak,
		"target_processing_peak_usec": target_processing_peak_usec,
		"last_target_processing_usec": last_target_processing_usec,
		"explosion_requests_total": explosion_requests_total,
		"explosion_groups_total": explosion_groups_total,
		"explosion_request_merges_total": (
			explosion_request_merges_total
		),
		"explosion_enemy_grid_builds_total": (
			explosion_enemy_grid_builds_total
		),
		"explosion_index_queries_total": explosion_index_queries_total,
		"explosion_logical_hits_total": explosion_logical_hits_total,
		"explosion_enemy_batch_calls_total": (
			explosion_enemy_batch_calls_total
		),
		"explosion_processing_peak_usec": explosion_processing_peak_usec,
		"last_explosion_processing_usec": last_explosion_processing_usec,
	}


func _ready() -> void:
	set_physics_process(_authoritative_processing_enabled)


func _physics_process(_delta: float) -> void:
	if not _authoritative_processing_enabled:
		return
	_process_target_requests()
	_process_explosion_batch()


func _process_target_requests() -> void:
	if _pending_target_cursor >= _pending_target_owner_ids.size():
		_compact_target_queue()
		return
	var started_usec := Time.get_ticks_usec()
	var dequeued_count := 0
	var scanned_count := 0
	_target_candidate_cache.clear()
	_target_result_cache.clear()
	while (
		_pending_target_cursor < _pending_target_owner_ids.size()
		and dequeued_count < target_requests_per_physics_frame
	):
		if (
			scanned_count > 0
			and Time.get_ticks_usec() - started_usec >= target_budget_usec
		):
			break
		var owner_id := _pending_target_owner_ids[_pending_target_cursor]
		_pending_target_cursor += 1
		scanned_count += 1
		if not _pending_target_requests.has(owner_id):
			continue
		dequeued_count += 1
		var request := _pending_target_requests[owner_id] as Dictionary
		_pending_target_requests.erase(owner_id)
		var owner_reference := request.get("owner") as WeakRef
		var owner := (
			owner_reference.get_ref() as Node2D
			if owner_reference != null
			else null
		)
		if (
			owner == null
			or not is_instance_valid(owner)
			or not owner.is_inside_tree()
		):
			continue
		var callback := request.get("callback") as Callable
		if not callback.is_valid():
			continue
		var minimum_range := float(request.get("minimum_range", 0.0))
		var maximum_range := float(request.get("maximum_range", 0.0))
		var owner_position := owner.global_position
		var exact_cache_key := Vector4(
			owner_position.x,
			owner_position.y,
			minimum_range,
			maximum_range
		)
		var target: Enemy = null
		if _target_result_cache.has(exact_cache_key):
			target_result_cache_hits_total += 1
			target = _target_result_cache.get(exact_cache_key) as Enemy
		else:
			var candidates := _get_cached_target_candidates(
				owner_position,
				maximum_range
			)
			target = _select_nearest_target_exact(
				owner_position,
				minimum_range,
				maximum_range,
				candidates
			)
			_target_result_cache[exact_cache_key] = target
			target_result_cache_misses_total += 1
		target_requests_resolved_total += 1
		callback.call(target)
	last_target_processing_usec = int(
		Time.get_ticks_usec() - started_usec
	)
	target_processing_peak_usec = maxi(
		target_processing_peak_usec,
		last_target_processing_usec
	)
	_compact_target_queue()


func _compact_target_queue() -> void:
	if _pending_target_cursor <= 0:
		return
	if _pending_target_cursor >= _pending_target_owner_ids.size():
		_pending_target_owner_ids.clear()
	else:
		_pending_target_owner_ids = _pending_target_owner_ids.slice(
			_pending_target_cursor
		)
	_pending_target_cursor = 0


func _get_cached_target_candidates(
	center: Vector2,
	maximum_range: float
) -> Array[Enemy]:
	if not _has_query_runtime():
		return []
	var center_cell := _to_cell(center, TARGET_CACHE_CELL_SIZE)
	var radius_bucket := maxi(
		ceili(maxf(maximum_range, 0.0) / TARGET_CACHE_CELL_SIZE),
		1
	)
	var cache_key := Vector3i(
		center_cell.x,
		center_cell.y,
		radius_bucket
	)
	if _target_candidate_cache.has(cache_key):
		target_candidate_cache_hits_total += 1
		return _target_candidate_cache[cache_key] as Array[Enemy]
	var query_center := (
		Vector2(center_cell) + Vector2(0.5, 0.5)
	) * TARGET_CACHE_CELL_SIZE
	var query_radius := (
		float(radius_bucket) * TARGET_CACHE_CELL_SIZE
		+ TARGET_CACHE_CELL_HALF_DIAGONAL
		+ 0.001
	)
	var candidates: Array[Enemy] = []
	_combat_runtime.query_combat_targets_unordered_into(
		query_center,
		query_radius,
		candidates
	)
	_target_candidate_cache[cache_key] = candidates
	target_candidate_cache_misses_total += 1
	return candidates


func _select_nearest_target_exact(
	center: Vector2,
	minimum_range: float,
	maximum_range: float,
	candidates: Array[Enemy]
) -> Enemy:
	var safe_maximum_range := maxf(maximum_range, 0.0)
	var safe_minimum_range := clampf(
		minimum_range,
		0.0,
		safe_maximum_range
	)
	var minimum_distance_squared := (
		safe_minimum_range * safe_minimum_range
	)
	var maximum_distance_squared := (
		safe_maximum_range * safe_maximum_range
	)
	var nearest: Enemy = null
	var nearest_distance_squared := INF
	var nearest_instance_id := 0
	for candidate in candidates:
		if (
			candidate == null
			or not is_instance_valid(candidate)
			or not candidate.is_inside_tree()
			or candidate.is_dead
		):
			continue
		var distance_squared := center.distance_squared_to(
			candidate.global_position
		)
		if (
			distance_squared <= minimum_distance_squared
			or distance_squared > maximum_distance_squared
		):
			continue
		var candidate_instance_id := candidate.get_instance_id()
		if (
			nearest == null
			or distance_squared < nearest_distance_squared
			or (
				is_equal_approx(
					distance_squared,
					nearest_distance_squared
				)
				and candidate_instance_id < nearest_instance_id
			)
		):
			nearest = candidate
			nearest_distance_squared = distance_squared
			nearest_instance_id = candidate_instance_id
	return nearest


func _process_explosion_batch() -> void:
	if _pending_explosions.is_empty():
		return
	var started_usec := Time.get_ticks_usec()
	var requests := _pending_explosions
	_pending_explosions = []
	var dense_batch := requests.size() >= EXPLOSION_GRID_BATCH_THRESHOLD
	var groups := _group_explosions_by_exact_position(requests)
	explosion_groups_total += groups.size()
	explosion_request_merges_total += requests.size() - groups.size()
	if dense_batch and groups.size() == 1:
		_apply_single_dense_group_exact(groups[0])
		last_explosion_processing_usec = int(
			Time.get_ticks_usec() - started_usec
		)
		explosion_processing_peak_usec = maxi(
			explosion_processing_peak_usec,
			last_explosion_processing_usec
		)
		return
	var accumulated_hits: Dictionary[int, Dictionary] = {}
	if dense_batch:
		var profiles := _group_landing_groups_by_profile(groups)
		if (
			profiles.size() == 1
			and _try_apply_single_cluster_profile_exact(profiles[0])
		):
			last_explosion_processing_usec = int(
				Time.get_ticks_usec() - started_usec
			)
			explosion_processing_peak_usec = maxi(
				explosion_processing_peak_usec,
				last_explosion_processing_usec
			)
			return
		var direct_single_profile := profiles.size() == 1
		var enemy_index := _build_temporary_enemy_index(
			direct_single_profile and groups.size() >= 64
		)
		var indexed_enemies := (
			enemy_index.get("enemies", []) as Array[Enemy]
		)
		var indexed_positions := (
			enemy_index.get(
				"positions",
				PackedVector2Array()
			) as PackedVector2Array
		)
		var enemy_grid := enemy_index.get("grid", {}) as Dictionary
		var position_members := (
			enemy_index.get("position_members", []) as Array
		)
		var position_multiplicities := (
			enemy_index.get(
				"position_multiplicities",
				PackedInt32Array()
			) as PackedInt32Array
		)
		for profile in profiles:
			_accumulate_profile_hits(
				profile,
				indexed_enemies,
				indexed_positions,
				enemy_grid,
				position_members,
				position_multiplicities,
				accumulated_hits,
				direct_single_profile
			)
	else:
		for group in groups:
			_accumulate_group_hits_from_shared_index(
				group,
				accumulated_hits
			)
	for enemy_id_variant in accumulated_hits:
		var enemy_id := int(enemy_id_variant)
		var source_records := accumulated_hits[enemy_id] as Dictionary
		for damage_source_id_variant in source_records:
			var hit_record := (
				source_records[damage_source_id_variant] as Dictionary
			)
			var enemy := hit_record.get("enemy") as Enemy
			if (
				enemy == null
				or not is_instance_valid(enemy)
				or not enemy.is_inside_tree()
				or enemy.is_dead
			):
				continue
			var direction_sum := hit_record.get(
				"direction_sum",
				Vector2.ZERO
			) as Vector2
			var impact_direction := (
				direction_sum.normalized()
				if direction_sum.length_squared() > 0.0001
				else Vector2.UP
			)
			_apply_enemy_damage_batch(
				int(damage_source_id_variant),
				enemy,
				hit_record.get("damage_amounts") as PackedInt64Array,
				hit_record.get("hit_counts") as PackedInt32Array,
				impact_direction
			)
			explosion_enemy_batch_calls_total += 1
	last_explosion_processing_usec = int(
		Time.get_ticks_usec() - started_usec
	)
	explosion_processing_peak_usec = maxi(
		explosion_processing_peak_usec,
		last_explosion_processing_usec
	)


func _apply_single_dense_group_exact(group: Dictionary) -> void:
	if not _has_query_runtime():
		return
	var position := group.get("position", Vector2.ZERO) as Vector2
	var inner_radius := maxf(
		float(group.get("inner_radius", 0.0)),
		0.0
	)
	var outer_radius := maxf(
		float(group.get("outer_radius", 0.0)),
		inner_radius
	)
	var inner_damage := maxi(int(group.get("inner_damage", 0)), 0)
	var outer_damage := maxi(int(group.get("outer_damage", 0)), 0)
	var hit_count := maxi(int(group.get("count", 1)), 1)
	var damage_source_id := maxi(int(group.get("damage_source_id", 0)), 0)
	var candidates: Array[Enemy] = []
	_combat_runtime.query_combat_targets_unordered_into(
		position,
		outer_radius,
		candidates
	)
	explosion_index_queries_total += 1
	var inner_radius_squared := inner_radius * inner_radius
	var outer_radius_squared := outer_radius * outer_radius
	var damage_amounts := PackedInt64Array()
	var inner_slot := -1
	var outer_slot := -1
	if inner_damage > 0:
		inner_slot = damage_amounts.size()
		damage_amounts.append(inner_damage)
	if outer_damage > 0:
		if outer_damage == inner_damage and inner_slot >= 0:
			outer_slot = inner_slot
		else:
			outer_slot = damage_amounts.size()
			damage_amounts.append(outer_damage)
	var shared_hit_counts := PackedInt32Array()
	shared_hit_counts.resize(damage_amounts.size())
	for enemy in candidates:
		if (
			enemy == null
			or not is_instance_valid(enemy)
			or not enemy.is_inside_tree()
			or enemy.is_dead
		):
			continue
		var direction_delta := enemy.global_position - position
		var distance_squared := direction_delta.length_squared()
		if distance_squared > outer_radius_squared:
			continue
		var damage_slot := (
			inner_slot
			if distance_squared <= inner_radius_squared
			else outer_slot
		)
		if damage_slot < 0:
			continue
		shared_hit_counts.fill(0)
		shared_hit_counts[damage_slot] = hit_count
		var impact_direction := (
			direction_delta.normalized()
			if direction_delta.length_squared() > 0.0001
			else Vector2.UP
		)
		_apply_enemy_damage_batch(
			damage_source_id,
			enemy,
			damage_amounts,
			shared_hit_counts,
			impact_direction
		)
		explosion_logical_hits_total += hit_count
		explosion_enemy_batch_calls_total += 1


func _try_apply_single_cluster_profile_exact(
	profile: Dictionary
) -> bool:
	if not _has_query_runtime():
		return false
	var landing_groups := (
		profile.get("groups", []) as Array[Dictionary]
	)
	var damage_source_id := maxi(int(profile.get("damage_source_id", 0)), 0)
	if landing_groups.size() <= 1:
		return false
	var landing_positions := PackedVector2Array()
	var landing_hit_counts := PackedInt32Array()
	landing_positions.resize(landing_groups.size())
	landing_hit_counts.resize(landing_groups.size())
	var total_hit_count := 0
	var weighted_position_sum := Vector2.ZERO
	var cluster_cell := Vector2i.ZERO
	for group_index in range(landing_groups.size()):
		var group := landing_groups[group_index]
		var position := group.get(
			"position",
			Vector2.ZERO
		) as Vector2
		var hit_count := maxi(int(group.get("count", 1)), 1)
		var current_cell := _to_exact_cluster_cell(
			position,
			EXPLOSION_EXACT_CLUSTER_CELL_SIZE
		)
		if group_index == 0:
			cluster_cell = current_cell
		elif current_cell != cluster_cell:
			return false
		landing_positions[group_index] = position
		landing_hit_counts[group_index] = hit_count
		total_hit_count += hit_count
		weighted_position_sum += position * float(hit_count)
	if total_hit_count <= 0:
		return true

	var cluster_center := (
		weighted_position_sum / float(total_hit_count)
	)
	var cluster_maximum_offset := 0.0
	for position in landing_positions:
		cluster_maximum_offset = maxf(
			cluster_maximum_offset,
			cluster_center.distance_to(position)
		)
	var inner_radius := maxf(
		float(profile.get("inner_radius", 0.0)),
		0.0
	)
	var outer_radius := maxf(
		float(profile.get("outer_radius", 0.0)),
		inner_radius
	)
	var inner_damage := maxi(
		int(profile.get("inner_damage", 0)),
		0
	)
	var outer_damage := maxi(
		int(profile.get("outer_damage", 0)),
		0
	)
	var candidates: Array[Enemy] = []
	_combat_runtime.query_combat_targets_unordered_into(
		cluster_center,
		outer_radius + cluster_maximum_offset,
		candidates
	)
	explosion_index_queries_total += 1

	var stable_inner_radius := inner_radius - cluster_maximum_offset
	var stable_outer_minimum_radius := (
		inner_radius + cluster_maximum_offset
	)
	var stable_outer_maximum_radius := (
		outer_radius - cluster_maximum_offset
	)
	var outside_minimum_radius := (
		outer_radius + cluster_maximum_offset
	)
	var stable_inner_radius_squared := (
		stable_inner_radius * stable_inner_radius
	)
	var stable_outer_minimum_radius_squared := (
		stable_outer_minimum_radius
		* stable_outer_minimum_radius
	)
	var stable_outer_maximum_radius_squared := (
		stable_outer_maximum_radius
		* stable_outer_maximum_radius
	)
	var outside_minimum_radius_squared := (
		outside_minimum_radius * outside_minimum_radius
	)
	var inner_radius_squared := inner_radius * inner_radius
	var outer_radius_squared := outer_radius * outer_radius
	var damage_amounts := PackedInt64Array()
	var inner_slot := -1
	var outer_slot := -1
	if inner_damage > 0:
		inner_slot = damage_amounts.size()
		damage_amounts.append(inner_damage)
	if outer_damage > 0:
		if outer_damage == inner_damage and inner_slot >= 0:
			outer_slot = inner_slot
		else:
			outer_slot = damage_amounts.size()
			damage_amounts.append(outer_damage)
	var shared_hit_counts := PackedInt32Array()
	shared_hit_counts.resize(damage_amounts.size())
	for enemy in candidates:
		if (
			enemy == null
			or not is_instance_valid(enemy)
			or not enemy.is_inside_tree()
			or enemy.is_dead
		):
			continue
		var enemy_position := enemy.global_position
		var center_delta := enemy_position - cluster_center
		var center_distance_squared := center_delta.length_squared()
		if center_distance_squared > outside_minimum_radius_squared:
			continue
		var inner_hit_count := 0
		var outer_hit_count := 0
		var direction_sum := Vector2.ZERO
		if (
			stable_inner_radius >= 0.0
			and center_distance_squared
			<= stable_inner_radius_squared
		):
			if inner_damage <= 0:
				continue
			inner_hit_count = total_hit_count
			direction_sum = (
				enemy_position * float(total_hit_count)
				- weighted_position_sum
			)
		elif (
			stable_outer_maximum_radius >= 0.0
			and center_distance_squared
			> stable_outer_minimum_radius_squared
			and center_distance_squared
			<= stable_outer_maximum_radius_squared
		):
			if outer_damage <= 0:
				continue
			outer_hit_count = total_hit_count
			direction_sum = (
				enemy_position * float(total_hit_count)
				- weighted_position_sum
			)
		else:
			for group_index in range(landing_positions.size()):
				var exact_delta := (
					enemy_position
					- landing_positions[group_index]
				)
				var exact_distance_squared := (
					exact_delta.length_squared()
				)
				if exact_distance_squared > outer_radius_squared:
					continue
				var exact_hit_count := landing_hit_counts[group_index]
				if exact_distance_squared <= inner_radius_squared:
					if inner_damage <= 0:
						continue
					inner_hit_count += exact_hit_count
				else:
					if outer_damage <= 0:
						continue
					outer_hit_count += exact_hit_count
				direction_sum += (
					exact_delta * float(exact_hit_count)
				)
		var logical_hit_count := (
			inner_hit_count + outer_hit_count
		)
		if logical_hit_count <= 0:
			continue
		shared_hit_counts.fill(0)
		if inner_slot >= 0:
			shared_hit_counts[inner_slot] += inner_hit_count
		if outer_slot >= 0:
			shared_hit_counts[outer_slot] += outer_hit_count
		var impact_direction := (
			direction_sum.normalized()
			if direction_sum.length_squared() > 0.0001
			else Vector2.UP
		)
		_apply_enemy_damage_batch(
			damage_source_id,
			enemy,
			damage_amounts,
			shared_hit_counts,
			impact_direction
		)
		explosion_logical_hits_total += logical_hit_count
		explosion_enemy_batch_calls_total += 1
	return true


func _group_explosions_by_exact_position(
	requests: Array[Dictionary]
) -> Array[Dictionary]:
	var groups: Array[Dictionary] = []
	var group_indices_by_position: Dictionary[Vector2, Array] = {}
	for request in requests:
		var position := request.get(
			"position",
			Vector2.ZERO
		) as Vector2
		var candidate_indices := (
			group_indices_by_position.get(position, []) as Array
		)
		var matched_group_index := -1
		for group_index_variant in candidate_indices:
			var group_index := int(group_index_variant)
			var group := groups[group_index]
			if _has_same_explosion_profile(group, request):
				matched_group_index = group_index
				break
		if matched_group_index >= 0:
			var matched_group := groups[matched_group_index]
			matched_group["count"] = int(
				matched_group.get("count", 1)
			) + 1
			continue
		var next_group := request.duplicate()
		next_group["position"] = position
		next_group["count"] = 1
		var next_group_index := groups.size()
		groups.append(next_group)
		candidate_indices.append(next_group_index)
		group_indices_by_position[position] = candidate_indices
	return groups


func _has_same_explosion_profile(
	a: Dictionary,
	b: Dictionary
) -> bool:
	return (
		is_equal_approx(
			float(a.get("inner_radius", 0.0)),
			float(b.get("inner_radius", 0.0))
		)
		and is_equal_approx(
			float(a.get("outer_radius", 0.0)),
			float(b.get("outer_radius", 0.0))
		)
		and int(a.get("inner_damage", 0))
		== int(b.get("inner_damage", 0))
		and int(a.get("outer_damage", 0))
		== int(b.get("outer_damage", 0))
		and int(a.get("damage_source_id", 0))
		== int(b.get("damage_source_id", 0))
	)


func _group_landing_groups_by_profile(
	groups: Array[Dictionary]
) -> Array[Dictionary]:
	var profiles: Array[Dictionary] = []
	for group in groups:
		var matched_profile: Dictionary = {}
		for profile in profiles:
			if _has_same_explosion_profile(profile, group):
				matched_profile = profile
				break
		if matched_profile.is_empty():
			matched_profile = {
				"inner_radius": group.get("inner_radius", 0.0),
				"outer_radius": group.get("outer_radius", 0.0),
				"inner_damage": group.get("inner_damage", 0),
				"outer_damage": group.get("outer_damage", 0),
				"damage_source_id": group.get("damage_source_id", 0),
				"groups": [] as Array[Dictionary],
			}
			profiles.append(matched_profile)
		var profile_groups := (
			matched_profile.get("groups") as Array[Dictionary]
		)
		profile_groups.append(group)
	return profiles


func _cluster_exact_landing_groups(
	landing_positions: PackedVector2Array,
	landing_hit_counts: PackedInt32Array
) -> Array[Dictionary]:
	if landing_positions.size() <= 1:
		return []
	var occupied_cells: Dictionary = {}
	var has_shared_cell := false
	for group_index in range(landing_positions.size()):
		var position := landing_positions[group_index]
		var cell := _to_exact_cluster_cell(
			position,
			EXPLOSION_EXACT_CLUSTER_CELL_SIZE
		)
		if occupied_cells.has(cell):
			has_shared_cell = true
			break
		occupied_cells[cell] = true
	if not has_shared_cell:
		return []

	var clusters: Array[Dictionary] = []
	var clusters_by_cell: Dictionary = {}
	for group_index in range(landing_positions.size()):
		var position := landing_positions[group_index]
		var hit_count := maxi(landing_hit_counts[group_index], 1)
		var cell := _to_exact_cluster_cell(
			position,
			EXPLOSION_EXACT_CLUSTER_CELL_SIZE
		)
		var cluster := (
			clusters_by_cell.get(cell, {}) as Dictionary
		)
		if cluster.is_empty():
			cluster = {
				"indices": PackedInt32Array(),
				"total_count": 0,
				"weighted_position_sum": Vector2.ZERO,
				"minimum_position": position,
				"maximum_position": position,
			}
			clusters_by_cell[cell] = cluster
			clusters.append(cluster)
		var cluster_indices := (
			cluster.get("indices") as PackedInt32Array
		)
		cluster_indices.append(group_index)
		cluster["indices"] = cluster_indices
		cluster["total_count"] = int(
			cluster.get("total_count", 0)
		) + hit_count
		cluster["weighted_position_sum"] = (
			cluster.get(
				"weighted_position_sum",
				Vector2.ZERO
			) as Vector2
		) + position * float(hit_count)
		var minimum_position := cluster.get(
			"minimum_position",
			position
		) as Vector2
		var maximum_position := cluster.get(
			"maximum_position",
			position
		) as Vector2
		cluster["minimum_position"] = Vector2(
			minf(minimum_position.x, position.x),
			minf(minimum_position.y, position.y)
		)
		cluster["maximum_position"] = Vector2(
			maxf(maximum_position.x, position.x),
			maxf(maximum_position.y, position.y)
		)
	for cluster in clusters:
		var total_count := maxi(
			int(cluster.get("total_count", 1)),
			1
		)
		var weighted_position_sum := cluster.get(
			"weighted_position_sum",
			Vector2.ZERO
		) as Vector2
		var center := weighted_position_sum / float(total_count)
		var maximum_offset := 0.0
		var cluster_indices := (
			cluster.get("indices") as PackedInt32Array
		)
		for group_index in cluster_indices:
			var position := landing_positions[group_index]
			maximum_offset = maxf(
				maximum_offset,
				center.distance_to(position)
			)
		cluster["center"] = center
		cluster["maximum_offset"] = maximum_offset
	return clusters


func _build_temporary_enemy_index(
	compress_exact_positions: bool = false
) -> Dictionary:
	var indexed_enemies: Array[Enemy] = []
	var indexed_positions := PackedVector2Array()
	if not _has_query_runtime():
		return {
			"grid": {},
			"enemies": indexed_enemies,
			"positions": indexed_positions,
			"position_members": [],
			"position_multiplicities": PackedInt32Array(),
		}
	var enemies := _combat_runtime.get_all_combat_targets()
	for enemy in enemies:
		if (
			enemy == null
			or not is_instance_valid(enemy)
			or not enemy.is_inside_tree()
			or enemy.is_dead
		):
			continue
		var enemy_index := indexed_enemies.size()
		indexed_enemies.append(enemy)
		indexed_positions.append(enemy.global_position)
	var position_members: Array = []
	if compress_exact_positions and indexed_positions.size() >= 4:
		var slot_by_position: Dictionary = {}
		var unique_positions := PackedVector2Array()
		var slot_by_enemy := PackedInt32Array()
		slot_by_enemy.resize(indexed_positions.size())
		for enemy_index in range(indexed_positions.size()):
			var position := indexed_positions[enemy_index]
			var slot_index := int(
				slot_by_position.get(position, -1)
			)
			if slot_index < 0:
				slot_index = unique_positions.size()
				slot_by_position[position] = slot_index
				unique_positions.append(position)
			slot_by_enemy[enemy_index] = slot_index
		# Only allocate per-position member lists after compression has proved
		# worthwhile. A normal formation with all unique coordinates therefore
		# avoids hundreds of throwaway PackedArrays.
		if (
			unique_positions.size() * 4
			<= indexed_positions.size() * 3
		):
			position_members.resize(unique_positions.size())
			for position_index in range(unique_positions.size()):
				position_members[position_index] = PackedInt32Array()
			for enemy_index in range(indexed_positions.size()):
				var slot_index := slot_by_enemy[enemy_index]
				var members := (
					position_members[slot_index]
					as PackedInt32Array
				)
				members.append(enemy_index)
				position_members[slot_index] = members
			indexed_positions = unique_positions
	var grid: Dictionary = {}
	for position_index in range(indexed_positions.size()):
		var cell := _to_cell(
			indexed_positions[position_index],
			EXPLOSION_GRID_CELL_SIZE
		)
		if grid.has(cell):
			var bucket := grid[cell] as PackedInt32Array
			bucket.append(position_index)
			grid[cell] = bucket
		else:
			grid[cell] = PackedInt32Array([position_index])
	var position_multiplicities := PackedInt32Array()
	position_multiplicities.resize(indexed_positions.size())
	if position_members.is_empty():
		position_multiplicities.fill(1)
	else:
		for position_index in range(position_members.size()):
			var members := (
				position_members[position_index]
				as PackedInt32Array
			)
			position_multiplicities[position_index] = members.size()
	explosion_enemy_grid_builds_total += 1
	return {
		"grid": grid,
		"enemies": indexed_enemies,
		"positions": indexed_positions,
		"position_members": position_members,
		"position_multiplicities": position_multiplicities,
	}


func _accumulate_profile_hits(
	profile: Dictionary,
	indexed_enemies: Array[Enemy],
	indexed_positions: PackedVector2Array,
	enemy_grid: Dictionary,
	position_members: Array,
	position_multiplicities: PackedInt32Array,
	accumulated_hits: Dictionary[int, Dictionary],
	apply_directly: bool
) -> void:
	var inner_radius := maxf(
		float(profile.get("inner_radius", 0.0)),
		0.0
	)
	var outer_radius := maxf(
		float(profile.get("outer_radius", 0.0)),
		inner_radius
	)
	var inner_radius_squared := inner_radius * inner_radius
	var outer_radius_squared := outer_radius * outer_radius
	var inner_damage := maxi(int(profile.get("inner_damage", 0)), 0)
	var outer_damage := maxi(int(profile.get("outer_damage", 0)), 0)
	var damage_source_id := maxi(int(profile.get("damage_source_id", 0)), 0)
	var position_count := indexed_positions.size()
	if position_count <= 0:
		return
	var inner_hit_counts := PackedInt32Array()
	var outer_hit_counts := PackedInt32Array()
	var direction_sums := PackedVector2Array()
	var touched_flags := PackedByteArray()
	inner_hit_counts.resize(position_count)
	outer_hit_counts.resize(position_count)
	direction_sums.resize(position_count)
	touched_flags.resize(position_count)
	var touched_indices := PackedInt32Array()
	var landing_groups := (
		profile.get("groups", []) as Array[Dictionary]
	)
	var landing_positions := PackedVector2Array()
	var landing_hit_counts := PackedInt32Array()
	landing_positions.resize(landing_groups.size())
	landing_hit_counts.resize(landing_groups.size())
	for group_index in range(landing_groups.size()):
		var group := landing_groups[group_index]
		landing_positions[group_index] = group.get(
			"position",
			Vector2.ZERO
		) as Vector2
		landing_hit_counts[group_index] = maxi(
			int(group.get("count", 1)),
			1
		)
	var landing_clusters := _cluster_exact_landing_groups(
		landing_positions,
		landing_hit_counts
	)
	if landing_clusters.is_empty():
		for group_index in range(landing_positions.size()):
			var exact_position := landing_positions[group_index]
			var exact_hit_count := landing_hit_counts[group_index]
			var minimum_cell := _to_cell(
				exact_position - Vector2.ONE * outer_radius,
				EXPLOSION_GRID_CELL_SIZE
			)
			var maximum_cell := _to_cell(
				exact_position + Vector2.ONE * outer_radius,
				EXPLOSION_GRID_CELL_SIZE
			)
			for cell_x in range(minimum_cell.x, maximum_cell.x + 1):
				for cell_y in range(
					minimum_cell.y,
					maximum_cell.y + 1
				):
					var cell := Vector2i(cell_x, cell_y)
					if not enemy_grid.has(cell):
						continue
					var bucket := (
						enemy_grid[cell] as PackedInt32Array
					)
					for enemy_index in bucket:
						var exact_direction_delta := (
							indexed_positions[enemy_index]
							- exact_position
						)
						var exact_distance_squared := (
							exact_direction_delta.length_squared()
						)
						if exact_distance_squared > outer_radius_squared:
							continue
						if exact_distance_squared <= inner_radius_squared:
							if inner_damage <= 0:
								continue
							inner_hit_counts[enemy_index] += exact_hit_count
						else:
							if outer_damage <= 0:
								continue
							outer_hit_counts[enemy_index] += exact_hit_count
						if touched_flags[enemy_index] == 0:
							touched_flags[enemy_index] = 1
							touched_indices.append(enemy_index)
						direction_sums[enemy_index] += (
							exact_direction_delta
							* float(exact_hit_count)
						)
						explosion_logical_hits_total += (
							exact_hit_count
							* position_multiplicities[enemy_index]
						)
	for cluster in landing_clusters:
		var cluster_indices := (
			cluster.get("indices") as PackedInt32Array
		)
		var singleton_group := cluster_indices.size() == 1
		var singleton_position := Vector2.ZERO
		var singleton_hit_count := 0
		if singleton_group:
			var only_group_index := cluster_indices[0]
			singleton_position = landing_positions[only_group_index]
			singleton_hit_count = landing_hit_counts[only_group_index]
		var cluster_center := cluster.get(
			"center",
			Vector2.ZERO
		) as Vector2
		var cluster_maximum_offset := maxf(
			float(cluster.get("maximum_offset", 0.0)),
			0.0
		)
		var cluster_total_count := maxi(
			int(cluster.get("total_count", 1)),
			1
		)
		var weighted_position_sum := cluster.get(
			"weighted_position_sum",
			Vector2.ZERO
		) as Vector2
		var minimum_position := cluster.get(
			"minimum_position",
			cluster_center
		) as Vector2
		var maximum_position := cluster.get(
			"maximum_position",
			cluster_center
		) as Vector2
		var minimum_cell := _to_cell(
			minimum_position - Vector2.ONE * outer_radius,
			EXPLOSION_GRID_CELL_SIZE
		)
		var maximum_cell := _to_cell(
			maximum_position + Vector2.ONE * outer_radius,
			EXPLOSION_GRID_CELL_SIZE
		)
		var stable_inner_radius := (
			inner_radius - cluster_maximum_offset
		)
		var stable_outer_minimum_radius := (
			inner_radius + cluster_maximum_offset
		)
		var stable_outer_maximum_radius := (
			outer_radius - cluster_maximum_offset
		)
		var outside_minimum_radius := (
			outer_radius + cluster_maximum_offset
		)
		var stable_inner_radius_squared := (
			stable_inner_radius * stable_inner_radius
		)
		var stable_outer_minimum_radius_squared := (
			stable_outer_minimum_radius
			* stable_outer_minimum_radius
		)
		var stable_outer_maximum_radius_squared := (
			stable_outer_maximum_radius
			* stable_outer_maximum_radius
		)
		var outside_minimum_radius_squared := (
			outside_minimum_radius * outside_minimum_radius
		)
		for cell_x in range(minimum_cell.x, maximum_cell.x + 1):
			for cell_y in range(
				minimum_cell.y,
				maximum_cell.y + 1
			):
				var cell := Vector2i(cell_x, cell_y)
				if not enemy_grid.has(cell):
					continue
				var bucket := (
					enemy_grid[cell] as PackedInt32Array
				)
				for enemy_index in bucket:
					if singleton_group:
						var exact_direction_delta := (
							indexed_positions[enemy_index]
							- singleton_position
						)
						var exact_distance_squared := (
							exact_direction_delta.length_squared()
						)
						if exact_distance_squared > outer_radius_squared:
							continue
						if exact_distance_squared <= inner_radius_squared:
							if inner_damage <= 0:
								continue
							inner_hit_counts[enemy_index] += (
								singleton_hit_count
							)
						else:
							if outer_damage <= 0:
								continue
							outer_hit_counts[enemy_index] += (
								singleton_hit_count
							)
						if touched_flags[enemy_index] == 0:
							touched_flags[enemy_index] = 1
							touched_indices.append(enemy_index)
						direction_sums[enemy_index] += (
							exact_direction_delta
							* float(singleton_hit_count)
						)
						explosion_logical_hits_total += (
							singleton_hit_count
							* position_multiplicities[enemy_index]
						)
						continue
					var direction_delta := (
						indexed_positions[enemy_index]
						- cluster_center
					)
					var center_distance_squared := (
						direction_delta.length_squared()
					)
					var stable_inner := (
						stable_inner_radius >= 0.0
						and center_distance_squared
						<= stable_inner_radius_squared
					)
					var stable_outer := (
						stable_outer_maximum_radius >= 0.0
						and center_distance_squared
						> stable_outer_minimum_radius_squared
						and center_distance_squared
						<= stable_outer_maximum_radius_squared
					)
					if (
						center_distance_squared
						> outside_minimum_radius_squared
					):
						continue
					if stable_inner:
						if inner_damage <= 0:
							continue
						inner_hit_counts[enemy_index] += (
							cluster_total_count
						)
					elif stable_outer:
						if outer_damage <= 0:
							continue
						outer_hit_counts[enemy_index] += (
							cluster_total_count
						)
					else:
						var exact_cluster_hit := false
						for group_index in cluster_indices:
							var exact_position := (
								landing_positions[group_index]
							)
							var exact_hit_count := (
								landing_hit_counts[group_index]
							)
							var exact_direction_delta := (
								indexed_positions[enemy_index]
								- exact_position
							)
							var exact_distance_squared := (
								exact_direction_delta.length_squared()
							)
							if (
								exact_distance_squared
								> outer_radius_squared
							):
								continue
							if (
								exact_distance_squared
								<= inner_radius_squared
							):
								if inner_damage <= 0:
									continue
								inner_hit_counts[enemy_index] += (
									exact_hit_count
								)
							else:
								if outer_damage <= 0:
									continue
								outer_hit_counts[enemy_index] += (
									exact_hit_count
								)
							direction_sums[enemy_index] += (
								exact_direction_delta
								* float(exact_hit_count)
							)
							explosion_logical_hits_total += (
								exact_hit_count
								* position_multiplicities[enemy_index]
							)
							exact_cluster_hit = true
						if exact_cluster_hit:
							if touched_flags[enemy_index] == 0:
								touched_flags[enemy_index] = 1
								touched_indices.append(enemy_index)
						continue
					if touched_flags[enemy_index] == 0:
						touched_flags[enemy_index] = 1
						touched_indices.append(enemy_index)
					direction_sums[enemy_index] += (
						indexed_positions[enemy_index]
						* float(cluster_total_count)
						- weighted_position_sum
					)
					explosion_logical_hits_total += (
						cluster_total_count
						* position_multiplicities[enemy_index]
					)
	if apply_directly:
		var damage_amounts := PackedInt64Array()
		var inner_slot := -1
		var outer_slot := -1
		if inner_damage > 0:
			inner_slot = damage_amounts.size()
			damage_amounts.append(inner_damage)
		if outer_damage > 0:
			if outer_damage == inner_damage and inner_slot >= 0:
				outer_slot = inner_slot
			else:
				outer_slot = damage_amounts.size()
				damage_amounts.append(outer_damage)
		var shared_hit_counts := PackedInt32Array()
		shared_hit_counts.resize(damage_amounts.size())
		for enemy_index in touched_indices:
			shared_hit_counts.fill(0)
			if inner_slot >= 0:
				shared_hit_counts[inner_slot] += (
					inner_hit_counts[enemy_index]
				)
			if outer_slot >= 0:
				shared_hit_counts[outer_slot] += (
					outer_hit_counts[enemy_index]
				)
			var direction_sum := direction_sums[enemy_index]
			var impact_direction := (
				direction_sum.normalized()
				if direction_sum.length_squared() > 0.0001
				else Vector2.UP
			)
			# 批伤入口同步消费PackedArray；复用同一缓冲避免为每名敌人分配
			# Dictionary和两组临时PackedArray。完全同坐标的敌人只共享
			# 几何结果，生命/防御仍逐个独立结算。
			if position_members.is_empty():
				_apply_enemy_damage_batch(
					damage_source_id,
					indexed_enemies[enemy_index],
					damage_amounts,
					shared_hit_counts,
					impact_direction
				)
				explosion_enemy_batch_calls_total += 1
			else:
				var members := (
					position_members[enemy_index]
					as PackedInt32Array
				)
				for member_index in members:
					_apply_enemy_damage_batch(
						damage_source_id,
						indexed_enemies[member_index],
						damage_amounts,
						shared_hit_counts,
						impact_direction
					)
					explosion_enemy_batch_calls_total += 1
		return
	for enemy_index in touched_indices:
		var inner_hit_count := inner_hit_counts[enemy_index]
		var outer_hit_count := outer_hit_counts[enemy_index]
		var direction_sum := direction_sums[enemy_index]
		var members := PackedInt32Array([enemy_index])
		if not position_members.is_empty():
			members = (
				position_members[enemy_index]
				as PackedInt32Array
			)
		for member_index in members:
			var member_direction_sum := direction_sum
			if inner_hit_count > 0:
				_append_accumulated_hit(
					accumulated_hits,
					indexed_enemies[member_index],
					damage_source_id,
					inner_damage,
					inner_hit_count,
					member_direction_sum
				)
				member_direction_sum = Vector2.ZERO
			if outer_hit_count > 0:
				_append_accumulated_hit(
					accumulated_hits,
					indexed_enemies[member_index],
					damage_source_id,
					outer_damage,
					outer_hit_count,
					member_direction_sum
				)


func _accumulate_group_hits_from_shared_index(
	group: Dictionary,
	accumulated_hits: Dictionary[int, Dictionary]
) -> void:
	if not _has_query_runtime():
		return
	var position := group.get("position", Vector2.ZERO) as Vector2
	var inner_radius := maxf(
		float(group.get("inner_radius", 0.0)),
		0.0
	)
	var outer_radius := maxf(
		float(group.get("outer_radius", 0.0)),
		inner_radius
	)
	var candidates: Array[Enemy] = []
	_combat_runtime.query_combat_targets_unordered_into(
		position,
		outer_radius,
		candidates
	)
	explosion_index_queries_total += 1
	var inner_radius_squared := inner_radius * inner_radius
	var outer_radius_squared := outer_radius * outer_radius
	var inner_damage := maxi(int(group.get("inner_damage", 0)), 0)
	var outer_damage := maxi(int(group.get("outer_damage", 0)), 0)
	var hit_count := maxi(int(group.get("count", 1)), 1)
	var damage_source_id := maxi(int(group.get("damage_source_id", 0)), 0)
	for enemy in candidates:
		_accumulate_enemy_hit(
			accumulated_hits,
			enemy,
			damage_source_id,
			position,
			inner_radius_squared,
			outer_radius_squared,
			inner_damage,
			outer_damage,
			hit_count
		)


func _accumulate_enemy_hit(
	accumulated_hits: Dictionary[int, Dictionary],
	enemy: Enemy,
	damage_source_id: int,
	position: Vector2,
	inner_radius_squared: float,
	outer_radius_squared: float,
	inner_damage: int,
	outer_damage: int,
	hit_count: int
) -> void:
	if (
		enemy == null
		or not is_instance_valid(enemy)
		or not enemy.is_inside_tree()
		or enemy.is_dead
	):
		return
	var direction_delta := enemy.global_position - position
	var distance_squared := direction_delta.length_squared()
	if distance_squared > outer_radius_squared:
		return
	var damage := (
		inner_damage
		if distance_squared <= inner_radius_squared
		else outer_damage
	)
	if damage <= 0:
		return
	explosion_logical_hits_total += hit_count
	_append_accumulated_hit(
		accumulated_hits,
		enemy,
		damage_source_id,
		damage,
		hit_count,
		direction_delta * float(hit_count)
	)


func _append_accumulated_hit(
	accumulated_hits: Dictionary[int, Dictionary],
	enemy: Enemy,
	damage_source_id: int,
	damage: int,
	hit_count: int,
	direction_contribution: Vector2
) -> void:
	var enemy_id := enemy.get_instance_id()
	var safe_damage_source_id := maxi(damage_source_id, 0)
	var source_records := accumulated_hits.get(enemy_id, {}) as Dictionary
	var record := source_records.get(safe_damage_source_id, {}) as Dictionary
	if record.is_empty():
		record = {
			"enemy": enemy,
			"damage_amounts": PackedInt64Array(),
			"hit_counts": PackedInt32Array(),
			"direction_sum": Vector2.ZERO,
		}
	var damage_amounts := (
		record.get("damage_amounts") as PackedInt64Array
	)
	var hit_counts := record.get("hit_counts") as PackedInt32Array
	var last_index := damage_amounts.size() - 1
	if last_index >= 0 and damage_amounts[last_index] == damage:
		hit_counts[last_index] += hit_count
	else:
		damage_amounts.append(damage)
		hit_counts.append(hit_count)
	record["damage_amounts"] = damage_amounts
	record["hit_counts"] = hit_counts
	record["direction_sum"] = (
		record.get("direction_sum", Vector2.ZERO) as Vector2
	) + direction_contribution
	source_records[safe_damage_source_id] = record
	accumulated_hits[enemy_id] = source_records


func _apply_enemy_damage_batch(
	damage_source_id: int,
	enemy: Enemy,
	damage_amounts: PackedInt64Array,
	hit_counts: PackedInt32Array,
	impact_direction: Vector2
) -> bool:
	if (
		_tower_multiplayer_mode_adapter == null
		or not is_instance_valid(_tower_multiplayer_mode_adapter)
	):
		return false
	var accepted := _tower_multiplayer_mode_adapter.apply_authoritative_plant_enemy_damage_batch(
		maxi(damage_source_id, 0),
		enemy,
		damage_amounts,
		hit_counts,
		impact_direction,
		EnemyConfig.DamageType.PHYSICAL
	)
	if (
		accepted
		and enemy != null
		and is_instance_valid(enemy)
		and not enemy.is_dead
		and research_concussion_duration_seconds > 0.0
		and research_concussion_move_speed_multiplier < 1.0
	):
		enemy.apply_bamboo_mortar_concussion(
			research_concussion_duration_seconds,
			research_concussion_move_speed_multiplier
		)
	return accepted


func _has_query_runtime() -> bool:
	return (
		_combat_runtime != null
		and is_instance_valid(_combat_runtime)
	)


func _to_cell(position: Vector2, cell_size: float) -> Vector2i:
	var safe_cell_size := maxf(cell_size, 1.0)
	return Vector2i(
		floori(position.x / safe_cell_size),
		floori(position.y / safe_cell_size)
	)


func _to_exact_cluster_cell(
	position: Vector2,
	cell_size: float
) -> Vector2i:
	# Exact landing clusters are only a broad-phase acceleration. Centering the
	# cells around integer multiples keeps tightly grouped sub-pixel volleys in
	# one cluster even when their common target lies on a floor-grid boundary.
	# Boundary-band members are still checked against every original position.
	var safe_cell_size := maxf(cell_size, 1.0)
	return Vector2i(
		roundi(position.x / safe_cell_size),
		roundi(position.y / safe_cell_size)
	)
