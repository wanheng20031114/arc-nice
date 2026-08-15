extends SceneTree

const QUERY_REPETITIONS := 512
const QUERY_RADIUS := 80.0
const SIMULATED_BENCHMARK_FRAMES := 16
const EQUIVALENCE_RADII := [-8.0, 0.0, 1.0, 48.0, 80.0, 192.0]
const EQUIVALENCE_MAX_COUNTS := [-1, 0, 1, 3, 16]
const MpGameScript := preload("res://scene/multiplayer/mp_game.gd")


class TestEnemy:
	extends Enemy

	func _ready() -> void:
		pass

	func _physics_process(_delta: float) -> void:
		pass


class TestNetManager:
	extends Node

	var host_mode := false

	func is_host() -> bool:
		return host_mode


var failures: Array[String] = []
var test_root: Node2D


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	test_root = Node2D.new()
	root.add_child(test_root)
	_test_game_source_enables_shared_index()
	_test_nearest_combat_target_contracts()
	_test_queued_target_query_contracts()
	_test_singleplayer_container_lifecycle()
	_test_same_physics_frame_bucket_migration()
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
	var source := FileAccess.get_file_as_string(
		"res://scene/combat/runtime/wave_combat_runtime_base.gd"
	)
	_expect(
		source.contains("enable_singleplayer_combat_target_index()"),
		"StandardGame._ready() must enable the shared single-player combat target index."
	)
	var tower_source := FileAccess.get_file_as_string(
		"res://scene/game_modes/tower_defense/tower_defense_game.gd"
	)
	_expect(
		tower_source.contains("enable_singleplayer_combat_target_index(true)"),
		"TowerDefenseGame must preserve its forced bounded-query index policy."
	)


