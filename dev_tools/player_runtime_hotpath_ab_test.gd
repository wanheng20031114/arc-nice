extends SceneTree

const PLAYER_SCENE := preload("res://scene/player/weishidaier/player_weishidaier.tscn")
const BENCHMARK_SAMPLE_COUNT := 5
const SCHEDULER_ITERATIONS := 30_000
const VISUAL_ITERATIONS := 30_000
const STAT_REFRESH_ITERATIONS := 10_000
const FIRE_INTERVAL_ITERATIONS := 30_000
const SYNTHETIC_PERIODIC_COUNT := 14

var failures: Array[String] = []
var test_root: Node2D


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	test_root = Node2D.new()
	test_root.name = "PlayerRuntimeHotpathABTest"
	root.add_child(test_root)
	current_scene = test_root

	var player := PLAYER_SCENE.instantiate() as Player
	test_root.add_child(player)
	await process_frame
	await physics_frame
	player.set_physics_process(false)

	_test_periodic_deadline_semantics(player)
	_test_trigger_deadline_semantics(player)
	_test_runtime_state_pruning_boundary(player)
	_test_randomized_deadline_oracle(player)
	_test_multiplayer_authority_semantics(player)
	_test_movement_visual_state_cache(player)
	_test_attack_speed_change_gate(player)

	var fire_interval_samples := _benchmark_fire_interval_change_gate(player)
	_configure_stat_refresh_benchmark(player)
	var stat_refresh_samples := _benchmark_stat_refresh(player)
	_configure_scheduler_benchmark(player)
	player.call("_update_collectible_runtime_effects", 0.0)
	var scheduler_samples := _benchmark_collectible_scheduler(player)
	var visual_samples := _benchmark_movement_visuals(player)
	print(
		(
			"PLAYER_RUNTIME_HOTPATH_AB scheduler_median_us=%d scheduler_samples=%s "
			+ "visual_idle_median_us=%d visual_idle_samples=%s "
			+ "visual_move_median_us=%d visual_move_samples=%s "
			+ "visual_haste_median_us=%d visual_haste_samples=%s "
			+ "stat_refresh_median_us=%d stat_refresh_samples=%s "
			+ "fire_gate_median_us=%d fire_gate_samples=%s "
			+ "fire_legacy_median_us=%d fire_legacy_samples=%s"
		)
		% [
			_median(scheduler_samples),
			str(scheduler_samples),
			_median(visual_samples["idle"]),
			str(visual_samples["idle"]),
			_median(visual_samples["move"]),
			str(visual_samples["move"]),
			_median(visual_samples["haste"]),
			str(visual_samples["haste"]),
			_median(stat_refresh_samples),
			str(stat_refresh_samples),
			_median(fire_interval_samples["cached"]),
			str(fire_interval_samples["cached"]),
			_median(fire_interval_samples["legacy"]),
			str(fire_interval_samples["legacy"]),
		]
	)

	player.queue_free()
	test_root.queue_free()
	for _cleanup_frame in range(4):
		await process_frame
		await physics_frame

	if failures.is_empty():
		print("PLAYER_RUNTIME_HOTPATH_AB_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_periodic_deadline_semantics(player: Player) -> void:
	var item := PickupConfig.new()
	item.collectible_effect_id = "periodic_deadline_probe"
	item.periodic_effect_id = PickupConfig.PERIODIC_EFFECT_HEAL
	item.periodic_interval = 1.0
	item.periodic_radius = 1.0
	item.periodic_heal = 1
	_configure_single_periodic_item(player, item)
	player.current_health = player.max_health - 8
	var initial_health := player.current_health

	player.call("_update_collectible_runtime_effects", 0.4)
	_expect(
		player.current_health == initial_health,
		"A periodic collectible must not trigger before its complete first interval."
	)
	var deadline := float(
		player.collectible_periodic_deadlines.get(item.collectible_effect_id, -1.0)
	)
	_expect(
		is_equal_approx(deadline - player._collectible_periodic_elapsed, 0.6),
		"The first periodic deadline must retain the exact delta-based remainder."
	)
	player.call("_update_collectible_runtime_effects", 0.59)
	_expect(
		player.current_health == initial_health,
		"A periodic collectible must remain pending immediately before its deadline."
	)
	player.call("_update_collectible_runtime_effects", 0.011)
	_expect(
		player.current_health == initial_health + 1,
		"A periodic collectible must trigger exactly once when its deadline is crossed."
	)

	var health_before_hitch := player.current_health
	player.call("_update_collectible_runtime_effects", 2.5)
	_expect(
		player.current_health == health_before_hitch + 1,
		"A long frame must preserve the legacy one-trigger-per-update behavior."
	)
	deadline = float(
		player.collectible_periodic_deadlines.get(item.collectible_effect_id, -1.0)
	)
	_expect(
		is_equal_approx(deadline - player._collectible_periodic_elapsed, 1.0),
		"A periodic trigger after a hitch must restart one full interval from now."
	)


func _test_trigger_deadline_semantics(player: Player) -> void:
	_clear_periodic_items(player)
	var item := PickupConfig.new()
	item.collectible_effect_id = "trigger_deadline_probe"
	item.trigger_effect_id = "probe"
	item.trigger_cooldown = 1.0
	player.collectible_trigger_deadlines.clear()
	player._next_collectible_trigger_deadline = INF

	_expect(
		bool(player.call("_try_start_collectible_trigger_cooldown", item)),
		"A trigger cooldown must admit its first event."
	)
	player.call("_update_collectible_runtime_effects", 0.4)
	_expect(
		not bool(player.call("_try_start_collectible_trigger_cooldown", item)),
		"A trigger cooldown must reject an event before expiry."
	)
	player.call("_update_collectible_runtime_effects", 0.59)
	_expect(
		not bool(player.call("_try_start_collectible_trigger_cooldown", item)),
		"A trigger cooldown must stay closed immediately before expiry."
	)
	player.call("_update_collectible_runtime_effects", 0.011)
	var trigger_key: String = player.call("_get_collectible_trigger_key", item)
	_expect(
		not player.collectible_trigger_deadlines.has(trigger_key),
		"The event-gated cleanup must erase a trigger as its deadline is crossed."
	)
	_expect(
		bool(player.call("_try_start_collectible_trigger_cooldown", item)),
		"A trigger cooldown must reopen immediately after its deadline."
	)


func _test_randomized_deadline_oracle(player: Player) -> void:
	var random := RandomNumberGenerator.new()
	random.seed = 0xC011EC71
	var periodic_items: Array[PickupConfig] = []
	var periodic_remaining: Dictionary = {}
	player.collectible_shot_counters.clear()
	player.active_collectible_runtime_keys_cache.clear()
	player.active_collectible_items_cache.clear()
	player.active_periodic_collectible_items_cache.clear()
	player.active_periodic_collectible_keys_cache.clear()
	player.collectible_periodic_deadlines.clear()
	player._collectible_periodic_elapsed = 0.0
	player._next_collectible_periodic_deadline = 0.0
	for index in range(SYNTHETIC_PERIODIC_COUNT):
		var item := PickupConfig.new()
		item.collectible_effect_id = "periodic_oracle_%d" % index
		item.periodic_effect_id = "oracle_noop"
		item.periodic_interval = 0.25 + float(index) * 0.07
		periodic_items.append(item)
		player.active_collectible_items_cache.append(item)
		player.active_periodic_collectible_items_cache.append(item)
		player.active_periodic_collectible_keys_cache.append(item.collectible_effect_id)
	player.active_collectible_cache_initialized = true

	for step in range(500):
		var delta := (
			0.9
			if step % 17 == 0
			else random.randf_range(0.001, 0.12)
		)
		player.call("_update_collectible_runtime_effects", delta)
		for item in periodic_items:
			var key := item.collectible_effect_id
			var remaining := float(
				periodic_remaining.get(key, item.periodic_interval)
			) - delta
			if remaining <= 0.0:
				remaining = maxf(item.periodic_interval, 0.1)
			periodic_remaining[key] = remaining
			var actual_remaining := float(
				player.collectible_periodic_deadlines.get(key, -INF)
			) - player._collectible_periodic_elapsed
			if not is_equal_approx(actual_remaining, remaining):
				failures.append(
					"Periodic deadline oracle mismatch at step %d key %s: %.6f != %.6f"
					% [step, key, actual_remaining, remaining]
				)
				return

	_clear_periodic_items(player)
	player.collectible_trigger_deadlines.clear()
	player._collectible_runtime_elapsed = 0.0
	player._next_collectible_trigger_deadline = INF
	var trigger_items: Array[PickupConfig] = []
	var trigger_remaining: Dictionary = {}
	for index in range(SYNTHETIC_PERIODIC_COUNT):
		var item := PickupConfig.new()
		item.collectible_effect_id = "trigger_oracle_%d" % index
		item.trigger_effect_id = "oracle_%d" % index
		item.trigger_cooldown = 0.2 + float(index) * 0.05
		trigger_items.append(item)
		trigger_remaining[item.collectible_effect_id] = 0.0

	for step in range(500):
		var delta := random.randf_range(0.001, 0.08)
		player.call("_update_collectible_runtime_effects", delta)
		for item in trigger_items:
			var key := item.collectible_effect_id
			trigger_remaining[key] = maxf(
				float(trigger_remaining.get(key, 0.0)) - delta,
				0.0
			)
			if (step + key.hash()) % 4 != 0:
				continue
			var expected_admitted := (
				float(trigger_remaining.get(key, 0.0)) <= 0.0
			)
			var actual_admitted := bool(
				player.call("_try_start_collectible_trigger_cooldown", item)
			)
			if actual_admitted != expected_admitted:
				failures.append(
					"Trigger deadline oracle mismatch at step %d key %s."
					% [step, key]
				)
				return
			if actual_admitted:
				trigger_remaining[key] = item.trigger_cooldown


func _test_runtime_state_pruning_boundary(player: Player) -> void:
	player.active_collectible_runtime_keys_cache.clear()
	player.active_collectible_runtime_keys_cache["keep"] = true
	player.collectible_periodic_deadlines = {
		"keep": 10.0,
		"drop": 5.0,
	}
	player.collectible_shot_counters = {
		"keep": 2,
		"drop": 3,
	}
	player.collectible_trigger_deadlines = {
		"keep::hit": 11.0,
		"drop::hit": 4.0,
	}
	player._next_collectible_periodic_deadline = 5.0
	player._next_collectible_trigger_deadline = 4.0
	player.call("_prune_inactive_collectible_runtime_state")
	_expect(
		player.collectible_periodic_deadlines.has("keep")
		and not player.collectible_periodic_deadlines.has("drop")
		and player.collectible_shot_counters.has("keep")
		and not player.collectible_shot_counters.has("drop")
		and player.collectible_trigger_deadlines.has("keep::hit")
		and not player.collectible_trigger_deadlines.has("drop::hit"),
		"An inventory rebuild must prune only runtime state whose owner disappeared."
	)
	_expect(
		is_zero_approx(player._next_collectible_periodic_deadline)
		and is_zero_approx(player._next_collectible_trigger_deadline),
		"Pruning a possible earliest entry must invalidate both deadline minima."
	)

	player._next_collectible_periodic_deadline = 10.0
	player._next_collectible_trigger_deadline = 11.0
	player.call("_refresh_collectible_stats", false)
	_expect(
		is_equal_approx(player._next_collectible_periodic_deadline, 10.0)
		and is_equal_approx(player._next_collectible_trigger_deadline, 11.0),
		"A health/stat refresh must not repeat inventory-owned runtime pruning."
	)


func _test_multiplayer_authority_semantics(player: Player) -> void:
	var net_manager := root.get_node_or_null("NetManager") as NetManagerStore
	_expect(net_manager != null, "The authority probe requires the NetManager autoload.")
	if net_manager == null:
		return
	var old_role := net_manager.net_role
	var old_connection_state := net_manager.connection_state
	var old_disconnect_in_progress := bool(net_manager.get("_disconnect_in_progress"))

	var item := PickupConfig.new()
	item.collectible_effect_id = "authority_periodic_probe"
	item.periodic_effect_id = PickupConfig.PERIODIC_EFFECT_HEAL
	item.periodic_interval = 1.0
	item.periodic_radius = 1.0
	item.periodic_heal = 1
	_configure_single_periodic_item(player, item)
	player.current_health = player.max_health - 8
	var initial_health := player.current_health

	net_manager.set("_disconnect_in_progress", false)
	net_manager.net_role = NetManagerStore.NetRole.CLIENT
	net_manager.connection_state = NetManagerStore.ConnectionState.IN_GAME
	player.call("_update_collectible_runtime_effects", 2.0)
	_expect(
		player.current_health == initial_health
		and player.collectible_periodic_deadlines.is_empty(),
		"A multiplayer client must neither trigger nor arm authoritative periodic effects."
	)

	net_manager.net_role = NetManagerStore.NetRole.HOST
	player.call("_update_collectible_runtime_effects", 0.4)
	_expect(
		player.current_health == initial_health,
		"A promoted host must begin a fresh full periodic interval."
	)
	player.call("_update_collectible_runtime_effects", 0.6)
	_expect(
		player.current_health == initial_health + 1,
		"Only the multiplayer host may trigger the periodic effect."
	)
	var host_periodic_time := player._collectible_periodic_elapsed
	net_manager.net_role = NetManagerStore.NetRole.CLIENT
	player.call("_update_collectible_runtime_effects", 4.0)
	_expect(
		is_equal_approx(player._collectible_periodic_elapsed, host_periodic_time),
		"Losing authority must pause an already armed periodic deadline."
	)
	net_manager.net_role = NetManagerStore.NetRole.HOST
	player.call("_update_collectible_runtime_effects", 0.99)
	_expect(
		player.current_health == initial_health + 1,
		"Regaining authority must preserve the pre-demotion periodic remainder."
	)
	player.call("_update_collectible_runtime_effects", 0.011)
	_expect(
		player.current_health == initial_health + 2,
		"A restored host deadline must trigger only after its remaining game delta."
	)

	net_manager.net_role = old_role
	net_manager.connection_state = old_connection_state
	net_manager.set("_disconnect_in_progress", old_disconnect_in_progress)


func _test_movement_visual_state_cache(player: Player) -> void:
	var sprite := player.get_node("BodySprite") as AnimatedSprite2D
	var speed_trail := player.get_node("MoveSpeedTrailEffect") as Node2D
	player.cold_stack_count = 0
	player.speed_buff_time_left = 0.0
	player.collectible_swift_time_left = 0.0
	player.network_effective_move_speed_multiplier_override = 0.0
	player.velocity = Vector2.ZERO
	player.call("_update_movement_status_visuals", Vector2.ZERO)
	_expect(
		is_zero_approx(_get_instance_shader_float(sprite, &"slow_overlay_strength")),
		"The cached visual path must keep an unslowed player overlay clear."
	)

	player.cold_stack_count = 1
	player.call("_update_movement_status_visuals", Vector2.ZERO)
	_expect(
		_get_instance_shader_float(sprite, &"slow_overlay_strength") > 0.0,
		"A cold state transition must still publish the slow overlay."
	)
	for _repeat in range(16):
		player.call("_update_movement_status_visuals", Vector2.ZERO)
	_expect(
		is_equal_approx(player._slow_overlay_strength, Player.SLOW_OVERLAY_ACTIVE_STRENGTH),
		"Repeated unchanged slow updates must retain the cached shader state."
	)

	player.cold_stack_count = 0
	player.speed_buff_time_left = 10.0
	player.current_move_speed_multiplier = 1.5
	player.velocity = Vector2.RIGHT * 120.0
	player.call("_update_movement_status_visuals", Vector2.RIGHT)
	_expect(
		speed_trail.visible and player._speed_trail_effect_active,
		"A moving haste transition must still activate the speed trail."
	)
	player.call("_update_movement_status_visuals", Vector2.LEFT)
	_expect(
		(Vector2(speed_trail.get("motion_direction"))).is_equal_approx(Vector2.LEFT),
		"A live direction transition must still rotate the cached speed trail."
	)
	player.speed_buff_time_left = 0.0
	player.current_move_speed_multiplier = 1.0
	player.call("_update_movement_status_visuals", Vector2.LEFT)
	_expect(
		not speed_trail.visible and not player._speed_trail_effect_active,
		"Ending haste must still disable the speed trail."
	)


func _test_attack_speed_change_gate(player: Player) -> void:
	player.rapid_fire_rate_multiplier = 1.0
	player.call("_refresh_shooting_timer_wait_time")
	var signal_count := [0]
	var count_signal := func(_attack_speed: float) -> void:
		signal_count[0] += 1
	player.attack_speed_changed.connect(count_signal)

	player.call("_refresh_shooting_timer_wait_time")
	_expect(
		int(signal_count[0]) == 0,
		"An unchanged fire interval must not emit a false attack-speed change."
	)
	player.rapid_fire_rate_multiplier = 1.25
	player.call("_refresh_shooting_timer_wait_time")
	player.call("_refresh_shooting_timer_wait_time")
	_expect(
		int(signal_count[0]) == 1,
		"A changed fire interval must emit once, then remain quiet while stable."
	)
	player.rapid_fire_rate_multiplier = 1.0
	player.call("_refresh_shooting_timer_wait_time")
	_expect(
		int(signal_count[0]) == 2,
		"Restoring the base fire interval must emit one final change event."
	)
	player.attack_speed_changed.disconnect(count_signal)


func _configure_single_periodic_item(player: Player, item: PickupConfig) -> void:
	player.active_collectible_items_cache.clear()
	player.active_collectible_items_cache.append(item)
	player.active_periodic_collectible_items_cache.clear()
	player.active_periodic_collectible_items_cache.append(item)
	player.active_periodic_collectible_keys_cache.clear()
	player.active_periodic_collectible_keys_cache.append(item.collectible_effect_id)
	player.active_collectible_cache_initialized = true
	player.collectible_periodic_deadlines.clear()
	player._next_collectible_periodic_deadline = 0.0


func _clear_periodic_items(player: Player) -> void:
	player.active_collectible_items_cache.clear()
	player.active_periodic_collectible_items_cache.clear()
	player.active_periodic_collectible_keys_cache.clear()
	player.collectible_periodic_deadlines.clear()
	player._next_collectible_periodic_deadline = INF


func _configure_scheduler_benchmark(player: Player) -> void:
	player.active_periodic_collectible_items_cache.clear()
	player.active_periodic_collectible_keys_cache.clear()
	player.collectible_periodic_deadlines.clear()
	player.collectible_trigger_deadlines.clear()
	player._next_collectible_periodic_deadline = 0.0
	player._next_collectible_trigger_deadline = INF
	for index in range(SYNTHETIC_PERIODIC_COUNT):
		var item := PickupConfig.new()
		item.collectible_effect_id = "scheduler_probe_%d" % index
		item.periodic_effect_id = "benchmark_noop"
		item.periodic_interval = 1_000_000_000.0
		player.active_periodic_collectible_items_cache.append(item)
		player.active_periodic_collectible_keys_cache.append(item.collectible_effect_id)
		var trigger_deadline := player._collectible_runtime_elapsed + 1_000_000_000.0
		player.collectible_trigger_deadlines["trigger_probe_%d" % index] = trigger_deadline
		player._next_collectible_trigger_deadline = minf(
			player._next_collectible_trigger_deadline,
			trigger_deadline
		)


func _configure_stat_refresh_benchmark(player: Player) -> void:
	player.active_collectible_items_cache.clear()
	player.collectible_periodic_deadlines.clear()
	player.collectible_trigger_deadlines.clear()
	for index in range(RunStateStore.INVENTORY_CAPACITY):
		var item := PickupConfig.new()
		item.collectible_effect_id = "stat_refresh_probe_%d" % index
		item.periodic_effect_id = "benchmark_noop"
		item.periodic_interval = 10.0
		item.trigger_effect_id = "benchmark_noop"
		player.active_collectible_items_cache.append(item)
		player.collectible_periodic_deadlines[item.collectible_effect_id] = 10.0
		player.collectible_trigger_deadlines[
			"%s::%s" % [item.collectible_effect_id, item.trigger_effect_id]
		] = 10.0
	player.active_collectible_cache_initialized = true


func _benchmark_fire_interval_change_gate(player: Player) -> Dictionary:
	var result := {
		"cached": [] as Array[int],
		"legacy": [] as Array[int],
	}
	var probe_label := Label.new()
	test_root.add_child(probe_label)
	var update_label := func(attack_speed: float) -> void:
		probe_label.text = "%.2f" % attack_speed
	player.attack_speed_changed.connect(update_label)
	player.rapid_fire_rate_multiplier = 1.0
	player.call("_refresh_shooting_timer_wait_time")
	var stable_interval := player._get_effective_fire_interval()
	for _sample_index in range(BENCHMARK_SAMPLE_COUNT):
		var started_usec := Time.get_ticks_usec()
		for _iteration in range(FIRE_INTERVAL_ITERATIONS):
			player.call("_refresh_shooting_timer_wait_time")
		(result["cached"] as Array[int]).append(Time.get_ticks_usec() - started_usec)

		started_usec = Time.get_ticks_usec()
		for _iteration in range(FIRE_INTERVAL_ITERATIONS):
			player.shooting_timer.wait_time = stable_interval
			player.attack_speed_changed.emit(player.get_attack_speed())
		(result["legacy"] as Array[int]).append(Time.get_ticks_usec() - started_usec)
	player.attack_speed_changed.disconnect(update_label)
	probe_label.queue_free()
	return result


func _benchmark_stat_refresh(player: Player) -> Array[int]:
	var samples: Array[int] = []
	for _sample_index in range(BENCHMARK_SAMPLE_COUNT):
		var started_usec := Time.get_ticks_usec()
		for _iteration in range(STAT_REFRESH_ITERATIONS):
			player.call("_refresh_collectible_stats", false)
		samples.append(Time.get_ticks_usec() - started_usec)
	return samples


func _benchmark_collectible_scheduler(player: Player) -> Array[int]:
	var samples: Array[int] = []
	for _sample_index in range(BENCHMARK_SAMPLE_COUNT):
		var started_usec := Time.get_ticks_usec()
		for _iteration in range(SCHEDULER_ITERATIONS):
			player.call("_update_collectible_runtime_effects", 1.0 / 60.0)
		samples.append(Time.get_ticks_usec() - started_usec)
	return samples


func _benchmark_movement_visuals(player: Player) -> Dictionary:
	var result := {
		"idle": [] as Array[int],
		"move": [] as Array[int],
		"haste": [] as Array[int],
	}
	player.cold_stack_count = 0
	player.speed_buff_time_left = 0.0
	player.current_move_speed_multiplier = 1.0
	player.collectible_swift_time_left = 0.0
	player.network_effective_move_speed_multiplier_override = 0.0
	player.velocity = Vector2.ZERO
	player.call("_update_movement_status_visuals", Vector2.ZERO)
	for _sample_index in range(BENCHMARK_SAMPLE_COUNT):
		var started_usec := Time.get_ticks_usec()
		for _iteration in range(VISUAL_ITERATIONS):
			player.call("_update_movement_status_visuals", Vector2.ZERO)
		(result["idle"] as Array[int]).append(Time.get_ticks_usec() - started_usec)

	player.velocity = Vector2.RIGHT * 120.0
	player.call("_update_movement_status_visuals", Vector2.RIGHT)
	for _sample_index in range(BENCHMARK_SAMPLE_COUNT):
		var started_usec := Time.get_ticks_usec()
		for _iteration in range(VISUAL_ITERATIONS):
			player.call("_update_movement_status_visuals", Vector2.RIGHT)
		(result["move"] as Array[int]).append(Time.get_ticks_usec() - started_usec)

	player.speed_buff_time_left = 1_000_000_000.0
	player.current_move_speed_multiplier = 1.5
	player.call("_update_movement_status_visuals", Vector2.RIGHT)
	for _sample_index in range(BENCHMARK_SAMPLE_COUNT):
		var started_usec := Time.get_ticks_usec()
		for _iteration in range(VISUAL_ITERATIONS):
			player.call("_update_movement_status_visuals", Vector2.RIGHT)
		(result["haste"] as Array[int]).append(Time.get_ticks_usec() - started_usec)
	return result


func _median(values: Array[int]) -> int:
	var sorted_values := values.duplicate()
	sorted_values.sort()
	return sorted_values[sorted_values.size() / 2]


func _get_instance_shader_float(
	canvas_item: CanvasItem,
	parameter_name: StringName
) -> float:
	if canvas_item == null:
		return 0.0
	var value: Variant = canvas_item.get_instance_shader_parameter(parameter_name)
	return float(value) if value != null else 0.0


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
