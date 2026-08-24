extends SceneTree

const RUNTIME_SCENE := preload(
	"res://dev_tools/fixtures/enemy_gameplay_gateway_test_runtime.tscn"
)
const BASIC_CONFIG := preload(
	"res://resources/config/enemies/yuanshi_insect_basic.tres"
)
const DESCRIPTOR := preload(
	"res://scene/combat/targeting/combat_target_descriptor.gd"
)

const FIXED_SEED := 20_260_824
const FACTION_SIZE := 150
const TOTAL_ENEMY_COUNT := FACTION_SIZE * 2
const ALLIED_NET_ID_BASE := 10_001
const HOSTILE_NET_ID_BASE := 20_001
const STRESS_MINIMUM_AUTHORITATIVE_TICKS := 100_000
const STRESS_MAXIMUM_PHYSICS_FRAMES := 600
const FACTION_CHANGE_FRAME := 60
const TARGET_DEATH_FRAME := 120
const PROBE_HEALTH := 1_000_000
const DIRECT_CERTIFICATE_FRAME_LIMIT := 10_000
const NORMAL_PAIR_SEPARATION := 80.0
const NORMAL_PAIR_COLUMN_SPACING := 256.0
const NORMAL_PAIR_ROW_SPACING := 64.0
const NORMAL_PAIR_COLUMNS := 15
const SOFT_PASS_FIRST_PAIR_INDEX := 4
const SOFT_PASS_SECOND_PAIR_INDEX := 5

