extends SceneTree

const COORDINATOR_SCENE := preload(
	"res://scene/game_modes/tower_defense/plant/tower_defense_plant_runtime_coordinator.tscn"
)
const PRODUCTION_BUILDING_SCENE := preload(
	"res://scene/plant_defense/plant_cultivation_center.tscn"
)
const ROOT_SCRIPT_PATH := "res://scene/game_modes/tower_defense/tower_defense_game.gd"
const COORDINATOR_SCRIPT_PATH := (
	"res://scene/game_modes/tower_defense/plant/tower_defense_plant_runtime_coordinator.gd"
)

var failures: Array[String] = []


class ProductionProbe:
	extends ProductionCoordinator
	var events: Array[String]

	func register_plant(_plant: PlantDefense) -> void:
		pass

	func unregister_plant(_plant: PlantDefense) -> void:
		events.append("production_unregister")


class VegetationProbe:
	extends VegetationSpreadSystem
	var events: Array[String]

	func cancel_source(_source_id: int) -> bool:
		events.append("vegetation_cancel")
		return true


class MortarProbe:
	extends BambooMortarCombatSystem

	func request_target(
		_owner: Node2D,
		_minimum_range: float,
		_maximum_range: float,
		_callback: Callable
	) -> bool:
		return true

	func queue_explosion(
		_landing_position: Vector2,
		_inner_radius: float,
		_outer_radius: float,
		_inner_damage: int,
		_outer_damage: int,
		_damage_source_id: int
	) -> bool:
		return true


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	var coordinator := COORDINATOR_SCENE.instantiate() as TowerDefensePlantRuntimeCoordinator
	_expect(coordinator != null, "PlantRuntime 必须由原生 .tscn 实例化。")
	var root_scene := load(
		"res://scene/game_modes/tower_defense/tower_defense_game.tscn"
	) as PackedScene
	var runtime := root_scene.instantiate() as TowerDefenseGame
	_expect(
		runtime.get_node_or_null("PlantRuntimeCoordinator")
			is TowerDefensePlantRuntimeCoordinator,
		"TowerDefenseGame 场景必须静态搭建 PlantRuntimeCoordinator 子节点。"
	)

	var coordinator_source := FileAccess.get_file_as_string(COORDINATOR_SCRIPT_PATH)
	var root_source := FileAccess.get_file_as_string(ROOT_SCRIPT_PATH)
	_expect(
		not coordinator_source.contains("current_scene")
		and not coordinator_source.contains("get_tree()")
		and not coordinator_source.contains("EnemyCoordinator")
		and not coordinator_source.contains("has_method(")
		and not coordinator_source.contains(".call("),
		"PlantRuntime 不得通过场景树、动态调用或 EnemyCoordinator 猜测依赖。"
	)
	_expect(
		not root_source.contains("SharedWarehouseLedgerBridge.persist_to_ledger")
		and not root_source.contains("try_consume_item_at_slot_for_peer_if_revision")
		and not root_source.contains("spawn_multiplayer_replica("),
		"根脚本不得保留 PlantRuntime 的仓库、放置事务或复制算法。"
	)
	_expect(
		TowerDefensePlantRuntimeCoordinator.PLACEMENT_REJECT_INVALID_REQUEST
			== TowerDefensePlantRuntimeCoordinator.PLACEMENT_REJECT_INVALID_REQUEST
		and TowerDefensePlantRuntimeCoordinator.PLACEMENT_REJECT_INVALID_PLAYER
			== TowerDefensePlantRuntimeCoordinator.PLACEMENT_REJECT_INVALID_PLAYER
		and TowerDefensePlantRuntimeCoordinator.PLACEMENT_REJECT_INVALID_CONFIG
			== TowerDefensePlantRuntimeCoordinator.PLACEMENT_REJECT_INVALID_CONFIG
		and TowerDefensePlantRuntimeCoordinator.PLACEMENT_REJECT_INVALID_POSITION
			== TowerDefensePlantRuntimeCoordinator.PLACEMENT_REJECT_INVALID_POSITION
		and TowerDefensePlantRuntimeCoordinator.PLACEMENT_REJECT_INVALID_INVENTORY_ITEM
			== TowerDefensePlantRuntimeCoordinator.PLACEMENT_REJECT_INVALID_INVENTORY_ITEM
		and TowerDefensePlantRuntimeCoordinator.PLACEMENT_REJECT_STALE_INVENTORY
			== TowerDefensePlantRuntimeCoordinator.PLACEMENT_REJECT_STALE_INVENTORY
		and TowerDefensePlantRuntimeCoordinator.PLACEMENT_REJECT_FREE_DISABLED
			== TowerDefensePlantRuntimeCoordinator.PLACEMENT_REJECT_FREE_DISABLED
		and TowerDefensePlantRuntimeCoordinator.PLACEMENT_REJECT_FLOW_LOCKED
			== TowerDefensePlantRuntimeCoordinator.PLACEMENT_REJECT_FLOW_LOCKED,
		"根 façade 必须完整重导出八个稳定 rejection reason。"
	)

	var events: Array[String] = []
	var production := ProductionProbe.new()
	production.events = events
	var vegetation := VegetationProbe.new()
	vegetation.events = events
	var mortar := MortarProbe.new()
	coordinator.setup(
		CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY,
		null,
		vegetation,
		null,
		null
	)
	coordinator.configure_mode_services(
		null, production, null, null, null, null, mortar, 64
	)
	coordinator.plant_removed_for_target_cleanup.connect(
		func(_plant: PlantDefense) -> void: events.append("clear_target")
	)
	coordinator.enemy_retarget_requested.connect(
		func() -> void: events.append("retarget")
	)
	coordinator.removal_presentation_requested.connect(
		func(_plant: PlantDefense) -> void: events.append("presentation")
	)
	coordinator.network_plant_removed.connect(
		func(_net_id: int, _destroyed: bool) -> void: events.append("network_remove")
	)
	var plant := VegetationStake.new()
	plant.config = PlantDefenseConfig.new()
	plant.config.enemy_engagement_mode = PlantDefenseConfig.EnemyEngagementMode.PROACTIVE
	plant.removal_mode = PlantDefense.RemovalMode.ANIMATED
	plant.set_meta(&"net_id", 71)
	coordinator.handle_plant_removed(plant)
	_expect(
		events == [
			"production_unregister",
			"clear_target",
			"retarget",
			"presentation",
			"network_remove",
			"vegetation_cancel",
		],
		"Plant removal 顺序错误：%s" % [events]
	)
	var recipe_building := PRODUCTION_BUILDING_SCENE.instantiate() as ProductionBuilding
	recipe_building.config = PlantDefenseConfig.new()
	recipe_building.config.enemy_engagement_mode = (
		PlantDefenseConfig.EnemyEngagementMode.CONTACT_ONLY
	)
	root.add_child(recipe_building)
	var recipe_notifications := PackedInt32Array([0])
	recipe_building.production_state_changed.connect(
		func(_replicate: bool) -> void: recipe_notifications[0] += 1
	)
	coordinator.handle_plant_placed(recipe_building)
	var before_live_notify := recipe_notifications[0]
	coordinator.notify_recipe_unlocks_changed()
	var live_notified := recipe_notifications[0] == before_live_notify + 1
	recipe_building.removal_mode = PlantDefense.RemovalMode.ANIMATED
	coordinator.handle_plant_removed(recipe_building)
	var before_residual_notify := recipe_notifications[0]
	coordinator.notify_recipe_unlocks_changed()
	var residual_notified := recipe_notifications[0] == before_residual_notify + 1
	root.remove_child(recipe_building)
	recipe_building.free()
	var before_exit_notify := recipe_notifications[0]
	coordinator.notify_recipe_unlocks_changed()
	_expect(
		live_notified
		and residual_notified
		and recipe_notifications[0] == before_exit_notify,
		"recipe notify registry 未保持 live/residual/tree-exit 语义。"
	)
	var ordered_first := PRODUCTION_BUILDING_SCENE.instantiate() as ProductionBuilding
	var ordered_second := PRODUCTION_BUILDING_SCENE.instantiate() as ProductionBuilding
	for building in [ordered_first, ordered_second]:
		building.config = PlantDefenseConfig.new()
		building.config.enemy_engagement_mode = (
			PlantDefenseConfig.EnemyEngagementMode.CONTACT_ONLY
		)
		root.add_child(building)
		coordinator.handle_plant_placed(building)
	var notify_order: Array[String] = []
	ordered_first.production_state_changed.connect(
		func(_replicate: bool) -> void:
			notify_order.append("first")
			if ordered_first.get_parent() != null:
				ordered_first.get_parent().remove_child(ordered_first)
	)
	ordered_second.production_state_changed.connect(
		func(_replicate: bool) -> void: notify_order.append("second")
	)
	coordinator.notify_recipe_unlocks_changed()
	_expect(
		notify_order == ["first", "second"],
		"recipe notify 必须保持放置顺序，并在 callback tree-exit 修改 registry 时仍各通知一次。"
	)
	ordered_first.free()
	root.remove_child(ordered_second)
	ordered_second.free()

	coordinator.set_runtime_mode(CombatRuntimeBase.RuntimeMode.CLIENT_VIEW)
	var mortar_requester := Node2D.new()
	_expect(
		not coordinator.request_bamboo_mortar_target(
			mortar_requester, 1.0, 10.0, func(_target: Enemy) -> void: pass
		)
		and not coordinator.queue_bamboo_mortar_explosion(
			Vector2.ZERO, 1.0, 2.0, 10, 5, 1
		),
		"CLIENT_VIEW 必须在 PlantRuntime 边界拒绝迫击炮选靶与排爆。"
	)
	var tree_less_runtime := TowerDefenseGame.new()
	var tree_less_coordinator := TowerDefensePlantRuntimeCoordinator.new()
	var tree_less_plant_system := PlantSystem.new()
	tree_less_coordinator.name = "PlantRuntimeCoordinator"
	tree_less_runtime.add_child(tree_less_coordinator)
	tree_less_runtime.plant_runtime_coordinator = tree_less_coordinator
	tree_less_coordinator.setup(
		CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY,
		null,
		null,
		tree_less_plant_system,
		null
	)
	var snapshots: Array[Dictionary] = (
		tree_less_coordinator.get_multiplayer_plant_snapshots()
	)
	_expect(snapshots.is_empty(), "tree-less typed plant snapshot 必须安全返回空数组。")

	plant.free()
	production.free()
	vegetation.free()
	mortar.free()
	mortar_requester.free()
	coordinator.free()
	runtime.free()
	tree_less_runtime.free()
	tree_less_plant_system.free()
	if failures.is_empty():
		print("TOWER_DEFENSE_PLANT_RUNTIME_BOUNDARY_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
