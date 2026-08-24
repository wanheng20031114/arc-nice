extends SceneTree

const FIXTURE_SCENE := preload(
	"res://dev_tools/fixtures/enemy_damageable_spatial_index_fixture.tscn"
)
const MULTI_CELL_CONFIG := preload(
	"res://resources/config/plant_defense/excavator.tres"
)
const EnemyDamageableSpatialIndexScript := preload(
	"res://scene/combat/targeting/enemy_damageable_spatial_index.gd"
)

var failures: Array[String] = []
var fixture: EnemyGameplayGatewayTestRuntime = null
var plant_system: PlantSystem = null
var damageable_index: EnemyDamageableSpatialIndexScript = null
var wide_plant: PlantDefense = null
var first_plant: PlantDefense = null
var second_plant: PlantDefense = null


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	await _mount_fixture_and_bind_source()
	if fixture != null and damageable_index != null and plant_system != null:
		_register_fixture_plants()
		_test_complete_multi_cell_collision_aabb_and_closed_boundaries()
		_test_reused_output_and_stable_order()
		_test_combined_shape_query_reuse_and_exact_boundaries()
		_test_cached_exact_shape_posterior_and_transform_refresh()
		_test_explicit_move_and_lifecycle_unregister()
		_test_idempotent_teardown()
	await _cleanup_fixture()
	_finish()


func _mount_fixture_and_bind_source() -> void:
	fixture = FIXTURE_SCENE.instantiate() as EnemyGameplayGatewayTestRuntime
	_expect(fixture != null, "Damageable spatial fixture must instantiate.")
	if fixture == null:
		return
	root.add_child(fixture)
	await process_frame
	plant_system = fixture.get_node_or_null("PlantSystem") as PlantSystem
	var plant_container := fixture.get_node_or_null("PlantContainer") as Node2D
	_expect(plant_system != null, "Fixture must author PlantSystem.")
	_expect(plant_container != null, "Fixture must author PlantContainer.")
	if plant_system == null or plant_container == null:
		return
	plant_system.setup(
		null,
		null,
		plant_container,
		PlantSystem.DEFAULT_PLACEMENT_AREA,
		null,
		fixture,
		null
	)
	var combat_services := fixture.get_enemy_combat_services()
	_expect(combat_services != null, "Fixture must expose bound combat services.")
	if combat_services == null:
		return
	damageable_index = combat_services.get_enemy_damageable_spatial_index()
	_expect(
		damageable_index != null,
		"Combat services must author EnemyDamageableSpatialIndex."
	)
	_expect(
		damageable_index != null and damageable_index.is_bound(),
		"Damageable index must inherit the service runtime context."
	)
	_expect(
		plant_system.get_enemy_damageable_spatial_index() == damageable_index,
		"PlantSystem setup must explicitly bind the shared damageable index."
	)


func _register_fixture_plants() -> void:
	wide_plant = fixture.get_node_or_null(
		"PlantContainer/WidePlant"
	) as PlantDefense
	first_plant = fixture.get_node_or_null(
		"PlantContainer/FirstPlant"
	) as PlantDefense
	second_plant = fixture.get_node_or_null(
		"PlantContainer/SecondPlant"
	) as PlantDefense
	_expect(wide_plant != null, "Fixture must author the multi-cell plant.")
	_expect(first_plant != null, "Fixture must author the first stable-order plant.")
	_expect(second_plant != null, "Fixture must author the second stable-order plant.")
	if wide_plant == null or first_plant == null or second_plant == null:
		return
	_register_plant(wide_plant, Vector2i(3, 3))
	# Deliberately register in reverse scene order. Query order must remain a
	# stable instance-ID order rather than bucket or registration order.
	_register_plant(second_plant, Vector2i(7, 0))
	_register_plant(first_plant, Vector2i.ZERO)
	var metrics := damageable_index.get_metrics()
	_expect(
		int(metrics["registered_count"]) == 3,
		"PlantSystem registration lifecycle must write all three plants."
	)
	_expect(
		int(metrics["membership_count"]) > int(metrics["registered_count"]),
		"The offset multi-cell plant AABB must own every crossed bucket."
	)


func _test_complete_multi_cell_collision_aabb_and_closed_boundaries() -> void:
	if wide_plant == null:
		return
	var cached_aabb := damageable_index.get_registered_world_aabb(wide_plant)
	_expect(
		cached_aabb.is_equal_approx(Rect2(Vector2(54.0, 48.0), Vector2(28.0, 28.0))),
		"Cached bounds must include the complete offset root collision shape."
	)
	var results: Array = []
	damageable_index.query_world_aabb_into(
		Rect2(Vector2(54.0, 62.0), Vector2.ZERO),
		results
	)
	_expect(
		results.size() == 1 and results[0] == wide_plant,
		"The closed left edge of a multi-cell collision AABB must be queryable."
	)
	damageable_index.query_world_aabb_into(
		Rect2(Vector2(82.0, 62.0), Vector2.ZERO),
		results
	)
	_expect(
		results.size() == 1 and results[0] == wide_plant,
		"The closed right edge across a bucket boundary must be queryable once."
	)
	damageable_index.query_world_aabb_into(
		Rect2(Vector2(82.01, 62.0), Vector2.ZERO),
		results
	)
	_expect(
		results.is_empty(),
		"A point outside the cached root collision AABB must not be returned."
	)


