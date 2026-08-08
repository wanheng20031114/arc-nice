extends SceneTree

const PREVIEW_SCENE := preload(
	"res://dev_tools/visual_prototypes/underground_shop/underground_shop_preview.tscn"
)
const VIEWPORT_SIZE := Vector2i(1152, 648)
const EXPECTED_ASSET_SIZES := {
	"res://resources/texture/rogue_shop/ui/shop_panel_frame_v1.png": Vector2i(136, 136),
	"res://resources/texture/rogue_shop/ui/shop_title_plaque_v1.png": Vector2i(136, 32),
	"res://resources/texture/rogue_shop/ui/shop_button_normal_v1.png": Vector2i(104, 28),
	"res://resources/texture/rogue_shop/ui/shop_button_hover_v1.png": Vector2i(104, 28),
	"res://resources/texture/rogue_shop/ui/shop_button_pressed_v1.png": Vector2i(104, 28),
	"res://resources/texture/rogue_shop/ui/shop_button_disabled_v1.png": Vector2i(104, 28),
	"res://resources/texture/rogue_shop/ui/shop_product_card_normal_v2.png": Vector2i(128, 128),
	"res://resources/texture/rogue_shop/ui/shop_product_card_hover_v2.png": Vector2i(128, 128),
	"res://resources/texture/rogue_shop/ui/shop_product_card_pressed_v2.png": Vector2i(128, 128),
	"res://resources/texture/rogue_shop/ui/shop_product_card_disabled_v2.png": Vector2i(128, 128),
}
const GENERATED_ALPHA_ASSETS := [
	"res://resources/texture/rogue_shop/ui/shop_panel_frame_v1.png",
	"res://resources/texture/rogue_shop/ui/shop_title_plaque_v1.png",
	"res://resources/texture/rogue_shop/ui/shop_button_normal_v1.png",
	"res://resources/texture/rogue_shop/ui/shop_button_hover_v1.png",
	"res://resources/texture/rogue_shop/ui/shop_button_pressed_v1.png",
	"res://resources/texture/rogue_shop/ui/shop_button_disabled_v1.png",
	"res://resources/texture/rogue_shop/ui/shop_product_card_normal_v2.png",
	"res://resources/texture/rogue_shop/ui/shop_product_card_hover_v2.png",
	"res://resources/texture/rogue_shop/ui/shop_product_card_pressed_v2.png",
	"res://resources/texture/rogue_shop/ui/shop_product_card_disabled_v2.png",
]

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	root.content_scale_size = VIEWPORT_SIZE
	root.size = VIEWPORT_SIZE
	_audit_asset_contracts()
	_audit_preview_source_boundary()

	var preview := PREVIEW_SCENE.instantiate() as Control
	_expect(preview != null, "地下商店拼装原型必须能够独立实例化。")
	if preview == null:
		call_deferred("_finish")
		return
	root.add_child(preview)
	current_scene = preview
	for _frame in range(5):
		await process_frame

	_audit_authored_scene(preview)
	_audit_layout(preview)
	_audit_interaction(preview)

	current_scene = null
	root.remove_child(preview)
	preview.free()
	await process_frame
	# 让本帧中的纹理、Image 与信号闭包局部引用先离开调用栈，再退出
	# SceneTree。否则 Godot 会把仍在测试函数栈上的合法临时资源误报为退出泄漏。
	call_deferred("_finish")


func _audit_asset_contracts() -> void:
	for asset_path in EXPECTED_ASSET_SIZES:
		var texture := load(asset_path) as Texture2D
		_expect(texture != null, "必须能够导入地下商店素材：%s" % asset_path)
		if texture == null:
			continue
		_expect(
			texture.get_size() == Vector2(EXPECTED_ASSET_SIZES[asset_path]),
			"地下商店素材尺寸必须固定：%s 当前为 %s"
			% [asset_path, texture.get_size()]
		)
	for asset_path in GENERATED_ALPHA_ASSETS:
		var texture := load(asset_path) as Texture2D
		if texture == null:
			continue
		var image := texture.get_image()
		_expect(image != null and not image.is_empty(), "透明素材必须可读回：%s" % asset_path)
		if image == null or image.is_empty():
			continue
		_expect(image.detect_alpha() != Image.ALPHA_NONE, "素材必须保留透明通道：%s" % asset_path)
		_expect(image.get_used_rect().has_area(), "素材必须包含可见像素：%s" % asset_path)
		_audit_hard_alpha_and_green_fringe(image, asset_path)

	var button_hashes: Dictionary = {}
	for state_name in ["normal", "hover", "pressed", "disabled"]:
		var path := "res://resources/texture/rogue_shop/ui/shop_button_%s_v1.png" % state_name
		var bytes := FileAccess.get_file_as_bytes(path)
		button_hashes[bytes.hex_encode().hash()] = true
	_expect(button_hashes.size() == 4, "四种按钮状态必须使用四份不同的图像。")
	var product_card_hashes: Dictionary = {}
	for state_name in ["normal", "hover", "pressed", "disabled"]:
		var path := "res://resources/texture/rogue_shop/ui/shop_product_card_%s_v2.png" % state_name
		var bytes := FileAccess.get_file_as_bytes(path)
		product_card_hashes[bytes.hex_encode().hash()] = true
	_expect(product_card_hashes.size() == 4, "商品卡四态必须使用四份同几何独立图像。")


