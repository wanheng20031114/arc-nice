extends CanvasLayer
class_name XiaocongFateChoiceOverlay

const DEFAULT_CANVAS_LAYER := 24
const INVENTORY_ACCESS_CANVAS_LAYER := 19
const ENTRANCE_REVEAL_DURATION_SECONDS := 0.36
const RETURN_TO_ROOM_DURATION_SECONDS := 0.32
const XIAOCONG_PORTRAIT_POSITION := Vector2.ZERO

signal choice_submitted(option_id: StringName, permanent_buff_id: StringName)
signal collectible_submitted(choice_index: int)

@onready var title_label: Label = (
	$Root/ScreenMargin/MainRow/DecisionColumn/Header/Title
)
@onready var status_label: Label = (
	$Root/ScreenMargin/MainRow/DecisionColumn/Header/Status
)
@onready var main_row: HBoxContainer = $Root/ScreenMargin/MainRow
@onready var choice_list: VBoxContainer = (
	$Root/ScreenMargin/MainRow/DecisionColumn/ChoiceList
)
@onready var xiaocong_sprite: TextureRect = (
	$Root/ScreenMargin/MainRow/PortraitStage/PortraitFrame/Xiaocong
)
@onready var entrance_back_buffer: BackBufferCopy = $Root/EntranceBackBuffer
@onready var entrance_reveal_cover: ColorRect = $Root/EntranceRevealCover
@onready var buff_modal: CenterContainer = $Root/BuffModal
@onready var buff_buttons: Array[Button] = [
	$Root/BuffModal/Panel/Margin/Content/Buff0,
	$Root/BuffModal/Panel/Margin/Content/Buff1,
	$Root/BuffModal/Panel/Margin/Content/Buff2,
]
@onready var buff_cancel_button: Button = (
	$Root/BuffModal/Panel/Margin/Content/Cancel
)
@onready var collectible_panel: PanelContainer = $Root/CollectibleCenter/Panel
@onready var collectible_status: Label = (
	$Root/CollectibleCenter/Panel/Margin/Content/Status
)
@onready var collectible_buttons: Array[Button] = [
	$Root/CollectibleCenter/Panel/Margin/Content/Choices/Choice0,
	$Root/CollectibleCenter/Panel/Margin/Content/Choices/Choice1,
	$Root/CollectibleCenter/Panel/Margin/Content/Choices/Choice2,
	$Root/CollectibleCenter/Panel/Margin/Content/Choices/Choice3,
]

var choice_cards: Array[XiaocongFateChoiceCard] = []
var choice_button_group := ButtonGroup.new()
var available_option_ids: Array[StringName] = []
var permanent_buff_offer: Array[StringName] = []
var local_peer_id := 0
var rendered_local_vote: StringName = &""
var show_tween: Tween = null
var rendered_stage: StringName = &""


func _ready() -> void:
	choice_button_group.allow_unpress = false
	for child in choice_list.get_children():
		var card := child as XiaocongFateChoiceCard
		if card == null:
			continue
		choice_cards.append(card)
		card.button.button_group = choice_button_group
		card.selected.connect(_on_card_selected)
	for button_index in range(buff_buttons.size()):
		buff_buttons[button_index].pressed.connect(
			_on_buff_selected.bind(button_index)
		)
	buff_cancel_button.pressed.connect(_on_buff_cancelled)
	for button_index in range(collectible_buttons.size()):
		collectible_buttons[button_index].pressed.connect(
			_on_collectible_selected.bind(button_index)
		)
	hide_overlay()


