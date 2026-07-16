extends SceneTree

# Focused CPU comparison for the two minimap loops that appear in the Godot
# profiler. Each optimized path is measured against the former implementation
# with the same 192 x 108 projection and representative horde/topology counts.
const MINIMAP_SCENE := preload("res://scene/tower_defense_minimap.tscn")

const CANVAS_SIZE := Vector2(192.0, 108.0)
const WORLD_SIZE := Vector2(960.0, 540.0)
const WORLD_CENTER := WORLD_SIZE * 0.5
const ENEMY_COUNT := 600
const STATIC_CELL_COUNT := 580
const DYNAMIC_ITERATIONS := 160
const STATIC_ITERATIONS := 120
const SAMPLE_COUNT := 5
const DRAW_SAMPLE_COUNT := 17

var failures: Array[String] = []
var projection_sink := 0.0


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var minimap := MINIMAP_SCENE.instantiate() as TowerDefenseMinimap
	root.add_child(minimap)
	var dynamic_layer := minimap.minimap_canvas.dynamic_layer
	var static_layer := minimap.minimap_canvas.static_layer
	dynamic_layer.set_projection(WORLD_CENTER, WORLD_SIZE)
	static_layer.set_projection(WORLD_CENTER, WORLD_SIZE, WORLD_SIZE / 3.0)
	await process_frame
	_expect(
		dynamic_layer.size.is_equal_approx(CANVAS_SIZE)
		and static_layer.size.is_equal_approx(CANVAS_SIZE),
		"The A/B fixture must retain the authored 192 x 108 canvas size."
	)

	var enemy_positions := _build_enemy_positions()
	var static_positions := _build_static_positions()
	var overview_rect := Rect2(Vector2.ZERO, WORLD_SIZE)
	dynamic_layer.set_world_entities(
		PackedVector2Array(),
		enemy_positions,
		PackedVector2Array()
	)
	static_layer.set_topology(
		Vector2(16.0, 16.0),
		static_positions,
		PackedVector2Array(),
		PackedVector2Array(),
		PackedVector2Array()
	)
	# Warm both implementations before taking alternating samples.
	dynamic_layer._rebuild_enemy_canvas_bucket_counts(overview_rect, false)
	_legacy_rebuild_enemy_buckets(dynamic_layer, enemy_positions, overview_rect)
	_measure_cached_static_projection(static_layer, static_positions, 2)
	_measure_legacy_static_projection(static_layer, static_positions, 2)

	var packed_bucket_samples: Array[float] = []
	var synced_bucket_samples: Array[float] = []
	var dictionary_bucket_samples: Array[float] = []
	var cached_projection_samples: Array[float] = []
	var repeated_projection_samples: Array[float] = []
	for sample_index in range(SAMPLE_COUNT):
		if sample_index % 2 == 0:
			packed_bucket_samples.append(
				_measure_packed_enemy_buckets(dynamic_layer, overview_rect)
			)
			synced_bucket_samples.append(
				_measure_synced_enemy_buckets(dynamic_layer, overview_rect)
			)
			dictionary_bucket_samples.append(
				_measure_dictionary_enemy_buckets(
					dynamic_layer,
					enemy_positions,
					overview_rect
				)
			)
			cached_projection_samples.append(
				_measure_cached_static_projection(
					static_layer,
					static_positions,
					STATIC_ITERATIONS
				)
			)
			repeated_projection_samples.append(
				_measure_legacy_static_projection(
					static_layer,
					static_positions,
					STATIC_ITERATIONS
				)
			)
		else:
			dictionary_bucket_samples.append(
				_measure_dictionary_enemy_buckets(
					dynamic_layer,
					enemy_positions,
					overview_rect
				)
			)
			packed_bucket_samples.append(
				_measure_packed_enemy_buckets(dynamic_layer, overview_rect)
			)
			synced_bucket_samples.append(
				_measure_synced_enemy_buckets(dynamic_layer, overview_rect)
			)
			repeated_projection_samples.append(
				_measure_legacy_static_projection(
					static_layer,
					static_positions,
					STATIC_ITERATIONS
				)
			)
			cached_projection_samples.append(
				_measure_cached_static_projection(
					static_layer,
					static_positions,
					STATIC_ITERATIONS
				)
			)

	var packed_bucket_ms := _median(packed_bucket_samples)
	var synced_bucket_ms := _median(synced_bucket_samples)
	var dictionary_bucket_ms := _median(dictionary_bucket_samples)
	var cached_projection_ms := _median(cached_projection_samples)
	var repeated_projection_ms := _median(repeated_projection_samples)
	var dynamic_draw_samples := await _measure_interleaved_dynamic_draws(dynamic_layer)
	var static_draw_samples := await _measure_interleaved_static_draws(static_layer)
	var dynamic_batch_draw_usec := _median(dynamic_draw_samples["batch"])
	var dynamic_legacy_draw_usec := _median(dynamic_draw_samples["legacy"])
	var static_batch_draw_usec := _median(static_draw_samples["batch"])
	var static_legacy_draw_usec := _median(static_draw_samples["legacy"])
	var synced_bucket_usec_per_update := (
		synced_bucket_ms * 1000.0 / float(DYNAMIC_ITERATIONS)
	)
	var combined_batch_usec := synced_bucket_usec_per_update + dynamic_batch_draw_usec
	_expect(
		packed_bucket_ms < dictionary_bucket_ms,
		"Packed enemy buckets must beat the former Vector2i Dictionary hot path."
	)
	_expect(
		cached_projection_ms < repeated_projection_ms,
		"Cached static projection must beat recomputing projection constants per cell."
	)
	_expect(
		dynamic_batch_draw_usec < dynamic_legacy_draw_usec,
		"One enemy MultiMesh draw must beat one draw_circle command per touched bucket."
	)
	_expect(
		combined_batch_usec < dynamic_legacy_draw_usec,
		"Bucket upload plus one MultiMesh draw must beat the complete legacy draw path."
	)
	_expect(
		static_batch_draw_usec < static_legacy_draw_usec,
		"Four topology MultiMesh draws must beat one draw_rect command per static cell."
	)
	_expect(
		dynamic_layer._enemy_marker_bucket_indices.size()
		== dynamic_layer._touched_enemy_bucket_indices.size()
		and dynamic_layer.enemy_marker_multimesh.visible_instance_count
		== dynamic_layer._touched_enemy_bucket_indices.size(),
		"The dynamic A/B fixture must preserve one batched instance per touched bucket."
	)
	_expect(
		static_layer._wall_batch_world_positions == static_positions
		and static_layer.wall_multimesh.instance_count == static_positions.size(),
		"The static A/B fixture must preserve the exact legacy wall-cell signature."
	)
	_expect(
		dynamic_layer._enemy_canvas_bucket_counts.size() == 48 * 27,
		"The benchmark must exercise the production 48 x 27 packed bucket table."
	)
	print(
		(
			"TOWER_DEFENSE_MINIMAP_CPU_PROBE enemies=%d static_cells=%d "
			+ "packed_bucket_ms=%.3f synced_bucket_ms=%.3f "
			+ "dictionary_bucket_ms=%.3f bucket_speedup=%.2fx "
			+ "cached_projection_ms=%.3f repeated_projection_ms=%.3f "
			+ "projection_speedup=%.2fx dynamic_batch_draw_us=%.1f "
			+ "dynamic_legacy_draw_us=%.1f dynamic_draw_speedup=%.2fx "
			+ "dynamic_combined_batch_us=%.1f dynamic_combined_speedup=%.2fx "
			+ "static_batch_draw_us=%.1f static_legacy_draw_us=%.1f "
			+ "static_draw_speedup=%.2fx sink=%.1f"
		)
		% [
			ENEMY_COUNT,
			STATIC_CELL_COUNT,
			packed_bucket_ms,
			synced_bucket_ms,
			dictionary_bucket_ms,
			dictionary_bucket_ms / maxf(packed_bucket_ms, 0.001),
			cached_projection_ms,
			repeated_projection_ms,
			repeated_projection_ms / maxf(cached_projection_ms, 0.001),
			dynamic_batch_draw_usec,
			dynamic_legacy_draw_usec,
			dynamic_legacy_draw_usec / maxf(dynamic_batch_draw_usec, 0.001),
			combined_batch_usec,
			dynamic_legacy_draw_usec / maxf(combined_batch_usec, 0.001),
			static_batch_draw_usec,
			static_legacy_draw_usec,
			static_legacy_draw_usec / maxf(static_batch_draw_usec, 0.001),
			projection_sink,
		]
	)

	minimap.queue_free()
	await process_frame
	if failures.is_empty():
		print("TOWER_DEFENSE_MINIMAP_CPU_PERFORMANCE_PROBE_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _measure_interleaved_dynamic_draws(
	dynamic_layer: TowerDefenseMinimapDynamicLayer
) -> Dictionary:
	var batch_samples: Array[float] = []
	var legacy_samples: Array[float] = []
	await _capture_dynamic_draw(dynamic_layer, false)
	await _capture_dynamic_draw(dynamic_layer, true)
	for sample_index in range(DRAW_SAMPLE_COUNT):
		var batch_first := sample_index % 4 == 0 or sample_index % 4 == 3
		if batch_first:
			batch_samples.append(await _capture_dynamic_draw(dynamic_layer, true))
			legacy_samples.append(await _capture_dynamic_draw(dynamic_layer, false))
		else:
			legacy_samples.append(await _capture_dynamic_draw(dynamic_layer, false))
			batch_samples.append(await _capture_dynamic_draw(dynamic_layer, true))
	return {"batch": batch_samples, "legacy": legacy_samples}


