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
const PLAYER_CENTERED_BROADPHASE_ENEMY_COUNT := 200
const PLAYER_CENTERED_BROADPHASE_PLAYER_COUNT := 5
const PLAYER_CENTERED_PERFORMANCE_WARMUP_TICKS := 30
const PLAYER_CENTERED_PERFORMANCE_TICKS := 120

var failures: Array[String] = []
var player_centered_broadphase_report: Dictionary = {}


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	await _test_cached_candidate_empty_certificate_and_sweep_invalidation()
	await _test_rotation_invalidates_contact_geometry_certificate()
	await _test_plant_shape_change_and_target_deletion()
	await _test_stable_candidate_and_dirty_drain_order()
	await _test_player_domain_does_not_poison_plant_certificate()
	await _test_moving_player_against_static_enemy()
	await _test_player_centered_broadphase_and_touch_deadline()
	if failures.is_empty():
		print(
			"ENEMY_INDEXED_PLAYER_BROADPHASE_JSON %s"
			% JSON.stringify(player_centered_broadphase_report)
		)
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


func _test_moving_player_against_static_enemy() -> void:
	var runtime := RUNTIME_SCENE.instantiate() as EnemyGameplayGatewayTestRuntime
	root.add_child(runtime)
	await process_frame
	runtime.enable_singleplayer_combat_target_index(true)
	var coordinator := runtime.get_enemy_simulation_coordinator()
	coordinator.set_mode(POLICY.Mode.LAYERED_CONTACT)

	var player := PLAYER_SCENE.instantiate() as Player
	player.peer_id = 9
	runtime.add_child(player)
	runtime.bind_player_runtime_context(player)
	runtime.peer_players[player.peer_id] = player
	player.global_position = Vector2(512.0, 0.0)
	player.reset_physics_interpolation()
	player.set_process(false)
	player.set_physics_process(false)
	var enemy := _spawn_harness(runtime, Vector2.ZERO)
	enemy.set_objective_target(player)
	await _settle_physics_frames(6)
	coordinator.set_physics_process(false)
	coordinator.get_metrics(true)

	var health_before_rejected_enter := player.current_health
	player.invincibility_time_left = 1.0
	player.global_position = enemy.global_position
	await _manual_coordinator_tick(coordinator)
	var enter_metrics: Dictionary = coordinator.get_metrics(true)
	var health_after_enter := player.current_health
	_expect(
		int(enter_metrics["indexed_touch_player_index_queries"]) == 1
		and int(enter_metrics["indexed_touch_player_exact_shape_hits"]) == 1
		and int(enter_metrics["indexed_touch_contact_enters"]) == 1
		and int(enter_metrics["touch_damage_attempts"]) == 1
		and int(enter_metrics["touch_damage_accepted"]) == 0
		and int(enter_metrics["touch_damage_rejected"]) == 1
		and player.current_health == health_before_rejected_enter
		and enemy.has_active_touch_damage_cooldown()
		and enemy.touched_player == player,
		"A moving Player must enter a static enemy in the same tick; the authored single-player rejected settlement still establishes its cooldown deadline."
	)

	player.is_dead = true
	await _manual_coordinator_tick(coordinator)
	var death_metrics: Dictionary = coordinator.get_metrics(true)
	_expect(
		int(death_metrics["indexed_touch_contact_exits"]) == 1
		and enemy.indexed_touch_player_snapshot_is_empty(),
		"Player death must remove a nonempty indexed contact snapshot in the first tick."
	)

	player.is_dead = false
	await _manual_coordinator_tick(coordinator)
	var revive_metrics: Dictionary = coordinator.get_metrics(true)
	_expect(
		int(revive_metrics["indexed_touch_contact_enters"]) == 1
		and enemy.touched_player == player
		and player.current_health == health_after_enter,
		"Player revival inside contact must re-enter immediately without bypassing the existing damage deadline."
	)
	await _cleanup_runtime(runtime, coordinator)


