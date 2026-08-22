extends SceneTree

const COORDINATOR_SCENE := preload(
	"res://scene/game_modes/tower_defense/economy/production/production_coordinator.tscn"
)
const WAREHOUSE_SCENE := preload("res://scene/plant_defense/oak_warehouse.tscn")
const WOOD: PickupConfig = preload(
	"res://resources/config/materials/material_wood.tres"
)
const WATER_BOTTLE: PickupConfig = preload(
	"res://resources/config/materials/material_water_bottle.tres"
)
const APPLE: PickupConfig = preload(
	"res://resources/config/collectibles/collectible_apple.tres"
)
const SIMPLE_FENCE_ITEM: PickupConfig = preload(
	"res://resources/config/buildings/building_simple_fence.tres"
)
const STONE_MILL_ITEM: PickupConfig = preload(
	"res://resources/config/buildings/building_stone_mill.tres"
)

const FIRST_PEER_ID := 11
const SECOND_PEER_ID := 12


class Fixture extends RefCounted:
	var scene_root: Node
	var coordinator: ProductionCoordinator
	var warehouses: Array[OakWarehouse] = []


var failures: Array[String] = []
var warehouse_config: PlantDefenseConfig
var fence_recipe: ProductionRecipe
var stone_mill_recipe: ProductionRecipe


func _initialize() -> void:
	call_deferred(&"_run")


func _run() -> void:
	var run_state := root.get_node_or_null("RunState") as RunStateStore
	warehouse_config = PlantDefenseRegistry.get_config(&"oak_warehouse")
	fence_recipe = SimpleCraftingRegistry.get_recipe(
		SimpleCraftingRegistry.SIMPLE_FENCE_ID
	)
	stone_mill_recipe = SimpleCraftingRegistry.get_recipe(
		SimpleCraftingRegistry.STONE_MILL_ID
	)
	_expect(run_state != null, "测试必须能读取 RunState autoload。")
	_expect(warehouse_config != null, "测试必须能读取完工橡木仓库配置。")
	_expect(fence_recipe != null, "测试必须能读取正式简易围栏配方。")
	_expect(stone_mill_recipe != null, "测试必须能读取正式石磨台配方。")
	if (
		run_state == null
		or warehouse_config == null
		or fence_recipe == null
		or stone_mill_recipe == null
	):
		_finish()
		return

	await _test_local_storage_only(run_state)
	await _test_personal_first_across_two_warehouses(run_state)
	await _test_combined_material_shortage_is_atomic(run_state)
	await _test_stale_inventory_revision_is_atomic(run_state)
	await _test_full_inventory_rolls_back_storage(run_state)
	await _test_target_peer_receives_personal_output(run_state)
	await _test_two_peers_contend_for_last_shared_material(run_state)
	_finish()


func _test_local_storage_only(run_state: RunStateStore) -> void:
	run_state.begin_new_run(&"weishidaier", false)
	var fixture := await _create_fixture(&"LocalStorageOnly", 2)
	var source := fixture.warehouses[0]
	var unrelated := fixture.warehouses[1]
	_expect(
		source.try_add_storage_item_count(WOOD, 1)
		and unrelated.try_add_storage_item_count(APPLE, 1),
		"纯仓库夹具必须能准备制作材料和无关仓库哨兵。"
	)
	var inventory_revision := run_state.get_inventory_revision()
	var source_revision := source.get_storage_revision()
	var unrelated_revision := unrelated.get_storage_revision()
	var unrelated_before := _warehouse_signature(unrelated)
	var result := fixture.coordinator.try_commit_simple_crafting_recipe(
		fence_recipe,
		inventory_revision
	)
	_expect(
		result == RunStateStore.CRAFT_RESULT_SUCCESS
		and run_state.get_inventory_item_total(WOOD) == 0
		and run_state.get_inventory_item_total(SIMPLE_FENCE_ITEM) == 1
		and run_state.get_inventory_revision() == inventory_revision + 1,
		"本地简易制作必须能只消耗共享仓库材料，且产物只进入玩家背包、revision只前进一次。"
	)
	_expect(
		source.get_storage_item_total(WOOD) == 0
		and source.get_storage_revision() == source_revision + 1
		and unrelated.get_storage_revision() == unrelated_revision
		and _warehouse_signature(unrelated) == unrelated_before,
		"纯仓库成功事务必须只让实际扣料仓库的revision前进一步。"
	)
	await _free_fixture(fixture)


