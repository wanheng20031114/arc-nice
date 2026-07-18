extends SceneTree

# Integrated regression probe for the reported high-pressure hitch: a real
# GameTowerDefense scene, live pathfinding enemies, real Corn/Agave/Bamboo
# plants, pooled projectiles/effects and the production follow camera all run
# together.
#
# Run with --headless --fixed-fps 60. Timings are diagnostic rather than tied
# to a machine-specific pass threshold; semantic and lifecycle invariants are
# the regression gates.
const TOWER_SCENE := preload("res://scene/game_tower_defense.tscn")
const BASIC_ENEMY_CONFIG := preload(
	"res://resources/config/enemies/yuanshi_insect_basic.tres"
)
const SHELL_ENEMY_CONFIG := preload(
	"res://resources/config/enemies/yuanshi_insect_shell.tres"
)
const CORN_CONFIG := preload(
	"res://resources/config/plant_defense/corn_machine_gun.tres"
)
const AGAVE_CONFIG := preload(
	"res://resources/config/plant_defense/agave_cannon.tres"
)
const BAMBOO_MORTAR_CONFIG := preload(
	"res://resources/config/plant_defense/bamboo_mortar.tres"
)
const AGAVE_CANNONBALL_SCENE := preload(
	"res://scene/plant_defense/agave_cannonball.tscn"
)
const BAMBOO_MORTAR_SHELL_SCENE := preload(
	"res://scene/plant_defense/bamboo_mortar_shell.tscn"
)
const ENEMY_HIT_EFFECT_SCENE := preload(
	"res://scene/enemy/enemy_hit_effect.tscn"
)

const ENEMY_COUNT := 300
const BASIC_ENEMY_COUNT := 240
const SHELL_ENEMY_COUNT := ENEMY_COUNT - BASIC_ENEMY_COUNT
const CORN_TOWER_COUNT := 64
const AGAVE_TOWER_COUNT := 32
const BAMBOO_MORTAR_COUNT := 32
const TOTAL_TOWER_COUNT := (
	CORN_TOWER_COUNT + AGAVE_TOWER_COUNT + BAMBOO_MORTAR_COUNT
)
const FIXTURE_CENTER := Vector2(512.0, 352.0)
const FIXED_SEED := 20260715
const PROBE_ENEMY_HEALTH := 1_000_000_000
const PROBE_PLANT_HEALTH := 1_000_000_000
const INITIAL_WARMUP_FRAMES := 180
const PHASE_WARMUP_FRAMES := 60
const SAMPLE_FRAMES := 240
const SYNCHRONIZED_SAMPLE_FRAMES := 180
const QUIESCE_FRAMES := 120
const MOVEMENT_SWITCH_PHYSICS_FRAMES := 75
const CLEANUP_FRAMES := 12