func _audit_hard_alpha_and_green_fringe(image: Image, asset_path: String) -> void:
	for y in range(image.get_height()):
		for x in range(image.get_width()):
			var pixel := image.get_pixel(x, y)
			_expect(
				pixel.a <= 0.001 or pixel.a >= 0.999,
				"透明边缘必须使用硬 Alpha：%s @ %s" % [asset_path, Vector2i(x, y)]
			)
			if pixel.a <= 0.001:
				continue
			_expect(
				not (
					pixel.g > 0.3
					and pixel.g > pixel.r + 0.10
					and pixel.g > pixel.b + 0.10
				),
				"色键去除后不得残留亮绿色边缘：%s @ %s" % [asset_path, Vector2i(x, y)]
			)


func _audit_preview_source_boundary() -> void:
	var combined_source := ""
	for source_path in [
		"res://dev_tools/visual_prototypes/underground_shop/underground_shop_preview.gd",
		"res://dev_tools/visual_prototypes/underground_shop/underground_shop_product_card_preview.gd",
	]:
		var source := FileAccess.get_file_as_string(source_path)
		combined_source += "\n" + source
		_expect(not source.is_empty(), "原型脚本必须可读取：%s" % source_path)
		for forbidden in ["RunState", "NetManager", "MultiplayerSynchronizer", ".instantiate()", ".new()"]:
			_expect(
				not source.contains(forbidden),
				"视觉原型不得接入正式状态或动态创建节点：%s 命中 %s"
				% [source_path, forbidden]
			)
	var preview_scene_source := FileAccess.get_file_as_string(
		"res://dev_tools/visual_prototypes/underground_shop/underground_shop_preview.tscn"
	)
	var card_scene_source := FileAccess.get_file_as_string(
		"res://dev_tools/visual_prototypes/underground_shop/underground_shop_product_card_preview.tscn"
	)
	combined_source += "\n" + preview_scene_source + "\n" + card_scene_source
	for forbidden in [
		"owned_count",
		"OwnedLabel",
		"DetailOwned",
		"StockLabel",
		"QuantitySelector",
		"PriceShade",
		"PriceDivider",
		"持有",
		"库存",
		"rogue_shop/environment",
		"rogue_shop/characters",
	]:
		_expect(
			not combined_source.contains(forbidden),
			"商品原型不得保留数量语义、浮贴售价或派生背景角色：%s" % forbidden
		)


