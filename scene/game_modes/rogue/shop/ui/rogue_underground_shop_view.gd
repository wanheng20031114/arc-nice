extends CanvasLayer
class_name RogueUndergroundShopView

signal purchase_requested(offer_index: int)
signal sell_requested(slot_index: int, expected_config_path: String)
signal sell_inventory_requested
signal sell_page_requested(page_index: int)
signal exit_requested

const CARD_COUNT := 8
const SELL_SLOT_CAPACITY := 20
const SELL_PAGE_SIZE := 8
const SELL_PAGE_COUNT := 3
const XIAOCONG_SHOP_LINE := "在这地下矿洞中只有我这一家商店物美价廉"
const XIAOCONG_DIALOGUE_DESIRED_LEFT := 40.0
const XIAOCONG_DIALOGUE_MIN_LEFT := 12.0
const XIAOCONG_DIALOGUE_PANEL_WIDTH := 308.0
const XIAOCONG_DIALOGUE_PANEL_GAP := 4.0
const DETAIL_PRICE_COLOR := Color(1.0, 0.84, 0.52, 1.0)
const DETAIL_INSUFFICIENT_PRICE_COLOR := Color(0.86, 0.32, 0.29, 1.0)

enum ShopTab {
	BUY,
	SELL,
}

@onready var root_control: Control = %Root
@onready var buy_tab_button: TextureButton = %BuyTabButton
@onready var sell_tab_button: TextureButton = %SellTabButton
@onready var buy_tab_label: Label = %BuyTabLabel
@onready var sell_tab_label: Label = %SellTabLabel
@onready var page_controls: Control = %PageControls
@onready var previous_page_button: TextureButton = %PreviousPageButton
@onready var next_page_button: TextureButton = %NextPageButton
@onready var page_label: Label = %PageLabel
@onready var exit_button: TextureButton = %ExitButton
@onready var xiaocong_dialogue_bubble: MerchantDialogueBubble = (
	%XiaocongDialogueBubble
)
@onready var purchase_success_audio: AudioStreamPlayer = %PurchaseSuccessAudio
@onready var detail_overlay: Control = %DetailOverlay
@onready var detail_icon: TextureRect = %DetailIcon
@onready var detail_name: Label = %DetailName
@onready var detail_description: Label = %DetailDescription
@onready var detail_quantity: Label = %DetailQuantity
@onready var detail_price_title: Label = %DetailPriceTitle
@onready var detail_price: Label = %DetailPrice
@onready var detail_status: Label = %DetailStatus
@onready var detail_action_button: TextureButton = %DetailActionButton
@onready var detail_action_label: Label = %DetailActionLabel
@onready var detail_cancel_button: TextureButton = %DetailCancelButton
@onready var run_state: RunStateStore = get_node("/root/RunState") as RunStateStore

@onready var item_cards: Array[RogueUndergroundShopItemCard] = [
	%ItemCard00,
	%ItemCard01,
	%ItemCard02,
	%ItemCard03,
	%ItemCard04,
	%ItemCard05,
	%ItemCard06,
	%ItemCard07,
]

var _active_tab := ShopTab.BUY
var _sell_page := 0
var _buy_offers: Array = []
var _sell_slots: Array = []
var _selected_payload: Dictionary = {}
var _selected_card_index := -1
var _transaction_pending := false
var _current_xirang_balance := 0
var _balance_peer_id := 0


func _ready() -> void:
	assert(item_cards.size() == CARD_COUNT)
	_buy_offers.resize(CARD_COUNT)
	_sell_slots.resize(SELL_SLOT_CAPACITY)
	for card in item_cards:
		card.clear_card()
	if not run_state.quick_use_binding_changed.is_connected(
		_on_quick_use_binding_changed
	):
		run_state.quick_use_binding_changed.connect(
			_on_quick_use_binding_changed
		)
	if not run_state.party_xirang_ledger_changed.is_connected(
		_on_party_xirang_ledger_changed
	):
		run_state.party_xirang_ledger_changed.connect(
			_on_party_xirang_ledger_changed
		)
	_balance_peer_id = run_state.get_active_multiplayer_peer_id()
	_current_xirang_balance = run_state.get_party_xirang_balance(
		_balance_peer_id
	)
	if not root_control.resized.is_connected(_layout_xiaocong_dialogue):
		root_control.resized.connect(_layout_xiaocong_dialogue)
	_layout_xiaocong_dialogue()
	detail_overlay.hide()
	_show_tab(ShopTab.BUY, false)
	close_immediately()


