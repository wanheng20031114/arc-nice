extends SceneTree

const RUNTIME_SCENE := preload(
	"res://dev_tools/fixtures/enemy_gameplay_gateway_test_runtime.tscn"
)
const FAST_CONFIG := preload(
	"res://resources/config/enemies/yuanshi_insect_fast.tres"
)
const DESCRIPTOR := preload(
	"res://scene/combat/targeting/combat_target_descriptor.gd"
)

var failures: Array[String] = []


class ReachabilityHarness extends YuanshiInsect:
	var forced_unreachable_target: Node2D = null


	func classify_combat_target_reachability(target: Node2D) -> int:
		return (
			EnemyTargetingState.ReachabilityResult.UNREACHABLE
			if target == forced_unreachable_target
			else EnemyTargetingState.ReachabilityResult.REACHABLE
		)


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	var runtime := RUNTIME_SCENE.instantiate() as EnemyGameplayGatewayTestRuntime
	root.add_child(runtime)
	await process_frame
	var coordinator := runtime.get_enemy_simulation_coordinator()
	coordinator.set_mode(EnemySimulationPolicy.Mode.LAYERED_AREA)

	var source := _spawn_enemy(runtime, 101, Vector2.ZERO)
	var designated := _spawn_enemy(runtime, 102, Vector2(96.0, 0.0))
	var fallback := _spawn_enemy(runtime, 103, Vector2(48.0, 0.0))
	source.set_combat_faction_id(CombatRelationService.PLAYER_ALLIED, -1, true)
	_expect(
		source.supports_dynamic_enemy_targeting()
		and source.can_attack_combat_target(designated)
		and not source.can_attack_combat_target(source),
		"普通元始必须允许敌对 Enemy 动态目标，并严格排除自身。"
	)

	_expect(
		source.consider_automatic_combat_target(fallback, 1)
		and source.objective_target == fallback
		and source.get_attackable_objective() == fallback,
		"敌对 Enemy 自动候选必须成为可攻击导航目标。"
	)
	var assignment := DESCRIPTOR.create_enemy(
		102,
		1,
		designated.global_position
	)
	_expect(
		source.apply_designated_combat_target(assignment)
		and source.objective_target == designated,
		"宿主指定 Enemy 必须越过普通搜索距离并取得绝对优先级。"
	)

	designated.set_combat_faction_id(
		CombatRelationService.PLAYER_ALLIED,
		-1,
		true
	)
	source.refresh_dynamic_combat_target_decision(Engine.get_physics_frames())
	_expect(
		source.objective_target == fallback
		and source.targeting_state.is_assignment_negative_cached(
			Engine.get_physics_frames()
		),
		"指定目标转为友方后必须立即进入负缓存并启用自动补位。"
	)

	var fallback_original_position := fallback.global_position
	var contact_radius := (
		maxf(source.touch_damage_extent_radius, source.body_collision_extent_radius)
		+ fallback.body_collision_extent_radius
	)
	fallback.global_position = Vector2(maxf(contact_radius - 0.25, 0.0), 0.0)
	_expect(
		source._has_dynamic_enemy_target_contact(),
		"敌对动态目标进入攻击壳层后必须停步。"
	)
	fallback.set_combat_faction_id(
		CombatRelationService.PLAYER_ALLIED,
		-1,
		true
	)
	_expect(
		not source._has_dynamic_enemy_target_contact()
		and not source.can_attack_combat_target(fallback),
		"同阵营敌人必须软穿行，不能形成停步接触。"
	)
	var friendly_player := Player.new()
	friendly_player.peer_id = 1
	source._on_touch_damage_area_body_entered(friendly_player)
	_expect(
		source._select_touching_player() == null
		and not source._has_player_contact(),
		"玩家阵营敌人即使仍处于旧 Area 重叠中，也不能被友方玩家挡停或选作伤害目标。"
	)
	source._on_touch_damage_area_body_exited(friendly_player)
	friendly_player.free()

	fallback.set_combat_faction_id(
		CombatRelationService.HOSTILE_WAVE,
		-1,
		true
	)
	fallback.global_position = fallback_original_position + Vector2(192.0, 0.0)
	var fallback_descriptor := runtime.get_combat_query_facade().describe_enemy(
		fallback,
		fallback.get_faction_revision()
	)
	_expect(
		fallback_descriptor != null
		and runtime.get_combat_query_facade().resolve_target(fallback_descriptor)
			== fallback
		and runtime.combat_target_index.get_enemy(103) == fallback,
		"动态目标跨越多个 96px 空间格后，稳定 ID 解析和索引成员必须保持一致。"
	)
	var removed_target := _spawn_enemy(runtime, 104, source.global_position)
	source.set_objective_target(removed_target)
	removed_target.free()
	_expect(
		not source._has_dynamic_enemy_target_contact(),
		"动态 Enemy 目标同步释放后，接触热路径必须安全失效，不能强转已释放对象。"
	)
	source._update_touch_damage(1.0 / 60.0)
	_test_unreachable_automatic_target_bypasses_hysteresis(runtime)

	coordinator.set_mode(EnemySimulationPolicy.Mode.LEGACY)
	runtime.queue_free()
	await process_frame
	await physics_frame
	if failures.is_empty():
		print("YUANSHI_DYNAMIC_ENEMY_TARGET_SMOKE_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_unreachable_automatic_target_bypasses_hysteresis(
	runtime: EnemyGameplayGatewayTestRuntime
) -> void:
	var source := ReachabilityHarness.new()
	var old_target := Enemy.new()
	var reachable_replacement := Enemy.new()
	source.bind_combat_runtime(runtime)
	source.set_combat_faction_id(
		CombatRelationService.PLAYER_ALLIED,
		-1,
		true
	)
	old_target.global_position = Vector2(24.0, 0.0)
	reachable_replacement.global_position = Vector2(96.0, 0.0)
	runtime.register_network_enemy(201, source)
	runtime.register_network_enemy(202, old_target)
	runtime.register_network_enemy(203, reachable_replacement)
	source.consider_automatic_combat_target(old_target, 1)
	source.forced_unreachable_target = old_target
	var coordinator := TowerDefenseEnemyCoordinator.new()
	coordinator.call(
		"_prune_out_of_sense_automatic_target",
		source,
		source.global_position
	)
	var replacement_accepted := source.consider_automatic_combat_target(
		reachable_replacement,
		1
	)
	_expect(
		replacement_accepted
		and source.get_automatic_combat_target() == reachable_replacement,
		(
			"旧自动目标跨入断开连通分量后必须先被清除；更远但可达的候选"
			+ "不得被 25% 滞回永久锁死。"
		)
	)
	coordinator.free()
	runtime.unregister_network_enemy(201, source)
	runtime.unregister_network_enemy(202, old_target)
	runtime.unregister_network_enemy(203, reachable_replacement)
	source.free()
	old_target.free()
	reachable_replacement.free()


func _spawn_enemy(
	runtime: EnemyGameplayGatewayTestRuntime,
	net_id: int,
	position: Vector2
) -> YuanshiInsect:
	var enemy := FAST_CONFIG.enemy_scene.instantiate() as YuanshiInsect
	runtime.enemy_container.add_child(enemy)
	enemy.global_position = position
	enemy.setup(FAST_CONFIG, null, null, runtime)
	if not runtime.register_network_enemy(net_id, enemy):
		failures.append("测试敌人 %d 注册失败。" % net_id)
	return enemy


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
