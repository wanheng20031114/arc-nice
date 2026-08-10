extends CanvasLayer
class_name RogueRareChestOverlay

const RareChestRegistry = preload(
	"res://scene/game_modes/rogue/rare_chest/domain/rogue_rare_chest_registry.gd"
)
const PHASE_IDLE := &"idle"
const PHASE_CHOOSING := &"choosing"
const PHASE_WAITING := &"waiting"
const PHASE_COMPLETED := &"completed"

signal choice_requested(
	occurrence_key: String,
	expected_offer_revision: int,
	option_id: StringName
)

@onready var root: Control = $Root
@onready var main_row: HBoxContainer = $Root/ScreenMargin/MainRow
@onready var tableau: TextureRect = (
	$Root/ScreenMargin/MainRow/TableauStage/TableauFrame/TableauLayer/Tableau
)
@onready var title_label: Label = (
	$Root/ScreenMargin/MainRow/DecisionColumn/Header/Title
)
@onready var private_hint_label: Label = (
	$Root/ScreenMargin/MainRow/DecisionColumn/Header/PrivateHint
)
@onready var status_label: Label = (
	$Root/ScreenMargin/MainRow/DecisionColumn/Header/Status
)
@onready var choice_cards: Array[RogueRareChestChoiceCard] = [
	$Root/ScreenMargin/MainRow/DecisionColumn/ChoiceList/Choice0,
	$Root/ScreenMargin/MainRow/DecisionColumn/ChoiceList/Choice1,
	$Root/ScreenMargin/MainRow/DecisionColumn/ChoiceList/Choice2,
]
@onready var local_result_label: Label = (
	$Root/ScreenMargin/MainRow/DecisionColumn/Footer/LocalResult
)
@onready var waiting_list_label: Label = (
	$Root/ScreenMargin/MainRow/DecisionColumn/Footer/WaitingList
)

var local_peer_id := 0
var player_names: Dictionary = {}
var rendered_state: Dictionary = {}
var rendered_phase: StringName = PHASE_IDLE
var rendered_occurrence_key := ""
var rendered_offer_revision := 0
var rendered_local_selection: StringName = &""
var submission_pending := false
var show_tween: Tween = null


func _ready() -> void:
	for card in choice_cards:
		card.selected.connect(_on_option_selected)
	hide_rare_chest_immediately()


func configure_local_context(
	new_local_peer_id: int,
	new_player_names: Dictionary
) -> void:
	local_peer_id = new_local_peer_id
	player_names = new_player_names.duplicate(true)
	if not rendered_state.is_empty():
		_render_state()


func apply_state(state: Dictionary) -> void:
	var phase := StringName(state.get("phase", PHASE_IDLE))
	if phase == PHASE_IDLE:
		rendered_state.clear()
		hide_rare_chest_immediately()
		return
	var next_occurrence_key := str(state.get("occurrence_key", ""))
	var next_offer_revision := maxi(int(state.get("offer_revision", 0)), 0)
	var next_selection := StringName(
		state.get("local_selected_option_id", "")
	)
	if (
		next_occurrence_key != rendered_occurrence_key
		or next_offer_revision != rendered_offer_revision
		or not next_selection.is_empty()
	):
		submission_pending = false
	rendered_state = state.duplicate(true)
	rendered_phase = phase
	rendered_occurrence_key = next_occurrence_key
	rendered_offer_revision = next_offer_revision
	rendered_local_selection = next_selection
	show_rare_chest()
	_render_state()


func show_rare_chest() -> void:
	if visible:
		return
	visible = true
	root.mouse_filter = Control.MOUSE_FILTER_STOP
	_play_show_tween()


func hide_rare_chest_immediately() -> void:
	if show_tween != null:
		show_tween.kill()
		show_tween = null
	visible = false
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rendered_phase = PHASE_IDLE
	rendered_local_selection = &""
	submission_pending = false


func _render_state() -> void:
	if rendered_state.is_empty() or not visible:
		return
	title_label.text = "稀有宝箱"
	private_hint_label.text = "每位玩家独立选择 · 你的候选仅自己可见"
	var participant_peer_ids := _to_int_array(
		rendered_state.get("participant_peer_ids", [])
	)
	var active_peer_ids := _to_int_array(
		rendered_state.get("active_peer_ids", [])
	)
	var completed_peer_ids := _to_int_array(
		rendered_state.get("completed_peer_ids", [])
	)
	var local_participates := participant_peer_ids.has(local_peer_id)
	var local_is_active := active_peer_ids.has(local_peer_id)
	var option_ids := _to_string_name_array(
		rendered_state.get("local_option_ids", [])
	)
	var availability := (
		rendered_state.get("local_option_availability", {}) as Dictionary
	)
	var has_selection := not rendered_local_selection.is_empty()
	var local_can_select := (
		rendered_phase == PHASE_CHOOSING
		and local_participates
		and local_is_active
		and not has_selection
		and not submission_pending
	)
	for card_index in range(choice_cards.size()):
		var card := choice_cards[card_index]
		card.visible = card_index < option_ids.size()
		if not card.visible:
			continue
		var option_id := option_ids[card_index]
		var definition: Dictionary = (
			RareChestRegistry.get_option_definition(option_id)
		)
		if definition.is_empty():
			card.visible = false
			continue
		definition["option_id"] = option_id
		var disabled_reason := _get_disabled_reason(
			availability,
			option_id
		)
		card.configure(
			definition,
			card_index,
			local_can_select,
			disabled_reason
		)
		card.set_interaction_enabled(local_can_select)
		card.set_resolution_state(
			option_id == rendered_local_selection,
			has_selection
		)
	_render_status(
		participant_peer_ids,
		active_peer_ids,
		completed_peer_ids,
		local_participates,
		local_is_active,
		option_ids
	)
	_focus_first_available()


