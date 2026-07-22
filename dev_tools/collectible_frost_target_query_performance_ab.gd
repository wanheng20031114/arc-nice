extends SceneTree

# A/B for the retired collectible-frost target path. The legacy side requests
# every live enemy and then filters the small frost circle. The production side
# enters the maintained CombatTargetIndex through Player's real bounded-query
# facade. Both paths return the same target set; only candidate discovery is
# timed, so damage/status scheduling cannot hide a broadphase regression.

const PLAYER_SCENE := preload(
	"res://scene/player/weishidaier/player_weishidaier.tscn"
)
const ENEMY_COUNTS := [300, 1000]
const LOCAL_ENEMY_COUNT := 8
const QUERY_RADIUS := 72.0
const QUERY_REPETITIONS := 256
const WARMUP_PAIRS := 3
const SAMPLE_PAIRS := 15


class TestEnemy:
	extends Enemy

	func _ready() -> void:
		pass

	func _physics_process(_delta: float) -> void:
		pass


class FrostQueryRuntime:
	extends Node2D

	var target_index := CombatTargetIndex.new()
	var unordered_query_calls := 0
	var get_all_calls := 0

	func query_combat_targets_unordered_into(
		center: Vector2,
		radius: float,
		result: Array[Enemy]
	) -> void:
		unordered_query_calls += 1
		target_index.query_radius_unordered_into(center, radius, result)

	func get_all_combat_targets() -> Array[Enemy]:
		get_all_calls += 1
		return target_index.get_all_alive()


