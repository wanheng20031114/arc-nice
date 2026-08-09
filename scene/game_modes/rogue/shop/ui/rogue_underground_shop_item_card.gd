extends TextureButton
class_name RogueUndergroundShopItemCard

signal item_selected(card: RogueUndergroundShopItemCard)

enum PresentationMode {
	BUY,
	SELL,
}

@onready var item_icon: TextureRect = %ItemIcon
@onready var quick_use_badge: TextureRect = %QuickUseBadge
@onready var xirang_icon: TextureRect = %XirangIcon
@onready var price_label: Label = %PriceLabel
@onready var count_label: Label = %CountLabel
@onready var state_shade: ColorRect = %StateShade
@onready var state_label: Label = %StateLabel

var _mode := PresentationMode.BUY
var _payload: Dictionary = {}


func _ready() -> void:
	pressed.connect(_on_pressed)
	clear_card()


func present_buy_offer(offer: Dictionary) -> void:
	_mode = PresentationMode.BUY
	_payload = offer.duplicate(true)
	_apply_common_payload(offer, int(offer.get("price", 0)))
	quick_use_badge.hide()
	count_label.hide()
	var sold_out := bool(offer.get("purchased", offer.get("sold_out", false)))
	state_label.text = "售罄" if sold_out else ""
	state_label.visible = sold_out
	state_shade.visible = sold_out
	disabled = sold_out or bool(offer.get("disabled", false))
	tooltip_text = _build_tooltip(offer, disabled)
	visible = true


func present_sell_slot(slot: Dictionary, quick_use_bound: bool = false) -> void:
	_mode = PresentationMode.SELL
	_payload = slot.duplicate(true)
	_apply_common_payload(
		slot,
		int(slot.get("sell_price", slot.get("recycle_price", slot.get("price", 0))))
	)
	var count := maxi(
		int(slot.get("stack_count", slot.get("count", slot.get("amount", 1)))),
		1
	)
	count_label.text = "×%d" % count
	var item := _resolve_item(slot)
	quick_use_badge.visible = quick_use_bound
	count_label.visible = count > 1 or (item != null and item.stackable)
	var cannot_sell := (
		not bool(slot.get("can_sell", true))
		if slot.has("can_sell")
		else bool(slot.get("disabled", false))
	)
	state_label.text = "禁售" if cannot_sell else ""
	state_label.visible = cannot_sell
	state_shade.visible = cannot_sell
	disabled = cannot_sell
	tooltip_text = _build_tooltip(slot, cannot_sell)
	visible = true


func clear_card() -> void:
	_payload = {}
	if item_icon != null:
		item_icon.texture = null
	if quick_use_badge != null:
		quick_use_badge.hide()
	if price_label != null:
		price_label.text = ""
	if xirang_icon != null:
		xirang_icon.hide()
	if count_label != null:
		count_label.hide()
	if state_label != null:
		state_label.hide()
	if state_shade != null:
		state_shade.hide()
	disabled = true
	tooltip_text = ""
	visible = true


func get_payload() -> Dictionary:
	return _payload.duplicate(true)


func get_presentation_mode() -> int:
	return _mode


static func get_disabled_reason_text(reason: String) -> String:
	match reason:
		"", "empty", "out_of_range":
			return ""
		"locked":
			return "锁定物品不可出售"
		"building":
			return "建筑物品不可出售"
		"unsupported_type":
			return "该类型暂不可出售"
		"insufficient_xirang":
			return "息壤不足"
		"inventory_full":
			return "背包已满"
		_:
			return reason


func set_background_interaction_enabled(enabled: bool) -> void:
	focus_mode = Control.FOCUS_ALL if enabled else Control.FOCUS_NONE
	mouse_filter = Control.MOUSE_FILTER_STOP if enabled else Control.MOUSE_FILTER_IGNORE


func _apply_common_payload(payload: Dictionary, price: int) -> void:
	var item := _resolve_item(payload)
	var texture := payload.get("icon_texture") as Texture2D
	if texture == null:
		texture = payload.get("texture") as Texture2D
	if texture == null and item != null:
		texture = item.icon_texture
	item_icon.texture = texture
	price_label.text = str(maxi(price, 0))
	xirang_icon.show()


func _resolve_item(payload: Dictionary) -> PickupConfig:
	var item := payload.get("item") as PickupConfig
	if item != null:
		return item
	var config_path := str(payload.get("config_path", ""))
	if config_path.is_empty() or not ResourceLoader.exists(config_path):
		return null
	return load(config_path) as PickupConfig


func _build_tooltip(payload: Dictionary, is_disabled: bool) -> String:
	var item := _resolve_item(payload)
	var display_name := str(payload.get("display_name", ""))
	if display_name.is_empty() and item != null:
		display_name = item.display_name
	if is_disabled:
		var reason := get_disabled_reason_text(
			str(payload.get("disabled_reason", ""))
		)
		if not reason.is_empty():
			return "%s · %s" % [display_name, reason]
	return display_name


func _on_pressed() -> void:
	if _payload.is_empty() or disabled:
		return
	item_selected.emit(self)
