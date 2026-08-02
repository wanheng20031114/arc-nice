extends SceneTree

const OVERLAY_SCENE := preload(
	"res://scene/rogue_encounter/rogue_encounter_overlay.tscn"
)

var failures: Array[String] = []
var intro_requests: Array[Dictionary] = []
var vote_requests: Array[Dictionary] = []
var revealed_count := 0
var result_hold_count := 0


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var overlay := OVERLAY_SCENE.instantiate() as RogueEncounterOverlay
	root.add_child(overlay)
	overlay.intro_ack_requested.connect(
		func(key: String, revision: int) -> void:
			intro_requests.append({"key": key, "revision": revision})
	)
	overlay.vote_requested.connect(
		func(key: String, revision: int, option: StringName) -> void:
			vote_requests.append({
				"key": key,
				"revision": revision,
				"option": option,
			})
	)
	overlay.encounter_revealed.connect(
		func(_key: String, _revision: int) -> void: revealed_count += 1
	)
	overlay.result_hold_completed.connect(
		func(_key: String, _revision: int) -> void: result_hold_count += 1
	)
	overlay.configure_local_context(1, {1: "玩家"}, {1: &""})
	overlay.apply_state(_make_intro_state())
	await overlay.cover_map_for_encounter()
	await overlay.reveal_encounter()
	_expect(overlay.visible, "遭遇揭示后覆盖层必须可见。")
	_expect(revealed_count == 1, "每个 occurrence 只能发出一次 reveal 完成信号。")
	_expect(
		overlay.dialogue_text.text.replace(
			DialogueTypewriterController.NO_BREAK_MARK,
			""
		) == RogueEncounterOverlay.INTRO_TEXT,
		"鸡哥开场对白必须与策划文本完全一致。"
	)
	var echoed_confirm := InputEventKey.new()
	echoed_confirm.keycode = KEY_ENTER
	echoed_confirm.pressed = true
	echoed_confirm.echo = true
	overlay._input(echoed_confirm)
	_expect(
		overlay.typewriter.is_revealing(),
		"长按确认键产生的echo事件不得补全或跳过对白。"
	)

	var confirm := InputEventAction.new()
	confirm.action = &"interact"
	confirm.pressed = true
	overlay._input(confirm)
	_expect(
		not overlay.typewriter.is_revealing() and intro_requests.is_empty(),
		"第一次确认只能补全文字，不得提前提交对白确认。"
	)
	overlay._input(confirm)
	await create_timer(RogueEncounterOverlay.OPTION_REVEAL_DURATION_SECONDS + 0.08).timeout
	_expect(
		intro_requests.size() == 1
		and bool(overlay.options_page.visible),
		"第二次确认应提交个人对白确认并立即揭示选项。"
	)
	var rejected_ack := _make_intro_state()
	rejected_ack["revision"] = 2
	overlay.apply_state(rejected_ack)
	_expect(
		overlay.intro_page.visible and not overlay.local_intro_advanced,
		"权威revision前进但未确认对白时，应撤销过期乐观态以允许重试。"
	)

	var voting := _make_intro_state()
	voting["revision"] = 3
	voting["phase"] = "voting"
	voting["intro_confirmed_peer_ids"] = [1]
	voting["option_availability"] = {
		"purchase_basketball": false,
		"ask_for_free": true,
	}
	overlay.apply_state(voting)
	_expect(
		overlay.choice_purchase.button.disabled
		and not overlay.choice_free.button.disabled,
		"木板不足时购买项应显示但禁用，0元购仍可选择。"
	)
	_expect(
		overlay.choice_purchase.title_label.text == "购买篮球"
		and overlay.choice_purchase.description_label.text
		== "花费10个木板购买一个篮球"
		and overlay.choice_free.description_label.text
		== "鸡哥有概率被你说服",
		"鸡哥两个选项必须使用精简后的标题与小字文案。"
	)
	overlay.choice_free.button.emit_signal("pressed")
	_expect(
		vote_requests.size() == 1
		and StringName(vote_requests[0]["option"])
		== RogueEncounterOverlay.OPTION_FREE,
		"可用选项应提交 occurrence、revision 与 option id。"
	)

	var result := voting.duplicate(true)
	result["revision"] = 5
	result["phase"] = "result"
	result["result_text"] = "鸡哥：好吧，那就送你了。"
	overlay.apply_state(result)
	overlay.typewriter.finish_line()
	await create_timer(RogueEncounterOverlay.RESULT_HOLD_SECONDS + 0.08).timeout
	_expect(result_hold_count == 1, "结果完整显示后必须停留1.5秒再请求退出。")
	await overlay.reveal_map_after_encounter()
	_expect(not overlay.visible, "退出转场后覆盖层必须完全隐藏。")
	var replay := _make_intro_state()
	replay["revision"] = 6
	overlay.apply_state(replay)
	await overlay.cover_map_for_encounter()
	await overlay.reveal_encounter()
	_expect(
		revealed_count == 2,
		"覆盖层隐藏后必须允许同 occurrence 的重同步实例再次完成 reveal。"
	)
	overlay.hide_immediately()
	overlay.free()
	_test_mouse_confirm_and_inactive_vote_filter()
	await _test_reconnected_options_focus()
	await _test_completed_state_waits_for_local_result_hold()

	if failures.is_empty():
		print("ROGUE_ENCOUNTER_OVERLAY_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _make_intro_state() -> Dictionary:
	return {
		"schema_version": 1,
		"revision": 1,
		"phase": "intro",
		"node_id": 12,
		"node_content_seed": 9981,
		"occurrence_key": "12:9981",
		"encounter_id": "chicken_bro",
		"remaining_seconds": 60.0,
		"voting_timer_running": false,
		"participant_peer_ids": [1],
		"active_peer_ids": [1],
		"spectator_peer_ids": [],
		"intro_confirmed_peer_ids": [],
		"votes": [],
		"abstained_peer_ids": [],
		"option_availability": {
			"purchase_basketball": true,
			"ask_for_free": true,
		},
		"winning_option": "",
		"economy_result": {},
		"result_text": "",
	}


func _test_mouse_confirm_and_inactive_vote_filter() -> void:
	var overlay := OVERLAY_SCENE.instantiate() as RogueEncounterOverlay
	root.add_child(overlay)
	overlay.configure_local_context(11, {11: "玩家一", 22: "玩家二"}, {})
	var state := _make_intro_state()
	state["participant_peer_ids"] = [11, 22]
	state["active_peer_ids"] = [11]
	overlay.apply_state(state)
	overlay.visible = true
	overlay.encounter_is_revealed = true
	overlay.local_intro_advanced = false
	overlay.typewriter.say(RogueEncounterOverlay.INTRO_TEXT)
	var mouse_confirm := InputEventMouseButton.new()
	mouse_confirm.button_index = MOUSE_BUTTON_LEFT
	mouse_confirm.pressed = true
	overlay._input(mouse_confirm)
	_expect(
		not overlay.typewriter.is_revealing(),
		"鼠标左键第一次确认应补全当前对白。"
	)
	state["revision"] = 2
	state["intro_confirmed_peer_ids"] = [11]
	state["phase"] = "voting"
	state["votes"] = [
		{"peer_id": 11, "option_id": "purchase_basketball"},
		{"peer_id": 22, "option_id": "ask_for_free"},
	]
	overlay.apply_state(state)
	overlay._update_vote_state()
	_expect(
		overlay.vote_status_label.text.begins_with("已投票 1/1"),
		"可见票数只能统计仍有效玩家。"
	)
	_expect(
		overlay._get_voters_for_option(&"ask_for_free").is_empty(),
		"掉线玩家的保留票不得出现在有效投票头像中。"
	)
	overlay.free()


func _test_reconnected_options_focus() -> void:
	var overlay := OVERLAY_SCENE.instantiate() as RogueEncounterOverlay
	root.add_child(overlay)
	overlay.configure_local_context(7, {7: "重连玩家"}, {})
	var state := _make_intro_state()
	state["participant_peer_ids"] = [7]
	state["active_peer_ids"] = [7]
	state["intro_confirmed_peer_ids"] = [7]
	state["phase"] = "voting"
	overlay.apply_state(state)
	await overlay.cover_map_for_encounter()
	await overlay.reveal_encounter()
	_expect(
		overlay.choice_purchase.button.has_focus()
		or overlay.choice_free.button.has_focus(),
		"重连或全量同步后直接进入选项页时，手柄必须获得可用选项焦点。"
	)
	# 覆盖层已经揭示后，也可能因修复性全量快照从对白页直接恢复到选项页。
	overlay.choice_purchase.button.release_focus()
	overlay.choice_free.button.release_focus()
	var repaired_intro := _make_intro_state()
	repaired_intro["node_id"] = 13
	repaired_intro["node_content_seed"] = 9982
	repaired_intro["occurrence_key"] = "13:9982"
	repaired_intro["participant_peer_ids"] = [7]
	repaired_intro["active_peer_ids"] = [7]
	overlay.apply_state(repaired_intro)
	var repaired_voting := repaired_intro.duplicate(true)
	repaired_voting["revision"] = 2
	repaired_voting["phase"] = "voting"
	repaired_voting["intro_confirmed_peer_ids"] = [7]
	overlay.apply_state(repaired_voting)
	_expect(
		overlay.options_page.visible
		and (
			overlay.choice_purchase.button.has_focus()
			or overlay.choice_free.button.has_focus()
		),
		"已揭示覆盖层的全量修复直接进入选项页时也必须补齐手柄焦点。"
	)
	overlay.hide_immediately()
	overlay.free()


func _test_completed_state_waits_for_local_result_hold() -> void:
	var overlay := OVERLAY_SCENE.instantiate() as RogueEncounterOverlay
	root.add_child(overlay)
	overlay.configure_local_context(17, {17: "高延迟玩家"}, {})
	var local_hold_count := [0]
	overlay.result_hold_completed.connect(
		func(_key: String, _revision: int) -> void: local_hold_count[0] += 1
	)
	overlay.visible = true
	overlay.encounter_content.visible = true
	overlay.encounter_is_revealed = true
	var result := _make_intro_state()
	result["participant_peer_ids"] = [17]
	result["active_peer_ids"] = [17]
	result["intro_confirmed_peer_ids"] = [17]
	result["revision"] = 4
	result["phase"] = "result"
	result["result_text"] = "好吧，那就送你了。"
	overlay.apply_state(result)
	var completed := result.duplicate(true)
	completed["revision"] = 5
	completed["phase"] = "completed"
	overlay.apply_state(completed)
	_expect(
		local_hold_count[0] == 0 and overlay.typewriter.is_revealing(),
		"completed 快照不得跳过高延迟客户端尚未完成的结果逐字显示。"
	)
	overlay.typewriter.finish_line()
	await create_timer(RogueEncounterOverlay.RESULT_HOLD_SECONDS - 0.1).timeout
	_expect(local_hold_count[0] == 0, "completed 状态也必须完整保留本地1.5秒结果停留。")
	await create_timer(0.18).timeout
	_expect(local_hold_count[0] == 1, "本地结果停留完成后应恰好发出一次退出就绪信号。")
	overlay.hide_immediately()
	overlay.free()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
