extends SceneTree

const COMBAT_SYSTEM_SCENE := preload(
	"res://scene/game_modes/tower_defense/plant/combat/bamboo_mortar_combat_system.tscn"
)
const ENEMY_SCENE := preload("res://scene/enemy/enemy.tscn")
const ARMORED_ENEMY_CONFIG := preload(
	"res://resources/config/enemies/yuanshi_insect_shell.tres"
)
const MP_GAME_SCRIPT := preload("res://scene/multiplayer/mp_game.gd")
const TOWER_DEFENSE_GAME_SCRIPT := preload(
	"res://scene/game_modes/tower_defense/tower_defense_game.gd"
)

var failures: Array[String] = []
var runtime: CombatRuntimeStub = null
var combat_system: BambooMortarCombatSystem = null
var plant_gameplay_port: CombatSystemPlantPort = null
var next_enemy_id := 1


class TargetRequester:
	extends Node2D

	var resolved_count := 0
	var resolved_target: Enemy = null

	func resolve_target(target: Enemy) -> void:
		resolved_count += 1
		resolved_target = target


class CombatRuntimeStub:
	extends CombatRuntimeTestFixture

	var target_index := CombatTargetIndex.new()
	var enemies: Array[Enemy] = []
	var query_count := 0
	var batch_call_count := 0
	var batch_confirmed_damage := 0

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
		var applied := enemy.apply_damage_batch(
			damage_amounts,
			hit_counts,
			impact_direction,
			damage_type,
			false
		)
		if applied:
			batch_confirmed_damage += enemy.last_damage_taken
		return applied


class CombatSystemPlantPort:
	extends TowerPlantGameplayTestPort

	var fixture_runtime: CombatRuntimeStub = null

	func apply_authoritative_plant_enemy_damage_batch(
		source_id: int,
		enemy_node: Node2D,
		damage_amounts: PackedInt64Array,
		hit_counts: PackedInt32Array,
		impact_direction: Vector2,
		damage_type: int
	) -> bool:
		return (
			fixture_runtime != null
			and fixture_runtime.apply_authoritative_plant_enemy_damage_batch(
				source_id,
				enemy_node as Enemy,
				damage_amounts,
				hit_counts,
				impact_direction,
				damage_type
			)
		)


