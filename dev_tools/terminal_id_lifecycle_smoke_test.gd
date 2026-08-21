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
const MP_GAME_SCRIPT_PATH := "res://scene/multiplayer/mp_game.gd"
const STANDARD_GAME_SCRIPT_PATH := "res://scene/game_modes/standard/standard_game.gd"

const HOST_AUTHORITY := 1
const CLIENT_VIEW := 2
const ENEMY_TERMINAL_DEFEATED := CombatTypes.EnemyTerminalReason.DEFEATED
const ENEMY_TERMINAL_ESCAPED := CombatTypes.EnemyTerminalReason.ESCAPED
const ENEMY_TERMINAL_REMOVED := CombatTypes.EnemyTerminalReason.REMOVED
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
	_test_network_enemy_registry_atomicity()
	_test_network_pickup_registry_atomicity()
	_test_game_enemy_removal_markers()
	_test_runtime_scene_teardown_contract()
	_test_nested_runtime_scene_teardown_propagation()
	_test_mp_game_teardown_order_contract()
	_test_standard_boss_intro_scene_teardown_contract()
	_test_tower_defense_enemy_escape_marker()
	_test_pickup_tree_exit_markers(GAME_SCRIPT.new(), "StandardGame")
	_test_pickup_tree_exit_markers(TOWER_DEFENSE_GAME_SCRIPT.new(), "TowerDefenseGame")
	_test_local_overkill_damage_feedback_value()
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


func _test_network_enemy_registry_atomicity() -> void:
	var runtime := TOWER_DEFENSE_GAME_SCRIPT.new() as CombatRuntimeBase
	var first_enemy := Enemy.new()
	var replacement_enemy := Enemy.new()
	_expect(
		runtime.register_network_enemy(41, first_enemy)
		and runtime.get_network_enemy(41) == first_enemy
		and runtime.get_network_enemy_net_id_by_instance_id(
			first_enemy.get_instance_id()
		) == 41
		and runtime.combat_target_index.get_enemy(41) == first_enemy,
		"网络敌人注册必须原子写入 net、instance 与战斗目标三索引。"
	)
	_expect(
		runtime.register_network_enemy(41, replacement_enemy)
		and runtime.get_network_enemy(41) == replacement_enemy
		and runtime.get_network_enemy_net_id_by_instance_id(
			first_enemy.get_instance_id()
		) == 0,
		"同 net-id 替换必须清理旧实例反向索引。"
	)
	_expect(
		runtime.unregister_network_enemy(41, first_enemy) == null
		and runtime.get_network_enemy(41) == replacement_enemy,
		"旧实例迟到 tree-exit 不得移除同 net-id 的新代理。"
	)
	_expect(
		runtime.register_network_enemy(52, first_enemy)
		and runtime.register_network_enemy(53, first_enemy)
		and not runtime.has_network_enemy(52)
		and runtime.get_network_enemy(53) == first_enemy,
		"同实例迁移 net-id 必须移除旧 net 索引。"
	)
	_expect(
		runtime.unregister_network_enemy_by_instance_id(
			first_enemy.get_instance_id()
		) == 53
		and not runtime.has_network_enemy(53),
		"按 instance-id 移除必须幂等清理双向索引。"
	)
	var freed_enemy := Enemy.new()
	var freed_instance_id := freed_enemy.get_instance_id()
	runtime.register_network_enemy(54, freed_enemy)
	freed_enemy.free()
	_expect(
		runtime.get_network_enemy(54) == null
		and runtime.get_network_enemy_net_id_by_instance_id(freed_instance_id) == 0,
		"已释放敌人查询必须无类型转换错误地清理双向索引。"
	)
	runtime.clear_network_enemy_registry()
	_expect(
		runtime.get_network_enemy_count() == 0
		and runtime.combat_target_index.get_enemy(41) == null,
		"会话级清理必须同时清空网络敌人与战斗目标索引。"
	)
	first_enemy.free()
	replacement_enemy.free()
	runtime.free()


