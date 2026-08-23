extends SceneTree

const MpProjectileCoordinator := preload(
	"res://scene/multiplayer/projectile/mp_projectile_coordinator.gd"
)
const MP_GAME_SCENE := preload("res://scene/multiplayer/mp_game.tscn")
const ROGUE_COMBAT_SCENE := preload(
	"res://scene/game_modes/rogue/combat/rogue_combat_game_01.tscn"
)
const COMBAT_ROBOT_SCENE := preload(
	"res://scene/enemy/mechanical_life/combat_robot.tscn"
)
const COMBAT_ROBOT_CONFIG := preload(
	"res://resources/config/enemies/combat_robot.tres"
)
const COMBAT_ROBOT_GUNNER_SCENE := preload(
	"res://scene/enemy/mechanical_life/combat_robot_gunner.tscn"
)
const COMBAT_ROBOT_GUNNER_CONFIG := preload(
	"res://resources/config/enemies/combat_robot_gunner.tres"
)
const ROGUE_COMBAT_MUSIC := preload(
	"res://resources/audio/1-28 Journey of the Prairie King (The Outlaw).mp3"
)

const AUTHORITATIVE_SEED := 20_260_806
const CLIENT_PEER_ID := 2
const CLIENT_GUNNER_PROJECTILE_ID := 72_001
const CLIENT_DRONE_PROJECTILE_ID := 72_002
const COOLDOWN_EPSILON := 0.01


## Reproduces the production embedding boundary without granting network methods
## to SceneTree.current_scene. In production those methods belong to the nested
## MpGame/gateway, while current_scene is MpRogueRoute.
class EmbeddedRouteShell:
	extends Node2D


## Runs MpGame's real static coordinator scene without starting an ENet
## session. Only scene/session boot and teardown are suppressed; the tested
## projectile and player-life calls still cross their production coordinators.
class EmbeddedMpGameHarness:
	extends "res://scene/multiplayer/mp_game.gd"


	func _ready() -> void:
		pass


	func _exit_tree() -> void:
		pass


var failures: Array[String] = []
var run_state: RunStateStore = null


func _initialize() -> void:
	call_deferred(&"_run")


func _run() -> void:
	run_state = root.get_node_or_null("RunState") as RunStateStore
	_expect(run_state != null, "肉鸽真实战斗链路测试需要 RunState 自动加载。")
	if run_state == null:
		_finish()
		return

	run_state.begin_new_run(&"weishidaier", false)
	await _test_authoritative_real_combat_and_teardown()
	_expect(
		run_state.register_multiplayer_peer_state(CLIENT_PEER_ID),
		(
			"ClientView 夹具必须先模拟顶层会话为 peer 2 建立持久成长账本，"
			+ "内嵌战场不得自行补建认证成员。"
		)
	)
	await _test_embedded_client_view_damage_authority()
	_finish()


