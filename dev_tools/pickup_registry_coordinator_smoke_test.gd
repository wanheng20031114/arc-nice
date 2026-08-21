extends SceneTree

const STANDARD_SCENE := preload(
	"res://scene/game_modes/standard/standard_game.tscn"
)
const ROGUE_SCENE := preload(
	"res://scene/game_modes/rogue/combat/rogue_combat_game_01.tscn"
)
const TOWER_SCENE := preload(
	"res://scene/game_modes/tower_defense/tower_defense_game.tscn"
)
const STANDARD_REGISTRY_SCENE := preload(
	"res://scene/game_modes/standard/pickup/standard_pickup_registry.tscn"
)
const TOWER_REGISTRY_SCENE := preload(
	"res://scene/game_modes/tower_defense/pickup/tower_defense_pickup_registry.tscn"
)
const PICKUP_SCENE := preload("res://scene/combat/pickups/pickup.tscn")
const HEALTH_PICKUP := preload(
	"res://resources/config/consumables/healing_potion.tres"
)

var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	await _test_standard_registry()
	await _test_rogue_registry()
	_test_tree_less_standard_facade()
	_test_tree_less_tower_registry()
	_test_source_boundaries()
	_finish()


func _test_standard_registry() -> void:
	var game := STANDARD_SCENE.instantiate() as StandardGame
	_expect(game != null, "普通模式场景必须实例化为 StandardGame。")
	if game == null:
		return
	game.auto_start_waves = false
	game.configure_multiplayer(
		CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY,
		1,
		{1: "Host"},
		{1: &"weishidaier"}
	)
	root.add_child(game)
	await process_frame
	await process_frame

	var registry := game.get_node_or_null("PickupRegistry") as StandardPickupRegistry
	_expect(registry != null, "普通模式必须静态挂载独立 PickupRegistry。")
	_expect(registry != null and registry.is_bound(), "普通 PickupRegistry 必须绑定中性依赖。")
	var first_static := game.get_node_or_null("WorldBounds/Pickup3") as Pickup
	var second_static := game.get_node_or_null("WorldBounds/Pickup4") as Pickup
	_expect(
		game.get_pickup_for_net_id(1) == first_static
		and game.get_pickup_for_net_id(2) == second_static,
		"普通模式静态 Pickup 必须继续按 NodePath 排序获得 1、2。"
	)
	_expect(
		registry.next_multiplayer_pickup_net_id
		== PickupRegistryBase.FIRST_DYNAMIC_PICKUP_NET_ID,
		"普通模式动态 Pickup 起始 net id 必须保持 1000。"
	)

	var spawn_records: Array[Dictionary] = []
	var terminal_events: Array[String] = []
	game.multiplayer_gateway.pickup_spawned.connect(
		func(net_id: int, config: PickupConfig, spawn_position: Vector2) -> void:
			spawn_records.append({
				"net_id": net_id,
				"config": config,
				"position": spawn_position,
			})
	)
	game.multiplayer_gateway.pickup_removed.connect(
		func(net_id: int) -> void:
			terminal_events.append("removed:%d" % net_id)
	)
	game.multiplayer_gateway.pickup_collected.connect(
		func(net_id: int, _peer_id: int, _config: PickupConfig, _applied: bool) -> void:
			terminal_events.append("collected:%d" % net_id)
	)

	var boss_pickup := PICKUP_SCENE.instantiate() as Pickup
	boss_pickup.config = HEALTH_PICKUP
	game.boss_container.add_child(boss_pickup)
	boss_pickup.global_position = Vector2(321.0, 123.0)
	await process_frame
	await process_frame
	_expect(
		spawn_records.size() == 1
		and int(spawn_records[0].get("net_id", 0)) == 1000
		and spawn_records[0].get("config") == HEALTH_PICKUP
		and (spawn_records[0].get("position") as Vector2) == Vector2(321.0, 123.0),
		"BossContainer 动态 Pickup 必须延后一回合以最终位置广播 net id 1000。"
	)
	_expect(
		game.get_pickup_for_net_id(1000) == boss_pickup
		and registry.next_multiplayer_pickup_net_id == 1001,
		"普通 PickupRegistry 必须独占动态 net id 游标。"
	)
	registry.register_existing_dynamic_pickups()
	_expect(
		spawn_records.size() == 1 and registry.next_multiplayer_pickup_net_id == 1001,
		"重复扫描已有动态 Pickup 不得重复分配或广播。"
	)
	boss_pickup.consumed.emit(boss_pickup, 1, true)
	boss_pickup.queue_free()
	await process_frame
	await process_frame
	_expect(
		terminal_events == ["collected:1000"],
		"消费必须只发布原子收集终结，后续 tree_exited 不得再竞争发布移除。"
	)
	_expect(
		registry.pending_multiplayer_pickup_exit_ids.is_empty()
		and game.get_pickup_for_net_id(1000) == null,
		"Pickup 消费退出后不得残留索引或抑制标记。"
	)
	_cleanup_runtime(game)
	await process_frame


