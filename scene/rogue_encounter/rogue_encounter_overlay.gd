extends CanvasLayer
class_name RogueEncounterOverlay

signal intro_ack_requested(occurrence_key: String, expected_revision: int)
signal vote_requested(
	occurrence_key: String,
	expected_revision: int,
	option_id: StringName
)
signal encounter_revealed(occurrence_key: String, expected_revision: int)
signal result_hold_completed(occurrence_key: String, expected_revision: int)
signal encounter_hidden

const PHASE_IDLE := &"idle"
const PHASE_INTRO := &"intro"
const PHASE_VOTING := &"voting"
const PHASE_RESOLVING := &"resolving"
const PHASE_RESULT := &"result"
const PHASE_COMPLETED := &"completed"
const OPTION_PURCHASE := &"purchase_basketball"
const OPTION_FREE := &"ask_for_free"
const INTRO_TEXT := "鸡哥：练习时长2年半，会唱跳rap篮球。"
const COVER_DURATION_SECONDS := 0.32
const REVEAL_DURATION_SECONDS := 0.38
const OPTION_REVEAL_DURATION_SECONDS := 0.36
const RESULT_HOLD_SECONDS := 1.5
const BASKETBALL_TEXTURE := preload(
	"res://resources/texture/collectibles/basketball.png"
)

@onready var encounter_content: Control = %EncounterContent
@onready var decision_panel: NinePatchRect = %DecisionPanel
@onready var stage_label: Label = %StageLabel
@onready var status_label: Label = %StatusLabel
@onready var intro_page: VBoxContainer = %IntroPage
@onready var dialogue_text: RichTextLabel = %DialogueText
@onready var prompt_label: Label = %PromptLabel
@onready var options_page: VBoxContainer = %OptionsPage
@onready var choice_purchase: RogueEncounterChoiceCard = %ChoicePurchase
@onready var choice_free: RogueEncounterChoiceCard = %ChoiceFree
@onready var vote_status_label: Label = %VoteStatusLabel
@onready var option_back_buffer: BackBufferCopy = %OptionBackBuffer
@onready var option_reveal_cover: ColorRect = %OptionRevealCover
@onready var transition_cover: ColorRect = %TransitionCover
@onready var typewriter: DialogueTypewriterController = %Typewriter
@onready var blip_audio: AudioStreamPlayer = %BlipAudio
@onready var transition_cover_audio: AudioStreamPlayer = %TransitionCoverAudio
@onready var transition_reveal_audio: AudioStreamPlayer = %TransitionRevealAudio

var local_peer_id := 0
var player_names_by_peer: Dictionary = {}
var character_ids_by_peer: Dictionary = {}
var state: Dictionary = {}
var occurrence_key := ""
var expected_revision := 0
var rendered_phase: StringName = PHASE_IDLE
var rendered_line := ""
var local_intro_advanced := false
var pending_intro_revision := -1
var encounter_is_revealed := false
var option_transition_active := false
var transition_tween: Tween = null
var option_tween: Tween = null
var result_hold_serial := 0
var revealed_occurrence_key := ""


func _ready() -> void:
	typewriter.configure(dialogue_text, blip_audio)
	typewriter.line_finished.connect(_on_typewriter_line_finished)
	choice_purchase.selected.connect(_on_option_selected)
	choice_free.selected.connect(_on_option_selected)
	var group := ButtonGroup.new()
	group.allow_unpress = false
	choice_purchase.button.button_group = group
	choice_free.button.button_group = group
	_set_transition_progress(0.0)
	_set_option_reveal_progress(1.0)
	hide_immediately()


func configure_local_context(
	peer_id: int,
	player_names: Dictionary,
	character_ids: Dictionary
) -> void:
	local_peer_id = peer_id
	player_names_by_peer = player_names.duplicate(true)
	character_ids_by_peer = character_ids.duplicate(true)
	if encounter_is_revealed:
		_render_state(false)


