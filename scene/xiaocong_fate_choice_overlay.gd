extends CanvasLayer
class_name XiaocongFateChoiceOverlay

const STAGE_WAIT_INTERACTIONS := &"wait_interactions"
const STAGE_VOTING := &"voting"
const STAGE_RESOLVING := &"resolving"
const STAGE_RESOLVED := &"resolved"
const STAGE_COLLECTIBLE_REWARD := &"collectible_reward"
const FATE_STONE_ICON := preload("res://resources/texture/xiaocong_fate_stone.png")
const DEFAULT_CANVAS_LAYER := 24
const INVENTORY_ACCESS_CANVAS_LAYER := 19

const OPTION_TITLES := [
	"永久增益 · 精英契约",
	"重铸基地核心",
	"全员收藏品选择",
	"小葱展示了？？？",
	"息壤馈赠",
	"缩短冲刺冷却",
	"提升生命上限",
	"濒危核心 · 全局增益",
	"清空息壤 · 次日双倍掉落",
	"危险的疾行",
]

const OPTION_DESCRIPTIONS := [
	"从本次展示的 3 项永久增益中选择 1 项；下一日更容易出现精英敌人。",
	"基地最大生命值提升 50 点，并立刻恢复至上限。",
	"每名玩家分别获得一次收藏品选择。",
	"每名玩家的背包获得不可移动、不可删除的神秘核心石。",
	"所有玩家获得 8000 息壤。",
	"所有玩家的冲刺冷却时间永久减少 0.4 秒。",
	"所有玩家的生命值上限永久增加 20%。",
	"基地当前生命值降至 1 点（上限不变），获得一项尚未生效的全局增益。",
	"清空所有玩家持有的息壤；下一日敌人掉落的息壤数量翻倍。",
	"所有玩家移动速度增加 30%；受伤后速度降至基础值的 20%，持续 1 秒。",
]

const PERMANENT_BUFF_TEXT := {
	1: "战斗中所有建筑每秒恢复 10 点生命值",
	2: "源石虫的攻击力降低 35%",
	3: "人工造物的物理防御降低 50%",
	4: "玩家每秒恢复 5% 最大生命值",
	5: "史莱姆的移动速度降低 40%",
	6: "所有敌人的生命值上限降低 10%",
	7: "所有敌人的移动速度降低 20%",
	8: "洛曦每轮展示 4 个可选收藏品",
	9: "玩家生命值低于 25% 时，受到的伤害减少 80%",
}

signal choice_submitted(option_index: int, permanent_buff_id: int)
signal collectible_submitted(choice_index: int)

@onready var title_label: Label = $Root/Center/Panel/Margin/Content/Header/Title
@onready var status_label: Label = $Root/Center/Panel/Margin/Content/Header/Status
@onready var choice_scroll: ScrollContainer = $Root/Center/Panel/Margin/Content/ChoiceScroll
@onready var choice_grid: GridContainer = $Root/Center/Panel/Margin/Content/ChoiceScroll/ChoiceGrid
@onready var buff_panel: PanelContainer = $Root/BuffModal/Panel
@onready var buff_buttons: Array[Button] = [
	$Root/BuffModal/Panel/Margin/Content/Buff0,
	$Root/BuffModal/Panel/Margin/Content/Buff1,
	$Root/BuffModal/Panel/Margin/Content/Buff2,
]
@onready var buff_cancel_button: Button = $Root/BuffModal/Panel/Margin/Content/Cancel
@onready var collectible_panel: PanelContainer = $Root/CollectibleCenter/Panel
@onready var collectible_status: Label = $Root/CollectibleCenter/Panel/Margin/Content/Status
@onready var collectible_buttons: Array[Button] = [
	$Root/CollectibleCenter/Panel/Margin/Content/Choices/Choice0,
	$Root/CollectibleCenter/Panel/Margin/Content/Choices/Choice1,
	$Root/CollectibleCenter/Panel/Margin/Content/Choices/Choice2,
	$Root/CollectibleCenter/Panel/Margin/Content/Choices/Choice3,
]

var choice_cards: Array[XiaocongFateChoiceCard] = []
var permanent_buff_offer: Array[int] = []
var local_peer_id := 0
var show_tween: Tween = null
var rendered_stage: StringName = &""


