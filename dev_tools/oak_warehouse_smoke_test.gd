extends SceneTree

const WAREHOUSE_SCENE := preload("res://scene/plant_defense/oak_warehouse.tscn")
const WAREHOUSE_PANEL_SCENE := preload("res://scene/plant_defense/oak_warehouse_panel.tscn")
const PLAYER_SCENE := preload("res://scene/player/weishidaier/player_weishidaier.tscn")
const WOOD := preload("res://resources/config/materials/material_wood.tres")
const APPLE := preload("res://resources/config/collectibles/collectible_apple.tres")
const PLANT_HEALTH_BAR_SCRIPT := preload("res://scene/plant_defense/ui/plant_health_bar.gd")
const MP_GAME_SCRIPT := preload("res://scene/multiplayer/mp_game.gd")
const OAK_WAREHOUSE_CONFIG := preload(
	"res://resources/config/plant_defense/oak_warehouse.tres"
)

var failures: Array[String] = []


class HostNetManagerStub:
	extends Node

	var local_peer_id := 2
	var peer_send_ready_checks := 0

	func is_host() -> bool:
		return true

	func get_local_peer_id() -> int:
		return local_peer_id

	func is_peer_send_ready(_peer_id: int) -> bool:
		peer_send_ready_checks += 1
		return false


class AuthoritativePlantSystemStub:
	extends PlantSystem

	func register_warehouse(net_id: int, warehouse: OakWarehouse) -> void:
		plants_by_net_id[net_id] = warehouse
		_register_plant_footprint(
			warehouse,
			[Vector2i.ZERO],
			OAK_WAREHOUSE_CONFIG
		)


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var inventory_only := OS.get_cmdline_user_args().has("--inventory-only")
	var run_state := root.get_node("RunState") as RunStateStore
	run_state.begin_new_run(&"weishidaier", false)

	var fixture := Node2D.new()
	root.add_child(fixture)
	var player := PLAYER_SCENE.instantiate() as Player
	fixture.add_child(player)
	player.set_physics_process(false)
	var storage_panel := WAREHOUSE_PANEL_SCENE.instantiate() as OakWarehousePanel
	storage_panel.visible = false
	fixture.add_child(storage_panel)
	var warehouse := WAREHOUSE_SCENE.instantiate() as OakWarehouse
	fixture.add_child(warehouse)
	warehouse.set_shared_storage_panel(storage_panel)
	var config := PlantDefenseRegistry.get_config(&"oak_warehouse")
	warehouse.setup(
		config,
		player,
		[Vector2i.ZERO, Vector2i.RIGHT, Vector2i.DOWN, Vector2i.ONE]
	)
	await process_frame

	if not inventory_only:
		_test_config_and_scene(config, warehouse)
		await _test_plant_health_bar(warehouse)
		_test_interaction_lock(player, warehouse)
	_test_detail_layout(warehouse.storage_panel)
	await _test_slot_transfer_interactions(run_state, warehouse)
	await _test_drag_and_controller_slot_moves(run_state, warehouse)
	_test_authoritative_shared_storage(run_state, warehouse)
	if not inventory_only:
		await _test_unique_nearest_interaction(
			run_state,
			player,
			warehouse,
			config,
			fixture
		)
	warehouse.configure_multiplayer_storage(44, 2, true)
	fixture.remove_child(warehouse)
	_expect(
		not warehouse.is_multiplayer_storage_ready()
		and not warehouse.request_multiplayer_storage_snapshot(),
		"仓库离开场景树后必须拒绝网络请求，不得启动已脱离场景树的计时器。"
	)
	warehouse.queue_free()

	fixture.queue_free()
	for _frame in range(3):
		await process_frame
	run_state.begin_new_run(&"weishidaier", false)

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
	_expect(config.max_health == 2000, "橡木仓库生命值必须为2000。")
	_expect(
		config.physical_defense == 0 and config.magic_defense == 0,
		"橡木仓库的物理防御与法术防御必须都为0。"
	)
	_expect(
		warehouse.max_health == 2000 and warehouse.current_health == 2000,
		"橡木仓库实例必须以2000点满生命生成。"
	)
	_expect(
		config.plant_scene.resource_path.begins_with("res://scene/plant_defense/"),
		"橡木仓库必须继续由scene/plant_defense下的独立场景实例化。"
	)
	_expect(config.supports_multiplayer, "共享仓库权威事务就绪后，橡木仓库必须允许多人放置。")
	_expect(
		PlantDefenseRegistry.get_all_configs().size() == 15
		and PlantDefenseRegistry.get_all_configs().has(
			PlantDefenseRegistry.get_config(&"excavator")
		)
		and PlantDefenseRegistry.get_all_configs().has(
			PlantDefenseRegistry.get_config(&"stone_mill")
		)
		and PlantDefenseRegistry.get_all_configs().has(
			PlantDefenseRegistry.get_config(&"simple_fence")
		),
		"植物选择必须包含全部15种建筑，包括挖土装置、石磨台、简易围栏、植物培育中心、竹筒迫击炮、紫阳花雨幕塔与葡萄电弧塔。"
	)
	_expect(warehouse.storage_items.size() == 20, "仓库必须拥有20个物品格。")
	_expect(
		warehouse.get_node_or_null("OakWarehousePanel") == null
		and warehouse.storage_panel != null
		and warehouse.storage_panel.get_parent() != warehouse,
		"仓库建筑场景不得再内嵌独立面板，必须引用游戏级共享面板。"
	)
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
		sprite_texture.get_size() == Vector2(64, 64),
		"橡木仓库必须使用真正的64×64逻辑像素画布。"
	)
	var warehouse_image := sprite_texture.get_image()
	_expect(_has_binary_alpha(warehouse_image), "橡木仓库像素图不得包含半透明脏边。")
	_expect(not _has_legacy_magenta_fringe(warehouse_image), "橡木仓库轮廓不得残留旧素材的紫色边缘。")
	var opaque_bounds := _get_opaque_bounds(warehouse_image)
	_expect(
		opaque_bounds.has_area()
		and opaque_bounds.size.x <= 60
		and opaque_bounds.size.y <= 62,
		"橡木仓库可见主体必须收进60×62源像素预算。"
	)
	var subject_rect := _get_centered_sprite_subject_rect(
		warehouse_sprite,
		opaque_bounds,
		sprite_texture.get_size()
	)
	_expect(
		Rect2(Vector2(-16, -16), Vector2(32, 32)).encloses(subject_rect),
		"橡木仓库应用0.5场景变换后必须完整位于32×32世界占格内。"
	)
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
		for track_index in range(idle_animation.get_track_count()):
			var track_path := str(idle_animation.track_get_path(track_index))
			_expect(
				not track_path.ends_with(":position")
				and not track_path.ends_with(":scale"),
				"仓库待机动画不得再移动或缩放整栋建筑。"
			)
	var background := warehouse.storage_panel.get_node("Overlay/PanelRoot/Background") as TextureRect
	_expect(background.texture.get_size() == Vector2(724, 543), "仓库界面底图必须匹配724×543设计画布。")
	var prompt := warehouse.interaction_prompt
	var key_label := prompt.get_node("PromptMargin/PromptRow/Keycap/KeyLabel") as Label
	var action_label := prompt.get_node("PromptMargin/PromptRow/ActionLabel") as Label
	_expect(prompt.scale == Vector2(0.5, 0.5), "仓库提示必须用0.5静态缩放抵消塔防镜头放大。")
	_expect(
		warehouse.prompt_rest_position == Vector2(-22, -33),
		"仓库提示静止位置必须位于血条正上方。"
	)
	_expect(prompt.custom_minimum_size == Vector2(88, 26), "仓库提示内部画布必须压缩为88×26。")
	_expect(key_label.text == "F" and action_label.text == "打开仓库", "仓库提示必须使用独立F键帽与精简文案。")
	_expect(
		warehouse.health_bar.position == Vector2(-16, -20)
		and warehouse.health_bar.size == Vector2(32, 5),
		"仓库血条必须贴近屋顶并保持32×5世界尺寸。"
	)
	var prompt_bottom := (
		warehouse.prompt_rest_position.y + prompt.size.y * prompt.scale.y
	)
	var prompt_health_gap := warehouse.health_bar.position.y - prompt_bottom
	var health_bottom := warehouse.health_bar.position.y + warehouse.health_bar.size.y
	var health_roof_gap := subject_rect.position.y - health_bottom
	_expect(
		absf(prompt_health_gap) <= 0.01
		and absf(health_roof_gap) <= 1.0,
		"仓库提示、血条与屋顶必须自上而下紧密衔接且不留异常空隙。"
	)
	warehouse.call("_set_prompt_reveal_offset", 1.0)
	_expect(prompt.position == Vector2(-22, -32), "仓库提示入场只能使用-32整数Y坐标。")
	var reveal_prompt_bottom := prompt.position.y + prompt.size.y * prompt.scale.y
	_expect(
		reveal_prompt_bottom <= warehouse.health_bar.position.y + 1.0,
		"仓库提示入场最多与血条相接1像素，不得压入建筑主体。"
	)
	warehouse.call("_set_prompt_reveal_offset", 0.0)
	_expect(prompt.position == Vector2(-22, -33), "仓库提示静止时必须回到-33整数Y坐标。")