var failures: Array[String] = []
var game: GameTowerDefense = null
var pathfinder: GridPathfinder = null
var enemies: Array[Enemy] = []
var initial_enemy_positions := PackedVector2Array()
var corn_towers: Array[CornMachineGun] = []
var agave_towers: Array[AgaveCannon] = []
var bamboo_mortars: Array[BambooMortar] = []
var tower_cells: Array[Vector2i] = []
var forbidden_enemy_cells: Dictionary[Vector2i, bool] = {}
var phase_results: Dictionary = {}
var all_stationary_wall_samples: Array[float] = []
var all_moving_wall_samples: Array[float] = []
var movement_enabled := false
var movement_start_physics_frame := 0
var movement_direction := 0
var original_max_fps := 0


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	original_max_fps = Engine.max_fps
	Engine.max_fps = 0
	seed(FIXED_SEED)

	game = TOWER_SCENE.instantiate() as GameTowerDefense
	_expect(game != null, "Combined stress probe must instantiate GameTowerDefense.")
	if game == null:
		await _finish()
		return
	game.auto_start_waves = false
	game.random_generator.seed = FIXED_SEED
	root.add_child(game)
	current_scene = game
	await process_frame
	await physics_frame

	pathfinder = game.grid_pathfinder as GridPathfinder
	_expect(pathfinder != null and pathfinder.is_built, "Production GridPathfinder must be ready.")
	if pathfinder == null or not pathfinder.is_built:
		await _finish()
		return
	_stop_background_flow_timers()
	_prepare_player_and_camera()
	_build_tower_fixture()
	_spawn_live_enemies()
	_prewarm_enemy_profiles()
	_expect(corn_towers.size() == CORN_TOWER_COUNT, "Fixture must create 64 Corn towers.")
	_expect(agave_towers.size() == AGAVE_TOWER_COUNT, "Fixture must create 32 Agave towers.")
	_expect(
		bamboo_mortars.size() == BAMBOO_MORTAR_COUNT,
		"Fixture must create 32 Bamboo Mortars."
	)
	_expect(enemies.size() == ENEMY_COUNT, "Fixture must create 300 live enemies.")
	_expect(
		game.combat_target_index.enemies_by_net_id.size() == ENEMY_COUNT,
		"Every real enemy must be registered in the production CombatTargetIndex."
	)
	if (
		corn_towers.size() != CORN_TOWER_COUNT
		or agave_towers.size() != AGAVE_TOWER_COUNT
		or bamboo_mortars.size() != BAMBOO_MORTAR_COUNT
		or enemies.size() != ENEMY_COUNT
	):
		await _finish()
		return

	# Populate the real pools and native physics caches before taking the stable
	# node/pool baseline. No test-only targeting or hitscan loop is substituted.
	await _reset_fixture(false)
	await _advance_frames(INITIAL_WARMUP_FRAMES)
	await _quiesce_fixture()
	# A second short cycle lets authored one-shot presentation helpers settle;
	# the retained gameplay pools are already hot from the first cycle.
	await _reset_fixture(false)
	await _advance_frames(PHASE_WARMUP_FRAMES)
	await _quiesce_fixture()
	var stable_node_baseline := _count_subtree_nodes(game)
	var stable_pool_baseline := _capture_relevant_pool_metrics()

	print(
		(
			"COMBINED_HORDE_TURRET_FIXTURE enemies=%d basic=%d shell=%d "
			+ "towers=%d corn=%d agave=%d bamboo=%d samples=%d warmup=%d "
			+ "physics_hz=%d renderer=%s nodes=%d pools=%s"
		)
		% [
			enemies.size(),
			BASIC_ENEMY_COUNT,
			SHELL_ENEMY_COUNT,
			TOTAL_TOWER_COUNT,
			corn_towers.size(),
			agave_towers.size(),
			bamboo_mortars.size(),
			SAMPLE_FRAMES,
			PHASE_WARMUP_FRAMES,
			Engine.physics_ticks_per_second,
			RenderingServer.get_current_rendering_method(),
			stable_node_baseline,
			_format_relevant_pool_metrics(stable_pool_baseline),
		]
	)
	if DisplayServer.get_name() == "headless":
		print(
			"COMBINED_HORDE_TURRET_NOTE headless GPUParticles2D does not "
			+ "advance the render-backed finished signal; EnemyHitEffect metrics "
			+ "are reported for transparency but excluded from lifecycle gates."
		)

	# Counterbalanced hot phases reduce ordering bias without turning timing into
	# a brittle machine-specific assertion.
	await _measure_phase("stationary_a", false)
	await _measure_phase("moving_a", true)
	await _measure_phase("moving_b", true)
	await _measure_phase("stationary_b", false)
	await _measure_synchronized_corn_peak()
	await _measure_real_target_query_batch()
	await _measure_synchronized_corn_stage_attribution()

	await _quiesce_fixture()
	var stable_node_final := _count_subtree_nodes(game)
	var stable_pool_final := _capture_relevant_pool_metrics()
	var stationary_summary := _summarize(all_stationary_wall_samples)
	var moving_summary := _summarize(all_moving_wall_samples)
	var stationary_p50 := float(stationary_summary["p50"])
	var moving_p50 := float(moving_summary["p50"])
	var stationary_p95 := float(stationary_summary["p95"])
	var moving_p95 := float(moving_summary["p95"])
	var total_target_locks := 0
	var total_hitscan_rays := 0
	var total_bamboo_fires := 0
	for phase_result_variant in phase_results.values():
		var phase_result := phase_result_variant as Dictionary
		total_target_locks += int(phase_result.get("corn_target_locks", 0))
		total_hitscan_rays += int(phase_result.get("corn_hitscan_rays", 0))
		total_bamboo_fires += int(phase_result.get("bamboo_fires", 0))

	print(
		(
			"COMBINED_HORDE_TURRET_SUMMARY stationary_wall_ms=%s moving_wall_ms=%s "
			+ "movement_increment_p50_ms=%.3f movement_increment_p95_ms=%.3f "
			+ "movement_ratio_p50=%.3f corn_target_locks=%d corn_hitscan_rays=%d "
			+ "bamboo_fires=%d nodes_stable=%d/%d index_size=%d pools_final=%s"
		)
		% [
			_format_summary(stationary_summary),
			_format_summary(moving_summary),
			moving_p50 - stationary_p50,
			moving_p95 - stationary_p95,
			moving_p50 / maxf(stationary_p50, 0.001),
			total_target_locks,
			total_hitscan_rays,
			total_bamboo_fires,
			stable_node_baseline,
			stable_node_final,
			game.combat_target_index.enemies_by_net_id.size(),
			_format_relevant_pool_metrics(stable_pool_final),
		]
	)

	_expect(
		stable_node_final <= stable_node_baseline,
		"A fully drained repeated stress run must not grow the real scene tree."
	)
	_expect(
		_relevant_pool_created_counts_match(stable_pool_baseline, stable_pool_final),
		"Relevant retained pools must stop growing after their integrated warmup."
	)
	_expect(
		_gameplay_projectile_pool_outstanding(stable_pool_final) == 0,
		"Agave and Bamboo gameplay projectiles must fully return after quiescing."
	)
	_expect(
		game.combat_target_index.enemies_by_net_id.size() == ENEMY_COUNT,
		"CombatTargetIndex membership must remain stable across all phases."
	)
	_expect(
		total_bamboo_fires > 0,
		"Integrated phases must complete at least one real Bamboo Mortar launch."
	)
	_expect(_count_alive_enemies() == ENEMY_COUNT, "No stress-fixture enemy may die.")
	_expect(_count_alive_towers() == TOTAL_TOWER_COUNT, "No stress-fixture tower may die.")

	await _finish()


func _stop_background_flow_timers() -> void:
	game.enemy_spawn_timer.stop()
	game.state_timer.stop()


func _prepare_player_and_camera() -> void:
	_expect(game.player != null, "Combined stress probe requires the real local player.")
	if game.player == null:
		return
	game.player.global_position = FIXTURE_CENTER
	game.player.velocity = Vector2.ZERO
	game.player.controls_locked = true
	game.player.uses_local_input = false
	game.player.max_health = PROBE_ENEMY_HEALTH
	game.player.current_health = PROBE_ENEMY_HEALTH
	game.player.is_dead = false
	game.player.reset_physics_interpolation()
	if game.map_camera != null:
		game.map_camera.position = Vector2.ZERO
		game.map_camera.position_smoothing_enabled = false
		game.map_camera.enabled = true
		game.map_camera.reset_physics_interpolation()


