extends SceneTree

const SPAWN_EFFECT_SCENE := preload("res://scene/enemy/yuanshi_insect/yuanshi_insect_spawn_effect.tscn")
const BULLET_SCENE := preload("res://scene/bullet.tscn")
const BASIC_ENEMY_CONFIG := preload("res://resources/config/enemies/yuanshi_insect_basic.tres")
const LINGLAN_ENEMY_CONFIG := preload("res://resources/config/enemies/linglan_boss.tres")
const POOL_SCRIPT := preload("res://scene/session_object_pool.gd")

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
	await _test_direct_xirang_kill_reward()
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
		_expect(pool != null, "Runtime scene must own its session object pool: %s" % runtime_scene_path)
		_expect(
			runtime.get_node_or_null("XirangDropManager") == null,
			"Runtime scene must not retain the removed Xirang orb manager: %s"
			% runtime_scene_path
		)
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
	var spawn_particles := first_lease.get_node_or_null("Particles") as GPUParticles2D
	_expect(
		spawn_particles != null,
		"Pooled spawn accents must use GPU particles instead of the dormant CPU emitter."
	)
	first_lease.set("duration", 0.1)
	first_lease.call("restart_effect")
	_expect(
		spawn_particles != null and spawn_particles.emitting,
		"Restarting a pooled spawn effect must emit its particle accent."
	)
	await create_timer(0.02).timeout
	_expect(tween_pool.release(first_lease), "An active spawn effect must return to its pool.")
	_expect(
		spawn_particles != null and not spawn_particles.emitting,
		"Releasing a spawn effect must stop its GPU emitter before quarantine."
	)
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


func _test_direct_xirang_kill_reward() -> void:
	var runtime_scene := load("res://scene/game.tscn") as PackedScene
	var runtime := runtime_scene.instantiate() as GameRuntimeBase
	_expect(runtime != null, "Direct-reward fixture must instantiate the standard runtime.")
	if runtime == null:
		return
	runtime.set("auto_start_waves", false)
	root.add_child(runtime)
	current_scene = runtime
	await process_frame

	var enemy := BASIC_ENEMY_CONFIG.enemy_scene.instantiate() as Enemy
	_expect(enemy != null, "Direct-reward fixture must instantiate a configured enemy.")
	if enemy == null:
		current_scene = null
		runtime.queue_free()
		await process_frame
		return
	runtime.enemy_container.add_child(enemy)
	enemy.setup(BASIC_ENEMY_CONFIG, runtime.player, runtime.grid_pathfinder)
	enemy.set_process(false)
	enemy.set_physics_process(false)
	var xirang_before := runtime.player.current_xirang
	enemy.call("_die")
	enemy.call("_die")
	await process_frame
	_expect(
		runtime.player.current_xirang
		== xirang_before + BASIC_ENEMY_CONFIG.xirang_kill_reward,
		"Enemy death must settle its configured Xirang kill reward by frame end."
	)
	_expect(
		runtime.player.current_xirang
		== xirang_before + BASIC_ENEMY_CONFIG.xirang_kill_reward,
		"Duplicate enemy death resolution must not grant Xirang twice."
	)
	var zero_reward_enemy := BASIC_ENEMY_CONFIG.enemy_scene.instantiate() as Enemy
	_expect(zero_reward_enemy != null, "Zero-reward override fixture must instantiate an enemy.")
	if zero_reward_enemy != null:
		runtime.enemy_container.add_child(zero_reward_enemy)
		zero_reward_enemy.setup(BASIC_ENEMY_CONFIG, runtime.player, runtime.grid_pathfinder)
		zero_reward_enemy.set_xirang_kill_reward_override(0)
		zero_reward_enemy.call("_die")
		await process_frame
		_expect(
			runtime.player.current_xirang
			== xirang_before + BASIC_ENEMY_CONFIG.xirang_kill_reward,
			"An explicit zero wave reward must grant no Xirang."
		)
	const OVERRIDDEN_REWARD := 37
	var overridden_enemy := BASIC_ENEMY_CONFIG.enemy_scene.instantiate() as Enemy
	_expect(overridden_enemy != null, "Positive-reward override fixture must instantiate an enemy.")
	if overridden_enemy != null:
		runtime.enemy_container.add_child(overridden_enemy)
		overridden_enemy.setup(BASIC_ENEMY_CONFIG, runtime.player, runtime.grid_pathfinder)
		overridden_enemy.set_xirang_kill_reward_override(OVERRIDDEN_REWARD)
		overridden_enemy.call("_die")
		await process_frame
		_expect(
			runtime.player.current_xirang
			== xirang_before
			+ BASIC_ENEMY_CONFIG.xirang_kill_reward
			+ OVERRIDDEN_REWARD,
			"A positive wave reward override must replace the configured amount."
		)
	var boss := LINGLAN_ENEMY_CONFIG.enemy_scene.instantiate() as Enemy
	_expect(boss != null, "Linglan reward regression requires the configured boss scene.")
	if boss != null:
		runtime.get_node("BossContainer").add_child(boss)
		boss.setup(LINGLAN_ENEMY_CONFIG, runtime.player, runtime.grid_pathfinder)
		boss.call("_die")
		await process_frame
		_expect(
			runtime.player.current_xirang
			== xirang_before
			+ BASIC_ENEMY_CONFIG.xirang_kill_reward
			+ OVERRIDDEN_REWARD
			+ LINGLAN_ENEMY_CONFIG.xirang_kill_reward,
			"Linglan death must now grant its configured 500 Xirang reward."
		)
	_expect(
		runtime.get_node_or_null("XirangDropManager") == null,
		"Direct enemy rewards must not create or require a Xirang orb manager."
	)
	current_scene = null
	runtime.queue_free()
	for _cleanup_frame in range(3):
		await process_frame
		await physics_frame


