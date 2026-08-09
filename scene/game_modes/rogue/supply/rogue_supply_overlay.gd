extends CanvasLayer
class_name RogueSupplyOverlay

const PHASE_IDLE := &"idle"
const PHASE_INTRO := &"intro"
const PHASE_VOTING := &"voting"
const PHASE_COLLECTIBLE_CHOICE := &"collectible_choice"
const PHASE_RESULT := &"result"
const PHASE_COMPLETED := &"completed"
const RESULT_AUTO_COMPLETE_SECONDS := 2.4

signal intro_ack_requested(occurrence_key: String, expected_revision: int)
signal vote_requested(
	occurrence_key: String,
	expected_revision: int,
	option_id: StringName
)
signal collectible_choice_requested(
	occurrence_key: String,
	expected_revision: int,
	offer_index: int
)
signal completed_requested(occurrence_key: String, expected_revision: int)
signal inventory_requested()

@onready var root: Control = $Root
@onready var global_shade: ColorRect = $Root/Shade
@onready var ambient_top: ColorRect = $Root/AmbientTop
@onready var screen_margin: MarginContainer = $Root/ScreenMargin
@onready var main_row: HBoxContainer = $Root/ScreenMargin/MainRow
@onready var tableau: TextureRect = (
	$Root/ScreenMargin/MainRow/TableauStage/TableauFrame/TableauLayer/Tableau
)
@onready var title_label: Label = (
	$Root/ScreenMargin/MainRow/DecisionColumn/Header/Title
)
@onready var shared_hint_label: Label = (
	$Root/ScreenMargin/MainRow/DecisionColumn/Header/SharedHint
)
@onready var status_label: Label = (
	$Root/ScreenMargin/MainRow/DecisionColumn/Header/Status
)
@onready var choice_cards: Array[RogueSupplyChoiceCard] = [
	$Root/ScreenMargin/MainRow/DecisionColumn/ChoiceList/Choice0,
	$Root/ScreenMargin/MainRow/DecisionColumn/ChoiceList/Choice1,
	$Root/ScreenMargin/MainRow/DecisionColumn/ChoiceList/Choice2,
]
@onready var result_text: Label = (
	$Root/ScreenMargin/MainRow/DecisionColumn/ResultFooter/ResultText
)
@onready var result_button: Button = (
	$Root/ScreenMargin/MainRow/DecisionColumn/ResultFooter/CompleteButton
)
@onready var collectible_modal: Control = $Root/CollectibleModal
@onready var collectible_panel: RogueSupplyCollectibleChoicePanel = (
	$Root/CollectibleModal/Center/CollectibleChoicePanel
)
@onready var result_auto_complete_timer: Timer = $ResultAutoCompleteTimer

var local_peer_id := 0
var player_names: Dictionary = {}
var character_ids: Dictionary = {}
var rendered_state: Dictionary = {}
var rendered_phase: StringName = PHASE_IDLE
var rendered_occurrence_key := ""
var rendered_revision := 0
var rendered_local_vote: StringName = &""
var show_tween: Tween = null
var intro_ack_reservation := ""
var completed_reservation := ""


func _ready() -> void:
	var choice_group := ButtonGroup.new()
	choice_group.allow_unpress = false
	for card in choice_cards:
		card.button.button_group = choice_group
		card.selected.connect(_on_option_selected)
	collectible_panel.choice_selected.connect(_on_collectible_selected)
	collectible_panel.inventory_requested.connect(_on_inventory_requested)
	result_button.pressed.connect(_request_completed)
	result_auto_complete_timer.timeout.connect(_request_completed)
	hide_supply_immediately()


func configure_local_context(
	new_local_peer_id: int,
	new_player_names: Dictionary,
	new_character_ids: Dictionary
) -> void:
	local_peer_id = new_local_peer_id
	player_names = new_player_names.duplicate(true)
	character_ids = new_character_ids.duplicate(true)
	if not rendered_state.is_empty():
		_render_state()


func apply_state(state: Dictionary) -> void:
	var phase := StringName(state.get("phase", PHASE_IDLE))
	if phase == PHASE_IDLE:
		rendered_state.clear()
		hide_supply_immediately()
		return
	rendered_state = state.duplicate(true)
	rendered_phase = phase
	rendered_occurrence_key = str(state.get("occurrence_key", ""))
	rendered_revision = maxi(int(state.get("revision", 0)), 0)
	show_supply()
	_render_state()


func show_supply() -> void:
	if visible:
		return
	visible = true
	root.mouse_filter = Control.MOUSE_FILTER_STOP
	_play_show_tween()