func open_session() -> void:
	visible = true
	_transaction_pending = false
	_sell_page = 0
	exit_button.disabled = false
	close_detail()
	_show_tab(ShopTab.BUY, false)
	_layout_xiaocong_dialogue()
	xiaocong_dialogue_bubble.say(XIAOCONG_SHOP_LINE)
	_focus_first_available_card()


func close_immediately() -> void:
	_selected_payload.clear()
	_selected_card_index = -1
	if detail_overlay != null:
		detail_overlay.hide()
	if xiaocong_dialogue_bubble != null:
		xiaocong_dialogue_bubble.hide_bubble()
	visible = false


func present_buy_offers(offers: Array) -> void:
	_buy_offers.clear()
	_buy_offers.resize(CARD_COUNT)
	for source_index in range(mini(offers.size(), CARD_COUNT)):
		var offer_value: Variant = offers[source_index]
		if typeof(offer_value) != TYPE_DICTIONARY:
			continue
		var offer: Dictionary = offer_value
		_buy_offers[source_index] = offer.duplicate(true)
	if _active_tab == ShopTab.BUY:
		_refresh_grid()
		_refresh_or_close_detail()


func present_shop_snapshot(snapshot: Dictionary) -> void:
	if typeof(snapshot.get("target_peer_id")) == TYPE_INT:
		_balance_peer_id = int(snapshot["target_peer_id"])
	if typeof(snapshot.get("xirang_balance")) == TYPE_INT:
		_current_xirang_balance = maxi(int(snapshot["xirang_balance"]), 0)
	var offers := snapshot.get("offers", snapshot.get("target_offers", [])) as Array
	if offers != null:
		present_buy_offers(offers)
	else:
		_refresh_affordability_presentation()


func set_xirang_balance(balance: int) -> void:
	var normalized_balance := maxi(balance, 0)
	if normalized_balance == _current_xirang_balance:
		return
	_current_xirang_balance = normalized_balance
	_refresh_affordability_presentation()


func present_sell_inventory(slots: Array) -> void:
	_sell_slots.clear()
	_sell_slots.resize(SELL_SLOT_CAPACITY)
	for fallback_index in range(slots.size()):
		var slot_value: Variant = slots[fallback_index]
		if typeof(slot_value) != TYPE_DICTIONARY:
			continue
		var slot: Dictionary = slot_value
		if slot.is_empty():
			continue
		var slot_index := int(slot.get("slot_index", fallback_index))
		if slot_index < 0 or slot_index >= SELL_SLOT_CAPACITY:
			continue
		_sell_slots[slot_index] = slot.duplicate(true)
	if _active_tab == ShopTab.SELL:
		_refresh_grid()
		_refresh_or_close_detail()


func present_sell_inventory_page(page_snapshot: Dictionary) -> void:
	_sell_page = clampi(
		int(page_snapshot.get("page_index", _sell_page)),
		0,
		SELL_PAGE_COUNT - 1
	)
	var slots := page_snapshot.get("slots", []) as Array
	if slots == null:
		slots = []
	present_sell_inventory(slots)


func set_transaction_pending(pending: bool, message := "") -> void:
	_transaction_pending = pending
	detail_action_button.disabled = pending or _selected_payload.is_empty()
	detail_status.text = message
	detail_status.visible = not message.is_empty()
	_set_background_focus_enabled(not detail_overlay.visible)


func present_transaction_error(message: String) -> void:
	set_transaction_pending(false, message)
	if detail_overlay.visible:
		detail_action_button.grab_focus()


func set_exit_enabled(enabled: bool) -> void:
	exit_button.disabled = not enabled


