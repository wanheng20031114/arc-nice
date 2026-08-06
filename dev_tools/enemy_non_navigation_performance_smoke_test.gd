extends SceneTree

const TOWER_SCENE := preload("res://scene/game_modes/tower_defense/tower_defense_game.tscn")
const PICKUP_SCENE := preload("res://scene/pickup.tscn")
const PICKUP_CONFIG := preload("res://resources/config/pickups/pickup_health.tres")
const EXPECTED_ENEMY_COUNT := 300
const WARMUP_PHYSICS_FRAMES := 30
const SAMPLE_PHYSICS_FRAMES := 180
const METHOD_BENCHMARK_ITERATIONS := 600
const LEGACY_PICKUP_SCAN_BENCHMARK_ITERATIONS := 12
const DAMAGE_MULTIPLIER_BENCHMARK_ITERATIONS := 120000

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var game := TOWER_SCENE.instantiate() as TowerDefenseGame
	_expect(game != null, "Non-navigation fixture must instantiate tower defense.")
	if game == null:
		await _finish(null)
		return
	game.auto_start_waves = false
	root.add_child(game)
	current_scene = game
	await process_frame
	await physics_frame

	game.call("_schedule_enemy_navigation_prewarm")
	var preparation_deadline := Time.get_ticks_msec() + 30000
	while not game.is_runtime_preparation_complete() and Time.get_ticks_msec() < preparation_deadline:
		await process_frame
	_expect(
		game.is_runtime_preparation_complete(),
		"Non-navigation fixture must finish staged runtime preparation."
	)
	if game.waves.is_empty():
		await _finish(game)
		return

	game.call("_begin_flow_step", game.waves[0])
	game.enemy_spawn_timer.stop()
	for _spawn_index in range(EXPECTED_ENEMY_COUNT):
		game.enemy_coordinator.spawn_wave_batch(
			TowerDefenseCampaignCoordinator.MAX_WAVE_SPAWN_COUNT_PER_TICK
		)
	game.set_physics_process(false)

	var enemies: Array[Enemy] = []
	for child in game.enemy_container.get_children():
		var enemy := child as Enemy
		if enemy == null or enemy.is_dead:
			continue
		enemy.set_objective_target(null)
		enemy.set_pathfinder(null)
		enemy.velocity = Vector2.ZERO
		enemies.append(enemy)
	_expect(
		enemies.size() == EXPECTED_ENEMY_COUNT,
		"Non-navigation fixture must hold exactly 300 live enemies."
	)

	_verify_cached_move_speed(enemies)
	_verify_cached_damage_taken_multiplier(enemies)
	_verify_empty_touch_fast_path(enemies)
	_verify_segmented_enemy_metrics(enemies)
	_verify_source_allocation_contract()
	await _verify_event_driven_pickup_registration(game)
	var method_benchmark := _benchmark_idle_methods(enemies)
	var legacy_pickup_scan_benchmark := _benchmark_legacy_pickup_scan(game)

	var frame_samples_ms: Array[float] = await _sample_physics_frames()
	var p50_ms: float = _percentile(frame_samples_ms, 0.50)
	var p95_ms: float = _percentile(frame_samples_ms, 0.95)
	var maximum_ms: float = frame_samples_ms.back() if not frame_samples_ms.is_empty() else 0.0
	for enemy in enemies:
		enemy.set_physics_process(false)
	var passive_samples_ms: Array[float] = await _sample_physics_frames()
	var passive_p50_ms := _percentile(passive_samples_ms, 0.50)
	var passive_p95_ms := _percentile(passive_samples_ms, 0.95)
	var avoided_empty_array_allocations_per_second: int = (
		enemies.size() * Engine.physics_ticks_per_second * 2
	)
	var runtime_node_count := _count_nodes_recursive(game)
	var eliminated_pickup_scan_node_visits_per_second := (
		runtime_node_count * Engine.physics_ticks_per_second
	)
	print(
		(
			"ENEMY_NON_NAVIGATION_PERFORMANCE enemies=%d frames=%d p50_ms=%.3f "
			+ "p95_ms=%.3f max_ms=%.3f passive_p50_ms=%.3f passive_p95_ms=%.3f "
			+ "active_minus_passive_p50_ms=%.3f speed_calls=%d speed_ms=%.3f "
			+ "touch_calls=%d touch_ms=%.3f avoided_empty_arrays_per_second=%d "
			+ "runtime_nodes=%d eliminated_pickup_scan_node_visits_per_second=%d "
			+ "legacy_pickup_scan_ms_each=%.3f legacy_scan_cpu_ms_per_second=%.3f"
		)
		% [
			enemies.size(),
			SAMPLE_PHYSICS_FRAMES,
			p50_ms,
			p95_ms,
			maximum_ms,
			passive_p50_ms,
			passive_p95_ms,
			maxf(p50_ms - passive_p50_ms, 0.0),
			int(method_benchmark["speed_calls"]),
			float(method_benchmark["speed_ms"]),
			int(method_benchmark["touch_calls"]),
			float(method_benchmark["touch_ms"]),
			avoided_empty_array_allocations_per_second,
			runtime_node_count,
			eliminated_pickup_scan_node_visits_per_second,
			float(legacy_pickup_scan_benchmark["per_scan_ms"]),
			float(legacy_pickup_scan_benchmark["estimated_cpu_ms_per_second"]),
		]
	)
	_expect(p95_ms < 35.0, "300 enemies without navigation must keep p95 below 35 ms.")
	await _finish(game)