func _test_authoritative_real_combat_and_teardown() -> void:
	var route_shell := EmbeddedRouteShell.new()
	route_shell.name = "RogueRouteAuthoritativeShell"
	root.add_child(route_shell)
	current_scene = route_shell

	var coordinator := RogueCombatSingleplayerCoordinator.new()
	coordinator.name = "SingleplayerCombatCoordinator"
	route_shell.add_child(coordinator)
	var wave := _create_one_enemy_wave()
	var battle := await _create_battle(
		route_shell,
		wave,
		CombatRuntimeBase.RuntimeMode.SINGLEPLAYER,
		0
	)
	if battle == null:
		await _dispose_shell(route_shell)
		return

	var player := battle.player as AmmoRangedPlayer
	var gameplay_gateway := battle.get_multiplayer_gameplay_gateway()
	_expect(
		player != null
		and gameplay_gateway != null
		and gameplay_gateway.get_projectile_parent() == battle,
		(
			"单人肉鸽战场必须创建真实弹药型玩家，并把静态多人网关绑定到"
			+ "战场根节点。"
		)
	)
	if player == null:
		coordinator.active_battle = battle
		coordinator.call("_dispose_active_battle")
		await _dispose_shell(route_shell)
		return

	# Start the real wave path so the spawned enemy owns the production defeated
	# and tree_exited callbacks that drive final-wave settlement.
	battle.random_generator.seed = AUTHORITATIVE_SEED
	battle.navigation_prewarmed = true
	battle.call("_begin_flow_step", wave)
	battle.enemy_spawn_timer.stop()
	battle.combat_deadline_timer.stop()
	var enemy := _first_living_enemy(battle)
	_expect(
		enemy != null,
		(
			"单敌人肉鸽波次必须通过正式刷怪管线生成目标；"
			+ "built=%s spawn_points=%d active_points=%d total=%d spawned=%d pending=%d。"
		) % [
			bool(battle.grid_pathfinder.get("is_built")),
			battle.enemy_spawn_points.size(),
			battle.active_wave_spawn_points.size(),
			battle.current_wave_total,
			battle.current_wave_spawned,
			battle.pending_enemy_configs.size(),
		]
	)
	if enemy != null:
		enemy.set_physics_process(false)
		enemy.set_process(false)

	var outcomes: Array[Dictionary] = []
	battle.combat_outcome_started.connect(
		func(victory: bool, failure_reason: String) -> void:
			outcomes.append({
				"victory": victory,
				"failure_reason": failure_reason,
			})
	)

	var ammo_before := player.current_ammo
	player.shooting_timer.stop()
	if enemy != null:
		# A one-health target still resolves armor and minimum damage through the
		# production DamageResolver; no test-only damage shortcut is used.
		enemy.current_health = 1
	player.call("_try_shoot", Vector2.RIGHT)
	var player_bullet := _find_active_player_bullet(route_shell, player)
	_expect(
		player_bullet != null
		and player.current_ammo == ammo_before - 1,
		"真实玩家开火必须消耗一发弹药并生成一枚由该玩家拥有的 Bullet。"
	)
	if player_bullet != null and enemy != null:
		var hit_accepted := player_bullet.try_hit_enemy(enemy)
		_expect(
			hit_accepted
			and enemy.is_dead
			and enemy.current_health <= 0
			and battle.current_wave_defeated == 1,
			"Bullet 命中必须经过 Enemy 伤害/死亡信号并累计最后一名敌人。"
		)
		# Complete the authored death lifecycle deterministically instead of waiting
		# on animation wall time; tree_exited remains the production completion gate.
		enemy.call("_finish_after_death_animation")
		await process_frame
		await process_frame
		_expect(
			battle.wave_state == CombatFlowState.State.VICTORY
			and outcomes.size() == 1
			and bool(outcomes[0].get("victory", false))
			and str(outcomes[0].get("failure_reason", "")).is_empty(),
			"末敌退出树后必须且只能触发一次肉鸽胜利结算。"
		)

	await _test_real_gunner_projectile_damage(route_shell, battle, player)
	await _test_contact_damage_cooldown(battle, player)

	# Leave one real player projectile in flight, then execute the coordinator's
	# production battle disposal. The outer route must survive without any lease.
	player.shooting_timer.stop()
	player.set_combat_actions_locked(false)
	var lingering_spawned := bool(player.call("_spawn_bullet", Vector2.UP))
	var lingering_bullet := _find_active_player_bullet(route_shell, player)
	_expect(
		lingering_spawned and lingering_bullet != null,
		"释放测试必须先创建一枚仍在飞行的真实玩家弹体。"
	)
	coordinator.active_battle = battle
	coordinator.call("_dispose_active_battle")
	await process_frame
	await physics_frame
	var remaining_projectiles := _collect_projectiles(route_shell)
	_expect(
		remaining_projectiles.is_empty(),
		(
			"战场 teardown 后路线树下不得残留弹体；实际残留：%s。"
			% [_describe_nodes(remaining_projectiles)]
		)
	)
	for projectile in remaining_projectiles:
		if projectile != null and is_instance_valid(projectile):
			projectile.queue_free()
	await _dispose_shell(route_shell)


