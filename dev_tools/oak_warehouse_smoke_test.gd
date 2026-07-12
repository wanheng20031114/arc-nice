extends SceneTree

const WAREHOUSE_SCENE := preload("res://scene/plant_defense/oak_warehouse.tscn")
const PLAYER_SCENE := preload("res://scene/player/weishidaier/player_weishidaier.tscn")
const WOOD := preload("res://resources/config/materials/material_wood.tres")

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var run_state := root.get_node("RunState") as RunStateStore
	run_state.begin_new_run(&"weishidaier")

	var fixture := Node2D.new()
	root.add_child(fixture)
	var player := PLAYER_SCENE.instantiate() as Player
	fixture.add_child(player)
	player.set_physics_process(false)
	var warehouse := WAREHOUSE_SCENE.instantiate() as OakWarehouse
	fixture.add_child(warehouse)
	var config := PlantDefenseRegistry.get_config(&"oak_warehouse")
	warehouse.setup(
		config,
		player,
		[Vector2i.ZERO, Vector2i.RIGHT, Vector2i.DOWN, Vector2i.ONE]
	)
	await process_frame

	_test_config_and_scene(config, warehouse)
	_test_interaction_lock(player, warehouse)
	_test_stack_transfer(run_state, warehouse)

	fixture.queue_free()
	for _frame in range(3):
		await process_frame
	run_state.begin_new_run(&"weishidaier")

	if failures.is_empty():
		print("OAK_WAREHOUSE_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_config_and_scene(config: PlantDefenseConfig, warehouse: OakWarehouse) -> void:
	_expect(config != null and config.is_valid(), "橡木仓库配置必须有效。")
	_expect(config.footprint_size == Vector2i(2, 2), "橡木仓库必须占用四格地砖。")
	_expect(config.max_health == 300, "橡木仓库生命值必须为300。")
	_expect(PlantDefenseRegistry.get_all_configs().size() == 2, "植物选择必须包含两种建筑。")
	_expect(warehouse.storage_items.size() == 20, "仓库必须拥有20个物品格。")
	_expect(
		warehouse.storage_panel.storage_slots.size() == 20,
		"仓库左侧界面必须拥有20个槽位。"
	)
	_expect(
		warehouse.storage_panel.player_slots.size() == 20,
		"玩家背包右侧界面必须拥有20个槽位。"
	)
	var sprite_texture := warehouse.get_node("Sprite2D").texture as Texture2D
	_expect(sprite_texture.get_size() == Vector2(64, 64), "橡木仓库贴图必须限制为64×64。")
	var background := warehouse.storage_panel.get_node("Overlay/PanelRoot/Background") as TextureRect
	_expect(background.texture.get_size() == Vector2(724, 543), "仓库界面底图必须匹配724×543设计画布。")


func _test_interaction_lock(player: Player, warehouse: OakWarehouse) -> void:
	warehouse.call("_on_interaction_area_body_entered", player)
	_expect(warehouse.interaction_prompt.visible, "玩家靠近后必须显示按F打开提示。")
	var interact_event := InputEventAction.new()
	interact_event.action = &"interact"
	interact_event.pressed = true
	warehouse._unhandled_input(interact_event)
	_expect(warehouse.storage_panel.is_open(), "仓库界面必须能够打开。")
	_expect(player.controls_locked, "打开仓库时必须锁定玩家操作。")
	warehouse.storage_panel.close()
	_expect(not player.controls_locked, "关闭仓库后必须解除玩家操作锁。")


func _test_stack_transfer(run_state: RunStateStore, warehouse: OakWarehouse) -> void:
	_expect(run_state.try_add_item_count(WOOD, 17), "测试物资必须能整叠加入背包。")
	_expect(run_state.get_item_count(0) == 17, "背包测试木头数量必须为17。")
	_expect(
		warehouse.transfer_player_stack_to_storage(0, run_state),
		"玩家背包中的整叠物资必须能移入仓库。"
	)
	_expect(run_state.get_item(0) == null, "物资移入仓库后来源槽必须清空。")
	_expect(warehouse.get_storage_item_count(0) == 17, "仓库必须保留完整堆叠数量。")
	_expect(
		warehouse.transfer_storage_stack_to_player(0, run_state),
		"仓库中的整叠物资必须能移回玩家背包。"
	)
	_expect(warehouse.get_storage_item(0) == null, "物资移出仓库后来源槽必须清空。")
	_expect(run_state.get_item_count(0) == 17, "移回背包后物资数量不得损失。")


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