func _ready() -> void:
	for child in choice_grid.get_children():
		var card := child as XiaocongFateChoiceCard
		if card == null:
			continue
		choice_cards.append(card)
		card.selected.connect(_on_card_selected)
	for card_index in range(choice_cards.size()):
		choice_cards[card_index].configure(
			OPTION_TITLES[card_index],
			OPTION_DESCRIPTIONS[card_index],
			FATE_STONE_ICON if card_index == 3 else null
		)
	for button_index in range(buff_buttons.size()):
		buff_buttons[button_index].pressed.connect(
			_on_buff_selected.bind(button_index)
		)
	buff_cancel_button.pressed.connect(_hide_buff_modal)
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
	title_label.text = "第 %d 日已经通过 · 决定接下来的命运" % day_number
	var stage := StringName(state.get("stage", STAGE_WAIT_INTERACTIONS))
	if stage == STAGE_WAIT_INTERACTIONS:
		hide_overlay()
		return
	if stage not in [
		STAGE_VOTING,
		STAGE_RESOLVING,
		STAGE_RESOLVED,
		STAGE_COLLECTIBLE_REWARD,
	]:
		hide_overlay()
		return
	var should_animate := not visible or rendered_stage != stage
	visible = true
	rendered_stage = stage
	_set_inventory_access_mode(false)
	var eligible_peers := _to_int_array(state.get("eligible_peer_ids", []))
	permanent_buff_offer = _to_int_array(state.get("permanent_buff_offer", []))
	choice_scroll.visible = stage in [STAGE_VOTING, STAGE_RESOLVING, STAGE_RESOLVED]
	collectible_panel.visible = stage == STAGE_COLLECTIBLE_REWARD
	if stage == STAGE_VOTING:
		_apply_vote_state(state, eligible_peers, character_ids_by_peer)
	elif stage == STAGE_COLLECTIBLE_REWARD:
		_apply_collectible_state(state, eligible_peers)
		_hide_buff_modal()
	elif stage == STAGE_RESOLVING:
		_apply_resolution_state(state, character_ids_by_peer, false)
		_hide_buff_modal()
	elif stage == STAGE_RESOLVED:
		_apply_resolution_state(state, character_ids_by_peer, true)
		_hide_buff_modal()
	if should_animate:
		_play_show_tween()


func hide_overlay() -> void:
	if show_tween != null:
		show_tween.kill()
		show_tween = null
	visible = false
	rendered_stage = &""
	_set_inventory_access_mode(false)
	buff_panel.visible = false
	collectible_panel.visible = false


func _apply_vote_state(
	state: Dictionary,
	eligible_peers: Array[int],
	character_ids_by_peer: Dictionary
) -> void:
	var votes := state.get("votes", {}) as Dictionary
	var local_vote := int(votes.get(local_peer_id, -1))
	var available_buff_count := int(state.get("available_permanent_buff_count", 0))
	var local_is_eligible := eligible_peers.has(local_peer_id)
	if local_is_eligible:
		status_label.text = "已投票 %d/%d · 可重新选择，全部完成后由多数票决定" % [
			votes.size(),
			eligible_peers.size(),
		]
	else:
		status_label.text = "本日旁观 · 不参与本次命运选择"
		_hide_buff_modal()
	for card_index in range(choice_cards.size()):
		var voters: Array[int] = []
		for peer_variant in votes:
			var peer_id := int(peer_variant)
			if int(votes[peer_variant]) == card_index:
				voters.append(peer_id)
		voters.sort()
		var disabled := (
			not local_is_eligible
			or (available_buff_count <= 0 and card_index in [0, 7])
		)
		choice_cards[card_index].configure(
			OPTION_TITLES[card_index],
			OPTION_DESCRIPTIONS[card_index],
			FATE_STONE_ICON if card_index == 3 else null,
			disabled
		)
		choice_cards[card_index].set_selected(local_vote == card_index)
		choice_cards[card_index].set_voters(voters, character_ids_by_peer)