func _render_status(
	participant_peer_ids: Array[int],
	active_peer_ids: Array[int],
	completed_peer_ids: Array[int],
	local_participates: bool,
	local_is_active: bool,
	option_ids: Array[StringName]
) -> void:
	var pending_peer_ids: Array[int] = []
	for peer_id in active_peer_ids:
		if participant_peer_ids.has(peer_id) and not completed_peer_ids.has(peer_id):
			pending_peer_ids.append(peer_id)
	var effective_total := completed_peer_ids.size() + pending_peer_ids.size()
	var progress_text := "已完成 %d/%d" % [
		completed_peer_ids.size(),
		maxi(effective_total, 1),
	]
	if not local_participates:
		status_label.text = "旁观本次稀有宝箱选择 · %s" % progress_text
	elif rendered_phase == PHASE_COMPLETED:
		status_label.text = "所有玩家均已完成选择"
	elif not rendered_local_selection.is_empty():
		status_label.text = "选择已确认 · %s" % progress_text
	elif submission_pending:
		status_label.text = "正在等待主机确认……"
	elif not local_is_active:
		status_label.text = "当前无法提交选择"
	elif option_ids.size() != choice_cards.size():
		status_label.text = "正在等待主机生成个人候选……"
	else:
		status_label.text = "请选择一项永久增益 · %s" % progress_text

	var local_result_text := str(
		rendered_state.get("local_result_text", "")
	)
	local_result_label.visible = not local_result_text.is_empty()
	local_result_label.text = local_result_text
	if pending_peer_ids.is_empty():
		waiting_list_label.text = "所有有效玩家均已完成选择"
	else:
		var pending_names: Array[String] = []
		for peer_id in pending_peer_ids:
			pending_names.append(_get_player_name(peer_id))
		waiting_list_label.text = "等待：%s" % "、".join(pending_names)


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
		choice_cards[card_index].play_entrance(
			0.06 * card_index + 0.04
		)
	var entrance_tween := show_tween
	entrance_tween.finished.connect(func() -> void:
		if show_tween != entrance_tween:
			return
		show_tween = null
		_focus_first_available()
	)


func _on_option_selected(option_id: StringName) -> void:
	if (
		rendered_phase != PHASE_CHOOSING
		or rendered_occurrence_key.is_empty()
		or submission_pending
		or not rendered_local_selection.is_empty()
	):
		return
	var participant_peer_ids := _to_int_array(
		rendered_state.get("participant_peer_ids", [])
	)
	var active_peer_ids := _to_int_array(
		rendered_state.get("active_peer_ids", [])
	)
	if (
		not participant_peer_ids.has(local_peer_id)
		or not active_peer_ids.has(local_peer_id)
	):
		return
	var option_ids := _to_string_name_array(
		rendered_state.get("local_option_ids", [])
	)
	if not option_ids.has(option_id):
		return
	submission_pending = true
	_render_state()
	choice_requested.emit(
		rendered_occurrence_key,
		rendered_offer_revision,
		option_id
	)


func _focus_first_available() -> void:
	if not visible or show_tween != null:
		return
	for card in choice_cards:
		if (
			card.visible
			and not card.button.disabled
			and card.button.focus_mode != Control.FOCUS_NONE
		):
			card.button.grab_focus()
			return


func _get_disabled_reason(
	availability: Dictionary,
	option_id: StringName
) -> String:
	var raw_value: Variant = availability.get(
		String(option_id),
		availability.get(option_id, {})
	)
	if not (raw_value is Dictionary):
		return ""
	var entry := raw_value as Dictionary
	if bool(entry.get("available", true)):
		return ""
	return str(entry.get("disabled_reason", "当前条件不可用"))


func _get_player_name(peer_id: int) -> String:
	var player_name := str(
		player_names.get(peer_id, player_names.get(str(peer_id), ""))
	)
	return player_name if not player_name.is_empty() else "玩家%d" % peer_id


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
				RareChestRegistry.has_option(option_id)
				and not result.has(option_id)
			):
				result.append(option_id)
	return result