func _test_network_pickup_registry_atomicity() -> void:
	var runtime := GAME_SCRIPT.new() as CombatRuntimeBase
	var first_pickup := Pickup.new()
	var replacement_pickup := Pickup.new()
	_expect(
		runtime.register_network_pickup(61, first_pickup)
		and runtime.get_network_pickup(61) == first_pickup
		and runtime.get_network_pickup_net_id_by_instance_id(
			first_pickup.get_instance_id()
		) == 61,
		"网络拾取物注册必须原子写入 net/instance 双向索引。"
	)
	_expect(
		runtime.register_network_pickup(61, replacement_pickup)
		and runtime.get_network_pickup(61) == replacement_pickup
		and runtime.get_network_pickup_net_id_by_instance_id(
			first_pickup.get_instance_id()
		) == 0,
		"同 net-id 拾取物替换必须清理旧实例反向索引。"
	)
	_expect(
		runtime.unregister_network_pickup(61, first_pickup) == null
		and runtime.get_network_pickup(61) == replacement_pickup,
		"旧拾取物迟到 tree-exit 不得移除同 net-id 的新代理。"
	)
	_expect(
		runtime.register_network_pickup(62, first_pickup)
		and runtime.register_network_pickup(63, first_pickup)
		and not runtime.has_network_pickup(62)
		and runtime.get_network_pickup(63) == first_pickup,
		"同拾取物实例迁移 net-id 必须移除旧 net 索引。"
	)
	var freed_pickup := Pickup.new()
	var freed_instance_id := freed_pickup.get_instance_id()
	runtime.register_network_pickup(64, freed_pickup)
	freed_pickup.free()
	_expect(
		runtime.get_network_pickup(64) == null
		and runtime.get_network_pickup_net_id_by_instance_id(freed_instance_id) == 0,
		"已释放拾取物查询必须无类型转换错误地清理双向索引。"
	)
	runtime.clear_network_pickup_registry()
	_expect(
		runtime.get_network_pickup_count() == 0
		and runtime.get_network_pickup_net_id_by_instance_id(
			first_pickup.get_instance_id()
		) == 0,
		"会话级清理必须同时清空拾取物双向索引。"
	)
	first_pickup.free()
	replacement_pickup.free()
	runtime.free()


func _test_game_enemy_removal_markers() -> void:
	var standard_runtime := GAME_SCRIPT.new() as CombatRuntimeBase
	_prepare_runtime_boundaries(standard_runtime)
	_exercise_enemy_exit_pressure(standard_runtime, "StandardGame")
	var tower_runtime := TOWER_DEFENSE_GAME_SCRIPT.new() as CombatRuntimeBase
	_prepare_runtime_boundaries(tower_runtime)
	_exercise_enemy_exit_pressure(tower_runtime, "TowerDefenseGame")


func _test_runtime_scene_teardown_contract() -> void:
	_exercise_runtime_scene_teardown(GAME_SCRIPT.new(), "StandardGame")
	_exercise_runtime_scene_teardown(
		TOWER_DEFENSE_GAME_SCRIPT.new(),
		"TowerDefenseGame"
	)