func _test_real_gunner_projectile_damage(
	_route_shell: Node,
	battle: RogueCombatGame,
	player: AmmoRangedPlayer
) -> void:
	_reset_player_for_damage_test(player)
	_expect(
		CombatRobotGunner.projectile_backend
		== CombatRobotGunner.ProjectileBackend.DATA,
		"持枪战斗机器人正式链路必须使用DATA权威弹体。"
	)
	var combat_services := battle.get_enemy_combat_services()
	var rapid_fire_service := (
		combat_services.get_rapid_fire_simulation_service()
		if combat_services != null
		else null
	) as RapidFireSimulationService
	_expect(rapid_fire_service != null, "真实战场必须提供共享连发弹体服务。")
	if rapid_fire_service == null:
		return
	var gunner := (
		COMBAT_ROBOT_GUNNER_SCENE.instantiate() as CombatRobotGunner
	)
	_expect(gunner != null, "持枪战斗机器人场景必须能实例化。")
	if gunner == null:
		return
	battle.enemy_container.add_child(gunner)
	gunner.global_position = player.global_position + Vector2.LEFT * 40.0
	gunner.setup(
		COMBAT_ROBOT_GUNNER_CONFIG,
		player,
		battle.grid_pathfinder,
		battle
	)
	gunner.random_generator.seed = AUTHORITATIVE_SEED
	gunner.set_physics_process(false)
	var health_before := player.current_health
	var expected_damage := gunner.get_effective_attack_damage(
		COMBAT_ROBOT_GUNNER_CONFIG.attack_damage
	)
	var burst_started := bool(gunner.call("_try_start_burst", player))
	gunner.call("_update_burst", 0.0)
	var data_handle := _find_gunner_data_handle(
		rapid_fire_service,
		int(gunner.get_instance_id())
	)
	_expect(
		burst_started
		and data_handle > RapidFireSimulationService.INVALID_HANDLE
		and _find_active_gunner_bullet(battle) == null,
		"持枪战斗机器人必须通过真实burst管线生成DATA句柄且不创建权威Node。"
	)
	for _physics_index in range(90):
		if player.current_health < health_before:
			break
		await physics_frame
	_expect(
		health_before - player.current_health == expected_damage
		and not rapid_fire_service.is_handle_live(data_handle),
		"真实机器人DATA枪弹必须命中玩家、结算权威伤害并回收句柄。"
	)
	gunner.queue_free()
	await process_frame


func _test_contact_damage_cooldown(
	battle: RogueCombatGame,
	player: AmmoRangedPlayer
) -> void:
	_reset_player_for_damage_test(player)
	player.physical_defense = maxi(COMBAT_ROBOT_CONFIG.attack_damage - 1, 0)
	var robot := COMBAT_ROBOT_SCENE.instantiate() as CombatRobot
	_expect(robot != null, "基础战斗机器人场景必须能实例化。")
	if robot == null:
		return
	battle.enemy_container.add_child(robot)
	robot.global_position = player.global_position
	robot.setup(COMBAT_ROBOT_CONFIG, player, battle.grid_pathfinder, battle)
	robot.set_physics_process(false)
	robot.add_outgoing_attack_damage_multiplier_modifier(
		91_001,
		1.0 / float(COMBAT_ROBOT_CONFIG.attack_damage)
	)
	robot.touching_players[player.get_instance_id()] = player
	robot.touched_player = player

	var damage_per_touch := robot.get_effective_attack_damage(
		COMBAT_ROBOT_CONFIG.attack_damage
	)
	var health_before := player.current_health
	robot.call("_try_deal_touch_damage")
	var health_after_first := player.current_health
	robot.call("_try_deal_touch_damage")
	var health_after_immediate_retry := player.current_health
	robot.call(
		"_update_touch_damage_unprofiled",
		maxf(robot.touch_damage_interval - COOLDOWN_EPSILON, 0.0)
	)
	var health_before_expiry := player.current_health
	robot.call("_update_touch_damage_unprofiled", COOLDOWN_EPSILON * 2.0)
	_expect(
		health_before - health_after_first == damage_per_touch
		and health_after_immediate_retry == health_after_first
		and health_before_expiry == health_after_first
		and health_before_expiry - player.current_health == damage_per_touch
		and robot.touch_damage_cooldown_left > 0.0,
		"接触伤害必须立即命中一次、冷却内拒绝重复命中，并在到期后只命中一次。"
	)
	robot.queue_free()
	await process_frame


