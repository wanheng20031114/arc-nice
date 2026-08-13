extends TextureButton
class_name RogueUndergroundShopItemCard

signal item_selected(card: RogueUndergroundShopItemCard)

enum PresentationMode {
	BUY,
	SELL,
}

const PRICE_COLOR := Color(0.91, 0.8, 0.57, 1.0)
const INSUFFICIENT_PRICE_COLOR := Color(0.86, 0.32, 0.29, 1.0)

@export_range(0.0, 4.0, 0.05) var float_amplitude_pixels := 1.5
@export_range(1.0, 6.0, 0.05) var float_period_seconds := 3.0
@export_range(0.0, 1.0, 0.01) var float_phase_turns := 0.0

@onready var item_icon: TextureRect = %ItemIcon
@onready var quick_use_badge: TextureRect = %QuickUseBadge
@onready var xirang_icon: TextureRect = %XirangIcon
@onready var price_label: Label = %PriceLabel
@onready var count_label: Label = %CountLabel
@onready var state_shade: ColorRect = %StateShade
@onready var state_label: Label = %StateLabel

var _mode := PresentationMode.BUY
var _payload: Dictionary = {}
var _item_icon_rest_position := Vector2.ZERO
var _float_elapsed_seconds := 0.0


func _ready() -> void:
	_item_icon_rest_position = item_icon.position
	pressed.connect(_on_pressed)
	clear_card()


func _process(delta: float) -> void:
	if item_icon.texture == null or not is_visible_in_tree():
		return
	_float_elapsed_seconds = fposmod(
		_float_elapsed_seconds + maxf(delta, 0.0),
		maxf(float_period_seconds, 0.001)
	)
	_update_item_icon_float()


func present_buy_offer(offer: Dictionary, xirang_balance: int = 0) -> void:
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
	refresh_buy_affordability(xirang_balance)
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
	_set_price_color(false)
	tooltip_text = _build_tooltip(slot, cannot_sell)
	visible = true


func clear_card() -> void:
	_payload = {}
	if item_icon != null:
		item_icon.texture = null
		item_icon.position = _item_icon_rest_position
	_float_elapsed_seconds = 0.0
	set_process(false)
	if quick_use_badge != null:
		quick_use_badge.hide()
	if price_label != null:
		price_label.text = ""
		_set_price_color(false)
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


func refresh_buy_affordability(xirang_balance: int) -> void:
	if _mode != PresentationMode.BUY or _payload.is_empty():
		return
	var sold_out := bool(
		_payload.get("purchased", _payload.get("sold_out", false))
	)
	var price := maxi(int(_payload.get("price", 0)), 0)
	_set_price_color(not sold_out and maxi(xirang_balance, 0) < price)


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


func get_float_offset_at_time(elapsed_seconds: float) -> float:
	var safe_period := maxf(float_period_seconds, 0.001)
	return sin(
		TAU * (elapsed_seconds / safe_period + float_phase_turns)
	) * float_amplitude_pixels


func _apply_common_payload(payload: Dictionary, price: int) -> void:
	var item := _resolve_item(payload)
	var texture := payload.get("icon_texture") as Texture2D
	if texture == null:
		texture = payload.get("texture") as Texture2D
	if texture == null and item != null:
		texture = item.icon_texture
	item_icon.texture = texture
	set_process(texture != null)
	_update_item_icon_float()
	price_label.text = str(maxi(price, 0))
	xirang_icon.show()


func _update_item_icon_float() -> void:
	item_icon.position = _item_icon_rest_position + Vector2(
		0.0,
		get_float_offset_at_time(_float_elapsed_seconds)
	)


func _set_price_color(insufficient: bool) -> void:
	price_label.add_theme_color_override(
		"font_color",
		INSUFFICIENT_PRICE_COLOR if insufficient else PRICE_COLOR
	)


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
