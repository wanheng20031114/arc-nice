extends SceneTree

const OVERLAY_SCENE := preload(
	"res://scene/game_modes/rogue/combat/reward/rogue_emergency_reward_choice_overlay.tscn"
)

var failures: Array[String] = []
var overlay: CanvasLayer
var choice_payloads: Array[Array] = []
var inventory_requested_count := 0


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	overlay = OVERLAY_SCENE.instantiate() as CanvasLayer
	root.add_child(overlay)
	_disable_test_button_audio(overlay)
	overlay.choice_selected.connect(
		func(round_number: int, offer_index: int) -> void:
			choice_payloads.append([round_number, offer_index])
	)
	overlay.inventory_requested.connect(
		func() -> void: inventory_requested_count += 1
	)
	await process_frame
	_test_authored_layout()
	_test_two_choice_round_and_retry()
	_test_next_round_and_timeout()
	_test_hide_reset()
	overlay.queue_free()
	await process_frame
	if failures.is_empty():
		print("ROGUE_EMERGENCY_REWARD_CHOICE_OVERLAY_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_authored_layout() -> void:
	_expect(
		overlay.choice_panel.scene_file_path
		== "res://scene/game_modes/rogue/supply/rogue_supply_collectible_choice_panel.tscn",
		"紧急奖励界面必须复用现有收藏品选择面板场景。"
	)
	_expect(
		overlay.get_node_or_null("CountdownTimer") is Timer,
		"30 秒倒计时必须由场景原生 Timer 节点承载。"
	)
	_expect(
		overlay.choice_panel.cards.size() == 3,
		"复用面板的三张原生卡片结构必须保持完整。"
	)


func _test_two_choice_round_and_retry() -> void:
	var paths := _get_offer_paths(0)
	if paths.size() != 2:
		return
	overlay.show_round(paths, 1, 2, 30.0)
	_expect(overlay.visible, "显示奖励轮次时覆盖层必须可见。")
	_expect(
		overlay.root.mouse_filter == Control.MOUSE_FILTER_STOP,
		"奖励覆盖层显示时必须阻止点击穿透。"
	)
	_expect(overlay.round_label.text == "第 1 / 2 轮", "必须显示当前奖励轮次。")
	_expect(overlay.countdown_label.text.contains("30"), "每轮必须显示 30 秒倒计时。")
	_expect(
		overlay.choice_panel.cards[0].visible
		and overlay.choice_panel.cards[1].visible
		and not overlay.choice_panel.cards[2].visible,
		"每轮必须只显示两个收藏品候选。"
	)
	_expect(
		not overlay.choice_panel.cards[0].button.disabled
		and not overlay.choice_panel.cards[1].button.disabled,
		"有效的两个候选都必须可选择。"
	)
	choice_payloads.clear()
	overlay.choice_panel.cards[1].button.pressed.emit()
	_expect(
		choice_payloads == [[1, 1]],
		"选择收藏品必须发出轮次与候选下标。"
	)
	_expect(
		overlay.pending_offer_index == 1
		and not overlay.choice_panel.interaction_enabled
		and overlay.choice_panel.cards[0].button.mouse_filter
		== Control.MOUSE_FILTER_IGNORE
		and overlay.choice_panel.cards[1].button.mouse_filter
		== Control.MOUSE_FILTER_IGNORE,
		"提交后必须保留所选下标并阻止重复点击。"
	)
	overlay.show_inventory_full_error()
	_expect(
		overlay.pending_offer_index == 1
		and overlay.active_offer_paths == paths,
		"背包已满时必须保留当前选择与候选。"
	)
	_expect(
		overlay.retry_button.visible
		and not overlay.retry_button.disabled
		and overlay.choice_panel.inventory_button.visible
		and not overlay.choice_panel.inventory_button.disabled,
		"背包已满后必须同时允许整理背包与重试领取。"
	)
	inventory_requested_count = 0
	overlay.choice_panel.inventory_button.pressed.emit()
	_expect(inventory_requested_count == 1, "整理背包必须发出独立信号。")
	overlay.retry_button.pressed.emit()
	_expect(
		choice_payloads == [[1, 1], [1, 1]],
		"重试必须重新提交已保留的同一候选。"
	)


func _test_next_round_and_timeout() -> void:
	var paths := _get_offer_paths(2)
	if paths.size() != 2:
		return
	overlay.show_round(paths, 2, 2, 8.2)
	_expect(
		overlay.pending_offer_index
		== -1,
		"进入下一轮时必须清理上一轮保留的选择。"
	)
	_expect(overlay.round_label.text == "第 2 / 2 轮", "第二轮标签必须正确。")
	_expect(
		overlay.countdown_label.text.contains("09"),
		"非整数剩余时间必须向上取整显示。"
	)
	overlay.set_remaining_seconds(0.0)
	_expect(
		overlay.countdown_label.text.contains("00")
		and overlay.choice_panel.cards[0].button.disabled
		and overlay.choice_panel.cards[1].button.disabled,
		"倒计时结束后必须显示 00 并停止本地选择。"
	)
	_expect(
		overlay.choice_panel.status_label.text.contains("自动分配"),
		"倒计时结束后必须提示正在等待自动选择。"
	)
	overlay.pending_offer_index = 0
	overlay.show_inventory_full_error()
	choice_payloads.clear()
	overlay.retry_button.pressed.emit()
	_expect(
		choice_payloads == [[2, 0]],
		"超时自动项因背包已满而锁定后，整理背包仍必须能重试同一候选。"
	)


func _test_hide_reset() -> void:
	overlay.hide_and_reset()
	_expect(not overlay.visible, "重置后覆盖层必须隐藏。")
	_expect(
		overlay.root.mouse_filter == Control.MOUSE_FILTER_IGNORE,
		"重置后覆盖层必须恢复点击穿透。"
	)
	_expect(
		overlay.active_round_number == 0
		and overlay.active_offer_paths.is_empty()
		and overlay.pending_offer_index
		== -1
		and overlay.countdown_timer.is_stopped(),
		"隐藏重置必须清理轮次、候选、保留选择与计时器。"
	)


func _get_offer_paths(start_index: int) -> Array[String]:
	var pool := CollectibleRegistry.get_standard_random_pool()
	_expect(pool.size() >= start_index + 2, "UI 测试需要至少四个收藏品配置。")
	var result: Array[String] = []
	if pool.size() < start_index + 2:
		return result
	for index in range(start_index, start_index + 2):
		result.append(pool[index].resource_path)
	return result


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _disable_test_button_audio(node: Node) -> void:
	if node is BaseButton:
		node.set_meta(&"skip_ui_click_audio", true)
	for child in node.get_children():
		_disable_test_button_audio(child)