func _test_embedded_client_view_damage_authority() -> void:
	var route_shell := EmbeddedRouteShell.new()
	route_shell.name = "MpRogueRouteClientShell"
	root.add_child(route_shell)
	current_scene = route_shell

	var mp_game_node := MP_GAME_SCENE.instantiate()
	mp_game_node.set_script(EmbeddedMpGameHarness)
	var mp_game := mp_game_node as EmbeddedMpGameHarness
	_expect(mp_game != null, "ClientView 测试必须实例化真实 MpGame 静态协调器场景。")
	if mp_game == null:
		mp_game_node.free()
		await _dispose_shell(route_shell)
		return
	mp_game.name = "EmbeddedCombatRuntime"
	route_shell.add_child(mp_game)
	var net_manager := root.get_node("NetManager") as NetManagerStore
	var session_coordinator := mp_game.get_node(
		"SessionCoordinator"
	) as MpSessionCoordinator
	var player_coordinator := mp_game.get_node(
		"PlayerCoordinator"
	) as MpPlayerCoordinator
	var projectile_coordinator := mp_game.get_node(
		"ProjectileCoordinator"
	) as MpProjectileCoordinator
	_expect(
		net_manager != null
		and session_coordinator != null
		and player_coordinator != null
		and projectile_coordinator != null,
		"真实 MpGame 场景必须提供会话、玩家与弹体协调器。"
	)
	if (
		net_manager == null
		or session_coordinator == null
		or player_coordinator == null
		or projectile_coordinator == null
	):
		await _dispose_shell(route_shell)
		return
	session_coordinator.bind_transport_dependencies(net_manager)
	var wave := _create_one_enemy_wave()
	var battle := await _create_battle(
		mp_game,
		wave,
		CombatRuntimeBase.RuntimeMode.CLIENT_VIEW,
		CLIENT_PEER_ID
	)
	if battle == null:
		session_coordinator.unbind_transport_dependencies()
		await _dispose_shell(route_shell)
		return
	mp_game.game = battle
	mp_game._gameplay_gateway = battle.get_multiplayer_gameplay_gateway()
	mp_game._mode_adapter = battle.get_multiplayer_mode_adapter()
	session_coordinator.bind_runtime(battle)
	player_coordinator.bind_runtime(battle)
	player_coordinator.bind_realtime_dependencies(
		net_manager,
		session_coordinator
	)
	projectile_coordinator.bind_runtime(battle)
	projectile_coordinator.bind_network_facade_dependencies(
		net_manager,
		player_coordinator,
		Callable(mp_game, "_get_net_time"),
		Callable(mp_game, "_get_unbounded_host_event_age"),
		Callable(mp_game, "_is_embedded_participant_suspended")
	)
	player_coordinator.bind_life_dependencies(
		net_manager,
		mp_game._mode_adapter,
		projectile_coordinator,
		Callable(mp_game, "_get_net_time"),
		Callable(mp_game, "_cancel_player_life_tango_for_revive_schedule"),
		Callable(mp_game, "_cancel_player_life_actions_for_revive"),
		Callable(mp_game, "_clear_player_life_tiyi_lifecycle_state"),
		Callable(mp_game, "_get_player_life_revive_anchor_position"),
		Callable(mp_game, "_commit_player_life_revive_position")
	)
	var gameplay_gateway := battle.get_multiplayer_gameplay_gateway()
	_expect(
		gameplay_gateway != null,
		"ClientView 肉鸽战场必须提供静态 MultiplayerGameplayGateway 子节点。"
	)
	if gameplay_gateway != null:
		gameplay_gateway.attach_multiplayer_session(mp_game)
	if mp_game._mode_adapter != null:
		mp_game._mode_adapter.attach_multiplayer_session(mp_game)
	_expect(
		player_coordinator.has_life_dependencies()
		and projectile_coordinator.has_network_facade_dependencies(),
		"ClientView 伤害链必须由玩家生命协调器与弹体网络门面共同持有依赖。"
	)
	var player := battle.get_player_for_peer(CLIENT_PEER_ID) as Player
	_expect(player != null, "ClientView 肉鸽战场必须创建本地玩家视图。")
	if player == null:
		mp_game.game = null
		await _dispose_shell(route_shell)
		return
	battle.process_mode = Node.PROCESS_MODE_DISABLED
	_reset_player_for_damage_test(player)

	var previous_net_role := net_manager.net_role
	# A direct local call has sender id 0. The coordinator accepts that identity
	# only for Host-side loopback, matching the authority RPC's production source.
	net_manager.net_role = NetManagerStore.NetRole.HOST
	mp_game.net_projectile_fired(
		CLIENT_GUNNER_PROJECTILE_ID,
		"combat_robot_gunner_bullet",
		0,
		player.global_position,
		Vector2.RIGHT,
		COMBAT_ROBOT_GUNNER_CONFIG.attack_damage,
		COMBAT_ROBOT_GUNNER_CONFIG.projectile_speed,
		COMBAT_ROBOT_GUNNER_CONFIG.projectile_lifetime,
		false,
		CLIENT_PEER_ID,
		-1.0,
		0,
		CombatRelationService.HOSTILE_WAVE,
		0,
		0,
		CLIENT_GUNNER_PROJECTILE_ID,
		"combat_robot_gunner_bullet"
	)
	net_manager.net_role = previous_net_role
	var gunner_bullet := (
		projectile_coordinator.get_projectile(CLIENT_GUNNER_PROJECTILE_ID)
		as CombatRobotGunnerBullet
	)
	_expect(
		gunner_bullet != null,
		"MpGame 必须通过真实复制弹体工厂创建机器人枪弹。"
	)
	if gunner_bullet != null:
		gunner_bullet.set_physics_process(false)
		var health_before := player.current_health
		net_manager.net_role = NetManagerStore.NetRole.CLIENT
		gunner_bullet.call("_on_body_entered", player)
		net_manager.net_role = previous_net_role
		_expect(
			player.current_health == health_before
			and gunner_bullet.has_hit,
			(
				"ClientView 枪弹接触必须经真实玩家生命协调器消费且不能本地扣血；"
				+ "health %d -> %d，consumed=%s。"
			) % [
				health_before,
				player.current_health,
				gunner_bullet.has_hit,
			]
		)

	_reset_player_for_damage_test(player)
	net_manager.net_role = NetManagerStore.NetRole.HOST
	mp_game.net_projectile_fired(
		CLIENT_DRONE_PROJECTILE_ID,
		"combat_robot_suicide_drone",
		0,
		player.global_position,
		Vector2.RIGHT,
		CombatRobotSuicideDrone.DEFAULT_DAMAGE,
		CombatRobotSuicideDrone.DEFAULT_SPEED,
		0.0,
		false,
		CLIENT_PEER_ID,
		-1.0,
		0,
		CombatRelationService.HOSTILE_WAVE,
		0,
		0,
		CLIENT_DRONE_PROJECTILE_ID,
		"combat_robot_suicide_drone"
	)
	net_manager.net_role = previous_net_role
	var drone := (
		projectile_coordinator.get_projectile(CLIENT_DRONE_PROJECTILE_ID)
		as CombatRobotSuicideDrone
	)
	_expect(drone != null, "MpGame 必须通过真实复制弹体工厂创建自爆无人机。")
	if drone != null:
		await physics_frame
		await physics_frame
		var health_before := player.current_health
		var recognized_client_view := bool(
			drone.call("_is_client_view_runtime")
		)
		drone.simulate_compensated_motion(
			CombatRobotSuicideDrone.DEPLOY_DELAY
		)
		_expect(
			recognized_client_view
			and drone.explosion_started
			and player.current_health == health_before,
			(
				"ClientView 自爆无人机必须识别嵌套运行时并保持纯表现；"
				+ "client_view=%s，exploded=%s，health %d -> %d。"
			) % [
				recognized_client_view,
				drone.explosion_started,
				health_before,
				player.current_health,
			]
		)

	if gameplay_gateway != null:
		gameplay_gateway.detach_multiplayer_session(mp_game)
	if mp_game._mode_adapter != null:
		mp_game._mode_adapter.detach_multiplayer_session(mp_game)
	player_coordinator.unbind_runtime(battle)
	projectile_coordinator.unbind_runtime(battle)
	session_coordinator.unbind_runtime(battle)
	session_coordinator.unbind_transport_dependencies()
	mp_game._gameplay_gateway = null
	mp_game._mode_adapter = null
	mp_game.game = null
	await _dispose_shell(route_shell)


