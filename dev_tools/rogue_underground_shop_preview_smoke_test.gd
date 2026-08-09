extends SceneTree

const PREVIEW_SCENE := preload(
	"res://dev_tools/visual_prototypes/underground_shop/underground_shop_preview.tscn"
)
const VIEWPORT_SIZE := Vector2i(1152, 648)
const HEALTH_CONFIG := preload("res://resources/config/consumables/healing_potion.tres")

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	root.content_scale_size = VIEWPORT_SIZE
	root.size = VIEWPORT_SIZE
	_audit_source_boundaries()
	var run_state := root.get_node("RunState") as RunStateStore
	run_state.begin_new_run(&"weishidaier", false)

	var preview := PREVIEW_SCENE.instantiate() as Control
	_expect(preview != null, "正式地下商店拼装预览必须能够实例化。")
	if preview == null:
		call_deferred("_finish")
		return
	root.add_child(preview)
	current_scene = preview
	for _frame in range(5):
		await process_frame

	var view := preview.get_node_or_null("ShopView") as RogueUndergroundShopView
	_expect(view != null, "dev 预览必须直接实例化正式 RogueUndergroundShopView。")
	if view != null:
		_audit_authored_scene(view)
		_audit_buy_interaction(view)
		_audit_sell_interaction(view, run_state)
		await _audit_responsive_layout(view)
		_audit_exit_boundary(view)

	current_scene = null
	root.remove_child(preview)
	preview.free()
	await process_frame
	call_deferred("_finish")


func _audit_source_boundaries() -> void:
	var view_scene_source := FileAccess.get_file_as_string(
		"res://scene/game_modes/rogue/shop/ui/rogue_underground_shop_view.tscn"
	)
	var view_script_source := FileAccess.get_file_as_string(
		"res://scene/game_modes/rogue/shop/ui/rogue_underground_shop_view.gd"
	)
	_expect(
		view_scene_source.count("instance=ExtResource(\"10_item_card\")") == 8,
		"正式场景必须 authored 8 张且仅 8 张商品卡。"
	)
	for forbidden in [".new()", ".instantiate()", "RogueRouteTopBar", "rogue_route_top_bar.tscn"]:
		_expect(
			not view_script_source.contains(forbidden)
			and not view_scene_source.contains(forbidden),
			"正式商店不得动态创建节点或复制顶部 HUD：%s" % forbidden
		)
	_expect(
		not FileAccess.file_exists(
			"res://dev_tools/visual_prototypes/underground_shop/underground_shop_product_card_preview.tscn"
		),
		"旧 10 格商品卡原型必须退役，避免与正式布局漂移。"
	)