var failures: Array[String] = []
var allied_enemies: Array[YuanshiInsect] = []
var hostile_enemies: Array[YuanshiInsect] = []
var initial_bucket_by_net_id: Dictionary[int, Vector2i] = {}
var death_target_scheduled_steps := 0
var faction_change_immediate_diagnostics := {}


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	var runtime := RUNTIME_SCENE.instantiate() as EnemyGameplayGatewayTestRuntime
	_expect(runtime != null, "动态阵营压力门禁必须实例化 authored combat runtime。")
	if runtime == null:
		_finish({})
		return
	runtime.runtime_mode = CombatRuntimeBase.RuntimeMode.SINGLEPLAYER
	root.add_child(runtime)
	current_scene = runtime
	await process_frame

	var coordinator := runtime.get_enemy_simulation_coordinator()
	_expect(coordinator != null, "authored runtime 必须提供 EnemySimulationCoordinator。")
	_expect(
		runtime.get_enemy_contact_service() != null,
		"authored runtime 必须提供共享 EnemyContactService。"
	)
	if coordinator == null or runtime.get_enemy_contact_service() == null:
		await _dispose_runtime(runtime, coordinator)
		_finish({})
		return
	coordinator.set_mode(EnemySimulationPolicy.Mode.LAYERED_CONTACT)

	var allied_config := BASIC_CONFIG.duplicate(true) as EnemyConfig
	var hostile_config := BASIC_CONFIG.duplicate(true) as EnemyConfig
	_expect(
		allied_config != null and hostile_config != null,
		"基础原石虫配置必须可为两阵营压力夹具复制。"
	)
	if allied_config == null or hostile_config == null:
		await _dispose_runtime(runtime, coordinator)
		_finish({})
		return
	_configure_stress_config(
		allied_config,
		CombatRelationService.PLAYER_ALLIED
	)
	_configure_stress_config(
		hostile_config,
		CombatRelationService.HOSTILE_WAVE
	)

	var spawn_started_usec := Time.get_ticks_usec()
	for pair_index in range(FACTION_SIZE):
		var pair_positions := _get_pair_positions(pair_index)
		var allied := _spawn_yuanshi(
			runtime,
			allied_config,
			ALLIED_NET_ID_BASE + pair_index,
			pair_positions[0],
			pair_index * 2
		)
		var hostile := _spawn_yuanshi(
			runtime,
			hostile_config,
			HOSTILE_NET_ID_BASE + pair_index,
			pair_positions[1],
			pair_index * 2 + 1
		)
		if allied != null:
			allied_enemies.append(allied)
		if hostile != null:
			hostile_enemies.append(hostile)
	var spawn_usec := Time.get_ticks_usec() - spawn_started_usec
	_expect(
		allied_enemies.size() == FACTION_SIZE
		and hostile_enemies.size() == FACTION_SIZE,
		"压力夹具必须完整生成 150v150 个真实基础原石虫。"
	)
	if (
		allied_enemies.size() != FACTION_SIZE
		or hostile_enemies.size() != FACTION_SIZE
	):
		await _dispose_runtime(runtime, coordinator)
		_finish({"spawn_usec": spawn_usec})
		return

	_assign_paired_dynamic_targets(runtime)
	var initial_index_migrations: int = int(
		runtime.combat_target_index.event_bucket_migrations_total
	)
	var soft_pass_first_initial_health: int = (
		allied_enemies[SOFT_PASS_FIRST_PAIR_INDEX].current_health
	)
	var soft_pass_second_initial_health: int = (
		allied_enemies[SOFT_PASS_SECOND_PAIR_INDEX].current_health
	)
	var faction_changed_health_after_switch := -1
	var faction_change_succeeded := false
	var faction_change_fallback_succeeded := false
	var target_death_succeeded := false
	var stress_physics_frames := 0
	var final_metrics: Dictionary = coordinator.get_metrics()
	var run_started_usec := Time.get_ticks_usec()

	while (
		int(final_metrics.get("authoritative_steps", 0))
		< STRESS_MINIMUM_AUTHORITATIVE_TICKS
		and stress_physics_frames < STRESS_MAXIMUM_PHYSICS_FRAMES
	):
		await physics_frame
		stress_physics_frames += 1
		if stress_physics_frames == FACTION_CHANGE_FRAME:
			var changed_enemy := hostile_enemies[2]
			faction_change_succeeded = changed_enemy.set_combat_faction_id(
				CombatRelationService.PLAYER_ALLIED
			)
			changed_enemy.consider_automatic_combat_target(
				hostile_enemies[3],
				1
			)
			changed_enemy.refresh_dynamic_combat_target_decision(
				Engine.get_physics_frames()
			)
			allied_enemies[2].refresh_dynamic_combat_target_decision(
				Engine.get_physics_frames()
			)
			faction_change_fallback_succeeded = (
				_has_valid_automatic_fallback(
					allied_enemies[2],
					hostile_enemies[2]
				)
				and _has_valid_automatic_fallback(
					hostile_enemies[2],
					allied_enemies[2]
				)
			)
			faction_change_immediate_diagnostics = (
				_capture_faction_change_target_diagnostics()
			)
			faction_changed_health_after_switch = changed_enemy.current_health
		if stress_physics_frames == TARGET_DEATH_FRAME:
			var death_target := hostile_enemies[0]
			death_target_scheduled_steps = (
				death_target.scheduled_authoritative_step_count
			)
			var death_result := death_target.apply_combat_damage(
				_make_lethal_player_allied_damage_request()
			)
			target_death_succeeded = death_result.accepted and death_result.lethal
		final_metrics = coordinator.get_metrics()

	var run_usec := Time.get_ticks_usec() - run_started_usec
	_validate_stress_result(
		runtime,
		coordinator,
		final_metrics,
		initial_index_migrations,
		soft_pass_first_initial_health,
		soft_pass_second_initial_health,
		faction_changed_health_after_switch,
		faction_change_succeeded,
		faction_change_fallback_succeeded,
		target_death_succeeded
	)
	var contact_metrics: Dictionary = (
		runtime.get_enemy_contact_service().get_metrics()
	)
	var result: Dictionary = {
		"status": "ok" if failures.is_empty() else "failed",
		"seed": FIXED_SEED,
		"spawned": TOTAL_ENEMY_COUNT,
		"physics_frames": stress_physics_frames,
		"authoritative_enemy_ticks": int(
			final_metrics.get("authoritative_steps", 0)
		),
		"registered_count": int(final_metrics.get("registered_count", -1)),
		"event_bucket_migrations": (
			runtime.combat_target_index.event_bucket_migrations_total
			- initial_index_migrations
		),
		"contact_registered_count": int(
			contact_metrics.get("registered_count", -1)
		),
		"spawn_usec": spawn_usec,
		"run_usec": run_usec,
		"faction_change_targets": _capture_faction_change_target_diagnostics(),
		"faction_change_immediate_targets": faction_change_immediate_diagnostics,
		"failures": failures.duplicate(),
	}
	await _dispose_runtime(runtime, coordinator)
	_finish(result)


func _configure_stress_config(config: EnemyConfig, faction_id: int) -> void:
	config.default_combat_faction_id = faction_id
	config.max_health = PROBE_HEALTH
	config.xirang_kill_reward = 0
	config.drop_table = null


