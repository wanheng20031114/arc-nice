extends SceneTree

const WAREHOUSE_SCENE := preload("res://scene/plant_defense/oak_warehouse.tscn")
const PLAYER_SCENE := preload("res://scene/player/weishidaier/player_weishidaier.tscn")
const WOOD := preload("res://resources/config/materials/material_wood.tres")
const PLANT_HEALTH_BAR_SCRIPT := preload("res://scene/plant_defense/ui/plant_health_bar.gd")

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
	await _test_plant_health_bar(warehouse)
	_test_interaction_lock(player, warehouse)
	_test_detail_layout(warehouse.storage_panel)
	_test_slot_transfer_interactions(run_state, warehouse)

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
	_expect(config.max_health == 5000, "橡木仓库生命值必须为5000。")
	_expect(
		config.physical_defense == 10 and config.magic_defense == 20,
		"橡木仓库必须拥有10物理防御与20法术防御。"
	)
	_expect(
		warehouse.max_health == 5000 and warehouse.current_health == 5000,
		"橡木仓库实例必须以5000点满生命生成。"
	)
	_expect(
		config.plant_scene.resource_path.begins_with("res://scene/plant_defense/"),
		"橡木仓库必须继续由scene/plant_defense下的独立场景实例化。"
	)
	_expect(not config.supports_multiplayer, "仓库库存联网前，橡木仓库必须明确限制为单人建筑。")
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
	var warehouse_sprite := warehouse.get_node("Sprite2D") as Sprite2D
	var sprite_texture := warehouse_sprite.texture as Texture2D
	_expect(
		warehouse_sprite.texture_filter == CanvasItem.TEXTURE_FILTER_NEAREST,
		"橡木仓库像素图必须使用邻近过滤。"
	)
	_expect(
		sprite_texture.get_size().x <= 128 and sprite_texture.get_size().y <= 128,
		"橡木仓库贴图必须遵守单张不超过128×128的规则。"
	)
	var warehouse_image := sprite_texture.get_image()
	_expect(_has_binary_alpha(warehouse_image), "橡木仓库像素图不得包含半透明脏边。")
	_expect(not _has_legacy_magenta_fringe(warehouse_image), "橡木仓库轮廓不得残留旧素材的紫色边缘。")
	var player_core := warehouse.get_node("PlayerCoreBody") as StaticBody2D
	var player_core_shape := player_core.get_node("CollisionShape2D") as CollisionShape2D
	var player_core_circle := player_core_shape.shape as CircleShape2D
	_expect(
		player_core.collision_layer == 1024
		and player_core.collision_mask == 2
		and player_core_circle != null
		and is_equal_approx(player_core_circle.radius, 9.0),
		"仓库树干核心必须使用仅供玩家碰撞的TowerCore圆形体积。"
	)
	_expect(
		warehouse.health_bar.get_script() == PLANT_HEALTH_BAR_SCRIPT
		and warehouse.health_bar.size == Vector2(44, 5)
		and warehouse.health_bar.scale == Vector2.ONE
		and not warehouse.health_bar.visible,
		"仓库必须实例化44×5且满血隐藏的独立植物血条。"
	)
	var idle_animation := warehouse.idle_animation_player.get_animation(&"idle")
	_expect(
		idle_animation != null
		and warehouse.idle_animation_player.is_playing()
		and idle_animation.loop_mode == Animation.LOOP_LINEAR,
		"橡木仓库必须持续播放低频循环待机动画。"
	)
	if idle_animation != null:
		for track_index in range(idle_animation.get_track_count()):
			var track_path := str(idle_animation.track_get_path(track_index))
			_expect(
				not track_path.contains(":scale"),
				"仓库待机动画不得缩放像素图。"
			)
			if track_path.ends_with(":position"):
				_expect(
					idle_animation.track_get_interpolation_type(track_index)
					== Animation.INTERPOLATION_NEAREST,
					"仓库待机位移必须使用阶跃插值避免亚像素模糊。"
				)
				for key_index in range(idle_animation.track_get_key_count(track_index)):
					var position_key: Vector2 = idle_animation.track_get_key_value(
						track_index,
						key_index
					)
					_expect(
						position_key == position_key.round(),
						"仓库待机动画的所有位移关键帧都必须落在整数像素。"
					)
	var background := warehouse.storage_panel.get_node("Overlay/PanelRoot/Background") as TextureRect
	_expect(background.texture.get_size() == Vector2(724, 543), "仓库界面底图必须匹配724×543设计画布。")
	var prompt := warehouse.interaction_prompt
	var key_label := prompt.get_node("PromptMargin/PromptRow/Keycap/KeyLabel") as Label
	var action_label := prompt.get_node("PromptMargin/PromptRow/ActionLabel") as Label
	_expect(prompt.scale == Vector2(0.5, 0.5), "仓库提示必须用0.5静态缩放抵消塔防镜头放大。")
	_expect(prompt.custom_minimum_size == Vector2(104, 28), "仓库提示内部画布必须保持104×28。")
	_expect(key_label.text == "F" and action_label.text == "打开仓库", "仓库提示必须使用独立F键帽与精简文案。")
	var prompt_bottom := prompt.position.y + prompt.size.y * prompt.scale.y
	_expect(prompt_bottom <= warehouse.health_bar.position.y - 1.0, "仓库提示不得与生命条重叠。")


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