func _benchmark_idle_methods(enemies: Array[Enemy]) -> Dictionary:
	var speed_checksum := 0.0
	var speed_started_usec := Time.get_ticks_usec()
	for _iteration in range(METHOD_BENCHMARK_ITERATIONS):
		for enemy in enemies:
			speed_checksum += enemy.get_effective_move_speed()
	var speed_elapsed_ms := float(Time.get_ticks_usec() - speed_started_usec) / 1000.0

	var touch_started_usec := Time.get_ticks_usec()
	for _iteration in range(METHOD_BENCHMARK_ITERATIONS):
		for enemy in enemies:
			enemy.call("_update_touch_damage", 1.0 / 60.0)
	var touch_elapsed_ms := float(Time.get_ticks_usec() - touch_started_usec) / 1000.0
	_expect(speed_checksum > 0.0, "Move-speed benchmark checksum must remain positive.")
	return {
		"speed_calls": enemies.size() * METHOD_BENCHMARK_ITERATIONS,
		"speed_ms": speed_elapsed_ms,
		"touch_calls": enemies.size() * METHOD_BENCHMARK_ITERATIONS,
		"touch_ms": touch_elapsed_ms,
	}


func _benchmark_legacy_pickup_scan(game: TowerDefenseGame) -> Dictionary:
	var started_usec := Time.get_ticks_usec()
	for _iteration in range(LEGACY_PICKUP_SCAN_BENCHMARK_ITERATIONS):
		var pickups: Array[Pickup] = []
		game.call("_collect_pickups_recursive", game, pickups)
	var elapsed_ms := float(Time.get_ticks_usec() - started_usec) / 1000.0
	var per_scan_ms := elapsed_ms / float(LEGACY_PICKUP_SCAN_BENCHMARK_ITERATIONS)
	return {
		"per_scan_ms": per_scan_ms,
		"estimated_cpu_ms_per_second": per_scan_ms * Engine.physics_ticks_per_second,
	}


func _sample_physics_frames() -> Array[float]:
	for _warmup_index in range(WARMUP_PHYSICS_FRAMES):
		await physics_frame
	var samples_ms: Array[float] = []
	var previous_tick_usec := Time.get_ticks_usec()
	for _sample_index in range(SAMPLE_PHYSICS_FRAMES):
		await physics_frame
		var current_tick_usec := Time.get_ticks_usec()
		samples_ms.append(float(current_tick_usec - previous_tick_usec) / 1000.0)
		previous_tick_usec = current_tick_usec
	samples_ms.sort()
	return samples_ms