func _test_reused_output_and_stable_order() -> void:
	if first_plant == null or second_plant == null or wide_plant == null:
		return
	var reused_output: Array = [fixture]
	var broad_query := Rect2(Vector2(-32.0, -32.0), Vector2(176.0, 144.0))
	var first_count := damageable_index.query_world_aabb_into(
		broad_query,
		reused_output
	)
	_expect(first_count == 3, "Broad query must find each plant exactly once.")
	_expect(
		not reused_output.has(fixture),
		"query_world_aabb_into must clear and reuse caller-owned Array storage."
	)
	var expected_ids: Array[int] = [
		wide_plant.get_instance_id(),
		first_plant.get_instance_id(),
		second_plant.get_instance_id(),
	]
	expected_ids.sort()
	var first_ids := _collect_instance_ids(reused_output)
	_expect(
		first_ids == expected_ids,
		"Query results must use deterministic ascending instance-ID order."
	)
	damageable_index.query_world_aabb_into(broad_query, reused_output)
	_expect(
		_collect_instance_ids(reused_output) == first_ids,
		"Repeated queries into the same Array must preserve stable order."
	)


func _test_combined_shape_query_reuse_and_exact_boundaries() -> void:
	if first_plant == null or second_plant == null or wide_plant == null:
		return
	var query_circle := CircleShape2D.new()
	query_circle.radius = 1.0
	var reused_output: Array = [fixture]
	var corner_false_positive_transform := Transform2D(
		0.0,
		Vector2(118.0, 22.0)
	)
	_expect(
		damageable_index.query_overlapping_damageables_into(
			query_circle,
			corner_false_positive_transform,
			reused_output
		) == 0 and reused_output.is_empty(),
		"Combined shape query must reject an AABB-corner false positive in place."
	)
	var closed_tangent_transform := Transform2D(0.0, Vector2(120.0, 16.0))
	_expect(
		damageable_index.query_overlapping_damageables_into(
			query_circle,
			closed_tangent_transform,
			reused_output
		) == 1
		and reused_output.size() == 1
		and reused_output[0] == second_plant,
		"Combined shape query must include an exact closed tangent boundary once."
	)
	_expect(
		damageable_index.query_overlapping_damageables_into(
			query_circle,
			Transform2D(0.0, Vector2(120.01, 16.0)),
			reused_output
		) == 0 and reused_output.is_empty(),
		"Combined shape query must exclude a shape immediately beyond contact."
	)

	var covering_shape := RectangleShape2D.new()
	covering_shape.size = Vector2(128.0, 80.0)
	var covering_transform := Transform2D(0.0, Vector2(64.0, 40.0))
	reused_output.append(fixture)
	var first_count := damageable_index.query_overlapping_damageables_into(
		covering_shape,
		covering_transform,
		reused_output
	)
	_expect(first_count == 3, "Combined shape query must find all exact overlaps.")
	_expect(
		not reused_output.has(fixture),
		"Combined shape query must clear and reuse caller-owned Array storage."
	)
	var first_ids := _collect_instance_ids(reused_output)
	var expected_ids: Array[int] = [
		wide_plant.get_instance_id(),
		first_plant.get_instance_id(),
		second_plant.get_instance_id(),
	]
	expected_ids.sort()
	_expect(
		first_ids == expected_ids,
		"Combined exact results must retain ascending instance-ID order."
	)
	damageable_index.query_overlapping_damageables_into(
		covering_shape,
		covering_transform,
		reused_output
	)
	_expect(
		_collect_instance_ids(reused_output) == first_ids,
		"Repeated combined queries into one Array must preserve stable order."
	)

	reused_output.append(fixture)
	_expect(
		damageable_index.query_overlapping_damageables_into(
			null,
			Transform2D.IDENTITY,
			reused_output
		) == 0 and reused_output.is_empty(),
		"A null query shape must fail closed and clear reused output."
	)
	var invalid_transform := Transform2D.IDENTITY
	invalid_transform.origin = Vector2(INF, 0.0)
	reused_output.append(fixture)
	_expect(
		damageable_index.query_overlapping_damageables_into(
			query_circle,
			invalid_transform,
			reused_output
		) == 0 and reused_output.is_empty(),
		"A non-finite query transform must fail closed and clear reused output."
	)