func play_purchase_success_audio() -> void:
	purchase_success_audio.stop()
	purchase_success_audio.play()


func close_detail() -> void:
	if detail_overlay == null:
		return
	detail_overlay.hide()
	_transaction_pending = false
	detail_status.text = ""
	detail_status.hide()
	_set_background_focus_enabled(true)
	if _selected_card_index >= 0 and _selected_card_index < item_cards.size():
		var selected_card := item_cards[_selected_card_index]
		if not selected_card.disabled:
			selected_card.grab_focus()
	_selected_payload.clear()
	_selected_card_index = -1


func show_buy_tab() -> void:
	_show_tab(ShopTab.BUY, false)


func show_sell_tab() -> void:
	_show_tab(ShopTab.SELL, true)


func get_item_cards() -> Array[RogueUndergroundShopItemCard]:
	return item_cards


func get_active_tab() -> int:
	return _active_tab


func get_sell_page() -> int:
	return _sell_page


func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if (
		event.is_action_pressed(&"interact")
		and xiaocong_dialogue_bubble.visible
	):
		if xiaocong_dialogue_bubble.is_revealing:
			xiaocong_dialogue_bubble.finish_line()
		else:
			xiaocong_dialogue_bubble.hide_bubble()
		get_viewport().set_input_as_handled()
		return
	if not detail_overlay.visible:
		return
	if event.is_action_pressed(&"ui_cancel"):
		if not _transaction_pending:
			close_detail()
		get_viewport().set_input_as_handled()


func _show_tab(tab: int, request_fresh_inventory: bool) -> void:
	_active_tab = tab
	buy_tab_button.button_pressed = tab == ShopTab.BUY
	sell_tab_button.button_pressed = tab == ShopTab.SELL
	buy_tab_label.modulate = Color.WHITE if tab == ShopTab.BUY else Color(0.7, 0.7, 0.68)
	sell_tab_label.modulate = Color.WHITE if tab == ShopTab.SELL else Color(0.7, 0.7, 0.68)
	page_controls.visible = tab == ShopTab.SELL
	close_detail()
	_refresh_grid()
	if request_fresh_inventory:
		sell_inventory_requested.emit()
		sell_page_requested.emit(_sell_page)
	_focus_first_available_card()


func _refresh_grid() -> void:
	if _active_tab == ShopTab.BUY:
		for index in range(CARD_COUNT):
			var offer_value: Variant = _buy_offers[index]
			if typeof(offer_value) != TYPE_DICTIONARY:
				item_cards[index].clear_card()
				continue
			var offer: Dictionary = offer_value
			if offer.is_empty():
				item_cards[index].clear_card()
				continue
			item_cards[index].present_buy_offer(
				offer,
				_current_xirang_balance
			)
		page_label.text = ""
		return

	var first_slot := _sell_page * SELL_PAGE_SIZE
	for card_index in range(CARD_COUNT):
		var slot_index := first_slot + card_index
		if slot_index >= SELL_SLOT_CAPACITY:
			item_cards[card_index].clear_card()
			continue
		var slot_value: Variant = _sell_slots[slot_index]
		if typeof(slot_value) != TYPE_DICTIONARY:
			item_cards[card_index].clear_card()
			continue
		var slot: Dictionary = slot_value
		if slot.is_empty() or str(slot.get("config_path", "")).is_empty():
			item_cards[card_index].clear_card()
			continue
		item_cards[card_index].present_sell_slot(
			slot,
			run_state.is_quick_use_slot(int(slot.get("slot_index", -1)))
		)
	page_label.text = "%d / %d" % [_sell_page + 1, SELL_PAGE_COUNT]
	previous_page_button.disabled = _sell_page <= 0
	next_page_button.disabled = _sell_page >= SELL_PAGE_COUNT - 1


func _on_quick_use_binding_changed(
	owner_peer_id: int,
	_config_path: String,
	_preferred_slot_index: int
) -> void:
	if (
		owner_peer_id == run_state.get_active_multiplayer_peer_id()
		and _active_tab == ShopTab.SELL
	):
		_refresh_grid()


