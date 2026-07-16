extends SceneTree

# Headless CPU A/B for the movement hot paths used by 300-enemy tower-defense
# pressure. Timings are diagnostic; each optimized path is compared against its
# former allocation/physics behavior with identical live nodes in one process.
const BASIC_CONFIG := preload("res://resources/config/enemies/yuanshi_insect_basic.tres")
const GUARDIAN_SYSTEM_SCENE := preload("res://scene/enemy/guardian_aura_system.tscn")
const PLAYER_SCENE := preload("res://scene/player/tiyi/player_tiyi.tscn")

const ENEMY_COUNT := 300
const ENEMY_ITERATIONS := 180
const ENEMY_SAMPLE_COUNT := 5
const MIRROR_ITERATIONS := 240
const MIRROR_SAMPLE_COUNT := 5
const GUARDIAN_ITERATIONS := 1200
const PLAYER_QUERY_ITERATIONS := 20000

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var fixture := Node2D.new()
	var enemy_container := Node2D.new()
	enemy_container.name = "EnemyContainer"
	fixture.add_child(enemy_container)
	var boss_container := Node2D.new()
	boss_container.name = "BossContainer"
	fixture.add_child(boss_container)
	var guardian_system := GUARDIAN_SYSTEM_SCENE.instantiate() as GuardianAuraSystem
	fixture.add_child(guardian_system)
	var objective := Node2D.new()
	objective.position = Vector2(100000.0, 0.0)
	fixture.add_child(objective)
	root.add_child(fixture)

	var enemies: Array[Enemy] = []
	for index in range(ENEMY_COUNT):
		var enemy := BASIC_CONFIG.enemy_scene.instantiate() as Enemy
		enemy_container.add_child(enemy)
		enemy.setup(BASIC_CONFIG, null, null)
		enemy.set_physics_process(false)
		enemy.position = Vector2(index % 30, index / 30) * 24.0
		enemy.objective_target = objective
		enemy.target_player = null
		enemy.velocity = Vector2.RIGHT * 60.0
		enemies.append(enemy)
	var player := PLAYER_SCENE.instantiate() as Player
	fixture.add_child(player)
	player.position = Vector2(2000.0, 2000.0)
	player.set_physics_process(false)
	await process_frame
	await physics_frame
	guardian_system.set_physics_process(false)
	guardian_system.force_refresh_all()

	var enemy_motion_results := _measure_enemy_motion_ab(enemies)
	var direct_ms := float(enemy_motion_results["direct_ms"])
	var slide_ms := float(enemy_motion_results["slide_ms"])
	var mirror_results := _measure_facing_mirror_ab(enemies)
	var cached_mirror_ms := float(mirror_results["cached_ms"])
	var allocating_mirror_ms := float(mirror_results["allocating_ms"])
	var batched_aura_ms := _measure_batched_guardian_ticks(guardian_system)
	var legacy_aura_ms := _measure_legacy_guardian_ticks(guardian_system)
	var reused_player_query_ms := _measure_reused_player_query(player)
	var allocating_player_query_ms := _measure_allocating_player_query(player)

	_expect(direct_ms < slide_ms, "Verified direct enemy motion must beat move_and_slide().")
	_expect(
		cached_mirror_ms < allocating_mirror_ms,
		"Cached enemy mirror shapes must beat rebuilding arrays per facing change."
	)
	_expect(
		batched_aura_ms < legacy_aura_ms,
		"Batched GuardianAuraSystem auditing must beat a per-tick full prune."
	)
	_expect(
		reused_player_query_ms < allocating_player_query_ms,
		"Reusable player wall queries must beat allocating parameters and excludes."
	)
	print(
		(
			"MOVEMENT_HOT_PATH_PROBE enemies=%d direct_ms=%.3f slide_ms=%.3f "
			+ "direct_speedup=%.2fx cached_mirror_ms=%.3f allocating_mirror_ms=%.3f "
			+ "aura_batched_ms=%.3f aura_legacy_ms=%.3f player_reused_ms=%.3f "
			+ "player_allocating_ms=%.3f"
		)
		% [
			ENEMY_COUNT,
			direct_ms,
			slide_ms,
			slide_ms / maxf(direct_ms, 0.001),
			cached_mirror_ms,
			allocating_mirror_ms,
			batched_aura_ms,
			legacy_aura_ms,
			reused_player_query_ms,
			allocating_player_query_ms,
		]
	)

	fixture.queue_free()
	await process_frame
	await physics_frame
	if failures.is_empty():
		print("MOVEMENT_HOT_PATH_PERFORMANCE_PROBE_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _measure_enemy_motion_ab(enemies: Array[Enemy]) -> Dictionary:
	var direct_samples: Array[float] = []
	var slide_samples: Array[float] = []
	for sample_index in range(ENEMY_SAMPLE_COUNT):
		if sample_index % 2 == 0:
			_reset_enemy_motion_fixture(enemies, true)
			direct_samples.append(_measure_verified_direct_motion(enemies))
			_reset_enemy_motion_fixture(enemies, false)
			slide_samples.append(_measure_character_body_motion(enemies))
		else:
			_reset_enemy_motion_fixture(enemies, false)
			slide_samples.append(_measure_character_body_motion(enemies))
			_reset_enemy_motion_fixture(enemies, true)
			direct_samples.append(_measure_verified_direct_motion(enemies))
	return {
		"direct_ms": _median(direct_samples),
		"slide_ms": _median(slide_samples),
	}


func _measure_verified_direct_motion(enemies: Array[Enemy]) -> float:
	var started := Time.get_ticks_usec()
	for _iteration in range(ENEMY_ITERATIONS):
		for enemy in enemies:
			enemy.call("_move_until_player_contact")
	return float(Time.get_ticks_usec() - started) / 1000.0


func _reset_enemy_motion_fixture(enemies: Array[Enemy], direct_enabled: bool) -> void:
	for index in range(enemies.size()):
		var enemy := enemies[index]
		enemy.position = Vector2(index % 30, index / 30) * 24.0
		enemy.cached_navigation_uses_direct_objective_approach = direct_enabled
		enemy.cached_navigation_verified_direct_motion_clearance = INF if direct_enabled else 0.0
		enemy.cached_navigation_move_direction = Vector2.RIGHT if direct_enabled else Vector2.ZERO
		enemy.cached_navigation_generation = -1


func _measure_character_body_motion(enemies: Array[Enemy]) -> float:
	var started := Time.get_ticks_usec()
	for _iteration in range(ENEMY_ITERATIONS):
		for enemy in enemies:
			enemy.call("_move_until_player_contact")
	return float(Time.get_ticks_usec() - started) / 1000.0


func _measure_facing_mirror_ab(enemies: Array[Enemy]) -> Dictionary:
	var cached_samples: Array[float] = []
	var allocating_samples: Array[float] = []
	for sample_index in range(MIRROR_SAMPLE_COUNT):
		if sample_index % 2 == 0:
			cached_samples.append(_measure_cached_facing_mirror(enemies))
			allocating_samples.append(_measure_allocating_facing_mirror(enemies))
		else:
			allocating_samples.append(_measure_allocating_facing_mirror(enemies))
			cached_samples.append(_measure_cached_facing_mirror(enemies))
	return {
		"cached_ms": _median(cached_samples),
		"allocating_ms": _median(allocating_samples),
	}


func _measure_cached_facing_mirror(enemies: Array[Enemy]) -> float:
	var started := Time.get_ticks_usec()
	for iteration in range(MIRROR_ITERATIONS):
		var mirror_sign := -1.0 if iteration % 2 == 0 else 1.0
		for enemy in enemies:
			for shape_node in enemy.mirrored_collision_shapes:
				enemy.call("_apply_collision_shape_mirror", shape_node, mirror_sign)
	return float(Time.get_ticks_usec() - started) / 1000.0


func _measure_allocating_facing_mirror(enemies: Array[Enemy]) -> float:
	var started := Time.get_ticks_usec()
	for iteration in range(MIRROR_ITERATIONS):
		var mirror_sign := -1.0 if iteration % 2 == 0 else 1.0
		for enemy in enemies:
			var shape_nodes: Array[CollisionShape2D] = []
			shape_nodes.append_array(enemy.body_collision_shapes)
			shape_nodes.append_array(enemy.touch_damage_shapes)
			for shape_node in shape_nodes:
				enemy.call("_apply_collision_shape_mirror", shape_node, mirror_sign)
	return float(Time.get_ticks_usec() - started) / 1000.0


func _measure_batched_guardian_ticks(system: GuardianAuraSystem) -> float:
	var started := Time.get_ticks_usec()
	for _iteration in range(GUARDIAN_ITERATIONS):
		system.call("_physics_process", 1.0 / 60.0)
	return float(Time.get_ticks_usec() - started) / 1000.0


func _measure_legacy_guardian_ticks(system: GuardianAuraSystem) -> float:
	var started := Time.get_ticks_usec()
	for _iteration in range(GUARDIAN_ITERATIONS):
		system.call("_prune_dead_or_invalid_enemies")
		system.call("_physics_process", 1.0 / 60.0)
	return float(Time.get_ticks_usec() - started) / 1000.0


func _measure_reused_player_query(player: Player) -> float:
	var started := Time.get_ticks_usec()
	for _iteration in range(PLAYER_QUERY_ITERATIONS):
		player.call(
			"_get_world_overlap_rest_normal",
			player.collision_shape.global_transform
		)
	return float(Time.get_ticks_usec() - started) / 1000.0


func _measure_allocating_player_query(player: Player) -> float:
	var space_state := player.get_world_2d().direct_space_state
	var started := Time.get_ticks_usec()
	for _iteration in range(PLAYER_QUERY_ITERATIONS):
		var query := PhysicsShapeQueryParameters2D.new()
		query.shape = player.collision_shape.shape
		query.transform = player.collision_shape.global_transform
		query.collision_mask = 1
		query.collide_with_bodies = true
		query.collide_with_areas = false
		query.exclude = [player.get_rid()]
		space_state.get_rest_info(query)
	return float(Time.get_ticks_usec() - started) / 1000.0


func _median(values: Array[float]) -> float:
	var sorted := values.duplicate()
	sorted.sort()
	return sorted[sorted.size() / 2] if not sorted.is_empty() else 0.0


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
