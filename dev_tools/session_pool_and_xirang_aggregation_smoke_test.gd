extends SceneTree

const SPAWN_EFFECT_SCENE := preload("res://scene/enemy/yuanshi_insect_spawn_effect.tscn")
const BULLET_SCENE := preload("res://scene/bullet.tscn")
const PLAYER_SCENE := preload("res://scene/player/weishidaier/player_weishidaier.tscn")
const POOL_SCRIPT := preload("res://scene/session_object_pool.gd")
const XIRANG_MANAGER_SCRIPT := preload("res://scene/xirang_drop_manager.gd")

var failures: Array[String] = []


class PhysicsReleaseProbe:
	extends Node

	signal release_completed

	var pool: SessionObjectPool = null
	var instance: Node = null
	var release_result := false
	var process_mode_during_release := -1

	func _physics_process(_delta: float) -> void:
		if pool == null or instance == null:
			return
		release_result = pool.release(instance)
		process_mode_during_release = instance.process_mode
		set_physics_process(false)
		release_completed.emit()


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_runtime_scene_wiring()
	await _test_session_pool()
	await _test_physics_callback_release()
	await _test_strict_session_pool()
	await _test_per_bucket_pending_metrics()
	await _test_spawn_effect_tween_isolation()
	await _test_xirang_aggregation()
	await _test_xirang_visual_spawn_budget()
	await _test_invalid_pending_target_preserves_value()
	_test_multiplayer_forwarding_contract()
	if failures.is_empty():
		print("SESSION_POOL_AND_XIRANG_AGGREGATION_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_runtime_scene_wiring() -> void:
	for runtime_scene_path in [
		"res://scene/game.tscn",
		"res://scene/game_tower_defense.tscn",
	]:
		var runtime_scene := load(runtime_scene_path) as PackedScene
		_expect(runtime_scene != null, "Runtime scene resource must load: %s" % runtime_scene_path)
		if runtime_scene == null:
			continue
		var runtime := runtime_scene.instantiate() as GameRuntimeBase
		_expect(runtime != null, "Runtime scene must instantiate: %s" % runtime_scene_path)
		if runtime == null:
			continue
		var pool := runtime.get_node_or_null("SessionObjectPool") as SessionObjectPool
		var manager := runtime.get_node_or_null("XirangDropManager") as XirangDropManager
		_expect(pool != null, "Runtime scene must own its session object pool: %s" % runtime_scene_path)
		_expect(manager != null, "Runtime scene must own its Xirang manager: %s" % runtime_scene_path)
		if pool != null:
			pool.register_scene(SPAWN_EFFECT_SCENE, 1, 1)
			_expect(
				runtime.has_session_object_pool_scene(SPAWN_EFFECT_SCENE),
				"Runtime pool forwarding must expose registered scenes: %s" % runtime_scene_path
			)
			var forwarded_lease := runtime.acquire_session_object(SPAWN_EFFECT_SCENE, true)
			_expect(
				forwarded_lease != null,
				"Runtime strict acquisition must forward to its pool: %s" % runtime_scene_path
			)
			_expect(
				runtime.release_session_object(forwarded_lease),
				"Runtime release must reject neither its own pool nor active lease: %s"
				% runtime_scene_path
			)
		if manager != null:
			_expect(
				manager.get_node_or_null(manager.drop_parent_path) == runtime.get_node_or_null("EnemyContainer"),
				"Xirang visuals must be parented under the runtime EnemyContainer: %s"
				% runtime_scene_path
			)
		runtime.free()


func _test_session_pool() -> void:
	var pool := POOL_SCRIPT.new() as SessionObjectPool
	root.add_child(pool)
	pool.register_scene(SPAWN_EFFECT_SCENE, 2, 2)
	var initial := pool.get_metrics(SPAWN_EFFECT_SCENE.resource_path)
	_expect(int(initial.get("created", 0)) == 2, "Pool must prewarm the requested capacity.")

	var first := pool.acquire(SPAWN_EFFECT_SCENE)
	var second := pool.acquire(SPAWN_EFFECT_SCENE)
	var overflow := pool.acquire(SPAWN_EFFECT_SCENE)
	_expect(first != null and second != null and overflow != null, "Pool acquire must never drop gameplay work.")
	var peak := pool.get_metrics(SPAWN_EFFECT_SCENE.resource_path)
	_expect(
		int(peak.get("in_use", 0)) == 3
		and int(peak.get("peak_in_use", 0)) == 3
		and int(peak.get("overflow", 0)) == 1,
		"Pool must record elastic overflow and peak use."
	)
	_expect(pool.release(first), "Pool must accept the active lease release.")
	_expect(not pool.release(first), "Pool must reject duplicate releases.")
	await physics_frame
	await physics_frame
	var reused := pool.acquire(SPAWN_EFFECT_SCENE)
	_expect(reused == first, "A released lease must become reusable after the physics quarantine frame.")
	pool.queue_free()
	await process_frame


func _test_physics_callback_release() -> void:
	var pool := POOL_SCRIPT.new() as SessionObjectPool
	root.add_child(pool)
	pool.register_scene(BULLET_SCENE, 1, 1)
	var bullet := pool.acquire(BULLET_SCENE) as Bullet
	_expect(bullet != null, "Physics-callback release fixture must acquire its bullet lease.")
	if bullet == null:
		pool.queue_free()
		await process_frame
		return

	var probe := PhysicsReleaseProbe.new()
	probe.pool = pool
	probe.instance = bullet
	root.add_child(probe)
	await probe.release_completed
	_expect(probe.release_result, "A physics callback must be able to release an active lease.")
	_expect(
		probe.process_mode_during_release != Node.PROCESS_MODE_DISABLED,
		"CollisionObject process-mode shutdown must be deferred outside the physics callback."
	)
	await process_frame
	_expect(
		bullet.process_mode == Node.PROCESS_MODE_DISABLED,
		"The deferred inactive state must commit on the following idle frame."
	)
	_expect(
		not bullet.monitoring and not bullet.monitorable,
		"A physics-released Area2D must leave monitoring before it can be reused."
	)
	await physics_frame
	await physics_frame
	var reused := pool.acquire(BULLET_SCENE) as Bullet
	_expect(
		reused == bullet and reused.process_mode == Node.PROCESS_MODE_INHERIT,
		"The quarantined physics-released lease must reactivate normally."
	)
	if reused != null:
		pool.release(reused)
	probe.queue_free()
	pool.queue_free()
	await process_frame


func _test_strict_session_pool() -> void:
	var pool := POOL_SCRIPT.new() as SessionObjectPool
	root.add_child(pool)
	pool.register_scene(SPAWN_EFFECT_SCENE, 2, 2)
	_expect(pool.is_registered(SPAWN_EFFECT_SCENE), "Registered pool scenes must be discoverable.")
	_expect(not pool.is_registered(BULLET_SCENE), "Unregistered scenes must not enter strict acquisition.")
	_expect(pool.try_acquire(BULLET_SCENE) == null, "Strict acquisition must reject an unregistered scene.")

	var first := pool.try_acquire(SPAWN_EFFECT_SCENE)
	var second := pool.try_acquire(SPAWN_EFFECT_SCENE)
	var dropped := pool.try_acquire(SPAWN_EFFECT_SCENE)
	var saturated := pool.get_metrics(SPAWN_EFFECT_SCENE.resource_path)
	_expect(first != null and second != null, "Strict acquisition must use every retained slot.")
	_expect(dropped == null, "Strict acquisition must not create overflow instances.")
	_expect(
		int(saturated.get("created", 0)) == 2
		and int(saturated.get("in_use", 0)) == 2
		and int(saturated.get("overflow", 0)) == 0
		and int(saturated.get("dropped", 0)) == 1,
		"Strict saturation must preserve capacity and record one dropped visual lease."
	)

	_expect(
		SessionObjectPool.release_to_owner(first),
		"Static safe release must resolve and release the owning pool."
	)
	_expect(
		not SessionObjectPool.release_to_owner(first),
		"Static safe release must reject duplicate release."
	)
	_expect(
		pool.try_acquire(SPAWN_EFFECT_SCENE) == null,
		"Strict acquisition must respect the one-frame release quarantine."
	)
	await physics_frame
	await physics_frame
	var reused := pool.try_acquire(SPAWN_EFFECT_SCENE)
	_expect(reused == first, "Strict acquisition must reuse a quarantined retained instance.")

	var foreign := Node.new()
	root.add_child(foreign)
	_expect(
		not SessionObjectPool.release_to_owner(foreign),
		"Static safe release must reject nodes without a pool owner."
	)
	foreign.queue_free()
	pool.queue_free()
	await process_frame


func _test_per_bucket_pending_metrics() -> void:
	var pool := POOL_SCRIPT.new() as SessionObjectPool
	root.add_child(pool)
	pool.register_scene(SPAWN_EFFECT_SCENE, 1, 1)
	pool.register_scene(BULLET_SCENE, 1, 1)
	var effect := pool.acquire(SPAWN_EFFECT_SCENE)
	var bullet := pool.acquire(BULLET_SCENE)
	_expect(effect != null and bullet != null, "Pending metrics fixture must acquire both scene buckets.")
	_expect(pool.release(effect), "Pending metrics fixture must release its effect lease.")
	var effect_pending := pool.get_metrics(SPAWN_EFFECT_SCENE.resource_path)
	var bullet_before_release := pool.get_metrics(BULLET_SCENE.resource_path)
	_expect(
		int(effect_pending.get("pending_release", 0)) == 1
		and int(bullet_before_release.get("pending_release", -1)) == 0,
		"Pending release metrics must be counted per scene bucket."
	)
	_expect(pool.release(bullet), "Pending metrics fixture must release its bullet lease.")
	var bullet_pending := pool.get_metrics(BULLET_SCENE.resource_path)
	_expect(
		int(bullet_pending.get("pending_release", 0)) == 1,
		"A second bucket must track only its own pending lease."
	)
	await physics_frame
	await physics_frame
	var effect_released := pool.get_metrics(SPAWN_EFFECT_SCENE.resource_path)
	var bullet_released := pool.get_metrics(BULLET_SCENE.resource_path)
	_expect(
		int(effect_released.get("pending_release", -1)) == 0
		and int(bullet_released.get("pending_release", -1)) == 0,
		"Each bucket pending count must clear after quarantine processing."
	)
	pool.queue_free()
	await process_frame


func _test_spawn_effect_tween_isolation() -> void:
	var quarantine_pool := POOL_SCRIPT.new() as SessionObjectPool
	root.add_child(quarantine_pool)
	quarantine_pool.register_scene(SPAWN_EFFECT_SCENE, 1, 1)
	var quarantined_effect := quarantine_pool.acquire(SPAWN_EFFECT_SCENE)
	_expect(quarantine_pool.release(quarantined_effect), "Pool quarantine fixture must release its lease.")
	var immediate_replacement := quarantine_pool.acquire(SPAWN_EFFECT_SCENE)
	_expect(
		immediate_replacement != null and immediate_replacement != quarantined_effect,
		"A released node must not be reacquired within the same physics frame."
	)
	quarantine_pool.queue_free()
	await process_frame

	var tween_pool := POOL_SCRIPT.new() as SessionObjectPool
	root.add_child(tween_pool)
	tween_pool.register_scene(SPAWN_EFFECT_SCENE, 1, 1)
	var first_lease := tween_pool.acquire(SPAWN_EFFECT_SCENE)
	first_lease.set("duration", 0.1)
	first_lease.call("restart_effect")
	await create_timer(0.02).timeout
	_expect(tween_pool.release(first_lease), "An active spawn effect must return to its pool.")
	await physics_frame
	await physics_frame

	var second_lease := tween_pool.acquire(SPAWN_EFFECT_SCENE)
	_expect(second_lease == first_lease, "The tween fixture must reuse the same effect node.")
	second_lease.set("duration", 0.5)
	second_lease.call("restart_effect")
	# The killed first tween would have completed after about 0.162 seconds. The
	# second lease lasts about 0.81 seconds, so it must still be active here.
	await create_timer(0.2).timeout
	var active_metrics := tween_pool.get_metrics(SPAWN_EFFECT_SCENE.resource_path)
	_expect(
		bool(second_lease.get_meta(SessionObjectPool.POOL_ACTIVE_META, false))
		and int(active_metrics.get("in_use", 0)) == 1,
		"A killed tween must not release a later lease of the same pooled node."
	)
	_expect(tween_pool.release(second_lease), "The second effect lease must release cleanly.")
	await physics_frame
	await physics_frame

	var natural_lease := tween_pool.acquire(SPAWN_EFFECT_SCENE)
	natural_lease.set("duration", 0.02)
	natural_lease.call("restart_effect")
	await create_timer(0.1).timeout
	await physics_frame
	var finished_metrics := tween_pool.get_metrics(SPAWN_EFFECT_SCENE.resource_path)
	_expect(
		int(finished_metrics.get("in_use", 0)) == 0
		and int(finished_metrics.get("inactive", 0)) == 1,
		"A naturally completed effect must release itself after the physics quarantine."
	)
	tween_pool.queue_free()
	await process_frame


func _test_xirang_aggregation() -> void:
	var runtime := Node2D.new()
	root.add_child(runtime)
	var enemy_container := Node2D.new()
	enemy_container.name = "EnemyContainer"
	runtime.add_child(enemy_container)
	var manager := XIRANG_MANAGER_SCRIPT.new() as XirangDropManager
	manager.name = "XirangDropManager"
	_expect(
		manager.max_active_visual_drops == 128,
		"The production Xirang visual-node ceiling must default to 128."
	)
	manager.max_active_visual_drops = 4
	runtime.add_child(manager)
	var player := PLAYER_SCENE.instantiate() as Player
	_expect(player != null, "Aggregation fixture requires a real Player target.")
	if player == null:
		runtime.queue_free()
		return
	player.process_mode = Node.PROCESS_MODE_DISABLED
	runtime.add_child(player)
	player.global_position = Vector2(10000.0, 10000.0)

	for amount in range(1, 11):
		_expect(
			manager.spawn_reward(amount, player, Vector2.ZERO, Vector2.ZERO),
			"Every positive reward must be accepted."
		)
	var capped := manager.get_metrics()
	_expect(
		int(capped.get("active_visual_drops", 0)) == 4,
		"Visual Xirang nodes must respect the configured active cap."
	)
	_expect(
		int(capped.get("pending_reward_groups", 0)) == 1
		and int(capped.get("pending_value", 0)) == 45,
		"Rewards above the cap must aggregate without losing value."
	)
	_expect(
		int(capped.get("total_value_requested", 0)) == 55
		and int(capped.get("total_value_spawned", 0)) == 10,
		"Aggregation accounting must distinguish queued and visualized value."
	)

	var first_drop := enemy_container.get_child(0) as XirangDrop
	first_drop.queue_free()
	await process_frame
	await process_frame
	var flushed := manager.get_metrics()
	_expect(
		int(flushed.get("active_visual_drops", 0)) == 4
		and int(flushed.get("pending_value", 0)) == 0,
		"A free visual slot must flush the aggregated reward as one new orb."
	)
	_expect(
		int(flushed.get("total_value_requested", 0)) == 55
		and int(flushed.get("total_value_spawned", 0)) == 55,
		"Flushing must preserve the exact requested reward total."
	)
	runtime.queue_free()
	await process_frame


func _test_invalid_pending_target_preserves_value() -> void:
	var runtime := Node2D.new()
	root.add_child(runtime)
	var enemy_container := Node2D.new()
	enemy_container.name = "EnemyContainer"
	runtime.add_child(enemy_container)
	var manager := XIRANG_MANAGER_SCRIPT.new() as XirangDropManager
	manager.name = "XirangDropManager"
	manager.max_active_visual_drops = 1
	runtime.add_child(manager)
	var player := PLAYER_SCENE.instantiate() as Player
	player.process_mode = Node.PROCESS_MODE_DISABLED
	runtime.add_child(player)
	player.global_position = Vector2(10000.0, 10000.0)

	_expect(manager.spawn_reward(2, player, Vector2.ZERO), "The first reward must occupy the visual slot.")
	_expect(manager.spawn_reward(9, player, Vector2.ZERO), "The second reward must enter aggregation.")
	player.queue_free()
	await process_frame
	var first_drop := enemy_container.get_child(0) as XirangDrop
	first_drop.queue_free()
	await process_frame
	await process_frame
	var preserved := manager.get_metrics()
	_expect(
		int(preserved.get("pending_value", 0)) == 9
		and int(preserved.get("total_value_requested", 0)) == 11
		and int(preserved.get("total_value_spawned", 0)) == 2,
		"An invalid pending target must preserve, not silently discard, its reward value."
	)
	runtime.queue_free()
	await process_frame


func _test_xirang_visual_spawn_budget() -> void:
	var runtime := Node2D.new()
	root.add_child(runtime)
	var enemy_container := Node2D.new()
	enemy_container.name = "EnemyContainer"
	runtime.add_child(enemy_container)
	var manager := XIRANG_MANAGER_SCRIPT.new() as XirangDropManager
	manager.name = "XirangDropManager"
	manager.max_active_visual_drops = 128
	manager.max_visual_spawns_per_frame = 4
	runtime.add_child(manager)
	var player := PLAYER_SCENE.instantiate() as Player
	player.process_mode = Node.PROCESS_MODE_DISABLED
	runtime.add_child(player)
	player.global_position = Vector2(10000.0, 10000.0)

	for _reward_index in range(10):
		_expect(manager.spawn_reward(1, player, Vector2.ZERO), "Budgeted reward must be accepted.")
	var first_frame := manager.get_metrics()
	_expect(
		int(first_frame.get("active_visual_drops", 0)) == 4
		and int(first_frame.get("visual_spawns_this_frame", 0)) == 4
		and int(first_frame.get("pending_value", 0)) == 6,
		"A reward burst must stop visual instantiation at the per-frame budget."
	)
	await process_frame
	await process_frame
	var flushed := manager.get_metrics()
	_expect(
		int(flushed.get("active_visual_drops", 0)) == 5
		and int(flushed.get("pending_value", 0)) == 0
		and int(flushed.get("total_value_requested", 0)) == 10
		and int(flushed.get("total_value_spawned", 0)) == 10,
		"The next-frame aggregate must preserve all value without refilling 128 nodes."
	)
	runtime.queue_free()
	await process_frame


func _test_multiplayer_forwarding_contract() -> void:
	var enemy_source := FileAccess.get_file_as_string("res://scene/enemy/enemy.gd")
	_expect(
		enemy_source.contains('current_scene.has_method("spawn_xirang_reward")')
		and enemy_source.contains('current_scene.call(\n\t\t"spawn_xirang_reward"'),
		"Enemy reward forwarding must route through the active root scene."
	)
	for reward_owner_path in [
		"res://scene/enemy/yuanshi_insect.gd",
		"res://scene/enemy/capoo_ak47.gd",
		"res://scene/enemy/capoo_knight.gd",
		"res://scene/enemy/capoo_ranged_enemy.gd",
		"res://scene/enemy/capoo_rpg.gd",
	]:
		var reward_owner_source := FileAccess.get_file_as_string(reward_owner_path)
		_expect(
			reward_owner_source.contains("_request_xirang_reward("),
			"Every enemy reward implementation must use the shared forwarding path: %s"
			% reward_owner_path
		)
	var mp_game_source := FileAccess.get_file_as_string("res://scene/multiplayer/mp_game.gd")
	_expect(
		mp_game_source.contains("func spawn_xirang_reward(")
		and mp_game_source.contains("if game == null or not net_manager.is_host():")
		and mp_game_source.contains("return game.spawn_xirang_reward("),
		"MpGame must accept rewards only on the host and forward them to its child runtime."
	)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