func _capture_dynamic_draw(
	dynamic_layer: TowerDefenseMinimapDynamicLayer,
	use_batches: bool
) -> float:
	dynamic_layer.use_multimesh_batches = use_batches
	dynamic_layer.queue_redraw()
	await process_frame
	await process_frame
	return float(dynamic_layer._last_draw_elapsed_usec)


func _measure_interleaved_static_draws(
	static_layer: TowerDefenseMinimapStaticLayer
) -> Dictionary:
	var batch_samples: Array[float] = []
	var legacy_samples: Array[float] = []
	await _capture_static_draw(static_layer, false)
	await _capture_static_draw(static_layer, true)
	for sample_index in range(DRAW_SAMPLE_COUNT):
		var batch_first := sample_index % 4 == 0 or sample_index % 4 == 3
		if batch_first:
			batch_samples.append(await _capture_static_draw(static_layer, true))
			legacy_samples.append(await _capture_static_draw(static_layer, false))
		else:
			legacy_samples.append(await _capture_static_draw(static_layer, false))
			batch_samples.append(await _capture_static_draw(static_layer, true))
	return {"batch": batch_samples, "legacy": legacy_samples}


func _capture_static_draw(
	static_layer: TowerDefenseMinimapStaticLayer,
	use_batches: bool
) -> float:
	static_layer.use_multimesh_batches = use_batches
	static_layer.queue_redraw()
	await process_frame
	await process_frame
	return float(static_layer._last_draw_elapsed_usec)