func _test_multiplayer_forwarding_contract() -> void:
	_expect(
		not ResourceLoader.exists("res://scene/xirang_drop.tscn")
		and not ResourceLoader.exists("res://scene/xirang_drop_manager.gd")
		and not ResourceLoader.exists("res://resources/config/xirang_drop.tres"),
		"Xirang orb scene, manager, and config must be deleted, not merely disconnected."
	)
	var enemy_source := FileAccess.get_file_as_string("res://scene/enemy/enemy.gd")
	_expect(
		enemy_source.contains('current_scene.has_method("grant_xirang_kill_reward")')
		and enemy_source.contains(
			'current_scene.call("grant_xirang_kill_reward", reward_amount)'
		),
		"Enemy death rewards must route their effective value through the active root scene."
	)
	for reward_owner_path in [
		"res://scene/enemy/yuanshi_insect/yuanshi_insect.gd",
		"res://scene/enemy/capoo/capoo_ak47.gd",
		"res://scene/enemy/capoo/capoo_knight.gd",
		"res://scene/enemy/capoo_ranged_enemy.gd",
		"res://scene/enemy/capoo/capoo_rpg.gd",
	]:
		var reward_owner_source := FileAccess.get_file_as_string(reward_owner_path)
		_expect(
			not reward_owner_source.contains("_request_xirang_reward(")
			and not reward_owner_source.contains("xirang_drop.tscn")
			and not reward_owner_source.contains("XirangDrop"),
			"Enemy subclasses must not retain Xirang orb creation or collection code: %s"
			% reward_owner_path
		)
	var runtime_source := FileAccess.get_file_as_string("res://scene/game_runtime_base.gd")
	_expect(
		runtime_source.contains("func grant_xirang_kill_reward(")
		and not runtime_source.contains("func spawn_xirang_reward("),
		"The shared runtime must expose direct kill rewards and remove orb spawning."
	)
	var mp_game_source := FileAccess.get_file_as_string("res://scene/multiplayer/mp_game.gd")
	_expect(
		mp_game_source.contains("func grant_xirang_kill_reward(")
		and mp_game_source.contains("if game == null or not net_manager.is_host():")
		and mp_game_source.contains("return game.grant_xirang_kill_reward(")
		and not mp_game_source.contains("const XIRANG_DROP_SCENE")
		and not mp_game_source.contains("var _xirang_orbs")
		and not mp_game_source.contains("func register_xirang_orb(")
		and not mp_game_source.contains("func request_xirang_orb_collected(")
		and not mp_game_source.contains("func _apply_xirang_orb_collected(")
		and not mp_game_source.contains("func _remove_xirang_orb_local("),
		"MpGame must accept direct kill rewards only on the host and forward them to its runtime."
	)
	for compatibility_rpc_signature in [
		"func net_xirang_orb_spawned(orb_id: int, amount: int, spawn_position: Vector2) -> void:\n\tpass",
		"func _rpc_xirang_orb_collected(orb_id: int) -> void:\n\tpass",
		"func net_xirang_granted_all(orb_id: int, amount: int, revision: int) -> void:\n\tpass",
		"func net_xirang_orb_removed(orb_id: int) -> void:\n\tpass",
	]:
		_expect(
			mp_game_source.contains(compatibility_rpc_signature),
			"Protocol-v8 Xirang RPC compatibility shells must remain inert: %s"
			% compatibility_rpc_signature.get_slice("(", 0)
		)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
