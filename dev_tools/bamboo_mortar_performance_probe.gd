extends SceneTree

# Dense diagnostic for the bamboo mortar's actual hot paths. It keeps the
# gameplay scene structure, shared CombatTargetIndex and SessionObjectPool.
# Damage callbacks are count-only here so the 90,000-hit synchronized case can
# stay alive and expose traversal cost; the combined-horde probe separately
# covers production Enemy.apply_damage, feedback, particles and audio limiting.
const MORTAR_SCENE := preload(
	"res://scene/plant_defense/bamboo_mortar.tscn"
)
const MORTAR_CONFIG := preload(
	"res://resources/config/plant_defense/bamboo_mortar.tres"
)
const SHELL_SCENE := preload(
	"res://scene/plant_defense/bamboo_mortar_shell.tscn"
)
const ENEMY_SCENE := preload("res://scene/enemy/enemy.tscn")

const MORTAR_COUNT := 300
const PROXY_MORTAR_COUNT := 300
const ENEMY_COUNT := 300
const ACQUISITION_SWEEP_COUNT := 30
const SYNCHRONIZED_SAMPLE_COUNT := 20
const STAGGERED_BATCH_SIZE := 10
const STAGGERED_BATCH_COUNT := 30
const PROXY_FLIGHT_STEP_COUNT := 61
const TARGET_POSITION := Vector2(96.0, 0.0)
const FRAME_BUDGET_MS := 16.6

var failures: Array[String] = []
var runtime: MortarPerformanceRuntime = null
var mortars: Array[BambooMortar] = []
var proxy_mortars: Array[BambooMortar] = []
var enemies: Array[Enemy] = []