func _exercise_runtime_scene_teardown(
	runtime: CombatRuntimeBase,
	label: String
) -> void:
	var gateway := _prepare_runtime_boundaries(runtime)
	runtime.runtime_mode = HOST_AUTHORITY
	var removed_ids: Array[int] = []
	var pickup_removed_ids: Array[int] = []
	gateway.enemy_removed.connect(
		func(net_id: int) -> void: removed_ids.append(net_id)
	)
	gateway.pickup_removed.connect(
		func(net_id: int) -> void: pickup_removed_ids.append(net_id)
	)

	var objective := Enemy.new()
	var auxiliary := Enemy.new()
	var pickup := Pickup.new()
	var objective_id := objective.get_instance_id()
	var auxiliary_id := auxiliary.get_instance_id()
	var attached_count := Callable()
	var removed_count := Callable()
	var objective_registered := false
	var auxiliary_registered := false
	if runtime is TowerDefenseGame:
		var tower_runtime := runtime as TowerDefenseGame
		var campaign := tower_runtime.get_node(
			"CampaignCoordinator"
		) as TowerDefenseCampaignCoordinator
		campaign.reset_wave_progress(1)
		objective_registered = tower_runtime.enemy_coordinator.register_external_enemy(
			objective, WaveEnemyTerminalLedger.EnemyRole.OBJECTIVE
		)
		auxiliary_registered = tower_runtime.enemy_coordinator.register_external_enemy(
			auxiliary, WaveEnemyTerminalLedger.EnemyRole.AUXILIARY
		)
		tower_runtime.enemy_coordinator.add_hud_enemy(objective_id)
		tower_runtime.enemy_coordinator.pending_enemy_configs.append(ENEMY_CONFIG)
		tower_runtime.enemy_coordinator.pending_enemy_xirang_kill_rewards.append(0)
		attached_count = func() -> int:
			return campaign.get_attached_wave_enemy_count()
		removed_count = func() -> int:
			return campaign.current_wave_removed
	else:
		var wave_runtime := runtime as WaveCombatRuntimeBase
		wave_runtime.reset_wave_progress(1)
		objective_registered = wave_runtime.register_active_wave_enemy(objective)
		auxiliary_registered = wave_runtime.register_auxiliary_wave_enemy(auxiliary)
		wave_runtime.pending_enemy_configs.append(ENEMY_CONFIG)
		wave_runtime.pending_enemy_xirang_kill_rewards.append(0)
		attached_count = func() -> int:
			return wave_runtime.wave_enemy_terminal_ledger.get_attached_enemy_count()
		removed_count = func() -> int:
			return wave_runtime.current_wave_removed

	var objective_network_registered := runtime.register_network_enemy(901, objective)
	var auxiliary_network_registered := runtime.register_network_enemy(902, auxiliary)
	var pickup_network_registered := runtime.register_network_pickup(903, pickup)
	_expect(
		objective_registered
		and auxiliary_registered
		and int(attached_count.call()) == 2
		and objective_network_registered
		and auxiliary_network_registered
		and pickup_network_registered
		and runtime.get_network_enemy_count() == 2
		and runtime.get_network_pickup_count() == 1,
		"%s teardown 夹具必须先建立完整的存活实体与网络索引。" % label
	)
	runtime.prepare_for_scene_teardown()
	var removed_after_first_prepare := int(removed_count.call())
	runtime.prepare_for_scene_teardown()
	_expect(
		runtime.is_scene_teardown_prepared()
		and runtime.process_mode == Node.PROCESS_MODE_DISABLED,
		"%s teardown 必须幂等冻结运行时。" % label
	)
	_expect(
		int(attached_count.call()) == 0
		and removed_after_first_prepare == 1
		and int(removed_count.call()) == removed_after_first_prepare,
		"%s teardown 必须静默完成 ACTIVE→REMOVED→DETACHED 且不可重复计数。" % label
	)
	_expect(
		runtime.get_network_enemy_count() == 0
		and runtime.get_network_pickup_count() == 0,
		"%s teardown 必须原子清空敌人与拾取物网络索引。" % label
	)
	_expect(
		removed_ids.is_empty() and pickup_removed_ids.is_empty(),
		"%s 整局 teardown 不得发布逐实体 removed 终结包。" % label
	)
	if runtime is TowerDefenseGame:
		var tower_enemy_coordinator := (
			(runtime as TowerDefenseGame).enemy_coordinator
		)
		tower_enemy_coordinator.handle_wave_enemy_tree_exited(objective_id)
		tower_enemy_coordinator.handle_wave_enemy_tree_exited(auxiliary_id)
		_expect(
			tower_enemy_coordinator.hud_enemy_count() == 0
			and not tower_enemy_coordinator.has_pending_queue(),
			"TowerDefenseGame teardown 必须清空 HUD 与待刷队列。"
		)
	else:
		runtime.call("_on_wave_enemy_tree_exited", objective_id)
		runtime.call("_on_wave_enemy_tree_exited", auxiliary_id)
		_expect(
			not (runtime as WaveCombatRuntimeBase)._has_pending_enemy_configs(),
			"StandardGame teardown 必须清空待刷队列。"
		)
	_expect(
		removed_ids.is_empty(),
		"%s teardown 后的 tree_exited 回放必须是幂等空操作。" % label
	)
	var late_enemy := Enemy.new()
	var late_pickup := Pickup.new()
	var late_domain_registration := false
	if runtime is TowerDefenseGame:
		late_domain_registration = (
			(runtime as TowerDefenseGame).enemy_coordinator.register_external_enemy(
				late_enemy, WaveEnemyTerminalLedger.EnemyRole.AUXILIARY
			)
		)
	else:
		late_domain_registration = (
			(runtime as WaveCombatRuntimeBase).register_auxiliary_wave_enemy(late_enemy)
		)
	_expect(
		not late_domain_registration
		and not runtime.register_network_enemy(904, late_enemy)
		and not runtime.register_network_pickup(905, late_pickup),
		"%s teardown 后必须拒绝新的领域实体和网络索引登记。" % label
	)
	objective.free()
	auxiliary.free()
	pickup.free()
	late_enemy.free()
	late_pickup.free()
	runtime.free()


