extends SceneTree

# 300-unit worst-case diagnostic for the Bamboo Mortar production path.
# Performance thresholds are deliberately non-blocking: this fixture models an
# impossible synchronized load and reports its risks, while functional
# assertions still prevent empty-query or bypassed-batcher "wins".
const MORTAR_SCENE := preload(
	"res://scene/plant_defense/bamboo_mortar.tscn"
)
const MORTAR_CONFIG := preload(
	"res://resources/config/plant_defense/bamboo_mortar.tres"
)
const SHELL_SCENE := preload(
	"res://scene/plant_defense/bamboo_mortar_shell.tscn"
)
const COMBAT_SYSTEM_SCENE := preload(
	"res://scene/plant_defense/bamboo_mortar_combat_system.tscn"
)
const ENEMY_CONFIG := preload(
	"res://resources/config/enemies/yuanshi_insect_basic.tres"
)

const MORTAR_COUNT := 300
const PROXY_MORTAR_COUNT := 300
const ENEMY_COUNT := 300
const SYNCHRONIZED_TARGET_SAMPLE_COUNT := 20
const STAGGERED_TARGET_BATCH_SIZE := 10
const STAGGERED_TARGET_BATCH_COUNT := 30
const SYNCHRONIZED_EXPLOSION_SAMPLE_COUNT := 20
const STAGGERED_EXPLOSION_BATCH_SIZE := 10
const STAGGERED_EXPLOSION_BATCH_COUNT := 30
# 0.55 s maximum flight at 60 Hz, plus the terminal impact step.
const PROXY_FLIGHT_STEP_COUNT := 34
const TARGET_POSITION := Vector2(96.0, 0.0)
const FRAME_BUDGET_MS := 16.6
const MAX_TARGET_DRAIN_GUARD_FRAMES := MORTAR_COUNT
const EXPECTED_SYNCHRONIZED_LOGICAL_HITS := (
	MORTAR_COUNT * ENEMY_COUNT
)

var failures: Array[String] = []
var runtime: MortarPerformanceRuntime = null
var mortars: Array[BambooMortar] = []
var proxy_mortars: Array[BambooMortar] = []
var enemies: Array[Enemy] = []
var enemy_ids := PackedInt32Array()