func hide_supply_immediately() -> void:
	if show_tween != null:
		show_tween.kill()
		show_tween = null
	result_auto_complete_timer.stop()
	collectible_modal.visible = false
	collectible_panel.hide_panel()
	visible = false
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rendered_phase = PHASE_IDLE
	rendered_local_vote = &""


func _render_state() -> void:
	if rendered_state.is_empty() or not visible:
		return
	title_label.text = "遗址物资"
	shared_hint_label.text = "共同清点物资 · 每位玩家的选择都会显示在卡片上"
	var participant_peer_ids := _to_int_array(
		rendered_state.get("participant_peer_ids", [])
	)
	var active_peer_ids := _to_int_array(
		rendered_state.get("active_peer_ids", [])
	)
	var local_participates := participant_peer_ids.has(local_peer_id)
	var local_is_active := active_peer_ids.has(local_peer_id)
	var local_offer_paths := _get_local_collectible_offer_paths()
	var local_has_pending_collectible := not local_offer_paths.is_empty()
	var pending_only := (
		rendered_phase == PHASE_COMPLETED
		and local_has_pending_collectible
	)
	global_shade.visible = not pending_only
	ambient_top.visible = not pending_only
	screen_margin.visible = not pending_only
	root.mouse_filter = (
		Control.MOUSE_FILTER_IGNORE
		if pending_only
		else Control.MOUSE_FILTER_STOP
	)
	var votes := _votes_to_dictionary(rendered_state.get("votes", []))
	for raw_peer_id in votes.keys():
		if not active_peer_ids.has(int(raw_peer_id)):
			votes.erase(raw_peer_id)
	rendered_local_vote = StringName(votes.get(local_peer_id, ""))
	var option_ids := _to_string_name_array(
		rendered_state.get("option_ids", [])
	)
	var option_availability := (
		rendered_state.get("option_availability", {}) as Dictionary
	)
	var light_stone_amount := maxi(
		int(rendered_state.get("light_stone_amount", 0)),
		0
	)
	var winning_option := StringName(
		rendered_state.get("winning_option", "")
	)
	var resolution_active := rendered_phase in [
		PHASE_COLLECTIBLE_CHOICE,
		PHASE_RESULT,
		PHASE_COMPLETED,
	]
	for card_index in range(choice_cards.size()):
		var card := choice_cards[card_index]
		card.visible = card_index < option_ids.size()
		if not card.visible:
			continue
		var option_id := option_ids[card_index]
		var definition := RogueSupplyRegistry.get_option_definition(option_id)
		if definition.is_empty():
			card.visible = false
			continue
		definition["option_id"] = option_id
		definition["available"] = _is_option_available(
			option_availability,
			option_id
		)
		if not bool(definition["available"]):
			definition["disabled_reason"] = "当前条件不足"
		var local_can_vote := (
			rendered_phase == PHASE_VOTING
			and local_participates
			and local_is_active
		)
		card.configure(
			definition,
			card_index,
			light_stone_amount,
			local_can_vote
		)
		card.set_selected(
			option_id == winning_option
			if resolution_active
			else option_id == rendered_local_vote
		)
		card.set_interaction_enabled(local_can_vote)
		card.set_resolution_state(
			option_id == winning_option,
			resolution_active
		)
		card.set_voters(
			_voters_for_option(votes, option_id),
			character_ids,
			player_names
		)

	result_text.visible = rendered_phase in [PHASE_RESULT, PHASE_COMPLETED]
	result_button.visible = rendered_phase == PHASE_RESULT and local_is_active
	result_button.disabled = false
	collectible_modal.visible = local_has_pending_collectible
	if collectible_modal.visible:
		_render_collectible_choice(
			local_participates,
			local_is_active,
			local_offer_paths
		)
	else:
		collectible_panel.hide_panel()
	_render_status(
		participant_peer_ids,
		active_peer_ids,
		votes,
		local_participates
	)
	if rendered_phase == PHASE_RESULT:
		_start_result_auto_complete(local_is_active)
	else:
		result_auto_complete_timer.stop()
	if rendered_phase in [PHASE_INTRO, PHASE_VOTING]:
		_schedule_intro_ack()
	_focus_active_control()