func _build_tower_fixture() -> void:
	var positions := _build_tower_positions()
	_expect(positions.size() >= TOTAL_TOWER_COUNT, "Map must provide 128 walkable tower cells.")
	if positions.size() < TOTAL_TOWER_COUNT:
		return
	var empty_footprint: Array[Vector2i] = []
	for tower_index in range(TOTAL_TOWER_COUNT):
		var tower_position := positions[tower_index]
		var tower_cell := pathfinder.call("_global_to_map", tower_position) as Vector2i
		tower_cells.append(tower_cell)
		for y_offset in range(-1, 2):
			for x_offset in range(-1, 2):
				forbidden_enemy_cells[tower_cell + Vector2i(x_offset, y_offset)] = true

		if tower_index < CORN_TOWER_COUNT:
			var corn := CORN_CONFIG.plant_scene.instantiate() as CornMachineGun
			if corn == null:
				continue
			game.plant_container.add_child(corn)
			corn.global_position = tower_position
			corn.set_meta(&"net_id", tower_index + 1)
			corn.setup(CORN_CONFIG, game.player, empty_footprint)
			corn.max_health = PROBE_PLANT_HEALTH
			corn.current_health = PROBE_PLANT_HEALTH
			corn.set_idle_aim_random_seed(FIXED_SEED + tower_index)
			corn.attack_timer.stop()
			corn.call("_cancel_burst", false)
			corn_towers.append(corn)
			continue

		if tower_index < CORN_TOWER_COUNT + AGAVE_TOWER_COUNT:
			var agave := AGAVE_CONFIG.plant_scene.instantiate() as AgaveCannon
			if agave == null:
				continue
			game.plant_container.add_child(agave)
			agave.global_position = tower_position
			agave.set_meta(&"net_id", tower_index + 1)
			agave.setup(AGAVE_CONFIG, game.player, empty_footprint)
			agave.max_health = PROBE_PLANT_HEALTH
			agave.current_health = PROBE_PLANT_HEALTH
			agave.set_idle_aim_random_seed(FIXED_SEED + tower_index)
			agave.attack_timer.stop()
			agave_towers.append(agave)
			continue

		var mortar := (
			BAMBOO_MORTAR_CONFIG.plant_scene.instantiate()
			as BambooMortar
		)
		if mortar == null:
			continue
		game.plant_container.add_child(mortar)
		mortar.global_position = tower_position
		mortar.set_meta(&"net_id", tower_index + 1)
		mortar.setup(
			BAMBOO_MORTAR_CONFIG,
			game.player,
			empty_footprint
		)
		mortar.max_health = PROBE_PLANT_HEALTH
		mortar.current_health = PROBE_PLANT_HEALTH
		mortar.attack_timer.stop()
		mortar.target_track_timer.stop()
		bamboo_mortars.append(mortar)


func _build_tower_positions() -> PackedVector2Array:
	var result := PackedVector2Array()
	var used_cells: Dictionary[Vector2i, bool] = {}
	var center_cell := pathfinder.call("_global_to_map", FIXTURE_CENTER) as Vector2i
	var preferred_rows: Array[int] = [-8, -6, -4, 4, 6, 8]
	for y_offset in preferred_rows:
		for x_offset in range(-15, 16, 2):
			var cell := center_cell + Vector2i(x_offset, y_offset)
			_append_walkable_cell_position(cell, used_cells, result)
			if result.size() >= TOTAL_TOWER_COUNT:
				return result

	# Authored blockers can remove a preferred cell. Deterministically fill from
	# the same battle area while preserving the player's central movement lane.
	for y_offset in range(-10, 11):
		if absi(y_offset) < 3:
			continue
		for x_offset in range(-18, 19):
			var cell := center_cell + Vector2i(x_offset, y_offset)
			_append_walkable_cell_position(cell, used_cells, result)
			if result.size() >= TOTAL_TOWER_COUNT:
				return result
	return result


func _append_walkable_cell_position(
	cell: Vector2i,
	used_cells: Dictionary[Vector2i, bool],
	result: PackedVector2Array
) -> void:
	if used_cells.has(cell):
		return
	if not pathfinder.astar_grid.is_in_boundsv(cell):
		return
	if pathfinder.astar_grid.is_point_solid(cell):
		return
	used_cells[cell] = true
	result.append(pathfinder.call("_map_to_global", cell) as Vector2)


func _spawn_live_enemies() -> void:
	var positions := _build_enemy_positions()
	_expect(positions.size() >= ENEMY_COUNT, "Map must provide 300 walkable enemy cells.")
	if positions.size() < ENEMY_COUNT:
		return
	for enemy_index in range(ENEMY_COUNT):
		var enemy_config: EnemyConfig = (
			BASIC_ENEMY_CONFIG
			if enemy_index < BASIC_ENEMY_COUNT
			else SHELL_ENEMY_CONFIG
		)
		var enemy := enemy_config.enemy_scene.instantiate() as Enemy
		if enemy == null:
			continue
		game.enemy_container.add_child(enemy)
		enemy.global_position = positions[enemy_index]
		enemy.setup(enemy_config, game.player, pathfinder)
		enemy.current_health = PROBE_ENEMY_HEALTH
		enemy.set_near_moving_target_direct_distance(
			GameTowerDefense.PLAYER_OBJECTIVE_AGGRO_RADIUS
		)
		enemy.material_drop_random_generator.seed = FIXED_SEED + enemy_index * 2 + 1
		var insect := enemy as YuanshiInsect
		if insect != null:
			insect.random_generator.seed = FIXED_SEED + enemy_index * 2 + 2
		enemy.reset_physics_interpolation()
		enemies.append(enemy)
		initial_enemy_positions.append(enemy.global_position)


