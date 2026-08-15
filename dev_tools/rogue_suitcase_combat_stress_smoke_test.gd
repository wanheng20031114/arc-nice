extends SceneTree

const SUITCASE_CONFIG: RogueCombatEncounterConfig = preload(
	"res://resources/config/rogue_combat/suitcase_battle.tres"
)
const GUNNER_ELITE: EnemyConfig = preload(
	"res://resources/config/enemies/combat_robot_gunner_elite.tres"
)
const SHIELD_BEARER_ELITE: EnemyConfig = preload(
	"res://resources/config/enemies/combat_robot_shield_bearer_elite.tres"
)
const ELITE_BULLET_SCENE := preload(
	"res://scene/enemy/mechanical_life/combat_robot_gunner_elite_bullet.tscn"
)
const PLAYER_SCENE := preload(
	"res://scene/player/weishidaier/player_weishidaier.tscn"
)
const MP_PROJECTILE_COORDINATOR_SCRIPT := preload(
	"res://scene/multiplayer/projectile/mp_projectile_coordinator.gd"
)
const POINT_NAMES: Array[StringName] = [&"Spawn1", &"Spawn2", &"Spawn3"]
const STRESS_SEED := 73_310_581
const EXPECTED_ENEMY_COUNT := 100
const EXPECTED_ALIVE_CAP := 40
const ELITE_BULLET_CAPACITY := 480

var _failures := PackedStringArray()


class SpawnProbe:
	extends WaveCombatRuntimeBase

	var spawned_config_paths := PackedStringArray()
	var spawned_point_names := PackedStringArray()
	var next_fake_enemy_id := 1

	func configure_multiplayer(
		_mode: int,
		_local_peer_id: int,
		_player_names: Dictionary,
		_player_character_ids: Dictionary = {}
	) -> void:
		pass

	func get_player_for_peer(_peer_id: int) -> Player:
		return null

	func get_pickup_for_net_id(_net_id: int) -> Pickup:
		return null

	func remove_multiplayer_player(_peer_id: int) -> void:
		pass

	func collect_player_snapshot_states() -> Array[SnapshotManager.PlayerState]:
		return []

	func _configure_singleplayer_player() -> void:
		pass

	func _configure_multiplayer_players() -> void:
		pass

	func _connect_mode_singleplayer_player_death_signal() -> void:
		pass

	func _update_multiplayer_remote_player_passive_state(_delta: float) -> void:
		pass

	func _connect_mode_dynamic_pickup_containers() -> void:
		pass

	func _register_static_multiplayer_pickups() -> void:
		pass

	func _try_spawn_enemy(
		enemy_config: EnemyConfig,
		_xirang_kill_reward_override: int = -1
	) -> bool:
		if enemy_config == null:
			return false
		var spawn_point := _pick_spawn_point()
		if spawn_point == null:
			return false
		spawned_config_paths.append(enemy_config.resource_path)
		spawned_point_names.append(String(spawn_point.name))
		active_wave_enemy_ids[next_fake_enemy_id] = true
		next_fake_enemy_id += 1
		return true

	func _check_wave_completion() -> void:
		pass