func apply_state(
	state: Dictionary,
	new_local_peer_id: int,
	character_ids_by_peer: Dictionary
) -> void:
	local_peer_id = new_local_peer_id
	if not bool(state.get("active", false)):
		hide_overlay()
		return
	var day_number := maxi(int(state.get("completed_day", 1)), 1)
	title_label.text = "第 %d 日已经通过 · 决定命运" % day_number
	var stage := StringName(
		state.get(
			"stage",
			TowerDefenseFateManager.STAGE_WAIT_INTERACTIONS
		)
	)
	if stage == TowerDefenseFateManager.STAGE_WAIT_INTERACTIONS:
		hide_overlay()
		return
	if stage not in [
		TowerDefenseFateManager.STAGE_VOTING,
		TowerDefenseFateManager.STAGE_RESOLVING,
		TowerDefenseFateManager.STAGE_RESOLVED,
		TowerDefenseFateManager.STAGE_COLLECTIBLE_REWARD,
	]:
		hide_overlay()
		return
	var should_animate := not visible
	visible = true
	rendered_stage = stage
	_set_inventory_access_mode(false)
	var eligible_peers := _to_int_array(state.get("eligible_peer_ids", []))
	available_option_ids = _to_option_id_array(
		state.get("available_option_ids", [])
	)
	permanent_buff_offer = _to_buff_id_array(
		state.get("permanent_buff_offer", [])
	)
	choice_list.visible = stage in [
		TowerDefenseFateManager.STAGE_VOTING,
		TowerDefenseFateManager.STAGE_RESOLVING,
		TowerDefenseFateManager.STAGE_RESOLVED,
	]
	collectible_panel.visible = (
		stage == TowerDefenseFateManager.STAGE_COLLECTIBLE_REWARD
	)
	if stage == TowerDefenseFateManager.STAGE_VOTING:
		_apply_vote_state(state, eligible_peers, character_ids_by_peer)
	elif stage == TowerDefenseFateManager.STAGE_COLLECTIBLE_REWARD:
		_apply_collectible_state(state, eligible_peers)
		_hide_buff_modal()
	elif stage == TowerDefenseFateManager.STAGE_RESOLVING:
		_apply_resolution_state(state, character_ids_by_peer, false)
		_hide_buff_modal()
	elif stage == TowerDefenseFateManager.STAGE_RESOLVED:
		_apply_resolution_state(state, character_ids_by_peer, true)
		_hide_buff_modal()
	if should_animate:
		_play_show_tween()


func hide_overlay() -> void:
	if show_tween != null:
		show_tween.kill()
		show_tween = null
	_set_entrance_reveal_progress(1.0)
	entrance_back_buffer.visible = false
	entrance_reveal_cover.visible = false
	visible = false
	rendered_stage = &""
	rendered_local_vote = &""
	_set_inventory_access_mode(false)
	buff_modal.visible = false
	collectible_panel.visible = false


func play_return_to_room() -> void:
	if not visible:
		return
	if show_tween != null:
		show_tween.kill()
		show_tween = null
	get_viewport().gui_release_focus()
	_hide_buff_modal()
	collectible_panel.visible = false
	entrance_back_buffer.visible = true
	entrance_reveal_cover.visible = true
	_set_entrance_reveal_progress(1.0)
	var return_tween := create_tween()
	show_tween = return_tween
	return_tween.tween_method(
		_set_entrance_reveal_progress,
		1.0,
		0.0,
		RETURN_TO_ROOM_DURATION_SECONDS
	).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	await return_tween.finished
	if show_tween != return_tween:
		return
	show_tween = null
	hide_overlay()