func _test_interaction_lock(player: Player, warehouse: OakWarehouse) -> void:
	warehouse.call("_on_interaction_area_body_entered", player)
	_expect(warehouse.interaction_prompt.visible, "玩家靠近后必须显示按F打开提示。")
	var interact_event := InputEventKey.new()
	interact_event.physical_keycode = KEY_F
	interact_event.pressed = true
	_expect(interact_event.is_action_pressed(&"interact"), "键盘F必须继续映射到interact动作。")
	warehouse._unhandled_input(interact_event)
	_expect(warehouse.storage_panel.is_open(), "仓库界面必须能够打开。")
	_expect(player.controls_locked, "打开仓库时必须锁定玩家操作。")
	warehouse.storage_panel._input(interact_event)
	_expect(not warehouse.storage_panel.is_open(), "仓库打开后再次按F必须关闭界面。")
	_expect(not player.controls_locked, "按F关闭仓库后必须解除玩家操作锁。")

	warehouse._unhandled_input(interact_event)
	_expect(warehouse.storage_panel.is_open(), "仓库关闭后必须能再次打开。")
	var joypad_y := InputEventJoypadButton.new()
	joypad_y.button_index = JOY_BUTTON_Y
	joypad_y.pressed = true
	_expect(joypad_y.is_action_pressed(&"interact"), "手柄Y必须继续映射到interact动作。")
	warehouse.storage_panel._input(joypad_y)
	_expect(not warehouse.storage_panel.is_open(), "仓库打开后按手柄Y必须关闭界面。")
	_expect(not player.controls_locked, "按手柄Y关闭仓库后必须解除玩家操作锁。")


func _test_plant_health_bar(warehouse: OakWarehouse) -> void:
	var starting_health := warehouse.current_health
	_expect(
		warehouse.receive_damage(50, null, Vector2.ZERO, EnemyConfig.DamageType.PHYSICAL)
		and warehouse.current_health == starting_health - 50,
		"0物防仓库受到50点物理伤害时必须实际承受50点。"
	)
	await process_frame
	_expect(warehouse.health_bar.visible, "植物受伤后独立血条必须淡入显示。")
	warehouse.receive_healing(50)
	await create_timer(0.5).timeout
	_expect(not warehouse.health_bar.visible, "植物回满生命后独立血条必须淡出隐藏。")


func _test_unique_nearest_interaction(
	run_state: RunStateStore,
	player: Player,
	first_warehouse: OakWarehouse,
	config: PlantDefenseConfig,
	fixture: Node2D
) -> void:
	var second_warehouse := WAREHOUSE_SCENE.instantiate() as OakWarehouse
	second_warehouse.position = Vector2(32, 0)
	fixture.add_child(second_warehouse)
	second_warehouse.set_shared_storage_panel(first_warehouse.storage_panel)
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
		second_warehouse.is_modal_ui_open()
		and not first_warehouse.is_modal_ui_open()
		and second_warehouse.storage_panel == first_warehouse.storage_panel
		and second_warehouse.storage_panel.warehouse == second_warehouse
		and not first_warehouse.interaction_prompt.visible
		and not second_warehouse.interaction_prompt.visible,
		"按F只能打开唯一目标仓库，并在面板打开时隐藏全部仓库提示。"
	)
	await _test_shared_panel_rebinding(
		run_state,
		player,
		first_warehouse,
		second_warehouse
	)
	first_warehouse.call("_on_interaction_area_body_exited", player)
	second_warehouse.call("_on_interaction_area_body_exited", player)
	if not second_warehouse.is_queued_for_deletion():
		second_warehouse.queue_free()
	await process_frame


func _test_shared_panel_rebinding(
	run_state: RunStateStore,
	player: Player,
	first_warehouse: OakWarehouse,
	second_warehouse: OakWarehouse
) -> void:
	var panel := first_warehouse.storage_panel
	var refresh_callback := Callable(panel, "_refresh_all")
	for warehouse in [first_warehouse, second_warehouse]:
		warehouse.storage_items.fill(null)
		warehouse.storage_stack_counts.fill(0)
		warehouse.storage_items[0] = WOOD
		warehouse.storage_stack_counts[0] = 1
		warehouse.storage_revision = 77
	first_warehouse.warehouse_net_id = 101
	second_warehouse.warehouse_net_id = 202
	panel.call("_refresh_all")
	var stale_drag_data := panel.make_slot_drag_data(
		OakWarehousePanel.ItemSource.STORAGE,
		0
	)
	_expect(
		int(stale_drag_data.get("warehouse_instance_id", 0))
		== second_warehouse.get_instance_id()
		and int(stale_drag_data.get("warehouse_net_id", 0)) == 202,
		"共享面板拖拽凭据必须同时记录仓库实例与网络身份。"
	)

	panel.queued_quick_moves.append({"source": OakWarehousePanel.ItemSource.STORAGE})
	panel.controller_accept_held = true
	panel.controller_drag_active = true
	panel.controller_device = 0
	panel.controller_drag_data = stale_drag_data.duplicate(true)
	panel.virtual_cursor.show()
	panel.set_process(true)
	panel.multiplayer_slot_drop_pending = true
	panel.multiplayer_slot_drop_source = OakWarehousePanel.ItemSource.STORAGE
	panel.multiplayer_slot_drop_source_index = 0
	panel.multiplayer_slot_drop_target = OakWarehousePanel.ItemSource.PLAYER
	panel.multiplayer_slot_drop_target_index = 19
	panel.open_for(first_warehouse, player)
	_expect(
		panel.is_open()
		and panel.warehouse == first_warehouse
		and first_warehouse.is_modal_ui_open()
		and not second_warehouse.is_modal_ui_open(),
		"同一个共享面板必须能从一栋仓库原子切换绑定到另一栋。"
	)
	_expect(
		first_warehouse.storage_changed.is_connected(refresh_callback)
		and not second_warehouse.storage_changed.is_connected(refresh_callback)
		and run_state.inventory_changed.is_connected(refresh_callback),
		"重绑后只能订阅当前仓库与当前打开会话的背包信号。"
	)
	_expect(
		panel.queued_quick_moves.is_empty()
		and not panel.controller_accept_held
		and not panel.controller_drag_active
		and panel.controller_drag_data.is_empty()
		and not panel.virtual_cursor.visible
		and not panel.multiplayer_slot_drop_pending,
		"跨仓重绑必须清空快速移动、手柄拖拽与多人落点等待状态。"
	)
	_expect(
		not panel.can_drop_slot_data(
			stale_drag_data,
			OakWarehousePanel.ItemSource.PLAYER,
			19
		),
		"即使两栋仓库revision与物品完全相同，旧仓库拖拽凭据也不得串仓提交。"
	)

	panel.close()
	_expect(
		not panel.is_open()
		and panel.warehouse == null
		and panel.tracked_player == null
		and not first_warehouse.storage_changed.is_connected(refresh_callback)
		and not run_state.inventory_changed.is_connected(refresh_callback),
		"关闭共享面板必须解绑仓库、玩家以及所有内容变更信号。"
	)
	_expect(run_state.try_add_item_count(WOOD, 1), "隐藏面板断连测试必须准备一份木材。")
	first_warehouse.storage_changed.emit()
	_expect(
		panel.player_slots[0].item == null and panel.storage_slots[0].item == null,
		"关闭后背包与仓库变化不得继续刷新隐藏面板。"
	)
	_expect(run_state.discard_item(0), "隐藏面板断连测试物品必须能清理。")
	for warehouse in [first_warehouse, second_warehouse]:
		warehouse.storage_items.fill(null)
		warehouse.storage_stack_counts.fill(0)
		warehouse.storage_changed.emit()

	panel.open_for(first_warehouse, player)
	player.died.emit()
	_expect(
		not panel.is_open() and panel.warehouse == null and not player.controls_locked,
		"玩家死亡信号必须关闭、解锁并解绑共享仓库面板。"
	)
	panel.open_for(first_warehouse, player)
	first_warehouse.call("_on_interaction_area_body_exited", player)
	_expect(
		not panel.is_open() and panel.warehouse == null,
		"玩家离开当前仓库交互范围时必须关闭并解绑共享面板。"
	)
	first_warehouse.call("_on_interaction_area_body_entered", player)
	panel.open_for(second_warehouse, player)
	second_warehouse.receive_damage(
		second_warehouse.current_health + second_warehouse.get_effective_physical_defense()
	)
	_expect(
		not panel.is_open() and panel.warehouse == null,
		"当前仓库死亡时必须关闭并解绑游戏级共享面板。"
	)


