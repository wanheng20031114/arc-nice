extends SceneTree

const PLAYER_SCENE := preload("res://scene/player/weishidaier/player_weishidaier.tscn")
const PLAYER_TEST_RUNTIME := preload("res://dev_tools/player_test_combat_runtime.gd")
const BASIC_ENEMY_CONFIG := preload("res://resources/config/enemies/yuanshi_insect_basic.tres")
const CLAY_TOTEM := preload("res://resources/config/collectibles/collectible_clay_totem.tres")
const LIFE_RING := preload("res://resources/config/collectibles/collectible_life_ring.tres")
const RUBY := preload("res://resources/config/collectibles/collectible_ruby.tres")
const APPLE := preload("res://resources/config/collectibles/collectible_apple.tres")
const LIFE_CRYSTAL := preload("res://resources/config/collectibles/collectible_life_crystal.tres")
const HOT_PATH_ITERATIONS := 100_000
const LEGACY_SCAN_ITERATIONS := 10_000

var failures: Array[String] = []
var test_root: PlayerTestCombatRuntime
var run_state: RunStateStore
var observed_xirang_signal_count := 0


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	test_root = PLAYER_TEST_RUNTIME.new() as PlayerTestCombatRuntime
	test_root.name = "PlayerCollectibleCacheSmokeTest"
	root.add_child(test_root)
	current_scene = test_root
	run_state = root.get_node("RunState") as RunStateStore

	await _test_preowned_health_condition_and_maximum_changes()
	await _test_peer_keyed_cache_and_first_configuration_health()
	await _test_periodic_cache_and_allocation_free_runtime_shape()
	await _test_reusable_homing_query_at_two_positions()

	run_state.set_active_multiplayer_peer(0)
	test_root.queue_free()
	for _cleanup_frame in range(6):
		await process_frame
		await physics_frame

	if failures.is_empty():
		print("PLAYER_COLLECTIBLE_CACHE_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_preowned_health_condition_and_maximum_changes() -> void:
	run_state.begin_new_run(&"weishidaier", false)
	_expect(run_state.try_add_item(CLAY_TOTEM), "Preowned clay totem must fit.")
	var player := await _spawn_player(Vector2.ZERO)
	var base_defense := int(player.get("_base_physical_defense"))
	var base_max_health := int(player.get("_base_max_health"))
	_expect(player.current_health == player.max_health, "A newly ready player must start at full derived health.")
	_expect(
		player.physical_defense == base_defense,
		"A preowned low-health collectible must not activate from construction-time zero health."
	)

	player.current_health = ceili(float(base_max_health) * 0.45)
	player.refresh_collectible_stats()
	_expect(player.physical_defense == base_defense, "45% health must keep the clay totem inactive.")
	_expect(run_state.try_add_item(LIFE_RING), "Life ring threshold probe must fit.")
	_expect(
		player.max_health == base_max_health + LIFE_RING.collectible_max_health_bonus,
		"Life ring must publish its prospective maximum in one refresh."
	)
	_expect(
		player.physical_defense == base_defense + CLAY_TOTEM.conditional_physical_defense_bonus,
		"The life-ring denominator change must activate the clay totem during the same inventory refresh."
	)
	_expect(run_state.discard_item(1), "Life ring threshold probe must be removable.")
	_expect(player.max_health == base_max_health, "Removing the life ring must restore the base maximum.")
	_expect(
		player.physical_defense == base_defense,
		"The restored base denominator must deactivate the clay totem during the same inventory refresh."
	)

	player.current_health = floori(float(base_max_health) * 0.39)
	player.refresh_collectible_stats()
	_expect(player.physical_defense == base_defense + 2, "Below-40% health must activate the clay totem.")
	var healing_amount := ceili(float(base_max_health) * 0.1)
	_expect(bool(player.call("_try_heal", healing_amount)), "Health-condition healing probe must succeed.")
	_expect(
		float(player.current_health) / float(player.max_health) > 0.4,
		"Healing probe must cross above the 40% threshold."
	)
	_expect(player.physical_defense == base_defense, "Healing above 40% must deactivate the clay totem immediately.")
	await _free_player(player)


func _test_peer_keyed_cache_and_first_configuration_health() -> void:
	run_state.begin_new_run(&"weishidaier", false)
	run_state.register_multiplayer_peer_state(2)
	run_state.register_multiplayer_peer_state(3)
	_expect(run_state.try_add_item_for_peer(2, LIFE_RING), "Peer 2 life ring must fit.")
	for copy_index in range(6):
		_expect(
			run_state.try_add_item_for_peer(2, APPLE),
			"Peer 2 apple copy %d must fit." % (copy_index + 1)
		)
	run_state.set_active_multiplayer_peer(3)

	var peer_two := await _spawn_player(Vector2(-40.0, 0.0))
	var base_max_health := int(peer_two.get("_base_max_health"))
	peer_two.configure_multiplayer_control(2, false, "Peer 2")
	_expect(
		peer_two.max_health == base_max_health + LIFE_RING.collectible_max_health_bonus,
		"Peer 2 must bind its own life-ring maximum."
	)
	_expect(
		peer_two.current_health == peer_two.max_health,
		"First peer binding must preserve a full-health spawn when inventories have different maxima."
	)
	_expect(
		is_equal_approx(peer_two.get_inventory_bullet_pierce_chance(), 1.0),
		"Peer 2 must apply exactly the first five of six carried apples."
	)
	_expect(
		peer_two.active_collectible_items_cache.size() == 6,
		"Peer 2 cache must contain one life ring plus five active apple copies."
	)

	run_state.set_active_multiplayer_peer(2)
	var peer_three := await _spawn_player(Vector2(40.0, 0.0))
	peer_three.configure_multiplayer_control(3, false, "Peer 3")
	_expect(peer_three.max_health == base_max_health, "Peer 3 must not inherit peer 2's life ring.")
	_expect(peer_three.current_health == peer_three.max_health, "Peer 3 must remain full after rebinding from a larger temporary maximum.")
	_expect(peer_three.active_collectible_items_cache.is_empty(), "Peer 3 cache must begin empty.")
	_expect(is_zero_approx(peer_three.get_inventory_bullet_pierce_chance()), "Peer 3 must not inherit peer 2's apples.")

	var peer_two_attack := peer_two.attack_damage
	var peer_three_attack := peer_three.attack_damage
	_expect(run_state.try_add_item_for_peer(3, RUBY), "Peer 3 ruby must fit.")
	_expect(peer_two.attack_damage == peer_two_attack, "A peer 3 inventory signal must not alter peer 2 stats.")
	_expect(peer_three.attack_damage > peer_three_attack, "A peer 3 inventory signal must refresh peer 3 stats.")
	_expect(peer_two.active_collectible_items_cache.size() == 6, "Global inventory_changed must rebuild peer 2 from peer 2 data.")
	_expect(peer_three.active_collectible_items_cache.size() == 1, "Global inventory_changed must rebuild peer 3 from peer 3 data.")

	var peer_three_base_defense := int(peer_three.get("_base_physical_defense"))
	_expect(run_state.try_add_item_for_peer(3, CLAY_TOTEM), "Peer 3 clay totem must fit.")
	peer_three.set_multiplayer_health_state(
		floori(float(peer_three.max_health) * 0.39),
		false
	)
	_expect(
		peer_three.physical_defense == peer_three_base_defense + 2,
		"Authoritative multiplayer health updates must activate health conditions."
	)
	peer_three.set_multiplayer_health_state(peer_three.max_health, false)
	_expect(
		peer_three.physical_defense == peer_three_base_defense,
		"Authoritative multiplayer healing must deactivate health conditions."
	)

	observed_xirang_signal_count = 0
	peer_three.xirang_changed.connect(_count_observed_xirang_signal)
	_apply_realtime_probe(peer_three, peer_three.current_xirang)
	_expect(
		observed_xirang_signal_count == 0,
		"An unchanged realtime xirang snapshot must not emit a false changed event."
	)
	_apply_realtime_probe(peer_three, peer_three.current_xirang + 10)
	_expect(
		observed_xirang_signal_count == 1,
		"A changed realtime xirang snapshot must emit exactly one changed event."
	)

	await _free_player(peer_two)
	await _free_player(peer_three)
	run_state.set_active_multiplayer_peer(0)


func _test_periodic_cache_and_allocation_free_runtime_shape() -> void:
	run_state.begin_new_run(&"weishidaier", false)
	for copy_index in range(RunStateStore.INVENTORY_CAPACITY - 1):
		_expect(run_state.try_add_item(RUBY), "Runtime cache ruby copy %d must fit." % (copy_index + 1))
	_expect(run_state.try_add_item(LIFE_CRYSTAL), "Runtime cache periodic collectible must fit.")
	var player := await _spawn_player(Vector2.ZERO)
	player.set_physics_process(false)
	_expect(
		player.active_collectible_items_cache.size() == RunStateStore.INVENTORY_CAPACITY,
		"The active cache must retain every uncapped stacked ruby plus the periodic item."
	)
	_expect(player.active_periodic_collectible_items_cache.size() == 1, "Periodic cache must contain only the life crystal.")
	_expect(player.active_periodic_collectible_keys_cache.size() == 1, "Periodic runtime keys must stay parallel to periodic items.")
	player.active_collectible_items_cache.clear()
	player.active_periodic_collectible_items_cache.clear()
	player.active_periodic_collectible_keys_cache.clear()
	player.active_collectible_cache_initialized = true
	player.refresh_collectible_stats()
	_expect(
		player.active_collectible_items_cache.size() == RunStateStore.INVENTORY_CAPACITY
		and player.active_periodic_collectible_items_cache.size() == 1,
		"The public collectible refresh API must explicitly rebuild every cache."
	)

	player.collectible_periodic_deadlines.clear()
	player._next_collectible_periodic_deadline = 0.0
	player.call("_update_collectible_runtime_effects", 1.0)
	var periodic_key := player.active_periodic_collectible_keys_cache[0]
	_expect(
		is_equal_approx(
			float(player.collectible_periodic_deadlines.get(periodic_key, -1.0))
			- player._collectible_periodic_elapsed,
			LIFE_CRYSTAL.periodic_interval - 1.0
		),
		"Periodic cooldown must advance once by the requested delta."
	)
	player.collectible_trigger_deadlines["cache_probe_a"] = (
		player._collectible_runtime_elapsed + 0.25
	)
	player.collectible_trigger_deadlines["cache_probe_b"] = (
		player._collectible_runtime_elapsed + 0.75
	)
	player._next_collectible_trigger_deadline = (
		player._collectible_runtime_elapsed + 0.25
	)
	player.call("_update_collectible_runtime_effects", 0.5)
	_expect(not player.collectible_trigger_deadlines.has("cache_probe_a"), "Expired trigger cooldowns must be erased after traversal.")
	_expect(
		is_equal_approx(
			float(player.collectible_trigger_deadlines.get("cache_probe_b", -1.0))
			- player._collectible_runtime_elapsed,
			0.25
		),
		"Live trigger cooldowns must retain exact remaining time."
	)

	var source := FileAccess.get_file_as_string("res://scene/player/player.gd")
	var function_start := source.find("func _update_collectible_runtime_effects")
	var function_end := source.find("\nfunc ", function_start + 5)
	var hot_path_source := source.substr(function_start, function_end - function_start)
	_expect(function_start >= 0 and function_end > function_start, "Collectible runtime function must be readable for hot-path audit.")
	_expect(
		not hot_path_source.contains("_get_active_collectible_items"),
		"The physics-frame collectible runtime must not rescan RunState."
	)
	_expect(
		not hot_path_source.contains("collectible_trigger_deadlines.keys()"),
		"The physics-frame cooldown runtime must not allocate a keys array."
	)
	_expect(
		hot_path_source.contains(
			"_collectible_runtime_elapsed >= _next_collectible_trigger_deadline"
		),
		"Trigger cooldown cleanup must stay gated by the earliest absolute deadline."
	)

	var started_usec := Time.get_ticks_usec()
	for _iteration in range(HOT_PATH_ITERATIONS):
		player.call("_update_collectible_runtime_effects", 0.0)
	var elapsed_usec := Time.get_ticks_usec() - started_usec
	var legacy_item_count_checksum := 0
	var legacy_started_usec := Time.get_ticks_usec()
	for _iteration in range(LEGACY_SCAN_ITERATIONS):
		legacy_item_count_checksum += _simulate_legacy_active_collectible_scan(player)
	var legacy_elapsed_usec := Time.get_ticks_usec() - legacy_started_usec
	var hot_path_usec_per_update := float(elapsed_usec) / float(HOT_PATH_ITERATIONS)
	var legacy_usec_per_scan := float(legacy_elapsed_usec) / float(LEGACY_SCAN_ITERATIONS)
	print(
		"PLAYER_COLLECTIBLE_CACHE_PERF iterations=%d active=%d periodic=%d elapsed_us=%d us_per_update=%.4f legacy_scan_us=%.4f speedup=%.2fx checksum=%d"
		% [
			HOT_PATH_ITERATIONS,
			player.active_collectible_items_cache.size(),
			player.active_periodic_collectible_items_cache.size(),
			elapsed_usec,
			hot_path_usec_per_update,
			legacy_usec_per_scan,
			legacy_usec_per_scan / maxf(hot_path_usec_per_update, 0.0001),
			legacy_item_count_checksum,
		]
	)
	await _free_player(player)


func _test_reusable_homing_query_at_two_positions() -> void:
	run_state.begin_new_run(&"weishidaier", false)
	var player := await _spawn_player(Vector2.ZERO)
	player.set_physics_process(false)
	var near_enemy := await _spawn_enemy(Vector2(48.0, 0.0), player)
	var far_enemy := await _spawn_enemy(Vector2(96.0, 0.0), player)
	var left_enemy := await _spawn_enemy(Vector2(-32.0, 0.0), player)
	await physics_frame

	var shape_instance_id := player._homing_target_shape.get_instance_id()
	var query_instance_id := player._homing_target_query.get_instance_id()
	_expect(
		player.call("_find_homing_bullet_target", Vector2.RIGHT) == near_enemy,
		"The first homing query must choose the nearest enemy inside the forward cone."
	)
	_expect(
		player.call("_find_homing_bullet_target", Vector2.LEFT) == left_enemy,
		"Changing direction must query the opposite cone without stale results."
	)

	player.global_position = Vector2(320.0, 0.0)
	near_enemy.global_position = Vector2(120.0, 80.0)
	far_enemy.global_position = Vector2(380.0, 0.0)
	left_enemy.global_position = Vector2(250.0, 0.0)
	await physics_frame
	_expect(
		player.call("_find_homing_bullet_target", Vector2.RIGHT) == far_enemy,
		"The reused query must update its transform after the player moves."
	)
	_expect(
		player._homing_target_shape.get_instance_id() == shape_instance_id
		and player._homing_target_query.get_instance_id() == query_instance_id,
		"Homing target searches must reuse one shape and one query object."
	)

	near_enemy.queue_free()
	far_enemy.queue_free()
	left_enemy.queue_free()
	await _free_player(player)
	await physics_frame


func _simulate_legacy_active_collectible_scan(player: Player) -> int:
	var result: Array[PickupConfig] = []
	var active_copy_counts: Dictionary = {}
	for slot_index in range(RunStateStore.INVENTORY_CAPACITY):
		var item := (
			run_state.get_item_for_peer(player.peer_id, slot_index)
			if player.peer_id > 0
			else run_state.get_item(slot_index)
		)
		if item == null or item.pickup_type != PickupConfig.PickupType.COLLECTIBLE:
			continue
		var effect_key: String = player.call("_get_collectible_runtime_key", item)
		var active_copies := int(active_copy_counts.get(effect_key, 0))
		if not item.collectible_stacks_by_copy:
			if active_copies > 0:
				continue
			active_copy_counts[effect_key] = 1
			result.append(item)
			continue
		var copies_to_activate := (
			run_state.get_item_count_for_peer(player.peer_id, slot_index)
			if player.peer_id > 0
			else run_state.get_item_count(slot_index)
		)
		if item.collectible_max_copies > 0:
			copies_to_activate = mini(
				copies_to_activate,
				maxi(item.collectible_max_copies - active_copies, 0)
			)
		for _copy_index in range(copies_to_activate):
			result.append(item)
		active_copy_counts[effect_key] = active_copies + copies_to_activate
	return result.size()


func _apply_realtime_probe(player: Player, xirang: int) -> void:
	player.apply_multiplayer_realtime_state(
		player.current_health,
		player.max_health,
		xirang,
		false,
		player.invincibility_time_left,
		player.skill1_unlocked,
		player.skill1_charge,
		player.skill1_charge_duration,
		PickupConfig.PlayerFormMode.NORMAL,
		PickupConfig.ShotPattern.NORMAL
	)


func _count_observed_xirang_signal(_total: int, _added_amount: int) -> void:
	observed_xirang_signal_count += 1


func _spawn_player(spawn_position: Vector2) -> Player:
	var player := PLAYER_SCENE.instantiate() as Player
	player.global_position = spawn_position
	test_root.add_child(player)
	test_root.bind_player_runtime_context(player)
	await process_frame
	await physics_frame
	return player


func _spawn_enemy(spawn_position: Vector2, player: Player) -> Enemy:
	var enemy := BASIC_ENEMY_CONFIG.enemy_scene.instantiate() as Enemy
	test_root.add_child(enemy)
	enemy.setup(BASIC_ENEMY_CONFIG, player, null)
	enemy.global_position = spawn_position
	enemy.set_physics_process(false)
	await process_frame
	return enemy


func _free_player(player: Player) -> void:
	player.queue_free()
	await process_frame
	await physics_frame


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