func _test_rogue_registry() -> void:
	var game := ROGUE_SCENE.instantiate() as RogueCombatGame
	_expect(game != null, "肉鸽作战场景必须实例化为 RogueCombatGame。")
	if game == null:
		return
	game.auto_start_waves = false
	game.configure_multiplayer(
		CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY,
		1,
		{1: "Host"},
		{1: &"weishidaier"}
	)
	root.add_child(game)
	await process_frame
	await process_frame

	var registry := game.get_node_or_null("PickupRegistry") as RoguePickupRegistry
	_expect(registry != null, "肉鸽必须静态挂载自身 PickupRegistry。")
	_expect(registry != null and registry.is_bound(), "肉鸽 PickupRegistry 必须绑定中性依赖。")
	_expect(game.get_network_pickup_count() == 0, "肉鸽场景不得凭空产生静态 Pickup。")
	_expect(
		registry.next_multiplayer_pickup_net_id
		== PickupRegistryBase.FIRST_DYNAMIC_PICKUP_NET_ID,
		"肉鸽动态 Pickup 起始 net id 必须独立保持 1000。"
	)

	var spawn_ids: Array[int] = []
	game.multiplayer_gateway.pickup_spawned.connect(
		func(net_id: int, _config: PickupConfig, _position: Vector2) -> void:
			spawn_ids.append(net_id)
	)
	var enemy_pickup := PICKUP_SCENE.instantiate() as Pickup
	enemy_pickup.config = HEALTH_PICKUP
	game.enemy_container.add_child(enemy_pickup)
	enemy_pickup.global_position = Vector2(48.0, 96.0)
	await process_frame
	await process_frame
	_expect(
		spawn_ids == [1000]
		and game.get_pickup_for_net_id(1000) == enemy_pickup
		and registry.next_multiplayer_pickup_net_id == 1001,
		"肉鸽 EnemyContainer 必须由自身协调器注册动态 Pickup。"
	)
	enemy_pickup.queue_free()
	await process_frame
	_expect(
		game.get_pickup_for_net_id(1000) == null,
		"肉鸽动态 Pickup 自然退出必须清理共享索引。"
	)
	_cleanup_runtime(game)
	await process_frame


func _test_tree_less_standard_facade() -> void:
	var game := StandardGame.new()
	var gateway := MultiplayerGameplayGateway.new()
	gateway.name = "MultiplayerGameplayGateway"
	game.add_child(gateway)
	gateway.bind_runtime(game)
	game.multiplayer_gateway = gateway
	game.runtime_mode = CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY
	var enemy_container := Node2D.new()
	enemy_container.name = "EnemyContainer"
	game.add_child(enemy_container)
	var boss_container := Node2D.new()
	boss_container.name = "BossContainer"
	game.add_child(boss_container)
	var registry := STANDARD_REGISTRY_SCENE.instantiate() as StandardPickupRegistry
	registry.name = "PickupRegistry"
	game.add_child(registry)
	registry.bind_standard_dependencies(
		game.runtime_mode,
		game,
		gateway,
		enemy_container,
		boss_container
	)
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
	pickup.config = HEALTH_PICKUP
	game.register_network_pickup(77, pickup)
	game._on_multiplayer_pickup_consumed(pickup, 2, true)
	game._on_multiplayer_pickup_tree_exited(77)
	_expect(
		removed_ids.is_empty()
		and collected_ids == [77]
		and registry.pending_multiplayer_pickup_exit_ids.is_empty(),
		"StandardGame.new() 的 tree-less 注册表必须保持原子消费/退出抑制语义。"
	)
	pickup.free()
	game.free()