func _verify_cached_move_speed(enemies: Array[Enemy]) -> void:
	if enemies.is_empty():
		return
	var enemy := enemies[0]
	var base_speed := enemy.config.move_speed
	_expect(
		is_equal_approx(enemy.get_effective_move_speed(), base_speed),
		"Cached effective speed must initially match EnemyConfig."
	)
	enemy.add_move_speed_modifier(900001, 0.5)
	enemy.add_move_speed_modifier(900002, 1.2)
	_expect(
		is_equal_approx(enemy.get_effective_move_speed(), base_speed * 0.6),
		"Cached effective speed must refresh after modifier insertion."
	)
	enemy.remove_move_speed_modifier(900001)
	_expect(
		is_equal_approx(enemy.get_effective_move_speed(), base_speed * 1.2),
		"Cached effective speed must refresh after modifier removal."
	)
	enemy.remove_move_speed_modifier(900002)


func _verify_cached_damage_taken_multiplier(enemies: Array[Enemy]) -> void:
	if enemies.size() < 2:
		return
	var enemy := enemies[1]
	var source_ids: Array[int] = []
	for modifier_index in range(8):
		var source_id := 910000 + modifier_index
		source_ids.append(source_id)
		enemy.add_damage_taken_multiplier_modifier(
			source_id,
			1.02 + float(modifier_index) * 0.01
		)
	var expected_multiplier := _calculate_legacy_damage_taken_multiplier(enemy)
	_expect(
		is_equal_approx(enemy.get_damage_taken_multiplier(), expected_multiplier),
		"Cached damage multiplier must match the legacy product after insertion."
	)
	enemy.add_damage_taken_multiplier_modifier(source_ids[3], 1.25)
	expected_multiplier = _calculate_legacy_damage_taken_multiplier(enemy)
	_expect(
		is_equal_approx(enemy.get_damage_taken_multiplier(), expected_multiplier),
		"Cached damage multiplier must refresh after same-source replacement."
	)
	enemy.remove_damage_taken_multiplier_modifier(source_ids[5])
	expected_multiplier = _calculate_legacy_damage_taken_multiplier(enemy)
	_expect(
		is_equal_approx(enemy.get_damage_taken_multiplier(), expected_multiplier),
		"Cached damage multiplier must refresh after removal."
	)

	var cached_checksum := 0.0
	var cached_started_usec := Time.get_ticks_usec()
	for _iteration in range(DAMAGE_MULTIPLIER_BENCHMARK_ITERATIONS):
		cached_checksum += enemy.get_damage_taken_multiplier()
	var cached_elapsed_usec := Time.get_ticks_usec() - cached_started_usec
	var legacy_checksum := 0.0
	var legacy_started_usec := Time.get_ticks_usec()
	for _iteration in range(DAMAGE_MULTIPLIER_BENCHMARK_ITERATIONS):
		legacy_checksum += _calculate_legacy_damage_taken_multiplier(enemy)
	var legacy_elapsed_usec := Time.get_ticks_usec() - legacy_started_usec
	_expect(
		is_equal_approx(cached_checksum, legacy_checksum),
		"Cached and legacy damage-multiplier A/B checksums must remain identical."
	)
	_expect(
		cached_elapsed_usec < legacy_elapsed_usec,
		"O(1) damage-multiplier reads must outperform repeated dictionary products."
	)
	print(
		"DAMAGE_MULTIPLIER_CACHE_AB reads=%d modifiers=%d cached_ms=%.3f legacy_ms=%.3f speedup=%.2fx"
		% [
			DAMAGE_MULTIPLIER_BENCHMARK_ITERATIONS,
			enemy.damage_taken_multiplier_modifiers.size(),
			float(cached_elapsed_usec) / 1000.0,
			float(legacy_elapsed_usec) / 1000.0,
			float(legacy_elapsed_usec) / maxf(float(cached_elapsed_usec), 1.0),
		]
	)
	for source_id in source_ids:
		enemy.remove_damage_taken_multiplier_modifier(source_id)
	_expect(
		is_equal_approx(enemy.get_damage_taken_multiplier(), 1.0),
		"Removing all damage modifiers must restore the cached neutral multiplier."
	)