func _create_battle(
	parent: Node,
	wave: WaveConfig,
	runtime_mode: CombatRuntimeBase.RuntimeMode,
	local_peer_id: int
) -> RogueCombatGame:
	var battle := ROGUE_COMBAT_SCENE.instantiate() as RogueCombatGame
	_expect(battle != null, "肉鸽作战场景必须能实例化。")
	if battle == null:
		return null
	var campaign := _create_campaign(wave)
	battle.singleplayer_campaign = campaign
	battle.multiplayer_campaign = campaign
	battle.auto_start_waves = false
	battle.runtime_mode = runtime_mode
	if runtime_mode == CombatRuntimeBase.RuntimeMode.CLIENT_VIEW:
		battle.configure_multiplayer(
			runtime_mode,
			local_peer_id,
			{local_peer_id: "Client"},
			{local_peer_id: &"weishidaier"}
		)
	var music_player := battle.get_node_or_null("MusicPlayer") as AudioStreamPlayer
	if music_player != null:
		music_player.autoplay = false
	parent.add_child(battle)
	await process_frame
	if not is_instance_valid(battle) or battle.player == null:
		_expect(false, "肉鸽作战场景 ready 后必须拥有可用玩家。")
		if is_instance_valid(battle):
			battle.free()
		return null
	return battle