func apply_state(new_state: Dictionary) -> void:
	state = new_state.duplicate(true)
	var new_occurrence_key := str(state.get("occurrence_key", ""))
	if new_occurrence_key != occurrence_key:
		occurrence_key = new_occurrence_key
		revealed_occurrence_key = ""
		local_intro_advanced = false
		pending_intro_revision = -1
		rendered_line = ""
		rendered_phase = PHASE_IDLE
		result_hold_serial += 1
	expected_revision = int(state.get("revision", 0))
	var authoritative_intro := _local_intro_is_authoritatively_confirmed()
	if authoritative_intro:
		local_intro_advanced = true
		pending_intro_revision = -1
	elif (
		pending_intro_revision >= 0
		and expected_revision > pending_intro_revision
	):
		# 请求落后于权威 revision 时服务端会回送最新快照。撤销本地乐观态，
		# 让玩家重新确认，而不是留在一个永远无法提交投票的假选项页。
		local_intro_advanced = false
		pending_intro_revision = -1
	if encounter_is_revealed:
		_render_state(false)


func cover_map_for_encounter() -> void:
	_stop_transition_tween()
	visible = true
	encounter_content.visible = false
	encounter_is_revealed = false
	transition_cover.visible = true
	transition_cover.mouse_filter = Control.MOUSE_FILTER_STOP
	_set_transition_progress(0.0)
	transition_cover_audio.play()
	var tween := create_tween()
	transition_tween = tween
	tween.tween_method(
		_set_transition_progress,
		0.0,
		1.0,
		COVER_DURATION_SECONDS
	).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	await tween.finished
	if transition_tween != tween:
		return
	transition_tween = null
	_set_transition_progress(1.0)


func reveal_encounter() -> void:
	_stop_transition_tween()
	visible = true
	encounter_content.visible = true
	encounter_is_revealed = true
	transition_cover.visible = true
	transition_cover.mouse_filter = Control.MOUSE_FILTER_STOP
	_set_transition_progress(1.0)
	_render_state(true)
	transition_reveal_audio.play()
	var tween := create_tween()
	transition_tween = tween
	tween.tween_method(
		_set_transition_progress,
		1.0,
		0.0,
		REVEAL_DURATION_SECONDS
	).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	await tween.finished
	if transition_tween != tween:
		return
	transition_tween = null
	_set_transition_progress(0.0)
	transition_cover.visible = false
	transition_cover.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if occurrence_key.is_empty() or revealed_occurrence_key == occurrence_key:
		return
	revealed_occurrence_key = occurrence_key
	if options_page.visible:
		_focus_first_available_option()
	encounter_revealed.emit(occurrence_key, expected_revision)


func reveal_map_after_encounter() -> void:
	if not visible:
		encounter_hidden.emit()
		return
	_stop_transition_tween()
	_stop_option_tween()
	result_hold_serial += 1
	transition_cover.visible = true
	transition_cover.mouse_filter = Control.MOUSE_FILTER_STOP
	_set_transition_progress(0.0)
	transition_cover_audio.play()
	var tween := create_tween()
	transition_tween = tween
	tween.tween_method(
		_set_transition_progress,
		0.0,
		1.0,
		COVER_DURATION_SECONDS
	).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	await tween.finished
	if transition_tween != tween:
		return
	encounter_content.visible = false
	transition_reveal_audio.play()
	tween = create_tween()
	transition_tween = tween
	tween.tween_method(
		_set_transition_progress,
		1.0,
		0.0,
		REVEAL_DURATION_SECONDS
	).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	await tween.finished
	if transition_tween != tween:
		return
	transition_tween = null
	hide_immediately()
	encounter_hidden.emit()