class MortarPerformanceRuntime:
	extends Node2D

	var target_index := CombatTargetIndex.new()
	var session_object_pool: SessionObjectPool = null
	var combat_system: BambooMortarCombatSystem = null
	var query_count := 0
	var visual_record_count := 0
	var batch_call_count := 0
	var damage_number_count := 0

	func install_runtime_systems() -> void:
		session_object_pool = SessionObjectPool.new()
		session_object_pool.name = "SessionObjectPool"
		add_child(session_object_pool)
		session_object_pool.register_scene(SHELL_SCENE, 100, 384)
		combat_system = (
			COMBAT_SYSTEM_SCENE.instantiate()
			as BambooMortarCombatSystem
		)
		combat_system.name = "BambooMortarCombatSystem"
		add_child(combat_system)
		combat_system.setup(self)
		combat_system.set_authoritative_processing_enabled(true)
		# The probe explicitly invokes the production service step so target and
		# explosion wall time can be measured without an automatic second flush.
		combat_system.set_physics_process(false)

	func request_bamboo_mortar_target(
		owner: Node2D,
		minimum_range: float,
		maximum_range: float,
		callback: Callable
	) -> bool:
		return combat_system.request_target(
			owner,
			minimum_range,
			maximum_range,
			callback
		)

	func cancel_bamboo_mortar_target_request(owner: Node) -> void:
		combat_system.cancel_target_request(owner)

	func queue_bamboo_mortar_explosion(
		landing_position: Vector2,
		inner_radius: float,
		outer_radius: float,
		inner_damage: int,
		outer_damage: int,
		damage_source_id: int
	) -> bool:
		return combat_system.queue_explosion(
			landing_position,
			inner_radius,
			outer_radius,
			inner_damage,
			outer_damage,
			damage_source_id
		)

	func query_combat_targets_unordered_into(
		center: Vector2,
		radius: float,
		result: Array[Enemy]
	) -> void:
		query_count += 1
		target_index.query_radius_unordered_into(center, radius, result)

	func get_all_combat_targets() -> Array[Enemy]:
		return target_index.get_all_alive()

	func apply_authoritative_plant_enemy_damage_batch(
		_source_id: int,
		enemy: Enemy,
		damage_amounts: PackedInt64Array,
		hit_counts: PackedInt32Array,
		impact_direction: Vector2,
		damage_type: EnemyConfig.DamageType
	) -> bool:
		batch_call_count += 1
		return enemy.apply_damage_batch(
			damage_amounts,
			hit_counts,
			impact_direction,
			damage_type,
			false
		)

	func queue_bamboo_mortar_visual(
		_plant_net_id: int,
		_action_id: int,
		_stage: int,
		_spawn_position: Vector2,
		_landing_position: Vector2,
		_committed_windup_duration_seconds: float
	) -> void:
		visual_record_count += 1

	func show_damage_number(
		_amount: int,
		_world_position: Vector2,
		_impact_direction: Vector2,
		_damage_type: EnemyConfig.DamageType
	) -> void:
		damage_number_count += 1

	func has_session_object_pool_scene(scene: PackedScene) -> bool:
		return session_object_pool.is_registered(scene)

	func acquire_session_object(
		scene: PackedScene,
		strict: bool = false
	) -> Node:
		return (
			session_object_pool.try_acquire(scene)
			if strict
			else session_object_pool.acquire(scene)
		)


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	runtime = MortarPerformanceRuntime.new()
	runtime.name = "BambooMortar300PerformanceFixture"
	root.add_child(runtime)
	current_scene = runtime
	runtime.install_runtime_systems()
	_spawn_enemies()
	_spawn_mortars()
	_spawn_proxy_mortars()
	var initial_pool_metrics := runtime.session_object_pool.get_metrics(
		SHELL_SCENE.resource_path
	)
	_place_dense_fixture()

	# Setup may briefly schedule normal operational polling. Clear that setup
	# state so every measured request belongs to this probe.
	runtime.combat_system.set_authoritative_processing_enabled(false)
	runtime.combat_system.set_authoritative_processing_enabled(true)
	runtime.combat_system.set_physics_process(false)
	for mortar in mortars:
		_reset_mortar_after_sample(mortar)

	var target_metrics_before := (
		runtime.combat_system.get_metrics_snapshot()
	)
	var target_queries_before := runtime.query_count
	var visual_records_before := runtime.visual_record_count
	var synchronized_target_metrics := (
		_measure_synchronized_target_requests()
	)
	var staggered_target_metrics := _measure_staggered_target_requests()
	var target_metrics_after := (
		runtime.combat_system.get_metrics_snapshot()
	)
	var expected_target_requests := (
		SYNCHRONIZED_TARGET_SAMPLE_COUNT * MORTAR_COUNT
		+ STAGGERED_TARGET_BATCH_COUNT
		* STAGGERED_TARGET_BATCH_SIZE
	)
	_verify_target_contract(
		target_metrics_before,
		target_metrics_after,
		target_queries_before,
		expected_target_requests
	)
	for mortar in mortars:
		_reset_mortar_after_sample(mortar)

	var explosion_metrics_before := (
		runtime.combat_system.get_metrics_snapshot()
	)
	var batch_calls_before := runtime.batch_call_count
	var damage_numbers_before := runtime.damage_number_count
	var warm_sync_metrics := await _run_explosion_cycle(
		0,
		MORTAR_COUNT,
		true
	)
	var warmed_pool_metrics := runtime.session_object_pool.get_metrics(
		SHELL_SCENE.resource_path
	)
	var node_count_after_warmup := _count_subtree_nodes(runtime)

	var synchronized_spawn_samples: Array[float] = []
	var synchronized_submit_samples: Array[float] = []
	var synchronized_flush_samples: Array[float] = []
	var synchronized_impact_total_samples: Array[float] = []
	for sample_index in range(
		SYNCHRONIZED_EXPLOSION_SAMPLE_COUNT
	):
		var synchronized_metrics := await _run_explosion_cycle(
			0,
			MORTAR_COUNT,
			sample_index == 0
		)
		synchronized_spawn_samples.append(
			float(synchronized_metrics.get("spawn_ms", 0.0))
		)
		synchronized_submit_samples.append(
			float(synchronized_metrics.get("submit_ms", 0.0))
		)
		synchronized_flush_samples.append(
			float(synchronized_metrics.get("flush_ms", 0.0))
		)
		synchronized_impact_total_samples.append(
			float(
				synchronized_metrics.get(
					"impact_total_ms",
					0.0
				)
			)
		)

	var staggered_total_samples: Array[float] = []
	var staggered_flush_samples: Array[float] = []
	for batch_index in range(
		STAGGERED_EXPLOSION_BATCH_COUNT
	):
		var staggered_metrics := await _run_explosion_cycle(
			batch_index * STAGGERED_EXPLOSION_BATCH_SIZE,
			STAGGERED_EXPLOSION_BATCH_SIZE,
			batch_index == 0
		)
		staggered_total_samples.append(
			float(staggered_metrics.get("cycle_total_ms", 0.0))
		)
		staggered_flush_samples.append(
			float(staggered_metrics.get("flush_ms", 0.0))
		)

	var explosion_metrics_after := (
		runtime.combat_system.get_metrics_snapshot()
	)
	_verify_explosion_contract(
		explosion_metrics_before,
		explosion_metrics_after,
		batch_calls_before,
		damage_numbers_before
	)

	var damage_calls_before_proxy := runtime.batch_call_count
	var proxy_visual_ms := _measure_proxy_visual_batch()
	var active_proxy_shell_count := _get_active_shells().size()
	var proxy_flight_samples := _measure_proxy_flight_steps()
	await _retire_active_shells()
	var final_pool_metrics := runtime.session_object_pool.get_metrics(
		SHELL_SCENE.resource_path
	)
	var final_node_count := _count_subtree_nodes(runtime)

	var synchronized_target_enqueue := _summarize(
		synchronized_target_metrics.get(
			"enqueue_samples",
			[]
		) as Array[float]
	)
	var synchronized_target_service := _summarize(
		synchronized_target_metrics.get(
			"service_samples",
			[]
		) as Array[float]
	)
	var synchronized_target_cpu_total := _summarize(
		synchronized_target_metrics.get(
			"cpu_total_samples",
			[]
		) as Array[float]
	)
	var staggered_target_total := _summarize(
		staggered_target_metrics.get(
			"total_samples",
			[]
		) as Array[float]
	)
	var synchronized_spawn := _summarize(
		synchronized_spawn_samples
	)
	var synchronized_submit := _summarize(
		synchronized_submit_samples
	)
	var synchronized_flush := _summarize(
		synchronized_flush_samples
	)
	var synchronized_impact_total := _summarize(
		synchronized_impact_total_samples
	)
	var staggered_total := _summarize(staggered_total_samples)
	var staggered_flush := _summarize(staggered_flush_samples)
	var proxy_flight := _summarize(proxy_flight_samples)

	_expect(
		mortars.size() == MORTAR_COUNT
		and proxy_mortars.size() == PROXY_MORTAR_COUNT
		and enemies.size() == ENEMY_COUNT,
		"300座诊断必须完整建立300座权威炮、300座代理炮与300个敌人。"
	)
	_expect(
		int(initial_pool_metrics.get("created", 0)) == 100
		and int(initial_pool_metrics.get("inactive", 0)) == 100
		and int(initial_pool_metrics.get("in_use", -1)) == 0
		and int(initial_pool_metrics.get("pending_release", -1)) == 0
		and int(
			initial_pool_metrics.get(
				"retained_capacity",
				0
			)
		) == 384,
		"300诊断必须从生产一致的100枚完整预热池开始，不能以首次齐射后的扩容结果掩盖预热回归。"
	)
	_expect(
		int(warmed_pool_metrics.get("created", 0))
		== MORTAR_COUNT
		and int(warmed_pool_metrics.get("peak_in_use", 0))
		== MORTAR_COUNT
		and int(warmed_pool_metrics.get("retained_capacity", 0))
		== 384,
		"100预热/384保留池必须真实承载300枚同步炮弹。"
	)
	_expect(
		int(final_pool_metrics.get("created", -1))
		== int(warmed_pool_metrics.get("created", -2))
		and int(final_pool_metrics.get("in_use", -1)) == 0
		and int(final_pool_metrics.get("pending_release", -1)) == 0
		and final_node_count == node_count_after_warmup,
		"热身后同步、错峰和代理炮弹不得继续增长池节点，结束时租约必须归零。"
	)
	_expect(
		active_proxy_shell_count == PROXY_MORTAR_COUNT
		and runtime.batch_call_count == damage_calls_before_proxy,
		"300条代理蓄热/开火记录必须真实生成300枚视觉炮弹，且不能提交权威伤害。"
	)
	var expected_authoritative_shells := (
		(1 + SYNCHRONIZED_EXPLOSION_SAMPLE_COUNT)
		* MORTAR_COUNT
		+ STAGGERED_EXPLOSION_BATCH_COUNT
		* STAGGERED_EXPLOSION_BATCH_SIZE
	)
	_expect(
		runtime.visual_record_count - visual_records_before
		== expected_target_requests + expected_authoritative_shells,
		"异步蓄热与权威开火必须完整写入网络视觉记录，不能绕过真实迫击炮路径。"
	)

	var risk_labels: Array[String] = []
	_append_summary_risk(
		risk_labels,
		"target_sync_service_frame",
		synchronized_target_service
	)
	_append_summary_risk(
		risk_labels,
		"sync_spawn",
		synchronized_spawn
	)
	_append_summary_risk(
		risk_labels,
		"sync_impact_submit",
		synchronized_submit
	)
	_append_summary_risk(
		risk_labels,
		"sync_explosion_flush",
		synchronized_flush
	)
	_append_summary_risk(
		risk_labels,
		"staggered_cycle",
		staggered_total
	)
	_append_summary_risk(
		risk_labels,
		"proxy_flight",
		proxy_flight
	)
	if (
		float(warm_sync_metrics.get("spawn_ms", 0.0))
		>= FRAME_BUDGET_MS
	):
		risk_labels.append("cold_sync_spawn")
	if proxy_visual_ms >= FRAME_BUDGET_MS:
		risk_labels.append("proxy_apply")

	var target_query_delta := (
		runtime.query_count - target_queries_before
	)
	var target_result_cache_hits_delta := int(
		target_metrics_after.get(
			"target_result_cache_hits_total",
			0
		)
	) - int(
		target_metrics_before.get(
			"target_result_cache_hits_total",
			0
		)
	)
	var explosion_logical_hits_delta := int(
		explosion_metrics_after.get(
			"explosion_logical_hits_total",
			0
		)
	) - int(
		explosion_metrics_before.get(
			"explosion_logical_hits_total",
			0
		)
	)
	var explosion_batch_calls_delta := int(
		explosion_metrics_after.get(
			"explosion_enemy_batch_calls_total",
			0
		)
	) - int(
		explosion_metrics_before.get(
			"explosion_enemy_batch_calls_total",
			0
		)
	)
	var explosion_grid_builds_delta := int(
		explosion_metrics_after.get(
			"explosion_enemy_grid_builds_total",
			0
		)
	) - int(
		explosion_metrics_before.get(
			"explosion_enemy_grid_builds_total",
			0
		)
	)
	var risk_text := (
		"none"
		if risk_labels.is_empty()
		else ",".join(risk_labels)
	)
	print(
		(
			"BAMBOO_MORTAR_PERFORMANCE_PROBE mortars=%d proxies=%d enemies=%d "
			+ "target_sync_enqueue_p50/p95/p99/max_ms="
			+ "%.3f/%.3f/%.3f/%.3f "
			+ "target_sync_service_frame_p50/p95/p99/max_ms="
			+ "%.3f/%.3f/%.3f/%.3f "
			+ "target_sync_cpu_total_p50/p95/p99/max_ms="
			+ "%.3f/%.3f/%.3f/%.3f drain_frames_max=%d "
			+ "target_staggered_total_p50/p95/p99/max_ms="
			+ "%.3f/%.3f/%.3f/%.3f drain_frames_max=%d "
			+ "warm_sync_spawn/submit/flush_ms=%.3f/%.3f/%.3f "
			+ "sync_spawn_p50/p95/p99/max_ms="
			+ "%.3f/%.3f/%.3f/%.3f "
			+ "sync_impact_submit_p50/p95/p99/max_ms="
			+ "%.3f/%.3f/%.3f/%.3f "
			+ "sync_explosion_flush_p50/p95/p99/max_ms="
			+ "%.3f/%.3f/%.3f/%.3f "
			+ "sync_impact_total_p50/p95/p99/max_ms="
			+ "%.3f/%.3f/%.3f/%.3f "
			+ "staggered_total_p50/p95/p99/max_ms="
			+ "%.3f/%.3f/%.3f/%.3f "
			+ "staggered_flush_p50/p95/p99/max_ms="
			+ "%.3f/%.3f/%.3f/%.3f "
			+ "proxy_apply_ms=%.3f "
			+ "proxy_flight_p50/p95/p99/max_ms="
			+ "%.3f/%.3f/%.3f/%.3f "
			+ "target_queries=%d target_result_cache_hits=%d "
			+ "explosion_logical_hits=%d explosion_batch_calls=%d "
			+ "explosion_grid_builds=%d damage_mode=enemy_apply_damage_batch "
			+ "pool_created/peak/in_use=%d/%d/%d risks_16_6ms=%s"
		)
		% [
			mortars.size(),
			proxy_mortars.size(),
			enemies.size(),
			_value(synchronized_target_enqueue, "p50_ms"),
			_value(synchronized_target_enqueue, "p95_ms"),
			_value(synchronized_target_enqueue, "p99_ms"),
			_value(synchronized_target_enqueue, "max_ms"),
			_value(synchronized_target_service, "p50_ms"),
			_value(synchronized_target_service, "p95_ms"),
			_value(synchronized_target_service, "p99_ms"),
			_value(synchronized_target_service, "max_ms"),
			_value(synchronized_target_cpu_total, "p50_ms"),
			_value(synchronized_target_cpu_total, "p95_ms"),
			_value(synchronized_target_cpu_total, "p99_ms"),
			_value(synchronized_target_cpu_total, "max_ms"),
			int(
				synchronized_target_metrics.get(
					"maximum_drain_frames",
					0
				)
			),
			_value(staggered_target_total, "p50_ms"),
			_value(staggered_target_total, "p95_ms"),
			_value(staggered_target_total, "p99_ms"),
			_value(staggered_target_total, "max_ms"),
			int(
				staggered_target_metrics.get(
					"maximum_drain_frames",
					0
				)
			),
			float(warm_sync_metrics.get("spawn_ms", 0.0)),
			float(warm_sync_metrics.get("submit_ms", 0.0)),
			float(warm_sync_metrics.get("flush_ms", 0.0)),
			_value(synchronized_spawn, "p50_ms"),
			_value(synchronized_spawn, "p95_ms"),
			_value(synchronized_spawn, "p99_ms"),
			_value(synchronized_spawn, "max_ms"),
			_value(synchronized_submit, "p50_ms"),
			_value(synchronized_submit, "p95_ms"),
			_value(synchronized_submit, "p99_ms"),
			_value(synchronized_submit, "max_ms"),
			_value(synchronized_flush, "p50_ms"),
			_value(synchronized_flush, "p95_ms"),
			_value(synchronized_flush, "p99_ms"),
			_value(synchronized_flush, "max_ms"),
			_value(synchronized_impact_total, "p50_ms"),
			_value(synchronized_impact_total, "p95_ms"),
			_value(synchronized_impact_total, "p99_ms"),
			_value(synchronized_impact_total, "max_ms"),
			_value(staggered_total, "p50_ms"),
			_value(staggered_total, "p95_ms"),
			_value(staggered_total, "p99_ms"),
			_value(staggered_total, "max_ms"),
			_value(staggered_flush, "p50_ms"),
			_value(staggered_flush, "p95_ms"),
			_value(staggered_flush, "p99_ms"),
			_value(staggered_flush, "max_ms"),
			proxy_visual_ms,
			_value(proxy_flight, "p50_ms"),
			_value(proxy_flight, "p95_ms"),
			_value(proxy_flight, "p99_ms"),
			_value(proxy_flight, "max_ms"),
			target_query_delta,
			target_result_cache_hits_delta,
			explosion_logical_hits_delta,
			explosion_batch_calls_delta,
			explosion_grid_builds_delta,
			int(final_pool_metrics.get("created", 0)),
			int(final_pool_metrics.get("peak_in_use", 0)),
			int(final_pool_metrics.get("in_use", 0)),
			risk_text,
		]
	)
	if not risk_labels.is_empty():
		push_warning(
			(
				"300座迫击炮是刻意同步的非阻断最坏情况诊断；"
				+ "以下独立热路径达到或超过16.6ms：%s"
			) % risk_text
		)
	await _finish()