class DirectPathfinder:
	extends Node

	var is_built := true

	func try_get_safe_navigation_step(
		_from_position: Vector2,
		target_position: Vector2,
		_half_extents: Vector2 = Vector2.ZERO,
		_terrain_types: int = DualGridTilemap.TraversalType.LAND
	) -> Dictionary:
		return {
			"status": GridPathfinder.NavigationStepStatus.READY,
			"is_complete_route": true,
			"waypoint": target_position,
		}


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	_test_formal_suitcase_config()
	var first_sequence := _run_spawn_scenario(STRESS_SEED, true)
	var repeated_sequence := _run_spawn_scenario(STRESS_SEED, false)
	_expect(
		first_sequence == repeated_sequence,
		"相同种子必须稳定复现敌人乱序与三门均衡序列。"
	)
	await _test_forty_live_elite_gunners()
	await _test_elite_bullet_pool_capacity()
	await _test_multiplayer_elite_bullet_proxy_stress()

	if _failures.is_empty():
		print("ROGUE_SUITCASE_COMBAT_STRESS_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in _failures:
		push_error(failure)
	quit(1)


func _test_formal_suitcase_config() -> void:
	_expect(SUITCASE_CONFIG != null, "必须能加载皮箱之战正式作战配置。")
	if SUITCASE_CONFIG == null:
		return
	_expect(
		SUITCASE_CONFIG.encounter_id == &"suitcase_battle"
		and SUITCASE_CONFIG.campaign != null
		and SUITCASE_CONFIG.validate_config().is_empty(),
		"皮箱之战正式配置必须有效且绑定稳定ID。"
	)
	var waves := SUITCASE_CONFIG.campaign.get_waves()
	_expect(waves.size() == 1, "皮箱之战必须只有一个终点波次。")
	if waves.size() != 1:
		return
	var wave := waves[0]
	_expect(
		wave.get_total_enemy_count() == EXPECTED_ENEMY_COUNT
		and is_equal_approx(wave.spawn_interval, 0.1)
		and wave.spawn_count_per_tick == 1
		and wave.max_alive_enemies == EXPECTED_ALIVE_CAP
		and wave.spawn_point_mask
			== (
				WaveConfig.SPAWN_POINT_1_MASK
				| WaveConfig.SPAWN_POINT_2_MASK
				| WaveConfig.SPAWN_POINT_3_MASK
			)
		and wave.spawn_point_order == WaveConfig.SpawnPointOrder.BALANCED_SHUFFLE_BAG
		and wave.spawn_order == WaveConfig.SpawnOrder.SHUFFLED,
		"皮箱之战必须保持100名敌人、0.1秒批1、存活上限40、三门均衡乱序。"
	)


func _run_spawn_scenario(seed_value: int, exercise_cap: bool) -> Dictionary:
	var waves := SUITCASE_CONFIG.campaign.get_waves()
	if waves.size() != 1:
		return {}
	var wave := waves[0]
	var probe := SpawnProbe.new()
	probe.wave_state = CombatFlowState.State.WAVE_ACTIVE
	probe.current_flow_step = wave
	probe.enemy_spawn_timer = Timer.new()
	probe.random_generator.seed = seed_value
	for point_name in POINT_NAMES:
		var marker := Marker2D.new()
		marker.name = point_name
		probe.active_wave_spawn_points.append(marker)
	probe.call("_build_wave_spawn_queue", wave)
	probe.reset_wave_progress(probe.pending_enemy_configs.size())

	for tick_index in range(EXPECTED_ALIVE_CAP):
		var spawned_before := probe.current_wave_spawned
		probe.call("_spawn_wave_batch")
		if exercise_cap:
			_expect(
				probe.current_wave_spawned == spawned_before + 1,
				"前40个生成tick必须严格批1；第%d个tick发生漂移。" % (tick_index + 1)
			)
	if exercise_cap:
		_expect(
			probe.current_wave_spawned == EXPECTED_ALIVE_CAP
			and probe.active_wave_enemy_ids.size() == EXPECTED_ALIVE_CAP
			and probe.pending_enemy_config_index == EXPECTED_ALIVE_CAP,
			"第40个tick后必须恰有40名存活敌人且游标停在40。"
		)

	var capped_spawned := probe.current_wave_spawned
	var capped_cursor := probe.pending_enemy_config_index
	var capped_attempts := probe.spawned_config_paths.size()
	probe.call("_spawn_wave_batch")
	if exercise_cap:
		_expect(
			probe.current_wave_spawned == capped_spawned
			and probe.pending_enemy_config_index == capped_cursor
			and probe.spawned_config_paths.size() == capped_attempts,
			"存活敌人达到40上限时，额外tick不得推进队列或尝试生成。"
		)

	_erase_one_active_enemy(probe)
	probe.call("_spawn_wave_batch")
	if exercise_cap:
		_expect(
			probe.current_wave_spawned == EXPECTED_ALIVE_CAP + 1
			and probe.active_wave_enemy_ids.size() == EXPECTED_ALIVE_CAP
			and probe.pending_enemy_config_index == EXPECTED_ALIVE_CAP + 1,
			"移除1名敌人后，下个tick必须只补1名并重新达到40上限。"
		)

	while probe.current_wave_spawned < EXPECTED_ENEMY_COUNT:
		_erase_one_active_enemy(probe)
		var spawned_before := probe.current_wave_spawned
		probe.call("_spawn_wave_batch")
		_expect(
			probe.current_wave_spawned == spawned_before + 1,
			"余下生成队列的每个tick也必须严格批1。"
		)

	var enemy_counts := {
		GUNNER_ELITE.resource_path: 0,
		SHIELD_BEARER_ELITE.resource_path: 0,
	}
	for config_path in probe.spawned_config_paths:
		enemy_counts[config_path] = int(enemy_counts.get(config_path, 0)) + 1
	_expect(
		probe.spawned_config_paths.size() == EXPECTED_ENEMY_COUNT
		and int(enemy_counts.get(GUNNER_ELITE.resource_path, 0)) == 95
		and int(enemy_counts.get(SHIELD_BEARER_ELITE.resource_path, 0)) == 5,
		"最终生成必须严格为95名精英枪手与5名精英举盾机器人。"
	)

	var point_counts := {&"Spawn1": 0, &"Spawn2": 0, &"Spawn3": 0}
	for point_name in probe.spawned_point_names:
		var point_id := StringName(point_name)
		point_counts[point_id] = int(point_counts.get(point_id, 0)) + 1
	var sorted_point_counts: Array[int] = []
	for point_count in point_counts.values():
		sorted_point_counts.append(int(point_count))
	sorted_point_counts.sort()
	_expect(
		probe.spawned_point_names.size() == EXPECTED_ENEMY_COUNT
		and sorted_point_counts == [33, 33, 34],
		"100次生成必须在三扇红门形成33/33/34分布：%s" % point_counts
	)

	var result := {
		"enemy_configs": probe.spawned_config_paths.duplicate(),
		"spawn_points": probe.spawned_point_names.duplicate(),
	}
	for marker in probe.active_wave_spawn_points:
		marker.free()
	probe.enemy_spawn_timer.free()
	probe.free()
	return result


func _erase_one_active_enemy(probe: SpawnProbe) -> void:
	var active_ids := probe.active_wave_enemy_ids.keys()
	if active_ids.is_empty():
		_failures.append("压力探针没有可移除的存活敌人。")
		return
	probe.active_wave_enemy_ids.erase(active_ids[0])


func _test_forty_live_elite_gunners() -> void:
	var fixture_root := Node2D.new()
	fixture_root.name = "SuitcaseFortyEliteFixture"
	fixture_root.process_mode = Node.PROCESS_MODE_DISABLED
	root.add_child(fixture_root)
	var target := PLAYER_SCENE.instantiate() as Player
	var pathfinder := DirectPathfinder.new()
	fixture_root.add_child(target)
	fixture_root.add_child(pathfinder)
	var live_enemies: Array[CombatRobotGunner] = []
	for enemy_index in range(EXPECTED_ALIVE_CAP):
		var enemy := (
			GUNNER_ELITE.enemy_scene.instantiate() as CombatRobotGunner
		)
		if enemy == null:
			_failures.append("第%d名精英枪手场景实例化失败。" % enemy_index)
			break
		fixture_root.add_child(enemy)
		enemy.setup(GUNNER_ELITE, target, pathfinder)
		enemy.set_process(false)
		enemy.set_physics_process(false)
		live_enemies.append(enemy)
	var configured_count := 0
	for enemy in live_enemies:
		if (
			enemy.is_inside_tree()
			and enemy.config == GUNNER_ELITE
			and enemy.get_node_or_null("Muzzle") is Marker2D
		):
			configured_count += 1
	_expect(
		live_enemies.size() == EXPECTED_ALIVE_CAP
		and configured_count == EXPECTED_ALIVE_CAP,
		(
			"必须能在同一场景树中同时实例化并配置40名正式精英枪手，"
			+ "而不是只用队列替身推算上限。"
		)
	)
	fixture_root.queue_free()
	await process_frame
	await process_frame


func _test_elite_bullet_pool_capacity() -> void:
	var pool := SessionObjectPool.new()
	pool.name = "SuitcaseEliteBulletPool"
	root.add_child(pool)
	CombatRuntimeBase.register_combat_robot_gunner_elite_bullet_pool(
		pool,
		ELITE_BULLET_CAPACITY,
		ELITE_BULLET_CAPACITY
	)
	var prewarmed := pool.get_metrics(ELITE_BULLET_SCENE.resource_path)
	_expect(
		int(prewarmed.get("created", -1)) == ELITE_BULLET_CAPACITY
		and int(prewarmed.get("inactive", -1)) == ELITE_BULLET_CAPACITY
		and int(prewarmed.get("retained_capacity", -1)) == ELITE_BULLET_CAPACITY
		and int(prewarmed.get("overflow", -1)) == 0,
		"皮箱之战精英弹丸池必须预热并保留480发，且初始无溢出。"
	)

	var first_leases: Array[Node] = []
	var first_lease_ids: Dictionary = {}
	for lease_index in range(ELITE_BULLET_CAPACITY):
		var lease := pool.acquire(ELITE_BULLET_SCENE)
		if lease == null:
			_failures.append("第一轮第%d个精英弹丸租约获取失败。" % lease_index)
			break
		first_leases.append(lease)
		first_lease_ids[lease.get_instance_id()] = true
	var first_peak := pool.get_metrics(ELITE_BULLET_SCENE.resource_path)
	_expect(
		first_leases.size() == ELITE_BULLET_CAPACITY
		and first_lease_ids.size() == ELITE_BULLET_CAPACITY
		and int(first_peak.get("created", -1)) == ELITE_BULLET_CAPACITY
		and int(first_peak.get("in_use", -1)) == ELITE_BULLET_CAPACITY
		and int(first_peak.get("peak_in_use", -1)) == ELITE_BULLET_CAPACITY
		and int(first_peak.get("overflow", -1)) == 0,
		"第一轮必须获得480个唯一租约且不触发弹丸池溢出。"
	)
	for lease in first_leases:
		_expect(pool.release(lease), "第一轮精英弹丸租约必须可正常归还。")
	await physics_frame
	await physics_frame
	var first_released := pool.get_metrics(ELITE_BULLET_SCENE.resource_path)
	_expect(
		int(first_released.get("created", -1)) == ELITE_BULLET_CAPACITY
		and int(first_released.get("in_use", -1)) == 0
		and int(first_released.get("inactive", -1)) == ELITE_BULLET_CAPACITY
		and int(first_released.get("pending_release", -1)) == 0
		and int(first_released.get("overflow", -1)) == 0,
		"第一轮回收后必须恰有480发处于inactive且无待处理租约。"
	)

	var second_leases: Array[Node] = []
	for lease_index in range(ELITE_BULLET_CAPACITY):
		var lease := pool.acquire(ELITE_BULLET_SCENE)
		if lease == null:
			_failures.append("第二轮第%d个精英弹丸租约获取失败。" % lease_index)
			break
		second_leases.append(lease)
	var second_peak := pool.get_metrics(ELITE_BULLET_SCENE.resource_path)
	_expect(
		second_leases.size() == ELITE_BULLET_CAPACITY
		and int(second_peak.get("created", -1)) == ELITE_BULLET_CAPACITY
		and int(second_peak.get("in_use", -1)) == ELITE_BULLET_CAPACITY
		and int(second_peak.get("overflow", -1)) == 0,
		"第二轮必须复用全部480发，不得创建新实例或增加溢出。"
	)
	for lease in second_leases:
		_expect(pool.release(lease), "第二轮精英弹丸租约必须可正常归还。")
	await physics_frame
	await physics_frame
	var second_released := pool.get_metrics(ELITE_BULLET_SCENE.resource_path)
	_expect(
		int(second_released.get("created", -1)) == ELITE_BULLET_CAPACITY
		and int(second_released.get("inactive", -1)) == ELITE_BULLET_CAPACITY
		and int(second_released.get("in_use", -1)) == 0
		and int(second_released.get("pending_release", -1)) == 0
		and int(second_released.get("overflow", -1)) == 0,
		"第二轮归还后必须保持480发inactive且累计溢出仍为0。"
	)
	pool.queue_free()
	await process_frame
	await process_frame


func _test_multiplayer_elite_bullet_proxy_stress() -> void:
	var runtime := StandardGame.new()
	var pool := SessionObjectPool.new()
	pool.name = "SessionObjectPool"
	runtime.add_child(pool)
	var gateway := MultiplayerGameplayGateway.new()
	gateway.name = "MultiplayerGameplayGateway"
	runtime.add_child(gateway)
	gateway.bind_runtime(runtime)
	CombatRuntimeBase.register_combat_robot_gunner_elite_bullet_pool(
		pool,
		ELITE_BULLET_CAPACITY,
		ELITE_BULLET_CAPACITY
	)
	var coordinator := MP_PROJECTILE_COORDINATOR_SCRIPT.new()
	coordinator.bind_runtime(runtime)
	var proxies: Array[CombatRobotGunnerBullet] = []
	var proxy_ids: Dictionary = {}
	for projectile_index in range(ELITE_BULLET_CAPACITY):
		var angle := TAU * float(projectile_index % 40) / 40.0
		var direction := Vector2.RIGHT.rotated(angle)
		var projectile := coordinator.instantiate_projectile(
			&"combat_robot_gunner_elite_bullet",
			1,
			direction,
			50,
			80.0,
			1.5,
			false,
			0,
			0
		) as CombatRobotGunnerBullet
		if projectile == null:
			_failures.append(
				"客户端第%d发精英紫弹代理实例化失败。" % projectile_index
			)
			break
		proxies.append(projectile)
		proxy_ids[projectile.get_instance_id()] = true
	var proxy_peak := pool.get_metrics(ELITE_BULLET_SCENE.resource_path)
	var valid_proxy_count := 0
	for projectile in proxies:
		if (
			projectile.authored_source_type
				== &"combat_robot_gunner_elite_bullet"
			and projectile.damage == 50
			and is_equal_approx(projectile.speed, 80.0)
			and is_equal_approx(projectile.remaining_lifetime, 1.5)
		):
			valid_proxy_count += 1
	_expect(
		proxies.size() == ELITE_BULLET_CAPACITY
		and proxy_ids.size() == ELITE_BULLET_CAPACITY
		and valid_proxy_count == ELITE_BULLET_CAPACITY
		and int(proxy_peak.get("in_use", -1)) == ELITE_BULLET_CAPACITY
		and int(proxy_peak.get("overflow", -1)) == 0,
		(
			"客户端多人投射物协调器必须能按同一Host合同建立480发唯一紫弹代理，"
			+ "且伤害、弹速、寿命与池容量均不漂移。"
		)
	)
	for projectile in proxies:
		_expect(pool.release(projectile), "多人紫弹代理必须能归还皮箱专用池。")
	await physics_frame
	pool.call("_process_pending_releases")
	var released := pool.get_metrics(ELITE_BULLET_SCENE.resource_path)
	_expect(
		int(released.get("in_use", -1)) == 0
		and int(released.get("inactive", -1)) == ELITE_BULLET_CAPACITY
		and int(released.get("pending_release", -1)) == 0,
		"480发客户端代理必须完整回收，不得残留同步租约。"
	)
	coordinator.unbind_runtime(runtime)
	coordinator.free()
	runtime.free()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
