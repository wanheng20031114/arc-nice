extends CanvasLayer
class_name LuoxiSpecialGameOverlay

signal card_reveal_requested(card_index: int)
signal finish_requested

const Rules := preload("res://scene/game_modes/tower_defense/merchants/luoxi/luoxi_special_game_rules.gd")

const HEALTH_ICON := preload("res://resources/texture/pickup_health.png")
const CORE_ICON := preload("res://resources/texture/materials/wooden_core.png")
const XIRANG_ICON := preload("res://resources/texture/xirang_icon.png")

const CARD_EDGE_SCALE_X := 0.035
const CARD_FLIP_CLOSE_DURATION := 0.13
const CARD_FLIP_OPEN_DURATION := 0.22
const DEFAULT_STATUS := "选择一张卡牌翻开；奖励会在结束时统一结算"
const CARD_BACK_BORDER_COLOR := Color(0.91, 0.70, 0.27, 1.0)
const BLANK_CARD_BORDER_COLOR := Color(0.58, 0.55, 0.51, 1.0)

@onready var root_control: Control = $Root
@onready var cards: Array[PanelContainer] = [
	$Root/Center/Window/Margin/Layout/CardRow/Card0,
	$Root/Center/Window/Margin/Layout/CardRow/Card1,
	$Root/Center/Window/Margin/Layout/CardRow/Card2,
	$Root/Center/Window/Margin/Layout/CardRow/Card3,
]
@onready var card_backs: Array[Control] = [
	$Root/Center/Window/Margin/Layout/CardRow/Card0/Back,
	$Root/Center/Window/Margin/Layout/CardRow/Card1/Back,
	$Root/Center/Window/Margin/Layout/CardRow/Card2/Back,
	$Root/Center/Window/Margin/Layout/CardRow/Card3/Back,
]
@onready var card_fronts: Array[Control] = [
	$Root/Center/Window/Margin/Layout/CardRow/Card0/Front,
	$Root/Center/Window/Margin/Layout/CardRow/Card1/Front,
	$Root/Center/Window/Margin/Layout/CardRow/Card2/Front,
	$Root/Center/Window/Margin/Layout/CardRow/Card3/Front,
]
@onready var card_contents: Array[Control] = [
	$Root/Center/Window/Margin/Layout/CardRow/Card0/Front/Margin,
	$Root/Center/Window/Margin/Layout/CardRow/Card1/Front/Margin,
	$Root/Center/Window/Margin/Layout/CardRow/Card2/Front/Margin,
	$Root/Center/Window/Margin/Layout/CardRow/Card3/Front/Margin,
]
@onready var card_blank_messages: Array[Label] = [
	$Root/Center/Window/Margin/Layout/CardRow/Card0/Front/BlankMessage,
	$Root/Center/Window/Margin/Layout/CardRow/Card1/Front/BlankMessage,
	$Root/Center/Window/Margin/Layout/CardRow/Card2/Front/BlankMessage,
	$Root/Center/Window/Margin/Layout/CardRow/Card3/Front/BlankMessage,
]
@onready var card_icons: Array[TextureRect] = [
	$Root/Center/Window/Margin/Layout/CardRow/Card0/Front/Margin/Content/Icon,
	$Root/Center/Window/Margin/Layout/CardRow/Card1/Front/Margin/Content/Icon,
	$Root/Center/Window/Margin/Layout/CardRow/Card2/Front/Margin/Content/Icon,
	$Root/Center/Window/Margin/Layout/CardRow/Card3/Front/Margin/Content/Icon,
]
@onready var card_titles: Array[Label] = [
	$Root/Center/Window/Margin/Layout/CardRow/Card0/Front/Margin/Content/Title,
	$Root/Center/Window/Margin/Layout/CardRow/Card1/Front/Margin/Content/Title,
	$Root/Center/Window/Margin/Layout/CardRow/Card2/Front/Margin/Content/Title,
	$Root/Center/Window/Margin/Layout/CardRow/Card3/Front/Margin/Content/Title,
]
@onready var card_descriptions: Array[RichTextLabel] = [
	$Root/Center/Window/Margin/Layout/CardRow/Card0/Front/Margin/Content/Description,
	$Root/Center/Window/Margin/Layout/CardRow/Card1/Front/Margin/Content/Description,
	$Root/Center/Window/Margin/Layout/CardRow/Card2/Front/Margin/Content/Description,
	$Root/Center/Window/Margin/Layout/CardRow/Card3/Front/Margin/Content/Description,
]
@onready var card_buttons: Array[Button] = [
	$Root/Center/Window/Margin/Layout/CardRow/Card0/RevealButton,
	$Root/Center/Window/Margin/Layout/CardRow/Card1/RevealButton,
	$Root/Center/Window/Margin/Layout/CardRow/Card2/RevealButton,
	$Root/Center/Window/Margin/Layout/CardRow/Card3/RevealButton,
]
@onready var status_label: Label = $Root/Center/Window/Margin/Layout/Status
@onready var finish_button: Button = $Root/Center/Window/Margin/Layout/FinishButton