func _render_status(
	_participant_peer_ids: Array[int],
	active_peer_ids: Array[int],
	votes: Dictionary,
	local_participates: bool
) -> void:
	var remaining_seconds := maxi(
		ceili(float(rendered_state.get("remaining_seconds", 0.0))),
		0
	)
	match rendered_phase:
		PHASE_INTRO:
			status_label.text = (
				"发现一处尚未清空的物资点，正在确认全队状态…… %d秒"
				% remaining_seconds
			)
		PHASE_VOTING:
			if not local_participates:
				status_label.text = "旁观本次物资选择"
			elif not active_peer_ids.has(local_peer_id):
				status_label.text = "等待重连 · 当前无法提交选择"
			else:
				status_label.text = "已选择 %d/%d · 可重新选择 · 剩余%d秒" % [
					votes.size(),
					active_peer_ids.size(),
					remaining_seconds,
				]
		PHASE_COLLECTIBLE_CHOICE:
			status_label.text = "珍藏补给已选定 · 每名玩家独立选择一件收藏品"
		PHASE_RESULT:
			status_label.text = "物资已完成分配"
			result_text.text = _get_local_result_text()
			result_button.text = "确认离开"
		PHASE_COMPLETED:
			status_label.text = "全队已完成本次物资清点"
			result_text.text = _get_local_result_text()
		_:
			status_label.text = "同步物资状态中……"


func _render_collectible_choice(
	local_participates: bool,
	_local_is_active: bool,
	offer_paths: Array
) -> void:
	var claimed_peer_ids := _to_int_array(
		rendered_state.get("claimed_peer_ids", [])
	)
	var local_claimed := claimed_peer_ids.has(local_peer_id)
	var status_text := _get_local_personal_message()
	if status_text.is_empty():
		if not offer_paths.is_empty():
			status_text = "请选择其中一件收藏品"
		elif local_claimed:
			status_text = "收藏品已放入背包 · 等待其他玩家"
		elif not local_participates:
			status_text = "你不参与本次收藏品分配"
		elif offer_paths.is_empty():
			status_text = "正在等待主机生成个人候选"
	var enabled := (
		not local_claimed
		and offer_paths.size() == 3
	)
	collectible_panel.show_choices(
		offer_paths,
		status_text,
		enabled,
		not offer_paths.is_empty() and not local_claimed,
		not offer_paths.is_empty() and not local_claimed
	)


func _play_show_tween() -> void:
	if show_tween != null:
		return
	get_viewport().gui_release_focus()
	main_row.modulate = Color(1, 1, 1, 0)
	tableau.position = Vector2(-26, 0)
	show_tween = create_tween().set_parallel(true)
	show_tween.tween_property(main_row, "modulate", Color.WHITE, 0.24)
	show_tween.tween_property(
		tableau,
		"position",
		Vector2.ZERO,
		0.34
	).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	show_tween.tween_interval(0.52)
	for card_index in range(choice_cards.size()):
		choice_cards[card_index].play_entrance(0.06 * card_index + 0.04)
	var entrance_tween := show_tween
	entrance_tween.finished.connect(func() -> void:
		if show_tween != entrance_tween:
			return
		show_tween = null
		_maybe_emit_intro_ack()
		_focus_active_control()
	)


func _schedule_intro_ack() -> void:
	if show_tween != null:
		return
	call_deferred("_maybe_emit_intro_ack")


func _maybe_emit_intro_ack() -> void:
	if (
		rendered_phase not in [PHASE_INTRO, PHASE_VOTING]
		or rendered_occurrence_key.is_empty()
	):
		return
	var confirmed_peer_ids := _to_int_array(
		rendered_state.get("intro_confirmed_peer_ids", [])
	)
	var active_peer_ids := _to_int_array(
		rendered_state.get("active_peer_ids", [])
	)
	if (
		confirmed_peer_ids.has(local_peer_id)
		or not active_peer_ids.has(local_peer_id)
	):
		return
	var reservation := "%s|%d" % [
		rendered_occurrence_key,
		rendered_revision,
	]
	if intro_ack_reservation == reservation:
		return
	intro_ack_reservation = reservation
	intro_ack_requested.emit(rendered_occurrence_key, rendered_revision)


func _start_result_auto_complete(local_is_active: bool) -> void:
	if not local_is_active or _local_result_already_acknowledged():
		result_auto_complete_timer.stop()
		result_button.disabled = true
		return
	result_button.disabled = false
	if result_auto_complete_timer.is_stopped():
		result_auto_complete_timer.start(RESULT_AUTO_COMPLETE_SECONDS)


func _request_completed() -> void:
	if (
		rendered_phase != PHASE_RESULT
		or rendered_occurrence_key.is_empty()
		or _local_result_already_acknowledged()
	):
		return
	var reservation := "%s|%d" % [
		rendered_occurrence_key,
		rendered_revision,
	]
	if completed_reservation == reservation:
		return
	completed_reservation = reservation
	result_auto_complete_timer.stop()
	result_button.disabled = true
	completed_requested.emit(rendered_occurrence_key, rendered_revision)


func _on_option_selected(option_id: StringName) -> void:
	if rendered_phase != PHASE_VOTING or rendered_occurrence_key.is_empty():
		return
	rendered_local_vote = option_id
	for card in choice_cards:
		card.set_selected(card.visible and card.option_id == option_id)
	vote_requested.emit(
		rendered_occurrence_key,
		rendered_revision,
		option_id
	)


