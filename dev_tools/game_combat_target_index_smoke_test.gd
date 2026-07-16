extends SceneTree

const QUERY_REPETITIONS := 512
const QUERY_RADIUS := 80.0
const SIMULATED_BENCHMARK_FRAMES := 16
const EQUIVALENCE_RADII := [-8.0, 0.0, 1.0, 48.0, 80.0, 192.0]
const EQUIVALENCE_MAX_COUNTS := [-1, 0, 1, 3, 16]


class TestEnemy:
	extends Enemy

	func _ready() -> void:
		pass

	func _physics_process(_delta: float) -> void:
		pass


var failures: Array[String] = []
var test_root: Node2D


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	test_root = Node2D.new()
	root.add_child(test_root)
	_test_game_source_enables_shared_index()
	_test_singleplayer_container_lifecycle()
	_test_tower_defense_forced_policy()
	_run_ab_case(300)
	_run_ab_case(1000)
	test_root.queue_free()
	await process_frame
	if failures.is_empty():
		print("GAME_COMBAT_TARGET_INDEX_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_game_source_enables_shared_index() -> void:
	var source := FileAccess.get_file_as_string("res://scene/game.gd")
	_expect(
		source.contains("enable_singleplayer_combat_target_index()"),
		"Game._ready() must enable the shared single-player combat target index."
	)
	var tower_source := FileAccess.get_file_as_string(
		"res://scene/game_tower_defense.gd"
	)
	_expect(
		tower_source.contains("enable_singleplayer_combat_target_index(true)"),
		"GameTowerDefense must preserve its forced bounded-query index policy."
	)


func _test_singleplayer_container_lifecycle() -> void:
	var game := Game.new()
	game.runtime_mode = GameRuntimeBase.RuntimeMode.SINGLEPLAYER
	var enemy_container := Node2D.new()
	enemy_container.name = "IndexedEnemyContainer"
	test_root.add_child(enemy_container)
	game.enemy_container = enemy_container
	var boss_container := Node2D.new()
	boss_container.name = "BossContainer"
	game.add_child(boss_container)
	game.boss_container = boss_container

	var existing_boss := TestEnemy.new()
	existing_boss.position = Vector2(120.0, 0.0)
	boss_container.add_child(existing_boss)
	game.enable_singleplayer_combat_target_index()
	_expect(
		bool(game.get("_singleplayer_combat_target_index_enabled")),
		"The shared runtime must mark the single-player index as authoritative."
	)
	_expect(
		enemy_container.child_entered_tree.is_connected(
			game._on_singleplayer_combat_target_entered
		)
		and enemy_container.child_exiting_tree.is_connected(
			game._on_singleplayer_combat_target_exiting
		),
		"Single-player enemy containers must bind both registration lifecycle signals."
	)
	_expect(
		game.get_all_combat_targets() == [existing_boss],
		"Enemies already present in the BossContainer must be seeded into the index."
	)

	var spawned_enemy := _new_tree_safe_test_enemy()
	spawned_enemy.position = Vector2(16.0, 0.0)
	enemy_container.add_child(spawned_enemy)
	var spawned_instance_id := spawned_enemy.get_instance_id()
	game._on_singleplayer_combat_target_entered(spawned_enemy)
	game._on_singleplayer_combat_target_entered(spawned_enemy)
	_expect(
		game.combat_target_index.enemies_by_net_id.size() == 2
		and _count_index_bucket_occurrences(game, spawned_instance_id) == 1,
		"Repeated single-player registration must replace the same instance-id entry without duplicating its bucket slot."
	)
	var nearest := game.query_combat_targets(Vector2.ZERO, 200.0, 1)
	_expect(
		nearest == [spawned_enemy],
		"A newly entered normal enemy must be immediately queryable through the index."
	)
	spawned_enemy.is_dead = true
	game.combat_target_index._last_refresh_physics_frame = -1
	game.combat_target_index.query_radius_into(
		Vector2.ZERO,
		200.0,
		nearest,
		1
	)
	_expect(
		not nearest.has(spawned_enemy)
		and not game.combat_target_index.enemies_by_net_id.has(spawned_instance_id),
		"A dead enemy must be pruned from both query results and index storage."
	)
	spawned_enemy.is_dead = false
	enemy_container.remove_child(spawned_enemy)
	enemy_container.add_child(spawned_enemy)
	_expect(
		game.query_combat_targets(Vector2.ZERO, 200.0, 1) == [spawned_enemy],
		"A reset enemy re-entering its container must be registered under the same live instance id."
	)
	enemy_container.remove_child(spawned_enemy)
	_expect(
		not game.get_all_combat_targets().has(spawned_enemy),
		"A child exiting the enemy container must be synchronously unregistered."
	)
	spawned_enemy.free()
	game.free()
	enemy_container.queue_free()

	var multiplayer_game := Game.new()
	multiplayer_game.runtime_mode = GameRuntimeBase.RuntimeMode.CLIENT_VIEW
	var multiplayer_enemy_container := Node2D.new()
	multiplayer_game.enemy_container = multiplayer_enemy_container
	multiplayer_game.add_child(multiplayer_enemy_container)
	var multiplayer_boss_container := Node2D.new()
	multiplayer_boss_container.name = "BossContainer"
	multiplayer_game.add_child(multiplayer_boss_container)
	multiplayer_game.enable_singleplayer_combat_target_index()
	_expect(
		not bool(multiplayer_game.get("_singleplayer_combat_target_index_enabled"))
		and not multiplayer_enemy_container.child_entered_tree.is_connected(
			multiplayer_game._on_singleplayer_combat_target_entered
		),
		"CLIENT_VIEW must not bind instance-id lifecycle signals over its explicit net-id index."
	)
	var multiplayer_target := TestEnemy.new()
	multiplayer_target.position = Vector2(8.0, 0.0)
	multiplayer_game.register_combat_target(77, multiplayer_target)
	_expect(
		multiplayer_game.query_combat_targets(Vector2.ZERO, 32.0, 1) == [multiplayer_target],
		"Non-single-player runtimes must retain the existing net-id index semantics."
	)
	multiplayer_game.unregister_combat_target(77)
	multiplayer_target.free()
	multiplayer_game.free()


func _count_index_bucket_occurrences(game: Game, net_id: int) -> int:
	var occurrences := 0
	for bucket_variant in game.combat_target_index.buckets.values():
		var bucket := bucket_variant as Array
		occurrences += bucket.count(net_id)
	return occurrences


func _test_tower_defense_forced_policy() -> void:
	var game := GameTowerDefense.new()
	game.runtime_mode = GameRuntimeBase.RuntimeMode.SINGLEPLAYER
	var enemy_container := Node2D.new()
	enemy_container.name = "EnemyContainer"
	var boss_container := Node2D.new()
	boss_container.name = "BossContainer"
	game.add_child(enemy_container)
	game.add_child(boss_container)
	game.enemy_container = enemy_container
	game.boss_container = boss_container
	var enemy := TestEnemy.new()
	enemy.position = Vector2(24.0, 0.0)
	enemy_container.add_child(enemy)
	game.enable_singleplayer_combat_target_index(true)
	var result: Array[Enemy] = []
	var physics_frame := Engine.get_physics_frames()
	game.combat_target_index._last_refresh_physics_frame = -777
	game.query_combat_targets_into(Vector2.ZERO, 128.0, result, 1)
	_expect(
		game.combat_target_index._last_refresh_physics_frame == physics_frame,
		"Tower-defense bounded queries must use the index even when query density is sparse."
	)
	game.combat_target_index._last_refresh_physics_frame = -777
	game.query_combat_targets_into(Vector2.ZERO, 0.0, result, 1)
	_expect(
		game.combat_target_index._last_refresh_physics_frame == -777,
		"Tower-defense global queries must also skip redundant bucket reconciliation."
	)
	game.free()


func _new_tree_safe_test_enemy() -> TestEnemy:
	var enemy := TestEnemy.new()
	var animated_sprite := AnimatedSprite2D.new()
	animated_sprite.name = "AnimatedSprite2D"
	enemy.add_child(animated_sprite)
	var touch_damage_area := Area2D.new()
	touch_damage_area.name = "TouchDamageArea"
	enemy.add_child(touch_damage_area)
	var hit_audio := AudioStreamPlayer2D.new()
	hit_audio.name = "HitAudio"
	enemy.add_child(hit_audio)
	var death_audio := AudioStreamPlayer2D.new()
	death_audio.name = "DeathAudio"
	enemy.add_child(death_audio)
	return enemy


func _run_ab_case(enemy_count: int) -> void:
	var game := Game.new()
	game.runtime_mode = GameRuntimeBase.RuntimeMode.SINGLEPLAYER
	var enemy_container := Node2D.new()
	enemy_container.name = "EnemyContainer"
	var boss_container := Node2D.new()
	boss_container.name = "BossContainer"
	game.add_child(enemy_container)
	game.add_child(boss_container)
	game.enemy_container = enemy_container
	game.boss_container = boss_container
	for enemy_index in range(enemy_count):
		var enemy := TestEnemy.new()
		var column := enemy_index % 50
		var row := enemy_index / 50
		enemy.position = Vector2(column * 24.0, row * 24.0)
		if enemy_index % 17 == 0:
			boss_container.add_child(enemy)
		else:
			enemy_container.add_child(enemy)
	game.enable_singleplayer_combat_target_index()
	var centers := PackedVector2Array()
	for center_index in range(16):
		centers.append(Vector2(
			float((center_index * 7) % 50) * 24.0,
			float((center_index * 5) % maxi(enemy_count / 50, 1)) * 24.0
		))
	_assert_query_equivalence(
		game,
		[enemy_container, boss_container],
		PackedVector2Array([centers[0], centers[7], Vector2(-24.0, -24.0)]),
		enemy_count
	)
	_assert_adaptive_routing(game, enemy_count)

	var legacy_usec := _measure_legacy_queries(game, centers)
	var indexed_usec := _measure_indexed_queries(game, centers)
	var speedup := float(legacy_usec) / float(maxi(indexed_usec, 1))
	print(
		"GAME_COMBAT_TARGET_INDEX_AB enemies=%d queries=%d legacy_usec=%d indexed_usec=%d speedup=%.2fx"
		% [enemy_count, QUERY_REPETITIONS, legacy_usec, indexed_usec, speedup]
	)
	_expect(
		indexed_usec < legacy_usec,
		"The indexed %d-enemy repeated-query workload must beat the legacy full scan."
		% enemy_count
	)
	_run_frame_group_ab_matrix(
		game,
		centers,
		enemy_count
	)
	game.free()


func _assert_query_equivalence(
	game: Game,
	containers: Array[Node],
	centers: PackedVector2Array,
	enemy_count: int
) -> void:
	var indexed_result: Array[Enemy] = []
	var legacy_result: Array[Enemy] = []
	for center in centers:
		for radius_variant in EQUIVALENCE_RADII:
			var radius := float(radius_variant)
			for max_count_variant in EQUIVALENCE_MAX_COUNTS:
				var max_count := int(max_count_variant)
				game.combat_target_index.query_radius_into(
					center,
					radius,
					indexed_result,
					max_count
				)
				_legacy_query_into(
					containers,
					center,
					radius,
					legacy_result,
					max_count
				)
				_expect(
					indexed_result == legacy_result,
					(
						"Indexed/legacy mismatch for %d enemies, center=%s, radius=%.1f, max_count=%d."
						% [enemy_count, center, radius, max_count]
					)
				)
			game.combat_target_index.query_radius_unordered_into(
				center,
				radius,
				indexed_result
			)
			_legacy_query_into(containers, center, radius, legacy_result, 0)
			_expect(
				_same_enemy_membership(indexed_result, legacy_result),
				(
					"Indexed/legacy unordered membership mismatch for %d enemies, center=%s, radius=%.1f."
					% [enemy_count, center, radius]
				)
			)


func _same_enemy_membership(a: Array[Enemy], b: Array[Enemy]) -> bool:
	if a.size() != b.size():
		return false
	var ids: Dictionary[int, bool] = {}
	for enemy in a:
		ids[enemy.get_instance_id()] = true
	if ids.size() != a.size():
		return false
	for enemy in b:
		if not ids.has(enemy.get_instance_id()):
			return false
	return true


func _assert_adaptive_routing(game: Game, enemy_count: int) -> void:
	var result: Array[Enemy] = []
	var physics_frame := Engine.get_physics_frames()
	game._singleplayer_combat_query_physics_frame = physics_frame
	game._singleplayer_combat_queries_this_frame = 0
	game._singleplayer_combat_queries_previous_frame = 1
	game.combat_target_index._last_refresh_physics_frame = -777
	game.query_combat_targets_into(Vector2.ZERO, 128.0, result, 1)
	_expect(
		game.combat_target_index._last_refresh_physics_frame == -777,
		"A sparse local nearest query must stay on the lower-overhead container scan."
	)

	game._singleplayer_combat_queries_previous_frame = 8
	game.combat_target_index._last_refresh_physics_frame = -777
	game.query_combat_targets_into(Vector2.ZERO, 128.0, result, 1)
	_expect(
		game.combat_target_index._last_refresh_physics_frame == physics_frame,
		"A dense local nearest workload must activate the amortized spatial index."
	)

	game._singleplayer_combat_queries_previous_frame = 8
	game.combat_target_index._last_refresh_physics_frame = -777
	game.query_combat_targets_into(Vector2.ZERO, 0.0, result, 1)
	_expect(
		game.combat_target_index._last_refresh_physics_frame == -777,
		"Global queries must avoid the index's redundant full moving-bucket refresh."
	)

	game._singleplayer_combat_queries_previous_frame = 8
	game.combat_target_index._last_refresh_physics_frame = -777
	game.query_combat_targets_into(Vector2.ZERO, 128.0, result, 0)
	var bulk_used_index: bool = (
		game.combat_target_index._last_refresh_physics_frame == physics_frame
	)
	_expect(
		bulk_used_index == (enemy_count >= 512),
		"Dense local bulk routing must use the measured 512-target break-even guard."
	)


func _run_frame_group_ab_matrix(
	game: Game,
	centers: PackedVector2Array,
	enemy_count: int
) -> void:
	for radius in [128.0, 0.0]:
		for max_count in [1, 0]:
			for queries_per_frame in [1, 8]:
				var legacy_usec := _measure_legacy_frame_groups(
					game,
					centers,
					radius,
					max_count,
					queries_per_frame
				)
				var indexed_usec := _measure_indexed_frame_groups(
					game,
					centers,
					radius,
					max_count,
					queries_per_frame
				)
				var adaptive_usec := _measure_adaptive_frame_groups(
					game,
					centers,
					radius,
					max_count,
					queries_per_frame
				)
				var speedup := float(legacy_usec) / float(maxi(indexed_usec, 1))
				var adaptive_speedup := (
					float(legacy_usec) / float(maxi(adaptive_usec, 1))
				)
				print(
					(
						"GAME_COMBAT_TARGET_INDEX_FRAME_AB enemies=%d frames=%d queries_per_frame=%d radius=%.0f max_count=%d legacy_usec=%d raw_indexed_usec=%d raw_speedup=%.2fx adaptive_usec=%d adaptive_speedup=%.2fx"
						% [
							enemy_count,
							SIMULATED_BENCHMARK_FRAMES,
							queries_per_frame,
							radius,
							max_count,
							legacy_usec,
							indexed_usec,
							speedup,
							adaptive_usec,
							adaptive_speedup,
						]
					)
				)


func _measure_legacy_frame_groups(
	game: Game,
	centers: PackedVector2Array,
	radius: float,
	max_count: int,
	queries_per_frame: int
) -> int:
	var result: Array[Enemy] = []
	var checksum := 0
	var index_was_enabled := game._singleplayer_combat_target_index_enabled
	game._singleplayer_combat_target_index_enabled = false
	var started_usec := Time.get_ticks_usec()
	for simulated_frame in range(SIMULATED_BENCHMARK_FRAMES):
		for query_in_frame in range(queries_per_frame):
			var query_index := simulated_frame * queries_per_frame + query_in_frame
			game.query_combat_targets_into(
				centers[query_index % centers.size()],
				radius,
				result,
				max_count
			)
			checksum += result.size()
	var elapsed_usec := Time.get_ticks_usec() - started_usec
	game._singleplayer_combat_target_index_enabled = index_was_enabled
	if checksum <= 0:
		failures.append("Legacy frame-group A/B workload unexpectedly returned no targets.")
	return elapsed_usec


func _measure_indexed_frame_groups(
	game: Game,
	centers: PackedVector2Array,
	radius: float,
	max_count: int,
	queries_per_frame: int
) -> int:
	var result: Array[Enemy] = []
	var checksum := 0
	var started_usec := Time.get_ticks_usec()
	for simulated_frame in range(SIMULATED_BENCHMARK_FRAMES):
		# One forced reconciliation per group models a new physics frame without
		# making this deterministic smoke test wait for wall-clock physics ticks.
		game.combat_target_index._last_refresh_physics_frame = -1
		for query_in_frame in range(queries_per_frame):
			var query_index := simulated_frame * queries_per_frame + query_in_frame
			game.combat_target_index.query_radius_into(
				centers[query_index % centers.size()],
				radius,
				result,
				max_count
			)
			checksum += result.size()
	var elapsed_usec := Time.get_ticks_usec() - started_usec
	if checksum <= 0:
		failures.append("Indexed frame-group A/B workload unexpectedly returned no targets.")
	return elapsed_usec


func _measure_adaptive_frame_groups(
	game: Game,
	centers: PackedVector2Array,
	radius: float,
	max_count: int,
	queries_per_frame: int
) -> int:
	var result: Array[Enemy] = []
	var checksum := 0
	var physics_frame := Engine.get_physics_frames()
	var started_usec := Time.get_ticks_usec()
	for simulated_frame in range(SIMULATED_BENCHMARK_FRAMES):
		game._singleplayer_combat_query_physics_frame = physics_frame
		game._singleplayer_combat_queries_previous_frame = queries_per_frame
		game._singleplayer_combat_queries_this_frame = 0
		game.combat_target_index._last_refresh_physics_frame = -1
		for query_in_frame in range(queries_per_frame):
			var query_index := simulated_frame * queries_per_frame + query_in_frame
			game.query_combat_targets_into(
				centers[query_index % centers.size()],
				radius,
				result,
				max_count
			)
			checksum += result.size()
	var elapsed_usec := Time.get_ticks_usec() - started_usec
	if checksum <= 0:
		failures.append("Adaptive frame-group A/B workload unexpectedly returned no targets.")
	return elapsed_usec


func _measure_legacy_queries(game: Game, centers: PackedVector2Array) -> int:
	var result: Array[Enemy] = []
	var checksum := 0
	var index_was_enabled := game._singleplayer_combat_target_index_enabled
	game._singleplayer_combat_target_index_enabled = false
	var started_usec := Time.get_ticks_usec()
	for query_index in range(QUERY_REPETITIONS):
		game.query_combat_targets_into(
			centers[query_index % centers.size()],
			QUERY_RADIUS,
			result,
			1
		)
		checksum += result.size()
	var elapsed_usec := Time.get_ticks_usec() - started_usec
	game._singleplayer_combat_target_index_enabled = index_was_enabled
	if checksum != QUERY_REPETITIONS:
		failures.append("Legacy A/B workload unexpectedly lost nearest targets.")
	return elapsed_usec


func _measure_indexed_queries(game: Game, centers: PackedVector2Array) -> int:
	var result: Array[Enemy] = []
	var checksum := 0
	var started_usec := Time.get_ticks_usec()
	for query_index in range(QUERY_REPETITIONS):
		game.combat_target_index.query_radius_into(
			centers[query_index % centers.size()],
			QUERY_RADIUS,
			result,
			1
		)
		checksum += result.size()
	var elapsed_usec := Time.get_ticks_usec() - started_usec
	if checksum != QUERY_REPETITIONS:
		failures.append("Indexed A/B workload unexpectedly lost nearest targets.")
	return elapsed_usec


func _legacy_query_into(
	containers: Array[Node],
	center: Vector2,
	radius: float,
	result: Array[Enemy],
	max_count: int
) -> void:
	result.clear()
	var safe_radius := maxf(radius, 0.0)
	var radius_squared := safe_radius * safe_radius
	for container in containers:
		for child in container.get_children():
			var enemy := child as Enemy
			if enemy == null or enemy.is_dead:
				continue
			if (
				safe_radius > 0.0
				and center.distance_squared_to(enemy.global_position) > radius_squared
			):
				continue
			result.append(enemy)
	if max_count == 1:
		_retain_legacy_nearest(result, center)
		return
	CombatTargetIndex.sort_candidates_by_distance(result, center)
	if max_count > 0 and result.size() > max_count:
		result.resize(max_count)


func _retain_legacy_nearest(result: Array[Enemy], center: Vector2) -> void:
	if result.size() <= 1:
		return
	var nearest := result[0]
	var nearest_distance := center.distance_squared_to(nearest.global_position)
	var nearest_instance_id := nearest.get_instance_id()
	for candidate_index in range(1, result.size()):
		var candidate := result[candidate_index]
		var candidate_distance := center.distance_squared_to(candidate.global_position)
		var candidate_instance_id := candidate.get_instance_id()
		if (
			candidate_distance < nearest_distance
			and not is_equal_approx(candidate_distance, nearest_distance)
		) or (
			is_equal_approx(candidate_distance, nearest_distance)
			and candidate_instance_id < nearest_instance_id
		):
			nearest = candidate
			nearest_distance = candidate_distance
			nearest_instance_id = candidate_instance_id
	result[0] = nearest
	result.resize(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