var session_revision: int = 0
var revealed_count: int = 0
var pending := false
var selected_index := 0
var revealed_cards: Array[bool] = [false, false, false, false]
var card_tweens: Array[Tween] = []
var card_styles: Array[StyleBoxFlat] = []


func _ready() -> void:
	card_tweens.resize(cards.size())
	for index in range(cards.size()):
		card_buttons[index].pressed.connect(_request_card_reveal.bind(index))
		card_buttons[index].focus_entered.connect(_on_card_focus_entered.bind(index))
		var style := cards[index].get_theme_stylebox("panel").duplicate() as StyleBoxFlat
		cards[index].add_theme_stylebox_override("panel", style)
		card_styles.append(style)
	finish_button.pressed.connect(_request_finish)
	finish_button.focus_entered.connect(_on_finish_focus_entered)
	root_control.hide()


func show_game(new_session_revision: int) -> void:
	session_revision = new_session_revision
	revealed_count = 0
	pending = false
	selected_index = 0
	for index in range(cards.size()):
		_stop_card_tween(index)
		revealed_cards[index] = false
		cards[index].scale = Vector2.ONE
		cards[index].pivot_offset = _get_card_size(cards[index]) * 0.5
		card_backs[index].show()
		card_fronts[index].hide()
		card_contents[index].show()
		card_blank_messages[index].hide()
		card_icons[index].texture = null
		card_titles[index].text = ""
		card_descriptions[index].text = ""
		_apply_card_color(index, CARD_BACK_BORDER_COLOR)
	_update_finish_button_text()
	set_status(DEFAULT_STATUS)
	root_control.show()
	_update_interactivity()
	call_deferred("_focus_selected_card")


func hide_game() -> void:
	for index in range(cards.size()):
		_stop_card_tween(index)
		cards[index].scale = Vector2.ONE
	pending = false
	root_control.hide()


func is_open() -> bool:
	return root_control.visible


func set_pending(new_pending: bool) -> void:
	pending = new_pending
	_update_interactivity()


func reveal_card(card_index: int, outcome: Dictionary) -> void:
	if card_index < 0 or card_index >= cards.size():
		push_error("洛茜特殊游戏收到越界卡牌编号：%d" % card_index)
		return
	if revealed_cards[card_index]:
		return

	_populate_card_front(card_index, outcome)
	revealed_cards[card_index] = true
	revealed_count += 1
	set_pending(false)
	_update_finish_button_text()
	_update_status_after_reveal(int(outcome["kind"]))
	_play_card_flip(card_index)

	var next_index := _find_next_unrevealed(card_index, 1)
	if next_index >= 0:
		selected_index = next_index
		call_deferred("_focus_selected_card")
	else:
		selected_index = -1
		call_deferred("_focus_finish_button")


func set_status(text: String) -> void:
	status_label.text = text


func handle_input(event: InputEvent) -> bool:
	if not is_open():
		return false
	if event.is_action_pressed("ui_left") or event.is_action_pressed("move_left") or event.is_action_pressed("shoot_left"):
		_select_relative_card(-1)
		return true
	if event.is_action_pressed("ui_right") or event.is_action_pressed("move_right") or event.is_action_pressed("shoot_right"):
		_select_relative_card(1)
		return true
	if event.is_action_pressed("ui_up") or event.is_action_pressed("move_up") or event.is_action_pressed("shoot_up"):
		if selected_index < 0:
			selected_index = _find_next_unrevealed(0, 1, true)
			_focus_selected_card()
		return true
	if event.is_action_pressed("ui_down") or event.is_action_pressed("move_down") or event.is_action_pressed("shoot_down"):
		selected_index = -1
		_focus_finish_button()
		return true
	if event.is_action_pressed("interact") or event.is_action_pressed("ui_accept"):
		if selected_index < 0 or revealed_count >= cards.size():
			_request_finish()
		else:
			_request_card_reveal(selected_index)
		return true
	if event.is_action_pressed("ui_cancel"):
		_request_finish()
		return true
	return true


