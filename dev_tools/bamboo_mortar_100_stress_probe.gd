extends SceneTree

# Formal 60 FPS gate for the Bamboo Mortar production scheduler. The legacy
# 300-unit probe remains an intentionally impossible, non-blocking diagnostic;
# this probe validates the requested 100-unit synchronized ceiling through the
# real request queue, explosion batcher, Enemy mitigation and shell pool.
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
	"res://scene/game_modes/tower_defense/plant/combat/bamboo_mortar_combat_system.tscn"
)
const ENEMY_CONFIG := preload(
	"res://resources/config/enemies/yuanshi_insect_basic.tres"
)

const MORTAR_COUNT := 100
const PROXY_MORTAR_COUNT := 100
const ENEMY_COUNT := 300
const TARGET_FORMAL_SAMPLE_COUNT := 60
const EXPLOSION_WARMUP_COUNT := 8
const EXPLOSION_FORMAL_SAMPLE_COUNT := 60
const DISTINCT_EXPLOSION_FORMAL_SAMPLE_COUNT := 60
const SPREAD_EXPLOSION_FORMAL_SAMPLE_COUNT := 60
# 0.55 s maximum flight at 60 Hz, plus the terminal impact step.
const PROXY_FLIGHT_STEP_COUNT := 34
const FRAME_BUDGET_MS := 16.6
const FRAME_BUDGET_USEC := 16600
const EXPECTED_TARGET_PROCESSING_BUDGET_USEC := 6000
const TARGET_POSITION := Vector2(96.0, 0.0)
const MAXIMUM_TARGET_DRAIN_FRAMES := 30
const EXPECTED_DENSE_LOGICAL_HITS := MORTAR_COUNT * ENEMY_COUNT
const LANDING_MODE_SHARED := 0
const LANDING_MODE_SUBPIXEL := 1
const LANDING_MODE_SPREAD := 2

var failures: Array[String] = []
var runtime: MortarStressRuntime = null
var mortars: Array[BambooMortar] = []
var proxy_mortars: Array[BambooMortar] = []
var enemies: Array[Enemy] = []
var enemy_ids: PackedInt32Array = PackedInt32Array()


class MortarStressRuntime:
	extends CombatRuntimeBase

	var target_index := CombatTargetIndex.new()
	var session_object_pool: SessionObjectPool = null
	var combat_system: BambooMortarCombatSystem = null
	var gameplay_port: TowerPlantGameplayPort = null
	var query_count := 0
	var visual_record_count := 0
	var batch_call_count := 0
	var damage_number_count := 0

	func _init() -> void:
		_add_required_runtime_child(&"EnemyContainer", Node2D.new())
		_add_required_runtime_child(&"GridPathfinder", Node.new())
		_add_required_runtime_child(&"CapooProjectileMotionSystem", Node.new())
		_add_required_runtime_child(
			&"CombatRobotDroneMotionSystem",
			CombatRobotDroneMotionSystem.new()
		)
		_add_required_runtime_child(&"DayNightController", DayNightController.new())
		_add_required_runtime_child(
			&"MultiplayerGameplayGateway",
			MultiplayerGameplayGateway.new()
		)
		_add_required_runtime_child(&"MultiplayerModeAdapter", MultiplayerModeAdapter.new())

	func _add_required_runtime_child(node_name: StringName, node: Node) -> void:
		node.name = node_name
		add_child(node)

	func install_runtime_systems() -> void:
		session_object_pool = SessionObjectPool.new()
		session_object_pool.name = "SessionObjectPool"
		add_child(session_object_pool)
		session_object_pool.register_scene(SHELL_SCENE, MORTAR_COUNT, 384)
		gameplay_port = MortarStressGameplayPort.new(self)
		add_child(gameplay_port)
		combat_system = (
			COMBAT_SYSTEM_SCENE.instantiate()
			as BambooMortarCombatSystem
		)
		combat_system.name = "BambooMortarCombatSystem"
		add_child(combat_system)
		combat_system.setup(self, gameplay_port)
		combat_system.set_authoritative_processing_enabled(true)
		# The probe calls the production service method explicitly so its wall
		# time is measured without an automatic second service during pool waits.
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
		enemy: Node2D,
		damage_amounts: PackedInt64Array,
		hit_counts: PackedInt32Array,
		impact_direction: Vector2,
		damage_type: int
	) -> bool:
		var target_enemy := enemy as Enemy
		if target_enemy == null:
			return false
		batch_call_count += 1
		return target_enemy.apply_damage_batch(
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
		_impact_direction: Vector2 = Vector2.ZERO,
		_damage_type: EnemyConfig.DamageType = EnemyConfig.DamageType.PHYSICAL,
		_display_priority: DamageNumberPool.DisplayPriority = (
			DamageNumberPool.DisplayPriority.NORMAL
		)
	) -> bool:
		damage_number_count += 1
		return true

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

	func configure_multiplayer(
		_mode: int,
		_local_peer_id: int,
		_player_names: Dictionary,
		_player_character_ids: Dictionary = {}
	) -> void:
		pass

	func get_player_for_peer(_peer_id: int) -> Player:
		return null

	func get_enemy_for_net_id(_net_id: int) -> Enemy:
		return null

	func get_pickup_for_net_id(_net_id: int) -> Pickup:
		return null

	func remove_multiplayer_player(_peer_id: int) -> void:
		pass

	func collect_player_snapshot_states() -> Array[SnapshotManager.PlayerState]:
		return []

	func collect_enemy_snapshot_states() -> Array[SnapshotManager.EnemyState]:
		return []

	func play_remote_enemy_spawn_effect(_spawn_global_position: Vector2) -> void:
		pass