class HostFlagNetManagerStub:
	extends NetManagerStore

	var host := true

	func is_host() -> bool:
		return host


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	runtime = CombatRuntimeStub.new()
	runtime.name = "BambooMortarCombatSystemSmokeFixture"
	runtime.install_base_runtime_nodes()
	root.add_child(runtime)
	current_scene = runtime
	plant_gameplay_port = CombatSystemPlantPort.new()
	plant_gameplay_port.fixture_runtime = runtime
	plant_gameplay_port.name = "TowerPlantGameplayPort"
	runtime.add_child(plant_gameplay_port)
	combat_system = (
		COMBAT_SYSTEM_SCENE.instantiate()
		as BambooMortarCombatSystem
	)
	_expect(
		combat_system != null,
		"竹筒迫击炮战斗系统场景必须成功实例化。"
	)
	if combat_system != null:
		runtime.add_child(combat_system)
		combat_system.setup(runtime, plant_gameplay_port)
		combat_system.set_authoritative_processing_enabled(true)
		if OS.get_cmdline_user_args().has("--concussion-only"):
			await _test_research_concussion_semantics()
		else:
			_test_budgeted_cached_targeting()
			await _test_dense_explosion_batch()
			await _test_sparse_explosion_boundaries()
			await _test_dense_explosion_boundaries()
			await _test_shared_enemy_position_geometry()
			await _test_batch_damage_semantics()
			await _test_research_concussion_semantics()
			await _test_multiplayer_batch_bridge()

	await _cleanup()
	if failures.is_empty():
		print("BAMBOO_MORTAR_COMBAT_SYSTEM_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_budgeted_cached_targeting() -> void:
	_clear_enemies_immediate()
	var too_close := _spawn_enemy(Vector2(64.0, 0.0))
	var nearest_valid := _spawn_enemy(Vector2(64.25, 0.0))
	var outer_edge := _spawn_enemy(Vector2(160.0, 0.0))
	var outside := _spawn_enemy(Vector2(160.25, 0.0))
	var first := TargetRequester.new()
	var second := TargetRequester.new()
	var cancelled := TargetRequester.new()
	runtime.add_child(first)
	runtime.add_child(second)
	runtime.add_child(cancelled)
	var callback := Callable(first, "resolve_target")
	_expect(
		combat_system.request_target(first, 64.0, 160.0, callback),
		"权威战斗系统必须接受索敌请求。"
	)
	_expect(
		combat_system.request_target(first, 64.0, 160.0, callback),
		"同一迫击炮的待处理索敌请求必须可去重更新。"
	)
	_expect(
		combat_system.request_target(
			second,
			64.0,
			160.0,
			Callable(second, "resolve_target")
		),
		"同格第二座迫击炮必须成功入队。"
	)
	_expect(
		combat_system.request_target(
			cancelled,
			64.0,
			160.0,
			Callable(cancelled, "resolve_target")
		),
		"待移除迫击炮的索敌请求必须先成功入队。"
	)
	combat_system.cancel_target_request(cancelled)
	var queries_before := runtime.query_count
	combat_system.call("_physics_process", 1.0 / 60.0)
	var metrics := combat_system.get_metrics_snapshot()
	_expect(
		first.resolved_count == 1
		and second.resolved_count == 1
		and cancelled.resolved_count == 0
		and first.resolved_target == nearest_valid
		and second.resolved_target == nearest_valid,
		"同格请求必须复用候选超集、精确排除64边界并选择最近合法目标，取消请求不得回调。"
	)
	_expect(
		runtime.query_count == queries_before + 1
		and (
			int(metrics.get("target_candidate_cache_hits_total", 0))
			+ int(metrics.get("target_result_cache_hits_total", 0))
		) >= 1
		and int(metrics.get("target_requests_deduplicated_total", 0)) >= 1
		and int(metrics.get("pending_target_requests", -1)) == 0,
		"同一64像素缓存格的索敌必须只查一次共享索引，并完整排空去重队列。"
	)
	_expect(
		too_close != null and outer_edge != null and outside != null,
		"索敌边界夹具必须完整建立。"
	)
	var tombstone_owner := TargetRequester.new()
	var live_owner := TargetRequester.new()
	var disabled_owner := TargetRequester.new()
	runtime.add_child(tombstone_owner)
	runtime.add_child(live_owner)
	runtime.add_child(disabled_owner)
	combat_system.target_requests_per_physics_frame = 1
	for _index in range(32):
		combat_system.request_target(
			tombstone_owner,
			64.0,
			160.0,
			Callable(tombstone_owner, "resolve_target")
		)
		combat_system.cancel_target_request(tombstone_owner)
	combat_system.request_target(
		live_owner,
		64.0,
		160.0,
		Callable(live_owner, "resolve_target")
	)
	combat_system.call("_physics_process", 1.0 / 60.0)
	_expect(
		tombstone_owner.resolved_count == 0
		and live_owner.resolved_count == 1
		and live_owner.resolved_target == nearest_valid,
		"已取消请求的队列墓碑不得占用每帧有效索敌名额。"
	)
	combat_system.request_target(
		disabled_owner,
		64.0,
		160.0,
		Callable(disabled_owner, "resolve_target")
	)
	combat_system.set_authoritative_processing_enabled(false)
	_expect(
		disabled_owner.resolved_count == 1
		and disabled_owner.resolved_target == null
		and int(
			combat_system.get_metrics_snapshot().get(
				"pending_target_requests",
				-1
			)
		) == 0,
		"运行中关闭权威系统必须以空目标回调待处理请求，不能让迫击炮永久停在请求中。"
	)
	combat_system.set_authoritative_processing_enabled(true)
	combat_system.target_requests_per_physics_frame = 12
	first.queue_free()
	second.queue_free()
	cancelled.queue_free()
	tombstone_owner.queue_free()
	live_owner.queue_free()
	disabled_owner.queue_free()


func _test_dense_explosion_batch() -> void:
	await _clear_enemies()
	var armored_config := ARMORED_ENEMY_CONFIG.duplicate(true) as EnemyConfig
	armored_config.max_health = 100000
	armored_config.physical_defense = 3
	var armored := _spawn_configured_enemy(Vector2.ZERO, armored_config)
	if armored == null:
		return
	var health_before := armored.current_health
	var batch_calls_before := runtime.batch_call_count
	var metrics_before := combat_system.get_metrics_snapshot()
	for _index in range(100):
		_expect(
			combat_system.queue_explosion(
				Vector2.ZERO,
				16.0,
				32.0,
				100,
				50,
				9001
			),
			"100座同步爆炸必须全部进入批处理队列。"
		)
	combat_system.call("_physics_process", 1.0 / 60.0)
	var metrics_after := combat_system.get_metrics_snapshot()
	_expect(
		health_before - armored.current_health == 9700
		and armored.last_damage_taken == 9700,
		"100次中心100物理伤害命中3物防目标时必须逐击减防并总计9700，不能只减一次防御。"
	)
	_expect(
		runtime.batch_call_count == batch_calls_before + 1
		and int(metrics_after.get("explosion_logical_hits_total", 0))
		- int(metrics_before.get("explosion_logical_hits_total", 0))
		== 100
		and int(metrics_after.get("explosion_enemy_batch_calls_total", 0))
		- int(
			metrics_before.get(
				"explosion_enemy_batch_calls_total",
				0
			)
		)
		== 1
		and int(metrics_after.get("pending_explosions", -1)) == 0,
		"同落点100次逻辑命中必须聚合为单个敌人批伤调用，并完整清空爆炸队列。"
	)


func _test_sparse_explosion_boundaries() -> void:
	await _clear_enemies()
	var test_config := ARMORED_ENEMY_CONFIG.duplicate(true) as EnemyConfig
	test_config.max_health = 10000
	test_config.physical_defense = 0
	var landing_position := Vector2(3.25, 5.5)
	var inner_edge := _spawn_configured_enemy(
		landing_position + Vector2(16.0, 0.0),
		test_config
	)
	var outer_start := _spawn_configured_enemy(
		landing_position + Vector2(16.25, 0.0),
		test_config
	)
	var outer_edge := _spawn_configured_enemy(
		landing_position + Vector2(32.0, 0.0),
		test_config
	)
	var outside := _spawn_configured_enemy(
		landing_position + Vector2(32.25, 0.0),
		test_config
	)
	if (
		inner_edge == null
		or outer_start == null
		or outer_edge == null
		or outside == null
	):
		return
	var initial_health := test_config.max_health
	var queries_before := runtime.query_count
	var grid_builds_before := int(
		combat_system.get_metrics_snapshot().get(
			"explosion_enemy_grid_builds_total",
			0
		)
	)
	combat_system.queue_explosion(
		landing_position,
		16.0,
		32.0,
		100,
		50,
		9100
	)
	combat_system.call("_physics_process", 1.0 / 60.0)
	_expect(
		inner_edge.current_health == initial_health - 100
		and outer_start.current_health == initial_health - 50
		and outer_edge.current_health == initial_health - 50
		and outside.current_health == initial_health,
		"稀疏且非网格对齐的爆炸必须保持[0,16]为100、(16,32]为50、32外为0的精确边界。"
	)
	_expect(
		runtime.query_count == queries_before + 1
		and int(
			combat_system.get_metrics_snapshot().get(
				"explosion_enemy_grid_builds_total",
				0
			)
		) == grid_builds_before,
		"单发爆炸必须沿用一次局部共享索引查询，不得为稀疏攻击重建全敌人格。"
	)


func _test_dense_explosion_boundaries() -> void:
	await _clear_enemies()
	var test_config := ARMORED_ENEMY_CONFIG.duplicate(true) as EnemyConfig
	test_config.max_health = 10000
	test_config.physical_defense = 0
	var landing_position := Vector2(0.99, 0.0)
	var inner_edge := _spawn_configured_enemy(
		landing_position + Vector2(16.0, 0.0),
		test_config
	)
	var outer_edge := _spawn_configured_enemy(
		landing_position + Vector2(32.0, 0.0),
		test_config
	)
	if inner_edge == null or outer_edge == null:
		return
	for _index in range(4):
		_expect(
			combat_system.queue_explosion(
				landing_position,
				16.0,
				32.0,
				100,
				50,
				9200
			),
			"密集边界夹具的4发爆炸必须全部入队。"
		)
	combat_system.call("_physics_process", 1.0 / 60.0)
	_expect(
		inner_edge.current_health == test_config.max_health - 400
		and outer_edge.current_health == test_config.max_health - 200,
		"爆炸边界不得随同帧炮弹数量变化：密集批次仍须保持[0,16]为100、(16,32]为50。"
	)

	await _clear_enemies()
	var clustered_inner_boundary := _spawn_configured_enemy(
		Vector2(16.5, 0.2),
		test_config
	)
	var clustered_outer_boundary := _spawn_configured_enemy(
		Vector2(32.5, 0.2),
		test_config
	)
	if clustered_inner_boundary == null or clustered_outer_boundary == null:
		return
	var clustered_landings: Array[Vector2] = [
		Vector2(0.2, 0.2),
		Vector2(0.4, 0.2),
		Vector2(0.6, 0.2),
		Vector2(0.8, 0.2),
	]
	for exact_landing in clustered_landings:
		combat_system.queue_explosion(
			exact_landing,
			16.0,
			32.0,
			100,
			50,
			9201
		)
	combat_system.call("_physics_process", 1.0 / 60.0)
	_expect(
		clustered_inner_boundary.current_health
		== test_config.max_health - 300
		and clustered_outer_boundary.current_health
		== test_config.max_health - 100,
		"同一粗候选格内的不同落点只能共享包络；16/32边界必须按4个原始中心逐发精确结算。"
	)


func _test_shared_enemy_position_geometry() -> void:
	await _clear_enemies()
	var defenses := PackedInt32Array([0, 25, 10, 40])
	var enemy_positions := PackedVector2Array([
		Vector2.ZERO,
		Vector2.ZERO,
		Vector2(56.0, 56.0),
		Vector2(56.0, 56.0),
	])
	var shared_position_enemies: Array[Enemy] = []
	for enemy_index in range(enemy_positions.size()):
		var test_config := (
			ARMORED_ENEMY_CONFIG.duplicate(true) as EnemyConfig
		)
		test_config.max_health = 1000000
		test_config.physical_defense = defenses[enemy_index]
		var enemy := _spawn_configured_enemy(
			enemy_positions[enemy_index],
			test_config
		)
		if enemy != null:
			shared_position_enemies.append(enemy)
	if shared_position_enemies.size() != enemy_positions.size():
		return

	var exact_landings := PackedVector2Array()
	for row in range(8):
		for column in range(8):
			var landing := Vector2(
				float(column) * 8.0,
				float(row) * 8.0
			)
			exact_landings.append(landing)
			combat_system.queue_explosion(
				landing,
				16.0,
				32.0,
				100,
				50,
				9250
			)
	var expected_damages := PackedInt32Array()
	var expected_logical_hits := 0
	expected_damages.resize(shared_position_enemies.size())
	for enemy_index in range(shared_position_enemies.size()):
		var defense := defenses[enemy_index]
		for landing in exact_landings:
			var distance_squared := (
				enemy_positions[enemy_index]
				.distance_squared_to(landing)
			)
			if distance_squared <= 16.0 * 16.0:
				expected_damages[enemy_index] += maxi(
					100 - defense,
					1
				)
				expected_logical_hits += 1
			elif distance_squared <= 32.0 * 32.0:
				expected_damages[enemy_index] += maxi(
					50 - defense,
					1
				)
				expected_logical_hits += 1
	var batch_calls_before := runtime.batch_call_count
	var metrics_before := combat_system.get_metrics_snapshot()
	combat_system.call("_physics_process", 1.0 / 60.0)
	var all_damage_correct := true
	for enemy_index in range(shared_position_enemies.size()):
		var enemy := shared_position_enemies[enemy_index]
		if (
			1000000 - enemy.current_health
			!= expected_damages[enemy_index]
		):
			all_damage_correct = false
			break
	var metrics_after := combat_system.get_metrics_snapshot()
	_expect(
		all_damage_correct
		and runtime.batch_call_count - batch_calls_before
		== shared_position_enemies.size()
		and int(
			metrics_after.get(
				"explosion_logical_hits_total",
				0
			)
		) - int(
			metrics_before.get(
				"explosion_logical_hits_total",
				0
			)
		) == expected_logical_hits,
		"同坐标敌人只能共享精确几何；不同物防与生命必须逐个批伤，并保留逐敌逻辑命中计数。"
	)


func _test_batch_damage_semantics() -> void:
	await _clear_enemies()
	var test_config := ARMORED_ENEMY_CONFIG.duplicate(true) as EnemyConfig
	test_config.max_health = 100000
	test_config.physical_defense = 75
	var sequential := _spawn_configured_enemy(Vector2.ZERO, test_config)
	var batched := _spawn_configured_enemy(Vector2(40.0, 0.0), test_config)
	if sequential == null or batched == null:
		return
	sequential.add_damage_taken_multiplier_modifier(7001, 1.25)
	batched.add_damage_taken_multiplier_modifier(7001, 1.25)
	var sequential_health_before := sequential.current_health
	for _index in range(3):
		sequential.apply_damage(
			100,
			Vector2.UP,
			EnemyConfig.DamageType.PHYSICAL,
			false
		)
	for _index in range(2):
		sequential.apply_damage(
			50,
			Vector2.UP,
			EnemyConfig.DamageType.PHYSICAL,
			false
		)
	var expected_damage := sequential_health_before - sequential.current_health
	var accepted := batched.apply_damage_batch(
		PackedInt64Array([100, 50]),
		PackedInt32Array([3, 2]),
		Vector2.UP,
		EnemyConfig.DamageType.PHYSICAL,
		false
	)
	_expect(
		accepted
		and batched.current_health == sequential.current_health
		and batched.last_damage_taken == expected_damage,
		"批伤入口必须与逐发物防、每击最低1点及受伤倍率取整语义完全一致。"
	)
	var lethal_config := test_config.duplicate(true) as EnemyConfig
	lethal_config.max_health = 25
	lethal_config.physical_defense = 0
	var sequential_lethal := _spawn_configured_enemy(
		Vector2(80.0, 0.0),
		lethal_config
	)
	var batched_lethal := _spawn_configured_enemy(
		Vector2(120.0, 0.0),
		lethal_config
	)
	if sequential_lethal == null or batched_lethal == null:
		return
	for _index in range(3):
		sequential_lethal.apply_damage(
			20,
			Vector2.UP,
			EnemyConfig.DamageType.PHYSICAL,
			false
		)
	batched_lethal.apply_damage_batch(
		PackedInt64Array([20]),
		PackedInt32Array([3]),
		Vector2.UP,
		EnemyConfig.DamageType.PHYSICAL,
		false
	)
	_expect(
		sequential_lethal.is_dead
		and batched_lethal.is_dead
		and batched_lethal.current_health == 0
		and batched_lethal.last_damage_taken == lethal_config.max_health,
		"批伤致死必须停止后续攻击，并将聚合伤害钳制到剩余生命，不能产生顺序相关的过量伤害。"
	)
	var order_a := _spawn_configured_enemy(
		Vector2(160.0, 0.0),
		lethal_config
	)
	var order_b := _spawn_configured_enemy(
		Vector2(200.0, 0.0),
		lethal_config
	)
	if order_a == null or order_b == null:
		return
	order_a.current_health = 25
	order_b.current_health = 25
	order_a.apply_damage_batch(
		PackedInt64Array([20, 50]),
		PackedInt32Array([1, 1]),
		Vector2.UP,
		EnemyConfig.DamageType.PHYSICAL,
		false
	)
	order_b.apply_damage_batch(
		PackedInt64Array([50, 20]),
		PackedInt32Array([1, 1]),
		Vector2.UP,
		EnemyConfig.DamageType.PHYSICAL,
		false
	)
	_expect(
		order_a.current_health == 0
		and order_b.current_health == 0
		and order_a.last_damage_taken == 25
		and order_b.last_damage_taken == 25,
		"混合伤害档位无论聚合顺序如何，都必须只确认目标剩余的25点生命伤害。"
	)


func _test_research_concussion_semantics() -> void:
	await _clear_enemies()
	var durable_config := ARMORED_ENEMY_CONFIG.duplicate(true) as EnemyConfig
	durable_config.max_health = 1000
	durable_config.physical_defense = 0
	var durable := _spawn_configured_enemy(Vector2.ZERO, durable_config)
	if durable == null:
		return
	combat_system.set_research_concussion_effect(0.75, 3.0)
	var accepted := bool(combat_system.call(
		"_apply_enemy_damage_batch",
		durable,
		PackedInt64Array([20]),
		PackedInt32Array([1]),
		Vector2.UP
	))
	_expect(
		accepted
		and durable.current_health == 980
		and durable.has_collectible_status(&"bamboo_mortar_concussion")
		and is_equal_approx(
			durable.get_effective_move_speed_multiplier(),
			0.75
		),
		"震爆科研必须在迫击炮批伤成功且目标存活后施加25%减速。"
	)
	var first_deadline_clock := durable.collectible_status_clock
	durable.call(
		"_advance_collectible_status_effects_to",
		first_deadline_clock + 2.0
	)
	durable.apply_bamboo_mortar_concussion(3.0, 0.75)
	var refreshed_clock := durable.collectible_status_clock
	durable.call(
		"_advance_collectible_status_effects_to",
		refreshed_clock + 2.9
	)
	_expect(
		durable.has_collectible_status(&"bamboo_mortar_concussion")
		and is_equal_approx(
			durable.get_effective_move_speed_multiplier(),
			0.75
		),
		"同一震爆科研来源重复命中必须刷新3秒期限，不能重复叠乘减速。"
	)
	durable.call(
		"_advance_collectible_status_effects_to",
		refreshed_clock + 3.1
	)
	_expect(
		not durable.has_collectible_status(&"bamboo_mortar_concussion")
		and is_equal_approx(
			durable.get_effective_move_speed_multiplier(),
			1.0
		),
		"震爆减速必须在刷新后的3秒期限结束时恢复。"
	)

	var lethal_config := durable_config.duplicate(true) as EnemyConfig
	lethal_config.max_health = 1
	var lethal := _spawn_configured_enemy(Vector2(40.0, 0.0), lethal_config)
	if lethal != null:
		var lethal_accepted := bool(combat_system.call(
			"_apply_enemy_damage_batch",
			lethal,
			PackedInt64Array([20]),
			PackedInt32Array([1]),
			Vector2.UP
		))
		_expect(
			lethal_accepted
			and lethal.is_dead
			and not lethal.has_collectible_status(
				&"bamboo_mortar_concussion"
			),
			"致死迫击炮批伤不得给已死亡目标残留震爆减速状态。"
		)
	combat_system.set_research_concussion_effect(1.0, 0.0)


func _test_multiplayer_batch_bridge() -> void:
	await _clear_enemies()
	var test_config := ARMORED_ENEMY_CONFIG.duplicate(true) as EnemyConfig
	test_config.max_health = 1000
	test_config.physical_defense = 3
	var enemy := _spawn_configured_enemy(Vector2.ZERO, test_config)
	if enemy == null:
		return
	var bridge_game := TOWER_DEFENSE_GAME_SCRIPT.new()
	var plant_runtime := TowerDefensePlantRuntimeCoordinator.new()
	plant_runtime.name = "PlantRuntimeCoordinator"
	bridge_game.add_child(plant_runtime)
	bridge_game.plant_runtime_coordinator = plant_runtime
	plant_runtime.setup(bridge_game.runtime_mode, null, null, null, null)
	var mp_game := MP_GAME_SCRIPT.new()
	var net_manager_stub := HostFlagNetManagerStub.new()
	var tower_mode_adapter := TowerDefenseMultiplayerModeAdapter.new()
	var session_coordinator := MpSessionCoordinator.new()
	var transactions_coordinator := MpTransactionsCoordinator.new()
	var enemy_coordinator := MpEnemyCoordinator.new()
	var tower_economy_coordinator := MpTowerEconomyCoordinator.new()
	var tower_world_coordinator := MpTowerWorldCoordinator.new()
	mp_game.set("net_manager", net_manager_stub)
	mp_game.game = bridge_game
	mp_game.tower_mode_adapter = tower_mode_adapter
	mp_game.tower_world_coordinator = tower_world_coordinator
	tower_world_coordinator.bind_session(
		mp_game,
		session_coordinator,
		bridge_game,
		tower_mode_adapter,
		net_manager_stub,
		transactions_coordinator,
		enemy_coordinator,
		tower_economy_coordinator
	)
	var enemy_net_id := 808
	bridge_game.register_network_enemy(enemy_net_id, enemy)
	var health_before := enemy.current_health
	var accepted := mp_game.apply_authoritative_plant_enemy_damage_batch(
		77,
		enemy,
		PackedInt64Array([100]),
		PackedInt32Array([2]),
		Vector2.RIGHT,
		EnemyConfig.DamageType.PHYSICAL
	)
	_expect(
		accepted
		and enemy.current_health == health_before - 194
		and enemy.last_damage_taken == 194,
		"MpGame Host批伤桥必须先按实例映射net-id，再以每击物防结算两次97点伤害。"
	)
	var client_health_before := enemy.current_health
	net_manager_stub.host = false
	_expect(
		not mp_game.apply_authoritative_plant_enemy_damage_batch(
			77,
			enemy,
			PackedInt64Array([100]),
			PackedInt32Array([1]),
			Vector2.RIGHT,
			EnemyConfig.DamageType.PHYSICAL
		)
		and enemy.current_health == client_health_before,
		"MpGame Client视角必须拒绝权威植物批伤，不能修改敌人生命。"
	)
	bridge_game.runtime_mode = CombatRuntimeBase.RuntimeMode.CLIENT_VIEW
	plant_runtime.set_runtime_mode(bridge_game.runtime_mode)
	_expect(
		not plant_runtime.apply_authoritative_enemy_damage_batch(
			77,
			enemy,
			PackedInt64Array([100]),
			PackedInt32Array([1]),
			Vector2.RIGHT,
			EnemyConfig.DamageType.PHYSICAL
		)
		and enemy.current_health == client_health_before,
		"PlantRuntime Client运行时必须在底层拒绝植物批伤。"
	)
	bridge_game.runtime_mode = CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY
	net_manager_stub.host = true
	bridge_game.clear_network_enemy_registry()
	_expect(
		not mp_game.apply_authoritative_plant_enemy_damage_batch(
			77,
			enemy,
			PackedInt64Array([100]),
			PackedInt32Array([1]),
			Vector2.RIGHT,
			EnemyConfig.DamageType.PHYSICAL
		),
		"MpGame Host找不到敌人net-id映射时必须拒绝批伤，不能生成无主反馈。"
	)
	tower_world_coordinator.unbind_session(mp_game)
	mp_game.free()
	bridge_game.free()
	tower_world_coordinator.free()
	tower_economy_coordinator.free()
	enemy_coordinator.free()
	transactions_coordinator.free()
	session_coordinator.free()
	tower_mode_adapter.free()
	net_manager_stub.free()


func _spawn_enemy(position: Vector2) -> Enemy:
	var enemy := ENEMY_SCENE.instantiate() as Enemy
	_expect(enemy != null, "索敌夹具必须成功实例化敌人。")
	if enemy == null:
		return null
	runtime.add_child(enemy)
	_prepare_enemy(enemy, position)
	_register_enemy(enemy)
	return enemy


func _spawn_configured_enemy(
	position: Vector2,
	config: EnemyConfig
) -> Enemy:
	var enemy := config.enemy_scene.instantiate() as Enemy
	_expect(enemy != null, "批伤夹具必须成功实例化配置敌人。")
	if enemy == null:
		return null
	runtime.add_child(enemy)
	enemy.global_position = position
	enemy.setup(config, null, null, runtime)
	_prepare_enemy(enemy, position)
	_register_enemy(enemy)
	return enemy


func _prepare_enemy(enemy: Enemy, position: Vector2) -> void:
	enemy.global_position = position
	enemy.collision_layer = 0
	enemy.collision_mask = 0
	enemy.set_process(false)
	enemy.set_physics_process(false)
	if enemy.touch_damage_area != null:
		enemy.touch_damage_area.set_deferred("monitoring", false)
		enemy.touch_damage_area.set_deferred("monitorable", false)


func _register_enemy(enemy: Enemy) -> void:
	var enemy_id := next_enemy_id
	next_enemy_id += 1
	runtime.enemies.append(enemy)
	runtime.target_index.register_enemy(enemy_id, enemy)


func _clear_enemies_immediate() -> void:
	runtime.target_index.clear()
	for enemy in runtime.enemies:
		if enemy != null and is_instance_valid(enemy):
			enemy.free()
	runtime.enemies.clear()


func _clear_enemies() -> void:
	runtime.target_index.clear()
	for enemy in runtime.enemies:
		if enemy != null and is_instance_valid(enemy):
			enemy.queue_free()
	runtime.enemies.clear()
	await process_frame


func _cleanup() -> void:
	if runtime != null:
		await _clear_enemies()
		combat_system.set_authoritative_processing_enabled(false)
		current_scene = null
		runtime.queue_free()
	for _frame in range(4):
		await process_frame
		await physics_frame


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