func _spawn_enemies() -> void:
	var stress_config := ENEMY_CONFIG.duplicate(true) as EnemyConfig
	stress_config.max_health = 1000000000
	for enemy_index in range(ENEMY_COUNT):
		var enemy := stress_config.enemy_scene.instantiate() as Enemy
		if enemy == null:
			continue
		runtime.add_child(enemy)
		enemy.setup(stress_config, null, null)
		enemy.collision_layer = 0
		enemy.collision_mask = 0
		enemy.is_dead = false
		enemy.set_process(false)
		enemy.set_physics_process(false)
		if enemy.touch_damage_area != null:
			enemy.touch_damage_area.monitoring = false
			enemy.touch_damage_area.monitorable = false
		var enemy_id := enemy_index + 1
		runtime.target_index.register_enemy(enemy_id, enemy)
		enemy_ids.append(enemy_id)
		enemies.append(enemy)


func _spawn_mortars() -> void:
	for mortar_index in range(MORTAR_COUNT):
		var mortar := MORTAR_SCENE.instantiate() as BambooMortar
		if mortar == null:
			continue
		mortar.set_meta(&"net_id", mortar_index + 1)
		runtime.add_child(mortar)
		mortar.collision_layer = 0
		mortar.setup(MORTAR_CONFIG, null, [], false)
		_reset_mortar_after_sample(mortar)
		mortars.append(mortar)