func _test_detail_layout(panel: OakWarehousePanel) -> void:
	var storage_title := panel.get_node("Overlay/PanelRoot/StorageTitle") as Label
	var player_title := panel.get_node("Overlay/PanelRoot/PlayerTitle") as Label
	_expect(
		Rect2(storage_title.position, storage_title.size)
		== Rect2(45.0, 78.0, 285.0, 30.0)
		and Rect2(player_title.position, player_title.size)
		== Rect2(394.0, 78.0, 285.0, 30.0),
		"仓库与背包标题必须同步下移3像素，并保持栏内水平对齐。"
	)
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
	var button_specs := [
		{
			"path": "Overlay/PanelRoot/UseButton",
			"rect": Rect2(50.0, 421.0, 61.0, 59.0),
		},
		{
			"path": "Overlay/PanelRoot/MoveButton",
			"rect": Rect2(117.0, 421.0, 61.0, 59.0),
		},
		{
			"path": "Overlay/PanelRoot/DiscardButton",
			"rect": Rect2(545.0, 421.0, 61.0, 59.0),
		},
		{
			"path": "Overlay/PanelRoot/CloseButton",
			"rect": Rect2(612.0, 421.0, 61.0, 59.0),
		},
	]
	for spec: Dictionary in button_specs:
		var button := panel.get_node(str(spec["path"])) as Button
		_expect(
			Rect2(button.position, button.size) == spec["rect"],
			"仓库按钮点击区域必须精确贴合底图中的像素按钮框：%s。" % spec["path"]
		)
		for style_name in [&"normal", &"hover", &"pressed", &"focus", &"disabled"]:
			var button_style := button.get_theme_stylebox(style_name)
			_expect(
				button_style is StyleBoxEmpty
				and is_equal_approx(
					button_style.get_content_margin(SIDE_BOTTOM),
					4.0
				),
				"仓库按钮不得在底图像素按钮框上重复绘制圆角边框：%s/%s。" % [
					spec["path"],
					style_name,
				]
			)
	var half_button := panel.get_node("Overlay/PanelRoot/HalfButton") as Button
	var quantity_button := panel.get_node("Overlay/PanelRoot/QuantityButton") as Button
	_expect(
		half_button.text == "取一半"
		and Rect2(half_button.position, half_button.size)
		== Rect2(331.0, 302.0, 62.0, 26.0),
		"取一半按钮必须作为原生场景节点固定在双容器之间。"
	)
	_expect(
		quantity_button.text == "取固定数量"
		and Rect2(quantity_button.position, quantity_button.size)
		== Rect2(331.0, 334.0, 62.0, 26.0),
		"取固定数量按钮必须作为原生场景节点固定在双容器之间。"
	)
	var quantity_dialog := panel.get_node("QuantityDialog") as ConfirmationDialog
	var quantity_input := quantity_dialog.get_node(
		"ContentMargin/Content/QuantityInput"
	) as LineEdit
	_expect(
		not quantity_dialog.dialog_hide_on_ok
		and quantity_dialog.exclusive
		and quantity_dialog.get_ok_button().text == "确认"
		and quantity_dialog.get_cancel_button().text == "取消",
		"数量输入必须使用不会在无效确认时自动关闭的独占ConfirmationDialog。"
	)
	_expect(
		quantity_input.virtual_keyboard_type == LineEdit.KEYBOARD_TYPE_NUMBER
		and quantity_input.max_length >= 4,
		"固定数量输入框必须提供数字键盘，并允许输入超上限值后由事务层明确拒绝。"
	)


func _test_slot_transfer_interactions(run_state: RunStateStore, warehouse: OakWarehouse) -> void:
	var panel := warehouse.storage_panel
	panel.open_for(warehouse, warehouse.owner_player)
	# This suite validates transfer behavior, not the global button SFX playback.
	panel.move_button.set_meta(&"skip_ui_click_audio", true)
	_expect(run_state.try_add_item_count(WOOD, 17), "测试物资必须能整叠加入背包。")
	_expect(run_state.get_item_count(0) == 17, "背包测试木头数量必须为17。")
	panel.call("_refresh_all")
	await _test_partial_quantity_controls(run_state, warehouse, panel)
	await _test_reopened_panel_click_session(run_state, warehouse, panel)
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

	_simulate_double_click(panel.storage_slots[0])
	await process_frame
	_expect(
		warehouse.get_storage_item(0) == null and run_state.get_item_count(0) == 17,
		"双击仓储槽必须把整叠物品快速移回背包。"
	)
	_expect(
		panel.status_label.text == "物品已移动",
		"双击的原生Button release不得在延迟提交后清空移动状态。"
	)
	_simulate_double_click(panel.player_slots[0])
	await process_frame
	_expect(
		run_state.get_item(0) == null and warehouse.get_storage_item_count(0) == 17,
		"双击背包槽必须把整叠物品快速移入仓库。"
	)
	_simulate_double_click(panel.storage_slots[0])
	await process_frame
	_expect(
		warehouse.get_storage_item(0) == null and run_state.get_item_count(0) == 17,
		"双击往返移动不得丢失物品数量。"
	)
	_send_mouse_click(panel.player_slots[0], Vector2(24.0, 24.0))
	var outside_release_press := InputEventMouseButton.new()
	outside_release_press.button_index = MOUSE_BUTTON_LEFT
	outside_release_press.pressed = true
	outside_release_press.position = Vector2(24.0, 24.0)
	panel.player_slots[0].call("_on_gui_input", outside_release_press)
	var outside_release := InputEventMouseButton.new()
	outside_release.button_index = MOUSE_BUTTON_LEFT
	outside_release.pressed = false
	outside_release.position = Vector2(-2.0, 24.0)
	panel.player_slots[0].call("_on_gui_input", outside_release)
	_expect(
		run_state.get_item_count(0) == 17 and warehouse.get_storage_item(0) == null,
		"第二次点击在槽外松开时不得误触快速移动。"
	)
	_send_mouse_click(panel.player_slots[0], Vector2(24.0, 24.0))
	_send_mouse_click(panel.player_slots[1], Vector2(24.0, 24.0))
	_send_mouse_click(panel.player_slots[0], Vector2(24.0, 24.0))
	await process_frame
	_expect(
		run_state.get_item_count(0) == 17 and warehouse.get_storage_item(0) == null,
		"A槽、其他槽、A槽的非连续点击不得被识别成双击。"
	)
	panel.open()
	for _frame in 2:
		await process_frame
	var sequence_before_viewport_clicks := panel.panel_mouse_press_sequence
	await _send_viewport_double_click(panel.player_slots[0])
	_expect(
		panel.panel_mouse_press_sequence == sequence_before_viewport_clicks + 2,
		"Viewport真实双击的每次物理按下必须且只能计入一个面板点击序号。"
	)
	_expect(
		run_state.get_item(0) == null and warehouse.get_storage_item_count(0) == 17,
		"Viewport从_input复制到gui_input的真实双击必须把背包物品移入仓库。"
	)
	_expect(
		warehouse.transfer_storage_stack_to_player(0, run_state),
		"真实双击回归测试结束后必须能恢复测试物品。"
	)
	run_state.discard_item(0)


func _test_partial_quantity_controls(
	run_state: RunStateStore,
	warehouse: OakWarehouse,
	panel: OakWarehousePanel
) -> void:
	panel.player_slots[0].call("_on_pressed")
	_expect(
		not panel.half_button.disabled and not panel.quantity_button.disabled,
		"可堆叠且数量大于1的物品必须启用取一半与取固定数量。"
	)
	var inventory_revision := run_state.get_inventory_revision()
	var storage_revision := warehouse.get_storage_revision()
	panel.half_button.pressed.emit()
	_expect(
		run_state.get_item_count(0) == 8
		and warehouse.get_storage_item_count(0) == 9,
		"17个物品取一半必须按向上取整移动9个，并在来源保留8个。"
	)
	_expect(
		run_state.get_inventory_revision() == inventory_revision + 1
		and warehouse.get_storage_revision() == storage_revision + 1,
		"本地部分转移必须让背包与仓库revision各只递增一次。"
	)

	panel.storage_slots[0].call("_on_pressed")
	panel.quantity_button.pressed.emit()
	_expect(
		panel.quantity_dialog.visible
		and panel.quantity_prompt.text.contains("9"),
		"取固定数量必须打开原生输入对话框并显示当前来源数量。"
	)
	var invalid_inventory_snapshot := run_state.export_inventory_snapshot()
	var invalid_storage_snapshot := warehouse.export_storage_snapshot()
	panel.quantity_input.text = "10"
	panel.quantity_dialog.confirmed.emit()
	_expect(
		panel.quantity_dialog.visible
		and panel.quantity_error.text.contains("超过")
		and run_state.export_inventory_snapshot() == invalid_inventory_snapshot
		and warehouse.export_storage_snapshot() == invalid_storage_snapshot,
		"输入超过来源数量时必须保留对话框、显示错误且两端零写入。"
	)
	panel.quantity_input.text = "abc"
	panel.quantity_dialog.confirmed.emit()
	_expect(
		panel.quantity_dialog.visible
		and panel.quantity_error.text.contains("正整数")
		and run_state.export_inventory_snapshot() == invalid_inventory_snapshot
		and warehouse.export_storage_snapshot() == invalid_storage_snapshot,
		"非数字固定数量必须被拒绝且两端零写入。"
	)

	inventory_revision = run_state.get_inventory_revision()
	storage_revision = warehouse.get_storage_revision()
	panel.quantity_input.text = "4"
	panel.quantity_dialog.confirmed.emit()
	_expect(
		not panel.quantity_dialog.visible
		and run_state.get_item_count(0) == 12
		and warehouse.get_storage_item_count(0) == 5,
		"合法固定数量必须只移动输入的4个物品并关闭对话框。"
	)
	_expect(
		run_state.get_inventory_revision() == inventory_revision + 1
		and warehouse.get_storage_revision() == storage_revision + 1,
		"固定数量转移成功时双方revision必须各只递增一次。"
	)
	_expect(
		warehouse.transfer_storage_stack_to_player(0, run_state)
		and run_state.get_item_count(0) == 17
		and warehouse.get_storage_item(0) == null,
		"部分转移交互测试结束后必须无损恢复17个测试物品。"
	)
	_expect(
		warehouse.try_add_storage_item_count(
			APPLE,
			1,
			warehouse.get_storage_revision()
		),
		"不可叠加按钮状态测试必须准备一个收藏品。"
	)
	panel.call("_refresh_all")
	panel.storage_slots[0].call("_on_pressed")
	_expect(
		panel.half_button.disabled and panel.quantity_button.disabled,
		"不可叠加物品即使可在仓库中保存，也必须禁用两种数量拆分按钮。"
	)
	warehouse.discard_storage_item(0)
	panel.call("_clear_selection")
	panel.call("_refresh_all")
	await process_frame