func _test_nested_runtime_scene_teardown_propagation() -> void:
	var outer_runtime := TOWER_DEFENSE_GAME_SCRIPT.new() as CombatRuntimeBase
	var nested_runtime := GAME_SCRIPT.new() as WaveCombatRuntimeBase
	outer_runtime.add_child(nested_runtime)
	var enemy := Enemy.new()
	nested_runtime.reset_wave_progress(1)
	nested_runtime.register_active_wave_enemy(enemy)
	outer_runtime.prepare_for_scene_teardown()
	_expect(
		nested_runtime.is_scene_teardown_prepared()
		and nested_runtime.current_wave_removed == 1
		and nested_runtime.wave_enemy_terminal_ledger.get_attached_enemy_count() == 0,
		"外层运行时 teardown 必须递归收束内嵌 CombatRuntime。"
	)
	enemy.free()
	outer_runtime.free()


func _test_mp_game_teardown_order_contract() -> void:
	var source := FileAccess.get_file_as_string(MP_GAME_SCRIPT_PATH)
	var entry_index := source.find("func _complete_return_to_lobby() -> void:")
	var entry_source := source.substr(entry_index) if entry_index >= 0 else ""
	var prepare_index := entry_source.find("game.prepare_for_scene_teardown()")
	var reset_index := entry_source.find("player_coordinator.reset_session_state()")
	var scene_change_index := entry_source.find("tree.change_scene_to_file(")
	_expect(
		entry_index >= 0
		and prepare_index >= 0
		and reset_index > prepare_index
		and scene_change_index > reset_index,
		"MpGame 返回大厅必须先 prepare 战斗运行时，再重置会话并切换场景。"
	)


func _test_standard_boss_intro_scene_teardown_contract() -> void:
	var runtime := GAME_SCRIPT.new() as StandardGame
	var intro_boss := Enemy.new()
	var boss_id := intro_boss.get_instance_id()
	runtime.runtime_mode = HOST_AUTHORITY
	_expect(
		runtime.register_network_enemy(906, intro_boss)
		and not runtime.wave_enemy_terminal_ledger.has_enemy(boss_id),
		"Standard Boss 介绍阶段夹具必须保持网络可见、波次账本尚未登记。"
	)
	runtime.prepare_for_scene_teardown()
	runtime._on_boss_enemy_removed(boss_id)
	_expect(
		runtime.get_network_enemy_count() == 0
		and not runtime.wave_enemy_terminal_ledger.has_enemy(boss_id),
		"Standard Boss 介绍阶段退场必须静默清理未登记 Boss。"
	)
	var source := FileAccess.get_file_as_string(STANDARD_GAME_SCRIPT_PATH)
	var handler_index := source.find("func _on_boss_enemy_removed(enemy_id: int) -> void:")
	var handler_source := source.substr(handler_index) if handler_index >= 0 else ""
	var teardown_guard_index := handler_source.find("is_scene_teardown_prepared()")
	var ledger_detach_index := handler_source.find(
		"wave_enemy_terminal_ledger.detach_enemy(enemy_id)"
	)
	_expect(
		handler_index >= 0
		and teardown_guard_index >= 0
		and ledger_detach_index > teardown_guard_index,
		"Standard Boss 退出处理必须先识别场景 teardown，再执行正常期强诊断。"
	)
	intro_boss.free()
	runtime.free()


