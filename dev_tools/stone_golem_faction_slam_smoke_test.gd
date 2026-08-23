extends SceneTree

## Stage-five focused acceptance test for the complete stone-golem slam query.
## The test covers the inherited elite path because source identity is virtual.

const RUNTIME_SCENE := preload(
	"res://dev_tools/fixtures/enemy_gameplay_gateway_test_runtime.tscn"
)
const BASE_CONFIG := preload(
	"res://resources/config/enemies/stone_golem.tres"
)
const ELITE_CONFIG := preload(
	"res://resources/config/enemies/stone_golem_elite.tres"
)
const TARGET_CONFIG := preload(
	"res://resources/config/enemies/yuanshi_insect_basic.tres"
)
const IMMUNE_TARGET_CONFIG := preload(
	"res://resources/config/enemies/combat_robot_main_battle_elite.tres"
)
const GREEN_SHELL_CONFIG := preload(
	"res://resources/config/enemies/yuanshi_insect_green_shell.tres"
)
const PLAYER_SCENE := preload(
	"res://scene/player/weishidaier/player_weishidaier.tscn"
)

var failures: Array[String] = []
var runtime: EnemyGameplayGatewayTestRuntime
var next_net_id := 7000


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	runtime = RUNTIME_SCENE.instantiate() as EnemyGameplayGatewayTestRuntime
	root.add_child(runtime)
	current_scene = runtime
	await process_frame

	_test_static_transaction_contract()
	_test_yuanshi_dynamic_target_capabilities()
	await _test_enemy_slam_transaction(
		BASE_CONFIG,
		&"stone_golem_slam",
		Vector2.ZERO
	)
	await _test_enemy_slam_transaction(
		ELITE_CONFIG,
		&"stone_golem_elite_slam",
		Vector2(256.0, 0.0)
	)
	await _test_aura_cooldown_admission()

	StoneGolem.set_slam_performance_metrics_enabled(false)
	current_scene = null
	runtime.queue_free()
	for _cleanup_frame in range(4):
		await process_frame
		await physics_frame
	if failures.is_empty():
		print("STONE_GOLEM_FACTION_SLAM_SMOKE_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_static_transaction_contract() -> void:
	var source := FileAccess.get_file_as_string(
		"res://scene/enemy/artificial_creation/stone_golem.gd"
	)
	var dispatch_guard_position := source.find("if not _dispatch_slash_damage(")
	var ledger_commit_position := source.find(
		"slam_hit_target_ids[target_id] = true",
		dispatch_guard_position
	)
	_expect(
		source.contains("const SLAM_ENEMY_COLLISION_MASK := 1 << 2")
		and source.contains("| SLAM_ENEMY_COLLISION_MASK")
		and not source.contains("plant.receive_damage("),
		"石像人 slam 必须查询 Enemy layer，并让 Player/Plant/Enemy 共用统一伤害入口。"
	)
	_expect(
		dispatch_guard_position >= 0
		and ledger_commit_position > dispatch_guard_position,
		"石像人 slam 只能在 DamageResult.accepted 后提交命中账本。"
	)
	var knight_source := FileAccess.get_file_as_string(
		"res://scene/enemy/capoo/capoo_knight.gd"
	)
	_expect(
		knight_source.contains(
			"damage_type: int = EnemyConfig.DamageType.PHYSICAL"
		)
		and knight_source.contains(
			"impact_direction: Vector2 = Vector2.ZERO"
		)
		and knight_source.contains("-resolved_impact_direction"),
		"Knight 家族统一入口必须兼容旧调用并透传伤害类型和冲击方向。"
	)


func _test_yuanshi_dynamic_target_capabilities() -> void:
	var base := YuanshiInsect.new()
	var slime := Slime.new()
	var fire_ranged := YuanshiInsectFireRanged.new()
	var exploder := YuanshiInsectExploder.new()
	var aura := YuanshiInsectAura.new()
	_expect(
		base.supports_dynamic_enemy_targeting()
		and slime.supports_dynamic_enemy_targeting()
		and fire_ranged.supports_dynamic_enemy_targeting()
		and exploder.supports_dynamic_enemy_targeting(),
		(
			"元始基础、史莱姆、火焰远程和自爆家族的动态 Enemy 目标能力"
			+ "不得被各自的分层调度策略关闭。"
		)
	)
	_expect(
		not aura.supports_dynamic_enemy_targeting(),
		"Player-only 光环攻击迁移前必须显式拒绝动态 Enemy 目标。"
	)
	for enemy in [base, slime, fire_ranged, exploder, aura]:
		enemy.free()


func _test_enemy_slam_transaction(
	source_config_resource: EnemyConfig,
	expected_source_type: StringName,
	origin: Vector2
) -> void:
	var source := _spawn_enemy(source_config_resource, origin) as StoneGolem
	var accepted_target := _spawn_enemy(
		TARGET_CONFIG,
		origin + Vector2(22.0, 0.0)
	)
	var immune_target := _spawn_enemy(
		IMMUNE_TARGET_CONFIG,
		origin + Vector2(-22.0, 0.0)
	) as CombatRobotMainBattleElite
	if source == null or accepted_target == null or immune_target == null:
		_expect(false, "石像人 slam 专项场景实例化失败。")
		return

	source.set_combat_faction_id(
		CombatRelationService.PLAYER_ALLIED,
		-1,
		true
	)
	immune_target.airborne = true
	source.attack_cooldown_left = 0.0
	source.action_sequence = 40
	await _wait_physics_frames(3)
	var windup_started := false
	for _attempt in range(16):
		windup_started = bool(source.call(
			&"_try_start_windup",
			accepted_target
		))
		if windup_started:
			break
		await physics_frame
	_expect(windup_started, "石像人必须能对敌对 Enemy 开始蓄力。")
	if not windup_started:
		_queue_fixture_free([source, accepted_target, immune_target])
		await _wait_physics_frames(2)
		return

	var frozen_snapshot := source.slash_damage_source_snapshot
	_expect(
		frozen_snapshot != null
		and frozen_snapshot.source_faction_id
			== CombatRelationService.PLAYER_ALLIED
		and frozen_snapshot.source_type == expected_source_type,
		"%s 必须在 windup 时冻结正确的阵营与攻击来源。" % expected_source_type
	)
	var accepted_health_before := accepted_target.current_health
	var immune_health_before := immune_target.current_health
	StoneGolem.set_slam_performance_metrics_enabled(true)
	source.call(&"_apply_slash_damage")
	var metrics := StoneGolem.get_slam_performance_metrics(true)
	StoneGolem.set_slam_performance_metrics_enabled(false)
	var accepted_result := accepted_target.last_damage_result
	var immune_result := immune_target.last_damage_result
	_expect(
		accepted_result != null
		and accepted_result.accepted
		and accepted_target.current_health < accepted_health_before
		and accepted_result.request.get_or_create_source_snapshot().source_type
			== expected_source_type,
		"%s slam 必须通过冻结 snapshot 伤害敌对 Enemy。" % expected_source_type
	)
	_expect(
		immune_result != null
		and immune_result.is_rejected_for(
			CombatTypes.DamageRejectionReason.INVULNERABLE
		)
		and immune_target.current_health == immune_health_before
		and not source.slam_hit_target_ids.has(immune_target.get_instance_id()),
		"被伤害域拒绝的 Enemy 不得占用 slam 命中账本。"
	)
	_expect(
		int(metrics.get("slam_unique_targets", -1)) == 1
		and int(metrics.get("slam_damage_dispatches", -1)) == 1,
		"slam 指标只能统计 accepted 目标：%s。" % [metrics]
	)
	_queue_fixture_free([source, accepted_target, immune_target])
	await _wait_physics_frames(2)


func _test_aura_cooldown_admission() -> void:
	var player := PLAYER_SCENE.instantiate() as Player
	runtime.add_child(player)
	player.bind_combat_runtime(runtime)
	player.global_position = Vector2(2048.0, 2048.0)
	player.max_health = 500
	player.current_health = 500
	player.physical_defense = 0
	player.magic_defense = 0
	player.invincibility_duration = 0.0
	player.invincibility_time_left = 0.0
	player.dodge_chance = 0.0
	player.health_bar.set_health(player.current_health, player.max_health)
	player.set_process(false)
	player.set_physics_process(false)
	var aura_config := GREEN_SHELL_CONFIG.duplicate(
		true
	) as YuanshiInsectGreenShellConfig
	aura_config.move_speed = 0.0
	aura_config.aura_damage_interval = 0.75
	var aura := _spawn_enemy(
		aura_config,
		Vector2(1800.0, 1800.0)
	) as YuanshiInsectAura
	if aura == null:
		_expect(false, "光环冷却专项场景实例化失败。")
		player.queue_free()
		return
	aura.aura_touched_player = player
	aura.aura_damage_cooldown_left = 0.0
	aura.set_combat_faction_id(
		CombatRelationService.PLAYER_ALLIED,
		-1,
		true
	)
	var friendly_health := player.current_health
	aura.call(&"_try_deal_aura_damage")
	_expect(
		player.current_health == friendly_health
		and is_zero_approx(aura.aura_damage_cooldown_left),
		"友方 Player 光环接触不得造成伤害或提前消费攻击冷却。"
	)
	aura.set_combat_faction_id(
		CombatRelationService.HOSTILE_WAVE,
		-1,
		true
	)
	aura.call(&"_try_deal_aura_damage")
	_expect(
		player.current_health < friendly_health
		and is_equal_approx(
			aura.aura_damage_cooldown_left,
			aura_config.aura_damage_interval
		),
		"只有真正处理敌对 Player 命中后，光环才应进入攻击冷却。"
	)
	_queue_fixture_free([aura, player])
	await _wait_physics_frames(2)


func _spawn_enemy(config_resource: EnemyConfig, position: Vector2) -> Enemy:
	var config := config_resource.duplicate(true) as EnemyConfig
	config.max_health = maxi(config.max_health, 500)
	config.physical_defense = 0
	config.magic_defense = 0
	config.xirang_kill_reward = 0
	config.drop_table = null
	if config is StoneGolemConfig:
		(config as StoneGolemConfig).initial_attack_stagger = 0.0
	var enemy := config.enemy_scene.instantiate() as Enemy
	if enemy == null:
		return null
	runtime.enemy_container.add_child(enemy)
	enemy.global_position = position
	enemy.setup(config, null, runtime.grid_pathfinder, runtime)
	enemy.set_process(false)
	enemy.set_physics_process(false)
	next_net_id += 1
	_expect(
		runtime.register_network_enemy(next_net_id, enemy),
		"石像人 slam 专项敌人注册失败：%d。" % next_net_id
	)
	return enemy


func _queue_fixture_free(nodes: Array) -> void:
	for node_variant in nodes:
		var node := node_variant as Node
		if node != null and is_instance_valid(node):
			node.queue_free()


func _wait_physics_frames(frame_count: int) -> void:
	for _frame_index in range(frame_count):
		await physics_frame


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
