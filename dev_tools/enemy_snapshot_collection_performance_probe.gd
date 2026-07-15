extends SceneTree

# A/B probe for the host-side enemy snapshot collector. The legacy fixture
# mirrors the former temporary containers/live-id/get_children allocations while
# reusing EnemyState objects, so the timing comparison isolates collection
# overhead rather than snapshot encoding or state construction.
const TOWER_SCENE := preload("res://scene/game_tower_defense.tscn")
const BASIC_CONFIG := preload(
	"res://resources/config/enemies/yuanshi_insect_basic.tres"
)

const ENEMY_COUNT := 300
const WARMUP_SWEEPS := 30
const SAMPLE_BATCHES := 31
const SWEEPS_PER_SAMPLE := 20
const FIXTURE_ORIGIN := Vector2(2800.0, 2800.0)

var failures: Array[String] = []
var game: GameTowerDefense = null
var enemies: Array[Enemy] = []
var legacy_states_by_net_id: Dictionary = {}
var legacy_output: Array[SnapshotManager.EnemyState] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	game = TOWER_SCENE.instantiate() as GameTowerDefense
	_expect(game != null, "Enemy snapshot probe must instantiate tower defense.")
	if game == null:
		await _finish()
		return
	game.auto_start_waves = false
	root.add_child(game)
	current_scene = game
	await process_frame
	await physics_frame
	game.set_process(false)
	game.set_physics_process(false)
	game.enemy_spawn_timer.stop()
	game.state_timer.stop()
	_spawn_frozen_enemies()
	await process_frame
	await physics_frame

	_expect(
		enemies.size() == ENEMY_COUNT,
		"Enemy snapshot probe must create exactly 300 enemies."
	)
	_verify_collection_semantics_and_reuse()
	for _warmup_index in range(WARMUP_SWEEPS):
		game.collect_enemy_snapshot_states()
		_legacy_collect_enemy_snapshot_states()

	var production_samples: Array[float] = []
	var legacy_samples: Array[float] = []
	for sample_index in range(SAMPLE_BATCHES):
		if sample_index % 2 == 0:
			production_samples.append(_measure_production_batch())
			legacy_samples.append(_measure_legacy_batch())
		else:
			legacy_samples.append(_measure_legacy_batch())
			production_samples.append(_measure_production_batch())

	var production_summary := _summarize(production_samples)
	var legacy_summary := _summarize(legacy_samples)
	var production_p50 := float(production_summary["p50"])
	var legacy_p50 := float(legacy_summary["p50"])
	print(
		(
			"ENEMY_SNAPSHOT_COLLECTION_PROBE enemies=%d sweeps_per_sample=%d "
			+ "samples=%d production_ms=%s legacy_allocating_ms=%s speedup_p50=%.2f"
		)
		% [
			ENEMY_COUNT,
			SWEEPS_PER_SAMPLE,
			SAMPLE_BATCHES,
			_format_summary(production_summary),
			_format_summary(legacy_summary),
			legacy_p50 / maxf(production_p50, 0.001),
		]
	)
	_verify_removal_prunes_cached_state()
	await _finish()


func _spawn_frozen_enemies() -> void:
	for enemy_index in range(ENEMY_COUNT):
		var enemy := BASIC_CONFIG.enemy_scene.instantiate() as Enemy
		if enemy == null:
			continue
		enemy.set_meta(&"net_id", enemy_index + 1)
		game.enemy_container.add_child(enemy)
		enemy.global_position = FIXTURE_ORIGIN + Vector2(
			float(enemy_index % 30) * 8.0,
			float(enemy_index / 30) * 8.0
		)
		enemy.setup(BASIC_CONFIG, game.player, null)
		enemy.current_health = 1000 + enemy_index
		enemy.velocity = Vector2(float(enemy_index % 7), -float(enemy_index % 5))
		enemy.set_process(false)
		enemy.set_physics_process(false)
		enemy.collision_layer = 0
		enemy.collision_mask = 0
		enemy.touch_damage_area.monitoring = false
		enemy.touch_damage_area.monitorable = false
		enemy.touch_damage_area.collision_layer = 0
		enemy.touch_damage_area.collision_mask = 0
		enemies.append(enemy)