func _on_party_xirang_ledger_changed(snapshot: Dictionary) -> void:
	var values := snapshot.get("values", {}) as Dictionary
	if values == null:
		return
	var balance_value: Variant = values.get(
		_balance_peer_id,
		values.get(str(_balance_peer_id), null)
	)
	if typeof(balance_value) == TYPE_INT:
		set_xirang_balance(int(balance_value))


func _refresh_affordability_presentation() -> void:
	if _active_tab == ShopTab.BUY:
		for card in item_cards:
			card.refresh_buy_affordability(_current_xirang_balance)
	if detail_overlay.visible and not _selected_payload.is_empty():
		_refresh_detail_price_color()


func _refresh_or_close_detail() -> void:
	if not detail_overlay.visible or _selected_payload.is_empty():
		return
	if _active_tab == ShopTab.BUY:
		var selected_offer_index := int(_selected_payload.get("offer_index", _selected_card_index))
		if selected_offer_index < 0 or selected_offer_index >= _buy_offers.size():
			close_detail()
			return
		var updated_offer_value: Variant = _buy_offers[selected_offer_index]
		if typeof(updated_offer_value) != TYPE_DICTIONARY:
			close_detail()
			return
		var updated_offer: Dictionary = updated_offer_value
		if (
			updated_offer.is_empty()
			or bool(updated_offer.get("purchased", updated_offer.get("sold_out", false)))
		):
			close_detail()
			return
		_selected_payload = updated_offer.duplicate(true)
		_present_detail(_selected_payload)
		return

	var selected_slot_index := int(_selected_payload.get("slot_index", -1))
	if selected_slot_index < 0 or selected_slot_index >= _sell_slots.size():
		close_detail()
		return
	var updated_slot_value: Variant = _sell_slots[selected_slot_index]
	if typeof(updated_slot_value) != TYPE_DICTIONARY:
		close_detail()
		return
	var updated_slot: Dictionary = updated_slot_value
	if (
		updated_slot.is_empty()
		or str(updated_slot.get("config_path", "")).is_empty()
		or int(updated_slot.get(
			"stack_count",
			updated_slot.get("count", updated_slot.get("amount", 0))
		)) <= 0
	):
		close_detail()
		return
	_selected_payload = updated_slot.duplicate(true)
	_present_detail(_selected_payload)


func _focus_first_available_card() -> void:
	for card in item_cards:
		if not card.disabled:
			card.grab_focus()
			return
	if not exit_button.disabled:
		exit_button.grab_focus()


func _on_item_card_selected(card: RogueUndergroundShopItemCard) -> void:
	var card_index := item_cards.find(card)
	if card_index < 0:
		return
	_selected_card_index = card_index
	_selected_payload = card.get_payload()
	xiaocong_dialogue_bubble.hide_bubble()
	_present_detail(_selected_payload)
	_set_background_focus_enabled(false)
	detail_overlay.show()
	detail_action_button.grab_focus()


func _present_detail(payload: Dictionary) -> void:
	var item := _resolve_item(payload)
	var texture := payload.get("icon_texture") as Texture2D
	if texture == null:
		texture = payload.get("texture") as Texture2D
	if texture == null and item != null:
		texture = item.icon_texture
	var display_name := str(payload.get("display_name", ""))
	var description := str(payload.get("description", ""))
	if item != null:
		if display_name.is_empty():
			display_name = item.display_name
		if description.is_empty():
			description = item.description
	detail_icon.texture = texture
	detail_name.text = display_name if not display_name.is_empty() else "未知物品"
	detail_description.text = description
	var is_sell := _active_tab == ShopTab.SELL
	var price := int(
		payload.get(
			"sell_price",
			payload.get("recycle_price", payload.get("price", 0))
		)
	)
	detail_price_title.text = "回收价" if is_sell else "价格"
	detail_price.text = str(maxi(price, 0))
	_refresh_detail_price_color()
	detail_action_label.text = "出售" if is_sell else "购买"
	var count := maxi(
		int(payload.get(
			"stack_count",
			payload.get("count", payload.get("amount", 1))
		)),
		1
	)
	detail_quantity.text = "背包内 ×%d" % count
	detail_quantity.visible = is_sell
	detail_status.text = RogueUndergroundShopItemCard.get_disabled_reason_text(
		str(payload.get("disabled_reason", ""))
	)
	detail_status.visible = not detail_status.text.is_empty()
	var cannot_sell := (
		not bool(payload.get("can_sell", true))
		if is_sell and payload.has("can_sell")
		else bool(payload.get("disabled", false))
	)
	detail_action_button.disabled = _transaction_pending or cannot_sell