func _calculate_legacy_damage_taken_multiplier(enemy: Enemy) -> float:
	var total := 1.0
	for source_id in enemy.damage_taken_multiplier_modifiers:
		total *= maxf(
			float(enemy.damage_taken_multiplier_modifiers[source_id]),
			0.0
		)
	return maxf(total, 0.0)


func _verify_empty_touch_fast_path(enemies: Array[Enemy]) -> void:
	if enemies.size() < 2:
		return
	var enemy := enemies[1]
	_expect(
		enemy.touching_players.is_empty() and enemy.touching_plants.is_empty(),
		"Touch fast-path fixture must start without contacts."
	)
	var saved_metrics_enabled := Enemy.performance_metrics_enabled
	Enemy.set_performance_metrics_enabled(true)
	enemy.touch_damage_cooldown_left = 0.0
	enemy.touched_player = enemy.target_player
	enemy.call("_update_touch_damage", 0.1)
	var idle_metrics := Enemy.get_performance_metrics()
	_expect(
		int(idle_metrics.get("touch_damage_calls", -1)) == 0
		and enemy.touched_player == null
		and enemy.touched_plant == null,
		"Zero-cooldown enemies without contacts must return before touch-damage profiling."
	)
	enemy.touch_damage_cooldown_left = 0.2
	enemy.call("_update_touch_damage", 0.1)
	var cooldown_metrics := Enemy.get_performance_metrics()
	_expect(
		is_equal_approx(enemy.touch_damage_cooldown_left, 0.1)
		and enemy.touched_player == null
		and enemy.touched_plant == null
		and int(cooldown_metrics.get("touch_damage_calls", 0)) == 1,
		"Empty-contact fast path must still advance cooldown without inventing contacts."
	)
	Enemy.set_performance_metrics_enabled(saved_metrics_enabled)


func _verify_source_allocation_contract() -> void:
	var source := FileAccess.get_file_as_string("res://scene/enemy/enemy.gd")
	_expect(
		not source.contains("move_speed_modifiers.values()"),
		"Per-frame effective speed must not allocate Dictionary.values arrays."
	)
	_expect(
		not source.contains("touching_plants.keys()"),
		"Touch selection must not allocate Dictionary.keys arrays."
	)
	_expect(
		source.contains("cached_effective_move_speed"),
		"Enemy must cache effective move speed between modifier changes."
	)
	_expect(
		source.contains("cached_damage_taken_multiplier"),
		"Enemy must cache incoming damage multipliers between status changes."
	)
	var movement_function_offset := source.find("func _move_until_player_contact()")
	var zero_velocity_guard_offset := source.find(
		"if velocity == Vector2.ZERO:",
		movement_function_offset
	)
	var contact_guard_offset := source.find(
		"if _has_player_contact():",
		movement_function_offset
	)
	_expect(
		movement_function_offset >= 0
		and zero_velocity_guard_offset > movement_function_offset
		and contact_guard_offset > zero_velocity_guard_offset,
		"Zero-velocity movement must return before scanning player or plant contacts."
	)
	for registry_source_path in [
		"res://scene/combat/pickup/pickup_registry_base.gd",
	]:
		var registry_source := FileAccess.get_file_as_string(registry_source_path)
		_expect(
			not registry_source.contains("func _physics_process"),
			"Pickup registries must not poll the full scene tree from physics: %s"
			% registry_source_path
		)
		_expect(
			registry_source.contains("child_entered_tree.connect("),
			"Pickup registry must use dynamic-container enter events: %s"
			% registry_source_path
		)
	var tower_runtime_source := FileAccess.get_file_as_string(
		"res://scene/game_modes/tower_defense/tower_defense_game.gd"
	)
	_expect(
		tower_runtime_source.count("_register_dynamic_multiplayer_pickups()") == 1,
		"Tower runtime physics must not poll the full scene tree for pickups."
	)
	_expect(
		tower_runtime_source.contains("enemy_container.child_entered_tree.connect("),
		"Tower runtime must register dynamic pickups from EnemyContainer events."
	)