func _spawn_proxy_mortars() -> void:
	for proxy_index in range(PROXY_MORTAR_COUNT):
		var proxy := MORTAR_SCENE.instantiate() as BambooMortar
		if proxy == null:
			continue
		proxy.set_meta(&"net_id", 1001 + proxy_index)
		runtime.add_child(proxy)
		proxy.collision_layer = 0
		proxy.setup(MORTAR_CONFIG, null, [], true)
		proxy_mortars.append(proxy)


func _place_dense_fixture() -> void:
	for mortar in mortars:
		mortar.global_position = Vector2.ZERO
	for enemy_index in range(enemies.size()):
		var enemy := enemies[enemy_index]
		enemy.global_position = Vector2(
			80.0 + float(enemy_index % 17) * 2.0,
			-24.0 + float((enemy_index / 17) % 7) * 8.0
		)
		runtime.target_index.update_enemy_bucket(
			enemy_ids[enemy_index],
			enemy
		)


func _measure_synchronized_target_requests() -> Dictionary:
	var enqueue_samples: Array[float] = []
	var service_samples: Array[float] = []
	var cpu_total_samples: Array[float] = []
	var maximum_drain_frames := 0
	for _sample_index in range(
		SYNCHRONIZED_TARGET_SAMPLE_COUNT
	):
		for mortar in mortars:
			_reset_mortar_after_sample(mortar)
		var enqueue_started := Time.get_ticks_usec()
		for mortar in mortars:
			mortar.call("_try_begin_windup")
		var enqueue_ms := float(
			Time.get_ticks_usec() - enqueue_started
		) / 1000.0
		enqueue_samples.append(enqueue_ms)
		var service_cpu_ms := 0.0
		var drain_frames := 0
		while (
			_pending_target_request_count() > 0
			and drain_frames < MAX_TARGET_DRAIN_GUARD_FRAMES
		):
			var service_started := Time.get_ticks_usec()
			runtime.combat_system.call(
				"_physics_process",
				1.0 / 60.0
			)
			var service_ms := float(
				Time.get_ticks_usec() - service_started
			) / 1000.0
			service_samples.append(service_ms)
			service_cpu_ms += service_ms
			drain_frames += 1
		cpu_total_samples.append(enqueue_ms + service_cpu_ms)
		maximum_drain_frames = maxi(
			maximum_drain_frames,
			drain_frames
		)
		_expect(
			_pending_target_request_count() == 0
			and _count_windup_mortars(0, MORTAR_COUNT)
			== MORTAR_COUNT,
			"300座同步异步索敌必须全部排空并进入蓄热，不能空跑。"
		)
	return {
		"enqueue_samples": enqueue_samples,
		"service_samples": service_samples,
		"cpu_total_samples": cpu_total_samples,
		"maximum_drain_frames": maximum_drain_frames,
	}