func _spawn_yuanshi(
	runtime: EnemyGameplayGatewayTestRuntime,
	config: EnemyConfig,
	net_id: int,
	spawn_position: Vector2,
	seed_offset: int
) -> YuanshiInsect:
	var enemy := config.enemy_scene.instantiate() as YuanshiInsect
	if enemy == null:
		failures.append("net_id=%d 的基础原石虫场景实例化失败。" % net_id)
		return null
	runtime.enemy_container.add_child(enemy)
	enemy.random_generator.seed = FIXED_SEED + seed_offset * 2
	enemy.material_drop_random_generator.seed = FIXED_SEED + seed_offset * 2 + 1
	enemy.global_position = spawn_position
	# 轻量 authored runtime 的 GridPathfinder 节点故意只是网关占位；本门禁
	# 验证动态目标、共享接触和空间索引，所以稍后为无障碍直线写入与生产
	# 运动热路径相同的有限证书，不把占位寻路结果混入压力证据。
	enemy.setup(config, null, null, runtime)
	enemy.current_health = PROBE_HEALTH
	enemy.set_near_moving_target_direct_distance(10_000.0)
	if not runtime.register_network_enemy(net_id, enemy):
		failures.append("net_id=%d 的基础原石虫网络/空间索引注册失败。" % net_id)
		enemy.queue_free()
		return null
	initial_bucket_by_net_id[net_id] = enemy.combat_target_index_bucket
	return enemy


func _get_pair_positions(pair_index: int) -> Array[Vector2]:
	if pair_index == SOFT_PASS_FIRST_PAIR_INDEX:
		return [Vector2(-64.0, -256.0), Vector2(400.0, -256.0)]
	if pair_index == SOFT_PASS_SECOND_PAIR_INDEX:
		return [Vector2(64.0, -256.0), Vector2(-400.0, -256.0)]
	var column := pair_index % NORMAL_PAIR_COLUMNS
	var row := floori(float(pair_index) / float(NORMAL_PAIR_COLUMNS))
	var allied_position := Vector2(
		float(column) * NORMAL_PAIR_COLUMN_SPACING + 72.0,
		float(row) * NORMAL_PAIR_ROW_SPACING
	)
	return [
		allied_position,
		allied_position + Vector2(NORMAL_PAIR_SEPARATION, 0.0),
	]


func _assign_paired_dynamic_targets(
	runtime: EnemyGameplayGatewayTestRuntime
) -> void:
	# Two sources retain a deterministic automatic fallback underneath their
	# Host-authored assignment. One assignment is invalidated by death and the
	# other by a runtime faction change during the 100k-tick window.
	allied_enemies[0].consider_automatic_combat_target(hostile_enemies[1], 1)
	allied_enemies[2].consider_automatic_combat_target(hostile_enemies[3], 1)
	for pair_index in range(FACTION_SIZE):
		_assign_dynamic_target(
			allied_enemies[pair_index],
			hostile_enemies[pair_index],
			HOSTILE_NET_ID_BASE + pair_index
		)
		_assign_dynamic_target(
			hostile_enemies[pair_index],
			allied_enemies[pair_index],
			ALLIED_NET_ID_BASE + pair_index
		)
	_expect(
		runtime.combat_target_index.enemies_by_net_id.size()
		== TOTAL_ENEMY_COUNT,
		"配对前 CombatTargetIndex 必须完整持有 300 个稳定 net_id。"
	)


func _assign_dynamic_target(
	source: YuanshiInsect,
	target: YuanshiInsect,
	target_net_id: int
) -> void:
	var descriptor := DESCRIPTOR.create_enemy(
		target_net_id,
		target.get_faction_revision(),
		target.global_position
	)
	_expect(
		source.apply_designated_combat_target(descriptor),
		"net_id=%d 的动态 Enemy 指定目标必须成功。" % target_net_id
	)
	_prime_verified_direct_motion(source, target)


func _prime_verified_direct_motion(
	source: YuanshiInsect,
	target: YuanshiInsect
) -> void:
	var offset := target.global_position - source.global_position
	var direction := offset.normalized() if offset != Vector2.ZERO else Vector2.ZERO
	source.cached_navigation_move_direction = direction
	source.cached_navigation_uses_direct_objective_approach = (
		direction != Vector2.ZERO
	)
	source.cached_navigation_verified_direct_motion_clearance = offset.length()
	source.cached_navigation_generation = -1
	source.cached_navigation_tracks_live_target_direction = true
	source.navigation_scheduled_refresh_interval_frames = maxi(
		source.navigation_update_interval_frames,
		1
	)
	source.navigation_next_refresh_physics_frame = (
		Engine.get_physics_frames() + DIRECT_CERTIFICATE_FRAME_LIMIT
	)