func _apply_vote_state(
	state: Dictionary,
	eligible_peers: Array[int],
	character_ids_by_peer: Dictionary
) -> void:
	var votes := state.get("votes", {}) as Dictionary
	rendered_local_vote = StringName(votes.get(local_peer_id, ""))
	var local_is_eligible := eligible_peers.has(local_peer_id)
	var recovery_available := bool(
		state.get("timeout_recovery_available", false)
	)
	var local_is_host := int(state.get("host_peer_id", -1)) == local_peer_id
	if local_is_eligible:
		status_label.text = (
			"已投票 %d/%d · 可重新选择，全部完成后由多数票决定"
			% [votes.size(), eligible_peers.size()]
		)
		if recovery_available:
			status_label.text += (
				" · 等待超时，按 F 继续结算"
				if local_is_host
				else " · 等待房主继续结算"
			)
		else:
			status_label.text += " · 剩余 %d 秒" % ceili(
				float(state.get("stage_time_remaining", 0.0))
			)
	else:
		status_label.text = "本日旁观 · 不参与本次命运选择"
		_hide_buff_modal()
	for card_index in range(choice_cards.size()):
		var card := choice_cards[card_index]
		card.visible = card_index < available_option_ids.size()
		if not card.visible:
			continue
		var option_id := available_option_ids[card_index]
		var option_config := TowerDefenseFateRegistry.get_option_config(option_id)
		if option_config == null:
			card.visible = false
			continue
		var voters := _voters_for_option(votes, option_id)
		var disabled := not local_is_eligible
		card.configure(option_config, card_index, disabled)
		card.set_interaction_enabled(
			not disabled and not buff_modal.visible
		)
		card.set_resolution_state(false, false)
		card.set_selected(rendered_local_vote == option_id)
		card.set_voters(voters, character_ids_by_peer)


func _apply_collectible_state(
	state: Dictionary,
	eligible_peers: Array[int]
) -> void:
	var offers_by_peer := state.get("collectible_offers", {}) as Dictionary
	var offer_paths := offers_by_peer.get(local_peer_id, []) as Array
	var claimed_peers := _to_int_array(
		state.get("collectible_claimed_peer_ids", [])
	)
	var is_claimed := claimed_peers.has(local_peer_id)
	var local_is_eligible := eligible_peers.has(local_peer_id)
	var statuses := state.get("collectible_status_by_peer", {}) as Dictionary
	var local_status := str(statuses.get(local_peer_id, "请选择一件收藏品"))
	var inventory_is_full := (
		local_is_eligible
		and not is_claimed
		and local_status.contains("背包已满")
	)
	_set_inventory_access_mode(inventory_is_full)
	status_label.text = (
		"命运已选定：每名玩家获得一次收藏品选择"
		if local_is_eligible
		else "本日旁观 · 等待参与玩家完成收藏品选择"
	)
	if not local_is_eligible:
		collectible_status.text = "你不参与本日奖励结算"
	elif is_claimed:
		collectible_status.text = "你的收藏品已经放入背包 · 等待其他玩家"
	elif inventory_is_full:
		collectible_status.text = (
			"背包已满 · 按背包键清出一个空位后，再次选择收藏品"
		)
	else:
		collectible_status.text = local_status
	for button_index in range(collectible_buttons.size()):
		var button := collectible_buttons[button_index]
		button.visible = button_index < offer_paths.size()
		button.disabled = is_claimed or not local_is_eligible
		button.icon = null
		if not button.visible:
			continue
		var item := LuoxiMerchant.get_collectible_for_path(
			str(offer_paths[button_index])
		)
		if item == null:
			button.text = "无效选项"
			button.disabled = true
			continue
		button.text = "%s\n%s" % [item.display_name, item.description]
		button.icon = item.icon_texture