func _apply_collectible_state(state: Dictionary, eligible_peers: Array[int]) -> void:
	var offers_by_peer := state.get("collectible_offers", {}) as Dictionary
	var offer_paths := offers_by_peer.get(local_peer_id, []) as Array
	var claimed_peers := _to_int_array(state.get("collectible_claimed_peer_ids", []))
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
		collectible_status.text = "背包已满 · 按背包键清出一个空位后，再次选择收藏品"
	else:
		collectible_status.text = local_status
	for button_index in range(collectible_buttons.size()):
		var button := collectible_buttons[button_index]
		button.visible = button_index < offer_paths.size()
		button.disabled = is_claimed or not local_is_eligible
		button.icon = null
		if not button.visible:
			continue
		var item := LuoxiMerchant.get_collectible_for_path(str(offer_paths[button_index]))
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
	var winning_option := int(state.get("winning_option_index", -1))
	var winning_buff := int(state.get("winning_permanent_buff_id", 0))
	var status_prefix := "命运已决定" if is_complete else "正在兑现命运"
	var resolution_status := (
		"%s：%s · %s" % [
			status_prefix,
			OPTION_TITLES[winning_option],
			str(PERMANENT_BUFF_TEXT.get(winning_buff, "")),
		]
		if winning_option in [0, 7] and winning_buff > 0
		else "%s：%s" % [
			status_prefix,
			OPTION_TITLES[clampi(winning_option, 0, 9)],
		]
	)
	var pending_stone_peers := _to_int_array(state.get("pending_stone_peer_ids", []))
	var local_stone_pending := (
		not is_complete
		and winning_option == 3
		and pending_stone_peers.has(local_peer_id)
	)
	_set_inventory_access_mode(local_stone_pending)
	if local_stone_pending:
		status_label.text = (
			"背包已满 · 按背包键打开背包并丢弃一件可删除物品；"
			+ "腾出空位后将自动获得神秘核心石"
		)
	elif not is_complete and winning_option == 3 and not pending_stone_peers.is_empty():
		status_label.text = "等待 %d 名玩家为神秘核心石腾出背包空位" % pending_stone_peers.size()
	else:
		status_label.text = resolution_status
	var votes := state.get("votes", {}) as Dictionary
	for card_index in range(choice_cards.size()):
		var voters: Array[int] = []
		for peer_variant in votes:
			if int(votes[peer_variant]) == card_index:
				voters.append(int(peer_variant))
		choice_cards[card_index].configure(
			OPTION_TITLES[card_index],
			OPTION_DESCRIPTIONS[card_index],
			FATE_STONE_ICON if card_index == 3 else null,
			true
		)
		choice_cards[card_index].set_selected(card_index == winning_option)
		choice_cards[card_index].set_voters(voters, character_ids_by_peer)


func _set_inventory_access_mode(enabled: bool) -> void:
	layer = INVENTORY_ACCESS_CANVAS_LAYER if enabled else DEFAULT_CANVAS_LAYER
	$Root.mouse_filter = (
		Control.MOUSE_FILTER_IGNORE if enabled else Control.MOUSE_FILTER_STOP
	)


func _on_card_selected(option_index: int) -> void:
	if option_index == 0:
		_show_buff_modal()
		return
	choice_submitted.emit(option_index, 0)


func _show_buff_modal() -> void:
	if permanent_buff_offer.is_empty():
		return
	buff_panel.visible = true
	for button_index in range(buff_buttons.size()):
		var button := buff_buttons[button_index]
		button.visible = button_index < permanent_buff_offer.size()
		if button.visible:
			var buff_id := permanent_buff_offer[button_index]
			button.text = str(PERMANENT_BUFF_TEXT.get(buff_id, "未知增益"))


func _hide_buff_modal() -> void:
	buff_panel.visible = false


func _on_buff_selected(button_index: int) -> void:
	if button_index < 0 or button_index >= permanent_buff_offer.size():
		return
	var buff_id := permanent_buff_offer[button_index]
	_hide_buff_modal()
	choice_submitted.emit(0, buff_id)


func _on_collectible_selected(choice_index: int) -> void:
	collectible_submitted.emit(choice_index)


func _play_show_tween() -> void:
	if show_tween != null:
		return
	var panel := $Root/Center/Panel as Control
	panel.modulate = Color(1, 1, 1, 0)
	panel.scale = Vector2(0.985, 0.985)
	show_tween = create_tween().set_parallel(true)
	show_tween.tween_property(panel, "modulate", Color.WHITE, 0.2)
	show_tween.tween_property(panel, "scale", Vector2.ONE, 0.24).set_trans(
		Tween.TRANS_CUBIC
	).set_ease(Tween.EASE_OUT)
	show_tween.finished.connect(func() -> void: show_tween = null)


func _to_int_array(value: Variant) -> Array[int]:
	var result: Array[int] = []
	if value is Array or value is PackedInt32Array:
		for entry in value:
			result.append(int(entry))
	return result