func _on_collectible_selected(offer_index: int) -> void:
	var offer_occurrence_key := _get_local_collectible_offer_occurrence()
	if (
		offer_occurrence_key.is_empty()
		or _get_local_collectible_offer_paths().is_empty()
	):
		return
	collectible_panel.set_pending(true, "正在等待主机确认收藏品……")
	collectible_choice_requested.emit(
		offer_occurrence_key,
		rendered_revision,
		offer_index
	)


func _on_inventory_requested() -> void:
	if not _get_local_collectible_offer_paths().is_empty():
		inventory_requested.emit()


func _focus_active_control() -> void:
	if not visible:
		return
	if collectible_modal.visible:
		collectible_panel.focus_first_available()
		return
	if result_button.visible and not result_button.disabled:
		result_button.grab_focus()
		return
	for card in choice_cards:
		if (
			card.visible
			and card.option_id == rendered_local_vote
			and not card.button.disabled
			and card.button.focus_mode != Control.FOCUS_NONE
		):
			card.button.grab_focus()
			return
	for card in choice_cards:
		if (
			card.visible
			and not card.button.disabled
			and card.button.focus_mode != Control.FOCUS_NONE
		):
			card.button.grab_focus()
			return


func _get_local_collectible_offer_paths() -> Array:
	for raw_offer_value in rendered_state.get("collectible_offers", []) as Array:
		if typeof(raw_offer_value) != TYPE_DICTIONARY:
			continue
		var offer := raw_offer_value as Dictionary
		if int(offer.get("peer_id", -1)) == local_peer_id:
			return (offer.get("paths", []) as Array).duplicate()
	return []


func _get_local_collectible_offer_occurrence() -> String:
	for raw_offer_value in rendered_state.get("collectible_offers", []) as Array:
		if typeof(raw_offer_value) != TYPE_DICTIONARY:
			continue
		var offer := raw_offer_value as Dictionary
		if int(offer.get("peer_id", -1)) == local_peer_id:
			return str(offer.get("occurrence_key", ""))
	return ""


func _get_local_personal_message() -> String:
	for raw_message_value in rendered_state.get("personal_messages", []) as Array:
		if typeof(raw_message_value) != TYPE_DICTIONARY:
			continue
		var message := raw_message_value as Dictionary
		if int(message.get("peer_id", -1)) == local_peer_id:
			return str(message.get("message", ""))
	return ""


func _get_local_result_text() -> String:
	var global_result := str(rendered_state.get("result_text", ""))
	var personal_result := _get_local_personal_message()
	if global_result.is_empty():
		return personal_result if not personal_result.is_empty() else "物资已完成分配"
	if personal_result.is_empty() or personal_result == global_result:
		return global_result
	return "%s\n%s" % [global_result, personal_result]


func _local_result_already_acknowledged() -> bool:
	return _to_int_array(
		rendered_state.get("result_ack_peer_ids", [])
	).has(local_peer_id)


func _is_option_available(
	availability: Dictionary,
	option_id: StringName
) -> bool:
	if availability.has(option_id):
		return bool(availability[option_id])
	var wire_id := String(option_id)
	return bool(availability.get(wire_id, false))


func _votes_to_dictionary(value: Variant) -> Dictionary:
	var result: Dictionary = {}
	if not (value is Array):
		return result
	for raw_vote_value in value:
		if typeof(raw_vote_value) != TYPE_DICTIONARY:
			continue
		var vote := raw_vote_value as Dictionary
		var peer_id := int(vote.get("peer_id", -1))
		var option_id := StringName(vote.get("option_id", ""))
		if peer_id >= 0 and RogueSupplyRegistry.has_option(option_id):
			result[peer_id] = option_id
	return result


func _voters_for_option(
	votes: Dictionary,
	option_id: StringName
) -> Array[int]:
	var voters: Array[int] = []
	for raw_peer_id in votes.keys():
		if StringName(votes[raw_peer_id]) == option_id:
			voters.append(int(raw_peer_id))
	voters.sort()
	return voters


func _to_int_array(value: Variant) -> Array[int]:
	var result: Array[int] = []
	if value is Array or value is PackedInt32Array:
		for entry in value:
			var peer_id := int(entry)
			if peer_id >= 0 and not result.has(peer_id):
				result.append(peer_id)
	result.sort()
	return result


func _to_string_name_array(value: Variant) -> Array[StringName]:
	var result: Array[StringName] = []
	if value is Array or value is PackedStringArray:
		for entry in value:
			var option_id := StringName(entry)
			if (
				RogueSupplyRegistry.has_option(option_id)
				and not result.has(option_id)
			):
				result.append(option_id)
	return result