func _build_enemy_positions() -> PackedVector2Array:
	var candidates := PackedVector2Array()
	var center_cell := pathfinder.call("_global_to_map", FIXTURE_CENTER) as Vector2i
	for y_offset in range(-12, 13):
		for x_offset in range(-20, 21):
			var cell := center_cell + Vector2i(x_offset, y_offset)
			if forbidden_enemy_cells.has(cell):
				continue
			if not pathfinder.astar_grid.is_in_boundsv(cell):
				continue
			if pathfinder.astar_grid.is_point_solid(cell):
				continue
			var world_position := pathfinder.call("_map_to_global", cell) as Vector2
			if world_position.distance_to(FIXTURE_CENTER) < 96.0:
				continue
			candidates.append(world_position)

	var shuffle_rng := RandomNumberGenerator.new()
	shuffle_rng.seed = FIXED_SEED
	for source_index in range(candidates.size() - 1, 0, -1):
		var target_index := shuffle_rng.randi_range(0, source_index)
		var temporary := candidates[source_index]
		candidates[source_index] = candidates[target_index]
		candidates[target_index] = temporary
	return candidates


func _prewarm_enemy_profiles() -> void:
	for enemy in enemies:
		if enemy.config == null:
			continue
		pathfinder.prewarm_agent_grid(
			enemy.get_configured_body_collision_half_extents(),
			enemy.config.terrain_traversal_types
		)


func _measure_phase(label: String, should_move: bool) -> void:
	await _reset_fixture(should_move)
	await _advance_frames(PHASE_WARMUP_FRAMES)

	var target_locks_before := _get_corn_target_lock_count()
	var hitscan_rays_before := _get_corn_hitscan_ray_count()
	var bamboo_fires_before := _get_bamboo_fire_count()
	var enemy_health_before := _get_total_enemy_health()
	var node_count_before := _count_subtree_nodes(game)
	var wall_samples: Array[float] = []
	var physics_samples: Array[float] = []
	var collision_pair_samples: Array[float] = []
	var previous_tick_usec := Time.get_ticks_usec()
	var previous_target_cell := _get_player_target_cell()
	var target_cell_transitions := 0
	var maximum_player_displacement := 0.0
	var flow_builds := 0
	var last_sampled_physics_frame := -1

	for _sample_index in range(SAMPLE_FRAMES):
		await physics_frame
		_drive_movement_input()
		var now_usec := Time.get_ticks_usec()
		wall_samples.append(float(now_usec - previous_tick_usec) / 1000.0)
		previous_tick_usec = now_usec
		physics_samples.append(
			Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
		)
		collision_pair_samples.append(
			Performance.get_monitor(Performance.PHYSICS_2D_COLLISION_PAIRS)
		)

		var target_cell := _get_player_target_cell()
		if target_cell != previous_target_cell:
			target_cell_transitions += 1
			previous_target_cell = target_cell
		maximum_player_displacement = maxf(
			maximum_player_displacement,
			game.player.global_position.distance_to(FIXTURE_CENTER)
		)

		var physics_frame_id := Engine.get_physics_frames()
		if physics_frame_id != last_sampled_physics_frame:
			last_sampled_physics_frame = physics_frame_id
			if pathfinder.flow_field_budget_frame == physics_frame_id:
				flow_builds += pathfinder.flow_field_builds_used_this_frame

	_release_movement_input()
	var target_locks := _get_corn_target_lock_count() - target_locks_before
	var hitscan_rays := _get_corn_hitscan_ray_count() - hitscan_rays_before
	var bamboo_fires := _get_bamboo_fire_count() - bamboo_fires_before
	var enemy_damage := enemy_health_before - _get_total_enemy_health()
	var node_count_live := _count_subtree_nodes(game)
	var pool_metrics_live := _capture_relevant_pool_metrics()
	var wall_summary := _summarize(wall_samples)
	var physics_summary := _summarize(physics_samples)
	var collision_summary := _summarize(collision_pair_samples)
	if should_move:
		all_moving_wall_samples.append_array(wall_samples)
	else:
		all_stationary_wall_samples.append_array(wall_samples)

	await _quiesce_fixture()
	var node_count_drained := _count_subtree_nodes(game)
	var pool_metrics_drained := _capture_relevant_pool_metrics()
	phase_results[label] = {
		"moving": should_move,
		"wall": wall_summary,
		"physics": physics_summary,
		"collision_pairs": collision_summary,
		"corn_target_locks": target_locks,
		"corn_hitscan_rays": hitscan_rays,
		"bamboo_fires": bamboo_fires,
		"enemy_damage": enemy_damage,
		"flow_builds": flow_builds,
		"target_cell_transitions": target_cell_transitions,
		"maximum_player_displacement": maximum_player_displacement,
		"nodes_before": node_count_before,
		"nodes_live": node_count_live,
		"nodes_drained": node_count_drained,
	}
	print(
		(
			"COMBINED_HORDE_TURRET_PHASE label=%s moving=%s wall_ms=%s "
			+ "physics_ms=%s collision_pairs=%s displacement=%.1f cell_transitions=%d "
			+ "flow_builds=%d corn_target_locks=%d corn_hitscan_rays=%d enemy_damage=%d "
			+ "bamboo_fires=%d nodes=%d/%d/%d pools_live=%s pools_drained=%s"
		)
		% [
			label,
			str(should_move),
			_format_summary(wall_summary),
			_format_summary(physics_summary),
			_format_summary(collision_summary),
			maximum_player_displacement,
			target_cell_transitions,
			flow_builds,
			target_locks,
			hitscan_rays,
			enemy_damage,
			bamboo_fires,
			node_count_before,
			node_count_live,
			node_count_drained,
			_format_relevant_pool_metrics(pool_metrics_live),
			_format_relevant_pool_metrics(pool_metrics_drained),
		]
	)

	if should_move:
		_expect(
			maximum_player_displacement >= 48.0 and target_cell_transitions >= 4,
			"%s must sustain real player movement across several navigation cells." % label
		)
	else:
		_expect(
			maximum_player_displacement <= 0.01 and target_cell_transitions == 0,
			"%s must keep the real player stationary." % label
		)
	_expect(target_locks > 0, "%s must acquire real targets with Corn towers." % label)
	_expect(hitscan_rays > 0, "%s must execute real Corn hitscan rays." % label)
	_expect(
		hitscan_rays
		<= (target_locks + CORN_TOWER_COUNT) * CORN_CONFIG.attack_burst_count,
		"%s may carry in at most one warmup burst per Corn tower." % label
	)
	_expect(
		hitscan_rays
		>= maxi(target_locks - CORN_TOWER_COUNT, 0) * CORN_CONFIG.attack_burst_count,
		"%s may leave at most one cutoff burst unfinished per Corn tower." % label
	)
	_expect(
		node_count_drained <= node_count_before,
		"%s must not grow its drained scene-tree size." % label
	)
	_expect(
		_gameplay_projectile_pool_outstanding(pool_metrics_drained) == 0,
		"%s must return all Agave and Bamboo gameplay projectiles." % label
	)