func _measure_staggered_target_requests() -> Dictionary:
	var total_samples: Array[float] = []
	var maximum_drain_frames := 0
	for batch_index in range(STAGGERED_TARGET_BATCH_COUNT):
		var start_index := (
			batch_index * STAGGERED_TARGET_BATCH_SIZE
		)
		for mortar_index in range(
			start_index,
			start_index + STAGGERED_TARGET_BATCH_SIZE
		):
			_reset_mortar_after_sample(mortars[mortar_index])
		var started := Time.get_ticks_usec()
		for mortar_index in range(
			start_index,
			start_index + STAGGERED_TARGET_BATCH_SIZE
		):
			mortars[mortar_index].call("_try_begin_windup")
		var drain_frames := 0
		while (
			_pending_target_request_count() > 0
			and drain_frames < MAX_TARGET_DRAIN_GUARD_FRAMES
		):
			runtime.combat_system.call(
				"_physics_process",
				1.0 / 60.0
			)
			drain_frames += 1
		total_samples.append(
			float(Time.get_ticks_usec() - started) / 1000.0
		)
		maximum_drain_frames = maxi(
			maximum_drain_frames,
			drain_frames
		)
		_expect(
			_pending_target_request_count() == 0
			and _count_windup_mortars(
				start_index,
				STAGGERED_TARGET_BATCH_SIZE
			) == STAGGERED_TARGET_BATCH_SIZE,
			"每组10座错峰异步索敌必须全部排空并进入蓄热。"
		)
	return {
		"total_samples": total_samples,
		"maximum_drain_frames": maximum_drain_frames,
	}