func _test_plant_health_bar(warehouse: OakWarehouse) -> void:
	var starting_health := warehouse.current_health
	_expect(
		warehouse.receive_damage(50, null, Vector2.ZERO, EnemyConfig.DamageType.PHYSICAL)
		and warehouse.current_health == starting_health - 40,
		"仓库受到50点物理伤害时必须在10物防后实际承受40点。"
	)
	await process_frame
	_expect(warehouse.health_bar.visible, "植物受伤后独立血条必须淡入显示。")
	warehouse.receive_healing(40)
	await create_timer(0.5).timeout
	_expect(not warehouse.health_bar.visible, "植物回满生命后独立血条必须淡出隐藏。")


func _test_detail_layout(panel: OakWarehousePanel) -> void:
	var item_detail := panel.get_node("Overlay/PanelRoot/ItemDetail") as Control
	var item_title := item_detail.get_node("ItemTitle") as Label
	var item_category := item_detail.get_node("ItemCategory") as Label
	var item_description := item_detail.get_node("ItemDescription") as RichTextLabel
	_expect(item_detail.clip_contents, "仓库详情框必须裁剪所有超出边界的内容。")
	_expect(item_title.clip_text and item_category.clip_text, "详情标题与分类必须在各自区域内裁剪。")
	_expect(
		item_description.clip_contents and not item_description.scroll_active,
		"物品描述必须稳定裁剪且不得出现突出的滚动条。"
	)
	_expect(item_description.text.contains("双击"), "仓库详情区必须提示双击快速移动。")
	var description_rect := Rect2(item_description.position, item_description.size)
	var detail_rect := Rect2(Vector2.ZERO, item_detail.size)
	_expect(
		detail_rect.encloses(description_rect.grow(8.0)),
		"物品描述四周必须保留至少8像素安全内边距。"
	)


func _test_slot_transfer_interactions(run_state: RunStateStore, warehouse: OakWarehouse) -> void:
	var panel := warehouse.storage_panel
	# This suite validates transfer behavior, not the global button SFX playback.
	panel.move_button.set_meta(&"skip_ui_click_audio", true)
	_expect(run_state.try_add_item_count(WOOD, 17), "测试物资必须能整叠加入背包。")
	_expect(run_state.get_item_count(0) == 17, "背包测试木头数量必须为17。")
	panel.call("_refresh_all")
	panel.player_slots[0].call("_on_pressed")
	_expect(
		panel.selected_source == OakWarehousePanel.ItemSource.PLAYER
		and panel.selected_slot_index == 0,
		"单击背包槽位必须只选中物品。"
	)
	_expect(warehouse.get_storage_item(0) == null, "单击槽位不得立即移动物品。")
	panel.move_button.pressed.emit()
	_expect(run_state.get_item(0) == null, "物资移入仓库后来源槽必须清空。")
	_expect(warehouse.get_storage_item_count(0) == 17, "移动按钮必须把整叠物资移入仓库。")

	var double_click := InputEventMouseButton.new()
	double_click.button_index = MOUSE_BUTTON_LEFT
	double_click.pressed = true
	double_click.double_click = true
	panel.storage_slots[0].call("_on_gui_input", double_click)
	_expect(
		warehouse.get_storage_item(0) == null and run_state.get_item_count(0) == 17,
		"双击仓储槽必须把整叠物品快速移回背包。"
	)
	panel.player_slots[0].call("_on_gui_input", double_click)
	_expect(
		run_state.get_item(0) == null and warehouse.get_storage_item_count(0) == 17,
		"双击背包槽必须把整叠物品快速移入仓库。"
	)
	panel.storage_slots[0].call("_on_gui_input", double_click)
	_expect(
		warehouse.get_storage_item(0) == null and run_state.get_item_count(0) == 17,
		"双击往返移动不得丢失物品数量。"
	)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _has_binary_alpha(image: Image) -> bool:
	for y in range(image.get_height()):
		for x in range(image.get_width()):
			var alpha := image.get_pixel(x, y).a
			if alpha > 0.001 and alpha < 0.999:
				return false
	return true


func _has_legacy_magenta_fringe(image: Image) -> bool:
	var legacy_fringe := Color8(91, 20, 62, 255)
	for y in range(image.get_height()):
		for x in range(image.get_width()):
			var pixel := image.get_pixel(x, y)
			if pixel.a <= 0.001:
				continue
			if (
				absf(pixel.r - legacy_fringe.r) < 0.02
				and absf(pixel.g - legacy_fringe.g) < 0.02
				and absf(pixel.b - legacy_fringe.b) < 0.02
			):
				return true
	return false