func _measure_synchronized_corn_peak() -> void:
	# This phase deliberately gives all 64 real AttackTimers the same initial
	# delay and repeat interval. It quantifies the exact worst case where every
	# tower queries and sort_custom runs in one frame instead of hiding that peak
	# behind the normal deterministic staggering used by the control phases.
	await _reset_fixture(true, true)
	var wall_samples: Array[float] = []
	var lock_frame_wall_samples: Array[float] = []
	var non_lock_frame_wall_samples: Array[float] = []
	var lock_counts_per_frame: Array[float] = []
	var previous_lock_count := _get_corn_target_lock_count()
	var hitscan_rays_before := _get_corn_hitscan_ray_count()
	var enemy_health_before := _get_total_enemy_health()
	var previous_tick_usec := Time.get_ticks_usec()
	var peak_locks_in_one_frame := 0
	var synchronized_event_frames := 0
	for _sample_index in range(SYNCHRONIZED_SAMPLE_FRAMES):
		await physics_frame
		_drive_movement_input()
		var now_usec := Time.get_ticks_usec()
		var wall_ms := float(now_usec - previous_tick_usec) / 1000.0
		previous_tick_usec = now_usec
		wall_samples.append(wall_ms)
		var current_lock_count := _get_corn_target_lock_count()
		var locks_this_frame := current_lock_count - previous_lock_count
		previous_lock_count = current_lock_count
		if locks_this_frame > 0:
			lock_frame_wall_samples.append(wall_ms)
			lock_counts_per_frame.append(float(locks_this_frame))
			peak_locks_in_one_frame = maxi(peak_locks_in_one_frame, locks_this_frame)
			synchronized_event_frames += 1
		else:
			non_lock_frame_wall_samples.append(wall_ms)

	var hitscan_rays := _get_corn_hitscan_ray_count() - hitscan_rays_before
	var enemy_damage := enemy_health_before - _get_total_enemy_health()
	var all_summary := _summarize(wall_samples)
	var lock_summary := _summarize(lock_frame_wall_samples)
	var non_lock_summary := _summarize(non_lock_frame_wall_samples)
	var lock_count_summary := _summarize(lock_counts_per_frame)
	await _quiesce_fixture()
	print(
		(
			"COMBINED_HORDE_TURRET_SYNCHRONIZED_ATTACK_TIMERS frames=%d "
			+ "all_wall_ms=%s lock_frame_wall_ms=%s non_lock_wall_ms=%s "
			+ "locks_per_event_frame=%s peak_locks=%d event_frames=%d "
			+ "corn_hitscan_rays=%d enemy_damage=%d lock_frame_increment_p95_ms=%.3f "
			+ "lock_frame_increment_max_ms=%.3f"
		)
		% [
			SYNCHRONIZED_SAMPLE_FRAMES,
			_format_summary(all_summary),
			_format_summary(lock_summary),
			_format_summary(non_lock_summary),
			_format_summary(lock_count_summary),
			peak_locks_in_one_frame,
			synchronized_event_frames,
			hitscan_rays,
			enemy_damage,
			float(lock_summary["p95"]) - float(non_lock_summary["p50"]),
			float(lock_summary["max"]) - float(non_lock_summary["p50"]),
		]
	)
	_expect(
		peak_locks_in_one_frame >= CORN_TOWER_COUNT / 2,
		"Synchronized AttackTimers must place at least half the Corn locks in one frame."
	)
	_expect(
		synchronized_event_frames >= 2,
		"Synchronized AttackTimers must repeat their dense lock frame."
	)


func _measure_real_target_query_batch() -> void:
	# Supplemental CPU attribution inside the same production fixture. Each
	# sweep calls the real Corn selection method, which uses GameTowerDefense's
	# CombatTargetIndex, full exact distance ordering and physics LOS ray.
	_stop_tower_combat()
	for enemy in enemies:
		enemy.set_physics_process(false)
	var sweep_samples: Array[float] = []
	var visible_counts: Array[float] = []
	var fast_path_counts: Array[float] = []
	for _warmup_index in range(2):
		await physics_frame
		for corn in corn_towers:
			corn.call("_select_nearest_visible_enemy")
	for _sample_index in range(12):
		await physics_frame
		var visible_count := 0
		var fast_path_count := 0
		var started_usec := Time.get_ticks_usec()
		for corn in corn_towers:
			if corn.call("_select_nearest_visible_enemy") as Enemy != null:
				visible_count += 1
			var retained_candidates := corn.get("_target_candidates") as Array
			if retained_candidates.size() == 1:
				fast_path_count += 1
		sweep_samples.append(float(Time.get_ticks_usec() - started_usec) / 1000.0)
		visible_counts.append(float(visible_count))
		fast_path_counts.append(float(fast_path_count))
	var sweep_summary := _summarize(sweep_samples)
	var visible_summary := _summarize(visible_counts)
	var fast_path_summary := _summarize(fast_path_counts)
	print(
		(
			"COMBINED_HORDE_TURRET_REAL_TARGET_BATCH corn_queries_per_sweep=%d "
			+ "enemies=%d sweep_ms=%s visible_targets=%s fast_path_towers=%s"
		)
		% [
			corn_towers.size(),
			enemies.size(),
			_format_summary(sweep_summary),
			_format_summary(visible_summary),
			_format_summary(fast_path_summary),
		]
	)
	_expect(
		float(visible_summary["p50"]) >= float(CORN_TOWER_COUNT) * 0.5,
		"Real target batch must keep at least half the Corn towers engaged."
	)