func _audit_authored_scene(view: RogueUndergroundShopView) -> void:
	_expect(view.layer == 10, "正式商店背景与交互应位于可复用顶部 HUD 的下层。")
	_expect(view.get_item_cards().size() == 8, "正式购买/出售必须共用 4×2 的 8 张卡。")
	_expect(
		view.get_node_or_null("Root/TopBar") == null,
		"正式商店不得复制路线顶部 HUD。"
	)
	var backdrop := view.get_node("Root/SceneBackdrop") as TextureRect
	_expect(
		backdrop.texture.resource_path.ends_with("underground_ruins_background.png"),
		"正式商店必须直接复用地下遗迹背景。"
	)
	var xiaocong := view.get_node("Root/XiaocongStage/Xiaocong") as TextureRect
	var atlas := xiaocong.texture as AtlasTexture
	_expect(
		xiaocong.size == Vector2(366, 477)
		and atlas != null
		and atlas.region == Rect2(0, 0, 1098, 1431)
		and atlas.atlas.resource_path.ends_with("xiaocong_keypose_hd.png"),
		"小葱必须用 1098×1431→366×477 的精确 1/3 nearest 采样。"
	)
	var grid := view.get_node("Root/ShopPanel/ItemGrid") as GridContainer
	_expect(
		grid.columns == 4 and grid.get_child_count() == 8,
		"商品网格必须是 authored 4×2。"
	)
	for card_index in range(view.get_item_cards().size()):
		var card := view.get_item_cards()[card_index]
		_expect(card.size == Vector2(128, 128), "商品卡必须保持 128×128 像素尺寸。")
		var quick_use_badge := card.get_node("QuickUseBadge") as TextureRect
		_expect(
			quick_use_badge.size == Vector2(10, 10)
			and quick_use_badge.texture_filter == CanvasItem.TEXTURE_FILTER_NEAREST
			and quick_use_badge.texture.get_size() == Vector2(10, 10),
			"出售卡必须 authored 原生10×10快捷使用徽记。"
		)
		_expect(
			(card.get_node("XirangIcon") as TextureRect).texture.resource_path.ends_with(
				"xirang_icon.png"
			),
			"交易卡价格必须使用个人息壤图标，而不是光石。"
		)
	var consumable_prices: Dictionary = {}
	for card in view.get_item_cards():
		var payload := card.get_payload()
		if str(payload.get("kind", "")) == "consumable":
			consumable_prices[str(payload.get("config_path", ""))] = int(
				payload.get("price", 0)
			)
	_expect(
		consumable_prices == {
			"res://resources/config/consumables/healing_potion.tres": 50,
			"res://resources/config/consumables/large_healing_potion.tres": 200,
			"res://resources/config/consumables/rock_potion.tres": 70,
			"res://resources/config/consumables/large_rock_potion.tres": 280,
		},
		"正式 UI 预览必须展示四种 consumable 及其 typed listing 买价。"
	)


func _audit_buy_interaction(view: RogueUndergroundShopView) -> void:
	var cards := view.get_item_cards()
	var detail := view.get_node("Root/DetailOverlay") as Control
	var action_button := view.get_node(
		"Root/DetailOverlay/DetailFrame/DetailActionButton"
	) as TextureButton
	var cancel_button := view.get_node(
		"Root/DetailOverlay/DetailFrame/DetailCancelButton"
	) as TextureButton
	for button in [action_button, cancel_button]:
		button.set_meta(&"skip_ui_click_audio", true)
	for card in cards:
		card.set_meta(&"skip_ui_click_audio", true)
	var requests: Array[int] = []
	view.purchase_requested.connect(
		func(offer_index: int) -> void:
			requests.append(offer_index)
	)
	_expect(view.get_active_tab() == 0, "商店打开后默认位于购买页。")
	_expect(not (cards[0].get_node("CountLabel") as Label).visible, "购买卡不得显示库存或持有数量。")
	_expect(
		not (cards[0].get_node("QuickUseBadge") as TextureRect).visible,
		"购买卡不得显示玩家快捷使用绑定。"
	)
	cards[6].pressed.emit()
	_expect(detail.visible, "点击购买卡必须打开 authored 详情模态。")
	_expect(detail.mouse_filter == Control.MOUSE_FILTER_STOP, "详情模态必须阻断底层鼠标。")
	for card in cards:
		_expect(card.focus_mode == Control.FOCUS_NONE, "详情打开时底层卡片必须退出焦点导航。")
	view.set_transaction_pending(true)
	var cancel_event := InputEventAction.new()
	cancel_event.action = &"ui_cancel"
	cancel_event.pressed = true
	view.call("_unhandled_input", cancel_event)
	_expect(detail.visible, "交易等待 Host 回包时，Esc 不得关闭详情或解除事务锁。")
	view.set_transaction_pending(false)
	action_button.pressed.emit()
	_expect(requests == [6], "购买确认必须只发出选中报价索引。")
	view.set_transaction_pending(false)
	cancel_button.pressed.emit()
	_expect(not detail.visible, "取消详情必须复用并隐藏 authored 模态。")
	for card in cards:
		_expect(card.focus_mode == Control.FOCUS_ALL, "关闭详情后必须恢复卡片焦点导航。")