func _build_enemy_positions() -> PackedVector2Array:
	var positions := PackedVector2Array()
	positions.resize(ENEMY_COUNT)
	for index in range(ENEMY_COUNT):
		positions[index] = Vector2(
			fmod(float(index * 37), WORLD_SIZE.x - 1.0) + 0.25,
			fmod(float(index * 53), WORLD_SIZE.y - 1.0) + 0.25
		)
	return positions


func _build_static_positions() -> PackedVector2Array:
	var positions := PackedVector2Array()
	positions.resize(STATIC_CELL_COUNT)
	for index in range(STATIC_CELL_COUNT):
		positions[index] = Vector2(
			float(index % 40) * 16.0 + 8.0,
			float(floori(float(index) / 40.0)) * 16.0 + 8.0
		)
	return positions


func _measure_packed_enemy_buckets(
	dynamic_layer: TowerDefenseMinimapDynamicLayer,
	overview_rect: Rect2
) -> float:
	var started_usec := Time.get_ticks_usec()
	for _iteration in range(DYNAMIC_ITERATIONS):
		dynamic_layer._rebuild_enemy_canvas_bucket_counts(overview_rect, false)
	return float(Time.get_ticks_usec() - started_usec) / 1000.0


func _measure_synced_enemy_buckets(
	dynamic_layer: TowerDefenseMinimapDynamicLayer,
	overview_rect: Rect2
) -> float:
	var started_usec := Time.get_ticks_usec()
	for _iteration in range(DYNAMIC_ITERATIONS):
		dynamic_layer._rebuild_enemy_canvas_bucket_counts(overview_rect, true)
	return float(Time.get_ticks_usec() - started_usec) / 1000.0