func _test_reopened_panel_click_session(
	run_state: RunStateStore,
	warehouse: OakWarehouse,
	panel: OakWarehousePanel
) -> void:
	var previous_session_generation := panel.panel_session_generation
	var previous_gesture_revision := panel.get_slot_gesture_revision(
		OakWarehousePanel.ItemSource.PLAYER
	)
	_send_mouse_click(panel.player_slots[0], Vector2(24.0, 24.0))
	panel.close()
	panel.open_for(warehouse, warehouse.owner_player)
	var reopened_gesture_revision := panel.get_slot_gesture_revision(
		OakWarehousePanel.ItemSource.PLAYER
	)
	_expect(
		panel.panel_session_generation == previous_session_generation + 1
		and reopened_gesture_revision != previous_gesture_revision,
		"关闭后重开同一仓库必须创建新的面板点击会话。"
	)
	_send_mouse_click(panel.player_slots[0], Vector2(24.0, 24.0))
	await process_frame
	_expect(
		run_state.get_item_count(0) == 17 and warehouse.get_storage_item(0) == null,
		"420毫秒内重开同仓后的首次点击不得沿用旧会话并误触双击移动。"
	)
	_send_mouse_click(panel.player_slots[0], Vector2(24.0, 24.0))
	await process_frame
	_expect(
		run_state.get_item(0) == null and warehouse.get_storage_item_count(0) == 17,
		"新会话内连续两次点击仍必须正常触发快速移动。"
	)
	_expect(
		warehouse.transfer_storage_stack_to_player(0, run_state),
		"面板点击会话回归测试结束后必须恢复测试物资。"
	)


func _simulate_double_click(slot: InventorySlot) -> void:
	for _click_index in 2:
		_send_mouse_click(slot, Vector2(24.0, 24.0))


func _send_mouse_click(slot: InventorySlot, position: Vector2) -> void:
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = position
	slot.call("_on_gui_input", press)
	var release := InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_LEFT
	release.pressed = false
	release.position = position
	slot.call("_on_gui_input", release)
	slot.call("_on_pressed")


func _send_viewport_double_click(slot: InventorySlot) -> void:
	var position := slot.get_global_rect().get_center()
	await _send_viewport_mouse_click(position, false)
	await _send_viewport_mouse_click(position, true)
	for _frame in 2:
		await process_frame


func _send_viewport_mouse_click(position: Vector2, double_click: bool) -> void:
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.button_mask = MOUSE_BUTTON_MASK_LEFT
	press.pressed = true
	press.double_click = double_click
	press.position = position
	press.global_position = position
	root.push_input(press, true)
	await process_frame

	var release := InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_LEFT
	release.pressed = false
	release.position = position
	release.global_position = position
	root.push_input(release, true)
	await process_frame


func _test_drag_and_controller_slot_moves(
	run_state: RunStateStore,
	warehouse: OakWarehouse
) -> void:
	var panel := warehouse.storage_panel
	_expect(run_state.try_add_item_count(WOOD, 3), "拖拽测试必须准备一叠木材。")
	panel.call("_refresh_all")
	panel.open()
	for _frame in range(2):
		await process_frame
	panel.storage_slots[0].grab_focus()
	var empty_slot_accept := InputEventJoypadButton.new()
	empty_slot_accept.device = 0
	empty_slot_accept.button_index = JOY_BUTTON_A
	empty_slot_accept.pressed = true
	panel._input(empty_slot_accept)
	panel.storage_slots[0]._on_gui_input(empty_slot_accept)
	panel.storage_slots[0]._on_pressed()
	_expect(
		panel.get_viewport().gui_get_focus_owner() == panel.storage_slots[0]
		and not panel.controller_accept_held,
		"手柄在空槽按A不得丢失GUI焦点或启动拖拽。"
	)

	var player_drag_data := panel.make_slot_drag_data(
		OakWarehousePanel.ItemSource.PLAYER,
		0
	)
	var unchanged_inventory := run_state.export_inventory_snapshot()
	var unchanged_storage := warehouse.export_storage_snapshot()
	_expect(
		not panel.can_drop_slot_data(
			player_drag_data,
			OakWarehousePanel.ItemSource.PLAYER,
			0
		),
		"拖回原槽必须被视为无效落点。"
	)
	panel.drop_slot_data(
		player_drag_data,
		OakWarehousePanel.ItemSource.PLAYER,
		0
	)
	_expect(
		run_state.export_inventory_snapshot() == unchanged_inventory
		and warehouse.export_storage_snapshot() == unchanged_storage,
		"无效拖放必须让背包与仓库保持零写入。"
	)
	_expect(
		panel.can_drop_slot_data(
			player_drag_data,
			OakWarehousePanel.ItemSource.STORAGE,
			5
		),
		"鼠标拖拽必须能预检背包到指定仓库格。"
	)
	panel.drop_slot_data(
		player_drag_data,
		OakWarehousePanel.ItemSource.STORAGE,
		5
	)
	_expect(
		run_state.get_item(0) == null
		and warehouse.get_storage_item_count(5) == 3,
		"鼠标拖拽必须只在有效落点提交整叠移动。"
	)

	_expect(run_state.try_add_item(APPLE), "占位测试必须能加入苹果。")
	var blocked_drag_data := panel.make_slot_drag_data(
		OakWarehousePanel.ItemSource.STORAGE,
		5
	)
	unchanged_inventory = run_state.export_inventory_snapshot()
	unchanged_storage = warehouse.export_storage_snapshot()
	_expect(
		not panel.can_drop_slot_data(
			blocked_drag_data,
			OakWarehousePanel.ItemSource.PLAYER,
			0
		),
		"不同物品占用的目标格必须拒绝拖放。"
	)
	panel.drop_slot_data(
		blocked_drag_data,
		OakWarehousePanel.ItemSource.PLAYER,
		0
	)
	_expect(
		run_state.export_inventory_snapshot() == unchanged_inventory
		and warehouse.export_storage_snapshot() == unchanged_storage,
		"被占用目标格上的无效拖放必须完整零写入。"
	)
	_expect(run_state.discard_item(0), "占位苹果必须能在验证后清理。")
	var storage_drag_data := panel.make_slot_drag_data(
		OakWarehousePanel.ItemSource.STORAGE,
		5
	)
	panel.drop_slot_data(
		storage_drag_data,
		OakWarehousePanel.ItemSource.PLAYER,
		7
	)
	_expect(
		warehouse.get_storage_item(5) == null
		and run_state.get_item_count(7) == 3,
		"鼠标拖拽必须能把仓库整叠放到指定背包格。"
	)

	panel.player_slots[7].grab_focus()
	_expect(
		bool(panel.call("_begin_controller_accept_hold", 0)),
		"手柄按住A必须从当前聚焦物品建立拖拽候选。"
	)
	panel.call("_on_controller_hold_timeout")
	_expect(
		panel.controller_drag_active and panel.virtual_cursor.visible,
		"手柄A达到长按阈值后必须显示虚拟光标。"
	)
	var storage_target_center := panel.call(
		"_get_slot_center_in_panel",
		OakWarehousePanel.ItemSource.STORAGE,
		3
	) as Vector2
	var resolved_controller_target := panel.call(
		"_get_slot_at_panel_position",
		storage_target_center
	) as Dictionary
	_expect(
		int(resolved_controller_target.get("source", OakWarehousePanel.ItemSource.NONE))
		== OakWarehousePanel.ItemSource.STORAGE
		and int(resolved_controller_target.get("slot_index", -1)) == 3,
		"虚拟光标槽位坐标必须解析回仓库目标格。"
	)
	_expect(
		panel.can_drop_slot_data(
			panel.controller_drag_data,
			OakWarehousePanel.ItemSource.STORAGE,
			3
		),
		"手柄长按数据必须能通过目标格纯预检。"
	)
	panel.virtual_cursor.position = storage_target_center - panel.virtual_cursor.size * 0.5
	panel.call("_finish_controller_accept_hold")
	_expect(
		run_state.get_item(7) == null
		and warehouse.get_storage_item_count(3) == 3
		and not panel.virtual_cursor.visible,
		"手柄松开A到有效格时必须提交移动并隐藏虚拟光标。"
	)

	panel.storage_slots[3].grab_focus()
	_expect(
		bool(panel.call("_begin_controller_accept_hold", 0)),
		"手柄无效落点测试必须重新建立拖拽候选。"
	)
	panel.call("_on_controller_hold_timeout")
	unchanged_inventory = run_state.export_inventory_snapshot()
	unchanged_storage = warehouse.export_storage_snapshot()
	panel.virtual_cursor.position = Vector2(-100.0, -100.0)
	panel.call("_finish_controller_accept_hold")
	_expect(
		run_state.export_inventory_snapshot() == unchanged_inventory
		and warehouse.export_storage_snapshot() == unchanged_storage,
		"手柄松开A到非格子区域时必须让两端完整零写入。"
	)

	panel.storage_slots[3].grab_focus()
	_expect(
		bool(panel.call("_begin_controller_accept_hold", 0)),
		"手柄断连测试必须建立长按候选。"
	)
	panel.call("_on_joy_connection_changed", 0, false)
	_expect(
		not panel.controller_accept_held
		and not panel.controller_drag_active
		and not panel.virtual_cursor.visible,
		"手柄断连必须取消长按和虚拟光标状态。"
	)

	storage_drag_data = panel.make_slot_drag_data(
		OakWarehousePanel.ItemSource.STORAGE,
		3
	)
	panel.drop_slot_data(
		storage_drag_data,
		OakWarehousePanel.ItemSource.PLAYER,
		0
	)
	_expect(
		warehouse.get_storage_item(3) == null and run_state.get_item_count(0) == 3,
		"拖拽测试物资必须能完整取回。"
	)
	panel.status_label.text = "正在等待主机确认…"
	panel.set_multiplayer_storage_state(true, true, false)
	panel.multiplayer_slot_drop_pending = true
	panel.multiplayer_slot_drop_source = OakWarehousePanel.ItemSource.PLAYER
	panel.multiplayer_slot_drop_source_index = 0
	panel.multiplayer_slot_drop_target = OakWarehousePanel.ItemSource.STORAGE
	panel.multiplayer_slot_drop_target_index = 2
	panel.storage_slots[2].grab_focus()
	panel.show_multiplayer_command_result(
		false,
		OakWarehouseProtocol.RESULT_TARGET_FULL
	)
	await process_frame
	_expect(
		panel.get_viewport().gui_get_focus_owner() == panel.player_slots[0]
		and panel.status_label.text.is_empty(),
		"Host拒绝拖放时必须静默恢复来源格焦点。"
	)
	panel.set_multiplayer_storage_state(false, true, false)
	panel.close()
	_expect(run_state.discard_item(0), "拖拽测试物资必须能在验证后清理。")