func _test_personal_first_across_two_warehouses(
	run_state: RunStateStore
) -> void:
	run_state.begin_new_run(&"weishidaier", false)
	_expect(
		run_state.try_add_item_count(WOOD, 4)
		and run_state.try_add_item_count(WATER_BOTTLE, 2),
		"跨仓夹具必须能准备个人背包材料。"
	)
	var fixture := await _create_fixture(&"PersonalFirstAcrossWarehouses", 3)
	var first := fixture.warehouses[0]
	var second := fixture.warehouses[1]
	var unrelated := fixture.warehouses[2]
	_expect(
		first.try_add_storage_item_count(WOOD, 3)
		and first.try_add_storage_item_count(WATER_BOTTLE, 4)
		and second.try_add_storage_item_count(WOOD, 7)
		and second.try_add_storage_item_count(WATER_BOTTLE, 10)
		and unrelated.try_add_storage_item_count(APPLE, 1),
		"跨仓夹具必须能准备两个共享材料来源和无关仓库哨兵。"
	)
	var inventory_revision := run_state.get_inventory_revision()
	var first_revision := first.get_storage_revision()
	var second_revision := second.get_storage_revision()
	var unrelated_revision := unrelated.get_storage_revision()
	var unrelated_before := _warehouse_signature(unrelated)
	var result := fixture.coordinator.try_commit_simple_crafting_recipe(
		stone_mill_recipe,
		inventory_revision
	)
	_expect(
		result == RunStateStore.CRAFT_RESULT_SUCCESS
		and run_state.get_inventory_item_total(WOOD) == 0
		and run_state.get_inventory_item_total(WATER_BOTTLE) == 0
		and run_state.get_inventory_item_total(STONE_MILL_ITEM) == 1
		and run_state.get_inventory_revision() == inventory_revision + 1,
		"联合制作必须优先扣个人材料、从共享仓库补足缺口，并将产物原子写回个人背包。"
	)
	_expect(
		first.get_storage_item_total(WOOD) == 0
		and first.get_storage_item_total(WATER_BOTTLE) == 0
		and second.get_storage_item_total(WOOD) == 4
		and second.get_storage_item_total(WATER_BOTTLE) == 6
		and first.get_storage_revision() == first_revision + 1
		and second.get_storage_revision() == second_revision + 1,
		"跨两仓扣料必须只消耗个人背包之外的6木头和8水瓶，且每个触及仓库revision只前进一步。"
	)
	_expect(
		unrelated.get_storage_revision() == unrelated_revision
		and _warehouse_signature(unrelated) == unrelated_before,
		"跨仓联合事务不得改写未参与扣料的仓库。"
	)
	await _free_fixture(fixture)