func _test_player_centered_broadphase_and_touch_deadline() -> void:
	var runtime := RUNTIME_SCENE.instantiate() as EnemyGameplayGatewayTestRuntime
	runtime.enemy_navigation_mode = (
		CombatRuntimeBase.EnemyNavigationMode.SIMPLE_LINEAR
	)
	root.add_child(runtime)
	await process_frame
	runtime.enable_singleplayer_combat_target_index(true)
	var coordinator := runtime.get_enemy_simulation_coordinator()
	coordinator.set_mode(POLICY.Mode.LAYERED_CONTACT)

	var players: Array[Player] = []
	for peer_id in range(1, PLAYER_CENTERED_BROADPHASE_PLAYER_COUNT + 1):
		var player := PLAYER_SCENE.instantiate() as Player
		player.peer_id = peer_id
		runtime.add_child(player)
		runtime.bind_player_runtime_context(player)
		runtime.peer_players[peer_id] = player
		player.global_position = Vector2.ZERO
		player.reset_physics_interpolation()
		player.set_process(false)
		player.set_physics_process(false)
		players.append(player)

	var enemies: Array[YuanshiInsect] = []
	for enemy_index in range(PLAYER_CENTERED_BROADPHASE_ENEMY_COUNT):
		var spawn_position := Vector2(
			2048.0 + float(enemy_index % 20) * 24.0,
			1024.0 + float(enemy_index / 20) * 24.0
		)
		var enemy := _spawn_harness(runtime, spawn_position)
		enemy.set_objective_target(players[0])
		enemy.random_generator.seed = 20_260_827 + enemy_index
		enemies.append(enemy)
	await _settle_physics_frames(PLAYER_CENTERED_PERFORMANCE_WARMUP_TICKS)
	# Exercise the complete automatic physics path, but do not turn Godot's
	# TIME_PHYSICS_PROCESS monitor into per-tick samples. That monitor publishes
	# the previous coarse (up to one-second) maximum and retains the same value
	# between updates; percentiles over repeated reads would therefore be false.
	for tick_index in range(PLAYER_CENTERED_PERFORMANCE_TICKS):
		var phase := (
			TAU * float(tick_index % 60) / 60.0
		)
		for player_index in range(players.size()):
			players[player_index].global_position = (
				Vector2.from_angle(
					phase + TAU * float(player_index) / float(players.size())
				)
				* 32.0
			)
		await physics_frame

	coordinator.set_physics_process(false)
	var previous_performance_metrics_enabled := Enemy.performance_metrics_enabled
	Enemy.set_performance_metrics_enabled(true)
	coordinator.get_metrics(true)
	var coordinator_usec_samples: Array[int] = []
	for tick_index in range(PLAYER_CENTERED_PERFORMANCE_TICKS):
		var phase := (
			TAU * float(tick_index % 60) / 60.0
		)
		for player_index in range(players.size()):
			players[player_index].global_position = (
				Vector2.from_angle(
					phase + TAU * float(player_index) / float(players.size())
				)
				* 32.0
			)
		await physics_frame
		var coordinator_started_usec := Time.get_ticks_usec()
		coordinator._physics_process(PHYSICS_DELTA)
		coordinator_usec_samples.append(
			Time.get_ticks_usec() - coordinator_started_usec
		)
	var coordinator_profile_metrics := coordinator.get_metrics(true)
	Enemy.set_performance_metrics_enabled(previous_performance_metrics_enabled)
	coordinator_usec_samples.sort()
	for player in players:
		player.global_position = Vector2.ZERO
	await physics_frame
	coordinator.get_metrics(true)

	for enemy in enemies:
		enemy.global_position += Vector2.RIGHT
	await _manual_coordinator_tick(coordinator)
	var empty_motion_metrics: Dictionary = coordinator.get_metrics(true)
	var legacy_pair_upper_bound := (
		PLAYER_CENTERED_BROADPHASE_ENEMY_COUNT
		* PLAYER_CENTERED_BROADPHASE_PLAYER_COUNT
	)
	_expect(
		int(empty_motion_metrics["indexed_touch_player_index_queries"])
			== PLAYER_CENTERED_BROADPHASE_PLAYER_COUNT,
		"Two hundred normal movers must issue exactly one spatial-index query per living Player."
	)
	_expect(
		int(empty_motion_metrics["indexed_touch_player_aabb_pair_checks"])
			< legacy_pair_upper_bound / 10
		and int(empty_motion_metrics["indexed_touch_player_slow_path_movers"])
			== 0,
		"The common empty-contact frame must eliminate the Enemy x Player full pair path."
	)
	player_centered_broadphase_report = {
		"enemies": PLAYER_CENTERED_BROADPHASE_ENEMY_COUNT,
		"players": PLAYER_CENTERED_BROADPHASE_PLAYER_COUNT,
		"legacy_pair_upper_bound_per_tick": legacy_pair_upper_bound,
		"index_queries": int(
			empty_motion_metrics["indexed_touch_player_index_queries"]
		),
		"index_candidates": int(
			empty_motion_metrics["indexed_touch_player_index_candidates"]
		),
		"aabb_pair_checks": int(
			empty_motion_metrics["indexed_touch_player_aabb_pair_checks"]
		),
		"aabb_pair_hits": int(
			empty_motion_metrics["indexed_touch_player_aabb_pair_hits"]
		),
		"slow_path_movers": int(
			empty_motion_metrics["indexed_touch_player_slow_path_movers"]
		),
		"automatic_stress_ticks": PLAYER_CENTERED_PERFORMANCE_TICKS,
		"full_host_physics_percentiles": "requires_profiler_host_matrix",
		"coordinator_p50_ms": (
			float(_percentile_nearest_rank(coordinator_usec_samples, 0.50))
			/ 1000.0
		),
		"coordinator_p95_ms": (
			float(_percentile_nearest_rank(coordinator_usec_samples, 0.95))
			/ 1000.0
		),
		"coordinator_p99_ms": (
			float(_percentile_nearest_rank(coordinator_usec_samples, 0.99))
			/ 1000.0
		),
		"profile_contact_setup_ms_per_tick": (
			float(coordinator_profile_metrics["profile_contact_setup_usec"])
			/ float(PLAYER_CENTERED_PERFORMANCE_TICKS)
			/ 1000.0
		),
		"profile_indexed_player_refresh_ms_per_tick": (
			float(
				coordinator_profile_metrics[
					"profile_indexed_player_refresh_usec"
				]
			)
			/ float(PLAYER_CENTERED_PERFORMANCE_TICKS)
			/ 1000.0
		),
		"profile_indexed_dirty_drain_ms_per_tick": (
			float(
				coordinator_profile_metrics[
					"profile_indexed_dirty_drain_usec"
				]
			)
			/ float(PLAYER_CENTERED_PERFORMANCE_TICKS)
			/ 1000.0
		),
		"profile_motion_ms_per_tick": (
			float(coordinator_profile_metrics["profile_motion_phase_usec"])
			/ float(PLAYER_CENTERED_PERFORMANCE_TICKS)
			/ 1000.0
		),
	}

	var teleported_enemy := enemies[0]
	teleported_enemy.global_position = players[0].global_position
	await _manual_coordinator_tick(coordinator)
	var teleport_metrics: Dictionary = coordinator.get_metrics(true)
	_expect(
		int(teleport_metrics["indexed_touch_player_slow_path_movers"]) >= 1
		and int(teleport_metrics["indexed_touch_player_aabb_pair_hits"]) >= 1
		and int(teleport_metrics["indexed_touch_player_exact_shape_hits"])
			== PLAYER_CENTERED_BROADPHASE_PLAYER_COUNT
		and int(teleport_metrics["indexed_touch_contact_enters"])
			== PLAYER_CENTERED_BROADPHASE_PLAYER_COUNT,
		"A teleport must use the explicit all-Player slow path and publish every exact overlap in the same tick."
	)
	_expect(
		teleported_enemy.touched_player == players[0],
		"Five overlapping Players must retain deterministic lowest-peer selection."
	)

	var first_hit_health := players[0].current_health
	var cooldown_deadline := (
		teleported_enemy.get_touch_damage_cooldown_deadline_physics_frame()
	)
	_expect(
		cooldown_deadline
			- teleported_enemy.touch_damage_cooldown_started_physics_frame
			== 31,
		"The authored 0.5 second cooldown must preserve legacy tick-31 readiness."
	)
	var far_position := Vector2(4096.0, 2048.0)
	teleported_enemy.global_position = far_position
	await _manual_coordinator_tick(coordinator)
	var exit_metrics: Dictionary = coordinator.get_metrics(true)
	_expect(
		int(exit_metrics["indexed_touch_contact_exits"])
			== PLAYER_CENTERED_BROADPHASE_PLAYER_COUNT
		and teleported_enemy.indexed_touch_player_snapshot_is_empty()
		and teleported_enemy.get_touch_damage_cooldown_deadline_physics_frame()
			== cooldown_deadline,
		"EXIT must resume movement membership without cancelling the accepted-hit cooldown deadline."
	)

	teleported_enemy.global_position = players[0].global_position
	await _manual_coordinator_tick(coordinator)
	var reentry_metrics: Dictionary = coordinator.get_metrics(true)
	_expect(
		int(reentry_metrics["indexed_touch_contact_enters"])
			== PLAYER_CENTERED_BROADPHASE_PLAYER_COUNT
		and players[0].current_health == first_hit_health,
		"Re-entry during cooldown must update exact membership without duplicate damage."
	)

	while Engine.get_physics_frames() < cooldown_deadline:
		if Engine.get_physics_frames() + 1 >= cooldown_deadline:
			players[0].invincibility_time_left = 0.0
		await _manual_coordinator_tick(coordinator)
	var deadline_metrics: Dictionary = coordinator.get_metrics(true)
	_expect(
		int(deadline_metrics["touch_cooldown_deadline_wakes"]) == 1
		and int(deadline_metrics["touch_damage_attempts"]) == 1
		and int(deadline_metrics["touch_damage_accepted"]) == 1
		and int(deadline_metrics["touch_damage_rejected"]) == 0
		and players[0].current_health < first_hit_health,
		(
			"The default 0.5 second cooldown must wake exactly once on authored tick 31 and settle one accepted hit; deadline=%d frame=%d health=%d->%d metrics=%s."
			% [
				cooldown_deadline,
				Engine.get_physics_frames(),
				first_hit_health,
				players[0].current_health,
				deadline_metrics,
			]
		)
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


func _percentile_nearest_rank(
	sorted_samples: Array[int],
	percentile: float
) -> int:
	if sorted_samples.is_empty():
		return 0
	var rank := clampi(
		ceili(clampf(percentile, 0.0, 1.0) * float(sorted_samples.size())) - 1,
		0,
		sorted_samples.size() - 1
	)
	return sorted_samples[rank]


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