func _test_nearest_combat_target_contracts() -> void:
	var game := StandardGame.new()
	game.runtime_mode = CombatRuntimeBase.RuntimeMode.SINGLEPLAYER
	var enemy_container := Node2D.new()
	enemy_container.name = "NearestEnemyContainer"
	test_root.add_child(enemy_container)
	game.enemy_container = enemy_container
	var boss_container := Node2D.new()
	boss_container.name = "BossContainer"
	game.add_child(boss_container)
	game.boss_container = boss_container

	var nearest_enemy := _new_tree_safe_test_enemy()
	var middle_enemy := _new_tree_safe_test_enemy()
	var tie_enemy_a := _new_tree_safe_test_enemy()
	var tie_enemy_b := _new_tree_safe_test_enemy()
	nearest_enemy.position = Vector2(8.0, 0.0)
	middle_enemy.position = Vector2(65.0, 0.0)
	tie_enemy_a.position = Vector2(-130.0, 0.0)
	tie_enemy_b.position = Vector2(130.0, 0.0)
	enemy_container.add_child(nearest_enemy)
	boss_container.add_child(middle_enemy)
	enemy_container.add_child(tie_enemy_a)
	boss_container.add_child(tie_enemy_b)

	var empty_exclusions: Dictionary = {}
	var invalid_exclusions: Dictionary = {-1: true, 9223372036854775807: true}
	_expect(
		game.find_nearest_combat_target(
			Vector2.ZERO,
			160.0,
			empty_exclusions
		) == nearest_enemy
		and game.find_nearest_combat_target(
			Vector2.ZERO,
			160.0,
			invalid_exclusions
		) == nearest_enemy,
		"The direct two-container nearest scan must accept empty and unknown exclusions."
	)
	var excluded_nearest: Dictionary = {
		nearest_enemy.get_instance_id(): true,
	}
	_expect(
		game.find_nearest_combat_target(
			Vector2.ZERO,
			160.0,
			excluded_nearest
		) == middle_enemy,
		"The direct single-player scan must exclude an instance without allocating candidates."
	)
	var excluded_first_two: Dictionary = {
		nearest_enemy.get_instance_id(): true,
		middle_enemy.get_instance_id(): true,
	}
	var expected_tie_first := (
		tie_enemy_a
		if tie_enemy_a.get_instance_id() < tie_enemy_b.get_instance_id()
		else tie_enemy_b
	)
	_expect(
		game.find_nearest_combat_target(
			Vector2.ZERO,
			160.0,
			excluded_first_two
		) == expected_tie_first,
		"The direct scan must merge both containers with the stable instance-id tie break."
	)
	_expect(
		game.find_nearest_combat_target(
			Vector2(NAN, 0.0),
			160.0,
			empty_exclusions
		) == null
		and game.find_nearest_combat_target(
			Vector2.ZERO,
			INF,
			empty_exclusions
		) == null
		and game.find_nearest_combat_target(
			Vector2.ZERO,
			-1.0,
			empty_exclusions
		) == null,
		"The runtime nearest facade must reject non-finite and negative inputs before either query path."
	)

	game.enable_singleplayer_combat_target_index()
	var physics_frame := Engine.get_physics_frames()
	game.combat_target_index._last_refresh_physics_frame = -777
	_expect(
		game.find_nearest_combat_target(
			Vector2.ZERO,
			160.0,
			excluded_first_two
		) == expected_tie_first
		and game.combat_target_index._last_refresh_physics_frame == physics_frame,
		"An enabled bounded single-player nearest query must route through the maintained index."
	)

	var net_manager := TestNetManager.new()
	net_manager.host_mode = true
	var multiplayer_game: Variant = MpGameScript.new()
	var enemy_coordinator := MpEnemyCoordinator.new()
	multiplayer_game.add_child(enemy_coordinator)
	enemy_coordinator.bind_runtime(game)
	multiplayer_game.set("enemy_coordinator", enemy_coordinator)
	multiplayer_game.set("net_manager", net_manager)
	multiplayer_game.set("game", game)
	_expect(
		multiplayer_game.call(
			"find_nearest_combat_target",
			Vector2.ZERO,
			160.0,
			excluded_nearest
		) == middle_enemy,
		"The multiplayer host nearest query must forward to its authoritative game runtime."
	)

	game.combat_target_index._last_refresh_physics_frame = -777
	_expect(
		game.find_nearest_combat_target(
			Vector2.ZERO,
			0.0,
			excluded_nearest
		) == null
		and game.combat_target_index._last_refresh_physics_frame == -777,
		"A zero-radius single-player nearest query must be a closed point query without bucket maintenance."
	)

	game._singleplayer_combat_target_index_enabled = false
	var queued_enemy := _new_tree_safe_test_enemy()
	queued_enemy.position = Vector2(1.0, 0.0)
	enemy_container.add_child(queued_enemy)
	queued_enemy.queue_free()
	var dead_enemy := _new_tree_safe_test_enemy()
	dead_enemy.position = Vector2(2.0, 0.0)
	dead_enemy.is_dead = true
	enemy_container.add_child(dead_enemy)
	_expect(
		game.find_nearest_combat_target(
			Vector2.ZERO,
			160.0,
			empty_exclusions
		) == nearest_enemy,
		"The direct container scan must reject dead and queued-for-deletion enemies."
	)

	net_manager.host_mode = false
	var client_nearest := _new_tree_safe_test_enemy()
	var client_tie_a := _new_tree_safe_test_enemy()
	var client_tie_b := _new_tree_safe_test_enemy()
	var client_dead := _new_tree_safe_test_enemy()
	var client_queued := _new_tree_safe_test_enemy()
	client_nearest.position = Vector2(8.0, 0.0)
	client_tie_a.position = Vector2(-80.0, 0.0)
	client_tie_b.position = Vector2(80.0, 0.0)
	client_dead.position = Vector2(1.0, 0.0)
	client_dead.is_dead = true
	client_queued.position = Vector2(2.0, 0.0)
	for enemy in [
		client_nearest,
		client_tie_a,
		client_tie_b,
		client_dead,
		client_queued,
	]:
		test_root.add_child(enemy)
	client_queued.queue_free()
	var freed_client_enemy := _new_tree_safe_test_enemy()
	freed_client_enemy.free()
	for entry in [
		[501, client_nearest],
		[502, client_tie_a],
		[503, client_tie_b],
		[504, client_dead],
		[505, client_queued],
	]:
		enemy_coordinator.register_client_enemy(
			int(entry[0]),
			entry[1] as Enemy,
			0.0
		)
	var client_exclusions: Dictionary = {
		client_nearest.get_instance_id(): true,
	}
	var expected_client_tie := (
		client_tie_a
		if client_tie_a.get_instance_id() < client_tie_b.get_instance_id()
		else client_tie_b
	)
	_expect(
		multiplayer_game.call(
			"find_nearest_combat_target",
			Vector2.ZERO,
			100.0,
			empty_exclusions
		) == client_nearest
		and multiplayer_game.call(
			"find_nearest_combat_target",
			Vector2.ZERO,
			100.0,
			client_exclusions
		) == expected_client_tie
		and multiplayer_game.call(
			"find_nearest_combat_target",
			Vector2.ZERO,
			0.0,
			client_exclusions
		) == null,
		"The multiplayer client scan must filter invalid/dead/queued proxies and retain closed-radius exclusion semantics."
	)
	_expect(
		multiplayer_game.call(
			"find_nearest_combat_target",
			Vector2(NAN, 0.0),
			100.0,
			empty_exclusions
		) == null
		and multiplayer_game.call(
			"find_nearest_combat_target",
			Vector2.ZERO,
			INF,
			empty_exclusions
		) == null,
		"The multiplayer nearest facade must reject non-finite host/client inputs."
	)

	multiplayer_game.free()
	net_manager.free()
	for enemy in [client_nearest, client_tie_a, client_tie_b, client_dead]:
		enemy.queue_free()
	game.free()
	enemy_container.queue_free()