func _make_lethal_player_allied_damage_request() -> DamageRequest:
	var request := DamageRequest.new(
		PROBE_HEALTH * 2,
		CombatTypes.DamageType.PHYSICAL
	)
	request.with_source_snapshot(DamageSourceSnapshot.create(
		CombatRelationService.PLAYER_ALLIED,
		1,
		1,
		900_001,
		&"dynamic_faction_stress"
	))
	request.with_flag(CombatTypes.DamageFlag.SUPPRESS_HIT_PARTICLES)
	request.with_flag(CombatTypes.DamageFlag.SUPPRESS_HIT_FLASH)
	return request


func _validate_stress_result(
	runtime: EnemyGameplayGatewayTestRuntime,
	coordinator: EnemySimulationCoordinator,
	metrics: Dictionary,
	initial_index_migrations: int,
	soft_pass_first_initial_health: int,
	soft_pass_second_initial_health: int,
	faction_changed_health_after_switch: int,
	faction_change_succeeded: bool,
	faction_change_fallback_succeeded: bool,
	target_death_succeeded: bool
) -> void:
	var authoritative_steps := int(metrics.get("authoritative_steps", 0))
	_expect(
		authoritative_steps >= STRESS_MINIMUM_AUTHORITATIVE_TICKS,
		"动态阵营压力门禁必须累计至少 100,000 authoritative enemy-tick。"
	)
	_expect(
		faction_change_succeeded
		and hostile_enemies[2].get_combat_faction_id()
		== CombatRelationService.PLAYER_ALLIED
		and hostile_enemies[2].get_faction_revision() == 1,
		"运行窗口中的一次阵营变化必须递增 revision 并收敛到玩家阵营。"
	)
	_expect(
		int(runtime.combat_target_index.faction_by_net_id.get(
			HOSTILE_NET_ID_BASE + 2,
			-1
		)) == CombatRelationService.PLAYER_ALLIED,
		"阵营变化必须原子迁移 CombatTargetIndex 的阵营分区。"
	)
	_expect(
		faction_changed_health_after_switch >= 0
		and hostile_enemies[2].current_health
		== faction_changed_health_after_switch,
		"目标转为友方后，旧指定攻击者不得继续造成伤害。"
	)
	_expect(
		faction_change_fallback_succeeded,
		"阵营变化令指定目标失效后，双方必须切换到合法敌对自动目标。"
	)
	for source in [allied_enemies[2], hostile_enemies[2]]:
		_expect(
			source.objective_target == null
			or source.can_attack_combat_target(source.objective_target),
			"长时间移动后 active 目标可以离开感知范围，但不得退回友方目标。"
		)
	_expect(
		target_death_succeeded
		and runtime.combat_target_index.get_enemy(HOSTILE_NET_ID_BASE) == null
		and allied_enemies[0].objective_target == hostile_enemies[1],
		"指定 Enemy 死亡后必须从稳定索引失效，并自动补位到缓存候选。"
	)

	var first_soft_pass := allied_enemies[SOFT_PASS_FIRST_PAIR_INDEX]
	var second_soft_pass := allied_enemies[SOFT_PASS_SECOND_PAIR_INDEX]
	_expect(
		first_soft_pass.global_position.x > second_soft_pass.global_position.x,
		"同阵营原石虫必须软穿行并完成相向位置交换，不能互相物理阻挡。"
	)
	_expect(
		first_soft_pass.current_health == soft_pass_first_initial_health
		and second_soft_pass.current_health == soft_pass_second_initial_health,
		"相向软穿行的友军不得互相造成接触伤害。"
	)

	var damaged_enemy_count := 0
	var live_enemy_count := 0
	var scheduled_step_sum := death_target_scheduled_steps
	var changed_bucket_count := 0
	var broad_query := Rect2(Vector2(-512.0, -512.0), Vector2(5_000.0, 1_500.0))
	var indexed_targets: Array[Enemy] = []
	runtime.query_combat_targets_in_world_aabb_into(
		broad_query,
		indexed_targets
	)
	var previous_net_id := 0
	for indexed_enemy in indexed_targets:
		var indexed_net_id := indexed_enemy.combat_target_index_net_id
		_expect(
			indexed_net_id > previous_net_id,
			"客户端/小地图共用 AABB 查询必须保持稳定 net_id 顺序。"
		)
		previous_net_id = indexed_net_id
	for enemy in allied_enemies + hostile_enemies:
		if enemy == null or not is_instance_valid(enemy) or enemy.is_dead:
			continue
		live_enemy_count += 1
		scheduled_step_sum += enemy.scheduled_authoritative_step_count
		if enemy.current_health < PROBE_HEALTH:
			damaged_enemy_count += 1
		var net_id := enemy.combat_target_index_net_id
		if initial_bucket_by_net_id.get(net_id, Vector2i.MAX) != enemy.combat_target_index_bucket:
			changed_bucket_count += 1
		_expect(
			runtime.combat_target_index.get_enemy(net_id) == enemy,
			"移动后的真实原石虫必须仍由原稳定 net_id 解析。"
		)
		_expect(
			enemy.is_centrally_simulated()
			and not enemy.is_physics_processing(),
			"权威原石虫只能由 coordinator 执行，不能恢复逐节点 physics。"
		)
	_expect(
		damaged_enemy_count >= 200,
		"150v150 接触压力中必须有大量敌对目标实际产生接触伤害。"
	)
	_expect(
		changed_bucket_count > 0
		and runtime.combat_target_index.event_bucket_migrations_total
		> initial_index_migrations,
		"权威运动必须跨越至少一个 96px 空间格并由事件路径迁移索引。"
	)
	_expect(
		indexed_targets.size() == live_enemy_count,
		"最终 AABB 候选数必须与仍存活的索引成员完全一致。"
	)
	_expect(
		live_enemy_count == TOTAL_ENEMY_COUNT - 1
		and int(metrics.get("registered_count", -1)) == live_enemy_count
		and int(metrics.get("active_count", -1)) == live_enemy_count,
		"一次目标死亡后 coordinator 必须精确保留 299 个活跃注册。"
	)
	_expect(
		scheduled_step_sum == authoritative_steps,
		"coordinator authoritative_steps 必须等于每个实体实际接收步数之和。"
	)
	var contact_metrics := runtime.get_enemy_contact_service().get_metrics()
	_expect(
		int(contact_metrics.get("registered_count", -1)) == live_enemy_count
		and int(metrics.get("contact_registration_rejections", -1)) == 0,
		"共享接触服务必须与 coordinator 活跃注册完全收敛且无形状拒绝。"
	)