func hide_immediately() -> void:
	_stop_transition_tween()
	_stop_option_tween()
	result_hold_serial += 1
	revealed_occurrence_key = ""
	visible = false
	encounter_content.visible = false
	encounter_is_revealed = false
	transition_cover.visible = false
	transition_cover.mouse_filter = Control.MOUSE_FILTER_IGNORE
	option_back_buffer.visible = false
	option_reveal_cover.visible = false
	typewriter.clear()


func _input(event: InputEvent) -> void:
	if (
		not visible
		or not encounter_is_revealed
		or transition_cover.visible
		or option_transition_active
	):
		return
	if event is InputEventKey and (event as InputEventKey).echo:
		return
	if not _local_can_participate() or _local_intro_page_is_advanced():
		return
	var is_mouse_confirm: bool = false
	if event is InputEventMouseButton:
		var mouse_event := event as InputEventMouseButton
		is_mouse_confirm = (
			mouse_event.button_index == MOUSE_BUTTON_LEFT
			and mouse_event.pressed
		)
	if not (
		event.is_action_pressed(&"interact")
		or event.is_action_pressed(&"ui_accept")
		or is_mouse_confirm
	):
		return
	get_viewport().set_input_as_handled()
	if typewriter.is_revealing():
		typewriter.finish_line()
		return
	local_intro_advanced = true
	pending_intro_revision = expected_revision
	_play_option_reveal()
	intro_ack_requested.emit(occurrence_key, expected_revision)


func _render_state(force: bool) -> void:
	var phase := StringName(state.get("phase", PHASE_IDLE))
	if phase == PHASE_IDLE:
		return
	rendered_phase = phase
	if phase == PHASE_RESULT or phase == PHASE_COMPLETED:
		_show_result(force)
		return
	if phase == PHASE_RESOLVING:
		_show_dialogue_page("鸡哥正在盘算……", false, force)
		status_label.text = "结算中"
		return
	if _local_intro_page_is_advanced() or not _local_can_participate():
		_show_options_page()
	else:
		_show_dialogue_page(INTRO_TEXT, true, force)
	_update_vote_state()


func _show_dialogue_page(
	line: String,
	show_prompt: bool,
	force: bool
) -> void:
	_stop_option_tween()
	intro_page.visible = true
	options_page.visible = false
	prompt_label.visible = show_prompt
	stage_label.text = "鸡哥"
	if show_prompt:
		status_label.text = "先听他说完，再作决定"
	if force or rendered_line != line:
		rendered_line = line
		typewriter.say(line)


func _show_options_page() -> void:
	intro_page.visible = false
	options_page.visible = true
	stage_label.text = "做出选择"
	_render_choice_cards()
	# 全量同步可能绕过本地选项揭示动画，直接把已确认对白的玩家放进
	# 选项页。此处补齐焦点，同时由 helper 保留玩家已选中的焦点。
	_focus_first_available_option()


func _play_option_reveal() -> void:
	if option_transition_active or not encounter_is_revealed:
		return
	option_transition_active = true
	option_back_buffer.visible = true
	option_reveal_cover.visible = true
	option_reveal_cover.mouse_filter = Control.MOUSE_FILTER_STOP
	_set_option_reveal_progress(0.0)
	await get_tree().process_frame
	if not is_inside_tree() or not visible:
		option_transition_active = false
		return
	_show_options_page()
	var tween := create_tween()
	option_tween = tween
	tween.tween_method(
		_set_option_reveal_progress,
		0.0,
		1.0,
		OPTION_REVEAL_DURATION_SECONDS
	).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	await tween.finished
	if option_tween != tween:
		return
	option_tween = null
	option_transition_active = false
	option_back_buffer.visible = false
	option_reveal_cover.visible = false
	option_reveal_cover.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_focus_first_available_option()


func _show_result(force: bool) -> void:
	var result_text := str(state.get("result_text", ""))
	if result_text.is_empty():
		result_text = _fallback_result_text()
	_show_dialogue_page(result_text, false, force)
	stage_label.text = "遭遇结果"
	status_label.text = "鸡哥已经作出回应"