func _request_card_reveal(card_index: int) -> void:
	if pending or card_index < 0 or card_index >= cards.size() or revealed_cards[card_index]:
		return
	selected_index = card_index
	set_pending(true)
	set_status("正在等待洛茜揭晓……")
	card_reveal_requested.emit(card_index)


func _request_finish() -> void:
	if pending:
		return
	set_pending(true)
	set_status("正在结算本局……")
	finish_requested.emit()


func _populate_card_front(card_index: int, outcome: Dictionary) -> void:
	var kind := int(outcome["kind"])
	var amount := int(outcome["amount"])
	match kind:
		Rules.OutcomeKind.COLLECTIBLE, Rules.OutcomeKind.MATERIAL:
			_populate_item_card(
				card_index,
				outcome,
				kind == Rules.OutcomeKind.COLLECTIBLE
			)
		Rules.OutcomeKind.HEALTH_DAMAGE:
			card_icons[card_index].texture = HEALTH_ICON
			card_titles[card_index].text = "生命代价"
			card_descriptions[card_index].text = _build_health_description(
				int(outcome["effect"]),
				amount
			)
			_apply_card_color(card_index, Color(0.93, 0.24, 0.31, 1.0))
		Rules.OutcomeKind.CORE_DAMAGE:
			card_icons[card_index].texture = CORE_ICON
			card_titles[card_index].text = "核心受创"
			card_descriptions[card_index].text = "核心生命立即 -%d\n此效果无法撤回" % amount
			_apply_card_color(card_index, Color(0.96, 0.47, 0.20, 1.0))
		Rules.OutcomeKind.XIRANG:
			card_icons[card_index].texture = XIRANG_ICON
			card_titles[card_index].text = "+%d" % amount
			card_descriptions[card_index].text = "结束本局后统一结算"
			_apply_card_color(card_index, Color(0.42, 0.85, 1.0, 1.0))
		Rules.OutcomeKind.BLANK:
			card_contents[card_index].hide()
			card_blank_messages[card_index].show()
			_apply_card_color(card_index, BLANK_CARD_BORDER_COLOR)
		_:
			push_error("洛茜特殊游戏收到未知结果类型：%d" % kind)


func _populate_item_card(card_index: int, outcome: Dictionary, is_collectible: bool) -> void:
	var item_path := String(outcome["item_path"])
	var item := load(item_path) as PickupConfig
	if item == null:
		push_error("洛茜特殊游戏无法加载奖励物品：%s" % item_path)
		return
	var amount := maxi(int(outcome["amount"]), 1)
	card_icons[card_index].texture = item.icon_texture
	card_titles[card_index].text = item.display_name
	card_descriptions[card_index].text = "结束本局后获得 ×%d\n%s" % [amount, item.description]
	if is_collectible:
		_apply_card_color(card_index, _get_rarity_color(int(outcome["rarity"])))
	else:
		_apply_card_color(card_index, Color(0.91, 0.70, 0.27, 1.0))


func _build_health_description(effect: int, amount: int) -> String:
	match effect:
		Rules.HealthEffect.SELF_FIXED:
			return "你立即受到 %d 点伤害\n若因此倒下，本局作废" % amount
		Rules.HealthEffect.SELF_LEAVE_ONE:
			return "你的生命值立即变为 1\n此效果无法撤回"
		Rules.HealthEffect.OTHERS_CURRENT_PERCENT:
			return "除你之外的所有玩家\n当前生命值立即减少 %d%%" % amount
		Rules.HealthEffect.ALL_FIXED:
			return "所有玩家立即受到 %d 点伤害\n若你因此倒下，本局作废" % amount
		_:
			push_error("洛茜特殊游戏收到未知生命效果：%d" % effect)
			return ""