var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_verify_production_source_routes_every_frost_path()
	for enemy_count_variant in ENEMY_COUNTS:
		await _run_enemy_count(int(enemy_count_variant))
	if failures.is_empty():
		print("COLLECTIBLE_FROST_TARGET_QUERY_PERFORMANCE_AB_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _run_enemy_count(enemy_count: int) -> void:
	var runtime := FrostQueryRuntime.new()
	runtime.name = "FrostQueryRuntime%d" % enemy_count
	root.add_child(runtime)
	current_scene = runtime
	var player := PLAYER_SCENE.instantiate() as Player
	_expect(player != null, "Fixture must instantiate the production player scene.")
	if player == null:
		runtime.queue_free()
		await process_frame
		return
	runtime.add_child(player)
	player.global_position = Vector2.ZERO
	player.set_process(false)
	player.set_physics_process(false)

	var enemies: Array[Enemy] = []
	for enemy_index in range(enemy_count):
		var enemy := _new_tree_safe_test_enemy()
		runtime.add_child(enemy)
		if enemy_index < LOCAL_ENEMY_COUNT:
			enemy.global_position = Vector2(
				float(enemy_index % 4) * 16.0 - 24.0,
				float(enemy_index / 4) * 24.0 - 12.0
			)
		else:
			enemy.global_position = Vector2(
				4096.0 + float(enemy_index % 32) * 12.0,
				4096.0 + float(enemy_index / 32) * 12.0
			)
		enemies.append(enemy)
		runtime.target_index.register_enemy(enemy_index + 1, enemy)

	var indexed_targets: Array[Enemy] = []
	player.call(
		"_query_alive_enemies_in_radius_into",
		player.global_position,
		QUERY_RADIUS,
		indexed_targets
	)
	var legacy_targets := _legacy_collect_local_targets(player, QUERY_RADIUS)
	_expect(
		_same_target_set(indexed_targets, legacy_targets)
		and indexed_targets.size() == LOCAL_ENEMY_COUNT,
		"Indexed and legacy frost queries must return the same %d local targets at %d enemies."
		% [LOCAL_ENEMY_COUNT, enemy_count]
	)
	_expect(
		runtime.unordered_query_calls == 1 and runtime.get_all_calls == 1,
		"Production must issue one bounded query while the explicit legacy control performs the only all-target collection."
	)

	for _warmup_pair in range(WARMUP_PAIRS):
		_measure_indexed_batch(player, indexed_targets)
		_measure_legacy_batch(player)
	var indexed_samples: Array[float] = []
	var legacy_samples: Array[float] = []
	for sample_index in range(SAMPLE_PAIRS):
		if sample_index % 2 == 0:
			indexed_samples.append(_measure_indexed_batch(player, indexed_targets))
			legacy_samples.append(_measure_legacy_batch(player))
		else:
			legacy_samples.append(_measure_legacy_batch(player))
			indexed_samples.append(_measure_indexed_batch(player, indexed_targets))
	var indexed_summary := _summarize(indexed_samples)
	var legacy_summary := _summarize(legacy_samples)
	var indexed_p50 := float(indexed_summary["p50"])
	var legacy_p50 := float(legacy_summary["p50"])
	var speedup := legacy_p50 / maxf(indexed_p50, 0.001)
	print(
		(
			"COLLECTIBLE_FROST_TARGET_QUERY_AB enemies=%d local=%d repetitions=%d "
			+ "indexed_ms=%s legacy_all_scan_ms=%s speedup_p50=%.2f"
		)
		% [
			enemy_count,
			LOCAL_ENEMY_COUNT,
			QUERY_REPETITIONS,
			_format_summary(indexed_summary),
			_format_summary(legacy_summary),
			speedup,
		]
	)
	_expect(
		indexed_p50 < legacy_p50 and speedup >= 2.0,
		"Bounded frost query must materially beat the all-enemy scan at %d enemies (speedup %.2f)."
		% [enemy_count, speedup]
	)

	runtime.target_index.clear()
	current_scene = null
	runtime.queue_free()
	for _cleanup_frame in range(4):
		await process_frame
		await physics_frame


func _measure_indexed_batch(player: Player, result: Array[Enemy]) -> float:
	var checksum := 0
	var started_usec := Time.get_ticks_usec()
	for _query_index in range(QUERY_REPETITIONS):
		player.call(
			"_query_alive_enemies_in_radius_into",
			player.global_position,
			QUERY_RADIUS,
			result
		)
		checksum += result.size()
	var elapsed_ms := float(Time.get_ticks_usec() - started_usec) / 1000.0
	_expect(
		checksum == QUERY_REPETITIONS * LOCAL_ENEMY_COUNT,
		"Indexed timing batch must consume every local target."
	)
	return elapsed_ms


func _measure_legacy_batch(player: Player) -> float:
	var checksum := 0
	var started_usec := Time.get_ticks_usec()
	for _query_index in range(QUERY_REPETITIONS):
		checksum += _legacy_collect_local_targets(player, QUERY_RADIUS).size()
	var elapsed_ms := float(Time.get_ticks_usec() - started_usec) / 1000.0
	_expect(
		checksum == QUERY_REPETITIONS * LOCAL_ENEMY_COUNT,
		"Legacy timing batch must consume every local target."
	)
	return elapsed_ms


func _legacy_collect_local_targets(player: Player, radius: float) -> Array[Enemy]:
	var result: Array[Enemy] = []
	var radius_squared := radius * radius
	for enemy in player.call("_collect_alive_enemies") as Array[Enemy]:
		if enemy == null or not is_instance_valid(enemy) or enemy.is_dead:
			continue
		if player.global_position.distance_squared_to(enemy.global_position) > radius_squared:
			continue
		result.append(enemy)
	return result


func _same_target_set(first: Array[Enemy], second: Array[Enemy]) -> bool:
	if first.size() != second.size():
		return false
	var first_ids: Array[int] = []
	var second_ids: Array[int] = []
	for enemy in first:
		first_ids.append(enemy.get_instance_id())
	for enemy in second:
		second_ids.append(enemy.get_instance_id())
	first_ids.sort()
	second_ids.sort()
	return first_ids == second_ids


func _verify_production_source_routes_every_frost_path() -> void:
	var source := FileAccess.get_file_as_string("res://scene/player/player.gd")
	for function_name in [
		"_trigger_frost_crystal",
		"_trigger_collectible_custom_frost",
		"_apply_collectible_area_frost",
	]:
		var function_source := _extract_function_source(source, function_name)
		_expect(
			not function_source.is_empty()
			and function_source.contains("_query_alive_enemies_in_radius_into(")
			and not function_source.contains("_collect_alive_enemies()"),
			"%s must use the bounded combat-target query instead of collecting every enemy."
			% function_name
		)


func _extract_function_source(source: String, function_name: String) -> String:
	var start := source.find("func %s(" % function_name)
	if start < 0:
		return ""
	var next_function := source.find("\nfunc ", start + 1)
	if next_function < 0:
		return source.substr(start)
	return source.substr(start, next_function - start)


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


func _summarize(samples: Array[float]) -> Dictionary:
	var sorted := samples.duplicate()
	sorted.sort()
	return {
		"p50": sorted[sorted.size() / 2],
		"p95": sorted[clampi(ceili(sorted.size() * 0.95) - 1, 0, sorted.size() - 1)],
		"max": sorted.back(),
	}


func _format_summary(summary: Dictionary) -> String:
	return "%.3f/%.3f/%.3f" % [
		summary["p50"],
		summary["p95"],
		summary["max"],
	]


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