func _render_choice_cards() -> void:
	var availability := state.get("option_availability", {}) as Dictionary
	var purchase_enabled := bool(
		_dict_value(availability, "purchase_basketball", false)
	)
	var free_enabled := bool(_dict_value(availability, "ask_for_free", true))
	var local_enabled := (
		_local_can_participate()
		and _local_intro_is_authoritatively_confirmed()
	)
	choice_purchase.configure(
		OPTION_PURCHASE,
		0,
		"花费10个木板购买一个篮球",
		(
			"优先从共享仓库支付，余额由玩家背包补足。"
			if purchase_enabled
			else "全队木板不足10个，当前无法购买。"
		),
		BASKETBALL_TEXTURE,
		not purchase_enabled or not local_enabled
	)
	choice_free.configure(
		OPTION_FREE,
		1,
		"为什么不能0元购？",
		"鸡哥有50%的概率被你说服。",
		null,
		not free_enabled or not local_enabled
	)
	choice_purchase.set_interaction_enabled(local_enabled and purchase_enabled)
	choice_free.set_interaction_enabled(local_enabled and free_enabled)
	var local_vote := _get_vote_for_peer(local_peer_id)
	choice_purchase.set_selected(local_vote == OPTION_PURCHASE)
	choice_free.set_selected(local_vote == OPTION_FREE)
	choice_purchase.set_voters(
		_get_voters_for_option(OPTION_PURCHASE),
		character_ids_by_peer
	)
	choice_free.set_voters(
		_get_voters_for_option(OPTION_FREE),
		character_ids_by_peer
	)


func _update_vote_state() -> void:
	var phase := StringName(state.get("phase", PHASE_IDLE))
	var active_peers := _active_peer_ids()
	var votes_count := _active_votes().size()
	var abstained_count := 0
	for peer_id in _to_int_array(state.get("abstained_peer_ids", [])):
		if active_peers.has(peer_id):
			abstained_count += 1
	var remaining := ceili(float(state.get("remaining_seconds", 0.0)))
	if not _local_can_participate():
		status_label.text = "本轮旁观 · 可查看实时投票"
	elif local_intro_advanced and not _local_intro_is_authoritatively_confirmed():
		status_label.text = "正在同步个人选项……"
	elif phase == PHASE_INTRO and not _local_intro_page_is_advanced():
		status_label.text = "先听他说完，再作决定"
	else:
		status_label.text = "等待所有玩家决定 · 剩余 %d 秒" % remaining
	vote_status_label.text = "已投票 %d/%d" % [votes_count, active_peers.size()]
	if abstained_count > 0:
		vote_status_label.text += " · 弃票 %d" % abstained_count


func _on_option_selected(option_id: StringName) -> void:
	if (
		not _local_can_participate()
		or not _local_intro_is_authoritatively_confirmed()
	):
		return
	choice_purchase.set_selected(option_id == OPTION_PURCHASE)
	choice_free.set_selected(option_id == OPTION_FREE)
	vote_requested.emit(occurrence_key, expected_revision, option_id)


func _on_typewriter_line_finished() -> void:
	# completed 是房主已完成权威结算，不代表这个客户端也已读完结果。
	# 高延迟客户端继续完成自己的逐字显示与 1.5 秒停留，再通知外层退出。
	if rendered_phase not in [PHASE_RESULT, PHASE_COMPLETED] or rendered_line.is_empty():
		return
	result_hold_serial += 1
	var serial := result_hold_serial
	var timer := get_tree().create_timer(RESULT_HOLD_SECONDS)
	await timer.timeout
	if (
		serial != result_hold_serial
		or not visible
		or rendered_phase not in [PHASE_RESULT, PHASE_COMPLETED]
	):
		return
	result_hold_completed.emit(occurrence_key, expected_revision)