func _create_one_enemy_wave() -> WaveConfig:
	var entry := WaveEnemyEntry.new()
	entry.enemy_config = COMBAT_ROBOT_CONFIG
	entry.count = 1

	var wave := WaveConfig.new()
	wave.step_id = &"rogue_real_chain_wave"
	wave.wave_name = "真实链路测试"
	wave.enemy_entries = [entry]
	wave.spawn_point_mask = (
		RogueCombatEncounterConfig.REQUIRED_SCENE_SPAWN_POINT_MASK
	)
	wave.spawn_interval = 60.0
	wave.spawn_count_per_tick = 1
	wave.max_alive_enemies = 1
	wave.music = ROGUE_COMBAT_MUSIC
	return wave


func _create_campaign(wave: WaveConfig) -> WaveCampaignConfig:
	var graph := FlowGraphConfig.new()
	graph.graph_name = "Rogue Embedded Real Combat Chain"
	graph.steps = [wave]
	graph.start_step = wave

	var campaign := WaveCampaignConfig.new()
	campaign.campaign_id = &"rogue_embedded_real_chain"
	campaign.flow_graph = graph
	return campaign


func _first_living_enemy(battle: RogueCombatGame) -> Enemy:
	for child in battle.enemy_container.get_children():
		var enemy := child as Enemy
		if enemy != null and not enemy.is_dead:
			return enemy
	return null


