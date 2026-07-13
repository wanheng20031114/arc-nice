extends SceneTree

const WAREHOUSE_SCENE := preload("res://scene/plant_defense/oak_warehouse.tscn")
const PLAYER_SCENE := preload("res://scene/player/weishidaier/player_weishidaier.tscn")
const WOOD := preload("res://resources/config/materials/material_wood.tres")
const APPLE := preload("res://resources/config/collectibles/collectible_apple.tres")
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
	_test_authoritative_shared_storage(run_state, warehouse)
	await _test_unique_nearest_interaction(player, warehouse, config, fixture)

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
	_expect(config.supports_multiplayer, "共享仓库权威事务就绪后，橡木仓库必须允许多人放置。")
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
		warehouse_sprite.scale == Vector2(0.5, 0.5)
		and sprite_texture.get_size() * warehouse_sprite.scale == Vector2(32, 32),
		"64×64仓库像素图必须以0.5静态缩放收进32×32占格。"
	)
	_expect(
		sprite_texture.get_size().x <= 128 and sprite_texture.get_size().y <= 128,
		"橡木仓库贴图必须遵守单张不超过128×128的规则。"
	)
	var warehouse_image := sprite_texture.get_image()
	_expect(_has_binary_alpha(warehouse_image), "橡木仓库像素图不得包含半透明脏边。")
	_expect(not _has_legacy_magenta_fringe(warehouse_image), "橡木仓库轮廓不得残留旧素材的紫色边缘。")
	var body_shape := warehouse.get_node("CollisionShape2D") as CollisionShape2D
	var body_rectangle := body_shape.shape as RectangleShape2D
	_expect(
		body_shape.position == Vector2.ZERO
		and body_rectangle != null
		and body_rectangle.size == Vector2(28, 28),
		"仓库接触碰撞必须以28×28居中并完整留在2×2占格内。"
	)
	var player_core := warehouse.get_node("PlayerCoreBody") as StaticBody2D
	var player_core_shape := player_core.get_node("CollisionShape2D") as CollisionShape2D
	var player_core_circle := player_core_shape.shape as CircleShape2D
	_expect(
		player_core.collision_layer == 1024
		and player_core.collision_mask == 2
		and player_core_circle != null
		and is_equal_approx(player_core_circle.radius, 7.0)
		and player_core.position == Vector2(0, 6),
		"仓库树干核心必须使用仅供玩家碰撞的TowerCore圆形体积。"
	)
	var interaction_shape := warehouse.interaction_area.get_node("CollisionShape2D") as CollisionShape2D
	var interaction_circle := interaction_shape.shape as CircleShape2D
	_expect(
		interaction_circle != null and is_equal_approx(interaction_circle.radius, 28.0),
		"仓库交互半径必须收紧到28像素。"
	)
	_expect(
		warehouse.health_bar.get_script() == PLANT_HEALTH_BAR_SCRIPT
		and warehouse.health_bar.size == Vector2(32, 5)
		and warehouse.health_bar.scale == Vector2.ONE
		and not warehouse.health_bar.visible,
		"仓库必须实例化32×5且满血隐藏的独立植物血条。"
	)
	var idle_animation := warehouse.idle_animation_player.get_animation(&"idle")
	_expect(
		idle_animation != null
		and warehouse.idle_animation_player.is_playing()
		and idle_animation.loop_mode == Animation.LOOP_LINEAR,
		"橡木仓库必须持续播放低频循环待机动画。"
	)
	if idle_animation != null:
		var opaque_bounds := _get_opaque_bounds(warehouse_image)
		var footprint_rect := Rect2(Vector2(-16, -16), Vector2(32, 32))
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
						position_key == position_key.round()
						and is_zero_approx(position_key.x)
						and position_key.y >= -1.0
						and position_key.y <= 0.0,
						"仓库待机动画必须只在占格内做最多1像素的整数上移。"
					)
					var subject_rect := Rect2(
						Vector2(opaque_bounds.position) * warehouse_sprite.scale
						- sprite_texture.get_size() * warehouse_sprite.scale * 0.5
						+ position_key,
						Vector2(opaque_bounds.size) * warehouse_sprite.scale
					)
					_expect(
						footprint_rect.encloses(subject_rect),
						"仓库可见像素在完整待机动画中都必须位于32×32占格内。"
					)
	var background := warehouse.storage_panel.get_node("Overlay/PanelRoot/Background") as TextureRect
	_expect(background.texture.get_size() == Vector2(724, 543), "仓库界面底图必须匹配724×543设计画布。")
	var prompt := warehouse.interaction_prompt
	var key_label := prompt.get_node("PromptMargin/PromptRow/Keycap/KeyLabel") as Label
	var action_label := prompt.get_node("PromptMargin/PromptRow/ActionLabel") as Label
	_expect(prompt.scale == Vector2(0.5, 0.5), "仓库提示必须用0.5静态缩放抵消塔防镜头放大。")
	_expect(prompt.custom_minimum_size == Vector2(88, 26), "仓库提示内部画布必须压缩为88×26。")
	_expect(key_label.text == "F" and action_label.text == "打开仓库", "仓库提示必须使用独立F键帽与精简文案。")
	var prompt_bottom := prompt.position.y + prompt.size.y * prompt.scale.y
	var prompt_gap := warehouse.health_bar.position.y - prompt_bottom
	_expect(
		prompt_gap >= 1.0
		and prompt_gap <= 4.0
		and warehouse.health_bar.position.y - (prompt_bottom + 1.0) >= 1.0,
		"仓库提示在静止和入场动画期间都必须紧贴生命条且不得重叠。"
	)


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