func _verify_target_contract(
	metrics_before: Dictionary,
	metrics_after: Dictionary,
	query_count_before: int,
	expected_request_count: int
) -> void:
	var enqueued_delta := int(
		metrics_after.get("target_requests_enqueued_total", 0)
	) - int(
		metrics_before.get("target_requests_enqueued_total", 0)
	)
	var resolved_delta := int(
		metrics_after.get("target_requests_resolved_total", 0)
	) - int(
		metrics_before.get("target_requests_resolved_total", 0)
	)
	var result_cache_hits_delta := int(
		metrics_after.get("target_result_cache_hits_total", 0)
	) - int(
		metrics_before.get("target_result_cache_hits_total", 0)
	)
	var query_delta := runtime.query_count - query_count_before
	_expect(
		enqueued_delta == expected_request_count
		and resolved_delta == expected_request_count
		and int(metrics_after.get("pending_target_requests", -1))
		== 0,
		"300座探针必须通过生产异步队列完整入队、解析并排空全部索敌请求。"
	)
	_expect(
		query_delta > 0
		and query_delta < expected_request_count
		and result_cache_hits_delta > 0,
		"索敌必须真实查询敌人索引并命中共享结果缓存，不能退化为空测或逐炮查询。"
	)


func _run_explosion_cycle(
	start_mortar_index: int,
	mortar_count: int,
	verify_contract: bool
) -> Dictionary:
	var metrics_before := runtime.combat_system.get_metrics_snapshot()
	var batch_calls_before := runtime.batch_call_count
	var spawn_started := Time.get_ticks_usec()
	for mortar_index in range(
		start_mortar_index,
		start_mortar_index + mortar_count
	):
		_prepare_and_fire(mortars[mortar_index])
	var spawn_ms := float(
		Time.get_ticks_usec() - spawn_started
	) / 1000.0
	var active_shells := _get_active_shells()
	var impact_started := Time.get_ticks_usec()
	for shell in active_shells:
		shell.call("_impact")
	var submit_ms := float(
		Time.get_ticks_usec() - impact_started
	) / 1000.0
	var flush_started := Time.get_ticks_usec()
	runtime.combat_system.call("_physics_process", 1.0 / 60.0)
	var flush_ms := float(
		Time.get_ticks_usec() - flush_started
	) / 1000.0
	var impact_total_ms := float(
		Time.get_ticks_usec() - impact_started
	) / 1000.0
	if verify_contract:
		var metrics_after := (
			runtime.combat_system.get_metrics_snapshot()
		)
		_expect(
			active_shells.size() == mortar_count,
			"爆炸周期必须实际租用并冲击指定数量的真实池化炮弹。"
		)
		_expect(
			int(
				metrics_after.get(
					"explosion_logical_hits_total",
					0
				)
			) - int(
				metrics_before.get(
					"explosion_logical_hits_total",
					0
				)
			) == mortar_count * ENEMY_COUNT,
			"密集爆炸必须跑满炮弹数×300敌人的逻辑命中，不能以空查询获得虚假性能。"
		)
		_expect(
			runtime.batch_call_count - batch_calls_before
			== ENEMY_COUNT
			and int(
				metrics_after.get(
					"explosion_enemy_batch_calls_total",
					0
				)
			) - int(
				metrics_before.get(
					"explosion_enemy_batch_calls_total",
					0
				)
			) == ENEMY_COUNT,
			"同落点逻辑命中必须聚合为300次真实Enemy批伤调用。"
		)
		_expect(
			int(
				metrics_after.get(
					"explosion_enemy_grid_builds_total",
					0
				)
			) - int(
				metrics_before.get(
					"explosion_enemy_grid_builds_total",
					0
				)
			) == 0
			and int(
				metrics_after.get(
					"explosion_index_queries_total",
					0
				)
			) - int(
				metrics_before.get(
					"explosion_index_queries_total",
					0
				)
			) == 1
			and int(metrics_after.get("pending_explosions", -1))
			== 0,
			"同落点爆炸必须复用一次共享战斗索引查询、跳过临时敌人格并由统一flush完整结算。"
		)
	for shell in active_shells:
		shell.call("_on_visual_animation_finished")
	for mortar_index in range(
		start_mortar_index,
		start_mortar_index + mortar_count
	):
		var mortar := mortars[mortar_index]
		mortar.call("_finish_fire_visual")
		# Production immediately defers the next four-second windup. This probe
		# measures one explicitly forced fire cycle at a time, so hold the phase
		# behind the normal re-entry guard until that deferred call has drained.
		mortar.combat_phase = BambooMortar.CombatPhase.WINDUP
		mortar.attack_timer.stop()
	await physics_frame
	await physics_frame
	for mortar_index in range(
		start_mortar_index,
		start_mortar_index + mortar_count
	):
		_reset_mortar_after_sample(mortars[mortar_index])
	return {
		"spawn_ms": spawn_ms,
		"submit_ms": submit_ms,
		"flush_ms": flush_ms,
		"impact_total_ms": impact_total_ms,
		"cycle_total_ms": spawn_ms + impact_total_ms,
	}