func _test_tree_less_tower_registry() -> void:
	var authored_game := TOWER_SCENE.instantiate() as TowerDefenseGame
	_expect(
		authored_game != null
		and authored_game.get_node_or_null("PickupRegistry")
		is TowerDefensePickupRegistry,
		"塔防场景必须静态挂载自身 PickupRegistry。"
	)
	if authored_game != null:
		authored_game.free()

	var game := TowerDefenseGame.new()
	game.runtime_mode = CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY
	var gateway := MultiplayerGameplayGateway.new()
	gateway.name = "MultiplayerGameplayGateway"
	game.add_child(gateway)
	gateway.bind_runtime(game)
	game.multiplayer_gateway = gateway
	var enemy_container := Node2D.new()
	enemy_container.name = "EnemyContainer"
	game.add_child(enemy_container)
	var boss_container := Node2D.new()
	boss_container.name = "BossContainer"
	game.add_child(boss_container)
	var registry := TOWER_REGISTRY_SCENE.instantiate() as TowerDefensePickupRegistry
	registry.name = "PickupRegistry"
	game.add_child(registry)
	game.pickup_registry = registry
	registry.bind_tower_dependencies(
		game.runtime_mode,
		game,
		gateway,
		enemy_container,
		boss_container
	)
	var spawned_ids: Array[int] = []
	var terminal_events: Array[String] = []
	gateway.pickup_spawned.connect(
		func(net_id: int, _config: PickupConfig, _position: Vector2) -> void:
			spawned_ids.append(net_id)
	)
	gateway.pickup_removed.connect(
		func(net_id: int) -> void: terminal_events.append("removed:%d" % net_id)
	)
	gateway.pickup_collected.connect(
		func(net_id: int, _peer_id: int, _config: PickupConfig, _applied: bool) -> void:
			terminal_events.append("collected:%d" % net_id)
	)
	var pickup := PICKUP_SCENE.instantiate() as Pickup
	pickup.config = HEALTH_PICKUP
	boss_container.add_child(pickup)
	registry.register_existing_dynamic_pickups()
	_expect(
		spawned_ids == [PickupRegistryBase.FIRST_DYNAMIC_PICKUP_NET_ID]
		and game.get_pickup_for_net_id(
			PickupRegistryBase.FIRST_DYNAMIC_PICKUP_NET_ID
		) == pickup
		and registry.next_multiplayer_pickup_net_id
		== PickupRegistryBase.FIRST_DYNAMIC_PICKUP_NET_ID + 1,
		"塔防 PickupRegistry 必须独占动态索引与 net id 游标。"
	)
	pickup.consumed.emit(pickup, 2, true)
	registry.handle_multiplayer_pickup_tree_exited(
		PickupRegistryBase.FIRST_DYNAMIC_PICKUP_NET_ID
	)
	_expect(
		terminal_events == ["collected:1000"]
		and registry.pending_multiplayer_pickup_exit_ids.is_empty()
		and game.get_pickup_for_net_id(
			PickupRegistryBase.FIRST_DYNAMIC_PICKUP_NET_ID
		) == null,
		"塔防 PickupRegistry 必须以单一收集终结完成消费与退出抑制。"
	)
	pickup.free()
	game.free()