class MortarPerformanceRuntime:
	extends Node2D

	var target_index := CombatTargetIndex.new()
	var session_object_pool: SessionObjectPool = null
	var query_count := 0
	var damage_call_count := 0
	var queued_visual_count := 0

	func install_pool() -> void:
		session_object_pool = SessionObjectPool.new()
		session_object_pool.name = "SessionObjectPool"
		add_child(session_object_pool)
		session_object_pool.register_scene(SHELL_SCENE, 64, 384)

	func query_combat_targets_unordered_into(
		center: Vector2,
		radius: float,
		result: Array[Enemy]
	) -> void:
		query_count += 1
		target_index.query_radius_unordered_into(
			center,
			radius,
			result
		)

	func queue_bamboo_mortar_visual(
		_plant_net_id: int,
		_action_id: int,
		_stage: int,
		_spawn_position: Vector2,
		_landing_position: Vector2
	) -> void:
		queued_visual_count += 1

	func apply_authoritative_plant_enemy_damage(
		_source_id: int,
		_enemy: Enemy,
		_damage: int,
		_impact_direction: Vector2,
		_damage_type: EnemyConfig.DamageType
	) -> bool:
		damage_call_count += 1
		return true

	func has_session_object_pool_scene(scene: PackedScene) -> bool:
		return (
			session_object_pool != null
			and session_object_pool.is_registered(scene)
		)

	func acquire_session_object(
		scene: PackedScene,
		strict: bool = false
	) -> Node:
		if session_object_pool == null:
			return null
		return (
			session_object_pool.try_acquire(scene)
			if strict
			else session_object_pool.acquire(scene)
		)


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	runtime = MortarPerformanceRuntime.new()
	runtime.name = "BambooMortarPerformanceFixture"
	root.add_child(runtime)
	current_scene = runtime
	runtime.install_pool()

	_spawn_mortars()
	var idle_poll_ms := _measure_idle_poll_sweep()
	_spawn_enemies()
	var acquisition_samples := _measure_acquisition_sweeps(
		ACQUISITION_SWEEP_COUNT
	)
	var warm_sync_metrics := _launch_synchronized_burst()
	await _finish_active_shells()
	var warmed_pool_metrics := runtime.session_object_pool.get_metrics(
		SHELL_SCENE.resource_path
	)
	var node_count_after_warmup := _count_subtree_nodes(runtime)
	var synchronized_spawn_samples: Array[float] = []
	var synchronized_impact_samples: Array[float] = []
	for _cycle in range(SYNCHRONIZED_SAMPLE_COUNT):
		var synchronized_metrics := _launch_synchronized_burst()
		synchronized_spawn_samples.append(
			float(synchronized_metrics.get("spawn_ms", 0.0))
		)
		synchronized_impact_samples.append(
			float(synchronized_metrics.get("impact_ms", 0.0))
		)
		await _finish_active_shells()
	var staggered_samples := await _measure_staggered_burst()
	var damage_calls_before_proxy := runtime.damage_call_count
	var proxy_visual_ms := _measure_proxy_visual_batch()
	var proxy_flight_samples := _measure_proxy_flight_steps()
	await _finish_active_shells()
	var final_pool_metrics := runtime.session_object_pool.get_metrics(
		SHELL_SCENE.resource_path
	)
	var final_node_count := _count_subtree_nodes(runtime)

	var acquisition_summary := _summarize(acquisition_samples)
	var synchronized_spawn_summary := _summarize(
		synchronized_spawn_samples
	)
	var synchronized_impact_summary := _summarize(
		synchronized_impact_samples
	)
	var staggered_summary := _summarize(staggered_samples)
	var proxy_flight_summary := _summarize(proxy_flight_samples)
	var expected_authoritative_shells := (
		(1 + SYNCHRONIZED_SAMPLE_COUNT) * MORTAR_COUNT
		+ STAGGERED_BATCH_COUNT * STAGGERED_BATCH_SIZE
	)
	var expected_query_count := (
		MORTAR_COUNT * 2
		+ ACQUISITION_SWEEP_COUNT * MORTAR_COUNT
		+ expected_authoritative_shells
	)
	var expected_damage_calls := (
		expected_authoritative_shells * ENEMY_COUNT
	)
	_expect(
		mortars.size() == MORTAR_COUNT
		and proxy_mortars.size() == PROXY_MORTAR_COUNT
		and enemies.size() == ENEMY_COUNT,
		"性能探针必须完整建立300座权威迫击炮、300座客户端代理和300个敌人。"
	)
	_expect(
		int(warmed_pool_metrics.get("created", 0)) == MORTAR_COUNT
		and int(warmed_pool_metrics.get("peak_in_use", 0)) == MORTAR_COUNT
		and int(warmed_pool_metrics.get("retained_capacity", 0)) == 384,
		"64预热/384保留池必须承载300枚同帧炮弹且不丢失。"
	)
	_expect(
		int(final_pool_metrics.get("created", -1))
		== int(warmed_pool_metrics.get("created", -2))
		and int(final_pool_metrics.get("in_use", -1)) == 0
		and int(final_pool_metrics.get("pending_release", -1)) == 0
		and final_node_count == node_count_after_warmup,
		"热身后重复同步与错峰攻击不得增长池节点，结束时全部租约必须归零。"
	)
	_expect(
		runtime.damage_call_count == damage_calls_before_proxy,
		"300条客户端蓄热/出膛视觉记录不得执行敌人查询或权威伤害。"
	)
	_expect(
		runtime.query_count == expected_query_count
		and runtime.damage_call_count == expected_damage_calls
		and runtime.queued_visual_count == expected_authoritative_shells,
		"性能探针必须跑满预期索引查询、密集命中与权威视觉记录，不能以空查询获得虚假性能。"
	)
	_expect(
		float(staggered_summary.get("p95_ms", INF))
		< FRAME_BUDGET_MS,
		"300座迫击炮错峰攻击的p95逻辑帧开销必须低于16.6ms。"
	)
	_expect(
		float(proxy_flight_summary.get("p95_ms", INF))
		< FRAME_BUDGET_MS,
		"300枚客户端视觉炮弹的逐帧飞行p95必须低于16.6ms。"
	)

	var sync_spawn_max := float(
		synchronized_spawn_summary.get("max_ms", 0.0)
	)
	var sync_impact_max := float(
		synchronized_impact_summary.get("max_ms", 0.0)
	)
	var sync_risk := (
		maxf(sync_spawn_max, sync_impact_max) >= FRAME_BUDGET_MS
	)
	print(
		(
			"BAMBOO_MORTAR_PERFORMANCE_PROBE mortars=%d proxies=%d enemies=%d "
			+ "idle_poll_ms=%.3f acquisition_p50/p95/p99/max_ms="
			+ "%.3f/%.3f/%.3f/%.3f warm_sync_spawn/impact_ms=%.3f/%.3f "
			+ "sync_spawn_p50/p95/p99/max_ms=%.3f/%.3f/%.3f/%.3f "
			+ "sync_impact_p50/p95/p99/max_ms=%.3f/%.3f/%.3f/%.3f "
			+ "staggered_p50/p95/p99/max_ms=%.3f/%.3f/%.3f/%.3f "
			+ "proxy_300_apply_ms=%.3f "
			+ "proxy_flight_p50/p95/p99/max_ms=%.3f/%.3f/%.3f/%.3f "
			+ "queries=%d damage_calls=%d visual_records=%d damage_mode=count_only "
			+ "pool_created/peak/in_use=%d/%d/%d sync_16_6ms_risk=%s"
		)
		% [
			mortars.size(),
			proxy_mortars.size(),
			enemies.size(),
			idle_poll_ms,
			float(acquisition_summary.get("p50_ms", 0.0)),
			float(acquisition_summary.get("p95_ms", 0.0)),
			float(acquisition_summary.get("p99_ms", 0.0)),
			float(acquisition_summary.get("max_ms", 0.0)),
			float(warm_sync_metrics.get("spawn_ms", 0.0)),
			float(warm_sync_metrics.get("impact_ms", 0.0)),
			float(synchronized_spawn_summary.get("p50_ms", 0.0)),
			float(synchronized_spawn_summary.get("p95_ms", 0.0)),
			float(synchronized_spawn_summary.get("p99_ms", 0.0)),
			sync_spawn_max,
			float(synchronized_impact_summary.get("p50_ms", 0.0)),
			float(synchronized_impact_summary.get("p95_ms", 0.0)),
			float(synchronized_impact_summary.get("p99_ms", 0.0)),
			sync_impact_max,
			float(staggered_summary.get("p50_ms", 0.0)),
			float(staggered_summary.get("p95_ms", 0.0)),
			float(staggered_summary.get("p99_ms", 0.0)),
			float(staggered_summary.get("max_ms", 0.0)),
			proxy_visual_ms,
			float(proxy_flight_summary.get("p50_ms", 0.0)),
			float(proxy_flight_summary.get("p95_ms", 0.0)),
			float(proxy_flight_summary.get("p99_ms", 0.0)),
			float(proxy_flight_summary.get("max_ms", 0.0)),
			runtime.query_count,
			runtime.damage_call_count,
			runtime.queued_visual_count,
			int(final_pool_metrics.get("created", 0)),
			int(final_pool_metrics.get("peak_in_use", 0)),
			int(final_pool_metrics.get("in_use", 0)),
			str(sync_risk),
		]
	)
	if sync_risk:
		push_warning(
			"竹筒迫击炮300座同帧出膛或一秒后同帧爆炸的独立峰值超过16.6ms；这是刻意同步的最坏情况，必须在交付报告中单独披露。"
		)
	await _finish()