func _audit_sell_interaction(
	view: RogueUndergroundShopView,
	run_state: RunStateStore
) -> void:
	_expect(
		run_state.try_add_item_count(HEALTH_CONFIG, 5)
		and run_state.set_quick_use_binding(0),
		"出售卡徽记测试必须准备已绑定的治疗血瓶。"
	)
	var slots: Array[Dictionary] = []
	for slot_index in range(20):
		slots.append({
			"slot_index": slot_index,
			"config_path": HEALTH_CONFIG.resource_path,
			"item": HEALTH_CONFIG,
			"stack_count": slot_index + 1,
			"sell_price": 50,
			"can_sell": slot_index != 17,
			"disabled_reason": "locked" if slot_index == 17 else "",
		})
	view.present_sell_inventory(slots)
	view.show_sell_tab()
	_expect(view.get_active_tab() == 1, "出售页签必须切换到出售模式。")
	var first_count := view.get_item_cards()[0].get_node("CountLabel") as Label
	_expect(
		first_count.visible and first_count.text == "×1",
		"可堆叠出售物品必须显示玩家实际持有数，即使当前仅1件。"
	)
	var second_count := view.get_item_cards()[1].get_node("CountLabel") as Label
	_expect(second_count.visible and second_count.text == "×2", "出售卡必须显示实际堆叠数。")
	var first_badge := view.get_item_cards()[0].get_node("QuickUseBadge") as TextureRect
	var second_badge := view.get_item_cards()[1].get_node("QuickUseBadge") as TextureRect
	_expect(
		first_badge.visible
		and not second_badge.visible
		and first_badge.position == Vector2(100, 66)
		and first_count.position == Vector2(84, 12),
		"SELL卡必须仅在绑定槽显示右下徽记，并保持数量位于右上。"
	)
	var next_button := view.get_node("Root/ShopPanel/PageControls/NextPageButton") as TextureButton
	next_button.set_meta(&"skip_ui_click_audio", true)
	next_button.pressed.emit()
	next_button.pressed.emit()
	_expect(view.get_sell_page() == 2, "20格背包必须提供第三页。")
	for card_index in range(4):
		_expect(
			int(view.get_item_cards()[card_index].get_payload().get("slot_index", -1)) == 16 + card_index,
			"第三页前4张卡必须保持原背包槽位顺序。"
		)
	for card_index in range(4, 8):
		_expect(
			view.get_item_cards()[card_index].get_payload().is_empty()
			and view.get_item_cards()[card_index].disabled,
			"第三页越过20格容量的后4张卡必须为空且不可交互。"
		)
	var locked_card := view.get_item_cards()[1]
	_expect(
		locked_card.disabled
		and locked_card.tooltip_text.contains("锁定物品不可出售"),
		"domain禁售原因必须映射为简洁中文，且卡片不可交互。"
	)
	var detail_before_locked_click := view.get_node("Root/DetailOverlay") as Control
	locked_card.pressed.emit()
	_expect(not detail_before_locked_click.visible, "空槽与禁售卡不得打开详情。")
	var sell_requests: Array[Dictionary] = []
	view.sell_requested.connect(
		func(slot_index: int, expected_path: String) -> void:
			sell_requests.append({"slot": slot_index, "path": expected_path})
	)
	view.get_item_cards()[0].pressed.emit()
	var action_button := view.get_node(
		"Root/DetailOverlay/DetailFrame/DetailActionButton"
	) as TextureButton
	action_button.pressed.emit()
	_expect(
		sell_requests.size() == 1
		and int(sell_requests[0].get("slot", -1)) == 16
		and str(sell_requests[0].get("path", "")) == HEALTH_CONFIG.resource_path,
		"出售确认必须携带原槽位与预期物品路径。"
	)
	view.set_transaction_pending(false)
	var remaining_page := _build_sell_page(16, 2)
	view.present_sell_inventory_page(remaining_page)
	var detail := view.get_node("Root/DetailOverlay") as Control
	var detail_quantity := view.get_node(
		"Root/DetailOverlay/DetailFrame/DetailQuantity"
	) as Label
	_expect(
		detail.visible and detail_quantity.text == "背包内 ×2",
		"出售后堆叠仍存在时详情必须原地更新实际数量。"
	)
	var empty_page := _build_sell_page(16, 0)
	view.present_sell_inventory_page(empty_page)
	_expect(not detail.visible, "出售最后1件后空槽详情必须立即关闭。")
	run_state.clear_quick_use_binding()


