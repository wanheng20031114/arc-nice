extends SceneTree

const GAME_SCRIPT := preload("res://scene/game_modes/standard/standard_game.gd")
const TOWER_DEFENSE_GAME_SCRIPT := preload("res://scene/game_modes/tower_defense/tower_defense_game.gd")
const STANDARD_PICKUP_REGISTRY_SCENE := preload(
	"res://scene/game_modes/standard/pickup/standard_pickup_registry.tscn"
)
const TOWER_PICKUP_REGISTRY_SCENE := preload(
	"res://scene/game_modes/tower_defense/pickup/tower_defense_pickup_registry.tscn"
)
const TOWER_ENEMY_COORDINATOR_SCENE := preload(
	"res://scene/game_modes/tower_defense/enemy/tower_defense_enemy_coordinator.tscn"
)
const ENEMY_SPAWN_EFFECT_SCENE := preload(
	"res://scene/enemy/yuanshi_insect/yuanshi_insect_spawn_effect.tscn"
)
const ENEMY_SCENE := preload("res://scene/enemy/enemy.tscn")
const ENEMY_CONFIG := preload(
	"res://resources/config/enemies/yuanshi_insect_basic.tres"
)

const HOST_AUTHORITY := 1
const CLIENT_VIEW := 2
const ENEMY_TERMINAL_DEFEATED := 0
const ENEMY_TERMINAL_ESCAPED := 1
const ENEMY_TERMINAL_REMOVED := 2
const PRESSURE_EVENT_COUNT := 4096


class RecordingMpGame:
	extends "res://scene/multiplayer/mp_game.gd"

	var sent_reasons: Array[int] = []
	var last_terminal_args: Array = []

	func _ready() -> void:
		pass

	func _rpc_to_connected_clients(
		method_name: StringName,
		args: Array = []
	) -> void:
		if method_name == &"net_enemy_terminal" and args.size() >= 2:
			sent_reasons.append(int(args[1]))
			last_terminal_args = args.duplicate(true)


class ClientNetManagerStub:
	extends NetManagerStore

	func is_host() -> bool:
		return false

	func is_client() -> bool:
		return true


class HostNetManagerStub:
	extends NetManagerStore

	func is_host() -> bool:
		return true

	func is_client() -> bool:
		return false


class TerminalTowerRuntime:
	extends TowerDefenseGame

	var amount := 0
	var impact_direction := Vector2.ZERO
	var damage_type := -1

	func show_damage_number(
		confirmed_amount: int,
		_world_position: Vector2,
		confirmed_direction: Vector2 = Vector2.ZERO,
		confirmed_type: EnemyConfig.DamageType = EnemyConfig.DamageType.PHYSICAL,
		_display_priority: DamageNumberPool.DisplayPriority = (
			DamageNumberPool.DisplayPriority.NORMAL
		)
	) -> bool:
		amount = confirmed_amount
		impact_direction = confirmed_direction
		damage_type = int(confirmed_type)
		return true