func _audit_authored_scene(preview: Control) -> void:
	var top_bar := preview.get_node_or_null("TopBar") as RogueRouteTopBar
	_expect(top_bar != null, "拼装原型必须复用 RogueRouteTopBar，而不是复制顶部 HUD。")
	if top_bar != null:
		_expect(
			top_bar.floor_title.text == "浅层矿洞"
			and top_bar.core_value.text == "100/100"
			and top_bar.action_points_value.text == "12"
			and top_bar.light_stone_value.text == "128"
			and top_bar.xirang_value.text == "46",
			"复用顶部 HUD 必须展示拼装样例值。"
		)
	var grid := preview.get_node_or_null("ShopPanel/ProductGrid") as GridContainer
	_expect(grid != null and grid.columns == 5, "商品区域必须使用原生五列 GridContainer。")
	if grid == null:
		return
	_expect(grid.get_child_count() == 10, "商品区域必须静态拼装 10 张商品卡。")
	for card_node in grid.get_children():
		var card := card_node as TextureButton
		_expect(card != null, "商品网格子节点必须全部是可聚焦的 TextureButton。")
		if card == null:
			continue
		_expect(card.focus_mode == Control.FOCUS_ALL, "商品卡必须支持键盘/手柄聚焦。")
		var payload: Dictionary = card.call("get_offer_payload")
		var icon := payload.get("texture") as Texture2D
		_expect(icon != null and icon.get_size() == Vector2(32, 32), "真实商品图标必须以 32×32 原生素材进入卡片。")
		_expect(int(payload.get("price", -1)) >= 0, "每张商品卡必须在卡内提供光石价格。")
		_expect(not payload.has("owned_count"), "商品卡固定为单件，不得携带库存或持有数量。")
		_expect(
			card.texture_normal.resource_path.ends_with("shop_product_card_normal_v2.png")
			and card.texture_hover.resource_path.ends_with("shop_product_card_hover_v2.png")
			and card.texture_pressed.resource_path.ends_with("shop_product_card_pressed_v2.png")
			and card.texture_disabled.resource_path.ends_with("shop_product_card_disabled_v2.png"),
			"商品卡必须使用售价底座已经画入框体的四态素材。"
		)
		var price_icon := card.get_node("LightStoneIcon") as TextureRect
		var price_label := card.get_node("PriceLabel") as Label
		_expect(
			price_icon.position.y == 76.0
			and price_icon.size == Vector2(32, 32)
			and price_label.position.y == 78.0
			and price_label.get_rect().end.y <= 108.0,
			"售价内容必须完整落在卡框内建的 y=78..108 底座中。"
		)

	var panel := preview.get_node_or_null("ShopPanel") as NinePatchRect
	var plaque := preview.get_node_or_null("ShopPanel/TitlePlaque") as NinePatchRect
	_audit_nine_patch(panel, 16, "商店主面板")
	if plaque != null:
		_expect(
			plaque.patch_margin_left == 16
			and plaque.patch_margin_right == 16
			and plaque.patch_margin_top == 12
			and plaque.patch_margin_bottom == 12,
			"标题牌必须使用约定的整数九宫格边距。"
		)
		_expect(
			plaque.axis_stretch_horizontal == NinePatchRect.AXIS_STRETCH_MODE_TILE
			and plaque.axis_stretch_vertical == NinePatchRect.AXIS_STRETCH_MODE_TILE,
			"标题牌边缘必须平铺而不是任意拉伸。"
		)


func _audit_nine_patch(panel: NinePatchRect, expected_margin: int, label: String) -> void:
	_expect(panel != null, "%s必须存在。" % label)
	if panel == null:
		return
	_expect(
		panel.patch_margin_left == expected_margin
		and panel.patch_margin_top == expected_margin
		and panel.patch_margin_right == expected_margin
		and panel.patch_margin_bottom == expected_margin,
		"%s必须使用一致的整数九宫格边距。" % label
	)
	_expect(
		panel.axis_stretch_horizontal == NinePatchRect.AXIS_STRETCH_MODE_TILE
		and panel.axis_stretch_vertical == NinePatchRect.AXIS_STRETCH_MODE_TILE,
		"%s边缘必须使用原生 TILE 九宫格。" % label
	)


func _audit_layout(preview: Control) -> void:
	_expect(preview.size == Vector2(VIEWPORT_SIZE), "拼装原型必须以项目 1152×648 基础画布验证。")
	var backdrop := preview.get_node("SceneBackdrop") as TextureRect
	var xiaocong := preview.get_node("XiaocongStage/Xiaocong") as TextureRect
	var panel := preview.get_node("ShopPanel") as Control
	var grid := preview.get_node("ShopPanel/ProductGrid") as GridContainer
	for entry in [backdrop, xiaocong, panel, grid]:
		_expect(_inside_viewport(entry.get_global_rect()), "所有拼装组件必须位于基础画布内：%s" % entry.name)
	_expect(
		backdrop.size == Vector2(VIEWPORT_SIZE)
		and backdrop.texture.resource_path.ends_with("underground_ruins_background.png"),
		"原型必须直接复用项目已有的整张地下遗迹背景，不创建商店背景拆件。"
	)
	var xiaocong_atlas := xiaocong.texture as AtlasTexture
	_expect(
		xiaocong.size == Vector2(366, 477)
		and xiaocong_atlas != null
		and xiaocong_atlas.atlas.resource_path.ends_with("xiaocong_keypose_hd.png"),
		"小葱必须直接复用项目权威立绘，并固定为精确 1/3 的 366×477 显示。"
	)
	_expect(
		preview.get_node_or_null("MerchantBackdrop") == null
		and preview.get_node_or_null("MerchantStage") == null
		and preview.get_node_or_null("CounterForeground") == null,
		"场景树不得重新拆出商店背景、柜台或派生商人舞台。"
	)

	var cards := grid.get_children()
	if cards.size() != 10:
		return
	for card_index in range(cards.size()):
		var card := cards[card_index] as Control
		_expect(card.size == Vector2(128, 128), "商品卡必须保持 128×128 原生槽位尺寸。")
		var expected_column := card_index % 5
		var expected_row := card_index / 5
		_expect(
			is_equal_approx(card.position.x, float(expected_column * 136))
			and is_equal_approx(card.position.y, float(expected_row * 136)),
			"商品卡必须形成整齐的 5×2 像素网格：index=%d position=%s"
			% [card_index, card.position]
		)