func _capture_faction_change_target_diagnostics() -> Dictionary:
	var result := {}
	for source_index in [2]:
		for source_label in ["allied", "changed"]:
			var source := (
				allied_enemies[source_index]
				if source_label == "allied"
				else hostile_enemies[source_index]
			)
			var objective := source.objective_target as Enemy
			result[source_label] = {
				"objective_net_id": (
					objective.combat_target_index_net_id
					if objective != null
					else 0
				),
				"objective_faction": (
					objective.get_combat_faction_id()
					if objective != null
					else -1
				),
				"objective_attackable": (
					source.can_attack_combat_target(objective)
					if objective != null
					else false
				),
				"active_is_assigned": (
					source.targeting_state.is_active_target_assigned()
				),
				"assigned_id": source.targeting_state.assigned_target.id,
				"automatic_id": source.targeting_state.automatic_target.id,
				"active_id": source.targeting_state.active_target.id,
			}
	return result


func _has_valid_automatic_fallback(
	source: YuanshiInsect,
	invalid_designated_target: Enemy
) -> bool:
	var objective := source.objective_target as Enemy
	return (
		objective != null
		and objective != invalid_designated_target
		and source.can_attack_combat_target(objective)
		and not source.targeting_state.is_active_target_assigned()
	)


func _dispose_runtime(
	runtime: EnemyGameplayGatewayTestRuntime,
	coordinator: EnemySimulationCoordinator
) -> void:
	if coordinator != null and is_instance_valid(coordinator):
		coordinator.clear(false)
	if runtime != null and is_instance_valid(runtime):
		runtime.clear_network_enemy_registry()
		_expect(
			runtime.combat_target_index.enemies_by_net_id.is_empty(),
			"动态压力夹具清理后 CombatTargetIndex 必须为空。"
		)
		if coordinator != null and is_instance_valid(coordinator):
			_expect(
				int(coordinator.get_metrics().get("registered_count", -1)) == 0,
				"动态压力夹具清理后 coordinator 注册必须归零。"
			)
		var contact_service := runtime.get_enemy_contact_service()
		if contact_service != null:
			_expect(
				int(contact_service.get_metrics().get("registered_count", -1))
				== 0,
				"动态压力夹具清理后共享接触注册必须归零。"
			)
		if current_scene == runtime:
			current_scene = null
		runtime.queue_free()
	await process_frame
	await physics_frame


func _finish(result: Dictionary) -> void:
	var output := result.duplicate(true)
	output["status"] = "ok" if failures.is_empty() else "failed"
	output["failures"] = failures.duplicate()
	print("ENEMY_DYNAMIC_FACTION_STRESS_JSON %s" % JSON.stringify(output))
	if failures.is_empty():
		print("ENEMY_DYNAMIC_FACTION_STRESS_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