func _test_unique_nearest_interaction(
	player: Player,
	first_warehouse: OakWarehouse,
	config: PlantDefenseConfig,
	fixture: Node2D
) -> void:
	var second_warehouse := WAREHOUSE_SCENE.instantiate() as OakWarehouse
	second_warehouse.position = Vector2(32, 0)
	fixture.add_child(second_warehouse)
	second_warehouse.setup(
		config,
		player,
		[Vector2i(2, 0), Vector2i(3, 0), Vector2i(2, 1), Vector2i(3, 1)]
	)
	await process_frame

	player.global_position = first_warehouse.global_position
	second_warehouse.call("_on_interaction_area_body_entered", player)
	first_warehouse.call("_refresh_interaction_selection", player)
	_expect(
		first_warehouse.is_interaction_target
		and first_warehouse.interaction_prompt.visible
		and first_warehouse.is_processing_unhandled_input()
		and not second_warehouse.is_interaction_target
		and not second_warehouse.interaction_prompt.visible
		and not second_warehouse.is_processing_unhandled_input(),
		"多个仓库交互范围重叠时只能显示最近仓库的提示。"
	)

	player.global_position = second_warehouse.global_position
	await create_timer(0.12).timeout
	_expect(
		second_warehouse.is_interaction_target
		and second_warehouse.interaction_prompt.visible
		and second_warehouse.is_processing_unhandled_input()
		and not first_warehouse.is_interaction_target
		and not first_warehouse.interaction_prompt.visible
		and not first_warehouse.is_processing_unhandled_input(),
		"玩家移动后唯一交互目标必须动态切换到新的最近仓库。"
	)

	var interact_event := InputEventAction.new()
	interact_event.action = &"interact"
	interact_event.pressed = true
	first_warehouse._unhandled_input(interact_event)
	_expect(not first_warehouse.storage_panel.is_open(), "非目标仓库不得响应F交互。")
	second_warehouse._unhandled_input(interact_event)
	_expect(
		second_warehouse.storage_panel.is_open()
		and not first_warehouse.storage_panel.is_open()
		and not first_warehouse.interaction_prompt.visible
		and not second_warehouse.interaction_prompt.visible,
		"按F只能打开唯一目标仓库，并在面板打开时隐藏全部仓库提示。"
	)
	second_warehouse.storage_panel.close()
	first_warehouse.call("_on_interaction_area_body_exited", player)
	second_warehouse.call("_on_interaction_area_body_exited", player)
	second_warehouse.queue_free()
	await process_frame


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
	run_state.discard_item(0)