func _find_active_player_bullet(root_node: Node, owner: Player) -> Bullet:
	for node in _collect_descendants(root_node):
		var bullet := node as Bullet
		if (
			bullet != null
			and bullet.pool_active
			and not bullet.is_queued_for_deletion()
			and bullet.collectible_owner == owner
		):
			return bullet
	return null


func _find_active_gunner_bullet(root_node: Node) -> CombatRobotGunnerBullet:
	for node in _collect_descendants(root_node):
		var bullet := node as CombatRobotGunnerBullet
		if (
			bullet != null
			and bullet.pool_active
			and not bullet.has_hit
			and not bullet.is_queued_for_deletion()
		):
			return bullet
	return null


func _find_gunner_data_handle(
	rapid_fire_service: RapidFireSimulationService,
	source_enemy_id: int
) -> int:
	for stable_index in range(rapid_fire_service.get_dense_record_count()):
		var handle := rapid_fire_service.get_handle_at_stable_index(stable_index)
		if (
			handle > RapidFireSimulationService.INVALID_HANDLE
			and rapid_fire_service.get_slot_mode(handle)
			== RapidFireSimulationService.Mode.DATA
			and rapid_fire_service.get_slot_profile(handle)
			== RapidFireSimulationService.Profile.GUNNER
			and rapid_fire_service.get_source_enemy_id(handle) == source_enemy_id
		):
			return handle
	return RapidFireSimulationService.INVALID_HANDLE


func _collect_projectiles(root_node: Node) -> Array[Node]:
	var result: Array[Node] = []
	for node in _collect_descendants(root_node):
		var is_projectile := (
			node is Bullet
			or node is CapooAK47Bullet
			or node is CombatRobotSuicideDrone
		)
		if is_projectile and not node.is_queued_for_deletion():
			result.append(node)
	return result


func _collect_descendants(root_node: Node) -> Array[Node]:
	var result: Array[Node] = []
	var pending: Array[Node] = [root_node]
	while not pending.is_empty():
		var parent := pending.pop_back() as Node
		for child in parent.get_children():
			var child_node := child as Node
			result.append(child_node)
			pending.append(child_node)
	return result


func _describe_nodes(nodes: Array[Node]) -> PackedStringArray:
	var descriptions := PackedStringArray()
	for node in nodes:
		if node == null or not is_instance_valid(node):
			continue
		descriptions.append("%s:%s" % [node.get_path(), node.get_class()])
	return descriptions


func _reset_player_for_damage_test(player: Player) -> void:
	player.is_dead = false
	player.current_health = maxi(player.max_health, 1)
	player.physical_defense = 0
	player.magic_defense = 0
	player.invincibility_duration = 0.0
	player.invincibility_time_left = 0.0
	player.dodge_chance = 0.0
	player.health_bar.setup(player.max_health, player.current_health)


func _dispose_shell(route_shell: Node) -> void:
	if current_scene == route_shell:
		current_scene = null
	if route_shell != null and is_instance_valid(route_shell):
		route_shell.queue_free()
	await process_frame
	await process_frame


func _expect(condition: bool, message: String) -> void:
	if condition:
		return
	failures.append(message)
	push_error(message)


func _finish() -> void:
	if failures.is_empty():
		print("ROGUE_EMBEDDED_COMBAT_REAL_CHAIN_SMOKE_TEST_OK")
		quit(0)
		return
	print(
		"ROGUE_EMBEDDED_COMBAT_REAL_CHAIN_SMOKE_TEST_FAILED count=%d"
		% failures.size()
	)
	for failure in failures:
		print(" - %s" % failure)
	quit(1)