func _verify_explosion_contract(
	metrics_before: Dictionary,
	metrics_after: Dictionary,
	batch_calls_before: int,
	damage_numbers_before: int
) -> void:
	var synchronized_cycle_count := (
		1 + SYNCHRONIZED_EXPLOSION_SAMPLE_COUNT
	)
	var total_explosion_request_count := (
		synchronized_cycle_count * MORTAR_COUNT
		+ STAGGERED_EXPLOSION_BATCH_COUNT
		* STAGGERED_EXPLOSION_BATCH_SIZE
	)
	var total_logical_hit_count := (
		synchronized_cycle_count
		* EXPECTED_SYNCHRONIZED_LOGICAL_HITS
		+ STAGGERED_EXPLOSION_BATCH_COUNT
		* STAGGERED_EXPLOSION_BATCH_SIZE
		* ENEMY_COUNT
	)
	var flush_count := (
		synchronized_cycle_count
		+ STAGGERED_EXPLOSION_BATCH_COUNT
	)
	var expected_batch_call_count := flush_count * ENEMY_COUNT
	var request_delta := int(
		metrics_after.get("explosion_requests_total", 0)
	) - int(metrics_before.get("explosion_requests_total", 0))
	var logical_hit_delta := int(
		metrics_after.get("explosion_logical_hits_total", 0)
	) - int(
		metrics_before.get("explosion_logical_hits_total", 0)
	)
	var batch_metric_delta := int(
		metrics_after.get(
			"explosion_enemy_batch_calls_total",
			0
		)
	) - int(
		metrics_before.get(
			"explosion_enemy_batch_calls_total",
			0
		)
	)
	var grid_build_delta := int(
		metrics_after.get(
			"explosion_enemy_grid_builds_total",
			0
		)
	) - int(
		metrics_before.get(
			"explosion_enemy_grid_builds_total",
			0
		)
	)
	var index_query_delta := int(
		metrics_after.get(
			"explosion_index_queries_total",
			0
		)
	) - int(
		metrics_before.get(
			"explosion_index_queries_total",
			0
		)
	)
	_expect(
		request_delta == total_explosion_request_count
		and logical_hit_delta == total_logical_hit_count,
		"同步与错峰爆炸必须完整提交全部请求和逻辑命中，不能空测。"
	)
	_expect(
		batch_metric_delta == expected_batch_call_count
		and runtime.batch_call_count - batch_calls_before
		== expected_batch_call_count
		and runtime.damage_number_count - damage_numbers_before
		== expected_batch_call_count,
		"统一flush必须通过真实Enemy.apply_damage_batch结算，并保留一次聚合伤害反馈。"
	)
	_expect(
		grid_build_delta == 0
		and index_query_delta == flush_count
		and int(metrics_after.get("pending_explosions", -1)) == 0
		and not enemies.is_empty()
		and enemies[0].config != null
		and enemies[0].current_health
		< enemies[0].config.max_health,
		"每次同步/错峰同落点flush必须各复用一次共享索引、跳过临时敌人格并真实扣减敌人生命。"
	)