func _play_card_flip(card_index: int) -> void:
	_stop_card_tween(card_index)
	var card := cards[card_index]
	card.pivot_offset = _get_card_size(card) * 0.5
	var tween := create_tween()
	card_tweens[card_index] = tween
	tween.tween_property(card, "scale:x", CARD_EDGE_SCALE_X, CARD_FLIP_CLOSE_DURATION).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	tween.tween_callback(_show_card_front.bind(card_index))
	tween.tween_property(card, "scale:x", 1.0, CARD_FLIP_OPEN_DURATION).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tween.finished.connect(func() -> void:
		if card_tweens[card_index] == tween:
			card_tweens[card_index] = null
	)


func _show_card_front(card_index: int) -> void:
	card_backs[card_index].hide()
	card_fronts[card_index].show()


func _stop_card_tween(card_index: int) -> void:
	if card_index < card_tweens.size() and card_tweens[card_index] != null:
		card_tweens[card_index].kill()
		card_tweens[card_index] = null


func _update_interactivity() -> void:
	for index in range(card_buttons.size()):
		card_buttons[index].disabled = pending or revealed_cards[index]
	finish_button.disabled = pending


func _update_finish_button_text() -> void:
	if revealed_count == 0:
		finish_button.text = "直接跑路！"
	elif revealed_count < cards.size():
		finish_button.text = "见好就收！"
	else:
		finish_button.text = "结束"


func _update_status_after_reveal(kind: int) -> void:
	if revealed_count >= cards.size():
		set_status("四张卡牌已全部翻开，请结束本局")
	elif (
		kind == Rules.OutcomeKind.HEALTH_DAMAGE
		or kind == Rules.OutcomeKind.CORE_DAMAGE
	):
		set_status("代价已经立即生效；你仍可继续翻牌或结束")
	elif kind == Rules.OutcomeKind.BLANK:
		set_status("这张牌什么都没有；你可以继续翻牌或结束")
	else:
		set_status("奖励已暂存；你可以继续翻牌或结束")


func _select_relative_card(direction: int) -> void:
	var start_index := selected_index
	if start_index < 0:
		start_index = 0 if direction > 0 else cards.size() - 1
		selected_index = _find_next_unrevealed(start_index, direction, true)
	else:
		selected_index = _find_next_unrevealed(start_index, direction)
	_focus_selected_card()


func _find_next_unrevealed(start_index: int, direction: int, include_start := false) -> int:
	if revealed_count >= cards.size():
		return -1
	var offset := 0 if include_start else 1
	for step in range(offset, cards.size() + offset):
		var candidate := wrapi(start_index + step * direction, 0, cards.size())
		if not revealed_cards[candidate]:
			return candidate
	return -1


func _focus_selected_card() -> void:
	if not is_open() or pending:
		return
	if selected_index >= 0 and selected_index < card_buttons.size() and not card_buttons[selected_index].disabled:
		card_buttons[selected_index].grab_focus()


func _focus_finish_button() -> void:
	if is_open() and not finish_button.disabled:
		finish_button.grab_focus()


func _on_card_focus_entered(card_index: int) -> void:
	selected_index = card_index


func _on_finish_focus_entered() -> void:
	selected_index = -1


func _apply_card_color(card_index: int, color: Color) -> void:
	var style := card_styles[card_index]
	style.border_color = color
	style.shadow_color = Color(color.r, color.g, color.b, 0.28)
	card_titles[card_index].add_theme_color_override("font_color", color.darkened(0.48))


func _get_rarity_color(rarity: int) -> Color:
	match rarity:
		PickupConfig.CollectibleRarity.RARE:
			return Color(0.27, 0.70, 1.0, 1.0)
		PickupConfig.CollectibleRarity.EPIC:
			return Color(0.76, 0.36, 1.0, 1.0)
		PickupConfig.CollectibleRarity.LEGENDARY:
			return Color(1.0, 0.72, 0.20, 1.0)
		PickupConfig.CollectibleRarity.SPECIAL:
			return Color("7EE3C4")
		_:
			return Color(0.80, 0.76, 0.65, 1.0)


func _get_card_size(card: Control) -> Vector2:
	if card.size.x > 0.0 and card.size.y > 0.0:
		return card.size
	return card.custom_minimum_size