func _test_combined_material_shortage_is_atomic(
	run_state: RunStateStore
) -> void:
	run_state.begin_new_run(&"weishidaier", false)
	_expect(
		run_state.try_add_item_count(WOOD, 4),
		"合计缺料夹具必须能准备个人木头。"
	)
	var fixture := await _create_fixture(&"CombinedShortage", 2)
	var first := fixture.warehouses[0]
	var second := fixture.warehouses[1]
	_expect(
		first.try_add_storage_item_count(WOOD, 3)
		and second.try_add_storage_item_count(WOOD, 2)
		and second.try_add_storage_item_count(WATER_BOTTLE, 10),
		"合计缺料夹具必须能准备不足10份的总木头与完整水瓶。"
	)
	var inventory_revision := run_state.get_inventory_revision()
	var inventory_before := _local_inventory_signature(run_state)
	var first_revision := first.get_storage_revision()
	var second_revision := second.get_storage_revision()
	var first_before := _warehouse_signature(first)
	var second_before := _warehouse_signature(second)
	var result := fixture.coordinator.try_commit_simple_crafting_recipe(
		stone_mill_recipe,
		inventory_revision
	)
	_expect(
		result == RunStateStore.CRAFT_RESULT_MISSING_INPUT
		and run_state.get_inventory_revision() == inventory_revision
		and _local_inventory_signature(run_state) == inventory_before
		and first.get_storage_revision() == first_revision
		and second.get_storage_revision() == second_revision
		and _warehouse_signature(first) == first_before
		and _warehouse_signature(second) == second_before,
		"背包与全部仓库合计缺料时必须零写拒绝，不得部分扣除任何一侧材料。"
	)
	await _free_fixture(fixture)


func _test_stale_inventory_revision_is_atomic(run_state: RunStateStore) -> void:
	run_state.begin_new_run(&"weishidaier", false)
	_expect(run_state.try_add_item(APPLE), "旧revision夹具必须能准备背包哨兵。")
	var fixture := await _create_fixture(&"StaleInventoryRevision", 1)
	var warehouse := fixture.warehouses[0]
	_expect(
		warehouse.try_add_storage_item_count(WOOD, 1),
		"旧revision夹具必须能准备共享木头。"
	)
	var inventory_revision := run_state.get_inventory_revision()
	var inventory_before := _local_inventory_signature(run_state)
	var warehouse_revision := warehouse.get_storage_revision()
	var warehouse_before := _warehouse_signature(warehouse)
	var result := fixture.coordinator.try_commit_simple_crafting_recipe(
		fence_recipe,
		inventory_revision - 1
	)
	_expect(
		result == RunStateStore.CRAFT_RESULT_STALE_REVISION
		and run_state.get_inventory_revision() == inventory_revision
		and _local_inventory_signature(run_state) == inventory_before
		and warehouse.get_storage_revision() == warehouse_revision
		and _warehouse_signature(warehouse) == warehouse_before,
		"旧背包revision必须在共享仓库扣料前零写拒绝。"
	)
	await _free_fixture(fixture)


func _test_full_inventory_rolls_back_storage(run_state: RunStateStore) -> void:
	run_state.begin_new_run(&"weishidaier", false)
	for _slot_index in RunStateStore.INVENTORY_CAPACITY:
		_expect(
			run_state.try_add_item(APPLE),
			"满背包夹具必须能用不可叠加苹果占满每个槽位。"
		)
	var fixture := await _create_fixture(&"FullInventory", 1)
	var warehouse := fixture.warehouses[0]
	_expect(
		warehouse.try_add_storage_item_count(WOOD, 1),
		"满背包夹具必须能在共享仓库准备完整材料。"
	)
	var inventory_revision := run_state.get_inventory_revision()
	var inventory_before := _local_inventory_signature(run_state)
	var warehouse_revision := warehouse.get_storage_revision()
	var warehouse_before := _warehouse_signature(warehouse)
	var result := fixture.coordinator.try_commit_simple_crafting_recipe(
		fence_recipe,
		inventory_revision
	)
	_expect(
		result == RunStateStore.CRAFT_RESULT_INVENTORY_FULL
		and run_state.get_inventory_revision() == inventory_revision
		and _local_inventory_signature(run_state) == inventory_before
		and warehouse.get_storage_revision() == warehouse_revision
		and _warehouse_signature(warehouse) == warehouse_before,
		"材料全在仓库但个人背包已满时必须返回inventory_full，并保持两侧零写。"
	)
	await _free_fixture(fixture)