func _test_queued_target_query_contracts() -> void:
	var game := StandardGame.new()
	game.runtime_mode = CombatRuntimeBase.RuntimeMode.SINGLEPLAYER
	var enemy_container := Node2D.new()
	enemy_container.name = "QueuedEnemyContainer"
	test_root.add_child(enemy_container)
	game.enemy_container = enemy_container
	var boss_container := Node2D.new()
	boss_container.name = "BossContainer"
	game.add_child(boss_container)
	game.boss_container = boss_container

	var queued_enemy := _new_tree_safe_test_enemy()
	queued_enemy.position = Vector2(8.0, 0.0)
	enemy_container.add_child(queued_enemy)
	queued_enemy.queue_free()
	var sorted_targets: Array[Enemy] = []
	var unordered_targets: Array[Enemy] = []
	game.query_combat_targets_into(
		Vector2.ZERO,
		32.0,
		sorted_targets,
		0
	)
	game.query_combat_targets_unordered_into(
		Vector2.ZERO,
		32.0,
		unordered_targets
	)
	_expect(
		game.get_all_combat_targets().is_empty()
		and game.pick_random_combat_target(Vector2.ZERO, 32.0) == null
		and sorted_targets.is_empty()
		and unordered_targets.is_empty(),
		"Single-player container fallbacks must reject queued targets in full, random, sorted, and unordered queries."
	)

	var net_manager := TestNetManager.new()
	var multiplayer_game: Variant = MpGameScript.new()
	var enemy_coordinator := MpEnemyCoordinator.new()
	multiplayer_game.add_child(enemy_coordinator)
	enemy_coordinator.bind_runtime(game)
	multiplayer_game.set("enemy_coordinator", enemy_coordinator)
	multiplayer_game.set("net_manager", net_manager)
	multiplayer_game.set("game", game)
	enemy_coordinator.register_client_enemy(701, queued_enemy, 0.0)
	sorted_targets.append(queued_enemy)
	unordered_targets.append(queued_enemy)
	multiplayer_game.call(
		"query_combat_targets_into",
		Vector2.ZERO,
		32.0,
		sorted_targets,
		0
	)
	multiplayer_game.call(
		"query_combat_targets_unordered_into",
		Vector2.ZERO,
		32.0,
		unordered_targets
	)
	_expect(
		multiplayer_game.call("get_combat_target_by_net_id", 701) == null
		and (multiplayer_game.call("get_all_combat_targets") as Array[Enemy]).is_empty()
		and sorted_targets.is_empty()
		and unordered_targets.is_empty(),
		"Multiplayer client fallbacks must reject queued proxies by id and in every collection query."
	)

	multiplayer_game.free()
	net_manager.free()
	game.free()
	enemy_container.queue_free()