func _apply_resolution_state(
	state: Dictionary,
	character_ids_by_peer: Dictionary,
	is_complete: bool
) -> void:
	var winning_option := StringName(state.get("winning_option_id", ""))
	var winning_buff := StringName(
		state.get("winning_permanent_buff_id", "")
	)
	var option_config := TowerDefenseFateRegistry.get_option_config(
		winning_option
	)
	var buff_config := TowerDefenseFateRegistry.get_permanent_buff_config(
		winning_buff
	)
	var status_prefix := "命运已决定" if is_complete else "正在兑现命运"
	var resolution_status := "%s：%s" % [
		status_prefix,
		option_config.display_name if option_config != null else "未知命运",
	]
	if buff_config != null:
		resolution_status += " · %s" % buff_config.description
	var pending_stone_peers := _to_int_array(
		state.get("pending_stone_peer_ids", [])
	)
	var local_stone_pending := (
		not is_complete
		and winning_option == TowerDefenseFateRegistry.OPTION_FATE_STONE
		and pending_stone_peers.has(local_peer_id)
	)
	_set_inventory_access_mode(local_stone_pending)
	if local_stone_pending:
		status_label.text = (
			"背包已满 · 按背包键打开背包并丢弃一件可删除物品；"
			+ "腾出空位后将自动获得神秘核心石"
		)
	elif (
		not is_complete
		and winning_option == TowerDefenseFateRegistry.OPTION_FATE_STONE
		and not pending_stone_peers.is_empty()
	):
		status_label.text = (
			"等待 %d 名玩家为神秘核心石腾出背包空位"
			% pending_stone_peers.size()
		)
	else:
		status_label.text = resolution_status
	var votes := state.get("votes", {}) as Dictionary
	for card_index in range(choice_cards.size()):
		var card := choice_cards[card_index]
		card.visible = card_index < available_option_ids.size()
		if not card.visible:
			continue
		var option_id := available_option_ids[card_index]
		var card_config := TowerDefenseFateRegistry.get_option_config(option_id)
		if card_config == null:
			card.visible = false
			continue
		card.configure(card_config, card_index, false)
		card.set_interaction_enabled(false)
		card.set_selected(option_id == winning_option)
		card.set_resolution_state(option_id == winning_option, true)
		card.set_voters(
			_voters_for_option(votes, option_id),
			character_ids_by_peer
		)


func _set_inventory_access_mode(enabled: bool) -> void:
	layer = (
		INVENTORY_ACCESS_CANVAS_LAYER
		if enabled
		else DEFAULT_CANVAS_LAYER
	)
	$Root.mouse_filter = (
		Control.MOUSE_FILTER_IGNORE
		if enabled
		else Control.MOUSE_FILTER_STOP
	)


func _on_card_selected(option_id: StringName) -> void:
	if rendered_stage != TowerDefenseFateManager.STAGE_VOTING:
		return
	if option_id == TowerDefenseFateRegistry.OPTION_PERMANENT_CONTRACT:
		if permanent_buff_offer.is_empty():
			_restore_vote_selection()
			return
		_show_buff_modal()
		return
	rendered_local_vote = option_id
	_restore_vote_selection()
	choice_submitted.emit(option_id, &"")


func _show_buff_modal() -> void:
	buff_modal.visible = true
	for card in choice_cards:
		card.set_interaction_enabled(false)
	for button_index in range(buff_buttons.size()):
		var button := buff_buttons[button_index]
		button.visible = button_index < permanent_buff_offer.size()
		if not button.visible:
			continue
		var buff_config := TowerDefenseFateRegistry.get_permanent_buff_config(
			permanent_buff_offer[button_index]
		)
		button.text = (
			buff_config.description
			if buff_config != null
			else "未知增益"
		)
	for button in buff_buttons:
		if button.visible and not button.disabled:
			button.grab_focus()
			break


func _hide_buff_modal() -> void:
	buff_modal.visible = false
	if rendered_stage == TowerDefenseFateManager.STAGE_VOTING:
		for card in choice_cards:
			card.set_interaction_enabled(
				card.visible and not card.button.disabled
			)


func _on_buff_cancelled() -> void:
	_hide_buff_modal()
	_restore_vote_selection()
	_focus_selected_card()


func _on_buff_selected(button_index: int) -> void:
	if (
		rendered_stage != TowerDefenseFateManager.STAGE_VOTING
		or not buff_modal.visible
		or button_index < 0
		or button_index >= permanent_buff_offer.size()
	):
		return
	var buff_id := permanent_buff_offer[button_index]
	rendered_local_vote = TowerDefenseFateRegistry.OPTION_PERMANENT_CONTRACT
	_hide_buff_modal()
	_restore_vote_selection()
	choice_submitted.emit(
		TowerDefenseFateRegistry.OPTION_PERMANENT_CONTRACT,
		buff_id
	)