class MortarStressGameplayPort:
	extends TowerPlantGameplayPort

	var runtime: MortarStressRuntime

	func _init(runtime_instance: MortarStressRuntime) -> void:
		runtime = runtime_instance

	func broadcast_plant_projectile_visual(
		_plant_net_id: int,
		_spawn_position: Vector2,
		_direction: Vector2,
		_speed: float,
		_explosion_radius: float,
		_lifetime: float
	) -> bool:
		return true

	func queue_bamboo_mortar_visual(
		_plant_net_id: int,
		_action_id: int,
		_stage: int,
		_spawn_position: Vector2,
		_landing_position: Vector2,
		_committed_windup_duration_seconds: float
	) -> bool:
		runtime.visual_record_count += 1
		return true

	func queue_hydrangea_rain_visual(
		_plant_net_id: int,
		_action_id: int,
		_target_position: Vector2,
		_action_elapsed_seconds: float
	) -> bool:
		return true

	func queue_corn_machine_gun_burst_visual(
		_plant_net_id: int,
		_action_id: int,
		_direction: Vector2,
		_shot_count: int
	) -> bool:
		return true

	func apply_authoritative_plant_enemy_damage(
		_damage_source_id: int,
		_enemy: Node2D,
		_damage: int,
		_impact_direction: Vector2,
		_damage_type: int
	) -> bool:
		return false

	func apply_authoritative_plant_enemy_damage_batch(
		_damage_source_id: int,
		enemy: Node2D,
		damage_amounts: PackedInt64Array,
		hit_counts: PackedInt32Array,
		impact_direction: Vector2,
		damage_type: int
	) -> bool:
		return runtime.apply_authoritative_plant_enemy_damage_batch(
			0,
			enemy,
			damage_amounts,
			hit_counts,
			impact_direction,
			damage_type
		)

	func request_bamboo_mortar_target(
		owner: Node2D,
		minimum_range: float,
		maximum_range: float,
		callback: Callable
	) -> bool:
		return runtime.combat_system.request_target(
			owner,
			minimum_range,
			maximum_range,
			callback
		)

	func cancel_bamboo_mortar_target_request(owner: Node) -> void:
		runtime.combat_system.cancel_target_request(owner)

	func queue_bamboo_mortar_explosion(
		landing_position: Vector2,
		inner_radius: float,
		outer_radius: float,
		inner_damage: int,
		outer_damage: int,
		damage_source_id: int
	) -> bool:
		return runtime.combat_system.queue_explosion(
			landing_position,
			inner_radius,
			outer_radius,
			inner_damage,
			outer_damage,
			damage_source_id
		)

	func query_living_plants_in_radius_into(
		_center: Vector2,
		_radius: float,
		result: Array
	) -> void:
		result.clear()

	func begin_inventory_building_placement(
		_slot_index: int,
		_expected_inventory_revision: int
	) -> bool:
		return false


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	runtime = MortarStressRuntime.new()
	runtime.name = "BambooMortar100StressFixture"
	root.add_child(runtime)
	current_scene = runtime
	runtime.install_runtime_systems()
	_spawn_enemies()
	_spawn_mortars()
	_spawn_proxy_mortars()
	var initial_pool := runtime.session_object_pool.get_metrics(
		SHELL_SCENE.resource_path
	)

	_place_dense_fixture()
	var dense_target_metrics := _measure_target_gate(false)
	_place_grid_fixture()
	var grid_target_metrics := _measure_target_gate(true)
	_place_dense_fixture()

	var cold_cycle: Dictionary = {}
	for warmup_index in range(EXPLOSION_WARMUP_COUNT):
		var warmup_cycle := await _run_explosion_cycle(
			false,
			LANDING_MODE_SHARED
		)
		if warmup_index == 0:
			cold_cycle = warmup_cycle
	var pool_after_warmup := runtime.session_object_pool.get_metrics(
		SHELL_SCENE.resource_path
	)
	var node_count_after_warmup := _count_subtree_nodes(runtime)
	var explosion_spawn_samples: Array[float] = []
	var explosion_submit_samples: Array[float] = []
	var explosion_flush_samples: Array[float] = []
	var explosion_impact_total_samples: Array[float] = []
	for sample_index in range(EXPLOSION_FORMAL_SAMPLE_COUNT):
		var cycle := await _run_explosion_cycle(
			sample_index == 0,
			LANDING_MODE_SHARED
		)
		explosion_spawn_samples.append(
			float(cycle.get("spawn_ms", 0.0))
		)
		explosion_submit_samples.append(
			float(cycle.get("submit_ms", 0.0))
		)
		explosion_flush_samples.append(
			float(cycle.get("flush_ms", 0.0))
		)
		explosion_impact_total_samples.append(
			float(cycle.get("impact_total_ms", 0.0))
		)
	var distinct_explosion_flush_samples: Array[float] = []
	var distinct_explosion_impact_total_samples: Array[float] = []
	for sample_index in range(DISTINCT_EXPLOSION_FORMAL_SAMPLE_COUNT):
		var cycle := await _run_explosion_cycle(
			sample_index == 0,
			LANDING_MODE_SUBPIXEL
		)
		distinct_explosion_flush_samples.append(
			float(cycle.get("flush_ms", 0.0))
		)
		distinct_explosion_impact_total_samples.append(
			float(cycle.get("impact_total_ms", 0.0))
		)
	_place_spread_explosion_fixture()
	var spread_explosion_flush_samples: Array[float] = []
	var spread_explosion_impact_total_samples: Array[float] = []
	for sample_index in range(SPREAD_EXPLOSION_FORMAL_SAMPLE_COUNT):
		var cycle := await _run_explosion_cycle(
			sample_index == 0,
			LANDING_MODE_SPREAD
		)
		spread_explosion_flush_samples.append(
			float(cycle.get("flush_ms", 0.0))
		)
		spread_explosion_impact_total_samples.append(
			float(cycle.get("impact_total_ms", 0.0))
		)

	var proxy_apply_ms := _measure_proxy_visual_batch()
	var proxy_flight_samples := _measure_proxy_flight_steps()
	await _retire_all_shells()
	var final_pool := runtime.session_object_pool.get_metrics(
		SHELL_SCENE.resource_path
	)
	var final_node_count := _count_subtree_nodes(runtime)

	var dense_target_service := _summarize(
		dense_target_metrics.get("service_samples", []) as Array[float]
	)
	var dense_target_enqueue := _summarize(
		dense_target_metrics.get("enqueue_samples", []) as Array[float]
	)
	var grid_target_service := _summarize(
		grid_target_metrics.get("service_samples", []) as Array[float]
	)
	var explosion_spawn := _summarize(explosion_spawn_samples)
	var explosion_submit := _summarize(explosion_submit_samples)
	var explosion_flush := _summarize(explosion_flush_samples)
	var explosion_impact_total := _summarize(
		explosion_impact_total_samples
	)
	var distinct_explosion_flush := _summarize(
		distinct_explosion_flush_samples
	)
	var distinct_explosion_impact_total := _summarize(
		distinct_explosion_impact_total_samples
	)
	var spread_explosion_flush := _summarize(
		spread_explosion_flush_samples
	)
	var spread_explosion_impact_total := _summarize(
		spread_explosion_impact_total_samples
	)
	var proxy_flight := _summarize(proxy_flight_samples)
	var target_metrics_snapshot := (
		runtime.combat_system.get_metrics_snapshot()
	)
	var target_processing_peak_usec := int(
		target_metrics_snapshot.get("target_processing_peak_usec", -1)
	)

	_expect(
		mortars.size() == MORTAR_COUNT
		and proxy_mortars.size() == PROXY_MORTAR_COUNT
		and enemies.size() == ENEMY_COUNT,
		"100座正式门槛必须完整建立100权威炮、100代理炮与300敌人。"
	)
	_expect(
		int(initial_pool.get("created", 0)) == MORTAR_COUNT
		and int(initial_pool.get("inactive", 0)) == MORTAR_COUNT
		and int(initial_pool.get("in_use", -1)) == 0
		and int(initial_pool.get("pending_release", -1)) == 0
		and int(initial_pool.get("retained_capacity", 0)) == 384,
		"生产一致的炮弹池必须在首次齐射前完整预热100枚，并保留384枚弹性上限。"
	)
	_expect_summary_under_budget(
		dense_target_enqueue,
		"100座同步索敌入队"
	)
	_expect_summary_under_budget(
		dense_target_service,
		"100座同点索敌单帧服务"
	)
	_expect_summary_under_budget(
		grid_target_service,
		"100座合法网格索敌单帧服务"
	)
	_expect(
		runtime.combat_system.target_budget_usec
		== EXPECTED_TARGET_PROCESSING_BUDGET_USEC,
		"正式索敌服务必须保持6000微秒生产预算，避免压力门槛与生产配置脱节。"
	)
	_expect(
		target_processing_peak_usec
		< FRAME_BUDGET_USEC,
		"索敌服务以6000微秒为软预算；不可中断的单项查询即使跨过预算，整个服务帧仍必须低于16.6ms。"
	)
	_expect(
		int(dense_target_metrics.get("maximum_drain_frames", 999))
		<= MAXIMUM_TARGET_DRAIN_FRAMES
		and int(grid_target_metrics.get("maximum_drain_frames", 999))
		<= MAXIMUM_TARGET_DRAIN_FRAMES,
		"6000微秒软预算生效时，100个索敌请求仍必须在最多30个物理帧内无饥饿排空。"
	)
	_expect_summary_under_budget(explosion_spawn, "100枚热池炮弹出膛")
	_expect_summary_under_budget(explosion_submit, "100枚同步爆炸提交")
	_expect_summary_under_budget(explosion_flush, "100枚同落点同步爆炸批结算")
	_expect_summary_under_budget(
		explosion_impact_total,
		"100枚同落点热态爆炸提交及批结算同帧总路径"
	)
	_expect_summary_under_budget(
		distinct_explosion_flush,
		"100枚不同落点同步爆炸批结算"
	)
	_expect_summary_under_budget(
		distinct_explosion_impact_total,
		"100枚不同落点热态爆炸提交及批结算同帧总路径"
	)
	_expect_summary_under_budget(
		spread_explosion_flush,
		"100枚分散伤害格同步爆炸批结算"
	)
	_expect_summary_under_budget(
		spread_explosion_impact_total,
		"100枚分散伤害格热态爆炸提交及批结算同帧总路径"
	)
	_expect(
		float(cold_cycle.get("spawn_ms", INF)) < FRAME_BUDGET_MS
		and float(cold_cycle.get("impact_total_ms", INF))
		< FRAME_BUDGET_MS,
		"100枚完整预热池的首轮出膛与爆炸总路径必须低于16.6ms。"
	)
	_expect(
		proxy_apply_ms < FRAME_BUDGET_MS,
		"100条客户端蓄热/出膛视觉应用必须低于16.6ms。"
	)
	_expect_summary_under_budget(proxy_flight, "100枚客户端炮弹逐帧飞行")
	_expect(
		int(pool_after_warmup.get("created", 0)) == MORTAR_COUNT
		and int(pool_after_warmup.get("peak_in_use", 0))
		== MORTAR_COUNT
		and int(final_pool.get("created", -1))
		== int(pool_after_warmup.get("created", -2))
		and int(final_pool.get("in_use", -1)) == 0
		and int(final_pool.get("pending_release", -1)) == 0
		and final_node_count == node_count_after_warmup,
		"100枚完整预热池必须承载同帧齐射，热身后不得继续增长且租约必须归零。"
	)

	print(
		(
			"BAMBOO_MORTAR_100_GATE mortars=%d proxies=%d enemies=%d "
			+ "target_dense_enqueue_p50/p95/p99/max_ms="
			+ "%.3f/%.3f/%.3f/%.3f "
			+ "target_dense_service_p50/p95/p99/max_ms="
			+ "%.3f/%.3f/%.3f/%.3f drain_frames=%d "
			+ "target_grid_service_p50/p95/p99/max_ms="
			+ "%.3f/%.3f/%.3f/%.3f drain_frames=%d "
			+ "target_processing_peak/budget_usec=%d/%d "
			+ "cold_spawn/impact_total_ms=%.3f/%.3f "
			+ "spawn_p50/p95/p99/max_ms=%.3f/%.3f/%.3f/%.3f "
			+ "impact_submit_p50/p95/p99/max_ms=%.3f/%.3f/%.3f/%.3f "
			+ "explosion_flush_p50/p95/p99/max_ms=%.3f/%.3f/%.3f/%.3f "
			+ "impact_total_p50/p95/p99/max_ms=%.3f/%.3f/%.3f/%.3f "
			+ "distinct_explosion_flush_p50/p95/p99/max_ms="
			+ "%.3f/%.3f/%.3f/%.3f "
			+ "distinct_impact_total_p50/p95/p99/max_ms="
			+ "%.3f/%.3f/%.3f/%.3f "
			+ "spread_explosion_flush_p50/p95/p99/max_ms="
			+ "%.3f/%.3f/%.3f/%.3f "
			+ "spread_impact_total_p50/p95/p99/max_ms="
			+ "%.3f/%.3f/%.3f/%.3f "
			+ "proxy_apply_ms=%.3f "
			+ "proxy_flight_p50/p95/p99/max_ms=%.3f/%.3f/%.3f/%.3f "
			+ "queries=%d batches=%d damage_numbers=%d "
			+ "pool_created/peak/in_use=%d/%d/%d"
		)
		% [
			mortars.size(),
			proxy_mortars.size(),
			enemies.size(),
			_value(dense_target_enqueue, "p50_ms"),
			_value(dense_target_enqueue, "p95_ms"),
			_value(dense_target_enqueue, "p99_ms"),
			_value(dense_target_enqueue, "max_ms"),
			_value(dense_target_service, "p50_ms"),
			_value(dense_target_service, "p95_ms"),
			_value(dense_target_service, "p99_ms"),
			_value(dense_target_service, "max_ms"),
			int(dense_target_metrics.get("maximum_drain_frames", 0)),
			_value(grid_target_service, "p50_ms"),
			_value(grid_target_service, "p95_ms"),
			_value(grid_target_service, "p99_ms"),
			_value(grid_target_service, "max_ms"),
			int(grid_target_metrics.get("maximum_drain_frames", 0)),
			target_processing_peak_usec,
			EXPECTED_TARGET_PROCESSING_BUDGET_USEC,
			float(cold_cycle.get("spawn_ms", 0.0)),
			float(cold_cycle.get("impact_total_ms", 0.0)),
			_value(explosion_spawn, "p50_ms"),
			_value(explosion_spawn, "p95_ms"),
			_value(explosion_spawn, "p99_ms"),
			_value(explosion_spawn, "max_ms"),
			_value(explosion_submit, "p50_ms"),
			_value(explosion_submit, "p95_ms"),
			_value(explosion_submit, "p99_ms"),
			_value(explosion_submit, "max_ms"),
			_value(explosion_flush, "p50_ms"),
			_value(explosion_flush, "p95_ms"),
			_value(explosion_flush, "p99_ms"),
			_value(explosion_flush, "max_ms"),
			_value(explosion_impact_total, "p50_ms"),
			_value(explosion_impact_total, "p95_ms"),
			_value(explosion_impact_total, "p99_ms"),
			_value(explosion_impact_total, "max_ms"),
			_value(distinct_explosion_flush, "p50_ms"),
			_value(distinct_explosion_flush, "p95_ms"),
			_value(distinct_explosion_flush, "p99_ms"),
			_value(distinct_explosion_flush, "max_ms"),
			_value(distinct_explosion_impact_total, "p50_ms"),
			_value(distinct_explosion_impact_total, "p95_ms"),
			_value(distinct_explosion_impact_total, "p99_ms"),
			_value(distinct_explosion_impact_total, "max_ms"),
			_value(spread_explosion_flush, "p50_ms"),
			_value(spread_explosion_flush, "p95_ms"),
			_value(spread_explosion_flush, "p99_ms"),
			_value(spread_explosion_flush, "max_ms"),
			_value(spread_explosion_impact_total, "p50_ms"),
			_value(spread_explosion_impact_total, "p95_ms"),
			_value(spread_explosion_impact_total, "p99_ms"),
			_value(spread_explosion_impact_total, "max_ms"),
			proxy_apply_ms,
			_value(proxy_flight, "p50_ms"),
			_value(proxy_flight, "p95_ms"),
			_value(proxy_flight, "p99_ms"),
			_value(proxy_flight, "max_ms"),
			runtime.query_count,
			runtime.batch_call_count,
			runtime.damage_number_count,
			int(final_pool.get("created", 0)),
			int(final_pool.get("peak_in_use", 0)),
			int(final_pool.get("in_use", 0)),
		]
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
		mortar.bind_gameplay_context(runtime, runtime.gameplay_port)
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
		proxy.bind_gameplay_context(runtime, runtime.gameplay_port)
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


func _place_grid_fixture() -> void:
	for mortar_index in range(mortars.size()):
		mortars[mortar_index].global_position = Vector2(
			float(mortar_index % 10) * 32.0,
			float(mortar_index / 10) * 32.0
		)
	for enemy_index in range(enemies.size()):
		var owner_index := enemy_index % MORTAR_COUNT
		var owner_position := mortars[owner_index].global_position
		var radial_offset := Vector2(
			96.0 + float((enemy_index / MORTAR_COUNT) * 8),
			float((enemy_index % 3) - 1) * 8.0
		)
		var enemy := enemies[enemy_index]
		enemy.global_position = owner_position + radial_offset
		runtime.target_index.update_enemy_bucket(
			enemy_ids[enemy_index],
			enemy
		)


func _place_spread_explosion_fixture() -> void:
	for enemy_index in range(enemies.size()):
		var landing_index := enemy_index % MORTAR_COUNT
		var enemy := enemies[enemy_index]
		enemy.global_position = TARGET_POSITION + Vector2(
			(float(landing_index % 10) - 4.5) * 8.0,
			(float(landing_index / 10) - 4.5) * 8.0
		)
		runtime.target_index.update_enemy_bucket(
			enemy_ids[enemy_index],
			enemy
		)


func _measure_target_gate(grid_layout: bool) -> Dictionary:
	var enqueue_samples: Array[float] = []
	var service_samples: Array[float] = []
	var maximum_drain_frames := 0
	for sample_index in range(TARGET_FORMAL_SAMPLE_COUNT):
		for mortar in mortars:
			_reset_mortar_after_sample(mortar)
		var query_count_before := runtime.query_count
		var enqueue_started := Time.get_ticks_usec()
		for mortar in mortars:
			mortar.call("_try_begin_windup")
		enqueue_samples.append(
			float(Time.get_ticks_usec() - enqueue_started) / 1000.0
		)
		var drain_frames := 0
		while (
			int(
				runtime.combat_system.get_metrics_snapshot().get(
					"pending_target_requests",
					0
				)
			) > 0
			and drain_frames < 32
		):
			var service_started := Time.get_ticks_usec()
			runtime.combat_system.call("_physics_process", 1.0 / 60.0)
			service_samples.append(
				float(Time.get_ticks_usec() - service_started) / 1000.0
			)
			drain_frames += 1
		maximum_drain_frames = maxi(maximum_drain_frames, drain_frames)
		_expect(
			drain_frames <= MAXIMUM_TARGET_DRAIN_FRAMES,
			"100个索敌请求不得超过30个预算帧或发生饥饿。"
		)
		_expect(
			runtime.query_count - query_count_before <= drain_frames * 6,
			"索敌查询次数必须受唯一缓存格约束，不能退化为每座炮一次索引查询。"
		)
		var pending_requests := int(
			runtime.combat_system.get_metrics_snapshot().get(
				"pending_target_requests",
				-1
			)
		)
		var resolved_count := 0
		for mortar in mortars:
			if (
				mortar.combat_phase
				== BambooMortar.CombatPhase.WINDUP
				and mortar.pending_target != null
				and is_instance_valid(mortar.pending_target)
			):
				resolved_count += 1
		var fixture_label := (
			"合法网格"
			if grid_layout
			else "密集同点"
		)
		_expect(
			pending_requests == 0,
			"%s夹具第%d轮必须完整排空100个权威索敌请求。"
			% [fixture_label, sample_index + 1]
		)
		_expect(
			resolved_count == MORTAR_COUNT,
			"%s夹具第%d轮的100座权威迫击炮必须全部获得合法目标并进入蓄热，实际%d座。"
			% [fixture_label, sample_index + 1, resolved_count]
		)
	return {
		"enqueue_samples": enqueue_samples,
		"service_samples": service_samples,
		"maximum_drain_frames": maximum_drain_frames,
	}


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


func _run_explosion_cycle(
	verify_contract: bool,
	landing_mode: int
) -> Dictionary:
	var metrics_before := runtime.combat_system.get_metrics_snapshot()
	var batch_calls_before := runtime.batch_call_count
	var spawn_started := Time.get_ticks_usec()
	for mortar_index in range(mortars.size()):
		var mortar := mortars[mortar_index]
		mortar.attack_timer.stop()
		mortar.target_track_timer.stop()
		mortar.combat_phase = BambooMortar.CombatPhase.WINDUP
		mortar.next_authoritative_action_id += 1
		mortar.set(
			"_authoritative_fire_action_id",
			mortar.next_authoritative_action_id - 1
		)
		var landing_position := TARGET_POSITION
		match landing_mode:
			LANDING_MODE_SUBPIXEL:
				landing_position += Vector2(
					(float(mortar_index % 10) - 4.5) * 0.05,
					(float(mortar_index / 10) - 4.5) * 0.05
				)
			LANDING_MODE_SPREAD:
				landing_position += Vector2(
					(float(mortar_index % 10) - 4.5) * 8.0,
					(float(mortar_index / 10) - 4.5) * 8.0
				)
		mortar.last_valid_target_position = landing_position
		mortar.pending_target = null
		mortar.call("_fire_authoritative_shell")
		mortar.attack_timer.stop()
	var spawn_ms := float(
		Time.get_ticks_usec() - spawn_started
	) / 1000.0
	var active_shells := _get_active_shells()
	var impact_started := Time.get_ticks_usec()
	var submit_started := Time.get_ticks_usec()
	for shell in active_shells:
		shell.call("_impact")
	var submit_ms := float(
		Time.get_ticks_usec() - submit_started
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
		var metrics_after := runtime.combat_system.get_metrics_snapshot()
		var unique_visual_landings: Dictionary[Vector2, bool] = {}
		for shell in active_shells:
			unique_visual_landings[shell.landing_position] = true
		_expect(
			active_shells.size() == MORTAR_COUNT,
			"同步爆炸周期必须实际租用并冲击100枚真实池化炮弹。"
		)
		_expect(
			unique_visual_landings.size()
			== (
				1
				if landing_mode == LANDING_MODE_SHARED
				else MORTAR_COUNT
			),
			"100枚炮弹必须保持各自的精确视觉与伤害落点。"
		)
		var logical_hit_delta := (
			int(metrics_after.get("explosion_logical_hits_total", 0))
			- int(metrics_before.get("explosion_logical_hits_total", 0))
		)
		_expect(
			(
				logical_hit_delta == EXPECTED_DENSE_LOGICAL_HITS
				if landing_mode != LANDING_MODE_SPREAD
				else logical_hit_delta >= ENEMY_COUNT
			),
			"同步爆炸必须跑满密集30000命中，或在分散夹具中至少命中全部300名敌人，不能空测。"
		)
		_expect(
			runtime.batch_call_count - batch_calls_before == ENEMY_COUNT
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
			"30000个逻辑命中必须聚合为至多300次真实敌人批结算。"
		)
		_expect(
			int(metrics_after.get("explosion_enemy_grid_builds_total", 0))
			- int(
				metrics_before.get(
					"explosion_enemy_grid_builds_total",
					0
				)
			) == (
				0
				if landing_mode != LANDING_MODE_SPREAD
				else 1
			)
			and int(metrics_after.get("pending_explosions", -1)) == 0,
			"同落点与单精确簇齐射必须复用共享索引查询；分散落点批次必须只构建一次临时敌人格。"
		)
		_expect(
			int(metrics_after.get("explosion_groups_total", 0))
			- int(metrics_before.get("explosion_groups_total", 0))
			== unique_visual_landings.size(),
			"密集批次只能合并完全相同的伤害落点，不能量化或偏移边界。"
		)
	for shell in active_shells:
		shell.call("_on_visual_animation_finished")
	for mortar in mortars:
		mortar.call("_finish_fire_visual")
		mortar.attack_timer.stop()
	await physics_frame
	await physics_frame
	return {
		"spawn_ms": spawn_ms,
		"submit_ms": submit_ms,
		"flush_ms": flush_ms,
		"impact_total_ms": impact_total_ms,
	}


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


func _retire_all_shells() -> void:
	for shell in _get_active_shells():
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
	var index := clampi(
		ceili(float(sorted.size()) * ratio) - 1,
		0,
		sorted.size() - 1
	)
	return sorted[index]


func _value(summary: Dictionary, key: String) -> float:
	return float(summary.get(key, 0.0))


func _expect_summary_under_budget(
	summary: Dictionary,
	label: String
) -> void:
	# A desktop microbenchmark cannot distinguish one OS/editor preemption from
	# work performed by this subsystem. Gate the sustained 60-sample p95; keep
	# p99/max in the report so isolated scheduling spikes remain visible.
	_expect(
		_value(summary, "p95_ms") < FRAME_BUDGET_MS,
		"%s的60轮p95单帧开销必须低于16.6ms；p99/max保留为调度尖峰诊断。" % label
	)


func _count_subtree_nodes(node: Node) -> int:
	var count := 1
	for child in node.get_children():
		count += _count_subtree_nodes(child)
	return count


func _finish() -> void:
	await _retire_all_shells()
	runtime.combat_system.set_authoritative_processing_enabled(false)
	runtime.target_index.clear()
	current_scene = null
	runtime.queue_free()
	for _frame in range(4):
		await process_frame
		await physics_frame
	if failures.is_empty():
		print("BAMBOO_MORTAR_100_STRESS_PROBE_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