func _spawn_mortars() -> void:
	for mortar_index in range(MORTAR_COUNT):
		var mortar := MORTAR_SCENE.instantiate() as BambooMortar
		if mortar == null:
			continue
		mortar.set_meta(&"net_id", mortar_index + 1)
		runtime.add_child(mortar)
		mortar.collision_layer = 0
		mortar.setup(MORTAR_CONFIG, null, [], false)
		mortar.attack_timer.stop()
		mortar.target_track_timer.stop()
		mortars.append(mortar)
	for proxy_index in range(PROXY_MORTAR_COUNT):
		var proxy := MORTAR_SCENE.instantiate() as BambooMortar
		if proxy == null:
			continue
		proxy.set_meta(&"net_id", 1001 + proxy_index)
		runtime.add_child(proxy)
		proxy.collision_layer = 0
		proxy.setup(MORTAR_CONFIG, null, [], true)
		proxy_mortars.append(proxy)


func _spawn_enemies() -> void:
	for enemy_index in range(ENEMY_COUNT):
		var enemy := ENEMY_SCENE.instantiate() as Enemy
		if enemy == null:
			continue
		runtime.add_child(enemy)
		enemy.global_position = Vector2(
			80.0 + float(enemy_index % 17) * 2.0,
			-24.0 + float((enemy_index / 17) % 7) * 8.0
		)
		enemy.is_dead = false
		enemy.collision_layer = 0
		enemy.collision_mask = 0
		enemy.set_process(false)
		enemy.set_physics_process(false)
		if enemy.touch_damage_area != null:
			enemy.touch_damage_area.monitoring = false
			enemy.touch_damage_area.monitorable = false
		runtime.target_index.register_enemy(enemy_index + 1, enemy)
		enemies.append(enemy)


func _measure_idle_poll_sweep() -> float:
	var started := Time.get_ticks_usec()
	for mortar in mortars:
		mortar.call("_on_attack_timer_timeout")
		mortar.attack_timer.stop()
	return float(Time.get_ticks_usec() - started) / 1000.0


func _measure_acquisition_sweeps(count: int) -> Array[float]:
	var samples: Array[float] = []
	for _sweep in range(count):
		var started := Time.get_ticks_usec()
		for mortar in mortars:
			mortar.call("_select_nearest_target_in_ring")
		samples.append(
			float(Time.get_ticks_usec() - started) / 1000.0
		)
	return samples


func _launch_synchronized_burst() -> Dictionary:
	var spawn_started := Time.get_ticks_usec()
	for mortar in mortars:
		_prepare_and_fire(mortar)
	var spawn_ms := float(
		Time.get_ticks_usec() - spawn_started
	) / 1000.0
	var impact_started := Time.get_ticks_usec()
	for child in runtime.session_object_pool.get_children():
		var shell := child as BambooMortarShell
		if (
			shell != null
			and bool(
				shell.get_meta(
					SessionObjectPool.POOL_ACTIVE_META,
					false
				)
			)
			and not bool(shell.get("_has_impacted"))
		):
			shell.call("_impact")
	var impact_ms := float(
		Time.get_ticks_usec() - impact_started
	) / 1000.0
	return {
		"spawn_ms": spawn_ms,
		"impact_ms": impact_ms,
	}