func _measure_synchronized_corn_stage_attribution() -> void:
	# Keep the exact production nodes and physics world, but invoke one stage at a
	# time. These timings are diagnostic only; the integrated synchronized phase
	# above remains the semantic/lifecycle gate.
	var directions := PackedVector2Array()
	var hit_targets: Array[Enemy] = []
	for corn in corn_towers:
		var target := corn.call("_select_nearest_visible_enemy") as Enemy
		if target == null:
			directions.append(Vector2.RIGHT)
			hit_targets.append(null)
			continue
		var direction := corn.aim_pivot.global_position.direction_to(
			target.global_position
		).normalized()
		directions.append(direction)
		hit_targets.append(target)

	var ray_samples: Array[float] = []
	var visual_samples: Array[float] = []
	var damage_without_particles_samples: Array[float] = []
	var particle_samples: Array[float] = []
	var fire_audio_samples: Array[float] = []
	for _sample_index in range(12):
		await physics_frame
		var started_usec := Time.get_ticks_usec()
		for corn_index in range(corn_towers.size()):
			corn_towers[corn_index].call("_cast_locked_hitscan", directions[corn_index])
		ray_samples.append(float(Time.get_ticks_usec() - started_usec) / 1000.0)

		started_usec = Time.get_ticks_usec()
		for corn_index in range(corn_towers.size()):
			corn_towers[corn_index].call(
				"_play_shot_visual",
				directions[corn_index],
				20.0
			)
		visual_samples.append(float(Time.get_ticks_usec() - started_usec) / 1000.0)

		started_usec = Time.get_ticks_usec()
		for corn_index in range(corn_towers.size()):
			var damage_target := hit_targets[corn_index]
			if damage_target == null:
				continue
			damage_target.apply_damage(
				CORN_CONFIG.attack_damage,
				directions[corn_index],
				EnemyConfig.DamageType.PHYSICAL,
				false
			)
		damage_without_particles_samples.append(
			float(Time.get_ticks_usec() - started_usec) / 1000.0
		)

		_release_all_enemy_hit_effects()
		await physics_frame
		started_usec = Time.get_ticks_usec()
		for corn_index in range(corn_towers.size()):
			var particle_target := hit_targets[corn_index]
			if particle_target != null:
				particle_target.play_multiplayer_damage_feedback(
					directions[corn_index],
					true
				)
		particle_samples.append(float(Time.get_ticks_usec() - started_usec) / 1000.0)

		_stop_corn_fire_audio_voices()
		started_usec = Time.get_ticks_usec()
		for corn in corn_towers:
			PlantAttackAudioLimiter.play_burst(corn.fire_audio)
		fire_audio_samples.append(float(Time.get_ticks_usec() - started_usec) / 1000.0)

	_release_all_enemy_hit_effects()
	_stop_corn_fire_audio_voices()
	print(
		(
			"COMBINED_HORDE_TURRET_CORN_STAGE_ATTRIBUTION towers=%d "
			+ "one_ray_each_ms=%s one_visual_each_ms=%s "
			+ "one_damage_no_particles_each_ms=%s one_particle_each_ms=%s "
			+ "one_fire_audio_request_each_ms=%s"
		)
		% [
			corn_towers.size(),
			_format_summary(_summarize(ray_samples)),
			_format_summary(_summarize(visual_samples)),
			_format_summary(_summarize(damage_without_particles_samples)),
			_format_summary(_summarize(particle_samples)),
			_format_summary(_summarize(fire_audio_samples)),
		]
	)


func _release_all_enemy_hit_effects() -> void:
	if game == null or game.session_object_pool == null:
		return
	for child in game.session_object_pool.get_children():
		var effect := child as EnemyHitEffect
		if effect == null or not bool(
			effect.get_meta(SessionObjectPool.POOL_ACTIVE_META, false)
		):
			continue
		game.session_object_pool.release(effect)


func _stop_corn_fire_audio_voices() -> void:
	for corn in corn_towers:
		corn.fire_audio.stop()
		if corn.fire_audio.is_in_group(&"limited_plant_attack_audio_players"):
			corn.fire_audio.remove_from_group(&"limited_plant_attack_audio_players")


func _reset_fixture(should_move: bool, synchronize_corn: bool = false) -> void:
	_release_movement_input()
	_stop_tower_combat()
	for enemy in enemies:
		enemy.set_physics_process(false)
	_clear_pathfinder_runtime_state()

	game.player.global_position = FIXTURE_CENTER
	game.player.velocity = Vector2.ZERO
	game.player.controls_locked = not should_move
	game.player.uses_local_input = should_move
	game.player.max_health = PROBE_ENEMY_HEALTH
	game.player.current_health = PROBE_ENEMY_HEALTH
	game.player.is_dead = false
	game.player.reset_physics_interpolation()
	if game.map_camera != null:
		game.map_camera.position = Vector2.ZERO
		game.map_camera.reset_physics_interpolation()

	for enemy_index in range(enemies.size()):
		var enemy := enemies[enemy_index]
		enemy.global_position = initial_enemy_positions[enemy_index]
		enemy.velocity = Vector2.ZERO
		enemy.current_health = PROBE_ENEMY_HEALTH
		enemy.set_target_player(game.player)
		enemy.set_objective_target(game.player)
		enemy.set_pathfinder(pathfinder)
		enemy.call("_clear_navigation_path")
		enemy.call("_clear_touching_players")
		enemy.reset_physics_interpolation()
		enemy.set_physics_process(true)

	_start_staggered_tower_combat(synchronize_corn)
	movement_enabled = should_move
	movement_start_physics_frame = Engine.get_physics_frames()
	movement_direction = 0
	if should_move:
		_set_movement_direction(1)
	for _settle_index in range(3):
		await physics_frame
		_drive_movement_input()


