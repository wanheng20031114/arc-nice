extends SceneTree

const PROFILE_PANEL_SCENE := preload(
	"res://scene/game_modes/standard/ui/standard_player_profile_panel.tscn"
)
const SIMPLE_CRAFTING_PANEL_SCENE := preload(
	"res://scene/ui/shared/crafting/simple_crafting_panel.tscn"
)
const RESEARCH_COORDINATOR_SCENE := preload(
	"res://scene/plant_defense/research_coordinator.tscn"
)
const MP_GAME_SCRIPT := preload("res://scene/multiplayer/mp_game.gd")
const PLAYER_SCENE := preload(
	"res://scene/player/weishidaier/player_weishidaier.tscn"
)
const SAPLING := preload(
	"res://resources/config/materials/material_sapling.tres"
)
const WATER_BOTTLE := preload(
	"res://resources/config/materials/material_water_bottle.tres"
)
const GEL := preload(
	"res://resources/config/materials/material_gel.tres"
)
const WOOD := preload(
	"res://resources/config/materials/material_wood.tres"
)
const PLANK := preload(
	"res://resources/config/materials/material_plank.tres"
)
const WOODEN_CORE := preload(
	"res://resources/config/materials/material_wooden_core.tres"
)
const CAPOO_BLUE_CRYSTAL_POWDER := preload(
	"res://resources/config/materials/material_capoo_blue_crystal_powder.tres"
)
const HEALTH_PICKUP := preload(
	"res://resources/config/pickups/pickup_health.tres"
)
const WOOD_PROCESSING_STATION_ITEM := preload(
	"res://resources/config/buildings/building_wood_processing_station.tres"
)
const STONE_MILL_ITEM := preload(
	"res://resources/config/buildings/building_stone_mill.tres"
)
const SIMPLE_FENCE_ITEM := preload(
	"res://resources/config/buildings/building_simple_fence.tres"
)
const OAK_WAREHOUSE_ITEM := preload(
	"res://resources/config/buildings/building_oak_warehouse.tres"
)
const VEGETATION_STAKE_ITEM := preload(
	"res://resources/config/buildings/building_vegetation_stake.tres"
)
const BAMBOO_MORTAR_ITEM := preload(
	"res://resources/config/buildings/building_bamboo_mortar.tres"
)
const HYDRANGEA_RAIN_TOWER_ITEM := preload(
	"res://resources/config/buildings/building_hydrangea_rain_tower.tres"
)
const APPLE := preload(
	"res://resources/config/collectibles/collectible_apple.tres"
)

var failures: Array[String] = []
var inventory_change_count := 0
var panel_request_tokens: Array[int] = []
var panel_cancelled_tokens: Array[int] = []