func _verify_collection_semantics_and_reuse() -> void:
	var first := game.collect_enemy_snapshot_states()
	var first_state_refs: Array[SnapshotManager.EnemyState] = []
	first_state_refs.assign(first)
	_expect(first.size() == ENEMY_COUNT, "Production collection must include all enemies.")
	for state_index in range(first.size()):
		var state := first[state_index]
		var enemy := enemies[state_index]
		_expect(
			state.net_id == state_index + 1
			and state.position == enemy.global_position
			and state.velocity == enemy.velocity
			and state.health == enemy.current_health
			and not state.is_dead,
			"Production collection must preserve child order and every encoded field."
		)

	enemies[17].global_position += Vector2(3.0, -5.0)
	enemies[17].current_health -= 23
	enemies[17].is_dead = true
	var second := game.collect_enemy_snapshot_states()
	_expect(
		second.size() == ENEMY_COUNT
		and second[17].position == enemies[17].global_position
		and second[17].health == enemies[17].current_health
		and second[17].is_dead,
		"Cached snapshot states must refresh motion, health and death on every sweep."
	)
	for state_index in range(second.size()):
		_expect(
			is_same(first_state_refs[state_index], second[state_index]),
			"Snapshot collection must reuse one EnemyState object per stable net id."
		)
	enemies[17].is_dead = false
	var secondary_enemy: Enemy = enemies.back()
	secondary_enemy.reparent(game.boss_container, true)
	var split_container_states := game.collect_enemy_snapshot_states()
	_expect(
		split_container_states.size() == ENEMY_COUNT
		and split_container_states[ENEMY_COUNT - 1].net_id == ENEMY_COUNT,
		"Snapshot collection must preserve primary-then-secondary container order."
	)
	secondary_enemy.reparent(game.enemy_container, true)

	var runtime_source := FileAccess.get_file_as_string(
		"res://scene/game_runtime_base.gd"
	)
	var helper_start := runtime_source.find("func collect_reused_enemy_snapshot_states(")
	var helper_end := runtime_source.find("\n\nfunc defer_runtime_activation", helper_start)
	var helper_source := runtime_source.substr(helper_start, helper_end - helper_start)
	_expect(
		helper_start >= 0
		and helper_end > helper_start
		and helper_source.contains("for child in container.get_children()")
		and not helper_source.contains("container.get_child(child_index)")
		and not helper_source.contains("var live_ids: Dictionary = {}"),
		"Production snapshot collection must retain native bulk traversal and reusable scratch containers."
	)
	var game_source := FileAccess.get_file_as_string("res://scene/game.gd")
	var tower_source := FileAccess.get_file_as_string(
		"res://scene/game_tower_defense.gd"
	)
	_expect(
		not game_source.contains(
			"var containers: Array[Node] = [enemy_container, boss_container]"
		)
		and not tower_source.contains(
			"var containers: Array[Node] = [enemy_container, boss_container]"
		),
		"Snapshot callers must not rebuild the two-container list on every tick."
	)


func _legacy_collect_enemy_snapshot_states() -> Array[SnapshotManager.EnemyState]:
	legacy_output.clear()
	var live_ids: Dictionary = {}
	var containers: Array[Node] = [game.enemy_container, game.boss_container]
	for container in containers:
		if container == null:
			continue
		for child in container.get_children():
			var enemy := child as Enemy
			if enemy == null or not is_instance_valid(enemy):
				continue
			var net_id := int(enemy.get_meta(&"net_id", enemy.get_instance_id()))
			if net_id <= 0:
				continue
			live_ids[net_id] = true
			var state := (
				legacy_states_by_net_id.get(net_id)
				as SnapshotManager.EnemyState
			)
			if state == null:
				state = SnapshotManager.EnemyState.new()
				legacy_states_by_net_id[net_id] = state
			state.net_id = net_id
			state.position = enemy.global_position
			state.velocity = enemy.velocity
			state.health = enemy.current_health
			state.is_dead = enemy.is_dead
			state.visual_status_mask = enemy.get_collectible_visual_status_mask()
			legacy_output.append(state)
	for cached_id_variant in legacy_states_by_net_id.keys():
		var cached_id := int(cached_id_variant)
		if not live_ids.has(cached_id):
			legacy_states_by_net_id.erase(cached_id)
	return legacy_output


func _measure_production_batch() -> float:
	var checksum := 0
	var started_usec := Time.get_ticks_usec()
	for _sweep_index in range(SWEEPS_PER_SAMPLE):
		var states := game.collect_enemy_snapshot_states()
		checksum += states[0].health + states[states.size() - 1].health
	var elapsed_ms := float(Time.get_ticks_usec() - started_usec) / 1000.0
	_expect(checksum > 0, "Production benchmark must consume collected state.")
	return elapsed_ms


func _measure_legacy_batch() -> float:
	var checksum := 0
	var started_usec := Time.get_ticks_usec()
	for _sweep_index in range(SWEEPS_PER_SAMPLE):
		var states := _legacy_collect_enemy_snapshot_states()
		checksum += states[0].health + states[states.size() - 1].health
	var elapsed_ms := float(Time.get_ticks_usec() - started_usec) / 1000.0
	_expect(checksum > 0, "Legacy benchmark must consume collected state.")
	return elapsed_ms


func _verify_removal_prunes_cached_state() -> void:
	var removed_enemy: Enemy = enemies.pop_back()
	var removed_net_id := int(removed_enemy.get_meta(&"net_id", 0))
	game.enemy_container.remove_child(removed_enemy)
	var states := game.collect_enemy_snapshot_states()
	var state_cache := game.get("_enemy_snapshot_states_by_net_id") as Dictionary
	_expect(
		states.size() == ENEMY_COUNT - 1
		and removed_net_id == ENEMY_COUNT
		and not state_cache.has(removed_net_id),
		"Removing an enemy must prune its cached state on the very next collection."
	)
	removed_enemy.queue_free()


func _summarize(samples: Array[float]) -> Dictionary:
	var sorted := samples.duplicate()
	sorted.sort()
	return {
		"p50": sorted[floori(float(sorted.size()) / 2.0)],
		"p95": sorted[clampi(ceili(sorted.size() * 0.95) - 1, 0, sorted.size() - 1)],
		"max": sorted.back(),
	}


func _format_summary(summary: Dictionary) -> String:
	return "%.3f/%.3f/%.3f" % [
		summary["p50"],
		summary["p95"],
		summary["max"],
	]


func _finish() -> void:
	current_scene = null
	if game != null and is_instance_valid(game):
		game.queue_free()
	for _cleanup_index in range(8):
		await process_frame
		await physics_frame
	if failures.is_empty():
		print("ENEMY_SNAPSHOT_COLLECTION_PERFORMANCE_PROBE_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