func _build_sell_page(selected_slot: int, selected_count: int) -> Dictionary:
	var page_slots: Array[Dictionary] = []
	for card_index in range(8):
		var slot_index := 16 + card_index
		if slot_index >= 20 or (slot_index == selected_slot and selected_count <= 0):
			page_slots.append({
				"slot_index": slot_index,
				"config_path": "",
				"stack_count": 0,
				"can_sell": false,
				"sell_price": 0,
				"disabled_reason": "empty",
			})
			continue
		page_slots.append({
			"slot_index": slot_index,
			"config_path": HEALTH_CONFIG.resource_path,
			"item": HEALTH_CONFIG,
			"stack_count": selected_count if slot_index == selected_slot else 1,
			"can_sell": true,
			"sell_price": 50,
			"disabled_reason": "",
		})
	return {"page_index": 2, "page_count": 3, "slots": page_slots}


func _audit_exit_boundary(view: RogueUndergroundShopView) -> void:
	var exit_events: Array[bool] = []
	view.exit_requested.connect(func() -> void: exit_events.append(true))
	var exit_button := view.get_node("Root/ShopPanel/ExitButton") as TextureButton
	exit_button.set_meta(&"skip_ui_click_audio", true)
	exit_button.pressed.emit()
	_expect(exit_events.size() == 1, "退出按钮必须只发出本地退出请求。")
	_expect(view.visible, "UI 不得在本地点击时自行隐藏，需等待 Route 完成菱形转场。")


func _audit_responsive_layout(view: RogueUndergroundShopView) -> void:
	var logical_sizes := [
		Vector2i(1280, 720),
		Vector2i(1920, 1080),
		Vector2i(960, 720),
		Vector2i(2560, 1080),
	]
	view.show_buy_tab()
	for logical_size in logical_sizes:
		root.content_scale_size = logical_size
		root.size = logical_size
		for _frame in range(2):
			await process_frame
		var viewport_rect := Rect2(Vector2.ZERO, Vector2(logical_size))
		var panel := view.get_node("Root/ShopPanel") as Control
		var xiaocong := view.get_node("Root/XiaocongStage/Xiaocong") as Control
		var grid := view.get_node("Root/ShopPanel/ItemGrid") as Control
		var exit_button := view.get_node("Root/ShopPanel/ExitButton") as Control
		for control in [panel, xiaocong, grid, exit_button]:
			_expect(
				viewport_rect.encloses(control.get_global_rect()),
				"%s 逻辑尺寸下 %s 不得被裁出视口。"
				% [logical_size, control.name]
			)
		_expect(
			not grid.get_global_rect().intersects(xiaocong.get_global_rect()),
			"%s 下小葱不得遮挡可交互商品网格。" % logical_size
		)
		_expect(
			not grid.get_global_rect().intersects(exit_button.get_global_rect()),
			"%s 下商品网格不得与退出按钮重叠。" % logical_size
		)
		for card in view.get_item_cards():
			_expect(
				card.size == Vector2(128, 128),
				"%s 下商品卡仍须保持 128×128 整数像素几何。" % logical_size
			)
		view.get_item_cards()[0].pressed.emit()
		var detail_frame := view.get_node("Root/DetailOverlay/DetailFrame") as Control
		_expect(
			viewport_rect.encloses(detail_frame.get_global_rect()),
			"%s 下详情模态不得被裁切。" % logical_size
		)
		view.close_detail()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("ROGUE_UNDERGROUND_SHOP_PREVIEW_SMOKE_TEST_OK cards=8 sell_pages=3")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)