func _test_authoritative_warehouse_candidate_filter(warehouse: OakWarehouse) -> void:
	var mp_game := MP_GAME_SCRIPT.new()
	_expect(
		bool(mp_game.call(
			"_is_authoritative_warehouse_interaction_candidate",
			warehouse
		)),
		"正常运作的仓库必须能参与Host最近交互目标选择。"
	)
	warehouse.is_operational = false
	_expect(
		not bool(mp_game.call(
			"_is_authoritative_warehouse_interaction_candidate",
			warehouse
		)),
		"尚未完成搭建的仓库不得遮挡Host对其他正常仓库的交互授权。"
	)
	warehouse.is_operational = true
	warehouse.is_removing = true
	_expect(
		not bool(mp_game.call(
			"_is_authoritative_warehouse_interaction_candidate",
			warehouse
		)),
		"正在拆除的仓库不得遮挡Host对其他正常仓库的交互授权。"
	)
	warehouse.is_removing = false
	mp_game.free()


func _test_authoritative_warehouse_sender_guard(
	run_state: RunStateStore,
	warehouse: OakWarehouse,
	peer_id: int,
	warehouse_net_id: int
) -> void:
	var mp_game := MP_GAME_SCRIPT.new()
	var net_manager_stub := HostNetManagerStub.new()
	var game_stub := GameTowerDefense.new()
	var plant_system_stub := AuthoritativePlantSystemStub.new()
	mp_game.net_manager = net_manager_stub
	mp_game.run_state = run_state
	mp_game.game = game_stub
	game_stub.plant_system = plant_system_stub
	game_stub.peer_players[peer_id] = warehouse.owner_player
	plant_system_stub.register_warehouse(warehouse_net_id, warehouse)
	var inventory_before := run_state.export_inventory_snapshot_for_peer(peer_id)
	var storage_before := warehouse.export_storage_snapshot()
	var legitimate_command := OakWarehouseProtocol.make_transfer_command(
		101,
		warehouse_net_id,
		peer_id,
		OakWarehouseProtocol.TransferDirection.PLAYER_TO_STORAGE,
		0,
		1,
		run_state.get_inventory_revision_for_peer(peer_id),
		warehouse.get_storage_revision()
	)
	var command_with_untrusted_extensions := legitimate_command.duplicate()
	command_with_untrusted_extensions["nested_junk"] = {
		"payload": [{"unexpected": "value"}],
	}
	var canonical_command := OakWarehouseProtocol.canonicalize_command(
		command_with_untrusted_extensions,
		peer_id
	)
	var legacy_transfer_command := legitimate_command.duplicate()
	legacy_transfer_command.erase("operation")
	var canonical_legacy_command := OakWarehouseProtocol.canonicalize_command(
		legacy_transfer_command,
		peer_id
	)
	_expect(
		canonical_command == legitimate_command
		and not canonical_command.has("nested_junk")
		and canonical_legacy_command == legitimate_command,
		"Host仓库命令解码必须只复制白名单字段，并保留省略transfer操作的兼容语义。"
	)
	var original_cached_result := OakWarehouseProtocol.make_result(
		legitimate_command,
		false,
		OakWarehouseProtocol.RESULT_STALE_INVENTORY,
		run_state.get_inventory_revision_for_peer(peer_id),
		warehouse.get_storage_revision()
	)
	original_cached_result["cache_sentinel"] = &"legitimate_result"
	mp_game.call(
		"_cache_warehouse_transaction_result",
		peer_id,
		warehouse_net_id,
		101,
		original_cached_result
	)
	var forged_command := OakWarehouseProtocol.make_transfer_command(
		101,
		warehouse_net_id,
		peer_id + 1,
		OakWarehouseProtocol.TransferDirection.PLAYER_TO_STORAGE,
		0,
		1,
		run_state.get_inventory_revision_for_peer(peer_id),
		warehouse.get_storage_revision()
	)
	mp_game.call("_apply_authoritative_warehouse_command", peer_id, forged_command)
	var cached_result := mp_game.call(
		"_get_cached_warehouse_transaction_result",
		peer_id,
		warehouse_net_id,
		101
	) as Dictionary
	_expect(
		cached_result == original_cached_result
		and run_state.export_inventory_snapshot_for_peer(peer_id) == inventory_before
		and warehouse.export_storage_snapshot() == storage_before,
		"Host必须拒绝伪造peer ID的仓库命令，且不得覆盖同请求号的合法幂等缓存。"
	)
	var player_position_before := warehouse.owner_player.global_position
	var warehouse_position_before := warehouse.global_position
	warehouse.owner_player.global_position = warehouse_position_before + Vector2(256.0, 0.0)
	_expect(
		not bool(mp_game.call(
			"_handle_authoritative_warehouse_snapshot_request",
			peer_id,
			warehouse_net_id
		)),
		"远离仓库的客户端不得主动索取仓库与背包权威快照。"
	)
	var snapshot_rate_buckets := mp_game.get(
		"_warehouse_snapshot_request_rate_buckets"
	) as Dictionary
	var snapshot_rate_bucket := snapshot_rate_buckets.get(peer_id, {}) as Dictionary
	_expect(
		not snapshot_rate_bucket.is_empty()
		and float(snapshot_rate_bucket.get("tokens", 4.0)) < 4.0,
		"无效的远距离仓库快照请求也必须消耗限流令牌。"
	)
	warehouse.owner_player.global_position = warehouse_position_before
	warehouse.is_operational = false
	_expect(
		not bool(mp_game.call(
			"_handle_authoritative_warehouse_snapshot_request",
			peer_id,
			warehouse_net_id
		)),
		"尚未完成搭建的仓库不得响应客户端快照请求。"
	)
	warehouse.is_operational = true
	warehouse.is_removing = true
	_expect(
		not bool(mp_game.call(
			"_handle_authoritative_warehouse_snapshot_request",
			peer_id,
			warehouse_net_id
		)),
		"正在拆除的仓库不得响应客户端快照请求。"
	)
	warehouse.is_removing = false
	_expect(
		not bool(mp_game.call(
			"_handle_authoritative_warehouse_snapshot_request",
			peer_id,
			warehouse_net_id
		))
		and net_manager_stub.peer_send_ready_checks == 1,
		"合法近距仓库快照请求必须通过交互授权并抵达发送就绪检查。"
	)
	warehouse.owner_player.global_position = player_position_before
	plant_system_stub.plants_by_net_id.clear()
	plant_system_stub.free()
	game_stub.free()
	net_manager_stub.free()
	mp_game.free()