func _verify_segmented_enemy_metrics(enemies: Array[Enemy]) -> void:
	if enemies.size() < 3:
		return
	var enemy := enemies[2]
	Enemy.set_performance_metrics_enabled(true)
	Enemy.reset_performance_metrics()
	enemy.touch_damage_cooldown_left = 0.1
	enemy.call("_update_touch_damage", 1.0 / 60.0)
	enemy.call("_get_safe_navigation_move_direction", null, null, 1.0)
	enemy.call("_test_navigation_motion", enemy.global_transform, Vector2.ZERO)
	var position_before := enemy.global_position
	enemy.velocity = Vector2.RIGHT
	enemy.call("_move_until_player_contact")
	enemy.velocity = Vector2.ZERO
	var metrics := Enemy.get_performance_metrics()
	Enemy.set_performance_metrics_enabled(false)
	enemy.touch_damage_cooldown_left = 0.0
	_expect(
		int(metrics.get("touch_damage_calls", 0)) == 1,
		"Opt-in enemy telemetry must count touch-damage segments exactly."
	)
	_expect(
		int(metrics.get("navigation_calls", 0)) == 1,
		"Opt-in enemy telemetry must count navigation segments exactly."
	)
	_expect(
		int(metrics.get("test_move_calls", 0)) == 1,
		"Opt-in enemy telemetry must count test_move segments exactly."
	)
	_expect(
		int(metrics.get("move_and_slide_calls", 0)) == 1,
		"Opt-in enemy telemetry must count CharacterBody movement segments exactly."
	)
	_expect(
		enemy.global_position != position_before,
		"Segmented movement telemetry must preserve the measured CharacterBody step."
	)
	for key in [
		"touch_damage_usec",
		"navigation_usec",
		"test_move_usec",
		"move_and_slide_usec",
	]:
		_expect(
			int(metrics.get(key, -1)) >= 0,
			"Opt-in enemy telemetry must expose non-negative %s." % key
		)


func _verify_event_driven_pickup_registration(game: TowerDefenseGame) -> void:
	var original_mode := game.runtime_mode
	game.runtime_mode = CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY
	var pickup := PICKUP_SCENE.instantiate() as Pickup
	_expect(pickup != null, "Event-driven pickup fixture must instantiate Pickup.")
	if pickup == null:
		game.runtime_mode = original_mode
		return
	pickup.config = PICKUP_CONFIG
	game.enemy_container.add_child(pickup)
	pickup.global_position = Vector2(10000.0, 9000.0)
	await process_frame
	var net_id := int(pickup.get_meta("net_id", 0))
	_expect(
		net_id >= 1000
		and game.multiplayer_pickups.get(net_id) == pickup
		and pickup.global_position == Vector2(10000.0, 9000.0),
		"EnemyContainer child events must register the finalized pickup exactly once."
	)
	pickup.queue_free()
	await process_frame
	game.runtime_mode = original_mode


func _percentile(sorted_samples: Array[float], ratio: float) -> float:
	if sorted_samples.is_empty():
		return 0.0
	var rank := ceili(clampf(ratio, 0.0, 1.0) * sorted_samples.size())
	return sorted_samples[clampi(rank - 1, 0, sorted_samples.size() - 1)]


func _count_nodes_recursive(node: Node) -> int:
	var count := 1
	for child in node.get_children():
		count += _count_nodes_recursive(child)
	return count


func _finish(game: TowerDefenseGame) -> void:
	current_scene = null
	if game != null:
		game.queue_free()
	for _cleanup_index in range(6):
		await process_frame
		await physics_frame
	if failures.is_empty():
		print("ENEMY_NON_NAVIGATION_PERFORMANCE_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