var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_game_enemy_removal_markers()
	_test_tower_defense_enemy_escape_marker()
	_test_pickup_tree_exit_markers(GAME_SCRIPT.new(), "StandardGame")
	_test_pickup_tree_exit_markers(TOWER_DEFENSE_GAME_SCRIPT.new(), "TowerDefenseGame")
	_test_host_terminal_pairing_cache()
	_test_reliable_terminal_feedback_payload()
	_test_real_batch_damage_terminal_chain()
	_test_client_escape_compatibility_has_no_tombstone_cache()
	if failures.is_empty():
		print("TERMINAL_ID_LIFECYCLE_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_game_enemy_removal_markers() -> void:
	var standard_runtime := GAME_SCRIPT.new() as CombatRuntimeBase
	_prepare_runtime_boundaries(standard_runtime)
	_exercise_enemy_exit_pressure(standard_runtime, "StandardGame")
	var tower_runtime := TOWER_DEFENSE_GAME_SCRIPT.new() as CombatRuntimeBase
	_prepare_runtime_boundaries(tower_runtime)
	_exercise_enemy_exit_pressure(tower_runtime, "TowerDefenseGame")


func _exercise_enemy_exit_pressure(runtime: CombatRuntimeBase, label: String) -> void:
	runtime.runtime_mode = HOST_AUTHORITY
	var gateway := runtime.get_multiplayer_gameplay_gateway()
	var removed_ids: Array[int] = []
	gateway.enemy_removed.connect(
		func(net_id: int) -> void: removed_ids.append(net_id)
	)
	var instance_to_net := runtime.multiplayer_enemy_ids_by_instance
	var net_to_enemy := runtime.multiplayer_enemies_by_net_id
	for event_index in range(PRESSURE_EVENT_COUNT):
		var instance_id := 100_000 + event_index
		var net_id := event_index + 1
		instance_to_net[instance_id] = net_id
		net_to_enemy[net_id] = null
		if runtime is TowerDefenseGame:
			(runtime as TowerDefenseGame).enemy_coordinator.handle_wave_enemy_tree_exited(
				instance_id
			)
		elif event_index % 2 == 0:
			runtime.call("_on_wave_enemy_tree_exited", instance_id)
		else:
			runtime.call("_on_boss_enemy_tree_exited", instance_id)
	_expect(
		removed_ids.size() == PRESSURE_EVENT_COUNT,
		"%s must emit exactly one removal for each wave/boss exit." % label
	)
	runtime.free()


func _test_tower_defense_enemy_escape_marker() -> void:
	var runtime := TOWER_DEFENSE_GAME_SCRIPT.new() as TowerDefenseGame
	var gateway := _prepare_runtime_boundaries(runtime)
	runtime.runtime_mode = HOST_AUTHORITY
	var escaped_ids: Array[int] = []
	var removed_ids: Array[int] = []
	gateway.enemy_escaped.connect(
		func(net_id: int) -> void: escaped_ids.append(net_id)
	)
	gateway.enemy_removed.connect(
		func(net_id: int) -> void: removed_ids.append(net_id)
	)
	var enemy := Enemy.new()
	var enemy_instance_id := enemy.get_instance_id()
	var net_id := 77
	runtime.multiplayer_enemy_ids_by_instance[enemy_instance_id] = net_id
	runtime.multiplayer_enemies_by_net_id[net_id] = enemy
	runtime.enemy_coordinator.emit_multiplayer_enemy_escaped(enemy)
	var pending_escape_ids := (
		runtime.enemy_coordinator.get("_pending_terminal_escape_net_ids")
		as Dictionary
	)
	_expect(
		pending_escape_ids.size() == 1,
		"Escape must retain one marker only until the paired tree exit."
	)
	# Boss and boss-add exits share this removal path; it must consume, not retain,
	# the escape marker while suppressing the duplicate generic terminal event.
	runtime.enemy_coordinator.handle_wave_enemy_tree_exited(enemy_instance_id)
	_expect(escaped_ids == [net_id], "Escape must emit its terminal event once.")
	_expect(removed_ids.is_empty(), "Escape tree exit must suppress generic removal.")
	_expect(
		pending_escape_ids.is_empty(),
		"Escape marker must be consumed by the paired boss tree exit."
	)
	enemy.free()
	runtime.free()


func _test_pickup_tree_exit_markers(runtime: CombatRuntimeBase, label: String) -> void:
	var gateway := _prepare_runtime_boundaries(runtime)
	runtime.runtime_mode = HOST_AUTHORITY
	var pickup_registry: PickupRegistryBase = null
	if runtime is StandardGame:
		pickup_registry = _bind_tree_less_standard_pickup_registry(
			runtime as StandardGame,
			gateway
		)
	elif runtime is TowerDefenseGame:
		pickup_registry = _bind_tree_less_tower_pickup_registry(
			runtime as TowerDefenseGame,
			gateway
		)
	_expect(pickup_registry != null, "%s pickup registry must bind." % label)
	if pickup_registry == null:
		runtime.free()
		return
	var removed_ids: Array[int] = []
	var collected_ids: Array[int] = []
	gateway.pickup_removed.connect(
		func(net_id: int) -> void: removed_ids.append(net_id)
	)
	gateway.pickup_collected.connect(
		func(net_id: int, _peer_id: int, _config: PickupConfig, _applied: bool) -> void:
			collected_ids.append(net_id)
	)
	var pickup := Pickup.new()
	var pickup_index := runtime.get("multiplayer_pickups") as Dictionary
	for event_index in range(PRESSURE_EVENT_COUNT):
		var net_id := event_index + 1
		pickup.set_meta("net_id", net_id)
		pickup_index[net_id] = pickup
		pickup_registry.handle_multiplayer_pickup_consumed(pickup, 2, true)
		pickup_registry.handle_multiplayer_pickup_tree_exited(net_id)
	_expect(
		removed_ids.size() == PRESSURE_EVENT_COUNT,
		"%s consumed pickups must emit one removal despite their later tree exit." % label
	)
	_expect(
		collected_ids.size() == PRESSURE_EVENT_COUNT,
		"%s consumed pickups must preserve one collection confirmation." % label
	)
	_expect(
		pickup_registry.pending_multiplayer_pickup_exit_ids.is_empty(),
		"%s consumed pickup suppression markers must be consumed." % label
	)

	var spontaneous_net_id := PRESSURE_EVENT_COUNT + 1
	pickup_index[spontaneous_net_id] = pickup
	pickup_registry.handle_multiplayer_pickup_tree_exited(spontaneous_net_id)
	_expect(
		removed_ids.size() == PRESSURE_EVENT_COUNT + 1,
		"%s spontaneous pickup exit must still emit one generic removal." % label
	)
	_expect(
		pickup_registry.pending_multiplayer_pickup_exit_ids.is_empty(),
		"%s spontaneous pickup exit must not allocate a tombstone." % label
	)
	pickup.free()
	runtime.free()


func _bind_tree_less_standard_pickup_registry(
	runtime: StandardGame,
	gateway: MultiplayerGameplayGateway
) -> StandardPickupRegistry:
	var enemy_container := Node2D.new()
	enemy_container.name = "EnemyContainer"
	runtime.add_child(enemy_container)
	var boss_container := Node2D.new()
	boss_container.name = "BossContainer"
	runtime.add_child(boss_container)
	var registry := (
		STANDARD_PICKUP_REGISTRY_SCENE.instantiate()
		as StandardPickupRegistry
	)
	registry.name = "PickupRegistry"
	runtime.add_child(registry)
	registry.bind_standard_dependencies(
		runtime.runtime_mode,
		runtime.multiplayer_pickups,
		gateway,
		enemy_container,
		boss_container,
		{},
		PickupRegistryBase.FIRST_DYNAMIC_PICKUP_NET_ID
	)
	return registry


func _bind_tree_less_tower_pickup_registry(
	runtime: TowerDefenseGame,
	gateway: MultiplayerGameplayGateway
) -> TowerDefensePickupRegistry:
	var registry := (
		TOWER_PICKUP_REGISTRY_SCENE.instantiate()
		as TowerDefensePickupRegistry
	)
	registry.name = "PickupRegistry"
	runtime.add_child(registry)
	runtime.pickup_registry = registry
	registry.bind_tower_dependencies(
		runtime.runtime_mode,
		runtime.multiplayer_pickups,
		gateway,
		runtime.get_node("EnemyContainer") as Node2D,
		runtime.get_node("BossContainer") as Node2D,
		{},
		PickupRegistryBase.FIRST_DYNAMIC_PICKUP_NET_ID
	)
	return registry


func _attach_enemy_coordinator(
	mp_game: RecordingMpGame
) -> MpEnemyCoordinator:
	var coordinator := MpEnemyCoordinator.new()
	coordinator.name = "EnemyCoordinator"
	mp_game.add_child(coordinator)
	mp_game.enemy_coordinator = coordinator
	return coordinator


func _test_host_terminal_pairing_cache() -> void:
	var mp_game := RecordingMpGame.new()
	var enemy_coordinator := _attach_enemy_coordinator(mp_game)
	mp_game._broadcast_enemy_terminal(1, ENEMY_TERMINAL_DEFEATED, Vector2.ZERO)
	mp_game._broadcast_enemy_terminal(1, ENEMY_TERMINAL_DEFEATED, Vector2.ZERO)
	_expect(
		mp_game.sent_reasons == [ENEMY_TERMINAL_DEFEATED],
		"Duplicate defeated event must remain suppressed while removal is pending."
	)
	mp_game._broadcast_enemy_terminal(1, ENEMY_TERMINAL_REMOVED, Vector2.ZERO)
	_expect(
		enemy_coordinator.host_terminal_enemy_ids.is_empty(),
		"Generic removal must consume the pending defeated marker."
	)

	mp_game.sent_reasons.clear()
	for event_index in range(PRESSURE_EVENT_COUNT):
		var net_id := event_index + 10
		mp_game._broadcast_enemy_terminal(
			net_id,
			ENEMY_TERMINAL_DEFEATED,
			Vector2.ZERO
		)
		mp_game._broadcast_enemy_terminal(
			net_id,
			ENEMY_TERMINAL_REMOVED,
			Vector2.ZERO
		)
	_expect(
		enemy_coordinator.host_terminal_enemy_ids.is_empty(),
		"Thousands of defeated→removed pairs must leave no Host terminal IDs."
	)
	_expect(
		mp_game.sent_reasons.size() == PRESSURE_EVENT_COUNT,
		"Defeated→removed pairs must send only the defeated terminal event."
	)

	mp_game.sent_reasons.clear()
	for event_index in range(PRESSURE_EVENT_COUNT):
		var net_id := event_index + 20_000
		mp_game._broadcast_enemy_terminal(net_id, ENEMY_TERMINAL_REMOVED, Vector2.ZERO)
		mp_game._broadcast_enemy_terminal(net_id, ENEMY_TERMINAL_ESCAPED, Vector2.ZERO)
	_expect(
		enemy_coordinator.host_terminal_enemy_ids.is_empty(),
		"Direct removed/escaped terminals must never allocate Host tombstones."
	)
	_expect(
		mp_game.sent_reasons.size() == PRESSURE_EVENT_COUNT * 2,
		"Direct removed/escaped terminal sends must remain intact."
	)
	mp_game.free()


func _test_client_escape_compatibility_has_no_tombstone_cache() -> void:
	var mp_game := RecordingMpGame.new()
	var enemy_coordinator := _attach_enemy_coordinator(mp_game)
	var net_manager_stub := ClientNetManagerStub.new()
	mp_game.set("net_manager", net_manager_stub)
	var runtime := TOWER_DEFENSE_GAME_SCRIPT.new()
	_prepare_runtime_boundaries(runtime)
	runtime.runtime_mode = CLIENT_VIEW
	mp_game.game = runtime
	enemy_coordinator.bind_runtime(runtime)
	mp_game._mode_adapter = runtime.get_multiplayer_mode_adapter()
	mp_game.tower_mode_adapter = (
		mp_game._mode_adapter as TowerDefenseMultiplayerModeAdapter
	)
	for event_index in range(PRESSURE_EVENT_COUNT):
		var net_id := event_index + 1
		mp_game.net_enemy_terminal(net_id, ENEMY_TERMINAL_ESCAPED, Vector2.ZERO)
		mp_game.net_enemy_escaped(net_id)
		mp_game.net_enemy_removed(net_id)
	_expect(
		enemy_coordinator.net_enemies.is_empty(),
		"Unified and legacy escape/removal traffic must leave no client enemies."
	)
	var source := FileAccess.get_file_as_string("res://scene/multiplayer/mp_game.gd")
	_expect(
		source.find("_escaped_enemy_ids") < 0,
		"Client escape compatibility must not keep a session-long ID tombstone cache."
	)
	runtime.free()
	mp_game.free()
	net_manager_stub.free()


func _test_reliable_terminal_feedback_payload() -> void:
	var mp_game := RecordingMpGame.new()
	var enemy_coordinator := _attach_enemy_coordinator(mp_game)
	var runtime := TOWER_DEFENSE_GAME_SCRIPT.new() as TowerDefenseGame
	_prepare_runtime_boundaries(runtime)
	var enemy := Enemy.new()
	var net_id := 606
	var lethal_request := DamageRequest.new(
		25,
		CombatTypes.DamageType.PHYSICAL
	)
	lethal_request.with_directions(Vector2.RIGHT)
	enemy.last_damage_result = DamageResolver.resolve(
		lethal_request,
		DamageTargetProfile.new(25)
	)
	enemy.current_health = 0
	enemy.is_dead = true
	runtime.multiplayer_enemies_by_net_id[net_id] = enemy
	mp_game.game = runtime
	enemy_coordinator.bind_runtime(runtime)
	enemy_coordinator.pending_enemy_damage_feedback[net_id] = {
		"current_health": 10,
		"damage": 15,
		"impact_direction": Vector2.LEFT,
		"damage_type": int(EnemyConfig.DamageType.MAGIC),
		"show_hit_particles": false,
	}
	enemy_coordinator.active_enemy_damage_feedback_context[net_id] = {
		"impact_direction": Vector2.RIGHT,
		"damage_type": int(EnemyConfig.DamageType.PHYSICAL),
		"show_hit_particles": true,
	}
	mp_game._broadcast_enemy_terminal(
		net_id,
		ENEMY_TERMINAL_DEFEATED,
		Vector2(12.0, 8.0)
	)
	var args := mp_game.last_terminal_args
	_expect(
		args.size() == 9
		and int(args[0]) == net_id
		and int(args[1]) == ENEMY_TERMINAL_DEFEATED
		and args[2] == Vector2(12.0, 8.0)
		and int(args[3]) == 0
		and int(args[4]) == enemy.health_revision
		and int(args[5]) == 40
		and args[6] == Vector2.RIGHT
		and int(args[7]) == int(EnemyConfig.DamageType.PHYSICAL)
		and bool(args[8]),
		"可靠终结事件必须合并未发送的15点反馈与最后25点致死伤害，并携带最终方向、类型和粒子标记。"
	)
	_expect(
		not enemy_coordinator.pending_enemy_damage_feedback.has(net_id),
		"致死反馈并入可靠终结事件后必须从不可靠批队列移除，避免重复浮字。"
	)
	runtime.multiplayer_enemies_by_net_id.clear()
	enemy.free()
	runtime.free()
	mp_game.free()


func _test_real_batch_damage_terminal_chain() -> void:
	var mp_game := RecordingMpGame.new()
	var enemy_coordinator := _attach_enemy_coordinator(mp_game)
	var keepalive_request := HTTPRequest.new()
	keepalive_request.name = "PublicRoomKeepaliveRequest"
	mp_game.add_child(keepalive_request)
	root.add_child(mp_game)
	var net_manager_stub := HostNetManagerStub.new()
	mp_game.net_manager = net_manager_stub
	var runtime := TOWER_DEFENSE_GAME_SCRIPT.new()
	var gateway := _prepare_runtime_boundaries(runtime)
	runtime.runtime_mode = HOST_AUTHORITY
	mp_game.game = runtime
	enemy_coordinator.bind_runtime(runtime)
	mp_game._mode_adapter = runtime.get_multiplayer_mode_adapter()
	mp_game.tower_mode_adapter = (
		mp_game._mode_adapter as TowerDefenseMultiplayerModeAdapter
	)
	gateway.enemy_defeated.connect(
		mp_game._on_host_enemy_defeated
	)
	var enemy := ENEMY_SCENE.instantiate() as Enemy
	if enemy == null:
		_expect(false, "真实批伤终结链必须能实例化敌人。")
		root.remove_child(mp_game)
		mp_game.free()
		runtime.free()
		net_manager_stub.free()
		return
	mp_game.add_child(enemy)
	var lethal_config := ENEMY_CONFIG.duplicate(true) as EnemyConfig
	lethal_config.max_health = 40
	lethal_config.physical_defense = 0
	lethal_config.xirang_kill_reward = 0
	lethal_config.drop_table = null
	enemy.setup(lethal_config, null, null, runtime)
	enemy.set_process(false)
	enemy.set_physics_process(false)
	var net_id := 707
	enemy.set_meta(&"net_id", net_id)
	runtime.multiplayer_enemy_ids_by_instance[
		enemy.get_instance_id()
	] = net_id
	runtime.multiplayer_enemies_by_net_id[net_id] = enemy
	enemy.defeated.connect(
		func(defeated_enemy: Enemy) -> void:
			runtime.enemy_coordinator.emit_multiplayer_enemy_defeated(defeated_enemy)
	)
	var accepted := (
		mp_game.apply_authoritative_plant_enemy_damage_batch(
			9901,
			enemy,
			PackedInt64Array([40]),
			PackedInt32Array([1]),
			Vector2.RIGHT,
			EnemyConfig.DamageType.PHYSICAL
		)
	)
	var args := mp_game.last_terminal_args
	_expect(
		accepted
		and enemy.is_dead
		and args.size() == 9
		and int(args[0]) == net_id
		and int(args[1]) == ENEMY_TERMINAL_DEFEATED
		and int(args[3]) == 0
		and int(args[4]) == enemy.health_revision
		and int(args[5]) == 40
		and args[6] == Vector2.RIGHT
		and int(args[7]) == int(EnemyConfig.DamageType.PHYSICAL),
		"真实apply_damage_batch→defeated信号→可靠terminal链必须携带最后40点致死反馈。"
	)
	_expect(
		not enemy_coordinator.pending_enemy_damage_feedback.has(net_id)
		and not enemy_coordinator.active_enemy_damage_feedback_context.has(net_id),
		"真实致死批伤结束后不得遗留不可靠反馈或活动伤害上下文。"
	)
	var client_mp_game := RecordingMpGame.new()
	var client_enemy_coordinator := _attach_enemy_coordinator(client_mp_game)
	var client_net_manager := ClientNetManagerStub.new()
	var client_runtime := TerminalTowerRuntime.new()
	_prepare_runtime_boundaries(client_runtime)
	client_runtime.runtime_mode = CLIENT_VIEW
	client_mp_game.net_manager = client_net_manager
	client_mp_game.game = client_runtime
	client_enemy_coordinator.bind_runtime(client_runtime)
	client_mp_game._mode_adapter = client_runtime.get_multiplayer_mode_adapter()
	client_mp_game.tower_mode_adapter = (
		client_mp_game._mode_adapter as TowerDefenseMultiplayerModeAdapter
	)
	var client_keepalive_request := HTTPRequest.new()
	client_keepalive_request.name = "PublicRoomKeepaliveRequest"
	client_mp_game.add_child(client_keepalive_request)
	root.add_child(client_mp_game)
	var client_enemy := ENEMY_SCENE.instantiate() as Enemy
	client_mp_game.add_child(client_enemy)
	client_enemy.setup(lethal_config, null, null, client_runtime)
	client_enemy.configure_multiplayer_proxy()
	client_enemy.set_meta(&"net_id", net_id)
	client_enemy_coordinator.net_enemies[net_id] = client_enemy
	client_runtime.multiplayer_enemies_by_net_id[net_id] = client_enemy
	client_runtime.multiplayer_enemy_ids_by_instance[
		client_enemy.get_instance_id()
	] = net_id
	client_mp_game.callv("net_enemy_terminal", args)
	_expect(
		client_enemy.is_dead
		and client_enemy.current_health == 0
		and not client_enemy_coordinator.net_enemies.has(net_id)
		and not client_runtime.multiplayer_enemies_by_net_id.has(net_id)
		and client_runtime.amount == 40
		and client_runtime.impact_direction == Vector2.RIGHT
		and client_runtime.damage_type
		== int(EnemyConfig.DamageType.PHYSICAL),
		"客户端消费九参数可靠terminal时必须先显示最后40点伤害、应用0生命，再执行死亡移除。"
	)
	runtime.multiplayer_enemies_by_net_id.clear()
	runtime.multiplayer_enemy_ids_by_instance.clear()
	mp_game.remove_child(enemy)
	enemy.free()
	# This tree-less fixture never binds tower warehouse state. Disable that
	# unrelated exit capture before removing the MpGame node from the SceneTree.
	mp_game.tower_mode_adapter = null
	root.remove_child(mp_game)
	mp_game.free()
	runtime.free()
	net_manager_stub.free()
	client_mp_game.remove_child(client_enemy)
	client_enemy.free()
	client_runtime.free()
	root.remove_child(client_mp_game)
	client_mp_game.free()
	client_net_manager.free()


func _prepare_runtime_boundaries(
	runtime: CombatRuntimeBase
) -> MultiplayerGameplayGateway:
	var gateway := MultiplayerGameplayGateway.new()
	gateway.name = "MultiplayerGameplayGateway"
	runtime.add_child(gateway)
	gateway.bind_runtime(runtime)
	runtime.multiplayer_gateway = gateway
	var adapter: MultiplayerModeAdapter = null
	if runtime is TowerDefenseGame:
		var tower_runtime := runtime as TowerDefenseGame
		_bind_tree_less_tower_enemy_coordinator(tower_runtime, gateway)
		var plant_runtime := TowerDefensePlantRuntimeCoordinator.new()
		plant_runtime.name = "PlantRuntimeCoordinator"
		tower_runtime.add_child(plant_runtime)
		tower_runtime.plant_runtime_coordinator = plant_runtime
		plant_runtime.setup(tower_runtime.runtime_mode, null, null, null, null)
		adapter = TowerDefenseMultiplayerModeAdapter.new()
	else:
		adapter = StandardMultiplayerModeAdapter.new()
	adapter.name = "MultiplayerModeAdapter"
	runtime.add_child(adapter)
	adapter.bind_runtime(runtime)
	runtime.multiplayer_mode_adapter = adapter
	return gateway


func _bind_tree_less_tower_enemy_coordinator(
	runtime: TowerDefenseGame,
	gateway: MultiplayerGameplayGateway
) -> TowerDefenseEnemyCoordinator:
	var coordinator := (
		TOWER_ENEMY_COORDINATOR_SCENE.instantiate()
		as TowerDefenseEnemyCoordinator
	)
	coordinator.name = "EnemyCoordinator"
	runtime.add_child(coordinator)
	var campaign := TowerDefenseCampaignCoordinator.new()
	campaign.name = "CampaignCoordinator"
	runtime.add_child(campaign)
	var player_roster := TowerDefensePlayerRosterCoordinator.new()
	player_roster.name = "PlayerRosterCoordinator"
	runtime.add_child(player_roster)
	var plant_runtime := TowerDefensePlantRuntimeCoordinator.new()
	plant_runtime.name = "EnemyFixturePlantRuntimeCoordinator"
	runtime.add_child(plant_runtime)
	var enemy_container := Node2D.new()
	enemy_container.name = "EnemyContainer"
	runtime.add_child(enemy_container)
	var boss_container := Node2D.new()
	boss_container.name = "BossContainer"
	runtime.add_child(boss_container)
	var spawn_points := Node2D.new()
	spawn_points.name = "EnemySpawnPoints"
	runtime.add_child(spawn_points)
	var spawn_point := Marker2D.new()
	spawn_point.name = "Spawn1"
	spawn_points.add_child(spawn_point)
	var ground_layer := TileMapLayer.new()
	ground_layer.name = "GroundTileMapLayer"
	runtime.add_child(ground_layer)
	var pathfinder := GridPathfinder.new()
	pathfinder.name = "GridPathfinder"
	runtime.add_child(pathfinder)
	var spawn_timer := Timer.new()
	spawn_timer.name = "EnemySpawnTimer"
	runtime.add_child(spawn_timer)
	var fate := FateCoordinator.new()
	fate.name = "FateCoordinator"
	runtime.add_child(fate)
	var presentation := TowerDefensePresentationCoordinator.new()
	presentation.name = "PresentationCoordinator"
	runtime.add_child(presentation)
	var object_pool := SessionObjectPool.new()
	object_pool.name = "SessionObjectPool"
	runtime.add_child(object_pool)
	coordinator.setup(
		runtime,
		campaign,
		player_roster,
		plant_runtime,
		RandomNumberGenerator.new(),
		enemy_container,
		boss_container,
		spawn_points,
		ground_layer,
		pathfinder,
		spawn_timer,
		gateway,
		fate,
		presentation,
		object_pool,
		ENEMY_SPAWN_EFFECT_SCENE
	)
	runtime.enemy_coordinator = coordinator
	return coordinator


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
