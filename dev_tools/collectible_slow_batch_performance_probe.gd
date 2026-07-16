extends SceneTree

# Structural and wall-clock A/B probe for the two retired costs:
# 1. one SceneTreeTimer/callback per slowed enemy;
# 2. one render-frame Enemy._process callback per static slow overlay.
const PLAYER_SCENE := preload("res://scene/player/weishidaier/player_weishidaier.tscn")
const BASIC_CONFIG := preload("res://resources/config/enemies/yuanshi_insect_basic.tres")
const ENEMY_COUNT := 300
# Leave enough headroom for the first post-fixture frame, whose delta includes
# the deliberate 300-instance construction burst in a headless probe.
const SLOW_DURATION := 1.0
const SAMPLE_RENDER_FRAMES := 8

var failures: Array[String] = []
var test_root: Node2D


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	test_root = Node2D.new()
	test_root.name = "CollectibleSlowBatchPerformanceProbe"
	root.add_child(test_root)
	current_scene = test_root

	var legacy := await _run_case(false)
	var optimized := await _run_case(true)
	_verify_ab_contract(legacy, optimized)
	_print_ab_result(legacy, optimized)

	Player.set_collectible_slow_batch_expiry_enabled(true)
	Player.set_collectible_slow_expiry_metrics_enabled(false)
	Enemy.set_slow_only_status_process_optimization_enabled(true)
	Enemy.set_performance_metrics_enabled(false)
	test_root.queue_free()
	for _cleanup_frame in range(4):
		await process_frame
		await physics_frame

	if failures.is_empty():
		print("COLLECTIBLE_SLOW_BATCH_PERFORMANCE_PROBE_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _run_case(optimized: bool) -> Dictionary:
	Player.set_collectible_slow_batch_expiry_enabled(optimized)
	Player.set_collectible_slow_expiry_metrics_enabled(true)
	Enemy.set_slow_only_status_process_optimization_enabled(optimized)
	Enemy.set_performance_metrics_enabled(true)

	var player := PLAYER_SCENE.instantiate() as Player
	test_root.add_child(player)
	player.set_physics_process(false)
	var enemies: Array[Enemy] = []
	for enemy_index in range(ENEMY_COUNT):
		var enemy := BASIC_CONFIG.enemy_scene.instantiate() as Enemy
		test_root.add_child(enemy)
		enemy.setup(BASIC_CONFIG, player, null)
		enemy.set_physics_process(false)
		enemy.current_health = 1000000
		enemies.append(enemy)
	await process_frame

	Player.reset_collectible_slow_expiry_metrics()
	Enemy.reset_performance_metrics()
	var source_id := -910002 if optimized else -910001
	var batch_enemy_refs: Array[WeakRef] = []
	var scheduling_started_usec := Time.get_ticks_usec()
	for enemy in enemies:
		enemy.add_move_speed_modifier(source_id, 0.5)
		player.call(
			"_queue_collectible_enemy_slow_expiry",
			enemy,
			source_id,
			SLOW_DURATION,
			batch_enemy_refs
		)
	player.call(
		"_schedule_collectible_enemy_slow_batch_expiry",
		batch_enemy_refs,
		source_id,
		SLOW_DURATION
	)
	var scheduling_usec := Time.get_ticks_usec() - scheduling_started_usec
	var scheduled_metrics := Player.get_collectible_slow_expiry_metrics()

	var frame_samples_usec: Array[int] = []
	for _sample_index in range(SAMPLE_RENDER_FRAMES):
		var frame_started_usec := Time.get_ticks_usec()
		await process_frame
		frame_samples_usec.append(Time.get_ticks_usec() - frame_started_usec)
	var enemy_metrics := Enemy.get_performance_metrics()
	var active_modifier_count := _count_enemies_with_source(enemies, source_id)
	var active_process_count := _count_processing_enemies(enemies)

	await create_timer(SLOW_DURATION + 0.05).timeout
	var expired_metrics := Player.get_collectible_slow_expiry_metrics()
	var remaining_modifier_count := _count_enemies_with_source(enemies, source_id)
	var remaining_process_count := _count_processing_enemies(enemies)

	for enemy in enemies:
		enemy.queue_free()
	player.queue_free()
	await process_frame
	await physics_frame

	return {
		"optimized": optimized,
		"scheduling_usec": scheduling_usec,
		"scheduled_metrics": scheduled_metrics,
		"expired_metrics": expired_metrics,
		"status_process_calls": int(enemy_metrics.get("status_process_calls", -1)),
		"status_process_usec": int(enemy_metrics.get("status_process_usec", -1)),
		"frame_p50_usec": _percentile(frame_samples_usec, 0.50),
		"frame_p95_usec": _percentile(frame_samples_usec, 0.95),
		"active_modifier_count": active_modifier_count,
		"active_process_count": active_process_count,
		"remaining_modifier_count": remaining_modifier_count,
		"remaining_process_count": remaining_process_count,
	}


func _verify_ab_contract(legacy: Dictionary, optimized: Dictionary) -> void:
	for result in [legacy, optimized]:
		var label := "optimized" if bool(result.get("optimized", false)) else "legacy"
		var scheduled := result.get("scheduled_metrics", {}) as Dictionary
		var expired := result.get("expired_metrics", {}) as Dictionary
		_expect(
			int(result.get("active_modifier_count", -1)) == ENEMY_COUNT,
			"%s A/B cohort must apply the same slow source to all enemies." % label
		)
		_expect(
			int(result.get("remaining_modifier_count", -1)) == 0,
			"%s A/B cohort must remove every modifier at expiry." % label
		)
		_expect(
			int(result.get("remaining_process_count", -1)) == 0,
			"%s A/B cohort must leave no enemy status process enabled after expiry." % label
		)
		_expect(
			int(scheduled.get("target_registrations", -1)) == ENEMY_COUNT,
			"%s A/B cohort must register every target exactly once: %s." % [label, scheduled]
		)
		_expect(
			int(expired.get("removed_modifier_count", -1)) == ENEMY_COUNT,
			"%s A/B cohort must remove every registered target/source pair: %s." % [label, expired]
		)

	var legacy_scheduled := legacy.get("scheduled_metrics", {}) as Dictionary
	var legacy_expired := legacy.get("expired_metrics", {}) as Dictionary
	_expect(
		int(legacy_scheduled.get("timer_count", -1)) == ENEMY_COUNT
		and int(legacy_scheduled.get("legacy_timer_count", -1)) == ENEMY_COUNT
		and int(legacy_scheduled.get("batch_timer_count", -1)) == 0,
		"Legacy A/B must reconstruct one timer per target: %s." % [legacy_scheduled]
	)
	_expect(
		int(legacy_expired.get("expiry_callback_count", -1)) == ENEMY_COUNT,
		"Legacy A/B must reconstruct one expiry callback per target: %s." % [legacy_expired]
	)
	_expect(
		int(legacy.get("active_process_count", -1)) == ENEMY_COUNT
		and int(legacy.get("status_process_calls", -1)) >= ENEMY_COUNT,
		"Legacy A/B must reconstruct per-render-frame slow processing: %s." % [legacy]
	)

	var optimized_scheduled := optimized.get("scheduled_metrics", {}) as Dictionary
	var optimized_expired := optimized.get("expired_metrics", {}) as Dictionary
	_expect(
		int(optimized_scheduled.get("timer_count", -1)) == 1
		and int(optimized_scheduled.get("batch_timer_count", -1)) == 1
		and int(optimized_scheduled.get("legacy_timer_count", -1)) == 0,
		"Optimized A/B must schedule exactly one batch timer: %s." % [optimized_scheduled]
	)
	_expect(
		int(optimized_expired.get("expiry_callback_count", -1)) == 1,
		"Optimized A/B must execute exactly one batch callback: %s." % [optimized_expired]
	)
	_expect(
		int(optimized.get("active_process_count", -1)) == 0
		and int(optimized.get("status_process_calls", -1)) == 0,
		"Optimized A/B must keep slow-only enemies off the render process list: %s." % [optimized]
	)


func _print_ab_result(legacy: Dictionary, optimized: Dictionary) -> void:
	print(
		(
			"COLLECTIBLE_SLOW_BATCH_AB enemies=%d legacy_timers=%d optimized_timers=%d "
			+ "legacy_callbacks=%d optimized_callbacks=%d legacy_process_calls=%d "
			+ "optimized_process_calls=%d legacy_process_usec=%d optimized_process_usec=%d "
			+ "legacy_schedule_usec=%d optimized_schedule_usec=%d legacy_frame_p50_usec=%d "
			+ "optimized_frame_p50_usec=%d legacy_frame_p95_usec=%d optimized_frame_p95_usec=%d"
		)
		% [
			ENEMY_COUNT,
			int((legacy.get("scheduled_metrics", {}) as Dictionary).get("timer_count", -1)),
			int((optimized.get("scheduled_metrics", {}) as Dictionary).get("timer_count", -1)),
			int((legacy.get("expired_metrics", {}) as Dictionary).get("expiry_callback_count", -1)),
			int((optimized.get("expired_metrics", {}) as Dictionary).get("expiry_callback_count", -1)),
			int(legacy.get("status_process_calls", -1)),
			int(optimized.get("status_process_calls", -1)),
			int(legacy.get("status_process_usec", -1)),
			int(optimized.get("status_process_usec", -1)),
			int(legacy.get("scheduling_usec", -1)),
			int(optimized.get("scheduling_usec", -1)),
			int(legacy.get("frame_p50_usec", -1)),
			int(optimized.get("frame_p50_usec", -1)),
			int(legacy.get("frame_p95_usec", -1)),
			int(optimized.get("frame_p95_usec", -1)),
		]
	)


func _count_enemies_with_source(enemies: Array[Enemy], source_id: int) -> int:
	var count := 0
	for enemy in enemies:
		if is_instance_valid(enemy) and enemy.move_speed_modifiers.has(source_id):
			count += 1
	return count


func _count_processing_enemies(enemies: Array[Enemy]) -> int:
	var count := 0
	for enemy in enemies:
		if is_instance_valid(enemy) and enemy.is_processing():
			count += 1
	return count


func _percentile(samples: Array[int], ratio: float) -> int:
	if samples.is_empty():
		return 0
	var sorted_samples := samples.duplicate()
	sorted_samples.sort()
	var index := clampi(ceili(float(sorted_samples.size()) * ratio) - 1, 0, sorted_samples.size() - 1)
	return sorted_samples[index]


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