func _fallback_result_text() -> String:
	var economy := state.get("economy_result", {}) as Dictionary
	var result_code := str(economy.get("result_code", ""))
	if result_code == "all_inventories_full":
		return "所有玩家背包均已满，交易未完成。"
	if bool(economy.get("reward_granted", false)):
		if bool(economy.get("free_purchase_success", false)):
			return "鸡哥：好吧，那就送你了。"
		return "鸡哥：一手交钱，一手交球。"
	if StringName(state.get("winning_option", &"")) == OPTION_FREE:
		return "鸡哥：哪有什么好的事情。"
	return "鸡哥结束了这次交易。"


func _local_intro_page_is_advanced() -> bool:
	return local_intro_advanced or _local_intro_is_authoritatively_confirmed()


func _local_intro_is_authoritatively_confirmed() -> bool:
	return _to_int_array(
		state.get("intro_confirmed_peer_ids", [])
	).has(local_peer_id)


func _local_can_participate() -> bool:
	return _active_peer_ids().has(local_peer_id)


func _active_peer_ids() -> Array[int]:
	var active := _to_int_array(state.get("active_peer_ids", []))
	if active.is_empty():
		active = _to_int_array(state.get("participant_peer_ids", []))
	return active


func _all_votes() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var raw_votes: Variant = state.get("votes", [])
	if raw_votes is Array:
		for entry in raw_votes:
			if entry is Dictionary:
				result.append((entry as Dictionary).duplicate(true))
	elif raw_votes is Dictionary:
		for peer_key in raw_votes:
			result.append({
				"peer_id": int(peer_key),
				"option_id": StringName(raw_votes[peer_key]),
			})
	return result


func _get_vote_for_peer(peer_id: int) -> StringName:
	for vote in _all_votes():
		if int(vote.get("peer_id", -1)) == peer_id:
			return StringName(vote.get("option_id", &""))
	return &""


func _get_voters_for_option(option_id: StringName) -> Array[int]:
	var voters: Array[int] = []
	for vote in _active_votes():
		if StringName(vote.get("option_id", &"")) == option_id:
			voters.append(int(vote.get("peer_id", -1)))
	voters.sort()
	return voters


func _active_votes() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var active_peers := _active_peer_ids()
	for vote in _all_votes():
		if active_peers.has(int(vote.get("peer_id", -1))):
			result.append(vote)
	return result


func _focus_first_available_option() -> void:
	if (
		not encounter_is_revealed
		or transition_cover.visible
		or option_transition_active
		or not _local_can_participate()
	):
		return
	if (
		choice_purchase.button.has_focus()
		or choice_free.button.has_focus()
	):
		return
	if not choice_purchase.button.disabled:
		choice_purchase.button.grab_focus()
	elif not choice_free.button.disabled:
		choice_free.button.grab_focus()


func _dict_value(mapping: Dictionary, key: String, default: Variant) -> Variant:
	if mapping.has(key):
		return mapping[key]
	var string_name_key := StringName(key)
	if mapping.has(string_name_key):
		return mapping[string_name_key]
	return default


func _to_int_array(value: Variant) -> Array[int]:
	var result: Array[int] = []
	if value is Array or value is PackedInt32Array:
		for entry in value:
			result.append(int(entry))
	return result


func _stop_transition_tween() -> void:
	if transition_tween == null:
		return
	transition_tween.kill()
	transition_tween = null


func _stop_option_tween() -> void:
	if option_tween != null:
		option_tween.kill()
		option_tween = null
	option_transition_active = false
	option_back_buffer.visible = false
	option_reveal_cover.visible = false


func _set_transition_progress(progress: float) -> void:
	transition_cover.set_instance_shader_parameter(
		&"cover_progress",
		clampf(progress, 0.0, 1.0)
	)


func _set_option_reveal_progress(progress: float) -> void:
	option_reveal_cover.set_instance_shader_parameter(
		&"reveal_progress",
		clampf(progress, 0.0, 1.0)
	)
