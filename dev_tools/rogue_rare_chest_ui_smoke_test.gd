extends SceneTree

const OVERLAY_SCENE := preload(
	"res://scene/game_modes/rogue/rare_chest/rogue_rare_chest_overlay.tscn"
)
const OVERLAY_SCRIPT := preload(
	"res://scene/game_modes/rogue/rare_chest/rogue_rare_chest_overlay.gd"
)

var failures: Array[String] = []
var overlay = null
var choice_payload: Array = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	overlay = OVERLAY_SCENE.instantiate()
	root.add_child(overlay)
	_disable_test_button_audio(overlay)
	overlay.choice_requested.connect(
		func(
			occurrence_key: String,
			offer_revision: int,
			option_id: StringName
		) -> void:
			choice_payload = [occurrence_key, offer_revision, option_id]
	)
	overlay.configure_local_context(
		1,
		{1: "本地玩家", 2: "队友"}
	)
	await process_frame
	_test_authored_layout()
	_test_private_choice_state()
	_test_host_confirmed_waiting_state()
	_test_spectator_state()
	_test_completed_state()
	_test_idle_hides()
	overlay.queue_free()
	await process_frame
	if failures.is_empty():
		print("ROGUE_RARE_CHEST_UI_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_authored_layout() -> void:
	_expect(
		overlay.choice_cards.size() == 3,
		"稀有宝箱界面必须原生配置三张个人选项卡。"
	)
	var shared_background_path := (
		"res://resources/texture/rogue_route/supply/supply_choice_panel.png"
	)
	for card in overlay.choice_cards:
		_expect(
			card.custom_minimum_size == Vector2(520, 148)
			and card.size == Vector2(520, 148),
			"稀有宝箱选项卡必须保持 520x148。"
		)
		_expect(
			card.background_texture != null
			and card.background_texture.resource_path == shared_background_path
			and card.background.texture == card.background_texture,
			"三张稀有宝箱卡必须共用遗址物资卡片背景。"
		)
		_expect(
			card.background.texture_filter
			== CanvasItem.TEXTURE_FILTER_NEAREST,
			"选项卡背景必须使用 nearest。"
		)
		_expect(
			card.get_node_or_null("Content/Margin/Rows/Footer") == null
			and card.get_node_or_null("Content/Margin/Rows/VoteRow") == null
			and card.find_child("LightStoneCost", true, false) == null
			and card.find_child("Voter0", true, false) == null,
			"稀有宝箱卡片不能含投票头像或光石区域。"
		)
		_expect(
			card.effect_label.label_settings.font_size >= 24
			and card.detail_label.label_settings.font_size >= 17,
			"永久增益与补充说明必须保持清晰字号。"
		)
	var tableau_frame: Control = overlay.tableau.get_parent().get_parent()
	_expect(
		tableau_frame.custom_minimum_size == Vector2(366, 478),
		"高分辨率宝箱图必须落在 366x478 authored 画框。"
	)
	_expect(
		overlay.tableau.size == Vector2(366, 478)
		and overlay.tableau.texture_filter
		== CanvasItem.TEXTURE_FILTER_LINEAR
		and overlay.tableau.stretch_mode
		== TextureRect.STRETCH_KEEP_ASPECT_CENTERED,
		"高分辨率宝箱图必须按画框静态等比缩放并使用 linear。"
	)
	_expect(
		overlay.tableau.texture != null
		and overlay.tableau.texture.resource_path
		== (
			"res://resources/texture/rogue_route/prepare_ahead/"
			+ "rare_chest_tableau.png"
		),
		"左框必须使用获批的生产高分辨率宝箱图。"
	)
	_expect(
		overlay.find_child("CompleteButton", true, false) == null
		and overlay.find_child("ExitButton", true, false) == null,
		"稀有宝箱界面不能提供手动退出按钮。"
	)


func _test_private_choice_state() -> void:
	choice_payload.clear()
	overlay.apply_state(_make_state(OVERLAY_SCRIPT.PHASE_CHOOSING))
	_expect(overlay.visible, "choosing 状态必须显示稀有宝箱界面。")
	_expect(
		overlay.choice_cards[0].effect_label.text == "生命值永久+10"
		and overlay.choice_cards[0].detail_label.text
		== "同时回复10点生命值",
		"生命选项必须显示精确效果和同步治疗说明。"
	)
	_expect(
		overlay.choice_cards[1].effect_label.text == "物理防御永久+2"
		and not overlay.choice_cards[1].detail_label.visible,
		"无补充说明的选项只能显示精确效果。"
	)
	for card in overlay.choice_cards:
		_expect(not card.button.disabled, "三个私人候选都应可选择。")
	overlay.choice_cards[1].button.pressed.emit()
	_expect(
		choice_payload == ["rare_chest:42", 7, &"physical_defense"],
		"点击必须提交 occurrence、个人 offer revision 与 option id。"
	)
	_expect(
		overlay.submission_pending,
		"首次点击后必须等待 Host 确认。"
	)
	for card in overlay.choice_cards:
		_expect(card.button.disabled, "等待 Host 时三张卡都必须禁用。")
		_expect(
			not card.selection_border.visible,
			"Host 确认前不能提前显示选择成功。"
		)
	overlay.choice_cards[1].button.pressed.emit()
	_expect(
		choice_payload == ["rare_chest:42", 7, &"physical_defense"],
		"快速连点不能重复发出选择请求。"
	)


func _test_host_confirmed_waiting_state() -> void:
	var state := _make_state(OVERLAY_SCRIPT.PHASE_WAITING)
	state["local_selected_option_id"] = "physical_defense"
	state["local_result_text"] = "物理防御永久提高2点"
	state["completed_peer_ids"] = [1]
	overlay.apply_state(state)
	_expect(
		not overlay.submission_pending,
		"Host 回传选择后必须清除本地 pending。"
	)
	_expect(
		overlay.choice_cards[1].selection_border.visible
		and overlay.choice_cards[1].self_modulate == Color.WHITE,
		"Host 确认的卡片必须高亮。"
	)
	_expect(
		overlay.choice_cards[0].self_modulate.r < 0.7
		and overlay.choice_cards[2].self_modulate.r < 0.7,
		"确认后其余两张卡必须变暗。"
	)
	_expect(
		overlay.local_result_label.visible
		and overlay.local_result_label.text == "物理防御永久提高2点",
		"确认后必须显示本地私有结算文本。"
	)
	_expect(
		overlay.waiting_list_label.text == "等待：队友",
		"确认后必须显示公共等待名单。"
	)


func _test_spectator_state() -> void:
	var state := _make_state(OVERLAY_SCRIPT.PHASE_WAITING)
	state["participant_peer_ids"] = [2]
	state["active_peer_ids"] = [2]
	state["local_option_ids"] = []
	state["local_option_availability"] = {}
	overlay.apply_state(state)
	_expect(
		overlay.status_label.text.contains("旁观"),
		"迟到加入者必须显示旁观状态。"
	)
	for card in overlay.choice_cards:
		_expect(not card.visible, "旁观者不能看到其他玩家的私有候选。")


func _test_completed_state() -> void:
	var state := _make_state(OVERLAY_SCRIPT.PHASE_COMPLETED)
	state["local_selected_option_id"] = "max_health"
	state["local_result_text"] = "最大生命值永久提高10点"
	state["completed_peer_ids"] = [1, 2]
	overlay.apply_state(state)
	_expect(
		overlay.status_label.text == "所有玩家均已完成选择"
		and overlay.waiting_list_label.text == "所有有效玩家均已完成选择",
		"全员完成时只能显示完成状态并等待上层关闭。"
	)
	for card in overlay.choice_cards:
		_expect(
			card.button.disabled and not card.button.has_focus(),
			"completed 阶段所有卡片必须锁定且不可聚焦。"
		)


func _test_idle_hides() -> void:
	overlay.apply_state({"phase": "idle"})
	_expect(not overlay.visible, "idle 状态必须立即隐藏稀有宝箱界面。")


func _make_state(phase: StringName) -> Dictionary:
	return {
		"schema_version": 1,
		"phase": String(phase),
		"occurrence_key": "rare_chest:42",
		"offer_revision": 7,
		"local_option_ids": [
			"max_health",
			"physical_defense",
			"move_speed",
		],
		"local_selected_option_id": "",
		"local_result_text": "",
		"local_option_availability": {
			"max_health": {"available": true, "disabled_reason": ""},
			"physical_defense": {"available": true, "disabled_reason": ""},
			"move_speed": {"available": true, "disabled_reason": ""},
		},
		"participant_peer_ids": [1, 2],
		"active_peer_ids": [1, 2],
		"completed_peer_ids": [],
	}


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _disable_test_button_audio(node: Node) -> void:
	if node is BaseButton:
		node.set_meta(&"skip_ui_click_audio", true)
	for child in node.get_children():
		_disable_test_button_audio(child)