func _test_authoritative_shared_storage(
	run_state: RunStateStore,
	warehouse: OakWarehouse
) -> void:
	const PEER_ID := 2
	const WAREHOUSE_NET_ID := 44
	_test_authoritative_warehouse_candidate_filter(warehouse)
	warehouse.storage_panel.open_for(warehouse, warehouse.owner_player)
	warehouse.configure_multiplayer_storage(WAREHOUSE_NET_ID, PEER_ID, true)
	_test_authoritative_warehouse_sender_guard(
		run_state,
		warehouse,
		PEER_ID,
		WAREHOUSE_NET_ID
	)
	var malformed_inventory_snapshot := run_state.export_inventory_snapshot_for_peer(PEER_ID)
	var malformed_storage_snapshot := warehouse.export_storage_snapshot()
	var malformed_command := OakWarehouseProtocol.make_transfer_command(
		99,
		WAREHOUSE_NET_ID,
		PEER_ID,
		OakWarehouseProtocol.TransferDirection.PLAYER_TO_STORAGE,
		0,
		1,
		run_state.get_inventory_revision_for_peer(PEER_ID),
		warehouse.get_storage_revision()
	)
	malformed_command["operation"] = []
	malformed_command["peer_id"] = {}
	_expect(
		not OakWarehouseProtocol.is_valid_command(malformed_command)
		and not OakWarehouseProtocol.command_peer_matches(
			malformed_command,
			PEER_ID
		),
		"多人仓库协议必须安全拒绝字段类型畸形的命令。"
	)
	var forged_peer_command := OakWarehouseProtocol.make_transfer_command(
		100,
		WAREHOUSE_NET_ID,
		PEER_ID + 1,
		OakWarehouseProtocol.TransferDirection.PLAYER_TO_STORAGE,
		0,
		1,
		run_state.get_inventory_revision_for_peer(PEER_ID),
		warehouse.get_storage_revision()
	)
	_expect(
		OakWarehouseProtocol.command_peer_matches(
			OakWarehouseProtocol.make_transfer_command(
				100,
				WAREHOUSE_NET_ID,
				PEER_ID,
				OakWarehouseProtocol.TransferDirection.PLAYER_TO_STORAGE,
				0,
				1,
				run_state.get_inventory_revision_for_peer(PEER_ID),
				warehouse.get_storage_revision()
			),
			PEER_ID
		)
		and not OakWarehouseProtocol.command_peer_matches(
			forged_peer_command,
			PEER_ID
		),
		"仓库权威入口必须只接受严格整数且与RPC发送者一致的peer ID。"
	)
	var malformed_result := warehouse.apply_transfer_command(malformed_command, run_state)
	_expect(
		not bool(malformed_result.get("success", false))
		and malformed_result.get("reason") == OakWarehouseProtocol.RESULT_INVALID_COMMAND
		and run_state.export_inventory_snapshot_for_peer(PEER_ID)
		== malformed_inventory_snapshot
		and warehouse.export_storage_snapshot() == malformed_storage_snapshot,
		"字段类型畸形的多人命令必须零写入并返回invalid_command。"
	)
	var invalid_amount_command := OakWarehouseProtocol.make_transfer_command(
		102,
		WAREHOUSE_NET_ID,
		PEER_ID,
		OakWarehouseProtocol.TransferDirection.PLAYER_TO_STORAGE,
		0,
		1,
		run_state.get_inventory_revision_for_peer(PEER_ID),
		warehouse.get_storage_revision()
	)
	invalid_amount_command["transfer_count"] = 0
	_expect(
		not OakWarehouseProtocol.is_valid_command(invalid_amount_command)
		and not bool(
			warehouse.apply_transfer_command(invalid_amount_command, run_state).get(
				"success",
				false
			)
		)
		and run_state.export_inventory_snapshot_for_peer(PEER_ID)
		== malformed_inventory_snapshot
		and warehouse.export_storage_snapshot() == malformed_storage_snapshot,
		"协议层必须拒绝非正整数转移数量，且Host两端零写入。"
	)
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
		17,
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

	var partial_inventory_revision := run_state.get_inventory_revision_for_peer(PEER_ID)
	var partial_storage_revision := warehouse.get_storage_revision()
	var partial_retrieve_command := OakWarehouseProtocol.make_transfer_command(
		2,
		WAREHOUSE_NET_ID,
		PEER_ID,
		OakWarehouseProtocol.TransferDirection.STORAGE_TO_PLAYER,
		0,
		9,
		partial_inventory_revision,
		partial_storage_revision
	)
	var partial_retrieve_result := warehouse.apply_transfer_command(
		partial_retrieve_command,
		run_state
	)
	_expect(
		bool(partial_retrieve_result.get("success", false))
		and run_state.get_item_count_for_peer(PEER_ID, 0) == 9
		and warehouse.get_storage_item_count(0) == 8
		and run_state.get_inventory_revision_for_peer(PEER_ID)
		== partial_inventory_revision + 1
		and warehouse.get_storage_revision() == partial_storage_revision + 1,
		"Host必须原子取回指定的9个物资，并在共享仓库保留8个。"
	)

	var overage_inventory_snapshot := run_state.export_inventory_snapshot_for_peer(PEER_ID)
	var overage_storage_snapshot := warehouse.export_storage_snapshot()
	var overage_command := OakWarehouseProtocol.make_transfer_command(
		3,
		WAREHOUSE_NET_ID,
		PEER_ID,
		OakWarehouseProtocol.TransferDirection.STORAGE_TO_PLAYER,
		0,
		9,
		run_state.get_inventory_revision_for_peer(PEER_ID),
		warehouse.get_storage_revision()
	)
	var overage_result := warehouse.apply_transfer_command(overage_command, run_state)
	_expect(
		not bool(overage_result.get("success", false))
		and overage_result.get("reason") == OakWarehouseProtocol.RESULT_INVALID_AMOUNT
		and run_state.export_inventory_snapshot_for_peer(PEER_ID)
		== overage_inventory_snapshot
		and warehouse.export_storage_snapshot() == overage_storage_snapshot,
		"请求数量超过来源实际8个时，Host必须返回invalid_amount且两端零写入。"
	)

	var retrieve_command := OakWarehouseProtocol.make_transfer_command(
		4,
		WAREHOUSE_NET_ID,
		PEER_ID,
		OakWarehouseProtocol.TransferDirection.STORAGE_TO_PLAYER,
		0,
		8,
		run_state.get_inventory_revision_for_peer(PEER_ID),
		warehouse.get_storage_revision()
	)
	var retrieve_result := warehouse.apply_transfer_command(retrieve_command, run_state)
	_expect(
		bool(retrieve_result.get("success", false))
		and run_state.get_item_count_for_peer(PEER_ID, 0) == 17
		and warehouse.get_storage_item(0) == null,
		"取回剩余8个物资后必须完整恢复17个背包堆叠并清空来源槽。"
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
		"仓库份数测试必须先把Peer收藏品填到效果生效份数上限。"
	)
	_expect(
		warehouse.try_add_storage_item_count(APPLE, 1, warehouse.get_storage_revision()),
		"共享仓库允许独立保存超出玩家当前生效上限的收藏品。"
	)
	var sixth_apple_storage_revision := warehouse.get_storage_revision()
	var sixth_apple_inventory_revision := run_state.get_inventory_revision_for_peer(PEER_ID)
	var sixth_apple_retrieve_command := OakWarehouseProtocol.make_transfer_command(
		5,
		WAREHOUSE_NET_ID,
		PEER_ID,
		OakWarehouseProtocol.TransferDirection.STORAGE_TO_PLAYER,
		0,
		1,
		sixth_apple_inventory_revision,
		sixth_apple_storage_revision
	)
	var sixth_apple_retrieve_result := warehouse.apply_transfer_command(
		sixth_apple_retrieve_command,
		run_state
	)
	_expect(
		bool(sixth_apple_retrieve_result.get("success", false))
		and sixth_apple_retrieve_result.get("reason") == OakWarehouseProtocol.RESULT_SUCCESS,
		"Host必须允许从共享仓库取回效果已封顶的第6个苹果。"
	)
	_expect(
		_count_peer_item_copies(run_state, PEER_ID, APPLE) == 6
		and warehouse.get_storage_item(0) == null
		and warehouse.get_storage_revision() == sixth_apple_storage_revision + 1
		and run_state.get_inventory_revision_for_peer(PEER_ID)
		== sixth_apple_inventory_revision + 1,
		"第6个苹果必须真实写入Peer背包，且取回事务双方revision各只递增一次。"
	)

	_test_authoritative_slot_moves(run_state, warehouse, PEER_ID, WAREHOUSE_NET_ID)
	_test_multiplayer_result_correlation(run_state, warehouse)
	_test_synchronous_host_panel_result(run_state, warehouse, PEER_ID)

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
		and requested_snapshot_ids == [WAREHOUSE_NET_ID]
		and not warehouse.multiplayer_storage_request_timer.is_stopped(),
		"请求仓库快照时必须进入只读加载态并携带正确net id。"
	)
	warehouse.call("_on_multiplayer_storage_request_timeout")
	_expect(
		requested_snapshot_ids == [WAREHOUSE_NET_ID, WAREHOUSE_NET_ID]
		and not warehouse.multiplayer_storage_request_timer.is_stopped(),
		"共享仓库快照未到达时必须保持只读并定时重试。"
	)
	warehouse.storage_snapshot_requested.disconnect(snapshot_request_callback)
	_expect(
		warehouse.apply_storage_snapshot(warehouse.export_storage_snapshot())
		and warehouse.multiplayer_storage_request_timer.is_stopped(),
		"收到权威仓库快照后必须恢复可交互状态。"
	)
	warehouse.storage_panel.call("_refresh_all")
	warehouse.storage_panel.player_slots[1].call("_on_pressed")
	_expect(
		warehouse.storage_panel.discard_button.disabled,
		"多人仓库界面必须禁止直接删除共享或个人物品。"
	)
	for slot_index in range(RunStateStore.INVENTORY_CAPACITY):
		if run_state.get_item_for_peer(PEER_ID, slot_index) != null:
			run_state.discard_item_for_peer(PEER_ID, slot_index)
	_test_unconfigured_multiplayer_storage_is_read_only(run_state, warehouse, PEER_ID)
	warehouse.storage_panel.close()