func _start_staggered_tower_combat(synchronize_corn: bool = false) -> void:
	for corn_index in range(corn_towers.size()):
		var corn := corn_towers[corn_index]
		corn.max_health = PROBE_PLANT_HEALTH
		corn.current_health = PROBE_PLANT_HEALTH
		corn.call("_cancel_burst", false)
		corn.call("_start_idle_aim")
		var authored_interval := CORN_CONFIG.get_attack_interval()
		var corn_delay := 0.25 if synchronize_corn else 0.05 + fposmod(
			float(corn_index) * 0.61803398875 * authored_interval,
			maxf(authored_interval - 0.05, 0.05)
		)
		corn.attack_timer.start(corn_delay)
		# Timer.start(custom_time) also changes wait_time. Restore the authored
		# repeat interval while retaining the initial phase offset.
		corn.attack_timer.wait_time = authored_interval

	for agave_index in range(agave_towers.size()):
		var agave := agave_towers[agave_index]
		agave.max_health = PROBE_PLANT_HEALTH
		agave.current_health = PROBE_PLANT_HEALTH
		agave.pending_target = null
		agave.projectile_spawned_for_current_attack = false
		agave.cannon_sprite.play(&"idle")
		agave.call("_start_idle_aim")
		var authored_interval := AGAVE_CONFIG.get_attack_interval()
		var agave_delay := 0.08 + fposmod(
			float(agave_index) * 0.61803398875 * authored_interval,
			maxf(authored_interval - 0.08, 0.08)
		)
		agave.attack_timer.start(agave_delay)
		agave.attack_timer.wait_time = authored_interval

	for mortar_index in range(bamboo_mortars.size()):
		var mortar := bamboo_mortars[mortar_index]
		mortar.max_health = PROBE_PLANT_HEALTH
		mortar.current_health = PROBE_PLANT_HEALTH
		mortar.pending_target = null
		mortar.combat_phase = BambooMortar.CombatPhase.IDLE
		mortar.main_sprite.play(&"idle")
		mortar.call("_set_glow_state", false, 0)
		mortar.target_track_timer.stop()
		var authored_interval := BAMBOO_MORTAR_CONFIG.get_attack_interval()
		var mortar_cycle := (
			authored_interval + BambooMortar.WINDUP_DURATION_SECONDS
		)
		var mortar_delay := 0.10 + fposmod(
			float(mortar_index) * 0.61803398875 * mortar_cycle,
			maxf(mortar_cycle - 0.10, 0.10)
		)
		mortar.attack_timer.start(mortar_delay)
		mortar.attack_timer.wait_time = authored_interval


func _stop_tower_combat() -> void:
	for corn in corn_towers:
		corn.attack_timer.stop()
		corn.call("_cancel_burst", false)
		corn.call("_stop_idle_aim")
		corn.fire_audio.stop()
	for agave in agave_towers:
		agave.attack_timer.stop()
		agave.call("_stop_idle_aim")
		agave.pending_target = null
		agave.projectile_spawned_for_current_attack = false
		agave.cannon_sprite.play(&"idle")
		agave.fire_audio.stop()
	for mortar in bamboo_mortars:
		mortar.attack_timer.stop()
		mortar.target_track_timer.stop()
		mortar.pending_target = null
		mortar.combat_phase = BambooMortar.CombatPhase.IDLE
		mortar.main_sprite.play(&"idle")
		mortar.call("_set_glow_state", false, 0)


func _quiesce_fixture() -> void:
	_release_movement_input()
	_stop_tower_combat()
	for enemy in enemies:
		if enemy != null and is_instance_valid(enemy):
			enemy.set_physics_process(false)
	await _advance_frames(QUIESCE_FRAMES)


func _advance_frames(frame_count: int) -> void:
	for _frame_index in range(maxi(frame_count, 0)):
		await physics_frame
		_drive_movement_input()


func _clear_pathfinder_runtime_state() -> void:
	pathfinder.call("_cancel_all_runtime_navigation_jobs")
	pathfinder.dynamic_flow_target_slots.clear()
	pathfinder.flow_field_cache.clear()
	pathfinder.flow_field_cache_order.clear()
	pathfinder.flow_recovery_route_cache.clear()
	pathfinder.flow_recovery_cache_order.clear()
	pathfinder.flow_field_builds_used_this_frame = 0
	pathfinder.flow_field_budget_frame = -1
	pathfinder.path_queries_used_this_frame = 0
	pathfinder.path_query_budget_frame = -1
	pathfinder.runtime_navigation_expansions_last_frame = 0
	pathfinder.runtime_navigation_build_usec_last_frame = 0
	pathfinder.runtime_navigation_build_usec_peak = 0
	pathfinder.runtime_flow_builds_completed = 0
	pathfinder.runtime_flow_builds_cancelled = 0


func _drive_movement_input() -> void:
	if not movement_enabled:
		return
	var elapsed_frames := maxi(
		Engine.get_physics_frames() - movement_start_physics_frame,
		0
	)
	var segment := floori(
		float(elapsed_frames) / float(MOVEMENT_SWITCH_PHYSICS_FRAMES)
	)
	var next_direction := 1 if segment % 2 == 0 else -1
	if next_direction != movement_direction:
		_set_movement_direction(next_direction)