func _test_singleplayer_container_lifecycle() -> void:
	var game := StandardGame.new()
	game.runtime_mode = CombatRuntimeBase.RuntimeMode.SINGLEPLAYER
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
		and not game.combat_target_index.enemies_by_net_id.has(spawned_instance_id)
		and spawned_enemy.combat_target_index_binding == null,
		"A dead enemy must be pruned from index storage and release its notification binding."
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

	var multiplayer_game := StandardGame.new()
	multiplayer_game.runtime_mode = CombatRuntimeBase.RuntimeMode.CLIENT_VIEW
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


func _count_index_bucket_occurrences(game: StandardGame, net_id: int) -> int:
	var occurrences := 0
	for bucket_variant in game.combat_target_index.buckets.values():
		var bucket := bucket_variant as Array
		occurrences += bucket.count(net_id)
	return occurrences


func _test_same_physics_frame_bucket_migration() -> void:
	var game := StandardGame.new()
	game.runtime_mode = CombatRuntimeBase.RuntimeMode.CLIENT_VIEW
	var enemy := _new_tree_safe_test_enemy()
	test_root.add_child(enemy)
	enemy.global_position = Vector2(95.5, 12.0)
	game.register_combat_target(701, enemy)
	var result: Array[Enemy] = []
	game.combat_target_index.query_radius_into(enemy.global_position, 1.0, result, 1)
	var audit_count: int = game.combat_target_index.full_bucket_audits_total
	_expect(result == [enemy], "跨桶测试必须先从旧桶查询到目标。")

	# This remains the same physics frame. The transform notification must migrate
	# the net id immediately instead of waiting for another full O(enemy count)
	# reconciliation or leaking a one-frame false negative at the query boundary.
	enemy.global_position = Vector2(96.5, 12.0)
	game.combat_target_index.query_radius_into(enemy.global_position, 0.75, result, 1)
	_expect(
		result == [enemy]
		and game.combat_target_index.bucket_by_net_id.get(701) == Vector2i(1, 0)
		and game.combat_target_index.event_bucket_migrations_total == 1
		and game.combat_target_index.full_bucket_audits_total == audit_count,
		"同一物理帧内跨过96px桶边界后必须O(1)迁移且后续查询不得漏掉目标。"
	)

	# Teleports are also transform changes and may cross more than one bucket.
	enemy.global_position = Vector2(-193.0, 12.0)
	game.combat_target_index.query_radius_into(enemy.global_position, 0.75, result, 1)
	_expect(
		result == [enemy]
		and game.combat_target_index.bucket_by_net_id.get(701) == Vector2i(-3, 0)
		and game.combat_target_index.event_bucket_migrations_total == 2,
		"事件驱动索引必须在同帧正确处理跨多个桶的传送。"
	)

	var replacement := _new_tree_safe_test_enemy()
	test_root.add_child(replacement)
	replacement.global_position = Vector2(12.0, 12.0)
	var refresh_frame_before_replacement: int = (
		game.combat_target_index._last_refresh_physics_frame
	)
	game.register_combat_target(701, replacement)
	var migrations_before_old_move: int = (
		game.combat_target_index.event_bucket_migrations_total
	)
	enemy.global_position = Vector2(500.0, 12.0)
	_expect(
		enemy.combat_target_index_binding == null
		and replacement.combat_target_index_binding == game.combat_target_index
		and game.combat_target_index.get_enemy(701) == replacement
		and game.combat_target_index.event_bucket_migrations_total
			== migrations_before_old_move
		and game.combat_target_index._last_refresh_physics_frame
			== refresh_frame_before_replacement,
		(
			"Replacing one net id must detach the old enemy, retain only the new "
			+ "binding, and avoid scheduling a full-index spawn audit."
		)
	)

	game.combat_target_index.clear()
	_expect(
		replacement.combat_target_index_binding == null
		and game.combat_target_index.enemies_by_net_id.is_empty()
		and game.combat_target_index.buckets.is_empty(),
		"CombatTargetIndex.clear() must detach every surviving enemy binding."
	)
	game.register_combat_target(702, replacement)
	test_root.remove_child(replacement)
	_expect(
		replacement.combat_target_index_binding == null
		and not game.combat_target_index.enemies_by_net_id.has(702),
		"Enemy tree exit must synchronously unregister its index entry."
	)
	replacement.free()
	enemy.queue_free()
	game.free()