func _exercise_enemy_exit_pressure(runtime: CombatRuntimeBase, label: String) -> void:
	runtime.runtime_mode = HOST_AUTHORITY
	var gateway := runtime.get_multiplayer_gameplay_gateway()
	var removed_ids: Array[int] = []
	gateway.enemy_removed.connect(
		func(net_id: int) -> void: removed_ids.append(net_id)
	)
	for event_index in range(PRESSURE_EVENT_COUNT):
		var enemy := Enemy.new()
		var instance_id := enemy.get_instance_id()
		var net_id := event_index + 1
		runtime.register_network_enemy(net_id, enemy)
		if runtime is TowerDefenseGame:
			var tower_enemy_coordinator := (
				(runtime as TowerDefenseGame).enemy_coordinator
			)
			tower_enemy_coordinator.register_external_enemy(
				enemy, WaveEnemyTerminalLedger.EnemyRole.AUXILIARY
			)
			tower_enemy_coordinator.handle_wave_enemy_tree_exited(
				instance_id
			)
		else:
			var wave_runtime := runtime as WaveCombatRuntimeBase
			wave_runtime.register_auxiliary_wave_enemy(enemy)
			if event_index % 2 == 0:
				runtime.call("_on_wave_enemy_tree_exited", instance_id)
			else:
				runtime.call("_on_boss_enemy_tree_exited", instance_id)
		enemy.free()
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
	runtime.register_network_enemy(net_id, enemy)
	runtime.enemy_coordinator.register_external_enemy(
		enemy, WaveEnemyTerminalLedger.EnemyRole.AUXILIARY
	)
	_expect(
		runtime.enemy_coordinator.try_resolve_active_enemy_escape(
			enemy_instance_id
		),
		"Escape fixture must commit ESCAPED before presentation removal."
	)
	runtime.enemy_coordinator.emit_multiplayer_enemy_escaped(enemy)
	# Boss 和召唤物共用账本终结原因，不再维护第二份 escape pending 集合。
	runtime.enemy_coordinator.handle_wave_enemy_tree_exited(enemy_instance_id)
	_expect(escaped_ids == [net_id], "Escape must emit its terminal event once.")
	_expect(removed_ids.is_empty(), "Escape tree exit must suppress generic removal.")
	_expect(
		not runtime.enemy_coordinator.active_wave_enemy_ids.has(enemy_instance_id),
		"Escape tree exit must move the ledger entity to DETACHED."
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
	for event_index in range(PRESSURE_EVENT_COUNT):
		var net_id := event_index + 1
		runtime.register_network_pickup(net_id, pickup)
		pickup_registry.handle_multiplayer_pickup_consumed(pickup, 2, true)
		pickup_registry.handle_multiplayer_pickup_tree_exited(net_id)
	_expect(
		removed_ids.is_empty(),
		"%s consumed pickups must not publish a competing generic removal." % label
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
	runtime.register_network_pickup(spontaneous_net_id, pickup)
	pickup_registry.handle_multiplayer_pickup_tree_exited(spontaneous_net_id)
	_expect(
		removed_ids.size() == 1,
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
		runtime,
		gateway,
		enemy_container,
		boss_container
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
		runtime,
		gateway,
		runtime.get_node("EnemyContainer") as Node2D,
		runtime.get_node("BossContainer") as Node2D
	)
	return registry


func _attach_enemy_coordinator(
	mp_game: RecordingMpGame
) -> MpEnemyCoordinator:
	var coordinator := MpEnemyCoordinator.new()
	coordinator.name = "EnemyCoordinator"
	mp_game.add_child(coordinator)
	mp_game.enemy_coordinator = coordinator
	coordinator.lifecycle_rpc_broadcast_requested.connect(
		mp_game._on_enemy_lifecycle_rpc_broadcast_requested
	)
	return coordinator


func _test_host_terminal_pairing_cache() -> void:
	var enemy_coordinator := MpEnemyCoordinator.new()
	var sent_reasons: Array[int] = []
	var terminal := enemy_coordinator.build_host_terminal_event(
		1,
		ENEMY_TERMINAL_DEFEATED,
		Vector2.ZERO
	)
	if not terminal.is_empty():
		sent_reasons.append(int(terminal.get("reason", -1)))
	terminal = enemy_coordinator.build_host_terminal_event(
		1,
		ENEMY_TERMINAL_DEFEATED,
		Vector2.ZERO
	)
	if not terminal.is_empty():
		sent_reasons.append(int(terminal.get("reason", -1)))
	_expect(
		sent_reasons == [ENEMY_TERMINAL_DEFEATED],
		"Duplicate defeated event must remain suppressed while removal is pending."
	)
	enemy_coordinator.build_host_terminal_event(
		1,
		ENEMY_TERMINAL_REMOVED,
		Vector2.ZERO
	)
	_expect(
		enemy_coordinator.host_terminal_enemy_ids.is_empty(),
		"Generic removal must consume the pending defeated marker."
	)

	sent_reasons.clear()
	for event_index in range(PRESSURE_EVENT_COUNT):
		var net_id := event_index + 10
		terminal = enemy_coordinator.build_host_terminal_event(
			net_id,
			ENEMY_TERMINAL_DEFEATED,
			Vector2.ZERO
		)
		if not terminal.is_empty():
			sent_reasons.append(int(terminal.get("reason", -1)))
		enemy_coordinator.build_host_terminal_event(
			net_id,
			ENEMY_TERMINAL_REMOVED,
			Vector2.ZERO
		)
	_expect(
		enemy_coordinator.host_terminal_enemy_ids.is_empty(),
		"Thousands of defeated→removed pairs must leave no Host terminal IDs."
	)
	_expect(
		sent_reasons.size() == PRESSURE_EVENT_COUNT,
		"Defeated→removed pairs must send only the defeated terminal event."
	)

	sent_reasons.clear()
	for event_index in range(PRESSURE_EVENT_COUNT):
		var net_id := event_index + 20_000
		terminal = enemy_coordinator.build_host_terminal_event(
			net_id,
			ENEMY_TERMINAL_REMOVED,
			Vector2.ZERO
		)
		if not terminal.is_empty():
			sent_reasons.append(int(terminal.get("reason", -1)))
		terminal = enemy_coordinator.build_host_terminal_event(
			net_id,
			ENEMY_TERMINAL_ESCAPED,
			Vector2.ZERO
		)
		if not terminal.is_empty():
			sent_reasons.append(int(terminal.get("reason", -1)))
	_expect(
		enemy_coordinator.host_terminal_enemy_ids.is_empty(),
		"Direct removed/escaped terminals must never allocate Host tombstones."
	)
	_expect(
		sent_reasons.size() == PRESSURE_EVENT_COUNT * 2,
		"Direct removed/escaped terminal sends must remain intact."
	)
	enemy_coordinator.free()


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
		runtime.get_network_enemy_count() == 0,
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


func _test_local_overkill_damage_feedback_value() -> void:
	var runtime := TerminalTowerRuntime.new()
	_prepare_runtime_boundaries(runtime)
	var enemy := ENEMY_SCENE.instantiate() as Enemy
	if enemy == null:
		_expect(false, "本地过量伤害反馈必须能实例化敌人。")
		runtime.free()
		return
	root.add_child(enemy)
	var overkill_config := ENEMY_CONFIG.duplicate(true) as EnemyConfig
	overkill_config.max_health = 1
	overkill_config.physical_defense = 1000
	overkill_config.xirang_kill_reward = 0
	overkill_config.drop_table = null
	enemy.setup(overkill_config, null, null, runtime)
	enemy.add_damage_taken_multiplier_modifier(88001, 0.5)
	enemy.set_process(false)
	enemy.set_physics_process(false)
	var result := enemy.apply_combat_damage(DamageRequest.new(
		10000,
		CombatTypes.DamageType.PHYSICAL
	))
	_expect(
		result.requested_amount == 10000
		and result.mitigated_damage == 9000
		and result.resolved_damage == 4500
		and result.applied_damage == 1
		and enemy.last_damage_taken == 1
		and runtime.amount == 4500,
		"伤害浮字必须显示防御与承伤倍率后的完整4500点结算伤害，不能显示原始10000或实际扣除的1点生命。"
	)
	root.remove_child(enemy)
	enemy.free()
	runtime.free()


func _test_reliable_terminal_feedback_payload() -> void:
	var enemy_coordinator := MpEnemyCoordinator.new()
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
	runtime.register_network_enemy(net_id, enemy)
	enemy_coordinator.bind_runtime(runtime)
	enemy_coordinator.pending_enemy_damage_feedback[net_id] = {
		"current_health": 10,
		"damage": 15,
		"impact_direction": Vector2.LEFT,
		"damage_type": int(EnemyConfig.DamageType.MAGIC),
		"presentation_flags": CombatTypes.DamageFeedbackFlag.DIRECT_HIT_FLASH,
	}
	enemy_coordinator.active_enemy_damage_feedback_context[net_id] = {
		"impact_direction": Vector2.RIGHT,
		"damage_type": int(EnemyConfig.DamageType.PHYSICAL),
		"presentation_flags": (
			CombatTypes.DamageFeedbackFlag.HIT_PARTICLES
			| CombatTypes.DamageFeedbackFlag.DIRECT_HIT_FLASH
		),
	}
	var terminal := enemy_coordinator.build_host_terminal_event(
		net_id,
		ENEMY_TERMINAL_DEFEATED,
		Vector2(12.0, 8.0)
	)
	_expect(
		int(terminal.get("net_id", 0)) == net_id
		and int(terminal.get("reason", -1)) == ENEMY_TERMINAL_DEFEATED
		and terminal.get("event_position", Vector2.ZERO) == Vector2(12.0, 8.0)
		and int(terminal.get("current_health", -1)) == 0
		and int(terminal.get("health_revision", -1)) == enemy.health_revision
		and int(terminal.get("damage", 0)) == 40
		and terminal.get("impact_direction", Vector2.ZERO) == Vector2.RIGHT
		and int(terminal.get("damage_type", -1))
		== int(EnemyConfig.DamageType.PHYSICAL)
		and int(terminal.get("presentation_flags", 0)) == 3,
		"可靠终结事件必须合并未发送的15点反馈与最后25点致死伤害，并携带最终方向、类型和粒子/闪红表现位。"
	)
	_expect(
		not enemy_coordinator.pending_enemy_damage_feedback.has(net_id),
		"致死反馈并入可靠终结事件后必须从不可靠批队列移除，避免重复浮字。"
	)
	runtime.clear_network_enemy_registry()
	enemy_coordinator.clear_active_damage_feedback_context(net_id)
	enemy.free()
	runtime.free()
	enemy_coordinator.free()


func _test_real_batch_damage_terminal_chain() -> void:
	var enemy_coordinator := MpEnemyCoordinator.new()
	root.add_child(enemy_coordinator)
	var net_manager_stub := HostNetManagerStub.new()
	var runtime := TerminalTowerRuntime.new()
	var gateway := _prepare_runtime_boundaries(runtime)
	runtime.runtime_mode = HOST_AUTHORITY
	enemy_coordinator.bind_runtime(runtime)
	enemy_coordinator.bind_lifecycle_dependencies(
		net_manager_stub,
		gateway,
		func() -> float: return 0.0
	)
	var terminal_capture: Dictionary = {"args": []}
	enemy_coordinator.lifecycle_rpc_broadcast_requested.connect(
		func(method_name: StringName, arguments: Array) -> void:
			if method_name == &"net_enemy_terminal":
				terminal_capture["args"] = arguments.duplicate(true)
	)
	var enemy := ENEMY_SCENE.instantiate() as Enemy
	if enemy == null:
		_expect(false, "真实批伤终结链必须能实例化敌人。")
		root.remove_child(enemy_coordinator)
		enemy_coordinator.free()
		runtime.free()
		net_manager_stub.free()
		return
	root.add_child(enemy)
	var lethal_config := ENEMY_CONFIG.duplicate(true) as EnemyConfig
	lethal_config.max_health = 1
	lethal_config.physical_defense = 0
	lethal_config.xirang_kill_reward = 0
	lethal_config.drop_table = null
	enemy.setup(lethal_config, null, null, runtime)
	enemy.set_process(false)
	enemy.set_physics_process(false)
	var net_id := 707
	runtime.register_network_enemy(net_id, enemy)
	enemy.defeated.connect(
		func(defeated_enemy: Enemy) -> void:
			gateway.enemy_defeated.emit(net_id, defeated_enemy.global_position)
	)
	enemy_coordinator.set_active_damage_feedback_context(
		net_id,
		Vector2.RIGHT,
		EnemyConfig.DamageType.PHYSICAL,
		(
			CombatTypes.DamageFeedbackFlag.HIT_PARTICLES
			| CombatTypes.DamageFeedbackFlag.DIRECT_HIT_FLASH
		)
	)
	var lethal_batch := DamageBatchRequest.new(
		PackedInt64Array([10000]),
		PackedInt32Array([1]),
		CombatTypes.DamageType.PHYSICAL
	)
	lethal_batch.with_directions(Vector2.RIGHT)
	var result := enemy.apply_combat_damage(lethal_batch)
	enemy_coordinator.clear_active_damage_feedback_context(net_id)
	var args := terminal_capture.get("args", []) as Array
	_expect(
		result.accepted
		and result.resolved_damage == 10000
		and result.applied_damage == 1
		and enemy.is_dead
		and runtime.amount == 10000
		and args.size() == 9
		and int(args[0]) == net_id
		and int(args[1]) == ENEMY_TERMINAL_DEFEATED
		and int(args[3]) == 0
		and int(args[4]) == enemy.health_revision
		and int(args[5]) == 10000
		and args[6] == Vector2.RIGHT
		and int(args[7]) == int(EnemyConfig.DamageType.PHYSICAL)
		and int(args[8]) == 3,
		"1生命敌人受到10000点伤害时，本地浮字和可靠terminal都必须携带完整结算伤害，生命扣除仍只能为1。"
	)
	_expect(
		not enemy_coordinator.pending_enemy_damage_feedback.has(net_id)
		and not enemy_coordinator.active_enemy_damage_feedback_context.has(net_id),
		"真实致死批伤结束后不得遗留不可靠反馈或活动伤害上下文。"
	)
	if args.size() != 9:
		runtime.clear_network_enemy_registry()
		root.remove_child(enemy)
		enemy.free()
		root.remove_child(enemy_coordinator)
		enemy_coordinator.free()
		runtime.free()
		net_manager_stub.free()
		return
	var client_enemy_coordinator := MpEnemyCoordinator.new()
	var client_runtime := TerminalTowerRuntime.new()
	_prepare_runtime_boundaries(client_runtime)
	client_runtime.runtime_mode = CLIENT_VIEW
	client_enemy_coordinator.bind_runtime(client_runtime)
	var client_enemy := ENEMY_SCENE.instantiate() as Enemy
	root.add_child(client_enemy)
	client_enemy.setup(lethal_config, null, null, client_runtime)
	client_enemy.configure_multiplayer_proxy()
	client_enemy_coordinator.register_client_enemy(net_id, client_enemy, 0.0)
	client_enemy_coordinator.receive_enemy_terminal(
		int(args[0]),
		int(args[1]),
		args[2] as Vector2,
		int(args[3]),
		int(args[4]),
		int(args[5]),
		args[6] as Vector2,
		int(args[7]),
		int(args[8])
	)
	_expect(
		client_enemy.is_dead
		and client_enemy.current_health == 0
		and client_enemy_coordinator.get_client_enemy(net_id) == null
		and not client_runtime.has_network_enemy(net_id)
		and client_runtime.amount == 10000
		and client_runtime.impact_direction == Vector2.RIGHT
		and client_runtime.damage_type
		== int(EnemyConfig.DamageType.PHYSICAL),
		"客户端消费九参数可靠terminal时必须先显示完整10000点伤害、应用0生命，再执行死亡移除。"
	)
	runtime.clear_network_enemy_registry()
	root.remove_child(enemy)
	enemy.free()
	root.remove_child(enemy_coordinator)
	enemy_coordinator.free()
	runtime.free()
	net_manager_stub.free()
	if is_instance_valid(client_enemy):
		if client_enemy.get_parent() != null:
			client_enemy.get_parent().remove_child(client_enemy)
		client_enemy.free()
	client_runtime.free()
	client_enemy_coordinator.free()


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