func _set_movement_direction(direction: int) -> void:
	movement_direction = signi(direction)
	Input.action_release(&"move_left")
	Input.action_release(&"move_right")
	if movement_direction > 0:
		Input.action_press(&"move_right")
	elif movement_direction < 0:
		Input.action_press(&"move_left")


func _release_movement_input() -> void:
	Input.action_release(&"move_left")
	Input.action_release(&"move_right")
	movement_enabled = false
	movement_direction = 0


func _get_player_target_cell() -> Vector2i:
	if game == null or game.player == null or pathfinder == null:
		return Vector2i.ZERO
	return pathfinder.call("_global_to_map", game.player.global_position) as Vector2i


func _get_corn_target_lock_count() -> int:
	var result := 0
	for corn in corn_towers:
		result += corn.next_authoritative_action_id
	return result


func _get_corn_hitscan_ray_count() -> int:
	var result := 0
	for corn in corn_towers:
		result += corn.get_hitscan_query_count()
	return result


func _get_bamboo_fire_count() -> int:
	var result := 0
	for mortar in bamboo_mortars:
		result += mortar.get_completed_authoritative_launch_count()
	return result


func _count_alive_enemies() -> int:
	var result := 0
	for enemy in enemies:
		if enemy != null and is_instance_valid(enemy) and not enemy.is_dead:
			result += 1
	return result


func _get_total_enemy_health() -> int:
	var result := 0
	for enemy in enemies:
		if enemy != null and is_instance_valid(enemy) and not enemy.is_dead:
			result += enemy.current_health
	return result


func _count_alive_towers() -> int:
	var result := 0
	for corn in corn_towers:
		if corn != null and is_instance_valid(corn) and not corn.is_dead:
			result += 1
	for agave in agave_towers:
		if agave != null and is_instance_valid(agave) and not agave.is_dead:
			result += 1
	for mortar in bamboo_mortars:
		if mortar != null and is_instance_valid(mortar) and not mortar.is_dead:
			result += 1
	return result


func _capture_relevant_pool_metrics() -> Dictionary:
	if game == null or game.session_object_pool == null:
		return {}
	return {
		"agave": game.session_object_pool.get_metrics(
			AGAVE_CANNONBALL_SCENE.resource_path
		),
		"bamboo": game.session_object_pool.get_metrics(
			BAMBOO_MORTAR_SHELL_SCENE.resource_path
		),
		"enemy_hit": game.session_object_pool.get_metrics(
			ENEMY_HIT_EFFECT_SCENE.resource_path
		),
	}


func _format_relevant_pool_metrics(metrics_by_label: Dictionary) -> String:
	var parts := PackedStringArray()
	for label in [&"agave", &"bamboo", &"enemy_hit"]:
		var metrics := metrics_by_label.get(String(label), {}) as Dictionary
		parts.append(
			"%s(c=%d,use=%d,peak=%d,over=%d,drop=%d,pending=%d)"
			% [
				String(label),
				int(metrics.get("created", 0)),
				int(metrics.get("in_use", 0)),
				int(metrics.get("peak_in_use", 0)),
				int(metrics.get("overflow", 0)),
				int(metrics.get("dropped", 0)),
				int(metrics.get("pending_release", 0)),
			]
		)
	return ";".join(parts)


func _relevant_pool_created_counts_match(before: Dictionary, after: Dictionary) -> bool:
	for label in ["agave", "bamboo", "enemy_hit"]:
		var before_metrics := before.get(label, {}) as Dictionary
		var after_metrics := after.get(label, {}) as Dictionary
		if int(before_metrics.get("created", -1)) != int(after_metrics.get("created", -2)):
			return false
	return true


func _gameplay_projectile_pool_outstanding(metrics_by_label: Dictionary) -> int:
	var agave_metrics := metrics_by_label.get("agave", {}) as Dictionary
	var bamboo_metrics := metrics_by_label.get("bamboo", {}) as Dictionary
	return (
		int(agave_metrics.get("in_use", 0))
		+ int(agave_metrics.get("pending_release", 0))
		+ int(bamboo_metrics.get("in_use", 0))
		+ int(bamboo_metrics.get("pending_release", 0))
	)


func _count_subtree_nodes(node: Node) -> int:
	var result := 1
	for child in node.get_children():
		result += _count_subtree_nodes(child)
	return result


func _summarize(samples: Array[float]) -> Dictionary:
	if samples.is_empty():
		return {"p50": 0.0, "p95": 0.0, "max": 0.0}
	var sorted := samples.duplicate()
	sorted.sort()
	return {
		"p50": _nearest_rank(sorted, 0.50),
		"p95": _nearest_rank(sorted, 0.95),
		"max": sorted.back(),
	}


func _nearest_rank(sorted: Array[float], percentile: float) -> float:
	var rank := ceili(clampf(percentile, 0.0, 1.0) * sorted.size())
	return sorted[clampi(rank - 1, 0, sorted.size() - 1)]


func _format_summary(summary: Dictionary) -> String:
	return "%.3f/%.3f/%.3f" % [
		float(summary.get("p50", 0.0)),
		float(summary.get("p95", 0.0)),
		float(summary.get("max", 0.0)),
	]


func _finish() -> void:
	_release_movement_input()
	Engine.max_fps = original_max_fps
	if game != null and is_instance_valid(game):
		_stop_tower_combat()
		for enemy in enemies:
			if enemy != null and is_instance_valid(enemy):
				enemy.set_physics_process(false)
	current_scene = null
	if game != null and is_instance_valid(game):
		game.queue_free()
	for _cleanup_index in range(CLEANUP_FRAMES):
		await process_frame
		await physics_frame
	if failures.is_empty():
		print("GAME_TOWER_DEFENSE_COMBINED_HORDE_TURRET_STRESS_PROBE_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