func _test_tower_defense_forced_policy() -> void:
	var game := TowerDefenseGame.new()
	game.runtime_mode = CombatRuntimeBase.RuntimeMode.SINGLEPLAYER
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
		"Tower-defense bounded queries must use the maintained index even when query density is sparse."
	)
	game.combat_target_index._last_refresh_physics_frame = -777
	game.query_combat_targets_into(Vector2.ZERO, 0.0, result, 1)
	_expect(
		game.combat_target_index._last_refresh_physics_frame == -777,
		"Tower-defense global queries must skip irrelevant bucket maintenance."
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
	var game := StandardGame.new()
	game.runtime_mode = CombatRuntimeBase.RuntimeMode.SINGLEPLAYER
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
	game: StandardGame,
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


func _assert_adaptive_routing(game: StandardGame, enemy_count: int) -> void:
	var result: Array[Enemy] = []
	var physics_frame := Engine.get_physics_frames()
	game.combat_target_index._last_refresh_physics_frame = -777
	game.query_combat_targets_into(Vector2.ZERO, 128.0, result, 1)
	_expect(
		game.combat_target_index._last_refresh_physics_frame == physics_frame,
		"Even one local nearest query must use the event-maintained spatial index."
	)

	game.combat_target_index._last_refresh_physics_frame = -777
	game.query_combat_targets_into(Vector2.ZERO, 128.0, result, 1)
	_expect(
		game.combat_target_index._last_refresh_physics_frame == physics_frame,
		"Repeated local nearest queries must remain on the spatial index."
	)

	game.combat_target_index._last_refresh_physics_frame = -777
	game.query_combat_targets_into(Vector2.ZERO, 0.0, result, 1)
	_expect(
		game.combat_target_index._last_refresh_physics_frame == -777,
		"Global queries must avoid irrelevant bucket maintenance."
	)

	game.combat_target_index._last_refresh_physics_frame = -777
	game.query_combat_targets_into(Vector2.ZERO, 128.0, result, 0)
	var bulk_used_index: bool = (
		game.combat_target_index._last_refresh_physics_frame == physics_frame
	)
	_expect(
		bulk_used_index == (enemy_count >= 512),
		"Local bulk routing must use the measured 512-target break-even guard."
	)


func _run_frame_group_ab_matrix(
	game: StandardGame,
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
	game: StandardGame,
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
	game: StandardGame,
	centers: PackedVector2Array,
	radius: float,
	max_count: int,
	queries_per_frame: int
) -> int:
	var result: Array[Enemy] = []
	var checksum := 0
	var started_usec := Time.get_ticks_usec()
	for simulated_frame in range(SIMULATED_BENCHMARK_FRAMES):
		# One bounded repair slice per group models a new physics frame without
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
	game: StandardGame,
	centers: PackedVector2Array,
	radius: float,
	max_count: int,
	queries_per_frame: int
) -> int:
	var result: Array[Enemy] = []
	var checksum := 0
	var started_usec := Time.get_ticks_usec()
	for simulated_frame in range(SIMULATED_BENCHMARK_FRAMES):
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


func _measure_legacy_queries(game: StandardGame, centers: PackedVector2Array) -> int:
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


func _measure_indexed_queries(game: StandardGame, centers: PackedVector2Array) -> int:
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
