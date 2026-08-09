extends SceneTree

const OVERLAY_SCENE := preload(
	"res://scene/game_modes/rogue/supply/rogue_supply_overlay.tscn"
)

var failures: Array[String] = []
var overlay: RogueSupplyOverlay
var intro_ack_payload: Array = []
var vote_payload: Array = []
var collectible_payload: Array = []
var completed_payload: Array = []
var inventory_requested_count := 0


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	overlay = OVERLAY_SCENE.instantiate() as RogueSupplyOverlay
	root.add_child(overlay)
	_disable_test_button_audio(overlay)
	overlay.intro_ack_requested.connect(
		func(occurrence_key: String, revision: int) -> void:
			intro_ack_payload = [occurrence_key, revision]
	)
	overlay.vote_requested.connect(
		func(
			occurrence_key: String,
			revision: int,
			option_id: StringName
		) -> void:
			vote_payload = [occurrence_key, revision, option_id]
	)
	overlay.collectible_choice_requested.connect(
		func(
			occurrence_key: String,
			revision: int,
			offer_index: int
		) -> void:
			collectible_payload = [occurrence_key, revision, offer_index]
	)
	overlay.completed_requested.connect(
		func(occurrence_key: String, revision: int) -> void:
			completed_payload = [occurrence_key, revision]
	)
	overlay.inventory_requested.connect(
		func() -> void: inventory_requested_count += 1
	)
	var character_id := PlayerCharacterRegistry.get_default_character_id()
	overlay.configure_local_context(
		1,
		{1: "本地玩家", 2: "队友"},
		{1: character_id, 2: character_id}
	)
	await process_frame
	_test_authored_layout()
	await _test_intro_auto_ack()
	await _test_vote_state()
	_test_collectible_state()
	_test_result_state()
	_test_completed_state()
	_test_idle_hides()
	overlay.queue_free()
	await process_frame
	if failures.is_empty():
		print("ROGUE_SUPPLY_UI_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_authored_layout() -> void:
	_expect(overlay.choice_cards.size() == 3, "物资界面必须原生配置三张主选项卡。")
	var shared_background_path := (
		"res://resources/texture/rogue_route/supply/supply_choice_panel.png"
	)
	for card in overlay.choice_cards:
		_expect(
			card.custom_minimum_size == Vector2(520, 148)
			and card.size == Vector2(520, 148),
			"主选项卡必须保持 520x148。"
		)
		_expect(
			card.background.texture_filter
			== CanvasItem.TEXTURE_FILTER_NEAREST,
			"主选项卡背景必须使用 nearest，保持清晰像素边缘。"
		)
		_expect(
			card.background_texture != null
			and card.background_texture.resource_path == shared_background_path
			and card.background.texture == card.background_texture,
			"三张主选项卡必须共用同一张背景纹理。"
		)
		var normal_style := card.button.get_theme_stylebox("normal") as StyleBoxFlat
		_expect(
			normal_style != null
			and normal_style.corner_radius_top_left == 16
			and normal_style.corner_radius_top_right == 16
			and normal_style.corner_radius_bottom_left == 16
			and normal_style.corner_radius_bottom_right == 16,
			"卡片交互描边必须与背景的 16px 透明切角对齐。"
		)
		var content_margin := card.get_node("Content/Margin") as MarginContainer
		var footer := card.get_node("Content/Margin/Rows/Footer") as HBoxContainer
		_expect(
			content_margin.get_theme_constant("margin_left") == 28
			and content_margin.get_theme_constant("margin_top") == 18
			and content_margin.get_theme_constant("margin_right") == 28
			and content_margin.get_theme_constant("margin_bottom") == 20,
			"卡片文字必须保持在木框内侧安全区。"
		)
		_expect(
			card.number_label.label_settings.font_size >= 22
			and card.title_label.label_settings.font_size >= 23
			and card.description_label.label_settings.font_size >= 18
			and card.disabled_reason_label.label_settings.font_size >= 15,
			"卡片标题、正文与条件文字必须保持可读字号。"
		)
		_expect(
			footer.position.y + footer.size.y <= card.size.y - 16.0,
			"卡片底部条件行不能进入木质边框区域。"
		)
		_expect(
			card.voter_portraits.size() == 8,
			"每张选项卡必须原生配置八个投票头像槽。"
		)
	_expect(
		overlay.tableau.get_parent().get_parent().custom_minimum_size
		== Vector2(366, 478),
		"左侧物资画面应落在 390x520 舞台内的 366x478 画框。"
	)
	_expect(
		overlay.tableau.size == Vector2(366, 478)
		and overlay.tableau.scale == Vector2.ONE
		and overlay.tableau.texture_filter
		== CanvasItem.TEXTURE_FILTER_NEAREST,
		"物资场景必须按原生 366x478 nearest 呈现。"
	)
	_expect(
		overlay.collectible_panel.cards.size() == 3,
		"个人收藏品面板必须固定为三选一。"
	)
	_expect(
		overlay.collectible_panel.get_node_or_null("Cancel") == null
		and overlay.collectible_panel.get_node_or_null("Refresh") == null,
		"个人收藏品面板不能提供取消或刷新按钮。"
	)
	for card in overlay.collectible_panel.cards:
		_expect(
			card.icon_rect.custom_minimum_size == Vector2(32, 32)
			and card.icon_rect.texture_filter
			== CanvasItem.TEXTURE_FILTER_NEAREST,
			"收藏品图标必须按 32x32 nearest 呈现。"
		)


func _test_intro_auto_ack() -> void:
	intro_ack_payload.clear()
	overlay.apply_state(_make_state(RogueSupplyOverlay.PHASE_INTRO, 1))
	await create_timer(0.65).timeout
	_expect(
		intro_ack_payload == ["supply:42", 1],
		"intro reveal 完成后应只提交当前 occurrence/revision。"
	)


func _test_vote_state() -> void:
	intro_ack_payload.clear()
	vote_payload.clear()
	var state := _make_state(RogueSupplyOverlay.PHASE_VOTING, 2)
	state["votes"] = [{"peer_id": 2, "option_id": "flying_envelope"}]
	overlay.apply_state(state)
	await process_frame
	_expect(
		intro_ack_payload == ["supply:42", 2],
		"首名玩家推进到 voting 后，未确认客户端必须用新 revision 自动补 ack。"
	)
	_expect(overlay.status_label.text.contains("47秒"), "投票界面必须显示权威剩余秒数。")
	var free_card := overlay.choice_cards[0]
	var paid_card := overlay.choice_cards[1]
	_expect(not free_card.button.disabled, "免费物资选项应可投票。")
	_expect(paid_card.button.disabled, "0 光石时付费选项必须禁用。")
	_expect(
		is_equal_approx(paid_card.self_modulate.a, 1.0)
		and paid_card.self_modulate.r >= 0.8,
		"浅色卡片的禁用状态必须保持不透明与可读对比。"
	)
	_expect(paid_card.light_stone_cost.visible, "付费选项必须显示光石图标。")
	_expect(
		paid_card.light_stone_amount.text == "0/1",
		"光石不足的付费选项必须显示 0/1。"
	)
	_expect(
		overlay.choice_cards[2].voter_portraits[0].visible,
		"队友投票必须以头像显示在对应卡片上。"
	)
	_expect(
		overlay.choice_cards[2].voter_portraits[0].tooltip_text == "队友",
		"投票头像提示必须使用玩家名称。"
	)
	free_card.button.pressed.emit()
	_expect(
		vote_payload == [
			"supply:42",
			2,
			RogueSupplyRegistry.OPTION_CORE_REPAIR,
		],
		"主选项点击应发出 Host 权威投票请求参数。"
	)


func _test_collectible_state() -> void:
	collectible_payload.clear()
	inventory_requested_count = 0
	var pool := CollectibleRegistry.get_standard_random_pool()
	_expect(pool.size() >= 3, "收藏品测试需要至少三个标准候选。")
	if pool.size() < 3:
		return
	var paths: Array[String] = []
	for index in range(3):
		paths.append(pool[index].resource_path)
	var state := _make_state(
		RogueSupplyOverlay.PHASE_COLLECTIBLE_CHOICE,
		3
	)
	state["winning_option"] = String(
		RogueSupplyRegistry.OPTION_LIGHT_STONE_COLLECTIBLES
	)
	state["collectible_offers"] = [{
		"peer_id": 1,
		"occurrence_key": "supply:42",
		"paths": paths,
	}]
	overlay.apply_state(state)
	_expect(overlay.collectible_modal.visible, "收藏品阶段必须打开个人三选一面板。")
	for card in overlay.collectible_panel.cards:
		_expect(card.visible and not card.button.disabled, "三个个人候选都应可选择。")
	_expect(
		overlay.collectible_panel.inventory_button.visible
		and not overlay.collectible_panel.inventory_button.disabled,
		"尚未领取收藏品时必须能打开背包整理空间。"
	)
	overlay.collectible_panel.inventory_button.pressed.emit()
	_expect(inventory_requested_count == 1, "整理背包按钮必须发出独立请求。")
	overlay.collectible_panel.cards[1].button.pressed.emit()
	_expect(
		collectible_payload == ["supply:42", 3, 1],
		"收藏品点击应提交 occurrence/revision/offer_index。"
	)
	state["claimed_peer_ids"] = [1]
	overlay.apply_state(state)
	_expect(
		not overlay.collectible_panel.inventory_button.visible,
		"本地玩家领取后必须隐藏整理背包按钮。"
	)


func _test_result_state() -> void:
	completed_payload.clear()
	var state := _make_state(RogueSupplyOverlay.PHASE_RESULT, 4)
	state["winning_option"] = String(RogueSupplyRegistry.OPTION_CORE_REPAIR)
	state["result_text"] = "核心生命值上限与当前生命值各提高10点"
	state["personal_messages"] = [{"peer_id": 1, "message": "核心恢复完成"}]
	overlay.apply_state(state)
	_expect(overlay.result_text.visible, "结果阶段必须显示结算文本。")
	_expect(
		overlay.result_text.text.contains("核心恢复完成"),
		"结果阶段必须合并本地玩家消息。"
	)
	_expect(
		is_equal_approx(overlay.choice_cards[1].self_modulate.a, 1.0)
		and overlay.choice_cards[1].self_modulate.r >= 0.6,
		"结算落选卡必须保持不透明与可读对比。"
	)
	overlay.result_button.pressed.emit()
	_expect(
		completed_payload == ["supply:42", 4],
		"结果确认应提交当前 occurrence/revision。"
	)


func _test_completed_state() -> void:
	var state := _make_state(RogueSupplyOverlay.PHASE_COMPLETED, 5)
	state["winning_option"] = String(RogueSupplyRegistry.OPTION_CORE_REPAIR)
	state["result_text"] = "物资分配已完成"
	state["result_ack_peer_ids"] = [1, 2]
	overlay.apply_state(state)
	for card in overlay.choice_cards:
		_expect(
			not card.button.has_focus(),
			"completed 阶段不应尝试聚焦不可交互的选项卡。"
		)
	var pool := CollectibleRegistry.get_standard_random_pool()
	if pool.size() >= 3:
		var paths: Array[String] = []
		for index in range(3):
			paths.append(pool[index].resource_path)
		state["participant_peer_ids"] = [2]
		state["active_peer_ids"] = [2]
		state["collectible_offers"] = [{
			"peer_id": 1,
			"occurrence_key": "supply:older",
			"paths": paths,
		}]
		overlay.apply_state(state)
		_expect(
			overlay.collectible_modal.visible
			and not overlay.screen_margin.visible
			and overlay.collectible_panel.inventory_button.visible,
			"completed 后的跨节点个人待领取必须独立显示且仍可整理背包。"
		)


func _test_idle_hides() -> void:
	overlay.apply_state({"phase": "idle"})
	_expect(not overlay.visible, "idle 状态必须立即隐藏物资界面。")


func _make_state(phase: StringName, revision: int) -> Dictionary:
	return {
		"schema_version": 2,
		"revision": revision,
		"phase": String(phase),
		"node_id": 42,
		"node_content_seed": 7788,
		"occurrence_key": "supply:42",
		"remaining_seconds": 47.0,
		"voting_timer_running": true,
		"participant_peer_ids": [1, 2],
		"active_peer_ids": [1, 2],
		"disconnected_peer_ids": [],
		"intro_confirmed_peer_ids": [],
		"option_ids": [
			String(RogueSupplyRegistry.OPTION_CORE_REPAIR),
			String(RogueSupplyRegistry.OPTION_LIGHT_STONE_XIRANG),
			String(RogueSupplyRegistry.OPTION_FLYING_ENVELOPE),
		],
		"option_availability": {
			String(RogueSupplyRegistry.OPTION_CORE_REPAIR): true,
			String(RogueSupplyRegistry.OPTION_LIGHT_STONE_XIRANG): false,
			String(RogueSupplyRegistry.OPTION_FLYING_ENVELOPE): true,
		},
		"light_stone_amount": 0,
		"votes": [],
		"abstained_peer_ids": [],
		"winning_option": "",
		"result": {},
		"result_text": "",
		"collectible_offers": [],
		"claimed_peer_ids": [],
		"personal_messages": [],
		"result_ack_peer_ids": [],
		"resolved_node_ids": [],
		"settlement_committed": false,
	}


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _disable_test_button_audio(node: Node) -> void:
	if node is BaseButton:
		node.set_meta(&"skip_ui_click_audio", true)
	for child in node.get_children():
		_disable_test_button_audio(child)