func _prepare_and_fire(mortar: BambooMortar) -> void:
	mortar.attack_timer.stop()
	mortar.target_track_timer.stop()
	mortar.combat_phase = BambooMortar.CombatPhase.WINDUP
	mortar.next_authoritative_action_id += 1
	mortar.set(
		"_authoritative_fire_action_id",
		mortar.next_authoritative_action_id - 1
	)
	mortar.last_valid_target_position = TARGET_POSITION
	mortar.pending_target = null
	mortar.call("_fire_authoritative_shell")
	mortar.attack_timer.stop()


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
			1.25,
			BambooMortar.WINDUP_DURATION_SECONDS
		)
		proxy.play_multiplayer_action(
			BambooMortar.NETWORK_STAGE_FIRE,
			action_id,
			proxy.muzzle.global_position,
			TARGET_POSITION,
			0.0,
			BambooMortar.WINDUP_DURATION_SECONDS
		)
	return float(Time.get_ticks_usec() - started) / 1000.0


func _measure_proxy_flight_steps() -> Array[float]:
	var samples: Array[float] = []
	for _step in range(PROXY_FLIGHT_STEP_COUNT):
		var started := Time.get_ticks_usec()
		for shell in _get_active_shells():
			if not bool(shell.get("_has_impacted")):
				shell.call("_physics_process", 1.0 / 60.0)
		samples.append(
			float(Time.get_ticks_usec() - started) / 1000.0
		)
	return samples


func _get_active_shells() -> Array[BambooMortarShell]:
	var result: Array[BambooMortarShell] = []
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
		):
			result.append(shell)
	return result


func _retire_active_shells() -> void:
	for shell in _get_active_shells():
		if not bool(shell.get("_has_impacted")):
			shell.call("_impact")
		shell.call("_on_visual_animation_finished")
	await physics_frame
	await physics_frame


func _reset_mortar_after_sample(mortar: BambooMortar) -> void:
	runtime.cancel_bamboo_mortar_target_request(mortar)
	mortar.set("_target_request_pending", false)
	mortar.attack_timer.stop()
	mortar.target_track_timer.stop()
	mortar.pending_target = null
	mortar.combat_phase = BambooMortar.CombatPhase.IDLE
	mortar.main_sprite.position = Vector2.ZERO
	mortar.main_sprite.play(&"idle")
	mortar.call("_set_glow_state", false, 0)


func _pending_target_request_count() -> int:
	return int(
		runtime.combat_system.get_metrics_snapshot().get(
			"pending_target_requests",
			0
		)
	)


func _count_windup_mortars(
	start_index: int,
	count: int
) -> int:
	var result := 0
	for mortar_index in range(start_index, start_index + count):
		if (
			mortars[mortar_index].combat_phase
			== BambooMortar.CombatPhase.WINDUP
		):
			result += 1
	return result


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
	var index := clampi(
		ceili(float(sorted.size()) * ratio) - 1,
		0,
		sorted.size() - 1
	)
	return sorted[index]


func _value(summary: Dictionary, key: String) -> float:
	return float(summary.get(key, 0.0))


func _append_summary_risk(
	risk_labels: Array[String],
	label: String,
	summary: Dictionary
) -> void:
	if (
		_value(summary, "p95_ms") >= FRAME_BUDGET_MS
		or _value(summary, "max_ms") >= FRAME_BUDGET_MS
	):
		risk_labels.append(label)


func _count_subtree_nodes(node: Node) -> int:
	var count := 1
	for child in node.get_children():
		count += _count_subtree_nodes(child)
	return count


func _finish() -> void:
	await _retire_active_shells()
	runtime.combat_system.set_authoritative_processing_enabled(false)
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