func _test_target_peer_receives_personal_output(
	run_state: RunStateStore
) -> void:
	run_state.begin_new_run(&"weishidaier", false)
	_expect(
		run_state.register_multiplayer_peer_states(
			PackedInt32Array([FIRST_PEER_ID, SECOND_PEER_ID])
		)
		and run_state.try_add_item(APPLE)
		and run_state.try_add_item_count_for_peer(SECOND_PEER_ID, APPLE, 1),
		"指定Peer夹具必须注册两名玩家并准备本地与另一Peer哨兵。"
	)
	var fixture := await _create_fixture(&"TargetPeerOutput", 1)
	fixture.coordinator.configure_multiplayer_output_peers(
		[FIRST_PEER_ID, SECOND_PEER_ID]
	)
	var warehouse := fixture.warehouses[0]
	_expect(
		warehouse.try_add_storage_item_count(WOOD, 1),
		"指定Peer夹具必须能准备一份共享木头。"
	)
	var local_revision := run_state.get_inventory_revision()
	var local_before := _local_inventory_signature(run_state)
	var target_revision := run_state.get_inventory_revision_for_peer(FIRST_PEER_ID)
	var other_revision := run_state.get_inventory_revision_for_peer(SECOND_PEER_ID)
	var other_before := _peer_inventory_signature(run_state, SECOND_PEER_ID)
	var warehouse_revision := warehouse.get_storage_revision()
	var result := fixture.coordinator.try_commit_simple_crafting_recipe_for_peer(
		FIRST_PEER_ID,
		fence_recipe,
		target_revision
	)
	_expect(
		result == RunStateStore.CRAFT_RESULT_SUCCESS
		and run_state.get_inventory_item_total_for_peer(
			FIRST_PEER_ID,
			SIMPLE_FENCE_ITEM
		) == 1
		and run_state.get_inventory_revision_for_peer(FIRST_PEER_ID)
		== target_revision + 1
		and warehouse.get_storage_item_total(WOOD) == 0
		and warehouse.get_storage_revision() == warehouse_revision + 1,
		"Host为指定Peer提交联合制作时，必须只给目标Peer产物且两侧revision各前进一步。"
	)
	_expect(
		run_state.get_inventory_revision() == local_revision
		and _local_inventory_signature(run_state) == local_before
		and run_state.get_inventory_revision_for_peer(SECOND_PEER_ID)
		== other_revision
		and _peer_inventory_signature(run_state, SECOND_PEER_ID) == other_before,
		"指定Peer联合制作不得串写Host本地背包或其他Peer背包。"
	)
	await _free_fixture(fixture)


func _test_two_peers_contend_for_last_shared_material(
	run_state: RunStateStore
) -> void:
	run_state.begin_new_run(&"weishidaier", false)
	_expect(
		run_state.register_multiplayer_peer_states(
			PackedInt32Array([FIRST_PEER_ID, SECOND_PEER_ID])
		),
		"争抢夹具必须注册两名空背包玩家。"
	)
	var fixture := await _create_fixture(&"PeerContention", 1)
	fixture.coordinator.configure_multiplayer_output_peers(
		[FIRST_PEER_ID, SECOND_PEER_ID]
	)
	var warehouse := fixture.warehouses[0]
	_expect(
		warehouse.try_add_storage_item_count(WOOD, 1),
		"争抢夹具必须只准备最后一份共享木头。"
	)
	var first_revision := run_state.get_inventory_revision_for_peer(FIRST_PEER_ID)
	var second_revision := run_state.get_inventory_revision_for_peer(SECOND_PEER_ID)
	var warehouse_revision := warehouse.get_storage_revision()
	var first_result := (
		fixture.coordinator.try_commit_simple_crafting_recipe_for_peer(
			FIRST_PEER_ID,
			fence_recipe,
			first_revision
		)
	)
	var second_result := (
		fixture.coordinator.try_commit_simple_crafting_recipe_for_peer(
			SECOND_PEER_ID,
			fence_recipe,
			second_revision
		)
	)
	_expect(
		first_result == RunStateStore.CRAFT_RESULT_SUCCESS
		and second_result == RunStateStore.CRAFT_RESULT_MISSING_INPUT
		and warehouse.get_storage_item_total(WOOD) == 0
		and warehouse.get_storage_revision() == warehouse_revision + 1,
		"两个Peer争抢最后一份共享材料时只能首个权威事务成功，仓库revision不得重复推进。"
	)
	_expect(
		run_state.get_inventory_item_total_for_peer(
			FIRST_PEER_ID,
			SIMPLE_FENCE_ITEM
		) == 1
		and run_state.get_inventory_revision_for_peer(FIRST_PEER_ID)
		== first_revision + 1
		and run_state.get_inventory_item_total_for_peer(
			SECOND_PEER_ID,
			SIMPLE_FENCE_ITEM
		) == 0
		and run_state.get_inventory_revision_for_peer(SECOND_PEER_ID)
		== second_revision,
		"争抢失败不得给第二名Peer产物或推进其背包revision。"
	)
	await _free_fixture(fixture)