func _refresh_detail_price_color() -> void:
	var is_sell := _active_tab == ShopTab.SELL
	var resolved_price := int(
		_selected_payload.get(
			"sell_price",
			_selected_payload.get(
				"recycle_price",
				_selected_payload.get("price", 0)
			)
		)
	)
	var insufficient := (
		not is_sell
		and not bool(
			_selected_payload.get(
				"purchased",
				_selected_payload.get("sold_out", false)
			)
		)
		and _current_xirang_balance < maxi(resolved_price, 0)
	)
	detail_price.add_theme_color_override(
		"font_color",
		DETAIL_INSUFFICIENT_PRICE_COLOR if insufficient else DETAIL_PRICE_COLOR
	)


func _resolve_item(payload: Dictionary) -> PickupConfig:
	var item := payload.get("item") as PickupConfig
	if item != null:
		return item
	var config_path := str(payload.get("config_path", ""))
	if config_path.is_empty() or not ResourceLoader.exists(config_path):
		return null
	return load(config_path) as PickupConfig


func _set_background_focus_enabled(enabled: bool) -> void:
	var focus_mode := Control.FOCUS_ALL if enabled else Control.FOCUS_NONE
	for card in item_cards:
		card.set_background_interaction_enabled(enabled)
	for button in [
		buy_tab_button,
		sell_tab_button,
		previous_page_button,
		next_page_button,
		exit_button,
	]:
		button.focus_mode = focus_mode


func _on_buy_tab_pressed() -> void:
	_show_tab(ShopTab.BUY, false)


func _on_sell_tab_pressed() -> void:
	_show_tab(ShopTab.SELL, true)


func _on_previous_page_pressed() -> void:
	if _sell_page <= 0:
		return
	_sell_page -= 1
	close_detail()
	_refresh_grid()
	sell_page_requested.emit(_sell_page)
	_focus_first_available_card()


func _on_next_page_pressed() -> void:
	if _sell_page >= SELL_PAGE_COUNT - 1:
		return
	_sell_page += 1
	close_detail()
	_refresh_grid()
	sell_page_requested.emit(_sell_page)
	_focus_first_available_card()


func _on_detail_action_pressed() -> void:
	if _transaction_pending or _selected_payload.is_empty():
		return
	_transaction_pending = true
	detail_action_button.disabled = true
	detail_status.text = "正在提交……"
	detail_status.show()
	if _active_tab == ShopTab.BUY:
		purchase_requested.emit(
			int(_selected_payload.get("offer_index", _selected_card_index))
		)
		return
	sell_requested.emit(
		int(_selected_payload.get("slot_index", -1)),
		str(_selected_payload.get("config_path", ""))
	)


func _on_detail_cancel_pressed() -> void:
	if _transaction_pending:
		return
	close_detail()


func _on_exit_pressed() -> void:
	if _transaction_pending:
		return
	exit_button.disabled = true
	xiaocong_dialogue_bubble.hide_bubble()
	exit_requested.emit()


func _layout_xiaocong_dialogue() -> void:
	if xiaocong_dialogue_bubble == null or root_control == null:
		return
	var shop_panel_left := root_control.size.x * 0.34
	var safe_left := shop_panel_left - (
		XIAOCONG_DIALOGUE_PANEL_WIDTH + XIAOCONG_DIALOGUE_PANEL_GAP
	)
	xiaocong_dialogue_bubble.position = Vector2(
		maxf(
			XIAOCONG_DIALOGUE_MIN_LEFT,
			minf(XIAOCONG_DIALOGUE_DESIRED_LEFT, safe_left)
		),
		28.0
	).round()