func _measure_staggered_burst() -> Array[float]:
	var samples: Array[float] = []
	for batch_index in range(STAGGERED_BATCH_COUNT):
		var started := Time.get_ticks_usec()
		var batch_start := batch_index * STAGGERED_BATCH_SIZE
		var batch_end := mini(
			batch_start + STAGGERED_BATCH_SIZE,
			mortars.size()
		)
		for mortar_index in range(batch_start, batch_end):
			_prepare_and_fire(mortars[mortar_index])
		for child in runtime.session_object_pool.get_children():
			var shell := child as BambooMortarShell
			if (
				shell != null
				and bool(
					shell.get_meta(
						SessionObjectPool.POOL_ACTIVE_META,
						false
					)
				)
				and not bool(shell.get("_has_impacted"))
			):
				shell.call("_impact")
				shell.call("_on_visual_animation_finished")
		samples.append(
			float(Time.get_ticks_usec() - started) / 1000.0
		)
		await physics_frame
		await physics_frame
	return samples


func _measure_proxy_visual_batch() -> float:
	var started := Time.get_ticks_usec()
	for proxy_index in range(proxy_mortars.size()):
		var proxy := proxy_mortars[proxy_index]
		var action_id := proxy_index + 1
		proxy.play_multiplayer_action(
			BambooMortar.NETWORK_STAGE_WINDUP,
			action_id,
			proxy.muzzle.global_position,
			TARGET_POSITION,
			1.25
		)
		proxy.play_multiplayer_action(
			BambooMortar.NETWORK_STAGE_FIRE,
			action_id,
			proxy.muzzle.global_position,
			TARGET_POSITION,
			0.0
		)
	return float(Time.get_ticks_usec() - started) / 1000.0


func _measure_proxy_flight_steps() -> Array[float]:
	var samples: Array[float] = []
	for _step in range(PROXY_FLIGHT_STEP_COUNT):
		var started := Time.get_ticks_usec()
		for child in runtime.session_object_pool.get_children():
			var shell := child as BambooMortarShell
			if (
				shell != null
				and bool(
					shell.get_meta(
						SessionObjectPool.POOL_ACTIVE_META,
						false
					)
				)
				and not bool(shell.get("_has_impacted"))
			):
				shell.call("_physics_process", 1.0 / 60.0)
		samples.append(
			float(Time.get_ticks_usec() - started) / 1000.0
		)
	return samples


func _prepare_and_fire(mortar: BambooMortar) -> void:
	mortar.attack_timer.stop()
	mortar.target_track_timer.stop()
	mortar.combat_phase = BambooMortar.CombatPhase.WINDUP
	mortar.next_authoritative_action_id += 1
	mortar.last_valid_target_position = TARGET_POSITION
	mortar.pending_target = null
	mortar.call("_fire_authoritative_shell")
	mortar.attack_timer.stop()


func _finish_active_shells() -> void:
	for child in runtime.session_object_pool.get_children():
		var shell := child as BambooMortarShell
		if (
			shell == null
			or not bool(
				shell.get_meta(
					SessionObjectPool.POOL_ACTIVE_META,
					false
				)
			)
		):
			continue
		if not bool(shell.get("_has_impacted")):
			shell.call("_impact")
		shell.call("_on_visual_animation_finished")
	await physics_frame
	await physics_frame


func _summarize(source: Array[float]) -> Dictionary:
	if source.is_empty():
		return {
			"p50_ms": 0.0,
			"p95_ms": 0.0,
			"p99_ms": 0.0,
			"max_ms": 0.0,
		}
	var sorted := source.duplicate()
	sorted.sort()
	return {
		"p50_ms": _percentile(sorted, 0.50),
		"p95_ms": _percentile(sorted, 0.95),
		"p99_ms": _percentile(sorted, 0.99),
		"max_ms": sorted.back(),
	}


func _percentile(sorted: Array[float], ratio: float) -> float:
	if sorted.is_empty():
		return 0.0
	var index := clampi(
		ceili(float(sorted.size()) * ratio) - 1,
		0,
		sorted.size() - 1
	)
	return sorted[index]


func _count_subtree_nodes(node: Node) -> int:
	var count := 1
	for child in node.get_children():
		count += _count_subtree_nodes(child)
	return count


func _finish() -> void:
	await _finish_active_shells()
	runtime.target_index.clear()
	current_scene = null
	runtime.queue_free()
	for _frame in range(4):
		await process_frame
		await physics_frame
	if failures.is_empty():
		print("BAMBOO_MORTAR_PERFORMANCE_PROBE_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
