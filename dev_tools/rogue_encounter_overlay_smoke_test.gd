extends SceneTree

const OVERLAY_SCENE := preload(
	"res://scene/game_modes/rogue/encounter/rogue_encounter_overlay.tscn"
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
	_expect(
		overlay.transition_cover_audio.stream.resource_path
		== "res://resources/audio/ui/xiaocong_transition_cover.wav"
		and overlay.transition_reveal_audio.stream.resource_path
		== "res://resources/audio/ui/xiaocong_transition_reveal.wav"
		and overlay.transition_cover_audio.bus == &"SFX"
		and overlay.transition_reveal_audio.bus == &"SFX"
		and is_equal_approx(overlay.transition_cover_audio.volume_db, -8.0)
		and is_equal_approx(overlay.transition_reveal_audio.volume_db, -7.0),
		"神奇遭遇必须复用小葱转场的遮盖/揭示音效、总线与响度。"
	)
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
	_expect(
		overlay.transition_cover_audio.playing,
		"从肉鸽地图进入神奇遭遇时必须播放小葱遮盖音效。"
	)
	await overlay.reveal_encounter()
	_expect(
		overlay.transition_reveal_audio.playing,
		"神奇遭遇揭示时必须播放小葱揭示音效。"
	)
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
		overlay.choice_first.button.disabled
		and not overlay.choice_second.button.disabled,
		"木板不足时购买项应显示但禁用，0元购仍可选择。"
	)
	_expect(
		overlay.choice_first.title_label.text == "购买篮球"
		and overlay.choice_first.description_label.text
		== "花费10个木板购买一个篮球"
		and overlay.choice_second.description_label.text
		== "鸡哥有概率被你说服",
		"鸡哥两个选项必须使用精简后的标题与小字文案。"
	)
	_expect(
		not overlay.choice_third.visible,
		"鸡哥回归必须只显示两张选项卡，第三张静态卡不得残留。"
	)
	overlay.choice_second.button.emit_signal("pressed")
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
	overlay.transition_cover_audio.stop()
	overlay.transition_reveal_audio.stop()
	overlay.reveal_map_after_encounter()
	await process_frame
	_expect(
		overlay.transition_cover_audio.playing,
		"从神奇遭遇返回肉鸽地图时必须先播放小葱遮盖音效。"
	)
	await create_timer(
		RogueEncounterOverlay.COVER_DURATION_SECONDS + 0.04
	).timeout
	_expect(
		overlay.transition_reveal_audio.playing,
		"返回肉鸽地图的揭示阶段必须播放小葱揭示音效。"
	)
	await create_timer(
		RogueEncounterOverlay.REVEAL_DURATION_SECONDS + 0.06
	).timeout
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
	await _test_slime_content_three_choices_and_result_pages()
	await _test_ghost_shadow_presentation_and_results()
	await _test_personal_result_page_and_ack_request()
	await _test_suitcase_intro_results_and_immediate_exit()

	if failures.is_empty():
		print("ROGUE_ENCOUNTER_OVERLAY_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _make_intro_state() -> Dictionary:
	return {
		"schema_version": 4,
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
		"result_pages": [],
		"round_index": 0,
		"result_sequence": 0,
		"disabled_option_ids": [],
		"round_recipient_peer_ids": [],
		"result_ack_peer_ids": [],
		"terminal_result": false,
		"run_failed": false,
		"personal_result_pages": {},
	}


func _make_slime_intro_state() -> Dictionary:
	var state := _make_intro_state()
	state["node_id"] = 21
	state["node_content_seed"] = 77821
	state["occurrence_key"] = "21:77821"
	state["encounter_id"] = "slime_talkers"
	state["option_availability"] = {
		"help_slimes": true,
		"kick_slimes": true,
		"leave_slimes": true,
	}
	return state


func _make_suitcase_intro_state() -> Dictionary:
	var state := _make_intro_state()
	state["node_id"] = 31
	state["node_content_seed"] = 88331
	state["occurrence_key"] = "31:88331"
	state["encounter_id"] = "suitcase_frenzy"
	state["option_availability"] = {
		"claim_suitcase": true,
		"join_suitcase_shooting": true,
		"ignore_suitcase": true,
	}
	return state


func _make_ghost_state() -> Dictionary:
	return {
		"schema_version": 4,
		"revision": 1,
		"phase": "intro",
		"node_id": 81,
		"node_content_seed": 8181,
		"occurrence_key": "81:8181",
		"encounter_id": "ghost_shadow",
		"remaining_seconds": 60.0,
		"voting_timer_running": false,
		"participant_peer_ids": [81],
		"active_peer_ids": [81],
		"spectator_peer_ids": [],
		"intro_confirmed_peer_ids": [],
		"votes": [],
		"abstained_peer_ids": [],
		"option_availability": {
			"ghost_run_away": true,
			"ghost_who_are_you": true,
		},
		"winning_option": "",
		"economy_result": {},
		"result_text": "",
		"result_pages": [],
		"round_index": 0,
		"result_sequence": 0,
		"disabled_option_ids": [],
		"round_recipient_peer_ids": [],
		"result_ack_peer_ids": [],
		"terminal_result": false,
		"run_failed": false,
		"personal_result_pages": {},
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
		overlay.choice_first.button.has_focus()
		or overlay.choice_second.button.has_focus(),
		"重连或全量同步后直接进入选项页时，手柄必须获得可用选项焦点。"
	)
	# 覆盖层已经揭示后，也可能因修复性全量快照从对白页直接恢复到选项页。
	overlay.choice_first.button.release_focus()
	overlay.choice_second.button.release_focus()
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
			overlay.choice_first.button.has_focus()
			or overlay.choice_second.button.has_focus()
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


func _test_slime_content_three_choices_and_result_pages() -> void:
	var overlay := OVERLAY_SCENE.instantiate() as RogueEncounterOverlay
	root.add_child(overlay)
	overlay.configure_local_context(31, {31: "史莱姆访客"}, {})
	var intro := _make_slime_intro_state()
	intro["participant_peer_ids"] = [31]
	intro["active_peer_ids"] = [31]
	overlay.visible = true
	overlay.encounter_content.visible = true
	overlay.encounter_is_revealed = true
	overlay.apply_state(intro)
	_expect(
		overlay.rendered_encounter_id == RogueEncounterRegistry.SLIME_TALKERS
		and overlay.actor_name.text == "会说话的史莱姆"
		and not overlay.speaker_label.visible
		and overlay.dialogue_text.text.replace(
			DialogueTypewriterController.NO_BREAK_MARK,
			""
		) == "你遇到了一群会说话的史莱姆",
		"史莱姆开场必须使用群体身份和无说话者的旁白正文。"
	)
	overlay.typewriter.finish_line()
	var voting := intro.duplicate(true)
	voting["revision"] = 2
	voting["phase"] = "voting"
	voting["intro_confirmed_peer_ids"] = [31]
	overlay.apply_state(voting)
	_expect(
		overlay.choice_purchase.visible
		and overlay.choice_free.visible
		and overlay.choice_third.visible,
		"史莱姆选项页必须完整显示三张选项卡。"
	)
	_expect(
		overlay.choice_purchase.option_id
		== RogueEncounterRegistry.OPTION_HELP_SLIMES
		and overlay.choice_purchase.title_label.text == "给予一些帮助"
		and overlay.choice_purchase.description_label.text
		== "赠予这些史莱姆10个水瓶"
		and overlay.choice_free.option_id
		== RogueEncounterRegistry.OPTION_KICK_SLIMES
		and overlay.choice_free.title_label.text == "一脚踢死"
		and overlay.choice_free.description_label.text == "杀死这些史莱姆"
		and overlay.choice_third.option_id
		== RogueEncounterRegistry.OPTION_LEAVE_SLIMES
		and overlay.choice_third.title_label.text == "这和我有什么关系？"
		and overlay.choice_third.description_label.text == "离开该节点",
		"史莱姆三个选项的标题、小字和ID必须逐项匹配配置。"
	)
	var requested_options: Array[StringName] = []
	overlay.vote_requested.connect(
		func(_key: String, _revision: int, option_id: StringName) -> void:
			requested_options.append(option_id)
	)
	overlay.choice_third.button.emit_signal("pressed")
	_expect(
		requested_options == [RogueEncounterRegistry.OPTION_LEAVE_SLIMES],
		"第三张选项卡必须通过既有投票信号提交离开选项。"
	)
	for choice_card in overlay.choice_cards:
		choice_card.button.release_focus()
	var only_leave_available := voting.duplicate(true)
	only_leave_available["revision"] = 3
	only_leave_available["option_availability"] = {
		"help_slimes": false,
		"kick_slimes": false,
		"leave_slimes": true,
	}
	overlay.apply_state(only_leave_available)
	_expect(
		overlay.choice_purchase.button.disabled
		and overlay.choice_free.button.disabled
		and overlay.choice_third.button.has_focus(),
		"前两项不可用时，键盘和手柄焦点必须落到第三个可用选项。"
	)

	var chicken := _make_intro_state()
	chicken["node_id"] = 22
	chicken["node_content_seed"] = 77822
	chicken["occurrence_key"] = "22:77822"
	chicken["participant_peer_ids"] = [31]
	chicken["active_peer_ids"] = [31]
	chicken["intro_confirmed_peer_ids"] = [31]
	chicken["phase"] = "voting"
	overlay.apply_state(chicken)
	_expect(
		not overlay.choice_third.visible
		and overlay.choice_third.option_id.is_empty(),
		"从三选项史莱姆切换到鸡哥时必须清空并隐藏第三张卡。"
	)

	var result := _make_slime_intro_state()
	result["revision"] = 4
	result["phase"] = "result"
	result["participant_peer_ids"] = [31]
	result["active_peer_ids"] = [31]
	result["intro_confirmed_peer_ids"] = [31]
	result["result_pages"] = [
		{
			"speaker": "史莱姆",
			"text": "谢谢你，旅行者",
			"is_narration": false,
		},
		{
			"speaker": "",
			"text": "史莱姆回礼了你一些息壤水晶",
			"is_narration": true,
		},
	]
	var local_result_hold_count := [0]
	overlay.result_hold_completed.connect(
		func(_key: String, _revision: int) -> void:
			local_result_hold_count[0] += 1
	)
	overlay.apply_state(result)
	_expect(
		overlay.speaker_label.visible
		and overlay.speaker_label.text == "史莱姆"
		and overlay.dialogue_text.text.replace(
			DialogueTypewriterController.NO_BREAK_MARK,
			""
		) == "谢谢你，旅行者",
		"史莱姆结果第一页必须作为角色对白显示。"
	)
	var completed := result.duplicate(true)
	completed["revision"] = 5
	completed["phase"] = "completed"
	overlay.apply_state(completed)
	overlay.typewriter.finish_line()
	await create_timer(RogueEncounterOverlay.RESULT_PAGE_GAP_SECONDS + 0.08).timeout
	_expect(
		overlay.result_page_index == 1
		and not overlay.speaker_label.visible
		and overlay.dialogue_text.text.replace(
			DialogueTypewriterController.NO_BREAK_MARK,
			""
		) == "史莱姆回礼了你一些息壤水晶"
		and local_result_hold_count[0] == 0,
		"completed 快照不得跳过第二页旁白或提前请求退出。"
	)
	overlay.typewriter.finish_line()
	await create_timer(RogueEncounterOverlay.RESULT_HOLD_SECONDS + 0.08).timeout
	_expect(
		local_result_hold_count[0] == 1,
		"多页结果只能在最后一页完整显示并停留后请求退出。"
	)
	overlay.hide_immediately()
	overlay.free()


func _test_ghost_shadow_presentation_and_results() -> void:
	var overlay := OVERLAY_SCENE.instantiate() as RogueEncounterOverlay
	root.add_child(overlay)
	var local_vote_requests: Array[StringName] = []
	var local_hold_count := [0]
	overlay.vote_requested.connect(
		func(
			_key: String,
			_revision: int,
			option_id: StringName
		) -> void: local_vote_requests.append(option_id)
	)
	overlay.result_hold_completed.connect(
		func(_key: String, _revision: int) -> void: local_hold_count[0] += 1
	)
	overlay.configure_local_context(81, {81: "玩家"}, {})
	overlay.visible = true
	overlay.encounter_content.visible = true
	overlay.encounter_is_revealed = true
	overlay.apply_state(_make_ghost_state())
	_expect(
		overlay.encounter_name.text == "鬼影"
		and overlay.encounter_portrait.texture != null
		and overlay.encounter_portrait.texture.resource_path
		== "res://resources/texture/rogue_encounter/ghost_shadow.png"
		and not overlay.encounter_hint.visible,
		"鬼影事件必须展示专属左侧立绘与名称。"
	)
	_expect(
		not overlay.speaker.visible
		and overlay.dialogue_text.text.replace(
			DialogueTypewriterController.NO_BREAK_MARK,
			""
		) == "你遇到了一个鬼影",
		"鬼影开场必须作为非对话旁白显示。"
	)

	var voting := _make_ghost_state()
	voting["revision"] = 2
	voting["phase"] = "voting"
	voting["intro_confirmed_peer_ids"] = [81]
	overlay.apply_state(voting)
	_expect(
		overlay.choice_first.title_label.text == "逃跑"
		and overlay.choice_first.description_label.text
		== "鬼知道会发生什么，赶快逃"
		and overlay.choice_first.description_label.visible
		and overlay.choice_second.title_label.text == "你是？"
		and overlay.choice_second.description_label.text.is_empty()
		and not overlay.choice_second.description_label.visible,
		"鬼影选项必须使用指定文案，且“你是？”不能显示小字行。"
	)
	overlay.choice_second.button.emit_signal("pressed")
	_expect(
		local_vote_requests == [
			RogueEncounterRegistry.OPTION_GHOST_WHO_ARE_YOU
		],
		"鬼影第二项必须提交预留了特殊结果入口的独立option id。"
	)

	var flee_result := voting.duplicate(true)
	flee_result["revision"] = 3
	flee_result["phase"] = "result"
	flee_result["winning_option"] = "ghost_run_away"
	flee_result["result_pages"] = [{
		"speaker": "",
		"text": "处于安全考虑，逃跑了",
		"is_narration": true,
	}]
	overlay.apply_state(flee_result)
	overlay.typewriter.finish_line()
	_expect(
		overlay.dialogue_text.text.replace(
			DialogueTypewriterController.NO_BREAK_MARK,
			""
		) == "处于安全考虑，逃跑了"
		and not overlay.speaker.visible,
		"鬼影逃跑必须通过权威结果页展示旁白文字。"
	)

	var question_result := flee_result.duplicate(true)
	question_result["revision"] = 4
	question_result["winning_option"] = "ghost_who_are_you"
	question_result["result_pages"] = [{
		"speaker": "",
		"text": "鬼影什么也没有说，消失了",
		"is_narration": true,
	}]
	overlay.apply_state(question_result)
	overlay.typewriter.finish_line()
	_expect(
		overlay.dialogue_text.text.replace(
			DialogueTypewriterController.NO_BREAK_MARK,
			""
		) == "鬼影什么也没有说，消失了"
		and not overlay.speaker.visible
		and overlay.status_label.text == "鬼影已经离开",
		"鬼影询问身份必须通过权威结果页展示默认消失旁白。"
	)
	await create_timer(RogueEncounterOverlay.RESULT_HOLD_SECONDS + 0.08).timeout
	_expect(
		local_hold_count[0] == 1,
		"鬼影结果显示完成后必须沿用通用离场信号。"
	)
	overlay.hide_immediately()
	overlay.free()


func _test_personal_result_page_and_ack_request() -> void:
	var overlay := OVERLAY_SCENE.instantiate() as RogueEncounterOverlay
	root.add_child(overlay)
	overlay.configure_local_context(101, {101: "玩家一", 202: "玩家二"}, {})
	var ack_requests: Array[Dictionary] = []
	overlay.result_ack_requested.connect(
		func(key: String, sequence: int) -> void:
			ack_requests.append({"key": key, "sequence": sequence})
	)
	overlay.visible = true
	overlay.encounter_content.visible = true
	overlay.encounter_is_revealed = true
	var result := _make_intro_state()
	result["node_id"] = 101
	result["node_content_seed"] = 99101
	result["occurrence_key"] = "101:99101"
	result["encounter_id"] = "fluorescent_pit"
	result["participant_peer_ids"] = [101, 202]
	result["active_peer_ids"] = [101, 202]
	result["intro_confirmed_peer_ids"] = [101, 202]
	result["revision"] = 8
	result["phase"] = "result"
	result["result_sequence"] = 3
	result["round_recipient_peer_ids"] = [101, 202]
	result["result_pages"] = [{
		"speaker": "",
		"text": "捡到一个亮晶晶的物品",
		"is_narration": true,
	}]
	result["personal_result_pages"] = {
		101: [{
			"speaker": "",
			"text": "获得：测试收藏品（普通）",
			"is_narration": true,
		}],
		202: [{
			"speaker": "",
			"text": "背包已满，未获得：另一件收藏品（史诗）",
			"is_narration": true,
		}],
	}
	overlay.apply_state(result)
	_expect(
		overlay.result_pages.size() == 2
		and str(overlay.result_pages[1].get("text", ""))
		== "获得：测试收藏品（普通）",
		"结果页必须只拼接本地玩家的个人明细，不能泄露其他玩家页面。"
	)
	overlay.typewriter.finish_line()
	await create_timer(RogueEncounterOverlay.RESULT_PAGE_GAP_SECONDS + 0.08).timeout
	overlay.typewriter.finish_line()
	await create_timer(RogueEncounterOverlay.RESULT_HOLD_SECONDS + 0.08).timeout
	_expect(
		ack_requests == [{"key": "101:99101", "sequence": 3}],
		"通用页与本地个人页播放完并停留1.5秒后，应按结果序号恰好请求一次ACK。"
	)
	var replay := result.duplicate(true)
	replay["revision"] = 9
	replay["result_ack_peer_ids"] = [202]
	overlay.apply_state(replay)
	await create_timer(0.05).timeout
	_expect(
		ack_requests.size() == 1,
		"同一结果序号的ACK快照更新不得重复触发结果播放或ACK请求。"
	)
	overlay.hide_immediately()
	overlay.free()


func _test_suitcase_intro_results_and_immediate_exit() -> void:
	var overlay := OVERLAY_SCENE.instantiate() as RogueEncounterOverlay
	root.add_child(overlay)
	overlay.configure_local_context(1, {1: "玩家"}, {1: &""})
	var intro_acks: Array[Dictionary] = []
	var result_acks: Array[Dictionary] = []
	var hold_completions: Array[String] = []
	overlay.intro_ack_requested.connect(
		func(key: String, revision: int) -> void:
			intro_acks.append({"key": key, "revision": revision})
	)
	overlay.result_ack_requested.connect(
		func(key: String, sequence: int) -> void:
			result_acks.append({"key": key, "sequence": sequence})
	)
	overlay.result_hold_completed.connect(
		func(key: String, _revision: int) -> void:
			hold_completions.append(key)
	)
	overlay.visible = true
	overlay.encounter_content.visible = true
	overlay.encounter_is_revealed = true
	var intro := _make_suitcase_intro_state()
	overlay.apply_state(intro)
	_expect(
		overlay.intro_pages.size() == 2
		and overlay.intro_page_index == 0
		and overlay.dialogue_text.text.replace(
			DialogueTypewriterController.NO_BREAK_MARK,
			""
		) == "发现了一群失控的战斗机器人正在开枪疯穿箱子。",
		"疯穿箱子必须先显示第一段精确旁白。"
	)
	var confirm := InputEventAction.new()
	confirm.action = &"interact"
	confirm.pressed = true
	overlay.typewriter.finish_line()
	overlay._input(confirm)
	_expect(
		overlay.intro_page_index == 1
		and intro_acks.is_empty()
		and overlay.dialogue_text.text.replace(
			DialogueTypewriterController.NO_BREAK_MARK,
			""
		) == "也不知道这皮箱有什么特别的",
		"第一段读完后只能进入第二段，不得提前提交intro ACK。"
	)
	overlay.typewriter.finish_line()
	overlay._input(confirm)
	await create_timer(
		RogueEncounterOverlay.OPTION_REVEAL_DURATION_SECONDS + 0.08
	).timeout
	_expect(
		intro_acks == [{"key": "31:88331", "revision": 1}]
		and overlay.options_page.visible
		and overlay.choice_first.title_label.text == "箱子是我的！"
		and overlay.choice_first.description_label.text == "朝着机器人开火"
		and overlay.choice_second.title_label.text == "凑热闹！"
		and overlay.choice_second.description_label.text
		== "跟着一起射击皮箱！"
		and overlay.choice_third.title_label.text
		== "一个皮箱有什么好在意的！"
		and overlay.choice_third.description_label.text
		== "趁没被机器人发现前离开",
		"第二段读完后才可显示三张精确选项卡并提交一次ACK。"
	)

	var fight_result := intro.duplicate(true)
	fight_result["revision"] = 5
	fight_result["phase"] = "result"
	fight_result["intro_confirmed_peer_ids"] = [1]
	fight_result["winning_option"] = "claim_suitcase"
	fight_result["result_sequence"] = 1
	fight_result["round_recipient_peer_ids"] = [1]
	fight_result["terminal_result"] = true
	fight_result["result_pages"] = [{
		"speaker": "",
		"text": "机器人注意到了你！",
		"is_narration": true,
	}]
	fight_result["result_text"] = "机器人注意到了你！"
	fight_result["economy_result"] = {
		"resolved": true,
		"result_code": "suitcase_robots_alerted",
		"result_presentation": "pages",
		"followup_combat_id": "suitcase_battle",
	}
	overlay.apply_state(fight_result)
	overlay.typewriter.finish_line()
	await create_timer(RogueEncounterOverlay.RESULT_HOLD_SECONDS + 0.08).timeout
	_expect(
		result_acks == [{"key": "31:88331", "sequence": 1}]
		and hold_completions == ["31:88331"],
		"疯穿箱子开火结果必须复用结果序号ACK屏障并完成本地停留。"
	)

	var immediate := _make_suitcase_intro_state()
	immediate["node_id"] = 32
	immediate["node_content_seed"] = 88332
	immediate["occurrence_key"] = "32:88332"
	immediate["revision"] = 4
	immediate["phase"] = "completed"
	immediate["intro_confirmed_peer_ids"] = [1]
	immediate["winning_option"] = "ignore_suitcase"
	immediate["terminal_result"] = true
	immediate["result_pages"] = []
	immediate["result_text"] = ""
	immediate["economy_result"] = {
		"resolved": true,
		"result_code": "suitcase_left",
		"result_presentation": "immediate",
		"followup_combat_id": "",
	}
	overlay.apply_state(immediate)
	await process_frame
	_expect(
		hold_completions == ["31:88331", "32:88332"]
		and overlay.result_pages.is_empty()
		and not overlay.intro_page.visible
		and not overlay.options_page.visible,
		"安全离开必须不生成兜底结果文案，并立即请求关闭遭遇表现。"
	)
	overlay.apply_state(immediate)
	await process_frame
	_expect(
		hold_completions.size() == 2,
		"同一immediate完成快照重放不得重复请求关闭。"
	)
	overlay.hide_immediately()
	overlay.free()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