func _test_source_boundaries() -> void:
	var wave_source := FileAccess.get_file_as_string(
		"res://scene/combat/runtime/wave_combat_runtime_base.gd"
	)
	var standard_source := FileAccess.get_file_as_string(
		"res://scene/game_modes/standard/pickup/standard_pickup_registry.gd"
	)
	var rogue_source := FileAccess.get_file_as_string(
		"res://scene/game_modes/rogue/combat/pickup/rogue_pickup_registry.gd"
	)
	var tower_source := FileAccess.get_file_as_string(
		"res://scene/game_modes/tower_defense/pickup/tower_defense_pickup_registry.gd"
	)
	var tower_runtime_source := FileAccess.get_file_as_string(
		"res://scene/game_modes/tower_defense/tower_defense_game.gd"
	)
	var standard_runtime_source := FileAccess.get_file_as_string(
		"res://scene/game_modes/standard/standard_game.gd"
	)
	var rogue_runtime_source := FileAccess.get_file_as_string(
		"res://scene/game_modes/rogue/combat/rogue_combat_game.gd"
	)
	var tower_scene_source := FileAccess.get_file_as_string(
		"res://scene/game_modes/tower_defense/tower_defense_game.tscn"
	)
	var base_source := FileAccess.get_file_as_string(
		"res://scene/combat/pickup/pickup_registry_base.gd"
	)
	for concrete_symbol in [
		"_collect_pickups_recursive",
		"_register_dynamic_multiplayer_pickup_from_ref",
		"_mark_multiplayer_pickup_removed",
		"pending_multiplayer_pickup_exit_ids",
	]:
		_expect(
			not wave_source.contains(concrete_symbol),
			"WaveCombatRuntimeBase 不得继续拥有具体 Pickup 编排：%s。"
			% concrete_symbol
		)
	_expect(not standard_source.contains("RoguePickupRegistry"), "普通 Pickup 协调器不得引用肉鸽实现。")
	_expect(not rogue_source.contains("StandardPickupRegistry"), "肉鸽 Pickup 协调器不得引用普通实现。")
	_expect(
		standard_source.contains("extends PickupRegistryBase")
		and rogue_source.contains("extends PickupRegistryBase")
		and tower_source.contains("extends PickupRegistryBase"),
		"三个模式的 PickupRegistry 必须各自静态实例化同一中性索引基类。"
	)
	for source in [base_source, standard_source, rogue_source, tower_source]:
		_expect(
			not source.contains("StandardGame")
			and not source.contains("RogueCombatGame")
			and not source.contains("current_scene")
			and not source.contains("get_tree()"),
			"Pickup 协调器不得持有具体模式根或从场景树猜测网络边界。"
		)
		_expect(
			source.contains("MultiplayerGameplayGateway"),
			"Pickup 协调器必须直接依赖中性 MultiplayerGameplayGateway。"
		)
	for runtime_source in [
		standard_runtime_source,
		rogue_runtime_source,
		tower_runtime_source,
	]:
		_expect(
			not runtime_source.contains("pending_multiplayer_pickup_exit_ids")
			and not runtime_source.contains("next_multiplayer_pickup_net_id"),
			"模式根不得镜像 PickupRegistry 的退出账本或 net id 游标。"
		)
	_expect(
		standard_source.contains("[enemy_container, boss_container]"),
		"普通 PickupRegistry 必须显式组合 Enemy 与 Boss 两个动态容器。"
	)
	_expect(
		rogue_source.contains("[enemy_container]"),
		"肉鸽 PickupRegistry 必须只组合自身 Enemy 动态容器。"
	)
	_expect(
		tower_source.contains("[enemy_container, boss_container]"),
		"塔防 PickupRegistry 必须显式组合 Enemy 与 Boss 两个动态容器。"
	)
	_expect(
		tower_runtime_source.contains("pickup_registry.connect_dynamic_containers()")
		and not tower_runtime_source.contains(
			"func _on_dynamic_pickup_container_child_entered"
		)
		and tower_scene_source.contains(
			"tower_defense/pickup/tower_defense_pickup_registry.tscn"
		),
		"塔防根必须只绑定静态 PickupRegistry，不再持有具体动态注册算法。"
	)
	for neutral_algorithm in [
		"_collect_pickups_recursive",
		"_register_dynamic_multiplayer_pickup_from_ref",
		"handle_multiplayer_pickup_consumed",
		"mark_multiplayer_pickup_removed",
		"_claim_multiplayer_pickup_consumption",
	]:
		_expect(
			base_source.contains(neutral_algorithm)
			and not standard_source.contains(neutral_algorithm)
			and not rogue_source.contains(neutral_algorithm)
			and not tower_source.contains(neutral_algorithm),
			"中性 Pickup 算法只能存在于 PickupRegistryBase：%s。"
			% neutral_algorithm
		)


func _cleanup_runtime(runtime: Node) -> void:
	_stop_audio_players(runtime)
	runtime.queue_free()


func _stop_audio_players(node: Node) -> void:
	for child in node.get_children():
		var player_1d := child as AudioStreamPlayer
		if player_1d != null:
			player_1d.stop()
			player_1d.stream = null
		var player_2d := child as AudioStreamPlayer2D
		if player_2d != null:
			player_2d.stop()
			player_2d.stream = null
		_stop_audio_players(child)


func _finish() -> void:
	if failures.is_empty():
		print("PICKUP_REGISTRY_COORDINATOR_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