func _measure_dictionary_enemy_buckets(
	dynamic_layer: TowerDefenseMinimapDynamicLayer,
	enemy_positions: PackedVector2Array,
	overview_rect: Rect2
) -> float:
	var started_usec := Time.get_ticks_usec()
	for _iteration in range(DYNAMIC_ITERATIONS):
		_legacy_rebuild_enemy_buckets(dynamic_layer, enemy_positions, overview_rect)
	return float(Time.get_ticks_usec() - started_usec) / 1000.0


func _legacy_rebuild_enemy_buckets(
	dynamic_layer: TowerDefenseMinimapDynamicLayer,
	enemy_positions: PackedVector2Array,
	overview_rect: Rect2
) -> int:
	var bucket_counts: Dictionary[Vector2i, int] = {}
	for world_position in enemy_positions:
		if not overview_rect.has_point(world_position):
			continue
		var canvas_position := _legacy_world_to_canvas(
			dynamic_layer.size,
			dynamic_layer.world_center,
			dynamic_layer.overview_world_size,
			world_position
		)
		var bucket_coordinate := Vector2i(
			floori(canvas_position.x / dynamic_layer.ENEMY_BUCKET_SIZE_PX),
			floori(canvas_position.y / dynamic_layer.ENEMY_BUCKET_SIZE_PX)
		)
		bucket_counts[bucket_coordinate] = bucket_counts.get(bucket_coordinate, 0) + 1
	return bucket_counts.size()


func _measure_cached_static_projection(
	static_layer: TowerDefenseMinimapStaticLayer,
	positions: PackedVector2Array,
	iterations: int
) -> float:
	var started_usec := Time.get_ticks_usec()
	for _iteration in range(iterations):
		for world_position in positions:
			var canvas_rect := static_layer._world_rect_to_canvas(
				Rect2(world_position - Vector2(8.0, 8.0), Vector2(16.0, 16.0))
			)
			projection_sink += canvas_rect.position.x + canvas_rect.size.y
	return float(Time.get_ticks_usec() - started_usec) / 1000.0


func _measure_legacy_static_projection(
	static_layer: TowerDefenseMinimapStaticLayer,
	positions: PackedVector2Array,
	iterations: int
) -> float:
	var started_usec := Time.get_ticks_usec()
	for _iteration in range(iterations):
		for world_position in positions:
			var world_rect := Rect2(
				world_position - Vector2(8.0, 8.0),
				Vector2(16.0, 16.0)
			)
			var canvas_top_left := _legacy_world_to_canvas(
				static_layer.size,
				static_layer.world_center,
				static_layer.overview_world_size,
				world_rect.position
			)
			var canvas_bottom_right := _legacy_world_to_canvas(
				static_layer.size,
				static_layer.world_center,
				static_layer.overview_world_size,
				world_rect.end
			)
			var canvas_rect := Rect2(
				canvas_top_left,
				canvas_bottom_right - canvas_top_left
			)
			projection_sink += canvas_rect.position.x + canvas_rect.size.y
	return float(Time.get_ticks_usec() - started_usec) / 1000.0


func _legacy_world_to_canvas(
	canvas_size: Vector2,
	world_center: Vector2,
	overview_world_size: Vector2,
	world_position: Vector2
) -> Vector2:
	var safe_world_size := Vector2(
		maxf(overview_world_size.x, 0.001),
		maxf(overview_world_size.y, 0.001)
	)
	var projection_scale := minf(
		canvas_size.x / maxf(overview_world_size.x, 0.001),
		canvas_size.y / maxf(overview_world_size.y, 0.001)
	)
	var projected_world_size := safe_world_size * projection_scale
	var projection_origin := (canvas_size - projected_world_size) * 0.5
	var world_top_left := world_center - safe_world_size * 0.5
	return projection_origin + (world_position - world_top_left) * projection_scale


func _median(values: Array[float]) -> float:
	var sorted_values := values.duplicate()
	sorted_values.sort()
	return sorted_values[sorted_values.size() / 2]


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
