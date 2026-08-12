extends SceneTree

const PLAYER_SCENE := preload(
	"res://scene/player/weishidaier/player_weishidaier.tscn"
)
const RUNTIME_SCENE := preload(
	"res://dev_tools/fixtures/enemy_gameplay_gateway_test_runtime.tscn"
)
const MpPlayerCoordinatorScript := preload(
	"res://scene/multiplayer/player/mp_player_coordinator.gd"
)
const MpProjectileCoordinatorScript := preload(
	"res://scene/multiplayer/projectile/mp_projectile_coordinator.gd"
)

const TEST_PEER_ID := 71
const TEST_HEALTH := 2000

var failures: Array[String] = []
var runtime: EnemyGameplayGatewayTestRuntime = null
var coordinator: MpPlayerCoordinator = null
var projectile_coordinator: MpProjectileCoordinator = null
var net_manager: NetManagerStore = null
var previous_net_role := 0
var life_rpc_count := 0
var last_life_rpc_method: StringName = &""
var last_life_rpc_arguments: Array = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	runtime = RUNTIME_SCENE.instantiate() as EnemyGameplayGatewayTestRuntime
	root.add_child(runtime)
	current_scene = runtime
	runtime.runtime_mode = CombatRuntimeBase.RuntimeMode.CLIENT_VIEW

	coordinator = MpPlayerCoordinatorScript.new() as MpPlayerCoordinator
	coordinator.name = "MainBattlePlayerCoordinator"
	runtime.add_child(coordinator)
	projectile_coordinator = (
		MpProjectileCoordinatorScript.new() as MpProjectileCoordinator
	)
	projectile_coordinator.name = "MainBattleProjectileCoordinator"
	runtime.add_child(projectile_coordinator)

	net_manager = root.get_node("NetManager") as NetManagerStore
	previous_net_role = int(net_manager.net_role)
	coordinator.bind_runtime(runtime)
	coordinator.bind_life_dependencies(
		net_manager,
		runtime.get_node("MultiplayerModeAdapter") as MultiplayerModeAdapter,
		projectile_coordinator,
		Callable(self, "_get_test_net_time"),
		Callable(self, "_noop_peer"),
		Callable(self, "_noop_peer"),
		Callable(self, "_noop_peer"),
		Callable(self, "_get_revive_anchor"),
		Callable(self, "_commit_revive_position")
	)
	coordinator.life_rpc_broadcast_requested.connect(_on_life_rpc_requested)
	root.get_node("BurnStatusScheduler").call("clear_all")
	root.get_node("PlayerTimedMoveSlowScheduler").call("clear_all")

	var player := _spawn_player(TEST_PEER_ID)
	_test_client_direct_sink_fails_closed(player)
	_test_host_confirmed_main_battle_statuses(player)
	_test_client_cross_channel_status_confirmation_ordering(player)

	root.get_node("BurnStatusScheduler").call("clear_all")
	root.get_node("PlayerTimedMoveSlowScheduler").call("clear_all")
	runtime.peer_players.clear()
	player.queue_free()
	coordinator.unbind_runtime(runtime)
	net_manager.net_role = previous_net_role as NetManagerStore.NetRole
	runtime.queue_free()
	await process_frame
	await physics_frame
	for _cleanup_frame in range(3):
		await process_frame

	if failures.is_empty():
		print("COMBAT_ROBOT_MAIN_BATTLE_ELITE_NETWORK_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_client_direct_sink_fails_closed(player: Player) -> void:
	net_manager.net_role = NetManagerStore.NetRole.CLIENT
	runtime.runtime_mode = CombatRuntimeBase.RuntimeMode.CLIENT_VIEW
	var burn_scheduler := root.get_node("BurnStatusScheduler")
	var slow_scheduler := root.get_node("PlayerTimedMoveSlowScheduler")
	var health_before := player.current_health
	life_rpc_count = 0
	var result := coordinator.apply_player_hit_report(
		71001,
		player.peer_id,
		120,
		CombatAttackRegistry.COMBAT_ROBOT_MAIN_BATTLE_SKILL2,
		Vector2.LEFT,
		EnemyConfig.DamageType.PHYSICAL,
		0
	)
	_expect(
		result.is_rejected_for(
			CombatTypes.DamageRejectionReason.NOT_AUTHORITY
		)
		and player.current_health == health_before
		and not bool(burn_scheduler.call(
			"has_burn",
			player,
			CombatAttackRegistry.COMBAT_ROBOT_MAIN_BATTLE_BURN_FAMILY
		))
		and not bool(slow_scheduler.call(
			"has_slow",
			player,
			CombatAttackRegistry.COMBAT_ROBOT_MAIN_BATTLE_SLOW_FAMILY
		))
		and life_rpc_count == 0,
		"CLIENT_VIEW direct access to the Host hit sink must reject NOT_AUTHORITY without health, burn, slow, or RPC side effects."
	)


func _test_host_confirmed_main_battle_statuses(player: Player) -> void:
	net_manager.net_role = NetManagerStore.NetRole.HOST
	runtime.runtime_mode = CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY
	player.invincibility_time_left = 0.0
	life_rpc_count = 0
	var skill1_result := coordinator.apply_player_hit_report(
		71002,
		player.peer_id,
		96,
		CombatAttackRegistry.COMBAT_ROBOT_MAIN_BATTLE_SKILL1,
		Vector2.RIGHT,
		EnemyConfig.DamageType.PHYSICAL,
		0
	)
	var burn_scheduler := root.get_node("BurnStatusScheduler")
	var burn_snapshot := burn_scheduler.call(
		"get_source_snapshot",
		player,
		CombatAttackRegistry.COMBAT_ROBOT_MAIN_BATTLE_BURN_FAMILY
	) as Dictionary
	_expect(
		skill1_result.accepted
		and skill1_result.applied_damage == 96
		and int(burn_snapshot.get("tick_damage", 0)) == 5
		and is_equal_approx(float(burn_snapshot.get("time_left", 0.0)), 5.0)
		and life_rpc_count == 1
		and last_life_rpc_method == &"net_player_damage_applied"
		and last_life_rpc_arguments.size() == 11
		and int(last_life_rpc_arguments[10])
			== MpPlayerCoordinator.CONFIRMED_STATUS_MAIN_BATTLE_BURN,
		"Host-confirmed skill1 must deal 96, apply the shared five-second level-5 burn, and use the existing damage confirmation RPC."
	)

	player.invincibility_time_left = 0.0
	var health_before := player.current_health
	var skill2_result := coordinator.apply_player_hit_report(
		71003,
		player.peer_id,
		120,
		CombatAttackRegistry.COMBAT_ROBOT_MAIN_BATTLE_SKILL2,
		Vector2.RIGHT,
		EnemyConfig.DamageType.PHYSICAL,
		0
	)
	var refreshed_burn := burn_scheduler.call(
		"get_source_snapshot",
		player,
		CombatAttackRegistry.COMBAT_ROBOT_MAIN_BATTLE_BURN_FAMILY
	) as Dictionary
	var slow_snapshot := root.get_node(
		"PlayerTimedMoveSlowScheduler"
	).call(
		"get_source_snapshot",
		player,
		CombatAttackRegistry.COMBAT_ROBOT_MAIN_BATTLE_SLOW_FAMILY
	) as Dictionary
	_expect(
		skill2_result.accepted
		and player.current_health == health_before - 120
		and int(refreshed_burn.get("tick_damage", 0)) == 5
		and is_equal_approx(float(refreshed_burn.get("time_left", 0.0)), 5.0)
		and is_equal_approx(float(slow_snapshot.get("time_left", 0.0)), 1.0)
		and is_equal_approx(float(slow_snapshot.get("multiplier", 1.0)), 0.75)
		and life_rpc_count == 2
		and last_life_rpc_arguments.size() == 11
		and int(last_life_rpc_arguments[10])
			== (
				MpPlayerCoordinator.CONFIRMED_STATUS_MAIN_BATTLE_BURN
				| MpPlayerCoordinator.CONFIRMED_STATUS_MAIN_BATTLE_SLOW
			),
		"Host-confirmed skill2 must deal 120, refresh the shared burn, apply one 1s/0.75 slow, and remain on the existing confirmation payload."
	)

	root.get_node("BurnStatusScheduler").call("clear_target", player)
	root.get_node("PlayerTimedMoveSlowScheduler").call("clear_target", player)
	net_manager.net_role = NetManagerStore.NetRole.CLIENT
	runtime.runtime_mode = CombatRuntimeBase.RuntimeMode.CLIENT_VIEW
	player.invincibility_time_left = 0.0
	health_before = player.current_health
	coordinator.apply_player_damage_confirmation(
		player.peer_id,
		health_before - 12,
		false,
		3,
		12,
		Vector2.LEFT,
		int(EnemyConfig.DamageType.PHYSICAL),
		true,
		false,
		CombatTypes.DamageRejectionReason.NONE,
		(
			MpPlayerCoordinator.CONFIRMED_STATUS_MAIN_BATTLE_BURN
			| MpPlayerCoordinator.CONFIRMED_STATUS_MAIN_BATTLE_SLOW
		)
	)
	var client_burn_active := bool(root.get_node(
		"BurnStatusScheduler"
	).call(
		"has_burn",
		player,
		CombatAttackRegistry.COMBAT_ROBOT_MAIN_BATTLE_BURN_FAMILY
	))
	var client_slow_active := bool(root.get_node(
		"PlayerTimedMoveSlowScheduler"
	).call(
		"has_slow",
		player,
		CombatAttackRegistry.COMBAT_ROBOT_MAIN_BATTLE_SLOW_FAMILY
	))
	_expect(
		player.current_health == health_before - 12
		and client_burn_active
		and client_slow_active
		and float(player.get("_burn_overlay_strength")) > 0.0
		and is_equal_approx(player.timed_move_slow_multiplier, 0.75),
		"The v62 client confirmation mask must reconstruct burn presentation and immediate slow prediction without a new RPC or wire attack id."
	)
	var health_after_confirmation := player.current_health
	root.get_node("BurnStatusScheduler").call("_advance_active_burns", 1.01)
	root.get_node("PlayerTimedMoveSlowScheduler").call(
		"_advance_active_slows",
		1.01
	)
	_expect(
		player.current_health == health_after_confirmation
		and bool(root.get_node("BurnStatusScheduler").call(
			"has_burn",
			player,
			CombatAttackRegistry.COMBAT_ROBOT_MAIN_BATTLE_BURN_FAMILY
		))
		and not bool(root.get_node("PlayerTimedMoveSlowScheduler").call(
			"has_slow",
			player,
			CombatAttackRegistry.COMBAT_ROBOT_MAIN_BATTLE_SLOW_FAMILY
		))
		and is_equal_approx(player.timed_move_slow_multiplier, 1.0),
		"Client burn presentation ticks must remain non-authoritative while the one-second slow restores locally."
	)


func _test_client_cross_channel_status_confirmation_ordering(
	player: Player
) -> void:
	net_manager.net_role = NetManagerStore.NetRole.CLIENT
	runtime.runtime_mode = CombatRuntimeBase.RuntimeMode.CLIENT_VIEW
	var burn_scheduler := root.get_node("BurnStatusScheduler")
	var slow_scheduler := root.get_node("PlayerTimedMoveSlowScheduler")
	burn_scheduler.call("clear_target", player)
	slow_scheduler.call("clear_target", player)

	# Model CH2 snapshot revision 5 arriving before the first CH5 reliable
	# confirmation at revision 4. The snapshot life value must win, while the
	# reliable event still owns its one-shot status acknowledgements.
	var authoritative_health := player.current_health
	coordinator.set_applied_health_revision(player.peer_id, 5)
	coordinator.apply_player_damage_confirmation(
		player.peer_id,
		authoritative_health - 37,
		false,
		4,
		37,
		Vector2.LEFT,
		int(EnemyConfig.DamageType.PHYSICAL),
		true,
		false,
		CombatTypes.DamageRejectionReason.NONE,
		(
			MpPlayerCoordinator.CONFIRMED_STATUS_MAIN_BATTLE_BURN
			| MpPlayerCoordinator.CONFIRMED_STATUS_MAIN_BATTLE_SLOW
		)
	)
	_expect(
		player.current_health == authoritative_health
		and coordinator.get_applied_health_revision(player.peer_id) == 5
		and bool(burn_scheduler.call(
			"has_burn",
			player,
			CombatAttackRegistry.COMBAT_ROBOT_MAIN_BATTLE_BURN_FAMILY
		))
		and bool(slow_scheduler.call(
			"has_slow",
			player,
			CombatAttackRegistry.COMBAT_ROBOT_MAIN_BATTLE_SLOW_FAMILY
		)),
		"A newer CH2 health snapshot must prevent rollback without swallowing the first older CH5 burn/slow confirmation."
	)

	# Reliable confirmation revision is the exactly-once boundary. Replaying the
	# same revision after clocks advance must not refresh either duration.
	burn_scheduler.call("_advance_active_burns", 0.25)
	slow_scheduler.call("_advance_active_slows", 0.25)
	var burn_before_duplicate := burn_scheduler.call(
		"get_source_snapshot",
		player,
		CombatAttackRegistry.COMBAT_ROBOT_MAIN_BATTLE_BURN_FAMILY
	) as Dictionary
	var slow_before_duplicate := slow_scheduler.call(
		"get_source_snapshot",
		player,
		CombatAttackRegistry.COMBAT_ROBOT_MAIN_BATTLE_SLOW_FAMILY
	) as Dictionary
	coordinator.apply_player_damage_confirmation(
		player.peer_id,
		authoritative_health - 37,
		false,
		4,
		37,
		Vector2.LEFT,
		int(EnemyConfig.DamageType.PHYSICAL),
		true,
		false,
		CombatTypes.DamageRejectionReason.NONE,
		(
			MpPlayerCoordinator.CONFIRMED_STATUS_MAIN_BATTLE_BURN
			| MpPlayerCoordinator.CONFIRMED_STATUS_MAIN_BATTLE_SLOW
		)
	)
	var burn_after_duplicate := burn_scheduler.call(
		"get_source_snapshot",
		player,
		CombatAttackRegistry.COMBAT_ROBOT_MAIN_BATTLE_BURN_FAMILY
	) as Dictionary
	var slow_after_duplicate := slow_scheduler.call(
		"get_source_snapshot",
		player,
		CombatAttackRegistry.COMBAT_ROBOT_MAIN_BATTLE_SLOW_FAMILY
	) as Dictionary
	_expect(
		player.current_health == authoritative_health
		and not burn_before_duplicate.is_empty()
		and not slow_before_duplicate.is_empty()
		and float(burn_after_duplicate.get("time_left", 0.0))
			<= float(burn_before_duplicate.get("time_left", 0.0)) + 0.001
		and float(slow_after_duplicate.get("time_left", 0.0))
			<= float(slow_before_duplicate.get("time_left", 0.0)) + 0.001,
		"A duplicate reliable confirmation revision must neither roll back health nor refresh burn/slow durations."
	)

	# A terminal confirmation may carry a non-zero mask on the wire, but dead
	# players must never acquire or retain either status.
	burn_scheduler.call("clear_target", player)
	slow_scheduler.call("clear_target", player)
	coordinator.apply_player_damage_confirmation(
		player.peer_id,
		0,
		true,
		6,
		authoritative_health,
		Vector2.LEFT,
		int(EnemyConfig.DamageType.PHYSICAL),
		false,
		false,
		CombatTypes.DamageRejectionReason.NONE,
		(
			MpPlayerCoordinator.CONFIRMED_STATUS_MAIN_BATTLE_BURN
			| MpPlayerCoordinator.CONFIRMED_STATUS_MAIN_BATTLE_SLOW
		)
	)
	_expect(
		player.is_dead
		and player.current_health == 0
		and not bool(burn_scheduler.call(
			"has_burn",
			player,
			CombatAttackRegistry.COMBAT_ROBOT_MAIN_BATTLE_BURN_FAMILY
		))
		and not bool(slow_scheduler.call(
			"has_slow",
			player,
			CombatAttackRegistry.COMBAT_ROBOT_MAIN_BATTLE_SLOW_FAMILY
		)),
		"A dead reliable confirmation must not apply main-battle burn or slow even when its mask is non-zero."
	)


func _spawn_player(peer_id: int) -> Player:
	var player := PLAYER_SCENE.instantiate() as Player
	runtime.add_child(player)
	runtime.bind_player_runtime_context(player)
	player.peer_id = peer_id
	player.global_position = Vector2(300.0, 300.0)
	player.collision_layer = 0
	player.collision_mask = 0
	player.invincibility_duration = 0.0
	player.invincibility_time_left = 0.0
	player.physical_defense = 0
	player.magic_defense = 0
	player.set("_base_physical_defense", 0)
	player.set("_base_magic_defense", 0)
	player.set("_base_max_health", TEST_HEALTH)
	player.max_health = TEST_HEALTH
	player.current_health = TEST_HEALTH
	player.health_bar.setup(TEST_HEALTH, TEST_HEALTH)
	player.set_process(false)
	player.set_physics_process(false)
	runtime.peer_players[peer_id] = player
	return player


func _on_life_rpc_requested(method_name: StringName, arguments: Array) -> void:
	life_rpc_count += 1
	last_life_rpc_method = method_name
	last_life_rpc_arguments = arguments.duplicate(true)


func _get_test_net_time() -> float:
	return 71.0


func _noop_peer(_peer_id: int) -> void:
	pass


func _get_revive_anchor(_peer_id: int) -> Vector2:
	return Vector2.ZERO


func _commit_revive_position(_peer_id: int, _position: Vector2) -> void:
	pass


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
