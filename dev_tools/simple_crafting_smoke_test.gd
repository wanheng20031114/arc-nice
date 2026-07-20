extends SceneTree

const PROFILE_PANEL_SCENE := preload(
	"res://scene/player/ui/player_profile_panel.tscn"
)
const SIMPLE_CRAFTING_PANEL_SCENE := preload(
	"res://scene/player/ui/simple_crafting_panel.tscn"
)
const PLAYER_SCENE := preload(
	"res://scene/player/weishidaier/player_weishidaier.tscn"
)
const SAPLING := preload(
	"res://resources/config/materials/material_sapling.tres"
)
const WATER_BOTTLE := preload(
	"res://resources/config/materials/material_water_bottle.tres"
)
const WOOD := preload(
	"res://resources/config/materials/material_wood.tres"
)
const PLANK := preload(
	"res://resources/config/materials/material_plank.tres"
)
const HEALTH_PICKUP := preload(
	"res://resources/config/pickups/pickup_health.tres"
)
const WOOD_PROCESSING_STATION_ITEM := preload(
	"res://resources/config/buildings/building_wood_processing_station.tres"
)
const VEGETATION_STAKE_ITEM := preload(
	"res://resources/config/buildings/building_vegetation_stake.tres"
)
const APPLE := preload(
	"res://resources/config/collectibles/collectible_apple.tres"
)

var failures: Array[String] = []
var inventory_change_count := 0


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var run_state := root.get_node("RunState") as RunStateStore
	run_state.inventory_changed.connect(_on_inventory_changed)

	_test_registry_contract(run_state)
	_test_building_recipe_transactions(run_state)
	_test_local_atomic_success(run_state)
	_test_missing_input_is_atomic(run_state)
	_test_stale_revision_is_atomic(run_state)
	_test_full_inventory_is_atomic(run_state)
	_test_consumed_inputs_can_free_output_space(run_state)
	_test_peer_atomic_success(run_state)
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
	var vegetation_stake_recipe := SimpleCraftingRegistry.get_recipe(
		SimpleCraftingRegistry.VEGETATION_STAKE_ID
	)
	_expect(recipe != null, "简易制造白名单必须能解析草药生命药瓶配方。")
	_expect(
		wood_station_recipe != null and vegetation_stake_recipe != null,
		"简易制造白名单必须能解析木头加工站与植被桩配方。"
	)
	if recipe == null or wood_station_recipe == null or vegetation_stake_recipe == null:
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
			String(SimpleCraftingRegistry.VEGETATION_STAKE_ID)
		) == vegetation_stake_recipe
		and SimpleCraftingRegistry.get_recipe_by_wire_id(
			"x".repeat(SimpleCraftingRegistry.MAX_WIRE_RECIPE_ID_LENGTH + 1)
		) == null,
		"多人配方ID必须只按有界字符串解析，不得接受超长网络输入。"
	)
	var registered_recipes := SimpleCraftingRegistry.get_all_recipes()
	_expect(
		registered_recipes.size() == 3
		and registered_recipes[0] == recipe
		and registered_recipes[1] == wood_station_recipe
		and registered_recipes[2] == vegetation_stake_recipe,
		"简易制造配方列表只能暴露白名单中的有效配方。"
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
		vegetation_stake_recipe.input_items == [PLANK, SAPLING]
		and vegetation_stake_recipe.input_amounts == [10, 1]
		and vegetation_stake_recipe.output_items == [VEGETATION_STAKE_ITEM]
		and vegetation_stake_recipe.output_amounts == [1],
		"植被桩配方必须消耗10木板和1树苗并产出1个植被桩建筑物品。"
	)
	_expect(
		_is_valid_unstackable_building_item(
			WOOD_PROCESSING_STATION_ITEM,
			&"wood_processing_station"
		)
		and _is_valid_unstackable_building_item(
			VEGETATION_STAKE_ITEM,
			&"vegetation_stake"
		),
		"两种简易制造建筑产物必须使用32×32图标、不可堆叠并指向正确建筑。"
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


func _test_building_recipe_transactions(run_state: RunStateStore) -> void:
	var wood_station_recipe := SimpleCraftingRegistry.get_recipe(
		SimpleCraftingRegistry.WOOD_PROCESSING_STATION_ID
	)
	var vegetation_stake_recipe := SimpleCraftingRegistry.get_recipe(
		SimpleCraftingRegistry.VEGETATION_STAKE_ID
	)
	if wood_station_recipe == null or vegetation_stake_recipe == null:
		return

	run_state.begin_new_run(&"weishidaier")
	_expect(
		run_state.try_add_item_count(WOOD, 5),
		"木头加工站事务测试必须能准备5份木头。"
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
		and _count_occupied_local_slots(run_state) == 1,
		"两瓶生命药瓶必须进入同一背包槽。"
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


func _test_simple_crafting_ui(run_state: RunStateStore) -> void:
	run_state.begin_new_run(&"weishidaier")
	_expect(
		run_state.try_add_item_count(SAPLING, 2)
		and run_state.try_add_item_count(WATER_BOTTLE, 2),
		"UI满包提示用例必须准备材料。"
	)
	_fill_remaining_slots_with_apples(run_state)

	var ui_root := Node2D.new()
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
		_count_visible_recipe_buttons(crafting_panel) == 3
		and crafting_panel.recipe_buttons[0].text == "草药生命药瓶"
		and crafting_panel.recipe_buttons[1].text == "木头加工站"
		and crafting_panel.recipe_buttons[2].text == "植被桩",
		"简易制造界面必须展示三条已登记配方。"
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
		not _tree_contains_class(crafting_panel, &"Timer")
		and not _tree_contains_class(crafting_panel, &"ProgressBar"),
		"简易制造必须瞬间完成，界面不得引入生产计时器或进度条。"
	)
	var panel_source := FileAccess.get_file_as_string(
		"res://scene/player/ui/simple_crafting_panel.gd"
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
		RunStateStore.CRAFT_RESULT_INVENTORY_FULL
	)
	_expect(
		status_label.text == "背包剩余空间不足",
		"Host拒绝满包制造后，结果提示必须保持明确且可见。"
	)

	var profile_panel := PROFILE_PANEL_SCENE.instantiate() as PlayerProfilePanel
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


func _is_valid_unstackable_building_item(
	item: PickupConfig,
	expected_plant_id: StringName
) -> bool:
	return (
		item != null
		and item.pickup_type == PickupConfig.PickupType.BUILDING
		and item.can_store_in_inventory
		and not item.stackable
		and item.inventory_stack_limit == 1
		and item.placeable_plant_id == expected_plant_id
		and item.icon_texture != null
		and item.icon_texture.get_size() == Vector2(32, 32)
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


func _has_vertical_text_safety(control: Control, padding: float) -> bool:
	if control == null:
		return false
	return control.size.y - control.get_minimum_size().y >= padding


func _on_inventory_changed() -> void:
	inventory_change_count += 1


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