func _test_authoritative_shared_storage(
	run_state: RunStateStore,
	warehouse: OakWarehouse
) -> void:
	const PEER_ID := 2
	const WAREHOUSE_NET_ID := 44
	warehouse.configure_multiplayer_storage(WAREHOUSE_NET_ID, PEER_ID, true)
	_expect(
		run_state.try_add_item_count_for_peer(PEER_ID, WOOD, 17),
		"多人测试物资必须能整叠加入指定玩家背包。"
	)
	var first_inventory_revision := run_state.get_inventory_revision_for_peer(PEER_ID)
	var first_storage_revision := warehouse.get_storage_revision()
	var store_command := OakWarehouseProtocol.make_transfer_command(
		1,
		WAREHOUSE_NET_ID,
		PEER_ID,
		OakWarehouseProtocol.TransferDirection.PLAYER_TO_STORAGE,
		0,
		first_inventory_revision,
		first_storage_revision
	)
	var store_result := warehouse.apply_transfer_command(store_command, run_state)
	_expect(bool(store_result.get("success", false)), "Host必须原子确认整叠物资存入共享仓库。")
	_expect(
		run_state.get_item_for_peer(PEER_ID, 0) == null
		and warehouse.get_storage_item_count(0) == 17,
		"成功事务必须清空来源槽且完整保留17个物资。"
	)
	_expect(
		run_state.get_inventory_revision_for_peer(PEER_ID) == first_inventory_revision + 1
		and warehouse.get_storage_revision() == first_storage_revision + 1,
		"共享仓库成功事务必须各自只递增一次背包与仓库revision。"
	)

	var duplicate_result := warehouse.apply_transfer_command(store_command, run_state)
	_expect(
		not bool(duplicate_result.get("success", false))
		and duplicate_result.get("reason") == OakWarehouseProtocol.RESULT_STALE_INVENTORY,
		"重复或并发的旧revision命令必须被稳定拒绝。"
	)
	_expect(
		warehouse.get_storage_item_count(0) == 17,
		"拒绝重复命令后共享仓库数量不得翻倍。"
	)

	var retrieve_command := OakWarehouseProtocol.make_transfer_command(
		2,
		WAREHOUSE_NET_ID,
		PEER_ID,
		OakWarehouseProtocol.TransferDirection.STORAGE_TO_PLAYER,
		0,
		run_state.get_inventory_revision_for_peer(PEER_ID),
		warehouse.get_storage_revision()
	)
	var retrieve_result := warehouse.apply_transfer_command(retrieve_command, run_state)
	_expect(bool(retrieve_result.get("success", false)), "Host必须原子确认从共享仓库取回整叠物资。")
	_expect(
		run_state.get_item_count_for_peer(PEER_ID, 0) == 17
		and warehouse.get_storage_item(0) == null,
		"取回事务必须完整恢复背包堆叠并清空仓库来源槽。"
	)
	_expect(
		(retrieve_result.get("inventory_snapshot", {}) as Dictionary).get("revision", -1)
		== run_state.get_inventory_revision_for_peer(PEER_ID)
		and (retrieve_result.get("storage_snapshot", {}) as Dictionary).get("revision", -1)
		== warehouse.get_storage_revision(),
		"事务结果必须携带可直接用于RPC确认的最新完整快照。"
	)

	_expect(
		run_state.try_add_item_count_for_peer(PEER_ID, APPLE, APPLE.collectible_max_copies),
		"仓库份数测试必须先把Peer收藏品填到配置上限。"
	)
	_expect(
		warehouse.try_add_storage_item_count(APPLE, 1, warehouse.get_storage_revision()),
		"共享仓库允许独立保存超出玩家当前生效上限的收藏品。"
	)
	var limited_storage_revision := warehouse.get_storage_revision()
	var limited_inventory_revision := run_state.get_inventory_revision_for_peer(PEER_ID)
	var limited_retrieve_command := OakWarehouseProtocol.make_transfer_command(
		3,
		WAREHOUSE_NET_ID,
		PEER_ID,
		OakWarehouseProtocol.TransferDirection.STORAGE_TO_PLAYER,
		0,
		limited_inventory_revision,
		limited_storage_revision
	)
	var limited_retrieve_result := warehouse.apply_transfer_command(
		limited_retrieve_command,
		run_state
	)
	_expect(
		not bool(limited_retrieve_result.get("success", false))
		and limited_retrieve_result.get("reason") == OakWarehouseProtocol.RESULT_TARGET_FULL,
		"Host必须拒绝从共享仓库取回会突破最大份数的收藏品。"
	)
	_expect(
		warehouse.get_storage_item(0) == APPLE
		and warehouse.get_storage_revision() == limited_storage_revision
		and run_state.get_inventory_revision_for_peer(PEER_ID) == limited_inventory_revision,
		"份数校验失败时仓库与个人背包必须原子保持不变。"
	)

	var requested_snapshot_ids: Array[int] = []
	var snapshot_request_callback := func(requested_net_id: int) -> void:
		requested_snapshot_ids.append(requested_net_id)
	warehouse.storage_snapshot_requested.connect(snapshot_request_callback)
	_expect(
		warehouse.request_multiplayer_storage_snapshot(),
		"多人仓库必须能显式请求Host重发权威快照。"
	)
	_expect(
		warehouse.multiplayer_storage_enabled
		and not warehouse.storage_panel.multiplayer_storage_snapshot_ready
		and requested_snapshot_ids == [WAREHOUSE_NET_ID],
		"请求仓库快照时必须进入只读加载态并携带正确net id。"
	)
	warehouse.storage_snapshot_requested.disconnect(snapshot_request_callback)
	_expect(
		warehouse.apply_storage_snapshot(warehouse.export_storage_snapshot()),
		"收到权威仓库快照后必须恢复可交互状态。"
	)
	warehouse.storage_panel.call("_refresh_all")
	warehouse.storage_panel.player_slots[0].call("_on_pressed")
	_expect(
		warehouse.storage_panel.discard_button.disabled,
		"多人仓库界面必须禁止直接删除共享或个人物品。"
	)
	run_state.discard_item_for_peer(PEER_ID, 0)


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


func _get_opaque_bounds(image: Image) -> Rect2i:
	var minimum := Vector2i(image.get_width(), image.get_height())
	var maximum := Vector2i(-1, -1)
	for y in range(image.get_height()):
		for x in range(image.get_width()):
			if image.get_pixel(x, y).a <= 0.001:
				continue
			minimum.x = mini(minimum.x, x)
			minimum.y = mini(minimum.y, y)
			maximum.x = maxi(maximum.x, x + 1)
			maximum.y = maxi(maximum.y, y + 1)
	if maximum.x < minimum.x or maximum.y < minimum.y:
		return Rect2i()
	return Rect2i(minimum, maximum - minimum)


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
