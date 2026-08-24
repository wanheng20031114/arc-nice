extends SceneTree

const POLICY := preload(
	"res://scene/combat/simulation/enemy_simulation_policy.gd"
)
const RUNTIME_SCENE := preload(
	"res://dev_tools/fixtures/enemy_gameplay_gateway_test_runtime.tscn"
)
const FAST_CONFIG := preload(
	"res://resources/config/enemies/yuanshi_insect_fast.tres"
)
const PLAYER_SCENE := preload(
	"res://scene/player/weishidaier/player_weishidaier.tscn"
)
const PLANT_FIXTURE_SCENE := preload(
	"res://dev_tools/fixtures/indexed_touch_circle_plant_fixture.tscn"
)
const HARNESS_SCRIPT := preload(
	"res://dev_tools/fixtures/indexed_touch_plant_certificate_yuanshi_harness.gd"
)
const HARNESS_SCENE := preload(
	"res://dev_tools/fixtures/indexed_touch_plant_certificate_yuanshi_harness.tscn"
)

const PHYSICS_DELTA := 1.0 / 60.0

var failures: Array[String] = []


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	await _test_cached_candidate_empty_certificate_and_sweep_invalidation()
	await _test_rotation_invalidates_contact_geometry_certificate()
	await _test_plant_shape_change_and_target_deletion()
	await _test_stable_candidate_and_dirty_drain_order()
	await _test_player_domain_does_not_poison_plant_certificate()
	if failures.is_empty():
		print("ENEMY_INDEXED_PLANT_EMPTY_CERTIFICATE_REGRESSION_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


## A Circle plant at x=10 is inside Yuanshi's six-tick query envelope but not
## its current Capsule AABB. Multiple same-frame translations remain reusable
## only while both the current and accumulated swept AABB stay separated.
func _test_cached_candidate_empty_certificate_and_sweep_invalidation() -> void:
	var runtime := RUNTIME_SCENE.instantiate() as EnemyGameplayGatewayTestRuntime
	root.add_child(runtime)
	await process_frame
	runtime.enable_singleplayer_combat_target_index(true)
	var coordinator := runtime.get_enemy_simulation_coordinator()
	coordinator.set_mode(POLICY.Mode.LAYERED_CONTACT)
	var plant_fixture := _make_circle_plant(runtime, Vector2(10.0, 0.0), 1.0)
	var plant := plant_fixture["plant"] as PlantDefense
	var damageable_index := _get_damageable_index(coordinator)
	_expect(
		damageable_index != null
		and damageable_index.register_damageable(plant),
		"Cached-candidate fixture must register its Plant in the production spatial index."
	)
	var enemy := _spawn_harness(runtime, Vector2.ZERO)
	await _settle_physics_frames(5)
	coordinator.set_physics_process(false)
	var initial_metrics: Dictionary = coordinator.get_metrics()
	_expect(
		enemy.is_indexed_touch_authority_enabled()
		and enemy.indexed_touch_contact_snapshot_is_empty(),
		"The cached-candidate fixture must begin with a complete empty contact snapshot."
	)
	_expect(
		int(initial_metrics["indexed_touch_plant_candidate_checks"]) > 0
		and int(initial_metrics["indexed_touch_plant_exact_candidates"]) == 0,
		"The Plant must be cached from the grown query envelope while remaining outside the exact current attacker AABB."
	)

	var before_safe_motion: Dictionary = coordinator.get_metrics()
	# All writes occur before one coordinator tick. The resulting accumulated
	# attacker sweep ends at x=8, still before the Plant AABB beginning at x=9.
	enemy.global_position = Vector2(0.75, 0.0)
	enemy.global_position = Vector2(1.5, 0.0)
	enemy.global_position = Vector2(2.0, 0.0)
	await _manual_coordinator_tick(coordinator)
	var after_safe_motion: Dictionary = coordinator.get_metrics()
	_expect(
		int(after_safe_motion["indexed_touch_dirty_drains"])
			== int(before_safe_motion["indexed_touch_dirty_drains"])
		and int(after_safe_motion["indexed_touch_empty_corridor_skips"])
			> int(before_safe_motion["indexed_touch_empty_corridor_skips"])
		and enemy.indexed_touch_contact_snapshot_is_empty(),
		"A cached Plant candidate disjoint from the current and accumulated swept AABB must reuse the complete empty snapshot without an exact drain."
	)

	# Cross into exact contact and return before the tick. Looking only at the
	# final Transform would incorrectly reuse the empty certificate; the retained
	# cumulative sweep must force an exact reconciliation.
	var before_crossing: Dictionary = coordinator.get_metrics()
	enemy.global_position = Vector2(3.2, 0.0)
	enemy.global_position = Vector2(2.0, 0.0)
	await _manual_coordinator_tick(coordinator)
	var after_crossing: Dictionary = coordinator.get_metrics()
	_expect(
		int(after_crossing["indexed_touch_dirty_drains"])
			> int(before_crossing["indexed_touch_dirty_drains"])
		and enemy.indexed_touch_contact_snapshot_is_empty(),
		"A same-frame sweep crossing a cached Plant AABB must invalidate immediately even when the final Transform is empty again."
	)

	# At x=2.8 the exact shapes remain separated, but the 0.25px safety margin
	# reaches the Plant AABB and must end the certificate before contact occurs.
	var before_imminent: Dictionary = coordinator.get_metrics()
	enemy.global_position = Vector2(2.8, 0.0)
	await _manual_coordinator_tick(coordinator)
	var after_imminent: Dictionary = coordinator.get_metrics()
	_expect(
		int(after_imminent["indexed_touch_dirty_drains"])
			> int(before_imminent["indexed_touch_dirty_drains"])
		and not enemy.touching_plants.has(plant.get_instance_id()),
		"Approaching within the static-envelope epsilon must invalidate the certificate before the exact shapes intersect."
	)

	var before_enter: Dictionary = coordinator.get_metrics()
	enemy.global_position = Vector2(3.2, 0.0)
	await _manual_coordinator_tick(coordinator)
	var after_enter: Dictionary = coordinator.get_metrics()
	_expect(
		int(after_enter["indexed_touch_dirty_drains"])
			> int(before_enter["indexed_touch_dirty_drains"])
		and enemy.touching_plants.has(plant.get_instance_id()),
		"Actual Plant intersection must publish ENTER on the first coordinator tick."
	)
	await _cleanup_runtime(runtime, coordinator)


## Root rotation changes the authored horizontal Capsule into a vertical one.
## The Plant is deliberately inside the query cache but outside the old AABB.
func _test_rotation_invalidates_contact_geometry_certificate() -> void:
	var runtime := RUNTIME_SCENE.instantiate() as EnemyGameplayGatewayTestRuntime
	root.add_child(runtime)
	await process_frame
	runtime.enable_singleplayer_combat_target_index(true)
	var coordinator := runtime.get_enemy_simulation_coordinator()
	coordinator.set_mode(POLICY.Mode.LAYERED_CONTACT)
	var plant_fixture := _make_circle_plant(runtime, Vector2(0.0, 5.0), 1.0)
	var plant := plant_fixture["plant"] as PlantDefense
	var damageable_index := _get_damageable_index(coordinator)
	_expect(
		damageable_index != null
		and damageable_index.register_damageable(plant),
		"Rotation fixture must register its Plant."
	)
	var enemy := _spawn_harness(runtime, Vector2.ZERO)
	await _settle_physics_frames(5)
	coordinator.set_physics_process(false)
	_expect(
		not enemy.touching_plants.has(plant.get_instance_id()),
		"The horizontal authored Capsule must initially miss the vertical Plant fixture."
	)
	var before_rotation: Dictionary = coordinator.get_metrics()
	enemy.rotation = PI * 0.5
	await _manual_coordinator_tick(coordinator)
	var after_rotation: Dictionary = coordinator.get_metrics()
	_expect(
		int(after_rotation["indexed_touch_dirty_drains"])
			> int(before_rotation["indexed_touch_dirty_drains"])
		and enemy.touching_plants.has(plant.get_instance_id()),
		"A root rotation changing the attacker AABB must recapture geometry, invalidate the empty certificate, and publish Plant ENTER in the same tick."
	)
	await _cleanup_runtime(runtime, coordinator)


func _test_plant_shape_change_and_target_deletion() -> void:
	var runtime := RUNTIME_SCENE.instantiate() as EnemyGameplayGatewayTestRuntime
	root.add_child(runtime)
	await process_frame
	runtime.enable_singleplayer_combat_target_index(true)
	var coordinator := runtime.get_enemy_simulation_coordinator()
	coordinator.set_mode(POLICY.Mode.LAYERED_CONTACT)
	var plant_fixture := _make_circle_plant(runtime, Vector2(10.0, 0.0), 1.0)
	var plant := plant_fixture["plant"] as PlantDefense
	var plant_shape := plant_fixture["shape"] as CircleShape2D
	var damageable_index := _get_damageable_index(coordinator)
	_expect(
		damageable_index != null
		and damageable_index.register_damageable(plant),
		"Shape-change fixture must register its Plant."
	)
	var enemy := _spawn_harness(runtime, Vector2.ZERO)
	await _settle_physics_frames(5)
	coordinator.set_physics_process(false)
	_expect(
		not enemy.touching_plants.has(plant.get_instance_id()),
		"The small Plant shape must initially remain outside exact contact."
	)

	var before_shape_change: Dictionary = coordinator.get_metrics()
	plant_shape.radius = 5.0
	_expect(
		damageable_index.update_damageable(plant),
		"Changing the Plant Shape2D AABB must advance the spatial-index geometry revision."
	)
	await _manual_coordinator_tick(coordinator)
	var after_shape_change: Dictionary = coordinator.get_metrics()
	_expect(
		int(after_shape_change["indexed_touch_dirty_drains"])
			> int(before_shape_change["indexed_touch_dirty_drains"])
		and enemy.touching_plants.has(plant.get_instance_id()),
		"A Plant shape expansion must invalidate the certificate and publish ENTER immediately."
	)

	var removed_plant_id := plant.get_instance_id()
	var before_removal: Dictionary = coordinator.get_metrics()
	_expect(
		damageable_index.unregister_damageable(plant),
		"Target-deletion fixture must unregister the indexed Plant before freeing it."
	)
	plant.queue_free()
	await process_frame
	await _manual_coordinator_tick(coordinator)
	var after_removal: Dictionary = coordinator.get_metrics()
	_expect(
		int(after_removal["indexed_touch_dirty_drains"])
			> int(before_removal["indexed_touch_dirty_drains"])
		and not enemy.touching_plants.has(removed_plant_id)
		and enemy.indexed_touch_contact_snapshot_is_empty(),
		"Deleting a cached/contacting Plant must invalidate geometry and remove every stale target reference in the first tick."
	)
	await _cleanup_runtime(runtime, coordinator)


func _test_stable_candidate_and_dirty_drain_order() -> void:
	HARNESS_SCRIPT.reset_contact_observations()
	var runtime := RUNTIME_SCENE.instantiate() as EnemyGameplayGatewayTestRuntime
	root.add_child(runtime)
	await process_frame
	runtime.enable_singleplayer_combat_target_index(true)
	var coordinator := runtime.get_enemy_simulation_coordinator()
	coordinator.set_mode(POLICY.Mode.LAYERED_CONTACT)
	var first_fixture := _make_circle_plant(runtime, Vector2(-1.0, 0.0), 1.0)
	var second_fixture := _make_circle_plant(runtime, Vector2(1.0, 0.0), 1.0)
	var first_plant := first_fixture["plant"] as PlantDefense
	var second_plant := second_fixture["plant"] as PlantDefense
	var lower_plant := first_plant
	var higher_plant := second_plant
	if lower_plant.get_instance_id() > higher_plant.get_instance_id():
		lower_plant = second_plant
		higher_plant = first_plant
	var damageable_index := _get_damageable_index(coordinator)
	# Deliberately register in reverse stable-ID order.
	_expect(
		damageable_index != null
		and damageable_index.register_damageable(higher_plant)
		and damageable_index.register_damageable(lower_plant),
		"Stable-order fixture must register both Plants in reverse instance-ID order."
	)
	var low_enemy := _spawn_harness(runtime, Vector2.ZERO)
	var high_enemy := _spawn_harness(runtime, Vector2.ZERO)
	await _settle_physics_frames(6)
	coordinator.set_physics_process(false)
	var expected_plant_order: Array[int] = [
		lower_plant.get_instance_id(),
		higher_plant.get_instance_id(),
	]
	var delivered_plant_order: Array[int] = (
		HARNESS_SCRIPT.get_synchronized_plant_ids(low_enemy.simulation_id)
	)
	_expect(
		delivered_plant_order == expected_plant_order,
		"Spatial candidates must reach indexed contact in stable instance-ID order even when registration order is reversed; expected %s, got %s."
			% [expected_plant_order, delivered_plant_order]
	)
	_expect(
		low_enemy.simulation_id > 0
		and high_enemy.simulation_id > low_enemy.simulation_id,
		"Stable dirty-drain fixture requires monotonic simulation IDs."
	)

	HARNESS_SCRIPT.reset_contact_visit_order()
	# Enqueue the high-ID enemy first to require the coordinator's stable sort.
	high_enemy.global_position = Vector2(0.1, 0.0)
	low_enemy.global_position = Vector2(0.1, 0.0)
	await _manual_coordinator_tick(coordinator)
	var visit_order: Array[int] = HARNESS_SCRIPT.get_contact_visit_order()
	var expected_visit_order: Array[int] = [
		low_enemy.simulation_id,
		high_enemy.simulation_id,
	]
	_expect(
		visit_order == expected_visit_order,
		"High-ID-first Transform dirties must reconcile exactly once each in ascending simulation-ID order; expected %s, got %s."
			% [expected_visit_order, visit_order]
	)
	await _cleanup_runtime(runtime, coordinator)
	HARNESS_SCRIPT.reset_contact_observations()


func _test_player_domain_does_not_poison_plant_certificate() -> void:
	var runtime := RUNTIME_SCENE.instantiate() as EnemyGameplayGatewayTestRuntime
	root.add_child(runtime)
	await process_frame
	runtime.enable_singleplayer_combat_target_index(true)
	var coordinator := runtime.get_enemy_simulation_coordinator()
	coordinator.set_mode(POLICY.Mode.LAYERED_CONTACT)
	var player := PLAYER_SCENE.instantiate() as Player
	player.peer_id = 1
	runtime.add_child(player)
	runtime.bind_player_runtime_context(player)
	runtime.peer_players[player.peer_id] = player
	player.global_position = Vector2(15.0, 0.0)
	player.reset_physics_interpolation()
	player.set_physics_process(false)
	var plant_fixture := _make_circle_plant(runtime, Vector2(0.0, 7.5), 1.0)
	var plant := plant_fixture["plant"] as PlantDefense
	var damageable_index := _get_damageable_index(coordinator)
	_expect(
		damageable_index != null
		and damageable_index.register_damageable(plant),
		"Player-domain fixture must register its disjoint cached Plant."
	)
	var enemy := _spawn_harness(runtime, Vector2.ZERO)
	await _settle_physics_frames(5)
	coordinator.set_physics_process(false)
	var initial_metrics: Dictionary = coordinator.get_metrics()
	_expect(
		int(initial_metrics["indexed_touch_plant_candidate_checks"]) > 0
		and enemy.indexed_touch_contact_snapshot_is_empty(),
		"Player-domain fixture must start with a real cached Plant candidate and an empty combined snapshot."
	)

	# Plant remains vertically disjoint, while the enemy translation reaches the
	# real Player circle. Plant-certificate reuse must not suppress Player sweep.
	var before_player_enter: Dictionary = coordinator.get_metrics()
	enemy.global_position = Vector2(2.0, 0.0)
	await _manual_coordinator_tick(coordinator)
	var after_player_enter: Dictionary = coordinator.get_metrics()
	_expect(
		int(after_player_enter["indexed_touch_dirty_drains"])
			> int(before_player_enter["indexed_touch_dirty_drains"])
		and enemy.touching_players.has(player.get_instance_id())
		and not enemy.touching_plants.has(plant.get_instance_id()),
		"A reusable empty Plant certificate must not hide a Player ENTER from the independent relative-sweep domain."
	)

	player.global_position = Vector2(4096.0, 0.0)
	player.reset_physics_interpolation()
	await _manual_coordinator_tick(coordinator)
	_expect(
		not enemy.touching_players.has(player.get_instance_id())
		and not enemy.touching_plants.has(plant.get_instance_id()),
		"Player EXIT must reconcile without changing the cached empty Plant result."
	)

	var before_post_player_motion: Dictionary = coordinator.get_metrics()
	enemy.global_position = Vector2(2.25, 0.0)
	await _manual_coordinator_tick(coordinator)
	var after_post_player_motion: Dictionary = coordinator.get_metrics()
	_expect(
		int(after_post_player_motion["indexed_touch_dirty_drains"])
			== int(before_post_player_motion["indexed_touch_dirty_drains"])
		and int(after_post_player_motion["indexed_touch_empty_corridor_skips"])
			> int(before_post_player_motion["indexed_touch_empty_corridor_skips"])
		and enemy.indexed_touch_contact_snapshot_is_empty(),
		"A completed Player ENTER/EXIT cycle must not permanently poison the independent cached-Plant empty certificate."
	)
	await _cleanup_runtime(runtime, coordinator)


func _make_circle_plant(
	runtime: EnemyGameplayGatewayTestRuntime,
	world_position: Vector2,
	radius: float
) -> Dictionary:
	var plant := PLANT_FIXTURE_SCENE.instantiate() as PlantDefense
	plant.max_health = 100000
	plant.current_health = 100000
	var shape_node := plant.get_node(^"CollisionShape2D") as CollisionShape2D
	var shape := shape_node.shape as CircleShape2D
	shape.radius = radius
	runtime.add_child(plant)
	plant.global_position = world_position
	return {
		"plant": plant,
		"shape_node": shape_node,
		"shape": shape,
	}


func _spawn_harness(
	runtime: EnemyGameplayGatewayTestRuntime,
	world_position: Vector2
) -> YuanshiInsect:
	# Headless single-script runs do not require the editor's global-class cache
	# to discover the fixture subclass before this test script is parsed. Its
	# production parent type exposes every contact/simulation assertion used here.
	var enemy := HARNESS_SCENE.instantiate() as YuanshiInsect
	enemy.global_position = world_position
	runtime.enemy_container.add_child(enemy)
	enemy.setup(FAST_CONFIG, null, runtime.grid_pathfinder, runtime)
	return enemy


func _get_damageable_index(
	coordinator: EnemySimulationCoordinator
) -> EnemyDamageableSpatialIndex:
	var services := coordinator.get_combat_services()
	if services == null:
		return null
	return services.get_enemy_damageable_spatial_index()


func _settle_physics_frames(frame_count: int) -> void:
	for _frame_index in range(frame_count):
		await physics_frame


func _manual_coordinator_tick(
	coordinator: EnemySimulationCoordinator
) -> void:
	coordinator.set_physics_process(false)
	await physics_frame
	coordinator.set_physics_process(false)
	coordinator._physics_process(PHYSICS_DELTA)
	coordinator.set_physics_process(false)


func _cleanup_runtime(
	runtime: EnemyGameplayGatewayTestRuntime,
	coordinator: EnemySimulationCoordinator
) -> void:
	if coordinator != null and is_instance_valid(coordinator):
		coordinator.set_mode(POLICY.Mode.LEGACY)
	if runtime != null and is_instance_valid(runtime):
		runtime.queue_free()
	await process_frame
	await physics_frame


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