class MultiplayerCraftSceneStub:
	extends Node2D

	var requests: Array[Dictionary] = []
	var cancelled_tokens: Array[int] = []

	func request_multiplayer_simple_crafting(
		recipe_id: StringName,
		request_token: int
	) -> void:
		requests.append({
			"recipe_id": recipe_id,
			"request_token": request_token,
		})

	func cancel_multiplayer_simple_crafting_request(
		request_token: int
	) -> void:
		cancelled_tokens.append(request_token)


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var run_state := root.get_node("RunState") as RunStateStore
	run_state.inventory_changed.connect(_on_inventory_changed)

	_test_registry_contract(run_state)
	_test_gel_to_water_bottle_transaction(run_state)
	_test_building_recipe_transactions(run_state)
	_test_research_locked_recipe_transactions(run_state)
	_test_local_atomic_success(run_state)
	_test_missing_input_is_atomic(run_state)
	_test_stale_revision_is_atomic(run_state)
	_test_full_inventory_is_atomic(run_state)
	_test_consumed_inputs_can_free_output_space(run_state)
	_test_peer_atomic_success(run_state)
	_test_multiplayer_request_token_tracking()
	await _test_health_potion_stack_and_use(run_state)
	await _test_simple_crafting_ui(run_state)

	if run_state.inventory_changed.is_connected(_on_inventory_changed):
		run_state.inventory_changed.disconnect(_on_inventory_changed)
	run_state.begin_new_run(&"weishidaier")

	if failures.is_empty():
		print("SIMPLE_CRAFTING_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_registry_contract(run_state: RunStateStore) -> void:
	var recipe := SimpleCraftingRegistry.get_recipe(
		SimpleCraftingRegistry.HERBAL_HEALTH_POTION_ID
	)
	var wood_station_recipe := SimpleCraftingRegistry.get_recipe(
		SimpleCraftingRegistry.WOOD_PROCESSING_STATION_ID
	)
	var oak_warehouse_recipe := SimpleCraftingRegistry.get_recipe(
		SimpleCraftingRegistry.OAK_WAREHOUSE_ID
	)
	var vegetation_stake_recipe := SimpleCraftingRegistry.get_recipe(
		SimpleCraftingRegistry.VEGETATION_STAKE_ID
	)
	var stone_mill_recipe := SimpleCraftingRegistry.get_recipe(
		SimpleCraftingRegistry.STONE_MILL_ID
	)
	var bamboo_mortar_recipe := SimpleCraftingRegistry.get_recipe(
		SimpleCraftingRegistry.BAMBOO_MORTAR_ID
	)
	var hydrangea_recipe := SimpleCraftingRegistry.get_recipe(
		SimpleCraftingRegistry.HYDRANGEA_RAIN_TOWER_ID
	)
	var simple_fence_recipe := SimpleCraftingRegistry.get_recipe(
		SimpleCraftingRegistry.SIMPLE_FENCE_ID
	)
	var gel_to_water_bottle_recipe := SimpleCraftingRegistry.get_recipe(
		SimpleCraftingRegistry.GEL_TO_WATER_BOTTLE_ID
	)
	_expect(recipe != null, "简易制造白名单必须能解析草药生命药瓶配方。")
	_expect(
		wood_station_recipe != null
		and oak_warehouse_recipe != null
		and vegetation_stake_recipe != null
		and stone_mill_recipe != null
		and bamboo_mortar_recipe != null
		and hydrangea_recipe != null
		and simple_fence_recipe != null
		and gel_to_water_bottle_recipe != null,
		"简易制造白名单必须能解析七条基础配方及两条科研解锁配方。"
	)
	if (
		recipe == null
		or wood_station_recipe == null
		or oak_warehouse_recipe == null
		or vegetation_stake_recipe == null
		or stone_mill_recipe == null
		or bamboo_mortar_recipe == null
		or hydrangea_recipe == null
		or simple_fence_recipe == null
		or gel_to_water_bottle_recipe == null
	):
		return
	_expect(
		SimpleCraftingRegistry.get_recipe(&"unknown_simple_recipe") == null,
		"未登记的配方ID不得进入简易制造白名单。"
	)
	_expect(
		SimpleCraftingRegistry.get_recipe_by_wire_id(
			String(SimpleCraftingRegistry.HERBAL_HEALTH_POTION_ID)
		) == recipe
		and SimpleCraftingRegistry.get_recipe_by_wire_id(
			String(SimpleCraftingRegistry.WOOD_PROCESSING_STATION_ID)
		) == wood_station_recipe
		and SimpleCraftingRegistry.get_recipe_by_wire_id(
			String(SimpleCraftingRegistry.OAK_WAREHOUSE_ID)
		) == oak_warehouse_recipe
		and SimpleCraftingRegistry.get_recipe_by_wire_id(
			String(SimpleCraftingRegistry.VEGETATION_STAKE_ID)
		) == vegetation_stake_recipe
		and SimpleCraftingRegistry.get_recipe_by_wire_id(
			String(SimpleCraftingRegistry.STONE_MILL_ID)
		) == stone_mill_recipe
		and SimpleCraftingRegistry.get_recipe_by_wire_id(
			String(SimpleCraftingRegistry.SIMPLE_FENCE_ID)
		) == simple_fence_recipe
		and SimpleCraftingRegistry.get_recipe_by_wire_id(
			String(SimpleCraftingRegistry.GEL_TO_WATER_BOTTLE_ID)
		) == gel_to_water_bottle_recipe
		and SimpleCraftingRegistry.get_recipe_by_wire_id(
			String(SimpleCraftingRegistry.BAMBOO_MORTAR_ID)
		) == bamboo_mortar_recipe
		and SimpleCraftingRegistry.get_recipe_by_wire_id(
			String(SimpleCraftingRegistry.HYDRANGEA_RAIN_TOWER_ID)
		) == hydrangea_recipe
		and SimpleCraftingRegistry.get_recipe_by_wire_id(
			"x".repeat(SimpleCraftingRegistry.MAX_WIRE_RECIPE_ID_LENGTH + 1)
		) == null,
		"多人配方ID必须只按有界字符串解析，不得接受超长网络输入。"
	)
	var registered_recipes := SimpleCraftingRegistry.get_all_recipes()
	_expect(
		registered_recipes.size() == 9
		and registered_recipes[0] == recipe
		and registered_recipes[1] == wood_station_recipe
		and registered_recipes[2] == oak_warehouse_recipe
		and registered_recipes[3] == vegetation_stake_recipe
		and registered_recipes[4] == stone_mill_recipe
		and registered_recipes[5] == simple_fence_recipe
		and registered_recipes[6] == gel_to_water_bottle_recipe
		and registered_recipes[7] == bamboo_mortar_recipe
		and registered_recipes[8] == hydrangea_recipe,
		"简易制造注册表必须按固定顺序保留七条基础配方与两条科研配方。"
	)
	var bamboo_completed_ids: Array[StringName] = [
		GlobalResearchRegistry.BAMBOO_MORTAR_CRAFTING_ID,
	]
	var all_crafting_research_ids: Array[StringName] = [
		GlobalResearchRegistry.BAMBOO_MORTAR_CRAFTING_ID,
		GlobalResearchRegistry.HYDRANGEA_RAIN_TOWER_CRAFTING_ID,
	]
	var default_available_recipes := SimpleCraftingRegistry.get_available_recipes()
	var bamboo_available_recipes := SimpleCraftingRegistry.get_available_recipes(
		bamboo_completed_ids
	)
	var all_available_recipes := SimpleCraftingRegistry.get_available_recipes(
		all_crafting_research_ids
	)
	_expect(
		default_available_recipes.size() == 7
		and default_available_recipes[4] == stone_mill_recipe
		and default_available_recipes[5] == simple_fence_recipe
		and default_available_recipes[6] == gel_to_water_bottle_recipe
		and bamboo_available_recipes.size() == 8
		and bamboo_available_recipes[6] == gel_to_water_bottle_recipe
		and bamboo_available_recipes[7] == bamboo_mortar_recipe
		and all_available_recipes.size() == 9
		and all_available_recipes[8] == hydrangea_recipe,
		"未研发时只能看到七条基础配方，完成对应科研后必须依次扩展为八条和九条。"
	)
	for registered_recipe in registered_recipes:
		_expect(
			registered_recipe.inputs_from_player_inventory()
			and registered_recipe.outputs_to_player_inventory()
			and not registered_recipe.uses_environment_source(),
			"简易制造必须只从玩家背包取材，并把产物放回玩家背包。"
		)
	_expect(
		recipe.input_items == [SAPLING, WATER_BOTTLE]
		and recipe.input_amounts == [1, 1]
		and recipe.output_items == [HEALTH_PICKUP]
		and recipe.output_amounts == [1],
		"草药生命药瓶配方必须消耗1树苗和1水瓶并产出1生命药瓶。"
	)
	_expect(
		gel_to_water_bottle_recipe.input_items == [GEL]
		and gel_to_water_bottle_recipe.input_amounts == [1]
		and gel_to_water_bottle_recipe.output_items == [WATER_BOTTLE]
		and gel_to_water_bottle_recipe.output_amounts == [1]
		and is_equal_approx(gel_to_water_bottle_recipe.duration_seconds, 0.1),
		"凝胶制水瓶配方必须以0.1秒合法占位时长瞬间将1凝胶转化为1水瓶。"
	)
	_expect(
		HEALTH_PICKUP.stackable
		and HEALTH_PICKUP.inventory_stack_limit == 999
		and HEALTH_PICKUP.heal_amount == 20,
		"生命药瓶必须可堆叠至999，并且每次恢复20点生命。"
	)
	_expect(
		wood_station_recipe.input_items == [WOOD]
		and wood_station_recipe.input_amounts == [5]
		and wood_station_recipe.output_items == [WOOD_PROCESSING_STATION_ITEM]
		and wood_station_recipe.output_amounts == [1],
		"木头加工站配方必须消耗5木头并产出1个木头加工站建筑物品。"
	)
	_expect(
		oak_warehouse_recipe.input_items == [WOOD]
		and oak_warehouse_recipe.input_amounts == [10]
		and oak_warehouse_recipe.output_items == [OAK_WAREHOUSE_ITEM]
		and oak_warehouse_recipe.output_amounts == [1],
		"橡木仓库配方必须消耗10木头并产出1个橡木仓库建筑物品。"
	)
	_expect(
		vegetation_stake_recipe.input_items == [PLANK, SAPLING]
		and vegetation_stake_recipe.input_amounts == [10, 1]
		and vegetation_stake_recipe.output_items == [VEGETATION_STAKE_ITEM]
		and vegetation_stake_recipe.output_amounts == [1],
		"植被桩配方必须消耗10木板和1树苗并产出1个植被桩建筑物品。"
	)
	_expect(
		stone_mill_recipe.is_valid()
		and stone_mill_recipe.input_items == [WOOD, WATER_BOTTLE]
		and stone_mill_recipe.input_amounts == [10, 10]
		and stone_mill_recipe.output_items == [STONE_MILL_ITEM]
		and stone_mill_recipe.output_amounts == [1]
		and is_equal_approx(stone_mill_recipe.duration_seconds, 0.1),
		"石磨台配方必须以0.1秒合法占位时长消耗10木头和10水瓶，并产出1个石磨台建筑物品。"
	)
	_expect(
		bamboo_mortar_recipe.is_valid()
		and bamboo_mortar_recipe.input_items == [WOODEN_CORE, PLANK]
		and bamboo_mortar_recipe.input_amounts == [1, 10]
		and bamboo_mortar_recipe.output_items == [BAMBOO_MORTAR_ITEM]
		and bamboo_mortar_recipe.output_amounts == [1]
		and is_equal_approx(bamboo_mortar_recipe.duration_seconds, 0.1)
		and bamboo_mortar_recipe.required_global_research_id
		== GlobalResearchRegistry.BAMBOO_MORTAR_CRAFTING_ID,
		"竹筒迫击炮简易配方必须消耗1木制核心和10木板，并由对应全局科研解锁。"
	)
	_expect(
		hydrangea_recipe.is_valid()
		and hydrangea_recipe.input_items
		== [WOODEN_CORE, CAPOO_BLUE_CRYSTAL_POWDER]
		and hydrangea_recipe.input_amounts == [2, 1]
		and hydrangea_recipe.output_items == [HYDRANGEA_RAIN_TOWER_ITEM]
		and hydrangea_recipe.output_amounts == [1]
		and is_equal_approx(hydrangea_recipe.duration_seconds, 0.1)
		and hydrangea_recipe.required_global_research_id
		== GlobalResearchRegistry.HYDRANGEA_RAIN_TOWER_CRAFTING_ID,
		"紫阳花雨幕塔简易配方必须消耗2木制核心和1卡普蓝晶粉，并由对应全局科研解锁。"
	)
	_expect(
		simple_fence_recipe.is_valid()
		and simple_fence_recipe.input_items == [WOOD]
		and simple_fence_recipe.input_amounts == [1]
		and simple_fence_recipe.output_items == [SIMPLE_FENCE_ITEM]
		and simple_fence_recipe.output_amounts == [1]
		and is_equal_approx(simple_fence_recipe.duration_seconds, 0.1),
		"简易围栏配方必须以0.1秒合法占位时长消耗1木头，并立即产出1个简易围栏。"
	)
	_expect(
		_is_valid_unstackable_building_item(
			WOOD_PROCESSING_STATION_ITEM,
			&"wood_processing_station"
		)
		and _is_valid_unstackable_building_item(
			OAK_WAREHOUSE_ITEM,
			&"oak_warehouse"
		)
		and _is_valid_unstackable_building_item(
			VEGETATION_STAKE_ITEM,
			&"vegetation_stake"
		)
		and _is_valid_unstackable_building_item(
			STONE_MILL_ITEM,
			&"stone_mill"
		)
		and _is_valid_unstackable_building_item(
			BAMBOO_MORTAR_ITEM,
			&"bamboo_mortar"
		)
		and _is_valid_unstackable_building_item(
			HYDRANGEA_RAIN_TOWER_ITEM,
			&"hydrangea_rain_tower"
		)
		and _is_valid_stackable_building_item(
			SIMPLE_FENCE_ITEM,
			&"simple_fence"
		),
		"七种简易制造建筑产物必须复用原图、以32×32有效尺寸显示并指向正确建筑；围栏须可堆叠至999。"
	)

	var shared_storage_recipe := recipe.duplicate() as ProductionRecipe
	shared_storage_recipe.input_source = ProductionRecipe.InputSource.SHARED_STORAGE
	run_state.begin_new_run(&"weishidaier")
	_expect(
		run_state.get_simple_crafting_result(shared_storage_recipe)
		== RunStateStore.CRAFT_RESULT_INVALID_RECIPE,
		"共享仓库配方不得绕过白名单语义进入个人简易制造。"
	)
	var forged_recipe := recipe.duplicate() as ProductionRecipe
	_expect(
		run_state.get_simple_crafting_result(forged_recipe)
		== RunStateStore.CRAFT_RESULT_INVALID_RECIPE,
		"即使字段与ID相同，非白名单资源也不得进入简易制造事务。"
	)


func _test_gel_to_water_bottle_transaction(run_state: RunStateStore) -> void:
	var recipe := SimpleCraftingRegistry.get_recipe(
		SimpleCraftingRegistry.GEL_TO_WATER_BOTTLE_ID
	)
	if recipe == null:
		return
	run_state.begin_new_run(&"weishidaier")
	_expect(
		run_state.try_add_item_count(GEL, 1),
		"凝胶制水瓶事务测试必须能准备1份凝胶。"
	)
	var revision_before := run_state.get_inventory_revision()
	inventory_change_count = 0
	var result := run_state.try_craft_inventory_recipe_if_revision(
		recipe,
		revision_before
	)
	_expect(
		result == RunStateStore.CRAFT_RESULT_SUCCESS
		and run_state.get_inventory_item_total(GEL) == 0
		and run_state.get_inventory_item_total(WATER_BOTTLE) == 1
		and run_state.get_inventory_revision() == revision_before + 1
		and inventory_change_count == 1,
		"简易制造必须在一次同步原子事务中立即将1凝胶转化为1水瓶。"
	)


func _test_building_recipe_transactions(run_state: RunStateStore) -> void:
	var wood_station_recipe := SimpleCraftingRegistry.get_recipe(
		SimpleCraftingRegistry.WOOD_PROCESSING_STATION_ID
	)
	var oak_warehouse_recipe := SimpleCraftingRegistry.get_recipe(
		SimpleCraftingRegistry.OAK_WAREHOUSE_ID
	)
	var vegetation_stake_recipe := SimpleCraftingRegistry.get_recipe(
		SimpleCraftingRegistry.VEGETATION_STAKE_ID
	)
	var stone_mill_recipe := SimpleCraftingRegistry.get_recipe(
		SimpleCraftingRegistry.STONE_MILL_ID
	)
	var simple_fence_recipe := SimpleCraftingRegistry.get_recipe(
		SimpleCraftingRegistry.SIMPLE_FENCE_ID
	)
	if (
		wood_station_recipe == null
		or oak_warehouse_recipe == null
		or vegetation_stake_recipe == null
		or stone_mill_recipe == null
		or simple_fence_recipe == null
	):
		return

	run_state.begin_new_run(&"weishidaier")
	_expect(
		run_state.get_inventory_item_total(WOOD) == RunStateStore.STARTING_WOOD_COUNT,
		"木头加工站事务测试必须使用新局自带的5份木头。"
	)
	var wood_revision := run_state.get_inventory_revision()
	_expect(
		run_state.try_craft_inventory_recipe_if_revision(
			wood_station_recipe,
			wood_revision
		) == RunStateStore.CRAFT_RESULT_SUCCESS
		and run_state.get_inventory_item_total(WOOD) == 0
		and run_state.get_inventory_item_total(WOOD_PROCESSING_STATION_ITEM) == 1,
		"木头加工站必须在一次原子事务中扣除5木头并进入背包。"
	)

	run_state.begin_new_run(&"weishidaier")
	_expect(
		run_state.get_inventory_item_total(WOOD) == RunStateStore.STARTING_WOOD_COUNT
		and run_state.try_add_item_count(WOOD, 5),
		"橡木仓库事务测试必须在初始5木头外再准备5木头。"
	)
	var warehouse_revision := run_state.get_inventory_revision()
	_expect(
		run_state.try_craft_inventory_recipe_if_revision(
			oak_warehouse_recipe,
			warehouse_revision
		) == RunStateStore.CRAFT_RESULT_SUCCESS
		and run_state.get_inventory_item_total(WOOD) == 0
		and run_state.get_inventory_item_total(OAK_WAREHOUSE_ITEM) == 1,
		"橡木仓库必须在一次原子事务中扣除10木头并进入背包。"
	)

	run_state.begin_new_run(&"weishidaier")
	_expect(
		run_state.try_add_item_count(PLANK, 10)
		and run_state.try_add_item_count(SAPLING, 1),
		"植被桩事务测试必须能准备10木板和1树苗。"
	)
	var stake_revision := run_state.get_inventory_revision()
	_expect(
		run_state.try_craft_inventory_recipe_if_revision(
			vegetation_stake_recipe,
			stake_revision
		) == RunStateStore.CRAFT_RESULT_SUCCESS
		and run_state.get_inventory_item_total(PLANK) == 0
		and run_state.get_inventory_item_total(SAPLING) == 0
		and run_state.get_inventory_item_total(VEGETATION_STAKE_ITEM) == 1,
		"植被桩必须在一次原子事务中扣除10木板和1树苗并进入背包。"
	)

	run_state.begin_new_run(&"weishidaier")
	_expect(
		run_state.try_add_item_count(WOOD, 5)
		and run_state.try_add_item_count(WATER_BOTTLE, 10),
		"石磨台成功事务必须在初始5木头外补齐5木头，并准备10个水瓶。"
	)
	var stone_mill_revision := run_state.get_inventory_revision()
	inventory_change_count = 0
	var stone_mill_result := run_state.try_craft_inventory_recipe_if_revision(
		stone_mill_recipe,
		stone_mill_revision
	)
	_expect(
		stone_mill_result == RunStateStore.CRAFT_RESULT_SUCCESS
		and run_state.get_inventory_item_total(WOOD) == 0
		and run_state.get_inventory_item_total(WATER_BOTTLE) == 0
		and run_state.get_inventory_item_total(STONE_MILL_ITEM) == 1
		and run_state.get_inventory_revision() == stone_mill_revision + 1
		and inventory_change_count == 1,
		"石磨台必须忽略0.1秒占位时长，在一次同步原子事务中扣除10木头和10水瓶并进入背包。"
	)

	run_state.begin_new_run(&"weishidaier")
	_expect(
		run_state.try_add_item_count(WOOD, 5),
		"石磨台缺水瓶用例必须先准备完整的10木头。"
	)
	var missing_water_revision := run_state.get_inventory_revision()
	var missing_water_inventory := _local_inventory_signature(run_state)
	inventory_change_count = 0
	_expect(
		run_state.try_craft_inventory_recipe_if_revision(
			stone_mill_recipe,
			missing_water_revision
		) == RunStateStore.CRAFT_RESULT_MISSING_INPUT
		and _local_inventory_signature(run_state) == missing_water_inventory
		and run_state.get_inventory_revision() == missing_water_revision
		and inventory_change_count == 0,
		"石磨台缺少水瓶时不得部分扣除已有木头或推进背包revision。"
	)

	run_state.begin_new_run(&"weishidaier")
	_expect(
		run_state.try_add_item_count(WATER_BOTTLE, 10),
		"石磨台缺木头用例必须先准备完整的10个水瓶。"
	)
	var missing_wood_revision := run_state.get_inventory_revision()
	var missing_wood_inventory := _local_inventory_signature(run_state)
	inventory_change_count = 0
	_expect(
		run_state.try_craft_inventory_recipe_if_revision(
			stone_mill_recipe,
			missing_wood_revision
		) == RunStateStore.CRAFT_RESULT_MISSING_INPUT
		and _local_inventory_signature(run_state) == missing_wood_inventory
		and run_state.get_inventory_revision() == missing_wood_revision
		and inventory_change_count == 0,
		"石磨台缺少木头时不得部分扣除已有水瓶或推进背包revision。"
	)

	run_state.begin_new_run(&"weishidaier")
	var fence_revision_before := run_state.get_inventory_revision()
	inventory_change_count = 0
	for _craft_index in range(RunStateStore.STARTING_WOOD_COUNT):
		_expect(
			run_state.try_craft_inventory_recipe_if_revision(
				simple_fence_recipe,
				run_state.get_inventory_revision()
			) == RunStateStore.CRAFT_RESULT_SUCCESS,
			"每份木头必须能在同步原子事务中立即制造1个简易围栏。"
		)
	_expect(
		run_state.get_inventory_item_total(WOOD) == 0
		and run_state.get_inventory_item_total(SIMPLE_FENCE_ITEM)
		== RunStateStore.STARTING_WOOD_COUNT
		and _count_local_item_slots(run_state, SIMPLE_FENCE_ITEM) == 1
		and run_state.get_inventory_revision()
		== fence_revision_before + RunStateStore.STARTING_WOOD_COUNT
		and inventory_change_count == RunStateStore.STARTING_WOOD_COUNT,
		"连续制造的简易围栏必须合并在同一999上限堆栈，每次事务仅推进一次revision和通知。"
	)
	var exhausted_revision := run_state.get_inventory_revision()
	var exhausted_inventory := _local_inventory_signature(run_state)
	inventory_change_count = 0
	_expect(
		run_state.try_craft_inventory_recipe_if_revision(
			simple_fence_recipe,
			exhausted_revision
		) == RunStateStore.CRAFT_RESULT_MISSING_INPUT
		and _local_inventory_signature(run_state) == exhausted_inventory
		and run_state.get_inventory_revision() == exhausted_revision
		and inventory_change_count == 0,
		"木头耗尽后制造围栏必须原子拒绝，既有围栏堆栈与revision不得改变。"
	)

	run_state.begin_new_run(&"weishidaier")
	var stale_fence_revision := run_state.get_inventory_revision()
	var stale_fence_inventory := _local_inventory_signature(run_state)
	inventory_change_count = 0
	_expect(
		run_state.try_craft_inventory_recipe_if_revision(
			simple_fence_recipe,
			stale_fence_revision - 1
		) == RunStateStore.CRAFT_RESULT_STALE_REVISION
		and _local_inventory_signature(run_state) == stale_fence_inventory
		and run_state.get_inventory_revision() == stale_fence_revision
		and inventory_change_count == 0,
		"过期revision制造围栏必须在扣除木头前原子拒绝。"
	)

	run_state.begin_new_run(&"weishidaier")
	_fill_remaining_slots_with_apples(run_state)
	var full_fence_revision := run_state.get_inventory_revision()
	var full_fence_inventory := _local_inventory_signature(run_state)
	inventory_change_count = 0
	_expect(
		_count_occupied_local_slots(run_state) == RunStateStore.INVENTORY_CAPACITY
		and run_state.try_craft_inventory_recipe_if_revision(
			simple_fence_recipe,
			full_fence_revision
		) == RunStateStore.CRAFT_RESULT_INVENTORY_FULL
		and _local_inventory_signature(run_state) == full_fence_inventory
		and run_state.get_inventory_revision() == full_fence_revision
		and inventory_change_count == 0,
		"满背包且木头堆栈不会清空时，围栏制造必须原子拒绝且不得部分扣木头。"
	)


func _test_research_locked_recipe_transactions(
	run_state: RunStateStore
) -> void:
	var bamboo_mortar_recipe := SimpleCraftingRegistry.get_recipe(
		SimpleCraftingRegistry.BAMBOO_MORTAR_ID
	)
	var hydrangea_recipe := SimpleCraftingRegistry.get_recipe(
		SimpleCraftingRegistry.HYDRANGEA_RAIN_TOWER_ID
	)
	if bamboo_mortar_recipe == null or hydrangea_recipe == null:
		return

	run_state.begin_new_run(&"weishidaier")
	_expect(
		run_state.try_add_item_count(WOODEN_CORE, 1)
		and run_state.try_add_item_count(PLANK, 10),
		"竹筒迫击炮科研门槛测试必须能准备1木制核心和10木板。"
	)
	var bamboo_revision := run_state.get_inventory_revision()
	var bamboo_inventory := _local_inventory_signature(run_state)
	inventory_change_count = 0
	var locked_bamboo_result := run_state.try_craft_inventory_recipe_if_revision(
		bamboo_mortar_recipe,
		bamboo_revision
	)
	_expect(
		run_state.get_simple_crafting_result(bamboo_mortar_recipe)
		== RunStateStore.CRAFT_RESULT_RESEARCH_LOCKED
		and locked_bamboo_result == RunStateStore.CRAFT_RESULT_RESEARCH_LOCKED
		and _local_inventory_signature(run_state) == bamboo_inventory
		and run_state.get_inventory_revision() == bamboo_revision
		and inventory_change_count == 0,
		"默认未研发时竹筒迫击炮必须返回research_locked，且材料、产物和revision保持不变。"
	)
	var bamboo_completed_ids: Array[StringName] = [
		GlobalResearchRegistry.BAMBOO_MORTAR_CRAFTING_ID,
	]
	var bamboo_result := run_state.try_craft_inventory_recipe_if_revision(
		bamboo_mortar_recipe,
		bamboo_revision,
		true,
		bamboo_completed_ids
	)
	_expect(
		bamboo_result == RunStateStore.CRAFT_RESULT_SUCCESS
		and run_state.get_inventory_item_total(WOODEN_CORE) == 0
		and run_state.get_inventory_item_total(PLANK) == 0
		and run_state.get_inventory_item_total(BAMBOO_MORTAR_ITEM) == 1
		and run_state.get_inventory_revision() == bamboo_revision + 1
		and inventory_change_count == 1,
		"传入已完成的迫击炮科研后必须精确扣除1核心和10木板，并原子产出1座竹筒迫击炮。"
	)

	run_state.begin_new_run(&"weishidaier")
	_expect(
		run_state.try_add_item_count(WOODEN_CORE, 2)
		and run_state.try_add_item_count(CAPOO_BLUE_CRYSTAL_POWDER, 1),
		"紫阳花科研门槛测试必须能准备2木制核心和1卡普蓝晶粉。"
	)
	var hydrangea_revision := run_state.get_inventory_revision()
	var hydrangea_inventory := _local_inventory_signature(run_state)
	inventory_change_count = 0
	var locked_hydrangea_result := (
		run_state.try_craft_inventory_recipe_if_revision(
			hydrangea_recipe,
			hydrangea_revision
		)
	)
	_expect(
		run_state.get_simple_crafting_result(hydrangea_recipe)
		== RunStateStore.CRAFT_RESULT_RESEARCH_LOCKED
		and locked_hydrangea_result == RunStateStore.CRAFT_RESULT_RESEARCH_LOCKED
		and _local_inventory_signature(run_state) == hydrangea_inventory
		and run_state.get_inventory_revision() == hydrangea_revision
		and inventory_change_count == 0,
		"默认未研发时紫阳花必须返回research_locked，且材料、产物和revision保持不变。"
	)
	var hydrangea_completed_ids: Array[StringName] = [
		GlobalResearchRegistry.HYDRANGEA_RAIN_TOWER_CRAFTING_ID,
	]
	var hydrangea_result := run_state.try_craft_inventory_recipe_if_revision(
		hydrangea_recipe,
		hydrangea_revision,
		true,
		hydrangea_completed_ids
	)
	_expect(
		hydrangea_result == RunStateStore.CRAFT_RESULT_SUCCESS
		and run_state.get_inventory_item_total(WOODEN_CORE) == 0
		and run_state.get_inventory_item_total(CAPOO_BLUE_CRYSTAL_POWDER) == 0
		and run_state.get_inventory_item_total(HYDRANGEA_RAIN_TOWER_ITEM) == 1
		and run_state.get_inventory_revision() == hydrangea_revision + 1
		and inventory_change_count == 1,
		"传入已完成的紫阳花科研后必须精确扣除2核心和1卡普蓝晶粉，并原子产出1座紫阳花雨幕塔。"
	)


func _test_local_atomic_success(run_state: RunStateStore) -> void:
	var recipe := _get_recipe()
	if recipe == null:
		return
	run_state.begin_new_run(&"weishidaier")
	_expect(
		run_state.try_add_item_count(SAPLING, 1)
		and run_state.try_add_item_count(WATER_BOTTLE, 1),
		"本地成功用例必须能准备树苗和水瓶。"
	)
	var revision_before := run_state.get_inventory_revision()
	inventory_change_count = 0
	var result := run_state.try_craft_inventory_recipe_if_revision(
		recipe,
		revision_before
	)
	_expect(
		result == RunStateStore.CRAFT_RESULT_SUCCESS,
		"材料与空间充足时，本地简易制造必须立即成功。"
	)
	_expect(
		run_state.get_inventory_item_total(SAPLING) == 0
		and run_state.get_inventory_item_total(WATER_BOTTLE) == 0
		and run_state.get_inventory_item_total(HEALTH_PICKUP) == 1,
		"成功制造必须原子扣除全部材料并放入产物。"
	)
	_expect(
		run_state.get_inventory_revision() == revision_before + 1,
		"一次成功制造必须只递增一次本地背包revision。"
	)
	_expect(
		inventory_change_count == 1,
		"一次成功制造必须只发出一次inventory_changed。"
	)


func _test_missing_input_is_atomic(run_state: RunStateStore) -> void:
	var recipe := _get_recipe()
	if recipe == null:
		return
	run_state.begin_new_run(&"weishidaier")
	_expect(
		run_state.try_add_item_count(SAPLING, 1),
		"缺材料用例必须能准备单独的树苗。"
	)
	var revision_before := run_state.get_inventory_revision()
	var inventory_before := _local_inventory_signature(run_state)
	inventory_change_count = 0
	var result := run_state.try_craft_inventory_recipe_if_revision(
		recipe,
		revision_before
	)
	_expect(
		result == RunStateStore.CRAFT_RESULT_MISSING_INPUT,
		"缺少任意输入时必须明确返回材料不足。"
	)
	_expect(
		_local_inventory_signature(run_state) == inventory_before
		and run_state.get_inventory_revision() == revision_before,
		"材料不足时不得先扣除已有材料或推进revision。"
	)
	_expect(
		inventory_change_count == 0,
		"材料不足的拒绝不得发出inventory_changed。"
	)


func _test_stale_revision_is_atomic(run_state: RunStateStore) -> void:
	var recipe := _get_recipe()
	if recipe == null:
		return
	run_state.begin_new_run(&"weishidaier")
	_expect(
		run_state.try_add_item_count(SAPLING, 1)
		and run_state.try_add_item_count(WATER_BOTTLE, 1),
		"过期revision用例必须能准备完整材料。"
	)
	var revision_before := run_state.get_inventory_revision()
	var inventory_before := _local_inventory_signature(run_state)
	inventory_change_count = 0
	var result := run_state.try_craft_inventory_recipe_if_revision(
		recipe,
		revision_before - 1
	)
	_expect(
		result == RunStateStore.CRAFT_RESULT_STALE_REVISION,
		"客户端背包revision过期时必须拒绝制造。"
	)
	_expect(
		_local_inventory_signature(run_state) == inventory_before
		and run_state.get_inventory_revision() == revision_before,
		"过期revision不得修改任何背包槽位。"
	)
	_expect(
		inventory_change_count == 0,
		"过期revision拒绝不得发出inventory_changed。"
	)


func _test_full_inventory_is_atomic(run_state: RunStateStore) -> void:
	var recipe := _get_recipe()
	if recipe == null:
		return
	run_state.begin_new_run(&"weishidaier")
	_expect(
		run_state.try_add_item_count(SAPLING, 2)
		and run_state.try_add_item_count(WATER_BOTTLE, 2),
		"满背包拒绝用例必须准备扣除后仍占槽的材料堆叠。"
	)
	_fill_remaining_slots_with_apples(run_state)
	_expect(
		_count_occupied_local_slots(run_state) == RunStateStore.INVENTORY_CAPACITY,
		"满背包拒绝用例必须占满全部背包槽。"
	)
	var revision_before := run_state.get_inventory_revision()
	var inventory_before := _local_inventory_signature(run_state)
	inventory_change_count = 0
	var result := run_state.try_craft_inventory_recipe_if_revision(
		recipe,
		revision_before
	)
	_expect(
		result == RunStateStore.CRAFT_RESULT_INVENTORY_FULL,
		"扣料后仍没有产物槽位时必须返回背包空间不足。"
	)
	_expect(
		_local_inventory_signature(run_state) == inventory_before
		and run_state.get_inventory_revision() == revision_before,
		"背包空间不足时材料、产物和revision必须全部保持不变。"
	)
	_expect(
		inventory_change_count == 0,
		"背包空间不足的原子拒绝不得发出inventory_changed。"
	)


func _test_consumed_inputs_can_free_output_space(
	run_state: RunStateStore
) -> void:
	var recipe := _get_recipe()
	if recipe == null:
		return
	run_state.begin_new_run(&"weishidaier")
	_expect(
		run_state.try_add_item_count(SAPLING, 1)
		and run_state.try_add_item_count(WATER_BOTTLE, 1),
		"腾位成功用例必须准备恰好会清空槽位的材料。"
	)
	_fill_remaining_slots_with_apples(run_state)
	_expect(
		_count_occupied_local_slots(run_state) == RunStateStore.INVENTORY_CAPACITY,
		"腾位成功用例在制造前必须同样占满全部背包槽。"
	)
	var revision_before := run_state.get_inventory_revision()
	inventory_change_count = 0
	var result := run_state.try_craft_inventory_recipe_if_revision(
		recipe,
		revision_before
	)
	_expect(
		result == RunStateStore.CRAFT_RESULT_SUCCESS,
		"满背包中先扣除材料能腾出槽位时，制造不得被预容量检查误拒绝。"
	)
	_expect(
		run_state.get_inventory_item_total(SAPLING) == 0
		and run_state.get_inventory_item_total(WATER_BOTTLE) == 0
		and run_state.get_inventory_item_total(HEALTH_PICKUP) == 1
		and _count_occupied_local_slots(run_state)
		== RunStateStore.INVENTORY_CAPACITY - 1,
		"腾位制造成功后应清空两个材料槽，并用其中一个槽放入产物。"
	)
	_expect(
		run_state.get_inventory_revision() == revision_before + 1
		and inventory_change_count == 1,
		"腾位成功仍必须只提交一次revision并只发出一次变更信号。"
	)


func _test_peer_atomic_success(run_state: RunStateStore) -> void:
	const CRAFTING_PEER_ID := 7
	const OTHER_PEER_ID := 8
	var recipe := _get_recipe()
	if recipe == null:
		return
	run_state.begin_new_run(&"weishidaier")
	_expect(
		run_state.try_add_item_count_for_peer(
			CRAFTING_PEER_ID,
			SAPLING,
			1
		)
		and run_state.try_add_item_count_for_peer(
			CRAFTING_PEER_ID,
			WATER_BOTTLE,
			1
		)
		and run_state.try_add_item_count_for_peer(
			OTHER_PEER_ID,
			APPLE,
			1
		),
		"Peer成功用例必须能准备目标玩家材料与另一玩家哨兵物品。"
	)
	var local_before := _local_inventory_signature(run_state)
	var other_peer_before := _peer_inventory_signature(
		run_state,
		OTHER_PEER_ID
	)
	var revision_before := run_state.get_inventory_revision_for_peer(
		CRAFTING_PEER_ID
	)
	inventory_change_count = 0
	var result := (
		run_state.try_craft_inventory_recipe_for_peer_if_revision(
			CRAFTING_PEER_ID,
			recipe,
			revision_before
		)
	)
	_expect(
		result == RunStateStore.CRAFT_RESULT_SUCCESS,
		"Host必须能为指定Peer原子完成简易制造。"
	)
	_expect(
		run_state.get_inventory_item_total_for_peer(
			CRAFTING_PEER_ID,
			SAPLING
		) == 0
		and run_state.get_inventory_item_total_for_peer(
			CRAFTING_PEER_ID,
			WATER_BOTTLE
		) == 0
		and run_state.get_inventory_item_total_for_peer(
			CRAFTING_PEER_ID,
			HEALTH_PICKUP
		) == 1,
		"Peer成功制造必须只更新目标玩家的材料与产物。"
	)
	_expect(
		_local_inventory_signature(run_state) == local_before
		and _peer_inventory_signature(run_state, OTHER_PEER_ID)
		== other_peer_before,
		"指定Peer制造不得串写本地背包或其他Peer背包。"
	)
	_expect(
		run_state.get_inventory_revision_for_peer(CRAFTING_PEER_ID)
		== revision_before + 1
		and inventory_change_count == 1,
		"Peer成功制造必须只递增一次目标revision并只发出一次变更信号。"
	)


func _test_health_potion_stack_and_use(run_state: RunStateStore) -> void:
	run_state.begin_new_run(&"weishidaier")
	var player := PLAYER_SCENE.instantiate() as Player
	root.add_child(player)
	await process_frame
	_expect(
		run_state.try_add_item_count(HEALTH_PICKUP, 2),
		"生命药瓶堆叠测试必须能一次放入两瓶。"
	)
	var potion_slot := _find_local_item_slot(run_state, HEALTH_PICKUP)
	_expect(
		potion_slot >= 0
		and run_state.get_item_count(potion_slot) == 2
		and _count_occupied_local_slots(run_state) == 2,
		"两瓶生命药瓶必须在初始木头之外只占用一个背包槽。"
	)
	if potion_slot >= 0 and player != null:
		var initial_health := maxi(player.max_health - 40, 1)
		player.current_health = initial_health
		player.health_bar.set_health(player.current_health, player.max_health)
		var expected_after_first := mini(initial_health + 20, player.max_health)
		var expected_after_second := mini(expected_after_first + 20, player.max_health)
		_expect(
			run_state.try_use_item(potion_slot, player)
			and player.current_health == expected_after_first
			and run_state.get_item(potion_slot) == HEALTH_PICKUP
			and run_state.get_item_count(potion_slot) == 1,
			"使用一瓶生命药瓶必须恢复20点生命且只扣除堆叠中的1瓶。"
		)
		_expect(
			run_state.try_use_item(potion_slot, player)
			and player.current_health == expected_after_second
			and run_state.get_item(potion_slot) == null
			and run_state.get_item_count(potion_slot) == 0,
			"再次使用生命药瓶必须再恢复20点生命并清空最后1瓶。"
		)
	player.queue_free()
	await process_frame


func _test_multiplayer_request_token_tracking() -> void:
	var transactions := MpTransactionsCoordinator.new()
	transactions.track_local_simple_crafting_request(11, 101)
	transactions.track_local_simple_crafting_request(12, 102)
	_expect(
		transactions.take_local_simple_crafting_request_token(11) == 101
		and not (
			transactions.get(
				"_local_simple_crafting_ui_tokens_by_request_id"
			) as Dictionary
		).has(11)
		and not (
			transactions.get(
				"_local_simple_crafting_request_ids_by_ui_token"
			) as Dictionary
		).has(101)
		and (
			transactions.get(
				"_local_simple_crafting_ui_tokens_by_request_id"
			) as Dictionary
		).get(12, 0) == 102,
		"正常回包必须按网络request_id取回对应面板token，且只清理本次映射。"
	)
	transactions.cancel_simple_crafting_request(102)
	_expect(
		(
			transactions.get(
				"_local_simple_crafting_ui_tokens_by_request_id"
			) as Dictionary
		).is_empty()
		and (
			transactions.get(
				"_local_simple_crafting_request_ids_by_ui_token"
			) as Dictionary
		).is_empty(),
		"超时或关闭必须通过反向token索引O(1)释放本地请求映射。"
	)
	transactions.track_local_simple_crafting_request(13, 103)
	transactions.clear_local_simple_crafting_request_tracking()
	_expect(
		(
			transactions.get(
				"_local_simple_crafting_ui_tokens_by_request_id"
			) as Dictionary
		).is_empty()
		and (
			transactions.get(
				"_local_simple_crafting_request_ids_by_ui_token"
			) as Dictionary
		).is_empty(),
		"多人场景退出时必须清空尚未收到结果的本地制造token。"
	)
	transactions.free()


func _test_simple_crafting_ui(run_state: RunStateStore) -> void:
	run_state.begin_new_run(&"weishidaier")
	_expect(
		run_state.try_add_item_count(SAPLING, 2)
		and run_state.try_add_item_count(WATER_BOTTLE, 2),
		"UI满包提示用例必须准备材料。"
	)
	_fill_remaining_slots_with_apples(run_state)

	var ui_root := MultiplayerCraftSceneStub.new()
	ui_root.name = "SimpleCraftingSmokeTest"
	root.add_child(ui_root)
	current_scene = ui_root

	var crafting_panel := (
		SIMPLE_CRAFTING_PANEL_SCENE.instantiate()
		as SimpleCraftingPanel
	)
	ui_root.add_child(crafting_panel)
	await process_frame
	crafting_panel.refresh()

	var craft_area := crafting_panel.get_node("Background/CraftArea") as Control
	var recipe_area := crafting_panel.get_node("Background/RecipeArea") as Control
	var input_slots := crafting_panel.get_node(
		"Background/CraftArea/Margin/Content/InputSlots"
	)
	var output_slots := crafting_panel.get_node(
		"Background/CraftArea/Margin/Content/OutputSlots"
	)
	var status_label := crafting_panel.get_node(
		"Background/CraftArea/Margin/Content/Status"
	) as Label
	var craft_button := crafting_panel.get_node(
		"Background/CraftArea/Margin/Content/CraftButton"
	) as Button
	var request_timeout := crafting_panel.get_node(
		"RequestTimeout"
	) as Timer
	var recipe_name := crafting_panel.get_node(
		"Background/CraftArea/Margin/Content/RecipeName"
	) as Label
	var input_title := crafting_panel.get_node(
		"Background/CraftArea/Margin/Content/InputTitle"
	) as Label
	var arrow_label := crafting_panel.get_node(
		"Background/CraftArea/Margin/Content/Arrow"
	) as Label
	var output_title := crafting_panel.get_node(
		"Background/CraftArea/Margin/Content/OutputTitle"
	) as Label
	var recipe_title := crafting_panel.get_node(
		"Background/RecipeArea/Margin/Content/Title"
	) as Label
	var recipe_scroll := crafting_panel.get_node_or_null(
		"Background/RecipeArea/Margin/Content/RecipeScroll"
	) as ScrollContainer
	var recipe_margin := crafting_panel.get_node_or_null(
		"Background/RecipeArea/Margin"
	) as MarginContainer
	var recipe_list := crafting_panel.get_node_or_null(
		"Background/RecipeArea/Margin/Content/RecipeScroll/RecipeList"
	) as VBoxContainer
	var amount_label := crafting_panel.get_node(
		"Background/CraftArea/Margin/Content/InputSlots/InputSlot0/Content/Amount"
	) as Label
	var detail_label := crafting_panel.get_node(
		"Background/CraftArea/Margin/Content/InputSlots/InputSlot0/Content/Detail"
	) as Label
	_expect(
		craft_area.position.x + craft_area.size.x <= recipe_area.position.x,
		"简易制造界面必须保持左侧制造区、右侧配方区且互不重叠。"
	)
	_expect(
		crafting_panel.size == Vector2(418, 444),
		"简易制造外框必须保持418×444。"
	)
	_expect(
		input_slots.get_child_count() == ProductionRecipe.MAX_INPUT_ITEMS
		and output_slots.get_child_count() == ProductionRecipe.MAX_OUTPUT_ITEMS,
		"简易制造物品框数量必须覆盖配方允许的最多3项输入和3项输出。"
	)
	_expect(
		_count_visible_children(input_slots) == 2
		and _count_visible_children(output_slots) == 1,
		"物品框必须按当前配方自适应，只显示实际的2项输入和1项产出。"
	)
	_expect(
		_count_visible_recipe_buttons(crafting_panel) == 7
		and crafting_panel.recipe_buttons[0].text == "草药生命药瓶"
		and crafting_panel.recipe_buttons[1].text == "木头加工站"
		and crafting_panel.recipe_buttons[2].text == "橡木仓库"
		and crafting_panel.recipe_buttons[3].text == "植被桩"
		and crafting_panel.recipe_buttons[4].text == "石磨台"
		and crafting_panel.recipe_buttons[5].text == "简易围栏"
		and crafting_panel.recipe_buttons[6].text == "凝胶制水瓶",
		"未绑定已完成科研时，简易制造界面只能按注册顺序展示七条基础配方。"
	)
	_expect(
		crafting_panel.recipe_buttons.size() == 9
		and recipe_scroll != null
		and recipe_margin != null
		and recipe_list != null
		and recipe_list.get_child_count() == 9,
		"九条注册配方必须由场景原生预建九个按钮，并放在可滚动列表中。"
	)
	if recipe_scroll != null and recipe_margin != null:
		var recipe_scrollbar := recipe_scroll.get_v_scroll_bar()
		var first_recipe_button := crafting_panel.recipe_buttons[0]
		var left_gap := (
			recipe_scrollbar.global_position.x
			- first_recipe_button.get_global_rect().end.x
		)
		var right_gap := (
			recipe_area.get_global_rect().end.x
			- recipe_scrollbar.get_global_rect().end.x
		)
		_expect(
			recipe_margin.get_theme_constant(&"margin_right") == 4
			and recipe_scroll.get_theme_constant(&"scrollbar_h_separation") == 4
			and recipe_scrollbar.visible
			and left_gap >= 4.0
			and absf(left_gap - right_gap) <= 1.0,
			"建议配方滚动条必须位于配方按钮与右侧边框空档的中央。"
		)

	var research := (
		RESEARCH_COORDINATOR_SCENE.instantiate() as ResearchCoordinator
	)
	ui_root.add_child(research)
	await process_frame
	research.research_tick_timer.stop()
	crafting_panel.set_research_state_provider(research)
	_expect(
		_count_visible_recipe_buttons(crafting_panel) == 7,
		"绑定尚未完成任何配方科研的协调器后仍只能显示七条基础配方。"
	)
	research.global_research_states[
		GlobalResearchRegistry.BAMBOO_MORTAR_CRAFTING_ID
	] = ResearchCoordinator.GlobalResearchState.COMPLETED
	research.research_state_changed.emit()
	_expect(
		_count_visible_recipe_buttons(crafting_panel) == 8
		and crafting_panel.recipe_buttons[7].text == "竹筒迫击炮",
		"迫击炮科研完成事件必须立即把竹筒迫击炮追加为第八条可见配方。"
	)
	research.global_research_states[
		GlobalResearchRegistry.HYDRANGEA_RAIN_TOWER_CRAFTING_ID
	] = ResearchCoordinator.GlobalResearchState.COMPLETED
	research.research_state_changed.emit()
	_expect(
		_count_visible_recipe_buttons(crafting_panel) == 9
		and crafting_panel.recipe_buttons[8].text == "紫阳花雨幕塔",
		"紫阳花科研完成事件必须立即把紫阳花追加为第九条可见配方。"
	)
	crafting_panel.call("_on_recipe_pressed", 8)
	await process_frame
	recipe_scroll.scroll_vertical = 10000
	await process_frame
	_expect(
		crafting_panel.selected_recipe_id
		== SimpleCraftingRegistry.HYDRANGEA_RAIN_TOWER_ID
		and _count_pressed_recipe_buttons(crafting_panel) == 1
		and crafting_panel.recipe_buttons[8].button_pressed
		and recipe_scroll.scroll_vertical > 0,
		"第九条配方必须可滚动到达，并保持唯一选中态。"
	)
	var replacement_research := (
		RESEARCH_COORDINATOR_SCENE.instantiate() as ResearchCoordinator
	)
	ui_root.add_child(replacement_research)
	await process_frame
	replacement_research.research_tick_timer.stop()
	crafting_panel.set_research_state_provider(replacement_research)
	_expect(
		_count_visible_recipe_buttons(crafting_panel) == 7
		and crafting_panel.selected_recipe_id
		== SimpleCraftingRegistry.HERBAL_HEALTH_POTION_ID
		and not research.research_state_changed.is_connected(
			crafting_panel._on_research_state_changed
		)
		and replacement_research.research_state_changed.is_connected(
			crafting_panel._on_research_state_changed
		),
		"切换科研协调器时必须解绑旧信号，并在当前配方消失后回退到第一条基础配方。"
	)
	crafting_panel.set_research_state_provider(null)
	_expect(
		_count_visible_recipe_buttons(crafting_panel) == 7
		and not replacement_research.research_state_changed.is_connected(
			crafting_panel._on_research_state_changed
		),
		"解绑科研协调器后必须维持基础配方列表，且不能残留旧科研信号连接。"
	)
	_expect(
		_has_vertical_text_safety(recipe_name, 2.0)
		and _has_vertical_text_safety(input_title, 2.0)
		and _has_vertical_text_safety(arrow_label, 2.0)
		and _has_vertical_text_safety(output_title, 2.0)
		and _has_vertical_text_safety(recipe_title, 2.0)
		and _has_vertical_text_safety(amount_label, 2.0)
		and _has_vertical_text_safety(detail_label, 2.0),
		"简易制造的标题、流程文字和物品数量文字必须保留至少2像素纵向安全区。"
	)
	_expect(
		amount_label.size.x >= 38.0
		and amount_label.offset_right <= 65.0,
		"物品数量文字必须为×10/×999及阴影保留足够横向安全区。"
	)
	_expect(
		request_timeout != null
		and request_timeout.one_shot
		and request_timeout.ignore_time_scale
		and is_equal_approx(request_timeout.wait_time, 3.0)
		and _count_tree_nodes_by_class(crafting_panel, &"Timer") == 1
		and not _tree_contains_class(crafting_panel, &"ProgressBar"),
		"简易制造必须只使用场景常驻的3秒单次RPC超时Timer，不得引入生产进度条。"
	)
	var panel_source := FileAccess.get_file_as_string(
		"res://scene/ui/shared/crafting/simple_crafting_panel.gd"
	)
	_expect(
		not panel_source.contains("func _process(")
		and not panel_source.contains("func _physics_process("),
		"简易制造面板必须事件驱动，不得引入空闲帧或物理帧开销。"
	)
	_expect(
		status_label.text == "背包剩余空间不足"
		and craft_button.disabled,
		"产物无法放入背包时，界面必须明确提示空间不足并禁止制造。"
	)
	crafting_panel.show_result(
		SimpleCraftingRegistry.HERBAL_HEALTH_POTION_ID,
		RunStateStore.CRAFT_RESULT_INVENTORY_FULL,
		0
	)
	_expect(
		status_label.text == "背包剩余空间不足",
		"Host拒绝满包制造后，结果提示必须保持明确且可见。"
	)

	run_state.begin_new_run(&"weishidaier")
	_expect(
		run_state.try_add_item_count(SAPLING, 2)
		and run_state.try_add_item_count(WATER_BOTTLE, 2),
		"RPC生命周期测试必须准备可制造材料与空余背包槽。"
	)
	crafting_panel.refresh()
	panel_request_tokens.clear()
	panel_cancelled_tokens.clear()
	crafting_panel.craft_requested.connect(_on_panel_craft_requested)
	crafting_panel.craft_request_cancelled.connect(
		_on_panel_craft_request_cancelled
	)
	request_timeout.wait_time = 0.03
	crafting_panel.call("_on_craft_pressed")
	var normal_request_token: int = int(
		panel_request_tokens.back()
		if not panel_request_tokens.is_empty()
		else 0
	)
	_expect(
		normal_request_token > 0
		and crafting_panel.request_pending
		and not request_timeout.is_stopped()
		and craft_button.disabled,
		"制造请求发出后必须记录唯一token、启动超时Timer并锁定制造按钮。"
	)
	crafting_panel.show_result(
		SimpleCraftingRegistry.HERBAL_HEALTH_POTION_ID,
		RunStateStore.CRAFT_RESULT_SUCCESS,
		normal_request_token
	)
	_expect(
		not crafting_panel.request_pending
		and request_timeout.is_stopped()
		and status_label.text == "制造完成，产物已放入背包",
		"匹配当前token的正常结果必须停止Timer并解除pending。"
	)

	crafting_panel.call("_on_craft_pressed")
	var timed_out_token: int = int(panel_request_tokens.back())
	await create_timer(0.08, true, false, true).timeout
	_expect(
		timed_out_token > normal_request_token
		and not crafting_panel.request_pending
		and request_timeout.is_stopped()
		and not craft_button.disabled
		and status_label.text == "主机未响应，请重试"
		and panel_cancelled_tokens == [timed_out_token],
		"共享/功能限流静默拒绝时必须在超时后恢复按钮、提示主机未响应并释放token。"
	)

	crafting_panel.call("_on_craft_pressed")
	var retry_token: int = int(panel_request_tokens.back())
	crafting_panel.show_result(
		SimpleCraftingRegistry.HERBAL_HEALTH_POTION_ID,
		RunStateStore.CRAFT_RESULT_SUCCESS,
		timed_out_token
	)
	_expect(
		retry_token > timed_out_token
		and crafting_panel.request_pending
		and not request_timeout.is_stopped()
		and status_label.text == "正在制造…",
		"超时重试必须使用新token，旧请求晚到的结果不得清理新pending。"
	)
	crafting_panel.show_result(
		SimpleCraftingRegistry.HERBAL_HEALTH_POTION_ID,
		RunStateStore.CRAFT_RESULT_SUCCESS,
		retry_token
	)
	_expect(
		not crafting_panel.request_pending
		and request_timeout.is_stopped(),
		"重试请求自己的结果必须正常结束pending。"
	)

	crafting_panel.call("_on_craft_pressed")
	var closed_token: int = int(panel_request_tokens.back())
	crafting_panel.set_panel_active(false)
	_expect(
		not crafting_panel.request_pending
		and request_timeout.is_stopped()
		and panel_cancelled_tokens == [timed_out_token, closed_token],
		"切走或关闭简易制造面板必须停止Timer并释放当前请求token。"
	)
	crafting_panel.set_panel_active(true)

	var profile_panel := (
		PROFILE_PANEL_SCENE.instantiate() as StandardPlayerProfilePanel
	)
	profile_panel.configure_multiplayer_requests(true)
	profile_panel.multiplayer_simple_crafting_requested.connect(
		ui_root.request_multiplayer_simple_crafting
	)
	profile_panel.multiplayer_simple_crafting_cancel_requested.connect(
		ui_root.cancel_multiplayer_simple_crafting_request
	)
	ui_root.add_child(profile_panel)
	await process_frame
	var tab_bar := profile_panel.get_node("Overlay/PanelRoot/TabBar") as TabBar
	var embedded_panel := profile_panel.get_node_or_null(
		"Overlay/PanelRoot/SimpleCraftingPanel"
	) as SimpleCraftingPanel
	var craft_surface := profile_panel.get_node_or_null(
		"Overlay/PanelRoot/CraftSurface"
	) as NinePatchRect
	_expect(
		tab_bar.tab_count == 3
		and tab_bar.get_tab_title(0) == "背包"
		and tab_bar.get_tab_title(1) == "升级"
		and tab_bar.get_tab_title(2) == "简易制造",
		"个人数据界面必须在背包和升级之后提供第三个“简易制造”标签。"
	)
	_expect(
		embedded_panel != null,
		"个人数据场景必须原生实例化简易制造面板。"
	)
	if embedded_panel != null:
		profile_panel.call("_on_tab_changed", 2)
		_expect(
			embedded_panel.visible
			and craft_surface != null
			and craft_surface.visible
			and not profile_panel.inventory_grid.visible
			and not profile_panel.upgrade_panel.visible
			and not profile_panel.upgrade_surface.visible,
			"切换到第三标签时只能显示简易制造内容。"
		)
		embedded_panel.call("_on_craft_pressed")
		var forwarded_request := (
			ui_root.requests.back()
			if not ui_root.requests.is_empty()
			else {}
		) as Dictionary
		var forwarded_token := int(
			forwarded_request.get("request_token", 0)
		)
		_expect(
			forwarded_request.get("recipe_id", &"")
			== SimpleCraftingRegistry.HERBAL_HEALTH_POTION_ID
			and forwarded_token > 0
			and embedded_panel.request_pending,
			"个人数据面板必须把配方与面板token一并交给多人请求入口。"
		)
		profile_panel.show_simple_crafting_result(
			SimpleCraftingRegistry.HERBAL_HEALTH_POTION_ID,
			RunStateStore.CRAFT_RESULT_SUCCESS,
			forwarded_token
		)
		embedded_panel.call("_on_craft_pressed")
		var closing_request := ui_root.requests.back() as Dictionary
		var closing_token := int(closing_request.get("request_token", 0))
		profile_panel.overlay.visible = true
		profile_panel.close()
		_expect(
			closing_token > forwarded_token
			and not embedded_panel.request_pending
			and embedded_panel.request_timeout.is_stopped()
			and ui_root.cancelled_tokens == [closing_token],
			"关闭个人数据面板必须向多人场景释放对应token，不能遗留本地映射。"
		)

	profile_panel.queue_free()
	crafting_panel.queue_free()
	await process_frame
	ui_root.queue_free()
	await process_frame


func _get_recipe() -> ProductionRecipe:
	var recipe := SimpleCraftingRegistry.get_recipe(
		SimpleCraftingRegistry.HERBAL_HEALTH_POTION_ID
	)
	_expect(recipe != null, "测试需要白名单中的草药生命药瓶配方。")
	return recipe


func _fill_remaining_slots_with_apples(run_state: RunStateStore) -> void:
	while _count_occupied_local_slots(run_state) < RunStateStore.INVENTORY_CAPACITY:
		if not run_state.try_add_item(APPLE):
			failures.append("测试夹具无法用苹果填满剩余背包槽。")
			return


func _count_occupied_local_slots(run_state: RunStateStore) -> int:
	var occupied := 0
	for slot_index in range(RunStateStore.INVENTORY_CAPACITY):
		if run_state.get_item(slot_index) != null:
			occupied += 1
	return occupied


func _find_local_item_slot(
	run_state: RunStateStore,
	item: PickupConfig
) -> int:
	for slot_index in range(RunStateStore.INVENTORY_CAPACITY):
		if run_state.get_item(slot_index) == item:
			return slot_index
	return -1


func _count_local_item_slots(
	run_state: RunStateStore,
	item: PickupConfig
) -> int:
	var count := 0
	for slot_index in range(RunStateStore.INVENTORY_CAPACITY):
		if PickupConfig.inventory_identity_matches(
			run_state.get_item(slot_index),
			item
		):
			count += 1
	return count


func _is_valid_unstackable_building_item(
	item: PickupConfig,
	expected_plant_id: StringName
) -> bool:
	var plant_config := PlantDefenseRegistry.get_config(expected_plant_id)
	if item == null or plant_config == null or item.icon_texture == null:
		return false
	var uses_original_building_texture := false
	if plant_config.footprint_size == Vector2i.ONE:
		var atlas_icon := item.icon_texture as AtlasTexture
		uses_original_building_texture = (
			atlas_icon != null
			and atlas_icon.atlas != null
			and atlas_icon.atlas.resource_path
			== plant_config.icon.resource_path
		)
	else:
		uses_original_building_texture = (
			item.icon_texture.resource_path
			== plant_config.icon.resource_path
		)
	return (
		item.pickup_type == PickupConfig.PickupType.BUILDING
		and item.can_store_in_inventory
		and not item.stackable
		and item.inventory_stack_limit == 1
		and item.placeable_plant_id == expected_plant_id
		and uses_original_building_texture
		and item.icon_texture.get_size() * item.icon_scale
		== Vector2(32, 32)
	)


func _is_valid_stackable_building_item(
	item: PickupConfig,
	expected_plant_id: StringName
) -> bool:
	var plant_config := PlantDefenseRegistry.get_config(expected_plant_id)
	if item == null or plant_config == null or item.icon_texture == null:
		return false
	var atlas_icon := item.icon_texture as AtlasTexture
	return (
		item.pickup_type == PickupConfig.PickupType.BUILDING
		and item.can_store_in_inventory
		and item.stackable
		and item.inventory_stack_limit == 999
		and item.placeable_plant_id == expected_plant_id
		and atlas_icon != null
		and atlas_icon.atlas != null
		and item.icon_texture.resource_path == plant_config.icon.resource_path
		and atlas_icon.atlas.resource_path
		== "res://resources/texture/plant_defense/simple_fence/simple_fence_atlas.png"
		and item.icon_texture.get_size() * item.icon_scale == Vector2(32, 32)
	)


func _local_inventory_signature(
	run_state: RunStateStore
) -> PackedStringArray:
	var signature := PackedStringArray()
	for slot_index in range(RunStateStore.INVENTORY_CAPACITY):
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
	for slot_index in range(RunStateStore.INVENTORY_CAPACITY):
		var item := run_state.get_item_for_peer(peer_id, slot_index)
		signature.append(
			"%s:%d" % [
				item.resource_path if item != null else "",
				run_state.get_item_count_for_peer(peer_id, slot_index),
			]
		)
	return signature


func _tree_contains_class(node: Node, node_class: StringName) -> bool:
	if node.is_class(node_class):
		return true
	for child in node.get_children():
		if _tree_contains_class(child, node_class):
			return true
	return false


func _count_tree_nodes_by_class(
	node: Node,
	node_class: StringName
) -> int:
	var count := 1 if node.is_class(node_class) else 0
	for child in node.get_children():
		count += _count_tree_nodes_by_class(child, node_class)
	return count


func _count_visible_children(node: Node) -> int:
	var visible_count := 0
	for child in node.get_children():
		var control := child as Control
		if control != null and control.visible:
			visible_count += 1
	return visible_count


func _count_visible_recipe_buttons(panel: SimpleCraftingPanel) -> int:
	var visible_count := 0
	for button in panel.recipe_buttons:
		if button.visible:
			visible_count += 1
	return visible_count


func _count_pressed_recipe_buttons(panel: SimpleCraftingPanel) -> int:
	var pressed_count := 0
	for button in panel.recipe_buttons:
		if button.visible and button.button_pressed:
			pressed_count += 1
	return pressed_count


func _has_vertical_text_safety(control: Control, padding: float) -> bool:
	if control == null:
		return false
	return control.size.y - control.get_minimum_size().y >= padding


func _on_inventory_changed() -> void:
	inventory_change_count += 1


func _on_panel_craft_requested(
	_recipe_id: StringName,
	request_token: int
) -> void:
	panel_request_tokens.append(request_token)


func _on_panel_craft_request_cancelled(request_token: int) -> void:
	panel_cancelled_tokens.append(request_token)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
