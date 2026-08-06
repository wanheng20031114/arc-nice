extends RefCounted
class_name CompleteShapeQuery2D

const DEFAULT_BATCH_SIZE := 64


## Returns every collider matched by a shape query instead of silently truncating
## at PhysicsDirectSpaceState2D.intersect_shape's max_results argument.
##
## Each full batch is excluded by collision-object RID before requesting the next
## batch. The no-progress guard makes the loop finite even if a physics backend
## ever returns an entry without a usable RID. The caller's original exclusions
## are restored before returning so a query object can be reused safely.
## When a Dictionary is supplied as `metrics`, it is replaced with deterministic
## paging counters plus an informational elapsed time for dense-wave diagnostics.
static func intersect_shape_all(
	space_state: PhysicsDirectSpaceState2D,
	query: PhysicsShapeQueryParameters2D,
	batch_size: int = DEFAULT_BATCH_SIZE,
	metrics: Variant = null
) -> Array[Dictionary]:
	var results: Array[Dictionary] = []
	var metrics_enabled := metrics is Dictionary
	var physics_query_count := 0
	var full_batch_count := 0
	var newly_excluded_count_total := 0
	var metrics_started_usec := Time.get_ticks_usec() if metrics_enabled else 0
	if space_state == null or query == null or query.shape == null:
		if metrics_enabled:
			_write_metrics(
				metrics,
				physics_query_count,
				full_batch_count,
				newly_excluded_count_total,
				results.size(),
				metrics_started_usec
			)
		return results

	var safe_batch_size := maxi(batch_size, 1)
	var original_exclusions: Array[RID] = query.exclude.duplicate()
	var paged_exclusions: Array[RID] = original_exclusions.duplicate()
	var excluded_rids: Dictionary = {}
	for excluded_rid in paged_exclusions:
		excluded_rids[excluded_rid] = true

	while true:
		query.exclude = paged_exclusions
		if metrics_enabled:
			physics_query_count += 1
		var batch := space_state.intersect_shape(query, safe_batch_size)
		if batch.is_empty():
			break
		results.append_array(batch)
		if metrics_enabled and batch.size() == safe_batch_size:
			full_batch_count += 1

		var newly_excluded_count := 0
		for result in batch:
			var collider_rid: RID = result.get("rid", RID())
			if not collider_rid.is_valid():
				var collision_object := result.get("collider") as CollisionObject2D
				if collision_object != null:
					collider_rid = collision_object.get_rid()
			if not collider_rid.is_valid() or excluded_rids.has(collider_rid):
				continue
			excluded_rids[collider_rid] = true
			paged_exclusions.append(collider_rid)
			newly_excluded_count += 1
		if metrics_enabled:
			newly_excluded_count_total += newly_excluded_count

		if batch.size() < safe_batch_size or newly_excluded_count == 0:
			break

	query.exclude = original_exclusions
	if metrics_enabled:
		_write_metrics(
			metrics,
			physics_query_count,
			full_batch_count,
			newly_excluded_count_total,
			results.size(),
			metrics_started_usec
		)
	return results


static func _write_metrics(
	metrics: Variant,
	physics_query_count: int,
	full_batch_count: int,
	newly_excluded_count: int,
	result_count: int,
	started_usec: int
) -> void:
	if not (metrics is Dictionary):
		return
	var output := metrics as Dictionary
	output.clear()
	output["physics_query_count"] = physics_query_count
	output["full_batch_count"] = full_batch_count
	output["newly_excluded_count"] = newly_excluded_count
	output["result_count"] = result_count
	output["elapsed_usec"] = maxi(Time.get_ticks_usec() - started_usec, 0)