func _test_multiplayer_result_correlation(
	run_state: RunStateStore,
	warehouse: OakWarehouse
) -> void:
	var requested_commands: Array[Dictionary] = []
	var command_callback := func(command: Dictionary) -> void:
		requested_commands.append(command)
	warehouse.storage_command_requested.connect(command_callback)
	_expect(
		warehouse.request_multiplayer_stack_transfer(
			OakWarehouseProtocol.TransferDirection.PLAYER_TO_STORAGE,
			1
		),
		"多人结果关联测试必须发出一个权威请求。"
	)
	warehouse.storage_command_requested.disconnect(command_callback)
	_expect(requested_commands.size() == 1, "多人结果关联测试必须捕获唯一请求。")
	if requested_commands.is_empty():
		return
	var command := requested_commands[0]
	var pending_request_id := warehouse.multiplayer_storage_pending_request_id
	var pending_timer_time_left := warehouse.multiplayer_storage_request_timer.time_left
	warehouse.configure_multiplayer_storage(
		int(command["warehouse_net_id"]),
		int(command["peer_id"]),
		true
	)
	warehouse.configure_multiplayer_storage(
		int(command["warehouse_net_id"]),
		int(command["peer_id"]),
		false
	)
	_expect(
		warehouse.multiplayer_storage_request_pending
		and warehouse.multiplayer_storage_pending_request_id == pending_request_id
		and warehouse.multiplayer_storage_snapshot_ready
		and not warehouse.multiplayer_storage_request_timer.is_stopped()
		and warehouse.multiplayer_storage_request_timer.time_left > 0.0
		and warehouse.multiplayer_storage_request_timer.time_left
		<= pending_timer_time_left,
		"实时spawn与完整roster重复配置同一仓库时必须保留pending事务、ready状态和计时器。"
	)
	var result := warehouse.apply_transfer_command(command, run_state)
	_expect(
		warehouse.is_current_multiplayer_storage_result(result),
		"只有当前pending request的Host结果才能进入客户端提交路径。"
	)
	var unrelated_result := result.duplicate(true)
	unrelated_result["request_id"] = int(result["request_id"]) + 1
	_expect(
		not warehouse.is_current_multiplayer_storage_result(unrelated_result),
		"迟到或乱序的多人结果必须在应用快照前被拒绝。"
	)
	var inventory_snapshot := result.get("inventory_snapshot", {}) as Dictionary
	var storage_snapshot := result.get("storage_snapshot", {}) as Dictionary
	_expect(
		run_state.apply_inventory_snapshot_for_peer(
			warehouse.multiplayer_storage_peer_id,
			inventory_snapshot
		),
		"当前多人结果必须能先应用单调revision的背包快照。"
	)
	_expect(
		warehouse.complete_multiplayer_storage_request(result),
		"当前多人结果必须能完成pending request。"
	)
	_expect(
		warehouse.apply_storage_snapshot(storage_snapshot)
		and not warehouse.multiplayer_storage_request_pending,
		"完成结果后应用仓库快照不得重新清除或错配请求状态。"
	)


func _test_synchronous_host_panel_result(
	run_state: RunStateStore,
	warehouse: OakWarehouse,
	peer_id: int
) -> void:
	for slot_index in range(RunStateStore.INVENTORY_CAPACITY):
		if run_state.get_item_for_peer(peer_id, slot_index) != null:
			run_state.discard_item_for_peer(peer_id, slot_index)
		if warehouse.get_storage_item(slot_index) != null:
			warehouse.discard_storage_item(slot_index)
	run_state.set_active_multiplayer_peer(peer_id)
	_expect(
		run_state.try_add_item_count_for_peer(peer_id, WOOD, 4),
		"同步Host结果测试必须准备4份可拆分木头。"
	)
	var panel := warehouse.storage_panel
	panel.call("_refresh_all")
	var command_callback := func(command: Dictionary) -> void:
		var result := warehouse.apply_transfer_command(command, run_state)
		var inventory_snapshot := result.get("inventory_snapshot", {}) as Dictionary
		if not inventory_snapshot.is_empty():
			run_state.apply_inventory_snapshot_for_peer(peer_id, inventory_snapshot)
		warehouse.complete_multiplayer_storage_request(result)
		var storage_snapshot := result.get("storage_snapshot", {}) as Dictionary
		if not storage_snapshot.is_empty():
			warehouse.apply_storage_snapshot(storage_snapshot)
	warehouse.storage_command_requested.connect(command_callback)

	panel.player_slots[0].call("_on_pressed")
	panel.half_button.pressed.emit()
	_expect(
		run_state.get_item_count_for_peer(peer_id, 0) == 2
		and warehouse.get_storage_item_count(0) == 2
		and not warehouse.multiplayer_storage_request_pending
		and panel.status_label.text == "物品已移动",
		"Host同步完成取一半后，成功提示不得被覆盖成等待确认。"
	)

	panel.player_slots[0].call("_on_pressed")
	panel.move_button.pressed.emit()
	_expect(
		run_state.get_item_for_peer(peer_id, 0) == null
		and warehouse.get_storage_item_count(0) == 4
		and not warehouse.multiplayer_storage_request_pending
		and panel.status_label.text == "物品已移动",
		"Host同步完成整叠移动后，成功提示不得被覆盖成等待确认。"
	)
	warehouse.storage_command_requested.disconnect(command_callback)
	for slot_index in range(OakWarehouse.STORAGE_CAPACITY):
		if warehouse.get_storage_item(slot_index) != null:
			warehouse.discard_storage_item(slot_index)
	run_state.set_active_multiplayer_peer(0)
	panel.call("_refresh_all")