func _audit_interaction(preview: Control) -> void:
	var detail := preview.get_node("DetailOverlay") as Control
	var detail_id := detail.get_instance_id()
	var grid := preview.get_node("ShopPanel/ProductGrid") as GridContainer
	var exit_button := preview.get_node("ShopPanel/ExitButton") as TextureButton
	var purchase_button := preview.get_node(
		"DetailOverlay/DetailFrame/PreviewPurchaseButton"
	) as TextureButton
	var cancel_button := preview.get_node(
		"DetailOverlay/DetailFrame/DetailCancelButton"
	) as TextureButton
	# 交互测试直接发出 pressed 信号，不验证全局 UI 点击音。阻止自动
	# UIAudio 为这些合成点击创建播放实例，确保无头测试退出时资源干净。
	for button in [exit_button, purchase_button, cancel_button]:
		button.set_meta(&"skip_ui_click_audio", true)
	for card_node in grid.get_children():
		(card_node as BaseButton).set_meta(&"skip_ui_click_audio", true)
	var initial_child_count := grid.get_child_count()
	var selected_card := grid.get_child(7) as TextureButton
	var purchase_indices: Array[int] = []
	var exit_events: Array[bool] = []
	preview.connect(
		"preview_purchase_requested",
		func(offer_index: int) -> void:
			purchase_indices.append(offer_index)
	)
	preview.connect(
		"exit_requested",
		func() -> void:
			exit_events.append(true)
	)
	_expect(not detail.visible, "商品详情层初始必须隐藏。")
	selected_card.grab_focus()
	selected_card.pressed.emit()
	_expect(detail.visible, "选择商品后必须显示预制的详情层。")
	_expect(detail.mouse_filter == Control.MOUSE_FILTER_STOP, "详情层必须截断鼠标输入，避免穿透到底层商品。")
	_expect((preview.get_node("DetailOverlay/DetailFrame/DetailName") as Label).text == "王家圣杯", "详情层必须读取真实点击的商品名称。")
	_expect((preview.get_node("DetailOverlay/DetailFrame/DetailPrice") as Label).text == "30", "详情层必须读取真实点击商品的卡内售价。")
	for card_node in grid.get_children():
		_expect((card_node as Control).focus_mode == Control.FOCUS_NONE, "详情显示时底层商品卡必须退出焦点导航。")
	_expect(exit_button.focus_mode == Control.FOCUS_NONE, "详情显示时退出按钮必须退出焦点导航。")
	purchase_button.pressed.emit()
	_expect(
		detail.visible
		and (preview.get_node("DetailOverlay/DetailFrame/DetailPrice") as Label).text == "30"
		and purchase_indices == [7],
		"购买按钮必须通过真实信号链发出所选单件商品索引，且不得修改详情或货币状态。"
	)
	cancel_button.pressed.emit()
	_expect(not detail.visible, "取消详情后必须复用同一隐藏层。")
	_expect(selected_card.has_focus(), "取消详情后必须把键盘/手柄焦点还给刚才选择的商品。")
	for card_node in grid.get_children():
		_expect((card_node as Control).focus_mode == Control.FOCUS_ALL, "关闭详情后商品卡必须恢复焦点导航。")
	_expect(exit_button.focus_mode == Control.FOCUS_ALL, "关闭详情后退出按钮必须恢复焦点导航。")
	exit_button.pressed.emit()
	_expect(exit_events.size() == 1, "退出按钮必须通过真实场景连接发出退出请求。")
	_expect(
		detail.get_instance_id() == detail_id and grid.get_child_count() == initial_child_count,
		"交互不得在运行时生成或销毁 UI 节点。"
	)


func _inside_viewport(rect: Rect2) -> bool:
	return (
		rect.position.x >= -1.0
		and rect.position.y >= -1.0
		and rect.end.x <= float(VIEWPORT_SIZE.x) + 1.0
		and rect.end.y <= float(VIEWPORT_SIZE.y) + 1.0
	)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("ROGUE_UNDERGROUND_SHOP_PREVIEW_SMOKE_TEST_OK assets=%d products=10" % EXPECTED_ASSET_SIZES.size())
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)