func _test_cached_exact_shape_posterior_and_transform_refresh() -> void:
	if second_plant == null:
		return
	var projectile_shape := CircleShape2D.new()
	projectile_shape.radius = 1.0
	var false_positive_center := Vector2(118.0, 22.0)
	var false_positive_transform := Transform2D(0.0, false_positive_center)
	var broad_results: Array = []
	damageable_index.query_world_aabb_into(
		Rect2(false_positive_center - Vector2.ONE, Vector2.ONE * 2.0),
		broad_results
	)
	_expect(
		broad_results.has(second_plant),
		"Circle AABB corner must remain an observable broad-phase candidate."
	)
	_expect(
		not damageable_index.damageable_overlaps_shape(
			second_plant,
			projectile_shape,
			false_positive_transform
		),
		"Cached exact shapes must reject an AABB-only false positive."
	)
	var overlapping_transform := Transform2D(0.0, Vector2(118.0, 16.0))
	_expect(
		damageable_index.damageable_overlaps_shape(
			second_plant,
			projectile_shape,
			overlapping_transform
		),
		"Cached exact shapes must accept a real projectile contact."
	)

	second_plant.global_position = Vector2(304.0, 16.0)
	_expect(
		plant_system.refresh_enemy_damageable_spatial_entry(second_plant),
		"Exact-shape transforms must refresh through the explicit update seam."
	)
	_expect(
		not damageable_index.damageable_overlaps_shape(
			second_plant,
			projectile_shape,
			overlapping_transform
		),
		"An updated cache must stop using the previous shape transform."
	)
	_expect(
		damageable_index.damageable_overlaps_shape(
			second_plant,
			projectile_shape,
			Transform2D(0.0, Vector2(310.0, 16.0))
		),
		"An updated cache must use the moved shape transform."
	)


func _test_explicit_move_and_lifecycle_unregister() -> void:
	if wide_plant == null:
		return
	wide_plant.global_position = Vector2(224.0, 64.0)
	_expect(
		plant_system.refresh_enemy_damageable_spatial_entry(wide_plant),
		"A movement owner must be able to refresh one plant explicitly."
	)
	var results: Array = []
	damageable_index.query_world_aabb_into(
		Rect2(Vector2(68.0, 62.0), Vector2.ZERO),
		results
	)
	_expect(results.is_empty(), "Moved plant must leave every old bucket.")
	damageable_index.query_world_aabb_into(
		Rect2(Vector2(228.0, 62.0), Vector2.ZERO),
		results
	)
	_expect(
		results.size() == 1 and results[0] == wide_plant,
		"Moved plant must enter its new collision AABB without a scene scan."
	)
	plant_system.call("_release_plant_footprint", wide_plant)
	_expect(
		not damageable_index.contains_damageable(wide_plant),
		"The shared PlantSystem removal path must synchronously unregister."
	)
	damageable_index.query_world_aabb_into(
		Rect2(Vector2(228.0, 62.0), Vector2.ZERO),
		results
	)
	_expect(results.is_empty(), "Released plant must no longer be queryable.")


func _test_idempotent_teardown() -> void:
	fixture.prepare_for_scene_teardown()
	fixture.prepare_for_scene_teardown()
	var metrics := damageable_index.get_metrics()
	_expect(
		int(metrics["teardown_count"]) == 1,
		"Damageable index teardown must be idempotent."
	)
	_expect(
		not bool(metrics["bound"])
		and int(metrics["registered_count"]) == 0
		and int(metrics["membership_count"]) == 0,
		"Teardown must release context, registrations, and bucket memberships."
	)
	_expect(
		plant_system.get_enemy_damageable_spatial_index() == null,
		"Service teardown must detach the PlantSystem source."
	)
	var reused_output: Array = [first_plant]
	_expect(
		damageable_index.query_world_aabb_into(
			Rect2(Vector2(-1000.0, -1000.0), Vector2(2000.0, 2000.0)),
			reused_output
		) == 0 and reused_output.is_empty(),
		"A torn-down empty index must still clear caller-owned query output."
	)
	_expect(
		not damageable_index.register_damageable(first_plant),
		"Teardown must reject later registrations instead of silently rebinding."
	)


func _register_plant(plant: PlantDefense, top_left: Vector2i) -> void:
	var cells: Array[Vector2i] = []
	for y in range(MULTI_CELL_CONFIG.footprint_size.y):
		for x in range(MULTI_CELL_CONFIG.footprint_size.x):
			cells.append(top_left + Vector2i(x, y))
	plant_system.call(
		"_register_plant_footprint",
		plant,
		cells,
		MULTI_CELL_CONFIG
	)


func _collect_instance_ids(objects: Array) -> Array[int]:
	var instance_ids: Array[int] = []
	for object_variant in objects:
		var object := object_variant as Object
		if object != null:
			instance_ids.append(object.get_instance_id())
	return instance_ids


func _cleanup_fixture() -> void:
	if fixture != null and is_instance_valid(fixture):
		fixture.queue_free()
	for _cleanup_frame in range(4):
		await process_frame
	await physics_frame


func _finish() -> void:
	var result := {
		"status": "ok" if failures.is_empty() else "failed",
		"failures": failures.duplicate(),
	}
	print("ENEMY_DAMAGEABLE_SPATIAL_INDEX_JSON %s" % JSON.stringify(result))
	if failures.is_empty():
		print("ENEMY_DAMAGEABLE_SPATIAL_INDEX_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