func _test_authoritative_slot_moves(
	run_state: RunStateStore,
	warehouse: OakWarehouse,
	peer_id: int,
	warehouse_net_id: int
) -> void:
	var inventory_revision := run_state.get_inventory_revision_for_peer(peer_id)
	var storage_revision := warehouse.get_storage_revision()
	var player_move_command := OakWarehouseProtocol.make_slot_move_command(
		4,
		warehouse_net_id,
		peer_id,
		OakWarehouseProtocol.ItemContainer.PLAYER,
		0,
		OakWarehouseProtocol.ItemContainer.PLAYER,
		10,
		inventory_revision,
		storage_revision
	)
	_expect(
		player_move_command.get("operation") == OakWarehouseProtocol.OPERATION_SLOT_MOVE
		and OakWarehouseProtocol.is_valid_slot_move_command(player_move_command)
		and OakWarehouseProtocol.is_valid_command(player_move_command),
		"slot_move协议必须编码容器、精确槽位与双方revision，并通过统一命令校验。"
	)
	var player_move_result := warehouse.apply_transfer_command(
		player_move_command,
		run_state
	)
	_expect(
		bool(player_move_result.get("success", false))
		and run_state.get_item_for_peer(peer_id, 0) == null
		and run_state.get_item_for_peer(peer_id, 10) == WOOD
		and run_state.get_item_count_for_peer(peer_id, 10) == 17,
		"Host必须按slot_move协议把Peer背包整叠物资移动到指定背包槽。"
	)
	_expect(
		run_state.get_inventory_revision_for_peer(peer_id) == inventory_revision + 1
		and warehouse.get_storage_revision() == storage_revision,
		"背包内精确槽移动只能写入一次个人背包revision。"
	)

	inventory_revision = run_state.get_inventory_revision_for_peer(peer_id)
	storage_revision = warehouse.get_storage_revision()
	var store_exact_command := OakWarehouseProtocol.make_slot_move_command(
		5,
		warehouse_net_id,
		peer_id,
		OakWarehouseProtocol.ItemContainer.PLAYER,
		10,
		OakWarehouseProtocol.ItemContainer.STORAGE,
		12,
		inventory_revision,
		storage_revision
	)
	var store_exact_result := warehouse.apply_transfer_command(store_exact_command, run_state)
	_expect(
		bool(store_exact_result.get("success", false))
		and run_state.get_item_for_peer(peer_id, 10) == null
		and warehouse.get_storage_item(12) == WOOD
		and warehouse.get_storage_item_count(12) == 17,
		"Host必须把Peer物资原子存入请求指定的仓库槽。"
	)
	_expect(
		run_state.get_inventory_revision_for_peer(peer_id) == inventory_revision + 1
		and warehouse.get_storage_revision() == storage_revision + 1,
		"背包到仓库的精确槽事务必须让双方revision各递增一次。"
	)

	inventory_revision = run_state.get_inventory_revision_for_peer(peer_id)
	storage_revision = warehouse.get_storage_revision()
	var storage_move_command := OakWarehouseProtocol.make_slot_move_command(
		6,
		warehouse_net_id,
		peer_id,
		OakWarehouseProtocol.ItemContainer.STORAGE,
		12,
		OakWarehouseProtocol.ItemContainer.STORAGE,
		14,
		inventory_revision,
		storage_revision
	)
	var storage_move_result := warehouse.apply_transfer_command(
		storage_move_command,
		run_state
	)
	_expect(
		bool(storage_move_result.get("success", false))
		and warehouse.get_storage_item(12) == null
		and warehouse.get_storage_item(14) == WOOD
		and warehouse.get_storage_item_count(14) == 17,
		"Host必须按精确槽位完成共享仓库内部移动。"
	)
	_expect(
		run_state.get_inventory_revision_for_peer(peer_id) == inventory_revision
		and warehouse.get_storage_revision() == storage_revision + 1,
		"仓库内精确槽移动只能写入一次共享仓库revision。"
	)

	var invalid_inventory_snapshot := run_state.export_inventory_snapshot_for_peer(peer_id)
	var invalid_storage_snapshot := warehouse.export_storage_snapshot()
	_expect(
		not warehouse.can_move_stack_to_slot(
			OakWarehouseProtocol.ItemContainer.STORAGE,
			14,
			-1,
			11,
			run_state,
			run_state.get_inventory_revision_for_peer(peer_id),
			warehouse.get_storage_revision(),
			peer_id
		)
		and not warehouse.move_stack_to_slot(
			OakWarehouseProtocol.ItemContainer.STORAGE,
			14,
			-1,
			11,
			run_state,
			run_state.get_inventory_revision_for_peer(peer_id),
			warehouse.get_storage_revision(),
			peer_id
		),
		"非法容器编号必须在任何读写前被拒绝。"
	)
	_expect(
		run_state.export_inventory_snapshot_for_peer(peer_id) == invalid_inventory_snapshot
		and warehouse.export_storage_snapshot() == invalid_storage_snapshot,
		"非法容器编号失败时，个人背包与共享仓库都必须零写入。"
	)
	var invalid_target_command := OakWarehouseProtocol.make_slot_move_command(
		7,
		warehouse_net_id,
		peer_id,
		OakWarehouseProtocol.ItemContainer.STORAGE,
		14,
		OakWarehouseProtocol.ItemContainer.PLAYER,
		1,
		run_state.get_inventory_revision_for_peer(peer_id),
		warehouse.get_storage_revision()
	)
	var invalid_target_result := warehouse.apply_transfer_command(
		invalid_target_command,
		run_state
	)
	_expect(
		not bool(invalid_target_result.get("success", false))
		and invalid_target_result.get("reason") == OakWarehouseProtocol.RESULT_TARGET_FULL,
		"Host必须拒绝把木材精确移动到已被苹果占用的Peer槽位。"
	)
	_expect(
		run_state.export_inventory_snapshot_for_peer(peer_id) == invalid_inventory_snapshot
		and warehouse.export_storage_snapshot() == invalid_storage_snapshot,
		"无效目标槽失败时，个人背包与共享仓库都必须零写入。"
	)

	var stale_inventory_snapshot := run_state.export_inventory_snapshot_for_peer(peer_id)
	var stale_storage_snapshot := warehouse.export_storage_snapshot()
	var stale_move_command := OakWarehouseProtocol.make_slot_move_command(
		8,
		warehouse_net_id,
		peer_id,
		OakWarehouseProtocol.ItemContainer.STORAGE,
		14,
		OakWarehouseProtocol.ItemContainer.PLAYER,
		11,
		run_state.get_inventory_revision_for_peer(peer_id) - 1,
		warehouse.get_storage_revision()
	)
	var stale_move_result := warehouse.apply_transfer_command(stale_move_command, run_state)
	_expect(
		not bool(stale_move_result.get("success", false))
		and stale_move_result.get("reason") == OakWarehouseProtocol.RESULT_STALE_INVENTORY,
		"Host必须按权威revision拒绝过期的多人slot_move命令。"
	)
	_expect(
		run_state.export_inventory_snapshot_for_peer(peer_id) == stale_inventory_snapshot
		and warehouse.export_storage_snapshot() == stale_storage_snapshot,
		"stale inventory revision失败时，个人背包与共享仓库都必须零写入。"
	)

	stale_inventory_snapshot = run_state.export_inventory_snapshot_for_peer(peer_id)
	stale_storage_snapshot = warehouse.export_storage_snapshot()
	var stale_storage_move_command := OakWarehouseProtocol.make_slot_move_command(
		9,
		warehouse_net_id,
		peer_id,
		OakWarehouseProtocol.ItemContainer.STORAGE,
		14,
		OakWarehouseProtocol.ItemContainer.PLAYER,
		11,
		run_state.get_inventory_revision_for_peer(peer_id),
		warehouse.get_storage_revision() - 1
	)
	var stale_storage_move_result := warehouse.apply_transfer_command(
		stale_storage_move_command,
		run_state
	)
	_expect(
		not bool(stale_storage_move_result.get("success", false))
		and stale_storage_move_result.get("reason") == OakWarehouseProtocol.RESULT_STALE_STORAGE,
		"Host必须按权威revision拒绝过期仓库状态的多人slot_move命令。"
	)
	_expect(
		run_state.export_inventory_snapshot_for_peer(peer_id) == stale_inventory_snapshot
		and warehouse.export_storage_snapshot() == stale_storage_snapshot,
		"stale storage revision失败时，个人背包与共享仓库都必须零写入。"
	)

	inventory_revision = run_state.get_inventory_revision_for_peer(peer_id)
	storage_revision = warehouse.get_storage_revision()
	var retrieve_exact_command := OakWarehouseProtocol.make_slot_move_command(
		10,
		warehouse_net_id,
		peer_id,
		OakWarehouseProtocol.ItemContainer.STORAGE,
		14,
		OakWarehouseProtocol.ItemContainer.PLAYER,
		11,
		inventory_revision,
		storage_revision
	)
	var retrieve_exact_result := warehouse.apply_transfer_command(
		retrieve_exact_command,
		run_state
	)
	_expect(
		bool(retrieve_exact_result.get("success", false))
		and warehouse.get_storage_item(14) == null
		and run_state.get_item_for_peer(peer_id, 11) == WOOD
		and run_state.get_item_count_for_peer(peer_id, 11) == 17,
		"Host必须把共享物资原子取回请求指定的Peer背包槽。"
	)
	_expect(
		run_state.get_inventory_revision_for_peer(peer_id) == inventory_revision + 1
		and warehouse.get_storage_revision() == storage_revision + 1,
		"仓库到背包的精确槽事务必须让双方revision各递增一次。"
	)
	_expect(
		run_state.discard_item_for_peer(peer_id, 11),
		"精确槽位测试的木材必须能在验证后清理。"
	)


func _test_unconfigured_multiplayer_storage_is_read_only(
	run_state: RunStateStore,
	warehouse: OakWarehouse,
	peer_id: int
) -> void:
	warehouse.configure_multiplayer_storage(0, 0, true)
	run_state.set_active_multiplayer_peer(peer_id)
	_expect(
		run_state.try_add_item_count_for_peer(peer_id, WOOD, 3),
		"未配置共享仓库的只读测试必须准备Peer物资。"
	)
	var local_inventory_snapshot := run_state.export_inventory_snapshot()
	var peer_inventory_snapshot := run_state.export_inventory_snapshot_for_peer(peer_id)
	var storage_snapshot := warehouse.export_storage_snapshot()
	warehouse.storage_panel.call("_refresh_all")
	warehouse.storage_panel.player_slots[0].call("_on_pressed")
	warehouse.storage_panel.call("_on_move_pressed")
	_expect(
		run_state.export_inventory_snapshot() == local_inventory_snapshot
		and run_state.export_inventory_snapshot_for_peer(peer_id) == peer_inventory_snapshot
		and warehouse.export_storage_snapshot() == storage_snapshot,
		"多人仓库尚未获得网络配置时，快速移动必须保持两端零写入。"
	)
	_expect(
		warehouse.storage_panel.status_label.text == "正在同步共享仓库…",
		"多人仓库尚未配置时必须保持只读同步状态。"
	)
	run_state.discard_item_for_peer(peer_id, 0)
	run_state.set_active_multiplayer_peer(0)


func _count_peer_item_copies(
	run_state: RunStateStore,
	peer_id: int,
	item: PickupConfig
) -> int:
	var copy_count := 0
	for slot_index in range(RunStateStore.INVENTORY_CAPACITY):
		var stored_item := run_state.get_item_for_peer(peer_id, slot_index)
		if stored_item == null or stored_item.resource_path != item.resource_path:
			continue
		copy_count += run_state.get_item_count_for_peer(peer_id, slot_index)
	return copy_count


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


func _get_centered_sprite_subject_rect(
	sprite: Sprite2D,
	opaque_bounds: Rect2i,
	texture_size: Vector2
) -> Rect2:
	var source_origin := Vector2(opaque_bounds.position)
	if sprite.centered:
		source_origin -= texture_size * 0.5
	source_origin += sprite.offset
	return Rect2(
		sprite.position + source_origin * sprite.scale,
		Vector2(opaque_bounds.size) * sprite.scale.abs()
	)


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