func _create_fixture(label: StringName, warehouse_count: int) -> Fixture:
	var fixture := Fixture.new()
	fixture.scene_root = Node2D.new()
	fixture.scene_root.name = "%sFixture" % String(label)
	root.add_child(fixture.scene_root)
	fixture.coordinator = COORDINATOR_SCENE.instantiate() as ProductionCoordinator
	fixture.scene_root.add_child(fixture.coordinator)
	for warehouse_index in warehouse_count:
		var warehouse := WAREHOUSE_SCENE.instantiate() as OakWarehouse
		warehouse.name = "Warehouse%d" % (warehouse_index + 1)
		fixture.scene_root.add_child(warehouse)
		fixture.warehouses.append(warehouse)
	await process_frame
	fixture.coordinator.production_tick_timer.stop()
	for warehouse_index in fixture.warehouses.size():
		var warehouse := fixture.warehouses[warehouse_index]
		var net_id := warehouse_index + 1
		warehouse.global_position = Vector2(float(warehouse_index * 16), 0.0)
		warehouse.set_meta(&"net_id", net_id)
		warehouse.setup(
			warehouse_config,
			null,
			[Vector2i(warehouse_index, 0)]
		)
		fixture.coordinator.register_plant(warehouse)
		_expect(
			warehouse.is_operational and not warehouse.is_dead,
			"仓库夹具必须以完工、存活状态注册到ProductionCoordinator。"
		)
	return fixture


func _free_fixture(fixture: Fixture) -> void:
	if fixture != null and fixture.scene_root != null:
		fixture.scene_root.queue_free()
		await process_frame


func _local_inventory_signature(
	run_state: RunStateStore
) -> PackedStringArray:
	var signature := PackedStringArray()
	for slot_index in RunStateStore.INVENTORY_CAPACITY:
		var item := run_state.get_item(slot_index)
		signature.append(
			"%s:%d" % [
				item.resource_path if item != null else "",
				run_state.get_item_count(slot_index),
			]
		)
	return signature


func _peer_inventory_signature(
	run_state: RunStateStore,
	peer_id: int
) -> PackedStringArray:
	var signature := PackedStringArray()
	for slot_index in RunStateStore.INVENTORY_CAPACITY:
		var item := run_state.get_item_for_peer(peer_id, slot_index)
		signature.append(
			"%s:%d" % [
				item.resource_path if item != null else "",
				run_state.get_item_count_for_peer(peer_id, slot_index),
			]
		)
	return signature


func _warehouse_signature(warehouse: OakWarehouse) -> PackedStringArray:
	var signature := PackedStringArray()
	for slot_index in OakWarehouse.STORAGE_CAPACITY:
		var item := warehouse.get_storage_item(slot_index)
		signature.append(
			"%s:%d" % [
				item.resource_path if item != null else "",
				warehouse.get_storage_item_count(slot_index),
			]
		)
	return signature


func _finish() -> void:
	if failures.is_empty():
		print("SIMPLE_CRAFTING_STORAGE_TRANSACTION_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