func _on_collectible_selected(choice_index: int) -> void:
	collectible_submitted.emit(choice_index)


func _play_show_tween() -> void:
	if show_tween != null:
		return
	get_viewport().gui_release_focus()
	entrance_back_buffer.visible = true
	entrance_reveal_cover.visible = true
	_set_entrance_reveal_progress(0.0)
	main_row.modulate = Color.WHITE
	xiaocong_sprite.position = (
		XIAOCONG_PORTRAIT_POSITION + Vector2(0, 14)
	)
	var entrance_tween := create_tween().set_parallel(true)
	show_tween = entrance_tween
	entrance_tween.tween_method(
		_set_entrance_reveal_progress,
		0.0,
		1.0,
		ENTRANCE_REVEAL_DURATION_SECONDS
	).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	entrance_tween.tween_property(
		xiaocong_sprite,
		"position",
		XIAOCONG_PORTRAIT_POSITION,
		0.32
	).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	for card_index in range(choice_cards.size()):
		if choice_cards[card_index].visible:
			choice_cards[card_index].play_entrance(
				0.07 * card_index + 0.05
			)
	entrance_tween.finished.connect(func() -> void:
		if show_tween != entrance_tween:
			return
		_set_entrance_reveal_progress(1.0)
		entrance_back_buffer.visible = false
		entrance_reveal_cover.visible = false
		show_tween = null
		_focus_active_action()
	)


func _set_entrance_reveal_progress(progress: float) -> void:
	entrance_reveal_cover.set_instance_shader_parameter(
		&"reveal_progress",
		clampf(progress, 0.0, 1.0)
	)


func _focus_active_action() -> void:
	if not visible:
		return
	if buff_modal.visible:
		for button in buff_buttons:
			if button.visible and not button.disabled:
				button.grab_focus()
				return
	if rendered_stage == TowerDefenseFateManager.STAGE_VOTING:
		_focus_selected_card()
		return
	if rendered_stage == TowerDefenseFateManager.STAGE_COLLECTIBLE_REWARD:
		for button in collectible_buttons:
			if button.visible and not button.disabled:
				button.grab_focus()
				return


func _restore_vote_selection() -> void:
	for card in choice_cards:
		card.set_selected(
			card.visible and card.option_id == rendered_local_vote
		)


func _focus_selected_card() -> void:
	for card in choice_cards:
		if card.visible and card.option_id == rendered_local_vote:
			card.button.grab_focus()
			return
	for card in choice_cards:
		if card.visible and not card.button.disabled:
			card.button.grab_focus()
			return


func _voters_for_option(
	votes: Dictionary,
	option_id: StringName
) -> Array[int]:
	var voters: Array[int] = []
	for peer_variant in votes:
		if StringName(votes[peer_variant]) == option_id:
			voters.append(int(peer_variant))
	voters.sort()
	return voters


func _to_int_array(value: Variant) -> Array[int]:
	var result: Array[int] = []
	if value is Array or value is PackedInt32Array:
		for entry in value:
			result.append(int(entry))
	return result


func _to_option_id_array(value: Variant) -> Array[StringName]:
	var result: Array[StringName] = []
	if value is Array or value is PackedStringArray:
		for entry in value:
			var config := (
				TowerDefenseFateRegistry.get_option_config_by_wire_id(
					str(entry)
				)
			)
			if config != null and not result.has(config.option_id):
				result.append(config.option_id)
	return result


func _to_buff_id_array(value: Variant) -> Array[StringName]:
	var result: Array[StringName] = []
	if value is Array or value is PackedStringArray:
		for entry in value:
			var config := (
				TowerDefenseFateRegistry.get_permanent_buff_config_by_wire_id(
					str(entry)
				)
			)
			if config != null and not result.has(config.buff_id):
				result.append(config.buff_id)
	return result
